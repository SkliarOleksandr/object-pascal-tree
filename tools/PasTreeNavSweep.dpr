program PasTreeNavSweep;

{ Entry-point x model-state sweep (gate T1 of the 2026-09 audit plan): every
  public caret entry point of TPasNavigator, TPasCompletion (CaretAt,
  CompleteAt, CallAt), TPasFormBinder and PasModuleOutline, at random and at
  edge carets of a sample of files, in each state a host leaves a project in:

    full       - just analyzed
    edited     - a buffer mutated by a random edit (a span cut, a fragment
                 typed, the text truncated) and AnalyzeModuleOnly run over it,
                 accepted or refused; the original text is put back after
    textdemoted - DemoteText: the text layer of every unkept model freed
    released   - ReleaseTransientMaps
    demoted    - DemoteClosedUnits

  Every symbol, unit, builtin and define a caret answers with is then asked
  for its references, declaration, overrides, implementations, rename plan
  and form sites. Any exception out of any call is a finding: the run goes on,
  and the findings are printed grouped by entry point and exception, each with
  its first state, file and caret. Exit code 1 when there is one.

  Usage: PasTreeNavSweep <dir|file.dpr|file.dpk>
           [-p:<platform>] [-L<dir>]... [-studio:<dir>]
           [-seed:N] [-files:N] [-carets:N] [-mutants:N] [-states:a,b,...]

  A directory is analyzed whole (AnalyzeDirectory) and every unit in it is a
  candidate file; a project file is analyzed with AnalyzeProject over its
  directory, -L paths and the Studio source trees, and the candidates are the
  units under its directory. Half the sampled files are KEPT (a host's open
  editors: completion is asked there), half are not (navigation only - the
  navigator hydrates what it needs).

  Build it like the other tools, checked: from tools\,
    dcc64 -B -Q -$R+ -$Q+ -NSSystem;Winapi;System.Win -U..\source
      -N0..\out\dcu\win64g -Eoutg PasTreeNavSweep.dpr }

{$APPTYPE CONSOLE}
{$MAXSTACKSIZE $01000000}   // 16 MB per thread: README, "The stack every host should reserve"

uses
  System.SysUtils,
  System.Classes,
  System.Math,
  System.Types,
  System.Generics.Defaults,
  System.Diagnostics,
  System.IOUtils,
  System.Generics.Collections,
  PasTree.Types,
  PasTree.Platforms,
  PasTree.Ast,
  PasTree.Outline,
  PasTree.Project,
  PasTree.Sema.Model,
  PasTree.Sema.Project,
  PasTree.Sema.Nav,
  PasTree.Sema.Dfm,
  PasTree.Sema.Complete;

type
  TFinding = record
    Count: Integer;
    First: string;   // state, file:line:col of the first occurrence
  end;

var
  GProj: TPasSemaProject;
  GNav: TPasNavigator;
  GBinder: TPasFormBinder;
  GFindings: TDictionary<string, TFinding>;
  GCalls: Int64;
  GState, GSite: string;
  GSlowest: Double;
  GSlowestAt: string;
  GKept, GFree: TArray<Integer>;      // sampled model ids, kept / not kept
  GTexts: TDictionary<Integer, TArray<string>>;   // mid -> lines as swept
  GCarets, GMutants: Integer;

{ One call: counted, timed, and an exception out of it recorded rather than
  ending the run. }
procedure Probe(const AEntry: string; const ACall: TProc);
var
  LKey: string;
  LFind: TFinding;
  LSW: TStopwatch;
begin
  Inc(GCalls);
  LSW := TStopwatch.StartNew;
  try
    ACall();
  except
    on E: Exception do
    begin
      LKey := AEntry + ' | ' + E.ClassName + ': ' + Copy(E.Message, 1, 120);
      if not GFindings.TryGetValue(LKey, LFind) then
      begin
        LFind.Count := 0;
        LFind.First := GState + ' ' + GSite;
      end;
      Inc(LFind.Count);
      GFindings.AddOrSetValue(LKey, LFind);
    end;
  end;
  if LSW.Elapsed.TotalMilliseconds > GSlowest then
  begin
    GSlowest := LSW.Elapsed.TotalMilliseconds;
    GSlowestAt := AEntry + ' ' + GState + ' ' + GSite;
  end;
end;

function LinesOf(AMid: Integer): TArray<string>;
begin
  if not GTexts.TryGetValue(AMid, Result) then
  begin
    try
      Result := TFile.ReadAllText(GProj.ModelFile(AMid)).Split([#13#10, #10]);
    except
      Result := nil;   // a .dcu-backed or vanished file: edge carets only
    end;
    GTexts.Add(AMid, Result);
  end;
end;

{ Everything asked of one symbol a caret answered with. }
procedure SweepSymbol(ATMid, ASym: Integer);
begin
  if (ATMid < 0) or (ASym < 0) then
    Exit;
  Probe('FindReferences', procedure begin GNav.FindReferences(ATMid, ASym, True, True); end);
  Probe('FindFormSites', procedure begin GNav.FindFormSites(ATMid, ASym); end);
  Probe('DeclHit', procedure var H: TPasRefHit; begin GNav.DeclHit(ATMid, ASym, H); end);
  Probe('PlanRename', procedure
    var E: TArray<TPasRenameEdit>; C: TArray<TPasCarriedRename>;
      F: TArray<TPasRenameFamilyMember>; Err: string;
    begin GNav.PlanRename(ATMid, ASym, 'SweepRenamed', E, C, F, Err); end);
  Probe('FormRoleOf', procedure begin GNav.FormRoleOf(ATMid, ASym); end);
  Probe('RoutineImplNode', procedure begin GNav.RoutineImplNode(ATMid, ASym); end);
  Probe('FindOverrides', procedure begin GNav.FindOverrides(ATMid, ASym); end);
  Probe('RenameFamily', procedure
    var F: TArray<TPasRenameFamilyMember>; Err: string;
    begin GNav.RenameFamily(ATMid, ASym, F, Err); end);
  Probe('FindImplementations', procedure begin GNav.FindImplementations(ATMid, ASym); end);
  Probe('FindInterfaceImplementors', procedure begin GNav.FindInterfaceImplementors(ATMid, ASym); end);
  Probe('FindDescendants', procedure begin GNav.FindDescendants(ATMid, ASym); end);
  Probe('FindAssignments', procedure begin GNav.FindAssignments(ATMid, ASym); end);
  Probe('FindCreations', procedure begin GNav.FindCreations(ATMid, ASym); end);
  Probe('FindDestructions', procedure begin GNav.FindDestructions(ATMid, ASym); end);
  Probe('Binder.SitesOf', procedure
    var S: TArray<TPasFormSite>; Err: string;
    begin
      S := GBinder.SitesOf(ATMid, ASym, True, Err);
      GBinder.RenameRefusal(ATMid, ASym, 'SweepRenamed', S);
    end);
  Probe('Binder.RoleOf', procedure begin GBinder.RoleOf(ATMid, ASym); end);
end;

{ Every caret entry point at (ALine, ACol) of AMid. ADeep: also sweep what
  they answered with (capped per file by the caller - a reference search is
  the expensive half). }
procedure SweepCaret(AMid, ALine, ACol: Integer; ADeep, AComplete: Boolean);
var
  LT, LS, LUid, LRaw, LA, LB: Integer;
  LName, LFile: string;
  LIdent: TPasNavIdent;
  LTarget: TPasNavTarget;
  LSyms: TList<TPair<Integer, Integer>>;
  LUnits: TList<Integer>;
  LNames, LDefines: TList<string>;
begin
  GSite := Format('%s:%d:%d (mid %d)', [ExtractFileName(GProj.ModelFile(
    Max(0, Min(AMid, GProj.ModelCount - 1)))), ALine, ACol, AMid]);
  if (AMid >= 0) and (AMid < GProj.ModelCount) then
    LFile := GProj.ModelFile(AMid)
  else
    LFile := '';
  LSyms := TList<TPair<Integer, Integer>>.Create;
  LUnits := TList<Integer>.Create;
  LNames := TList<string>.Create;
  LDefines := TList<string>.Create;
  try
    Probe('IdentAt/ResolveDecl', procedure
      begin
        if GNav.IdentAt(AMid, ALine, ACol, LIdent) and (LIdent.Node >= 0) then
          GNav.ResolveDecl(AMid, LIdent.Node, LTarget);
      end);
    Probe('SymbolAt', procedure
      begin
        if GNav.SymbolAt(AMid, ALine, ACol, LT, LS, LName) then
          LSyms.Add(TPair<Integer, Integer>.Create(LT, LS));
      end);
    Probe('SymbolAtFile', procedure
      begin GNav.SymbolAtFile(AMid, LFile, ALine, ACol, LT, LS, LName); end);
    Probe('UnitAt', procedure
      begin
        if GNav.UnitAt(AMid, ALine, ACol, LUid, LName) then
          LUnits.Add(LUid);
      end);
    Probe('BuiltinNameAt', procedure
      begin
        if GNav.BuiltinNameAt(AMid, ALine, ACol, LName) then
          LNames.Add(LName);
        GNav.BuiltinNameAt(AMid, ALine, ACol, LName, LT, LS);
      end);
    Probe('DefineAt', procedure
      begin
        if GNav.DefineAt(AMid, ALine, ACol, LName, LRaw) then
          LDefines.Add(LName);
      end);
    Probe('DefineSpanAt', procedure begin GNav.DefineSpanAt(AMid, ALine, ACol, LA, LB); end);
    Probe('IfNameAt', procedure
      begin GNav.IfNameAt(AMid, ALine, ACol, LName, LA, LB, LT, LS); end);
    Probe('GotoDefine', procedure begin GNav.GotoDefine(AMid, ALine, ACol, LTarget); end);
    Probe('DefinesAt', procedure begin GNav.DefinesAt(AMid, ALine, ACol); end);
    Probe('MethodAt', procedure
      begin
        if GNav.MethodAt(AMid, ALine, ACol, LT, LS, LName) then
          LSyms.Add(TPair<Integer, Integer>.Create(LT, LS));
      end);
    Probe('InterfaceMethodAt', procedure
      begin GNav.InterfaceMethodAt(AMid, ALine, ACol, LT, LS, LName); end);
    Probe('InterfaceAt', procedure
      begin
        if GNav.InterfaceAt(AMid, ALine, ACol, LT, LS, LName) then
          LSyms.Add(TPair<Integer, Integer>.Create(LT, LS));
      end);
    Probe('TypeAt', procedure begin GNav.TypeAt(AMid, ALine, ACol, LT, LS, LName); end);
    Probe('AssignableAt', procedure
      begin GNav.AssignableAt(AMid, ALine, ACol, LT, LS, LName); end);
    Probe('ClassAt', procedure
      begin
        if GNav.ClassAt(AMid, ALine, ACol, LT, LS, LName) then
          LSyms.Add(TPair<Integer, Integer>.Create(LT, LS));
      end);
    Probe('GotoImplementation', procedure
      begin GNav.GotoImplementation(AMid, ALine, ACol, LTarget); end);
    Probe('GotoDeclaration', procedure
      begin GNav.GotoDeclaration(AMid, ALine, ACol, LTarget); end);
    Probe('GotoBareInherited', procedure
      begin GNav.GotoBareInherited(AMid, ALine, ACol, LTarget); end);
    if AComplete then
      Probe('Completion', procedure
        var
          LC: TPasCompletion;
          LCaret: TPasCaretInfo;
          LCtx: TPasComplContext;
          LItems: TArray<TPasComplItem>;
          LCall: TPasCallInfo;
        begin
          LC := TPasCompletion.Create(GProj.Model(AMid), GProj, AMid);
          try
            if LC.CaretAt(ALine, ACol, LCaret) then
              LC.ClassifyAt(LCaret);
            if LC.CompleteAt(ALine, ACol, LCaret, LCtx, LItems) then
              for var LIdx := 0 to Min(High(LItems), 20) do
              begin
                LC.ItemHeadWord(LItems[LIdx]);
                LC.ItemParamsText(LItems[LIdx]);
                LC.ItemDocComment(LItems[LIdx]);
              end;
            LC.CallAt(ALine, ACol, LCall);
          finally
            LC.Free;
          end;
        end);
    if not ADeep then
      Exit;
    for var LP in LSyms do
      SweepSymbol(LP.Key, LP.Value);
    for var LU in LUnits do
    begin
      Probe('FindUnitReferences', procedure begin GNav.FindUnitReferences(LU); end);
      Probe('UnitDeclHit', procedure var H: TPasRefHit; begin GNav.UnitDeclHit(LU, H); end);
      Probe('UnitHeaderTarget', procedure begin GNav.UnitHeaderTarget(LU, LTarget); end);
      Probe('PlanUnitRename', procedure
        var E: TArray<TPasRenameEdit>; F, Err: string;
        begin GNav.PlanUnitRename(LU, 'Sweep.Renamed', E, F, Err); end);
    end;
    for var LN in LNames do
      Probe('FindBuiltinReferences', procedure begin GNav.FindBuiltinReferences(LN); end);
    for var LD in LDefines do
      Probe('FindDefineReferences', procedure
        begin
          GNav.FindDefineReferences(LD);
          GNav.IsProjectDefined(LD);
        end);
  finally
    LDefines.Free;
    LNames.Free;
    LUnits.Free;
    LSyms.Free;
  end;
end;

{ Per file: the whole-file entry points, then the carets - edge ones first
  (line 0, column 0, past the end, MaxInt), then random ones. }
procedure SweepFile(AMid: Integer; AComplete: Boolean);
var
  LLines: TArray<string>;
  LLine, LCol, LDeep: Integer;
  LFile: string;
begin
  LFile := GProj.ModelFile(AMid);
  GSite := ExtractFileName(LFile);
  Probe('SemanticTokens', procedure begin GNav.SemanticTokens(AMid); end);
  Probe('PasModuleOutline', procedure
    begin PasModuleOutline(GProj.Model(AMid).Tree); end);
  Probe('ProjectOutline', procedure begin GNav.ProjectOutline([AMid]); end);
  Probe('RenameBlockReason', procedure
    begin
      GNav.RenameBlockReason(LFile);
      GNav.IsUnderLibraryPath(LFile);
    end);
  for var LInc := 0 to 3 do
    Probe('IncludeSiteTarget', procedure var T: TPasNavTarget;
      begin GNav.IncludeSiteTarget(AMid, LInc, T); end);
  for var LExt in ['.dfm', '.fmx'] do
    if TFile.Exists(TPath.ChangeExtension(LFile, LExt)) then
      Probe('DescribeForm', procedure var I: TPasFormInfo;
        begin
          GNav.DescribeForm(TPath.ChangeExtension(LFile, LExt), I);
          GBinder.DescribeForm(TPath.ChangeExtension(LFile, LExt), I);
        end);
  LLines := LinesOf(AMid);
  for var LEdge in [TPoint.Create(0, 0), TPoint.Create(1, 0),
    TPoint.Create(-1, 1), TPoint.Create(1, MaxInt), TPoint.Create(MaxInt, 1),
    TPoint.Create(MaxInt, MaxInt), TPoint.Create(Length(LLines) + 1, 1),
    TPoint.Create(Length(LLines), MaxInt - 3)] do
    SweepCaret(AMid, LEdge.X, LEdge.Y, False, AComplete);
  if LLines = nil then
    Exit;
  LDeep := 0;
  for var LIdx := 1 to GCarets do
  begin
    LLine := 1 + Random(Length(LLines));
    // Mostly inside the line, a few at its end and past it (virtual space).
    case Random(8) of
      0: LCol := Length(LLines[LLine - 1]) + 1;
      1: LCol := Length(LLines[LLine - 1]) + 1 + Random(10);
    else
      LCol := 1 + Random(Max(1, Length(LLines[LLine - 1])));
    end;
    // The deep half (references, rename plans) for the first few carets only.
    SweepCaret(AMid, LLine, LCol, LDeep < 4, AComplete);
    Inc(LDeep);
  end;
end;

procedure SweepState(const AState: string);
var
  LSW: TStopwatch;
  LBefore: Int64;
begin
  GState := AState;
  LSW := TStopwatch.StartNew;
  LBefore := GCalls;
  GNav := TPasNavigator.Create(GProj);
  GBinder := TPasFormBinder.Create(GProj, []);
  try
    GSite := '(project)';
    Probe('FindDefines', procedure begin GNav.FindDefines; end);
    Probe('ProjectOutline(all)', procedure
      begin GNav.ProjectOutline(GKept + GFree); end);
    // Model ids no model has: every entry point refuses them.
    SweepCaret(-1, 1, 1, False, False);
    SweepCaret(GProj.ModelCount, 1, 1, False, False);
    for var LMid in GKept do
      SweepFile(LMid, True);
    for var LMid in GFree do
      SweepFile(LMid, False);
  finally
    GBinder.Free;
    GNav.Free;
  end;
  Writeln(ErrOutput, Format('%-12s %8d calls %7d ms, %d finding kind(s) so far',
    [AState, GCalls - LBefore, LSW.ElapsedMilliseconds, GFindings.Count]));
end;

{ A random edit of the text: a span cut, a fragment typed, or the rest
  dropped - what a buffer looks like between keystrokes. }
function Mutate(const AText: string): string;
const
  FRAGMENTS: array[0..13] of string = ('.', '(', ')', 'begin ', 'end;', '''',
    '{', '(*', '<', ';', ' X.', '[', 'inherited ', 'property ');
var
  LAt: Integer;
begin
  if AText = '' then
    Exit('unit');
  LAt := 1 + Random(Length(AText));
  case Random(3) of
    0: Result := Copy(AText, 1, LAt - 1) + Copy(AText, LAt + 1 + Random(40), MaxInt);
    1: Result := Copy(AText, 1, LAt - 1) + FRAGMENTS[Random(Length(FRAGMENTS))] +
         Copy(AText, LAt, MaxInt);
  else
    Result := Copy(AText, 1, LAt - 1);
  end;
end;

procedure SweepEdits;
var
  LMid, LAccepted: Integer;
  LFile, LOrig, LText: string;
  LSW: TStopwatch;
  LBefore: Int64;
begin
  if (GKept = nil) or (GMutants <= 0) then
    Exit;
  GState := 'edited';
  LSW := TStopwatch.StartNew;
  LBefore := GCalls;
  LAccepted := 0;
  for var LIdx := 1 to GMutants do
  begin
    LMid := GKept[Random(Length(GKept))];
    LFile := GProj.ModelFile(LMid);
    try
      LOrig := TFile.ReadAllText(LFile);
    except
      Continue;
    end;
    LText := Mutate(LOrig);
    GSite := ExtractFileName(LFile) + ' (edit)';
    Probe('SetBuffer+AnalyzeModuleOnly', procedure
      begin
        GProj.SetBuffer(LFile, LText, LIdx);
        if GProj.AnalyzeModuleOnly(LFile) then
          Inc(LAccepted);
      end);
    GTexts.AddOrSetValue(LMid, LText.Split([#13#10, #10]));
    GNav := TPasNavigator.Create(GProj);
    GBinder := TPasFormBinder.Create(GProj, []);
    try
      SweepFile(LMid, True);
    finally
      GBinder.Free;
      GNav.Free;
    end;
    // Back to the file's own text, the way a host's undo would.
    GSite := ExtractFileName(LFile) + ' (undo)';
    Probe('SetBuffer+AnalyzeModuleOnly', procedure
      begin
        GProj.SetBuffer(LFile, LOrig, LIdx + 100000);
        GProj.AnalyzeModuleOnly(LFile);
      end);
    GTexts.Remove(LMid);
  end;
  Writeln(ErrOutput, Format('%-12s %8d calls %7d ms, %d of %d edits accepted, '
    + '%d finding kind(s) so far', [GState, GCalls - LBefore,
    LSW.ElapsedMilliseconds, LAccepted, GMutants, GFindings.Count]));
end;

function StudioSearchPaths(const ARoot: string): TArray<string>;
const
  // As in PasTreeSemaProject: the trees that make System.*, Vcl.*, FMX.*
  // resolve without the registry.
  SUBS: array[0..8] of string = ('source\rtl\sys', 'source\rtl\common',
    'source\rtl\win', 'source\rtl\win\winrt', 'source\rtl\net',
    'source\databinding\engine', 'source\xml', 'source\vcl', 'source\fmx');
begin
  Result := nil;
  if ARoot <> '' then
    for var LSub in SUBS do
      if TDirectory.Exists(TPath.Combine(ARoot, LSub)) then
        Result := Result + [TPath.Combine(ARoot, LSub)];
end;

function KeepFiles: TArray<string>;
begin
  Result := nil;
  for var LMid in GKept do
    Result := Result + [GProj.ModelFile(LMid)];
end;

var
  GPath, GStudio, GRoot, GStates: string;
  GPlatform: TPasPlatform;
  GExtra: TArray<string>;
  GSeed, GFiles: Integer;
  GCand: TList<Integer>;
  GKeys: TArray<string>;
  GTotal: TStopwatch;
begin
  try
    if ParamCount < 1 then
    begin
      Writeln('Usage: PasTreeNavSweep <dir|file.dpr|file.dpk> [-p:<platform>]'
        + ' [-L<dir>]... [-studio:<dir>] [-seed:N] [-files:N] [-carets:N]'
        + ' [-mutants:N] [-states:full,edited,textdemoted,released,demoted]');
      ExitCode := 2;
      Exit;
    end;
    GPath := TPath.GetFullPath(ParamStr(1));
    GPlatform := pfWin32;
    GStudio := GetEnvironmentVariable('BDS');
    GSeed := 1;
    GFiles := 40;
    GCarets := 30;
    GMutants := 20;
    GStates := 'full,edited,textdemoted,released,demoted';
    for var LIdx := 2 to ParamCount do
      if ParamStr(LIdx).StartsWith('-p:', True) then
        TryParsePlatformName(Copy(ParamStr(LIdx), 4, MaxInt), GPlatform)
      else if ParamStr(LIdx).StartsWith('-studio:', True) then
        GStudio := Copy(ParamStr(LIdx), 9, MaxInt)
      else if ParamStr(LIdx).StartsWith('-seed:', True) then
        GSeed := StrToInt(Copy(ParamStr(LIdx), 7, MaxInt))
      else if ParamStr(LIdx).StartsWith('-files:', True) then
        GFiles := StrToInt(Copy(ParamStr(LIdx), 8, MaxInt))
      else if ParamStr(LIdx).StartsWith('-carets:', True) then
        GCarets := StrToInt(Copy(ParamStr(LIdx), 9, MaxInt))
      else if ParamStr(LIdx).StartsWith('-mutants:', True) then
        GMutants := StrToInt(Copy(ParamStr(LIdx), 10, MaxInt))
      else if ParamStr(LIdx).StartsWith('-states:', True) then
        GStates := LowerCase(Copy(ParamStr(LIdx), 9, MaxInt))
      else if ParamStr(LIdx).StartsWith('-L', True) and
              (Length(ParamStr(LIdx)) > 2) then
        GExtra := GExtra + [Copy(ParamStr(LIdx), 3, MaxInt)];
    RandSeed := GSeed;
    GFindings := TDictionary<string, TFinding>.Create;
    GTexts := TDictionary<Integer, TArray<string>>.Create;
    GTotal := TStopwatch.StartNew;
    if TDirectory.Exists(GPath) then
    begin
      GRoot := GPath;
      GProj := TPasSemaProject.Create(GPlatform, [GPath], []);
    end
    else
    begin
      GRoot := TPath.GetDirectoryName(GPath);
      GProj := TPasSemaProject.Create(GPlatform,
        [GRoot] + StudioSearchPaths(GStudio) + GExtra, []);
    end;
    GCand := TList<Integer>.Create;
    try
      GProj.SetNamespaces(PasDefaultNamespaces(GPlatform));
      for var LDef in PasDefaultUnitAliases(GPlatform) do
        GProj.AddUnitAlias(LDef.Alias, LDef.UnitName);
      if TDirectory.Exists(GPath) then
        GProj.AnalyzeDirectory(GPath)
      else
        GProj.AnalyzeProject(GPath);
      Writeln(ErrOutput, Format('analyzed %d units in %d ms',
        [GProj.ModelCount, GTotal.ElapsedMilliseconds]));
      for var LMid := 0 to GProj.ModelCount - 1 do
        if GProj.ModelFile(LMid).StartsWith(IncludeTrailingPathDelimiter(GRoot),
             True) and not SameText(TPath.GetExtension(GProj.ModelFile(LMid)),
             '.dcu') then
          GCand.Add(LMid);
      // The sample: deterministic in the seed, half kept, half not.
      while (GCand.Count > 0) and
            (Length(GKept) + Length(GFree) < GFiles) do
      begin
        var LPick := Random(GCand.Count);
        if Length(GKept) <= Length(GFree) then
          GKept := GKept + [GCand[LPick]]
        else
          GFree := GFree + [GCand[LPick]];
        GCand.Delete(LPick);
      end;
      Writeln(ErrOutput, Format('sample: %d kept, %d not kept, of %d '
        + 'candidates; %d carets per file, seed %d', [Length(GKept),
        Length(GFree), Length(GKept) + Length(GFree) + GCand.Count, GCarets,
        GSeed]));
      GKeys := GStates.Split([',']);
      for var LState in GKeys do
        if LState = 'full' then
          SweepState('full')
        else if LState = 'edited' then
          SweepEdits
        else if LState = 'textdemoted' then
        begin
          GProj.DemoteText(KeepFiles);
          SweepState('textdemoted');
        end
        else if LState = 'released' then
        begin
          GProj.ReleaseTransientMaps(KeepFiles);
          SweepState('released');
        end
        else if LState = 'demoted' then
        begin
          GProj.DemoteClosedUnits(KeepFiles);
          SweepState('demoted');
        end
        else
          Writeln(ErrOutput, 'unknown state: ' + LState);
    finally
      GCand.Free;
      GProj.Free;
    end;
    Writeln(Format('%d calls in %d ms; slowest %.0f ms: %s', [GCalls,
      GTotal.ElapsedMilliseconds, GSlowest, GSlowestAt]));
    GKeys := GFindings.Keys.ToArray;
    TArray.Sort<string>(GKeys);
    Writeln(Format('%d finding kind(s)', [Length(GKeys)]));
    for var LKey in GKeys do
      Writeln(Format('  %dx %s'#13#10'      first: %s', [GFindings[LKey].Count,
        LKey, GFindings[LKey].First]));
    if Length(GKeys) > 0 then
      ExitCode := 1;
    GTexts.Free;
    GFindings.Free;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, 'ABORTED: ', E.ClassName, ': ', E.Message,
        ' (state ', GState, ', ', GSite, ')');
      ExitCode := 2;
    end;
  end;
end.
