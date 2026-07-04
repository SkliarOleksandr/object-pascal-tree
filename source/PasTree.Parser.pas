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
    // cursor
    function CurKind: TPasTokenKind;
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
  public
    class function ParseStatements(const ASource: TPasPreprocessed;
      out ADiags: TArray<TPasParseDiag>): TPasTree; static;
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
  Result := FSrc.VisibleToken(FPos).Kind;
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
        Result := FB.AddNode(nkIntLit, NIL_NODE, LStart);
        Next;
        Exit;
      end;
    tkRealLiteral:
      begin
        Result := FB.AddNode(nkRealLit, NIL_NODE, LStart);
        Next;
        Exit;
      end;
    tkStringLiteral, tkMultilineString, tkControlChar:
      begin
        // Adjacent string elements concatenate into one literal (B.6.1).
        Result := FB.AddNode(nkStrLit, NIL_NODE, LStart);
        Next;
        while CurKind in [tkStringLiteral, tkMultilineString, tkControlChar]
        do
          Next;
        FB.SetLast(Result, FPos - 1);
        Exit;
      end;
    tkNil:
      begin
        Result := FB.AddNode(nkNilLit, NIL_NODE, LStart);
        Next;
        Exit;
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
        end;
        FB.SetLast(LNode, FPos - 1);
        Exit(LNode);
      end;
    tkProcedure, tkFunction:
      begin
        // Anonymous method literal (17.2.1) — v1: opaque params, one block.
        LNode := FB.AddNode(nkAnonMethod, NIL_NODE, LStart);
        Next;
        if CurKind = tkLParen then
        begin
          LChild := FB.AddNode(nkAnonParams, NIL_NODE, FPos);
          LStart := 1;
          Next;
          while (LStart > 0) and (CurKind <> tkEndOfFile) do
          begin
            case CurKind of
              tkLParen: Inc(LStart);
              tkRParen: Dec(LStart);
            end;
            Next;
          end;
          FB.SetLast(LChild, FPos - 1);
          FB.Adopt(LNode, LChild);
        end;
        if CurKind = tkColon then
        begin
          Next;
          FB.Adopt(LNode, ParseTypeRef);
        end;
        if CurKind = tkBegin then
        begin
          LChild := FB.AddNode(nkBlock, NIL_NODE, FPos);
          Next;
          ParseBlockUntil(LChild, [tkEnd]);
          Expect(tkEnd, '"end"');
          FB.SetLast(LChild, FPos - 1);
          FB.Adopt(LNode, LChild);
        end
        else
          Error('"begin" expected in anonymous method');
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
          if CurKind = tkIdentifier then
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
              if LKind in [tkLParen, tkDot] then
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
  LNode, LExpr: Integer;
begin
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

  // Expression statement / assignment (5.1).
  LExpr := ParseExpression;
  if CurKind = tkAssign then
  begin
    LNode := FB.AddNode(nkAssign, NIL_NODE, FPos);
    FB.Adopt(LNode, LExpr);
    Next;
    FB.Adopt(LNode, ParseExpression);
    FB.SetLast(LNode, FPos - 1);
    Result := LNode;
  end
  else
  begin
    LNode := FB.AddNode(nkExprStmt, NIL_NODE, FPos);
    FB.Adopt(LNode, LExpr);
    FB.SetLast(LNode, FPos - 1);
    Result := LNode;
  end;
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
  LParser.FB.Init;
  LRoot := LParser.FB.AddNode(nkBlock, NIL_NODE, 0);
  LParser.ParseBlockUntil(LRoot, [tkEndOfFile]);
  LParser.FB.SetLast(LRoot, LParser.FPos);
  SetLength(LParser.FDiags, LParser.FDiagCount);
  ADiags := LParser.FDiags;
  Result := LParser.FB.Build(ASource);
end;

end.
