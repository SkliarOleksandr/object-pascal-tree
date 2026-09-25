unit PasTree.Sema.Model;

{
  PasTree semantics - the side-model bound to one immutable TPasTree.

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
  PasTree.Parser,
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
    // (they used to ship as skType, documented-meaningless - the review's
    // note). No resolver code path produces or consumes it.
    skKeyword);

  // sfGeneric: a TYPE declared with parameters (`TFoo<T>`). Set once at collect
  // time because the alternative - deriving it at lookup - sits on the hottest
  // path there is: a bare type reference must prefer the arity-0 declaration
  // (16.1.2), so EVERY type reference in the closure asks the question. Reading
  // it off the declaration there cost +1.7% even in its cheapest structural
  // form; a set membership test costs nothing.
  // sfVarArgs (a routine whose parameter scope's owner carries `varargs`) and
  // sfDefaultArrayProp (a property with an index list AND `default`) are
  // stamped at the end of Phase 1 for the same reason AND because the other
  // readers are CROSS-model: overload scoring and default-property indexing
  // ask them of a symbol in whatever unit declares it, and a text-demoted
  // declaring model has no directive text left to read (stage A1 of the
  // memory census found both answering "no" there).
  TSemaSymbolFlag = (sfBuiltin, sfExternalUnresolved, sfStrict, sfOverload,
    sfClassMember, sfForward, sfHasBody, sfHasDefault, sfGeneric, sfVarArgs,
    sfDefaultArrayProp);
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

  // A routine's HEAD word, resolved once - the display/classification facts
  // completion reads per row (see RoutineHead). Survives text demotion.
  TPasRoutineHead = (rhNone, rhProcedure, rhFunction, rhConstructor,
    rhDestructor, rhOperator);

  // Type category (mirrors DelphiAST TDataTypeID groupings) - set on
  // skType/skBuiltinType symbols; drives assignment/operator checks.
  TSemaTypeCat = (tcUnknown, tcInteger, tcFloat, tcBoolean, tcChar, tcString,
    tcPointer, tcNil, tcEnum, tcSet, tcArray, tcRecord, tcClass, tcInterface,
    tcProc, tcClassOf, tcVariant, tcFile);

  // Field order is LAYOUT: the strings, then the Integers, then the byte-sized
  // fields packed into the last word - 48 bytes, where Kind declared first
  // padded the record to 56 (memory census, 2026-09: -22 MB of symbol arrays
  // on the client closure). Nothing reads the record positionally.
  TSemaSymbol = record
    Name: string;          // original spelling
    NameLower: string;     // case-insensitive key
    DeclNode: Integer;     // CST index; NIL_NODE for builtins
    Scope: Integer;        // owning scope index
    TypeSym: Integer;      // resolved type symbol; NIL_SYM if unbound
    TypeNode: Integer;     // CST node of the declared type expr; NIL_NODE if none
    NextOverload: Integer;  // next routine of the same name in scope; NIL_SYM
    MemberScope: Integer;   // members of a type/unit for A.B lookup; NIL_SCOPE
    Flags: TSemaSymbolFlags;
    Kind: TSemaSymbolKind;
    Visibility: TSemaVisibility;
    TypeCat: TSemaTypeCat;  // category (types only); tcUnknown otherwise
    NumRank: Byte;          // numeric widening rank (int/float families); 0 else
  end;

  TSemaScopeKind = (sckSystem, sckUnit, sckImplementation, sckStruct,
    sckRoutine, sckWith, sckBlock, sckGenericParams, sckEnum);

  // Callback for EnumScopeDeep: one symbol, plus the scope it was found IN
  // (which may be a joined scope, not the one enumeration started from).
  TPasSymEnumProc = reference to procedure(ASym, AScope: Integer);

  // One slot of a TSemaNames table: the key's PasNameHash and the symbol it
  // names. S = -1 marks an empty slot (table mode only).
  TSemaNameSlot = record
    H: Cardinal;
    S: Integer;
  end;

  { A lookup key BY REFERENCE: Len chars at Text plus the key's PasNameHash.
    Two sources:
    - a key STRING (SemaKey): Text is that string's own buffer, compared
      exactly, so the string must outlive the key - a const parameter or a
      local does;
    - an identifier TOKEN (PasNodeKey / SemaSliceKey): Text is the source
      spelling, '&' already skipped, compared ASCII-folded and hashed folded -
      exactly the key PasNameKey / TPasTree.NodeNameLower would have built,
      without building it. Valid while the tree's token layer lives.
    Name keys were 45% of the analyzer's heap allocations (memory census,
    2026-09), nearly all of them a lower-cased copy of a token made only to be
    looked up once and dropped. }
  TSemaKey = record
    Text: PChar;
    Len: Integer;
    Hash: Cardinal;
    Raw: Boolean;    // Text is source spelling: fold 'A'..'Z' when comparing
  end;

  { A scope's names AND its declaration order, one record. Names: NameLower
    -> head symbol index. Replaced a TDictionary<string, Integer> per scope
    (memory audit, 2026-09): RTL dictionaries grow at 50% load and carry a
    96-byte object, so the client closure's 640k named scopes - half of them
    holding ONE name - cost ~200 B per name. Here there is no object and no
    stored key: a slot is the key's hash plus the symbol index, and the key
    itself is read from Symbols[S].NameLower, only when the hash matches.

    Up to CLinearNames names the slots are an array scanned linearly over
    its first Count slots (capacity odd while below CLinearNames, see
    AddOrSet; a spare slot is empty); beyond, an open-addressing table,
    pow2 capacity,
    at most 75% full, linear probing. The hash is kept per slot for the
    misses: most lookups walk a scope chain and miss in most of its scopes,
    and a miss that compared hashes only never touches a symbol record.

    ORDER. The linear slots are appended in bind order, so while every bound
    symbol was a NEW name they already ARE the declaration order and no order
    list exists (FOrder nil) - true in all but ~3k of the client's 640k named
    scopes. The first bind that breaks it materializes FOrder from the slots:
    a same-name bind (an overload replaces the head in its slot), an
    order-only entry (AddOrder), or the switch to table mode.

    ASyms is the owning model's Symbols array - a table is only meaningful
    against the model whose symbol indexes it holds (the shared builtin seed
    qualifies because every adopting model gets the seed symbols at the same
    indexes, see TPasSemaModel.AdoptSeededSymbols). A value type: copying the
    record SHARES the arrays, which is what the seed template relies on;
    writers go through TSemaScope.EnsureOwnedContainers first. }
  TSemaNames = record
  private
    FSlots: TArray<TSemaNameSlot>;
    FCount: Integer;
    FOrderCount: Integer;
    FOrder: TArray<Integer>;       // nil = the slots are the order
    procedure Rehash(ACapacity: Integer);
    procedure MaterializeOrder;
    procedure AppendOrder(ASym: Integer);
  public
    function Find(const AKey: TSemaKey;
      const ASyms: TArray<TSemaSymbol>): Integer; inline;
    // Binds ASyms[ASym].NameLower (hash AHash) to ASym, replacing the symbol
    // a same-key slot held - TDictionary.AddOrSetValue's contract - and
    // appends ASym to the declaration order.
    procedure AddOrSet(AHash: Cardinal; ASym: Integer;
      const ASyms: TArray<TSemaSymbol>);
    // Declaration order only, no name binding.
    procedure AddOrder(ASym: Integer);
    procedure MakeUnique;
    property Count: Integer read FCount;
  end;
  PSemaNames = ^TSemaNames;

  { A scope's symbols in declaration order: a read-only view over its
    TSemaNames (Scope.Symbols). No managed field, so taking one per access
    costs no refcount traffic; valid while the scope lives and unchanged. }
  TSemaSymList = record
  public type
    TEnumerator = record
    private
      FNames: PSemaNames;
      FIdx: Integer;
      function GetCurrent: Integer; inline;
    public
      function MoveNext: Boolean; inline;
      property Current: Integer read GetCurrent;
    end;
  private
    FNames: PSemaNames;
    function GetItem(AIdx: Integer): Integer; inline;
    function GetCount: Integer; inline;
  public
    function ToArray: TArray<Integer>;
    function GetEnumerator: TEnumerator; inline;
    property Count: Integer read GetCount;
    property Items[AIdx: Integer]: Integer read GetItem; default;
  end;

  { The Int32-keyed maps a model keeps per node or per symbol (ExtRefMap,
    CallTarget(X), SymTypeX, ExprTypeX, AnonStructSyms). Replaced a
    TDictionary<Integer, V> each (memory audit, 2026-09): the RTL dictionary
    grows at 50% load and stores a hash code per slot, so on the client
    closure these maps sat at 34-36% load and cost 38-61 B per entry. Here a
    slot is the key and the value only, pow2 capacity, at most 75% full,
    linear probing, deletion by backward shift (no tombstones).

    Keys are node or symbol indexes - sequential runs - so the home slot is a
    Fibonacci hash of the key, not the key itself: an identity hash would lay
    a run into one contiguous cluster that every miss inside it walks to the
    end. Low(Integer) marks an empty slot and is the one key it cannot hold.

    The method names and contracts are TDictionary's (TryGetValue writes
    Default(V) on a miss, Add raises on a duplicate, Items[] raises on a
    missing key), so callers read the same. A value type: copying the record
    SHARES the slot array and forks the count - the maps live in model fields
    and are only ever used in place. A field of a class starts zeroed; a
    LOCAL one does not (only the array is), so a local needs
    `:= Default(TPasIntMap<V>)` before first use. }
  TPasIntMap<V> = record
  public type
    TSlot = TPair<Integer, V>;
    TEnumerator = record
    private
      FSlots: TArray<TSlot>;
      FIdx: Integer;
      function GetCurrent: TSlot; inline;
    public
      function MoveNext: Boolean; inline;
      property Current: TSlot read GetCurrent;
    end;
  private const
    CEmptyKey = Low(Integer);
  private
    FSlots: TArray<TSlot>;
    FCount: Integer;
    FShift: Integer;
    function Home(AKey: Integer): Integer; inline;
    function IndexOf(AKey: Integer): Integer;
    procedure Grow;
    function GetItem(AKey: Integer): V;
    procedure SetItem(AKey: Integer; const AValue: V);
  public
    function TryGetValue(AKey: Integer; var AValue: V): Boolean;
    function ContainsKey(AKey: Integer): Boolean; inline;
    procedure AddOrSetValue(AKey: Integer; const AValue: V);
    procedure Add(AKey: Integer; const AValue: V);
    procedure Remove(AKey: Integer);
    // Drops the slot array too: an emptied map holds no heap.
    procedure Clear;
    function GetEnumerator: TEnumerator; inline;
    property Count: Integer read FCount;
    property Items[AKey: Integer]: V read GetItem write SetItem; default;
  end;

  TSemaPoolSlot = record
    H: Cardinal;
    S: string;       // '' = empty slot
  end;

  { Phase 1's spelling pool (TPasSemaModel.FNamePool): a set of strings,
    open addressing, the PasNameHash kept per slot, pow2 capacity, at most
    75% full. Intern returns the pooled instance of AText's spelling (exact,
    case-sensitive), pooling AText itself the first time. A TDictionary
    <string, string> in its place cost ~4% of the client's analysis CPU.
    A LOCAL pool must be Clear'ed before use: a record local initializes its
    managed fields only, and a garbage FCount grows the table without end. }
  TSemaNamePool = record
  private
    FSlots: TArray<TSemaPoolSlot>;
    FCount: Integer;
    procedure Grow;
  public
    function Intern(const AText: string): string;
    // Intern of the ALen chars at AText - folded ('A'..'Z' only) when AFold -
    // without building the string unless the pool does not have it yet.
    function InternSlice(AText: PChar; ALen: Integer; AFold: Boolean): string;
    procedure Clear;
  end;

  TSemaKeyIndexSlot = record
    H: Cardinal;
    V1: Integer;     // value + 1; 0 = empty slot
    K: string;
  end;

  { Key string -> non-negative Integer, looked up by TSemaKey so a probe with a
    token's key builds no string. Open addressing, pow2 capacity, at most 75%
    full; TryAdd keeps the FIRST value added for a key (TDictionary.TryAdd).
    Keys must BE keys (PasNameKey / LowerCase form). A local one must be
    Clear'ed first, as TSemaNamePool. }
  TSemaKeyIndex = record
  private
    FSlots: TArray<TSemaKeyIndexSlot>;
    FCount: Integer;
    procedure Grow;
  public
    function TryAdd(const AKey: string; AValue: Integer): Boolean;
    function TryGet(const AKey: TSemaKey; out AValue: Integer): Boolean;
    procedure Clear;
    property Count: Integer read FCount;
  end;

  { One scope. A RECORD, stored inline in the model's TSemaScopeList: as a
    class every scope was its own heap block - a VMT and monitor slot, the
    block header and a list slot on top of the fields, 88 B per scope where
    the record is 56, and ~740k heap objects on the client closure to
    allocate and tear down (memory census, 2026-09).

    Reach it through the list (Model.Scopes[I], a PSemaScope) and never hold
    that pointer across an AddScope: the list grows by reallocation - the
    same discipline the Symbols arena has always needed. A local TSemaScope
    VARIABLE is a copy; writing to it changes nothing in the model.

    Field order is LAYOUT, as in TSemaSymbol: the byte-sized and Integer
    fields first, then the managed ones. }
  TSemaScope = record
    Kind: TSemaScopeKind;
    // True when Names SHARES its arrays with containers owned
    // elsewhere, read-only across models - today only the builtin seed
    // template (PasTree.Sema.Builtins). Any WRITE goes through
    // EnsureOwnedContainers first (copy-on-write), so a future pass that
    // declares into such a scope gets a private copy instead of corrupting
    // every other model's view.
    SharedContainers: Boolean;
    Parent: Integer;                       // scope index; NIL_SCOPE at root
    OwnerNode: Integer;                    // CST node that opened this scope
    // For a METHOD implementation's routine scope: the (innermost) struct
    // type symbol the qualified name resolved to (TFoo in TFoo.Bar). NIL_SYM
    // elsewhere. The project driver's inherited-member pass starts its
    // cross-unit ancestor walk here.
    StructSym: Integer;
    // Empty (Count 0, no heap) until the first name is bound - most scopes
    // never bind one; TPasSemaModel.BindName/AddToOrder fill it. Holds the
    // declaration order too, which Symbols reads.
    Names: TSemaNames;                     // NameLower -> symbol index (head)
    Additional: TArray<Integer>;           // joined scopes (system/with/ancestor)
    // Joined scopes checked BEFORE this scope's own names. Exactly one thing
    // needs that order and the spec is explicit about it (15.3.3): a HELPER
    // member hides the extended type's own member of the same name. Everything
    // else joined here - uses, with, ancestors, enums - is a fallback and
    // belongs in Additional. See JoinScopeShadowing.
    Shadowing: TArray<Integer>;
    procedure EnsureOwnedContainers;
    function GetSymbols: TSemaSymList; inline;
    // The scope's symbols in declaration order (a view over Names).
    property Symbols: TSemaSymList read GetSymbols;
  end;
  PSemaScope = ^TSemaScope;

  { Cutting a grown array to its count. NOT SetLength(A, Count): the memory
    manager shrinks a medium or large block by less than half IN PLACE and
    keeps the whole block, so the doubling slack stayed allocated - the
    census measured 162 MB held for 128 MB of symbols and 55 MB for 41 MB of
    scopes (2026-09). Exact allocates the exact array and moves the elements
    over. For arrays nothing points into. }
  TSemaArrayTrim = record
    class procedure Exact<T>(var A: TArray<T>; ACount: Integer); static;
  end;

  { A model's scopes, indexed by scope id: an array of TSemaScope records
    grown by doubling during Phase 1 and cut to exact length when it ends
    (TPasSemaResolver.Analyze). Items[I] is a POINTER into the array - valid
    until the next Add, see TSemaScope. Index-checked like the TObjectList it
    replaced. Lives inside the model object, so it starts zeroed; nothing
    else may declare one. }
  TSemaScopeList = record
  private
    FItems: TArray<TSemaScope>;
    FCount: Integer;
    class procedure RaiseIndex(AIdx, ACount: Integer); static;
    function GetItem(AIdx: Integer): PSemaScope; inline;
  public
    // A new scope: Kind/Parent/OwnerNode as given, StructSym NIL_SYM,
    // everything else empty. Returns its id.
    function Add(AKind: TSemaScopeKind; AParent, AOwnerNode: Integer): Integer;
    // Removes the scope Add returned last (the seed's fallback path).
    procedure DropLast;
    // Drops the growth slack.
    procedure Trim;
    procedure Clear;
    property Count: Integer read FCount;
    property Items[AIdx: Integer]: PSemaScope read GetItem; default;
  end;

  TPasSemaModel = class
  private
    FSymCount: Integer;
    // Diags' filled prefix. The array itself carries CAPACITY between
    // TrimDiags calls (AddDiag doubles instead of the old `Diags + [x]`,
    // which re-copied every managed record per append - O(n^2) on the
    // error-heavy units, ~2447 diags in corpus history). Everything outside
    // this unit reads Diags AFTER analysis, when TrimDiags has cut it back
    // to exact length; in-flight readers go through HasDiagAt, which stops
    // at the count.
    FDiagCount: Integer;
    // Phase 1's spelling pool (BeginNamePool..EndNamePool, around the
    // resolver's Run): text -> the one heap string AddSymbol hands out for
    // it. Every symbol used to own two fresh strings, Name and NameLower,
    // copied out of the token layer - 4.3M heap strings for 1.0M distinct
    // texts on the client closure (memory audit, 2026-09). Pooling within
    // the unit keeps 92 of those 191 MB and needs no lock: a model's Phase 1
    // runs on one thread. Off outside Phase 1 - later symbols (none today)
    // would simply not be pooled.
    FNamePool: TSemaNamePool;
    FNamePoolOn: Boolean;
    procedure GrowSyms;
    function FindByArityDeepK(AScope: Integer; const AKey: TSemaKey;
      AWantGeneric: Boolean): Integer;
  public
    Tree: TPasTree;                 // referenced, not owned
    Symbols: TArray<TSemaSymbol>;
    Scopes: TSemaScopeList;
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
    ExtRefMap: TPasIntMap<TPasExtRef>;           // node -> external symbol
    CallTarget: TPasIntMap<Integer>;             // nkCall node -> chosen routine
    // Cross-model call target (Phase 3c): the overload CrossType selected by
    // argument types among the merged local + used-units candidate set. Set
    // only when the winner is meaningful beyond CallTarget (cross-unit callee
    // or a real overload choice) - the future overload-precise navigation
    // jump reads this.
    CallTargetX: TPasIntMap<TPasExtRef>;
    // Phase 3c: cross-model typing (filled by the project driver; empty in a
    // standalone per-unit analysis). Entries exist only where they ADD to the
    // intra-unit result: a declared type / expression type that lives in
    // another model, or a generic instantiation of one.
    SymTypeX: TPasIntMap<TSemaXType>;            // symbol -> declared type
    ExprTypeX: TPasIntMap<TSemaXType>;           // node -> expression type
    UsesList: TArray<TPasUsesRef>;
    { Lower-cased `uses` names -> UnitId, both the full dotted name and its
      last segment, first entry wins - the same answer the ascending scan of
      UsesList gives. Built by the project driver's ResolveUses once the ids
      are assigned (UsesIndexed False until then, and in a standalone
      per-unit analysis); the scan it replaces ran per namespace-qualifier
      probe and, on a main form unit with hundreds of `uses`, cost more than
      the member walk. Probed by key, so a bare identifier costs no string. }
    UsesByName: TSemaKeyIndex;
    UsesIndexed: Boolean;
    AllUsesResolved: Boolean;       // gates E2003 (set by the project driver)
    UnitNameLower: string;          // this unit's own name, lower-cased
    // nkWithStmt nodes whose target member set is NOT fully known intra-unit:
    // the target's type could not be resolved at all, OR it resolved to a
    // same-unit struct whose ancestry continues in another unit (a class
    // derived from a cross-unit base, or from the implicit TObject) - see
    // PasTree.Sema.Resolver.ResolveOneWithStmt and AncestryLeavesUnit. In the
    // second case the target's OWN scope is open, but the inherited members
    // are not in it. Inside such a body ANY unqualified name might be a
    // member of the target - a member that shadows everything else (ch.05
    // sec. 5.7, dcc-verified against a class field, a local, a parameter, a
    // same-unit global, and even an inline var declared in the body itself).
    // So Phase 1's binding there is a best-effort GUESS: the project's
    // with pass revises it once the cross-unit type is known, and until then
    // any type derived from it is unreliable - which is why the typer stays
    // quiet over these nodes (see InUnopenedWithBody / TPasSemaTyper.Diag).
    WithUnopened: TArray<Integer>;
    { Keyword constraint node (`class`, `record`, `constructor` in a generic
      parameter list - an nkConstraint with no child) -> Ord of its token
      kind, filled by Phase 1. CheckConstraints reads the DECLARING model's
      constraints from every instantiating unit, so the answer must survive
      text demotion; a handful of entries per unit that declares generics. }
    KeywordConstraints: TPasIntMap<Byte>;
    { MEMORY-AUDIT sec. 6.4-4 stage 2 - TEXT DEMOTION state. When Demoted, the
      token layer is gone: Tree.Source.Visible is nil and every file's
      Source/Tokens/LineStarts are empty; Nodes, RefMap, ExtRefMap, Symbols,
      Scopes, SymTypeX all survive, so resolution and the generic machinery
      keep working (they are node-id/symbol-table driven - verified in the
      audit). Every text/position consumer either degrades through its
      existing bounds guards or asks TPasSemaProject.EnsureHydrated first.
      The Demoted* fields are the REHYDRATION IDENTITY CHECK: a re-preprocess
      must reproduce exactly this stream or the node token indices would lie. }
    { Snapshot ReleaseTransientMaps takes before freeing NodeScope: struct
      TYPE node -> its member scope's StructSym, for every scope owned by a
      struct-kind node. The one post-analysis reader of another model's
      NodeScope is ResolveTypeExpr's anonymous-struct branch (an inline
      `record ... end` in a type slot has no name, so RefMap has nothing) -
      this map is that branch's released-mode answer. Empty until a release;
      scopes are few, so it is tiny. }
    AnonStructSyms: TPasIntMap<Integer>;
    Demoted: Boolean;
    { True when this model's FINAL token stream came from the declared-pass
      re-preprocess (the per-unit $IF oracle) rather than the plain seeded
      first pass. Such a stream depended on MID-ANALYSIS oracle state and is
      not reproducible from cold - measured on the client closure: exactly
      these units (System.pas, System.Rtti, FastMM4...) failed the rehydration
      identity check. DemoteClosedUnits therefore skips them; they keep full
      text. A handful of units against ~3750 demoted. }
    OracleStream: Boolean;
    { The names the oracle was asked for that stream - every `Declared(X)`
      and symbol question (`SizeOf(T)`, a const) the first pass could not
      answer, lower-cased, dotted names split into their segments. Empty
      unless OracleStream. AnalyzeModuleOnly reads it: an interface edit that
      touches none of these names cannot flip a branch of this stream, so the
      model stays an ordinary consumer instead of forcing a rebuild (one
      project unit guarding on `Declared(RTLVersion131)` used to turn every
      edit of the hub unit it imports into a 7 s rebuild). }
    OracleNames: TArray<string>;
    DemotedVisCount: Integer;
    DemotedFileSizes: TArray<Integer>;    // Length(Files[i].Source)
    DemotedTokenCounts: TArray<Integer>;  // Length(Files[i].Tokens)
    { CONTENT fingerprint per file, not just a size one. Sizes and token
      counts alone accept any edit that keeps both - `foo` -> `bar` is the
      cheap one to reach - and rehydration would then install text and
      positions from a DIFFERENT parse than the one Symbols/RefMap were built
      from: a wrong answer where the contract above promises none. }
    DemotedFileHashes: TArray<Cardinal>;  // FNV-1a over Files[i].Source
    DemotedHeads: TArray<Byte>;           // per symbol: Ord(TPasRoutineHead)
    constructor Create(const ATree: TPasTree);

    function SymCount: Integer;
    function AddScope(AKind: TSemaScopeKind; AParent, AOwnerNode: Integer):
      Integer;
    procedure JoinScope(AScope, AAdditional: Integer);
    { Joins AShadowing so it is searched BEFORE AScope's own names - the one
      precedence a plain JoinScope cannot express. See TSemaScope.Shadowing. }
    procedure JoinScopeShadowing(AScope, AShadowing: Integer);
    // Adds a symbol to the arena (does not register a name). ANameKey, when
    // non-empty, is a PRECOMPUTED PasNameKey(AName) - callers that already
    // built the key for their own lookup pass it to avoid lowering twice.
    function AddSymbol(AScope: Integer; AKind: TSemaSymbolKind;
      const AName: string; ADeclNode: Integer;
      const ANameKey: string = ''): Integer; overload;
    { The same, named by the identifier token ANameNode (display name = its
      text, '&' kept; key = AKey, which must be PasNodeKey of that node): no
      string is built for a spelling the Phase-1 pool already holds. }
    function AddSymbol(AScope: Integer; AKind: TSemaSymbolKind;
      ANameNode, ADeclNode: Integer; const AKey: TSemaKey): Integer; overload;
    // Brackets Phase 1 (TPasSemaResolver.Analyze): between the two, AddSymbol
    // shares one heap string per distinct spelling (see FNamePool).
    procedure BeginNamePool;
    procedure EndNamePool;
    // Registers NameLower -> symbol in a scope's dictionary + order list.
    procedure BindName(AScope, ASym: Integer);
    // Appends to a scope's declaration-order list WITHOUT (re)binding a name -
    // the overload/duplicate branches of DeclareSym. Honours copy-on-write on
    // a shared-container scope, same as BindName.
    procedure AddToOrder(AScope, ASym: Integer);
    { Bulk-adopts a seed TEMPLATE: copies ASyms into Symbols[0..N-1] (string
      fields share their heap data by refcount - no per-name allocation) and
      re-stamps each record's Scope to AScope. ONLY valid on an empty symbol
      arena: the template's name dictionary maps names to indices 0..N-1.
      Returns False (and does nothing) when the arena is not empty - the
      caller then falls back to seeding symbol by symbol. }
    function AdoptSeededSymbols(const ASyms: TArray<TSemaSymbol>;
      AScope: Integer): Boolean;
    // Local lookup in one scope (no chain).
    function FindLocal(AScope: Integer; const ANameLower: string): Integer;
      overload;
    { Every lookup below also takes a TSemaKey - the string forms are that
      overload over SemaKey(ANameLower). A key built once (PasNodeKey over the
      referring identifier, or SemaKey over a string) carries its hash, so a
      chain walk over it hashes nothing. }
    function FindLocal(AScope: Integer; const AKey: TSemaKey): Integer;
      overload; inline;
    function FindLocalDeep(AScope: Integer; const AKey: TSemaKey;
      ADepth: Integer = 0): Integer; overload;
    function ResolveAt(AScope: Integer; const AKey: TSemaKey;
      AAtToken: Integer): Integer; overload;
    function ResolveByArityAt(AScope: Integer; const AKey: TSemaKey;
      AAtToken: Integer; AWantGeneric: Boolean): Integer; overload;
    { FindLocal / FindLocalDeep with the key's PasNameHash supplied by the
      caller. For every loop that looks ONE name up in a chain of scopes - a
      parent climb, an ancestor or helper walk, across models too (the hash
      is a function of the key alone): hash once before the loop. 84% of
      consecutive lookups on the client closure repeat the previous key, and
      rehashing it per scope was a third of the lookup cost. }
    function FindLocalH(AScope: Integer; const ANameLower: string;
      AHash: Cardinal): Integer; inline;
    function FindLocalDeepH(AScope: Integer; const ANameLower: string;
      AHash: Cardinal; ADepth: Integer = 0): Integer;
    // AScope's own names, then its Additional (joined) scopes, most-recently
    // -added first, EACH CHECKED THE SAME WAY (so a joined scope's own
    // joins are reachable too - e.g. a class's member scope has a nested
    // enum's values joined into IT; a routine implementing that class's
    // method joins the class's member scope in turn, and must still see the
    // enum values two joins deep). FindLocal alone is one level only; this
    // is what Resolve actually needs at each scope of its PARENT climb.
    function FindLocalDeep(AScope: Integer; const ANameLower: string;
      ADepth: Integer = 0): Integer; overload;
    { The ENUMERATING counterpart of FindLocalDeep, for completion: every
      symbol visible through AScope, reported in exactly the order the lookup
      would try them - Shadowing joins (recursive) first, then the scope's own
      declaration-order list, then Additional joins most-recently-added first
      (recursive). A caller deduplicating by NameLower and keeping the FIRST
      hit therefore reproduces FindLocalDeep's precedence. Does NOT climb
      Parent - that is the caller's chain walk, same split as the lookups. }
    procedure EnumScopeDeep(AScope: Integer; const AOnSym: TPasSymEnumProc;
      ADepth: Integer = 0);
    // Full lookup: self -> additional (reverse) -> parent -> ...
    function Resolve(AScope: Integer; const ANameLower: string): Integer;
      overload;
    function Resolve(AScope: Integer; const AKey: TSemaKey): Integer; overload;
    { Resolve honouring block-scope POSITION - see the implementation. Only a
      reference lookup passes a real AAtToken; everything else passes -1. }
    function ResolveAt(AScope: Integer; const ANameLower: string;
      AAtToken: Integer): Integer; overload;
    { ResolveAt restricted to one side of the GENERIC/non-generic split, since
      arity is part of a type's identity. See the implementation. }
    function ResolveByArityAt(AScope: Integer; const ANameLower: string;
      AAtToken: Integer; AWantGeneric: Boolean): Integer; overload;
    function FindByArityDeep(AScope: Integer; const ANameLower: string;
      AWantGeneric: Boolean): Integer;
    function DeclaredAfter(ASym, AAtToken: Integer): Boolean;
    { True when ANode sits in the BODY of a `with` listed in WithUnopened -
      see that field. An identifier inside a with's own TARGET expression is
      NOT in its scope (the target is evaluated in the enclosing one), hence
      the last-child test. WithUnopened is empty for the overwhelming
      majority of units, so this costs one length check on the hot path. }
    function InUnopenedWithBody(ANode: Integer): Boolean;
    { Frees the maps nothing reads after analysis for a unit the host is not
      EDITING: ExprType (a nodes-sized array), ExprTypeX and WithUnopened.
      Navigation reads none of them (grep-verified in MEMORY-AUDIT sec. 6.4-4 and
      re-verified 2026-08-23); completion reads them for the ACTIVE file only,
      which the caller keeps. ExprTypeX is emptied, not dropped, so existing
      TryGetValue readers need no guard. See
      TPasSemaProject.ReleaseTransientMaps for the contract - this is not
      called during any analysis. }
    procedure ReleaseTransientMaps;
    { The member-scope struct symbol stamped on a struct TYPE node - from
      NodeScope while it lives, from the release-time snapshot afterwards.
      NIL_SYM when the node owns no such scope. }
    function StructSymAtNode(ANode: Integer): Integer;
    { The innermost struct whose scope ENCLOSES ANode - the `Self` context
      there, as opposed to StructSymAtNode's "this node IS the struct".
      Climbs the node's parents to the nearest scope, then that scope's
      parents: StructSym is stamped both on a struct's own member scope and
      on a method IMPLEMENTATION's routine scope, so this answers inside a
      declaration and inside a body alike. NIL_SYM outside any struct.
      Reads NodeScope, so it is an ANALYSIS-TIME query - a demoted model
      (ReleaseTransientMaps) answers NIL_SYM. }
    function EnclosingStructSym(ANode: Integer): Integer;
    { The routine head word of ASym (skRoutine), from the head token - or,
      on a demoted model, from the snapshot DemoteText took. rhNone for a
      symbol that is not a routine or has no routine node. }
    function RoutineHead(ASym: Integer): TPasRoutineHead;
    { Stage 2 of the release: snapshots RoutineHead for every routine symbol
      and the stream identity counts, then frees the whole text layer
      (Visible + per-file Source/Tokens/LineStarts). See the Demoted field. }
    procedure DemoteText;
    { Installs APre as this model's token layer IF it is stream-identical to
      the demoted one (same file count, per-file source sizes and token
      counts, same visible count) - the guard that a changed file can only
      ever mean "no answer", never a wrong position. False leaves the model
      demoted. }
    function TryRehydrate(const APre: TPasPreprocessed): Boolean;
    { TryRehydrate's identity test alone, installing nothing: would APre
      reproduce this demoted model's stream? False on a model that is not
      demoted. The parse-donor path uses it to graft a DEMOTED donor's nodes
      onto a stream the adopting project preprocessed itself, leaving the
      donor untouched (it may be serving other readers). }
    function DemotedStreamMatches(const APre: TPasPreprocessed): Boolean;
    { The cheap half, before any preprocessing: does AText (what a run would
      read for Files[AFileIdx] now) have the demoted file's size and
      fingerprint? False on a model that is not demoted. }
    function DemotedFileMatches(AFileIdx: Integer; const AText: string): Boolean;
    procedure AddDiag(const ADiag: TSemaDiag);
    { The parser's own diagnostics, folded in as E2029 rows at the token they
      name. Without this a syntax error is INVISIBLE to every host that reads
      Diags - the demo showed only the false E2035 the truncated call caused,
      and nothing once that was fixed. dcc's nearest code: E2029 is its
      "X expected but Y found". }
    procedure AddParseDiags(const ADiags: TArray<TPasParseDiag>);
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
  `Foo` name the same thing - see the implementation. }
function PasNameKey(const AName: string): string;

{ The hash TSemaNames keys on: FNV-1a over the key's UTF-16 code units (one
  step per char, not per byte). Pass a lookup KEY (PasNameKey form). }
function PasNameHash(const AKey: string): Cardinal; inline;

{ A key string as a TSemaKey (see there): AKey must already BE a key. }
function SemaKey(const AKey: string): TSemaKey; inline;
{ The key of the ALen source chars at AText: '&' skipped, hashed folded. }
function SemaSliceKey(AText: PChar; ALen: Integer): TSemaKey;
{ The key of identifier node ANode of ATree, straight off its token -
  TPasTree.NodeNameLower's key, not built. Empty (Len 0) where NodeNameLower
  answers '' (no such node, no token layer). }
function PasNodeKey(ATree: TPasTree; ANode: Integer): TSemaKey;
{ Does the key string ANameLower equal AKey? The comparison TSemaNames uses. }
function SemaKeyEquals(const ANameLower: string; const AKey: TSemaKey): Boolean;
  inline;
{ SemaKeyEquals' folding half: the AKey.Len chars at AName (a key) against a
  Raw key. Out of line - a loop does not inline. }
function SemaRawKeyEquals(AName: PChar; const AKey: TSemaKey): Boolean;
{ The key as a string (PasNameKey form) - for the rare caller that must keep
  or concatenate it. }
function SemaKeyText(const AKey: TSemaKey): string;

implementation

uses
  System.SysUtils;

const
  // Names up to this many: an exact-length array scanned linearly. Measured
  // on the client closure: 80% of named scopes hold <= 4 names, and a miss
  // over <= 8 hashes is one cache line.
  CLinearNames = 8;

// $Q- for the same reason as SourceFingerprint below: the wraparound IS the
// algorithm, and the checked test build compiles with $Q+.
{$IFOPT Q+}{$DEFINE PT_RESTORE_Q}{$OVERFLOWCHECKS OFF}{$ENDIF}
function PasNameHash(const AKey: string): Cardinal;
var
  LIdx: Integer;
begin
  Result := 2166136261;
  for LIdx := 1 to Length(AKey) do
    Result := (Result xor Cardinal(Ord(AKey[LIdx]))) * 16777619;
end;

// PasNameHash of the folded slice - the same value PasNameHash gives the
// string PasNameKey would build from it.
function FoldedSliceHash(AText: PChar; ALen: Integer): Cardinal;
var
  LIdx: Integer;
  LCh: Char;
begin
  Result := 2166136261;
  for LIdx := 0 to ALen - 1 do
  begin
    LCh := AText[LIdx];
    if (LCh >= 'A') and (LCh <= 'Z') then
      Inc(LCh, 32);
    Result := (Result xor Cardinal(Ord(LCh))) * 16777619;
  end;
end;

function RawSliceHash(AText: PChar; ALen: Integer): Cardinal;
var
  LIdx: Integer;
begin
  Result := 2166136261;
  for LIdx := 0 to ALen - 1 do
    Result := (Result xor Cardinal(Ord(AText[LIdx]))) * 16777619;
end;
{$IFDEF PT_RESTORE_Q}{$OVERFLOWCHECKS ON}{$UNDEF PT_RESTORE_Q}{$ENDIF}

function SemaKey(const AKey: string): TSemaKey;
begin
  Result.Text := Pointer(AKey);
  Result.Len := Length(AKey);
  Result.Hash := PasNameHash(AKey);
  Result.Raw := False;
end;

function SemaSliceKey(AText: PChar; ALen: Integer): TSemaKey;
begin
  if (ALen > 0) and (AText^ = '&') then
  begin
    Inc(AText);
    Dec(ALen);
  end;
  Result.Text := AText;
  Result.Len := ALen;
  Result.Hash := FoldedSliceHash(AText, ALen);
  Result.Raw := True;
end;

function PasNodeKey(ATree: TPasTree; ANode: Integer): TSemaKey;
var
  LText: PChar;
  LLen: Integer;
begin
  ATree.NodeSlice(ANode, LText, LLen);
  Result := SemaSliceKey(LText, LLen);
end;

function SemaRawKeyEquals(AName: PChar; const AKey: TSemaKey): Boolean;
var
  LIdx: Integer;
  LCh: Char;
begin
  for LIdx := 0 to AKey.Len - 1 do
  begin
    LCh := AKey.Text[LIdx];
    if (LCh >= 'A') and (LCh <= 'Z') then
      Inc(LCh, 32);
    if LCh <> AName[LIdx] then
      Exit(False);
  end;
  Result := True;
end;

function SemaKeyEquals(const ANameLower: string; const AKey: TSemaKey): Boolean;
begin
  // Same instance first: a key taken from a symbol's own (pooled) NameLower.
  if Length(ANameLower) <> AKey.Len then
    Result := False
  else if Pointer(ANameLower) = AKey.Text then
    Result := True
  else if AKey.Raw then
    Result := SemaRawKeyEquals(Pointer(ANameLower), AKey)
  else
    Result := CompareMem(Pointer(ANameLower), AKey.Text,
      AKey.Len * SizeOf(Char));
end;

function SameNameKey(const A, B: string): Boolean; inline;
begin
  Result := (Pointer(A) = Pointer(B)) or
    ((Length(A) = Length(B)) and
     CompareMem(Pointer(A), Pointer(B), Length(A) * SizeOf(Char)));
end;

function SemaKeyText(const AKey: TSemaKey): string;
var
  LIdx: Integer;
  LCh: Char;
  LOut: PChar;
begin
  SetString(Result, AKey.Text, AKey.Len);
  if AKey.Raw then
  begin
    LOut := Pointer(Result);
    for LIdx := 0 to AKey.Len - 1 do
    begin
      LCh := LOut[LIdx];
      if (LCh >= 'A') and (LCh <= 'Z') then
        LOut[LIdx] := Char(Ord(LCh) + 32);
    end;
  end;
end;

{ TSemaNames }

function TSemaNames.Find(const AKey: TSemaKey;
  const ASyms: TArray<TSemaSymbol>): Integer;
var
  LIdx, LMask: Integer;
begin
  if FCount <= CLinearNames then
  begin
    for LIdx := 0 to FCount - 1 do
      if (FSlots[LIdx].H = AKey.Hash) and
         SemaKeyEquals(ASyms[FSlots[LIdx].S].NameLower, AKey) then
        Exit(FSlots[LIdx].S);
    Exit(NIL_SYM);
  end;
  LMask := High(FSlots);
  LIdx := Integer(AKey.Hash and Cardinal(LMask));
  repeat
    Result := FSlots[LIdx].S;
    if Result = NIL_SYM then
      Exit;   // empty slot: not here
    if (FSlots[LIdx].H = AKey.Hash) and
       SemaKeyEquals(ASyms[Result].NameLower, AKey) then
      Exit;
    LIdx := (LIdx + 1) and LMask;
  until False;
end;

procedure TSemaNames.Rehash(ACapacity: Integer);
var
  LOld: TArray<TSemaNameSlot>;
  LIdx, LAt, LMask: Integer;
begin
  LOld := FSlots;
  SetLength(FSlots, 0);
  SetLength(FSlots, ACapacity);
  for LIdx := 0 to ACapacity - 1 do
    FSlots[LIdx].S := NIL_SYM;
  LMask := ACapacity - 1;
  for LIdx := 0 to High(LOld) do
    if LOld[LIdx].S <> NIL_SYM then
    begin
      LAt := Integer(LOld[LIdx].H and Cardinal(LMask));
      while FSlots[LAt].S <> NIL_SYM do
        LAt := (LAt + 1) and LMask;
      FSlots[LAt] := LOld[LIdx];
    end;
end;

procedure TSemaNames.AddOrSet(AHash: Cardinal; ASym: Integer;
  const ASyms: TArray<TSemaSymbol>);
var
  LIdx, LMask, LCap: Integer;
begin
  if FCount <= CLinearNames then
  begin
    for LIdx := 0 to FCount - 1 do
      if (FSlots[LIdx].H = AHash) and
         SameNameKey(ASyms[FSlots[LIdx].S].NameLower, ASyms[ASym].NameLower) then
      begin
        // The head moves to ASym: the slots stop being the order.
        MaterializeOrder;
        FSlots[LIdx].S := ASym;
        AppendOrder(ASym);
        Exit;
      end;
    if FCount < CLinearNames then
    begin
      // Capacities 1, 3, 5, 7, CLinearNames. On Win64 a dynarray asks for
      // 16 + 8 per slot and the memory manager's small blocks (its own
      // 8-byte header included) come in steps of 16, so 2k+1 slots sit in
      // the very block 2k take (probed: 1 -> 32, 2..3 -> 48, 4..5 -> 64,
      // 6..7 -> 80). Growing by one reallocated for nothing every other bind
      // (2.2 M calls per client analysis, memory census 2026-09). The spare
      // slot is marked empty, so a reader of the whole array (Rehash) never
      // takes it for symbol 0.
      if FCount = Length(FSlots) then
      begin
        if FCount = 0 then
          LCap := 1
        else if FCount + 2 > CLinearNames then
          LCap := CLinearNames
        else
          LCap := FCount + 2;
        SetLength(FSlots, LCap);
        if LCap > FCount + 1 then
          FSlots[FCount + 1].S := NIL_SYM;
      end;
      FSlots[FCount].H := AHash;
      FSlots[FCount].S := ASym;
      Inc(FCount);
      if FOrder <> nil then
        AppendOrder(ASym);
      Exit;
    end;
    // The name after CLinearNames: linear array -> table, which has no order.
    MaterializeOrder;
    Rehash(16);
  end;
  LMask := High(FSlots);
  LIdx := Integer(AHash and Cardinal(LMask));
  while FSlots[LIdx].S <> NIL_SYM do
  begin
    if (FSlots[LIdx].H = AHash) and
       SameNameKey(ASyms[FSlots[LIdx].S].NameLower, ASyms[ASym].NameLower) then
    begin
      FSlots[LIdx].S := ASym;
      AppendOrder(ASym);
      Exit;
    end;
    LIdx := (LIdx + 1) and LMask;
  end;
  // A new name. Keep the table at most 75% full so a miss meets an empty
  // slot within a few probes.
  if (FCount + 1) * 4 > Length(FSlots) * 3 then
  begin
    Rehash(Length(FSlots) * 2);
    LMask := High(FSlots);
    LIdx := Integer(AHash and Cardinal(LMask));
    while FSlots[LIdx].S <> NIL_SYM do
      LIdx := (LIdx + 1) and LMask;
  end;
  FSlots[LIdx].H := AHash;
  FSlots[LIdx].S := ASym;
  Inc(FCount);
  AppendOrder(ASym);
end;

procedure TSemaNames.MaterializeOrder;
var
  LIdx: Integer;
begin
  if FOrder <> nil then
    Exit;
  // The slots are still in bind order (linear mode, every bind a new name):
  // they become the explicit list. An empty scope yields nil here, and the
  // AppendOrder that always follows makes it explicit.
  SetLength(FOrder, FCount);
  for LIdx := 0 to FCount - 1 do
    FOrder[LIdx] := FSlots[LIdx].S;
  FOrderCount := FCount;
end;

procedure TSemaNames.AppendOrder(ASym: Integer);
begin
  if FOrderCount = Length(FOrder) then
  begin
    // Exact while small - most scopes stop at a handful - then by half.
    if FOrderCount < CLinearNames then
      SetLength(FOrder, FOrderCount + 1)
    else
      SetLength(FOrder, FOrderCount + FOrderCount div 2);
  end;
  FOrder[FOrderCount] := ASym;
  Inc(FOrderCount);
end;

procedure TSemaNames.AddOrder(ASym: Integer);
begin
  MaterializeOrder;
  AppendOrder(ASym);
end;

procedure TSemaNames.MakeUnique;
begin
  FSlots := Copy(FSlots);
  if FOrder <> nil then
    FOrder := Copy(FOrder, 0, FOrderCount);
end;

{ TSemaNamePool }

procedure TSemaNamePool.Grow;
var
  LOld: TArray<TSemaPoolSlot>;
  LIdx, LAt, LMask, LCap: Integer;
begin
  LOld := FSlots;
  LCap := Length(LOld) * 2;
  if LCap < 64 then
    LCap := 64;
  FSlots := nil;
  SetLength(FSlots, LCap);
  LMask := LCap - 1;
  for LIdx := 0 to High(LOld) do
    if LOld[LIdx].S <> '' then
    begin
      LAt := Integer(LOld[LIdx].H and Cardinal(LMask));
      while FSlots[LAt].S <> '' do
        LAt := (LAt + 1) and LMask;
      FSlots[LAt] := LOld[LIdx];
    end;
end;

function TSemaNamePool.Intern(const AText: string): string;
var
  LHash: Cardinal;
  LIdx, LMask: Integer;
begin
  if AText = '' then
    Exit('');
  if (FCount + 1) * 4 > Length(FSlots) * 3 then
    Grow;
  LHash := PasNameHash(AText);
  LMask := High(FSlots);
  LIdx := Integer(LHash and Cardinal(LMask));
  while FSlots[LIdx].S <> '' do
  begin
    if (FSlots[LIdx].H = LHash) and (FSlots[LIdx].S = AText) then
      Exit(FSlots[LIdx].S);
    LIdx := (LIdx + 1) and LMask;
  end;
  FSlots[LIdx].H := LHash;
  FSlots[LIdx].S := AText;
  Inc(FCount);
  Result := AText;
end;

function TSemaNamePool.InternSlice(AText: PChar; ALen: Integer;
  AFold: Boolean): string;
var
  LHash: Cardinal;
  LIdx, LMask: Integer;
  LKey: TSemaKey;
begin
  if ALen = 0 then
    Exit('');
  if (FCount + 1) * 4 > Length(FSlots) * 3 then
    Grow;
  // Slots hold exact spellings hashed with PasNameHash, so a folded slice
  // hashes folded and compares folded - SemaKeyEquals' Raw mode - and an
  // exact one hashes and compares as is.
  LKey.Text := AText;
  LKey.Len := ALen;
  LKey.Raw := AFold;
  if AFold then
    LHash := FoldedSliceHash(AText, ALen)
  else
    LHash := RawSliceHash(AText, ALen);
  LMask := High(FSlots);
  LIdx := Integer(LHash and Cardinal(LMask));
  while FSlots[LIdx].S <> '' do
  begin
    if (FSlots[LIdx].H = LHash) and SemaKeyEquals(FSlots[LIdx].S, LKey) then
      Exit(FSlots[LIdx].S);
    LIdx := (LIdx + 1) and LMask;
  end;
  LKey.Hash := LHash;
  if AFold then
    Result := SemaKeyText(LKey)
  else
    SetString(Result, AText, ALen);
  FSlots[LIdx].H := LHash;
  FSlots[LIdx].S := Result;
  Inc(FCount);
end;

procedure TSemaNamePool.Clear;
begin
  FSlots := nil;
  FCount := 0;
end;

{ TSemaKeyIndex }

procedure TSemaKeyIndex.Grow;
var
  LOld: TArray<TSemaKeyIndexSlot>;
  LIdx, LAt, LMask, LCap: Integer;
begin
  LOld := FSlots;
  LCap := Length(LOld) * 2;
  if LCap < 16 then
    LCap := 16;
  FSlots := nil;
  SetLength(FSlots, LCap);
  LMask := LCap - 1;
  for LIdx := 0 to High(LOld) do
    if LOld[LIdx].V1 <> 0 then
    begin
      LAt := Integer(LOld[LIdx].H and Cardinal(LMask));
      while FSlots[LAt].V1 <> 0 do
        LAt := (LAt + 1) and LMask;
      FSlots[LAt] := LOld[LIdx];
    end;
end;

function TSemaKeyIndex.TryAdd(const AKey: string; AValue: Integer): Boolean;
var
  LHash: Cardinal;
  LIdx, LMask: Integer;
begin
  if (FCount + 1) * 4 > Length(FSlots) * 3 then
    Grow;
  LHash := PasNameHash(AKey);
  LMask := High(FSlots);
  LIdx := Integer(LHash and Cardinal(LMask));
  while FSlots[LIdx].V1 <> 0 do
  begin
    if (FSlots[LIdx].H = LHash) and (FSlots[LIdx].K = AKey) then
      Exit(False);
    LIdx := (LIdx + 1) and LMask;
  end;
  FSlots[LIdx].H := LHash;
  FSlots[LIdx].V1 := AValue + 1;
  FSlots[LIdx].K := AKey;
  Inc(FCount);
  Result := True;
end;

function TSemaKeyIndex.TryGet(const AKey: TSemaKey;
  out AValue: Integer): Boolean;
var
  LIdx, LMask: Integer;
begin
  if FCount = 0 then
    Exit(False);
  LMask := High(FSlots);
  LIdx := Integer(AKey.Hash and Cardinal(LMask));
  while FSlots[LIdx].V1 <> 0 do
  begin
    if (FSlots[LIdx].H = AKey.Hash) and SemaKeyEquals(FSlots[LIdx].K, AKey) then
    begin
      AValue := FSlots[LIdx].V1 - 1;
      Exit(True);
    end;
    LIdx := (LIdx + 1) and LMask;
  end;
  Result := False;
end;

procedure TSemaKeyIndex.Clear;
begin
  FSlots := nil;
  FCount := 0;
end;

{ TSemaSymList }

function TSemaSymList.TEnumerator.GetCurrent: Integer;
begin
  if FNames.FOrder = nil then
    Result := FNames.FSlots[FIdx].S
  else
    Result := FNames.FOrder[FIdx];
end;

function TSemaSymList.TEnumerator.MoveNext: Boolean;
begin
  Inc(FIdx);
  if FNames.FOrder = nil then
    Result := FIdx < FNames.FCount
  else
    Result := FIdx < FNames.FOrderCount;
end;

function TSemaSymList.GetCount: Integer;
begin
  if FNames.FOrder = nil then
    Result := FNames.FCount
  else
    Result := FNames.FOrderCount;
end;

function TSemaSymList.GetItem(AIdx: Integer): Integer;
begin
  if FNames.FOrder = nil then
    Result := FNames.FSlots[AIdx].S
  else
    Result := FNames.FOrder[AIdx];
end;

function TSemaSymList.GetEnumerator: TEnumerator;
begin
  Result.FNames := FNames;
  Result.FIdx := -1;
end;

function TSemaSymList.ToArray: TArray<Integer>;
var
  LIdx: Integer;
begin
  SetLength(Result, GetCount);
  for LIdx := 0 to High(Result) do
    Result[LIdx] := GetItem(LIdx);
end;

{ TPasIntMap<V> }

function TPasIntMap<V>.TEnumerator.GetCurrent: TSlot;
begin
  Result := FSlots[FIdx];
end;

function TPasIntMap<V>.TEnumerator.MoveNext: Boolean;
begin
  repeat
    Inc(FIdx);
    if FIdx > High(FSlots) then
      Exit(False);
  until FSlots[FIdx].Key <> CEmptyKey;
  Result := True;
end;

function TPasIntMap<V>.Home(AKey: Integer): Integer;
begin
  // Fibonacci hashing: the top bits of key * 2^32/phi. The product is taken
  // in 64 bits so it cannot overflow under $Q+; the casts truncate, they do
  // not range-check.
  Result := Integer(Cardinal(UInt64(Cardinal(AKey)) * $9E3779B9) shr FShift);
end;

function TPasIntMap<V>.IndexOf(AKey: Integer): Integer;
var
  LMask, LKey: Integer;
begin
  if FCount = 0 then
    Exit(-1);
  LMask := High(FSlots);
  Result := Home(AKey);
  repeat
    LKey := FSlots[Result].Key;
    if LKey = AKey then
      Exit;
    if LKey = CEmptyKey then
      Exit(-1);
    Result := (Result + 1) and LMask;
  until False;
end;

procedure TPasIntMap<V>.Grow;
var
  LOld: TArray<TSlot>;
  LIdx, LAt, LMask, LCap: Integer;
begin
  LOld := FSlots;
  LCap := Length(LOld) * 2;
  if LCap < 4 then
    LCap := 4;
  FSlots := nil;
  SetLength(FSlots, LCap);
  for LIdx := 0 to LCap - 1 do
    FSlots[LIdx].Key := CEmptyKey;
  FShift := 32;
  while (1 shl (32 - FShift)) < LCap do
    Dec(FShift);
  LMask := LCap - 1;
  for LIdx := 0 to High(LOld) do
    if LOld[LIdx].Key <> CEmptyKey then
    begin
      LAt := Home(LOld[LIdx].Key);
      while FSlots[LAt].Key <> CEmptyKey do
        LAt := (LAt + 1) and LMask;
      FSlots[LAt] := LOld[LIdx];
    end;
end;

function TPasIntMap<V>.GetItem(AKey: Integer): V;
var
  LIdx: Integer;
begin
  LIdx := IndexOf(AKey);
  if LIdx < 0 then
    raise EListError.CreateFmt('TPasIntMap: key %d not found', [AKey]);
  Result := FSlots[LIdx].Value;
end;

procedure TPasIntMap<V>.SetItem(AKey: Integer; const AValue: V);
var
  LIdx: Integer;
begin
  LIdx := IndexOf(AKey);
  if LIdx < 0 then
    raise EListError.CreateFmt('TPasIntMap: key %d not found', [AKey]);
  FSlots[LIdx].Value := AValue;
end;

function TPasIntMap<V>.TryGetValue(AKey: Integer; var AValue: V): Boolean;
var
  LIdx: Integer;
begin
  LIdx := IndexOf(AKey);
  Result := LIdx >= 0;
  if Result then
    AValue := FSlots[LIdx].Value
  else
    AValue := Default(V);
end;

function TPasIntMap<V>.ContainsKey(AKey: Integer): Boolean;
begin
  Result := IndexOf(AKey) >= 0;
end;

procedure TPasIntMap<V>.AddOrSetValue(AKey: Integer; const AValue: V);
var
  LIdx, LMask: Integer;
begin
  Assert(AKey <> CEmptyKey);
  if (FCount + 1) * 4 > Length(FSlots) * 3 then
  begin
    // Grow only for a NEW key: an overwrite at the threshold must not
    // double a table that is not getting fuller.
    LIdx := IndexOf(AKey);
    if LIdx >= 0 then
    begin
      FSlots[LIdx].Value := AValue;
      Exit;
    end;
    Grow;
  end;
  LMask := High(FSlots);
  LIdx := Home(AKey);
  while FSlots[LIdx].Key <> CEmptyKey do
  begin
    if FSlots[LIdx].Key = AKey then
    begin
      FSlots[LIdx].Value := AValue;
      Exit;
    end;
    LIdx := (LIdx + 1) and LMask;
  end;
  FSlots[LIdx].Key := AKey;
  FSlots[LIdx].Value := AValue;
  Inc(FCount);
end;

procedure TPasIntMap<V>.Add(AKey: Integer; const AValue: V);
begin
  if ContainsKey(AKey) then
    raise EListError.CreateFmt('TPasIntMap: duplicate key %d', [AKey]);
  AddOrSetValue(AKey, AValue);
end;

procedure TPasIntMap<V>.Remove(AKey: Integer);
var
  LHole, LIdx, LHome, LMask: Integer;
begin
  LHole := IndexOf(AKey);
  if LHole < 0 then
    Exit;
  // Backward shift: pull later members of the probe run into the hole when
  // their home slot does not lie cyclically in (hole, idx] - otherwise a
  // lookup for them would stop at the hole and miss.
  LMask := High(FSlots);
  LIdx := LHole;
  repeat
    LIdx := (LIdx + 1) and LMask;
    if FSlots[LIdx].Key = CEmptyKey then
      Break;
    LHome := Home(FSlots[LIdx].Key);
    if LHole <= LIdx then
    begin
      if (LHole < LHome) and (LHome <= LIdx) then
        Continue;
    end
    else if (LHole < LHome) or (LHome <= LIdx) then
      Continue;
    FSlots[LHole] := FSlots[LIdx];
    LHole := LIdx;
  until False;
  FSlots[LHole].Key := CEmptyKey;
  FSlots[LHole].Value := Default(V);
  Dec(FCount);
end;

procedure TPasIntMap<V>.Clear;
begin
  FSlots := nil;
  FCount := 0;
  FShift := 0;
end;

function TPasIntMap<V>.GetEnumerator: TEnumerator;
begin
  Result.FSlots := FSlots;
  Result.FIdx := -1;
end;

{ TSemaScopeList }

class procedure TSemaScopeList.RaiseIndex(AIdx, ACount: Integer);
begin
  raise EArgumentOutOfRangeException.CreateFmt(
    'scope index %d out of range (count %d)', [AIdx, ACount]);
end;

function TSemaScopeList.GetItem(AIdx: Integer): PSemaScope;
begin
  if Cardinal(AIdx) >= Cardinal(FCount) then
    RaiseIndex(AIdx, FCount);
  Result := @FItems[AIdx];
end;

function TSemaScopeList.Add(AKind: TSemaScopeKind; AParent,
  AOwnerNode: Integer): Integer;
var
  LScope: PSemaScope;
begin
  if FCount = Length(FItems) then
    if FCount < 8 then
      SetLength(FItems, 8)
    else
      SetLength(FItems, FCount * 2);
  Result := FCount;
  Inc(FCount);
  // A fresh slot is zeroed (SetLength, or DropLast's Default).
  LScope := @FItems[Result];
  LScope.Kind := AKind;
  LScope.Parent := AParent;
  LScope.OwnerNode := AOwnerNode;
  LScope.StructSym := NIL_SYM;
  // Names/Symbols stay empty, with no heap behind them, until the first bind
  // (see BindName): scopes are minted per routine, per declaring block, per
  // with, per enum - and many never declare a name.
end;

procedure TSemaScopeList.DropLast;
begin
  Dec(FCount);
  FItems[FCount] := Default(TSemaScope);
end;

procedure TSemaScopeList.Trim;
begin
  TSemaArrayTrim.Exact<TSemaScope>(FItems, FCount);
end;

{ TSemaArrayTrim }

class procedure TSemaArrayTrim.Exact<T>(var A: TArray<T>; ACount: Integer);
var
  LExact: TArray<T>;
begin
  if Length(A) = ACount then
    Exit;
  // A fresh exact array, the elements moved over bitwise - managed fields
  // change owner, no refcount traffic - and the old slots zeroed so
  // releasing the old array finalizes nothing.
  SetLength(LExact, ACount);
  if ACount > 0 then
  begin
    Move(A[0], LExact[0], ACount * SizeOf(T));
    FillChar(A[0], ACount * SizeOf(T), 0);
  end;
  A := LExact;
end;

procedure TSemaScopeList.Clear;
begin
  FItems := nil;
  FCount := 0;
end;

{ TSemaScope }

procedure TSemaScope.EnsureOwnedContainers;
begin
  if not SharedContainers then
    Exit;
  // Copy-on-write off the shared seed containers: from here on this scope
  // owns private copies and mutating it is ordinary.
  Names.MakeUnique;
  SharedContainers := False;
end;

function TSemaScope.GetSymbols: TSemaSymList;
begin
  Result.FNames := @Names;
end;

{ TPasSemaModel }

constructor TPasSemaModel.Create(const ATree: TPasTree);
begin
  inherited Create;
  Tree := ATree;
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

function TPasSemaModel.SymCount: Integer;
begin
  Result := FSymCount;
end;

procedure TPasSemaModel.GrowSyms;
begin
  // Phase 1 cuts the arena to exact length, possibly 0.
  if FSymCount = Length(Symbols) then
    if Length(Symbols) < 32 then
      SetLength(Symbols, 64)
    else
      SetLength(Symbols, Length(Symbols) * 2);
end;

function TPasSemaModel.AddScope(AKind: TSemaScopeKind; AParent,
  AOwnerNode: Integer): Integer;
begin
  Result := Scopes.Add(AKind, AParent, AOwnerNode);
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
  all, because that is what the source said - the key must not keep it. Applied
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
  // returned as-is - a refcount bump instead of an allocation. Callers often
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
  // Single pass, one allocation - ASCII-only folding, exactly what the old
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
  if not FNamePoolOn then
  begin
    Symbols[Result].Name := AName;
    if ANameKey <> '' then
      Symbols[Result].NameLower := ANameKey
    else
      Symbols[Result].NameLower := PasNameKey(AName);
  end
  else
  begin
    if ANameKey <> '' then
      Symbols[Result].NameLower := FNamePool.Intern(ANameKey)
    else
      Symbols[Result].NameLower := FNamePool.Intern(PasNameKey(AName));
    // A lower-case spelling IS its key: one string for both.
    if AName = Symbols[Result].NameLower then
      Symbols[Result].Name := Symbols[Result].NameLower
    else
      Symbols[Result].Name := FNamePool.Intern(AName);
  end;
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

function TPasSemaModel.AddSymbol(AScope: Integer; AKind: TSemaSymbolKind;
  ANameNode, ADeclNode: Integer; const AKey: TSemaKey): Integer;
var
  LText: PChar;
  LLen, LIdx: Integer;
  LIsKey: Boolean;
begin
  // The display spelling is the whole token ('&' kept, as NodeText gives it);
  // AKey is the same slice past any '&'. A spelling with no '&' and no
  // upper-case letter IS its key - one string for both, as in the string
  // overload.
  Tree.NodeSlice(ANameNode, LText, LLen);
  LIsKey := LLen = AKey.Len;
  if LIsKey then
    for LIdx := 0 to LLen - 1 do
      if (LText[LIdx] >= 'A') and (LText[LIdx] <= 'Z') then
      begin
        LIsKey := False;
        Break;
      end;
  if not FNamePoolOn then
  begin
    var LKeyText := SemaKeyText(AKey);
    var LName: string;
    if LIsKey then
      LName := LKeyText
    else
      SetString(LName, LText, LLen);
    Exit(AddSymbol(AScope, AKind, LName, ADeclNode, LKeyText));
  end;
  GrowSyms;
  Result := FSymCount;
  Inc(FSymCount);
  Symbols[Result].Kind := AKind;
  Symbols[Result].NameLower := FNamePool.InternSlice(AKey.Text, AKey.Len,
    True);
  if LIsKey then
    Symbols[Result].Name := Symbols[Result].NameLower
  else
    Symbols[Result].Name := FNamePool.InternSlice(LText, LLen, False);
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

procedure TPasSemaModel.BeginNamePool;
begin
  FNamePoolOn := True;
end;

procedure TPasSemaModel.EndNamePool;
begin
  FNamePoolOn := False;
  FNamePool.Clear;
end;

procedure TPasSemaModel.BindName(AScope, ASym: Integer);
begin
  Scopes[AScope].EnsureOwnedContainers;
  Scopes[AScope].Names.AddOrSet(PasNameHash(Symbols[ASym].NameLower), ASym,
    Symbols);
end;

procedure TPasSemaModel.AddToOrder(AScope, ASym: Integer);
begin
  Scopes[AScope].EnsureOwnedContainers;
  Scopes[AScope].Names.AddOrder(ASym);
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
    Symbols[LIdx].Scope := AScope;   // scope INDEX is per-model - re-stamp
  end;
  FSymCount := Length(ASyms);
  Result := True;
end;

function TPasSemaModel.FindLocal(AScope: Integer;
  const AKey: TSemaKey): Integer;
var
  LScope: PSemaScope;
begin
  // ANameLower must ALREADY be a key (PasNameKey / TPasTree.NodeNameLower).
  // Normalizing defensively here instead cost 3.3x total analysis time: this is
  // the hottest function in the analyzer, and PasNameKey allocates a string per
  // call. Cheap-looking belt-and-braces on a hot path is not cheap - the
  // boundary that BUILDS the key is the only place that can normalize for free,
  // because it is already producing a string there.
  // The empty test comes BEFORE the hash: ~14% of lookups land on a scope
  // that never declared anything, and hashing first made the replacement of
  // the per-scope TDictionary measurably slower than the dictionary's own nil
  // test had been.
  LScope := Scopes[AScope];
  if LScope.Names.Count = 0 then
    Result := NIL_SYM
  else
    Result := LScope.Names.Find(AKey, Symbols);
end;

function TPasSemaModel.FindLocal(AScope: Integer;
  const ANameLower: string): Integer;
begin
  Result := FindLocal(AScope, SemaKey(ANameLower));
end;

function TPasSemaModel.FindLocalH(AScope: Integer; const ANameLower: string;
  AHash: Cardinal): Integer;
var
  LKey: TSemaKey;
begin
  LKey.Text := Pointer(ANameLower);
  LKey.Len := Length(ANameLower);
  LKey.Hash := AHash;
  LKey.Raw := False;
  Result := FindLocal(AScope, LKey);
end;

function TPasSemaModel.FindLocalDeep(AScope: Integer;
  const ANameLower: string; ADepth: Integer): Integer;
begin
  Result := FindLocalDeep(AScope, SemaKey(ANameLower), ADepth);
end;

function TPasSemaModel.FindLocalDeepH(AScope: Integer;
  const ANameLower: string; AHash: Cardinal; ADepth: Integer): Integer;
var
  LKey: TSemaKey;
begin
  LKey.Text := Pointer(ANameLower);
  LKey.Len := Length(ANameLower);
  LKey.Hash := AHash;
  LKey.Raw := False;
  Result := FindLocalDeep(AScope, LKey, ADepth);
end;

function TPasSemaModel.FindLocalDeep(AScope: Integer;
  const AKey: TSemaKey; ADepth: Integer): Integer;
var
  LAdd: TArray<Integer>;
  LIdx: Integer;
begin
  // A DEPTH CAP, not a visited set: this is the hottest lookup in the
  // analyzer and real join chains are a handful of links deep, so the cost
  // has to be one integer compare. The resolver refuses to join a scope into
  // ITSELF, but nothing stops a MUTUAL pair - `TH1 = record helper for TH2;
  // TH2 = record helper for TH1;` is illegal for dcc yet representable
  // mid-edit - and an unguarded recursion there is a stack overflow, i.e. a
  // crashed editor process, on a file the analyzer is supposed to tolerate.
  if ADepth > 16 then
    Exit(NIL_SYM);
  // SHADOWING joins first, before the scope's own names: 15.3.3 - a helper
  // member hides the extended type's own member of the same name.
  // dcc-verified, and a component suite leans on it hard: its rich-edit
  // `TdxTagBaseInnerHelper = class helper for TdxTagBase` redeclares
  // `Importer` at the DERIVED importer type, and every `Importer.TagsStack`
  // in that unit needs the helper's, not the class's own. Empty for all but a
  // handful of scopes, so the common lookup pays one length test.
  LAdd := Scopes[AScope].Shadowing;
  for LIdx := High(LAdd) downto 0 do
  begin
    Result := FindLocalDeep(LAdd[LIdx], AKey, ADepth + 1);
    if Result <> NIL_SYM then
      Exit;
  end;
  Result := FindLocal(AScope, AKey);
  if Result <> NIL_SYM then
    Exit;
  // Joined scopes, most-recently-added first (uses/with priority) - each
  // recursed into the SAME way, not just FindLocal'd, so a joined scope's
  // own joins are reachable too.
  LAdd := Scopes[AScope].Additional;
  for LIdx := High(LAdd) downto 0 do
  begin
    Result := FindLocalDeep(LAdd[LIdx], AKey, ADepth + 1);
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
  // Same depth cap as the lookups (FindLocalDeep), for the same reason and
  // then one of its own: an enumerator visits EVERYTHING, so on a malformed
  // graph the cap costs duplicates rather than a hang.
  if ADepth > 16 then
    Exit;
  LJoins := Scopes[AScope].Shadowing;
  for LIdx := High(LJoins) downto 0 do
    EnumScopeDeep(LJoins[LIdx], AOnSym, ADepth + 1);
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

function TPasSemaModel.Resolve(AScope: Integer; const AKey: TSemaKey): Integer;
begin
  Result := ResolveAt(AScope, AKey, -1);
end;

{ FindLocalDeep restricted to one side of the generic split - the same-name chain
  first, then the joined scopes. See ResolveByArityAt.

  AWantGeneric False skips generic TYPES; True skips everything that is not one,
  which is deliberately narrower than "skip non-generic types": a routine or a
  variable of that name is not a wrong-arity type and must still be able to win,
  or `TFoo<T>` written where a VALUE named TFoo is in scope would resolve to a
  type it has no business finding. }
function TPasSemaModel.FindByArityDeep(AScope: Integer;
  const ANameLower: string; AWantGeneric: Boolean): Integer;
begin
  Result := FindByArityDeepK(AScope, SemaKey(ANameLower), AWantGeneric);
end;

function TPasSemaModel.FindByArityDeepK(AScope: Integer;
  const AKey: TSemaKey; AWantGeneric: Boolean): Integer;
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
  // SHADOWING joins first, exactly as FindLocalDeep orders them: this walk
  // searched a DIFFERENT scope set from the lookup it corrects, so a
  // right-arity candidate reachable only through a helper's shadowing join
  // stayed invisible to the arity-corrected relookup.
  LAdd := Scopes[AScope].Shadowing;
  for LIdx := High(LAdd) downto 0 do
  begin
    Result := FindByArityDeepK(LAdd[LIdx], AKey, AWantGeneric);
    if Result <> NIL_SYM then
      Exit;
  end;
  LSym := FindLocal(AScope, AKey);
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
    Result := FindByArityDeepK(LAdd[LIdx], AKey, AWantGeneric);
    if Result <> NIL_SYM then
      Exit;
  end;
  Result := NIL_SYM;
end;

{ ResolveAt restricted to one side of the generic split (16 sec. 16.1.2).

  ARITY is part of a type's identity, and BOTH directions of ignoring that are
  real, both set by one third-party library's base unit:

  - a BARE name must not bind to a generic. `Pointer<T> = record ... end` does
    not shadow the builtin `Pointer`, however much nearer it is - every
    `Pointer(X) := nil` in that unit was a type error until this existed.
  - a `Name<T>` must not bind to a NON-generic. `Nullable = record class var
    HasValue: string; end` sits beside `Nullable<T>` with a Boolean `HasValue`
    property, and a parameter typed `Nullable<T>` was resolving to the arity-0
    record - so `not other.HasValue` was `not <string>`.

  Called ONLY when the ordinary lookup already answered with the wrong side, and
  the reference's form is known - both tested at the call site, because this walk
  is not free and every name in the closure would otherwise pay for it. NIL_SYM
  means "no candidate of the wanted arity anywhere", and the caller then keeps
  the binding it has rather than losing the reference: that is dcc's error, not a
  reason to unbind. }
function TPasSemaModel.ResolveByArityAt(AScope: Integer;
  const ANameLower: string; AAtToken: Integer;
  AWantGeneric: Boolean): Integer;
begin
  Result := ResolveByArityAt(AScope, SemaKey(ANameLower), AAtToken,
    AWantGeneric);
end;

function TPasSemaModel.ResolveByArityAt(AScope: Integer;
  const AKey: TSemaKey; AAtToken: Integer; AWantGeneric: Boolean): Integer;
var
  LCur: Integer;
begin
  LCur := AScope;
  while LCur <> NIL_SCOPE do
  begin
    Result := FindByArityDeepK(LCur, AKey, AWantGeneric);
    if Result <> NIL_SYM then
      if (AAtToken < 0) or (Scopes[LCur].Kind <> sckBlock) or
         not DeclaredAfter(Result, AAtToken) then
        Exit;
    LCur := Scopes[LCur].Parent;
  end;
  Result := NIL_SYM;
end;

{ Resolve, but honouring the one scope kind whose names are visible only from
  their declaration onward: a BLOCK, where inline `var`/`const` live (3.1.3 -
  "visible from its declaration to the end of the enclosing block").

  Everything else stays order-independent, and deliberately: a routine's classic
  `var` section, a unit section and a struct's members are all visible
  throughout regardless of where the reference sits.

  AAtToken is the referring node's own first VISIBLE-stream index, which is
  monotonic in source order across include boundaries - that is what the
  visible stream is for - so comparing it against the declaration's is the
  whole test. Pass -1 to skip the check, which is what every lookup that is not
  resolving a reference does (a declaration completing a forward, a qualified
  segment, the aggregate walk). }
function TPasSemaModel.ResolveAt(AScope: Integer; const ANameLower: string;
  AAtToken: Integer): Integer;
begin
  Result := ResolveAt(AScope, SemaKey(ANameLower), AAtToken);
end;

function TPasSemaModel.ResolveAt(AScope: Integer; const AKey: TSemaKey;
  AAtToken: Integer): Integer;
var
  LCur: Integer;
begin
  LCur := AScope;
  while LCur <> NIL_SCOPE do
  begin
    Result := FindLocalDeep(LCur, AKey, 0);
    if Result <> NIL_SYM then
    begin
      if (AAtToken < 0) or (Scopes[LCur].Kind <> sckBlock) or
         not DeclaredAfter(Result, AAtToken) then
        Exit;
      // Declared BELOW the reference: not in scope yet, so keep walking
      // outward. Without this the inline declaration captured references
      // above it - a WRONG binding rather than a missing one, so it cost no
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
  // SymCount, not High(Symbols): the array carries capacity slack, and an
  // index into the zeroed tail passed this test and read a default record.
  if (ASym = NIL_SYM) or (ASym >= SymCount) then
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
  ExprTypeX.Clear;
  // NodeScope joins the released set - but its one post-analysis consumer
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
          AnonStructSyms.AddOrSetValue(LOwner, Scopes[LScope].StructSym);
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
  // The Parent read needs the SAME backstop the NodeScope read has (see
  // StructSymAtNode): a node id from another generation can be past this
  // tree's end, and the guarded lookup above would then be followed by an
  // unguarded array read.
  while (ANode <> NIL_NODE) and (ANode <= High(Tree.Nodes)) do
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
  // TryGetValue writes Default = 0 on a miss, and 0 is a real symbol index.
  else if not AnonStructSyms.TryGetValue(ANode, Result) then
    Result := NIL_SYM;
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

{ FNV-1a over the UTF-16 code units of a preprocessed file's source. Cheap
  (one pass, no allocation) and enough to reject the same-length edits the
  size fingerprint alone lets through - see DemotedFileHashes.

  $Q- because the wraparound IS the algorithm and the host's switches are
  not ours to inherit - the full story is on TDefinesNameComparer.GetHashCode
  in PasTree.Preprocessor. }
{$IFOPT Q+}{$DEFINE PT_RESTORE_Q}{$OVERFLOWCHECKS OFF}{$ENDIF}
function SourceFingerprint(const AText: string): Cardinal;
var
  LIdx: Integer;
begin
  Result := 2166136261;
  for LIdx := 1 to Length(AText) do
  begin
    Result := Result xor Cardinal(Ord(AText[LIdx]));
    Result := Result * 16777619;
  end;
end;
{$IFDEF PT_RESTORE_Q}{$OVERFLOWCHECKS ON}{$UNDEF PT_RESTORE_Q}{$ENDIF}

procedure TPasSemaModel.DemoteText;
var
  LIdx: Integer;
begin
  if Demoted then
    Exit;
  // Snapshot the per-row facts completion keeps reading (RoutineHead), then
  // the stream identity, THEN free - order matters, RoutineHead reads text.
  SetLength(DemotedHeads, SymCount);
  for LIdx := 0 to SymCount - 1 do
    DemotedHeads[LIdx] := Byte(RoutineHead(LIdx));
  DemotedVisCount := Length(Tree.Source.Visible);
  SetLength(DemotedFileSizes, Length(Tree.Source.Files));
  SetLength(DemotedTokenCounts, Length(Tree.Source.Files));
  SetLength(DemotedFileHashes, Length(Tree.Source.Files));
  for LIdx := 0 to High(Tree.Source.Files) do
  begin
    DemotedFileSizes[LIdx] := Length(Tree.Source.Files[LIdx].Source);
    DemotedTokenCounts[LIdx] := Length(Tree.Source.Files[LIdx].Tokens);
    DemotedFileHashes[LIdx] :=
      SourceFingerprint(Tree.Source.Files[LIdx].Source);
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

function TPasSemaModel.DemotedStreamMatches(
  const APre: TPasPreprocessed): Boolean;
var
  LIdx: Integer;
begin
  Result := False;
  if not Demoted then
    Exit;
  if Length(APre.Visible) <> DemotedVisCount then
    Exit;
  if Length(APre.Files) <> Length(DemotedTokenCounts) then
    Exit;
  if Length(APre.Files) <> Length(DemotedFileHashes) then
    Exit;
  for LIdx := 0 to High(APre.Files) do
    if (Length(APre.Files[LIdx].Source) <> DemotedFileSizes[LIdx]) or
       (Length(APre.Files[LIdx].Tokens) <> DemotedTokenCounts[LIdx]) or
       (SourceFingerprint(APre.Files[LIdx].Source) <>
        DemotedFileHashes[LIdx]) then
      Exit;
  Result := True;
end;

function TPasSemaModel.DemotedFileMatches(AFileIdx: Integer;
  const AText: string): Boolean;
begin
  Result := Demoted and (AFileIdx >= 0) and
    (AFileIdx <= High(DemotedFileSizes)) and
    (Length(AText) = DemotedFileSizes[AFileIdx]) and
    (SourceFingerprint(AText) = DemotedFileHashes[AFileIdx]);
end;

function TPasSemaModel.TryRehydrate(const APre: TPasPreprocessed): Boolean;
begin
  if not Demoted then
    Exit(True);
  Result := DemotedStreamMatches(APre);
  if not Result then
    Exit;
  Tree.Source := APre;
  Demoted := False;
  DemotedFileSizes := nil;
  DemotedTokenCounts := nil;
  DemotedFileHashes := nil;
  DemotedHeads := nil;
  DemotedVisCount := 0;
  Result := True;
end;

function TPasSemaModel.InUnopenedWithBody(ANode: Integer): Boolean;
var
  LCur, LParent, LLast, LIdx: Integer;
begin
  Result := False;
  // Bounds-checked, not just nil-checked - same cross-generation-id class the
  // other node walks guard against.
  if (Length(WithUnopened) = 0) or (ANode = NIL_NODE) or
     (ANode > High(Tree.Nodes)) then
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

procedure TPasSemaModel.AddParseDiags(const ADiags: TArray<TPasParseDiag>);
var
  LIdx, LTok, LLine, LCol, LFile: Integer;
  LCode, LMsg: string;
  LVis: TPasVisibleToken;
begin
  for LIdx := 0 to High(ADiags) do
  begin
    LTok := ADiags[LIdx].VisIndex;
    if (LTok < 0) or (LTok > High(Tree.Source.Visible)) then
      Continue;
    LVis := Tree.Source.Visible[LTok];
    Tree.Source.Files[LVis.FileId].OffsetToLineCol(
      Tree.Source.Files[LVis.FileId].Tokens[LVis.TokenIndex].Start, LLine, LCol);
    AddDiag(MakeDiag('E2029', 'E2029 ' + ADiags[LIdx].Msg, NIL_NODE,
      LVis.FileId, LLine, LCol));
  end;
  // The LEXER's diagnostics too, from every file of the model (includes have
  // their own token stream and their own FileId). Until now only the demo's
  // highlighter read them, so a bare `%` before garbage surfaced as nothing
  // but the parser's `")" expected` one token later. Same entry point as the
  // parser's rows so every parse path - first, incremental, rehydrated -
  // carries them alike.
  for LFile := 0 to High(Tree.Source.Files) do
    for LIdx := 0 to High(Tree.Source.Files[LFile].Diagnostics) do
    begin
      // Not from a skipped `$IFDEF` branch: dcc never lexes that text, so
      // `Windows only!` under `{$IFDEF Linux}` is not an E2038 (a real
      // client unit). The lexer runs before the preprocessor and cannot
      // know; the skip map is the place that does.
      if Tree.Source.IsSkipped(LFile,
           Tree.Source.Files[LFile].Diagnostics[LIdx].Start) then
        Continue;
      Tree.Source.Files[LFile].OffsetToLineCol(
        Tree.Source.Files[LFile].Diagnostics[LIdx].Start, LLine, LCol);
      LexDiagText(Tree.Source.Files[LFile].Diagnostics[LIdx],
        Tree.Source.Files[LFile], LLine, LCode, LMsg);
      AddDiag(MakeDiag(LCode, LMsg, NIL_NODE, LFile, LLine, LCol));
    end;
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
