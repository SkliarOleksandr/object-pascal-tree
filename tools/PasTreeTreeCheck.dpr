program PasTreeTreeCheck;

{
  The tree checker over a corpus (parser fidelity, phase 1). Every .pas/.dpr/
  .dpk under a directory - or one file - is preprocessed and parsed the way
  PasTreeParse does it and run through PasTree.Ast.Check: I1-I4 and I6 on the
  tree, I8 when the file parses clean, I7 against a second parse and the
  interface-only parse. Every token's owner goes into one histogram per node
  kind (I5).

  Usage:
    PasTreeTreeCheck <root-dir|file> [-p:<platform>] [-v] [-hist:<file>]
      [-max:<n>]
    PasTreeTreeCheck -golden [-hist:<file>] [-max:<n>]

  Output: one line per violation, `file(line,col): class: message` - at most
  -max per class (default 200), all of them counted - then the summary:
  files, parse diagnostics (I8 is not applied to a file that has any),
  violations per class, the recognised shapes with a count and one example
  each. The histogram - per node kind, every cell of owned tokens with a
  count and one example site, over the files that parse clean - goes to -hist,
  or after the summary.

  -v prints every parse diagnostic, `file(line,col): parse: message`.

  -golden runs the parser's golden STMT/DECL rows (PasTree.Tests.Parser)
  instead of a directory, wrapped exactly as ParserSmoke wraps them.

  Exit code: 0 no violation, 1 violations, 2 usage or I/O error.
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Diagnostics,
  System.Generics.Collections,
  System.Generics.Defaults,
  System.TypInfo,
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
  PasTree.TestKit in '..\tests\PasTree.TestKit.pas',
  PasTree.Tests.Parser in '..\tests\PasTree.Tests.Parser.pas';

type
  TTotals = record
    Files, Units, Nodes, Tokens: Int64;
    // I5 cross-check: in a clean file every visible token has exactly one
    // owner, but the ones after a final `end.`.
    CleanTokens, CleanOwned: Int64;
    ParseDiags, FilesWithDiags, Exceptions: Int64;
    // Violations, split by whether the file parsed clean.
    Valid, Invalid: array[TPasCheckClass] of Int64;
    Shapes: array[TPasCheckShape] of Int64;
    ShapeSites: array[TPasCheckShape] of string;
  end;

var
  GTotals: TTotals;
  GMaxPrint: Integer;
  GVerbose: Boolean;   // -v: print each file's parse diagnostics
  GPrinted: array[TPasCheckClass] of Integer;
  // The histogram: [kind * cell count + cell].
  GCellCount: Integer;
  GCounts: TArray<Int64>;
  GSites: TArray<string>;
  GKindTotals: array[TPasNodeKind] of Int64;
  // MarkContextKeyword's orphans, by word.
  GContextWords: TDictionary<string, Integer>;

function KindText(AKind: TPasNodeKind): string;
begin
  Result := GetEnumName(TypeInfo(TPasNodeKind), Ord(AKind));
  Delete(Result, 1, 2);   // 'nk', as TPasTree.KindName
end;

procedure CheckOne(const ALabel: string; const APre: TPasPreprocessed;
  AStatements: Boolean);
var
  LTree, LAgain, LIntf: TPasTree;
  LDiags, LDiags2: TArray<TPasParseDiag>;
  LReport: TPasCheckReport;
  LOwnProc: TPasOwnTokenProc;
  LValid: Boolean;
  LIdx, LCount: Integer;
  LCls: TPasCheckClass;
  LShape: TPasCheckShape;
  LWord: string;
begin
  if AStatements then
    LTree := TPasParser.ParseStatements(APre, LDiags)
  else
    LTree := TPasParser.ParseFile(APre, LDiags);
  LValid := Length(LDiags) = 0;
  Inc(GTotals.Files);
  Inc(GTotals.Nodes, Length(LTree.Nodes));
  Inc(GTotals.Tokens, Length(LTree.Source.Visible));
  Inc(GTotals.ParseDiags, Length(LDiags));
  if not LValid then
  begin
    Inc(GTotals.FilesWithDiags);
    if GVerbose then
      for LIdx := 0 to High(LDiags) do
        Writeln(ALabel, VisSiteText(APre, LDiags[LIdx].VisIndex),
          ': parse: ', LDiags[LIdx].Msg);
  end
  else
    Inc(GTotals.CleanTokens, Length(LTree.Source.Visible));

  LReport.Init;
  // The histogram is of CLEAN files only: it is the loss list of valid code,
  // and an error-recovery tree owns whatever tokens its recovery skipped.
  if LValid then
    LOwnProc :=
      procedure(ANode, AVisIndex: Integer)
      var
        LSlot: Integer;
      begin
        LSlot := Ord(LTree.Nodes[ANode].Kind) * GCellCount +
          OwnTokenCell(LTree.Source, AVisIndex);
        if GCounts[LSlot] = 0 then
          GSites[LSlot] := ALabel + VisSiteText(LTree.Source, AVisIndex);
        Inc(GCounts[LSlot]);
        Inc(GKindTotals[LTree.Nodes[ANode].Kind]);
        Inc(GTotals.CleanOwned);
      end
  else
    LOwnProc := nil;
  CheckTree(LTree, LValid, LReport, LOwnProc);

  // I7: a second parse, and for a unit the interface-only one.
  if AStatements then
    LAgain := TPasParser.ParseStatements(APre, LDiags2)
  else
    LAgain := TPasParser.ParseFile(APre, LDiags2);
  CompareTrees(LTree, LAgain, LReport);
  if not AStatements then
  begin
    if (Length(LTree.Nodes) > 0) and (LTree.Nodes[0].Kind = nkUnit) then
      Inc(GTotals.Units);
    LIntf := TPasParser.ParseFile(APre, LDiags2, True);
    CheckInterfacePrefix(LIntf, LTree, LReport);
  end;

  for LIdx := 0 to LReport.Kept - 1 do
  begin
    LCls := LReport.Violations[LIdx].Cls;
    if GPrinted[LCls] >= GMaxPrint then
      Continue;
    Inc(GPrinted[LCls]);
    Writeln(ALabel,
      VisSiteText(LTree.Source, LReport.Violations[LIdx].VisIndex), ': ',
      CheckClassName(LCls), ': ', LReport.Violations[LIdx].Msg);
  end;
  for LCls := Low(TPasCheckClass) to High(TPasCheckClass) do
    if LValid then
      Inc(GTotals.Valid[LCls], LReport.Counts[LCls])
    else
      Inc(GTotals.Invalid[LCls], LReport.Counts[LCls]);
  for LShape := Low(TPasCheckShape) to High(TPasCheckShape) do
    if LReport.Shapes[LShape] > 0 then
    begin
      if GTotals.Shapes[LShape] = 0 then
        GTotals.ShapeSites[LShape] := ALabel +
          VisSiteText(LTree.Source, LReport.ShapeSites[LShape]);
      Inc(GTotals.Shapes[LShape], LReport.Shapes[LShape]);
    end;
  for LIdx := 0 to LReport.OrphanCount - 1 do
    if LReport.Orphans[LIdx].Known and
       (LReport.Orphans[LIdx].Shape = csContextKeyword) then
    begin
      LWord := LowerCase(LTree.NodeText(LReport.Orphans[LIdx].Root));
      if not GContextWords.TryGetValue(LWord, LCount) then
        LCount := 0;
      GContextWords.AddOrSetValue(LWord, LCount + 1);
    end;
end;

procedure CheckFile(APP: TPasPreprocessor; const AFile: string);
var
  LPre: TPasPreprocessed;
begin
  try
    LPre := APP.Process(AFile);
    CheckOne('', LPre, False);
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
  LPP: TPasPreprocessor;
  LRow: TPasCaseRow;
begin
  // ParserSmoke's own preprocessor, so the trees are the ones it judges.
  LSM := TPasSourceManager.Create([]);
  LDefines := TPasDefines.Create(['MSWINDOWS', 'WIN64']);
  LPP := TPasPreprocessor.Create(LSM, LDefines);
  try
    for LRow in STMT_CASES do
      CheckOne('[' + LRow.Section + ' ' + LRow.Name + '] ',
        LPP.ProcessText('test.pas', LRow.Source), True);
    for LRow in DECL_CASES do
      CheckOne('[' + LRow.Section + ' ' + LRow.Name + '] ',
        LPP.ProcessText('test.pas', DeclCaseText(LRow.Source)), False);
  finally
    LPP.Free;
    LDefines.Free;
    LSM.Free;
  end;
end;

procedure RunCorpus(const ARoot: string; APlatform: TPasPlatform);
var
  LSM: TPasSourceManager;
  LDefines: TPasDefines;
  LPP: TPasPreprocessor;
  LInfo: TPasPlatformInfo;
  LDir, LExt: string;
  LAll, LFiles: TArray<string>;
  LFile: string;
  LCount: Integer;
begin
  if TFile.Exists(ARoot) then
  begin
    LDir := TPath.GetDirectoryName(TPath.GetFullPath(ARoot));
    LFiles := [TPath.GetFullPath(ARoot)];
  end
  else
  begin
    LDir := ARoot;
    LAll := TDirectory.GetFiles(ARoot, '*.*', TSearchOption.soAllDirectories);
    SetLength(LFiles, Length(LAll));
    LCount := 0;
    for LFile in LAll do
    begin
      LExt := LowerCase(TPath.GetExtension(LFile));
      if (LExt = '.pas') or (LExt = '.dpr') or (LExt = '.dpk') then
      begin
        LFiles[LCount] := LFile;
        Inc(LCount);
      end;
    end;
    SetLength(LFiles, LCount);
    // A stable order, so two runs diff line by line.
    TArray.Sort<string>(LFiles, TIStringComparer.Ordinal);
  end;
  LInfo := PlatformInfo(APlatform);
  Writeln('Platform: ', LInfo.Name);
  LSM := TPasSourceManager.Create([]);
  LDefines := CreatePlatformDefines(APlatform);
  LPP := TPasPreprocessor.Create(LSM, LDefines, 37.0, LInfo.PointerBytes,
    LInfo.ExtendedBytes);
  try
    LSM.BuildIncludeIndex(LDir);
    for LFile in LFiles do
      CheckFile(LPP, LFile);
  finally
    LPP.Free;
    LDefines.Free;
    LSM.Free;
  end;
end;

procedure WriteSummary(AElapsedMs: Int64);
var
  LCls: TPasCheckClass;
  LShape: TPasCheckShape;
  LValid, LInvalid: Int64;
  LWords: TArray<string>;
  LWord, LText: string;
begin
  Writeln;
  Writeln('=== PasTreeTreeCheck report ===');
  Writeln(Format('Files:                %d (%d units)',
    [GTotals.Files, GTotals.Units]));
  Writeln(Format('Nodes / tokens:       %d / %d',
    [GTotals.Nodes, GTotals.Tokens]));
  Writeln(Format('Owned tokens:         %d of %d in clean files ' +
    '(the rest: text after end.)',
    [GTotals.CleanOwned, GTotals.CleanTokens]));
  Writeln(Format('Parse diagnostics:    %d in %d files (I8 not applied there)',
    [GTotals.ParseDiags, GTotals.FilesWithDiags]));
  Writeln(Format('Exceptions:           %d', [GTotals.Exceptions]));
  Writeln(Format('Elapsed:              %.2f s', [AElapsedMs / 1000]));
  LValid := 0;
  LInvalid := 0;
  for LCls := Low(TPasCheckClass) to High(TPasCheckClass) do
  begin
    Inc(LValid, GTotals.Valid[LCls]);
    Inc(LInvalid, GTotals.Invalid[LCls]);
  end;
  Writeln(Format('Violations:           %d in clean files, %d in files with ' +
    'parse diagnostics', [LValid, LInvalid]));
  for LCls := Low(TPasCheckClass) to High(TPasCheckClass) do
    if GTotals.Valid[LCls] + GTotals.Invalid[LCls] > 0 then
      Writeln(Format('  %-12s %8d clean %8d with diagnostics',
        [CheckClassName(LCls), GTotals.Valid[LCls], GTotals.Invalid[LCls]]));
  Writeln('Recognised shapes (counted, not violations):');
  for LShape := Low(TPasCheckShape) to High(TPasCheckShape) do
  begin
    LText := Format('  %-46s %8d', [CheckShapeName(LShape),
      GTotals.Shapes[LShape]]);
    if GTotals.Shapes[LShape] > 0 then
      LText := LText + '  e.g. ' + GTotals.ShapeSites[LShape];
    Writeln(LText);
  end;
  if GContextWords.Count > 0 then
  begin
    LWords := GContextWords.Keys.ToArray;
    TArray.Sort<string>(LWords);
    LText := '';
    for LWord in LWords do
      LText := LText + Format(' %s %d', [LWord, GContextWords[LWord]]);
    Writeln('  context keywords by word:', LText);
  end;
end;

procedure WriteHistogram(const AEmit: TProc<string>);
type
  TCellRow = record
    Cell: Integer;
    Count: Int64;
  end;
var
  LKind: TPasNodeKind;
  LRows: TList<TCellRow>;
  LRow: TCellRow;
  LCell: Integer;
begin
  AEmit('=== I5 own tokens per node kind: the tokens inside a ' +
    'node''s span and inside none of its children''s, files that ' +
    'parse clean ===');
  AEmit('Cells: a reserved word, directive word or punctuation by ' +
    'its text; <ident> <int> <real> <str> <char> ... by class.');
  LRows := TList<TCellRow>.Create(TComparer<TCellRow>.Construct(
    function(const A, B: TCellRow): Integer
    begin
      if A.Count > B.Count then
        Result := -1
      else if A.Count < B.Count then
        Result := 1
      else
        Result := A.Cell - B.Cell;
    end));
  try
    for LKind := Low(TPasNodeKind) to High(TPasNodeKind) do
    begin
      if GKindTotals[LKind] = 0 then
        Continue;
      LRows.Clear;
      for LCell := 0 to GCellCount - 1 do
        if GCounts[Ord(LKind) * GCellCount + LCell] > 0 then
        begin
          LRow.Cell := LCell;
          LRow.Count := GCounts[Ord(LKind) * GCellCount + LCell];
          LRows.Add(LRow);
        end;
      LRows.Sort;
      AEmit('');
      AEmit(Format('%s  (%d tokens)',
        [KindText(LKind), GKindTotals[LKind]]));
      for LRow in LRows do
        AEmit(Format('  %-16s %10d  %s', [OwnTokenCellName(LRow.Cell),
          LRow.Count, GSites[Ord(LKind) * GCellCount + LRow.Cell]]));
    end;
  finally
    LRows.Free;
  end;
end;

var
  GArg, GHistFile: string;
  GGolden: Boolean;
  GPlatform: TPasPlatform;
  GIdx: Integer;
  GWatch: TStopwatch;
  GHist: TStringList;
  GCls: TPasCheckClass;
  GAny: Boolean;

begin
  try
    if ParamCount < 1 then
    begin
      Writeln('Usage: PasTreeTreeCheck <root-dir|file> [-p:<platform>] [-v] ' +
        '[-hist:<file>] [-max:<n>]');
      Writeln('       PasTreeTreeCheck -golden [-hist:<file>] [-max:<n>]');
      ExitCode := 2;
      Exit;
    end;
    GArg := '';
    GHistFile := '';
    GGolden := False;
    GPlatform := pfWin32;
    GMaxPrint := 200;
    GVerbose := False;
    for GIdx := 1 to ParamCount do
      if SameText(ParamStr(GIdx), '-golden') then
        GGolden := True
      else if ParamStr(GIdx).StartsWith('-p:', True) then
      begin
        if not TryParsePlatformName(Copy(ParamStr(GIdx), 4, MaxInt),
           GPlatform) then
        begin
          Writeln('Unknown platform: ', Copy(ParamStr(GIdx), 4, MaxInt));
          ExitCode := 2;
          Exit;
        end;
      end
      else if ParamStr(GIdx).StartsWith('-hist:', True) then
        GHistFile := Copy(ParamStr(GIdx), 7, MaxInt)
      else if SameText(ParamStr(GIdx), '-v') then
        GVerbose := True
      else if ParamStr(GIdx).StartsWith('-max:', True) then
        GMaxPrint := StrToInt(Copy(ParamStr(GIdx), 6, MaxInt))
      else
        GArg := ParamStr(GIdx);
    if not GGolden and (GArg = '') then
    begin
      Writeln('No directory or file given');
      ExitCode := 2;
      Exit;
    end;

    GCellCount := OwnTokenCellCount;
    SetLength(GCounts, (Ord(High(TPasNodeKind)) + 1) * GCellCount);
    SetLength(GSites, Length(GCounts));
    GContextWords := TDictionary<string, Integer>.Create;
    try
      GWatch := TStopwatch.StartNew;
      if GGolden then
        RunGolden
      else
        RunCorpus(GArg, GPlatform);
      GWatch.Stop;
      WriteSummary(GWatch.ElapsedMilliseconds);
      if GHistFile <> '' then
      begin
        GHist := TStringList.Create;
        try
          WriteHistogram(
            procedure(ALine: string)
            begin
              GHist.Add(ALine);
            end);
          GHist.WriteBOM := False;
          GHist.SaveToFile(GHistFile, TEncoding.UTF8);
        finally
          GHist.Free;
        end;
        Writeln('Histogram: ', GHistFile);
      end
      else
      begin
        Writeln;
        WriteHistogram(
          procedure(ALine: string)
          begin
            Writeln(ALine);
          end);
      end;
    finally
      GContextWords.Free;
    end;
    GAny := GTotals.Exceptions > 0;
    for GCls := Low(TPasCheckClass) to High(TPasCheckClass) do
      if GTotals.Valid[GCls] + GTotals.Invalid[GCls] > 0 then
        GAny := True;
    if GAny then
      ExitCode := 1;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
