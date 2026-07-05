program PasTreeDemo;

// PasTree demo host (VCL). Opens a Delphi project, parses it with PasTree and
// shows source (SynEdit), the file tree (VirtualTrees), diagnostics and AST
// JSON. Build with demo\build.bat (Win32; needs SynEdit + VirtualTreeView).

uses
  Vcl.Forms,
  PasTreeDemo.Main in 'PasTreeDemo.Main.pas' {frmMain},
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Ast.Json in '..\source\PasTree.Ast.Json.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.Project in '..\source\PasTree.Project.pas';

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TfrmMain, frmMain);
  Application.Run;
end.
