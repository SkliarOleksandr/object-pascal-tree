unit PasTree.Lexer;

{
  PasTree - the lexer (spec: object-pascal-spec, Appendix B).

  Contract:
  - Full fidelity: every character of the source belongs to exactly one
    token; concatenating all tokens reproduces the source byte-for-byte.
  - Trivia (whitespace, comments) and compiler directives are emitted as
    ordinary tokens; the preprocessor later builds the "visible" stream.
  - Reserved words (B.4.1) become dedicated kinds; &-escaped words are
    always tkIdentifier (B.3).
  - asm...end switches to BASM mode (spec 6.10): body text is emitted as
    opaque tkAsmChunk tokens, BUT comments and directives inside asm are
    still lexed normally so conditional compilation keeps working. An
    `asm` opened inside a conditional branch is closed by that branch's
    `$ELSE`/`$ELSEIF` (NoteDirective): the alternative branch is Pascal
    text sharing the routine's `end`, and without this it lexed as asm
    chunks even when the asm branch was dead.
    Known limitation: a bare `end` inside a skipped $IFDEF branch of an
    asm body would close the asm block at the raw-lexing level.
  - Caret control chars (spec B.6.2): `^` + a LETTER stays tkCaret +
    tkIdentifier (`^M` and the pointer type `^TFoo` are the same two
    tokens; only the parser knows expression from type position). `^` +
    a non-letter char - `^[ ^^ ^? ^1 ^'` - is one tkCaretChar token, but
    only when the previous significant token cannot end an operand:
    `P^[0]`, `A[1]^^` and `nil^` are still derefs. dcc also takes
    whitespace after the caret (`^ ` = chr 96); that is NOT mirrored - a
    token spanning a newline would break every line-based consumer.
}

interface

uses
  System.Character,
  PasTree.Types;

type
  TPasLexer = record
  private
    FSource: string;
    FBase: PChar;
    FLen: Integer;
    FPos: Integer;            // 0-based
    FTokens: TArray<TPasToken>;
    FTokenCount: Integer;
    FDiags: TArray<TPasDiagnostic>;
    FDiagCount: Integer;
    FInAsm: Boolean;
    // Conditional nesting seen so far (a raw count - the lexer does not know
    // which branch is live) and the depth the open `asm` started at; see
    // NoteDirective for what the pair is for.
    FCondDepth: Integer;
    FAsmCondDepth: Integer;
    procedure NoteDirective(ANameStart: Integer);
    procedure Emit(AKind: TPasTokenKind; AStart: Integer;
      AFlags: TPasTokenFlags = []);
    function PrevEndsOperand: Boolean;
    function IsCaretCharHere: Boolean;
    procedure Diag(ACode: TPasDiagCode; AStart, ALen: Integer);
    function CharAt(AIndex: Integer): Char; inline;
    function IsIdentRun(AIndex: Integer): Boolean;
    procedure LexWhitespace;
    procedure LexLineComment;
    procedure LexBraceCommentOrDirective;
    procedure LexParenOrCommentOrLegacyBracket;
    procedure LexString;
    procedure LexMultilineString(AQuoteRun: Integer);
    procedure LexControlChar;
    procedure LexNumber(AStart: Integer = -1;
      AExtraFlags: TPasTokenFlags = []);
    procedure LexHexNumber;
    procedure LexBinNumber;
    procedure LexIdentOrKeyword(AAmpersand: Boolean);
    procedure LexAsmToken;
    procedure LexPunctuation;
    procedure Run;
  public
    class function Tokenize(const ASource: string): TPasTokenStream; static;
  end;

implementation

function IsDigit(ACh: Char): Boolean; inline;
begin
  Result := (ACh >= '0') and (ACh <= '9');
end;

function IsHexDigit(ACh: Char): Boolean; inline;
begin
  Result := IsDigit(ACh) or ((ACh >= 'A') and (ACh <= 'F')) or
    ((ACh >= 'a') and (ACh <= 'f'));
end;

function IsBinDigit(ACh: Char): Boolean; inline;
begin
  Result := (ACh = '0') or (ACh = '1');
end;

function IsIdentStart(ACh: Char): Boolean; inline;
begin
  Result := ((ACh >= 'a') and (ACh <= 'z')) or
    ((ACh >= 'A') and (ACh <= 'Z')) or (ACh = '_') or
    ((ACh > #127) and ACh.IsLetter);
end;

function IsIdentChar(ACh: Char): Boolean; inline;
begin
  Result := ((ACh >= 'a') and (ACh <= 'z')) or
    ((ACh >= 'A') and (ACh <= 'Z')) or (ACh = '_') or IsDigit(ACh) or
    ((ACh > #127) and ACh.IsLetterOrDigit);
end;

function IsWhitespace(ACh: Char): Boolean; inline;
begin
  // Every C0 control character is whitespace for dcc, not only the printing
  // ones (#9 #10 #11 #12 #13, #26 = legacy DOS EOF marker): a stray #$12
  // after a semicolon in a PDF-viewer library unit, #1, #31 and even an
  // embedded #0 compile silently (probed dcc64 35.0, 2026-09-16); only #$7F
  // is E2038. Lexing them as tkUnknown made the parser report a declaration
  // expected at an invisible character.
  Result := (ACh = ' ') or (ACh < #32);
end;

{ TPasLexer }

class function TPasLexer.Tokenize(const ASource: string): TPasTokenStream;
var
  LLexer: TPasLexer;
begin
  LLexer := Default(TPasLexer);
  LLexer.FSource := ASource;
  LLexer.FLen := Length(ASource);
  if LLexer.FLen > 0 then
    LLexer.FBase := PChar(LLexer.FSource)
  else
    LLexer.FBase := nil;
  // Pre-size: Delphi source averages ~1 token per 4 chars incl. trivia.
  SetLength(LLexer.FTokens, (LLexer.FLen div 4) + 16);
  LLexer.Run;

  Result.Source := LLexer.FSource;
  SetLength(LLexer.FTokens, LLexer.FTokenCount);
  Result.Tokens := LLexer.FTokens;
  SetLength(LLexer.FDiags, LLexer.FDiagCount);
  Result.Diagnostics := LLexer.FDiags;
  Result.LineStarts := BuildLineStarts(LLexer.FSource);
end;

function TPasLexer.CharAt(AIndex: Integer): Char;
begin
  if (AIndex >= 0) and (AIndex < FLen) then
    Result := FBase[AIndex]
  else
    Result := #0;
end;

{ True when AIndex begins a run of '&' followed by an identifier start - i.e. the
  `&&op_Equality` shape, where only the FIRST '&' of the whole token escapes and
  the rest are name characters. }
function TPasLexer.IsIdentRun(AIndex: Integer): Boolean;
var
  LIdx: Integer;
begin
  LIdx := AIndex;
  while CharAt(LIdx) = '&' do
    Inc(LIdx);
  Result := IsIdentStart(CharAt(LIdx));
end;

procedure TPasLexer.Emit(AKind: TPasTokenKind; AStart: Integer;
  AFlags: TPasTokenFlags);
begin
  if FTokenCount = Length(FTokens) then
    SetLength(FTokens, (Length(FTokens) * 3) div 2 + 16);
  FTokens[FTokenCount].Kind := AKind;
  FTokens[FTokenCount].Flags := AFlags;
  FTokens[FTokenCount].Start := AStart;
  FTokens[FTokenCount].Len := FPos - AStart;
  Inc(FTokenCount);
end;

function TPasLexer.PrevEndsOperand: Boolean;
var
  LIdx: Integer;
begin
  // Can the token before FPos end an operand, making a `^` here a postfix
  // dereference? A one-letter identifier glued to a caret (`^M`) is itself
  // a caret char when THAT caret was in operand position, so the question
  // moves to the token before it: `^M^J` is two chars, `X^M^J` two derefs.
  LIdx := FTokenCount - 1;
  repeat
    while (LIdx >= 0) and (FTokens[LIdx].Kind in [tkWhitespace,
      tkCommentLine, tkCommentBrace, tkCommentParen, tkDirective]) do
      Dec(LIdx);
    if LIdx < 0 then
      Exit(False);
    if (FTokens[LIdx].Kind = tkIdentifier) and (FTokens[LIdx].Len = 1) and
       (LIdx > 0) and (FTokens[LIdx - 1].Kind = tkCaret) and
       (FTokens[LIdx - 1].Start + 1 = FTokens[LIdx].Start) then
      Dec(LIdx, 2)
    else
      Exit(FTokens[LIdx].Kind in [tkIdentifier, tkRParen, tkRBracket,
        tkCaret, tkNil, tkInherited, tkString, tkIntLiteral, tkRealLiteral]);
  until False;
end;

function TPasLexer.IsCaretCharHere: Boolean;
var
  LCh: Char;
begin
  // FPos is just past a `^`. A caret control char (B.6.2) when the next
  // char is a printable non-letter (`^[ ^^ ^? ^1 ^'`) and the caret is in
  // operand position - nothing before it that could end an operand and
  // make it a postfix dereference (`P^[0]`, `A[1]^^`, `nil^`). Letters
  // are left to the parser: `^M` and the pointer type `^TFoo` lex the
  // same and only the parser knows expression from type position.
  // Whitespace after the caret (dcc: `^ ` = chr 96) is deliberately not
  // taken - a token spanning a newline would break line-based consumers.
  // Comment and directive openers stay openers: Vcl.Outline.pas writes
  // `{$IFNDEF CLR}^{$ENDIF}TBitmap`, a pointer type with a directive glued
  // to the caret; `^{` there is not chr 59.
  LCh := CharAt(FPos);
  if (LCh <= #32) or (LCh > #127) or (LCh = '&') or (LCh = '{') or
     (LCh = '(') or ((LCh = '/') and (CharAt(FPos + 1) = '/')) or
     IsIdentStart(LCh) then
    Exit(False);
  Result := not PrevEndsOperand;
end;

procedure TPasLexer.Diag(ACode: TPasDiagCode; AStart, ALen: Integer);
begin
  if FDiagCount = Length(FDiags) then
    SetLength(FDiags, Length(FDiags) * 2 + 8);
  FDiags[FDiagCount].Code := ACode;
  FDiags[FDiagCount].Start := AStart;
  FDiags[FDiagCount].Len := ALen;
  Inc(FDiagCount);
end;

procedure TPasLexer.Run;
var
  LCh: Char;
  LStart: Integer;
begin
  while FPos < FLen do
  begin
    if FInAsm then
    begin
      LexAsmToken;
      Continue;
    end;
    LCh := FBase[FPos];
    if IsWhitespace(LCh) then
      LexWhitespace
    else if IsIdentStart(LCh) then
      LexIdentOrKeyword(False)
    else if IsDigit(LCh) then
      LexNumber
    else
      case LCh of
        '''': LexString;
        '{': LexBraceCommentOrDirective;
        '(': LexParenOrCommentOrLegacyBracket;
        '/':
          if CharAt(FPos + 1) = '/' then
            LexLineComment
          else
            LexPunctuation;
        '#': LexControlChar;
        '$': LexHexNumber;
        '%': LexBinNumber;
        '&':
          // One '&' escapes (B.3), and any FURTHER '&'s belong to the name:
          // `&&op_Equality` names `&op_Equality`, which is a different member
          // from `op_Equality` - dcc32 37.0 accepts both in one record, and
          // rejects `&op_Equality` beside `op_Equality` as a redeclaration, so
          // exactly one leading '&' is the escape. a third-party library's TValue declares
          // its comparison operators this way and the stray-'&' token that used
          // to come out here derailed the whole class body (5 false E2004).
          if IsIdentStart(CharAt(FPos + 1)) or
             ((CharAt(FPos + 1) = '&') and IsIdentRun(FPos + 1)) then
            LexIdentOrKeyword(True)
          else if IsDigit(CharAt(FPos + 1)) then
          begin
            // Undocumented but accepted by dcc: & before a numeric literal
            // (e.g. `&1` in System.Beacon.pas). Verified against dcc64 37.0.
            LStart := FPos;
            Inc(FPos);
            LexNumber(LStart, [tfAmpersand]);
          end
          else
          begin
            LStart := FPos;
            Inc(FPos);
            Emit(tkUnknown, LStart);
            Diag(dcInvalidAmpersand, LStart, 1);
          end;
      else
        LexPunctuation;
      end;
  end;
  // The file ended while still inside an `asm` block. Reported HERE and not
  // in LexAsmToken, where the test used to sit: that one needed FPos = LStart
  // with FPos >= FLen at once, and the chunk loop always consumes at least
  // one character - so the diagnostic could never fire, and a truncated asm
  // block ended the file silently.
  if FInAsm then
  begin
    FInAsm := False;
    Diag(dcUnterminatedAsm, FPos, 0);
  end;
  // Zero-length EOF sentinel.
  Emit(tkEndOfFile, FPos);
end;

procedure TPasLexer.LexWhitespace;
var
  LStart: Integer;
begin
  LStart := FPos;
  repeat
    Inc(FPos);
  until (FPos >= FLen) or not IsWhitespace(FBase[FPos]);
  Emit(tkWhitespace, LStart);
end;

procedure TPasLexer.LexLineComment;
var
  LStart: Integer;
  LCh: Char;
begin
  LStart := FPos;
  Inc(FPos, 2); // '//'
  while FPos < FLen do
  begin
    LCh := FBase[FPos];
    if (LCh = #13) or (LCh = #10) then
      Break;
    Inc(FPos);
  end;
  Emit(tkCommentLine, LStart);
end;

procedure TPasLexer.LexBraceCommentOrDirective;
var
  LStart: Integer;
  LKind: TPasTokenKind;
begin
  LStart := FPos;
  Inc(FPos); // '{'
  if CharAt(FPos) = '$' then
    LKind := tkDirective
  else
    LKind := tkCommentBrace;
  if LKind = tkDirective then
    NoteDirective(FPos + 1);
  while (FPos < FLen) and (FBase[FPos] <> '}') do
    Inc(FPos);
  if FPos < FLen then
  begin
    Inc(FPos); // '}'
    Emit(LKind, LStart);
  end
  else
  begin
    Emit(LKind, LStart, [tfUnterminated]);
    if LKind = tkDirective then
      Diag(dcUnterminatedDirective, LStart, FPos - LStart)
    else
      Diag(dcUnterminatedComment, LStart, FPos - LStart);
  end;
end;

procedure TPasLexer.NoteDirective(ANameStart: Integer);

  function IsName(const AUpper: string): Boolean;
  var
    LIdx: Integer;
  begin
    for LIdx := 1 to Length(AUpper) do
      if UpCase(CharAt(ANameStart + LIdx - 1)) <> AUpper[LIdx] then
        Exit(False);
    Result := not IsIdentChar(CharAt(ANameStart + Length(AUpper)));
  end;

begin
  // Tracks conditional depth so an `asm` opened INSIDE a conditional branch
  // is closed by that branch's $ELSE/$ELSEIF, not by the shared `end` after
  // $IFEND. The shape (both branches of one routine, a Win32 asm body and a
  // portable Pascal one):
  //   function F: Integer;
  //   {$IF defined(WIN32)} asm ... {$ELSE} const ... begin ... {$IFEND} end;
  // Lexing runs before the preprocessor decides the branch, so on Win64 the
  // dead `asm` still switched the mode and the live Pascal branch came out
  // as tkAsmChunk tokens - 74 parse errors in one unit. An $ELSE at a DEEPER
  // depth (a conditional inside the asm body) leaves the mode alone, and one
  // at depth 0 cannot belong to anything.
  if IsName('IF') or IsName('IFDEF') or IsName('IFNDEF') or IsName('IFOPT') then
    Inc(FCondDepth)
  else if IsName('ENDIF') or IsName('IFEND') then
  begin
    if FCondDepth > 0 then
      Dec(FCondDepth);
  end
  else if IsName('ELSE') or IsName('ELSEIF') then
    if FInAsm and (FCondDepth > 0) and (FCondDepth = FAsmCondDepth) then
      FInAsm := False;
end;

procedure TPasLexer.LexParenOrCommentOrLegacyBracket;
var
  LStart: Integer;
  LKind: TPasTokenKind;
begin
  LStart := FPos;
  case CharAt(FPos + 1) of
    '*':
      begin
        Inc(FPos, 2); // '(*'
        if CharAt(FPos) = '$' then
          LKind := tkDirective
        else
          LKind := tkCommentParen;
        if LKind = tkDirective then
          NoteDirective(FPos + 1);
        while (FPos < FLen) and
          not ((FBase[FPos] = '*') and (CharAt(FPos + 1) = ')')) do
          Inc(FPos);
        if FPos < FLen then
        begin
          Inc(FPos, 2); // '*)'
          Emit(LKind, LStart);
        end
        else
        begin
          Emit(LKind, LStart, [tfUnterminated]);
          if LKind = tkDirective then
            Diag(dcUnterminatedDirective, LStart, FPos - LStart)
          else
            Diag(dcUnterminatedComment, LStart, FPos - LStart);
        end;
      end;
    '.':
      begin
        // Legacy alternate for '['
        Inc(FPos, 2);
        Emit(tkLBracket, LStart, [tfLegacyBracket]);
      end;
  else
    Inc(FPos);
    Emit(tkLParen, LStart);
  end;
end;

procedure TPasLexer.LexString;
var
  LStart, LRun, LProbe: Integer;
begin
  LStart := FPos;
  // Count the opening quote run to detect multiline literals (B.6.3):
  // an odd run of >= 3 quotes followed by a line break opens a multiline
  // string. Anything else is handled by the classic single-line automaton.
  LRun := 0;
  LProbe := FPos;
  while CharAt(LProbe) = '''' do
  begin
    Inc(LRun);
    Inc(LProbe);
  end;
  if (LRun >= 3) and Odd(LRun) and
    ((CharAt(LProbe) = #13) or (CharAt(LProbe) = #10) or (LProbe >= FLen)) then
  begin
    LexMultilineString(LRun);
    Exit;
  end;

  Inc(FPos); // opening quote
  while FPos < FLen do
  begin
    case FBase[FPos] of
      '''':
        begin
          if CharAt(FPos + 1) = '''' then
            Inc(FPos, 2)  // escaped quote
          else
          begin
            Inc(FPos);    // closing quote
            Emit(tkStringLiteral, LStart);
            Exit;
          end;
        end;
      #13, #10:
        Break;
    else
      Inc(FPos);
    end;
  end;
  Emit(tkStringLiteral, LStart, [tfUnterminated]);
  Diag(dcUnterminatedString, LStart, FPos - LStart);
end;

procedure TPasLexer.LexMultilineString(AQuoteRun: Integer);
var
  LStart, LLineStart, LProbe, LRun, LFirstContent: Integer;

  { B.6.3: the closing run's indentation is the base, and every content line
    must BEGIN with it - dcc reports `E2657 Inconsistent indent characters`, one
    per offending line, and the message names the real rule better than "under-
    indented" does. Verified against dcc32 37.0, comparing characters and not
    widths:

      closer '    ' (4 spaces), line '  under indented'   error at the 'u'
      closer '    ', line #9 (a tab)                      error at the tab
      closer '    ', line '  ' (whitespace only, shorter) OK
      closer '    ', line '' (empty)                      OK
      closer '    ', line '     '#9'x' (more, then a tab) OK
      closer '' (column 1)                                anything goes

    One rule covers all six: walk the closer's indent character by character; a
    MISMATCH is the error, and running out of line is not. That is why a short
    whitespace-only line passes while a tab-indented one fails, which no
    width-based reading of the spec predicts.

    ACloser is the closing line's start and ALen its indentation length. }
  procedure CheckIndent(AFrom, ACloser, ALen: Integer);
  var
    LLine, LEnd, LIdx: Integer;
  begin
    if (ALen <= 0) or (AFrom < 0) then
      Exit;
    LLine := AFrom;
    while LLine < ACloser do
    begin
      LEnd := LLine;
      while (LEnd < ACloser) and (FBase[LEnd] <> #13) and (FBase[LEnd] <> #10) do
        Inc(LEnd);
      LIdx := 0;
      while (LIdx < ALen) and (LLine + LIdx < LEnd) do
      begin
        if FBase[LLine + LIdx] <> FBase[ACloser + LIdx] then
        begin
          Diag(dcInconsistentIndentChars, LLine + LIdx, 1);
          Break;
        end;
        Inc(LIdx);
      end;
      // Past the line break, whichever form it takes.
      if (LEnd < ACloser) and (FBase[LEnd] = #13) and
         (CharAt(LEnd + 1) = #10) then
        LLine := LEnd + 2
      else
        LLine := LEnd + 1;
    end;
  end;

begin
  LStart := FPos;
  LFirstContent := -1;
  Inc(FPos, AQuoteRun);
  // Scan line by line for a closing run of the same length on its own line.
  while FPos < FLen do
  begin
    // Advance to the start of the next line.
    while (FPos < FLen) and (FBase[FPos] <> #10) and (FBase[FPos] <> #13) do
      Inc(FPos);
    if FPos >= FLen then
      Break;
    if (FBase[FPos] = #13) and (CharAt(FPos + 1) = #10) then
      Inc(FPos, 2)
    else
      Inc(FPos);
    LLineStart := FPos;
    if LFirstContent < 0 then
      LFirstContent := LLineStart;   // content starts on the line after the run
    // Optional indentation before the closing quote run.
    LProbe := LLineStart;
    while (CharAt(LProbe) = ' ') or (CharAt(LProbe) = #9) do
      Inc(LProbe);
    LRun := 0;
    while CharAt(LProbe + LRun) = '''' do
      Inc(LRun);
    if LRun = AQuoteRun then
    begin
      CheckIndent(LFirstContent, LLineStart, LProbe - LLineStart);
      FPos := LProbe + LRun;
      Emit(tkMultilineString, LStart);
      Exit;
    end;
  end;
  FPos := FLen;
  Emit(tkMultilineString, LStart, [tfUnterminated]);
  Diag(dcUnterminatedMultilineString, LStart, FPos - LStart);
end;

procedure TPasLexer.LexControlChar;
var
  LStart: Integer;
  LFlags: TPasTokenFlags;
  LOk: Boolean;
begin
  LStart := FPos;
  LFlags := [];
  Inc(FPos); // '#'
  LOk := False;
  case CharAt(FPos) of
    '$':
      begin
        Include(LFlags, tfHex);
        Inc(FPos);
        while IsHexDigit(CharAt(FPos)) or (CharAt(FPos) = '_') do
        begin
          if FBase[FPos] <> '_' then
            LOk := True;
          Inc(FPos);
        end;
      end;
    '%':
      begin
        Include(LFlags, tfBinary);
        Inc(FPos);
        while IsBinDigit(CharAt(FPos)) or (CharAt(FPos) = '_') do
        begin
          if FBase[FPos] <> '_' then
            LOk := True;
          Inc(FPos);
        end;
      end;
  else
    while IsDigit(CharAt(FPos)) or (CharAt(FPos) = '_') do
    begin
      if FBase[FPos] <> '_' then
        LOk := True;
      Inc(FPos);
    end;
  end;
  Emit(tkControlChar, LStart, LFlags);
  if not LOk then
    Diag(dcMissingControlCharValue, LStart, FPos - LStart);
end;

procedure TPasLexer.LexNumber(AStart: Integer; AExtraFlags: TPasTokenFlags);
var
  LStart: Integer;
  LFlags: TPasTokenFlags;
  LIsReal: Boolean;
  LProbe: Integer;
begin
  if AStart >= 0 then
    LStart := AStart
  else
    LStart := FPos;
  LFlags := AExtraFlags;
  LIsReal := False;
  while IsDigit(CharAt(FPos)) or (CharAt(FPos) = '_') do
  begin
    if FBase[FPos] = '_' then
      Include(LFlags, tfHasSeparator);
    Inc(FPos);
  end;
  // Fraction: '.' followed by a digit, or by nothing that could start a
  // different token - guards '..' ranges and member access on literals
  // (42.ToString; dcc reads `100.e2` as member access too, not as a real).
  // The fraction may be EMPTY: `100. - X` and `1.;` are real literals for
  // dcc (probed 2026-09-16), and the spec's B.5.2 grammar is narrower than
  // the compiler here.
  if (CharAt(FPos) = '.') and
     (IsDigit(CharAt(FPos + 1)) or
      ((CharAt(FPos + 1) <> '.') and not IsIdentStart(CharAt(FPos + 1)))) then
  begin
    LIsReal := True;
    Inc(FPos); // '.'
    while IsDigit(CharAt(FPos)) or (CharAt(FPos) = '_') do
    begin
      if FBase[FPos] = '_' then
        Include(LFlags, tfHasSeparator);
      Inc(FPos);
    end;
  end;
  // Exponent.
  if (CharAt(FPos) = 'e') or (CharAt(FPos) = 'E') then
  begin
    LProbe := FPos + 1;
    if (CharAt(LProbe) = '+') or (CharAt(LProbe) = '-') then
      Inc(LProbe);
    if IsDigit(CharAt(LProbe)) then
    begin
      LIsReal := True;
      FPos := LProbe;
      while IsDigit(CharAt(FPos)) do
        Inc(FPos);
    end;
  end;
  if LIsReal then
    Emit(tkRealLiteral, LStart, LFlags)
  else
    Emit(tkIntLiteral, LStart, LFlags);
end;

procedure TPasLexer.LexHexNumber;
var
  LStart: Integer;
  LFlags: TPasTokenFlags;
  LOk: Boolean;
begin
  LStart := FPos;
  LFlags := [tfHex];
  Inc(FPos); // '$'
  LOk := False;
  while IsHexDigit(CharAt(FPos)) or (CharAt(FPos) = '_') do
  begin
    if FBase[FPos] = '_' then
      Include(LFlags, tfHasSeparator)
    else
      LOk := True;
    Inc(FPos);
  end;
  Emit(tkIntLiteral, LStart, LFlags);
  if not LOk then
    Diag(dcMissingHexDigits, LStart, FPos - LStart);
end;

procedure TPasLexer.LexBinNumber;
var
  LStart: Integer;
  LFlags: TPasTokenFlags;
  LOk: Boolean;
begin
  LStart := FPos;
  LFlags := [tfBinary];
  Inc(FPos); // '%'
  LOk := False;
  while IsBinDigit(CharAt(FPos)) or (CharAt(FPos) = '_') do
  begin
    if FBase[FPos] = '_' then
      Include(LFlags, tfHasSeparator)
    else
      LOk := True;
    Inc(FPos);
  end;
  Emit(tkIntLiteral, LStart, LFlags);
  if not LOk then
    Diag(dcMissingBinDigits, LStart, FPos - LStart);
end;

procedure TPasLexer.LexIdentOrKeyword(AAmpersand: Boolean);
var
  LStart, LNameStart: Integer;
  LKind: TPasTokenKind;
begin
  LStart := FPos;
  if AAmpersand then
  begin
    Inc(FPos); // the escaping '&'
    // Any further '&'s are part of the NAME (see the dispatch in Run).
    while CharAt(FPos) = '&' do
      Inc(FPos);
  end;
  LNameStart := FPos;
  repeat
    Inc(FPos);
  until (FPos >= FLen) or not IsIdentChar(FBase[FPos]);
  if AAmpersand then
  begin
    // An &-escaped word is always an identifier, never a keyword (B.3).
    Emit(tkIdentifier, LStart, [tfAmpersand]);
    Exit;
  end;
  LKind := KeywordKind(FBase + LNameStart, FPos - LNameStart);
  Emit(LKind, LStart);
  if LKind = tkAsm then
  begin
    FInAsm := True;
    FAsmCondDepth := FCondDepth;
  end;
end;

procedure TPasLexer.LexAsmToken;
var
  LStart, LWordStart: Integer;
  LCh: Char;
begin
  LCh := FBase[FPos];
  // Trivia, directives and strings keep their normal lexing inside asm.
  if IsWhitespace(LCh) then
  begin
    LexWhitespace;
    Exit;
  end;
  case LCh of
    '{':
      begin
        LexBraceCommentOrDirective;
        Exit;
      end;
    '/':
      if CharAt(FPos + 1) = '/' then
      begin
        LexLineComment;
        Exit;
      end;
    '(':
      if CharAt(FPos + 1) = '*' then
      begin
        LexParenOrCommentOrLegacyBracket;
        Exit;
      end;
    '''':
      begin
        LexString;
        Exit;
      end;
    '"':
      begin
        // BASM accepts double-quoted strings: CMP AL,"'"
        LStart := FPos;
        Inc(FPos);
        while (FPos < FLen) and (FBase[FPos] <> '"') and
          (FBase[FPos] <> #13) and (FBase[FPos] <> #10) do
          Inc(FPos);
        if (FPos < FLen) and (FBase[FPos] = '"') then
        begin
          Inc(FPos);
          Emit(tkStringLiteral, LStart);
        end
        else
        begin
          Emit(tkStringLiteral, LStart, [tfUnterminated]);
          Diag(dcUnterminatedString, LStart, FPos - LStart);
        end;
        Exit;
      end;
  end;
  // Opaque BASM chunk: consume until whitespace/comment/string/`end`.
  LStart := FPos;
  while FPos < FLen do
  begin
    LCh := FBase[FPos];
    if IsWhitespace(LCh) or (LCh = '''') or (LCh = '"') or (LCh = '{') then
      Break;
    if (LCh = '/') and (CharAt(FPos + 1) = '/') then
      Break;
    if (LCh = '(') and (CharAt(FPos + 1) = '*') then
      Break;
    if ((LCh = 'e') or (LCh = 'E')) and not IsIdentChar(CharAt(FPos - 1)) and
       (CharAt(FPos - 1) <> '@') then
    begin
      // NB: '@' exclusion - BASM labels may be named END: `JS @@END` /
      // `@@END:` (Vcl.Graphics.pas) must not close the asm block.
      // Possible closing `end` at a word boundary.
      LWordStart := FPos;
      if ((CharAt(LWordStart + 1) = 'n') or (CharAt(LWordStart + 1) = 'N')) and
         ((CharAt(LWordStart + 2) = 'd') or (CharAt(LWordStart + 2) = 'D')) and
         not IsIdentChar(CharAt(LWordStart + 3)) then
      begin
        if FPos > LStart then
          Emit(tkAsmChunk, LStart);
        FPos := LWordStart + 3;
        Emit(tkEnd, LWordStart);
        FInAsm := False;
        Exit;
      end;
    end;
    Inc(FPos);
  end;
  if FPos > LStart then
    Emit(tkAsmChunk, LStart);
  // EOF inside the block is Run's to report - see there.
end;

procedure TPasLexer.LexPunctuation;
var
  LStart: Integer;
  LCh: Char;
begin
  LStart := FPos;
  LCh := FBase[FPos];
  Inc(FPos);
  case LCh of
    '+': Emit(tkPlus, LStart);
    '-': Emit(tkMinus, LStart);
    '*': Emit(tkStar, LStart);
    '/': Emit(tkSlash, LStart);
    '=': Emit(tkEqual, LStart);
    ',': Emit(tkComma, LStart);
    ';': Emit(tkSemicolon, LStart);
    '^':
      if IsCaretCharHere then
      begin
        Inc(FPos);
        Emit(tkCaretChar, LStart);
      end
      else
        Emit(tkCaret, LStart);
    '@': Emit(tkAt, LStart);
    '[': Emit(tkLBracket, LStart);
    ']': Emit(tkRBracket, LStart);
    ')': Emit(tkRParen, LStart);
    ':':
      if CharAt(FPos) = '=' then
      begin
        Inc(FPos);
        Emit(tkAssign, LStart);
      end
      else
        Emit(tkColon, LStart);
    '<':
      case CharAt(FPos) of
        '=':
          begin
            Inc(FPos);
            Emit(tkLessEqual, LStart);
          end;
        '>':
          begin
            Inc(FPos);
            Emit(tkNotEqual, LStart);
          end;
      else
        Emit(tkLess, LStart);
      end;
    '>':
      if CharAt(FPos) = '=' then
      begin
        Inc(FPos);
        Emit(tkGreaterEqual, LStart);
      end
      else
        Emit(tkGreater, LStart);
    '.':
      case CharAt(FPos) of
        '.':
          begin
            Inc(FPos);
            Emit(tkDotDot, LStart);
          end;
        ')':
          begin
            // Legacy alternate for ']'
            Inc(FPos);
            Emit(tkRBracket, LStart, [tfLegacyBracket]);
          end;
      else
        Emit(tkDot, LStart);
      end;
  else
    Emit(tkUnknown, LStart);
    Diag(dcInvalidChar, LStart, 1);
  end;
end;

end.
