program ParserSmoke;

{
  PasTree parser golden tests. The cases themselves live as DATA in
  PasTree.Tests.Parser (STMT_CASES, DECL_CASES, BuildCustomCases) --
  test-coverage plan step 2+5. This host just wires a preprocessor and runs
  them through PasTree.TestKit, the same shared runner every suite that
  migrates onto this mechanism will use.

  Every STMT/DECL row's tree also goes through the tree checker
  (PasTree.Ast.Check): the invariants I1-I4 and I6, I8 when the row parses
  clean, and I7 - a second parse must build the same arena, and for a DECL
  row the interface-only parse must be a prefix of the full one. A violation
  fails the row, whatever its dump says.
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
      BuildPreprocessorCases(GPP), GPassed, GFailed, TreeVerdict);
    if GFailed > 0 then
      ExitCode := 1;
  finally
    GPP.Free;
    GDefines.Free;
    GSM.Free;
  end;
end.
