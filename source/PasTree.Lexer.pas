unit PasTree.Lexer;

{
  PasTree — the lexer (spec: object-pascal-spec, Appendix B).

  Contract:
  - Full fidelity: every character of the source belongs to exactly one
    token; concatenating all tokens reproduces the source byte-for-byte.
  - Trivia (whitespace, comments) and compiler directives are emitted as
    ordinary tokens; the preprocessor later builds the "visible" stream.
  - Reserved words (B.4.1) become dedicated kinds; &-escaped words are
    always tkIdentifier (B.3).
  - asm...end switches to BASM mode (spec 6.10): body text is emitted as
    opaque tkAsmChunk tokens, BUT comments and directives inside asm are
    still lexed normally so conditional compilation keeps working.
    Known limitation: a bare `end` inside a skipped $IFDEF branch of an
    asm body would close the asm block at the raw-lexing level.
  - The caret control-char notation (^M) is NOT resolved here: `^` is
    always tkCaret; the parser decides caret-char vs dereference by
    position and adjacency (spec B.6.2).
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
    procedure Emit(AKind: TPasTokenKind; AStart: Integer;
      AFlags: TPasTokenFlags = []);
    procedure Diag(ACode: TPasDiagCode; AStart, ALen: Integer);
    function CharAt(AIndex: Integer): Char; inline;
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
  // #12 = form feed, #26 = legacy DOS EOF marker
  Result := (ACh = ' ') or (ACh = #9) or (ACh = #13) or (ACh = #10) or
    (ACh = #12) or (ACh = #26) or (ACh = #11);
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
          if IsIdentStart(CharAt(FPos + 1)) then
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
  LStart, LLineStart, LProbe, LRun: Integer;
begin
  LStart := FPos;
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
    // Optional indentation before the closing quote run.
    LProbe := LLineStart;
    while (CharAt(LProbe) = ' ') or (CharAt(LProbe) = #9) do
      Inc(LProbe);
    LRun := 0;
    while CharAt(LProbe + LRun) = '''' do
      Inc(LRun);
    if LRun = AQuoteRun then
    begin
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
  // Fraction: '.' only when followed by a digit — guards '..' ranges and
  // member access on literals (42.ToString).
  if (CharAt(FPos) = '.') and IsDigit(CharAt(FPos + 1)) then
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
    Inc(FPos); // '&'
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
    FInAsm := True;
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
    if ((LCh = 'e') or (LCh = 'E')) and not IsIdentChar(CharAt(FPos - 1)) then
    begin
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
    Emit(tkAsmChunk, LStart)
  else if FPos >= FLen then
  begin
    FInAsm := False;
    Diag(dcUnterminatedAsm, LStart, 0);
  end;
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
    '^': Emit(tkCaret, LStart);
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
