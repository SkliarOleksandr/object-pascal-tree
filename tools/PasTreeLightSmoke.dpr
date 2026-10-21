program PasTreeLightSmoke;

{ The light-mode query equivalence oracle - gate G7 of light mode
  (docs/library-light-mode.md, "Full answers in light mode").

  Analyzes one project twice in the same process - full, and light (the
  library trees interface-only) - and asks both the SAME questions: every
  public query of TPasNavigator and PasTree.Sema.Lint, over a sample of
  symbols, units, names and positions. Both sides ask through a
  TPasWorkspace (PasTree.Sema.Workspace), exactly as a host does: the light
  workspace meets each question's demand inside the query - promotion,
  a rebuild with the project as parse donor when EnsureFull asks for one, an
  escalation to a full rebuild when that is cheaper - and the full one,
  having nothing light, is the navigator's own call. The oracle therefore
  tests the code path the hosts run. After an escalation the light workspace
  is full for good (decision D9), so the next question gets a fresh light
  one. Answers are compared by IDENTITY - file, line, column, kind, name -
  never by model id (the two closures number their models differently).
  Every family must answer exactly what the full analysis answers, with
  NotSearched = 0.

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
    -find:<query>        a declaration search (FindDeclarations; repeatable);
                         the default library sample is used when none
    -findown:<n>         every n-th own symbol's name searched too (25; 0 =
                         none), on one shared light workspace
    -family:<name>       only this family (repeatable)
    -v                   every difference, not the first few per family

  Exit code 0 when every family is equal with NotSearched = 0, 1 otherwise,
  2 on a usage or load error. }

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
  PasTree.Sema.Lint in '..\source\PasTree.Sema.Lint.pas',
  PasTree.Sema.Workspace in '..\source\PasTree.Sema.Workspace.pas';

type
  { A declaration, by what both analyses agree on (TPasSymbolKey), and its
    text for the report. }
  TSymId = record
    Key: TPasSymbolKey;
    Text: string;
  end;

  TQueryFn = reference to function(AWs: TPasWorkspace): TArray<string>;

  TFamilyStat = record
    Name: string;
    Queries, Equal, Diff, NotSearchedBad, FullRows, LightRows: Integer;
    Samples: TArray<string>;
    // What meeting the family's demands cost the light workspace: the
    // questions whose demand did something (Worked), and its sums.
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
  GFullWS, GLightWS: TPasWorkspace;
  GFull: TPasSemaProject;    // GFullWS.Project: a full one never changes
  GLibs: TArray<string>;     // the navigators' LibraryPaths
  GOwnStride, GOwnUnitStride, GPosStride, GLibPosStride, GEscalate: Integer;
  GFindArgs: TArray<string>; // -find:<query>; the default sample when none
  GFindOwnStride: Integer;   // every n-th own symbol's name searched (0: none)
  GNoLib, GShared, GVerbose: Boolean;
  GStats: TDictionary<string, TFamilyStat>;
  GFamilyOrder: TList<string>;
  GCosts: TList<TCostRow>;
  GCur: TCostRow;            // the cost of the question being asked
  GLightRuns: Integer;       // light analyses run (the first one included)
  GWordMs: Int64;            // the first demand's cost: the word index
  GWordBytes: Int64;
  GResets: Integer;          // light workspaces started again after an escalation

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
  not analyzed - the light workspace's factory. }
function ConfigureProject(ALight: Boolean): TPasSemaProject;
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
  except
    Result.Free;
    raise;
  end;
end;

{ ConfigureProject, analyzed. ADonor: the parse donor, its promotions
  forgotten (the next light project is light again). }
function NewProject(ALight: Boolean; ADonor: TPasSemaProject): TPasSemaProject;
begin
  Result := ConfigureProject(ALight);
  try
    if ADonor <> nil then
    begin
      Result.AdoptParseDonor(ADonor);
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

function NewWorkspace(AProject: TPasSemaProject): TPasWorkspace;
begin
  Result := TPasWorkspace.Create(AProject,
    function: TPasSemaProject
    begin
      Result := ConfigureProject(True);
    end);
  Result.LibraryPaths := GLibs;
end;

{ A fresh light workspace, the current one's project as parse donor (a
  full one after an escalation: its light units are not reused). }
procedure NewLightWorkspace;
var
  LNew: TPasSemaProject;
begin
  if GLightWS = nil then
    LNew := NewProject(True, nil)
  else
    LNew := NewProject(True, GLightWS.Project);
  FreeAndNil(GLightWS);
  GLightWS := NewWorkspace(LNew);
end;

{ ---- identities ----------------------------------------------------------- }

function SymIdOf(AProj: TPasSemaProject; AMid, ASym: Integer;
  out AId: TSymId): Boolean;
begin
  AId := Default(TSymId);
  AId.Key := TPasSymbolKey.Make(AProj, AMid, ASym);
  Result := AId.Key.Valid;
  if Result then
    AId.Text := Format('%s %s(%d,%d)', [AId.Key.Name,
      TPath.GetFileName(AId.Key.DeclFile), AId.Key.Line, AId.Key.Col]);
end;

function SymKey(AProj: TPasSemaProject; AMid, ASym: Integer): string;
var
  LId: TSymId;
begin
  if SymIdOf(AProj, AMid, ASym, LId) then
    Result := Format('%s|%s|%d|%d', [LowerCase(LId.Key.DeclFile),
      LId.Key.Name, LId.Key.Line, LId.Key.Col])
  else if (AMid >= 0) and (AMid < AProj.ModelCount) and (ASym >= 0) and
          (ASym < AProj.Model(AMid).SymCount) then
    // A builtin: by name.
    Result := 'builtin|' + AProj.Model(AMid).Symbols[ASym].NameLower
  else
    Result := '-';
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

// AId in AWs's project now (after the query met its demand).
function Resolved(AWs: TPasWorkspace; const AId: TSymId): Boolean;
var
  LM, LS: Integer;
begin
  Result := AId.Key.Resolve(AWs.Project, LM, LS);
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

procedure Note(const AFamily: string; const AFull, ALight: TArray<string>;
  ANotSearched: Integer; const ALabel: string);
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
  if ANotSearched <> 0 then
  begin
    Inc(LStat.NotSearchedBad);
    if Length(LStat.Samples) < 24 then
      LStat.Samples := LStat.Samples + [Format('%s: NotSearched = %d',
        [ALabel, ANotSearched])];
  end;
  GStats.AddOrSetValue(AFamily, LStat);
end;

{ What the light workspace's last query cost: into GCur and the family. }
procedure NoteCost(const AFamily: string; const AStatus: TPasQueryStatus);
var
  LStat: TFamilyStat;
begin
  Inc(GCur.Rounds, AStatus.Rounds);
  Inc(GCur.Promoted, AStatus.Promoted);
  Inc(GCur.Loaded, AStatus.Loaded);
  Inc(GCur.Preprocessed, AStatus.Preprocessed);
  Inc(GCur.Rebuilds, Ord(AStatus.Rebuilt));
  Inc(GCur.Escalations, Ord(AStatus.Escalated));
  Inc(GCur.Refused, Length(AStatus.Refused));
  Inc(GCur.Ms, AStatus.Ms);
  if GVerbose then
  begin
    for var LR in AStatus.Refused do
      Writeln(ErrOutput, '      refused: ', LR);
    if AStatus.Note <> '' then
      Writeln(ErrOutput, '      ', AStatus.Note);
  end;
  if not GStats.TryGetValue(AFamily, LStat) then
    Exit;
  if (AStatus.Promoted = 0) and (AStatus.Loaded = 0) and
     (AStatus.Preprocessed = 0) and not AStatus.Rebuilt and
     not AStatus.Escalated then
    Exit;
  Inc(LStat.Worked);
  Inc(LStat.Rounds, AStatus.Rounds);
  Inc(LStat.Promoted, AStatus.Promoted);
  Inc(LStat.Loaded, AStatus.Loaded);
  Inc(LStat.Preprocessed, AStatus.Preprocessed);
  Inc(LStat.Rebuilds, Ord(AStatus.Rebuilt));
  Inc(LStat.Escalations, Ord(AStatus.Escalated));
  Inc(LStat.EnsureMs, AStatus.Ms);
  if AStatus.Ms > LStat.MaxMs then
    LStat.MaxMs := AStatus.Ms;
  GStats[AFamily] := LStat;
end;

{ One question to both workspaces. AViaWorkspace: AQuery's last call is a
  workspace query, whose Status is the light answer's NotSearched and cost;
  False - a query with no demand (the inventory's "none" row), asked of
  the workspace's Nav directly. }
procedure Ask(const AFamily, ALabel: string; const AQuery: TQueryFn;
  AViaWorkspace: Boolean = True);
var
  LFull, LLight: TArray<string>;
  LStatus: TPasQueryStatus;
begin
  if not Wanted(AFamily) then
    Exit;
  try
    LFull := AQuery(GFullWS);
  except
    on E: Exception do
      LFull := ['raised ' + E.ClassName + ': ' + E.Message];
  end;
  LStatus := Default(TPasQueryStatus);
  try
    LLight := AQuery(GLightWS);
    if AViaWorkspace then
      LStatus := GLightWS.Status;
  except
    on E: Exception do
      LLight := ['raised ' + E.ClassName + ': ' + E.Message];
  end;
  Note(AFamily, LFull, LLight, LStatus.NotSearched, ALabel);
  NoteCost(AFamily, LStatus);
  // An escalation leaves the light workspace full for good (D9): every
  // later question would compare full with full. A light one again.
  if GLightWS.Escalated then
  begin
    NewLightWorkspace;
    Inc(GResets);
  end;
end;

{ ---- the questions -------------------------------------------------------- }

procedure AskSymbol(const AId: TSymId; AOwn: Boolean = False);
var
  LKind: TSemaSymbolKind;
  LMid, LSym: Integer;
  LIsClass, LIsRoutine, LIsIntf: Boolean;
  LLabel: string;
  LMembers: TArray<TPasSymbolKey>;
begin
  if not AId.Key.Resolve(GFull, LMid, LSym) then
    Exit;
  LKind := GFull.Model(LMid).Symbols[LSym].Kind;
  LIsClass := (LKind = skType) and
    (GFull.Model(LMid).Symbols[LSym].TypeCat = tcClass);
  LIsIntf := (LKind = skType) and
    (GFull.Model(LMid).Symbols[LSym].TypeCat = tcInterface);
  LIsRoutine := LKind = skRoutine;
  LLabel := AId.Text;
  Ask('references', LLabel,
    function(AWs: TPasWorkspace): TArray<string>
    begin
      Result := HitsText(AWs.FindReferences(AId.Key, True));
      if not Resolved(AWs, AId) then
        Result := One('unresolved');
    end);
  if LKind in [skVar, skField, skProperty] then
    Ask('assignments', LLabel,
      function(AWs: TPasWorkspace): TArray<string>
      begin
        Result := HitsText(AWs.FindAssignments(AId.Key));
        if not Resolved(AWs, AId) then
          Result := One('unresolved');
      end);
  if LIsClass then
  begin
    Ask('creations', LLabel,
      function(AWs: TPasWorkspace): TArray<string>
      begin
        Result := HitsText(AWs.FindCreations(AId.Key));
        if not Resolved(AWs, AId) then
          Result := One('unresolved');
      end);
    Ask('destructions', LLabel,
      function(AWs: TPasWorkspace): TArray<string>
      begin
        Result := HitsText(AWs.FindDestructions(AId.Key));
        if not Resolved(AWs, AId) then
          Result := One('unresolved');
      end);
  end;
  // A type's members at once: CollectReferencesOfAll, the members by the
  // keys both closures agree on.
  if (LKind = skType) and
     (GFull.Model(LMid).Symbols[LSym].MemberScope <> NIL_SCOPE) then
  begin
    LMembers := nil;
    var LModel := GFull.Model(LMid);
    for var LX := 0 to LModel.SymCount - 1 do
      if LModel.Symbols[LX].Scope = LModel.Symbols[LSym].MemberScope then
      begin
        var LK := TPasSymbolKey.Make(GFull, LMid, LX);
        if LK.Valid then
          LMembers := LMembers + [LK];
      end;
    Ask('references-of-all', LLabel,
      function(AWs: TPasWorkspace): TArray<string>
      begin
        Result := HitsText(AWs.CollectReferencesOfAll(LMembers));
        if not Resolved(AWs, AId) then
          Result := One('unresolved');
      end);
  end;
  // The hierarchy family, the library file's bodies, the rename plan.
  if LKind = skType then
    Ask('descendants', LLabel,
      function(AWs: TPasWorkspace): TArray<string>
      begin
        Result := nil;
        for var LH in AWs.FindDescendants(AId.Key) do
          Result := Result + [HitText(LH.Hit) + '|' + LH.TypeName + '|' +
            LH.ParentTypeName + '|' + IntToStr(Ord(LH.Kind)) + '|' +
            IntToStr(LH.Depth)];
      end);
  if LIsIntf then
    Ask('interface-implementors', LLabel,
      function(AWs: TPasWorkspace): TArray<string>
      begin
        Result := nil;
        for var LH in AWs.FindInterfaceImplementors(AId.Key) do
          Result := Result + [HitText(LH.Hit) + '|' + LH.TypeName + '|' +
            LH.ViaTypeName + '|' + IntToStr(Ord(LH.Kind))];
      end);
  // A class property has the overrides question too: its bare
  // redeclarations (`property Text;`) below it. Asked since 0.121.2 - its
  // demand had lost the class, and no question here asked it.
  if LKind = skProperty then
    Ask('overrides', LLabel,
      function(AWs: TPasWorkspace): TArray<string>
      begin
        Result := nil;
        for var LH in AWs.FindOverrides(AId.Key) do
          Result := Result + [HitText(LH.Hit) + '|' + LH.TypeName + '|' +
            IntToStr(Ord(LH.Kind))];
      end);
  if LIsRoutine then
  begin
    Ask('overrides', LLabel,
      function(AWs: TPasWorkspace): TArray<string>
      begin
        Result := nil;
        for var LH in AWs.FindOverrides(AId.Key) do
          Result := Result + [HitText(LH.Hit) + '|' + LH.TypeName + '|' +
            IntToStr(Ord(LH.Kind))];
      end);
    Ask('implementations', LLabel,
      function(AWs: TPasWorkspace): TArray<string>
      begin
        Result := nil;
        for var LH in AWs.FindImplementations(AId.Key) do
          Result := Result + [HitText(LH.Hit) + '|' + LH.TypeName + '|' +
            LH.ViaTypeName + '|' + IntToStr(Ord(LH.Kind))];
      end);
    Ask('rename-family', LLabel,
      function(AWs: TPasWorkspace): TArray<string>
      var
        LFamily: TArray<TPasRenameFamilyMember>;
        LErr: string;
      begin
        Result := nil;
        if not AWs.RenameFamily(AId.Key, LFamily, LErr) then
          Exit(One('refused: ' + LErr));
        for var LMem in LFamily do
          Result := Result + [HitText(LMem.Hit) + '|' + LMem.TypeName + '|' +
            IntToStr(Ord(LMem.Why))];
      end);
    Ask('routine-impl', LLabel,
      function(AWs: TPasWorkspace): TArray<string>
      var
        LM, LLine, LCol: Integer;
        LFile: string;
      begin
        Result := nil;
        var LNode := AWs.RoutineImplNode(AId.Key, LM);
        if (LNode <> NIL_NODE) and AWs.Project.NodeSite(LM, LNode, LFile,
             LLine, LCol) then
          Result := [Format('%s|%d|%d', [LowerCase(LFile), LLine, LCol])];
      end);
  end;
  // A rename of an own symbol (a library one is refused in both modes).
  if AOwn and (LKind in [skType, skVar, skConst, skField, skRoutine,
     skProperty]) then
    Ask('rename-plan', LLabel,
      function(AWs: TPasWorkspace): TArray<string>
      var
        LEdits: TArray<TPasRenameEdit>;
        LCarried: TArray<TPasCarriedRename>;
        LFamily: TArray<TPasRenameFamilyMember>;
        LErr: string;
      begin
        Result := nil;
        if not AWs.PlanRename(AId.Key, AId.Key.Name + 'Rn', LEdits, LCarried,
             LFamily, LErr) then
          Exit(One('refused: ' + LErr));
        for var LE in LEdits do
          Result := Result + [Format('%s|%d|%d|%s|%s', [LowerCase(LE.FilePath),
            LE.Line, LE.Col, LE.OldText, LE.NewText])];
      end);
  // No demand: asked of the navigator.
  Ask('decl-hit', LLabel,
    function(AWs: TPasWorkspace): TArray<string>
    var
      LM, LS: Integer;
      LHit: TPasRefHit;
    begin
      Result := nil;
      if AId.Key.Resolve(AWs.Project, LM, LS) and AWs.Nav.DeclHit(LM, LS, LHit) then
        Result := [HitText(LHit)];
    end, False);
  Ask('form-sites', LLabel,
    function(AWs: TPasWorkspace): TArray<string>
    var
      LM, LS: Integer;
    begin
      Result := nil;
      if AId.Key.Resolve(AWs.Project, LM, LS) then
        for var LSite in AWs.Nav.FindFormSites(LM, LS) do
          Result := Result + [Format('%s|%d|%d|%d', [LowerCase(LSite.FilePath),
            LSite.Line, LSite.Col, Ord(LSite.Kind)])];
    end, False);
end;

function TokensText(const ATokens: TArray<TPasSemanticToken>): TArray<string>;
begin
  Result := nil;
  for var LT in ATokens do
    Result := Result + [Format('%d|%d|%s', [LT.RawToken, Ord(LT.Kind),
      BoolToStr(LT.IsDecl, True)])];
end;

{ Every position question at (ALine, ACol) of model AMid, as text. }
function PositionText(ANav: TPasNavigator; AMid, ALine, ACol: Integer): TArray<string>;
var
  LIdent: TPasNavIdent;
  LTarget: TPasNavTarget;
  LTMid, LSym, LStart, LLen, LRaw: Integer;
  LName: string;
begin
  Result := nil;
  if ANav.IdentAt(AMid, ALine, ACol, LIdent) then
  begin
    Result := Result + [Format('ident|%d|%d|%d|%s', [LIdent.Line,
      LIdent.ColFrom, LIdent.ColTo, LIdent.Name])];
    if ANav.ResolveDecl(AMid, LIdent.Node, LTarget) then
      Result := Result + ['decl|' + TargetText(LTarget)];
  end;
  if ANav.SymbolAt(AMid, ALine, ACol, LTMid, LSym, LName) then
    Result := Result + ['symbol|' + SymKey(ANav.Project, LTMid, LSym)];
  if ANav.GotoDeclaration(AMid, ALine, ACol, LTarget) then
    Result := Result + ['goto-decl|' + TargetText(LTarget)];
  if ANav.MethodAt(AMid, ALine, ACol, LTMid, LSym, LName) then
    Result := Result + ['method|' + SymKey(ANav.Project, LTMid, LSym)];
  if ANav.InterfaceMethodAt(AMid, ALine, ACol, LTMid, LSym, LName) then
    Result := Result + ['intf-method|' + SymKey(ANav.Project, LTMid, LSym)];
  if ANav.InterfaceAt(AMid, ALine, ACol, LTMid, LSym, LName) then
    Result := Result + ['intf|' + SymKey(ANav.Project, LTMid, LSym)];
  if ANav.TypeAt(AMid, ALine, ACol, LTMid, LSym, LName) then
    Result := Result + ['type|' + SymKey(ANav.Project, LTMid, LSym)];
  if ANav.AssignableAt(AMid, ALine, ACol, LTMid, LSym, LName) then
    Result := Result + ['assignable|' + SymKey(ANav.Project, LTMid, LSym)];
  if ANav.ClassAt(AMid, ALine, ACol, LTMid, LSym, LName) then
    Result := Result + ['class|' + SymKey(ANav.Project, LTMid, LSym)];
  if ANav.UnitAt(AMid, ALine, ACol, LTMid, LName) then
    Result := Result + ['unit|' + LowerCase(ANav.Project.ModelFile(LTMid)) + '|' + LName];
  if ANav.BuiltinNameAt(AMid, ALine, ACol, LName) then
    Result := Result + ['builtin|' + LName];
  if ANav.DefineAt(AMid, ALine, ACol, LName, LRaw) then
    Result := Result + ['define|' + LName];
  if ANav.DefineSpanAt(AMid, ALine, ACol, LStart, LLen) then
    Result := Result + [Format('define-span|%d|%d', [LStart, LLen])];
  if ANav.IfNameAt(AMid, ALine, ACol, LName, LStart, LLen, LTMid, LSym) then
    Result := Result + ['if-name|' + LName + '|' + SymKey(ANav.Project, LTMid, LSym)];
  if ANav.GotoDefine(AMid, ALine, ACol, LTarget) then
    Result := Result + ['goto-define|' + TargetText(LTarget)];
  if ANav.GotoBareInherited(AMid, ALine, ACol, LTarget) then
    Result := Result + ['bare-inherited|' + TargetText(LTarget)];
  if ANav.GotoImplementation(AMid, ALine, ACol, LTarget) then
    Result := Result + ['goto-impl|' + TargetText(LTarget)];
  for var LD in ANav.DefinesAt(AMid, ALine, ACol) do
    Result := Result + [Format('defines-at|%s|%d|%s', [LD.Name,
      Ord(LD.Origin), BoolToStr(LD.Active, True)])];
  for var LO in ANav.OptionsAt(AMid, ALine, ACol) do
    Result := Result + [Format('options-at|%s|%s|%d', [LO.Name,
      LO.Value, Ord(LO.Origin)])];
end;

{ A unit's questions: unit-level, then every n-th position of its text
  (AStride). ALibrary: a library file - the one-library-file family, the
  file made fully analyzed by the workspace (InFile, At); an own unit's
  unit-level questions have no demand. }
procedure AskUnit(const AFile: string; ALibrary: Boolean = False;
  AStride: Integer = -1);
var
  LFile, LText, LPrefix: string;
  LLines: TArray<string>;
  LCount: Integer;
begin
  LFile := AFile;
  if AStride < 0 then
    AStride := GPosStride;
  LPrefix := '';
  // A unit's references, its own or a library one: the `uses` entries of
  // units nobody loaded and the qualifiers in library bodies (0.122.0 -
  // asked of the navigator, "none needed", before).
  Ask('unit-references', TPath.GetFileName(LFile),
    function(AWs: TPasWorkspace): TArray<string>
    begin
      Result := HitsText(AWs.FindUnitReferences(LFile));
      if AWs.Nav.ModelIdOf(LFile) < 0 then
        Result := One('unresolved');
    end);
  if ALibrary then
  begin
    LPrefix := 'library-file-';
    Ask('library-file-tokens', TPath.GetFileName(LFile),
      function(AWs: TPasWorkspace): TArray<string>
      begin
        Result := TokensText(AWs.SemanticTokens(LFile));
      end);
    Ask('library-file-outline', TPath.GetFileName(LFile),
      function(AWs: TPasWorkspace): TArray<string>
      begin
        // Every routine's implementation, where the unit declares one.
        Result := AWs.InFile<TArray<string>>(LFile,
          function(ANav: TPasNavigator; AMid: Integer): TArray<string>
          var
            LLine, LCol: Integer;
            LSite: string;
          begin
            Result := nil;
            var LM := ANav.Project.Model(AMid);
            for var LS := 0 to LM.SymCount - 1 do
              if LM.Symbols[LS].Kind = skRoutine then
              begin
                var LNode := ANav.RoutineImplNode(AMid, LS);
                if (LNode <> NIL_NODE) and ANav.Project.NodeSite(AMid, LNode,
                     LSite, LLine, LCol) then
                  Result := Result + [Format('%s|%s|%d|%d', [LM.Symbols[LS].Name,
                    LowerCase(LSite), LLine, LCol])];
              end;
          end);
      end);
  end
  else
  begin
    Ask('unit-decl', TPath.GetFileName(LFile),
      function(AWs: TPasWorkspace): TArray<string>
      var
        LHit: TPasRefHit;
        LTarget: TPasNavTarget;
      begin
        Result := nil;
        var LMid := AWs.Nav.ModelIdOf(LFile);
        if LMid < 0 then
          Exit(One('unresolved'));
        if AWs.Nav.UnitDeclHit(LMid, LHit) then
          Result := Result + [HitText(LHit)];
        if AWs.Nav.UnitHeaderTarget(LMid, LTarget) then
          Result := Result + [TargetText(LTarget)];
      end, False);
    Ask('semantic-tokens', TPath.GetFileName(LFile),
      function(AWs: TPasWorkspace): TArray<string>
      begin
        Result := TokensText(AWs.SemanticTokens(LFile));
      end);
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
            function(AWs: TPasWorkspace): TArray<string>
            begin
              Result := AWs.At<TArray<string>>(LFile, LL, LC,
                function(ANav: TPasNavigator; AMid: Integer): TArray<string>
                begin
                  Result := PositionText(ANav, AMid, LL, LC);
                end);
            end);
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
  // The uses lint.
  Ask('lint-unused', 'own units',
    function(AWs: TPasWorkspace): TArray<string>
    begin
      Result := nil;
      for var LR in AWs.FindUnusedUses(GOwnFiles) do
        Result := Result + [HitText(LR.Hit) + '|' + LR.UnitName + '|' +
          BoolToStr(LR.InInterface, True) + '|' + string.Join('; ', LR.Doubts)];
    end);
  Ask('lint-unreferenced', 'own units',
    function(AWs: TPasWorkspace): TArray<string>
    begin
      Result := nil;
      for var LR in AWs.FindUnreferencedUnits(GOwnFiles) do
        Result := Result + [HitText(LR.Hit) + '|' + LR.UnitName + '|' +
          string.Join(', ', LR.ListedBy) + '|' + string.Join('; ', LR.Doubts)];
    end);
  Ask('project-outline', 'own units',
    function(AWs: TPasWorkspace): TArray<string>
    begin
      Result := nil;
      for var LE in AWs.Nav.ProjectOutline(OwnMids(AWs.Nav)) do
        Result := Result + [LE.Head + '|' + LE.Owner + '|' + LE.Name + '|' +
          LE.UnitName + '|' + LE.Detail];
    end, False);
  Ask('defines', 'all',
    function(AWs: TPasWorkspace): TArray<string>
    begin
      Result := nil;
      for var LD in AWs.FindDefines do
        Result := Result + [HitText(LD.Hit) + '|' + LD.Name + '|' +
          IntToStr(Ord(LD.Origin)) + '|' + BoolToStr(LD.Active, True)];
    end);
  for var LName in ['MSWINDOWS', 'WIN64', 'WIN32', 'DEBUG', 'RELEASE',
    'UNICODE', 'CPUX64', 'NEXTGEN', 'PUREPASCAL', 'X86ASM', 'POSIX',
    'LINUX', 'ASSEMBLER'] do
    Ask('define-references', LName,
      function(AWs: TPasWorkspace): TArray<string>
      begin
        Result := ['defined|' + BoolToStr(AWs.Nav.IsProjectDefined(LName), True)];
        // The workspace query last: its Status is the answer's.
        for var LD in AWs.FindDefineReferences(LName) do
          Result := Result + [HitText(LD.Hit) + '|' + IntToStr(Ord(LD.Kind)) +
            '|' + BoolToStr(LD.Active, True)];
      end);
  for var LName in ['Length', 'Inc', 'Exit', 'SizeOf', 'Assigned', 'High',
    'Ord', 'Copy', 'Integer', 'string'] do
    Ask('builtin-references', LName,
      function(AWs: TPasWorkspace): TArray<string>
      begin
        Result := HitsText(AWs.FindBuiltinReferences(LName));
      end);
end;

{ ---- declarations by name (the find family, 0.124.0) ----------------------- }

function DeclHitsText(const AHits: TArray<TPasDeclHit>): TArray<string>;
begin
  SetLength(Result, Length(AHits));
  for var LI := 0 to High(AHits) do
    Result[LI] := HitText(AHits[LI].Hit) + '|' + AHits[LI].Name + '|' +
      AHits[LI].Inherits + IfThen(AHits[LI].IsUnit, '|unit', '');
end;

{ One search, each on a fresh light workspace unless -shared (its cost is
  its own, and an earlier search's promotions do not make it equal). }
procedure AskFind(const AQuery: string; AFresh: Boolean);
begin
  if not Wanted('find') then
    Exit;
  if AFresh and not GShared then
    NewLightWorkspace;
  GCur := Default(TCostRow);
  GCur.Text := 'find ' + AQuery;
  var LSW := TStopwatch.StartNew;
  Ask('find', AQuery,
    function(AWs: TPasWorkspace): TArray<string>
    begin
      Result := DeclHitsText(AWs.FindDeclarations(AQuery));
    end);
  GCosts.Add(GCur);
  Writeln(ErrOutput, Format('  find %s: %d ms (ensure %d ms, %d promoted, ' +
    '%d loaded, %d escalation(s))', [AQuery, LSW.ElapsedMilliseconds, GCur.Ms,
    GCur.Promoted, GCur.Loaded, GCur.Escalations]));
end;

{ The library sample of names (-find:<query> replaces it), then every n-th
  own symbol's name (-findown:<n>) on one shared light workspace. }
procedure AskFinds(const AOwnNames: TArray<string>);
var
  LQueries: TArray<string>;
begin
  LQueries := GFindArgs;
  if LQueries = nil then
    LQueries := ['TAnonymousThread', 'TRegGroups', 'TPropFixup', 'Min',
      'System.Classes.TList', 'TStringList.Add', 'TStringList.BeginUpdate',
      'Classes.TThread.Synchronize', 'TComponent.Create', 'System.VarUtils',
      'Winapi.ShLwApi', 'NoSuchNameAnywhere', '*Fixup*', '*Anonymous*',
      '*.SaveToStream', '*Form.Close*', '*GetCurrent*', '*Utils', '*Add*',
      '*Create*'];
  for var LQ in LQueries do
    AskFind(LQ, True);
  if not GShared then
    NewLightWorkspace;
  for var LQ in AOwnNames do
    AskFind(LQ, False);
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
      'yes', LStat.Queries, LStat.Equal, LStat.Diff, LStat.NotSearchedBad,
      LStat.FullRows, LStat.LightRows]));
    if (LStat.Diff > 0) or (LStat.NotSearchedBad > 0) then
      Result := False;
  end;
  for var LName in GFamilyOrder do
  begin
    LStat := GStats[LName];
    if LStat.Samples = nil then
      Continue;
    Writeln('--- ', LStat.Name, ': DIFFERENCES (a defect)');
    for var LS in LStat.Samples do
      Writeln('  ', LS);
  end;
  Writeln('--- cost per family (light workspace: the questions whose demand ' +
    'did something; an escalation''s full rebuild is timed in) ---');
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
  Writeln('--- cost per question (light workspace) ---');
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
  LBefore: Int64;
  LFindOwn: TArray<string>;
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
    GLibs := LightTrees;
    LSW := TStopwatch.StartNew;
    GFullWS := NewWorkspace(NewProject(False, nil));
    GFull := GFullWS.Project;
    Writeln(ErrOutput, Format('full: %d units in %d ms', [GFull.ModelCount,
      LSW.ElapsedMilliseconds]));
    LSW := TStopwatch.StartNew;
    NewLightWorkspace;
    Writeln(ErrOutput, Format('light: %d units (%d light) in %d ms',
      [GLightWS.Project.ModelCount, GLightWS.Project.LightCount,
      LSW.ElapsedMilliseconds]));
    // The word index's first build: a demand that needs it.
    LBefore := AllocatedBytes;
    LSW := TStopwatch.StartNew;
    GLightWS.Project.DemandOf(nil);
    GWordMs := LSW.ElapsedMilliseconds;
    GWordBytes := Int64(AllocatedBytes) - LBefore;
    // The project's own units: its listed files with a model on both sides.
    LOwnFiles := nil;
    for var LF in GDProj.Files do
      if (GFull.ModelIdOf(LF) >= 0) and (GLightWS.Project.ModelIdOf(LF) >= 0) then
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
            if (GFindOwnStride > 0) and (LUnitIdx mod GFindOwnStride = 0) and
               not MatchText(LId.Key.Name, LFindOwn) then
              LFindOwn := LFindOwn + [LId.Key.Name];
          end;
      end;
      Writeln(ErrOutput, Format('own symbols asked: %d', [LOwnIds.Count]));
      GCur := Default(TCostRow);
      GCur.Text := Format('own symbols (%d)', [LOwnIds.Count]);
      LSW := TStopwatch.StartNew;
      for var LI := 0 to LOwnIds.Count - 1 do
        AskSymbol(LOwnIds[LI], True);
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
        AskUnit(LF);
    end;
    GCosts.Add(GCur);
    Writeln(ErrOutput, Format('own units and positions: %d ms',
      [LSW.ElapsedMilliseconds]));
    // 4. The library sample, each on a fresh light workspace unless -shared.
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
          NewLightWorkspace;
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
    //    asked about on a fresh light workspace.
    if not GNoLib then
    begin
      var LDone := TDictionary<string, Boolean>.Create;
      try
        for LId in LLibIds do
          if LDone.TryAdd(LowerCase(LId.Key.MainFile), True) and
             (GLightWS.Project.IsLightFile(LId.Key.MainFile) or
              (GLightWS.Project.ModelIdOf(LId.Key.MainFile) < 0)) then
          begin
            if not GShared then
              NewLightWorkspace;
            GCur := Default(TCostRow);
            GCur.Text := 'file ' + TPath.GetFileName(LId.Key.MainFile);
            LSW := TStopwatch.StartNew;
            AskUnit(LId.Key.MainFile, True, GLibPosStride);
            GCosts.Add(GCur);
            Writeln(ErrOutput, Format('  %s: %d ms (ensure %d ms, %d promoted)',
              [GCur.Text, LSW.ElapsedMilliseconds, GCur.Ms, GCur.Promoted]));
          end;
      finally
        LDone.Free;
      end;
    end;
    // 6. Declarations by name: the library sample, each on a fresh light
    //    workspace, then the own names.
    LSW := TStopwatch.StartNew;
    AskFinds(LFindOwn);
    Writeln(ErrOutput, Format('find: %d ms', [LSW.ElapsedMilliseconds]));
    if not Report then
      ExitCode := 1;
  finally
    FreeAndNil(GLightWS);
    FreeAndNil(GFullWS);
    GFull := nil;
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
        '[-escalate:<pct>] [-find:<query>] [-findown:<n>] [-family:<name>] [-v]');
      ExitCode := 2;
      Exit;
    end;
    GStudio := GetEnvironmentVariable('BDS');
    GOwnStride := 1;
    GOwnUnitStride := 1;
    GPosStride := 40;
    GLibPosStride := 100;
    GEscalate := 40;
    GFindOwnStride := 25;
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
      else if GArg.StartsWith('-findown:', True) then
        GFindOwnStride := StrToIntDef(Copy(GArg, 10, MaxInt), 25)
      else if GArg.StartsWith('-find:', True) then
        GFindArgs := GFindArgs + [Copy(GArg, 7, MaxInt)]
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
