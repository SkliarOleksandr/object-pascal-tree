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

implementation

uses
  System.SysUtils;

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
