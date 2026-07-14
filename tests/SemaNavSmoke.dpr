program SemaNavSmoke;

{ Go-to-declaration smoke tests: fixture units in a temp dir, then IdentAt +
  ResolveDecl checks — same-unit locals, cross-unit types, cross-unit MEMBER
  access (Phase-3c discovered refs), and builtins (no target). }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.IOUtils,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.Project in '..\source\PasTree.Project.pas',
  PasTree.Sema.Diagnostics in '..\source\PasTree.Sema.Diagnostics.pas',
  PasTree.Sema.Model in '..\source\PasTree.Sema.Model.pas',
  PasTree.Sema.Builtins in '..\source\PasTree.Sema.Builtins.pas',
  PasTree.Sema.Resolver in '..\source\PasTree.Sema.Resolver.pas',
  PasTree.Sema.Dump in '..\source\PasTree.Sema.Dump.pas',
  PasTree.Sema.Project in '..\source\PasTree.Sema.Project.pas',
  PasTree.Sema.Nav in '..\source\PasTree.Sema.Nav.pas';

const
  // Line/col layout matters: tests below address positions in these sources.
  UNIT_A =
    'unit NavA;'#10 +                          // 1
    'interface'#10 +                           // 2
    'type'#10 +                                // 3
    '  TThing = record'#10 +                   // 4  (TThing at col 3)
    '    Value: Integer;'#10 +                 // 5  (Value at col 5)
    '  end;'#10 +                              // 6
    'function MakeThing: TThing;'#10 +         // 7  (MakeThing at col 10)
    'implementation'#10 +                      // 8
    'function MakeThing: TThing;'#10 +         // 9
    'begin Result.Value := 1; end;'#10 +       // 10
    'end.'#10;                                 // 11

  UNIT_B =
    'unit NavB;'#10 +                          // 1
    'interface'#10 +                           // 2
    'uses NavA;'#10 +                          // 3
    'var GT: TThing;'#10 +                     // 4  (GT col 5, TThing col 9)
    'implementation'#10 +                      // 5
    'procedure P;'#10 +                        // 6
    'var L: Integer;'#10 +                     // 7  (Integer col 8)
    'begin'#10 +                               // 8
    '  L := GT.Value;'#10 +                    // 9  (GT col 8, Value col 11)
    'end;'#10 +                                // 10
    'end.'#10;                                 // 11

var
  GProj: TPasSemaProject;
  GNav: TPasNavigator;
  GPassed, GFailed: Integer;
  GMidB: Integer;

procedure Ok(const AName: string; ACond: Boolean);
begin
  if ACond then
    Inc(GPassed)
  else
  begin
    Inc(GFailed);
    Writeln('FAIL: ', AName);
  end;
end;

// IdentAt + ResolveDecl in one step; '' expectations are skipped.
procedure CheckNav(const ACase: string; ALine, ACol: Integer;
  const AWantIdent, AWantFile: string; AWantLine, AWantCol: Integer);
var
  LIdent: TPasNavIdent;
  LTarget: TPasNavTarget;
begin
  if not GNav.IdentAt(GMidB, ALine, ACol, LIdent) then
  begin
    Ok(ACase + ': IdentAt', False);
    Exit;
  end;
  Ok(ACase + ': ident name', SameText(LIdent.Name, AWantIdent));
  if not GNav.ResolveDecl(GMidB, LIdent.Node, LTarget) then
  begin
    Ok(ACase + ': ResolveDecl', False);
    Exit;
  end;
  Ok(ACase + ': target file',
    SameText(TPath.GetFileName(LTarget.FilePath), AWantFile));
  Ok(ACase + ': target pos',
    (LTarget.Line = AWantLine) and (LTarget.Col = AWantCol));
end;

var
  LDir: string;
  LIdent: TPasNavIdent;
  LTarget: TPasNavTarget;
begin
  GPassed := 0; GFailed := 0;
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_nav');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'NavA.pas'), UNIT_A);
  TFile.WriteAllText(TPath.Combine(LDir, 'NavB.pas'), UNIT_B);

  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.AnalyzeDirectory(LDir);
    GNav := TPasNavigator.Create(GProj);
    try
      GMidB := GNav.ModelIdOf(TPath.Combine(LDir, 'NavB.pas'));
      Ok('NavB model found', GMidB >= 0);
      Ok('unknown path -> -1', GNav.ModelIdOf('C:\no\such.pas') = -1);

      // Cross-unit type reference: TThing in `var GT: TThing;`.
      CheckNav('type ref', 4, 9, 'TThing', 'NavA.pas', 4, 3);
      // Middle of the token works too (col 12 is inside TThing).
      CheckNav('type ref mid-token', 4, 12, 'TThing', 'NavA.pas', 4, 3);
      // Same-unit var reference: GT in the body -> its decl on line 4.
      CheckNav('local var', 9, 8, 'GT', 'NavB.pas', 4, 5);
      // Cross-unit MEMBER (Phase-3c discovered): GT.Value -> NavA field.
      CheckNav('cross member', 9, 11, 'Value', 'NavA.pas', 5, 5);

      // Builtin: Integer has no source declaration.
      Ok('builtin: IdentAt', GNav.IdentAt(GMidB, 7, 8, LIdent));
      Ok('builtin: no target', not GNav.ResolveDecl(GMidB, LIdent.Node,
        LTarget));

      // Non-identifier position (the ':=' on line 9 is at col 5).
      Ok('symbol pos -> no ident', not GNav.IdentAt(GMidB, 9, 5, LIdent));
    finally
      GNav.Free;
    end;
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  Writeln(Format('=== SemaNavSmoke: %d passed, %d failed ===',
    [GPassed, GFailed]));
  if GFailed > 0 then
    ExitCode := 1;
end.
