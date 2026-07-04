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
  PasTree.Parser in '..\source\PasTree.Parser.pas';

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
  GVis: TPasVisibleToken;
  GIssueFiles: TStringList;
  GElapsedSec: Double;

begin
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
    GPlatform := pfWin32;   // most common target in the wild
    for GIdx := 2 to ParamCount do
      if ParamStr(GIdx).StartsWith('-p:', True) then
        if not TryParsePlatformName(Copy(ParamStr(GIdx), 4, MaxInt),
          GPlatform) then
        begin
          Writeln('Unknown platform: ', Copy(ParamStr(GIdx), 4, MaxInt));
          ExitCode := 2;
          Exit;
        end;
    GTotalFiles := 0;
    GTotalNodes := 0;
    GTotalParseDiags := 0;
    GFilesWithDiags := 0;
    GRoot := ParamStr(1);
    GVerbose := SameText(ParamStr(2), '-v');

    GIssueFiles := TStringList.Create;
    GSM := TPasSourceManager.Create([]);
    GDefines := CreatePlatformDefines(GPlatform);
    GPlatInfo := PlatformInfo(GPlatform);
    GPP := TPasPreprocessor.Create(GSM, GDefines, 37.0,
      GPlatInfo.PointerBytes, GPlatInfo.ExtendedBytes);
    Writeln('Platform: ', GPlatInfo.Name);
    try
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
