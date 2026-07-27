program SemaXTypeSmoke;

{ Phase-3c cross-model typing smoke tests: writes tiny unit fixtures to a
  temp dir, runs the project analyzer, and checks ExprTypeX — cross-unit
  Var.Field access, ancestor/alias member walks, constructor calls, and
  generic-parameter substitution (TWrap<Integer>.Get -> Integer). }

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
  UNIT_XA =
    'unit XA;'#10'interface'#10 +
    'type'#10 +
    '  TPair = record'#10 +
    '    X: Integer;'#10 +
    '    Y: Integer;'#10 +
    '  end;'#10 +
    '  TBase = class'#10 +
    '    FP: TPair;'#10 +
    '    constructor Create;'#10 +
    '    function Half: Integer;'#10 +
    '  end;'#10 +
    '  TDerived = class(TBase)'#10 +
    '    FS: string;'#10 +
    '  end;'#10 +
    '  TAlias = TDerived;'#10 +
    'implementation'#10 +
    'constructor TBase.Create; begin end;'#10 +
    'function TBase.Half: Integer; begin Result := 0; end;'#10 +
    'end.'#10;

  UNIT_XG =
    'unit XG;'#10'interface'#10 +
    'type'#10 +
    '  TWrap<T> = class'#10 +
    '    FValue: T;'#10 +
    '    constructor Create;'#10 +
    '    function Get: T;'#10 +
    '    property Value: T read FValue;'#10 +
    '  end;'#10 +
    '  TPairWrap<TKey, TVal> = class'#10 +
    '    FKey: TKey;'#10 +
    '    FVal: TVal;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'constructor TWrap<T>.Create; begin end;'#10 +
    'function TWrap<T>.Get: T; begin Result := FValue; end;'#10 +
    'end.'#10;

  UNIT_XU =
    'unit XU;'#10'interface'#10'uses XA, XG;'#10 +
    'var'#10 +
    '  GD: TDerived;'#10 +
    '  GA: TAlias;'#10 +
    '  GW: TWrap<Integer>;'#10 +
    '  GN: TWrap<TWrap<string>>;'#10 +
    '  GP: TPairWrap<string, Boolean>;'#10 +
    'implementation'#10 +
    'procedure Use;'#10 +
    'var'#10 +
    '  LI: Integer;'#10 +
    '  LS: string;'#10 +
    'begin'#10 +
    '  LI := GD.FP.X;'#10 +
    '  LI := GD.Half;'#10 +
    '  LS := GA.FS;'#10 +
    '  LI := GW.FValue;'#10 +
    '  LI := GW.Get;'#10 +
    '  LI := GW.Value;'#10 +
    '  LS := GN.FValue.FValue;'#10 +
    '  LS := GP.FKey;'#10 +
    '  GD := TDerived.Create;'#10 +
    '  GW := TWrap<Integer>.Create;'#10 +
    'end;'#10 +
    'end.'#10;

  // A helper declared ALONGSIDE the type it extends (15.3.4): its members
  // must be reachable from a DIFFERENT unit, since the join lives inside XH's
  // own model and FindMemberX walks into it. Nested inside another class on
  // purpose — dcc-verified that nesting only namespaces the helper's TYPE
  // name and never confines its activation (spec 15.3.4).
  UNIT_XH =
    'unit XH;'#10'interface'#10 +
    'type'#10 +
    '  TMat = record'#10 +
    '    m11: Integer;'#10 +
    '  end;'#10 +
    '  TOwner = class'#10 +
    '  strict private'#10 +
    '    type'#10 +
    '      TMatHelper = record helper for TMat'#10 +
    '        function Twice: Integer;'#10 +
    '      end;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TOwner.TMatHelper.Twice: Integer; begin Result := m11 * 2; end;'#10 +
    'end.'#10;

  UNIT_XI =
    'unit XI;'#10'interface'#10'uses XH;'#10 +
    'var'#10 +
    '  GM: TMat;'#10 +
    'implementation'#10 +
    'procedure UseHelper;'#10 +
    'var'#10 +
    '  LI: Integer;'#10 +
    'begin'#10 +
    '  LI := GM.m11;'#10 +
    '  LI := GM.Twice;'#10 +
    'end;'#10 +
    'end.'#10;

  // A property specifier naming an accessor INHERITED from another unit:
  // `read GetWordProp` where GetWordProp is TBase's, in XP. The ancestor walk
  // only ever ran for nodes inside a METHOD BODY, so a specifier — which sits
  // in the type declaration — got a straight E2003 (System.Win.
  // InternetExplorer over OleControls' TOleControl, 47 of the RTL's).
  // The bare-inherited-member uses in Work are the control: they already
  // worked, and deferring the WHOLE declaration to the inherited pass (rather
  // than just specifiers) breaks them, because the ancestor reference
  // `class(TBase)` would then be resolved in the same round as the lookups
  // that read it. TNested exists to cover exactly that shape.
  UNIT_XP =
    'unit XP;'#10'interface'#10 +
    'type'#10 +
    '  TBase = class'#10 +
    '  protected'#10 +
    '    FCount: Integer;'#10 +
    '    function GetWordProp(Index: Integer): Boolean;'#10 +
    '    procedure SetWordProp(Index: Integer; Value: Boolean);'#10 +
    '  public'#10 +
    '    procedure Bump;'#10 +
    '    property Count: Integer read FCount;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TBase.GetWordProp(Index: Integer): Boolean; begin Result := False; end;'#10 +
    'procedure TBase.SetWordProp(Index: Integer; Value: Boolean); begin end;'#10 +
    'procedure TBase.Bump; begin Inc(FCount); end;'#10 +
    'end.'#10;

  UNIT_XQ =
    'unit XQ;'#10'interface'#10'uses XP;'#10 +
    'type'#10 +
    '  TDerived = class(TBase)'#10 +
    '  public'#10 +
    '    property Flag: Boolean index 204 read GetWordProp write SetWordProp;'#10 +
    '    procedure Work;'#10 +
    '  end;'#10 +
    '  TOuter = class'#10 +
    '  public type'#10 +
    '    TNested = class(TBase)'#10 +
    '      procedure Deep;'#10 +
    '    end;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure TDerived.Work;'#10 +
    'begin'#10 +
    '  Bump;'#10 +
    '  FCount := FCount + 1;'#10 +
    '  if Count > 0 then Exit;'#10 +
    'end;'#10 +
    'procedure TOuter.TNested.Deep;'#10 +
    'begin'#10 +
    '  Bump;'#10 +               // nested class, ancestor method across units
    '  FCount := 0;'#10 +
    'end;'#10 +
    'end.'#10;

  // with-targets whose TYPE lives in another unit — the shapes Phase 1 cannot
  // resolve on its own, so only the cross-unit pass can. Mirrors
  // System.ObjAuto (`with TVarData(X) do`) and System.Variants (`with P^ do`,
  // `with FindVarData(V)^ do`), where TVarData/PVarData come from System.
  UNIT_XW =
    'unit XW;'#10'interface'#10 +
    'type'#10 +
    '  TVarLike = record'#10 +
    '    VType: Word;'#10 +
    '  end;'#10 +
    '  PVarLike = ^TVarLike;'#10 +
    '  PAlias = PVarLike;'#10 +
    'function FindVar: PVarLike;'#10 +
    'implementation'#10 +
    'function FindVar: PVarLike; begin Result := nil; end;'#10 +
    'end.'#10;

  UNIT_XY =
    'unit XY;'#10'interface'#10'uses XW;'#10 +
    'implementation'#10 +
    'procedure UseWith;'#10 +
    'var'#10 +
    '  Buf: array[0..3] of Integer;'#10 +
    '  LP: PVarLike;'#10 +
    '  LA: PAlias;'#10 +
    'begin'#10 +
    '  with TVarLike(Buf) do'#10 +
    '    VType := 1;'#10 +
    '  with LP^ do'#10 +
    '    VType := 2;'#10 +
    '  with LA^ do'#10 +
    '    VType := 3;'#10 +
    '  with FindVar^ do'#10 +
    '    VType := 4;'#10 +
    '  with XW.TVarLike(Buf) do'#10 +   // qualified cast
    '    VType := 5;'#10 +
    'end;'#10 +
    'end.'#10;

  // Cross-unit overload selection by ARGUMENT TYPES: three global overloads
  // (mirrors System.Math.Min's shape) + method overloads + a generic method
  // whose parameter needs instantiation-frame substitution before scoring.
  UNIT_XO =
    'unit XO;'#10'interface'#10 +
    'function Pick(A: Integer): Integer; overload;'#10 +
    'function Pick(A: Double): Double; overload;'#10 +
    'function Pick(A: string): string; overload;'#10 +
    'type'#10 +
    '  TBox = class'#10 +
    '    function Add(A: Integer): Integer; overload;'#10 +
    '    function Add(A: string): string; overload;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function Pick(A: Integer): Integer; begin Result := A; end;'#10 +
    'function Pick(A: Double): Double; begin Result := A; end;'#10 +
    'function Pick(A: string): string; begin Result := A; end;'#10 +
    'function TBox.Add(A: Integer): Integer; begin Result := A; end;'#10 +
    'function TBox.Add(A: string): string; begin Result := A; end;'#10 +
    'end.'#10;

  UNIT_XV =
    'unit XV;'#10'interface'#10'uses XO, XG;'#10 +
    'var'#10 +
    '  GB: TBox;'#10 +
    '  GWD: TWrap<Double>;'#10 +
    // A LOCAL same-named overload: merged with XO''s set, exact match wins.
    'function Pick(A: Boolean): Boolean; overload;'#10 +
    'implementation'#10 +
    'function Pick(A: Boolean): Boolean; begin Result := A; end;'#10 +
    'procedure UseIt;'#10 +
    'var'#10 +
    '  LI: Integer;'#10 +
    '  LD: Double;'#10 +
    '  LS: string;'#10 +
    '  LB: Boolean;'#10 +
    'begin'#10 +
    '  LI := Pick(11);'#10 +
    '  LD := Pick(2.5);'#10 +
    '  LS := Pick(''s'');'#10 +
    '  LB := Pick(True);'#10 +
    '  LI := GB.Add(7);'#10 +
    '  LS := GB.Add(''x'');'#10 +
    '  LD := GWD.Get;'#10 +
    'end;'#10 +
    'end.'#10;

function ModelByName(const ANameLower: string): TPasSemaModel;
begin
  Result := nil;
  for var LId := 0 to GProj.ModelCount - 1 do
    if GProj.Model(LId).UnitNameLower = ANameLower then
      Exit(GProj.Model(LId));
end;

// The node's source text: its visible tokens joined without whitespace
// ('GD.FP.X') — enough to address an expression in the fixtures uniquely.
// An nkMember's own FirstToken is the '.', so the span starts at the
// LEFTMOST DESCENDANT's first token (the base expression), not the node's.
function SpanText(AModel: TPasSemaModel; ANode: Integer): string;
var
  LLeft, LFirst, LLast, LTok: Integer;
begin
  LLeft := ANode;
  LFirst := AModel.Tree.Nodes[ANode].FirstToken;
  while AModel.Tree.Nodes[LLeft].FirstChild <> NIL_NODE do
  begin
    LLeft := AModel.Tree.Nodes[LLeft].FirstChild;
    if (AModel.Tree.Nodes[LLeft].FirstToken >= 0) and
       (AModel.Tree.Nodes[LLeft].FirstToken < LFirst) then
      LFirst := AModel.Tree.Nodes[LLeft].FirstToken;
  end;
  LLast := AModel.Tree.Nodes[ANode].LastToken;
  Result := '';
  for LTok := LFirst to LLast do
    if (LTok >= 0) and (LTok <= High(AModel.Tree.Source.Visible)) then
      Result := Result + AModel.Tree.Source.VisibleText(LTok);
end;

// XTypeText of the expression spelled AExpr (first node with a cross type;
// falls back to the intra-unit type name; '?' when untyped).
function XTypeOf(AModel: TPasSemaModel; const AExpr: string): string;
var
  LX: TSemaXType;
begin
  Result := '?';
  for var LNode := 0 to High(AModel.RefMap) do
    if (AModel.Tree.Nodes[LNode].Kind in [nkIdent, nkMember, nkCall,
        nkTypeArgs]) and (SpanText(AModel, LNode) = AExpr) then
    begin
      if AModel.ExprTypeX.TryGetValue(LNode, LX) then
        Exit(GProj.XTypeText(LX));
      if AModel.ExprType[LNode] <> NIL_SYM then
        Exit(AModel.Symbols[AModel.ExprType[LNode]].Name);
    end;
end;

// The unit name of the overload CrossType selected for the call spelled
// AExpr ('?' when no CallTargetX was recorded) — the future overload-precise
// navigation jump reads the same map.
function CallTargetUnitOf(AModel: TPasSemaModel; const AExpr: string): string;
var
  LExt: TPasExtRef;
begin
  Result := '?';
  for var LNode := 0 to High(AModel.RefMap) do
    if (AModel.Tree.Nodes[LNode].Kind = nkCall) and
       (SpanText(AModel, LNode) = AExpr) and
       AModel.CallTargetX.TryGetValue(LNode, LExt) then
      Exit(GProj.Model(LExt.UnitId).UnitNameLower);
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

procedure Eq(const AName, AGot, AWant: string);
begin
  if AGot = AWant then
    Inc(GPassed)
  else
  begin
    Inc(GFailed);
    Writeln('FAIL: ', AName, ' — got "', AGot, '", want "', AWant, '"');
  end;
end;

var
  LDir: string;
  LU, LV, LH, LW, LQ: TPasSemaModel;
begin
  GPassed := 0; GFailed := 0;
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_xtype');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'XA.pas'), UNIT_XA);
  TFile.WriteAllText(TPath.Combine(LDir, 'XG.pas'), UNIT_XG);
  TFile.WriteAllText(TPath.Combine(LDir, 'XU.pas'), UNIT_XU);
  TFile.WriteAllText(TPath.Combine(LDir, 'XO.pas'), UNIT_XO);
  TFile.WriteAllText(TPath.Combine(LDir, 'XV.pas'), UNIT_XV);
  TFile.WriteAllText(TPath.Combine(LDir, 'XH.pas'), UNIT_XH);
  TFile.WriteAllText(TPath.Combine(LDir, 'XI.pas'), UNIT_XI);
  TFile.WriteAllText(TPath.Combine(LDir, 'XW.pas'), UNIT_XW);
  TFile.WriteAllText(TPath.Combine(LDir, 'XY.pas'), UNIT_XY);
  TFile.WriteAllText(TPath.Combine(LDir, 'XP.pas'), UNIT_XP);
  TFile.WriteAllText(TPath.Combine(LDir, 'XQ.pas'), UNIT_XQ);

  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.AnalyzeDirectory(LDir);
    LU := ModelByName('xu');
    Ok('XU loaded', Assigned(LU));
    Ok('XU: no diags at all', Length(LU.Diags) = 0);

    // Cross-unit member access, nested and through the ancestor / alias.
    Eq('GD.FP is TPair', XTypeOf(LU, 'GD.FP'), 'TPair');
    Eq('GD.FP.X is Integer', XTypeOf(LU, 'GD.FP.X'), 'Integer');
    Eq('GD.Half is Integer', XTypeOf(LU, 'GD.Half'), 'Integer');
    Eq('GA.FS is string (alias walk)', XTypeOf(LU, 'GA.FS'), 'string');

    // Generic instantiation + parameter substitution.
    Eq('GW.FValue is Integer', XTypeOf(LU, 'GW.FValue'), 'Integer');
    Eq('GW.Get is Integer', XTypeOf(LU, 'GW.Get'), 'Integer');
    Eq('GW.Value is Integer (property)', XTypeOf(LU, 'GW.Value'), 'Integer');
    Eq('GN.FValue is TWrap<string> (nested)',
      XTypeOf(LU, 'GN.FValue'), 'TWrap<string>');
    Eq('GN.FValue.FValue is string', XTypeOf(LU, 'GN.FValue.FValue'), 'string');
    Eq('GP.FKey is string (multi-param)', XTypeOf(LU, 'GP.FKey'), 'string');

    // Constructor calls yield the class type (incl. the instantiated one).
    Eq('TDerived.Create is TDerived',
      XTypeOf(LU, 'TDerived.Create'), 'TDerived');
    Eq('TWrap<Integer>.Create is TWrap<Integer>',
      XTypeOf(LU, 'TWrap<Integer>.Create'), 'TWrap<Integer>');

    // Instances are deduped: TWrap<Integer> used twice, TWrap<string>,
    // TWrap<TWrap<string>>, TPairWrap<string,Boolean>, and XV's TWrap<Double>
    // -> 5 distinct.
    Ok('instance table deduped (5)', GProj.InstanceCount = 5);

    // ---- Cross-unit overload selection by ARGUMENT TYPES ----
    LV := ModelByName('xv');
    Ok('XV loaded', Assigned(LV));
    Ok('XV: no diags (esp. no false E2010 from the local-overload shadow)',
      Length(LV.Diags) = 0);
    // Three same-arity imported overloads (the System.Math.Min shape): the
    // argument's type picks the overload — and thus the call's result type.
    Eq('Pick(11) -> Integer overload', XTypeOf(LV, 'Pick(11)'), 'Integer');
    Eq('Pick(2.5) -> Double overload', XTypeOf(LV, 'Pick(2.5)'), 'Double');
    Eq('Pick(''s'') -> string overload',
      XTypeOf(LV, 'Pick(''s'')'), 'string');
    // The LOCAL same-named overload joins the merged candidate set and wins
    // on an exact match — dcc's merge semantics.
    Eq('Pick(True) -> the local Boolean overload',
      XTypeOf(LV, 'Pick(True)'), 'Boolean');
    // Method overloads across units.
    Eq('GB.Add(7) -> Integer method overload',
      XTypeOf(LV, 'GB.Add(7)'), 'Integer');
    Eq('GB.Add(''x'') -> string method overload',
      XTypeOf(LV, 'GB.Add(''x'')'), 'string');
    // Generic member result substituted in the instantiation frame (control).
    Eq('GWD.Get -> Double', XTypeOf(LV, 'GWD.Get'), 'Double');
    // The chosen overload is recorded (mid, sym) for navigation.
    Eq('CallTargetX: Pick(2.5) selected XO''s overload',
      CallTargetUnitOf(LV, 'Pick(2.5)'), 'xo');
    Eq('CallTargetX: Pick(True) selected the local one',
      CallTargetUnitOf(LV, 'Pick(True)'), 'xv');

    // ---- Helper members reachable ACROSS units (15.3.4) ----
    // The helper is declared in XH beside TMat and nested inside a class,
    // strict private; XI never names TOwner. Both must type identically.
    LH := ModelByName('xi');
    Ok('XI loaded', Assigned(LH));
    Ok('XI: no diags at all', Length(LH.Diags) = 0);
    Eq('GM.m11 is Integer (plain field, control)',
      XTypeOf(LH, 'GM.m11'), 'Integer');
    Eq('GM.Twice is Integer (nested strict-private helper, cross-unit)',
      XTypeOf(LH, 'GM.Twice'), 'Integer');

    // ---- inherited members reached from another unit ----
    LQ := ModelByName('xq');
    Ok('XQ loaded', Assigned(LQ));
    Ok('XQ: no diags (inherited accessors in property specifiers, and bare '
      + 'inherited members in nested-class method bodies)',
      Length(LQ.Diags) = 0);
    // Positive: the specifier's accessor must type to its declared result,
    // so this cannot pass by merely staying quiet.
    Eq('a property specifier binds to the ANCESTOR''s accessor',
      XTypeOf(LQ, 'GetWordProp'), 'Boolean');

    // ---- with-targets whose type lives in another unit ----
    // Cast, deref of a variable, deref through an alias chain, deref of a
    // call result, and a qualified cast. Every VType write below must bind to
    // XW's field; a miss leaves the with-body unresolved and E2003s.
    LW := ModelByName('xy');
    Ok('XY loaded', Assigned(LW));
    Ok('XY: no diags at all (cast / deref with-targets)',
      Length(LW.Diags) = 0);
    // Positive, so the check cannot pass merely by staying silent: the
    // with-body's VType must actually TYPE to XW's field type.
    Eq('with-target member types through to the field',
      XTypeOf(LW, 'VType'), 'Word');
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  Writeln(Format('=== SemaXTypeSmoke: %d passed, %d failed ===',
    [GPassed, GFailed]));
  if GFailed > 0 then
    ExitCode := 1;
end.
