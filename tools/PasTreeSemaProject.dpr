program PasTreeSemaProject;

{ Project-level (Phase 2) semantic dump: resolves uses across units and shows
  each unit's model, cross-unit refs and diagnostics.
  Usage: PasTreeSemaProject <file.dpr|dir> [-p:<platform>] }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Diagnostics,
  System.IOUtils,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.Project in '..\source\PasTree.Project.pas',
  PasTree.Sema.Diagnostics in '..\source\PasTree.Sema.Diagnostics.pas',
  PasTree.Sema.Model in '..\source\PasTree.Sema.Model.pas',
  PasTree.Sema.Builtins in '..\source\PasTree.Sema.Builtins.pas',
  PasTree.Sema.Resolver in '..\source\PasTree.Sema.Resolver.pas',
  PasTree.Sema.Dump in '..\source\PasTree.Sema.Dump.pas',
  PasTree.Sema.Project in '..\source\PasTree.Sema.Project.pas';

var
  GPlatform: TPasPlatform;
  GProj: TPasSemaProject;
  GPath: string;
  GIdx: Integer;
  GSingle: Boolean;
  GSW: TStopwatch;
  GMode: string;

begin
  // The driver fans parse+resolve out across cores; without this the default
  // memory manager SLEEPS on allocation contention and eats the whole win.
  System.NeverSleepOnMMThreadContention := True;
  try
    if ParamCount < 1 then
    begin
      Writeln(ErrOutput,
        'Usage: PasTreeSemaProject <file.dpr|dir> [-p:<platform>] [-st]');
      ExitCode := 2;
      Exit;
    end;
    GPath := TPath.GetFullPath(ParamStr(1));
    GPlatform := pfWin32;
    GSingle := False;
    for GIdx := 2 to ParamCount do
      if ParamStr(GIdx).StartsWith('-p:', True) then
        TryParsePlatformName(Copy(ParamStr(GIdx), 4, MaxInt), GPlatform)
      else if SameText(ParamStr(GIdx), '-st') then
        GSingle := True;   // single-threaded baseline (timing comparison)

    if TDirectory.Exists(GPath) then
      GProj := TPasSemaProject.Create(GPlatform, [GPath], [])
    else
      GProj := TPasSemaProject.Create(GPlatform,
        [TPath.GetDirectoryName(GPath)], []);
    try
      GProj.SingleThreaded := GSingle;
      GSW := TStopwatch.StartNew;
      if TDirectory.Exists(GPath) then
        GProj.AnalyzeDirectory(GPath)
      else
        GProj.AnalyzeFile(GPath);
      GSW.Stop;
      for GIdx := 0 to GProj.ModelCount - 1 do
      begin
        Writeln('=== ', GProj.ModelFile(GIdx), ' ===');
        Write(DumpSemaModel(GProj.Model(GIdx)));
      end;
      if GSingle then
        GMode := 'SingleThread'
      else
        GMode := 'MultiThread';
      Writeln(ErrOutput, Format('%d units in %d ms (%s)',
        [GProj.ModelCount, GSW.ElapsedMilliseconds, GMode]));
    finally
      GProj.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
