program PasTreeTreeCheck;

{
  The tree checker over a corpus (parser fidelity). Every .pas/.dpr/.dpk under
  a directory - or one file - is preprocessed and parsed the way PasTreeParse
  does it and run through PasTree.Ast.Check: I1-I4 and I6 on the tree, I5 and
  I8 when the file parses clean, I7 against a second parse and the
  interface-only parse. Every token a node owns is classified by the
  own-token table (I5) and counted per node kind.

  Usage:
    PasTreeTreeCheck <root-dir|file> [-p:<platform>] [-v] [-hist:<file>]
      [-loss:<file>] [-max:<n>]
    PasTreeTreeCheck -golden [-hist:<file>] [-loss:<file>] [-max:<n>]

  Output: one line per violation, `file(line,col): class: message` - at most
  -max per class (default 200), all of them counted - then the summary:
  files, parse diagnostics (I5 and I8 are not applied to a file that has
  any), violations per class, the recognised shapes with a count and one
  example each, and the owned tokens per class of the own-token table, the
  losses per plan finding.

  -hist writes the histogram - per node kind, every cell of owned tokens, a
  head token (the node's FirstToken) marked, with its count, the table's
  class and one example site, over the files that parse clean; without it
  the histogram follows the summary.

  -loss writes the triage report: the owned tokens no rule covers, the loss
  list (per finding every cell with its count and up to five sites), the
  contract reads and the insignificant tokens.

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

const
  MAX_SITES = 5;
  // A histogram entry per (kind, cell, head or not, variant): variant 0 is
  // the rule without a condition (or none), 1 a conditioned rule of the
  // kind, 2 and 3 the two `*` rules (after end., dropped initializer).
  VARIANTS = 4;

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

  THistEntry = record
    Count: Int64;
    Rule: Integer;           // the own-token rule; -1: none covers it
    Sites: TArray<string>;   // the first MAX_SITES
  end;

  // One printed histogram row.
  THistRow = record
    Kind: TPasNodeKind;
    Cell: Integer;
    Head: Boolean;
    Entry: Integer;          // index into GHist
  end;

var
  GTotals: TTotals;
  GMaxPrint: Integer;
  GVerbose: Boolean;   // -v: print each file's parse diagnostics
  GPrinted: array[TPasCheckClass] of Integer;
  GCellCount: Integer;
  GHist: TArray<THistEntry>;
  GRuleVariant: TArray<Integer>;   // per own-token rule: its variant
  GRuleConflicts: Int64;           // one entry, two rules: a checker bug
  GKindTotals: array[TPasNodeKind] of Int64;
  // MarkContextKeyword's orphans, by word.
  GContextWords: TDictionary<string, Integer>;

function KindText(AKind: TPasNodeKind): string;
begin
  Result := GetEnumName(TypeInfo(TPasNodeKind), Ord(AKind));
  Delete(Result, 1, 2);   // 'nk', as TPasTree.KindName
end;

function HistIndex(AKind: TPasNodeKind; ACell: Integer; AHead: Boolean;
  AVariant: Integer): Integer;
begin
  Result := ((Ord(AKind) * GCellCount + ACell) * 2 + Ord(AHead)) * VARIANTS +
    AVariant;
end;

procedure InitRuleVariants;
var
  LIdx: Integer;
begin
  SetLength(GRuleVariant, OwnRuleCount);
  for LIdx := 0 to OwnRuleCount - 1 do
    case OwnRule(LIdx).Cond of
      wcNone: GRuleVariant[LIdx] := 0;
      wcAfterEnd: GRuleVariant[LIdx] := 2;
      wcOrphanInit: GRuleVariant[LIdx] := 3;
    else
      GRuleVariant[LIdx] := 1;
    end;
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
      procedure(ANode, AVisIndex, ACell, ARule: Integer)
      var
        LKind: TPasNodeKind;
        LVariant: Integer;
      begin
        LKind := LTree.Nodes[ANode].Kind;
        if ARule < 0 then
          LVariant := 0
        else
          LVariant := GRuleVariant[ARule];
        with GHist[HistIndex(LKind, ACell,
          AVisIndex = LTree.Nodes[ANode].FirstToken, LVariant)] do
        begin
          if Count = 0 then
            Rule := ARule
          else if Rule <> ARule then
            Inc(GRuleConflicts);
          Inc(Count);
          if Length(Sites) < MAX_SITES then
            Sites := Sites + [ALabel + VisSiteText(LTree.Source, AVisIndex)];
        end;
        Inc(GKindTotals[LKind]);
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

// Every histogram entry that counted a token, in kind order and, within a
// kind, by count, largest first.
function HistRows: TArray<THistRow>;
var
  LKind: TPasNodeKind;
  LCell, LHead, LVariant, LCount, LFirst: Integer;
  LRow: THistRow;
begin
  Result := nil;
  LCount := 0;
  for LKind := Low(TPasNodeKind) to High(TPasNodeKind) do
  begin
    LFirst := LCount;
    for LCell := 0 to GCellCount - 1 do
      for LHead := 0 to 1 do
        for LVariant := 0 to VARIANTS - 1 do
        begin
          LRow.Entry := HistIndex(LKind, LCell, LHead = 1, LVariant);
          if GHist[LRow.Entry].Count = 0 then
            Continue;
          LRow.Kind := LKind;
          LRow.Cell := LCell;
          LRow.Head := LHead = 1;
          if LCount = Length(Result) then
            SetLength(Result, LCount * 2 + 64);
          Result[LCount] := LRow;
          Inc(LCount);
        end;
    if LCount - LFirst > 1 then
      TArray.Sort<THistRow>(Result, TComparer<THistRow>.Construct(
        function(const A, B: THistRow): Integer
        begin
          if GHist[A.Entry].Count > GHist[B.Entry].Count then
            Result := -1
          else if GHist[A.Entry].Count < GHist[B.Entry].Count then
            Result := 1
          else
            Result := A.Entry - B.Entry;
        end), LFirst, LCount - LFirst);
  end;
  SetLength(Result, LCount);
end;

function CellText(const ARow: THistRow): string;
begin
  Result := OwnTokenCellName(ARow.Cell);
  if ARow.Head then
    Result := Result + ' (head)';
end;

// 'F2' < 'F10': by the number.
function FindingNumber(const AFinding: string): Integer;
begin
  Result := StrToIntDef(Copy(AFinding, 2, MaxInt), MaxInt);
end;

procedure WriteSummary(AElapsedMs: Int64);
var
  LCls: TPasCheckClass;
  LShape: TPasCheckShape;
  LValid, LInvalid, LUnlisted: Int64;
  LWords, LFindings: TArray<string>;
  LWord, LText: string;
  LRow: THistRow;
  LByClass: array[TPasOwnClass] of Int64;
  LOwnCls: TPasOwnClass;
  LByFinding: TDictionary<string, Int64>;
  LRule: Integer;
  LSum: Int64;
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
  Writeln(Format('Parse diagnostics:    %d in %d files (I5 and I8 not ' +
    'applied there)', [GTotals.ParseDiags, GTotals.FilesWithDiags]));
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

  // I5, from the histogram: owned tokens of clean files by class.
  for LOwnCls := Low(TPasOwnClass) to High(TPasOwnClass) do
    LByClass[LOwnCls] := 0;
  LUnlisted := 0;
  LByFinding := TDictionary<string, Int64>.Create;
  try
    for LRow in HistRows do
    begin
      LRule := GHist[LRow.Entry].Rule;
      if LRule < 0 then
      begin
        Inc(LUnlisted, GHist[LRow.Entry].Count);
        Continue;
      end;
      Inc(LByClass[OwnRule(LRule).Cls], GHist[LRow.Entry].Count);
      if OwnRule(LRule).Cls = ocLoss then
      begin
        if not LByFinding.TryGetValue(OwnRule(LRule).Finding, LSum) then
          LSum := 0;
        LByFinding.AddOrSetValue(OwnRule(LRule).Finding,
          LSum + GHist[LRow.Entry].Count);
      end;
    end;
    LText := '';
    for LOwnCls := Low(TPasOwnClass) to High(TPasOwnClass) do
      LText := LText + Format(' %s %d,', [OwnClassName(LOwnCls),
        LByClass[LOwnCls]]);
    Writeln(Format('Own tokens (I5):     %s UNLISTED %d', [LText, LUnlisted]));
    LFindings := LByFinding.Keys.ToArray;
    TArray.Sort<string>(LFindings, TComparer<string>.Construct(
      function(const A, B: string): Integer
      begin
        Result := FindingNumber(A) - FindingNumber(B);
      end));
    LText := '';
    for LWord in LFindings do
      LText := LText + Format(' %s %d', [LWord, LByFinding[LWord]]);
    if LText <> '' then
      Writeln('  losses by finding:', LText);
  finally
    LByFinding.Free;
  end;
  if GRuleConflicts > 0 then
    Writeln(Format('  CHECKER BUG: %d tokens met a histogram entry of ' +
      'another rule', [GRuleConflicts]));
  if OwnRuleTableErrors <> '' then
    Writeln('Own-token table errors:', sLineBreak, OwnRuleTableErrors);
end;

procedure WriteHistogram(const AEmit: TProc<string>);
var
  LRows: TArray<THistRow>;
  LIdx: Integer;
begin
  AEmit('=== I5 own tokens per node kind: the tokens inside a ' +
    'node''s span and inside none of its children''s, files that ' +
    'parse clean ===');
  AEmit('Cells: a reserved word, directive word or punctuation by ' +
    'its text; <ident> <int> <real> <str> <char> ... by class. (head): the ' +
    'node''s FirstToken. Class: the own-token table''s.');
  LRows := HistRows;
  for LIdx := 0 to High(LRows) do
  begin
    if (LIdx = 0) or (LRows[LIdx].Kind <> LRows[LIdx - 1].Kind) then
    begin
      AEmit('');
      AEmit(Format('%s  (%d tokens)', [KindText(LRows[LIdx].Kind),
        GKindTotals[LRows[LIdx].Kind]]));
    end;
    AEmit(Format('  %-18s %10d  %-14s %s', [CellText(LRows[LIdx]),
      GHist[LRows[LIdx].Entry].Count,
      OwnRuleClassText(GHist[LRows[LIdx].Entry].Rule),
      GHist[LRows[LIdx].Entry].Sites[0]]));
  end;
end;

procedure WriteLossReport(const AEmit: TProc<string>);
var
  LRows: TArray<THistRow>;
  LRow: THistRow;
  LFindings: TList<string>;
  LFinding, LText: string;
  LRule: Integer;
  LAny: Boolean;
  LSum: Int64;

  function SitesText(const AEntry: THistEntry): string;
  var
    LSite: string;
  begin
    Result := '';
    for LSite in AEntry.Sites do
    begin
      if Result <> '' then
        Result := Result + '; ';
      Result := Result + LSite;
    end;
  end;

  function RowText(const ARow: THistRow): string;
  begin
    Result := Format('  %-16s %-18s %10d', [KindText(ARow.Kind),
      CellText(ARow), GHist[ARow.Entry].Count]);
  end;

  procedure ClassSection(ACls: TPasOwnClass; const ATitle: string);
  var
    LRowIn: THistRow;
    LAnyIn: Boolean;
  begin
    AEmit('');
    AEmit(ATitle);
    LAnyIn := False;
    for LRowIn in LRows do
      if (GHist[LRowIn.Entry].Rule >= 0) and
         (OwnRule(GHist[LRowIn.Entry].Rule).Cls = ACls) then
      begin
        LAnyIn := True;
        AEmit(RowText(LRowIn) + '  ' + OwnRule(GHist[LRowIn.Entry].Rule).Note);
      end;
    if not LAnyIn then
      AEmit('  (none)');
  end;

begin
  LRows := HistRows;
  AEmit(Format('=== I5 triage over the files that parse clean: %d owned ' +
    'tokens ===', [GTotals.CleanOwned]));

  AEmit('');
  AEmit('--- UNLISTED: owned tokens no rule of the own-token table covers ' +
    '(each one a violation) ---');
  LAny := False;
  for LRow in LRows do
    if GHist[LRow.Entry].Rule < 0 then
    begin
      LAny := True;
      AEmit(RowText(LRow) + '  ' + SitesText(GHist[LRow.Entry]));
    end;
  if not LAny then
    AEmit('  (none)');

  AEmit('');
  AEmit('--- LOSS: facts only a token holds, by plan finding ---');
  LFindings := TList<string>.Create;
  try
    for LRow in LRows do
    begin
      LRule := GHist[LRow.Entry].Rule;
      if (LRule >= 0) and (OwnRule(LRule).Cls = ocLoss) and
         not LFindings.Contains(OwnRule(LRule).Finding) then
        LFindings.Add(OwnRule(LRule).Finding);
    end;
    LFindings.Sort(TComparer<string>.Construct(
      function(const A, B: string): Integer
      begin
        Result := FindingNumber(A) - FindingNumber(B);
      end));
    if LFindings.Count = 0 then
      AEmit('  (none)');
    for LFinding in LFindings do
    begin
      LSum := 0;
      for LRow in LRows do
      begin
        LRule := GHist[LRow.Entry].Rule;
        if (LRule >= 0) and (OwnRule(LRule).Cls = ocLoss) and
           (OwnRule(LRule).Finding = LFinding) then
          Inc(LSum, GHist[LRow.Entry].Count);
      end;
      AEmit('');
      AEmit(Format('%s  %d tokens', [LFinding, LSum]));
      for LRow in LRows do
      begin
        LRule := GHist[LRow.Entry].Rule;
        if (LRule >= 0) and (OwnRule(LRule).Cls = ocLoss) and
           (OwnRule(LRule).Finding = LFinding) then
        begin
          AEmit(RowText(LRow) + '  ' + OwnRule(LRule).Note);
          LText := SitesText(GHist[LRow.Entry]);
          AEmit('      ' + LText);
        end;
      end;
    end;
  finally
    LFindings.Free;
  end;

  ClassSection(ocContract, '--- CONTRACT: read from the token by a ' +
    'documented rule ---');
  ClassSection(ocInsignificant, '--- INSIGNIFICANT: the printer''s ' +
    'normalization list ---');
end;

type
  TLinesWriter = reference to procedure(const AEmit: TProc<string>);

procedure SaveLines(const AFile: string; const AWrite: TLinesWriter);
var
  LLines: TStringList;
begin
  LLines := TStringList.Create;
  try
    AWrite(
      procedure(ALine: string)
      begin
        LLines.Add(ALine);
      end);
    LLines.WriteBOM := False;
    LLines.SaveToFile(AFile, TEncoding.UTF8);
  finally
    LLines.Free;
  end;
end;

var
  GArg, GHistFile, GLossFile: string;
  GGolden: Boolean;
  GPlatform: TPasPlatform;
  GIdx: Integer;
  GWatch: TStopwatch;
  GCls: TPasCheckClass;
  GAny: Boolean;

begin
  try
    if ParamCount < 1 then
    begin
      Writeln('Usage: PasTreeTreeCheck <root-dir|file> [-p:<platform>] [-v] ' +
        '[-hist:<file>] [-loss:<file>] [-max:<n>]');
      Writeln('       PasTreeTreeCheck -golden [-hist:<file>] [-loss:<file>] ' +
        '[-max:<n>]');
      ExitCode := 2;
      Exit;
    end;
    GArg := '';
    GHistFile := '';
    GLossFile := '';
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
      else if ParamStr(GIdx).StartsWith('-loss:', True) then
        GLossFile := Copy(ParamStr(GIdx), 7, MaxInt)
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
    SetLength(GHist, (Ord(High(TPasNodeKind)) + 1) * GCellCount * 2 *
      VARIANTS);
    InitRuleVariants;
    GContextWords := TDictionary<string, Integer>.Create;
    try
      GWatch := TStopwatch.StartNew;
      if GGolden then
        RunGolden
      else
        RunCorpus(GArg, GPlatform);
      GWatch.Stop;
      WriteSummary(GWatch.ElapsedMilliseconds);
      if GLossFile <> '' then
      begin
        SaveLines(GLossFile, WriteLossReport);
        Writeln('Loss report: ', GLossFile);
      end;
      if GHistFile <> '' then
      begin
        SaveLines(GHistFile, WriteHistogram);
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
    GAny := (GTotals.Exceptions > 0) or (OwnRuleTableErrors <> '');
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
