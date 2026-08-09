unit PasTree.TestKit;

{
  Shared golden-test infrastructure (test-coverage plan step 2+5): a case is
  DATA -- a (section, name, source, expected) row -- not 30 lines of Pascal
  string concatenation inside a suite's own .dpr. A suite unit (e.g.
  PasTree.Tests.Parser) declares its rows as plain const arrays of
  TPasCaseRow; the .dpr host becomes the thin part, just wiring a
  TPasPreprocessor to RunSuite. Anything that does not fit the
  (source, expected-dump) shape -- a platform matrix, a filesystem fixture --
  is a TPasCustomCase instead, so the report stays uniform without forcing
  every check into the same string comparison.

  This unit is deliberately UI-agnostic: RunStmtCase/RunDeclCase/RunCustomCase
  return a verdict and say nothing to stdout, so a future demo view can call
  them directly instead of scraping a console suite's output. RunSuite is the
  console formatting on top, reused by every thin .dpr host.
}

interface

uses
  System.SysUtils,
  System.Math,
  PasTree.Types,
  PasTree.Lexer,
  PasTree.Ast,
  PasTree.Preprocessor,
  PasTree.Parser;

type
  { One golden case, as DATA. Source is what gets parsed; Expected is the
    exact S-expression dump (TPasTree.Dump) it must produce. ExpectDiags is
    the parse-diagnostic count, almost always 0 -- a case that expects an
    error is the rare, deliberate exception and says so in its own name. }
  TPasCaseRow = record
    Section: string;   // spec numbering, e.g. '5.1.1' or 'B.6.3'
    Name: string;       // short label, e.g. 'assign'
    Source: string;
    Expected: string;
    ExpectDiags: Integer;
  end;

  { The verdict for one case, independent of how it gets displayed. }
  TPasCheckResult = record
    Passed: Boolean;
    Message: string;   // multi-line failure detail; '' when Passed
  end;

  { A case that is not a plain dump comparison (a platform matrix, an include
    search-path fixture, a lexer-diagnostic-lines check...). Run is a zero-arg
    closure: it captures whatever preprocessor/source-manager/temp directory
    it needs at construction time, since those vary per case family. }
  TPasCustomCase = record
    Section: string;
    Name: string;
    Run: TFunc<TPasCheckResult>;
  end;

  TPasCaseRows = array of TPasCaseRow;
  TPasCustomCases = array of TPasCustomCase;

  { Shared pass/fail bookkeeping for the OTHER suites (SemaSmoke,
    SemaProjectSmoke, ...): a fixture is built ONCE (a source string, a temp
    project directory) and several `Ok` calls assert different things
    against that one piece of state, which doesn't decompose into
    independent (source, expected) rows or zero-arg closures without either
    re-running the fixture per assertion or renaming every case. Twelve
    suites carried an IDENTICAL ~10-line `Ok`/counters/summary-footer copy
    before this existed; this is that copy, written once. A suite keeps its
    own case bodies and every `Ok('name', cond)` call site UNTOUCHED --
    only the counter declaration, the `Ok` PROCEDURE BODY, and the closing
    summary line change to route through this instead. }
  TPasSuiteCounter = record
    Passed, Failed: Integer;
    procedure Init;
    { AOnFail, given, runs AFTER the FAIL line -- e.g. SemaSmoke's own
      Ok dumping DumpSemaModel(GModel), context only that suite's state can
      provide. }
    procedure Ok(const AName: string; ACond: Boolean; AOnFail: TProc = nil);
    { Prints '=== <name>: N passed, M failed ===' and returns True when the
      caller should set ExitCode := 1. }
    function Finish(const ASuiteName: string): Boolean;
  end;

{ Runs ARow.Source through ParseStatements and compares the whole tree's dump.
  The statement-level counterpart of RunDeclCase; see the unit comment. }
function RunStmtCase(APP: TPasPreprocessor; const ARow: TPasCaseRow):
  TPasCheckResult;

{ Runs ARow.Source through ParseFile, wrapped in a minimal unit ('unit
  Test; interface <ASource> implementation end.'), and compares the DUMP OF
  THE INTERFACE SECTION'S OWN CHILDREN, joined by a space -- so Expected
  stays about the declaration and says nothing about the wrapper. The
  declaration-level counterpart of RunStmtCase (test-coverage plan step 1). }
function RunDeclCase(APP: TPasPreprocessor; const ARow: TPasCaseRow):
  TPasCheckResult;

{ Builds a passing/failing TPasCheckResult from a comparison, formatting the
  failure the same way every case family has always formatted it (source /
  expected / actual, plus a diag dump when the diag count is also wrong). Used
  by RunStmtCase/RunDeclCase and available to a suite's own custom cases so
  hand-written checks look the same as the generated ones on failure. }
function CheckDump(const ASource, AExpected, AActual: string;
  const ADiags: TArray<TPasParseDiag>; AExpectDiags: Integer): TPasCheckResult;

{ Definition-of-done item 2: the lexer is FULL-FIDELITY -- every character of
  ASource comes out as part of exactly one token (trivia included), so
  concatenating every token's text reproduces ASource byte-for-byte, even for
  malformed input (an unterminated string, an invalid character) that also
  raises a diagnostic. This tokenizes ASource itself and concatenates the
  TEXT, rather than trusting Start/Len bookkeeping never to lie, so a bug
  that still tiled the offsets right but sliced the wrong text would still
  be caught. AFirstMismatch is the 0-based offset of the first differing
  character, -1 when it holds. }
function RoundtripHolds(const ASource: string; out AFirstMismatch: Integer):
  Boolean;

{ Wraps RoundtripHolds as a TPasCustomCase, formatting a failure with the
  offset and a short window of context around it -- the direct counterpart of
  CheckDump for the one property that is not a dump comparison at all. }
function RoundtripCase(const ASection, AName, ASource: string):
  TPasCustomCase;

{ test-coverage plan step 3 batch 5: a compiler-OPTION-state case (1.3.1
  switch directives, 1.3.4 $PUSHOPT/$POPOPT) -- neither has an AST shape to
  dump, so this is their observation surface: process ASource, then read
  APP.SwitchState(ASwitch) (or APP.ScopedEnumsFinal when ASwitch = #0, the
  one option $PUSHOPT/$POPOPT also saves that isn't a single letter) and
  compare against AExpected. The direct counterpart of CheckDump/
  RoundtripHolds for the one property that is COMPILER STATE, not a tree or
  a token stream. }
function SwitchCase(const ASection, AName, ASource: string; ASwitch: Char;
  AExpected: Boolean; APP: TPasPreprocessor): TPasCustomCase;

{ Runs every row/case, printing PASS/FAIL to stdout exactly like the suites
  did before this unit existed, and prints the '=== <name>: N passed, M
  failed ===' footer. This is the whole body of a thin .dpr host now. }
procedure RunSuite(const ASuiteName: string; APP: TPasPreprocessor;
  const AStmtRows, ADeclRows: array of TPasCaseRow;
  const ACustom: array of TPasCustomCase; out APassed, AFailed: Integer);

implementation

procedure TPasSuiteCounter.Init;
begin
  Passed := 0;
  Failed := 0;
end;

procedure TPasSuiteCounter.Ok(const AName: string; ACond: Boolean;
  AOnFail: TProc);
begin
  if ACond then
  begin
    Inc(Passed);
    Exit;
  end;
  Inc(Failed);
  Writeln('FAIL: ', AName);
  if Assigned(AOnFail) then
    AOnFail();
end;

function TPasSuiteCounter.Finish(const ASuiteName: string): Boolean;
begin
  Writeln(Format('=== %s: %d passed, %d failed ===',
    [ASuiteName, Passed, Failed]));
  Result := Failed > 0;
end;

function CheckDump(const ASource, AExpected, AActual: string;
  const ADiags: TArray<TPasParseDiag>; AExpectDiags: Integer): TPasCheckResult;
var
  LIdx: Integer;
  LMsg: string;
begin
  Result.Passed := (AActual = AExpected) and (Length(ADiags) = AExpectDiags);
  if Result.Passed then
  begin
    Result.Message := '';
    Exit;
  end;
  LMsg := '  source:   ' + ASource + sLineBreak +
    '  expected: ' + AExpected + sLineBreak +
    '  actual:   ' + AActual + sLineBreak;
  if Length(ADiags) <> AExpectDiags then
  begin
    LMsg := LMsg + '  diags (expected ' + IntToStr(AExpectDiags) + '):' +
      sLineBreak;
    for LIdx := 0 to High(ADiags) do
      LMsg := LMsg + '    @' + IntToStr(ADiags[LIdx].VisIndex) + ': ' +
        ADiags[LIdx].Msg + sLineBreak;
  end;
  Result.Message := LMsg;
end;

function RoundtripHolds(const ASource: string; out AFirstMismatch: Integer):
  Boolean;
var
  LStream: TPasTokenStream;
  LSB: TStringBuilder;
  LIdx: Integer;
  LBuilt: string;
begin
  LStream := TPasLexer.Tokenize(ASource);
  LSB := TStringBuilder.Create(Length(ASource));
  try
    for LIdx := 0 to High(LStream.Tokens) do
      LSB.Append(LStream.TokenText(LIdx));
    LBuilt := LSB.ToString;
  finally
    LSB.Free;
  end;
  Result := LBuilt = ASource;
  if Result then
  begin
    AFirstMismatch := -1;
    Exit;
  end;
  AFirstMismatch := 0;
  while (AFirstMismatch < Length(ASource)) and
        (AFirstMismatch < Length(LBuilt)) and
        (ASource[AFirstMismatch + 1] = LBuilt[AFirstMismatch + 1]) do
    Inc(AFirstMismatch);
end;

function RoundtripCase(const ASection, AName, ASource: string):
  TPasCustomCase;
begin
  Result.Section := ASection;
  Result.Name := AName;
  Result.Run :=
    function: TPasCheckResult
    var
      LAt, LFrom, LTo: Integer;
    begin
      Result.Passed := RoundtripHolds(ASource, LAt);
      if Result.Passed then
      begin
        Result.Message := '';
        Exit;
      end;
      LFrom := Max(0, LAt - 20);
      LTo := Min(Length(ASource), LAt + 20);
      Result.Message := '  mismatch at offset ' + IntToStr(LAt) +
        ' of ' + IntToStr(Length(ASource)) + sLineBreak +
        '  source around it: ' +
        QuotedStr(Copy(ASource, LFrom + 1, LTo - LFrom)) + sLineBreak;
    end;
end;

function SwitchCase(const ASection, AName, ASource: string; ASwitch: Char;
  AExpected: Boolean; APP: TPasPreprocessor): TPasCustomCase;
begin
  Result.Section := ASection;
  Result.Name := AName;
  Result.Run :=
    function: TPasCheckResult
    var
      LActual: Boolean;
      LLabel: string;
    begin
      APP.ProcessText('test.pas', ASource);
      if ASwitch = #0 then
      begin
        LActual := APP.ScopedEnumsFinal;
        LLabel := 'SCOPEDENUMS';
      end
      else
      begin
        LActual := APP.SwitchState(ASwitch);
        LLabel := ASwitch;
      end;
      Result.Passed := LActual = AExpected;
      if Result.Passed then
      begin
        Result.Message := '';
        Exit;
      end;
      Result.Message := '  source:   ' + ASource + sLineBreak +
        '  switch:   ' + LLabel + sLineBreak +
        '  expected: ' + BoolToStr(AExpected, True) + sLineBreak +
        '  actual:   ' + BoolToStr(LActual, True) + sLineBreak;
    end;
end;

function RunStmtCase(APP: TPasPreprocessor; const ARow: TPasCaseRow):
  TPasCheckResult;
var
  LPre: TPasPreprocessed;
  LDiags: TArray<TPasParseDiag>;
  LTree: TPasTree;
begin
  LPre := APP.ProcessText('test.pas', ARow.Source);
  LTree := TPasParser.ParseStatements(LPre, LDiags);
  Result := CheckDump(ARow.Source, ARow.Expected, LTree.Dump(0), LDiags,
    ARow.ExpectDiags);
end;

function RunDeclCase(APP: TPasPreprocessor; const ARow: TPasCaseRow):
  TPasCheckResult;
const
  NL = #13#10;
var
  LPre: TPasPreprocessed;
  LDiags: TArray<TPasParseDiag>;
  LTree: TPasTree;
  LActual: string;
  LIdx, LChild: Integer;
begin
  LPre := APP.ProcessText('test.pas',
    'unit Test;' + NL + 'interface' + NL + ARow.Source + NL +
    'implementation' + NL + 'end.' + NL);
  LTree := TPasParser.ParseFile(LPre, LDiags);
  LActual := '';
  for LIdx := 0 to High(LTree.Nodes) do
    if LTree.Nodes[LIdx].Kind = nkInterfaceSec then
    begin
      LChild := LTree.Nodes[LIdx].FirstChild;
      while LChild <> NIL_NODE do
      begin
        if LActual <> '' then
          LActual := LActual + ' ';
        LActual := LActual + LTree.Dump(LChild);
        LChild := LTree.Nodes[LChild].NextSibling;
      end;
      Break;
    end;
  Result := CheckDump(ARow.Source, ARow.Expected, LActual, LDiags,
    ARow.ExpectDiags);
end;

procedure ReportOne(const AName: string; const AResult: TPasCheckResult;
  var APassed, AFailed: Integer);
begin
  if AResult.Passed then
  begin
    Inc(APassed);
    Exit;
  end;
  Inc(AFailed);
  Writeln('FAIL ', AName);
  Write(AResult.Message);
end;

procedure RunSuite(const ASuiteName: string; APP: TPasPreprocessor;
  const AStmtRows, ADeclRows: array of TPasCaseRow;
  const ACustom: array of TPasCustomCase; out APassed, AFailed: Integer);
var
  LRow: TPasCaseRow;
  LCustom: TPasCustomCase;
begin
  APassed := 0;
  AFailed := 0;
  for LRow in AStmtRows do
    ReportOne(LRow.Section + ' ' + LRow.Name, RunStmtCase(APP, LRow),
      APassed, AFailed);
  for LRow in ADeclRows do
    ReportOne(LRow.Section + ' ' + LRow.Name, RunDeclCase(APP, LRow),
      APassed, AFailed);
  for LCustom in ACustom do
    ReportOne(Trim(LCustom.Section + ' ' + LCustom.Name), LCustom.Run(),
      APassed, AFailed);
  Writeln;
  Writeln(Format('=== %s: %d passed, %d failed ===',
    [ASuiteName, APassed, AFailed]));
end;

end.
