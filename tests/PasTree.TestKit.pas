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
  PasTree.Types,
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

{ Runs every row/case, printing PASS/FAIL to stdout exactly like the suites
  did before this unit existed, and prints the '=== <name>: N passed, M
  failed ===' footer. This is the whole body of a thin .dpr host now. }
procedure RunSuite(const ASuiteName: string; APP: TPasPreprocessor;
  const AStmtRows, ADeclRows: array of TPasCaseRow;
  const ACustom: array of TPasCustomCase; out APassed, AFailed: Integer);

implementation

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
