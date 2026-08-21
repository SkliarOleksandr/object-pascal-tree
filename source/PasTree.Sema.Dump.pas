unit PasTree.Sema.Dump;

{
  PasTree semantics — a compact, human-readable dump of a TPasSemaModel
  (scope tree + symbols + diagnostics + resolution stats). Used by the
  PasTreeSema tool and for eyeballing test failures.
}

interface

uses
  PasTree.Sema.Model;

function DumpSemaModel(AModel: TPasSemaModel): string;

implementation

uses
  System.SysUtils, System.Classes,
  PasTree.Ast;

function KindStr(AKind: TSemaSymbolKind): string;
begin
  case AKind of
    skType: Result := 'type';
    skVar: Result := 'var';
    skConst: Result := 'const';
    skField: Result := 'field';
    skRoutine: Result := 'routine';
    skParam: Result := 'param';
    skProperty: Result := 'property';
    skEnumValue: Result := 'enum';
    skGenericParam: Result := 'generic';
    skLabel: Result := 'label';
    skUnitRef: Result := 'uses';
    skBuiltinType: Result := 'builtin';
  else
    Result := '?';
  end;
end;

function ScopeStr(AKind: TSemaScopeKind): string;
begin
  case AKind of
    sckSystem: Result := 'system';
    sckUnit: Result := 'unit';
    sckImplementation: Result := 'impl';
    sckStruct: Result := 'struct';
    sckRoutine: Result := 'routine';
    sckWith: Result := 'with';
    sckBlock: Result := 'block';
    sckGenericParams: Result := 'generics';
    sckEnum: Result := 'enum';
  else
    Result := '?';
  end;
end;

function DumpSemaModel(AModel: TPasSemaModel): string;
var
  LSB: TStringBuilder;
  LScope, LSymIdx, LResolved, LExternal, LUnresolvedRefs, LNode: Integer;
  LSym: TSemaSymbol;
  LLine: string;
begin
  LSB := TStringBuilder.Create;
  try
    for LScope := 0 to AModel.Scopes.Count - 1 do
    begin
      // Summarize the system scope; detail user scopes.
      // Names/Symbols are LAZY (nil until the first bind) — count nil as 0.
      if AModel.Scopes[LScope].Kind = sckSystem then
      begin
        var LBuiltinCount := 0;
        if AModel.Scopes[LScope].Symbols <> nil then
          LBuiltinCount := AModel.Scopes[LScope].Symbols.Count;
        LSB.AppendFormat('scope#%d %s (builtins: %d)'#10,
          [LScope, ScopeStr(AModel.Scopes[LScope].Kind), LBuiltinCount]);
        Continue;
      end;
      LSB.AppendFormat('scope#%d %s (parent#%d)'#10,
        [LScope, ScopeStr(AModel.Scopes[LScope].Kind),
         AModel.Scopes[LScope].Parent]);
      if AModel.Scopes[LScope].Symbols = nil then
        Continue;
      for LSymIdx in AModel.Scopes[LScope].Symbols do
      begin
        LSym := AModel.Symbols[LSymIdx];
        LLine := Format('  %-8s %s', [KindStr(LSym.Kind), LSym.Name]);
        if LSym.TypeSym <> NIL_SYM then
          LLine := LLine + ' : ' + AModel.Symbols[LSym.TypeSym].Name
        else if LSym.TypeNode <> NIL_NODE then
          LLine := LLine + ' : <unbound>';
        if sfOverload in LSym.Flags then
          LLine := LLine + ' [overload]';
        if sfExternalUnresolved in LSym.Flags then
          LLine := LLine + ' [external]';
        if LSym.MemberScope <> NIL_SCOPE then
          LLine := LLine + Format(' [members scope#%d]', [LSym.MemberScope]);
        LSB.Append(LLine).Append(#10);
      end;
    end;

    // Reference resolution stats.
    LResolved := 0; LExternal := 0; LUnresolvedRefs := 0;
    var LCross := 0;
    for LNode := 0 to High(AModel.RefMap) do
      if AModel.Tree.Nodes[LNode].Kind in [nkIdent, nkMember] then
      begin
        if AModel.RefMap[LNode] <> NIL_SYM then
          Inc(LResolved)
        else if AModel.ExtRefMap.ContainsKey(LNode) then
          Inc(LCross)
        else
          Inc(LUnresolvedRefs);
      end;
    for LSymIdx := 0 to AModel.SymCount - 1 do
      if sfExternalUnresolved in AModel.Symbols[LSymIdx].Flags then
        Inc(LExternal);

    LSB.AppendFormat(
      'refs: %d local, %d cross-unit, %d unresolved; external-uses: %d'#10,
      [LResolved, LCross, LUnresolvedRefs, LExternal]);

    // Typed-expression coverage (Phase 3).
    var LExprTotal := 0; var LTyped := 0;
    for LNode := 0 to High(AModel.ExprType) do
      if AModel.Tree.Nodes[LNode].Kind in [nkIdent, nkIntLit, nkRealLit,
        nkStrLit, nkBinaryOp, nkUnaryOp, nkCall, nkMember] then
      begin
        Inc(LExprTotal);
        if AModel.ExprType[LNode] <> NIL_SYM then
          Inc(LTyped);
      end;
    LSB.AppendFormat(
      'typed exprs: %d/%d (+%d cross-model); calls resolved: %d'#10,
      [LTyped, LExprTotal, AModel.ExprTypeX.Count, AModel.CallTarget.Count]);

    if Length(AModel.Diags) > 0 then
    begin
      LSB.Append('diags:'#10);
      for LNode := 0 to High(AModel.Diags) do
        LSB.AppendFormat('  %s(%d,%d): %s'#10,
          [AModel.Diags[LNode].Code, AModel.Diags[LNode].Line,
           AModel.Diags[LNode].Col, AModel.Diags[LNode].Msg]);
    end;
  finally
    Result := LSB.ToString;
    LSB.Free;
  end;
end;

end.
