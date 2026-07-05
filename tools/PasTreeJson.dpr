program PasTreeJson;

{ Dumps the AST of one source file as JSON (stdout).
  Usage: PasTreeJson <file.pas> [-p:<platform>] }

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
  PasTree.Ast.Json in '..\source\PasTree.Ast.Json.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas';

var
  GSM: TPasSourceManager;
  GDefines: TPasDefines;
  GPP: TPasPreprocessor;
  GPre: TPasPreprocessed;
  GTree: TPasTree;
  GDiags: TArray<TPasParseDiag>;
  GPlatform: TPasPlatform;
  GInfo: TPasPlatformInfo;
  GIdx: Integer;

begin
  try
    if ParamCount < 1 then
    begin
      Writeln(ErrOutput, 'Usage: PasTreeJson <file.pas> [-p:<platform>]');
      ExitCode := 2;
      Exit;
    end;
    GPlatform := pfWin32;
    for GIdx := 2 to ParamCount do
      if ParamStr(GIdx).StartsWith('-p:', True) then
        TryParsePlatformName(Copy(ParamStr(GIdx), 4, MaxInt), GPlatform);
    GInfo := PlatformInfo(GPlatform);
    GSM := TPasSourceManager.Create(
      [TPath.GetDirectoryName(TPath.GetFullPath(ParamStr(1)))]);
    GDefines := CreatePlatformDefines(GPlatform);
    GPP := TPasPreprocessor.Create(GSM, GDefines, 37.0,
      GInfo.PointerBytes, GInfo.ExtendedBytes);
    try
      GPre := GPP.Process(TPath.GetFullPath(ParamStr(1)));
      GTree := TPasParser.ParseFile(GPre, GDiags);
      Writeln(AstToJson(GTree));
      for GIdx := 0 to High(GDiags) do
        Writeln(ErrOutput, 'DIAG @', GDiags[GIdx].VisIndex, ': ',
          GDiags[GIdx].Msg);
      if Length(GDiags) > 0 then
        ExitCode := 1;
    finally
      GPP.Free;
      GDefines.Free;
      GSM.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
