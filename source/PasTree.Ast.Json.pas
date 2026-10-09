unit PasTree.Ast.Json;

// PasTree - JSON serialization of the AST.
//
// Schema (stable, machine-diffable), braces shown as [ ] to survive this
// comment: node = [ kind, file (index into files), line, col (1-based,
// first token), text (leaf/name-bearing nodes only), negated?, aux?,
// children (omitted when empty) ]. The root object wraps the tree with
// the file table: [ files: [...], ast: node ].

interface

uses
  PasTree.Ast;

function AstToJson(const ATree: TPasTree; ARootNode: Integer = 0): string;

implementation

uses
  System.SysUtils,
  PasTree.Types,
  PasTree.Preprocessor;

procedure JsonEscape(const AValue: string; ABuilder: TStringBuilder);
var
  LCh: Char;
begin
  ABuilder.Append('"');
  for LCh in AValue do
    case LCh of
      '"': ABuilder.Append('\"');
      '\': ABuilder.Append('\\');
      #8: ABuilder.Append('\b');
      #9: ABuilder.Append('\t');
      #10: ABuilder.Append('\n');
      #12: ABuilder.Append('\f');
      #13: ABuilder.Append('\r');
    else
      if LCh < #32 then
        ABuilder.AppendFormat('\u%.4x', [Ord(LCh)])
      else
        ABuilder.Append(LCh);
    end;
  ABuilder.Append('"');
end;

function AstToJson(const ATree: TPasTree; ARootNode: Integer): string;
var
  LSB: TStringBuilder;

  // A node's object up to its children: closed with `}` when it has none,
  // left open after `"children":[` when it has some.
  procedure EmitHead(AIndex: Integer);
  var
    LVis: TPasVisibleToken;
    LLine, LCol: Integer;
    LKind: TPasNodeKind;
  begin
    LKind := ATree.Nodes[AIndex].Kind;
    LSB.Append('{"kind":');
    JsonEscape(ATree.KindName(LKind), LSB);
    if (ATree.Nodes[AIndex].FirstToken >= 0) and
       (ATree.Nodes[AIndex].FirstToken <= High(ATree.Source.Visible)) then
    begin
      LVis := ATree.Source.Visible[ATree.Nodes[AIndex].FirstToken];
      ATree.Source.Files[LVis.FileId].OffsetToLineCol(
        ATree.Source.Files[LVis.FileId].Tokens[LVis.TokenIndex].Start,
        LLine, LCol);
      LSB.AppendFormat(',"file":%d,"line":%d,"col":%d',
        [LVis.FileId, LLine, LCol]);
    end;
    // Text for name/value-bearing leaves (matches TPasTree.Dump).
    case LKind of
      nkIdent, nkIntLit, nkRealLit, nkStrLit, nkCaretChar,
      nkUnaryOp, nkBinaryOp:
        begin
          LSB.Append(',"text":');
          // Bounds-checked like the position emission above: on a demoted
          // model Visible is nil and this read was an AV.
          if LKind in [nkUnaryOp, nkBinaryOp] then
            if (ATree.Nodes[AIndex].Aux >= 0) and
               (ATree.Nodes[AIndex].Aux <= High(ATree.Source.Visible)) then
              JsonEscape(LowerCase(
                ATree.Source.VisibleText(ATree.Nodes[AIndex].Aux)), LSB)
            else
              LSB.Append('""')
          else
            JsonEscape(ATree.NodeText(AIndex), LSB);
        end;
    end;
    // ANY node's negated mark, not just the text-bearing ones. On nkVisibility
    // it is what separates `strict private` from `private` - the S-expression
    // dump prints `#strict` for it, while JSON made the two byte-identical.
    if nfNegated in ATree.Nodes[AIndex].Flags then
      LSB.Append(',"negated":true');
    // Part of a declared name (see nfName): without it `P, T: C` and
    // `P: T = C` serialize alike, as the dump's `#name` says.
    if nfName in ATree.Nodes[AIndex].Flags then
      LSB.Append(',"name":true');
    // `packed` before the type (nfPacked), a token outside its span.
    if nfPacked in ATree.Nodes[AIndex].Flags then
      LSB.Append(',"packed":true');
    // `class abstract` / `class sealed` (nfAbstract, nfSealed).
    if nfAbstract in ATree.Nodes[AIndex].Flags then
      LSB.Append(',"abstract":true');
    if nfSealed in ATree.Nodes[AIndex].Flags then
      LSB.Append(',"sealed":true');
    // `class threadvar` (nfThreadvar).
    if nfThreadvar in ATree.Nodes[AIndex].Flags then
      LSB.Append(',"threadvar":true');
    // A parameter's mode (nfVar, nfConst, nfOut).
    if nfVar in ATree.Nodes[AIndex].Flags then
      LSB.Append(',"var":true');
    if nfConst in ATree.Nodes[AIndex].Flags then
      LSB.Append(',"const":true');
    if nfOut in ATree.Nodes[AIndex].Flags then
      LSB.Append(',"out":true');
    // An external directive's clauses (nfExtName, nfExtIndex,
    // nfExtDependency on the values, nfDelayed on the directive).
    if nfExtName in ATree.Nodes[AIndex].Flags then
      LSB.Append(',"extname":true');
    if nfExtIndex in ATree.Nodes[AIndex].Flags then
      LSB.Append(',"extindex":true');
    if nfExtDependency in ATree.Nodes[AIndex].Flags then
      LSB.Append(',"extdependency":true');
    if nfDelayed in ATree.Nodes[AIndex].Flags then
      LSB.Append(',"delayed":true');
    if nfResident in ATree.Nodes[AIndex].Flags then
      LSB.Append(',"resident":true');
    if ATree.Nodes[AIndex].Aux <> NIL_NODE then
      if not (LKind in [nkUnaryOp, nkBinaryOp]) then
        LSB.AppendFormat(',"aux":%d', [ATree.Nodes[AIndex].Aux]);
    if ATree.Nodes[AIndex].FirstChild <> NIL_NODE then
      LSB.Append(',"children":[')
    else
      LSB.Append('}');
  end;

  // The subtree under ARoot, in a loop over the tree's own links rather than
  // a recursion per level: an operator chain nests one nkBinaryOp per operand,
  // and a few thousand terms of generated code overflowed the stack here
  // (audit B1-37). Pre-order, the children of a node closed by `]}` on the
  // way back up - the output the recursion wrote.
  procedure EmitTree(ARoot: Integer);
  var
    LNode: Integer;
  begin
    LNode := ARoot;
    repeat
      EmitHead(LNode);
      if ATree.Nodes[LNode].FirstChild <> NIL_NODE then
      begin
        LNode := ATree.Nodes[LNode].FirstChild;
        Continue;
      end;
      while (LNode <> ARoot) and
            (ATree.Nodes[LNode].NextSibling = NIL_NODE) do
      begin
        LNode := ATree.Nodes[LNode].Parent;
        LSB.Append(']}');
      end;
      if LNode = ARoot then
        Break;
      LSB.Append(',');
      LNode := ATree.Nodes[LNode].NextSibling;
    until False;
  end;

var
  LIdx: Integer;
begin
  LSB := TStringBuilder.Create;
  try
    LSB.Append('{"files":[');
    for LIdx := 0 to High(ATree.Source.FileNames) do
    begin
      if LIdx > 0 then
        LSB.Append(',');
      JsonEscape(ATree.Source.FileNames[LIdx], LSB);
    end;
    LSB.Append('],"ast":');
    EmitTree(ARootNode);
    LSB.Append('}');
    Result := LSB.ToString;
  finally
    LSB.Free;
  end;
end;

end.
