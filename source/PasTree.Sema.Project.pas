unit PasTree.Sema.Project;

{
  PasTree semantics — Phase 2 project driver: resolves `uses` to real units,
  indexes their interface symbols, re-resolves each unit's external references
  against them, and emits E2003 for genuinely undeclared identifiers.

  Per-unit models (Phase 1) are kept as-is; a cross-unit resolution is recorded
  in the referring model's ExtRefMap as (unitId, symbolId). E2003 is emitted
  only when every `uses` unit of the referring unit resolved (AllUsesResolved),
  so an unindexable import never yields a false undeclared-identifier.

  Phase 3c adds cross-model TYPING on top: BindTypesX resolves declared types
  that live in another unit (and generic instantiations, deduped in the
  project-owned instance table), CrossType then types expressions the
  intra-unit typer could not — Var.Field across units, member access through
  ancestor chains and type aliases, constructor calls, and generic-parameter
  substitution (TList<Integer>.First -> Integer). This pass records types and
  member references only; it emits NO diagnostics (typing for navigation and
  dumps, never a new error source).
}

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.Generics.Collections,
  PasTree.Preprocessor,
  PasTree.Platforms,
  PasTree.SourceManager,
  PasTree.Ast,
  PasTree.Sema.Model;

type
  // One generic instantiation: a generic type symbol + positional actual
  // args. Args may themselves reference skGenericParam symbols (an "open"
  // instantiation inside another generic's body, e.g. TEnumerator<T> inside
  // TList<T>) — those close over the outer instance on substitution.
  TSemaInstance = record
    UnitId: Integer;            // model id of the generic type symbol
    Sym: Integer;               // the skType symbol of the generic
    Args: TArray<TSemaXType>;
  end;

  // One deferred ExtRefMap write from the inherited-member pass (computed in
  // parallel, committed sequentially — see CrossResolveInherited).
  TPasInhPending = record
    Node: Integer;
    Ext: TPasExtRef;
  end;

  // Progress of a staged (incremental) analysis, reported to AnalyzeStaged's
  // callback after each step. Total GROWS as the uses closure is discovered
  // (a module's dependencies aren't known until it is parsed), so a UI shows
  // "done/total" with a moving total — as designed.
  TPasStagedProgress = record
    Total: Integer;      // modules discovered so far
    IntfDone: Integer;   // modules that reached at least msIntfReady
    FullDone: Integer;   // modules that reached at least msFullReady
    Phase: string;       // 'intf' | 'full' | 'cross' | 'done' | 'cancelled'
  end;

  TPasSemaProject = class
  private
    FPlatform: TPasPlatform;
    FInfo: TPasPlatformInfo;
    FSM: TPasSourceManager;
    FDefines: TPasDefines;
    FPP: TPasPreprocessor;
    FModels: TObjectList<TPasSemaModel>;
    FFiles: TList<string>;                 // parallel to FModels (full path)
    // Parallel to FModels: each model's pipeline status. Kept in lockstep by
    // RegisterModel (the only place a model is appended). The synchronous
    // drivers register models as msFullReady (LoadFile/LoadFilesParallel do a
    // full parse + Phase 1) and bump them to msCrossReady once the cross
    // passes have run. The async driver (later) uses the finer transitions.
    FStatus: TList<TPasModuleStatus>;
    FByPath: TDictionary<string, Integer>; // full path (lower) -> model id
    // Declared unit name (lower) -> model id, registered as files load. The
    // dcc rule this serves: a program's `uses X in 'path'` locates X for the
    // WHOLE project — other units say just `uses X` with the file nowhere on
    // any search path (the demo's own .dproj has no UnitSearchPath at all).
    FByUnitName: TDictionary<string, Integer>;
    FNamespaces: TArray<string>;           // own copy for LoadedUnitByName
    FStageTimings: string;                 // see StageTimings
    FSingleThreaded: Boolean;
    FSystemUnitId: Integer;                // memoized EnsureSystemUnit result
    FSystemUnitResolved: Boolean;
    FSysInitUnitId: Integer;               // memoized EnsureSysInitUnit result
    FSysInitUnitResolved: Boolean;
    // Guards EnsureSystemUnit AND EnsureSysInitUnit (both mutate the same
    // shared FModels/FByPath via LoadFile, so must exclude each other too,
    // not just themselves): unlike ResolveUses (always sequential) and
    // CrossType/BindTypesX (deliberately sequential — see the Phase 3c
    // comment above), CrossResolve runs ONE WORKER PER CORE by default
    // (ForEachIndex) and is the only caller of either Ensure*Unit that can
    // race — several units' CrossResolve can hit an unresolved implicit-
    // System name (e.g. sLineBreak) on different threads at the same
    // instant, all racing the SAME first-time LoadFile (which mutates the
    // shared FModels/FByPath, neither thread-safe) — real, not
    // hypothetical: reproduced via SemaProjectSmoke's UnitE fixture.
    FSystemUnitLock: TCriticalSection;
    // Phase 3c: cross-model typing.
    FInstances: TList<TSemaInstance>;
    FInstKeys: TDictionary<string, Integer>;
    // Guards ALL FInstances/FInstKeys access: the parallel inherited-member
    // pass instantiates generics from heritage clauses concurrently (see
    // Instantiate); a bare TList read during another thread's Add is unsafe.
    FInstLock: TCriticalSection;
    // Runs ABody for 0..AHi — one worker per core, or a plain loop when
    // SingleThreaded (baseline emulation / timing comparison / debugging).
    procedure ForEachIndex(AHi: Integer; const ABody: TProc<Integer>);
    // Appends a model + its initial status, keeping FModels/FFiles/FStatus in
    // lockstep. Returns the new model id.
    function RegisterModel(AModel: TPasSemaModel; const AFullPath: string;
      AStatus: TPasModuleStatus): Integer;
    procedure SetModuleStatus(AId: Integer; AStatus: TPasModuleStatus);
    // Bumps every currently loaded model to at least msCrossReady (called by
    // the synchronous drivers once their cross passes have completed).
    procedure MarkAllCrossReady;
    function LoadFile(const APath: string): Integer;
    procedure LoadFilesParallel(const APaths: TArray<string>;
      AInterfaceOnly: Boolean = False);
    procedure RegisterUnitName(AId: Integer);
    function LoadedUnitByName(const AName: string): Integer;
    procedure ResolveUses(AId: Integer);
    procedure CrossResolve(AId: Integer);
    function StructSymOfNode(AModel: TPasSemaModel; ANode: Integer): Integer;
    procedure CrossResolveInherited(AId: Integer;
      var APending: TArray<TPasInhPending>);
    procedure RunInheritedPass(ACount: Integer);
    function FindInUses(AId: Integer; const ANameLower: string;
      out AUnit, ASym: Integer): Boolean;
    function FindInSystemUnit(const ANameLower: string;
      out AUnit, ASym: Integer): Boolean;
    function FindInSysInitUnit(const ANameLower: string;
      out AUnit, ASym: Integer): Boolean;
    function IsAttributeTypeRef(AModel: TPasSemaModel; ANode: Integer): Boolean;
    function UsesUnitOf(AId, ASym: Integer): Integer;
    function LocalHead(AModel: TPasSemaModel; ANode: Integer): Integer;
    function QualifiedText(AId, ANode: Integer): string;
    function UnitNameOf(AId, ANode: Integer): Integer;
    procedure EmitE2003(AModel: TPasSemaModel; ANode: Integer);
    procedure EmitAt(AModel: TPasSemaModel; ANode: Integer;
      const ACode, AMsg: string);
    function RoutineArity(AMid, ASym: Integer; out AReq, ATot: Integer;
      out AVariadic: Boolean): Boolean;
    procedure CheckCalls(AId: Integer);
    // Phase 3c: cross-model typing.
    function Instantiate(const ABase: TSemaXType;
      const AArgs: TArray<TSemaXType>): Integer;
    function InstanceRead(AInst: Integer): TSemaInstance;
    function TypeDefNodeOf(AMid, ASym: Integer): Integer;
    function GenericParamIdents(AMid, ASym: Integer): TArray<Integer>;
    function DeclTypeX(AMid, ASym: Integer): TSemaXType;
    function SubstX(const AX: TSemaXType; AInst, ADepth: Integer): TSemaXType;
    function ResolveTypeExpr(AId, ANode: Integer): TSemaXType;
    function FindMemberX(const ABase: TSemaXType; const ANameLower: string;
      out AMemMid, AMemSym: Integer; out ACtx: Integer): Boolean;
    function IsConstructorSym(AMid, ASym: Integer): Boolean;
    // Cross-model overload selection (CrossType's call typing):
    function XCatOf(const AX: TSemaXType): TSemaTypeCat;
    function XSameType(const A, B: TSemaXType): Boolean;
    function XAssignableX(const ADst, ASrc: TSemaXType): Boolean;
    function XParamSyms(AMid, ASym: Integer): TArray<Integer>;
    procedure BindTypesX(AId: Integer);
    procedure CrossType(AId: Integer);
  public
    constructor Create(APlatform: TPasPlatform;
      const ASearchPaths: TArray<string>; const AExtraDefines: TArray<string>);
    destructor Destroy; override;
    // True = run every stage on the calling thread (emulates the sequential
    // driver exactly; results are identical either way — the parallel stages
    // are pure per unit). Default False (one worker per core).
    property SingleThreaded: Boolean read FSingleThreaded write FSingleThreaded;
    { Editor-host buffer override: analysis reads AText for APath instead of
      the file on disk (for unsaved editor content). Call BEFORE AnalyzeFile/
      AnalyzeDirectory — LoadFile reads at analysis time. }
    procedure SetBuffer(const APath, AText: string);
    { Unit-scope namespaces (dcc -NS / DCC_Namespace) and unit aliases
      (dcc -A / DCC_UnitAlias), forwarded to the source manager's unit-name
      resolution. Set BEFORE analyzing. }
    procedure SetNamespaces(const ANamespaces: TArray<string>);
    procedure AddUnitAlias(const AAlias, AReal: string);
    { Resolves and loads the real `System` unit on demand (memoized; -1 if it
      cannot be found via the configured search paths). EVERY unit implicitly
      uses System (11.2.1 / 1.2.1) without a `uses` clause naming it, so it
      never appears in any model's UsesList and the normal name-resolution
      machinery (Phase 1/2, which decides RefMap/ExtRefMap/diagnostics) never
      reaches it — that stays exactly as before, no behavior change there.
      Used by ResolveRealDecl below, itself used by FindMemberX (so member
      access through a compiler-seeded builtin type, e.g. `Obj.Free` where
      Obj: TObject, can reach the real class body) and by PasTree.Sema.Nav
      (go-to-declaration for a builtin name that is really declared
      somewhere — TBytes/SysUtils, TObject/System, ...). Never emits a
      diagnostic and never affects RefMap/ExtRefMap for genuinely intra- or
      cross-unit names — purely additive reach for names that would
      otherwise dead-end at a DeclNode-less compiler symbol. }
    function EnsureSystemUnit: Integer;
    { SysInit is, like System, implicitly visible to every OTHER unit with no
      `uses` entry at all (dcc-verified: a unit with an EMPTY uses clause
      still resolves bare `HInstance`/`ModuleIsLib` — SysInit-only globals,
      not System's). Same memoize-and-lock shape as EnsureSystemUnit, same
      race (see FSystemUnitLock), reusing that lock rather than a second
      one since both mutate the same shared FModels/FByPath. }
    function EnsureSysInitUnit: Integer;
    { A real (non-builtin) declaration of ANameLower reachable from AMid:
      first AMid's own `uses` (last-uses-wins, matching normal resolution
      priority), then the implicit System unit as a last resort. }
    function ResolveRealDecl(AMid: Integer; const ANameLower: string;
      out ARMid, ARSym: Integer): Boolean;
    { ANode's enclosing namespace-qualifier prefix (System/SysUtils in
      System.SysUtils.TBytes), if any: the unit's model id (-1 if none), with
      AMatchNode set to the node whose OWN span is exactly the qualifier text
      (excludes the trailing member). PasTree.Sema.Nav uses this so hovering/
      clicking the QUALIFIER itself opens that unit, not just its member. }
    function QualifierUnitAt(AId, ANode: Integer;
      out AMatchNode: Integer): Integer;
    { Per-stage wall-clock of the LAST AnalyzeProject/AnalyzeDirectory/
      AnalyzeStaged run ('stage=ms;...') — for perf logging in hosts and
      probes. Empty for AnalyzeFile. }
    function StageTimings: string;
    function ModelCount: Integer;
    function Model(AId: Integer): TPasSemaModel;
    function ModelFile(AId: Integer): string;
    { A module's current pipeline status (msQueued if AId is out of range). }
    function ModuleStatus(AId: Integer): TPasModuleStatus;
    { Non-blocking snapshot fetch for UI/consumers: returns the model at AId
      only if it has reached at least AMinStatus, else False (AModel := nil).
      The UI must NEVER block waiting for analysis — it calls this and, on
      False, disables the action / no-ops the hover. In the synchronous
      drivers every model is msCrossReady by the time anyone can call this, so
      it always succeeds; the gate matters once analysis runs in the
      background. }
    function TryGetSnapshot(AId: Integer; AMinStatus: TPasModuleStatus;
      out AModel: TPasSemaModel): Boolean;
    function InstanceCount: Integer;
    function Instance(AInst: Integer): TSemaInstance;
    // 'TList<Integer>'-style rendering of a cross-model type (for dumps/tests).
    function XTypeText(const AX: TSemaXType): string;
    // Analyze one unit + its direct uses; returns the main unit's model id.
    function AnalyzeFile(const AMainFile: string): Integer;
    { Analyze a whole PROJECT from its main source: loads the TRANSITIVE
      uses closure and runs the cross passes (CrossResolve/CheckCalls/
      BindTypesX/CrossType) on EVERY loaded unit — not just the main file
      (AnalyzeFile's narrower contract, kept for tools). This is what an
      editor host needs for go-to-declaration to work INSIDE dependency
      units: without it a dependency only gets Phase 1 (no ExtRefMap at
      all). Returns the main unit's model id. }
    function AnalyzeProject(const AMainFile: string): Integer;
    // Analyze every .pas/.dpr under a directory (indexed first).
    procedure AnalyzeDirectory(const ARoot: string);
    { Incremental analysis of ARoots' transitive uses closure, in two waves —
      wave 1 parses every reachable module INTERFACE-ONLY (msIntfReady: enough
      for navigation INTO it), wave 2 upgrades each to a full parse
      (msFullReady, revealing implementation-only dependencies), then a
      finalizer runs the cross passes (msCrossReady). APriority names files to
      front-load (the open editor module + its direct uses) so they reach
      readiness first. ACancelled is polled between modules/waves — on True the
      call returns early leaving whatever completed published (partial but
      consistent). AOnProgress reports a growing done/total after each step.
      Returns the model id of ARoots[0], or -1.

      The FINAL state (models + diagnostics + cross-refs) is equivalent to
      AnalyzeProject over the same closure; the interface wave is a transient
      early-usability optimization. This method carries no threads of its own
      — TPasAsyncSession runs it on a background thread; a caller using it
      directly (tests, headless) gets a deterministic staged build. }
    function AnalyzeStaged(const ARoots, APriority: TArray<string>;
      const ACancelled: TFunc<Boolean> = nil;
      const AOnProgress: TProc<TPasStagedProgress> = nil): Integer;
  end;

implementation

uses
  System.IOUtils,
  System.Threading,
  System.Diagnostics,
  PasTree.Parser,
  PasTree.Sema.Resolver,
  PasTree.Sema.Diagnostics;

constructor TPasSemaProject.Create(APlatform: TPasPlatform;
  const ASearchPaths: TArray<string>; const AExtraDefines: TArray<string>);
var
  LName: string;
begin
  inherited Create;
  FPlatform := APlatform;
  FInfo := PlatformInfo(APlatform);
  FSM := TPasSourceManager.Create(ASearchPaths);
  FDefines := CreatePlatformDefines(APlatform);
  for LName in AExtraDefines do
    FDefines.Define(LName);
  FPP := TPasPreprocessor.Create(FSM, FDefines, 37.0, FInfo.PointerBytes,
    FInfo.ExtendedBytes);
  FModels := TObjectList<TPasSemaModel>.Create(True);
  FFiles := TList<string>.Create;
  FStatus := TList<TPasModuleStatus>.Create;
  FByPath := TDictionary<string, Integer>.Create;
  FInstances := TList<TSemaInstance>.Create;
  FInstKeys := TDictionary<string, Integer>.Create;
  FInstLock := TCriticalSection.Create;
  FSystemUnitId := -1;
  FSystemUnitResolved := False;
  FSysInitUnitId := -1;
  FSysInitUnitResolved := False;
  FSystemUnitLock := TCriticalSection.Create;
end;

destructor TPasSemaProject.Destroy;
begin
  FByUnitName.Free;
  FSystemUnitLock.Free;
  FInstLock.Free;
  FInstKeys.Free;
  FInstances.Free;
  FByPath.Free;
  FFiles.Free;
  FStatus.Free;
  FModels.Free;
  FPP.Free;
  FDefines.Free;
  FSM.Free;
  inherited;
end;

procedure TPasSemaProject.ForEachIndex(AHi: Integer;
  const ABody: TProc<Integer>);
var
  LIdx: Integer;
begin
  if FSingleThreaded then
    for LIdx := 0 to AHi do
      ABody(LIdx)
  else
    TParallel.&For(0, AHi, ABody);
end;

procedure TPasSemaProject.SetBuffer(const APath, AText: string);
begin
  FSM.SetBuffer(APath, AText);
end;

procedure TPasSemaProject.SetNamespaces(const ANamespaces: TArray<string>);
begin
  FNamespaces := ANamespaces;
  FSM.SetNamespaces(ANamespaces);
end;

procedure TPasSemaProject.AddUnitAlias(const AAlias, AReal: string);
begin
  FSM.AddUnitAlias(AAlias, AReal);
end;

function TPasSemaProject.EnsureSystemUnit: Integer;
var
  LPath: string;
begin
  // Locked unconditionally (no unlocked fast-path read of FSystemUnitResolved)
  // — this is called only for identifiers that missed local/explicit-uses
  // resolution, never once per token, so the lock is not a hot-path cost; a
  // "check outside, lock, check again" version would just reintroduce the
  // exact race this exists to fix, for a saving that doesn't matter here.
  FSystemUnitLock.Enter;
  try
    if not FSystemUnitResolved then
    begin
      FSystemUnitResolved := True;
      if FSM.ResolveUnit('System', '', '', LPath) then
        FSystemUnitId := LoadFile(LPath);
    end;
    Result := FSystemUnitId;
  finally
    FSystemUnitLock.Leave;
  end;
end;

function TPasSemaProject.EnsureSysInitUnit: Integer;
var
  LPath: string;
begin
  FSystemUnitLock.Enter;
  try
    if not FSysInitUnitResolved then
    begin
      FSysInitUnitResolved := True;
      if FSM.ResolveUnit('SysInit', '', '', LPath) then
        FSysInitUnitId := LoadFile(LPath);
    end;
    Result := FSysInitUnitId;
  finally
    FSystemUnitLock.Leave;
  end;
end;

function TPasSemaProject.ResolveRealDecl(AMid: Integer;
  const ANameLower: string; out ARMid, ARSym: Integer): Boolean;
var
  LM, LUsed: TPasSemaModel;
  LIdx, LUid, LS: Integer;
begin
  Result := False;
  LM := FModels[AMid];
  for LIdx := High(LM.UsesList) downto 0 do   // last uses wins, like resolution
  begin
    LUid := LM.UsesList[LIdx].UnitId;
    if LUid < 0 then
      Continue;
    LUsed := FModels[LUid];
    if LUsed.InterfaceScope = NIL_SCOPE then
      Continue;
    LS := LUsed.Resolve(LUsed.InterfaceScope, ANameLower);
    if (LS <> NIL_SYM) and (LUsed.Symbols[LS].DeclNode <> NIL_NODE) then
    begin
      ARMid := LUid;
      ARSym := LS;
      Exit(True);
    end;
  end;

  LUid := EnsureSystemUnit;
  if (LUid >= 0) and (LUid <> AMid) then
  begin
    LUsed := FModels[LUid];
    if LUsed.InterfaceScope <> NIL_SCOPE then
    begin
      LS := LUsed.Resolve(LUsed.InterfaceScope, ANameLower);
      if (LS <> NIL_SYM) and (LUsed.Symbols[LS].DeclNode <> NIL_NODE) then
      begin
        ARMid := LUid;
        ARSym := LS;
        Exit(True);
      end;
    end;
  end;

  LUid := EnsureSysInitUnit;
  if (LUid >= 0) and (LUid <> AMid) then
  begin
    LUsed := FModels[LUid];
    if LUsed.InterfaceScope <> NIL_SCOPE then
    begin
      LS := LUsed.Resolve(LUsed.InterfaceScope, ANameLower);
      if (LS <> NIL_SYM) and (LUsed.Symbols[LS].DeclNode <> NIL_NODE) then
      begin
        ARMid := LUid;
        ARSym := LS;
        Exit(True);
      end;
    end;
  end;
end;

function TPasSemaProject.ModelCount: Integer;
begin
  Result := FModels.Count;
end;

function TPasSemaProject.Model(AId: Integer): TPasSemaModel;
begin
  Result := FModels[AId];
end;

function TPasSemaProject.ModelFile(AId: Integer): string;
begin
  Result := FFiles[AId];
end;

function TPasSemaProject.ModuleStatus(AId: Integer): TPasModuleStatus;
begin
  if (AId >= 0) and (AId < FStatus.Count) then
    Result := FStatus[AId]
  else
    Result := msQueued;
end;

function TPasSemaProject.TryGetSnapshot(AId: Integer;
  AMinStatus: TPasModuleStatus; out AModel: TPasSemaModel): Boolean;
begin
  Result := (AId >= 0) and (AId < FModels.Count) and
    (FStatus[AId] >= AMinStatus);
  if Result then
    AModel := FModels[AId]
  else
    AModel := nil;
end;

function TPasSemaProject.LoadFile(const APath: string): Integer;
var
  LFull, LKey: string;
  LPre: TPasPreprocessed;
  LDiags: TArray<TPasParseDiag>;
  LTree: TPasTree;
  LModel: TPasSemaModel;
begin
  LFull := TPath.GetFullPath(APath);
  LKey := LowerCase(LFull);
  if FByPath.TryGetValue(LKey, Result) then
    Exit;   // includes the -1 negative-cache sentinel for known-bad files
  if not TFile.Exists(LFull) then
    Exit(-1);
  try
    LPre := FPP.Process(LFull);
    LTree := TPasParser.ParseFile(LPre, LDiags);
    LModel := TPasSemaResolver.Analyze(LTree);
  except
    on Exception do
    begin
      // Tolerate a unit that fails to parse; treat as unresolvable — and
      // remember that, so repeated `uses` of it don't re-parse every time.
      FByPath.Add(LKey, -1);
      Exit(-1);
    end;
  end;
  // Full parse + Phase 1 done -> msFullReady (cross passes bump it later).
  Result := RegisterModel(LModel, LFull, msFullReady);
  FByPath.Add(LKey, Result);
  RegisterUnitName(Result);
end;

// Single point where a model is appended: keeps FModels/FFiles/FStatus in
// lockstep so a model id indexes all three.
function TPasSemaProject.RegisterModel(AModel: TPasSemaModel;
  const AFullPath: string; AStatus: TPasModuleStatus): Integer;
begin
  Result := FModels.Add(AModel);
  FFiles.Add(AFullPath);
  FStatus.Add(AStatus);
end;

procedure TPasSemaProject.SetModuleStatus(AId: Integer;
  AStatus: TPasModuleStatus);
begin
  if (AId >= 0) and (AId < FStatus.Count) then
    FStatus[AId] := AStatus;
end;

procedure TPasSemaProject.MarkAllCrossReady;
var
  LIdx: Integer;
begin
  for LIdx := 0 to FStatus.Count - 1 do
    if FStatus[LIdx] < msCrossReady then
      FStatus[LIdx] := msCrossReady;
end;

// Parse + Phase-1-analyze a batch of files with one worker per core, then
// register the results IN INPUT ORDER (deterministic model ids). Pure per
// file: each worker owns its preprocessor (which clones the shared defines
// per run); the source manager and define set are read-only during the loop —
// the same no-locks model as TPasProject.ParseFiles.
procedure TPasSemaProject.LoadFilesParallel(const APaths: TArray<string>;
  AInterfaceOnly: Boolean = False);
var
  LTodo: TArray<string>;
  LKeys: TArray<string>;
  LDone: TArray<TPasSemaModel>;
  LSeen: TDictionary<string, Boolean>;
  LIdx, LDummy: Integer;
  LFull, LKey: string;
  LStatus: TPasModuleStatus;
begin
  // Normalize, drop already-loaded/known-bad paths and in-batch duplicates.
  LTodo := nil;
  LKeys := nil;
  LSeen := TDictionary<string, Boolean>.Create;
  try
    for LIdx := 0 to High(APaths) do
    begin
      LFull := TPath.GetFullPath(APaths[LIdx]);
      LKey := LowerCase(LFull);
      if FByPath.TryGetValue(LKey, LDummy) or LSeen.ContainsKey(LKey) then
        Continue;
      if not TFile.Exists(LFull) then
        Continue;
      LSeen.Add(LKey, True);
      LTodo := LTodo + [LFull];
      LKeys := LKeys + [LKey];
    end;
  finally
    LSeen.Free;
  end;
  if LTodo = nil then
    Exit;

  // I/O first, CPU second: pull every file into the source manager's memory
  // repository with the deep I/O pool, so the per-core parse workers below
  // never stall on a COLD read (antivirus scan-on-first-touch dominates a
  // first-run analysis otherwise).
  FSM.Prefetch(LTodo);

  SetLength(LDone, Length(LTodo));
  ForEachIndex(High(LTodo),
    procedure(AIndex: Integer)
    var
      LPP: TPasPreprocessor;
      LPre: TPasPreprocessed;
      LDiags: TArray<TPasParseDiag>;
    begin
      LPP := TPasPreprocessor.Create(FSM, FDefines, 37.0, FInfo.PointerBytes,
        FInfo.ExtendedBytes);
      try
        try
          LPre := LPP.Process(LTodo[AIndex]);
          var LTree := TPasParser.ParseFile(LPre, LDiags, AInterfaceOnly);
          // A model whose parse really did stop at the interface is
          // TRANSIENT (replaced by the full wave) — skip the expression
          // typer, its ExprType/E2010/E2015 output dies with the model.
          // NOT keyed on AInterfaceOnly alone: a program/library/package
          // ignores the flag, parses fully, registers msFullReady below and
          // is never upgraded — skipping ITS typer would permanently lose
          // its type diagnostics.
          LDone[AIndex] := TPasSemaResolver.Analyze(LTree,
            {ASkipTyper} AInterfaceOnly and (Length(LTree.Nodes) > 0) and
            (LTree.Nodes[0].Kind = nkUnit));
        except
          on Exception do
            LDone[AIndex] := nil;   // registered as known-bad below
        end;
      finally
        LPP.Free;
      end;
    end);

  // Interface-only -> msIntfReady (later upgraded); full parse -> msFullReady.
  // Per item, not per batch: program/library/package files IGNORE
  // AInterfaceOnly (no interface section — ParseFile parses them fully), so
  // they register as already-full and wave 2 never pays a pointless reparse
  // for a .dpr/.dpk root.
  for LIdx := 0 to High(LTodo) do
    if LDone[LIdx] <> nil then
    begin
      if AInterfaceOnly and (Length(LDone[LIdx].Tree.Nodes) > 0) and
         (LDone[LIdx].Tree.Nodes[0].Kind = nkUnit) then
        LStatus := msIntfReady
      else
        LStatus := msFullReady;
      FByPath.Add(LKeys[LIdx],
        RegisterModel(LDone[LIdx], LTodo[LIdx], LStatus));
      RegisterUnitName(FModels.Count - 1);
    end
    else
      FByPath.Add(LKeys[LIdx], -1);
end;

// Maps the model's DECLARED unit name (root's name node, dotted included) to
// its id — first-loaded wins, so a program's own `in 'path'` units (loaded
// first, from the main source) are authoritative over later stray same-named
// files. This is the dcc rule that lets OTHER units say plain `uses X` for a
// unit only the program's `uses X in 'path'` locates (no search-path entry).
procedure TPasSemaProject.RegisterUnitName(AId: Integer);
var
  LName: string;
  LNameNode: Integer;
begin
  if FByUnitName = nil then
    FByUnitName := TDictionary<string, Integer>.Create;
  LNameNode := FModels[AId].Tree.Nodes[0].FirstChild;
  if LNameNode = NIL_NODE then
    Exit;
  LName := LowerCase(QualifiedText(AId, LNameNode));
  if (LName <> '') and not FByUnitName.ContainsKey(LName) then
    FByUnitName.Add(LName, AId);
end;

// An already-loaded model whose DECLARED name matches AName (as written or
// through a unit-scope namespace prefix); -1 when none. See RegisterUnitName.
function TPasSemaProject.LoadedUnitByName(const AName: string): Integer;
var
  LNS: string;
begin
  if FByUnitName = nil then
    Exit(-1);
  if FByUnitName.TryGetValue(LowerCase(AName), Result) then
    Exit;
  if Pos('.', AName) = 0 then
    for LNS in FNamespaces do
      if (LNS <> '') and
         FByUnitName.TryGetValue(LowerCase(LNS + '.' + AName), Result) then
        Exit;
  Result := -1;
end;

procedure TPasSemaProject.ResolveUses(AId: Integer);
var
  LModel: TPasSemaModel;
  LPath: string;
  LUid, LIdx: Integer;
begin
  LModel := FModels[AId];
  LModel.AllUsesResolved := True;
  for LIdx := 0 to High(LModel.UsesList) do
  begin
    if FSM.ResolveUnit(LModel.UsesList[LIdx].NameFull,
      LModel.UsesList[LIdx].InPath, FFiles[AId], LPath) then
      LUid := LoadFile(LPath)
    else
      // No file on any path — but the unit may ALREADY be loaded under this
      // name via a program's `uses X in 'path'` (dcc: an in-path locates the
      // unit for the whole project, not just the program file).
      LUid := LoadedUnitByName(LModel.UsesList[LIdx].NameFull);
    LModel.UsesList[LIdx].UnitId := LUid;
    if LUid >= 0 then
    begin
      if LModel.UsesList[LIdx].Sym <> NIL_SYM then
        LModel.Symbols[LModel.UsesList[LIdx].Sym].Flags :=
          LModel.Symbols[LModel.UsesList[LIdx].Sym].Flags -
          [sfExternalUnresolved];
    end
    else
      LModel.AllUsesResolved := False;
  end;
end;

function TPasSemaProject.UsesUnitOf(AId, ASym: Integer): Integer;
var
  LModel: TPasSemaModel;
  LIdx: Integer;
begin
  LModel := FModels[AId];
  for LIdx := 0 to High(LModel.UsesList) do
    if LModel.UsesList[LIdx].Sym = ASym then
      Exit(LModel.UsesList[LIdx].UnitId);
  Result := -1;
end;

function TPasSemaProject.FindInUses(AId: Integer; const ANameLower: string;
  out AUnit, ASym: Integer): Boolean;
var
  LModel, LUsed: TPasSemaModel;
  LIdx, LUid, LSym: Integer;
begin
  LModel := FModels[AId];
  for LIdx := High(LModel.UsesList) downto 0 do
  begin
    LUid := LModel.UsesList[LIdx].UnitId;
    if LUid < 0 then
      Continue;
    LUsed := FModels[LUid];
    if LUsed.InterfaceScope = NIL_SCOPE then
      Continue;
    // Resolve (not FindLocal) so interface-visible enum values and other
    // joined-scope names are importable too.
    LSym := LUsed.Resolve(LUsed.InterfaceScope, ANameLower);
    if LSym <> NIL_SYM then
    begin
      AUnit := LUid;
      ASym := LSym;
      Exit(True);
    end;
  end;
  Result := False;
end;

// Every unit implicitly uses System (1.2.1 / 11.2.1) without naming it in a
// `uses` clause, so FindInUses (which only walks the model's OWN UsesList)
// can never find a name declared ONLY there — sLineBreak, PathDelim, and
// similar System-only RTL identifiers were false E2003s until this existed.
// Tried as the LAST resort in CrossResolve, after explicit uses, matching
// real dcc lookup order; a miss here changes nothing — the normal
// AllUsesResolved-gated E2003 still applies exactly as before.
function TPasSemaProject.FindInSystemUnit(const ANameLower: string;
  out AUnit, ASym: Integer): Boolean;
var
  LUid, LSym: Integer;
  LUsed: TPasSemaModel;
begin
  Result := False;
  LUid := EnsureSystemUnit;
  if LUid < 0 then
    Exit;
  LUsed := FModels[LUid];
  if LUsed.InterfaceScope = NIL_SCOPE then
    Exit;
  LSym := LUsed.Resolve(LUsed.InterfaceScope, ANameLower);
  if LSym <> NIL_SYM then
  begin
    AUnit := LUid;
    ASym := LSym;
    Result := True;
  end;
end;

// Companion to FindInSystemUnit for the OTHER implicit unit (see
// EnsureSysInitUnit) — tried right after it, same last-resort spot in
// CrossResolve, so a miss here changes nothing either.
function TPasSemaProject.FindInSysInitUnit(const ANameLower: string;
  out AUnit, ASym: Integer): Boolean;
var
  LUid, LSym: Integer;
  LUsed: TPasSemaModel;
begin
  Result := False;
  LUid := EnsureSysInitUnit;
  if LUid < 0 then
    Exit;
  LUsed := FModels[LUid];
  if LUsed.InterfaceScope = NIL_SCOPE then
    Exit;
  LSym := LUsed.Resolve(LUsed.InterfaceScope, ANameLower);
  if LSym <> NIL_SYM then
  begin
    AUnit := LUid;
    ASym := LSym;
    Result := True;
  end;
end;

// ANode is an attribute usage's TypeRef (`[Unsafe]` in `[Unsafe] FField:
// TFoo;`) if its parent is the nkAttribute node AND it sits in that node's
// TypeRef position (FirstChild) rather than among its `(...)` argument
// expressions. 19.3.1: the `Attribute` suffix may be omitted at the use
// site (`[Weak]` names `WeakAttribute`) — real dcc tries the bare name
// first, then retries with the suffix; a name this project resolves plainly
// (SOME OTHER `TFooAttribute` declared under its own short alias) must not
// pay the suffix-retry cost or risk resolving to the wrong symbol, so this
// is only consulted after a normal-name lookup already failed.
function TPasSemaProject.IsAttributeTypeRef(AModel: TPasSemaModel;
  ANode: Integer): Boolean;
var
  LParent: Integer;
begin
  LParent := AModel.Tree.Nodes[ANode].Parent;
  Result := (LParent <> NIL_NODE) and
    (AModel.Tree.Nodes[LParent].Kind = nkAttribute) and
    (AModel.Tree.Nodes[LParent].FirstChild = ANode);
end;

// The local symbol a designator head resolved to (reads RefMap only).
function TPasSemaProject.LocalHead(AModel: TPasSemaModel;
  ANode: Integer): Integer;
var
  LLast: Integer;
begin
  case AModel.Tree.Nodes[ANode].Kind of
    nkIdent:
      Result := AModel.RefMap[ANode];
    nkMember:
      begin
        LLast := AModel.Tree.Nodes[ANode].FirstChild;
        while (LLast <> NIL_NODE) and
              (AModel.Tree.Nodes[LLast].NextSibling <> NIL_NODE) do
          LLast := AModel.Tree.Nodes[LLast].NextSibling;
        if LLast <> NIL_NODE then
          Result := AModel.RefMap[LLast]
        else
          Result := NIL_SYM;
      end;
    nkTypeArgs:
      Result := LocalHead(AModel, AModel.Tree.Nodes[ANode].FirstChild);
  else
    Result := NIL_SYM;
  end;
end;

// The dotted spelling of a name designator (nkIdent or nested nkMember), as
// WRITTEN — e.g. "System.SysUtils" for the nkMember(nkMember(System,
// SysUtils)) shape. Used to recognize a qualified-expression prefix as a
// UNIT name (System.sLineBreak, System.SysUtils.TBytes) — distinct from
// PasTree.Sema.Resolver's private QualifiedNameText, which serves the same
// purpose but isn't reachable from this unit.
function TPasSemaProject.QualifiedText(AId, ANode: Integer): string;
var
  LM: TPasSemaModel;
  LBase, LName: Integer;
begin
  LM := FModels[AId];
  if LM.Tree.Nodes[ANode].Kind = nkMember then
  begin
    LBase := LM.Tree.Nodes[ANode].FirstChild;
    LName := LM.Tree.Nodes[LBase].NextSibling;
    Result := QualifiedText(AId, LBase) + '.' + LM.Tree.NodeText(LName);
  end
  else
    Result := LM.Tree.NodeText(ANode);
end;

// The model id ANode's qualified text names as a UNIT — literally 'System'
// (the implicit unit; see EnsureSystemUnit), or a match (full dotted name OR
// bare leaf, either is legal in real dcc) against AId's OWN `uses` list.
// -1 when the text doesn't name any unit reachable from AId. This is what
// lets `System.sLineBreak` / `System.SysUtils.TBytes` resolve even though
// neither `System` nor a `System.SysUtils`-as-a-whole ever gets a skUnitRef
// symbol anywhere (System is implicit; SysUtils here is a sub-expression of
// a bigger nkMember, never itself collected as a uses item).
function TPasSemaProject.UnitNameOf(AId, ANode: Integer): Integer;
var
  LM: TPasSemaModel;
  LText, LLeaf: string;
  LIdx, LDot: Integer;
begin
  Result := -1;
  LM := FModels[AId];
  LText := QualifiedText(AId, ANode);
  if SameText(LText, 'system') then
    Exit(EnsureSystemUnit);
  if SameText(LText, 'sysinit') then
    Exit(EnsureSysInitUnit);
  for LIdx := 0 to High(LM.UsesList) do
  begin
    if LM.UsesList[LIdx].UnitId < 0 then
      Continue;
    if SameText(LM.UsesList[LIdx].NameFull, LText) then
      Exit(LM.UsesList[LIdx].UnitId);
    LDot := LastDelimiter('.', LM.UsesList[LIdx].NameFull);
    LLeaf := Copy(LM.UsesList[LIdx].NameFull, LDot + 1, MaxInt);
    if SameText(LLeaf, LText) then
      Exit(LM.UsesList[LIdx].UnitId);
  end;
end;

// ANode (an identifier that failed ALL normal local resolution — callers
// only reach this after that check) may be a namespace-qualifier segment of
// SOME enclosing dotted expression that names a real unit — `System` in
// `System.sLineBreak`; either of `System`/`SysUtils` in `System.SysUtils.
// TBytes`. First climbs to the OUTERMOST node of the WHOLE dotted chain
// ANode belongs to (regardless of whether ANode sits at a "base" or
// "member name" position — a caller only ever reaches this for a node that
// is NOT the chain's actual final/real member, since that one already
// resolved via RefMap/ExtRefMap before this is ever called, so climbing
// past ANode is always safe). The outermost node's OWN member-name child is
// therefore the chain's true final segment (TBytes); the QUALIFIER is
// exactly its base. From there, tries progressively SHORTER prefixes
// (drop one trailing segment at a time) so the LONGEST match wins FIRST —
// mirrors real dcc's greedy namespace resolution (spec 1.2.3): in `System.
// SysUtils.TBytes`, `System.SysUtils` (a real used unit) must win over bare
// `System` (the ALSO-valid implicit unit) rather than stopping at the
// first, shortest candidate. Returns the matched unit's model id (-1 if
// none), and AMatchNode = the node whose OWN span is exactly the matched
// qualifier text — e.g. the inner nkMember representing "System.SysUtils"
// — so a host can highlight/link the WHOLE qualifier when hovering ANY of
// its segments, same as it would for a `uses` clause's dotted name.
//
// Two uses: CrossResolve's E2003 exemption for `System`/`SysUtils` above
// (a namespace token is never an undeclared-identifier candidate — mirrors
// the existing "member name of A.B" guard, generalized to the qualifier
// side of the dot), and PasTree.Sema.Nav (clicking/hovering the qualifier
// itself opens the referenced unit, same as a `uses` clause name).
function TPasSemaProject.QualifierUnitAt(AId, ANode: Integer;
  out AMatchNode: Integer): Integer;
var
  LM: TPasSemaModel;
  LOutermost, LCandidate: Integer;
begin
  Result := -1;
  LM := FModels[AId];
  LOutermost := ANode;
  while (LM.Tree.Nodes[LOutermost].Parent <> NIL_NODE) and
        (LM.Tree.Nodes[LM.Tree.Nodes[LOutermost].Parent].Kind = nkMember) do
    LOutermost := LM.Tree.Nodes[LOutermost].Parent;
  if LM.Tree.Nodes[LOutermost].Kind <> nkMember then
    Exit;   // ANode isn't part of any dotted chain at all

  LCandidate := LM.Tree.Nodes[LOutermost].FirstChild;
  while LCandidate <> NIL_NODE do
  begin
    Result := UnitNameOf(AId, LCandidate);
    if Result >= 0 then
    begin
      AMatchNode := LCandidate;
      Exit;
    end;
    if LM.Tree.Nodes[LCandidate].Kind = nkMember then
      LCandidate := LM.Tree.Nodes[LCandidate].FirstChild
    else
      LCandidate := NIL_NODE;
  end;
end;

procedure TPasSemaProject.EmitE2003(AModel: TPasSemaModel; ANode: Integer);
var
  LVis: TPasVisibleToken;
  LFile, LLine, LCol, LTok: Integer;
  LName: string;
begin
  LFile := 0; LLine := 0; LCol := 0;
  LTok := AModel.Tree.Nodes[ANode].FirstToken;
  if (LTok >= 0) and (LTok <= High(AModel.Tree.Source.Visible)) then
  begin
    LVis := AModel.Tree.Source.Visible[LTok];
    LFile := LVis.FileId;
    AModel.Tree.Source.Files[LVis.FileId].OffsetToLineCol(
      AModel.Tree.Source.Files[LVis.FileId].Tokens[LVis.TokenIndex].Start,
      LLine, LCol);
  end;
  LName := AModel.Tree.NodeText(ANode);
  AModel.AddDiag(MakeDiag('E2003',
    Format(SE2003_UndeclaredIdentifier, [LName]), ANode, LFile, LLine, LCol));
end;

procedure TPasSemaProject.EmitAt(AModel: TPasSemaModel; ANode: Integer;
  const ACode, AMsg: string);
var
  LVis: TPasVisibleToken;
  LFile, LLine, LCol, LTok: Integer;
begin
  LFile := 0; LLine := 0; LCol := 0;
  LTok := AModel.Tree.Nodes[ANode].FirstToken;
  if (LTok >= 0) and (LTok <= High(AModel.Tree.Source.Visible)) then
  begin
    LVis := AModel.Tree.Source.Visible[LTok];
    LFile := LVis.FileId;
    AModel.Tree.Source.Files[LVis.FileId].OffsetToLineCol(
      AModel.Tree.Source.Files[LVis.FileId].Tokens[LVis.TokenIndex].Start,
      LLine, LCol);
  end;
  AModel.AddDiag(MakeDiag(ACode, AMsg, ANode, LFile, LLine, LCol));
end;

// Model-aware parameter arity of a routine symbol. Result=False if the routine
// has no parameter scope (a builtin) — caller then skips the whole call.
function TPasSemaProject.RoutineArity(AMid, ASym: Integer;
  out AReq, ATot: Integer; out AVariadic: Boolean): Boolean;
var
  LM: TPasSemaModel;
  LScope, LS, LChild: Integer;
  LSawDefault: Boolean;
begin
  LM := FModels[AMid];
  AReq := 0; ATot := 0; AVariadic := False;
  LScope := LM.Symbols[ASym].MemberScope;
  if LScope = NIL_SCOPE then
    Exit(False);
  LSawDefault := False;
  for LS in LM.Scopes[LScope].Symbols do
    if LM.Symbols[LS].Kind = skParam then
    begin
      Inc(ATot);
      if sfHasDefault in LM.Symbols[LS].Flags then
        LSawDefault := True;
      if not LSawDefault then
        Inc(AReq);
    end;
  LChild := LM.Tree.Nodes[LM.Scopes[LScope].OwnerNode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if (LM.Tree.Nodes[LChild].Kind = nkDirective) and
       SameText(LM.Tree.NodeText(LChild), 'varargs') then
      AVariadic := True;
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
  Result := True;
end;

// Cross-unit argument-count check: gathers a call's candidate routines from the
// local overload chain PLUS every resolved used unit's interface, then flags
// E2035/E2034 only if no candidate's arity admits the argument count. Runs only
// for units with resolved uses (complete candidate visibility).
procedure TPasSemaProject.CheckCalls(AId: Integer);
var
  LModel: TPasSemaModel;
  LNode, LCallee, LArg, LArgCount, LLocalHead, LUid, LS, LIdx: Integer;
  LMinReq, LMaxTot: Integer;
  LAnyFit, LAnyVariadic, LHaveAny, LSkip: Boolean;
  LName: string;

  procedure Consider(AMid, AHead: Integer);
  var
    LCand, LReq, LTot: Integer;
    LVariadic: Boolean;
  begin
    LCand := AHead;
    while LCand <> NIL_SYM do
    begin
      if FModels[AMid].Symbols[LCand].Kind <> skRoutine then
        Break;
      if not RoutineArity(AMid, LCand, LReq, LTot, LVariadic) then
      begin
        LSkip := True;   // a candidate with no param info (builtin) -> bail
        Exit;
      end;
      LHaveAny := True;
      if LVariadic then
        LAnyVariadic := True;
      if LReq < LMinReq then LMinReq := LReq;
      if LTot > LMaxTot then LMaxTot := LTot;
      if LVariadic or ((LArgCount >= LReq) and (LArgCount <= LTot)) then
        LAnyFit := True;
      LCand := FModels[AMid].Symbols[LCand].NextOverload;
    end;
  end;

begin
  LModel := FModels[AId];
  if (Length(LModel.UsesList) = 0) or not LModel.AllUsesResolved then
    Exit;

  for LNode := 0 to High(LModel.RefMap) do
  begin
    if LModel.Tree.Nodes[LNode].Kind <> nkCall then
      Continue;
    LCallee := LModel.Tree.Nodes[LNode].FirstChild;
    if (LCallee = NIL_NODE) or (LModel.Tree.Nodes[LCallee].Kind <> nkIdent) then
      Continue;   // member/qualified calls (methods) are out of scope
    LLocalHead := LModel.RefMap[LCallee];
    if (LLocalHead <> NIL_SYM) and
       (LModel.Symbols[LLocalHead].Kind in [skType, skBuiltinType]) then
      Continue;   // a type cast, not a call

    LArgCount := 0;
    LArg := LModel.Tree.Nodes[LCallee].NextSibling;
    while LArg <> NIL_NODE do
    begin
      Inc(LArgCount);
      LArg := LModel.Tree.Nodes[LArg].NextSibling;
    end;

    LMinReq := MaxInt; LMaxTot := -1;
    LAnyFit := False; LAnyVariadic := False; LHaveAny := False; LSkip := False;

    // Local global-routine overloads.
    if (LLocalHead <> NIL_SYM) and (LModel.Symbols[LLocalHead].Kind = skRoutine)
       and (LModel.Scopes[LModel.Symbols[LLocalHead].Scope].Kind in
            [sckUnit, sckImplementation]) then
      Consider(AId, LLocalHead);

    // Same-named routines from every resolved used unit.
    if not LSkip then
    begin
      LName := LowerCase(LModel.Tree.NodeText(LCallee));
      for LIdx := 0 to High(LModel.UsesList) do
      begin
        LUid := LModel.UsesList[LIdx].UnitId;
        if LUid < 0 then
          Continue;
        LS := FModels[LUid].Resolve(FModels[LUid].InterfaceScope, LName);
        if (LS <> NIL_SYM) and (FModels[LUid].Symbols[LS].Kind = skRoutine) then
          Consider(LUid, LS);
        if LSkip then
          Break;
      end;
    end;

    if LSkip or not LHaveAny or LAnyVariadic or LAnyFit or (LMaxTot < 0) then
      Continue;
    if LArgCount < LMinReq then
      EmitAt(LModel, LNode, 'E2035', SE2035_NotEnoughActualParams)
    else if LArgCount > LMaxTot then
      EmitAt(LModel, LNode, 'E2034', SE2034_TooManyActualParams);
  end;
end;

{ Phase 3c — cross-model typing }

function XNil: TSemaXType;
begin
  Result.UnitId := NIL_SYM;
  Result.Sym := NIL_SYM;
  Result.Inst := NIL_INST;
end;

function XValid(const AX: TSemaXType): Boolean;
begin
  Result := AX.Sym <> NIL_SYM;
end;

function XPlain(AMid, ASym: Integer): TSemaXType;
begin
  Result.UnitId := AMid;
  Result.Sym := ASym;
  Result.Inst := NIL_INST;
end;

// Dedup-registers one generic instantiation; returns its instance-table index.
// LOCKED (FInstLock): the parallel inherited-member pass reaches here through
// FindMemberX -> ResolveTypeExpr on generic heritage (TList<T> = class(
// TEnumerable<T>)) with one worker per unit — unguarded, concurrent
// FInstances.Add corrupted the list (AV on the full-RTL scan). Every other
// FInstances access is locked too (InstanceRead below): a TList read during
// another thread's Add sees a mid-reallocation array.
function TPasSemaProject.Instantiate(const ABase: TSemaXType;
  const AArgs: TArray<TSemaXType>): Integer;
var
  LKey: string;
  LInst: TSemaInstance;
  LArg: TSemaXType;
begin
  LKey := Format('%d:%d', [ABase.UnitId, ABase.Sym]);
  for LArg in AArgs do
    LKey := LKey + Format('|%d:%d:%d', [LArg.UnitId, LArg.Sym, LArg.Inst]);
  FInstLock.Enter;
  try
    if FInstKeys.TryGetValue(LKey, Result) then
      Exit;
    LInst.UnitId := ABase.UnitId;
    LInst.Sym := ABase.Sym;
    LInst.Args := AArgs;
    Result := FInstances.Add(LInst);
    FInstKeys.Add(LKey, Result);
  finally
    FInstLock.Leave;
  end;
end;

// Locked FInstances[AInst] snapshot — see the Instantiate comment.
function TPasSemaProject.InstanceRead(AInst: Integer): TSemaInstance;
begin
  FInstLock.Enter;
  try
    Result := FInstances[AInst];
  finally
    FInstLock.Leave;
  end;
end;

// The type-expression node defining a type symbol (nkTypeDecl's def child).
function TPasSemaProject.TypeDefNodeOf(AMid, ASym: Integer): Integer;
var
  LM: TPasSemaModel;
  LName, LParent: Integer;
begin
  Result := NIL_NODE;
  LM := FModels[AMid];
  if LM.Symbols[ASym].Kind <> skType then
    Exit;
  LName := LM.Symbols[ASym].DeclNode;
  if LName = NIL_NODE then
    Exit;
  LParent := LM.Tree.Nodes[LName].Parent;
  if (LParent = NIL_NODE) or (LM.Tree.Nodes[LParent].Kind <> nkTypeDecl) then
    Exit;
  Result := LM.Tree.Nodes[LName].NextSibling;
  while (Result <> NIL_NODE) and
        (LM.Tree.Nodes[Result].Kind = nkGenericParams) do
    Result := LM.Tree.Nodes[Result].NextSibling;
end;

// The name-ident nodes of a generic type's parameters, in declaration order —
// the positional frame instantiation args are matched against.
function TPasSemaProject.GenericParamIdents(AMid,
  ASym: Integer): TArray<Integer>;
var
  LM: TPasSemaModel;
  LName, LParent, LGen, LParam, LP: Integer;
begin
  Result := nil;
  LM := FModels[AMid];
  LName := LM.Symbols[ASym].DeclNode;
  if LName = NIL_NODE then
    Exit;
  LParent := LM.Tree.Nodes[LName].Parent;
  if (LParent = NIL_NODE) or (LM.Tree.Nodes[LParent].Kind <> nkTypeDecl) then
    Exit;
  LGen := LM.Tree.Nodes[LParent].FirstChild;
  while (LGen <> NIL_NODE) and (LM.Tree.Nodes[LGen].Kind <> nkGenericParams) do
    LGen := LM.Tree.Nodes[LGen].NextSibling;
  if LGen = NIL_NODE then
    Exit;
  LParam := LM.Tree.Nodes[LGen].FirstChild;
  while LParam <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LParam].Kind = nkGenericParam then
    begin
      // Leading idents are the names; a trailing nkConstraint ends them.
      LP := LM.Tree.Nodes[LParam].FirstChild;
      while (LP <> NIL_NODE) and (LM.Tree.Nodes[LP].Kind = nkIdent) do
      begin
        Result := Result + [LP];
        LP := LM.Tree.Nodes[LP].NextSibling;
      end;
    end;
    LParam := LM.Tree.Nodes[LParam].NextSibling;
  end;
end;

// The declared type of any symbol as a cross-model descriptor: the model's
// SymTypeX refinement when present, else its locally-bound TypeSym.
function TPasSemaProject.DeclTypeX(AMid, ASym: Integer): TSemaXType;
var
  LM: TPasSemaModel;
begin
  LM := FModels[AMid];
  if LM.SymTypeX.TryGetValue(ASym, Result) then
    Exit;
  if LM.Symbols[ASym].TypeSym <> NIL_SYM then
    Exit(XPlain(AMid, LM.Symbols[ASym].TypeSym));
  Result := XNil;
end;

// Closes AX over instantiation AInst: an open generic parameter of the
// instantiated type becomes its actual argument; an instantiation whose args
// mention open parameters is re-instantiated with them closed.
function TPasSemaProject.SubstX(const AX: TSemaXType;
  AInst, ADepth: Integer): TSemaXType;
var
  LInst: TSemaInstance;
  LIdents: TArray<Integer>;
  LIdx: Integer;
  LArgs: TArray<TSemaXType>;
begin
  Result := AX;
  if (AInst = NIL_INST) or (ADepth > 16) or not XValid(AX) then
    Exit;
  LInst := InstanceRead(AInst);
  if (AX.UnitId = LInst.UnitId) and
     (FModels[AX.UnitId].Symbols[AX.Sym].Kind = skGenericParam) then
  begin
    LIdents := GenericParamIdents(LInst.UnitId, LInst.Sym);
    for LIdx := 0 to High(LIdents) do
      if LIdents[LIdx] = FModels[AX.UnitId].Symbols[AX.Sym].DeclNode then
      begin
        if LIdx <= High(LInst.Args) then
          Exit(LInst.Args[LIdx]);
        Exit;
      end;
    Exit;   // someone else's parameter (an enclosing generic) — leave open
  end;
  if AX.Inst <> NIL_INST then
  begin
    LArgs := Copy(InstanceRead(AX.Inst).Args);
    for LIdx := 0 to High(LArgs) do
      LArgs[LIdx] := SubstX(LArgs[LIdx], AInst, ADepth + 1);
    Result.Inst := Instantiate(XPlain(AX.UnitId, AX.Sym), LArgs);
  end;
end;

// A type designator (nkIdent / nkMember / nkTypeArgs) as a cross-model type,
// reading the resolver's RefMap first, then the project's ExtRefMap. For
// nkTypeArgs the args are resolved too and the instantiation is registered;
// an unresolved arg degrades to the plain (open) generic.
function TPasSemaProject.ResolveTypeExpr(AId, ANode: Integer): TSemaXType;
var
  LM: TPasSemaModel;
  LName, LSym, LArgNode: Integer;
  LExt: TPasExtRef;
  LBase, LArg: TSemaXType;
  LArgs: TArray<TSemaXType>;
begin
  Result := XNil;
  if ANode = NIL_NODE then
    Exit;
  LM := FModels[AId];
  case LM.Tree.Nodes[ANode].Kind of
    nkIdent, nkMember:
      begin
        LName := ANode;
        if LM.Tree.Nodes[ANode].Kind = nkMember then
        begin
          LName := LM.Tree.Nodes[ANode].FirstChild;
          while (LName <> NIL_NODE) and
                (LM.Tree.Nodes[LName].NextSibling <> NIL_NODE) do
            LName := LM.Tree.Nodes[LName].NextSibling;
          if LName = NIL_NODE then
            Exit;
        end;
        LSym := LM.RefMap[LName];
        if (LSym <> NIL_SYM) and (LM.Symbols[LSym].Kind in
           [skType, skBuiltinType, skGenericParam]) then
          Exit(XPlain(AId, LSym));
        if LM.ExtRefMap.TryGetValue(LName, LExt) and
           (FModels[LExt.UnitId].Symbols[LExt.Sym].Kind in
            [skType, skBuiltinType, skGenericParam]) then
          Exit(XPlain(LExt.UnitId, LExt.Sym));
      end;
    nkTypeArgs:
      begin
        LBase := ResolveTypeExpr(AId, LM.Tree.Nodes[ANode].FirstChild);
        if not XValid(LBase) then
          Exit;
        LArgs := nil;
        LArgNode := LM.Tree.Nodes[LM.Tree.Nodes[ANode].FirstChild].NextSibling;
        while LArgNode <> NIL_NODE do
        begin
          LArg := ResolveTypeExpr(AId, LArgNode);
          if not XValid(LArg) then
            Exit(LBase);
          LArgs := LArgs + [LArg];
          LArgNode := LM.Tree.Nodes[LArgNode].NextSibling;
        end;
        Result := LBase;
        if (Length(LArgs) > 0) and
           (Length(GenericParamIdents(LBase.UnitId, LBase.Sym)) =
            Length(LArgs)) then
          Result.Inst := Instantiate(LBase, LArgs);
      end;
  end;
end;

// Member lookup by name on a type, following type aliases and the first
// heritage entry (ancestor class / base interface) across models, closing
// each hop over the current instantiation. ACtx returns the instantiation
// in whose frame the found member's declared type must be substituted.
function TPasSemaProject.FindMemberX(const ABase: TSemaXType;
  const ANameLower: string; out AMemMid, AMemSym: Integer;
  out ACtx: Integer): Boolean;
var
  LCur, LNext: TSemaXType;
  LM: TPasSemaModel;
  LScope, LDef, LChild, LDepth, LFound, LRMid, LRSym: Integer;
begin
  Result := False;
  AMemMid := NIL_SYM;
  AMemSym := NIL_SYM;
  ACtx := NIL_INST;
  LCur := ABase;
  for LDepth := 1 to 32 do
  begin
    if not XValid(LCur) then
      Exit;
    LM := FModels[LCur.UnitId];
    if not (LM.Symbols[LCur.Sym].Kind in [skType, skBuiltinType]) then
      Exit;
    LScope := LM.Symbols[LCur.Sym].MemberScope;
    if LScope <> NIL_SCOPE then
    begin
      LFound := LM.FindLocal(LScope, ANameLower);
      if LFound <> NIL_SYM then
      begin
        AMemMid := LCur.UnitId;
        AMemSym := LFound;
        ACtx := LCur.Inst;
        Exit(True);
      end;
    end;
    LDef := TypeDefNodeOf(LCur.UnitId, LCur.Sym);
    if LDef = NIL_NODE then
    begin
      // A compiler-seeded builtin (TObject, Exception, ...) has no source
      // DeclNode in ITS OWN model, so there is normally nowhere to go — but
      // it may be a REAL declaration somewhere reachable (System, or a used
      // unit): redirect there and continue the walk instead of giving up.
      // This is what lets `Obj.Free` (Obj: TObject) resolve at all: the
      // synthetic TObject symbol has no MemberScope, but the real TObject
      // class body (System.pas) does.
      if ResolveRealDecl(LCur.UnitId, LM.Symbols[LCur.Sym].NameLower, LRMid,
         LRSym) and ((LRMid <> LCur.UnitId) or (LRSym <> LCur.Sym)) then
      begin
        LCur.UnitId := LRMid;
        LCur.Sym := LRSym;
        Continue;
      end;
      Exit;   // truly nowhere to go
    end;
    case LM.Tree.Nodes[LDef].Kind of
      nkIdent, nkMember, nkTypeArgs:
        LNext := ResolveTypeExpr(LCur.UnitId, LDef);   // type alias
      nkClassType, nkInterfaceType, nkRecordType, nkObjectType:
        begin
          // Leading nkIdent/nkMember/nkTypeArgs children are the heritage
          // list; the FIRST is the ancestor (a class's other entries are
          // implemented interfaces — their members must be implemented in
          // the class anyway, so they are not followed).
          LChild := LM.Tree.Nodes[LDef].FirstChild;
          while (LChild <> NIL_NODE) and not (LM.Tree.Nodes[LChild].Kind in
            [nkIdent, nkMember, nkTypeArgs]) do
            LChild := LM.Tree.Nodes[LChild].NextSibling;
          if LChild = NIL_NODE then
            Exit;
          LNext := ResolveTypeExpr(LCur.UnitId, LChild);
        end;
    else
      Exit;
    end;
    LNext := SubstX(LNext, LCur.Inst, 0);
    if XValid(LNext) and (LNext.UnitId = LCur.UnitId) and
       (LNext.Sym = LCur.Sym) and (LNext.Inst = LCur.Inst) then
      Exit;   // self-referential alias — bail
    LCur := LNext;
  end;
end;

// True when a routine symbol's declaration is `constructor ...` (the nkRoutine
// node's first visible token is the routine keyword itself).
function TPasSemaProject.IsConstructorSym(AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
  LName, LRoutine, LTok: Integer;
begin
  Result := False;
  LM := FModels[AMid];
  if LM.Symbols[ASym].Kind <> skRoutine then
    Exit;
  LName := LM.Symbols[ASym].DeclNode;
  if LName = NIL_NODE then
    Exit;
  LRoutine := LM.Tree.Nodes[LName].Parent;
  if (LRoutine = NIL_NODE) or (LM.Tree.Nodes[LRoutine].Kind <> nkRoutine) then
    Exit;
  LTok := LM.Tree.Nodes[LRoutine].FirstToken;
  if (LTok >= 0) and (LTok <= High(LM.Tree.Source.Visible)) then
    Result := SameText(LM.Tree.Source.VisibleText(LTok), 'constructor');
end;

// Type category of a cross-model type — the symbol's own TypeCat, computed by
// each model's Phase-1 typer categorization. tcUnknown for an invalid X.
function TPasSemaProject.XCatOf(const AX: TSemaXType): TSemaTypeCat;
begin
  if not XValid(AX) then
    Exit(tcUnknown);
  Result := FModels[AX.UnitId].Symbols[AX.Sym].TypeCat;
end;

// Same type across models. Builtin symbol indexes are IDENTICAL in every
// model (SeedSystemScope runs first, deterministically), so two references to
// the builtin Integer compare equal even when they live in different models —
// without this, an exact arg/param match across units would never register.
function TPasSemaProject.XSameType(const A, B: TSemaXType): Boolean;
begin
  Result := XValid(A) and XValid(B) and (A.Sym = B.Sym) and
    (A.Inst = B.Inst) and ((A.UnitId = B.UnitId) or
    ((sfBuiltin in FModels[A.UnitId].Symbols[A.Sym].Flags) and
     (sfBuiltin in FModels[B.UnitId].Symbols[B.Sym].Flags)));
end;

// Cross-model mirror of TPasSemaTyper.Assignable: conservative, rejects only
// definite scalar mismatches; anything unknown/non-scalar is allowed.
function TPasSemaProject.XAssignableX(const ADst, ASrc: TSemaXType): Boolean;
var
  D, S: TSemaTypeCat;
begin
  D := XCatOf(ADst);
  S := XCatOf(ASrc);
  if (D = tcUnknown) or (S = tcUnknown) then
    Exit(True);
  if S = tcNil then
    Exit(D in [tcPointer, tcClass, tcInterface, tcProc, tcClassOf, tcVariant,
      tcArray]);
  case D of
    tcString:  Result := S in [tcString, tcChar];
    tcInteger: Result := S = tcInteger;
    tcFloat:   Result := S in [tcFloat, tcInteger];
    tcBoolean: Result := S = tcBoolean;
    tcChar:    Result := S = tcChar;
  else
    Result := True;
  end;
  if not Result and
     not (S in [tcInteger, tcFloat, tcBoolean, tcChar, tcString]) then
    Result := True;
end;

// A routine's parameter symbols in declaration order (its param scope —
// reused as MemberScope, see the resolver). nil when there is no param info
// (builtins).
function TPasSemaProject.XParamSyms(AMid, ASym: Integer): TArray<Integer>;
var
  LM: TPasSemaModel;
  LS: Integer;
begin
  Result := nil;
  LM := FModels[AMid];
  if LM.Symbols[ASym].MemberScope = NIL_SCOPE then
    Exit;
  for LS in LM.Scopes[LM.Symbols[ASym].MemberScope].Symbols do
    if LM.Symbols[LS].Kind = skParam then
      Result := Result + [LS];
end;

// Declared-type pass: for every symbol whose type expression did not bind to
// a plain local type, resolve it cross-model / as an instantiation.
procedure TPasSemaProject.BindTypesX(AId: Integer);
var
  LM: TPasSemaModel;
  LSym: Integer;
  LX: TSemaXType;
begin
  LM := FModels[AId];
  for LSym := 0 to LM.SymCount - 1 do
    if LM.Symbols[LSym].TypeNode <> NIL_NODE then
    begin
      LX := ResolveTypeExpr(AId, LM.Symbols[LSym].TypeNode);
      if XValid(LX) and ((LM.Symbols[LSym].TypeSym = NIL_SYM) or
         (LX.Inst <> NIL_INST)) then
        LM.SymTypeX.AddOrSetValue(LSym, LX);
    end;
end;

// Expression pass: bottom-up over the whole tree, typing what the intra-unit
// typer could not — cross-model idents/members (with ancestor/alias walk),
// constructor calls, casts, generic-parameter substitution. Also records the
// member references it discovers (RefMap locally, ExtRefMap across models) —
// typing and navigation only, NO diagnostics.
procedure TPasSemaProject.CrossType(AId: Integer);
var
  LM: TPasSemaModel;
  LX: TArray<TSemaXType>;
  // Instantiation frame a member designator was found in (NIL_INST elsewhere)
  // — kept per node so the CALL over that member can substitute the chosen
  // overload's parameter/result types in the same frame (TWrap<Integer>.Get).
  LCtxOf: TArray<Integer>;
  // Same-named routine heads from every resolved used unit, memoized per
  // callee name for this unit's pass (a big unit calls the same few names
  // thousands of times; one interface Resolve per used unit per NAME, not
  // per call).
  LUsesHeads: TDictionary<string, TArray<TPasExtRef>>;

  // A node's best-known type: this pass's result, else the intra-unit one.
  function GetX(N: Integer): TSemaXType;
  begin
    Result := LX[N];
    if not XValid(Result) and (LM.ExprType[N] <> NIL_SYM) then
      Result := XPlain(AId, LM.ExprType[N]);
  end;

  // The (mid, sym) a callee designator resolved to (after the member pass
  // below has enriched RefMap/ExtRefMap).
  function TargetSym(N: Integer; out AMid, ASym: Integer): Boolean;
  var
    LName: Integer;
    LExt: TPasExtRef;
  begin
    Result := False;
    AMid := AId;
    case LM.Tree.Nodes[N].Kind of
      nkIdent:
        LName := N;
      nkMember:
        begin
          LName := LM.Tree.Nodes[N].FirstChild;
          while (LName <> NIL_NODE) and
                (LM.Tree.Nodes[LName].NextSibling <> NIL_NODE) do
            LName := LM.Tree.Nodes[LName].NextSibling;
          if LName = NIL_NODE then
            Exit;
        end;
      nkTypeArgs:
        Exit(TargetSym(LM.Tree.Nodes[N].FirstChild, AMid, ASym));
    else
      Exit;
    end;
    ASym := LM.RefMap[LName];
    if ASym <> NIL_SYM then
      Exit(True);
    if LM.ExtRefMap.TryGetValue(LName, LExt) then
    begin
      AMid := LExt.UnitId;
      ASym := LExt.Sym;
      Exit(True);
    end;
  end;

  // Same-named routine heads from every resolved used unit (memoized).
  function UsesHeads(const ANameLower: string): TArray<TPasExtRef>;
  var
    LIdx, LUid, LS: Integer;
    LRef: TPasExtRef;
  begin
    if LUsesHeads.TryGetValue(ANameLower, Result) then
      Exit;
    Result := nil;
    for LIdx := 0 to High(LM.UsesList) do
    begin
      LUid := LM.UsesList[LIdx].UnitId;
      if LUid < 0 then
        Continue;
      LS := FModels[LUid].Resolve(FModels[LUid].InterfaceScope, ANameLower);
      if (LS <> NIL_SYM) and (FModels[LUid].Symbols[LS].Kind = skRoutine) then
      begin
        LRef.UnitId := LUid;
        LRef.Sym := LS;
        Result := Result + [LRef];
      end;
    end;
    LUsesHeads.Add(ANameLower, Result);
  end;

  // Conservative per-candidate match score, mirroring the intra-unit
  // TPasSemaTyper.ScoreArgs: exact type = 2, assignable = 1 per argument,
  // parameter types substituted in ACtx (the instantiation frame the callee
  // member was found in). -1 = the candidate's arity does not admit the call.
  // A candidate with NO param info (builtin) fits neutrally at 0.
  function ScoreCandidate(ACall, AMid, ACand, ACtx: Integer): Integer;
  var
    LParams: TArray<Integer>;
    LReq, LTot, LIdx, LArg, LArgs: Integer;
    LVariadic: Boolean;
    LArgX, LParX: TSemaXType;
  begin
    LArgs := 0;
    LArg := LM.Tree.Nodes[LM.Tree.Nodes[ACall].FirstChild].NextSibling;
    while LArg <> NIL_NODE do
    begin
      Inc(LArgs);
      LArg := LM.Tree.Nodes[LArg].NextSibling;
    end;
    if not RoutineArity(AMid, ACand, LReq, LTot, LVariadic) then
      Exit(0);
    if not (LVariadic or ((LArgs >= LReq) and (LArgs <= LTot))) then
      Exit(-1);
    Result := 0;
    LParams := XParamSyms(AMid, ACand);
    LArg := LM.Tree.Nodes[LM.Tree.Nodes[ACall].FirstChild].NextSibling;
    LIdx := 0;
    while (LArg <> NIL_NODE) and (LIdx <= High(LParams)) do
    begin
      LArgX := GetX(LArg);
      LParX := SubstX(DeclTypeX(AMid, LParams[LIdx]), ACtx, 0);
      if XValid(LArgX) and XValid(LParX) then
        if XSameType(LParX, LArgX) then
          Inc(Result, 2)
        else if XAssignableX(LParX, LArgX) then
          Inc(Result, 1);
      LArg := LM.Tree.Nodes[LArg].NextSibling;
      Inc(LIdx);
    end;
  end;

  // Cross-model overload selection for a call: walks the resolved head's
  // overload chain and — for a bare-ident callee naming a UNIT-LEVEL routine —
  // merges same-named heads from every resolved used unit (real dcc merges
  // the visible overload sets; CheckCalls already does the same for arity).
  // Picks the arity-fitting candidate with the best argument score (first
  // wins ties, matching the intra-unit SelectOverload). False = nothing fits.
  function SelectCallTarget(ACall, ACalleeNode, AHeadMid, AHeadSym,
    ACtx: Integer; out ABestMid, ABestSym: Integer): Boolean;
  var
    LSeen: TArray<TPasExtRef>;
    LBestScore: Integer;

    procedure ConsiderChain(AMid, AHead: Integer);
    var
      LCand, LScore, LIdx: Integer;
      LDup: Boolean;
      LRef: TPasExtRef;
    begin
      LCand := AHead;
      while LCand <> NIL_SYM do
      begin
        if FModels[AMid].Symbols[LCand].Kind <> skRoutine then
          Break;
        LDup := False;
        for LIdx := 0 to High(LSeen) do
          if (LSeen[LIdx].UnitId = AMid) and (LSeen[LIdx].Sym = LCand) then
          begin
            LDup := True;
            Break;
          end;
        if not LDup then
        begin
          LRef.UnitId := AMid;
          LRef.Sym := LCand;
          LSeen := LSeen + [LRef];
          LScore := ScoreCandidate(ACall, AMid, LCand, ACtx);
          if (LScore >= 0) and (LScore > LBestScore) then
          begin
            LBestScore := LScore;
            ABestMid := AMid;
            ABestSym := LCand;
          end;
        end;
        LCand := FModels[AMid].Symbols[LCand].NextOverload;
      end;
    end;

  var
    LHeads: TArray<TPasExtRef>;
    LIdx: Integer;
  begin
    LSeen := nil;
    LBestScore := -1;
    ABestMid := -1;
    ABestSym := NIL_SYM;
    ConsiderChain(AHeadMid, AHeadSym);
    // Merge used units' candidates only for a bare unit-level routine name —
    // methods and nested routines have a closed candidate set (their scope).
    if (LM.Tree.Nodes[ACalleeNode].Kind = nkIdent) and
       (FModels[AHeadMid].Scopes[FModels[AHeadMid].Symbols[AHeadSym].Scope].
        Kind in [sckUnit, sckImplementation]) then
    begin
      LHeads := UsesHeads(LowerCase(LM.Tree.NodeText(ACalleeNode)));
      for LIdx := 0 to High(LHeads) do
        ConsiderChain(LHeads[LIdx].UnitId, LHeads[LIdx].Sym);
    end;
    Result := ABestSym <> NIL_SYM;
  end;

  // The type a member access yields: the member's declared type (routines:
  // result type; constructors: the base type itself, so `TDerived.Create` —
  // parsed as a plain member when argless — types as TDerived), substituted
  // in the instantiation frame it was found in; a nested type member is the
  // type itself (designator).
  function MemberTypeX(AMid, ASym, AInstCtx: Integer;
    const ABaseX: TSemaXType): TSemaXType;
  begin
    case FModels[AMid].Symbols[ASym].Kind of
      skType, skBuiltinType:
        Result := XPlain(AMid, ASym);
      skRoutine:
        if IsConstructorSym(AMid, ASym) then
          Result := ABaseX
        else
          Result := SubstX(DeclTypeX(AMid, ASym), AInstCtx, 0);
      skVar, skConst, skField, skParam, skProperty, skEnumValue:
        Result := SubstX(DeclTypeX(AMid, ASym), AInstCtx, 0);
    else
      Result := XNil;
    end;
  end;

  procedure Walk(N: Integer);
  var
    LChild, LBase, LName, LSym, LMemMid, LMemSym, LCtx: Integer;
    LBestMid, LBestSym: Integer;
    LExt: TPasExtRef;
    LBX: TSemaXType;
  begin
    LChild := LM.Tree.Nodes[N].FirstChild;
    while LChild <> NIL_NODE do
    begin
      Walk(LChild);
      LChild := LM.Tree.Nodes[LChild].NextSibling;
    end;

    case LM.Tree.Nodes[N].Kind of
      nkIdent:
        begin
          LSym := LM.RefMap[N];
          if LSym <> NIL_SYM then
            case LM.Symbols[LSym].Kind of
              skVar, skConst, skField, skParam, skProperty, skRoutine:
                LX[N] := DeclTypeX(AId, LSym);
              skType, skBuiltinType, skGenericParam:
                LX[N] := XPlain(AId, LSym);
            end
          else if LM.ExtRefMap.TryGetValue(N, LExt) then
            case FModels[LExt.UnitId].Symbols[LExt.Sym].Kind of
              skVar, skConst, skField, skParam, skProperty, skRoutine:
                LX[N] := DeclTypeX(LExt.UnitId, LExt.Sym);
              skType, skBuiltinType:
                LX[N] := XPlain(LExt.UnitId, LExt.Sym);
            end;
        end;

      nkParen:
        if LM.Tree.Nodes[N].FirstChild <> NIL_NODE then
          LX[N] := GetX(LM.Tree.Nodes[N].FirstChild);

      nkTypeArgs:
        LX[N] := ResolveTypeExpr(AId, N);

      nkMember:
        begin
          LBase := LM.Tree.Nodes[N].FirstChild;
          if LBase = NIL_NODE then
            Exit;
          LName := LM.Tree.Nodes[LBase].NextSibling;
          if (LName = NIL_NODE) or
             (LM.Tree.Nodes[LName].Kind <> nkIdent) then
            Exit;
          LBX := GetX(LBase);
          LSym := LM.RefMap[LName];
          if LSym <> NIL_SYM then
          begin
            LX[N] := MemberTypeX(AId, LSym, LBX.Inst, LBX);
            LCtxOf[N] := LBX.Inst;
          end
          else if LM.ExtRefMap.TryGetValue(LName, LExt) then
          begin
            LX[N] := MemberTypeX(LExt.UnitId, LExt.Sym, LBX.Inst, LBX);
            LCtxOf[N] := LBX.Inst;
          end
          else if XValid(LBX) and FindMemberX(LBX,
            LowerCase(LM.Tree.NodeText(LName)), LMemMid, LMemSym, LCtx) then
          begin
            // Record the discovered member reference for navigation.
            if LMemMid = AId then
              LM.RefMap[LName] := LMemSym
            else
            begin
              LExt.UnitId := LMemMid;
              LExt.Sym := LMemSym;
              LM.ExtRefMap.AddOrSetValue(LName, LExt);
            end;
            LX[N] := MemberTypeX(LMemMid, LMemSym, LCtx, LBX);
            LCtxOf[N] := LCtx;
          end;
        end;

      nkCall:
        begin
          LBase := LM.Tree.Nodes[N].FirstChild;   // the callee
          if (LBase <> NIL_NODE) and TargetSym(LBase, LMemMid, LMemSym) then
            case FModels[LMemMid].Symbols[LMemSym].Kind of
              skRoutine:
                begin
                  LCtx := LCtxOf[LBase];
                  if SelectCallTarget(N, LBase, LMemMid, LMemSym, LCtx,
                    LBestMid, LBestSym) then
                  begin
                    // Record the argument-matched overload — the future
                    // overload-precise navigation jump reads this.
                    LExt.UnitId := LBestMid;
                    LExt.Sym := LBestSym;
                    LM.CallTargetX.AddOrSetValue(N, LExt);
                    if IsConstructorSym(LBestMid, LBestSym) and
                       (LM.Tree.Nodes[LBase].Kind = nkMember) then
                      // T.Create / TList<Integer>.Create -> the class itself
                      LX[N] := GetX(LM.Tree.Nodes[LBase].FirstChild)
                    else
                      LX[N] := SubstX(DeclTypeX(LBestMid, LBestSym), LCtx, 0);
                  end
                  else if IsConstructorSym(LMemMid, LMemSym) and
                     (LM.Tree.Nodes[LBase].Kind = nkMember) then
                    // No modeled ctor overload admits the args (inherited
                    // constructors across unseen hierarchy links) — keep the
                    // long-standing behavior: a ctor call is the class type.
                    LX[N] := GetX(LM.Tree.Nodes[LBase].FirstChild);
                  // else: no candidate admits the arg count — the real
                  // callee is likely an unseen same-named overload; leave
                  // the call untyped rather than claim the wrong result.
                end;
              skType, skBuiltinType:
                LX[N] := GetX(LBase);   // a cast (incl. instantiated generic)
            end;
        end;

      nkInlineIf:
        begin
          LChild := LM.Tree.Nodes[N].FirstChild;   // cond, then, else
          if (LChild <> NIL_NODE) and
             (LM.Tree.Nodes[LChild].NextSibling <> NIL_NODE) then
            LX[N] := GetX(LM.Tree.Nodes[LChild].NextSibling);
        end;
    end;
  end;

var
  LNode: Integer;
begin
  LM := FModels[AId];
  SetLength(LX, Length(LM.Tree.Nodes));
  SetLength(LCtxOf, Length(LM.Tree.Nodes));
  for LNode := 0 to High(LX) do
  begin
    LX[LNode] := XNil;
    LCtxOf[LNode] := NIL_INST;
  end;
  LUsesHeads := TDictionary<string, TArray<TPasExtRef>>.Create;
  try
    if Length(LX) > 0 then
      Walk(0);
  finally
    LUsesHeads.Free;
  end;
  // Persist only what ADDS to the intra-unit result: a type for a locally
  // untyped node, an instantiation, or a type living in another model.
  for LNode := 0 to High(LX) do
    if XValid(LX[LNode]) and ((LM.ExprType[LNode] = NIL_SYM) or
       (LX[LNode].Inst <> NIL_INST) or (LX[LNode].UnitId <> AId)) then
      LM.ExprTypeX.AddOrSetValue(LNode, LX[LNode]);
end;

function TPasSemaProject.InstanceCount: Integer;
begin
  FInstLock.Enter;
  try
    Result := FInstances.Count;
  finally
    FInstLock.Leave;
  end;
end;

function TPasSemaProject.Instance(AInst: Integer): TSemaInstance;
begin
  Result := InstanceRead(AInst);
end;

function TPasSemaProject.XTypeText(const AX: TSemaXType): string;
var
  LIdx: Integer;
  LArgs: TArray<TSemaXType>;
begin
  if not XValid(AX) then
    Exit('?');
  Result := FModels[AX.UnitId].Symbols[AX.Sym].Name;
  if AX.Inst <> NIL_INST then
  begin
    LArgs := InstanceRead(AX.Inst).Args;
    Result := Result + '<';
    for LIdx := 0 to High(LArgs) do
    begin
      if LIdx > 0 then
        Result := Result + ',';
      Result := Result + XTypeText(LArgs[LIdx]);
    end;
    Result := Result + '>';
  end;
end;

procedure TPasSemaProject.CrossResolve(AId: Integer);
var
  LModel: TPasSemaModel;
  LNode, LBase, LName, LHead, LUid, LSym, LMatchNode: Integer;
  LExt: TPasExtRef;
  LNameLower: string;
begin
  LModel := FModels[AId];
  for LNode := 0 to High(LModel.RefMap) do
  begin
    case LModel.Tree.Nodes[LNode].Kind of
      nkMember:
        begin
          LBase := LModel.Tree.Nodes[LNode].FirstChild;
          if LBase = NIL_NODE then
            Continue;
          LName := LModel.Tree.Nodes[LBase].NextSibling;
          if (LName = NIL_NODE) or (LModel.RefMap[LName] <> NIL_SYM) or
             LModel.ExtRefMap.ContainsKey(LName) then
            Continue;
          LHead := LocalHead(LModel, LBase);
          if (LHead <> NIL_SYM) and
             (LModel.Symbols[LHead].Kind = skUnitRef) then
          begin
            LUid := UsesUnitOf(AId, LHead);
            if LUid >= 0 then
            begin
              LSym := FModels[LUid].Resolve(FModels[LUid].InterfaceScope,
                LowerCase(LModel.Tree.NodeText(LName)));
              if LSym <> NIL_SYM then
              begin
                LExt.UnitId := LUid; LExt.Sym := LSym;
                LModel.ExtRefMap.Add(LName, LExt);
              end;
            end;
          end
          else if LHead = NIL_SYM then
          begin
            // LBase resolved to NOTHING locally (never shadowed by a real
            // declaration — a genuine local/global always wins and is
            // handled above via LHead <> NIL_SYM): it may still be a
            // namespace qualifier that was never collected as a `uses` item
            // at all — the IMPLICIT System unit (`System.sLineBreak`), or a
            // multi-segment prefix naming a used unit even though the
            // PREFIX itself (e.g. `System.SysUtils` as a whole) is never
            // itself a skUnitRef symbol (`System.SysUtils.TBytes`).
            LUid := UnitNameOf(AId, LBase);
            if LUid >= 0 then
            begin
              LSym := FModels[LUid].Resolve(FModels[LUid].InterfaceScope,
                LowerCase(LModel.Tree.NodeText(LName)));
              if LSym <> NIL_SYM then
              begin
                LExt.UnitId := LUid; LExt.Sym := LSym;
                LModel.ExtRefMap.Add(LName, LExt);
              end;
            end;
          end;
        end;

      nkIdent:
        begin
          if (LModel.RefMap[LNode] <> NIL_SYM) or
             LModel.ExtRefMap.ContainsKey(LNode) then
            Continue;
          if (LNode > High(LModel.NodeScope)) or
             (LModel.NodeScope[LNode] = NIL_SCOPE) then
            Continue;   // not a reference in a real scope (e.g. uses name)
          // The member name of `A.B` is resolved via A's scope (nkMember case),
          // never as a plain identifier — it is not an undeclared-id candidate.
          LBase := LModel.Tree.Nodes[LNode].Parent;
          if (LBase <> NIL_NODE) and
             (LModel.Tree.Nodes[LBase].Kind = nkMember) and
             (LModel.Tree.Nodes[LBase].FirstChild <> LNode) then
            Continue;
          // Inside a METHOD body the name may be an INHERITED member from a
          // cross-unit ancestor (AddAttribute in a TSynCustomHighlighter
          // descendant), which dcc resolves BEFORE any used unit's globals.
          // That walk (FindMemberX) reads OTHER models' ExtRefMap — mutated
          // concurrently by their own CrossResolve workers — so it is
          // DEFERRED to the sequential CrossResolveInherited pass, wholesale
          // (uses/System fallback included, to keep dcc's precedence).
          // Checked FIRST: the cheap scope-climb spares the allocation-heavy
          // QualifierUnitAt for the bulk of nodes (method bodies).
          if StructSymOfNode(LModel, LNode) <> NIL_SYM then
            Continue;
          LNameLower := LowerCase(LModel.Tree.NodeText(LNode));
          if (LNameLower = 'result') or (LNameLower = 'self') then
            Continue;   // implicit routine/method names
          // A qualifier segment of a dotted expression that names a real
          // unit (`System` in `System.sLineBreak`; `System`/`SysUtils` in
          // `System.SysUtils.TBytes`) is a namespace token, not an
          // undeclared-id candidate — same spirit as the member-name guard
          // above, generalized to the OTHER side of the dot.
          if QualifierUnitAt(AId, LNode, LMatchNode) >= 0 then
            Continue;
          if FindInUses(AId, LNameLower, LUid, LSym) then
          begin
            LExt.UnitId := LUid; LExt.Sym := LSym;
            LModel.ExtRefMap.Add(LNode, LExt);
          end
          else if FindInSystemUnit(LNameLower, LUid, LSym) then
          begin
            LExt.UnitId := LUid; LExt.Sym := LSym;
            LModel.ExtRefMap.Add(LNode, LExt);
          end
          else if FindInSysInitUnit(LNameLower, LUid, LSym) then
          begin
            LExt.UnitId := LUid; LExt.Sym := LSym;
            LModel.ExtRefMap.Add(LNode, LExt);
          end
          else if IsAttributeTypeRef(LModel, LNode) and
                  (FindInUses(AId, LNameLower + 'attribute', LUid, LSym) or
                   FindInSystemUnit(LNameLower + 'attribute', LUid, LSym)) then
          begin
            LExt.UnitId := LUid; LExt.Sym := LSym;
            LModel.ExtRefMap.Add(LNode, LExt);
          end
          else if LModel.AllUsesResolved then
            EmitE2003(LModel, LNode);
        end;
    end;
  end;
end;

// The struct type symbol of the METHOD implementation enclosing ANode, via
// the scope chain (a local proc inside a method climbs to the method's
// scope); NIL_SYM when ANode isn't inside any method body.
function TPasSemaProject.StructSymOfNode(AModel: TPasSemaModel;
  ANode: Integer): Integer;
var
  LScope: Integer;
begin
  Result := NIL_SYM;
  if (ANode > High(AModel.NodeScope)) then
    Exit;
  LScope := AModel.NodeScope[ANode];
  while LScope <> NIL_SCOPE do
  begin
    if AModel.Scopes[LScope].StructSym <> NIL_SYM then
      Exit(AModel.Scopes[LScope].StructSym);
    LScope := AModel.Scopes[LScope].Parent;
  end;
end;

// Companion to CrossResolve for idents inside METHOD bodies, deferred there
// because the inherited-member walk (FindMemberX) reads other models'
// ExtRefMap — those must be FROZEN (every parallel CrossResolve worker done)
// before this runs. Resolution order matches dcc: inherited members first,
// then used units, then the implicit System unit; E2003 after all three miss.
//
// Runs in TWO PHASES (see RunInheritedPass): this COMPUTE step is safe to
// farm out one-worker-per-unit because every worker only READS ExtRefMaps
// (its own included) and writes its results to APending / its OWN Diags —
// the ExtRefMap writes are committed sequentially afterwards. The split is
// exact: the entries this pass produces are method-BODY nodes, which are
// never heritage/alias/type nodes, so no worker's FindMemberX result can
// depend on another worker's pending (uncommitted) entries.
procedure TPasSemaProject.CrossResolveInherited(AId: Integer;
  var APending: TArray<TPasInhPending>);
var
  LModel: TPasSemaModel;
  LNode, LBase, LStruct, LUid, LSym, LCtx, LMatchNode: Integer;
  LPend: TPasInhPending;
  LNameLower: string;
begin
  APending := nil;
  LModel := FModels[AId];
  for LNode := 0 to High(LModel.RefMap) do
  begin
    if LModel.Tree.Nodes[LNode].Kind <> nkIdent then
      Continue;
    if (LModel.RefMap[LNode] <> NIL_SYM) or
       LModel.ExtRefMap.ContainsKey(LNode) then
      Continue;
    if (LNode > High(LModel.NodeScope)) or
       (LModel.NodeScope[LNode] = NIL_SCOPE) then
      Continue;
    LBase := LModel.Tree.Nodes[LNode].Parent;
    if (LBase <> NIL_NODE) and
       (LModel.Tree.Nodes[LBase].Kind = nkMember) and
       (LModel.Tree.Nodes[LBase].FirstChild <> LNode) then
      Continue;   // member name of A.B — resolved via A, not as a plain ident
    // Cheap scope-climb FIRST: everything outside a method body was already
    // handled (resolved or E2003'd) by CrossResolve — bailing here avoids
    // re-running the allocation-heavy QualifierUnitAt on every one of those
    // nodes a second time.
    LStruct := StructSymOfNode(LModel, LNode);
    if LStruct = NIL_SYM then
      Continue;
    LNameLower := LowerCase(LModel.Tree.NodeText(LNode));
    if (LNameLower = 'result') or (LNameLower = 'self') then
      Continue;
    if QualifierUnitAt(AId, LNode, LMatchNode) >= 0 then
      Continue;
    if FindMemberX(XPlain(AId, LStruct), LNameLower, LUid, LSym, LCtx) or
       FindInUses(AId, LNameLower, LUid, LSym) or
       FindInSystemUnit(LNameLower, LUid, LSym) or
       FindInSysInitUnit(LNameLower, LUid, LSym) then
    begin
      LPend.Node := LNode;
      LPend.Ext.UnitId := LUid;
      LPend.Ext.Sym := LSym;
      APending := APending + [LPend];
    end
    else if LModel.AllUsesResolved then
      EmitE2003(LModel, LNode);
  end;
end;

// Both phases of the inherited-member pass over models 0..ACount-1: parallel
// compute, then the sequential ExtRefMap commit.
procedure TPasSemaProject.RunInheritedPass(ACount: Integer);
var
  LPending: TArray<TArray<TPasInhPending>>;
  LIdx, LP: Integer;
begin
  SetLength(LPending, ACount);
  ForEachIndex(ACount - 1,
    procedure(AIdx: Integer)
    begin
      CrossResolveInherited(AIdx, LPending[AIdx]);
    end);
  for LIdx := 0 to ACount - 1 do
    for LP := 0 to High(LPending[LIdx]) do
      FModels[LIdx].ExtRefMap.Add(LPending[LIdx][LP].Node,
        LPending[LIdx][LP].Ext);
end;

function TPasSemaProject.AnalyzeFile(const AMainFile: string): Integer;
var
  LIdx: Integer;
  LPaths: TArray<string>;
  LPath: string;
begin
  Result := LoadFile(AMainFile);
  if Result < 0 then
    Exit;
  // Pre-load the main unit's direct uses in parallel; ResolveUses below then
  // finds every one already cached (it stays the single source of truth for
  // UnitId assignment and the AllUsesResolved gate).
  LPaths := nil;
  for LIdx := 0 to High(FModels[Result].UsesList) do
    if FSM.ResolveUnit(FModels[Result].UsesList[LIdx].NameFull,
      FModels[Result].UsesList[LIdx].InPath, FFiles[Result], LPath) then
      LPaths := LPaths + [LPath];
  LoadFilesParallel(LPaths);
  ResolveUses(Result);
  CrossResolve(Result);
  var LPend: TArray<TPasInhPending>;
  CrossResolveInherited(Result, LPend);
  for LIdx := 0 to High(LPend) do
    FModels[Result].ExtRefMap.Add(LPend[LIdx].Node, LPend[LIdx].Ext);
  CheckCalls(Result);
  // Declared types for EVERY loaded model first (the expression pass reads
  // used units' SymTypeX), then expressions for the requested unit only.
  for LIdx := 0 to FModels.Count - 1 do
    BindTypesX(LIdx);
  CrossType(Result);
  // Only the requested unit gets the full cross treatment here (AnalyzeFile's
  // narrower contract); its direct uses stay msFullReady.
  SetModuleStatus(Result, msCrossReady);
end;

function TPasSemaProject.StageTimings: string;
begin
  Result := FStageTimings;
end;

function TPasSemaProject.AnalyzeProject(const AMainFile: string): Integer;
var
  LDone, LN, LIdx, LU: Integer;
  LPaths: TArray<string>;
  LPath: string;
  LSW: TStopwatch;
  LResolveMs, LLoadMs: Int64;

  procedure Stage(const AName: string);
  begin
    FStageTimings := FStageTimings +
      Format('%s=%d;', [AName, LSW.ElapsedMilliseconds]);
    LSW := TStopwatch.StartNew;
  end;

begin
  FStageTimings := '';
  LSW := TStopwatch.StartNew;
  Result := LoadFile(AMainFile);
  if Result < 0 then
    Exit;
  // The implicit System unit is part of every unit's closure (1.2.1) yet
  // never appears in a `uses` clause — pull it in NOW so the closure loop
  // and the cross passes below cover it too (nav inside an opened System.pas
  // works), and so no parallel CrossResolve worker triggers its first-time
  // load mid-flight. SysInit is the same story (bare HInstance/ModuleIsLib).
  EnsureSystemUnit;
  EnsureSysInitUnit;
  Stage('main+sys');
  // Load the TRANSITIVE closure, breadth-first: resolve every not-yet-
  // processed model's uses, batch-preload the newly discovered files in
  // parallel, then let ResolveUses (sequential, the single source of truth
  // for UnitId assignment) find them all cached. Repeat until no model is
  // left unprocessed. Terminates: each round processes models created
  // before it, and a file loads at most once (FByPath cache).
  LResolveMs := 0;
  LLoadMs := 0;
  LDone := 0;
  while LDone < FModels.Count do
  begin
    LN := FModels.Count;
    LPaths := nil;
    LSW := TStopwatch.StartNew;
    for LIdx := LDone to LN - 1 do
      for LU := 0 to High(FModels[LIdx].UsesList) do
        if FSM.ResolveUnit(FModels[LIdx].UsesList[LU].NameFull,
          FModels[LIdx].UsesList[LU].InPath, FFiles[LIdx], LPath) and
          not FByPath.ContainsKey(LowerCase(LPath)) then
          LPaths := LPaths + [LPath];
    Inc(LResolveMs, LSW.ElapsedMilliseconds);
    LSW := TStopwatch.StartNew;
    LoadFilesParallel(LPaths);
    Inc(LLoadMs, LSW.ElapsedMilliseconds);
    LSW := TStopwatch.StartNew;
    for LIdx := LDone to LN - 1 do
      ResolveUses(LIdx);
    Inc(LResolveMs, LSW.ElapsedMilliseconds);
    LDone := LN;
  end;
  FStageTimings := FStageTimings +
    Format('resolve=%d;load=%d;', [LResolveMs, LLoadMs]);
  LSW := TStopwatch.StartNew;
  // Cross passes for EVERY loaded unit — same per-unit write discipline as
  // AnalyzeDirectory (each writes only its own model, reads others' frozen
  // Phase-1 state), so the same parallel farming is safe.
  LN := FModels.Count;
  ForEachIndex(LN - 1,
    procedure(AIdx: Integer)
    begin
      CrossResolve(AIdx);
    end);
  Stage('xresolve');
  // The inherited-member pass needs every CrossResolve worker done first
  // (it reads their ExtRefMaps); parallel compute + sequential commit.
  RunInheritedPass(LN);
  Stage('inherited');
  ForEachIndex(LN - 1,
    procedure(AIdx: Integer)
    begin
      CheckCalls(AIdx);
    end);
  Stage('calls');
  // Sequential by design — see AnalyzeDirectory's Phase-3c comment.
  for LIdx := 0 to FModels.Count - 1 do
    BindTypesX(LIdx);
  Stage('bindx');
  for LIdx := 0 to LN - 1 do
    CrossType(LIdx);
  Stage('xtype');
  // Whole transitive closure went through the cross passes.
  MarkAllCrossReady;
end;

procedure TPasSemaProject.AnalyzeDirectory(const ARoot: string);
var
  LFile, LExt: string;
  LPaths: TArray<string>;
  LN, LIdx: Integer;
  LSW: TStopwatch;

  procedure Stage(const AName: string);
  begin
    FStageTimings := FStageTimings +
      Format('%s=%d;', [AName, LSW.ElapsedMilliseconds]);
    LSW := TStopwatch.StartNew;
  end;

begin
  FStageTimings := '';
  LSW := TStopwatch.StartNew;
  FSM.BuildUnitIndex(ARoot);
  LPaths := nil;
  for LFile in TDirectory.GetFiles(ARoot, '*.*',
    TSearchOption.soAllDirectories) do
  begin
    LExt := LowerCase(TPath.GetExtension(LFile));
    if (LExt = '.pas') or (LExt = '.dpr') then
      LPaths := LPaths + [LFile];
  end;
  Stage('scan');
  LoadFilesParallel(LPaths);
  Stage('load');
  LN := FModels.Count;   // snapshot: only the directory's own units get E2003
  // Resolve the implicit System unit BEFORE any parallel pass: a worker
  // hitting it first mid-flight would LoadFile into the shared FModels
  // while other workers read FModels[i] (the lock serializes the load
  // itself, not the container reads elsewhere). After the LN snapshot, so a
  // from-search-paths System stays outside the cross passes — exactly where
  // the old lazy mid-CrossResolve load would have put it. SysInit: same deal.
  EnsureSystemUnit;
  EnsureSysInitUnit;
  for LIdx := 0 to LN - 1 do
    ResolveUses(LIdx);
  Stage('main+sys+resolve');
  // Cross passes per unit write ONLY their own model and read the others'
  // Phase-1 state (frozen once every unit is loaded) — safe to farm out.
  ForEachIndex(LN - 1,
    procedure(AIdx: Integer)
    begin
      CrossResolve(AIdx);
    end);
  Stage('xresolve');
  // The inherited-member pass needs every CrossResolve worker done first
  // (it reads their ExtRefMaps); parallel compute + sequential commit.
  RunInheritedPass(LN);
  Stage('inherited');
  ForEachIndex(LN - 1,
    procedure(AIdx: Integer)
    begin
      CheckCalls(AIdx);
    end);
  Stage('calls');
  // Cross typing stays SEQUENTIAL by design: Instantiate mutates the shared
  // instance table, and CrossType both writes a model's RefMap/ExtRefMap and
  // reads other models' — parallelizing would need locks on the hot path for
  // ~5% of the total time (measured on the full RTL).
  for LIdx := 0 to FModels.Count - 1 do
    BindTypesX(LIdx);
  Stage('bindx');
  for LIdx := 0 to LN - 1 do
    CrossType(LIdx);
  Stage('xtype');
  // Units [0..LN-1] (the directory's own) went through the cross passes; a
  // System unit pulled in from search paths after the LN snapshot stays
  // msFullReady, mirroring the E2003 scoping above.
  for LIdx := 0 to LN - 1 do
    SetModuleStatus(LIdx, msCrossReady);
end;

function TPasSemaProject.AnalyzeStaged(const ARoots, APriority: TArray<string>;
  const ACancelled: TFunc<Boolean>;
  const AOnProgress: TProc<TPasStagedProgress>): Integer;
const
  // Batch slice: big enough to keep every core busy, small enough that the
  // progress counter keeps moving and a Cancel never waits longer than one
  // slice (the first implementation loaded a several-hundred-file discovery
  // round as ONE silent batch — the counter froze for seconds, and a project
  // switch blocked the UI in the session drain for just as long).
  CHUNK = 64;
var
  LProgress: TPasStagedProgress;
  LDone, LN, LIdx, LScanFrom: Integer;
  LNewPaths, LOrdered: TArray<string>;
  LPath, LKey: string;
  LSeen: TDictionary<string, Boolean>;
  LSW: TStopwatch;

  procedure StageMark(const AName: string);
  begin
    FStageTimings := FStageTimings +
      Format('%s=%d;', [AName, LSW.ElapsedMilliseconds]);
    LSW := TStopwatch.StartNew;
  end;

  function Cancelled: Boolean;
  begin
    Result := Assigned(ACancelled) and ACancelled();
  end;

  procedure Recount;
  var
    LI: Integer;
  begin
    LProgress.Total := FModels.Count;
    LProgress.IntfDone := 0;
    LProgress.FullDone := 0;
    for LI := 0 to FStatus.Count - 1 do
    begin
      if FStatus[LI] >= msIntfReady then
        Inc(LProgress.IntfDone);
      if FStatus[LI] >= msFullReady then
        Inc(LProgress.FullDone);
    end;
  end;

  procedure Report(const APhase: string);
  begin
    LProgress.Phase := APhase;
    if Assigned(AOnProgress) then
      AOnProgress(LProgress);
  end;

  // Uses-closure paths not yet loaded, discovered from models [AFrom..AToExcl).
  function DiscoverUses(AFrom, AToExcl: Integer): TArray<string>;
  var
    LI, LK: Integer;
    LP: string;
  begin
    Result := nil;
    for LI := AFrom to AToExcl - 1 do
      for LK := 0 to High(FModels[LI].UsesList) do
        if FSM.ResolveUnit(FModels[LI].UsesList[LK].NameFull,
          FModels[LI].UsesList[LK].InPath, FFiles[LI], LP) and
          not FByPath.ContainsKey(LowerCase(LP)) and
          not LSeen.ContainsKey(LowerCase(LP)) then
        begin
          LSeen.Add(LowerCase(LP), True);
          Result := Result + [LP];
        end;
  end;

  // Loads APaths in CHUNK slices — progress report and cancellation check
  // between slices. False = cancelled part-way (loaded slices stay published).
  function LoadChunked(const APaths: TArray<string>; AIntf: Boolean;
    const APhase: string): Boolean;
  var
    LFrom, LTo: Integer;
  begin
    Result := True;
    LFrom := 0;
    while LFrom <= High(APaths) do
    begin
      if Cancelled then
        Exit(False);
      LTo := LFrom + CHUNK - 1;
      if LTo > High(APaths) then
        LTo := High(APaths);
      LoadFilesParallel(Copy(APaths, LFrom, LTo - LFrom + 1), AIntf);
      Recount;
      Report(APhase);
      LFrom := LTo + 1;
    end;
  end;

  // Upgrades every msIntfReady module to a full model: the compute (reparse
  // reusing the intf snapshot's whole-file lex+PP, then Phase 1) farms one
  // worker per core, the commit (model swap + status) is sequential between
  // chunks — the same pure-compute/sequential-commit discipline as
  // LoadFilesParallel. The first implementation upgraded ONE MODULE AT A
  // TIME on the single worker thread — the dominant perf loss vs the batch
  // driver on a big project. False = cancelled part-way.
  function UpgradeChunked: Boolean;
  var
    LIds: TArray<Integer>;
    LNew: TArray<TPasSemaModel>;
    LI, LFrom, LTo: Integer;
  begin
    Result := True;
    LIds := nil;
    for LI := 0 to FStatus.Count - 1 do
      if FStatus[LI] = msIntfReady then
        LIds := LIds + [LI];
    LFrom := 0;
    while LFrom <= High(LIds) do
    begin
      if Cancelled then
        Exit(False);
      LTo := LFrom + CHUNK - 1;
      if LTo > High(LIds) then
        LTo := High(LIds);
      SetLength(LNew, LTo - LFrom + 1);
      ForEachIndex(LTo - LFrom,
        procedure(AIdx: Integer)
        var
          LDiags: TArray<TPasParseDiag>;
        begin
          try
            // Tree.Source always covers the WHOLE file (stage 1 stops only
            // the parser, never the preprocessor) — so the upgrade pays
            // parse + Phase 1 only, per the plan's §2.2 "reparse reusing
            // stage-1 artifacts". Re-preprocessing here would double-pay
            // lex+PP for the entire closure (the single biggest perf
            // regression of the first implementation), and building from
            // the SAME token layer also keeps the prefix invariant safe
            // against a file changing on disk between the waves.
            LNew[AIdx] := TPasSemaResolver.Analyze(TPasParser.ParseFile(
              FModels[LIds[LFrom + AIdx]].Tree.Source, LDiags, False));
          except
            on Exception do
              LNew[AIdx] := nil;   // keep the interface snapshot
          end;
        end);
      for LI := 0 to LTo - LFrom do
        if LNew[LI] <> nil then
        begin
          FModels[LIds[LFrom + LI]] := LNew[LI]; // owns-list frees the intf one
          FStatus[LIds[LFrom + LI]] := msFullReady;
        end;
      Recount;
      Report('full');
      LFrom := LTo + 1;
    end;
  end;

begin
  Result := -1;
  FStageTimings := '';
  LProgress := Default(TPasStagedProgress);
  LSeen := TDictionary<string, Boolean>.Create;
  try
    LSW := TStopwatch.StartNew;
    // Front-load the priority set (open module + its uses), then the roots.
    LOrdered := nil;
    for LPath in APriority + ARoots do
    begin
      LKey := LowerCase(TPath.GetFullPath(LPath));
      if not LSeen.ContainsKey(LKey) then
      begin
        LSeen.Add(LKey, True);
        LOrdered := LOrdered + [LPath];
      end;
    end;

    // The implicit System unit is part of every closure (1.2.1) but never
    // named in a `uses` clause — pull it in up front (full, like
    // AnalyzeProject) so wave 1's BFS also walks its uses and the finalizer
    // covers it. Matches AnalyzeProject's early EnsureSystemUnit. SysInit
    // rides along the same way.
    EnsureSystemUnit;
    EnsureSysInitUnit;

    // ---- Wave 1: interface-only closure (breadth-first) ----
    Report('intf');
    if not LoadChunked(LOrdered, {AIntf} True, 'intf') then
    begin
      Report('cancelled');
      Exit;
    end;
    LDone := 0;
    while LDone < FModels.Count do
    begin
      LN := FModels.Count;
      LNewPaths := DiscoverUses(LDone, LN);
      if not LoadChunked(LNewPaths, {AIntf} True, 'intf') then
      begin
        Report('cancelled');
        Exit;
      end;
      LDone := LN;
    end;
    StageMark('intf');

    // ---- Wave 2: upgrade every module to a full parse, discovering any
    // implementation-only dependencies the interface trees didn't show ----
    Report('full');
    // The FIRST discovery round after the upgrades must rescan EVERY model
    // (implementation uses only just became visible); later rounds only the
    // newly loaded ones (they arrive as full trees already).
    LScanFrom := 0;
    repeat
      if not UpgradeChunked then
      begin
        Report('cancelled');
        Exit;
      end;
      LN := FModels.Count;
      LNewPaths := DiscoverUses(LScanFrom, LN);
      LScanFrom := LN;
      if not LoadChunked(LNewPaths, {AIntf} False, 'full') then
      begin
        Report('cancelled');
        Exit;
      end;
    until FModels.Count = LN;
    StageMark('full');

    // ---- Finalizer: cross passes over the whole closure. Reported as
    // sub-phases (they take real seconds on a big project — a single silent
    // 'cross' looked like a hang), with a cancel point between passes. ----
    LN := FModels.Count;
    Report('cross:resolve');
    for LIdx := 0 to LN - 1 do
      ResolveUses(LIdx);
    if Cancelled then
    begin
      Report('cancelled');
      Exit;
    end;
    Report('cross:xresolve');
    ForEachIndex(LN - 1,
      procedure(AIdx: Integer)
      begin
        CrossResolve(AIdx);
      end);
    if Cancelled then
    begin
      Report('cancelled');
      Exit;
    end;
    Report('cross:inherited');
    RunInheritedPass(LN);
    if Cancelled then
    begin
      Report('cancelled');
      Exit;
    end;
    Report('cross:calls');
    ForEachIndex(LN - 1,
      procedure(AIdx: Integer)
      begin
        CheckCalls(AIdx);
      end);
    if Cancelled then
    begin
      Report('cancelled');
      Exit;
    end;
    Report('cross:bindx');
    for LIdx := 0 to FModels.Count - 1 do
      BindTypesX(LIdx);
    Report('cross:xtype');
    for LIdx := 0 to LN - 1 do
      CrossType(LIdx);
    MarkAllCrossReady;
    StageMark('cross');
    Recount;
    Report('done');

    if Length(ARoots) > 0 then
      FByPath.TryGetValue(LowerCase(TPath.GetFullPath(ARoots[0])), Result);
  finally
    LSeen.Free;
  end;
end;

end.
