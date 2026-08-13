@echo off
rem Build the PasTree VCL demo. WIN64 ONLY -- see demo\README.md: the demo is
rem never built for Win32, because a real project's closure needs more than a
rem 32-bit address space (the client project holds 3.5 GB; Win32 dies with
rem EOutOfMemory and the failure masquerades as an analyzer defect).
rem Requires SynEdit + VirtualTreeView sources under C:\Repos\3rdlib13.
call "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat"
cd /d "%~dp0"
if not exist out mkdir out
rem Compile the application manifest (native visual styles + PerMonitorV2 DPI).
brcc32 PasTreeDemo.rc
dcc64 -B -Q ^
 -U"%BDS%\lib\win64\release" ^
 -U"..\source" ^
 -U"C:\Repos\3rdlib13\SynEdit\Source" ^
 -U"C:\Repos\3rdlib13\SynEdit\Source\Highlighters" ^
 -U"C:\Repos\3rdlib13\VirtualTreeView\Source" ^
 -I"C:\Repos\3rdlib13\SynEdit\Source" ^
 -I"C:\Repos\3rdlib13\VirtualTreeView\Source" ^
 -NSSystem;System.Win;Winapi;Vcl;Vcl.Imaging;Data;Xml ^
 -N0out -Eout PasTreeDemo.dpr
