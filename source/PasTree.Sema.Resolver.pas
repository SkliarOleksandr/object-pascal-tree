unit PasTree.Sema.Resolver;

{
  PasTree semantics — Phase 1 resolver (per unit).

  Two sub-passes over the immutable CST:
    1. Collect  — open scopes (unit / struct / routine / with / block), add a
                  symbol for every declaration, chain routine overloads, and
                  flag same-scope duplicates (E2004).
    2. Resolve  — bind each identifier/member reference to a symbol via the
                  scope chain, and bind each declaration's declared type to a
                  type symbol. Unresolved refs (e.g. names from a not-yet-indexed
                  used unit) are left NIL and flagged sfExternalUnresolved — no
                  diagnostic in Phase 1.

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
    // tree helpers
    function KindOf(ANode: Integer): TPasNodeKind; inline;
    function FirstChild(ANode: Integer): Integer; inline;
    function NextSib(ANode: Integer): Integer; inline;
    function NodeText(ANode: Integer): string; inline;
    function SkipAttr(AChild: Integer): Integer;
    function SepAfter(ANode: Integer): string;
    function QualifiedNameText(ANode: Integer): string;
    procedure CollectRoot(ARoot: Integer);
    function FindChildKind(ANode: Integer; AKind: TPasNodeKind): Integer;
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
    procedure Run;
  public
    class function Analyze(const ATree: TPasTree): TPasSemaModel; static;
  end;

implementation

uses
  System.SysUtils,
  PasTree.Preprocessor,
  PasTree.Sema.Builtins,
  PasTree.Sema.Diagnostics;

class function TPasSemaResolver.Analyze(const ATree: TPasTree): TPasSemaModel;
var
  LR: TPasSemaResolver;
begin
  LR := TPasSemaResolver.Create;
  try
    LR.FTree := ATree;
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
          if (LN <> NIL_NODE) and (KindOf(LN) = nkIdent) then
            DeclareSym(LMembers, skProperty, NodeText(LN), LN);
          var LC := NextSib(LN);
          while LC <> NIL_NODE do
          begin
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

procedure TPasSemaResolver.CollectEnum(ANode, AOuter, ATypeSym: Integer);
var
  LEnum, LChild, LName, LVal: Integer;
begin
  // Each enum gets its own scope, so values of different enums never share a
  // scope (no false redeclaration). The scope is also joined into the enclosing
  // one so unqualified values resolve (non-scoped enums); qualified access
  // (Enum.Value) works via the type symbol's member scope.
  LEnum := FModel.AddScope(sckEnum, AOuter, ANode);
  FNodeScope[ANode] := LEnum;
  if ATypeSym <> NIL_SYM then
    FModel.Symbols[ATypeSym].MemberScope := LEnum;
  FModel.JoinScope(AOuter, LEnum);
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
  LRoutine, LChild, LNameNode, LSegIdent, LSegLast, LQualIdent: Integer;
  LQualified: Boolean;
begin
  LRoutine := FModel.AddScope(sckRoutine, AScope, ANode);
  FNodeScope[ANode] := AScope;
  LQualIdent := NIL_NODE;

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
      LQualified := True;          // qualifier segment; ident is a type/unit ref
      LQualIdent := LSegIdent;     // remember the (last) qualifier = the type
    end
    else
    begin
      LNameNode := LSegIdent;      // routine name; remaining children follow
      Break;
    end;
  end;

  // For a method implementation (TFoo.Bar), make the routine body see the
  // struct's members (implicit Self) by joining the type's member scope.
  if LQualified and (LQualIdent <> NIL_NODE) then
  begin
    var LTy := FModel.Resolve(AScope, LowerCase(NodeText(LQualIdent)));
    if (LTy <> NIL_SYM) and (FModel.Symbols[LTy].Kind = skType) and
       (FModel.Symbols[LTy].MemberScope <> NIL_SCOPE) then
      FModel.JoinScope(LRoutine, FModel.Symbols[LTy].MemberScope);
  end;
  if (LNameNode <> NIL_NODE) and not LQualified then
  begin
    // An unqualified routine WITH a body in the implementation section that
    // matches an interface declaration is that declaration's implementation —
    // link to it (mark sfHasBody) instead of adding a phantom overload.
    var LLink := NIL_SYM;
    if (AScope = FImpl) and (FindChildKind(ANode, nkRoutineBody) <> NIL_NODE) then
    begin
      var LIntfSym := FModel.FindLocal(FIntf, LowerCase(NodeText(LNameNode)));
      if (LIntfSym <> NIL_SYM) and
         (FModel.Symbols[LIntfSym].Kind = skRoutine) then
        LLink := LIntfSym;
    end;
    if LLink <> NIL_SYM then
    begin
      FModel.Symbols[LLink].Flags := FModel.Symbols[LLink].Flags + [sfHasBody];
      MarkDeclName(LNameNode, LLink);
    end
    else
      DeclareSym(AScope, skRoutine, NodeText(LNameNode), LNameNode);
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
    else
      Collect(LChild, LRoutine);   // generic params, result type, body...
    end;
    LChild := NextSib(LChild);
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

    nkRecordType, nkClassType, nkInterfaceType, nkObjectType, nkHelperType:
      CollectStruct(ANode, AScope, NIL_SYM);

    nkBlock:
      begin
        // Inline vars are block-scoped: give each begin..end its own scope so
        // the same name in sibling blocks does not read as a redeclaration.
        var LBlock := FModel.AddScope(sckBlock, AScope, ANode);
        FNodeScope[ANode] := LBlock;
        LChild := FirstChild(ANode);
        while LChild <> NIL_NODE do
        begin
          Collect(LChild, LBlock);
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
        FModel.RefMap[ANode] :=
          FModel.Resolve(FNodeScope[ANode], LowerCase(NodeText(ANode)));

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
end;

end.
