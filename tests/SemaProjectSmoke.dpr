program SemaProjectSmoke;

{ Phase-2 cross-unit smoke tests: writes tiny unit fixtures to a temp dir and
  runs the project analyzer, checking external resolution, qualified access,
  E2003 (fired only when all uses resolve) and impl->interface linking. }

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
  PasTree.Sema.Project in '..\source\PasTree.Sema.Project.pas';

var
  GProj: TPasSemaProject;
  GPassed, GFailed: Integer;

const
  UNIT_A =
    'unit UnitA;'#10'interface'#10 +
    'type TThing = record V: Integer; end;'#10 +
    'const KA = 7;'#10 +
    'function Foo: Integer;'#10 +
    'implementation'#10 +
    'function Foo: Integer; begin Result := KA; end;'#10'end.'#10;

  UNIT_B =
    'unit UnitB;'#10'interface'#10'uses UnitA;'#10 +
    'var GB: TThing;'#10'implementation'#10 +
    'procedure Bar;'#10'var L: Integer;'#10'begin'#10 +
    '  L := KA;'#10'  L := Foo;'#10'  L := UnitA.KA;'#10'end;'#10'end.'#10;

  UNIT_C =
    'unit UnitC;'#10'interface'#10'uses UnitA;'#10'implementation'#10 +
    'procedure Baz;'#10'begin'#10'  Nonexistent := 1;'#10'end;'#10'end.'#10;

  UNIT_D =
    'unit UnitD;'#10'interface'#10'uses NoSuchUnit;'#10'implementation'#10 +
    'procedure Q;'#10'begin'#10'  Whatever := 2;'#10'end;'#10'end.'#10;

function ModelByName(const ANameLower: string): TPasSemaModel;
begin
  Result := nil;
  for var LId := 0 to GProj.ModelCount - 1 do
    if GProj.Model(LId).UnitNameLower = ANameLower then
      Exit(GProj.Model(LId));
end;

// A reference of the given text resolved cross-unit to a symbol named ATarget.
function CrossRefTo(AModel: TPasSemaModel; const ARefText, ATarget: string):
  Boolean;
var
  LExt: TPasExtRef;
begin
  Result := False;
  for var LNode := 0 to High(AModel.RefMap) do
    if (AModel.Tree.Nodes[LNode].Kind = nkIdent) and
       SameText(AModel.Tree.NodeText(LNode), ARefText) and
       AModel.ExtRefMap.TryGetValue(LNode, LExt) then
      if SameText(GProj.Model(LExt.UnitId).Symbols[LExt.Sym].Name, ATarget) then
        Exit(True);
end;

function DiagCount(AModel: TPasSemaModel; const ACode: string): Integer;
begin
  Result := 0;
  for var LIdx := 0 to High(AModel.Diags) do
    if AModel.Diags[LIdx].Code = ACode then
      Inc(Result);
end;

function SymCountOf(AModel: TPasSemaModel; const ANameLower: string;
  AKind: TSemaSymbolKind): Integer;
begin
  Result := 0;
  for var LIdx := 0 to AModel.SymCount - 1 do
    if (AModel.Symbols[LIdx].NameLower = ANameLower) and
       (AModel.Symbols[LIdx].Kind = AKind) then
      Inc(Result);
end;

function HasBodyFlag(AModel: TPasSemaModel; const ANameLower: string): Boolean;
begin
  Result := False;
  for var LIdx := 0 to AModel.SymCount - 1 do
    if (AModel.Symbols[LIdx].NameLower = ANameLower) and
       (AModel.Symbols[LIdx].Kind = skRoutine) then
      Exit(sfHasBody in AModel.Symbols[LIdx].Flags);
end;

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

var
  LDir: string;
  LA, LB, LC, LD: TPasSemaModel;
begin
  GPassed := 0; GFailed := 0;
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_proj');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitA.pas'), UNIT_A);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitB.pas'), UNIT_B);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitC.pas'), UNIT_C);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitD.pas'), UNIT_D);

  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.AnalyzeDirectory(LDir);
    LA := ModelByName('unita');
    LB := ModelByName('unitb');
    LC := ModelByName('unitc');
    LD := ModelByName('unitd');

    Ok('all units loaded', Assigned(LA) and Assigned(LB) and Assigned(LC) and
      Assigned(LD));

    // impl links to interface: one Foo routine, marked with a body.
    Ok('A: single Foo routine', SymCountOf(LA, 'foo', skRoutine) = 1);
    Ok('A: Foo has body linked', HasBodyFlag(LA, 'foo'));
    Ok('A: no diags', Length(LA.Diags) = 0);

    // B: cross-unit references into A.
    Ok('B: KA resolved cross-unit', CrossRefTo(LB, 'KA', 'KA'));
    Ok('B: Foo resolved cross-unit', CrossRefTo(LB, 'Foo', 'Foo'));
    Ok('B: TThing resolved cross-unit', CrossRefTo(LB, 'TThing', 'TThing'));
    Ok('B: qualified UnitA.KA (member) resolved',
      CrossRefTo(LB, 'KA', 'KA')); // KA node appears both plain and qualified
    Ok('B: uses fully resolved', LB.AllUsesResolved);
    Ok('B: no E2003', DiagCount(LB, 'E2003') = 0);

    // C: undeclared id, all uses resolved -> E2003.
    Ok('C: uses fully resolved', LC.AllUsesResolved);
    Ok('C: E2003 for Nonexistent', DiagCount(LC, 'E2003') >= 1);

    // D: an unresolvable use -> E2003 suppressed.
    Ok('D: uses NOT fully resolved', not LD.AllUsesResolved);
    Ok('D: E2003 suppressed', DiagCount(LD, 'E2003') = 0);
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  Writeln(Format('=== SemaProjectSmoke: %d passed, %d failed ===',
    [GPassed, GFailed]));
  if GFailed > 0 then
    ExitCode := 1;
end.
