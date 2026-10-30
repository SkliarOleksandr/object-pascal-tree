unit PasTree.Ast.Check;

{
  PasTree - the tree checker (parser fidelity, phase 1): the invariants every
  parse must hold, and the own-token table the loss list is judged by.

  A node carries no text - a kind, a span over the visible stream, an Aux and
  three links - so most structural defects are SILENT: a subtree built and
  never adopted, a span one token short, a node on two child lists. Every
  consumer walks from the root and reads only what it looks for, and nothing
  notices. This unit states what a tree is and checks it, over any tree:

  - I1 span sanity: token, node and link indices in range; a span is a span.
  - I2 children ordered and disjoint, each inside its parent's span. A span
    starts at FirstToken, but for the kinds whose FirstToken stands after
    their first child (LEFT_OPERAND_KINDS: an operator, a postfix, a member
    access) and for a declaration's leading attribute groups, which may
    stand before its name (tree-contract.md sec. 5).
  - I3 links consistent (Parent / FirstChild / NextSibling), every node
    reachable from the root - except the unreachable shapes the parser builds
    ON PURPOSE, which are recognised and COUNTED (TPasCheckShape), never
    silenced: an orphan of any other shape is a violation.
  - I4 the root's span covers the whole visible stream.
  - I6 Aux and Flags inside each kind's domain; an operator's Aux is its own
    operator token, standing between its operands; the names a declaration
    marks (nfName) open its child list and, in valid code, agree with the
    separators between and after them (CheckNames).
  - I8, for valid code only: no nkError, and no nkMissing but the one closing
    a trailing comma, `F(A, B,)`.
  - I7 compares two trees of one source: two parses must build the same
    arena, and the interface-only parse of a unit must be a prefix of the
    full one. The CALLER parses - this unit depends on nothing beyond Types,
    Preprocessor and Ast - see CompareTrees and CheckInterfacePrefix.
  - I5 OWNERSHIP, for valid code: every token a reachable node owns - inside
    its span and inside none of its children's - is judged against the
    OWN-TOKEN TABLE (OWN_RULE_TEXT below), the structural printer's
    specification in multiset form. Per node kind it says which owned tokens
    are DERIVED (the printer regenerates them from Kind, Aux, Flags and the
    children), LEAF (the node's own text), CONTRACT (read from the token by a
    documented rule: the head word at FirstToken, or asm's opaque range),
    INSIGNIFICANT (the printer's normalization list) or a LOSS (a fact only
    that token holds - a finding of the parser-fidelity plan), and how many
    of them one node may own. A token no rule covers, or a count the table
    does not allow, is a violation; a loss is counted, like the orphan
    shapes. The cell a token falls in is OwnTokenCell's: reserved and
    directive words by text, everything else by class.

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
    ccOwn,       // I5: an owned token the own-token table does not allow
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

  { I5: what the tree does with a token a node owns - the classes of the
    own-token table. }
  TPasOwnClass = (
    ocDerived,        // regenerated from Kind, Aux, Flags and the children
    ocLeaf,           // the node's own text: a name or a literal
    ocContract,       // read from the token by a documented rule: the node's
                      // head word at FirstToken, or an opaque range (asm)
    ocInsignificant,  // may be dropped or respelled without changing what dcc
                      // compiles - the printer's normalization list
    ocLoss            // a fact only this token holds: a plan finding
  );

  // How many tokens of one rule one node may own.
  TPasOwnMult = (omMany, omOnce, omOpt);

  // A rule that applies only while its condition holds (`when:` in the table).
  TPasOwnCond = (
    wcNone,
    wcNoArgs,       // an attribute with no argument child
    wcAfterEnd      // the token after the final `end.` (csAfterEnd)
  );

  { One rule of the own-token table, parsed from its line. }
  TPasOwnRule = record
    AllKinds: Boolean;              // `*`: every kind (with a condition)
    Kinds: set of TPasNodeKind;
    Cells: TArray<Boolean>;         // indexed by OwnTokenCell
    Head: Boolean;                  // only the token at the node's FirstToken
    Mult: TPasOwnMult;
    Cond: TPasOwnCond;
    Cls: TPasOwnClass;
    Finding: string;                // ocLoss: the plan finding, 'F2'
    KindsText, CellsText, Note: string;
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
    // I5, valid parses only: the owned tokens each rule of the own-token
    // table classified, by rule index, with the first one's visible index
    // (-1: none); and the tokens no rule covers (each also a ccOwn).
    OwnCounts: TArray<Integer>;
    OwnSites: TArray<Integer>;
    OwnUnlisted: Integer;
    procedure Init(AMaxKept: Integer = 1000);
    function Total: Integer;
    procedure Add(ACls: TPasCheckClass; ANode, AVisIndex: Integer;
      const AMsg: string);
    procedure AddShape(AShape: TPasCheckShape; AVisIndex: Integer);
  end;

  { One owned token (I5): its node, its visible index, its OwnTokenCell and
    the own-token rule that classified it (OwnRule; -1 when none does). }
  TPasOwnTokenProc = reference to procedure(ANode, AVisIndex, ACell,
    ARule: Integer);

{ I1-I4 and I6 over ATree, and I5 and I8 when AValid (the parse reported no
  diagnostic); found violations, shapes and I5's per-rule counts are added to
  AReport. AOwnProc, when given, is called once for every token a reachable
  node owns - for an invalid parse too, where nothing is judged. True when
  this call added no violation. }
function CheckTree(const ATree: TPasTree; AValid: Boolean;
  var AReport: TPasCheckReport;
  const AOwnProc: TPasOwnTokenProc = nil): Boolean;

{ I7: two parses of one preprocessed source must build the same arena, node
  for node and field for field. Reports the first difference. }
function CompareTrees(const A, B: TPasTree;
  var AReport: TPasCheckReport): Boolean;

{ I7: the interface-only parse of a unit is a prefix of its full parse -
  nodes [0..N-1] identical except the root's LastToken and the interface
  section's NextSibling (see TPasParser.ParseFile). An
  interface-and-implementation-uses parse (pmInterfaceAndImplUses) is one as
  well, its implementation section's LastToken, FirstChild and NextSibling
  and its `uses` clause's NextSibling excepted. For anything but a unit the
  flag is ignored and the two trees must be identical. }
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

{ The own-token table (I5), parsed from OWN_RULE_TEXT when the unit
  initializes. OwnRuleTableErrors is '' when every line parsed and no two
  rules claim one token; otherwise CheckTree reports it on every valid
  parse. }
function OwnRuleCount: Integer;
function OwnRule(AIndex: Integer): TPasOwnRule;
function OwnRuleTableErrors: string;
function OwnClassName(ACls: TPasOwnClass): string;   // 'derived', 'loss'
{ 'derived', 'leaf', 'contract', 'insignificant', 'loss F2'; 'UNLISTED' for
  -1. }
function OwnRuleClassText(ARule: Integer): string;

function CheckClassName(ACls: TPasCheckClass): string;   // 'I2.order'
function CheckShapeName(AShape: TPasCheckShape): string;

{ 'file(line,col)' of a visible token; the main file's name alone when the
  index is out of range. }
function VisSiteText(const ASource: TPasPreprocessed;
  AVisIndex: Integer): string;

const
  // The kinds that stand between tokens and own none, whatever their span.
  PAS_ZERO_WIDTH_KINDS = [nkEmptyStmt, nkMissing];

{ A node that stands between tokens and owns none: a zero-width kind, or a
  span that ends before it starts (EMPTY nodes, above). }
function IsEmptyNode(const ATree: TPasTree; ANode: Integer): Boolean;

{ Is ANode an nkBinaryOp whose operator token is a `>=` fused from the `>`
  closing type arguments on its left and its own `=`? CloseGeneric splits
  such a token, so the type arguments end one token BEFORE it and own no `>`
  - their span ends where their last argument does. Read from the tree: the
  operator token (the contract read) and the spans along the left operand's
  right edge. Safe on a corrupt tree: every link is range-checked and every
  walk bounded. The checker's csFusedGreaterEqual and the printer's N2 rule
  both ask it. }
function IsFusedGreaterEqual(const ATree: TPasTree; ANode: Integer): Boolean;

{ Per visible token: is it a `>=` fused from the `>` closing type arguments
  or generic parameters and the `=` after them, whoever owns it - an
  operator, a type declaration, or a typed constant's, a variable's, a
  parameter's or an inline constant's `=` before its value (`V:
  TArr<Integer>= nil`)? Read from the tree: the token right after an
  nkTypeArgs or nkGenericParams that owns no `>` - its last child ends where
  it does. The checker reads such a token as the owner's `=` (I5, I6), the
  printer as `>` and `=` (N2). Safe on a corrupt tree, as above (audit
  B2-46). }
function PasFusedGreaterEquals(const ATree: TPasTree): TArray<Boolean>;

{ One line per kept violation, 'file(line,col): class: message'; '' when the
  report holds none. }
function CheckReportText(const ATree: TPasTree;
  const AReport: TPasCheckReport): string;

implementation

uses
  System.SysUtils,
  System.Math,
  System.Generics.Collections;

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

  BINARY_OP_TOKENS = [tkEqual, tkNotEqual, tkLess, tkGreater, tkLessEqual,
    tkGreaterEqual, tkIn, tkIs] + PAS_ADD_OPS + PAS_MUL_OPS;
  UNARY_OP_TOKENS = [tkPlus, tkMinus, tkNot, tkAt];

  CHECK_CLASS_NAMES: array[TPasCheckClass] of string = (
    'I1.range', 'I1.span', 'I2.order', 'I2.contain', 'I3.link', 'I3.orphan',
    'I4.root', 'I5.own', 'I6.aux', 'I6.flags', 'I7.differ', 'I7.prefix',
    'I8.error', 'I8.missing');
  CHECK_SHAPE_NAMES: array[TPasCheckShape] of string = (
    'orphan: context keyword', 'orphan: type reference re-read',
    'trailing comma', 'text after end.',
    'fused >= as type-argument close and =');

  PUNCT_TEXT: array[tkPlus..tkAssign] of string = (
    '+', '-', '*', '/', '=', '<>', '<', '>', '<=', '>=', '(', ')', '[', ']',
    '.', '..', ',', ':', ';', '^', '@', ':=');

  { The own-token table (I5): the structural printer's specification in
    multiset form, and the parser-fidelity plan's loss list. One rule per
    line, five fields separated by `|`:

      Kinds | Cells | Flags | Class | Note

    Kinds  node kinds as KindName spells them, or `*`: every kind, for a rule
           with a condition.
    Cells  OwnTokenCell names - a reserved word, a directive word or a
           punctuation token by its text; <ident> <int> <real> <str> <mlstr>
           <char> <caretchar> <eof> by class - or a set: @keywords (the
           reserved words), @words (the directive words), @routine (what the
           parser's IsDirectiveWord takes: the routine directives plus inline
           and library) and @any.
    Flags  `-`, or any of: head (only the token at the node's FirstToken),
           once / opt (the node owns exactly one / at most one token of the
           rule; default: any number), when:<condition> (noargs, afterend
           - see TPasOwnCond). A rule with a condition
           takes no count: its tokens count for the rule that covers them
           when the condition does not hold.
    Class  derived | leaf | contract | insig | loss:F<n> - see TPasOwnClass.
    Note   where the printer takes the token from; for a loss, the fact only
           the token holds.

    Which rule covers a token: a `*` rule whose condition holds; else a rule
    of the node's kind with a condition that holds, in table order; else the
    one rule that claims the token's cell for the kind - at the head a head
    rule before a positionless one, and a cell named outright before one a
    set brings in. Two rules claiming one cell alike is a table error.

    The finding numbers are the plan's (local/PARSER-FIDELITY-PLAN.md, a
    working paper). No loss is filed: the last one, F17's program
    parameters, is an nkProgramParams child. Each earlier one became a fact
    of the tree - F19, where a name list ends, since the names carry nfName
    (I6 checks the flag against the separators); F3's `packed` since the
    type carries nfPacked, F4's class modifiers since the class carries
    nfAbstract / nfSealed, F9's `class threadvar` since the section carries
    nfThreadvar, F12's message, F15's GUID literal and F16's numeric labels
    since each is a child, F18's parameter modes since the parameter carries
    nfVar / nfConst / nfOut, F13's external clauses since each value carries
    nfExtName / nfExtIndex / nfExtDependency and the directive nfDelayed,
    F14's exports clauses likewise (nfExtIndex / nfExtName on the values,
    nfResident on the item); F1, F2, F10 and F11 since every directive of a
    procedural type, of a routine header before its `;` and of an anonymous
    method is an nkDirective child, and the initializer after a procedural
    type's directives is its declaration's. A new finding of the kind is
    filed here as a `loss:F<n>` row, until the tree holds it. }
  OWN_RULE_TEXT: array[0..229] of string = (
    // ---- leaves: the token is the node's own text ----
    'Ident | <ident> @words @keywords | once | leaf | the name as written; ' +
      'a reserved word only after a dot, as an operator name or as the ' +
      'type words string and file',
    'IntLit | <int> | once | leaf | the literal',
    'RealLit | <real> | once | leaf | the literal',
    'StrLit | <str> <mlstr> <char> <caretchar> ^ <ident> | - | leaf | the ' +
      'adjacent string elements of one literal: quoted, #n, ^X (a caret ' +
      'before one letter)',
    'NilLit | nil | once | derived | the kind',
    'CaretChar | <caretchar> ^ <ident> | - | leaf | ^X: one token, or a ' +
      'caret before one letter',

    // ---- expressions ----
    'UnaryOp | + - @ not | head once | contract | the operator token Aux ' +
      'names',
    'BinaryOp | = <> < > <= >= in is + - or xor * / div mod and shl shr as | ' +
      'head once | contract | the operator token Aux names; a fused >= that ' +
      'also closes type arguments is their > and the = (normalization list)',
    'BinaryOp | not | opt | derived | nfNegated: is not, not in',
    'Paren | ( | head once | derived | the kind',
    'Paren | ) | once | derived | the kind',
    'Call | ( | head once | derived | the kind',
    'Call | ) | once | derived | the kind',
    'Call | , | - | derived | between the arguments; a trailing comma has ' +
      'an nkMissing after it',
    'FormattedArg | : | head once | derived | before the width, the second ' +
      'child',
    'FormattedArg | : | opt | derived | before the precision, a third child',
    'Index | [ | head once | derived | the kind',
    'Index | ] | once | derived | the kind',
    'Index | , | - | derived | between the indices',
    'Member | . | head once | derived | the kind; FirstToken is the dot',
    'Deref | ^ | head once | derived | the kind',
    'TypeArgs | < | head once | derived | the kind',
    'TypeArgs | > | opt | derived | the kind; a fused >= closing the list ' +
      'lies outside it (normalization list)',
    'TypeArgs | , | - | derived | between the arguments',
    'SetCtor | [ | head once | derived | the kind',
    'SetCtor | ] | once | derived | the kind',
    'SetCtor | , | - | derived | between the elements',
    'Range | .. | head once | derived | the kind',
    'InlineIf | if | head once | derived | the kind',
    'InlineIf | then | once | derived | the kind',
    'InlineIf | else | once | derived | the kind',
    'Inherited | inherited | head once | derived | the kind',
    'AnonMethod | procedure function | head once | derived | function when ' +
      'a result type child is there',
    'AnonMethod | : | opt | derived | before the result type',
    'NamedArg | := | head once | derived | the kind',

    // ---- statements ----
    'Block | begin | head opt | derived | a compound statement, a routine ' +
      'body or a main block - not a statement list inside try, finally, ' +
      'except, case else or repeat',
    'Block | end | opt | derived | closes the begin',
    'Block | else | head opt | derived | the else part of a case, or of an ' +
      'except with handlers',
    'Block | ; | - | derived | between the statements; runs of ; and one ' +
      'before end are optional (normalization list)',
    'Block | <eof> | opt | insig | the sentinel a ParseStatements root ends on',
    'Assign | := | once | derived | the kind',
    'IfStmt | if | head once | derived | the kind',
    'IfStmt | then | once | derived | the kind',
    'IfStmt | else | opt | derived | a third child',
    'CaseStmt | case | head once | derived | the kind',
    'CaseStmt | of | once | derived | the kind',
    'CaseStmt | end | once | derived | the kind',
    'CaseStmt | ; | - | derived | between the selectors; optional before ' +
      'else and end (normalization list)',
    'CaseSel | : | once | derived | the kind',
    'CaseLabels | , | - | derived | between the labels',
    'ForStmt | for | head once | derived | the kind',
    'ForStmt | := | once | derived | the kind',
    'ForStmt | to downto | once | derived | Aux 1: downto',
    'ForStmt | do | once | derived | the kind',
    'ForInStmt | for | head once | derived | the kind',
    'ForInStmt | in | once | derived | the kind',
    'ForInStmt | do | once | derived | the kind',
    'WhileStmt | while | head once | derived | the kind',
    'WhileStmt | do | once | derived | the kind',
    'RepeatStmt | repeat | head once | derived | the kind',
    'RepeatStmt | until | once | derived | the kind',
    'WithStmt | with | head once | derived | the kind',
    'WithStmt | , | - | derived | between the targets',
    'WithStmt | do | once | derived | the kind',
    'GotoStmt | goto | head once | derived | the kind',
    'LabeledStmt | : | once | derived | the kind',
    'TryStmt | try | head once | derived | the kind',
    'TryStmt | end | once | derived | the kind',
    'ExceptPart | except | head once | derived | the kind',
    'ExceptPart | ; | - | derived | between the handlers; optional after the ' +
      'last (normalization list)',
    'ExceptOn | on | head once | derived | the kind',
    'ExceptOn | : | opt | derived | three children: a name before the type',
    'ExceptOn | do | once | derived | the kind',
    'FinallyPart | finally | head once | derived | the kind',
    'RaiseStmt | raise | head once | derived | the kind',
    'RaiseStmt | at | opt | derived | a second child: the address',
    'AsmStmt | @any | - | contract | opaque by design (6.10): printed from ' +
      'its own token range',
    'InlineVar | var | head once | derived | the kind',
    'InlineVar | , | - | derived | between the names (nfName)',
    'InlineVar | : | opt | derived | before the type: a child after the ' +
      'names that is not the initializer',
    'InlineVar | := | opt | derived | before the initializer (Aux 1)',
    'InlineConst | const | head once | derived | the kind',
    'InlineConst | : | opt | derived | two children after the name: the type',
    'InlineConst | = | once | derived | the kind: before the value (Aux 1); ' +
      'a fused >= after type arguments is their > and this =',

    // ---- compilation units ----
    'Unit | unit | head once | derived | the kind',
    'Program | program | head once | derived | the kind',
    'Library | library | head once | derived | the kind',
    'Package | package | head once | derived | the kind',
    'Unit Program Library Package | ; | once | derived | after the name',
    'Unit Program Library Package | end | once | derived | the kind',
    'Unit Program Library Package | . | once | derived | the kind',
    'Unit Program Library Package | <eof> | opt | insig | the sentinel the ' +
      'root span ends on',
    'Program Library | class | - | derived | before a class method ' +
      'implementation, whose Routine has Aux 1',
    'ProgramParams | ( | head once | derived | the kind',
    'ProgramParams | ) | once | derived | the kind',
    'ProgramParams | , | - | derived | between the names',
    '* | @any | when:afterend | insig | text after the final end.: dcc ' +
      'ignores it; the root ends on its first token',
    'UsesClause | uses requires contains | head once | derived | uses ' +
      'outside a package; in one, Aux 1 is requires, else contains',
    'UsesClause | , | - | derived | between the items',
    'UsesClause | ; | once | derived | the kind',
    'UsesItem | in | opt | derived | a second child: the path',
    'InterfaceSec | interface | head once | derived | the kind',
    'ImplementationSec | implementation | head once | derived | the kind',
    'ImplementationSec | class | - | derived | before a class method ' +
      'implementation, whose Routine has Aux 1',
    'InitSec | initialization begin | head once | contract | the head word: ' +
      'a unit''s legacy `begin ... end.` opens the same section, but gives ' +
      'other .dcu line records (F30)',
    'InitSec | ; | - | derived | between the statements',
    'FinalSec | finalization | head once | derived | the kind',
    'FinalSec | ; | - | derived | between the statements',
    'ExportsClause | exports | head once | derived | the kind',
    'ExportsClause | , | - | derived | between the items',
    'ExportsClause | ; | once | derived | the kind',
    'ExportsItem | name index | - | derived | nfExtName, nfExtIndex on the ' +
      'value after the word (F14)',
    'ExportsItem | resident | opt | derived | nfResident on the item (F14)',

    // ---- declaration sections ----
    'TypeSec | type | head once | derived | the kind',
    'TypeSec | ; | - | derived | after each declaration',
    'ConstSec | const resourcestring | head once | contract | the head word',
    'ConstSec | ; | - | derived | after each declaration',
    'VarSec | var threadvar | head opt | contract | the head word; a class ' +
      'var run and a section in a struct body have none (F9)',
    'VarSec | ; | - | derived | after each declaration; the last of a class ' +
      'var run or a struct body''s var section may stop at the end',
    'LabelSec | label | head once | derived | the kind',
    'LabelSec | , | - | derived | between the labels',
    'LabelSec | ; | once | derived | the kind',
    'TypeDecl | = | opt | derived | the kind; a fused >= after generic ' +
      'parameters is their > and this = (normalization list)',
    'TypeDecl | type | opt | derived | Aux 1: a distinct alias, `= type X`',
    'TypeDecl | reference | opt | derived | the ProcType child''s Aux 2; ' +
      'outside its span',
    'TypeDecl | to | opt | derived | the ProcType child''s Aux 2; outside ' +
      'its span',
    'TypeDecl VarDecl ConstDecl ArrayType FileType InlineVar InlineConst | ' +
      'packed | opt | derived | the type child''s nfPacked; outside its ' +
      'span (F3)',
    'ConstDecl | : | opt | derived | two children after the name: the type ' +
      'and the value',
    'ConstDecl | = | once | derived | the kind; a fused >= after type ' +
      'arguments is their > and this =',
    'VarDecl | , | - | derived | between the names (nfName)',
    'VarDecl | : | once | derived | the kind: after the names',
    'VarDecl | = | opt | derived | before the initializer; a fused >= ' +
      'after type arguments is their > and this =',
    'VarDecl | absolute | opt | derived | Aux 1',
    'Aggregate | ( | head once | derived | the kind',
    'Aggregate | ) | once | derived | the kind',
    'Aggregate | , ; | - | derived | between the elements: ; between record ' +
      'fields (AggregateField children), a comma otherwise',
    'AggregateField | : | once | derived | the kind',

    // ---- type expressions ----
    'Subrange | .. | head once | derived | the kind',
    'EnumType | ( | head once | derived | the kind',
    'EnumType | ) | once | derived | the kind',
    'EnumType | , | - | derived | between the values',
    'EnumValue | = | opt | derived | a second child: the ordinal',
    'ArrayType | array | head once | derived | the kind',
    'ArrayType | [ | opt | derived | index type children before the element ' +
      'type',
    'ArrayType | ] | opt | derived | closes the [',
    'ArrayType | , | - | derived | between the index types',
    'ArrayType | of | once | derived | the kind',
    'ArrayType | const | opt | derived | Aux 1: array of const',
    'SetType | set | head once | derived | the kind',
    'SetType | of | once | derived | the kind',
    'FileType | file | head once | derived | the kind',
    'FileType | of | opt | derived | a child: the element type',
    'PointerType | ^ | head once | derived | the kind',
    'StringType | string | head once | derived | the kind',
    'StringType | [ | once | derived | the kind',
    'StringType | ] | once | derived | the kind',
    'ClassOf | class type | head once | derived | Aux 1: type of',
    'ClassOf | of | once | derived | the kind',
    'ClassOf | interface | opt | derived | Aux 1 and no child: type of ' +
      'interface',
    'ProcType | procedure function | head once | derived | function when a ' +
      'result type child is there',
    'ProcType | : | opt | derived | before the result type',
    'ProcType | of | opt | derived | Aux 1: of object',
    'ProcType | object | opt | derived | Aux 1: of object',
    'ProcType | ; | opt | derived | before the directive child whose Aux ' +
      'is 1, `procedure; stdcall` (F29: one type with `procedure stdcall`, ' +
      'not one .dcu)',
    'ClassType | class | head once | derived | the kind',
    'ClassType RecordType ObjectType HelperType | class | - | derived | ' +
      'before each member whose Aux is 1: class method, property, var',
    'ClassType ObjectType InterfaceType HelperType | ( | opt | derived | the ' +
      'ancestors: the leading type-reference children',
    'ClassType ObjectType InterfaceType HelperType | ) | opt | derived | ' +
      'closes the (',
    'ClassType | , | - | derived | between the ancestors',
    'ClassType RecordType ObjectType | ; | - | derived | after each field ' +
      'declaration',
    'ClassType ObjectType InterfaceType | end | opt | derived | absent in a ' +
      'forward declaration (Aux); a class with no member may also stop at ' +
      'its ancestors, `class(TBase);` - no mark (normalization list)',
    'ClassType ObjectType | abstract sealed | - | derived | nfAbstract, ' +
      'nfSealed: right after the head word; a repeat is one (N12) (F4)',
    'ClassType RecordType HelperType ObjectType | var threadvar | - | ' +
      'derived | the head of a VarSec child, outside its span: var (Aux nil) ' +
      'or class var (Aux 1); nfThreadvar says threadvar (F9)',
    'RecordType | record | head once | derived | the kind',
    'RecordType HelperType | end | once | derived | the kind',
    'RecordType | align | opt | derived | a trailing expression child, ' +
      '`end align 16`',
    'InterfaceType | interface dispinterface | head once | derived | Aux bit ' +
      '1: dispinterface',
    'ObjectType | object | head once | derived | the kind',
    'HelperType | class record | head once | derived | Aux 1: record helper',
    'HelperType | helper | once | derived | the kind',
    'HelperType | for | once | derived | the kind',
    'Guid | [ | head once | derived | the kind',
    'Guid | ] | once | derived | the kind',

    // ---- members and routines ----
    'Visibility | private protected public published automated | once | ' +
      'derived | Aux 1..5',
    'Visibility | strict | head opt | derived | nfNegated: strict private, ' +
      'strict protected',
    'Routine | procedure function constructor destructor operator | head ' +
      'once | contract | the head word; a `class` before it is the ' +
      'parent''s token (Aux 1)',
    'Routine | . | - | derived | between the name segments (nfName)',
    'Routine | : | opt | derived | before the result type',
    'Routine | ; | - | derived | after the header, each directive and the ' +
      'body; the last directive''s may be missing, and the header''s may ' +
      'follow directives written before it, `function F: Bool stdcall;` ' +
      '(normalization list)',
    'Params | ( [ | head once | derived | [ for the index parameters of a ' +
      'property',
    'Params | ) ] | once | derived | closes the list',
    'Params | ; | - | derived | between the parameters',
    'Param | , | - | derived | between the names (nfName)',
    'Param | : | opt | derived | before the type: a child after the names',
    'Param | = | opt | derived | before the default value; a fused >= ' +
      'after type arguments is their > and this =',
    'Param | const var out | opt | derived | nfVar, nfConst, nfOut: the mode ' +
      'word, at the left edge or right after a leading attribute group (F18)',
    'Directive | @routine | head once | contract | the directive word',
    'Directive | name index dependency delayed , | - | derived | inside ' +
      'external: nfExtName, nfExtIndex, nfExtDependency on the value after ' +
      'the word (or the `,` of a dependency list), nfDelayed on the ' +
      'directive (F13)',
    'PropertyDecl | property | head once | derived | the kind; a `class` ' +
      'before it is the parent''s token (Aux 1)',
    'PropertyDecl | : | opt | derived | before the type, which a ' +
      'redeclaration omits',
    'PropertyDecl | ; | - | derived | after the specifiers and after the ' +
      'hints',
    'PropSpec | read write index stored default nodefault implements ' +
      'readonly writeonly dispid | head once | contract | the specifier word',
    'PropSpec | , | - | derived | between the implemented interfaces',
    'PropSpec | ; | opt | derived | the trailing `default;` of an array ' +
      'property owns its ;',
    'MethodResolution | procedure function | head once | contract | the head ' +
      'word',
    'MethodResolution | . | - | derived | between the name segments',
    'MethodResolution | = | once | derived | before the last child, the ' +
      'implementing method',
    'MethodResolution | ; | once | derived | the kind',
    'VariantPart | case | head once | derived | the kind',
    'VariantPart | of | once | derived | the kind',
    'VariantPart | : | opt | derived | two children before the branches: the ' +
      'tag name and its type',
    'VariantPart | ; | - | derived | between the branches',
    'VariantBranch | : | once | derived | after the labels, the expression ' +
      'children',
    'VariantBranch | ( | once | derived | the kind',
    'VariantBranch | ) | once | derived | the kind',
    'VariantBranch | , | - | derived | between the labels',
    'VariantBranch | ; | - | derived | after each field declaration',
    'GenericParams | < | head once | derived | the kind',
    'GenericParams | > | opt | derived | the kind; a fused >= closing the ' +
      'list lies outside it (normalization list)',
    'GenericParams | ; | - | derived | between the parameter groups',
    'GenericParam | , | - | derived | between the names and between the ' +
      'constraints',
    'GenericParam | : | opt | derived | before the Constraint children',
    'Constraint | class record constructor | head opt | contract | the ' +
      'constraint word; a type constraint has a child instead',
    'AttrGroup | [ ] , | - | derived | one pair at least; how many bracket ' +
      'groups is not recorded: [A][B] = [A, B] (normalization list)',
    'Attribute | ( ) | when:noargs | insig | an empty argument list, ' +
      '`[A()]`, leaves no child: = `[A]` (normalization list)',
    'Attribute | ( | opt | derived | the argument children after the name',
    'Attribute | ) | opt | derived | closes the (',
    'Attribute | , | - | derived | between the arguments',
    'Attribute | <ident> | head opt | contract | nfAttrTarget: the target ' +
      'word, `[Result: Tag]`',
    'Attribute | : | opt | derived | nfAttrTarget: after the target word'
  );

{ TPasCheckReport }

procedure TPasCheckReport.Init(AMaxKept: Integer);
var
  LShape: TPasCheckShape;
  LCls: TPasCheckClass;
  LIdx: Integer;
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
  OwnCounts := nil;
  SetLength(OwnCounts, OwnRuleCount);
  SetLength(OwnSites, OwnRuleCount);
  for LIdx := 0 to High(OwnSites) do
    OwnSites[LIdx] := -1;
  OwnUnlisted := 0;
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

const
  CELL_WORD_MAX_LEN = 15;

var
  // The cell words (DIRECTIVE_WORDS, then CELL_EXTRA_WORDS) by length and
  // lower-cased first letter, each bucket in word order: OwnTokenCell runs
  // for every owned identifier, and a plain name compared against all 60
  // words through an out-of-line call (audit C1-49). Built once, read-only.
  GCellWords: array[1..CELL_WORD_MAX_LEN, 'a'..'z'] of TArray<SmallInt>;

procedure BuildCellWords;
var
  LIdx: Integer;
  LWord: string;
begin
  for LIdx := 0 to Length(DIRECTIVE_WORDS) + High(CELL_EXTRA_WORDS) do
  begin
    if LIdx <= High(DIRECTIVE_WORDS) then
      LWord := DIRECTIVE_WORDS[LIdx]
    else
      LWord := CELL_EXTRA_WORDS[LIdx - Length(DIRECTIVE_WORDS)];
    // Every word is lower-case ASCII and short; one that is not would never
    // be found, so it stops the program at once instead.
    Assert((Length(LWord) >= 1) and (Length(LWord) <= CELL_WORD_MAX_LEN) and
      CharInSet(LWord[1], ['a'..'z']));
    GCellWords[Length(LWord), LWord[1]] :=
      GCellWords[Length(LWord), LWord[1]] + [SmallInt(LIdx)];
  end;
end;

function OwnTokenCell(const ASource: TPasPreprocessed;
  AVisIndex: Integer): Integer;
var
  LKind: TPasTokenKind;
  LText: PChar;
  LLen: Integer;
  LCh: Char;
  LWord: SmallInt;
  LMatch: Boolean;
begin
  LKind := ASource.VisibleKind(AVisIndex);
  if LKind <> tkIdentifier then
    Exit(Ord(LKind));
  ASource.VisibleSlice(AVisIndex, LText, LLen);
  // An &-escaped identifier keeps its '&' and never matches: it is a name.
  if (LLen < 1) or (LLen > CELL_WORD_MAX_LEN) then
    Exit(CELL_IDENT);
  LCh := LText^;
  if (LCh >= 'A') and (LCh <= 'Z') then
    Inc(LCh, 32);
  if (LCh < 'a') or (LCh > 'z') then
    Exit(CELL_IDENT);
  for LWord in GCellWords[LLen, LCh] do
  begin
    if LWord <= High(DIRECTIVE_WORDS) then
      LMatch := SliceEqualsWord(LText, LLen, DIRECTIVE_WORDS[LWord])
    else
      LMatch := SliceEqualsWord(LText, LLen,
        CELL_EXTRA_WORDS[LWord - Length(DIRECTIVE_WORDS)]);
    if LMatch then
      Exit(CELL_WORD_BASE + LWord);
  end;
  Result := CELL_IDENT;
end;

{ The own-token table, built from OWN_RULE_TEXT once, when the unit
  initializes - read-only afterwards, so CheckTree may run on any thread. }

var
  GOwnRules: TArray<TPasOwnRule>;
  GOwnCellCount: Integer;
  // Per (kind, cell, at the head or not): the rule without a condition that
  // covers the token; -1 when none does.
  GOwnPrimary: TArray<SmallInt>;
  GOwnKindCond: array[TPasNodeKind] of TArray<Integer>;  // rules with when:
  GOwnGlobal: array[TPasOwnCond] of Integer;             // the `*` rules
  GOwnMult: array[TPasNodeKind] of TArray<Integer>;      // once / opt rules
  GOwnErrors: string;

function OwnSlot(AKind: TPasNodeKind; ACell: Integer; AHead: Boolean): Integer;
  inline;
begin
  Result := (Ord(AKind) * GOwnCellCount + ACell) * 2 + Ord(AHead);
end;

procedure BuildOwnTable;
var
  LNames: TDictionary<string, Integer>;
  LKinds: TDictionary<string, TPasNodeKind>;
  LNamer: TPasTree;        // for KindName, which reads no field
  LPrec: TArray<Byte>;     // per slot: the claiming rule's precedence
  LExplicit: TArray<Boolean>;
  LFields: TArray<string>;
  LRule: TPasOwnRule;
  LIdx, LCell: Integer;
  LKind: TPasNodeKind;
  LCond: TPasOwnCond;
  LTk: TPasTokenKind;
  LWord, LField, LName: string;

  procedure Fail(const AMsg: string);
  begin
    GOwnErrors := GOwnErrors + Format('OWN_RULE_TEXT[%d] %s | %s: %s',
      [LIdx, LRule.KindsText, LRule.CellsText, AMsg]) + sLineBreak;
  end;

  procedure SetCell(const AName: string; AExplicit: Boolean);
  var
    LAt: Integer;
  begin
    if LNames.TryGetValue(AName, LAt) then
    begin
      LRule.Cells[LAt] := True;
      if AExplicit then
        LExplicit[LAt] := True;
    end
    else
      Fail('no cell is named ' + AName);
  end;

  // At the head a head rule wins over a positionless one, and a cell named
  // outright over one a set brings in; two alike are an error.
  procedure Claim(AKind: TPasNodeKind; ACell: Integer; AHead: Boolean);
  const
    WHERE: array[Boolean] of string = ('', ' at the head');
  var
    LSlot: Integer;
    LPrecOf: Byte;
  begin
    LSlot := OwnSlot(AKind, ACell, AHead);
    LPrecOf := 1 + Ord(LExplicit[ACell]) + 2 * Ord(LRule.Head);
    if LPrec[LSlot] = LPrecOf then
      Fail(Format('%s %s%s is claimed by rule %d as well', [
        LNamer.KindName(AKind), OwnTokenCellName(ACell), WHERE[AHead],
        GOwnPrimary[LSlot]]))
    else if LPrec[LSlot] < LPrecOf then
    begin
      GOwnPrimary[LSlot] := LIdx;
      LPrec[LSlot] := LPrecOf;
    end;
  end;

begin
  GOwnErrors := '';
  LNamer := Default(TPasTree);
  GOwnCellCount := OwnTokenCellCount;
  for LCond := Low(TPasOwnCond) to High(TPasOwnCond) do
    GOwnGlobal[LCond] := -1;
  SetLength(GOwnPrimary, (Ord(High(TPasNodeKind)) + 1) * GOwnCellCount * 2);
  for LIdx := 0 to High(GOwnPrimary) do
    GOwnPrimary[LIdx] := -1;
  SetLength(LPrec, Length(GOwnPrimary));
  SetLength(GOwnRules, Length(OWN_RULE_TEXT));
  LKinds := TDictionary<string, TPasNodeKind>.Create;
  LNames := TDictionary<string, Integer>.Create;
  try
    for LKind := Low(TPasNodeKind) to High(TPasNodeKind) do
      LKinds.Add(LNamer.KindName(LKind), LKind);
    LIdx := -1;
    for LCell := 0 to GOwnCellCount - 1 do
    begin
      LName := OwnTokenCellName(LCell);
      // Trivia is never visible, and several kinds share the name.
      if LName = '<trivia>' then
        Continue;
      if LNames.ContainsKey(LName) then
        Fail('two cells are named ' + LName)
      else
        LNames.Add(LName, LCell);
    end;
    for LIdx := 0 to High(OWN_RULE_TEXT) do
    begin
      LRule := Default(TPasOwnRule);
      LFields := OWN_RULE_TEXT[LIdx].Split(['|']);
      if Length(LFields) <> 5 then
      begin
        Fail('five fields expected');
        Continue;
      end;
      LRule.KindsText := Trim(LFields[0]);
      LRule.CellsText := Trim(LFields[1]);
      LRule.Note := Trim(LFields[4]);
      SetLength(LRule.Cells, GOwnCellCount);
      LExplicit := nil;
      SetLength(LExplicit, GOwnCellCount);

      for LField in LRule.KindsText.Split([' '],
        TStringSplitOptions.ExcludeEmpty) do
        if LField = '*' then
          LRule.AllKinds := True
        else if LKinds.TryGetValue(LField, LKind) then
          Include(LRule.Kinds, LKind)
        else
          Fail('no node kind ' + LField);

      for LField in LRule.CellsText.Split([' '],
        TStringSplitOptions.ExcludeEmpty) do
        if LField = '@any' then
          for LCell := 0 to GOwnCellCount - 1 do
            LRule.Cells[LCell] := True
        else if LField = '@keywords' then
          for LTk := tkAnd to tkXor do
            LRule.Cells[Ord(LTk)] := True
        else if LField = '@words' then
          for LCell := CELL_WORD_BASE to GOwnCellCount - 1 do
            LRule.Cells[LCell] := True
        else if LField = '@routine' then
        begin
          for LWord in ROUTINE_DIRECTIVE_WORDS do
            SetCell(LWord, False);
          LRule.Cells[Ord(tkInline)] := True;
          LRule.Cells[Ord(tkLibrary)] := True;
        end
        else
          SetCell(LField, True);

      for LField in Trim(LFields[2]).Split([' '],
        TStringSplitOptions.ExcludeEmpty) do
        if LField = '-' then
          // no flag
        else if LField = 'head' then
          LRule.Head := True
        else if LField = 'once' then
          LRule.Mult := omOnce
        else if LField = 'opt' then
          LRule.Mult := omOpt
        else if LField = 'when:noargs' then
          LRule.Cond := wcNoArgs
        else if LField = 'when:afterend' then
          LRule.Cond := wcAfterEnd
        else
          Fail('no flag ' + LField);

      LField := Trim(LFields[3]);
      if LField = 'derived' then
        LRule.Cls := ocDerived
      else if LField = 'leaf' then
        LRule.Cls := ocLeaf
      else if LField = 'contract' then
        LRule.Cls := ocContract
      else if LField = 'insig' then
        LRule.Cls := ocInsignificant
      else if LField.StartsWith('loss:F') and (Length(LField) > 6) then
      begin
        LRule.Cls := ocLoss;
        LRule.Finding := Copy(LField, 6, MaxInt);
      end
      else
        Fail('no class ' + LField);

      // The token-level conditions go with `*`, the node-level ones with
      // named kinds; a count belongs to the rule without a condition.
      if (LRule.Cond <> wcNone) and (LRule.Mult <> omMany) then
        Fail('a rule with a condition takes no count')
      else if LRule.AllKinds <> (LRule.Cond = wcAfterEnd) then
        Fail('`*` goes with when:afterend, and it with `*`')
      else if LRule.AllKinds then
      begin
        if LRule.Kinds <> [] then
          Fail('`*` beside named kinds')
        else if GOwnGlobal[LRule.Cond] >= 0 then
          Fail('a second `*` rule for one condition')
        else
          GOwnGlobal[LRule.Cond] := LIdx;
      end
      else if LRule.Kinds = [] then
        Fail('no kind')
      else
        for LKind in LRule.Kinds do
        begin
          if LRule.Cond <> wcNone then
            GOwnKindCond[LKind] := GOwnKindCond[LKind] + [LIdx]
          else
            for LCell := 0 to GOwnCellCount - 1 do
              if LRule.Cells[LCell] then
              begin
                Claim(LKind, LCell, True);
                if not LRule.Head then
                  Claim(LKind, LCell, False);
              end;
          if LRule.Mult <> omMany then
            GOwnMult[LKind] := GOwnMult[LKind] + [LIdx];
        end;
      GOwnRules[LIdx] := LRule;
    end;
  finally
    LNames.Free;
    LKinds.Free;
  end;
end;

function OwnRuleCount: Integer;
begin
  Result := Length(GOwnRules);
end;

function OwnRule(AIndex: Integer): TPasOwnRule;
begin
  Result := GOwnRules[AIndex];
end;

function OwnRuleTableErrors: string;
begin
  Result := GOwnErrors;
end;

function OwnClassName(ACls: TPasOwnClass): string;
const
  NAMES: array[TPasOwnClass] of string = (
    'derived', 'leaf', 'contract', 'insignificant', 'loss');
begin
  Result := NAMES[ACls];
end;

function OwnRuleClassText(ARule: Integer): string;
begin
  if (ARule < 0) or (ARule > High(GOwnRules)) then
    Exit('UNLISTED');
  Result := OwnClassName(GOwnRules[ARule].Cls);
  if GOwnRules[ARule].Cls = ocLoss then
    Result := Result + ' ' + GOwnRules[ARule].Finding;
end;

// The line and column of a visible token in range; its file id is the result.
function VisLineCol(const ASource: TPasPreprocessed; AVisIndex: Integer;
  out ALine, ACol: Integer): Integer;
var
  LVis: TPasVisibleToken;
begin
  LVis := ASource.Visible[AVisIndex];
  ASource.Files[LVis.FileId].OffsetToLineCol(
    ASource.Files[LVis.FileId].Tokens[LVis.TokenIndex].Start, ALine, ACol);
  Result := LVis.FileId;
end;

function VisSiteText(const ASource: TPasPreprocessed;
  AVisIndex: Integer): string;
var
  LFile, LLine, LCol: Integer;
begin
  if (AVisIndex < 0) or (AVisIndex > High(ASource.Visible)) then
  begin
    if Length(ASource.FileNames) > 0 then
      Exit(ASource.FileNames[0]);
    Exit('?');
  end;
  LFile := VisLineCol(ASource, AVisIndex, LLine, LCol);
  Result := Format('%s(%d,%d)', [ASource.FileNames[LFile], LLine, LCol]);
end;

function IsEmptyNode(const ATree: TPasTree; ANode: Integer): Boolean;
begin
  Result := (ATree.Nodes[ANode].Kind in PAS_ZERO_WIDTH_KINDS) or
    (ATree.Nodes[ANode].LastToken < ATree.Nodes[ANode].FirstToken);
end;

function IsFusedGreaterEqual(const ATree: TPasTree; ANode: Integer): Boolean;
var
  LCount, LOp, LNode, LLast, LSteps: Integer;

  function Valid(AIdx: Integer): Boolean;
  begin
    Result := (AIdx >= 0) and (AIdx < LCount);
  end;

  // The last child reachable through valid links.
  function LastKid(AParent: Integer): Integer;
  var
    LKid, LGuard: Integer;
  begin
    Result := NIL_NODE;
    LKid := ATree.Nodes[AParent].FirstChild;
    LGuard := 0;
    while Valid(LKid) and (LGuard < LCount) do
    begin
      Result := LKid;
      LKid := ATree.Nodes[LKid].NextSibling;
      Inc(LGuard);
    end;
  end;

begin
  Result := False;
  LCount := Length(ATree.Nodes);
  if not Valid(ANode) or (ATree.Nodes[ANode].Kind <> nkBinaryOp) then
    Exit;
  LOp := ATree.Nodes[ANode].Aux;
  if (LOp < 1) or (LOp > High(ATree.Source.Visible)) or
     (ATree.Source.VisibleKind(LOp) <> tkGreaterEqual) then
    Exit;
  LNode := ATree.Nodes[ANode].FirstChild;
  LSteps := 0;
  while Valid(LNode) and (LSteps < LCount) and
        (ATree.Nodes[LNode].LastToken = LOp - 1) do
  begin
    if ATree.Nodes[LNode].Kind = nkTypeArgs then
    begin
      LLast := LastKid(LNode);
      Exit(Valid(LLast) and
        (ATree.Nodes[LLast].LastToken = ATree.Nodes[LNode].LastToken));
    end;
    LNode := LastKid(LNode);
    Inc(LSteps);
  end;
end;

function PasFusedGreaterEquals(const ATree: TPasTree): TArray<Boolean>;
var
  LCount, LNode, LKid, LLast, LGuard, LAfter: Integer;
begin
  SetLength(Result, Length(ATree.Source.Visible));
  LCount := Length(ATree.Nodes);
  for LNode := 0 to LCount - 1 do
  begin
    if not (ATree.Nodes[LNode].Kind in [nkTypeArgs, nkGenericParams]) then
      Continue;
    LAfter := ATree.Nodes[LNode].LastToken + 1;
    if (LAfter < 1) or (LAfter > High(Result)) or
       (ATree.Nodes[LNode].LastToken < ATree.Nodes[LNode].FirstToken) or
       (ATree.Source.VisibleKind(LAfter) <> tkGreaterEqual) then
      Continue;
    LLast := NIL_NODE;
    LKid := ATree.Nodes[LNode].FirstChild;
    LGuard := 0;
    while (LKid >= 0) and (LKid < LCount) and (LGuard < LCount) do
    begin
      LLast := LKid;
      LKid := ATree.Nodes[LKid].NextSibling;
      Inc(LGuard);
    end;
    if (LLast <> NIL_NODE) and
       (ATree.Nodes[LLast].LastToken = ATree.Nodes[LNode].LastToken) then
      Result[LAfter] := True;
  end;
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
    nkVarDecl, nkVarSec, nkConstSec, nkForStmt, nkUsesClause, nkInlineVar,
    nkInlineConst, nkDirective:
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
  // The kinds whose FirstToken is an interior token - the operator, the
  // bracket or the dot after their first child (tree-contract.md sec. 5):
  // their span starts where that child does.
  LEFT_OPERAND_KINDS = [nkMember, nkBinaryOp, nkCall, nkIndex, nkDeref,
    nkTypeArgs, nkRange, nkSubrange, nkFormattedArg, nkNamedArg];
var
  LCount, LLastVis, LBefore, LOrderCount, LOrphanStart: Integer;
  LState: TArray<Byte>;
  LBadTok, LEmpty: TArray<Boolean>;
  LIsTop: TArray<Boolean>;  // the top of an unreachable subtree (WalkOrphans)
  // Per visible token: a fused `>=` after type arguments or generic
  // parameters, read as its owner's `=` (PasFusedGreaterEquals).
  LFusedGE: TArray<Boolean>;
  LLo, LHi, LOrder, LOwner, LStack: TArray<Integer>;
  // The children Walk accepted, per node: every later pass follows a child
  // list this far and no further, so a list that loops ends where Walk
  // stopped it.
  LKidCount: TArray<Integer>;
  LKids: TArray<Integer>;   // SettlePlaceholders' scratch: one child list
  // I5: the token after the final `end.` (-1: no csAfterEnd).
  LAfterEnd: Integer;
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
    Result := ATree.Source.VisibleKind(AVis);
  end;

  // TokKind, but a fused `>=` after type arguments is the `=` it ends in:
  // the `>` is theirs, outside the owner's reading.
  function ReadKind(AVis: Integer): TPasTokenKind;
  begin
    Result := TokKind(AVis);
    if (Result = tkGreaterEqual) and LFusedGE[AVis] then
      Result := tkEqual;
  end;

  // 'line:col' of a visible token, for the second position in a message.
  function At(AVis: Integer): string;
  var
    LLine, LCol: Integer;
  begin
    if (AVis < 0) or (AVis > LLastVis) then
      Exit(Format('#%d', [AVis]));
    VisLineCol(ATree.Source, AVis, LLine, LCol);
    Result := Format('%d:%d', [LLine, LCol]);
  end;

  function Site(ANode: Integer): Integer;
  begin
    if LBadTok[ANode] then
      Result := -1
    else
      Result := ATree.Nodes[ANode].FirstToken;
  end;

  // A violation, its message rendered here, only when one is found: a check
  // that built it inline paid the hidden string temporaries of every KName,
  // At and Format at the call site on each call, valid code included - about
  // 18% of CheckTree (audit C1-48). In ATemplate, {n} is the kind name of the
  // next argument (a node), {a} its site (a visible token), {d} the integer
  // itself and {c} its own-token cell name.
  procedure Report(ACls: TPasCheckClass; ANode, AVisIndex: Integer;
    const ATemplate: string; const AArgs: array of Integer);
  var
    LMsg: string;
    LIdx, LArg: Integer;
  begin
    LMsg := '';
    LArg := 0;
    LIdx := 1;
    while LIdx <= Length(ATemplate) do
      if (ATemplate[LIdx] = '{') and (LIdx + 2 <= Length(ATemplate)) and
         (ATemplate[LIdx + 2] = '}') and (LArg <= High(AArgs)) then
      begin
        case ATemplate[LIdx + 1] of
          'n': LMsg := LMsg + KName(AArgs[LArg]);
          'a': LMsg := LMsg + At(AArgs[LArg]);
          'd': LMsg := LMsg + IntToStr(AArgs[LArg]);
          'c': LMsg := LMsg + OwnTokenCellName(AArgs[LArg]);
        end;
        Inc(LArg);
        Inc(LIdx, 3);
      end
      else
      begin
        LMsg := LMsg + ATemplate[LIdx];
        Inc(LIdx);
      end;
    AReport.Add(ACls, ANode, AVisIndex, LMsg);
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

  // I3 after the root's walk: every unreachable subtree from its own top,
  // marked in LIsTop. A top is a node whose Parent is out of range - the
  // parser's orphans have none - or whose Parent's child list, as far as it
  // can be followed, does not hold it: that names a Parent which does not
  // list it, the one violation such a subtree is. Its descendants, each on
  // its own parent's list, are no tops and not reported again (audit
  // B1-34). What a top's walk does not reach - a ring of nodes listing one
  // another, none listed from outside - is walked from its lowest index.
  procedure WalkOrphans;
  var
    LNode, LKid, LSteps: Integer;
    LHeld: TArray<Boolean>;   // on the child list of its unreached Parent

    procedure Top(ANode: Integer; ALinked: Boolean);
    begin
      if ALinked then
        AReport.Add(ccLink, ANode, Site(ANode), Format(
          '%s node %d names Parent %d, whose child list does not hold it',
          [KName(ANode), ANode, ATree.Nodes[ANode].Parent]));
      LIsTop[ANode] := True;
      Walk(ANode, ST_ORPHAN);
    end;

  begin
    for LNode := 1 to LCount - 1 do
      if (LState[LNode] = ST_NONE) and not LinkOk(ATree.Nodes[LNode].Parent) then
        Top(LNode, False);
    if LOrderCount = LCount then
      Exit;
    SetLength(LHeld, LCount);
    for LNode := 1 to LCount - 1 do
      if LState[LNode] = ST_NONE then
      begin
        LKid := ATree.Nodes[LNode].FirstChild;
        LSteps := 0;
        while LinkOk(LKid) and (LSteps < LCount) do
        begin
          if ATree.Nodes[LKid].Parent = LNode then
          begin
            if LHeld[LKid] then
              Break;   // the list loops
            LHeld[LKid] := True;
          end;
          LKid := ATree.Nodes[LKid].NextSibling;
          Inc(LSteps);
        end;
      end;
    for LNode := 1 to LCount - 1 do
      if (LState[LNode] = ST_NONE) and not LHeld[LNode] then
        Top(LNode, True);
    // Its walk reports the ring, where it comes back round.
    for LNode := 1 to LCount - 1 do
      if LState[LNode] = ST_NONE then
        Top(LNode, False);
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
    LFirst, LLast, LMin, LLeadMin, LKid, LIdx: Integer;
    LHasFull, LLead: Boolean;
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
    LLeadMin := MaxInt;
    LLead := True;
    LHasFull := False;
    LKid := ATree.Nodes[ANode].FirstChild;
    for LIdx := 1 to LKidCount[ANode] do
    begin
      if Kind(LKid) <> nkAttrGroup then
        LLead := False;
      if not LEmpty[LKid] then
      begin
        LHasFull := True;
        LMin := Min(LMin, LLo[LKid]);
        if LLead then
          LLeadMin := Min(LLeadMin, LLo[LKid]);
      end;
      LKid := ATree.Nodes[LKid].NextSibling;
    end;
    if Kind(ANode) in PAS_ZERO_WIDTH_KINDS then
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
      // Only a kind whose FirstToken stands after its left operand, and the
      // attribute groups leading a declaration whose FirstToken is its name
      // (`[Weak] FRef: TObject`), reach left of FirstToken; any other child
      // starting first is an I2 violation (audit B1-35).
      if Kind(ANode) in LEFT_OPERAND_KINDS then
        LLo[ANode] := Min(LFirst, LMin)
      else
        LLo[ANode] := Min(LFirst, LLeadMin);
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
              Report(ccContain, LKid, LAnchor,
                'empty {n} (child {d}) anchored at {a}, away from its empty ' +
                'parent {n} at {a}', [LKid, LIdx, LAnchor, ANode, LLo[ANode]]);
          end
          else if (LAnchor < LLo[ANode]) or (LAnchor > LHi[ANode] + 1) then
            Report(ccContain, LKid, LAnchor,
              'empty {n} (child {d}) anchored at {a}, outside its parent {n} ' +
              '{a}..{a}', [LKid, LIdx, LAnchor, ANode, LLo[ANode], LHi[ANode]])
          else if (LAnchor <= LPrevEnd) or (LAnchor < LPrevAnchor) then
            Report(ccOrder, LKid, LAnchor,
              'empty {n} (child {d} of {n}) anchored at {a}, before the end ' +
              'of the sibling before it', [LKid, LIdx, ANode, LAnchor]);
          LPrevAnchor := Max(LPrevAnchor, LAnchor);
        end
        else if not LEmpty[ANode] then
        begin
          if LLo[LKid] < LLo[ANode] then
            Report(ccContain, LKid, LLo[LKid],
              '{n} (child {d}) {a}..{a} starts before its parent {n} {a}..{a}',
              [LKid, LIdx, LLo[LKid], LHi[LKid], ANode, LLo[ANode],
              LHi[ANode]]);
          if LHi[LKid] > LHi[ANode] then
            Report(ccContain, LKid, LLo[LKid],
              '{n} (child {d}) {a}..{a} ends after its parent {n} {a}..{a}',
              [LKid, LIdx, LLo[LKid], LHi[LKid], ANode, LLo[ANode],
              LHi[ANode]]);
          if LLo[LKid] <= LPrevEnd then
            Report(ccOrder, LKid, LLo[LKid],
              '{n} (child {d} of {n}) starts at {a}, inside the sibling ' +
              'before it (ends {a})', [LKid, LIdx, ANode, LLo[LKid], LPrevEnd])
          else if LLo[LKid] < LPrevAnchor then
            Report(ccOrder, LKid, LLo[LKid],
              '{n} (child {d} of {n}) starts at {a}, before an empty ' +
              'sibling''s anchor {a}', [LKid, LIdx, ANode, LLo[LKid],
              LPrevAnchor]);
          LPrevEnd := Max(LPrevEnd, LHi[LKid]);
          LPrevAnchor := Max(LPrevAnchor, LHi[LKid] + 1);
        end;
      end;
      LKid := LNextKid;
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
    else if not LEmpty[ARoot] and (TokKind(LHi[ARoot] + 1) in PAS_REREAD_TOKENS)
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

  // I5: does a rule's node-level condition hold for ANode?
  function CondHolds(ACond: TPasOwnCond; ANode: Integer): Boolean;
  begin
    case ACond of
      wcNoArgs:
        Result := LKidCount[ANode] <= 1;
    else
      Result := False;
    end;
  end;

  // I5: the rule that covers ANode's own token ATok (-1: none), the token's
  // cell, and the rule without a condition that covers it - the one its
  // count goes to (-1 for a token of a `*` rule, which counts for none).
  function ClassifyOwn(ANode, ATok: Integer; out ACell,
    APrimary: Integer): Integer;
  var
    LKind: TPasNodeKind;
    LHead: Boolean;
    LRule: Integer;
  begin
    ACell := OwnTokenCell(ATree.Source, ATok);
    if LFusedGE[ATok] then
      ACell := Ord(tkEqual);
    APrimary := -1;
    if (ATok = LAfterEnd) and (ANode = 0) and
       (GOwnGlobal[wcAfterEnd] >= 0) then
      Exit(GOwnGlobal[wcAfterEnd]);
    LKind := Kind(ANode);
    LHead := ATok = ATree.Nodes[ANode].FirstToken;
    APrimary := GOwnPrimary[OwnSlot(LKind, ACell, LHead)];
    for LRule in GOwnKindCond[LKind] do
      if GOwnRules[LRule].Cells[ACell] and
         (LHead or not GOwnRules[LRule].Head) and
         CondHolds(GOwnRules[LRule].Cond, ANode) then
        Exit(LRule);
    Result := APrimary;
  end;

  // I5 for one node: the tokens of ANode's span that no child's span covers
  // - its OWN tokens. Without AJudge each gets ANode as its owner; with it
  // each is classified, counted and handed to AOwnProc, and for a valid
  // parse a token no rule covers, or a once / opt rule's count broken, is a
  // violation. One walk, so the owner map and the judged tokens cannot
  // disagree on which tokens are own (audit D1-50).
  procedure OwnTokens(ANode: Integer; AJudge: Boolean);
  const
    MAX_HITS = 16;
    SAYS: array[TPasOwnMult] of string = ('', 'once', 'at most once');
  var
    LHitRule, LHitCount: array[0..MAX_HITS - 1] of Integer;
    LHits, LKid, LCursor, LTok, LIdx, LRule, LCount: Integer;

    procedure One(ATok: Integer);
    var
      LCell, LAt, LRuleOf, LPrimary: Integer;
    begin
      LRuleOf := ClassifyOwn(ANode, ATok, LCell, LPrimary);
      if Assigned(AOwnProc) then
        AOwnProc(ANode, ATok, LCell, LRuleOf);
      if not AValid then
        Exit;
      if LRuleOf < 0 then
      begin
        Inc(AReport.OwnUnlisted);
        if ATok = ATree.Nodes[ANode].FirstToken then
          Report(ccOwn, ANode, ATok, '{n} owns `{c}` at its head, which no ' +
            'rule of the own-token table covers', [ANode, LCell])
        else
          Report(ccOwn, ANode, ATok, '{n} owns `{c}`, which no rule of the ' +
            'own-token table covers', [ANode, LCell]);
        Exit;
      end;
      Inc(AReport.OwnCounts[LRuleOf]);
      if AReport.OwnSites[LRuleOf] < 0 then
        AReport.OwnSites[LRuleOf] := ATok;
      // The count: the node's structure, whatever a condition made of the
      // token.
      if (LPrimary < 0) or (GOwnRules[LPrimary].Mult = omMany) then
        Exit;
      for LAt := 0 to LHits - 1 do
        if LHitRule[LAt] = LPrimary then
        begin
          Inc(LHitCount[LAt]);
          Exit;
        end;
      // A kind has far fewer once / opt rules than this.
      if LHits < MAX_HITS then
      begin
        LHitRule[LHits] := LPrimary;
        LHitCount[LHits] := 1;
        Inc(LHits);
      end;
    end;

    procedure Visit(ATok: Integer);
    begin
      if AJudge then
        One(ATok)
      else
        LOwner[ATok] := ANode;
    end;

    // Cold, as Report: its strings are this frame's, not OwnTokens'.
    procedure ReportMult(ARule, ACount: Integer);
    begin
      AReport.Add(ccOwn, ANode, Site(ANode), Format(
        '%s owns %d token(s) of `%s`; the own-token table says %s',
        [KName(ANode), ACount, GOwnRules[ARule].CellsText,
         SAYS[GOwnRules[ARule].Mult]]));
    end;

  begin
    LHits := 0;
    LCursor := LLo[ANode];
    LKid := ATree.Nodes[ANode].FirstChild;
    for LIdx := 1 to LKidCount[ANode] do
    begin
      if not LEmpty[LKid] then
      begin
        for LTok := LCursor to Min(LLo[LKid] - 1, LHi[ANode]) do
          Visit(LTok);
        if LHi[LKid] + 1 > LCursor then
          LCursor := LHi[LKid] + 1;
      end;
      LKid := ATree.Nodes[LKid].NextSibling;
    end;
    for LTok := LCursor to LHi[ANode] do
      Visit(LTok);
    if not AJudge or not AValid then
      Exit;
    for LRule in GOwnMult[Kind(ANode)] do
    begin
      if (GOwnRules[LRule].Cond <> wcNone) and
         not CondHolds(GOwnRules[LRule].Cond, ANode) then
        Continue;
      LCount := 0;
      for LIdx := 0 to LHits - 1 do
        if LHitRule[LIdx] = LRule then
          LCount := LHitCount[LIdx];
      if ((GOwnRules[LRule].Mult = omOnce) and (LCount <> 1)) or
         ((GOwnRules[LRule].Mult = omOpt) and (LCount > 1)) then
        ReportMult(LRule, LCount);
    end;
  end;

  // I6 for one node.
  procedure CheckAux(ANode: Integer);
  var
    LAux, LKids, LFirstKid, LSecondKid, LVis, LKid: Integer;
    LOpKind: TPasTokenKind;
    LAbstract, LSealed, LExtParent, LFound: Boolean;
    LMode, LWant: TPasNodeFlags;
    LParent, LPrev: Integer;
  begin
    // Read once and through LinkOk: an orphan top is checked here too, and
    // its out-of-range Parent is already reported as I1 - reading through
    // it raised ERangeError and lost that report.
    LParent := ATree.Nodes[ANode].Parent;
    if not LinkOk(LParent) then
      LParent := NIL_NODE;
    LAux := ATree.Nodes[ANode].Aux;
    if not AuxInDomain(Kind(ANode), LAux) then
      Report(ccAux, ANode, Site(ANode),
        '{n} has Aux {d}, outside its kind''s domain', [ANode, LAux]);
    if nfError in ATree.Nodes[ANode].Flags then
      Report(ccFlags, ANode, Site(ANode),
        '{n} carries nfError, which the parser never sets', [ANode]);
    if (nfNegated in ATree.Nodes[ANode].Flags) and
       not (Kind(ANode) in [nkBinaryOp, nkVisibility]) then
      Report(ccFlags, ANode, Site(ANode), '{n} carries nfNegated', [ANode]);
    if LBadTok[ANode] then
      Exit;
    // nfPacked (F3): on a type dcc lets `packed` pack, with the word right
    // before the type's span, its parent's token.
    if nfPacked in ATree.Nodes[ANode].Flags then
      if not (Kind(ANode) in [nkRecordType, nkArrayType, nkSetType,
         nkFileType, nkClassType, nkObjectType, nkClassOf]) then
        Report(ccFlags, ANode, Site(ANode), '{n} carries nfPacked', [ANode])
      else if (LLo[ANode] = 0) or (TokKind(LLo[ANode] - 1) <> tkPacked) then
        Report(ccFlags, ANode, Site(ANode),
          '{n} is marked packed, and no `packed` stands before it', [ANode])
      else if (LState[ANode] = ST_TREE) and
              (LOwner[LLo[ANode] - 1] <> ATree.Nodes[ANode].Parent) then
        Report(ccFlags, ANode, Site(ANode),
          'the `packed` before {n} is not its parent''s token', [ANode]);
    // nfAbstract / nfSealed (F4): on a class or an object type, each set
    // exactly when its word stands in the run right after the head word.
    if ([nfAbstract, nfSealed] * ATree.Nodes[ANode].Flags <> []) and
       not (Kind(ANode) in [nkClassType, nkObjectType]) then
      Report(ccFlags, ANode, Site(ANode), '{n} carries nfAbstract or nfSealed',
        [ANode])
    else if Kind(ANode) in [nkClassType, nkObjectType] then
    begin
      LAbstract := False;
      LSealed := False;
      LVis := LLo[ANode] + 1;
      while (LVis <= LHi[ANode]) and WordAt(LVis, ['abstract', 'sealed']) do
      begin
        if WordAt(LVis, ['abstract']) then
          LAbstract := True
        else
          LSealed := True;
        Inc(LVis);
      end;
      if (LAbstract <> (nfAbstract in ATree.Nodes[ANode].Flags)) or
         (LSealed <> (nfSealed in ATree.Nodes[ANode].Flags)) then
        Report(ccFlags, ANode, Site(ANode),
          '{n}: nfAbstract / nfSealed disagree with the words after its head',
          [ANode]);
    end;
    // nfVar / nfConst / nfOut (F18): a parameter's mode word stands at its
    // left edge, or right after a leading attribute group that starts there
    // (`const [Ref] X` and `[A] const X` are both dcc's). A parameter NAMED
    // `out` carries no flag - the word is its first name child.
    LMode := [nfVar, nfConst, nfOut] * ATree.Nodes[ANode].Flags;
    if (LMode <> []) and (Kind(ANode) <> nkParam) then
      Report(ccFlags, ANode, Site(ANode), '{n} carries a parameter mode',
        [ANode])
    else if Kind(ANode) = nkParam then
    begin
      LVis := LLo[ANode];
      LKid := ATree.Nodes[ANode].FirstChild;
      while (LKid <> NIL_NODE) and (Kind(LKid) = nkAttrGroup) and
            not LEmpty[LKid] and (LLo[LKid] = LVis) do
      begin
        LVis := LHi[LKid] + 1;
        LKid := ATree.Nodes[LKid].NextSibling;
      end;
      LWant := [];
      if (LVis <= LHi[ANode]) and
         not ((LKid <> NIL_NODE) and (nfName in ATree.Nodes[LKid].Flags) and
              not LEmpty[LKid] and (LLo[LKid] = LVis)) then
        // `var` and `const` are reserved words (a kind), `out` a directive
        // word (a text).
        if TokKind(LVis) = tkVar then
          LWant := [nfVar]
        else if TokKind(LVis) = tkConst then
          LWant := [nfConst]
        else if WordAt(LVis, ['out']) then
          LWant := [nfOut];
      if LMode <> LWant then
        AReport.Add(ccFlags, ANode, Site(ANode),
          'the parameter''s mode flags disagree with the word before its ' +
          'names');
    end;
    // nfThreadvar (F9): on the var section of a struct body, exactly when
    // `threadvar` stands right before its span.
    if nfThreadvar in ATree.Nodes[ANode].Flags then
      if (Kind(ANode) <> nkVarSec) or (LParent = NIL_NODE) or
         not (Kind(LParent) in [nkClassType, nkRecordType,
         nkObjectType, nkHelperType]) then
        Report(ccFlags, ANode, Site(ANode), '{n} carries nfThreadvar', [ANode])
      else if (LLo[ANode] = 0) or (TokKind(LLo[ANode] - 1) <> tkThreadvar) then
        AReport.Add(ccFlags, ANode, Site(ANode),
          'a var section is marked threadvar, and no `threadvar` stands ' +
          'before it');
    // A resourcestring section is Aux 1 (3.2.3): its head word, when it has
    // one, says so too.
    if (Kind(ANode) = nkConstSec) and (LLo[ANode] >= 0) and
       (TokKind(LLo[ANode]) = tkResourcestring) and
       (ATree.Nodes[ANode].Aux <> 1) then
      AReport.Add(ccAux, ANode, Site(ANode),
        'a resourcestring section is not marked Aux 1');
    // The clauses of an `external` directive (F13). A value carries the
    // flag of the clause word standing right before it - `name`, `index`,
    // `dependency`, or the `,` of a dependency list - and the library, right
    // after `external`, none; nfDelayed is on the directive exactly when the
    // word `delayed` stands in its clause outside every value's span.
    LExtParent := (LParent <> NIL_NODE) and not LEmpty[LParent] and
      (((Kind(LParent) = nkDirective) and WordAt(LLo[LParent], ['external'])) or
       (Kind(LParent) = nkExportsItem));
    LMode := [nfExtName, nfExtIndex, nfExtDependency] *
      ATree.Nodes[ANode].Flags;
    if not LExtParent then
    begin
      if LMode <> [] then
        Report(ccFlags, ANode, Site(ANode),
          '{n} carries an external clause flag outside an external directive',
          [ANode]);
    end
    else if not LEmpty[ANode] then
    begin
      // A word that ends the value before this one is that value's own
      // (`external index 3`: the library is the identifier `index`).
      LKid := ATree.Nodes[LParent].FirstChild;
      LPrev := NIL_NODE;
      while (LKid <> NIL_NODE) and (LKid <> ANode) do
      begin
        if not LEmpty[LKid] then
          LPrev := LKid;
        LKid := ATree.Nodes[LKid].NextSibling;
      end;
      LWant := [];
      if (LLo[ANode] > 0) and ((LPrev = NIL_NODE) or
         (LHi[LPrev] < LLo[ANode] - 1)) then
        if (TokKind(LLo[ANode] - 1) = tkComma) and
           (Kind(LParent) = nkDirective) then
          LWant := [nfExtDependency]
        else if WordAt(LLo[ANode] - 1, ['name']) then
          LWant := [nfExtName]
        else if WordAt(LLo[ANode] - 1, ['index']) then
          LWant := [nfExtIndex]
        else if (Kind(LParent) = nkDirective) and
                WordAt(LLo[ANode] - 1, ['dependency']) then
          LWant := [nfExtDependency];
      if LMode <> LWant then
        AReport.Add(ccFlags, ANode, Site(ANode),
          'the external clause flags disagree with the word before the value');
    end;
    // nfAttrTarget (19.3.2): on an attribute, exactly when a word and a `:`
    // are its first two tokens, before its first child.
    if Kind(ANode) = nkAttribute then
    begin
      LKid := ATree.Nodes[ANode].FirstChild;
      LFound := not LEmpty[ANode] and (TokKind(LLo[ANode]) = tkIdentifier) and
        (LLo[ANode] + 1 <= LHi[ANode]) and
        (TokKind(LLo[ANode] + 1) = tkColon) and
        ((LKid = NIL_NODE) or LEmpty[LKid] or (LLo[LKid] > LLo[ANode] + 1));
      if LFound <> (nfAttrTarget in ATree.Nodes[ANode].Flags) then
        AReport.Add(ccFlags, ANode, Site(ANode),
          'nfAttrTarget disagrees with a word and `:` before the attribute');
    end
    else if nfAttrTarget in ATree.Nodes[ANode].Flags then
      Report(ccFlags, ANode, Site(ANode), '{n} carries nfAttrTarget', [ANode]);
    // nfDelayed (an external directive) and nfResident (an exports item):
    // exactly when the word stands in the node's clause outside every
    // value's span.
    if (LEmpty[ANode]) or not (((Kind(ANode) = nkDirective) and
       WordAt(LLo[ANode], ['external'])) or (Kind(ANode) = nkExportsItem)) then
    begin
      if [nfDelayed, nfResident] * ATree.Nodes[ANode].Flags <> [] then
        Report(ccFlags, ANode, Site(ANode),
          '{n} carries nfDelayed or nfResident', [ANode]);
    end
    else
    begin
      LFound := False;
      LVis := LLo[ANode] + 1;
      LKid := ATree.Nodes[ANode].FirstChild;
      while LVis <= LHi[ANode] do
      begin
        while (LKid <> NIL_NODE) and (LEmpty[LKid] or (LHi[LKid] < LVis)) do
          LKid := ATree.Nodes[LKid].NextSibling;
        if (LKid <> NIL_NODE) and (LLo[LKid] <= LVis) then
          LVis := LHi[LKid] + 1
        else
        begin
          if (Kind(ANode) = nkDirective) and WordAt(LVis, ['delayed']) or
             (Kind(ANode) = nkExportsItem) and WordAt(LVis, ['resident']) then
            LFound := True;
          Inc(LVis);
        end;
      end;
      if Kind(ANode) = nkDirective then
      begin
        if LFound <> (nfDelayed in ATree.Nodes[ANode].Flags) then
          AReport.Add(ccFlags, ANode, Site(ANode),
            'nfDelayed disagrees with the word `delayed` in the external ' +
            'clause');
        if nfResident in ATree.Nodes[ANode].Flags then
          AReport.Add(ccFlags, ANode, Site(ANode),
            'a directive carries nfResident');
      end
      else
      begin
        if LFound <> (nfResident in ATree.Nodes[ANode].Flags) then
          AReport.Add(ccFlags, ANode, Site(ANode),
            'nfResident disagrees with the word `resident` in the exports ' +
            'item');
        if nfDelayed in ATree.Nodes[ANode].Flags then
          AReport.Add(ccFlags, ANode, Site(ANode),
            'an exports item carries nfDelayed');
      end;
    end;
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
            Report(ccAux, ANode, Site(ANode),
              'BinaryOp Aux {d} is not its FirstToken {d}',
              [LAux, ATree.Nodes[ANode].FirstToken])
          else if not (LOpKind in BINARY_OP_TOKENS) then
            Report(ccAux, ANode, Site(ANode),
              'BinaryOp Aux names a {c} token, no binary operator',
              [Ord(LOpKind)])
          else if LKids <> 2 then
            Report(ccAux, ANode, Site(ANode), 'BinaryOp has {d} children',
              [LKids])
          else if not (LEmpty[LFirstKid] or LEmpty[LSecondKid]) and
             ((LAux <= LHi[LFirstKid]) or (LAux >= LLo[LSecondKid])) then
            Report(ccAux, ANode, Site(ANode),
              'BinaryOp operator at {a} is not between its operands ' +
              '({a}..{a}, {a}..{a})', [LAux, LLo[LFirstKid], LHi[LFirstKid],
              LLo[LSecondKid], LHi[LSecondKid]])
          else
          begin
            if nfNegated in ATree.Nodes[ANode].Flags then
              if not (((LOpKind = tkIs) and (TokKind(LAux + 1) = tkNot)) or
                 ((LOpKind = tkIn) and (TokKind(LAux - 1) = tkNot))) then
                AReport.Add(ccFlags, ANode, Site(ANode),
                  'BinaryOp is negated but reads neither `is not` nor `not in`');
            if (LOpKind = tkGreaterEqual) and IsFusedGreaterEqual(ATree, ANode) then
              AReport.AddShape(csFusedGreaterEqual, LAux);
          end;
        end;
      nkUnaryOp:
        begin
          if LAux <> ATree.Nodes[ANode].FirstToken then
            Report(ccAux, ANode, Site(ANode),
              'UnaryOp Aux {d} is not its FirstToken {d}',
              [LAux, ATree.Nodes[ANode].FirstToken])
          else if not (TokKind(LAux) in UNARY_OP_TOKENS) then
            Report(ccAux, ANode, Site(ANode),
              'UnaryOp Aux names a {c} token, no unary operator',
              [Ord(TokKind(LAux))])
          else if LKids <> 1 then
            Report(ccAux, ANode, Site(ANode), 'UnaryOp has {d} children',
              [LKids])
          else if not LEmpty[LFirstKid] and (LAux >= LLo[LFirstKid]) then
            Report(ccAux, ANode, Site(ANode),
              'UnaryOp operator at {a} is not before its operand at {a}',
              [LAux, LLo[LFirstKid]]);
        end;
      nkVisibility:
        if (nfNegated in ATree.Nodes[ANode].Flags) and
           not (WordAt(LLo[ANode], ['strict']) and (LAux in [1, 2])) then
          AReport.Add(ccFlags, ANode, Site(ANode),
            'Visibility is marked strict but does not read `strict ' +
            'private` or `strict protected`');
      // Aux 1 marks a procedural type's first directive after its `;` (F29):
      // on no other directive, and on that one always - inside the type's
      // span a `;` right before a directive is the type's own.
      nkDirective:
        if (LParent = NIL_NODE) or (Kind(LParent) <> nkProcType) then
        begin
          if LAux = 1 then
            AReport.Add(ccAux, ANode, Site(ANode),
              'Directive has Aux 1 outside a procedural type');
        end
        else if (LAux = 1) <>
           ((ATree.Nodes[ANode].FirstToken - 1 >
             ATree.Nodes[LParent].FirstToken) and
            (TokKind(ATree.Nodes[ANode].FirstToken - 1) = tkSemicolon)) then
          if LAux = 1 then
            AReport.Add(ccAux, ANode, Site(ANode),
              'Directive of a procedural type has Aux 1 but follows no `;`')
          else
            AReport.Add(ccAux, ANode, Site(ANode),
              'Directive of a procedural type follows its `;` without Aux 1');
    end;
  end;

  // I6 for the names of a declaration (nfName, the plan's F19). The flag sits
  // only on an nkIdent child of a kind whose names it marks; the marked
  // children open the child list - attribute groups may stand before and
  // between them, a routine's generic parameters after their segment - and
  // nothing after the first other child is marked. In valid code each name
  // agrees with the token after it: the list separator (`,`, or `.` in a
  // routine's name) after every name but the last, and after the last the
  // token that opens what follows - `:` before a type or a result type, `:=`
  // or `=` before an inline initializer, `(` before the parameters, `=`
  // before a method resolution's target. An inline var's or const's Aux 1
  // stands on its initializer: the last child, after `:=` or `=`. Every
  // consumer read these separators before the flag existed, so a clean run
  // over a corpus says the flag tells them what the tokens did.
  procedure CheckNames(ANode: Integer);
  const
    NAME_KINDS = [nkVarDecl, nkParam, nkInlineVar, nkInlineConst, nkRoutine,
      nkMethodResolution];
  var
    LKid, LIdx, LNames, LSegEnd, LTail, LNext, LLastTail: Integer;
    LOpen, LRoutine, LHasInit: Boolean;
    LListSep, LAfter: TPasTokenKind;

    procedure Say(const AMsg: string);
    begin
      AReport.Add(ccFlags, ANode, Site(ANode), KName(ANode) + ' ' + AMsg);
    end;

    function TokName(AVis: Integer): string;
    begin
      if (AVis < 0) or (AVis > LLastVis) then
        Result := 'nothing'
      else
        Result := '`' + OwnTokenCellName(OwnTokenCell(ATree.Source, AVis)) +
          '`';
    end;

    // After the last name, AWant is due.
    procedure Due(AWant: TPasTokenKind; const AWhat: string);
    begin
      if LAfter <> AWant then
        Say(Format('has %s after its last name, where `%s` is due (%s)',
          [TokName(LSegEnd + 1), OwnTokenCellName(Ord(AWant)), AWhat]));
    end;

  begin
    if nfName in ATree.Nodes[ANode].Flags then
      // nkMissing: a routine's name cut short after a dot (invalid code).
      if not (Kind(ANode) in [nkIdent, nkMissing]) then
        Say('carries nfName')
      else if not LinkOk(ATree.Nodes[ANode].Parent) or
              not (Kind(ATree.Nodes[ANode].Parent) in NAME_KINDS) then
        Say('carries nfName outside a declaration whose names it marks');
    if not (Kind(ANode) in NAME_KINDS) or LBadTok[ANode] then
      Exit;
    LRoutine := Kind(ANode) in [nkRoutine, nkMethodResolution];
    if LRoutine then
      LListSep := tkDot
    else
      LListSep := tkComma;
    LNames := 0;
    LSegEnd := -1;         // the name so far ends here, a routine segment's
                           // generic parameters included
    LTail := 0;            // children after the names, but attribute groups
                           // and hints
    LNext := NIL_NODE;     // the first child after the names
    LLastTail := NIL_NODE;
    LOpen := True;
    LKid := ATree.Nodes[ANode].FirstChild;
    for LIdx := 1 to LKidCount[ANode] do
    begin
      if nfName in ATree.Nodes[LKid].Flags then
      begin
        if not LOpen then
          Say('has a name marked after what follows its names')
        else if AValid and (LNames > 0) and
                (TokKind(LSegEnd + 1) <> LListSep) then
          Say(Format('has %s between two names, where `%s` is due',
            [TokName(LSegEnd + 1), OwnTokenCellName(Ord(LListSep))]));
        Inc(LNames);
        LSegEnd := LHi[LKid];
      end
      else if LOpen and ((Kind(LKid) = nkAttrGroup) or (LRoutine and
              (LNames > 0) and (Kind(LKid) = nkGenericParams))) then
      begin
        if Kind(LKid) = nkGenericParams then
          LSegEnd := LHi[LKid];
      end
      else
      begin
        if LOpen then
          LNext := LKid;
        LOpen := False;
        if not (Kind(LKid) in [nkAttrGroup, nkDirective]) then
        begin
          Inc(LTail);
          LLastTail := LKid;
        end;
      end;
      LKid := ATree.Nodes[LKid].NextSibling;
    end;
    if not AValid then
      Exit;
    if LNames = 0 then
    begin
      Say('has no name marked');
      Exit;
    end;
    LAfter := ReadKind(LSegEnd + 1);
    if LAfter = LListSep then
      Say(Format('has %s after its last marked name: a name is not marked',
        [TokName(LSegEnd + 1)]));
    case Kind(ANode) of
      nkVarDecl:
        Due(tkColon, 'the type');
      nkParam:
        if LTail > 0 then
          Due(tkColon, 'the type')
        else if not (LAfter in [tkSemicolon, tkRParen, tkRBracket]) then
          Say(Format('is untyped, but %s follows its last name',
            [TokName(LSegEnd + 1)]));
      nkInlineVar, nkInlineConst:
        begin
          // Agreement with the tokens, not completeness: the parser takes
          // `var X, Y;` with neither a type nor an initializer as it is.
          LHasInit := ATree.Nodes[ANode].Aux = 1;
          if LHasInit and ((LLastTail = NIL_NODE) or LEmpty[LLastTail] or
             not (ReadKind(LLo[LLastTail] - 1) in [tkAssign, tkEqual])) then
            Say('has Aux 1, but its last child is no initializer')
          else if LTail - Ord(LHasInit) > 1 then
            Say(Format('has %d children after its names', [LTail]))
          else if LTail - Ord(LHasInit) = 1 then
            Due(tkColon, 'the type')
          else if LHasInit then
            Due(ReadKind(LLo[LLastTail] - 1), 'the initializer')
          else if (LAfter = tkColon) or ((LAfter in [tkAssign, tkEqual]) and
             not (LinkOk(ATree.Nodes[ANode].Parent) and
             (Kind(ATree.Nodes[ANode].Parent) = nkForStmt))) then
            // Neither a type nor an initializer, where the token after the
            // names opens one - but a for loop's own `:=` after its counter.
            Say(Format('has neither a type nor an initializer, but %s ' +
              'follows its names', [TokName(LSegEnd + 1)]));
        end;
      nkMethodResolution:
        Due(tkEqual, 'the implementing method');
      nkRoutine:
        if (LNext <> NIL_NODE) and (Kind(LNext) = nkParams) then
          Due(tkLParen, 'the parameters')
        else if (LNext <> NIL_NODE) and
                not (Kind(LNext) in [nkDirective, nkRoutineBody]) then
          Due(tkColon, 'the result type')
        else if LAfter in [tkColon, tkLParen, tkLess] then
          Say(Format('has %s after its name, but nothing it would open',
            [TokName(LSegEnd + 1)]));
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
  SetLength(LIsTop, LCount);
  SetLength(LLo, LCount);
  SetLength(LHi, LCount);
  SetLength(LOrder, LCount);
  SetLength(LStack, LCount);
  SetLength(LKidCount, LCount);
  SetLength(LOwner, LLastVis + 1);
  for LPos := 0 to LLastVis do
    LOwner[LPos] := NIL_NODE;
  LAfterEnd := -1;
  LFusedGE := PasFusedGreaterEquals(ATree);

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
  // from its own top.
  LOrderCount := 0;
  if ATree.Nodes[0].Parent <> NIL_NODE then
    AReport.Add(ccLink, 0, Site(0), 'the root has a Parent');
  Walk(0, ST_TREE);
  LOrphanStart := LOrderCount;
  WalkOrphans;

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
      begin
        AReport.AddShape(csAfterEnd, LHi[0]);
        LAfterEnd := LHi[0];
      end
      else
        AReport.Add(ccRoot, 0, LHi[0], Format(
          'the root ends at token %d of %d', [LHi[0], LLastVis]));
  end;

  // I5: the owners, which the orphan shapes below read (ReReadCovers).
  for LPos := 0 to LOrphanStart - 1 do
    if not LEmpty[LOrder[LPos]] then
      OwnTokens(LOrder[LPos], False);

  // I3: what the unreachable subtrees are.
  LPos := LOrphanStart;
  while LPos < LOrderCount do
  begin
    LNode := LOrder[LPos];
    // The subtree's nodes follow its top in LOrder, up to the next top.
    LSize := 1;
    while (LPos + LSize < LOrderCount) and not LIsTop[LOrder[LPos + LSize]] do
      Inc(LSize);
    ClassifyOrphan(LNode, LSize);
    Inc(LPos, LSize);
  end;

  // I5, judged: every own token against the own-token table. Nothing here
  // reads the orphans' shapes or the owner map; it runs after them so the
  // report keeps its order (orphan violations first), which decides what
  // AMaxKept keeps.
  if AValid and (GOwnErrors <> '') then
    AReport.Add(ccOwn, NIL_NODE, -1, 'the own-token table is invalid: ' +
      GOwnErrors.Split([sLineBreak])[0]);
  if AValid or Assigned(AOwnProc) then
    for LPos := 0 to LOrphanStart - 1 do
      if not LEmpty[LOrder[LPos]] then
        OwnTokens(LOrder[LPos], True);

  // I6 and I8 over every walked node.
  for LPos := 0 to LOrderCount - 1 do
  begin
    LNode := LOrder[LPos];
    CheckAux(LNode);
    CheckNames(LNode);
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
  LIdx, LSec, LChild, LPrev, LImpl, LImplUses: Integer;
  LA, LB: TPasNode;
begin
  LSec := NIL_NODE;
  // An interface-and-implementation-uses parse (pmInterfaceAndImplUses)
  // holds the implementation section's node and its `uses` clause: the
  // section's extent, children and successor, and the clause's successor,
  // are what the full parse adds after them.
  LImpl := NIL_NODE;
  LImplUses := NIL_NODE;
  if ALenient and (Length(A.Nodes) > 0) then
  begin
    LPrev := 0;
    LChild := A.Nodes[0].FirstChild;
    while (LChild > LPrev) and (LChild <= High(A.Nodes)) do
    begin
      LPrev := LChild;
      if A.Nodes[LChild].Kind = nkImplementationSec then
      begin
        LImpl := LChild;
        LImplUses := A.Nodes[LChild].FirstChild;
        if (LImplUses <> NIL_NODE) and ((LImplUses > High(A.Nodes)) or
           (A.Nodes[LImplUses].Kind <> nkUsesClause)) then
          LImplUses := NIL_NODE;
        Break;
      end;
      LChild := A.Nodes[LChild].NextSibling;
    end;
  end;
  if ALenient and (Length(B.Nodes) > 0) then
  begin
    // Children are created after their parent and in order, so each index
    // must exceed the last: a stale link that loops back ends the walk
    // instead of spinning after CheckTree has already reported the cycle.
    LPrev := 0;
    LChild := B.Nodes[0].FirstChild;
    while (LChild > LPrev) and (LChild <= High(B.Nodes)) do
    begin
      LPrev := LChild;
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
    if LIdx = LImpl then
    begin
      LA.LastToken := LB.LastToken;
      if LA.NextSibling = NIL_NODE then
        LA.NextSibling := LB.NextSibling;
      if LA.FirstChild = NIL_NODE then
        LA.FirstChild := LB.FirstChild;
    end;
    if (LIdx = LImplUses) and (LA.NextSibling = NIL_NODE) then
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

initialization
  BuildCellWords;
  BuildOwnTable;

end.
