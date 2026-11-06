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

  { An open-array parameter names no type, so every argument scored nothing
    against it and the first declared won (6.2.6, 6.3.1; dcc64 37.0,
    local/compl-c1c2-2026-11/fc): an array of the element type fits, of
    another element is out, a string variable is no `array of const`
    argument; a parameter of the argument's own type beats the open array
    (Z, a control). Each TRW overload is dcc's pick; J, O and Y typed TRA on
    0.146.8. }
  SRC_OPEN =
    'unit U;'#10'interface'#10'type'#10 +
    '  TRA = record A: Integer; end;'#10 +
    '  TRW = record W: Integer; end;'#10 +
    '  TStrs = array of string;'#10 +
    '  TInts = array of Integer;'#10 +
    'function J(const A: array of const): TRA; overload;'#10 +
    'function J(const A: array of string): TRW; overload;'#10 +
    'function L(const A: array of string): TRW; overload;'#10 +
    'function L(const A: array of const): TRA; overload;'#10 +
    'function O(const A: array of const): TRA; overload;'#10 +
    'function O(const A: array of string): TRW; overload;'#10 +
    'function Y(const A: array of Int64): TRA; overload;'#10 +
    'function Y(const A: array of Integer): TRW; overload;'#10 +
    'function Z(const A: array of Integer): TRA; overload;'#10 +
    'function Z(const A: TInts): TRW; overload;'#10 +
    'implementation'#10 +
    'function J(const A: array of const): TRA; begin end;'#10 +
    'function J(const A: array of string): TRW; begin end;'#10 +
    'function L(const A: array of string): TRW; begin end;'#10 +
    'function L(const A: array of const): TRA; begin end;'#10 +
    'function O(const A: array of const): TRA; begin end;'#10 +
    'function O(const A: array of string): TRW; begin end;'#10 +
    'function Y(const A: array of Int64): TRA; begin end;'#10 +
    'function Y(const A: array of Integer): TRW; begin end;'#10 +
    'function Z(const A: array of Integer): TRA; begin end;'#10 +
    'function Z(const A: TInts): TRW; begin end;'#10 +
    'procedure Test(SS: TStrs; S: string; II: TInts);'#10 +
    'var X: TRW;'#10 +
    'begin'#10 +
    '  X := J(SS);'#10 +
    '  X := L(SS);'#10 +
    '  X := O(S);'#10 +
    '  X := Y(II);'#10 +
    '  X := Z(II);'#10 +
    'end;'#10'end.'#10;

  { A `[...]` against open-array overloads is ranked by its WORST element,
    and an array whose type is written inline is an array of its element
    (6.3.1, 6.2.6; dcc64 37.0, local/compl-c1c2-2026-11/fd). Each TRW
    overload is dcc's pick: J an exact bracket or inline array over `array
    of const`; L `array of const` over `array of string` for one element
    converted; Q `array of string` over `array of Char` for a string among
    the elements, K the reverse for Char values; D an exact bracket and an
    inline `array of string` over a named dynamic array; V `array of const`
    over `array of Variant`; N `array of Integer` over `array of Byte`; E and
    F an open-array parameter passed on. Declared second there - every one
    took the first on 0.146.10 - and first in the *M twins, which must not
    lose it. }
  SRC_OPEN2 =
    'unit U;'#10'interface'#10'type'#10 +
    '  TRA = record A: Integer; end;'#10 +
    '  TRW = record W: Integer; end;'#10 +
    '  TStrs = array of string;'#10 +
    '  TCA = class end;'#10 +
    '  TCAClass = class of TCA;'#10 +
    'function J(const A: array of const): TRA; overload;'#10 +
    'function J(const A: array of string): TRW; overload;'#10 +
    'function L(const A: array of string): TRA; overload;'#10 +
    'function L(const A: array of const): TRW; overload;'#10 +
    'function Q(const A: array of Char): TRA; overload;'#10 +
    'function Q(const A: array of string): TRW; overload;'#10 +
    'function K(const A: array of string): TRA; overload;'#10 +
    'function K(const A: array of Char): TRW; overload;'#10 +
    'function D(const A: TStrs): TRA; overload;'#10 +
    'function D(const A: array of string): TRW; overload;'#10 +
    'function V(const A: array of Variant): TRA; overload;'#10 +
    'function V(const A: array of const): TRW; overload;'#10 +
    'function N(const A: array of Byte): TRA; overload;'#10 +
    'function N(const A: array of Integer): TRW; overload;'#10 +
    'function E(const A: array of const): TRA; overload;'#10 +
    'function E(const A: array of string): TRW; overload;'#10 +
    'function F(const A: array of string): TRA; overload;'#10 +
    'function F(const A: array of const): TRW; overload;'#10 +
    'function JM(const A: array of string): TRW; overload;'#10 +
    'function JM(const A: array of const): TRA; overload;'#10 +
    'function LM(const A: array of const): TRW; overload;'#10 +
    'function LM(const A: array of string): TRA; overload;'#10 +
    'function QM(const A: array of string): TRW; overload;'#10 +
    'function QM(const A: array of Char): TRA; overload;'#10 +
    'function KM(const A: array of Char): TRW; overload;'#10 +
    'function KM(const A: array of string): TRA; overload;'#10 +
    'function DM(const A: array of string): TRW; overload;'#10 +
    'function DM(const A: TStrs): TRA; overload;'#10 +
    'function VM(const A: array of const): TRW; overload;'#10 +
    'function VM(const A: array of Variant): TRA; overload;'#10 +
    'function NM(const A: array of Integer): TRW; overload;'#10 +
    'function NM(const A: array of Byte): TRA; overload;'#10 +
    'function CR(const A: array of string): TRA; overload;'#10 +
    'function CR(const A: array of TCAClass): TRW; overload;'#10 +
    'function CRM(const A: array of TCAClass): TRW; overload;'#10 +
    'function CRM(const A: array of string): TRA; overload;'#10 +
    'implementation'#10 +
    'function J(const A: array of const): TRA; begin end;'#10 +
    'function J(const A: array of string): TRW; begin end;'#10 +
    'function L(const A: array of string): TRA; begin end;'#10 +
    'function L(const A: array of const): TRW; begin end;'#10 +
    'function Q(const A: array of Char): TRA; begin end;'#10 +
    'function Q(const A: array of string): TRW; begin end;'#10 +
    'function K(const A: array of string): TRA; begin end;'#10 +
    'function K(const A: array of Char): TRW; begin end;'#10 +
    'function D(const A: TStrs): TRA; begin end;'#10 +
    'function D(const A: array of string): TRW; begin end;'#10 +
    'function V(const A: array of Variant): TRA; begin end;'#10 +
    'function V(const A: array of const): TRW; begin end;'#10 +
    'function N(const A: array of Byte): TRA; begin end;'#10 +
    'function N(const A: array of Integer): TRW; begin end;'#10 +
    'function E(const A: array of const): TRA; begin end;'#10 +
    'function E(const A: array of string): TRW; begin end;'#10 +
    'function F(const A: array of string): TRA; begin end;'#10 +
    'function F(const A: array of const): TRW; begin end;'#10 +
    'function JM(const A: array of string): TRW; begin end;'#10 +
    'function JM(const A: array of const): TRA; begin end;'#10 +
    'function LM(const A: array of const): TRW; begin end;'#10 +
    'function LM(const A: array of string): TRA; begin end;'#10 +
    'function QM(const A: array of string): TRW; begin end;'#10 +
    'function QM(const A: array of Char): TRA; begin end;'#10 +
    'function KM(const A: array of Char): TRW; begin end;'#10 +
    'function KM(const A: array of string): TRA; begin end;'#10 +
    'function DM(const A: array of string): TRW; begin end;'#10 +
    'function DM(const A: TStrs): TRA; begin end;'#10 +
    'function VM(const A: array of const): TRW; begin end;'#10 +
    'function VM(const A: array of Variant): TRA; begin end;'#10 +
    'function NM(const A: array of Integer): TRW; begin end;'#10 +
    'function NM(const A: array of Byte): TRA; begin end;'#10 +
    'function CR(const A: array of string): TRA; begin end;'#10 +
    'function CR(const A: array of TCAClass): TRW; begin end;'#10 +
    'function CRM(const A: array of TCAClass): TRW; begin end;'#10 +
    'function CRM(const A: array of string): TRA; begin end;'#10 +
    'procedure PassOn(const A: array of string; const KK: array of const);'#10 +
    'var X: TRW;'#10 +
    'begin'#10 +
    '  X := E(A);'#10 +
    '  X := F(KK);'#10 +
    'end;'#10 +
    'procedure Test(S: string; I: Integer; C: Char; AS_: AnsiString);'#10 +
    'var'#10 +
    '  X: TRW;'#10 +
    '  LA: array of string;'#10 +
    '  SA: array[0..1] of string;'#10 +
    'begin'#10 +
    '  X := J([''a'', ''b'']);'#10 +
    '  X := J([S, ''x'']);'#10 +
    '  X := J([C]);'#10 +
    '  X := J(LA);'#10 +
    '  X := J(SA);'#10 +
    '  X := L([1, ''b'']);'#10 +
    '  X := L([S, I]);'#10 +
    '  X := L([S, AS_]);'#10 +
    '  X := Q(['', '']);'#10 +
    '  X := Q(['','', ''ab'']);'#10 +
    '  X := Q([S]);'#10 +
    '  X := K(['','']);'#10 +
    '  X := K([C, '';'']);'#10 +
    '  X := K([#9]);'#10 +
    '  X := D([''a'', ''b'']);'#10 +
    '  X := D(LA);'#10 +
    '  X := V([1, ''b'']);'#10 +
    '  X := N([I, I]);'#10 +
    '  X := JM([''a'', ''b'']);'#10 +
    '  X := JM([C]);'#10 +
    '  X := JM(LA);'#10 +
    '  X := LM([1, ''b'']);'#10 +
    '  X := LM([S, I]);'#10 +
    '  X := LM([S, AS_]);'#10 +
    '  X := QM(['', '']);'#10 +
    '  X := QM(['','', ''ab'']);'#10 +
    '  X := KM(['','']);'#10 +
    '  X := KM([C, '';'']);'#10 +
    '  X := DM([''a'', ''b'']);'#10 +
    '  X := DM(LA);'#10 +
    '  X := VM([1, ''b'']);'#10 +
    '  X := NM([I, I]);'#10 +
    '  X := CR([TCA]);'#10 +
    '  X := CRM([TCA]);'#10 +
    'end;'#10'end.'#10;

  { 6.3.1, a `[...]` against a DYNAMIC-array parameter this unit declares:
    each element a step below the open array's match - an exact element
    above `array of const`, an exact constant (not a string or a character)
    below it. Every call binds the TRW overload (dcc64 37.0,
    local/compl-c1c2-2026-11/fe); G, GM, HV, P and R red on 0.146.11, where
    a `[...]` scored nothing against a dynamic array. }
  SRC_OPEN3 =
    'unit U;'#10'interface'#10'type'#10 +
    '  TRA = record A: Integer; end;'#10 +
    '  TRW = record W: Integer; end;'#10 +
    '  TInts = array of Integer;'#10 +
    '  TStrs = array of string;'#10 +
    '  TChars = array of Char;'#10 +
    'const'#10 +
    '  NC = 5;'#10 +
    'function G(const A: array of const): TRA; overload;'#10 +
    'function G(const A: TStrs): TRW; overload;'#10 +
    'function GM(const A: TStrs): TRW; overload;'#10 +
    'function GM(const A: array of const): TRA; overload;'#10 +
    'function H(const A: array of const): TRW; overload;'#10 +
    'function H(const A: TInts): TRA; overload;'#10 +
    'function HM(const A: TInts): TRA; overload;'#10 +
    'function HM(const A: array of const): TRW; overload;'#10 +
    'function HV(const A: array of const): TRA; overload;'#10 +
    'function HV(const A: TInts): TRW; overload;'#10 +
    'function P(const A: array of Int64): TRA; overload;'#10 +
    'function P(const A: TInts): TRW; overload;'#10 +
    'function R(const A: array of string): TRA; overload;'#10 +
    'function R(const A: TChars): TRW; overload;'#10 +
    'implementation'#10 +
    'function G(const A: array of const): TRA; begin end;'#10 +
    'function G(const A: TStrs): TRW; begin end;'#10 +
    'function GM(const A: TStrs): TRW; begin end;'#10 +
    'function GM(const A: array of const): TRA; begin end;'#10 +
    'function H(const A: array of const): TRW; begin end;'#10 +
    'function H(const A: TInts): TRA; begin end;'#10 +
    'function HM(const A: TInts): TRA; begin end;'#10 +
    'function HM(const A: array of const): TRW; begin end;'#10 +
    'function HV(const A: array of const): TRA; begin end;'#10 +
    'function HV(const A: TInts): TRW; begin end;'#10 +
    'function P(const A: array of Int64): TRA; begin end;'#10 +
    'function P(const A: TInts): TRW; begin end;'#10 +
    'function R(const A: array of string): TRA; begin end;'#10 +
    'function R(const A: TChars): TRW; begin end;'#10 +
    'procedure Test(S: string; I: Integer; C: Char);'#10 +
    'var'#10 +
    '  X: TRW;'#10 +
    'begin'#10 +
    '  X := G([''a'', S]);'#10 +
    '  X := GM([C]);'#10 +
    '  X := H([1, 2]);'#10 +
    '  X := H([NC]);'#10 +
    '  X := H([NC + 1]);'#10 +
    '  X := HM([1]);'#10 +
    '  X := HV([I]);'#10 +
    '  X := P([I]);'#10 +
    '  X := R([C]);'#10 +
    '  X := R([''a'']);'#10 +
    'end;'#10'end.'#10;

  { 6.3.1, a `[...]` in parentheses is a set constructor (8.2.2), which no
    array takes: beside a set overload the set one is taken whichever is
    declared first - an open array (SR, SRM), `array of const` (SJ) and a
    dynamic array (SD); without the parentheses the open array is taken
    again (RC). dcc64 37.0 (review 2026-11-03): `R(([1, 2]))` takes the set
    overload, `R([1, 2])` the open array; both scored the brackets as an
    array constructor before. }
  SRC_OPEN4 =
    'unit U;'#10'interface'#10'type'#10 +
    '  TRA = record A: Integer; end;'#10 +
    '  TRW = record W: Integer; end;'#10 +
    '  TInts = array of Integer;'#10 +
    '  TBS = set of Byte;'#10 +
    '  TCo = class end;'#10 +
    '  TCoClass = class of TCo;'#10 +
    'function SR(const A: array of Integer): TRA; overload;'#10 +
    'function SR(const S: TBS): TRW; overload;'#10 +
    'function SRM(const S: TBS): TRW; overload;'#10 +
    'function SRM(const A: array of Integer): TRA; overload;'#10 +
    'function SJ(const A: array of const): TRA; overload;'#10 +
    'function SJ(const S: TBS): TRW; overload;'#10 +
    'function SD(const A: TInts): TRA; overload;'#10 +
    'function SD(const S: TBS): TRW; overload;'#10 +
    'function RC(const A: array of Integer): TRW; overload;'#10 +
    'function RC(const S: TBS): TRA; overload;'#10 +
    'function CF(const A: array of TObject): TRA; overload;'#10 +
    'function CF(const A: array of TCoClass): TRW; overload;'#10 +
    'function VQ(var A: array of Integer): TRW; overload;'#10 +
    'function VQ(const A: array of const): TRA; overload;'#10 +
    'function VR(const A: array of const): TRA; overload;'#10 +
    'function VR(out A: array of Integer): TRW; overload;'#10 +
    'implementation'#10 +
    'function SR(const A: array of Integer): TRA; begin end;'#10 +
    'function SR(const S: TBS): TRW; begin end;'#10 +
    'function SRM(const S: TBS): TRW; begin end;'#10 +
    'function SRM(const A: array of Integer): TRA; begin end;'#10 +
    'function SJ(const A: array of const): TRA; begin end;'#10 +
    'function SJ(const S: TBS): TRW; begin end;'#10 +
    'function SD(const A: TInts): TRA; begin end;'#10 +
    'function SD(const S: TBS): TRW; begin end;'#10 +
    'function RC(const A: array of Integer): TRW; begin end;'#10 +
    'function RC(const S: TBS): TRA; begin end;'#10 +
    'function CF(const A: array of TObject): TRA; begin end;'#10 +
    'function CF(const A: array of TCoClass): TRW; begin end;'#10 +
    'function VQ(var A: array of Integer): TRW; begin end;'#10 +
    'function VQ(const A: array of const): TRA; begin end;'#10 +
    'function VR(const A: array of const): TRA; begin end;'#10 +
    'function VR(out A: array of Integer): TRW; begin end;'#10 +
    'procedure Test;'#10 +
    'var'#10 +
    '  X: TRW; I: Integer;'#10 +
    'begin'#10 +
    '  X := CF([TCo]);'#10 +
    '  X := CF([(TCo)]);'#10 +
    '  X := VQ([I]);'#10 +
    '  X := VR([I]);'#10 +
    '  X := SR(([1, 2]));'#10 +
    '  X := SRM(([1, 2]));'#10 +
    '  X := SJ(([1, 2]));'#10 +
    '  X := SD(([1, 2]));'#10 +
    '  X := RC([1, 2]);'#10 +
    'end;'#10'end.'#10;

  { `class operator Implicit` by its signature in the unit's own typer
    (UserConvSym, the project's UserConvX rule; 6.3.1, 9.3.1,
    local/type-conv-2026-11/n2): SemaProjectSmoke's TestImplicitRanking in
    one unit. The overload dcc does NOT pick is declared first. }
  SRC_IMPL =
    'unit U;'#10'interface'#10'type'#10 +
    '  TRA = record A: Integer; end;'#10 +
    '  TRW = record W: Integer; end;'#10 +
    '  TBase = class end;'#10 +
    '  TDer = class(TBase) end;'#10 +
    '  TRi = record class operator Implicit(A: Integer): TRi; end;'#10 +
    '  TRb = record class operator Implicit(A: Byte): TRb; end;'#10 +
    '  TRv = record class operator Implicit(const A: Variant): TRv; end;'#10 +
    '  TRs = record class operator Implicit(const A: string): TRs; end;'#10 +
    '  TRe = record class operator Explicit(A: Integer): TRe; end;'#10 +
    '  TRo = record class operator Implicit(A: TBase): TRo; end;'#10 +
    '  TOi = record class operator Implicit(const A: TOi): Integer; end;'#10 +
    '  TOis = record'#10 +
    '    class operator Implicit(const A: TOis): Integer;'#10 +
    '    class operator Implicit(const A: TOis): string;'#10 +
    '  end;'#10 +
    '  TA = record X: Integer; end;'#10 +
    '  TB = record class operator Implicit(const A: TA): TB; end;'#10 +
    '  TC = record class operator Implicit(A: Integer): TC; end;'#10 +
    'function IA(X: Byte): TRA; overload;'#10 +
    'function IA(const X: TRi): TRW; overload;'#10 +
    'function IB(const X: TRi): TRA; overload;'#10 +
    'function IB(X: Double): TRW; overload;'#10 +
    'function IC(const X: TRi): TRA; overload;'#10 +
    'function IC(const X: TRb): TRW; overload;'#10 +
    'function ID(X: Double): TRA; overload;'#10 +
    'function ID(const X: TRv): TRW; overload;'#10 +
    'function IE(const X: TRe): TRA; overload;'#10 +
    'function IE(X: Byte): TRW; overload;'#10 +
    'function IFs(const X: TRi): TRA; overload;'#10 +
    'function IFs(const X: TRs): TRW; overload;'#10 +
    'function IG(X: ShortInt): TRA; overload;'#10 +
    'function IG(X: Byte): TRW; overload;'#10 +
    'function IH(X: Int64): TRA; overload;'#10 +
    'function IH(const X: string): TRW; overload;'#10 +
    'function IJ(X: Double): TRA; overload;'#10 +
    'function IJ(X: Int64): TRW; overload;'#10 +
    'function IM(const X: TRo): TRA; overload;'#10 +
    'function IM(X: TBase): TRW; overload;'#10 +
    'function INs(X: Double): TRA; overload;'#10 +
    'function INs(const X: TRv): TRW; overload;'#10 +
    'function IO(const X: AnsiString): TRA; overload;'#10 +
    'function IO(const X: TRv): TRW; overload;'#10 +
    'function IP(X: Byte): TRA; overload;'#10 +
    'function IP(const X: TRi): TRW; overload;'#10 +
    'function IQ(const X: TC): TRA; overload;'#10 +
    'function IQ(const X: TB): TRW; overload;'#10 +
    'implementation'#10 +
    'class operator TRi.Implicit(A: Integer): TRi; begin end;'#10 +
    'class operator TRb.Implicit(A: Byte): TRb; begin end;'#10 +
    'class operator TRv.Implicit(const A: Variant): TRv; begin end;'#10 +
    'class operator TRs.Implicit(const A: string): TRs; begin end;'#10 +
    'class operator TRe.Explicit(A: Integer): TRe; begin end;'#10 +
    'class operator TRo.Implicit(A: TBase): TRo; begin end;'#10 +
    'class operator TOi.Implicit(const A: TOi): Integer; begin end;'#10 +
    'class operator TOis.Implicit(const A: TOis): Integer; begin end;'#10 +
    'class operator TOis.Implicit(const A: TOis): string; begin end;'#10 +
    'class operator TB.Implicit(const A: TA): TB; begin end;'#10 +
    'class operator TC.Implicit(A: Integer): TC; begin end;'#10 +
    'function IA(X: Byte): TRA; begin end;'#10 +
    'function IA(const X: TRi): TRW; begin end;'#10 +
    'function IB(const X: TRi): TRA; begin end;'#10 +
    'function IB(X: Double): TRW; begin end;'#10 +
    'function IC(const X: TRi): TRA; begin end;'#10 +
    'function IC(const X: TRb): TRW; begin end;'#10 +
    'function ID(X: Double): TRA; begin end;'#10 +
    'function ID(const X: TRv): TRW; begin end;'#10 +
    'function IE(const X: TRe): TRA; begin end;'#10 +
    'function IE(X: Byte): TRW; begin end;'#10 +
    'function IFs(const X: TRi): TRA; begin end;'#10 +
    'function IFs(const X: TRs): TRW; begin end;'#10 +
    'function IG(X: ShortInt): TRA; begin end;'#10 +
    'function IG(X: Byte): TRW; begin end;'#10 +
    'function IH(X: Int64): TRA; begin end;'#10 +
    'function IH(const X: string): TRW; begin end;'#10 +
    'function IJ(X: Double): TRA; begin end;'#10 +
    'function IJ(X: Int64): TRW; begin end;'#10 +
    'function IM(const X: TRo): TRA; begin end;'#10 +
    'function IM(X: TBase): TRW; begin end;'#10 +
    'function INs(X: Double): TRA; begin end;'#10 +
    'function INs(const X: TRv): TRW; begin end;'#10 +
    'function IO(const X: AnsiString): TRA; begin end;'#10 +
    'function IO(const X: TRv): TRW; begin end;'#10 +
    'function IP(X: Byte): TRA; begin end;'#10 +
    'function IP(const X: TRi): TRW; begin end;'#10 +
    'function IQ(const X: TC): TRA; begin end;'#10 +
    'function IQ(const X: TB): TRW; begin end;'#10 +
    'procedure Test(I: Integer; Bt: Byte; I64: Int64; const S: string;'#10 +
    '  const V: Variant; const ROi: TOi; const ROis: TOis; Der: TDer;'#10 +
    '  const RA: TA);'#10 +
    'var'#10 +
    '  X: TRW;'#10 +
    'begin'#10 +
    '  X := IA(I);'#10 +
    '  X := IB(I);'#10 +
    '  X := IC(Bt);'#10 +
    '  X := ID(I64);'#10 +
    '  X := IE(I);'#10 +
    '  X := IFs(S);'#10 +
    '  X := IG(ROi);'#10 +
    '  X := IH(ROis);'#10 +
    '  X := IJ(ROi);'#10 +
    '  X := IM(Der);'#10 +
    '  X := INs(V);'#10 +
    '  X := IO(''abc'');'#10 +
    '  X := IP(300);'#10 +
    '  X := IQ(RA);'#10 +
    'end;'#10'end.'#10;

  { dcc's ranking of number and string conversions in the unit's own typer
    (ConvRank, 6.3.1; local/type-conv-2026-11/n1), the project pass's rule:
    the overload dcc does NOT pick is declared first. An integer literal by
    its value (A, B), a variable by its type (D, E, G, H), a cast constant
    its own type then its value (M), the string kinds (P, R, T, U), no rank
    for a `var` parameter (V: TryTextToValue's shape). Each TRW
    overload is dcc's pick; each typed TRA before 0.148.0. C (a literal
    beyond Integer) and O (a constant expression) this typer leaves to the
    project pass - it selects no overload for them; SemaProjectSmoke's
    TestConvRanking has them. }
  SRC_CONV =
    'unit U;'#10'interface'#10'type'#10 +
    '  TRA = record A: Integer; end;'#10 +
    '  TRW = record W: Integer; end;'#10 +
    'const KB = 5;'#10 +
    'function A(X: Integer): TRA; overload;'#10 +
    'function A(X: Byte): TRW; overload;'#10 +
    'function B(X: Byte): TRA; overload;'#10 +
    'function B(X: Word): TRW; overload;'#10 +
    'function C(X: Double): TRA; overload;'#10 +
    'function C(X: Int64): TRW; overload;'#10 +
    'function D(X: Integer): TRA; overload;'#10 +
    'function D(X: SmallInt): TRW; overload;'#10 +
    'function E(X: Int64): TRA; overload;'#10 +
    'function E(X: Cardinal): TRW; overload;'#10 +
    'function G(X: Double): TRA; overload;'#10 +
    'function G(X: Single): TRW; overload;'#10 +
    'function H(X: Single): TRA; overload;'#10 +
    'function H(X: Double): TRW; overload;'#10 +
    'function M(X: Integer): TRA; overload;'#10 +
    'function M(X: ShortInt): TRW; overload;'#10 +
    'function O(X: Integer): TRA; overload;'#10 +
    'function O(X: Word): TRW; overload;'#10 +
    'function P(const X: AnsiString): TRA; overload;'#10 +
    'function P(const X: WideString): TRW; overload;'#10 +
    'function R(const X: Variant): TRA; overload;'#10 +
    'function R(X: PChar): TRW; overload;'#10 +
    'function T(const X: Variant): TRA; overload;'#10 +
    'function T(const X: WideString): TRW; overload;'#10 +
    'function U(X: AnsiChar): TRA; overload;'#10 +
    'function U(const X: WideString): TRW; overload;'#10 +
    'function V(var X: Double; D: Double): TRA; overload;'#10 +
    'function V(var X: Single; D: Single): TRW; overload;'#10 +
    'implementation'#10 +
    'function A(X: Integer): TRA; begin end;'#10 +
    'function A(X: Byte): TRW; begin end;'#10 +
    'function B(X: Byte): TRA; begin end;'#10 +
    'function B(X: Word): TRW; begin end;'#10 +
    'function C(X: Double): TRA; begin end;'#10 +
    'function C(X: Int64): TRW; begin end;'#10 +
    'function D(X: Integer): TRA; begin end;'#10 +
    'function D(X: SmallInt): TRW; begin end;'#10 +
    'function E(X: Int64): TRA; begin end;'#10 +
    'function E(X: Cardinal): TRW; begin end;'#10 +
    'function G(X: Double): TRA; begin end;'#10 +
    'function G(X: Single): TRW; begin end;'#10 +
    'function H(X: Single): TRA; begin end;'#10 +
    'function H(X: Double): TRW; begin end;'#10 +
    'function M(X: Integer): TRA; begin end;'#10 +
    'function M(X: ShortInt): TRW; begin end;'#10 +
    'function O(X: Integer): TRA; begin end;'#10 +
    'function O(X: Word): TRW; begin end;'#10 +
    'function P(const X: AnsiString): TRA; begin end;'#10 +
    'function P(const X: WideString): TRW; begin end;'#10 +
    'function R(const X: Variant): TRA; begin end;'#10 +
    'function R(X: PChar): TRW; begin end;'#10 +
    'function T(const X: Variant): TRA; begin end;'#10 +
    'function T(const X: WideString): TRW; begin end;'#10 +
    'function U(X: AnsiChar): TRA; begin end;'#10 +
    'function U(const X: WideString): TRW; begin end;'#10 +
    'function V(var X: Double; D: Double): TRA; begin end;'#10 +
    'function V(var X: Single; D: Single): TRW; begin end;'#10 +
    'procedure Test(Bt: Byte; Wd: Word; I: Integer; I64: Int64; S: string;'#10 +
    '  C: Char; SG: Single; DV: Double);'#10 +
    'var X: TRW;'#10 +
    'begin'#10 +
    '  X := A(5);'#10 +
    '  X := B(300);'#10 +
    '  X := C(5000000000);'#10 +
    '  X := D(Bt);'#10 +
    '  X := E(Wd);'#10 +
    '  X := G(I);'#10 +
    '  X := H(I64);'#10 +
    '  X := M(Byte(5));'#10 +
    '  X := O(KB + 300);'#10 +
    '  X := P(S);'#10 +
    '  X := R(''abc'');'#10 +
    '  X := T(C);'#10 +
    '  X := U(''a'');'#10 +
    '  X := V(SG, DV);'#10 +
    'end;'#10'end.'#10;

  { Classes, interfaces and nil in the unit's own typer (RefConvSym, the
    project's XRefConvX; 6.3.1, 14.2.1, local/type-conv-2026-11/n3): a
    nearer ancestor class over a farther one (UA), an unrelated class out
    (UB), a class over an interface (UC), an interface no class of the
    chain lists out (UD: TImpl lists IB, not its ancestor IA), a nearer
    ancestor interface (UE), an unrelated one out (UF), an interface over
    Variant (UG), an interface to a class out (UH), nil to Pointer over
    Variant (UI) and to a class with Variant out (UJ), an interface type
    name to TGUID, not to itself (UK). The overload dcc does NOT pick is
    declared first. }
  SRC_REF =
    'unit U;'#10'interface'#10'type'#10 +
    '  TRA = record A: Integer; end;'#10 +
    '  TRW = record W: Integer; end;'#10 +
    '  TGUID = record D1: Cardinal; end;'#10 +
    '  IA = interface end;'#10 +
    '  IB = interface(IA) end;'#10 +
    '  IC = interface(IB) end;'#10 +
    '  IX = interface end;'#10 +
    '  TBase = class end;'#10 +
    '  TMid = class(TBase) end;'#10 +
    '  TDer = class(TMid) end;'#10 +
    '  TOther = class end;'#10 +
    '  TImpl = class(TBase, IB) end;'#10 +
    'function UA(X: TBase): TRA; overload;'#10 +
    'function UA(X: TMid): TRW; overload;'#10 +
    'function UB(X: TOther): TRA; overload;'#10 +
    'function UB(X: TBase): TRW; overload;'#10 +
    'function UC(const X: IB): TRA; overload;'#10 +
    'function UC(X: TBase): TRW; overload;'#10 +
    'function UD(const X: IA): TRA; overload;'#10 +
    'function UD(X: Pointer): TRW; overload;'#10 +
    'function UE(const X: IA): TRA; overload;'#10 +
    'function UE(const X: IB): TRW; overload;'#10 +
    'function UF(const X: IX): TRA; overload;'#10 +
    'function UF(const X: IA): TRW; overload;'#10 +
    'function UG(const X: Variant): TRA; overload;'#10 +
    'function UG(const X: IB): TRW; overload;'#10 +
    'function UH(X: TBase): TRA; overload;'#10 +
    'function UH(const X: Variant): TRW; overload;'#10 +
    'function UI(const X: Variant): TRA; overload;'#10 +
    'function UI(X: Pointer): TRW; overload;'#10 +
    'function UJ(const X: Variant): TRA; overload;'#10 +
    'function UJ(X: TBase): TRW; overload;'#10 +
    'function UK(const X: IA): TRA; overload;'#10 +
    'function UK(const G: TGUID): TRW; overload;'#10 +
    'implementation'#10 +
    'function UA(X: TBase): TRA; begin end;'#10 +
    'function UA(X: TMid): TRW; begin end;'#10 +
    'function UB(X: TOther): TRA; begin end;'#10 +
    'function UB(X: TBase): TRW; begin end;'#10 +
    'function UC(const X: IB): TRA; begin end;'#10 +
    'function UC(X: TBase): TRW; begin end;'#10 +
    'function UD(const X: IA): TRA; begin end;'#10 +
    'function UD(X: Pointer): TRW; begin end;'#10 +
    'function UE(const X: IA): TRA; begin end;'#10 +
    'function UE(const X: IB): TRW; begin end;'#10 +
    'function UF(const X: IX): TRA; begin end;'#10 +
    'function UF(const X: IA): TRW; begin end;'#10 +
    'function UG(const X: Variant): TRA; begin end;'#10 +
    'function UG(const X: IB): TRW; begin end;'#10 +
    'function UH(X: TBase): TRA; begin end;'#10 +
    'function UH(const X: Variant): TRW; begin end;'#10 +
    'function UI(const X: Variant): TRA; begin end;'#10 +
    'function UI(X: Pointer): TRW; begin end;'#10 +
    'function UJ(const X: Variant): TRA; begin end;'#10 +
    'function UJ(X: TBase): TRW; begin end;'#10 +
    'function UK(const X: IA): TRA; begin end;'#10 +
    'function UK(const G: TGUID): TRW; begin end;'#10 +
    'procedure Test(Der: TDer; Impl: TImpl; const JB: IB; const JC: IC);'#10 +
    'var'#10 +
    '  X: TRW;'#10 +
    'begin'#10 +
    '  X := UA(Der);'#10 +
    '  X := UB(Der);'#10 +
    '  X := UC(Impl);'#10 +
    '  X := UD(Impl);'#10 +
    '  X := UE(JC);'#10 +
    '  X := UF(JB);'#10 +
    '  X := UG(JC);'#10 +
    '  X := UH(JB);'#10 +
    '  X := UI(nil);'#10 +
    '  X := UJ(nil);'#10 +
    '  X := UK(IA);'#10 +
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

  Analyze(SRC_OPEN);
  for var LName in ['J', 'L', 'O', 'Y', 'Z'] do
    Ok('open array (6.2.6): ' + LName + ' binds the TRW overload',
      HasCallTyped(LName, 'TRW') and not HasCallTyped(LName, 'TRA'));
  Ok('open array: no E2010', DiagCount('E2010') = 0);
  GModel.Free;

  Analyze(SRC_OPEN2);
  for var LName in ['J', 'L', 'Q', 'K', 'D', 'V', 'N', 'E', 'F', 'JM', 'LM',
    'QM', 'KM', 'DM', 'VM', 'NM', 'CR', 'CRM'] do
    Ok('[...] / inline array (6.3.1): ' + LName + ' binds the TRW overload',
      HasCallTyped(LName, 'TRW') and not HasCallTyped(LName, 'TRA'));
  Ok('[...] / inline array: no E2010', DiagCount('E2010') = 0);
  GModel.Free;

  Analyze(SRC_OPEN3);
  for var LName in ['G', 'GM', 'H', 'HM', 'HV', 'P', 'R'] do
    Ok('[...] for a dynamic array (6.3.1): ' + LName +
      ' binds the TRW overload',
      HasCallTyped(LName, 'TRW') and not HasCallTyped(LName, 'TRA'));
  Ok('[...] for a dynamic array: no E2010', DiagCount('E2010') = 0);
  GModel.Free;

  Analyze(SRC_OPEN4);
  // VQ / VR: the mode takes no part in the ranking - `[I]` takes the `var` /
  // `out` open array over `array of const`, as dcc does before its E2197.
  // CF: a type name in brackets is a class reference, in parentheses too.
  for var LName in ['SR', 'SRM', 'SJ', 'SD', 'RC', 'VQ', 'VR', 'CF'] do
    Ok('6.3.1 brackets: ' + LName + ' binds the TRW overload',
      HasCallTyped(LName, 'TRW') and not HasCallTyped(LName, 'TRA'));
  Ok('([...]) is a set: no E2010', DiagCount('E2010') = 0);
  GModel.Free;

  Analyze(SRC_CONV);
  for var LName in ['A', 'B', 'D', 'E', 'G', 'H', 'M', 'P', 'R', 'T',
    'U', 'V'] do
    Ok('conversion ranking (6.3.1): ' + LName + ' binds the TRW overload',
      HasCallTyped(LName, 'TRW') and not HasCallTyped(LName, 'TRA'));
  Ok('conversion ranking: no E2010', DiagCount('E2010') = 0);
  GModel.Free;

  Analyze(SRC_IMPL);
  for var LName in ['IA', 'IB', 'IC', 'ID', 'IE', 'IFs', 'IG', 'IH', 'IJ',
    'IM', 'INs', 'IO', 'IP', 'IQ'] do
    Ok('Implicit by signature (6.3.1): ' + LName + ' binds the TRW overload',
      HasCallTyped(LName, 'TRW') and not HasCallTyped(LName, 'TRA'));
  GModel.Free;

  Analyze(SRC_REF);
  for var LName in ['UA', 'UB', 'UC', 'UD', 'UE', 'UF', 'UG', 'UH', 'UI',
    'UJ', 'UK'] do
    Ok('class / interface / nil ranking (6.3.1, 14.2.1): ' + LName +
      ' binds the TRW overload',
      HasCallTyped(LName, 'TRW') and not HasCallTyped(LName, 'TRA'));
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
