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

procedure Analyze(const ASource: string; APlatform: TPasPlatform = pfWin32);
var
  LPre: TPasPreprocessed;
  LDiags: TArray<TPasParseDiag>;
begin
  LPre := GPP.ProcessText('test.pas', ASource);
  GTree := TPasParser.ParseFile(LPre, LDiags);
  GModel := TPasSemaResolver.Analyze(GTree, False, APlatform);
end;

// ExprType name of the right-hand side of the assignment whose target is the
// bare name ADst ('?' when untyped, '' when no such assignment).
function AssignedType(const ADst: string): string;
begin
  Result := '';
  for var LNode := 0 to High(GModel.ExprType) do
    if GTree.Nodes[LNode].Kind = nkAssign then
    begin
      var LDst := GTree.Nodes[LNode].FirstChild;
      if (LDst <> NIL_NODE) and (GTree.Nodes[LDst].Kind = nkIdent) and
         SameText(GTree.NodeText(LDst), ADst) then
      begin
        var LSrc := GTree.Nodes[LDst].NextSibling;
        if (LSrc <> NIL_NODE) and (GModel.ExprType[LSrc] <> NIL_SYM) then
          Result := GModel.Symbols[GModel.ExprType[LSrc]].Name
        else
          Result := '?';
        Exit;
      end;
    end;
end;

procedure Eq(const AName, AGot, AWant: string);
begin
  GCounter.Ok(AName, AGot = AWant,
    procedure
    begin
      Writeln('  got "', AGot, '", want "', AWant, '"');
    end);
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

  // ---- 4.11: the result type of every value-returning intrinsic, by the
  // dcc-probed rules PasTree.Sema.Builtins documents (local/probe/intr,
  // both compilers, 2026-09-07). Every target is a Variant so no assignment
  // check fires; the READ is the right-hand side's ExprType. ----
  const INTR =
    'unit u;'#10'interface'#10 +
    'type'#10 +
    '  TEnum = (eA, eB, eC);'#10 +
    '  TSub = 3..9;'#10 +
    '  TRec = record A: Integer; end;'#10 +
    '  TDynI = array of Integer;'#10 +
    '  TStatI = array[2..5] of Integer;'#10 +
    '  TStatE = array[TEnum] of Integer;'#10 +
    '  TStatC = array[''a''..''z''] of Integer;'#10 +
    '  TStatW = array[Word] of Integer;'#10 +
    '  TStatN = array[-5..5] of Integer;'#10 +
    '  TAlias = TDynI;'#10 +
    '  TObj = class end;'#10 +
    '  TProc = reference to procedure;'#10 +
    'implementation'#10 +
    'procedure P;'#10 +
    'var'#10 +
    '  I: Integer; C: Cardinal; I64: Int64; U64: UInt64; B: Byte; W: Word;'#10 +
    '  SmI: SmallInt; NI: NativeInt; NU: NativeUInt;'#10 +
    '  Db: Double; Cu: Currency; Ch: Char; AC: AnsiChar; Bo: Boolean;'#10 +
    '  S: string; AS_: AnsiString; SS: ShortString; V: Variant;'#10 +
    '  E: TEnum; Sub: TSub; DI: TDynI; SA: TStatI; SE: TStatE;'#10 +
    '  SC: TStatC; SW: TStatW; SN: TStatN; AL: TAlias; O: TObj; P_: Pointer;'#10 +
    '  R01, R02, R03, R04, R05, R06, R07, R08, R09, R10, R11, R12, R13, R14,'#10 +
    '  R15, R16, R17, R18, R19, R20, R21, R22, R23, R24, R25, R26, R27, R28,'#10 +
    '  R29, R30, R31, R32, R33, R34, R35, R36, R37, R38, R39, R40, R41, R42,'#10 +
    '  R43, R44, R45, R46, R47, R48, R49, R50, R51, R52, R53, R54: Variant;'#10 +
    'begin'#10 +
    '  R01 := Length(S);'#10 +
    '  R02 := Length(DI);'#10 +
    '  R03 := Length(SA);'#10 +
    '  R04 := Ord(I64);'#10 +
    '  R05 := Chr(65);'#10 +
    '  R06 := SizeOf(TRec);'#10 +
    '  R07 := Assigned(O);'#10 +
    '  R08 := Odd(I);'#10 +
    '  R09 := Trunc(Db);'#10 +
    '  R10 := Round(Cu);'#10 +
    '  R11 := Pi;'#10 +
    '  R12 := Abs(B);'#10 +
    '  R13 := Abs(I64);'#10 +
    '  R14 := Abs(Cu);'#10 +
    '  R15 := Abs(NI);'#10 +
    '  R16 := Abs(V);'#10 +
    '  R17 := Sqr(C);'#10 +
    '  R18 := Sqr(U64);'#10 +
    '  R19 := Sqr(Cu);'#10 +
    '  R20 := Sqr(SmI);'#10 +
    '  R21 := Pred(E);'#10 +
    '  R22 := Succ(Ch);'#10 +
    '  R23 := Succ(U64);'#10 +
    '  R24 := Pred(W);'#10 +
    '  R25 := Succ(Bo);'#10 +
    '  R26 := Pred(Sub);'#10 +
    '  R27 := Low(SA);'#10 +
    '  R28 := High(SE);'#10 +
    '  R29 := Low(SC);'#10 +
    '  R30 := High(SW);'#10 +
    '  R31 := Low(SN);'#10 +
    '  R32 := Low(DI);'#10 +
    '  R33 := High(DI);'#10 +
    '  R34 := High(AL);'#10 +
    '  R35 := Low(S);'#10 +
    '  R36 := High(TEnum);'#10 +
    '  R37 := High(Byte);'#10 +
    '  R38 := Low(Int64);'#10 +
    '  R39 := High(AC);'#10 +
    '  R40 := Hi(I64);'#10 +
    '  R41 := Swap(W);'#10 +
    '  R42 := Swap(B);'#10 +
    '  R43 := Addr(I);'#10 +
    '  R44 := TypeInfo(TRec);'#10 +
    '  R45 := Default(TRec);'#10 +
    '  R46 := Default(TObj);'#10 +
    '  R47 := Default(TDynI);'#10 +
    '  R48 := Default(TStatI);'#10 +
    '  R49 := Copy(AS_, 1, 2);'#10 +
    '  R50 := Copy(DI, 0, 1);'#10 +
    '  R51 := Concat(S, AS_);'#10 +
    '  R52 := Concat(SS, SS);'#10 +
    '  R53 := Concat(AC, AC);'#10 +
    '  R54 := AtomicIncrement(NI);'#10 +
    'end;'#10 +
    'end.'#10;
  Analyze(INTR);
  Ok('4.11: the intrinsic fixture itself is diagnostic-free',
    Length(GModel.Diags) = 0);
  Eq('4.11: Length(string) is Integer', AssignedType('R01'), 'Integer');
  Eq('4.11: Length(dynamic array) is NativeInt', AssignedType('R02'),
    'NativeInt');
  Eq('4.11: Length(static array) is Integer', AssignedType('R03'), 'Integer');
  Eq('4.11: Ord(Int64) is still Integer', AssignedType('R04'), 'Integer');
  Eq('4.11: Chr is Char', AssignedType('R05'), 'Char');
  Eq('4.11: SizeOf(T) is Integer', AssignedType('R06'), 'Integer');
  Eq('4.11: Assigned is Boolean', AssignedType('R07'), 'Boolean');
  Eq('4.11: Odd is Boolean', AssignedType('R08'), 'Boolean');
  Eq('4.11: Trunc is Int64', AssignedType('R09'), 'Int64');
  Eq('4.11: Round(Currency) is Int64', AssignedType('R10'), 'Int64');
  Eq('4.11: Pi is Extended', AssignedType('R11'), 'Extended');
  Eq('4.11: Abs(Byte) widens to Integer', AssignedType('R12'), 'Integer');
  Eq('4.11: Abs(Int64) is Int64', AssignedType('R13'), 'Int64');
  Eq('4.11: Abs(Currency) is Extended on Win32', AssignedType('R14'),
    'Extended');
  Eq('4.11: Abs(NativeInt) is NativeInt', AssignedType('R15'), 'NativeInt');
  Eq('4.11: Abs(Variant) is not typed', AssignedType('R16'), '?');
  Eq('4.11: Sqr(Cardinal) stays Cardinal', AssignedType('R17'), 'Cardinal');
  Eq('4.11: Sqr(UInt64) stays UInt64', AssignedType('R18'), 'UInt64');
  Eq('4.11: Sqr(Currency) is Extended', AssignedType('R19'), 'Extended');
  Eq('4.11: Sqr(SmallInt) widens to Integer', AssignedType('R20'), 'Integer');
  Eq('4.11: Pred(enum) is the enum', AssignedType('R21'), 'TEnum');
  Eq('4.11: Succ(Char) is Char', AssignedType('R22'), 'Char');
  Eq('4.11: Succ(UInt64) is Int64', AssignedType('R23'), 'Int64');
  Eq('4.11: Pred(Word) widens to Integer', AssignedType('R24'), 'Integer');
  Eq('4.11: Succ(Boolean) is Boolean', AssignedType('R25'), 'Boolean');
  Eq('4.11: Pred(subrange) is Integer', AssignedType('R26'), 'Integer');
  Eq('4.11: Low(static array) is its Integer bound', AssignedType('R27'),
    'Integer');
  Eq('4.11: High(enum-indexed array) is the enum', AssignedType('R28'),
    'TEnum');
  Eq('4.11: Low(Char-indexed array) is Char', AssignedType('R29'), 'Char');
  Eq('4.11: High(array[Word]) widens to Integer', AssignedType('R30'),
    'Integer');
  Eq('4.11: Low(array[-5..5]) is Integer', AssignedType('R31'), 'Integer');
  Eq('4.11: Low(dynamic array) is Integer', AssignedType('R32'), 'Integer');
  Eq('4.11: High(dynamic array) is NativeInt', AssignedType('R33'),
    'NativeInt');
  Eq('4.11: High through an alias of a dynamic array', AssignedType('R34'),
    'NativeInt');
  Eq('4.11: Low(string) is Integer', AssignedType('R35'), 'Integer');
  Eq('4.11: High(enum TYPE) is the enum', AssignedType('R36'), 'TEnum');
  Eq('4.11: High(Byte) is Integer', AssignedType('R37'), 'Integer');
  Eq('4.11: Low(Int64) is Int64', AssignedType('R38'), 'Int64');
  Eq('4.11: High(AnsiChar value) is AnsiChar', AssignedType('R39'),
    'AnsiChar');
  Eq('4.11: Hi(Int64) is Integer', AssignedType('R40'), 'Integer');
  Eq('4.11: Swap(Word) stays Word', AssignedType('R41'), 'Word');
  Eq('4.11: Swap(Byte) is Integer', AssignedType('R42'), 'Integer');
  Eq('4.11: Addr is Pointer', AssignedType('R43'), 'Pointer');
  Eq('4.11: TypeInfo is Pointer', AssignedType('R44'), 'Pointer');
  Eq('4.11: Default(record) is the record', AssignedType('R45'), 'TRec');
  Eq('4.11: Default(class) is Pointer (dcc: E2018 on a member after it)',
    AssignedType('R46'), 'Pointer');
  Eq('4.11: Default(dynamic array) is Pointer', AssignedType('R47'),
    'Pointer');
  Eq('4.11: Default(static array) is the array', AssignedType('R48'),
    'TStatI');
  Eq('4.11: Copy(AnsiString) stays AnsiString', AssignedType('R49'),
    'AnsiString');
  Eq('4.11: Copy(dynamic array) stays that array', AssignedType('R50'),
    'TDynI');
  Eq('4.11: Concat of mixed string kinds is string', AssignedType('R51'),
    'string');
  Eq('4.11: Concat(ShortString, ShortString) is AnsiString',
    AssignedType('R52'), 'AnsiString');
  Eq('4.11: Concat(AnsiChar, AnsiChar) is ShortString', AssignedType('R53'),
    'ShortString');
  Eq('4.11: AtomicIncrement(NativeInt) is NativeInt', AssignedType('R54'),
    'NativeInt');
  GModel.Free;

  // The same source on a 64-bit target: Currency and Comp keep their type
  // under Abs there (their arithmetic is integral), everything else holds.
  Analyze(INTR, pfWin64);
  Eq('4.11/Win64: Abs(Currency) is Currency', AssignedType('R14'), 'Currency');
  Eq('4.11/Win64: Sqr(Currency) is still Extended', AssignedType('R19'),
    'Extended');
  Eq('4.11/Win64: Length(dynamic array) is NativeInt', AssignedType('R02'),
    'NativeInt');
  GModel.Free;

  // A typed intrinsic result now takes part in the assignment check, the way
  // dcc's does: `Ch := Copy(S, 1, 1)` is E2010 ('Char' and 'string') under
  // dcc, `I := Length(S)` and `S := Chr(65)` are fine.
  Analyze(
    'unit u;'#10'interface'#10'implementation'#10 +
    'procedure P;'#10 +
    'var S: string; Ch: Char; I: Integer; D: Double;'#10 +
    'begin'#10 +
    '  I := Length(S);'#10 +
    '  S := Chr(65);'#10 +
    '  D := Sqr(I) + Pi;'#10 +
    '  Ch := Copy(S, 1, 1);'#10 +
    'end;'#10'end.'#10);
  Ok('4.11: exactly the one real E2010 (Char := Copy(...))',
    DiagCount('E2010') = 1);
  GModel.Free;

  if GCounter.Finish('SemaTypeSmoke') then
    ExitCode := 1;
  GPP.Free;
  GDefines.Free;
  GSM.Free;
end.
