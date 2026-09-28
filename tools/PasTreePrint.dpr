program PasTreePrint;

{
  The structural printer over a corpus (parser fidelity, T3 and T3r). Every
  .pas/.dpr/.dpk under a directory - or one file - is preprocessed and parsed
  the way PasTreeTreeCheck does it; each file that parses clean is printed
  from its tree (PasTree.Printer) and judged twice:

  - T3: the print against the visible stream it was parsed from - every
    token regenerated or copied at its place, modulo PRINT_NORMALIZATION.
    A token the tree does not hold is read as a filed LOSS (counted per plan
    finding); a token the print misses or misplaces is a DEFECT (reported).
  - T3r: the print rendered one token per line and on one line, each parsed
    back; both trees must fingerprint as the original.

  Usage:
    PasTreePrint <root-dir|file> [-p:<platform>] [-max:<n>] [-keep:<dir>]
    PasTreePrint -golden [-max:<n>] [-keep:<dir>]
    PasTreePrint <file> -print[:line|:token|:source] [-p:<platform>]

  Output: one line per defect, `file(line,col): T3: message`, and per file
  whose round trip fails `file: T3r: message` - at most -max of each
  (default 200), all counted; then the summary: files, clean files, tokens,
  what the normalization took, items matched (of them copied from a span),
  the losses per finding, defects and T3r failures.

  -keep writes, for every T3r failure, both renders beside each other
  (`<n>.token.pas`, `<n>.line.pas`, `<n>.txt` naming the file).
  -print writes the print of one file to stdout, one line (default), one
  token per line or in the source's own layout (each token where the token
  it matched stands), and nothing else.
  -golden runs the parser's golden STMT/DECL rows, wrapped as ParserSmoke
  wraps them.

  Exit code: 0 no defect and no T3r failure, 1 some, 2 usage or I/O error.
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Diagnostics,
  System.Generics.Collections,
  System.Generics.Defaults,
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
  PasTree.Printer in '..\source\PasTree.Printer.pas',
  PasTree.TestKit in '..\tests\PasTree.TestKit.pas',
  PasTree.Tests.Parser in '..\tests\PasTree.Tests.Parser.pas';

type
  TTotals = record
    Files, Clean, Exceptions: Int64;
    Original, Normalized, Printed, Matched, Spans, Losses, Defects: Int64;
    T3Files, T3rFiles: Int64;
  end;

var
  GTotals: TTotals;
  GLosses: TDictionary<string, Int64>;
  GLossSites: TDictionary<string, string>;
  GMaxPrint: Integer = 200;
  GPrintedDefects, GPrintedT3r: Integer;
  GKeepDir: string;
  GKept: Integer;
  GPP: TPasPreprocessor;

procedure Keep(const ALabel: string; const ATree: TPasTree);
var
  LItems: TPasPrintItems;
begin
  if GKeepDir = '' then
    Exit;
  Inc(GKept);
  ForceDirectories(GKeepDir);
  LItems := PrintNode(ATree, 0);
  TFile.WriteAllText(TPath.Combine(GKeepDir, Format('%d.token.pas', [GKept])),
    RenderItems(ATree, LItems, plTokenPerLine));
  TFile.WriteAllText(TPath.Combine(GKeepDir, Format('%d.line.pas', [GKept])),
    RenderItems(ATree, LItems, plOneLine));
  TFile.WriteAllText(TPath.Combine(GKeepDir, Format('%d.txt', [GKept])),
    ALabel + sLineBreak);
end;

procedure JudgeOne(const ALabel: string; const APre: TPasPreprocessed;
  AStatements: Boolean);
var
  LTree: TPasTree;
  LDiags: TArray<TPasParseDiag>;
  LResult: TPasT3Result;
  LIdx: Integer;
  LMsg, LSite: string;
  LCount: Int64;
begin
  if AStatements then
    LTree := TPasParser.ParseStatements(APre, LDiags)
  else
    LTree := TPasParser.ParseFile(APre, LDiags);
  Inc(GTotals.Files);
  if Length(LDiags) > 0 then
    Exit;
  Inc(GTotals.Clean);

  CompareT3(LTree, 0, LResult, GMaxPrint);
  Inc(GTotals.Original, LResult.Original);
  Inc(GTotals.Normalized, LResult.Normalized);
  Inc(GTotals.Printed, LResult.Printed);
  Inc(GTotals.Matched, LResult.Matched);
  Inc(GTotals.Spans, LResult.Spans);
  Inc(GTotals.Losses, LResult.Losses);
  Inc(GTotals.Defects, LResult.Defects);
  if LResult.Defects > 0 then
    Inc(GTotals.T3Files);
  for LIdx := 0 to High(LResult.Sites) do
  begin
    if LResult.Sites[LIdx].Vis >= 0 then
      LSite := VisSiteText(LTree.Source, LResult.Sites[LIdx].Vis)
    else
      LSite := VisSiteText(LTree.Source, High(LTree.Source.Visible));
    if LResult.Sites[LIdx].Finding <> '' then
    begin
      if not GLossSites.ContainsKey(LResult.Sites[LIdx].Finding) then
        GLossSites.Add(LResult.Sites[LIdx].Finding, ALabel + LSite);
    end
    else if GPrintedDefects < GMaxPrint then
    begin
      Inc(GPrintedDefects);
      Writeln(ALabel, LSite, ': T3: ', LResult.Sites[LIdx].Msg);
    end;
  end;

  for LIdx := 0 to High(LResult.LossCounts) do
  begin
    if not GLosses.TryGetValue(LResult.LossCounts[LIdx].Finding, LCount) then
      LCount := 0;
    GLosses.AddOrSetValue(LResult.LossCounts[LIdx].Finding,
      LCount + LResult.LossCounts[LIdx].Count);
  end;

  if not CheckT3r(LTree,
    function(const AText: string; out ATree: TPasTree; out ADiags,
      ADiagVis: Integer; out AFirstDiag: string): Boolean
    var
      LPre: TPasPreprocessed;
      LBackDiags: TArray<TPasParseDiag>;
    begin
      LPre := GPP.ProcessText('print.pas', AText);
      if AStatements then
        ATree := TPasParser.ParseStatements(LPre, LBackDiags)
      else
        ATree := TPasParser.ParseFile(LPre, LBackDiags);
      ADiags := Length(LBackDiags);
      ADiagVis := -1;
      AFirstDiag := '';
      if ADiags > 0 then
      begin
        ADiagVis := LBackDiags[0].VisIndex;
        AFirstDiag := LBackDiags[0].Msg;
      end;
      Result := True;
    end, LMsg) then
  begin
    Inc(GTotals.T3rFiles);
    if GPrintedT3r < GMaxPrint then
    begin
      Inc(GPrintedT3r);
      Writeln(ALabel, APre.FileNames[0], ': T3r: ', LMsg);
    end;
    Keep(ALabel + APre.FileNames[0], LTree);
  end;
end;

procedure JudgeFile(const AFile: string);
var
  LPre: TPasPreprocessed;
begin
  try
    LPre := GPP.Process(AFile);
    JudgeOne('', LPre, False);
  except
    on E: Exception do
    begin
      Inc(GTotals.Exceptions);
      Writeln(AFile, ': EXCEPTION: ', E.ClassName, ': ', E.Message);
    end;
  end;
end;

procedure RunGolden;
var
  LSM: TPasSourceManager;
  LDefines: TPasDefines;
  LRow: TPasCaseRow;
begin
  // ParserSmoke's own preprocessor, so the trees are the ones it judges.
  LSM := TPasSourceManager.Create([]);
  LDefines := TPasDefines.Create(['MSWINDOWS', 'WIN64']);
  GPP := TPasPreprocessor.Create(LSM, LDefines);
  try
    for LRow in STMT_CASES do
      JudgeOne('[' + LRow.Section + ' ' + LRow.Name + '] ',
        GPP.ProcessText('test.pas', LRow.Source), True);
    for LRow in DECL_CASES do
      JudgeOne('[' + LRow.Section + ' ' + LRow.Name + '] ',
        GPP.ProcessText('test.pas', DeclCaseText(LRow.Source)), False);
  finally
    FreeAndNil(GPP);
    LDefines.Free;
    LSM.Free;
  end;
end;

function CorpusFiles(const ARoot: string; out ADir: string): TArray<string>;
var
  LAll: TArray<string>;
  LFile, LExt: string;
  LCount: Integer;
begin
  if TFile.Exists(ARoot) then
  begin
    ADir := TPath.GetDirectoryName(TPath.GetFullPath(ARoot));
    Result := [TPath.GetFullPath(ARoot)];
    Exit;
  end;
  ADir := ARoot;
  LAll := TDirectory.GetFiles(ARoot, '*.*', TSearchOption.soAllDirectories);
  SetLength(Result, Length(LAll));
  LCount := 0;
  for LFile in LAll do
  begin
    LExt := LowerCase(TPath.GetExtension(LFile));
    if (LExt = '.pas') or (LExt = '.dpr') or (LExt = '.dpk') then
    begin
      Result[LCount] := LFile;
      Inc(LCount);
    end;
  end;
  SetLength(Result, LCount);
  // A stable order, so two runs diff line by line.
  TArray.Sort<string>(Result, TIStringComparer.Ordinal);
end;

procedure WithPreprocessor(const ADir: string; APlatform: TPasPlatform;
  const AProc: TProc);
var
  LSM: TPasSourceManager;
  LDefines: TPasDefines;
  LInfo: TPasPlatformInfo;
begin
  LInfo := PlatformInfo(APlatform);
  LSM := TPasSourceManager.Create([]);
  LDefines := CreatePlatformDefines(APlatform);
  GPP := TPasPreprocessor.Create(LSM, LDefines, 37.0, LInfo.PointerBytes,
    LInfo.ExtendedBytes);
  try
    LSM.BuildIncludeIndex(ADir);
    AProc();
  finally
    FreeAndNil(GPP);
    LDefines.Free;
    LSM.Free;
  end;
end;

procedure RunCorpus(const ARoot: string; APlatform: TPasPlatform);
var
  LDir: string;
  LFiles: TArray<string>;
begin
  LFiles := CorpusFiles(ARoot, LDir);
  Writeln('Platform: ', PlatformInfo(APlatform).Name);
  WithPreprocessor(LDir, APlatform,
    procedure
    var
      LFile: string;
    begin
      for LFile in LFiles do
        JudgeFile(LFile);
    end);
end;

procedure PrintOne(const AFile: string; APlatform: TPasPlatform;
  ALayout: TPasPrintLayout);
var
  LDir: string;
begin
  CorpusFiles(AFile, LDir);
  WithPreprocessor(LDir, APlatform,
    procedure
    var
      LPre: TPasPreprocessed;
      LTree: TPasTree;
      LDiags: TArray<TPasParseDiag>;
      LT3: TPasT3Result;
    begin
      LPre := GPP.Process(TPath.GetFullPath(AFile));
      LTree := TPasParser.ParseFile(LPre, LDiags);
      if ALayout = plSource then
      begin
        CompareT3(LTree, 0, LT3);
        Write(RenderItems(LTree, PrintNode(LTree, 0), ALayout, LT3.ItemAt));
      end
      else
        Write(RenderItems(LTree, PrintNode(LTree, 0), ALayout));
    end);
end;

procedure WriteSummary(AElapsedMs: Int64);
var
  LKeys: TArray<string>;
  LKey: string;
begin
  Writeln;
  Writeln(Format('Files: %d, parsed clean: %d, exceptions: %d',
    [GTotals.Files, GTotals.Clean, GTotals.Exceptions]));
  Writeln(Format('T3: %d original tokens, %d normalized (%s); %d printed ' +
    'items, %d matched (%d copied from a span, %d read as a filed loss), ' +
    '%d defects in %d files',
    [GTotals.Original, GTotals.Normalized, 'N1-N11', GTotals.Printed,
     GTotals.Matched, GTotals.Spans, GTotals.Losses, GTotals.Defects,
     GTotals.T3Files]));
  LKeys := GLosses.Keys.ToArray;
  TArray.Sort<string>(LKeys);
  for LKey in LKeys do
    Writeln(Format('  loss %s: %d (first %s)',
      [LKey, GLosses[LKey], GLossSites[LKey]]));
  Writeln(Format('T3r: %d of %d clean files round-trip, %d fail',
    [GTotals.Clean - GTotals.T3rFiles, GTotals.Clean, GTotals.T3rFiles]));
  Writeln(Format('Elapsed: %.1f s', [AElapsedMs / 1000]));
end;

var
  GArg, GPrintMode: string;
  GGolden, GPrint: Boolean;
  GPlatform: TPasPlatform;
  GIdx: Integer;
  GWatch: TStopwatch;
  GLayout: TPasPrintLayout;
begin
  try
    GGolden := False;
    GPrint := False;
    GPlatform := pfWin64;
    GArg := '';
    GIdx := 1;
    while GIdx <= ParamCount do
    begin
      if SameText(ParamStr(GIdx), '-golden') then
        GGolden := True
      else if ParamStr(GIdx).StartsWith('-p:', True) then
      begin
        if not TryParsePlatformName(Copy(ParamStr(GIdx), 4, MaxInt),
          GPlatform) then
        begin
          Writeln('Unknown platform: ', Copy(ParamStr(GIdx), 4, MaxInt));
          Halt(2);
        end;
      end
      else if ParamStr(GIdx).StartsWith('-max:', True) then
        GMaxPrint := StrToInt(Copy(ParamStr(GIdx), 6, MaxInt))
      else if ParamStr(GIdx).StartsWith('-keep:', True) then
        GKeepDir := Copy(ParamStr(GIdx), 7, MaxInt)
      else if ParamStr(GIdx).StartsWith('-print', True) then
      begin
        GPrint := True;
        GPrintMode := Copy(ParamStr(GIdx), 8, MaxInt);
      end
      else
        GArg := ParamStr(GIdx);
      Inc(GIdx);
    end;
    if GPrint then
    begin
      if SameText(GPrintMode, 'token') then
        GLayout := plTokenPerLine
      else if SameText(GPrintMode, 'source') then
        GLayout := plSource
      else
        GLayout := plOneLine;
      PrintOne(GArg, GPlatform, GLayout);
      Exit;
    end;
    if not GGolden and (GArg = '') then
    begin
      Writeln('Usage: PasTreePrint <root-dir|file> [-p:<platform>] ' +
        '[-max:<n>] [-keep:<dir>] | -golden | <file> -print[:line|:token|:source]');
      Halt(2);
    end;
    GLosses := TDictionary<string, Int64>.Create;
    GLossSites := TDictionary<string, string>.Create;
    try
      GWatch := TStopwatch.StartNew;
      if GGolden then
        RunGolden
      else
        RunCorpus(GArg, GPlatform);
      WriteSummary(GWatch.ElapsedMilliseconds);
    finally
      GLossSites.Free;
      GLosses.Free;
    end;
    if (GTotals.Defects > 0) or (GTotals.T3rFiles > 0) or
       (GTotals.Exceptions > 0) then
      ExitCode := 1;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
