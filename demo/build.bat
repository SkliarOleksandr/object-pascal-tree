@echo off
rem Build the PasTree VCL demo (Win32).
rem Requires SynEdit + VirtualTreeView sources under C:\Repos\3rdlib13.
call "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat"
cd /d "%~dp0"
if not exist out mkdir out
dcc32 -B -Q ^
 -U"%BDS%\lib\win32\release" ^
 -U"..\source" ^
 -U"C:\Repos\3rdlib13\SynEdit\Source" ^
 -U"C:\Repos\3rdlib13\SynEdit\Source\Highlighters" ^
 -U"C:\Repos\3rdlib13\VirtualTreeView\Source" ^
 -I"C:\Repos\3rdlib13\SynEdit\Source" ^
 -I"C:\Repos\3rdlib13\VirtualTreeView\Source" ^
 -NSSystem;System.Win;Winapi;Vcl;Vcl.Imaging;Data;Xml ^
 -N0out -Eout PasTreeDemo.dpr
