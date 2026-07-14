program SemaNavSmoke;

{ Go-to-declaration smoke tests: fixture units in a temp dir, then IdentAt +
  ResolveDecl checks — same-unit locals, cross-unit types, cross-unit MEMBER
  access (Phase-3c discovered refs), a builtin name a used unit actually
  declares (the TBytes/SysUtils shape), the IMPLICIT System unit (TObject/
  TArray<T> — real declarations, never in any UsesList), the implicit Result,
  and pure builtins (no target). }

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
  // Line/col layout matters: the checks below address exact positions.
  UNIT_A =
    'unit NavA;'#10 +                          // 1
    'interface'#10 +                           // 2
    'type'#10 +                                // 3
    '  TThing = record'#10 +                   // 4  TThing at col 3
    '    Value: Integer;'#10 +                 // 5  Value at col 5
    '  end;'#10 +                              // 6
    'function MakeThing: TThing;'#10 +         // 7
    'implementation'#10 +                      // 8
    'function MakeThing: TThing;'#10 +         // 9
    'begin Result.Value := 1; end;'#10 +       // 10
    'end.'#10;                                 // 11

  // Declares TBytes — a name ALSO seeded as a compiler builtin. A reference to
  // it in NavB resolves locally to the builtin (no DeclNode); the used-unit
  // fallback must find THIS declaration. Mirrors TBytes / System.SysUtils.
  UNIT_C =
    'unit NavC;'#10 +                          // 1
    'interface'#10 +                           // 2
    'type'#10 +                                // 3
    '  TBytes = record'#10 +                   // 4  TBytes at col 3
    '    Len: Integer;'#10 +                   // 5
    '  end;'#10 +                              // 6
    'implementation'#10 +                      // 7
    'end.'#10;                                 // 8

  // A fixture for the IMPLICIT `System` unit — NEVER named in any `uses`
  // clause (that's the whole point: every unit uses it without saying so),
  // yet TObject/TArray<T> below are REAL declarations PasTree.Sema.Nav must
  // find via TPasSemaProject.EnsureSystemUnit. Mirrors real System.pas.
  // TObject.Free exercises the MEMBER fallback: the synthetic builtin
  // TObject symbol has no MemberScope, so FindMemberX must redirect to
  // THIS real class body to resolve `.Free` at all (see FindMemberX's
  // ResolveRealDecl call for the "builtin, nowhere to go" case).
  UNIT_SYS =
    'unit System;'#10 +                        // 1
    'interface'#10 +                           // 2
    'type'#10 +                                // 3
    '  TArray<T> = array of T;'#10 +           // 4  TArray col 3
    '  TObject = class'#10 +                   // 5  TObject col 3
    '    constructor Create;'#10 +              // 6
    '    procedure Free;'#10 +                  // 7  Free col 15
    '  end;'#10 +                              // 8
    'implementation'#10 +                      // 9
    'constructor TObject.Create;'#10 +          // 10
    'begin'#10 +                               // 11
    'end;'#10 +                                // 12
    'procedure TObject.Free;'#10 +              // 13
    'begin'#10 +                               // 14
    'end;'#10 +                                // 15
    'end.'#10;                                 // 16

  UNIT_B =
    'unit NavB;'#10 +                          // 1
    'interface'#10 +                           // 2
    'uses NavA, NavC;'#10 +                    // 3  (NOT System — implicit)
    'var GT: TThing;'#10 +                     // 4  GT col 5, TThing col 9
    'implementation'#10 +                      // 5
    'procedure P;'#10 +                        // 6
    'var'#10 +                                 // 7
    '  L: Integer;'#10 +                       // 8  Integer col 6
    '  B: TBytes;'#10 +                        // 9  TBytes col 6
    '  O: TObject;'#10 +                       // 10  TObject col 6
    '  A: TArray<Integer>;'#10 +               // 11  TArray col 6
    'begin'#10 +                               // 12
    '  L := GT.Value;'#10 +                    // 13  GT col 8, Value col 11
    '  O.Free;'#10 +                           // 14  Free col 5
    'end;'#10 +                                // 15
    'function GetLen: Integer;'#10 +           // 16  GetLen col 10
    'begin'#10 +                               // 17
    '  Result := 0;'#10 +                      // 18  Result col 3
    'end;'#10 +                                // 19
    'end.'#10;                                 // 20

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

// IdentAt + ResolveDecl in one step.
procedure CheckNav(const ACase: string; ALine, ACol: Integer;
  const AWantIdent, AWantFile: string; AWantLine, AWantCol: Integer);
var
  LIdent: TPasNavIdent;
  LTarget: TPasNavTarget;
begin
  if not GNav.IdentAt(GMidB, ALine, ACol, {out} LIdent) then
  begin
    Ok(ACase + ': IdentAt', False);
    Exit;
  end;
  Ok(ACase + ': ident name', SameText(LIdent.Name, AWantIdent));
  if not GNav.ResolveDecl(GMidB, LIdent.Node, {out} LTarget) then
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
  TFile.WriteAllText(TPath.Combine(LDir, 'NavC.pas'), UNIT_C);
  TFile.WriteAllText(TPath.Combine(LDir, 'System.pas'), UNIT_SYS);
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
      CheckNav('local var', 13, 8, 'GT', 'NavB.pas', 4, 5);
      // Cross-unit MEMBER (Phase-3c discovered): GT.Value -> NavA field.
      CheckNav('cross member', 13, 11, 'Value', 'NavA.pas', 5, 5);
      // Builtin name a used unit actually declares: TBytes -> NavC.
      CheckNav('builtin-in-uses', 9, 6, 'TBytes', 'NavC.pas', 4, 3);
      // Implicit System unit, no `uses System` anywhere: TObject/TArray<T>.
      CheckNav('implicit System: TObject', 10, 6, 'TObject', 'System.pas', 5, 3);
      CheckNav('implicit System: TArray', 11, 6, 'TArray', 'System.pas', 4, 3);
      // MEMBER access through a builtin: O.Free — the synthetic TObject
      // symbol has no MemberScope; FindMemberX must redirect to the real
      // TObject class body (System.pas) to resolve `.Free` at all.
      CheckNav('member through builtin: O.Free', 14, 5, 'Free', 'System.pas',
        7, 15);
      // Implicit Result -> its enclosing routine's declaration (GetLen).
      CheckNav('result -> routine', 18, 3, 'Result', 'NavB.pas', 16, 10);

      // Pure builtin: Integer has no source declaration anywhere in uses.
      Ok('builtin: IdentAt', GNav.IdentAt(GMidB, 8, 6, {out} LIdent));
      Ok('builtin: no target', not GNav.ResolveDecl(GMidB, LIdent.Node,
        {out} LTarget));

      // Non-identifier position (the ':' of ':=' on line 13 is at col 5).
      Ok('symbol pos -> no ident', not GNav.IdentAt(GMidB, 13, 5, {out} LIdent));
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
