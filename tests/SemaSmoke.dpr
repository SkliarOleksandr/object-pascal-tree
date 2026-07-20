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

  // Sibling for-loops reusing one inline var name: each `for var` is scoped
  // to ITS loop (dcc behavior), so this is NOT a redeclaration.
  SRC_FORVAR =
    'unit U;'#10'interface'#10'implementation'#10 +
    'const ARR: array[0..1] of string = (''a'', ''b'');'#10 +
    'procedure P;'#10'begin'#10 +
    '  for var W in ARR do Writeln(W);'#10 +
    '  for var W in ARR do Writeln(W);'#10 +
    '  for var I := 0 to 1 do Writeln(I);'#10 +
    '  for var I := 0 to 1 do Writeln(I);'#10 +
    'end;'#10'end.'#10;

  // Two sibling anonymous functions: each owns its locals AND its implicit
  // Result (typed by ITS result type, not the enclosing function's).
  SRC_ANON =
    'unit U;'#10'interface'#10'implementation'#10 +
    'type TFn = reference to function: Boolean;'#10 +
    'function Outer: string;'#10 +
    'var F, G: TFn;'#10 +
    'begin'#10 +
    '  F := function: Boolean var L: Integer; begin L := 1; Result := L > 0; end;'#10 +
    '  G := function: Boolean var L: Integer; begin L := 2; Result := L > 0; end;'#10 +
    '  Result := '''';'#10 +
    'end;'#10'end.'#10;

  // A type declaration legally hides a used unit's leaf name (WinSock2's
  // `QOS = ...` vs `uses Winapi.Qos`).
  SRC_UNITHIDE =
    'unit U;'#10'interface'#10'uses Winapi.Qos;'#10 +
    'type Qos = record V: Integer; end;'#10 +
    'implementation'#10'end.'#10;

  // A call no local overload admits: arg-count fires, but the call must stay
  // UNTYPED (the real callee may be an unseen overload from another unit) —
  // no bogus E2010 from the local head's result type.
  SRC_NOFIT =
    'unit U;'#10'interface'#10'implementation'#10 +
    'function F(A: Integer): string; begin Result := ''''; end;'#10 +
    'procedure P;'#10'var I: Integer;'#10'begin'#10 +
    '  I := F(1, 2);'#10 +
    'end;'#10'end.'#10;

  // Interface-only symbol-id stability: the interface section declares types,
  // fields, a var and routines; the implementation adds bodies (and its own
  // locals). Because SeedSystemScope runs first (identical) and the interface
  // is collected before the implementation, every symbol id an interface-only
  // model assigns must equal the full model's symbol at the SAME id — the
  // guarantee that keeps other units' cross-references valid across the
  // intf->full snapshot swap (async parser plan §2.2).
  SRC_STAGED =
    'unit Staged;'#10 +
    'interface'#10 +
    'type'#10 +
    '  TFoo = class'#10 +
    '    FX: Integer;'#10 +
    '    function Bar(A: Integer): string;'#10 +
    '    procedure Baz;'#10 +
    '  end;'#10 +
    'var GCount: Integer;'#10 +
    'function Helper(N: Integer): Integer;'#10 +
    'implementation'#10 +
    'function TFoo.Bar(A: Integer): string;'#10 +
    'var LTmp: Integer;'#10 +
    'begin'#10 +
    '  LTmp := A;'#10 +
    '  Result := IntToStr(LTmp);'#10 +
    'end;'#10 +
    'procedure TFoo.Baz;'#10 +
    'begin'#10 +
    'end;'#10 +
    'function Helper(N: Integer): Integer;'#10 +
    'begin'#10 +
    '  Result := N + GCount;'#10 +
    'end;'#10 +
    'end.'#10;

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

  // 6. sibling `for var` loops reusing a name -> loop-scoped, no E2004
  Analyze(SRC_FORVAR);
  Ok('for-var: no E2004', DiagCount('E2004') = 0);
  Ok('for-var: W referenced in body', RefResolvesTo('W', 'W'));
  GModel.Free;

  // 7. anonymous methods own their locals and implicit Result
  Analyze(SRC_ANON);
  Ok('anon: no E2004 (locals scoped)', DiagCount('E2004') = 0);
  Ok('anon: no E2010 (own Result)', DiagCount('E2010') = 0);
  GModel.Free;

  // 8. type declaration hides a used unit's leaf name
  Analyze(SRC_UNITHIDE);
  Ok('unit-hide: no E2004', DiagCount('E2004') = 0);
  Ok('unit-hide: Qos is the type', HasSym('Qos', skType));
  GModel.Free;

  // 9. call fitting no local overload stays untyped (no bogus E2010)
  Analyze(SRC_NOFIT);
  Ok('no-fit: E2034 fired', DiagCount('E2034') = 1);
  Ok('no-fit: no E2010', DiagCount('E2010') = 0);
  GModel.Free;

  // 10. interface-only symbol ids are a prefix of the full model's ids
  begin
    var LPre := GPP.ProcessText('test.pas', SRC_STAGED);
    var LD: TArray<TPasParseDiag>;
    var LIntfTree := TPasParser.ParseFile(LPre, LD, {AInterfaceOnly} True);
    var LIntfModel := TPasSemaResolver.Analyze(LIntfTree);
    LPre := GPP.ProcessText('test.pas', SRC_STAGED);
    var LFullTree := TPasParser.ParseFile(LPre, LD, {AInterfaceOnly} False);
    var LFullModel := TPasSemaResolver.Analyze(LFullTree);
    try
      Ok('staged: intf model has fewer symbols than full',
        LIntfModel.SymCount < LFullModel.SymCount);
      // The interface declared these — all must exist in the intf-only model.
      var LHaveIntfSyms := True;
      var LNames: TArray<string> := ['TFoo', 'FX', 'Bar', 'Baz', 'GCount',
        'Helper'];
      for var LN in LNames do
      begin
        var LFound := False;
        for var LI := 0 to LIntfModel.SymCount - 1 do
          if SameText(LIntfModel.Symbols[LI].Name, LN) then
          begin
            LFound := True;
            Break;
          end;
        if not LFound then
          LHaveIntfSyms := False;
      end;
      Ok('staged: all interface symbols present in intf-only model',
        LHaveIntfSyms);
      // The id-stability invariant: every symbol the intf-only model holds
      // matches the full model's symbol at the SAME id (name + kind + scope).
      var LStable := True;
      for var LI := 0 to LIntfModel.SymCount - 1 do
        if not ((LIntfModel.Symbols[LI].Name = LFullModel.Symbols[LI].Name) and
          (LIntfModel.Symbols[LI].Kind = LFullModel.Symbols[LI].Kind) and
          (LIntfModel.Symbols[LI].Scope = LFullModel.Symbols[LI].Scope)) then
        begin
          LStable := False;
          Writeln(Format('  staged: sym %d differs: intf=%s/%d full=%s/%d',
            [LI, LIntfModel.Symbols[LI].Name,
             Ord(LIntfModel.Symbols[LI].Kind),
             LFullModel.Symbols[LI].Name, Ord(LFullModel.Symbols[LI].Kind)]));
        end;
      Ok('staged: interface symbol ids are a stable prefix of the full model',
        LStable);
    finally
      LIntfModel.Free;
      LFullModel.Free;
    end;
  end;

  Writeln(Format('=== SemaSmoke: %d passed, %d failed ===', [GPassed, GFailed]));
  if GFailed > 0 then
    ExitCode := 1;
  GPP.Free;
  GDefines.Free;
  GSM.Free;
end.
