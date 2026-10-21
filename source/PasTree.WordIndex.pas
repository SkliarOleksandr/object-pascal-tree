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
    { The words a type HERITAGE can spell, over the same part of the text as
      Words (0.122.0): every identifier inside the parentheses after
      `class`, `object`, `record`, `interface` or `dispinterface` (`sealed`,
      `abstract`, `helper` between them allowed) - `class(Vcl.Controls.TControl,
      IFoo)` adds Vcl, Controls, TControl and IFoo - and the keyword itself
      where no parenthesis follows: an implicit root (`= class`,
      `= interface`), or `class function`, `of object`, the section keyword -
      the safe side. A hierarchy demand asks these instead of Words: a unit
      that only USES a class in its bodies declares nothing below it. }
    HeritWords: TPasWordSet;
    { The words a DECLARATION can spell, over the same part of the text as
      Words (0.124.0): every identifier followed by `=`, `:` (not `:=`),
      `,`, `)` or `<` - a type, a constant, a variable, a field, an enum
      value, a generic type's name, and on the way every argument and
      comparison - or by a compiler directive (the safe side: the branch
      may hide what follows), and the names after `procedure`, `function`,
      `constructor`, `destructor`, `property` and `operator`, each segment
      of a dotted one. A declaration search (DemandFind) asks these: a unit
      that only calls `Min` declares no Min. }
    DeclWords: TPasWordSet;
  end;

{ The FNV-1a hash of an identifier's folded spelling (PasFoldChar, `&`
  dropped) - the key of a TPasWordSet. }
function PasWordHash(const AName: string): Cardinal;

{ Scans AText. AWholeText: Words holds every identifier of the text, not
  only those from the first `implementation` on. }
function PasScanWords(const AText: string; AWholeText: Boolean): TPasWordScan;

{ The distinct identifiers AText spells in code - all of it, the `uses`
  names left out as in Words - each folded (PasFoldChar, `&` dropped): the
  spellings behind the hashes, which a wildcard needs (TPasSemaProject's
  vocabulary, 0.124.0). Distinct by spelling, not by hash: two spellings
  sharing a hash are both kept. }
function PasScanSpellings(const AText: string): TArray<string>;

{ APattern over AText, both folded: `*` any run of characters, `?` one. }
function PasWildMatch(const APattern, AText: string): Boolean;

{ Whether AText holds a wildcard (`*` or `?`). }
function PasIsWildPattern(const AText: string): Boolean;

{ Is the identifier hashed AHash in ASet? }
function PasWordSetHas(const ASet: TPasWordSet; AHash: Cardinal): Boolean;

{ ASet and AMore as one sorted set. }
function PasWordSetUnion(const ASet, AMore: TPasWordSet): TPasWordSet;

implementation

uses
  System.Math,
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

function PasWildMatch(const APattern, AText: string): Boolean;
var
  LP, LT, LStar, LMark: Integer;
begin
  LP := 1;
  LT := 1;
  LStar := 0;
  LMark := 0;
  while LT <= Length(AText) do
  begin
    if (LP <= Length(APattern)) and ((APattern[LP] = '?') or
       (APattern[LP] = AText[LT])) then
    begin
      Inc(LP);
      Inc(LT);
    end
    else if (LP <= Length(APattern)) and (APattern[LP] = '*') then
    begin
      LStar := LP;
      LMark := LT;
      Inc(LP);
    end
    else if LStar > 0 then
    begin
      LP := LStar + 1;
      Inc(LMark);
      LT := LMark;
    end
    else
      Exit(False);
  end;
  while (LP <= Length(APattern)) and (APattern[LP] = '*') do
    Inc(LP);
  Result := LP > Length(APattern);
end;

function PasIsWildPattern(const AText: string): Boolean;
begin
  Result := (System.Pos('*', AText) > 0) or (System.Pos('?', AText) > 0);
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
  { The words DeclWords' tracking of routine bodies reacts to. }
  TDeclKw = (dkNone, dkRoutine, dkProperty, dkBegin, dkInit, dkBlock, dkEnd,
    dkNoBody, dkImplementation, dkClass, dkTypeKw, dkPacked, dkOf, dkTo);

  { Where DeclWords' tracking stands: the routine bodies and the type
    bodies open, the routine headers whose body has not begun (their local
    declarations follow), the parameter lists' brackets. }
  TDeclDepths = record
    Body, Typ, Pend, Param: Integer;
  end;

  { A conditional's branches: the state at its `$IF`, and the branches
    seen so far combined on the safe side (TWordScanner.Conditional). }
  TDeclCond = record
    Start, Combined: TDeclDepths;
    HasCombined: Boolean;
  end;

  { The scanner's state over one text. }
  TWordScanner = record
    Text: string;
    Pos, Len: Integer;                   // 1-based cursor
    Words: TList<Cardinal>;
    DirWords: TList<Cardinal>;
    HeritWords: TList<Cardinal>;
    DeclWords: TList<Cardinal>;
    // The word before was a routine or property keyword, or a dotted
    // routine name's segment after one: this word is declared.
    AfterDeclKw: Boolean;
    // A routine's or a property's name (or a procedural type's keyword)
    // was just read: a `(` / `[` next opens its parameters (Depths.Param
    // counts the brackets), whose names DeclWords leaves out.
    ParamArm: Boolean;
    // DeclWords leaves out what a routine declares locally - in its body
    // and between its header and its body: Depths tracks the blocks past
    // the first `implementation` (an interface has no bodies), Conds the
    // conditional branches, PrevKw / PrevCol1 / LastPunct the word and
    // the punctuation before the current word (a header or a procedural
    // type? a type with a body?), TypeHead that the word read opens a
    // type's body unless what follows its heritage says otherwise.
    Depths: TDeclDepths;
    Conds: TArray<TDeclCond>;
    CondCount: Integer;
    PrevKw: TDeclKw;
    PrevCol1: Boolean;
    LastPunct: Char;
    TypeHead: Boolean;
    // SkipTrivia passed a lone `=` (not `:=`, `<=`, `>=`) and no other
    // punctuation since: the next name may be an alias's target.
    EqSeen: Boolean;
    Collect: Boolean;                    // words are being recorded
    // Inside a `uses` clause whose words would be recorded: Collect is off
    // for its names, but a directive between them still spells DirWords
    // (`uses A {$IFDEF MSWINDOWS}, B{$ENDIF};`).
    UsesCollect: Boolean;
    SeenImpl: Boolean;                   // past the first `implementation`
    Scan: TPasWordScan;
    // PasScanSpellings: the folded spellings, and per hash the first one's
    // index in Spell (another spelling with that hash is added too).
    Spell: TList<string>;
    SpellAt: TDictionary<Cardinal, Integer>;
    procedure AddSpelling(AStart, ALen: Integer; AHash: Cardinal);
    function KwOf(AStart, ALen: Integer): TDeclKw;
    function AtLineStart(AStart: Integer): Boolean;
    function NextIs(const AChars: TSysCharSet; const AWord: string): Boolean;
    procedure Declared(AStart, ALen: Integer; ADeclKw: Boolean);
    procedure Conditional(const AName: string);
    function Ch(AOffset: Integer = 0): Char; inline;
    procedure SkipToLineEnd;
    procedure SkipBraceComment;
    procedure SkipParenComment;
    procedure SkipString;
    procedure Directive(AStart, AEnd: Integer);
    function NextWord(out AStart, ALen: Integer): Boolean;
    function SkipTrivia: Boolean;
    procedure ReadUses(AImpl: Boolean);
    procedure ReadUsesNames(AImpl: Boolean);
    procedure SkipBlank;
    procedure ReadHeritage(AKeyStart, AKeyLen: Integer);
    function DeclFollows(out ADot: Boolean): Boolean;
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
  if Collect or UsesCollect then
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
  Conditional(LName);
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
  begin
    Scan.Includes := Scan.Includes + [LArg];
    // The included file may hold the rest of a routine - its body, its
    // `end`: DeclWords reads what follows as module level again (the safe
    // side - a local recorded, never a declaration missed).
    if SeenImpl then
    begin
      Depths.Body := 0;
      Depths.Pend := 0;
      Depths.Param := 0;
    end;
  end;
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
  EqSeen := False;
  while Pos <= Len do
  begin
    LCh := Text[Pos];
    if PasIsIdentStart(LCh) or (LCh = '&') then
      Exit(True);
    // A parameter list's brackets, and the punctuation before the next
    // word (DeclWords).
    if ((LCh = '(') and (Ch(1) <> '*')) or (LCh = '[') then
    begin
      if ParamArm or (Depths.Param > 0) then
        Inc(Depths.Param);
      ParamArm := False;
    end
    else if (LCh = ')') or (LCh = ']') then
    begin
      if Depths.Param > 0 then
        Dec(Depths.Param);
    end
    else if not CharInSet(LCh, [' ', #9, #10, #13, '{', '/']) then
      ParamArm := False;
    if not CharInSet(LCh, [' ', #9, #10, #13, '{']) and
       not ((LCh = '(') and (Ch(1) = '*')) and
       not ((LCh = '/') and (Ch(1) = '/')) then
      LastPunct := LCh;
    if LCh = '=' then
      EqSeen := (Pos = 1) or not CharInSet(Text[Pos - 1], [':', '<', '>'])
    else if not CharInSet(LCh, [' ', #9, #10, #13, '{', '(', '/']) then
      EqSeen := False;
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
  begin
    Words.Add(HashSlice(@Text[AStart], ALen));
    if Spell <> nil then
      AddSpelling(AStart, ALen, Words.Last);
  end;
  Result := True;
end;

procedure TWordScanner.AddSpelling(AStart, ALen: Integer; AHash: Cardinal);
var
  LAt, LIdx: Integer;
  LSame: Boolean;
  LText: string;
begin
  if SpellAt.TryGetValue(AHash, LAt) then
  begin
    LText := Spell[LAt];
    LSame := Length(LText) = ALen;
    LIdx := 0;
    while LSame and (LIdx < ALen) do
    begin
      LSame := LText[LIdx + 1] = PasFoldChar(Text[AStart + LIdx]);
      Inc(LIdx);
    end;
    if LSame then
      Exit;
  end
  else
    SpellAt.Add(AHash, Spell.Count);
  SetLength(LText, ALen);
  for LIdx := 0 to ALen - 1 do
    LText[LIdx + 1] := PasFoldChar(Text[AStart + LIdx]);
  Spell.Add(LText);
end;

{ After `uses` / `contains`: dotted names separated by commas up to the
  semicolon, an `in 'path'` skipped. The names are NOT words (since 0.122.0):
  a `uses` entry names no declaration - the demand reads the clauses from
  IntfUses / ImplUses and the models' UsesList - and a unit name spelled in a
  light unit's implementation `uses` made every lister of the unit look as
  if its body qualified a name with it (DemandUnitReferences). }
procedure TWordScanner.ReadUses(AImpl: Boolean);
var
  LCollect: Boolean;
begin
  LCollect := Collect;
  Collect := False;
  UsesCollect := LCollect;
  try
    ReadUsesNames(AImpl);
  finally
    Collect := LCollect;
    UsesCollect := False;
  end;
end;

procedure TWordScanner.ReadUsesNames(AImpl: Boolean);
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

{ Whitespace and comments (directives recorded as everywhere), up to the
  next token, whatever it is. }
procedure TWordScanner.SkipBlank;
begin
  while Pos <= Len do
    case Text[Pos] of
      ' ', #9, #10, #13:
        Inc(Pos);
      '{':
        SkipBraceComment;
      '(':
        if Ch(1) = '*' then
          SkipParenComment
        else
          Exit;
      '/':
        if Ch(1) = '/' then
          SkipToLineEnd
        else
          Exit;
    else
      Exit;
    end;
end;

{ After `class` / `object` / `interface` / `dispinterface` (the keyword at
  AKeyStart, already a word): `sealed` / `abstract` skipped, then the
  parenthesized heritage's identifiers - or, with no parenthesis, the
  keyword itself - go to HeritWords. Nested parentheses are counted; a `;`
  ends a heritage nobody closed. }
procedure TWordScanner.ReadHeritage(AKeyStart, AKeyLen: Integer);
var
  LStart, LLen, LDepth: Integer;
  LWord: string;
begin
  SkipBlank;
  while (Pos <= Len) and PasIsIdentStart(Text[Pos]) do
  begin
    LStart := Pos;
    while (Pos <= Len) and PasIsIdentChar(Text[Pos]) do
      Inc(Pos);
    LWord := LowerCase(Copy(Text, LStart, Pos - LStart));
    // `class helper(TParentHelper) for TFoo` inherits too.
    if (LWord <> 'sealed') and (LWord <> 'abstract') and
       (LWord <> 'helper') then
    begin
      // Something else follows (`class function`, `of object`): back to it,
      // for Run to read as a word.
      Pos := LStart;
      Break;
    end;
    Words.Add(HashSlice(@Text[LStart], Pos - LStart));
    SkipBlank;
  end;
  if (Pos > Len) or (Text[Pos] <> '(') then
  begin
    HeritWords.Add(HashSlice(@Text[AKeyStart], AKeyLen));
    Exit;
  end;
  Inc(Pos);   // (
  LDepth := 1;
  while (Pos <= Len) and (LDepth > 0) do
  begin
    SkipBlank;
    if Pos > Len then
      Break;
    case Text[Pos] of
      '(':
        begin
          Inc(LDepth);
          Inc(Pos);
        end;
      ')':
        begin
          Dec(LDepth);
          Inc(Pos);
        end;
      ';':
        Exit;
      '''':
        SkipString;
    else
      if NextWord(LStart, LLen) then
        HeritWords.Add(HashSlice(@Text[LStart], LLen))
      else
        Inc(Pos);
    end;
  end;
end;

{ Whether the identifier just read (Pos past it) reads as declared - the
  next token, past blanks and comments, is `=`, `:` but not `:=`, `,`, `)`
  or `<`, or a directive comes first; ADot: the next token is `.`. Reads
  ahead only: Pos, the word sets and the directives' records stay as they
  are (Run's SkipTrivia records them when it gets there). }
function TWordScanner.DeclFollows(out ADot: Boolean): Boolean;
var
  LAt: Integer;
begin
  ADot := False;
  LAt := Pos;
  while LAt <= Len do
    case Text[LAt] of
      ' ', #9, #10, #13:
        Inc(LAt);
      '{':
        begin
          if (LAt < Len) and (Text[LAt + 1] = '$') then
            Exit(True);
          while (LAt <= Len) and (Text[LAt] <> '}') do
            Inc(LAt);
          Inc(LAt);
        end;
      '(':
        if (LAt < Len) and (Text[LAt + 1] = '*') then
        begin
          if (LAt + 1 < Len) and (Text[LAt + 2] = '$') then
            Exit(True);
          Inc(LAt, 2);
          while (LAt < Len) and not ((Text[LAt] = '*') and
                (Text[LAt + 1] = ')')) do
            Inc(LAt);
          Inc(LAt, 2);
        end
        else
          Exit(False);
      '/':
        if (LAt < Len) and (Text[LAt + 1] = '/') then
        begin
          while (LAt <= Len) and (Text[LAt] <> #10) and (Text[LAt] <> #13) do
            Inc(LAt);
        end
        else
          Exit(False);
      '=', ',', ')', '<':
        Exit(True);
      ':':
        Exit((LAt = Len) or (Text[LAt + 1] <> '='));
      '.':
        begin
          ADot := (LAt = Len) or (Text[LAt + 1] <> '.');
          Exit(False);
        end;
    else
      Exit(False);
    end;
  Result := False;
end;

// The word at AStart (ALen characters) is AKw - lower-case ASCII, compared
// without building a string.
function WordIs(const AText: string; AStart, ALen: Integer;
  const AKw: string): Boolean;
var
  LCh: Char;
begin
  if ALen <> Length(AKw) then
    Exit(False);
  for var LIdx := 0 to ALen - 1 do
  begin
    LCh := AText[AStart + LIdx];
    if (LCh >= 'A') and (LCh <= 'Z') then
      LCh := Char(Ord(LCh) + 32);
    if LCh <> AKw[LIdx + 1] then
      Exit(False);
  end;
  Result := True;
end;

function TWordScanner.KwOf(AStart, ALen: Integer): TDeclKw;

  function Is_(const AKw: string): Boolean;
  begin
    Result := WordIs(Text, AStart, ALen, AKw);
  end;

begin
  Result := dkNone;
  case ALen of
    2:
      if Is_('of') then
        Result := dkOf
      else if Is_('to') then
        Result := dkTo;
    3:
      if Is_('end') then
        Result := dkEnd
      else if Is_('asm') then
        Result := dkBegin
      else if Is_('try') then
        Result := dkBlock;
    4:
      if Is_('case') then
        Result := dkBlock;
    5:
      if Is_('begin') then
        Result := dkBegin
      else if Is_('class') then
        Result := dkClass;
    6:
      if Is_('record') or Is_('object') then
        Result := dkTypeKw
      else if Is_('packed') then
        Result := dkPacked;
    7:
      if Is_('forward') then
        Result := dkNoBody;
    8:
      if Is_('function') or Is_('operator') then
        Result := dkRoutine
      else if Is_('property') then
        Result := dkProperty
      else if Is_('external') then
        Result := dkNoBody;
    9:
      if Is_('procedure') then
        Result := dkRoutine
      else if Is_('interface') then
        Result := dkTypeKw;
    10:
      if Is_('destructor') then
        Result := dkRoutine;
    11:
      if Is_('constructor') then
        Result := dkRoutine;
    12:
      if Is_('finalization') then
        Result := dkInit;
    13:
      if Is_('dispinterface') then
        Result := dkTypeKw;
    14:
      if Is_('implementation') then
        Result := dkImplementation
      else if Is_('initialization') then
        Result := dkInit;
  end;
end;

function TWordScanner.AtLineStart(AStart: Integer): Boolean;
begin
  Result := (AStart = 1) or CharInSet(Text[AStart - 1], [#10, #13]);
end;

{ Whether the next token, past blanks and comments, is one of AChars or the
  word AWord (lower case). Reads ahead only. }
function TWordScanner.NextIs(const AChars: TSysCharSet;
  const AWord: string): Boolean;
var
  LAt, LFrom: Integer;
begin
  LAt := Pos;
  while LAt <= Len do
    case Text[LAt] of
      ' ', #9, #10, #13:
        Inc(LAt);
      '{':
        begin
          while (LAt <= Len) and (Text[LAt] <> '}') do
            Inc(LAt);
          Inc(LAt);
        end;
      '/':
        if (LAt < Len) and (Text[LAt + 1] = '/') then
          while (LAt <= Len) and not CharInSet(Text[LAt], [#10, #13]) do
            Inc(LAt)
        else
          Exit(False);
    else
      if CharInSet(Text[LAt], AChars) then
        Exit(True);
      if not PasIsIdentStart(Text[LAt]) then
        Exit(False);
      LFrom := LAt;
      while (LAt <= Len) and PasIsIdentChar(Text[LAt]) do
        Inc(LAt);
      Exit(WordIs(Text, LFrom, LAt - LFrom, AWord));
    end;
  Result := False;
end;

{ DeclWords for the word just read (Collect on), and the tracking of what
  a routine declares locally - past the first `implementation`: a header
  (a routine keyword at module level that is no procedural type) has its
  local declarations up to its `begin` / `asm` (Pend), a body its blocks up
  to their `end` (Body); `forward` and `external` end a header with no
  body; a routine keyword at a line's start (or after `class` there) is at
  module level whatever the count says (a block left open across a
  conditional branch); a body's `begin` leaves any type body. Every guess
  errs toward recording a word: a local declaration recorded only makes a
  unit match a name it does not declare (one more unit made full). }
procedure TWordScanner.Declared(AStart, ALen: Integer; ADeclKw: Boolean);
var
  LDot, LTracked: Boolean;
  LKw: TDeclKw;
begin
  LTracked := SeenImpl;
  // `procedure(A: T)`: the keyword's list, not a name after it.
  ADeclKw := ADeclKw and (Depths.Param = 0);
  if ADeclKw or (DeclFollows(LDot) and (Depths.Param = 0) and
     not (LTracked and ((Depths.Body > 0) or (Depths.Pend > 0)))) then
    DeclWords.Add(Words.Last);
  if ADeclKw then
  begin
    DeclFollows(LDot);
    if LDot then
      AfterDeclKw := True
    else
      ParamArm := True;
  end;
  LKw := KwOf(AStart, ALen);
  case LKw of
    dkRoutine, dkProperty:
      begin
        AfterDeclKw := True;
        ParamArm := True;
        Depths.Param := 0;
        if (LKw = dkRoutine) and LTracked then
        begin
          // At a line's start: module level, a header of its own - or a
          // nested routine, whose outer header's locals are then recorded.
          if AtLineStart(AStart) or ((PrevKw = dkClass) and PrevCol1) then
          begin
            Depths.Body := 0;
            Depths.Pend := 0;
          end;
          if (Depths.Body = 0) and (Depths.Typ = 0) and
             not CharInSet(LastPunct, ['=', ':', '(', ',']) and
             not (PrevKw in [dkOf, dkTo]) then
            Inc(Depths.Pend);
        end;
      end;
    dkBegin:
      begin
        Depths.Param := 0;
        if LTracked then
          if Depths.Body > 0 then
            Inc(Depths.Body)
          else
          begin
            Depths.Body := 1;
            Depths.Typ := 0;
            if Depths.Pend > 0 then
              Dec(Depths.Pend);
          end;
      end;
    dkInit:
      if LTracked and (Depths.Body = 0) then
      begin
        Depths.Body := 1;
        Depths.Typ := 0;
        Depths.Pend := 0;
      end;
    dkBlock:
      if LTracked and (Depths.Body > 0) then
        Inc(Depths.Body);
    dkEnd:
      begin
        Depths.Param := 0;
        if Depths.Body > 0 then
          Dec(Depths.Body)
        else if Depths.Typ > 0 then
          Dec(Depths.Typ);
      end;
    dkNoBody:
      if (Depths.Body = 0) and (Depths.Pend > 0) then
        Dec(Depths.Pend);
    dkImplementation:
      Depths := Default(TDeclDepths);
    dkClass, dkTypeKw:
      // A type's body opens after its heritage, unless what follows says
      // otherwise (Run): after `=` or `:` (`packed`, `array of`), never an
      // `of object`.
      TypeHead := (CharInSet(LastPunct, ['=', ':']) or
        (PrevKw = dkPacked) or ((PrevKw = dkOf) and
        not WordIs(Text, AStart, ALen, 'object'))) and
        ((Depths.Body = 0) or WordIs(Text, AStart, ALen, 'record'));
  end;
  PrevKw := LKw;
  PrevCol1 := AtLineStart(AStart);
  LastPunct := #0;
end;

{ A conditional directive (its name upper-cased): DeclWords' tracking takes
  each branch from the state at the `$IF`, and leaves the `$ENDIF` with
  the branches combined toward recording - the fewest bodies, headers and
  parameter lists open, the most type bodies (inside one a routine keyword
  is a method, not a header). }
procedure TWordScanner.Conditional(const AName: string);

  function Combine(const A, B: TDeclDepths): TDeclDepths;
  begin
    Result.Body := Min(A.Body, B.Body);
    Result.Pend := Min(A.Pend, B.Pend);
    Result.Param := Min(A.Param, B.Param);
    Result.Typ := Max(A.Typ, B.Typ);
  end;

begin
  if (AName = 'IF') or (AName = 'IFDEF') or (AName = 'IFNDEF') or
     (AName = 'IFOPT') then
  begin
    if CondCount = Length(Conds) then
      SetLength(Conds, CondCount * 2 + 4);
    Conds[CondCount].Start := Depths;
    Conds[CondCount].HasCombined := False;
    Inc(CondCount);
  end
  else if CondCount = 0 then
    Exit
  else if (AName = 'ELSE') or (AName = 'ELSEIF') then
  begin
    if Conds[CondCount - 1].HasCombined then
      Conds[CondCount - 1].Combined := Combine(Conds[CondCount - 1].Combined,
        Depths)
    else
      Conds[CondCount - 1].Combined := Depths;
    Conds[CondCount - 1].HasCombined := True;
    Depths := Conds[CondCount - 1].Start;
  end
  else if (AName = 'ENDIF') or (AName = 'IFEND') then
  begin
    if Conds[CondCount - 1].HasCombined then
      Depths := Combine(Conds[CondCount - 1].Combined, Depths);
    Dec(CondCount);
  end;
end;

procedure TWordScanner.Run;
var
  LStart, LLen: Integer;
  LWord: string;
  LEq, LDeclKw: Boolean;
begin
  while Pos <= Len do
  begin
    if not SkipTrivia then
    begin
      LastPunct := Text[Pos];
      Inc(Pos);
      Continue;
    end;
    LEq := EqSeen;
    LDeclKw := AfterDeclKw;
    AfterDeclKw := False;
    if not NextWord(LStart, LLen) then
    begin
      if Pos <= Len then
        Inc(Pos);
      Continue;
    end;
    ParamArm := False;
    TypeHead := False;
    if Collect then
      Declared(LStart, LLen, LDeclKw);
    // The name after a lone `=` may be a type alias's target - `TBase =
    // TCustomEdit;`, `TBase = type Vcl.StdCtrls.TCustomEdit;` - which a
    // heritage `class(TBase)` then reaches: dotted, and past `type`, in
    // HeritWords too. A comparison `A = B` only adds a word.
    if Collect and LEq then
    begin
      HeritWords.Add(HashSlice(@Text[LStart], LLen));
      if SameText(Copy(Text, LStart, LLen), 'type') then
      begin
        SkipBlank;
        if NextWord(LStart, LLen) then
          HeritWords.Add(HashSlice(@Text[LStart], LLen));
      end;
      while (Pos < Len) and (Text[Pos] = '.') and
            PasIsIdentStart(Text[Pos + 1]) do
      begin
        Inc(Pos);
        if NextWord(LStart, LLen) then
          HeritWords.Add(HashSlice(@Text[LStart], LLen));
      end;
    end;
    // A type's heritage (HeritWords): only the keywords that start one.
    if Collect and ((LLen = 5) or (LLen = 6) or (LLen = 9) or
       (LLen = 13)) then
    begin
      LWord := LowerCase(Copy(Text, LStart, LLen));
      if (LWord = 'class') or (LWord = 'object') or (LWord = 'record') or
         (LWord = 'interface') or (LWord = 'dispinterface') then
      begin
        ReadHeritage(LStart, LLen);
        // A type with a body (DeclWords' tracking): not a forward
        // declaration, a short `class(TBase);`, a `class of`, a generic
        // constraint.
        if TypeHead and not NextIs([';', '>', ',', ')'], 'of') then
          if Depths.Body > 0 then
            Inc(Depths.Body)
          else
            Inc(Depths.Typ);
      end;
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
  LArr, LDir, LHerit, LDecl: TArray<Cardinal>;
begin
  LS := Default(TWordScanner);
  LS.Text := AText;
  LS.Pos := 1;
  LS.Len := Length(AText);
  LS.Collect := AWholeText;
  LS.Words := TList<Cardinal>.Create;
  LS.DirWords := TList<Cardinal>.Create;
  LS.HeritWords := TList<Cardinal>.Create;
  LS.DeclWords := TList<Cardinal>.Create;
  try
    LS.Run;
    // No `implementation` keyword: the whole text is the answer.
    if not LS.Collect then
    begin
      LS.Scan := Default(TPasWordScan);
      LS.Pos := 1;
      LS.SeenImpl := False;
      LS.Collect := True;
      LS.AfterDeclKw := False;
      LS.ParamArm := False;
      LS.Depths := Default(TDeclDepths);
      LS.CondCount := 0;
      LS.PrevKw := dkNone;
      LS.LastPunct := #0;
      LS.Words.Clear;
      LS.DirWords.Clear;
      LS.HeritWords.Clear;
      LS.DeclWords.Clear;
      LS.Run;
      LS.Scan.FromImplementation := False;
    end;
    LArr := SortedSet(LS.Words.ToArray);
    LDir := SortedSet(LS.DirWords.ToArray);
    LHerit := SortedSet(LS.HeritWords.ToArray);
    LDecl := SortedSet(LS.DeclWords.ToArray);
  finally
    LS.DeclWords.Free;
    LS.HeritWords.Free;
    LS.DirWords.Free;
    LS.Words.Free;
  end;
  Result := LS.Scan;
  Result.HeritWords := LHerit;
  Result.DeclWords := LDecl;
  Result.Words := LArr;
  Result.DirWords := LDir;
  if AWholeText then
    Result.FromImplementation := False;
end;

function PasScanSpellings(const AText: string): TArray<string>;
var
  LS: TWordScanner;
begin
  LS := Default(TWordScanner);
  LS.Text := AText;
  LS.Pos := 1;
  LS.Len := Length(AText);
  LS.Collect := True;
  LS.Words := TList<Cardinal>.Create;
  LS.DirWords := TList<Cardinal>.Create;
  LS.HeritWords := TList<Cardinal>.Create;
  LS.DeclWords := TList<Cardinal>.Create;
  LS.Spell := TList<string>.Create;
  LS.SpellAt := TDictionary<Cardinal, Integer>.Create;
  try
    LS.Run;
    Result := LS.Spell.ToArray;
  finally
    LS.SpellAt.Free;
    LS.Spell.Free;
    LS.DeclWords.Free;
    LS.HeritWords.Free;
    LS.DirWords.Free;
    LS.Words.Free;
  end;
end;

end.
