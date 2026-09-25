unit PasTree.Ast.Check;

{
  PasTree - the tree checker (parser fidelity, phase 1): the invariants every
  parse must hold, and the own-token walk the loss list is built from.

  A node carries no text - a kind, a span over the visible stream, an Aux and
  three links - so most structural defects are SILENT: a subtree built and
  never adopted, a span one token short, a node on two child lists. Every
  consumer walks from the root and reads only what it looks for, and nothing
  notices. This unit states what a tree is and checks it, over any tree:

  - I1 span sanity: token, node and link indices in range; a span is a span.
  - I2 children ordered and disjoint, each inside its parent's span.
  - I3 links consistent (Parent / FirstChild / NextSibling), every node
    reachable from the root - except the unreachable shapes the parser builds
    ON PURPOSE, which are recognised and COUNTED (TPasCheckShape), never
    silenced: an orphan of any other shape is a violation.
  - I4 the root's span covers the whole visible stream.
  - I6 Aux and Flags inside each kind's domain; an operator's Aux is its own
    operator token, standing between its operands.
  - I8, for valid code only: no nkError, and no nkMissing but the one closing
    a trailing comma, `F(A, B,)`.
  - I7 compares two trees of one source: two parses must build the same
    arena, and the interface-only parse of a unit must be a prefix of the
    full one. The CALLER parses - this unit depends on nothing beyond Types,
    Preprocessor and Ast - see CompareTrees and CheckInterfacePrefix.
  - I5 is not judged here yet. CheckTree reports every token a REACHABLE node
    owns - inside its span and inside none of its children's - to AOwnProc,
    and OwnTokenCell names the histogram cell the token falls in (reserved
    and directive words by text, everything else by class). An identifier,
    literal or directive word owned by a non-leaf kind is a fact that lives
    only in a token: the loss list, judged by an allowed table later.

  EMPTY nodes. Two shapes, both anchored at FirstToken, neither owning a token:
  - a ZERO-WIDTH kind (nkEmptyStmt, nkMissing) is created at the next token
    without consuming it, so its FirstToken = LastToken names the token it
    stands BEFORE - `if C then ;` gives the empty statement the block's `;`,
    which lies outside the if statement's own span;
  - any node whose LastToken is FirstToken - 1: a statement list holding
    nothing, like the try block of `try finally ... end`.
  An empty node sits between its siblings at its anchor, which may be one
  past its parent's last token (the `;` above).

  INVALID code (a parse that reported diagnostics) gets every check but I8,
  with one allowance: a childless one-token node may be a placeholder created
  at the next token without consuming it (nkError, or an nkIdent where a name
  was expected), token-identical to one that consumed its token. When reading
  it as a token breaks I2, the checker reads it as zero-width instead.
}

interface

uses
  PasTree.Types,
  PasTree.Preprocessor,
  PasTree.Ast;

type
  TPasCheckClass = (
    ccRange,     // I1: a token, node or link index out of range
    ccSpan,      // I1: a span that is no span
    ccOrder,     // I2: siblings overlapping or out of order
    ccContain,   // I2: a child outside its parent's span
    ccLink,      // I3: Parent / FirstChild / NextSibling disagree
    ccOrphan,    // I3: an unreachable subtree of no recognised shape
    ccRoot,      // I4: the root does not cover the visible stream
    ccAux,       // I6: Aux outside its kind's domain
    ccFlags,     // I6: a flag on a kind that never takes it
    ccDiffer,    // I7: two parses of one source differ
    ccPrefix,    // I7: the interface-only parse is no prefix of the full one
    ccError,     // I8: an nkError in valid code
    ccMissing    // I8: an nkMissing that closes no trailing comma
  );

  TPasCheckShape = (
    // Unreachable on purpose - the parser builds them and never adopts them:
    csContextKeyword,     // MarkContextKeyword's one-token nkDirective, for
                          // the highlighter: reference, operator, abstract,
                          // sealed, helper
    csTypeRefReread,      // ParseTypeExpr's type-reference attempt, left
                          // behind when an arithmetic operator after it makes
                          // the whole a constant expression that is re-read
                          // from the start (`array[B-1..B]`)
    csDirectiveInit,      // `X: procedure; cdecl = nil;` - an initializer
                          // after a trailing directive, parsed and dropped
                          // (plan finding F1)
    // Reachable, and recognised:
    csTrailingComma,      // the nkMissing closing `F(A, B,)`
    csAfterEnd,           // visible text after the final `end.`: dcc ignores
                          // it, the root stops at its first token
    csFusedGreaterEqual   // `V.AsType<T>=5`: ONE `>=` token closes the type
                          // arguments and is the `=` operator
  );

  TPasCheckViolation = record
    Cls: TPasCheckClass;
    Node: Integer;       // NIL_NODE when it is about the tree as a whole
    VisIndex: Integer;   // where it is reported; -1: nowhere in particular
    Msg: string;
  end;

  TPasCheckOrphan = record
    Root: Integer;       // the unreachable subtree's top node
    Size: Integer;       // nodes in the subtree
    Known: Boolean;      // True: Shape says which; False: a ccOrphan
    Shape: TPasCheckShape;
  end;

  { What the checks found, accumulated over the calls that share it (a
    caller runs CheckTree, CompareTrees and CheckInterfacePrefix into one).
    Counts are complete; Violations keeps the first MaxKept, because a
    systematic defect produces one per node. }
  TPasCheckReport = record
    Violations: TArray<TPasCheckViolation>;
    Kept: Integer;
    MaxKept: Integer;
    Counts: array[TPasCheckClass] of Integer;
    Shapes: array[TPasCheckShape] of Integer;
    ShapeSites: array[TPasCheckShape] of Integer;   // first VisIndex; -1: none
    Orphans: TArray<TPasCheckOrphan>;
    OrphanCount: Integer;
    procedure Init(AMaxKept: Integer = 1000);
    function Total: Integer;
    procedure Add(ACls: TPasCheckClass; ANode, AVisIndex: Integer;
      const AMsg: string);
    procedure AddShape(AShape: TPasCheckShape; AVisIndex: Integer);
  end;

  TPasOwnTokenProc = reference to procedure(ANode, AVisIndex: Integer);

{ I1-I4 and I6 over ATree, and I8 when AValid (the parse reported no
  diagnostic); found violations and shapes are added to AReport. AOwnProc,
  when given, is called once for every token a reachable node owns (I5).
  True when this call added no violation. }
function CheckTree(const ATree: TPasTree; AValid: Boolean;
  var AReport: TPasCheckReport;
  const AOwnProc: TPasOwnTokenProc = nil): Boolean;

{ I7: two parses of one preprocessed source must build the same arena, node
  for node and field for field. Reports the first difference. }
function CompareTrees(const A, B: TPasTree;
  var AReport: TPasCheckReport): Boolean;

{ I7: the interface-only parse of a unit is a prefix of its full parse -
  nodes [0..N-1] identical except the root's LastToken and the interface
  section's NextSibling (see TPasParser.ParseFile). For anything but a unit
  the flag is ignored and the two trees must be identical. }
function CheckInterfacePrefix(const AIntf, AFull: TPasTree;
  var AReport: TPasCheckReport): Boolean;

{ The I5 histogram cell of the visible token AVisIndex: a reserved word or
  punctuation by its kind, an identifier by its text when it is a directive
  word (B.4.2, plus the context words the parser matches by name), every
  other identifier as one class. 0 .. OwnTokenCellCount - 1. }
function OwnTokenCell(const ASource: TPasPreprocessed;
  AVisIndex: Integer): Integer;
function OwnTokenCellName(ACell: Integer): string;
function OwnTokenCellCount: Integer;

function CheckClassName(ACls: TPasCheckClass): string;   // 'I2.order'
function CheckShapeName(AShape: TPasCheckShape): string;

{ 'file(line,col)' of a visible token; the main file's name alone when the
  index is out of range. }
function VisSiteText(const ASource: TPasPreprocessed;
  AVisIndex: Integer): string;

{ One line per kept violation, 'file(line,col): class: message'; '' when the
  report holds none. }
function CheckReportText(const ATree: TPasTree;
  const AReport: TPasCheckReport): string;

implementation

uses
  System.SysUtils,
  System.Math;

const
  // The histogram keeps these identifiers by TEXT: the whole directive
  // vocabulary (DIRECTIVE_WORDS, B.4.2) plus the context words the parser
  // matches by name that the vocabulary does not list.
  CELL_EXTRA_WORDS: array[0..0] of string = ('align');

  CELL_IDENT = Ord(High(TPasTokenKind)) + 1;
  CELL_WORD_BASE = CELL_IDENT + 1;

  // MarkContextKeyword's words - see csContextKeyword.
  CONTEXT_WORDS: array[0..4] of string = (
    'reference', 'operator', 'abstract', 'sealed', 'helper');

  ZERO_WIDTH_KINDS = [nkEmptyStmt, nkMissing];
  BINARY_OP_TOKENS = [tkEqual, tkNotEqual, tkLess, tkGreater, tkLessEqual,
    tkGreaterEqual, tkIn, tkIs, tkPlus, tkMinus, tkOr, tkXor, tkStar, tkSlash,
    tkDiv, tkMod, tkAnd, tkShl, tkShr, tkAs];
  UNARY_OP_TOKENS = [tkPlus, tkMinus, tkNot, tkAt];
  // What ParseTypeExpr tests after an identifier-headed type reference: one
  // of these makes it re-read the whole as a constant expression.
  REREAD_TOKENS = [tkPlus, tkMinus, tkStar, tkSlash, tkDiv, tkMod, tkShl,
    tkShr, tkAnd, tkOr, tkXor];

  CHECK_CLASS_NAMES: array[TPasCheckClass] of string = (
    'I1.range', 'I1.span', 'I2.order', 'I2.contain', 'I3.link', 'I3.orphan',
    'I4.root', 'I6.aux', 'I6.flags', 'I7.differ', 'I7.prefix', 'I8.error',
    'I8.missing');
  CHECK_SHAPE_NAMES: array[TPasCheckShape] of string = (
    'orphan: context keyword', 'orphan: type reference re-read',
    'orphan: initializer after a trailing directive', 'trailing comma',
    'text after end.', 'fused >= as type-argument close and =');

  PUNCT_TEXT: array[tkPlus..tkAssign] of string = (
    '+', '-', '*', '/', '=', '<>', '<', '>', '<=', '>=', '(', ')', '[', ']',
    '.', '..', ',', ':', ';', '^', '@', ':=');

{ TPasCheckReport }

procedure TPasCheckReport.Init(AMaxKept: Integer);
var
  LShape: TPasCheckShape;
  LCls: TPasCheckClass;
begin
  Violations := nil;
  Kept := 0;
  MaxKept := AMaxKept;
  for LCls := Low(TPasCheckClass) to High(TPasCheckClass) do
    Counts[LCls] := 0;
  for LShape := Low(TPasCheckShape) to High(TPasCheckShape) do
  begin
    Shapes[LShape] := 0;
    ShapeSites[LShape] := -1;
  end;
  Orphans := nil;
  OrphanCount := 0;
end;

function TPasCheckReport.Total: Integer;
var
  LCls: TPasCheckClass;
begin
  Result := 0;
  for LCls := Low(TPasCheckClass) to High(TPasCheckClass) do
    Inc(Result, Counts[LCls]);
end;

procedure TPasCheckReport.Add(ACls: TPasCheckClass; ANode,
  AVisIndex: Integer; const AMsg: string);
begin
  Inc(Counts[ACls]);
  if Kept >= MaxKept then
    Exit;
  if Kept = Length(Violations) then
    SetLength(Violations, Kept * 2 + 8);
  Violations[Kept].Cls := ACls;
  Violations[Kept].Node := ANode;
  Violations[Kept].VisIndex := AVisIndex;
  Violations[Kept].Msg := AMsg;
  Inc(Kept);
end;

procedure TPasCheckReport.AddShape(AShape: TPasCheckShape;
  AVisIndex: Integer);
begin
  Inc(Shapes[AShape]);
  if ShapeSites[AShape] < 0 then
    ShapeSites[AShape] := AVisIndex;
end;

{ Names }

function CheckClassName(ACls: TPasCheckClass): string;
begin
  Result := CHECK_CLASS_NAMES[ACls];
end;

function CheckShapeName(AShape: TPasCheckShape): string;
begin
  Result := CHECK_SHAPE_NAMES[AShape];
end;

function OwnTokenCellCount: Integer;
begin
  Result := CELL_WORD_BASE + Length(DIRECTIVE_WORDS) + Length(CELL_EXTRA_WORDS);
end;

function OwnTokenCellName(ACell: Integer): string;
var
  LKind: TPasTokenKind;
  LWord: Integer;
begin
  if (ACell < 0) or (ACell >= OwnTokenCellCount) then
    Exit('<?>');
  if ACell = CELL_IDENT then
    Exit('<ident>');
  if ACell >= CELL_WORD_BASE then
  begin
    LWord := ACell - CELL_WORD_BASE;
    if LWord <= High(DIRECTIVE_WORDS) then
      Exit(DIRECTIVE_WORDS[LWord]);
    Exit(CELL_EXTRA_WORDS[LWord - Length(DIRECTIVE_WORDS)]);
  end;
  LKind := TPasTokenKind(ACell);
  if IsKeyword(LKind) then
    Exit(KEYWORDS[Ord(LKind) - Ord(tkAnd)]);
  if (LKind >= Low(PUNCT_TEXT)) and (LKind <= High(PUNCT_TEXT)) then
    Exit(PUNCT_TEXT[LKind]);
  case LKind of
    tkUnknown: Result := '<unknown>';
    tkEndOfFile: Result := '<eof>';
    tkIntLiteral: Result := '<int>';
    tkRealLiteral: Result := '<real>';
    tkStringLiteral: Result := '<str>';
    tkMultilineString: Result := '<mlstr>';
    tkControlChar: Result := '<char>';
    tkCaretChar: Result := '<caretchar>';
    tkAsmChunk: Result := '<asm>';
  else
    // Trivia is never visible; named anyway so no cell prints blank.
    Result := '<trivia>';
  end;
end;

function OwnTokenCell(const ASource: TPasPreprocessed;
  AVisIndex: Integer): Integer;
var
  LKind: TPasTokenKind;
  LText: PChar;
  LLen, LIdx: Integer;
begin
  LKind := ASource.VisibleToken(AVisIndex).Kind;
  if LKind <> tkIdentifier then
    Exit(Ord(LKind));
  ASource.VisibleSlice(AVisIndex, LText, LLen);
  // An &-escaped identifier keeps its '&' and never matches: it is a name.
  for LIdx := 0 to High(DIRECTIVE_WORDS) do
    if SliceEqualsWord(LText, LLen, DIRECTIVE_WORDS[LIdx]) then
      Exit(CELL_WORD_BASE + LIdx);
  for LIdx := 0 to High(CELL_EXTRA_WORDS) do
    if SliceEqualsWord(LText, LLen, CELL_EXTRA_WORDS[LIdx]) then
      Exit(CELL_WORD_BASE + Length(DIRECTIVE_WORDS) + LIdx);
  Result := CELL_IDENT;
end;

function VisSiteText(const ASource: TPasPreprocessed;
  AVisIndex: Integer): string;
var
  LVis: TPasVisibleToken;
  LLine, LCol: Integer;
begin
  if (AVisIndex < 0) or (AVisIndex > High(ASource.Visible)) then
  begin
    if Length(ASource.FileNames) > 0 then
      Exit(ASource.FileNames[0]);
    Exit('?');
  end;
  LVis := ASource.Visible[AVisIndex];
  ASource.Files[LVis.FileId].OffsetToLineCol(
    ASource.Files[LVis.FileId].Tokens[LVis.TokenIndex].Start, LLine, LCol);
  Result := Format('%s(%d,%d)', [ASource.FileNames[LVis.FileId], LLine, LCol]);
end;

function CheckReportText(const ATree: TPasTree;
  const AReport: TPasCheckReport): string;
var
  LIdx: Integer;
begin
  Result := '';
  for LIdx := 0 to AReport.Kept - 1 do
    Result := Result + VisSiteText(ATree.Source,
      AReport.Violations[LIdx].VisIndex) + ': ' +
      CheckClassName(AReport.Violations[LIdx].Cls) + ': ' +
      AReport.Violations[LIdx].Msg + sLineBreak;
  if AReport.Total > AReport.Kept then
    Result := Result + Format('... %d more violations not kept',
      [AReport.Total - AReport.Kept]) + sLineBreak;
end;

{ Aux domains (I6). The kinds with a documented Aux are listed; every other
  kind leaves the arena's default, NIL_NODE. nkUnaryOp, nkBinaryOp and nkParam
  point at a token and are checked against it separately. }
function AuxInDomain(AKind: TPasNodeKind; AAux: Integer): Boolean;
begin
  case AKind of
    nkUnaryOp, nkBinaryOp, nkParam:
      Result := True;
    nkInterfaceType:
      Result := (AAux >= 0) and (AAux <= 3);   // bit set: 1 disp, 2 forward
    nkVisibility:
      Result := (AAux >= 1) and (AAux <= 5);
    nkAttribute:
      Result := (AAux = amaNone) or ((AAux >= amaRef) and (AAux <= amaAlign));
    nkProcType:
      Result := (AAux = NIL_NODE) or (AAux = 1) or (AAux = 2);
    nkTypeDecl, nkClassType, nkRecordType, nkObjectType, nkHelperType,
    nkClassOf, nkArrayType, nkRoutine, nkMethodResolution, nkPropertyDecl,
    nkVarDecl, nkVarSec, nkForStmt, nkUsesClause:
      Result := (AAux = NIL_NODE) or (AAux = 1);
  else
    Result := AAux = NIL_NODE;
  end;
end;

function NodesEqual(const A, B: TPasNode): Boolean;
begin
  Result := (A.Kind = B.Kind) and (A.Flags = B.Flags) and
    (A.FirstToken = B.FirstToken) and (A.LastToken = B.LastToken) and
    (A.Parent = B.Parent) and (A.FirstChild = B.FirstChild) and
    (A.NextSibling = B.NextSibling) and (A.Aux = B.Aux);
end;

function CheckTree(const ATree: TPasTree; AValid: Boolean;
  var AReport: TPasCheckReport; const AOwnProc: TPasOwnTokenProc): Boolean;
const
  ST_NONE = 0;       // reached from no root
  ST_TREE = 1;       // reachable from the root
  ST_ORPHAN = 2;     // in an unreachable subtree
var
  LCount, LLastVis, LBefore, LOrderCount, LOrphanStart: Integer;
  LState: TArray<Byte>;
  LBadTok, LEmpty: TArray<Boolean>;
  LLo, LHi, LOrder, LOwner, LStack: TArray<Integer>;
  // The children Walk accepted, per node: every later pass follows a child
  // list this far and no further, so a list that loops ends where Walk
  // stopped it.
  LKidCount: TArray<Integer>;
  LKids: TArray<Integer>;   // SettlePlaceholders' scratch: one child list
  LNode, LPos, LSize: Integer;
  LRec: TPasNode;

  function Kind(ANode: Integer): TPasNodeKind;
  begin
    Result := ATree.Nodes[ANode].Kind;
  end;

  function KName(ANode: Integer): string;
  begin
    Result := ATree.KindName(ATree.Nodes[ANode].Kind);
  end;

  function TokKind(AVis: Integer): TPasTokenKind;
  begin
    if (AVis < 0) or (AVis > LLastVis) then
      Exit(tkUnknown);
    Result := ATree.Source.VisibleToken(AVis).Kind;
  end;

  // 'line:col' of a visible token, for the second position in a message.
  function At(AVis: Integer): string;
  var
    LVis: TPasVisibleToken;
    LLine, LCol: Integer;
  begin
    if (AVis < 0) or (AVis > LLastVis) then
      Exit(Format('#%d', [AVis]));
    LVis := ATree.Source.Visible[AVis];
    ATree.Source.Files[LVis.FileId].OffsetToLineCol(
      ATree.Source.Files[LVis.FileId].Tokens[LVis.TokenIndex].Start,
      LLine, LCol);
    Result := Format('%d:%d', [LLine, LCol]);
  end;

  function Site(ANode: Integer): Integer;
  begin
    if LBadTok[ANode] then
      Result := -1
    else
      Result := ATree.Nodes[ANode].FirstToken;
  end;

  function LinkOk(ALink: Integer): Boolean;
  begin
    Result := (ALink >= 0) and (ALink < LCount);
  end;

  function WordAt(AVis: Integer; const AWords: array of string): Boolean;
  var
    LText: PChar;
    LLen: Integer;
    LWord: string;
  begin
    if TokKind(AVis) <> tkIdentifier then
      Exit(False);
    ATree.Source.VisibleSlice(AVis, LText, LLen);
    for LWord in AWords do
      if SliceEqualsWord(LText, LLen, LWord) then
        Exit(True);
    Result := False;
  end;

  // TPasParser.IsDirectiveWord's test, from the token alone.
  function DirectiveWordAt(AVis: Integer): Boolean;
  begin
    Result := (TokKind(AVis) in [tkInline, tkLibrary]) or
      WordAt(AVis, ROUTINE_DIRECTIVE_WORDS);
  end;

  // Depth-first from ARoot over the child lists, marking AState; appends to
  // LOrder in preorder (so every node lands after its ancestors) and checks
  // that each child names the list's owner as its Parent. An explicit stack:
  // a left-deep operator chain nests as deep as it is long.
  function Walk(ARoot: Integer; AState: Byte): Integer;
  var
    LTop, LAt, LKid, LSteps: Integer;
  begin
    Result := 0;
    LState[ARoot] := AState;
    LTop := 0;
    LStack[LTop] := ARoot;
    Inc(LTop);
    while LTop > 0 do
    begin
      Dec(LTop);
      LAt := LStack[LTop];
      LOrder[LOrderCount] := LAt;
      Inc(LOrderCount);
      Inc(Result);
      LKid := ATree.Nodes[LAt].FirstChild;
      LSteps := 0;
      // LState stops a list at the first node seen before, so this ends.
      while LinkOk(LKid) do
      begin
        if LState[LKid] <> ST_NONE then
        begin
          AReport.Add(ccLink, LKid, Site(LKid), Format(
            '%s is on the child list of %s but was reached before - two ' +
            'lists, or a cycle', [KName(LKid), KName(LAt)]));
          Break;
        end;
        if ATree.Nodes[LKid].Parent <> LAt then
          AReport.Add(ccLink, LKid, Site(LKid), Format(
            '%s is on the child list of %s (node %d) but its Parent is %d',
            [KName(LKid), KName(LAt), LAt, ATree.Nodes[LKid].Parent]));
        LState[LKid] := AState;
        LStack[LTop] := LKid;
        Inc(LTop);
        Inc(LSteps);
        LKid := ATree.Nodes[LKid].NextSibling;
      end;
      LKidCount[LAt] := LSteps;
    end;
  end;

  // Invalid code only: which of ANode's childless one-token children are
  // placeholders standing BEFORE their token (see the unit comment). One is
  // read that way when the token reading does not fit: ANode is empty, or the
  // token is past ANode's LastToken, over the sibling before it or under the
  // sibling after it.
  procedure SettlePlaceholders(ANode: Integer);
  var
    LKid, LIdx, LAt, LNum, LLast, LPrevEnd, LNextLo: Integer;
  begin
    LNum := LKidCount[ANode];
    if LNum = 0 then
      Exit;
    if Length(LKids) < LNum then
      SetLength(LKids, LNum * 2);
    LKid := ATree.Nodes[ANode].FirstChild;
    for LIdx := 0 to LNum - 1 do
    begin
      LKids[LIdx] := LKid;
      LKid := ATree.Nodes[LKid].NextSibling;
    end;
    LLast := ATree.Nodes[ANode].LastToken;
    LPrevEnd := -1;
    for LIdx := 0 to LNum - 1 do
    begin
      LKid := LKids[LIdx];
      if LEmpty[LKid] then
        Continue;
      if (ATree.Nodes[LKid].FirstChild = NIL_NODE) and
         (LLo[LKid] = LHi[LKid]) then
      begin
        LNextLo := MaxInt;
        for LAt := LIdx + 1 to LNum - 1 do
          if not LEmpty[LKids[LAt]] then
          begin
            LNextLo := LLo[LKids[LAt]];
            Break;
          end;
        if (LLast < ATree.Nodes[ANode].FirstToken) or (LHi[LKid] > LLast) or
           (LLo[LKid] <= LPrevEnd) or (LHi[LKid] >= LNextLo) then
        begin
          LEmpty[LKid] := True;
          LHi[LKid] := LLo[LKid] - 1;
          Continue;
        end;
      end;
      LPrevEnd := Max(LPrevEnd, LHi[LKid]);
    end;
  end;

  // Lo / Hi / Empty of ANode from its own fields and its children's (which
  // are computed first: LOrder is walked backwards).
  procedure ComputeSpan(ANode: Integer);
  var
    LFirst, LLast, LMin, LKid, LIdx: Integer;
    LHasFull: Boolean;
  begin
    LFirst := ATree.Nodes[ANode].FirstToken;
    LLast := ATree.Nodes[ANode].LastToken;
    if LBadTok[ANode] then
    begin
      // Reported by the range pass; kept out of every span comparison.
      LEmpty[ANode] := True;
      LLo[ANode] := Max(0, Min(LFirst, LLastVis));
      LHi[ANode] := LLo[ANode] - 1;
      Exit;
    end;
    if not AValid then
      SettlePlaceholders(ANode);
    LMin := MaxInt;
    LHasFull := False;
    LKid := ATree.Nodes[ANode].FirstChild;
    for LIdx := 1 to LKidCount[ANode] do
    begin
      if not LEmpty[LKid] then
      begin
        LHasFull := True;
        LMin := Min(LMin, LLo[LKid]);
      end;
      LKid := ATree.Nodes[LKid].NextSibling;
    end;
    if Kind(ANode) in ZERO_WIDTH_KINDS then
    begin
      LEmpty[ANode] := True;
      LLo[ANode] := LFirst;
      LHi[ANode] := LFirst - 1;
      if LLast <> LFirst then
        AReport.Add(ccSpan, ANode, LFirst, Format(
          'zero-width %s spans %s..%s', [KName(ANode), At(LFirst), At(LLast)]));
      if ATree.Nodes[ANode].FirstChild <> NIL_NODE then
        AReport.Add(ccSpan, ANode, LFirst, Format(
          'zero-width %s has children', [KName(ANode)]));
    end
    else if LLast < LFirst then
    begin
      LEmpty[ANode] := True;
      LLo[ANode] := LFirst;
      LHi[ANode] := LFirst - 1;
      if LLast <> LFirst - 1 then
        AReport.Add(ccSpan, ANode, LFirst, Format(
          '%s ends %d tokens before it starts', [KName(ANode), LFirst - LLast]));
      if LHasFull then
        AReport.Add(ccSpan, ANode, LFirst, Format(
          '%s has an empty span over children that hold tokens',
          [KName(ANode)]));
    end
    else
    begin
      LEmpty[ANode] := False;
      LLo[ANode] := Min(LFirst, LMin);
      LHi[ANode] := LLast;
    end;
  end;

  // I2 over ANode's children.
  procedure CheckChildren(ANode: Integer);
  var
    LKid, LNextKid, LIdx, LPrevEnd, LPrevAnchor, LAnchor: Integer;
  begin
    LPrevEnd := LLo[ANode] - 1;
    LPrevAnchor := LLo[ANode];
    LKid := ATree.Nodes[ANode].FirstChild;
    for LIdx := 0 to LKidCount[ANode] - 1 do
    begin
      if LIdx < LKidCount[ANode] - 1 then
        LNextKid := ATree.Nodes[LKid].NextSibling
      else
        LNextKid := NIL_NODE;
      if not LBadTok[LKid] then
      begin
        if LEmpty[LKid] then
        begin
          LAnchor := LLo[LKid];
          if LEmpty[ANode] then
          begin
            if LAnchor <> LLo[ANode] then
              AReport.Add(ccContain, LKid, LAnchor, Format(
                'empty %s (child %d) anchored at %s, away from its empty ' +
                'parent %s at %s', [KName(LKid), LIdx, At(LAnchor),
                KName(ANode), At(LLo[ANode])]));
          end
          else if (LAnchor < LLo[ANode]) or (LAnchor > LHi[ANode] + 1) then
            AReport.Add(ccContain, LKid, LAnchor, Format(
              'empty %s (child %d) anchored at %s, outside its parent %s ' +
              '%s..%s', [KName(LKid), LIdx, At(LAnchor), KName(ANode),
              At(LLo[ANode]), At(LHi[ANode])]))
          else if (LAnchor <= LPrevEnd) or (LAnchor < LPrevAnchor) then
            AReport.Add(ccOrder, LKid, LAnchor, Format(
              'empty %s (child %d of %s) anchored at %s, before the end of ' +
              'the sibling before it', [KName(LKid), LIdx, KName(ANode),
              At(LAnchor)]));
          LPrevAnchor := Max(LPrevAnchor, LAnchor);
        end
        else if not LEmpty[ANode] then
        begin
          if LHi[LKid] > LHi[ANode] then
            AReport.Add(ccContain, LKid, LLo[LKid], Format(
              '%s (child %d) %s..%s ends after its parent %s %s..%s',
              [KName(LKid), LIdx, At(LLo[LKid]), At(LHi[LKid]), KName(ANode),
              At(LLo[ANode]), At(LHi[ANode])]));
          if LLo[LKid] <= LPrevEnd then
            AReport.Add(ccOrder, LKid, LLo[LKid], Format(
              '%s (child %d of %s) starts at %s, inside the sibling before ' +
              'it (ends %s)', [KName(LKid), LIdx, KName(ANode),
              At(LLo[LKid]), At(LPrevEnd)]))
          else if LLo[LKid] < LPrevAnchor then
            AReport.Add(ccOrder, LKid, LLo[LKid], Format(
              '%s (child %d of %s) starts at %s, before an empty sibling''s ' +
              'anchor %s', [KName(LKid), LIdx, KName(ANode), At(LLo[LKid]),
              At(LPrevAnchor)]));
          LPrevEnd := Max(LPrevEnd, LHi[LKid]);
          LPrevAnchor := Max(LPrevAnchor, LHi[LKid] + 1);
        end;
      end;
      LKid := LNextKid;
    end;
  end;

  // I5: the tokens of ANode's span that no child's span covers.
  procedure WalkOwn(ANode: Integer);
  var
    LKid, LCursor, LTok, LIdx: Integer;
  begin
    LCursor := LLo[ANode];
    LKid := ATree.Nodes[ANode].FirstChild;
    for LIdx := 1 to LKidCount[ANode] do
    begin
      if not LEmpty[LKid] then
      begin
        for LTok := LCursor to Min(LLo[LKid] - 1, LHi[ANode]) do
        begin
          LOwner[LTok] := ANode;
          if Assigned(AOwnProc) then
            AOwnProc(ANode, LTok);
        end;
        if LHi[LKid] + 1 > LCursor then
          LCursor := LHi[LKid] + 1;
      end;
      LKid := ATree.Nodes[LKid].NextSibling;
    end;
    for LTok := LCursor to LHi[ANode] do
    begin
      LOwner[LTok] := ANode;
      if Assigned(AOwnProc) then
        AOwnProc(ANode, LTok);
    end;
  end;

  // csTypeRefReread: the reachable tree re-reads the orphan's tokens, from
  // the same first token through the operator after it.
  function ReReadCovers(ARoot: Integer): Boolean;
  var
    LAt, LSteps: Integer;
  begin
    Result := False;
    LAt := LOwner[LLo[ARoot]];
    LSteps := 0;
    // Bounded: a Parent link I3 found wrong may point anywhere.
    while LinkOk(LAt) and (LState[LAt] = ST_TREE) and (LSteps < LCount) do
    begin
      if LLo[LAt] < LLo[ARoot] then
        Exit;
      if (LLo[LAt] = LLo[ARoot]) and (LHi[LAt] > LHi[ARoot]) then
        Exit(True);
      LAt := ATree.Nodes[LAt].Parent;
      Inc(LSteps);
    end;
  end;

  procedure ClassifyOrphan(ARoot, ASize: Integer);
  var
    LOrphan: TPasCheckOrphan;
  begin
    LOrphan.Root := ARoot;
    LOrphan.Size := ASize;
    LOrphan.Known := True;
    if (Kind(ARoot) = nkDirective) and
       (ATree.Nodes[ARoot].FirstChild = NIL_NODE) and not LBadTok[ARoot] and
       (ATree.Nodes[ARoot].FirstToken = ATree.Nodes[ARoot].LastToken) and
       WordAt(ATree.Nodes[ARoot].FirstToken, CONTEXT_WORDS) then
      LOrphan.Shape := csContextKeyword
    else if not LEmpty[ARoot] and (LLo[ARoot] >= 2) and
       (TokKind(LLo[ARoot] - 1) = tkEqual) and
       DirectiveWordAt(LLo[ARoot] - 2) then
      LOrphan.Shape := csDirectiveInit
    else if not LEmpty[ARoot] and (TokKind(LHi[ARoot] + 1) in REREAD_TOKENS)
       and ReReadCovers(ARoot) then
      LOrphan.Shape := csTypeRefReread
    else
      LOrphan.Known := False;
    if LOrphan.Known then
      AReport.AddShape(LOrphan.Shape, Site(ARoot))
    else
      AReport.Add(ccOrphan, ARoot, Site(ARoot), Format(
        'unreachable %s subtree, %d node(s), of no known shape',
        [KName(ARoot), ASize]));
    if AReport.OrphanCount = Length(AReport.Orphans) then
      SetLength(AReport.Orphans, AReport.OrphanCount * 2 + 8);
    AReport.Orphans[AReport.OrphanCount] := LOrphan;
    Inc(AReport.OrphanCount);
  end;

  // csFusedGreaterEqual: the left operand ends in type arguments that close
  // on this very `>=` - their LastToken is the token before it.
  function FusedClose(ALeft, AOp: Integer): Boolean;
  var
    LAt, LKid, LIdx, LSteps: Integer;
  begin
    Result := False;
    if TokKind(AOp - 1) = tkGreater then
      Exit;
    LAt := ALeft;
    LSteps := 0;
    while LinkOk(LAt) and (LSteps < LCount) do
    begin
      if (Kind(LAt) = nkTypeArgs) and (ATree.Nodes[LAt].LastToken = AOp - 1) then
        Exit(True);
      // Down to the last child: the rightmost designator segment.
      if LKidCount[LAt] = 0 then
        Exit;
      LKid := ATree.Nodes[LAt].FirstChild;
      for LIdx := 2 to LKidCount[LAt] do
        LKid := ATree.Nodes[LKid].NextSibling;
      LAt := LKid;
      Inc(LSteps);
    end;
  end;

  // I6 for one node.
  procedure CheckAux(ANode: Integer);
  var
    LAux, LKids, LFirstKid, LSecondKid: Integer;
    LOpKind: TPasTokenKind;
  begin
    LAux := ATree.Nodes[ANode].Aux;
    if not AuxInDomain(Kind(ANode), LAux) then
      AReport.Add(ccAux, ANode, Site(ANode), Format(
        '%s has Aux %d, outside its kind''s domain', [KName(ANode), LAux]));
    if nfError in ATree.Nodes[ANode].Flags then
      AReport.Add(ccFlags, ANode, Site(ANode), Format(
        '%s carries nfError, which the parser never sets', [KName(ANode)]));
    if (nfNegated in ATree.Nodes[ANode].Flags) and
       not (Kind(ANode) in [nkBinaryOp, nkVisibility]) then
      AReport.Add(ccFlags, ANode, Site(ANode), Format(
        '%s carries nfNegated', [KName(ANode)]));
    if LBadTok[ANode] then
      Exit;
    LKids := LKidCount[ANode];
    LFirstKid := NIL_NODE;
    LSecondKid := NIL_NODE;
    if LKids >= 1 then
      LFirstKid := ATree.Nodes[ANode].FirstChild;
    if LKids >= 2 then
      LSecondKid := ATree.Nodes[LFirstKid].NextSibling;
    case Kind(ANode) of
      nkBinaryOp:
        begin
          LOpKind := TokKind(LAux);
          if LAux <> ATree.Nodes[ANode].FirstToken then
            AReport.Add(ccAux, ANode, Site(ANode), Format(
              'BinaryOp Aux %d is not its FirstToken %d',
              [LAux, ATree.Nodes[ANode].FirstToken]))
          else if not (LOpKind in BINARY_OP_TOKENS) then
            AReport.Add(ccAux, ANode, Site(ANode), Format(
              'BinaryOp Aux names a %s token, no binary operator',
              [OwnTokenCellName(Ord(LOpKind))]))
          else if LKids <> 2 then
            AReport.Add(ccAux, ANode, Site(ANode), Format(
              'BinaryOp has %d children', [LKids]))
          else if not (LEmpty[LFirstKid] or LEmpty[LSecondKid]) and
             ((LAux <= LHi[LFirstKid]) or (LAux >= LLo[LSecondKid])) then
            AReport.Add(ccAux, ANode, Site(ANode), Format(
              'BinaryOp operator at %s is not between its operands (%s..%s, ' +
              '%s..%s)', [At(LAux), At(LLo[LFirstKid]), At(LHi[LFirstKid]),
              At(LLo[LSecondKid]), At(LHi[LSecondKid])]))
          else
          begin
            if nfNegated in ATree.Nodes[ANode].Flags then
              if not (((LOpKind = tkIs) and (TokKind(LAux + 1) = tkNot)) or
                 ((LOpKind = tkIn) and (TokKind(LAux - 1) = tkNot))) then
                AReport.Add(ccFlags, ANode, Site(ANode),
                  'BinaryOp is negated but reads neither `is not` nor `not in`');
            if (LOpKind = tkGreaterEqual) and FusedClose(LFirstKid, LAux) then
              AReport.AddShape(csFusedGreaterEqual, LAux);
          end;
        end;
      nkUnaryOp:
        begin
          if LAux <> ATree.Nodes[ANode].FirstToken then
            AReport.Add(ccAux, ANode, Site(ANode), Format(
              'UnaryOp Aux %d is not its FirstToken %d',
              [LAux, ATree.Nodes[ANode].FirstToken]))
          else if not (TokKind(LAux) in UNARY_OP_TOKENS) then
            AReport.Add(ccAux, ANode, Site(ANode), Format(
              'UnaryOp Aux names a %s token, no unary operator',
              [OwnTokenCellName(Ord(TokKind(LAux)))]))
          else if LKids <> 1 then
            AReport.Add(ccAux, ANode, Site(ANode), Format(
              'UnaryOp has %d children', [LKids]))
          else if not LEmpty[LFirstKid] and (LAux >= LLo[LFirstKid]) then
            AReport.Add(ccAux, ANode, Site(ANode), Format(
              'UnaryOp operator at %s is not before its operand at %s',
              [At(LAux), At(LLo[LFirstKid])]));
        end;
      nkParam:
        if LAux <> NIL_NODE then
          if (LAux < LLo[ANode]) or (LAux > LHi[ANode]) or
             not WordAt(LAux, ['out']) then
            AReport.Add(ccAux, ANode, Site(ANode), Format(
              'Param Aux %d names no `out` inside the parameter', [LAux]))
          else if (LState[ANode] = ST_TREE) and (LOwner[LAux] <> ANode) then
            AReport.Add(ccAux, ANode, Site(ANode),
              'Param Aux names an `out` a child of the parameter owns');
      nkVisibility:
        if (nfNegated in ATree.Nodes[ANode].Flags) and
           not (WordAt(LLo[ANode], ['strict']) and (LAux in [1, 2])) then
          AReport.Add(ccFlags, ANode, Site(ANode),
            'Visibility is marked strict but does not read `strict ' +
            'private` or `strict protected`');
    end;
  end;

  // I8's nkMissing test, and the shape it recognises.
  procedure CheckMissing(ANode: Integer);
  var
    LParent, LAnchor: Integer;
  begin
    LParent := ATree.Nodes[ANode].Parent;
    LAnchor := ATree.Nodes[ANode].FirstToken;
    if LinkOk(LParent) and (Kind(LParent) in [nkCall, nkAttribute]) and
       (ATree.Nodes[ANode].NextSibling = NIL_NODE) and
       (TokKind(LAnchor) = tkRParen) and (TokKind(LAnchor - 1) = tkComma) then
      AReport.AddShape(csTrailingComma, LAnchor)
    else if AValid then
      if LinkOk(LParent) then
        AReport.Add(ccMissing, ANode, Site(ANode), Format(
          'Missing under %s, not the trailing comma of an argument list',
          [KName(LParent)]))
      else
        AReport.Add(ccMissing, ANode, Site(ANode), 'Missing with no parent');
  end;

begin
  LBefore := AReport.Total;
  LCount := Length(ATree.Nodes);
  LLastVis := High(ATree.Source.Visible);
  if LCount = 0 then
  begin
    AReport.Add(ccRoot, NIL_NODE, -1, 'the tree has no nodes');
    Exit(False);
  end;
  if LLastVis < 0 then
  begin
    AReport.Add(ccRoot, NIL_NODE, -1, 'the tree has no visible stream');
    Exit(False);
  end;
  SetLength(LState, LCount);
  SetLength(LBadTok, LCount);
  SetLength(LEmpty, LCount);
  SetLength(LLo, LCount);
  SetLength(LHi, LCount);
  SetLength(LOrder, LCount);
  SetLength(LStack, LCount);
  SetLength(LKidCount, LCount);
  SetLength(LOwner, LLastVis + 1);
  for LPos := 0 to LLastVis do
    LOwner[LPos] := NIL_NODE;

  // I1, indices. A node whose tokens are out of range stays out of every
  // span test below; an out-of-range link ends the list it is on.
  for LNode := 0 to LCount - 1 do
  begin
    LRec := ATree.Nodes[LNode];
    if (LRec.FirstToken < 0) or (LRec.FirstToken > LLastVis) or
       (LRec.LastToken < -1) or (LRec.LastToken > LLastVis) then
    begin
      LBadTok[LNode] := True;
      AReport.Add(ccRange, LNode, -1, Format(
        '%s node %d spans tokens %d..%d, outside the visible stream 0..%d',
        [KName(LNode), LNode, LRec.FirstToken, LRec.LastToken, LLastVis]));
    end;
    if (LRec.Parent < NIL_NODE) or (LRec.Parent >= LCount) then
      AReport.Add(ccRange, LNode, Site(LNode), Format(
        '%s node %d has Parent %d', [KName(LNode), LNode, LRec.Parent]));
    if (LRec.FirstChild < NIL_NODE) or (LRec.FirstChild >= LCount) then
      AReport.Add(ccRange, LNode, Site(LNode), Format(
        '%s node %d has FirstChild %d',
        [KName(LNode), LNode, LRec.FirstChild]));
    if (LRec.NextSibling < NIL_NODE) or (LRec.NextSibling >= LCount) then
      AReport.Add(ccRange, LNode, Site(LNode), Format(
        '%s node %d has NextSibling %d',
        [KName(LNode), LNode, LRec.NextSibling]));
  end;

  // I3: reachability from the root (node 0), then every unreachable subtree
  // from its own top. What neither walk reaches names a Parent whose list
  // does not hold it.
  LOrderCount := 0;
  if ATree.Nodes[0].Parent <> NIL_NODE then
    AReport.Add(ccLink, 0, Site(0), 'the root has a Parent');
  Walk(0, ST_TREE);
  LOrphanStart := LOrderCount;
  for LNode := 1 to LCount - 1 do
    if (LState[LNode] = ST_NONE) and not LinkOk(ATree.Nodes[LNode].Parent) then
      Walk(LNode, ST_ORPHAN);
  for LNode := 1 to LCount - 1 do
    if LState[LNode] = ST_NONE then
      AReport.Add(ccLink, LNode, Site(LNode), Format(
        '%s node %d names Parent %d, whose child list does not hold it',
        [KName(LNode), LNode, ATree.Nodes[LNode].Parent]));

  // I1 spans, bottom-up: descendants come after their ancestors in LOrder.
  // A placeholder is settled by its parent, before anybody reads its span
  // as part of a larger one.
  for LPos := LOrderCount - 1 downto 0 do
    ComputeSpan(LOrder[LPos]);

  // I2.
  for LPos := 0 to LOrderCount - 1 do
    if not LBadTok[LOrder[LPos]] then
      CheckChildren(LOrder[LPos]);

  // I4.
  if LEmpty[0] then
    AReport.Add(ccRoot, 0, Site(0), 'the root span is empty')
  else
  begin
    if LLo[0] <> 0 then
      AReport.Add(ccRoot, 0, LLo[0], Format(
        'the root starts at token %d, not 0', [LLo[0]]));
    if LHi[0] < LLastVis then
      if (Kind(0) in [nkUnit, nkProgram, nkLibrary, nkPackage]) and
         (TokKind(LHi[0] - 1) = tkDot) and (TokKind(LHi[0] - 2) = tkEnd) then
        AReport.AddShape(csAfterEnd, LHi[0])
      else
        AReport.Add(ccRoot, 0, LHi[0], Format(
          'the root ends at token %d of %d', [LHi[0], LLastVis]));
  end;

  // I5: the owners, which the orphan shapes below also read.
  for LPos := 0 to LOrphanStart - 1 do
    if not LEmpty[LOrder[LPos]] then
      WalkOwn(LOrder[LPos]);

  // I3: what the unreachable subtrees are.
  LPos := LOrphanStart;
  while LPos < LOrderCount do
  begin
    LNode := LOrder[LPos];
    // The subtree's nodes follow its top in LOrder, up to the next top.
    LSize := 1;
    while (LPos + LSize < LOrderCount) and
          LinkOk(ATree.Nodes[LOrder[LPos + LSize]].Parent) do
      Inc(LSize);
    ClassifyOrphan(LNode, LSize);
    Inc(LPos, LSize);
  end;

  // I6 and I8 over every walked node.
  for LPos := 0 to LOrderCount - 1 do
  begin
    LNode := LOrder[LPos];
    CheckAux(LNode);
    case Kind(LNode) of
      nkError:
        if AValid then
          AReport.Add(ccError, LNode, Site(LNode), 'Error node in valid code');
      nkMissing:
        CheckMissing(LNode);
    end;
  end;
  Result := AReport.Total = LBefore;
end;


{ The first node index at which A and B differ, comparing A's nodes
  [0..High(A.Nodes)] against B's; -1 when there is none. ALenient: the two
  deltas of the interface-only prefix are not differences - the root's
  LastToken, and an interface section whose NextSibling is NIL in A and B's
  implementation section in B. }
function FirstDifference(const A, B: TPasTree; ALenient: Boolean): Integer;
var
  LIdx, LSec, LChild: Integer;
  LA, LB: TPasNode;
begin
  LSec := NIL_NODE;
  if ALenient and (Length(B.Nodes) > 0) then
  begin
    LChild := B.Nodes[0].FirstChild;
    while (LChild >= 0) and (LChild <= High(B.Nodes)) do
    begin
      if B.Nodes[LChild].Kind = nkInterfaceSec then
      begin
        LSec := LChild;
        Break;
      end;
      LChild := B.Nodes[LChild].NextSibling;
    end;
  end;
  for LIdx := 0 to Min(High(A.Nodes), High(B.Nodes)) do
  begin
    LA := A.Nodes[LIdx];
    LB := B.Nodes[LIdx];
    if ALenient and (LIdx = 0) then
      LA.LastToken := LB.LastToken;
    if ALenient and (LIdx = LSec) and (LA.NextSibling = NIL_NODE) and
       (LB.NextSibling >= 0) and (LB.NextSibling <= High(B.Nodes)) and
       (B.Nodes[LB.NextSibling].Kind = nkImplementationSec) then
      LA.NextSibling := LB.NextSibling;
    if not NodesEqual(LA, LB) then
      Exit(LIdx);
  end;
  Result := -1;
end;

function CompareTrees(const A, B: TPasTree;
  var AReport: TPasCheckReport): Boolean;
var
  LIdx: Integer;
begin
  if Length(A.Nodes) <> Length(B.Nodes) then
  begin
    AReport.Add(ccDiffer, NIL_NODE, -1, Format(
      'two parses of one source built %d and %d nodes',
      [Length(A.Nodes), Length(B.Nodes)]));
    Exit(False);
  end;
  // The first difference is the one worth reading; the rest follow from it.
  LIdx := FirstDifference(A, B, False);
  Result := LIdx < 0;
  if not Result then
    AReport.Add(ccDiffer, LIdx, A.Nodes[LIdx].FirstToken, Format(
      'node %d differs between two parses of one source (%s / %s)',
      [LIdx, A.KindName(A.Nodes[LIdx].Kind), B.KindName(B.Nodes[LIdx].Kind)]));
end;

function CheckInterfacePrefix(const AIntf, AFull: TPasTree;
  var AReport: TPasCheckReport): Boolean;
var
  LUnit: Boolean;
  LIdx: Integer;
begin
  // AInterfaceOnly is ignored for a program, library or package: there the
  // two parses must be the same tree.
  LUnit := (Length(AFull.Nodes) > 0) and (AFull.Nodes[0].Kind = nkUnit);
  if (LUnit and (Length(AIntf.Nodes) > Length(AFull.Nodes))) or
     (not LUnit and (Length(AIntf.Nodes) <> Length(AFull.Nodes))) then
  begin
    AReport.Add(ccPrefix, NIL_NODE, -1, Format(
      'the interface-only parse built %d nodes, the full parse %d',
      [Length(AIntf.Nodes), Length(AFull.Nodes)]));
    Exit(False);
  end;
  LIdx := FirstDifference(AIntf, AFull, LUnit);
  Result := LIdx < 0;
  if not Result then
    AReport.Add(ccPrefix, LIdx, AFull.Nodes[LIdx].FirstToken, Format(
      'node %d of the interface-only parse differs from the full parse''s ' +
      '(%s / %s)', [LIdx, AIntf.KindName(AIntf.Nodes[LIdx].Kind),
      AFull.KindName(AFull.Nodes[LIdx].Kind)]));
end;

end.
