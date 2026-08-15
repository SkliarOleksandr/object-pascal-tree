unit PasTreeIdePlugin.FindReferences;

{
  Find References entry point, wired to the "Find References (PasTree)" editor
  menu item (see PasTreeIdePlugin.Wizard).

  Current state: PoC. Runs PasTree's real TPasSemaProject/TPasNavigator
  in-process, inside this (Win32) designtime package. Deliberately NOT
  out-of-process yet - see the architecture note below.

    - GatherOpenUnitOverrides reads every currently-OPEN Pascal unit's live
      buffer text via IOTAEditorContent.Content, using IOTAModuleServices'
      already-open-modules list (IOTAModuleServices.Modules) - never forcing
      anything to load. An earlier version instead walked every unit
      belonging to the active project via IOTAProject.GetModule and called
      IOTAModuleInfo.OpenModule on each one to force it open; for a form or
      data module not already open, that forces the IDE to instantiate its
      design surface, which flickered every such form's designer open and
      shut in rapid succession on the very first click. Everything NOT
      currently open doesn't need us at all: TPasSemaProject.LoadFile
      already reads any unit straight from disk when nothing overrode its
      buffer via SetBuffer - overlaying live text is only for units that
      might have unsaved edits, i.e. ones already open.
    - ExecuteFindReferences builds a throwaway TPasSemaProject rooted at the
      active project's own file, overlaying just the open units' live text,
      analyzes the whole project (TPasSemaProject.AnalyzeProject), and uses
      TPasNavigator's three-identity lookup (symbol / unit / builtin - see
      source/PasTree.Sema.Nav.pas's own comments) to resolve whatever is
      under the cursor and enumerate its references.
    - Results go to a dedicated "Find References" tab in the Messages
      panel (see ReportHits), grouped by file (one header row per file via
      AddToolMessage's own Parent/LineRef mechanism - same tree structure
      "Find in Files" uses), one line per hit with file/line/column so the
      IDE's own message navigation jumps straight to it.

  Architecture note - in-process is a known, accepted PoC limitation:
  the real target project (large; needs Win64 and several GB to analyze -
  see project memory) will NOT fit/perform acceptably analyzed from inside
  THIS package, because a designtime package is forced to run Win32 (the
  IDE itself is a 32-bit process). Re-running the full project analysis on
  every single menu click, synchronously, on the UI thread, is also not
  viable at real-project scale. The intended fix is an out-of-process Win64
  helper (extending tools\PasTreeSemaProject.dpr) that this plugin talks to
  instead of calling TPasSemaProject directly - deliberately not built yet.

  TODO (next):
    1. Cache TPasSemaProject/TPasNavigator across calls instead of rebuilding
       from scratch on every click (fine for a small test project; not for
       a real one).
    2. Move analysis out-of-process (Win64 helper) once ready to test against
       the real target project - see the architecture note above.
    3. Read the project's actual $DEFINEs (e.g. from .dproj DCC_Define) and
       pass them as TPasSemaProject's AExtraDefines instead of the empty
       array used now.
    4. Highlight the matched identifier within each hit's snippet text
       (TPasRefHit.HiFrom/HiTo already carry the offsets - same field the
       demo's own MakeFindRefDisplay uses). AddToolMessage draws plain text
       only; doing this means a message class implementing
       IOTACustomMessage100 (for FileName/Line/Col + navigation) and
       INTACustomDrawMessage (Draw/CalcRect on a TCanvas - ToolsAPI.pas:6335)
       together, registered via AddCustomMessage instead of AddToolMessage.
       Deliberately deferred - real code, not wired up, for a cosmetic-only
       improvement at this PoC stage.
}

interface

uses
  ToolsAPI;

type
  TUnitSource = record
    FileName: string;
    Text: string;
  end;

/// <summary>
/// Entry point called from the editor's local menu action.
/// </summary>
procedure ExecuteFindReferences(const AView: IOTAEditView);

/// <summary>
/// Live buffer text of every currently-open Pascal unit, IDE-wide (not
/// forced open - see the unit header for why forcing modules open is
/// avoided). These are overlaid onto the analyzed project via SetBuffer so
/// unsaved edits are picked up; everything else is read from disk by
/// TPasSemaProject itself.
/// </summary>
function GatherOpenUnitOverrides: TArray<TUnitSource>;

implementation

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Generics.Collections,
  Vcl.Dialogs, Vcl.Forms, ToolsAPI.UI, Winapi.ActiveX, IStreams, PlatformConst,
  PasTree.Platforms, PasTree.Sema.Project, PasTree.Sema.Nav;

const
  cMessageGroupName = 'Find References';

function GetOrCreateMessageGroup(const AMessageServices: IOTAMessageServices): IOTAMessageGroup;
begin
  Result := AMessageServices.GetGroup(cMessageGroupName);
  if not Assigned(Result) then
    Result := AMessageServices.AddMessageGroup(cMessageGroupName);
end;

function GetActiveProject: IOTAProject;
var
  LModuleServices: IOTAModuleServices;
  LGroup: IOTAProjectGroup;
begin
  Result := nil;
  if Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
  begin
    LGroup := LModuleServices.MainProjectGroup;
    if Assigned(LGroup) then
      Result := LGroup.ActiveProject;
  end;
end;

/// <summary>
/// IOTAProject.FileName is the .dproj (the MSBuild wrapper RAD Studio
/// actually opens) - not something TPasParser can make any sense of, and
/// with no `uses` clause in it, AnalyzeProject silently "succeeds" having
/// analyzed nothing. The real Pascal main source (.dpr for an application,
/// .dpk for a package) sits right next to it with the same base name - that
/// convention is what .dproj's own <MainSource> tag encodes, and is reliable
/// enough for this PoC without pulling in an XML/dproj parser to read it
/// properly (source/PasTree.DProj.pas already does that, if this ever needs
/// to stop assuming the convention holds).
/// </summary>
function ResolveMainSourceFile(const AProject: IOTAProject): string;
var
  LBase, LCandidate: string;
begin
  LBase := ChangeFileExt(AProject.FileName, '');
  LCandidate := LBase + '.dpr';
  if TFile.Exists(LCandidate) then
    Exit(LCandidate);
  LCandidate := LBase + '.dpk';
  if TFile.Exists(LCandidate) then
    Exit(LCandidate);
  Result := AProject.FileName; // fallback - will very likely fail to parse
end;

function ReadUnitText(const AModule: IOTAModule): string;
var
  LBuffer: IOTAEditBuffer;
  LEditorContent: IOTAEditorContent;
  LIStream: IStream;
  LIMemStream: TIMemoryStream;
  LMemStream: TMemoryStream;
  LFileContent: UTF8String;
begin
  // Deliberately using the same technique as RAD Studio's own official
  // "Editor Raw Read Demo" (StreamReadGetFileData): IOTAEditorContent.Content
  // gives direct access to the buffer's own memory stream. An earlier version
  // of this function used the legacy IOTAEditReader.GetText loop instead,
  // which triggered heap/stack corruption (an access violation showing up
  // much later, in unrelated IDE code, on the *next* menu click) - GetText's
  // Count-respecting behavior is apparently not safe to assume here. Do not
  // reintroduce IOTAEditReader for this without re-verifying against the
  // official samples first.
  //
  // AModule is expected to already be open (came from IOTAModuleServices'
  // already-open-modules list) - no .OpenModule call here. Forcing a module
  // open (an earlier version of this unit did, via IOTAModuleInfo.OpenModule
  // over every unit belonging to the project) makes the IDE instantiate a
  // form/data module's design surface if it wasn't open yet, which flickers
  // every such form's designer open and shut. See the unit header.
  Result := '';
  if not Supports(AModule.GetModuleFileEditor(0), IOTAEditBuffer, LBuffer) then
    Exit;

  LEditorContent := LBuffer as IOTAEditorContent;
  LIStream := LEditorContent.Content;
  LIMemStream := LIStream as TIMemoryStream;
  LMemStream := LIMemStream.MemoryStream;
  SetLength(LFileContent, LMemStream.Size);
  LMemStream.Position := 0;
  if LMemStream.Size <> 0 then
    LMemStream.Read(LFileContent[1], Length(LFileContent));
  Result := UTF8ToString(LFileContent);
end;

/// <summary>
/// Unlike a plain AddTitleMessage, this always routes into the same "PasTree
/// References" tab AND activates it (ShowMessageView) - a diagnostic that
/// only the Build tab sees, unopened, might as well not exist. Use this for
/// every early-exit/error path so a silent failure is never actually silent.
/// </summary>
procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
  LGroup: IOTAMessageGroup;
begin
  if not Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    Exit;
  LGroup := GetOrCreateMessageGroup(LMessageServices);
  LMessageServices.AddTitleMessage(AMessage, LGroup);
  LMessageServices.ShowMessageView(LGroup);
end;

function GatherOpenUnitOverrides: TArray<TUnitSource>;
var
  LModuleServices: IOTAModuleServices;
  I: Integer;
  LModule: IOTAModule;
  LUnits: TList<TUnitSource>;
begin
  SetLength(Result, 0);
  if not Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
    Exit;

  LUnits := TList<TUnitSource>.Create;
  try
    for I := 0 to LModuleServices.ModuleCount - 1 do
    begin
      LModule := LModuleServices.Modules[I];
      if not Assigned(LModule) then
        Continue;
      if not SameText(ExtractFileExt(LModule.FileName), '.pas') then
        Continue;
      try
        var LUnit: TUnitSource;
        LUnit.FileName := LModule.FileName;
        LUnit.Text := ReadUnitText(LModule);
        LUnits.Add(LUnit);
      except
        on E: Exception do
          // Scaffold diagnostics: identify exactly which module/operation is
          // failing instead of guessing. Remove once the real cause is fixed.
          LogDiagnostic(Format('PasTree Find References: failed reading open unit #%d '
            + '(FileName=%s): %s: %s',
            [I, LModule.FileName, E.ClassName, E.Message]));
      end;
    end;
    Result := LUnits.ToArray;
  finally
    LUnits.Free;
  end;
end;

/// <summary>
/// Maps an IOTAProject.CurrentPlatform platform id (see PlatformConst.pas -
/// cWin32Platform, cWin64Platform, ...) to the closest TPasPlatform PasTree
/// understands. PasTree doesn't model every RAD Studio target (no ARM64EC,
/// no 32-bit non-Windows) - those fall back to the nearest 64-bit equivalent,
/// and anything unrecognized falls back to pfWin32.
/// </summary>
function MapPlatform(const APlatformId: string): TPasPlatform;
begin
  if SameText(APlatformId, cWin64Platform) or SameText(APlatformId, cWin64xPlatform)
    or SameText(APlatformId, cWinArm64Platform) or SameText(APlatformId, cWinArm64ECPlatform) then
    Result := pfWin64
  else if SameText(APlatformId, ciOSDevice64Platform) then
    Result := pfIOSDevice64
  else if SameText(APlatformId, ciOSSimulatorArm64Platform) then
    Result := pfIOSSimArm64
  else if SameText(APlatformId, cAndroidArm32Platform) then
    Result := pfAndroid32
  else if SameText(APlatformId, cAndroidArm64Platform) then
    Result := pfAndroid64
  else if SameText(APlatformId, cLinux64Platform) then
    Result := pfLinux64
  else
    Result := pfWin32; // includes cWin32Platform itself, and any unknown id
end;

/// <summary>
/// DISABLED - see CollectSearchPaths' own comment at its call site. Kept
/// here, unused, as a documented starting point for whoever investigates
/// the AV next; do not just re-enable the call without a standalone repro.
///
/// RTL/VCL/ToolsAPI source directories, rooted at the IDE's own install
/// location (IOTAServices.GetRootDirectory - portable across machines and
/// versions, no hardcoded "37.0"). Without these, any identifier declared
/// outside the active project itself - TActionList (Vcl.ActnList), IOTAWizard
/// (ToolsAPI), anything from the RTL/VCL - fails to resolve: `uses` can't
/// find a unit PasTree has no search path for, so SymbolAt/UnitAt/
/// BuiltinNameAt all correctly report nothing. Only Pascal compiler builtins
/// (Boolean, Integer, ...) worked before this, since those never depend on
/// `uses` resolution at all.
/// </summary>
function GetIDESourcePaths: TArray<string>;
var
  LServices: IOTAServices;
  LRoot: string;
begin
  SetLength(Result, 0);
  if not Supports(BorlandIDEServices, IOTAServices, LServices) then
    Exit;
  LRoot := IncludeTrailingPathDelimiter(LServices.GetRootDirectory) + 'source\';
  Result := [LRoot + 'rtl', LRoot + 'vcl', LRoot + 'ToolsAPI'];
end;

/// <summary>
/// Distinct directories from the active project's own location, every
/// currently-open unit, and the IDE's own RTL/VCL/ToolsAPI source (see
/// GetIDESourcePaths) - in first-seen order. TPasSourceManager scans each
/// entry's whole subtree, so the project's own root alone usually covers
/// units that aren't open at all.
/// </summary>
function CollectSearchPaths(const AProjectDir: string; const AOpenUnits: TArray<TUnitSource>): TArray<string>;
var
  LSeen: TDictionary<string, Boolean>;
  LList: TList<string>;
  LUnit: TUnitSource;
  LDir: string;

  procedure AddDir(const ADir: string);
  begin
    if (ADir <> '') and not LSeen.ContainsKey(LowerCase(ADir)) then
    begin
      LSeen.Add(LowerCase(ADir), True);
      LList.Add(ADir);
    end;
  end;

begin
  LSeen := TDictionary<string, Boolean>.Create;
  LList := TList<string>.Create;
  try
    AddDir(AProjectDir);
    for LUnit in AOpenUnits do
    begin
      LDir := ExtractFilePath(LUnit.FileName);
      AddDir(LDir);
    end;
    // GetIDESourcePaths (rtl/vcl/ToolsAPI) is DISABLED for now - see its own
    // comment. Adding those search paths correlated with an access violation
    // (heap/stack corruption surfacing later, in unrelated IDE code, on a
    // subsequent menu click - the same signature the IOTAEditReader.GetText
    // bug had) on a real multi-unit project. That earlier bug was in this
    // unit's own ToolsAPI usage; this one showed up with no ToolsAPI-side
    // change at all, only a much larger search corpus handed to PasTree
    // itself (thousands of RTL/VCL files, incl. platform-duplicate unit
    // names across subfolders) - suspect it's inside PasTree's own
    // TPasSourceManager/preprocessor at that scale, not this plugin's code.
    // Do not re-enable without a proper standalone repro outside the IDE.
    Result := LList.ToArray;
  finally
    LList.Free;
    LSeen.Free;
  end;
end;

/// <summary>
/// Reports the declaration site (if any) plus every found reference, grouped
/// by file, in a dedicated "Find References" tab in the Messages panel
/// (distinct from the Build tab, reused across searches - each call clears
/// it first). Grouping uses AddToolMessage's own Parent/LineRef mechanism -
/// one header line per file (its LineRef captured), every hit in that file
/// added as a child of that header - no custom message class needed, this
/// is the same mechanism the IDE's own "Find in Files" tree uses. Each leaf
/// line carries a file/line/column, so the IDE's own message-view navigation
/// (double-click, Enter, F8/Shift+F8) jumps straight to it.
/// </summary>
procedure ReportHits(const AIdentifier: string; AHasDecl: Boolean;
  const ADeclHit: TPasRefHit; const AHits: TArray<TPasRefHit>);
var
  LMessageServices: IOTAMessageServices;
  LGroup: IOTAMessageGroup;
  LFileCounts: TDictionary<string, Integer>;
  LFileHeaders: TDictionary<string, Pointer>;
  LLineRef, LParentRef: Pointer;
  LHit: TPasRefHit;
  LCount: Integer;

  procedure CountFile(const AFilePath: string);
  var
    LKey: string;
    LExisting: Integer;
  begin
    LKey := LowerCase(AFilePath);
    LFileCounts.TryGetValue(LKey, LExisting);
    LFileCounts.AddOrSetValue(LKey, LExisting + 1);
  end;

  function GetOrCreateFileHeader(const AFilePath: string): Pointer;
  var
    LKey: string;
    LFileCount: Integer;
  begin
    LKey := LowerCase(AFilePath);
    if not LFileHeaders.TryGetValue(LKey, Result) then
    begin
      LFileCounts.TryGetValue(LKey, LFileCount);
      // LineNumber stays 1 (not the file's reference count) - double-click
      // still jumps to the top of the file rather than doing nothing/
      // expand-only. Fixing that needs a custom IOTACustomMessage100 class
      // (CanGotoSource/DefaultHandling) - deliberately not done yet, see
      // this procedure's own doc comment.
      LMessageServices.AddToolMessage(AFilePath,
        Format('%s (%d)', [ExtractFileName(AFilePath), LFileCount]),
        '', 1, 1, nil, Result, LGroup);
      LFileHeaders.Add(LKey, Result);
    end;
  end;

begin
  if not Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    Exit;

  LGroup := GetOrCreateMessageGroup(LMessageServices);
  LMessageServices.ClearMessageGroup(LGroup);

  LMessageServices.AddTitleMessage(
    Format('PasTree Find References: "%s" - %d reference(s)', [AIdentifier, Length(AHits)]),
    LGroup);

  LFileCounts := TDictionary<string, Integer>.Create;
  LFileHeaders := TDictionary<string, Pointer>.Create;
  try
    if AHasDecl then
      CountFile(ADeclHit.FilePath);
    for LHit in AHits do
      CountFile(LHit.FilePath);

    if AHasDecl then
    begin
      LParentRef := GetOrCreateFileHeader(ADeclHit.FilePath);
      LMessageServices.AddToolMessage(ADeclHit.FilePath,
        Format('declaration of "%s"', [AIdentifier]),
        '', ADeclHit.Line, ADeclHit.Col, LParentRef, LLineRef, LGroup);
    end;

    for LHit in AHits do
    begin
      LParentRef := GetOrCreateFileHeader(LHit.FilePath);
      LMessageServices.AddToolMessage(LHit.FilePath, Trim(LHit.Snippet),
        '', LHit.Line, LHit.Col, LParentRef, LLineRef, LGroup);
    end;
  finally
    LFileHeaders.Free;
    LFileCounts.Free;
  end;

  LMessageServices.ShowMessageView(LGroup);
end;

procedure ExecuteFindReferences(const AView: IOTAEditView);
var
  LCursorPos: IOTAEditPosition;
  LCursorFile: string;
  LRow, LCol: Integer;
  LProject: IOTAProject;
  LMainFile: string;
  LUnits: TArray<TUnitSource>;
  LUnit: TUnitSource;
  LSearchPaths: TArray<string>;
  LSema: TPasSemaProject;
  LNav: TPasNavigator;
  LMid, LTMid, LSym, LTargetMid: Integer;
  LName: string;
  LHasDecl, LFound: Boolean;
  LDeclHit: TPasRefHit;
  LHits: TArray<TPasRefHit>;
begin
  try
    if not Assigned(AView) then
      Exit;

    LCursorFile := AView.Buffer.FileName;
    LCursorPos := AView.Buffer.EditPosition;
    LRow := LCursorPos.Row;
    LCol := LCursorPos.Column;

    LProject := GetActiveProject;
    if not Assigned(LProject) then
    begin
      (BorlandIDEServices as INTAIDEUIServices).MessageDlg(
        'No active project.', mtInformation, [mbOK], -1);
      Exit;
    end;

    LUnits := GatherOpenUnitOverrides;
    LSearchPaths := CollectSearchPaths(ExtractFilePath(LProject.FileName), LUnits);
    LMainFile := ResolveMainSourceFile(LProject);
    LogDiagnostic(Format('PasTree Find References: starting - %d open unit(s) overlaid, '
      + '%d search path(s), platform=%s, main file=%s',
      [Length(LUnits), Length(LSearchPaths), LProject.CurrentPlatform, LMainFile]));

    LSema := TPasSemaProject.Create(MapPlatform(LProject.CurrentPlatform), LSearchPaths, []);
    try
      // Run every analysis stage on this (the IDE's main) thread instead of
      // TPasSemaProject's default one-worker-per-core pool. We're calling
      // this synchronously from the UI thread; if any worker ever needs to
      // get back onto the main thread (Synchronize/Queue) while the main
      // thread is sitting here blocked waiting for the pool, that's a
      // deadlock - "click and nothing ever happens again" is exactly what
      // that looks like from the outside. Multi-threaded is only safe to
      // reintroduce once this runs off the UI thread (see the out-of-process
      // architecture note at the top of this unit).
      LSema.SingleThreaded := True;

      for LUnit in LUnits do
        LSema.SetBuffer(LUnit.FileName, LUnit.Text);

      LSema.AnalyzeProject(LMainFile);
      LogDiagnostic('PasTree Find References: analysis finished, resolving cursor position...');

      LNav := TPasNavigator.Create(LSema);
      try
        LMid := LNav.ModelIdOf(LCursorFile);
        if LMid < 0 then
        begin
          LogDiagnostic(Format('PasTree Find References: "%s" was not part of '
            + 'the analyzed project (check the Build tab for parse errors).', [LCursorFile]));
          Exit;
        end;

        LFound := True;
        LHasDecl := False;
        if LNav.SymbolAt(LMid, LRow, LCol, LTMid, LSym, LName) then
        begin
          LHasDecl := LNav.DeclHit(LTMid, LSym, LDeclHit);
          LHits := LNav.FindReferences(LTMid, LSym);
        end
        else if LNav.UnitAt(LMid, LRow, LCol, LTargetMid, LName) then
        begin
          LHasDecl := LNav.UnitDeclHit(LTargetMid, LDeclHit);
          LHits := LNav.FindUnitReferences(LTargetMid);
        end
        else if LNav.BuiltinNameAt(LMid, LRow, LCol, LName) then
          LHits := LNav.FindBuiltinReferences(LName)
        else
          LFound := False;

        if not LFound then
          (BorlandIDEServices as INTAIDEUIServices).MessageDlg(
            'No identifier under the cursor.', mtInformation, [mbOK], -1)
        else
          ReportHits(LName, LHasDecl, LDeclHit, LHits);
      finally
        LNav.Free;
      end;
    finally
      LSema.Free;
    end;
  except
    // Scaffold diagnostics: surface the real exception in the Messages panel
    // instead of letting an unhandled one pop the IDE's generic "Error"
    // dialog with no context. Remove once the pipeline is stable.
    on E: Exception do
      LogDiagnostic(Format('PasTree Find References: unhandled %s: %s', [E.ClassName, E.Message]));
  end;
end;

end.
