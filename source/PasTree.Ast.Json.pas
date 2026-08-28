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

  procedure EmitNode(AIndex: Integer);
  var
    LVis: TPasVisibleToken;
    LLine, LCol, LChild: Integer;
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
          if LKind in [nkUnaryOp, nkBinaryOp] then
            JsonEscape(LowerCase(
              ATree.Source.VisibleText(ATree.Nodes[AIndex].Aux)), LSB)
          else
            JsonEscape(ATree.NodeText(AIndex), LSB);
          if nfNegated in ATree.Nodes[AIndex].Flags then
            LSB.Append(',"negated":true');
        end;
    end;
    if ATree.Nodes[AIndex].Aux <> NIL_NODE then
      if not (LKind in [nkUnaryOp, nkBinaryOp]) then
        LSB.AppendFormat(',"aux":%d', [ATree.Nodes[AIndex].Aux]);
    LChild := ATree.Nodes[AIndex].FirstChild;
    if LChild <> NIL_NODE then
    begin
      LSB.Append(',"children":[');
      while LChild <> NIL_NODE do
      begin
        EmitNode(LChild);
        LChild := ATree.Nodes[LChild].NextSibling;
        if LChild <> NIL_NODE then
          LSB.Append(',');
      end;
      LSB.Append(']');
    end;
    LSB.Append('}');
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
    EmitNode(ARootNode);
    LSB.Append('}');
    Result := LSB.ToString;
  finally
    LSB.Free;
  end;
end;

end.
