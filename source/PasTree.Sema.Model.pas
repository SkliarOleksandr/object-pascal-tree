unit PasTree.Sema.Model;

{
  PasTree semantics — the side-model bound to one immutable TPasTree.

  Everything is index-based (mirrors the AST arena): symbols live in a grown
  array, scopes in an owned list, and RefMap maps a CST node index to the
  symbol it resolved to (NIL_SYM = -1). The model is a pure product of
  (tree, builtins) so it can be built one-per-unit in parallel later.
}

interface

uses
  System.Generics.Collections,
  // Types after System units so its tk* token kinds shadow System.TTypeKind's
  // same-named members (RoutineHead switches on them); Preprocessor for
  // TPasPreprocessed (TryRehydrate's parameter).
  PasTree.Types,
  PasTree.Preprocessor,
  PasTree.Ast,
  PasTree.Sema.Diagnostics;

const
  NIL_SYM = -1;
  NIL_SCOPE = -1;
  NIL_INST = -1;

type
  // A module's progress through the project's analysis pipeline. The async
  // parser advances a module msQueued -> msIntfReady (interface parsed +
  // Phase 1) -> msFullReady (full parse + Phase 1) -> msCrossReady (cross
  // passes done); a consumer waits for / gates on the minimum status it
  // needs (see TPasSemaProject.TryGetSnapshot). Ordered so `>=` works.
  // The synchronous drivers take every model straight to msCrossReady.
  TPasModuleStatus = (msQueued, msIntfReady, msFullReady, msCrossReady);

  TSemaSymbolKind = (skType, skVar, skConst, skField, skRoutine, skParam,
    skProperty, skEnumValue, skGenericParam, skLabel, skUnitRef, skBuiltinType,
    // Never a declared symbol: completion KEYWORD rows carry this so a host
    // mapping Kind to its own item kinds cannot mistake `begin` for a type
    // (they used to ship as skType, documented-meaningless — the review's
    // note). No resolver code path produces or consumes it.
    skKeyword);

  // sfGeneric: a TYPE declared with parameters (`TFoo<T>`). Set once at collect
  // time because the alternative — deriving it at lookup — sits on the hottest
  // path there is: a bare type reference must prefer the arity-0 declaration
  // (16.1.2), so EVERY type reference in the closure asks the question. Reading
  // it off the declaration there cost +1.7% even in its cheapest structural
  // form; a set membership test costs nothing.
  TSemaSymbolFlag = (sfBuiltin, sfExternalUnresolved, sfStrict, sfOverload,
    sfClassMember, sfForward, sfHasBody, sfHasDefault, sfGeneric);
  TSemaSymbolFlags = set of TSemaSymbolFlag;

  // A reference resolved to a symbol in another unit's model.
  TPasExtRef = record
    UnitId: Integer;   // index into the project's model list
    Sym: Integer;      // symbol index within that model
  end;

  // A cross-model type descriptor (Phase 3c): a type symbol in any of the
  // project's models, optionally a generic INSTANTIATION of it (Inst indexes
  // the owning TPasSemaProject's instance table; NIL_INST for a plain type).
  // Only meaningful within the project that produced it.
  TSemaXType = record
    UnitId: Integer;   // model id of the type symbol; NIL_SYM = no type
    Sym: Integer;      // type symbol index within that model
    Inst: Integer;     // project instance-table index; NIL_INST = plain type
  end;

  // One `uses` entry, recorded by the resolver and completed by the project.
  TPasUsesRef = record
    NameFull: string;  // dotted unit name as written
    InPath: string;    // from `in '...'`, or ''
    NameNode: Integer; // CST node of the (qualified) name
    Sym: Integer;      // the skUnitRef symbol in this model
    UnitId: Integer;   // resolved project model id; NIL_SYM if unresolved
  end;

  // Appended, never reordered: svAutomated last so existing ordinals hold.
  TSemaVisibility = (svDefault, svStrictPrivate, svPrivate, svStrictProtected,
    svProtected, svPublic, svPublished, svAutomated);

  // A routine's HEAD word, resolved once — the display/classification facts
  // completion reads per row (see RoutineHead). Survives text demotion.
  TPasRoutineHead = (rhNone, rhProcedure, rhFunction, rhConstructor,
    rhDestructor, rhOperator);

  // Type category (mirrors DelphiAST TDataTypeID groupings) — set on
  // skType/skBuiltinType symbols; drives assignment/operator checks.
  TSemaTypeCat = (tcUnknown, tcInteger, tcFloat, tcBoolean, tcChar, tcString,
    tcPointer, tcNil, tcEnum, tcSet, tcArray, tcRecord, tcClass, tcInterface,
    tcProc, tcClassOf, tcVariant, tcFile);

  TSemaSymbol = record
    Kind: TSemaSymbolKind;
    Name: string;          // original spelling
    NameLower: string;     // case-insensitive key
    DeclNode: Integer;     // CST index; NIL_NODE for builtins
    Scope: Integer;        // owning scope index
    TypeSym: Integer;      // resolved type symbol; NIL_SYM if unbound
    TypeNode: Integer;     // CST node of the declared type expr; NIL_NODE if none
    Flags: TSemaSymbolFlags;
    Visibility: TSemaVisibility;
    NextOverload: Integer;  // next routine of the same name in scope; NIL_SYM
    MemberScope: Integer;   // members of a type/unit for A.B lookup; NIL_SCOPE
    TypeCat: TSemaTypeCat;  // category (types only); tcUnknown otherwise
    NumRank: Byte;          // numeric widening rank (int/float families); 0 else
  end;

  TSemaScopeKind = (sckSystem, sckUnit, sckImplementation, sckStruct,
    sckRoutine, sckWith, sckBlock, sckGenericParams, sckEnum);

  // Callback for EnumScopeDeep: one symbol, plus the scope it was found IN
  // (which may be a joined scope, not the one enumeration started from).
  TPasSymEnumProc = reference to procedure(ASym, AScope: Integer);

  TSemaScope = class
    Kind: TSemaScopeKind;
    Parent: Integer;                       // scope index; NIL_SCOPE at root
    OwnerNode: Integer;                    // CST node that opened this scope
    // Both LAZY — nil until the first name is bound (most scopes never bind
    // one). Readers treat nil as empty; TPasSemaModel.BindName creates them.
    Names: TDictionary<string, Integer>;   // NameLower -> symbol index (head)
    Symbols: TList<Integer>;               // declaration order
    // True when Names/Symbols point at containers OWNED ELSEWHERE and shared
    // read-only across models — today only the builtin seed template
    // (PasTree.Sema.Builtins). Destroy leaves them alone, and any WRITE goes
    // through EnsureOwnedContainers first (copy-on-write), so a future pass
    // that declares into such a scope gets a private copy instead of
    // corrupting every other model's view.
    SharedContainers: Boolean;
    Additional: TArray<Integer>;           // joined scopes (system/with/ancestor)
    // Joined scopes checked BEFORE this scope's own names. Exactly one thing
    // needs that order and the spec is explicit about it (15.3.3): a HELPER
    // member hides the extended type's own member of the same name. Everything
    // else joined here — uses, with, ancestors, enums — is a fallback and
    // belongs in Additional. See JoinScopeShadowing.
    Shadowing: TArray<Integer>;
    // For a METHOD implementation's routine scope: the (innermost) struct
    // type symbol the qualified name resolved to (TFoo in TFoo.Bar). NIL_SYM
    // elsewhere. The project driver's inherited-member pass starts its
    // cross-unit ancestor walk here.
    StructSym: Integer;
    constructor Create(AKind: TSemaScopeKind; AParent, AOwnerNode: Integer);
    destructor Destroy; override;
    procedure EnsureOwnedContainers;
  end;

  TPasSemaModel = class
  private
    FSymCount: Integer;
    // Diags' filled prefix. The array itself carries CAPACITY between
    // TrimDiags calls (AddDiag doubles instead of the old `Diags + [x]`,
    // which re-copied every managed record per append — O(n²) on the
    // error-heavy units, ~2447 diags in corpus history). Everything outside
    // this unit reads Diags AFTER analysis, when TrimDiags has cut it back
    // to exact length; in-flight readers go through HasDiagAt, which stops
    // at the count.
    FDiagCount: Integer;
    procedure GrowSyms;
  public
    Tree: TPasTree;                 // referenced, not owned
    Symbols: TArray<TSemaSymbol>;
    Scopes: TObjectList<TSemaScope>;
    RefMap: TArray<Integer>;        // node index -> symbol index; NIL_SYM
    Diags: TArray<TSemaDiag>;
    // Phase 2: cross-unit state.
    InterfaceScope: Integer;        // scope importers may read; NIL_SCOPE
    // The implicit System scope seeded with the compiler-provided names
    // (PasTree.Sema.Builtins). Kept separately from InterfaceScope, which
    // JOINS it: answering "is this name compiler-provided?" must NOT also see
    // the unit's own declarations.
    SystemScope: Integer;
    NodeScope: TArray<Integer>;     // node index -> scope in effect; NIL_SCOPE
    ExprType: TArray<Integer>;      // node index -> type symbol; NIL_SYM = untyped
    ExtRefMap: TDictionary<Integer, TPasExtRef>; // node -> external symbol
    CallTarget: TDictionary<Integer, Integer>;   // nkCall node -> chosen routine
    // Cross-model call target (Phase 3c): the overload CrossType selected by
    // argument types among the merged local + used-units candidate set. Set
    // only when the winner is meaningful beyond CallTarget (cross-unit callee
    // or a real overload choice) — the future overload-precise navigation
    // jump reads this.
    CallTargetX: TDictionary<Integer, TPasExtRef>;
    // Phase 3c: cross-model typing (filled by the project driver; empty in a
    // standalone per-unit analysis). Entries exist only where they ADD to the
    // intra-unit result: a declared type / expression type that lives in
    // another model, or a generic instantiation of one.
    SymTypeX: TDictionary<Integer, TSemaXType>;  // symbol -> declared type
    ExprTypeX: TDictionary<Integer, TSemaXType>; // node -> expression type
    UsesList: TArray<TPasUsesRef>;
    AllUsesResolved: Boolean;       // gates E2003 (set by the project driver)
    UnitNameLower: string;          // this unit's own name, lower-cased
    // nkWithStmt nodes whose target type could NOT be resolved intra-unit, so
    // their member scope was never opened (PasTree.Sema.Resolver.
    // ResolveOneWithStmt). Inside such a body ANY unqualified name might be a
    // member of the target — a member that shadows everything else (ch.05
    // §5.7, dcc-verified against a class field, a local, a parameter, a
    // same-unit global, and even an inline var declared in the body itself).
    // So Phase 1's binding there is a best-effort GUESS: the project's
    // with pass revises it once the cross-unit type is known, and until then
    // any type derived from it is unreliable — which is why the typer stays
    // quiet over these nodes (see InUnopenedWithBody / TPasSemaTyper.Diag).
    WithUnopened: TArray<Integer>;
    { MEMORY-AUDIT §6.4-4 stage 2 — TEXT DEMOTION state. When Demoted, the
      token layer is gone: Tree.Source.Visible is nil and every file's
      Source/Tokens/LineStarts are empty; Nodes, RefMap, ExtRefMap, Symbols,
      Scopes, SymTypeX all survive, so resolution and the generic machinery
      keep working (they are node-id/symbol-table driven — verified in the
      audit). Every text/position consumer either degrades through its
      existing bounds guards or asks TPasSemaProject.EnsureHydrated first.
      The Demoted* fields are the REHYDRATION IDENTITY CHECK: a re-preprocess
      must reproduce exactly this stream or the node token indices would lie. }
    { Snapshot ReleaseTransientMaps takes before freeing NodeScope: struct
      TYPE node -> its member scope's StructSym, for every scope owned by a
      struct-kind node. The one post-analysis reader of another model's
      NodeScope is ResolveTypeExpr's anonymous-struct branch (an inline
      `record ... end` in a type slot has no name, so RefMap has nothing) —
      this dictionary is that branch's released-mode answer. Nil until a
      release; scopes are few, so it is tiny. }
    AnonStructSyms: TDictionary<Integer, Integer>;
    Demoted: Boolean;
    { True when this model's FINAL token stream came from the declared-pass
      re-preprocess (the per-unit $IF oracle) rather than the plain seeded
      first pass. Such a stream depended on MID-ANALYSIS oracle state and is
      not reproducible from cold — measured on the client closure: exactly
      these units (System.pas, System.Rtti, FastMM4...) failed the rehydration
      identity check. DemoteClosedUnits therefore skips them; they keep full
      text. A handful of units against ~3750 demoted. }
    OracleStream: Boolean;
    DemotedVisCount: Integer;
    DemotedFileSizes: TArray<Integer>;    // Length(Files[i].Source)
    DemotedTokenCounts: TArray<Integer>;  // Length(Files[i].Tokens)
    DemotedHeads: TArray<Byte>;           // per symbol: Ord(TPasRoutineHead)
    constructor Create(const ATree: TPasTree);
    destructor Destroy; override;

    function SymCount: Integer;
    function AddScope(AKind: TSemaScopeKind; AParent, AOwnerNode: Integer):
      Integer;
    procedure JoinScope(AScope, AAdditional: Integer);
    { Joins AShadowing so it is searched BEFORE AScope's own names — the one
      precedence a plain JoinScope cannot express. See TSemaScope.Shadowing. }
    procedure JoinScopeShadowing(AScope, AShadowing: Integer);
    // Adds a symbol to the arena (does not register a name). ANameKey, when
    // non-empty, is a PRECOMPUTED PasNameKey(AName) — callers that already
    // built the key for their own lookup pass it to avoid lowering twice.
    function AddSymbol(AScope: Integer; AKind: TSemaSymbolKind;
      const AName: string; ADeclNode: Integer;
      const ANameKey: string = ''): Integer;
    // Registers NameLower -> symbol in a scope's dictionary + order list.
    procedure BindName(AScope, ASym: Integer);
    // Appends to a scope's declaration-order list WITHOUT (re)binding a name —
    // the overload/duplicate branches of DeclareSym. Honours copy-on-write on
    // a shared-container scope, same as BindName.
    procedure AddToOrder(AScope, ASym: Integer);
    { Bulk-adopts a seed TEMPLATE: copies ASyms into Symbols[0..N-1] (string
      fields share their heap data by refcount — no per-name allocation) and
      re-stamps each record's Scope to AScope. ONLY valid on an empty symbol
      arena: the template's name dictionary maps names to indices 0..N-1.
      Returns False (and does nothing) when the arena is not empty — the
      caller then falls back to seeding symbol by symbol. }
    function AdoptSeededSymbols(const ASyms: TArray<TSemaSymbol>;
      AScope: Integer): Boolean;
    // Local lookup in one scope (no chain).
    function FindLocal(AScope: Integer; const ANameLower: string): Integer;
    // AScope's own names, then its Additional (joined) scopes, most-recently
    // -added first, EACH CHECKED THE SAME WAY (so a joined scope's own
    // joins are reachable too — e.g. a class's member scope has a nested
    // enum's values joined into IT; a routine implementing that class's
    // method joins the class's member scope in turn, and must still see the
    // enum values two joins deep). FindLocal alone is one level only; this
    // is what Resolve actually needs at each scope of its PARENT climb.
    function FindLocalDeep(AScope: Integer; const ANameLower: string): Integer;
    { The ENUMERATING counterpart of FindLocalDeep, for completion: every
      symbol visible through AScope, reported in exactly the order the lookup
      would try them — Shadowing joins (recursive) first, then the scope's own
      declaration-order list, then Additional joins most-recently-added first
      (recursive). A caller deduplicating by NameLower and keeping the FIRST
      hit therefore reproduces FindLocalDeep's precedence. Does NOT climb
      Parent — that is the caller's chain walk, same split as the lookups. }
    procedure EnumScopeDeep(AScope: Integer; const AOnSym: TPasSymEnumProc;
      ADepth: Integer = 0);
    // Full lookup: self -> additional (reverse) -> parent -> ...
    function Resolve(AScope: Integer; const ANameLower: string): Integer;
    { Resolve honouring block-scope POSITION — see the implementation. Only a
      reference lookup passes a real AAtToken; everything else passes -1. }
    function ResolveAt(AScope: Integer; const ANameLower: string;
      AAtToken: Integer): Integer;
    { ResolveAt restricted to one side of the GENERIC/non-generic split, since
      arity is part of a type's identity. See the implementation. }
    function ResolveByArityAt(AScope: Integer; const ANameLower: string;
      AAtToken: Integer; AWantGeneric: Boolean): Integer;
    function FindByArityDeep(AScope: Integer; const ANameLower: string;
      AWantGeneric: Boolean): Integer;
    function DeclaredAfter(ASym, AAtToken: Integer): Boolean;
    { True when ANode sits in the BODY of a `with` listed in WithUnopened —
      see that field. An identifier inside a with's own TARGET expression is
      NOT in its scope (the target is evaluated in the enclosing one), hence
      the last-child test. WithUnopened is empty for the overwhelming
      majority of units, so this costs one length check on the hot path. }
    function InUnopenedWithBody(ANode: Integer): Boolean;
    { Frees the maps nothing reads after analysis for a unit the host is not
      EDITING: ExprType (a nodes-sized array), ExprTypeX and WithUnopened.
      Navigation reads none of them (grep-verified in MEMORY-AUDIT §6.4-4 and
      re-verified 2026-08-23); completion reads them for the ACTIVE file only,
      which the caller keeps. ExprTypeX stays a live-but-empty dictionary so
      existing TryGetValue readers need no nil-guard. See
      TPasSemaProject.ReleaseTransientMaps for the contract — this is not
      called during any analysis. }
    procedure ReleaseTransientMaps;
    { The member-scope struct symbol stamped on a struct TYPE node — from
      NodeScope while it lives, from the release-time snapshot afterwards.
      NIL_SYM when the node owns no such scope. }
    function StructSymAtNode(ANode: Integer): Integer;
    { The innermost struct whose scope ENCLOSES ANode — the `Self` context
      there, as opposed to StructSymAtNode's "this node IS the struct".
      Climbs the node's parents to the nearest scope, then that scope's
      parents: StructSym is stamped both on a struct's own member scope and
      on a method IMPLEMENTATION's routine scope, so this answers inside a
      declaration and inside a body alike. NIL_SYM outside any struct.
      Reads NodeScope, so it is an ANALYSIS-TIME query — a demoted model
      (ReleaseTransientMaps) answers NIL_SYM. }
    function EnclosingStructSym(ANode: Integer): Integer;
    { The routine head word of ASym (skRoutine), from the head token — or,
      on a demoted model, from the snapshot DemoteText took. rhNone for a
      symbol that is not a routine or has no routine node. }
    function RoutineHead(ASym: Integer): TPasRoutineHead;
    { Stage 2 of the release: snapshots RoutineHead for every routine symbol
      and the stream identity counts, then frees the whole text layer
      (Visible + per-file Source/Tokens/LineStarts). See the Demoted field. }
    procedure DemoteText;
    { Installs APre as this model's token layer IF it is stream-identical to
      the demoted one (same file count, per-file source sizes and token
      counts, same visible count) — the guard that a changed file can only
      ever mean "no answer", never a wrong position. False leaves the model
      demoted. }
    function TryRehydrate(const APre: TPasPreprocessed): Boolean;
    procedure AddDiag(const ADiag: TSemaDiag);
    { Cuts Diags back to its filled prefix. The project driver calls this at
      the end of every analysis entry point, BEFORE any consumer enumerates
      Diags with Length/High. }
    procedure TrimDiags;
    { Is a diagnostic already anchored at this CST node? For a pass that can
      reach the same failure twice (the cross-type pass runs per driver path and
      a node can be visited from more than one expression) and wants dcc's one
      report per site. Linear, so only for the error path. }
    function HasDiagAt(ANode: Integer): Boolean;
  end;

{ Any name -> its lookup key: lower-cased, leading '&' stripped. `&Foo` and
  `Foo` name the same thing — see the implementation. }
function PasNameKey(const AName: string): string;

implementation

uses
  System.SysUtils;

{ TSemaScope }

constructor TSemaScope.Create(AKind: TSemaScopeKind; AParent,
  AOwnerNode: Integer);
begin
  inherited Create;
  Kind := AKind;
  Parent := AParent;
  OwnerNode := AOwnerNode;
  StructSym := NIL_SYM;
  // Names/Symbols stay NIL until the first bind (see BindName): scopes are
  // minted per routine, per block, per with, per enum — and most never
  // declare a name, so the two eager heap objects per scope were the
  // dominant small-object count in the analyzer. Every reader treats nil as
  // empty (FindLocal here; the for-in/Count readers each guard locally).
end;

destructor TSemaScope.Destroy;
begin
  if not SharedContainers then
  begin
    Names.Free;
    Symbols.Free;
  end;
  inherited;
end;

procedure TSemaScope.EnsureOwnedContainers;
var
  LOwnNames: TDictionary<string, Integer>;
  LOwnOrder: TList<Integer>;
  LPair: TPair<string, Integer>;
begin
  if not SharedContainers then
    Exit;
  // Copy-on-write off the shared seed containers: from here on this scope
  // owns private copies and mutating it is ordinary.
  LOwnNames := TDictionary<string, Integer>.Create(Names.Count);
  for LPair in Names do
    LOwnNames.Add(LPair.Key, LPair.Value);
  LOwnOrder := TList<Integer>.Create;
  LOwnOrder.AddRange(Symbols);
  Names := LOwnNames;
  Symbols := LOwnOrder;
  SharedContainers := False;
end;

{ TPasSemaModel }

constructor TPasSemaModel.Create(const ATree: TPasTree);
begin
  inherited Create;
  Tree := ATree;
  Scopes := TObjectList<TSemaScope>.Create(True);
  ExtRefMap := TDictionary<Integer, TPasExtRef>.Create;
  CallTarget := TDictionary<Integer, Integer>.Create;
  CallTargetX := TDictionary<Integer, TPasExtRef>.Create;
  SymTypeX := TDictionary<Integer, TSemaXType>.Create;
  ExprTypeX := TDictionary<Integer, TSemaXType>.Create;
  InterfaceScope := NIL_SCOPE;
  SystemScope := NIL_SCOPE;
  AllUsesResolved := False;
  SetLength(Symbols, 64);
  FSymCount := 0;
  SetLength(RefMap, Length(ATree.Nodes));
  SetLength(ExprType, Length(ATree.Nodes));
  for var LIdx := 0 to High(RefMap) do
  begin
    RefMap[LIdx] := NIL_SYM;
    ExprType[LIdx] := NIL_SYM;
  end;
end;

destructor TPasSemaModel.Destroy;
begin
  AnonStructSyms.Free;
  ExprTypeX.Free;
  SymTypeX.Free;
  CallTargetX.Free;
  CallTarget.Free;
  ExtRefMap.Free;
  Scopes.Free;
  inherited;
end;

function TPasSemaModel.SymCount: Integer;
begin
  Result := FSymCount;
end;

procedure TPasSemaModel.GrowSyms;
begin
  if FSymCount = Length(Symbols) then
    SetLength(Symbols, Length(Symbols) * 2);
end;

function TPasSemaModel.AddScope(AKind: TSemaScopeKind; AParent,
  AOwnerNode: Integer): Integer;
begin
  Result := Scopes.Add(TSemaScope.Create(AKind, AParent, AOwnerNode));
end;

procedure TPasSemaModel.JoinScope(AScope, AAdditional: Integer);
begin
  Scopes[AScope].Additional := Scopes[AScope].Additional + [AAdditional];
end;

procedure TPasSemaModel.JoinScopeShadowing(AScope, AShadowing: Integer);
begin
  Scopes[AScope].Shadowing := Scopes[AScope].Shadowing + [AShadowing];
end;

{ Any name -> its lookup key: lower-cased, leading '&' stripped.

  `&Foo` and `Foo` name the SAME thing (see TPasTree.NodeNameLower for the
  dcc-verified detail). Callers pass a symbol's DISPLAY name here, ampersand and
  all, because that is what the source said — the key must not keep it. Applied
  at both ends on purpose: AddSymbol/DeclareSym for what gets declared, and
  FindLocal for what gets looked up, so no future call site can reintroduce the
  mismatch by building a key its own way. }
function PasNameKey(const AName: string): string;
var
  LFrom, LLen, LIdx: Integer;
  LCh: Char;
  LOut: PChar;
begin
  // Fast path: a name that is already a key (no '&', no ASCII uppercase) is
  // returned as-is — a refcount bump instead of an allocation. Callers often
  // pass names that are already lowered.
  LLen := Length(AName);
  LFrom := 1;
  if (LLen > 0) and (AName[1] = '&') then
  begin
    Inc(LFrom);
    Dec(LLen);
  end
  else
  begin
    LIdx := 1;
    while (LIdx <= LLen) and not ((AName[LIdx] >= 'A') and (AName[LIdx] <= 'Z'))
    do
      Inc(LIdx);
    if LIdx > LLen then
      Exit(AName);
  end;
  // Single pass, one allocation — ASCII-only folding, exactly what the old
  // Delete('&') -> LowerCase chain produced.
  SetLength(Result, LLen);
  LOut := PChar(Pointer(Result));
  for LIdx := 0 to LLen - 1 do
  begin
    LCh := AName[LFrom + LIdx];
    if (LCh >= 'A') and (LCh <= 'Z') then
      Inc(LCh, 32);
    LOut[LIdx] := LCh;
  end;
end;

function TPasSemaModel.AddSymbol(AScope: Integer; AKind: TSemaSymbolKind;
  const AName: string; ADeclNode: Integer;
  const ANameKey: string): Integer;
begin
  GrowSyms;
  Result := FSymCount;
  Inc(FSymCount);
  Symbols[Result].Kind := AKind;
  Symbols[Result].Name := AName;
  if ANameKey <> '' then
    Symbols[Result].NameLower := ANameKey
  else
    Symbols[Result].NameLower := PasNameKey(AName);
  Symbols[Result].DeclNode := ADeclNode;
  Symbols[Result].Scope := AScope;
  Symbols[Result].TypeSym := NIL_SYM;
  Symbols[Result].TypeNode := NIL_NODE;
  Symbols[Result].Flags := [];
  Symbols[Result].Visibility := svDefault;
  Symbols[Result].NextOverload := NIL_SYM;
  Symbols[Result].MemberScope := NIL_SCOPE;
  Symbols[Result].TypeCat := tcUnknown;
  Symbols[Result].NumRank := 0;
end;

procedure TPasSemaModel.BindName(AScope, ASym: Integer);
begin
  Scopes[AScope].EnsureOwnedContainers;
  if Scopes[AScope].Names = nil then
  begin
    Scopes[AScope].Names := TDictionary<string, Integer>.Create;
    Scopes[AScope].Symbols := TList<Integer>.Create;
  end;
  Scopes[AScope].Names.AddOrSetValue(Symbols[ASym].NameLower, ASym);
  Scopes[AScope].Symbols.Add(ASym);
end;

procedure TPasSemaModel.AddToOrder(AScope, ASym: Integer);
begin
  Scopes[AScope].EnsureOwnedContainers;
  // The callers just hit a FindLocal match in this scope, so the containers
  // exist; the nil test keeps the method honest if that ever changes.
  if Scopes[AScope].Symbols = nil then
    Scopes[AScope].Symbols := TList<Integer>.Create;
  Scopes[AScope].Symbols.Add(ASym);
end;

function TPasSemaModel.AdoptSeededSymbols(const ASyms: TArray<TSemaSymbol>;
  AScope: Integer): Boolean;
var
  LIdx: Integer;
begin
  if FSymCount <> 0 then
    Exit(False);
  if Length(Symbols) < Length(ASyms) then
    SetLength(Symbols, Length(ASyms) + 64);
  for LIdx := 0 to High(ASyms) do
  begin
    Symbols[LIdx] := ASyms[LIdx];
    Symbols[LIdx].Scope := AScope;   // scope INDEX is per-model — re-stamp
  end;
  FSymCount := Length(ASyms);
  Result := True;
end;

function TPasSemaModel.FindLocal(AScope: Integer;
  const ANameLower: string): Integer;
begin
  // ANameLower must ALREADY be a key (PasNameKey / TPasTree.NodeNameLower).
  // Normalizing defensively here instead cost 3.3x total analysis time: this is
  // the hottest function in the analyzer, and PasNameKey allocates a string per
  // call. Cheap-looking belt-and-braces on a hot path is not cheap — the
  // boundary that BUILDS the key is the only place that can normalize for free,
  // because it is already producing a string there.
  // A scope that never declared anything has no dictionary at all (lazy —
  // see TSemaScope.Create); the nil test also short-circuits the hash.
  if (Scopes[AScope].Names = nil) or
     not Scopes[AScope].Names.TryGetValue(ANameLower, Result) then
    Result := NIL_SYM;
end;

function TPasSemaModel.FindLocalDeep(AScope: Integer;
  const ANameLower: string): Integer;
var
  LAdd: TArray<Integer>;
  LIdx: Integer;
begin
  // SHADOWING joins first, before the scope's own names: 15.3.3 — a helper
  // member hides the extended type's own member of the same name.
  // dcc-verified, and a component suite leans on it hard: its rich-edit
  // `TdxTagBaseInnerHelper = class helper for TdxTagBase` redeclares
  // `Importer` at the DERIVED importer type, and every `Importer.TagsStack`
  // in that unit needs the helper's, not the class's own. Empty for all but a
  // handful of scopes, so the common lookup pays one length test.
  LAdd := Scopes[AScope].Shadowing;
  for LIdx := High(LAdd) downto 0 do
  begin
    Result := FindLocalDeep(LAdd[LIdx], ANameLower);
    if Result <> NIL_SYM then
      Exit;
  end;
  Result := FindLocal(AScope, ANameLower);
  if Result <> NIL_SYM then
    Exit;
  // Joined scopes, most-recently-added first (uses/with priority) — each
  // recursed into the SAME way, not just FindLocal'd, so a joined scope's
  // own joins are reachable too.
  LAdd := Scopes[AScope].Additional;
  for LIdx := High(LAdd) downto 0 do
  begin
    Result := FindLocalDeep(LAdd[LIdx], ANameLower);
    if Result <> NIL_SYM then
      Exit;
  end;
  Result := NIL_SYM;
end;

procedure TPasSemaModel.EnumScopeDeep(AScope: Integer;
  const AOnSym: TPasSymEnumProc; ADepth: Integer);
var
  LJoins: TArray<Integer>;
  LIdx: Integer;
begin
  // The lookups recurse joins unguarded (the resolver never builds a cyclic
  // join graph); an enumerator visits EVERYTHING, so it caps depth anyway —
  // a malformed graph then costs duplicates, never a hang.
  if ADepth > 16 then
    Exit;
  LJoins := Scopes[AScope].Shadowing;
  for LIdx := High(LJoins) downto 0 do
    EnumScopeDeep(LJoins[LIdx], AOnSym, ADepth + 1);
  if Scopes[AScope].Symbols <> nil then
    for LIdx := 0 to Scopes[AScope].Symbols.Count - 1 do
      AOnSym(Scopes[AScope].Symbols[LIdx], AScope);
  LJoins := Scopes[AScope].Additional;
  for LIdx := High(LJoins) downto 0 do
    EnumScopeDeep(LJoins[LIdx], AOnSym, ADepth + 1);
end;

function TPasSemaModel.Resolve(AScope: Integer;
  const ANameLower: string): Integer;
begin
  Result := ResolveAt(AScope, ANameLower, -1);
end;

{ FindLocalDeep restricted to one side of the generic split — the same-name chain
  first, then the joined scopes. See ResolveByArityAt.

  AWantGeneric False skips generic TYPES; True skips everything that is not one,
  which is deliberately narrower than "skip non-generic types": a routine or a
  variable of that name is not a wrong-arity type and must still be able to win,
  or `TFoo<T>` written where a VALUE named TFoo is in scope would resolve to a
  type it has no business finding. }
function TPasSemaModel.FindByArityDeep(AScope: Integer;
  const ANameLower: string; AWantGeneric: Boolean): Integer;
var
  LAdd: TArray<Integer>;
  LIdx, LSym, LDepth: Integer;

  function Wrong(ASym: Integer): Boolean;
  begin
    if Symbols[ASym].Kind <> skType then
      Result := False   // not a type at all: not this rule's business
    else
      Result := (sfGeneric in Symbols[ASym].Flags) <> AWantGeneric;
  end;

begin
  LSym := FindLocal(AScope, ANameLower);
  // Same name, same scope: types chain through NextOverload like routines do,
  // so the other arity declared beside this one is found here. Depth-capped for
  // a malformed chain, like every other walk in this model.
  LDepth := 0;
  while (LSym <> NIL_SYM) and (LDepth < 32) do
  begin
    if not Wrong(LSym) then
      Exit(LSym);
    LSym := Symbols[LSym].NextOverload;
    Inc(LDepth);
  end;
  LAdd := Scopes[AScope].Additional;
  for LIdx := High(LAdd) downto 0 do
  begin
    Result := FindByArityDeep(LAdd[LIdx], ANameLower, AWantGeneric);
    if Result <> NIL_SYM then
      Exit;
  end;
  Result := NIL_SYM;
end;

{ ResolveAt restricted to one side of the generic split (16 §16.1.2).

  ARITY is part of a type's identity, and BOTH directions of ignoring that are
  real, both set by one third-party library's base unit:

  - a BARE name must not bind to a generic. `Pointer<T> = record ... end` does
    not shadow the builtin `Pointer`, however much nearer it is — every
    `Pointer(X) := nil` in that unit was a type error until this existed.
  - a `Name<T>` must not bind to a NON-generic. `Nullable = record class var
    HasValue: string; end` sits beside `Nullable<T>` with a Boolean `HasValue`
    property, and a parameter typed `Nullable<T>` was resolving to the arity-0
    record — so `not other.HasValue` was `not <string>`.

  Called ONLY when the ordinary lookup already answered with the wrong side, and
  the reference's form is known — both tested at the call site, because this walk
  is not free and every name in the closure would otherwise pay for it. NIL_SYM
  means "no candidate of the wanted arity anywhere", and the caller then keeps
  the binding it has rather than losing the reference: that is dcc's error, not a
  reason to unbind. }
function TPasSemaModel.ResolveByArityAt(AScope: Integer;
  const ANameLower: string; AAtToken: Integer;
  AWantGeneric: Boolean): Integer;
var
  LCur: Integer;
begin
  LCur := AScope;
  while LCur <> NIL_SCOPE do
  begin
    Result := FindByArityDeep(LCur, ANameLower, AWantGeneric);
    if Result <> NIL_SYM then
      if (AAtToken < 0) or (Scopes[LCur].Kind <> sckBlock) or
         not DeclaredAfter(Result, AAtToken) then
        Exit;
    LCur := Scopes[LCur].Parent;
  end;
  Result := NIL_SYM;
end;

{ Resolve, but honouring the one scope kind whose names are visible only from
  their declaration onward: a BLOCK, where inline `var`/`const` live (3.1.3 —
  "visible from its declaration to the end of the enclosing block").

  Everything else stays order-independent, and deliberately: a routine's classic
  `var` section, a unit section and a struct's members are all visible
  throughout regardless of where the reference sits.

  AAtToken is the referring node's own first VISIBLE-stream index, which is
  monotonic in source order across include boundaries — that is what the
  visible stream is for — so comparing it against the declaration's is the
  whole test. Pass -1 to skip the check, which is what every lookup that is not
  resolving a reference does (a declaration completing a forward, a qualified
  segment, the aggregate walk). }
function TPasSemaModel.ResolveAt(AScope: Integer; const ANameLower: string;
  AAtToken: Integer): Integer;
var
  LCur: Integer;
begin
  LCur := AScope;
  while LCur <> NIL_SCOPE do
  begin
    Result := FindLocalDeep(LCur, ANameLower);
    if Result <> NIL_SYM then
    begin
      if (AAtToken < 0) or (Scopes[LCur].Kind <> sckBlock) or
         not DeclaredAfter(Result, AAtToken) then
        Exit;
      // Declared BELOW the reference: not in scope yet, so keep walking
      // outward. Without this the inline declaration captured references
      // above it — a WRONG binding rather than a missing one, so it cost no
      // diagnostic and sent go-to-declaration to the wrong line.
    end;
    LCur := Scopes[LCur].Parent;
  end;
  Result := NIL_SYM;
end;

// Is ASym's declaration positioned after AAtToken in the visible stream?
function TPasSemaModel.DeclaredAfter(ASym, AAtToken: Integer): Boolean;
var
  LDecl: Integer;
begin
  Result := False;
  if (ASym = NIL_SYM) or (ASym > High(Symbols)) then
    Exit;
  LDecl := Symbols[ASym].DeclNode;
  if (LDecl = NIL_NODE) or (LDecl > High(Tree.Nodes)) then
    Exit;
  Result := Tree.Nodes[LDecl].FirstToken > AAtToken;
end;

procedure TPasSemaModel.ReleaseTransientMaps;
var
  LScope, LOwner: Integer;
begin
  ExprType := nil;
  WithUnopened := nil;
  ExprTypeX.Free;
  ExprTypeX := TDictionary<Integer, TSemaXType>.Create;
  // NodeScope joins the released set — but its one post-analysis consumer
  // (the anonymous-struct branch, see AnonStructSyms) gets a snapshot first.
  // Built from the SCOPES (a few hundred) rather than a scan of every node.
  if NodeScope <> nil then
  begin
    for LScope := 0 to Scopes.Count - 1 do
      if Scopes[LScope].StructSym <> NIL_SYM then
      begin
        LOwner := Scopes[LScope].OwnerNode;
        if (LOwner <> NIL_NODE) and (LOwner <= High(Tree.Nodes)) and
           (Tree.Nodes[LOwner].Kind in [nkRecordType, nkClassType,
             nkInterfaceType, nkObjectType]) then
        begin
          if AnonStructSyms = nil then
            AnonStructSyms := TDictionary<Integer, Integer>.Create;
          AnonStructSyms.AddOrSetValue(LOwner, Scopes[LScope].StructSym);
        end;
      end;
    NodeScope := nil;
  end;
end;

function TPasSemaModel.EnclosingStructSym(ANode: Integer): Integer;
var
  LScope: Integer;
begin
  Result := NIL_SYM;
  if (ANode < 0) or (NodeScope = nil) then
    Exit;
  // To the nearest scope-owning ancestor node...
  LScope := NIL_SCOPE;
  while ANode <> NIL_NODE do
  begin
    if ANode <= High(NodeScope) then
    begin
      LScope := NodeScope[ANode];
      if LScope <> NIL_SCOPE then
        Break;
    end;
    ANode := Tree.Nodes[ANode].Parent;
  end;
  // ...then out through the enclosing scopes.
  while LScope <> NIL_SCOPE do
  begin
    if Scopes[LScope].StructSym <> NIL_SYM then
      Exit(Scopes[LScope].StructSym);
    LScope := Scopes[LScope].Parent;
  end;
end;

function TPasSemaModel.StructSymAtNode(ANode: Integer): Integer;
var
  LScope: Integer;
begin
  Result := NIL_SYM;
  if (ANode < 0) or (ANode > High(Tree.Nodes)) then
    Exit;
  if NodeScope <> nil then
  begin
    if ANode > High(NodeScope) then
      Exit;
    LScope := NodeScope[ANode];
    if LScope <> NIL_SCOPE then
      Result := Scopes[LScope].StructSym;
  end
  else if AnonStructSyms <> nil then
    AnonStructSyms.TryGetValue(ANode, Result);
end;

function TPasSemaModel.RoutineHead(ASym: Integer): TPasRoutineHead;
var
  LNode, LVis: Integer;
begin
  Result := rhNone;
  if (ASym < 0) or (ASym >= SymCount) or (Symbols[ASym].Kind <> skRoutine) then
    Exit;
  if Demoted then
  begin
    if ASym <= High(DemotedHeads) then
      Result := TPasRoutineHead(DemotedHeads[ASym]);
    Exit;
  end;
  // The name node sits inside its nkRoutine; the head token is the routine's
  // first. `class` is NOT in the routine's token span (the struct-body parser
  // eats it and sets Aux = 1), so the head really is one of the five words.
  LNode := Symbols[ASym].DeclNode;
  while (LNode <> NIL_NODE) and (Tree.Nodes[LNode].Kind <> nkRoutine) do
    LNode := Tree.Nodes[LNode].Parent;
  if LNode = NIL_NODE then
    Exit;
  LVis := Tree.Nodes[LNode].FirstToken;
  if (LVis < 0) or (LVis > High(Tree.Source.Visible)) then
    Exit;
  case Tree.Source.VisibleToken(LVis).Kind of
    tkProcedure: Result := rhProcedure;
    tkFunction: Result := rhFunction;
    tkConstructor: Result := rhConstructor;
    tkDestructor: Result := rhDestructor;
  else
    // `operator` is the one head that lexes as an identifier.
    if Tree.Source.VisibleTextEquals(LVis, 'operator') then
      Result := rhOperator;
  end;
end;

procedure TPasSemaModel.DemoteText;
var
  LIdx: Integer;
begin
  if Demoted then
    Exit;
  // Snapshot the per-row facts completion keeps reading (RoutineHead), then
  // the stream identity, THEN free — order matters, RoutineHead reads text.
  SetLength(DemotedHeads, SymCount);
  for LIdx := 0 to SymCount - 1 do
    DemotedHeads[LIdx] := Byte(RoutineHead(LIdx));
  DemotedVisCount := Length(Tree.Source.Visible);
  SetLength(DemotedFileSizes, Length(Tree.Source.Files));
  SetLength(DemotedTokenCounts, Length(Tree.Source.Files));
  for LIdx := 0 to High(Tree.Source.Files) do
  begin
    DemotedFileSizes[LIdx] := Length(Tree.Source.Files[LIdx].Source);
    DemotedTokenCounts[LIdx] := Length(Tree.Source.Files[LIdx].Tokens);
  end;
  Demoted := True;   // before the frees: RoutineHead must read the snapshot
  Tree.Source.Visible := nil;
  for LIdx := 0 to High(Tree.Source.Files) do
  begin
    Tree.Source.Files[LIdx].Source := '';
    Tree.Source.Files[LIdx].Tokens := nil;
    Tree.Source.Files[LIdx].LineStarts := nil;
  end;
end;

function TPasSemaModel.TryRehydrate(const APre: TPasPreprocessed): Boolean;
var
  LIdx: Integer;
begin
  Result := False;
  if not Demoted then
    Exit(True);
  if Length(APre.Visible) <> DemotedVisCount then
    Exit;
  if Length(APre.Files) <> Length(DemotedTokenCounts) then
    Exit;
  for LIdx := 0 to High(APre.Files) do
    if (Length(APre.Files[LIdx].Source) <> DemotedFileSizes[LIdx]) or
       (Length(APre.Files[LIdx].Tokens) <> DemotedTokenCounts[LIdx]) then
      Exit;
  Tree.Source := APre;
  Demoted := False;
  DemotedFileSizes := nil;
  DemotedTokenCounts := nil;
  DemotedHeads := nil;
  DemotedVisCount := 0;
  Result := True;
end;

function TPasSemaModel.InUnopenedWithBody(ANode: Integer): Boolean;
var
  LCur, LParent, LLast, LIdx: Integer;
begin
  Result := False;
  if (Length(WithUnopened) = 0) or (ANode = NIL_NODE) then
    Exit;
  LCur := ANode;
  LParent := Tree.Nodes[LCur].Parent;
  while LParent <> NIL_NODE do
  begin
    if Tree.Nodes[LParent].Kind = nkWithStmt then
      for LIdx := 0 to High(WithUnopened) do
        if WithUnopened[LIdx] = LParent then
        begin
          // Children are target1..targetN then the body (last one).
          LLast := Tree.Nodes[LParent].FirstChild;
          while (LLast <> NIL_NODE) and
                (Tree.Nodes[LLast].NextSibling <> NIL_NODE) do
            LLast := Tree.Nodes[LLast].NextSibling;
          if LCur = LLast then
            Exit(True);
          Break;
        end;
    LCur := LParent;
    LParent := Tree.Nodes[LCur].Parent;
  end;
end;

procedure TPasSemaModel.AddDiag(const ADiag: TSemaDiag);
begin
  if FDiagCount = Length(Diags) then
    SetLength(Diags, FDiagCount * 2 + 8);
  Diags[FDiagCount] := ADiag;
  Inc(FDiagCount);
end;

procedure TPasSemaModel.TrimDiags;
begin
  if Length(Diags) <> FDiagCount then
    SetLength(Diags, FDiagCount);
end;

function TPasSemaModel.HasDiagAt(ANode: Integer): Boolean;
begin
  for var LIdx := 0 to FDiagCount - 1 do
    if Diags[LIdx].DeclNode = ANode then
      Exit(True);
  Result := False;
end;

end.
