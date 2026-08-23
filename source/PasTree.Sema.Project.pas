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
  PasTree.Types,
  PasTree.Preprocessor,
  PasTree.Platforms,
  PasTree.SourceManager,
  PasTree.Ast,
  PasTree.Sema.Model;

type
  // One generic type PARAMETER bound to an actual, for the SizeOf layout walk
  // only (the general instantiation machinery is TSemaInstance below). The
  // argument is kept as a (model, type-node) pair rather than a resolved
  // symbol because an argument may be any type expression — `TG<array[0..2]
  // of Byte>` — and the walk already knows how to size a node.
  TPasSubstEntry = record
    Name: string;     // lower-case parameter name
    Mid: Integer;     // model the argument node lives in
    Node: Integer;    // the argument's type node
  end;
  TPasSubst = TArray<TPasSubstEntry>;

  // One generic instantiation: a generic type symbol + positional actual
  // args. Args may themselves reference skGenericParam symbols (an "open"
  // instantiation inside another generic's body, e.g. TEnumerator<T> inside
  // TList<T>) — those close over the outer instance on substitution.
  TSemaInstance = record
    UnitId: Integer;            // model id of the generic type symbol
    Sym: Integer;               // the skType symbol of the generic
    Args: TArray<TSemaXType>;
  end;

  // Callback for EnumMembersX: one member symbol in its declaring model, plus
  // the instantiation frame (NIL_INST for none) its declared type must be
  // SubstX'd through — the same triple FindMemberX answers for one name.
  TPasMemberEnumProc = reference to procedure(AMid, ASym, ACtx: Integer);

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
    // Every FURTHER identity of the extended type: the plain-alias chain
    // behind TargetUnit/TargetSym (`Winapi.Windows.TRect = System.Types
    // .TRect`). One type, several symbols, and which one a VALUE carries
    // depends on the unit its declaration was read in — so the helper is
    // indexed under all of them. See Publish.
    Aliases: TArray<TPasExtRef>;
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
    // Reusable preprocessors for the parallel load/declared passes: Process
    // fully resets per-run state, so a returned instance is as good as a
    // fresh one — without paying ~20 container allocations per FILE.
    FPPPool: TList<TPasPreprocessor>;
    FPPPoolLock: TCriticalSection;
    // A model that exists only to hold the seeded compiler-provided names, so
    // SeedDeclaredQuery can answer before any real unit is loaded. Same
    // SeedSystemScope call as every other model, so the two cannot drift.
    FSeedModel: TPasSemaModel;
    FSeedScope: Integer;
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
    // Lowered names of the work-list nodes, parallel to FInhWork/FWithWork —
    // computed ONCE in EnsureCrossWork's single scan. The with pass re-reads
    // its list on EVERY fixpoint round (up to 8), and each NodeNameLower was
    // an allocation; a cached name is a refcount bump. Same lifetime and
    // reset as the lists themselves.
    FInhWorkNames: TArray<TArray<string>>;
    FWithWorkNames: TArray<TArray<string>>;
    FWorkBuilt: TArray<Boolean>;
    { Declaration-site idents CrossResolve could bind NOWHERE — see
      CrossResolveDecl. Filled by the CrossResolve workers (own slot only,
      count-tracked doubling — the filled prefix is FDeclWorkCount[mid], the
      array carries capacity slack), drained by the decl pass. }
    FDeclWork: TArray<TArray<Integer>>;
    FDeclWorkCount: TArray<Integer>;
    { Per-model overlay of the member references CrossType discovers, so the
      parallel walks never mutate a dictionary another walk is reading — see
      RunCrossTypePass. Owned here; merged and freed there. }
    FXNewExt: TArray<TDictionary<Integer, TPasExtRef>>;
    FSingleThreaded: Boolean;
    // Pass failures that had no model to hang off — see NoteInternalError.
    // The lock also guards AddDiag on a shared model from a parallel body.
    FInternalDiags: TArray<string>;
    FInternalLock: TObject;
    FReportMembers: Boolean;   // see ReportUnresolvedMembers
    FReportGuessedIfs: Boolean;   // see ReportGuessedIfs
    FReportVisibility: Boolean;   // see ReportVisibility
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
    FInstKeys: TDictionary<TSemaInstance, Integer>;
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
    // The cancellation predicate of the CURRENT AnalyzeStaged run, nil
    // otherwise. Set/cleared by AnalyzeStaged only; read by ForEachIndex so a
    // cancel lands MID-PASS instead of waiting for a whole cross pass to
    // finish (seconds on a big project — the LSP server cancels on every
    // keystroke). Skipped iterations leave their slots at the pass's own
    // "this unit failed" default (nil), which every commit loop already
    // tolerates; the driver then exits at its next between-pass check, and
    // the host discards a cancelled project wholesale.
    FCancelCheck: TFunc<Boolean>;
    function CancelRequested: Boolean; inline;
    // Runs ABody for 0..AHi — one worker per core, or a plain loop when
    // SingleThreaded (baseline emulation / timing comparison / debugging).
    // Stops early (remaining iterations become no-ops) when the current
    // staged run has been cancelled — see FCancelCheck.
    procedure ForEachIndex(AHi: Integer; const APass: string;
      const ABody: TProc<Integer>;
      const AMidOf: TFunc<Integer, Integer> = nil);
    procedure NoteInternalError(AMid: Integer; const APass: string;
      E: Exception); overload;
    procedure NoteInternalError(AMid: Integer; const APass, AClassName,
      AMessage: string); overload;
    // Appends a model + its initial status, keeping FModels/FFiles/FStatus in
    // lockstep. Returns the new model id.
    function RegisterModel(AModel: TPasSemaModel; const AFullPath: string;
      AStatus: TPasModuleStatus): Integer;
    procedure SetModuleStatus(AId: Integer; AStatus: TPasModuleStatus);
    // Bumps every currently loaded model to at least msCrossReady (called by
    // the synchronous drivers once their cross passes have completed).
    procedure MarkAllCrossReady;
    procedure TrimAllDiags;
    procedure ReleaseCrossWork;
    function RentPP: TPasPreprocessor;
    procedure ReturnPP(APP: TPasPreprocessor);
    function LoadFile(const APath: string): Integer;
    procedure LoadFilesParallel(const APaths: TArray<string>;
      AInterfaceOnly: Boolean = False);
    // Continuous closure loader — see the implementation. Returns False when
    // the run was cancelled part-way (committed models stay published).
    function RunLoadEngine(const ASeedLoads: TArray<string>;
      const ASeedUpgrades: TArray<Integer>; AIntfLoads: Boolean;
      const AAfterCommits: TProc): Boolean;
    // RunLoadEngine's worker computes — a method, not a nested routine,
    // because the worker is an anonymous method and cannot capture one.
    function ComputeLoad(const APath: string; AIntf: Boolean;
      out AErrClass, AErrMsg: string): TPasSemaModel;
    function ComputeUpgrade(const ASource: TPasPreprocessed;
      out AErrClass, AErrMsg: string): TPasSemaModel;
    procedure RegisterUnitName(AId: Integer);
    function LoadedUnitByName(const AName: string): Integer;
    procedure ResolveUses(AId: Integer);
    function SeedDeclaredQuery: TPasDeclaredQuery;
    function DeclaredQueryFor(AId: Integer): TPasDeclaredQuery;
    procedure RunDeclaredPass(ACount: Integer);
    procedure InjectGuessedIfDiags(ACount: Integer);
    procedure InjectEncodingDiags(ACount: Integer);
    procedure CrossResolve(AId: Integer);
    procedure CheckVisibility(AId, ANameNode, AMemMid, AMemSym: Integer);
    function StructEncloses(AMid, AOuter, AInner: Integer): Boolean;
    procedure RepointCallee(AModel: TPasSemaModel;
      ACalleeNode, AMid, ASym: Integer;
      ANewExt: TDictionary<Integer, TPasExtRef>);
    procedure RunVisibilityPass(AId: Integer);
    function InPropertySpecifier(AModel: TPasSemaModel; ANode: Integer): Boolean;
    function OuterStructsOfNode(AModel: TPasSemaModel;
      ANode, AInnermost: Integer): TArray<Integer>;
    // `with` over a target whose TYPE lives in another unit (ch.05 §5.7) —
    // see FindInEnclosingWith.
    function AllParamsDefaulted(AMid, AParams: Integer): Boolean;
    function PointeeOfDeclX(AId, ABaseNode: Integer): TSemaXType;
    function IsDefaultArrayProp(AMid, ASym: Integer): Boolean;
    function DefaultArrayPropX(const AX: TSemaXType;
      out AMid, ASym: Integer; out AOwner: TSemaXType): Boolean;
    function RoutineHasParams(AMid, ASym: Integer): Boolean;
    function ParamlessOverloadX(const AX: TSemaXType;
      const ANameLower: string; out AMid, ASym, ACtx: Integer): Boolean;
    function ElementX(AId, ABaseNode: Integer): TSemaXType;
    function InlineVarInitTypeX(AMid, ASym, ADepth: Integer): TSemaXType;
    function InsideWithBody(AModel: TPasSemaModel; ANode: Integer): Boolean;
    function InsideLaterWithTarget(AModel: TPasSemaModel;
      ANode: Integer): Boolean;
    procedure CrossResolveInherited(AId: Integer;
      var APending: TArray<TPasInhPending>);
    procedure EnsureCrossWork(AId: Integer);
    procedure SizeCrossWork(ACount: Integer);
    procedure PrepareDeclWork(ACount: Integer);
    procedure CrossResolveDecl(AId: Integer;
      var APending: TArray<TPasInhPending>; AEmit: Boolean);
    procedure RunDeclPass(ACount: Integer);
    procedure RunInheritedPass(ACount: Integer);
    { AEmit=False computes bindings only and RECORDS the still-unresolved
      candidates in AUnresolved; when a round turns out to be the converged
      one (no new bindings anywhere), RunWithPass emits E2003 from that list
      directly instead of paying one more full round to rediscover it. AEmit
      is the round-cap fallback only. }
    procedure CrossResolveWith(AId: Integer;
      var APending: TArray<TPasInhPending>; AEmit: Boolean;
      var AUnresolved: TArray<Integer>);
    procedure RunWithPass(ACount: Integer);
    function ArityOfTypeSym(AMid, ASym: Integer): Integer;
    function FindTypeInSelfArity(AId: Integer; const ANameLower: string;
      AArity: Integer; out ASym: Integer): Boolean;
    function FindTypeInUsesArity(AId: Integer; const ANameLower: string;
      AArity: Integer; out AUnit, ASym: Integer): Boolean;
    function WrittenArityOfRef(AModel: TPasSemaModel;
      ANode: Integer): Integer;
    procedure FixCrossArity(AId: Integer; AModel: TPasSemaModel;
      ANode: Integer; const ANameLower: string; var AUnit, ASym: Integer);
    function IsAttributeTypeRef(AModel: TPasSemaModel; ANode: Integer): Boolean;
    function UsesUnitOf(AId, ASym: Integer): Integer;
    function LocalHead(AModel: TPasSemaModel; ANode: Integer): Integer;
    function QualifiedText(AId, ANode: Integer): string;
    function UnitNameOf(AId, ANode: Integer): Integer;
    procedure EmitE2003(AModel: TPasSemaModel; ANode: Integer);
    procedure EmitAt(AModel: TPasSemaModel; ANode: Integer;
      const ACode, AMsg: string);
    function CalleeShadowsUses(AModel: TPasSemaModel;
      ACallee, ALocalSym: Integer): Boolean;
    procedure CheckCalls(AId: Integer);
    // Phase 3c: cross-model typing.
    function InstanceRead(AInst: Integer): TSemaInstance;
    function TypeDefNodeOf(AMid, ASym: Integer): Integer;
    function GenericParamIdents(AMid, ASym: Integer): TArray<Integer>;
    function GenericParamConstraints(AMid,
      ASym: Integer): TArray<TArray<Integer>>;
    function RealGenericBase(const AX: TSemaXType): TSemaXType;
    function ConstraintsOfParamX(
      const AParam: TSemaXType): TArray<TSemaXType>;
    function RoutineNameOfParam(AMid, ANode: Integer): string;
    procedure CheckConstraints(AId: Integer);
    function ResolveCustomAttributeX(AId: Integer): TSemaXType;
    procedure CheckAttributes(AId: Integer);
    function RecordHasLifecycleOp(AMid, ADefNode: Integer): Boolean;
    function OracleResolve(AId: Integer; const ANameLower: string;
      out AMid, ASym: Integer): Boolean;
    function OracleConstVal(AMid, ASym, ADepth: Integer;
      out AValue: TPasSymbolValue): Boolean;
    function OracleConstNum(AMid, ASym, ADepth: Integer;
      out ANum: Double): Boolean;
    function OracleQualified(AId: Integer; const AName: string;
      out AMid, ASym: Integer): Boolean;
    function OracleSizeOf(AMid, ASym, ADepth: Integer;
      out ABytes: Double): Boolean;
    function OracleLayout(AMid, ASym, ADepth: Integer; const ASubst: TPasSubst;
      out ABytes: Double; out AAlign: Integer): Boolean;
    function OracleFieldLayout(AMid, ATypeNode, ADepth: Integer;
      const ASubst: TPasSubst; out ABytes: Double;
      out AAlign: Integer): Boolean;
    function OracleRecordLayout(AMid, ADefNode, ADepth: Integer;
      const ASubst: TPasSubst; AStart, AStartAlign: Integer;
      out ABytes: Double; out AAlign: Integer): Boolean;
    function OracleArrayLayout(AMid, ADefNode, ADepth: Integer;
      const ASubst: TPasSubst; out ABytes: Double;
      out AAlign: Integer): Boolean;
    function OracleConstExpr(AMid, ANode, ADepth: Integer;
      out ANum: Double): Boolean;
    function OracleOrdinalCount(AMid, ANode, ADepth: Integer;
      out ACount: Double): Boolean;
    function OracleOrdinalRange(AMid, ANode, ADepth: Integer;
      out ALo, AHi: Double): Boolean;
    function OracleEnumRange(AMid, ADefNode, ADepth: Integer;
      out ALo, AHi: Double): Boolean;
    function OracleEnumLayout(AMid, ADefNode, ADepth: Integer;
      out ABytes: Double; out AAlign: Integer): Boolean;
    function OracleVariantLayout(AMid, APartNode, ADepth, ACap,
      AStart: Integer; const ASubst: TPasSubst;
      out AEnd, AAlign: Integer): Boolean;
    function OracleObjectLayout(AMid, ADefNode, ADepth: Integer;
      const ASubst: TPasSubst; out ABytes: Double;
      out AAlign: Integer): Boolean;
    function OracleObjectHasVmt(AMid, ADefNode, ADepth: Integer): Boolean;
    function OracleGenericLayout(AMid, AArgsNode, ADepth: Integer;
      const ASubst: TPasSubst; out ABytes: Double;
      out AAlign: Integer): Boolean;
    function OracleLength(AMid, ASym: Integer; out ALen: Double): Boolean;
    function SymbolQueryFor(AId: Integer): TPasCondSymbolQuery;
    function DeclaredWithinX(AMid, ASym, AOwnerMid, AOwnerSym: Integer): Boolean;
    function PreferNonGeneric(AId, AMid, ASym,
      ANameNode: Integer): TSemaXType;
    function TypeSlotByNameX(AMid, ANode: Integer): TSemaXType;
    function IsGenericTypeSym(AMid, ASym: Integer): Boolean;
    function ClassRefTargetX(const AX: TSemaXType): TSemaXType;
    function IsDynArrayTypeX(const AX: TSemaXType): Boolean;
    function ResolveTypeExprNested(AId, ANode: Integer;
      ADepth: Integer = 0): TSemaXType;
    procedure BuildHelperMap;
    // BuildHelperMap's phase-B publisher — a method because the parallel
    // phase-B worker is an anonymous method and cannot capture a nested one.
    procedure PublishHelper(AMid: Integer; const AReg: TPasHelperReg);
    procedure ClearHelperIdx;
    function HelperAncestorX(AMid, ASym: Integer): TSemaXType;
    function HelperMemberHit(AFromMid: Integer; const ACur: TSemaXType;
      const ANameLower: string; out AMemMid, AMemSym: Integer): Boolean;
    // Cross-model overload selection (CrossType's call typing):
    function XCatOf(const AX: TSemaXType): TSemaTypeCat;
    function CanonTypeX(const AX: TSemaXType): TSemaXType;
    function XSameType(const A, B: TSemaXType): Boolean;
    function XAssignableX(const ADst, ASrc: TSemaXType): Boolean;
    function InferMethodFrame(AMid, ASym: Integer;
      const AArgTypes: TArray<TSemaXType>; ACtx: Integer): Integer;
    function ExplicitMethodFrame(AId, AMid, ASym, ATypeArgs,
      ACtx: Integer): Integer;
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
    { OPT-IN diagnostic, default OFF: report a member after a dot that no
      lookup could resolve, as `E2003` on the member's own name. dcc reports
      such a name and we do not, so this is a real gap — but the member walk
      keeps gaining branches (the audit found the `IInterface` hole exactly
      here), and a FALSE E2003 on a member is worse than a missing one, so it
      stays behind this switch until a corpus run says otherwise. What that run
      says today is in the README; the point of the flag is that anyone can
      repeat it. }
    property ReportUnresolvedMembers: Boolean read FReportMembers
      write FReportMembers;
    { OPT-IN, default OFF: surface every `$IF`/`$ELSEIF` whose branch still
      rests on a GUESS after the second pass (code PPIF), and every
      conditional expression that did not parse at all (PPBAD) — as ordinary
      model diagnostics, so they flow through -list, the histograms and the
      demo with no new plumbing. The exotica detector for foreign projects:
      the message carries the expression text verbatim. NB a Declared(X)-only
      guard whose name is declared NOWHERE is a CONFIRMED-correct guess (the
      second pass checked and skipped the re-run) yet still listed — the
      expression text makes those easy to eyeball, and hiding them would also
      hide a misspelled name that WAS meant to exist. Off, the analysis is
      byte-identical. }
    property ReportGuessedIfs: Boolean read FReportGuessedIfs
      write FReportGuessedIfs;
    { OPT-IN, default OFF: enforce member VISIBILITY on a QUALIFIED access —
      `E2361 Cannot access private symbol TType.Member` (11 §11.2.1). Recording
      landed first and deliberately; this is the enforcement half, and it is the
      only check here that can reject code the corpora currently ACCEPT for a
      reason other than a missing check, which is why it is a switch and not a
      default. What it covers and what it does not is in the README. }
    property ReportVisibility: Boolean read FReportVisibility
      write FReportVisibility;
    { Editor-host buffer override: analysis reads AText for APath instead of
      the file on disk (for unsaved editor content). Call BEFORE AnalyzeFile/
      AnalyzeDirectory — LoadFile reads at analysis time. AVersion is the
      host's version stamp for the document, readable back via BufferVersion
      once the analysis is done — so an async host can tell a result computed
      from the CURRENT text apart from one computed from an older keystroke. }
    procedure SetBuffer(const APath, AText: string; AVersion: Integer = 0);
    { The version SetBuffer stored for APath, or -1 when APath has no
      overlay (analysis read it from disk). }
    function BufferVersion(const APath: string): Integer;
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
    { ---- editor-feature query surface -------------------------------------
      Pure lookups promoted UNCHANGED from the private resolution machinery,
      so engines outside this unit (PasTree.Sema.Complete, PasTree.Sema.Nav)
      reuse the real walks instead of re-deriving them. All of them read the
      analyzed models and mutate no model state (the lazy System/SysInit
      loading some reach through is the same one EnsureSystemUnit above
      already exposes). Grouped, not scattered, so the line between "the
      analysis" and "what editors may ask of it" stays visible. }
    // The innermost struct type symbol whose scope chain holds ANode — the
    // `Self` context of a position (a method body's routine scope carries it,
    // and so does a struct declaration's own member scope).
    function StructSymOfNode(AModel: TPasSemaModel; ANode: Integer): Integer;
    // Every struct DECLARATION lexically enclosing ANode, innermost first —
    // the "declared inside" half of a visibility decision.
    function DeclStructsOfNode(AModel: TPasSemaModel;
      ANode: Integer): TArray<Integer>;
    // The (model, symbol) a designator node names, when one does.
    function DesignatorSymX(AId, ANode: Integer;
      out AMid, ASym: Integer): Boolean;
    function AncestorOfX(const AX: TSemaXType): TSemaXType;
    { The single answer to "what type is this member?" — see the implementation
      for why a bare property redeclaration makes it necessary. }
    function SymDeclTypeX(AMid, ASym: Integer): TSemaXType;
    { The type of an arbitrary designator NODE, computed on demand — written
      for `with` targets (hence the name) but structurally general: parens,
      derefs, indexing, as-casts, calls, `inherited`, `Self`, members. }
    function WithTargetTypeX(AId, ANode: Integer): TSemaXType;
    function FindInEnclosingWith(AId, ANode: Integer;
      const ANameLower: string; out AUid, ASym: Integer;
      out AX: TSemaXType): Boolean;
    // The cross-unit halves of unqualified name resolution, in the priority
    // order CrossResolve itself uses: uses (last-wins) -> System -> SysInit.
    function FindInUses(AId: Integer; const ANameLower: string;
      out AUnit, ASym: Integer): Boolean;
    function FindInSystemUnit(const ANameLower: string;
      out AUnit, ASym: Integer): Boolean;
    function FindInSysInitUnit(const ANameLower: string;
      out AUnit, ASym: Integer): Boolean;
    function RoutineArity(AMid, ASym: Integer; out AReq, ATot: Integer;
      out AVariadic: Boolean): Boolean;
    function XDescendsFrom(const ADesc, ABase: TSemaXType): Boolean;
    function DeclTypeX(AMid, ASym: Integer): TSemaXType;
    function SubstX(const AX: TSemaXType; AInst, ADepth: Integer): TSemaXType;
    function ResolveTypeExpr(AId, ANode: Integer;
      ABare: Boolean = True): TSemaXType;
    { ADepth guards the CONSTRAINT hop, which is the one place this function
      re-enters itself: a type parameter may carry several constraints and the
      member may be on ANY of them (16 §16.4.1), so each is walked in turn. }
    function FindMemberX(AFromMid: Integer; const ABase: TSemaXType;
      const ANameLower: string;
      out AMemMid, AMemSym: Integer; out ACtx: Integer;
      ADepth: Integer = 0): Boolean;
    function IsConstructorSym(AMid, ASym: Integer): Boolean;
    function IsClassCtorDtorSym(AMid, ASym: Integer): Boolean;
    function XParamSyms(AMid, ASym: Integer): TArray<Integer>;
    function PointeeX(const AX: TSemaXType): TSemaXType;
    function ProcResultX(const AX: TSemaXType): TSemaXType;
    { Dedup-registers one generic instantiation and returns its instance-table
      index (locked, callable from anywhere). Promoted for the completion
      engine: a buffer being typed declares instantiations the analysis has
      not seen yet (`var G: TQueue<TFoo>; G.`), and dedup means an already-
      known frame comes back as the SAME index the project uses. }
    function Instantiate(const ABase: TSemaXType;
      const AArgs: TArray<TSemaXType>): Integer;
    { The ENUMERATING twin of FindMemberX, for completion: reports EVERY
      member reachable from ABase, walking the same hops in the same order —
      active helper (and its ancestor helpers) first, then each type's own
      member scope, then the alias / pointer-deref / paramless-proc-result /
      `class of` / heritage / implicit-root hops, closing each hop over its
      instantiation frame; a generic parameter enumerates its constraints'
      members. Class constructors/destructors are skipped (never nameable).
      Members are reported ancestor-visited-later, and overridden names
      recur — a caller deduplicating by NameLower and keeping the FIRST hit
      reproduces FindMemberX's precedence, exactly like EnumScopeDeep's
      contract mirrors FindLocalDeep's. }
    procedure EnumMembersX(AFromMid: Integer; const ABase: TSemaXType;
      const AOnMember: TPasMemberEnumProc; ADepth: Integer = 0);
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
    { Every unit name the project's search paths can reach — completion's
      uses-clause candidates beyond the analyzed closure. Delegates to the
      source manager's cached scan (see its contract). }
    function SearchPathUnitNames: TArray<string>;
    { The `///` doc-comment block above a symbol's declaration (completion
      plan §8D, Help Insight) — TPasTree.DeclDocComment over the symbol's
      DeclNode. '' for builtins (no source), unknown ids, and undocumented
      declarations. The hover path's entry: navigation hands out (Mid, Sym)
      pairs, and this is the step from one to its documentation. }
    function SymDocComment(AMid, ASym: Integer): string;
    { 20.3.1 — is AX one of the compiler-MANAGED types (automatic init/
      finalize/copy: long strings, dynamic arrays, interfaces, Variant,
      `reference to` procedural types, and records that either declare a
      lifecycle operator or transitively contain a managed field)? A pure
      query, exposed publicly (like XCatOf/XTypeText's own callers use them)
      rather than tied to a diagnostic — the spec itself frames this as a
      type-system question a type-checker computes, not a rule dcc enforces
      or warns about (probed: dcc32 37.0 gives no diagnostic at all for
      GetMem/FreeMem of a managed-field record, so THAT is not a real check
      to add). ADepth guards the record-field/static-array recursion the
      same way every other cross-model walk in this file caps itself. }
    function IsManagedTypeX(const AX: TSemaXType; ADepth: Integer = 0): Boolean;
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

{ TSemaXType value helpers, promoted with the query surface above: the null
  value, its test, and a plain (uninstantiated) wrapper — so a caller of
  FindMemberX/WithTargetTypeX can build and test the record without knowing
  its field conventions. }
function XNil: TSemaXType;
function XValid(const AX: TSemaXType): Boolean;
function XPlain(AMid, ASym: Integer): TSemaXType;

implementation

uses
  System.IOUtils,
  System.Threading,
  System.Diagnostics,
  System.Math,
  System.Generics.Defaults,
  PasTree.Parser,
  PasTree.CondEval,
  PasTree.Sema.Builtins,
  PasTree.Sema.Resolver,
  PasTree.Sema.Diagnostics;

type
  { Structural equality for the instantiation-dedup dictionary: the instance
    record IS the key, hashed and compared as integers. Replaces a
    `Format('%d:%d') + per-arg concat` string key that allocated 2–5 strings
    per call — 77k calls per corpus run, under the instance lock. }
  TSemaInstanceComparer = class(TEqualityComparer<TSemaInstance>)
  public
    function Equals(const Left, Right: TSemaInstance): Boolean;
      overload; override;
    function GetHashCode(const Value: TSemaInstance): Integer;
      overload; override;
  end;

var
  // Process-wide, set once — see TPasSemaProject.ConfigureThreadPool.
  GPoolConfigured: Boolean = False;
  // Shared stateless comparer (interface-refcounted; see initialization).
  GInstanceComparer: IEqualityComparer<TSemaInstance>;

function TSemaInstanceComparer.Equals(const Left,
  Right: TSemaInstance): Boolean;
var
  LIdx: Integer;
begin
  if (Left.UnitId <> Right.UnitId) or (Left.Sym <> Right.Sym) or
     (Length(Left.Args) <> Length(Right.Args)) then
    Exit(False);
  for LIdx := 0 to High(Left.Args) do
    if (Left.Args[LIdx].UnitId <> Right.Args[LIdx].UnitId) or
       (Left.Args[LIdx].Sym <> Right.Args[LIdx].Sym) or
       (Left.Args[LIdx].Inst <> Right.Args[LIdx].Inst) then
      Exit(False);
  Result := True;
end;

function TSemaInstanceComparer.GetHashCode(const Value: TSemaInstance): Integer;
var
  LIdx: Integer;
  LHash: Cardinal;

  procedure Mix(AVal: Integer);
  begin
    // FNV-1a over the record's integers, byte-for-byte equivalent mixing.
    LHash := (LHash xor Cardinal(AVal)) * 16777619;
  end;

begin
  LHash := 2166136261;
  Mix(Value.UnitId);
  Mix(Value.Sym);
  for LIdx := 0 to High(Value.Args) do
  begin
    Mix(Value.Args[LIdx].UnitId);
    Mix(Value.Args[LIdx].Sym);
    Mix(Value.Args[LIdx].Inst);
  end;
  Result := Integer(LHash);
end;

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
  time. NB that table was measured while the pin LEAKED (see the
  UnlimitedWorkerThreadsWhenBlocked note below): "16" really meant 16 pinned
  plus an unbounded injected tail, which is what made wide look pathological.
  With the cap actually holding, re-measured on the 3757-unit client corpus:

    workers   wall     CPU
    8         10.6 s   49 s
    12        10.7 s   59 s
    16 (=CPUs) 9.5 s   65 s

  Logical-core width now wins the clock (the extra CPU is MM spin, bounded),
  so 0 selects CPUCount. A host that prefers CPU-efficiency over wall time —
  a background LSP, say — passes its own width instead.

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
    LWant := Max(2, CPUCount);
  // Min first: Max refuses anything below the current Min.
  TThreadPool.Default.SetMinWorkerThreads(LWant);
  TThreadPool.Default.SetMaxWorkerThreads(LWant);
  // Without this the Min=Max pin does not actually hold: the pool's monitor
  // thread injects threads PAST Max whenever the queue is non-empty, no
  // worker is idle and process CPU usage is "low" — and on a machine with
  // more logical cores than workers, a fully busy pinned pool IS "low"
  // (8 busy of 16 logical = 50%). Measured on the 3757-unit client corpus:
  // the pool grew 8 -> ~38 threads within the first two seconds, the extras
  // then took part in every later pass, and the run burned 85 s CPU against
  // the single-thread run's 38 s — the very MM-spin spiral the pin above was
  // measured to prevent. The trade: past-Max injection is also the pool's
  // deadlock escape for tasks that BLOCK on other queued tasks, so no task
  // scheduled on the default pool may wait on another queued task. The
  // analyzer's passes never do (fork-join only, joins on the caller).
  TThreadPool.Default.UnlimitedWorkerThreadsWhenBlocked := False;
end;

constructor TPasSemaProject.Create(APlatform: TPasPlatform;
  const ASearchPaths: TArray<string>; const AExtraDefines: TArray<string>);
var
  LName: string;
begin
  inherited Create;
  ConfigureThreadPool(0);
  FInternalLock := TObject.Create;
  FPlatform := APlatform;
  FInfo := PlatformInfo(APlatform);
  FSM := TPasSourceManager.Create(ASearchPaths);
  FDefines := CreatePlatformDefines(APlatform);
  for LName in AExtraDefines do
    FDefines.Define(LName);
  FPP := TPasPreprocessor.Create(FSM, FDefines, 37.0, FInfo.PointerBytes,
    FInfo.ExtendedBytes);
  FPPPool := TList<TPasPreprocessor>.Create;
  FPPPoolLock := TCriticalSection.Create;
  FSeedModel := TPasSemaModel.Create(Default(TPasTree));
  FSeedScope := SeedSystemScope(FSeedModel, APlatform);
  FModels := TObjectList<TPasSemaModel>.Create(True);
  FFiles := TList<string>.Create;
  FStatus := TList<TPasModuleStatus>.Create;
  FByPath := TDictionary<string, Integer>.Create;
  FInstances := TList<TSemaInstance>.Create;
  FInstKeys := TDictionary<TSemaInstance, Integer>.Create(GInstanceComparer);
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
  FInternalLock.Free;
  FFiles.Free;
  FStatus.Free;
  FModels.Free;
  for var LPP in FPPPool do
    LPP.Free;
  FPPPool.Free;
  FPPPoolLock.Free;
  FPP.Free;
  FSeedModel.Free;
  FDefines.Free;
  FSM.Free;
  inherited;
end;

{ Every parallel pass runs through here, so this is where the safety net goes:
  an exception escaping a pass body is recorded as a PPINT diagnostic on the
  unit it was working on and the run CONTINUES.

  Without it the failure is invisible in the worst possible way — the unit ends
  up half-analyzed, so the names it should declare are missing and its
  importers report a flood of "undeclared identifier" that points everywhere
  except at the cause. (An unhandled exception in a TParallel body also
  re-raises out of the whole &For, which loses every other worker's result.)

  APass names the pass for the message. AMidOf maps a body index to the model
  it belongs to: for most passes that is the index itself, but the
  candidate-driven ones iterate a subset and must map back, or the report
  would blame an unrelated unit. }
procedure TPasSemaProject.ForEachIndex(AHi: Integer; const APass: string;
  const ABody: TProc<Integer>; const AMidOf: TFunc<Integer, Integer>);
var
  LIdx: Integer;
  LRun: TProc<Integer>;
begin
  // An anonymous method, not a nested procedure: TParallel.&For takes a
  // TProc<Integer> and a nested one cannot be captured (E2555).
  LRun :=
    procedure(AIndex: Integer)
    var
      LMid: Integer;
    begin
      // A cancelled run turns the rest of the pass into no-ops. Cheaper and
      // safer than TParallel's LoopState.Stop: no overload gymnastics, and
      // the already-running bodies still finish and commit normally.
      if CancelRequested then
        Exit;
      try
        ABody(AIndex);
      except
        on E: Exception do
        begin
          if Assigned(AMidOf) then
            LMid := AMidOf(AIndex)
          else
            LMid := AIndex;
          NoteInternalError(LMid, APass, E);
        end;
      end;
    end;
  if FSingleThreaded then
  begin
    for LIdx := 0 to AHi do
    begin
      if CancelRequested then
        Break;
      LRun(LIdx);
    end;
  end
  else
    TParallel.&For(0, AHi, LRun);
end;

function TPasSemaProject.CancelRequested: Boolean;
begin
  Result := Assigned(FCancelCheck) and FCancelCheck();
end;

{ Records a pass failure against AMid. Anchored on the unit's ROOT node, which
  every model has, so the host gets a file and a line rather than nothing. If
  the model itself is missing — the failure happened while building it — the
  note goes to the project-level list, which the report prints alongside. }
procedure TPasSemaProject.NoteInternalError(AMid: Integer; const APass: string;
  E: Exception);
begin
  NoteInternalError(AMid, APass, E.ClassName, E.Message);
end;

procedure TPasSemaProject.NoteInternalError(AMid: Integer; const APass,
  AClassName, AMessage: string);
var
  LMsg: string;
begin
  LMsg := Format(SPPINT_PassFailed, [APass, AClassName, AMessage]);
  TMonitor.Enter(FInternalLock);
  try
    if (AMid >= 0) and (AMid < FModels.Count) and (FModels[AMid] <> nil) and
       (FModels[AMid].Tree.Nodes <> nil) then
      FModels[AMid].AddDiag(MakeDiag('PPINT', LMsg, 0, 0, 0, 0))
    else
      FInternalDiags := FInternalDiags + [LMsg];
  finally
    TMonitor.Exit(FInternalLock);
  end;
end;

procedure TPasSemaProject.SetBuffer(const APath, AText: string;
  AVersion: Integer);
begin
  FSM.SetBuffer(APath, AText, AVersion);
end;

function TPasSemaProject.BufferVersion(const APath: string): Integer;
begin
  Result := FSM.BufferVersion(APath);
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

function TPasSemaProject.SearchPathUnitNames: TArray<string>;
begin
  Result := FSM.SearchPathUnitNames;
end;

function TPasSemaProject.SymDocComment(AMid, ASym: Integer): string;
var
  LM: TPasSemaModel;
begin
  Result := '';
  if (AMid < 0) or (AMid >= FModels.Count) then
    Exit;
  LM := FModels[AMid];
  if (LM = nil) or (ASym < 0) or (ASym >= LM.SymCount) then
    Exit;
  Result := LM.Tree.DeclDocComment(LM.Symbols[ASym].DeclNode);
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
    FPP.OnDeclared := SeedDeclaredQuery();
    LPre := FPP.Process(LFull);
    LTree := TPasParser.ParseFile(LPre, LDiags);
    LModel := TPasSemaResolver.Analyze(LTree, False, FPlatform);
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

{ The FIRST-pass answer: compiler-provided names only, so it needs no models
  and can run while units are still being loaded, in parallel, before anything
  is linked.

  Only a POSITIVE is definitive. A seeded name is in scope everywhere, so True
  is final; a name the seed does not have may still come from an import, so
  that case answers "do not know" and the name is recorded for the second pass.

  This is what keeps the second pass small, and the effect is not marginal: a
  `$IF DECLARED(AnsiChar)` guard in the platform header unit and one over
  `UInt64` in a compatibility unit are the two commonest spellings, and the
  units carrying them are among the largest in the RTL. Answering them here
  took the second pass from 7 units to 2 on the 665-unit corpus, and with it a
  +4% regression down to noise. }
function TPasSemaProject.SeedDeclaredQuery: TPasDeclaredQuery;
begin
  Result :=
    function(const AName: string; out ADeclared: Boolean): Boolean
    begin
      ADeclared := FSeedModel.FindLocal(FSeedScope, LowerCase(AName)) <> NIL_SYM;
      Result := ADeclared;
    end;
end;

{ Answers a `$IF Declared(X)` guard on behalf of unit AId.

  Deliberately NOT the unit's own declarations, only what it can see from
  outside: its own imports, the implicit System and SysInit units, and the
  compiler-provided seed. Including the unit's own scope would make the answer
  depend on the branch the previous pass took, which is exactly what this pass
  is re-deciding — `TSomething = QWord` inside the guarded text would report
  TSomething as declared, flip the branch, remove the declaration, and the two
  readings would trade places forever.

  The seed is consulted through SystemScope rather than InterfaceScope for the
  same reason: InterfaceScope JOINS the seed, so asking it would drag the
  unit's own names back in. And each lookup rejects a hit in AId itself, which
  is how System.pas asking `Declared(RTLVersion132)` about its OWN const stops
  being self-referential — FindInSystemUnit reaches exactly that scope. }
function TPasSemaProject.DeclaredQueryFor(AId: Integer): TPasDeclaredQuery;
begin
  Result :=
    function(const AName: string; out ADeclared: Boolean): Boolean
    var
      LLower: string;
      LUid, LSym: Integer;
    begin
      LLower := LowerCase(AName);
      ADeclared :=
        (FindInUses(AId, LLower, LUid, LSym) and (LUid <> AId)) or
        (FindInSystemUnit(LLower, LUid, LSym) and (LUid <> AId)) or
        (FindInSysInitUnit(LLower, LUid, LSym) and (LUid <> AId)) or
        ((FModels[AId].SystemScope <> NIL_SCOPE) and
         (FModels[AId].Resolve(FModels[AId].SystemScope, LLower) <> NIL_SYM));
      Result := True;   // this one always has an answer
    end;
end;

{ The `$IF` symbol oracle (const values / SizeOf / Length — see
  TPasCondSymbolQuery), RunDeclaredPass's second half. Unlike DeclaredQueryFor
  it DOES answer from the asking unit's own model: a constant's VALUE cannot
  self-fulfil the way a Declared() guard around a fallback declaration can
  (the value exists whichever branch the $IF takes), and same-unit
  declarations are exactly what the measured RTL sites reference
  (System.VarUtils' Generic* consts, System.Classes' TValueType, System.pas'
  RegisteredTypeInfoTable). Two documented approximations, both inherited
  from the pass's one-round design: declarations are read from the
  FIRST-pass model (a value whose own declaration sits inside a branch the
  second pass flips would be stale for that round), and position is not
  checked (dcc answers a $IF only from declarations ABOVE it; a $IF
  referencing a constant declared BELOW reads here as declared — code that
  fragile hits dcc's undeclared-abort quirk anyway and exists in no corpus).

  Everything is three-state and proof-or-refuse: an initializer that does not
  fold to a clean number/bool, an enum with explicit values, a record with
  mixed field sizes, a dotted name — all answer "cannot", which leaves the
  first-pass guess standing, exactly today's behavior. }

function TPasSemaProject.OracleResolve(AId: Integer; const ANameLower: string;
  out AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
  LScope, LIdx: Integer;
begin
  AMid := AId;
  ASym := NIL_SYM;
  LM := FModels[AId];
  // The unit's own scopes first: the implementation scope's parent chain
  // covers the interface and system scopes, so one Resolve from there sees
  // everything the unit itself declares.
  LScope := NIL_SCOPE;
  for LIdx := 0 to LM.Scopes.Count - 1 do
    if LM.Scopes[LIdx].Kind = sckImplementation then
    begin
      LScope := LIdx;
      Break;
    end;
  if LScope = NIL_SCOPE then
    LScope := LM.InterfaceScope;
  if LScope <> NIL_SCOPE then
  begin
    ASym := LM.Resolve(LScope, ANameLower);
    if ASym <> NIL_SYM then
      Exit(True);
  end;
  // Then the uses closure and the implicit System unit, the same route every
  // other cross-unit fallback takes (System.Rtti's SizeOf(TMethod) reaches
  // System.pas through here).
  Result := ResolveRealDecl(AId, ANameLower, AMid, ASym);
end;

// The recursive const-evaluation context: resolves further plain names in
// AMid as constants (GenericVariants = GenericVarUtils = False chains),
// depth-capped like every other walk in this file.
function TPasSemaProject.OracleConstVal(AMid, ASym, ADepth: Integer;
  out AValue: TPasSymbolValue): Boolean;
var
  LM: TPasSemaModel;
  LDecl, LParent, LChild, LInit: Integer;
  LCtx: TPasCondContext;
  LVal: TPasCondValue;
begin
  Result := False;
  AValue := Default(TPasSymbolValue);
  if ADepth > 8 then
    Exit;
  LM := FModels[AMid];
  if LM.Symbols[ASym].Kind <> skConst then
    Exit;
  LDecl := LM.Symbols[ASym].DeclNode;
  if LDecl = NIL_NODE then
    Exit;   // seeded consts (True/False/MaxInt) never reach here
  LParent := LM.Tree.Nodes[LDecl].Parent;
  if (LParent = NIL_NODE) or (LM.Tree.Nodes[LParent].Kind <> nkConstDecl) then
    Exit;
  // The initializer is the LAST expression-kind child: children are the name
  // ident, an optional type ref, the initializer, then optional nkDirective
  // hints — so "last expression child that is not child #0" is exactly it.
  LInit := NIL_NODE;
  LChild := LM.Tree.Nodes[LParent].FirstChild;
  if LChild <> NIL_NODE then
    LChild := LM.Tree.Nodes[LChild].NextSibling;   // never the name itself
  while LChild <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LChild].Kind in [nkIdent, nkMember, nkIntLit, nkRealLit,
       nkStrLit, nkUnaryOp, nkBinaryOp, nkParen, nkCall] then
      LInit := LChild;
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
  if LInit = NIL_NODE then
    Exit;
  LCtx := Default(TPasCondContext);
  LCtx.CompilerVersion := 37.0;
  LCtx.PointerBytes := FInfo.PointerBytes;
  LCtx.ExtendedBytes := FInfo.ExtendedBytes;
  LCtx.OnSymbol :=
    function(AQuery: TPasSymbolQuery; const AName: string;
      out AV: TPasSymbolValue): Boolean
    var
      LRMid, LRSym: Integer;
    begin
      // All three questions, not just the const one. A constant's initializer
      // routinely IS a size -- FastMM4's `SmallBlockPoolHeaderSize =
      // SizeOf(TSmallBlockPoolHeader)` -- and answering only sqConstValue here
      // meant the type sized fine while every constant derived from it stayed
      // a residual guess. Depth carries through, so a cyclic const still
      // terminates on the same cap.
      AV := Default(TPasSymbolValue);
      if not OracleQualified(AMid, AName, LRMid, LRSym) then
        Exit(False);
      case AQuery of
        sqConstValue:
          Result := OracleConstVal(LRMid, LRSym, ADepth + 1, AV);
        sqSizeOfType:
          Result := OracleSizeOf(LRMid, LRSym, ADepth + 1, AV.Num);
        sqLengthOf:
          Result := OracleLength(LRMid, LRSym, AV.Num);
      else
        Result := False;
      end;
    end;
  LVal := EvalCondNode(LM.Tree, LInit, LCtx);
  if LVal.Guessed then
    Exit;
  AValue.IsStr := LVal.Kind = cvStr;
  AValue.Str := LVal.Str;
  AValue.Num := CondAsNum(LVal);
  Result := True;
end;

// The numeric-only face of OracleConstVal, for the callers that need a bound
// or a size rather than a value (array lengths, enum ranges): a string
// constant is not an answer there, so it refuses rather than coercing.
function TPasSemaProject.OracleConstNum(AMid, ASym, ADepth: Integer;
  out ANum: Double): Boolean;
var
  LVal: TPasSymbolValue;
begin
  ANum := 0;
  Result := OracleConstVal(AMid, ASym, ADepth, LVal) and not LVal.IsStr;
  if Result then
    ANum := LVal.Num;
end;

{ Resolves a name that MAY be qualified. dcc resolves `Unit.Const` in a `$IF`
  exactly like a plain one (probed: a `$IF UConst.QC > 1` guard evaluates for
  real, and a known unit with an unknown member is a hard E2003, not a
  fallback), and the version-guard idiom in the wild writes it that way —
  `$IF IdGlobal.gsIdVersion > '10.6.2'`. Refusing dots turned every such guard
  into a residual guess.

  Only the LAST dot is split: the prefix is a unit name, which may itself be
  dotted (`Winapi.Windows.SomeConst`). The prefix is matched against the
  asking unit's imports, so an unrelated unit's constant cannot leak in. }
function TPasSemaProject.OracleQualified(AId: Integer; const AName: string;
  out AMid, ASym: Integer): Boolean;

  // `Winapi.Windows` is also referred to as `Windows`; match either spelling.
  function UnitNameMatches(const AFullLower, AWantedLower: string): Boolean;
  var
    LDot: Integer;
  begin
    if AFullLower = AWantedLower then
      Exit(True);
    LDot := AFullLower.LastIndexOf('.');
    Result := (LDot >= 0) and
      (Copy(AFullLower, LDot + 2, MaxInt) = AWantedLower);
  end;

var
  LDot, LIdx, LUid: Integer;
  LUnit, LMember: string;
begin
  LDot := AName.LastIndexOf('.');
  if LDot < 0 then
    Exit(OracleResolve(AId, LowerCase(AName), AMid, ASym));
  LUnit := Copy(AName, 1, LDot);
  LMember := Copy(AName, LDot + 2, MaxInt);
  if (LUnit = '') or (LMember = '') then
    Exit(False);
  LUnit := LowerCase(LUnit);
  LMember := LowerCase(LMember);
  AMid := NIL_SYM;
  ASym := NIL_SYM;
  // The asking unit may qualify with its OWN name.
  if SameText(FModels[AId].UnitNameLower, LUnit) then
  begin
    AMid := AId;
    ASym := FModels[AId].Resolve(FModels[AId].InterfaceScope, LMember);
    Exit(ASym <> NIL_SYM);
  end;
  for LIdx := High(FModels[AId].UsesList) downto 0 do
  begin
    LUid := FModels[AId].UsesList[LIdx].UnitId;
    if (LUid < 0) or (FModels[LUid].InterfaceScope = NIL_SCOPE) then
      Continue;
    // Match on the unit's OWN name, not on the text of the `uses` clause: a
    // unit imported unqualified through a scope-name prefix (`uses Windows`
    // reaching Winapi.Windows) is still referred to by either spelling.
    if not UnitNameMatches(FModels[LUid].UnitNameLower, LUnit) then
      Continue;
    ASym := FModels[LUid].Resolve(FModels[LUid].InterfaceScope, LMember);
    if ASym <> NIL_SYM then
    begin
      AMid := LUid;
      Exit(True);
    end;
  end;
  Result := False;
end;

function TPasSemaProject.OracleSizeOf(AMid, ASym, ADepth: Integer;
  out ABytes: Double): Boolean;
var
  LAlign: Integer;
begin
  Result := OracleLayout(AMid, ASym, ADepth, nil, ABytes, LAlign);
end;

{ The size AND alignment of a named type. Alignment has to travel with size
  because a record's own alignment is the largest of its fields' — a nested
  record contributes ITS alignment, not its size, and dcc-probed a 9-byte
  `$A1` record nested inside an `$A8` one lands at offset 1, not 8.

  For a builtin the alignment is Min(size, 8): every natural alignment is the
  type's own size up to 8, and Extended is the one that separates the two
  (10 bytes on Win32, aligned to 8). }
function TPasSemaProject.OracleLayout(AMid, ASym, ADepth: Integer;
  const ASubst: TPasSubst; out ABytes: Double; out AAlign: Integer): Boolean;
var
  LM: TPasSemaModel;
  LDef: Integer;
begin
  Result := False;
  ABytes := 0;
  AAlign := 1;
  if ADepth > 8 then
    Exit;
  LM := FModels[AMid];
  case LM.Symbols[ASym].Kind of
    skBuiltinType:
      begin
        Result := PasBuiltinSizeOf(LM.Symbols[ASym].Name, FInfo.PointerBytes,
          FInfo.ExtendedBytes, ABytes);
        if Result then
          AAlign := Min(Trunc(ABytes), 8);
        Exit;
      end;
    skType: ;   // fall through to the definition walk below
  else
    Exit;
  end;
  LDef := TypeDefNodeOf(AMid, ASym);
  if LDef = NIL_NODE then
    Exit;
  case LM.Tree.Nodes[LDef].Kind of
    nkEnumType:
      Result := OracleEnumLayout(AMid, LDef, ADepth, ABytes, AAlign);
  else
    // Everything else — a record, an array, `string[N]`, a pointer, a class,
    // an alias — is the same question a FIELD asks, so one dispatcher answers
    // both and the two cannot drift apart.
    Result := OracleFieldLayout(AMid, LDef, ADepth, ASubst, ABytes, AAlign);
  end;
end;

{ dcc's record layout, every rule of it measured by compiling a battery of
  record shapes for Win32 and Win64 and printing SizeOf at run time:

    a field starts at the next multiple of Min(its alignment, the CAP)
    the record's own alignment is the largest cap-clipped field alignment
    the size is the running offset rounded UP to that own alignment

  The cap is `$A`/`$ALIGN` AT THE DECLARATION SITE, positional for the same
  reason `$Z` is; `packed` is a cap of 1. Anything the walk does not model —
  a variant part, a class-var section, a field whose type will not resolve —
  REFUSES rather than guessing, which leaves the caller's residual-$IF
  diagnostic standing. }
function TPasSemaProject.OracleRecordLayout(AMid, ADefNode, ADepth: Integer;
  const ASubst: TPasSubst; AStart, AStartAlign: Integer;
  out ABytes: Double; out AAlign: Integer): Boolean;
var
  LM: TPasSemaModel;
  LChild, LCap, LMaxAlign, LOffset: Integer;

  // One `A, B: T;` declaration, placed at LOffset. Shared by the record body
  // and by a plain `var` section inside it, so the two cannot drift.
  function PlaceOneDecl(ADecl: Integer): Boolean;
  var
    LSub, LCount, LUse, LOneAlign: Integer;
    LOneSize: Double;
  begin
    // Children: name idents then ONE type node (records carry no
    // initializers/absolute).
    LCount := 0;
    LSub := LM.Tree.Nodes[ADecl].FirstChild;
    if LSub = NIL_NODE then
      Exit(False);
    while LM.Tree.Nodes[LSub].NextSibling <> NIL_NODE do
    begin
      Inc(LCount);
      LSub := LM.Tree.Nodes[LSub].NextSibling;
    end;
    if (LCount = 0) or
       not OracleFieldLayout(AMid, LSub, ADepth, ASubst, LOneSize, LOneAlign) then
      Exit(False);
    LUse := Min(LOneAlign, LCap);
    if LUse > LMaxAlign then
      LMaxAlign := LUse;
    // `A, B: Integer` is LCount separately placed fields; after the first the
    // offset is already a multiple of LUse, so the rounding is a no-op.
    for var LN := 1 to LCount do
    begin
      LOffset := ((LOffset + LUse - 1) div LUse) * LUse;
      LOffset := LOffset + Trunc(LOneSize);
    end;
    Result := True;
  end;

  // Every declaration in a `var` section.
  function PlaceFieldsOf(ASec: Integer): Boolean;
  var
    LF: Integer;
  begin
    LF := LM.Tree.Nodes[ASec].FirstChild;
    while LF <> NIL_NODE do
    begin
      if LM.Tree.Nodes[LF].Kind = nkVarDecl then
        if not PlaceOneDecl(LF) then
          Exit(False);
      LF := LM.Tree.Nodes[LF].NextSibling;
    end;
    Result := True;
  end;

begin
  Result := False;
  ABytes := 0;
  AAlign := 1;
  LM := FModels[AMid];
  LCap := LM.Tree.Source.AlignAt(LM.Tree.Nodes[ADefNode].FirstToken);
  // `packed record` — the parser consumes the keyword without a node of its
  // own, so the token in front of the definition is what says so.
  if (LM.Tree.Nodes[ADefNode].FirstToken > 0) and
     SameText(LM.Tree.Source.VisibleText(
       LM.Tree.Nodes[ADefNode].FirstToken - 1), 'packed') then
    LCap := 1;
  // An old-style `object` starts where its ANCESTOR's storage ended and
  // inherits its alignment; a record always starts at zero.
  LOffset := AStart;
  LMaxAlign := AStartAlign;
  LChild := LM.Tree.Nodes[ADefNode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    case LM.Tree.Nodes[LChild].Kind of
      nkIdent, nkMember, nkTypeArgs:
        ;   // an object's ancestor reference; the caller already placed it
      nkVarDecl:
        if not PlaceOneDecl(LChild) then
          Exit;
      nkVariantPart:
        begin
          var LVarAlign: Integer;
          if not OracleVariantLayout(AMid, LChild, ADepth, LCap, LOffset, ASubst,
               LOffset, LVarAlign) then
            Exit;
          if LVarAlign > LMaxAlign then
            LMaxAlign := LVarAlign;
        end;
      nkVarSec:
        // A `var` or `class var` section. Aux = 1 marks the class one, whose
        // members are per-TYPE storage and contribute neither size nor
        // alignment -- dcc-probed: `record A: Byte; class var Q: Int64;
        // var B: Byte; end` is 2 bytes, so the Int64 did not even align
        // anything. Note the section RUNS ON: a plain field written after
        // `class var` is still a class var (`record class var Q: Integer;
        // A: Byte; end` is 0 bytes), and the parser already nests it here,
        // so honouring the node is enough.
        if LM.Tree.Nodes[LChild].Aux <> 1 then
          if not PlaceFieldsOf(LChild) then
            Exit;
      nkVisibility, nkRoutine, nkPropertyDecl, nkAttrGroup,
      nkConstSec, nkTypeSec:
        ;   // no instance storage
    else
      Exit;   // anything we do not recognise stays a refusal
    end;
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
  // ZERO instance fields is a real answer, not a failure: a record whose only
  // members are class vars, methods or constants is 0 bytes (dcc-probed).
  // Every unrecognised child above exits, so reaching here means the walk
  // really did understand the whole body.
  ABytes := ((LOffset + LMaxAlign - 1) div LMaxAlign) * LMaxAlign;
  AAlign := LMaxAlign;
  Result := True;
end;

{ A `case … of` variant part, laid out from AStart. Three rules, all measured
  by printing real field OFFSETS rather than inferring them from sizes:

  1. a NAMED tag occupies storage, placed with its own alignment — but it does
     NOT contribute to the record's alignment. `record A: Byte;
     case T: Int64 of 0: (X: Byte); end` puts T at 8, X at 16 and is 17 bytes
     long: an odd size, so nothing rounded it. An UNNAMED tag
     (`case Integer of`) occupies nothing at all.
  2. every branch starts at the SAME offset, aligned to the largest alignment
     among the fields declared directly at this level — not counting a nested
     variant's fields. That is what separates `case of 0: (P: Byte; Q: Int64)`
     (both at this level, so the part starts at 8) from
     `case of 0: (X: Byte; case of 0: (Q: Int64))` (X alone here, so the part
     starts at 1 and the NESTED one starts at 8).
  3. the part's extent is the furthest any branch reaches. }
function TPasSemaProject.OracleVariantLayout(AMid, APartNode, ADepth, ACap,
  AStart: Integer; const ASubst: TPasSubst;
  out AEnd, AAlign: Integer): Boolean;
var
  LM: TPasSemaModel;
  LChild, LTagType, LBranch, LSub, LCount, LBase, LPos, LNested: Integer;
  LSize: Double;
  LOneAlign, LUse, LNestEnd, LNestAlign: Integer;

  // The fields declared DIRECTLY in a branch (a nested variant's are not).
  function LevelAlignOf: Integer;
  var
    LB, LF, LT: Integer;
    LS: Double;
    LA: Integer;
  begin
    Result := 1;
    LB := LM.Tree.Nodes[APartNode].FirstChild;
    while LB <> NIL_NODE do
    begin
      if LM.Tree.Nodes[LB].Kind = nkVariantBranch then
      begin
        LF := LM.Tree.Nodes[LB].FirstChild;
        while LF <> NIL_NODE do
        begin
          if LM.Tree.Nodes[LF].Kind = nkVarDecl then
          begin
            LT := LM.Tree.Nodes[LF].FirstChild;
            if LT <> NIL_NODE then
            begin
              while LM.Tree.Nodes[LT].NextSibling <> NIL_NODE do
                LT := LM.Tree.Nodes[LT].NextSibling;
              if OracleFieldLayout(AMid, LT, ADepth, ASubst, LS, LA) then
              begin
                if Min(LA, ACap) > Result then
                  Result := Min(LA, ACap);
              end
              else
                Exit(-1);   // a field we cannot size: refuse the whole part
            end;
          end;
          LF := LM.Tree.Nodes[LF].NextSibling;
        end;
      end;
      LB := LM.Tree.Nodes[LB].NextSibling;
    end;
  end;

begin
  AEnd := AStart;
  AAlign := 1;
  Result := False;
  if ADepth > 16 then
    Exit;
  LM := FModels[AMid];
  LChild := LM.Tree.Nodes[APartNode].FirstChild;
  if LChild = NIL_NODE then
    Exit;
  // Children are [tag name] tag-type branch... — the name is there only when
  // the SECOND child is not already a branch.
  if (LM.Tree.Nodes[LChild].Kind = nkIdent) and
     (LM.Tree.Nodes[LChild].NextSibling <> NIL_NODE) and
     (LM.Tree.Nodes[LM.Tree.Nodes[LChild].NextSibling].Kind <>
      nkVariantBranch) then
  begin
    // A NAMED tag: it is a real field. Place it, but keep it out of AAlign.
    LTagType := LM.Tree.Nodes[LChild].NextSibling;
    if not OracleFieldLayout(AMid, LTagType, ADepth, ASubst, LSize, LOneAlign) then
      Exit;
    LUse := Min(LOneAlign, ACap);
    AEnd := ((AEnd + LUse - 1) div LUse) * LUse + Trunc(LSize);
  end;

  LOneAlign := LevelAlignOf;
  if LOneAlign < 0 then
    Exit;
  AAlign := LOneAlign;
  LBase := ((AEnd + LOneAlign - 1) div LOneAlign) * LOneAlign;
  AEnd := LBase;

  LBranch := LM.Tree.Nodes[APartNode].FirstChild;
  while LBranch <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LBranch].Kind = nkVariantBranch then
    begin
      LPos := LBase;
      LSub := LM.Tree.Nodes[LBranch].FirstChild;
      while LSub <> NIL_NODE do
      begin
        case LM.Tree.Nodes[LSub].Kind of
          nkVarDecl:
            begin
              LCount := 0;
              LNested := LM.Tree.Nodes[LSub].FirstChild;
              if LNested = NIL_NODE then
                Exit;
              while LM.Tree.Nodes[LNested].NextSibling <> NIL_NODE do
              begin
                Inc(LCount);
                LNested := LM.Tree.Nodes[LNested].NextSibling;
              end;
              if (LCount = 0) or
                 not OracleFieldLayout(AMid, LNested, ADepth, ASubst, LSize,
                   LOneAlign) then
                Exit;
              LUse := Min(LOneAlign, ACap);
              for var LN := 1 to LCount do
              begin
                LPos := ((LPos + LUse - 1) div LUse) * LUse;
                LPos := LPos + Trunc(LSize);
              end;
            end;
          nkVariantPart:
            begin
              if not OracleVariantLayout(AMid, LSub, ADepth + 1, ACap, LPos, ASubst,
                   LNestEnd, LNestAlign) then
                Exit;
              LPos := LNestEnd;
              if LNestAlign > AAlign then
                AAlign := LNestAlign;
            end;
        else
          ;   // branch LABELS are ordinary expressions; skip them
        end;
        LSub := LM.Tree.Nodes[LSub].NextSibling;
      end;
      if LPos > AEnd then
        AEnd := LPos;
    end;
    LBranch := LM.Tree.Nodes[LBranch].NextSibling;
  end;
  Result := True;
end;

{ A STATIC array is element-size times the product of its dimensions, aligned
  exactly like one element — dcc-probed, including that `packed array` changes
  neither (there is no sub-byte packing to do, and the element type carries its
  own). A DYNAMIC array (`array of T`, no index) is one pointer.

  The node carries one child per dimension followed by the element type, so
  `array[0..1, 0..2] of Integer` and `array[0..1] of array[0..2] of Integer`
  fall out of the same walk — both measured at 24. }
function TPasSemaProject.OracleArrayLayout(AMid, ADefNode, ADepth: Integer;
  const ASubst: TPasSubst; out ABytes: Double; out AAlign: Integer): Boolean;
var
  LM: TPasSemaModel;
  LChild, LElem: Integer;
  LTotal, LCount, LElemSize: Double;
begin
  Result := False;
  ABytes := 0;
  AAlign := 1;
  LM := FModels[AMid];
  if LM.Tree.Nodes[ADefNode].Aux = 1 then
    Exit;   // `array of const`: an open TVarRec list, not storage we size
  LElem := LM.Tree.Nodes[ADefNode].FirstChild;
  if LElem = NIL_NODE then
    Exit;
  // The LAST child is the element type; everything before it is a dimension.
  while LM.Tree.Nodes[LElem].NextSibling <> NIL_NODE do
    LElem := LM.Tree.Nodes[LElem].NextSibling;
  if LElem = LM.Tree.Nodes[ADefNode].FirstChild then
  begin
    // No dimensions at all: a dynamic array, one reference.
    ABytes := FInfo.PointerBytes;
    AAlign := FInfo.PointerBytes;
    Exit(True);
  end;
  if not OracleFieldLayout(AMid, LElem, ADepth + 1, ASubst, LElemSize, AAlign) then
    Exit;
  LTotal := 1;
  LChild := LM.Tree.Nodes[ADefNode].FirstChild;
  while LChild <> LElem do
  begin
    if not OracleOrdinalCount(AMid, LChild, ADepth, LCount) or (LCount <= 0) then
      Exit;
    LTotal := LTotal * LCount;
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
  ABytes := LTotal * LElemSize;
  Result := True;
end;

{ How many values an array INDEX spans: `0..2` is 3, and a bare type name is
  that type's own ordinal count (`array[Byte]` is 256, `array[TEnum]` is its
  member count, `array['a'..'e']` is 5). }
function TPasSemaProject.OracleOrdinalCount(AMid, ANode, ADepth: Integer;
  out ACount: Double): Boolean;
var
  LLo, LHi: Double;
begin
  Result := OracleOrdinalRange(AMid, ANode, ADepth, LLo, LHi);
  if Result then
    ACount := LHi - LLo + 1
  else
    ACount := 0;
end;

{ The ordinal values an enum spans. Explicit values are honoured, and so is
  the rule that an implicit one continues from the last explicit: `(g1,
  g2 = 300)` is 0..300, not 0..1. A negative value is not something dcc
  accepts here, so it refuses rather than inventing a signed range. }
function TPasSemaProject.OracleEnumRange(AMid, ADefNode, ADepth: Integer;
  out ALo, AHi: Double): Boolean;
var
  LM: TPasSemaModel;
  LChild, LName, LValue: Integer;
  LNext, LThis: Double;
  LAny: Boolean;
begin
  ALo := 0;
  AHi := 0;
  LM := FModels[AMid];
  LNext := 0;
  LAny := False;
  LChild := LM.Tree.Nodes[ADefNode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LChild].Kind <> nkEnumValue then
      Exit(False);
    LName := LM.Tree.Nodes[LChild].FirstChild;
    if LName = NIL_NODE then
      Exit(False);
    LValue := LM.Tree.Nodes[LName].NextSibling;
    if LValue = NIL_NODE then
      LThis := LNext
    else if not OracleConstExpr(AMid, LValue, ADepth, LThis) then
      Exit(False);
    if (LThis < 0) or (Frac(LThis) <> 0) then
      Exit(False);
    if not LAny then
    begin
      ALo := LThis;
      AHi := LThis;
      LAny := True;
    end
    else
    begin
      if LThis < ALo then
        ALo := LThis;
      if LThis > AHi then
        AHi := LThis;
    end;
    LNext := LThis + 1;
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
  Result := LAny;
end;

{ An enum's storage: the smallest of 1/2/4 bytes that holds its LARGEST value
  (dcc-probed — `(c1 = 5, c2 = 9)` is one byte, `(f1 = 200, f2 = 300)` is
  two), then raised to the `$Z`/`$MINENUMSIZE` state AT THE DECLARATION SITE,
  which is positional because System.pas flips it mid-file (see
  TPasMinEnumEvent). An enum aligns to its size. }
function TPasSemaProject.OracleEnumLayout(AMid, ADefNode, ADepth: Integer;
  out ABytes: Double; out AAlign: Integer): Boolean;
var
  LLo, LHi: Double;
  LNatural, LMinimum: Integer;
begin
  ABytes := 0;
  AAlign := 1;
  if not OracleEnumRange(AMid, ADefNode, ADepth, LLo, LHi) then
    Exit(False);
  if LHi <= 255 then
    LNatural := 1
  else if LHi <= 65535 then
    LNatural := 2
  else if LHi <= 2147483647 then
    LNatural := 4
  else
    Exit(False);
  LMinimum := FModels[AMid].Tree.Source.MinEnumSizeAt(
    FModels[AMid].Tree.Nodes[ADefNode].FirstToken);
  if LMinimum > LNatural then
    ABytes := LMinimum
  else
    ABytes := LNatural;
  AAlign := Trunc(ABytes);
  Result := True;
end;

{ The ordinal BOUNDS of a type used as an array index or a set base. An array
  only needs the count, but a set needs the bounds themselves: its storage is
  the byte SPAN from Lo to Hi, so `set of 8..15` is one byte while
  `set of 0..8` is two. }
function TPasSemaProject.OracleOrdinalRange(AMid, ANode, ADepth: Integer;
  out ALo, AHi: Double): Boolean;

var
  LM: TPasSemaModel;
  LLo, LHi, LMid2, LSym, LDef: Integer;
  LName: string;
begin
  ALo := 0;
  AHi := 0;
  if ADepth > 8 then
    Exit(False);
  LM := FModels[AMid];
  case LM.Tree.Nodes[ANode].Kind of
    nkSubrange:
      begin
        LLo := LM.Tree.Nodes[ANode].FirstChild;
        if LLo = NIL_NODE then
          Exit(False);
        LHi := LM.Tree.Nodes[LLo].NextSibling;
        Result := (LHi <> NIL_NODE) and
          OracleConstExpr(AMid, LLo, ADepth, ALo) and
          OracleConstExpr(AMid, LHi, ADepth, AHi);
        Exit;
      end;
    nkEnumType:
      Exit(OracleEnumRange(AMid, ANode, ADepth, ALo, AHi));   // inline, as a set base
    nkIdent: ;
  else
    Exit(False);
  end;
  LName := LM.Tree.NodeText(ANode);
  // The ordinal builtins that actually appear as an index or a set base.
  if SameText(LName, 'Byte') or SameText(LName, 'AnsiChar') then
  begin
    AHi := 255;
    Exit(True);
  end;
  if SameText(LName, 'Char') or SameText(LName, 'WideChar') or
     SameText(LName, 'Word') then
  begin
    AHi := 65535;
    Exit(True);
  end;
  if SameText(LName, 'Boolean') or SameText(LName, 'ByteBool') then
  begin
    AHi := 1;
    Exit(True);
  end;
  // A named enum or subrange type.
  if not OracleResolve(AMid, LM.Tree.NodeNameLower(ANode), LMid2, LSym) then
    Exit(False);
  LDef := TypeDefNodeOf(LMid2, LSym);
  if LDef = NIL_NODE then
    Exit(False);
  case FModels[LMid2].Tree.Nodes[LDef].Kind of
    nkEnumType: Result := OracleEnumRange(LMid2, LDef, ADepth, ALo, AHi);
    nkSubrange, nkIdent:
      Result := OracleOrdinalRange(LMid2, LDef, ADepth + 1, ALo, AHi);
  else
    Result := False;
  end;
end;

{ A constant EXPRESSION in a type position (an array bound, a `string[N]`
  length), folded with the same recursive oracle a const initializer gets. A
  one-character literal counts as its ordinal, which is what makes
  `array['a'..'e']` come out as 5. }
function TPasSemaProject.OracleConstExpr(AMid, ANode, ADepth: Integer;
  out ANum: Double): Boolean;
var
  LCtx: TPasCondContext;
  LVal: TPasCondValue;
begin
  ANum := 0;
  if ADepth > 8 then
    Exit(False);
  LCtx := Default(TPasCondContext);
  LCtx.CompilerVersion := 37.0;
  LCtx.PointerBytes := FInfo.PointerBytes;
  LCtx.ExtendedBytes := FInfo.ExtendedBytes;
  LCtx.OnSymbol :=
    function(AQuery: TPasSymbolQuery; const AName: string;
      out AV: TPasSymbolValue): Boolean
    var
      LRMid, LRSym: Integer;
    begin
      AV := Default(TPasSymbolValue);
      if not OracleQualified(AMid, AName, LRMid, LRSym) then
        Exit(False);
      case AQuery of
        sqConstValue: Result := OracleConstVal(LRMid, LRSym, ADepth + 1, AV);
        sqSizeOfType: Result := OracleSizeOf(LRMid, LRSym, ADepth + 1, AV.Num);
        sqLengthOf: Result := OracleLength(LRMid, LRSym, AV.Num);
      else
        Result := False;
      end;
    end;
  LVal := EvalCondNode(FModels[AMid].Tree, ANode, LCtx);
  if LVal.Guessed then
    Exit(False);
  if LVal.Kind = cvStr then
  begin
    if Length(LVal.Str) <> 1 then
      Exit(False);
    ANum := Ord(LVal.Str[1]);
    Exit(True);
  end;
  ANum := CondAsNum(LVal);
  Result := True;
end;

{ The size and alignment of the type NAMED by ATypeNode — a field's type, or
  the right-hand side of an alias. Builtins answer straight from the table;
  anything else resolves and recurses. Kept apart from OracleLayout so the two
  callers cannot drift: a field and an alias must size identically. }
function TPasSemaProject.OracleFieldLayout(AMid, ATypeNode, ADepth: Integer;
  const ASubst: TPasSubst; out ABytes: Double; out AAlign: Integer): Boolean;

  // `System.ShortInt`, `Winapi.Windows.DWORD` — a type name written with its
  // unit. FastMM4 aliases one (TSynchronizationVariable), and refusing the dot
  // stopped the whole record it appears in.
  function DottedText(ANode: Integer): string;
  var
    LChild: Integer;
  begin
    Result := '';
    LChild := FModels[AMid].Tree.Nodes[ANode].FirstChild;
    while LChild <> NIL_NODE do
    begin
      if FModels[AMid].Tree.Nodes[LChild].Kind <> nkIdent then
        Exit('');
      if Result <> '' then
        Result := Result + '.';
      Result := Result + FModels[AMid].Tree.NodeText(LChild);
      LChild := FModels[AMid].Tree.Nodes[LChild].NextSibling;
    end;
  end;

var
  LM: TPasSemaModel;
  LRMid, LRSym, LDot, LLen, LLo, LHi: Integer;
  LName: string;
  LNum, LNum2: Double;
begin
  ABytes := 0;
  AAlign := 1;
  LM := FModels[AMid];
  if ADepth > 16 then
    Exit(False);
  case LM.Tree.Nodes[ATypeNode].Kind of
    nkIdent: LName := LM.Tree.NodeText(ATypeNode);
    nkMember: LName := DottedText(ATypeNode);
    nkRecordType:
      Exit(OracleRecordLayout(AMid, ATypeNode, ADepth + 1, ASubst, 0, 1, ABytes, AAlign));
    nkArrayType:
      Exit(OracleArrayLayout(AMid, ATypeNode, ADepth + 1, ASubst, ABytes, AAlign));
    nkStringType:
      begin
        // `string[N]` is N characters plus the leading length byte, and it is
        // byte-aligned like the ShortString it is a shorter form of.
        LLen := LM.Tree.Nodes[ATypeNode].FirstChild;
        if (LLen = NIL_NODE) or
           not OracleConstExpr(AMid, LLen, ADepth, LNum) or
           (LNum < 1) or (LNum > 255) then
          Exit(False);
        ABytes := LNum + 1;
        AAlign := 1;
        Exit(True);
      end;
    nkPointerType, nkClassOf, nkClassType, nkInterfaceType:
      begin
        // `^T`, `class of T`, and a class or interface VARIABLE are all one
        // machine pointer — no need to resolve the target, and resolving it
        // would recurse forever on the linked-list shapes these appear in
        // (FastMM4's PSmallBlockPoolHeader points back at the record that
        // contains it). dcc-probed: SizeOf of a CLASS type is the reference,
        // not the instance.
        ABytes := FInfo.PointerBytes;
        AAlign := FInfo.PointerBytes;
        Exit(True);
      end;
    nkProcType:
      begin
        // A plain procedural type is one pointer; `of object` carries the
        // Self pointer too. `reference to` is an interface reference, one
        // pointer again. It aligns as a SCALAR of its own size, not as a
        // pointer: dcc-probed, a Win32 `of object` field is 8 bytes aligned
        // to 8, even though a hand-written `record Code, Data: Pointer; end`
        // there aligns to 4.
        if LM.Tree.Nodes[ATypeNode].Aux = 1 then
          ABytes := FInfo.PointerBytes * 2
        else
          ABytes := FInfo.PointerBytes;
        AAlign := Min(Trunc(ABytes), 8);
        Exit(True);
      end;
    nkSubrange:
      begin
        // `5..9`. dcc picks the smallest storage the RANGE fits in, signed or
        // not, and the type aligns to that size.
        LLo := LM.Tree.Nodes[ATypeNode].FirstChild;
        if LLo = NIL_NODE then
          Exit(False);
        LHi := LM.Tree.Nodes[LLo].NextSibling;
        if (LHi = NIL_NODE) or
           not OracleConstExpr(AMid, LLo, ADepth, LNum) or
           not OracleConstExpr(AMid, LHi, ADepth, LNum2) then
          Exit(False);
        if ((LNum >= 0) and (LNum2 <= 255)) or
           ((LNum >= -128) and (LNum2 <= 127)) then
          ABytes := 1
        else if ((LNum >= 0) and (LNum2 <= 65535)) or
                ((LNum >= -32768) and (LNum2 <= 32767)) then
          ABytes := 2
        else
          ABytes := 4;
        AAlign := Trunc(ABytes);
        Exit(True);
      end;
    nkEnumType:
      // An INLINE anonymous enum as a field or array element:
      // `record A: Byte; F: (r0, r1); end`. Same sizing as a named one, and
      // the same positional {$Z} state.
      Exit(OracleEnumLayout(AMid, ATypeNode, ADepth, ABytes, AAlign));
    nkObjectType:
      Exit(OracleObjectLayout(AMid, ATypeNode, ADepth, ASubst, ABytes,
        AAlign));
    nkTypeArgs:
      Exit(OracleGenericLayout(AMid, ATypeNode, ADepth, ASubst, ABytes,
        AAlign));
    nkSetType:
      begin
        // A set stores the byte SPAN from its base type's Lo to its Hi --
        // `set of 8..15` is one byte, `set of 0..8` is two. Below a machine
        // word that span is rounded up to a power of two, above it it is
        // exact: dcc-probed, span 3 is 4 bytes on both platforms, while span
        // 5, 6 and 7 are 5, 6 and 7 on Win32 but all 8 on Win64. Always
        // byte-aligned, whatever the size.
        LLo := LM.Tree.Nodes[ATypeNode].FirstChild;
        if (LLo = NIL_NODE) or
           not OracleOrdinalRange(AMid, LLo, ADepth, LNum, LNum2) then
          Exit(False);
        // dcc caps a set base at 0..255; anything else is an error there, not
        // a size we should invent.
        if (LNum < 0) or (LNum2 > 255) or (LNum2 < LNum) then
          Exit(False);
        LLen := Trunc(LNum2) div 8 - Trunc(LNum) div 8 + 1;
        if LLen <= FInfo.PointerBytes then
          while (LLen and (LLen - 1)) <> 0 do
            Inc(LLen);
        ABytes := LLen;
        AAlign := 1;
        Exit(True);
      end;
    nkFileType:
      begin
        // `file` and `file of T` are both the same System record whatever T
        // is (dcc-probed: identical sizes), so the honest answer is that
        // record's -- looked up rather than hard-coded, since its size is an
        // RTL fact that has moved between releases.
        Result := OracleResolve(AMid, 'tfilerec', LRMid, LRSym) and
          OracleLayout(LRMid, LRSym, ADepth + 1, nil, ABytes, AAlign);
        // Its SIZE only. TFileRec is declared `packed`, so laying it out
        // gives an alignment of 1 -- but dcc aligns a file VARIABLE to a
        // pointer regardless (a Byte before a `file of Byte` field is 596 on
        // Win32, not 593). The packing describes the record's own offsets,
        // not how the compiler's file type is placed.
        AAlign := FInfo.PointerBytes;
        Exit;
      end;
  else
    // A variant part reaches OracleRecordLayout, never here; anything else is
    // a shape we do not model, and refusing keeps the caller's residual-$IF
    // diagnostic honest.
    Exit(False);
  end;
  if LName = '' then
    Exit(False);
  // A generic PARAMETER bound by the enclosing instantiation resolves to its
  // actual, which lives in the REFERRING model. Checked before the builtin
  // table so a parameter named like one cannot be mistaken for it.
  for var LSIdx := 0 to High(ASubst) do
    if ASubst[LSIdx].Name = LowerCase(LName) then
      Exit(OracleFieldLayout(ASubst[LSIdx].Mid, ASubst[LSIdx].Node,
        ADepth + 1, nil, ABytes, AAlign));
  if PasBuiltinLayout(LName, FInfo.PointerBytes, FInfo.ExtendedBytes,
    ABytes, AAlign) then
    Exit(True);
  // `Text` is a compiler intrinsic with no size in the table, and `TextFile`
  // is System's alias for it. Both are that unit's TTextRec — looked up, not
  // hard-coded, for the same reason TFileRec is.
  if SameText(LName, 'Text') or SameText(LName, 'TextFile') then
    if OracleResolve(AMid, 'ttextrec', LRMid, LRSym) and
       OracleLayout(LRMid, LRSym, ADepth + 1, nil, ABytes, AAlign) then
    begin
      AAlign := FInfo.PointerBytes;   // see the nkFileType branch above
      Exit(True);
    end;
  if OracleQualified(AMid, LName, LRMid, LRSym) then
    Exit(OracleLayout(LRMid, LRSym, ADepth + 1, nil, ABytes, AAlign));
  // `System.X` where X is a builtin: System is the implicit unit and is not
  // in anyone's `uses`, so the lookup above cannot reach it. Restricted to
  // that one prefix — for any other unit, an unresolved member must refuse
  // rather than fall back to a same-named builtin.
  LDot := LName.LastIndexOf('.');
  Result := (LDot >= 0) and SameText(Copy(LName, 1, LDot), 'System') and
    PasBuiltinLayout(Copy(LName, LDot + 2, MaxInt), FInfo.PointerBytes,
      FInfo.ExtendedBytes, ABytes, AAlign);
end;

{ An old-style `object` (11.5). Its fields lay out exactly like a record's,
  starting where the ANCESTOR's storage ended, plus one rule that has to be
  measured: introducing a VIRTUAL member appends a VMT pointer AFTER the
  fields, pointer-aligned — and that pointer does NOT raise the type's own
  alignment, so `object A: Integer; procedure P; virtual; end` is 16 bytes on
  Win64 yet still aligns to 4 (a Byte before such a field gives 20, not 24).
  A derived object whose ancestor already has a VMT does not get a second one:
  `object(that) C: Byte; end` is 20, not 28. A variant part is not legal in an
  object, so there is none to model. }
function TPasSemaProject.OracleObjectLayout(AMid, ADefNode, ADepth: Integer;
  const ASubst: TPasSubst; out ABytes: Double;
  out AAlign: Integer): Boolean;
var
  LM: TPasSemaModel;
  LChild, LStart, LStartAlign, LPtr, LRMid, LRSym, LBaseDef: Integer;
  LBaseSize: Double;
  LBaseHasVmt: Boolean;
begin
  ABytes := 0;
  AAlign := 1;
  if ADepth > 8 then
    Exit(False);
  LM := FModels[AMid];
  LStart := 0;
  LStartAlign := 1;
  LBaseHasVmt := False;
  LChild := LM.Tree.Nodes[ADefNode].FirstChild;
  // The heritage, when present, is the FIRST child and is a type reference;
  // members are declaration nodes.
  if (LChild <> NIL_NODE) and
     (LM.Tree.Nodes[LChild].Kind in [nkIdent, nkMember, nkTypeArgs]) then
  begin
    if not OracleFieldLayout(AMid, LChild, ADepth + 1, ASubst, LBaseSize,
         LStartAlign) then
      Exit(False);
    LStart := Trunc(LBaseSize);
    // Whether the ANCESTOR already carries a VMT — asked of its own
    // definition, not ours, because that is what decides if we introduce one.
    if (LM.Tree.Nodes[LChild].Kind = nkIdent) and
       OracleQualified(AMid, LM.Tree.NodeText(LChild), LRMid, LRSym) then
    begin
      LBaseDef := TypeDefNodeOf(LRMid, LRSym);
      LBaseHasVmt := (LBaseDef <> NIL_NODE) and
        (FModels[LRMid].Tree.Nodes[LBaseDef].Kind = nkObjectType) and
        OracleObjectHasVmt(LRMid, LBaseDef, ADepth + 1);
    end;
  end;
  if not OracleRecordLayout(AMid, ADefNode, ADepth, ASubst, LStart,
       LStartAlign, ABytes, AAlign) then
    Exit(False);
  // A VMT slot, only where it is INTRODUCED.
  if not LBaseHasVmt and OracleObjectHasVmt(AMid, ADefNode, ADepth + 1) then
  begin
    LPtr := FInfo.PointerBytes;
    ABytes := ((Trunc(ABytes) + LPtr - 1) div LPtr) * LPtr + LPtr;
    // ...and the pointer does not raise the alignment, so round again to the
    // alignment the FIELDS established.
    ABytes := ((Trunc(ABytes) + AAlign - 1) div AAlign) * AAlign;
  end;
  Result := True;
end;

{ Does this object introduce or inherit a VMT — that is, does it or any
  ancestor declare a `virtual` (or `dynamic`) member? Called with ADepth+1 for
  the type's own members and with ADepth for its ancestor chain, so the two
  questions stay separable. }
function TPasSemaProject.OracleObjectHasVmt(AMid, ADefNode,
  ADepth: Integer): Boolean;
var
  LM: TPasSemaModel;
  LChild, LDir, LRMid, LRSym, LBase: Integer;
begin
  Result := False;
  if ADepth > 8 then
    Exit;
  LM := FModels[AMid];
  LChild := LM.Tree.Nodes[ADefNode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LChild].Kind = nkRoutine then
    begin
      LDir := LM.Tree.Nodes[LChild].FirstChild;
      while LDir <> NIL_NODE do
      begin
        if (LM.Tree.Nodes[LDir].Kind = nkDirective) and
           (SameText(LM.Tree.NodeText(LDir), 'virtual') or
            SameText(LM.Tree.NodeText(LDir), 'dynamic')) then
          Exit(True);
        LDir := LM.Tree.Nodes[LDir].NextSibling;
      end;
    end;
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
  // Not here — ask the ancestor.
  LBase := LM.Tree.Nodes[ADefNode].FirstChild;
  if (LBase <> NIL_NODE) and (LM.Tree.Nodes[LBase].Kind = nkIdent) and
     OracleQualified(AMid, LM.Tree.NodeText(LBase), LRMid, LRSym) then
  begin
    LBase := TypeDefNodeOf(LRMid, LRSym);
    if (LBase <> NIL_NODE) and
       (FModels[LRMid].Tree.Nodes[LBase].Kind = nkObjectType) then
      Result := OracleObjectHasVmt(LRMid, LBase, ADepth + 1);
  end;
end;

{ A generic INSTANTIATION used as a type — `TG<Integer>`, the nkTypeArgs node.
  The generic's own declaration is laid out with its parameters bound to the
  actuals, which live in the REFERRING model and are therefore carried as
  (model, node) pairs.

  An argument that is itself a bare parameter of the ENCLOSING instantiation
  is passed through by copying that binding, which is what makes
  `TOuter<T> = record V: TInner<T>; end` work when TOuter is instantiated. An
  argument that MENTIONS an enclosing parameter without being one outright
  (`TOuter<T> = record V: TInner<TPair<T>>; end`) is refused rather than
  half-substituted. }
function TPasSemaProject.OracleGenericLayout(AMid, AArgsNode, ADepth: Integer;
  const ASubst: TPasSubst; out ABytes: Double;
  out AAlign: Integer): Boolean;

  // Does this subtree name any parameter of the enclosing instantiation?
  function MentionsParam(ANode: Integer): Boolean;
  var
    LKid: Integer;
  begin
    if FModels[AMid].Tree.Nodes[ANode].Kind = nkIdent then
      for var LI := 0 to High(ASubst) do
        if ASubst[LI].Name = FModels[AMid].Tree.NodeNameLower(ANode) then
          Exit(True);
    LKid := FModels[AMid].Tree.Nodes[ANode].FirstChild;
    while LKid <> NIL_NODE do
    begin
      if MentionsParam(LKid) then
        Exit(True);
      LKid := FModels[AMid].Tree.Nodes[LKid].NextSibling;
    end;
    Result := False;
  end;

var
  LM: TPasSemaModel;
  LBase, LArg, LGMid, LGSym, LDecl, LParams, LP, LName: Integer;
  LInner: TPasSubst;
  LNames: TArray<string>;
begin
  ABytes := 0;
  AAlign := 1;
  if ADepth > 8 then
    Exit(False);
  LM := FModels[AMid];
  LBase := LM.Tree.Nodes[AArgsNode].FirstChild;
  // A plain name only. `SomeUnit.TG<Integer>` would need the dotted route and
  // appears nowhere measured, so it refuses rather than half-resolving.
  if (LBase = NIL_NODE) or (LM.Tree.Nodes[LBase].Kind <> nkIdent) then
    Exit(False);
  if not OracleQualified(AMid, LM.Tree.NodeText(LBase), LGMid, LGSym) then
    Exit(False);
  // The parameter NAMES come from the declaration's <...> list.
  LDecl := FModels[LGMid].Symbols[LGSym].DeclNode;
  if LDecl = NIL_NODE then
    Exit(False);
  LDecl := FModels[LGMid].Tree.Nodes[LDecl].Parent;
  if LDecl = NIL_NODE then
    Exit(False);
  LParams := FModels[LGMid].Tree.Nodes[LDecl].FirstChild;
  LNames := nil;
  while LParams <> NIL_NODE do
  begin
    if FModels[LGMid].Tree.Nodes[LParams].Kind = nkGenericParams then
    begin
      LP := FModels[LGMid].Tree.Nodes[LParams].FirstChild;
      while LP <> NIL_NODE do
      begin
        if FModels[LGMid].Tree.Nodes[LP].Kind = nkGenericParam then
        begin
          // `<T, U>` is ONE group carrying BOTH names (the `;` is what
          // separates groups), so every ident child is a parameter. The
          // nkConstraint children that may follow are not.
          LName := FModels[LGMid].Tree.Nodes[LP].FirstChild;
          if (LName = NIL_NODE) or
             (FModels[LGMid].Tree.Nodes[LName].Kind <> nkIdent) then
            Exit(False);
          while (LName <> NIL_NODE) and
                (FModels[LGMid].Tree.Nodes[LName].Kind = nkIdent) do
          begin
            LNames := LNames + [FModels[LGMid].Tree.NodeNameLower(LName)];
            LName := FModels[LGMid].Tree.Nodes[LName].NextSibling;
          end;
        end;
        LP := FModels[LGMid].Tree.Nodes[LP].NextSibling;
      end;
      Break;
    end;
    LParams := FModels[LGMid].Tree.Nodes[LParams].NextSibling;
  end;
  if LNames = nil then
    Exit(False);
  // Bind them positionally to the actuals.
  LInner := nil;
  LArg := LM.Tree.Nodes[LBase].NextSibling;
  for var LI := 0 to High(LNames) do
  begin
    if LArg = NIL_NODE then
      Exit(False);
    var LEntry: TPasSubstEntry;
    LEntry.Name := LNames[LI];
    if (LM.Tree.Nodes[LArg].Kind = nkIdent) and MentionsParam(LArg) then
    begin
      // The actual IS an enclosing parameter: carry its binding through.
      for var LJ := 0 to High(ASubst) do
        if ASubst[LJ].Name = LM.Tree.NodeNameLower(LArg) then
        begin
          LEntry.Mid := ASubst[LJ].Mid;
          LEntry.Node := ASubst[LJ].Node;
          Break;
        end;
    end
    else if MentionsParam(LArg) then
      Exit(False)   // a compound actual over an open parameter: refuse
    else
    begin
      LEntry.Mid := AMid;
      LEntry.Node := LArg;
    end;
    LInner := LInner + [LEntry];
    LArg := LM.Tree.Nodes[LArg].NextSibling;
  end;
  if LArg <> NIL_NODE then
    Exit(False);   // more actuals than parameters
  Result := OracleLayout(LGMid, LGSym, ADepth + 1, LInner, ABytes, AAlign);
end;

function TPasSemaProject.OracleLength(AMid, ASym: Integer;
  out ALen: Double): Boolean;
var
  LM: TPasSemaModel;
  LDecl, LParent, LChild, LArr, LSub, LLo, LHi: Integer;
  LCtx: TPasCondContext;
  LLoVal, LHiVal: TPasCondValue;
begin
  Result := False;
  ALen := 0;
  LM := FModels[AMid];
  if not (LM.Symbols[ASym].Kind in [skConst, skVar]) then
    Exit;
  LDecl := LM.Symbols[ASym].DeclNode;
  if LDecl = NIL_NODE then
    Exit;
  LParent := LM.Tree.Nodes[LDecl].Parent;
  if (LParent = NIL_NODE) or
     not (LM.Tree.Nodes[LParent].Kind in [nkVarDecl, nkConstDecl]) then
    Exit;
  // The first nkArrayType child is the declared type; its FIRST dimension is
  // what Length answers (dcc's rule for multidimensional arrays too).
  LArr := NIL_NODE;
  LChild := LM.Tree.Nodes[LParent].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LChild].Kind = nkArrayType then
    begin
      LArr := LChild;
      Break;
    end;
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
  if LArr = NIL_NODE then
    Exit;
  LSub := LM.Tree.Nodes[LArr].FirstChild;
  if (LSub = NIL_NODE) or (LM.Tree.Nodes[LSub].Kind <> nkSubrange) then
    Exit;   // a dynamic array's Length is runtime state, not a bound
  LLo := LM.Tree.Nodes[LSub].FirstChild;
  if LLo = NIL_NODE then
    Exit;
  LHi := LM.Tree.Nodes[LLo].NextSibling;
  if LHi = NIL_NODE then
    Exit;
  // Bounds may themselves be constants — evaluate with the same recursive
  // const context OracleConstNum builds.
  LCtx := Default(TPasCondContext);
  LCtx.CompilerVersion := 37.0;
  LCtx.PointerBytes := FInfo.PointerBytes;
  LCtx.ExtendedBytes := FInfo.ExtendedBytes;
  LCtx.OnSymbol :=
    function(AQuery: TPasSymbolQuery; const AName: string;
      out AV: TPasSymbolValue): Boolean
    var
      LRMid, LRSym: Integer;
    begin
      AV := Default(TPasSymbolValue);
      Result := (AQuery = sqConstValue) and
        OracleQualified(AMid, AName, LRMid, LRSym) and
        OracleConstNum(LRMid, LRSym, 0, AV.Num);
    end;
  LLoVal := EvalCondNode(LM.Tree, LLo, LCtx);
  LHiVal := EvalCondNode(LM.Tree, LHi, LCtx);
  if LLoVal.Guessed or LHiVal.Guessed or (LLoVal.Kind <> cvNum) or
     (LHiVal.Kind <> cvNum) then
    Exit;
  ALen := LHiVal.Num - LLoVal.Num + 1;
  Result := True;
end;

function TPasSemaProject.SymbolQueryFor(AId: Integer): TPasCondSymbolQuery;
begin
  Result :=
    function(AQuery: TPasSymbolQuery; const AName: string;
      out AValue: TPasSymbolValue): Boolean
    var
      LMid, LSym: Integer;
    begin
      Result := False;
      AValue := Default(TPasSymbolValue);
      // Qualified names resolve too — dcc evaluates a `$IF Unit.Const > 1`
      // guard for real, so refusing the dot invented a residual guess where
      // the compiler had a plain answer (see OracleQualified).
      if not OracleQualified(AId, AName, LMid, LSym) then
      begin
        // "Exists nowhere" is a stronger claim than "I could not resolve it",
        // and CondEval copies dcc's abort verdict from it — so only make it
        // when the claim is sound. A unit with an unresolved import has a
        // hole in its symbol table exactly where a declaration could be
        // hiding, and a DOTTED name is dcc's own fallback-to-False shape
        // rather than an abort, so neither earns the flag.
        AValue.NoSymbol := FModels[AId].AllUsesResolved and
          not AName.Contains('.');
        Exit;
      end;
      case AQuery of
        sqConstValue: Result := OracleConstVal(LMid, LSym, 0, AValue);
        sqSizeOfType: Result := OracleSizeOf(LMid, LSym, 0, AValue.Num);
        sqLengthOf: Result := OracleLength(LMid, LSym, AValue.Num);
      end;
    end;
end;

{ The second preprocessing pass, for units whose `$IF Declared(X)` the FIRST
  pass could not answer (1.3: the guard needs a symbol table, and the symbol
  table is built from the stream the guard decides). Cheap because it is
  candidate-driven: a unit only qualifies if it actually asked, which across
  the RTL+VCL+FMX corpus is a few dozen units out of hundreds.

  Placed after `uses` are linked and before any cross pass, and that is the
  only window where it is safe: the imports it must consult have models, while
  nothing yet holds a (unit, symbol) reference INTO the models being replaced.

  ONE round, by design. A re-decided unit can in principle change its own
  interface, which would change the answer for a unit that imports it; chasing
  that to a fixpoint would mean re-parsing on every round for a shape nobody
  writes (the guards ask about RTL names, not about each other). Units the new
  branch newly imports ARE loaded, though — otherwise the unit would end up
  with an unresolved `uses`, which gates its diagnostics entirely. }
procedure TPasSemaProject.RunDeclaredPass(ACount: Integer);
var
  LCand: TArray<Integer>;
  LDone: TArray<TPasSemaModel>;
  LIdx, LU: Integer;
  LPaths: TArray<string>;
  LPath, LName: string;
  LQuery: TPasDeclaredQuery;
  LSymQuery: TPasCondSymbolQuery;
  LUnsym: TPasUnresolvedSymbol;
  LAnswer, LIsCand: Boolean;
  LNum: TPasSymbolValue;
begin
  // Candidates are not "asked a question" but "would get a DIFFERENT answer".
  // The first pass answered every Declared() False, so a unit whose names all
  // still answer False would re-preprocess to a byte-identical stream — and
  // paying a re-parse for that is not free: doing it unfiltered measured +4%
  // on the 665-unit corpus, for zero diagnostic change there. The test itself
  // is a few dictionary lookups per recorded name.
  //
  // Symbol questions (const values / SizeOf / Length — see TPasCondSymbolQuery)
  // use the looser "would get an ANSWER" criterion: unlike Declared, whose
  // False guess only ever flips on a True answer, a const's real value may
  // happen to reproduce the guessed verdict — comparing would need the define
  // state at the directive, so the re-run eats that instead. Bounded by how
  // rare the questions are (a dozen units on the whole RTL).
  LCand := nil;
  for LIdx := 0 to ACount - 1 do
  begin
    LIsCand := False;
    if Length(FModels[LIdx].Tree.Source.UnresolvedDeclared) > 0 then
    begin
      LQuery := DeclaredQueryFor(LIdx);
      for LName in FModels[LIdx].Tree.Source.UnresolvedDeclared do
        if LQuery(LName, LAnswer) and LAnswer then
        begin
          LIsCand := True;
          Break;
        end;
    end;
    if not LIsCand and
       (Length(FModels[LIdx].Tree.Source.UnresolvedSymbols) > 0) then
    begin
      LSymQuery := SymbolQueryFor(LIdx);
      for LUnsym in FModels[LIdx].Tree.Source.UnresolvedSymbols do
        // Either kind of answer earns the re-run. "Here is the value" is the
        // obvious one; "this name exists NOWHERE" is the other, because that
        // is what lets CondEval apply dcc's abort rules instead of leaving the
        // first pass's False guess standing — a different verdict, not a
        // byte-identical one.
        if LSymQuery(LUnsym.Query, LUnsym.Name, LNum) or LNum.NoSymbol then
        begin
          LIsCand := True;
          Break;
        end;
    end;
    if LIsCand then
      LCand := LCand + [LIdx];
  end;
  if LCand = nil then
    Exit;
  // Ask first, in PARALLEL and without touching anything: a worker reads other
  // models' frozen interface scopes and writes only its own slot.
  SetLength(LDone, Length(LCand));
  ForEachIndex(High(LCand), 'declared-pass',
    procedure(AIndex: Integer)
    var
      LPP: TPasPreprocessor;
      LDiags: TArray<TPasParseDiag>;
    begin
      LDone[AIndex] := nil;
      LPP := RentPP;
      try
        try
          LPP.OnDeclared := DeclaredQueryFor(LCand[AIndex]);
          LPP.OnSymbol := SymbolQueryFor(LCand[AIndex]);
          LDone[AIndex] := TPasSemaResolver.Analyze(
            TPasParser.ParseFile(LPP.Process(FFiles[LCand[AIndex]]), LDiags),
            False, FPlatform);
        except
          // Keep the first-pass model. A unit that parsed once and throws now
          // is a defect, but the wrong branch is still better than no unit at
          // all — an unloadable unit gates every importer.
          on Exception do
            LDone[AIndex] := nil;
        end;
      finally
        ReturnPP(LPP);
      end;
    end,
    // This pass walks a CANDIDATE list, so the body index is not a unit id.
    function(AIndex: Integer): Integer
    begin
      Result := LCand[AIndex];
    end);
  // Then commit, sequentially. FModels OWNS its items, so the assignment is
  // what frees the first-pass model — freeing it here as well is a double free.
  for LIdx := 0 to High(LCand) do
    if LDone[LIdx] <> nil then
      FModels[LCand[LIdx]] := LDone[LIdx];
  LPaths := nil;
  for LIdx := 0 to High(LCand) do
    if LDone[LIdx] <> nil then
      for LU := 0 to High(FModels[LCand[LIdx]].UsesList) do
        if FSM.ResolveUnit(FModels[LCand[LIdx]].UsesList[LU].NameFull,
             FModels[LCand[LIdx]].UsesList[LU].InPath, FFiles[LCand[LIdx]],
             LPath) and not FByPath.ContainsKey(LowerCase(LPath)) then
          LPaths := LPaths + [LPath];
  if LPaths <> nil then
    LoadFilesParallel(LPaths);
  for LIdx := 0 to High(LCand) do
    if LDone[LIdx] <> nil then
      ResolveUses(LCand[LIdx]);
end;

{ ReportGuessedIfs' worker: lifts the preprocessor's conditional flags out of
  each model's retained preprocess data and into its ordinary diagnostics,
  where -list/histograms/the demo already know how to show them. Runs right
  after RunDeclaredPass in each driver, and gated on ACount like every other
  diagnostic — units pulled in later from search paths stay out, as their
  E2003s do.

  THE FILTER IS THE POINT. A flag means "the verdict rested on a guess", and
  most such guesses are provably CORRECT by the time we get here: a
  `$IF Declared(TlsStart)` in SysInit guards a name that exists on another
  platform only, and DeclaredQueryFor answers that definitively ("declared
  nowhere in this closure") — the guard is ordinary platform-conditional
  code, not a finding. RunDeclaredPass therefore did not even re-run the
  unit, which is exactly why its first-pass flag is still sitting there. So
  the flag alone cannot be the report criterion; re-asking is.

  Each flag carries the questions its evaluation could not answer
  (TPasPPDiagnostic.Unanswered). We ask them again with the FULL project
  oracle, and report only when something is STILL unanswerable — the genuine
  exotica: SizeOf of a type whose layout tier 1 refuses, a string-valued
  constant, Ord(), a dotted name. A `Declared` question is always answerable
  now, so a Declared-only guard never reports.

  (An earlier version reported every flag and argued that hiding a confirmed
  guess would also hide a misspelled name meant to exist. That was wrong: a
  misspelling is indistinguishable from a legitimate platform guard, and the
  guards outnumber it 31 to 0 on the RTL alone — so the argument bought
  nothing and cost a flood of normal code reported as findings.) }
{ One PPENC per file that had to be RECOVERED to be read — see
  TPasSourceManager.DecodeText. Every file of the unit is checked, includes as
  well, since a `.inc` is where such a byte is most likely to hide.

  Unlike the residual-$IF report this is NOT opt-in. A recovered file may not
  say what its author wrote, and the failure mode when it goes wrong is not
  subtle: it silently cost ~1700 downstream "undeclared identifier" reports on
  the Alcinoe package with nothing in the log pointing back. }
procedure TPasSemaProject.InjectEncodingDiags(ACount: Integer);
var
  LIdx, LF: Integer;
  LM: TPasSemaModel;
  LNote: string;
  LParts: TArray<string>;
begin
  for LIdx := 0 to ACount - 1 do
  begin
    LM := FModels[LIdx];
    if (LM = nil) or (LM.Tree.Source.FileNames = nil) then
      Continue;
    for LF := 0 to High(LM.Tree.Source.FileNames) do
    begin
      LNote := FSM.RecoveryNote(LM.Tree.Source.FileNames[LF]);
      if LNote = '' then
        Continue;
      LParts := LNote.Split(['|']);
      if Length(LParts) < 2 then
        Continue;
      LM.AddDiag(MakeDiag('PPENC',
        Format(SPPENC_Recovered, [LParts[0], LParts[1]]), 0, LF, 1, 1));
    end;
  end;
end;

procedure TPasSemaProject.InjectGuessedIfDiags(ACount: Integer);
var
  LIdx, LDIdx, LQIdx: Integer;
  LM: TPasSemaModel;
  LDiag: TSemaDiag;
  LDeclQuery: TPasDeclaredQuery;
  LSymQuery: TPasCondSymbolQuery;
  LPPCode: TPasPPDiagCode;
  LOpen: TArray<string>;
  LName: string;
  LNum: TPasSymbolValue;
  LDeclAnswer: Boolean;
begin
  if not FReportGuessedIfs then
    Exit;
  for LIdx := 0 to ACount - 1 do
  begin
    LM := FModels[LIdx];
    LDeclQuery := nil;
    LSymQuery := nil;
    for LDIdx := 0 to High(LM.Tree.Source.Diagnostics) do
    begin
      LPPCode := LM.Tree.Source.Diagnostics[LDIdx].Code;
      if not (LPPCode in [ppIfNeedsSemantics, ppBadIfExpression]) then
        Continue;
      LOpen := nil;
      if LPPCode = ppIfNeedsSemantics then
      begin
        // Build the oracles lazily: most units have no conditional flags at
        // all, and each closure captures a model id.
        if not Assigned(LDeclQuery) then
        begin
          LDeclQuery := DeclaredQueryFor(LIdx);
          LSymQuery := SymbolQueryFor(LIdx);
        end;
        for LQIdx := 0 to High(LM.Tree.Source.Diagnostics[LDIdx].Unanswered) do
        begin
          LName := LM.Tree.Source.Diagnostics[LDIdx].Unanswered[LQIdx].Name;
          if LM.Tree.Source.Diagnostics[LDIdx].Unanswered[LQIdx].Query =
             sqDeclared then
          begin
            if not LDeclQuery(LName, LDeclAnswer) then
              LOpen := LOpen + ['Declared(' + LName + ')'];
          end
          else if not LSymQuery(
            LM.Tree.Source.Diagnostics[LDIdx].Unanswered[LQIdx].Query,
            LName, LNum) then
            case LM.Tree.Source.Diagnostics[LDIdx].Unanswered[LQIdx].Query of
              sqSizeOfType: LOpen := LOpen + ['SizeOf(' + LName + ')'];
              sqLengthOf: LOpen := LOpen + ['Length(' + LName + ')'];
            else
              LOpen := LOpen + [LName];
            end;
        end;
        // No questions recorded at all means the evaluation guessed at
        // something it could not even NAME (an indexed designator, a shape
        // CondEval has no case for) — the most unknown thing there is, so it
        // reports rather than passing the "nothing open" test vacuously.
        if (LOpen = nil) and
           (Length(LM.Tree.Source.Diagnostics[LDIdx].Unanswered) > 0) then
          Continue;   // every question answerable now: a CONFIRMED guess
        if LOpen = nil then
          LOpen := ['an unrecognized expression form'];
      end;
      if LPPCode = ppIfNeedsSemantics then
      begin
        LDiag.Code := 'PPIF';
        LDiag.Msg := Format('PPIF conditional still undecidable: [%s] — ' +
          'cannot resolve %s', [LM.Tree.Source.Diagnostics[LDIdx].Detail,
          string.Join(', ', LOpen)]);
      end
      else
      begin
        LDiag.Code := 'PPBAD';
        LDiag.Msg := 'PPBAD malformed conditional expression: [' +
          LM.Tree.Source.Diagnostics[LDIdx].Detail + ']';
      end;
      LDiag.DeclNode := NIL_NODE;
      LDiag.FileId := LM.Tree.Source.Diagnostics[LDIdx].FileId;
      LM.Tree.Source.Files[LDiag.FileId].OffsetToLineCol(
        LM.Tree.Source.Diagnostics[LDIdx].Start, LDiag.Line, LDiag.Col);
      LM.AddDiag(LDiag);
    end;
  end;
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

function TPasSemaProject.RentPP: TPasPreprocessor;
begin
  Result := nil;
  FPPPoolLock.Enter;
  try
    if FPPPool.Count > 0 then
    begin
      Result := FPPPool[FPPPool.Count - 1];
      FPPPool.Delete(FPPPool.Count - 1);
    end;
  finally
    FPPPoolLock.Leave;
  end;
  if Result = nil then
    Result := TPasPreprocessor.Create(FSM, FDefines, 37.0, FInfo.PointerBytes,
      FInfo.ExtendedBytes);
  // A previous renter's callbacks must never answer this run's questions.
  Result.OnDeclared := nil;
  Result.OnSymbol := nil;
end;

procedure TPasSemaProject.ReturnPP(APP: TPasPreprocessor);
begin
  FPPPoolLock.Enter;
  try
    FPPPool.Add(APP);
  finally
    FPPPoolLock.Leave;
  end;
end;

// Cut every model's Diags back to its filled prefix (AddDiag grows with
// capacity slack) — must run before any consumer enumerates Diags with
// Length/High, i.e. at the end of every analysis entry point.
procedure TPasSemaProject.TrimAllDiags;
var
  LIdx: Integer;
begin
  for LIdx := 0 to FModels.Count - 1 do
    FModels[LIdx].TrimDiags;
end;

// Drop the body passes' work lists and their cached names — pass-lifetime
// scratch, tens of MB on a big closure, and nothing reads them after the
// passes finish. All five arrays go TOGETHER: EnsureCrossWork's FWorkBuilt
// guard is what keeps the parallel lists in sync, so a partial release would
// leave a True guard over empty name arrays. Any later pass entry rebuilds
// on demand (BuildHelperMap resets the same set at the start of every run).
procedure TPasSemaProject.ReleaseCrossWork;
begin
  SetLength(FWorkBuilt, 0);
  SetLength(FInhWork, 0);
  SetLength(FWithWork, 0);
  SetLength(FInhWorkNames, 0);
  SetLength(FWithWorkNames, 0);
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
  LIdx, LDummy, LTodoCount: Integer;
  LFull, LKey: string;
  LStatus: TPasModuleStatus;
  LFailLock: TCriticalSection;
begin
  // Normalize, drop already-loaded/known-bad paths and in-batch duplicates.
  // Pre-sized to the input (survivors <= input), truncated after the loop —
  // per-append array copies were O(n²) refcount churn on a 3757-path batch.
  SetLength(LTodo, Length(APaths));
  SetLength(LKeys, Length(APaths));
  LTodoCount := 0;
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
      LTodo[LTodoCount] := LFull;
      LKeys[LTodoCount] := LKey;
      Inc(LTodoCount);
    end;
  finally
    LSeen.Free;
  end;
  SetLength(LTodo, LTodoCount);
  SetLength(LKeys, LTodoCount);
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
  ForEachIndex(High(LTodo), 'load',
    procedure(AIndex: Integer)
    var
      LPP: TPasPreprocessor;
      LPre: TPasPreprocessed;
      LDiags: TArray<TPasParseDiag>;
    begin
      LPP := RentPP;
      try
        try
          // The compiler-provided names are answerable already; anything
          // else a Declared() guard asks is recorded for RunDeclaredPass.
          LPP.OnDeclared := SeedDeclaredQuery();
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
            (LTree.Nodes[0].Kind = nkUnit), FPlatform);
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
        ReturnPP(LPP);
      end;
    end,
    // This pass walks FILE PATHS — the models do not exist yet — so there is
    // no unit to blame; -1 sends the note to the project-level list.
    function(AIndex: Integer): Integer
    begin
      Result := -1;
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

type
  // RunLoadEngine's queue entry / result. Unit-level: Delphi has no local
  // type declarations, and the queue is a generic over these.
  TPasLoadKind = (lkLoad, lkUpgrade);
  TPasLoadItem = record
    Kind: TPasLoadKind;
    Path, Key: string;         // lkLoad: normalized full path + lower key
    Mid: Integer;              // lkUpgrade: model to swap in place
    Source: TPasPreprocessed;  // lkUpgrade: token-layer snapshot
  end;
  TPasLoadRes = record
    Model: TPasSemaModel;            // nil = failed; ErrClass/ErrMsg say why
    ErrClass, ErrMsg: string;
  end;

function TPasSemaProject.ComputeLoad(const APath: string; AIntf: Boolean;
  out AErrClass, AErrMsg: string): TPasSemaModel;
var
  LPP: TPasPreprocessor;
  LPre: TPasPreprocessed;
  LDiags: TArray<TPasParseDiag>;
  LTree: TPasTree;
begin
  // Mirrors LoadFilesParallel's worker body — see the comments there (the
  // typer skip rule, the tolerate-out-loud contract).
  Result := nil;
  AErrClass := '';
  AErrMsg := '';
  try
    LPP := RentPP;
    try
      LPP.OnDeclared := SeedDeclaredQuery();
      LPre := LPP.Process(APath);
      LTree := TPasParser.ParseFile(LPre, LDiags, AIntf);
      Result := TPasSemaResolver.Analyze(LTree,
        {ASkipTyper} AIntf and (Length(LTree.Nodes) > 0) and
        (LTree.Nodes[0].Kind = nkUnit), FPlatform);
    finally
      ReturnPP(LPP);
    end;
  except
    on E: Exception do
    begin
      Result := nil;
      AErrClass := E.ClassName;
      AErrMsg := E.Message;
    end;
  end;
end;

function TPasSemaProject.ComputeUpgrade(const ASource: TPasPreprocessed;
  out AErrClass, AErrMsg: string): TPasSemaModel;
var
  LDiags: TArray<TPasParseDiag>;
begin
  // Mirrors UpgradeChunked's worker body: reparse from the SAME token layer
  // (stage 1 preprocessed the whole file; re-preprocessing would double-pay
  // lex+PP and break the prefix invariant against on-disk changes).
  Result := nil;
  AErrClass := '';
  AErrMsg := '';
  try
    Result := TPasSemaResolver.Analyze(
      TPasParser.ParseFile(ASource, LDiags, False), False, FPlatform);
  except
    on E: Exception do
    begin
      Result := nil;
      AErrClass := E.ClassName;
      AErrMsg := E.Message;
    end;
  end;
end;

{ Continuous closure loading — the barrier-free replacement for the
  LoadChunked/DiscoverUses rounds and for UpgradeChunked's slices.

  The chunked drivers held 16 workers at 10-22% busy through the load waves
  (measured on the 3757-unit client corpus): a 64-file slice ends at a
  barrier one straggler holds alone, and between slices the driver thread
  runs discovery while every worker idles. Here instead:

  - N worker tasks pull items from a shared queue and parse OUT OF ORDER;
  - the driver commits results STRICTLY IN QUEUE ORDER (a reorder buffer),
    so model ids stay exactly as deterministic as the chunked loader's;
  - discovery runs on the driver right after each commit, in commit order.
    Committing in queue order makes per-commit discovery concatenate to the
    very same path sequence the old id-ordered DiscoverUses sweep produced —
    which is what keeps the queue, and therefore every model id and every
    downstream report, byte-for-byte reproducible against the old driver;
  - wave-2 upgrades ride the same queue; the item carries a SNAPSHOT of the
    model's token layer, so no worker ever indexes FModels while the
    driver's commits are growing its backing array.

  No Prefetch here: it runs TParallel.&For, and this engine's tasks occupy
  the whole pinned pool for the duration (see ConfigureThreadPool — with
  past-Max injection off that inner For would execute on the driver alone).
  The workers overlap their own I/O with each other's CPU instead. For the
  same reason the FIRST FSM.ResolveUnit of a run must happen before the
  engine starts — it lazily builds the search index with a TParallel.&For of
  its own; every driver's EnsureSystemUnit satisfies this.

  Cancellation: the driver stops committing between items and workers stop
  taking; in-flight parses finish, their results are freed uncommitted, and
  the committed prefix stays published — LoadChunked's exact contract. }
function TPasSemaProject.RunLoadEngine(const ASeedLoads: TArray<string>;
  const ASeedUpgrades: TArray<Integer>; AIntfLoads: Boolean;
  const AAfterCommits: TProc): Boolean;
const
  REPORT_EVERY = 64;
var
  LQueue: TList<TPasLoadItem>;              // guarded by LLock
  LResults: TDictionary<Integer, TPasLoadRes>; // guarded by LLock
  LTake: Integer;                           // guarded by LLock
  LStop: Boolean;                           // guarded by LLock
  LLock: TCriticalSection;
  LWorkEvt, LDoneEvt: TEvent;               // auto-reset kicks; 5 ms fallback
  LTasks: TArray<ITask>;
  LSeen: TDictionary<string, Boolean>;      // driver-only enqueue dedup
  LItem: TPasLoadItem;
  LRes: TPasLoadRes;
  LPair: TPair<Integer, TPasLoadRes>;
  LCommit, LSince, LIdx, LWorkers: Integer;
  LHaveItem, LHaveRes: Boolean;
  LStatus: TPasModuleStatus;

  procedure EnqueueLoad(const APath: string);
  var
    LFull, LKey: string;
    LDummy: Integer;
    LNew: TPasLoadItem;
  begin
    // Same normalize/dedup gate LoadFilesParallel ran per batch.
    LFull := TPath.GetFullPath(APath);
    LKey := LowerCase(LFull);
    if FByPath.TryGetValue(LKey, LDummy) or LSeen.ContainsKey(LKey) then
      Exit;
    if not TFile.Exists(LFull) then
      Exit;
    LSeen.Add(LKey, True);
    LNew := Default(TPasLoadItem);
    LNew.Kind := lkLoad;
    LNew.Path := LFull;
    LNew.Key := LKey;
    LNew.Mid := -1;
    LLock.Enter;
    try
      LQueue.Add(LNew);
    finally
      LLock.Leave;
    end;
    LWorkEvt.SetEvent;
  end;

  procedure EnqueueUpgrade(AMid: Integer);
  var
    LNew: TPasLoadItem;
  begin
    LNew := Default(TPasLoadItem);
    LNew.Kind := lkUpgrade;
    LNew.Mid := AMid;
    LNew.Source := FModels[AMid].Tree.Source;
    LLock.Enter;
    try
      LQueue.Add(LNew);
    finally
      LLock.Leave;
    end;
    LWorkEvt.SetEvent;
  end;

  // The per-model half of the old DiscoverUses sweep, run at commit time.
  procedure DiscoverFrom(AMid: Integer);
  var
    LU: Integer;
    LPath: string;
  begin
    for LU := 0 to High(FModels[AMid].UsesList) do
      if FSM.ResolveUnit(FModels[AMid].UsesList[LU].NameFull,
        FModels[AMid].UsesList[LU].InPath, FFiles[AMid], LPath) then
        EnqueueLoad(LPath);
  end;

begin
  Result := True;
  LQueue := TList<TPasLoadItem>.Create;
  LResults := TDictionary<Integer, TPasLoadRes>.Create;
  LSeen := TDictionary<string, Boolean>.Create;
  LLock := TCriticalSection.Create;
  LWorkEvt := TEvent.Create(nil, False, False, '');
  LDoneEvt := TEvent.Create(nil, False, False, '');
  LTasks := nil;
  LTake := 0;
  LStop := False;
  try
    // Seed order decides model ids, so it replicates the chunked drivers
    // exactly: explicit roots first (they loaded before any discovery), then
    // one discovery sweep over every model committed before this call, in id
    // order — the first round of the old loop.
    for LIdx := 0 to High(ASeedLoads) do
      EnqueueLoad(ASeedLoads[LIdx]);
    for LIdx := 0 to High(ASeedUpgrades) do
      EnqueueUpgrade(ASeedUpgrades[LIdx]);
    if ASeedUpgrades = nil then
      for LIdx := 0 to FModels.Count - 1 do
        DiscoverFrom(LIdx);

    if not FSingleThreaded then
    begin
      LWorkers := TThreadPool.Default.MaxWorkerThreads;
      if LWorkers < 1 then
        LWorkers := 1;
      SetLength(LTasks, LWorkers);
      for LIdx := 0 to LWorkers - 1 do
        LTasks[LIdx] := TTask.Run(
          procedure
          var
            LMine: Integer;
            LIt: TPasLoadItem;
            LR: TPasLoadRes;
            LExit: Boolean;
          begin
            while True do
            begin
              LMine := -1;
              LLock.Enter;
              try
                LExit := LStop;
                if not LExit and (LTake < LQueue.Count) then
                begin
                  LMine := LTake;
                  Inc(LTake);
                  LIt := LQueue[LMine];
                end;
              finally
                LLock.Leave;
              end;
              if LExit then
                Break;
              if LMine < 0 then
              begin
                LWorkEvt.WaitFor(5);
                Continue;
              end;
              LR := Default(TPasLoadRes);
              // A cancelled run turns the rest into no-ops; the driver stops
              // committing at the same check, so this result is never read.
              if not CancelRequested then
                if LIt.Kind = lkLoad then
                  LR.Model := ComputeLoad(LIt.Path, AIntfLoads,
                    LR.ErrClass, LR.ErrMsg)
                else
                  LR.Model := ComputeUpgrade(LIt.Source,
                    LR.ErrClass, LR.ErrMsg);
              LLock.Enter;
              try
                LResults.Add(LMine, LR);
              finally
                LLock.Leave;
              end;
              LDoneEvt.SetEvent;
            end;
          end);
    end;

    LCommit := 0;
    LSince := 0;
    while True do
    begin
      LLock.Enter;
      try
        LHaveItem := LCommit < LQueue.Count;
        if LHaveItem then
          LItem := LQueue[LCommit];
      finally
        LLock.Leave;
      end;
      if not LHaveItem then
        Break;   // drained; only this thread enqueues, so nothing can appear
      if CancelRequested then
      begin
        Result := False;
        Break;
      end;
      if FSingleThreaded then
      begin
        LRes := Default(TPasLoadRes);
        if LItem.Kind = lkLoad then
          LRes.Model := ComputeLoad(LItem.Path, AIntfLoads,
            LRes.ErrClass, LRes.ErrMsg)
        else
          LRes.Model := ComputeUpgrade(LItem.Source,
            LRes.ErrClass, LRes.ErrMsg);
      end
      else
      begin
        // Reorder buffer: wait for THE NEXT queue index, not just any result.
        LHaveRes := False;
        repeat
          LLock.Enter;
          try
            LHaveRes := LResults.TryGetValue(LCommit, LRes);
            if LHaveRes then
              LResults.Remove(LCommit);
          finally
            LLock.Leave;
          end;
          if not LHaveRes then
          begin
            if CancelRequested then
              Break;
            LDoneEvt.WaitFor(5);
          end;
        until LHaveRes;
        if not LHaveRes then
        begin
          Result := False;
          Break;
        end;
      end;

      // Commit — the same registration the chunked loaders made, one item at
      // a time, on this thread only.
      if LItem.Kind = lkLoad then
      begin
        if LRes.Model <> nil then
        begin
          if AIntfLoads and (Length(LRes.Model.Tree.Nodes) > 0) and
             (LRes.Model.Tree.Nodes[0].Kind = nkUnit) then
            LStatus := msIntfReady
          else
            LStatus := msFullReady;
          FByPath.Add(LItem.Key,
            RegisterModel(LRes.Model, LItem.Path, LStatus));
          RegisterUnitName(FModels.Count - 1);
          DiscoverFrom(FModels.Count - 1);
        end
        else
        begin
          FByPath.Add(LItem.Key, -1);
          if LRes.ErrClass <> '' then
            FLoadFailures := FLoadFailures +
              [Format('%s: %s: %s', [TPath.GetFileName(LItem.Path),
                LRes.ErrClass, LRes.ErrMsg])];
        end;
      end
      else
      begin
        if LRes.Model <> nil then
        begin
          // The owns-list assignment frees the interface model here, on the
          // driver — measured at 604 ms across the client's full wave, and
          // deliberately LEFT that way: deferring the frees into a parallel
          // batch after the engine was tried and changed the wall time not
          // at all (the workers overlap the driver's teardown), so the
          // simpler form wins.
          FModels[LItem.Mid] := LRes.Model; // owns-list frees the intf one
          FStatus[LItem.Mid] := msFullReady;
          DiscoverFrom(LItem.Mid);
        end
        else
          // Keep the interface snapshot rather than losing the unit — but
          // SAY SO (UpgradeChunked's contract).
          NoteInternalError(LItem.Mid, 'full-parse',
            LRes.ErrClass, LRes.ErrMsg);
      end;
      Inc(LCommit);
      Inc(LSince);
      if (LSince >= REPORT_EVERY) and Assigned(AAfterCommits) then
      begin
        AAfterCommits();
        LSince := 0;
      end;
    end;
  finally
    LLock.Enter;
    try
      LStop := True;
    finally
      LLock.Leave;
    end;
    if LTasks <> nil then
    begin
      for LIdx := 0 to High(LTasks) do
        LWorkEvt.SetEvent;
      TTask.WaitForAll(LTasks);
    end;
    // A cancelled run leaves computed-but-uncommitted models behind.
    for LPair in LResults do
      LPair.Value.Model.Free;
    LResults.Free;
    LQueue.Free;
    LSeen.Free;
    LWorkEvt.Free;
    LDoneEvt.Free;
    LLock.Free;
  end;
  if Assigned(AAfterCommits) then
    AAfterCommits();
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

{ The generic arity a REFERENCE was written with: the argument count when ANode
  is the HEAD of an `nkTypeArgs` (`TArray<string>` is 1), else 0. Only the head
  counts — an ident sitting INSIDE `<...>` is itself a bare reference, and the
  parser puts the arguments after the head under the same node, so the
  first-child test tells the two apart. Mirror of the resolver's
  IsBareTypeUse + GenericArityOfParamsNode pair, which answers the same
  question for a SAME-unit reference. }
function TPasSemaProject.WrittenArityOfRef(AModel: TPasSemaModel;
  ANode: Integer): Integer;
var
  LParent, LArg: Integer;
begin
  Result := 0;
  LParent := AModel.Tree.Nodes[ANode].Parent;
  if (LParent = NIL_NODE) or
     (AModel.Tree.Nodes[LParent].Kind <> nkTypeArgs) or
     (AModel.Tree.Nodes[LParent].FirstChild <> ANode) then
    Exit;
  LArg := AModel.Tree.Nodes[ANode].NextSibling;
  while LArg <> NIL_NODE do
  begin
    Inc(Result);
    LArg := AModel.Tree.Nodes[LArg].NextSibling;
  end;
end;

{ Arity correction for a CROSS-unit reference, applied where ExtRefMap is
  written — which is also what ctrl+click reads.

  ResolveTypeExpr already matches arity for the TYPE it computes (see its
  nkTypeArgs branch), but that answer never reaches ExtRefMap: the binding
  CrossResolve committed via FindInUses stands, and go-to-declaration follows
  it. `TArray<string>` in a unit that uses System.Generics.Collections is the
  case that proves it — last-uses-wins hands back that unit's arity-0
  `TArray = class`, and the arity-1 `TArray<T> = array of T` in the IMPLICIT
  System unit is never consulted, because ordinary lookup treats the two as
  equals. Arity is part of the identity (16.1.2), so they are not equals.

  Same two places in the same order the type pass uses: the found symbol's own
  overload chain (arities declared in ONE unit link there, and only the head is
  registered under the name), then an arity-restricted scan of the imports plus
  System. A no-op unless the reference is a type whose arity actually
  mismatches, which is rare — the ordinary reference pays one set membership
  and one parent read. }
procedure TPasSemaProject.FixCrossArity(AId: Integer; AModel: TPasSemaModel;
  ANode: Integer; const ANameLower: string; var AUnit, ASym: Integer);
var
  LWant, LProbe, LDepth, LUid, LFound: Integer;
begin
  if FModels[AUnit].Symbols[ASym].Kind <> skType then
    Exit;
  LWant := WrittenArityOfRef(AModel, ANode);
  if ArityOfTypeSym(AUnit, ASym) = LWant then
    Exit;
  LProbe := FModels[AUnit].Symbols[ASym].NextOverload;
  for LDepth := 1 to 32 do
  begin
    if LProbe = NIL_SYM then
      Break;
    if (FModels[AUnit].Symbols[LProbe].Kind = skType) and
       (ArityOfTypeSym(AUnit, LProbe) = LWant) then
    begin
      ASym := LProbe;
      Exit;
    end;
    LProbe := FModels[AUnit].Symbols[LProbe].NextOverload;
  end;
  if FindTypeInUsesArity(AId, ANameLower, LWant, LUid, LFound) then
  begin
    AUnit := LUid;
    ASym := LFound;
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
  LScope, LS, LIdx, LChild: Integer;
  LSyms: TList<Integer>;
  LSawDefault: Boolean;
begin
  LM := FModels[AMid];
  AReq := 0; ATot := 0; AVariadic := False;
  LScope := LM.Symbols[ASym].MemberScope;
  if LScope = NIL_SCOPE then
    Exit(False);
  LSawDefault := False;
  // A lazy nil Symbols list is a recorded-but-empty param scope — a paramless
  // routine, arity 0/0, NOT the "no parameter scope" False above.
  // Index loop, not for-in: this runs per candidate per call site, and a
  // for-in over TList mints a heap enumerator each time (same reasoning as
  // ParamsOf/XParamSyms).
  LSyms := LM.Scopes[LScope].Symbols;
  if LSyms <> nil then
    for LIdx := 0 to LSyms.Count - 1 do
    begin
      LS := LSyms[LIdx];
      if LM.Symbols[LS].Kind = skParam then
      begin
        Inc(ATot);
        if sfHasDefault in LM.Symbols[LS].Flags then
          LSawDefault := True;
        if not LSawDefault then
          Inc(AReq);
      end;
    end;
  LChild := LM.Tree.Nodes[LM.Scopes[LScope].OwnerNode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if (LM.Tree.Nodes[LChild].Kind = nkDirective) and
       LM.Tree.NodeTextEquals(LChild, 'varargs') then
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

// Cross-unit argument-count check: gathers a call's candidate routines from the
// local overload chain PLUS every resolved used unit's interface, then flags
// E2035/E2034 only if no candidate's arity admits the argument count. Runs only
// for units with resolved uses (complete candidate visibility).
procedure TPasSemaProject.CheckCalls(AId: Integer);
type
  // One candidate's arity facts, cached per callee NAME (below).
  TCallArity = record
    Req, Tot: Integer;
    Variadic: Boolean;
  end;
  TSweep = record
    Skip: Boolean;                 // a candidate had no param info -> bail
    Arities: TArray<TCallArity>;
  end;
var
  LModel: TPasSemaModel;
  LNode, LCallee, LArg, LArgCount, LLocalHead, LUid, LS, LIdx: Integer;
  LMinReq, LMaxTot, LStruct: Integer;
  LAnyFit, LAnyVariadic, LHaveAny, LSkip: Boolean;
  LName: string;
  LExt: TPasExtRef;
  // The uses-sweep result depends only on the callee NAME (the uses list is
  // fixed per unit), yet it used to run per CALL NODE — a unit calling
  // `Format` 500 times paid the 40-unit sweep, and RoutineArity per candidate,
  // 500 times. Same cure as SelectCallTarget's UsesHeads memo: one sweep per
  // distinct name per unit, caching each candidate's (Req, Tot, Variadic) —
  // which are symbol invariants — so a repeat call only re-checks the fit
  // against ITS argument count. Worker-local, no locks.
  LSweeps: TDictionary<string, TSweep>;
  LSweep: TSweep;

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

  // Collect one unit's chain of AHead into ASweep (the cache-building
  // counterpart of Consider; fit is NOT computed here — it is per-call).
  procedure Gather(AMid, AHead: Integer; var ASweep: TSweep;
    var ACount: Integer);
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
        ASweep.Skip := True;
        Exit;
      end;
      if ACount = Length(ASweep.Arities) then
        SetLength(ASweep.Arities, ACount * 2 + 4);
      ASweep.Arities[ACount].Req := LReq;
      ASweep.Arities[ACount].Tot := LTot;
      ASweep.Arities[ACount].Variadic := LVariadic;
      Inc(ACount);
      LCand := FModels[AMid].Symbols[LCand].NextOverload;
    end;
  end;

  function SweepFor(const AName: string): TSweep;
  var
    LI, LUnit, LHead, LCount: Integer;
  begin
    Result.Skip := False;
    Result.Arities := nil;
    LCount := 0;
    for LI := 0 to High(LModel.UsesList) do
    begin
      LUnit := LModel.UsesList[LI].UnitId;
      if LUnit < 0 then
        Continue;
      LHead := FModels[LUnit].Resolve(FModels[LUnit].InterfaceScope, AName);
      if (LHead <> NIL_SYM) and
         (FModels[LUnit].Symbols[LHead].Kind = skRoutine) then
        Gather(LUnit, LHead, Result, LCount);
      if Result.Skip then
        Break;
    end;
    SetLength(Result.Arities, LCount);
  end;

begin
  LModel := FModels[AId];
  if (Length(LModel.UsesList) = 0) or not LModel.AllUsesResolved then
    Exit;

  LSweeps := nil;
  try
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

    // Same-named routines from every resolved used unit — through the
    // per-name cache (see LSweeps above).
    if not LSkip then
    begin
      LName := LModel.Tree.NodeNameLower(LCallee);
      if LSweeps = nil then
        LSweeps := TDictionary<string, TSweep>.Create;
      if not LSweeps.TryGetValue(LName, LSweep) then
      begin
        LSweep := SweepFor(LName);
        LSweeps.Add(LName, LSweep);
      end;
      if LSweep.Skip then
        LSkip := True
      else
        for LIdx := 0 to High(LSweep.Arities) do
        begin
          LHaveAny := True;
          if LSweep.Arities[LIdx].Variadic then
            LAnyVariadic := True;
          if LSweep.Arities[LIdx].Req < LMinReq then
            LMinReq := LSweep.Arities[LIdx].Req;
          if LSweep.Arities[LIdx].Tot > LMaxTot then
            LMaxTot := LSweep.Arities[LIdx].Tot;
          if LSweep.Arities[LIdx].Variadic or
             ((LArgCount >= LSweep.Arities[LIdx].Req) and
              (LArgCount <= LSweep.Arities[LIdx].Tot)) then
            LAnyFit := True;
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
  finally
    LSweeps.Free;
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
  LInst: TSemaInstance;
begin
  // The instance record is its own dictionary key — integer hash + compare
  // (TSemaInstanceComparer), no string is built. Args is shared by reference
  // between the key and the stored instance; instances are append-only and
  // never mutated, so the shared array is safe.
  LInst.UnitId := ABase.UnitId;
  LInst.Sym := ABase.Sym;
  LInst.Args := AArgs;
  FInstLock.Enter;
  try
    if FInstKeys.TryGetValue(LInst, Result) then
      Exit;
    Result := FInstances.Add(LInst);
    FInstKeys.Add(LInst, Result);
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

{ The TYPE a generic parameter is constrained to, or XNil when it has no type
  constraint — `F: IInspectable` answers IInspectable, and `T: class` answers
  TObject, because "a reference type" (16 §16.4.1) means one, and dcc agrees:
  `V.Free` and `V.ClassName` compile under a bare `T: class`. The other two kind
  constraints answer nothing, and that is dcc's line too — under `T: record` or
  a lone `T: constructor` the same `V.Free` is `E2003`, all three probed.

  The parameter symbol's DeclNode is its name inside the `nkGenericParam` group,
  so the constraints are that group's `nkConstraint` children; the first one that
  resolves to a type wins, which matches dcc's own "the members you may use are
  the ones the constraint guarantees".

  A method BODY's parameter has no constraints of its own, and that is not a
  parse gap but the language: `procedure TList<T>.Sort;` may not repeat them
  (16 §16.4.1 puts them on the declaration, once). The body is also where nearly
  every use of a constrained parameter lives, so the group is searched first and
  the DECLARING type's same-named parameter second. }
function TPasSemaProject.ConstraintsOfParamX(
  const AParam: TSemaXType): TArray<TSemaXType>;
var
  LM: TPasSemaModel;
  LDecl, LGroup, LStruct, LIdx, LScope, LMethod: Integer;
  LIdents: TArray<Integer>;
  LCons: TArray<TArray<Integer>>;

  { EVERY constraint of AGroup that names a type, in source order. All of
    them, not the first: `TKey: IComparable<TKey>, IEquatable<TKey>,
    IHashable` guarantees the members of all three at once (16 §16.4.1), and
    a utility library calls `AKey.GetHashCode` (the third) and `A.Equals(B)` (the
    second) in adjacent methods. }
  function AllTypeConstraints(
    const ANodes: TArray<Integer>): TArray<TSemaXType>;
  var
    LNode, LRef: Integer;
    LX: TSemaXType;
  begin
    Result := nil;
    for LNode in ANodes do
    begin
      LRef := LM.Tree.Nodes[LNode].FirstChild;
      while LRef <> NIL_NODE do
      begin
        if LM.Tree.Nodes[LRef].Kind in [nkIdent, nkMember, nkTypeArgs] then
        begin
          LX := ResolveTypeExpr(AParam.UnitId, LRef);
          if XValid(LX) then
            Result := Result + [LX];
        end;
        LRef := LM.Tree.Nodes[LRef].NextSibling;
      end;
    end;
  end;

  { A KIND constraint that means "a class", as TObject. A kind constraint
    adopts no child (the parser consumes the keyword), so the node's own text
    is what tells the three apart.

    `constructor` counts for the same reason `class` does, and it is not a
    formality: only a CLASS can satisfy it (16 §16.4.1 — a record has no
    constructor to require), so a `T: constructor` parameter is a class
    parameter that additionally promises a parameterless `Create`.
    `Atomic<I; T: constructor>` in a threading library writes exactly that and
    then `T.Create`, and with only `class` recognised the walk stopped at the
    parameter. `record` is the one kind that must NOT land here.

    Routed through ResolveRealDecl like every other implicit-TObject hop, so
    it finds the real System.pas declaration rather than a seeded stub. }
  function ClassConstraintX(const ANodes: TArray<Integer>): TSemaXType;
  var
    LNode, LRMid, LRSym: Integer;
  begin
    Result := XNil;
    for LNode in ANodes do
      if (LM.Tree.Nodes[LNode].FirstChild = NIL_NODE) and
         (SameText(LM.Tree.NodeText(LNode), 'class') or
          SameText(LM.Tree.NodeText(LNode), 'constructor')) and
         ResolveRealDecl(AParam.UnitId, 'tobject', LRMid, LRSym) then
        Exit(XPlain(LRMid, LRSym));
  end;

  { The named constraints, then TObject when a KIND constraint asks for a
    class. Last, not first: a named type's members are a superset of
    TObject's, so trying it earlier can only find the same names later. }
  function ConstraintList(const ANodes: TArray<Integer>): TArray<TSemaXType>;
  var
    LClass: TSemaXType;
  begin
    Result := AllTypeConstraints(ANodes);
    LClass := ClassConstraintX(ANodes);
    if XValid(LClass) then
      Result := Result + [LClass];
  end;

  function OwnConstraints(AGroup: Integer): TArray<Integer>;
  var
    LNode: Integer;
  begin
    Result := nil;
    LNode := LM.Tree.Nodes[AGroup].FirstChild;
    while LNode <> NIL_NODE do
    begin
      if LM.Tree.Nodes[LNode].Kind = nkConstraint then
        Result := Result + [LNode];
      LNode := LM.Tree.Nodes[LNode].NextSibling;
    end;
  end;

begin
  Result := nil;
  if not XValid(AParam) then
    Exit;
  LM := FModels[AParam.UnitId];
  LDecl := LM.Symbols[AParam.Sym].DeclNode;
  if LDecl = NIL_NODE then
    Exit;
  LGroup := LM.Tree.Nodes[LDecl].Parent;
  if (LGroup = NIL_NODE) or (LM.Tree.Nodes[LGroup].Kind <> nkGenericParam) then
    Exit;
  var LOwn := OwnConstraints(LGroup);
  // A named type outranks the `class` keyword: `T: TItem, class` guarantees
  // TItem's members, which are a superset of TObject's.
  Result := ConstraintList(LOwn);
  if Length(Result) > 0 then
    Exit;
  // Nothing here: this is a method body's `<T>`, and the constraint is on the
  // type. Match by NAME rather than by position — the body may spell the
  // parameters differently from the declaration, and dcc binds them positionally
  // but names them here, so a same-named parameter is the honest link and a
  // renamed one simply finds nothing rather than the wrong constraint.
  // Through the SYMBOL's scope, not the node's: a header's generic-parameter
  // idents are declared into the routine scope but never stamped into
  // NodeScope, so StructSymOfNode has nothing to walk. The routine scope of a
  // QUALIFIED implementation carries StructSym (the resolver sets it there when
  // it binds `TFoo<T>.Bar` to its class), which is exactly the link wanted.
  LStruct := NIL_SYM;
  LScope := LM.Symbols[AParam.Sym].Scope;
  while LScope <> NIL_SCOPE do
  begin
    if LM.Scopes[LScope].StructSym <> NIL_SYM then
    begin
      LStruct := LM.Scopes[LScope].StructSym;
      Break;
    end;
    LScope := LM.Scopes[LScope].Parent;
  end;
  if LStruct = NIL_SYM then
    Exit;
  LIdents := GenericParamIdents(AParam.UnitId, LStruct);
  LCons := GenericParamConstraints(AParam.UnitId, LStruct);
  for LIdx := 0 to High(LIdents) do
    if (LIdx <= High(LCons)) and
       (LM.Tree.NodeNameLower(LIdents[LIdx]) =
        LM.Symbols[AParam.Sym].NameLower) then
    begin
      Result := ConstraintList(LCons[LIdx]);
      Exit;
    end;
  // Still nothing: the parameter belongs to a generic METHOD rather than to the
  // type (16 §16.2.1), so the constraints are on the method's own declaration —
  // `function GetNamedObject<T: TRttiNamedObject>(...)` in System.Rtti's
  // TRttiType, whose body writes a bare `<T>` and then calls `Obj.HasName`.
  // Find the declaration by NAME in the struct's member scope and read its
  // parameters the same way; GenericParamIdents already reads a routine's.
  LMethod := LM.FindLocal(LM.Symbols[LStruct].MemberScope,
    RoutineNameOfParam(AParam.UnitId, LDecl));
  while LMethod <> NIL_SYM do
  begin
    if LM.Symbols[LMethod].Kind = skRoutine then
    begin
      LIdents := GenericParamIdents(AParam.UnitId, LMethod);
      LCons := GenericParamConstraints(AParam.UnitId, LMethod);
      for LIdx := 0 to High(LIdents) do
        if (LIdx <= High(LCons)) and
           (LM.Tree.NodeNameLower(LIdents[LIdx]) =
            LM.Symbols[AParam.Sym].NameLower) then
        begin
          Result := ConstraintList(LCons[LIdx]);
          Exit;
        end;
    end;
    LMethod := LM.Symbols[LMethod].NextOverload;
  end;
  Result := nil;
end;

{ The NAME of the routine whose generic-parameter list ANode sits in, lowered.
  ANode is the parameter's own ident, so the walk is group -> list -> routine,
  and the routine's name may be qualified (`TRttiType.GetNamedObject`) — the
  LAST segment is the method's own name. '' when the shape is anything else. }
function TPasSemaProject.RoutineNameOfParam(AMid, ANode: Integer): string;
var
  LM: TPasSemaModel;
  LGroup, LList, LRoutine, LChild, LName: Integer;
begin
  Result := '';
  LM := FModels[AMid];
  LGroup := LM.Tree.Nodes[ANode].Parent;
  if LGroup = NIL_NODE then
    Exit;
  LList := LM.Tree.Nodes[LGroup].Parent;
  if (LList = NIL_NODE) or
     (LM.Tree.Nodes[LList].Kind <> nkGenericParams) then
    Exit;
  LRoutine := LM.Tree.Nodes[LList].Parent;
  if (LRoutine = NIL_NODE) or (LM.Tree.Nodes[LRoutine].Kind <> nkRoutine) then
    Exit;
  // A qualified implementation name is a FLAT run of nkIdent children —
  // `TFoo`, `Bar` — and each segment may carry its OWN nkGenericParams right
  // after it (`TList<T>.Sort`, `TFinder.Pick<T>`). So the owner of this list is
  // the ident immediately before it, not the first or the last segment: taking
  // the first answered `TFinder` and looked up a method by the class's name.
  LName := NIL_NODE;
  LChild := LM.Tree.Nodes[LRoutine].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if LChild = LList then
      Break;
    if LM.Tree.Nodes[LChild].Kind = nkIdent then
      LName := LChild;
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
  if (LChild <> LList) or (LName = NIL_NODE) then
    Exit;
  Result := LM.Tree.NodeNameLower(LName);
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
  LParamName: string;
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
          // A keyword constraint: class / record / constructor — reserved
          // words, so the token KIND is the test (no text copy).
          LTok := FModels[LBase.UnitId].Tree.Nodes[LC].FirstToken;
          if (LTok < 0) or
             (LTok > High(FModels[LBase.UnitId].Tree.Source.Visible)) then
            Continue;
          if LCat = tcUnknown then
            Continue;   // category not modeled — say nothing
          // NB: qualified kinds — System.TypInfo's TTypeKind also names
          // tkClass/tkRecord and shadows ours in this unit.
          case FModels[LBase.UnitId].Tree.Source.VisibleToken(LTok).Kind of
            PasTree.Types.tkClass:
              if LCat <> tcClass then
                EmitAt(LM, LArgNode, 'E2511',
                  Format(SE2511_MustBeClass, [LParamName]));
            PasTree.Types.tkRecord:
              if not (LCat in VALUE_CATS) then
                EmitAt(LM, LArgNode, 'E2512',
                  Format(SE2512_MustBeValueType, [LParamName]));
          end;
        end;
      end;
      Inc(LIdx);
      LArgNode := LM.Tree.Nodes[LArgNode].NextSibling;
    end;
  end;
end;

// TCustomAttribute itself, resolved from AId's own point of view (its uses
// list, or the implicit System unit -- ResolveRealDecl already tries both,
// same as every other implicit-name lookup in this file). XNil (silently)
// when it cannot be found at all, e.g. a unit with no System unit visible
// on the search paths -- CheckAttributes treats that as "cannot judge",
// not as "everything fails".
function TPasSemaProject.ResolveCustomAttributeX(AId: Integer): TSemaXType;
var
  LRMid, LRSym: Integer;
begin
  if ResolveRealDecl(AId, 'tcustomattribute', LRMid, LRSym) then
    Result := XPlain(LRMid, LRSym)
  else
    Result := XNil;
end;

{ 19.3.1/19.3.3 — an attribute's TypeRef must resolve to a class descending
  from TCustomAttribute. dcc32 37.0 probed first (never guess a diagnostic
  code): `[TObject] TFoo = class end;` and a from-scratch `TNotAnAttr =
  class end; [TNotAnAttr] ...` both give
  `E2010 Incompatible types: '<name>' and 'TCustomAttribute'` — the exact
  SE2010_IncompatibleTypes shape 2.6.1's assignment-compatibility checks
  already use, just fired from a declaration site instead of an assignment.

  Conservative like CheckConstraints, for the same reason: a diagnostic
  pass says nothing the moment it is unsure, rather than guess.
  - TCustomAttribute itself must resolve (ResolveCustomAttributeX) — a unit
    that genuinely cannot see it says nothing at all.
  - The TypeRef must resolve to an actual class (XCatOf = tcClass) — an
    unresolved name already gets its own E2003 elsewhere (or, for a name
    this pass cannot judge at all, nothing), and this must never pile a
    second diagnostic on top of a first one, or invent one for something
    that isn't a class to begin with (an enum, a routine written by
    mistake, ...). }
procedure TPasSemaProject.CheckAttributes(AId: Integer);
var
  LM: TPasSemaModel;
  LCustomAttrX, LAttrX: TSemaXType;
  LNode, LRef: Integer;
begin
  LCustomAttrX := ResolveCustomAttributeX(AId);
  if not XValid(LCustomAttrX) then
    Exit;
  LM := FModels[AId];
  for LNode := 0 to High(LM.Tree.Nodes) do
  begin
    if LM.Tree.Nodes[LNode].Kind <> nkAttribute then
      Continue;
    // A COMPILER-RECOGNIZED attribute (19.3.3) is exempt: dcc matches
    // `[weak]`/`[unsafe]`/`[Ref]`/`[Volatile]` specially rather than looking
    // the name up in scope, so ordinary resolution here means nothing. The
    // parser already tagged them (nkAttribute.Aux, PasAttrMagicAux).
    //
    // Not a nicety — this was 3 false E2010 on a real project. A component
    // suite declares `Unsafe = class // for internal use` (dxCore.pas), so
    // the bare name in `[unsafe] FField: IPalette;` resolves to THAT class;
    // 19.3.1's `+Attribute` fallback never fires, because it only fires when
    // the bare name misses entirely, and System.pas's real
    // `UnsafeAttribute = class(TCustomAttribute)` is therefore never
    // consulted. Exact-name-wins (pinned by 19.3.1's own test) and a
    // magic-attribute name reused as an ordinary class collide exactly here.
    if LM.Tree.Nodes[LNode].Aux <> amaNone then
      Continue;
    LRef := LM.Tree.Nodes[LNode].FirstChild;
    if LRef = NIL_NODE then
      Continue;
    LAttrX := ResolveTypeExpr(AId, LRef);
    if not XValid(LAttrX) then
      Continue;
    if XCatOf(LAttrX) <> tcClass then
      Continue;
    if not XDescendsFrom(LAttrX, LCustomAttrX) then
      EmitAt(LM, LRef, 'E2010', Format(SE2010_IncompatibleTypes,
        [XTypeText(LAttrX), 'TCustomAttribute']));
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
    // Copy-on-write: the stored args are read SHARED (instances are append-
    // only), and the array is copied only when a substitution actually
    // changes an element. When nothing changes the result is the same
    // instance by dedup, so both the Copy and the Instantiate lock round are
    // skipped — the common case on the 126k-call path.
    var LShared := InstanceRead(AX.Inst).Args;
    LArgs := nil;
    for LIdx := 0 to High(LShared) do
    begin
      var LSub := SubstX(LShared[LIdx], AInst, ADepth + 1);
      if (LArgs = nil) and
         ((LSub.UnitId <> LShared[LIdx].UnitId) or
          (LSub.Sym <> LShared[LIdx].Sym) or
          (LSub.Inst <> LShared[LIdx].Inst)) then
        LArgs := Copy(LShared);   // elements before LIdx were unchanged
      if LArgs <> nil then
        LArgs[LIdx] := LSub;
    end;
    if LArgs = nil then
      Result.Inst := AX.Inst
    else
      Result.Inst := Instantiate(XPlain(AX.UnitId, AX.Sym), LArgs);
  end
  // A type DECLARED INSIDE the generic this frame instantiates has no
  // arguments of its own, yet its definition is written in that generic's
  // parameters — so the frame must travel WITH it, or it is lost at exactly
  // the point it is about to be needed.
  //
  // `TList<T>` declares `arrayofT = array of T` as a nested type and returns it
  // from `property List`. `with FSelections.List[I] do` then substitutes the
  // member type over {T := TSelection}, gets back the bare nested-type symbol,
  // indexes it — and the element is the OPEN `T`, because by then nothing knows
  // which instantiation it came from. 78 of 94 diagnostics on one project were
  // that single shape, in two units of the same editor component.
  else if DeclaredWithinX(AX.UnitId, AX.Sym, LInst.UnitId, LInst.Sym) then
    Result.Inst := AInst;
end;

// Is ASym declared inside AOwnerSym's scope, at any nesting depth? Used only by
// SubstX, to tell a nested type of the generic being instantiated from an
// unrelated type that merely happens to be its member's declared type.
function TPasSemaProject.DeclaredWithinX(AMid, ASym,
  AOwnerMid, AOwnerSym: Integer): Boolean;
var
  LScope, LDepth: Integer;
begin
  Result := False;
  if (AMid <> AOwnerMid) or (ASym = NIL_SYM) or (AOwnerSym = NIL_SYM) then
    Exit;
  LScope := FModels[AMid].Symbols[ASym].Scope;
  for LDepth := 1 to 16 do
  begin
    if LScope = NIL_SCOPE then
      Exit;
    if FModels[AMid].Scopes[LScope].StructSym = AOwnerSym then
      Exit(True);
    LScope := FModels[AMid].Scopes[LScope].Parent;
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

  A component suite leans on it: `TBarAccessibilityHelper` is a plain class in
  one unit and `TBarAccessibilityHelper<T: TWinControl>` a generic in
  another, and the latter unit then writes both spellings. Taking
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

{ Is AX a DYNAMIC array, after following aliases? `TBytes` is `TArray<Byte>` is
  `array of T`, so the answer takes a walk rather than a TypeCat test — and the
  distinction from a STATIC array is the whole point: only the dynamic one has
  the pseudo-constructor below. A dimension list makes the array static, so the
  test is "exactly one child, the element type"; `array of const` (Aux = 1) has
  no child at all and is not one either. }
function TPasSemaProject.IsDynArrayTypeX(const AX: TSemaXType): Boolean;
var
  LCur: TSemaXType;
  LDef, LChild, LCount, LDepth, LRMid, LRSym: Integer;
  LM: TPasSemaModel;
begin
  Result := False;
  LCur := AX;
  for LDepth := 1 to 8 do
  begin
    if not XValid(LCur) then
      Exit;
    LM := FModels[LCur.UnitId];
    LDef := TypeDefNodeOf(LCur.UnitId, LCur.Sym);
    if LDef = NIL_NODE then
    begin
      // A SEEDED array type (`TArray`, `TBytes` — PasTree.Sema.Builtins) has no
      // declaration to walk, and every seed of that category is a dynamic
      // array. Answering from the category is also what makes this work in a
      // model that never used System.SysUtils, where the real TBytes is not
      // reachable at all. The redirect below is still tried first for anything
      // else with no def node, the same hop FindMemberX makes for TObject.
      if LM.Symbols[LCur.Sym].TypeCat = tcArray then
        Exit(True);
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
        LCur := ResolveTypeExpr(LCur.UnitId, LDef);   // alias link
      nkArrayType:
        begin
          if LM.Tree.Nodes[LDef].Aux = 1 then
            Exit;
          LCount := 0;
          LChild := LM.Tree.Nodes[LDef].FirstChild;
          while LChild <> NIL_NODE do
          begin
            Inc(LCount);
            LChild := LM.Tree.Nodes[LChild].NextSibling;
          end;
          Exit(LCount = 1);
        end;
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
          // A type ARGUMENT may be a NESTED type named through its outer type
          // (`TDispatchMessageWithValue<TCustomMemoModel.TLineInfo>`, FMX), and
          // nothing binds that last segment this early — the same gap the
          // HERITAGE case has, and the same helper answers it. Reached only
          // after the plain lookup missed, so the common argument pays nothing.
          //
          // Losing one argument loses the whole FRAME (Exit(LBase) below), and
          // with it every member of a field typed by the parameter: 82 of the
          // FMX package's 89 member reports were `Message.Value.<anything>`
          // through exactly this.
          if not XValid(LArg) and
             (LM.Tree.Nodes[LArgNode].Kind = nkMember) then
            LArg := ResolveTypeExprNested(AId, LArgNode);
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

  The lookup is the qualifier's own members and then its ANCESTORS' — a nested
  type is inherited like any other member (11.4.1), and the qualifier need not be
  the class that declares it:

    TTextSettings = class(TALBaseEdit.TDisabledStateStyle.TTextSettings)  // Alcinoe

  where TDisabledStateStyle declares no TTextSettings at all — it comes from its
  own ancestor TBaseStateStyle. Costing three false E2003 on `Create`, because a
  heritage miss leaves the DESCENDANT with no ancestry: TObject's constructor is
  then out of reach and every member the class inherits reads as undeclared.

  Still deliberately NOT FindMemberX: this is called FROM FindMemberX's ancestor
  walk, so `TFoo = class(TFoo.TBar)` — where finding TBar needs TFoo's ancestry,
  which is the very clause being resolved — would recurse until the stack ran
  out. ADepth caps the ancestor hops instead, and only that hop spends it: the
  qualifier recursion below walks to a strictly smaller node and is bounded by
  the chain. }
function TPasSemaProject.ResolveTypeExprNested(AId, ANode: Integer;
  ADepth: Integer): TSemaXType;
var
  LM, LQM: TPasSemaModel;
  LBase, LName, LScope, LFound, LDef, LDepth, LChild: Integer;
  LNameLower: string;
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
  LQ := ResolveTypeExprNested(AId, LBase, ADepth);
  LNameLower := LM.Tree.NodeNameLower(LName);
  // Alias and ancestor hops chased like everywhere else here, depth-capped for a
  // malformed chain rather than a real one.
  for LDepth := 1 to 32 do
  begin
    if not XValid(LQ) then
      Exit;
    LQM := FModels[LQ.UnitId];
    LScope := LQM.Symbols[LQ.Sym].MemberScope;
    if LScope <> NIL_SCOPE then
    begin
      LFound := LQM.FindLocalDeep(LScope, LNameLower);
      if (LFound <> NIL_SYM) and (LQM.Symbols[LFound].Kind = skType) then
        Exit(XPlain(LQ.UnitId, LFound));
    end;
    LDef := TypeDefNodeOf(LQ.UnitId, LQ.Sym);
    if LDef = NIL_NODE then
      Exit;
    case LQM.Tree.Nodes[LDef].Kind of
      nkIdent, nkMember, nkTypeArgs:
        LQ := ResolveTypeExpr(LQ.UnitId, LDef);   // alias link
      nkClassType, nkInterfaceType, nkRecordType, nkObjectType:
        begin
          // Up to the qualifier's ANCESTOR and ask again. The heritage clause is
          // the leading run of type references and the FIRST is the ancestor —
          // the same convention AncestorOfX and FindMemberX use. No heritage
          // clause ends the walk: the implicit TObject/IInterface declare no
          // nested types, so there is nothing there to find.
          if ADepth >= 4 then
            Exit;
          LChild := LQM.Tree.Nodes[LDef].FirstChild;
          while (LChild <> NIL_NODE) and not (LQM.Tree.Nodes[LChild].Kind in
            [nkIdent, nkMember, nkTypeArgs]) do
            LChild := LQM.Tree.Nodes[LChild].NextSibling;
          if LChild = NIL_NODE then
            Exit;
          LQ := ResolveTypeExprNested(LQ.UnitId, LChild, ADepth + 1);
        end;
    else
      Exit;
    end;
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
    same-unit join (JoinHelperScopes) enforces the same order, through a
    scope's Shadowing list — searched before its own names.
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
// Registers AReg as AMid's active helper under every key AMid could reach
// the extended type by. Callers go weakest-precedence first, so a later
// write simply wins. Writes ONLY FHelperIdx[AMid] — phase B farms one worker
// per referring model, so this is the own-slot write discipline every
// parallel pass here follows.
procedure TPasSemaProject.PublishHelper(AMid: Integer;
  const AReg: TPasHelperReg);
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
    // A concrete type is one identity — but it may ALSO be an alias of a
    // builtin, and then it is that builtin's identity too (`TUInt32Helper =
    // record helper for UInt32` in System.Classes, applied to a value declared
    // `Cardinal`; System.pas says `UInt32 = Cardinal`). So both keys go in, and
    // TargetName carries the builtin the alias chain ended at.
    if AReg.TargetUnit <> NIL_SYM then
      Put(AReg.TargetUnit, AReg.TargetSym);
    // ...and under the rest of the alias chain, because the NAME the helper
    // was written against is only one of the type's symbols. SynFunc declares
    // `record helper for TRect` with Winapi.Windows last in its uses, so it
    // registered Winapi's alias; SynEditScrollBars declares `R: TRect` with
    // System.Types in its IMPLEMENTATION uses, so the local carries the
    // canonical symbol — a different key, and every `R.SetTop` came back
    // undeclared while the helper sat right there in scope.
    for var LAlias in AReg.Aliases do
      Put(LAlias.UnitId, LAlias.Sym);
    if AReg.TargetName = '' then
      Exit;
    // Builtin target: re-resolve the NAME in the REFERRING model — its own
    // seeded symbol, plus the real declaration the walk may redirect to
    // (ResolveRealDecl — System.pas's TObject for a seeded TObject). Doing
    // both here is what removes the old hot-path by-name fallback probe.
    //
    // Every name in the ALIAS GROUP, because the seeds are distinct symbols
    // for one type: a helper for Cardinal must answer for a `LongWord` value
    // too, and dcc says so (see PasBuiltinAliasGroup).
    for var LAlias in PasBuiltinAliasGroup(AReg.TargetName) do
    begin
      LBSym := FModels[AMid].Resolve(FModels[AMid].InterfaceScope, LAlias);
      if LBSym <> NIL_SYM then
        Put(AMid, LBSym);
      if ResolveRealDecl(AMid, LAlias, LRMid, LRSym) then
        Put(LRMid, LRSym);
    end;
end;

procedure TPasSemaProject.BuildHelperMap;
var
  LCount: Integer;
begin
  ClearHelperIdx;
  // Same lifetime as the helper index, and for the same reason: every driver
  // that runs the body passes calls this first, and a staged run REPLACES
  // interface-only models with full ones — a worklist held over from a previous
  // run would name nodes of a tree that no longer exists.
  ReleaseCrossWork;
  // Both phases below run PARALLEL workers, and PublishHelper's
  // ResolveRealDecl would APPEND a model on a first-time System load — load
  // it (and SysInit) now, on this thread, so no worker can. The drivers all
  // do this already; repeating it here is a memoized no-op that turns the
  // engine-order assumption into a guarantee.
  EnsureSystemUnit;
  EnsureSysInitUnit;
  LCount := FModels.Count;
  SetLength(FModelHelpers, LCount);
  SetLength(FHelperIdx, LCount);
  // ---- phase A: collect declarations (parallel; each worker scans its own
  // model's symbols and writes only FModelHelpers[mid] — the same own-slot
  // discipline as every pass; ResolveTypeExpr reads other models' frozen
  // Phase-1 state only). This was a SEQUENTIAL sweep over every symbol of
  // every model, and together with phase B it cost a full second of the
  // client run — a fifth of it inside one function, on one core. ----
  ForEachIndex(LCount - 1, 'helpers-collect',
    procedure(AMid: Integer)
    var
      LM: TPasSemaModel;
      LRegs: TArray<TPasHelperReg>;
      LReg: TPasHelperReg;
      LSym, LDef, LRef, LLast, LScope: Integer;
      LExported: Boolean;
      LX: TSemaXType;
    begin
    LM := FModels[AMid];
    LRegs := nil;
    for LSym := 0 to LM.SymCount - 1 do
    begin
      if LM.Symbols[LSym].Kind <> skType then
        Continue;
      LDef := TypeDefNodeOf(AMid, LSym);
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
      LX := ResolveTypeExpr(AMid, LLast);
      if not XValid(LX) then
        Continue;   // target didn't resolve — nothing to inject
      LReg.Aliases := nil;
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
        // ...and, if that named type is an ALIAS chain ending at a builtin,
        // the builtin's name as well: `helper for UInt32` extends Cardinal
        // values, since that is the same type and not a compatible one.
        LReg.TargetName := '';
        var LCanon := LX;
        for var LHop := 1 to 8 do
        begin
          var LCDef := TypeDefNodeOf(LCanon.UnitId, LCanon.Sym);
          if LCDef = NIL_NODE then
            Break;
          if not (FModels[LCanon.UnitId].Tree.Nodes[LCDef].Kind in
             [nkIdent, nkMember]) then
            Break;
          // `T = type Base` (2 §2.5.1) declares a DISTINCT type, and a helper
          // for it is NOT a helper for Base. The parser marks the nkTypeDecl
          // with Aux = 1, which is the whole difference between the two forms
          // here. Missing it cost 17 false reports in one measurement:
          // `TEditMask = type string` with its own helper claimed the `string`
          // key in FMX.MaskEdit and hid TStringHelper, so ordinary
          // `NewText.Substring` stopped resolving — a helper made INACTIVE by
          // registering another one too widely.
          var LCParent := FModels[LCanon.UnitId].Tree.Nodes[LCDef].Parent;
          if (LCParent <> NIL_NODE) and
             (FModels[LCanon.UnitId].Tree.Nodes[LCParent].Kind = nkTypeDecl) and
             (FModels[LCanon.UnitId].Tree.Nodes[LCParent].Aux = 1) then
            Break;
          LCanon := ResolveTypeExpr(LCanon.UnitId, LCDef);
          if not XValid(LCanon) then
            Break;
          // Same type, another symbol — index the helper under it too. Only
          // reached for a PLAIN alias: the `type Base` test above has already
          // broken out of the walk for a distinct type.
          if FModels[LCanon.UnitId].Symbols[LCanon.Sym].Kind <> skBuiltinType
          then
          begin
            var LAliasRef: TPasExtRef;
            LAliasRef.UnitId := LCanon.UnitId;
            LAliasRef.Sym := LCanon.Sym;
            LReg.Aliases := LReg.Aliases + [LAliasRef];
          end;
          if FModels[LCanon.UnitId].Symbols[LCanon.Sym].Kind =
             skBuiltinType then
          begin
            LReg.TargetName :=
              FModels[LCanon.UnitId].Symbols[LCanon.Sym].NameLower;
            Break;
          end;
        end;
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
      LReg.HelperMid := AMid;
      LReg.Sym := LSym;
      LReg.Exported := LExported;
      LRegs := LRegs + [LReg];
    end;
    FModelHelpers[AMid] := LRegs;
    end);
  // ---- phase B: apply precedence, per referring model (parallel; each
  // worker reads phase A's committed FModelHelpers and writes only its own
  // FHelperIdx slot — see PublishHelper). ----
  // Weakest first so a later write wins: used units in `uses` order (a
  // later-listed unit beats an earlier one — dcc-verified last-uses-wins),
  // then the referring unit's OWN helpers (nearest; impl-section ones count
  // here). Within one unit, declaration order, later winning.
  ForEachIndex(LCount - 1, 'helpers-publish',
    procedure(AMid: Integer)
    var
      LU, LUid, LI: Integer;
    begin
      for LU := 0 to High(FModels[AMid].UsesList) do
      begin
        LUid := FModels[AMid].UsesList[LU].UnitId;
        if (LUid < 0) or (LUid >= LCount) then
          Continue;
        for LI := 0 to High(FModelHelpers[LUid]) do
          if FModelHelpers[LUid][LI].Exported then
            PublishHelper(AMid, FModelHelpers[LUid][LI]);
      end;
      for LI := 0 to High(FModelHelpers[AMid]) do
        PublishHelper(AMid, FModelHelpers[AMid][LI]);
    end);
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
  LScope, LFound, LOwn: Integer;
  LAnc: TSemaXType;
begin
  Result := False;
  if (AFromMid < 0) or (AFromMid > High(FHelperIdx)) or
     (FHelperIdx[AFromMid] = nil) then
    Exit;
  if not FHelperIdx[AFromMid].TryGetValue(
       (Int64(ACur.UnitId) shl 32) or Cardinal(ACur.Sym), LExt) then
  begin
    // A BUILTIN type has no single identity: every model SEEDS its own
    // `string`/`Integer`/`Char` symbol (PasTree.Sema.Builtins), so which one a
    // value carries depends on where its type was READ. `S.Trim` on a local
    // works because the local's type is this model's seed and Publish indexed
    // exactly that — but `UpperCase(S).Trim` carries System.SysUtils' seed and
    // `Give(S).Trim` a third unit's, and both missed. That is the whole
    // `TStringHelper`/`TCharHelper` bucket of the member flag: the helper is
    // active, the name is right, and the KEY was a different `string`.
    //
    // So canonicalize to the referring model's own seed and probe once more.
    // Both guards keep this off the hot path: the retry costs a name lookup,
    // and it runs only for a builtin that came from ANOTHER model, after the
    // ordinary probe has already missed.
    if (ACur.UnitId = AFromMid) or
       (FModels[ACur.UnitId].Symbols[ACur.Sym].Kind <> skBuiltinType) then
      Exit;
    LOwn := FModels[AFromMid].Resolve(FModels[AFromMid].SystemScope,
      FModels[ACur.UnitId].Symbols[ACur.Sym].NameLower);
    if (LOwn = NIL_SYM) or
       not FHelperIdx[AFromMid].TryGetValue(
         (Int64(AFromMid) shl 32) or Cardinal(LOwn), LExt) then
      Exit;
  end;
  // The active helper, then ITS OWN ANCESTOR helpers: `class helper (X) for T`
  // (15.3) inherits X's members, and since at most one helper is active per
  // type, the derived one is the ONLY way its ancestor's members can still be
  // reached. A third-party library is exactly this: one of its units declares
  // `TRttiMethodHelper = class helper(Spring.TRttiMethodHelper) for
  // TRttiMethod`, so in any unit that uses BOTH, the active helper is the
  // derived one and `ReturnTypeHandle`/`IsAbstract` live on its ancestor. A
  // unit using only Spring resolved them and one using both did not.
  //
  // Still no recursive FindMemberX — only helper member scopes are read, and
  // the walk is depth-capped, so a malformed helper graph cannot cycle.
  for var LHop := 1 to 8 do
  begin
    LScope := FModels[LExt.UnitId].Symbols[LExt.Sym].MemberScope;
    if LScope = NIL_SCOPE then
      Exit;
    LFound := FModels[LExt.UnitId].FindLocalDeep(LScope, ANameLower);
    if LFound <> NIL_SYM then
    begin
      AMemMid := LExt.UnitId;
      AMemSym := LFound;
      Exit(True);
    end;
    LAnc := HelperAncestorX(LExt.UnitId, LExt.Sym);
    if not XValid(LAnc) or
       ((LAnc.UnitId = LExt.UnitId) and (LAnc.Sym = LExt.Sym)) then
      Exit;
    LExt.UnitId := LAnc.UnitId;
    LExt.Sym := LAnc.Sym;
  end;
end;

{ The ANCESTOR helper of a `class helper (X) for T` declaration, XNil when the
  helper names none. The parser adopts the leading run of type references in
  source order, so with two of them the FIRST is the ancestor and the LAST is
  the extended type — the same run BuildHelperMap reads from the other end. }
function TPasSemaProject.HelperAncestorX(AMid, ASym: Integer): TSemaXType;
var
  LM: TPasSemaModel;
  LDef, LRef, LFirst, LLast: Integer;
begin
  Result := XNil;
  LM := FModels[AMid];
  LDef := TypeDefNodeOf(AMid, ASym);
  if (LDef = NIL_NODE) or (LM.Tree.Nodes[LDef].Kind <> nkHelperType) then
    Exit;
  LFirst := NIL_NODE;
  LLast := NIL_NODE;
  LRef := LM.Tree.Nodes[LDef].FirstChild;
  while (LRef <> NIL_NODE) and
        (LM.Tree.Nodes[LRef].Kind in [nkIdent, nkMember, nkTypeArgs]) do
  begin
    if LFirst = NIL_NODE then
      LFirst := LRef;
    LLast := LRef;
    LRef := LM.Tree.Nodes[LRef].NextSibling;
  end;
  if (LFirst = NIL_NODE) or (LFirst = LLast) then
    Exit;   // only the `for T` target — no helper ancestor
  Result := ResolveTypeExprNested(AMid, LFirst);
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
  out ACtx: Integer; ADepth: Integer): Boolean;
var
  LCur, LNext: TSemaXType;
  LM: TPasSemaModel;
  LScope, LDef, LChild, LDepth, LFound, LRMid, LRSym: Integer;
  LRootName: string;   // the implicit ancestor for a heritage-less struct
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
    if LM.Symbols[LCur.Sym].Kind = skGenericParam then
    begin
      // A value whose type is an UNBOUND type parameter still has the members
      // its CONSTRAINT guarantees (16 §16.4.1): `class var FFactory: F` with
      // `F: IInspectable` reaches `_AddRef` through IInspectable's own
      // IInterface ancestor and through nothing else. The walk used to stop at
      // the parameter, which is 40 false E2003 in System.Win.WinRT alone —
      // every `_AddRef`/`QueryInterface` on one of those factory fields.
      //
      // The parameter's own frame is dropped deliberately: a constraint is
      // written in the DECLARING scope, so the instantiation that bound this
      // parameter says nothing about it.
      //
      // A parameter may carry SEVERAL constraints, and it guarantees the
      // members of ALL of them: `TKey: IComparable<TKey>, IEquatable<TKey>,
      // IHashable` in a utility library means `AKey.GetHashCode` (IHashable) and
      // `A.Equals(B)` (IEquatable) both compile, though neither is on the
      // FIRST constraint. So the extra ones are tried too — after the first,
      // which keeps the single-constraint case (all but a handful) walking
      // exactly as before, and only on a MISS, so the answer is still the
      // first constraint that HAS the name.
      if ADepth >= 4 then
        Exit;   // a constraint naming a parameter naming a constraint...
      for LNext in ConstraintsOfParamX(LCur) do
        if XValid(LNext) and
           not ((LNext.UnitId = LCur.UnitId) and (LNext.Sym = LCur.Sym)) and
           FindMemberX(AFromMid, LNext, ANameLower, AMemMid, AMemSym, ACtx,
             ADepth + 1) then
          Exit(True);
      Exit;
    end;
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
      // A `class constructor` is never what a NAME means: it runs once,
      // automatically, and cannot be called (15 §15.1.5). It is registered
      // under its name like any routine, though, so `TRegistry.Create` — with
      // a private class constructor declared fourteen lines above the public
      // parameterless one — found it and stopped. Advance along the overload
      // chain instead, and when the chain holds nothing else, fall through to
      // the ANCESTOR walk rather than returning it: with a class constructor as
      // a class's only own `Create`, the name means the inherited constructor
      // (`FEngineClass.Create` on TCustomStyleEngine, whose only `Create` is a
      // strict private class one — dcc-probed, it resolves to TObject's).
      //
      // The cost is one Aux read for a member hit that is a routine; the token
      // text is only reached for a `class` routine, which is rare enough.
      while (LFound <> NIL_SYM) and IsClassCtorDtorSym(LCur.UnitId, LFound) do
        LFound := LM.Symbols[LFound].NextOverload;
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
        // Nested-aware, because an alias to another class's NESTED type is
        // written as a dotted name and nothing binds its last segment: no
        // used unit declares `TNotify` — TRESTComponentAdapter does
        // (REST.BindSource), and REST.Client's `TNotify = TRESTComponentAdapter
        // .TNotify` then has no definition at all, so `TNotify.Create` had no
        // members to search. Costs nothing on the common path:
        // ResolveTypeExprNested IS ResolveTypeExpr until that one fails.
        LNext := ResolveTypeExprNested(LCur.UnitId, LDef);   // type alias
      nkPointerType:
        // Implicit dereference in member access: Object Pascal lets `P.Field`
        // stand for `P^.Field` when P is a pointer to a record, and the RTL
        // leans on it constantly (`Entry.Aliases` where Entry:
        // PEnumAliasEntry — System.TypInfo). Follow the pointee and keep
        // looking, so a member lookup on a pointer type behaves like one on
        // what it points at.
        LNext := PointeeX(LCur);
      nkProcType:
        // A PARAMETERLESS FUNCTION reference in a value position is CALLED,
        // and `.Member` then applies to its RESULT: `ValueFunc.GetValue` where
        // `ValueFunc: TFunc<IValue>` means `ValueFunc().GetValue`
        // (System.Bindings.Outputs — the whole VCL package's member tail). The
        // same rule the E2012 guard entry already leans on from the other
        // side, where it exempts procedural types because the guard's type is
        // the RESULT.
        //
        // The frame matters and is why this is a hop rather than a lookup:
        // `TFunc<TResult> = reference to function: TResult` declares the result
        // as a PARAMETER, so it is the instantiation that makes it IValue.
        //
        // A proc type WITH parameters, and a plain `procedure` type with no
        // result, both end the walk instead: neither can be called by writing
        // its name, so neither has members to reach this way.
        LNext := ProcResultX(LCur);
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
            // An INTERFACE has one too — `IInterface` (14.1.1), or `IDispatch`
            // for a dispinterface, which descends from IInterface and so
            // covers strictly more. This was originally left out on the
            // reasoning quoted for the implemented-interface entries above
            // ("their members have to be implemented by the class anyway"),
            // which is true THERE and false here: a value of interface type
            // reaches QueryInterface/_AddRef/_Release through this hop and
            // nothing else. dcc compiles `with I do QueryInterface(G, O)` for
            // a heritage-less `IFoo`; we reported E2003 on it. Found by
            // auditing the spec against the code, not by the corpora — the RTL
            // reaches those three through `Supports`/`as`, never by name.
            //
            // A record/object type genuinely has no implicit ancestor.
            // The (LRMid, LRSym) <> (current) guard is what stops TObject or
            // IInterface itself — which of course have no heritage clause
            // either — from walking into themselves forever.
            LRootName := '';
            case LM.Tree.Nodes[LDef].Kind of
              nkClassType:
                LRootName := 'tobject';
              nkInterfaceType:
                if LM.Tree.Nodes[LDef].Aux = 1 then
                  LRootName := 'idispatch'   // dispinterface
                else
                  LRootName := 'iinterface';
            end;
            if (LRootName <> '') and
               ResolveRealDecl(LCur.UnitId, LRootName, LRMid, LRSym) and
               ((LRMid <> LCur.UnitId) or (LRSym <> LCur.Sym)) then
            begin
              LCur.UnitId := LRMid;
              LCur.Sym := LRSym;
              LCur.Inst := NIL_INST;   // neither root is generic
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

{ FindMemberX's hop loop, enumerating instead of looking up — see the
  interface comment for the contract. Kept as a SEPARATE walk rather than a
  shared iterator on purpose: FindMemberX is on the analysis hot path and a
  callback-per-hop refactor there is exactly the "cheap-looking normalization
  on a shared hot path" this codebase has paid for three times. The two walks
  are pinned together by SemaCompleteSmoke instead (every FindMemberX hit must
  appear in the enumeration). }
procedure TPasSemaProject.EnumMembersX(AFromMid: Integer;
  const ABase: TSemaXType; const AOnMember: TPasMemberEnumProc;
  ADepth: Integer);
var
  LCur, LNext: TSemaXType;
  LM: TPasSemaModel;
  LScope, LDef, LChild, LDepth, LRMid, LRSym, LHop, LOwn: Integer;
  LRootName: string;
  LExt: TPasExtRef;
  LEmitMid, LEmitCtx: Integer;
begin
  LCur := ABase;
  for LDepth := 1 to 32 do
  begin
    if not XValid(LCur) then
      Exit;
    LM := FModels[LCur.UnitId];
    if LM.Symbols[LCur.Sym].Kind = skGenericParam then
    begin
      // The members an unbound parameter guarantees are its constraints'
      // (16 §16.4.1) — all of them, same as FindMemberX tries all on a miss.
      if ADepth >= 4 then
        Exit;
      for LNext in ConstraintsOfParamX(LCur) do
        if XValid(LNext) and
           not ((LNext.UnitId = LCur.UnitId) and (LNext.Sym = LCur.Sym)) then
          EnumMembersX(AFromMid, LNext, AOnMember, ADepth + 1);
      Exit;
    end;
    if not (LM.Symbols[LCur.Sym].Kind in [skType, skBuiltinType]) then
      Exit;
    // The active helper chain for this hop's type, before its own members
    // (a helper member HIDES the type's own — first-wins dedup needs them
    // first). Mirrors HelperMemberHit, including the builtin-seed
    // canonicalization retry.
    if (AFromMid >= 0) and (AFromMid <= High(FHelperIdx)) and
       (FHelperIdx[AFromMid] <> nil) then
    begin
      if not FHelperIdx[AFromMid].TryGetValue(
           (Int64(LCur.UnitId) shl 32) or Cardinal(LCur.Sym), LExt) then
      begin
        LExt.UnitId := NIL_SYM;
        if (LCur.UnitId <> AFromMid) and
           (FModels[LCur.UnitId].Symbols[LCur.Sym].Kind = skBuiltinType) then
        begin
          LOwn := FModels[AFromMid].Resolve(FModels[AFromMid].SystemScope,
            FModels[LCur.UnitId].Symbols[LCur.Sym].NameLower);
          if (LOwn = NIL_SYM) or
             not FHelperIdx[AFromMid].TryGetValue(
               (Int64(AFromMid) shl 32) or Cardinal(LOwn), LExt) then
            LExt.UnitId := NIL_SYM;
        end;
      end;
      if LExt.UnitId <> NIL_SYM then
        for LHop := 1 to 8 do
        begin
          LScope := FModels[LExt.UnitId].Symbols[LExt.Sym].MemberScope;
          if LScope = NIL_SCOPE then
            Break;
          LEmitMid := LExt.UnitId;
          FModels[LEmitMid].EnumScopeDeep(LScope,
            procedure(ASym, AScopeOfSym: Integer)
            begin
              // ACtx NIL_INST, as FindMemberX's helper hit: a helper cannot
              // extend an instantiation.
              if not IsClassCtorDtorSym(LEmitMid, ASym) then
                AOnMember(LEmitMid, ASym, NIL_INST);
            end);
          LNext := HelperAncestorX(LExt.UnitId, LExt.Sym);
          if not XValid(LNext) or
             ((LNext.UnitId = LExt.UnitId) and (LNext.Sym = LExt.Sym)) then
            Break;
          LExt.UnitId := LNext.UnitId;
          LExt.Sym := LNext.Sym;
        end;
    end;
    LScope := LM.Symbols[LCur.Sym].MemberScope;
    if LScope <> NIL_SCOPE then
    begin
      LEmitMid := LCur.UnitId;
      LEmitCtx := LCur.Inst;
      LM.EnumScopeDeep(LScope,
        procedure(ASym, AScopeOfSym: Integer)
        begin
          if not IsClassCtorDtorSym(LEmitMid, ASym) then
            AOnMember(LEmitMid, ASym, LEmitCtx);
        end);
    end;
    LDef := TypeDefNodeOf(LCur.UnitId, LCur.Sym);
    if LDef = NIL_NODE then
    begin
      // Builtin with a real declaration somewhere reachable — redirect, as
      // FindMemberX does (Obj: TObject -> System.pas's real class body).
      if ResolveRealDecl(LCur.UnitId, LM.Symbols[LCur.Sym].NameLower, LRMid,
         LRSym) and ((LRMid <> LCur.UnitId) or (LRSym <> LCur.Sym)) then
      begin
        LCur.UnitId := LRMid;
        LCur.Sym := LRSym;
        Continue;
      end;
      Exit;
    end;
    case LM.Tree.Nodes[LDef].Kind of
      nkIdent, nkMember, nkTypeArgs:
        LNext := ResolveTypeExprNested(LCur.UnitId, LDef);   // type alias
      nkPointerType:
        LNext := PointeeX(LCur);       // implicit deref: P.Field
      nkProcType:
        LNext := ProcResultX(LCur);    // paramless func ref is called
      nkClassOf:
        LNext := ResolveTypeExpr(LCur.UnitId,
          LM.Tree.Nodes[LDef].FirstChild);
      nkClassType, nkInterfaceType, nkRecordType, nkObjectType:
        begin
          LChild := LM.Tree.Nodes[LDef].FirstChild;
          while (LChild <> NIL_NODE) and not (LM.Tree.Nodes[LChild].Kind in
            [nkIdent, nkMember, nkTypeArgs]) do
            LChild := LM.Tree.Nodes[LChild].NextSibling;
          if LChild = NIL_NODE then
          begin
            // Heritage-less: the implicit TObject / IInterface / IDispatch
            // root, exactly as FindMemberX walks it.
            LRootName := '';
            case LM.Tree.Nodes[LDef].Kind of
              nkClassType:
                LRootName := 'tobject';
              nkInterfaceType:
                if LM.Tree.Nodes[LDef].Aux = 1 then
                  LRootName := 'idispatch'
                else
                  LRootName := 'iinterface';
            end;
            if (LRootName <> '') and
               ResolveRealDecl(LCur.UnitId, LRootName, LRMid, LRSym) and
               ((LRMid <> LCur.UnitId) or (LRSym <> LCur.Sym)) then
            begin
              LCur.UnitId := LRMid;
              LCur.Sym := LRSym;
              LCur.Inst := NIL_INST;
              Continue;
            end;
            Exit;
          end;
          LNext := ResolveTypeExprNested(LCur.UnitId, LChild);
        end;
      nkHelperType:
        begin
          // Walk STARTED at a helper (a helper method body's Self): its
          // ancestor helpers' members first, then continue into the extended
          // type — FindMemberX's shape, enumerated.
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
            EnumMembersX(AFromMid,
              ResolveTypeExpr(LCur.UnitId, LRefs[LAncIdx]), AOnMember,
              ADepth + 1);
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
  // `constructor` is a reserved word — the token KIND already says it, no
  // text copy needed (this runs per member hit / per overload candidate).
  if (LTok >= 0) and (LTok <= High(LM.Tree.Source.Visible)) then
    Result :=
      LM.Tree.Source.VisibleToken(LTok).Kind = PasTree.Types.tkConstructor;
end;

{ A `class constructor` / `class destructor` — which is NOT callable at all
  (15 §15.1.5: they run once, automatically, at unit initialization and
  finalization). So they are never overload candidates, and saying so is what
  keeps `TRegistry.Create` off the private `class constructor Create` that sits
  fourteen lines above the public parameterless one it means.

  The `class` keyword is NOT in the routine node's token span — the struct-body
  parser consumes it and then calls ParseRoutine, which records the fact as
  `Aux = 1` instead. So a class constructor's first token is `constructor`, the
  same as an instance one's, and `IsConstructorSym` answers True for both:
  the pair (that answer, Aux) is what separates them, and reading the tokens for
  the `class` would find `constructor` and be wrong. }
function TPasSemaProject.IsClassCtorDtorSym(AMid, ASym: Integer): Boolean;
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
  if (LRoutine = NIL_NODE) or (LM.Tree.Nodes[LRoutine].Kind <> nkRoutine) or
     (LM.Tree.Nodes[LRoutine].Aux <> 1) then
    Exit;   // not a `class` routine at all — the cheap half of the test first
  LTok := LM.Tree.Nodes[LRoutine].FirstToken;
  if (LTok < 0) or (LTok > High(LM.Tree.Source.Visible)) then
    Exit;
  Result := LM.Tree.Source.VisibleToken(LTok).Kind in
    [PasTree.Types.tkConstructor, PasTree.Types.tkDestructor];
end;

// Type category of a cross-model type — the symbol's own TypeCat, computed by
// each model's Phase-1 typer categorization. tcUnknown for an invalid X.
function TPasSemaProject.XCatOf(const AX: TSemaXType): TSemaTypeCat;
begin
  if not XValid(AX) then
    Exit(tcUnknown);
  Result := FModels[AX.UnitId].Symbols[AX.Sym].TypeCat;
end;

// Does the struct definition node ADefNode declare its own `class operator
// Initialize`/`Finalize` (9.4.1's custom managed-record lifecycle, 10.4) —
// walked over the AST directly (head word = 'operator', name = the
// operator's own first child) rather than through the symbol table, since
// Initialize/Finalize are ALSO seeded as global builtin intrinsic routine
// names (PasTree.Sema.Builtins) and this must mean the record's OWN member,
// not that unrelated seed.
function TPasSemaProject.RecordHasLifecycleOp(AMid, ADefNode: Integer):
  Boolean;
var
  LM: TPasSemaModel;
  LChild, LNameChild: Integer;
  LName: string;
begin
  Result := False;
  LM := FModels[AMid];
  LChild := LM.Tree.Nodes[ADefNode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if (LM.Tree.Nodes[LChild].Kind = nkRoutine) and
       SameText(LM.Tree.NodeText(LChild), 'operator') then
    begin
      LNameChild := LM.Tree.Nodes[LChild].FirstChild;
      if LNameChild <> NIL_NODE then
      begin
        LName := LM.Tree.NodeNameLower(LNameChild);
        if (LName = 'initialize') or (LName = 'finalize') then
          Exit(True);
      end;
    end;
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
end;

function TPasSemaProject.IsManagedTypeX(const AX: TSemaXType;
  ADepth: Integer): Boolean;
var
  LM: TPasSemaModel;
  LCanon: TSemaXType;
  LDef, LChild, LLast, LIdx, LScope: Integer;
  LElemX: TSemaXType;
begin
  Result := False;
  if not XValid(AX) or (ADepth > 8) then
    Exit;
  // A plain alias (`type TShortStr = ShortString;`) is its OWN skType
  // symbol with its own name, not the same symbol as its target -- follow
  // it first, or every check below sees the ALIAS's name/shape instead of
  // the real one (caught by TShortStr failing to read as non-managed: its
  // own NameLower is 'tshortstr', not 'shortstring'). CanonTypeX does not
  // follow a `= type X` DISTINCT alias (2.5.1) -- deliberately, for overload
  // identity -- but a distinct alias has the exact same storage/managedness
  // as its target regardless, so that is a harmless, narrow gap here, not a
  // wrong answer worth a second alias-walk just for this.
  LCanon := CanonTypeX(AX);
  if not XValid(LCanon) then
    LCanon := AX;
  LM := FModels[LCanon.UnitId];
  case XCatOf(LCanon) of
    tcString:
      // The one non-managed string: a Turbo-era fixed-size ShortString.
      // Every other seeded string name (string/UnicodeString/AnsiString/
      // WideString/RawByteString/UTF8String) is a real refcounted long
      // string.
      Exit(LM.Symbols[LCanon.Sym].NameLower <> 'shortstring');
    tcInterface, tcVariant:
      Exit(True);
    tcArray:
      begin
        // TArray<T>/TBytes are builtin-seeded dynamic-array ALIASES with no
        // DeclNode of their own (PasTree.Sema.Builtins) -- always managed,
        // and the only builtin names seeded as tcArray, so no name check
        // needed beyond "is this the builtin seed at all".
        if sfBuiltin in LM.Symbols[LCanon.Sym].Flags then
          Exit(True);
        LDef := TypeDefNodeOf(LCanon.UnitId, LCanon.Sym);
        if (LDef = NIL_NODE) or (LM.Tree.Nodes[LDef].Kind <> nkArrayType) or
           (LM.Tree.Nodes[LDef].Aux = 1) then
          Exit;   // Aux=1: `array of const` (6.2.6) -- not a variable type
        LChild := LM.Tree.Nodes[LDef].FirstChild;
        if LChild = NIL_NODE then
          Exit;
        LLast := LChild;
        while LM.Tree.Nodes[LLast].NextSibling <> NIL_NODE do
          LLast := LM.Tree.Nodes[LLast].NextSibling;
        if LLast = LChild then
          // Exactly one child: no dimension bound, so DYNAMIC -- the array
          // value itself is always refcounted, regardless of its element.
          Exit(True);
        // A STATIC array: not refcounted itself, but "managed fields force
        // the enclosing... array to also get finalize codegen" (20.3.1) --
        // so it counts as managed iff its ELEMENT (the last child) is.
        LElemX := ResolveTypeExpr(LCanon.UnitId, LLast);
        Exit(IsManagedTypeX(LElemX, ADepth + 1));
      end;
    tcProc:
      begin
        LDef := TypeDefNodeOf(LCanon.UnitId, LCanon.Sym);
        // Aux=2: `reference to` (17.1). A plain procedural type/pointer
        // (Aux=0) or `of object` (Aux=1) is NOT compiler-managed.
        Exit((LDef <> NIL_NODE) and
          (LM.Tree.Nodes[LDef].Kind = nkProcType) and
          (LM.Tree.Nodes[LDef].Aux = 2));
      end;
    tcRecord:
      begin
        LDef := TypeDefNodeOf(LCanon.UnitId, LCanon.Sym);
        if (LDef = NIL_NODE) or (LM.Tree.Nodes[LDef].Kind <> nkRecordType)
        then
          Exit;
        if RecordHasLifecycleOp(LCanon.UnitId, LDef) then
          Exit(True);
        // No lifecycle operator of its own -- managed iff any OWN field
        // (not inherited; records don't have ancestors) is, recursively.
        // Records don't nest deep enough in practice for ADepth's cap to
        // ever matter here, but a self-referential alias chain elsewhere
        // in the recursion (the array/proc cases above) still needs it.
        LScope := LM.Symbols[LCanon.Sym].MemberScope;
        if LScope = NIL_SCOPE then
          Exit;
        for LIdx := 0 to LM.SymCount - 1 do
          if (LM.Symbols[LIdx].Scope = LScope) and
             (LM.Symbols[LIdx].Kind = skField) then
          begin
            LElemX := DeclTypeX(LCanon.UnitId, LIdx);
            if IsManagedTypeX(LElemX, ADepth + 1) then
              Exit(True);
          end;
      end;
  end;
end;

{ AX with its plain ALIAS links followed to the declaration that actually
  defines the type. `Winapi.Windows.TRect = System.Types.TRect` is one type
  under two symbols, and which one a value carries depends on the unit its
  declaration was read in — the same fact the helper index has to canonicalize
  for. XSameType compares SYMBOLS, so without this an argument typed through
  one name never matches a parameter declared through the other, and a
  three-way overload set (TSize / TPoint / TRect at one arity) is decided by
  declaration order instead of by the argument.

  `T = type Base` is NOT followed: 2 §2.5.1 makes it a distinct type, and the
  parser marks it with Aux = 1 on the nkTypeDecl — the same test BuildHelperMap
  applies for the same reason. }
function TPasSemaProject.CanonTypeX(const AX: TSemaXType): TSemaXType;
var
  LDef, LParent, LDepth: Integer;
  LNext: TSemaXType;
begin
  Result := AX;
  for LDepth := 1 to 8 do
  begin
    if not XValid(Result) then
      Exit;
    LDef := TypeDefNodeOf(Result.UnitId, Result.Sym);
    if (LDef = NIL_NODE) or not (FModels[Result.UnitId].Tree.Nodes[LDef].Kind in
       [nkIdent, nkMember]) then
      Exit;
    LParent := FModels[Result.UnitId].Tree.Nodes[LDef].Parent;
    if (LParent <> NIL_NODE) and
       (FModels[Result.UnitId].Tree.Nodes[LParent].Kind = nkTypeDecl) and
       (FModels[Result.UnitId].Tree.Nodes[LParent].Aux = 1) then
      Exit;   // `type Base` — a distinct type, not an alias
    LNext := ResolveTypeExprNested(Result.UnitId, LDef);
    if not XValid(LNext) or
       ((LNext.UnitId = Result.UnitId) and (LNext.Sym = Result.Sym)) then
      Exit;
    Result := LNext;
  end;
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
  LList: TList<Integer>;
  LIdx, LCount: Integer;
begin
  // Indexed two-pass (count, size once, fill): runs per overload candidate,
  // and both the for-in enumerator and the per-append array copy it replaces
  // were allocations on that path.
  Result := nil;
  LM := FModels[AMid];
  if LM.Symbols[ASym].MemberScope = NIL_SCOPE then
    Exit;
  LList := LM.Scopes[LM.Symbols[ASym].MemberScope].Symbols;
  if LList = nil then
    Exit;   // lazy scope list — never bound
  LCount := 0;
  for LIdx := 0 to LList.Count - 1 do
    if LM.Symbols[LList[LIdx]].Kind = skParam then
      Inc(LCount);
  SetLength(Result, LCount);
  LCount := 0;
  for LIdx := 0 to LList.Count - 1 do
    if LM.Symbols[LList[LIdx]].Kind = skParam then
    begin
      Result[LCount] := LList[LIdx];
      Inc(LCount);
    end;
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

{ 16.5.1's other half — a generic method whose type arguments are WRITTEN at
  the call site: `Unsafe.Cast<TcxCustomTextEdit>(Edit)`. InferMethodFrame reads
  them off the ARGUMENTS, which cannot work here at all: `Cast<T: class>
  (AObject: TObject): T` declares every parameter concretely, so nothing binds
  T and the frame fails — leaving the call typed as the OPEN parameter, and
  every member after it undeclared. A suite's `Unsafe` trio (Cast /
  CastWithNilCheck / AccessProtected) is the shape at scale, and `TJSONObject
  .GetValue<TJSONObject>(...)` is the same thing in the RTL.

  The written list wins outright when it is present and complete — inference
  exists only to supply what was NOT written, and 16.5.1 does not mix the two:
  a partial list is an error at the call, not a hint. So a count mismatch
  returns NIL_INST and the caller falls back, rather than instantiating a frame
  that is positionally wrong.

  Type arguments are resolved in the CALLER's model (AId), where they are
  written; the frame is keyed on the callee's routine symbol, exactly as
  InferMethodFrame's is. }
function TPasSemaProject.ExplicitMethodFrame(AId, AMid, ASym, ATypeArgs,
  ACtx: Integer): Integer;
var
  LM: TPasSemaModel;
  LIdents: TArray<Integer>;
  LArgs: TArray<TSemaXType>;
  LNode: Integer;
  LX: TSemaXType;
begin
  Result := NIL_INST;
  LIdents := GenericParamIdents(AMid, ASym);
  if Length(LIdents) = 0 then
    Exit;   // not a generic method
  LM := FModels[AId];
  // The first child is the callee designator; the rest are the arguments.
  LNode := LM.Tree.Nodes[LM.Tree.Nodes[ATypeArgs].FirstChild].NextSibling;
  while LNode <> NIL_NODE do
  begin
    LX := ResolveTypeExpr(AId, LNode);
    if not XValid(LX) then
      Exit;   // an unresolvable argument makes the whole frame a guess
    // Written inside a generic's own body the argument can itself be an open
    // parameter (`Cast<T>` in a method of `TFoo<T>`); close it over the
    // enclosing frame first, the same order InferMethodFrame uses.
    LArgs := LArgs + [SubstX(LX, ACtx, 0)];
    LNode := LM.Tree.Nodes[LNode].NextSibling;
  end;
  if Length(LArgs) <> Length(LIdents) then
    Exit;
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
         (LX.Inst <> NIL_INST) or
         // A same-unit binding to a GENERIC, from a BARE reference, is the one
         // intra-unit answer worth overriding: arity is part of a type's
         // identity (16.1.2), and the resolver's own arity rule can only see
         // this unit — the non-generic of that name usually lives in a USED
         // one, which is where PreferNonGeneric has already looked by now.
         // `FCollectionEnumerator: TCollectionEnumerator` declared INSIDE
         // `TCollectionEnumerator<T>` is the shape (Data.Bind.Components): it
         // bound to the enclosing generic, and `.GetCurrent` — System.Classes'
         // — went undeclared.
         (IsGenericTypeSym(AId, LM.Symbols[LSym].TypeSym) and
          not ((LX.UnitId = AId) and (LX.Sym = LM.Symbols[LSym].TypeSym)))) then
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

  { Is N a bare designator naming a PROCEDURE — a routine with no result?

    Such an argument is a method VALUE and nothing else. It cannot be the
    implicit call that lets a procedural argument meet an ordinary parameter
    (that rule needs a FUNCTION and its result), so it rejects a non-procedural
    parameter exactly as an anonymous-method literal does. `TThread
    .Synchronize(nil, DoProvide)` in System.Net.URLClient is the shape: without
    this, the private `(ASyncRec: PSynchronizeRecord; QueueEvent: Boolean =
    False; ...)` still ties on arity with the public `(const AThread: TThread;
    AMethod: TThreadMethod)`.

    A CALL is not a designator — `F(X)` has an nkCall parent — so the test is on
    the node kind first, and a routine symbol with a TypeNode (a function) is
    excluded. }
  function IsProcedureDesignator(N: Integer): Boolean;
  var
    LSym, LName: Integer;
    LExt: TPasExtRef;
  begin
    Result := False;
    if not (LM.Tree.Nodes[N].Kind in [nkIdent, nkMember]) then
      Exit;
    LName := N;
    if LM.Tree.Nodes[N].Kind = nkMember then
    begin
      LName := LM.Tree.Nodes[N].FirstChild;
      while (LName <> NIL_NODE) and
            (LM.Tree.Nodes[LName].NextSibling <> NIL_NODE) do
        LName := LM.Tree.Nodes[LName].NextSibling;
      if LName = NIL_NODE then
        Exit;
    end;
    LSym := LM.RefMap[LName];
    if LSym <> NIL_SYM then
      Result := (LM.Symbols[LSym].Kind = skRoutine) and
                (LM.Symbols[LSym].TypeNode = NIL_NODE)
    else if ExtOf(LName, LExt) then
      Result := (FModels[LExt.UnitId].Symbols[LExt.Sym].Kind = skRoutine) and
                (FModels[LExt.UnitId].Symbols[LExt.Sym].TypeNode = NIL_NODE);
  end;

  // Does N name a TYPE rather than a value? Same question SelectCallTarget's
  // own class-vs-instance test asks, and the same two maps answer it.
  function IsTypeDesignator(N: Integer): Boolean;
  var
    LSym: Integer;
    LExt: TPasExtRef;
  begin
    // `TArray<TGUID>` names a type by construction and binds no symbol of its
    // own — neither map has anything for the nkTypeArgs node itself.
    if LM.Tree.Nodes[N].Kind = nkTypeArgs then
      Exit(True);
    // A DOTTED name binds on its last segment, never on the nkMember node —
    // `TObjectAppearance.TDataMembers.Create(...)` (FMX.ListView.Appearances,
    // where that nested name is an alias of `TArray<TDataMember>`) reads as a
    // value qualifier without this, and the dynamic-array pseudo-constructor
    // then does not apply. Same shape SelectCallTarget's own qualifier test
    // had to learn for `System.TMonitor.Enter`.
    if LM.Tree.Nodes[N].Kind = nkMember then
    begin
      N := LM.Tree.Nodes[N].FirstChild;
      while (N <> NIL_NODE) and (LM.Tree.Nodes[N].NextSibling <> NIL_NODE) do
        N := LM.Tree.Nodes[N].NextSibling;
      if N = NIL_NODE then
        Exit(False);
    end;
    LSym := LM.RefMap[N];
    if LSym <> NIL_SYM then
      Exit(LM.Symbols[LSym].Kind in [skType, skBuiltinType]);
    Result := ExtOf(N, LExt) and
      (FModels[LExt.UnitId].Symbols[LExt.Sym].Kind in [skType, skBuiltinType]);
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
  { Does AX's type declare a conversion operator — the one thing that can make
    a value of another record type acceptable where AX is wanted (`class
    operator Implicit`/`Explicit`, 6 §6.7)? Only the type's OWN members are
    read: an operator is not inherited. }
  function HasConversionOperator(const AX: TSemaXType): Boolean;
  var
    LScope: Integer;
  begin
    Result := False;
    if not XValid(AX) then
      Exit;
    LScope := FModels[AX.UnitId].Symbols[AX.Sym].MemberScope;
    if LScope = NIL_SCOPE then
      Exit;
    Result := (FModels[AX.UnitId].FindLocal(LScope, 'implicit') <> NIL_SYM) or
              (FModels[AX.UnitId].FindLocal(LScope, 'explicit') <> NIL_SYM);
  end;

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
      // An ANONYMOUS METHOD LITERAL rejects the candidate outright, and it is
      // the only mismatch that does. `TThread.Synchronize(nil, procedure ...
      // end)` fits BOTH the public `(const AThread: TThread; AThreadProc:
      // TThreadProcedure)` and the PRIVATE `(ASyncRec: PSynchronizeRecord;
      // QueueEvent: Boolean = False; ForceQueue: Boolean = False)` on arity,
      // `nil` scores the same against either first parameter, and the first
      // candidate — the private one — won the tie. 41 of bigflat's 111 false
      // E2361 came from that single pair.
      //
      // Deliberately SYNTACTIC and not a general type-mismatch rejection. A
      // written-out `procedure ... end` is a value of procedural type and
      // nothing else, so this is provable at the node; a general "the types do
      // not fit" rule is not, and would have to answer for record `Implicit`
      // operators, Variant, untyped parameters, and the rule that a
      // PARAMETERLESS function reference in a value position is CALLED (which
      // is why a tcProc argument in general may legitimately meet a Boolean
      // parameter — see the E2012 entry). A literal cannot be called that way.
      if XValid(LParX) and
         not (XCatOf(LParX) in [tcProc, tcVariant, tcUnknown]) and
         (FModels[LParX.UnitId].Symbols[LParX.Sym].Kind <> skGenericParam) and
         ((LM.Tree.Nodes[LArg].Kind = nkAnonMethod) or
          IsProcedureDesignator(LArg)) then
        Exit(-1);
      if XValid(LArgX) and XValid(LParX) then
        if XSameType(LParX, LArgX) then
          Inc(Result, 2)
        else
        begin
          // Not the same SYMBOL — but it may still be the same TYPE reached
          // through an alias, and the two sides are read in different units
          // by construction. `LayoutUnitsToPixels` in
          // dxDocumentLayoutUnitConverter is declared for TSize, TPoint and
          // TRect at one arity; a TRect argument matched none of them by
          // symbol, all three scored 0, and the FIRST — TSize — won the tie.
          // The call then typed as TSize: a wrong binding that costs no
          // diagnostic until something reads a member off it (`.ToRectF` in
          // a suite's ruler unit). Canonicalized only after the cheap test has
          // already failed.
          var LCanonPar := CanonTypeX(LParX);
          var LCanonArg := CanonTypeX(LArgX);
          if XSameType(LCanonPar, LCanonArg) then
            Inc(Result, 2)
          // Two DIFFERENT record types REJECT the candidate. The general
          // "the types do not fit" rule is still not attempted (see the note
          // above), but this corner of it is decidable: distinct records are
          // not assignable to one another, and the one thing that could make
          // them so — a `class operator Implicit`/`Explicit` on either side —
          // is a MEMBER, so it can be looked for.
          else if (XCatOf(LCanonPar) = tcRecord) and
                  (XCatOf(LCanonArg) = tcRecord) and
                  not HasConversionOperator(LCanonPar) and
                  not HasConversionOperator(LCanonArg) then
            Exit(-1)
          // An ARRAY parameter against a record/class/interface argument (or
          // the reverse) is the same kind of decidable mismatch, and it matters
          // because a binding stops at the FIRST declaration of a name: a
          // derived interface that declares only the `TArray<T>` overload of a
          // method and INHERITS the single-item one leaves the array overload
          // as the only candidate, fitting on arity, typing the call as
          // `TArray<...>`. Rejecting it is what lets the "nothing in the
          // type's own chain fits, so this means an INHERITED routine"
          // fallback do its job. `nil` and untyped arguments never reach here
          // — they are tcNil/tcUnknown, not these three.
          else if ((XCatOf(LCanonPar) = tcArray) and
                   (XCatOf(LCanonArg) in [tcRecord, tcClass, tcInterface]) and
                   not HasConversionOperator(LCanonArg)) or
                  ((XCatOf(LCanonArg) = tcArray) and
                   (XCatOf(LCanonPar) in [tcRecord, tcClass, tcInterface]) and
                   not HasConversionOperator(LCanonPar)) then
            Exit(-1)
          else if XAssignableX(LParX, LArgX) then
            Inc(Result, 1);
        end;
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
    LSeen: TArray<TPasExtRef>;   // count-tracked (LSeenCount), capacity slack
    LSeenCount: Integer;
    LBestScore: Integer;
    LTypeQualified: Boolean;

    // A `class` method — the parser marks the declaration with Aux = 1 (6.1), so
    // this reads the fact rather than re-deriving it. A CONSTRUCTOR counts too:
    // `TFoo.Create(...)` is the ordinary way to call one.
    function CallableOnType(AMid, ACand: Integer): Boolean;
    var
      LDecl, LParent: Integer;
    begin
      if IsConstructorSym(AMid, ACand) then
        Exit(True);
      Result := False;
      LDecl := FModels[AMid].Symbols[ACand].DeclNode;
      if LDecl = NIL_NODE then
        Exit;
      LParent := FModels[AMid].Tree.Nodes[LDecl].Parent;
      Result := (LParent <> NIL_NODE) and
        (FModels[AMid].Tree.Nodes[LParent].Kind = nkRoutine) and
        (FModels[AMid].Tree.Nodes[LParent].Aux = 1);
    end;

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
        // Never a candidate, whatever it scores: a class constructor runs
        // automatically and cannot be called (15 §15.1.5). `TRegistry.Create`
        // is the shape — a private `class constructor Create` declared above
        // the public parameterless `constructor Create`, both fitting zero
        // arguments, and the first candidate winning the tie.
        if IsClassCtorDtorSym(AMid, LCand) then
        begin
          LCand := FModels[AMid].Symbols[LCand].NextOverload;
          Continue;
        end;
        LDup := False;
        for LIdx := 0 to LSeenCount - 1 do
          if (LSeen[LIdx].UnitId = AMid) and (LSeen[LIdx].Sym = LCand) then
          begin
            LDup := True;
            Break;
          end;
        if not LDup then
        begin
          LRef.UnitId := AMid;
          LRef.Sym := LCand;
          if LSeenCount = Length(LSeen) then
            SetLength(LSeen, LSeenCount * 2 + 8);
          LSeen[LSeenCount] := LRef;
          Inc(LSeenCount);
          if LTypeQualified and not CallableOnType(AMid, LCand) then
            LScore := -1   // an instance method, reached through the TYPE
          else
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
    LIdx, LQBase, LQSym: Integer;
    LQExt: TPasExtRef;
  begin
    LSeen := nil;
    LSeenCount := 0;
    LBestScore := -1;
    ABestMid := -1;
    ABestSym := NIL_SYM;
    // Is the callee qualified by a TYPE (`TMonitor.Enter(X)`) rather than by a
    // value? Then an INSTANCE method is not a candidate at all, and that is the
    // only thing separating some overload pairs: System's TMonitor declares a
    // PRIVATE instance `function Enter(Timeout: Cardinal): Boolean` beside the
    // public `class procedure Enter(const AObject: TObject)`, same arity, so
    // argument scores decide nothing whenever the argument's own type is
    // unknown — and the first candidate, the private one, used to win. 150
    // false E2361 on bigflat came from this pair alone.
    LTypeQualified := False;
    if LM.Tree.Nodes[ACalleeNode].Kind = nkMember then
    begin
      LQBase := LM.Tree.Nodes[ACalleeNode].FirstChild;
      // A qualifier may itself be dotted — `System.TMonitor.Enter(X)` writes the
      // type as UNIT.TYPE, so the base is another nkMember and neither map has
      // anything for that node. Its LAST segment is the type name, and reading
      // it is what keeps the class-vs-instance rule working there: without this
      // the private instance `function Enter(Timeout: Cardinal): Boolean` was a
      // candidate again, and its arity tied with the public class procedure.
      // System.Types and Vcl.Controls both spell it that way.
      if (LQBase <> NIL_NODE) and (LM.Tree.Nodes[LQBase].Kind = nkMember) then
      begin
        LQSym := LM.Tree.Nodes[LQBase].FirstChild;
        while (LQSym <> NIL_NODE) and
              (LM.Tree.Nodes[LQSym].NextSibling <> NIL_NODE) do
          LQSym := LM.Tree.Nodes[LQSym].NextSibling;
        if LQSym <> NIL_NODE then
          LQBase := LQSym;
      end;
      if LQBase <> NIL_NODE then
      begin
        LQSym := LM.RefMap[LQBase];
        if LQSym <> NIL_SYM then
          LTypeQualified := LM.Symbols[LQSym].Kind in [skType, skBuiltinType]
        else if LM.ExtRefMap.TryGetValue(LQBase, LQExt) then
          LTypeQualified := FModels[LQExt.UnitId].Symbols[LQExt.Sym].Kind in
            [skType, skBuiltinType];
      end;
    end;
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
    // Nothing in the type's OWN chain fits, so the call means an INHERITED
    // routine of that name — `TButton.Create(Self)`, where Vcl.StdCtrls'
    // TButton declares only a parameterless `class constructor Create` and the
    // one being called is TComponent's `constructor Create(AOwner:
    // TComponent)`. A binding stops at the first declaration of the name, so
    // the ancestor's overloads were never candidates and the head stood: the
    // maps then said `TButton.Create`, and the visibility check believed them
    // (7 false E2361 on bigflat, plus TRegistry/TEdit/TBluetoothManager).
    //
    // Only when nothing fit, which keeps it off the common path entirely: one
    // FindMemberX from the owner's ANCESTOR, which walks the whole ancestry
    // itself. A class constructor is not callable at all (15 §15.1.5), so this
    // is also what stops the analyzer from believing it is.
    if (ABestSym = NIL_SYM) and (FModels[AHeadMid].Symbols[AHeadSym].Scope <>
       NIL_SCOPE) then
    begin
      LQBase := FModels[AHeadMid].Scopes[
        FModels[AHeadMid].Symbols[AHeadSym].Scope].StructSym;
      if LQBase <> NIL_SYM then
      begin
        var LAnc := AncestorOfX(XPlain(AHeadMid, LQBase));
        var LAMid, LASym, LACtx: Integer;
        if XValid(LAnc) and FindMemberX(AId, LAnc,
             FModels[AHeadMid].Symbols[AHeadSym].NameLower,
             LAMid, LASym, LACtx) and
           (FModels[LAMid].Symbols[LASym].Kind = skRoutine) then
          ConsiderChain(LAMid, LASym);
      end;
    end;
    Result := ABestSym <> NIL_SYM;
  end;

  { Moves (AMid, ASym) off a routine that cannot be what `Name<...>` means —
    one whose own generic-parameter count does not match the ARGUMENTS
    written — onto the ancestor's declaration that does. Walks up the owner's
    ancestry, since the member lookup that produced ASym stopped at the first
    hit; leaves the pair untouched when the ancestry offers nothing better,
    which keeps a genuinely unmatched call typed exactly as it was. }
  procedure RetargetToGeneric(ATypeArgs: Integer; var AMid, ASym: Integer);
  var
    LWanted, LOwner, LMemMid, LMemSym, LCtx, LNode: Integer;
    LCur: TSemaXType;
    LNameLower: string;
  begin
    LWanted := 0;
    LNode := LM.Tree.Nodes[LM.Tree.Nodes[ATypeArgs].FirstChild].NextSibling;
    while LNode <> NIL_NODE do
    begin
      Inc(LWanted);
      LNode := LM.Tree.Nodes[LNode].NextSibling;
    end;
    if Length(GenericParamIdents(AMid, ASym)) = LWanted then
      Exit;
    LNameLower := FModels[AMid].Symbols[ASym].NameLower;
    // The candidate moves; AMid/ASym only change once something MATCHES, so a
    // walk that ends in nothing leaves the call exactly as it found it.
    LMemMid := AMid;
    LMemSym := ASym;
    for var LHop := 1 to 8 do
    begin
      if FModels[LMemMid].Symbols[LMemSym].Scope = NIL_SCOPE then
        Exit;
      LOwner := FModels[LMemMid].Scopes[
        FModels[LMemMid].Symbols[LMemSym].Scope].StructSym;
      if LOwner = NIL_SYM then
        Exit;
      LCur := AncestorOfX(XPlain(LMemMid, LOwner));
      if not XValid(LCur) then
        Exit;
      if not FindMemberX(AId, LCur, LNameLower, LMemMid, LMemSym, LCtx) then
        Exit;
      if FModels[LMemMid].Symbols[LMemSym].Kind <> skRoutine then
        Exit;
      if Length(GenericParamIdents(LMemMid, LMemSym)) = LWanted then
      begin
        AMid := LMemMid;
        ASym := LMemSym;
        Exit;
      end;
    end;
  end;

  { Is N the BASE of a member access — `Add` in `Add.Assign(X)`? Then its
    value is what the dot applies to. A callee (`Add(X)`) is an nkCall child,
    not an nkMember base, so it is excluded by construction. }
  function IsValueQualifier(N: Integer): Boolean;
  var
    LParent: Integer;
  begin
    LParent := LM.Tree.Nodes[N].Parent;
    Result := (LParent <> NIL_NODE) and
              (LM.Tree.Nodes[LParent].Kind = nkMember) and
              (LM.Tree.Nodes[LParent].FirstChild = N);
  end;

  { Re-points N from an overload that TAKES parameters to the parameterless
    one of the same name on the enclosing struct's chain, when there is one.
    A no-op otherwise — including for every ordinary name, which is what keeps
    this off the hot path: the bound symbol must already be a routine with
    parameters before anything is searched. }
  procedure PreferParamlessOverload(N: Integer);
  var
    LBound, LStruct, LMemMid, LMemSym, LCtx: Integer;
    LExt: TPasExtRef;
  begin
    LBound := LM.RefMap[N];
    if LBound = NIL_SYM then
      Exit;
    if (LM.Symbols[LBound].Kind <> skRoutine) or
       not RoutineHasParams(AId, LBound) then
      Exit;
    LStruct := StructSymOfNode(LM, N);
    if LStruct = NIL_SYM then
      Exit;
    if not ParamlessOverloadX(XPlain(AId, LStruct),
         LM.Symbols[LBound].NameLower, LMemMid, LMemSym, LCtx) then
      Exit;
    if LMemMid = AId then
      LM.RefMap[N] := LMemSym
    else
    begin
      LM.RefMap[N] := NIL_SYM;
      LExt.UnitId := LMemMid;
      LExt.Sym := LMemSym;
      LNewExt.AddOrSetValue(N, LExt);
    end;
    LCtxOf[N] := LCtx;
  end;

  { Is N the NAME an `inherited` designator starts with — the `Alignment` of
    `inherited Alignment.Horz`, the `Create` of `inherited Create(X)`? The
    parser hangs the whole selector chain under one nkInherited (see
    ParseSelectors at tkInherited), so the head is reached by walking up the
    base-child links and finding nkInherited at the top. }
  function IsInheritedHead(N: Integer): Boolean;
  var
    LParent: Integer;
  begin
    LParent := LM.Tree.Nodes[N].Parent;
    while (LParent <> NIL_NODE) and
          (LM.Tree.Nodes[LParent].Kind in [nkMember, nkCall, nkIndex]) and
          (LM.Tree.Nodes[LParent].FirstChild = N) do
    begin
      N := LParent;
      LParent := LM.Tree.Nodes[LParent].Parent;
    end;
    Result := (LParent <> NIL_NODE) and
              (LM.Tree.Nodes[LParent].Kind = nkInherited) and
              (LM.Tree.Nodes[LParent].FirstChild = N);
  end;

  { Re-points an inherited head at the ANCESTOR's member of that name. Leaves
    the node alone when the enclosing struct has no ancestry, or the ancestry
    has no such name — the existing binding is then still the best guess. }
  procedure ResolveInheritedHead(N: Integer);
  var
    LStruct, LMemMid, LMemSym, LCtx: Integer;
    LAnc: TSemaXType;
    LExt: TPasExtRef;
  begin
    LStruct := StructSymOfNode(LM, N);
    if LStruct = NIL_SYM then
      Exit;
    LAnc := AncestorOfX(XPlain(AId, LStruct));
    if not XValid(LAnc) then
      Exit;
    if not FindMemberX(AId, LAnc, LM.Tree.NodeNameLower(N),
         LMemMid, LMemSym, LCtx) then
      Exit;
    if LMemMid = AId then
      LM.RefMap[N] := LMemSym
    else
    begin
      // The cross-model binding is the one that must be READ, so the local
      // one has to go: the typing below prefers RefMap over ExtRefMap.
      LM.RefMap[N] := NIL_SYM;
      LExt.UnitId := LMemMid;
      LExt.Sym := LMemSym;
      LNewExt.AddOrSetValue(N, LExt);
    end;
    LCtxOf[N] := LCtx;
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
          // 12.1.2: the name at the head of an `inherited` designator is a
          // member of the ANCESTOR, whatever the class itself declares. The
          // inherited pass only retries names that bound NOWHERE, so a
          // REDECLARED name never reached it — it bound to the class's own
          // member and typed as that. `inherited Alignment.Horz` in
          // two editor units of one suite are the shape at its sharpest: the derived
          // `Alignment` is a TAlignment (an enum) while the ancestor's is a
          // TcxEditAlignment object, so the chain after it lost every member.
          //
          // Off the hot path by construction — the test is one parent-kind
          // check per identifier, and the ancestor walk runs only for the head
          // of an actual inherited chain. A name the ancestry does NOT have
          // keeps whatever it already bound to (error-tolerant: this pass
          // corrects bindings, it does not invent diagnostics).
          if IsInheritedHead(N) then
            ResolveInheritedHead(N);
          // A bare name used as a QUALIFIER is a value, so an overloaded
          // routine of that name means the PARAMETERLESS overload — writing
          // its name calls it (6 §6.6.1). A binding stops at the first
          // declaration, and an RPC library declares `function Add(anEntity): Integer`
          // ahead of `function Add: TRODLEntity`, so `Add.Assign(...)` typed
          // as Integer and lost the member. Restricted to a qualifier
          // position: as a CALLEE the name is the whole overload set and
          // SelectCallTarget picks from it by arguments.
          if IsValueQualifier(N) then
            PreferParamlessOverload(N);
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
            end
          // `Self` (11.3.3) has NO symbol — nothing declares it, so both maps
          // above are empty for it and its type has to come from the enclosing
          // struct instead, exactly as WithTargetTypeX already does for
          // `with Self.X do`. Without this the nkMember branch below sees an
          // invalid qualifier type, never runs FindMemberX, and the member in
          // `Self.FX` stays unbound — navigation and every RefMap consumer
          // lose it, even though the bare `FX` spelling right beside it binds
          // fine. Costs nothing on the hot path: guarded by RefMap and
          // ExtRefMap both having missed, which for an ordinary identifier
          // they do not.
          else if LM.Tree.NodeTextEquals(N, 'Self') then
          begin
            LSym := StructSymOfNode(LM, N);
            if LSym <> NIL_SYM then
              LX[N] := XPlain(AId, LSym);
          end;
          // A bare name reached through a GENERIC ancestor is declared in that
          // ancestor's OPEN parameters — `class property Statics: S` on
          // `TWinRTGenericImportS<S>` — so the declared type read above IS that
          // bare `S`. The inherited pass already closed it over the
          // instantiation frame it found the member in (TPasInhPending.X) and
          // parked the answer in ExprTypeX; that frame cannot be recovered
          // here, because nothing at this node says which hop the member came
          // from. So take that answer when there is one — without it
          // `Statics.GetDefault` looks its member up in the OPEN parameter and
          // gives up (535 `CreateInstance` reports in the WinRT units alone).
          //
          // Gated on what we computed being an open parameter (or nothing)
          // rather than probing ExprTypeX for every identifier: that lookup is
          // on this walk's hot path and the common ident is neither.
          if (not XValid(LX[N])) or
             (FModels[LX[N].UnitId].Symbols[LX[N].Sym].Kind = skGenericParam) then
            if LM.ExprTypeX.TryGetValue(N, LBX) and XValid(LBX) then
              LX[N] := LBX;
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
          // A compiler SEED is never anyone's member, so a member name bound to
          // one is a Phase-1 mistake to be corrected here rather than trusted:
          // `Model.Text.IsEmpty` (FMX.Text.Deprecated) had `Text` bound to the
          // predefined FILE type, which typed the whole chain as a file and
          // lost the string helper after it. The bare-name side of this was
          // fixed by routing seed-bound identifiers through the inherited
          // pass; a MEMBER name never reaches that pass (it is resolved through
          // its qualifier, by design), so it needs the rule here.
          //
          // Dropping the binding is enough: the FindMemberX branch below then
          // runs and re-points the name at what it finds.
          if (LSym <> NIL_SYM) and (sfBuiltin in LM.Symbols[LSym].Flags) then
            LSym := NIL_SYM;
          if LSym <> NIL_SYM then
          begin
            LX[N] := MemberTypeX(AId, LSym, LBX.Inst, LBX);
            LCtxOf[N] := LBX.Inst;
          end
          else if ExtOf(LName, LExt) and
                  not (sfBuiltin in
                       FModels[LExt.UnitId].Symbols[LExt.Sym].Flags) then
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
          end
          // A DYNAMIC ARRAY's pseudo-constructor: `TBytes.Create($EF, $BB)`
          // builds the array, and there is no member symbol anywhere to bind
          // — the compiler makes it up. dcc-probed in both directions: legal
          // with arguments and with none, `E2671 Record, object, class type,
          // or type helper required` for a STATIC array and for a VARIABLE
          // qualifier, which is why the type test and the type-QUALIFIER test
          // are both here. 11 of the RTL package's remaining reports were this
          // one form (`TBytes`, `TCharArray`, `TArray<TGUID>`).
          //
          // Typed like any other constructor — as the type itself — so the
          // expression is not merely un-reported but right: `Length(TBytes
          // .Create(...))` needs an array, not nothing. No binding is recorded,
          // since there is nothing to navigate to.
          else if XValid(LBX) and LM.Tree.NodeTextEquals(LName, 'create') and
                  IsTypeDesignator(LBase) and IsDynArrayTypeX(LBX) then
          begin
            LX[N] := LBX;
            LCtxOf[N] := LBX.Inst;
          end
          else if FReportMembers and XValid(LBX) and LM.AllUsesResolved and
                  // A member on a VARIANT is late-bound: any name compiles and
                  // dcc checks nothing (`Excel.ActiveWorkbook.Worksheets[1]`).
                  // 312 `ActiveWorkbook` reports on one real project made this
                  // the first refinement the flag earned.
                  (XCatOf(LBX) <> tcVariant) and
                  not LM.InUnopenedWithBody(LName) and
                  not LM.HasDiagAt(LName) then
            // The one place a member reference is finally given up on: RefMap
            // and ExtRefMap are both empty and the member walk failed, with a
            // KNOWN container type (XValid) — without that last part we would
            // be reporting our own inability to type the qualifier. Gated on
            // AllUsesResolved for the same reason bare-name E2003 is: a missing
            // unit can hide the declaration. See ReportUnresolvedMembers.
            EmitE2003(LM, LName);
        end;

      nkCall:
        begin
          LBase := LM.Tree.Nodes[N].FirstChild;   // the callee
          if (LBase <> NIL_NODE) and TargetSym(LBase, LMemMid, LMemSym) then
            case FModels[LMemMid].Symbols[LMemSym].Kind of
              skRoutine:
                begin
                  LCtx := LCtxOf[LBase];
                  // A callee written `Name<...>` cannot mean a NON-generic
                  // routine of that name (16.1.2, the same arity rule types
                  // already get) — and the member walk stops at the FIRST
                  // declaration, so a derived class redeclaring the name
                  // plainly hid the ancestor's generic. System.JSON is the
                  // shape: `TJSONObject.GetValue(Name): TJSONValue` sits in
                  // front of `TJSONValue.GetValue<T>(APath): T`, so
                  // `Obj.GetValue<TJSONObject>('c').Get(...)` typed as
                  // TJSONValue and lost `Get`.
                  if LM.Tree.Nodes[LBase].Kind = nkTypeArgs then
                    RetargetToGeneric(LBase, LMemMid, LMemSym);
                  if SelectCallTarget(N, LBase, LMemMid, LMemSym, LCtx,
                    LBestMid, LBestSym) then
                  begin
                    // Record the argument-matched overload — the
                    // overload-precise navigation jump reads this.
                    LExt.UnitId := LBestMid;
                    LExt.Sym := LBestSym;
                    LM.CallTargetX.AddOrSetValue(N, LExt);
                    // ...and RE-POINT the callee NAME at it, so the maps agree
                    // with the selection instead of still holding the chain
                    // HEAD. Everything that reads a binding rather than
                    // CallTargetX was otherwise looking at the first candidate:
                    // `Exception.Create` bound to the PRIVATE `class constructor
                    // Create` at the top of that class's private section, which
                    // is how visibility enforcement got 475 false reports on one
                    // corpus. Same discipline as CheckCalls' own re-point — own
                    // model's RefMap directly, another model's through the
                    // deferred dictionary.
                    RepointCallee(LM, LBase, LBestMid, LBestSym, LNewExt);
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
                      // Count the arguments first and size the array once —
                      // the old `+ [x]` reallocated per argument, per call.
                      var LArgN := LM.Tree.Nodes[LBase].NextSibling;
                      var LArgCount := 0;
                      var LScan := LArgN;
                      while LScan <> NIL_NODE do
                      begin
                        Inc(LArgCount);
                        LScan := LM.Tree.Nodes[LScan].NextSibling;
                      end;
                      var LArgTypes: TArray<TSemaXType> := nil;
                      SetLength(LArgTypes, LArgCount);
                      LArgCount := 0;
                      while LArgN <> NIL_NODE do
                      begin
                        LArgTypes[LArgCount] := GetX(LArgN);
                        Inc(LArgCount);
                        LArgN := LM.Tree.Nodes[LArgN].NextSibling;
                      end;
                      // ...unless the type arguments were WRITTEN, in which
                      // case they are the answer and inference is not
                      // consulted at all — see ExplicitMethodFrame.
                      var LFrame := NIL_INST;
                      if LM.Tree.Nodes[LBase].Kind = nkTypeArgs then
                        LFrame := ExplicitMethodFrame(AId, LBestMid, LBestSym,
                          LBase, LCtx);
                      if LFrame = NIL_INST then
                        LFrame := InferMethodFrame(LBestMid, LBestSym,
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
    ForEachIndex(ACount - 1, 'cross-type',      procedure(AIdx: Integer)
      begin
        CrossType(AIdx);
      end);
    for LIdx := 0 to ACount - 1 do
      for var LPair in FXNewExt[LIdx] do
        FModels[LIdx].ExtRefMap.AddOrSetValue(LPair.Key, LPair.Value);
    // Only now are the bindings final — see RunVisibilityPass. No-op unless
    // ReportVisibility asked for it.
    if FReportVisibility then
      ForEachIndex(ACount - 1, 'visibility',        procedure(AIdx: Integer)
        begin
          RunVisibilityPass(AIdx);
        end);
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
            // ARITY is part of a type's identity (16.1.2) and last-uses-wins
            // is blind to it — see FixCrossArity.
            FixCrossArity(AId, LModel, LNode, LNameLower, LUid, LSym);
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
          begin
            // Count-tracked doubling: `+ [x]` reallocated and re-copied the
            // array per queued node, per unit with any E2003-shaped decl name.
            if FDeclWorkCount[AId] = Length(FDeclWork[AId]) then
              SetLength(FDeclWork[AId], FDeclWorkCount[AId] * 2 + 8);
            FDeclWork[AId][FDeclWorkCount[AId]] := LNode;
            Inc(FDeclWorkCount[AId]);
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
{ Points a callee NAME node at ASym — the node RefMap/ExtRefMap are keyed by,
  which for `A.Create` is the trailing segment and for a bare `Foo` the ident
  itself. AId's own model is written directly; another model's binding goes into
  the caller's deferred dictionary, because the cross pass runs one worker per
  model and only the owner may touch a model's ExtRefMap during it.

  The same-model branch also REMOVES any ExtRefMap entry already sitting at
  LName — needed because a bare call to an INHERITED member (`Seek(0, soEnd)`
  in TMemoryStream.SetSize, System.Classes.pas) is bound TWICE, by two passes
  that run in a fixed order and neither knows about the other's node: first
  CrossResolveInherited's FindMemberX, which matches by NAME only (no argument
  types) and commits straight to ExtRefMap even for a same-unit hit (its own
  commit clears RefMap first, so nothing is wrong on ITS side); then, only if
  the callee is a routine, CrossType's OWN overload-precise SelectCallTarget
  runs on the SAME node and calls RepointCallee — which used to write RefMap
  and stop, leaving the FIRST pass's ExtRefMap entry standing right beside it.
  With one overload the two passes agree, so both maps end up holding the
  identical (unit, symbol) — invisible to every consumer that reads "RefMap,
  falling back to ExtRefMap" (a single answer either way), but a project-wide
  scan that reads BOTH maps as independent evidence (Find References) counted
  the one real reference twice. Removing the stale entry restores the
  invariant every other caller already assumed held: one node, one map. }
procedure TPasSemaProject.RepointCallee(AModel: TPasSemaModel;
  ACalleeNode, AMid, ASym: Integer;
  ANewExt: TDictionary<Integer, TPasExtRef>);
var
  LName: Integer;
  LExt: TPasExtRef;
begin
  LName := ACalleeNode;
  if AModel.Tree.Nodes[LName].Kind = nkMember then
  begin
    LName := AModel.Tree.Nodes[LName].FirstChild;
    while (LName <> NIL_NODE) and
          (AModel.Tree.Nodes[LName].NextSibling <> NIL_NODE) do
      LName := AModel.Tree.Nodes[LName].NextSibling;
  end;
  if (LName = NIL_NODE) or (AModel.Tree.Nodes[LName].Kind <> nkIdent) then
    Exit;
  if AModel = FModels[AMid] then
  begin
    AModel.RefMap[LName] := ASym;
    AModel.ExtRefMap.Remove(LName);
    Exit;
  end;
  AModel.RefMap[LName] := NIL_SYM;
  LExt.UnitId := AMid;
  LExt.Sym := ASym;
  if ANewExt <> nil then
    ANewExt.AddOrSetValue(LName, LExt)
  else
    AModel.ExtRefMap.AddOrSetValue(LName, LExt);
end;

{ 11 §11.2.1, enforcement half: a QUALIFIED access to a private member, reported
  as dcc does — `E2361 Cannot access private symbol TType.Member`.

  OFF unless ReportVisibility says otherwise. This is the only check here that
  can reject code the corpora ACCEPT, so it ships as a switch.

  The rules, dcc32 37.0-probed rather than assumed:

  - `private` is visible to the whole DECLARING UNIT, not just the type — the
    "friend" rule. So it is an error only across units, which is why the test is
    a unit-id comparison and not a struct one.
  - `strict private` is visible only inside the declaring type, in its own unit
    too: `A.FStrict` from a sibling class one line below is already an error.
  - `protected` gets its own code (`E2362`) and needs an ancestry walk to answer,
    so it is deliberately NOT enforced here; the README names it.
  - A BARE name in a descendant is a different diagnostic entirely — dcc says
    `E2003 Undeclared identifier`, because an inaccessible member is not in scope
    rather than in scope and refused. Also named, also not done here: this
    routine sees qualified accesses only.

  Two things must keep working and are the reason the walk is written this way
  rather than as "the member's struct must be the accessing struct": a nested
  enum's VALUES are reachable from outside a private type (2 §2.2.4), and a
  strict private nested helper still activates (15 §15.4). Neither is a member
  ACCESS, so neither reaches here. }
{ Visibility over one model's finished bindings.

  A separate pass, and AFTER the cross-type one on purpose: a member's binding is
  not final while that pass runs. `Exception.Create` binds to the chain HEAD when
  the nkMember node is visited and is re-pointed to the argument-matched overload
  only when the enclosing nkCall is — so a check that ran inline saw the private
  `class constructor Create` and reported 475 times on one corpus. Reading the
  maps once everything has settled is the fix, and it is also why this is the only
  right shape for any check that inspects a BINDING rather than producing one. }
procedure TPasSemaProject.RunVisibilityPass(AId: Integer);
var
  LM: TPasSemaModel;
  LNode, LBase, LName, LSym: Integer;
  LExt: TPasExtRef;
begin
  if not FReportVisibility then
    Exit;
  LM := FModels[AId];
  if not LM.AllUsesResolved then
    Exit;   // a missing unit can hide the declaration — the E2003 gate's reason
  for LNode := 0 to High(LM.Tree.Nodes) do
  begin
    if LM.Tree.Nodes[LNode].Kind <> nkMember then
      Continue;
    LBase := LM.Tree.Nodes[LNode].FirstChild;
    if LBase = NIL_NODE then
      Continue;
    LName := LM.Tree.Nodes[LBase].NextSibling;
    if (LName = NIL_NODE) or (LM.Tree.Nodes[LName].Kind <> nkIdent) then
      Continue;
    LSym := LM.RefMap[LName];
    if LSym <> NIL_SYM then
      CheckVisibility(AId, LName, AId, LSym)
    else if LM.ExtRefMap.TryGetValue(LName, LExt) then
      CheckVisibility(AId, LName, LExt.UnitId, LExt.Sym);
  end;
end;

{ Is AInner the same type as AOuter, or one NESTED inside it (at any depth)?

  A nested type's symbol is declared into the enclosing type's member scope, so
  the chain to walk is symbol -> its scope -> that scope's StructSym, upward.
  Depth-capped like every other walk here; nesting cannot legally cycle, and the
  cap is a runaway guard rather than a rule. }
function TPasSemaProject.StructEncloses(AMid, AOuter, AInner: Integer): Boolean;
var
  LM: TPasSemaModel;
  LCur, LScope, LDepth: Integer;
begin
  Result := False;
  if (AOuter = NIL_SYM) or (AInner = NIL_SYM) then
    Exit;
  LM := FModels[AMid];
  LCur := AInner;
  for LDepth := 1 to 16 do
  begin
    if LCur = AOuter then
      Exit(True);
    LScope := LM.Symbols[LCur].Scope;
    if LScope = NIL_SCOPE then
      Exit;
    LCur := LM.Scopes[LScope].StructSym;
    if LCur = NIL_SYM then
      Exit;
  end;
end;

procedure TPasSemaProject.CheckVisibility(AId, ANameNode, AMemMid,
  AMemSym: Integer);
var
  LMemM, LM: TPasSemaModel;
  LVis: TSemaVisibility;
  LOwner, LHere: Integer;
begin
  if not FReportVisibility or (AMemSym = NIL_SYM) then
    Exit;
  LMemM := FModels[AMemMid];
  LVis := LMemM.Symbols[AMemSym].Visibility;
  if not (LVis in [svPrivate, svStrictPrivate]) then
    Exit;
  // The declaring struct: the member's own scope, which for a class member is
  // that class's member scope.
  LOwner := NIL_SYM;
  if LMemM.Symbols[AMemSym].Scope <> NIL_SCOPE then
    LOwner := LMemM.Scopes[LMemM.Symbols[AMemSym].Scope].StructSym;
  if LOwner = NIL_SYM then
    Exit;   // not a struct member after all: nothing to enforce
  LM := FModels[AId];
  LHere := StructSymOfNode(LM, ANameNode);
  if LHere = NIL_SYM then
  begin
    // The site may be in a type DECLARATION rather than a method body, and
    // StructSymOfNode deliberately answers NIL there (its own comment gives the
    // ordering reason). A field declared with its own class's strict private
    // NESTED type is exactly that shape — `FGlow: TSystemTitlebarButton
    // .TGlowWindow` inside TSystemTitlebarButton (Vcl.TitleBarCtrls) — and
    // refusing it was this check reporting a class for using its own member.
    // DeclStructsOfNode answers the same question for declaration sites,
    // innermost first, which is the one wanted here.
    for var LDeclStruct in DeclStructsOfNode(LM, ANameNode) do
    begin
      LHere := LDeclStruct;
      Break;
    end;
  end;
  if LVis = svPrivate then
  begin
    if AMemMid = AId then
      Exit;   // the friend rule: same unit, always legal
  end
  else
    // strict private: only from inside the declaring type itself — or from a
    // type NESTED in it, which is dcc's rule and an asymmetric one. Probed both
    // ways: a nested class reaching the OUTER class's strict private field
    // compiles, and the outer class reaching a NESTED class's strict private
    // field is `E2361` — the same code we emit, so the enclosing type is not
    // "inside" its own nested one. System.JSON.Builders is the shape:
    // `TJSONCollectionBuilder.TBaseCollection.WriteBuilder` reads the outer
    // class's strict private `FJSONWriter`.
    //
    // Same-unit is still required, because nesting cannot cross a unit.
    if (AMemMid = AId) and StructEncloses(AId, LOwner, LHere) then
      Exit;
  if LM.HasDiagAt(ANameNode) then
    Exit;   // one report per site, like every other pass here
  EmitAt(LM, ANameNode, 'E2361', Format(SE2361_CannotAccessPrivate,
    [LMemM.Symbols[LOwner].Name + '.' + LMemM.Symbols[AMemSym].Name]));
end;

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
{ The RESULT type of a PARAMETERLESS function/procedural type, closed over AX's
  own instantiation — XNil for anything else.

  "Parameterless" is the whole rule: `ValueFunc.GetValue` is only a member of
  the result because writing the name of a parameterless function reference
  CALLS it (6 §6.6.1). One that takes parameters cannot be called that way, and
  a `procedure` type has no result to take a member from, so both answer XNil
  and the member walk ends where it did before.

  The frame is why the substitution is here rather than at the call site:
  `TFunc<TResult> = reference to function: TResult` declares its result as a
  type PARAMETER, so `TFunc<IValue>` only yields IValue once AX's own
  instantiation is applied. }
{ Does every parameter in AParams carry a default value, so that the routine
  can be called with no arguments at all? Read off the TOKENS rather than the
  node shape: a default is the only thing that can put an `=` inside a
  parameter declaration (a type expression never contains one), while the node
  shape cannot tell `X: TFoo` from `X: TFoo = nil` without knowing which
  trailing child is a type and which an expression — and both can be an
  nkIdent. An empty list answers True, which is the same "callable bare" the
  no-list case already gets. }
function TPasSemaProject.AllParamsDefaulted(AMid, AParams: Integer): Boolean;
var
  LM: TPasSemaModel;
  LParam, LTok: Integer;
  LHasDefault: Boolean;
begin
  LM := FModels[AMid];
  LParam := LM.Tree.Nodes[AParams].FirstChild;
  while LParam <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LParam].Kind = nkParam then
    begin
      LHasDefault := False;
      for LTok := LM.Tree.Nodes[LParam].FirstToken to
                  LM.Tree.Nodes[LParam].LastToken do
        if (LTok >= 0) and (LTok <= High(LM.Tree.Source.Visible)) and
           (LM.Tree.Source.VisibleToken(LTok).Kind = PasTree.Types.tkEqual)
        then
        begin
          LHasDefault := True;
          Break;
        end;
      if not LHasDefault then
        Exit(False);
    end;
    LParam := LM.Tree.Nodes[LParam].NextSibling;
  end;
  Result := True;
end;

function TPasSemaProject.ProcResultX(const AX: TSemaXType): TSemaXType;
var
  LM: TPasSemaModel;
  LCur: TSemaXType;
  LDef, LChild, LDepth: Integer;
begin
  Result := XNil;
  LCur := AX;
  for LDepth := 1 to 8 do
  begin
    if not XValid(LCur) then
      Exit;
    LM := FModels[LCur.UnitId];
    LDef := TypeDefNodeOf(LCur.UnitId, LCur.Sym);
    if LDef = NIL_NODE then
      Exit;
    case LM.Tree.Nodes[LDef].Kind of
      nkIdent, nkMember, nkTypeArgs:
        LCur := ResolveTypeExpr(LCur.UnitId, LDef);   // alias link
      nkProcType:
        begin
          LChild := LM.Tree.Nodes[LDef].FirstChild;
          if LChild = NIL_NODE then
            Exit;   // `procedure` with neither parameters nor a result
          // Takes parameters — but a parameter with a DEFAULT still lets the
          // name be written bare, and dcc calls it then:
          // `TVTStyleServicesFunc = function(AControl: TControl = nil):
          // TCustomStyleServices` is called as `VTStyleServicesFunc.
          // GetSystemColor(...)` in a tree component's style hooks. So the rule is
          // "no parameter the caller MUST supply", not "no parameters".
          if (LM.Tree.Nodes[LChild].Kind = nkParams) and
             not AllParamsDefaulted(LCur.UnitId, LChild) then
            Exit;
          if LM.Tree.Nodes[LChild].Kind = nkParams then
          begin
            // Skip the list; the result type is the next child.
            LChild := LM.Tree.Nodes[LChild].NextSibling;
            if LChild = NIL_NODE then
              Exit;   // a `procedure(...)` type: no result to take a member of
          end;
          Exit(SubstX(ResolveTypeExpr(LCur.UnitId, LChild), LCur.Inst, 0));
        end;
    else
      Exit;
    end;
  end;
end;

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
    if (LScope <> NIL_SCOPE) and
       (FModels[LCur.UnitId].Scopes[LScope].Symbols <> nil) then
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
    if (LScope <> NIL_SCOPE) and
       (FModels[LCur.UnitId].Scopes[LScope].Symbols <> nil) then
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
    if (LScope <> NIL_SCOPE) and (LM.Scopes[LScope].Symbols <> nil) then
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
    // a threading library were this single shape, in two of its units).
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

{ The type of an inline `var` that declared no type of its own — 3.1.3's
  `var L := Expr;`, inferred from the INITIALIZER. Nothing records such a type:
  the resolver leaves TypeNode empty by design, so SymDeclTypeX answers XNil
  and every consumer that asks the symbol comes away empty-handed.

  For member binding that is merely silent (an unknown base type cannot be
  said to lack a member), which is why this went unnoticed. `with` is where it
  bites: the target types as nothing, the with-scope never opens, and every
  bare name in the body becomes a hard E2003 — 24 of them in one JSON writer
  off a single `var LNodeList := InternalGetChildNodes;`.

  The initializer is typed by the same walk the target itself uses, so calls,
  casts, `as`, indexing and dereferences all come along; the depth cap is for
  one inferred var initialised from another. }
function TPasSemaProject.InlineVarInitTypeX(AMid, ASym,
  ADepth: Integer): TSemaXType;
var
  LM: TPasSemaModel;
  LDecl, LParent, LInit: Integer;
begin
  Result := XNil;
  if (ADepth > 4) or (AMid < 0) or (ASym = NIL_SYM) then
    Exit;
  LM := FModels[AMid];
  if LM.Symbols[ASym].TypeNode <> NIL_NODE then
    Exit;   // it has a written type; not our case
  LDecl := LM.Symbols[ASym].DeclNode;
  if LDecl = NIL_NODE then
    Exit;
  LParent := LM.Tree.Nodes[LDecl].Parent;
  if (LParent = NIL_NODE) or
     not (LM.Tree.Nodes[LParent].Kind in [nkInlineVar, nkInlineConst]) then
    Exit;
  // Everything after the names is the initializer, and with no type node
  // that is exactly the LAST child. Equal to the name itself means there is
  // no initializer at all.
  LInit := LM.Tree.Nodes[LParent].FirstChild;
  if LInit = NIL_NODE then
    Exit;
  while LM.Tree.Nodes[LInit].NextSibling <> NIL_NODE do
    LInit := LM.Tree.Nodes[LInit].NextSibling;
  if LInit = LDecl then
    Exit;
  Result := WithTargetTypeX(AMid, LInit);
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
      // `as` is a reserved word: the operator token's KIND says it, free.
      if (LM.Tree.Nodes[ANode].Aux >= 0) and
         (LM.Tree.Source.VisibleToken(LM.Tree.Nodes[ANode].Aux).Kind = tkAs)
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
          Result := SymDeclTypeX(AId, LSym);
        // A type ALREADY recorded for this ident, when the symbol did not
        // yield one. Two shapes need it, and the second is why this is a
        // FALLBACK rather than an else-branch:
        //
        // - the inherited pass writes it for a member reached through a
        //   GENERIC ancestor: `Items` on a `class(TObjectList<TFloatingObj>)`
        //   is declared `T` on TList<T> (HTMLSubs.TFloatingObjList.Decrement);
        // - an INLINE VAR WITH AN INFERRED TYPE — `var L := GetChildNodes;`
        //   then `with L do ... Count` — has a symbol but no type NODE, so
        //   SymDeclTypeX answers nothing and the old else-chain stopped there.
        //   A plain `L.Count` typed fine, which is what made it look like a
        //   member-binding problem rather than a with-target one
        //   (Alcinoe.JSONDoc, 24 reports).
        if not XValid(Result) and
           LM.ExprTypeX.TryGetValue(ANode, LBX) and XValid(LBX) then
          Result := LBX;
        if not XValid(Result) and (LSym <> NIL_SYM) then
          Result := InlineVarInitTypeX(AId, LSym, 0);
        if not XValid(Result) and LM.ExtRefMap.TryGetValue(ANode, LExt) then
          Result := SymDeclTypeX(LExt.UnitId, LExt.Sym)
        // `Self` has no symbol — nothing declares it (11.3.3), so RefMap is
        // empty for it and the recursion above dead-ends. Inside a method body
        // its type is the enclosing struct, which is exactly what
        // StructSymOfNode answers. Real shape: `with Self.TreeViewControl do`,
        // where dropping the qualifier's type loses the whole with scope.
        else if LM.Tree.NodeTextEquals(ANode, 'Self') then
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
    SetLength(FInhWorkNames, ACount);
    SetLength(FWithWorkNames, ACount);
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
  LInhNames, LWithNames: TArray<string>;
  LName: string;
begin
  // Fail LOUDLY, naming the contract, instead of the AV an unsized read
  // produces (range checks are off in release; a nil-array index read
  // whatever sat at address AId). Sizing stays the CALLER's job on purpose:
  // this runs on pass workers, and lazily growing shared arrays here would
  // be a write race between them — the exact bug class this file avoids by
  // hoisting every SetLength to the driver (SizeCrossWork's callers).
  if AId > High(FWorkBuilt) then
    raise Exception.CreateFmt(
      'EnsureCrossWork(%d) before SizeCrossWork sized %d slots',
      [AId, Length(FWorkBuilt)]);
  if FWorkBuilt[AId] then
    Exit;
  LM := FModels[AId];
  // High(RefMap) is the node count; both lists are far smaller, but sizing to
  // it once beats growing them incrementally.
  SetLength(LInh, Length(LM.RefMap));
  SetLength(LWith, Length(LM.RefMap));
  SetLength(LInhNames, Length(LM.RefMap));
  SetLength(LWithNames, Length(LM.RefMap));
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
      //
      // The NAME is computed here, once — the pass itself re-reads this list
      // on every fixpoint round. 'result'/'self' are skipped at the source:
      // both passes Continue on them with no side effects, and a with body
      // mentions Result constantly.
      LName := LM.Tree.NodeNameLower(LNode);
      if (LName = 'result') or (LName = 'self') then
        Continue;
      LWith[LWithN] := LNode;
      LWithNames[LWithN] := LName;
      Inc(LWithN);
    end
    else if ((LM.RefMap[LNode] = NIL_SYM) and
             not LM.ExtRefMap.ContainsKey(LNode)) or
            ((LM.RefMap[LNode] <> NIL_SYM) and
             ((LM.Symbols[LM.RefMap[LNode]].Kind = skUnitRef) or
              ((sfBuiltin in LM.Symbols[LM.RefMap[LNode]].Flags) and
               (StructSymOfNode(LM, LNode) <> NIL_SYM)))) then
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
      LName := LM.Tree.NodeNameLower(LNode);
      if (LName = 'result') or (LName = 'self') then
        Continue;
      LInh[LInhN] := LNode;
      LInhNames[LInhN] := LName;
      Inc(LInhN);
    end;
  end;
  SetLength(LInh, LInhN);
  SetLength(LWith, LWithN);
  SetLength(LInhNames, LInhN);
  SetLength(LWithNames, LWithN);
  FInhWork[AId] := LInh;
  FWithWork[AId] := LWith;
  FInhWorkNames[AId] := LInhNames;
  FWithWorkNames[AId] := LWithNames;
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
  SetLength(FDeclWorkCount, ACount);
  for LIdx := 0 to ACount - 1 do
  begin
    FDeclWork[LIdx] := nil;
    FDeclWorkCount[LIdx] := 0;
  end;
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
  LNode, LUid, LSym, LCtx, LWIdx, LPendCount: Integer;
  LPend: TPasInhPending;
  LNameLower: string;
  LFound: Boolean;
begin
  APending := nil;
  if AId > High(FDeclWork) then
    Exit;
  LModel := FModels[AId];
  // Pre-size to the work list (every entry can pend at most once), truncate at
  // the end — the old `+ [x]` re-copied the managed-record array per append,
  // per round (the EnsureCrossWork idiom).
  // FDeclWork carries capacity slack — the filled prefix is FDeclWorkCount.
  SetLength(APending, FDeclWorkCount[AId]);
  LPendCount := 0;
  for LWIdx := 0 to FDeclWorkCount[AId] - 1 do
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
      APending[LPendCount] := LPend;
      Inc(LPendCount);
    end
    else if AEmit and LModel.AllUsesResolved then
      EmitE2003(LModel, LNode);   // CrossResolve's verdict, just deferred
  end;
  SetLength(APending, LPendCount);
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
    ForEachIndex(ACount - 1, 'declarations',      procedure(AIdx: Integer)
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
  LNode, LStruct, LUid, LSym, LCtx, LMatchNode, LWIdx, LBound: Integer;
  LPendCount: Integer;
  LPend: TPasInhPending;
  LFound: Boolean;
  LNameLower: string;
  LMiss: TDictionary<Int64, Byte>;
  LKey: Int64;
begin
  APending := nil;
  LModel := FModels[AId];
  EnsureCrossWork(AId);
  // Pre-size to the work list (each entry pends at most once), truncate at
  // the end — the same idiom EnsureCrossWork itself uses; the old `+ [x]`
  // re-copied the managed-record array per append, per fixpoint round.
  SetLength(APending, Length(FInhWork[AId]));
  LPendCount := 0;
  LMiss := TDictionary<Int64, Byte>.Create;
  try
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
    // A node that ARRIVES BOUND is here for the shadowing retry, and its
    // answer is almost always "no, the binding stands" — `Length`, `Copy` and
    // every other intrinsic used in a method body asks the same question over
    // and over. Remember the misses, keyed by (struct, the symbol it is bound
    // to): two integers, so no string is built and nothing is allocated, which
    // is the whole difference from the memo this file's history records at
    // +16%. Per worker, and one worker owns one model, so no lock either.
    LBound := LModel.RefMap[LNode];
    LKey := 0;
    if LBound <> NIL_SYM then
    begin
      LKey := (Int64(LStruct) shl 32) or Cardinal(LBound);
      if LMiss.ContainsKey(LKey) then
        Continue;
    end;
    // Precomputed by EnsureCrossWork's scan ('result'/'self' filtered there):
    // a refcount bump instead of an allocation, per candidate per round.
    LNameLower := FInhWorkNames[AId][LWIdx];
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
    // an inherited MEMBER outranks a unit name. `uses SomeLib.Header`
    // registers the unit under its LAST segment, so in a class that also has a
    // `Header` property the qualifier test says "this is a namespace token" and
    // skipped the very node that had a member to find — leaving `Header.Columns`
    // typed as nothing and its whole with body undeclared. Tested first, it also
    // suppressed the override below, which is why that change alone did nothing.
    if not LFound and (QualifierUnitAt(AId, LNode, LMatchNode) >= 0) then
      Continue;
    // An ALREADY-BOUND node is here to be OVERRIDDEN, not gap-filled: the
    // uses/System fallbacks would only re-find what Phase 1 already found, and
    // with no inherited member its answer simply stands. No diagnostic either
    // way. Two kinds reach this pass bound (see EnsureCrossWork):
    //
    // - a UNIT reference, because a bare unit name is never a value and an
    //   inherited member outranks it (`uses SomeLib.Header` in a class
    //   that also has a `Header` property);
    // - a compiler SEED, for the same reason one step further out. dcc-probed:
    //   a class with a `Text` property compiles `Text.IsEmpty` in its method
    //   body — the member beats the predefined FILE type — and `var F: Text;`
    //   in that same body is `E2007`, so the member wins in a TYPE position
    //   too. FMX's canvases are full of the first form (`TTextLayout.Text`),
    //   and binding the seed there is a WRONG binding, not a missing one: it
    //   sends ctrl+click to nothing and types the expression as a file.
    if LBound <> NIL_SYM then
    begin
      if LFound then
      begin
        LPend.Node := LNode;
        LPend.Ext.UnitId := LUid;
        LPend.Ext.Sym := LSym;
        // The frame travels with the OVERRIDE too, for the reason the unbound
        // branch below states at length: it cannot be recovered downstream.
        // Dropping it here was invisible until a name was BOTH the last
        // segment of a dotted `uses` AND a member declared in a generic
        // ancestor's open parameters — `Params` in a real project's UI tests, where
        // `uses UITest.Params` registers the unit under `Params` and
        // `TUITest<TParams>.Params: TParams` is the member that outranks it.
        // The override then typed every one of them as the open TParams,
        // which falls to the CONSTRAINT, so the base class's fields resolved
        // and the actual parameter class's did not: ~700 reports, and the
        // only visible symptom was which field name was undeclared.
        if LFound and (LCtx <> NIL_INST) then
          LPend.X := SubstX(SymDeclTypeX(LUid, LSym), LCtx, 0)
        else
          LPend.X := XNil;
        APending[LPendCount] := LPend;
        Inc(LPendCount);
      end
      else
        LMiss.AddOrSetValue(LKey, 0);
      Continue;
    end;
    if LFound or
       FindInUses(AId, LNameLower, LUid, LSym) or
       FindInSystemUnit(LNameLower, LUid, LSym) or
       FindInSysInitUnit(LNameLower, LUid, LSym) then
    begin
      // The uses/System fallbacks are last-uses-wins and blind to ARITY, which
      // is part of a type's identity (16.1.2) — see FixCrossArity. Not applied
      // to an inherited MEMBER hit (LFound): that came from a type's own
      // scope, not from a by-name import race.
      if not LFound then
        FixCrossArity(AId, LModel, LNode, LNameLower, LUid, LSym);
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
      APending[LPendCount] := LPend;
      Inc(LPendCount);
    end
    else if LModel.AllUsesResolved then
      EmitE2003(LModel, LNode);
    end;
    SetLength(APending, LPendCount);
  finally
    LMiss.Free;
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
  ForEachIndex(ACount - 1, 'inherited',    procedure(AIdx: Integer)
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
  var APending: TArray<TPasInhPending>; AEmit: Boolean;
  var AUnresolved: TArray<Integer>);
var
  LModel: TPasSemaModel;
  LNode, LStruct, LUid, LSym, LCtx, LMatchNode, LWIdx: Integer;
  LPendCount, LUnresCount: Integer;
  LPend: TPasInhPending;
  LNameLower: string;
  LBound, LFromMember: Boolean;
  LMemX: TSemaXType;
  LCurExt: TPasExtRef;
begin
  APending := nil;
  AUnresolved := nil;
  LModel := FModels[AId];
  EnsureCrossWork(AId);
  // Pre-size + truncate, same as CrossResolveInherited — this one repeats per
  // fixpoint round (MAX_ROUNDS=8), so the old per-append copy multiplied.
  SetLength(APending, Length(FWithWork[AId]));
  SetLength(AUnresolved, Length(FWithWork[AId]));
  LPendCount := 0;
  LUnresCount := 0;
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
    // by EnsureCrossWork's single scan — the NAME too ('result'/'self'
    // filtered there): this pass re-runs per fixpoint round, and each
    // NodeNameLower here was an allocation per node per round.
    LNameLower := FWithWorkNames[AId][LWIdx];
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
      APending[LPendCount] := LPend;
      Inc(LPendCount);
    end
    else if LBound then
      Continue   // no with member by that name: Phase 1's binding stands
    else
    begin
      // The member walk is hoisted out of the condition it used to sit in, so
      // the arity correction below can tell WHICH source won. An inherited
      // member hit is a type's own scope and needs no correction; the
      // uses/System fallbacks are last-uses-wins and blind to ARITY, which is
      // part of a type's identity (16.1.2). See FixCrossArity.
      LFromMember := (LStruct <> NIL_SYM) and
        FindMemberX(AId, XPlain(AId, LStruct), LNameLower, LUid, LSym, LCtx);
      if LFromMember or
         FindInUses(AId, LNameLower, LUid, LSym) or
         FindInSystemUnit(LNameLower, LUid, LSym) or
         FindInSysInitUnit(LNameLower, LUid, LSym) then
      begin
        if not LFromMember then
          FixCrossArity(AId, LModel, LNode, LNameLower, LUid, LSym);
        LPend.Node := LNode;
        LPend.Ext.UnitId := LUid;
        LPend.Ext.Sym := LSym;
        LPend.X := XNil;
        APending[LPendCount] := LPend;
        Inc(LPendCount);
      end
      else if LModel.AllUsesResolved then
      begin
        // Emit-or-record: the converged round's recording IS the emit set —
        // RunWithPass emits from it without paying another full round. AEmit
        // stays for the round-cap fallback, where a final round can still
        // BIND new names and only then report the rest.
        if AEmit then
          EmitE2003(LModel, LNode)
        else
        begin
          AUnresolved[LUnresCount] := LNode;
          Inc(LUnresCount);
        end;
      end;
    end;
  end;
  SetLength(APending, LPendCount);
  SetLength(AUnresolved, LUnresCount);
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
  LUnres: TArray<TArray<Integer>>;
  LIdx, LP, LNode, LRound, LNew: Integer;
  LEmit: Boolean;
begin
  SetLength(LPending, ACount);
  SetLength(LUnres, ACount);
  SizeCrossWork(ACount);   // AnalyzeFile reaches this pass without the other
  LRound := 0;
  LEmit := False;
  while True do
  begin
    Inc(LRound);
    for LIdx := 0 to ACount - 1 do
    begin
      LPending[LIdx] := nil;
      LUnres[LIdx] := nil;
    end;
    ForEachIndex(ACount - 1, 'with',      procedure(AIdx: Integer)
      begin
        CrossResolveWith(AIdx, LPending[AIdx], LEmit, LUnres[AIdx]);
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
      Break;   // the cap-fallback emitting round is always the last one
    // Converged: the round that found nothing new saw exactly the final
    // state, so the candidates it RECORDED as unresolved are the stable ones
    // — emit from the record instead of re-running a whole round to
    // rediscover it. Per model in work-list order, the same order the old
    // emit round produced.
    if LNew = 0 then
    begin
      for LIdx := 0 to ACount - 1 do
        for LP := 0 to High(LUnres[LIdx]) do
          EmitE2003(FModels[LIdx], LUnres[LIdx][LP]);
      Break;
    end;
    // Out of rounds with work still moving: one more round, old-style — it
    // may still BIND new names and must report only what then remains.
    if LRound >= MAX_ROUNDS then
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
  // Eagerly, like every other driver (AnalyzeProject/Directory/Staged): the
  // parallel passes below can reach EnsureSystemUnit from a worker (any
  // FindMemberX ancestry climb hops to the implicit TObject), and a
  // first-time System load THERE appends to FModels/FByPath while sibling
  // workers index them. This was the one driver without the eager load.
  EnsureSystemUnit;
  EnsureSysInitUnit;
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
  // The ONE direct CrossResolveInherited caller — every other driver goes
  // through RunInheritedPass, which sizes the cross-work arrays before
  // farming out. Without this, EnsureCrossWork read FWorkBuilt[Result] off a
  // NIL array: an AV on every AnalyzeFile run with real search paths, found
  // by the Prefetch-race stress repro (2026-08-22), invisible to the suites
  // because none of them drives AnalyzeFile. RunWithPass's own sizing call
  // carries the same "AnalyzeFile reaches this pass without the other" note.
  SizeCrossWork(FModels.Count);
  var LPend: TArray<TPasInhPending>;
  CrossResolveInherited(Result, LPend);
  for LIdx := 0 to High(LPend) do
    FModels[Result].ExtRefMap.Add(LPend[LIdx].Node, LPend[LIdx].Ext);
  CheckCalls(Result);
  CheckConstraints(Result);
  CheckAttributes(Result);
  // Declared types for EVERY loaded model first (the expression pass reads
  // used units' SymTypeX), then expressions for the requested unit only.
  for LIdx := 0 to FModels.Count - 1 do
    BindTypesX(LIdx);
  CrossType(Result);
  // Only the requested unit gets the full cross treatment here (AnalyzeFile's
  // narrower contract); its direct uses stay msFullReady.
  SetModuleStatus(Result, msCrossReady);
  TrimAllDiags;
  ReleaseCrossWork;
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
  LIdx, LN: Integer;
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
  // Load the TRANSITIVE closure — continuous, not round-barriered (see
  // RunLoadEngine). ResolveUses (sequential, the single source of truth for
  // UnitId assignment) then finds every file cached, exactly as it did after
  // the old per-round batch loads.
  RunLoadEngine(nil, nil, {AIntfLoads} False, nil);
  Stage('load');
  for LIdx := 0 to FModels.Count - 1 do
    ResolveUses(LIdx);
  Stage('resolve');
  // A Declared() guard can only be answered now — see RunDeclaredPass. It may
  // load units the re-decided branch newly imports, so LN is taken after it.
  RunDeclaredPass(FModels.Count);
  InjectEncodingDiags(FModels.Count);
  InjectGuessedIfDiags(FModels.Count);
  // Cross passes for EVERY loaded unit — same per-unit write discipline as
  // AnalyzeDirectory (each writes only its own model, reads others' frozen
  // Phase-1 state), so the same parallel farming is safe.
  LN := FModels.Count;
  PrepareDeclWork(LN);
  ForEachIndex(LN - 1, 'resolve',    procedure(AIdx: Integer)
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
  ForEachIndex(LN - 1, 'cross-resolve',    procedure(AIdx: Integer)
    begin
      CheckCalls(AIdx);
      CheckConstraints(AIdx);
      CheckAttributes(AIdx);
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
  TrimAllDiags;
  ReleaseCrossWork;
  // Analysis is over: drop the raw-bytes repository (a full second copy of
  // every closure file that nothing reads from here on — hundreds of MB on
  // a real project) and the include-cache's own stream references.
  FSM.ReleaseAnalysisCaches;
end;

procedure TPasSemaProject.AnalyzeDirectory(const ARoot: string);
var
  LFile, LExt: string;
  LPaths: TArray<string>;
  LN, LIdx, LPathCount: Integer;
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
  LPathCount := 0;
  for LFile in TDirectory.GetFiles(ARoot, '*.*',
    TSearchOption.soAllDirectories) do
  begin
    LExt := LowerCase(TPath.GetExtension(LFile));
    if (LExt = '.pas') or (LExt = '.dpr') then
    begin
      if LPathCount = Length(LPaths) then
        SetLength(LPaths, LPathCount * 2 + 16);
      LPaths[LPathCount] := LFile;
      Inc(LPathCount);
    end;
  end;
  SetLength(LPaths, LPathCount);
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
  // See RunDeclaredPass. LN stays the directory snapshot: anything it pulls in
  // from the search paths belongs outside the E2003 set, like System itself.
  RunDeclaredPass(LN);
  InjectEncodingDiags(LN);
  InjectGuessedIfDiags(LN);
  Stage('main+sys+resolve');
  // Cross passes per unit write ONLY their own model and read the others'
  // Phase-1 state (frozen once every unit is loaded) — safe to farm out.
  PrepareDeclWork(LN);
  ForEachIndex(LN - 1, 'resolve',    procedure(AIdx: Integer)
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
  ForEachIndex(LN - 1, 'cross-resolve',    procedure(AIdx: Integer)
    begin
      CheckCalls(AIdx);
      CheckConstraints(AIdx);
      CheckAttributes(AIdx);
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
  TrimAllDiags;
  ReleaseCrossWork;
  FSM.ReleaseAnalysisCaches;   // see AnalyzeProject
end;

function TPasSemaProject.AnalyzeStaged(const ARoots, APriority: TArray<string>;
  const ACancelled: TFunc<Boolean>;
  const AOnProgress: TProc<TPasStagedProgress>): Integer;
var
  LProgress: TPasStagedProgress;
  LN, LIdx: Integer;
  LOrdered: TArray<string>;
  LIds: TArray<Integer>;
  LPath, LKey: string;
  LSeen: TDictionary<string, Boolean>;
  LSW: TStopwatch;
  // Recount+Report as a CAPTURED closure: RunLoadEngine's progress hook is an
  // anonymous method, and an anonymous method cannot call the nested
  // Recount/Report (E2555) — but it can call another closure.
  LNotify: TProc<string>;

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

begin
  Result := -1;
  FStageTimings := '';
  LProgress := Default(TPasStagedProgress);
  LSeen := TDictionary<string, Boolean>.Create;
  // Publish the predicate for the duration of the run: ForEachIndex reads it
  // so a cancel stops the parallel passes mid-pass, not just at the
  // between-pass checks below.
  FCancelCheck := ACancelled;
  try
    LSW := TStopwatch.StartNew;
    LNotify :=
      procedure(APhase: string)
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
        LProgress.Phase := APhase;
        if Assigned(AOnProgress) then
          AOnProgress(LProgress);
      end;
    // Front-load the priority set (open module + its uses), then the roots.
    // Pre-sized to the input (survivors <= input), truncated after the loop.
    SetLength(LOrdered, Length(APriority) + Length(ARoots));
    LIdx := 0;
    for LPath in APriority + ARoots do
    begin
      LKey := LowerCase(TPath.GetFullPath(LPath));
      if not LSeen.ContainsKey(LKey) then
      begin
        LSeen.Add(LKey, True);
        LOrdered[LIdx] := LPath;
        Inc(LIdx);
      end;
    end;
    SetLength(LOrdered, LIdx);

    // The implicit System unit is part of every closure (1.2.1) but never
    // named in a `uses` clause — pull it in up front (full, like
    // AnalyzeProject) so wave 1's BFS also walks its uses and the finalizer
    // covers it. Matches AnalyzeProject's early EnsureSystemUnit. SysInit
    // rides along the same way.
    EnsureSystemUnit;
    EnsureSysInitUnit;

    // ---- Wave 1: interface-only closure, continuous (see RunLoadEngine —
    // parses run out of order, commits and discovery keep the old BFS's
    // deterministic id order; the engine reports every 64 commits, the same
    // heartbeat the 64-file chunks used to give) ----
    Report('intf');
    if not RunLoadEngine(LOrdered, nil, {AIntfLoads} True,
      procedure
      begin
        LNotify('intf');
      end) then
    begin
      Report('cancelled');
      Exit;
    end;
    StageMark('intf');

    // ---- Wave 2: upgrade every module to a full parse, discovering any
    // implementation-only dependencies the interface trees didn't show.
    // Upgrades and the loads they discover ride one queue, so a discovered
    // unit parses WHILE later upgrades still run — the old shape upgraded
    // everything, then loaded, in separate barriered rounds. ----
    Report('full');
    LIds := nil;
    for LIdx := 0 to FStatus.Count - 1 do
      if FStatus[LIdx] = msIntfReady then
        LIds := LIds + [LIdx];
    if not RunLoadEngine(nil, LIds, {AIntfLoads} False,
      procedure
      begin
        LNotify('full');
      end) then
    begin
      Report('cancelled');
      Exit;
    end;
    StageMark('full');

    // ---- Finalizer: cross passes over the whole closure. Reported as
    // sub-phases (they take real seconds on a big project — a single silent
    // 'cross' looked like a hang), with a cancel point between passes. ----
    LN := FModels.Count;
    Report('cross:resolve');
    for LIdx := 0 to LN - 1 do
    begin
      if (LIdx and 63 = 0) and Cancelled then
      begin
        Report('cancelled');
        Exit;
      end;
      ResolveUses(LIdx);
    end;
    if Cancelled then
    begin
      Report('cancelled');
      Exit;
    end;
    RunDeclaredPass(LN);   // see there; must precede every cross pass
    InjectEncodingDiags(LN);
    InjectGuessedIfDiags(LN);
    if Cancelled then
    begin
      Report('cancelled');
      Exit;
    end;
    // Sub-phase timings, same granularity AnalyzeProject reports: a single
    // 'cross=6900' says only THAT the finalizer is slow, never which pass.
    StageMark('declared');
    LN := FModels.Count;   // it may have loaded newly-imported units
    Report('cross:xresolve');
    PrepareDeclWork(LN);
    ForEachIndex(LN - 1, 'resolve',      procedure(AIdx: Integer)
      begin
        CrossResolve(AIdx);
      end);
    if Cancelled then
    begin
      Report('cancelled');
      Exit;
    end;
    StageMark('xresolve');
    Report('cross:inherited');
    RunInheritedPass(LN);
    StageMark('inherited');
    // Reads type nodes the inherited pass just COMMITTED — see
    // CrossResolveWith. Kept inside the same reported step (it is the same
    // "resolve what the parallel pass deferred" phase, just a later slice).
    RunWithPass(LN);
    if Cancelled then
    begin
      Report('cancelled');
      Exit;
    end;
    StageMark('with');
    Report('cross:calls');
    ForEachIndex(LN - 1, 'cross-resolve',      procedure(AIdx: Integer)
      begin
        CheckCalls(AIdx);
        CheckConstraints(AIdx);
        CheckAttributes(AIdx);
      end);
    if Cancelled then
    begin
      Report('cancelled');
      Exit;
    end;
    StageMark('calls');
    Report('cross:bindx');
    for LIdx := 0 to FModels.Count - 1 do
    begin
      if (LIdx and 63 = 0) and Cancelled then
      begin
        Report('cancelled');
        Exit;
      end;
      BindTypesX(LIdx);
    end;
    StageMark('bindx');
    Report('cross:xtype');
    RunCrossTypePass(LN);
    StageMark('xtype');
    // A cancel that landed inside the last pass must not report 'done' with
    // a half-run pass behind it — the host would treat the project as good.
    if Cancelled then
    begin
      Report('cancelled');
      Exit;
    end;
    MarkAllCrossReady;
    TrimAllDiags;
    ReleaseCrossWork;
    // See AnalyzeProject. On a cancelled run the caches stay — the host
    // discards a cancelled project wholesale anyway.
    FSM.ReleaseAnalysisCaches;
    StageMark('final');
    Recount;
    Report('done');

    if Length(ARoots) > 0 then
      FByPath.TryGetValue(LowerCase(TPath.GetFullPath(ARoots[0])), Result);
  finally
    FCancelCheck := nil;
    // LNotify is a closure OVER THIS FRAME stored IN this frame — a
    // self-cycle the compiler cannot collect (the $ActRec holds the TProc,
    // the TProc pins the $ActRec). Break it or every staged run leaks its
    // activation record plus everything it captured.
    LNotify := nil;
    LSeen.Free;
  end;
end;

initialization
  GInstanceComparer := TSemaInstanceComparer.Create;

end.
