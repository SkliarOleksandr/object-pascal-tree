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

  // One `class/record helper for T` (15.3) declared in some model.
  //
  // Extended-type identity: a concrete type is (declaring model, symbol),
  // stable across every referring unit. A BUILTIN target keeps its NAME
  // instead — every model seeds its own string/TObject/... symbols, so the
  // identity must be re-resolved per referring model (BuildHelperMap phase B).
  //
  // Exported = declared in (or nested under) the interface section; an
  // implementation-section helper is unit-local (dcc-verified, spec 15.3.4).
  TPasHelperReg = record
    TargetUnit: Integer;      // NIL_SYM => builtin target, use TargetName
    TargetSym: Integer;
    TargetName: string;       // lower-case; builtin targets only
    HelperMid: Integer;       // model the helper is declared in
    Sym: Integer;             // the helper's own skType symbol
    Exported: Boolean;
  end;

  // One deferred ExtRefMap write from the inherited-member pass (computed in
  // parallel, committed sequentially — see CrossResolveInherited).
  TPasInhPending = record
    Node: Integer;
    Ext: TPasExtRef;
    // Filled by the WITH pass only (XNil from the inherited pass): the
    // member's declared type ALREADY SUBSTITUTED in the with-target's
    // instantiation frame. It has to travel with the pending entry because
    // the frame is only known while the target is being typed — by the time
    // CrossType sees the bare ident there is no with-target context left, so
    // it would type `FValue` as the open parameter T instead of Integer
    // (`with FThreads.LockList do` — a TList<TBaseWorkerThread>).
    X: TSemaXType;
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
    FLoadFailures: TArray<string>;         // see LoadFailures
    { Candidate node lists for the two body passes — see EnsureCrossWork. One
      slot per model; a worker only ever touches its OWN slot. }
    FInhWork: TArray<TArray<Integer>>;
    FWithWork: TArray<TArray<Integer>>;
    FWorkBuilt: TArray<Boolean>;
    { Declaration-site idents CrossResolve could bind NOWHERE — see
      CrossResolveDecl. Filled by the CrossResolve workers (own slot only),
      drained by the decl pass. }
    FDeclWork: TArray<TArray<Integer>>;
    { Per-model overlay of the member references CrossType discovers, so the
      parallel walks never mutate a dictionary another walk is reading — see
      RunCrossTypePass. Owned here; merged and freed there. }
    FXNewExt: TArray<TDictionary<Integer, TPasExtRef>>;
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
    // Cross-unit helper injection (15.3). FModelHelpers is the raw per-model
    // list of DECLARED helpers; FHelperIdx is what the hot path reads: per
    // REFERRING model, extended-type key -> the single ACTIVE helper, with
    // precedence already applied. Per model because the active helper is a
    // property of the referring unit, not of the type (15.3.3, dcc-verified
    // as ordinary last-uses-wins).
    //
    // Both are built SEQUENTIALLY by BuildHelperMap and read-only afterwards,
    // so the parallel inherited/with workers need NO lock. An earlier
    // revision instead memoized on demand behind a critical section, keyed by
    // built-up strings: that cost 16% of total analysis time on a 665-unit
    // corpus, all of it hot-path allocation and lock traffic (the scan itself
    // measured 4 ms).
    FModelHelpers: TArray<TArray<TPasHelperReg>>;
    FHelperIdx: TArray<TDictionary<Int64, TPasExtRef>>;   // nil = sees none
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
    function InPropertySpecifier(AModel: TPasSemaModel; ANode: Integer): Boolean;
    function OuterStructsOfNode(AModel: TPasSemaModel;
      ANode, AInnermost: Integer): TArray<Integer>;
    function DeclStructsOfNode(AModel: TPasSemaModel;
      ANode: Integer): TArray<Integer>;
    // `with` over a target whose TYPE lives in another unit (ch.05 §5.7) —
    // see FindInEnclosingWith.
    function PointeeX(const AX: TSemaXType): TSemaXType;
    function PointeeOfDeclX(AId, ABaseNode: Integer): TSemaXType;
    function DesignatorSymX(AId, ANode: Integer;
      out AMid, ASym: Integer): Boolean;
    function AncestorOfX(const AX: TSemaXType): TSemaXType;
    { The single answer to "what type is this member?" — see the implementation
      for why a bare property redeclaration makes it necessary. }
    function SymDeclTypeX(AMid, ASym: Integer): TSemaXType;
    function IsDefaultArrayProp(AMid, ASym: Integer): Boolean;
    function DefaultArrayPropX(const AX: TSemaXType;
      out AMid, ASym: Integer; out AOwner: TSemaXType): Boolean;
    function RoutineHasParams(AMid, ASym: Integer): Boolean;
    function ParamlessOverloadX(const AX: TSemaXType;
      const ANameLower: string; out AMid, ASym, ACtx: Integer): Boolean;
    function ElementX(AId, ABaseNode: Integer): TSemaXType;
    function WithTargetTypeX(AId, ANode: Integer): TSemaXType;
    function InsideWithBody(AModel: TPasSemaModel; ANode: Integer): Boolean;
    function InsideLaterWithTarget(AModel: TPasSemaModel;
      ANode: Integer): Boolean;
    function FindInEnclosingWith(AId, ANode: Integer;
      const ANameLower: string; out AUid, ASym: Integer;
      out AX: TSemaXType): Boolean;
    procedure CrossResolveInherited(AId: Integer;
      var APending: TArray<TPasInhPending>);
    procedure EnsureCrossWork(AId: Integer);
    procedure SizeCrossWork(ACount: Integer);
    procedure PrepareDeclWork(ACount: Integer);
    procedure CrossResolveDecl(AId: Integer;
      var APending: TArray<TPasInhPending>; AEmit: Boolean);
    procedure RunDeclPass(ACount: Integer);
    procedure RunInheritedPass(ACount: Integer);
    { AEmit=False computes bindings only; E2003 is left to the final round —
      see RunWithPass, which iterates this to a fixpoint. }
    procedure CrossResolveWith(AId: Integer;
      var APending: TArray<TPasInhPending>; AEmit: Boolean);
    procedure RunWithPass(ACount: Integer);
    function FindInUses(AId: Integer; const ANameLower: string;
      out AUnit, ASym: Integer): Boolean;
    function ArityOfTypeSym(AMid, ASym: Integer): Integer;
    function FindTypeInSelfArity(AId: Integer; const ANameLower: string;
      AArity: Integer; out ASym: Integer): Boolean;
    function FindTypeInUsesArity(AId: Integer; const ANameLower: string;
      AArity: Integer; out AUnit, ASym: Integer): Boolean;
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
    function CalleeShadowsUses(AModel: TPasSemaModel;
      ACallee, ALocalSym: Integer): Boolean;
    procedure CheckCalls(AId: Integer);
    // Phase 3c: cross-model typing.
    function Instantiate(const ABase: TSemaXType;
      const AArgs: TArray<TSemaXType>): Integer;
    function InstanceRead(AInst: Integer): TSemaInstance;
    function TypeDefNodeOf(AMid, ASym: Integer): Integer;
    function GenericParamIdents(AMid, ASym: Integer): TArray<Integer>;
    function GenericParamConstraints(AMid,
      ASym: Integer): TArray<TArray<Integer>>;
    function RealGenericBase(const AX: TSemaXType): TSemaXType;
    function XDescendsFrom(const ADesc, ABase: TSemaXType): Boolean;
    procedure CheckConstraints(AId: Integer);
    function DeclTypeX(AMid, ASym: Integer): TSemaXType;
    function SubstX(const AX: TSemaXType; AInst, ADepth: Integer): TSemaXType;
    function ResolveTypeExpr(AId, ANode: Integer;
      ABare: Boolean = True): TSemaXType;
    function PreferNonGeneric(AId, AMid, ASym,
      ANameNode: Integer): TSemaXType;
    function TypeSlotByNameX(AMid, ANode: Integer): TSemaXType;
    function IsGenericTypeSym(AMid, ASym: Integer): Boolean;
    function ClassRefTargetX(const AX: TSemaXType): TSemaXType;
    function ResolveTypeExprNested(AId, ANode: Integer): TSemaXType;
    procedure BuildHelperMap;
    procedure ClearHelperIdx;
    function HelperMemberHit(AFromMid: Integer; const ACur: TSemaXType;
      const ANameLower: string; out AMemMid, AMemSym: Integer): Boolean;
    function FindMemberX(AFromMid: Integer; const ABase: TSemaXType;
      const ANameLower: string;
      out AMemMid, AMemSym: Integer; out ACtx: Integer): Boolean;
    function IsConstructorSym(AMid, ASym: Integer): Boolean;
    // Cross-model overload selection (CrossType's call typing):
    function XCatOf(const AX: TSemaXType): TSemaTypeCat;
    function XSameType(const A, B: TSemaXType): Boolean;
    function XAssignableX(const ADst, ASrc: TSemaXType): Boolean;
    function XParamSyms(AMid, ASym: Integer): TArray<Integer>;
    function InferMethodFrame(AMid, ASym: Integer;
      const AArgTypes: TArray<TSemaXType>; ACtx: Integer): Integer;
    procedure BindTypesX(AId: Integer);
    procedure CrossType(AId: Integer);
    procedure RunCrossTypePass(ACount: Integer);
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
    { Width of the default thread pool for every parallel pass, pinned once per
      process. 0 = physical-core width, which is where measurement puts the
      optimum; letting the pool grow costs ~30% of total analysis time. Call
      BEFORE the first TPasSemaProject is created to override; later calls and
      calls after the first are ignored. See the implementation for the numbers
      and for why a library is touching the process-wide pool at all. }
    class procedure ConfigureThreadPool(AWorkers: Integer);
    function StageTimings: string;
    { Units that could not be parsed at all, as 'file: EClass: message'.
      A unit in here is treated as unresolvable, so its importers report F1027 —
      which is why the list must be surfaced: F1027 says "no source on the
      search path", and for these the source IS there and WE failed on it.
      Non-empty means an analyzer defect, not a project problem. }
    function LoadFailures: TArray<string>;
    function ModelCount: Integer;
    function Model(AId: Integer): TPasSemaModel;
    function ModelFile(AId: Integer): string;
    { Source position of ANY node in AId, as a clickable site: the file the
      node's FIRST token really came from (NOT ModelFile — an $I-included file
      is a different path), 1-based line/col. False if AId/ANode is out of
      range or the node carries no token. This is the same mapping EmitAt uses
      for a diagnostic, exposed because hosts also need to point at nodes that
      never produced one — e.g. the `uses` item that first imported a unit
      whose source could not be found. }
    function NodeSite(AId, ANode: Integer; out AFilePath: string;
      out ALine, ACol: Integer): Boolean;
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
  System.Math,
  PasTree.Parser,
  PasTree.Sema.Resolver,
  PasTree.Sema.Diagnostics;

var
  // Process-wide, set once — see TPasSemaProject.ConfigureThreadPool.
  GPoolConfigured: Boolean = False;

{ Pin the default thread pool's width instead of letting it grow.

  Every parallel pass here is allocation-heavy — a token stream, a tree and a
  model per unit — and Delphi's memory manager SPINS on contention rather than
  sleeping. TThreadPool grows its worker count when it thinks workers are
  blocked, and it cannot tell spinning from blocking, so it adds threads, which
  adds contention, which looks like more blocking. Measured on the 665-unit
  corpus, that spiral is the single most expensive thing in the analysis:

    workers   total    load    CPU spent in parse+Phase 1
    pool grows (old)   2643 ms 1540 ms  ~20.5 s
    16                 2033    1061     ~11.0 s
    8                  1853     937      ~5.8 s
    4                  1891     926      ~3.4 s
    1                  5352    2300      ~1.6 s

  Same work, an order of magnitude more CPU at the wide end, and WORSE wall
  time. Physical-core width (logical div 2 on an SMT machine) sits at the
  optimum and is what 0 selects. The 4-vs-8 difference is inside the noise here,
  so the rule is deliberately coarse.

  NB this configures the PROCESS-WIDE default pool, which a library should not do
  silently — hence a public knob to override it, and a documented default. A
  private pool was tried before and behaved pathologically (see the note in
  PasTree.SourceManager): SetMaxWorkerThreads REFUSES values below the pool's
  MinWorkerThreads, which defaults to the CPU count, so Min must come down
  first. }
class procedure TPasSemaProject.ConfigureThreadPool(AWorkers: Integer);
var
  LWant: Integer;
begin
  if GPoolConfigured then
    Exit;
  GPoolConfigured := True;
  LWant := AWorkers;
  if LWant <= 0 then
    LWant := Max(2, CPUCount div 2);
  // Min first: Max refuses anything below the current Min.
  TThreadPool.Default.SetMinWorkerThreads(LWant);
  TThreadPool.Default.SetMaxWorkerThreads(LWant);
end;

constructor TPasSemaProject.Create(APlatform: TPasPlatform;
  const ASearchPaths: TArray<string>; const AExtraDefines: TArray<string>);
var
  LName: string;
begin
  inherited Create;
  ConfigureThreadPool(0);
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
  ClearHelperIdx;
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

function TPasSemaProject.NodeSite(AId, ANode: Integer; out AFilePath: string;
  out ALine, ACol: Integer): Boolean;
var
  LM: TPasSemaModel;
  LVis: TPasVisibleToken;
  LTok: Integer;
begin
  AFilePath := ''; ALine := 0; ACol := 0;
  Result := False;
  if (AId < 0) or (AId >= FModels.Count) then
    Exit;
  LM := FModels[AId];
  if (LM = nil) or (ANode < 0) or (ANode > High(LM.Tree.Nodes)) then
    Exit;
  LTok := LM.Tree.Nodes[ANode].FirstToken;
  if (LTok < 0) or (LTok > High(LM.Tree.Source.Visible)) then
    Exit;
  LVis := LM.Tree.Source.Visible[LTok];
  AFilePath := LM.Tree.Source.FileNames[LVis.FileId];
  LM.Tree.Source.Files[LVis.FileId].OffsetToLineCol(
    LM.Tree.Source.Files[LVis.FileId].Tokens[LVis.TokenIndex].Start,
    ALine, ACol);
  Result := True;
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
  LFailLock: TCriticalSection;
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
  LFailLock := TCriticalSection.Create;
  try

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
          on E: Exception do
          begin
            LDone[AIndex] := nil;   // registered as known-bad below
            // Keep WHY. Swallowing this made an internal defect indistinguish-
            // able from a missing file: the unit ended up cached as known-bad,
            // and its importers then reported F1027 "no source on the search
            // path" for a file sitting right there. That cost a day of chasing
            // a phantom search-path problem before a trace showed the real
            // cause (an ERangeError inside Phase 1). Tolerating the failure is
            // still right — one bad unit must not sink an analysis — but it has
            // to be tolerated OUT LOUD.
            LFailLock.Enter;
            try
              FLoadFailures := FLoadFailures +
                [Format('%s: %s: %s', [TPath.GetFileName(LTodo[AIndex]),
                  E.ClassName, E.Message])];
            finally
              LFailLock.Leave;
            end;
          end;
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
  finally
    LFailLock.Free;
  end;
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
    begin
      LModel.AllUsesResolved := False;
      // Report it. This used to be silent, which hid TWO things at once: that
      // an import was missing, and — because AllUsesResolved gates E2003 —
      // that every undeclared identifier in this unit was being suppressed as
      // a consequence. A unit could look clean when it had simply not been
      // checked. Anchored on the `uses` name node so a host can navigate to it.
      EmitAt(LModel, LModel.UsesList[LIdx].NameNode, 'F1027',
        Format(SF1027_UnitSourceNotFound, [LModel.UsesList[LIdx].NameFull]));
    end;
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

// The generic ARITY of a type symbol: 0 for a plain type, else its parameter
// count. The zero case is the cheap flag; only a generic pays the walk.
function TPasSemaProject.ArityOfTypeSym(AMid, ASym: Integer): Integer;
begin
  if not IsGenericTypeSym(AMid, ASym) then
    Result := 0
  else
    Result := Length(GenericParamIdents(AMid, ASym));
end;

{ The same arity search, but in the referring unit's OWN interface scope.

  The NextOverload chain links arities declared in one SCOPE, and the uses
  search covers OTHER units — between them sits the case that has neither: the
  two arities are declared in the same unit but in different sections. One
  editor library writes exactly that, and the shape is idiomatic rather than
  odd — a generic in the interface plus

      TSomeProvider = class(TSomeProvider<TSomeControl>);

  in the IMPLEMENTATION, to give the common instantiation a plain name. The
  implementation declaration is the nearer one, so the heritage reference inside
  it resolved to the class ITSELF, that class then had no ancestor at all, and
  every inherited member named from the generic's own method bodies was a false
  E2003. }
function TPasSemaProject.FindTypeInSelfArity(AId: Integer;
  const ANameLower: string; AArity: Integer; out ASym: Integer): Boolean;
var
  LModel: TPasSemaModel;
  LSym: Integer;
begin
  Result := False;
  LModel := FModels[AId];
  if LModel.InterfaceScope = NIL_SCOPE then
    Exit;
  LSym := LModel.Resolve(LModel.InterfaceScope, ANameLower);
  if (LSym <> NIL_SYM) and (LModel.Symbols[LSym].Kind = skType) and
     (ArityOfTypeSym(AId, LSym) = AArity) then
  begin
    ASym := LSym;
    Result := True;
  end;
end;

{ FindInUses, restricted to a type of a GIVEN generic arity — see
  PreferNonGeneric for why a wrong-arity candidate must not end the search. Same
  last-uses-wins order among the candidates that do qualify, then the implicit
  System unit.

  BOTH directions of the mistake are real, and both are set by the RTL's or a
  component library's own naming: a BARE name that has to skip an imported
  GENERIC, and a `Name<T>` that has to skip an imported NON-generic. The second
  hides better, because the reference looks unambiguous — `TdxPDFObjectList<T>`
  reads like it can only mean the generic, but the plain class of that name in
  another unit is what the ordinary lookup returns. }
function TPasSemaProject.FindTypeInUsesArity(AId: Integer;
  const ANameLower: string; AArity: Integer;
  out AUnit, ASym: Integer): Boolean;
var
  LModel, LUsed: TPasSemaModel;
  LIdx, LUid, LSym: Integer;
begin
  Result := False;
  LModel := FModels[AId];
  for LIdx := High(LModel.UsesList) downto 0 do
  begin
    LUid := LModel.UsesList[LIdx].UnitId;
    if LUid < 0 then
      Continue;
    LUsed := FModels[LUid];
    if LUsed.InterfaceScope = NIL_SCOPE then
      Continue;
    LSym := LUsed.Resolve(LUsed.InterfaceScope, ANameLower);
    if (LSym <> NIL_SYM) and (LUsed.Symbols[LSym].Kind = skType) and
       (ArityOfTypeSym(LUid, LSym) = AArity) then
    begin
      AUnit := LUid;
      ASym := LSym;
      Exit(True);
    end;
  end;
  if FindInSystemUnit(ANameLower, LUid, LSym) and
     (FModels[LUid].Symbols[LSym].Kind = skType) and
     (ArityOfTypeSym(LUid, LSym) = AArity) then
  begin
    AUnit := LUid;
    ASym := LSym;
    Result := True;
  end;
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
  // A unit may qualify with its OWN name — Winapi.Windows.pas calls
  // `Winapi.Windows.DrawText(...)` from an overload of DrawText to reach the
  // other one unambiguously. It is not in its own UsesList, so the loop below
  // can never find it; checked here, before the implicit units, since a unit
  // legitimately named System would mean itself too.
  if SameText(LText, LM.UnitNameLower) then
    Exit(AId);
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

// True when ACallee (a call's callee identifier) is already bound to a
// declaration NEARER than any used unit's globals — so those globals are
// shadowed and must NOT be gathered as arity candidates for this call.
// Covers: a method reached through implicit Self (same-unit, via RefMap's
// struct-scoped symbol; or inherited from a CROSS-unit ancestor, which lands
// in ExtRefMap via the inherited-member pass), a nested routine, and a
// local/param/field/property of procedural type called through its value.
//
// dcc-verified: inside `TStrings.IndexOfObject`, unqualified
// `GetObject(Result)` means `TStrings.GetObject(Index)` — Winapi.Windows'
// 3-parameter GDI `GetObject`, though perfectly visible through
// System.Classes' own `uses`, simply is not a candidate. Gathering it anyway
// made a 1-argument call look like it was missing two (real bug: E2035 on
// System.Classes.pas:7230).
//
// sckSystem is deliberately NOT treated as shadowing: a used unit's global
// DOES override a compiler builtin of the same name, so for a builtin
// binding the sweep is still the right thing.
function TPasSemaProject.CalleeShadowsUses(AModel: TPasSemaModel;
  ACallee, ALocalSym: Integer): Boolean;
var
  LExt: TPasExtRef;
  LScope: Integer;
begin
  if ALocalSym <> NIL_SYM then
  begin
    // A NON-routine binding shadows outright, wherever it sits. Only a ROUTINE
    // can join a used unit's same-named routines in an overload set, so for
    // anything else the sweep would be comparing the call against candidates
    // that were never in the running. dcc-verified: a unit-level
    // `Compare: TCompareFunc` (a procedural-type VAR) shadows an imported
    // 2-parameter `Compare`, and a 3-argument call through it compiles. Testing
    // only the SCOPE KIND missed exactly that — the var is at unit level, so it
    // looked like a candidate for merging.
    if AModel.Symbols[ALocalSym].Kind <> skRoutine then
      Exit(True);
    LScope := AModel.Symbols[ALocalSym].Scope;
    Result := (LScope <> NIL_SCOPE) and
      not (AModel.Scopes[LScope].Kind in
        [sckUnit, sckImplementation, sckSystem]);
    Exit;
  end;
  // Not locally bound. An inherited MEMBER found by CrossResolveInherited
  // still shadows; a used unit's own unit-level global — the very thing the
  // sweep exists to check — does not.
  Result := False;
  if AModel.ExtRefMap.TryGetValue(ACallee, LExt) then
  begin
    LScope := FModels[LExt.UnitId].Symbols[LExt.Sym].Scope;
    Result := (LScope <> NIL_SCOPE) and
      (FModels[LExt.UnitId].Scopes[LScope].Kind = sckStruct);
  end;
end;

// Defined with the rest of the Phase-3c helpers just below; CheckCalls needs it
// for its inherited-member gate.
function XPlain(AMid, ASym: Integer): TSemaXType; forward;

// Cross-unit argument-count check: gathers a call's candidate routines from the
// local overload chain PLUS every resolved used unit's interface, then flags
// E2035/E2034 only if no candidate's arity admits the argument count. Runs only
// for units with resolved uses (complete candidate visibility).
procedure TPasSemaProject.CheckCalls(AId: Integer);
var
  LModel: TPasSemaModel;
  LNode, LCallee, LArg, LArgCount, LLocalHead, LUid, LS, LIdx: Integer;
  LMinReq, LMaxTot, LStruct: Integer;
  LAnyFit, LAnyVariadic, LHaveAny, LSkip: Boolean;
  LName: string;
  LExt: TPasExtRef;

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
    // Whatever this call means, it is NOT one of the used units' globals —
    // so the sweep below would only gather irrelevant same-named candidates
    // and arity-check against them. See CalleeShadowsUses.
    if CalleeShadowsUses(LModel, LCallee, LLocalHead) then
      Continue;

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
    begin
      Consider(AId, LLocalHead);
      // 6.4: an IMPLEMENTATION-section overload joins the interface section's
      // set for the same unit, but the two are separate symbols in separate
      // scopes — deliberately, since chaining them would export an
      // implementation-only overload to every importer. So a call written
      // inside the implementation resolves to the nearer (impl) head and must
      // still be measured against the interface ones. dcc-verified; without it
      // a call to the INTERFACE overload looks short of arguments (4 sites in
      // one encoding unit, on a 3-parameter interface overload sitting beside a
      // 4-parameter implementation-only one).
      if LModel.Scopes[LModel.Symbols[LLocalHead].Scope].Kind =
           sckImplementation then
      begin
        LS := LModel.FindLocal(LModel.InterfaceScope,
          LModel.Symbols[LLocalHead].NameLower);
        if (LS <> NIL_SYM) and (LModel.Symbols[LS].Kind = skRoutine) then
          Consider(AId, LS);
      end;
    end;

    // Same-named routines from every resolved used unit.
    if not LSkip then
    begin
      LName := LModel.Tree.NodeNameLower(LCallee);
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
    // Last gate before reporting: an INHERITED member of the enclosing struct
    // outranks a unit-level global of the same name, so none of the candidates
    // gathered above was ever the callee. This is CalleeShadowsUses' rule for a
    // member the intra-unit pass could not see — CollectStruct never joins an
    // ancestor's scope, so `GetFileNames(FShellItems)` inside
    // TCustomFileOpenDialog.GetResults (FMX.Dialogs.Win) bound the 4-parameter
    // implementation-section procedure instead of TCustomFileDialog's
    // 1-parameter method, and a 1-argument call then looked short by three.
    // dcc-verified: that unit compiles, so the method wins.
    //
    // Deliberately HERE and not beside CalleeShadowsUses: this walks ancestors
    // (FindMemberX), and on the error path it runs for a handful of calls
    // instead of every call in the closure.
    LStruct := StructSymOfNode(LModel, LCallee);
    if (LStruct <> NIL_SYM) and
       FindMemberX(AId, XPlain(AId, LStruct),
         LModel.Tree.NodeNameLower(LCallee), LUid, LS, LIdx) then
    begin
      // Re-point while we are here: the binding was wrong, not just the arity,
      // and everything downstream (typing, navigation) reads these maps. Own
      // model only — the same write discipline every parallel pass here follows.
      LModel.RefMap[LCallee] := NIL_SYM;
      LExt.UnitId := LUid;
      LExt.Sym := LS;
      LModel.ExtRefMap.AddOrSetValue(LCallee, LExt);
      Continue;
    end;
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
  // An ANONYMOUS struct's symbol has the struct node ITSELF as its declaration
  // — there is no name node and no nkTypeDecl above it (see DeclareAnonStruct).
  if LM.Tree.Nodes[LName].Kind in [nkRecordType, nkClassType, nkInterfaceType,
     nkObjectType, nkHelperType] then
    Exit(LName);
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
  // A generic TYPE hangs its parameters off the nkTypeDecl; a generic METHOD
  // (16.2.1, `function Wrap<T>(...)`) off its nkRoutine. Both are read the
  // same way from there, which is what lets ONE substitution frame serve
  // either — see InferMethodFrame.
  LParent := LM.Tree.Nodes[LName].Parent;
  if (LParent = NIL_NODE) or not (LM.Tree.Nodes[LParent].Kind in
     [nkTypeDecl, nkRoutine]) then
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

{ Parallel to GenericParamIdents: each parameter's CONSTRAINT nodes. One entry
  per parameter, in the same order, so index i of both describes one parameter.
  Constraints are declared per GROUP (`<T; U: class, constructor>`), so every
  ident in a group shares that group's list. }
function TPasSemaProject.GenericParamConstraints(AMid,
  ASym: Integer): TArray<TArray<Integer>>;
var
  LM: TPasSemaModel;
  LName, LParent, LGen, LParam, LP: Integer;
  LGroup: TArray<Integer>;
  LCount: Integer;
begin
  Result := nil;
  LM := FModels[AMid];
  LName := LM.Symbols[ASym].DeclNode;
  if LName = NIL_NODE then
    Exit;
  LParent := LM.Tree.Nodes[LName].Parent;
  if (LParent = NIL_NODE) or not (LM.Tree.Nodes[LParent].Kind in
     [nkTypeDecl, nkRoutine]) then
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
      // Leading idents are the names; the nkConstraint nodes follow them.
      LGroup := nil;
      LCount := 0;
      LP := LM.Tree.Nodes[LParam].FirstChild;
      while (LP <> NIL_NODE) and (LM.Tree.Nodes[LP].Kind = nkIdent) do
      begin
        Inc(LCount);
        LP := LM.Tree.Nodes[LP].NextSibling;
      end;
      while LP <> NIL_NODE do
      begin
        if LM.Tree.Nodes[LP].Kind = nkConstraint then
          LGroup := LGroup + [LP];
        LP := LM.Tree.Nodes[LP].NextSibling;
      end;
      while LCount > 0 do
      begin
        Result := Result + [LGroup];
        Dec(LCount);
      end;
    end;
    LParam := LM.Tree.Nodes[LParam].NextSibling;
  end;
end;

{ Class-inheritance test across models: is ADesc ABase, or a descendant of it?
  Follows the FIRST heritage entry (the ancestor) and the implicit TObject,
  the same walk FindMemberX uses, depth-capped for the same reason. }
function TPasSemaProject.XDescendsFrom(const ADesc,
  ABase: TSemaXType): Boolean;
var
  LCur, LNext: TSemaXType;
  LM: TPasSemaModel;
  LDef, LChild, LDepth, LRMid, LRSym: Integer;
begin
  Result := False;
  LCur := ADesc;
  for LDepth := 1 to 32 do
  begin
    if not XValid(LCur) then
      Exit;
    if (LCur.UnitId = ABase.UnitId) and (LCur.Sym = ABase.Sym) then
      Exit(True);
    LM := FModels[LCur.UnitId];
    LDef := TypeDefNodeOf(LCur.UnitId, LCur.Sym);
    if LDef = NIL_NODE then
    begin
      if ResolveRealDecl(LCur.UnitId, LM.Symbols[LCur.Sym].NameLower,
           LRMid, LRSym) and
         ((LRMid <> LCur.UnitId) or (LRSym <> LCur.Sym)) then
      begin
        LCur.UnitId := LRMid;
        LCur.Sym := LRSym;
        LCur.Inst := NIL_INST;
        Continue;
      end;
      Exit;
    end;
    case LM.Tree.Nodes[LDef].Kind of
      nkIdent, nkMember, nkTypeArgs:
        LNext := ResolveTypeExpr(LCur.UnitId, LDef);   // alias
      nkClassType:
        begin
          LChild := LM.Tree.Nodes[LDef].FirstChild;
          while (LChild <> NIL_NODE) and not (LM.Tree.Nodes[LChild].Kind in
            [nkIdent, nkMember, nkTypeArgs]) do
            LChild := LM.Tree.Nodes[LChild].NextSibling;
          if LChild = NIL_NODE then
          begin
            // No heritage clause: the implicit TObject (11.1.1).
            if ResolveRealDecl(LCur.UnitId, 'tobject', LRMid, LRSym) and
               ((LRMid <> LCur.UnitId) or (LRSym <> LCur.Sym)) then
            begin
              LCur.UnitId := LRMid;
              LCur.Sym := LRSym;
              LCur.Inst := NIL_INST;
              Continue;
            end;
            Exit;
          end;
          LNext := ResolveTypeExpr(LCur.UnitId, LChild);
        end;
    else
      Exit;
    end;
    if XValid(LNext) and (LNext.UnitId = LCur.UnitId) and
       (LNext.Sym = LCur.Sym) then
      Exit;   // self-referential alias
    LCur := LNext;
  end;
end;

{ 16.4.1 — type-parameter constraints, checked at each instantiation site.

  A DIAGNOSTIC pass, so it is deliberately conservative: every uncertainty
  skips silently. dcc32 37.0 was probed for the exact accepted sets before any
  of this was written, because guessing here means false positives in a
  codebase that currently has none:

    T: class       accepts classes ONLY. Rejects interfaces, `reference to`
                   procedure types, metaclasses (TClass!), and ordinals.
    T: record      accepts records (INCLUDING ones with managed fields),
                   integers, floats, chars, booleans, enums and sets. Rejects
                   string, pointers, Variant, ARRAYS (static and dynamic) and
                   procedural types.
    T: SomeClass   accepts that class and its descendants.

  Not checked, and each for a stated reason:
    T: SomeInterface  needs the implemented-interface list, including the ones
                      inherited from ancestors — a traversal nothing here does
                      yet (FindMemberX deliberately follows only the FIRST
                      heritage entry). Silence is correct until it exists.
    constructor       satisfied by essentially every class, since TObject
                      declares a parameterless constructor. Checking it would
                      cost a member walk to find approximately no bugs. }
procedure TPasSemaProject.CheckConstraints(AId: Integer);
const
  // dcc-verified accepted categories for `T: record`.
  VALUE_CATS = [tcRecord, tcInteger, tcFloat, tcBoolean, tcChar, tcEnum,
    tcSet];
var
  LM: TPasSemaModel;
  LNode, LHead, LArgNode, LIdx, LTok: Integer;
  LBase, LArgX, LConX: TSemaXType;
  LIdents: TArray<Integer>;
  LCons: TArray<TArray<Integer>>;
  LWord, LParamName: string;
  LCat: TSemaTypeCat;
begin
  LM := FModels[AId];
  for LNode := 0 to High(LM.Tree.Nodes) do
  begin
    if LM.Tree.Nodes[LNode].Kind <> nkTypeArgs then
      Continue;
    LHead := LM.Tree.Nodes[LNode].FirstChild;
    if LHead = NIL_NODE then
      Continue;
    LBase := RealGenericBase(ResolveTypeExpr(AId, LHead));
    if not XValid(LBase) then
      Continue;
    LIdents := GenericParamIdents(LBase.UnitId, LBase.Sym);
    LCons := GenericParamConstraints(LBase.UnitId, LBase.Sym);
    if (Length(LIdents) = 0) or (Length(LCons) <> Length(LIdents)) then
      Continue;
    LArgNode := LM.Tree.Nodes[LHead].NextSibling;
    LIdx := 0;
    while (LArgNode <> NIL_NODE) and (LIdx <= High(LIdents)) do
    begin
      LArgX := ResolveTypeExpr(AId, LArgNode);
      // An argument that is itself an open parameter (an instantiation inside
      // another generic's body) constrains nothing until it is closed.
      if XValid(LArgX) and (FModels[LArgX.UnitId].Symbols[LArgX.Sym].Kind <>
         skGenericParam) then
      begin
        LParamName := FModels[LBase.UnitId].Tree.NodeText(LIdents[LIdx]);
        LCat := XCatOf(LArgX);
        for var LC in LCons[LIdx] do
        begin
          // Every LC index belongs to the DECLARING model, never to LM.
          if FModels[LBase.UnitId].Tree.Nodes[LC].FirstChild <> NIL_NODE then
          begin
            // A TYPE constraint. Only a class one is checked (see header).
            // The constraint node lives in the DECLARING model, so it must be
            // resolved there — not in AId, where that node index means
            // something else entirely.
            LConX := ResolveTypeExpr(LBase.UnitId,
              FModels[LBase.UnitId].Tree.Nodes[LC].FirstChild);
            if XValid(LConX) and (XCatOf(LConX) = tcClass) and
               (LCat = tcClass) and not XDescendsFrom(LArgX, LConX) then
              EmitAt(LM, LArgNode, 'E2515',
                Format(SE2515_NotCompatibleWith,
                  [LParamName, XTypeText(LConX)]));
            Continue;
          end;
          // A keyword constraint: class / record / constructor.
          LTok := FModels[LBase.UnitId].Tree.Nodes[LC].FirstToken;
          if (LTok < 0) or
             (LTok > High(FModels[LBase.UnitId].Tree.Source.Visible)) then
            Continue;
          LWord := LowerCase(
            FModels[LBase.UnitId].Tree.Source.VisibleText(LTok));
          if LCat = tcUnknown then
            Continue;   // category not modeled — say nothing
          if (LWord = 'class') and (LCat <> tcClass) then
            EmitAt(LM, LArgNode, 'E2511',
              Format(SE2511_MustBeClass, [LParamName]))
          else if (LWord = 'record') and not (LCat in VALUE_CATS) then
            EmitAt(LM, LArgNode, 'E2512',
              Format(SE2512_MustBeValueType, [LParamName]));
        end;
      end;
      Inc(LIdx);
      LArgNode := LM.Tree.Nodes[LArgNode].NextSibling;
    end;
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

{ The real declaration behind a generic base, when the head of a `Foo<...>`
  resolved to a compiler-seeded BUILTIN. Such a symbol has no source
  declaration and therefore no generic parameter list, so an arity check
  against it always fails and the instantiation degrades to the OPEN generic —
  which is what silently happened to every `TArray<T>` in the codebase, TArray
  being seeded (PasTree.Sema.Builtins). Same redirect FindMemberX does for a
  DeclNode-less builtin. Returns AX unchanged when there is nothing to fix. }
function TPasSemaProject.RealGenericBase(const AX: TSemaXType): TSemaXType;
var
  LRMid, LRSym: Integer;
begin
  Result := AX;
  if not XValid(AX) then
    Exit;
  if TypeDefNodeOf(AX.UnitId, AX.Sym) <> NIL_NODE then
    Exit;
  if ResolveRealDecl(AX.UnitId, FModels[AX.UnitId].Symbols[AX.Sym].NameLower,
       LRMid, LRSym) and ((LRMid <> AX.UnitId) or (LRSym <> AX.Sym)) then
  begin
    Result.UnitId := LRMid;
    Result.Sym := LRSym;
  end;
end;

// A type designator (nkIdent / nkMember / nkTypeArgs) as a cross-model type,
// reading the resolver's RefMap first, then the project's ExtRefMap. For
// nkTypeArgs the args are resolved too and the instantiation is registered;
// an unresolved arg degrades to the plain (open) generic.
{ A type reference that supplies NO type arguments names the arity-0
  declaration (16.1.2) — even when a same-named GENERIC is closer in scope.
  dcc-verified: with `TBase` in unit A and `TBase<T> = class(TBase)` in unit B,
  B's own `TDerived = class(TBase)` means A's.

  DevExpress leans on it: `TdxBarAccessibilityHelper` is a plain class in
  dxBar.pas and `TdxBarAccessibilityHelper<T: TWinControl>` a generic in
  dxBarAccessibility.pas, and the latter unit then writes both spellings. Taking
  the nearer (generic) one is not merely imprecise — the generic's OWN heritage
  is that same bare name, so the walk resolves it to ITSELF and the
  self-reference guard in FindMemberX stops the ancestry dead. 100+ false E2003
  in that library, on names declared three hops up.

  Two places to look, in dcc's own order: the same scope's overload chain
  (16.1.2's arity overloading), then the used units — the cross-UNIT case is
  ordinary shadowing rather than an overload chain, so nothing links the two.
  The generic test is deliberately structural and allocation-free: a generic
  type's member scope hangs off an sckGenericParams scope (CollectTypeDecl), so
  it costs two indexed reads on a path that runs for every type reference. }
function TPasSemaProject.PreferNonGeneric(AId, AMid, ASym,
  ANameNode: Integer): TSemaXType;
var
  LProbe, LDepth, LUid, LFound: Integer;
  LNameLower: string;
begin
  Result := XPlain(AMid, ASym);
  // Reached only for a BARE reference to a GENERIC type — both conditions are
  // tested INLINE by the callers, because this body allocates (NodeNameLower)
  // and every type reference in the closure would otherwise pass through it.
  // Taking the name eagerly measured +7% (1886 -> 2021 ms) on the 665-unit
  // corpus; deriving "is generic" here instead of reading sfGeneric cost a
  // further +1.7%. Same shape as the PasNameKey-on-FindLocal trap.
  LNameLower := FModels[AId].Tree.NodeNameLower(ANameNode);
  LProbe := FModels[AMid].Symbols[ASym].NextOverload;
  for LDepth := 1 to 32 do
  begin
    if LProbe = NIL_SYM then
      Break;
    if (FModels[AMid].Symbols[LProbe].Kind = skType) and
       not IsGenericTypeSym(AMid, LProbe) then
      Exit(XPlain(AMid, LProbe));
    LProbe := FModels[AMid].Symbols[LProbe].NextOverload;
  end;
  // Scan the used units for a NON-generic of that name, rather than asking
  // FindInUses for "the" one. FindInUses answers with last-uses-wins, which is
  // the right rule between equals — but arity is part of the identity, so a
  // generic is not an equal here and must not end the search. `TObjectList` is
  // the case that proves it: non-generic in one RTL unit, generic in another,
  // and a unit importing BOTH gets whichever it happened to import later. Four
  // classes in one debug library then inherited from the wrong TObjectList and
  // lost every member of the real one.
  if FindTypeInUsesArity(AId, LNameLower, 0, LUid, LFound) then
    Result := XPlain(LUid, LFound);
end;

{ T for a `class of T` (15.2.1), XNil for anything else — chasing alias links,
  since a class-reference type is usually reached through one
  (`TPainterClass = class of TPainter`, then a function returning it). The
  member walk already hops through nkClassOf inline; this is the same step for
  callers that need the referenced CLASS as a value type rather than a place to
  look a member up. }
function TPasSemaProject.ClassRefTargetX(const AX: TSemaXType): TSemaXType;
var
  LCur: TSemaXType;
  LDef, LDepth: Integer;
begin
  Result := XNil;
  LCur := AX;
  for LDepth := 1 to 32 do
  begin
    if not XValid(LCur) then
      Exit;
    LDef := TypeDefNodeOf(LCur.UnitId, LCur.Sym);
    if LDef = NIL_NODE then
      Exit;
    case FModels[LCur.UnitId].Tree.Nodes[LDef].Kind of
      nkClassOf:
        Exit(ResolveTypeExpr(LCur.UnitId,
          FModels[LCur.UnitId].Tree.Nodes[LDef].FirstChild));
      nkIdent, nkMember, nkTypeArgs:
        LCur := ResolveTypeExpr(LCur.UnitId, LDef);   // alias link
    else
      Exit;
    end;
  end;
end;

{ The TYPE named by a declaration's type SLOT, looked up by name: the unit's own
  interface scope first, then its used units, then the implicit System unit.

  Only reached from SymDeclTypeX after the normal resolution of that slot came
  back empty, so it is on the error path and its cost does not matter. It must
  NOT be folded into ResolveTypeExpr: that function is also asked "is this
  designator a bare type NAME?" (WithTargetTypeX), and answering yes for a VALUE
  that merely shares a name with a type broke 238 previously-clean units when
  tried that way. }
function TPasSemaProject.TypeSlotByNameX(AMid, ANode: Integer): TSemaXType;
var
  LSym, LUid, LFound, LAId: Integer;
  ANameLower: string;
begin
  Result := XNil;
  // Only a plain NAME has anything to look up; a structural slot (array,
  // pointer, inline record, ...) is not this shape.
  if FModels[AMid].Tree.Nodes[ANode].Kind <> nkIdent then
    Exit;
  ANameLower := FModels[AMid].Tree.NodeNameLower(ANode);
  LAId := AMid;
  LSym := FModels[LAId].Resolve(FModels[LAId].InterfaceScope, ANameLower);
  if (LSym <> NIL_SYM) and
     (FModels[LAId].Symbols[LSym].Kind in [skType, skBuiltinType]) then
    Exit(XPlain(LAId, LSym));
  if (FindInUses(LAId, ANameLower, LUid, LFound) or
      FindInSystemUnit(ANameLower, LUid, LFound)) and
     (FModels[LUid].Symbols[LFound].Kind in [skType, skBuiltinType]) then
    Result := XPlain(LUid, LFound);
end;

// True when ASym is a GENERIC type. Read straight off the flag CollectTypeDecl
// set — see sfGeneric for why this is not derived here.
function TPasSemaProject.IsGenericTypeSym(AMid, ASym: Integer): Boolean;
begin
  Result := sfGeneric in FModels[AMid].Symbols[ASym].Flags;
end;

function TPasSemaProject.ResolveTypeExpr(AId, ANode: Integer;
  ABare: Boolean = True): TSemaXType;
var
  LM: TPasSemaModel;
  LName, LSym, LArgNode, LArgCount, LUid: Integer;
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
        // The generic test is inline so the overwhelmingly common case — a
        // non-generic type reference — costs one set membership and no call.
        if (LSym <> NIL_SYM) and (LM.Symbols[LSym].Kind in
           [skType, skBuiltinType, skGenericParam]) then
        begin
          if ABare and (sfGeneric in LM.Symbols[LSym].Flags) then
            Exit(PreferNonGeneric(AId, AId, LSym, LName));
          Exit(XPlain(AId, LSym));
        end;
        if LM.ExtRefMap.TryGetValue(LName, LExt) and
           (FModels[LExt.UnitId].Symbols[LExt.Sym].Kind in
            [skType, skBuiltinType, skGenericParam]) then
        begin
          if ABare and
             (sfGeneric in FModels[LExt.UnitId].Symbols[LExt.Sym].Flags) then
            Exit(PreferNonGeneric(AId, LExt.UnitId, LExt.Sym, LName));
          Exit(XPlain(LExt.UnitId, LExt.Sym));
        end;
        // Deliberately NOT falling back to a by-name type lookup here:
        // ResolveTypeExpr is also asked "is this designator a bare type name?"
        // (WithTargetTypeX), where answering yes for a VALUE that merely shares
        // a name with a type is wrong. The type-position fallback lives in
        // SymDeclTypeX, which is only ever given a declaration's type slot.
      end;
    // An ANONYMOUS structured type written inline in a type slot. It has no
    // name, so there is nothing in RefMap — but CollectStruct gave it a member
    // scope and DeclareAnonStruct gave that scope a symbol, and the node is the
    // way back to both.
    nkRecordType, nkClassType, nkInterfaceType, nkObjectType:
      if (ANode <= High(LM.NodeScope)) and
         (LM.NodeScope[ANode] <> NIL_SCOPE) and
         (LM.Scopes[LM.NodeScope[ANode]].StructSym <> NIL_SYM) then
        Result := XPlain(AId, LM.Scopes[LM.NodeScope[ANode]].StructSym);

    nkTypeArgs:
      begin
        // ABare=False: the base of `T<...>` is SUPPOSED to be the generic, and
        // this branch does its own arity matching just below.
        LBase := ResolveTypeExpr(AId, LM.Tree.Nodes[ANode].FirstChild, False);
        if not XValid(LBase) then
          Exit;
        LBase := RealGenericBase(LBase);
        LArgs := nil;
        LArgCount := 0;
        LArgNode := LM.Tree.Nodes[LM.Tree.Nodes[ANode].FirstChild].NextSibling;
        while LArgNode <> NIL_NODE do
        begin
          Inc(LArgCount);
          LArgNode := LM.Tree.Nodes[LArgNode].NextSibling;
        end;
        // 16.1.2: one name may be declared at several ARITIES, chained on
        // NextOverload by CollectTypeDecl. Only the head is registered under
        // the name, so pick the declaration whose parameter count matches the
        // arguments actually written. Walking the chain is safe for a type
        // symbol: every other NextOverload consumer reaches the chain through
        // a ROUTINE head.
        if ArityOfTypeSym(LBase.UnitId, LBase.Sym) <> LArgCount then
        begin
          LSym := FModels[LBase.UnitId].Symbols[LBase.Sym].NextOverload;
          while LSym <> NIL_SYM do
          begin
            if (FModels[LBase.UnitId].Symbols[LSym].Kind = skType) and
               (ArityOfTypeSym(LBase.UnitId, LSym) = LArgCount) then
            begin
              LBase.Sym := LSym;
              Break;
            end;
            LSym := FModels[LBase.UnitId].Symbols[LSym].NextOverload;
          end;
          // The chain only links declarations in ONE model. When the arities
          // live in DIFFERENT used units there is nothing to chain, and the
          // ordinary lookup returned whichever was imported last — so
          // `TdxPDFObjectList<T>` can land on a plain class of that name in
          // another unit and take a whole ancestry with it. Mirror of the bare
          // case in PreferNonGeneric; searched only after the chain misses, so
          // the common single-declaration name never reaches it.
          // BUILTINS excluded, and that guard is load-bearing for the clock:
          // a seeded type carries no parameter list, so `TArray<T>` and friends
          // "mismatch" on every single use and would each pay a full scan of
          // the referring unit's imports. Measured at +1.8% before the guard.
          if (ArityOfTypeSym(LBase.UnitId, LBase.Sym) <> LArgCount) and
             not (sfBuiltin in FModels[LBase.UnitId].Symbols[LBase.Sym].Flags) then
          begin
            // The referring unit's own interface section first — see
            // FindTypeInSelfArity; then the used units.
            if FindTypeInSelfArity(AId,
                 LM.Tree.NodeNameLower(LM.Tree.Nodes[ANode].FirstChild),
                 LArgCount, LSym) then
            begin
              LBase.UnitId := AId;
              LBase.Sym := LSym;
            end
            else if FindTypeInUsesArity(AId,
                 LM.Tree.NodeNameLower(LM.Tree.Nodes[ANode].FirstChild),
                 LArgCount, LUid, LSym) then
            begin
              LBase.UnitId := LUid;
              LBase.Sym := LSym;
            end;
          end;
        end;
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

{ ResolveTypeExpr plus the one lookup it deliberately does not do: a NESTED type
  named through its OUTER type (11.4.1), cross-unit. Two real shapes, and the
  second is why this is not a with-only concern:

    with TScrollBarStyleHook.TScrollWindow(FMDIScrollSizeBox) do ...  // Vcl.Forms
    TMemoTextSettings = class(TTextSettingsInfo.TCustomTextSettings)   // FMX.Memo

  ResolveTypeExpr reads the maps, and nothing has bound that last segment: Phase 1
  resolves a type-qualified member only within its own unit, and the cross-unit
  member pass (CrossType) runs long after the passes that decide E2003. As a
  HERITAGE reference the miss is silent and expensive — the class is left with no
  ancestry, so every inherited member used in its methods reads as undeclared
  (12 diagnostics across 9 FMX units from this one form, all of them the
  `WordWrap`/`HorzAlign`/`VertAlign` family).

  Kept OUT of ResolveTypeExpr itself, which is on the BindTypesX/CrossType hot
  path: callers reach this only after the plain lookup has already missed.

  The lookup is the qualifier's OWN members, deliberately NOT FindMemberX. This
  is called FROM FindMemberX's ancestor walk, and `TFoo = class(TFoo.TBar)` would
  then recurse until the stack ran out. A nested type inherited through the
  qualifier's ancestor is the declaration-site case CrossResolveDecl covers. }
function TPasSemaProject.ResolveTypeExprNested(AId, ANode: Integer): TSemaXType;
var
  LM, LQM: TPasSemaModel;
  LBase, LName, LScope, LFound, LDef, LDepth: Integer;
  LQ: TSemaXType;
begin
  Result := ResolveTypeExpr(AId, ANode);
  if XValid(Result) or (ANode = NIL_NODE) then
    Exit;
  LM := FModels[AId];
  if LM.Tree.Nodes[ANode].Kind <> nkMember then
    Exit;
  LBase := LM.Tree.Nodes[ANode].FirstChild;
  if LBase = NIL_NODE then
    Exit;
  LName := LM.Tree.Nodes[LBase].NextSibling;
  // Qualifier and ONE trailing segment; a longer chain nests nkMember nodes, so
  // the recursion below covers `A.B.C` without a flat-list case here. That
  // recursion walks to a strictly SMALLER node, so it is bounded by the chain.
  if (LName = NIL_NODE) or (LM.Tree.Nodes[LName].Kind <> nkIdent) or
     (LM.Tree.Nodes[LName].NextSibling <> NIL_NODE) then
    Exit;
  LQ := ResolveTypeExprNested(AId, LBase);
  // Alias hops chased like everywhere else here, depth-capped for a malformed
  // chain rather than a real one.
  for LDepth := 1 to 32 do
  begin
    if not XValid(LQ) then
      Exit;
    LQM := FModels[LQ.UnitId];
    LScope := LQM.Symbols[LQ.Sym].MemberScope;
    if LScope <> NIL_SCOPE then
    begin
      LFound := LQM.FindLocalDeep(LScope, LM.Tree.NodeNameLower(LName));
      if (LFound <> NIL_SYM) and (LQM.Symbols[LFound].Kind = skType) then
        Exit(XPlain(LQ.UnitId, LFound));
    end;
    LDef := TypeDefNodeOf(LQ.UnitId, LQ.Sym);
    if (LDef = NIL_NODE) or not (LQM.Tree.Nodes[LDef].Kind in
       [nkIdent, nkMember, nkTypeArgs]) then
      Exit;
    LQ := ResolveTypeExpr(LQ.UnitId, LDef);
  end;
end;

{ Cross-unit helper injection (15.3) ---------------------------------------

  A `class/record helper for T` declared in unit B applies wherever B is in
  scope — the common real-world arrangement (TGUIDHelper in System.SysUtils
  for System's TGUID; TStringHelper for the intrinsic string). Same-unit
  helpers are already joined by the resolver (JoinHelperScopes); this is the
  cross-model side, which cannot use scope joining at all (a scope index only
  means anything inside its own model), so FindMemberX consults a
  project-wide registry instead.

  The dcc-verified rules this implements:
  - The ACTIVE helper is per REFERRING unit: own unit's last declaration
    first, then `uses` last-to-first — ordinary last-uses-wins (two units
    each declaring a helper for one type: the later-listed unit's wins).
  - At most ONE helper is active per (referring unit, type): a miss in the
    active helper's members falls through to the type's OWN members, never
    to an earlier-in-scope helper (15.3.3).
  - A helper MEMBER hides the type's own member of the same name — so the
    helper is consulted BEFORE the member scope at every hop. NB the
    same-unit join (JoinHelperScopes) still checks own names first; that
    known precedence imprecision is confined to same-unit shadow pairs.
  - An implementation-section helper is unit-local; interface-section ones
    (however deeply nested — 15.3.4) export. }

{ Scans every model for helper DECLARATIONS (phase A), then resolves the one
  ACTIVE helper per (referring model, extended type) into FHelperIdx (phase
  B). Sequential by contract: the parallel FindMemberX consumers only READ
  FHelperIdx, so the hot path needs no lock. Rebuilt per cross run, which is
  also how the staged pipeline's growing closure is handled — its finalizer
  simply re-scans.

  Requires CrossResolve to have run: a `for T` target resolves through
  ResolveTypeExpr, i.e. via RefMap/ExtRefMap. }
procedure TPasSemaProject.BuildHelperMap;
var
  LCount, LMid, LSym, LDef, LRef, LLast, LScope: Integer;
  LM: TPasSemaModel;
  LRegs: TArray<TPasHelperReg>;
  LReg: TPasHelperReg;
  LExported: Boolean;
  LX: TSemaXType;

  // Registers AReg as AMid's active helper under every key AMid could reach
  // the extended type by. Callers go weakest-precedence first, so a later
  // write simply wins.
  procedure Publish(AMid: Integer; const AReg: TPasHelperReg);
  var
    LExt: TPasExtRef;
    LBSym, LRMid, LRSym: Integer;

    procedure Put(AUnit, ASym: Integer);
    begin
      if (AUnit < 0) or (ASym < 0) then
        Exit;
      if FHelperIdx[AMid] = nil then
        FHelperIdx[AMid] := TDictionary<Int64, TPasExtRef>.Create;
      FHelperIdx[AMid].AddOrSetValue(
        (Int64(AUnit) shl 32) or Cardinal(ASym), LExt);
    end;

  begin
    LExt.UnitId := AReg.HelperMid;
    LExt.Sym := AReg.Sym;
    if AReg.TargetUnit <> NIL_SYM then
    begin
      Put(AReg.TargetUnit, AReg.TargetSym);   // concrete type: one identity
      Exit;
    end;
    // Builtin target: re-resolve the NAME in the REFERRING model — its own
    // seeded symbol, plus the real declaration the walk may redirect to
    // (ResolveRealDecl — System.pas's TObject for a seeded TObject). Doing
    // both here is what removes the old hot-path by-name fallback probe.
    LBSym := FModels[AMid].Resolve(FModels[AMid].InterfaceScope,
      AReg.TargetName);
    if LBSym <> NIL_SYM then
      Put(AMid, LBSym);
    if ResolveRealDecl(AMid, AReg.TargetName, LRMid, LRSym) then
      Put(LRMid, LRSym);
  end;

begin
  ClearHelperIdx;
  // Same lifetime as the helper index, and for the same reason: every driver
  // that runs the body passes calls this first, and a staged run REPLACES
  // interface-only models with full ones — a worklist held over from a previous
  // run would name nodes of a tree that no longer exists.
  SetLength(FWorkBuilt, 0);
  SetLength(FInhWork, 0);
  SetLength(FWithWork, 0);
  // ResolveRealDecl in Publish may load System on demand and APPEND a model,
  // so index only the models present now — a late arrival simply sees no
  // helpers, exactly as the previous revision's out-of-range guard did.
  LCount := FModels.Count;
  SetLength(FModelHelpers, LCount);
  SetLength(FHelperIdx, LCount);
  // ---- phase A: collect declarations ----
  for LMid := 0 to LCount - 1 do
  begin
    LM := FModels[LMid];
    LRegs := nil;
    for LSym := 0 to LM.SymCount - 1 do
    begin
      if LM.Symbols[LSym].Kind <> skType then
        Continue;
      LDef := TypeDefNodeOf(LMid, LSym);
      if (LDef = NIL_NODE) or (LM.Tree.Nodes[LDef].Kind <> nkHelperType) then
        Continue;
      // The `for T` target: LAST of the leading run of type references (a
      // class helper may name a helper ancestor first — `class helper (X)
      // for T`; the parser adopts X before T).
      LRef := LM.Tree.Nodes[LDef].FirstChild;
      LLast := NIL_NODE;
      while (LRef <> NIL_NODE) and (LM.Tree.Nodes[LRef].Kind in
        [nkIdent, nkMember, nkTypeArgs]) do
      begin
        LLast := LRef;
        LRef := LM.Tree.Nodes[LRef].NextSibling;
      end;
      if LLast = NIL_NODE then
        Continue;
      LX := ResolveTypeExpr(LMid, LLast);
      if not XValid(LX) then
        Continue;   // target didn't resolve — nothing to inject
      if FModels[LX.UnitId].Symbols[LX.Sym].Kind = skBuiltinType then
      begin
        LReg.TargetUnit := NIL_SYM;
        LReg.TargetSym := NIL_SYM;
        LReg.TargetName := FModels[LX.UnitId].Symbols[LX.Sym].NameLower;
      end
      else
      begin
        LReg.TargetUnit := LX.UnitId;
        LReg.TargetSym := LX.Sym;
        LReg.TargetName := '';
      end;
      // Interface-section helpers export, however deeply nested (15.3.4);
      // an implementation-section one stays unit-local. The scope chain
      // passes through the sckImplementation scope exactly for the latter.
      LExported := True;
      LScope := LM.Symbols[LSym].Scope;
      while LScope <> NIL_SCOPE do
      begin
        if LM.Scopes[LScope].Kind = sckImplementation then
        begin
          LExported := False;
          Break;
        end;
        LScope := LM.Scopes[LScope].Parent;
      end;
      LReg.HelperMid := LMid;
      LReg.Sym := LSym;
      LReg.Exported := LExported;
      LRegs := LRegs + [LReg];
    end;
    FModelHelpers[LMid] := LRegs;
  end;
  // ---- phase B: apply precedence, per referring model ----
  // Weakest first so a later write wins: used units in `uses` order (a
  // later-listed unit beats an earlier one — dcc-verified last-uses-wins),
  // then the referring unit's OWN helpers (nearest; impl-section ones count
  // here). Within one unit, declaration order, later winning.
  for LMid := 0 to LCount - 1 do
  begin
    for var LU := 0 to High(FModels[LMid].UsesList) do
    begin
      var LUid := FModels[LMid].UsesList[LU].UnitId;
      if (LUid < 0) or (LUid >= LCount) then
        Continue;
      for var LI := 0 to High(FModelHelpers[LUid]) do
        if FModelHelpers[LUid][LI].Exported then
          Publish(LMid, FModelHelpers[LUid][LI]);
    end;
    for var LI := 0 to High(FModelHelpers[LMid]) do
      Publish(LMid, FModelHelpers[LMid][LI]);
  end;
end;

procedure TPasSemaProject.ClearHelperIdx;
var
  LIdx: Integer;
begin
  for LIdx := 0 to High(FHelperIdx) do
    FHelperIdx[LIdx].Free;
  FHelperIdx := nil;
end;

// The active helper's member scope, consulted at one FindMemberX hop. HOT
// PATH: a single integer-keyed lookup in a prebuilt read-only dictionary —
// no allocation, no lock. Only the helper's OWN member scope is read
// (FindLocalDeep), never a recursive FindMemberX, so a malformed helper graph
// cannot cycle; a helper ANCESTOR's members (`class helper (X) for T`) are
// reached by the nkHelperType branch of the main walk instead, which only
// fires when the walk STARTS at a helper (a helper is never another type's
// heritage).
function TPasSemaProject.HelperMemberHit(AFromMid: Integer;
  const ACur: TSemaXType; const ANameLower: string;
  out AMemMid, AMemSym: Integer): Boolean;
var
  LExt: TPasExtRef;
  LScope, LFound: Integer;
begin
  Result := False;
  if (AFromMid < 0) or (AFromMid > High(FHelperIdx)) or
     (FHelperIdx[AFromMid] = nil) then
    Exit;
  if not FHelperIdx[AFromMid].TryGetValue(
       (Int64(ACur.UnitId) shl 32) or Cardinal(ACur.Sym), LExt) then
    Exit;
  LScope := FModels[LExt.UnitId].Symbols[LExt.Sym].MemberScope;
  if LScope = NIL_SCOPE then
    Exit;
  LFound := FModels[LExt.UnitId].FindLocalDeep(LScope, ANameLower);
  if LFound <> NIL_SYM then
  begin
    AMemMid := LExt.UnitId;
    AMemSym := LFound;
    Result := True;
  end;
end;

// Member lookup by name on a type, following type aliases and the first
// heritage entry (ancestor class / base interface) across models, closing
// each hop over the current instantiation. ACtx returns the instantiation
// in whose frame the found member's declared type must be substituted.
// AFromMid is the REFERRING unit — it decides which helper is active (see
// the helper-injection block above); it does not otherwise affect the walk.
function TPasSemaProject.FindMemberX(AFromMid: Integer;
  const ABase: TSemaXType;
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
    // The ACTIVE helper for the current hop's type, before the type's own
    // members: a helper member HIDES the type's own of the same name
    // (dcc-verified). Checking per hop also covers descendants — a helper
    // for TBase applies to a TDerived value once the walk reaches TBase.
    // ACtx deliberately NIL_INST: a helper cannot extend an instantiation,
    // so its members' types never involve the target's parameters.
    if HelperMemberHit(AFromMid, LCur, ANameLower, AMemMid, AMemSym) then
    begin
      ACtx := NIL_INST;
      Exit(True);
    end;
    LScope := LM.Symbols[LCur.Sym].MemberScope;
    if LScope <> NIL_SCOPE then
    begin
      // FindLocalDeep, mirroring ResolveNode's own nkMember lookup: a struct
      // member scope carries a joined scope only where one was deliberately
      // injected, and the sole injector is PasTree.Sema.Resolver's
      // JoinHelperScopes. So this is what lets a helper declared ALONGSIDE
      // its extended type be seen from any OTHER unit — `M.Twice` in unit B
      // where both TMatrix and its helper live in unit A. The converse (a
      // helper in B for a type in A) goes through HelperMemberHit above.
      LFound := LM.FindLocalDeep(LScope, ANameLower);
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
      nkPointerType:
        // Implicit dereference in member access: Object Pascal lets `P.Field`
        // stand for `P^.Field` when P is a pointer to a record, and the RTL
        // leans on it constantly (`Entry.Aliases` where Entry:
        // PEnumAliasEntry — System.TypInfo). Follow the pointee and keep
        // looking, so a member lookup on a pointer type behaves like one on
        // what it points at.
        LNext := PointeeX(LCur);
      nkClassOf:
        // A CLASS REFERENCE (15.2.1, `class of T`): its members are T's, which
        // is how `with TCustomStyleEngineClass(TStyleManager.Engine) do` reaches
        // TCustomStyleEngine's class vars (Vcl.Themes). Same shape as the
        // pointer hop — redirect to the referenced type and keep looking.
        // Visibility is not filtered here, so an INSTANCE member is reachable
        // through a class reference too; that is a known imprecision of this
        // walk, not specific to this hop.
        LNext := ResolveTypeExpr(LCur.UnitId,
          LM.Tree.Nodes[LDef].FirstChild);
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
          begin
            // No heritage clause — but a CLASS still has an ancestor: the
            // implicit TObject (11.1.1), whose members are reachable bare
            // inside the class's own methods (`ClassName`, `Free`,
            // `InitInstance`). The walk used to stop here, so those were
            // false E2003s. Routed through ResolveRealDecl, the same helper
            // the DeclNode-less branch above uses, so it finds the REAL
            // TObject (System.pas) rather than a compiler-seeded stub.
            //
            // Classes only. A record/object type genuinely has no implicit
            // ancestor, and an interface's implicit IInterface is left alone
            // on the same reasoning as the implemented-interface entries
            // above: its members have to be implemented by the class anyway.
            // The (LRMid, LRSym) <> (current) guard is what stops TObject
            // itself — which of course has no heritage clause either — from
            // walking into itself forever.
            if (LM.Tree.Nodes[LDef].Kind = nkClassType) and
               ResolveRealDecl(LCur.UnitId, 'tobject', LRMid, LRSym) and
               ((LRMid <> LCur.UnitId) or (LRSym <> LCur.Sym)) then
            begin
              LCur.UnitId := LRMid;
              LCur.Sym := LRSym;
              LCur.Inst := NIL_INST;   // TObject is not generic
              Continue;
            end;
            Exit;
          end;
          // Nested: the ancestor may be named through its OUTER type
          // (`TTextSettingsInfo.TCustomTextSettings`, FMX) — nothing binds that
          // segment this early, and the miss costs the whole ancestry.
          LNext := ResolveTypeExprNested(LCur.UnitId, LChild);
        end;
      nkHelperType:
        begin
          // The walk STARTED at a helper (a method body's enclosing struct —
          // System.SysUtils' TGUIDHelper.ToByteArray using TGUID's D1 bare;
          // a helper is never another type's heritage, so this cannot be
          // reached mid-walk). Its members behave as if declared on the
          // extended type, and vice versa: the body sees T's members through
          // the implicit Self — so continue the walk INTO the `for` target,
          // which also picks up T's own ancestors. Leading refs are optional
          // helper ANCESTORS then the target (last); an ancestor helper's
          // members apply too, tried first via recursion (bounded by the
          // declaration chain — helpers cannot form cycles).
          LChild := LM.Tree.Nodes[LDef].FirstChild;
          var LRefs: TArray<Integer> := nil;
          while (LChild <> NIL_NODE) and (LM.Tree.Nodes[LChild].Kind in
            [nkIdent, nkMember, nkTypeArgs]) do
          begin
            LRefs := LRefs + [LChild];
            LChild := LM.Tree.Nodes[LChild].NextSibling;
          end;
          if LRefs = nil then
            Exit;
          for var LAncIdx := 0 to High(LRefs) - 1 do
            if FindMemberX(AFromMid,
                 ResolveTypeExpr(LCur.UnitId, LRefs[LAncIdx]), ANameLower,
                 AMemMid, AMemSym, ACtx) then
              Exit(True);
          LNext := ResolveTypeExpr(LCur.UnitId, LRefs[High(LRefs)]);
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

{ 16.5.1 — a generic METHOD's own type parameters, inferred from the ARGUMENT
  types at a call site: `Take(7)` binds T to Integer without anyone writing
  `Take<Integer>(7)`. Returns a substitution frame (an instance-table index) to
  apply to the call's result type, or NIL_INST when nothing can be inferred.

  Only the direct shape is inferred: a parameter whose declared type IS one of
  the routine's own generic parameters. Delphi's real algorithm also matches
  through structure (`A: TArray<T>` against `TArray<Integer>`), which is a
  later slice — an unbound parameter makes the whole frame fail rather than
  guess, so the call stays typed exactly as it is today.

  NB the frame is keyed on the ROUTINE symbol, so an instance-table entry may
  name a routine rather than a type. It is only ever a substitution frame,
  never used AS a type; GenericParamIdents reads a routine's parameters for
  exactly this reason. There is deliberately no inference for generic TYPES
  (16.5.1: `TList.Create` cannot infer T). }
function TPasSemaProject.InferMethodFrame(AMid, ASym: Integer;
  const AArgTypes: TArray<TSemaXType>; ACtx: Integer): Integer;
var
  LIdents, LParams: TArray<Integer>;
  LArgs: TArray<TSemaXType>;
  LM: TPasSemaModel;
  LPIdx, LGIdx: Integer;
  LPX: TSemaXType;
begin
  Result := NIL_INST;
  LIdents := GenericParamIdents(AMid, ASym);
  if Length(LIdents) = 0 then
    Exit;   // not a generic method — nothing to infer
  LM := FModels[AMid];
  LParams := XParamSyms(AMid, ASym);
  SetLength(LArgs, Length(LIdents));
  for LGIdx := 0 to High(LArgs) do
    LArgs[LGIdx] := XNil;
  for LPIdx := 0 to High(LParams) do
  begin
    if LPIdx > High(AArgTypes) then
      Break;
    if not XValid(AArgTypes[LPIdx]) then
      Continue;   // untyped argument — cannot bind from it
    LPX := DeclTypeX(AMid, LParams[LPIdx]);
    if not XValid(LPX) then
      Continue;
    if (LPX.UnitId <> AMid) or
       (LM.Symbols[LPX.Sym].Kind <> skGenericParam) then
      Continue;   // a concrete parameter type binds nothing
    for LGIdx := 0 to High(LIdents) do
      if LIdents[LGIdx] = LM.Symbols[LPX.Sym].DeclNode then
      begin
        if not XValid(LArgs[LGIdx]) then
          // First binding wins. A later argument contradicting it is a real
          // dcc error (E2010 on the call); this pass emits no diagnostics, so
          // it just keeps the first.
          LArgs[LGIdx] := SubstX(AArgTypes[LPIdx], ACtx, 0);
        Break;
      end;
  end;
  for LGIdx := 0 to High(LArgs) do
    if not XValid(LArgs[LGIdx]) then
      Exit;   // some parameter stayed open — do not guess a partial frame
  Result := Instantiate(XPlain(AMid, ASym), LArgs);
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
      LX := SymDeclTypeX(AId, LSym);
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
  // Cross-unit member references this walk discovers, held OUT of the model's
  // own ExtRefMap until the pass is over — see the overlay note in the header.
  LNewExt: TDictionary<Integer, TPasExtRef>;

  { A node's cross-unit binding: this walk's own finds first, then the committed
    map. The two must be read together everywhere, because within one walk a
    later node's overload selection depends on a member reference an earlier
    node discovered (see TargetSym). }
  function ExtOf(N: Integer; out AExt: TPasExtRef): Boolean;
  begin
    Result := LNewExt.TryGetValue(N, AExt) or LM.ExtRefMap.TryGetValue(N, AExt);
  end;

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
    if ExtOf(LName, LExt) then
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
      LHeads := UsesHeads(LM.Tree.NodeNameLower(ACalleeNode));
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
          else if ExtOf(N, LExt) then
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
          else if ExtOf(LName, LExt) then
          begin
            LX[N] := MemberTypeX(LExt.UnitId, LExt.Sym, LBX.Inst, LBX);
            LCtxOf[N] := LBX.Inst;
          end
          else if XValid(LBX) and FindMemberX(AId, LBX,
            LM.Tree.NodeNameLower(LName), LMemMid, LMemSym, LCtx) then
          begin
            // Record the discovered member reference for navigation.
            if LMemMid = AId then
              LM.RefMap[LName] := LMemSym
            else
            begin
              LExt.UnitId := LMemMid;
              LExt.Sym := LMemSym;
              LNewExt.AddOrSetValue(LName, LExt);
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
                    begin
                      LX[N] := SubstX(DeclTypeX(LBestMid, LBestSym), LCtx, 0);
                      // 16.5.1: then close over the GENERIC METHOD's own
                      // parameters, inferred from the argument types, so
                      // `Take(7)` types like `Take<Integer>(7)`. Applied after
                      // the enclosing type's frame (LCtx) because a method
                      // parameter is never substituted by it.
                      var LArgTypes: TArray<TSemaXType> := nil;
                      var LArgN := LM.Tree.Nodes[LBase].NextSibling;
                      while LArgN <> NIL_NODE do
                      begin
                        LArgTypes := LArgTypes + [GetX(LArgN)];
                        LArgN := LM.Tree.Nodes[LArgN].NextSibling;
                      end;
                      var LFrame := InferMethodFrame(LBestMid, LBestSym,
                        LArgTypes, LCtx);
                      if LFrame <> NIL_INST then
                        LX[N] := SubstX(LX[N], LFrame, 0);
                    end;
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
  // Provided by RunCrossTypePass, which owns it across the parallel phase and
  // merges it afterwards; a direct caller (AnalyzeFile) gets a private one.
  if (AId <= High(FXNewExt)) and (FXNewExt[AId] <> nil) then
    LNewExt := FXNewExt[AId]
  else
    LNewExt := TDictionary<Integer, TPasExtRef>.Create;
  LUsesHeads := TDictionary<string, TArray<TPasExtRef>>.Create;
  try
    if Length(LX) > 0 then
      Walk(0);
  finally
    LUsesHeads.Free;
    if (AId > High(FXNewExt)) or (FXNewExt[AId] = nil) then
    begin
      // Unmanaged case: commit and drop it here.
      for var LPair in LNewExt do
        LM.ExtRefMap.AddOrSetValue(LPair.Key, LPair.Value);
      LNewExt.Free;
    end;
  end;
  // Persist only what ADDS to the intra-unit result: a type for a locally
  // untyped node, an instantiation, or a type living in another model.
  // An entry ALREADY present is left alone: at this point the only earlier
  // writer is the with pass, whose entries carry the with-target's
  // instantiation frame (TPasInhPending.X) — this walk has no with-target
  // context, so for exactly those nodes its answer is the OPEN generic
  // parameter, strictly worse.
  for LNode := 0 to High(LX) do
    if XValid(LX[LNode]) and ((LM.ExprType[LNode] = NIL_SYM) or
       (LX[LNode].Inst <> NIL_INST) or (LX[LNode].UnitId <> AId)) then
      if not LM.ExprTypeX.ContainsKey(LNode) then
        LM.ExprTypeX.Add(LNode, LX[LNode]);
end;

{ CrossType for every unit, in PARALLEL, with the one shared-write hazard
  removed rather than locked.

  The walk reads other models freely (Symbols/Tree/SymTypeX — all frozen by
  now) but used to also WRITE its own model's ExtRefMap mid-walk, recording each
  cross-unit member reference it discovered. That is the hazard: another walk
  reads that same dictionary through ResolveTypeExpr(thatModel, ...), and
  TDictionary.AddOrSetValue can rehash under a concurrent TryGetValue. RefMap is
  a pre-sized array of Integer, so element writes there are benign; the
  dictionary is not.

  So each walk now records into a private overlay, read back through ExtOf so
  the walk still sees its own finds (overload selection within one unit depends
  on that), and the overlays are merged here, sequentially, once every walk has
  finished. ExprTypeX needs no such treatment: nothing reads another model's.

  Instantiate stays locked — measured at 77k calls for the whole 665-unit corpus
  against 126k InstanceRead calls, so ~200k uncontended acquisitions in total;
  that is single-digit milliseconds, not a reason to redesign the instance
  table. }
procedure TPasSemaProject.RunCrossTypePass(ACount: Integer);
var
  LIdx: Integer;
begin
  SetLength(FXNewExt, ACount);
  for LIdx := 0 to ACount - 1 do
    FXNewExt[LIdx] := TDictionary<Integer, TPasExtRef>.Create;
  try
    ForEachIndex(ACount - 1,
      procedure(AIdx: Integer)
      begin
        CrossType(AIdx);
      end);
    for LIdx := 0 to ACount - 1 do
      for var LPair in FXNewExt[LIdx] do
        FModels[LIdx].ExtRefMap.AddOrSetValue(LPair.Key, LPair.Value);
  finally
    for LIdx := 0 to ACount - 1 do
      FXNewExt[LIdx].Free;
    SetLength(FXNewExt, 0);
  end;
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
                LModel.Tree.NodeNameLower(LName));
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
                LModel.Tree.NodeNameLower(LName));
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
          // Same reason, for a `with` body whose target type is cross-unit:
          // resolving it needs FindMemberX over OTHER models, so it waits for
          // the frozen-ExtRefMap pass too (see FindInEnclosingWith). A LATER
          // with TARGET waits for exactly the same reason — it is resolved
          // inside the earlier targets, whose types are just as likely to live
          // in another unit. Emitting here instead meant the with pass went on
          // to bind the name correctly while this pass's E2003 for it stood.
          if InsideWithBody(LModel, LNode) or
             InsideLaterWithTarget(LModel, LNode) then
            Continue;
          LNameLower := LModel.Tree.NodeNameLower(LNode);
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
          // Nothing local, nothing in a used unit — but a name written INSIDE a
          // type declaration may still be an INHERITED member of that type or of
          // one it is nested in (11.4.1). That walk is FindMemberX, which reads
          // other models' ExtRefMap while their own workers are still writing,
          // so it waits for the frozen-map pass: queue, don't judge.
          else if DeclStructsOfNode(LModel, LNode) <> nil then
            FDeclWork[AId] := FDeclWork[AId] + [LNode]
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
    begin
      // A method body (or a local proc inside one): the original case.
      if AModel.Scopes[LScope].Kind <> sckStruct then
        Exit(AModel.Scopes[LScope].StructSym);
      // A node in the type DECLARATION itself. Only a PROPERTY SPECIFIER is
      // deferred to the inherited pass, never the whole declaration, and the
      // reason is an ordering hazard rather than taste: that pass resolves a
      // member by walking the struct's ancestors, which means reading the
      // heritage reference (`class(TThread)`) out of this very declaration.
      // Deferring heritage references TOO puts them in the same round as the
      // lookups that depend on them — they are still uncommitted when the
      // walk reads them, and the ancestor is simply not found. Measured, not
      // theorised: deferring the whole declaration fixed the 47 property
      // specifiers and broke 74 previously-fine inherited members in nested
      // classes (TThreadPool.TBaseWorkerThread's `Terminate` and friends).
      // Same invariant CrossResolveInherited's own header states for `with`:
      // its entries must never be type nodes another worker needs.
      if InPropertySpecifier(AModel, ANode) then
        Exit(AModel.Scopes[LScope].StructSym);
      Exit(NIL_SYM);
    end;
    LScope := AModel.Scopes[LScope].Parent;
  end;
end;

{ The OUTER qualifier segments of the method enclosing ANode — everything
  StructSymOfNode does not return, innermost first.

  `procedure TParallel.TLoopState32.TLoopStateFlag32.ShouldExit` uses
  TLoopStateFlagSet, a private nested type of TLoopState — which is the
  ANCESTOR of the MIDDLE segment, TLoopState32. The innermost segment's own
  ancestry (all the inherited pass ever searched) does not contain it, so
  every such use was a false E2003 — 16 of them in System.Threading alone.

  CollectRoutine joins each resolved segment's member scope into the routine
  scope, and CollectStruct tags every struct scope with its own type, so the
  chain is readable straight off Additional. Join order is outer-to-inner, so
  it is walked backwards to keep dcc's innermost-first precedence. Scopes of
  other kinds joined in there (a matched declaration's parameter scope) are
  skipped — only structs have an ancestry to search. }
function TPasSemaProject.OuterStructsOfNode(AModel: TPasSemaModel;
  ANode, AInnermost: Integer): TArray<Integer>;
var
  LScope, LIdx, LSym: Integer;
  LAdd: TArray<Integer>;
begin
  Result := nil;
  if ANode > High(AModel.NodeScope) then
    Exit;
  LScope := AModel.NodeScope[ANode];
  while LScope <> NIL_SCOPE do
  begin
    if AModel.Scopes[LScope].StructSym <> NIL_SYM then
    begin
      // Only a method body carries qualifier segments; a struct scope (a type
      // declaration) has none, and StructSymOfNode already covers it.
      if AModel.Scopes[LScope].Kind = sckStruct then
        Exit;
      LAdd := AModel.Scopes[LScope].Additional;
      for LIdx := High(LAdd) downto 0 do
        if AModel.Scopes[LAdd[LIdx]].Kind = sckStruct then
        begin
          LSym := AModel.Scopes[LAdd[LIdx]].StructSym;
          if (LSym <> NIL_SYM) and (LSym <> AInnermost) then
            Result := Result + [LSym];
        end;
      Exit;
    end;
    LScope := AModel.Scopes[LScope].Parent;
  end;
end;

{ The enclosing TYPE-DECLARATION scopes around ANode, innermost first — the
  chain StructSymOfNode deliberately refuses to serve (it answers for method
  BODIES only). Empty for a node that is not inside a type declaration, and for
  one inside a method body, so it doubles as the "is this a declaration site?"
  test CrossResolve needs.

  What it buys: a name written inside a class declaration sees the members of
  that class AND of every class it is NESTED in — each one's ANCESTORS included
  (dcc-verified: a nested `TSub = class(TInner)` resolves both `TInner`, a
  nested type of the enclosing class's GRANDPARENT, and a const of that same
  grandparent used as an array bound). Vcl.Skia's

    TSkAnimatedPaintBox = class(TSkCustomAnimatedControl)
      TAnimation = class(TAnimationBase)          // ancestor's nested type

  is the shape, and the six false E2003 it produced per Skia unit cascade: with
  the heritage unresolved, TAnimation has no ancestry at all, so its property
  specifiers (`read GetDuration`) and its methods' inherited consts
  (`TimeEpsilon`) all read as undeclared too. }
function TPasSemaProject.DeclStructsOfNode(AModel: TPasSemaModel;
  ANode: Integer): TArray<Integer>;
var
  LScope: Integer;
begin
  Result := nil;
  if ANode > High(AModel.NodeScope) then
    Exit;
  LScope := AModel.NodeScope[ANode];
  while LScope <> NIL_SCOPE do
  begin
    if AModel.Scopes[LScope].StructSym <> NIL_SYM then
    begin
      // A method body (or a local proc in one) — StructSymOfNode's territory,
      // and the inherited pass already searches exactly this chain there.
      if AModel.Scopes[LScope].Kind <> sckStruct then
        Exit(nil);
      Result := Result + [AModel.Scopes[LScope].StructSym];
    end;
    LScope := AModel.Scopes[LScope].Parent;
  end;
end;

// True when ANode sits inside a property's read/write/stored/... specifier
// (nkPropSpec). Walks CST parents, stopping at the property declaration —
// nothing above it can be a specifier, so the walk is short.
function TPasSemaProject.InPropertySpecifier(AModel: TPasSemaModel;
  ANode: Integer): Boolean;
var
  LCur: Integer;
begin
  Result := False;
  LCur := ANode;
  while LCur <> NIL_NODE do
  begin
    case AModel.Tree.Nodes[LCur].Kind of
      nkPropSpec:
        Exit(True);
      nkPropertyDecl, nkRoutine, nkClassType, nkRecordType, nkInterfaceType,
      nkObjectType, nkHelperType:
        Exit(False);
    end;
    LCur := AModel.Tree.Nodes[LCur].Parent;
  end;
end;

{ `with` over a CROSS-UNIT target type (ch.05 §5.7)

  PasTree.Sema.Resolver.ResolveWithStmts already opens a with-target's member
  scope — but only when the target's type is resolvable INTRA-unit, because it
  works by joining the type's MemberScope, and a scope index only means
  anything inside its own model. In real code the target's type usually comes
  from another unit (`with LTZ.StandardDate do` where LTZ: TTimeZoneInformation
  from Winapi.Windows — System.DateUtils.pas:2612), and the whole body then
  stayed unresolved and got a false E2003 per member.

  Cross-unit member references cannot use scope joining at all; the project
  records them in ExtRefMap instead, exactly as the inherited-member pass
  does. So this mirrors that pass: CrossResolve DEFERS an unresolved ident
  sitting in a with body (InsideWithBody), and CrossResolveInherited — which
  already runs late enough for every model's ExtRefMap to be frozen —
  resolves it here. }

// The cross-model TYPE of a with-target expression, deliberately computed
// WITHOUT the Phase-3c tables: SymTypeX/ExprTypeX are filled by BindTypesX/
// CrossType, which run AFTER the pass that has to decide E2003, so this walks
// RefMap/ExtRefMap and declared type NODES directly (ResolveTypeExpr does the
// same and is likewise table-free).
{ The type a cross-model POINTER type points at: PVarData = ^TVarData ->
  TVarData, chasing through however many alias links sit in between. The
  cross-model twin of TPasSemaResolver.PointeeTypeSym, depth-capped for the
  same reason. XNil when AX is not a pointer type. }
function TPasSemaProject.PointeeX(const AX: TSemaXType): TSemaXType;
var
  LCur: TSemaXType;
  LDef, LDepth: Integer;
begin
  Result := XNil;
  LCur := AX;
  for LDepth := 1 to 32 do
  begin
    if not XValid(LCur) then
      Exit;
    LDef := TypeDefNodeOf(LCur.UnitId, LCur.Sym);
    if LDef = NIL_NODE then
      Exit;
    case FModels[LCur.UnitId].Tree.Nodes[LDef].Kind of
      nkPointerType:
        Exit(ResolveTypeExpr(LCur.UnitId,
          FModels[LCur.UnitId].Tree.Nodes[LDef].FirstChild));
      nkIdent, nkMember, nkTypeArgs:
        LCur := ResolveTypeExpr(LCur.UnitId, LDef);   // alias link
    else
      Exit;
    end;
  end;
end;

{ The pointee of an ANONYMOUS pointer type written INLINE on the base
  designator's own declaration — `PExtLogPen: ^TExtLogPen` as a local var, then
  `with Result, PExtLogPen^ do` (Vcl.Graphics.GetPenData). There is no pointer
  type SYMBOL anywhere in that shape, so PointeeX has nothing to chase: the
  declaration's type NODE is the only place the pointer type exists at all.

  Exactly the reason ElementX starts from the declared type node for an inline
  `array[...] of T` — same gap, the other type constructor. XNil whenever the
  base does have a named type, which is the ordinary path. }
function TPasSemaProject.PointeeOfDeclX(AId, ABaseNode: Integer): TSemaXType;
var
  LMid, LSym, LNode: Integer;
begin
  Result := XNil;
  if not DesignatorSymX(AId, ABaseNode, LMid, LSym) then
    Exit;
  LNode := FModels[LMid].Symbols[LSym].TypeNode;
  if (LNode = NIL_NODE) or
     (FModels[LMid].Tree.Nodes[LNode].Kind <> nkPointerType) then
    Exit;
  Result := ResolveTypeExpr(LMid, FModels[LMid].Tree.Nodes[LNode].FirstChild);
end;

{ The declaring (model, symbol) of a designator's head, across models: what
  RefMap/ExtRefMap say about the last segment. Needed because a variable's
  declared type NODE is sometimes the only place an array type exists (an
  inline `array[...] of T` resolves to no symbol at all). }
function TPasSemaProject.DesignatorSymX(AId, ANode: Integer;
  out AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
  LName: Integer;
  LExt: TPasExtRef;
begin
  Result := False;
  AMid := NIL_SYM;
  ASym := NIL_SYM;
  if ANode = NIL_NODE then
    Exit;
  LM := FModels[AId];
  LName := ANode;
  case LM.Tree.Nodes[ANode].Kind of
    nkMember:
      begin
        LName := LM.Tree.Nodes[ANode].FirstChild;
        while (LName <> NIL_NODE) and
              (LM.Tree.Nodes[LName].NextSibling <> NIL_NODE) do
          LName := LM.Tree.Nodes[LName].NextSibling;
      end;
    nkParen, nkDeref, nkIndex:
      Exit(DesignatorSymX(AId, LM.Tree.Nodes[ANode].FirstChild, AMid, ASym));
    nkIdent: ;
  else
    Exit;
  end;
  if LName = NIL_NODE then
    Exit;
  if LM.RefMap[LName] <> NIL_SYM then
  begin
    AMid := AId;
    ASym := LM.RefMap[LName];
    Exit(True);
  end;
  if LM.ExtRefMap.TryGetValue(LName, LExt) then
  begin
    AMid := LExt.UnitId;
    ASym := LExt.Sym;
    Exit(True);
  end;
  { Neither map has it yet. That is the normal state for a member inside a with
    TARGET: the pass that records cross-unit member references is CrossType,
    which runs AFTER the with pass that is asking. So find the member the same
    way WithTargetTypeX does — through the base's type.

    `with Params^.rgrc[0] do` (Vcl.Forms) needs exactly this: rgrc's declared
    type is an INLINE `array[..] of TRect`, so ElementX can only reach the
    element through the member SYMBOL's own type node, and it gets that symbol
    from here. Without the fallback the whole chain came back untyped and every
    TRect field in the body was undeclared. }
  if LM.Tree.Nodes[ANode].Kind = nkMember then
  begin
    var LBase := LM.Tree.Nodes[ANode].FirstChild;
    // The base may denote a VALUE (LB.Items) or a TYPE (THintAction.Create).
    // Both are member containers and both occur as with targets, so try the
    // value reading first and fall back to reading it as a type reference.
    var LBX := WithTargetTypeX(AId, LBase);
    if not XValid(LBX) then
      LBX := ResolveTypeExpr(AId, LBase);
    var LMemMid, LMemSym, LCtx: Integer;
    if XValid(LBX) and FindMemberX(AId, LBX, LM.Tree.NodeNameLower(LName),
         LMemMid, LMemSym, LCtx) then
    begin
      AMid := LMemMid;
      ASym := LMemSym;
      Exit(True);
    end;
  end;
end;

{ The ELEMENT type of an indexable designator, or XNil when it is not an array
  (the caller reads that as "leave the type alone" — see the nkIndex branch).
  Cross-model twin of TPasSemaResolver.ElementTypeOf, and it needs the same two
  sources: the base's own declared type NODE may BE an inline array, which no
  symbol lookup can reach, so that is tried before the named type it resolves
  to. Alias links chased in both, depth-capped like PointeeX. }
{ True when ASym is a DEFAULT ARRAY property (13.1.4) — `property Items[Index:
  Integer]: T read GetItem; default;`.

  Two different specifiers spell `default` and both land as an nkPropSpec whose
  first token is that word: this one, and the default-VALUE of an ordinary
  property (`property Align: TAlign read FAlign default alLeft;`). They are told
  apart by the index parameters — a value-default property has none, and only an
  ARRAY property can be the default one. }
{ One step up the inheritance chain: AX's ancestor, or XNil at the root.

  Chases a type alias transparently, and takes the heritage clause's FIRST type
  reference as the ancestor — the same convention CollectStruct and XDescendsFrom
  use. Extracted because three callers now climb (XDescendsFrom's own compare
  loop aside): the default-array-property search and the property-redeclaration
  type search below, and it is exactly the kind of step that should exist once. }
function TPasSemaProject.AncestorOfX(const AX: TSemaXType): TSemaXType;
var
  LM: TPasSemaModel;
  LDef, LChild: Integer;
begin
  Result := XNil;
  if not XValid(AX) then
    Exit;
  LM := FModels[AX.UnitId];
  LDef := TypeDefNodeOf(AX.UnitId, AX.Sym);
  if LDef = NIL_NODE then
    Exit;
  case LM.Tree.Nodes[LDef].Kind of
    nkIdent, nkMember, nkTypeArgs:
      Result := ResolveTypeExpr(AX.UnitId, LDef);   // alias link
    nkClassType, nkInterfaceType:
      begin
        LChild := LM.Tree.Nodes[LDef].FirstChild;
        while (LChild <> NIL_NODE) and not (LM.Tree.Nodes[LChild].Kind in
          [nkIdent, nkMember, nkTypeArgs]) do
          LChild := LM.Tree.Nodes[LChild].NextSibling;
        if LChild <> NIL_NODE then
          // Nested ancestor (`Outer.Inner`) reached the same way FindMemberX's
          // own heritage hop does — see ResolveTypeExprNested.
          Result := ResolveTypeExprNested(AX.UnitId, LChild);
      end;
  end;
  // Compose the frames, exactly as FindMemberX's own walk does one hop at a
  // time: the ancestor reference is written in the DESCENDANT's parameters, so
  // `TObjectList<T> = class(TList<T>)` reached from `TObjectList<TAttr>` must
  // come back as TList<TAttr>, not as the open TList<T>. Without this the frame
  // was silently dropped at every hop and only a DIRECT generic ancestor ever
  // carried one.
  Result := SubstX(Result, AX.Inst, 0);
end;

{ The declared type of ONE symbol, resolved in its own model — the single place
  that answers "what type is this member?".

  It exists because of the bare property REDECLARATION: `property Items;` with no
  type and no specifiers, which only promotes visibility. Vcl.StdCtrls declares
  `Items: TStrings` on TCustomListBox and then republishes it on TListBox exactly
  that way, so `with CatList.Items do` (Vcl.CustomizeDlg) finds the
  redeclaration — a real symbol, with NO TypeNode — and used to type to nothing,
  leaving the whole with body undeclared.

  Such a symbol's type is the inherited declaration's, so the walk continues up
  the ancestor chain looking for a same-named property that has one. Everything
  that needs a member's type goes through here rather than reading TypeNode
  directly, which is the rule this codebase already follows for ref-map lookups:
  one funnel, not a case per caller. }
function TPasSemaProject.SymDeclTypeX(AMid, ASym: Integer): TSemaXType;
var
  LM: TPasSemaModel;
  LOwner, LScope, LIdx, LCand, LDepth: Integer;
  LNameLower: string;
  LCur: TSemaXType;
begin
  Result := XNil;
  if (AMid < 0) or (ASym = NIL_SYM) then
    Exit;
  LM := FModels[AMid];
  if LM.Symbols[ASym].TypeNode <> NIL_NODE then
  begin
    Result := ResolveTypeExpr(AMid, LM.Symbols[ASym].TypeNode);
    if XValid(Result) then
      Exit;
    // A declaration's type slot that resolved to NOTHING, in a position where
    // only a type is legal. The ordinary cause is a member whose name equals
    // its own type's — `property Params: Params`, routine in imported
    // type-library interfaces. Phase 1 resolves that slot inside the struct's
    // member scope, finds the PROPERTY, and the declared type comes back empty;
    // every member reached through it is then a false E2003 (11 sites in one
    // database layer). dcc resolves the TYPE there, so look one up by name —
    // only here, where the node is known to be a type slot, and only after the
    // normal path has failed.
    Exit(TypeSlotByNameX(AMid, LM.Symbols[ASym].TypeNode));
  end;
  // No type of its own. Only a property redeclaration is expected here; any
  // other typeless symbol simply has no type and XNil is the right answer.
  if LM.Symbols[ASym].Kind <> skProperty then
    Exit;
  LScope := LM.Symbols[ASym].Scope;
  if LScope = NIL_SCOPE then
    Exit;
  LOwner := LM.Scopes[LScope].StructSym;
  if LOwner = NIL_SYM then
    Exit;
  LNameLower := LM.Symbols[ASym].NameLower;
  LCur := AncestorOfX(XPlain(AMid, LOwner));
  for LDepth := 1 to 32 do
  begin
    if not XValid(LCur) then
      Exit;
    LScope := FModels[LCur.UnitId].Symbols[LCur.Sym].MemberScope;
    if LScope <> NIL_SCOPE then
      for LIdx := 0 to FModels[LCur.UnitId].Scopes[LScope].Symbols.Count - 1 do
      begin
        LCand := FModels[LCur.UnitId].Scopes[LScope].Symbols[LIdx];
        if (FModels[LCur.UnitId].Symbols[LCand].Kind = skProperty) and
           (FModels[LCur.UnitId].Symbols[LCand].NameLower = LNameLower) and
           (FModels[LCur.UnitId].Symbols[LCand].TypeNode <> NIL_NODE) then
          Exit(SubstX(ResolveTypeExpr(LCur.UnitId,
            FModels[LCur.UnitId].Symbols[LCand].TypeNode), LCur.Inst, 0));
      end;
    LCur := AncestorOfX(LCur);
  end;
end;

function TPasSemaProject.IsDefaultArrayProp(AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
  LDecl, LChild: Integer;
  LHasParams, LHasDefault: Boolean;
begin
  Result := False;
  LM := FModels[AMid];
  if LM.Symbols[ASym].Kind <> skProperty then
    Exit;
  // The symbol's DeclNode is the property's NAME node; the specifiers are
  // siblings of it under the nkPropertyDecl.
  LDecl := LM.Symbols[ASym].DeclNode;
  if LDecl = NIL_NODE then
    Exit;
  LDecl := LM.Tree.Nodes[LDecl].Parent;
  if (LDecl = NIL_NODE) or (LM.Tree.Nodes[LDecl].Kind <> nkPropertyDecl) then
    Exit;
  LHasParams := False;
  LHasDefault := False;
  LChild := LM.Tree.Nodes[LDecl].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LChild].Kind = nkParams then
      LHasParams := True
    else if (LM.Tree.Nodes[LChild].Kind = nkPropSpec) and
            (LM.Tree.NodeNameLower(LChild) = 'default') then
      LHasDefault := True;
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
  Result := LHasParams and LHasDefault;
end;

// Does this routine declare a parameter list? Its DeclNode is the NAME node
// and the nkParams sits beside it under the nkRoutine, same shape as a
// property's specifiers.
function TPasSemaProject.RoutineHasParams(AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
  LDecl, LChild: Integer;
begin
  Result := False;
  LM := FModels[AMid];
  if LM.Symbols[ASym].Kind <> skRoutine then
    Exit;
  LDecl := LM.Symbols[ASym].DeclNode;
  if LDecl = NIL_NODE then
    Exit;
  LDecl := LM.Tree.Nodes[LDecl].Parent;
  if (LDecl = NIL_NODE) or (LM.Tree.Nodes[LDecl].Kind <> nkRoutine) then
    Exit;
  LChild := LM.Tree.Nodes[LDecl].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LChild].Kind = nkParams then
      Exit(True);
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
end;

{ A PARAMETERLESS routine of that name on AX or an ancestor.

  `with GetScreenBounds do X := (Left + Right) div 2` in one ribbon library: the
  class OVERRIDES `GetScreenBounds(out ABounds: TRect): Boolean` and inherits a
  parameterless `GetScreenBounds: TRect` overload from two classes up. A bare
  with target carries no arguments, so 6.3.1 selects the arity-0 one — but the
  ordinary member walk answers with the NEAREST member of that name, which is
  the Boolean override, and the with then opened over a Boolean.

  Only the with target needs this. A real call site goes through SelectOverload,
  which has an argument list to select on; here the empty list is implied by the
  syntax and there is nothing to hand it. }
function TPasSemaProject.ParamlessOverloadX(const AX: TSemaXType;
  const ANameLower: string; out AMid, ASym, ACtx: Integer): Boolean;
var
  LCur: TSemaXType;
  LScope, LIdx, LCand, LDepth: Integer;
begin
  Result := False;
  AMid := -1;
  ASym := NIL_SYM;
  ACtx := NIL_INST;
  LCur := AX;
  for LDepth := 1 to 32 do
  begin
    if not XValid(LCur) then
      Exit;
    LScope := FModels[LCur.UnitId].Symbols[LCur.Sym].MemberScope;
    if LScope <> NIL_SCOPE then
      for LIdx := 0 to FModels[LCur.UnitId].Scopes[LScope].Symbols.Count - 1 do
      begin
        LCand := FModels[LCur.UnitId].Scopes[LScope].Symbols[LIdx];
        if (FModels[LCur.UnitId].Symbols[LCand].Kind = skRoutine) and
           (FModels[LCur.UnitId].Symbols[LCand].NameLower = ANameLower) and
           not RoutineHasParams(LCur.UnitId, LCand) then
        begin
          AMid := LCur.UnitId;
          ASym := LCand;
          ACtx := LCur.Inst;
          Exit(True);
        end;
      end;
    LCur := AncestorOfX(LCur);
  end;
end;

{ The default array property of AX's type or of an ancestor.

  `with ActionManager.ActionBars[I] do` (Vcl.CustomizeDlg) indexes a value whose
  type is a CLASS, not an array: TActionBars declares `property ActionBars[const
  Index: Integer]: TActionBarItem ... default`, and the element type is that
  property's. Naming the property explicitly always worked — `Coll.Items[0]`
  types through the member — so it was only the unnamed form that fell back to
  the collection type itself and looked for the item's members on it.

  Walk shape and alias chasing mirror XDescendsFrom: a default property is
  frequently INHERITED (TCollection.Items, TStrings.Strings). }
{ AOwner is the hop the property was FOUND at, instantiation frame included, and
  it is not the same thing as AX: the walk climbs ancestors, and an ancestor is
  where the frame usually comes from. `TAttrList = class(TObjectList<TAttr>)`
  has no frame of its own — `Items: T` lives two hops up in `TList<T>`, and only
  TObjectList<TAttr>'s frame turns that `T` into TAttr. Substituting with AX's
  own frame (empty here) left the element type as the OPEN parameter, so
  `with L[I] do` opened over nothing and every member in the body was a false
  E2003 (~250 across one HTML component library). }
function TPasSemaProject.DefaultArrayPropX(const AX: TSemaXType;
  out AMid, ASym: Integer; out AOwner: TSemaXType): Boolean;
var
  LCur: TSemaXType;
  LM: TPasSemaModel;
  LScope, LIdx, LSym, LDepth: Integer;
begin
  Result := False;
  AMid := NIL_SYM;
  ASym := NIL_SYM;
  AOwner := XNil;
  LCur := AX;
  for LDepth := 1 to 32 do
  begin
    if not XValid(LCur) then
      Exit;
    LM := FModels[LCur.UnitId];
    LScope := LM.Symbols[LCur.Sym].MemberScope;
    if LScope <> NIL_SCOPE then
      for LIdx := 0 to LM.Scopes[LScope].Symbols.Count - 1 do
      begin
        LSym := LM.Scopes[LScope].Symbols[LIdx];
        if IsDefaultArrayProp(LCur.UnitId, LSym) then
        begin
          AMid := LCur.UnitId;
          ASym := LSym;
          AOwner := LCur;
          Exit(True);
        end;
      end;
    LCur := AncestorOfX(LCur);
  end;
end;

function TPasSemaProject.ElementX(AId, ABaseNode: Integer): TSemaXType;

  // Element child of an nkArrayType: its LAST child. For a multi-dimensional
  // `array[a, b] of T` this reaches T rather than the intermediate row type —
  // over-eager by one level in a shape too rare to model, and it can only find
  // members of T instead of failing.
  function ElemOf(AMid, ANode: Integer): TSemaXType;
  var
    LChild, LLast, LSysUid, LSysSym: Integer;
  begin
    Result := XNil;
    if (ANode = NIL_NODE) or
       (FModels[AMid].Tree.Nodes[ANode].Kind <> nkArrayType) then
      Exit;
    // `array of const` (Aux=1) has no element type NODE to resolve, but it does
    // have an element TYPE: 6.2.6 — "array of const builds a TVarRec array". So
    // indexing one yields System.TVarRec, and `with aValues[i] do VType ...`
    // over an `array of const` parameter opens over its fields. Bailing here
    // instead left every one of them undeclared (56 of 57 diagnostics on
    // OmniThreadLibrary were this single shape, in GpStuff and OtlCommon).
    if FModels[AMid].Tree.Nodes[ANode].Aux = 1 then
    begin
      if FindInSystemUnit('tvarrec', LSysUid, LSysSym) then
        Result := XPlain(LSysUid, LSysSym);
      Exit;
    end;
    LChild := FModels[AMid].Tree.Nodes[ANode].FirstChild;
    LLast := NIL_NODE;
    while LChild <> NIL_NODE do
    begin
      LLast := LChild;
      LChild := FModels[AMid].Tree.Nodes[LChild].NextSibling;
    end;
    // NESTED inline arrays — `array of array of T`, written as one nkArrayType
    // inside another. Descend to the innermost element, which is the same
    // deliberate over-eagerness the header already documents for the
    // comma-dimension spelling `array[a, b] of T`: right when the index count
    // matches the nesting (`AMatrix[I, J]`, the only shape that occurs), and
    // one level too deep otherwise, where it can only find members of T
    // instead of failing. The intermediate row type is ANONYMOUS and has no
    // symbol, so it could not be named as a type in any case.
    while (LLast <> NIL_NODE) and
          (FModels[AMid].Tree.Nodes[LLast].Kind = nkArrayType) and
          (FModels[AMid].Tree.Nodes[LLast].Aux <> 1) do
    begin
      LChild := FModels[AMid].Tree.Nodes[LLast].FirstChild;
      LLast := NIL_NODE;
      while LChild <> NIL_NODE do
      begin
        LLast := LChild;
        LChild := FModels[AMid].Tree.Nodes[LChild].NextSibling;
      end;
    end;
    Result := ResolveTypeExpr(AMid, LLast);
  end;

var
  LMid, LSym, LDef, LDepth: Integer;
  LCur, LOwner: TSemaXType;
begin
  // 1. The base's own declared type node (inline-array case).
  if DesignatorSymX(AId, ABaseNode, LMid, LSym) then
  begin
    Result := ElemOf(LMid, FModels[LMid].Symbols[LSym].TypeNode);
    if XValid(Result) then
      Exit;
  end;
  // 2. The named type it resolves to, chasing aliases to a definition.
  LCur := WithTargetTypeX(AId, ABaseNode);
  for LDepth := 1 to 32 do
  begin
    if not XValid(LCur) then
      Exit(XNil);
    LDef := TypeDefNodeOf(LCur.UnitId, LCur.Sym);
    if LDef = NIL_NODE then
      Exit(XNil);
    case FModels[LCur.UnitId].Tree.Nodes[LDef].Kind of
      nkArrayType:
        // Close the element type over the ARRAY's instantiation frame:
        // TArray<TElementAlias> is `array of T`, so the raw element is the
        // open parameter T and only SubstX turns it into TElementAlias.
        Exit(SubstX(ElemOf(LCur.UnitId, LDef), LCur.Inst, 0));
      nkIdent, nkMember, nkTypeArgs:
        LCur := ResolveTypeExpr(LCur.UnitId, LDef);   // alias link
      nkPointerType:
        // Indexing a POINTER to an array: `ImageData[i]` where
        // `pPixelLine = ^TPixelLine` and `TPixelLine = array[Word] of TRGBQuad`
        // (Vcl.Imaging.pngimage, 23 sites; Vcl.Imaging.GIFImg the same). The `^`
        // may be omitted before `[`, and no POINTERMATH directive is needed —
        // dcc-verified, both as an expression and as a with target.
        //
        // Deref and let the loop continue, so pointer -> alias -> array composes
        // instead of needing a case per combination. FindMemberX already applies
        // the same implicit deref for `P.Field`; this is its sibling.
        LCur := PointeeX(LCur);
    else
      Break;   // not an array — a default array property may still index it
    end;
  end;
  // A CLASS/interface being indexed: the element type is its default array
  // property's (see DefaultArrayPropX).
  // Substituted over the frame of the hop the property was FOUND at, not over
  // LCur's own — see DefaultArrayPropX. For `TAttrList = class(TObjectList
  // <TAttr>)` LCur has no frame at all and the element type would stay `T`.
  if XValid(LCur) and DefaultArrayPropX(LCur, LMid, LSym, LOwner) then
    Exit(SubstX(ResolveTypeExpr(LMid, FModels[LMid].Symbols[LSym].TypeNode),
      LOwner.Inst, 0));
  Result := XNil;
end;

function TPasSemaProject.WithTargetTypeX(AId, ANode: Integer): TSemaXType;
var
  LM: TPasSemaModel;
  LBase, LName, LSym, LMemMid, LMemSym, LCtx: Integer;
  LExt: TPasExtRef;
  LBX: TSemaXType;
begin
  Result := XNil;
  if ANode = NIL_NODE then
    Exit;
  LM := FModels[AId];
  case LM.Tree.Nodes[ANode].Kind of
    nkParen:
      Result := WithTargetTypeX(AId, LM.Tree.Nodes[ANode].FirstChild);

    // `with SomePointer^ do` — the target's type is the POINTEE. Mirrors
    // TPasSemaResolver.WithTargetTypeSym's own nkDeref branch, for a pointer
    // (or a pointee) declared in another unit: System.Variants' `with
    // LVarData^ do VType := ...` and `with FindVarData(V)^ do`, where both
    // PVarData and TVarData come from the implicit System unit. The second
    // shape composes with the cast/call branch above — the call types to
    // PVarData, this dereferences it to TVarData.
    nkDeref:
      begin
        LBase := LM.Tree.Nodes[ANode].FirstChild;
        // An inline `^T` on the base's own declaration first — that pointer type
        // has no symbol for PointeeX to chase (see PointeeOfDeclX).
        Result := PointeeOfDeclX(AId, LBase);
        if not XValid(Result) then
          Result := PointeeX(WithTargetTypeX(AId, LBase));
      end;

    // `with Arr[I] do` — the ELEMENT type; the single most common with-target
    // shape in the RTL (`with NetResources^[I] do` over a Winapi record,
    // `with LVarBounds[I] do`, `with FList[Index] do`). ElementX returns XNil
    // for a non-array, which is the array-PROPERTY case: such a property's
    // declared type is ALREADY its element type, so indexing must not peel a
    // level — hence the pass-through fallback.
    nkIndex:
      begin
        LBase := LM.Tree.Nodes[ANode].FirstChild;
        Result := ElementX(AId, LBase);
        if not XValid(Result) then
          Result := WithTargetTypeX(AId, LBase);
      end;

    // `with Obj as TSomething do` (System.Net.Socket) — the CAST's type, the
    // right operand. Only `as`; any other binary operator yields a value no
    // with can open anyway.
    nkBinaryOp:
      if (LM.Tree.Nodes[ANode].Aux >= 0) and
         SameText(LM.Tree.Source.VisibleText(LM.Tree.Nodes[ANode].Aux), 'as')
      then
      begin
        LBase := LM.Tree.Nodes[ANode].FirstChild;
        if LBase <> NIL_NODE then
          Result := ResolveTypeExprNested(AId,
            LM.Tree.Nodes[LBase].NextSibling);
      end;

    nkCall:
      begin
        LBase := LM.Tree.Nodes[ANode].FirstChild;
        // A CAST `T(Expr)`: the callee is a TYPE name, so the with-target's
        // type is that type ITSELF — not the callee's declared type, which is
        // what the recursion below would read. ResolveTypeExpr yields XNil for
        // anything that is not a type, so a genuine parameterless call
        // (`with GetRec do`) still falls through to it and picks up the
        // routine's own RESULT type, as before.
        //
        // TPasSemaResolver.WithTargetTypeSym has had this branch all along;
        // it was missing HERE, so a cast to a type declared in ANOTHER unit
        // never typed at all. Real bug: System.ObjAuto's `with TVarData(
        // ParamValues[...]) do VType := ...` — TVarData lives in the implicit
        // System unit, so Phase 1 cannot bind it and this pass is the only
        // one that can. Unlike the Phase 1 branch this also covers a
        // QUALIFIED cast (`System.TVarData(X)`) and a generic one, since
        // ResolveTypeExpr handles nkMember/nkTypeArgs too — and the Nested
        // variant also reaches a cross-unit NESTED type named through its outer
        // one (`TScrollBarStyleHook.TScrollWindow(X)`), which nothing has bound
        // this early.
        Result := ResolveTypeExprNested(AId, LBase);
        if XValid(Result) then
          Exit;
        // `with TApartmentThread.Create(...) do` (System.Win.VCLCom) — a
        // CONSTRUCTOR call yields the CLASS. Its routine symbol has no result
        // type, so the plain recursion below would type the whole thing as
        // nothing. Mirrors what CrossType already does for a ctor call.
        if (LBase <> NIL_NODE) and
           (LM.Tree.Nodes[LBase].Kind = nkMember) and
           DesignatorSymX(AId, LBase, LMemMid, LMemSym) and
           IsConstructorSym(LMemMid, LMemSym) then
        begin
          Result := ResolveTypeExpr(AId, LM.Tree.Nodes[LBase].FirstChild);
          if XValid(Result) then
            Exit;
          // The qualifier need not be a type NAME: a constructor called through
          // a CLASS REFERENCE constructs the referenced class (15.2.1), and the
          // reference is routinely a function result —
          // `with GetPainterClass.Create(...) do MainPaint`, a virtual-
          // constructor factory. Type the qualifier and unwrap `class of T`.
          Result := ClassRefTargetX(
            WithTargetTypeX(AId, LM.Tree.Nodes[LBase].FirstChild));
          if XValid(Result) then
            Exit;
        end;
        Result := WithTargetTypeX(AId, LBase);
      end;

    nkInherited:
      begin
        // `with inherited Canvas do` (Vcl.ExtCtrls). 12.1.2: `inherited` heads a
        // designator, and `inherited Name` names a member of the ANCESTOR — so
        // the target's type is that member's, looked up from the ancestor of the
        // struct whose method body this is, never from the struct itself.
        // Without it the target had no type, the body's Pen/Brush went
        // undeclared, and StretchDraw's bare name matched a GLOBAL instead of the
        // canvas method — which is where that E2035 came from.
        LName := LM.Tree.Nodes[ANode].FirstChild;
        if (LName = NIL_NODE) or (LM.Tree.Nodes[LName].Kind <> nkIdent) then
          Exit;
        LSym := StructSymOfNode(LM, ANode);
        if LSym = NIL_SYM then
          Exit;
        LBX := AncestorOfX(XPlain(AId, LSym));
        if XValid(LBX) and FindMemberX(AId, LBX,
             LM.Tree.NodeNameLower(LName), LMemMid, LMemSym, LCtx) then
          Result := SubstX(SymDeclTypeX(LMemMid, LMemSym), LCtx, 0);
      end;

    nkIdent:
      begin
        // A bare class TYPE NAME is itself a legal target (5.7) — its class
        // methods and class vars are what the body sees, exactly as for a
        // `class of` reference. ResolveTypeExpr yields XNil for anything that
        // is not a type, so a value designator falls through unchanged.
        Result := ResolveTypeExpr(AId, ANode);
        if XValid(Result) then
          Exit;
        // A routine that REQUIRES arguments is not what a bare `with Name do`
        // calls — see ParamlessOverloadX. Tried before the ordinary reading,
        // which would hand back that routine's own result type.
        LSym := LM.RefMap[ANode];
        if LSym <> NIL_SYM then
        begin
          LMemMid := AId;
          LMemSym := LSym;
        end
        else if LM.ExtRefMap.TryGetValue(ANode, LExt) then
        begin
          LMemMid := LExt.UnitId;
          LMemSym := LExt.Sym;
        end
        else
          LMemSym := NIL_SYM;
        if (LMemSym <> NIL_SYM) and RoutineHasParams(LMemMid, LMemSym) then
        begin
          LSym := StructSymOfNode(LM, ANode);
          if (LSym <> NIL_SYM) and ParamlessOverloadX(XPlain(AId, LSym),
               LM.Tree.NodeNameLower(ANode), LMemMid, LMemSym, LCtx) then
          begin
            Result := SubstX(SymDeclTypeX(LMemMid, LMemSym), LCtx, 0);
            if XValid(Result) then
              Exit;
          end;
        end;
        LSym := LM.RefMap[ANode];
        if LSym <> NIL_SYM then
          Result := SymDeclTypeX(AId, LSym)
        // A type ALREADY recorded for this ident outranks re-deriving one from
        // the symbol, because it is the only reading that can carry a frame.
        // The inherited pass writes it for a member it reached through a
        // GENERIC ancestor: `Items` on a `class(TObjectList<TFloatingObj>)` is
        // declared `T` on TList<T>, and SymDeclTypeX alone returns that OPEN
        // parameter — so `with Items[I] do` indexed nothing and the whole body
        // went undeclared (HTMLSubs.TFloatingObjList.Decrement).
        else if LM.ExprTypeX.TryGetValue(ANode, LBX) and XValid(LBX) then
          Result := LBX
        else if LM.ExtRefMap.TryGetValue(ANode, LExt) then
          Result := SymDeclTypeX(LExt.UnitId, LExt.Sym)
        // `Self` has no symbol — nothing declares it (11.3.3), so RefMap is
        // empty for it and the recursion above dead-ends. Inside a method body
        // its type is the enclosing struct, which is exactly what
        // StructSymOfNode answers. Real shape: `with Self.TreeViewControl do`,
        // where dropping the qualifier's type loses the whole with scope.
        else if SameText(LM.Tree.NodeText(ANode), 'Self') then
        begin
          LSym := StructSymOfNode(LM, ANode);
          if LSym <> NIL_SYM then
            Result := XPlain(AId, LSym);
        end;
      end;

    nkMember:
      begin
        LBase := LM.Tree.Nodes[ANode].FirstChild;
        if LBase = NIL_NODE then
          Exit;
        LName := LM.Tree.Nodes[LBase].NextSibling;
        if (LName = NIL_NODE) or (LM.Tree.Nodes[LName].Kind <> nkIdent) then
          Exit;
        // A CONSTRUCTOR yields the class, not its (absent) result type — and
        // a parameterless one needs no parentheses, so `with TThing.Create do`
        // arrives here as a plain nkMember, not as the nkCall the branch above
        // handles (System.Win.VCLCom writes it with arguments, the paren-less
        // form is just as legal).
        // Asked through DesignatorSymX, NOT by probing the maps here: for a
        // cross-unit class the constructor is not bound yet at with-pass time
        // (CrossType records that, and it runs later), and DesignatorSymX is
        // the one place that knows to fall back to walking the base's type.
        // Probing the maps directly was the bug — `with TControlCanvas.Create
        // do` (Vcl.ComCtrls) then fell through to the generic member path,
        // which typed the target as the constructor's own (absent) result type.
        if DesignatorSymX(AId, ANode, LMemMid, LMemSym) and
           IsConstructorSym(LMemMid, LMemSym) then
        begin
          Result := ResolveTypeExpr(AId, LBase);
          if not XValid(Result) then
            // Paren-less form of the class-reference case above.
            Result := ClassRefTargetX(WithTargetTypeX(AId, LBase));
          Exit;
        end;
        LSym := LM.RefMap[LName];
        // The member may already be bound (same-unit field, or a cross-unit
        // one the earlier passes reached); otherwise find it in the base's
        // type. Both paths end at the MEMBER's own declared type.
        if LSym <> NIL_SYM then
          Exit(SymDeclTypeX(AId, LSym));
        if LM.ExtRefMap.TryGetValue(LName, LExt) then
          Exit(SymDeclTypeX(LExt.UnitId, LExt.Sym));
        LBX := WithTargetTypeX(AId, LBase);
        if XValid(LBX) and FindMemberX(AId, LBX,
             LM.Tree.NodeNameLower(LName), LMemMid, LMemSym, LCtx) then
          // SubstX closes the member's declared type over the base's
          // instantiation frame: FThreads: TThreadList<TBaseWorkerThread>
          // makes LockList's declared TList<T> a TList<TBaseWorkerThread>,
          // exactly as CrossType's own member typing does. Without it the
          // with-body would look members up in an OPEN TList<T> — right
          // members, imprecise element types.
          Result := SubstX(SymDeclTypeX(LMemMid, LMemSym), LCtx, 0);
      end;
  end;
end;

// True when ANode sits in the BODY of some enclosing `with`. An identifier
// inside a with's own TARGET expression is NOT in its scope (the target is
// evaluated in the enclosing one), hence the last-child test.
function TPasSemaProject.InsideWithBody(AModel: TPasSemaModel;
  ANode: Integer): Boolean;
var
  LCur, LParent, LLast: Integer;
begin
  Result := False;
  LCur := ANode;
  LParent := AModel.Tree.Nodes[LCur].Parent;
  while LParent <> NIL_NODE do
  begin
    if AModel.Tree.Nodes[LParent].Kind = nkWithStmt then
    begin
      LLast := AModel.Tree.Nodes[LParent].FirstChild;
      while (LLast <> NIL_NODE) and
            (AModel.Tree.Nodes[LLast].NextSibling <> NIL_NODE) do
        LLast := AModel.Tree.Nodes[LLast].NextSibling;
      if LCur = LLast then
        Exit(True);
    end;
    LCur := LParent;
    LParent := AModel.Tree.Nodes[LCur].Parent;
  end;
end;

{ True when ANode sits inside a with TARGET that is not the FIRST one.

  Such a node needs the with pass just as much as a body node does, because a
  later target is resolved inside the earlier ones — `with DIB, dsbm, dsbmih do`
  (Vcl.Graphics), where dsbm is a field of DIB. It is NOT in any with body, so
  testing only InsideWithBody left it to the inherited pass, which knows nothing
  about with scopes: the target came out undeclared and every member reached
  through it in the body followed. FindInEnclosingWith has handled the
  target-sees-earlier-targets case since the multi-target fix; this is what
  actually routes those nodes to it. }
function TPasSemaProject.InsideLaterWithTarget(AModel: TPasSemaModel;
  ANode: Integer): Boolean;
var
  LCur, LParent, LChild: Integer;
begin
  Result := False;
  LCur := ANode;
  LParent := AModel.Tree.Nodes[LCur].Parent;
  while LParent <> NIL_NODE do
  begin
    if AModel.Tree.Nodes[LParent].Kind = nkWithStmt then
    begin
      // LCur is one of the with's children. It qualifies when it is a target
      // (i.e. has a next sibling — the body is last) and not the first one.
      LChild := AModel.Tree.Nodes[LParent].FirstChild;
      if (LChild <> LCur) and (LCur <> NIL_NODE) and
         (AModel.Tree.Nodes[LCur].NextSibling <> NIL_NODE) then
        Exit(True);
    end;
    LCur := LParent;
    LParent := AModel.Tree.Nodes[LCur].Parent;
  end;
end;

// Resolves ANameLower as a member of an enclosing with-target's type.
// Precedence follows 5.7: the INNERMOST `with` first (the outward climb gives
// that for free), and within one `with` its targets RIGHT-TO-LEFT, so the
// last target wins a name they share — the same rule the intra-unit pass gets
// out of Resolve()'s reverse Additional-scope walk.
//
// Only reached for names the intra-unit pass could NOT bind, so a `with`
// whose targets are a mix of same-unit and cross-unit types keeps working:
// the same-unit ones are already open, and this fills in the rest.
function TPasSemaProject.FindInEnclosingWith(AId, ANode: Integer;
  const ANameLower: string; out AUid, ASym: Integer;
  out AX: TSemaXType): Boolean;
var
  LM: TPasSemaModel;
  LCur, LParent, LLast, LChild, LIdx, LCtx, LFrom: Integer;
  LTargets: TArray<Integer>;
  LX: TSemaXType;
begin
  Result := False;
  AX := XNil;
  LM := FModels[AId];
  LCur := ANode;
  LParent := LM.Tree.Nodes[LCur].Parent;
  while LParent <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LParent].Kind = nkWithStmt then
    begin
      // Children are target1..targetN then the body (last).
      LTargets := nil;
      LChild := LM.Tree.Nodes[LParent].FirstChild;
      LLast := LChild;
      while (LLast <> NIL_NODE) and
            (LM.Tree.Nodes[LLast].NextSibling <> NIL_NODE) do
        LLast := LM.Tree.Nodes[LLast].NextSibling;
      while (LChild <> NIL_NODE) and (LChild <> LLast) do
      begin
        LTargets := LTargets + [LChild];
        LChild := LM.Tree.Nodes[LChild].NextSibling;
      end;
      // WHICH targets are open at LCur. In the body, all of them. But a target
      // is itself resolved inside the ones BEFORE it — `with DIB, dsbm, dsbmih
      // do` is legal precisely because dsbm is a field of DIB and dsbmih a
      // field of dsbm (Vcl.Graphics does exactly this). Treating a target like
      // ordinary enclosing code, which is what only testing `LCur = LLast`
      // did, left every such target unresolved and then every member of it in
      // the body too.
      LFrom := -1;
      if LCur = LLast then
        LFrom := High(LTargets)
      else
        for LIdx := 0 to High(LTargets) do
          if LTargets[LIdx] = LCur then
          begin
            LFrom := LIdx - 1;   // target k sees 0..k-1, never itself
            Break;
          end;
      if LFrom >= 0 then
        for LIdx := LFrom downto 0 do
        begin
          LX := WithTargetTypeX(AId, LTargets[LIdx]);
          if XValid(LX) and
             FindMemberX(AId, LX, ANameLower, AUid, ASym, LCtx) then
          begin
            // The member's declared type, closed over the instantiation
            // frame FindMemberX reported — travels back with the hit (see
            // TPasInhPending.X for why it cannot be recovered later).
            AX := SubstX(SymDeclTypeX(AUid, ASym), LCtx, 0);
            Exit(True);
          end;
        end;
    end;
    LCur := LParent;
    LParent := LM.Tree.Nodes[LCur].Parent;
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
procedure TPasSemaProject.SizeCrossWork(ACount: Integer);
begin
  // Never shrinks within a run: BuildHelperMap resets the whole thing between
  // runs, and a driver may call the with pass with a count the inherited pass
  // did not see.
  if Length(FWorkBuilt) < ACount then
  begin
    SetLength(FInhWork, ACount);
    SetLength(FWithWork, ACount);
    SetLength(FWorkBuilt, ACount);
  end;
end;

{ ONE scan of a model's nodes producing the candidate lists for BOTH body
  passes, which want complementary sets: the inherited pass takes idents
  OUTSIDE any with body, the with pass those INSIDE one.

  The scan those passes used to do each was the expensive part of them, not the
  work: per node it probed ExtRefMap (a dictionary) and, for the with pass, ran
  InsideWithBody (a walk up the parent chain) — and RunWithPass iterates to a
  fixpoint, so it paid that for every node of every model on every round. Here
  each node is classified once.

  The lists are a SUPERSET of what each pass acts on: every guard those passes
  apply is still applied per node inside them. That matters for the with pass in
  particular, whose bound/unbound test legitimately changes between rounds, so
  it must stay in the loop and not be baked into the list.

  Honest sizing, measured on the 665-unit corpus: this takes the two passes from
  617 ms to 480 ms, but on TOTAL analysis time that is inside the noise band
  (2904 -> 2882 ms best-of-5). The commit's actual win is the convergence fix in
  CrossResolveWith. Kept because the per-round rescan it removes scales with
  fixpoint depth, and depth grows with project size — not because it moved the
  number today. }
procedure TPasSemaProject.EnsureCrossWork(AId: Integer);
var
  LM: TPasSemaModel;
  LNode, LBase, LInhN, LWithN: Integer;
  LInh, LWith: TArray<Integer>;
begin
  if FWorkBuilt[AId] then
    Exit;
  LM := FModels[AId];
  // High(RefMap) is the node count; both lists are far smaller, but sizing to
  // it once beats growing them incrementally.
  SetLength(LInh, Length(LM.RefMap));
  SetLength(LWith, Length(LM.RefMap));
  LInhN := 0;
  LWithN := 0;
  for LNode := 0 to High(LM.RefMap) do
  begin
    if LM.Tree.Nodes[LNode].Kind <> nkIdent then
      Continue;
    if (LNode > High(LM.NodeScope)) or (LM.NodeScope[LNode] = NIL_SCOPE) then
      Continue;
    // The member name of A.B is resolved through A, never as a plain ident.
    LBase := LM.Tree.Nodes[LNode].Parent;
    if (LBase <> NIL_NODE) and (LM.Tree.Nodes[LBase].Kind = nkMember) and
       (LM.Tree.Nodes[LBase].FirstChild <> LNode) then
      Continue;
    if InsideWithBody(LM, LNode) or InsideLaterWithTarget(LM, LNode) then
    begin
      // NOT filtered on bound-ness: the with pass revisits an already-bound
      // name when its with target went unopened, to OVERRIDE a wrong guess.
      LWith[LWithN] := LNode;
      Inc(LWithN);
    end
    else if ((LM.RefMap[LNode] = NIL_SYM) and
             not LM.ExtRefMap.ContainsKey(LNode)) or
            ((LM.RefMap[LNode] <> NIL_SYM) and
             (LM.Symbols[LM.RefMap[LNode]].Kind = skUnitRef)) then
    begin
      // Safe to bake in here: CrossResolve has finished, and nothing between
      // this scan and the inherited pass can bind one of these.
      //
      // A UNIT-REFERENCE binding joins them: a bare unit name is never a value,
      // and an inherited member outranks it. A dotted `uses` registers the unit
      // under its LAST segment, so that segment used bare in a class which also
      // has a member of that name binds to the unit. Cheap where the same trick
      // for BUILTIN bindings was not -- unit refs are bounded by the uses
      // clause, while every Integer and Length is builtin-bound, and queueing
      // those measured +3.6%.
      LInh[LInhN] := LNode;
      Inc(LInhN);
    end;
  end;
  SetLength(LInh, LInhN);
  SetLength(LWith, LWithN);
  FInhWork[AId] := LInh;
  FWithWork[AId] := LWith;
  FWorkBuilt[AId] := True;
end;

// One empty slot per model, BEFORE the parallel CrossResolve workers start
// filling their own (see FDeclWork). Cleared every run: a list held over would
// name nodes of a tree a staged run has since replaced.
procedure TPasSemaProject.PrepareDeclWork(ACount: Integer);
var
  LIdx: Integer;
begin
  SetLength(FDeclWork, ACount);
  for LIdx := 0 to ACount - 1 do
    FDeclWork[LIdx] := nil;
end;

{ The DECLARATION-site companion to CrossResolveInherited: the names inside a
  type declaration that CrossResolve could bind nowhere, retried against the
  ancestry of every class they are declared inside (see DeclStructsOfNode).

  Runs BEFORE the inherited pass, and that order is the whole point — the
  entries it produces are HERITAGE references, which is precisely what the
  inherited and with passes read when they walk a struct's ancestors. Feeding
  them into the same round as their consumers is the ordering hazard
  StructSymOfNode's own comment records (deferring whole declarations there once
  fixed 47 property specifiers and broke 74 inherited members); a separately
  committed earlier pass has no such problem.

  Only the total failures reach here, never every declaration-site name, which
  keeps this off the hot path: the expensive FindMemberX walk runs on the
  handful of nodes that were about to be reported as errors anyway.

  Known precedence gap that costs: a used unit's global still outranks an
  inherited member for these, where dcc has it the other way round. Closing it
  means deferring EVERY unresolved-locally declaration-site name — that is every
  cross-unit type reference in every class in the closure, all of them through
  FindMemberX. Not worth it for a collision nobody has hit; noted in the README
  To-do instead. }
procedure TPasSemaProject.CrossResolveDecl(AId: Integer;
  var APending: TArray<TPasInhPending>; AEmit: Boolean);
var
  LModel: TPasSemaModel;
  LNode, LUid, LSym, LCtx, LWIdx: Integer;
  LPend: TPasInhPending;
  LNameLower: string;
  LFound: Boolean;
begin
  APending := nil;
  if AId > High(FDeclWork) then
    Exit;
  LModel := FModels[AId];
  for LWIdx := 0 to High(FDeclWork[AId]) do
  begin
    LNode := FDeclWork[AId][LWIdx];
    // An earlier ROUND may have bound it — that is what the rounds are for.
    if (LModel.RefMap[LNode] <> NIL_SYM) or
       LModel.ExtRefMap.ContainsKey(LNode) then
      Continue;
    LNameLower := LModel.Tree.NodeNameLower(LNode);
    LFound := False;
    // Innermost declaration first, matching dcc's precedence — and matching
    // what the method-body side already does with OuterStructsOfNode.
    for var LStruct in DeclStructsOfNode(LModel, LNode) do
      if FindMemberX(AId, XPlain(AId, LStruct), LNameLower, LUid, LSym,
        LCtx) then
      begin
        LFound := True;
        Break;
      end;
    if LFound then
    begin
      LPend.Node := LNode;
      LPend.Ext.UnitId := LUid;
      LPend.Ext.Sym := LSym;
      LPend.X := XNil;
      APending := APending + [LPend];
    end
    else if AEmit and LModel.AllUsesResolved then
      EmitE2003(LModel, LNode);   // CrossResolve's verdict, just deferred
  end;
end;

{ Parallel compute + sequential commit, iterated: one nested class's heritage
  can be another's, and round N+1 sees round N's bindings. Same shape and same
  reasoning as RunWithPass — including E2003 only in the final round, so a name
  a later round resolves is never reported. Depth here is nesting depth, so two
  rounds is already generous; the cap is a runaway guard. }
procedure TPasSemaProject.RunDeclPass(ACount: Integer);
const
  MAX_ROUNDS = 4;
var
  LPending: TArray<TArray<TPasInhPending>>;
  LIdx, LP, LRound, LNew: Integer;
  LEmit: Boolean;
begin
  SetLength(LPending, ACount);
  LRound := 0;
  LEmit := False;
  while True do
  begin
    Inc(LRound);
    for LIdx := 0 to ACount - 1 do
      LPending[LIdx] := nil;
    ForEachIndex(ACount - 1,
      procedure(AIdx: Integer)
      begin
        CrossResolveDecl(AIdx, LPending[AIdx], LEmit);
      end);
    LNew := 0;
    for LIdx := 0 to ACount - 1 do
      Inc(LNew, Length(LPending[LIdx]));
    for LIdx := 0 to ACount - 1 do
      for LP := 0 to High(LPending[LIdx]) do
        FModels[LIdx].ExtRefMap.AddOrSetValue(LPending[LIdx][LP].Node,
          LPending[LIdx][LP].Ext);
    if LEmit then
      Break;
    LEmit := (LNew = 0) or (LRound >= MAX_ROUNDS - 1);
  end;
end;

procedure TPasSemaProject.CrossResolveInherited(AId: Integer;
  var APending: TArray<TPasInhPending>);
var
  LModel: TPasSemaModel;
  LNode, LStruct, LUid, LSym, LCtx, LMatchNode, LWIdx: Integer;
  LPend: TPasInhPending;
  LFound: Boolean;
  LNameLower: string;
begin
  APending := nil;
  LModel := FModels[AId];
  EnsureCrossWork(AId);
  // Candidates only — kind, scope, A.B-member and not-in-a-with-body were all
  // decided by that single scan (see EnsureCrossWork).
  for LWIdx := 0 to High(FInhWork[AId]) do
  begin
    LNode := FInhWork[AId][LWIdx];
    // NB a with BODY is deliberately absent from this list and handled by the
    // LATER with pass: deciding such a node needs the with-target's TYPE node,
    // and for a `with` inside a METHOD that type node is itself a method-body
    // node THIS pass is still producing — it would be read while still
    // uncommitted and come back unresolved. Keeping them out preserves this
    // pass's stated invariant (see the header: its own entries are never type
    // nodes another worker needs).
    LStruct := StructSymOfNode(LModel, LNode);
    if LStruct = NIL_SYM then
      Continue;
    LNameLower := LModel.Tree.NodeNameLower(LNode);
    if (LNameLower = 'result') or (LNameLower = 'self') then
      Continue;
    // Innermost enclosing struct's ancestry, then the OUTER segments of a
    // qualified method name (see OuterStructsOfNode), then the ordinary
    // uses/System fallbacks — dcc's own precedence order.
    LFound := FindMemberX(AId, XPlain(AId, LStruct), LNameLower, LUid, LSym, LCtx);
    if not LFound then
      for var LOuter in OuterStructsOfNode(LModel, LNode, LStruct) do
        if FindMemberX(AId, XPlain(AId, LOuter), LNameLower, LUid, LSym, LCtx) then
        begin
          LFound := True;
          Break;
        end;
    // The namespace-token exemption runs AFTER the member walk, not before it:
    // an inherited MEMBER outranks a unit name. `uses VirtualTrees.Header`
    // registers the unit under its LAST segment, so in a class that also has a
    // `Header` property the qualifier test says "this is a namespace token" and
    // skipped the very node that had a member to find — leaving `Header.Columns`
    // typed as nothing and its whole with body undeclared. Tested first, it also
    // suppressed the override below, which is why that change alone did nothing.
    if not LFound and (QualifierUnitAt(AId, LNode, LMatchNode) >= 0) then
      Continue;
    // A UNIT-REFERENCE binding is here to be OVERRIDDEN, not gap-filled: it has
    // a binding already, the uses/System fallbacks would only re-find the same
    // unit, and with no inherited member Phase 1's answer simply stands. No
    // diagnostic either way.
    if (LModel.RefMap[LNode] <> NIL_SYM) and
       (LModel.Symbols[LModel.RefMap[LNode]].Kind = skUnitRef) then
    begin
      if LFound then
      begin
        LPend.Node := LNode;
        LPend.Ext.UnitId := LUid;
        LPend.Ext.Sym := LSym;
        LPend.X := XNil;
        APending := APending + [LPend];
      end;
      Continue;
    end;
    if LFound or
       FindInUses(AId, LNameLower, LUid, LSym) or
       FindInSystemUnit(LNameLower, LUid, LSym) or
       FindInSysInitUnit(LNameLower, LUid, LSym) then
    begin
      LPend.Node := LNode;
      LPend.Ext.UnitId := LUid;
      LPend.Ext.Sym := LSym;
      // The member's type, closed over the instantiation frame FindMemberX
      // reported — but ONLY when there is one. A member reached through a
      // GENERIC ancestor is declared in the open parameters (`Items: T` on
      // TList<T>), and the frame is the only thing that turns that `T` into the
      // actual element type. It cannot be recovered later: nothing downstream
      // knows which hop the member came from. Without it `with Items[I] do`
      // over a `class(TObjectList<TFloatingObj>)` indexed the OPEN T and opened
      // over nothing.
      if LFound and (LCtx <> NIL_INST) then
        LPend.X := SubstX(SymDeclTypeX(LUid, LSym), LCtx, 0)
      else
        LPend.X := XNil;
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
  // Sequential point right before the first parallel FindMemberX consumers:
  // the helper registry must be complete and read-only by the time the
  // workers below start (see BuildHelperMap / ActiveHelperFor).
  BuildHelperMap;
  // Heritage references this pass is about to WALK are resolved (and
  // committed) first — see CrossResolveDecl for why it cannot be folded in
  // here. Placed inside this pass, not beside it, so it inherits the same
  // "helper map is built" precondition rather than rebuilding it.
  RunDeclPass(ACount);
  SizeCrossWork(ACount);   // slots must exist before workers write their own
  SetLength(LPending, ACount);
  ForEachIndex(ACount - 1,
    procedure(AIdx: Integer)
    begin
      CrossResolveInherited(AIdx, LPending[AIdx]);
    end);
  for LIdx := 0 to ACount - 1 do
    for LP := 0 to High(LPending[LIdx]) do
    begin
      FModels[LIdx].RefMap[LPending[LIdx][LP].Node] := NIL_SYM;
      FModels[LIdx].ExtRefMap.AddOrSetValue(LPending[LIdx][LP].Node,
        LPending[LIdx][LP].Ext);
      // Same as the with pass's commit: the frame-substituted member type,
      // when the compute step had a frame at all.
      if XValid(LPending[LIdx][LP].X) then
        FModels[LIdx].ExprTypeX.AddOrSetValue(LPending[LIdx][LP].Node,
          LPending[LIdx][LP].X);
    end;
end;

// The deferred `with`-body pass: everything CrossResolve and
// CrossResolveInherited both stepped over (see FindInEnclosingWith). Must run
// AFTER RunInheritedPass has COMMITTED, because a with-target's type node
// inside a method body is exactly what that pass produces.
//
// Same two-phase shape as the inherited pass, and safe for the same reason:
// each worker only READS ExtRefMaps and writes its own APending/Diags. This
// pass's own entries are with-BODY statement nodes, never type/heritage
// nodes, so no worker depends on another's uncommitted entry.
procedure TPasSemaProject.CrossResolveWith(AId: Integer;
  var APending: TArray<TPasInhPending>; AEmit: Boolean);
var
  LModel: TPasSemaModel;
  LNode, LStruct, LUid, LSym, LCtx, LMatchNode, LWIdx: Integer;
  LPend: TPasInhPending;
  LNameLower: string;
  LBound: Boolean;
  LMemX: TSemaXType;
  LCurExt: TPasExtRef;
begin
  APending := nil;
  LModel := FModels[AId];
  EnsureCrossWork(AId);
  // Idents inside a with body, from the one classifying scan. Bound-ness is
  // NOT part of that list and is tested below per round, because a round can
  // bind a name the next round must then leave alone.
  for LWIdx := 0 to High(FWithWork[AId]) do
  begin
    LNode := FWithWork[AId][LWIdx];
    LBound := (LModel.RefMap[LNode] <> NIL_SYM) or
              LModel.ExtRefMap.ContainsKey(LNode);
    // An already-bound name is finished — EXCEPT in a `with` body whose target
    // type Phase 1 could not resolve. There its binding is only a guess, and a
    // member of that target outranks whatever it guessed (5.7): such nodes are
    // revisited here and OVERRIDDEN on a hit. That is the difference between
    // filling a gap and fixing a wrong answer — `with GR do Shared := 'x'`
    // must mean GR.Shared even when the enclosing class, a local, a parameter
    // or a unit global also offers a `Shared`.
    // A LATER TARGET is revisited for the same reason, and its Phase-1 binding
    // is even less trustworthy: `with ZStream, ZLIB do` (Vcl.Imaging.pngimage),
    // where ZLIB is a FIELD of ZStream and also the name of a used unit
    // (System.ZLib). Phase 1 bound the unit reference — a bare unit name is not
    // a legal with target at all (5.7) — and, being "bound", the node was never
    // reconsidered, so the second target never opened and its members
    // (next_out/avail_out) were false E2003. 5.7 is explicit on both halves: a
    // target after the first is resolved INSIDE the ones before it, and a target
    // member outranks everything else in scope, so an earlier best-effort
    // binding must be OVERRIDDEN rather than gap-filled.
    if LBound and not LModel.InUnopenedWithBody(LNode) and
       not InsideLaterWithTarget(LModel, LNode) then
      Continue;
    // Never re-point a DECLARATION's own name node: MarkDeclName records
    // declarations in RefMap too, and an inline `var Shared: Integer` inside
    // the body stays a declaration — only REFERENCES bind to the member.
    if (LModel.RefMap[LNode] <> NIL_SYM) and
       (LModel.Symbols[LModel.RefMap[LNode]].DeclNode = LNode) then
      Continue;
    // Scope, the A.B-member case and "is inside a with body" were all settled
    // by EnsureCrossWork's single scan.
    LNameLower := LModel.Tree.NodeNameLower(LNode);
    if (LNameLower = 'result') or (LNameLower = 'self') then
      Continue;
    if QualifierUnitAt(AId, LNode, LMatchNode) >= 0 then
      Continue;
    // dcc's order here: the `with` scope is opened INSIDE the enclosing body,
    // so its members shadow the enclosing method's own; then used units, then
    // the implicit System/SysInit units; E2003 only after every one misses.
    LStruct := StructSymOfNode(LModel, LNode);
    if FindInEnclosingWith(AId, LNode, LNameLower, LUid, LSym, LMemX) then
    begin
      // Already exactly this symbol — nothing to rewrite. BOTH maps have to be
      // consulted, and missing the second one is what made the fixpoint spin:
      // a commit CLEARS RefMap and writes ExtRefMap, so a node bound by an
      // earlier ROUND looked unbound-here-but-still-in-an-unopened-with-body,
      // got re-found, and was re-reported as a change every single round. The
      // loop then never converged and always ran the full MAX_ROUNDS.
      if (LUid = AId) and (LModel.RefMap[LNode] = LSym) then
        Continue;
      if LModel.ExtRefMap.TryGetValue(LNode, LCurExt) and
         (LCurExt.UnitId = LUid) and (LCurExt.Sym = LSym) then
        Continue;
      LPend.Node := LNode;
      LPend.Ext.UnitId := LUid;
      LPend.Ext.Sym := LSym;
      LPend.X := LMemX;
      APending := APending + [LPend];
    end
    else if LBound then
      Continue   // no with member by that name: Phase 1's binding stands
    else if ((LStruct <> NIL_SYM) and
             FindMemberX(AId, XPlain(AId, LStruct), LNameLower, LUid, LSym, LCtx)) or
            FindInUses(AId, LNameLower, LUid, LSym) or
            FindInSystemUnit(LNameLower, LUid, LSym) or
            FindInSysInitUnit(LNameLower, LUid, LSym) then
    begin
      LPend.Node := LNode;
      LPend.Ext.UnitId := LUid;
      LPend.Ext.Sym := LSym;
      LPend.X := XNil;
      APending := APending + [LPend];
    end
    else if AEmit and LModel.AllUsesResolved then
      EmitE2003(LModel, LNode);
  end;
end;

{ Runs to a FIXPOINT, because one round cannot resolve a nested `with` whose
  inner target is itself only resolvable by this pass.

  `else with CellRect do ... else with Canvas do begin Pen.Color := ... end`
  (Vcl.ColorGrd) is the shape: `Canvas` is an inherited cross-unit property, so
  the earlier passes skip it (it sits in the OUTER with's body, and deciding
  such a node needs a with-target type this very pass is still producing), and
  this pass does resolve it — but only into APending, committed after every
  worker has finished. So within one round `Pen`'s lookup still sees `Canvas`
  unbound, the inner with never opens, and every member of it is a false E2003.

  Iterating is the cheap correct answer: each round is a full parallel compute +
  sequential commit, so the pass's concurrency invariant (workers only ever READ
  committed maps) is untouched, and round N+1 sees round N's bindings. Real
  nesting is 2-3 deep, so this converges in a handful of rounds; the cap is a
  runaway guard, not a limit anybody reaches.

  E2003 is emitted ONLY in the final round. Emitting earlier would report every
  name that a later round goes on to resolve. }
procedure TPasSemaProject.RunWithPass(ACount: Integer);
const
  MAX_ROUNDS = 8;
var
  LPending: TArray<TArray<TPasInhPending>>;
  LIdx, LP, LNode, LRound, LNew: Integer;
  LEmit: Boolean;
begin
  SetLength(LPending, ACount);
  SizeCrossWork(ACount);   // AnalyzeFile reaches this pass without the other
  LRound := 0;
  LEmit := False;
  while True do
  begin
    Inc(LRound);
    for LIdx := 0 to ACount - 1 do
      LPending[LIdx] := nil;
    ForEachIndex(ACount - 1,
      procedure(AIdx: Integer)
      begin
        CrossResolveWith(AIdx, LPending[AIdx], LEmit);
      end);
    LNew := 0;
    for LIdx := 0 to ACount - 1 do
      Inc(LNew, Length(LPending[LIdx]));
    for LIdx := 0 to ACount - 1 do
      for LP := 0 to High(LPending[LIdx]) do
      begin
        LNode := LPending[LIdx][LP].Node;
        // RefMap must be CLEARED, not just shadowed: every consumer checks it
        // FIRST and only falls back to ExtRefMap (see CrossType's nkIdent), so
        // an override that merely added an ExtRefMap entry would be ignored.
        // Harmless for the gap-filling entries — those were NIL_SYM already.
        FModels[LIdx].RefMap[LNode] := NIL_SYM;
        FModels[LIdx].ExtRefMap.AddOrSetValue(LNode, LPending[LIdx][LP].Ext);
        // The frame-substituted member type, when the compute step had one.
        // Committed here so it EXISTS before CrossType runs; CrossType's
        // persist loop leaves existing entries alone (see there).
        if XValid(LPending[LIdx][LP].X) then
          FModels[LIdx].ExprTypeX.AddOrSetValue(LNode, LPending[LIdx][LP].X);
      end;
    if LEmit then
      Break;   // the emitting round is always the last one
    // Converged (or out of rounds): repeat once more WITH emission. That round
    // sees exactly this state, so the names it cannot resolve are the stable
    // ones — and it re-commits nothing, since it finds nothing new.
    if (LNew = 0) or (LRound >= MAX_ROUNDS) then
      LEmit := True;
  end;
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
  PrepareDeclWork(FModels.Count);
  CrossResolve(Result);
  BuildHelperMap;   // needs CrossResolve's ExtRefMap; feeds FindMemberX below
  // Heritage first, for the same reason the parallel drivers do it — the
  // inherited walk below reads what it binds (see CrossResolveDecl).
  RunDeclPass(FModels.Count);
  var LPend: TArray<TPasInhPending>;
  CrossResolveInherited(Result, LPend);
  for LIdx := 0 to High(LPend) do
    FModels[Result].ExtRefMap.Add(LPend[LIdx].Node, LPend[LIdx].Ext);
  CheckCalls(Result);
  CheckConstraints(Result);
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

function TPasSemaProject.LoadFailures: TArray<string>;
begin
  Result := FLoadFailures;
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
  PrepareDeclWork(LN);
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
  // Then the with-body pass, which reads type nodes the inherited pass just
  // COMMITTED (see CrossResolveWith) — order matters, not just grouping. Timed
  // apart because it iterates to a fixpoint: its cost is the one that is not
  // obvious from reading the code.
  RunWithPass(LN);
  Stage('with');
  ForEachIndex(LN - 1,
    procedure(AIdx: Integer)
    begin
      CheckCalls(AIdx);
      CheckConstraints(AIdx);
    end);
  Stage('calls');
  // Sequential by design — see AnalyzeDirectory's Phase-3c comment.
  for LIdx := 0 to FModels.Count - 1 do
    BindTypesX(LIdx);
  Stage('bindx');
  RunCrossTypePass(LN);
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
  PrepareDeclWork(LN);
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
  // Then the with-body pass, which reads type nodes the inherited pass just
  // COMMITTED (see CrossResolveWith) — order matters, not just grouping. Timed
  // apart because it iterates to a fixpoint: its cost is the one that is not
  // obvious from reading the code.
  RunWithPass(LN);
  Stage('with');
  ForEachIndex(LN - 1,
    procedure(AIdx: Integer)
    begin
      CheckCalls(AIdx);
      CheckConstraints(AIdx);
    end);
  Stage('calls');
  // Cross typing stays SEQUENTIAL by design: Instantiate mutates the shared
  // instance table, and CrossType both writes a model's RefMap/ExtRefMap and
  // reads other models' — parallelizing would need locks on the hot path for
  // ~5% of the total time (measured on the full RTL).
  for LIdx := 0 to FModels.Count - 1 do
    BindTypesX(LIdx);
  Stage('bindx');
  RunCrossTypePass(LN);
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
    PrepareDeclWork(LN);
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
    // Reads type nodes the inherited pass just COMMITTED — see
    // CrossResolveWith. Kept inside the same reported step (it is the same
    // "resolve what the parallel pass deferred" phase, just a later slice).
    RunWithPass(LN);
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
        CheckConstraints(AIdx);
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
    RunCrossTypePass(LN);
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
