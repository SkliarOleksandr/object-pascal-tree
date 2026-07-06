program SemaOverloadSmoke;

{ Phase-3b smoke tests: overload selection (call typing) + argument-count
  diagnostics (E2035/E2034), with default/varargs/builtin skips. }

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
  PasTree.Sema.Resolver in '..\source\PasTree.Sema.Resolver.pas';

var
  GSM: TPasSourceManager;
  GDefines: TPasDefines;
  GPP: TPasPreprocessor;
  GPassed, GFailed: Integer;
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

// Is there a call to ACallee whose result type is ATypeName?
function HasCallTyped(const ACallee, ATypeName: string): Boolean;
var
  LCallee, LTy: Integer;
begin
  Result := False;
  for var LNode := 0 to High(GModel.ExprType) do
    if GTree.Nodes[LNode].Kind = nkCall then
    begin
      LCallee := GTree.Nodes[LNode].FirstChild;
      if (LCallee <> NIL_NODE) and (GTree.Nodes[LCallee].Kind = nkIdent) and
         SameText(GTree.NodeText(LCallee), ACallee) then
      begin
        LTy := GModel.ExprType[LNode];
        if (LTy <> NIL_SYM) and SameText(GModel.Symbols[LTy].Name, ATypeName) then
          Exit(True);
      end;
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

const
  SRC =
    'unit U;'#10'interface'#10 +
    'function F(A: Integer): Integer; overload;'#10 +
    'function F(A: string): string; overload;'#10 +
    'procedure G(A, B: Integer);'#10 +
    'procedure H(A: Integer; B: Integer = 0);'#10 +
    'procedure V; varargs;'#10 +
    'implementation'#10 +
    'function F(A: Integer): Integer; overload; begin Result := A; end;'#10 +
    'function F(A: string): string; overload; begin Result := A; end;'#10 +
    'procedure G(A, B: Integer); begin end;'#10 +
    'procedure H(A: Integer; B: Integer = 0); begin end;'#10 +
    'procedure V; varargs; begin end;'#10 +
    'procedure Test;'#10'var I: Integer; S: string;'#10'begin'#10 +
    '  I := F(5);'#10 +         // -> F(Integer) : Integer
    '  S := F(''x'');'#10 +     // -> F(string) : string
    '  G(1);'#10 +             // E2035 (too few)
    '  G(1, 2, 3);'#10 +       // E2034 (too many)
    '  G(1, 2);'#10 +          // ok
    '  H(1);'#10 +             // ok (B has default)
    '  H(1, 2, 3);'#10 +       // E2034
    '  V(1, 2, 3);'#10 +       // ok (varargs)
    '  Writeln(1, 2, 3);'#10 + // ok (builtin)
    'end;'#10'end.'#10;

begin
  GSM := TPasSourceManager.Create([]);
  GDefines := TPasDefines.Create(['MSWINDOWS', 'WIN32']);
  GPP := TPasPreprocessor.Create(GSM, GDefines);
  GPassed := 0; GFailed := 0;

  Analyze(SRC);

  Ok('F(5) selects Integer overload', HasCallTyped('F', 'Integer'));
  Ok('F(''x'') selects string overload', HasCallTyped('F', 'string'));
  Ok('E2035 x1 (too few)', DiagCount('E2035') = 1);
  Ok('E2034 x2 (too many)', DiagCount('E2034') = 2);
  Ok('no bogus type errors', (DiagCount('E2010') = 0) and (DiagCount('E2015') = 0));
  GModel.Free;

  Writeln(Format('=== SemaOverloadSmoke: %d passed, %d failed ===',
    [GPassed, GFailed]));
  if GFailed > 0 then
    ExitCode := 1;
  GPP.Free;
  GDefines.Free;
  GSM.Free;
end.
