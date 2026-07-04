program PasTreeLex;

{
  PasTree corpus runner: lexes every Pascal source file under a directory,
  verifies full-fidelity coverage (every char in exactly one token), and
  reports diagnostics, unknown tokens, and throughput.

  Usage:
    PasTreeLex <root-dir> [-v]

  Exit code 0 = clean run, 1 = diagnostics/unknown tokens/coverage failures.
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Diagnostics,
  System.Generics.Collections,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas';

function LoadSource(const AFileName: string): string;
var
  LBytes: TBytes;
begin
  try
    Result := TFile.ReadAllText(AFileName);
  except
    on E: EEncodingError do
    begin
      // No/lying BOM with non-default bytes: fall back to raw ANSI decode.
      LBytes := TFile.ReadAllBytes(AFileName);
      Result := TEncoding.ANSI.GetString(LBytes);
    end;
  end;
end;

function CheckCoverage(const AStream: TPasTokenStream): Boolean;
var
  LExpected, LIdx: Integer;
begin
  LExpected := 0;
  for LIdx := 0 to High(AStream.Tokens) do
  begin
    if AStream.Tokens[LIdx].Start <> LExpected then
      Exit(False);
    Inc(LExpected, AStream.Tokens[LIdx].Len);
  end;
  Result := LExpected = Length(AStream.Source);
end;

var
  GRoot: string;
  GVerbose: Boolean;
  GFiles: TArray<string>;
  GFile: string;
  GSource: string;
  GStream: TPasTokenStream;
  GWatch: TStopwatch;
  GTotalFiles, GTotalTokens: Int64;
  GTotalChars: Int64;
  GFilesWithIssues: Integer;
  GCoverageFailures: Integer;
  GUnknownTokens: Int64;
  GDiagTotals: array[TPasDiagCode] of Integer;
  GIdx: Integer;
  GLine, GCol: Integer;
  GIssueFiles: TStringList;
  GFileHasIssue: Boolean;
  GExt: string;
  GCode: TPasDiagCode;
  GElapsedSec: Double;

begin
  try
    if ParamCount < 1 then
    begin
      Writeln('Usage: PasTreeLex <root-dir> [-v]');
      ExitCode := 2;
      Exit;
    end;
    GTotalFiles := 0;
    GTotalTokens := 0;
    GTotalChars := 0;
    GFilesWithIssues := 0;
    GCoverageFailures := 0;
    GUnknownTokens := 0;
    GRoot := ParamStr(1);
    GVerbose := SameText(ParamStr(2), '-v');
    if not TDirectory.Exists(GRoot) then
    begin
      Writeln('Directory not found: ', GRoot);
      ExitCode := 2;
      Exit;
    end;

    GIssueFiles := TStringList.Create;
    try
      GFiles := TDirectory.GetFiles(GRoot, '*.*', TSearchOption.soAllDirectories);
      GWatch := TStopwatch.StartNew;

      for GFile in GFiles do
      begin
        GExt := LowerCase(TPath.GetExtension(GFile));
        if (GExt <> '.pas') and (GExt <> '.dpr') and (GExt <> '.dpk') and
           (GExt <> '.inc') then
          Continue;

        GSource := LoadSource(GFile);
        GStream := TPasLexer.Tokenize(GSource);

        Inc(GTotalFiles);
        Inc(GTotalTokens, Length(GStream.Tokens));
        Inc(GTotalChars, Length(GSource));

        GFileHasIssue := False;

        if not CheckCoverage(GStream) then
        begin
          Inc(GCoverageFailures);
          GFileHasIssue := True;
          Writeln('COVERAGE FAIL: ', GFile);
        end;

        for GIdx := 0 to High(GStream.Tokens) do
          if GStream.Tokens[GIdx].Kind = tkUnknown then
          begin
            Inc(GUnknownTokens);
            GFileHasIssue := True;
            if GVerbose then
            begin
              GStream.OffsetToLineCol(GStream.Tokens[GIdx].Start, GLine, GCol);
              Writeln(Format('  UNKNOWN %s(%d:%d): "%s"',
                [GFile, GLine, GCol, GStream.TokenText(GIdx)]));
            end;
          end;

        for GIdx := 0 to High(GStream.Diagnostics) do
        begin
          Inc(GDiagTotals[GStream.Diagnostics[GIdx].Code]);
          GFileHasIssue := True;
          if GVerbose then
          begin
            GStream.OffsetToLineCol(GStream.Diagnostics[GIdx].Start, GLine, GCol);
            Writeln(Format('  DIAG %s(%d:%d): %s',
              [GFile, GLine, GCol,
               DIAG_MESSAGES[GStream.Diagnostics[GIdx].Code]]));
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
      Writeln('=== PasTreeLex corpus report ===');
      Writeln('Files lexed:        ', GTotalFiles);
      Writeln('Tokens:             ', GTotalTokens);
      Writeln(Format('Source size:        %.1f MB (chars)',
        [GTotalChars / (1024 * 1024)]));
      Writeln(Format('Elapsed:            %.2f s', [GElapsedSec]));
      if GElapsedSec > 0 then
        Writeln(Format('Throughput:         %.1f MB/s',
          [GTotalChars / (1024 * 1024) / GElapsedSec]));
      Writeln('Coverage failures:  ', GCoverageFailures);
      Writeln('Unknown tokens:     ', GUnknownTokens);
      Writeln('Files with issues:  ', GFilesWithIssues);
      for GCode := Low(TPasDiagCode) to High(TPasDiagCode) do
        if GDiagTotals[GCode] > 0 then
          Writeln(Format('  %-32s %d',
            [DIAG_MESSAGES[GCode] + ':', GDiagTotals[GCode]]));
      if (GIssueFiles.Count > 0) and not GVerbose then
      begin
        Writeln('First files with issues (re-run with -v for details):');
        for GIdx := 0 to GIssueFiles.Count - 1 do
          Writeln('  ', GIssueFiles[GIdx]);
      end;

      if (GCoverageFailures > 0) or (GUnknownTokens > 0) or
         (GFilesWithIssues > 0) then
        ExitCode := 1
      else
        ExitCode := 0;
    finally
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
