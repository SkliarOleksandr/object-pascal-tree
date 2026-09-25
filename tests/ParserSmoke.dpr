program ParserSmoke;

{
  PasTree parser golden tests. The cases themselves live as DATA in
  PasTree.Tests.Parser (STMT_CASES, DECL_CASES, BuildCustomCases) --
  test-coverage plan step 2+5. This host just wires a preprocessor and runs
  them through PasTree.TestKit, the same shared runner every suite that
  migrates onto this mechanism will use.

  Every STMT/DECL row's tree also goes through the tree checker
  (PasTree.Ast.Check): the invariants I1-I4 and I6, I5 (the own-token table)
  and I8 when the row parses clean, and I7 - a second parse must build the
  same arena, and for a DECL row the interface-only parse must be a prefix of
  the full one. A violation fails the row, whatever its dump says.
  BuildOwnTokenCases holds the table itself to account: it parses, and I5
  fails on trees built by hand to break it.
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.IOUtils,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Dcu in '..\source\PasTree.Dcu.pas',
  PasTree.Dcu.Source in '..\source\PasTree.Dcu.Source.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Ast.Check in '..\source\PasTree.Ast.Check.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.TestKit in 'PasTree.TestKit.pas',
  PasTree.Tests.Parser in 'PasTree.Tests.Parser.pas',
  PasTree.Tests.Roundtrip in 'PasTree.Tests.Roundtrip.pas',
  PasTree.Tests.Preprocessor in 'PasTree.Tests.Preprocessor.pas';

function TreeVerdict(const APre: TPasPreprocessed; const ATree: TPasTree;
  AStatements, AValid: Boolean): string;
var
  LReport: TPasCheckReport;
  LDiags: TArray<TPasParseDiag>;
  LLines: TArray<string>;
  LIdx: Integer;
begin
  LReport.Init;
  CheckTree(ATree, AValid, LReport);
  if AStatements then
    CompareTrees(ATree, TPasParser.ParseStatements(APre, LDiags), LReport)
  else
  begin
    CompareTrees(ATree, TPasParser.ParseFile(APre, LDiags), LReport);
    CheckInterfacePrefix(TPasParser.ParseFile(APre, LDiags, True), ATree,
      LReport);
  end;
  Result := '';
  LLines := CheckReportText(ATree, LReport).Split([sLineBreak],
    TStringSplitOptions.ExcludeEmpty);
  for LIdx := 0 to High(LLines) do
    Result := Result + '    ' + LLines[LIdx] + sLineBreak;
end;

type
  TNodeSpec = record
    Kind: TPasNodeKind;
    First, Last, Parent: Integer;
  end;

function N(AKind: TPasNodeKind; AFirst, ALast, AParent: Integer): TNodeSpec;
begin
  Result.Kind := AKind;
  Result.First := AFirst;
  Result.Last := ALast;
  Result.Parent := AParent;
end;

// A tree over ASource's visible tokens: each node in order, Parent an index
// into the nodes before it.
function HandTree(APP: TPasPreprocessor; const ASource: string;
  const ANodes: array of TNodeSpec): TPasTree;
var
  LB: TPasTreeBuilder;
  LSpec: TNodeSpec;
begin
  LB.Init;
  for LSpec in ANodes do
    LB.SetLast(LB.AddNode(LSpec.Kind, LSpec.Parent, LSpec.First), LSpec.Last);
  Result := LB.Build(APP.ProcessText('test.pas', ASource));
end;

// Passes when checking ATree as valid code reports exactly AOwn I5.own
// violations, AUnlisted of them for tokens no rule covers, and nothing else.
function JudgeOwn(const ATree: TPasTree; AOwn, AUnlisted: Integer;
  const AWhat: string): TPasCheckResult;
var
  LReport: TPasCheckReport;
begin
  LReport.Init;
  CheckTree(ATree, True, LReport);
  Result.Passed := (LReport.Counts[ccOwn] = AOwn) and
    (LReport.OwnUnlisted = AUnlisted) and (LReport.Total = AOwn);
  Result.Message := '';
  if not Result.Passed then
    Result.Message := Format('  %s: expected %d I5.own (%d unlisted) and ' +
      'nothing else, got %d I5.own (%d unlisted) of %d:', [AWhat, AOwn,
      AUnlisted, LReport.Counts[ccOwn], LReport.OwnUnlisted,
      LReport.Total]) + sLineBreak + CheckReportText(ATree, LReport);
end;

function OwnCase(const AName: string;
  const ARun: TFunc<TPasCheckResult>): TPasCustomCase;
begin
  Result.Section := 'I5';
  Result.Name := AName;
  Result.Run := ARun;
end;

// Passes when ADecl, parsed as a unit's interface, is valid, checks clean,
// and the own-token rules of AFinding classify exactly ATally tokens - the
// first of them the token ASite, when given.
function LossCase(APP: TPasPreprocessor; const ADecl, AFinding: string;
  ATally: Integer; const ASite: string): TPasCheckResult;
var
  LPre: TPasPreprocessed;
  LDiags: TArray<TPasParseDiag>;
  LTree: TPasTree;
  LReport: TPasCheckReport;
  LRule, LTally, LFirst: Integer;
begin
  LPre := APP.ProcessText('test.pas', DeclCaseText(ADecl));
  LTree := TPasParser.ParseFile(LPre, LDiags);
  LReport.Init;
  CheckTree(LTree, Length(LDiags) = 0, LReport);
  LTally := 0;
  LFirst := MaxInt;
  for LRule := 0 to OwnRuleCount - 1 do
    if (OwnRule(LRule).Finding = AFinding) and
       (LReport.OwnCounts[LRule] > 0) then
    begin
      Inc(LTally, LReport.OwnCounts[LRule]);
      if LReport.OwnSites[LRule] < LFirst then
        LFirst := LReport.OwnSites[LRule];
    end;
  Result.Passed := (Length(LDiags) = 0) and (LReport.Total = 0) and
    (LTally = ATally) and ((ASite = '') or
     ((LFirst <> MaxInt) and SameText(LPre.VisibleText(LFirst), ASite)));
  Result.Message := '';
  if not Result.Passed then
    Result.Message := Format('  %s: %d diagnostics, %d violations, %s tally ' +
      '%d (%d expected, first on %s)', [ADecl, Length(LDiags), LReport.Total,
      AFinding, LTally, ATally, ASite]) + sLineBreak +
      CheckReportText(LTree, LReport);
end;

{ I5 must be able to fail, and the table must hold: the table parses; trees
  built by hand, over real tokens, break it on purpose - a token no rule
  covers, a once-token owned twice - and the checker says so; a loss is
  counted, not reported. }
function BuildOwnTokenCases(APP: TPasPreprocessor): TPasCustomCases;
begin
  Result := [
    OwnCase('the own-token table parses',
      function: TPasCheckResult
      begin
        Result.Passed := OwnRuleTableErrors = '';
        Result.Message := OwnRuleTableErrors;
      end),
    // `if C then X` read with a hand-built tree: tokens if C then X <eof>.
    OwnCase('a hand tree the table accepts',
      function: TPasCheckResult
      begin
        Result := JudgeOwn(HandTree(APP, 'if C then X', [N(nkBlock, 0, 4, -1),
          N(nkIfStmt, 0, 3, 0), N(nkIdent, 1, 1, 1), N(nkExprStmt, 3, 3, 1),
          N(nkIdent, 3, 3, 3)]), 0, 0, 'IfStmt over if C then X');
      end),
    // The same tokens under a WhileStmt: `if` and `then` have no rule there
    // (2 unlisted), and `while` and `do`, once each, are missing (2 more).
    OwnCase('a token no rule covers is a violation',
      function: TPasCheckResult
      begin
        Result := JudgeOwn(HandTree(APP, 'if C then X', [N(nkBlock, 0, 4, -1),
          N(nkWhileStmt, 0, 3, 0), N(nkIdent, 1, 1, 1),
          N(nkExprStmt, 3, 3, 1), N(nkIdent, 3, 3, 3)]), 4, 2,
          'WhileStmt over if C then X');
      end),
    // `if C then then X`: one IfStmt owning both `then`.
    OwnCase('a once-token owned twice is a violation',
      function: TPasCheckResult
      begin
        Result := JudgeOwn(HandTree(APP, 'if C then then X', [
          N(nkBlock, 0, 5, -1), N(nkIfStmt, 0, 4, 0), N(nkIdent, 1, 1, 1),
          N(nkExprStmt, 4, 4, 1), N(nkIdent, 4, 4, 3)]), 1, 0,
          'IfStmt owning two then');
      end),
    // The parser's own tree: `stdcall` after the `;` is F2, counted.
    OwnCase('a loss is counted, not a violation',
      function: TPasCheckResult
      begin
        Result := LossCase(APP, 'type TFn = procedure; stdcall;', 'F2', 1,
          'stdcall');
      end),
    // F19 counts the separators of a declaration whose children cannot
    // tell where its names end - `P, T: C` reads as `P: T = C` too - and
    // not those of one they can: an Integer literal is no type.
    OwnCase('F19 counts only the ambiguous declarations',
      function: TPasCheckResult
      begin
        Result := LossCase(APP, 'var P, T: C; Q: Integer = 5;', 'F19', 2,
          ',');
      end)
  ];
end;

var
  GSM: TPasSourceManager;
  GDefines: TPasDefines;
  GPP: TPasPreprocessor;
  GPassed, GFailed: Integer;
begin
  GSM := TPasSourceManager.Create([]);
  GDefines := TPasDefines.Create(['MSWINDOWS', 'WIN64']);
  GPP := TPasPreprocessor.Create(GSM, GDefines);
  try
    RunSuite('ParserSmoke', GPP, STMT_CASES, DECL_CASES,
      BuildCustomCases(GPP, GSM) + BuildRoundtripCases +
      BuildPreprocessorCases(GPP) + BuildOwnTokenCases(GPP), GPassed,
      GFailed, TreeVerdict);
    if GFailed > 0 then
      ExitCode := 1;
  finally
    GPP.Free;
    GDefines.Free;
    GSM.Free;
  end;
end.
