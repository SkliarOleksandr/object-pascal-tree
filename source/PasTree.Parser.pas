unit PasTree.Parser;

{
  PasTree — the parser, v1: full expression grammar (spec B.7/B.9, ch.04)
  and statements (ch.05 + ch.18). Declarations come next.

  Principles:
  - Error-tolerant: parsing never raises; unexpected input produces nkError
    nodes plus diagnostics, and the cursor always makes progress.
  - Reads the preprocessor's VISIBLE stream; trivia and directives are
    invisible here but recoverable via token indices (full fidelity).
  - Disambiguation notes reference the spec:
    * assignment vs call statement — ":=" after a parsed designator (5.1);
    * dangling else — nearest unmatched if (5.3.1);
    * inline-if expression vs if statement — by context (5.4.1);
    * generic args vs less-than — bounded speculative token scan (16.3);
    * caret control-char vs deref — operand position + raw adjacency (B.6.2);
    * "is not" / "not in" — token pairs at the relational level (4.9.1);
    * "at" / "on" — contextual directives, matched by text (18.x).
}

interface

uses
  PasTree.Types,
  PasTree.Preprocessor,
  PasTree.Ast;

type
  TPasParseDiag = record
    VisIndex: Integer;   // visible-stream position
    Msg: string;
  end;

  TPasParser = record
  private
    FSrc: TPasPreprocessed;
    FB: TPasTreeBuilder;
    FPos: Integer;
    FLast: Integer;      // High(FSrc.Visible)
    FDiags: TArray<TPasParseDiag>;
    FDiagCount: Integer;
    FStuckPos: Integer;
    FStuckCount: Integer;
    // Watchdogs (see notes on ParseGuard):
    FFuel: Int64;              // decremented in CurKind; trips at 0
    FFuelTripped: Boolean;
    FDepth: Integer;           // recursion depth across Parse* entries
    FRoutineNameVis: Integer;  // diagnostics: current routine's name token
    // cursor
    function CurKind: TPasTokenKind;
    function EnterGuard: Boolean;
    procedure LeaveGuard;
    function PeekKind(AOffset: Integer): TPasTokenKind;
    function CurText: string;
    procedure Next;
    function Expect(AKind: TPasTokenKind; const AWhat: string): Boolean;
    function IsWord(const AWord: string): Boolean;
    function AdjacentNext: Boolean;
    procedure Error(const AMsg: string);
    // expressions
    function ParseExpression: Integer;
    function ParseSimpleExpr: Integer;
    function ParseTerm: Integer;
    function ParseFactor: Integer;
    function ParseSelectors(ABase: Integer): Integer;
    function ParseTypeRef: Integer;
    function ScanGenericArgs(AFrom: Integer): Integer;
    function ParseArgList(ACall: Integer): Integer;
    // statements
    function ParseStatement: Integer;
    function ParseBlockUntil(ABlock: Integer;
      const ATerminators: array of TPasTokenKind): Integer;
    function AtAny(const AKinds: array of TPasTokenKind): Boolean;
    function ParseIfStmt: Integer;
    function ParseCaseStmt: Integer;
    function ParseForStmt: Integer;
    function ParseTryStmt: Integer;
    function ParseInlineVar(AConst: Boolean): Integer;
    // declarations (spec ch.01/02/03/06/09/11/13/14/15/16)
    function ParseQualifiedName: Integer;
    function ParseUsesClause: Integer;
    function ParseAttrGroups: Integer;
    procedure ParseHintsOpt(ANode: Integer);
    function ParseTypeExpr: Integer;
    function ParseEnumType: Integer;
    function ParseArrayType: Integer;
    function ParseProcTypeExpr(ARefTo: Boolean): Integer;
    function ParseClassLike(AHeadKind: TPasTokenKind): Integer;
    procedure ParseMemberList(AOwner: Integer);
    procedure ParseVariantPart(AOwner: Integer);
    procedure ParseFieldList(AOwner: Integer;
      const ATerminators: array of TPasTokenKind);
    function ParseGenericParamsOpt: Integer;
    function ParseParamList(AClose: TPasTokenKind): Integer;
    function ParseRoutine(AClassMethod, AAllowBody: Boolean): Integer;
    function ParseRoutineDirectives(ARoutine: Integer): Boolean; // True=no body
    function ParseRoutineBody: Integer;
    function ParseProperty(AClassProp: Boolean): Integer;
    function ParseTypeSection: Integer;
    function ParseConstSection: Integer;
    function ParseVarSection(AClassVar: Boolean): Integer;
    function ParseConstInitializer(AHasType: Boolean): Integer;
    function ParseExportsClause: Integer;
    function IsDirectiveWord: Boolean;
    function IsVisibilityWord: Boolean;
    procedure MarkContextKeyword;
    procedure ConsumeTrailingDirectives;
    procedure ParseDeclSections(AParent: Integer; AAllowBodies: Boolean;
      const ATerminators: array of TPasTokenKind);
  public
    class function ParseStatements(const ASource: TPasPreprocessed;
      out ADiags: TArray<TPasParseDiag>): TPasTree; static;
    { Parses a whole source file (unit/program/library/package).
      When AInterfaceOnly is True AND the file is a unit, parsing stops right
      after the interface section (the implementation/init/final/end. are NOT
      consumed) — enough for cross-unit navigation, and cheap. The flag is
      IGNORED for program/library/package (they have no interface section).
      PREFIX INVARIANT (relied on by the async parser's snapshot swap): the
      resulting tree's nodes [0..N-1] are byte-identical to a full parse of
      the same source, EXCEPT Nodes[0] (nkUnit root) LastToken and the
      nkInterfaceSec node's NextSibling (NIL_NODE here vs the impl section in
      a full parse) — see StagedParseSmoke for the exact, tested delta. }
    class function ParseFile(const ASource: TPasPreprocessed;
      out ADiags: TArray<TPasParseDiag>;
      AInterfaceOnly: Boolean = False): TPasTree; static;
  end;

implementation

uses
  System.SysUtils;

const
  STMT_TERMINATORS: array[0..4] of TPasTokenKind =
    (tkEnd, tkUntil, tkFinally, tkExcept, tkEndOfFile);

{ TPasParser — cursor ------------------------------------------------------- }

function TPasParser.CurKind: TPasTokenKind;
begin
  // Fuel watchdog: CurKind is evaluated by every parsing loop's condition,
  // so a step budget here bounds ALL loops — including silent ones that
  // never consume and never report. Deterministic (per-token budget), so
  // parse stays a pure function: no timers, no wall-clock, thread-safe.
  if FFuel > 0 then
    Dec(FFuel)
  else if not FFuelTripped then
  begin
    FFuelTripped := True;
    Error('internal: parser step budget exhausted (loop guard)');
    FPos := FLast; // jump to EOF — every loop terminates naturally
  end;
  Result := FSrc.VisibleToken(FPos).Kind;
end;

function TPasParser.EnterGuard: Boolean;
begin
  // Recursion-depth watchdog: guards the mutually recursive entry points
  // against stack overflow on pathological nesting. Callers that get False
  // must emit an error node WITHOUT recursing further.
  Inc(FDepth);
  Result := FDepth <= 512;
  if not Result then
    Error('internal: parser recursion limit reached');
end;

procedure TPasParser.LeaveGuard;
begin
  Dec(FDepth);
end;

function TPasParser.PeekKind(AOffset: Integer): TPasTokenKind;
var
  LIdx: Integer;
begin
  LIdx := FPos + AOffset;
  if LIdx > FLast then
    LIdx := FLast;
  Result := FSrc.VisibleToken(LIdx).Kind;
end;

function TPasParser.CurText: string;
begin
  Result := FSrc.VisibleText(FPos);
end;

procedure TPasParser.Next;
begin
  if FPos < FLast then
    Inc(FPos);
end;

function TPasParser.Expect(AKind: TPasTokenKind; const AWhat: string): Boolean;
begin
  Result := CurKind = AKind;
  if Result then
    Next
  else
    Error(AWhat + ' expected');
end;

function TPasParser.IsWord(const AWord: string): Boolean;
begin
  Result := (CurKind = tkIdentifier) and SameText(CurText, AWord);
end;

function TPasParser.AdjacentNext: Boolean;
begin
  // True when the next visible token is raw-adjacent to the current one
  // (same file, consecutive raw indices — no trivia between).
  Result := (FPos < FLast) and
    (FSrc.Visible[FPos + 1].FileId = FSrc.Visible[FPos].FileId) and
    (FSrc.Visible[FPos + 1].TokenIndex = FSrc.Visible[FPos].TokenIndex + 1);
end;

procedure TPasParser.Error(const AMsg: string);
begin
  if FDiagCount = Length(FDiags) then
    SetLength(FDiags, Length(FDiags) * 2 + 8);
  FDiags[FDiagCount].VisIndex := FPos;
  FDiags[FDiagCount].Msg := AMsg;
  Inc(FDiagCount);
  // Anti-stall guard: repeated errors at one position mean some recovery
  // path is not consuming — force progress rather than loop forever.
  if FPos = FStuckPos then
  begin
    Inc(FStuckCount);
    if FStuckCount > 50 then
    begin
      FStuckCount := 0;
      Next;
    end;
  end
  else
  begin
    FStuckPos := FPos;
    FStuckCount := 0;
  end;
end;

{ TPasParser — expressions --------------------------------------------------- }

function TPasParser.ParseExpression: Integer;
var
  LOp, LRight, LNode: Integer;
  LNegated: Boolean;
begin
  Result := ParseSimpleExpr;
  while True do
  begin
    LNegated := False;
    case CurKind of
      tkEqual, tkNotEqual, tkLess, tkGreater, tkLessEqual, tkGreaterEqual,
      tkIn:
        LOp := FPos;
      tkIs:
        begin
          LOp := FPos;
          // "is not" (4.9.1) — negation consumed after the operator below.
        end;
      tkNot:
        begin
          // "not in" (4.9.1)
          if PeekKind(1) <> tkIn then
            Break;
          LNegated := True;
          Next; // 'not'
          LOp := FPos; // 'in'
        end;
    else
      Break;
    end;
    Next; // operator
    if (FSrc.VisibleToken(LOp).Kind = tkIs) and (CurKind = tkNot) then
    begin
      LNegated := True;
      Next;
    end;
    LRight := ParseSimpleExpr;
    LNode := FB.AddNode(nkBinaryOp, NIL_NODE, LOp);
    FB.SetAux(LNode, LOp);
    if LNegated then
      FB.AddFlag(LNode, nfNegated);
    FB.Adopt(LNode, Result);
    FB.Adopt(LNode, LRight);
    FB.SetLast(LNode, FPos - 1);
    Result := LNode;
  end;
end;

function TPasParser.ParseSimpleExpr: Integer;
var
  LOp, LRight, LNode: Integer;
begin
  Result := ParseTerm;
  while CurKind in [tkPlus, tkMinus, tkOr, tkXor] do
  begin
    LOp := FPos;
    Next;
    LRight := ParseTerm;
    LNode := FB.AddNode(nkBinaryOp, NIL_NODE, LOp);
    FB.SetAux(LNode, LOp);
    FB.Adopt(LNode, Result);
    FB.Adopt(LNode, LRight);
    FB.SetLast(LNode, FPos - 1);
    Result := LNode;
  end;
end;

function TPasParser.ParseTerm: Integer;
var
  LOp, LRight, LNode: Integer;
begin
  Result := ParseFactor;
  while CurKind in [tkStar, tkSlash, tkDiv, tkMod, tkAnd, tkShl, tkShr, tkAs]
  do
  begin
    LOp := FPos;
    Next;
    LRight := ParseFactor;
    LNode := FB.AddNode(nkBinaryOp, NIL_NODE, LOp);
    FB.SetAux(LNode, LOp);
    FB.Adopt(LNode, Result);
    FB.Adopt(LNode, LRight);
    FB.SetLast(LNode, FPos - 1);
    Result := LNode;
  end;
end;

function TPasParser.ParseFactor: Integer;
var
  LNode, LChild, LStart: Integer;
begin
  LStart := FPos;
  if not EnterGuard then
  begin
    Result := FB.AddNode(nkError, NIL_NODE, LStart);
    Next;
    LeaveGuard;
    Exit;
  end;
  try
  case CurKind of
    tkPlus, tkMinus, tkNot, tkAt:
      begin
        LNode := FB.AddNode(nkUnaryOp, NIL_NODE, LStart);
        FB.SetAux(LNode, LStart);
        Next;
        LChild := ParseFactor;
        FB.Adopt(LNode, LChild);
        FB.SetLast(LNode, FPos - 1);
        Exit(LNode);
      end;
    tkIntLiteral:
      begin
        // Literals take selectors too: 42.ToString (XE3 helpers).
        Result := FB.AddNode(nkIntLit, NIL_NODE, LStart);
        Next;
        Exit(ParseSelectors(Result));
      end;
    tkRealLiteral:
      begin
        Result := FB.AddNode(nkRealLit, NIL_NODE, LStart);
        Next;
        Exit(ParseSelectors(Result));
      end;
    tkStringLiteral, tkMultilineString, tkControlChar:
      begin
        // Adjacent string elements concatenate into one literal (B.6.1);
        // helper calls on literals are legal: '.amazonaws.com'.Length
        // (Data.Cloud.AmazonAPI.pas).
        Result := FB.AddNode(nkStrLit, NIL_NODE, LStart);
        Next;
        while CurKind in [tkStringLiteral, tkMultilineString, tkControlChar]
        do
          Next;
        FB.SetLast(Result, FPos - 1);
        Exit(ParseSelectors(Result));
      end;
    tkNil:
      begin
        // Even nil takes selectors: GetPaletteEntries(..., nil^)
        // (Vcl.Imaging.GIFImg.pas).
        Result := FB.AddNode(nkNilLit, NIL_NODE, LStart);
        Next;
        Exit(ParseSelectors(Result));
      end;
    tkCaret:
      begin
        // Operand position: caret control char (B.6.2), e.g. ^M — the
        // letter must be raw-adjacent to the caret (no trivia between).
        LNode := FB.AddNode(nkCaretChar, NIL_NODE, LStart);
        if AdjacentNext and (PeekKind(1) = tkIdentifier) then
        begin
          Next;
          Next;
        end
        else
        begin
          Next;
          Error('control character expected after "^"');
        end;
        FB.SetLast(LNode, FPos - 1);
        Exit(LNode);
      end;
    tkLParen:
      begin
        LNode := FB.AddNode(nkParen, NIL_NODE, LStart);
        Next;
        LChild := ParseExpression;
        FB.Adopt(LNode, LChild);
        Expect(tkRParen, '")"');
        FB.SetLast(LNode, FPos - 1);
        Exit(ParseSelectors(LNode));
      end;
    tkLBracket:
      begin
        // Set/array constructor (B.9); elements may be ranges (a..b).
        LNode := FB.AddNode(nkSetCtor, NIL_NODE, LStart);
        Next;
        while (CurKind <> tkRBracket) and (CurKind <> tkEndOfFile) do
        begin
          LChild := ParseExpression;
          if CurKind = tkDotDot then
          begin
            LStart := FB.AddNode(nkRange, NIL_NODE, FPos);
            FB.Adopt(LStart, LChild);
            Next;
            FB.Adopt(LStart, ParseExpression);
            FB.SetLast(LStart, FPos - 1);
            LChild := LStart;
          end;
          FB.Adopt(LNode, LChild);
          if CurKind = tkComma then
            Next
          else
            Break;
        end;
        Expect(tkRBracket, '"]"');
        FB.SetLast(LNode, FPos - 1);
        Exit(LNode);
      end;
    tkIf:
      begin
        // Inline-if expression (5.4.1): mandatory else.
        LNode := FB.AddNode(nkInlineIf, NIL_NODE, LStart);
        Next;
        FB.Adopt(LNode, ParseExpression);
        Expect(tkThen, '"then"');
        FB.Adopt(LNode, ParseExpression);
        Expect(tkElse, '"else"');
        FB.Adopt(LNode, ParseExpression);
        FB.SetLast(LNode, FPos - 1);
        Exit(LNode);
      end;
    tkInherited:
      begin
        LNode := FB.AddNode(nkInherited, NIL_NODE, LStart);
        Next;
        if CurKind = tkIdentifier then
        begin
          LChild := FB.AddNode(nkIdent, NIL_NODE, FPos);
          Next;
          LChild := ParseSelectors(LChild);
          FB.Adopt(LNode, LChild);
          FB.SetLast(LNode, FPos - 1);
          Exit(LNode);
        end;
        FB.SetLast(LNode, FPos - 1);
        // Bare inherited can be selected directly:
        // inherited.AsExtended (FMX.Grid.Style.pas).
        Exit(ParseSelectors(LNode));
      end;
    tkProcedure, tkFunction:
      begin
        // Anonymous method literal (17.2.1). Params parse with the same
        // grammar (and same nkParams/nkParam shape) as a routine's, so the
        // resolver declares them like any parameter — `AIndex` inside a
        // `procedure(AIndex: Integer) begin ... end` literal is a real,
        // resolvable symbol, not opaque trivia (the retired v1 shape).
        LNode := FB.AddNode(nkAnonMethod, NIL_NODE, LStart);
        Next;
        if CurKind = tkLParen then
          FB.Adopt(LNode, ParseParamList(tkRParen));
        if CurKind = tkColon then
        begin
          Next;
          FB.Adopt(LNode, ParseTypeRef);
        end;
        // Inline conventions before the body are legal:
        // function(AResult: HResult): HResult stdcall begin (Vcl.Edge.pas)
        while IsDirectiveWord do
          Next;
        // The body is a full routine body: anonymous methods may declare
        // locals — function(...): TValue var fx: Extended; begin ... end
        // (System.Bindings.EvalSys.pas) — and even nested routines.
        FB.Adopt(LNode, ParseRoutineBody);
        FB.SetLast(LNode, FPos - 1);
        Exit(LNode);
      end;
    tkIdentifier, tkString, tkFile:
      begin
        // tkString/tkFile: type keywords legal as cast/designator heads.
        LNode := FB.AddNode(nkIdent, NIL_NODE, LStart);
        Next;
        Exit(ParseSelectors(LNode));
      end;
  else
    Error('expression expected, found "' + CurText + '"');
    Result := FB.AddNode(nkError, NIL_NODE, LStart);
    Next; // always make progress
  end;
  finally
    LeaveGuard;
  end;
end;

function TPasParser.ParseSelectors(ABase: Integer): Integer;
var
  LNode, LChild, LScan: Integer;
begin
  Result := ABase;
  while True do
    case CurKind of
      tkDot:
        begin
          LNode := FB.AddNode(nkMember, NIL_NODE, FPos);
          FB.Adopt(LNode, Result);
          Next;
          // Member position is unambiguous, so dcc accepts RESERVED WORDS
          // as member names: TAnimationType.In (FMX declares `&In` but
          // call sites write `.In`). Accept any keyword here.
          if (CurKind = tkIdentifier) or IsKeyword(CurKind) then
          begin
            LChild := FB.AddNode(nkIdent, NIL_NODE, FPos);
            Next;
            FB.Adopt(LNode, LChild);
          end
          else
            Error('member name expected');
          FB.SetLast(LNode, FPos - 1);
          Result := LNode;
        end;
      tkLParen:
        begin
          LNode := FB.AddNode(nkCall, NIL_NODE, FPos);
          FB.Adopt(LNode, Result);
          Result := ParseArgList(LNode);
        end;
      tkLBracket:
        begin
          LNode := FB.AddNode(nkIndex, NIL_NODE, FPos);
          FB.Adopt(LNode, Result);
          Next;
          while (CurKind <> tkRBracket) and (CurKind <> tkEndOfFile) do
          begin
            FB.Adopt(LNode, ParseExpression);
            if CurKind = tkComma then
              Next
            else
              Break;
          end;
          Expect(tkRBracket, '"]"');
          FB.SetLast(LNode, FPos - 1);
          Result := LNode;
        end;
      tkCaret:
        begin
          LNode := FB.AddNode(nkDeref, NIL_NODE, FPos);
          FB.Adopt(LNode, Result);
          Next;
          FB.SetLast(LNode, FPos - 1);
          Result := LNode;
        end;
      tkLess:
        begin
          // Generic args vs comparison (16.3): bounded speculative scan.
          LScan := ScanGenericArgs(FPos);
          if LScan < 0 then
            Break;
          LNode := FB.AddNode(nkTypeArgs, NIL_NODE, FPos);
          FB.Adopt(LNode, Result);
          Next; // '<'
          while (CurKind <> tkGreater) and (CurKind <> tkEndOfFile) do
          begin
            FB.Adopt(LNode, ParseTypeRef);
            if CurKind = tkComma then
              Next
            else
              Break;
          end;
          Expect(tkGreater, '">"');
          FB.SetLast(LNode, FPos - 1);
          Result := LNode;
        end;
    else
      Break;
    end;
end;

function TPasParser.ParseArgList(ACall: Integer): Integer;
var
  LArg, LWrap: Integer;
begin
  // At '('.
  Next;
  while (CurKind <> tkRParen) and (CurKind <> tkEndOfFile) do
  begin
    LArg := ParseExpression;
    if CurKind = tkColon then
    begin
      // Write/Str formatted argument (4.11.2): expr:width[:prec].
      LWrap := FB.AddNode(nkFormattedArg, NIL_NODE, FPos);
      FB.Adopt(LWrap, LArg);
      Next;
      FB.Adopt(LWrap, ParseExpression);
      if CurKind = tkColon then
      begin
        Next;
        FB.Adopt(LWrap, ParseExpression);
      end;
      FB.SetLast(LWrap, FPos - 1);
      LArg := LWrap;
    end;
    FB.Adopt(ACall, LArg);
    if CurKind = tkComma then
      Next
    else
      Break;
  end;
  Expect(tkRParen, '")"');
  FB.SetLast(ACall, FPos - 1);
  Result := ACall;
end;

function TPasParser.ParseTypeRef: Integer;
var
  LNode, LChild: Integer;
begin
  // Minimal type reference: dotted name with optional generic args per
  // segment (B.11), plus the type keywords usable as refs.
  if CurKind in [tkIdentifier, tkString, tkFile] then
  begin
    LNode := FB.AddNode(nkIdent, NIL_NODE, FPos);
    Next;
    Result := LNode;
    while True do
      case CurKind of
        tkDot:
          begin
            LNode := FB.AddNode(nkMember, NIL_NODE, FPos);
            FB.Adopt(LNode, Result);
            Next;
            if CurKind = tkIdentifier then
            begin
              LChild := FB.AddNode(nkIdent, NIL_NODE, FPos);
              Next;
              FB.Adopt(LNode, LChild);
            end
            else
              Error('type name expected');
            FB.SetLast(LNode, FPos - 1);
            Result := LNode;
          end;
        tkLess:
          begin
            LNode := FB.AddNode(nkTypeArgs, NIL_NODE, FPos);
            FB.Adopt(LNode, Result);
            Next;
            while (CurKind <> tkGreater) and (CurKind <> tkEndOfFile) do
            begin
              FB.Adopt(LNode, ParseTypeRef);
              if CurKind = tkComma then
                Next
              else
                Break;
            end;
            Expect(tkGreater, '">"');
            FB.SetLast(LNode, FPos - 1);
            Result := LNode;
          end;
      else
        Break;
      end;
  end
  else
  begin
    Error('type expected');
    Result := FB.AddNode(nkError, NIL_NODE, FPos);
    Next;
  end;
end;

function TPasParser.ScanGenericArgs(AFrom: Integer): Integer;
var
  LIdx, LDepth, LSteps: Integer;
  LKind: TPasTokenKind;
begin
  // Returns the index just past the matching '>' when the token run from
  // AFrom looks like a generic argument list AND is followed by '(' or '.'
  // (expression context, 16.3); -1 otherwise. Pure lookahead, no nodes.
  Result := -1;
  LIdx := AFrom + 1;
  LDepth := 1;
  LSteps := 0;
  while (LIdx <= FLast) and (LSteps < 64) do
  begin
    LKind := FSrc.VisibleToken(LIdx).Kind;
    case LKind of
      tkLess:
        Inc(LDepth);
      tkGreater:
        begin
          Dec(LDepth);
          if LDepth = 0 then
          begin
            if LIdx < FLast then
            begin
              LKind := FSrc.VisibleToken(LIdx + 1).Kind;
              // Follower rule (16.3), inverted for safety: accept generic
              // args unless the next token could START AN OPERAND. If it
              // cannot (`;` `then` `=` `do` `and` ...), the comparison
              // reading `(a < X) >  <follower>` would lack a right operand
              // — a guaranteed syntax error — so accepting generic never
              // steals a valid comparison. Covers Value.AsType<T>;,
              // AsType<char> = #0, AsType<Boolean> then, @Proc<T>;.
              // '(' is genuinely ambiguous and reads as a call, matching
              // dcc (TList<Integer>.Create-style continuations).
              if not (LKind in [tkIdentifier, tkIntLiteral, tkRealLiteral,
                tkStringLiteral, tkMultilineString, tkControlChar, tkNil,
                tkNot, tkAt, tkInherited, tkPlus, tkMinus, tkCaret,
                tkLBracket, tkIf, tkProcedure, tkFunction, tkString]) then
                Exit(LIdx + 1);
            end;
            Exit(-1);
          end;
        end;
      tkIdentifier, tkDot, tkComma, tkString, tkFile:
        ; // plausible type-list content
    else
      Exit(-1);
    end;
    Inc(LIdx);
    Inc(LSteps);
  end;
end;

{ TPasParser — statements ---------------------------------------------------- }

function TPasParser.AtAny(const AKinds: array of TPasTokenKind): Boolean;
var
  LKind: TPasTokenKind;
begin
  for LKind in AKinds do
    if CurKind = LKind then
      Exit(True);
  Result := False;
end;

function TPasParser.ParseBlockUntil(ABlock: Integer;
  const ATerminators: array of TPasTokenKind): Integer;
var
  LStmt: Integer;
begin
  while True do
  begin
    while CurKind = tkSemicolon do
      Next;
    if AtAny(ATerminators) or (CurKind = tkEndOfFile) then
      Break;
    LStmt := ParseStatement;
    FB.Adopt(ABlock, LStmt);
    if CurKind = tkSemicolon then
      Continue;
    if AtAny(ATerminators) or (CurKind = tkEndOfFile) or (CurKind = tkElse)
    then
      Break;
    // Recovery: missing separator — resync to ';' or a terminator.
    Error('";" expected');
    while not (AtAny(ATerminators) or
      (CurKind in [tkSemicolon, tkEndOfFile])) do
      Next;
  end;
  Result := ABlock;
end;

function TPasParser.ParseIfStmt: Integer;
var
  LNode: Integer;
begin
  // 5.3.1; dangling else binds to the nearest if by recursion order.
  LNode := FB.AddNode(nkIfStmt, NIL_NODE, FPos);
  Next;
  FB.Adopt(LNode, ParseExpression);
  Expect(tkThen, '"then"');
  if (CurKind = tkElse) or (CurKind = tkSemicolon) then
    FB.Adopt(LNode, FB.AddNode(nkEmptyStmt, NIL_NODE, FPos))
  else
    FB.Adopt(LNode, ParseStatement);
  if CurKind = tkElse then
  begin
    Next;
    FB.Adopt(LNode, ParseStatement);
  end;
  FB.SetLast(LNode, FPos - 1);
  Result := LNode;
end;

function TPasParser.ParseCaseStmt: Integer;
var
  LNode, LSel, LLabels, LExpr, LRange, LElse: Integer;
begin
  // 5.3.2: ordinal selector; labels are const-exprs/ranges.
  LNode := FB.AddNode(nkCaseStmt, NIL_NODE, FPos);
  Next;
  FB.Adopt(LNode, ParseExpression);
  Expect(tkOf, '"of"');
  while not (CurKind in [tkElse, tkEnd, tkEndOfFile]) do
  begin
    LSel := FB.AddNode(nkCaseSel, NIL_NODE, FPos);
    LLabels := FB.AddNode(nkCaseLabels, NIL_NODE, FPos);
    FB.Adopt(LSel, LLabels);
    while True do
    begin
      LExpr := ParseExpression;
      if CurKind = tkDotDot then
      begin
        LRange := FB.AddNode(nkRange, NIL_NODE, FPos);
        FB.Adopt(LRange, LExpr);
        Next;
        FB.Adopt(LRange, ParseExpression);
        FB.SetLast(LRange, FPos - 1);
        LExpr := LRange;
      end;
      FB.Adopt(LLabels, LExpr);
      if CurKind = tkComma then
        Next
      else
        Break;
    end;
    FB.SetLast(LLabels, FPos - 1);
    Expect(tkColon, '":"');
    if CurKind in [tkSemicolon, tkElse, tkEnd] then
      FB.Adopt(LSel, FB.AddNode(nkEmptyStmt, NIL_NODE, FPos))
    else
      FB.Adopt(LSel, ParseStatement);
    FB.SetLast(LSel, FPos - 1);
    FB.Adopt(LNode, LSel);
    while CurKind = tkSemicolon do
      Next;
  end;
  if CurKind = tkElse then
  begin
    LElse := FB.AddNode(nkBlock, NIL_NODE, FPos);
    Next;
    ParseBlockUntil(LElse, [tkEnd]);
    FB.SetLast(LElse, FPos - 1);
    FB.Adopt(LNode, LElse);
  end;
  Expect(tkEnd, '"end"');
  FB.SetLast(LNode, FPos - 1);
  Result := LNode;
end;

function TPasParser.ParseForStmt: Integer;
var
  LNode, LVar: Integer;
  LIsForIn: Boolean;
begin
  // 5.5.1 / 5.5.2, incl. 10.3 inline counters.
  LNode := FB.AddNode(nkForStmt, NIL_NODE, FPos);
  Next;
  if CurKind = tkVar then
  begin
    LVar := FB.AddNode(nkInlineVar, NIL_NODE, FPos);
    Next;
    if CurKind = tkIdentifier then
    begin
      FB.Adopt(LVar, FB.AddNode(nkIdent, NIL_NODE, FPos));
      Next;
    end
    else
      Error('counter name expected');
    if CurKind = tkColon then
    begin
      Next;
      FB.Adopt(LVar, ParseTypeRef);
    end;
    FB.SetLast(LVar, FPos - 1);
    FB.Adopt(LNode, LVar);
  end
  else if CurKind = tkIdentifier then
  begin
    FB.Adopt(LNode, FB.AddNode(nkIdent, NIL_NODE, FPos));
    Next;
  end
  else
    Error('loop variable expected');

  LIsForIn := CurKind = tkIn;
  if LIsForIn then
  begin
    FB.SetKind(LNode, nkForInStmt);
    Next;
    FB.Adopt(LNode, ParseExpression);
  end
  else
  begin
    Expect(tkAssign, '":="');
    FB.Adopt(LNode, ParseExpression);
    if CurKind = tkDownto then
    begin
      FB.SetAux(LNode, 1);
      Next;
    end
    else
      Expect(tkTo, '"to"');
    FB.Adopt(LNode, ParseExpression);
  end;
  Expect(tkDo, '"do"');
  if CurKind = tkSemicolon then
    FB.Adopt(LNode, FB.AddNode(nkEmptyStmt, NIL_NODE, FPos))
  else
    FB.Adopt(LNode, ParseStatement);
  FB.SetLast(LNode, FPos - 1);
  Result := LNode;
end;

function TPasParser.ParseTryStmt: Integer;
var
  LNode, LBody, LPart, LOn, LElse: Integer;
begin
  // 18.1 / 18.2: one of except/finally, never both.
  LNode := FB.AddNode(nkTryStmt, NIL_NODE, FPos);
  Next;
  LBody := FB.AddNode(nkBlock, NIL_NODE, FPos);
  ParseBlockUntil(LBody, [tkFinally, tkExcept, tkEnd]);
  FB.SetLast(LBody, FPos - 1);
  FB.Adopt(LNode, LBody);
  if CurKind = tkFinally then
  begin
    LPart := FB.AddNode(nkFinallyPart, NIL_NODE, FPos);
    Next;
    LBody := FB.AddNode(nkBlock, NIL_NODE, FPos);
    ParseBlockUntil(LBody, [tkEnd]);
    FB.SetLast(LBody, FPos - 1);
    FB.Adopt(LPart, LBody);
    FB.SetLast(LPart, FPos - 1);
    FB.Adopt(LNode, LPart);
  end
  else if CurKind = tkExcept then
  begin
    LPart := FB.AddNode(nkExceptPart, NIL_NODE, FPos);
    Next;
    if IsWord('on') then
    begin
      // 18.1.2: on [name:] Type do stmt; ... [else ...]
      while IsWord('on') do
      begin
        LOn := FB.AddNode(nkExceptOn, NIL_NODE, FPos);
        Next;
        if (CurKind = tkIdentifier) and (PeekKind(1) = tkColon) then
        begin
          FB.Adopt(LOn, FB.AddNode(nkIdent, NIL_NODE, FPos));
          Next; // name
          Next; // ':'
        end;
        FB.Adopt(LOn, ParseTypeRef);
        Expect(tkDo, '"do"');
        if CurKind in [tkSemicolon, tkElse, tkEnd] then
          FB.Adopt(LOn, FB.AddNode(nkEmptyStmt, NIL_NODE, FPos))
        else
          FB.Adopt(LOn, ParseStatement);
        FB.SetLast(LOn, FPos - 1);
        FB.Adopt(LPart, LOn);
        while CurKind = tkSemicolon do
          Next;
      end;
      if CurKind = tkElse then
      begin
        LElse := FB.AddNode(nkBlock, NIL_NODE, FPos);
        Next;
        ParseBlockUntil(LElse, [tkEnd]);
        FB.SetLast(LElse, FPos - 1);
        FB.Adopt(LPart, LElse);
      end;
    end
    else
    begin
      // Catch-all form.
      LBody := FB.AddNode(nkBlock, NIL_NODE, FPos);
      ParseBlockUntil(LBody, [tkEnd]);
      FB.SetLast(LBody, FPos - 1);
      FB.Adopt(LPart, LBody);
    end;
    FB.SetLast(LPart, FPos - 1);
    FB.Adopt(LNode, LPart);
  end
  else
    Error('"finally" or "except" expected');
  Expect(tkEnd, '"end"');
  FB.SetLast(LNode, FPos - 1);
  Result := LNode;
end;

function TPasParser.ParseInlineVar(AConst: Boolean): Integer;
begin
  // 3.1.3: statement-position var/const with optional type & initializer.
  if AConst then
    Result := FB.AddNode(nkInlineConst, NIL_NODE, FPos)
  else
    Result := FB.AddNode(nkInlineVar, NIL_NODE, FPos);
  Next;
  if CurKind = tkIdentifier then
  begin
    FB.Adopt(Result, FB.AddNode(nkIdent, NIL_NODE, FPos));
    Next;
    // Inline vars may declare several names: var V, S: string; (10.3+)
    while CurKind = tkComma do
    begin
      Next;
      if CurKind = tkIdentifier then
      begin
        FB.Adopt(Result, FB.AddNode(nkIdent, NIL_NODE, FPos));
        Next;
      end
      else
        Error('name expected');
    end;
  end
  else
    Error('name expected');
  if CurKind = tkColon then
  begin
    Next;
    FB.Adopt(Result, ParseTypeRef);
  end;
  if (CurKind = tkAssign) or (AConst and (CurKind = tkEqual)) then
  begin
    Next;
    FB.Adopt(Result, ParseExpression);
  end;
  FB.SetLast(Result, FPos - 1);
end;

function TPasParser.ParseStatement: Integer;
var
  LNode, LExpr, LStart: Integer;
begin
  if not EnterGuard then
  begin
    Result := FB.AddNode(nkError, NIL_NODE, FPos);
    Next;
    LeaveGuard;
    Exit;
  end;
  try
  case CurKind of
    tkBegin:
      begin
        LNode := FB.AddNode(nkBlock, NIL_NODE, FPos);
        Next;
        ParseBlockUntil(LNode, [tkEnd]);
        Expect(tkEnd, '"end"');
        FB.SetLast(LNode, FPos - 1);
        Exit(LNode);
      end;
    tkIf:
      Exit(ParseIfStmt);
    tkCase:
      Exit(ParseCaseStmt);
    tkFor:
      Exit(ParseForStmt);
    tkWhile:
      begin
        LNode := FB.AddNode(nkWhileStmt, NIL_NODE, FPos);
        Next;
        FB.Adopt(LNode, ParseExpression);
        Expect(tkDo, '"do"');
        if CurKind = tkSemicolon then
          FB.Adopt(LNode, FB.AddNode(nkEmptyStmt, NIL_NODE, FPos))
        else
          FB.Adopt(LNode, ParseStatement);
        FB.SetLast(LNode, FPos - 1);
        Exit(LNode);
      end;
    tkRepeat:
      begin
        // 5.5.4: repeat brackets a statement list directly.
        LNode := FB.AddNode(nkRepeatStmt, NIL_NODE, FPos);
        Next;
        LExpr := FB.AddNode(nkBlock, NIL_NODE, FPos);
        ParseBlockUntil(LExpr, [tkUntil]);
        FB.SetLast(LExpr, FPos - 1);
        FB.Adopt(LNode, LExpr);
        Expect(tkUntil, '"until"');
        FB.Adopt(LNode, ParseExpression);
        FB.SetLast(LNode, FPos - 1);
        Exit(LNode);
      end;
    tkWith:
      begin
        // 5.7: multiple targets; body is the last child.
        LNode := FB.AddNode(nkWithStmt, NIL_NODE, FPos);
        Next;
        FB.Adopt(LNode, ParseExpression);
        while CurKind = tkComma do
        begin
          Next;
          FB.Adopt(LNode, ParseExpression);
        end;
        Expect(tkDo, '"do"');
        if CurKind = tkSemicolon then
          FB.Adopt(LNode, FB.AddNode(nkEmptyStmt, NIL_NODE, FPos))
        else
          FB.Adopt(LNode, ParseStatement);
        FB.SetLast(LNode, FPos - 1);
        Exit(LNode);
      end;
    tkGoto:
      begin
        LNode := FB.AddNode(nkGotoStmt, NIL_NODE, FPos);
        Next;
        if CurKind in [tkIdentifier, tkIntLiteral] then
          Next
        else
          Error('label expected');
        FB.SetLast(LNode, FPos - 1);
        Exit(LNode);
      end;
    tkRaise:
      begin
        // 18.3.1: bare re-raise or raise expr [at addr].
        LNode := FB.AddNode(nkRaiseStmt, NIL_NODE, FPos);
        Next;
        if not (CurKind in [tkSemicolon, tkEnd, tkElse, tkUntil, tkFinally,
          tkExcept, tkEndOfFile]) then
        begin
          FB.Adopt(LNode, ParseExpression);
          if IsWord('at') then
          begin
            Next;
            FB.Adopt(LNode, ParseExpression);
          end;
        end;
        FB.SetLast(LNode, FPos - 1);
        Exit(LNode);
      end;
    tkTry:
      Exit(ParseTryStmt);
    tkAsm:
      begin
        // 6.10: opaque BASM token range up to the matching end.
        LNode := FB.AddNode(nkAsmStmt, NIL_NODE, FPos);
        Next;
        while not (CurKind in [tkEnd, tkEndOfFile]) do
          Next;
        Expect(tkEnd, '"end"');
        FB.SetLast(LNode, FPos - 1);
        Exit(LNode);
      end;
    tkVar:
      Exit(ParseInlineVar(False));
    tkConst:
      Exit(ParseInlineVar(True));
    tkSemicolon, tkEnd, tkUntil, tkFinally, tkExcept, tkElse, tkEndOfFile:
      Exit(FB.AddNode(nkEmptyStmt, NIL_NODE, FPos));
    tkIdentifier:
      if PeekKind(1) = tkColon then
      begin
        // 5.6.4: label
        LNode := FB.AddNode(nkLabeledStmt, NIL_NODE, FPos);
        FB.Adopt(LNode, FB.AddNode(nkIdent, NIL_NODE, FPos));
        Next; // label
        Next; // ':'
        FB.Adopt(LNode, ParseStatement);
        FB.SetLast(LNode, FPos - 1);
        Exit(LNode);
      end;
    tkIntLiteral:
      if PeekKind(1) = tkColon then
      begin
        LNode := FB.AddNode(nkLabeledStmt, NIL_NODE, FPos);
        Next;
        Next;
        FB.Adopt(LNode, ParseStatement);
        FB.SetLast(LNode, FPos - 1);
        Exit(LNode);
      end;
  end;

  // Expression statement / assignment (5.1). LStart is captured BEFORE
  // ParseExpression runs — by the time it returns, FPos has already moved
  // past the whole LHS expression, so creating the wrapper node AT THAT
  // POINT (as this used to) gave nkAssign/nkExprStmt a FirstToken sitting
  // near the END of the statement instead of its true start (the same
  // "wrapper created after its child" trap nkMember's own dot-position
  // FirstToken is — see PasTree.Ast.pas — except THAT one is a deliberate,
  // documented, worked-around-in-consumers quirk; this one was a plain
  // bug with no consumer relying on the wrong position, caught by go-to-
  // implementation landing the cursor at the end of the first line instead
  // of its start).
  LStart := FPos;
  LExpr := ParseExpression;
  if CurKind = tkAssign then
  begin
    LNode := FB.AddNode(nkAssign, NIL_NODE, LStart);
    FB.Adopt(LNode, LExpr);
    Next;
    FB.Adopt(LNode, ParseExpression);
    FB.SetLast(LNode, FPos - 1);
    Result := LNode;
  end
  else
  begin
    LNode := FB.AddNode(nkExprStmt, NIL_NODE, LStart);
    FB.Adopt(LNode, LExpr);
    FB.SetLast(LNode, FPos - 1);
    Result := LNode;
  end;
  finally
    LeaveGuard;
  end;
end;

{ TPasParser — declarations ------------------------------------------------- }

function TPasParser.ParseQualifiedName: Integer;
var
  LNode, LChild: Integer;
begin
  Result := FB.AddNode(nkIdent, NIL_NODE, FPos);
  if CurKind = tkIdentifier then
    Next
  else
    Error('name expected');
  while CurKind = tkDot do
  begin
    LNode := FB.AddNode(nkMember, NIL_NODE, FPos);
    FB.Adopt(LNode, Result);
    Next;
    LChild := FB.AddNode(nkIdent, NIL_NODE, FPos);
    if CurKind = tkIdentifier then
      Next
    else
      Error('name expected');
    FB.Adopt(LNode, LChild);
    FB.SetLast(LNode, FPos - 1);
    Result := LNode;
  end;
end;

function TPasParser.ParseUsesClause: Integer;
var
  LItem: Integer;
begin
  // 1.2.1; program-level items may carry `in 'path'`.
  Result := FB.AddNode(nkUsesClause, NIL_NODE, FPos);
  Next; // uses
  repeat
    LItem := FB.AddNode(nkUsesItem, NIL_NODE, FPos);
    FB.Adopt(LItem, ParseQualifiedName);
    if CurKind = tkIn then
    begin
      Next;
      if CurKind = tkStringLiteral then
      begin
        FB.Adopt(LItem, FB.AddNode(nkStrLit, NIL_NODE, FPos));
        Next;
      end
      else
        Error('file path string expected');
    end;
    FB.SetLast(LItem, FPos - 1);
    FB.Adopt(Result, LItem);
    if CurKind = tkComma then
      Next
    else
      Break;
  until CurKind = tkEndOfFile;
  Expect(tkSemicolon, '";"');
  FB.SetLast(Result, FPos - 1);
end;

function TPasParser.ParseAttrGroups: Integer;
var
  LAttr: Integer;
begin
  // 19.3.2: one node collecting all adjacent [ ... ] groups.
  if CurKind <> tkLBracket then
    Exit(NIL_NODE);
  Result := FB.AddNode(nkAttrGroup, NIL_NODE, FPos);
  while CurKind = tkLBracket do
  begin
    Next;
    while (CurKind <> tkRBracket) and (CurKind <> tkEndOfFile) do
    begin
      LAttr := FB.AddNode(nkAttribute, NIL_NODE, FPos);
      FB.Adopt(LAttr, ParseTypeRef);
      if CurKind = tkLParen then
        ParseArgList(LAttr);
      FB.SetLast(LAttr, FPos - 1);
      FB.Adopt(Result, LAttr);
      if CurKind = tkComma then
        Next
      else
        Break;
    end;
    Expect(tkRBracket, '"]"');
  end;
  FB.SetLast(Result, FPos - 1);
end;

procedure TPasParser.ParseHintsOpt(ANode: Integer);
var
  LHint: Integer;
begin
  // 2.5.2 hint directives after a declaration. Each hint is its own
  // nkDirective child (mirroring ParseRoutineDirectives), so the demo
  // highlighter's AST-precise BuildWeakKeywordSpans can color it — a hint
  // consumed by plain Next with no node (the old behavior) is invisible to
  // that walk and stays uncolored (real bug: `X = 1 deprecated 'msg';`).
  while True do
  begin
    if IsWord('deprecated') then
    begin
      LHint := FB.AddNode(nkDirective, NIL_NODE, FPos);
      Next;
      if CurKind = tkStringLiteral then
      begin
        FB.Adopt(LHint, FB.AddNode(nkStrLit, NIL_NODE, FPos));
        Next;
      end;
      FB.SetLast(LHint, FPos - 1);
      FB.Adopt(ANode, LHint);
    end
    else if IsWord('platform') or IsWord('experimental') or
      (CurKind = tkLibrary) then
    begin
      LHint := FB.AddNode(nkDirective, NIL_NODE, FPos);
      Next;
      FB.SetLast(LHint, FPos - 1);
      FB.Adopt(ANode, LHint);
    end
    else
      Break;
  end;
  FB.SetLast(ANode, FPos - 1);
end;

function TPasParser.ParseTypeExpr: Integer;
var
  LNode, LExpr: Integer;
begin
  if not EnterGuard then
  begin
    Result := FB.AddNode(nkError, NIL_NODE, FPos);
    Next;
    LeaveGuard;
    Exit;
  end;
  try
  case CurKind of
    tkPacked:
      begin
        Next; // packing recorded implicitly by the token span
        Exit(ParseTypeExpr);
      end;
    tkArray:
      Exit(ParseArrayType);
    tkSet:
      begin
        LNode := FB.AddNode(nkSetType, NIL_NODE, FPos);
        Next;
        Expect(tkOf, '"of"');
        FB.Adopt(LNode, ParseTypeExpr);
        FB.SetLast(LNode, FPos - 1);
        Exit(LNode);
      end;
    tkFile:
      begin
        LNode := FB.AddNode(nkFileType, NIL_NODE, FPos);
        Next;
        if CurKind = tkOf then
        begin
          Next;
          FB.Adopt(LNode, ParseTypeExpr);
        end;
        FB.SetLast(LNode, FPos - 1);
        Exit(LNode);
      end;
    tkCaret:
      begin
        LNode := FB.AddNode(nkPointerType, NIL_NODE, FPos);
        Next;
        FB.Adopt(LNode, ParseTypeExpr);
        FB.SetLast(LNode, FPos - 1);
        Exit(LNode);
      end;
    tkClass:
      begin
        if PeekKind(1) = tkOf then
        begin
          LNode := FB.AddNode(nkClassOf, NIL_NODE, FPos);
          Next;
          Next;
          FB.Adopt(LNode, ParseTypeRef);
          FB.SetLast(LNode, FPos - 1);
          Exit(LNode);
        end;
        Exit(ParseClassLike(tkClass));
      end;
    tkInterface, tkDispinterface, tkRecord, tkObject:
      Exit(ParseClassLike(CurKind));
    tkProcedure, tkFunction:
      Exit(ParseProcTypeExpr(False));
    tkLParen:
      Exit(ParseEnumType);
    tkString:
      begin
        if PeekKind(1) = tkLBracket then
        begin
          LNode := FB.AddNode(nkStringType, NIL_NODE, FPos);
          Next;
          Next;
          FB.Adopt(LNode, ParseExpression);
          Expect(tkRBracket, '"]"');
          FB.SetLast(LNode, FPos - 1);
          Exit(LNode);
        end;
        LNode := FB.AddNode(nkIdent, NIL_NODE, FPos);
        Next;
        Exit(LNode);
      end;
    tkIdentifier:
      begin
        if IsWord('reference') and (PeekKind(1) = tkTo) and
          (PeekKind(2) in [tkProcedure, tkFunction]) then
        begin
          MarkContextKeyword; // color 'reference' (lexed as an identifier)
          Next; // reference
          Next; // to
          Exit(ParseProcTypeExpr(True));
        end;
        // Type-context: generics always bind (16.3); may be a subrange lo.
        LExpr := ParseTypeRef;
        // Constant-expression continuations in ordinal positions:
        // array[Ord(reA)..Ord(reB)] — allow selector chains (calls etc.).
        if CurKind in [tkLParen, tkLBracket, tkCaret] then
          LExpr := ParseSelectors(LExpr);
        if CurKind = tkDotDot then
        begin
          LNode := FB.AddNode(nkSubrange, NIL_NODE, FPos);
          FB.Adopt(LNode, LExpr);
          Next;
          FB.Adopt(LNode, ParseExpression);
          FB.SetLast(LNode, FPos - 1);
          Exit(LNode);
        end;
        Exit(LExpr);
      end;
  else
    // Constant-expression subrange: -1..1, $FF..$100, Ord(x)..Ord(y)...
    LExpr := ParseExpression;
    if CurKind = tkDotDot then
    begin
      LNode := FB.AddNode(nkSubrange, NIL_NODE, FPos);
      FB.Adopt(LNode, LExpr);
      Next;
      FB.Adopt(LNode, ParseExpression);
      FB.SetLast(LNode, FPos - 1);
      Exit(LNode);
    end;
    Result := LExpr;
  end;
  finally
    LeaveGuard;
  end;
end;

function TPasParser.ParseEnumType: Integer;
var
  LValue: Integer;
begin
  // 2.2.4: ( name [= const], ... )
  Result := FB.AddNode(nkEnumType, NIL_NODE, FPos);
  Next; // (
  while (CurKind <> tkRParen) and (CurKind <> tkEndOfFile) do
  begin
    LValue := FB.AddNode(nkEnumValue, NIL_NODE, FPos);
    if CurKind = tkIdentifier then
    begin
      FB.Adopt(LValue, FB.AddNode(nkIdent, NIL_NODE, FPos));
      Next;
    end
    else
    begin
      Error('enum element expected');
      Next;
    end;
    if CurKind = tkEqual then
    begin
      Next;
      FB.Adopt(LValue, ParseExpression);
    end;
    FB.SetLast(LValue, FPos - 1);
    FB.Adopt(Result, LValue);
    if CurKind = tkComma then
      Next
    else
      Break;
  end;
  Expect(tkRParen, '")"');
  FB.SetLast(Result, FPos - 1);
end;

function TPasParser.ParseArrayType: Integer;
begin
  // 8.1/8.2: array [dims] of (const | T)
  Result := FB.AddNode(nkArrayType, NIL_NODE, FPos);
  Next; // array
  if CurKind = tkLBracket then
  begin
    Next;
    while (CurKind <> tkRBracket) and (CurKind <> tkEndOfFile) do
    begin
      FB.Adopt(Result, ParseTypeExpr);
      if CurKind = tkComma then
        Next
      else
        Break;
    end;
    Expect(tkRBracket, '"]"');
  end;
  Expect(tkOf, '"of"');
  if CurKind = tkConst then
  begin
    FB.SetAux(Result, 1); // array of const (6.2.6)
    Next;
  end
  else
    FB.Adopt(Result, ParseTypeExpr);
  FB.SetLast(Result, FPos - 1);
end;

function TPasParser.ParseProcTypeExpr(ARefTo: Boolean): Integer;
begin
  // 6.6.1 procedural types; of object / reference to variants.
  Result := FB.AddNode(nkProcType, NIL_NODE, FPos);
  if ARefTo then
    FB.SetAux(Result, 2);
  Next; // procedure/function
  if CurKind = tkLParen then
    FB.Adopt(Result, ParseParamList(tkRParen));
  if CurKind = tkColon then
  begin
    Next;
    FB.Adopt(Result, ParseTypeExpr);
  end;
  if (CurKind = tkOf) and (PeekKind(1) = tkObject) then
  begin
    FB.SetAux(Result, 1);
    Next;
    Next;
  end;
  // Inline calling convention without a separating semicolon:
  // TFoo = procedure stdcall;
  while IsDirectiveWord do
    Next;
  FB.SetLast(Result, FPos - 1);
end;

function TPasParser.ParseClassLike(AHeadKind: TPasTokenKind): Integer;
var
  LKind: TPasNodeKind;
  LIsHelper: Boolean;
begin
  case AHeadKind of
    tkRecord: LKind := nkRecordType;
    tkInterface, tkDispinterface: LKind := nkInterfaceType;
    tkObject: LKind := nkObjectType;
  else
    LKind := nkClassType;
  end;
  Result := FB.AddNode(LKind, NIL_NODE, FPos);
  if AHeadKind = tkDispinterface then
    FB.SetAux(Result, 1);
  Next; // head keyword
  // class abstract / class sealed (context keywords, lexed as identifiers)
  while IsWord('abstract') or IsWord('sealed') do
  begin
    MarkContextKeyword;   // color 'abstract' / 'sealed'
    Next;
  end;
  LIsHelper := IsWord('helper');
  if LIsHelper then
  begin
    FB.SetKind(Result, nkHelperType);
    if AHeadKind = tkRecord then
      FB.SetAux(Result, 1);
    MarkContextKeyword;   // color 'helper'
    Next; // helper
  end;
  // Forward declaration: class; / interface;
  if (CurKind = tkSemicolon) and not LIsHelper then
  begin
    FB.SetAux(Result, 1);
    FB.SetLast(Result, FPos - 1);
    Exit;
  end;
  if CurKind = tkLParen then
  begin
    Next;
    while (CurKind <> tkRParen) and (CurKind <> tkEndOfFile) do
    begin
      FB.Adopt(Result, ParseTypeRef);
      if CurKind = tkComma then
        Next
      else
        Break;
    end;
    Expect(tkRParen, '")"');
  end;
  if LIsHelper then
  begin
    // NB: `for` here is the reserved word tkFor, not an identifier.
    if CurKind = tkFor then
      Next
    else
      Error('"for" expected');
    FB.Adopt(Result, ParseTypeRef);
  end;
  // Ancestor-only shorthand: TFoo = class(TBar);
  if CurKind = tkSemicolon then
  begin
    FB.SetLast(Result, FPos - 1);
    Exit;
  end;
  // Interface GUID (14.1.1).
  if (AHeadKind in [tkInterface, tkDispinterface]) and
     (CurKind = tkLBracket) and (PeekKind(1) = tkStringLiteral) then
  begin
    FB.Adopt(Result, FB.AddNode(nkGuid, NIL_NODE, FPos));
    Next;
    Next;
    Expect(tkRBracket, '"]"');
  end;
  ParseMemberList(Result);
  Expect(tkEnd, '"end"');
  // Semi-documented alignment clause: `record ... end align 16;`
  // (System.SysUtils.pas). The operand is a constant expression.
  if IsWord('align') then
  begin
    Next;
    FB.Adopt(Result, ParseExpression);
  end;
  ParseHintsOpt(Result);
  FB.SetLast(Result, FPos - 1);
end;

procedure TPasParser.ParseMemberList(AOwner: Integer);
var
  LVis, LNode: Integer;
  LStrict: Boolean;

  function VisLevel(const AWord: string): Integer;
  begin
    if SameText(AWord, 'private') then Result := 1
    else if SameText(AWord, 'protected') then Result := 2
    else if SameText(AWord, 'public') then Result := 3
    else if SameText(AWord, 'published') then Result := 4
    else if SameText(AWord, 'automated') then Result := 5
    else Result := 0;
  end;

begin
  while not (CurKind in [tkEnd, tkEndOfFile]) do
  begin
    // Visibility sections (11.2.1), incl. strict and legacy automated.
    // A bare visibility word in member position IS a section marker: a
    // field genuinely named `private` must be written `&private`, and the
    // &-escaped token text starts with '&', so SameText misses it — the
    // disambiguation falls out of the lexer (B.3).
    LStrict := IsWord('strict') and (FPos < FLast) and
      (VisLevel(FSrc.VisibleText(FPos + 1)) in [1, 2]);
    if LStrict or ((CurKind = tkIdentifier) and (VisLevel(CurText) > 0)) then
    begin
      LVis := FB.AddNode(nkVisibility, NIL_NODE, FPos);
      if LStrict then
      begin
        FB.AddFlag(LVis, nfNegated); // reuse flag slot: strict marker
        Next;
      end;
      FB.SetAux(LVis, VisLevel(CurText));
      Next;
      FB.SetLast(LVis, FPos - 1);
      FB.Adopt(AOwner, LVis);
      Continue;
    end;

    case CurKind of
      tkSemicolon:
        Next;
      tkLBracket:
        begin
          LNode := ParseAttrGroups;
          if LNode <> NIL_NODE then
            FB.Adopt(AOwner, LNode);
        end;
      tkClass:
        begin
          // class var/threadvar/method/property/operator (15.x)
          case PeekKind(1) of
            tkVar:
              begin
                Next;
                Next;
                FB.Adopt(AOwner, ParseVarSection(True));
              end;
            tkThreadvar:
              begin
                Next;
                Next;
                FB.Adopt(AOwner, ParseVarSection(True));
              end;
            tkProcedure, tkFunction, tkConstructor, tkDestructor:
              begin
                Next;
                FB.Adopt(AOwner, ParseRoutine(True, False));
              end;
            tkProperty:
              begin
                Next;
                FB.Adopt(AOwner, ParseProperty(True));
              end;
          else
            if (PeekKind(1) = tkIdentifier) and
               SameText(FSrc.VisibleText(FPos + 1), 'operator') then
            begin
              Next;
              FB.Adopt(AOwner, ParseRoutine(True, False));
            end
            else
            begin
              Error('class member expected');
              Next;
            end;
          end;
        end;
      tkProcedure, tkFunction, tkConstructor, tkDestructor:
        FB.Adopt(AOwner, ParseRoutine(False, False));
      tkProperty:
        FB.Adopt(AOwner, ParseProperty(False));
      tkType:
        FB.Adopt(AOwner, ParseTypeSection);
      tkConst, tkResourcestring:
        FB.Adopt(AOwner, ParseConstSection);
      tkVar, tkThreadvar:
        begin
          Next; // section marker inside a class body
          FB.Adopt(AOwner, ParseVarSection(False));
        end;
      tkCase:
        ParseVariantPart(AOwner);
      tkIdentifier, tkString:
        // field declaration(s)
        ParseFieldList(AOwner, [tkEnd, tkCase]);
    else
      Error('member declaration expected, found "' + CurText + '"');
      Next;
    end;
  end;
end;

procedure TPasParser.ParseFieldList(AOwner: Integer;
  const ATerminators: array of TPasTokenKind);
var
  LDecl: Integer;
begin
  // identList : Type [hints] ; ... — stops before terminators or non-fields.
  while CurKind = tkIdentifier do
  begin
    LDecl := FB.AddNode(nkVarDecl, NIL_NODE, FPos);
    FB.Adopt(LDecl, FB.AddNode(nkIdent, NIL_NODE, FPos));
    Next;
    while CurKind = tkComma do
    begin
      Next;
      if CurKind = tkIdentifier then
      begin
        FB.Adopt(LDecl, FB.AddNode(nkIdent, NIL_NODE, FPos));
        Next;
      end
      else
        Error('field name expected');
    end;
    Expect(tkColon, '":"');
    FB.Adopt(LDecl, ParseTypeExpr);
    ParseHintsOpt(LDecl);
    FB.SetLast(LDecl, FPos - 1);
    FB.Adopt(AOwner, LDecl);
    if CurKind = tkSemicolon then
      Next
    else
      Break;
    ConsumeTrailingDirectives;
    if AtAny(ATerminators) then
      Break;
    // Non-field successor ends the field run (methods, visibility, ...).
    if not (CurKind = tkIdentifier) then
      Break;
    // A visibility word starts a new section, not a field (see the note in
    // ParseMemberList: escaped &private would not SameText-match).
    if SameText(CurText, 'private') or SameText(CurText, 'protected') or
       SameText(CurText, 'public') or SameText(CurText, 'published') or
       SameText(CurText, 'strict') or SameText(CurText, 'automated') then
      Break;
  end;
end;

procedure TPasParser.ParseVariantPart(AOwner: Integer);
var
  LPart, LBranch: Integer;
begin
  // 9.1.3: case [tag:] OrdinalType of const,...: ( fields [variant] ); ...
  LPart := FB.AddNode(nkVariantPart, NIL_NODE, FPos);
  Next; // case
  if (CurKind = tkIdentifier) and (PeekKind(1) = tkColon) then
  begin
    FB.Adopt(LPart, FB.AddNode(nkIdent, NIL_NODE, FPos));
    Next;
    Next;
  end;
  FB.Adopt(LPart, ParseTypeRef);
  Expect(tkOf, '"of"');
  while not (CurKind in [tkEnd, tkRParen, tkEndOfFile]) do
  begin
    LBranch := FB.AddNode(nkVariantBranch, NIL_NODE, FPos);
    // labels
    repeat
      FB.Adopt(LBranch, ParseExpression);
      if CurKind = tkComma then
        Next
      else
        Break;
    until False;
    Expect(tkColon, '":"');
    Expect(tkLParen, '"("');
    while not (CurKind in [tkRParen, tkEndOfFile]) do
      if CurKind = tkCase then
        ParseVariantPart(LBranch)
      else if CurKind = tkIdentifier then
        ParseFieldList(LBranch, [tkRParen, tkCase])
      else
      begin
        Error('field expected');
        Next;
      end;
    Expect(tkRParen, '")"');
    FB.SetLast(LBranch, FPos - 1);
    FB.Adopt(LPart, LBranch);
    if CurKind = tkSemicolon then
      Next
    else
      Break;
  end;
  FB.SetLast(LPart, FPos - 1);
  FB.Adopt(AOwner, LPart);
end;

function TPasParser.ParseGenericParamsOpt: Integer;
var
  LParam, LCon: Integer;
begin
  // 16.1/16.4: <T; TKey, TValue: constraints>
  if CurKind <> tkLess then
    Exit(NIL_NODE);
  Result := FB.AddNode(nkGenericParams, NIL_NODE, FPos);
  Next;
  while (CurKind <> tkGreater) and (CurKind <> tkEndOfFile) do
  begin
    LParam := FB.AddNode(nkGenericParam, NIL_NODE, FPos);
    // A "parameter" here is a TypeRef, not a bare ident: implementation
    // headers of closed generics use type arguments — e.g. the method
    // resolution `function IEnumerator<string>.GetCurrent = ...`
    // (System.IOUtils.pas) — and TypeRef also covers plain T.
    FB.Adopt(LParam, ParseTypeRef);
    while CurKind = tkComma do
    begin
      Next;
      FB.Adopt(LParam, ParseTypeRef);
    end;
    if CurKind = tkColon then
    begin
      Next;
      repeat
        LCon := FB.AddNode(nkConstraint, NIL_NODE, FPos);
        case CurKind of
          tkClass, tkRecord, tkConstructor:
            Next;
        else
          FB.Adopt(LCon, ParseTypeRef);
        end;
        FB.SetLast(LCon, FPos - 1);
        FB.Adopt(LParam, LCon);
        if CurKind = tkComma then
          Next
        else
          Break;
      until False;
    end;
    FB.SetLast(LParam, FPos - 1);
    FB.Adopt(Result, LParam);
    if CurKind = tkSemicolon then
      Next
    else
      Break;
  end;
  Expect(tkGreater, '">"');
  FB.SetLast(Result, FPos - 1);
end;

function TPasParser.ParseParamList(AClose: TPasTokenKind): Integer;
var
  LParam, LAttrs: Integer;
begin
  // 6.2: [attrs] [var|const|out] names [: [array of] T] [= default]
  Result := FB.AddNode(nkParams, NIL_NODE, FPos);
  Next; // ( or [
  while (CurKind <> AClose) and (CurKind <> tkEndOfFile) do
  begin
    LParam := FB.AddNode(nkParam, NIL_NODE, FPos);
    LAttrs := ParseAttrGroups;
    if LAttrs <> NIL_NODE then
      FB.Adopt(LParam, LAttrs);
    if CurKind in [tkVar, tkConst] then
    begin
      Next;
      LAttrs := ParseAttrGroups; // const [Ref] X (6.2.3)
      if LAttrs <> NIL_NODE then
        FB.Adopt(LParam, LAttrs);
    end
    else if IsWord('out') then
      Next;
    if CurKind = tkIdentifier then
    begin
      FB.Adopt(LParam, FB.AddNode(nkIdent, NIL_NODE, FPos));
      Next;
      while CurKind = tkComma do
      begin
        Next;
        // Attributes may precede EACH name in the list:
        // const [REF] CLSID, [REF] IID: TGUID  (Datasnap.DSIntf.pas)
        LAttrs := ParseAttrGroups;
        if LAttrs <> NIL_NODE then
          FB.Adopt(LParam, LAttrs);
        if CurKind = tkIdentifier then
        begin
          FB.Adopt(LParam, FB.AddNode(nkIdent, NIL_NODE, FPos));
          Next;
        end;
      end;
    end
    else
      Error('parameter name expected');
    if CurKind = tkColon then
    begin
      Next;
      FB.Adopt(LParam, ParseTypeExpr);
      if CurKind = tkEqual then
      begin
        Next;
        FB.Adopt(LParam, ParseExpression);
      end;
    end;
    FB.SetLast(LParam, FPos - 1);
    FB.Adopt(Result, LParam);
    if CurKind = tkSemicolon then
      Next
    else
      Break;
  end;
  Expect(AClose, 'closing bracket');
  FB.SetLast(Result, FPos - 1);
end;

function TPasParser.IsDirectiveWord: Boolean;
var
  LWord: string;
begin
  if CurKind = tkInline then
    Exit(True);
  if CurKind = tkLibrary then
    Exit(True);
  if CurKind <> tkIdentifier then
    Exit(False);
  for LWord in PasTree.Types.ROUTINE_DIRECTIVE_WORDS do
    if SameText(CurText, LWord) then
      Exit(True);
  Result := False;
end;

function TPasParser.IsVisibilityWord: Boolean;
var
  LWord: string;
begin
  // Nested const/type/var sections inside a class body end where the next
  // visibility section starts (11.2.1). &-escaped names don't match (B.3).
  if CurKind <> tkIdentifier then
    Exit(False);
  for LWord in PasTree.Types.VISIBILITY_WORDS do
    if SameText(CurText, LWord) then
      Exit(True);
  Result := False;
end;

// A CONTEXT keyword (reference / operator / ...) is lexed as an identifier,
// not a reserved word, so nothing colors it as a keyword. Emit a standalone
// nkDirective over the current single token purely so the editor highlighter
// treats it as one (BuildWeakKeywordSpans marks the span of every nkDirective/
// nkVisibility/nkPropSpec node). The node is intentionally an ORPHAN — never
// adopted into the tree: it carries no structure any consumer needs, and
// staying out of every child chain leaves sema, Nav, Dump, JSON and the
// routine/type name-finding logic completely unaffected (they all walk from
// the root via child links; only the highlighter's flat all-nodes walk sees
// it). Call it BEFORE consuming the token, while FPos still points at it.
procedure TPasParser.MarkContextKeyword;
begin
  FB.AddNode(nkDirective, NIL_NODE, FPos);   // FirstToken = LastToken = FPos
end;

procedure TPasParser.ConsumeTrailingDirectives;

  function IsDirectiveWordAt(AIdx: Integer): Boolean;
  var
    LSave: Integer;
  begin
    LSave := FPos;
    FPos := AIdx;
    Result := IsDirectiveWord;
    FPos := LSave;
  end;

var
  LProbe: Integer;
begin
  // Post-semicolon directives after procedural-type declarations. Runs of
  // several directives without separators are legal:
  //   TFn = function(...): X; stdcall;
  //   curl_formadd: function(...): CURLFORMcode; cdecl varargs;
  // The run must terminate with ';' — otherwise the word is the next
  // declaration's name (e.g. a variable named `index`), and we leave it.
  while IsDirectiveWord do
  begin
    LProbe := FPos;
    while (LProbe <= FLast) and IsDirectiveWordAt(LProbe) do
      Inc(LProbe);
    if (LProbe <= FLast) and
       (FSrc.VisibleToken(LProbe).Kind = tkStringLiteral) then
      Inc(LProbe);
    // Initialized procedural-type variables put the initializer AFTER the
    // convention: `X: procedure; cdecl = nil;` (IdSSLOpenSSLHeaders.pas).
    if (LProbe <= FLast) and (FSrc.VisibleToken(LProbe).Kind = tkEqual) then
    begin
      while FPos < LProbe do
        Next;
      Next; // '='
      ParseConstInitializer(True);
      Expect(tkSemicolon, '";"');
      Continue;
    end;
    if (LProbe > FLast) or (FSrc.VisibleToken(LProbe).Kind <> tkSemicolon)
    then
      Break;
    while FPos < LProbe do
      Next;
    Expect(tkSemicolon, '";"');
  end;
end;

function TPasParser.ParseRoutineDirectives(ARoutine: Integer): Boolean;
var
  LDir: Integer;
  LIsExternal, LIsForward, LIsAbstract: Boolean;
begin
  // 6.x: `; directive`* — returns True when the routine has no body.
  LIsExternal := False;
  LIsForward := False;
  LIsAbstract := False;
  while IsDirectiveWord do
  begin
    LDir := FB.AddNode(nkDirective, NIL_NODE, FPos);
    if IsWord('external') then
    begin
      LIsExternal := True;
      Next;
      // external [lib] [name expr | index expr | dependency e,e | delayed]
      // The clause stops at ';' OR at anything that starts the next
      // declaration — dcc tolerates a missing terminator:
      // `function F; external shell32 name 'X'` + newline + `function ...`
      // (user corpus, verified against dcc64).
      while not (CurKind in [tkSemicolon, tkEndOfFile, tkFunction,
        tkProcedure, tkConstructor, tkDestructor, tkClass, tkType, tkVar,
        tkConst, tkThreadvar, tkLabel, tkExports, tkBegin, tkEnd,
        tkImplementation, tkInitialization, tkFinalization]) do
      begin
        if IsWord('name') or IsWord('index') then
        begin
          Next;
          FB.Adopt(LDir, ParseExpression);
        end
        else if IsWord('dependency') then
        begin
          Next;
          FB.Adopt(LDir, ParseExpression);
          while CurKind = tkComma do
          begin
            Next;
            FB.Adopt(LDir, ParseExpression);
          end;
        end
        else if IsWord('delayed') then
          Next
        else
          FB.Adopt(LDir, ParseExpression);
      end;
    end
    else if IsWord('message') or IsWord('dispid') then
    begin
      Next;
      FB.Adopt(LDir, ParseExpression);
    end
    else if IsWord('deprecated') then
    begin
      Next;
      if CurKind = tkStringLiteral then
        Next;
    end
    else
    begin
      if IsWord('forward') then
        LIsForward := True
      else if IsWord('abstract') then
        LIsAbstract := True;
      Next;
    end;
    FB.SetLast(LDir, FPos - 1);
    FB.Adopt(ARoutine, LDir);
    if CurKind = tkSemicolon then
      Next
    else if not IsDirectiveWord then
      // dcc tolerates a missing ';' after the LAST directive in a run —
      // both between directives (`platform deprecated`) and before the
      // next declaration or body (`procedure P; platform deprecated`
      // followed directly by `procedure`/`begin`; user corpus, verified).
      Break;
  end;
  Result := LIsExternal or LIsForward or LIsAbstract;
end;

function TPasParser.ParseRoutine(AClassMethod, AAllowBody: Boolean): Integer;
var
  LSeg, LGen, LRes: Integer;
  LIsOperator: Boolean;
begin
  // 6.1: [class] procedure|function|constructor|destructor|operator
  Result := FB.AddNode(nkRoutine, NIL_NODE, FPos);
  if AClassMethod then
    FB.SetAux(Result, 1);
  LIsOperator := IsWord('operator');
  if LIsOperator then
    MarkContextKeyword; // color 'operator' (lexed as an identifier)
  Next; // routine keyword (or 'operator' identifier)
  FRoutineNameVis := FPos;
  // Name: segments with optional generic params (impl headers, 16.3).
  // Operators may be named by reserved words: class operator In(...)
  // (FMX.Graphics.pas).
  if LIsOperator and IsKeyword(CurKind) then
  begin
    FB.Adopt(Result, FB.AddNode(nkIdent, NIL_NODE, FPos));
    Next;
  end
  else if CurKind = tkIdentifier then
  begin
    LSeg := FB.AddNode(nkIdent, NIL_NODE, FPos);
    Next;
    FB.Adopt(Result, LSeg);
    LGen := ParseGenericParamsOpt;
    if LGen <> NIL_NODE then
      FB.Adopt(Result, LGen);
    while CurKind = tkDot do
    begin
      Next;
      // Operator implementations may end in a reserved word:
      // class operator TFontStyleExt.In(...) (FMX.Graphics.pas).
      if (CurKind = tkIdentifier) or (LIsOperator and IsKeyword(CurKind))
      then
      begin
        FB.Adopt(Result, FB.AddNode(nkIdent, NIL_NODE, FPos));
        Next;
        LGen := ParseGenericParamsOpt;
        if LGen <> NIL_NODE then
          FB.Adopt(Result, LGen);
      end
      else
      begin
        Error('name expected');
        Break;
      end;
    end;
  end
  else
    Error('routine name expected');
  // Method resolution clause (14.2.2): function IFoo.M = Impl;
  if CurKind = tkEqual then
  begin
    FB.SetKind(Result, nkMethodResolution);
    Next;
    if CurKind = tkIdentifier then
    begin
      FB.Adopt(Result, FB.AddNode(nkIdent, NIL_NODE, FPos));
      Next;
    end
    else
      Error('method name expected');
    Expect(tkSemicolon, '";"');
    FB.SetLast(Result, FPos - 1);
    Exit;
  end;
  if CurKind = tkLParen then
    FB.Adopt(Result, ParseParamList(tkRParen));
  if CurKind = tkColon then
  begin
    Next;
    LRes := ParseTypeExpr;
    FB.Adopt(Result, LRes);
  end;
  // Calling convention without a separating semicolon:
  // function Foo(...): Bool stdcall;  (System.SysUtils.pas)
  while IsDirectiveWord and (PeekKind(1) = tkSemicolon) do
    Next;
  Expect(tkSemicolon, '";"');
  if not ParseRoutineDirectives(Result) then
    if AAllowBody then
    begin
      FB.Adopt(Result, ParseRoutineBody);
      Expect(tkSemicolon, '";"');
    end;
  FB.SetLast(Result, FPos - 1);
end;

function TPasParser.ParseRoutineBody: Integer;
var
  LBlock: Integer;
begin
  // 6.x + B.12: local declarations then begin..end or asm..end.
  // tkEnd in the terminators bounds the damage when a header unexpectedly
  // has no body (misalignment stops at the enclosing end instead of
  // swallowing the rest of the unit).
  Result := FB.AddNode(nkRoutineBody, NIL_NODE, FPos);
  ParseDeclSections(Result, True, [tkBegin, tkAsm, tkEnd]);
  if CurKind = tkAsm then
  begin
    LBlock := FB.AddNode(nkAsmStmt, NIL_NODE, FPos);
    Next;
    while not (CurKind in [tkEnd, tkEndOfFile]) do
      Next;
    Expect(tkEnd, '"end"');
    FB.SetLast(LBlock, FPos - 1);
    FB.Adopt(Result, LBlock);
  end
  else if CurKind = tkBegin then
  begin
    LBlock := FB.AddNode(nkBlock, NIL_NODE, FPos);
    Next;
    ParseBlockUntil(LBlock, [tkEnd]);
    Expect(tkEnd, '"end"');
    FB.SetLast(LBlock, FPos - 1);
    FB.Adopt(Result, LBlock);
  end
  else
    Error('"begin" expected (routine ' +
      FSrc.VisibleText(FRoutineNameVis) + ')');
  FB.SetLast(Result, FPos - 1);
end;

function TPasParser.ParseProperty(AClassProp: Boolean): Integer;
var
  LSpec: Integer;
  LArgless: Boolean;
begin
  // 13.1: property Name[params]: T specifiers; [default;]
  Result := FB.AddNode(nkPropertyDecl, NIL_NODE, FPos);
  if AClassProp then
    FB.SetAux(Result, 1);
  Next; // property
  if CurKind = tkIdentifier then
  begin
    FB.Adopt(Result, FB.AddNode(nkIdent, NIL_NODE, FPos));
    Next;
  end
  else
    Error('property name expected');
  if CurKind = tkLBracket then
    FB.Adopt(Result, ParseParamList(tkRBracket));
  if CurKind = tkColon then
  begin
    Next;
    FB.Adopt(Result, ParseTypeExpr);
  end;
  // Specifiers until ';' (13.1.x): read write index stored default
  // nodefault implements readonly writeonly dispid.
  while not (CurKind in [tkSemicolon, tkEndOfFile]) do
  begin
    if CurKind = tkIdentifier then
    begin
      LSpec := FB.AddNode(nkPropSpec, NIL_NODE, FPos);
      LArgless := SameText(CurText, 'nodefault') or
        SameText(CurText, 'readonly') or SameText(CurText, 'writeonly');
      Next;
      if not LArgless and (CurKind <> tkSemicolon) then
      begin
        FB.Adopt(LSpec, ParseExpression);
        // implements I1, I2 (14.4.1)
        while CurKind = tkComma do
        begin
          Next;
          FB.Adopt(LSpec, ParseExpression);
        end;
      end;
      FB.SetLast(LSpec, FPos - 1);
      FB.Adopt(Result, LSpec);
    end
    else
    begin
      Error('property specifier expected');
      Next;
    end;
  end;
  Expect(tkSemicolon, '";"');
  // Trailing `default;` = default array property (13.1.4).
  if IsWord('default') and (PeekKind(1) = tkSemicolon) then
  begin
    LSpec := FB.AddNode(nkPropSpec, NIL_NODE, FPos);
    Next;
    Next;
    FB.SetLast(LSpec, FPos - 1);
    FB.Adopt(Result, LSpec);
  end;
  ParseHintsOpt(Result);
  if CurKind = tkSemicolon then
    Next;
  FB.SetLast(Result, FPos - 1);
end;

function TPasParser.ParseConstInitializer(AHasType: Boolean): Integer;
var
  LField: Integer;

  function LooksLikeAggregate: Boolean;
  var
    LIdx, LDepth, LSteps: Integer;
    LKind: TPasTokenKind;
  begin
    // Distinguishes `(1, 2, 3)` / `(X: 0; Y: 1)` aggregates from plain
    // parenthesised const expressions like ((1.0/$10000) / $10000):
    // an aggregate has ',' ';' or ':' at nesting depth 1.
    Result := False;
    LIdx := FPos + 1;
    LDepth := 1;
    LSteps := 0;
    while (LIdx <= FLast) and (LSteps < 4096) do
    begin
      LKind := FSrc.VisibleToken(LIdx).Kind;
      // First-inner-token checks must run BEFORE the depth bookkeeping:
      // '()' empty aggregate closes depth immediately (OleControls), and
      // '((' opens a single-element nested aggregate (test_xpParse).
      if (LIdx = FPos + 1) and (LKind in [tkLParen, tkRParen]) then
        Exit(True);
      case LKind of
        tkLParen, tkLBracket:
          Inc(LDepth);
        tkRParen, tkRBracket:
          begin
            Dec(LDepth);
            if LDepth = 0 then
              Exit(False);
          end;
        tkComma, tkSemicolon, tkColon:
          if LDepth = 1 then
            Exit(True);
      end;
      Inc(LIdx);
      Inc(LSteps);
    end;
  end;

begin
  if not EnterGuard then
  begin
    Result := FB.AddNode(nkError, NIL_NODE, FPos);
    Next;
    LeaveGuard;
    Exit;
  end;
  try
  // 3.2.2: typed constants may use ( ... ) aggregates; only a typed const
  // can be an aggregate, so '(' after an untyped '=' is a paren expr —
  // and even for typed consts the parens may be a plain expression.
  if AHasType and (CurKind = tkLParen) and LooksLikeAggregate then
  begin
    Result := FB.AddNode(nkAggregate, NIL_NODE, FPos);
    Next;
    while not (CurKind in [tkRParen, tkEndOfFile]) do
    begin
      if (CurKind = tkIdentifier) and (PeekKind(1) = tkColon) then
      begin
        LField := FB.AddNode(nkAggregateField, NIL_NODE, FPos);
        FB.Adopt(LField, FB.AddNode(nkIdent, NIL_NODE, FPos));
        Next;
        Next;
        FB.Adopt(LField, ParseConstInitializer(True));
        FB.SetLast(LField, FPos - 1);
        FB.Adopt(Result, LField);
      end
      else if CurKind = tkLParen then
        // Nested aggregates are unambiguous in element position.
        FB.Adopt(Result, ParseConstInitializer(True))
      else
        FB.Adopt(Result, ParseExpression);
      if CurKind in [tkComma, tkSemicolon] then
        Next
      else
        Break;
    end;
    Expect(tkRParen, '")"');
    FB.SetLast(Result, FPos - 1);
  end
  else
    Result := ParseExpression;
  finally
    LeaveGuard;
  end;
end;

function TPasParser.ParseTypeSection: Integer;
var
  LDecl, LGen, LAttrs: Integer;
begin
  // 2.x: type name<...> = [type] TypeExpr; ...
  Result := FB.AddNode(nkTypeSec, NIL_NODE, FPos);
  Next; // type
  while (CurKind = tkIdentifier) or (CurKind = tkLBracket) do
  begin
    if IsVisibilityWord then
      Break;
    LAttrs := ParseAttrGroups;
    if CurKind <> tkIdentifier then
    begin
      if LAttrs <> NIL_NODE then
        FB.Adopt(Result, LAttrs);
      Break;
    end;
    LDecl := FB.AddNode(nkTypeDecl, NIL_NODE, FPos);
    if LAttrs <> NIL_NODE then
      FB.Adopt(LDecl, LAttrs);
    FB.Adopt(LDecl, FB.AddNode(nkIdent, NIL_NODE, FPos));
    Next;
    LGen := ParseGenericParamsOpt;
    if LGen <> NIL_NODE then
      FB.Adopt(LDecl, LGen);
    Expect(tkEqual, '"="');
    if CurKind = tkType then
    begin
      // Distinct alias: T = type Base (2.5.1).
      FB.SetAux(LDecl, 1);
      Next;
    end;
    FB.Adopt(LDecl, ParseTypeExpr);
    ParseHintsOpt(LDecl);
    FB.SetLast(LDecl, FPos - 1);
    FB.Adopt(Result, LDecl);
    Expect(tkSemicolon, '";"');
    ConsumeTrailingDirectives;
    if IsVisibilityWord then
      Break;
  end;
  FB.SetLast(Result, FPos - 1);
end;

function TPasParser.ParseConstSection: Integer;
var
  LDecl, LAttrs: Integer;
  LHasType: Boolean;
begin
  // 3.2: const/resourcestring entries.
  Result := FB.AddNode(nkConstSec, NIL_NODE, FPos);
  Next;
  while (CurKind = tkIdentifier) or (CurKind = tkLBracket) do
  begin
    if IsVisibilityWord then
      Break;
    LAttrs := ParseAttrGroups;
    if CurKind <> tkIdentifier then
      Break;
    LDecl := FB.AddNode(nkConstDecl, NIL_NODE, FPos);
    if LAttrs <> NIL_NODE then
      FB.Adopt(LDecl, LAttrs);
    FB.Adopt(LDecl, FB.AddNode(nkIdent, NIL_NODE, FPos));
    Next;
    LHasType := CurKind = tkColon;
    if LHasType then
    begin
      Next;
      FB.Adopt(LDecl, ParseTypeExpr);
    end;
    Expect(tkEqual, '"="');
    FB.Adopt(LDecl, ParseConstInitializer(LHasType));
    ParseHintsOpt(LDecl);
    FB.SetLast(LDecl, FPos - 1);
    FB.Adopt(Result, LDecl);
    Expect(tkSemicolon, '";"');
    ConsumeTrailingDirectives;
    if IsVisibilityWord then
      Break;
  end;
  FB.SetLast(Result, FPos - 1);
end;

function TPasParser.ParseVarSection(AClassVar: Boolean): Integer;
var
  LDecl, LAttrs: Integer;
begin
  // 3.1: var/threadvar entries; also used for class var sections.
  Result := FB.AddNode(nkVarSec, NIL_NODE, FPos);
  if AClassVar then
    FB.SetAux(Result, 1)
  else if CurKind in [tkVar, tkThreadvar] then
    Next;
  while (CurKind = tkIdentifier) or (CurKind = tkLBracket) do
  begin
    if IsVisibilityWord then
      Break;
    LAttrs := ParseAttrGroups;
    if CurKind <> tkIdentifier then
      Break;
    LDecl := FB.AddNode(nkVarDecl, NIL_NODE, FPos);
    if LAttrs <> NIL_NODE then
      FB.Adopt(LDecl, LAttrs);
    FB.Adopt(LDecl, FB.AddNode(nkIdent, NIL_NODE, FPos));
    Next;
    while CurKind = tkComma do
    begin
      Next;
      if CurKind = tkIdentifier then
      begin
        FB.Adopt(LDecl, FB.AddNode(nkIdent, NIL_NODE, FPos));
        Next;
      end
      else
        Error('name expected');
    end;
    Expect(tkColon, '":"');
    FB.Adopt(LDecl, ParseTypeExpr);
    // Hints may sit BETWEEN the type and the initializer:
    // Default8087CW: Word platform = $033F;  (System.pas)
    ParseHintsOpt(LDecl);
    if IsWord('absolute') then
    begin
      Next;
      FB.Adopt(LDecl, ParseExpression);
    end
    else if CurKind = tkEqual then
    begin
      Next;
      FB.Adopt(LDecl, ParseConstInitializer(True));
    end;
    ParseHintsOpt(LDecl);
    // Exported-var conventions: `var X: T; cvar; external ...` are C++-ish;
    // plain hint loop already consumed deprecated/platform.
    FB.SetLast(LDecl, FPos - 1);
    FB.Adopt(Result, LDecl);
    Expect(tkSemicolon, '";"');
    ConsumeTrailingDirectives;
    if AClassVar then
      Break; // a `class var` introduces exactly one decl run in our model
  end;
  FB.SetLast(Result, FPos - 1);
end;

function TPasParser.ParseExportsClause: Integer;
var
  LItem: Integer;
begin
  // 1.1.3: exports Name [(params)] [index e] [name e] [resident], ...;
  Result := FB.AddNode(nkExportsClause, NIL_NODE, FPos);
  Next;
  repeat
    LItem := FB.AddNode(nkExportsItem, NIL_NODE, FPos);
    FB.Adopt(LItem, ParseQualifiedName);
    if CurKind = tkLParen then
      FB.Adopt(LItem, ParseParamList(tkRParen));
    while IsWord('index') or IsWord('name') do
    begin
      Next;
      FB.Adopt(LItem, ParseExpression);
    end;
    if IsWord('resident') then
      Next;
    FB.SetLast(LItem, FPos - 1);
    FB.Adopt(Result, LItem);
    if CurKind = tkComma then
      Next
    else
      Break;
  until False;
  Expect(tkSemicolon, '";"');
  FB.SetLast(Result, FPos - 1);
end;

procedure TPasParser.ParseDeclSections(AParent: Integer; AAllowBodies: Boolean;
  const ATerminators: array of TPasTokenKind);
var
  LNode: Integer;
begin
  while not (AtAny(ATerminators) or (CurKind = tkEndOfFile)) do
    case CurKind of
      tkType:
        FB.Adopt(AParent, ParseTypeSection);
      tkConst, tkResourcestring:
        FB.Adopt(AParent, ParseConstSection);
      tkVar, tkThreadvar:
        FB.Adopt(AParent, ParseVarSection(False));
      tkLabel:
        begin
          LNode := FB.AddNode(nkLabelSec, NIL_NODE, FPos);
          Next;
          while CurKind in [tkIdentifier, tkIntLiteral] do
          begin
            Next;
            if CurKind = tkComma then
              Next;
          end;
          Expect(tkSemicolon, '";"');
          FB.SetLast(LNode, FPos - 1);
          FB.Adopt(AParent, LNode);
        end;
      tkExports:
        FB.Adopt(AParent, ParseExportsClause);
      tkProcedure, tkFunction, tkConstructor, tkDestructor:
        FB.Adopt(AParent, ParseRoutine(False, AAllowBodies));
      tkClass:
        // Implementation of class methods: class procedure TFoo.Bar; ...
        if PeekKind(1) in [tkProcedure, tkFunction, tkConstructor,
          tkDestructor] then
        begin
          Next;
          FB.Adopt(AParent, ParseRoutine(True, AAllowBodies));
        end
        else if (PeekKind(1) = tkIdentifier) and
          SameText(FSrc.VisibleText(FPos + 1), 'operator') then
        begin
          Next;
          FB.Adopt(AParent, ParseRoutine(True, AAllowBodies));
        end
        else
        begin
          Error('declaration expected');
          Next;
        end;
      tkLBracket:
        begin
          LNode := ParseAttrGroups;
          if LNode <> NIL_NODE then
            FB.Adopt(AParent, LNode);
        end;
      tkSemicolon:
        Next;
    else
      Error('declaration expected, found "' + CurText + '"');
      Next;
    end;
end;

class function TPasParser.ParseFile(const ASource: TPasPreprocessed;
  out ADiags: TArray<TPasParseDiag>;
  AInterfaceOnly: Boolean = False): TPasTree;
var
  LP: TPasParser;
  LRoot, LSec: Integer;
begin
  LP := Default(TPasParser);
  LP.FSrc := ASource;
  LP.FLast := High(ASource.Visible);
  LP.FFuel := Int64(Length(ASource.Visible)) * 200 + 10000;
  LP.FB.Init;
  case LP.CurKind of
    tkUnit:
      begin
        LRoot := LP.FB.AddNode(nkUnit, NIL_NODE, 0);
        LP.Next;
        LP.FB.Adopt(LRoot, LP.ParseQualifiedName);
        LP.ParseHintsOpt(LRoot);
        LP.Expect(tkSemicolon, '";"');
        // interface section
        LSec := LP.FB.AddNode(nkInterfaceSec, NIL_NODE, LP.FPos);
        LP.Expect(tkInterface, '"interface"');
        if LP.CurKind = tkUses then
          LP.FB.Adopt(LSec, LP.ParseUsesClause);
        LP.ParseDeclSections(LSec, False, [tkImplementation]);
        LP.FB.SetLast(LSec, LP.FPos - 1);
        LP.FB.Adopt(LRoot, LSec);
        // In interface-only mode we stop here: the implementation/init/final/
        // end. are left unparsed. Everything added above is byte-identical to
        // a full parse (append-only builder), so a later full reparse keeps
        // the same interface node indices and symbol ids (the prefix
        // invariant the async snapshot swap depends on).
        if not AInterfaceOnly then
        begin
          // implementation section
          LSec := LP.FB.AddNode(nkImplementationSec, NIL_NODE, LP.FPos);
          LP.Expect(tkImplementation, '"implementation"');
          if LP.CurKind = tkUses then
            LP.FB.Adopt(LSec, LP.ParseUsesClause);
          LP.ParseDeclSections(LSec, True,
            [tkInitialization, tkFinalization, tkBegin, tkEnd]);
          LP.FB.SetLast(LSec, LP.FPos - 1);
          LP.FB.Adopt(LRoot, LSec);
          // initialization / finalization (or legacy begin-as-init)
          if LP.CurKind in [tkInitialization, tkBegin] then
          begin
            LSec := LP.FB.AddNode(nkInitSec, NIL_NODE, LP.FPos);
            LP.Next;
            LP.ParseBlockUntil(LSec, [tkFinalization, tkEnd]);
            LP.FB.SetLast(LSec, LP.FPos - 1);
            LP.FB.Adopt(LRoot, LSec);
          end;
          if LP.CurKind = tkFinalization then
          begin
            LSec := LP.FB.AddNode(nkFinalSec, NIL_NODE, LP.FPos);
            LP.Next;
            LP.ParseBlockUntil(LSec, [tkEnd]);
            LP.FB.SetLast(LSec, LP.FPos - 1);
            LP.FB.Adopt(LRoot, LSec);
          end;
          LP.Expect(tkEnd, '"end"');
          LP.Expect(tkDot, '"."');
        end;
      end;
    tkProgram, tkLibrary:
      begin
        if LP.CurKind = tkProgram then
          LRoot := LP.FB.AddNode(nkProgram, NIL_NODE, 0)
        else
          LRoot := LP.FB.AddNode(nkLibrary, NIL_NODE, 0);
        LP.Next;
        LP.FB.Adopt(LRoot, LP.ParseQualifiedName);
        if LP.CurKind = tkLParen then
        begin
          // Legacy program parameters: program X(Input, Output);
          while not (LP.CurKind in [tkRParen, tkEndOfFile]) do
            LP.Next;
          LP.Expect(tkRParen, '")"');
        end;
        LP.Expect(tkSemicolon, '";"');
        if LP.CurKind = tkUses then
          LP.FB.Adopt(LRoot, LP.ParseUsesClause);
        // A library may end with a bare `end.` — no main begin-block
        // (DUnit's testXpgenLib.dpr: exports ...; end.)
        LP.ParseDeclSections(LRoot, True, [tkBegin, tkEnd]);
        if LP.CurKind = tkBegin then
        begin
          LSec := LP.FB.AddNode(nkBlock, NIL_NODE, LP.FPos);
          LP.Next;
          LP.ParseBlockUntil(LSec, [tkEnd]);
          LP.FB.SetLast(LSec, LP.FPos - 1);
          LP.FB.Adopt(LRoot, LSec);
        end;
        LP.Expect(tkEnd, '"end"');
        LP.Expect(tkDot, '"."');
      end;
  else
    if LP.IsWord('package') then
      begin
        // 'package' is a directive (B.4.2), not a reserved word.
        LRoot := LP.FB.AddNode(nkPackage, NIL_NODE, 0);
        LP.Next;
        LP.FB.Adopt(LRoot, LP.ParseQualifiedName);
        LP.Expect(tkSemicolon, '";"');
        while LP.IsWord('requires') or LP.IsWord('contains') do
        begin
          // Same item shape as a real uses clause (nkUsesItem with the
          // optional `in 'path'` string adopted), so the semantic layer can
          // walk a package's contains-graph like a program's uses-graph.
          // Aux = 1 marks `requires` (references to PACKAGES, not units).
          LSec := LP.FB.AddNode(nkUsesClause, NIL_NODE, LP.FPos);
          if LP.IsWord('requires') then
            LP.FB.SetAux(LSec, 1);
          LP.Next;
          repeat
            var LItem := LP.FB.AddNode(nkUsesItem, NIL_NODE, LP.FPos);
            LP.FB.Adopt(LItem, LP.ParseQualifiedName);
            if LP.CurKind = tkIn then
            begin
              LP.Next;
              if LP.CurKind = tkStringLiteral then
              begin
                LP.FB.Adopt(LItem, LP.FB.AddNode(nkStrLit, NIL_NODE, LP.FPos));
                LP.Next;
              end;
            end;
            LP.FB.SetLast(LItem, LP.FPos - 1);
            LP.FB.Adopt(LSec, LItem);
            if LP.CurKind = tkComma then
              LP.Next
            else
              Break;
          until False;
          LP.Expect(tkSemicolon, '";"');
          LP.FB.SetLast(LSec, LP.FPos - 1);
          LP.FB.Adopt(LRoot, LSec);
        end;
        LP.Expect(tkEnd, '"end"');
        LP.Expect(tkDot, '"."');
      end
    else
    begin
      LP.Error('unit, program, library or package expected');
      LRoot := LP.FB.AddNode(nkError, NIL_NODE, 0);
    end;
  end;
  LP.FB.SetLast(LRoot, LP.FPos);
  SetLength(LP.FDiags, LP.FDiagCount);
  ADiags := LP.FDiags;
  Result := LP.FB.Build(ASource);
end;

class function TPasParser.ParseStatements(const ASource: TPasPreprocessed;
  out ADiags: TArray<TPasParseDiag>): TPasTree;
var
  LParser: TPasParser;
  LRoot: Integer;
begin
  LParser := Default(TPasParser);
  LParser.FSrc := ASource;
  LParser.FLast := High(ASource.Visible);
  LParser.FFuel := Int64(Length(ASource.Visible)) * 200 + 10000;
  LParser.FB.Init;
  LRoot := LParser.FB.AddNode(nkBlock, NIL_NODE, 0);
  LParser.ParseBlockUntil(LRoot, [tkEndOfFile]);
  LParser.FB.SetLast(LRoot, LParser.FPos);
  SetLength(LParser.FDiags, LParser.FDiagCount);
  ADiags := LParser.FDiags;
  Result := LParser.FB.Build(ASource);
end;

end.
