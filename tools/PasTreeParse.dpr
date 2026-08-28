program PasTreeParse;

{
  PasTree full-pipeline corpus runner: lex -> preprocess -> PARSE every
  .pas/.dpr/.dpk under a directory. Reports parse diagnostics; the goal is
  zero across the whole Delphi 13 source tree (see README).

  Usage:
    PasTreeParse <root-dir> [-v]
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Diagnostics,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.Project in '..\source\PasTree.Project.pas';

function FilterPascal(const AAll: TArray<string>): TArray<string>;
var
  LFile, LExt: string;
  LCount: Integer;
begin
  SetLength(Result, Length(AAll));
  LCount := 0;
  for LFile in AAll do
  begin
    LExt := LowerCase(TPath.GetExtension(LFile));
    if (LExt = '.pas') or (LExt = '.dpr') or (LExt = '.dpk') then
    begin
      Result[LCount] := LFile;
      Inc(LCount);
    end;
  end;
  SetLength(Result, LCount);
end;

var
  GRoot: string;
  GVerbose: Boolean;
  GFiles: TArray<string>;
  GFile, GExt: string;
  GSM: TPasSourceManager;
  GDefines: TPasDefines;
  GPP: TPasPreprocessor;
  GPre: TPasPreprocessed;
  GTree: TPasTree;
  GDiags: TArray<TPasParseDiag>;
  GWatch: TStopwatch;
  GTotalFiles, GTotalNodes, GTotalParseDiags: Int64;
  GFilesWithDiags: Integer;
  GIdx, GShown: Integer;
  GLine, GCol: Integer;
  GCtxIdx: Integer;
  GCtx: string;
  GPlatform: TPasPlatform;
  GPlatInfo: TPasPlatformInfo;
  GParallel: Boolean;
  GRootArg, GMainSource: string;
  GProject: TPasProject;
  GResults: TArray<TPasFileResult>;
  GRIdx: Integer;
  GVis: TPasVisibleToken;
  GIssueFiles: TStringList;
  GElapsedSec: Double;

begin
  // -j fans parsing out across cores; without this the default memory
  // manager SLEEPS on allocation contention and eats most of the win.
  System.NeverSleepOnMMThreadContention := True;
  try
    if ParamCount < 1 then
    begin
      Writeln('Usage: PasTreeParse <root-dir> [-v] [-p:<platform>]');
      Writeln('Platforms: Win32 (default), Win64, WinArm64, OSX64,');
      Writeln('  OSXARM64, iOSDevice64, iOSSimARM64, Android, Android64,');
      Writeln('  Linux64');
      ExitCode := 2;
      Exit;
    end;
    GRootArg := ParamStr(1);
    GParallel := False;
    GPlatform := pfWin32;   // most common target in the wild
    // A .dproj as the argument sets the platform and the root directory.
    if SameText(TPath.GetExtension(GRootArg), '.dproj') then
    begin
      if not TryReadDProj(GRootArg, GPlatform, GMainSource) then
        Writeln('Note: no default platform in .dproj, using Win32');
      Writeln('Project: ', GRootArg, '  MainSource: ', GMainSource);
      GRootArg := TPath.GetDirectoryName(TPath.GetFullPath(GRootArg));
    end;
    for GIdx := 2 to ParamCount do
      if SameText(ParamStr(GIdx), '-j') then
        GParallel := True
      else if ParamStr(GIdx).StartsWith('-p:', True) then
        if not TryParsePlatformName(Copy(ParamStr(GIdx), 4, MaxInt),
          GPlatform) then
        begin
          Writeln('Unknown platform: ', Copy(ParamStr(GIdx), 4, MaxInt));
          ExitCode := 2;
          Exit;
        end;
    GVerbose := False;
    for GIdx := 2 to ParamCount do
      if SameText(ParamStr(GIdx), '-v') then
        GVerbose := True;
    GTotalFiles := 0;
    GTotalNodes := 0;
    GTotalParseDiags := 0;
    GFilesWithDiags := 0;
    GRoot := GRootArg;

    GIssueFiles := TStringList.Create;
    GSM := TPasSourceManager.Create([]);
    GDefines := CreatePlatformDefines(GPlatform);
    GPlatInfo := PlatformInfo(GPlatform);
    GPP := TPasPreprocessor.Create(GSM, GDefines, 37.0,
      GPlatInfo.PointerBytes, GPlatInfo.ExtendedBytes);
    Writeln('Platform: ', GPlatInfo.Name);
    try
      if GParallel then
      begin
        // Parallel mode: one worker per core over the pure parse function.
        System.NeverSleepOnMMThreadContention := True;
        GProject := TPasProject.Create(GPlatform, [], []);
        try
          // Keep the serial parts (disk walk, include index) out of the
          // timed region - we are measuring the parse pipeline.
          GProject.SourceManager.BuildIncludeIndex(GRoot);
          GFiles := TDirectory.GetFiles(GRoot, '*.*',
            TSearchOption.soAllDirectories);
          GResults := nil;
          SetLength(GResults, 0);
          GWatch := TStopwatch.StartNew;
          GResults := GProject.ParseFiles(FilterPascal(GFiles));
          GWatch.Stop;
          for GRIdx := 0 to High(GResults) do
          begin
            Inc(GTotalFiles);
            Inc(GTotalNodes, Length(GResults[GRIdx].Tree.Nodes));
            Inc(GTotalParseDiags, Length(GResults[GRIdx].ParseDiags));
            if Length(GResults[GRIdx].ParseDiags) > 0 then
            begin
              Inc(GFilesWithDiags);
              if GIssueFiles.Count < 30 then
                GIssueFiles.Add(Format('%s (%d diags)',
                  [GResults[GRIdx].FileName,
                   Length(GResults[GRIdx].ParseDiags)]));
            end;
          end;
        finally
          GProject.Free;
        end;
      end
      else
      begin
      GSM.BuildIncludeIndex(GRoot);
      GFiles := TDirectory.GetFiles(GRoot, '*.*', TSearchOption.soAllDirectories);
      GWatch := TStopwatch.StartNew;

      for GFile in GFiles do
      begin
        GExt := LowerCase(TPath.GetExtension(GFile));
        if (GExt <> '.pas') and (GExt <> '.dpr') and (GExt <> '.dpk') then
          Continue;

        if GVerbose then
          Writeln(ErrOutput, 'FILE: ', GFile);
        GPre := GPP.Process(GFile);
        GTree := TPasParser.ParseFile(GPre, GDiags);
        Inc(GTotalFiles);
        Inc(GTotalNodes, Length(GTree.Nodes));
        Inc(GTotalParseDiags, Length(GDiags));

        if Length(GDiags) > 0 then
        begin
          Inc(GFilesWithDiags);
          if GIssueFiles.Count < 30 then
            GIssueFiles.Add(Format('%s (%d diags)', [GFile, Length(GDiags)]));
          if GVerbose then
          begin
            GShown := 0;
            for GIdx := 0 to High(GDiags) do
            begin
              GVis := GPre.Visible[GDiags[GIdx].VisIndex];
              GPre.Files[GVis.FileId].OffsetToLineCol(
                GPre.Files[GVis.FileId].Tokens[GVis.TokenIndex].Start,
                GLine, GCol);
              GCtxIdx := GDiags[GIdx].VisIndex - 2;
              if GCtxIdx < 0 then
                GCtxIdx := 0;
              GCtx := '';
              while GCtxIdx <= GDiags[GIdx].VisIndex do
              begin
                GCtx := GCtx + GPre.VisibleText(GCtxIdx) + ' ';
                Inc(GCtxIdx);
              end;
              Writeln(Format('  PARSE %s(%d:%d): %s  [ctx: %s]',
                [GPre.FileNames[GVis.FileId], GLine, GCol, GDiags[GIdx].Msg,
                 GCtx]));
              Inc(GShown);
              if GShown >= 5 then
              begin
                Writeln('  ... (', Length(GDiags) - GShown,
                  ' more in this file)');
                Break;
              end;
            end;
          end;
        end;
      end;

      GWatch.Stop;
      end; // sequential branch
      GElapsedSec := GWatch.ElapsedMilliseconds / 1000.0;

      Writeln;
      Writeln('=== PasTreeParse corpus report ===');
      Writeln('Files parsed:       ', GTotalFiles);
      Writeln('AST nodes:          ', GTotalNodes);
      Writeln(Format('Elapsed:            %.2f s', [GElapsedSec]));
      Writeln('Parse diagnostics:  ', GTotalParseDiags);
      Writeln('Files with diags:   ', GFilesWithDiags);
      if (GIssueFiles.Count > 0) and not GVerbose then
      begin
        Writeln('Worst offenders (re-run with -v for details):');
        for GIdx := 0 to GIssueFiles.Count - 1 do
          Writeln('  ', GIssueFiles[GIdx]);
      end;

      if GFilesWithDiags > 0 then
        ExitCode := 1
      else
        ExitCode := 0;
    finally
      GPP.Free;
      GDefines.Free;
      GSM.Free;
      GIssueFiles.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
