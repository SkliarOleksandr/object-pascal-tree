program SemaTypeSmoke;

{ Phase-3a type-checker smoke tests: expression typing + E2010/E2015. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.Sema.Diagnostics in '..\source\PasTree.Sema.Diagnostics.pas',
  PasTree.Sema.Model in '..\source\PasTree.Sema.Model.pas',
  PasTree.Sema.Builtins in '..\source\PasTree.Sema.Builtins.pas',
  PasTree.Sema.Types in '..\source\PasTree.Sema.Types.pas',
  PasTree.Sema.Resolver in '..\source\PasTree.Sema.Resolver.pas',
  PasTree.TestKit in 'PasTree.TestKit.pas';

var
  GSM: TPasSourceManager;
  GDefines: TPasDefines;
  GPP: TPasPreprocessor;
  GCounter: TPasSuiteCounter;
  GModel: TPasSemaModel;
  GTree: TPasTree;

procedure Analyze(const ASource: string);
var
  LPre: TPasPreprocessed;
  LDiags: TArray<TPasParseDiag>;
begin
  LPre := GPP.ProcessText('test.pas', ASource);
  GTree := TPasParser.ParseFile(LPre, LDiags);
  GModel := TPasSemaResolver.Analyze(GTree);
end;

function DiagCount(const ACode: string): Integer;
begin
  Result := 0;
  for var LIdx := 0 to High(GModel.Diags) do
    if GModel.Diags[LIdx].Code = ACode then
      Inc(Result);
end;

// ExprType name of the first binary-op node with the given operator lexeme.
function BinOpType(const AOp: string): string;
begin
  Result := '';
  for var LNode := 0 to High(GModel.ExprType) do
    if (GTree.Nodes[LNode].Kind = nkBinaryOp) and
       (GTree.Nodes[LNode].Aux >= 0) and
       SameText(GTree.Source.VisibleText(GTree.Nodes[LNode].Aux), AOp) then
    begin
      if GModel.ExprType[LNode] <> NIL_SYM then
        Result := GModel.Symbols[GModel.ExprType[LNode]].Name;
      Exit;
    end;
end;

// ExprType name of the first member-access whose member name = AName.
function MemberType(const AName: string): string;
begin
  Result := '';
  for var LNode := 0 to High(GModel.ExprType) do
    if GTree.Nodes[LNode].Kind = nkMember then
    begin
      var LName := GTree.Nodes[GTree.Nodes[LNode].FirstChild].NextSibling;
      if (LName <> NIL_NODE) and SameText(GTree.NodeText(LName), AName) then
      begin
        if GModel.ExprType[LNode] <> NIL_SYM then
          Result := GModel.Symbols[GModel.ExprType[LNode]].Name;
        Exit;
      end;
    end;
end;

procedure Ok(const AName: string; ACond: Boolean);
begin
  GCounter.Ok(AName, ACond);
end;

const
  SRC =
    'unit U;'#10'interface'#10 +
    'type TPt = record X: Integer; end;'#10 +
    'implementation'#10 +
    'procedure P;'#10 +
    'var S: string; I, J: Integer; B: Boolean; D: Double; R: TPt;'#10 +
    'begin'#10 +
    '  I := J + 1;'#10 +       // ok
    '  D := I;'#10 +           // ok int->float
    '  B := I < 3;'#10 +       // ok -> Boolean
    '  D := I / 2;'#10 +       // ok -> Extended
    '  I := J div 2;'#10 +     // ok
    '  I := R.X;'#10 +         // ok member Integer
    '  S := 5;'#10 +           // E2010
    '  I := ''x'';'#10 +       // E2010
    '  B := 3;'#10 +           // E2010
    '  I := S;'#10 +           // E2010
    '  D := -S;'#10 +          // E2015 (unary minus on string)
    'end;'#10'end.'#10;

begin
  GSM := TPasSourceManager.Create([]);
  GDefines := TPasDefines.Create(['MSWINDOWS', 'WIN32']);
  GPP := TPasPreprocessor.Create(GSM, GDefines);
  GCounter.Init;

  Analyze(SRC);

  Ok('2.6.1: 4 x E2010 (assignment-incompatible pairs)', DiagCount('E2010') = 4);
  Ok('1 x E2015', DiagCount('E2015') = 1);
  Ok('comparison typed Boolean', SameText(BinOpType('<'), 'Boolean'));
  Ok('division typed Extended', SameText(BinOpType('/'), 'Extended'));
  Ok('addition typed Integer', SameText(BinOpType('+'), 'Integer'));
  Ok('member R.X typed Integer', SameText(MemberType('X'), 'Integer'));
  GModel.Free;

  // ---- A subrange takes its category from its BOUNDS (code audit
  // 2026-08-31, finding 3.6). Every nkSubrange used to be tcInteger, which
  // made a Char subrange assignment a false E2010 and a Boolean subrange in
  // an `if` a false E2012 - in a typer whose whole design is to report only
  // definite mismatches. ----
  Analyze(
    'unit u;'#10'interface'#10 +
    'type'#10 +
    '  TLetter = ''a''..''z'';'#10 +
    '  TFlag = False..True;'#10 +
    '  TSmall = 0..9;'#10 +
    'implementation'#10 +
    'procedure P;'#10 +
    'var'#10'  L: TLetter;'#10'  C: Char;'#10 +
    '  F: TFlag;'#10'  S: TSmall;'#10'  I: Integer;'#10 +
    'begin'#10 +
    '  C := L;'#10 +
    '  L := C;'#10 +
    '  if F then'#10 +
    '    I := S;'#10 +
    'end;'#10 +
    'end.'#10);
  Ok('2.2.5: a Char subrange is not an Integer - no false E2010',
    DiagCount('E2010') = 0);
  Ok('2.2.5: a Boolean subrange is a legal condition - no false E2012',
    DiagCount('E2012') = 0);
  GModel.Free;

  if GCounter.Finish('SemaTypeSmoke') then
    ExitCode := 1;
  GPP.Free;
  GDefines.Free;
  GSM.Free;
end.
