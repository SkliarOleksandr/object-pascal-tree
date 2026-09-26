program PasTreeXform;

{
  The source side of the compile-compare harness (tools\fidelity.ps1 is the
  driver): dcc judges the tree through the .dcu. A transformation that keeps
  the meaning FOR OUR TREE compiles to a byte-identical .dcu exactly when our
  tree agrees with dcc's, so nothing here needs an expectation file.

  Reads one unit with the inputs its compile gets (platform defines, -D
  defines, include paths) and writes a transformed copy of it AND of every
  include the preprocessor read into an output directory, plus sites.txt:
  what was changed where, and in which routine - the name the .dcu dump
  locates a difference by.

  Modes:
    t0  every file unchanged - the identity the harness must get right first
    ts  selftest: in each routine ONE deliberately WRONG regrouping of an
        operator chain the tree read left-associatively - `a - b + c` becomes
        `a - (b + c)`, `a div b * c` becomes `a div (b * c)`. Every unit with a
        site must compile to a different .dcu: a comparator that cannot see
        this cannot see anything.
    t0f the preprocessor's own decisions written into the text (plan T0'):
        every region it skipped and every conditional directive ($IF $IFDEF
        $IFNDEF $IFOPT $ELSEIF $ELSE $ENDIF $IFEND) blanked to spaces, every
        line break kept, so line numbers do not move - but for the few
        that stay as probes (see Flatten: dcc records what some of them
        consult, in any branch); any other directive kept where it was live
        and blanked where it was not; every include flattened the same way.
        dcc then compiles what PasTree saw - a branch taken differently
        shows as a different .dcu or a failed compile.
        sites.txt lists the preprocessor's diagnostics instead of edits: a
        guessed or unreadable $IF is where a DIFF is likeliest to come from.

  Usage:
    PasTreeXform <unit.pas> -mode:t0|ts|t0f -out:<dir> [-p:<platform>]
                 [-D:X;Y]... [-Undef:X;Y]... [-I:<dir>[;<dir>]]...
  -Undef takes names out of the define set after the platform's and -D's -
  with -D, a way to try another predefined set without rebuilding.
  -oracle (t0f): when a $IF of the unit asked what a bare preprocessor cannot
  answer (Declared, a constant, SizeOf), the stream flattened is the one a
  project analysis makes - its first pass answers compiler-provided names,
  its second asks the loaded units (the Declared/SizeOf oracle) - over the
  -S search paths plus the -I ones. That is the stream PasTree analyzes, and
  the only way to judge the oracle against dcc.

  Output, all of it under <dir>:
  - the files, mirrored under the common directory of the unit, its includes
    and the -I directories, so a relative `$I` include resolves as it did;
  - sites.txt, tab-separated: id, kind, operators, span
    `file(line,col)-(line,col)`, routine, the edit;
  - on stdout `main <path>` (the transformed unit), one `file <from> <to>`
    per file written, one `idir <from> <to>` per -I directory (the compile
    of the copy searches <to>), `sites <n>`; <from> and <to> tab-separated.
    t0f adds `copy <from> <to>` per extra instance copy of an include (see
    below), `argmap <new> <old>` per include argument rewritten to name one
    (the .dcu records each inclusion under its name as written: the driver
    maps these back before it compares) and one `flatten ...` line of
    counts.

  What a compile reads besides the text is kept too:
  - the source MTIME, copied as the exact FILETIME - dcc stores it in the
    .dcu, so a fresh timestamp alone makes a copy compile differently;
  - the ENCODING: an edit is spliced into the original BYTES at the byte
    offset of its token (the prefix re-counted in the file's own encoding),
    so no untouched byte is ever re-encoded. A file whose bytes do not
    round-trip through its decoding (a lenient U+FFFD recovery) is refused.

  A file included more than once takes no ts edit (one text serves several
  preprocessing states); a site that would need one is dropped and counted.
  t0f flattens every inclusion on its own, since each has its own state: the
  inclusions whose flattened texts agree share the file, and each different
  text is written to a copy in a `~<n>` directory beside it, its `$I`
  argument rewritten to name that copy.

  Which directive was live, t0f asks the preprocessor itself rather than
  re-deciding it: a second run over the same files, with a marker comment
  before every directive and after every conditional, reports each marker in
  a region it skipped - a comment decides nothing, so the run decides as the
  first did. Checked, not assumed: the two runs must read the same files and
  see the same visible tokens, every marker must come back, and the markers
  must agree with the preprocessor's own records (includes followed, define
  mentions) and with a rebuilt conditional stack.
}

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Dcu in '..\source\PasTree.Dcu.pas',
  PasTree.Dcu.Source in '..\source\PasTree.Dcu.Source.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.Sema.Diagnostics in '..\source\PasTree.Sema.Diagnostics.pas',
  PasTree.Sema.Model in '..\source\PasTree.Sema.Model.pas',
  PasTree.Sema.Builtins in '..\source\PasTree.Sema.Builtins.pas',
  PasTree.Sema.Resolver in '..\source\PasTree.Sema.Resolver.pas',
  PasTree.Sema.Project in '..\source\PasTree.Sema.Project.pas',
  PasTree.Version in '..\source\PasTree.Version.pas';

type
  TXformMode = (xmT0, xmTS, xmT0F);

const
  cModeNames: array[TXformMode] of string = ('t0', 'ts', 't0f');

type
  // One text insertion into one file, or a replacement of Len characters
  // there. Order breaks ties at the same offset: a closing paren must land
  // before an opening one there (`c)(d`), which is what T1 will need when
  // many parens meet; TS never puts two at one spot, and t0f's replacements
  // never overlap.
  TEdit = record
    FileId: Integer;
    Offset: Integer;     // UTF-16 offset in the file's decoded text
    Len: Integer;        // characters replaced from Offset; 0 inserts
    Order: Integer;
    Text: string;
  end;

  TSite = record
    Kind: string;
    Ops: string;
    Span: string;
    Routine: string;
    Edit: string;
  end;

var
  GPre: TPasPreprocessed;
  GTree: TPasTree;
  GEdits: TList<TEdit>;
  GSites: TList<TSite>;
  GIncludedTwice: TArray<Boolean>;   // per FileId: its path occurs twice
  GDropped: Integer;                 // sites refused for an include used twice
  GUnitName: string;
  // t0f: per FileId, the file it is written as - its own path, or an
  // instance copy's (see Flatten) - and the counts of the `flatten` line.
  GOutName: TArray<string>;
  GIsCopy: TArray<Boolean>;
  GFlatStats: string;
  // t0f: every include argument rewritten to name an instance copy, the new
  // spelling -> the one it replaced, quotes off - the .dcu records each
  // inclusion under its name as written, so the driver maps them back.
  GArgMap: TDictionary<string, string>;

function VisOffset(AVis: Integer; out AFileId: Integer): Integer;
var
  LTok: TPasVisibleToken;
begin
  LTok := GPre.Visible[AVis];
  AFileId := LTok.FileId;
  Result := GPre.Files[LTok.FileId].Tokens[LTok.TokenIndex].Start;
end;

function VisEnd(AVis: Integer; out AFileId: Integer): Integer;
var
  LTok: TPasVisibleToken;
begin
  LTok := GPre.Visible[AVis];
  AFileId := LTok.FileId;
  Result := GPre.Files[LTok.FileId].Tokens[LTok.TokenIndex].EndPos;
end;

// `File.pas(12,5)` for a file offset - 1-based, the dcc message form.
function PosText(AFileId, AOffset: Integer): string;
var
  LLine, LCol: Integer;
begin
  GPre.Files[AFileId].OffsetToLineCol(AOffset, LLine, LCol);
  Result := Format('%s(%d,%d)', [TPath.GetFileName(GPre.FileNames[AFileId]),
    LLine, LCol]);
end;

function SpanText(AFirstVis, ALastVis: Integer): string;
var
  LFile, LEndFile, LLine, LCol: Integer;
  LStart, LEnd: Integer;
begin
  LStart := VisOffset(AFirstVis, LFile);
  LEnd := VisEnd(ALastVis, LEndFile);
  Result := PosText(LFile, LStart);
  // The LAST character's position, inclusive, like an editor selection.
  GPre.Files[LEndFile].OffsetToLineCol(LEnd - 1, LLine, LCol);
  Result := Result + Format('-(%d,%d)', [LLine, LCol]);
end;

function Child(ANode, AIndex: Integer): Integer;
begin
  Result := GTree.Nodes[ANode].FirstChild;
  while (Result <> NIL_NODE) and (AIndex > 0) do
  begin
    Result := GTree.Nodes[Result].NextSibling;
    Dec(AIndex);
  end;
end;

function OpText(ANode: Integer): string;
begin
  Result := LowerCase(GPre.VisibleText(GTree.Nodes[ANode].Aux));
end;

{ A routine's name as the .dcu spells it: the leading name idents of the
  header, dotted (`TFoo.Bar`, `TOuter.TInner.Bar`), generic parameter lists
  left out - the driver compares names without them. A name part after the
  first follows a dot: the result type of a routine with no parameter list,
  `function TFoo.Get: TBar`, is the next ident child too. }
function RoutineName(ARoutine: Integer): string;
var
  LChild, LVis: Integer;
begin
  Result := '';
  LChild := GTree.Nodes[ARoutine].FirstChild;
  while LChild <> NIL_NODE do
  begin
    case GTree.Nodes[LChild].Kind of
      nkIdent:
        begin
          LVis := GTree.Nodes[LChild].FirstToken;
          if Result <> '' then
          begin
            if (LVis < 1) or (GPre.VisibleToken(LVis - 1).Kind <> tkDot) then
              Break;
            Result := Result + '.';
          end;
          // `&Type` names a routine `Type`: the ampersand is no part of it.
          Result := Result + GTree.NodeText(LChild).TrimLeft(['&']);
        end;
      nkGenericParams, nkTypeArgs:
        ;
    else
      Break;
    end;
    LChild := GTree.Nodes[LChild].NextSibling;
  end;
end;

{ The unit's name as written in its header, `PasTree.Ast` - the name of the
  routine a .dcu gives the initialization section's code. }
function HeaderName: string;
var
  LVis: Integer;
begin
  // ident { . ident } - a hint directive after it (`unit U platform;`) is
  // not part of the name.
  Result := '';
  LVis := GTree.Nodes[0].FirstToken + 1;
  while LVis <= High(GPre.Visible) do
  begin
    if GPre.VisibleToken(LVis).Kind <> tkIdentifier then
      Break;
    Result := Result + GPre.VisibleText(LVis).TrimLeft(['&']);
    if (LVis + 1 > High(GPre.Visible)) or
       (GPre.VisibleToken(LVis + 1).Kind <> tkDot) then
      Break;
    Result := Result + '.';
    Inc(LVis, 2);
  end;
end;

procedure AddEdit(AVis: Integer; AAfter: Boolean; AOrder: Integer;
  const AText: string);
var
  LEdit: TEdit;
begin
  if AAfter then
    LEdit.Offset := VisEnd(AVis, LEdit.FileId)
  else
    LEdit.Offset := VisOffset(AVis, LEdit.FileId);
  LEdit.Len := 0;
  LEdit.Order := AOrder;
  LEdit.Text := AText;
  GEdits.Add(LEdit);
end;

{ TS: the site class of binary op P, 0 when it is not a candidate. P reads
  (A op1 B) op2 R; the wrong grouping is A op1 (B op2 R). Only pairs where
  that is a DIFFERENT computation for every operand type the original allows,
  and still type-checks: op1 is the non-associative one. `(a + b) - c` ->
  `a + (b - c)` is the same integer, and `and`/`or` chains short-circuit to
  the same jumps, so both could compile identically and prove nothing. }
function SiteClass(AP: Integer): Integer;
var
  LL: Integer;
  LOp1, LOp2: string;
begin
  Result := 0;
  LL := Child(AP, 0);
  if (LL = NIL_NODE) or (GTree.Nodes[LL].Kind <> nkBinaryOp) or
     (Child(AP, 1) = NIL_NODE) or (Child(LL, 1) = NIL_NODE) then
    Exit;
  LOp1 := OpText(LL);
  LOp2 := OpText(AP);
  if (LOp1 = '-') and ((LOp2 = '+') or (LOp2 = '-')) then
    Result := 1
  else if (((LOp1 = 'div') or (LOp1 = 'mod')) and
           ((LOp2 = '*') or (LOp2 = 'div') or (LOp2 = 'mod'))) or
          ((LOp1 = '/') and ((LOp2 = '*') or (LOp2 = '/'))) or
          ((LOp1 = '*') and ((LOp2 = 'div') or (LOp2 = 'mod'))) then
    Result := 2
  else if ((LOp1 = 'shl') or (LOp1 = 'shr')) and
          ((LOp2 = 'shl') or (LOp2 = 'shr')) then
    Result := 3;
end;

{ The candidate operator chains of one routine's statements, source order.
  Not descended: an anonymous method (compiled as a routine of its own, under
  a compiler-made name), case labels (a regrouped label can collide with
  another one and stop the compile), asm. }
procedure CollectCandidates(ANode: Integer; ACandidates: TList<Integer>);
var
  LChild: Integer;
begin
  case GTree.Nodes[ANode].Kind of
    nkAnonMethod, nkRoutine, nkCaseLabels, nkAsmStmt:
      Exit;
    nkBinaryOp:
      if SiteClass(ANode) > 0 then
        ACandidates.Add(ANode);
  end;
  LChild := GTree.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    CollectCandidates(LChild, ACandidates);
    LChild := GTree.Nodes[LChild].NextSibling;
  end;
end;

procedure PickSite(ABlock: Integer; const ARoutine: string);
var
  LCandidates: TList<Integer>;
  LBest, LClass, LCand, LP, LB, LR: Integer;
  LFirst, LLast, LFileA, LFileB: Integer;
  LSite: TSite;
begin
  LCandidates := TList<Integer>.Create;
  try
    CollectCandidates(ABlock, LCandidates);
    // The best class first, the first in source order within it.
    LP := NIL_NODE;
    LBest := MaxInt;
    for LCand in LCandidates do
    begin
      LClass := SiteClass(LCand);
      if LClass < LBest then
      begin
        LBest := LClass;
        LP := LCand;
      end;
    end;
    if LP = NIL_NODE then
      Exit;
    LB := Child(Child(LP, 0), 1);
    LR := Child(LP, 1);
    LFirst := GTree.NodeLeftmostVis(LB);
    LLast := GTree.Nodes[LR].LastToken;
    VisOffset(LFirst, LFileA);
    VisOffset(LLast, LFileB);
    if (LFileA <> LFileB) or GIncludedTwice[LFileA] then
    begin
      Inc(GDropped);
      Exit;
    end;
    AddEdit(LFirst, False, 1, '(');
    AddEdit(LLast, True, 0, ')');
    LSite.Kind := GTree.KindName(GTree.Nodes[LP].Kind);
    LSite.Ops := OpText(Child(LP, 0)) + '/' + OpText(LP);
    LSite.Span := SpanText(GTree.NodeLeftmostVis(LP), GTree.Nodes[LP].LastToken);
    LSite.Routine := ARoutine;
    LSite.Edit := Format('( at %s, ) after %s', [
      SpanText(LFirst, LFirst), SpanText(LLast, LLast)]);
    GSites.Add(LSite);
  finally
    LCandidates.Free;
  end;
end;

{ Every routine with a body, nested ones named `Outer.Inner` (the name the
  .dcu dump gives an embedded routine under its parent), plus the
  initialization and finalization sections under the names dcc gives their
  code. }
procedure VisitRoutines(ANode: Integer; const AOuter: string);
var
  LChild, LBodyChild: Integer;
  LName: string;
begin
  case GTree.Nodes[ANode].Kind of
    nkAnonMethod:
      Exit;
    nkRoutine:
      begin
        LName := RoutineName(ANode);
        if AOuter <> '' then
          LName := AOuter + '.' + LName;
        LChild := GTree.Nodes[ANode].FirstChild;
        while LChild <> NIL_NODE do
        begin
          if GTree.Nodes[LChild].Kind = nkRoutineBody then
          begin
            LBodyChild := GTree.Nodes[LChild].FirstChild;
            while LBodyChild <> NIL_NODE do
            begin
              case GTree.Nodes[LBodyChild].Kind of
                nkRoutine:
                  VisitRoutines(LBodyChild, LName);
                nkBlock:
                  PickSite(LBodyChild, LName);
              end;
              LBodyChild := GTree.Nodes[LBodyChild].NextSibling;
            end;
          end;
          LChild := GTree.Nodes[LChild].NextSibling;
        end;
        Exit;
      end;
    nkInitSec:
      begin
        PickSite(ANode, GUnitName);
        Exit;
      end;
    nkFinalSec:
      begin
        PickSite(ANode, 'Finalization');
        Exit;
      end;
  end;
  LChild := GTree.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    VisitRoutines(LChild, AOuter);
    LChild := GTree.Nodes[LChild].NextSibling;
  end;
end;

{ t0f: the word of directive token AText, upper-cased, read the way
  TPasPreprocessor.HandleDirective reads it - the body between the
  delimiters, trimmed, then the run of LETTERS at its start (`IFDEF_X` is
  IFDEF with the argument `_X`, there and here); AWordStart is its 0-based
  offset in AText. }
function DirectiveWord(const AText: string; out AWordStart: Integer): string;
var
  LFirst, LLast, LName: Integer;
begin
  LFirst := 1;
  LLast := Length(AText);
  if (LLast >= 2) and (AText[1] = '{') then
  begin
    LFirst := 3;                                   // after the brace and $
    if (LLast >= 3) and (AText[LLast] = '}') then
      Dec(LLast);
  end
  else if (LLast >= 3) and (AText[1] = '(') then
  begin
    LFirst := 4;                                   // after paren, star, $
    if (LLast >= 5) and (AText[LLast - 1] = '*') and (AText[LLast] = ')') then
      Dec(LLast, 2);
  end;
  while (LFirst <= LLast) and (AText[LFirst] <= ' ') do
    Inc(LFirst);
  LName := LFirst;
  while (LName <= LLast) and CharInSet(AText[LName], ['A'..'Z', 'a'..'z']) do
    Inc(LName);
  AWordStart := LFirst - 1;
  Result := UpperCase(Copy(AText, LFirst, LName - LFirst));
end;

// The text after the word of directive token AText, trimmed, without the
// closing delimiter: `!FOO` for an $ENDIF written with that comment.
function DirectiveTrail(const AText: string): string;
var
  LStart, LEnd: Integer;
begin
  DirectiveWord(AText, LStart);
  LStart := LStart + 1;
  while (LStart <= Length(AText)) and
        CharInSet(AText[LStart], ['A'..'Z', 'a'..'z']) do
    Inc(LStart);
  LEnd := Length(AText);
  if AText.StartsWith('(') then
  begin
    if AText.EndsWith('*)') then
      Dec(LEnd, 2);
  end
  else if AText.EndsWith('}') then
    Dec(LEnd);
  Result := Trim(Copy(AText, LStart, LEnd - LStart + 1));
end;

{ The words that dispatch handles as conditionals. A copy of its list on
  purpose: a word read differently here than there shows up as a DIFF, it
  cannot hide one. }
function IsConditionalWord(const AWord: string): Boolean;
begin
  Result := (AWord = 'IF') or (AWord = 'IFDEF') or (AWord = 'IFNDEF') or
    (AWord = 'IFOPT') or (AWord = 'ELSEIF') or (AWord = 'ELSE') or
    (AWord = 'ENDIF') or (AWord = 'IFEND');
end;

const
  cMarkBefore = '{PTXM';
  cMarkAfter = '{PTXA';

// The marker the liveness run puts before (AAfter = False) or after token
// ATok of distinct file APath: a brace comment no real unit spells. A comment
// decides nothing and parses to nothing - the -oracle run parses the unit, an
// identifier would break its uses clause - and a comment inside asm is still
// a comment. Whether the run skipped the region it lies in is the answer.
function MarkerText(APath, ATok: Integer; AAfter: Boolean): string;
const
  cPrefix: array[Boolean] of string = (cMarkBefore, cMarkAfter);
begin
  Result := Format('%s%d_%d}', [cPrefix[AAfter], APath, ATok]);
end;

function ParseMarker(const AText: string; out APath, ATok: Integer;
  out AAfter: Boolean): Boolean;
var
  LSep: Integer;
begin
  Result := False;
  if AText.StartsWith(cMarkBefore) then
    AAfter := False
  else if AText.StartsWith(cMarkAfter) then
    AAfter := True
  else
    Exit;
  LSep := Pos('_', AText);
  if (LSep = 0) or not AText.EndsWith('}') then
    Exit;
  Result := TryStrToInt(Copy(AText, Length(cMarkBefore) + 1,
    LSep - Length(cMarkBefore) - 1), APath) and
    TryStrToInt(Copy(AText, LSep + 1, Length(AText) - LSep - 1), ATok);
end;

// ASource[AOffset..AOffset+ALen) with every character but CR and LF turned
// into a space: the line count, and so every later line number, stays.
function Blank(const ASource: string; AOffset, ALen: Integer): string;
var
  LIdx: Integer;
begin
  Result := Copy(ASource, AOffset + 1, ALen);
  for LIdx := 1 to Length(Result) do
    if (Result[LIdx] <> #13) and (Result[LIdx] <> #10) then
      Result[LIdx] := ' ';
end;

function MakeEdit(AFileId, AOffset, ALen: Integer; const AText: string): TEdit;
begin
  Result.FileId := AFileId;
  Result.Offset := AOffset;
  Result.Len := ALen;
  Result.Order := 0;
  Result.Text := AText;
end;

// AText with AEdits applied - sorted by offset, none overlapping.
function ApplyEdits(const AText: string; AEdits: TList<TEdit>): string;
var
  LSB: TStringBuilder;
  LPos: Integer;
  LEdit: TEdit;
begin
  LSB := TStringBuilder.Create;
  try
    LPos := 0;
    for LEdit in AEdits do
    begin
      LSB.Append(AText, LPos, LEdit.Offset - LPos);
      LSB.Append(LEdit.Text);
      LPos := LEdit.Offset + LEdit.Len;
    end;
    LSB.Append(AText, LPos, Length(AText) - LPos);
    Result := LSB.ToString;
  finally
    LSB.Free;
  end;
end;

// The argument of include directive AText (`$I x` in braces, or `INCLUDE x`
// in parens and stars): its offset in AText (0-based) and length, the
// delimiters and blanks outside.
procedure IncludeArg(const AText: string; out AStart, ALen: Integer);
var
  LFirst, LLast: Integer;
begin
  if AText.StartsWith('(') then
  begin
    LFirst := 4;
    LLast := Length(AText) - 2;
  end
  else
  begin
    LFirst := 3;
    LLast := Length(AText) - 1;
  end;
  while (LFirst <= LLast) and (AText[LFirst] <= ' ') do
    Inc(LFirst);
  while (LFirst <= LLast) and CharInSet(AText[LFirst], ['A'..'Z', 'a'..'z']) do
    Inc(LFirst);
  while (LFirst <= LLast) and (AText[LFirst] <= ' ') do
    Inc(LFirst);
  while (LLast >= LFirst) and (AText[LLast] <= ' ') do
    Dec(LLast);
  AStart := LFirst - 1;
  ALen := LLast - LFirst + 1;
end;

// Include argument AArg made to name the instance copy ACopy beside the file
// it named: `~2\` put before the file-name part, quotes kept.
function CopyArg(const AArg: string; ACopy: Integer): string;
var
  LName: string;
  LQuoted: Boolean;
  LSlash, LIdx: Integer;
begin
  LName := AArg;
  LQuoted := (Length(LName) >= 2) and (LName[1] = '''') and
    (LName[Length(LName)] = '''');
  if LQuoted then
    LName := Copy(LName, 2, Length(LName) - 2);
  LSlash := 0;
  for LIdx := 1 to Length(LName) do
    if CharInSet(LName[LIdx], ['\', '/']) then
      LSlash := LIdx;
  Insert('~' + IntToStr(ACopy) + '\', LName, LSlash + 1);
  if LQuoted then
    LName := '''' + LName + '''';
  Result := LName;
end;

// The index of the token of AStream that covers offset AOffset.
function TokenAt(const AStream: TPasTokenStream; AOffset: Integer): Integer;
var
  LLo, LHi, LMid: Integer;
begin
  LLo := 0;
  LHi := High(AStream.Tokens);
  Result := -1;
  while LLo <= LHi do
  begin
    LMid := (LLo + LHi) div 2;
    if AStream.Tokens[LMid].Start <= AOffset then
    begin
      Result := LMid;
      LLo := LMid + 1;
    end
    else
      LHi := LMid - 1;
  end;
end;

function InstanceCopyPath(const APath: string; ACopy: Integer): string;
begin
  Result := TPath.Combine(TPath.Combine(TPath.GetDirectoryName(APath),
    '~' + IntToStr(ACopy)), TPath.GetFileName(APath));
end;

type
  // One open conditional of the processing-order walk in Flatten - the
  // preprocessor's own stack, rebuilt from what the markers saw.
  TCondFrame = record
    ParentActive: Boolean;
    AnyTaken: Boolean;
    SeenElse: Boolean;
  end;

  // Preprocesses the unit once more with ATexts[i] standing in for the file
  // APaths[i] - the liveness run - exactly as the stream being flattened was
  // made: a bare preprocessor, or a project analysis under -oracle.
  TLivenessRun = reference to function(const APaths,
    ATexts: TArray<string>): TPasPreprocessed;

{ t0f. Fills GEdits with every inclusion's blanking and include rewrites,
  GOutName/GIsCopy with the file each inclusion is written as, GFlatStats
  with the counts. ALiveness repeats the run that made GPre (see
  TLivenessRun).

  Some directives survive as PROBES, because dcc records what they consult
  and blanking them changes the .dcu with no change of code (all probed on
  dcc64 37.0):
  - every $IF and $ELSEIF, live or not, stays where it was as an empty
    conditional, closed at once (an $ELSEIF reads as $IF). dcc evaluates
    EVERY such expression it meets - in a skipped branch, after a taken one
    - and records each name it finds as an import of the unit
    (`$IF RTLVersion >= 36` imports System's RTLVersion; the first self-host
    run's one DIFF; a skipped `$IF SizeOf(tagSTATSTG)` imports that type).
    The .dcu comes out the same whether the expression stood in a live or a
    dead branch, so the probe needs no liveness. An $IFDEF, $IFNDEF or
    $IFOPT records nothing and is blanked.

  - dcc stores the text after an $ELSE, $ENDIF or $IFEND when it starts with
    `!` - System.Contnrs' `$ENDIF !AUTOREFCOUNT` - provided the state after
    the directive is live (any other leading character stores nothing, nor
    does an $ELSE that turns code off); `$REGION` does the same, with a
    byte-identical result. Such a directive becomes `$REGION !text` +
    `$ENDREGION` in its place.
  The branches are still the preprocessor's: a probe chooses nothing. }
procedure Flatten(const ALiveness: TLivenessRun);
var
  LCount, LFile, LTok, LPath, LIdx, LJdx, LCopy, LWordStart: Integer;
  LPaths: TDictionary<string, Integer>;       // lower-cased path -> index
  LPathOf: TArray<Integer>;                   // FileId -> path index
  LRep: TList<Integer>;                       // path index -> first FileId
  LWord: TArray<TArray<string>>;              // FileId, token -> its word
  // FileId, token: a marker before / after it lay in live code; the marker
  // came back at all.
  LBefore, LAfter, LSeenBefore, LSeenAfter: TArray<TArray<Boolean>>;
  LAug, LAugPaths: TArray<string>;            // path index -> marked text
  LSB: TStringBuilder;
  LStream: TPasTokenStream;
  LMark: TPasPreprocessed;
  LText: string;
  LAfterMark: Boolean;
  LOwn: TArray<TList<TEdit>>;                 // FileId -> its blanking
  LKeys: TDictionary<string, Integer>;
  LKeyOf, LCopyOf: TArray<Integer>;
  LCopies: TDictionary<Integer, Integer>;
  LKey: TStringBuilder;
  LRef: TPasIncludeRef;
  LRegion: TPasSkippedRegion;
  LArgStart, LArgLen: Integer;
  LEdits: TList<TEdit>;
  LIncludeAt: TDictionary<Int64, Integer>;    // FileId:offset -> included
  LStack: TList<TCondFrame>;
  LBlankRegions, LBlankCond, LBlankDead, LKept, LProbes, LCopyFiles: Integer;
  LByOffset: IComparer<TEdit>;

  function IsCond(AFile, ATok: Integer): Boolean;
  begin
    Result := IsConditionalWord(LWord[AFile][ATok]);
  end;

  // The preprocessor's walk, in its order - an include is processed where
  // its directive stands - with its conditional stack rebuilt from the
  // markers: an opening conditional's after-marker says whether it was
  // taken, and so on. Checks the markers against what the stack implies
  // wherever that is determined: a marker read wrongly shows up here.
  procedure Walk(AFile: Integer);
  var
    LT, LTop, LIncluded: Integer;
    LW: string;
    LFrame: TCondFrame;

    procedure Mismatch;
    begin
      raise Exception.CreateFmt('the markers contradict the conditional ' +
        'stack at %s', [PosText(AFile, GPre.Files[AFile].Tokens[LT].Start)]);
    end;

  begin
    for LT := 0 to High(GPre.Files[AFile].Tokens) do
    begin
      LW := LWord[AFile][LT];
      if LW = '' then
        Continue;
      LTop := LStack.Count - 1;
      if (LW = 'IF') or (LW = 'IFDEF') or (LW = 'IFNDEF') or (LW = 'IFOPT') then
      begin
        if LAfter[AFile][LT] and not LBefore[AFile][LT] then
          Mismatch;
        LFrame.ParentActive := LBefore[AFile][LT];
        LFrame.AnyTaken := LAfter[AFile][LT];
        LFrame.SeenElse := False;
        LStack.Add(LFrame);
      end
      else if LW = 'ELSEIF' then
      begin
        if (LTop >= 0) and not LStack[LTop].SeenElse then
        begin
          LFrame := LStack[LTop];
          if LAfter[AFile][LT] and
             not (LFrame.ParentActive and not LFrame.AnyTaken) then
            Mismatch;
          if LAfter[AFile][LT] then
            LFrame.AnyTaken := True;
          LStack[LTop] := LFrame;
        end;
      end
      else if LW = 'ELSE' then
      begin
        if LTop >= 0 then
        begin
          LFrame := LStack[LTop];
          if LAfter[AFile][LT] <> (LFrame.ParentActive and
             not LFrame.AnyTaken) then
            Mismatch;
          LFrame.SeenElse := True;
          if LAfter[AFile][LT] then
            LFrame.AnyTaken := True;
          LStack[LTop] := LFrame;
        end;
      end
      else if (LW = 'ENDIF') or (LW = 'IFEND') then
      begin
        if LTop >= 0 then
        begin
          if LAfter[AFile][LT] <> LStack[LTop].ParentActive then
            Mismatch;
          LStack.Delete(LTop);
        end;
      end
      else if LIncludeAt.TryGetValue(Int64(AFile) shl 32 or
              GPre.Files[AFile].Tokens[LT].Start, LIncluded) then
        Walk(LIncluded);
    end;
  end;

begin
  LCount := Length(GPre.Files);
  LByOffset := TComparer<TEdit>.Construct(
    function(const A, B: TEdit): Integer
    begin
      Result := A.Offset - B.Offset;
    end);
  LPaths := TDictionary<string, Integer>.Create;
  LRep := TList<Integer>.Create;
  LKeys := TDictionary<string, Integer>.Create;
  LCopies := TDictionary<Integer, Integer>.Create;
  LIncludeAt := TDictionary<Int64, Integer>.Create;
  LStack := TList<TCondFrame>.Create;
  LSB := TStringBuilder.Create;
  LKey := TStringBuilder.Create;
  SetLength(LOwn, LCount);
  try
    SetLength(LPathOf, LCount);
    SetLength(LWord, LCount);
    SetLength(LBefore, LCount);
    SetLength(LAfter, LCount);
    SetLength(LSeenBefore, LCount);
    SetLength(LSeenAfter, LCount);
    for LFile := 0 to LCount - 1 do
    begin
      LText := LowerCase(TPath.GetFullPath(GPre.FileNames[LFile]));
      if not LPaths.TryGetValue(LText, LPath) then
      begin
        LPath := LRep.Add(LFile);
        LPaths.Add(LText, LPath);
      end;
      LPathOf[LFile] := LPath;
      LStream := GPre.Files[LFile];
      SetLength(LWord[LFile], Length(LStream.Tokens));
      SetLength(LBefore[LFile], Length(LStream.Tokens));
      SetLength(LAfter[LFile], Length(LStream.Tokens));
      SetLength(LSeenBefore[LFile], Length(LStream.Tokens));
      SetLength(LSeenAfter[LFile], Length(LStream.Tokens));
      for LTok := 0 to High(LStream.Tokens) do
        if LStream.Tokens[LTok].Kind = tkDirective then
        begin
          LWord[LFile][LTok] := DirectiveWord(LStream.TokenText(LTok),
            LWordStart);
          // A directive with no word at all still needs to tell itself
          // apart from a token that is none.
          if LWord[LFile][LTok] = '' then
            LWord[LFile][LTok] := '?';
        end;
    end;
    for LRef in GPre.IncludeRefs do
      if LRef.IncludedFileId >= 0 then
        LIncludeAt.AddOrSetValue(Int64(LRef.FileId) shl 32 or LRef.Start,
          LRef.IncludedFileId);

    // The liveness run: a marker before every directive of every file and
    // one after every conditional, the same inputs otherwise. A marker that
    // lies in a region the run skipped stood in dead code.
    SetLength(LAug, LRep.Count);
    SetLength(LAugPaths, LRep.Count);
    for LPath := 0 to LRep.Count - 1 do
    begin
      LFile := LRep[LPath];
      LStream := GPre.Files[LFile];
      LSB.Clear;
      LIdx := 0;
      for LTok := 0 to High(LStream.Tokens) do
        if LStream.Tokens[LTok].Kind = tkDirective then
        begin
          LSB.Append(LStream.Source, LIdx, LStream.Tokens[LTok].Start - LIdx);
          LSB.Append(MarkerText(LPath, LTok, False));
          LSB.Append(LStream.Source, LStream.Tokens[LTok].Start,
            LStream.Tokens[LTok].Len);
          if IsCond(LFile, LTok) then
            LSB.Append(MarkerText(LPath, LTok, True));
          LIdx := LStream.Tokens[LTok].EndPos;
        end;
      LSB.Append(LStream.Source, LIdx, Length(LStream.Source) - LIdx);
      LAug[LPath] := LSB.ToString;
      LAugPaths[LPath] := GPre.FileNames[LFile];
    end;
    LMark := ALiveness(LAugPaths, LAug);
    if Length(LMark.FileNames) <> LCount then
      raise Exception.CreateFmt('the liveness run read %d files, the first ' +
        'run %d', [Length(LMark.FileNames), LCount]);
    for LFile := 0 to LCount - 1 do
      if not SameText(LMark.FileNames[LFile], GPre.FileNames[LFile]) then
        raise Exception.CreateFmt('the liveness run read %s where the first ' +
          'run read %s', [LMark.FileNames[LFile], GPre.FileNames[LFile]]);
    // Comments are never visible: the two runs must see the same tokens.
    if Length(LMark.Visible) <> Length(GPre.Visible) then
      raise Exception.CreateFmt('the liveness run saw %d tokens, the first ' +
        '%d', [Length(LMark.Visible), Length(GPre.Visible)]);
    for LIdx := 0 to High(LMark.Visible) do
      if (GPre.Visible[LIdx].FileId <> LMark.Visible[LIdx].FileId) or
         (GPre.VisibleText(LIdx) <> LMark.VisibleText(LIdx)) then
        raise Exception.CreateFmt('the liveness run diverged from the first ' +
          'at visible token %d', [LIdx]);
    for LFile := 0 to LCount - 1 do
    begin
      LStream := LMark.Files[LFile];
      for LTok := 0 to High(LStream.Tokens) do
        if (LStream.Tokens[LTok].Kind = tkCommentBrace) and
           ParseMarker(LStream.TokenText(LTok), LPath, LJdx, LAfterMark) then
        begin
          if (LPath <> LPathOf[LFile]) or (LJdx < 0) or
             (LJdx > High(LBefore[LFile])) or
             (LWord[LFile][LJdx] = '') then
            raise Exception.CreateFmt('marker %s met in file %d',
              [LStream.TokenText(LTok), LFile]);
          if LAfterMark then
            LAfter[LFile][LJdx] := not LMark.IsSkipped(LFile,
              LStream.Tokens[LTok].Start)
          else
            LBefore[LFile][LJdx] := not LMark.IsSkipped(LFile,
              LStream.Tokens[LTok].Start);
          if LAfterMark then
            LSeenAfter[LFile][LJdx] := True
          else
            LSeenBefore[LFile][LJdx] := True;
        end;
    end;
    // Every marker must have come back as a comment of its own.
    for LFile := 0 to LCount - 1 do
      for LTok := 0 to High(LWord[LFile]) do
        if (LWord[LFile][LTok] <> '') and (not LSeenBefore[LFile][LTok] or
           (IsCond(LFile, LTok) and not LSeenAfter[LFile][LTok])) then
          raise Exception.CreateFmt('a marker of the directive at %s was ' +
            'lost', [PosText(LFile, GPre.Files[LFile].Tokens[LTok].Start)]);
    // Two records the preprocessor keeps of its own say the same thing for
    // some directives: an include it followed was live, and a $DEFINE or
    // $UNDEF carries the state it was met in.
    for LRef in GPre.IncludeRefs do
    begin
      LTok := TokenAt(GPre.Files[LRef.FileId], LRef.Start);
      if (LTok < 0) or not LBefore[LRef.FileId][LTok] then
        raise Exception.CreateFmt('an include the preprocessor followed ' +
          'reads as dead at %s', [PosText(LRef.FileId, LRef.Start)]);
    end;
    // Every define mention carries the state it was met in: a $DEFINE's or
    // $UNDEF's own, the enclosing one for an $IFDEF/$IFNDEF - both what the
    // marker before the directive saw.
    for LIdx := 0 to High(GPre.DefineRefs) do
      if GPre.DefineRefs[LIdx].Kind in [drDefine, drUndef, drIfdef, drIfndef]
      then
      begin
        LFile := GPre.DefineRefs[LIdx].FileId;
        LTok := TokenAt(GPre.Files[LFile], GPre.DefineRefs[LIdx].Start);
        if (LTok < 0) or
           (GPre.Files[LFile].Tokens[LTok].Kind <> tkDirective) or
           (LBefore[LFile][LTok] <> GPre.DefineRefs[LIdx].Active) then
          raise Exception.CreateFmt('a define''s recorded state disagrees ' +
            'with the liveness run at %s', [PosText(LFile,
            GPre.DefineRefs[LIdx].Start)]);
      end;
    Walk(0);

    // Each inclusion's own edits: the regions the preprocessor skipped and
    // every directive that was not live blanked; every conditional blanked
    // too, but for the probes (see above).
    LBlankRegions := 0;
    LBlankCond := 0;
    LBlankDead := 0;
    LKept := 0;
    LProbes := 0;
    for LFile := 0 to LCount - 1 do
    begin
      LStream := GPre.Files[LFile];
      LOwn[LFile] := TList<TEdit>.Create;
      for LRegion in GPre.Skipped[LFile] do
      begin
        LOwn[LFile].Add(MakeEdit(LFile, LRegion.Start,
          LRegion.EndPos - LRegion.Start, Blank(LStream.Source, LRegion.Start,
          LRegion.EndPos - LRegion.Start)));
        Inc(LBlankRegions);
      end;
      for LTok := 0 to High(LStream.Tokens) do
        if LStream.Tokens[LTok].Kind = tkDirective then
        begin
          if (LWord[LFile][LTok] = 'IF') or
             (LWord[LFile][LTok] = 'ELSEIF') then
          begin
            // `$ELSEIF expr` reads `$IF expr`, then the empty body closes.
            LText := LStream.TokenText(LTok);
            if LWord[LFile][LTok] = 'ELSEIF' then
            begin
              DirectiveWord(LText, LWordStart);
              LText := Copy(LText, 1, LWordStart) + 'IF' +
                Copy(LText, LWordStart + 7, MaxInt);
            end;
            LOwn[LFile].Add(MakeEdit(LFile, LStream.Tokens[LTok].Start,
              LStream.Tokens[LTok].Len, LText + '{$IFEND}'));
            Inc(LProbes);
            Continue;
          end;
          if ((LWord[LFile][LTok] = 'ENDIF') or
              (LWord[LFile][LTok] = 'IFEND') or
              (LWord[LFile][LTok] = 'ELSE')) and LAfter[LFile][LTok] then
          begin
            LText := DirectiveTrail(LStream.TokenText(LTok));
            if LText.StartsWith('!') then
            begin
              LOwn[LFile].Add(MakeEdit(LFile, LStream.Tokens[LTok].Start,
                LStream.Tokens[LTok].Len,
                '{$REGION ' + LText + '}{$ENDREGION}'));
              Inc(LProbes);
              Continue;
            end;
          end;
          if IsCond(LFile, LTok) then
            Inc(LBlankCond)
          else if not LBefore[LFile][LTok] then
            Inc(LBlankDead)
          else
          begin
            Inc(LKept);
            Continue;
          end;
          LOwn[LFile].Add(MakeEdit(LFile, LStream.Tokens[LTok].Start,
            LStream.Tokens[LTok].Len, Blank(LStream.Source,
            LStream.Tokens[LTok].Start, LStream.Tokens[LTok].Len)));
        end;
      LOwn[LFile].Sort(LByOffset);
    end;

    // Which inclusions read the same text. Leaf-first - an include's FileId
    // is always above its includer's - so a key can name the keys of the
    // inclusions inside it: equal keys, equal files.
    SetLength(LKeyOf, LCount);
    for LFile := LCount - 1 downto 0 do
    begin
      LKey.Clear;
      LKey.Append(ApplyEdits(GPre.Files[LFile].Source, LOwn[LFile]));
      for LRef in GPre.IncludeRefs do
        if (LRef.FileId = LFile) and (LRef.IncludedFileId >= 0) then
          LKey.Append(#0).Append(LRef.Start).Append(':').Append(
            LKeyOf[LRef.IncludedFileId]);
      LText := LKey.ToString;
      if not LKeys.TryGetValue(LText, LIdx) then
      begin
        LIdx := LKeys.Count;
        LKeys.Add(LText, LIdx);
      end;
      LKeyOf[LFile] := LIdx;
    end;
    // Per file, the first text keeps the file's own place; every other
    // distinct text gets copy 2, 3, ...
    SetLength(LCopyOf, LCount);
    SetLength(GOutName, LCount);
    SetLength(GIsCopy, LCount);
    LCopyFiles := 0;
    for LPath := 0 to LRep.Count - 1 do
    begin
      LCopies.Clear;
      for LFile := 0 to LCount - 1 do
        if LPathOf[LFile] = LPath then
        begin
          if not LCopies.TryGetValue(LKeyOf[LFile], LCopy) then
          begin
            LCopy := LCopies.Count + 1;
            LCopies.Add(LKeyOf[LFile], LCopy);
            if LCopy > 1 then
              Inc(LCopyFiles);
          end;
          LCopyOf[LFile] := LCopy;
          GIsCopy[LFile] := LCopy > 1;
          if LCopy > 1 then
            GOutName[LFile] := InstanceCopyPath(GPre.FileNames[LFile], LCopy)
          else
            GOutName[LFile] := GPre.FileNames[LFile];
        end;
    end;

    // The edits: the blanking, plus the argument of every include whose
    // inclusion reads a copy.
    for LFile := 0 to LCount - 1 do
    begin
      LEdits := LOwn[LFile];
      for LRef in GPre.IncludeRefs do
        if (LRef.FileId = LFile) and (LRef.IncludedFileId >= 0) and
           (LCopyOf[LRef.IncludedFileId] > 1) then
        begin
          LText := Copy(GPre.Files[LFile].Source, LRef.Start + 1, LRef.Len);
          IncludeArg(LText, LArgStart, LArgLen);
          LEdits.Add(MakeEdit(LFile, LRef.Start + LArgStart, LArgLen,
            CopyArg(Copy(LText, LArgStart + 1, LArgLen),
            LCopyOf[LRef.IncludedFileId])));
          GArgMap.AddOrSetValue(
            CopyArg(Copy(LText, LArgStart + 1, LArgLen),
            LCopyOf[LRef.IncludedFileId]).DeQuotedString,
            Copy(LText, LArgStart + 1, LArgLen).DeQuotedString);
        end;
      LEdits.Sort(LByOffset);
      GEdits.AddRange(LEdits);
    end;

    GFlatStats := Format('inclusions=%d files=%d copies=%d skipped-regions=%d ' +
      'conditionals=%d if-probes=%d dead-directives=%d live-directives=%d',
      [LCount, LRep.Count, LCopyFiles, LBlankRegions, LBlankCond, LProbes,
      LBlankDead, LKept]);
  finally
    for LIdx := 0 to High(LOwn) do
      LOwn[LIdx].Free;
    LKey.Free;
    LSB.Free;
    LStack.Free;
    LIncludeAt.Free;
    LCopies.Free;
    LKeys.Free;
    LRep.Free;
    LPaths.Free;
  end;
end;

{ The encoding the source manager decoded AFileName's bytes with - the same
  decision as TPasSourceManager.DecodeBytes. False for its lenient UTF-8
  recovery, whose U+FFFD substitutions have no byte-exact inverse. }
function FileEncoding(const ABytes: TBytes; out AEnc: TEncoding;
  out APreamble: Integer): Boolean;
begin
  AEnc := nil;
  APreamble := TEncoding.GetBufferEncoding(ABytes, AEnc, TEncoding.UTF8);
  Result := True;
  if (AEnc.CodePage = CP_UTF8) and
     not TPasSourceManager.IsValidUtf8(ABytes, APreamble) then
  begin
    if APreamble > 0 then
      Exit(False);
    AEnc := TEncoding.ANSI;
  end;
end;

procedure CopyFileTime(const AFrom, ATo: string);
var
  LFrom, LTo: THandle;
  LCreate, LAccess, LWrite: TFileTime;
begin
  LFrom := CreateFile(PChar(AFrom), GENERIC_READ, FILE_SHARE_READ or
    FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
  if LFrom = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  try
    if not GetFileTime(LFrom, @LCreate, @LAccess, @LWrite) then
      RaiseLastOSError;
  finally
    CloseHandle(LFrom);
  end;
  LTo := CreateFile(PChar(ATo), FILE_WRITE_ATTRIBUTES, 0, nil, OPEN_EXISTING,
    0, 0);
  if LTo = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  try
    if not SetFileTime(LTo, @LCreate, @LAccess, @LWrite) then
      RaiseLastOSError;
  finally
    CloseHandle(LTo);
  end;
end;

{ Writes file AFileId's bytes with its edits spliced in at byte offsets. }
procedure WriteFile(AFileId: Integer; const AOutPath: string);
var
  LBytes, LOut: TBytes;
  LEnc: TEncoding;
  LPreamble, LTextPos, LBytePos, LCount, LIdx: Integer;
  LText: string;
  LEdits: TList<TEdit>;
  LEdit: TEdit;
  LStream: TBytesStream;
  LIns: TBytes;
begin
  LBytes := TFile.ReadAllBytes(GPre.FileNames[AFileId]);
  if not FileEncoding(LBytes, LEnc, LPreamble) then
    raise Exception.CreateFmt('%s: not valid UTF-8 despite its BOM - no ' +
      'byte-exact edit is possible', [GPre.FileNames[AFileId]]);
  LText := LEnc.GetString(LBytes, LPreamble, Length(LBytes) - LPreamble);
  // The offsets are the lexer's: they index the text IT read.
  if LText <> GPre.Files[AFileId].Source then
    raise Exception.CreateFmt('%s: decodes differently from the text the ' +
      'lexer read', [GPre.FileNames[AFileId]]);
  if LEnc.GetByteCount(LText, 0, Length(LText), 0) <>
     Length(LBytes) - LPreamble then
    raise Exception.CreateFmt('%s: the %s decoding does not round-trip',
      [GPre.FileNames[AFileId], LEnc.EncodingName]);
  LEdits := TList<TEdit>.Create;
  LStream := TBytesStream.Create;
  try
    for LEdit in GEdits do
      if LEdit.FileId = AFileId then
        LEdits.Add(LEdit);
    LEdits.Sort(TComparer<TEdit>.Construct(
      function(const A, B: TEdit): Integer
      begin
        Result := A.Offset - B.Offset;
        if Result = 0 then
          Result := A.Order - B.Order;
      end));
    if LPreamble > 0 then
      LStream.WriteBuffer(LBytes[0], LPreamble);
    LTextPos := 0;
    LBytePos := LPreamble;
    for LIdx := 0 to LEdits.Count - 1 do
    begin
      LEdit := LEdits[LIdx];
      LCount := LEnc.GetByteCount(LText, LTextPos, LEdit.Offset - LTextPos, 0);
      if LCount > 0 then
        LStream.WriteBuffer(LBytes[LBytePos], LCount);
      Inc(LBytePos, LCount);
      LTextPos := LEdit.Offset;
      LIns := LEnc.GetBytes(LEdit.Text);
      if Length(LIns) > 0 then
        LStream.WriteBuffer(LIns[0], Length(LIns));
      // A replacement: the bytes of the replaced characters are skipped.
      if LEdit.Len > 0 then
      begin
        Inc(LBytePos, LEnc.GetByteCount(LText, LEdit.Offset, LEdit.Len, 0));
        Inc(LTextPos, LEdit.Len);
      end;
    end;
    if LBytePos < Length(LBytes) then
      LStream.WriteBuffer(LBytes[LBytePos], Length(LBytes) - LBytePos);
    LOut := Copy(LStream.Bytes, 0, LStream.Size);
  finally
    LStream.Free;
    LEdits.Free;
  end;
  TDirectory.CreateDirectory(TPath.GetDirectoryName(AOutPath));
  TFile.WriteAllBytes(AOutPath, LOut);
  CopyFileTime(GPre.FileNames[AFileId], AOutPath);
end;

function NoSlash(const APath: string): string;
begin
  Result := ExcludeTrailingPathDelimiter(TPath.GetFullPath(APath));
end;

// The deepest directory containing both - '' when they share no root.
function CommonDir(const A, B: string): string;
var
  LA, LB: TArray<string>;
  LIdx: Integer;
begin
  LA := A.Split([PathDelim]);
  LB := B.Split([PathDelim]);
  Result := '';
  LIdx := 0;
  while (LIdx < Length(LA)) and (LIdx < Length(LB)) and
        SameText(LA[LIdx], LB[LIdx]) do
  begin
    if LIdx = 0 then
      Result := LA[0]
    else
      Result := Result + PathDelim + LA[LIdx];
    Inc(LIdx);
  end;
end;

// APath's place under AOut, mirrored from ARoot (a directory APath is under).
function Mirror(const APath, ARoot, AOut: string): string;
begin
  if not SameText(Copy(APath, 1, Length(ARoot) + 1), ARoot + PathDelim) and
     not SameText(APath, ARoot) then
    raise Exception.CreateFmt('%s is not under %s', [APath, ARoot]);
  Result := AOut + Copy(APath, Length(ARoot) + 1, MaxInt);
end;

const
  cPPCodeNames: array[TPasPPDiagCode] of string = ('unbalanced-else',
    'unbalanced-endif', 'unterminated-conditional', 'include-not-found',
    'include-cycle', 'include-too-deep', 'if-unreadable', 'if-guessed',
    'unsupported-insertion', 'popopt-without-pushopt');

{ -oracle: does the project's analysis preprocess this unit differently from
  a bare preprocessor? Only where a $IF asked what a bare one cannot answer -
  a Declared() name, a constant, a SizeOf - and the guess could matter: the
  preprocessor records exactly those, and a guessed or unreadable $IF says
  so too. Anything else comes out the same, so it is left to the cheap run. }
function OracleCouldMatter(const APre: TPasPreprocessed): Boolean;
var
  LIdx: Integer;
begin
  Result := (Length(APre.UnresolvedDeclared) > 0) or
    (Length(APre.UnresolvedSymbols) > 0);
  for LIdx := 0 to High(APre.Diagnostics) do
    if APre.Diagnostics[LIdx].Code in [ppIfNeedsSemantics, ppBadIfExpression] then
      Result := True;
end;

var
  GArg, GFile, GOut, GRoot, GPath, GLine: string;
  GMode: TXformMode;
  GPlatform: TPasPlatform;
  GInfo: TPasPlatformInfo;
  GIncDirs, GDefNames, GUndefNames, GSearch: TList<string>;
  GOracle, GOracleUsed: Boolean;
  GProject: TPasSemaProject;
  GProjectId: Integer;
  GLiveness: TLivenessRun;
  GSM: TPasSourceManager;
  GDefines: TPasDefines;
  GPP: TPasPreprocessor;
  GDiags: TArray<TPasParseDiag>;
  GIdx, GJdx, GNonInfo, GOffset: Integer;
  GSite: TSite;
  GName: string;
  GWritten: TDictionary<string, Boolean>;
  GSitesText, GFileLines: TStringList;

begin
  try
    GMode := xmT0;
    GPlatform := pfWin64;
    GFile := '';
    GOut := '';
    GIncDirs := TList<string>.Create;
    GDefNames := TList<string>.Create;
    GUndefNames := TList<string>.Create;
    GSearch := TList<string>.Create;
    GOracle := False;
    GOracleUsed := False;
    GProject := nil;
    for GIdx := 1 to ParamCount do
    begin
      GArg := ParamStr(GIdx);
      if SameText(GArg, '-oracle') then
      begin
        GOracle := True;
        Continue;
      end;
      if GArg.StartsWith('-S:', True) then
      begin
        for GName in Copy(GArg, 4, MaxInt).Split([';']) do
          if Trim(GName) <> '' then
            GSearch.Add(NoSlash(Trim(GName)));
        Continue;
      end;
      if GArg.StartsWith('-mode:', True) then
      begin
        GArg := LowerCase(Copy(GArg, 7, MaxInt));
        if GArg = 't0' then GMode := xmT0
        else if GArg = 'ts' then GMode := xmTS
        else if GArg = 't0f' then GMode := xmT0F
        else raise Exception.Create('unknown mode: ' + GArg);
      end
      else if GArg.StartsWith('-Undef:', True) then
      begin
        for GName in Copy(GArg, 8, MaxInt).Split([';']) do
          if Trim(GName) <> '' then
            GUndefNames.Add(Trim(GName));
      end
      else if GArg.StartsWith('-out:', True) then
        GOut := NoSlash(Copy(GArg, 6, MaxInt))
      else if GArg.StartsWith('-p:', True) then
      begin
        if not TryParsePlatformName(Copy(GArg, 4, MaxInt), GPlatform) then
          raise Exception.Create('unknown platform: ' + Copy(GArg, 4, MaxInt));
      end
      else if GArg.StartsWith('-D:', True) then
      begin
        for GName in Copy(GArg, 4, MaxInt).Split([';']) do
          if Trim(GName) <> '' then
            GDefNames.Add(Trim(GName));
      end
      else if GArg.StartsWith('-I:', True) then
      begin
        for GName in Copy(GArg, 4, MaxInt).Split([';']) do
          if Trim(GName) <> '' then
            GIncDirs.Add(NoSlash(Trim(GName)));
      end
      else if GArg.StartsWith('-') then
        raise Exception.Create('unknown option: ' + GArg)
      else
        GFile := TPath.GetFullPath(GArg);
    end;
    if (GFile = '') or (GOut = '') then
    begin
      Writeln(ErrOutput, 'Usage: PasTreeXform <unit.pas> -mode:t0|ts|t0f ' +
        '-out:<dir> [-p:<platform>] [-D:X;Y]... [-Undef:X;Y]... ' +
        '[-I:<dir>[;<dir>]]... [-oracle [-S:<dir>[;<dir>]]...]');
      ExitCode := 1;
      Exit;
    end;

    GInfo := PlatformInfo(GPlatform);
    GSM := TPasSourceManager.Create(GIncDirs.ToArray);
    GDefines := CreatePlatformDefines(GPlatform);
    for GName in GDefNames do
      GDefines.Define(GName);
    for GName in GUndefNames do
      GDefines.Undefine(GName);
    GPP := TPasPreprocessor.Create(GSM, GDefines, DEFAULT_COMPILER_VERSION,
      GInfo.PointerBytes, GInfo.ExtendedBytes);
    GEdits := TList<TEdit>.Create;
    GSites := TList<TSite>.Create;
    GArgMap := TDictionary<string, string>.Create;
    GWritten := TDictionary<string, Boolean>.Create;
    GSitesText := TStringList.Create;
    GFileLines := TStringList.Create;
    try
      GPre := GPP.Process(GFile);
      // A preprocessor diagnostic is worth seeing: an include not found here
      // is a file the copy will lack. $IF-needs-semantics is informational.
      GNonInfo := 0;
      for GIdx := 0 to High(GPre.Diagnostics) do
        if GPre.Diagnostics[GIdx].Code <> ppIfNeedsSemantics then
        begin
          Inc(GNonInfo);
          Writeln(ErrOutput, 'PP ', PosText(GPre.Diagnostics[GIdx].FileId,
            GPre.Diagnostics[GIdx].Start), ': ',
            PP_DIAG_MESSAGES[GPre.Diagnostics[GIdx].Code], ' ',
            GPre.Diagnostics[GIdx].Detail);
        end;

      SetLength(GIncludedTwice, Length(GPre.FileNames));
      for GIdx := 0 to High(GPre.FileNames) do
        for GJdx := 0 to High(GPre.FileNames) do
          if (GIdx <> GJdx) and
             SameText(GPre.FileNames[GIdx], GPre.FileNames[GJdx]) then
            GIncludedTwice[GIdx] := True;

      GDiags := nil;
      if GMode = xmTS then
      begin
        GTree := TPasParser.ParseFile(GPre, GDiags);
        for GIdx := 0 to High(GDiags) do
          if GDiags[GIdx].VisIndex <= High(GPre.Visible) then
          begin
            GOffset := VisOffset(GDiags[GIdx].VisIndex, GJdx);
            Writeln(ErrOutput, 'PARSE ', PosText(GJdx, GOffset), ': ',
              GDiags[GIdx].Msg);
          end
          else
            Writeln(ErrOutput, 'PARSE <eof>: ', GDiags[GIdx].Msg);
        GUnitName := HeaderName;
        VisitRoutines(0, '');
      end
      else if GMode = xmT0F then
      begin
        if GOracle and (GUndefNames.Count > 0) then
          raise Exception.Create('-Undef cannot reach a project analysis: ' +
            'use -oracle without it');
        if GOracle and OracleCouldMatter(GPre) then
        begin
          // The stream PasTree really analyzes: the project's first pass
          // (compiler-provided names answered) and its second, the oracle's.
          GProject := TPasSemaProject.Create(GPlatform,
            GSearch.ToArray + GIncDirs.ToArray, GDefNames.ToArray);
          GProjectId := GProject.AnalyzeProject(GFile);
          if (GProjectId < 0) or
             (Length(GProject.Model(GProjectId).Tree.Source.Files) = 0) then
            raise Exception.Create('the project analysis kept no ' +
              'preprocessed text of the unit');
          GPre := GProject.Model(GProjectId).Tree.Source;
          if not SameText(NoSlash(GPre.FileNames[0]), NoSlash(GFile)) then
            raise Exception.CreateFmt('the project analyzed %s',
              [GPre.FileNames[0]]);
          GOracleUsed := True;
          GLiveness :=
            function(const APaths, ATexts: TArray<string>): TPasPreprocessed
            var
              LProject: TPasSemaProject;
              LId, LIdx: Integer;
            begin
              LProject := TPasSemaProject.Create(GPlatform,
                GSearch.ToArray + GIncDirs.ToArray, GDefNames.ToArray);
              try
                for LIdx := 0 to High(APaths) do
                  LProject.SetBuffer(APaths[LIdx], ATexts[LIdx]);
                LId := LProject.AnalyzeProject(GFile);
                if LId < 0 then
                  raise Exception.Create('the liveness analysis failed');
                Result := LProject.Model(LId).Tree.Source;
              finally
                LProject.Free;
              end;
            end;
        end
        else
          GLiveness :=
            function(const APaths, ATexts: TArray<string>): TPasPreprocessed
            var
              LSM: TPasSourceManager;
              LPP: TPasPreprocessor;
              LIdx: Integer;
            begin
              LSM := TPasSourceManager.Create(GIncDirs.ToArray);
              LPP := TPasPreprocessor.Create(LSM, GDefines,
                DEFAULT_COMPILER_VERSION, GInfo.PointerBytes,
                GInfo.ExtendedBytes);
              try
                for LIdx := 0 to High(APaths) do
                  LSM.SetBuffer(APaths[LIdx], ATexts[LIdx]);
                Result := LPP.ProcessText(GFile, ATexts[0]);
              finally
                LPP.Free;
                LSM.Free;
              end;
            end;
        Flatten(GLiveness);
        if GOracleUsed then
          GFlatStats := GFlatStats + ' stream=project'
        else
          GFlatStats := GFlatStats + ' stream=preprocessor';
        // The sites of t0f are the preprocessor's diagnostics: a guessed or
        // unreadable $IF is where a DIFF most likely comes from.
        for GIdx := 0 to High(GPre.Diagnostics) do
        begin
          GSite.Kind := cPPCodeNames[GPre.Diagnostics[GIdx].Code];
          GSite.Ops := GPre.Diagnostics[GIdx].Detail.Replace(#9, ' ').
            Replace(#13, ' ').Replace(#10, ' ');
          GSite.Span := PosText(GPre.Diagnostics[GIdx].FileId,
            GPre.Diagnostics[GIdx].Start);
          GSite.Routine := '';
          GSite.Edit := '';
          GSites.Add(GSite);
        end;
      end;

      // The mirror root: every file read and every -I directory under it.
      GRoot := NoSlash(TPath.GetDirectoryName(GFile));
      for GIdx := 1 to High(GPre.FileNames) do
        GRoot := CommonDir(GRoot, NoSlash(TPath.GetDirectoryName(
          GPre.FileNames[GIdx])));
      for GPath in GIncDirs do
        GRoot := CommonDir(GRoot, GPath);
      if GRoot = '' then
        raise Exception.Create('the unit, its includes and the -I ' +
          'directories share no root directory');

      // One file per distinct output: t0f writes each inclusion as its own
      // file or as an instance copy, the others every file as itself.
      for GIdx := 0 to High(GPre.FileNames) do
      begin
        if GMode = xmT0F then
          GPath := Mirror(NoSlash(GOutName[GIdx]), GRoot, GOut)
        else
          GPath := Mirror(NoSlash(GPre.FileNames[GIdx]), GRoot, GOut);
        if GWritten.ContainsKey(LowerCase(GPath)) then
          Continue;
        GWritten.Add(LowerCase(GPath), True);
        WriteFile(GIdx, GPath);
        if (GMode = xmT0F) and GIsCopy[GIdx] then
          GFileLines.Add('copy ' + NoSlash(GPre.FileNames[GIdx]) + #9 + GPath)
        else
          GFileLines.Add('file ' + NoSlash(GPre.FileNames[GIdx]) + #9 + GPath);
      end;

      GSitesText.Add(Format('# PasTreeXform %s  mode=%s  platform=%s  ' +
        'files=%d  parse-diagnostics=%d  pp-diagnostics=%d  ' +
        'dropped-sites=%d', [PasTreeVersion, cModeNames[GMode],
        PlatformName(GPlatform), Length(GPre.FileNames), Length(GDiags),
        GNonInfo, GDropped]));
      GSitesText.Add('# ' + GFile);
      GSitesText.Add('# id' + #9 + 'kind' + #9 + 'ops' + #9 + 'span' + #9 +
        'routine' + #9 + 'edit');
      for GIdx := 0 to GSites.Count - 1 do
      begin
        GSite := GSites[GIdx];
        GSitesText.Add(Format('%d'#9'%s'#9'%s'#9'%s'#9'%s'#9'%s', [GIdx + 1,
          GSite.Kind, GSite.Ops, GSite.Span, GSite.Routine, GSite.Edit]));
      end;
      TDirectory.CreateDirectory(GOut);
      GSitesText.WriteBOM := False;
      GSitesText.LineBreak := #13#10;
      GSitesText.SaveToFile(TPath.Combine(GOut, 'sites.txt'), TEncoding.UTF8);

      Writeln('main ', Mirror(NoSlash(GFile), GRoot, GOut));
      for GLine in GFileLines do
        Writeln(GLine);
      for GPath in GIncDirs do
        Writeln('idir ', GPath, #9, Mirror(GPath, GRoot, GOut));
      GLine := IntToStr(GSites.Count);
      if GDropped > 0 then
        GLine := GLine + ' dropped ' + IntToStr(GDropped);
      Writeln('sites ', GLine);
      if GMode = xmT0F then
      begin
        for GName in GArgMap.Keys do
          Writeln('argmap ', GName, #9, GArgMap[GName]);
        Writeln('flatten ', GFlatStats);
      end;
    finally
      GArgMap.Free;
      GFileLines.Free;
      GSitesText.Free;
      GWritten.Free;
      GSites.Free;
      GEdits.Free;
      GPP.Free;
      GDefines.Free;
      GSM.Free;
      GIncDirs.Free;
      GDefNames.Free;
      GUndefNames.Free;
      GSearch.Free;
      GProject.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
