program PasTreeLightSmoke;

{ The light-mode query equivalence oracle - gate G7 of light mode
  (docs/library-light-mode.md, "Full answers in light mode").

  Analyzes one project twice in the same process - full, and light (the
  library trees interface-only) - and asks both the SAME questions: every
  public query of TPasNavigator and PasTree.Sema.Lint, over a sample of
  symbols, units, names and positions. The light side first meets each
  question's DEMAND (TPasNavigator.Demand*, PasTree.Sema.Lint.DemandLint)
  the way a host does - PasEnsureDemand, a rebuild with the project as
  parse donor when EnsureFull asks for one; when it escalates, the host's
  rebuild without light paths is the full side itself, which answers - and
  then asks. Answers are compared by IDENTITY - file, line, column, kind,
  name - never by model id (the two closures number
  their models differently). A family whose demand is wired must answer
  exactly what the full analysis answers, with NotSearched = 0; a family not
  wired yet is reported as an expected difference with its counts, never
  hidden.

  PasTreeLightSmoke <project.dproj> [options]
    -p:<platform>        the platform (default: the .dproj's)
    -studio:<dir>        the Studio root (default: $(BDS))
    -L<dir>              a library path (repeatable)
    -Lfile:<file>        library paths, one per line
    -light:<spec>        the light trees: lib (default) = every -L path plus
                         the Studio source trees; studio; or a directory
    -own:<n>             every n-th symbol of the project's own units (1)
    -ownunits:<n>        every n-th own unit for the unit and position
                         queries (1)
    -pos:<n>             every n-th identifier of an own unit's text for the
                         position queries (40; 0 = none)
    -libpos:<n>          the same in the library sample's own files (100)
    -sym:<Unit.Name>     a library symbol (repeatable; Unit.Type.Member for
                         a member); the default sample is used when none
    -nolib               no library sample
    -shared              the library sample on one light project (default:
                         a fresh light project per library symbol, so each
                         question's cost is its own)
    -escalate:<pct>      TPasSemaProject.EscalationPercent (default 40)
    -family:<name>       only this family (repeatable)
    -v                   every difference, not the first few per family

  Exit code 0 when every wired family is equal with NotSearched = 0,
  1 otherwise, 2 on a usage or load error. }

{$APPTYPE CONSOLE}
{$MAXSTACKSIZE $01000000}   // 16 MB per thread: README, "The stack every host should reserve"

uses
  System.SysUtils,
  System.StrUtils,
  System.Math,
  System.Classes,
  System.Diagnostics,
  System.IOUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.Project in '..\source\PasTree.Project.pas',
  PasTree.DProj in '..\source\PasTree.DProj.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Outline in '..\source\PasTree.Outline.pas',
  PasTree.WordIndex in '..\source\PasTree.WordIndex.pas',
  PasTree.Sema.Model in '..\source\PasTree.Sema.Model.pas',
  PasTree.Sema.Project in '..\source\PasTree.Sema.Project.pas',
  PasTree.Sema.Nav in '..\source\PasTree.Sema.Nav.pas',
  PasTree.Sema.Lint in '..\source\PasTree.Sema.Lint.pas';

type
  { A declaration, by what both analyses agree on. }
  TSymId = record
    MainFile: string;    // the declaring model's file
    DeclFile: string;    // where the name is written (an include, maybe)
    Name: string;
    Line, Col: Integer;
    Text: string;        // for the report
  end;

  TQueryFn = reference to function(ANav: TPasNavigator): TArray<string>;

  TFamilyStat = record
    Name: string;
    Wired: Boolean;
    Queries, Equal, Diff, NotSearchedBad, FullRows, LightRows: Integer;
    Samples: TArray<string>;
    // What meeting the family's demands cost the light side: the questions
    // whose demand did something (Worked), and its sums.
    Worked, Rounds, Promoted, Loaded, Preprocessed, Rebuilds,
      Escalations: Integer;
    EnsureMs, MaxMs: Int64;
  end;

  TCostRow = record
    Text: string;
    Rounds, Promoted, Loaded, Preprocessed, Rebuilds, Escalations: Integer;
    Ms: Int64;
    Refused: Integer;
  end;

var
  GDProj: TPasDProj;
  GPaths, GExtraPaths, GLightSpecs, GOnlyFamilies, GSymArgs: TArray<string>;
  GStudio: string;
  GPlatform: TPasPlatform;
  GPlatformGiven: Boolean;
  GFull, GLight: TPasSemaProject;
  GFullNav, GLightNav: TPasNavigator;
  GOwnStride, GOwnUnitStride, GPosStride, GLibPosStride, GEscalate: Integer;
  GNoLib, GShared, GVerbose: Boolean;
  GStats: TDictionary<string, TFamilyStat>;
  GFamilyOrder: TList<string>;
  GCosts: TList<TCostRow>;
  GCur: TCostRow;            // the cost of the question being asked
  GLightRuns: Integer;       // light analyses run (the first one included)
  GWordMs: Int64;            // the first demand's cost: the word index
  GWordBytes: Int64;
  GEscalatedQ: Boolean;     // the current question escalated: see EnsureLight
  GResets: Integer;         // light projects started again after an escalation

{ ---- configuration -------------------------------------------------------- }

function StudioSearchPaths(const ARoot: string): TArray<string>;
const
  SUBS: array[0..8] of string = ('source\rtl\sys', 'source\rtl\common',
    'source\rtl\win', 'source\rtl\win\winrt', 'source\rtl\net',
    'source\databinding\engine', 'source\xml', 'source\vcl', 'source\fmx');
begin
  Result := nil;
  if ARoot = '' then
    Exit;
  for var LSub in SUBS do
    if TDirectory.Exists(TPath.Combine(ARoot, LSub)) then
      Result := Result + [TPath.Combine(ARoot, LSub)];
end;

function LightTrees: TArray<string>;
begin
  Result := nil;
  for var LSpec in GLightSpecs do
    if SameText(LSpec, 'lib') then
      Result := Result + GExtraPaths + StudioSearchPaths(GStudio)
    else if SameText(LSpec, 'studio') then
      Result := Result + StudioSearchPaths(GStudio)
    else
      Result := Result + [LSpec];
end;

{ The run's project, configured as PasTreeSemaProject's -dproj driver does,
  analyzed. ADonor: the parse donor (its promotions are forgotten unless
  AKeepPromoted - a rebuild a promotion asked for keeps them). }
function NewProject(ALight: Boolean; ADonor: TPasSemaProject;
  AKeepPromoted: Boolean): TPasSemaProject;
begin
  Result := TPasSemaProject.Create(GDProj.Platform, GPaths, GDProj.Defines);
  try
    Result.SwitchStart := PasStartOptState(GDProj.Switches);
    Result.ConsoleTarget := GDProj.ConsoleTarget;
    if Length(GDProj.Namespaces) > 0 then
      Result.SetNamespaces(GDProj.Namespaces)
    else
      Result.SetNamespaces(PasDefaultNamespaces(GDProj.Platform));
    for var LDef in PasDefaultUnitAliases(GDProj.Platform) do
      Result.AddUnitAlias(LDef.Alias, LDef.UnitName);
    for var LA in GDProj.UnitAliases do
      Result.AddUnitAlias(LA.Alias, LA.UnitName);
    if ALight then
      Result.LightPaths := LightTrees;
    Result.EscalationPercent := GEscalate;
    if ADonor <> nil then
    begin
      Result.AdoptParseDonor(ADonor);
      if not AKeepPromoted then
        Result.ForgetPromotions;
    end;
    Result.AnalyzeStaged([GDProj.MainSource], []);
    if ALight then
      Inc(GLightRuns);
  except
    Result.Free;
    raise;
  end;
end;

procedure ReplaceLight(ANew: TPasSemaProject);
var
  LLib: TArray<string>;
begin
  LLib := GLightNav.LibraryPaths;
  FreeAndNil(GLightNav);
  GLight.Free;
  GLight := ANew;
  GLightNav := TPasNavigator.Create(GLight);
  GLightNav.LibraryPaths := LLib;
end;

{ ---- identities ----------------------------------------------------------- }

function SymIdOf(AProj: TPasSemaProject; AMid, ASym: Integer;
  out AId: TSymId): Boolean;
var
  LM: TPasSemaModel;
begin
  AId := Default(TSymId);
  Result := False;
  if (AMid < 0) or (AMid >= AProj.ModelCount) then
    Exit;
  LM := AProj.Model(AMid);
  if (ASym < 0) or (ASym >= LM.SymCount) or
     (LM.Symbols[ASym].DeclNode = NIL_NODE) then
    Exit;
  AId.MainFile := AProj.ModelFile(AMid);
  AId.Name := LM.Symbols[ASym].Name;
  if not AProj.NodeSite(AMid, LM.Symbols[ASym].DeclNode, AId.DeclFile,
    AId.Line, AId.Col) then
    Exit;
  AId.Text := Format('%s %s(%d,%d)', [AId.Name,
    TPath.GetFileName(AId.DeclFile), AId.Line, AId.Col]);
  Result := True;
end;

function SymKey(AProj: TPasSemaProject; AMid, ASym: Integer): string;
var
  LId: TSymId;
begin
  if SymIdOf(AProj, AMid, ASym, LId) then
    Result := Format('%s|%s|%d|%d', [LowerCase(LId.DeclFile), LId.Name,
      LId.Line, LId.Col])
  else if (AMid >= 0) and (AMid < AProj.ModelCount) and (ASym >= 0) and
          (ASym < AProj.Model(AMid).SymCount) then
    // A builtin: by name.
    Result := 'builtin|' + AProj.Model(AMid).Symbols[ASym].NameLower
  else
    Result := '-';
end;

{ The symbol AId names in AProj, by file, name and declaration site. }
function FindSym(AProj: TPasSemaProject; const AId: TSymId;
  out AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
  LFile: string;
  LLine, LCol: Integer;
begin
  Result := False;
  ASym := -1;
  AMid := AProj.ModelIdOf(AId.MainFile);
  if AMid < 0 then
    Exit;
  LM := AProj.Model(AMid);
  for var LS := 0 to LM.SymCount - 1 do
    if SameText(LM.Symbols[LS].Name, AId.Name) and
       (LM.Symbols[LS].DeclNode <> NIL_NODE) and
       AProj.NodeSite(AMid, LM.Symbols[LS].DeclNode, LFile, LLine, LCol) and
       (LLine = AId.Line) and (LCol = AId.Col) and SameText(LFile, AId.DeclFile) then
    begin
      ASym := LS;
      Exit(True);
    end;
end;

function UnitModel(AProj: TPasSemaProject; const AName: string): Integer;
begin
  for var LMid := 0 to AProj.ModelCount - 1 do
    if SameText(AProj.Model(LMid).UnitNameLower, AName) then
      Exit(LMid);
  Result := -1;
end;

{ Unit.Type, Unit.Type.Member or Unit.Name in AProj: its declaration. }
function ResolveQualified(AProj: TPasSemaProject; const AText: string;
  out AId: TSymId): Boolean;
var
  LParts: TArray<string>;
  LMid, LSym, LUnitLen, LType: Integer;
  LM: TPasSemaModel;
  LUnit: string;
begin
  Result := False;
  LParts := AText.Split(['.']);
  // The longest prefix that names a loaded unit (dotted unit names).
  LMid := -1;
  LUnitLen := 0;
  for var LN := Length(LParts) - 1 downto 1 do
  begin
    LUnit := string.Join('.', Copy(LParts, 0, LN));
    LMid := UnitModel(AProj, LUnit);
    if LMid >= 0 then
    begin
      LUnitLen := LN;
      Break;
    end;
  end;
  if LMid < 0 then
    Exit;
  LM := AProj.Model(LMid);
  LParts := Copy(LParts, LUnitLen, MaxInt);
  LSym := -1;
  // A unit-level name in the interface.
  for var LS := 0 to LM.SymCount - 1 do
    if SameText(LM.Symbols[LS].Name, LParts[0]) and
       (LM.Symbols[LS].DeclNode <> NIL_NODE) and
       (LM.Symbols[LS].Scope >= 0) and
       (LM.Scopes[LM.Symbols[LS].Scope].Kind = sckUnit) then
    begin
      LSym := LS;
      Break;
    end;
  if LSym < 0 then
    Exit;
  if Length(LParts) >= 2 then
  begin
    LType := LSym;
    LSym := -1;
    for var LS := 0 to LM.SymCount - 1 do
      if SameText(LM.Symbols[LS].Name, LParts[1]) and
         (LM.Symbols[LS].DeclNode <> NIL_NODE) and
         (LM.Symbols[LType].MemberScope <> NIL_SCOPE) and
         (LM.Symbols[LS].Scope = LM.Symbols[LType].MemberScope) then
      begin
        LSym := LS;
        Break;
      end;
    if LSym < 0 then
      Exit;
  end;
  Result := SymIdOf(AProj, LMid, LSym, AId);
end;

{ ---- answers as text ------------------------------------------------------ }

function One(const AText: string): TArray<string>;
begin
  Result := [AText];
end;

function HitText(const AHit: TPasRefHit): string;
begin
  Result := Format('%s|%d|%d%s', [LowerCase(AHit.FilePath), AHit.Line,
    AHit.Col, IfThen(AHit.Implicit, '|implicit', '')]);
end;

function HitsText(const AHits: TArray<TPasRefHit>): TArray<string>;
begin
  SetLength(Result, Length(AHits));
  for var LI := 0 to High(AHits) do
    Result[LI] := HitText(AHits[LI]);
end;

function TargetText(const ATarget: TPasNavTarget): string;
begin
  Result := Format('%s|%d|%d|%s', [LowerCase(ATarget.FilePath), ATarget.Line,
    ATarget.Col, ATarget.Name]);
end;

{ ---- the comparison ------------------------------------------------------- }

function Wanted(const AFamily: string): Boolean;
begin
  if GOnlyFamilies = nil then
    Exit(True);
  for var LF in GOnlyFamilies do
    if SameText(LF, AFamily) then
      Exit(True);
  Result := False;
end;

procedure Note(const AFamily: string; AWired: Boolean;
  const AFull, ALight: TArray<string>; ANotSearched: Integer;
  const ALabel: string);
var
  LStat: TFamilyStat;
  LA, LB: TArray<string>;
  LIA, LIB: Integer;
  LDiffs: TArray<string>;
begin
  if not GStats.TryGetValue(AFamily, LStat) then
  begin
    LStat := Default(TFamilyStat);
    LStat.Name := AFamily;
    LStat.Wired := AWired;
    GFamilyOrder.Add(AFamily);
  end;
  Inc(LStat.Queries);
  Inc(LStat.FullRows, Length(AFull));
  Inc(LStat.LightRows, Length(ALight));
  LA := Copy(AFull);
  LB := Copy(ALight);
  TArray.Sort<string>(LA);
  TArray.Sort<string>(LB);
  LDiffs := nil;
  LIA := 0;
  LIB := 0;
  while (LIA <= High(LA)) or (LIB <= High(LB)) do
    if (LIB > High(LB)) or ((LIA <= High(LA)) and (CompareStr(LA[LIA], LB[LIB]) < 0)) then
    begin
      LDiffs := LDiffs + ['  full only: ' + LA[LIA]];
      Inc(LIA);
    end
    else if (LIA > High(LA)) or (CompareStr(LB[LIB], LA[LIA]) < 0) then
    begin
      LDiffs := LDiffs + ['  light only: ' + LB[LIB]];
      Inc(LIB);
    end
    else
    begin
      Inc(LIA);
      Inc(LIB);
    end;
  if LDiffs = nil then
    Inc(LStat.Equal)
  else
  begin
    Inc(LStat.Diff);
    if GVerbose or (Length(LStat.Samples) < 12) then
    begin
      LStat.Samples := LStat.Samples + [Format('%s: %d full, %d light row(s)',
        [ALabel, Length(AFull), Length(ALight)])];
      LStat.Samples := LStat.Samples + Copy(LDiffs, 0,
        IfThen(GVerbose, MaxInt, 4));
    end;
  end;
  if AWired and (ANotSearched <> 0) then
  begin
    Inc(LStat.NotSearchedBad);
    if Length(LStat.Samples) < 24 then
      LStat.Samples := LStat.Samples + [Format('%s: NotSearched = %d',
        [ALabel, ANotSearched])];
  end;
  GStats.AddOrSetValue(AFamily, LStat);
end;

{ The light side meets ADemand as a host does: PasEnsureDemand, then a
  rebuild when EnsureFull asks for one - with the project as donor and its
  promotions kept, or with no light paths at all on an escalation. }
procedure EnsureLight(const ADemand: TPasDemandFunc);
var
  LRes: TPasEnsureResult;
  LRounds: Integer;
  LSW: TStopwatch;
begin
  for var LPass := 1 to 4 do
  begin
    LSW := TStopwatch.StartNew;
    var LOk := PasEnsureDemand(GLightNav, ADemand, LRes, LRounds);
    GLight := GLightNav.Project;
    Inc(GCur.Rounds, LRounds);
    Inc(GCur.Promoted, LRes.Promoted);
    Inc(GCur.Loaded, LRes.Loaded);
    Inc(GCur.Preprocessed, LRes.Preprocessed);
    Inc(GCur.Refused, Length(LRes.Refused));
    Inc(GCur.Ms, LSW.ElapsedMilliseconds);
    if GVerbose then
      for var LR in LRes.Refused do
        Writeln(ErrOutput, '      refused: ', LR);
    if LOk then
      Exit;
    LSW := TStopwatch.StartNew;
    case LRes.Outcome of
      eoNeedsRebuild:
        begin
          Inc(GCur.Rebuilds);
          ReplaceLight(NewProject(True, GLight, True));
        end;
      eoEscalate:
        begin
          // The host's answer is a rebuild without light paths - a full
          // analysis of the same configuration, which the full side is
          // (G2 holds the two runs byte-identical). This question is
          // answered from it; the light project stays as it is.
          Inc(GCur.Escalations);
          if GVerbose then
            Writeln(ErrOutput, '      ', LRes.Note);
          GEscalatedQ := True;
          Inc(GCur.Ms, LSW.ElapsedMilliseconds);
          Exit;
        end;
    else
      Inc(GCur.Ms, LSW.ElapsedMilliseconds);
      Exit;   // partial: the comparison shows what is missing
    end;
    Inc(GCur.Ms, LSW.ElapsedMilliseconds);
  end;
end;

{ One question to both sides. ADemand nil: a family not wired yet - the
  light side answers as it is. }
procedure NoteCost(const AFamily: string; const ABefore: TCostRow);
var
  LStat: TFamilyStat;
  LMs: Int64;
begin
  if not GStats.TryGetValue(AFamily, LStat) then
    Exit;
  if (GCur.Promoted = ABefore.Promoted) and (GCur.Loaded = ABefore.Loaded) and
     (GCur.Preprocessed = ABefore.Preprocessed) and
     (GCur.Rebuilds = ABefore.Rebuilds) and
     (GCur.Escalations = ABefore.Escalations) then
    Exit;
  LMs := GCur.Ms - ABefore.Ms;
  Inc(LStat.Worked);
  Inc(LStat.Rounds, GCur.Rounds - ABefore.Rounds);
  Inc(LStat.Promoted, GCur.Promoted - ABefore.Promoted);
  Inc(LStat.Loaded, GCur.Loaded - ABefore.Loaded);
  Inc(LStat.Preprocessed, GCur.Preprocessed - ABefore.Preprocessed);
  Inc(LStat.Rebuilds, GCur.Rebuilds - ABefore.Rebuilds);
  Inc(LStat.Escalations, GCur.Escalations - ABefore.Escalations);
  Inc(LStat.EnsureMs, LMs);
  if LMs > LStat.MaxMs then
    LStat.MaxMs := LMs;
  GStats[AFamily] := LStat;
end;

procedure Ask(const AFamily, ALabel: string; const AQuery: TQueryFn;
  const ADemand: TPasDemandFunc);
var
  LFull, LLight: TArray<string>;
  LNotSearched: Integer;
  LBefore: TCostRow;
begin
  if not Wanted(AFamily) then
    Exit;
  try
    LFull := AQuery(GFullNav);
  except
    on E: Exception do
      LFull := ['raised ' + E.ClassName + ': ' + E.Message];
  end;
  GEscalatedQ := False;
  LBefore := GCur;
  if Assigned(ADemand) then
    EnsureLight(ADemand);
  try
    if GEscalatedQ then
    begin
      GFullNav.NotSearched := 0;
      LLight := AQuery(GFullNav);
      LNotSearched := GFullNav.NotSearched;
    end
    else
    begin
      GLightNav.NotSearched := 0;
      LLight := AQuery(GLightNav);
      LNotSearched := GLightNav.NotSearched;
    end;
  except
    on E: Exception do
    begin
      LLight := ['raised ' + E.ClassName + ': ' + E.Message];
      LNotSearched := 0;
    end;
  end;
  Note(AFamily, Assigned(ADemand), LFull, LLight, LNotSearched, ALabel);
  NoteCost(AFamily, LBefore);
  // An escalation means the light project has promoted most of what it
  // may: every later question would escalate at once. A light one again.
  if GEscalatedQ and (GLight.LightCount > 0) and (GLight.PromotedFiles <> nil) then
  begin
    ReplaceLight(NewProject(True, GLight, False));
    Inc(GResets);
  end;
end;

{ ---- the questions -------------------------------------------------------- }

// Resolves AId in ANav's project; False (and an empty answer) when absent.
function Resolve(ANav: TPasNavigator; const AId: TSymId;
  out AMid, ASym: Integer): Boolean;
begin
  Result := FindSym(ANav.Project, AId, AMid, ASym);
end;

{ A family whose answer needs no library body: wired, with an empty demand. }
function NoDemand: TPasDemandFunc;
begin
  Result :=
    function(ANav: TPasNavigator): TPasDemand
    begin
      Result := Default(TPasDemand);
    end;
end;

// A symbol question's demand, the symbol resolved in the navigator's project.
function SymDemand(const AId: TSymId; const AKind: string): TPasDemandFunc;
begin
  Result :=
    function(ANav: TPasNavigator): TPasDemand
    var
      LM, LS: Integer;
    begin
      // Not in this closure (yet): its unit first, when the full closure
      // has it (DemandFilePath).
      if not FindSym(ANav.Project, AId, LM, LS) then
        Exit(ANav.DemandFilePath(AId.MainFile));
      Result := Default(TPasDemand);
      if AKind = 'descendants' then
        Result := ANav.DemandDescendants(LM, LS)
      else if AKind = 'implementors' then
        Result := ANav.DemandInterfaceImplementors(LM, LS)
      else if AKind = 'overrides' then
        Result := ANav.DemandOverrides(LM, LS)
      else if AKind = 'implementations' then
        Result := ANav.DemandImplementations(LM, LS)
      else if AKind = 'rename-family' then
        Result := ANav.DemandRenameFamily(LM, LS)
      else if AKind = 'rename' then
        Result := ANav.DemandRename(LM, LS)
      else if AKind = 'file' then
        Result := ANav.DemandFile(LM);
    end;
end;

function PosDemand(const AFile: string; ALine, ACol: Integer): TPasDemandFunc;
begin
  Result :=
    function(ANav: TPasNavigator): TPasDemand
    begin
      if ANav.ModelIdOf(AFile) < 0 then
        Result := ANav.DemandFilePath(AFile)
      else
        Result := ANav.DemandPosition(ANav.ModelIdOf(AFile), ALine, ACol);
    end;
end;

function DefinesDemand(const AName: string): TPasDemandFunc;
begin
  Result :=
    function(ANav: TPasNavigator): TPasDemand
    begin
      if AName = '' then
        Result := ANav.DemandDefines
      else
        Result := ANav.DemandDefineReferences(AName);
    end;
end;

function BuiltinDemand(const AName: string): TPasDemandFunc;
begin
  Result :=
    function(ANav: TPasNavigator): TPasDemand
    begin
      Result := ANav.DemandBuiltin(AName);
    end;
end;

procedure AskSymbol(const AId: TSymId; AOwn: Boolean = False);
var
  LKind: TSemaSymbolKind;
  LMid, LSym: Integer;
  LIsClass, LIsRoutine, LIsIntf: Boolean;
  LLabel: string;
begin
  if not FindSym(GFull, AId, LMid, LSym) then
    Exit;
  LKind := GFull.Model(LMid).Symbols[LSym].Kind;
  LIsClass := (LKind = skType) and
    (GFull.Model(LMid).Symbols[LSym].TypeCat = tcClass);
  LIsIntf := (LKind = skType) and
    (GFull.Model(LMid).Symbols[LSym].TypeCat = tcInterface);
  LIsRoutine := LKind = skRoutine;
  LLabel := AId.Text;
  // The wired families (S10).
  Ask('references', LLabel,
    function(ANav: TPasNavigator): TArray<string>
    var
      LM, LS: Integer;
    begin
      if Resolve(ANav, AId, LM, LS) then
        Result := HitsText(ANav.FindReferences(LM, LS, True))
      else
        Result := ['unresolved'];
    end,
    function(ANav: TPasNavigator): TPasDemand
    var
      LM, LS: Integer;
    begin
      if Resolve(ANav, AId, LM, LS) then
        Result := ANav.DemandReferences(LM, LS)
      else
        Result := ANav.DemandFilePath(AId.MainFile);
    end);
  if LKind in [skVar, skField, skProperty] then
    Ask('assignments', LLabel,
      function(ANav: TPasNavigator): TArray<string>
      var
        LM, LS: Integer;
      begin
        if Resolve(ANav, AId, LM, LS) then
        begin
          // FindAssignments leaves NotSearched to CollectReferencesOfAll.
          Result := HitsText(ANav.FindAssignments(LM, LS));
        end
        else
          Result := ['unresolved'];
      end,
      function(ANav: TPasNavigator): TPasDemand
      var
        LM, LS: Integer;
      begin
        if Resolve(ANav, AId, LM, LS) then
          Result := ANav.DemandReferences(LM, LS)
        else
          Result := ANav.DemandFilePath(AId.MainFile);
      end);
  if LIsClass then
  begin
    Ask('creations', LLabel,
      function(ANav: TPasNavigator): TArray<string>
      var
        LM, LS: Integer;
      begin
        if Resolve(ANav, AId, LM, LS) then
          Result := HitsText(ANav.FindCreations(LM, LS))
        else
          Result := ['unresolved'];
      end,
      function(ANav: TPasNavigator): TPasDemand
      var
        LM, LS: Integer;
      begin
        if Resolve(ANav, AId, LM, LS) then
          Result := ANav.DemandCreations(LM, LS)
        else
          Result := ANav.DemandFilePath(AId.MainFile);
      end);
    Ask('destructions', LLabel,
      function(ANav: TPasNavigator): TArray<string>
      var
        LM, LS: Integer;
      begin
        if Resolve(ANav, AId, LM, LS) then
          Result := HitsText(ANav.FindDestructions(LM, LS))
        else
          Result := ['unresolved'];
      end,
      function(ANav: TPasNavigator): TPasDemand
      var
        LM, LS: Integer;
      begin
        if Resolve(ANav, AId, LM, LS) then
          Result := ANav.DemandDestructions(LM, LS)
        else
          Result := ANav.DemandFilePath(AId.MainFile);
      end);
  end;
  // A type's members at once: CollectReferencesOfAll.
  if (LKind = skType) and
     (GFull.Model(LMid).Symbols[LSym].MemberScope <> NIL_SCOPE) then
    Ask('references-of-all', LLabel,
      function(ANav: TPasNavigator): TArray<string>
      var
        LRefs: TArray<TPasExtRef>;
      begin
        LRefs := nil;
        var LM, LS: Integer;
        if not Resolve(ANav, AId, LM, LS) then
          Exit(One('unresolved'));
        var LModel := ANav.Project.Model(LM);
        for var LX := 0 to LModel.SymCount - 1 do
          if LModel.Symbols[LX].Scope = LModel.Symbols[LS].MemberScope then
          begin
            SetLength(LRefs, Length(LRefs) + 1);
            LRefs[High(LRefs)].UnitId := LM;
            LRefs[High(LRefs)].Sym := LX;
          end;
        var LHits := TList<TPasRefHit>.Create;
        try
          ANav.CollectReferencesOfAll(LRefs, LHits);
          Result := HitsText(LHits.ToArray);
        finally
          LHits.Free;
        end;
      end,
      function(ANav: TPasNavigator): TPasDemand
      var
        LRefs: TArray<TPasExtRef>;
      begin
        LRefs := nil;
        var LM, LS: Integer;
        if not Resolve(ANav, AId, LM, LS) then
          Exit(ANav.DemandFilePath(AId.MainFile));
        var LModel := ANav.Project.Model(LM);
        for var LX := 0 to LModel.SymCount - 1 do
          if LModel.Symbols[LX].Scope = LModel.Symbols[LS].MemberScope then
          begin
            SetLength(LRefs, Length(LRefs) + 1);
            LRefs[High(LRefs)].UnitId := LM;
            LRefs[High(LRefs)].Sym := LX;
          end;
        Result := ANav.DemandReferencesOfAll(LRefs);
      end);
  // The hierarchy family, the library file's bodies, the rename plan.
  if LKind = skType then
    Ask('descendants', LLabel,
      function(ANav: TPasNavigator): TArray<string>
      var
        LM, LS: Integer;
      begin
        Result := nil;
        if Resolve(ANav, AId, LM, LS) then
          for var LH in ANav.FindDescendants(LM, LS) do
            Result := Result + [HitText(LH.Hit) + '|' + LH.TypeName + '|' +
              LH.ParentTypeName + '|' + IntToStr(Ord(LH.Kind)) + '|' +
              IntToStr(LH.Depth)];
      end, SymDemand(AId, 'descendants'));
  if LIsIntf then
    Ask('interface-implementors', LLabel,
      function(ANav: TPasNavigator): TArray<string>
      var
        LM, LS: Integer;
      begin
        Result := nil;
        if Resolve(ANav, AId, LM, LS) then
          for var LH in ANav.FindInterfaceImplementors(LM, LS) do
            Result := Result + [HitText(LH.Hit) + '|' + LH.TypeName + '|' +
              LH.ViaTypeName + '|' + IntToStr(Ord(LH.Kind))];
      end, SymDemand(AId, 'implementors'));
  if LIsRoutine then
  begin
    Ask('overrides', LLabel,
      function(ANav: TPasNavigator): TArray<string>
      var
        LM, LS: Integer;
      begin
        Result := nil;
        if Resolve(ANav, AId, LM, LS) then
          for var LH in ANav.FindOverrides(LM, LS) do
            Result := Result + [HitText(LH.Hit) + '|' + LH.TypeName + '|' +
              IntToStr(Ord(LH.Kind))];
      end, SymDemand(AId, 'overrides'));
    Ask('implementations', LLabel,
      function(ANav: TPasNavigator): TArray<string>
      var
        LM, LS: Integer;
      begin
        Result := nil;
        if Resolve(ANav, AId, LM, LS) then
          for var LH in ANav.FindImplementations(LM, LS) do
            Result := Result + [HitText(LH.Hit) + '|' + LH.TypeName + '|' +
              LH.ViaTypeName + '|' + IntToStr(Ord(LH.Kind))];
      end, SymDemand(AId, 'implementations'));
    Ask('rename-family', LLabel,
      function(ANav: TPasNavigator): TArray<string>
      var
        LM, LS: Integer;
        LMembers: TArray<TPasRenameFamilyMember>;
        LErr: string;
      begin
        Result := nil;
        if Resolve(ANav, AId, LM, LS) then
        begin
          if not ANav.RenameFamily(LM, LS, LMembers, LErr) then
            Exit(One('refused: ' + LErr));
          for var LMem in LMembers do
            Result := Result + [HitText(LMem.Hit) + '|' + LMem.TypeName + '|' +
              IntToStr(Ord(LMem.Why))];
        end;
      end, SymDemand(AId, 'rename-family'));
    Ask('routine-impl', LLabel,
      function(ANav: TPasNavigator): TArray<string>
      var
        LM, LS, LLine, LCol: Integer;
        LFile: string;
      begin
        Result := nil;
        if Resolve(ANav, AId, LM, LS) then
        begin
          var LNode := ANav.RoutineImplNode(LM, LS);
          if (LNode <> NIL_NODE) and ANav.Project.NodeSite(LM, LNode, LFile,
               LLine, LCol) then
            Result := [Format('%s|%d|%d', [LowerCase(LFile), LLine, LCol])];
        end;
      end, SymDemand(AId, 'file'));
  end;
  // A rename of an own symbol (a library one is refused in both modes).
  if AOwn and (LKind in [skType, skVar, skConst, skField, skRoutine,
     skProperty]) then
    Ask('rename-plan', LLabel,
      function(ANav: TPasNavigator): TArray<string>
      var
        LM, LS: Integer;
        LEdits: TArray<TPasRenameEdit>;
        LErr: string;
      begin
        Result := nil;
        if not Resolve(ANav, AId, LM, LS) then
          Exit(One('unresolved'));
        if not ANav.PlanRename(LM, LS, AId.Name + 'Rn', LEdits, LErr) then
          Exit(One('refused: ' + LErr));
        for var LE in LEdits do
          Result := Result + [Format('%s|%d|%d|%s|%s', [LowerCase(LE.FilePath),
            LE.Line, LE.Col, LE.OldText, LE.NewText])];
      end, SymDemand(AId, 'rename'));
  Ask('decl-hit', LLabel,
    function(ANav: TPasNavigator): TArray<string>
    var
      LM, LS: Integer;
      LHit: TPasRefHit;
    begin
      Result := nil;
      if Resolve(ANav, AId, LM, LS) and ANav.DeclHit(LM, LS, LHit) then
        Result := [HitText(LHit)];
    end, SymDemand(AId, 'none'));
  Ask('form-sites', LLabel,
    function(ANav: TPasNavigator): TArray<string>
    var
      LM, LS: Integer;
    begin
      Result := nil;
      if Resolve(ANav, AId, LM, LS) then
        for var LSite in ANav.FindFormSites(LM, LS) do
          Result := Result + [Format('%s|%d|%d|%d', [LowerCase(LSite.FilePath),
            LSite.Line, LSite.Col, Ord(LSite.Kind)])];
    end, SymDemand(AId, 'none'));
end;

{ A unit's questions: unit-level, then every n-th position of its text
  (AStride). ALibrary: a library file - the one-library-file family, whose
  demand is the unit itself (DemandFile); an own unit's have none. }
procedure AskUnit(AFullMid: Integer; ALibrary: Boolean = False;
  AStride: Integer = -1);
var
  LFile, LText, LPrefix: string;
  LLines: TArray<string>;
  LCount: Integer;
  LDemand: TPasDemandFunc;
begin
  LFile := GFull.ModelFile(AFullMid);
  if AStride < 0 then
    AStride := GPosStride;
  LDemand := nil;
  LPrefix := '';
  if ALibrary then
  begin
    LPrefix := 'library-file-';
    LDemand :=
      function(ANav: TPasNavigator): TPasDemand
      begin
        Result := ANav.DemandFilePath(LFile);
      end;
    Ask('library-file-tokens', TPath.GetFileName(LFile),
      function(ANav: TPasNavigator): TArray<string>
      begin
        Result := nil;
        var LMid := ANav.ModelIdOf(LFile);
        if LMid < 0 then
          Exit(One('unresolved'));
        for var LT in ANav.SemanticTokens(LMid) do
          Result := Result + [Format('%d|%d|%s', [LT.RawToken, Ord(LT.Kind),
            BoolToStr(LT.IsDecl, True)])];
      end, LDemand);
    Ask('library-file-outline', TPath.GetFileName(LFile),
      function(ANav: TPasNavigator): TArray<string>
      var
        LLine, LCol: Integer;
        LSite: string;
      begin
        // Every routine's implementation, where the unit declares one.
        Result := nil;
        var LMid := ANav.ModelIdOf(LFile);
        if LMid < 0 then
          Exit(One('unresolved'));
        var LM := ANav.Project.Model(LMid);
        for var LS := 0 to LM.SymCount - 1 do
          if LM.Symbols[LS].Kind = skRoutine then
          begin
            var LNode := ANav.RoutineImplNode(LMid, LS);
            if (LNode <> NIL_NODE) and ANav.Project.NodeSite(LMid, LNode,
                 LSite, LLine, LCol) then
              Result := Result + [Format('%s|%s|%d|%d', [LM.Symbols[LS].Name,
                LowerCase(LSite), LLine, LCol])];
          end;
      end, LDemand);
  end
  else
  begin
  Ask('unit-references', TPath.GetFileName(LFile),
    function(ANav: TPasNavigator): TArray<string>
    begin
      var LMid := ANav.ModelIdOf(LFile);
      if LMid < 0 then
        Exit(One('unresolved'));
      Result := HitsText(ANav.FindUnitReferences(LMid));
    end, NoDemand());
  Ask('unit-decl', TPath.GetFileName(LFile),
    function(ANav: TPasNavigator): TArray<string>
    var
      LHit: TPasRefHit;
      LTarget: TPasNavTarget;
    begin
      Result := nil;
      var LMid := ANav.ModelIdOf(LFile);
      if LMid < 0 then
        Exit(One('unresolved'));
      if ANav.UnitDeclHit(LMid, LHit) then
        Result := Result + [HitText(LHit)];
      if ANav.UnitHeaderTarget(LMid, LTarget) then
        Result := Result + [TargetText(LTarget)];
    end, NoDemand());
  Ask('semantic-tokens', TPath.GetFileName(LFile),
    function(ANav: TPasNavigator): TArray<string>
    begin
      Result := nil;
      var LMid := ANav.ModelIdOf(LFile);
      if LMid < 0 then
        Exit(One('unresolved'));
      for var LT in ANav.SemanticTokens(LMid) do
        Result := Result + [Format('%d|%d|%s', [LT.RawToken, Ord(LT.Kind),
          BoolToStr(LT.IsDecl, True)])];
    end, NoDemand());
  end;
  if AStride <= 0 then
    Exit;
  // Every n-th identifier of the text: the position queries.
  try
    LText := TFile.ReadAllText(LFile);
  except
    Exit;
  end;
  LLines := LText.Split([#13#10, #10]);
  LCount := 0;
  for var LLine := 0 to High(LLines) do
  begin
    var LCol := 1;
    var LS := LLines[LLine];
    while LCol <= Length(LS) do
    begin
      if PasIsIdentStart(LS[LCol]) and ((LCol = 1) or not PasIsIdentChar(LS[LCol - 1])) then
      begin
        Inc(LCount);
        if LCount mod AStride = 0 then
        begin
          var LL := LLine + 1;
          var LC := LCol;
          var LLabel := Format('%s(%d,%d)', [TPath.GetFileName(LFile), LL, LC]);
          Ask(LPrefix + 'positions', LLabel,
            function(ANav: TPasNavigator): TArray<string>
            var
              LIdent: TPasNavIdent;
              LTarget: TPasNavTarget;
              LTMid, LSym, LStart, LLen, LRaw: Integer;
              LName: string;
            begin
              Result := nil;
              var LMid := ANav.ModelIdOf(LFile);
              if LMid < 0 then
                Exit(One('unresolved'));
              if ANav.IdentAt(LMid, LL, LC, LIdent) then
              begin
                Result := Result + [Format('ident|%d|%d|%d|%s', [LIdent.Line,
                  LIdent.ColFrom, LIdent.ColTo, LIdent.Name])];
                if ANav.ResolveDecl(LMid, LIdent.Node, LTarget) then
                  Result := Result + ['decl|' + TargetText(LTarget)];
              end;
              if ANav.SymbolAt(LMid, LL, LC, LTMid, LSym, LName) then
                Result := Result + ['symbol|' + SymKey(ANav.Project, LTMid, LSym)];
              if ANav.GotoDeclaration(LMid, LL, LC, LTarget) then
                Result := Result + ['goto-decl|' + TargetText(LTarget)];
              if ANav.MethodAt(LMid, LL, LC, LTMid, LSym, LName) then
                Result := Result + ['method|' + SymKey(ANav.Project, LTMid, LSym)];
              if ANav.InterfaceMethodAt(LMid, LL, LC, LTMid, LSym, LName) then
                Result := Result + ['intf-method|' + SymKey(ANav.Project, LTMid, LSym)];
              if ANav.InterfaceAt(LMid, LL, LC, LTMid, LSym, LName) then
                Result := Result + ['intf|' + SymKey(ANav.Project, LTMid, LSym)];
              if ANav.TypeAt(LMid, LL, LC, LTMid, LSym, LName) then
                Result := Result + ['type|' + SymKey(ANav.Project, LTMid, LSym)];
              if ANav.AssignableAt(LMid, LL, LC, LTMid, LSym, LName) then
                Result := Result + ['assignable|' + SymKey(ANav.Project, LTMid, LSym)];
              if ANav.ClassAt(LMid, LL, LC, LTMid, LSym, LName) then
                Result := Result + ['class|' + SymKey(ANav.Project, LTMid, LSym)];
              if ANav.UnitAt(LMid, LL, LC, LTMid, LName) then
                Result := Result + ['unit|' + LowerCase(ANav.Project.ModelFile(LTMid)) + '|' + LName];
              if ANav.BuiltinNameAt(LMid, LL, LC, LName) then
                Result := Result + ['builtin|' + LName];
              if ANav.DefineAt(LMid, LL, LC, LName, LRaw) then
                Result := Result + ['define|' + LName];
              if ANav.DefineSpanAt(LMid, LL, LC, LStart, LLen) then
                Result := Result + [Format('define-span|%d|%d', [LStart, LLen])];
              if ANav.IfNameAt(LMid, LL, LC, LName, LStart, LLen, LTMid, LSym) then
                Result := Result + ['if-name|' + LName + '|' + SymKey(ANav.Project, LTMid, LSym)];
              if ANav.GotoDefine(LMid, LL, LC, LTarget) then
                Result := Result + ['goto-define|' + TargetText(LTarget)];
              if ANav.GotoBareInherited(LMid, LL, LC, LTarget) then
                Result := Result + ['bare-inherited|' + TargetText(LTarget)];
              if ANav.GotoImplementation(LMid, LL, LC, LTarget) then
                Result := Result + ['goto-impl|' + TargetText(LTarget)];
              for var LD in ANav.DefinesAt(LMid, LL, LC) do
                Result := Result + [Format('defines-at|%s|%d|%s', [LD.Name,
                  Ord(LD.Origin), BoolToStr(LD.Active, True)])];
              for var LO in ANav.OptionsAt(LMid, LL, LC) do
                Result := Result + [Format('options-at|%s|%s|%d', [LO.Name,
                  LO.Value, Ord(LO.Origin)])];
            end, PosDemand(LFile, LL, LC));
        end;
        while (LCol <= Length(LS)) and PasIsIdentChar(LS[LCol]) do
          Inc(LCol);
      end
      else
        Inc(LCol);
    end;
  end;
end;

var
  GOwnFiles: TArray<string>;

function OwnMids(ANav: TPasNavigator): TArray<Integer>;
begin
  Result := nil;
  for var LF in GOwnFiles do
    if ANav.ModelIdOf(LF) >= 0 then
      Result := Result + [ANav.ModelIdOf(LF)];
end;

procedure AskProjectWide(const AOwnFiles: TArray<string>);
begin
  GOwnFiles := AOwnFiles;
  // The uses lint (wired: S5's LintPromotions, now DemandLint).
  Ask('lint-unused', 'own units',
    function(ANav: TPasNavigator): TArray<string>
    begin
      Result := nil;
      for var LR in FindUnusedUses(ANav, OwnMids(ANav)) do
        Result := Result + [HitText(LR.Hit) + '|' + LR.UnitName + '|' +
          BoolToStr(LR.InInterface, True) + '|' + string.Join('; ', LR.Doubts)];
    end,
    function(ANav: TPasNavigator): TPasDemand
    begin
      Result := DemandLint(ANav, OwnMids(ANav));
    end);
  Ask('lint-unreferenced', 'own units',
    function(ANav: TPasNavigator): TArray<string>
    begin
      Result := nil;
      for var LR in FindUnreferencedUnits(ANav, OwnMids(ANav)) do
        Result := Result + [HitText(LR.Hit) + '|' + LR.UnitName + '|' +
          string.Join(', ', LR.ListedBy) + '|' + string.Join('; ', LR.Doubts)];
    end,
    function(ANav: TPasNavigator): TPasDemand
    begin
      Result := DemandLint(ANav, OwnMids(ANav));
    end);
  Ask('project-outline', 'own units',
    function(ANav: TPasNavigator): TArray<string>
    begin
      Result := nil;
      for var LE in ANav.ProjectOutline(OwnMids(ANav)) do
        Result := Result + [LE.Head + '|' + LE.Owner + '|' + LE.Name + '|' +
          LE.UnitName + '|' + LE.Detail];
    end, NoDemand());
  Ask('defines', 'all',
    function(ANav: TPasNavigator): TArray<string>
    begin
      Result := nil;
      for var LD in ANav.FindDefines do
        Result := Result + [HitText(LD.Hit) + '|' + LD.Name + '|' +
          IntToStr(Ord(LD.Origin)) + '|' + BoolToStr(LD.Active, True)];
    end, DefinesDemand(''));
  for var LName in ['MSWINDOWS', 'WIN64', 'WIN32', 'DEBUG', 'RELEASE',
    'UNICODE', 'CPUX64', 'NEXTGEN', 'PUREPASCAL', 'X86ASM', 'POSIX',
    'LINUX', 'ASSEMBLER'] do
    Ask('define-references', LName,
      function(ANav: TPasNavigator): TArray<string>
      begin
        Result := ['defined|' + BoolToStr(ANav.IsProjectDefined(LName), True)];
        for var LD in ANav.FindDefineReferences(LName) do
          Result := Result + [HitText(LD.Hit) + '|' + IntToStr(Ord(LD.Kind)) +
            '|' + BoolToStr(LD.Active, True)];
      end, DefinesDemand(LName));
  for var LName in ['Length', 'Inc', 'Exit', 'SizeOf', 'Assigned', 'High',
    'Ord', 'Copy', 'Integer', 'string'] do
    Ask('builtin-references', LName,
      function(ANav: TPasNavigator): TArray<string>
      begin
        Result := HitsText(ANav.FindBuiltinReferences(LName));
      end, BuiltinDemand(LName));
end;

{ ---- the report ----------------------------------------------------------- }

function Report: Boolean;
var
  LStat: TFamilyStat;
begin
  Result := True;
  Writeln(Format('%-24s %-6s %8s %8s %8s %8s %10s %10s', ['family', 'wired',
    'queries', 'equal', 'diff', 'notsrch', 'full rows', 'light rows']));
  for var LName in GFamilyOrder do
  begin
    LStat := GStats[LName];
    Writeln(Format('%-24s %-6s %8d %8d %8d %8d %10d %10d', [LStat.Name,
      IfThen(LStat.Wired, 'yes', 'NO'), LStat.Queries, LStat.Equal,
      LStat.Diff, LStat.NotSearchedBad, LStat.FullRows, LStat.LightRows]));
    if LStat.Wired and ((LStat.Diff > 0) or (LStat.NotSearchedBad > 0)) then
      Result := False;
  end;
  for var LName in GFamilyOrder do
  begin
    LStat := GStats[LName];
    if LStat.Samples = nil then
      Continue;
    if LStat.Wired then
      Writeln('--- ', LStat.Name, ': DIFFERENCES (wired - a defect)')
    else
      Writeln('--- ', LStat.Name, ': differences, demand not wired yet');
    for var LS in LStat.Samples do
      Writeln('  ', LS);
  end;
  Writeln('--- cost per family (light side: the questions whose demand did ' +
    'something; an escalation is answered by the full analysis, its rebuild ' +
    'not timed here) ---');
  Writeln(Format('%-24s %8s %6s %8s %6s %8s %8s %8s %10s %8s', ['family',
    'worked', 'rounds', 'promoted', 'loaded', 'preproc.', 'rebuilds',
    'escal.', 'ensure ms', 'max ms']));
  for var LName in GFamilyOrder do
  begin
    LStat := GStats[LName];
    Writeln(Format('%-24s %8d %6d %8d %6d %8d %8d %8d %10d %8d', [LStat.Name,
      LStat.Worked, LStat.Rounds, LStat.Promoted, LStat.Loaded,
      LStat.Preprocessed, LStat.Rebuilds, LStat.Escalations, LStat.EnsureMs,
      LStat.MaxMs]));
  end;
  Writeln('--- cost per question (light side) ---');
  Writeln(Format('%-48s %6s %8s %6s %8s %8s %8s %8s', ['question', 'rounds',
    'promoted', 'loaded', 'rebuilds', 'escal.', 'refused', 'ms']));
  for var LC in GCosts do
    Writeln(Format('%-48s %6d %8d %6d %8d %8d %8d %8d', [Copy(LC.Text, 1, 48),
      LC.Rounds, LC.Promoted, LC.Loaded, LC.Rebuilds, LC.Escalations,
      LC.Refused, LC.Ms]));
  Writeln(Format('word index: first demand %d ms, %s held by it (measured ' +
    'as the allocation delta around the first demand)',
    [GWordMs, MemoryText(Max(0, GWordBytes))]));
  Writeln(Format('light analyses: %d (%d after an escalation)', [GLightRuns,
    GResets]));
end;

{ ---- main ----------------------------------------------------------------- }

procedure Run(const APath: string);
var
  LOwnFiles: TArray<string>;
  LOwnIds: TList<TSymId>;
  LLibIds: TArray<TSymId>;
  LId: TSymId;
  LMid, LUnitIdx: Integer;
  LSW: TStopwatch;
  LLibs: TArray<string>;
  LBefore: Int64;
begin
  GDProj := TPasDProj.Create;
  try
    var LPlatArg := '';
    if GPlatformGiven then
      LPlatArg := PlatformName(GPlatform);
    if not GDProj.Load(APath, LPlatArg) or not TFile.Exists(GDProj.MainSource) then
    begin
      Writeln(ErrOutput, 'Could not load .dproj or its main source: ', APath);
      ExitCode := 2;
      Exit;
    end;
    GPaths := [GDProj.Dir] + GDProj.SearchPaths + StudioSearchPaths(GStudio) +
      GExtraPaths;
    LSW := TStopwatch.StartNew;
    GFull := NewProject(False, nil, False);
    Writeln(ErrOutput, Format('full: %d units in %d ms', [GFull.ModelCount,
      LSW.ElapsedMilliseconds]));
    LSW := TStopwatch.StartNew;
    GLight := NewProject(True, nil, False);
    Writeln(ErrOutput, Format('light: %d units (%d light) in %d ms',
      [GLight.ModelCount, GLight.LightCount, LSW.ElapsedMilliseconds]));
    LLibs := LightTrees;
    GFullNav := TPasNavigator.Create(GFull);
    GFullNav.LibraryPaths := LLibs;
    GLightNav := TPasNavigator.Create(GLight);
    GLightNav.LibraryPaths := LLibs;
    // The word index's first build: a demand that needs it.
    LBefore := AllocatedBytes;
    LSW := TStopwatch.StartNew;
    GLight.DemandOf(nil);
    GWordMs := LSW.ElapsedMilliseconds;
    GWordBytes := Int64(AllocatedBytes) - LBefore;
    // The project's own units: its listed files with a model on both sides.
    LOwnFiles := nil;
    for var LF in GDProj.Files do
      if (GFull.ModelIdOf(LF) >= 0) and (GLight.ModelIdOf(LF) >= 0) then
        LOwnFiles := LOwnFiles + [GFull.ModelFile(GFull.ModelIdOf(LF))];
    if GFull.ModelIdOf(GDProj.MainSource) >= 0 then
      LOwnFiles := LOwnFiles + [GFull.ModelFile(GFull.ModelIdOf(GDProj.MainSource))];
    Writeln(ErrOutput, Format('own units: %d', [Length(LOwnFiles)]));
    // 1. The project-wide questions, the lint first (S5's own gate).
    GCur := Default(TCostRow);
    GCur.Text := 'project-wide';
    AskProjectWide(LOwnFiles);
    GCosts.Add(GCur);
    // 2. The own units' symbols, every n-th.
    LOwnIds := TList<TSymId>.Create;
    try
      LUnitIdx := 0;
      for var LF in LOwnFiles do
      begin
        LMid := GFull.ModelIdOf(LF);
        for var LS := 0 to GFull.Model(LMid).SymCount - 1 do
          if (GFull.Model(LMid).Symbols[LS].Kind in [skType, skVar, skConst,
               skField, skRoutine, skProperty, skEnumValue]) and
             SymIdOf(GFull, LMid, LS, LId) then
          begin
            Inc(LUnitIdx);
            if LUnitIdx mod GOwnStride = 0 then
              LOwnIds.Add(LId);
          end;
      end;
      Writeln(ErrOutput, Format('own symbols asked: %d', [LOwnIds.Count]));
      GCur := Default(TCostRow);
      GCur.Text := Format('own symbols (%d)', [LOwnIds.Count]);
      LSW := TStopwatch.StartNew;
      for var LI := 0 to LOwnIds.Count - 1 do
      begin
        AskSymbol(LOwnIds[LI], True);
        // An escalation left the light side a full analysis: the questions
        // after it would compare full with full. A light one again.
        if GLight.LightCount = 0 then
        begin
          Writeln(ErrOutput, '  escalated on ', LOwnIds[LI].Text,
            ' - a light analysis again');
          ReplaceLight(NewProject(True, GLight, False));
        end;
      end;
      GCosts.Add(GCur);
      Writeln(ErrOutput, Format('own symbols: %d ms', [LSW.ElapsedMilliseconds]));
    finally
      LOwnIds.Free;
    end;
    // 3. The own units' unit and position questions.
    LSW := TStopwatch.StartNew;
    GCur := Default(TCostRow);
    GCur.Text := 'own units and positions';
    LUnitIdx := 0;
    for var LF in LOwnFiles do
    begin
      Inc(LUnitIdx);
      if LUnitIdx mod GOwnUnitStride = 0 then
        AskUnit(GFull.ModelIdOf(LF));
    end;
    GCosts.Add(GCur);
    Writeln(ErrOutput, Format('own units and positions: %d ms',
      [LSW.ElapsedMilliseconds]));
    // 4. The library sample, each on a fresh light project unless -shared.
    if not GNoLib then
    begin
      if GSymArgs = nil then
        GSymArgs := ['System.TObject', 'System.TObject.Free',
          'System.Classes.TComponent', 'System.Classes.TComponent.Create',
          'System.Classes.TStrings.Add', 'System.Classes.TStringList',
          'System.Classes.TList.Count', 'System.SysUtils.FreeAndNil',
          'System.SysUtils.Exception', 'System.SysUtils.IntToStr',
          'System.SysUtils.TStringHelper', 'System.Generics.Collections.TList',
          'System.Math.Max', 'System.StrUtils.IfThen', 'System.IOUtils.TPath',
          'System.IOUtils.TPath.Combine', 'Vcl.Controls.TControl.Visible',
          'Vcl.Forms.TForm', 'Winapi.Windows.GetTickCount',
          'System.TypInfo.GetEnumName', 'System.Zip.TZipFile',
          'System.IInterface', 'System.TInterfacedObject',
          'System.Classes.TPersistent.Assign', 'System.Classes.TStrings',
          'System.Classes.TThread.Execute', 'System.SysUtils.Exception.Create'];
      LLibIds := nil;
      for var LText in GSymArgs do
        if ResolveQualified(GFull, LText, LId) then
          LLibIds := LLibIds + [LId]
        else
          Writeln(ErrOutput, '  library symbol not in the closure: ', LText);
      for LId in LLibIds do
      begin
        if not GShared then
          ReplaceLight(NewProject(True, GLight, False));
        GCur := Default(TCostRow);
        GCur.Text := LId.Text;
        LSW := TStopwatch.StartNew;
        AskSymbol(LId);
        GCosts.Add(GCur);
        Writeln(ErrOutput, Format('  %s: %d ms (ensure %d ms, %d promoted, ' +
          '%d loaded, %d rebuild(s), %d escalation(s))', [LId.Text,
          LSW.ElapsedMilliseconds, GCur.Ms, GCur.Promoted, GCur.Loaded,
          GCur.Rebuilds, GCur.Escalations]));
      end;
    end;
    // 5. One library file: the units the sample's symbols live in, each
    //    asked about on a fresh light project with DemandFile.
    if not GNoLib then
    begin
      var LDone := TDictionary<string, Boolean>.Create;
      try
        for LId in LLibIds do
          if LDone.TryAdd(LowerCase(LId.MainFile), True) and
             (GLight.IsLightFile(LId.MainFile) or
              (GLight.ModelIdOf(LId.MainFile) < 0)) then
          begin
            if not GShared then
              ReplaceLight(NewProject(True, GLight, False));
            GCur := Default(TCostRow);
            GCur.Text := 'file ' + TPath.GetFileName(LId.MainFile);
            LSW := TStopwatch.StartNew;
            AskUnit(GFull.ModelIdOf(LId.MainFile), True, GLibPosStride);
            GCosts.Add(GCur);
            Writeln(ErrOutput, Format('  %s: %d ms (ensure %d ms, %d promoted)',
              [GCur.Text, LSW.ElapsedMilliseconds, GCur.Ms, GCur.Promoted]));
          end;
      finally
        LDone.Free;
      end;
    end;
    if not Report then
      ExitCode := 1;
  finally
    FreeAndNil(GLightNav);
    FreeAndNil(GFullNav);
    FreeAndNil(GLight);
    FreeAndNil(GFull);
    FreeAndNil(GDProj);
  end;
end;

var
  GArg: string;
begin
  System.NeverSleepOnMMThreadContention := True;
  try
    if ParamCount < 1 then
    begin
      Writeln(ErrOutput, 'Usage: PasTreeLightSmoke <project.dproj> [-p:<platform>] ' +
        '[-studio:<dir>] [-L<dir>] [-Lfile:<file>] [-light:<spec>] [-own:<n>] ' +
        '[-ownunits:<n>] [-pos:<n>] [-sym:<Unit.Name>] [-nolib] [-shared] ' +
        '[-escalate:<pct>] [-family:<name>] [-v]');
      ExitCode := 2;
      Exit;
    end;
    GStudio := GetEnvironmentVariable('BDS');
    GOwnStride := 1;
    GOwnUnitStride := 1;
    GPosStride := 40;
    GLibPosStride := 100;
    GEscalate := 40;
    for var LI := 2 to ParamCount do
    begin
      GArg := ParamStr(LI);
      if GArg.StartsWith('-p:', True) then
        GPlatformGiven := TryParsePlatformName(Copy(GArg, 4, MaxInt), GPlatform)
      else if GArg.StartsWith('-studio:', True) then
        GStudio := Copy(GArg, 9, MaxInt)
      else if GArg.StartsWith('-Lfile:', True) then
      begin
        for var LP in TFile.ReadAllLines(Copy(GArg, 8, MaxInt)) do
          if Trim(LP.Trim([#$FEFF])) <> '' then
            GExtraPaths := GExtraPaths + [Trim(LP.Trim([#$FEFF]))];
      end
      else if GArg.StartsWith('-light:', True) then
        GLightSpecs := GLightSpecs + [Copy(GArg, 8, MaxInt)]
      else if GArg.StartsWith('-ownunits:', True) then
        GOwnUnitStride := Max(1, StrToIntDef(Copy(GArg, 11, MaxInt), 1))
      else if GArg.StartsWith('-own:', True) then
        GOwnStride := Max(1, StrToIntDef(Copy(GArg, 6, MaxInt), 1))
      else if GArg.StartsWith('-pos:', True) then
        GPosStride := StrToIntDef(Copy(GArg, 6, MaxInt), 40)
      else if GArg.StartsWith('-libpos:', True) then
        GLibPosStride := StrToIntDef(Copy(GArg, 9, MaxInt), 100)
      else if GArg.StartsWith('-sym:', True) then
        GSymArgs := GSymArgs + [Copy(GArg, 6, MaxInt)]
      else if SameText(GArg, '-nolib') then
        GNoLib := True
      else if SameText(GArg, '-shared') then
        GShared := True
      else if GArg.StartsWith('-escalate:', True) then
        GEscalate := StrToIntDef(Copy(GArg, 11, MaxInt), 40)
      else if GArg.StartsWith('-family:', True) then
        GOnlyFamilies := GOnlyFamilies + [Copy(GArg, 9, MaxInt)]
      else if SameText(GArg, '-v') then
        GVerbose := True
      else if GArg.StartsWith('-L', True) and (Length(GArg) > 2) then
        GExtraPaths := GExtraPaths + [Copy(GArg, 3, MaxInt)]
      else
      begin
        Writeln(ErrOutput, 'unknown option: ', GArg);
        ExitCode := 2;
        Exit;
      end;
    end;
    if GLightSpecs = nil then
      GLightSpecs := ['lib'];
    GStats := TDictionary<string, TFamilyStat>.Create;
    GFamilyOrder := TList<string>.Create;
    GCosts := TList<TCostRow>.Create;
    try
      Run(TPath.GetFullPath(ParamStr(1)));
    finally
      GCosts.Free;
      GFamilyOrder.Free;
      GStats.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, 'FATAL ', E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
