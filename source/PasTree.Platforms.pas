unit PasTree.Platforms;

{
  PasTree — target platform presets.

  A "platform" for the preprocessor is (a) the set of predefined
  conditional symbols and (b) the type sizes the $IF evaluator needs
  (SizeOf(Pointer), SizeOf(Extended)).

  The list covers the Delphi 13.x target platforms; symbols follow the
  official "Predefined Conditionals" documentation. Version symbols
  (VER370, CONDITIONALEXPRESSIONS, UNICODE) are common to all.

  The intended long-term source of the platform is the project's .dproj
  (Platform/ActiveConfig); until project parsing lands, callers choose a
  preset explicitly. Win32 is the default in the tools as the most common
  target in the wild.

  NB (verify): WinArm64 (13.1, Arm64EC) symbol set is asserted from release
  coverage, not yet from a shipping compiler run.
}

interface

uses
  PasTree.Preprocessor;

type
  TPasPlatform = (
    pfWin32,
    pfWin64,
    pfWinArm64,       // 13.1+, Arm64EC
    pfMacOS64,        // Intel
    pfMacOSArm64,
    pfIOSDevice64,
    pfIOSSimArm64,
    pfAndroid32,      // Arm 32-bit
    pfAndroid64,      // Arm 64-bit
    pfLinux64         // Intel x64
  );

  { One dcc -A entry: the spelling written in `uses`, and what it really names. }
  TPasUnitAliasDef = record
    Alias: string;
    UnitName: string;
  end;

  TPasPlatformInfo = record
    Name: string;             // canonical name, matches .dproj Platform values
    Defines: TArray<string>;  // platform-specific predefined symbols
    PointerBytes: Integer;
    ExtendedBytes: Integer;   // 10 on Win32-Intel, 8 elsewhere
    IsWindows: Boolean;
    IsPosix: Boolean;
    Is64Bit: Boolean;
  end;

const
  { Symbols shared by every target. }
  COMMON_DEFINES: array[0..2] of string =
    ('VER370', 'CONDITIONALEXPRESSIONS', 'UNICODE');

function PlatformInfo(APlatform: TPasPlatform): TPasPlatformInfo;

{ Full define set (common + platform) as a fresh TPasDefines the caller owns. }
function CreatePlatformDefines(APlatform: TPasPlatform): TPasDefines;

{ Parses a platform name ('Win32', 'OSX64', 'Android'...); case-insensitive,
  accepts both our canonical names and common .dproj spellings. }
function TryParsePlatformName(const AName: string;
  out APlatform: TPasPlatform): Boolean;

function PlatformName(APlatform: TPasPlatform): string;

{ The IDE's DEFAULT `Unit scope names` (Project Options > Delphi Compiler, dcc
  -NS) — what a project inherits when its .dproj says nothing extra.

  A host needs this when there IS no .dproj: a bare .dpr/.dpk or a directory
  scan. Without it every legacy unqualified import fails, because dcc itself
  has NO built-in namespaces (verified: dcc32 with --no-config cannot even find
  `System`) -- the list comes from the project template, not the compiler. That
  is what made a package of untouched VCL sources report `uses Windows,
  SysUtils, Classes, Graphics` as four F1027s.

  Both groups are read out of a real IDE-written .dproj (demo/PasTreeDemo.dproj,
  a VCL Windows app): the Winapi/*.Win group sits in a Windows-conditioned
  property group, the rest in the platform-neutral base -- so the split here is
  the .dproj's own, not an invention. Concatenated they are exactly the string
  the IDE shows for a Win64 target.

  The Vcl* entries are kept on every platform: a prefix that names no real file
  costs one failed lookup and nothing else, whereas dropping it would break a
  Windows-only unit reached from a cross-platform scan. NB the FireMonkey
  templates add their own entries — not listed here, because every FMX unit is
  already fully qualified and needs no prefix. }
function PasDefaultNamespaces(APlatform: TPasPlatform): TArray<string>;

{ The IDE's DEFAULT unit aliases (dcc -A) — the sibling of the list above, and
  read straight out of CodeGear.Common.Targets, which builds them in the same
  two groups:

    <UnitAliases>Generics.Collections=System.Generics.Collections;
                 Generics.Defaults=System.Generics.Defaults</UnitAliases>
    <UnitAliases Condition="Win32 Or Win64 Or WinArm64EC Or ...">
      $(UnitAliases);WinTypes=Winapi.Windows;WinProcs=Winapi.Windows;
      DbiTypes=BDE;DbiProcs=BDE;DbiErrs=BDE</UnitAliases>

  One difference from the namespaces matters: the next line there is
  `<UnitAliases Condition="'$(DCC_UnitAlias)'!=''">$(DCC_UnitAlias)$(UnitAliases)`
  — the project's own aliases are PREPENDED, not substituted. So these defaults
  apply even to a project that declares its own, and a host must add them first
  and let the project's entries override on collision, never skip them. }
function PasDefaultUnitAliases(
  APlatform: TPasPlatform): TArray<TPasUnitAliasDef>;

implementation

uses
  System.SysUtils;

const
  // Windows-conditioned group, first because the IDE puts it first.
  NS_WINDOWS: array[0..6] of string =
    ('Winapi', 'System.Win', 'Data.Win', 'Datasnap.Win', 'Web.Win', 'Soap.Win',
     'Xml.Win');
  // Platform-neutral base group.
  NS_BASE: array[0..10] of string =
    ('Vcl', 'Vcl.Imaging', 'Vcl.Touch', 'Vcl.Samples', 'Vcl.Shell', 'System',
     'Xml', 'Data', 'Datasnap', 'Web', 'Soap');

function PasDefaultNamespaces(APlatform: TPasPlatform): TArray<string>;
begin
  Result := nil;
  if PlatformInfo(APlatform).IsWindows then
    for var LName in NS_WINDOWS do
      Result := Result + [LName];
  for var LName in NS_BASE do
    Result := Result + [LName];
end;

function PasDefaultUnitAliases(
  APlatform: TPasPlatform): TArray<TPasUnitAliasDef>;

  procedure Add(const AAlias, AUnit: string);
  var
    LDef: TPasUnitAliasDef;
  begin
    LDef.Alias := AAlias;
    LDef.UnitName := AUnit;
    Result := Result + [LDef];
  end;

begin
  Result := nil;
  Add('Generics.Collections', 'System.Generics.Collections');
  Add('Generics.Defaults', 'System.Generics.Defaults');
  if PlatformInfo(APlatform).IsWindows then
  begin
    Add('WinTypes', 'Winapi.Windows');
    Add('WinProcs', 'Winapi.Windows');
    // BDE ships no source with Studio, so these three normally end up as an
    // honest F1027 rather than a resolution. Listed anyway: dropping them would
    // silently turn `uses DbiTypes` into "unit not found: DbiTypes", naming a
    // unit that does not exist even in principle instead of the one dcc looks
    // for.
    Add('DbiTypes', 'BDE');
    Add('DbiProcs', 'BDE');
    Add('DbiErrs', 'BDE');
  end;
end;

function PlatformInfo(APlatform: TPasPlatform): TPasPlatformInfo;
begin
  Result.PointerBytes := 8;
  Result.ExtendedBytes := 8;
  Result.IsWindows := False;
  Result.IsPosix := False;
  Result.Is64Bit := True;
  case APlatform of
    pfWin32:
      begin
        Result.Name := 'Win32';
        Result.Defines := ['MSWINDOWS', 'WIN32', 'CPU386', 'CPUX86',
          'CPU32BITS', 'CPUINTEL', 'ASSEMBLER'];
        Result.PointerBytes := 4;
        Result.ExtendedBytes := 10;
        Result.IsWindows := True;
        Result.Is64Bit := False;
      end;
    pfWin64:
      begin
        Result.Name := 'Win64';
        Result.Defines := ['MSWINDOWS', 'WIN64', 'CPUX64', 'CPU64BITS',
          'CPUINTEL', 'ASSEMBLER'];
        Result.IsWindows := True;
      end;
    pfWinArm64:
      begin
        Result.Name := 'WinArm64';
        // 13.1 Arm64EC target; LLVM-based toolchain (verify against a
        // shipping compiler when available).
        Result.Defines := ['MSWINDOWS', 'WIN64', 'WINARM64', 'CPUARM',
          'CPUARM64', 'CPU64BITS', 'EXTERNALLINKER'];
        Result.IsWindows := True;
      end;
    pfMacOS64:
      begin
        Result.Name := 'OSX64';
        Result.Defines := ['MACOS', 'MACOS64', 'POSIX', 'POSIX64', 'CPUX64',
          'CPU64BITS', 'CPUINTEL', 'EXTERNALLINKER', 'PIC',
          'UNDERSCOREIMPORTNAME'];
        Result.IsPosix := True;
      end;
    pfMacOSArm64:
      begin
        Result.Name := 'OSXARM64';
        Result.Defines := ['MACOS', 'MACOS64', 'POSIX', 'POSIX64', 'CPUARM',
          'CPUARM64', 'CPU64BITS', 'EXTERNALLINKER', 'PIC',
          'UNDERSCOREIMPORTNAME'];
        Result.IsPosix := True;
      end;
    pfIOSDevice64:
      begin
        Result.Name := 'iOSDevice64';
        // iOS defines MACOS as well (per official docs).
        Result.Defines := ['IOS', 'IOS64', 'MACOS', 'MACOS64', 'POSIX',
          'POSIX64', 'CPUARM', 'CPUARM64', 'CPU64BITS', 'EXTERNALLINKER',
          'PIC', 'UNDERSCOREIMPORTNAME'];
        Result.IsPosix := True;
      end;
    pfIOSSimArm64:
      begin
        Result.Name := 'iOSSimARM64';
        Result.Defines := ['IOS', 'IOS64', 'IOSSIMULATOR', 'MACOS',
          'MACOS64', 'POSIX', 'POSIX64', 'CPUARM', 'CPUARM64', 'CPU64BITS',
          'EXTERNALLINKER', 'PIC', 'UNDERSCOREIMPORTNAME'];
        Result.IsPosix := True;
      end;
    pfAndroid32:
      begin
        Result.Name := 'Android';
        Result.Defines := ['ANDROID', 'ANDROID32ARM', 'POSIX', 'POSIX32',
          'CPUARM', 'CPUARM32', 'CPU32BITS', 'EXTERNALLINKER', 'PIC'];
        Result.PointerBytes := 4;
        Result.IsPosix := True;
        Result.Is64Bit := False;
      end;
    pfAndroid64:
      begin
        Result.Name := 'Android64';
        Result.Defines := ['ANDROID', 'ANDROID64', 'POSIX', 'POSIX64',
          'CPUARM', 'CPUARM64', 'CPU64BITS', 'EXTERNALLINKER', 'PIC'];
        Result.IsPosix := True;
      end;
    pfLinux64:
      begin
        Result.Name := 'Linux64';
        Result.Defines := ['LINUX', 'LINUX64', 'POSIX', 'POSIX64', 'CPUX64',
          'CPU64BITS', 'CPUINTEL', 'EXTERNALLINKER', 'PIC'];
        Result.IsPosix := True;
      end;
  end;
end;

function CreatePlatformDefines(APlatform: TPasPlatform): TPasDefines;
var
  LName: string;
begin
  Result := TPasDefines.Create;
  for LName in COMMON_DEFINES do
    Result.Define(LName);
  for LName in PlatformInfo(APlatform).Defines do
    Result.Define(LName);
end;

function TryParsePlatformName(const AName: string;
  out APlatform: TPasPlatform): Boolean;
var
  LPlatform: TPasPlatform;
begin
  for LPlatform := Low(TPasPlatform) to High(TPasPlatform) do
    if SameText(PlatformInfo(LPlatform).Name, AName) then
    begin
      APlatform := LPlatform;
      Exit(True);
    end;
  // Common aliases.
  if SameText(AName, 'macOS64') or SameText(AName, 'OSX') then
  begin
    APlatform := pfMacOS64;
    Exit(True);
  end;
  if SameText(AName, 'macOSARM64') then
  begin
    APlatform := pfMacOSArm64;
    Exit(True);
  end;
  if SameText(AName, 'Android32') then
  begin
    APlatform := pfAndroid32;
    Exit(True);
  end;
  Result := False;
end;

function PlatformName(APlatform: TPasPlatform): string;
begin
  Result := PlatformInfo(APlatform).Name;
end;

end.
