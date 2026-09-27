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
    t1  parentheses along the tree (plan T1): every operator node - binary,
        unary, inline if - wrapped in `(` `)`. A correct tree leaves the
        .dcu identical; one grouping dcc makes differently changes the code
        or stops the compile. Only OPERATORS are wrapped: dcc keeps a
        parenthesized designator as a value of its own - `(@P) := X` is
        E2064 where `@P := X` assigns a procedural variable, and an inline
        routine's stored expression tree records `not (A.B)` differently
        from `not A.B` while the code is the same (plan S5). Not wrapped
        either, counted instead: an operator that starts a subrange TYPE - a
        `(` there opens an enumerated type in every type position
        (`excluded-type`); one whose left edge is a `[...]` constructor -
        parenthesized, dcc types it without the target, `A := ([X] + A)` is
        E2008 (`excluded-ctor`); every `@` - `@P` of a procedural variable is
        a designator for dcc (`excluded-at`); one that starts the value of a
        typed constant or an initialized variable, an aggregate element or a
        record constant's field value - a `(` there opens an aggregate
        (`excluded-init`, see CollectInitStarts); in a unit whose own text turns
        debug info on, an operator whose last token does not share a line
        with the next (`excluded-lines`, see LinesKept). Every site is one line of
        sites.txt; -sites: applies a subset (the driver's localizer bisects a
        DIFF down to the node with it).
    t2  blocks along the tree (plan T2): every statement node in a statement
        position - a statement list's item, an if's branch, a case branch's
        body, the body of a loop, a with or an exception handler, the
        statement a label marks - wrapped in `begin` `end`, an empty one
        replaced by `begin end`; the `end` goes right before the token
        after the statement, whose line dcc gives an Assert (see
        AddBlockSite). A correct tree leaves the .dcu identical;
        an `else` or a statement's end placed differently from dcc changes
        the code or stops the compile. Not wrapped, counted: an inline var
        or const (the block would end its scope - `excluded-inline`), a
        labeled statement itself (its statement is wrapped -
        `excluded-label`), asm (`excluded-asm`), a call statement standing
        as a list item (dcc finalizes a discarded managed result at the end
        of the list - `excluded-call`), in a generic's or an inline
        routine's body a statement not on one line with the token after it
        (dcc stores such a body with its lines - `excluded-stored`), the
        same in a unit whose own text turns debug or symbol info on
        (`excluded-lines`, see LinesKept; all three see T2Walk); never a
        routine's own block or the statement lists of
        a case-else, a try, an except, a finally or a repeat, which are no
        statements - their items are.

  Usage:
    PasTreeXform <unit.pas> -mode:t0|ts|t0f|t1|t2 -out:<dir> [-p:<platform>]
                 [-D:X;Y]... [-Undef:X;Y]... [-I:<dir>[;<dir>]]...
                 [-sites:<ids>]
  -sites (ts, t1, t2): only the sites with these ids take their edit - a
  comma list of ids and ranges, `1-40,57`; the ids are those of the full
  run, so sites.txt means the same in every run over the same unit.
  -Undef takes names out of the define set after the platform's and -D's -
  with -D, a way to try another predefined set without rebuilding.
  -oracle: when a $IF of the unit asked what a bare preprocessor cannot
  answer (Declared, a constant, SizeOf), the stream flattened (t0f) or
  parsed (ts, t1, t2) is the one a project analysis makes - its first pass
  answers compiler-provided names, its second asks the loaded units (the
  Declared/SizeOf oracle) - over the -S search paths plus the -I ones, with
  the -NS:X;Y unit scope names (default: the IDE's for the platform). That
  is the stream PasTree analyzes, and the only way to judge the oracle
  against dcc.

  Output, all of it under <dir>:
  - the files, mirrored under the common directory of the unit, its includes
    and the -I directories, so a relative `$I` include resolves as it did;
  - sites.txt, tab-separated: id, kind, operators, span
    `file(line,col)-(line,col)`, routine, the edit, applied (1, or 0 when
    -sites left it out); t2's ops column is `<position>:<statement>` -
    `else:if`, `list::=`, `then:empty`, `on:begin`;
  - on stdout `main <path>` (the transformed unit), one `file <from> <to>`
    per file written, one `idir <from> <to>` per -I directory (the compile
    of the copy searches <to>), `sites <n>` (with `dropped`, `excluded`,
    `applied` counts where they apply), `parse <n>` - the parse diagnostics
    of the tree ts, t1 and t2 edit along; <from> and <to> tab-separated.
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

  A file included more than once takes no ts, t1 or t2 edit (one text serves
  several preprocessing states); a site that would need one - or whose
  parentheses or begin and end would land in two files - is dropped and
  counted.
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
  System.StrUtils,
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
  TXformMode = (xmT0, xmTS, xmT0F, xmT1, xmT2);

const
  cModeNames: array[TXformMode] of string = ('t0', 'ts', 't0f', 't1', 't2');

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

  // ts, t1 and t2: OpenText goes before visible token OpenVis and CloseText
  // after CloseVis - `(` and `)`, or `begin` and `end` - with their Orders
  // at an offset other edits share (see AddEdit); an empty CloseText is no
  // edit. t0f's sites are diagnostics, OpenVis -1.
  TSite = record
    Kind: string;
    Ops: string;
    Span: string;
    Routine: string;
    Edit: string;
    OpenVis: Integer;
    CloseVis: Integer;
    OpenAfter: Boolean;     // OpenText goes AFTER token OpenVis (t2's empty)
    CloseBefore: Boolean;   // CloseText goes BEFORE token CloseVis (t2's end)
    OpenText: string;
    CloseText: string;
    OpenOrder: Integer;
    CloseOrder: Integer;
  end;

var
  GPre: TPasPreprocessed;
  GTree: TPasTree;
  GEdits: TList<TEdit>;
  GSites: TList<TSite>;
  GIncludedTwice: TArray<Boolean>;   // per FileId: its path occurs twice
  GDropped: Integer;                 // sites refused for an include used twice
  GExcluded: Integer;                // t1: operators starting a subrange type
  GExcludedCtor: Integer;            // t1: operators starting with `[`
  GExcludedAt: Integer;              // t1: `@` operators
  GExcludedInline: Integer;          // t2: inline var / const statements
  GExcludedLabel: Integer;           // t2: labeled statements themselves
  GExcludedAsm: Integer;             // t2: asm statements
  GExcludedCall: Integer;            // t2: call statements in a list
  GExcludedStored: Integer;          // t2: in a stored body, off one line
  GExcludedLines: Integer;           // t1, t2: line info on in the source
  GExcludedInit: Integer;            // t1: operators starting an initializer
  // t1: the first visible token of every initializer value (see
  // CollectInitStarts)
  GInitStarts: TDictionary<Integer, Boolean>;
  // t1, t2: the unit's own text turns line-keeping info on (see LinesKept)
  GLinesKept: Boolean;
  // t2: the last name part, lower case, of every routine declared `inline`
  // anywhere in the unit (see IsStoredBody).
  GInlineNames: TDictionary<string, Boolean>;
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

{ One text insertion before (AAfter False) or after visible token AVis.
  AOrder sorts the insertions that meet at one offset, lowest first: ts and
  t1 put a `)` (0) before a `(` (1), `c)(d`; t2 an empty statement's
  `begin end` (0), then the `end` of every statement that ends there (1) -
  an empty statement is the last part of the statement around it, `do;` ->
  `do begin end end;` - then a `begin` (2). }
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

// The text of visible token AVis.
function VisText(AVis: Integer): string;
var
  LTok: TPasVisibleToken;
begin
  LTok := GPre.Visible[AVis];
  Result := GPre.Files[LTok.FileId].TokenText(LTok.TokenIndex);
end;

{ ts, t1: the site's edit is a pair of parentheses - with a space where the
  paren would fuse with its neighbour into another token: `.)` is the digraph
  of `]` and `(.` of `[`, `(*` opens a comment. A real literal written with a
  trailing dot, `100.` (an application's report code: `... *` / `100. - X`),
  parenthesized to `100.)` read as `100` and `]` - E2029 (plan S7). }
procedure SetParens(var ASite: TSite);
var
  LText: string;
begin
  ASite.OpenAfter := False;
  ASite.CloseBefore := False;
  ASite.OpenText := '(';
  LText := VisText(ASite.OpenVis);
  if (LText <> '') and CharInSet(LText[1], ['.', '*']) then
    ASite.OpenText := '( ';
  ASite.OpenOrder := 1;
  ASite.CloseText := ')';
  if VisText(ASite.CloseVis).EndsWith('.') then
    ASite.CloseText := ' )';
  ASite.CloseOrder := 0;
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
    LSite.OpenVis := LFirst;
    LSite.CloseVis := LLast;
    SetParens(LSite);
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

{ t1: the operator as the report spells it - `is not` and `not in` from the
  node's flag, `if` for an inline if. }
function OpsOf(ANode: Integer): string;
begin
  if GTree.Nodes[ANode].Kind = nkInlineIf then
    Exit('if');
  Result := OpText(ANode);
  if nfNegated in GTree.Nodes[ANode].Flags then
    if Result = 'is' then
      Result := 'is not'
    else
      Result := 'not ' + Result;
end;

{ t1: a site wrapping ANode's whole span, from its leftmost token (an
  operator's FirstToken is the operator, not its left edge) to its last.
  Dropped and counted when the two ends lie in different files or in a file
  included twice. }
procedure AddParenSite(const AKind, AOps: string; ANode: Integer;
  const ARoutine: string);
var
  LFirst, LLast, LFileA, LFileB: Integer;
  LSite: TSite;
begin
  LFirst := GTree.NodeLeftmostVis(ANode);
  LLast := GTree.Nodes[ANode].LastToken;
  VisOffset(LFirst, LFileA);
  VisOffset(LLast, LFileB);
  if (LFileA <> LFileB) or GIncludedTwice[LFileA] then
  begin
    Inc(GDropped);
    Exit;
  end;
  LSite.Kind := AKind;
  LSite.Ops := AOps;
  LSite.Span := SpanText(LFirst, LLast);
  LSite.Routine := ARoutine;
  LSite.Edit := '()';
  LSite.OpenVis := LFirst;
  LSite.CloseVis := LLast;
  SetParens(LSite);
  GSites.Add(LSite);
end;

{ t1: every operator node of the subtree at ANode as a site, in pre-order
  (an operator before its operands). ARoutine names the code the node
  compiles into, for the report: the dotted routine name the .dcu dump uses
  ('' outside every body - a constant, a type, a default value; an anonymous
  method counts as the routine it is written in). ATypeStart is the leftmost
  token of the enclosing subrange TYPE (-2 outside one): a `(` there makes
  dcc read an enumerated type, in every type position probed - a type
  declaration, the type of a var, field, typed constant or inline var, an
  array index in any dimension, `set of`, `array of` (plan S5, probes
  ty01..ty28) - so an operator starting there is not wrapped, only counted
  (GExcluded). Case labels, variant labels, set elements, typed-constant
  values, default parameters and property specifiers are expressions and
  take the parentheses.

  Nor is an operator whose left edge is a `[...]` constructor (counted in
  GExcludedCtor): dcc types a constructor from the TARGET only while the
  expression is not parenthesized - `A := [X] + A` concatenates dynamic
  arrays, `A := ([X] + A)` is E2008 and `F(([X] + A))` E2008, `[X]` read as
  a set; `A + [X]` is typed from A and takes the parentheses (plan S5,
  probes dynarr). A set expression starting with `[` loses its check with
  them - it cannot be told from an array at parse time.

  Nor is any `@` (GExcludedAt): of a procedural variable, `@P` is a
  designator - `@P := GetProcAddress(...)` assigns the variable and `(@P)`
  is E2064 there, `F(@P)` passes it to a var parameter and `F((@P))` is
  E2197, and in an inline routine `LPARAM((@P))` is stored differently -
  and a parse cannot tell a procedural variable from any other. The
  operator around it is still wrapped: `(@F = nil)`.

  Nor an operator that starts an initializer's value (GExcludedInit, see
  CollectInitStarts).

  Nor, in a unit whose own text turns D or L on (GLinesKept, see
  LinesKept), an operator whose last token does not share a line with the
  next (GExcludedLines). }
function EndsOnLineOfNext(ANode: Integer): Boolean; forward;

{ t1: the first token of every value where a `(` opens an AGGREGATE when
  the value's type is structured - the value of a typed constant or of an
  initialized variable, an element of an aggregate, the value of a record
  constant's field. An array of Char takes a string expression there, and
  parenthesized it is a one-element array constant: `C: array[0..5] of
  AnsiChar = 'abc' + 'def'` compiles, `= ('abc' + 'def')` is E2010
  'AnsiChar' and 'string', in each of the four positions; `(1 + 2)` for an
  Integer, a string, a set or a Byte element compiles (plan S7, probes
  init-paren; mORMot's char tables). A parse cannot tell a structured type
  from a scalar one behind a name, so every such value start is recorded;
  an untyped constant's value takes the parentheses (no aggregate there). }
procedure CollectInitStarts(ANode: Integer);
var
  LChild, LFirst: Integer;
  LTyped: Boolean;
begin
  case GTree.Nodes[ANode].Kind of
    nkConstDecl, nkVarDecl:
      begin
        // A constant is typed when a `:` follows its name; a variable with
        // an initializer always is. The value is the child right after `=`.
        LTyped := GTree.Nodes[ANode].Kind = nkVarDecl;
        if not LTyped then
        begin
          LChild := GTree.Nodes[ANode].FirstChild;
          while (LChild <> NIL_NODE) and (GTree.Nodes[LChild].Kind <> nkIdent) do
            LChild := GTree.Nodes[LChild].NextSibling;
          LTyped := (LChild <> NIL_NODE) and
            (GTree.Nodes[LChild].LastToken < High(GPre.Visible)) and
            (GPre.VisibleToken(GTree.Nodes[LChild].LastToken + 1).Kind = tkColon);
        end;
        if LTyped then
        begin
          LChild := GTree.Nodes[ANode].FirstChild;
          while LChild <> NIL_NODE do
          begin
            LFirst := GTree.NodeLeftmostVis(LChild);
            if (LFirst > 0) and (GPre.VisibleToken(LFirst - 1).Kind = tkEqual) then
              GInitStarts.AddOrSetValue(LFirst, True);
            LChild := GTree.Nodes[LChild].NextSibling;
          end;
        end;
      end;
    nkAggregate:
      begin
        LChild := GTree.Nodes[ANode].FirstChild;
        while LChild <> NIL_NODE do
        begin
          if GTree.Nodes[LChild].Kind <> nkAggregateField then
            GInitStarts.AddOrSetValue(GTree.NodeLeftmostVis(LChild), True);
          LChild := GTree.Nodes[LChild].NextSibling;
        end;
      end;
    nkAggregateField:
      begin
        LChild := GTree.Nodes[ANode].FirstChild;       // the field name
        if LChild <> NIL_NODE then
          LChild := GTree.Nodes[LChild].NextSibling;   // its value
        if LChild <> NIL_NODE then
          GInitStarts.AddOrSetValue(GTree.NodeLeftmostVis(LChild), True);
      end;
  end;
  LChild := GTree.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    CollectInitStarts(LChild);
    LChild := GTree.Nodes[LChild].NextSibling;
  end;
end;

procedure T1Walk(ANode: Integer; const ARoutine: string; ATypeStart: Integer);
var
  LChild: Integer;
  LRoutine: string;
begin
  LRoutine := ARoutine;
  case GTree.Nodes[ANode].Kind of
    nkAsmStmt:
      Exit;
    nkRoutine:
      begin
        LRoutine := RoutineName(ANode);
        if ARoutine <> '' then
          LRoutine := ARoutine + '.' + LRoutine;
      end;
    nkInitSec:
      LRoutine := GUnitName;
    nkFinalSec:
      LRoutine := 'Finalization';
    nkSubrange:
      ATypeStart := GTree.NodeLeftmostVis(ANode);
    nkBinaryOp, nkUnaryOp, nkInlineIf:
      begin
        if GTree.NodeLeftmostVis(ANode) = ATypeStart then
          Inc(GExcluded)
        else if GPre.VisibleToken(GTree.NodeLeftmostVis(ANode)).Kind =
                tkLBracket then
          Inc(GExcludedCtor)
        else if GInitStarts.ContainsKey(GTree.NodeLeftmostVis(ANode)) then
          Inc(GExcludedInit)
        else if (GTree.Nodes[ANode].Kind = nkUnaryOp) and
                (OpText(ANode) = '@') then
          Inc(GExcludedAt)
        else if GLinesKept and not EndsOnLineOfNext(ANode) then
          Inc(GExcludedLines)
        else
          AddParenSite(GTree.KindName(GTree.Nodes[ANode].Kind), OpsOf(ANode),
            ANode, ARoutine);
      end;
  end;
  LChild := GTree.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    T1Walk(LChild, LRoutine, ATypeStart);
    LChild := GTree.Nodes[LChild].NextSibling;
  end;
end;

{ t2: whether AChild, the AIndex-th child (from 0) of AParent, stands where
  a statement does: an item of a statement list - a compound statement, a
  routine's or a program's block, the list of a case-else, a try, an
  except, a finally or a repeat, an initialization or finalization section
  - an if's then or else, a case branch's body, the body of a for, a while,
  a with or an exception handler, the statement a label marks. A statement
  list itself stands in none: `try`, `except`, `repeat` and the rest
  bracket it with words of their own. }
function InStatementPosition(AParent, AIndex, AChild: Integer): Boolean;
begin
  case GTree.Nodes[AParent].Kind of
    nkBlock, nkInitSec, nkFinalSec:
      Result := True;
    nkIfStmt, nkCaseSel:
      Result := AIndex >= 1;
    nkForStmt, nkForInStmt, nkWhileStmt, nkWithStmt, nkExceptOn,
    nkLabeledStmt:
      Result := GTree.Nodes[AChild].NextSibling = NIL_NODE;
  else
    Result := False;
  end;
end;

{ t2, for the report: where statement AIndex of AParent stands. }
function PositionName(AParent, AIndex: Integer): string;
var
  LUp: Integer;
begin
  case GTree.Nodes[AParent].Kind of
    nkBlock:
      begin
        LUp := GTree.Nodes[AParent].Parent;
        if LUp = NIL_NODE then
          Exit('list');
        case GTree.Nodes[LUp].Kind of
          nkCaseStmt: Result := 'case-else';
          nkTryStmt: Result := 'try';
          nkFinallyPart: Result := 'finally';
          nkExceptPart:
            if GTree.Nodes[GTree.Nodes[LUp].FirstChild].Kind = nkExceptOn then
              Result := 'except-else'
            else
              Result := 'except';
          nkRepeatStmt: Result := 'repeat';
          nkRoutineBody, nkProgram, nkLibrary: Result := 'body';
        else
          Result := 'begin';
        end;
      end;
    nkInitSec: Result := 'init';
    nkFinalSec: Result := 'final';
    nkIfStmt:
      if AIndex = 1 then
        Result := 'then'
      else
        Result := 'else';
    nkCaseSel: Result := 'case';
    nkExceptOn: Result := 'on';
    nkLabeledStmt: Result := 'label';
  else
    Result := 'do';
  end;
end;

{ t2, for the report: the statement's head - `if-else`, `raise-at`... }
function StatementHead(ANode: Integer): string;
var
  LLast: Integer;
begin
  LLast := GTree.Nodes[ANode].FirstChild;
  while (LLast <> NIL_NODE) and (GTree.Nodes[LLast].NextSibling <> NIL_NODE) do
    LLast := GTree.Nodes[LLast].NextSibling;
  case GTree.Nodes[ANode].Kind of
    nkBlock: Result := 'begin';
    nkEmptyStmt: Result := 'empty';
    nkAssign: Result := ':=';
    nkExprStmt: Result := 'call';
    nkIfStmt:
      if Child(ANode, 2) <> NIL_NODE then
        Result := 'if-else'
      else
        Result := 'if';
    nkCaseStmt:
      if (LLast <> NIL_NODE) and (GTree.Nodes[LLast].Kind = nkBlock) then
        Result := 'case-else'
      else
        Result := 'case';
    nkForStmt: Result := 'for';
    nkForInStmt: Result := 'for-in';
    nkWhileStmt: Result := 'while';
    nkRepeatStmt: Result := 'repeat';
    nkWithStmt: Result := 'with';
    nkGotoStmt: Result := 'goto';
    nkTryStmt:
      if (LLast <> NIL_NODE) and (GTree.Nodes[LLast].Kind = nkFinallyPart) then
        Result := 'try-finally'
      else
        Result := 'try-except';
    nkRaiseStmt:
      if Child(ANode, 1) <> NIL_NODE then
        Result := 'raise-at'
      else
        Result := 'raise';
  else
    Result := GTree.KindName(GTree.Nodes[ANode].Kind);
  end;
end;

{ t2: a site wrapping statement ANode (child AIndex of AParent) in `begin`
  `end`: the `begin` right before its leftmost token, the `end` right BEFORE
  the token after it, on that token's line. dcc takes a line from the token
  that follows a statement, and Assert passes it to the code: a then-branch
  `Assert(X)` with `else` on the next line reports the `else`'s line, and an
  `end` right after the `)` would give the Assert a line of its own (plan
  S7, probes assert-line). When the token after lies in another file, the
  `end` goes right after the statement. An empty statement owns no token:
  it becomes `begin end` right AFTER the token before it - the `then`,
  `else`, `do` or `:` of the statement it ends, ahead of that statement's
  own `end` (`if A then ;` -> `if A then begin end  end ;`). Dropped and
  counted like t1's: both ends in one file, not in a file included twice.
  The words go in with a blank on either side - `do(P).X` and `F(X)else`
  would glue to them otherwise. }
procedure AddBlockSite(AParent, AIndex, ANode: Integer; const ARoutine: string);
var
  LFirst, LLast, LFileA, LFileB: Integer;
  LSite: TSite;
begin
  if GTree.Nodes[ANode].Kind = nkEmptyStmt then
  begin
    LFirst := GTree.Nodes[ANode].FirstToken - 1;
    LLast := LFirst;
  end
  else
  begin
    LFirst := GTree.NodeLeftmostVis(ANode);
    LLast := GTree.Nodes[ANode].LastToken;
  end;
  VisOffset(LFirst, LFileA);
  VisOffset(LLast, LFileB);
  if (LFileA <> LFileB) or GIncludedTwice[LFileA] then
  begin
    Inc(GDropped);
    Exit;
  end;
  LSite.Kind := GTree.KindName(GTree.Nodes[ANode].Kind);
  LSite.Ops := PositionName(AParent, AIndex) + ':' + StatementHead(ANode);
  LSite.Span := SpanText(LFirst, LLast);
  LSite.Routine := ARoutine;
  LSite.OpenVis := LFirst;
  LSite.CloseVis := LLast;
  LSite.CloseBefore := False;
  if GTree.Nodes[ANode].Kind = nkEmptyStmt then
  begin
    LSite.Edit := 'begin end after';
    LSite.OpenAfter := True;
    LSite.OpenText := ' begin end ';
    LSite.OpenOrder := 0;
    LSite.CloseText := '';
    LSite.CloseOrder := 0;
  end
  else
  begin
    LSite.Edit := 'begin/end';
    LSite.OpenAfter := False;
    LSite.OpenText := ' begin ';
    LSite.OpenOrder := 2;
    LSite.CloseText := ' end ';
    LSite.CloseOrder := 1;
    if LLast < High(GPre.Visible) then
    begin
      VisOffset(LLast + 1, LFileB);
      if LFileB = LFileA then
      begin
        LSite.CloseVis := LLast + 1;
        LSite.CloseBefore := True;
      end;
    end;
  end;
  GSites.Add(LSite);
end;

{ t2: the last name part of routine ARoutine, lower case - `m` for
  `function TG<T>.M`. }
function LastNamePart(ARoutine: Integer): string;
var
  LName: string;
begin
  LName := RoutineName(ARoutine);
  Result := LowerCase(Copy(LName, LastDelimiter('.', LName) + 1, MaxInt));
end;

{ t2: GInlineNames - every routine with an `inline` directive, at its
  declaration or its implementation (a method's is usually on the one in
  the class). }
procedure CollectInlineNames(ANode: Integer);
var
  LChild: Integer;
begin
  if GTree.Nodes[ANode].Kind = nkRoutine then
  begin
    LChild := GTree.Nodes[ANode].FirstChild;
    while LChild <> NIL_NODE do
    begin
      if (GTree.Nodes[LChild].Kind = nkDirective) and
         SameText(GTree.NodeText(LChild), 'inline') then
        GInlineNames.AddOrSetValue(LastNamePart(ANode), True);
      LChild := GTree.Nodes[LChild].NextSibling;
    end;
  end;
  LChild := GTree.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    CollectInlineNames(LChild);
    LChild := GTree.Nodes[LChild].NextSibling;
  end;
end;

{ t2: whether routine ARoutine's body is one dcc STORES in the .dcu - a
  generic's (its name has generic parameters at any level: `TG<T>.M`,
  `TFoo.M<T>`, `TOuter<T>.TInner.M`), to be instantiated elsewhere, or an
  inline routine's, to be expanded elsewhere. A stored body keeps source
  LINES, whatever -$D, -$L and -$Y say (probed on dcc64 37.0; -$C-, -$O+
  change nothing either). Around a statement that spans lines, or whose
  next token lies on another line, a begin/end changes the stored bytes -
  `FIdx :=` / `3;` / `Result := True;` by 5 bytes in a generic method and
  in an inline function; a then-branch followed by `else` on the next line
  in Studio's inline getters and generic methods, where the line comes from
  the token after the statement, as in the code-lines record, and the
  begin/end makes that token its `end`. Around a statement that shares one
  line with the token after it they never did, in any position probed
  (plan S6, probes pairs-generic*, pairs-inline). A name declared `inline`
  counts for every routine of that name in the unit: an overload not
  declared so is left out too, which only costs sites. }
function IsStoredBody(ARoutine: Integer): Boolean;
var
  LChild: Integer;
begin
  LChild := GTree.Nodes[ARoutine].FirstChild;
  while (LChild <> NIL_NODE) and
        (GTree.Nodes[LChild].Kind in [nkIdent, nkGenericParams, nkTypeArgs]) do
  begin
    if GTree.Nodes[LChild].Kind <> nkIdent then
      Exit(True);
    LChild := GTree.Nodes[LChild].NextSibling;
  end;
  Result := GInlineNames.ContainsKey(LastNamePart(ARoutine));
end;

// The line visible token AVis starts on, and its file.
function VisLine(AVis: Integer; out AFileId: Integer): Integer;
var
  LCol: Integer;
begin
  GPre.Files[GPre.Visible[AVis].FileId].OffsetToLineCol(
    VisOffset(AVis, AFileId), Result, LCol);
end;

{ t2: whether statement ANode, AND the token after it, lie on one line - the
  only shape a stored body takes a begin/end around unchanged (see
  IsStoredBody). An empty statement: the tokens before and after it. }
function OnOneLine(ANode: Integer): Boolean;
var
  LFirst, LLast, LFile, LLine, LOtherFile: Integer;
begin
  if GTree.Nodes[ANode].Kind = nkEmptyStmt then
  begin
    LFirst := GTree.Nodes[ANode].FirstToken - 1;
    LLast := LFirst;
  end
  else
  begin
    LFirst := GTree.NodeLeftmostVis(ANode);
    LLast := GTree.Nodes[ANode].LastToken;
  end;
  LLine := VisLine(LFirst, LFile);
  Result := (VisLine(LLast, LOtherFile) = LLine) and (LOtherFile = LFile);
  if Result and (LLast < High(GPre.Visible)) then
    Result := (VisLine(LLast + 1, LOtherFile) = LLine) and (LOtherFile = LFile);
end;

{ t1: whether the last token of node ANode and the token after it lie on
  one line - the `)` then leaves every line the unit records as it was (see
  LinesKept). }
function EndsOnLineOfNext(ANode: Integer): Boolean;
var
  LLast, LFile, LOtherFile: Integer;
begin
  LLast := GTree.Nodes[ANode].LastToken;
  Result := (LLast >= High(GPre.Visible)) or
    ((VisLine(LLast + 1, LOtherFile) = VisLine(LLast, LFile)) and
     (LOtherFile = LFile));
end;


{ t2: every statement of the subtree at ANode as a site, in pre-order (a
  statement before the ones inside it); ARoutine as in T1Walk. AStored:
  ANode lies in a stored body (IsStoredBody). AInList: ANode stands as an
  item of a statement list - directly, or as the statement a label marks
  that does.

  Besides the kinds never wrapped (see the header), two rules, each from a
  probe (plan S6):
  - a CALL statement standing as a list item is not wrapped (counted in
    GExcludedCall): when the call discards a managed result - a string, an
    interface, a dynamic array, a record with managed fields - dcc
    finalizes the temporary holding it at the end of the statement LIST
    the call stands in (a routine's own list: in its epilogue), so a
    begin/end of its own moves the finalization up to the call - `S;` /
    `Y := 1;` differs from `begin S end;` / `Y := 1;` by 17 bytes. A parse
    cannot tell a function from a procedure, nor a managed result from any
    other. As the body of an if, a loop, a case branch, a with or an
    exception handler the temporary is the statement's own and the
    begin/end changes nothing; under a label it is the label's list's.
  - in a stored body, a statement that does not share one line with the
    token after it (counted in GExcludedStored) - see IsStoredBody; the
    same in a unit whose own text turns D, L or Y on (GLinesKept, counted
    in GExcludedLines) - see LinesKept. }
procedure T2Walk(ANode: Integer; const ARoutine: string; AStored,
  AInList: Boolean);
var
  LChild, LIndex: Integer;
  LRoutine: string;
  LInList: Boolean;
begin
  LRoutine := ARoutine;
  case GTree.Nodes[ANode].Kind of
    nkAsmStmt:
      Exit;
    nkRoutine:
      begin
        LRoutine := RoutineName(ANode);
        if ARoutine <> '' then
          LRoutine := ARoutine + '.' + LRoutine;
        // A nested routine or an anonymous method is part of the body it
        // is written in: stored with it.
        AStored := AStored or IsStoredBody(ANode);
      end;
    nkInitSec:
      LRoutine := GUnitName;
    nkFinalSec:
      LRoutine := 'Finalization';
  end;
  LChild := GTree.Nodes[ANode].FirstChild;
  LIndex := 0;
  while LChild <> NIL_NODE do
  begin
    LInList := (GTree.Nodes[ANode].Kind in [nkBlock, nkInitSec, nkFinalSec]) or
      ((GTree.Nodes[ANode].Kind = nkLabeledStmt) and AInList and
       (GTree.Nodes[LChild].NextSibling = NIL_NODE));
    if InStatementPosition(ANode, LIndex, LChild) then
      case GTree.Nodes[LChild].Kind of
        nkInlineVar, nkInlineConst:
          Inc(GExcludedInline);
        nkLabeledStmt:
          Inc(GExcludedLabel);
        nkAsmStmt:
          Inc(GExcludedAsm);
        nkBlock, nkEmptyStmt, nkAssign, nkExprStmt, nkIfStmt, nkCaseStmt,
        nkForStmt, nkForInStmt, nkWhileStmt, nkRepeatStmt, nkWithStmt,
        nkGotoStmt, nkTryStmt, nkRaiseStmt:
          if (GTree.Nodes[LChild].Kind = nkExprStmt) and LInList then
            Inc(GExcludedCall)
          else if AStored and not OnOneLine(LChild) then
            Inc(GExcludedStored)
          else if GLinesKept and not OnOneLine(LChild) then
            Inc(GExcludedLines)
          else
            AddBlockSite(ANode, LIndex, LChild, LRoutine);
      end;
    T2Walk(LChild, LRoutine, AStored, LInList);
    LChild := GTree.Nodes[LChild].NextSibling;
    Inc(LIndex);
  end;
end;

type
  TSiteRange = record
    Lo, Hi: Integer;
  end;

var
  // -sites: the ids (1-based) whose edits are applied; empty = all.
  GSiteRanges: TList<TSiteRange>;

procedure ParseSiteList(const AText: string);
var
  LPart: string;
  LDash: Integer;
  LRange: TSiteRange;
begin
  for LPart in AText.Split([',']) do
  begin
    if Trim(LPart) = '' then
      Continue;
    LDash := Pos('-', LPart);
    if LDash > 0 then
    begin
      LRange.Lo := StrToInt(Trim(Copy(LPart, 1, LDash - 1)));
      LRange.Hi := StrToInt(Trim(Copy(LPart, LDash + 1, MaxInt)));
    end
    else
    begin
      LRange.Lo := StrToInt(Trim(LPart));
      LRange.Hi := LRange.Lo;
    end;
    GSiteRanges.Add(LRange);
  end;
  if GSiteRanges.Count = 0 then
    raise Exception.Create('-sites: no id given');
end;

function SiteSelected(AId: Integer): Boolean;
var
  LRange: TSiteRange;
begin
  if GSiteRanges.Count = 0 then
    Exit(True);
  for LRange in GSiteRanges do
    if (AId >= LRange.Lo) and (AId <= LRange.Hi) then
      Exit(True);
  Result := False;
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

{ Whether directive token AText turns on a switch of ALetters, from the
  family whose records keep source lines: D (DEBUGINFO), L (LOCALSYMBOLS),
  Y (REFERENCEINFO; YD and DEFINITIONINFO turn it on for definitions) -
  `$D+`, `$O-,Y+`, `$YD`, `$DEFINITIONINFO ON` (braces left out here: a
  directive in a brace comment ends it). `$L file.obj` and `$D text` are
  other directives. }
function LineInfoOn(const AText: string; const ALetters: TSysCharSet): Boolean;
var
  LWord, LBody: string;
  LStart, LIdx: Integer;
begin
  LWord := DirectiveWord(AText, LStart);
  LBody := UpperCase(DirectiveTrail(AText));
  if (LWord = 'DEBUGINFO') or (LWord = 'LOCALSYMBOLS') or
     (LWord = 'REFERENCEINFO') or (LWord = 'DEFINITIONINFO') then
  begin
    if not (LBody.StartsWith('ON') and
            ((Length(LBody) = 2) or not CharInSet(LBody[3], ['A'..'Z']))) then
      Exit(False);
    if LWord[1] = 'R' then
      Exit(CharInSet('Y', ALetters))
    else if LWord[1] = 'D' then
      if LWord = 'DEBUGINFO' then
        Exit(CharInSet('D', ALetters))
      else
        Exit(CharInSet('Y', ALetters));
    Exit(CharInSet('L', ALetters));
  end;
  if LWord = 'YD' then
    Exit(CharInSet('Y', ALetters));
  Result := False;
  if Length(LWord) <> 1 then
    Exit;
  // The short form, a comma list: X+ X- YD Zn ...
  LBody := LWord + LBody;
  LIdx := 1;
  while LIdx < Length(LBody) do
  begin
    if not CharInSet(LBody[LIdx], ['A'..'Z']) then
      Exit;
    if CharInSet(LBody[LIdx + 1], ['+', '-']) then
    begin
      if (LBody[LIdx + 1] = '+') and CharInSet(LBody[LIdx], ALetters) then
        Exit(True);
    end
    else if (LBody[LIdx] = 'Y') and (LBody[LIdx + 1] = 'D') then
    begin
      if CharInSet('Y', ALetters) then
        Exit(True);
    end
    else if not CharInSet(LBody[LIdx + 1], ['0'..'9']) then
      Exit;
    Inc(LIdx, 2);
    while (LIdx <= Length(LBody)) and
          CharInSet(LBody[LIdx], ['0'..'9', ',', ' ', #9]) do
      Inc(LIdx);
  end;
end;

{ t1, t2 (rule R3): whether the unit's own text - the unit or an include,
  outside every region the preprocessor skipped - turns on a switch of
  ALetters (see LineInfoOn). The harness compiles t1 with -$D- -$L- and t2
  with -$Y- as well, because those records keep the line of the token AFTER
  a construct (plan S5, S6); a directive in the source overrides the
  command line. Spring4D's include turns DEFINITIONINFO on: a then-branch
  constructing a generic of the unit's own, `X := TField<Int64>.Create(...)`
  with `else` on the next line, records the `else`'s line, and its
  begin/end - or moving the `else` up a line, no block at all - changes one
  byte (plan S7, probes geninst3 yd-*, and the unit itself). Such a unit
  takes a site only where no recorded line can move: t2 a statement on one
  line with the token after it (as in a stored body), t1 an operator whose
  last token shares a line with the next. A whole unit, whatever the
  directive's position - conservative, and rare (no Studio unit). }
function LinesKept(const ALetters: TSysCharSet): Boolean;
var
  LFile, LTok, LStart: Integer;
  LRegion: TPasSkippedRegion;
  LLive: Boolean;
begin
  for LFile := 0 to High(GPre.Files) do
    for LTok := 0 to High(GPre.Files[LFile].Tokens) do
      if (GPre.Files[LFile].Tokens[LTok].Kind = tkDirective) and
         LineInfoOn(GPre.Files[LFile].TokenText(LTok), ALetters) then
      begin
        LStart := GPre.Files[LFile].Tokens[LTok].Start;
        LLive := True;
        for LRegion in GPre.Skipped[LFile] do
          if (LStart >= LRegion.Start) and (LStart < LRegion.EndPos) then
          begin
            LLive := False;
            Break;
          end;
        if LLive then
          Exit(True);
      end;
  Result := False;
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
  GIdx, GJdx, GNonInfo, GOffset, GApplied: Integer;
  GSite: TSite;
  GName: string;
  GWritten: TDictionary<string, Boolean>;
  GSitesText, GFileLines: TStringList;
  GNamespaces: TArray<string>;
  GHasNamespaces: Boolean;

{ -oracle: the unit scope names the project analysis resolves a unit name
  with - the compile's own (-NS:, the driver passes dcc's), else the IDE's
  default for the platform. Without them `uses AnsiStrings` found nothing
  and a `$IF Declared(StrScan)` after it stayed a guess (plan S7: a harness
  defect, not PasTree's - every other tool sets them). }
function ProjectNamespaces: TArray<string>;
begin
  if GHasNamespaces then
    Result := GNamespaces
  else
    Result := PasDefaultNamespaces(GPlatform);
end;

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
    GSiteRanges := TList<TSiteRange>.Create;
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
      if GArg.StartsWith('-NS:', True) then
      begin
        GNamespaces := nil;
        for GName in Copy(GArg, 5, MaxInt).Split([';']) do
          if Trim(GName) <> '' then
            GNamespaces := GNamespaces + [Trim(GName)];
        GHasNamespaces := True;
        Continue;
      end;
      if GArg.StartsWith('-sites:', True) then
      begin
        ParseSiteList(Copy(GArg, 8, MaxInt));
        Continue;
      end;
      if GArg.StartsWith('-mode:', True) then
      begin
        GArg := LowerCase(Copy(GArg, 7, MaxInt));
        if GArg = 't0' then GMode := xmT0
        else if GArg = 'ts' then GMode := xmTS
        else if GArg = 't0f' then GMode := xmT0F
        else if GArg = 't1' then GMode := xmT1
        else if GArg = 't2' then GMode := xmT2
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
      Writeln(ErrOutput, 'Usage: PasTreeXform <unit.pas> -mode:t0|ts|t0f|t1|t2 ' +
        '-out:<dir> [-p:<platform>] [-D:X;Y]... [-Undef:X;Y]... ' +
        '[-I:<dir>[;<dir>]]... [-oracle [-S:<dir>[;<dir>]]...] ' +
        '[-sites:<ids>]');
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
    GInlineNames := TDictionary<string, Boolean>.Create;
    GInitStarts := TDictionary<Integer, Boolean>.Create;
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

      if GOracle and (GUndefNames.Count > 0) then
        raise Exception.Create('-Undef cannot reach a project analysis: ' +
          'use -oracle without it');
      if GOracle and OracleCouldMatter(GPre) then
      begin
        // The stream PasTree really analyzes: the project's first pass
        // (compiler-provided names answered) and its second, the oracle's.
        GProject := TPasSemaProject.Create(GPlatform,
          GSearch.ToArray + GIncDirs.ToArray, GDefNames.ToArray);
        GProject.SetNamespaces(ProjectNamespaces);
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
      end;

      SetLength(GIncludedTwice, Length(GPre.FileNames));
      for GIdx := 0 to High(GPre.FileNames) do
        for GJdx := 0 to High(GPre.FileNames) do
          if (GIdx <> GJdx) and
             SameText(GPre.FileNames[GIdx], GPre.FileNames[GJdx]) then
            GIncludedTwice[GIdx] := True;

      GDiags := nil;
      GApplied := 0;
      if GMode in [xmTS, xmT1, xmT2] then
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
        case GMode of
          xmTS: VisitRoutines(0, '');
          xmT1:
            begin
              GLinesKept := LinesKept(['D', 'L']);
              CollectInitStarts(0);
              T1Walk(0, '', -2);
            end;
        else
          GLinesKept := LinesKept(['D', 'L', 'Y']);
          CollectInlineNames(0);
          T2Walk(0, '', False, False);
        end;
        for GIdx := 0 to GSites.Count - 1 do
          if SiteSelected(GIdx + 1) then
          begin
            GSite := GSites[GIdx];
            AddEdit(GSite.OpenVis, GSite.OpenAfter, GSite.OpenOrder,
              GSite.OpenText);
            if GSite.CloseText <> '' then
              AddEdit(GSite.CloseVis, not GSite.CloseBefore, GSite.CloseOrder,
                GSite.CloseText);
            Inc(GApplied);
          end;
      end
      else if GMode = xmT0F then
      begin
        if GOracleUsed then
          GLiveness :=
            function(const APaths, ATexts: TArray<string>): TPasPreprocessed
            var
              LProject: TPasSemaProject;
              LId, LIdx: Integer;
            begin
              LProject := TPasSemaProject.Create(GPlatform,
                GSearch.ToArray + GIncDirs.ToArray, GDefNames.ToArray);
              try
                LProject.SetNamespaces(ProjectNamespaces);
                for LIdx := 0 to High(APaths) do
                  LProject.SetBuffer(APaths[LIdx], ATexts[LIdx]);
                LId := LProject.AnalyzeProject(GFile);
                if LId < 0 then
                  raise Exception.Create('the liveness analysis failed');
                Result := LProject.Model(LId).Tree.Source;
              finally
                LProject.Free;
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
          GSite.OpenVis := -1;
          GSite.CloseVis := -1;
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
        'dropped-sites=%d  excluded-type=%d  excluded-ctor=%d  ' +
        'excluded-at=%d  excluded-inline=%d  excluded-label=%d  ' +
        'excluded-asm=%d  excluded-call=%d  excluded-stored=%d  ' +
        'excluded-lines=%d  excluded-init=%d  applied=%d  stream=%s',
        [PasTreeVersion, cModeNames[GMode], PlatformName(GPlatform),
        Length(GPre.FileNames), Length(GDiags), GNonInfo, GDropped, GExcluded,
        GExcludedCtor, GExcludedAt, GExcludedInline, GExcludedLabel,
        GExcludedAsm, GExcludedCall, GExcludedStored, GExcludedLines,
        GExcludedInit, GApplied, IfThen(GOracleUsed, 'project',
        'preprocessor')]));
      GSitesText.Add('# ' + GFile);
      GSitesText.Add('# id' + #9 + 'kind' + #9 + 'ops' + #9 + 'span' + #9 +
        'routine' + #9 + 'edit' + #9 + 'applied');
      for GIdx := 0 to GSites.Count - 1 do
      begin
        GSite := GSites[GIdx];
        GSitesText.Add(Format('%d'#9'%s'#9'%s'#9'%s'#9'%s'#9'%s'#9'%d',
          [GIdx + 1, GSite.Kind, GSite.Ops, GSite.Span, GSite.Routine,
          GSite.Edit, Ord((GSite.OpenVis >= 0) and SiteSelected(GIdx + 1))]));
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
      if GExcluded > 0 then
        GLine := GLine + ' excluded-type ' + IntToStr(GExcluded);
      if GExcludedCtor > 0 then
        GLine := GLine + ' excluded-ctor ' + IntToStr(GExcludedCtor);
      if GExcludedAt > 0 then
        GLine := GLine + ' excluded-at ' + IntToStr(GExcludedAt);
      if GExcludedInline > 0 then
        GLine := GLine + ' excluded-inline ' + IntToStr(GExcludedInline);
      if GExcludedLabel > 0 then
        GLine := GLine + ' excluded-label ' + IntToStr(GExcludedLabel);
      if GExcludedAsm > 0 then
        GLine := GLine + ' excluded-asm ' + IntToStr(GExcludedAsm);
      if GExcludedCall > 0 then
        GLine := GLine + ' excluded-call ' + IntToStr(GExcludedCall);
      if GExcludedStored > 0 then
        GLine := GLine + ' excluded-stored ' + IntToStr(GExcludedStored);
      if GExcludedLines > 0 then
        GLine := GLine + ' excluded-lines ' + IntToStr(GExcludedLines);
      if GExcludedInit > 0 then
        GLine := GLine + ' excluded-init ' + IntToStr(GExcludedInit);
      if GMode in [xmTS, xmT1, xmT2] then
        GLine := GLine + ' applied ' + IntToStr(GApplied);
      Writeln('sites ', GLine);
      if GMode in [xmTS, xmT1, xmT2] then
        Writeln('parse ', Length(GDiags));
      if GOracleUsed and (GMode <> xmT0F) then
        Writeln('stream project');
      if GMode = xmT0F then
      begin
        for GName in GArgMap.Keys do
          Writeln('argmap ', GName, #9, GArgMap[GName]);
        Writeln('flatten ', GFlatStats);
      end;
    finally
      GInitStarts.Free;
      GInlineNames.Free;
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
      GSiteRanges.Free;
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
