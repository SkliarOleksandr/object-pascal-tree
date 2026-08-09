unit PasTreeDemo.Coverage;

{
  Test-coverage plan step 5, the demo part: a LIVE view of how many of the
  spec's numbered sections have a test, read straight from the suites'
  own data/source -- no separate registry, and no more hand-maintained
  audit file (local/TEST-AUDIT.md was exactly this, done once by hand on
  2026-08-08; this is the same cross-reference, done every time the button
  is pressed, so it can never go stale the way a written-once file does).

  Three tiers, weakest to strongest:
  1. Always available, no configuration: PasTree.Tests.Parser's STMT_CASES/
     DECL_CASES (structured -- Source/Expected exist, just not shown here
     yet) plus its BuildCustomCases and PasTree.Tests.Roundtrip's
     BuildRoundtripCases (Section/Name only). This alone covers every
     ParserSmoke case, compiled straight into this unit.
  2. If a `tests\` checkout is found: every OTHER suite's spec-numbered
     `Ok('N.N.N: ...', ...)` case names, found by scanning source text --
     cheap, and the only way to see SemaSmoke/SemaProjectSmoke's
     newly-added cases (test-coverage plan step 3 batch 2) without
     migrating those suites onto PasTree.TestKit first.
  3. If an object-pascal-spec checkout is found: the FULL 173-ish section
     universe, with titles, grouped by chapter, gaps shown as gaps. Without
     it, the report can only show what IS covered, not what is missing --
     degrade to that rather than fail; a missing sibling checkout is
     expected on a fresh clone, not a bug.

  Both paths are guessed relative to the running exe and settings-
  overridable (PasTreeDemo.Settings' SpecDir/TestsDir keys) rather than
  hardcoded, since object-pascal-spec is a SEPARATE repo this one only ever
  references by section NUMBER, never by absolute path, until now.
}

interface

uses
  System.SysUtils, System.IOUtils, System.RegularExpressions,
  System.Generics.Collections,
  PasTree.SourceManager, PasTree.Preprocessor,
  PasTree.TestKit, PasTree.Tests.Parser, PasTree.Tests.Roundtrip;

type
  TPasSpecSection = record
    Chapter: string;   // source file, e.g. '05-statements.md'
    Section: string;   // '5.1.1' / 'B.6.3'
    Title: string;
  end;

const
  // ch.01-20 + appendix B, in the order local/TEST-AUDIT.md counted them.
  // README.md and A-version-history.md are deliberately excluded: the
  // README repeats one section number as a worked EXAMPLE, which would
  // double-count it against the real definition in 05-statements.md.
  SPEC_CHAPTER_FILES: array[0..20] of string = (
    '01-program-structure.md', '02-fundamental-types.md',
    '03-variables-constants.md', '04-expressions-operators.md',
    '05-statements.md', '06-routines.md', '07-strings.md', '08-arrays.md',
    '09-records.md', '10-pointers-files.md', '11-classes.md',
    '12-inheritance-polymorphism.md', '13-properties-events.md',
    '14-interfaces.md', '15-class-mechanics-helpers.md', '16-generics.md',
    '17-anonymous-methods.md', '18-exceptions.md', '19-rtti-attributes.md',
    '20-memory-management.md', 'B-lexical-grammar.md'
  );

{ Sibling-checkout guesses for object-pascal-spec, relative to the running
  exe (works from demo\out\<config>\PasTreeDemo.exe and a couple of other
  common build-output depths). '' if none of them look like a real checkout
  (missing 01-program-structure.md). }
function GuessSpecDir: string;

{ Same idea for this repo's own tests\ directory (needed only for the
  prose-scan tier -- the structured tier needs no path at all, since
  PasTree.Tests.Parser/.Roundtrip are compiled straight into this exe). }
function GuessTestsDir: string;

{ Scans ASpecDir's chapter files for `### N.N.N Title` headings. Empty if
  ASpecDir doesn't look like a real checkout. }
function LoadSpecSections(const ASpecDir: string): TArray<TPasSpecSection>;

{ The whole report as plain text, for a SynEdit tab. Degrades tier by tier
  as described above -- always returns SOMETHING, never raises for a
  missing path. }
function BuildCoverageReport(const ASpecDir, ATestsDir: string): string;

implementation

uses
  System.Classes, System.StrUtils, System.Math, PasTree.Types,
  PasTree.Platforms;

function GuessSpecDir: string;
var
  LExeDir, LCand: string;
begin
  LExeDir := TPath.GetDirectoryName(ParamStr(0));
  for LCand in [
    TPath.Combine(LExeDir, '..\..\..\..\object-pascal-spec'),  // out\<cfg>\<plat>\...
    TPath.Combine(LExeDir, '..\..\..\object-pascal-spec'),
    TPath.Combine(LExeDir, '..\..\object-pascal-spec')] do
    if TFile.Exists(TPath.Combine(TPath.GetFullPath(LCand),
         '01-program-structure.md')) then
      Exit(TPath.GetFullPath(LCand));
  Result := '';
end;

function GuessTestsDir: string;
var
  LExeDir, LCand: string;
begin
  LExeDir := TPath.GetDirectoryName(ParamStr(0));
  for LCand in [
    TPath.Combine(LExeDir, '..\..\..\..\tests'),
    TPath.Combine(LExeDir, '..\..\..\tests'),
    TPath.Combine(LExeDir, '..\..\tests')] do
    if TFile.Exists(TPath.Combine(TPath.GetFullPath(LCand),
         'ParserSmoke.dpr')) then
      Exit(TPath.GetFullPath(LCand));
  Result := '';
end;

function LoadSpecSections(const ASpecDir: string): TArray<TPasSpecSection>;
var
  LFile, LPath, LText: string;
  LMatch: TMatch;
  LRows: TList<TPasSpecSection>;
  LRow: TPasSpecSection;
  LPendingNum, LPendingTitle: string;
  LPendingHasChild: Boolean;

  // A `## N.N` heading with no `### N.N.N` CHILD before the next `##` is
  // itself the leaf a test can target (chapter 4's plain arithmetic/
  // bitwise/pointer operator sections, never subdivided further, are
  // exactly this shape) -- counting only `###` headings (the original
  // hand audit's method) silently drops every one of those as "not a real
  // section", which is what first surfaced this: existing case Section
  // values like '4.2'/'6.10'/'B.1' turned up as ORPHANS with the ###-only
  // version of this function.
  procedure FlushPending;
  begin
    if (LPendingNum <> '') and not LPendingHasChild then
    begin
      LRow.Chapter := LFile;
      LRow.Section := LPendingNum;
      LRow.Title := LPendingTitle;
      LRows.Add(LRow);
    end;
  end;

begin
  LRows := TList<TPasSpecSection>.Create;
  try
    for LFile in SPEC_CHAPTER_FILES do
    begin
      LPath := TPath.Combine(ASpecDir, LFile);
      if not TFile.Exists(LPath) then
        Continue;
      // Explicit UTF8: these files carry no BOM, and ReadAllText's
      // no-BOM-found default is the system ANSI codepage, which mangled
      // every em-dash and non-ASCII quote in a section title.
      LText := TFile.ReadAllText(LPath, TEncoding.UTF8);
      LPendingNum := '';
      LPendingTitle := '';
      LPendingHasChild := False;
      LMatch := TRegEx.Match(LText,
        '^(##|###) ([0-9A-Z]+(?:\.[0-9]+)+) (.+)$', [roMultiLine]);
      while LMatch.Success do
      begin
        if LMatch.Groups[1].Value = '##' then
        begin
          FlushPending;
          LPendingNum := LMatch.Groups[2].Value;
          LPendingTitle := LMatch.Groups[3].Value.TrimRight([#13, #10]);
          LPendingHasChild := False;
        end
        else
        begin
          LRow.Chapter := LFile;
          LRow.Section := LMatch.Groups[2].Value;
          LRow.Title := LMatch.Groups[3].Value.TrimRight([#13, #10]);
          LRows.Add(LRow);
          LPendingHasChild := True;
        end;
        LMatch := LMatch.NextMatch;
      end;
      FlushPending;
    end;
    Result := LRows.ToArray;
  finally
    LRows.Free;
  end;
end;

// Every case (Section, DisplayName) this exe carries STRUCTURED data for --
// no file path needed, all three sources are Delphi consts/functions
// compiled into this unit.
procedure CollectStructuredCases(ACases: TDictionary<string, TList<string>>);
  procedure Add(const ASection, AName: string);
  var
    LKey: string;
    LList: TList<string>;
  begin
    if ASection = '' then
      Exit;
    LKey := UpperCase(ASection);
    if not ACases.TryGetValue(LKey, LList) then
    begin
      LList := TList<string>.Create;
      ACases.Add(LKey, LList);
    end;
    LList.Add(AName);
  end;
var
  LIdx: Integer;
  LGSM: TPasSourceManager;
  LGDefines: TPasDefines;
  LGPP: TPasPreprocessor;
  LCustom: TPasCustomCase;
begin
  for LIdx := 0 to High(STMT_CASES) do
    Add(STMT_CASES[LIdx].Section, STMT_CASES[LIdx].Name + ' [ParserSmoke]');
  for LIdx := 0 to High(DECL_CASES) do
    Add(DECL_CASES[LIdx].Section, DECL_CASES[LIdx].Name + ' [ParserSmoke]');
  // BuildCustomCases only needs a preprocessor to construct its closures --
  // it is never RUN here, just enumerated for Section/Name.
  LGSM := TPasSourceManager.Create([]);
  LGDefines := TPasDefines.Create(['MSWINDOWS', 'WIN64']);
  LGPP := TPasPreprocessor.Create(LGSM, LGDefines);
  try
    for LCustom in BuildCustomCases(LGPP, LGSM) do
      Add(LCustom.Section, Trim(LCustom.Name) + ' [ParserSmoke]');
  finally
    LGPP.Free;
    LGDefines.Free;
    LGSM.Free;
  end;
  for LCustom in BuildRoundtripCases do
    Add(LCustom.Section, Trim(LCustom.Name) + ' [ParserSmoke roundtrip]');
end;

// Best-effort breadth beyond ParserSmoke: every OTHER suite's spec-numbered
// `Ok('N.N.N: name', ...)` or `Ok('N.N.N name', ...)` case, found by
// scanning SOURCE TEXT rather than requiring every suite to migrate onto
// PasTree.TestKit first (test-coverage plan: "migrate opportunistically,
// not as a big-bang pass"). Prose-only: no Source/Expected to show, just
// that the name exists and which file to open for it.
procedure CollectProseCases(const ATestsDir: string;
  ACases: TDictionary<string, TList<string>>);
  procedure Add(const ASection, AName: string);
  var
    LKey: string;
    LList: TList<string>;
  begin
    if ASection = '' then
      Exit;
    LKey := UpperCase(ASection);
    if not ACases.TryGetValue(LKey, LList) then
    begin
      LList := TList<string>.Create;
      ACases.Add(LKey, LList);
    end;
    LList.Add(AName);
  end;
const
  // Sections already counted structurally (CollectStructuredCases) --
  // scanning these too would double-count every one of their cases.
  SKIP_FILES: array[0..2] of string = (
    'parsersmoke.dpr', 'pastree.tests.parser.pas',
    'pastree.tests.roundtrip.pas');
var
  LFile, LName, LText: string;
  LMatch: TMatch;
  LSuite: string;
begin
  if (ATestsDir = '') or not TDirectory.Exists(ATestsDir) then
    Exit;
  for LFile in TDirectory.GetFiles(ATestsDir, '*.dpr') do
  begin
    LName := TPath.GetFileName(LFile);
    if MatchText(LName, SKIP_FILES) then
      Continue;
    LSuite := TPath.GetFileNameWithoutExtension(LFile);
    LText := TFile.ReadAllText(LFile, TEncoding.UTF8);
    // A section number, optional ': ', then the rest of the quoted string.
    // Delphi string literals may contain '' as an escaped quote; the
    // pattern stops at the first UNESCAPED one, which is what Ok(...)'s
    // own case names always are (none embed a literal quote).
    LMatch := TRegEx.Match(LText,
      '''([0-9]+(?:\.[0-9]+){2}|[A-Z](?:\.[0-9]+){2}):?\s*([^'']*)''');
    while LMatch.Success do
    begin
      Add(LMatch.Groups[1].Value,
        Trim(LMatch.Groups[2].Value) + ' [' + LSuite + ']');
      LMatch := LMatch.NextMatch;
    end;
  end;
end;

function BuildCoverageReport(const ASpecDir, ATestsDir: string): string;
var
  LCases: TObjectDictionary<string, TList<string>>;
  LSpec: TArray<TPasSpecSection>;
  LSB: TStringBuilder;
  LTotalCases, LCoveredSections: Integer;
  LChapter: string;
  LSection: TPasSpecSection;
  LNames: TList<string>;
  LName: string;
  LSeenKeys: TDictionary<string, Boolean>;
  LKey: string;
begin
  LCases := TObjectDictionary<string, TList<string>>.Create([doOwnsValues]);
  LSeenKeys := TDictionary<string, Boolean>.Create;
  LSB := TStringBuilder.Create;
  try
    CollectStructuredCases(LCases);
    CollectProseCases(ATestsDir, LCases);

    LTotalCases := 0;
    for LNames in LCases.Values do
      Inc(LTotalCases, LNames.Count);

    LSB.AppendLine('=== PasTree spec coverage ===');
    LSB.AppendLine;
    if ASpecDir <> '' then
      LSB.AppendLine('Spec checkout:  ' + ASpecDir)
    else
      LSB.AppendLine('Spec checkout:  NOT FOUND -- showing gathered cases ' +
        'only, no gaps (set SpecDir in the .ini to enable)');
    if ATestsDir <> '' then
      LSB.AppendLine('Tests checkout: ' + ATestsDir)
    else
      LSB.AppendLine('Tests checkout: NOT FOUND -- only ParserSmoke''s own ' +
        'data counted, not the other suites'' spec-tagged cases (set ' +
        'TestsDir in the .ini)');
    LSB.AppendLine;

    if ASpecDir <> '' then
    begin
      LSpec := LoadSpecSections(ASpecDir);
      LCoveredSections := 0;
      for LSection in LSpec do
        if LCases.ContainsKey(UpperCase(LSection.Section)) then
          Inc(LCoveredSections);
      LSB.AppendLine(Format('%d spec sections, %d covered (%d%%), ' +
        '%d cases total', [Length(LSpec), LCoveredSections,
        Round(100 * LCoveredSections / Max(1, Length(LSpec))), LTotalCases]));
      LSB.AppendLine;

      LChapter := '';
      for LSection in LSpec do
      begin
        if LSection.Chapter <> LChapter then
        begin
          LChapter := LSection.Chapter;
          LSB.AppendLine('--- ' + LChapter + ' ---');
        end;
        LSeenKeys.AddOrSetValue(UpperCase(LSection.Section), True);
        if LCases.TryGetValue(UpperCase(LSection.Section), LNames) then
        begin
          LSB.AppendLine(Format('[x] %-8s %s  (%d)',
            [LSection.Section, LSection.Title, LNames.Count]));
          for LName in LNames do
            LSB.AppendLine('        ' + LName);
        end
        else
          LSB.AppendLine(Format('[ ] %-8s %s',
            [LSection.Section, LSection.Title]));
      end;

      // Cases keyed to a section the spec listing above never mentioned --
      // a renumbered/renamed section, or a typo in a case's own Section
      // field. Surfaced rather than silently dropped (no silent caps).
      var LOrphans := TStringList.Create;
      try
        for LKey in LCases.Keys do
          if not LSeenKeys.ContainsKey(LKey) then
            LOrphans.Add(LKey);
        if LOrphans.Count > 0 then
        begin
          LOrphans.Sort;
          LSB.AppendLine;
          LSB.AppendLine(Format(
            '--- %d case section(s) not found in the spec listing above ' +
            '(renamed/typo''d?) ---', [LOrphans.Count]));
          for LKey in LOrphans do
          begin
            LCases.TryGetValue(LKey, LNames);
            LSB.AppendLine(Format('[?] %-8s (%d)', [LKey, LNames.Count]));
            for LName in LNames do
              LSB.AppendLine('        ' + LName);
          end;
        end;
      finally
        LOrphans.Free;
      end;
    end
    else
    begin
      // No spec checkout: list what was gathered, sorted, with no notion of
      // what is missing.
      LSB.AppendLine(Format('%d spec-numbered sections have at least one ' +
        'case, %d cases total', [LCases.Count, LTotalCases]));
      LSB.AppendLine;
      var LKeys := TStringList.Create;
      try
        for LKey in LCases.Keys do
          LKeys.Add(LKey);
        LKeys.Sort;
        for LKey in LKeys do
        begin
          LCases.TryGetValue(LKey, LNames);
          LSB.AppendLine(Format('[x] %-8s (%d)', [LKey, LNames.Count]));
          for LName in LNames do
            LSB.AppendLine('        ' + LName);
        end;
      finally
        LKeys.Free;
      end;
    end;

    Result := LSB.ToString;
  finally
    LSB.Free;
    LSeenKeys.Free;
    LCases.Free;
  end;
end;

end.
