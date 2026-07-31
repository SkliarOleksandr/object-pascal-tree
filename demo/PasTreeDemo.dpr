program PasTreeDemo;

// PasTree demo host (VCL). Opens a Delphi project, parses it with PasTree and
// shows source (SynEdit), the file tree (VirtualTrees), diagnostics and AST
// JSON. Build with demo\build.bat (Win32; needs SynEdit + VirtualTreeView).

uses
  Vcl.Forms,
  PasTreeDemo.Main in 'PasTreeDemo.Main.pas' {frmMain},
  PasTreeDemo.Highlighter in 'PasTreeDemo.Highlighter.pas',
  PasTreeDemo.Settings in 'PasTreeDemo.Settings.pas',
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Ast.Json in '..\source\PasTree.Ast.Json.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.Project in '..\source\PasTree.Project.pas',
  PasTree.DProj in '..\source\PasTree.DProj.pas',
  PasTree.Sema.Diagnostics in '..\source\PasTree.Sema.Diagnostics.pas',
  PasTree.Sema.Model in '..\source\PasTree.Sema.Model.pas',
  PasTree.Sema.Builtins in '..\source\PasTree.Sema.Builtins.pas',
  PasTree.Sema.Types in '..\source\PasTree.Sema.Types.pas',
  PasTree.Sema.Resolver in '..\source\PasTree.Sema.Resolver.pas',
  PasTree.Sema.Project in '..\source\PasTree.Sema.Project.pas',
  PasTree.Sema.Nav in '..\source\PasTree.Sema.Nav.pas',
  PasTree.Sema.Dump in '..\source\PasTree.Sema.Dump.pas',
  PasTree.Sema.Async in '..\source\PasTree.Sema.Async.pas';

{$R PasTreeDemo.res}

begin
  // Run Parse fans parse+resolve out across cores (TPasSemaProject); without
  // this the default memory manager sleeps on allocation contention there.
  System.NeverSleepOnMMThreadContention := True;
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TfrmMain, frmMain);
  Application.Run;
end.
