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
    wcAmbiguous,    // a node whose name list's end the children cannot tell
                    // (plan finding F19): a var or a parameter declaration,
                    // an inline var, a routine header - see NamesAmbiguous
    wcNoArgs,       // an attribute with no argument child
    wcAfterEnd,     // the token after the final `end.` (csAfterEnd)
    wcOrphanInit    // a token of the initializer a trailing directive drops
                    // (csDirectiveInit)
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
    'I4.root', 'I5.own', 'I6.aux', 'I6.flags', 'I7.differ', 'I7.prefix',
    'I8.error', 'I8.missing');
  CHECK_SHAPE_NAMES: array[TPasCheckShape] of string = (
    'orphan: context keyword', 'orphan: type reference re-read',
    'orphan: initializer after a trailing directive', 'trailing comma',
    'text after end.', 'fused >= as type-argument close and =');

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
           rule; default: any number), when:<condition> (ambiguous, noargs,
           afterend, orphaninit - see TPasOwnCond). A rule with a condition
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
    working paper): F1 the dropped initializer, F2 calling conventions of
    procedural types, F3 packed, F4 class abstract/sealed, F9 class
    threadvar, F10 directives before a routine header's `;`, F11 before an
    anonymous method's body, F12 a routine's deprecated message, F13 the
    external clause, F14 the exports clause, F15 the GUID literal, F16
    numeric labels, F17 program parameters, F18 parameter modes, F19 where a
    name list ends. }
  OWN_RULE_TEXT: array[0..246] of string = (
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
    'AnonMethod | @routine | - | loss:F11 | a calling convention before the ' +
      'body, `function(...): T stdcall begin`, is skipped',
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
    'GotoStmt | <int> | opt | loss:F16 | a numeric label has no node',
    'LabeledStmt | : | once | derived | the kind',
    'LabeledStmt | <int> | head opt | loss:F16 | a numeric label has no node',
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
    'InlineVar | , : := | when:ambiguous | loss:F19 | where the names end ' +
      'and whether a type or a value follows: `var X: K` and `var X := K`, ' +
      '`var X, Y: K` and `var X: Y := K` build the same children',
    'InlineVar | , | - | derived | between the names',
    'InlineVar | : | opt | derived | before the type',
    'InlineVar | := | opt | derived | before the initializer',
    'InlineConst | const | head once | derived | the kind',
    'InlineConst | : | opt | derived | three children: the type',
    'InlineConst | = | once | derived | the kind',

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
    'Program Library | ( ) , <ident> | - | loss:F17 | program parameters, ' +
      '`program X(Input, Output);`, are skipped (coverage.md 1.1.1)',
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
    'InitSec | initialization | head opt | derived | the kind',
    'InitSec | begin | head opt | insig | a unit''s `begin ... end.` opens ' +
      'the same section (normalization list)',
    'InitSec | ; | - | derived | between the statements',
    'FinalSec | finalization | head once | derived | the kind',
    'FinalSec | ; | - | derived | between the statements',
    'ExportsClause | exports | head once | derived | the kind',
    'ExportsClause | , | - | derived | between the items',
    'ExportsClause | ; | once | derived | the kind',
    'ExportsItem | name index | - | loss:F14 | the children do not say which ' +
      'expression is the name and which the index',
    'ExportsItem | resident | opt | loss:F14 | skipped',

    // ---- declaration sections ----
    'TypeSec | type | head once | derived | the kind',
    'TypeSec | ; | - | derived | after each declaration',
    'TypeSec | @routine | - | loss:F2 | a calling convention after the ; of ' +
      'a procedural type, `TFn = function: T; stdcall;`, is skipped',
    'ConstSec | const resourcestring | head once | contract | the head word',
    'ConstSec | ; | - | derived | after each declaration',
    'VarSec | var threadvar | head opt | contract | the head word; a class ' +
      'var run and a section in a struct body have none (F9)',
    'VarSec | ; | - | derived | after each declaration',
    'VarSec | @routine | - | loss:F2 | a calling convention after the ; of a ' +
      'procedural variable, `P: procedure; stdcall;`, is skipped',
    'VarSec | = | - | loss:F1 | the = of an initializer after such a ' +
      'convention, `P: procedure; cdecl = nil;`',
    '* | @any | when:orphaninit | loss:F1 | a token of that initializer: ' +
      'parsed and never adopted',
    'LabelSec | label | head once | derived | the kind',
    'LabelSec | , | - | derived | between the labels',
    'LabelSec | ; | once | derived | the kind',
    'LabelSec | <int> | - | loss:F16 | a numeric label has no node',
    'TypeDecl | = | opt | derived | the kind; a fused >= stands for it after ' +
      'generic parameters',
    'TypeDecl | >= | opt | insig | a fused >=: the > closing the generic ' +
      'parameters and the = (normalization list)',
    'TypeDecl | type | opt | derived | Aux 1: a distinct alias, `= type X`',
    'TypeDecl | reference | opt | derived | the ProcType child''s Aux 2; ' +
      'outside its span',
    'TypeDecl | to | opt | derived | the ProcType child''s Aux 2; outside ' +
      'its span',
    'TypeDecl VarDecl ConstDecl ArrayType | packed | opt | loss:F3 | ' +
      '`packed` is skipped (coverage.md 9.1.2)',
    'ConstDecl | : | opt | derived | two children after the name: the type ' +
      'and the value',
    'ConstDecl | = | once | derived | the kind',
    'ConstDecl | ; @routine | - | loss:F2 | the typed-constant twin, ' +
      '`C: procedure; cdecl = nil;`, skips `; cdecl`',
    'VarDecl | , : = | when:ambiguous | loss:F19 | whether the last child ' +
      'is an initializer: `P, T: C` and `P: T = C` build the same children',
    'VarDecl | , | - | derived | between the names',
    'VarDecl | : | once | derived | the kind',
    'VarDecl | = | opt | derived | before the initializer',
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
    'ProcType | @routine | - | loss:F2 | a calling convention written into ' +
      'the type, `procedure stdcall`, is skipped',
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
    'ClassType | abstract sealed | - | loss:F4 | `class abstract` and ' +
      '`class sealed` are skipped',
    'ClassType RecordType ObjectType | @routine | - | loss:F2 | a calling ' +
      'convention after the ; of a procedural field is skipped',
    'ClassType RecordType HelperType | var | - | derived | the head of a ' +
      'VarSec child, outside its span: var (Aux nil) or class var (Aux 1) ' +
      '(F9)',
    'ClassType RecordType | threadvar | - | loss:F9 | `class threadvar` ' +
      'reads as `class var`',
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
    'Guid | <str> | opt | loss:F15 | a GUID written as a literal has no ' +
      'leaf; a named constant has an nkIdent',

    // ---- members and routines ----
    'Visibility | private protected public published automated | once | ' +
      'derived | Aux 1..5',
    'Visibility | strict | head opt | derived | nfNegated: strict private, ' +
      'strict protected',
    'Routine | procedure function constructor destructor operator | head ' +
      'once | contract | the head word; a `class` before it is the ' +
      'parent''s token (Aux 1)',
    'Routine | . : | when:ambiguous | loss:F19 | a function with no ' +
      'parameter list where methods are implemented: a result type named by ' +
      'a plain identifier reads as one more name segment, `function A.B;` ' +
      'and `function A: B;` build the same children',
    'Routine | . | - | derived | between the name segments',
    'Routine | : | opt | derived | before the result type',
    'Routine | ; | - | derived | after the header, each directive and the ' +
      'body; the last directive''s may be missing (normalization list)',
    'Routine | @routine | - | loss:F10 | a directive before the header''s ;, ' +
      '`function F: Bool stdcall;`, is skipped',
    'Params | ( [ | head once | derived | [ for the index parameters of a ' +
      'property',
    'Params | ) ] | once | derived | closes the list',
    'Params | ; | - | derived | between the parameters',
    'Param | , : = | when:ambiguous | loss:F19 | where the names end: a var, ' +
      'const or out parameter may be untyped, `(const A, B)` and `(const A: ' +
      'B)`, and `(A, T: X)` and `(A: T = X)` build the same children',
    'Param | , | - | derived | between the names',
    'Param | : | opt | derived | before the type',
    'Param | = | opt | derived | before the default value',
    'Param | const var | opt | loss:F18 | the mode has no mark; only out has ' +
      'one, in Aux (coverage.md 6.2)',
    'Param | out | opt | derived | Aux names it',
    'Directive | @routine | head once | contract | the directive word',
    'Directive | name index dependency delayed , | - | loss:F13 | inside ' +
      'external: nothing says which child is the library, the name or the ' +
      'index; delayed is skipped',
    'Directive | <str> | opt | loss:F12 | the message of a routine''s ' +
      '`deprecated ''msg''` has no node (a declaration hint''s has an ' +
      'nkStrLit)',
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
    'Attribute | , | - | derived | between the arguments'
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
        else if LField = 'when:ambiguous' then
          LRule.Cond := wcAmbiguous
        else if LField = 'when:noargs' then
          LRule.Cond := wcNoArgs
        else if LField = 'when:afterend' then
          LRule.Cond := wcAfterEnd
        else if LField = 'when:orphaninit' then
          LRule.Cond := wcOrphanInit
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
      else if LRule.AllKinds <> (LRule.Cond in [wcAfterEnd, wcOrphanInit]) then
        Fail('`*` goes with when:afterend or when:orphaninit, and they with it')
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
  // I5: the tokens of csDirectiveInit orphans (nil while there is none), and
  // the token after the final `end.` (-1: no csAfterEnd).
  LInOrphanInit: TArray<Boolean>;
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

  // I5: the tokens of ANode's span that no child's span covers - its OWN
  // tokens - get ANode as their owner. JudgeOwn walks them the same way.
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
          LOwner[LTok] := ANode;
        if LHi[LKid] + 1 > LCursor then
          LCursor := LHi[LKid] + 1;
      end;
      LKid := ATree.Nodes[LKid].NextSibling;
    end;
    for LTok := LCursor to LHi[ANode] do
      LOwner[LTok] := ANode;
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
    LTok: Integer;
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
    // I5: the dropped initializer's tokens are owned by whatever reachable
    // node spans them; its own rule classifies them (wcOrphanInit).
    if LOrphan.Known and (LOrphan.Shape = csDirectiveInit) then
    begin
      if LInOrphanInit = nil then
        SetLength(LInOrphanInit, LLastVis + 1);
      for LTok := LLo[ARoot] to LHi[ARoot] do
        LInOrphanInit[LTok] := True;
    end;
    if AReport.OrphanCount = Length(AReport.Orphans) then
      SetLength(AReport.Orphans, AReport.OrphanCount * 2 + 8);
    AReport.Orphans[AReport.OrphanCount] := LOrphan;
    Inc(AReport.OrphanCount);
  end;

  // F19: can ANode's children alone not tell where its names end? Count the
  // readings that fit the same children - K the children but the attribute
  // groups and hints, R the leading run of nkIdent in K, T the children
  // after it (a type or a value, never a name). An initializer or a default
  // allows a single name (dcc: E2196, E2237); only a var, const or out
  // parameter may be untyped; the first child after the run, C, can be a
  // type as well as a value when it is a qualified name or a generic
  // instantiation. Two readings or more:
  // - var: T = 0 and R = 3, `P, T: C` / `P: T = C`; T = 1, R = 2 and C dual;
  // - parameter: T = 0 and R = 3, `(A, T: X)` / `(A: T = X)`; T = 0, R >= 2
  //   and a mode, `(const A, B)` / `(const A: B)`; T = 1, R = 2, C dual;
  // - inline var: T = 0 and R = 2, `var X: K` / `var X := K`; T = 0 and
  //   R = 3, `var X, Y: K` / `var X: Y := K`; T = 1, R <= 2 and C dual;
  // - routine: a `function` (its head word, a contract read: no other
  //   routine has a result) with no parameter list where a method may be
  //   implemented - an implementation section, a program or a library - the
  //   leading run of name segments ending on a plain identifier and holding
  //   two, and no type after it - `function A.B;` / `function A: B;`.
  function NamesAmbiguous(ANode: Integer): Boolean;
  const
    METHOD_HOMES = [nkImplementationSec, nkProgram, nkLibrary];
    DUAL_KINDS = [nkMember, nkTypeArgs];
  var
    LKid, LIdx, LTok, LRun, LAfter, LIdents: Integer;
    LFirstAfter: TPasNodeKind;
    LInRun, LLastIdent: Boolean;

    // A var, const or out mode: out is marked (Aux); var and const are the
    // first token after the leading attribute groups.
    function HasMode: Boolean;
    var
      LAt, LNum: Integer;
    begin
      if ATree.Nodes[ANode].Aux >= 0 then
        Exit(True);
      LTok := LLo[ANode];
      LAt := ATree.Nodes[ANode].FirstChild;
      for LNum := 1 to LKidCount[ANode] do
      begin
        if (Kind(LAt) <> nkAttrGroup) or LEmpty[LAt] or (LLo[LAt] <> LTok) then
          Break;
        LTok := LHi[LAt] + 1;
        LAt := ATree.Nodes[LAt].NextSibling;
      end;
      Result := TokKind(LTok) in [tkVar, tkConst];
    end;

  begin
    Result := False;
    LRun := 0;
    LAfter := 0;
    LIdents := 0;
    LInRun := True;
    LLastIdent := False;
    LFirstAfter := nkError;
    LKid := ATree.Nodes[ANode].FirstChild;
    if Kind(ANode) = nkRoutine then
    begin
      if (TokKind(ATree.Nodes[ANode].FirstToken) <> tkFunction) or
         not LinkOk(ATree.Nodes[ANode].Parent) or
         not (Kind(ATree.Nodes[ANode].Parent) in METHOD_HOMES) then
        Exit;
      for LIdx := 1 to LKidCount[ANode] do
      begin
        case Kind(LKid) of
          nkParams:
            Exit;
          nkIdent, nkGenericParams:
            if LInRun then
            begin
              LLastIdent := Kind(LKid) = nkIdent;
              if LLastIdent then
                Inc(LIdents);
            end;
        else
          if LInRun then
          begin
            LInRun := False;
            LFirstAfter := Kind(LKid);
          end;
        end;
        LKid := ATree.Nodes[LKid].NextSibling;
      end;
      Exit(LLastIdent and (LIdents >= 2) and
        (LInRun or (LFirstAfter in [nkDirective, nkRoutineBody])));
    end;
    for LIdx := 1 to LKidCount[ANode] do
    begin
      if not (Kind(LKid) in [nkAttrGroup, nkDirective]) then
        if LInRun and (Kind(LKid) = nkIdent) then
          Inc(LRun)
        else
        begin
          if LInRun then
            LFirstAfter := Kind(LKid);
          LInRun := False;
          Inc(LAfter);
        end;
      LKid := ATree.Nodes[LKid].NextSibling;
    end;
    case Kind(ANode) of
      nkVarDecl:
        // absolute (Aux 1): the last child is the alias, the one before it
        // the type.
        Result := (ATree.Nodes[ANode].Aux <> 1) and
          (((LAfter = 0) and (LRun = 3)) or
           ((LAfter = 1) and (LRun = 2) and (LFirstAfter in DUAL_KINDS)));
      nkParam:
        Result := ((LAfter = 0) and ((LRun = 3) or ((LRun >= 2) and HasMode)))
          or ((LAfter = 1) and (LRun = 2) and (LFirstAfter in DUAL_KINDS));
      nkInlineVar:
        Result := ((LAfter = 0) and (LRun in [2, 3])) or
          ((LAfter = 1) and (LRun <= 2) and (LFirstAfter in DUAL_KINDS));
    end;
  end;

  // I5: does a rule's node-level condition hold for ANode?
  function CondHolds(ACond: TPasOwnCond; ANode: Integer): Boolean;
  begin
    case ACond of
      wcAmbiguous:
        Result := NamesAmbiguous(ANode);
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
    APrimary := -1;
    if (ATok = LAfterEnd) and (ANode = 0) and
       (GOwnGlobal[wcAfterEnd] >= 0) then
      Exit(GOwnGlobal[wcAfterEnd]);
    if (LInOrphanInit <> nil) and LInOrphanInit[ATok] and
       (GOwnGlobal[wcOrphanInit] >= 0) then
      Exit(GOwnGlobal[wcOrphanInit]);
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

  // I5 for one node: every own token classified, counted and handed to
  // AOwnProc; for a valid parse a token no rule covers, or a once / opt
  // rule's count broken, is a violation.
  procedure JudgeOwn(ANode: Integer);
  const
    MAX_HITS = 16;
    SAYS: array[TPasOwnMult] of string = ('', 'once', 'at most once');
    HEAD_TEXT: array[Boolean] of string = ('', ' at its head');
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
        AReport.Add(ccOwn, ANode, ATok, Format(
          '%s owns `%s`%s, which no rule of the own-token table covers',
          [KName(ANode), OwnTokenCellName(LCell),
           HEAD_TEXT[ATok = ATree.Nodes[ANode].FirstToken]]));
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

  begin
    LHits := 0;
    LCursor := LLo[ANode];
    LKid := ATree.Nodes[ANode].FirstChild;
    for LIdx := 1 to LKidCount[ANode] do
    begin
      if not LEmpty[LKid] then
      begin
        for LTok := LCursor to Min(LLo[LKid] - 1, LHi[ANode]) do
          One(LTok);
        if LHi[LKid] + 1 > LCursor then
          LCursor := LHi[LKid] + 1;
      end;
      LKid := ATree.Nodes[LKid].NextSibling;
    end;
    for LTok := LCursor to LHi[ANode] do
      One(LTok);
    if not AValid then
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
        AReport.Add(ccOwn, ANode, Site(ANode), Format(
          '%s owns %d token(s) of `%s`; the own-token table says %s',
          [KName(ANode), LCount, GOwnRules[LRule].CellsText,
           SAYS[GOwnRules[LRule].Mult]]));
    end;
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
  LInOrphanInit := nil;
  LAfterEnd := -1;

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
      begin
        AReport.AddShape(csAfterEnd, LHi[0]);
        LAfterEnd := LHi[0];
      end
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

  // I5, judged: every own token against the own-token table - after the
  // orphans, whose shapes two of its rules read.
  if AValid and (GOwnErrors <> '') then
    AReport.Add(ccOwn, NIL_NODE, -1, 'the own-token table is invalid: ' +
      GOwnErrors.Split([sLineBreak])[0]);
  if AValid or Assigned(AOwnProc) then
    for LPos := 0 to LOrphanStart - 1 do
      if not LEmpty[LOrder[LPos]] then
        JudgeOwn(LOrder[LPos]);

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

initialization
  BuildOwnTable;

end.
