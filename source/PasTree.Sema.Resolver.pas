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
  PasTree.Ast,
  PasTree.Sema.Model;

type
  TPasSemaResolver = class
  private
    FModel: TPasSemaModel;
    FTree: TPasTree;
    FSys: Integer;
    FIntf: Integer;   // interface scope (importable)
    FImpl: Integer;   // implementation scope (parent = FIntf)
    FNodeScope: TArray<Integer>;
    FIsDeclName: TArray<Boolean>;
    FSkipTyper: Boolean;   // see Analyze
    // tree helpers
    function KindOf(ANode: Integer): TPasNodeKind; inline;
    function FirstChild(ANode: Integer): Integer; inline;
    function NextSib(ANode: Integer): Integer; inline;
    function NodeText(ANode: Integer): string; inline;
    function SkipAttr(AChild: Integer): Integer;
    function IsAttributeTypeRef(ANode: Integer): Boolean;
    function EnumJoinTarget(AScope: Integer): Integer;
    function SepAfter(ANode: Integer): string;
    function QualifiedNameText(ANode: Integer): string;
    procedure CollectRoot(ARoot: Integer);
    function FindChildKind(ANode: Integer; AKind: TPasNodeKind): Integer;
    function CountImplParamNames(ARoutineNode: Integer): Integer;
    function RoutineParamNameCount(ASym: Integer): Integer;
    procedure NodePos(ANode: Integer; out AFileId, ALine, ACol: Integer);
    // collect
    procedure MarkDeclName(ANode, ASym: Integer);
    function DeclareSym(AScope: Integer; AKind: TSemaSymbolKind;
      const AName: string; ADeclNode: Integer): Integer;
    procedure DeclareNamesAndType(ADecl, AScope: Integer;
      AKind: TSemaSymbolKind);
    procedure CollectTypeDecl(ANode, AScope: Integer);
    procedure CollectStruct(ANode, AOuter, ATypeSym: Integer);
    procedure CollectEnum(ANode, AOuter, ATypeSym: Integer);
    procedure CollectUsesItem(AItem, AScope: Integer);
    procedure CollectRoutine(ANode, AScope: Integer);
    procedure Collect(ANode, AScope: Integer);
    // resolve
    function DesignatorHead(ANode: Integer): Integer;
    procedure ResolveNode(ANode: Integer);
    procedure BindTypes;
    // with (ch.05 §5.7) — see ResolveWithStmts for why this runs as its own
    // pass, after BindTypes, rather than inline in Collect/ResolveNode.
    function FindMemberUpChain(ATypeSym: Integer;
      const ANameLower: string): Integer;
    function AncestorTypeSym(ATypeSym: Integer): Integer;
    function WithTargetTypeSym(ANode: Integer): Integer;
    procedure RepointScope(ANode, ANewScope: Integer);
    procedure ResolveOneWithStmt(AWith: Integer);
    procedure ResolveWithStmts;
    procedure Run;
  public
    { ASkipTyper skips the final expression type-check (Phase 3a) — for
      TRANSIENT models only (the async parser's interface-only wave, whose
      models are replaced by fully-analyzed ones before anyone reads
      diagnostics or ExprType). Collect/Resolve/BindTypes still run, so
      scopes, symbols, RefMap and declared-type bindings — everything
      navigation and cross-unit resolution read — are complete. }
    class function Analyze(const ATree: TPasTree;
      ASkipTyper: Boolean = False): TPasSemaModel; static;
  end;

implementation

uses
  System.SysUtils,
  PasTree.Preprocessor,
  PasTree.Sema.Builtins,
  PasTree.Sema.Diagnostics,
  PasTree.Sema.Types;

class function TPasSemaResolver.Analyze(const ATree: TPasTree;
  ASkipTyper: Boolean = False): TPasSemaModel;
var
  LR: TPasSemaResolver;
begin
  LR := TPasSemaResolver.Create;
  try
    LR.FTree := ATree;
    LR.FSkipTyper := ASkipTyper;
    LR.FModel := TPasSemaModel.Create(ATree);
    SetLength(LR.FNodeScope, Length(ATree.Nodes));
    SetLength(LR.FIsDeclName, Length(ATree.Nodes));
    for var LIdx := 0 to High(LR.FNodeScope) do
      LR.FNodeScope[LIdx] := NIL_SCOPE;   // unvisited => no scope => resolves NIL
    LR.Run;
    LR.FModel.NodeScope := LR.FNodeScope;
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

function TPasSemaResolver.SkipAttr(AChild: Integer): Integer;
begin
  Result := AChild;
  if (Result <> NIL_NODE) and (KindOf(Result) = nkAttrGroup) then
    Result := NextSib(Result);
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

// Text of the visible token immediately after ANode's last token ('','','':'').
function TPasSemaResolver.SepAfter(ANode: Integer): string;
var
  LNext: Integer;
begin
  LNext := FTree.Nodes[ANode].LastToken + 1;
  if (LNext >= 0) and (LNext <= High(FTree.Source.Visible)) then
    Result := FTree.Source.VisibleText(LNext)
  else
    Result := '';
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
        if SepAfter(LChild) = ':' then
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
  if LScope = NIL_SCOPE then
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
  const AName: string; ADeclNode: Integer): Integer;
var
  LExisting, LTail, LFileId, LLine, LCol: Integer;
begin
  LExisting := FModel.FindLocal(AScope, LowerCase(AName));
  Result := FModel.AddSymbol(AScope, AKind, AName, ADeclNode);
  if LExisting = NIL_SYM then
    FModel.BindName(AScope, Result)
  else if (AKind = skRoutine) and (FModel.Symbols[LExisting].Kind = skRoutine) then
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
  LSep: string;
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
    LSep := SepAfter(LChild);
    LSyms := LSyms + [DeclareSym(AScope, AKind, NodeText(LChild), LChild)];
    if LSep = ':' then
    begin
      LType := NextSib(LChild);
      LDone := True;
    end
    else if LSep = ',' then
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
  // Collect the type expression and anything after it (init / default /
  // absolute) as nested content in this scope, so every node gets a scope.
  LChild := LType;
  while LChild <> NIL_NODE do
  begin
    Collect(LChild, AScope);
    LChild := NextSib(LChild);
  end;
end;

procedure TPasSemaResolver.CollectTypeDecl(ANode, AScope: Integer);
var
  LName, LChild, LSym, LExisting, LGen, LBody: Integer;
begin
  LName := SkipAttr(FirstChild(ANode));
  if (LName = NIL_NODE) or (KindOf(LName) <> nkIdent) then
    Exit;
  // Forward-declared types (`TFoo = class;`) complete later under the same
  // name — reuse the existing symbol rather than flagging a redeclaration.
  LExisting := FModel.FindLocal(AScope, LowerCase(NodeText(LName)));
  if (LExisting <> NIL_SYM) and (FModel.Symbols[LExisting].Kind = skType) then
  begin
    LSym := LExisting;
    MarkDeclName(LName, LSym);
    // The completing declaration supersedes the forward one (`TFoo = class;`):
    // DeclNode must reach the real definition so ancestor/generic-param walks
    // (TypeDefNode and the project's cross typer) see heritage and params.
    FModel.Symbols[LSym].DeclNode := LName;
  end
  else
    LSym := DeclareSym(AScope, skType, NodeText(LName), LName);

  // Generic type params live in a per-type scope so identical names (T, TKey…)
  // across different generic types don't collide in the unit scope.
  LBody := AScope;
  LGen := FindChildKind(ANode, nkGenericParams);
  if LGen <> NIL_NODE then
  begin
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
        Collect(LChild, LBody);  // alias target, array, pointer…
      end;
    LChild := NextSib(LChild);
  end;
end;

procedure TPasSemaResolver.CollectStruct(ANode, AOuter, ATypeSym: Integer);
var
  LMembers, LChild: Integer;
begin
  LMembers := FModel.AddScope(sckStruct, AOuter, ANode);
  FNodeScope[ANode] := LMembers;
  if ATypeSym <> NIL_SYM then
    FModel.Symbols[ATypeSym].MemberScope := LMembers;

  LChild := FirstChild(ANode);
  while LChild <> NIL_NODE do
  begin
    case KindOf(LChild) of
      // ancestor / implemented-interface references: resolve in the outer scope
      nkIdent, nkMember, nkTypeArgs:
        Collect(LChild, AOuter);
      nkGuid, nkVisibility:
        ; // no names
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
    LChild := NextSib(LChild);
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
  LSym := FModel.FindLocal(AScope, LowerCase(NodeText(LLeaf)));
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
  FModel.UsesList := FModel.UsesList + [LU];
end;

procedure TPasSemaResolver.CollectRoutine(ANode, AScope: Integer);
var
  LRoutine, LChild, LNameNode, LSegIdent, LSegLast: Integer;
  LRoutineSym, LResultNode: Integer;
  LQualified: Boolean;
  LQualIdents: TArray<Integer>;
begin
  LRoutine := FModel.AddScope(sckRoutine, AScope, ANode);
  FNodeScope[ANode] := AScope;
  LQualIdents := nil;
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
    while (LChild <> NIL_NODE) and
          (KindOf(LChild) in [nkGenericParams, nkTypeArgs]) do
    begin
      Collect(LChild, LRoutine);   // generic params -> routine scope; args refs
      LSegLast := LChild;
      LChild := NextSib(LChild);
    end;
    if SepAfter(LSegLast) = '.' then
    begin
      LQualified := True;          // qualifier segment; ident is a type ref
      LQualIdents := LQualIdents + [LSegIdent];  // full chain, outer -> inner
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
    for var LSeg in LQualIdents do
    begin
      var LCand: Integer;
      if LTy = NIL_SYM then
        LCand := FModel.Resolve(AScope, LowerCase(NodeText(LSeg)))
      else if FModel.Symbols[LTy].MemberScope <> NIL_SCOPE then
        LCand := FModel.FindLocal(FModel.Symbols[LTy].MemberScope,
          LowerCase(NodeText(LSeg)))
      else
        LCand := NIL_SYM;
      if (LCand = NIL_SYM) or (FModel.Symbols[LCand].Kind <> skType) then
      begin
        LTy := NIL_SYM;
        Break;
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
        LowerCase(NodeText(LNameNode)));
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
      var LIntfHead := FModel.FindLocal(FIntf, LowerCase(NodeText(LNameNode)));
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

    nkConstDecl:
      begin
        LName := SkipAttr(FirstChild(ANode));
        if (LName <> NIL_NODE) and (KindOf(LName) = nkIdent) then
        begin
          var LSym := DeclareSym(AScope, skConst, NodeText(LName), LName);
          var LNext := NextSib(LName);
          // optional ': Type' before '='
          if (LNext <> NIL_NODE) and (SepAfter(LName) = ':') then
            FModel.Symbols[LSym].TypeNode := LNext;
          while LNext <> NIL_NODE do
          begin
            Collect(LNext, AScope);
            LNext := NextSib(LNext);
          end;
        end;
      end;

    nkInlineVar, nkInlineConst:
      begin
        LName := FirstChild(ANode);
        if (LName <> NIL_NODE) and (KindOf(LName) = nkIdent) then
        begin
          var LKind := skVar;
          if KindOf(ANode) = nkInlineConst then
            LKind := skConst;
          var LSym := DeclareSym(AScope, LKind, NodeText(LName), LName);
          var LNext := NextSib(LName);
          if (LNext <> NIL_NODE) and (SepAfter(LName) = ':') then
            FModel.Symbols[LSym].TypeNode := LNext;
          while LNext <> NIL_NODE do
          begin
            Collect(LNext, AScope);
            LNext := NextSib(LNext);
          end;
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
        // `function IEnumerable<string>.GetEnumerator = Impl;` — the <...>
        // segment is a type ARGUMENT of the implemented interface reference,
        // NOT generic parameter declarations (unlike a qualified method
        // implementation header). Walk idents as plain references only.
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
          else
            Collect(LChild, AScope);
          LChild := NextSib(LChild);
        end;
      end;

    nkRecordType, nkClassType, nkInterfaceType, nkObjectType, nkHelperType:
      CollectStruct(ANode, AScope, NIL_SYM);

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
        FModel.RefMap[ANode] :=
          FModel.Resolve(FNodeScope[ANode], LowerCase(NodeText(ANode)));
        if (FModel.RefMap[ANode] = NIL_SYM) and IsAttributeTypeRef(ANode) then
          FModel.RefMap[ANode] := FModel.Resolve(FNodeScope[ANode],
            LowerCase(NodeText(ANode)) + 'attribute');
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
          if LMemScope <> NIL_SCOPE then
            FModel.RefMap[LName] :=
              FModel.FindLocal(LMemScope, LowerCase(NodeText(LName)));
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
function TPasSemaResolver.WithTargetTypeSym(ANode: Integer): Integer;
var
  LBase, LName, LHead, LBaseType: Integer;
begin
  Result := NIL_SYM;
  case KindOf(ANode) of
    nkIdent:
      begin
        LHead := FModel.RefMap[ANode];
        if LHead = NIL_SYM then
          Exit;
        case FModel.Symbols[LHead].Kind of
          skVar, skConst, skField, skParam, skRoutine, skProperty:
            Result := FModel.Symbols[LHead].TypeSym;
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
          LHead := FindMemberUpChain(LBaseType, LowerCase(NodeText(LName)));
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
      // Obj[Idx] / Obj.ArrayProp[Idx]: this model already stores an array
      // PROPERTY's declared type as its per-ELEMENT type (see
      // CollectStruct's nkPropertyDecl handling — the property symbol's
      // TypeSym is the element type, not "array of X"), so indexing doesn't
      // change the type at all — just resolve the indexable head the same
      // way. (A plain dynamic-array VARIABLE's element type isn't modeled
      // this way — DesignatorHead can't resolve an nkArrayType expression to
      // a symbol at all — so that shape gracefully falls out as NIL_SYM,
      // same as any other with-target this function can't fully type.)
      Result := WithTargetTypeSym(FirstChild(ANode));
    nkParen:
      Result := WithTargetTypeSym(FirstChild(ANode));
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

procedure TPasSemaResolver.ResolveOneWithStmt(AWith: Integer);
var
  LTarget, LBody, LWithScope, LTypeSym: Integer;
  LTargets: TArray<Integer>;
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
  for LTarget in LTargets do
  begin
    LTypeSym := WithTargetTypeSym(LTarget);
    if LTypeSym = NIL_SYM then
      Continue;
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
      Continue;
    if LWithScope = NIL_SCOPE then
      LWithScope := FModel.AddScope(sckWith, FNodeScope[AWith], AWith);
    for var LI := High(LChain) downto 0 do
      FModel.JoinScope(LWithScope, FModel.Symbols[LChain[LI]].MemberScope);
  end;
  if LWithScope = NIL_SCOPE then
    Exit;   // no target resolved to a real, member-bearing type — leave as-is

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

procedure TPasSemaResolver.Run;
begin
  FSys := SeedSystemScope(FModel);
  FIntf := FModel.AddScope(sckUnit, NIL_SCOPE, 0);
  FModel.JoinScope(FIntf, FSys);            // implicit 'uses System'
  FImpl := FModel.AddScope(sckImplementation, FIntf, 0);
  FModel.InterfaceScope := FIntf;
  CollectRoot(0);
  ResolveNode(0);
  BindTypes;
  ResolveWithStmts;   // needs BindTypes' declared types — see its own header
  if not FSkipTyper then
    TPasSemaTyper.Check(FModel);
end;

end.
