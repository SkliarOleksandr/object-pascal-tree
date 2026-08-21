unit PasTree.Sema.Resolver;

{
  PasTree semantics — Phase 1 resolver (per unit).

  Passes over the immutable CST, in order:
    1. Collect         — open scopes (unit / struct / routine / block), add a
                          symbol for every declaration, chain routine
                          overloads, and flag same-scope duplicates (E2004).
    2. Resolve         — bind each identifier/member reference to a symbol via
                          the scope chain. Unresolved refs (e.g. names from a
                          not-yet-indexed used unit, or a `with`-target's
                          member, not yet in scope) are left NIL and flagged
                          sfExternalUnresolved — no diagnostic in Phase 1.
    3. BindTypes       — bind each declaration's declared type to a type
                          symbol.
    4. ResolveWithStmts — NOW that types are bound, open each `with` target's
                          member scope and retry whatever its body left
                          unresolved in pass 2 (see its own header comment for
                          why this can only run this late).

  Names vs. type are separated by the ':' token (leading idents joined by ','
  are names; the child after ':' is the type) — see TPasParser.ParseParamList /
  the var section in PasTree.Parser.pas.
}

interface

uses
  PasTree.Types,
  PasTree.Ast,
  PasTree.Platforms,
  PasTree.Sema.Model;

type
  // A structured typed-const/var initializer (3.2.2, `X: TPoint = (X: 0;
  // Y: 0)`) noted during Collect, resolved once BindTypes has run — see
  // ResolveAggregates for why this can't happen any earlier.
  TPasPendingAggr = record
    AggrNode: Integer;   // the nkAggregate node
    TypeNode: Integer;   // the declaration's OWN type-expression node
  end;

  // A `class/record helper for T` (15.3) noted during Collect: the helper's
  // nkHelperType node and its OWN type symbol. The extended type T cannot be
  // looked up while collecting (a helper may be declared before the type it
  // extends), so the two member scopes are wired together in a pass of its
  // own — see JoinHelperScopes.
  TPasPendingHelper = record
    Node: Integer;       // the nkHelperType node
    HelperSym: Integer;  // the helper's own skType symbol
  end;

  TPasSemaResolver = class
  private
    FModel: TPasSemaModel;
    FTree: TPasTree;
    FSys: Integer;
    FIntf: Integer;   // interface scope (importable)
    FImpl: Integer;   // implementation scope (parent = FIntf)
    FNodeScope: TArray<Integer>;
    FIsDeclName: TArray<Boolean>;
    FPendingAggr: TArray<TPasPendingAggr>;
    FPendingHelpers: TArray<TPasPendingHelper>;
    // FModel.UsesList's filled prefix during Run — appends double the array
    // instead of re-copying it per uses entry; Analyze trims before returning.
    FUsesCount: Integer;
    FSkipTyper: Boolean;   // see Analyze
    // Two consumers: the builtin seed, and one `set of` rule in the typer.
    FPlatform: TPasPlatform;
    // tree helpers
    function KindOf(ANode: Integer): TPasNodeKind; inline;
    function FirstChild(ANode: Integer): Integer; inline;
    function NextSib(ANode: Integer): Integer; inline;
    function NodeText(ANode: Integer): string; inline;
    function NodeNameLower(ANode: Integer): string; inline;
    function SkipAttr(AChild: Integer): Integer;
    function IsAttributeTypeRef(ANode: Integer): Boolean;
    function IsBareTypeUse(ANode: Integer): Boolean;
    function EnumJoinTarget(AScope: Integer): Integer;
    procedure NotePendingAggregate(ATypeNode: Integer);
    function SepKindAfter(ANode: Integer): TPasTokenKind;
    function QualifiedNameText(ANode: Integer): string;
    procedure CollectRoot(ARoot: Integer);
    function FindChildKind(ANode: Integer; AKind: TPasNodeKind): Integer;
    function CountImplParamNames(ARoutineNode: Integer): Integer;
    function RoutineParamNameCount(ASym: Integer): Integer;
    procedure NodePos(ANode: Integer; out AFileId, ALine, ACol: Integer);
    // collect
    procedure MarkDeclName(ANode, ASym: Integer);
    { AOverloadOnClash chains onto a same-named, same-kind symbol instead of
      reporting a redeclaration — for the one non-routine case that is legal,
      a generic type name declared at several ARITIES (16.1.2). }
    function DeclareSym(AScope: Integer; AKind: TSemaSymbolKind;
      const AName: string; ADeclNode: Integer;
      AOverloadOnClash: Boolean = False): Integer;
    function GenericArityOfParamsNode(ANode: Integer): Integer;
    function GenericArityOfDecl(ATypeDeclNode: Integer): Integer;
    function GenericArityOfSym(ASym: Integer): Integer;
    procedure DeclareNamesAndType(ADecl, AScope: Integer;
      AKind: TSemaSymbolKind);
    procedure CollectTypeDecl(ANode, AScope: Integer);
    function ResolveSkipping(AScope: Integer; const ANameLower: string;
      ASkipSym: Integer): Integer;
    function DeclareAnonStruct(AScope, ANode: Integer): Integer;
    procedure CollectStruct(ANode, AOuter, ATypeSym: Integer);
    function VisibilityOf(ANode: Integer): TSemaVisibility;
    procedure CollectEnum(ANode, AOuter, ATypeSym: Integer);
    procedure CollectVariantPart(ANode, AScope: Integer);
    procedure CollectUsesItem(AItem, AScope: Integer);
    procedure CollectRoutine(ANode, AScope: Integer);
    procedure Collect(ANode, AScope: Integer);
    // helpers (ch.15 §15.3) — see JoinHelperScopes for why this is its own
    // pass rather than something CollectStruct could do inline.
    function HelperForTypeRef(ANode: Integer): Integer;
    procedure JoinHelperScopes;
    // resolve
    function DesignatorHead(ANode: Integer): Integer;
    procedure ResolveNode(ANode: Integer);
    procedure BindTypes;
    // structured typed-const/var initializers (3.2.2) — see ResolveAggregates
    // for why this also runs as its own pass, after BindTypes.
    function StructMemberScope(ATypeSym: Integer): Integer;
    procedure ResolveAggregateAgainst(AAggrNode, AStructScope: Integer);
    procedure ResolveAggregates;
    // with (ch.05 §5.7) — see ResolveWithStmts for why this runs as its own
    // pass, after BindTypes, rather than inline in Collect/ResolveNode.
    function FindMemberUpChain(ATypeSym: Integer;
      const ANameLower: string): Integer;
    function AncestorTypeSym(ATypeSym: Integer): Integer;
    function IsArrayPropDesignator(ABaseNode: Integer): Boolean;
    function DefaultArrayPropTypeSym(ATypeSym: Integer): Integer;
    function WithTargetTypeSym(ANode: Integer): Integer;
    function PointeeTypeSym(ATypeSym: Integer): Integer;
    function ElementTypeOf(ABaseNode: Integer): Integer;
    procedure RepointScope(ANode, ANewScope: Integer);
    procedure UnbindShadowedByWith(ANode, AWithScope: Integer);
    procedure ResolveOneWithStmt(AWith: Integer);
    procedure ResolveWithStmts;
    procedure CheckForCounters;
    procedure CheckBareRaises;
    procedure CheckSlicePositions;
    procedure Run;
  public
    { ASkipTyper skips the final expression type-check (Phase 3a) — for
      TRANSIENT models only (the async parser's interface-only wave, whose
      models are replaced by fully-analyzed ones before anyone reads
      diagnostics or ExprType). Collect/Resolve/BindTypes still run, so
      scopes, symbols, RefMap and declared-type bindings — everything
      navigation and cross-unit resolution read — are complete. }
    class function Analyze(const ATree: TPasTree;
      ASkipTyper: Boolean = False;
      APlatform: TPasPlatform = pfWin32): TPasSemaModel; static;
  end;

implementation

uses
  System.SysUtils,
  PasTree.Preprocessor,
  PasTree.Sema.Builtins,
  PasTree.Sema.Diagnostics,
  PasTree.Sema.Types;

class function TPasSemaResolver.Analyze(const ATree: TPasTree;
  ASkipTyper: Boolean = False;
  APlatform: TPasPlatform = pfWin32): TPasSemaModel;
var
  LR: TPasSemaResolver;
begin
  LR := TPasSemaResolver.Create;
  try
    LR.FTree := ATree;
    LR.FSkipTyper := ASkipTyper;
    LR.FPlatform := APlatform;
    LR.FModel := TPasSemaModel.Create(ATree);
    SetLength(LR.FNodeScope, Length(ATree.Nodes));
    SetLength(LR.FIsDeclName, Length(ATree.Nodes));
    for var LIdx := 0 to High(LR.FNodeScope) do
      LR.FNodeScope[LIdx] := NIL_SCOPE;   // unvisited => no scope => resolves NIL
    LR.Run;
    LR.FModel.NodeScope := LR.FNodeScope;
    // Standalone (non-project) consumers enumerate Diags right after this
    // returns; the project driver re-trims after its own cross passes.
    LR.FModel.TrimDiags;
    // UsesList grew with capacity slack (see FUsesCount); every consumer
    // enumerates it with Length/High, so cut it exact before publishing.
    SetLength(LR.FModel.UsesList, LR.FUsesCount);
    Result := LR.FModel;
  finally
    LR.Free;
  end;
end;

{ tree helpers }

function TPasSemaResolver.KindOf(ANode: Integer): TPasNodeKind;
begin
  Result := FTree.Nodes[ANode].Kind;
end;

function TPasSemaResolver.FirstChild(ANode: Integer): Integer;
begin
  Result := FTree.Nodes[ANode].FirstChild;
end;

function TPasSemaResolver.NextSib(ANode: Integer): Integer;
begin
  Result := FTree.Nodes[ANode].NextSibling;
end;

function TPasSemaResolver.NodeText(ANode: Integer): string;
begin
  Result := FTree.NodeText(ANode);
end;

function TPasSemaResolver.NodeNameLower(ANode: Integer): string;
begin
  Result := FTree.NodeNameLower(ANode);
end;

function TPasSemaResolver.SkipAttr(AChild: Integer): Integer;
begin
  Result := AChild;
  if (Result <> NIL_NODE) and (KindOf(Result) = nkAttrGroup) then
    Result := NextSib(Result);
end;

// ATypeNode is a var/const/field declaration's OWN type-expression node
// (`TWndClass` in `UtilWindowClass: TWndClass = (style: 0; ...)`); if it is
// immediately followed by a structured aggregate initializer (3.2.2), note
// it for ResolveAggregates — which needs ATypeNode's designator RESOLVED
// (RefMap, filled by ResolveNode) to find the target type, so field-name
// resolution can't happen inline here, in Collect.
procedure TPasSemaResolver.NotePendingAggregate(ATypeNode: Integer);
var
  LInit: Integer;
begin
  if ATypeNode = NIL_NODE then
    Exit;
  LInit := NextSib(ATypeNode);
  if (LInit <> NIL_NODE) and (KindOf(LInit) = nkAggregate) then
  begin
    SetLength(FPendingAggr, Length(FPendingAggr) + 1);
    FPendingAggr[High(FPendingAggr)].AggrNode := LInit;
    FPendingAggr[High(FPendingAggr)].TypeNode := ATypeNode;
  end;
end;

// ANode is an attribute usage's TypeRef (`[Table]` in `[Table] TFoo = class`)
// if its parent is the nkAttribute node AND it sits in that node's TypeRef
// position (FirstChild) rather than among its `(...)` argument expressions.
// See PasTree.Sema.Project.IsAttributeTypeRef (same check, project-level
// tree) for why this matters: 19.3.1 lets the `Attribute` suffix be omitted
// at the use site.
function TPasSemaResolver.IsAttributeTypeRef(ANode: Integer): Boolean;
var
  LParent: Integer;
begin
  LParent := FTree.Nodes[ANode].Parent;
  Result := (LParent <> NIL_NODE) and (KindOf(LParent) = nkAttribute) and
    (FirstChild(LParent) = ANode);
end;

{ True when ANode is a name written WITHOUT type arguments — i.e. not the head of
  an `nkTypeArgs` (`TFoo<T>`). Only the head matters: an ident that is an
  ARGUMENT inside `<...>` is itself a bare reference (`TDict<Pointer, TList>`
  means the builtin Pointer), and the parser puts arguments after the head under
  the same node, so the first-child test tells the two apart. }
function TPasSemaResolver.IsBareTypeUse(ANode: Integer): Boolean;
var
  LParent: Integer;
begin
  LParent := FTree.Nodes[ANode].Parent;
  Result := (LParent = NIL_NODE) or (KindOf(LParent) <> nkTypeArgs) or
    (FirstChild(LParent) <> ANode);
end;

// KIND of the visible token immediately after ANode's last token. Every
// consumer asks about a single punctuation token (':' ',' '.' '<'), and the
// kind answers that without materializing the text — this runs per declared
// name and per parameter, hundreds of thousands of times on a big closure.
// tkUnknown when there is no next token. Note the kinds keep the old string
// compares exact: ':=' is ONE token (tkAssign, never tkColon) and '..' is
// tkDotDot (never tkDot).
function TPasSemaResolver.SepKindAfter(ANode: Integer): TPasTokenKind;
var
  LNext: Integer;
begin
  LNext := FTree.Nodes[ANode].LastToken + 1;
  if (LNext >= 0) and (LNext <= High(FTree.Source.Visible)) then
    Result := FTree.Source.VisibleToken(LNext).Kind
  else
    Result := tkUnknown;
end;

function TPasSemaResolver.FindChildKind(ANode: Integer;
  AKind: TPasNodeKind): Integer;
begin
  Result := FirstChild(ANode);
  while Result <> NIL_NODE do
  begin
    if KindOf(Result) = AKind then
      Exit;
    Result := NextSib(Result);
  end;
end;

// Total parameter NAME count of a routine's parameter list; -1 if the list is
// omitted (external / forward completion that doesn't repeat the params).
function TPasSemaResolver.CountImplParamNames(ARoutineNode: Integer): Integer;
var
  LParams, LParam, LChild: Integer;
begin
  LParams := FindChildKind(ARoutineNode, nkParams);
  if LParams = NIL_NODE then
    Exit(-1);
  Result := 0;
  LParam := FirstChild(LParams);
  while LParam <> NIL_NODE do
  begin
    if KindOf(LParam) = nkParam then
    begin
      LChild := SkipAttr(FirstChild(LParam));
      while (LChild <> NIL_NODE) and (KindOf(LChild) = nkIdent) do
      begin
        Inc(Result);
        if SepKindAfter(LChild) = tkColon then
          Break;                       // last name; the type follows
        LChild := NextSib(LChild);     // ',' -> next name
        if (LChild <> NIL_NODE) and (KindOf(LChild) <> nkIdent) then
          Break;
      end;
    end;
    LParam := NextSib(LParam);
  end;
end;

// Parameter count of an already-collected routine symbol (its param scope).
function TPasSemaResolver.RoutineParamNameCount(ASym: Integer): Integer;
var
  LScope, LS: Integer;
begin
  Result := 0;
  LScope := FModel.Symbols[ASym].MemberScope;
  if (LScope = NIL_SCOPE) or (FModel.Scopes[LScope].Symbols = nil) then
    Exit;
  for LS in FModel.Scopes[LScope].Symbols do
    if FModel.Symbols[LS].Kind = skParam then
      Inc(Result);
end;

procedure TPasSemaResolver.NodePos(ANode: Integer;
  out AFileId, ALine, ACol: Integer);
var
  LVis: TPasVisibleToken;
  LTok: Integer;
begin
  AFileId := 0; ALine := 0; ACol := 0;
  LTok := FTree.Nodes[ANode].FirstToken;
  if (LTok < 0) or (LTok > High(FTree.Source.Visible)) then
    Exit;
  LVis := FTree.Source.Visible[LTok];
  AFileId := LVis.FileId;
  FTree.Source.Files[LVis.FileId].OffsetToLineCol(
    FTree.Source.Files[LVis.FileId].Tokens[LVis.TokenIndex].Start, ALine, ACol);
end;

{ collect }

procedure TPasSemaResolver.MarkDeclName(ANode, ASym: Integer);
begin
  if ANode <> NIL_NODE then
  begin
    FIsDeclName[ANode] := True;
    FModel.RefMap[ANode] := ASym;
  end;
end;

function TPasSemaResolver.DeclareSym(AScope: Integer; AKind: TSemaSymbolKind;
  const AName: string; ADeclNode: Integer;
  AOverloadOnClash: Boolean): Integer;
var
  LExisting, LTail, LFileId, LLine, LCol: Integer;
  LKey: string;
begin
  // One PasNameKey for both the clash lookup and the symbol's stored key —
  // this runs per declared symbol.
  LKey := PasNameKey(AName);
  LExisting := FModel.FindLocal(AScope, LKey);
  Result := FModel.AddSymbol(AScope, AKind, AName, ADeclNode, LKey);
  if LExisting = NIL_SYM then
    FModel.BindName(AScope, Result)
  else if ((AKind = skRoutine) and
           (FModel.Symbols[LExisting].Kind = skRoutine)) or
          (AOverloadOnClash and (FModel.Symbols[LExisting].Kind = AKind)) then
  begin
    // overload: chain onto the head, keep the head registered under the name
    LTail := LExisting;
    while FModel.Symbols[LTail].NextOverload <> NIL_SYM do
      LTail := FModel.Symbols[LTail].NextOverload;
    FModel.Symbols[LTail].NextOverload := Result;
    FModel.Symbols[Result].Flags := FModel.Symbols[Result].Flags + [sfOverload];
    FModel.Scopes[AScope].Symbols.Add(Result);
  end
  else if (AKind = skProperty) and
          (FModel.Symbols[LExisting].Kind = skProperty) then
    // Overloaded array properties: `property Item[I: Integer]: T; default;`
    // + `property Item[I: string]: T; default;` is legal (13.1.4) — keep the
    // first registered under the name, no redeclaration.
    FModel.Scopes[AScope].Symbols.Add(Result)
  else if (FModel.Symbols[LExisting].Kind = skUnitRef) and
          (AKind <> skUnitRef) then
    // A declaration legally HIDES a used unit's (leaf) name — e.g.
    // Winapi.WinSock2 declares `QOS = _QualityOfService` while using
    // Winapi.Qos. The new symbol takes the bare name; the unit stays
    // reachable via its fully-qualified name (UsesList keeps NameFull).
    FModel.BindName(AScope, Result)
  else
  begin
    // genuine redeclaration in the same scope
    NodePos(ADeclNode, LFileId, LLine, LCol);
    FModel.AddDiag(MakeDiag('E2004',
      Format(SE2004_IdentifierRedeclared, [AName]), ADeclNode, LFileId, LLine,
      LCol));
    FModel.Scopes[AScope].Symbols.Add(Result);
  end;
  MarkDeclName(ADeclNode, Result);
end;

// names [, names] : Type   (used by var/field sections and parameters)
procedure TPasSemaResolver.DeclareNamesAndType(ADecl, AScope: Integer;
  AKind: TSemaSymbolKind);
var
  LChild, LType: Integer;
  LSep: TPasTokenKind;
  LSyms: TArray<Integer>;
  LDone: Boolean;
  LIdx: Integer;
begin
  LChild := SkipAttr(FirstChild(ADecl));
  LType := NIL_NODE;
  LSyms := nil;
  LDone := False;
  while (LChild <> NIL_NODE) and (KindOf(LChild) = nkIdent) and not LDone do
  begin
    LSep := SepKindAfter(LChild);
    LSyms := LSyms + [DeclareSym(AScope, AKind, NodeText(LChild), LChild)];
    if LSep = tkColon then
    begin
      LType := NextSib(LChild);
      LDone := True;
    end
    else if LSep = tkComma then
      LChild := NextSib(LChild)
    else
      LDone := True;  // untyped parameter, or end
  end;
  for LIdx := 0 to High(LSyms) do
    FModel.Symbols[LSyms[LIdx]].TypeNode := LType;
  // A parameter with a value after its type has a default (optional argument).
  if (AKind = skParam) and (LType <> NIL_NODE) and (NextSib(LType) <> NIL_NODE) then
    for LIdx := 0 to High(LSyms) do
      FModel.Symbols[LSyms[LIdx]].Flags :=
        FModel.Symbols[LSyms[LIdx]].Flags + [sfHasDefault];
  NotePendingAggregate(LType);
  // Collect the type expression and anything after it (init / default /
  // absolute) as nested content in this scope, so every node gets a scope.
  LChild := LType;
  while LChild <> NIL_NODE do
  begin
    Collect(LChild, AScope);
    LChild := NextSib(LChild);
  end;
end;

{ Type-parameter count of an nkGenericParams / nkTypeArgs node. For
  nkGenericParams it counts the declared NAMES, so `<T; U: class>` is 2 and
  `<T, U>` is also 2; for nkTypeArgs, the arguments written. }
function TPasSemaResolver.GenericArityOfParamsNode(ANode: Integer): Integer;
var
  LParam, LP: Integer;
begin
  Result := 0;
  if ANode = NIL_NODE then
    Exit;
  if KindOf(ANode) = nkTypeArgs then
  begin
    // Head then one child per argument.
    LP := FirstChild(ANode);
    if LP <> NIL_NODE then
      LP := NextSib(LP);
    while LP <> NIL_NODE do
    begin
      Inc(Result);
      LP := NextSib(LP);
    end;
    Exit;
  end;
  if KindOf(ANode) <> nkGenericParams then
    Exit;
  LParam := FirstChild(ANode);
  while LParam <> NIL_NODE do
  begin
    if KindOf(LParam) = nkGenericParam then
    begin
      LP := FirstChild(LParam);
      while (LP <> NIL_NODE) and (KindOf(LP) = nkIdent) do
      begin
        Inc(Result);
        LP := NextSib(LP);
      end;
    end;
    LParam := NextSib(LParam);
  end;
end;

// Number of type parameters an nkTypeDecl declares; 0 for a plain type.
function TPasSemaResolver.GenericArityOfDecl(ATypeDeclNode: Integer): Integer;
var
  LGen, LParam, LP: Integer;
begin
  Result := 0;
  if ATypeDeclNode = NIL_NODE then
    Exit;
  LGen := FindChildKind(ATypeDeclNode, nkGenericParams);
  if LGen = NIL_NODE then
    Exit;
  LParam := FirstChild(LGen);
  while LParam <> NIL_NODE do
  begin
    if KindOf(LParam) = nkGenericParam then
    begin
      LP := FirstChild(LParam);
      while (LP <> NIL_NODE) and (KindOf(LP) = nkIdent) do
      begin
        Inc(Result);
        LP := NextSib(LP);
      end;
    end;
    LParam := NextSib(LParam);
  end;
end;

// Same, for an already-declared type symbol (via its declaration's nkTypeDecl).
function TPasSemaResolver.GenericArityOfSym(ASym: Integer): Integer;
var
  LDecl, LParent: Integer;
begin
  Result := 0;
  if ASym = NIL_SYM then
    Exit;
  LDecl := FModel.Symbols[ASym].DeclNode;
  if LDecl = NIL_NODE then
    Exit;
  LParent := FTree.Nodes[LDecl].Parent;
  if (LParent <> NIL_NODE) and (KindOf(LParent) = nkTypeDecl) then
    Result := GenericArityOfDecl(LParent);
end;

procedure TPasSemaResolver.CollectTypeDecl(ANode, AScope: Integer);
var
  LName, LChild, LSym, LExisting, LGen, LBody: Integer;
  LMatch, LProbe, LDepth: Integer;
begin
  LChild := FirstChild(ANode);
  if (LChild <> NIL_NODE) and (KindOf(LChild) = nkAttrGroup) then
    // 19.3.1: an attribute name may omit the `Attribute` suffix its class
    // carries (IsAttributeTypeRef's fallback in ResolveNode), but that
    // fallback needs FNodeScope set on the ident inside -- SkipAttr just
    // jumps past the group without visiting it, so without this the group
    // was never Collect()ed at all and every attribute on a TYPE stayed
    // NIL_SCOPE, unresolvable no matter how the class was named. Mirrors
    // CollectRoutine's own `nkAttrGroup: Collect(LChild, LRoutine)` case.
    Collect(LChild, AScope);
  LName := SkipAttr(FirstChild(ANode));
  if (LName = NIL_NODE) or (KindOf(LName) <> nkIdent) then
    Exit;
  // Forward-declared types (`TFoo = class;`) complete later under the same
  // name — reuse the existing symbol rather than flagging a redeclaration.
  //
  // The match must be searched along the WHOLE NextOverload chain, not just at
  // its head: one name can carry several declarations at different arities
  // (16.1.2), and FindLocal returns whichever came first. One library unit
  // declares a non-generic `TJclArrayIterator`, then `TJclArrayIterator<T> =
  // class;`, then the real `TJclArrayIterator<T>`. Testing only the head found
  // the arity-0 class, read the arity mismatch as "a different type", and
  // declared a THIRD symbol — so the forward stayed the arity-1 winner with an
  // empty member scope, and every method body of the real class lost its own
  // fields and its inherited members. ~60 false E2003 in that one unit, and it
  // did not reproduce until the fixture also had the non-generic sibling.
  LExisting := FModel.FindLocal(AScope, NodeNameLower(LName));
  LMatch := NIL_SYM;
  LProbe := LExisting;
  for LDepth := 1 to 64 do
  begin
    if LProbe = NIL_SYM then
      Break;
    if (FModel.Symbols[LProbe].Kind = skType) and
       (GenericArityOfDecl(ANode) = GenericArityOfSym(LProbe)) then
    begin
      LMatch := LProbe;
      Break;
    end;
    LProbe := FModel.Symbols[LProbe].NextOverload;
  end;
  if LMatch <> NIL_SYM then
  begin
    LSym := LMatch;
    MarkDeclName(LName, LSym);
    // The completing declaration supersedes the forward one (`TFoo = class;`):
    // DeclNode must reach the real definition so ancestor/generic-param walks
    // (TypeDefNode and the project's cross typer) see heritage and params.
    FModel.Symbols[LSym].DeclNode := LName;
  end
  else if (LExisting <> NIL_SYM) and
          (FModel.Symbols[LExisting].Kind = skType) then
    // Same name, DIFFERENT generic arity — `TBox<T>` and `TBox<TKey, TVal>`
    // are two distinct types (16.1.2), not a redeclaration and not a forward
    // completion. Chained like routine overloads so ResolveTypeExpr can pick
    // by argument count; without this the second declaration reused the
    // first's symbol and silently overwrote its member scope, orphaning the
    // first type's members.
    LSym := DeclareSym(AScope, skType, NodeText(LName), LName,
      {AOverloadOnClash} True)
  else
    LSym := DeclareSym(AScope, skType, NodeText(LName), LName);

  // Generic type params live in a per-type scope so identical names (T, TKey…)
  // across different generic types don't collide in the unit scope.
  LBody := AScope;
  LGen := FindChildKind(ANode, nkGenericParams);
  if LGen <> NIL_NODE then
  begin
    // Recorded on the SYMBOL: the project's type-reference resolution needs
    // "is this generic?" for every reference it binds, and deriving it there
    // is measurably expensive (see sfGeneric).
    FModel.Symbols[LSym].Flags := FModel.Symbols[LSym].Flags + [sfGeneric];
    LBody := FModel.AddScope(sckGenericParams, AScope, ANode);
    Collect(LGen, LBody);
  end;

  LChild := NextSib(LName);
  while LChild <> NIL_NODE do
  begin
    if LChild <> LGen then
      case KindOf(LChild) of
        nkRecordType, nkClassType, nkInterfaceType, nkObjectType, nkHelperType:
          CollectStruct(LChild, LBody, LSym);
        nkEnumType:
          CollectEnum(LChild, LBody, LSym);
      else
        begin
          // `X = X` is the RE-EXPORT idiom, and its right side means the OUTER
          // X — the name being declared cannot alias itself. FMX writes it
          // twice inside classes: `TOverlayMode = TOverlayMode deprecated ...`
          // (FMX.MultiView.Types) and `TItemAppearanceObjectsClass =
          // TItemAppearanceObjectsClass` (FMX.ListView.Appearances), and
          // dcc32 37.0-probed, `THost.TMode.AllLocal` through such an alias
          // compiles.
          //
          // Bound HERE because the declared symbol is already in scope by now,
          // so the ordinary reference pass would resolve the name to the alias
          // itself: a type that is its own definition, whose members are
          // therefore nothing. ResolveNode leaves an already-bound node alone,
          // which is what makes writing it here enough.
          if KindOf(LChild) = nkIdent then
          begin
            var LChildLower := NodeNameLower(LChild);
            if LChildLower = NodeNameLower(LName) then
              FModel.RefMap[LChild] := ResolveSkipping(LBody,
                LChildLower, LSym);
          end;
          Collect(LChild, LBody);  // alias target, array, pointer…
        end;
      end;
    LChild := NextSib(LChild);
  end;
end;

{ Resolve ANameLower from AScope outward, ignoring ASkipSym and everything
  declared beside it in the SAME scope. Only the self-alias above needs this:
  the skipped symbol is the one being declared, and a same-scope sibling of that
  name would be a redeclaration rather than a candidate. }
function TPasSemaResolver.ResolveSkipping(AScope: Integer;
  const ANameLower: string; ASkipSym: Integer): Integer;
var
  LScope, LFound: Integer;
begin
  LScope := AScope;
  while LScope <> NIL_SCOPE do
  begin
    LFound := FModel.FindLocalDeep(LScope, ANameLower);
    if (LFound <> NIL_SYM) and (LFound <> ASkipSym) then
      Exit(LFound);
    LScope := FModel.Scopes[LScope].Parent;
  end;
  Result := NIL_SYM;
end;

{ A type symbol for an ANONYMOUS structured type, so it can be named as a
  (unit, symbol) pair like every other type. Added to the scope but NOT bound to
  a name: nothing may find it by lookup, and it cannot collide or shadow. The
  declaration node is the struct node itself, which is what TypeDefNodeOf and
  the ancestor/member walks need. }
function TPasSemaResolver.DeclareAnonStruct(AScope, ANode: Integer): Integer;
begin
  Result := FModel.AddSymbol(AScope, skType, '', ANode);
end;

procedure TPasSemaResolver.CollectStruct(ANode, AOuter, ATypeSym: Integer);
var
  LMembers, LChild, LFirstNew: Integer;
  LVis: TSemaVisibility;
begin
  LMembers := FModel.AddScope(sckStruct, AOuter, ANode);
  FNodeScope[ANode] := LMembers;
  if ATypeSym <> NIL_SYM then
  begin
    FModel.Symbols[ATypeSym].MemberScope := LMembers;
    // Tag the member scope with its OWN type, not just method-implementation
    // routine scopes (CollectRoutine). The project driver partitions its two
    // cross-unit passes on exactly this tag — CrossResolve defers a node when
    // StructSymOfNode finds one, CrossResolveInherited then walks the
    // ancestors for it — so anything inside a type DECLARATION was invisible
    // to the ancestor walk and got a straight E2003 instead. That is what a
    // property specifier naming an INHERITED accessor hits: `property Flag:
    // Boolean read GetWordBoolProp` where GetWordBoolProp is declared in an
    // ancestor in ANOTHER unit (System.Win.InternetExplorer over
    // System.Win.OleControls' TOleControl — 47 of the RTL's remaining false
    // E2003s). Setting it here flips both passes coherently, since they read
    // the same predicate.
    FModel.Scopes[LMembers].StructSym := ATypeSym;
    if KindOf(ANode) = nkHelperType then
    begin
      SetLength(FPendingHelpers, Length(FPendingHelpers) + 1);
      FPendingHelpers[High(FPendingHelpers)].Node := ANode;
      FPendingHelpers[High(FPendingHelpers)].HelperSym := ATypeSym;
    end;
  end;

  LChild := FirstChild(ANode);
  // Members before any section marker keep svDefault rather than a guess: the
  // real default is `published` under {$M+} (a TPersistent descendant) and
  // `public` otherwise (11.2.1), which is directive- AND ancestry-dependent.
  // Recording "not stated" is the honest answer and leaves the decision to
  // whoever implements enforcement.
  LVis := svDefault;
  while LChild <> NIL_NODE do
  begin
    // Every symbol the child adds to the member scope gets the section's
    // visibility. Counted rather than returned, because a single child can
    // declare several (a `A, B: Integer` field group, a property's accessors,
    // a nested type and its enum values). Symbols is lazy — nil counts as 0.
    if FModel.Scopes[LMembers].Symbols <> nil then
      LFirstNew := FModel.Scopes[LMembers].Symbols.Count
    else
      LFirstNew := 0;
    case KindOf(LChild) of
      // ancestor / implemented-interface references: resolve in the outer scope
      nkIdent, nkMember, nkTypeArgs:
        Collect(LChild, AOuter);
      nkGuid:
        ; // no names
      nkVisibility:
        LVis := VisibilityOf(LChild);
      nkVarDecl:
        DeclareNamesAndType(LChild, LMembers, skField);
      nkRoutine:
        CollectRoutine(LChild, LMembers);
      nkPropertyDecl:
        begin
          var LN := SkipAttr(FirstChild(LChild));
          var LPropSym := NIL_SYM;
          if (LN <> NIL_NODE) and (KindOf(LN) = nkIdent) then
            LPropSym := DeclareSym(LMembers, skProperty, NodeText(LN), LN);
          // Array-property index parameters (`property Items[Index: Integer]:
          // T read GetItem;`) arrive as an nkParams child, SAME shape as a
          // routine's — but the generic Collect() below has no case for
          // nkParams/nkParam at all (only CollectRoutine/nkProcType/
          // nkAnonMethod special-case them), so falling through to plain
          // Collect(LC, LMembers) walks down to the index name's bare nkIdent
          // and does NOTHING with it: no DeclareSym, no FIsDeclName mark.
          // Resolve then treats it as an ordinary reference, finds no such
          // member anywhere in the class, and raises a false E2003 (real bug:
          // System.Actions.pas's `property ShortCuts[Index: Integer]`). Real
          // dcc never lets anything reference this name outside the
          // property's own signature slot (the read/write specifier matches
          // the getter/setter by position/type, not by this placeholder's
          // name), so — exactly like nkProcType's own isolated LSig scope —
          // give it a scope of its own: declared, but reachable from nowhere
          // else, which is all "not undeclared" requires.
          var LPropSig := NIL_SCOPE;
          var LC := NextSib(LN);
          while LC <> NIL_NODE do
          begin
            // The property's type is the child after the name / index params
            // and before the specifiers (see TPasParser.ParseProperty).
            if (LPropSym <> NIL_SYM) and
               (FModel.Symbols[LPropSym].TypeNode = NIL_NODE) and
               not (KindOf(LC) in [nkParams, nkPropSpec]) then
              FModel.Symbols[LPropSym].TypeNode := LC;
            if KindOf(LC) = nkParams then
            begin
              if LPropSig = NIL_SCOPE then
                LPropSig := FModel.AddScope(sckRoutine, LMembers, LChild);
              FNodeScope[LC] := LPropSig;
              var LParam := FirstChild(LC);
              while LParam <> NIL_NODE do
              begin
                if KindOf(LParam) = nkParam then
                  DeclareNamesAndType(LParam, LPropSig, skParam);
                LParam := NextSib(LParam);
              end;
            end
            else
              Collect(LC, LMembers);
            LC := NextSib(LC);
          end;
        end;
    else
      Collect(LChild, LMembers);   // var/const/type sections, variant parts...
    end;
    if (LVis <> svDefault) and (FModel.Scopes[LMembers].Symbols <> nil) then
      for var LNew := LFirstNew to FModel.Scopes[LMembers].Symbols.Count - 1 do
        FModel.Symbols[FModel.Scopes[LMembers].Symbols[LNew]].Visibility := LVis;
    LChild := NextSib(LChild);
  end;
end;

{ The visibility an nkVisibility node states. The parser puts the level in Aux
  (1..5, the order the words are listed in 11.2.1) and marks `strict` with the
  spare nfNegated flag. }
function TPasSemaResolver.VisibilityOf(ANode: Integer): TSemaVisibility;
var
  LStrict: Boolean;
begin
  LStrict := nfNegated in FTree.Nodes[ANode].Flags;
  case FTree.Nodes[ANode].Aux of
    1: if LStrict then Result := svStrictPrivate else Result := svPrivate;
    2: if LStrict then Result := svStrictProtected else Result := svProtected;
    3: Result := svPublic;
    4: Result := svPublished;
    // `automated` (11.2.1) is the legacy OLE-Automation section: published
    // plus dispatch info. Kept distinct rather than folded into svPublished so
    // a later pass can tell them apart without re-reading the tree.
    5: Result := svAutomated;
  else
    Result := svDefault;
  end;
end;

// The nearest ancestor of AScope that is NOT itself a struct (class/record/
// interface/object/helper) member scope — climbing past however many
// classes/records the point in question is nested inside. A non-scoped
// enum's element names inject as if the enum sat AT THAT SCOPE directly:
// nesting an enum inside a class only namespaces the TYPE name (`TFoo.
// TInner`), never the VALUES — dcc-verified: TWO unrelated classes A/B in
// one unit, A's own `private type` nested enum's literal resolves bare
// inside B's method too, and the same literal resolves bare from a
// DIFFERENT unit that merely `uses` this one, as long as the nesting chain
// up to the enum sits entirely in the INTERFACE section (an enum nested
// inside an IMPLEMENTATION-section type stays unit-local, same as any other
// implementation declaration — real dcc E2003s a cross-unit bare reference
// to one). A routine-LOCAL nested type's enum, by contrast, stays properly
// routine-scoped (dcc-verified: real E2003 outside the declaring routine)
// — AScope is already non-struct there, so this is a no-op.
function TPasSemaResolver.EnumJoinTarget(AScope: Integer): Integer;
begin
  Result := AScope;
  while (Result <> NIL_SCOPE) and (FModel.Scopes[Result].Kind = sckStruct) do
    Result := FModel.Scopes[Result].Parent;
end;

procedure TPasSemaResolver.CollectEnum(ANode, AOuter, ATypeSym: Integer);
var
  LEnum, LChild, LName, LVal: Integer;
begin
  // Each enum gets its own scope, so values of different enums never share a
  // scope (no false redeclaration). The scope is also joined into the
  // enclosing one (see EnumJoinTarget) so unqualified values resolve
  // (non-scoped enums); qualified access (Enum.Value) works via the type
  // symbol's member scope.
  LEnum := FModel.AddScope(sckEnum, AOuter, ANode);
  FNodeScope[ANode] := LEnum;
  if ATypeSym <> NIL_SYM then
    FModel.Symbols[ATypeSym].MemberScope := LEnum;
  // {$SCOPEDENUMS ON} (2.2.4): values do NOT inject into the enclosing scope
  // — qualified access (TEnum.Value) via the member scope above is the ONLY
  // way in. The state is positional (read at this enum's own declaration
  // site, via the preprocessor's event journal), because one unit routinely
  // toggles it around a group of declarations. Real bug when this was
  // ignored: System.Threading ({$SCOPEDENUMS ON} for the whole unit) has
  // `TLoopStateFlags = (Exception, Broken, ...)` — the leaked `Exception`
  // VALUE shadowed the `Exception` TYPE for every declaration below it, so
  // `EAggregateException = class(Exception)`'s heritage resolved to an enum
  // value, the ancestor walk died at the first hop, and every inherited
  // member (`Message`) was a false E2003.
  //
  // ANONYMOUS enums are exempt, and necessarily so: `TNeededToDo = set of
  // (SetChecked, CallClick)` (FMX.StdCtrls, a {$SCOPEDENUMS ON} unit) has no
  // enum type NAME to qualify with, so scoping the values would make them
  // unreachable by any spelling. dcc-verified: both bare values compile there,
  // while a NAMED enum's do not. ATypeSym = NIL_SYM is exactly that case — an
  // enum reached through the generic Collect fallthrough rather than as a named
  // type declaration's own definition.
  if (ATypeSym = NIL_SYM) or
     not FTree.Source.ScopedEnumsAt(FTree.Nodes[ANode].FirstToken) then
    FModel.JoinScope(EnumJoinTarget(AOuter), LEnum);
  LChild := FirstChild(ANode);
  while LChild <> NIL_NODE do
  begin
    if KindOf(LChild) = nkEnumValue then
    begin
      LName := FirstChild(LChild);
      if (LName <> NIL_NODE) and (KindOf(LName) = nkIdent) then
        DeclareSym(LEnum, skEnumValue, NodeText(LName), LName);
      LVal := NextSib(LName);
      while LVal <> NIL_NODE do
      begin
        Collect(LVal, AOuter);   // explicit value expression
        LVal := NextSib(LVal);
      end;
    end;
    LChild := NextSib(LChild);
  end;
end;

// 9.1.3 `case [Tag:] OrdinalType of <labels>: (fields) ...` inside a record.
//
// The optional TAG NAME is a REAL field of the record — it occupies storage
// and is freely readable/assignable, not a cosmetic annotation on the type.
// dcc-verified both ways: `R.data := 2` compiles, and naming the tag grows
// SizeOf by the tag type's width (12 vs 8 for the same record with an
// anonymous `case Integer of`). Nothing here declared it, so the generic
// Collect fallthrough walked the name as an ordinary REFERENCE and it read as
// undeclared (real bug: System.Curl.pas's `case data: Integer of`).
//
// Presence of the tag is decided by the ':' AFTER the first child, not by its
// node kind: an anonymous tag (`case Integer of`) also leads with an nkIdent
// — the type name — so the kinds are identical in both shapes.
//
// Everything after the tag name (the tag type, then each nkVariantBranch)
// collects into the SAME scope: a branch's fields are the record's own
// members (all branches overlay one another in storage), and a branch may
// end with a NESTED variant part, which lands back here through Collect.
procedure TPasSemaResolver.CollectVariantPart(ANode, AScope: Integer);
var
  LChild, LSym: Integer;
  LKind: TSemaSymbolKind;
begin
  LChild := FirstChild(ANode);
  if (LChild <> NIL_NODE) and (KindOf(LChild) = nkIdent) and
     (SepKindAfter(LChild) = tkColon) then
  begin
    // Mirrors the nkVarDecl case's own scope test, so a variant part reached
    // outside a struct body still declares something sane rather than a field
    // in a non-struct scope.
    if FModel.Scopes[AScope].Kind = sckStruct then
      LKind := skField
    else
      LKind := skVar;
    LSym := DeclareSym(AScope, LKind, NodeText(LChild), LChild);
    FModel.Symbols[LSym].TypeNode := NextSib(LChild);   // the tag type
    LChild := NextSib(LChild);
  end;
  while LChild <> NIL_NODE do
  begin
    Collect(LChild, AScope);
    LChild := NextSib(LChild);
  end;
end;

procedure TPasSemaResolver.CollectUsesItem(AItem, AScope: Integer);
var
  LNameNode, LLeaf, LStr, LSym: Integer;
  LU: TPasUsesRef;
  LIn: string;
begin
  LNameNode := FirstChild(AItem);
  if LNameNode = NIL_NODE then
    Exit;
  // Leaf ident of the (possibly dotted) unit name.
  LLeaf := LNameNode;
  if KindOf(LNameNode) = nkMember then
  begin
    LLeaf := FirstChild(LNameNode);
    while (LLeaf <> NIL_NODE) and (NextSib(LLeaf) <> NIL_NODE) do
      LLeaf := NextSib(LLeaf);
  end;
  if (LLeaf = NIL_NODE) or (KindOf(LLeaf) <> nkIdent) then
    Exit;

  // Register the unit ref once (a unit may appear in both uses sections).
  LSym := FModel.FindLocal(AScope, NodeNameLower(LLeaf));
  if LSym = NIL_SYM then
  begin
    LSym := DeclareSym(AScope, skUnitRef, NodeText(LLeaf), LLeaf);
    FModel.Symbols[LSym].Flags :=
      FModel.Symbols[LSym].Flags + [sfExternalUnresolved];
  end
  else
    MarkDeclName(LLeaf, LSym);

  // Optional `in 'path'`.
  LIn := '';
  LStr := NextSib(LNameNode);
  if (LStr <> NIL_NODE) and (KindOf(LStr) = nkStrLit) then
  begin
    LIn := NodeText(LStr);
    if (Length(LIn) >= 2) and (LIn[1] = '''') then
      LIn := StringReplace(Copy(LIn, 2, Length(LIn) - 2), '''''', '''',
        [rfReplaceAll]);
  end;

  LU.NameFull := QualifiedNameText(LNameNode);
  LU.InPath := LIn;
  LU.NameNode := LNameNode;
  LU.Sym := LSym;
  LU.UnitId := NIL_SYM;
  if FUsesCount = Length(FModel.UsesList) then
    SetLength(FModel.UsesList, FUsesCount * 2 + 8);
  FModel.UsesList[FUsesCount] := LU;
  Inc(FUsesCount);
end;

procedure TPasSemaResolver.CollectRoutine(ANode, AScope: Integer);
var
  LRoutine, LChild, LNameNode, LSegIdent, LSegLast: Integer;
  LRoutineSym, LResultNode: Integer;
  LQualified: Boolean;
  LQualIdents, LQualArity: TArray<Integer>;
begin
  LRoutine := FModel.AddScope(sckRoutine, AScope, ANode);
  FNodeScope[ANode] := AScope;
  LQualIdents := nil;
  LQualArity := nil;
  LRoutineSym := NIL_SYM;
  LResultNode := NIL_NODE;

  // Parse the (possibly dotted, possibly generic) name: each segment is
  // `ident [<...>]`; a '.' after a segment means it is a qualifier (TFoo. /
  // TList<T>.), so the *last* segment's ident is the routine name. A ':' or '('
  // ends the name (result type / parameters follow). Qualified names are method
  // implementations of existing declarations — do not redeclare them.
  LChild := SkipAttr(FirstChild(ANode));
  LNameNode := NIL_NODE;
  LQualified := False;
  while (LChild <> NIL_NODE) and (KindOf(LChild) = nkIdent) do
  begin
    LSegIdent := LChild;
    LSegLast := LChild;
    LChild := NextSib(LChild);
    // A following nkGenericParams/nkTypeArgs belongs to THIS segment only when
    // the segment ident is immediately followed by '<' — `TThreadList<T>.` or
    // `Foo<T>(...)`. Without the separator check, `function LockList:
    // TList<T>;` had its RESULT TYPE eaten as segment generic-args: nkTypeArgs
    // follows the name ident either way, only the ':' between them tells the
    // two shapes apart. The result node then never registered, the routine
    // symbol's TypeNode stayed NIL, and every consumer of the result type —
    // most visibly `with FThreads.LockList do Count` (System.Threading) —
    // dead-ended. Every function returning a generic instantiation was
    // affected.
    while (LChild <> NIL_NODE) and
          (KindOf(LChild) in [nkGenericParams, nkTypeArgs]) and
          (SepKindAfter(LSegLast) = tkLess) do
    begin
      Collect(LChild, LRoutine);   // generic params -> routine scope; args refs
      LSegLast := LChild;
      LChild := NextSib(LChild);
    end;
    if SepKindAfter(LSegLast) = tkDot then
    begin
      LQualified := True;          // qualifier segment; ident is a type ref
      LQualIdents := LQualIdents + [LSegIdent];  // full chain, outer -> inner
      // The segment's own type-parameter count, so an arity-overloaded name
      // (16.1.2) picks the right declaration: `TBox<TKey, TVal>.GetKey` must
      // reach the two-parameter TBox, not the one-parameter one that happens
      // to be registered under the name. 0 when the segment is not generic.
      if LSegLast <> LSegIdent then
        LQualArity := LQualArity + [GenericArityOfParamsNode(LSegLast)]
      else
        LQualArity := LQualArity + [0];
    end
    else
    begin
      LNameNode := LSegIdent;      // routine name; remaining children follow
      Break;
    end;
  end;

  // For a method implementation (TFoo.Bar — or nested, TOuter.TInner.Bar),
  // make the routine body see the struct's members (implicit Self): resolve
  // the qualifier CHAIN (first segment at AScope, each next one INSIDE the
  // previous type's member scope) and join every resolved segment's member
  // scope — outer first, innermost last, so the innermost wins lookups. The
  // innermost type is remembered as the scope's StructSym: the project
  // driver's inherited-member pass starts its cross-unit ancestor walk there.
  if LQualified then
  begin
    var LTy := NIL_SYM;
    for var LSegIdx := 0 to High(LQualIdents) do
    begin
      var LSeg := LQualIdents[LSegIdx];
      var LCand: Integer;
      if LTy = NIL_SYM then
        LCand := FModel.Resolve(AScope, NodeNameLower(LSeg))
      else if FModel.Symbols[LTy].MemberScope <> NIL_SCOPE then
        LCand := FModel.FindLocal(FModel.Symbols[LTy].MemberScope,
          NodeNameLower(LSeg))
      else
        LCand := NIL_SYM;
      if (LCand = NIL_SYM) or (FModel.Symbols[LCand].Kind <> skType) then
      begin
        LTy := NIL_SYM;
        Break;
      end;
      // Only the FIRST of an arity-overloaded set is registered under the
      // name, so walk the chain for the one this segment actually declares.
      if GenericArityOfSym(LCand) <> LQualArity[LSegIdx] then
      begin
        var LAlt := FModel.Symbols[LCand].NextOverload;
        while LAlt <> NIL_SYM do
        begin
          if (FModel.Symbols[LAlt].Kind = skType) and
             (GenericArityOfSym(LAlt) = LQualArity[LSegIdx]) then
          begin
            LCand := LAlt;
            Break;
          end;
          LAlt := FModel.Symbols[LAlt].NextOverload;
        end;
      end;
      LTy := LCand;
      if FModel.Symbols[LTy].MemberScope <> NIL_SCOPE then
        FModel.JoinScope(LRoutine, FModel.Symbols[LTy].MemberScope);
    end;
    FModel.Scopes[LRoutine].StructSym := LTy;
    // A qualified implementation that OMITS its own parameter list
    // (`procedure TFoo.Bar;` completing a class-declared `procedure Bar(
    // Index: Integer);` — legal dcc: the impl header may drop the params
    // when they exactly match the declaration) has NO nkParams child, so
    // the "Remaining children" loop below declares nothing into LRoutine —
    // the body then treats every omitted parameter name as an ordinary
    // (undeclared) reference: false E2003 (real bug, found analyzing
    // Vcl.CheckLst.pas: TCustomCheckListBox.ToggleClickCheck declares
    // `(Index: Integer)` but implements bodilessly as `ToggleClickCheck;`,
    // using `Index` freely in its body). Mirrors the SAME idiom the
    // unqualified branch below already honors for global routines — find
    // the class's own declared method (by name; an overloaded name is left
    // alone, the same simplification the global-routine path already makes
    // for LIntfHead) and join ITS param scope in, exactly like the struct's
    // member scope is joined above.
    if (LTy <> NIL_SYM) and (LNameNode <> NIL_NODE) and
       (FModel.Symbols[LTy].MemberScope <> NIL_SCOPE) and
       (FindChildKind(ANode, nkParams) = NIL_NODE) then
    begin
      var LDeclSym := FModel.FindLocal(FModel.Symbols[LTy].MemberScope,
        NodeNameLower(LNameNode));
      if (LDeclSym <> NIL_SYM) and
         (FModel.Symbols[LDeclSym].Kind = skRoutine) and
         (FModel.Symbols[LDeclSym].MemberScope <> NIL_SCOPE) then
        FModel.JoinScope(LRoutine, FModel.Symbols[LDeclSym].MemberScope);
    end;
  end;
  if (LNameNode <> NIL_NODE) and not LQualified then
  begin
    // An unqualified implementation-section routine that matches an interface
    // declaration is that declaration's implementation — link to it (by
    // parameter count for overloads; a routine that omits its param list is a
    // forward/external completion of the sole interface decl) instead of adding
    // a phantom symbol. This is essential: e.g. `function X; external;` in the
    // implementation must NOT create a spurious 0-param X.
    var LLink := NIL_SYM;
    if AScope = FImpl then
    begin
      var LIntfHead := FModel.FindLocal(FIntf, NodeNameLower(LNameNode));
      if (LIntfHead <> NIL_SYM) and
         (FModel.Symbols[LIntfHead].Kind = skRoutine) then
      begin
        var LImplPC := CountImplParamNames(ANode);
        if LImplPC < 0 then
          LLink := LIntfHead                    // params omitted -> completion
        else
        begin
          var LCand := LIntfHead;               // match the overload by arity
          while LCand <> NIL_SYM do
          begin
            if (FModel.Symbols[LCand].Kind = skRoutine) and
               (RoutineParamNameCount(LCand) = LImplPC) then
            begin
              LLink := LCand;
              Break;
            end;
            LCand := FModel.Symbols[LCand].NextOverload;
          end;
        end;
      end;
    end;
    if LLink <> NIL_SYM then
    begin
      if FindChildKind(ANode, nkRoutineBody) <> NIL_NODE then
        FModel.Symbols[LLink].Flags := FModel.Symbols[LLink].Flags + [sfHasBody];
      MarkDeclName(LNameNode, LLink);
      // Same gap as the qualified branch above, for a global routine: params
      // omitted here means nothing else ever declares them for THIS body —
      // join the matched declaration's own param scope in.
      if (FindChildKind(ANode, nkParams) = NIL_NODE) and
         (FModel.Symbols[LLink].MemberScope <> NIL_SCOPE) then
        FModel.JoinScope(LRoutine, FModel.Symbols[LLink].MemberScope);
    end
    else
    begin
      LRoutineSym := DeclareSym(AScope, skRoutine, NodeText(LNameNode),
        LNameNode);
      // Parameter scope, so the typer can enumerate this routine's params
      // for overload selection / arity checks.
      FModel.Symbols[LRoutineSym].MemberScope := LRoutine;
    end;
  end;

  // Remaining children: parameters, result type, directives, body.
  while LChild <> NIL_NODE do
  begin
    case KindOf(LChild) of
      nkParams:
        begin
          var LParam := FirstChild(LChild);
          while LParam <> NIL_NODE do
          begin
            if KindOf(LParam) = nkParam then
              DeclareNamesAndType(LParam, LRoutine, skParam);
            LParam := NextSib(LParam);
          end;
        end;
      nkGenericParams, nkRoutineBody, nkDirective, nkAttrGroup:
        Collect(LChild, LRoutine);
    else
      begin
        // First non-directive/body/generics child after params is the result
        // type (function). Record it for result-type binding.
        if LResultNode = NIL_NODE then
          LResultNode := LChild;
        Collect(LChild, LRoutine);
      end;
    end;
    LChild := NextSib(LChild);
  end;

  if (LRoutineSym <> NIL_SYM) and (LResultNode <> NIL_NODE) then
    FModel.Symbols[LRoutineSym].TypeNode := LResultNode;

  // Functions get the implicit `Result` variable, declared LOCALLY so it
  // shadows any same-named member of the enclosing class (real dcc behavior —
  // e.g. TMatch in System.RegularExpressions has a METHOD named Result, yet
  // `Result := ...` inside its other methods still means the function result).
  if (LResultNode <> NIL_NODE) and
     (FModel.FindLocal(LRoutine, 'result') = NIL_SYM) then
  begin
    var LRes := FModel.AddSymbol(LRoutine, skVar, 'Result', NIL_NODE);
    FModel.Symbols[LRes].TypeNode := LResultNode;
    FModel.BindName(LRoutine, LRes);
  end;
end;

procedure TPasSemaResolver.Collect(ANode, AScope: Integer);
var
  LChild, LName: Integer;
begin
  if ANode = NIL_NODE then
    Exit;
  FNodeScope[ANode] := AScope;

  case KindOf(ANode) of
    nkUsesClause:
      // Aux = 1 is a package `requires` clause — references to PACKAGES,
      // not units; resolving those as units would only poison the graph.
      if FTree.Nodes[ANode].Aux <> 1 then
      begin
        LChild := FirstChild(ANode);
        while LChild <> NIL_NODE do
        begin
          if KindOf(LChild) = nkUsesItem then
            CollectUsesItem(LChild, AScope);
          LChild := NextSib(LChild);
        end;
      end;

    nkTypeDecl:
      CollectTypeDecl(ANode, AScope);

    nkVarDecl:
      if FModel.Scopes[AScope].Kind = sckStruct then
        DeclareNamesAndType(ANode, AScope, skField)
      else
        DeclareNamesAndType(ANode, AScope, skVar);

    // Reached both from CollectStruct's own fallthrough (a record's top-level
    // `case` part) and, recursively, from a branch that ends with a nested one.
    nkVariantPart:
      CollectVariantPart(ANode, AScope);

    nkConstDecl:
      begin
        LName := SkipAttr(FirstChild(ANode));
        if (LName <> NIL_NODE) and (KindOf(LName) = nkIdent) then
        begin
          var LSym := DeclareSym(AScope, skConst, NodeText(LName), LName);
          var LNext := NextSib(LName);
          // optional ': Type' before '='
          if (LNext <> NIL_NODE) and (SepKindAfter(LName) = tkColon) then
          begin
            FModel.Symbols[LSym].TypeNode := LNext;
            NotePendingAggregate(LNext);
          end;
          while LNext <> NIL_NODE do
          begin
            Collect(LNext, AScope);
            LNext := NextSib(LNext);
          end;
        end;
      end;

    nkInlineVar, nkInlineConst:
      begin
        // 3.1.3: an inline var may declare SEVERAL names — `var V, S: string;`
        // (10.3+, dcc-verified) — and the parser already emits one nkIdent per
        // name. Only the FIRST was ever declared, so every other name read as
        // an undeclared identifier and the shared type bound to none of them
        // (real bug: System.SysUtils' `var V, S: string`, System.TypInfo's
        // `var sType, sEnum: string`).
        //
        // Same names-then-':'-then-type walk DeclareNamesAndType does for a
        // var section, deliberately NOT reusing it: an inline var's tail may
        // be an INITIALIZER with no type at all (`var Name := Expr;`), and
        // that routine anchors its tail walk on the type node, so the
        // initializer would go uncollected.
        var LKind := skVar;
        if KindOf(ANode) = nkInlineConst then
          LKind := skConst;
        var LSyms: TArray<Integer> := nil;
        var LType := NIL_NODE;
        LName := FirstChild(ANode);
        while (LName <> NIL_NODE) and (KindOf(LName) = nkIdent) do
        begin
          var LSep := SepKindAfter(LName);
          LSyms := LSyms + [DeclareSym(AScope, LKind, NodeText(LName), LName)];
          if LSep = tkComma then
            LName := NextSib(LName)
          else
          begin
            // ':' -> the shared type follows; ':=' (one token, tkAssign,
            // never tkColon) or anything else -> no type, the tail is an
            // initializer.
            if LSep = tkColon then
              LType := NextSib(LName);
            Break;
          end;
        end;
        for var LIdx := 0 to High(LSyms) do
          FModel.Symbols[LSyms[LIdx]].TypeNode := LType;
        NotePendingAggregate(LType);
        // Everything after the last NAME — the type expression and/or the
        // initializer — is ordinary content of this scope.
        if LName <> NIL_NODE then
        begin
          var LRest := NextSib(LName);
          while LRest <> NIL_NODE do
          begin
            Collect(LRest, AScope);
            LRest := NextSib(LRest);
          end;
        end;
      end;

    nkLabelSec:
      begin
        // 5.6.4 `label Foo, Bar;` — declare each identifier label in the
        // enclosing (routine/program) scope. Without this nothing ever
        // produced a skLabel symbol, so the labeled statement's OWN `Foo:`
        // ident — which the parser does emit — resolved to nothing and Phase 2
        // reported a false E2003 (found on System.Generics.Defaults'
        // AnsiIdentHash, which jumps to a `notAscii` label).
        LChild := FirstChild(ANode);
        while LChild <> NIL_NODE do
        begin
          if KindOf(LChild) = nkIdent then
            DeclareSym(AScope, skLabel, NodeText(LChild), LChild);
          LChild := NextSib(LChild);
        end;
      end;

    nkRoutine:
      CollectRoutine(ANode, AScope);

    nkAnonMethod:
      begin
        // An anonymous method owns its params/locals — two sibling literals
        // reusing a local name (both declaring `var LSer: ...`) must not read
        // as a redeclaration in the enclosing routine. It also owns its
        // implicit `Result` (typed by the child between the params and the
        // body): `Result := True` inside a function(...): Boolean literal
        // must NOT bind to (and type-check against) the ENCLOSING function's
        // Result. Params arrive in the same nkParams shape as a routine's —
        // declare them the same way.
        var LAnon := FModel.AddScope(sckRoutine, AScope, ANode);
        FNodeScope[ANode] := LAnon;
        LChild := FirstChild(ANode);
        while LChild <> NIL_NODE do
        begin
          if KindOf(LChild) = nkParams then
          begin
            FNodeScope[LChild] := LAnon;
            var LParam := FirstChild(LChild);
            while LParam <> NIL_NODE do
            begin
              if KindOf(LParam) = nkParam then
                DeclareNamesAndType(LParam, LAnon, skParam);
              LParam := NextSib(LParam);
            end;
            LChild := NextSib(LChild);
            Continue;
          end;
          if not (KindOf(LChild) in [nkAnonParams, nkRoutineBody]) and
             (FModel.FindLocal(LAnon, 'result') = NIL_SYM) then
          begin
            var LRes := FModel.AddSymbol(LAnon, skVar, 'Result', NIL_NODE);
            FModel.Symbols[LRes].TypeNode := LChild;
            FModel.BindName(LAnon, LRes);
          end;
          Collect(LChild, LAnon);
          LChild := NextSib(LChild);
        end;
        // A procedure literal has no result type child: still shadow the
        // enclosing Result so it cannot leak into the anonymous body.
        if FModel.FindLocal(LAnon, 'result') = NIL_SYM then
        begin
          var LRes := FModel.AddSymbol(LAnon, skVar, 'Result', NIL_NODE);
          FModel.BindName(LAnon, LRes);
        end;
      end;

    nkMethodResolution:
      begin
        { 14.2.2 `function IPersistStreamInit.Load = PersistStreamLoad;`.

          The name segments arrive as a FLAT sibling list (the routine-header
          convention, not an nkMember), and their roles are NOT the ones a
          qualified implementation header has:

            [interface] [<type args>]? [the INTERFACE's method] [class method]

          Only the first and last are names in THIS scope. The middle segment
          names a member of the interface, so resolving it here as an ordinary
          unqualified reference is guaranteed to fail — that was 6 false E2003 in
          Vcl.AxCtrls alone (`IPersistStorage.Load`, `.Save`, ...).

          It is left WITHOUT A SCOPE, the same device the unit's own name node
          uses, so no pass — intra-unit or cross — tries to resolve or report it.
          ResolveNode binds it against the interface's member scope where it can,
          which is the navigable case.

          The <...> segment is a type ARGUMENT of the implemented interface, not
          a generic parameter declaration (§14.2.2's own warning), so its idents
          stay plain references. }
        var LIdents: TArray<Integer> := nil;
        LChild := FirstChild(ANode);
        while LChild <> NIL_NODE do
        begin
          if KindOf(LChild) = nkGenericParams then
          begin
            var LParam := FirstChild(LChild);
            while LParam <> NIL_NODE do
            begin
              var LP := FirstChild(LParam);   // idents + optional constraint
              while LP <> NIL_NODE do
              begin
                Collect(LP, AScope);
                LP := NextSib(LP);
              end;
              LParam := NextSib(LParam);
            end;
          end
          else if KindOf(LChild) = nkIdent then
            LIdents := LIdents + [LChild]
          else
            Collect(LChild, AScope);
          LChild := NextSib(LChild);
        end;
        for var LI := 0 to High(LIdents) do
          // First = the interface, last = this class's method: both are names in
          // AScope. Anything between belongs to the interface.
          if (LI = 0) or (LI = High(LIdents)) or (Length(LIdents) < 3) then
            Collect(LIdents[LI], AScope);
      end;

    nkRecordType, nkClassType, nkInterfaceType, nkObjectType, nkHelperType:
      // An ANONYMOUS structured type — written inline in a declaration's type
      // slot rather than given a name, e.g. `TAB: array[0..1] of record
      // offset, minimum: Cardinal; end = (...)`. It gets a member scope like
      // any other struct, but until now no SYMBOL owned that scope, and every
      // cross-model type is a (unit, symbol) pair — so `with TAB[I] do` could
      // name the element type at all, and its fields read as undeclared. The
      // synthetic symbol is deliberately unnamed: nothing may resolve TO it by
      // name, it exists only to carry the member scope.
      CollectStruct(ANode, AScope, DeclareAnonStruct(AScope, ANode));

    nkBlock, nkForStmt, nkForInStmt:
      begin
        // Inline vars are block-scoped: give each begin..end its own scope so
        // the same name in sibling blocks does not read as a redeclaration.
        // A for statement scopes the same way — its `for var I` counter or
        // `for var E in` element lives in the LOOP, so two sibling loops
        // reusing one name are not a redeclaration (dcc behavior).
        var LBlock := FModel.AddScope(sckBlock, AScope, ANode);
        FNodeScope[ANode] := LBlock;
        LChild := FirstChild(ANode);
        while LChild <> NIL_NODE do
        begin
          Collect(LChild, LBlock);
          LChild := NextSib(LChild);
        end;
      end;

    nkProcType:
      begin
        // 6.6.1 procedural type: its parameter NAMES are declarations of the
        // signature, not references — declare them in a scope of their own
        // (nothing outside the signature can see them), so they neither leak
        // nor read as undeclared identifiers (`TNotifyEvent = procedure(
        // Sender: TObject)...` must not E2003 on Sender). Everything else
        // (param types, result type) resolves normally.
        var LSig := FModel.AddScope(sckRoutine, AScope, ANode);
        FNodeScope[ANode] := LSig;
        LChild := FirstChild(ANode);
        while LChild <> NIL_NODE do
        begin
          if KindOf(LChild) = nkParams then
          begin
            FNodeScope[LChild] := LSig;
            var LParam := FirstChild(LChild);
            while LParam <> NIL_NODE do
            begin
              if KindOf(LParam) = nkParam then
                DeclareNamesAndType(LParam, LSig, skParam);
              LParam := NextSib(LParam);
            end;
          end
          else
            Collect(LChild, LSig);
          LChild := NextSib(LChild);
        end;
      end;

    nkExceptOn:
      begin
        // 18.1.2 `on [E:] Type do stmt` — the handler variable (named form:
        // 3 children = ident, type, body) is scoped to THIS handler alone.
        var LOn := FModel.AddScope(sckBlock, AScope, ANode);
        FNodeScope[ANode] := LOn;
        LChild := FirstChild(ANode);
        if (LChild <> NIL_NODE) and (KindOf(LChild) = nkIdent) and
           (NextSib(LChild) <> NIL_NODE) and
           (NextSib(NextSib(LChild)) <> NIL_NODE) then
        begin
          var LVar := FModel.AddSymbol(LOn, skVar, NodeText(LChild), LChild);
          FModel.Symbols[LVar].TypeNode := NextSib(LChild);
          FModel.BindName(LOn, LVar);
          MarkDeclName(LChild, LVar);
          LChild := NextSib(LChild);   // resolve from the TYPE on
        end;
        while LChild <> NIL_NODE do
        begin
          Collect(LChild, LOn);
          LChild := NextSib(LChild);
        end;
      end;

    nkEnumType:
      CollectEnum(ANode, AScope, NIL_SYM);

    nkGenericParams:
      begin
        LChild := FirstChild(ANode);
        while LChild <> NIL_NODE do
        begin
          if KindOf(LChild) = nkGenericParam then
          begin
            // leading idents = parameter names; a trailing nkConstraint refs types
            var LP := FirstChild(LChild);
            while (LP <> NIL_NODE) and (KindOf(LP) = nkIdent) do
            begin
              DeclareSym(AScope, skGenericParam, NodeText(LP), LP);
              LP := NextSib(LP);
            end;
            while LP <> NIL_NODE do
            begin
              Collect(LP, AScope);
              LP := NextSib(LP);
            end;
          end;
          LChild := NextSib(LChild);
        end;
      end;

    nkAggregateField:
      begin
        // FirstChild is a FIELD NAME (`style` in `(style: 0; ...)`), never
        // an ordinary value reference — resolved directly against the
        // aggregate's target type once BindTypes has run (see
        // ResolveAggregates), same spirit as nkMember's own member name
        // (ResolveNode: "resolved via A's scope, never as a plain
        // identifier"). Left UNVISITED here (NIL_SCOPE stays), so it is
        // never an undeclared-identifier candidate regardless of whether
        // that later pass finds a match — a typo'd field name silently
        // stays unresolved rather than false-E2003ing, the same trade-off
        // the array-property index param fix already makes. Only the VALUE
        // needs ordinary Collect.
        Collect(NextSib(FirstChild(ANode)), AScope);
      end;

    nkNamedArg:
      begin
        // `Meth(Source := X)` on a late-bound (Variant) call, 4.10.1. FirstChild
        // is a DISPATCH PARAMETER NAME resolved by the automation server at run
        // time — dcc name-checks nothing there (`V.Add(Nonexistent := 1)`
        // compiles), so leaving it unvisited, NIL_SCOPE and all, is exactly
        // right: every undeclared-identifier path already skips scopeless nodes.
        // The VALUE is an ordinary expression and IS checked (dcc-verified:
        // `V.Add(Source := Undeclared1)` is E2003 on the value).
        Collect(NextSib(FirstChild(ANode)), AScope);
      end;

  else
    begin
      LChild := FirstChild(ANode);
      while LChild <> NIL_NODE do
      begin
        Collect(LChild, AScope);
        LChild := NextSib(LChild);
      end;
    end;
  end;
end;

{ helpers (ch.15 §15.3)

  A `class/record helper for T` declares members that behave, at every use
  site, as if they were T's own: a method of T sees the helper's members bare
  (`Result := Identity` inside TMatrix.CreateRotation, where Identity is a
  const of `TMatrixConstants = record helper for TMatrix` — System.Math.
  Vectors, the bug that prompted this), a qualified `T.Member` finds them, and
  — the other direction — the helper's OWN method bodies see T's members
  through their implicit Self (`FValue` inside a TThingHelper method).

  None of that could happen from CollectStruct: a helper may be declared
  before the type it extends, so the `for T` target is not necessarily a
  declared symbol yet while collecting. Hence a pass of its own, run once
  Collect has declared every type in the unit but before Resolve binds any
  name — the joins have to be in place before the first lookup.

  INTRA-UNIT ONLY. A helper whose target lives in another unit (a qualified
  `for Some.Unit.T`) is skipped: cross-model member injection belongs to the
  project driver's cross passes, not here. Skipping only costs reach, never
  correctness — an unresolved name is never itself a diagnostic. }

// The `for T` target of a helper: the LAST of the leading run of type
// references under the nkHelperType node. A class helper may also name a
// helper ANCESTOR (`class helper (TBase) for T`), which the parser adopts
// FIRST, so only the last reference is the extended type; members follow and
// are never bare type references, which is where the run ends.
function TPasSemaResolver.HelperForTypeRef(ANode: Integer): Integer;
var
  LChild: Integer;
begin
  Result := NIL_NODE;
  LChild := SkipAttr(FirstChild(ANode));
  while (LChild <> NIL_NODE) and
        (KindOf(LChild) in [nkIdent, nkMember, nkTypeArgs]) do
  begin
    Result := LChild;
    LChild := NextSib(LChild);
  end;
end;

procedure TPasSemaResolver.JoinHelperScopes;
var
  LIdx, LScope, LRef, LExtSym: Integer;
  LExtScopes: TArray<Integer>;   // parallel to FPendingHelpers; NIL_SCOPE = skip
  LAny: Boolean;

  // The member scope of ASym or of whatever it aliases, resolving each link by
  // NAME (see the call site for why RefMap is unavailable here). Depth-capped
  // like StructMemberScope, for the same malformed/circular-chain reason.
  function AliasedMemberScope(ASym: Integer): Integer;
  var
    LSym, LDef, LDepth: Integer;
  begin
    Result := NIL_SCOPE;
    LSym := ASym;
    for LDepth := 1 to 32 do
    begin
      if LSym = NIL_SYM then
        Exit;
      if FModel.Symbols[LSym].MemberScope <> NIL_SCOPE then
        Exit(FModel.Symbols[LSym].MemberScope);
      if FModel.Symbols[LSym].DeclNode = NIL_NODE then
        Exit;
      LDef := NextSib(FModel.Symbols[LSym].DeclNode);
      while (LDef <> NIL_NODE) and (KindOf(LDef) = nkGenericParams) do
        LDef := NextSib(LDef);
      if (LDef = NIL_NODE) or (KindOf(LDef) <> nkIdent) then
        Exit;
      LSym := FModel.Resolve(FNodeScope[LDef], NodeNameLower(LDef));
    end;
  end;

begin
  if Length(FPendingHelpers) = 0 then
    Exit;
  SetLength(LExtScopes, Length(FPendingHelpers));
  LAny := False;
  for LIdx := 0 to High(FPendingHelpers) do
  begin
    LExtScopes[LIdx] := NIL_SCOPE;
    var LHelperScope := FModel.Symbols[FPendingHelpers[LIdx].HelperSym].MemberScope;
    if LHelperScope = NIL_SCOPE then
      Continue;
    LRef := HelperForTypeRef(FPendingHelpers[LIdx].Node);
    // Only a bare name is resolvable here (see the INTRA-UNIT note above).
    if (LRef = NIL_NODE) or (KindOf(LRef) <> nkIdent) then
      Continue;
    LExtSym := FModel.Resolve(FNodeScope[LRef], NodeNameLower(LRef));
    if (LExtSym = NIL_SYM) or (FModel.Symbols[LExtSym].Kind <> skType) then
      Continue;
    // Chase alias links, because the `for` target is often an ALIAS of the
    // real struct and only the struct's own symbol carries a member scope
    // (`TD2DMatrix3x2F = D2D_MATRIX_3X2_F`, helper declared for the alias
    // while the operator methods are on the underlying record —
    // Winapi.D2D1). NOT StructMemberScope: that chases via DesignatorHead,
    // i.e. RefMap, and this pass runs BEFORE ResolveNode has filled it (it
    // must — Resolve is what binds the names this join exists to serve). So
    // resolve each link by NAME instead. Bare names only, matching the
    // INTRA-UNIT guard on the `for` target above.
    var LExtScope := AliasedMemberScope(LExtSym);
    if LExtScope = NIL_SCOPE then
      Continue;
    // `TFoo = record helper for TFoo` is malformed but parses, and the name
    // resolves right back to the helper itself — joining a scope INTO ITSELF
    // would make FindLocalDeep recurse forever on every failed lookup. The
    // one shape that can do that, refused explicitly; every other join here
    // points from an extended type to a DIFFERENT helper, so the Additional
    // graph stays acyclic.
    if LExtScope = LHelperScope then
      Continue;
    // Direction 1: T's members now include the helper's, so both a bare
    // reference from inside T's own methods (which join T's member scope)
    // and a qualified T.Member (ResolveNode's nkMember, via FindLocalDeep)
    // find them. LAST helper joined wins the lookup — FindLocalDeep walks
    // Additional most-recently-added first, which is dcc's own rule when two
    // helpers for one type are in scope.
    // SHADOWING, not an ordinary join: a helper member hides the extended
    // type's own of the same name (15.3.3). That precedence was the long
    // standing same-unit gap — the cross-unit side (HelperMemberHit, checked
    // before the type's members at every hop) has always had it right.
    FModel.JoinScopeShadowing(LExtScope, LHelperScope);
    LExtScopes[LIdx] := LExtScope;
    LAny := True;
  end;
  if not LAny then
    Exit;
  // Direction 2: the helper's own method BODIES see T's members through the
  // implicit Self. Those bodies are separate routine scopes (a method is
  // implemented outside the type), each tagged by CollectRoutine with the
  // struct it belongs to — so the tag is what identifies them. Joined into
  // the ROUTINE scope, deliberately NOT into the helper's member scope: the
  // latter would pair with direction 1 into a two-node cycle.
  for LScope := 0 to FModel.Scopes.Count - 1 do
    if FModel.Scopes[LScope].Kind = sckRoutine then
      for LIdx := 0 to High(FPendingHelpers) do
        if (LExtScopes[LIdx] <> NIL_SCOPE) and
           (FModel.Scopes[LScope].StructSym = FPendingHelpers[LIdx].HelperSym) then
          FModel.JoinScope(LScope, LExtScopes[LIdx]);
end;

{ resolve }

// The symbol a designator (nkIdent / nkMember / nkTypeArgs) resolved to.
function TPasSemaResolver.DesignatorHead(ANode: Integer): Integer;
var
  LLast: Integer;
begin
  case KindOf(ANode) of
    nkIdent:
      Result := FModel.RefMap[ANode];
    nkMember:
      begin
        LLast := FirstChild(ANode);
        while (LLast <> NIL_NODE) and (NextSib(LLast) <> NIL_NODE) do
          LLast := NextSib(LLast);
        if LLast <> NIL_NODE then
          Result := FModel.RefMap[LLast]
        else
          Result := NIL_SYM;
      end;
    nkTypeArgs:
      Result := DesignatorHead(FirstChild(ANode));
  else
    Result := NIL_SYM;
  end;
end;

procedure TPasSemaResolver.ResolveNode(ANode: Integer);
var
  LChild, LBase, LName, LHead, LMemScope: Integer;
begin
  if ANode = NIL_NODE then
    Exit;

  case KindOf(ANode) of
    nkIdent:
      if not FIsDeclName[ANode] and (FModel.RefMap[ANode] = NIL_SYM) then
      begin
        // Computed ONCE for the whole branch — the arity retry and the
        // attribute fallback below used to re-lower the same node.
        var LNameLower := NodeNameLower(ANode);
        // ResolveAt, not Resolve: this is a REFERENCE, and an inline
        // `var`/`const` is visible only from its own declaration onward
        // (3.1.3). See TPasSemaModel.ResolveAt — the position is only
        // consulted for block scopes, so a routine's classic `var` section and
        // everything above it stay order-independent.
        FModel.RefMap[ANode] := FModel.ResolveAt(FNodeScope[ANode],
          LNameLower, FTree.Nodes[ANode].FirstToken);
        // ARITY is part of a type's identity (16.1.2), and BOTH directions of
        // ignoring that are real — one third-party library's base unit sets both traps:
        // `Pointer<T>` beside the builtin `Pointer` (a BARE name must skip the
        // generic) and `Nullable` beside `Nullable<T>` (a `Name<T>` must skip
        // the non-generic). The project pass has had the rule for CROSS-unit
        // references (PreferNonGeneric / FindTypeInUsesArity); this is the same
        // rule where RefMap is actually written, which is also what ctrl+click
        // reads.
        //
        // The conditions are tested INLINE and in this order for the reason
        // PreferNonGeneric gives: the common case must cost one set membership
        // and no call. A type hit is common, a MISMATCHED one is not.
        if (FModel.RefMap[ANode] <> NIL_SYM) and
           (FModel.Symbols[FModel.RefMap[ANode]].Kind = skType) then
        begin
          var LWantGeneric := not IsBareTypeUse(ANode);
          if (sfGeneric in FModel.Symbols[FModel.RefMap[ANode]].Flags) <>
             LWantGeneric then
          begin
            LHead := FModel.ResolveByArityAt(FNodeScope[ANode],
              LNameLower, FTree.Nodes[ANode].FirstToken,
              LWantGeneric);
            // NIL_SYM = only the other arity is in scope, which is dcc's error
            // and not a reason to drop the binding we have.
            if LHead <> NIL_SYM then
              FModel.RefMap[ANode] := LHead;
          end;
          // Generic-vs-not is only half of 16.1.2: the COUNT is part of the
          // identity too, and a name declared at two generic arities registers
          // only its head. `TNodes<T>` and `TNodes<TKey, TValue>` (a third-party
          // Spring.Collections.Trees) both declare a nested
          // `PRedBlackTreeNode`, so binding the qualifier to the wrong arity
          // silently resolved the wrong nested type — and the only visible
          // difference was that its node record has `fKey` where the other has
          // `fPair`. Same walk the qualified-implementation-name case does
          // above; reached only for a name written WITH type arguments whose
          // count does not match, so the ordinary reference pays nothing.
          if not IsBareTypeUse(ANode) then
          begin
            var LWantArity := GenericArityOfParamsNode(
              FTree.Nodes[ANode].Parent);
            var LBound := FModel.RefMap[ANode];
            if (LBound <> NIL_SYM) and (LWantArity > 0) and
               (FModel.Symbols[LBound].Kind = skType) and
               (GenericArityOfSym(LBound) <> LWantArity) then
            begin
              var LAlt := FModel.Symbols[LBound].NextOverload;
              while LAlt <> NIL_SYM do
              begin
                if (FModel.Symbols[LAlt].Kind = skType) and
                   (GenericArityOfSym(LAlt) = LWantArity) then
                begin
                  FModel.RefMap[ANode] := LAlt;
                  Break;
                end;
                LAlt := FModel.Symbols[LAlt].NextOverload;
              end;
            end;
          end;
        end;
        if (FModel.RefMap[ANode] = NIL_SYM) and IsAttributeTypeRef(ANode) then
          FModel.RefMap[ANode] := FModel.ResolveAt(FNodeScope[ANode],
            LNameLower + 'attribute', FTree.Nodes[ANode].FirstToken);
      end;

    nkMethodResolution:
      begin
        // Segments are flat siblings; see Collect's own case for the roles. The
        // middle one has no scope, so the generic child walk below would leave
        // it unbound — bind it against the interface's members when the
        // interface is same-unit, which is what makes it navigable.
        var LSegs: TArray<Integer> := nil;
        LChild := FirstChild(ANode);
        while LChild <> NIL_NODE do
        begin
          if KindOf(LChild) = nkIdent then
            LSegs := LSegs + [LChild]
          else
            ResolveNode(LChild);
          LChild := NextSib(LChild);
        end;
        for var LI := 0 to High(LSegs) do
          if (LI = 0) or (LI = High(LSegs)) or (Length(LSegs) < 3) then
            ResolveNode(LSegs[LI]);
        if Length(LSegs) >= 3 then
        begin
          LHead := FModel.RefMap[LSegs[0]];
          if (LHead <> NIL_SYM) and
             (FModel.Symbols[LHead].MemberScope <> NIL_SCOPE) then
            for var LI := 1 to High(LSegs) - 1 do
              FModel.RefMap[LSegs[LI]] := FModel.FindLocalDeep(
                FModel.Symbols[LHead].MemberScope, NodeNameLower(LSegs[LI]));
        end;
      end;

    nkMember:
      begin
        LBase := FirstChild(ANode);
        LName := NextSib(LBase);
        ResolveNode(LBase);
        LHead := DesignatorHead(LBase);
        if (LName <> NIL_NODE) and (LHead <> NIL_SYM) then
        begin
          LMemScope := FModel.Symbols[LHead].MemberScope;
          // FindLocalDeep, not FindLocal: a struct's member scope carries a
          // joined scope only where one was deliberately injected into it —
          // today that is a helper's members (JoinHelperScopes), which a
          // qualified `TMatrix.Identity` must find exactly like a bare one.
          if LMemScope <> NIL_SCOPE then
            FModel.RefMap[LName] :=
              FModel.FindLocalDeep(LMemScope, NodeNameLower(LName));
        end;
        // LName resolved (or left NIL) here; do not recurse into it as an ident
        Exit;
      end;
  end;

  LChild := FirstChild(ANode);
  while LChild <> NIL_NODE do
  begin
    ResolveNode(LChild);
    LChild := NextSib(LChild);
  end;
end;

procedure TPasSemaResolver.BindTypes;
var
  LIdx, LHead: Integer;
begin
  for LIdx := 0 to FModel.SymCount - 1 do
    if FModel.Symbols[LIdx].TypeNode <> NIL_NODE then
    begin
      LHead := DesignatorHead(FModel.Symbols[LIdx].TypeNode);
      if (LHead <> NIL_SYM) and
         (FModel.Symbols[LHead].Kind in [skType, skBuiltinType, skGenericParam]) then
        FModel.Symbols[LIdx].TypeSym := LHead;
    end;
end;

{ structured typed-const/var initializers (3.2.2)

  `X: TWndClass = (style: 0; lpfnWndProc: ...)` — the parser already builds
  nkAggregate/nkAggregateField nodes (TPasParser.ParseConstInitializer) but
  nothing downstream resolved a field NAME against the target type; Collect
  left it deliberately unvisited (see the nkAggregateField case) rather than
  treat it as an ordinary value reference, so this pass is the only place
  that can still fill in the right answer — same two-phase shape as `with`
  above: type binding (BindTypes) must run first, so this runs right after. }

// ATypeSym's own struct member scope, chasing through however many alias
// links sit in between (`TWndClass = TWndClassW = tagWNDCLASSW = record
// ... end;` — only tagWNDCLASSW's OWN symbol gets a MemberScope from
// CollectStruct; every alias in the chain has NIL_SCOPE). Depth-capped like
// AncestorTypeSym: real alias chains are shallow; this only guards a
// malformed/circular one.
function TPasSemaResolver.StructMemberScope(ATypeSym: Integer): Integer;
var
  LSym, LDef, LDepth: Integer;
begin
  Result := NIL_SCOPE;
  LSym := ATypeSym;
  LDepth := 0;
  while (LSym <> NIL_SYM) and (LDepth < 32) do
  begin
    Inc(LDepth);
    if FModel.Symbols[LSym].MemberScope <> NIL_SCOPE then
      Exit(FModel.Symbols[LSym].MemberScope);
    if FModel.Symbols[LSym].DeclNode = NIL_NODE then
      Exit;
    LDef := NextSib(FModel.Symbols[LSym].DeclNode);
    while (LDef <> NIL_NODE) and (KindOf(LDef) = nkGenericParams) do
      LDef := NextSib(LDef);
    if (LDef <> NIL_NODE) and (KindOf(LDef) in [nkIdent, nkMember, nkTypeArgs])
    then
      LSym := DesignatorHead(LDef)
    else
      Exit;
  end;
end;

// Resolves every nkAggregateField name directly under AAggrNode against
// AStructScope (the target type's member scope — NIL_SCOPE if the type
// wasn't a struct at all, e.g. an array/set aggregate, in which case this
// is a no-op: those have no field names to resolve in the first place),
// recursing into a nested aggregate for a record-typed field. Plain
// (unnamed) elements sitting alongside field entries — an array-of-scalar
// or set aggregate — are untouched: ordinary expressions Collect/ResolveNode
// already resolve normally, nothing new needed there.
procedure TPasSemaResolver.ResolveAggregateAgainst(AAggrNode,
  AStructScope: Integer);
var
  LChild, LNameNode, LValue, LFieldSym: Integer;
begin
  if (AAggrNode = NIL_NODE) or (AStructScope = NIL_SCOPE) then
    Exit;
  LChild := FirstChild(AAggrNode);
  while LChild <> NIL_NODE do
  begin
    if KindOf(LChild) = nkAggregateField then
    begin
      LNameNode := FirstChild(LChild);
      if (LNameNode <> NIL_NODE) and (KindOf(LNameNode) = nkIdent) then
      begin
        LFieldSym := FModel.FindLocal(AStructScope,
          NodeNameLower(LNameNode));
        if LFieldSym <> NIL_SYM then
        begin
          FModel.RefMap[LNameNode] := LFieldSym;
          LValue := NextSib(LNameNode);
          if (LValue <> NIL_NODE) and (KindOf(LValue) = nkAggregate) then
            ResolveAggregateAgainst(LValue,
              StructMemberScope(FModel.Symbols[LFieldSym].TypeSym));
        end;
      end;
    end;
    LChild := NextSib(LChild);
  end;
end;

procedure TPasSemaResolver.ResolveAggregates;
var
  LIdx, LTypeSym: Integer;
begin
  for LIdx := 0 to High(FPendingAggr) do
  begin
    LTypeSym := DesignatorHead(FPendingAggr[LIdx].TypeNode);
    if LTypeSym = NIL_SYM then
      Continue;
    ResolveAggregateAgainst(FPendingAggr[LIdx].AggrNode,
      StructMemberScope(LTypeSym));
  end;
end;

{ with (ch.05 §5.7)

  `with A, B do Body` opens an unqualified-name scope over A's and B's own
  members, right-to-left (B, the LAST target, wins a name both share) —
  Body sees them BEFORE the enclosing scope. This can only run as a
  SEPARATE, LATER pass, not inline in Collect/ResolveNode: it needs the
  TARGET's TYPE to find the member scope to open, and type information
  (TypeSym, bound by BindTypes from a symbol's own declared type node) is
  only available once BindTypes has run — which itself runs after
  ResolveNode. So: Collect/ResolveNode run as normal, unaware of `with`
  (a with-body's identifiers are Phase-1-unresolved exactly like any
  identifier from a not-yet-known scope); THEN, once BindTypes has bound
  declared types, ResolveWithStmts finds each target's type, opens a scope
  over its members, splices that scope into the with-body's existing scope
  chain (RepointScope), and re-runs ResolveNode over the body — which,
  thanks to ResolveNode's existing NIL_SYM guard, only fills in the NAMES
  that were still unresolved, never touching ones Phase 1 already got right. }

// ATypeSym's DIRECT ancestor's type symbol — same-unit only. CollectStruct
// never joins an ancestor's MemberScope into the descendant's own (that is
// the PROJECT-level CrossResolveInherited/FindMemberX pass's job, which also
// reaches CROSS-unit ancestors); this is a deliberately NARROWER intra-unit
// climb, giving `with` at least same-unit inherited members (a same-unit
// struct's own children lead with the heritage clause — ancestor first, any
// IMPLEMENTED INTERFACES after — CollectStruct's own nkIdent/nkMember/
// nkTypeArgs case list; the FIRST such child is always the true ancestor,
// same convention the project-level pass already uses). NIL_SYM (a
// cross-unit ancestor, or none) is the same graceful "can't fully type
// this" this whole feature already accepts elsewhere.
function TPasSemaResolver.AncestorTypeSym(ATypeSym: Integer): Integer;
var
  LScope, LChild, LHead: Integer;
begin
  Result := NIL_SYM;
  if ATypeSym = NIL_SYM then
    Exit;
  LScope := FModel.Symbols[ATypeSym].MemberScope;
  if LScope = NIL_SCOPE then
    Exit;
  LChild := FirstChild(FModel.Scopes[LScope].OwnerNode);
  while LChild <> NIL_NODE do
  begin
    if KindOf(LChild) in [nkIdent, nkMember, nkTypeArgs] then
    begin
      LHead := DesignatorHead(LChild);
      if (LHead <> NIL_SYM) and (FModel.Symbols[LHead].Kind = skType) then
        Result := LHead;
      Exit;
    end;
    LChild := NextSib(LChild);
  end;
end;

// ANameLower on ATypeSym's OWN member scope, or (same-unit only) an
// ancestor's — see AncestorTypeSym. Depth-capped defensively; real
// hierarchies are nowhere near this deep.
function TPasSemaResolver.FindMemberUpChain(ATypeSym: Integer;
  const ANameLower: string): Integer;
var
  LScope, LDepth: Integer;
begin
  Result := NIL_SYM;
  LDepth := 0;
  while (ATypeSym <> NIL_SYM) and (LDepth < 32) do
  begin
    Inc(LDepth);
    LScope := FModel.Symbols[ATypeSym].MemberScope;
    if LScope <> NIL_SCOPE then
    begin
      Result := FModel.FindLocal(LScope, ANameLower);
      if Result <> NIL_SYM then
        Exit;
    end;
    ATypeSym := AncestorTypeSym(ATypeSym);
  end;
end;

// The with-TARGET's type, restricted to what BindTypes already established
// (a symbol's OWN declared type — not full expression-level inference,
// which is the intra-unit typer's job and runs even later than this pass).
// Matches the spec's own restriction that with-targets are plain designators
// (var/field/param/property/routine-result) or a type-cast, not arbitrary
// expressions — NIL_SYM for anything fancier (e.g. an inline-if) is a
// deliberate, graceful "leave it unresolved", not a regression.
//
// nkMember needs its OWN chain-walk, not a RefMap lookup: Phase 1's
// ResolveNode only resolves a TYPE-QUALIFIED member (TFoo.Bar) — an
// INSTANCE member chain (Obj.Field.Method, e.g. `FItems.Add` — the ACTUAL
// shape of the real bug report, Vcl.ComCtrls.pas's `with FItems.Add do`) is
// deliberately left NIL there; walking it is normally the PROJECT-level
// CrossType pass's job (FindMemberX), which runs long after this one unit's
// Run finishes — too late for `with`. So this recurses on the BASE's own
// type (via this same function — restricted to the same simple designator
// shapes) and looks the member up directly, rather than trusting a RefMap
// entry that was never going to be there.
{ Does ABaseNode name an ARRAY PROPERTY — a property that declares parameters?
  Then the brackets after it are ITS index list, the model already stores its
  declared type per-element, and nothing further may be peeled. Anything else
  (a field, a variable, a plain property) is a value being indexed, and if its
  type is a class the brackets mean that class's DEFAULT array property. }
function TPasSemaResolver.IsArrayPropDesignator(ABaseNode: Integer): Boolean;
var
  LSym, LDecl, LChild: Integer;
begin
  Result := False;
  LSym := DesignatorHead(ABaseNode);
  if (LSym = NIL_SYM) or (FModel.Symbols[LSym].Kind <> skProperty) then
    Exit;
  LDecl := FModel.Symbols[LSym].DeclNode;
  if LDecl = NIL_NODE then
    Exit;
  LDecl := FTree.Nodes[LDecl].Parent;
  if (LDecl = NIL_NODE) or (KindOf(LDecl) <> nkPropertyDecl) then
    Exit;
  LChild := FirstChild(LDecl);
  while LChild <> NIL_NODE do
  begin
    if KindOf(LChild) = nkParams then
      Exit(True);
    LChild := NextSib(LChild);
  end;
end;

{ The declared type of ATypeSym's DEFAULT array property — the one indexing an
  instance of it means (13.1.2) — searched up the same-unit ancestor chain,
  NIL_SYM when the type has none. A property qualifies when it declares
  PARAMETERS and carries the `default` specifier, exactly as the project
  typer's IsDefaultArrayProp reads it; the model stores such a property's
  declared type per-ELEMENT already, so the type symbol IS the element's. }
function TPasSemaResolver.DefaultArrayPropTypeSym(ATypeSym: Integer): Integer;
var
  LScope, LDepth, LSym, LDecl, LChild: Integer;
  LHasParams, LHasDefault: Boolean;
begin
  Result := NIL_SYM;
  LDepth := 0;
  while (ATypeSym <> NIL_SYM) and (LDepth < 32) do
  begin
    Inc(LDepth);
    LScope := FModel.Symbols[ATypeSym].MemberScope;
    if (LScope <> NIL_SCOPE) and (FModel.Scopes[LScope].Symbols <> nil) then
      // The scope's OWN declaration list, not a scan of every symbol in the
      // unit: this runs per with-target, and a whole-model scan on a shared
      // path is the perf trap this codebase has hit three times.
      for LSym in FModel.Scopes[LScope].Symbols do
      begin
        if FModel.Symbols[LSym].Kind <> skProperty then
          Continue;
        LDecl := FModel.Symbols[LSym].DeclNode;
        if LDecl = NIL_NODE then
          Continue;
        LDecl := FTree.Nodes[LDecl].Parent;
        if (LDecl = NIL_NODE) or (KindOf(LDecl) <> nkPropertyDecl) then
          Continue;
        LHasParams := False;
        LHasDefault := False;
        LChild := FirstChild(LDecl);
        while LChild <> NIL_NODE do
        begin
          if KindOf(LChild) = nkParams then
            LHasParams := True
          else if (KindOf(LChild) = nkPropSpec) and
                  (NodeNameLower(LChild) = 'default') then
            LHasDefault := True;
          LChild := NextSib(LChild);
        end;
        if LHasParams and LHasDefault then
          Exit(FModel.Symbols[LSym].TypeSym);
      end;
    ATypeSym := AncestorTypeSym(ATypeSym);
  end;
end;

function TPasSemaResolver.WithTargetTypeSym(ANode: Integer): Integer;
var
  LBase, LName, LHead, LBaseType, LScope: Integer;
begin
  Result := NIL_SYM;
  case KindOf(ANode) of
    // `with inherited Canvas do` (Vcl.ExtCtrls). 12.1.2: `inherited Name` names
    // a member of the ANCESTOR, so the target's type is that member's, looked up
    // from the ancestor of the struct whose method body this is. The project
    // typer has had this branch since the nkInherited fix; without it here the
    // SAME-unit case never opened its scope intra-unit — no false diagnostic
    // (the project pass covers it) but no navigation either.
    nkInherited:
      begin
        LName := FirstChild(ANode);
        if (LName = NIL_NODE) or (KindOf(LName) <> nkIdent) then
          Exit;
        LScope := FNodeScope[ANode];
        while (LScope <> NIL_SCOPE) and
              (FModel.Scopes[LScope].StructSym = NIL_SYM) do
          LScope := FModel.Scopes[LScope].Parent;
        if LScope = NIL_SCOPE then
          Exit;
        LHead := AncestorTypeSym(FModel.Scopes[LScope].StructSym);
        if LHead = NIL_SYM then
          Exit;
        LHead := FindMemberUpChain(LHead, NodeNameLower(LName));
        if LHead <> NIL_SYM then
          Result := FModel.Symbols[LHead].TypeSym;
      end;

    nkIdent:
      begin
        LHead := FModel.RefMap[ANode];
        if LHead = NIL_SYM then
          Exit;
        case FModel.Symbols[LHead].Kind of
          skVar, skConst, skField, skParam, skRoutine, skProperty:
            Result := FModel.Symbols[LHead].TypeSym;
          // A bare class TYPE NAME is a legal target (5.7, dcc-verified:
          // `with TCanvas do Tick` reaches its class methods and class vars —
          // the same reach a `class of` reference gives). The target's type is
          // the type ITSELF; asking for its declared type, as the value kinds
          // above do, yields nothing.
          skType, skBuiltinType:
            Result := LHead;
        end;
      end;
    nkMember:
      begin
        LBase := FirstChild(ANode);
        LName := NextSib(LBase);
        if LName = NIL_NODE then
          Exit;
        LHead := FModel.RefMap[LName];
        if LHead = NIL_SYM then
        begin
          LBaseType := WithTargetTypeSym(LBase);
          if LBaseType = NIL_SYM then
            Exit;
          LHead := FindMemberUpChain(LBaseType, NodeNameLower(LName));
          if LHead = NIL_SYM then
            Exit;
          // Retroactively record it — the same thing CrossType would do
          // later for navigation purposes; a free correctness improvement
          // (e.g. ctrl+click on `Add` in `with FItems.Add do` now works
          // too), and keeps the upcoming ResolveNode(LBody) re-walk (which
          // recurses back through the targets — see ResolveWithStmts'
          // header) consistent with what this function already found.
          FModel.RefMap[LName] := LHead;
        end;
        case FModel.Symbols[LHead].Kind of
          skVar, skConst, skField, skParam, skRoutine, skProperty:
            Result := FModel.Symbols[LHead].TypeSym;
        end;
      end;
    nkCall:
      begin
        LBase := FirstChild(ANode);
        // A cast T(Expr): the callee is a bare type name — resolves
        // directly (Phase 1 already gets a plain type-name reference
        // right, no chain-walk needed).
        if KindOf(LBase) = nkIdent then
        begin
          LHead := FModel.RefMap[LBase];
          if (LHead <> NIL_SYM) and
             (FModel.Symbols[LHead].Kind in [skType, skBuiltinType]) then
            Exit(LHead);
        end;
        // Otherwise a routine/property call (bare or parenthesized,
        // qualified or not) -> its own declared result type — same
        // designator-typing this function already does for a parenless
        // access, so just recurse on the callee.
        Result := WithTargetTypeSym(LBase);
      end;
    nkIndex:
      // `with Arr[I] do` — the ELEMENT type. By far the most common with-target
      // shape in the RTL: `with FList[Index] do` (System.WideStrings),
      // `with LVarBounds[I] do` (System.Variants), `with Entry.Aliases[High(
      // Entry.Aliases)] do` (System.TypInfo), `with NetResources^[I] do`
      // (System.AnsiStrings, index over a deref) — 27 false E2003s between
      // them.
      //
      // ElementTypeOf returns NIL_SYM when the base is NOT an array, which is
      // exactly the array-PROPERTY case: this model stores such a property's
      // declared type as its per-ELEMENT type already (CollectStruct's
      // nkPropertyDecl handling), so indexing must NOT peel a level there.
      // Hence the fallback to the pass-through.
      begin
        Result := ElementTypeOf(FirstChild(ANode));
        // Not an array, but a CLASS/record with a DEFAULT array property is
        // indexable all the same, and then the element type is that
        // property's — `with Values[I - 1] do`, where Values is a
        // TcxValuesViewInfo and `property Values[Index]: TcxValueInfo ...
        // default` is what the brackets mean (a suite's filter control). The
        // pass-through below would open the COLLECTION instead, and the
        // damage is not a missing member but a WRONG binding: the collection
        // has a member named `Values` too, so the body's `Values.Separator`
        // bound to the element and lost Separator, with no diagnostic
        // anywhere near the cause. Tried before the pass-through, which
        // exists for the case where the base designator IS the array
        // property (its declared type is already per-element).
        // ...but ONLY when the base is not itself an array property, whose
        // stored type is per-element already — peeling a second level there
        // is how `with TaviFileList.Singleton.Files[Hospital_file] do` lost
        // its whole body (2447 reports on one project, from one `.inc`).
        if (Result = NIL_SYM) and
           not IsArrayPropDesignator(FirstChild(ANode)) then
          Result := DefaultArrayPropTypeSym(
            WithTargetTypeSym(FirstChild(ANode)));
        if Result = NIL_SYM then
          Result := WithTargetTypeSym(FirstChild(ANode));
      end;
    nkBinaryOp:
      // `with Obj as TSomething do` (System.Net.Socket) — the CAST's type, i.e.
      // the right operand. Only `as` qualifies; every other binary operator
      // yields a value whose type is not a with-openable struct anyway.
      //
      // Aux on nkBinaryOp is a TOKEN index, so it must be read through
      // Source.VisibleText — NOT NodeText, which takes a NODE index. Token
      // indices run well past the node count, so passing one to NodeText read
      // memory past the end of Nodes: garbage without range checks (this
      // comparison then usually said False, silently losing the cast, and the
      // junk it read varied per run — that was the source of the analyzer's
      // run-to-run non-determinism), ERangeError with them (whole unit
      // discarded as unparseable, reported as a missing unit). Every other
      // reader of Aux in the codebase already uses VisibleText.
      if (FTree.Nodes[ANode].Aux >= 0) and
         (FTree.Nodes[ANode].Aux <= High(FTree.Source.Visible)) and
         SameText(FTree.Source.VisibleText(FTree.Nodes[ANode].Aux), 'as') then
      begin
        LBase := FirstChild(ANode);
        if LBase <> NIL_NODE then
        begin
          LName := NextSib(LBase);
          if LName <> NIL_NODE then
          begin
            LHead := DesignatorHead(LName);
            if (LHead <> NIL_SYM) and
               (FModel.Symbols[LHead].Kind in [skType, skBuiltinType]) then
              Result := LHead;
          end;
        end;
      end;
    nkDeref:
      // `with SomePointer^ do` — the target's type is what the pointer POINTS
      // AT (System.Variants: `with LVarData^ do VType := ...`, LVarData being
      // a PVarData). Without this the whole with-body stayed unresolved.
      Result := PointeeTypeSym(WithTargetTypeSym(FirstChild(ANode)));
    nkParen:
      Result := WithTargetTypeSym(FirstChild(ANode));
  end;
end;

{ The ELEMENT type of an indexable designator, or NIL_SYM when it is not an
  array at all (which the caller reads as "leave the type alone").

  Two sources, because an array is often not a named type: the base's own
  declared type NODE may BE an inline `array[...] of T` (`LVarBounds:
  array[0..3] of TVarBound;`), which no symbol lookup can reach — nothing
  resolves an nkArrayType expression to a symbol. So try the declared node
  first, then the named type it resolves to. Alias links are chased in both
  (TArr = TInner = array of T), depth-capped like PointeeTypeSym. }
function TPasSemaResolver.ElementTypeOf(ABaseNode: Integer): Integer;

  // Element child of an nkArrayType node: the LAST child (`array[dims] of T`).
  // NB for a multi-dimensional `array[a, b] of T` this jumps straight to T
  // rather than to the intermediate row type — over-eager by one level in a
  // shape too rare to model, and it can only ever find members of T instead
  // of failing.
  function ElemOfArrayNode(ANode: Integer): Integer;
  var
    LChild, LLast: Integer;
  begin
    Result := NIL_SYM;
    if (ANode = NIL_NODE) or (KindOf(ANode) <> nkArrayType) or
       (FTree.Nodes[ANode].Aux = 1) then
      Exit;   // Aux = 1: `array of const`, no element type node at all
    LChild := FirstChild(ANode);
    LLast := NIL_NODE;
    while LChild <> NIL_NODE do
    begin
      LLast := LChild;
      LChild := NextSib(LChild);
    end;
    // NESTED inline arrays (`array of array of T`) — descend to the innermost
    // element. Same accepted over-eagerness as the comma-dimension spelling
    // documented above, and the intermediate row type is anonymous anyway.
    while (LLast <> NIL_NODE) and (KindOf(LLast) = nkArrayType) and
          (FTree.Nodes[LLast].Aux <> 1) do
    begin
      LChild := FirstChild(LLast);
      LLast := NIL_NODE;
      while LChild <> NIL_NODE do
      begin
        LLast := LChild;
        LChild := NextSib(LChild);
      end;
    end;
    // An ANONYMOUS element type (`array[...] of record ... end`) is a struct
    // NODE, not a designator, so DesignatorHead has nothing to read. Its
    // synthetic symbol is reachable through the member scope CollectStruct
    // hung off that node — see DeclareAnonStruct.
    if (LLast <> NIL_NODE) and (KindOf(LLast) in [nkRecordType, nkClassType,
       nkInterfaceType, nkObjectType]) then
    begin
      if (LLast <= High(FNodeScope)) and (FNodeScope[LLast] <> NIL_SCOPE) then
        Result := FModel.Scopes[FNodeScope[LLast]].StructSym;
      Exit;
    end;
    Result := DesignatorHead(LLast);
  end;

var
  LSym, LDef, LDepth: Integer;
begin
  // 1. The base designator's own declared type node (inline array case).
  LSym := DesignatorHead(ABaseNode);
  if (LSym <> NIL_SYM) and (FModel.Symbols[LSym].TypeNode <> NIL_NODE) then
  begin
    Result := ElemOfArrayNode(FModel.Symbols[LSym].TypeNode);
    if Result <> NIL_SYM then
      Exit;
  end;
  // 2. The named type it resolves to, chasing aliases to a definition.
  LSym := WithTargetTypeSym(ABaseNode);
  for LDepth := 1 to 32 do
  begin
    if (LSym = NIL_SYM) or (FModel.Symbols[LSym].DeclNode = NIL_NODE) then
      Exit(NIL_SYM);
    LDef := NextSib(FModel.Symbols[LSym].DeclNode);
    while (LDef <> NIL_NODE) and (KindOf(LDef) = nkGenericParams) do
      LDef := NextSib(LDef);
    if LDef = NIL_NODE then
      Exit(NIL_SYM);
    case KindOf(LDef) of
      nkArrayType:
        Exit(ElemOfArrayNode(LDef));
      nkIdent, nkMember, nkTypeArgs:
        LSym := DesignatorHead(LDef);   // alias link — keep chasing
    else
      Exit(NIL_SYM);                    // not an array, and never will be
    end;
  end;
  Result := NIL_SYM;
end;

// The type a POINTER type points at: PVarData = ^TVarData -> TVarData,
// chasing through however many alias links sit in between (PFoo = PVarData),
// exactly like StructMemberScope does for member scopes. Depth-capped for the
// same reason — real chains are shallow, this only guards a malformed or
// circular one. NIL_SYM when ATypeSym is not a pointer type at all.
function TPasSemaResolver.PointeeTypeSym(ATypeSym: Integer): Integer;
var
  LSym, LDef, LDepth: Integer;
begin
  Result := NIL_SYM;
  LSym := ATypeSym;
  for LDepth := 1 to 32 do
  begin
    if (LSym = NIL_SYM) or (FModel.Symbols[LSym].DeclNode = NIL_NODE) then
      Exit;
    LDef := NextSib(FModel.Symbols[LSym].DeclNode);
    while (LDef <> NIL_NODE) and (KindOf(LDef) = nkGenericParams) do
      LDef := NextSib(LDef);
    if LDef = NIL_NODE then
      Exit;
    case KindOf(LDef) of
      nkPointerType:
        Exit(DesignatorHead(FirstChild(LDef)));
      nkIdent, nkMember, nkTypeArgs:
        LSym := DesignatorHead(LDef);   // alias link — keep chasing
    else
      Exit;                             // not a pointer, and never will be
    end;
  end;
end;

// Retroactively routes ANode's name resolution — and, transitively, every
// descendant that does NOT open its own scope — through ANewScope instead of
// whatever Collect originally assigned. A descendant that DOES own a scope
// (block, nested `with`, anon method, ...) only needs THAT scope's own
// Parent link reparented; everything beneath it already resolves relative to
// that scope's chain, so recursion stops there — one link fixes the whole
// subtree. Used to splice a with-target's member scope into an
// already-Collected body (see ResolveOneWithStmt).
procedure TPasSemaResolver.RepointScope(ANode, ANewScope: Integer);
var
  LChild, LOwnScope: Integer;
begin
  if ANode = NIL_NODE then
    Exit;
  LOwnScope := FNodeScope[ANode];
  if (LOwnScope <> NIL_SCOPE) and
     (FModel.Scopes[LOwnScope].OwnerNode = ANode) then
  begin
    FModel.Scopes[LOwnScope].Parent := ANewScope;
    Exit;
  end;
  FNodeScope[ANode] := ANewScope;
  LChild := FirstChild(ANode);
  while LChild <> NIL_NODE do
  begin
    RepointScope(LChild, ANewScope);
    LChild := NextSib(LChild);
  end;
end;

{ Unbinds every body name that the with scope ALSO offers, so ResolveNode's
  "only fill NIL_SYM" rule cannot leave a Phase-1 guess standing in front of a
  member. 5.7: a target member outranks EVERYTHING — dcc-verified against a
  local, a parameter, a unit-level global and an inline `var` declared inside
  the body itself.

  Without this the override only ever happened for targets this pass could NOT
  open (WithUnopened, revised later by the project's with pass); a target whose
  type IS same-unit resolvable opened its scope and then quietly kept the older
  binding. `with R do Shared := 'x'` with a local `Shared: Integer` in scope
  was a false E2010 — the shape the 5.7 bullet describes, and the one the RTL
  corpus happens never to contain.

  Skips the two node classes that are not bare references: a DECLARATION's own
  name (an inline `var Shared` in the body still declares Shared — only its USES
  bind to the member, which is exactly why dcc rejects that program), and the
  member name of `A.B`, which is resolved through A. }
procedure TPasSemaResolver.UnbindShadowedByWith(ANode, AWithScope: Integer);
var
  LChild, LParent: Integer;
begin
  if ANode = NIL_NODE then
    Exit;
  if (KindOf(ANode) = nkIdent) and not FIsDeclName[ANode] and
     (FModel.RefMap[ANode] <> NIL_SYM) then
  begin
    LParent := FTree.Nodes[ANode].Parent;
    if (LParent = NIL_NODE) or (KindOf(LParent) <> nkMember) or
       (FirstChild(LParent) = ANode) then
      if FModel.FindLocalDeep(AWithScope, NodeNameLower(ANode)) <> NIL_SYM then
        FModel.RefMap[ANode] := NIL_SYM;
  end;
  LChild := FirstChild(ANode);
  while LChild <> NIL_NODE do
  begin
    UnbindShadowedByWith(LChild, AWithScope);
    LChild := NextSib(LChild);
  end;
end;

procedure TPasSemaResolver.ResolveOneWithStmt(AWith: Integer);
var
  LTarget, LBody, LWithScope, LTypeSym: Integer;
  LTargets: TArray<Integer>;
  LAnyUnopened: Boolean;
begin
  // Children: target1, target2, ..., targetN, body (body = last child;
  // TPasParser.ParseStatement's tkWith case, 5.7).
  LTargets := nil;
  LTarget := FirstChild(AWith);
  while (LTarget <> NIL_NODE) and (NextSib(LTarget) <> NIL_NODE) do
  begin
    LTargets := LTargets + [LTarget];
    LTarget := NextSib(LTarget);
  end;
  LBody := LTarget;
  if (LBody = NIL_NODE) or (Length(LTargets) = 0) then
    Exit;

  // One scope per with-statement. Every resolved target's members are
  // JOINED in LEFT-TO-RIGHT source order — Resolve()'s existing
  // Additional-scope walk already checks the MOST-RECENTLY-JOINED one first
  // ("uses/with priority", see TPasSemaModel.Resolve), which is exactly the
  // spec's right-to-left, last-target-wins precedence, for free. Each
  // target's OWN same-unit ancestor chain (see AncestorTypeSym) is ALSO
  // joined, root-most first / leaf last, so an inherited member is visible
  // too, and the type's OWN member of the same name still correctly shadows
  // it (its scope ends up "most recently added", checked first).
  LWithScope := NIL_SCOPE;
  LAnyUnopened := False;
  for LTarget in LTargets do
  begin
    // A target after the first is resolved INSIDE the ones before it — that is
    // the whole point of the multi-target form: `with DIB, dsbm, dsbmih do`
    // works because dsbm is a field of DIB and dsbmih a field of dsbm
    // (Vcl.Graphics does exactly this, and Vcl.Controls does
    // `with TDragDockObject(ADragObject), FDockRect do`). Resolving every
    // target in the ENCLOSING scope left the later ones unbound, and with them
    // every member of theirs in the body.
    //
    // Safe to do incrementally: the scope only ever GAINS the targets already
    // processed, and ResolveNode's NIL_SYM guard means a target Phase 1 already
    // bound correctly is left alone.
    if LWithScope <> NIL_SCOPE then
    begin
      RepointScope(LTarget, LWithScope);
      ResolveNode(LTarget);
    end;
    LTypeSym := WithTargetTypeSym(LTarget);
    if LTypeSym = NIL_SYM then
    begin
      LAnyUnopened := True;   // type not nameable intra-unit (usually: another unit)
      Continue;
    end;
    var LChain: TArray<Integer> := nil;
    var LChainDepth := 0;
    while (LTypeSym <> NIL_SYM) and (LChainDepth < 32) do
    begin
      Inc(LChainDepth);
      if FModel.Symbols[LTypeSym].MemberScope <> NIL_SCOPE then
        LChain := LChain + [LTypeSym];
      LTypeSym := AncestorTypeSym(LTypeSym);
    end;
    if Length(LChain) = 0 then
    begin
      LAnyUnopened := True;   // named a type, but its members live elsewhere
      Continue;
    end;
    if LWithScope = NIL_SCOPE then
      LWithScope := FModel.AddScope(sckWith, FNodeScope[AWith], AWith);
    for var LI := High(LChain) downto 0 do
      FModel.JoinScope(LWithScope, FModel.Symbols[LChain[LI]].MemberScope);
  end;

  // A target this pass could not open leaves every Phase-1 binding in the body
  // TENTATIVE: one of that target's members may still shadow whatever the name
  // bound to instead (5.7 — and a with member outranks EVERYTHING, verified
  // against a class field, local, parameter, same-unit global and even an
  // inline var declared inside the body). Recorded so the typer withholds
  // judgement here and the project's with pass can revise the binding.
  if LAnyUnopened then
    FModel.WithUnopened := FModel.WithUnopened + [AWith];

  if LWithScope = NIL_SCOPE then
    Exit;   // no target resolved to a real, member-bearing type — leave as-is

  UnbindShadowedByWith(LBody, LWithScope);
  RepointScope(LBody, LWithScope);
  ResolveNode(LBody);
end;

procedure TPasSemaResolver.ResolveWithStmts;
var
  LIdx: Integer;
begin
  // A flat forward scan over all nodes visits an OUTER with-statement before
  // any with NESTED in its body (node indices are assigned in parse order,
  // depth-first) — required for correctness: ResolveOneWithStmt's
  // RepointScope+ResolveNode(LBody) call for the outer one also re-resolves
  // the INNER with's own target expressions (ResolveNode recurses into
  // every child generically; nkWithStmt has no special case there), so by
  // the time this scan reaches the inner with, ITS targets are already
  // correctly resolved through the outer's scope.
  for LIdx := 0 to High(FTree.Nodes) do
    if KindOf(LIdx) = nkWithStmt then
      ResolveOneWithStmt(LIdx);
end;

function TPasSemaResolver.QualifiedNameText(ANode: Integer): string;
var
  LBase, LName: Integer;
begin
  if ANode = NIL_NODE then
    Exit('');
  case KindOf(ANode) of
    nkMember:
      begin
        LBase := FirstChild(ANode);
        LName := NextSib(LBase);
        Result := QualifiedNameText(LBase) + '.' + NodeText(LName);
      end;
  else
    Result := NodeText(ANode);
  end;
end;

procedure TPasSemaResolver.CollectRoot(ARoot: Integer);
var
  LChild, LNameNode: Integer;
begin
  FNodeScope[ARoot] := FImpl;
  // First child is the compilation unit's own name — a definition, not a
  // reference. Record it and leave it without a scope so no pass resolves it.
  LNameNode := FirstChild(ARoot);
  if (LNameNode <> NIL_NODE) and (KindOf(LNameNode) in [nkIdent, nkMember]) then
  begin
    FModel.UnitNameLower := LowerCase(QualifiedNameText(LNameNode));
    FIsDeclName[LNameNode] := True;
  end
  else
    LNameNode := NIL_NODE;

  LChild := FirstChild(ARoot);
  while LChild <> NIL_NODE do
  begin
    if LChild <> LNameNode then
      case KindOf(LChild) of
        nkInterfaceSec:
          Collect(LChild, FIntf);
        nkImplementationSec:
          Collect(LChild, FImpl);
      else
        Collect(LChild, FImpl);   // uses / decls / init / finalization / block
      end;
    LChild := NextSib(LChild);
  end;
end;

{ 5.5.1: the counter of a `for` loop is read-only in the body — dcc reports
  `E2081 Assignment to FOR-Loop variable 'X'`. Three shapes, all dcc-verified
  and all reported: a direct `I := ...`, a var-param mutation (`Inc(I)`,
  `Dec(I)`), and the same two against an inline `for var K` counter.

  Runs after ResolveNode because it works on BINDINGS, not names: the point is
  that the assignment target is the same SYMBOL the header declared or named,
  which is what makes a shadowed name in a nested scope not a false hit.

  Intra-unit by construction — a for counter is a local or an inline
  declaration, never reachable from another unit — so this needs none of the
  cross-unit machinery and cannot be gated on AllUsesResolved. }
procedure TPasSemaResolver.CheckForCounters;
var
  // Indexed by node, not a list: the test is per-node and this is a walk over
  // every node in the unit.
  LFlagged: TArray<Boolean>;
  LIdx, LSym, LBody, LChild: Integer;

  // The symbol the loop header's counter denotes: a declaration for the
  // `for var K` form, an ordinary reference otherwise.
  function CounterSym(AFor: Integer): Integer;
  var
    LFirst, LName: Integer;
  begin
    Result := NIL_SYM;
    LFirst := FirstChild(AFor);
    if LFirst = NIL_NODE then
      Exit;
    if KindOf(LFirst) = nkInlineVar then
    begin
      LName := FirstChild(LFirst);
      if (LName <> NIL_NODE) and (KindOf(LName) = nkIdent) then
        Result := FModel.RefMap[LName];
    end
    else if KindOf(LFirst) = nkIdent then
      Result := FModel.RefMap[LFirst];
  end;

  procedure Flag(ANode: Integer; const AName: string);
  var
    LFileId, LLine, LCol: Integer;
  begin
    // One report per offending node: nested loops mean the same assignment is
    // reached by more than one enclosing walk, and dcc reports it once.
    if LFlagged[ANode] then
      Exit;
    LFlagged[ANode] := True;
    NodePos(ANode, LFileId, LLine, LCol);
    FModel.AddDiag(MakeDiag('E2081',
      Format(SE2081_AssignToForLoopVar, [AName]), ANode, LFileId, LLine, LCol));
  end;

  // Walks a loop BODY looking for writes to ACounter.
  procedure Scan(ANode, ACounter: Integer; const AName: string);
  var
    LChild, LTarget, LCallee, LArg: Integer;
  begin
    if ANode = NIL_NODE then
      Exit;
    case KindOf(ANode) of
      nkAssign:
        begin
          LTarget := FirstChild(ANode);
          if (LTarget <> NIL_NODE) and (KindOf(LTarget) = nkIdent) and
             (FModel.RefMap[LTarget] = ACounter) then
            Flag(LTarget, AName);
        end;
      nkCall:
        begin
          // Inc/Dec take their first argument by reference (4.11), so they
          // mutate the counter exactly as an assignment does. Matched by NAME
          // rather than by symbol: both are compiler intrinsics with no
          // declaration to point at, and a user routine that shadows either
          // name would not be an intrinsic call at all — but it would also
          // have to take a var parameter to matter, which is a precision this
          // check does not claim.
          LCallee := FirstChild(ANode);
          if (LCallee <> NIL_NODE) and (KindOf(LCallee) = nkIdent) and
             (SameText(NodeText(LCallee), 'Inc') or
              SameText(NodeText(LCallee), 'Dec')) then
          begin
            LArg := NextSib(LCallee);
            if (LArg <> NIL_NODE) and (KindOf(LArg) = nkIdent) and
               (FModel.RefMap[LArg] = ACounter) then
              Flag(LArg, AName);
          end;
        end;
    end;
    LChild := FirstChild(ANode);
    while LChild <> NIL_NODE do
    begin
      Scan(LChild, ACounter, AName);
      LChild := NextSib(LChild);
    end;
  end;

begin
  SetLength(LFlagged, Length(FTree.Nodes));
  for LIdx := 0 to High(FTree.Nodes) do
  begin
    if not (KindOf(LIdx) in [nkForStmt, nkForInStmt]) then
      Continue;
    LSym := CounterSym(LIdx);
    if LSym = NIL_SYM then
      Continue;
    // The body is the LAST child: counter, bounds/collection, then the
    // statement. Scanning only it keeps the header's own `I := 1` out.
    LBody := NIL_NODE;
    LChild := FirstChild(LIdx);
    while LChild <> NIL_NODE do
    begin
      LBody := LChild;
      LChild := NextSib(LChild);
    end;
    Scan(LBody, LSym, FModel.Symbols[LSym].Name);
  end;
end;

{ 18 §18.3.1: a bare `raise` re-raises the in-flight exception and is only
  valid inside an exception handler — dcc reports `E2145 Re-raising an
  exception only allowed in exception handler`.

  The spec says "the analyzer must track handler context" without saying what
  that context is, so dcc32 37.0 was asked. It is purely LEXICAL, and the part
  of a `try` statement the `raise` sits in is what decides — the NEAREST one,
  not any enclosing one:

    try except try finally raise end end   error  (nearest part is `finally`)
    try finally try except raise end end   legal  (nearest part is `except`)
    try except try raise except end end    error  (nearest part is a try body)
    try try except raise end finally end   legal

  So a `finally` or a `try` body RESETS the context that an enclosing handler
  established. An anonymous method body does NOT — `raise` inside a
  `procedure begin ... end` written in a handler is accepted, which makes the
  boundary the try-statement part and nothing else. A named nested routine
  needs no rule of its own: its body is never lexically inside a statement, so
  the walk reaches it with no part in effect and rejects, exactly as dcc does.

  All eight shapes above plus the `on ... do` and `else` branches are pinned in
  SemaSmoke, and the probe's output matches dcc line for line.

  Structural, like CheckForCounters, but unlike it needs no bindings at all —
  it runs on the tree alone. }
procedure TPasSemaResolver.CheckBareRaises;

  procedure Walk(ANode: Integer; AInHandler: Boolean);
  var
    LChild, LPart: Integer;
    LFileId, LLine, LCol: Integer;
  begin
    case KindOf(ANode) of
      nkRaiseStmt:
        // No children = bare (an operand, and its optional `at` address, are
        // the children the parser adds).
        if (FirstChild(ANode) = NIL_NODE) and not AInHandler then
        begin
          NodePos(ANode, LFileId, LLine, LCol);
          FModel.AddDiag(MakeDiag('E2145', SE2145_ReRaiseOutsideHandler,
            ANode, LFileId, LLine, LCol));
          Exit;
        end;
      nkTryStmt:
        begin
          // Children: the guarded block, then exactly one part. The block is
          // walked with the context CLEARED whichever part follows it.
          LChild := FirstChild(ANode);
          if LChild = NIL_NODE then
            Exit;
          Walk(LChild, False);
          LPart := NextSib(LChild);
          while LPart <> NIL_NODE do
          begin
            LChild := FirstChild(LPart);
            while LChild <> NIL_NODE do
            begin
              Walk(LChild, KindOf(LPart) = nkExceptPart);
              LChild := NextSib(LChild);
            end;
            LPart := NextSib(LPart);
          end;
          Exit;
        end;
    end;
    LChild := FirstChild(ANode);
    while LChild <> NIL_NODE do
    begin
      Walk(LChild, AInHandler);
      LChild := NextSib(LChild);
    end;
  end;

begin
  Walk(0, False);
end;

{ 4 §4.11: `Slice(A, Count)` is valid only as an actual argument to an open-array
  parameter — dcc reports `E2193 Slice standard function only allowed as open
  array argument` anywhere else.

  dcc32 37.0 turned out to be STRICTER than the spec's wording, and in a way
  that decides how much of the rule is checkable here: an argument of a
  COMPILER INTRINSIC is never a valid position, even when that intrinsic's
  parameter really is an open array. `Insert(const Values: array of T; var
  Dest; Index)` is the strongest case and it is rejected, as are `Concat` and
  `Writeln` — so "open-array argument" means an argument of an ordinary call,
  and Slice's own arguments are excluded too (Slice is itself an intrinsic).

  What this reports, therefore, is every Slice call that is not an argument of a
  non-intrinsic call: an assignment RHS, a statement, an index base, an operand,
  an element of an array constructor, an argument of any intrinsic. All are
  dcc-verified.

  What it deliberately does NOT report is a Slice passed to an ordinary routine
  whose parameter at that position is NOT an open array (`TakesInt(Slice(A,3))`,
  `TakesDynArray(Slice(A,3))` — both E2193 under dcc). Deciding that needs the
  parameter of the SELECTED overload for a given argument index, which nothing
  here computes; CheckCalls only measures arity, and across units it bails on
  any candidate without param info. Claiming it from a single unbound guess is
  how a check like this acquires false positives, so the gap is left open and
  named rather than approximated.

  Needs RefMap, and only for the identity test: `Slice` is the seeded intrinsic
  (`sfBuiltin`) and not a user routine of that name, which would resolve
  elsewhere and be an ordinary call. }
procedure TPasSemaResolver.CheckSlicePositions;

  // Is ANode a call to the INTRINSIC of that name (not a same-named routine)?
  function IsIntrinsicCall(ANode: Integer; const ANameLower: string): Boolean;
  var
    LCallee, LSym: Integer;
  begin
    Result := False;
    if KindOf(ANode) <> nkCall then
      Exit;
    LCallee := FirstChild(ANode);
    if (LCallee = NIL_NODE) or (KindOf(LCallee) <> nkIdent) then
      Exit;
    LSym := FModel.RefMap[LCallee];
    if LSym = NIL_SYM then
      Exit;
    Result := (sfBuiltin in FModel.Symbols[LSym].Flags) and
      ((ANameLower = '') or (FModel.Symbols[LSym].NameLower = ANameLower));
  end;

  { Does argument AIndex of ACall land on an OPEN-ARRAY parameter? True also
    when the answer cannot be established, so that only a certain "no" reports.

    Certainty here means a single candidate: the callee is a plain name bound to
    a routine symbol with NO further overload and with its parameters visible in
    this unit. That deliberately skips overload sets rather than ranking them —
    picking the wrong candidate would invent a diagnostic, and `Slice` is rare
    enough that the precision is not worth the risk. Everything cross-unit
    (params in another model), every method call through a qualifier, and every
    call through a procedural variable also fall through to True. }
  function ParamTakesSlice(ACall, AIndex: Integer): Boolean;
  var
    LCallee, LSym, LScope, LParam, LSeen, LType: Integer;
  begin
    Result := True;
    LCallee := FirstChild(ACall);
    if (LCallee = NIL_NODE) or (KindOf(LCallee) <> nkIdent) then
      Exit;
    LSym := FModel.RefMap[LCallee];
    if (LSym = NIL_SYM) or (FModel.Symbols[LSym].Kind <> skRoutine) or
       (FModel.Symbols[LSym].NextOverload <> NIL_SYM) then
      Exit;
    LScope := FModel.Symbols[LSym].MemberScope;
    if (LScope = NIL_SCOPE) or (FModel.Scopes[LScope].Symbols = nil) then
      Exit;   // a builtin, or params not recorded
    LSeen := 0;
    for LParam in FModel.Scopes[LScope].Symbols do
    begin
      if FModel.Symbols[LParam].Kind <> skParam then
        Continue;
      if LSeen = AIndex then
      begin
        // `array of T` written in a parameter is an OPEN array: an nkArrayType
        // with no dimension children, the single child being the element type.
        // `array of const` (Aux = 1) has none at all and is one too.
        LType := FModel.Symbols[LParam].TypeNode;
        if (LType = NIL_NODE) or (KindOf(LType) <> nkArrayType) then
          Exit(False);
        if FTree.Nodes[LType].Aux = 1 then
          Exit(True);
        Result := (FirstChild(LType) <> NIL_NODE) and
          (NextSib(FirstChild(LType)) = NIL_NODE);
        Exit;
      end;
      Inc(LSeen);
    end;
    // Fewer parameters than arguments: an arity error, not this rule's.
  end;

  procedure Walk(ANode: Integer; ASliceOk: Boolean);
  var
    LChild, LCallee, LArgIdx: Integer;
    LFileId, LLine, LCol: Integer;
    LArgsOk: Boolean;
  begin
    if IsIntrinsicCall(ANode, 'slice') and not ASliceOk then
    begin
      // On the CALLEE, not the call: that is the `Slice` token, and it is where
      // dcc points.
      LCallee := FirstChild(ANode);
      NodePos(LCallee, LFileId, LLine, LCol);
      FModel.AddDiag(MakeDiag('E2193', SE2193_SliceOutsideOpenArray,
        LCallee, LFileId, LLine, LCol));
    end;
    LChild := FirstChild(ANode);
    if KindOf(ANode) = nkCall then
    begin
      // The callee is never an argument; the arguments are one only if this
      // call is an ordinary routine call.
      if LChild = NIL_NODE then
        Exit;
      LArgsOk := not IsIntrinsicCall(ANode, '');
      Walk(LChild, False);
      LChild := NextSib(LChild);
      LArgIdx := 0;
      while LChild <> NIL_NODE do
      begin
        Walk(LChild, LArgsOk and ParamTakesSlice(ANode, LArgIdx));
        Inc(LArgIdx);
        LChild := NextSib(LChild);
      end;
      Exit;
    end;
    while LChild <> NIL_NODE do
    begin
      Walk(LChild, False);
      LChild := NextSib(LChild);
    end;
  end;

begin
  Walk(0, False);
end;

procedure TPasSemaResolver.Run;
begin
  FSys := SeedSystemScope(FModel, FPlatform);
  FModel.SystemScope := FSys;
  FIntf := FModel.AddScope(sckUnit, NIL_SCOPE, 0);
  FModel.JoinScope(FIntf, FSys);            // implicit 'uses System'
  FImpl := FModel.AddScope(sckImplementation, FIntf, 0);
  FModel.InterfaceScope := FIntf;
  CollectRoot(0);
  JoinHelperScopes;   // must precede Resolve — see its own header
  ResolveNode(0);
  BindTypes;
  ResolveAggregates;  // needs BindTypes' declared types — see its own header
  ResolveWithStmts;   // needs BindTypes' declared types — see its own header
  CheckForCounters;   // needs RefMap — see its own header
  CheckBareRaises;    // structural only — see its own header
  CheckSlicePositions; // needs RefMap — see its own header
  if not FSkipTyper then
    // The platform reaches the typer for one rule only: a 64-bit ordinal
    // `set of` base is E2001 where a 32-bit one is E2028, and NativeInt is
    // whichever the target makes it.
    TPasSemaTyper.Check(FModel, FPlatform);
end;

end.
