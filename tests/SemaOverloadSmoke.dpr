program SemaOverloadSmoke;

{ Phase-3b smoke tests: overload selection (call typing) + argument-count
  diagnostics (E2035/E2034), with default/varargs/builtin skips. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Dcu in '..\source\PasTree.Dcu.pas',
  PasTree.Dcu.Source in '..\source\PasTree.Dcu.Source.pas',
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
  GModel.AddParseDiags(LDiags);   // as TPasSemaProject does after every parse
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
  GCounter.Ok(AName, ACond);
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

  { Inside a METHOD the candidate set is never complete intra-unit: dcc
    searches the type's own AND inherited members before the unit's globals,
    and every class also inherits TObject, which a `uses`-less unit has no
    model of. Both calls below are legal dcc (verified as a real compile) -
    they mean TBase.Foo/TBase.Bar, not the globals the intra-unit resolver
    binds them to, and the arity check must stay silent about them. }
  SRC_METHOD =
    'unit U;'#10'interface'#10 +
    'type'#10 +
    '  TBase = class'#10 +
    '    procedure Foo(A: Integer);'#10 +
    '    function Bar(A: Integer): Integer;'#10 +
    '  end;'#10 +
    '  TDer = class(TBase)'#10 +
    '    procedure Run;'#10 +
    '  end;'#10 +
    'procedure Foo(A, B: Integer);'#10 +   // global, needs 2
    'function Bar: Integer;'#10 +          // global, takes none
    'implementation'#10 +
    'procedure Foo(A, B: Integer); begin end;'#10 +
    'function Bar: Integer; begin Result := 0; end;'#10 +
    'procedure TBase.Foo(A: Integer); begin end;'#10 +
    'function TBase.Bar(A: Integer): Integer; begin Result := A; end;'#10 +
    'procedure TDer.Run;'#10'var I: Integer;'#10'begin'#10 +
    '  Foo(1);'#10 +           // the inherited TBase.Foo(A) - not 2 args short
    '  I := Bar(1);'#10 +      // the inherited TBase.Bar(A) - not 1 arg over
    'end;'#10'end.'#10;

  { A TRAILING COMMA at the call site (6.2.5, dcc-probed 36.0/37.0): the
    parser accepts it and leaves an nkMissing; the arity check gives dcc's
    verdict. `H(1, 2,)` compiles (every parameter supplied, the last has a
    default); `G(True, 1,)` is E2029 (a parameter still due); `P(1, 2,)` is
    E2034 (no default on the last parameter); `Q(1, 2, 3,)` is E2034 (too
    many). The client ships two of the legal shape - they were false E2029. }
  SRC_TRAILING =
    'unit U;'#10'interface'#10 +
    'procedure H(A: Integer; B: Integer = 0);'#10 +
    'procedure G(A: Boolean; B: Integer = 0; C: Integer = 0);'#10 +
    'procedure P(A, B: Integer);'#10 +
    'procedure Q(A, B: Integer);'#10 +
    'implementation'#10 +
    'procedure H(A: Integer; B: Integer = 0); begin end;'#10 +
    'procedure G(A: Boolean; B: Integer = 0; C: Integer = 0); begin end;'#10 +
    'procedure P(A, B: Integer); begin end;'#10 +
    'procedure Q(A, B: Integer); begin end;'#10 +
    'procedure Plain;'#10'begin'#10 +
    '  H(1, 2,);'#10 +        // legal
    '  G(True, 1,);'#10 +     // E2029
    '  P(1, 2,);'#10 +        // E2034
    '  Q(1, 2, 3,);'#10 +     // E2034
    'end;'#10'end.'#10;

  { The same unit and the same globals, called from OUTSIDE any struct: here
    the globals really are the only candidates, so both diagnostics must
    still fire - dcc reports exactly these two. }
  SRC_PLAIN =
    'unit U;'#10'interface'#10 +
    'procedure Foo(A, B: Integer);'#10 +
    'function Bar: Integer;'#10 +
    'implementation'#10 +
    'procedure Foo(A, B: Integer); begin end;'#10 +
    'function Bar: Integer; begin Result := 0; end;'#10 +
    'procedure Plain;'#10'var I: Integer;'#10'begin'#10 +
    '  Foo(1);'#10 +           // E2035
    '  I := Bar(1);'#10 +      // E2034
    '  Foo(1, &4M4);'#10 +     // parse error only: `)` never came, no arity check
    '  Foo(1 +, 2);'#10 +      // same
    'end;'#10'end.'#10;

  { One type under two seeded names is an EXACT match (6.3.1, dcc64 37.0,
    local/probe-b31 O1/O2): the AnsiChar / AnsiString / Int64 / PAnsiChar
    overload declared FIRST took the tie before, and the call typed TRA. A
    one-character literal fits Char best, a string next, AnsiChar least. }
  SRC_IDENT =
    'unit U;'#10'interface'#10'type'#10 +
    '  TRA = record A: Integer; end;'#10 +
    '  TRW = record W: Integer; end;'#10 +
    'function F(C: AnsiChar): TRA; overload;'#10 +
    'function F(C: WideChar): TRW; overload;'#10 +
    'function G(const S: AnsiString): TRA; overload;'#10 +
    'function G(const S: UnicodeString): TRW; overload;'#10 +
    'function H(A: Int64): TRA; overload;'#10 +
    'function H(A: LongInt): TRW; overload;'#10 +
    'function P(A: PAnsiChar): TRA; overload;'#10 +
    'function P(A: PWideChar): TRW; overload;'#10 +
    'function K(C: AnsiChar): TRA; overload;'#10 +
    'function K(const S: string): TRW; overload;'#10 +
    'function R(C: WideChar): TRW; overload;'#10 +
    'function R(C: AnsiChar): TRA; overload;'#10 +
    'implementation'#10 +
    'function F(C: AnsiChar): TRA; begin end;'#10 +
    'function F(C: WideChar): TRW; begin end;'#10 +
    'function G(const S: AnsiString): TRA; begin end;'#10 +
    'function G(const S: UnicodeString): TRW; begin end;'#10 +
    'function H(A: Int64): TRA; begin end;'#10 +
    'function H(A: LongInt): TRW; begin end;'#10 +
    'function P(A: PAnsiChar): TRA; begin end;'#10 +
    'function P(A: PWideChar): TRW; begin end;'#10 +
    'function K(C: AnsiChar): TRA; begin end;'#10 +
    'function K(const S: string): TRW; begin end;'#10 +
    'function R(C: WideChar): TRW; begin end;'#10 +
    'function R(C: AnsiChar): TRA; begin end;'#10 +
    'procedure Test;'#10 +
    'var C: Char; S: string; I: Integer; PC: PChar; X: Integer;'#10 +
    'begin'#10 +
    '  X := F(C).W;'#10 +
    '  X := F(''a'').W;'#10 +
    '  X := G(S).W;'#10 +
    '  X := H(I).W;'#10 +
    '  X := P(PC).W;'#10 +
    '  X := K(''a'').W;'#10 +
    '  X := R(''a'').W;'#10 +
    'end;'#10'end.'#10;

  { The unit scorer applies the project scorer's rules (audit B32, 6.3.1,
    dcc64 37.0, local/probe-b32 P1): `#13#10` / `'a'#0` are strings, `('x')`
    and an inline `if` of two literals are Chars, a weak alias is its target's
    own type, an anonymous method / a procedure designator rejects a Boolean,
    two distinct records reject each other. Each TRW overload is dcc's pick;
    on 0.98.3 every call typed TRA. Pick(11) fits no candidate (a class
    parameter) and must not take the head's result. }
  SRC_SCORE =
    'unit U;'#10'interface'#10'type'#10 +
    '  TRA = record A: Integer; end;'#10 +
    '  TRW = record W: Integer; end;'#10 +
    '  TId = Integer;'#10 +
    '  TRc = record A: Integer; end;'#10 +
    '  TPt = record X: Integer; end;'#10 +
    '  TMyRc = TRc;'#10 +
    '  TMyInt = Int64;'#10 +
    '  TMyProc = reference to procedure;'#10 +
    '  TFoo = class end;'#10 +
    'function P(C: Char): TRA; overload;'#10 +
    'function P(const S: string): TRW; overload;'#10 +
    'function Q(const S: string): TRA; overload;'#10 +
    'function Q(C: Char): TRW; overload;'#10 +
    'function F(A: Int64): TRA; overload;'#10 +
    'function F(A: TId): TRW; overload;'#10 +
    'function R(const A: TPt): TRA; overload;'#10 +
    'function R(const A: TRc): TRW; overload;'#10 +
    'function G(A: Integer): TRA; overload;'#10 +
    'function G(A: Int64): TRW; overload;'#10 +
    'function M(A: Integer; B: Boolean = False): TRA; overload;'#10 +
    'function M(A: Integer; P: TMyProc): TRW; overload;'#10 +
    'function Pick(O: TFoo): TRA;'#10 +
    'procedure Noop;'#10 +
    'implementation'#10 +
    'function P(C: Char): TRA; begin end;'#10 +
    'function P(const S: string): TRW; begin end;'#10 +
    'function Q(const S: string): TRA; begin end;'#10 +
    'function Q(C: Char): TRW; begin end;'#10 +
    'function F(A: Int64): TRA; begin end;'#10 +
    'function F(A: TId): TRW; begin end;'#10 +
    'function R(const A: TPt): TRA; begin end;'#10 +
    'function R(const A: TRc): TRW; begin end;'#10 +
    'function G(A: Integer): TRA; begin end;'#10 +
    'function G(A: Int64): TRW; begin end;'#10 +
    'function M(A: Integer; B: Boolean = False): TRA; begin end;'#10 +
    'function M(A: Integer; P: TMyProc): TRW; begin end;'#10 +
    'function Pick(O: TFoo): TRA; begin end;'#10 +
    'procedure Noop; begin end;'#10 +
    'procedure Test;'#10 +
    'var X: TRW; I: Integer; RR: TMyRc; MI: TMyInt; B: Boolean;'#10 +
    'begin'#10 +
    '  X := P(#13#10);'#10 +
    '  X := P(''a''#0);'#10 +
    '  X := Q((''x''));'#10 +
    '  X := Q(if B then ''a'' else ''b'');'#10 +
    '  X := F(I);'#10 +
    '  X := R(RR);'#10 +
    '  X := G(MI);'#10 +
    '  X := M(1, procedure begin end);'#10 +
    '  X := M(1, Noop);'#10 +
    '  I := Pick(11).A;'#10 +
    'end;'#10'end.'#10;

  { The Char-literal and nil exemptions of the assignment check (A4-10,
    A4-11; probe-b32 P1): dcc compiles every line but the last, where an
    operator-less record takes nil - E2010 naming `Pointer`, not `_nil`. }
  SRC_ASSIGN =
    'unit U;'#10'interface'#10'type'#10 +
    '  TPtrRec = record P: Pointer;'#10 +
    '    class operator Implicit(Value: Pointer): TPtrRec; end;'#10 +
    '  TPlain = record P: Pointer; end;'#10 +
    'implementation'#10 +
    'class operator TPtrRec.Implicit(Value: Pointer): TPtrRec; begin end;'#10 +
    'procedure Test;'#10 +
    'var Ch: Char; B: Boolean; Q: TPtrRec; N: TPlain;'#10 +
    'begin'#10 +
    '  Ch := (''x'');'#10 +
    '  Ch := ((#65));'#10 +
    '  Ch := if B then ''a'' else ''b'';'#10 +
    '  Ch := if B then ''a'' else Ch;'#10 +
    '  Q := nil;'#10 +
    '  N := nil;'#10 +
    'end;'#10'end.'#10;

begin
  GSM := TPasSourceManager.Create([]);
  GDefines := TPasDefines.Create(['MSWINDOWS', 'WIN32']);
  GPP := TPasPreprocessor.Create(GSM, GDefines);
  GCounter.Init;

  Analyze(SRC);

  Ok('F(5) selects Integer overload', HasCallTyped('F', 'Integer'));
  Ok('F(''x'') selects string overload', HasCallTyped('F', 'string'));
  Ok('E2035 x1 (too few)', DiagCount('E2035') = 1);
  Ok('E2034 x2 (too many)', DiagCount('E2034') = 2);
  Ok('no bogus type errors', (DiagCount('E2010') = 0) and (DiagCount('E2015') = 0));
  Ok('clean source: no E2029', DiagCount('E2029') = 0);
  GModel.Free;

  // A call inside a method may really be an inherited member, so the arity
  // check stands down there (the global it resolved to is not the callee).
  Analyze(SRC_METHOD);
  Ok('no false arity inside a method: inherited Foo(A) beats the 2-arg global',
    DiagCount('E2035') = 0);
  Ok('no false arity inside a method: inherited Bar(A) beats the 0-arg global',
    DiagCount('E2034') = 0);
  GModel.Free;

  // ...and the same globals still get checked where they ARE the callee.
  Analyze(SRC_PLAIN);
  Ok('outside a struct the check still fires: E2035 x1',
    DiagCount('E2035') = 1);
  Ok('a truncated argument list is a parse error, not E2035 (&4M4)',
    DiagCount('E2035') = 1);
  Ok('...and the parse error IS reported: E2029 at each cut list',
    DiagCount('E2029') >= 2);
  Ok('outside a struct the check still fires: E2034 x1',
    DiagCount('E2034') = 1);
  GModel.Free;

  Analyze(SRC_TRAILING);
  Ok('trailing comma: H(1, 2,) with a defaulted last parameter is legal, ' +
    'G(True, 1,) with one still due is E2029 - exactly one E2029',
    DiagCount('E2029') = 1);
  Ok('trailing comma: P(1, 2,) without a default and Q(1, 2, 3,) are E2034 x2',
    DiagCount('E2034') = 2);
  Ok('trailing comma: no E2035 anywhere', DiagCount('E2035') = 0);
  GModel.Free;

  Analyze(SRC_IDENT);
  for var LName in ['F', 'G', 'H', 'P', 'K', 'R'] do
    Ok('builtin identity: ' + LName + ' binds the TRW overload',
      HasCallTyped(LName, 'TRW') and not HasCallTyped(LName, 'TRA'));
  Ok('builtin identity: no E2003', DiagCount('E2003') = 0);
  GModel.Free;

  Analyze(SRC_SCORE);
  for var LName in ['P', 'Q', 'F', 'R', 'G', 'M'] do
    Ok('one scorer: ' + LName + ' binds the TRW overload',
      HasCallTyped(LName, 'TRW') and not HasCallTyped(LName, 'TRA'));
  Ok('one scorer: Pick(11) rejected by its only candidate is untyped',
    not HasCallTyped('Pick', 'TRA'));
  Ok('one scorer: no E2010', DiagCount('E2010') = 0);
  GModel.Free;

  Analyze(SRC_ASSIGN);
  Ok('char literal in parentheses / inline if, nil to an Implicit record:' +
    ' only the operator-less record is E2010', DiagCount('E2010') = 1);
  for var LDiag in GModel.Diags do
    if LDiag.Code = 'E2010' then
      Ok('nil is named Pointer in E2010 [' + LDiag.Msg + ']',
        LDiag.Msg.Contains('''Pointer''') and
        not LDiag.Msg.Contains('_nil'));
  GModel.Free;

  if GCounter.Finish('SemaOverloadSmoke') then
    ExitCode := 1;
  GPP.Free;
  GDefines.Free;
  GSM.Free;
end.
