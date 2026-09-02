@echo off
rem Build and run every smoke suite in this directory.
rem
rem WHY THIS EXISTS. The suites were built by hand, with flags reconstructed
rem from memory each time -- and three of them (UnitListSmoke, NavHistorySmoke,
rem DemoSettingsSmoke) link units from ..\demo through relative `in` paths, so
rem they only compile with the CURRENT DIRECTORY set here. Getting that wrong
rem produces "F1026 File not found: '..\demo\...'", which reads like a missing
rem file rather than a wrong cwd. Both facts now live in one place.
rem
rem WIN32, deliberately: these are unit suites over fixtures, not corpus runs.
rem The Win64 rule (see demo\build.bat and the README) is about analyzing a real
rem project's closure, which none of these do.
rem
rem DCUS go to ..\out\dcu\win32 -- the repository's one throwaway directory,
rem shared by every build here, split by platform because the same units also
rem compile for Win64 (tools\, demo\) and PasTree.Types.dcu would otherwise
rem exist twice under one name. Nothing reads a .dcu between runs (every call
rem below passes -B), so that directory exists to be deleted: one path to skip
rem in a backup, one path to clear when a build looks stale.
rem
rem CHECKED BUILDS: -$Q+ (integer overflow) and -$R+ (range). Not a style
rem preference - this library is compiled by whatever project links it, and RAD
rem Studio's stock Debug configuration sets both. Whatever the suites do not
rem exercise with them ON is a behaviour half the hosts get and nothing here
rem tests. Note that -Q, right beside them, is the compiler's QUIET switch and
rem has nothing to do with overflow; the two read alike and that cost a
rem misreading once already (the comment in PasTree.CondEval claiming these
rem suites were checked builds, when they were not).
rem
rem Turned on after 0.15.1, where three FNV hashes raised EIntOverflow under a
rem host's $Q+ because wraparound IS their algorithm. That reached a user as an
rem access violation with no visible cause, in a server built from the IDE
rem rather than by its own script, and took two rounds to find. These flags
rem would have caught it here, in the repository that owns the defect.
setlocal enabledelayedexpansion
call "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat"
cd /d "%~dp0"

set SUITES=ParserSmoke StagedParseSmoke DProjSmoke SemaSmoke SemaTypeSmoke SemaXTypeSmoke SemaOverloadSmoke SemaProjectSmoke SemaNavSmoke SemaCompleteSmoke AsyncSmoke UnitListSmoke NavHistorySmoke DemoSettingsSmoke
set DCU32=%~dp0..\out\dcu\win32
if not exist out mkdir out
if not exist "%DCU32%" mkdir "%DCU32%"

echo === building %SUITES: =% ===
for %%T in (%SUITES%) do (
  dcc32 -B -Q -$Q+ -$R+ -U"%BDS%\lib\win32\release;..\source;..\demo;." -Eout -N0"%DCU32%" "%%T.dpr"
  if errorlevel 1 goto :fail
)

echo === running ===
set FAILED=
for %%T in (%SUITES%) do (
  echo --- %%T
  "out\%%T.exe"
  if errorlevel 1 set FAILED=!FAILED! %%T
)

echo.
if not "!FAILED!"=="" (
  echo SUITES FAILED:!FAILED!
  exit /b 1
)
echo all suites passed
exit /b 0

:fail
echo.
echo BUILD FAILED
exit /b 1
