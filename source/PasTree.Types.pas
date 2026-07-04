unit PasTree.Types;

{
  PasTree — core lexical types.

  Design (see README / object-pascal-spec Appendix B):
  - Tokens are small records in a contiguous array; text is never copied —
    a token is a (Start, Len) slice of the source string.
  - The lexer emits EVERY character of the source as part of exactly one
    token (trivia included), so concatenating all tokens reproduces the
    source byte-for-byte (full fidelity).
  - Reserved words (spec B.4.1) get dedicated kinds; directives (B.4.2) and
    predefined identifiers (B.4.3) are plain tkIdentifier — the parser
    interprets them by position, the resolver by scope.
}

interface

type
  TPasTokenKind = (
    tkUnknown,
    tkEndOfFile,

    // ---- trivia -----------------------------------------------------------
    tkWhitespace,        // runs of space/tab/CR/LF/FF/^Z
    tkCommentLine,       // // ...
    tkCommentBrace,      // { ... }
    tkCommentParen,      // (* ... *)
    tkDirective,         // {$...} or (*$...*)

    // ---- names & literals -------------------------------------------------
    tkIdentifier,
    tkIntLiteral,        // 123, $FF, %1010 (radix in flags)
    tkRealLiteral,       // 1.5, 2e10, 3.14e-2
    tkStringLiteral,     // '...' with '' escapes; single line
    tkMultilineString,   // '''...''' (Delphi 12+), whole block as one token
    tkControlChar,       // #13, #$0A, #%1010
    tkAsmChunk,          // opaque BASM text between trivia inside asm...end

    // ---- punctuation ------------------------------------------------------
    tkPlus, tkMinus, tkStar, tkSlash,
    tkEqual, tkNotEqual, tkLess, tkGreater, tkLessEqual, tkGreaterEqual,
    tkLParen, tkRParen, tkLBracket, tkRBracket,
    tkDot, tkDotDot, tkComma, tkColon, tkSemicolon,
    tkCaret, tkAt, tkAssign,

    // ---- reserved words (spec B.4.1) --------------------------------------
    // MUST remain in alphabetical order and aligned 1:1 with the KEYWORDS
    // table below: kind = tkAnd + keyword index.
    tkAnd, tkArray, tkAs, tkAsm, tkBegin, tkCase, tkClass, tkConst,
    tkConstructor, tkDestructor, tkDispinterface, tkDiv, tkDo, tkDownto,
    tkElse, tkEnd, tkExcept, tkExports, tkFile, tkFinalization, tkFinally,
    tkFor, tkFunction, tkGoto, tkIf, tkImplementation, tkIn, tkInherited,
    tkInitialization, tkInline, tkInterface, tkIs, tkLabel, tkLibrary,
    tkMod, tkNil, tkNot, tkObject, tkOf, tkOr, tkPacked, tkProcedure,
    tkProgram, tkProperty, tkRaise, tkRecord, tkRepeat, tkResourcestring,
    tkSet, tkShl, tkShr, tkString, tkThen, tkThreadvar, tkTo, tkTry,
    tkType, tkUnit, tkUntil, tkUses, tkVar, tkWhile, tkWith, tkXor
  );

  TPasTokenFlag = (
    tfAmpersand,       // identifier written with a leading & escape
    tfHex,             // integer literal with $ prefix
    tfBinary,          // integer/control literal with % prefix
    tfHasSeparator,    // numeric literal contains a digit separator _
    tfLegacyBracket,   // (. or .) written instead of [ or ]
    tfUnterminated     // string/comment/directive hit EOL/EOF before closing
  );
  TPasTokenFlags = set of TPasTokenFlag;

  TPasToken = record
    Kind: TPasTokenKind;
    Flags: TPasTokenFlags;
    Start: Integer;      // 0-based offset into the source (UTF-16 code units)
    Len: Integer;
    function EndPos: Integer; inline;
  end;

  TPasDiagCode = (
    dcInvalidChar,
    dcInvalidAmpersand,
    dcMissingHexDigits,
    dcMissingBinDigits,
    dcMissingControlCharValue,
    dcUnterminatedString,
    dcUnterminatedComment,
    dcUnterminatedDirective,
    dcUnterminatedMultilineString,
    dcUnterminatedAsm
  );

  TPasDiagnostic = record
    Code: TPasDiagCode;
    Start: Integer;
    Len: Integer;
  end;

  { The result of lexing one source file: the source text plus the full-
    fidelity token array, diagnostics, and a line map for offset->line:col. }
  TPasTokenStream = record
  public
    Source: string;
    Tokens: TArray<TPasToken>;
    Diagnostics: TArray<TPasDiagnostic>;
    LineStarts: TArray<Integer>;   // 0-based offset of each line start
    function TokenText(AIndex: Integer): string; overload;
    function TokenText(const AToken: TPasToken): string; overload;
    procedure OffsetToLineCol(AOffset: Integer; out ALine, ACol: Integer);
  end;

const
  { Spec B.4.1 — the 64 reserved words, alphabetical. Aligned with
    tkAnd..tkXor above. Directives (B.4.2) are intentionally absent. }
  KEYWORDS: array[0..63] of string = (
    'and', 'array', 'as', 'asm', 'begin', 'case', 'class', 'const',
    'constructor', 'destructor', 'dispinterface', 'div', 'do', 'downto',
    'else', 'end', 'except', 'exports', 'file', 'finalization', 'finally',
    'for', 'function', 'goto', 'if', 'implementation', 'in', 'inherited',
    'initialization', 'inline', 'interface', 'is', 'label', 'library',
    'mod', 'nil', 'not', 'object', 'of', 'or', 'packed', 'procedure',
    'program', 'property', 'raise', 'record', 'repeat', 'resourcestring',
    'set', 'shl', 'shr', 'string', 'then', 'threadvar', 'to', 'try',
    'type', 'unit', 'until', 'uses', 'var', 'while', 'with', 'xor'
  );

  DIAG_MESSAGES: array[TPasDiagCode] of string = (
    'Invalid character',
    '"&" must be followed by an identifier',
    'Hexadecimal digits expected after "$"',
    'Binary digits expected after "%"',
    'Character ordinal expected after "#"',
    'Unterminated string literal',
    'Unterminated comment',
    'Unterminated compiler directive',
    'Unterminated multiline string literal',
    'Unterminated asm block'
  );

{ True for trivia kinds — tokens the parser's visible stream skips. }
function IsTrivia(AKind: TPasTokenKind): Boolean; inline;

{ True for reserved-word kinds. }
function IsKeyword(AKind: TPasTokenKind): Boolean; inline;

{ Case-insensitive reserved-word lookup over a raw character slice.
  Returns tkIdentifier when the slice is not a reserved word.
  ASCII-only folding is correct here: all keywords are ASCII. }
function KeywordKind(AText: PChar; ALen: Integer): TPasTokenKind;

{ Builds the line-start offsets table for a source string. }
function BuildLineStarts(const ASource: string): TArray<Integer>;

implementation

function IsTrivia(AKind: TPasTokenKind): Boolean;
begin
  Result := AKind in [tkWhitespace, tkCommentLine, tkCommentBrace,
    tkCommentParen, tkDirective];
end;

function IsKeyword(AKind: TPasTokenKind): Boolean;
begin
  Result := AKind >= tkAnd;
end;

function KeywordKind(AText: PChar; ALen: Integer): TPasTokenKind;

  function CompareFolded(const AKeyword: string): Integer;
  var
    LIdx, LKwLen: Integer;
    LCh: Char;
  begin
    LKwLen := Length(AKeyword);
    LIdx := 0;
    while (LIdx < ALen) and (LIdx < LKwLen) do
    begin
      LCh := AText[LIdx];
      if (LCh >= 'A') and (LCh <= 'Z') then
        Inc(LCh, 32);  // ASCII fold
      if LCh <> AKeyword[LIdx + 1] then
        Exit(Ord(LCh) - Ord(AKeyword[LIdx + 1]));
      Inc(LIdx);
    end;
    Result := ALen - LKwLen;
  end;

var
  LLo, LHi, LMid, LCmp: Integer;
begin
  // All keywords are 2..14 chars long.
  if (ALen < 2) or (ALen > 14) then
    Exit(tkIdentifier);
  LLo := Low(KEYWORDS);
  LHi := High(KEYWORDS);
  while LLo <= LHi do
  begin
    LMid := (LLo + LHi) div 2;
    LCmp := CompareFolded(KEYWORDS[LMid]);
    if LCmp = 0 then
      Exit(TPasTokenKind(Ord(tkAnd) + LMid));
    if LCmp < 0 then
      LHi := LMid - 1
    else
      LLo := LMid + 1;
  end;
  Result := tkIdentifier;
end;

function BuildLineStarts(const ASource: string): TArray<Integer>;
var
  LCount, LPos, LLen: Integer;
begin
  LLen := Length(ASource);
  // First pass: count lines.
  LCount := 1;
  LPos := 1;
  while LPos <= LLen do
  begin
    case ASource[LPos] of
      #10: Inc(LCount);
      #13:
        begin
          Inc(LCount);
          if (LPos < LLen) and (ASource[LPos + 1] = #10) then
            Inc(LPos);
        end;
    end;
    Inc(LPos);
  end;
  SetLength(Result, LCount);
  // Second pass: record starts (0-based offsets).
  Result[0] := 0;
  LCount := 1;
  LPos := 1;
  while LPos <= LLen do
  begin
    case ASource[LPos] of
      #10:
        begin
          Result[LCount] := LPos;  // char AFTER the LF, as 0-based offset
          Inc(LCount);
        end;
      #13:
        begin
          if (LPos < LLen) and (ASource[LPos + 1] = #10) then
            Inc(LPos);
          Result[LCount] := LPos;
          Inc(LCount);
        end;
    end;
    Inc(LPos);
  end;
end;

{ TPasToken }

function TPasToken.EndPos: Integer;
begin
  Result := Start + Len;
end;

{ TPasTokenStream }

function TPasTokenStream.TokenText(AIndex: Integer): string;
begin
  Result := TokenText(Tokens[AIndex]);
end;

function TPasTokenStream.TokenText(const AToken: TPasToken): string;
begin
  Result := Copy(Source, AToken.Start + 1, AToken.Len);
end;

procedure TPasTokenStream.OffsetToLineCol(AOffset: Integer; out ALine,
  ACol: Integer);
var
  LLo, LHi, LMid: Integer;
begin
  // Binary search: greatest LineStarts[i] <= AOffset.
  LLo := 0;
  LHi := High(LineStarts);
  while LLo < LHi do
  begin
    LMid := (LLo + LHi + 1) div 2;
    if LineStarts[LMid] <= AOffset then
      LLo := LMid
    else
      LHi := LMid - 1;
  end;
  ALine := LLo + 1;                          // 1-based line
  ACol := AOffset - LineStarts[LLo] + 1;     // 1-based column
end;

end.
