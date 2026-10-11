program PasTreeRenameOracle;
{ Rename oracle (gate T4 of the 2026-09 audit plan): applies
  TPasNavigator.PlanRename to a random sample of the symbols a real project
  declares - and PlanUnitRename to a sample of its units - and compiles the
  result with dcc in every configuration the .dproj names. A plan the
  compiler rejects is a finding: the rename left a site behind, or edited one
  it should not have. A refusal is not - it is reported and counted.

  Nothing of the project is touched. Its own files are mirrored under the
  work directory: every directory holding one of the .dproj's files (the
  sources, their forms, resources and includes, the .dproj itself), at the
  same relative layout, so `in '..\x\Y.pas'` paths keep working. A plan's
  edits are applied to the mirror, dcc builds it (make mode: one dcu
  directory per configuration, so the libraries compile once), and the
  touched files are put back byte for byte before the next symbol. The
  untouched mirror is built first: an error it already has is the baseline,
  and only an error beyond it counts.

  Usage: PasTreeRenameOracle <file.dproj> -work:<dir>
           [-p:<platform>] [-studio:<dir>] [-L<dir>]... [-configs:A,B]
           [-n:N] [-units:N] [-seed:N] [-only:<name>] [-dcc:<exe>] [-selftest]
    -n       symbols to rename (default 20); -units: units (default 0)
    -configs the configurations to build (default: every one but Base)
    -only    rename only declarations of this name (case-insensitive)
    -selftest apply only the first edit of each plan: every build must
             break (a plan of one edit is skipped)
    -L       a library directory: analyzed, on dcc's -U/-I path, and a
             rename that reaches it is refused (TPasNavigator.LibraryPaths)
  Exit code 1 when a plan breaks the build, 2 on a usage or setup error.

  Build it like the other tools, checked: from tools\,
    dcc64 -B -Q -$R+ -$Q+ -NSSystem;Winapi;System.Win -U..\source
      -N0..\out\dcu\win64g -Eoutg PasTreeRenameOracle.dpr }

{$APPTYPE CONSOLE}
{$MAXSTACKSIZE $01000000}   // 16 MB per thread: README, "The stack every host should reserve"

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  PasTree.Types,
  PasTree.Ast,
  PasTree.Platforms,
  PasTree.DProj,
  PasTree.Sema.Model,
  PasTree.Sema.Project,
  PasTree.Sema.Nav;

type
  TOriginal = record
    Path: string;       // mirrored path
    Bytes: TBytes;      // NIL: the file did not exist (a renamed unit's file)
  end;

var
  GDProj, GWork, GStudio, GDcc, GOnly: string;
  GPlatform: TPasPlatform = pfWin64;
  GExtra: TArray<string>;
  GConfigs: TArray<string>;
  GSymbols: Integer = 20;
  GUnits: Integer = 0;
  GSeed: Integer = 1;
  GSelfTest: Boolean = False;
  GRoot, GMirror: string;          // the common root of the own files, its copy
  GIncDirs: TArray<string>;        // the mirrored directories of their includes
  GProj: TPasSemaProject;
  GNav: TPasNavigator;
  GBaseline: TDictionary<string, Boolean>;   // config + '|' + error text
  GOk, GRefused, GBroken: Integer;

{ ---- paths ---- }

function Norm(const APath: string): string;
begin
  Result := ExcludeTrailingPathDelimiter(TPath.GetFullPath(APath));
end;

function IsUnder(const APath, ADir: string): Boolean;
begin
  Result := SameText(APath, ADir) or
    APath.StartsWith(IncludeTrailingPathDelimiter(ADir), True);
end;

// APath's place in the mirror; a path outside the root is its own.
function Mirrored(const APath: string): string;
var
  LFull: string;
begin
  LFull := Norm(APath);
  if IsUnder(LFull, GRoot) then
    Result := TPath.Combine(GMirror, LFull.Substring(Length(GRoot)).TrimLeft(['\']))
  else
    Result := LFull;
end;

function CommonDir(const A, B: string): string;
var
  LA, LB: TArray<string>;
  I: Integer;
begin
  LA := Norm(A).Split(['\']);
  LB := Norm(B).Split(['\']);
  Result := '';
  I := 0;
  while (I <= High(LA)) and (I <= High(LB)) and SameText(LA[I], LB[I]) do
  begin
    if Result = '' then
      Result := LA[I]
    else
      Result := Result + '\' + LA[I];
    Inc(I);
  end;
end;

function StudioSourcePaths(const ARoot: string): TArray<string>;
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

{ ---- processes ---- }

// Runs ACmdLine in ADir; its stdout and stderr together, and its exit code.
function RunCapture(const ACmdLine, ADir: string; out AOutput: string): Cardinal;
var
  LSA: TSecurityAttributes;
  LRead, LWrite: THandle;
  LSI: TStartupInfo;
  LPI: TProcessInformation;
  LBuf: array[0..8191] of AnsiChar;
  LGot: DWORD;
  LBytes: TBytesStream;
  LCmd: string;
begin
  AOutput := '';
  Result := Cardinal(-1);
  LSA.nLength := SizeOf(LSA);
  LSA.bInheritHandle := True;
  LSA.lpSecurityDescriptor := nil;
  if not CreatePipe(LRead, LWrite, @LSA, 0) then
    Exit;
  try
    SetHandleInformation(LRead, HANDLE_FLAG_INHERIT, 0);
    FillChar(LSI, SizeOf(LSI), 0);
    LSI.cb := SizeOf(LSI);
    LSI.dwFlags := STARTF_USESTDHANDLES;
    LSI.hStdOutput := LWrite;
    LSI.hStdError := LWrite;
    LSI.hStdInput := GetStdHandle(STD_INPUT_HANDLE);
    LCmd := ACmdLine;
    UniqueString(LCmd);
    if not CreateProcess(nil, PChar(LCmd), nil, nil, True, CREATE_NO_WINDOW,
       nil, PChar(ADir), LSI, LPI) then
      Exit;
    CloseHandle(LWrite);
    LWrite := 0;
    LBytes := TBytesStream.Create;
    try
      while ReadFile(LRead, LBuf, SizeOf(LBuf), LGot, nil) and (LGot > 0) do
        LBytes.WriteBuffer(LBuf, LGot);
      WaitForSingleObject(LPI.hProcess, INFINITE);
      GetExitCodeProcess(LPI.hProcess, Result);
      CloseHandle(LPI.hProcess);
      CloseHandle(LPI.hThread);
      AOutput := TEncoding.ANSI.GetString(LBytes.Bytes, 0, LBytes.Size);
    finally
      LBytes.Free;
    end;
  finally
    if LWrite <> 0 then
      CloseHandle(LWrite);
    CloseHandle(LRead);
  end;
end;

function Quote(const S: string): string;
begin
  Result := '"' + S + '"';
end;

{ ---- the build ---- }

// The error lines of one configuration's build of the mirror.
function Build(const AConfig: string): TArray<string>;
var
  LD: TPasDProj;
  LCmd, LOut, LDcu, LExe, LLib: string;
  LPaths, LNs: TArray<string>;
  LAliases: string;
begin
  Result := nil;
  LD := TPasDProj.Create;
  try
    if not LD.Load(GDProj, PlatformName(GPlatform), AConfig) then
      Exit(TArray<string>.Create('cannot load the .dproj for ' + AConfig));
    LDcu := TPath.Combine(GWork, 'dcu\' + AConfig);
    LExe := TPath.Combine(GWork, 'exe\' + AConfig);
    ForceDirectories(LDcu);
    ForceDirectories(LExe);
    LLib := TPath.Combine(GStudio, 'lib\' + LowerCase(PlatformName(GPlatform)) +
      '\release');
    LPaths := [LLib];
    for var LP in LD.SearchPaths do
      LPaths := LPaths + [Mirrored(LP)];
    LPaths := LPaths + GIncDirs + GExtra;
    LNs := LD.Namespaces;
    if LNs = nil then
      LNs := PasDefaultNamespaces(GPlatform);
    LAliases := '';
    for var LA in LD.UnitAliases do
      LAliases := LAliases + LA.Alias + '=' + LA.UnitName + ';';
    LCmd := Quote(GDcc) + ' -Q' +
      ' -U' + Quote(string.Join(';', LPaths)) +
      ' -I' + Quote(string.Join(';', LPaths)) +
      ' -R' + Quote(string.Join(';', LPaths)) +
      ' -NS' + Quote(string.Join(';', LNs)) +
      ' -N0' + Quote(LDcu) + ' -E' + Quote(LExe);
    if LD.Defines <> nil then
      LCmd := LCmd + ' -D' + Quote(string.Join(';', LD.Defines));
    if LAliases <> '' then
      LCmd := LCmd + ' -A' + Quote(LAliases.TrimRight([';']));
    LCmd := LCmd + ' ' + Quote(Mirrored(LD.MainSource));
    RunCapture(LCmd, Mirrored(LD.Dir), LOut);
    for var LLine in LOut.Split([#10]) do
      // No space required before the word: dcc wraps a long path at the
      // console width, and the line it prints is then `...\souError: E2003`.
      if LLine.Contains('Error: E') or LLine.Contains('Fatal: F') then
        Result := Result + [LLine.Trim];
  finally
    LD.Free;
  end;
end;

// The errors of every configuration beyond the baseline, as `config: line`.
function NewErrors: TArray<string>;
begin
  Result := nil;
  for var LC in GConfigs do
    for var LE in Build(LC) do
      if not GBaseline.ContainsKey(LC + '|' + LE) then
        Result := Result + [LC + ': ' + LE];
end;

{ ---- the mirror ---- }

procedure MirrorProject(const AOwn: TArray<string>);
const
  EXTS: array[0..10] of string = ('.pas', '.dpr', '.dpk', '.inc', '.dfm',
    '.fmx', '.res', '.dcr', '.rc', '.dproj', '.rc');
var
  LDirs: TDictionary<string, Boolean>;
  LTarget: string;
begin
  LDirs := TDictionary<string, Boolean>.Create;
  try
    for var LF in AOwn do
      LDirs.AddOrSetValue(LowerCase(TPath.GetDirectoryName(Norm(LF))), True);
    for var LDir in LDirs.Keys do
      for var LF in TDirectory.GetFiles(LDir) do
        for var LExt in EXTS do
          if SameText(TPath.GetExtension(LF), LExt) then
          begin
            LTarget := Mirrored(LF);
            ForceDirectories(TPath.GetDirectoryName(LTarget));
            TFile.Copy(LF, LTarget, True);
            Break;
          end;
  finally
    LDirs.Free;
  end;
end;

{ ---- applying a plan ---- }

// The text of a mirrored file as PasTree read it, and how to write it back.
function ReadText(const APath: string; out AEncoding: TEncoding;
  out APreamble: Integer): string;
var
  LBytes: TBytes;
begin
  LBytes := TFile.ReadAllBytes(APath);
  AEncoding := nil;
  APreamble := TEncoding.GetBufferEncoding(LBytes, AEncoding, TEncoding.UTF8);
  Result := AEncoding.GetString(LBytes, APreamble, Length(LBytes) - APreamble);
  // No BOM: UTF-8 when it decodes back to the same bytes, else ANSI.
  if (APreamble = 0) and
     (Length(AEncoding.GetBytes(Result)) <> Length(LBytes)) then
  begin
    AEncoding := TEncoding.ANSI;
    Result := AEncoding.GetString(LBytes);
  end;
end;

// Applies AEdits (one file's, any order) to APath; False with AWhy when an
// edit's old text is not where the plan says.
function ApplyEdits(const APath: string; AEdits: TArray<TPasRenameEdit>;
  out AWhy: string): Boolean;
var
  LText: string;
  LEnc: TEncoding;
  LPre, LLine, LPos, LAt: Integer;
  LBytes, LOut: TBytes;
begin
  AWhy := '';
  LText := ReadText(APath, LEnc, LPre);
  LBytes := TFile.ReadAllBytes(APath);
  TArray.Sort<TPasRenameEdit>(AEdits, TComparer<TPasRenameEdit>.Construct(
    function(const A, B: TPasRenameEdit): Integer
    begin
      Result := B.Line - A.Line;
      if Result = 0 then
        Result := B.Col - A.Col;
    end));
  for var LE in AEdits do
  begin
    // The 1-based offset of the line's first character.
    LPos := 1;
    LLine := 1;
    while (LLine < LE.Line) and (LPos <= Length(LText)) do
    begin
      LAt := LText.IndexOf(#10, LPos - 1);
      if LAt < 0 then
        Break;
      LPos := LAt + 2;
      Inc(LLine);
    end;
    LAt := LPos + LE.Col - 1;
    if (LLine <> LE.Line) or
       not SameText(Copy(LText, LAt, LE.Len), LE.OldText) then
    begin
      AWhy := Format('%s(%d,%d): expected "%s", found "%s"',
        [TPath.GetFileName(APath), LE.Line, LE.Col, LE.OldText,
         Copy(LText, LAt, LE.Len)]);
      Exit(False);
    end;
    LText := Copy(LText, 1, LAt - 1) + LE.NewText +
      Copy(LText, LAt + LE.Len, MaxInt);
  end;
  LOut := Copy(LBytes, 0, LPre) + LEnc.GetBytes(LText);
  TFile.WriteAllBytes(APath, LOut);
  Result := True;
end;

procedure Restore(const AOriginals: TArray<TOriginal>);
begin
  for var LO in AOriginals do
    if LO.Bytes = nil then
    begin
      if TFile.Exists(LO.Path) then
        TFile.Delete(LO.Path);
    end
    else
      TFile.WriteAllBytes(LO.Path, LO.Bytes);
end;

procedure Remember(var AOriginals: TArray<TOriginal>; const APath: string);
var
  LO: TOriginal;
begin
  for LO in AOriginals do
    if SameText(LO.Path, APath) then
      Exit;
  LO.Path := APath;
  if TFile.Exists(APath) then
    LO.Bytes := TFile.ReadAllBytes(APath)
  else
    LO.Bytes := nil;
  AOriginals := AOriginals + [LO];
end;

// Applies AEdits to the mirror, remembering every file it changes; False
// with AWhy when an edit does not apply.
function ApplyPlan(const AEdits: TArray<TPasRenameEdit>;
  var AOriginals: TArray<TOriginal>; out AWhy: string): Boolean;
var
  LByFile: TDictionary<string, TArray<TPasRenameEdit>>;
  LList: TArray<TPasRenameEdit>;
  LTarget: string;
begin
  Result := True;
  AWhy := '';
  LByFile := TDictionary<string, TArray<TPasRenameEdit>>.Create;
  try
    for var LE in AEdits do
    begin
      LTarget := Mirrored(LE.FilePath);
      if not IsUnder(LTarget, GMirror) then
      begin
        AWhy := 'an edit outside the project: ' + LE.FilePath;
        Exit(False);
      end;
      if not LByFile.TryGetValue(LowerCase(LTarget), LList) then
        LList := nil;
      LByFile.AddOrSetValue(LowerCase(LTarget), LList + [LE]);
    end;
    for var LPair in LByFile do
    begin
      Remember(AOriginals, LPair.Key);
      if not ApplyEdits(LPair.Key, LPair.Value, AWhy) then
        Exit(False);
    end;
  finally
    LByFile.Free;
  end;
end;

{ ---- the samples ---- }

function KindName(AKind: TSemaSymbolKind): string;
begin
  case AKind of
    skVar: Result := 'var';
    skConst: Result := 'const';
    skType: Result := 'type';
    skField: Result := 'field';
    skParam: Result := 'param';
    skRoutine: Result := 'routine';
    skProperty: Result := 'property';
    skEnumValue: Result := 'enum';
  else
    Result := 'other';
  end;
end;

procedure Report(const AWhat, AVerdict: string; const ADetail: TArray<string>);
begin
  Writeln(AWhat, ': ', AVerdict);
  for var LD in ADetail do
    Writeln('    ', LD);
end;

procedure TrySymbol(AMid, ASym: Integer);
var
  LM: TPasSemaModel;
  LEdits: TArray<TPasRenameEdit>;
  LErr, LWhy, LWhat, LNew: string;
  LOriginals: TArray<TOriginal>;
  LErrors: TArray<string>;
  LHit: TPasRefHit;
begin
  LM := GProj.Model(AMid);
  LNew := LM.Symbols[ASym].Name + 'Rn';
  LWhat := Format('%s %s', [KindName(LM.Symbols[ASym].Kind),
    LM.Symbols[ASym].Name]);
  if GNav.DeclHit(AMid, ASym, LHit) then
    LWhat := LWhat + Format(' (%s:%d)', [TPath.GetFileName(LHit.FilePath),
      LHit.Line]);
  if not GNav.PlanRename(AMid, ASym, LNew, LEdits, LErr) then
  begin
    Inc(GRefused);
    Report(LWhat, 'refused - ' + LErr, nil);
    Exit;
  end;
  // -selftest: the plan cut to its first edit must break the build - the
  // proof that a left-behind site is seen. A one-edit plan proves nothing.
  if GSelfTest then
  begin
    if Length(LEdits) < 2 then
      Exit;
    LEdits := Copy(LEdits, 0, 1);
  end;
  LOriginals := nil;
  try
    if not ApplyPlan(LEdits, LOriginals, LWhy) then
    begin
      Inc(GBroken);
      Report(LWhat, 'BROKEN - the plan does not apply', [LWhy]);
      Exit;
    end;
    LErrors := NewErrors;
    if GSelfTest then
    begin
      if LErrors = nil then
      begin
        Inc(GBroken);
        Report(LWhat, 'BROKEN - selftest: one edit of the plan built clean',
          [Format('%s(%d,%d) %s -> %s', [TPath.GetFileName(LEdits[0].FilePath),
            LEdits[0].Line, LEdits[0].Col, LEdits[0].OldText,
            LEdits[0].NewText])]);
      end
      else
      begin
        Inc(GOk);
        Report(LWhat, 'selftest ok - the cut plan breaks the build', Copy(LErrors, 0, 1));
      end;
    end
    else if LErrors = nil then
    begin
      Inc(GOk);
      Report(LWhat, Format('ok, %d edit(s)', [Length(LEdits)]), nil);
    end
    else
    begin
      Inc(GBroken);
      Report(LWhat, Format('BROKEN, %d edit(s)', [Length(LEdits)]),
        Copy(LErrors, 0, 6));
    end;
  finally
    Restore(LOriginals);
  end;
end;

procedure TryUnit(AMid: Integer);
var
  LM: TPasSemaModel;
  LEdits: TArray<TPasRenameEdit>;
  LErr, LWhy, LWhat, LNew, LReq, LOld, LNewPath, LForm: string;
  LOriginals: TArray<TOriginal>;
  LErrors: TArray<string>;
begin
  LM := GProj.Model(AMid);
  LOld := LM.Tree.Source.FileNames[0];
  LNew := TPath.GetFileNameWithoutExtension(LOld) + 'Rn';
  LWhat := 'unit ' + TPath.GetFileNameWithoutExtension(LOld);
  if not GNav.PlanUnitRename(AMid, LNew, LEdits, LReq, LErr) then
  begin
    Inc(GRefused);
    Report(LWhat, 'refused - ' + LErr, nil);
    Exit;
  end;
  LOriginals := nil;
  try
    if not ApplyPlan(LEdits, LOriginals, LWhy) then
    begin
      Inc(GBroken);
      Report(LWhat, 'BROKEN - the plan does not apply', [LWhy]);
      Exit;
    end;
    // The file the plan says the unit must now live in, and its form.
    LNewPath := TPath.Combine(TPath.GetDirectoryName(Mirrored(LOld)), LReq);
    Remember(LOriginals, Mirrored(LOld));
    Remember(LOriginals, LNewPath);
    TFile.Move(Mirrored(LOld), LNewPath);
    for var LExt in ['.dfm', '.fmx'] do
    begin
      LForm := TPath.ChangeExtension(Mirrored(LOld), LExt);
      if TFile.Exists(LForm) then
      begin
        Remember(LOriginals, LForm);
        Remember(LOriginals, TPath.ChangeExtension(LNewPath, LExt));
        TFile.Move(LForm, TPath.ChangeExtension(LNewPath, LExt));
      end;
    end;
    LErrors := NewErrors;
    if LErrors = nil then
    begin
      Inc(GOk);
      Report(LWhat, Format('ok, %d edit(s)', [Length(LEdits)]), nil);
    end
    else
    begin
      Inc(GBroken);
      Report(LWhat, Format('BROKEN, %d edit(s)', [Length(LEdits)]),
        Copy(LErrors, 0, 6));
    end;
  finally
    Restore(LOriginals);
  end;
end;

{ ---- main ---- }

procedure Run;
var
  LD: TPasDProj;
  LOwn: TDictionary<string, Boolean>;
  LCands: TList<TPair<Integer, Integer>>;
  LUnitCands: TList<Integer>;
  LM: TPasSemaModel;
  LFile: string;
  LNs: TArray<string>;
  LIncs, LIncDirs: TList<string>;
begin
  LD := TPasDProj.Create;
  LIncs := TList<string>.Create;
  LIncDirs := TList<string>.Create;
  LOwn := TDictionary<string, Boolean>.Create;
  LCands := TList<TPair<Integer, Integer>>.Create;
  LUnitCands := TList<Integer>.Create;
  GBaseline := TDictionary<string, Boolean>.Create;
  try
    if not LD.Load(GDProj, PlatformName(GPlatform)) then
    begin
      Writeln(ErrOutput, 'Could not load .dproj: ', GDProj);
      ExitCode := 2;
      Exit;
    end;
    if GConfigs = nil then
      for var LC in LD.Configurations do
        if not SameText(LC, 'Base') then
          GConfigs := GConfigs + [LC];
    GRoot := Norm(LD.Dir);
    for var LF in LD.Files do
    begin
      LOwn.AddOrSetValue(LowerCase(Norm(LF)), True);
      GRoot := CommonDir(GRoot, TPath.GetDirectoryName(Norm(LF)));
    end;
    Writeln(Format('%s: %d file(s) under %s, configurations %s',
      [TPath.GetFileName(GDProj), Length(LD.Files), GRoot,
       string.Join(', ', GConfigs)]));

    GProj := TPasSemaProject.Create(LD.Platform,
      [LD.Dir] + LD.SearchPaths + StudioSourcePaths(GStudio) + GExtra,
      LD.Defines);
    try
      LNs := LD.Namespaces;
      if LNs = nil then
        LNs := PasDefaultNamespaces(LD.Platform);
      GProj.SetNamespaces(LNs);
      for var LDef in PasDefaultUnitAliases(LD.Platform) do
        GProj.AddUnitAlias(LDef.Alias, LDef.UnitName);
      for var LA in LD.UnitAliases do
        GProj.AddUnitAlias(LA.Alias, LA.UnitName);
      GProj.AnalyzeStaged([LD.MainSource], []);
      GNav := TPasNavigator.Create(GProj);
      try
        GNav.LibraryPaths := StudioSourcePaths(GStudio) + GExtra;
        // The candidates: what the project's own files declare.
        for var LMid := 0 to GProj.ModelCount - 1 do
        begin
          LM := GProj.Model(LMid);
          if not GProj.EnsureHydrated(LMid) then
            Continue;
          LFile := LowerCase(Norm(LM.Tree.Source.FileNames[0]));
          if not LOwn.ContainsKey(LFile) then
            Continue;
          if SameText(TPath.GetExtension(LFile), '.pas') then
            LUnitCands.Add(LMid);
          for var LSym := 0 to LM.SymCount - 1 do
            if (LM.Symbols[LSym].Kind in [skVar, skConst, skType, skField,
                 skParam, skRoutine, skProperty, skEnumValue]) and
               (LM.Symbols[LSym].DeclNode <> NIL_NODE) and
               (LM.Tree.Source.Visible[LM.Tree.Nodes[
                  LM.Symbols[LSym].DeclNode].FirstToken].FileId = 0) and
               ((GOnly = '') or SameText(LM.Symbols[LSym].Name, GOnly)) then
              LCands.Add(TPair<Integer, Integer>.Create(LMid, LSym));
        end;
        // The include files the own units pulled in go into the mirror too,
        // and their directories onto dcc's -I path: a .dproj names its
        // include path in a setting this reader does not take.
        for var LMid := 0 to GProj.ModelCount - 1 do
        begin
          LM := GProj.Model(LMid);
          if not LOwn.ContainsKey(LowerCase(Norm(LM.Tree.Source.FileNames[0]))) then
            Continue;
          for var LI := 1 to High(LM.Tree.Source.FileNames) do
          begin
            LFile := Norm(LM.Tree.Source.FileNames[LI]);
            if not LIncs.Contains(LFile) then
              LIncs.Add(LFile);
            LFile := TPath.GetDirectoryName(Mirrored(LFile));
            if not LIncDirs.Contains(LFile) then
              LIncDirs.Add(LFile);
          end;
        end;
        GIncDirs := LIncDirs.ToArray;
        GMirror := TPath.Combine(GWork, 'src');
        if TDirectory.Exists(GMirror) then
          TDirectory.Delete(GMirror, True);
        MirrorProject(LD.Files + [GDProj] + LIncs.ToArray);
        // The baseline: the untouched mirror, in each configuration. It must
        // build - against a baseline that fails, every plan "builds" too.
        for var LC in GConfigs do
        begin
          var LErrs := Build(LC);
          for var LE in LErrs do
            GBaseline.AddOrSetValue(LC + '|' + LE, True);
          Writeln(Format('baseline %s: %d error(s)', [LC, Length(LErrs)]));
          for var LE in Copy(LErrs, 0, 6) do
            Writeln('    ', LE);
        end;
        if GBaseline.Count > 0 then
        begin
          Writeln(ErrOutput, 'The untouched mirror does not build - nothing ' +
            'to compare a rename against.');
          ExitCode := 2;
          Exit;
        end;
        Writeln(Format('%d candidate symbol(s), %d unit(s); seed %d',
          [LCands.Count, LUnitCands.Count, GSeed]));
        RandSeed := GSeed;
        for var LI := 1 to GSymbols do
        begin
          if LCands.Count = 0 then
            Break;
          var LPick := Random(LCands.Count);
          TrySymbol(LCands[LPick].Key, LCands[LPick].Value);
          LCands.Delete(LPick);
        end;
        for var LI := 1 to GUnits do
        begin
          if LUnitCands.Count = 0 then
            Break;
          var LPick := Random(LUnitCands.Count);
          TryUnit(LUnitCands[LPick]);
          LUnitCands.Delete(LPick);
        end;
      finally
        GNav.Free;
      end;
    finally
      GProj.Free;
    end;
    Writeln(Format('%d ok, %d refused, %d BROKEN', [GOk, GRefused, GBroken]));
    if GBroken > 0 then
      ExitCode := 1;
  finally
    GBaseline.Free;
    LIncDirs.Free;
    LIncs.Free;
    LUnitCands.Free;
    LCands.Free;
    LOwn.Free;
    LD.Free;
  end;
end;

begin
  try
    GStudio := GetEnvironmentVariable('BDS');
    if GStudio = '' then
      GStudio := 'C:\Program Files (x86)\Embarcadero\Studio\37.0';
    for var LI := 1 to ParamCount do
    begin
      var LArg := ParamStr(LI);
      if LArg.StartsWith('-work:', True) then
        GWork := Norm(LArg.Substring(6))
      else if LArg.StartsWith('-p:', True) then
        if SameText(LArg.Substring(3), 'Win32') then
          GPlatform := pfWin32
        else
          GPlatform := pfWin64
      else if LArg.StartsWith('-studio:', True) then
        GStudio := LArg.Substring(8)
      else if LArg.StartsWith('-L', True) then
        GExtra := GExtra + [Norm(LArg.Substring(2))]
      else if LArg.StartsWith('-configs:', True) then
        GConfigs := LArg.Substring(9).Split([','])
      else if LArg.StartsWith('-n:', True) then
        GSymbols := StrToInt(LArg.Substring(3))
      else if LArg.StartsWith('-units:', True) then
        GUnits := StrToInt(LArg.Substring(7))
      else if LArg.StartsWith('-seed:', True) then
        GSeed := StrToInt(LArg.Substring(6))
      else if LArg.StartsWith('-only:', True) then
        GOnly := LArg.Substring(6)
      else if SameText(LArg, '-selftest') then
        GSelfTest := True
      else if LArg.StartsWith('-dcc:', True) then
        GDcc := LArg.Substring(5)
      else if not LArg.StartsWith('-') then
        GDProj := Norm(LArg);
    end;
    if (GDProj = '') or (GWork = '') then
    begin
      Writeln(ErrOutput, 'Usage: PasTreeRenameOracle <file.dproj> -work:<dir>' +
        ' [-p:<platform>] [-studio:<dir>] [-L<dir>]... [-configs:A,B]' +
        ' [-n:N] [-units:N] [-seed:N] [-only:<name>] [-dcc:<exe>] [-selftest]');
      ExitCode := 2;
      Exit;
    end;
    if GDcc = '' then
      if GPlatform = pfWin32 then
        GDcc := TPath.Combine(GStudio, 'bin\dcc32.exe')
      else
        GDcc := TPath.Combine(GStudio, 'bin\dcc64.exe');
    Run;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
