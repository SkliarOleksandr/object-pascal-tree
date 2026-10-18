unit PasTree.WordIndex;

{ The implementation word index of light mode (docs/library-light-mode.md,
  "Full answers in light mode"): per source file, the set of identifiers it
  spells, as sorted 32-bit hashes of their folded spelling - and the names its
  `uses` clauses list and the files its include directives name.

  A DEMAND asks it one question - "can this unit's text name X at all?" - to
  decide which light units a query must have fully analyzed before it can
  answer as a full analysis would. So the scan errs the safe way everywhere:

  - it does not evaluate conditional compilation: a branch the build does not
    compile only ADDS words (and `uses` names), never hides one;
  - a hash collision only says "maybe" where the answer is "no" - one more
    unit promoted, never one missed;
  - comments, string literals and directives are skipped (an identifier in a
    comment names nothing), but a string or a comment the scanner cannot see
    the end of ends at the end of the line (a string) or of the text (a
    comment) - the compiler's own reading, so no code is skipped that it
    reads.

  Not a lexer: no tokens are kept, no positions, no conditionals - a demand
  needs a yes/no per (unit, name), and this is several times cheaper than
  lexing, which light mode exists not to do (TPasLexer.Tokenize's stop). }

interface

uses
  System.SysUtils;

type
  { Sorted, duplicate-free hashes (PasWordHash) of a text's identifiers. }
  TPasWordSet = TArray<Cardinal>;

  TPasWordScan = record
    { The identifiers spelled from the first `implementation` keyword on -
      or, when the text has none (a program, a package, an include file) or
      the caller asked for the whole text, every identifier. }
    Words: TPasWordSet;
    { True when Words starts at an `implementation` keyword. }
    FromImplementation: Boolean;
    { The unit names of the `uses` clauses (dotted, as written, `in` paths
      dropped) before the first `implementation` (a program's and a
      package's `uses` / `contains` too) and after it. Conditional entries
      are all there. }
    IntfUses, ImplUses: TArray<string>;
    { The arguments of every `$I` / `$INCLUDE` directive, as written
      (quotes dropped), in text order - resolving them is the caller's. }
    Includes: TArray<string>;
    { The identifiers inside compiler directives, over the same part of the
      text as Words - the names a `$DEFINE`, `$IFDEF` or `Defined()`
      spells, which Words leaves out with every other comment. }
    DirWords: TPasWordSet;
  end;

{ The FNV-1a hash of an identifier's folded spelling (PasFoldChar, `&`
  dropped) - the key of a TPasWordSet. }
function PasWordHash(const AName: string): Cardinal;

{ Scans AText. AWholeText: Words holds every identifier of the text, not
  only those from the first `implementation` on. }
function PasScanWords(const AText: string; AWholeText: Boolean): TPasWordScan;

{ Is the identifier hashed AHash in ASet? }
function PasWordSetHas(const ASet: TPasWordSet; AHash: Cardinal): Boolean;

{ ASet and AMore as one sorted set. }
function PasWordSetUnion(const ASet, AMore: TPasWordSet): TPasWordSet;

implementation

uses
  System.Generics.Collections,
  System.Generics.Defaults,
  PasTree.Types;

{$IFOPT Q+}{$DEFINE PT_RESTORE_Q}{$OVERFLOWCHECKS OFF}{$ENDIF}
function HashSlice(AText: PChar; ALen: Integer): Cardinal;
var
  LIdx: Integer;
begin
  Result := 2166136261;
  for LIdx := 0 to ALen - 1 do
    Result := (Result xor Cardinal(Ord(PasFoldChar(AText[LIdx])))) * 16777619;
end;
{$IFDEF PT_RESTORE_Q}{$OVERFLOWCHECKS ON}{$UNDEF PT_RESTORE_Q}{$ENDIF}

function PasWordHash(const AName: string): Cardinal;
var
  LStart: Integer;
begin
  LStart := 1;
  if (AName <> '') and (AName[1] = '&') then
    LStart := 2;
  if LStart > Length(AName) then
    Exit(HashSlice(nil, 0));
  Result := HashSlice(@AName[LStart], Length(AName) - LStart + 1);
end;

function PasWordSetHas(const ASet: TPasWordSet; AHash: Cardinal): Boolean;
var
  LLo, LHi, LMid: Integer;
begin
  LLo := 0;
  LHi := High(ASet);
  while LLo <= LHi do
  begin
    LMid := (LLo + LHi) shr 1;
    if ASet[LMid] = AHash then
      Exit(True);
    if ASet[LMid] < AHash then
      LLo := LMid + 1
    else
      LHi := LMid - 1;
  end;
  Result := False;
end;

function PasWordSetUnion(const ASet, AMore: TPasWordSet): TPasWordSet;
var
  LA, LB, LN: Integer;
begin
  if AMore = nil then
    Exit(ASet);
  if ASet = nil then
    Exit(AMore);
  SetLength(Result, Length(ASet) + Length(AMore));
  LA := 0;
  LB := 0;
  LN := 0;
  while (LA <= High(ASet)) or (LB <= High(AMore)) do
  begin
    if (LB > High(AMore)) or
       ((LA <= High(ASet)) and (ASet[LA] < AMore[LB])) then
    begin
      Result[LN] := ASet[LA];
      Inc(LA);
    end
    else if (LA > High(ASet)) or (AMore[LB] < ASet[LA]) then
    begin
      Result[LN] := AMore[LB];
      Inc(LB);
    end
    else
    begin
      Result[LN] := ASet[LA];
      Inc(LA);
      Inc(LB);
    end;
    Inc(LN);
  end;
  SetLength(Result, LN);
end;

type
  { The scanner's state over one text. }
  TWordScanner = record
    Text: string;
    Pos, Len: Integer;                   // 1-based cursor
    Words: TList<Cardinal>;
    DirWords: TList<Cardinal>;
    Collect: Boolean;                    // words are being recorded
    SeenImpl: Boolean;                   // past the first `implementation`
    Scan: TPasWordScan;
    function Ch(AOffset: Integer = 0): Char; inline;
    procedure SkipToLineEnd;
    procedure SkipBraceComment;
    procedure SkipParenComment;
    procedure SkipString;
    procedure Directive(AStart, AEnd: Integer);
    function NextWord(out AStart, ALen: Integer): Boolean;
    function SkipTrivia: Boolean;
    procedure ReadUses(AImpl: Boolean);
    procedure Run;
  end;

function TWordScanner.Ch(AOffset: Integer): Char;
begin
  if (Pos + AOffset >= 1) and (Pos + AOffset <= Len) then
    Result := Text[Pos + AOffset]
  else
    Result := #0;
end;

procedure TWordScanner.SkipToLineEnd;
begin
  while (Pos <= Len) and (Text[Pos] <> #10) and (Text[Pos] <> #13) do
    Inc(Pos);
end;

{ A directive's text between `{$` / `(*$` and the closing - an include's
  argument is recorded. `$I+` / `$I-` are the I/O-checks switch. }
procedure TWordScanner.Directive(AStart, AEnd: Integer);
var
  LName, LArg: string;
  LIdx: Integer;
begin
  if Collect then
  begin
    LIdx := AStart;
    while LIdx < AEnd do
      if PasIsIdentStart(Text[LIdx]) then
      begin
        LName := '';
        var LFrom := LIdx;
        while (LIdx < AEnd) and PasIsIdentChar(Text[LIdx]) do
          Inc(LIdx);
        DirWords.Add(HashSlice(@Text[LFrom], LIdx - LFrom));
      end
      else
        Inc(LIdx);
  end;
  LIdx := AStart;
  while (LIdx < AEnd) and CharInSet(Text[LIdx], ['A'..'Z', 'a'..'z', '_']) do
    Inc(LIdx);
  LName := UpperCase(Copy(Text, AStart, LIdx - AStart));
  if (LName <> 'I') and (LName <> 'INCLUDE') then
    Exit;
  LArg := Trim(Copy(Text, LIdx, AEnd - LIdx));
  if (LArg = '') or CharInSet(LArg[1], ['+', '-']) then
    Exit;
  if (Length(LArg) >= 2) and (LArg[1] = '''') then
  begin
    LIdx := LArg.IndexOf('''', 1);
    if LIdx > 0 then
      LArg := Copy(LArg, 2, LIdx - 1)
    else
      LArg := Copy(LArg, 2, MaxInt);
  end;
  // A compiler-supplied text (`$I %DATE%`) names no file.
  if (LArg <> '') and (LArg[1] <> '%') then
    Scan.Includes := Scan.Includes + [LArg];
end;

procedure TWordScanner.SkipBraceComment;
var
  LStart: Integer;
begin
  Inc(Pos);   // {
  LStart := Pos;
  while (Pos <= Len) and (Text[Pos] <> '}') do
    Inc(Pos);
  if (LStart <= Len) and (Text[LStart] = '$') then
    Directive(LStart + 1, Pos);
  if Pos <= Len then
    Inc(Pos);   // }
end;

procedure TWordScanner.SkipParenComment;
var
  LStart: Integer;
begin
  Inc(Pos, 2);   // (*
  LStart := Pos;
  while (Pos < Len) and not ((Text[Pos] = '*') and (Text[Pos + 1] = ')')) do
    Inc(Pos);
  if Pos >= Len then
  begin
    if (LStart <= Len) and (Text[LStart] = '$') then
      Directive(LStart + 1, Len + 1);
    Pos := Len + 1;
    Exit;
  end;
  if Text[LStart] = '$' then
    Directive(LStart + 1, Pos);
  Inc(Pos, 2);   // *)
end;

{ A string literal from its opening quote: '' is a quote inside it, and a
  line end ends it whatever (a literal cannot span lines). A text block -
  three quotes and nothing else to the line end (spec 7.1) - runs to the
  line whose first non-blank characters are three quotes. }
procedure TWordScanner.SkipString;
var
  LIdx: Integer;
  LBlock: Boolean;
begin
  if (Ch(1) = '''') and (Ch(2) = '''') then
  begin
    LIdx := Pos + 3;
    while (LIdx <= Len) and CharInSet(Text[LIdx], [' ', #9]) do
      Inc(LIdx);
    LBlock := (LIdx > Len) or CharInSet(Text[LIdx], [#10, #13]);
    if LBlock then
    begin
      Pos := LIdx;
      while Pos <= Len do
      begin
        // At a line start: blanks, then three quotes close the block.
        while (Pos <= Len) and CharInSet(Text[Pos], [#10, #13]) do
          Inc(Pos);
        while (Pos <= Len) and CharInSet(Text[Pos], [' ', #9]) do
          Inc(Pos);
        if (Pos + 2 <= Len) and (Text[Pos] = '''') and
           (Text[Pos + 1] = '''') and (Text[Pos + 2] = '''') then
        begin
          Inc(Pos, 3);
          Exit;
        end;
        SkipToLineEnd;
      end;
      Exit;
    end;
  end;
  Inc(Pos);   // the opening quote
  while Pos <= Len do
  begin
    case Text[Pos] of
      '''':
        if Ch(1) = '''' then
          Inc(Pos, 2)
        else
        begin
          Inc(Pos);
          Exit;
        end;
      #10, #13:
        Exit;
    else
      Inc(Pos);
    end;
  end;
end;

{ Skips whitespace, comments, strings, numbers, character codes and
  punctuation up to the next identifier, or to a `;` / `,` / `.` the uses
  reader wants to see (it then returns False with Pos ON that character).
  Returns True at an identifier start or at the end. }
function TWordScanner.SkipTrivia: Boolean;
var
  LCh: Char;
begin
  while Pos <= Len do
  begin
    LCh := Text[Pos];
    if PasIsIdentStart(LCh) or (LCh = '&') then
      Exit(True);
    case LCh of
      '{':
        SkipBraceComment;
      '(':
        if Ch(1) = '*' then
          SkipParenComment
        else
          Inc(Pos);
      '/':
        if Ch(1) = '/' then
          SkipToLineEnd
        else
          Inc(Pos);
      '''':
        SkipString;
      '#':
        begin
          // A character code: #13, #$0D.
          Inc(Pos);
          if Ch = '$' then
            Inc(Pos);
          while (Pos <= Len) and
                CharInSet(Text[Pos], ['0'..'9', 'A'..'F', 'a'..'f']) do
            Inc(Pos);
        end;
      '$':
        begin
          // A hexadecimal literal: its digits are no identifier.
          Inc(Pos);
          while (Pos <= Len) and
                CharInSet(Text[Pos], ['0'..'9', 'A'..'F', 'a'..'f', '_']) do
            Inc(Pos);
        end;
      '0'..'9':
        begin
          // A number, an exponent and digit separators included: `1e5`,
          // `1_000` - none of it is an identifier.
          while (Pos <= Len) and
                CharInSet(Text[Pos], ['0'..'9', '_', '.', 'e', 'E']) do
          begin
            if (Text[Pos] = '.') and (Ch(1) = '.') then
              Break;   // a range `1..N`
            if CharInSet(Text[Pos], ['e', 'E']) and
               not CharInSet(Ch(1), ['0'..'9', '+', '-']) then
              Break;
            if CharInSet(Text[Pos], ['e', 'E']) and
               CharInSet(Ch(1), ['+', '-']) then
              Inc(Pos);
            Inc(Pos);
          end;
        end;
      ';', ',', '.':
        Exit(False);
    else
      Inc(Pos);
    end;
  end;
  Result := True;
end;

{ The identifier at Pos (after SkipTrivia said so): its start and length,
  `&` dropped; Pos past it. Records it when words are being collected. }
function TWordScanner.NextWord(out AStart, ALen: Integer): Boolean;
begin
  Result := False;
  if Pos > Len then
    Exit;
  if Text[Pos] = '&' then
  begin
    Inc(Pos);
    if (Pos > Len) or not PasIsIdentStart(Text[Pos]) then
      Exit;
  end;
  if not PasIsIdentStart(Text[Pos]) then
    Exit;
  AStart := Pos;
  while (Pos <= Len) and PasIsIdentChar(Text[Pos]) do
    Inc(Pos);
  ALen := Pos - AStart;
  if Collect then
    Words.Add(HashSlice(@Text[AStart], ALen));
  Result := True;
end;

{ After `uses` / `contains`: dotted names separated by commas up to the
  semicolon, an `in 'path'` skipped. The names' words are words too. }
procedure TWordScanner.ReadUses(AImpl: Boolean);
var
  LName: string;
  LStart, LLen: Integer;
  LAfterDot: Boolean;

  procedure Flush;
  begin
    if LName <> '' then
      if AImpl then
        Scan.ImplUses := Scan.ImplUses + [LName]
      else
        Scan.IntfUses := Scan.IntfUses + [LName];
    LName := '';
  end;

begin
  LName := '';
  LAfterDot := False;
  while Pos <= Len do
  begin
    if not SkipTrivia then
    begin
      case Text[Pos] of
        ';':
          begin
            Flush;
            Inc(Pos);
            Exit;
          end;
        ',':
          begin
            Flush;
            LAfterDot := False;
          end;
        '.':
          LAfterDot := True;
      end;
      Inc(Pos);
      Continue;
    end;
    if not NextWord(LStart, LLen) then
    begin
      if Pos <= Len then
        Inc(Pos);
      Continue;
    end;
    if (LName <> '') and not LAfterDot then
    begin
      // `X in 'path'` - the word after the name is `in`. Any other word is a
      // name of its own: conditional alternatives need no comma between
      // them (`{$IFDEF A}mdb{$ELSE}DB{$ENDIF}, Next`), and stopping there
      // lost every entry after them.
      if SameText(Copy(Text, LStart, LLen), 'in') then
        Continue;
      Flush;
    end;
    if LAfterDot then
      LName := LName + '.' + Copy(Text, LStart, LLen)
    else
      LName := Copy(Text, LStart, LLen);
    LAfterDot := False;
  end;
  Flush;
end;

procedure TWordScanner.Run;
var
  LStart, LLen: Integer;
  LWord: string;
begin
  while Pos <= Len do
  begin
    if not SkipTrivia then
    begin
      Inc(Pos);
      Continue;
    end;
    if not NextWord(LStart, LLen) then
    begin
      if Pos <= Len then
        Inc(Pos);
      Continue;
    end;
    // Only the three keywords that steer the scan are compared.
    if (LLen = 4) or (LLen = 8) or (LLen = 14) then
    begin
      LWord := LowerCase(Copy(Text, LStart, LLen));
      if (LWord = 'uses') or (LWord = 'contains') then
        ReadUses(SeenImpl)
      else if (LWord = 'implementation') and not SeenImpl then
      begin
        SeenImpl := True;
        if not Collect then
        begin
          Collect := True;
          Scan.FromImplementation := True;
          Words.Add(HashSlice(@Text[LStart], LLen));
        end;
      end;
    end;
  end;
end;

// AList sorted, duplicates dropped.
function SortedSet(AList: TArray<Cardinal>): TArray<Cardinal>;
var
  LN: Integer;
begin
  TArray.Sort<Cardinal>(AList);
  LN := 0;
  for var LIdx := 0 to High(AList) do
    if (LN = 0) or (AList[LN - 1] <> AList[LIdx]) then
    begin
      AList[LN] := AList[LIdx];
      Inc(LN);
    end;
  SetLength(AList, LN);
  Result := AList;
end;

function PasScanWords(const AText: string; AWholeText: Boolean): TPasWordScan;
var
  LS: TWordScanner;
  LArr, LDir: TArray<Cardinal>;
begin
  LS := Default(TWordScanner);
  LS.Text := AText;
  LS.Pos := 1;
  LS.Len := Length(AText);
  LS.Collect := AWholeText;
  LS.Words := TList<Cardinal>.Create;
  LS.DirWords := TList<Cardinal>.Create;
  try
    LS.Run;
    // No `implementation` keyword: the whole text is the answer.
    if not LS.Collect then
    begin
      LS.Scan := Default(TPasWordScan);
      LS.Pos := 1;
      LS.SeenImpl := False;
      LS.Collect := True;
      LS.Words.Clear;
      LS.DirWords.Clear;
      LS.Run;
      LS.Scan.FromImplementation := False;
    end;
    LArr := SortedSet(LS.Words.ToArray);
    LDir := SortedSet(LS.DirWords.ToArray);
  finally
    LS.DirWords.Free;
    LS.Words.Free;
  end;
  Result := LS.Scan;
  Result.Words := LArr;
  Result.DirWords := LDir;
  if AWholeText then
    Result.FromImplementation := False;
end;

end.
