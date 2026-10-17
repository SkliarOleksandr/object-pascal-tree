program PasTreeSemaProject;

{ Project-level (Phase 2) semantic dump: resolves uses across units and shows
  each unit's model, cross-unit refs and diagnostics.

  Usage: PasTreeSemaProject <file.dpr|file.dproj|dir>
           [-p:<platform>] [-st] [-proj] [-dproj] [-studio:<dir>] [-list]

  -proj  analyzes a FILE as a whole project (AnalyzeProject): the transitive
         uses closure, with the cross passes run on EVERY unit. Without it a
         file goes through AnalyzeFile, whose narrower contract cross-analyzes
         only the main file itself - so a package/program with no code of its
         own reports NO project-wide diagnostics at all, which reads
         misleadingly like "clean".

  -dproj drives a REAL .dproj the way the demo does: reads platform, search
         paths, defines, namespaces and unit aliases out of the project file
         and runs AnalyzeStaged over its main source, then reports stage
         timings, source volume and a diagnostics breakdown split by
         project-file vs library unit (the same split the demo's message
         window makes). This is the closest headless equivalent of opening
         the project in the demo - use it to reproduce and bisect what the
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

  -defines  after the analysis, list every conditional-symbol mention the
         preprocessor recorded for the ROOT file (TPasPreprocessed.DefineRefs)
         and probe TPasNavigator.DefineAt / GotoDefine at each - the headless
         twin of Find References / ctrl+click on a define in the .dpr.

  -overrides:TClass.Method / -impls:IIntf.Method  (repeatable) after the
         analysis, run the demo's Find Overrides / Find Implementations for
         that method (found by NAME over the closure - every declaration of
         that name on a struct type of that name, so overloads and same-named
         types in two units each get their own block) and print every row.
         The headless way to check "the demo showed one row" against what the
         closure really holds.

  -members  turns ON the opt-in "unresolved member after a dot" diagnostic
         (TPasSemaProject.ReportUnresolvedMembers). Off by default because a
         FALSE E2003 on a member is worse than a missing one; this is how the
         corpora get measured for it.

  -$<switch> (repeatable: -$D-, -$A4, -$YD) and -CC  dcc's own command-line
         switches and console target (TPasSemaProject.SwitchStart,
         ConsoleTarget). With -dproj they go on top of the .dproj's DCC_*
         switch properties and DCC_ConsoleTarget, which are always read.

  Light-mode measurements (library units interface-only). "Own" is a unit
  the .dproj lists or one under its directory; a directory run counts every
  unit as own, a file run what lies under the file's directory.

  -fp:<file>  per own unit one line: the file, then count:hash for RefMap,
         ExprType, ExtRefMap, CallTargetX, SymTypeX, ExprTypeX and Diags.
         Order-independent, a target named by file + symbol name + declaring
         node (never a model id), so two closures compare. -fpdetail also
         writes every entry, sorted, to <file>.detail.txt.

  -stats  per category (own listed, own unlisted, Studio, other) units,
         tokens and nodes with their interface shares; the closure each light
         rule would load; references from library code to own units, by target.

  -demotelib  at the end, DemoteText keeping the own units: held memory and
         the time it took (the MCP server's resident state).

  -promote:<file> (repeatable)  AnalyzeModuleOnly over the file, timed, with
         its stage timings and what the module holds after.

  -refset:<unit> (repeatable)  the units whose bodies could refer to a symbol
         of the unit: a unit-level name's candidates and a member's, by
         category with node totals. }

{$APPTYPE CONSOLE}
{$MAXSTACKSIZE $01000000}   // 16 MB per thread: README, "The stack every host should reserve"

uses
  System.SysUtils,
  System.StrUtils,
  System.Math,
  System.Diagnostics,
  System.Threading,
  System.IOUtils,
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
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.Project in '..\source\PasTree.Project.pas',
  PasTree.DProj in '..\source\PasTree.DProj.pas',
  PasTree.Sema.Diagnostics in '..\source\PasTree.Sema.Diagnostics.pas',
  PasTree.Sema.Model in '..\source\PasTree.Sema.Model.pas',
  PasTree.Sema.Builtins in '..\source\PasTree.Sema.Builtins.pas',
  PasTree.Sema.Resolver in '..\source\PasTree.Sema.Resolver.pas',
  PasTree.Sema.Dump in '..\source\PasTree.Sema.Dump.pas',
  PasTree.Sema.Project in '..\source\PasTree.Sema.Project.pas',
  PasTree.Sema.Nav in '..\source\PasTree.Sema.Nav.pas',
  PasTree.Sema.Lint in '..\source\PasTree.Sema.Lint.pas';

type
  TCount = record
    Name: string;
    N: Integer;
  end;

var
  GPlatform: TPasPlatform;
  GPlatformGiven: Boolean;
  GProj: TPasSemaProject;
  GPath, GStudio: string;
  GExtraPaths: TArray<string>;   // -L<dir>, repeatable; see the arg loop
  GSwitches: TArray<string>;     // -$X+ / -$A4 ..., dcc's command-line switches
  GConsole: Boolean;             // -CC, dcc's console target
  // -overrides:TClass.Method / -impls:IIntf.Method, repeatable: Find
  // Overrides / Find Implementations queries to run over the analyzed closure
  // and print (see ReportChains). The headless twin of the demo's two
  // context-menu commands, for reproducing "the demo showed one row" against
  // a real project without the demo.
  GOverrideQueries, GImplQueries: TArray<string>;
  GIdx: Integer;
  GSingle, GWholeProject, GDProjMode, GList, GMembers, GIfs: Boolean;
  GVisibility: Boolean;
  GRelease: Boolean;   // -release: exercise ReleaseTransientMaps, report held
  GDemote: Boolean;    // -demote: stage 2 on top (DemoteClosedUnits)
  GRehydrate: Boolean; // -rehydrate: after -demote, EnsureHydrated EVERY model
  GOutline: Boolean;   // -outline: TPasNavigator.ProjectOutline over the .dproj files, row count + first rows (the Go To project tab, headless)
  GUnused: Boolean;    // -unused: FindUnusedUses over the .dproj files, every row (Find All > Unused Units in the Project, headless)
  GDefines: Boolean;   // -defines: dump the ROOT model's DefineRefs and probe
                       // DefineAt/GotoDefine on each (the headless twin of
                       // Find References on a conditional symbol)
                       // and report failures - the stream-reproducibility
                       // check over a real closure (includes, $IF oracle,
                       // recovered encodings), which no fixture can cover.
  GSW: TStopwatch;
  GMode: string;
  // Light-mode measurements, see ReportLightMeasures and the header.
  GStats: Boolean;            // -stats
  GDemoteLib: Boolean;        // -demotelib
  GFp: string;                // -fp:<file>
  GFpDetail: Boolean;         // -fpdetail
  GRefSets: TArray<string>;   // -refset:<unit>, repeatable
  GPromotes: TArray<string>;  // -promote:<file>, repeatable

{ Studio SOURCE trees, so System.*/Vcl.*/FMX.* resolve. See the -dproj note in
  the header: the demo reads the IDE's registry paths, this does not. }
function StudioSearchPaths(const ARoot: string): TArray<string>;
const
  // winrt, databinding\engine and xml earn their place from the VCL/FMX package
  // closures: without them Vcl.Clipbrd, Vcl.Bind.* and FMX's Xml.XMLDoc importers
  // stay unresolved, and an unresolved unit silences its IMPORTERS' diagnostics
  // (the AllUsesResolved gate) - which reads as "clean" instead of "not
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

// TDictionary has no GetValueOrDefault in this RTL - one-liner instead.
{ -defines: the root model's DefineRefs, each probed through the navigator
  the way an editor would ask (DefineAt at the name's own position, then
  GotoDefine). A row that the preprocessor recorded but DefineAt refuses is
  exactly the shape this exists to catch. }
procedure ReportDefines(const ARootPath: string);
const
  KINDS: array[TPasDefineRefKind] of string =
    ('DEFINE', 'UNDEF', 'IFDEF', 'IFNDEF', 'Defined');
var
  LNav: TPasNavigator;
  LMid, LIdx, LLine, LCol, LRaw: Integer;
  LM: TPasSemaModel;
  LRef: TPasDefineRef;
  LName, LProbe: string;
  LTarget: TPasNavTarget;
begin
  LNav := TPasNavigator.Create(GProj);
  try
    LMid := LNav.ModelIdOf(ARootPath);
    Writeln(ErrOutput, Format('=== defines: root %s -> model %d ===',
      [TPath.GetFileName(ARootPath), LMid]));
    if LMid < 0 then
      Exit;
    LM := GProj.Model(LMid);
    Writeln(ErrOutput, Format('  %d DefineRefs, %d file(s), demoted=%s',
      [Length(LM.Tree.Source.DefineRefs), Length(LM.Tree.Source.Files),
       BoolToStr(LM.Demoted, True)]));
    for LIdx := 0 to High(LM.Tree.Source.DefineRefs) do
    begin
      LRef := LM.Tree.Source.DefineRefs[LIdx];
      GProj.EnsureHydrated(LMid);
      LM.Tree.Source.Files[LRef.FileId].OffsetToLineCol(LRef.Start, LLine, LCol);
      LProbe := '';
      if LRef.FileId = 0 then
      begin
        if LNav.DefineAt(LMid, LLine, LCol, LName, LRaw) then
        begin
          LProbe := Format('DefineAt=%s raw=%d', [LName, LRaw]);
          if LNav.GotoDefine(LMid, LLine, LCol, LTarget) then
            LProbe := LProbe + Format(' -> %s(%d,%d)',
              [TPath.GetFileName(LTarget.FilePath), LTarget.Line, LTarget.Col])
          else if LNav.IsProjectDefined(LRef.Name) then
            LProbe := LProbe + ' -> project define'
          else
            LProbe := LProbe + ' -> no $DEFINE before it';
        end
        else
          LProbe := 'DefineAt REFUSED';
      end;
      Writeln(ErrOutput, Format('  %s(%d,%d) %-7s %-24s %s %s',
        [TPath.GetFileName(LM.Tree.Source.FileNames[LRef.FileId]), LLine, LCol,
         KINDS[LRef.Kind], LRef.Name,
         IfThen(LRef.Active, 'active  ', 'inactive'), LProbe]));
    end;
  finally
    LNav.Free;
  end;
end;

procedure Bump(ACounts: TDictionary<string, Integer>; const AName: string);
var
  LN: Integer;
begin
  if not ACounts.TryGetValue(AName, LN) then
    LN := 0;
  ACounts.AddOrSetValue(AName, LN + 1);
end;

{ Descending by count, then by name so equal counts print stably.

  ASites (optional) annotates each row with a 'file(line,col)' site - for the
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
{ Every (model, symbol) of a method named AMethod declared directly by a
  struct type named AType - by NAME over the whole closure, since a headless
  run has no caret to click. Several hits are normal: overloads, and the same
  type name declared in more than one unit. }
function FindMethodSyms(const AType, AMethod: string): TArray<TPasExtRef>;
var
  LMi, LSym, LScope, LStruct: Integer;
  LM: TPasSemaModel;
  LRef: TPasExtRef;
begin
  Result := nil;
  for LMi := 0 to GProj.ModelCount - 1 do
  begin
    LM := GProj.Model(LMi);
    for LSym := 0 to LM.SymCount - 1 do
    begin
      if (LM.Symbols[LSym].Kind <> skRoutine) or
         not SameText(LM.Symbols[LSym].Name, AMethod) then
        Continue;
      LScope := LM.Symbols[LSym].Scope;
      if (LScope < 0) or (LScope >= LM.Scopes.Count) or
         (LM.Scopes[LScope].Kind <> sckStruct) then
        Continue;
      LStruct := LM.Scopes[LScope].StructSym;
      if (LStruct = NIL_SYM) or not SameText(LM.Symbols[LStruct].Name, AType)
      then
        Continue;
      LRef.UnitId := LMi;
      LRef.Sym := LSym;
      Result := Result + [LRef];
    end;
  end;
end;

{ Runs the -overrides:/-impls: queries and prints every row as
  `file(line): Type kind`, plus a rows/files summary line. The demo's two
  result pages, as text. }
procedure ReportChains;
const
  OVK: array[TPasOverrideKind] of string = ('root', 'override', 'message',
    'reintroduce', 'redeclared');
  IMK: array[TPasImplKind] of string = ('declares', 'implements',
    'implements-via');
var
  LNav: TPasNavigator;
  LQ, LType, LMethod: string;
  LDot, LIdx, LFiles: Integer;
  LRefs: TArray<TPasExtRef>;
  LOvs: TArray<TPasOverrideHit>;
  LImps: TArray<TPasImplHit>;
  LSeenFiles: TDictionary<string, Boolean>;
begin
  if (Length(GOverrideQueries) = 0) and (Length(GImplQueries) = 0) then
    Exit;
  LNav := TPasNavigator.Create(GProj);
  LSeenFiles := TDictionary<string, Boolean>.Create;
  try
    for LQ in GOverrideQueries do
    begin
      LDot := LastDelimiter('.', LQ);
      LType := Copy(LQ, 1, LDot - 1);
      LMethod := Copy(LQ, LDot + 1, MaxInt);
      LRefs := FindMethodSyms(LType, LMethod);
      Writeln(Format('--- overrides of %s: %d matching declaration(s) ---',
        [LQ, Length(LRefs)]));
      for var LRef in LRefs do
      begin
        LOvs := LNav.FindOverrides(LRef.UnitId, LRef.Sym);
        LSeenFiles.Clear;
        for LIdx := 0 to High(LOvs) do
        begin
          LSeenFiles.AddOrSetValue(LowerCase(LOvs[LIdx].Hit.FilePath), True);
          Writeln(Format('  %s(%d): %s %s', [LOvs[LIdx].Hit.FilePath,
            LOvs[LIdx].Hit.Line, LOvs[LIdx].TypeName, OVK[LOvs[LIdx].Kind]]));
        end;
        LFiles := LSeenFiles.Count;
        Writeln(Format('  = %d row(s) in %d file(s) from %s',
          [Length(LOvs), LFiles, GProj.ModelFile(LRef.UnitId)]));
      end;
    end;
    for LQ in GImplQueries do
    begin
      LDot := LastDelimiter('.', LQ);
      LType := Copy(LQ, 1, LDot - 1);
      LMethod := Copy(LQ, LDot + 1, MaxInt);
      LRefs := FindMethodSyms(LType, LMethod);
      Writeln(Format('--- implementations of %s: %d matching declaration(s) ---',
        [LQ, Length(LRefs)]));
      for var LRef in LRefs do
      begin
        LImps := LNav.FindImplementations(LRef.UnitId, LRef.Sym);
        LSeenFiles.Clear;
        for LIdx := 0 to High(LImps) do
        begin
          LSeenFiles.AddOrSetValue(LowerCase(LImps[LIdx].Hit.FilePath), True);
          Writeln(Format('  %s(%d): %s %s %s', [LImps[LIdx].Hit.FilePath,
            LImps[LIdx].Hit.Line, LImps[LIdx].TypeName, IMK[LImps[LIdx].Kind],
            LImps[LIdx].ViaTypeName]));
        end;
        LFiles := LSeenFiles.Count;
        Writeln(Format('  = %d row(s) in %d file(s) from %s',
          [Length(LImps), LFiles, GProj.ModelFile(LRef.UnitId)]));
      end;
    end;
  finally
    LSeenFiles.Free;
    LNav.Free;
  end;
end;

// OUR failures, kept distinct from F1027: the file is present and we broke
// on it. Silence here once let an internal ERangeError look like a missing
// unit for a whole day - so every mode prints them, not -dproj alone.
procedure ReportLoadFailures;
begin
  if Length(GProj.LoadFailures) > 0 then
  begin
    Writeln(ErrOutput, Format('INTERNAL: %d unit(s) failed to parse - ' +
      'analyzer defect, not a missing file:', [Length(GProj.LoadFailures)]));
    for var LFail in GProj.LoadFailures do
      Writeln(ErrOutput, '    ' + LFail);
  end;
end;

// ---- Light-mode measurements: -stats, -fp, -refset, -promote, -demotelib ----
// The harness every light-mode gate reads (local working plan, stage 0). A
// unit is put in one of four categories by its file alone: own listed (the
// .dproj names it), own unlisted (under the project directory), Studio (under
// the Studio root) and other (a library path). A directory run has no project
// to say what is library: every unit is own there (GAllOwn).
const
  CAT_NAMES: array[0..3] of string = ('own-listed', 'own-unlisted', 'studio',
    'other');

var
  GAllOwn: Boolean;
  GOwnDir: string;
  GOwnFiles: TDictionary<string, Boolean>;   // lower-cased; nil = none listed

function UnitCat(const AFile: string): Integer;
begin
  if GAllOwn or ((GOwnFiles <> nil) and
     GOwnFiles.ContainsKey(LowerCase(AFile))) then
    Result := 0
  else if (GOwnDir <> '') and
          StartsText(IncludeTrailingPathDelimiter(GOwnDir), AFile) then
    Result := 1
  else if (GStudio <> '') and
          StartsText(IncludeTrailingPathDelimiter(GStudio), AFile) then
    Result := 2
  else
    Result := 3;
end;

// The node index of the unit's implementation section, -1 when there is none
// (an interface-only tree, a program).
function ImplSecNode(M: TPasSemaModel): Integer;
var
  LC: Integer;
begin
  Result := -1;
  if (Length(M.Tree.Nodes) = 0) or (M.Tree.Nodes[0].Kind <> nkUnit) then
    Exit;
  LC := M.Tree.Nodes[0].FirstChild;
  while LC >= 0 do
  begin
    if M.Tree.Nodes[LC].Kind = nkImplementationSec then
      Exit(LC);
    LC := M.Tree.Nodes[LC].NextSibling;
  end;
end;

// Per category: units, tokens, nodes and the interface share of each; the
// closure each light rule would load (a light unit's implementation `uses`
// not followed); references from library code to own units, by target.
procedure ReportLightStats(const AMain: string);
var
  LUnits, LTok, LTokIntf, LNodes, LNodesIntf, LChars: array[0..3] of Int64;
  LReach: array[0..2, 0..3] of Int64;   // rule: none, Studio light, all library light
  LCatOf, LImpl: TArray<Integer>;
  LMid, LC, LI, LMode, LU, LTo: Integer;
  LM: TPasSemaModel;
  LSeen: TArray<Boolean>;
  LQueue: TList<Integer>;
  LLight: Boolean;
begin
  FillChar(LUnits, SizeOf(LUnits), 0);
  FillChar(LTok, SizeOf(LTok), 0);
  FillChar(LTokIntf, SizeOf(LTokIntf), 0);
  FillChar(LNodes, SizeOf(LNodes), 0);
  FillChar(LNodesIntf, SizeOf(LNodesIntf), 0);
  FillChar(LChars, SizeOf(LChars), 0);
  FillChar(LReach, SizeOf(LReach), 0);
  SetLength(LCatOf, GProj.ModelCount);
  SetLength(LImpl, GProj.ModelCount);
  for LMid := 0 to GProj.ModelCount - 1 do
  begin
    LM := GProj.Model(LMid);
    LC := UnitCat(GProj.ModelFile(LMid));
    LCatOf[LMid] := LC;
    LImpl[LMid] := ImplSecNode(LM);
    Inc(LUnits[LC]);
    Inc(LTok[LC], Length(LM.Tree.Source.Visible));
    Inc(LNodes[LC], Length(LM.Tree.Nodes));
    if LImpl[LMid] >= 0 then
    begin
      Inc(LTokIntf[LC], LM.Tree.Nodes[LImpl[LMid]].FirstToken);
      Inc(LNodesIntf[LC], LImpl[LMid]);
    end
    else
    begin
      Inc(LTokIntf[LC], Length(LM.Tree.Source.Visible));
      Inc(LNodesIntf[LC], Length(LM.Tree.Nodes));
    end;
    for LI := 0 to High(LM.Tree.Source.Files) do
      Inc(LChars[LC], Length(LM.Tree.Source.Files[LI].Source));
  end;
  Writeln(ErrOutput, '--- stats: per category ---');
  Writeln(ErrOutput, Format('  %-13s %6s %12s %12s %6s %12s %12s %6s %9s',
    ['category', 'units', 'tokens', 'intf tokens', 'intf%', 'nodes',
     'intf nodes', 'intf%', 'MB text']));
  for LC := 0 to 3 do
    Writeln(ErrOutput, Format('  %-13s %6d %12d %12d %5.1f%% %12d %12d %5.1f%% %9.1f',
      [CAT_NAMES[LC], LUnits[LC], LTok[LC], LTokIntf[LC],
       100 * LTokIntf[LC] / Max(1, LTok[LC]), LNodes[LC], LNodesIntf[LC],
       100 * LNodesIntf[LC] / Max(1, LNodes[LC]),
       LChars[LC] * 2 / (1024 * 1024)]));

  // A directory run has no library and no main source to walk from.
  if GAllOwn then
    Exit;
  // Closure: from the main source, System and SysInit; a light unit's
  // implementation `uses` are not followed.
  LQueue := TList<Integer>.Create;
  try
    for LMode := 0 to 2 do
    begin
      SetLength(LSeen, 0);
      SetLength(LSeen, GProj.ModelCount);
      LQueue.Clear;
      for LMid := 0 to GProj.ModelCount - 1 do
        if SameText(GProj.ModelFile(LMid), AMain) or
           SameText(TPath.GetFileName(GProj.ModelFile(LMid)), 'System.pas') or
           SameText(TPath.GetFileName(GProj.ModelFile(LMid)), 'SysInit.pas') then
        begin
          LSeen[LMid] := True;
          LQueue.Add(LMid);
        end;
      LI := 0;
      while LI < LQueue.Count do
      begin
        LMid := LQueue[LI];
        Inc(LI);
        LM := GProj.Model(LMid);
        case LMode of
          1: LLight := LCatOf[LMid] = 2;
          2: LLight := LCatOf[LMid] >= 2;
        else
          LLight := False;
        end;
        for LU := 0 to High(LM.UsesList) do
        begin
          LTo := LM.UsesList[LU].UnitId;
          if (LTo < 0) or (LTo >= GProj.ModelCount) or LSeen[LTo] then
            Continue;
          if LLight and (LImpl[LMid] >= 0) and
             (LM.UsesList[LU].NameNode > LImpl[LMid]) then
            Continue;   // an implementation `uses` of a light unit
          LSeen[LTo] := True;
          LQueue.Add(LTo);
        end;
      end;
      for LMid := 0 to GProj.ModelCount - 1 do
        if LSeen[LMid] then
          Inc(LReach[LMode, LCatOf[LMid]]);
    end;
  finally
    LQueue.Free;
  end;
  Writeln(ErrOutput, '--- stats: closure each light rule would load ---');
  Writeln(ErrOutput, Format('  %-13s %8s %14s %15s',
    ['category', 'full', 'studio-light', 'library-light']));
  for LC := 0 to 3 do
    Writeln(ErrOutput, Format('  %-13s %8d %14d %15d',
      [CAT_NAMES[LC], LReach[0, LC], LReach[1, LC], LReach[2, LC]]));

  // References FROM library code TO own declarations - what light mode loses
  // outright (the virtual/interface dispatch it loses is not counted here).
  var LLibToOwn: array[0..1] of Integer;   // [in a library interface, in a body]
  var LLibUnits := TDictionary<Integer, Boolean>.Create;
  var LByTarget := TDictionary<Integer, Integer>.Create;   // own model -> refs
  try
    LLibToOwn[0] := 0;
    LLibToOwn[1] := 0;
    for LMid := 0 to GProj.ModelCount - 1 do
    begin
      if LCatOf[LMid] < 2 then
        Continue;
      LM := GProj.Model(LMid);
      for var LP in LM.ExtRefMap do
        if (LP.Value.UnitId >= 0) and (LP.Value.UnitId < GProj.ModelCount) and
           (LCatOf[LP.Value.UnitId] < 2) then
        begin
          if (LImpl[LMid] >= 0) and (LP.Key > LImpl[LMid]) then
            Inc(LLibToOwn[1])
          else
            Inc(LLibToOwn[0]);
          LLibUnits.AddOrSetValue(LMid, True);
          var LN := 0;
          LByTarget.TryGetValue(LP.Value.UnitId, LN);
          LByTarget.AddOrSetValue(LP.Value.UnitId, LN + 1);
        end;
    end;
    Writeln(ErrOutput, Format('--- stats: library -> own references: ' +
      '%d in library interfaces, %d in library bodies; %d library unit(s) ' +
      'refer to %d own unit(s)',
      [LLibToOwn[0], LLibToOwn[1], LLibUnits.Count, LByTarget.Count]));
    var LRows := TList<string>.Create;
    try
      // Most-referenced first; the count is zero-padded so a text sort orders it.
      for var LT in LByTarget do
        LRows.Add(Format('%.8d|%s|%s', [MaxInt - LT.Value, CAT_NAMES[LCatOf[LT.Key]],
          GProj.ModelFile(LT.Key)]));
      LRows.Sort;
      for var LR in LRows do
      begin
        var LParts := LR.Split(['|']);
        Writeln(ErrOutput, Format('  %6d to [%s] %s',
          [MaxInt - StrToInt(LParts[0]), LParts[1], LParts[2]]));
      end;
    finally
      LRows.Free;
    end;
  finally
    LByTarget.Free;
    LLibUnits.Free;
  end;
end;

// The fingerprint hashes wrap by design; the tool is also built with -$Q+.
{$IFOPT Q+}{$DEFINE FP_Q_WAS_ON}{$Q-}{$ENDIF}
function Fnv64(const S: string): UInt64;
var
  LI: Integer;
begin
  Result := UInt64($CBF29CE484222325);
  for LI := 1 to Length(S) do
    Result := (Result xor Ord(S[LI])) * UInt64($100000001B3);
end;

function HashSum(A, B: UInt64): UInt64;
begin
  Result := A + B;
end;
{$IFDEF FP_Q_WAS_ON}{$Q+}{$UNDEF FP_Q_WAS_ON}{$ENDIF}

// -fp: per own model, an order-independent hash of every binding the
// analysis made in it - local refs, expression types, external refs, call
// targets, cross-model types, diagnostics - with a target named by its file,
// symbol name and declaring node, never by model id (ids differ between two
// closures), so a full and a light analysis compare. One line per model:
// the file, then count:hash for each family in that order.
procedure ReportFingerprint(const AOutFile: string; ADetail: Boolean);
var
  LLines, LDet: TList<string>;
  LMid, LI: Integer;
  LM: TPasSemaModel;
  LH: array[0..6] of UInt64;
  LN: array[0..6] of Integer;
  LS: string;

  function MF(AUnit: Integer): string;
  begin
    if (AUnit >= 0) and (AUnit < GProj.ModelCount) then
      Result := LowerCase(GProj.ModelFile(AUnit))
    else
      Result := '?' + IntToStr(AUnit);
  end;

  // A target symbol by what it IS - file, name, declaring node - not by its
  // index in that model's arena.
  function TS(AUnit, ASym: Integer): string;
  var
    LTM: TPasSemaModel;
  begin
    Result := MF(AUnit);
    if (AUnit >= 0) and (AUnit < GProj.ModelCount) then
    begin
      LTM := GProj.Model(AUnit);
      if (ASym >= 0) and (ASym < LTM.SymCount) then
        Result := Result + ':' + LTM.Symbols[ASym].Name + ':' +
          IntToStr(LTM.Symbols[ASym].DeclNode)
      else
        Result := Result + ':#' + IntToStr(ASym);
    end;
  end;

  procedure Put(AFam: Integer; const AEntry: string);
  begin
    LH[AFam] := HashSum(LH[AFam], Fnv64(AEntry));
    Inc(LN[AFam]);
    if ADetail then
      LDet.Add(LowerCase(GProj.ModelFile(LMid)) + '|' + AEntry);
  end;

begin
  LLines := TList<string>.Create;
  LDet := TList<string>.Create;
  try
    for LMid := 0 to GProj.ModelCount - 1 do
    begin
      if UnitCat(GProj.ModelFile(LMid)) > 1 then
        Continue;
      LM := GProj.Model(LMid);
      FillChar(LH, SizeOf(LH), 0);
      FillChar(LN, SizeOf(LN), 0);
      for LI := 0 to High(LM.RefMap) do
        if LM.RefMap[LI] <> NIL_SYM then
          Put(0, Format('L %d %s', [LI, TS(LMid, LM.RefMap[LI])]));
      for LI := 0 to High(LM.ExprType) do
        if LM.ExprType[LI] <> NIL_SYM then
          Put(1, Format('T %d %s', [LI, TS(LMid, LM.ExprType[LI])]));
      for var LP in LM.ExtRefMap do
        Put(2, Format('X %d %s', [LP.Key, TS(LP.Value.UnitId, LP.Value.Sym)]));
      for var LP in LM.CallTargetX do
        Put(3, Format('CX %d %s', [LP.Key, TS(LP.Value.UnitId, LP.Value.Sym)]));
      for var LP in LM.SymTypeX do
        Put(4, Format('ST %d %s %s', [LP.Key, TS(LP.Value.UnitId, LP.Value.Sym),
          IfThen(LP.Value.Inst = NIL_INST, '-', 'I')]));
      for var LP in LM.ExprTypeX do
        Put(5, Format('ET %d %s %s', [LP.Key, TS(LP.Value.UnitId, LP.Value.Sym),
          IfThen(LP.Value.Inst = NIL_INST, '-', 'I')]));
      for LI := 0 to High(LM.Diags) do
        Put(6, Format('D %d %d %d %s %s', [LM.Diags[LI].FileId, LM.Diags[LI].Line,
          LM.Diags[LI].Col, LM.Diags[LI].Code, LM.Diags[LI].Msg]));
      LS := LowerCase(GProj.ModelFile(LMid));
      for LI := 0 to 6 do
        LS := LS + Format(' %d:%x', [LN[LI], LH[LI]]);
      LLines.Add(LS);
    end;
    LLines.Sort;
    TFile.WriteAllLines(AOutFile, LLines.ToArray);
    if ADetail then
    begin
      LDet.Sort;
      TFile.WriteAllLines(ChangeFileExt(AOutFile, '.detail.txt'), LDet.ToArray);
    end;
    Writeln(ErrOutput, Format('fingerprint: %d own model(s) -> %s',
      [LLines.Count, AOutFile]));
  finally
    LDet.Free;
    LLines.Free;
  end;
end;

// -refset: Find References on a symbol of AUnit with library bodies light -
// which units' bodies could hold a use. D: the units naming AUnit in a
// `uses` (either section) and AUnit itself, every unit for System - the
// candidates for a unit-level name. I: AUnit and every unit whose INTERFACE
// `uses` reaches it through interface `uses` only. M: I plus every unit with
// any `uses` edge into I - the candidates for a member, which a value of a
// type leading there reaches without naming AUnit.
procedure ReportRefSet(const AUnit: string);
var
  LTarget, LMid, LU, LTo, LI, LC: Integer;
  LM: TPasSemaModel;
  LImpl, LCatOf: TArray<Integer>;
  LInD, LInI, LInM: TArray<Boolean>;
  LRev: TArray<TList<Integer>>;   // interface edges, reversed: to -> froms
  LQueue: TList<Integer>;
  LCntD, LCntM: array[0..3] of Integer;
  LNodesD, LNodesM: array[0..3] of Int64;
  LIsSystem: Boolean;
begin
  LTarget := -1;
  for LMid := 0 to GProj.ModelCount - 1 do
    if SameText(GProj.Model(LMid).UnitNameLower, AUnit) then
    begin
      LTarget := LMid;
      Break;
    end;
  if LTarget < 0 then
  begin
    Writeln(ErrOutput, '  refset: no unit ', AUnit);
    Exit;
  end;
  LIsSystem := SameText(AUnit, 'system');
  SetLength(LImpl, GProj.ModelCount);
  SetLength(LCatOf, GProj.ModelCount);
  SetLength(LInD, GProj.ModelCount);
  SetLength(LInI, GProj.ModelCount);
  SetLength(LInM, GProj.ModelCount);
  SetLength(LRev, GProj.ModelCount);
  for LMid := 0 to GProj.ModelCount - 1 do
  begin
    LImpl[LMid] := ImplSecNode(GProj.Model(LMid));
    LCatOf[LMid] := UnitCat(GProj.ModelFile(LMid));
    LRev[LMid] := TList<Integer>.Create;
  end;
  LQueue := TList<Integer>.Create;
  try
    for LMid := 0 to GProj.ModelCount - 1 do
    begin
      LM := GProj.Model(LMid);
      for LU := 0 to High(LM.UsesList) do
      begin
        LTo := LM.UsesList[LU].UnitId;
        if (LTo < 0) or (LTo >= GProj.ModelCount) then
          Continue;
        if LTo = LTarget then
          LInD[LMid] := True;
        if (LImpl[LMid] < 0) or (LM.UsesList[LU].NameNode < LImpl[LMid]) then
          LRev[LTo].Add(LMid);
      end;
    end;
    LInD[LTarget] := True;
    if LIsSystem then
      for LMid := 0 to GProj.ModelCount - 1 do
        LInD[LMid] := True;
    LInI[LTarget] := True;
    LQueue.Add(LTarget);
    LI := 0;
    while LI < LQueue.Count do
    begin
      for LTo in LRev[LQueue[LI]] do
        if not LInI[LTo] then
        begin
          LInI[LTo] := True;
          LQueue.Add(LTo);
        end;
      Inc(LI);
    end;
    if LIsSystem then
      for LMid := 0 to GProj.ModelCount - 1 do
        LInI[LMid] := True;
    for LMid := 0 to GProj.ModelCount - 1 do
    begin
      if LInI[LMid] then
      begin
        LInM[LMid] := True;
        Continue;
      end;
      LM := GProj.Model(LMid);
      for LU := 0 to High(LM.UsesList) do
      begin
        LTo := LM.UsesList[LU].UnitId;
        if (LTo >= 0) and (LTo < GProj.ModelCount) and LInI[LTo] then
        begin
          LInM[LMid] := True;
          Break;
        end;
      end;
    end;
    FillChar(LCntD, SizeOf(LCntD), 0);
    FillChar(LCntM, SizeOf(LCntM), 0);
    FillChar(LNodesD, SizeOf(LNodesD), 0);
    FillChar(LNodesM, SizeOf(LNodesM), 0);
    for LMid := 0 to GProj.ModelCount - 1 do
    begin
      LC := LCatOf[LMid];
      if LInD[LMid] then
      begin
        Inc(LCntD[LC]);
        Inc(LNodesD[LC], Length(GProj.Model(LMid).Tree.Nodes));
      end;
      if LInM[LMid] then
      begin
        Inc(LCntM[LC]);
        Inc(LNodesM[LC], Length(GProj.Model(LMid).Tree.Nodes));
      end;
    end;
    Writeln(ErrOutput, Format('  refset %s:', [AUnit]));
    Writeln(ErrOutput, Format('    %-17s %-13s %6s %10s',
      ['set', 'category', 'units', 'nodes']));
    for LC := 0 to 3 do
      Writeln(ErrOutput, Format('    %-17s %-13s %6d %10d',
        ['unit-level (D)', CAT_NAMES[LC], LCntD[LC], LNodesD[LC]]));
    for LC := 0 to 3 do
      Writeln(ErrOutput, Format('    %-17s %-13s %6d %10d',
        ['member (M)', CAT_NAMES[LC], LCntM[LC], LNodesM[LC]]));
  finally
    LQueue.Free;
    for LMid := 0 to High(LRev) do
      LRev[LMid].Free;
  end;
end;

// -promote: AnalyzeModuleOnly over one file, timed, and what the module holds
// after - the stand-in for promoting a light unit to a full parse until the
// API for it exists.
procedure ReportPromote(const AFile: string);
var
  LBefore, LMid, LImpl, LBodyRefs, LI: Integer;
  LOk: Boolean;
  LM: TPasSemaModel;
  LSW: TStopwatch;
begin
  LBefore := GProj.ModelCount;
  LSW := TStopwatch.StartNew;
  LOk := GProj.AnalyzeModuleOnly(AFile);
  LSW.Stop;
  Writeln(ErrOutput, Format('  promote %s: %s in %d ms',
    [TPath.GetFileName(AFile), BoolToStr(LOk, True), LSW.ElapsedMilliseconds]));
  if GProj.StageTimings <> '' then
    Writeln(ErrOutput, '    stages: ', GProj.StageTimings);
  LMid := GProj.ModelIdOf(AFile);
  if LMid < 0 then
  begin
    Writeln(ErrOutput, '    no model for the file');
    Exit;
  end;
  LM := GProj.Model(LMid);
  LImpl := ImplSecNode(LM);
  LBodyRefs := 0;
  if LImpl >= 0 then
  begin
    for LI := LImpl + 1 to High(LM.RefMap) do
      if LM.RefMap[LI] <> NIL_SYM then
        Inc(LBodyRefs);
    for var LP in LM.ExtRefMap do
      if LP.Key > LImpl then
        Inc(LBodyRefs);
  end;
  Writeln(ErrOutput, Format('    after: implementation section %s, %d body ' +
    'ref(s), %d diagnostic(s), %d unit(s) added',
    [IfThen(LImpl >= 0, 'yes', 'no'), LBodyRefs, Length(LM.Diags),
     GProj.ModelCount - LBefore]));
end;

// -demotelib: the MCP server's resident state - DemoteText keeping the own
// units (listed or under the project directory) warm.
procedure ReportDemoteLib;
var
  LKeep: TArray<string>;
  LSW: TStopwatch;
begin
  LKeep := nil;
  for var LMid := 0 to GProj.ModelCount - 1 do
    if UnitCat(GProj.ModelFile(LMid)) <= 1 then
      LKeep := LKeep + [GProj.ModelFile(LMid)];
  LSW := TStopwatch.StartNew;
  GProj.DemoteText(LKeep);
  LSW.Stop;
  Writeln(ErrOutput, Format(
    'after DemoteText (keeping %d own units): %s held, %d ms',
    [Length(LKeep), MemoryText(AllocatedBytes), LSW.ElapsedMilliseconds]));
end;

// After the analysis, before the -release/-demote measurements.
procedure ReportLightMeasures(const AMain: string);
begin
  if GStats then
    ReportLightStats(AMain);
  if GFp <> '' then
    ReportFingerprint(GFp, GFpDetail);
  for var LRS in GRefSets do
    ReportRefSet(LRS);
  for var LPF in GPromotes do
    ReportPromote(LPF);
end;

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
    // Without -p: the project's own platform, its `'$(Platform)'==''`
    // fallback (audit B4-43).
    var LPlatArg := '';
    if GPlatformGiven then
      LPlatArg := PlatformName(GPlatform);
    if not LD.Load(APath, LPlatArg) then
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
        '  NB no Studio root (BDS unset, no -studio:) - RTL/VCL/FMX will not resolve');

    GProj := TPasSemaProject.Create(LD.Platform, LPaths, LD.Defines);
    try
      GProj.SingleThreaded := GSingle;
      GProj.ReportUnresolvedMembers := GMembers;
      GProj.ReportVisibility := GVisibility;
      GProj.ReportGuessedIfs := GIfs;
      // The .dproj's DCC_* switches and console target, as msbuild hands them
      // to dcc - and a command-line -$X / -CC on top, as dcc would take it.
      GProj.SwitchStart := PasStartOptState(LD.Switches + GSwitches);
      GProj.ConsoleTarget := LD.ConsoleTarget or GConsole;
      if Length(LD.Switches) > 0 then
        Writeln(ErrOutput, '    switches: ', string.Join(' ', LD.Switches));
      // No -NS list in the .dproj means we could not read the option, not that
      // the project wants zero prefixes - dcc has none built in, so zero would
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
      if GDefines then
        ReportDefines(LD.MainSource);

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
        // the compiler would have compiled is simply absent here - so the unit
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
            // a handful of them - so "one site per name" would hide all but
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
            // Library diagnostics are counted, not listed - but a bare count
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
      GOwnFiles := LOwn;
      GOwnDir := LD.Dir;
      ReportLightMeasures(LD.MainSource);
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
        if GRehydrate then
        begin
          var LFail := 0;
          for var LRIdx := 0 to GProj.ModelCount - 1 do
            if not GProj.EnsureHydrated(LRIdx) then
            begin
              Inc(LFail);
              Writeln(ErrOutput, '    rehydrate FAILED: ' +
                GProj.ModelFile(LRIdx));
            end;
          Writeln(ErrOutput, Format(
            '  rehydrate: %d of %d model(s) FAILED; %s held',
            [LFail, GProj.ModelCount, MemoryText(AllocatedBytes)]));
        end;
      end;
      if GOutline then
      begin
        // The Go To project tab, headless: the .dproj's files that have a
        // model, ProjectOutline over them (after -release/-demote when
        // given - the demo's state), the count and the first rows.
        var LONav := TPasNavigator.Create(GProj);
        try
          var LOMids: TArray<Integer> := nil;
          var LOMiss := 0;
          for var LOF in LD.Files do
          begin
            var LOMid := LONav.ModelIdOf(LOF);
            if LOMid >= 0 then
              LOMids := LOMids + [LOMid]
            else
              Inc(LOMiss);
          end;
          var LORows := LONav.ProjectOutline(LOMids);
          Writeln(ErrOutput, Format(
            '  outline: %d dproj file(s), %d with a model, %d without; %d row(s)',
            [Length(LD.Files), Length(LOMids), LOMiss, Length(LORows)]));
          for var LOI := 0 to Min(High(LORows), 7) do
            Writeln(ErrOutput, Format('    %s %s%s  [%s]', [LORows[LOI].Head,
              LORows[LOI].Owner + IfThen(LORows[LOI].Owner <> '', '.', ''),
              LORows[LOI].Name, LORows[LOI].UnitName]));
        finally
          LONav.Free;
        end;
      end;
      if GUnused then
      begin
        // Find All > Unused Units in the Project, headless: the .dproj's
        // files that have a model, every row with its doubts.
        var LUMids: TArray<Integer> := nil;
        for var LUF in LD.Files do
          if GProj.ModelIdOf(LUF) >= 0 then
            LUMids := LUMids + [GProj.ModelIdOf(LUF)];
        var LUNav := TPasNavigator.Create(GProj);
        var LURows: TArray<TPasUnusedUse>;
        var LUUnits: TArray<TPasUnreferencedUnit>;
        try
          LURows := FindUnusedUses(LUNav, LUMids);
          LUUnits := FindUnreferencedUnits(LUNav, LUMids);
        finally
          LUNav.Free;
        end;
        Writeln(ErrOutput, Format('  unreferenced: %d unit(s)',
          [Length(LUUnits)]));
        for var LUU in LUUnits do
          Writeln(ErrOutput, Format('    %s <- %s%s', [LUU.Hit.FilePath,
            string.Join(', ', LUU.ListedBy), IfThen(LUU.Doubts <> nil,
            '; but ' + string.Join('; ', LUU.Doubts), '')]));
        Writeln(ErrOutput, Format('  unused: %d `uses` entries in %d unit(s)',
          [Length(LURows), Length(LUMids)]));
        for var LUR in LURows do
          Writeln(ErrOutput, Format('    %s:%d:%d %s%s', [LUR.Hit.FilePath,
            LUR.Hit.Line, LUR.Hit.Col, LUR.UnitName, IfThen(LUR.Doubts <> nil,
            '; but ' + string.Join('; ', LUR.Doubts), '')]));
      end;
      if LTotalLines > 0 then
        Writeln(ErrOutput, Format(
          '  source: %s lines, %.1f MB, %s file(s) - %s lines/s',
          [FormatFloat('#,##0', LTotalLines), LTotalChars / (1024 * 1024),
           FormatFloat('#,##0', LTotalFiles),
           FormatFloat('#,##0', LTotalLines * 1000 /
             Max(1, GSW.ElapsedMilliseconds))]));
      Writeln(ErrOutput, Format(
        'closure: %d unresolved `uses` name(s); %d of %d unit(s) have E2003 '
        + 'GATED because of them',
        [LUnresUses, LUnitsGated, GProj.ModelCount]));
      Writeln(ErrOutput, Format(
        'diagnostics: %d total - %d in project files, %d in library units',
        [LListed + LOther, LListed, LOther]));
      ReportLoadFailures;
      ReportHistogram('--- unresolvable `uses` names, by import count ---',
        LMissing, 25, LSites);
      ReportHistogram('--- project files, by identifier/code ---', LInProj, 25);
      ReportHistogram('--- library units, by identifier/code ---', LOutProj, 25,
        LLibSites);
      ReportChains;
      if GDemoteLib then
        ReportDemoteLib;
    finally
      GOwnFiles := nil;
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
    GPlatformGiven := False;
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
      else if ParamStr(GIdx).StartsWith('-overrides:', True) then
        GOverrideQueries := GOverrideQueries +
          [Copy(ParamStr(GIdx), 12, MaxInt)]
      else if ParamStr(GIdx).StartsWith('-impls:', True) then
        GImplQueries := GImplQueries + [Copy(ParamStr(GIdx), 8, MaxInt)]
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
      else if SameText(ParamStr(GIdx), '-rehydrate') then
        GRehydrate := True
      else if SameText(ParamStr(GIdx), '-outline') then
        GOutline := True
      else if SameText(ParamStr(GIdx), '-unused') then
        GUnused := True
      else if SameText(ParamStr(GIdx), '-defines') then
        GDefines := True
      else if SameText(ParamStr(GIdx), '-stats') then
        GStats := True
      else if SameText(ParamStr(GIdx), '-demotelib') then
        GDemoteLib := True
      else if SameText(ParamStr(GIdx), '-fpdetail') then
        GFpDetail := True
      else if ParamStr(GIdx).StartsWith('-fp:', True) then
        GFp := TPath.GetFullPath(Copy(ParamStr(GIdx), 5, MaxInt))
      else if ParamStr(GIdx).StartsWith('-refset:', True) then
        GRefSets := GRefSets + [Copy(ParamStr(GIdx), 9, MaxInt)]
      else if ParamStr(GIdx).StartsWith('-promote:', True) then
        GPromotes := GPromotes +
          [TPath.GetFullPath(Copy(ParamStr(GIdx), 10, MaxInt))]
      else if ParamStr(GIdx).StartsWith('-$') then
        GSwitches := GSwitches + [ParamStr(GIdx)]
      else if SameText(ParamStr(GIdx), '-CC') then
        GConsole := True
      else if ParamStr(GIdx).StartsWith('-p:', True) then
        GPlatformGiven :=
          TryParsePlatformName(Copy(ParamStr(GIdx), 4, MaxInt), GPlatform)
      else if ParamStr(GIdx).StartsWith('-studio:', True) then
        GStudio := Copy(ParamStr(GIdx), 9, MaxInt)
      // -L<dir>: one extra search path, repeatable. The demo folds in the IDE's
      // registry Library/Browsing paths, which is where a real project's
      // third-party components live (large component suites). This is how a
      // headless run reaches the same closure without teaching the tool to read
      // the registry - and the closure line in the report is the check that it
      // did: a short unit count means paths are still missing, and a missing
      // unit GATES its importers' diagnostics rather than reporting them.
      else if ParamStr(GIdx).StartsWith('-L', True) and
              (Length(ParamStr(GIdx)) > 2) then
        GExtraPaths := GExtraPaths + [Copy(ParamStr(GIdx), 3, MaxInt)]
      // Through ConfigureThreadPool, not SetMaxWorkerThreads directly: the
      // project's constructor pins the pool (Min first, then Max) and ignores
      // a bare SetMaxWorkerThreads made before it - the flag silently did
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
      GProj.SwitchStart := PasStartOptState(GSwitches);
      GProj.ConsoleTarget := GConsole;
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
      ReportChains;
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
      ReportLoadFailures;
      // A directory is the whole world: every unit is own. A file run has
      // no list - own is what lies under the file's directory.
      GAllOwn := TDirectory.Exists(GPath);
      if not GAllOwn then
        GOwnDir := TPath.GetDirectoryName(GPath);
      ReportLightMeasures(GPath);
      if GDemoteLib then
        ReportDemoteLib;
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
        if GRehydrate then
        begin
          var LFail := 0;
          for var LRIdx := 0 to GProj.ModelCount - 1 do
            if not GProj.EnsureHydrated(LRIdx) then
              Inc(LFail);
          Writeln(ErrOutput, Format(
            'rehydrate: %d of %d model(s) FAILED; %s held',
            [LFail, GProj.ModelCount, MemoryText(AllocatedBytes)]));
        end;
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
