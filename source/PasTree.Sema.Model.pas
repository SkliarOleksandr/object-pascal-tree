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
    skProperty, skEnumValue, skGenericParam, skLabel, skUnitRef, skBuiltinType);

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

  TSemaScope = class
    Kind: TSemaScopeKind;
    Parent: Integer;                       // scope index; NIL_SCOPE at root
    OwnerNode: Integer;                    // CST node that opened this scope
    Names: TDictionary<string, Integer>;   // NameLower -> symbol index (head)
    Symbols: TList<Integer>;               // declaration order
    Additional: TArray<Integer>;           // joined scopes (system/with/ancestor)
    // For a METHOD implementation's routine scope: the (innermost) struct
    // type symbol the qualified name resolved to (TFoo in TFoo.Bar). NIL_SYM
    // elsewhere. The project driver's inherited-member pass starts its
    // cross-unit ancestor walk here.
    StructSym: Integer;
    constructor Create(AKind: TSemaScopeKind; AParent, AOwnerNode: Integer);
    destructor Destroy; override;
  end;

  TPasSemaModel = class
  private
    FSymCount: Integer;
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
    constructor Create(const ATree: TPasTree);
    destructor Destroy; override;

    function SymCount: Integer;
    function AddScope(AKind: TSemaScopeKind; AParent, AOwnerNode: Integer):
      Integer;
    procedure JoinScope(AScope, AAdditional: Integer);
    // Adds a symbol to the arena (does not register a name).
    function AddSymbol(AScope: Integer; AKind: TSemaSymbolKind;
      const AName: string; ADeclNode: Integer): Integer;
    // Registers NameLower -> symbol in a scope's dictionary + order list.
    procedure BindName(AScope, ASym: Integer);
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
    // Full lookup: self -> additional (reverse) -> parent -> ...
    function Resolve(AScope: Integer; const ANameLower: string): Integer;
    { Resolve honouring block-scope POSITION — see the implementation. Only a
      reference lookup passes a real AAtToken; everything else passes -1. }
    function ResolveAt(AScope: Integer; const ANameLower: string;
      AAtToken: Integer): Integer;
    { ResolveAt that never answers with a GENERIC type — for a BARE reference,
      where arity is part of the identity. See the implementation. }
    function ResolveNonGenericAt(AScope: Integer; const ANameLower: string;
      AAtToken: Integer): Integer;
    function FindNonGenericDeep(AScope: Integer;
      const ANameLower: string): Integer;
    function DeclaredAfter(ASym, AAtToken: Integer): Boolean;
    { True when ANode sits in the BODY of a `with` listed in WithUnopened —
      see that field. An identifier inside a with's own TARGET expression is
      NOT in its scope (the target is evaluated in the enclosing one), hence
      the last-child test. WithUnopened is empty for the overwhelming
      majority of units, so this costs one length check on the hot path. }
    function InUnopenedWithBody(ANode: Integer): Boolean;
    procedure AddDiag(const ADiag: TSemaDiag);
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
  Names := TDictionary<string, Integer>.Create;
  Symbols := TList<Integer>.Create;
end;

destructor TSemaScope.Destroy;
begin
  Names.Free;
  Symbols.Free;
  inherited;
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

{ Any name -> its lookup key: lower-cased, leading '&' stripped.

  `&Foo` and `Foo` name the SAME thing (see TPasTree.NodeNameLower for the
  dcc-verified detail). Callers pass a symbol's DISPLAY name here, ampersand and
  all, because that is what the source said — the key must not keep it. Applied
  at both ends on purpose: AddSymbol/DeclareSym for what gets declared, and
  FindLocal for what gets looked up, so no future call site can reintroduce the
  mismatch by building a key its own way. }
function PasNameKey(const AName: string): string;
begin
  Result := AName;
  if (Result <> '') and (Result[1] = '&') then
    Delete(Result, 1, 1);
  Result := LowerCase(Result);
end;

function TPasSemaModel.AddSymbol(AScope: Integer; AKind: TSemaSymbolKind;
  const AName: string; ADeclNode: Integer): Integer;
begin
  GrowSyms;
  Result := FSymCount;
  Inc(FSymCount);
  Symbols[Result].Kind := AKind;
  Symbols[Result].Name := AName;
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
  Scopes[AScope].Names.AddOrSetValue(Symbols[ASym].NameLower, ASym);
  Scopes[AScope].Symbols.Add(ASym);
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
  if not Scopes[AScope].Names.TryGetValue(ANameLower, Result) then
    Result := NIL_SYM;
end;

function TPasSemaModel.FindLocalDeep(AScope: Integer;
  const ANameLower: string): Integer;
var
  LAdd: TArray<Integer>;
  LIdx: Integer;
begin
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

function TPasSemaModel.Resolve(AScope: Integer;
  const ANameLower: string): Integer;
begin
  Result := ResolveAt(AScope, ANameLower, -1);
end;

// FindLocalDeep, skipping GENERIC types — the same-name chain first, then the
// joined scopes. See ResolveNonGenericAt.
function TPasSemaModel.FindNonGenericDeep(AScope: Integer;
  const ANameLower: string): Integer;
var
  LAdd: TArray<Integer>;
  LIdx, LSym, LDepth: Integer;
begin
  LSym := FindLocal(AScope, ANameLower);
  // Same name, same scope: types chain through NextOverload like routines do,
  // so a non-generic declared beside the generic is found here. Depth-capped
  // for a malformed chain, like every other walk in this model.
  LDepth := 0;
  while (LSym <> NIL_SYM) and (LDepth < 32) do
  begin
    if not ((Symbols[LSym].Kind = skType) and
            (sfGeneric in Symbols[LSym].Flags)) then
      Exit(LSym);
    LSym := Symbols[LSym].NextOverload;
    Inc(LDepth);
  end;
  LAdd := Scopes[AScope].Additional;
  for LIdx := High(LAdd) downto 0 do
  begin
    Result := FindNonGenericDeep(LAdd[LIdx], ANameLower);
    if Result <> NIL_SYM then
      Exit;
  end;
  Result := NIL_SYM;
end;

{ ResolveAt, but never answering with a GENERIC type.

  ARITY is part of a type's identity: `Pointer<T> = record ... end` does not
  shadow the builtin `Pointer`, and a bare `Pointer` means the builtin however
  much nearer the generic is. spring4d's `Spring.pas` declares exactly that pair
  and every `Pointer(X) := nil` in it was a type error for us until this existed.

  Called ONLY when the ordinary lookup already answered with a generic type and
  the reference is bare — both tested at the call site, because this walk is not
  free and every name in the closure would otherwise pay for it. NIL_SYM means
  "no non-generic anywhere", and the caller then keeps the generic binding
  rather than losing the reference: a bare name with only a generic in scope is
  dcc's error, not a reason to unbind. }
function TPasSemaModel.ResolveNonGenericAt(AScope: Integer;
  const ANameLower: string; AAtToken: Integer): Integer;
var
  LCur: Integer;
begin
  LCur := AScope;
  while LCur <> NIL_SCOPE do
  begin
    Result := FindNonGenericDeep(LCur, ANameLower);
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
  Diags := Diags + [ADiag];
end;

function TPasSemaModel.HasDiagAt(ANode: Integer): Boolean;
begin
  for var LIdx := 0 to High(Diags) do
    if Diags[LIdx].DeclNode = ANode then
      Exit(True);
  Result := False;
end;

end.
