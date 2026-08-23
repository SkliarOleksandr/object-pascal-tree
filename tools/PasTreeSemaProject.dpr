program PasTreeSemaProject;

{ Project-level (Phase 2) semantic dump: resolves uses across units and shows
  each unit's model, cross-unit refs and diagnostics.

  Usage: PasTreeSemaProject <file.dpr|file.dproj|dir>
           [-p:<platform>] [-st] [-proj] [-dproj] [-studio:<dir>] [-list]

  -proj  analyzes a FILE as a whole project (AnalyzeProject): the transitive
         uses closure, with the cross passes run on EVERY unit. Without it a
         file goes through AnalyzeFile, whose narrower contract cross-analyzes
         only the main file itself — so a package/program with no code of its
         own reports NO project-wide diagnostics at all, which reads
         misleadingly like "clean".

  -dproj drives a REAL .dproj the way the demo does: reads platform, search
         paths, defines, namespaces and unit aliases out of the project file
         and runs AnalyzeStaged over its main source, then reports stage
         timings, source volume and a diagnostics breakdown split by
         project-file vs library unit (the same split the demo's message
         window makes). This is the closest headless equivalent of opening
         the project in the demo — use it to reproduce and bisect what the
         demo reports.

         One deliberate difference: the demo also folds in the IDE's own
         library/browsing paths, read from the registry. This adds the Studio
         SOURCE trees instead -- $BDS or -studio:<dir>, then source\rtl\sys,
         source\rtl\common, source\rtl\win, source\rtl\net, source\vcl and
         source\fmx -- which is what makes System.*, Vcl.* and FMX.* resolve
         without a registry dependency. See StudioSearchPaths.

  -list  with -dproj, also dumps every project-file diagnostic (file:line:col)
         instead of only the histogram. Suppresses the per-unit model dump,
         which is what stdout normally carries.

  -members  turns ON the opt-in "unresolved member after a dot" diagnostic
         (TPasSemaProject.ReportUnresolvedMembers). Off by default because a
         FALSE E2003 on a member is worse than a missing one; this is how the
         corpora get measured for it. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Math,
  System.Diagnostics,
  System.Threading,
  System.IOUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.Project in '..\source\PasTree.Project.pas',
  PasTree.DProj in '..\source\PasTree.DProj.pas',
  PasTree.Sema.Diagnostics in '..\source\PasTree.Sema.Diagnostics.pas',
  PasTree.Sema.Model in '..\source\PasTree.Sema.Model.pas',
  PasTree.Sema.Builtins in '..\source\PasTree.Sema.Builtins.pas',
  PasTree.Sema.Resolver in '..\source\PasTree.Sema.Resolver.pas',
  PasTree.Sema.Dump in '..\source\PasTree.Sema.Dump.pas',
  PasTree.Sema.Project in '..\source\PasTree.Sema.Project.pas';

type
  TCount = record
    Name: string;
    N: Integer;
  end;

var
  GPlatform: TPasPlatform;
  GProj: TPasSemaProject;
  GPath, GStudio: string;
  GExtraPaths: TArray<string>;   // -L<dir>, repeatable; see the arg loop
  GIdx: Integer;
  GSingle, GWholeProject, GDProjMode, GList, GMembers, GIfs: Boolean;
  GVisibility: Boolean;
  GRelease: Boolean;   // -release: exercise ReleaseTransientMaps, report held
  GDemote: Boolean;    // -demote: stage 2 on top (DemoteClosedUnits)
  GSW: TStopwatch;
  GMode: string;

{ Studio SOURCE trees, so System.*/Vcl.*/FMX.* resolve. See the -dproj note in
  the header: the demo reads the IDE's registry paths, this does not. }
function StudioSearchPaths(const ARoot: string): TArray<string>;
const
  // winrt, databinding\engine and xml earn their place from the VCL/FMX package
  // closures: without them Vcl.Clipbrd, Vcl.Bind.* and FMX's Xml.XMLDoc importers
  // stay unresolved, and an unresolved unit silences its IMPORTERS' diagnostics
  // (the AllUsesResolved gate) — which reads as "clean" instead of "not
  // analyzed". Sanity check for any host doing this: the UNIT COUNT must match
  // what the IDE reports (271 for BuildWinVCL, 353 for BuildWinFMX).
  SUBS: array[0..8] of string = ('source\rtl\sys', 'source\rtl\common',
    'source\rtl\win', 'source\rtl\win\winrt', 'source\rtl\net',
    'source\databinding\engine', 'source\xml', 'source\vcl', 'source\fmx');
var
  LDir: string;
begin
  Result := nil;
  if ARoot = '' then
    Exit;
  for var LSub in SUBS do
  begin
    LDir := TPath.Combine(ARoot, LSub);
    if TDirectory.Exists(LDir) then
      Result := Result + [LDir];
  end;
end;

// TDictionary has no GetValueOrDefault in this RTL — one-liner instead.
procedure Bump(ACounts: TDictionary<string, Integer>; const AName: string);
var
  LN: Integer;
begin
  if not ACounts.TryGetValue(AName, LN) then
    LN := 0;
  ACounts.AddOrSetValue(AName, LN + 1);
end;

{ Descending by count, then by name so equal counts print stably.

  ASites (optional) annotates each row with a 'file(line,col)' site — for the
  missing-unit histogram, the FIRST place the name was imported. A count says
  a library is absent; the site says which of your units asked for it, which is
  the part you actually act on. }
procedure ReportHistogram(const ATitle: string;
  ACounts: TDictionary<string, Integer>; ATop: Integer;
  ASites: TDictionary<string, string> = nil);
var
  LRows: TArray<TCount>;
  LRow: TCount;
  LSite: string;
begin
  Writeln(ErrOutput, ATitle);
  if ACounts.Count = 0 then
  begin
    Writeln(ErrOutput, '    (none)');
    Exit;
  end;
  LRows := nil;
  for var LPair in ACounts do
  begin
    LRow.Name := LPair.Key;
    LRow.N := LPair.Value;
    LRows := LRows + [LRow];
  end;
  TArray.Sort<TCount>(LRows, TComparer<TCount>.Construct(
    function(const A, B: TCount): Integer
    begin
      Result := B.N - A.N;
      if Result = 0 then
        Result := CompareText(A.Name, B.Name);
    end));
  for var LI := 0 to Min(ATop, Length(LRows)) - 1 do
  begin
    if (ASites <> nil) and ASites.TryGetValue(LRows[LI].Name, LSite) then
      Writeln(ErrOutput, Format('    %5d  %-40s first at %s',
        [LRows[LI].N, LRows[LI].Name, LSite]))
    else
      Writeln(ErrOutput, Format('    %5d  %s', [LRows[LI].N, LRows[LI].Name]));
  end;
  if Length(LRows) > ATop then
    Writeln(ErrOutput, Format('    ... %d more distinct name(s)',
      [Length(LRows) - ATop]));
end;

{ The -dproj driver. }
procedure RunDProj(const APath: string);
var
  LD: TPasDProj;
  LPaths: TArray<string>;
  LOwn: TDictionary<string, Boolean>;   // project-file paths, lower-cased
  LInProj, LOutProj, LMissing: TDictionary<string, Integer>;
  LSites: TDictionary<string, string>;   // missing name -> FIRST import site
  LLibSites: TDictionary<string, string>;   // library diag name -> FIRST site
  LM: TPasSemaModel;
  LTotalLines, LTotalChars, LTotalFiles: Int64;
  LListed, LOther, LMid, LDIdx, LFileId, LQuote: Integer;
  LUnresUses, LUnitsGated, LSiteLine, LSiteCol: Integer;
  LName, LFile, LSiteFile: string;
  LIsOwn: Boolean;
begin
  LD := TPasDProj.Create;
  LOwn := TDictionary<string, Boolean>.Create;
  LInProj := TDictionary<string, Integer>.Create;
  LOutProj := TDictionary<string, Integer>.Create;
  LMissing := TDictionary<string, Integer>.Create;
  LSites := TDictionary<string, string>.Create;
  LLibSites := TDictionary<string, string>.Create;
  try
    if not LD.Load(APath, PlatformName(GPlatform)) then
    begin
      Writeln(ErrOutput, 'Could not load .dproj: ', APath);
      ExitCode := 2;
      Exit;
    end;
    if not TFile.Exists(LD.MainSource) then
    begin
      Writeln(ErrOutput, 'MainSource missing: ', LD.MainSource);
      ExitCode := 2;
      Exit;
    end;
    // Same assembly order the demo's BuildConfig uses: project dir, the
    // .dproj's own search paths, then the Studio trees.
    LPaths := [LD.Dir] + LD.SearchPaths + StudioSearchPaths(GStudio) +
      GExtraPaths;
    for var LF in LD.Files do
      LOwn.AddOrSetValue(LowerCase(LF), True);

    Writeln(ErrOutput, '=== ', TPath.GetFileName(APath), ' ===');
    // The configuration is not just a label: it decides the defines, the
    // search paths and (through per-config DCCReference conditions) the file
    // list. Naming the alternatives makes "why does this project analyze
    // differently in the IDE" answerable from the report alone.
    Writeln(ErrOutput, Format('  platform %s, config %s (of %s)',
      [PlatformName(LD.Platform), LD.Config,
       string.Join(', ', LD.Configurations)]));
    Writeln(ErrOutput, Format(
      '  %d search path(s), %d define(s), %d namespace(s), %d alias(es)',
      [Length(LPaths), Length(LD.Defines), Length(LD.Namespaces),
       Length(LD.UnitAliases)]));
    // NAMED, not just counted. These decide which branches are live, so "4
    // define(s)" is exactly the wrong amount of detail when a line is greying
    // out and you want to know whether DEBUG is among them. Short by nature.
    if Length(LD.Defines) > 0 then
      Writeln(ErrOutput, '    defines: ', string.Join(';', LD.Defines));
    Writeln(ErrOutput, Format('  %d project file(s)', [Length(LD.Files)]));
    if GStudio = '' then
      Writeln(ErrOutput,
        '  NB no Studio root (BDS unset, no -studio:) — RTL/VCL/FMX will not resolve');

    GProj := TPasSemaProject.Create(LD.Platform, LPaths, LD.Defines);
    try
      GProj.SingleThreaded := GSingle;
      GProj.ReportUnresolvedMembers := GMembers;
      GProj.ReportVisibility := GVisibility;
      GProj.ReportGuessedIfs := GIfs;
      // No -NS list in the .dproj means we could not read the option, not that
      // the project wants zero prefixes — dcc has none built in, so zero would
      // turn every legacy unqualified import into an F1027.
      if Length(LD.Namespaces) > 0 then
        GProj.SetNamespaces(LD.Namespaces)
      else
        GProj.SetNamespaces(PasDefaultNamespaces(LD.Platform));
      // Defaults always, project's on top (the IDE prepends rather than
      // replaces; AddUnitAlias is last-wins, so this gives the project priority).
      for var LDef in PasDefaultUnitAliases(LD.Platform) do
        GProj.AddUnitAlias(LDef.Alias, LDef.UnitName);
      for var LA in LD.UnitAliases do
        GProj.AddUnitAlias(LA.Alias, LA.UnitName);

      GSW := TStopwatch.StartNew;
      GProj.AnalyzeStaged([LD.MainSource], []);
      GSW.Stop;

      LTotalLines := 0; LTotalChars := 0; LTotalFiles := 0;
      LListed := 0; LOther := 0;
      LUnresUses := 0; LUnitsGated := 0;
      for LMid := 0 to GProj.ModelCount - 1 do
      begin
        LM := GProj.Model(LMid);
        for LFileId := 0 to High(LM.Tree.Source.Files) do
        begin
          Inc(LTotalFiles);
          Inc(LTotalLines, Length(LM.Tree.Source.Files[LFileId].LineStarts));
          Inc(LTotalChars, Length(LM.Tree.Source.Files[LFileId].Source));
        end;
        // Closure HEALTH. A `uses` name that did not resolve means a subtree
        // the compiler would have compiled is simply absent here — so the unit
        // count is an UNDER-count, and E2003 is suppressed for that unit
        // (AllUsesResolved gates it), which makes the diagnostics an
        // under-count too. dcc treats an unresolvable uses as fatal (F1027),
        // so on a project that really builds, a healthy run has zero.
        for var LU := 0 to High(LM.UsesList) do
          if LM.UsesList[LU].UnitId < 0 then
          begin
            Inc(LUnresUses);
            Bump(LMissing, LM.UsesList[LU].NameFull);
            // First sighting only: models are numbered in discovery order and
            // UsesList is in source order, so the first write is the earliest
            // place the analyzer met the name.
            if not LSites.ContainsKey(LM.UsesList[LU].NameFull) then
              if GProj.NodeSite(LMid, LM.UsesList[LU].NameNode,
                   {out} LSiteFile, {out} LSiteLine, {out} LSiteCol) then
                LSites.Add(LM.UsesList[LU].NameFull,
                  Format('%s(%d,%d)', [TPath.GetFileName(LSiteFile), LSiteLine,
                    LSiteCol]));
          end;
        if not LM.AllUsesResolved then
          Inc(LUnitsGated);
        LIsOwn := LOwn.ContainsKey(LowerCase(GProj.ModelFile(LMid)));
        for LDIdx := 0 to High(LM.Diags) do
        begin
          // Only E2003 carries a name worth counting; others are shapes.
          LName := LM.Diags[LDIdx].Code;
          if LName = 'E2003' then
          begin
            LName := LM.Diags[LDIdx].Msg;
            LQuote := Pos('''', LName);
            if LQuote > 0 then
              LName := Copy(LName, LQuote + 1, Length(LName) - LQuote - 1);
          end;
          if LIsOwn then
          begin
            Inc(LListed);
            Bump(LInProj, LName);
            if GList then
            begin
              LFileId := LM.Diags[LDIdx].FileId;
              if (LFileId >= 0) and
                 (LFileId <= High(LM.Tree.Source.FileNames)) then
                LFile := LM.Tree.Source.FileNames[LFileId]
              else
                LFile := GProj.ModelFile(LMid);
              Writeln(Format('%s(%d,%d): %s %s',
                [LFile, LM.Diags[LDIdx].Line, LM.Diags[LDIdx].Col,
                 LM.Diags[LDIdx].Code, LM.Diags[LDIdx].Msg]));
            end;
          end
          else
          begin
            Inc(LOther);
            Bump(LOutProj, LName);
            // The one exception to counted-not-listed below: the residual-$IF
            // codes are what -ifs exists to show, they live almost entirely in
            // LIBRARY units (FastMM4, Indy, third-party suites), and there are
            // a handful of them — so "one site per name" would hide all but
            // the first. Listing them needs -list as well, like everything
            // else that prints per site.
            if GList and GIfs and ((LM.Diags[LDIdx].Code = 'PPIF') or
               (LM.Diags[LDIdx].Code = 'PPBAD')) then
            begin
              LFileId := LM.Diags[LDIdx].FileId;
              if (LFileId >= 0) and
                 (LFileId <= High(LM.Tree.Source.FileNames)) then
                LFile := LM.Tree.Source.FileNames[LFileId]
              else
                LFile := GProj.ModelFile(LMid);
              Writeln(Format('%s(%d,%d): %s %s',
                [LFile, LM.Diags[LDIdx].Line, LM.Diags[LDIdx].Col,
                 LM.Diags[LDIdx].Code, LM.Diags[LDIdx].Msg]));
            end;
            // Library diagnostics are counted, not listed — but a bare count
            // is not actionable: working the tail down means opening the site,
            // and finding it by grepping a 3790-unit closure for a name like
            // `Left` is hopeless. One site per NAME, the first one met.
            if not LLibSites.ContainsKey(LName) then
            begin
              LFileId := LM.Diags[LDIdx].FileId;
              if (LFileId >= 0) and
                 (LFileId <= High(LM.Tree.Source.FileNames)) then
                LFile := LM.Tree.Source.FileNames[LFileId]
              else
                LFile := GProj.ModelFile(LMid);
              LLibSites.Add(LName, Format('%s(%d,%d)',
                [TPath.GetFileName(LFile), LM.Diags[LDIdx].Line,
                 LM.Diags[LDIdx].Col]));
            end;
          end;
        end;
      end;

      if GSingle then
        GMode := 'SingleThread'
      else
        GMode := 'MultiThread';
      Writeln(ErrOutput, Format('analysis: %d units in %.1f s, %s held (%s)',
        [GProj.ModelCount, GSW.ElapsedMilliseconds / 1000,
         MemoryText(AllocatedBytes), GMode]));
      if GProj.StageTimings <> '' then
        Writeln(ErrOutput, '  stages: ', GProj.StageTimings);
      // The retained-memory measurements: keep only the main source (the
      // "open editor"), release/demote everything else, report the delta.
      if GRelease then
      begin
        GProj.ReleaseTransientMaps([LD.MainSource]);
        Writeln(ErrOutput, Format('  after ReleaseTransientMaps: %s held',
          [MemoryText(AllocatedBytes)]));
      end;
      if GDemote then
      begin
        GProj.DemoteClosedUnits([LD.MainSource]);
        Writeln(ErrOutput, Format('  after DemoteClosedUnits: %s held',
          [MemoryText(AllocatedBytes)]));
      end;
      if LTotalLines > 0 then
        Writeln(ErrOutput, Format(
          '  source: %s lines, %.1f MB, %s file(s) — %s lines/s',
          [FormatFloat('#,##0', LTotalLines), LTotalChars / (1024 * 1024),
           FormatFloat('#,##0', LTotalFiles),
           FormatFloat('#,##0', LTotalLines * 1000 /
             Max(1, GSW.ElapsedMilliseconds))]));
      Writeln(ErrOutput, Format(
        'closure: %d unresolved `uses` name(s); %d of %d unit(s) have E2003 '
        + 'GATED because of them',
        [LUnresUses, LUnitsGated, GProj.ModelCount]));
      Writeln(ErrOutput, Format(
        'diagnostics: %d total — %d in project files, %d in library units',
        [LListed + LOther, LListed, LOther]));
      // OUR failures, kept distinct from F1027: the file is present and we
      // broke on it. Silence here once let an internal ERangeError look like a
      // missing unit for a whole day.
      if Length(GProj.LoadFailures) > 0 then
      begin
        Writeln(ErrOutput, Format('INTERNAL: %d unit(s) failed to parse — ' +
          'analyzer defect, not a missing file:', [Length(GProj.LoadFailures)]));
        for var LFail in GProj.LoadFailures do
          Writeln(ErrOutput, '    ' + LFail);
      end;
      ReportHistogram('--- unresolvable `uses` names, by import count ---',
        LMissing, 25, LSites);
      ReportHistogram('--- project files, by identifier/code ---', LInProj, 25);
      ReportHistogram('--- library units, by identifier/code ---', LOutProj, 25,
        LLibSites);
    finally
      GProj.Free;
    end;
  finally
    LMissing.Free;
    LSites.Free;
    LLibSites.Free;
    LOutProj.Free;
    LInProj.Free;
    LOwn.Free;
    LD.Free;
  end;
end;

begin
  // The driver fans parse+resolve out across cores; without this the default
  // memory manager SLEEPS on allocation contention and eats the whole win.
  System.NeverSleepOnMMThreadContention := True;
  try
    if ParamCount < 1 then
    begin
      Writeln(ErrOutput, 'Usage: PasTreeSemaProject <file.dpr|file.dproj|dir>'
        + ' [-p:<platform>] [-st] [-proj] [-dproj] [-studio:<dir>] [-list]');
      ExitCode := 2;
      Exit;
    end;
    GPath := TPath.GetFullPath(ParamStr(1));
    GPlatform := pfWin32;
    GSingle := False;
    GWholeProject := False;
    GDProjMode := False;
    GList := False;
    GMembers := False;
    GIfs := False;
    GVisibility := False;
    GStudio := GetEnvironmentVariable('BDS');
    for GIdx := 2 to ParamCount do
      // The exact-match flags come FIRST, because `-L` below is a
      // case-insensitive PREFIX and `-list` starts with `-l`: it was being
      // swallowed as a search path named "ist", so the flag silently did
      // nothing and every run with it carried one bogus path (the report's
      // search-path count is where that showed).
      if SameText(ParamStr(GIdx), '-st') then
        GSingle := True    // single-threaded baseline (timing comparison)
      else if SameText(ParamStr(GIdx), '-proj') then
        GWholeProject := True
      else if SameText(ParamStr(GIdx), '-dproj') then
        GDProjMode := True
      else if SameText(ParamStr(GIdx), '-list') then
        GList := True
      else if SameText(ParamStr(GIdx), '-members') then
        GMembers := True
      else if SameText(ParamStr(GIdx), '-ifs') then
        // Residual- exotica: every guard still GUESSED after the second
        // pass (PPIF) and every malformed conditional (PPBAD), as ordinary
        // diagnostics -- flows through -list and the histograms.
        GIfs := True
      else if SameText(ParamStr(GIdx), '-visibility') then
        GVisibility := True
      else if SameText(ParamStr(GIdx), '-release') then
        GRelease := True
      else if SameText(ParamStr(GIdx), '-demote') then
        GDemote := True
      else if ParamStr(GIdx).StartsWith('-p:', True) then
        TryParsePlatformName(Copy(ParamStr(GIdx), 4, MaxInt), GPlatform)
      else if ParamStr(GIdx).StartsWith('-studio:', True) then
        GStudio := Copy(ParamStr(GIdx), 9, MaxInt)
      // -L<dir>: one extra search path, repeatable. The demo folds in the IDE's
      // registry Library/Browsing paths, which is where a real project's
      // third-party components live (large component suites). This is how a
      // headless run reaches the same closure without teaching the tool to read
      // the registry — and the closure line in the report is the check that it
      // did: a short unit count means paths are still missing, and a missing
      // unit GATES its importers' diagnostics rather than reporting them.
      else if ParamStr(GIdx).StartsWith('-L', True) and
              (Length(ParamStr(GIdx)) > 2) then
        GExtraPaths := GExtraPaths + [Copy(ParamStr(GIdx), 3, MaxInt)]
      // Through ConfigureThreadPool, not SetMaxWorkerThreads directly: the
      // project's constructor pins the pool (Min first, then Max) and ignores
      // a bare SetMaxWorkerThreads made before it — the flag silently did
      // nothing. ConfigureThreadPool is first-caller-wins, so doing it here
      // makes the constructor's later call the no-op instead.
      else if ParamStr(GIdx).StartsWith('-threads:', True) then
        TPasSemaProject.ConfigureThreadPool(
          StrToIntDef(Copy(ParamStr(GIdx), 10, MaxInt), 0));
    // A .dproj argument means -dproj; asking for it explicitly is redundant
    // but harmless.
    if SameText(TPath.GetExtension(GPath), '.dproj') then
      GDProjMode := True;

    if GDProjMode then
    begin
      RunDProj(GPath);
      Exit;
    end;

    if TDirectory.Exists(GPath) then
      // A DIRECTORY run is a closed corpus by design: whatever is in the
      // directory is the whole world, so its F1027s are meaningful and its
      // counts are comparable run to run. Adding the Studio trees here would
      // silently change what is being measured.
      GProj := TPasSemaProject.Create(GPlatform, [GPath], [])
    else
      // A FILE target (`-proj` over a .dpk/.dpr) states nothing about where the
      // RTL lives, and without it every `uses System.X` is an F1027 and no
      // E2003 can be trusted. Same Studio SOURCE trees the -dproj driver adds.
      GProj := TPasSemaProject.Create(GPlatform,
        [TPath.GetDirectoryName(GPath)] + StudioSearchPaths(GStudio) +
        GExtraPaths, []);
    try
      GProj.SingleThreaded := GSingle;
      GProj.ReportUnresolvedMembers := GMembers;
      GProj.ReportVisibility := GVisibility;
      GProj.ReportGuessedIfs := GIfs;
      // Same reasoning as the -dproj driver: a directory or bare-file run has
      // no project to state its prefixes, and zero prefixes is not what the IDE
      // would use.
      GProj.SetNamespaces(PasDefaultNamespaces(GPlatform));
      for var LDef in PasDefaultUnitAliases(GPlatform) do
        GProj.AddUnitAlias(LDef.Alias, LDef.UnitName);
      GSW := TStopwatch.StartNew;
      if TDirectory.Exists(GPath) then
        GProj.AnalyzeDirectory(GPath)
      else if GWholeProject then
        GProj.AnalyzeProject(GPath)
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
      Writeln(ErrOutput, Format('%d units in %d ms, %s held (%s)',
        [GProj.ModelCount, GSW.ElapsedMilliseconds,
         MemoryText(AllocatedBytes), GMode]));
      // Per-stage breakdown: without it a slow run says only THAT it is slow.
      if GProj.StageTimings <> '' then
        Writeln(ErrOutput, 'stages: ' + GProj.StageTimings);
      if GRelease then
      begin
        GProj.ReleaseTransientMaps([GPath]);
        Writeln(ErrOutput, Format('after ReleaseTransientMaps: %s held',
          [MemoryText(AllocatedBytes)]));
      end;
      if GDemote then
      begin
        GProj.DemoteClosedUnits([GPath]);
        Writeln(ErrOutput, Format('after DemoteClosedUnits: %s held',
          [MemoryText(AllocatedBytes)]));
      end;
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
