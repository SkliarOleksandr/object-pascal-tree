unit PasTree.Types;

{
  PasTree - core lexical types.

  Design (see README / object-pascal-spec Appendix B):
  - Tokens are small records in a contiguous array; text is never copied -
    a token is a (Start, Len) slice of the source string.
  - The lexer emits EVERY character of the source as part of exactly one
    token (trivia included), so concatenating all tokens reproduces the
    source byte-for-byte (full fidelity).
  - Reserved words (spec B.4.1) get dedicated kinds; directives (B.4.2) and
    predefined identifiers (B.4.3) are plain tkIdentifier - the parser
    interprets them by position, the resolver by scope.
}

interface

type
  TPasTokenKind = (
    tkUnknown,
    tkEndOfFile,

    // ---- trivia -----------------------------------------------------------
    tkWhitespace,        // runs of space/tab/CR/LF/VT/FF/^Z
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
    dcUnterminatedAsm,
    // B.6.3: a content line of a multiline string whose indentation does not
    // start with the closing line's. dcc's E2657.
    dcInconsistentIndentChars
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
    { SameText(TokenText(AToken), AWord) without the copy - see
      SliceEqualsWord below. }
    function TokenTextEquals(const AToken: TPasToken;
      const AWord: string): Boolean;
    procedure OffsetToLineCol(AOffset: Integer; out ALine, ACol: Integer);
    function LineText(ALine: Integer): string;
  end;

const
  { Spec B.4.1 - the 64 reserved words, alphabetical. Aligned with
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

  { Spec B.4.2 - the FULL, exhaustive directive vocabulary (context-sensitive;
    legal as identifiers elsewhere), verbatim from object-pascal-spec's
    B-lexical-grammar.md (itself transcribed from the official RAD Studio
    docs). Lexically these are all plain tkIdentifier - the lexer cannot
    (and by design must not) special-case them; only the PARSER may, and only
    where the grammar actually looks for a specific word. This array is a
    vocabulary reference for consumers that want the complete word list (a
    syntax highlighter, autocomplete, ...) - it is NOT wired into any single
    grammar check. Not every word here is yet recognised by name at its
    grammatical position in TPasParser (e.g. package-level contains/requires,
    resident, exception-directive on/at) - that reflects unimplemented
    grammar, not a lexical gap; see ROUTINE_DIRECTIVE_WORDS/VISIBILITY_WORDS
    below for the narrower, grammar-scoped subsets the parser actually uses. }
  DIRECTIVE_WORDS: array[0..58] of string = (
    'absolute', 'abstract', 'assembler', 'at', 'automated', 'cdecl',
    'contains', 'default', 'delayed', 'dependency', 'deprecated', 'dispid',
    'dynamic', 'experimental', 'export', 'external', 'far', 'final',
    'forward', 'helper', 'implements', 'index', 'local', 'message', 'name',
    'near', 'nodefault', 'noreturn', 'on', 'operator', 'out', 'overload',
    'override', 'package', 'pascal', 'platform', 'private', 'protected',
    'public', 'published', 'read', 'readonly', 'reference', 'register',
    'reintroduce', 'requires', 'resident', 'safecall', 'sealed', 'static',
    'stdcall', 'stored', 'strict', 'unsafe', 'varargs', 'virtual', 'winapi',
    'write', 'writeonly'
  );

  { Grammar-scoped SUBSET of DIRECTIVE_WORDS actually checked by
    TPasParser.IsDirectiveWord: trailing method/procedure directives
    (binding, calling convention, hints, external linkage). Deliberately
    narrower than DIRECTIVE_WORDS - e.g. 'read'/'write'/'index' are real
    directives (property specifiers) but would be a GRAMMAR BUG if accepted
    here, since they're not valid trailing routine directives. }
  ROUTINE_DIRECTIVE_WORDS: array[0..29] of string = (
    'overload', 'virtual', 'dynamic', 'override', 'abstract', 'final',
    'reintroduce', 'static', 'assembler', 'cdecl', 'stdcall', 'register',
    'pascal', 'safecall', 'winapi', 'export', 'local', 'near', 'far',
    'varargs', 'unsafe', 'noreturn', 'deprecated', 'platform',
    'experimental', 'forward', 'delayed', 'message', 'dispid', 'external'
  );

  { Spec 11.2.1 - class-member visibility sections. Also a grammar-scoped
    subset of DIRECTIVE_WORDS; TPasParser.IsVisibilityWord is the authority. }
  VISIBILITY_WORDS: array[0..5] of string = (
    'private', 'protected', 'public', 'published', 'strict', 'automated'
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
    'Unterminated asm block',
    'Inconsistent indent characters'
  );

{ True for trivia kinds - tokens the parser's visible stream skips. }
function IsTrivia(AKind: TPasTokenKind): Boolean; inline;

{ True for reserved-word kinds. }
function IsKeyword(AKind: TPasTokenKind): Boolean; inline;

{ Case-insensitive reserved-word lookup over a raw character slice.
  Returns tkIdentifier when the slice is not a reserved word.
  ASCII-only folding is correct here: all keywords are ASCII. }
function KeywordKind(AText: PChar; ALen: Integer): TPasTokenKind;

{ Case-insensitive compare of a raw character slice against a word, without
  materializing a string - the non-allocating replacement for
  `SameText(TokenText(...), AWord)` on hot paths. ASCII-only folding, exactly
  CompareText's semantics (SameText folds only 'A'..'Z'), so the swap is
  behavior-preserving; every comparand in this codebase (keywords, directives,
  visibility words, separators) is ASCII. An &-escaped identifier keeps its
  '&' in the slice and so - deliberately, same as SameText on the copied
  text - never matches a bare word. }
function SliceEqualsWord(AText: PChar; ALen: Integer;
  const AWord: string): Boolean;

{ Builds the line-start offsets table for a source string. }
function BuildLineStarts(const ASource: string): TArray<Integer>;

{ Bytes currently ALLOCATED through the memory manager - token streams, node
  arenas, models, everything the analysis holds. Walked out of
  GetMemoryManagerState, so it is the process's own accounting rather than an
  OS working-set figure: it excludes the reserved-but-unused slack a working
  set includes, which is what makes it comparable run to run.

  Cheap enough to call at a report boundary (it sums ~60 small-block counters)
  and NOT on any hot path. A 32-bit host is the reason this is worth
  surfacing at all: the address space runs out around 2 GB (4 with
  LARGEADDRESSAWARE) long before a large project's closure is loaded, and an
  `EOutOfMemory` from that limit reads exactly like an analyzer defect unless
  the number is on screen next to it. }
function AllocatedBytes: UInt64;

{ AllocatedBytes as a human-readable string: 'MB' below a gigabyte, 'GB'
  above, one decimal either way. }
function MemoryText(ABytes: UInt64): string;

implementation

uses
  System.SysUtils;

function AllocatedBytes: UInt64;
var
  LState: TMemoryManagerState;
  LIdx: Integer;
begin
  // W1002 "specific to a platform": GetMemoryManagerState is the Windows
  // FastMM-shaped accounting, which is the only target this repo builds for.
  // Silenced locally rather than project-wide so a real portability warning
  // elsewhere still shows.
  {$WARN SYMBOL_PLATFORM OFF}
  GetMemoryManagerState(LState);
  {$WARN SYMBOL_PLATFORM ON}
  Result := UInt64(LState.TotalAllocatedMediumBlockSize) +
            UInt64(LState.TotalAllocatedLargeBlockSize);
  for LIdx := 0 to High(LState.SmallBlockTypeStates) do
    Result := Result +
      UInt64(LState.SmallBlockTypeStates[LIdx].UseableBlockSize) *
      UInt64(LState.SmallBlockTypeStates[LIdx].AllocatedBlockCount);
end;

function MemoryText(ABytes: UInt64): string;
begin
  if ABytes >= UInt64(1024) * 1024 * 1024 then
    Result := FormatFloat('0.0', ABytes / (1024 * 1024 * 1024)) + ' GB'
  else
    Result := FormatFloat('0.0', ABytes / (1024 * 1024)) + ' MB';
end;

function IsTrivia(AKind: TPasTokenKind): Boolean;
begin
  Result := AKind in [tkWhitespace, tkCommentLine, tkCommentBrace,
    tkCommentParen, tkDirective];
end;

function IsKeyword(AKind: TPasTokenKind): Boolean;
begin
  Result := AKind >= tkAnd;
end;

{ Keyword recognition, bucketed by FOLDED FIRST LETTER.

  KEYWORDS is alphabetical, so every word starting with a given letter occupies
  one contiguous range - GKwBucket caches those 26 ranges (built once, at unit
  init, from the table itself: no generated code to keep in sync, and KEYWORDS
  stays the single source of truth for both the words and their 1:1 alignment
  with the token-kind enum).

  Per identifier that costs: one fold, one range fetch, then for each candidate
  an integer LENGTH test before any character is touched. Average bucket is ~2.5
  words and the length test rejects most of them outright, so a typical
  identifier does one fold and a couple of compares.

  Measured on the flattened RTL+VCL+FMX corpus (665 units, 13.6M tokens): lexing
  it takes 478 ms with the previous 6-probe binary search, 404 ms with this, and
  387 ms with keyword recognition removed entirely. So the old cost was 91 ms,
  this is 17 ms, and the floor is 0 - this captures ~80% of what is there to get.
  Worth knowing the ceiling before reading more into it: the whole analysis is
  ~2960 ms, so ALL keyword recognition was 3.1% of it and this saves ~2.5%. The
  cross-model passes are ~70%; that is where analysis time actually lives. }
var
  GKwLo, GKwHi: array[0..25] of Integer;   // per 'a'..'z'; Hi < Lo when empty

procedure BuildKeywordBuckets;
var
  LIdx, LSlot: Integer;
begin
  for LIdx := 0 to 25 do
  begin
    GKwLo[LIdx] := 0;
    GKwHi[LIdx] := -1;
  end;
  for LIdx := Low(KEYWORDS) to High(KEYWORDS) do
  begin
    LSlot := Ord(KEYWORDS[LIdx][1]) - Ord('a');   // table is lower-case
    if (LSlot < 0) or (LSlot > 25) then
      Continue;
    if GKwHi[LSlot] < GKwLo[LSlot] then
      GKwLo[LSlot] := LIdx;
    GKwHi[LSlot] := LIdx;
  end;
end;

function KeywordKind(AText: PChar; ALen: Integer): TPasTokenKind;
var
  LIdx, LHi, LSlot, LPos: Integer;
  LCh: Char;
  LMatch: Boolean;
begin
  // All keywords are 2..14 chars long.
  if (ALen < 2) or (ALen > 14) then
    Exit(tkIdentifier);
  LCh := AText[0];
  if (LCh >= 'A') and (LCh <= 'Z') then
    Inc(LCh, 32);   // ASCII fold
  LSlot := Ord(LCh) - Ord('a');
  // Also the fast path for '_' and every non-ASCII start: no bucket, no work.
  if (LSlot < 0) or (LSlot > 25) then
    Exit(tkIdentifier);
  LIdx := GKwLo[LSlot];
  LHi := GKwHi[LSlot];
  while LIdx <= LHi do
  begin
    if Length(KEYWORDS[LIdx]) = ALen then
    begin
      // First char already matched by the bucket - compare from index 1.
      LMatch := True;
      for LPos := 1 to ALen - 1 do
      begin
        LCh := AText[LPos];
        if (LCh >= 'A') and (LCh <= 'Z') then
          Inc(LCh, 32);
        if LCh <> KEYWORDS[LIdx][LPos + 1] then
        begin
          LMatch := False;
          Break;
        end;
      end;
      if LMatch then
        Exit(TPasTokenKind(Ord(tkAnd) + LIdx));
    end;
    Inc(LIdx);
  end;
  Result := tkIdentifier;
end;

function SliceEqualsWord(AText: PChar; ALen: Integer;
  const AWord: string): Boolean;
var
  LIdx: Integer;
  LCh, LWCh: Char;
begin
  if ALen <> Length(AWord) then
    Exit(False);
  for LIdx := 0 to ALen - 1 do
  begin
    LCh := AText[LIdx];
    if (LCh >= 'A') and (LCh <= 'Z') then
      Inc(LCh, 32);
    LWCh := AWord[LIdx + 1];
    if (LWCh >= 'A') and (LWCh <= 'Z') then
      Inc(LWCh, 32);
    if LCh <> LWCh then
      Exit(False);
  end;
  Result := True;
end;

{ ONE pass over the source, not two.

  This used to count the lines and then record them, walking every character
  twice - and it is not a minor cost: measured over the flattened RTL+VCL+FMX
  corpus (665 files, 69.3M chars), stubbing this function out took lexing from
  404 ms to 304 ms. A quarter of lexing was here, more than all keyword
  recognition ever cost.

  Guessing the size instead is a good trade because a wrong guess costs a
  reallocation, not another pass over 69 MB. One line per ~20 characters fits
  Pascal source; the array grows geometrically from there and is trimmed once.

  B.1: CRLF, LF and CR EACH end a line, and CRLF is one break, not two. Every
  recorded value is the 0-based offset of the first character AFTER the break. }
function BuildLineStarts(const ASource: string): TArray<Integer>;
var
  LCount, LCap, LPos, LLen: Integer;
  LCh: Char;
begin
  LLen := Length(ASource);
  LCap := LLen div 20 + 8;
  SetLength(Result, LCap);
  Result[0] := 0;
  LCount := 1;
  LPos := 1;
  while LPos <= LLen do
  begin
    LCh := ASource[LPos];
    // Two direct compares rather than a `case` over every character: this loop
    // sees every char of every file, and only these two start a line.
    if (LCh = #10) or (LCh = #13) then
    begin
      if (LCh = #13) and (LPos < LLen) and (ASource[LPos + 1] = #10) then
        Inc(LPos);   // CRLF - one break
      if LCount = LCap then
      begin
        LCap := LCap * 2;
        SetLength(Result, LCap);
      end;
      Result[LCount] := LPos;
      Inc(LCount);
    end;
    Inc(LPos);
  end;
  SetLength(Result, LCount);
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

function TPasTokenStream.TokenTextEquals(const AToken: TPasToken;
  const AWord: string): Boolean;
begin
  // Pointer() sidesteps the refcount bump a PChar(Source) cast would keep
  // anyway; a zero-length token exits on the length test before any deref.
  Result := SliceEqualsWord(PChar(Pointer(Source)) + AToken.Start,
    AToken.Len, AWord);
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

// The raw text of one 1-based line, trailing CR/LF (whichever break BuildLine
// Starts recorded) stripped by TrimRight - Find References' snippet, and
// deliberately generic rather than folded into that one caller: nothing here
// is specific to what the text is used for.
function TPasTokenStream.LineText(ALine: Integer): string;
var
  LFrom, LToExcl: Integer;
begin
  Result := '';
  if (ALine < 1) or (ALine - 1 > High(LineStarts)) then
    Exit;
  LFrom := LineStarts[ALine - 1];
  if ALine <= High(LineStarts) then
    LToExcl := LineStarts[ALine]
  else
    LToExcl := Length(Source);
  Result := TrimRight(Copy(Source, LFrom + 1, LToExcl - LFrom));
end;

initialization
  BuildKeywordBuckets;   // see KeywordKind

end.
