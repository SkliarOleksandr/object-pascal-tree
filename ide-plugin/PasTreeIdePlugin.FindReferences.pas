unit PasTreeIdePlugin.FindReferences;

{
  Find References entry point, wired to the "Find References (PasTree)" editor
  menu item (see PasTreeIdePlugin.Wizard).

  Current state: PoC. Runs PasTree's real TPasSemaProject/TPasNavigator
  in-process, inside this (Win32) designtime package. Deliberately NOT
  out-of-process yet - see the architecture note below.

    - ExecuteFindReferences calls PasTreeIdePlugin.Analysis.BuildNavigator
      (shared with PasTreeIdePlugin.GotoDeclaration - see that unit's own
      header for the Ctrl+Click override), then uses TPasNavigator's
      three-identity lookup (symbol / unit / builtin - see
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
    1. Move analysis out-of-process (Win64 helper) once ready to test against
       the real target project - see the architecture note above.
    2. Read the project's actual $DEFINEs (e.g. from .dproj DCC_Define) and
       pass them as TPasSemaProject's AExtraDefines instead of the empty
       array used now.
    3. Highlight the matched identifier within each hit's snippet text
       (TPasRefHit.HiFrom/HiTo already carry the offsets - same field the
       demo's own MakeFindRefDisplay uses). AddToolMessage draws plain text
       only; doing this means a message class implementing
       IOTACustomMessage100 (for FileName/Line/Col + navigation) and
       INTACustomDrawMessage (Draw/CalcRect on a TCanvas - ToolsAPI.pas:6335)
       together, registered via AddCustomMessage instead of AddToolMessage.
       Deliberately deferred - real code, not wired up, for a cosmetic-only
       improvement at this PoC stage.

  DONE (2026-08-15): TPasSemaProject/TPasNavigator are now cached across
  calls instead of rebuilt from scratch on every click - see
  PasTreeIdePlugin.Analysis's "Caching" note. BuildNavigator's result is
  cache-owned; this unit no longer frees LNav/LSema itself.
}

interface

uses
  ToolsAPI;

/// <summary>
/// Entry point called from the editor's local menu action.
/// </summary>
procedure ExecuteFindReferences(const AView: IOTAEditView);

/// <summary>
/// Removes the "Find References" Messages tab. Call once (from
/// PasTreeIdePlugin.Wizard's TIDEWizard.Destroy) so the group doesn't
/// persist forever across package reinstalls - see the field comment on
/// GMessageGroup in the implementation section for why this is hygiene,
/// not something suspected of causing the reinstall AVs.
/// </summary>
procedure FinalizeFindReferencesMessageGroup;

implementation

uses
  System.SysUtils, System.Generics.Collections, Vcl.Dialogs,
  ToolsAPI.UI, PasTree.Sema.Project, PasTree.Sema.Nav, PasTreeIdePlugin.Analysis;

const
  cMessageGroupName = 'Find References';

var
  // Held so FinalizeFindReferencesMessageGroup can remove it on package
  // unload - a plain data container (no code pointers back into us), so its
  // leaking across a hot-reinstall was never itself a crash risk, just an
  // orphaned IDE resource. Fixed for hygiene, not because it was suspected
  // of causing the AVs - see PasTreeIdePlugin.GotoDeclaration's own header
  // for that (unrelated) investigation.
  GMessageGroup: IOTAMessageGroup;

function GetOrCreateMessageGroup(const AMessageServices: IOTAMessageServices): IOTAMessageGroup;
begin
  if not Assigned(GMessageGroup) then
    GMessageGroup := AMessageServices.GetGroup(cMessageGroupName);
  if not Assigned(GMessageGroup) then
    GMessageGroup := AMessageServices.AddMessageGroup(cMessageGroupName);
  Result := GMessageGroup;
end;

procedure FinalizeFindReferencesMessageGroup;
var
  LMessageServices: IOTAMessageServices;
begin
  if Assigned(GMessageGroup) and Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.RemoveMessageGroup(GMessageGroup);
  GMessageGroup := nil;
end;

/// <summary>
/// Diagnostics/errors/progress - as opposed to actual results (ReportHits) -
/// go to the IDE's own default Messages tab (nil group = the "Build" tab,
/// where compiler output already lives) rather than our own "Find
/// References" tab, so they're where a developer would already be looking
/// and not competing for space with the actual reference list. Tagged with
/// "[pastree]" to stay identifiable alongside compiler/linker noise.
/// </summary>
procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
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

    // BuildNavigator's result is cache-owned (see PasTreeIdePlugin.Analysis
    // - "Caching") - do not free LNav/LSema, they outlive this call.
    LNav := BuildNavigator(LProject, LSema, LMainFile);

    LMid := LNav.ModelIdOf(LCursorFile);
    if LMid < 0 then
    begin
      LogDiagnostic(Format('Find References: "%s" was not part of '
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
  except
    // Scaffold diagnostics: surface the real exception in the Messages panel
    // instead of letting an unhandled one pop the IDE's generic "Error"
    // dialog with no context. Remove once the pipeline is stable.
    on E: Exception do
      LogDiagnostic(Format('Find References: unhandled %s: %s', [E.ClassName, E.Message]));
  end;
end;

end.
