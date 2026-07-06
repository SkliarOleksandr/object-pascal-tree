program SemaSmoke;

{ Phase-1 semantic smoke tests: symbol collection, intra-unit name/type
  resolution, overloads, external (uses) names, and E2004 redeclaration.
  Mirrors ParserSmoke's harness. }

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
  PasTree.Sema.Resolver in '..\source\PasTree.Sema.Resolver.pas',
  PasTree.Sema.Dump in '..\source\PasTree.Sema.Dump.pas';

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

function SymCountOf(const ANameLower: string; AKind: TSemaSymbolKind): Integer;
begin
  Result := 0;
  for var LIdx := 0 to GModel.SymCount - 1 do
    if (GModel.Symbols[LIdx].NameLower = ANameLower) and
       (GModel.Symbols[LIdx].Kind = AKind) then
      Inc(Result);
end;

function HasSym(const AName: string; AKind: TSemaSymbolKind): Boolean;
begin
  Result := SymCountOf(LowerCase(AName), AKind) > 0;
end;

// A resolved *reference* (not the declaration itself) whose target symbol has
// the given name.
function RefResolvesTo(const ARefText, ATargetName: string): Boolean;
var
  LNode, LSym: Integer;
begin
  Result := False;
  for LNode := 0 to High(GModel.RefMap) do
    if (GTree.Nodes[LNode].Kind = nkIdent) and
       SameText(GTree.NodeText(LNode), ARefText) then
    begin
      LSym := GModel.RefMap[LNode];
      if (LSym <> NIL_SYM) and (LNode <> GModel.Symbols[LSym].DeclNode) and
         SameText(GModel.Symbols[LSym].Name, ATargetName) then
        Exit(True);
    end;
end;

function DiagCount(const ACode: string): Integer;
begin
  Result := 0;
  for var LIdx := 0 to High(GModel.Diags) do
    if GModel.Diags[LIdx].Code = ACode then
      Inc(Result);
end;

// A declaration symbol's bound type name (or '' if unbound / missing).
function TypeOf(const ANameLower: string; AKind: TSemaSymbolKind): string;
begin
  Result := '';
  for var LIdx := 0 to GModel.SymCount - 1 do
    if (GModel.Symbols[LIdx].NameLower = ANameLower) and
       (GModel.Symbols[LIdx].Kind = AKind) then
    begin
      if GModel.Symbols[LIdx].TypeSym <> NIL_SYM then
        Result := GModel.Symbols[GModel.Symbols[LIdx].TypeSym].Name;
      Exit;
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
    Writeln(DumpSemaModel(GModel));
  end;
end;

const
  SRC_RECORD =
    'unit U;'#10'interface'#10 +
    'type TFoo = record X, Y: Integer; end;'#10 +
    'var G: TFoo;'#10'implementation'#10'end.'#10;

  SRC_ROUTINE =
    'unit U;'#10'interface'#10'implementation'#10 +
    'function Sum(const A, B: Integer): Integer;'#10 +
    'var I: Integer;'#10'begin Result := A + B; end;'#10'end.'#10;

  SRC_REDECL =
    'unit U;'#10'interface'#10 +
    'var X: Integer; X: Integer;'#10'implementation'#10'end.'#10;

  SRC_EXTERNAL =
    'unit U;'#10'interface'#10'uses System.SysUtils;'#10 +
    'var G: TStringList;'#10'implementation'#10'end.'#10;

  SRC_OVERLOAD =
    'unit U;'#10'interface'#10'implementation'#10 +
    'procedure P(A: Integer); begin end;'#10 +
    'procedure P(A: string); begin end;'#10'end.'#10;

begin
  GSM := TPasSourceManager.Create([]);
  GDefines := TPasDefines.Create(['MSWINDOWS', 'WIN32']);
  GPP := TPasPreprocessor.Create(GSM, GDefines);
  GPassed := 0;
  GFailed := 0;

  // 1. record + fields + var; type binding to a user type and a builtin
  Analyze(SRC_RECORD);
  Ok('record: TFoo type', HasSym('TFoo', skType));
  Ok('record: fields X,Y', (SymCountOf('x', skField) = 1) and
    (SymCountOf('y', skField) = 1));
  Ok('record: var G', HasSym('G', skVar));
  Ok('record: G : TFoo bound', TypeOf('g', skVar) = 'TFoo');
  Ok('record: field X : Integer bound', TypeOf('x', skField) = 'Integer');
  Ok('record: TFoo reference resolves', RefResolvesTo('TFoo', 'TFoo'));
  Ok('record: no diags', Length(GModel.Diags) = 0);
  GModel.Free;

  // 2. routine + params + local + body references
  Analyze(SRC_ROUTINE);
  Ok('routine: Sum', HasSym('Sum', skRoutine));
  Ok('routine: params A,B', HasSym('A', skParam) and HasSym('B', skParam));
  Ok('routine: local I', HasSym('I', skVar));
  Ok('routine: A referenced in body', RefResolvesTo('A', 'A'));
  Ok('routine: no diags', Length(GModel.Diags) = 0);
  GModel.Free;

  // 3. redeclaration -> E2004
  Analyze(SRC_REDECL);
  Ok('redecl: E2004 fired', DiagCount('E2004') = 1);
  GModel.Free;

  // 4. external (uses) names -> unresolved, NOT an error
  Analyze(SRC_EXTERNAL);
  Ok('external: SysUtils uses-ref', HasSym('SysUtils', skUnitRef));
  Ok('external: no E2003', DiagCount('E2003') = 0);
  Ok('external: no E2004', DiagCount('E2004') = 0);
  Ok('external: TStringList unbound', TypeOf('g', skVar) = '');
  GModel.Free;

  // 5. overloads -> two routines, no redeclaration error
  Analyze(SRC_OVERLOAD);
  Ok('overload: two P routines', SymCountOf('p', skRoutine) = 2);
  Ok('overload: no E2004', DiagCount('E2004') = 0);
  GModel.Free;

  Writeln(Format('=== SemaSmoke: %d passed, %d failed ===', [GPassed, GFailed]));
  if GFailed > 0 then
    ExitCode := 1;
  GPP.Free;
  GDefines.Free;
  GSM.Free;
end.
