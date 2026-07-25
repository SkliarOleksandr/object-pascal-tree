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

  // A fixture for the IMPLICIT `System` unit (mirrors the real sLineBreak
  // shape) -- every unit uses it without a `uses` clause naming it. UnitE
  // below references SYS_CONST with NO uses clause at all; CrossResolve's
  // FindInSystemUnit fallback must resolve it (real dcc always can) instead
  // of firing a false E2003.
  UNIT_SYS =
    'unit System;'#10'interface'#10 +
    'const SYS_CONST = 42;'#10'implementation'#10'end.'#10;

  UNIT_E =
    'unit UnitE;'#10'interface'#10'implementation'#10 +
    'procedure R;'#10'var L: Integer;'#10'begin'#10 +
    '  L := SYS_CONST;'#10'end;'#10'end.'#10;

  // Cross-unit overloads: F lives in two used units with different arities.
  UNIT_OVL1 =
    'unit UnitOvl1;'#10'interface'#10 +
    'function F(A: Integer): Integer; overload;'#10'implementation'#10 +
    'function F(A: Integer): Integer; overload; begin Result := A; end;'#10 +
    'end.'#10;
  UNIT_OVL2 =
    'unit UnitOvl2;'#10'interface'#10 +
    'function F(A, B: string): string; overload;'#10'implementation'#10 +
    'function F(A, B: string): string; overload; begin Result := A; end;'#10 +
    'end.'#10;
  UNIT_OVLUSE =
    'unit UnitOvlUse;'#10'interface'#10'uses UnitOvl1, UnitOvl2;'#10 +
    'implementation'#10'procedure T;'#10'var I: Integer;'#10'begin'#10 +
    '  I := F(1);'#10 +        // fits UnitOvl1.F(Integer)
    '  F(''a'', ''b'');'#10 +  // fits UnitOvl2.F(string,string) -> no false E2034
    '  F(1, 2, 3);'#10 +       // fits neither -> E2034
    'end;'#10'end.'#10;

  // Arity candidates must respect SHADOWING: a used unit's global is NOT a
  // candidate for an unqualified call that already binds to something nearer.
  // UnitGdi plays Winapi.Windows (a 3-parameter GetObject); UnitShadow calls
  // `GetObject(I)` with ONE argument in four positions where dcc binds it
  // elsewhere -- an own method, an inherited method from a CROSS-unit
  // ancestor, a nested routine, and a procedural-type field. Real bug: the
  // RTL's own System.Classes.pas:7230 (TStrings.IndexOfObject) plus 45 more
  // across 8 units, all this one cause.
  UNIT_GDI =
    'unit UnitGdi;'#10'interface'#10 +
    'function GetObject(P1, P2, P3: Integer): Integer;'#10 +
    'procedure Fire(S: TObject);'#10'implementation'#10 +
    'function GetObject(P1, P2, P3: Integer): Integer; begin Result := 0; end;'#10 +
    'procedure Fire(S: TObject); begin end;'#10'end.'#10;

  UNIT_ANCESTOR =
    'unit UnitAncestor;'#10'interface'#10 +
    'type'#10 +
    '  TBase = class'#10 +
    '    function GetObject(Index: Integer): TObject; virtual;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TBase.GetObject(Index: Integer): TObject;'#10 +
    'begin Result := nil; end;'#10'end.'#10;

  UNIT_SHADOW =
    'unit UnitShadow;'#10'interface'#10'uses UnitGdi, UnitAncestor;'#10 +
    'type'#10 +
    '  TProc1 = procedure(S: TObject) of object;'#10 +
    '  TOwn = class'#10 +
    '    function GetObject(Index: Integer): TObject; virtual;'#10 +
    '    function Find(O: TObject): Integer;'#10 +
    '  end;'#10 +
    '  TDeriv = class(TBase)'#10 +
    '    function Find(O: TObject): Integer;'#10 +
    '  end;'#10 +
    '  THold = class'#10 +
    '    GetObject: TProc1;'#10 +
    '    procedure Go(S: TObject);'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TOwn.GetObject(Index: Integer): TObject;'#10 +
    'begin Result := nil; end;'#10 +
    // own method wins over UnitGdi.GetObject
    'function TOwn.Find(O: TObject): Integer;'#10 +
    'begin Result := 0; if GetObject(1) = O then Result := 1; end;'#10 +
    // method inherited from a CROSS-unit ancestor also wins
    'function TDeriv.Find(O: TObject): Integer;'#10 +
    'begin Result := 0; if GetObject(1) = O then Result := 1; end;'#10 +
    // a procedural-type FIELD, called through its value
    'procedure THold.Go(S: TObject);'#10 +
    'begin GetObject(S); end;'#10 +
    // a NESTED routine shadows it too
    'procedure UseNested;'#10 +
    '  function GetObject(Index: Integer): TObject;'#10 +
    '  begin Result := nil; end;'#10 +
    'begin'#10 +
    '  if GetObject(0) = nil then Exit;'#10 +
    'end;'#10 +
    // ...but a genuinely cross-unit call with the wrong arity MUST still be
    // caught. At UNIT level nothing shadows GetObject (THold's field lives in
    // the struct scope, TOwn's in its own), so this binds to UnitGdi's
    // 3-parameter global and one argument really is too few.
    'procedure Genuine;'#10 +
    'begin GetObject(1); end;'#10 +
    'end.'#10;

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
  LA, LB, LC, LD, LE, LOvl: TPasSemaModel;
begin
  GPassed := 0; GFailed := 0;
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_proj');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitA.pas'), UNIT_A);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitB.pas'), UNIT_B);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitC.pas'), UNIT_C);
  TFile.WriteAllText(TPath.Combine(LDir, 'System.pas'), UNIT_SYS);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitE.pas'), UNIT_E);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitD.pas'), UNIT_D);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitOvl1.pas'), UNIT_OVL1);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitOvl2.pas'), UNIT_OVL2);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitOvlUse.pas'), UNIT_OVLUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitGdi.pas'), UNIT_GDI);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitAncestor.pas'), UNIT_ANCESTOR);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitShadow.pas'), UNIT_SHADOW);

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

    // E: NO `uses` clause at all, references a name declared ONLY in the
    // IMPLICIT System unit (mirrors the real sLineBreak shape) -- real dcc
    // always resolves this; CrossResolve's FindInSystemUnit fallback must
    // suppress the E2003 that would otherwise fire here.
    LE := ModelByName('unite');
    Ok('E: loaded', Assigned(LE));
    Ok('E: SYS_CONST resolved via implicit System',
      CrossRefTo(LE, 'SYS_CONST', 'SYS_CONST'));
    Ok('E: no E2003 (implicit System, not a false undeclared-id)',
      DiagCount(LE, 'E2003') = 0);

    // Cross-unit overload arity: merged candidate set from UnitOvl1 + UnitOvl2.
    LOvl := ModelByName('unitovluse');
    Ok('Ovl: use unit loaded', Assigned(LOvl));
    Ok('Ovl: uses fully resolved', LOvl.AllUsesResolved);
    Ok('Ovl: E2034 x1 (F(1,2,3) fits neither)', DiagCount(LOvl, 'E2034') = 1);
    Ok('Ovl: no E2035 (merge covers F(1) and F(a,b))',
      DiagCount(LOvl, 'E2035') = 0);

    // Shadowing beats used-unit arity candidates (see UNIT_SHADOW).
    var LShadow := ModelByName('unitshadow');
    Ok('Shadow: use unit loaded', Assigned(LShadow));
    Ok('Shadow: uses fully resolved', LShadow.AllUsesResolved);
    Ok('Shadow: no E2034 at all', DiagCount(LShadow, 'E2034') = 0);
    // Exactly ONE E2035: the genuine `Fire;` (0 args, needs 1). The four
    // shadowed GetObject(1) calls must contribute none.
    Ok('Shadow: exactly 1 E2035 — the genuine cross-unit arity error only, '
      + 'none from the four shadowed GetObject calls',
      DiagCount(LShadow, 'E2035') = 1);

    // Module status / snapshot API: AnalyzeDirectory takes the directory's
    // own units all the way to msCrossReady, and TryGetSnapshot gates on the
    // minimum requested status (never blocks — synchronously everything is
    // already ready).
    var LSnap: TPasSemaModel;
    Ok('status: unita is msCrossReady',
      GProj.ModuleStatus(0) = msCrossReady);
    Ok('status: TryGetSnapshot(msIntfReady) succeeds',
      GProj.TryGetSnapshot(0, msIntfReady, LSnap) and (LSnap = GProj.Model(0)));
    Ok('status: TryGetSnapshot(msCrossReady) succeeds',
      GProj.TryGetSnapshot(0, msCrossReady, LSnap));
    Ok('status: out-of-range id -> msQueued, snapshot fails',
      (GProj.ModuleStatus(9999) = msQueued) and
      (not GProj.TryGetSnapshot(9999, msIntfReady, LSnap)) and
      (LSnap = nil));
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
