program PasTreeSema;

{ Dumps the Phase-1 semantic model of one source file (stdout).
  Usage: PasTreeSema <file.pas> [-p:<platform>] }

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
  PasTree.Sema.Diagnostics in '..\source\PasTree.Sema.Diagnostics.pas',
  PasTree.Sema.Model in '..\source\PasTree.Sema.Model.pas',
  PasTree.Sema.Builtins in '..\source\PasTree.Sema.Builtins.pas',
  PasTree.Sema.Resolver in '..\source\PasTree.Sema.Resolver.pas',
  PasTree.Sema.Dump in '..\source\PasTree.Sema.Dump.pas';

var
  GSM: TPasSourceManager;
  GDefines: TPasDefines;
  GPP: TPasPreprocessor;
  GPre: TPasPreprocessed;
  GTree: TPasTree;
  GDiags: TArray<TPasParseDiag>;
  GPlatform: TPasPlatform;
  GInfo: TPasPlatformInfo;
  GModel: TPasSemaModel;
  GIdx: Integer;

begin
  try
    if ParamCount < 1 then
    begin
      Writeln(ErrOutput, 'Usage: PasTreeSema <file.pas> [-p:<platform>]');
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
      // `-p:` reached the preprocessor's defines but not the analyzer, so the
      // model was seeded for Win32 whatever the flag said - which hides every
      // platform-conditional sema rule (the 64-bit intrinsics, `set of
      // NativeInt`). PasTreeSemaProject always passed it.
      GModel := TPasSemaResolver.Analyze(GTree, False, GPlatform);
      try
        Write(DumpSemaModel(GModel));
      finally
        GModel.Free;
      end;
      for GIdx := 0 to High(GDiags) do
        Writeln(ErrOutput, 'PARSE @', GDiags[GIdx].VisIndex, ': ',
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
