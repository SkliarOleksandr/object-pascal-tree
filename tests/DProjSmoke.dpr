program DProjSmoke;

{ TPasDProj smoke tests: MSBuild-lite condition evaluation, property chaining
  across Base/Platform/Config, file list, search paths, defines, aliases —
  against a fabricated fixture (the real Embarcadero PropertyGroup shape) and
  a sanity pass over this repo's own demo\PasTreeDemo.dproj. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.IOUtils,
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.DProj in '..\source\PasTree.DProj.pas',
  PasTree.TestKit in 'PasTree.TestKit.pas';

var
  GCounter: TPasSuiteCounter;

procedure Ok(const AName: string; ACond: Boolean);
begin
  GCounter.Ok(AName, ACond);
end;

function Contains(const AArr: TArray<string>; const AItem: string): Boolean;
var
  S: string;
begin
  for S in AArr do
    if SameText(S, AItem) or SameText(ExtractFileName(S), AItem) then
      Exit(True);
  Result := False;
end;

const
  // The real Base/Base_Platform/Cfg_1/Cfg_1_Platform/Cfg_2/Cfg_2_Platform
  // chain, as Embarcadero actually generates it (see demo\PasTreeDemo.dproj).
  // Cfg_1 = Release, Cfg_2 = Debug (deliberately non-default numbering, to
  // prove we read it from the conditions rather than assuming Cfg_1=Debug).
  FIXTURE =
    '<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003">'#10 +
    '  <PropertyGroup>'#10 +
    '    <MainSource>Fixture.dpr</MainSource>'#10 +
    '    <Base>True</Base>'#10 +
    '    <Config Condition="''$(Config)''==''''">Debug</Config>'#10 +
    '    <Platform Condition="''$(Platform)''==''''">Win64</Platform>'#10 +
    '  </PropertyGroup>'#10 +
    '  <PropertyGroup Condition="''$(Config)''==''Base'' or ''$(Base)''!=''''">'#10 +
    '    <Base>true</Base>'#10 +
    '  </PropertyGroup>'#10 +
    '  <PropertyGroup Condition="(''$(Platform)''==''Win32'' and ''$(Base)''==''true'') or ''$(Base_Win32)''!=''''">'#10 +
    '    <Base_Win32>true</Base_Win32>'#10 +
    '    <Base>true</Base>'#10 +
    '    <DCC_UnitSearchPath>Win32Only;$(DCC_UnitSearchPath)</DCC_UnitSearchPath>'#10 +
    '  </PropertyGroup>'#10 +
    '  <PropertyGroup Condition="(''$(Platform)''==''Win64'' and ''$(Base)''==''true'') or ''$(Base_Win64)''!=''''">'#10 +
    '    <Base_Win64>true</Base_Win64>'#10 +
    '    <Base>true</Base>'#10 +
    '    <DCC_UnitSearchPath>Win64Only;$(DCC_UnitSearchPath)</DCC_UnitSearchPath>'#10 +
    '  </PropertyGroup>'#10 +
    '  <PropertyGroup Condition="''$(Config)''==''Release'' or ''$(Cfg_1)''!=''''">'#10 +
    '    <Cfg_1>true</Cfg_1>'#10 +
    '    <Base>true</Base>'#10 +
    '    <DCC_Define>RELEASE;$(DCC_Define)</DCC_Define>'#10 +
    '  </PropertyGroup>'#10 +
    '  <PropertyGroup Condition="''$(Config)''==''Debug'' or ''$(Cfg_2)''!=''''">'#10 +
    '    <Cfg_2>true</Cfg_2>'#10 +
    '    <Base>true</Base>'#10 +
    '    <DCC_Define>DEBUG;$(DCC_Define)</DCC_Define>'#10 +
    '  </PropertyGroup>'#10 +
    '  <PropertyGroup Condition="''$(Base)''!=''''">'#10 +
    // A build event in CDATA, placed BEFORE the search path in the same group
    // and containing '>' and '"' — the exact shape Embarcadero emits for any
    // project with build events. Mishandled, it eats to the first '>' inside
    // the payload and desynchronizes the whole document: this group's later
    // children and every following ItemGroup are lost, silently (Load still
    // succeeds). Measured on a real 2500-unit project: 0 search paths and a
    // 1-entry file list, which is why the demo showed an empty file tree.
    '    <PreBuildEvent><![CDATA[echo "a &gt; b" > out.txt'#10 +
    'more $(Base)]]></PreBuildEvent>'#10 +
    '    <DCC_UnitSearchPath>..\common;$(DCC_UnitSearchPath)</DCC_UnitSearchPath>'#10 +
    '    <DCC_UnitAlias>WinTypes=Windows;WinProcs=Windows;$(DCC_UnitAlias)</DCC_UnitAlias>'#10 +
    '  </PropertyGroup>'#10 +
    '  <!-- a comment, for the sibling branch -->'#10 +
    '  <ItemGroup>'#10 +
    '    <DCCReference Include="UnitA.pas"/>'#10 +
    '    <DCCReference Include="sub\UnitB.pas"/>'#10 +
    '    <BuildConfiguration Include="Base"><Key>Base</Key></BuildConfiguration>'#10 +
    '    <BuildConfiguration Include="Release"><Key>Cfg_1</Key></BuildConfiguration>'#10 +
    '    <BuildConfiguration Include="Debug"><Key>Cfg_2</Key></BuildConfiguration>'#10 +
    '  </ItemGroup>'#10 +
    '  <ProjectExtensions>'#10 +
    '    <BorlandProject>'#10 +
    '      <Platforms>'#10 +
    '        <Platform value="Win32">True</Platform>'#10 +
    '        <Platform value="Win64">True</Platform>'#10 +
    '        <Platform value="WinARM64EC">False</Platform>'#10 +
    '      </Platforms>'#10 +
    '    </BorlandProject>'#10 +
    '  </ProjectExtensions>'#10 +
    '</Project>'#10;

var
  LDir, LPath: string;
  LDProj: TPasDProj;
begin
  GCounter.Init;
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_dproj_smoke');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  LPath := TPath.Combine(LDir, 'Fixture.dproj');
  TFile.WriteAllText(LPath, FIXTURE);
  TFile.WriteAllText(TPath.Combine(LDir, 'Fixture.dpr'), 'program Fixture;'#10'begin'#10'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitA.pas'), 'unit UnitA;'#10'interface'#10'implementation'#10'end.'#10);
  TDirectory.CreateDirectory(TPath.Combine(LDir, 'sub'));
  TFile.WriteAllText(TPath.Combine(LDir, 'sub\UnitB.pas'), 'unit UnitB;'#10'interface'#10'implementation'#10'end.'#10);

  try
    // ---- default (no override): dproj's own fallback = Config=Debug, Platform=Win64 ----
    LDProj := TPasDProj.Create;
    try
      Ok('default: Load succeeds', LDProj.Load(LPath));
      Ok('default: platform = Win64', LDProj.Platform = pfWin64);
      Ok('default: config = Debug', SameText(LDProj.Config, 'Debug'));
      Ok('default: MainSource resolved', SameText(ExtractFileName(LDProj.MainSource), 'Fixture.dpr'));
      Ok('default: 3 files (Main+2 DCCReference)', Length(LDProj.Files) = 3);
      Ok('default: UnitA.pas present', Contains(LDProj.Files, 'UnitA.pas'));
      Ok('default: sub\UnitB.pas present', Contains(LDProj.Files, 'UnitB.pas'));
      // Debug -> Cfg_2 (per THIS fixture's numbering) -> DEBUG define, no RELEASE
      Ok('default: DCC_Define has DEBUG', Contains(LDProj.Defines, 'DEBUG'));
      Ok('default: DCC_Define lacks RELEASE', not Contains(LDProj.Defines, 'RELEASE'));
      // search path chain: Base(..\common) + Base_Win64(Win64Only), NOT Win32Only
      Ok('default: search path has ..\common', Contains(LDProj.SearchPaths, 'common'));
      Ok('default: search path has Win64Only', Contains(LDProj.SearchPaths, 'Win64Only'));
      Ok('default: search path lacks Win32Only', not Contains(LDProj.SearchPaths, 'Win32Only'));
      Ok('default: 2 unit aliases', Length(LDProj.UnitAliases) = 2);
      Ok('default: WinTypes->Windows alias',
        (Length(LDProj.UnitAliases) > 0) and
        SameText(LDProj.UnitAliases[0].Alias, 'WinTypes') and
        SameText(LDProj.UnitAliases[0].UnitName, 'Windows'));
      Ok('default: 3 configurations found', Length(LDProj.Configurations) = 3);
      Ok('default: 2 platforms enabled (Win32,Win64; ARM64EC excluded)',
        Length(LDProj.Platforms) = 2);
    finally
      LDProj.Free;
    end;

    // ---- override: force Config=Release, Platform=Win32 ----
    LDProj := TPasDProj.Create;
    try
      Ok('override: Load succeeds', LDProj.Load(LPath, 'Win32', 'Release'));
      Ok('override: platform = Win32', LDProj.Platform = pfWin32);
      Ok('override: config = Release', SameText(LDProj.Config, 'Release'));
      Ok('override: DCC_Define has RELEASE', Contains(LDProj.Defines, 'RELEASE'));
      Ok('override: DCC_Define lacks DEBUG', not Contains(LDProj.Defines, 'DEBUG'));
      Ok('override: search path has Win32Only', Contains(LDProj.SearchPaths, 'Win32Only'));
      Ok('override: search path lacks Win64Only', not Contains(LDProj.SearchPaths, 'Win64Only'));
    finally
      LDProj.Free;
    end;

    // ---- missing file ----
    LDProj := TPasDProj.Create;
    try
      Ok('missing file: Load fails', not LDProj.Load(LPath + '.nope'));
    finally
      LDProj.Free;
    end;

    // ---- real-world sanity: this repo's own demo\PasTreeDemo.dproj ----
    LPath := TPath.GetFullPath(TPath.Combine(ExtractFilePath(ParamStr(0)),
      '..\..\demo\PasTreeDemo.dproj'));
    if TFile.Exists(LPath) then
    begin
      LDProj := TPasDProj.Create;
      try
        Ok('real dproj: Load succeeds', LDProj.Load(LPath));
        Ok('real dproj: MainSource = PasTreeDemo.dpr',
          SameText(ExtractFileName(LDProj.MainSource), 'PasTreeDemo.dpr'));
        Ok('real dproj: Main.pas + source\PasTree.*.pas all present (>= 15 files)',
          Length(LDProj.Files) >= 15);
        Ok('real dproj: PasTree.Sema.Project.pas present',
          Contains(LDProj.Files, 'PasTree.Sema.Project.pas'));
        Ok('real dproj: 3 configurations (Base/Release/Debug)',
          Length(LDProj.Configurations) = 3);
        Ok('real dproj: default platform Win64 (its own fallback)',
          LDProj.Platform = pfWin64);
      finally
        LDProj.Free;
      end;
    end
    else
      Writeln('(skip) demo\PasTreeDemo.dproj not found next to the test exe — real-world check skipped');
  finally
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  if GCounter.Finish('DProjSmoke') then
    ExitCode := 1;
end.
