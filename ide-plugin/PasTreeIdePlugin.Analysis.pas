unit PasTreeIdePlugin.Analysis;

{
  Shared PasTree analysis plumbing, used by both
  PasTreeIdePlugin.FindReferences (editor menu) and
  PasTreeIdePlugin.GotoDeclaration (Ctrl+Click override) - both need the
  exact same "build a TPasNavigator for whatever the active project
  currently looks like" pipeline, just to ask it a different question
  afterwards. Extracted here rather than duplicated once a second feature
  needed it.

  See PasTreeIdePlugin.FindReferences's own unit header for the fuller
  architecture note (in-process/Win32/PoC, out-of-process Win64 helper
  intended later) - it applies equally here, unchanged.

  Caching (BuildNavigator): the built TPasSemaProject/TPasNavigator pair is
  kept alive across calls in a package-lifetime cache (GCache*), instead of
  being rebuilt from scratch on every menu click / every Ctrl+Click - a full
  reparse of the whole project (now including RTL/VCL search paths) on
  every single Ctrl+Click was the whole point of adding this. Invalidation
  is content-based, not time-based: on each call, GatherOpenUnitOverrides
  runs as before (cheap - a handful of open files) and its result is
  compared against the last-cached snapshot; the expensive rebuild only
  happens if the active project changed or any open unit's text differs.
  KNOWN GAP: changes to files that aren't open in an editor tab (edited
  externally, or added/removed from the project on disk) are NOT detected -
  the cache has no file-system watcher. Acceptable for now since RTL/VCL
  essentially never changes mid-session and other project files not open
  in a tab rarely change without going through the editor too; revisit if
  that turns out to be wrong in practice.
}

interface

uses
  ToolsAPI, PasTree.Platforms, PasTree.Sema.Project, PasTree.Sema.Nav;

type
  TUnitSource = record
    FileName: string;
    Text: string;
  end;

/// <summary>
/// The IDE's currently active project, or nil if none.
/// </summary>
function GetActiveProject: IOTAProject;

/// <summary>
/// Live buffer text of every currently-open Pascal unit, IDE-wide (not
/// forced open - see this unit's implementation comment on ReadUnitText for
/// why forcing modules open is avoided). These are overlaid onto the
/// analyzed project via SetBuffer so unsaved edits are picked up; everything
/// else is read from disk by TPasSemaProject itself.
/// </summary>
function GatherOpenUnitOverrides: TArray<TUnitSource>;

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

/// <summary>
/// Maps an IOTAProject.CurrentPlatform platform id (see PlatformConst.pas -
/// cWin32Platform, cWin64Platform, ...) to the closest TPasPlatform PasTree
/// understands. PasTree doesn't model every RAD Studio target (no ARM64EC,
/// no 32-bit non-Windows) - those fall back to the nearest 64-bit equivalent,
/// and anything unrecognized falls back to pfWin32.
/// </summary>
function MapPlatform(const APlatformId: string): TPasPlatform;

/// <summary>
/// RE-ENABLED (2026-08-15, re-test after a confirmed-clean IDE restart) -
/// see CollectSearchPaths' own comment at its call site for the real risk
/// (a concurrency bug possibly in PasTree.SourceManager, not just this
/// package). If it AVs again after a clean restart, disable this call again
/// and treat it as evidence for the PasTree-side bug (project memory:
/// pastree-rtl-vcl-scale-av-suspect), not another hot-reload artifact.
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

/// <summary>
/// Distinct directories from the active project's own location and every
/// currently-open unit - in first-seen order. TPasSourceManager scans each
/// entry's whole subtree, so the project's own root alone usually covers
/// units that aren't open at all.
/// </summary>
function CollectSearchPaths(const AProjectDir: string; const AOpenUnits: TArray<TUnitSource>): TArray<string>;

/// <summary>
/// Builds (or reuses a cached) TPasSemaProject (analyzed) + TPasNavigator
/// for AProject. Cached across calls - see the "Caching" section of this
/// unit's header - and rebuilt only when the active project or the live
/// text of any open unit has actually changed since last time. The result
/// is OWNED BY THE CACHE, not the caller: do NOT free ASemaProject or the
/// returned TPasNavigator - they stay alive until the next invalidating
/// call, or until FinalizeAnalysisCache runs at package unload.
/// AMainFile receives the resolved real source file (see
/// ResolveMainSourceFile) that was actually analyzed, for diagnostics.
/// </summary>
function BuildNavigator(const AProject: IOTAProject; out ASemaProject: TPasSemaProject;
  out AMainFile: string): TPasNavigator;

/// <summary>
/// Frees the cached TPasSemaProject/TPasNavigator, if any. Call once, from
/// PasTreeIdePlugin.Wizard's TIDEWizard.Destroy, before the package unloads
/// - same reason the editor local menu's action list and the Ctrl+Click
/// notifier must be torn down there too.
/// </summary>
procedure FinalizeAnalysisCache;

implementation

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Generics.Collections,
  Winapi.ActiveX, IStreams, PlatformConst;

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
  // used the legacy IOTAEditReader.GetText loop instead, which triggered
  // heap/stack corruption (an access violation showing up much later, in
  // unrelated IDE code, on the *next* menu click) - GetText's Count-
  // respecting behavior is apparently not safe to assume here. Do not
  // reintroduce IOTAEditReader for this without re-verifying against the
  // official samples first.
  //
  // AModule is expected to already be open (came from IOTAModuleServices'
  // already-open-modules list) - no .OpenModule call here. Forcing a module
  // open (an earlier version did, via IOTAModuleInfo.OpenModule over every
  // unit belonging to the project) makes the IDE instantiate a form/data
  // module's design surface if it wasn't open yet, which flickers every such
  // form's designer open and shut.
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
        // Swallow per-unit read failures here - this is shared plumbing with
        // no single "right" place to report them; callers see a shorter
        // overlay list than expected, which is a safe degradation (that unit
        // just gets read from disk by TPasSemaProject instead).
      end;
    end;
    Result := LUnits.ToArray;
  finally
    LUnits.Free;
  end;
end;

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
    // RE-ENABLED 2026-08-15 for a re-test: the AV that got this disabled
    // might have been the separately-confirmed package-hot-reload issue
    // (see project memory) rather than a real PasTree bug - retesting after
    // a full IDE restart this time to tell the two apart. Real risk either
    // way: TPasSemaProject.SingleThreaded only gates the CPU parse workers
    // (ForEachIndex) - FSM.Prefetch (PasTree.Sema.Project.pas:2716) runs its
    // own concurrent I/O on the default thread pool unconditionally, and a
    // 2026-08-15 memory audit flagged unsynchronized FSearchIndex/DirIndex
    // lazy-init and FContentCache access in PasTree.SourceManager.pas as
    // concrete suspects - exactly the kind of race that would only surface
    // at RTL/VCL scale. If this AVs again after a clean restart, that's
    // real evidence for a genuine PasTree-side bug, not just stale-package
    // noise - see pastree-rtl-vcl-scale-av-suspect (project memory) for the
    // standalone-repro plan if so.
    for LDir in GetIDESourcePaths do
      AddDir(LDir);
    Result := LList.ToArray;
  finally
    LList.Free;
    LSeen.Free;
  end;
end;

var
  // Package-lifetime cache for BuildNavigator - see the unit header
  // ("Caching") for why and its known gap. GCacheProject uses plain
  // interface (=) comparison, i.e. pointer identity: "is this literally the
  // same project object as last time", which is what we want to detect a
  // project switch - IOTAProject implementations are stable per project for
  // the life of the IDE session, they don't get re-wrapped on repeat
  // .ActiveProject calls.
  GCacheProject: IOTAProject;
  GCacheUnits: TArray<TUnitSource>;
  GCacheMainFile: string;
  GCacheSemaProject: TPasSemaProject;
  GCacheNavigator: TPasNavigator;

/// <summary>
/// True if both unit-text snapshots are the same set of (filename, text)
/// pairs, regardless of order (open-tab order isn't a meaningful signal of
/// "something changed" on its own).
/// </summary>
function SameUnits(const A, B: TArray<TUnitSource>): Boolean;
var
  LMap: TDictionary<string, string>;
  LUnit: TUnitSource;
  LExisting: string;
begin
  if Length(A) <> Length(B) then
    Exit(False);

  LMap := TDictionary<string, string>.Create;
  try
    for LUnit in A do
      LMap.AddOrSetValue(LowerCase(LUnit.FileName), LUnit.Text);
    for LUnit in B do
    begin
      if not LMap.TryGetValue(LowerCase(LUnit.FileName), LExisting) then
        Exit(False);
      if LExisting <> LUnit.Text then
        Exit(False);
    end;
    Result := True;
  finally
    LMap.Free;
  end;
end;

procedure FinalizeAnalysisCache;
begin
  FreeAndNil(GCacheNavigator);
  FreeAndNil(GCacheSemaProject);
  GCacheProject := nil;
  GCacheUnits := nil;
  GCacheMainFile := '';
end;

function BuildNavigator(const AProject: IOTAProject; out ASemaProject: TPasSemaProject;
  out AMainFile: string): TPasNavigator;
var
  LUnits: TArray<TUnitSource>;
  LUnit: TUnitSource;
  LSearchPaths: TArray<string>;
begin
  LUnits := GatherOpenUnitOverrides;

  if Assigned(GCacheNavigator) and (GCacheProject = AProject) and SameUnits(GCacheUnits, LUnits) then
  begin
    ASemaProject := GCacheSemaProject;
    AMainFile := GCacheMainFile;
    Exit(GCacheNavigator);
  end;

  // Cache miss (first call, project switched, or an open unit's text
  // changed) - discard whatever was cached before building fresh.
  FinalizeAnalysisCache;

  LSearchPaths := CollectSearchPaths(ExtractFilePath(AProject.FileName), LUnits);
  AMainFile := ResolveMainSourceFile(AProject);

  ASemaProject := TPasSemaProject.Create(MapPlatform(AProject.CurrentPlatform), LSearchPaths, []);
  try
    // Run every analysis stage on this (the IDE's main) thread instead of
    // TPasSemaProject's default one-worker-per-core pool. Callers invoke
    // this synchronously from the UI thread; if any worker ever needs to
    // get back onto the main thread (Synchronize/Queue) while the main
    // thread is sitting here blocked waiting for the pool, that's a
    // deadlock - "click and nothing ever happens again" is exactly what
    // that looks like from the outside. Multi-threaded is only safe to
    // reintroduce once this runs off the UI thread (see the out-of-process
    // architecture note in PasTreeIdePlugin.FindReferences's unit header).
    ASemaProject.SingleThreaded := True;

    for LUnit in LUnits do
      ASemaProject.SetBuffer(LUnit.FileName, LUnit.Text);

    ASemaProject.AnalyzeProject(AMainFile);

    Result := TPasNavigator.Create(ASemaProject);
  except
    ASemaProject.Free;
    ASemaProject := nil;
    raise;
  end;

  // Cache the freshly built pair for the next call.
  GCacheProject := AProject;
  GCacheUnits := LUnits;
  GCacheMainFile := AMainFile;
  GCacheSemaProject := ASemaProject;
  GCacheNavigator := Result;
end;

end.
