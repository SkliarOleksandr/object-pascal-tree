unit PasTree.Printer;

{
  PasTree - the structural printer (parser fidelity, phase 3).

  NodeSpanText prints a node from its span: lossless by construction, and it
  tests nothing. This printer regenerates the source from the TREE: keywords
  and punctuation from Kind, Aux, Flags and the order of the children, text
  only from a leaf's own tokens and from the contract reads of the own-token
  table (PasTree.Ast.Check) - the operator token an nkUnaryOp's or
  nkBinaryOp's Aux names, and asm's opaque range. What the tree does not
  hold it cannot print, and T3 - the printed sequence against the visible
  stream the tree was parsed from - finds exactly those places.

  Templates exist for the expression and statement kinds (PasTemplatedKind).
  A node of any other kind - the declarations, for now - prints FROM ITS
  SPAN: its own tokens verbatim and its children in their places, each child
  through its own template. Its items are marked pcSpan, so a comparison can
  tell a copied token from a regenerated one, and the templates are
  exercised inside declarations too (a constant's value, a routine's body).

  The canonical form. Where the grammar allows several spellings of one tree
  the printer writes one of them:
  - one `;` between the statements of a list, none before the first or after
    the last; one after every case selector and every exception handler,
    the last included - it keeps a case's or an except part's `else` from
    reading as an if's (`1: if C then A; else B`);
  - keywords in lower case;
  - a `>=` the lexer fused from type arguments' closing `>` and an `=`
    operator (`V.AsType<T>=5`) as the two tokens it stands for.
  The comparison maps the ORIGINAL onto the same form - PRINT_NORMALIZATION,
  one entry per rule with its reason - and does nothing else.

  T3 (CompareT3): the printed items against the visible stream, one by one.
  A regenerated keyword or punctuation matches a token of the same text
  (case-insensitively) that its own node owns; a leaf, contract or span item
  matches the very token it was read from. A token the print lacks is a LOSS
  when the own-token table files it as one (a plan finding - inside
  statements that is F16, the numeric label) and a DEFECT otherwise.

  T3r (CheckT3r): parse(print(tree)) = tree. The print is rendered in two
  layouts, one token per line and everything on one line, and each is parsed
  back; both trees must fingerprint (TreeFingerprint) exactly as the
  original. It compares the parser with itself, so it is blind to what both
  parses share - a dropped fact, a consistent misreading: those take the
  original tokens (T3) and dcc. What it shows is that the canonical form is
  the same program for the parser, and that the tree of valid code does not
  depend on its layout (some recovery heuristics read line breaks).

  Valid code only: every function here assumes a parse that reported no
  diagnostic. An nkError prints from its span.
}

interface

uses
  PasTree.Types,
  PasTree.Preprocessor,
  PasTree.Ast;

type
  TPasPrintClass = (
    pcDerived,     // a keyword or punctuation regenerated from the tree
    pcSeparator,   // a statement list's `;`: derived, but T3 compares the
                   // lists without them (PRINT_NORMALIZATION, N1)
    pcLeaf,        // a leaf node's own token: a name or a literal
    pcContract,    // read from a token by a documented rule: the operator
                   // an Aux names, asm's opaque range
    pcSpan         // an own token of a node without a template, verbatim
  );

  TPasPrintItem = record
    Text: string;
    Cls: TPasPrintClass;
    Node: Integer;     // the node that printed it
    Vis: Integer;      // the visible token it was read from; -1: regenerated
    // Joined to the item before it by the original gap instead of the
    // layout's separator: the tokens of one string literal (`'a'#13`, `^M`
    // - a space would split or merge them) and the lines of an asm block
    // (BASM is line-structured). The gap keeps only its line breaks.
    Glue: Boolean;
  end;
  TPasPrintItems = TArray<TPasPrintItem>;

  TPasPrintLayout = (
    plOneLine,        // one space between items
    plTokenPerLine,   // one line break between items
    // The original's layout, for reading: each item on the line and at the
    // column of the token it stands for - the one it was read from, or for a
    // regenerated item the one CompareT3 matched it to (TPasT3Result.ItemAt);
    // an item with neither goes after the one before it.
    plSource
  );

const
  { What T3 does to the ORIGINAL stream before comparing, and why each is
    allowed. The printer writes the canonical form directly. }
  PRINT_NORMALIZATION: array[0..4] of string = (
    'N1 list separators: every `;` a statement list owns (nkBlock, ' +
      'nkCaseStmt, nkExceptPart) is dropped, and so is every separator the ' +
      'printer writes - a run of them is one, one before end / else / until ' +
      'is none, and the canonical ones are derived from the children',
    'N2 fused >=: the `>=` an nkBinaryOp names when type arguments on its ' +
      'left ended in it (`V.AsType<T>=5`) is the `>` closing them and the ' +
      '`=` operator: the lexer fused two tokens the grammar reads apart',
    'N3 keyword case: a regenerated keyword, directive word or punctuation ' +
      'matches its token case-insensitively (dcc reads them so); leaves and ' +
      'copied tokens match exactly',
    'N4 the <eof> sentinel a root span ends on is no token of the source',
    'N5 text after the final `end.` is ignored by dcc; the root owns its ' +
      'first token only (csAfterEnd)'
  );

{ The kinds the printer has a template for: every expression and statement
  kind. Any other kind prints from its span (pcSpan). }
function PasTemplatedKind(AKind: TPasNodeKind): Boolean;

{ The token sequence of ANode's subtree, regenerated. }
function PrintNode(const ATree: TPasTree; ANode: Integer = 0): TPasPrintItems;

{ The items as source text, separated as ALayout says (glued items by their
  original gap), ending in a line break. AAt, for plSource: CompareT3's
  ItemAt for the same items; without it only the items read from a token
  have a place. }
function RenderItems(const ATree: TPasTree; const AItems: TPasPrintItems;
  ALayout: TPasPrintLayout; const AAt: TArray<Integer> = nil): string;

type
  TPasT3Site = record
    Vis: Integer;        // the original token; -1: the original had run out
    Item: Integer;       // the printed item; -1: the print had run out
    Finding: string;     // a loss: its plan finding ('F16'); '' a defect
    Msg: string;
  end;

  TPasT3Result = record
    Original: Integer;   // tokens in the root's span
    Normalized: Integer; // of them dropped or split by PRINT_NORMALIZATION
    Printed: Integer;    // printed items compared (separators excluded)
    Matched: Integer;    // printed items that matched their token
    Spans: Integer;      // of them copied by a node without a template
    Losses: Integer;     // original tokens a filed loss explains
    Defects: Integer;    // mismatches nothing explains
    Sites: TArray<TPasT3Site>;   // the first ones, losses and defects
    // Per item of PrintNode's list (separators included): the visible token
    // it matched, -1 when none - the layout plSource reads.
    ItemAt: TArray<Integer>;
  end;

{ T3 over the subtree of ARoot (0: the whole tree). True when no defect was
  found; AResult.Sites keeps the first AMaxSites losses and defects. }
function CompareT3(const ATree: TPasTree; ARoot: Integer;
  out AResult: TPasT3Result; AMaxSites: Integer = 20): Boolean;

{ One line per reachable node, preorder, indented by depth: the kind, its
  flags, its Aux (an operator's by the operator's text, a parameter's `out`
  by the word - never a token index) and its own tokens' texts - for a leaf,
  asm and every kind without a template; the own tokens of a template's kind
  are regenerated and do not count. Two trees of one program in two layouts
  fingerprint alike. ANodes[i] is the node of line i. }
function TreeFingerprint(const ATree: TPasTree): TArray<string>; overload;
function TreeFingerprint(const ATree: TPasTree;
  out ANodes: TArray<Integer>): TArray<string>; overload;

type
  { Parses AText the way the original was parsed (ParseStatements or
    ParseFile, the same preprocessor); ADiags is the parse's diagnostic
    count, ADiagVis and AFirstDiag the first one's visible index and text.
    False: it could not run. }
  TPasReparse = reference to function(const AText: string;
    out ATree: TPasTree; out ADiags, ADiagVis: Integer;
    out AFirstDiag: string): Boolean;

{ T3r over the whole tree: printed in both layouts, each parsed back by
  AReparse, both fingerprints equal to ATree's. AMsg says, per layout that
  fails, where the first difference is; '' when True. }
function CheckT3r(const ATree: TPasTree; const AReparse: TPasReparse;
  out AMsg: string): Boolean;

implementation

uses
  System.SysUtils,
  PasTree.Ast.Check;

const
  TEMPLATED_KINDS = [
    nkMissing,
    nkIdent, nkIntLit, nkRealLit, nkStrLit, nkNilLit, nkCaretChar,
    nkUnaryOp, nkBinaryOp, nkParen, nkCall, nkFormattedArg, nkIndex,
    nkMember, nkDeref, nkTypeArgs, nkSetCtor, nkRange, nkInlineIf,
    nkInherited, nkAnonMethod, nkNamedArg,
    nkBlock, nkEmptyStmt, nkAssign, nkExprStmt, nkIfStmt, nkCaseStmt,
    nkCaseSel, nkCaseLabels, nkForStmt, nkForInStmt, nkWhileStmt,
    nkRepeatStmt, nkWithStmt, nkGotoStmt, nkLabeledStmt, nkTryStmt,
    nkExceptPart, nkExceptOn, nkFinallyPart, nkRaiseStmt, nkAsmStmt,
    nkInlineVar, nkInlineConst];
  // Leaves print their own tokens; their texts are the node.
  LEAF_KINDS = [nkIdent, nkIntLit, nkRealLit, nkStrLit, nkCaretChar];
  // The statement lists whose `;` are separators (N1).
  LIST_KINDS = [nkBlock, nkCaseStmt, nkExceptPart];
  ZERO_WIDTH = [nkEmptyStmt, nkMissing];
  UNIT_KINDS = [nkUnit, nkProgram, nkLibrary, nkPackage];

var
  // Per own-token rule, read once: a loss's finding ('' for any other
  // class), and whether it is the text-after-end rule.
  GRuleFinding: TArray<string>;
  GRuleAfterEnd: TArray<Boolean>;

procedure InitRules;
var
  LIdx: Integer;
  LRule: TPasOwnRule;
begin
  SetLength(GRuleFinding, OwnRuleCount);
  SetLength(GRuleAfterEnd, OwnRuleCount);
  for LIdx := 0 to OwnRuleCount - 1 do
  begin
    LRule := OwnRule(LIdx);
    if LRule.Cls = ocLoss then
      GRuleFinding[LIdx] := LRule.Finding;
    GRuleAfterEnd[LIdx] := LRule.Cond = wcAfterEnd;
  end;
end;

function PasTemplatedKind(AKind: TPasNodeKind): Boolean;
begin
  Result := AKind in TEMPLATED_KINDS;
end;

function LastChild(const ATree: TPasTree; ANode: Integer): Integer;
var
  LChild: Integer;
begin
  Result := NIL_NODE;
  LChild := ATree.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    Result := LChild;
    LChild := ATree.Nodes[LChild].NextSibling;
  end;
end;

// A node that stands between tokens and owns none (PasTree.Ast.Check, EMPTY
// nodes).
function IsEmptyNode(const ATree: TPasTree; ANode: Integer): Boolean;
begin
  Result := (ATree.Nodes[ANode].Kind in ZERO_WIDTH) or
    (ATree.Nodes[ANode].LastToken < ATree.Nodes[ANode].FirstToken);
end;

{ N2: is ANode an nkBinaryOp whose operator token is a `>=` fused from the
  `>` closing type arguments on its left and its own `=`? CloseGeneric splits
  such a token, so the type arguments end one token BEFORE it and own no `>`
  - their span ends where their last argument does. Read from the tree: the
  operator token (the contract read) and the spans along the left operand's
  right edge. }
function IsFusedGreaterEqual(const ATree: TPasTree; ANode: Integer): Boolean;
var
  LOp, LNode, LLast: Integer;
begin
  Result := False;
  if ATree.Nodes[ANode].Kind <> nkBinaryOp then
    Exit;
  LOp := ATree.Nodes[ANode].Aux;
  if (LOp < 0) or (LOp > High(ATree.Source.Visible)) or
     (ATree.Source.VisibleToken(LOp).Kind <> tkGreaterEqual) then
    Exit;
  LNode := ATree.Nodes[ANode].FirstChild;
  while (LNode <> NIL_NODE) and (ATree.Nodes[LNode].LastToken = LOp - 1) do
  begin
    if ATree.Nodes[LNode].Kind = nkTypeArgs then
    begin
      LLast := LastChild(ATree, LNode);
      Exit((LLast <> NIL_NODE) and
        (ATree.Nodes[LLast].LastToken = ATree.Nodes[LNode].LastToken));
    end;
    LNode := LastChild(ATree, LNode);
  end;
end;

{ TPrinter }

type
  TPrinter = record
    T: TPasTree;
    Items: TPasPrintItems;
    Count: Integer;
    procedure Add(const AText: string; ACls: TPasPrintClass; ANode,
      AVis: Integer; AGlue: Boolean);
    procedure Kw(const AText: string; ANode: Integer);
    procedure Sep(ANode: Integer);
    procedure Tok(AVis: Integer; ACls: TPasPrintClass; ANode: Integer;
      AGlue: Boolean);
    procedure OwnRange(ANode: Integer; ACls: TPasPrintClass; AGlued: Boolean);
    procedure Span(ANode: Integer);
    procedure ListFrom(AChild: Integer; const ASep: string; AParent: Integer);
    procedure Block(ANode: Integer);
    procedure InlineDecl(ANode: Integer; AConst: Boolean);
    procedure AnonMethod(ANode: Integer);
    procedure Emit(ANode: Integer);
  end;

procedure TPrinter.Add(const AText: string; ACls: TPasPrintClass; ANode,
  AVis: Integer; AGlue: Boolean);
begin
  if Count = Length(Items) then
    SetLength(Items, Count * 2 + 64);
  Items[Count].Text := AText;
  Items[Count].Cls := ACls;
  Items[Count].Node := ANode;
  Items[Count].Vis := AVis;
  Items[Count].Glue := AGlue;
  Inc(Count);
end;

procedure TPrinter.Kw(const AText: string; ANode: Integer);
begin
  Add(AText, pcDerived, ANode, -1, False);
end;

procedure TPrinter.Sep(ANode: Integer);
begin
  Add(';', pcSeparator, ANode, -1, False);
end;

procedure TPrinter.Tok(AVis: Integer; ACls: TPasPrintClass; ANode: Integer;
  AGlue: Boolean);
begin
  // The sentinel is no text of the source (N4). Out of range only in a
  // tree the printer is not meant for (an operator of an error tree).
  if (AVis < 0) or (AVis > High(T.Source.Visible)) or
     (T.Source.VisibleToken(AVis).Kind = tkEndOfFile) then
    Exit;
  Add(T.Source.VisibleText(AVis), ACls, ANode, AVis, AGlue);
end;

// Every token of ANode's span, as one glued run when AGlued: a leaf that
// spans several string elements, asm's range.
procedure TPrinter.OwnRange(ANode: Integer; ACls: TPasPrintClass;
  AGlued: Boolean);
var
  LFirst, LVis: Integer;
begin
  LFirst := T.NodeLeftmostVis(ANode);
  for LVis := LFirst to T.Nodes[ANode].LastToken do
    Tok(LVis, ACls, ANode, AGlued and (LVis > LFirst));
end;

procedure TPrinter.Span(ANode: Integer);
var
  LCursor, LLast, LChild, LFrom: Integer;
begin
  LCursor := T.NodeLeftmostVis(ANode);
  LLast := T.Nodes[ANode].LastToken;
  // N5: a root stops on the token after its final `.` - the sentinel or
  // text dcc ignores; neither is printed.
  if (ANode = 0) and (T.Nodes[ANode].Kind in UNIT_KINDS) then
    Dec(LLast);
  LChild := T.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if not IsEmptyNode(T, LChild) then
    begin
      LFrom := T.NodeLeftmostVis(LChild);
      while LCursor < LFrom do
      begin
        Tok(LCursor, pcSpan, ANode, False);
        Inc(LCursor);
      end;
      Emit(LChild);
      if T.Nodes[LChild].LastToken >= LCursor then
        LCursor := T.Nodes[LChild].LastToken + 1;
    end;
    LChild := T.Nodes[LChild].NextSibling;
  end;
  while LCursor <= LLast do
  begin
    Tok(LCursor, pcSpan, ANode, False);
    Inc(LCursor);
  end;
end;

// AChild and every sibling after it, ASep between them.
procedure TPrinter.ListFrom(AChild: Integer; const ASep: string;
  AParent: Integer);
var
  LFirst: Boolean;
begin
  LFirst := True;
  while AChild <> NIL_NODE do
  begin
    if not LFirst then
      Kw(ASep, AParent);
    Emit(AChild);
    LFirst := False;
    AChild := T.Nodes[AChild].NextSibling;
  end;
end;

{ An nkBlock's head and tail come from where it stands (the own-token table:
  begin only for a compound statement, a routine body or a main block):
  - the root of ParseStatements, a try's or a finally's statements, a
    repeat's, an except part's catch-all: the statements alone;
  - a case's last child, an except part's after its handlers: `else` first;
  - a program's or library's main block: `begin`, its `end` is the root's;
  - anywhere else - a statement, a routine body: `begin ... end`. }
procedure TPrinter.Block(ANode: Integer);
var
  LParent, LChild: Integer;
  LHead, LTail: string;
  LFirst: Boolean;
begin
  LParent := T.Nodes[ANode].Parent;
  LHead := 'begin';
  LTail := 'end';
  if LParent = NIL_NODE then
  begin
    LHead := '';
    LTail := '';
  end
  else
    case T.Nodes[LParent].Kind of
      nkTryStmt, nkFinallyPart, nkRepeatStmt:
        begin
          LHead := '';
          LTail := '';
        end;
      nkCaseStmt:
        begin
          LHead := 'else';
          LTail := '';
        end;
      nkExceptPart:
        begin
          if T.Nodes[LParent].FirstChild = ANode then
            LHead := ''
          else
            LHead := 'else';
          LTail := '';
        end;
      nkProgram, nkLibrary:
        LTail := '';
    end;
  if LHead <> '' then
    Kw(LHead, ANode);
  LFirst := True;
  LChild := T.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if not LFirst then
      Sep(ANode);
    Emit(LChild);
    LFirst := False;
    LChild := T.Nodes[LChild].NextSibling;
  end;
  if LTail <> '' then
    Kw(LTail, ANode);
end;

{ `var` names (nfName), [`:` type], [`:=` initializer - Aux 1 says the last
  child is one]; `const` name, [`:` type], `=` value. A for loop's counter is
  an nkInlineVar too, without Aux: the `:=` there is the loop's. }
procedure TPrinter.InlineDecl(ANode: Integer; AConst: Boolean);
var
  LChild, LRest: Integer;
  LFirst, LInit: Boolean;
begin
  if AConst then
    Kw('const', ANode)
  else
    Kw('var', ANode);
  LChild := T.Nodes[ANode].FirstChild;
  LFirst := True;
  while (LChild <> NIL_NODE) and (nfName in T.Nodes[LChild].Flags) do
  begin
    if not LFirst then
      Kw(',', ANode);
    Emit(LChild);
    LFirst := False;
    LChild := T.Nodes[LChild].NextSibling;
  end;
  LInit := T.Nodes[ANode].Aux = 1;
  LRest := 0;
  if LChild <> NIL_NODE then
    LRest := 1 + Ord(T.Nodes[LChild].NextSibling <> NIL_NODE);
  // Two children after the names: the type, then the value. One: the value
  // when Aux says so, else the type.
  if (LRest = 2) or ((LRest = 1) and not LInit) then
  begin
    Kw(':', ANode);
    Emit(LChild);
    LChild := T.Nodes[LChild].NextSibling;
  end;
  if (LChild <> NIL_NODE) and LInit then
  begin
    if AConst then
      Kw('=', ANode)
    else
      Kw(':=', ANode);
    Emit(LChild);
  end;
end;

{ [params], [result type], directives, body: `function` when a result type
  is there. The parameter list and the directives print from their spans
  for now; the body's statements through the templates. }
procedure TPrinter.AnonMethod(ANode: Integer);
var
  LChild: Integer;
  LFunction: Boolean;
begin
  LFunction := False;
  LChild := T.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if not (T.Nodes[LChild].Kind in [nkParams, nkDirective, nkRoutineBody])
    then
      LFunction := True;
    LChild := T.Nodes[LChild].NextSibling;
  end;
  if LFunction then
    Kw('function', ANode)
  else
    Kw('procedure', ANode);
  LChild := T.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if not (T.Nodes[LChild].Kind in [nkParams, nkDirective, nkRoutineBody])
    then
      Kw(':', ANode);
    Emit(LChild);
    LChild := T.Nodes[LChild].NextSibling;
  end;
end;

procedure TPrinter.Emit(ANode: Integer);
var
  LKind: TPasNodeKind;
  C0, C1, C2, LChild, LOp: Integer;
  LOpKind: TPasTokenKind;
begin
  // A child a template expects and an error tree lacks.
  if ANode = NIL_NODE then
    Exit;
  LKind := T.Nodes[ANode].Kind;
  C0 := T.Nodes[ANode].FirstChild;
  C1 := NIL_NODE;
  C2 := NIL_NODE;
  if C0 <> NIL_NODE then
  begin
    C1 := T.Nodes[C0].NextSibling;
    if C1 <> NIL_NODE then
      C2 := T.Nodes[C1].NextSibling;
  end;
  case LKind of
    nkMissing, nkEmptyStmt:
      ;
    nkIdent, nkIntLit, nkRealLit, nkStrLit, nkCaretChar:
      OwnRange(ANode, pcLeaf, True);
    nkNilLit:
      Kw('nil', ANode);

    // ---- expressions ----
    nkUnaryOp:
      begin
        Tok(T.Nodes[ANode].Aux, pcContract, ANode, False);
        Emit(C0);
      end;
    nkBinaryOp:
      begin
        Emit(C0);
        LOp := T.Nodes[ANode].Aux;
        if IsFusedGreaterEqual(T, ANode) then
          // N2: the `>` is the type arguments' (they print it), this is `=`.
          Add('=', pcContract, ANode, LOp, False)
        else
        begin
          LOpKind := tkUnknown;
          if (LOp >= 0) and (LOp <= High(T.Source.Visible)) then
            LOpKind := T.Source.VisibleToken(LOp).Kind;
          // nfNegated: `not in` reads the `not` first, `is not` after.
          if (nfNegated in T.Nodes[ANode].Flags) and (LOpKind = tkIn) then
            Kw('not', ANode);
          Tok(LOp, pcContract, ANode, False);
          if (nfNegated in T.Nodes[ANode].Flags) and (LOpKind = tkIs) then
            Kw('not', ANode);
        end;
        Emit(C1);
      end;
    nkParen:
      begin
        Kw('(', ANode);
        Emit(C0);
        Kw(')', ANode);
      end;
    nkCall:
      begin
        Emit(C0);
        Kw('(', ANode);
        ListFrom(C1, ',', ANode);
        Kw(')', ANode);
      end;
    nkFormattedArg:
      begin
        Emit(C0);
        Kw(':', ANode);
        Emit(C1);
        if C2 <> NIL_NODE then
        begin
          Kw(':', ANode);
          Emit(C2);
        end;
      end;
    nkIndex:
      begin
        Emit(C0);
        Kw('[', ANode);
        ListFrom(C1, ',', ANode);
        Kw(']', ANode);
      end;
    nkMember:
      begin
        Emit(C0);
        Kw('.', ANode);
        if C1 <> NIL_NODE then
          Emit(C1);
      end;
    nkDeref:
      begin
        Emit(C0);
        Kw('^', ANode);
      end;
    nkTypeArgs:
      begin
        Emit(C0);
        Kw('<', ANode);
        ListFrom(C1, ',', ANode);
        Kw('>', ANode);
      end;
    nkSetCtor:
      begin
        Kw('[', ANode);
        ListFrom(C0, ',', ANode);
        Kw(']', ANode);
      end;
    nkRange:
      begin
        Emit(C0);
        Kw('..', ANode);
        Emit(C1);
      end;
    nkInlineIf:
      begin
        Kw('if', ANode);
        Emit(C0);
        Kw('then', ANode);
        Emit(C1);
        Kw('else', ANode);
        Emit(C2);
      end;
    nkInherited:
      begin
        Kw('inherited', ANode);
        if C0 <> NIL_NODE then
          Emit(C0);
      end;
    nkAnonMethod:
      AnonMethod(ANode);
    nkNamedArg:
      begin
        Emit(C0);
        Kw(':=', ANode);
        Emit(C1);
      end;

    // ---- statements ----
    nkBlock:
      Block(ANode);
    nkAssign:
      begin
        Emit(C0);
        Kw(':=', ANode);
        Emit(C1);
      end;
    nkExprStmt:
      Emit(C0);
    nkIfStmt:
      begin
        Kw('if', ANode);
        Emit(C0);
        Kw('then', ANode);
        Emit(C1);
        if C2 <> NIL_NODE then
        begin
          Kw('else', ANode);
          Emit(C2);
        end;
      end;
    nkCaseStmt:
      begin
        Kw('case', ANode);
        Emit(C0);
        Kw('of', ANode);
        LChild := C1;
        while LChild <> NIL_NODE do
        begin
          Emit(LChild);
          // After every selector, the last too: see the canonical form.
          if T.Nodes[LChild].Kind = nkCaseSel then
            Sep(ANode);
          LChild := T.Nodes[LChild].NextSibling;
        end;
        Kw('end', ANode);
      end;
    nkCaseSel:
      begin
        Emit(C0);
        Kw(':', ANode);
        Emit(C1);
      end;
    nkCaseLabels:
      ListFrom(C0, ',', ANode);
    nkForStmt:
      begin
        Kw('for', ANode);
        Emit(C0);
        Kw(':=', ANode);
        Emit(C1);
        if T.Nodes[ANode].Aux = 1 then
          Kw('downto', ANode)
        else
          Kw('to', ANode);
        Emit(C2);
        Kw('do', ANode);
        if C2 <> NIL_NODE then
          Emit(T.Nodes[C2].NextSibling);
      end;
    nkForInStmt:
      begin
        Kw('for', ANode);
        Emit(C0);
        Kw('in', ANode);
        Emit(C1);
        Kw('do', ANode);
        Emit(C2);
      end;
    nkWhileStmt:
      begin
        Kw('while', ANode);
        Emit(C0);
        Kw('do', ANode);
        Emit(C1);
      end;
    nkRepeatStmt:
      begin
        Kw('repeat', ANode);
        Emit(C0);
        Kw('until', ANode);
        Emit(C1);
      end;
    nkWithStmt:
      begin
        Kw('with', ANode);
        LChild := C0;
        while (LChild <> NIL_NODE) and
              (T.Nodes[LChild].NextSibling <> NIL_NODE) do
        begin
          if LChild <> C0 then
            Kw(',', ANode);
          Emit(LChild);
          LChild := T.Nodes[LChild].NextSibling;
        end;
        Kw('do', ANode);
        Emit(LChild);
      end;
    nkGotoStmt:
      begin
        Kw('goto', ANode);
        // A numeric label has no node (F16): nothing to print.
        if C0 <> NIL_NODE then
          Emit(C0);
      end;
    nkLabeledStmt:
      // Two children: the label's name and the statement; one: a numeric
      // label, which has no node (F16).
      if C1 <> NIL_NODE then
      begin
        Emit(C0);
        Kw(':', ANode);
        Emit(C1);
      end
      else
      begin
        Kw(':', ANode);
        Emit(C0);
      end;
    nkTryStmt:
      begin
        Kw('try', ANode);
        Emit(C0);
        Emit(C1);
        Kw('end', ANode);
      end;
    nkFinallyPart:
      begin
        Kw('finally', ANode);
        Emit(C0);
      end;
    nkExceptPart:
      begin
        Kw('except', ANode);
        LChild := C0;
        while LChild <> NIL_NODE do
        begin
          Emit(LChild);
          // After every handler, the last too: see the canonical form.
          if T.Nodes[LChild].Kind = nkExceptOn then
            Sep(ANode);
          LChild := T.Nodes[LChild].NextSibling;
        end;
      end;
    nkExceptOn:
      begin
        Kw('on', ANode);
        if C2 <> NIL_NODE then
        begin
          Emit(C0);
          Kw(':', ANode);
          Emit(C1);
          Kw('do', ANode);
          Emit(C2);
        end
        else
        begin
          Emit(C0);
          Kw('do', ANode);
          Emit(C1);
        end;
      end;
    nkRaiseStmt:
      begin
        Kw('raise', ANode);
        if C0 <> NIL_NODE then
        begin
          Emit(C0);
          if C1 <> NIL_NODE then
          begin
            Kw('at', ANode);
            Emit(C1);
          end;
        end;
      end;
    nkAsmStmt:
      // Opaque by design (6.10): the range as written, its lines kept.
      OwnRange(ANode, pcContract, True);
    nkInlineVar:
      InlineDecl(ANode, False);
    nkInlineConst:
      InlineDecl(ANode, True);
  else
    Span(ANode);
  end;
end;

function PrintNode(const ATree: TPasTree; ANode: Integer): TPasPrintItems;
var
  LP: TPrinter;
begin
  LP.T := ATree;
  LP.Items := nil;
  LP.Count := 0;
  if (ANode >= 0) and (ANode <= High(ATree.Nodes)) then
    LP.Emit(ANode);
  SetLength(LP.Items, LP.Count);
  Result := LP.Items;
end;

// The original text between two glued tokens reduced to its line breaks:
// nothing when they touch, a space when they do not, else one line break
// per original one - a comment or a directive in between is dropped.
function GapText(const ATree: TPasTree; AFrom, ATo: Integer): string;
var
  LA, LB: TPasVisibleToken;
  LSrc: string;
  LPos, LEnd, LBreaks: Integer;
begin
  if (AFrom < 0) or (ATo < 0) then
    Exit(' ');
  LA := ATree.Source.Visible[AFrom];
  LB := ATree.Source.Visible[ATo];
  if LA.FileId <> LB.FileId then
    Exit(sLineBreak);
  LSrc := ATree.Source.Files[LA.FileId].Source;
  LPos := ATree.Source.Files[LA.FileId].Tokens[LA.TokenIndex].EndPos;
  LEnd := ATree.Source.Files[LB.FileId].Tokens[LB.TokenIndex].Start;
  if LEnd <= LPos then
    Exit('');
  LBreaks := 0;
  while LPos < LEnd do
  begin
    // 0-based offsets into a 1-based string.
    if LSrc[LPos + 1] = #10 then
      Inc(LBreaks)
    else if (LSrc[LPos + 1] = #13) and
            ((LPos + 1 >= LEnd) or (LSrc[LPos + 2] <> #10)) then
      Inc(LBreaks);
    Inc(LPos);
  end;
  if LBreaks = 0 then
    Exit(' ');
  Result := '';
  while LBreaks > 0 do
  begin
    Result := Result + sLineBreak;
    Dec(LBreaks);
  end;
end;

function RenderItems(const ATree: TPasTree; const AItems: TPasPrintItems;
  ALayout: TPasPrintLayout; const AAt: TArray<Integer>): string;
var
  LSB: TStringBuilder;
  LIdx, LAt, LFile, LLine, LCol, LEndLine, LEndCol, LCurFile,
    LCurLine: Integer;
  LVis: TPasVisibleToken;
begin
  LSB := TStringBuilder.Create;
  try
    LCurFile := -1;
    LCurLine := 1;
    for LIdx := 0 to High(AItems) do
    begin
      if ALayout = plSource then
      begin
        LAt := AItems[LIdx].Vis;
        if (LIdx <= High(AAt)) and (AAt[LIdx] >= 0) then
          LAt := AAt[LIdx];
        if (LAt < 0) or (LAt > High(ATree.Source.Visible)) then
        begin
          // No place of its own: after the item before it.
          if (LIdx > 0) and (AItems[LIdx].Cls <> pcSeparator) then
            LSB.Append(' ');
        end
        else
        begin
          LVis := ATree.Source.Visible[LAt];
          LFile := LVis.FileId;
          with ATree.Source.Files[LFile] do
          begin
            OffsetToLineCol(Tokens[LVis.TokenIndex].Start, LLine, LCol);
            OffsetToLineCol(Tokens[LVis.TokenIndex].EndPos - 1, LEndLine,
              LEndCol);
          end;
          // The main file's lines are kept from its first line on, so the
          // print reads side by side with the source (an include's lines
          // start a new line each).
          if LCurFile < 0 then
            LCurFile := LFile;
          if AItems[LIdx].Glue and (LIdx > 0) then
            LSB.Append(GapText(ATree, AItems[LIdx - 1].Vis, AItems[LIdx].Vis))
          else if (LFile <> LCurFile) or (LLine > LCurLine) or
                  (LSB.Length = 0) then
          begin
            if LFile <> LCurFile then
              LSB.Append(sLineBreak)
            else
              while LCurLine < LLine do
              begin
                LSB.Append(sLineBreak);
                Inc(LCurLine);
              end;
            LSB.Append(StringOfChar(' ', LCol - 1));
          end
          else if LIdx > 0 then
            LSB.Append(' ');
          LCurFile := LFile;
          LCurLine := LEndLine;
        end;
      end
      else if LIdx > 0 then
        if AItems[LIdx].Glue then
          LSB.Append(GapText(ATree, AItems[LIdx - 1].Vis, AItems[LIdx].Vis))
        else if ALayout = plTokenPerLine then
          LSB.Append(sLineBreak)
        else
          LSB.Append(' ');
      LSB.Append(AItems[LIdx].Text);
    end;
    LSB.Append(sLineBreak);
    Result := LSB.ToString;
  finally
    LSB.Free;
  end;
end;

{ Ownership }

type
  // Who owns each visible token (-1: nobody), by which own-token rule, and
  // each node's own tokens in order (CSR: OwnStart[n] .. OwnStart[n + 1] - 1
  // index Own).
  TOwnership = record
    Owner, Rule: TArray<Integer>;
    OwnStart, Own: TArray<Integer>;
    procedure Build(const ATree: TPasTree);
  end;

procedure TOwnership.Build(const ATree: TPasTree);
var
  LReport: TPasCheckReport;
  LOwner, LRule: TArray<Integer>;
  LStart, LOwn, LFill: TArray<Integer>;
  LIdx, LNode: Integer;
begin
  SetLength(LOwner, Length(ATree.Source.Visible));
  SetLength(LRule, Length(ATree.Source.Visible));
  for LIdx := 0 to High(LOwner) do
  begin
    LOwner[LIdx] := -1;
    LRule[LIdx] := -1;
  end;
  LReport.Init(1);
  CheckTree(ATree, True, LReport,
    procedure(ANode, AVisIndex, ACell, ARule: Integer)
    begin
      LOwner[AVisIndex] := ANode;
      LRule[AVisIndex] := ARule;
    end);
  SetLength(LStart, Length(ATree.Nodes) + 1);
  for LIdx := 0 to High(LOwner) do
    if LOwner[LIdx] >= 0 then
      Inc(LStart[LOwner[LIdx] + 1]);
  for LIdx := 1 to High(LStart) do
    Inc(LStart[LIdx], LStart[LIdx - 1]);
  SetLength(LOwn, LStart[High(LStart)]);
  LFill := Copy(LStart);
  for LIdx := 0 to High(LOwner) do
  begin
    LNode := LOwner[LIdx];
    if LNode >= 0 then
    begin
      LOwn[LFill[LNode]] := LIdx;
      Inc(LFill[LNode]);
    end;
  end;
  Owner := LOwner;
  Rule := LRule;
  OwnStart := LStart;
  Own := LOwn;
end;

{ T3 }

type
  TOrigTok = record
    Vis: Integer;
    Text: string;
    Owner, Rule: Integer;
    Split: Integer;     // N2: 1 the `>` half of a fused `>=`, 2 the `=`
  end;

function CompareT3(const ATree: TPasTree; ARoot: Integer;
  out AResult: TPasT3Result; AMaxSites: Integer): Boolean;
var
  LOwn: TOwnership;
  LItems, LP: TPasPrintItems;
  LPFrom: TArray<Integer>;  // LP's item -> its index in LItems
  LO: TArray<TOrigTok>;
  LOAt: TArray<Integer>;    // visible index -> its first entry in LO, -1
  LOCount, LPCount, LIdx, LVis, LFirst, LLast, LI, LJ, LK: Integer;
  LOwner: Integer;

  procedure AddO(AVis: Integer; const AText: string; ASplit: Integer);
  begin
    if LOCount = Length(LO) then
      SetLength(LO, LOCount * 2 + 64);
    LO[LOCount].Vis := AVis;
    LO[LOCount].Text := AText;
    LO[LOCount].Owner := LOwn.Owner[AVis];
    LO[LOCount].Rule := LOwn.Rule[AVis];
    LO[LOCount].Split := ASplit;
    if LOAt[AVis] < 0 then
      LOAt[AVis] := LOCount;
    Inc(LOCount);
  end;

  procedure Site(AVis, AItem: Integer; const AFinding, AMsg: string);
  var
    LN: Integer;
  begin
    LN := Length(AResult.Sites);
    if LN >= AMaxSites then
      Exit;
    SetLength(AResult.Sites, LN + 1);
    AResult.Sites[LN].Vis := AVis;
    AResult.Sites[LN].Item := AItem;
    AResult.Sites[LN].Finding := AFinding;
    AResult.Sites[LN].Msg := AMsg;
  end;

  function Matches(const AItem: TPasPrintItem; const AOrig: TOrigTok): Boolean;
  begin
    if AItem.Vis >= 0 then
      Result := (AItem.Vis = AOrig.Vis) and (AOrig.Split <> 1) and
        (AItem.Text = AOrig.Text)
    else
      // N3; and the token must be the printing node's own - but the `>`
      // half of a fused `>=`, which the operator owns (N2).
      Result := (AOrig.Split <> 2) and SameText(AItem.Text, AOrig.Text) and
        ((AOrig.Owner = AItem.Node) or
         ((AOrig.Split = 1) and (ATree.Nodes[AItem.Node].Kind = nkTypeArgs)));
  end;

  function ItemText(AItem: Integer): string;
  begin
    if AItem < 0 then
      Exit('the end of the print');
    Result := Format('`%s` of %s', [LP[AItem].Text,
      ATree.KindName(ATree.Nodes[LP[AItem].Node].Kind)]);
  end;

  function OrigText(AEntry: Integer): string;
  begin
    if AEntry >= LOCount then
      Exit('the end of the original');
    Result := '`' + LO[AEntry].Text + '`';
    if LO[AEntry].Owner >= 0 then
      Result := Result + ' of ' +
        ATree.KindName(ATree.Nodes[LO[AEntry].Owner].Kind);
  end;

begin
  AResult := Default(TPasT3Result);
  if (ARoot < 0) or (ARoot > High(ATree.Nodes)) then
    Exit(False);
  LOwn.Build(ATree);
  // The original, normalized.
  LFirst := ATree.NodeLeftmostVis(ARoot);
  LLast := ATree.Nodes[ARoot].LastToken;
  SetLength(LOAt, Length(ATree.Source.Visible));
  for LIdx := 0 to High(LOAt) do
    LOAt[LIdx] := -1;
  LO := nil;
  LOCount := 0;
  for LVis := LFirst to LLast do
  begin
    Inc(AResult.Original);
    LOwner := LOwn.Owner[LVis];
    if ATree.Source.VisibleToken(LVis).Kind = tkEndOfFile then
      Inc(AResult.Normalized)                                        // N4
    else if (LOwn.Rule[LVis] >= 0) and GRuleAfterEnd[LOwn.Rule[LVis]] then
      Inc(AResult.Normalized)                                        // N5
    else if (LOwner >= 0) and (ATree.Nodes[LOwner].Kind in LIST_KINDS) and
       (ATree.Source.VisibleToken(LVis).Kind = tkSemicolon) then
      Inc(AResult.Normalized)                                        // N1
    else if (LOwner >= 0) and (ATree.Nodes[LOwner].Aux = LVis) and
       IsFusedGreaterEqual(ATree, LOwner) then
    begin
      Inc(AResult.Normalized);                                       // N2
      AddO(LVis, '>', 1);
      AddO(LVis, '=', 2);
    end
    else
      AddO(LVis, ATree.Source.VisibleText(LVis), 0);
  end;
  // The print, without its separators (N1).
  LItems := PrintNode(ATree, ARoot);
  SetLength(LP, Length(LItems));
  SetLength(LPFrom, Length(LItems));
  SetLength(AResult.ItemAt, Length(LItems));
  LPCount := 0;
  for LIdx := 0 to High(LItems) do
  begin
    AResult.ItemAt[LIdx] := -1;
    if LItems[LIdx].Cls <> pcSeparator then
    begin
      LP[LPCount] := LItems[LIdx];
      LPFrom[LPCount] := LIdx;
      Inc(LPCount);
    end;
  end;
  SetLength(LP, LPCount);
  AResult.Printed := LPCount;
  // Side by side; a filed loss skips its token, a defect resynchronizes at
  // the next printed item that was read from a token.
  LI := 0;
  LJ := 0;
  while (LI < LPCount) or (LJ < LOCount) do
  begin
    if (LI < LPCount) and (LJ < LOCount) and Matches(LP[LI], LO[LJ]) then
    begin
      Inc(AResult.Matched);
      AResult.ItemAt[LPFrom[LI]] := LO[LJ].Vis;
      if LP[LI].Cls = pcSpan then
        Inc(AResult.Spans);
      Inc(LI);
      Inc(LJ);
      Continue;
    end;
    if (LJ < LOCount) and (LO[LJ].Rule >= 0) and
       (GRuleFinding[LO[LJ].Rule] <> '') then
    begin
      Inc(AResult.Losses);
      Site(LO[LJ].Vis, LI, GRuleFinding[LO[LJ].Rule],
        Format('%s is not printed: a filed loss', [OrigText(LJ)]));
      Inc(LJ);
      Continue;
    end;
    Inc(AResult.Defects);
    if LJ < LOCount then
      LVis := LO[LJ].Vis
    else
      LVis := -1;
    if LI < LPCount then
      Site(LVis, LI, '', Format('printed %s where the original has %s',
        [ItemText(LI), OrigText(LJ)]))
    else
      Site(LVis, -1, '', Format('the print ends where the original has %s',
        [OrigText(LJ)]));
    // Resync: the next printed item read from a token still ahead.
    LK := LI + 1;
    while (LK < LPCount) and
          ((LP[LK].Vis < 0) or (LOAt[LP[LK].Vis] < LJ)) do
      Inc(LK);
    if LK >= LPCount then
      Break;
    LI := LK;
    LJ := LOAt[LP[LK].Vis];
  end;
  Result := AResult.Defects = 0;
end;

{ T3r }

function StripWhitespace(const AText: string): string;
var
  LIdx, LLen: Integer;
begin
  SetLength(Result, Length(AText));
  LLen := 0;
  for LIdx := 1 to Length(AText) do
    if not CharInSet(AText[LIdx], [' ', #9, #10, #13]) then
    begin
      Inc(LLen);
      Result[LLen] := AText[LIdx];
    end;
  SetLength(Result, LLen);
end;

function TreeFingerprint(const ATree: TPasTree): TArray<string>;
var
  LNodes: TArray<Integer>;
begin
  Result := TreeFingerprint(ATree, LNodes);
end;

function TreeFingerprint(const ATree: TPasTree;
  out ANodes: TArray<Integer>): TArray<string>;
var
  LOwn: TOwnership;
  LStack, LDepth: TArray<Integer>;
  LTop, LNode, LDep, LCount, LIdx, LVis, LChild, LN: Integer;
  LLine, LText: string;
  LKind: TPasNodeKind;
  LKids: TArray<Integer>;
begin
  Result := nil;
  ANodes := nil;
  if Length(ATree.Nodes) = 0 then
    Exit;
  LOwn.Build(ATree);
  SetLength(Result, Length(ATree.Nodes));
  SetLength(ANodes, Length(ATree.Nodes));
  LCount := 0;
  SetLength(LStack, 64);
  SetLength(LDepth, 64);
  LStack[0] := 0;
  LDepth[0] := 0;
  LTop := 1;
  while LTop > 0 do
  begin
    Dec(LTop);
    LNode := LStack[LTop];
    LDep := LDepth[LTop];
    LKind := ATree.Nodes[LNode].Kind;
    LLine := StringOfChar(' ', LDep) + ATree.KindName(LKind);
    if nfNegated in ATree.Nodes[LNode].Flags then
      LLine := LLine + '!';
    if nfName in ATree.Nodes[LNode].Flags then
      LLine := LLine + '#name';
    if nfError in ATree.Nodes[LNode].Flags then
      LLine := LLine + '#error';
    case LKind of
      nkUnaryOp, nkBinaryOp:
        if IsFusedGreaterEqual(ATree, LNode) then
          LLine := LLine + ' op=='
        else
          LLine := LLine + ' op=' +
            LowerCase(ATree.Source.VisibleText(ATree.Nodes[LNode].Aux));
      nkParam:
        if ATree.Nodes[LNode].Aux >= 0 then
          LLine := LLine + ' out';
    else
      LLine := LLine + ' aux=' + IntToStr(ATree.Nodes[LNode].Aux);
    end;
    // The own tokens, but a template's regenerated ones.
    if (LKind in LEAF_KINDS) or (LKind = nkAsmStmt) or
       not (LKind in TEMPLATED_KINDS) then
      for LIdx := LOwn.OwnStart[LNode] to LOwn.OwnStart[LNode + 1] - 1 do
      begin
        LVis := LOwn.Own[LIdx];
        if (ATree.Source.VisibleToken(LVis).Kind = tkEndOfFile) or
           ((LOwn.Rule[LVis] >= 0) and GRuleAfterEnd[LOwn.Rule[LVis]]) then
          Continue;
        LText := ATree.Source.VisibleText(LVis);
        if IsKeyword(ATree.Source.VisibleToken(LVis).Kind) then
          LText := LowerCase(LText);
        // An asm range is its text, whitespace aside: where the lexer cuts
        // it into chunks depends on the directives around it (an `asm` in
        // a dead branch, F26 in the plan), never on the tree - and the
        // print has no directives.
        if LKind = nkAsmStmt then
          LLine := LLine + StripWhitespace(LText)
        else
          LLine := LLine + ' ' + LText;
      end;
    Result[LCount] := LLine;
    ANodes[LCount] := LNode;
    Inc(LCount);
    // Children pushed in reverse, so they pop in order.
    LKids := nil;
    LN := 0;
    LChild := ATree.Nodes[LNode].FirstChild;
    while LChild <> NIL_NODE do
    begin
      if LN = Length(LKids) then
        SetLength(LKids, LN * 2 + 4);
      LKids[LN] := LChild;
      Inc(LN);
      LChild := ATree.Nodes[LChild].NextSibling;
    end;
    for LIdx := LN - 1 downto 0 do
    begin
      if LTop = Length(LStack) then
      begin
        SetLength(LStack, LTop * 2);
        SetLength(LDepth, LTop * 2);
      end;
      LStack[LTop] := LKids[LIdx];
      LDepth[LTop] := LDep + 1;
      Inc(LTop);
    end;
  end;
  SetLength(Result, LCount);
  SetLength(ANodes, LCount);
end;

function CheckT3r(const ATree: TPasTree; const AReparse: TPasReparse;
  out AMsg: string): Boolean;
const
  LAYOUT_NAMES: array[TPasPrintLayout] of string = ('one-line',
    'token-per-line', 'source');
var
  LItems: TPasPrintItems;
  LOrig: TArray<string>;
  LOrigNodes: TArray<Integer>;
  LLayout: TPasPrintLayout;

  // Where in the ORIGINAL the item the reparse's visible token AVis stands
  // for was read: the item itself or the nearest one before it read from a
  // token (a regenerated keyword has none). Items and the reparse's tokens
  // correspond one to one - but for an asm range, whose chunks the lexer
  // cuts anew.
  function NearSite(AVis: Integer): string;
  var
    LItem: Integer;
  begin
    LItem := AVis;
    if LItem > High(LItems) then
      LItem := High(LItems);
    while (LItem >= 0) and (LItems[LItem].Vis < 0) do
      Dec(LItem);
    if LItem < 0 then
      Exit(VisSiteText(ATree.Source, 0));
    Result := VisSiteText(ATree.Source, LItems[LItem].Vis);
  end;

  function OneLayout(ALayout: TPasPrintLayout): string;
  var
    LText, LFirstDiag, LA, LB: string;
    LTree: TPasTree;
    LBack: TArray<string>;
    LBackNodes: TArray<Integer>;
    LDiags, LDiagVis, LIdx: Integer;
  begin
    Result := '';
    LText := RenderItems(ATree, LItems, ALayout);
    if not AReparse(LText, LTree, LDiags, LDiagVis, LFirstDiag) then
      Exit(Format('%s: the print could not be parsed back',
        [LAYOUT_NAMES[ALayout]]));
    if LDiags > 0 then
      Exit(Format('%s: the print parses with %d diagnostics, the first near ' +
        '%s: %s', [LAYOUT_NAMES[ALayout], LDiags, NearSite(LDiagVis),
        LFirstDiag]));
    LBack := TreeFingerprint(LTree, LBackNodes);
    for LIdx := 0 to Length(LOrig) do
    begin
      if LIdx < Length(LOrig) then
        LA := LOrig[LIdx]
      else
        LA := '<end>';
      if LIdx < Length(LBack) then
        LB := LBack[LIdx]
      else
        LB := '<end>';
      if LA <> LB then
      begin
        if LIdx < Length(LOrigNodes) then
          LText := VisSiteText(ATree.Source,
            ATree.NodeLeftmostVis(LOrigNodes[LIdx]))
        else
          LText := VisSiteText(ATree.Source, High(ATree.Source.Visible));
        Exit(Format('%s: the print parses to another tree at %s:' +
          sLineBreak + '    original: %s' + sLineBreak + '    reparsed: %s',
          [LAYOUT_NAMES[ALayout], LText, Trim(LA), Trim(LB)]));
      end;
    end;
  end;

var
  LOne: string;
begin
  AMsg := '';
  LItems := PrintNode(ATree, 0);
  LOrig := TreeFingerprint(ATree, LOrigNodes);
  // Both layouts, each on its own: a layout the parser misreads must not
  // hide what the other shows.
  for LLayout := plTokenPerLine downto plOneLine do
  begin
    LOne := OneLayout(LLayout);
    if LOne = '' then
      Continue;
    if AMsg <> '' then
      AMsg := AMsg + sLineBreak + '    ';
    AMsg := AMsg + LOne;
  end;
  Result := AMsg = '';
end;

initialization
  InitRules;
end.
