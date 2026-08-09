program ParserSmoke;

{
  PasTree parser golden tests. The cases themselves live as DATA in
  PasTree.Tests.Parser (STMT_CASES, DECL_CASES, BuildCustomCases) --
  test-coverage plan step 2+5. This host just wires a preprocessor and runs
  them through PasTree.TestKit, the same shared runner every suite that
  migrates onto this mechanism will use.
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.IOUtils,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.TestKit in 'PasTree.TestKit.pas',
  PasTree.Tests.Parser in 'PasTree.Tests.Parser.pas',
  PasTree.Tests.Roundtrip in 'PasTree.Tests.Roundtrip.pas',
  PasTree.Tests.Preprocessor in 'PasTree.Tests.Preprocessor.pas';

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
      BuildPreprocessorCases(GPP), GPassed, GFailed);
    if GFailed > 0 then
      ExitCode := 1;
  finally
    GPP.Free;
    GDefines.Free;
    GSM.Free;
  end;
end.
