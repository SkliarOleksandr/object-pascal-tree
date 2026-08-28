unit PasTree.Ast;

{
  PasTree - the homogeneous AST.

  Design (see README):
  - One node type. A node is a 32-byte record in a contiguous per-unit
    array; all references are integer indices (NIL_NODE = -1).
  - Nodes carry no text: FirstToken/LastToken index the preprocessor's
    VISIBLE stream, and the underlying token slices provide all names and
    values (full fidelity lives in the token layer).
  - Aux is a kind-specific payload: for nkBinaryOp/nkUnaryOp it is the
    visible index of the operator token; for others see the kind comments.
  - Kinds reference the spec (object-pascal-spec) feature numbers.
    TODO: generate this enum from the spec's AST blocks (tools/kindsgen).
}

interface

uses
  PasTree.Types,
  PasTree.Preprocessor;

const
  NIL_NODE = -1;

  // nkAttribute.Aux (19.3.3): a handful of attribute names are COMPILER-
  // RECOGNIZED -- a real compiler matches them by the identity of the
  // resolved TCustomAttribute descendant, but the spec explicitly allows a
  // lightweight parser to match by NAME instead, which is what
  // PasAttrMagicAux (below) does. Their real semantics live elsewhere
  // (6.2.3 [Ref] on a const param, 14.3.2/20.6.1 [weak]/[unsafe]); this Aux
  // value only records WHICH one was written, nothing more.
  amaNone = -1;      // an ordinary, non-magic attribute (the default)
  amaRef = 1;
  amaVolatile = 2;
  amaWeak = 3;
  amaUnsafe = 4;

type
  TPasNodeKind = (
    nkError,          // parse error recovery node
    nkMissing,        // expected element that was absent

    // ---- expressions (spec ch.04, B.9) ----
    nkIdent,          // identifier reference (incl. keyword-as-type: string)
    nkIntLit, nkRealLit, nkStrLit, nkNilLit,
    nkCaretChar,      // ^M caret control-char literal (B.6.2)
    nkUnaryOp,        // Aux = operator visible-token index (not/@/+/-)
    nkBinaryOp,       // Aux = operator visible-token index; is not/not in
                      // are flagged via nfNegated on the node
    nkParen,          // ( expr ) - kept for fidelity
    nkCall,           // callee = child 0, args follow (4.10 cast-vs-call is
                      // resolved semantically)
    nkFormattedArg,   // Write/Str colon-arg: expr [:width [:prec]] (4.11.2)
    nkIndex,          // base = child 0, indices follow
    nkMember,         // base = child 0, name = child 1 (nkIdent)
    nkDeref,          // base = child 0 (postfix ^)
    nkTypeArgs,       // generic argument list on a designator segment (16.3)
    nkSetCtor,        // [ ... ] set/array constructor (B.9)
    nkRange,          // a..b (case labels, set elements)
    nkInlineIf,       // if c then a else b expression (5.4.1)
    nkInherited,      // inherited [name] (12.1.2)
    nkAnonMethod,     // anonymous method literal (17.2.1); minimal v1
    nkAnonParams,     // RETIRED (anon methods emit real nkParams now); kept
                      // so existing kind ordinals stay stable

    // ---- statements (spec ch.05, ch.18) ----
    nkBlock,          // begin..end / statement list container
    nkEmptyStmt,
    nkAssign,         // 5.1.1: target = child 0, value = child 1
    nkExprStmt,       // 5.1.2: call/designator in statement position
    nkIfStmt,         // 5.3.1: cond, then, [else]
    nkCaseStmt,       // 5.3.2: selector, selectors..., [else block]
    nkCaseSel,        // labels (nkCaseLabels) + body
    nkCaseLabels,     // list of exprs/ranges
    nkForStmt,        // 5.5.1: [inline var] counter, from, to, body;
                      // Aux = 1 when downto
    nkForInStmt,      // 5.5.2: [inline var] element, collection, body
    nkWhileStmt,      // 5.5.3
    nkRepeatStmt,     // 5.5.4: body block, cond
    nkWithStmt,       // 5.7: targets..., body (last child)
    nkGotoStmt,       // 5.6.4
    nkLabeledStmt,    // label ident + statement
    nkTryStmt,        // 18.1/18.2: block + (nkExceptPart | nkFinallyPart)
    nkExceptPart,     // handlers (nkExceptOn...) or bare block; [else block]
    nkExceptOn,       // 18.1.2: [name], type, body
    nkFinallyPart,
    nkRaiseStmt,      // 18.3.1: [expr [at-expr]]
    nkAsmStmt,        // 6.10: opaque BASM token range
    nkInlineVar,      // 3.1.3: name, [type], [init]
    nkInlineConst,    // 3.1.3 const form

    // ---- compilation units (spec ch.01) ----
    nkUnit,           // 1.1.2: name, [uses], interface, implementation, ...
    nkProgram,        // 1.1.1
    nkLibrary,        // 1.1.3
    nkPackage,        // 1.1.3: requires/contains
    nkUsesClause,     // 1.2.1: items
    nkUsesItem,       //   name [+ 'in' path string]
    nkInterfaceSec,
    nkImplementationSec,
    nkInitSec, nkFinalSec,
    nkExportsClause,  // 1.1.3: items
    nkExportsItem,

    // ---- declaration sections (spec ch.02/03/06) ----
    nkTypeSec, nkConstSec, nkVarSec, nkLabelSec,
    nkTypeDecl,       // name [generic params] = [type-mark] TypeExpr;
                      // Aux = 1 for distinct alias (= type X, 2.5.1)
    nkConstDecl,      // name [: type] = init [hints]
    nkVarDecl,        // names... : type [absolute X | = init]; also fields
    nkAggregate,      // typed-const initializer ( ... ) (3.2.2)
    nkAggregateField, //   name: value element

    // ---- type expressions (spec ch.02/08/09/10/B.11) ----
    nkSubrange,       // lo..hi (2.2.5)
    nkEnumType,       // ( a, b = 1, ... ) (2.2.4)
    nkEnumValue,      //   name [= const]
    nkArrayType,      // array [dims] of T; Aux = 1 for array of const (8.x)
    nkSetType,        // set of T (2.4.1)
    nkFileType,       // file [of T] (10.2.1)
    nkPointerType,    // ^T (10.1.1)
    nkStringType,     // string[N] (7.1.3)
    nkClassOf,        // class of T (15.2.1)
    nkProcType,       // procedure/function type (6.6.1);
                      // Aux: 1 = of object, 2 = reference to
    nkClassType,      // 11.1.1; Aux: 1 = forward declaration
    nkRecordType,     // 9.x
    nkInterfaceType,  // 14.1.1; dispinterface flagged via Aux = 1
    nkObjectType,     // 11.5 legacy
    nkHelperType,     // 15.3: class/record helper for T; Aux 1 = record
    nkGuid,           // 14.1.1: ['{...}']

    // ---- members & routines (spec ch.06/11/13) ----
    nkVisibility,     // 11.2.1: Aux encodes level; strict via flag
    nkRoutine,        // procedure/function/constructor/destructor/operator;
                      // children: name, [generic params], [params], [result
                      // type], directives..., [body]
    nkParams,
    // 6.2. Aux = the visible-token index of an `out` modifier, -1 otherwise.
    // `var` and `const` need no such mark: they are reserved words and a lexer
    // already knows them, while `out` is a context-sensitive directive word
    // (B.4.2) - legal as an identifier elsewhere - so the only thing that can
    // prove this one MEANS the modifier is the parser, here.
    nkParam,
    nkDirective,      // routine directive (+ optional args as children)
    nkPropertyDecl,   // 13.1.1: name, [index params], [type], specifiers
    nkPropSpec,       // read/write/index/stored/default/implements + expr
    nkMethodResolution, // 14.2.2: IFace.Method = ImplName
    nkVariantPart,    // 9.1.3: [tag] type + branches
    nkVariantBranch,  //   labels : ( fields )
    nkGenericParams,  // 16.1: <T; U: constraints>
    nkGenericParam,
    nkConstraint,     // class/record/constructor/typeref
    nkAttrGroup,      // 19.3.2: [Attr(args), ...]
    nkAttribute,      // 19.3.2; Aux (19.3.3) = amaNone/amaRef/amaVolatile/
                      // amaWeak/amaUnsafe, set by the parser -- see the
                      // ama* constants above

    nkRoutineBody,    // local decl sections + compound/asm block
    // Appended, not inserted: existing ordinals stay stable (see nkAnonParams).
    nkNamedArg        // OLE-automation named argument `Name := Expr` in a call
                      // argument list (4.10.1): name = child 0, value = child 1.
                      // The NAME is a dispatch parameter name, NOT a reference -
                      // nothing resolves it.
  );

  TPasNodeFlag = (
    nfError,      // subtree contains a parse error
    nfNegated     // is not / not in (4.9.1)
  );
  TPasNodeFlags = set of TPasNodeFlag;

  TPasNode = record
    Kind: TPasNodeKind;
    Flags: TPasNodeFlags;
    FirstToken: Integer;   // visible-stream index of first token
    LastToken: Integer;    // visible-stream index of last token (inclusive)
    Parent: Integer;
    FirstChild: Integer;
    NextSibling: Integer;
    Aux: Integer;          // kind-specific (see kind comments)
  end;

  { A parsed compilation: the preprocessed token layer plus the node arena.
    Root node is index 0. Immutable once built. }
  TPasTree = record
  public
    Source: TPasPreprocessed;
    Nodes: TArray<TPasNode>;
    function KindName(AKind: TPasNodeKind): string;
    function NodeText(AIndex: Integer): string;    // first-token slice
    { The node's FULL token-span slice: raw source text from its leftmost
      visible token through LastToken, full fidelity (interior comments and
      whitespace included - collapse is a display concern, the caller's).
      Leftmost DESCENDANT, not FirstToken: nodes whose FirstToken is not
      their left edge exist by design (nkMember's is the dot). '' when the
      span crosses files (a declaration split over an $I include - not worth
      reconstructing) or is degenerate. Promoted here because three private
      copies of this walk existed (navigator, LSP, demo) - see the
      completion plan sec. 8A. }
    function NodeSpanText(AIndex: Integer): string;
    { The node's TRUE leftmost visible token: the smaller of its own
      FirstToken and its deepest-first-descendant's - nodes whose FirstToken
      is not their left edge exist by design (nkMember's is the dot). -1 for
      a bad index or a node with no tokens. }
    function NodeLeftmostVis(AIndex: Integer): Integer;
    { The LEADING doc-comment block of the declaration ANode belongs to
      (completion plan sec. 8D, Help Insight): the contiguous run of `///` line
      comments immediately above the declaration, in source order, with the
      `///` markers stripped, lines joined with #10; '' when there is none.

      ANode may be the declaration's NAME node (a symbol's DeclNode) - it is
      climbed to the enclosing declaration root first (routine, type/const/
      var/property declaration, enum value), because the doc sits above the
      whole declaration, not above the name mid-line. The walk then runs
      BACKWARD over the RAW token stream of the declaration's own file:
      whitespace is crossed (a BLANK line ends the run - attachment requires
      adjacency, the native IDE's rule), an attribute group between the doc
      block and the declaration is stepped over (docs conventionally sit
      above the attributes), and any other token - code, an ordinary `//`
      comment, a brace comment, a directive - ends the run.

      Raw text is the contract: XML-tag rendering (`<summary>`, `<param>`)
      is a HOST display concern, exactly like whitespace collapse in
      ItemParamsText. No XML parsing here. }
    function DeclDocComment(AIndex: Integer): string;
    { The same slice as a NAME KEY: lower-cased, leading '&' stripped. Use this
      for every declaration and lookup key - see the implementation. }
    function NodeNameLower(AIndex: Integer): string;
    { Non-allocating SameText(NodeText(AIndex), AWord) - the word-test
      counterpart of SliceEqualsWord for a node's first token. }
    function NodeTextEquals(AIndex: Integer; const AWord: string): Boolean;
    { Compact S-expression dump for golden tests:
      Kind or Kind'text' or Kind(children...). }
    function Dump(AIndex: Integer): string;
  end;

  { Arena builder used by the parser. }
  TPasTreeBuilder = record
  private
    FNodes: TArray<TPasNode>;
    FCount: Integer;
    FLastChild: TArray<Integer>;  // parallel: last child per node
    procedure Grow;
  public
    procedure Init(ACapacityHint: Integer = 64);
    function AddNode(AKind: TPasNodeKind; AParent, AFirstToken: Integer):
      Integer;
    procedure SetLast(ANode, ALastToken: Integer);
    procedure SetAux(ANode, AAux: Integer);
    procedure SetKind(ANode: Integer; AKind: TPasNodeKind);
    procedure AddFlag(ANode: Integer; AFlag: TPasNodeFlag);
    { Re-parents ANode under ANewParent (used when a parsed expression
      becomes the first child of an enclosing node, e.g. assignment). }
    procedure Adopt(ANewParent, ANode: Integer);
    function Kind(ANode: Integer): TPasNodeKind;
    function Build(const ASource: TPasPreprocessed): TPasTree;
  end;

  { nkAttribute.Aux (19.3.3): amaNone/amaRef/amaVolatile/amaWeak/amaUnsafe
    for the attribute name ANameLower (already lower-cased, `Attribute`
    suffix not yet stripped by the caller -- both the bare and suffixed
    spellings are matched here, the same either-spelling tolerance 19.3.1's
    own suffix fallback already gives every OTHER attribute). Free function,
    not a TPasTree method: the parser calls it before any node/tree exists
    yet (ParseAttrGroups, right after reading the identifier). }
  function PasAttrMagicAux(const ANameLower: string): Integer;

implementation

uses
  System.SysUtils,
  System.TypInfo;

function PasAttrMagicAux(const ANameLower: string): Integer;
begin
  if (ANameLower = 'ref') or (ANameLower = 'refattribute') then
    Result := amaRef
  else if (ANameLower = 'volatile') or (ANameLower = 'volatileattribute') then
    Result := amaVolatile
  else if (ANameLower = 'weak') or (ANameLower = 'weakattribute') then
    Result := amaWeak
  else if (ANameLower = 'unsafe') or (ANameLower = 'unsafeattribute') then
    Result := amaUnsafe
  else
    Result := amaNone;
end;

{ TPasTree }

function TPasTree.KindName(AKind: TPasNodeKind): string;
begin
  Result := GetEnumName(TypeInfo(TPasNodeKind), Ord(AKind));
  Delete(Result, 1, 2); // strip 'nk'
end;

{ An identifier node's NAME KEY: its text, lower-cased, with a leading '&'
  removed.

  `&Foo` and `Foo` are the SAME identifier - the ampersand only stops the word
  being read as a keyword, it is not part of the name. dcc-verified in BOTH
  directions: a parameter declared `var Message` can be written `&Message` in
  the body, one declared `var &Message` can be written `Message`, and `&begin`
  declares an identifier named `begin`. Vcl.Controls mixes the two spellings of
  the same parameter inside a single routine.

  So NodeText (full fidelity, ampersand included - right for spans, hovers and
  round-tripping) must never be used directly as a lookup or declaration key;
  this is what to use instead. }
function TPasTree.NodeNameLower(AIndex: Integer): string;
var
  LText: PChar;
  LLen, LIdx: Integer;
  LCh: Char;
  LOut: PChar;
begin
  // Single pass over the token slice: ONE allocation where the old
  // NodeText -> Delete('&') -> LowerCase chain paid two or three. Folding is
  // ASCII-only ('A'..'Z'), exactly what LowerCase did, so keys are unchanged.
  // Same bounds backstop as NodeText - see its comment.
  if (AIndex < 0) or (AIndex > High(Nodes)) then
    Exit('');
  if (Nodes[AIndex].FirstToken < 0) or
     (Nodes[AIndex].FirstToken > High(Source.Visible)) then
    Exit('');
  Source.VisibleSlice(Nodes[AIndex].FirstToken, LText, LLen);
  if (LLen > 0) and (LText^ = '&') then
  begin
    Inc(LText);
    Dec(LLen);
  end;
  SetLength(Result, LLen);
  LOut := PChar(Pointer(Result));
  for LIdx := 0 to LLen - 1 do
  begin
    LCh := LText[LIdx];
    if (LCh >= 'A') and (LCh <= 'Z') then
      Inc(LCh, 32);
    LOut[LIdx] := LCh;
  end;
end;

function TPasTree.NodeTextEquals(AIndex: Integer; const AWord: string): Boolean;
var
  LText: PChar;
  LLen: Integer;
begin
  // Same bounds backstop as NodeText; same '&' semantics as SameText on the
  // copied text (an escaped identifier keeps its '&' and never matches).
  if (AIndex < 0) or (AIndex > High(Nodes)) then
    Exit(False);
  if (Nodes[AIndex].FirstToken < 0) or
     (Nodes[AIndex].FirstToken > High(Source.Visible)) then
    Exit(False);
  Source.VisibleSlice(Nodes[AIndex].FirstToken, LText, LLen);
  Result := SliceEqualsWord(LText, LLen, AWord);
end;

function TPasTree.NodeText(AIndex: Integer): string;
begin
  // Backstop, not a licence: every caller is expected to pass a real node id.
  // It exists because the alternative is worse than a wrong answer - without
  // range checks an out-of-range index reads whatever memory follows Nodes, so
  // a caller bug became NON-DETERMINISTIC behaviour rather than a failure
  // (found exactly that way: a token index passed here, see
  // TPasSemaResolver.WithTargetTypeSym's nkBinaryOp case). An analyzer must not
  // read past its own arrays whatever it is fed.
  if (AIndex < 0) or (AIndex > High(Nodes)) then
    Exit('');
  if (Nodes[AIndex].FirstToken >= 0) and
     (Nodes[AIndex].FirstToken <= High(Source.Visible)) then
    Result := Source.VisibleText(Nodes[AIndex].FirstToken)
  else
    Result := '';
end;

function TPasTree.NodeLeftmostVis(AIndex: Integer): Integer;
var
  LNode, LTok: Integer;
begin
  if (AIndex < 0) or (AIndex > High(Nodes)) then
    Exit(-1);
  Result := Nodes[AIndex].FirstToken;
  LNode := Nodes[AIndex].FirstChild;
  while LNode <> NIL_NODE do
  begin
    LTok := Nodes[LNode].FirstToken;
    if (LTok >= 0) and ((Result < 0) or (LTok < Result)) then
      Result := LTok;
    LNode := Nodes[LNode].FirstChild;
  end;
end;

function TPasTree.NodeSpanText(AIndex: Integer): string;
var
  LFirst, LLast: Integer;
  LFrom, LTo: TPasVisibleToken;
begin
  Result := '';
  if (AIndex < 0) or (AIndex > High(Nodes)) then
    Exit;
  LFirst := NodeLeftmostVis(AIndex);
  LLast := Nodes[AIndex].LastToken;
  if (LFirst < 0) or (LLast < LFirst) or (LLast > High(Source.Visible)) then
    Exit;
  LFrom := Source.Visible[LFirst];
  LTo := Source.Visible[LLast];
  if LFrom.FileId <> LTo.FileId then
    Exit;
  with Source.Files[LFrom.FileId] do
    Result := Copy(Source, Tokens[LFrom.TokenIndex].Start + 1,
      Tokens[LTo.TokenIndex].EndPos - Tokens[LFrom.TokenIndex].Start);
end;

function TPasTree.DeclDocComment(AIndex: Integer): string;
var
  LTS: TPasTokenStream;
  LVisTok: TPasVisibleToken;
  LDecl, LVis, LRaw, LDepth, LBreaks, LIdx, LCount: Integer;
  LText: string;
  LLines: TArray<string>;
  LDone: Boolean;

  function TokenText(ARaw: Integer): string;
  begin
    Result := Copy(LTS.Source, LTS.Tokens[ARaw].Start + 1,
      LTS.Tokens[ARaw].Len);
  end;

begin
  Result := '';
  if (AIndex < 0) or (AIndex > High(Nodes)) then
    Exit;
  // Climb to the declaration ROOT: the OUTERMOST declaration-shaped ancestor
  // (a name node sits inside its declaration; the doc sits above the whole
  // declaration). Containers end the climb - a nested routine keeps its own
  // nkRoutine because nkRoutineBody stops the walk before the outer one.
  LDecl := NIL_NODE;
  LIdx := AIndex;
  while LIdx <> NIL_NODE do
  begin
    case Nodes[LIdx].Kind of
      nkRoutine, nkTypeDecl, nkConstDecl, nkVarDecl, nkPropertyDecl,
      nkEnumValue, nkInlineVar, nkInlineConst:
        LDecl := LIdx;
      nkTypeSec, nkConstSec, nkVarSec, nkLabelSec, nkInterfaceSec,
      nkImplementationSec, nkUnit, nkProgram, nkLibrary, nkPackage,
      nkBlock, nkRoutineBody, nkClassType, nkRecordType, nkInterfaceType,
      nkObjectType, nkHelperType:
        Break;
    end;
    LIdx := Nodes[LIdx].Parent;
  end;
  if LDecl = NIL_NODE then
    Exit;
  LVis := NodeLeftmostVis(LDecl);
  if (LVis < 0) or (LVis > High(Source.Visible)) then
    Exit;
  LVisTok := Source.Visible[LVis];
  LTS := Source.Files[LVisTok.FileId];
  // Backward over the RAW stream of the declaration's own file.
  LRaw := LVisTok.TokenIndex - 1;
  LDepth := 0;
  LLines := nil;
  LCount := 0;
  LDone := False;
  while (LRaw >= 0) and not LDone do
  begin
    if LDepth > 0 then
      // Stepping over an attribute group: only the brackets count; its
      // interior (including line breaks) is not the doc block's business.
      case LTS.Tokens[LRaw].Kind of
        tkRBracket: Inc(LDepth);
        tkLBracket: Dec(LDepth);
      end
    else
      case LTS.Tokens[LRaw].Kind of
        tkWhitespace:
          begin
            // A BLANK line breaks attachment: doc must sit immediately
            // above (the native IDE's rule) - two line breaks in one
            // whitespace run mean an empty line between.
            LText := TokenText(LRaw);
            LBreaks := 0;
            for LIdx := 1 to Length(LText) do
              if LText[LIdx] = #10 then
                Inc(LBreaks);
            if LBreaks = 0 then
              // Classic-Mac CR-only line ends, defensively.
              for LIdx := 1 to Length(LText) do
                if LText[LIdx] = #13 then
                  Inc(LBreaks);
            if LBreaks >= 2 then
              LDone := True;
          end;
        tkCommentLine:
          begin
            LText := TokenText(LRaw);
            if (Length(LText) >= 3) and (LText[1] = '/') and
               (LText[2] = '/') and (LText[3] = '/') then
            begin
              // Strip the marker and the ONE conventional space after it.
              Delete(LText, 1, 3);
              if (LText <> '') and (LText[1] = ' ') then
                Delete(LText, 1, 1);
              if LCount = Length(LLines) then
                SetLength(LLines, LCount * 2 + 8);
              LLines[LCount] := TrimRight(LText);
              Inc(LCount);
            end
            else
              LDone := True;   // an ordinary // comment is not doc
          end;
        tkRBracket:
          Inc(LDepth);   // an attribute group between doc and declaration
      else
        LDone := True;   // code, brace/paren comments, directives
      end;
    Dec(LRaw);
  end;
  // Collected bottom-up - emit in source order.
  for LIdx := LCount - 1 downto 0 do
  begin
    if Result <> '' then
      Result := Result + #10;
    Result := Result + LLines[LIdx];
  end;
end;

function TPasTree.Dump(AIndex: Integer): string;
var
  LChild: Integer;
  LChildren: string;
  LText: string;
begin
  Result := KindName(Nodes[AIndex].Kind);
  case Nodes[AIndex].Kind of
    nkIdent, nkIntLit, nkRealLit, nkStrLit, nkCaretChar:
      Result := Result + '''' + NodeText(AIndex) + '''';
    nkUnaryOp, nkBinaryOp:
      if (Nodes[AIndex].Aux >= 0) then
      begin
        LText := Source.VisibleText(Nodes[AIndex].Aux);
        Result := Result + '''' + LowerCase(LText) + '''';
        if nfNegated in Nodes[AIndex].Flags then
          Result := Result + '!';
      end;
    // Nodes whose HEAD WORD is the whole distinction: `threadvar` from `var`,
    // `resourcestring` from `const`, which visibility, which directive, which
    // property specifier. All of them are one token at FirstToken, and without
    // it a declaration dump cannot tell those pairs apart.
    nkVarSec:
      // A `class var` run has no head word of its own (the struct-body parser
      // has already eaten both keywords, so FirstToken is the first NAME);
      // Aux marks it instead.
      if Nodes[AIndex].Aux = 1 then
        Result := Result + '#class'
      else
        Result := Result + '''' + LowerCase(NodeText(AIndex)) + '''';
    nkVisibility:
      begin
        // The LEVEL is in Aux, not at FirstToken: `strict private` starts on
        // `strict`, so the head word alone cannot tell the two strict forms
        // apart. nfNegated is the parser's strict marker.
        case Nodes[AIndex].Aux of
          1: LText := 'private';
          2: LText := 'protected';
          3: LText := 'public';
          4: LText := 'published';
          5: LText := 'automated';
        else
          LText := '?';
        end;
        Result := Result + '''' + LText + '''';
        if nfNegated in Nodes[AIndex].Flags then
          Result := Result + '#strict';
      end;
    nkConstSec, nkDirective, nkPropSpec:
      Result := Result + '''' + LowerCase(NodeText(AIndex)) + '''';
    // 16.4.1: a `class`/`record`/`constructor` constraint is a bare
    // keyword with no child of its own (ParseGenericParamsOpt just
    // Nexts past it); a SPECIFIC-type constraint (`T: IInterface`) adopts
    // the type ref as a child instead, so printing the head word there
    // too would just repeat the child's own Ident text.
    nkConstraint:
      if Nodes[AIndex].FirstChild = NIL_NODE then
        Result := Result + '''' + LowerCase(NodeText(AIndex)) + '''';
    // Nodes whose distinction is a flag in Aux (see the kind comments): a
    // marker reads better in an expected string than a number would.
    nkTypeDecl:
      if Nodes[AIndex].Aux = 1 then
        Result := Result + '#distinct';
    nkInterfaceType:
      if Nodes[AIndex].Aux = 1 then
        Result := Result + '#disp';
    nkClassType:
      if Nodes[AIndex].Aux = 1 then
        Result := Result + '#forward';
    nkHelperType:
      if Nodes[AIndex].Aux = 1 then
        Result := Result + '#record';
    nkArrayType:
      if Nodes[AIndex].Aux = 1 then
        Result := Result + '#ofconst';
    nkProcType:
      case Nodes[AIndex].Aux of
        1: Result := Result + '#ofobject';
        2: Result := Result + '#reference';
      end;
    // A routine needs BOTH: the head word says procedure/function/constructor/
    // destructor/operator, Aux says whether `class` preceded it (that keyword
    // is not in the node's own token span - the struct-body parser eats it).
    nkRoutine:
      begin
        Result := Result + '''' + LowerCase(NodeText(AIndex)) + '''';
        if Nodes[AIndex].Aux = 1 then
          Result := Result + '#class';
      end;
    nkPropertyDecl:
      if Nodes[AIndex].Aux = 1 then
        Result := Result + '#class';
    nkVarDecl:
      if Nodes[AIndex].Aux = 1 then
        Result := Result + '#absolute';
    nkParam:
      if Nodes[AIndex].Aux >= 0 then
        Result := Result + '#out';
    // 19.3.3: which compiler-recognized attribute this is, if any -- see
    // the ama* constants and PasAttrMagicAux.
    nkAttribute:
      case Nodes[AIndex].Aux of
        amaRef: Result := Result + '#ref';
        amaVolatile: Result := Result + '#volatile';
        amaWeak: Result := Result + '#weak';
        amaUnsafe: Result := Result + '#unsafe';
      end;
  end;
  LChildren := '';
  LChild := Nodes[AIndex].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if LChildren <> '' then
      LChildren := LChildren + ' ';
    LChildren := LChildren + Dump(LChild);
    LChild := Nodes[LChild].NextSibling;
  end;
  if LChildren <> '' then
    Result := Result + '(' + LChildren + ')';
end;

{ TPasTreeBuilder }

procedure TPasTreeBuilder.Init(ACapacityHint: Integer);
begin
  // The parser passes ~half its visible-token count (nodes run 0.5-1x visible
  // tokens): one up-front allocation instead of ~10 doublings each copying the
  // arena so far. Build still trims to the exact count.
  if ACapacityHint < 64 then
    ACapacityHint := 64;
  FNodes := nil;
  FLastChild := nil;
  FCount := 0;
  SetLength(FNodes, ACapacityHint);
  SetLength(FLastChild, ACapacityHint);
end;

procedure TPasTreeBuilder.Grow;
begin
  if FCount = Length(FNodes) then
  begin
    SetLength(FNodes, Length(FNodes) * 2);
    SetLength(FLastChild, Length(FNodes));
  end;
end;

function TPasTreeBuilder.AddNode(AKind: TPasNodeKind; AParent,
  AFirstToken: Integer): Integer;
begin
  Grow;
  Result := FCount;
  Inc(FCount);
  FNodes[Result].Kind := AKind;
  FNodes[Result].Flags := [];
  FNodes[Result].FirstToken := AFirstToken;
  FNodes[Result].LastToken := AFirstToken;
  FNodes[Result].Parent := AParent;
  FNodes[Result].FirstChild := NIL_NODE;
  FNodes[Result].NextSibling := NIL_NODE;
  FNodes[Result].Aux := NIL_NODE;
  FLastChild[Result] := NIL_NODE;
  if AParent <> NIL_NODE then
  begin
    if FNodes[AParent].FirstChild = NIL_NODE then
      FNodes[AParent].FirstChild := Result
    else
      FNodes[FLastChild[AParent]].NextSibling := Result;
    FLastChild[AParent] := Result;
  end;
end;

procedure TPasTreeBuilder.SetLast(ANode, ALastToken: Integer);
begin
  FNodes[ANode].LastToken := ALastToken;
end;

procedure TPasTreeBuilder.SetAux(ANode, AAux: Integer);
begin
  FNodes[ANode].Aux := AAux;
end;

procedure TPasTreeBuilder.SetKind(ANode: Integer; AKind: TPasNodeKind);
begin
  FNodes[ANode].Kind := AKind;
end;

procedure TPasTreeBuilder.AddFlag(ANode: Integer; AFlag: TPasNodeFlag);
begin
  Include(FNodes[ANode].Flags, AFlag);
end;

procedure TPasTreeBuilder.Adopt(ANewParent, ANode: Integer);
var
  LPrev, LCur: Integer;
begin
  // Detach from the old parent's child list.
  if FNodes[ANode].Parent <> NIL_NODE then
  begin
    LPrev := NIL_NODE;
    LCur := FNodes[FNodes[ANode].Parent].FirstChild;
    while (LCur <> NIL_NODE) and (LCur <> ANode) do
    begin
      LPrev := LCur;
      LCur := FNodes[LCur].NextSibling;
    end;
    if LCur = ANode then
    begin
      if LPrev = NIL_NODE then
        FNodes[FNodes[ANode].Parent].FirstChild := FNodes[ANode].NextSibling
      else
        FNodes[LPrev].NextSibling := FNodes[ANode].NextSibling;
      if FLastChild[FNodes[ANode].Parent] = ANode then
        FLastChild[FNodes[ANode].Parent] := LPrev;
    end;
  end;
  FNodes[ANode].NextSibling := NIL_NODE;
  FNodes[ANode].Parent := ANewParent;
  if FNodes[ANewParent].FirstChild = NIL_NODE then
    FNodes[ANewParent].FirstChild := ANode
  else
    FNodes[FLastChild[ANewParent]].NextSibling := ANode;
  FLastChild[ANewParent] := ANode;
end;

function TPasTreeBuilder.Kind(ANode: Integer): TPasNodeKind;
begin
  Result := FNodes[ANode].Kind;
end;

function TPasTreeBuilder.Build(const ASource: TPasPreprocessed): TPasTree;
begin
  SetLength(FNodes, FCount);
  Result.Nodes := FNodes;
  Result.Source := ASource;
  FNodes := nil;
  FLastChild := nil;
  FCount := 0;
end;

end.
