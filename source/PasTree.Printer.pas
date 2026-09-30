unit PasTree.Printer;

{
  PasTree - the structural printer (parser fidelity, phase 3).

  NodeSpanText prints a node from its span: lossless by construction, and it
  tests nothing. This printer regenerates the source from the TREE: keywords
  and punctuation from Kind, Aux, Flags and the order of the children, text
  only from a leaf's own tokens and from the contract reads of the own-token
  table (PasTree.Ast.Check) - the head word of a routine, a directive, a
  property specifier, a const or var section and a constraint, the operator
  token an nkUnaryOp's or nkBinaryOp's Aux names, and asm's opaque range.

  Every kind has a template but nkError (and the retired nkAnonParams),
  which print FROM THEIR SPAN: own tokens verbatim, children through their
  templates, the items marked pcSpan. Valid code has none.

  What the tree does not hold - the filed LOSSES of the own-token table
  (a parameter's `var` / `const`, `class sealed`, a numeric label, ...) -
  the printer reads from the token that holds it, at its place among
  the node's children, and marks it pcLoss. So the print is the same
  program, T3r can judge every file, and the loss list is exactly the set of
  pcLoss items: T3 counts them per finding and reports a filed loss the
  print did NOT read as a defect.

  The canonical form. Where the grammar allows several spellings of one tree
  the printer writes one of them:
  - one `;` between the statements of a list, none before the first or after
    the last; one after every case selector and every exception handler,
    the last included - it keeps a case's or an except part's `else` from
    reading as an if's (`1: if C then A; else B`);
  - one `;` after every field of a record, class, object or variant, every
    declaration of a var section, every variant, a routine's header, each
    of its directives and its body, a property's specifiers;
  - keywords in lower case;
  - a `>=` the lexer fused from type arguments' or generic parameters'
    closing `>` and an `=` (`V.AsType<T>=5`, `TFoo<T>= class`) as the two
    tokens it stands for;
  - a unit's `begin ... end.` as `initialization ... end.`;
  - `class(TBase);` as `class(TBase) end;`;
  - a procedural type's directives after its `of object`, behind a `;` when
    a calling convention, far or near starts them (`procedure; stdcall`,
    the one form a following declaration named like a convention cannot
    join) and written into the type otherwise (`procedure varargs`, and
    after `reference to`, which takes no `;`);
  - no `;` after a record constant's last field value;
  - one bracket pair per attribute group, `[A, B]`, and no `()` after an
    attribute without arguments.
  The comparison maps the ORIGINAL onto the same form - PRINT_NORMALIZATION,
  one entry per rule with its reason - and does nothing else.

  T3 (CompareT3): the printed items against the visible stream, one by one.
  A regenerated keyword or punctuation matches a token of the same text
  (case-insensitively) that its own node owns - or, for the few tokens the
  own-token table gives to a parent (`class` before a member, a struct's
  `var`, `reference to`), that parent; a leaf, contract, loss or span item
  matches the very token it was read from. Anything else is a DEFECT.

  T3r (CheckT3r): parse(print(tree)) = tree. The print is rendered in two
  layouts, one token per line and everything on one line, and each is parsed
  back; both trees must fingerprint (TreeFingerprint) exactly as the
  original. It compares the parser with itself, so it is blind to what both
  parses share - a consistent misreading: that takes dcc. What it shows is
  that the canonical form is the same program for the parser, and that the
  tree of valid code does not depend on its layout (some recovery
  heuristics read line breaks).

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
    pcSeparator,   // a list's `;`: derived, but T3 compares the lists without
                   // them (PRINT_NORMALIZATION, N1)
    pcLeaf,        // a leaf node's own token: a name or a literal
    pcContract,    // read from a token by a documented rule: a head word, the
                   // operator an Aux names, asm's opaque range
    pcLoss,        // read from a token that holds a fact the tree does not: a
                   // filed loss of the own-token table
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
  PRINT_NORMALIZATION: array[0..10] of string = (
    'N1 list separators: every `;` a statement or declaration list owns ' +
      '(nkBlock, nkCaseStmt, nkExceptPart, nkInitSec, nkFinalSec; nkClassType, ' +
      'nkRecordType, nkObjectType, nkHelperType, nkInterfaceType, ' +
      'nkVariantPart, nkVariantBranch, nkVarSec, nkRoutine, nkPropertyDecl) ' +
      'is dropped, and so is every separator the printer writes - a run of ' +
      'them is one, the one before end / else / until / ) is optional, a ' +
      'routine''s directive may stand before its header''s `;` or after it, ' +
      'and the canonical ones are derived from the children',
    'N2 fused >=: the `>=` an nkBinaryOp names when type arguments on its ' +
      'left ended in it (`V.AsType<T>=5`), and the one an nkTypeDecl owns ' +
      'after generic parameters (`TFoo<T>= class`), are the `>` closing them ' +
      'and the `=`: the lexer fused two tokens the grammar reads apart',
    'N3 keyword case: a regenerated keyword, directive word or punctuation ' +
      'matches its token case-insensitively (dcc reads them so); leaves and ' +
      'tokens read as written match exactly',
    'N4 the <eof> sentinel a root span ends on is no token of the source',
    'N5 text after the final `end.` is ignored by dcc; the root owns its ' +
      'first token only (csAfterEnd)',
    'N6 insignificant tokens (class insig of the own-token table) are ' +
      'dropped: the `()` of an attribute without arguments, `[A()]` = `[A]`',
    'N7 retired (F30): a unit''s `begin ... end.` and `initialization ... ' +
      'end.` give other .dcu line records, so the head word of nkInitSec is ' +
      'a contract read, printed as written',
    'N8 attribute groups: `][` inside one nkAttrGroup reads as `,` - the ' +
      'tree keeps one group, `[A][B]` = `[A, B]`',
    'N9 `class(TBase);` - a class, object or interface type that stops at ' +
      'its ancestors - declares the type `class(TBase) end` does: a virtual ' +
      '`end` after its last token',
    'N10 a procedural type''s directives written before its `of object` ' +
      '(`procedure stdcall of object`) are the type''s as the ones after it ' +
      'are (dcc64 37.0): the `of object` reads as if it stood before the ' +
      'first of them',
    'N11 a record constant''s last field value may be followed by a `;` ' +
      'before its `)`, `(X: 1; Y: 2;)` (dcc64 37.0 compiles it): an ' +
      'nkAggregate''s `;` right before its `)` is dropped'
  );

{ The kinds the printer has a template for: every kind but nkError and the
  retired nkAnonParams, which print from their span (pcSpan). }
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

  // One filed loss finding the print read: how many tokens, the first one.
  TPasT3Loss = record
    Finding: string;
    Count: Integer;
    FirstVis: Integer;
  end;

  TPasT3Result = record
    Original: Integer;   // tokens in the root's span
    Normalized: Integer; // of them dropped, split or moved by PRINT_NORMALIZATION
    Printed: Integer;    // printed items compared (separators excluded)
    Matched: Integer;    // printed items that matched their token
    Spans: Integer;      // of them copied by a node without a template
    Losses: Integer;     // of them read as a filed loss
    LossCounts: TArray<TPasT3Loss>;   // the losses per finding
    Defects: Integer;    // mismatches nothing explains
    Sites: TArray<TPasT3Site>;   // the first defects, the first loss of each
                                 // finding
    // Per item of PrintNode's list (separators included): the visible token
    // it matched, -1 when none - the layout plSource reads.
    ItemAt: TArray<Integer>;
  end;

{ T3 over the subtree of ARoot (0: the whole tree). True when no defect was
  found; AResult.Sites keeps the first AMaxSites defects and the first loss
  of each finding. }
function CompareT3(const ATree: TPasTree; ARoot: Integer;
  out AResult: TPasT3Result; AMaxSites: Integer = 20): Boolean;

{ One line per reachable node, preorder, indented by depth: the kind, its
  flags, its Aux (an operator's by the operator's text, a parameter's `out`
  by the word - never a token index) and the texts of its own tokens that
  are facts - a leaf's, a contract read's, a filed loss's, and every own
  token of a kind without a template; regenerated tokens do not count. Two
  trees of one program in two layouts fingerprint alike. ANodes[i] is the
  node of line i. }
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
  // Print from their span: no template.
  SPAN_KINDS = [nkError, nkAnonParams];
  // Leaves print their own tokens; their texts are the node.
  LEAF_KINDS = [nkIdent, nkIntLit, nkRealLit, nkStrLit, nkCaretChar];
  // The lists whose `;` are separators (N1).
  LIST_KINDS = [nkBlock, nkCaseStmt, nkExceptPart, nkInitSec, nkFinalSec,
    nkClassType, nkRecordType, nkObjectType, nkHelperType, nkInterfaceType,
    nkVariantPart, nkVariantBranch, nkVarSec, nkRoutine, nkPropertyDecl];
  ZERO_WIDTH = [nkEmptyStmt, nkMissing];
  UNIT_KINDS = [nkUnit, nkProgram, nkLibrary, nkPackage];
  // The bodies whose members may be `class` ones, and whose var sections
  // have their head word outside their span (the own-token table).
  STRUCT_KINDS = [nkClassType, nkRecordType, nkObjectType, nkHelperType,
    nkInterfaceType];
  // A type reference: an ancestor, a helper's target.
  TYPEREF_KINDS = [nkIdent, nkMember, nkTypeArgs, nkError];
  // What a struct body holds before its `end`.
  MEMBER_KINDS = [nkVisibility, nkAttrGroup, nkRoutine, nkPropertyDecl,
    nkTypeSec, nkConstSec, nkVarSec, nkVarDecl, nkVariantPart,
    nkMethodResolution];
  VISIBILITY_TEXT: array[1..5] of string = ('private', 'protected', 'public',
    'published', 'automated');

var
  // Per own-token rule, read once: its class, a loss's finding ('' for any
  // other class), and whether it is the text-after-end rule.
  GRuleCls: TArray<TPasOwnClass>;
  GRuleFinding: TArray<string>;
  GRuleAfterEnd: TArray<Boolean>;

procedure InitRules;
var
  LIdx: Integer;
  LRule: TPasOwnRule;
begin
  SetLength(GRuleCls, OwnRuleCount);
  SetLength(GRuleFinding, OwnRuleCount);
  SetLength(GRuleAfterEnd, OwnRuleCount);
  for LIdx := 0 to OwnRuleCount - 1 do
  begin
    LRule := OwnRule(LIdx);
    GRuleCls[LIdx] := LRule.Cls;
    if LRule.Cls = ocLoss then
      GRuleFinding[LIdx] := LRule.Finding;
    GRuleAfterEnd[LIdx] := LRule.Cond = wcAfterEnd;
  end;
end;

function IsLossRule(ARule: Integer): Boolean; inline;
begin
  Result := (ARule >= 0) and (GRuleCls[ARule] = ocLoss);
end;

function PasTemplatedKind(AKind: TPasNodeKind): Boolean;
begin
  Result := not (AKind in SPAN_KINDS);
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

{ TPrinter }

type
  TPrinter = record
    T: TPasTree;
    Own: TOwnership;
    // Per node: the next of its own tokens Losses has not looked at.
    LossPos: TArray<Integer>;
    Items: TPasPrintItems;
    Count: Integer;
    function Kind(ANode: Integer): TPasNodeKind; inline;
    function Next(ANode: Integer): Integer; inline;
    function Left(ANode: Integer): Integer;
    procedure Add(const AText: string; ACls: TPasPrintClass; ANode,
      AVis: Integer; AGlue: Boolean);
    procedure Kw(const AText: string; ANode: Integer);
    procedure Sep(ANode: Integer);
    procedure Tok(AVis: Integer; ACls: TPasPrintClass; ANode: Integer;
      AGlue: Boolean);
    procedure Head(ANode: Integer);
    procedure OwnRange(ANode: Integer; ACls: TPasPrintClass; AGlued: Boolean);
    procedure Losses(ANode, ALimit: Integer);
    function NextLoss(ANode: Integer): Integer;
    procedure Child(ANode, AChild: Integer);
    procedure Span(ANode: Integer);
    procedure ListFrom(AChild: Integer; const ASep: string; AParent: Integer);
    function ListUntil(AChild, AStop: Integer; const ASep: string;
      AParent: Integer): Integer;
    procedure Block(ANode: Integer);
    procedure Statements(ANode: Integer);
    procedure InlineDecl(ANode: Integer; AConst: Boolean);
    procedure AnonMethod(ANode: Integer);
    // declarations
    procedure Decls(ANode, AChild, AStop: Integer);
    function TrailingFrom(AChild: Integer): Integer;
    procedure UnitLike(ANode: Integer);
    procedure UsesClause(ANode: Integer);
    procedure LabelSec(ANode: Integer);
    procedure TypeDecl(ANode: Integer);
    procedure ConstDecl(ANode: Integer);
    procedure VarSec(ANode: Integer);
    procedure VarDecl(ANode: Integer);
    procedure Aggregate(ANode: Integer);
    procedure ArrayType(ANode: Integer);
    procedure ProcType(ANode: Integer);
    procedure StructType(ANode: Integer);
    procedure Routine(ANode: Integer);
    function RoutineName(ANode, AChild: Integer): Integer;
    procedure Params(ANode: Integer);
    procedure Param(ANode: Integer);
    procedure PropertyDecl(ANode: Integer);
    procedure PropSpec(ANode: Integer);
    procedure VariantPart(ANode: Integer);
    procedure VariantBranch(ANode: Integer);
    procedure GenericParam(ANode: Integer);
    procedure Emit(ANode: Integer);
  end;

function TPrinter.Kind(ANode: Integer): TPasNodeKind;
begin
  Result := T.Nodes[ANode].Kind;
end;

function TPrinter.Next(ANode: Integer): Integer;
begin
  Result := T.Nodes[ANode].NextSibling;
end;

function TPrinter.Left(ANode: Integer): Integer;
begin
  Result := T.NodeLeftmostVis(ANode);
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

// The head word at FirstToken: a contract read.
procedure TPrinter.Head(ANode: Integer);
begin
  Tok(T.Nodes[ANode].FirstToken, pcContract, ANode, False);
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

{ ANode's own tokens that hold a filed loss, from where the last call
  stopped up to (not including) the visible index ALimit, read as written.
  Templates call it where such a token stands among their children - Child
  before every child, and Emit once more at the node's end. }
procedure TPrinter.Losses(ANode, ALimit: Integer);
var
  LPos, LVis: Integer;
begin
  LPos := LossPos[ANode];
  while LPos < Own.OwnStart[ANode + 1] do
  begin
    LVis := Own.Own[LPos];
    if LVis >= ALimit then
      Break;
    if IsLossRule(Own.Rule[LVis]) then
      Tok(LVis, pcLoss, ANode, False);
    Inc(LPos);
  end;
  LossPos[ANode] := LPos;
end;

// The visible index of ANode's next own loss token Losses has not read; -1
// when none is left. Reads nothing.
function TPrinter.NextLoss(ANode: Integer): Integer;
var
  LPos: Integer;
begin
  LPos := LossPos[ANode];
  while LPos < Own.OwnStart[ANode + 1] do
  begin
    if IsLossRule(Own.Rule[Own.Own[LPos]]) then
      Exit(Own.Own[LPos]);
    Inc(LPos);
  end;
  Result := -1;
end;

// One child of ANode: the losses of ANode before it, then the child.
procedure TPrinter.Child(ANode, AChild: Integer);
begin
  if AChild = NIL_NODE then
    Exit;
  if not IsEmptyNode(T, AChild) then
    Losses(ANode, Left(AChild));
  Emit(AChild);
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
begin
  ListUntil(AChild, NIL_NODE, ASep, AParent);
end;

// AChild and its siblings up to (not including) AStop, ASep between them;
// AStop is returned.
function TPrinter.ListUntil(AChild, AStop: Integer; const ASep: string;
  AParent: Integer): Integer;
var
  LFirst: Boolean;
begin
  LFirst := True;
  while (AChild <> NIL_NODE) and (AChild <> AStop) do
  begin
    if not LFirst then
      Kw(ASep, AParent);
    Child(AParent, AChild);
    LFirst := False;
    AChild := Next(AChild);
  end;
  Result := AStop;
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
  LParent: Integer;
  LHead, LTail: string;
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
  Statements(ANode);
  if LTail <> '' then
    Kw(LTail, ANode);
end;

// ANode's children as a statement list: one separator between them.
procedure TPrinter.Statements(ANode: Integer);
var
  LChild: Integer;
  LFirst: Boolean;
begin
  LFirst := True;
  LChild := T.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if not LFirst then
      Sep(ANode);
    Emit(LChild);
    LFirst := False;
    LChild := Next(LChild);
  end;
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
    LChild := Next(LChild);
  end;
  LInit := T.Nodes[ANode].Aux = 1;
  LRest := 0;
  if LChild <> NIL_NODE then
    LRest := 1 + Ord(Next(LChild) <> NIL_NODE);
  // Two children after the names: the type, then the value. One: the value
  // when Aux says so, else the type.
  if (LRest = 2) or ((LRest = 1) and not LInit) then
  begin
    Kw(':', ANode);
    Emit(LChild);
    LChild := Next(LChild);
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
  is there. }
procedure TPrinter.AnonMethod(ANode: Integer);
var
  LChild: Integer;
  LFunction: Boolean;
begin
  LFunction := False;
  LChild := T.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if not (Kind(LChild) in [nkParams, nkDirective, nkRoutineBody]) then
      LFunction := True;
    LChild := Next(LChild);
  end;
  if LFunction then
    Kw('function', ANode)
  else
    Kw('procedure', ANode);
  LChild := T.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if not (Kind(LChild) in [nkParams, nkDirective, nkRoutineBody]) then
      Kw(':', ANode);
    Emit(LChild);
    LChild := Next(LChild);
  end;
end;

{ ---- declarations ---- }

{ A declaration list from AChild up to (not including) AStop: a section's,
  a routine body's, a unit's, a struct body's or a variant's. A member with
  Aux 1 is a `class` one, and the `class` is the list owner's token; so is a
  struct body's var section's head, `var` - or `threadvar`, a filed loss
  (F9). A field is followed by a separator. }
procedure TPrinter.Decls(ANode, AChild, AStop: Integer);
var
  LKind: TPasNodeKind;
  LStruct, LFields: Boolean;
  LBefore: Integer;
begin
  LStruct := Kind(ANode) in STRUCT_KINDS;
  LFields := LStruct or (Kind(ANode) = nkVariantBranch);
  while (AChild <> NIL_NODE) and (AChild <> AStop) do
  begin
    LKind := Kind(AChild);
    if (LKind in [nkRoutine, nkPropertyDecl, nkVarSec]) and
       (T.Nodes[AChild].Aux = 1) then
      Kw('class', ANode);
    if LStruct and (LKind = nkVarSec) then
    begin
      LBefore := Left(AChild) - 1;
      if (LBefore >= 0) and (Own.Owner[LBefore] = ANode) and
         IsLossRule(Own.Rule[LBefore]) then
        Losses(ANode, LBefore + 1)
      else
        Kw('var', ANode);
    end;
    Child(ANode, AChild);
    if LFields and (LKind = nkVarDecl) then
      Sep(ANode);
    AChild := Next(AChild);
  end;
end;

// The first of AChild and its siblings from which on no member follows: a
// struct's `align` expression and its hints after `end`.
function TPrinter.TrailingFrom(AChild: Integer): Integer;
begin
  Result := NIL_NODE;
  while AChild <> NIL_NODE do
  begin
    if Kind(AChild) in MEMBER_KINDS then
      Result := NIL_NODE
    else if Result = NIL_NODE then
      Result := AChild;
    AChild := Next(AChild);
  end;
end;

{ unit Name [hints]; sections end.
  program Name [params: F17]; [uses] declarations [begin ...] end.
  package Name; requires/contains clauses end. }
procedure TPrinter.UnitLike(ANode: Integer);
var
  LChild: Integer;
begin
  case Kind(ANode) of
    nkUnit: Kw('unit', ANode);
    nkProgram: Kw('program', ANode);
    nkLibrary: Kw('library', ANode);
  else
    Kw('package', ANode);
  end;
  LChild := T.Nodes[ANode].FirstChild;
  Child(ANode, LChild);
  if LChild <> NIL_NODE then
    LChild := Next(LChild);
  if Kind(ANode) = nkUnit then
    while (LChild <> NIL_NODE) and (Kind(LChild) = nkDirective) do
    begin
      Child(ANode, LChild);
      LChild := Next(LChild);
    end;
  // A program's parameters (F17) stand before the `;`.
  if LChild <> NIL_NODE then
    Losses(ANode, Left(LChild))
  else
    Losses(ANode, T.Nodes[ANode].LastToken);
  Kw(';', ANode);
  Decls(ANode, LChild, NIL_NODE);
  Kw('end', ANode);
  Kw('.', ANode);
end;

procedure TPrinter.UsesClause(ANode: Integer);
var
  LParent: Integer;
begin
  LParent := T.Nodes[ANode].Parent;
  if (LParent <> NIL_NODE) and (Kind(LParent) = nkPackage) then
  begin
    if T.Nodes[ANode].Aux = 1 then
      Kw('requires', ANode)
    else
      Kw('contains', ANode);
  end
  else
    Kw('uses', ANode);
  ListFrom(T.Nodes[ANode].FirstChild, ',', ANode);
  Kw(';', ANode);
end;

// `label` labels `;` - a name label is a child, a numeric one a filed loss
// (F16): both in their order, commas between.
procedure TPrinter.LabelSec(ANode: Integer);
var
  LChild, LLoss: Integer;
  LFirst: Boolean;
begin
  Kw('label', ANode);
  LChild := T.Nodes[ANode].FirstChild;
  LFirst := True;
  while True do
  begin
    LLoss := NextLoss(ANode);
    if (LChild = NIL_NODE) and (LLoss < 0) then
      Break;
    if not LFirst then
      Kw(',', ANode);
    LFirst := False;
    if (LChild <> NIL_NODE) and ((LLoss < 0) or (Left(LChild) < LLoss)) then
    begin
      Emit(LChild);
      LChild := Next(LChild);
    end
    else
      Losses(ANode, LLoss + 1);
  end;
  Kw(';', ANode);
end;

{ [attributes] Name [generic params] = [type] Type [hints]; Aux 1 is the
  distinct alias `= type X`. `packed` before the type is the type's to print
  (nfPacked, Emit). }
procedure TPrinter.TypeDecl(ANode: Integer);
var
  LChild: Integer;
begin
  LChild := T.Nodes[ANode].FirstChild;
  while (LChild <> NIL_NODE) and (Kind(LChild) = nkAttrGroup) do
  begin
    Child(ANode, LChild);
    LChild := Next(LChild);
  end;
  Child(ANode, LChild);
  if LChild <> NIL_NODE then
    LChild := Next(LChild);
  if (LChild <> NIL_NODE) and (Kind(LChild) = nkGenericParams) then
  begin
    Child(ANode, LChild);
    LChild := Next(LChild);
  end;
  Kw('=', ANode);
  if T.Nodes[ANode].Aux = 1 then
    Kw('type', ANode);
  while LChild <> NIL_NODE do
  begin
    Child(ANode, LChild);
    LChild := Next(LChild);
  end;
end;

// [attributes] Name [: Type] = value [hints].
procedure TPrinter.ConstDecl(ANode: Integer);
var
  LChild, LAfter: Integer;
begin
  LChild := T.Nodes[ANode].FirstChild;
  while (LChild <> NIL_NODE) and (Kind(LChild) = nkAttrGroup) do
  begin
    Child(ANode, LChild);
    LChild := Next(LChild);
  end;
  Child(ANode, LChild);
  if LChild <> NIL_NODE then
    LChild := Next(LChild);
  if LChild <> NIL_NODE then
  begin
    LAfter := Next(LChild);
    if (LAfter <> NIL_NODE) and (Kind(LAfter) <> nkDirective) then
    begin
      Kw(':', ANode);
      Child(ANode, LChild);
      LChild := LAfter;
    end;
  end;
  Kw('=', ANode);
  while LChild <> NIL_NODE do
  begin
    Child(ANode, LChild);
    LChild := Next(LChild);
  end;
end;

{ The head word - but in a struct body, where the list owner prints it - and
  every declaration with a separator after it. }
procedure TPrinter.VarSec(ANode: Integer);
var
  LChild, LParent: Integer;
begin
  LParent := T.Nodes[ANode].Parent;
  if (LParent = NIL_NODE) or not (Kind(LParent) in STRUCT_KINDS) then
    Head(ANode);
  LChild := T.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    Child(ANode, LChild);
    if Kind(LChild) = nkVarDecl then
      Sep(ANode);
    LChild := Next(LChild);
  end;
end;

{ [attributes] names (nfName) : Type, then in their order hints and the
  initializer - `= value`, or `absolute X` when Aux is 1. }
procedure TPrinter.VarDecl(ANode: Integer);
var
  LChild: Integer;
  LFirst: Boolean;
begin
  LChild := T.Nodes[ANode].FirstChild;
  while (LChild <> NIL_NODE) and (Kind(LChild) = nkAttrGroup) do
  begin
    Child(ANode, LChild);
    LChild := Next(LChild);
  end;
  LFirst := True;
  while (LChild <> NIL_NODE) and (nfName in T.Nodes[LChild].Flags) do
  begin
    if not LFirst then
      Kw(',', ANode);
    Child(ANode, LChild);
    LFirst := False;
    LChild := Next(LChild);
  end;
  if LChild = NIL_NODE then
    Exit;
  Kw(':', ANode);
  Child(ANode, LChild);
  LChild := Next(LChild);
  while LChild <> NIL_NODE do
  begin
    if Kind(LChild) <> nkDirective then
      if T.Nodes[ANode].Aux = 1 then
        Kw('absolute', ANode)
      else
        Kw('=', ANode);
    Child(ANode, LChild);
    LChild := Next(LChild);
  end;
end;

// ( elements ): `;` after a record field's element, `,` otherwise.
procedure TPrinter.Aggregate(ANode: Integer);
var
  LChild, LPrev: Integer;
begin
  Kw('(', ANode);
  LPrev := NIL_NODE;
  LChild := T.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if LPrev <> NIL_NODE then
      if Kind(LPrev) = nkAggregateField then
        Kw(';', ANode)
      else
        Kw(',', ANode);
    Child(ANode, LChild);
    LPrev := LChild;
    LChild := Next(LChild);
  end;
  Kw(')', ANode);
end;

{ array [index types] of Element; Aux 1: array of const, every child an
  index type. }
procedure TPrinter.ArrayType(ANode: Integer);
var
  LChild, LElem: Integer;
begin
  Kw('array', ANode);
  LChild := T.Nodes[ANode].FirstChild;
  if T.Nodes[ANode].Aux = 1 then
    LElem := NIL_NODE
  else
    LElem := LastChild(T, ANode);
  if (LChild <> NIL_NODE) and (LChild <> LElem) then
  begin
    Kw('[', ANode);
    ListUntil(LChild, LElem, ',', ANode);
    Kw(']', ANode);
  end;
  Kw('of', ANode);
  if T.Nodes[ANode].Aux = 1 then
    Kw('const', ANode)
  else
    Child(ANode, LElem);
end;

{ [reference to] procedure|function [params] [: result] [of object]
  directives - `reference to` is the parent's token (Aux 2), `function` when
  a result type is there; the directives after its `of object` (N10), the
  `;` before the one with Aux 1. }
procedure TPrinter.ProcType(ANode: Integer);
var
  LChild, LParent: Integer;
  LFunction: Boolean;
begin
  if T.Nodes[ANode].Aux = 2 then
  begin
    LParent := T.Nodes[ANode].Parent;
    Kw('reference', LParent);
    Kw('to', LParent);
  end;
  LFunction := False;
  LChild := T.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if not (Kind(LChild) in [nkParams, nkDirective]) then
      LFunction := True;
    LChild := Next(LChild);
  end;
  if LFunction then
    Kw('function', ANode)
  else
    Kw('procedure', ANode);
  LChild := T.Nodes[ANode].FirstChild;
  while (LChild <> NIL_NODE) and (Kind(LChild) <> nkDirective) do
  begin
    if Kind(LChild) <> nkParams then
      Kw(':', ANode);
    Child(ANode, LChild);
    LChild := Next(LChild);
  end;
  if T.Nodes[ANode].Aux = 1 then
  begin
    Kw('of', ANode);
    Kw('object', ANode);
  end;
  // The `;` where it was written, before the directive with Aux 1 (F29: one
  // type either way, not one .dcu). The parser takes it only before a
  // convention, far or near and never after `reference to`, so the print
  // reads back as the tree: `var V: procedure; stdcall; cdecl: Integer;` is
  // two variables, `procedure stdcall; cdecl: Integer` an error.
  while LChild <> NIL_NODE do
  begin
    if T.Nodes[LChild].Aux = 1 then
      Kw(';', ANode);
    Child(ANode, LChild);
    LChild := Next(LChild);
  end;
end;

{ class / record / object / interface / helper:
    class [abstract | sealed: F4] [(ancestors)] members end [hints]
    record members end [align X] [hints]
    object [(ancestor)] members end [hints]
    interface | dispinterface [(ancestor)] [GUID] members end [hints]
    class | record helper [(ancestor)] for T members end [hints]
  A forward declaration (Aux) is the head word alone. }
procedure TPrinter.StructType(ANode: Integer);
var
  LKind: TPasNodeKind;
  LChild, LTarget, LStop, LLast: Integer;
begin
  LKind := Kind(ANode);
  case LKind of
    nkClassType: Kw('class', ANode);
    nkRecordType: Kw('record', ANode);
    nkObjectType: Kw('object', ANode);
    nkInterfaceType:
      if T.Nodes[ANode].Aux and 1 <> 0 then
        Kw('dispinterface', ANode)
      else
        Kw('interface', ANode);
  else
    if T.Nodes[ANode].Aux = 1 then
      Kw('record', ANode)
    else
      Kw('class', ANode);
    Kw('helper', ANode);
  end;
  if ((LKind = nkClassType) and (T.Nodes[ANode].Aux = 1)) or
     ((LKind = nkInterfaceType) and (T.Nodes[ANode].Aux and 2 <> 0)) then
    Exit;
  // `class sealed` / `class abstract` (F4) follow the head word.
  LLast := T.Nodes[ANode].FirstToken + 1;
  while (LLast <= T.Nodes[ANode].LastToken) and
        (Own.Owner[LLast] = ANode) and IsLossRule(Own.Rule[LLast]) do
    Inc(LLast);
  Losses(ANode, LLast);
  LChild := T.Nodes[ANode].FirstChild;
  // The leading type references: the ancestors; a helper's last one is its
  // target.
  if LKind <> nkRecordType then
  begin
    LLast := NIL_NODE;
    LStop := LChild;
    while (LStop <> NIL_NODE) and (Kind(LStop) in TYPEREF_KINDS) do
    begin
      LLast := LStop;
      LStop := Next(LStop);
    end;
    LTarget := LStop;
    if LKind = nkHelperType then
      LTarget := LLast;
    if (LChild <> NIL_NODE) and (LChild <> LTarget) then
    begin
      Kw('(', ANode);
      ListUntil(LChild, LTarget, ',', ANode);
      Kw(')', ANode);
    end;
    if LKind = nkHelperType then
    begin
      Kw('for', ANode);
      Child(ANode, LTarget);
    end;
    LChild := LStop;
    if (LChild <> NIL_NODE) and (Kind(LChild) = nkGuid) then
    begin
      Child(ANode, LChild);
      LChild := Next(LChild);
    end;
  end;
  LStop := TrailingFrom(LChild);
  Decls(ANode, LChild, LStop);
  Kw('end', ANode);
  LChild := LStop;
  if (LChild <> NIL_NODE) and (Kind(LChild) <> nkDirective) then
  begin
    Kw('align', ANode);
    Child(ANode, LChild);
    LChild := Next(LChild);
  end;
  while LChild <> NIL_NODE do
  begin
    Child(ANode, LChild);
    LChild := Next(LChild);
  end;
end;

// A routine's or a method resolution's dotted name from AChild: segments
// (nfName) with their generic parameters, `.` between. Returns the child
// after it.
function TPrinter.RoutineName(ANode, AChild: Integer): Integer;
var
  LFirst: Boolean;
begin
  LFirst := True;
  while (AChild <> NIL_NODE) and ((nfName in T.Nodes[AChild].Flags) or
        (Kind(AChild) = nkGenericParams)) do
  begin
    if nfName in T.Nodes[AChild].Flags then
    begin
      if not LFirst then
        Kw('.', ANode);
      LFirst := False;
    end;
    Child(ANode, AChild);
    AChild := Next(AChild);
  end;
  Result := AChild;
end;

{ head Name [params] [: result]; directive; ... [body;] - the head word read
  (a `class` before it is the list owner's), a separator after the header,
  every directive and the body (N1: a directive written before the header's
  `;` is the same directive). }
procedure TPrinter.Routine(ANode: Integer);
var
  LChild: Integer;
  LHeader: Boolean;
begin
  Head(ANode);
  LChild := RoutineName(ANode, T.Nodes[ANode].FirstChild);
  LHeader := True;
  while LChild <> NIL_NODE do
  begin
    case Kind(LChild) of
      nkParams:
        Child(ANode, LChild);
      nkDirective, nkRoutineBody:
        begin
          if LHeader then
            Sep(ANode);
          LHeader := False;
          Child(ANode, LChild);
          Sep(ANode);
        end;
    else
      Kw(':', ANode);
      Child(ANode, LChild);
    end;
    LChild := Next(LChild);
  end;
  if LHeader then
    Sep(ANode);
end;

// ( params ; ... ) - `[ ]` for a property's index parameters.
procedure TPrinter.Params(ANode: Integer);
var
  LProp: Boolean;
begin
  LProp := (T.Nodes[ANode].Parent <> NIL_NODE) and
    (Kind(T.Nodes[ANode].Parent) = nkPropertyDecl);
  if LProp then
    Kw('[', ANode)
  else
    Kw('(', ANode);
  ListFrom(T.Nodes[ANode].FirstChild, ';', ANode);
  if LProp then
    Kw(']', ANode)
  else
    Kw(')', ANode);
end;

{ [attributes] [var | const: F18] [out] names (nfName, each may carry
  attributes) [: Type [= default]]. `out` is Aux's. }
procedure TPrinter.Param(ANode: Integer);
var
  LChild, LLastName: Integer;
  LSeenName, LPrevName: Boolean;
begin
  LLastName := NIL_NODE;
  LChild := T.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if nfName in T.Nodes[LChild].Flags then
      LLastName := LChild;
    LChild := Next(LChild);
  end;
  LChild := T.Nodes[ANode].FirstChild;
  LSeenName := False;
  LPrevName := False;
  while (LChild <> NIL_NODE) and (LLastName <> NIL_NODE) do
  begin
    if LPrevName then
      Kw(',', ANode);
    if (nfName in T.Nodes[LChild].Flags) and not LSeenName then
    begin
      if not IsEmptyNode(T, LChild) then
        Losses(ANode, Left(LChild));
      if T.Nodes[ANode].Aux >= 0 then
        Kw('out', ANode);
    end;
    Child(ANode, LChild);
    LPrevName := nfName in T.Nodes[LChild].Flags;
    LSeenName := LSeenName or LPrevName;
    if LChild = LLastName then
    begin
      LChild := Next(LChild);
      Break;
    end;
    LChild := Next(LChild);
  end;
  if LChild <> NIL_NODE then
  begin
    Kw(':', ANode);
    Child(ANode, LChild);
    LChild := Next(LChild);
    if LChild <> NIL_NODE then
    begin
      Kw('=', ANode);
      Child(ANode, LChild);
    end;
  end;
end;

{ property Name [index params] [: Type] specifiers [hints]; [default;]
  [hints;] - the head `class` is the list owner's (Aux 1). A specifier
  `default` with no value is always the trailing one, which owns its `;`
  (`read G default;` is E2029, dcc64 37.0). }
procedure TPrinter.PropertyDecl(ANode: Integer);
var
  LChild: Integer;
  LClosed: Boolean;

  function TrailingDefault(ASpec: Integer): Boolean;
  begin
    Result := (Kind(ASpec) = nkPropSpec) and
      (T.Nodes[ASpec].FirstChild = NIL_NODE) and
      SameText(T.Source.VisibleText(T.Nodes[ASpec].FirstToken), 'default');
  end;

begin
  Kw('property', ANode);
  LChild := T.Nodes[ANode].FirstChild;
  Child(ANode, LChild);
  if LChild <> NIL_NODE then
    LChild := Next(LChild);
  if (LChild <> NIL_NODE) and (Kind(LChild) = nkParams) then
  begin
    Child(ANode, LChild);
    LChild := Next(LChild);
  end;
  if (LChild <> NIL_NODE) and not (Kind(LChild) in [nkPropSpec, nkDirective])
  then
  begin
    Kw(':', ANode);
    Child(ANode, LChild);
    LChild := Next(LChild);
  end;
  LClosed := False;
  while LChild <> NIL_NODE do
  begin
    if TrailingDefault(LChild) then
    begin
      if not LClosed then
        Sep(ANode);
      LClosed := True;
      Child(ANode, LChild);
      LClosed := LClosed and (Next(LChild) = NIL_NODE);
    end
    else
      Child(ANode, LChild);
    LChild := Next(LChild);
  end;
  if not LClosed then
    Sep(ANode);
end;

// The specifier word, its values with `,` between; the trailing `default`
// with its `;`.
procedure TPrinter.PropSpec(ANode: Integer);
begin
  Head(ANode);
  ListFrom(T.Nodes[ANode].FirstChild, ',', ANode);
  if (T.Nodes[ANode].FirstChild = NIL_NODE) and
     SameText(T.Source.VisibleText(T.Nodes[ANode].FirstToken), 'default') then
    Kw(';', ANode);
end;

// case [Tag :] Type of branches - a separator after every branch.
procedure TPrinter.VariantPart(ANode: Integer);
var
  LChild, LAfter: Integer;
begin
  Kw('case', ANode);
  LChild := T.Nodes[ANode].FirstChild;
  if LChild <> NIL_NODE then
  begin
    LAfter := Next(LChild);
    if (LAfter <> NIL_NODE) and (Kind(LAfter) <> nkVariantBranch) then
    begin
      Child(ANode, LChild);
      Kw(':', ANode);
      LChild := LAfter;
    end;
    Child(ANode, LChild);
    LChild := Next(LChild);
  end;
  Kw('of', ANode);
  while LChild <> NIL_NODE do
  begin
    Child(ANode, LChild);
    Sep(ANode);
    LChild := Next(LChild);
  end;
end;

// labels : ( fields )
procedure TPrinter.VariantBranch(ANode: Integer);
var
  LChild: Integer;
begin
  LChild := T.Nodes[ANode].FirstChild;
  while (LChild <> NIL_NODE) and
        not (Kind(LChild) in [nkVarDecl, nkVariantPart]) do
  begin
    if LChild <> T.Nodes[ANode].FirstChild then
      Kw(',', ANode);
    Child(ANode, LChild);
    LChild := Next(LChild);
  end;
  Kw(':', ANode);
  Kw('(', ANode);
  Decls(ANode, LChild, NIL_NODE);
  Kw(')', ANode);
end;

// names , ... [: constraints , ...]
procedure TPrinter.GenericParam(ANode: Integer);
var
  LChild: Integer;
  LFirst: Boolean;
begin
  LChild := T.Nodes[ANode].FirstChild;
  LFirst := True;
  while (LChild <> NIL_NODE) and (Kind(LChild) <> nkConstraint) do
  begin
    if not LFirst then
      Kw(',', ANode);
    Child(ANode, LChild);
    LFirst := False;
    LChild := Next(LChild);
  end;
  if LChild <> NIL_NODE then
  begin
    Kw(':', ANode);
    ListFrom(LChild, ',', ANode);
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
  // F3: `packed` before the type is its parent's token, like `reference
  // to` (see ProcType).
  if nfPacked in T.Nodes[ANode].Flags then
    Kw('packed', T.Nodes[ANode].Parent);
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
    nkRange, nkSubrange:
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
        // A numeric label has no node (F16): the loss read at the end.
        if C0 <> NIL_NODE then
          Emit(C0);
      end;
    nkLabeledStmt:
      // Two children: the label's name and the statement; one: a numeric
      // label, which has no node (F16) - read before the `:`.
      if C1 <> NIL_NODE then
      begin
        Emit(C0);
        Kw(':', ANode);
        Emit(C1);
      end
      else
      begin
        if (C0 <> NIL_NODE) and not IsEmptyNode(T, C0) then
          Losses(ANode, Left(C0))
        else
          Losses(ANode, T.Nodes[ANode].LastToken + 1);
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

    // ---- compilation units ----
    nkUnit, nkProgram, nkLibrary, nkPackage:
      UnitLike(ANode);
    nkUsesClause:
      UsesClause(ANode);
    nkUsesItem:
      begin
        Child(ANode, C0);
        if C1 <> NIL_NODE then
        begin
          Kw('in', ANode);
          Child(ANode, C1);
        end;
      end;
    nkInterfaceSec:
      begin
        Kw('interface', ANode);
        Decls(ANode, C0, NIL_NODE);
      end;
    nkImplementationSec:
      begin
        Kw('implementation', ANode);
        Decls(ANode, C0, NIL_NODE);
      end;
    nkInitSec:
      begin
        // `initialization` or a unit's legacy `begin`, as written: one
        // section, but not one .dcu (F30).
        Head(ANode);
        Statements(ANode);
      end;
    nkFinalSec:
      begin
        Kw('finalization', ANode);
        Statements(ANode);
      end;
    nkExportsClause:
      begin
        Kw('exports', ANode);
        ListFrom(C0, ',', ANode);
        Kw(';', ANode);
      end;
    nkExportsItem:
      // Name [params], then its `index` / `name` clauses and `resident` -
      // which of the values is which is a filed loss (F14), read in place.
      begin
        LChild := C0;
        while LChild <> NIL_NODE do
        begin
          Child(ANode, LChild);
          LChild := Next(LChild);
        end;
      end;

    // ---- declaration sections ----
    nkTypeSec:
      begin
        Kw('type', ANode);
        LChild := C0;
        while LChild <> NIL_NODE do
        begin
          Child(ANode, LChild);
          if Kind(LChild) = nkTypeDecl then
            Kw(';', ANode);
          LChild := Next(LChild);
        end;
      end;
    nkConstSec:
      begin
        Head(ANode);
        LChild := C0;
        while LChild <> NIL_NODE do
        begin
          Child(ANode, LChild);
          if Kind(LChild) = nkConstDecl then
            Kw(';', ANode);
          LChild := Next(LChild);
        end;
      end;
    nkVarSec:
      VarSec(ANode);
    nkLabelSec:
      LabelSec(ANode);
    nkTypeDecl:
      TypeDecl(ANode);
    nkConstDecl:
      ConstDecl(ANode);
    nkVarDecl:
      VarDecl(ANode);
    nkAggregate:
      Aggregate(ANode);
    nkAggregateField:
      begin
        Child(ANode, C0);
        Kw(':', ANode);
        Child(ANode, C1);
      end;

    // ---- type expressions ----
    nkEnumType:
      begin
        Kw('(', ANode);
        ListFrom(C0, ',', ANode);
        Kw(')', ANode);
      end;
    nkEnumValue:
      begin
        Child(ANode, C0);
        if C1 <> NIL_NODE then
        begin
          Kw('=', ANode);
          Child(ANode, C1);
        end;
      end;
    nkArrayType:
      ArrayType(ANode);
    nkSetType:
      begin
        Kw('set', ANode);
        Kw('of', ANode);
        Child(ANode, C0);
      end;
    nkFileType:
      begin
        Kw('file', ANode);
        if C0 <> NIL_NODE then
        begin
          Kw('of', ANode);
          Child(ANode, C0);
        end;
      end;
    nkPointerType:
      begin
        Kw('^', ANode);
        Child(ANode, C0);
      end;
    nkStringType:
      begin
        Kw('string', ANode);
        Kw('[', ANode);
        Child(ANode, C0);
        Kw(']', ANode);
      end;
    nkClassOf:
      // Aux 1: `type of X`, `type of interface` without a child.
      if T.Nodes[ANode].Aux = 1 then
      begin
        Kw('type', ANode);
        Kw('of', ANode);
        if C0 <> NIL_NODE then
          Child(ANode, C0)
        else
          Kw('interface', ANode);
      end
      else
      begin
        Kw('class', ANode);
        Kw('of', ANode);
        Child(ANode, C0);
      end;
    nkProcType:
      ProcType(ANode);
    nkClassType, nkRecordType, nkInterfaceType, nkObjectType, nkHelperType:
      StructType(ANode);
    nkGuid:
      begin
        Kw('[', ANode);
        Child(ANode, C0);
        // A GUID written as a literal has no leaf (F15).
        Losses(ANode, T.Nodes[ANode].LastToken + 1);
        Kw(']', ANode);
      end;

    // ---- members and routines ----
    nkVisibility:
      begin
        if nfNegated in T.Nodes[ANode].Flags then
          Kw('strict', ANode);
        if (T.Nodes[ANode].Aux >= Low(VISIBILITY_TEXT)) and
           (T.Nodes[ANode].Aux <= High(VISIBILITY_TEXT)) then
          Kw(VISIBILITY_TEXT[T.Nodes[ANode].Aux], ANode);
      end;
    nkRoutine:
      Routine(ANode);
    nkParams:
      Params(ANode);
    nkParam:
      Param(ANode);
    nkDirective:
      // The word, then its values - which value of `external` is the
      // library, the name or the index is a filed loss (F13), and so is the
      // message of a routine's `deprecated` (F12): read in place.
      begin
        Head(ANode);
        LChild := C0;
        while LChild <> NIL_NODE do
        begin
          Child(ANode, LChild);
          LChild := Next(LChild);
        end;
      end;
    nkPropertyDecl:
      PropertyDecl(ANode);
    nkPropSpec:
      PropSpec(ANode);
    nkMethodResolution:
      begin
        Head(ANode);
        LChild := RoutineName(ANode, C0);
        Kw('=', ANode);
        Child(ANode, LChild);
        Kw(';', ANode);
      end;
    nkVariantPart:
      VariantPart(ANode);
    nkVariantBranch:
      VariantBranch(ANode);
    nkGenericParams:
      begin
        Kw('<', ANode);
        ListFrom(C0, ';', ANode);
        Kw('>', ANode);
      end;
    nkGenericParam:
      GenericParam(ANode);
    nkConstraint:
      // A type constraint is its child; `class`, `record`, `constructor`
      // the head word.
      if C0 <> NIL_NODE then
        Child(ANode, C0)
      else
        Head(ANode);
    nkAttrGroup:
      begin
        Kw('[', ANode);
        ListFrom(C0, ',', ANode);
        Kw(']', ANode);
      end;
    nkAttribute:
      begin
        Child(ANode, C0);
        if C1 <> NIL_NODE then
        begin
          Kw('(', ANode);
          ListFrom(C1, ',', ANode);
          Kw(')', ANode);
        end;
      end;
    nkRoutineBody:
      Decls(ANode, C0, NIL_NODE);
  else
    Span(ANode);
  end;
  // What a template left of the node's filed losses stands at its end.
  if not (LKind in SPAN_KINDS) then
    Losses(ANode, MaxInt);
end;

function PrintWith(const ATree: TPasTree; const AOwn: TOwnership;
  ANode: Integer): TPasPrintItems;
var
  LP: TPrinter;
begin
  LP.T := ATree;
  LP.Own := AOwn;
  LP.LossPos := Copy(AOwn.OwnStart);
  LP.Items := nil;
  LP.Count := 0;
  if (ANode >= 0) and (ANode <= High(ATree.Nodes)) then
    LP.Emit(ANode);
  SetLength(LP.Items, LP.Count);
  Result := LP.Items;
end;

function PrintNode(const ATree: TPasTree; ANode: Integer): TPasPrintItems;
var
  LOwn: TOwnership;
begin
  LOwn.Build(ATree);
  Result := PrintWith(ATree, LOwn, ANode);
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
  LSkip: TArray<Boolean>;   // N8, N10: a token read elsewhere
  LMoveBefore: TArray<Integer>;  // N10: the `of` read before this token
  LEndAfter: TArray<Boolean>;    // N9: a virtual `end` after this token
  LOCount, LPCount, LIdx, LVis, LFirst, LLast, LI, LJ, LK: Integer;
  LOwner, LRule, LNode, LOf, LChild, LSites: Integer;
  LTok: TPasTokenKind;
  LHasEnd: Boolean;

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
    SetLength(AResult.Sites, LN + 1);
    AResult.Sites[LN].Vis := AVis;
    AResult.Sites[LN].Item := AItem;
    AResult.Sites[LN].Finding := AFinding;
    AResult.Sites[LN].Msg := AMsg;
  end;

  // A loss read: counted per finding, the first of each kept as a site.
  procedure CountLoss(AVis: Integer; const AFinding: string);
  var
    LN: Integer;
  begin
    Inc(AResult.Losses);
    for LN := 0 to High(AResult.LossCounts) do
      if AResult.LossCounts[LN].Finding = AFinding then
      begin
        Inc(AResult.LossCounts[LN].Count);
        Exit;
      end;
    LN := Length(AResult.LossCounts);
    SetLength(AResult.LossCounts, LN + 1);
    AResult.LossCounts[LN].Finding := AFinding;
    AResult.LossCounts[LN].Count := 1;
    AResult.LossCounts[LN].FirstVis := AVis;
    Site(AVis, -1, AFinding, Format('`%s` read as the filed loss %s',
      [ATree.Source.VisibleText(AVis), AFinding]));
  end;

  function Matches(const AItem: TPasPrintItem; const AOrig: TOrigTok): Boolean;
  begin
    if AItem.Vis >= 0 then
      Result := (AItem.Vis = AOrig.Vis) and (AOrig.Split <> 1) and
        (AItem.Text = AOrig.Text)
    else
      // N3; and the token must be the printing node's own - but the `>`
      // half of a fused `>=`, which the operator or the type declaration
      // owns (N2).
      Result := SameText(AItem.Text, AOrig.Text) and
        ((AOrig.Owner = AItem.Node) or
         ((AOrig.Split = 1) and
          (ATree.Nodes[AItem.Node].Kind in [nkTypeArgs, nkGenericParams])));
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

  function OwnsTokenOf(ANode: Integer; AKind: TPasTokenKind): Integer;
  var
    LPos: Integer;
  begin
    for LPos := LOwn.OwnStart[ANode] to LOwn.OwnStart[ANode + 1] - 1 do
      if ATree.Source.VisibleToken(LOwn.Own[LPos]).Kind = AKind then
        Exit(LOwn.Own[LPos]);
    Result := -1;
  end;

  procedure Defect(AVis, AItem: Integer; const AMsg: string);
  begin
    Inc(AResult.Defects);
    if LSites < AMaxSites then
    begin
      Inc(LSites);
      Site(AVis, AItem, '', AMsg);
    end;
  end;

begin
  AResult := Default(TPasT3Result);
  if (ARoot < 0) or (ARoot > High(ATree.Nodes)) then
    Exit(False);
  LOwn.Build(ATree);
  LSites := 0;
  LFirst := ATree.NodeLeftmostVis(ARoot);
  LLast := ATree.Nodes[ARoot].LastToken;
  SetLength(LOAt, Length(ATree.Source.Visible));
  SetLength(LSkip, Length(ATree.Source.Visible));
  SetLength(LMoveBefore, Length(ATree.Source.Visible));
  SetLength(LEndAfter, Length(ATree.Source.Visible));
  for LIdx := 0 to High(LOAt) do
  begin
    LOAt[LIdx] := -1;
    LMoveBefore[LIdx] := -1;
  end;
  // N9 and N10 are decided per node, before the stream is read.
  for LNode := 0 to High(ATree.Nodes) do
    case ATree.Nodes[LNode].Kind of
      nkClassType, nkObjectType, nkInterfaceType:
        begin
          if ((ATree.Nodes[LNode].Kind = nkClassType) and
              (ATree.Nodes[LNode].Aux = 1)) or
             ((ATree.Nodes[LNode].Kind = nkInterfaceType) and
              (ATree.Nodes[LNode].Aux and 2 <> 0)) or
             (LOwn.OwnStart[LNode] = LOwn.OwnStart[LNode + 1]) then
            Continue;
          LHasEnd := OwnsTokenOf(LNode, tkEnd) >= 0;
          if not LHasEnd and (ATree.Nodes[LNode].LastToken >= 0) and
             (ATree.Nodes[LNode].LastToken <= High(LEndAfter)) then
            LEndAfter[ATree.Nodes[LNode].LastToken] := True;
        end;
      nkProcType:
        if ATree.Nodes[LNode].Aux = 1 then
        begin
          LOf := OwnsTokenOf(LNode, tkOf);
          if LOf < 0 then
            Continue;
          LChild := ATree.Nodes[LNode].FirstChild;
          while (LChild <> NIL_NODE) and
                (ATree.Nodes[LChild].Kind <> nkDirective) do
            LChild := ATree.Nodes[LChild].NextSibling;
          if (LChild <> NIL_NODE) and (ATree.NodeLeftmostVis(LChild) < LOf)
          then
          begin
            LMoveBefore[ATree.NodeLeftmostVis(LChild)] := LOf;
            LSkip[LOf] := True;
            LSkip[LOf + 1] := True;
          end;
        end;
    end;
  // The original, normalized.
  LO := nil;
  LOCount := 0;
  for LVis := LFirst to LLast do
  begin
    Inc(AResult.Original);
    LOwner := LOwn.Owner[LVis];
    LRule := LOwn.Rule[LVis];
    LTok := ATree.Source.VisibleToken(LVis).Kind;
    if LMoveBefore[LVis] >= 0 then
    begin
      // N10: `of object` before the directives.
      AddO(LMoveBefore[LVis], 'of', 0);
      AddO(LMoveBefore[LVis] + 1,
        ATree.Source.VisibleText(LMoveBefore[LVis] + 1), 0);
    end;
    if LSkip[LVis] then
      Inc(AResult.Normalized)                                        // N8 N10
    else if LTok = tkEndOfFile then
      Inc(AResult.Normalized)                                        // N4
    else if (LRule >= 0) and GRuleAfterEnd[LRule] then
      Inc(AResult.Normalized)                                        // N5
    else if (LOwner >= 0) and (ATree.Nodes[LOwner].Kind in LIST_KINDS) and
       (LTok = tkSemicolon) then
      Inc(AResult.Normalized)                                        // N1
    else if (LOwner >= 0) and (LTok = tkGreaterEqual) and
       (((ATree.Nodes[LOwner].Aux = LVis) and
         IsFusedGreaterEqual(ATree, LOwner)) or
        (ATree.Nodes[LOwner].Kind = nkTypeDecl)) then
    begin
      Inc(AResult.Normalized);                                       // N2
      AddO(LVis, '>', 1);
      AddO(LVis, '=', 2);
    end
    else if (LRule >= 0) and (GRuleCls[LRule] = ocInsignificant) then
      Inc(AResult.Normalized)                                        // N6
    else if (LOwner >= 0) and (ATree.Nodes[LOwner].Kind = nkAggregate) and
       (LTok = tkSemicolon) and (LVis < LLast) and
       (LOwn.Owner[LVis + 1] = LOwner) and
       (ATree.Source.VisibleToken(LVis + 1).Kind = tkRParen) then
      Inc(AResult.Normalized)                                        // N11
    else if (LOwner >= 0) and (ATree.Nodes[LOwner].Kind = nkAttrGroup) and
       (LTok = tkRBracket) and (LVis < LLast) and
       (LOwn.Owner[LVis + 1] = LOwner) and
       (ATree.Source.VisibleToken(LVis + 1).Kind = tkLBracket) then
    begin
      Inc(AResult.Normalized);                                       // N8
      AddO(LVis, ',', 0);
      LSkip[LVis + 1] := True;
    end
    else
      AddO(LVis, ATree.Source.VisibleText(LVis), 0);
    if LEndAfter[LVis] then
    begin
      Inc(AResult.Normalized);                                       // N9
      AddO(LVis, 'end', 3);
    end;
  end;
  // The print, without its separators (N1).
  LItems := PrintWith(ATree, LOwn, ARoot);
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
  // Side by side; a defect resynchronizes at the next printed item that was
  // read from a token.
  LI := 0;
  LJ := 0;
  while (LI < LPCount) or (LJ < LOCount) do
  begin
    if (LI < LPCount) and (LJ < LOCount) and Matches(LP[LI], LO[LJ]) then
    begin
      Inc(AResult.Matched);
      AResult.ItemAt[LPFrom[LI]] := LO[LJ].Vis;
      case LP[LI].Cls of
        pcSpan:
          Inc(AResult.Spans);
        pcLoss:
          CountLoss(LO[LJ].Vis, GRuleFinding[LO[LJ].Rule]);
      end;
      Inc(LI);
      Inc(LJ);
      Continue;
    end;
    if LJ < LOCount then
      LVis := LO[LJ].Vis
    else
      LVis := -1;
    if (LJ < LOCount) and IsLossRule(LO[LJ].Rule) then
      Defect(LVis, LI, Format('%s, the filed loss %s, is not read where ' +
        'the print has %s', [OrigText(LJ), GRuleFinding[LO[LJ].Rule],
        ItemText(LI)]))
    else if LI < LPCount then
      Defect(LVis, LI, Format('printed %s where the original has %s',
        [ItemText(LI), OrigText(LJ)]))
    else
      Defect(LVis, -1, Format('the print ends where the original has %s',
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
  LTop, LNode, LDep, LCount, LIdx, LVis, LChild, LN, LRule: Integer;
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
    // The own tokens that are facts: a leaf's, a contract read's (asm's
    // range, a head word), a filed loss's, one no rule classifies - and
    // every own token of a kind without a template. An operator's is its
    // op= above; derived and insignificant tokens are regenerated.
    if not (LKind in [nkUnaryOp, nkBinaryOp]) then
      for LIdx := LOwn.OwnStart[LNode] to LOwn.OwnStart[LNode + 1] - 1 do
      begin
        LVis := LOwn.Own[LIdx];
        LRule := LOwn.Rule[LVis];
        if (ATree.Source.VisibleToken(LVis).Kind = tkEndOfFile) or
           ((LRule >= 0) and GRuleAfterEnd[LRule]) then
          Continue;
        if not (LKind in SPAN_KINDS) and (LRule >= 0) and
           not (GRuleCls[LRule] in [ocLeaf, ocContract, ocLoss]) then
          Continue;
        LText := ATree.Source.VisibleText(LVis);
        // A keyword, and a directive word read by contract or as a loss,
        // in any case (N3) - but in asm, whose range is copied as written
        // and lexed anew (an identifier here may be a chunk there).
        if (LKind <> nkAsmStmt) and
           (IsKeyword(ATree.Source.VisibleToken(LVis).Kind) or
            ((ATree.Source.VisibleToken(LVis).Kind = tkIdentifier) and
             (LRule >= 0) and (GRuleCls[LRule] in [ocContract, ocLoss]))) then
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
