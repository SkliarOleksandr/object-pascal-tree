program PasTreePP;

{
  PasTree preprocessor corpus runner: preprocesses every .pas/.dpr/.dpk
  under a directory with Win64 defines, reporting conditional-balance
  problems, include failures, $IF evaluation errors, and residual lexer
  diagnostics (raw diagnostics inside skipped regions are suppressed).

  Usage:
    PasTreePP <root-dir> [-v]
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
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas';

var
  GRoot: string;
  GVerbose: Boolean;
  GFiles: TArray<string>;
  GFile, GExt: string;
  GSM: TPasSourceManager;
  GDefines: TPasDefines;
  GPP: TPasPreprocessor;
  GResult: TPasPreprocessed;
  GWatch: TStopwatch;
  GTotalFiles, GTotalVisible: Int64;
  GFilesWithIssues: Integer;
  GPPDiagTotals: array[TPasPPDiagCode] of Integer;
  GResidualLexDiags, GSuppressedLexDiags: Integer;
  GIdx, GFileIdx: Integer;
  GLine, GCol: Integer;
  GCode: TPasPPDiagCode;
  GIssueFiles: TStringList;
  GFileHasIssue: Boolean;
  GStream: TPasTokenStream;
  GElapsedSec: Double;

begin
  try
    if ParamCount < 1 then
    begin
      Writeln('Usage: PasTreePP <root-dir> [-v]');
      ExitCode := 2;
      Exit;
    end;
    GTotalFiles := 0;
    GTotalVisible := 0;
    GFilesWithIssues := 0;
    GResidualLexDiags := 0;
    GSuppressedLexDiags := 0;
    GRoot := ParamStr(1);
    GVerbose := SameText(ParamStr(2), '-v');
    if not TDirectory.Exists(GRoot) then
    begin
      Writeln('Directory not found: ', GRoot);
      ExitCode := 2;
      Exit;
    end;

    GIssueFiles := TStringList.Create;
    GSM := TPasSourceManager.Create([]);
    GDefines := TPasDefines.Create([
      'MSWINDOWS', 'WIN64', 'CPUX64', 'CPU64BITS', 'CPUINTEL',
      'VER370', 'CONDITIONALEXPRESSIONS', 'UNICODE', 'ASSEMBLER',
      'NATIVECODE', 'UNDERSCOREIMPORTNAME'
    ]);
    GPP := TPasPreprocessor.Create(GSM, GDefines, 37.0);
    try
      GSM.BuildIncludeIndex(GRoot);
      GFiles := TDirectory.GetFiles(GRoot, '*.*', TSearchOption.soAllDirectories);
      GWatch := TStopwatch.StartNew;

      for GFile in GFiles do
      begin
        GExt := LowerCase(TPath.GetExtension(GFile));
        // .inc files are include material, not standalone compilands.
        if (GExt <> '.pas') and (GExt <> '.dpr') and (GExt <> '.dpk') then
          Continue;

        GResult := GPP.Process(GFile);
        Inc(GTotalFiles);
        Inc(GTotalVisible, Length(GResult.Visible));
        GFileHasIssue := False;

        for GIdx := 0 to High(GResult.Diagnostics) do
        begin
          Inc(GPPDiagTotals[GResult.Diagnostics[GIdx].Code]);
          // ppIfNeedsSemantics is informational: a standalone preprocessor
          // cannot see unit constants; the branch was taken as False.
          if GResult.Diagnostics[GIdx].Code <> ppIfNeedsSemantics then
            GFileHasIssue := True;
          if GVerbose then
          begin
            GResult.Files[GResult.Diagnostics[GIdx].FileId].OffsetToLineCol(
              GResult.Diagnostics[GIdx].Start, GLine, GCol);
            Writeln(Format('  PP %s(%d:%d): %s [%s]',
              [GResult.FileNames[GResult.Diagnostics[GIdx].FileId],
               GLine, GCol,
               PP_DIAG_MESSAGES[GResult.Diagnostics[GIdx].Code],
               GResult.Diagnostics[GIdx].Detail]));
          end;
        end;

        // Residual lexer diagnostics: only those OUTSIDE skipped regions.
        for GFileIdx := 0 to High(GResult.Files) do
        begin
          GStream := GResult.Files[GFileIdx];
          for GIdx := 0 to High(GStream.Diagnostics) do
            if GResult.IsSkipped(GFileIdx, GStream.Diagnostics[GIdx].Start)
            then
              Inc(GSuppressedLexDiags)
            else
            begin
              Inc(GResidualLexDiags);
              GFileHasIssue := True;
              if GVerbose then
              begin
                GStream.OffsetToLineCol(GStream.Diagnostics[GIdx].Start,
                  GLine, GCol);
                Writeln(Format('  LEX %s(%d:%d): %s',
                  [GResult.FileNames[GFileIdx], GLine, GCol,
                   DIAG_MESSAGES[GStream.Diagnostics[GIdx].Code]]));
              end;
            end;
        end;

        if GFileHasIssue then
        begin
          Inc(GFilesWithIssues);
          if GIssueFiles.Count < 25 then
            GIssueFiles.Add(GFile);
        end;
      end;

      GWatch.Stop;
      GElapsedSec := GWatch.ElapsedMilliseconds / 1000.0;

      Writeln;
      Writeln('=== PasTreePP corpus report ===');
      Writeln('Files preprocessed: ', GTotalFiles);
      Writeln('Visible tokens:     ', GTotalVisible);
      Writeln(Format('Elapsed:            %.2f s', [GElapsedSec]));
      Writeln('Suppressed lexer diags (skipped regions): ', GSuppressedLexDiags);
      Writeln('Residual lexer diags:                     ', GResidualLexDiags);
      Writeln('Files with issues:  ', GFilesWithIssues);
      for GCode := Low(TPasPPDiagCode) to High(TPasPPDiagCode) do
        if GPPDiagTotals[GCode] > 0 then
          Writeln(Format('  %-40s %d',
            [PP_DIAG_MESSAGES[GCode] + ':', GPPDiagTotals[GCode]]));
      if (GIssueFiles.Count > 0) and not GVerbose then
      begin
        Writeln('First files with issues (re-run with -v for details):');
        for GIdx := 0 to GIssueFiles.Count - 1 do
          Writeln('  ', GIssueFiles[GIdx]);
      end;

      if GFilesWithIssues > 0 then
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
