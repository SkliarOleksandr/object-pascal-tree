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
  LU: TPasSemaModel;
begin
  GPassed := 0; GFailed := 0;
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_xtype');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'XA.pas'), UNIT_XA);
  TFile.WriteAllText(TPath.Combine(LDir, 'XG.pas'), UNIT_XG);
  TFile.WriteAllText(TPath.Combine(LDir, 'XU.pas'), UNIT_XU);

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
    // TWrap<TWrap<string>>, TPairWrap<string,Boolean> -> 4 distinct.
    Ok('instance table deduped (4)', GProj.InstanceCount = 4);
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
