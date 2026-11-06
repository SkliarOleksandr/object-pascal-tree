program ConvSmoke;

{ The one conversion test, TPasSemaProject.XConvX (TSemaConv), against dcc's
  verdicts: a grid of destination types x source variables, every cell a
  grade backed by a dcc64 37.0 probe (local/type-conv-2026-11/m2 Set A: `d :=
  v` compiles or not - the same verdicts as a lone value parameter of a
  routine that is not overloaded, 2,870 of 2,870 alike), a list of further
  type pairs (m2 Set X), and the ranking orders of stages 1-8 where a rank
  function answers them alone (n1, n3, n5, n6, n7, n8).

  A cell is the grade XConvX must answer and what dcc said:
    I  scIdentical, dcc compiles      C  scImplicit, dcc compiles
    N  scNone, dcc refuses            m  scMaybe, dcc compiles
    x  scMaybe, dcc refuses           c  scImplicit, dcc refuses (a gap
                                         on the error-tolerant side)
  scNone where dcc compiles has no letter: that is a false E2010, never a
  grade this suite keeps. Run with -dump to print the grades XConvX answers
  now, in the grid's shape. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Generics.Collections,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Dcu in '..\source\PasTree.Dcu.pas',
  PasTree.Dcu.Source in '..\source\PasTree.Dcu.Source.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.Project in '..\source\PasTree.Project.pas',
  PasTree.Sema.Diagnostics in '..\source\PasTree.Sema.Diagnostics.pas',
  PasTree.Sema.Model in '..\source\PasTree.Sema.Model.pas',
  PasTree.Sema.Builtins in '..\source\PasTree.Sema.Builtins.pas',
  PasTree.Sema.Types in '..\source\PasTree.Sema.Types.pas',
  PasTree.Sema.Resolver in '..\source\PasTree.Sema.Resolver.pas',
  PasTree.Sema.Project in '..\source\PasTree.Sema.Project.pas',
  PasTree.TestKit in 'PasTree.TestKit.pas';

type
  TConvPair = record
    Dst, Src: string;
    Cell: Char;
  end;

const
  // The sources, in the grid's column order: n8's 39 variables.
  SRCS: array[0..38] of string = ('vB', 'vSh', 'vW', 'vI', 'vCard', 'vI64',
    'vSub', 'vIal', 'vId', 'vSg', 'vD', 'vE', 'vCur', 'vBo', 'vEn', 'vCh',
    'vAC', 'vS', 'vAS', 'vWS', 'vSS', 'vPC', 'vPtr', 'vPI', 'vV', 'vOV', 'vO',
    'vC', 'vCls', 'vIntf', 'vSE', 'vR', 'vRi', 'vDA', 'vTA', 'vSA', 'vP1',
    'vM1', 'vGuid');
  SRC_TYPES: array[0..38] of string = ('Byte', 'ShortInt', 'Word', 'Integer',
    'Cardinal', 'Int64', 'TSub', 'TIal', 'TId', 'Single', 'Double', 'Extended',
    'Currency', 'Boolean', 'TE', 'Char', 'AnsiChar', 'string', 'AnsiString',
    'WideString', 'ShortString', 'PChar', 'Pointer', 'PI', 'Variant',
    'OleVariant', 'TObject', 'TComponent', 'TClass', 'IInterface', 'TSE', 'TR',
    'TRi', 'TDA', 'TArray<Integer>', 'TSA', 'TP1', 'TM1', 'TGUID');

  {$I ConvSmoke.grid.inc}

  // The universe: n8's (common.ps1), on a fixture System and Classes.
  SYS_UNIT =
    'unit System;'#10'interface'#10'type'#10 +
    '  TObject = class end;'#10 +
    '  TClass = class of TObject;'#10 +
    '  TGUID = record D1: Cardinal; D2, D3: Word; end;'#10 +
    '  IInterface = interface'#10 +
    '    [''{00000000-0000-0000-C000-000000000046}'']'#10 +
    '    function _AddRef: Integer; stdcall;'#10 +
    '  end;'#10 +
    '  IUnknown = IInterface;'#10 +
    '  TInterfacedObject = class(TObject, IInterface)'#10 +
    '    function _AddRef: Integer; stdcall;'#10 +
    '  end;'#10 +
    '  TArray<T> = array of T;'#10 +
    '  TVarRec = record VType: Byte; end;'#10 +
    '  PInteger = ^Integer;'#10 +
    'implementation'#10 +
    'function TInterfacedObject._AddRef: Integer; begin Result := 0; end;'#10 +
    'end.'#10;
  CLS_UNIT =
    'unit Classes;'#10'interface'#10'type'#10 +
    '  TPersistent = class(TObject) end;'#10 +
    '  TComponent = class(TPersistent, IInterface)'#10 +
    '    function _AddRef: Integer; stdcall;'#10 +
    '  end;'#10 +
    '  TComponentClass = class of TComponent;'#10 +
    '  TProc<T> = reference to procedure(Arg1: T);'#10 +
    'implementation'#10 +
    'function TComponent._AddRef: Integer; begin Result := 0; end;'#10 +
    'end.'#10;
  UNI_HEAD =
    'unit ConvU;'#10'interface'#10'uses Classes;'#10'type'#10 +
    '  TE = (e1, e2, e3);'#10 +
    '  TSub = 1..10;'#10 +
    '  TSE = set of TE;'#10 +
    '  TIal = Integer;'#10 +
    '  TId = type Integer;'#10 +
    '  TR = record X: Integer; end;'#10 +
    '  TRi = record X: Integer; class operator Implicit(A: Integer): TRi; end;'#10 +
    '  TRs = record X: Integer; class operator Implicit(const A: string): TRs; end;'#10 +
    '  TRo = record X: Integer; class operator Implicit(A: TObject): TRo; end;'#10 +
    '  TDA = array of Integer;'#10 +
    '  TSA = array[0..1] of Integer;'#10 +
    '  TP1 = procedure(A: Integer);'#10 +
    '  TM1 = procedure(A: Integer) of object;'#10 +
    '  PI = ^Integer;'#10 +
    '  TSE2 = set of TE;'#10 +
    '  IA = interface(IInterface) end;'#10 +
    '  TP1d = type TP1;'#10 +
    '  TRP = reference to procedure(A: Integer);'#10 +
    '  TCA = array[0..3] of Char;'#10 +
    // m2 Set X's additions.
    '  TES = e1..e2;'#10 +
    '  TES2 = e2..e3;'#10 +
    '  PI2 = ^Integer;'#10 +
    '  TF0 = function: Integer;'#10 +
    '  TRP2 = reference to procedure(A: Integer);'#10 +
    '  TCh = ''a''..''z'';'#10 +
    '  TClsA = class end;'#10 +
    '  TClsB = class(TClsA) end;'#10 +
    '  TClsAC = class of TClsA;'#10 +
    '  TClsBC = class of TClsB;'#10 +
    '  IB = interface(IA) end;'#10 +
    '  TImplA = class(TInterfacedObject, IA) end;'#10 +
    '  TImplB = class(TImplA) end;'#10 +
    '  TBy = 0..255;'#10 +
    '  TDA2 = array of Integer;'#10 +
    'var'#10 +
    '  vB: Byte; vSh: ShortInt; vW: Word; vI: Integer; vCard: Cardinal;'#10 +
    '  vI64: Int64; vSub: TSub; vIal: TIal; vId: TId; vSg: Single;'#10 +
    '  vD: Double; vE: Extended; vCur: Currency; vBo: Boolean; vEn: TE;'#10 +
    '  vCh: Char; vAC: AnsiChar; vS: string; vAS: AnsiString;'#10 +
    '  vWS: WideString; vSS: ShortString; vPC: PChar; vPtr: Pointer; vPI: PI;'#10 +
    '  vV: Variant; vOV: OleVariant; vO: TObject; vC: TComponent;'#10 +
    '  vCls: TClass; vIntf: IInterface; vSE: TSE; vR: TR; vRi: TRi;'#10 +
    '  vDA: TDA; vTA: TArray<Integer>; vSA: TSA; vP1: TP1; vM1: TM1;'#10 +
    '  vGuid: TGUID;'#10 +
    '  vES: TES; vES2: TES2; vPI2: PI2; vF0: TF0; vRP: TRP; vRP2: TRP2;'#10 +
    '  vTP: TProc<Integer>; vPB: PByte; vCh2: TCh; vImB: TImplB; vImA: TImplA;'#10 +
    '  vIA: IA; vIB: IB; vBy: TBy; vClA: TClsAC; vClB: TClsBC; vDA2: TDA2;'#10 +
    '  vPAC: PAnsiChar; vWC: WideChar; vCA: TCA; vP1d: TP1d; vSE2: TSE2;'#10 +
    '  vLB: LongBool; vNI: NativeInt; vClsA: TClsA; vClsB: TClsB;'#10 +
    '  vCC: TComponentClass; vRs: TRs; vRo: TRo; vPInt: PInteger;'#10;

var
  GProj: TPasSemaProject;
  GCounter: TPasSuiteCounter;
  GUnit: Integer;

function DstVar(AIdx: Integer): string;
begin
  Result := 'd' + IntToStr(AIdx);
end;

function UnitSource: string;
var
  LIdx: Integer;
begin
  Result := UNI_HEAD;
  for LIdx := 0 to High(DSTS) do
    Result := Result + '  ' + DstVar(LIdx) + ': ' + DSTS[LIdx] + ';'#10;
  Result := Result + 'implementation'#10 +
    'class operator TRi.Implicit(A: Integer): TRi; begin Result.X := 1; end;'#10 +
    'class operator TRs.Implicit(const A: string): TRs; begin Result.X := 2; end;'#10 +
    'class operator TRo.Implicit(A: TObject): TRo; begin Result.X := 3; end;'#10 +
    'end.'#10;
end;

// The declared type of the variable ANameLower of ConvU.
function VarTypeX(const AName: string): TSemaXType;
var
  LM: TPasSemaModel;
  LSym: Integer;
begin
  LM := GProj.Model(GUnit);
  LSym := LM.Resolve(LM.InterfaceScope, LowerCase(AName));
  if LSym = NIL_SYM then
    raise Exception.Create('ConvSmoke: no variable ' + AName);
  Result := GProj.SymDeclTypeX(GUnit, LSym);
end;

function GradeChar(AConv: TSemaConv): Char;
begin
  case AConv of
    scIdentical: Result := 'I';
    scImplicit: Result := 'C';
    scMaybe: Result := 'M';
  else
    Result := 'N';
  end;
end;

// The grade a cell asks for (the case of 'm', 'x', 'c' is dcc's verdict).
function CellGrade(ACell: Char): Char;
begin
  case ACell of
    'm', 'x': Result := 'M';
    'c': Result := 'C';
  else
    Result := ACell;
  end;
end;

procedure Check(const ADst, ASrc: string; ACell: Char);
var
  LGot: Char;
begin
  LGot := GradeChar(GProj.XConvX(VarTypeX(ADst), VarTypeX(ASrc)));
  GCounter.Ok(Format('XConvX(%s := %s) = %s [got %s]',
    [ADst, ASrc, ACell, LGot]), LGot = CellGrade(ACell));
end;

procedure TestGrid(ADump: Boolean);
var
  LRow, LCol: Integer;
  LLine: string;
begin
  for LRow := 0 to High(DSTS) do
  begin
    if ADump then
    begin
      LLine := '';
      for LCol := 0 to High(SRCS) do
        LLine := LLine + GradeChar(GProj.XConvX(VarTypeX(DstVar(LRow)),
          VarTypeX(SRCS[LCol])));
      Writeln(Format('%-18s %s', [DSTS[LRow], LLine]));
      Continue;
    end;
    if Length(GRID[LRow]) <> Length(SRCS) then
      raise Exception.Create('ConvSmoke: grid row ' + DSTS[LRow]);
    for LCol := 0 to High(SRCS) do
      Check(DstVar(LRow), SRCS[LCol], GRID[LRow][LCol + 1]);
  end;
end;

procedure TestPairs(ADump: Boolean);
var
  LIdx: Integer;
begin
  for LIdx := 0 to High(PAIRS) do
    if ADump then
      Writeln(Format('%-8s %-8s %s', [PAIRS[LIdx].Dst, PAIRS[LIdx].Src,
        GradeChar(GProj.XConvX(VarTypeX(PAIRS[LIdx].Dst),
        VarTypeX(PAIRS[LIdx].Src)))]))
    else
      Check(PAIRS[LIdx].Dst, PAIRS[LIdx].Src, PAIRS[LIdx].Cell);
end;

{ Stage 1's ranking of a variable's numeric and string conversions
  (ConvRank, dcc64: no wide Extended), n1's measured orders: each `>` a
  strictly higher rank, each `=` the same. }
procedure TestConvRankOrders;
const
  KINDS: array[TSemaConvKind] of string = ('', 'ShortInt', 'Byte',
    'SmallInt', 'Word', 'Integer', 'Cardinal', 'Int64', 'UInt64', 'Single',
    'Double', 'Extended', 'Currency', 'Comp', 'Variant', 'string',
    'WideString', 'AnsiString', 'UTF8String', 'RawByteString', 'ShortString',
    'Char', 'AnsiChar', 'PChar', 'PAnsiChar', '', '');
  ORDERS: array[0..23] of string = (
    'ShortInt:ShortInt > SmallInt > Integer > Int64 > UInt64 > Single=Currency=Comp > Double > Extended > Variant > Cardinal > Word',
    'Byte:Byte > SmallInt > Word > Integer > Cardinal > Int64 > UInt64 > Single=Currency=Comp > Double > Extended > Variant',
    'SmallInt:SmallInt > Integer > Int64 > UInt64 > Single=Currency=Comp > Double > Extended > Variant > Cardinal > Word > Byte',
    'Word:Word > Integer > Cardinal > Int64 > UInt64 > Single=Currency=Comp > Double > Extended > Variant > SmallInt > Byte',
    'Integer:Integer > Int64 > UInt64 > Single=Currency=Comp > Double > Extended > Variant > Cardinal > Word > SmallInt > Byte',
    'Cardinal:Cardinal > Int64 > UInt64 > Single=Currency=Comp > Double > Extended > Variant > Integer > Word > SmallInt > Byte',
    'Int64:Int64 > Comp > Variant > Currency=Extended > Double > Single > UInt64 > Cardinal > Integer > Word > SmallInt > Byte',
    'UInt64:UInt64 > Comp > Variant > Currency=Extended > Double > Single > Int64 > Cardinal > Integer > Word > SmallInt > Byte',
    'Single:Single > Double > Extended > Variant > Currency=Comp',
    'Double:Double > Extended > Variant > Single=Currency=Comp',
    'Extended:Extended > Variant > Currency=Double=Comp > Single',
    'Currency:Currency > Variant > Extended=Comp > Double > Single',
    'Comp:Comp > Variant > Currency=Extended > Double > Single',
    'Variant:Variant > Currency=Extended=Comp > Double > Single > UInt64 > Int64 > Cardinal > Integer > Word > SmallInt > Byte',
    'string:string > WideString > Variant > UTF8String=AnsiString=RawByteString > ShortString',
    'AnsiString:AnsiString > UTF8String=RawByteString > string > WideString > Variant > ShortString',
    'WideString:WideString > string > Variant > UTF8String=AnsiString=RawByteString > ShortString',
    'ShortString:ShortString > UTF8String=RawByteString > AnsiString > string > WideString > Variant',
    'RawByteString:RawByteString > UTF8String > AnsiString > string > WideString > Variant > ShortString',
    'UTF8String:UTF8String > AnsiString=RawByteString > string > WideString > Variant > ShortString',
    'PChar:PChar > string > WideString > UTF8String=AnsiString=RawByteString',
    'PAnsiChar:PAnsiChar > UTF8String=RawByteString > AnsiString > string > WideString > ShortString',
    'Char:Char > string > WideString > Variant > UTF8String=AnsiString=RawByteString > ShortString',
    'AnsiChar:AnsiChar > UTF8String=RawByteString > AnsiString > ShortString > string > WideString > Variant');

  function KindOf(const AName: string): TSemaConvKind;
  begin
    for Result := Low(TSemaConvKind) to High(TSemaConvKind) do
      if (KINDS[Result] <> '') and SameText(KINDS[Result], Trim(AName)) then
        Exit;
    raise Exception.Create('ConvSmoke: no conversion kind ' + AName);
  end;

var
  LArg: TSemaArgConv;
  LParts, LGroups, LNames: TArray<string>;
  LPrev, LRank, LGroup, LName: Integer;
  LOk: Boolean;
begin
  for var LOrder in ORDERS do
  begin
    LParts := LOrder.Split([':']);
    LArg := Default(TSemaArgConv);
    LArg.Kind := KindOf(LParts[0]);
    LGroups := LParts[1].Split(['>']);
    LPrev := MaxInt;
    LOk := True;
    for LGroup := 0 to High(LGroups) do
    begin
      LNames := LGroups[LGroup].Split(['=']);
      LRank := ConvRank(LArg, KindOf(LNames[0]), False);
      for LName := 1 to High(LNames) do
        if ConvRank(LArg, KindOf(LNames[LName]), False) <> LRank then
          LOk := False;
      if (LRank <= 0) or (LRank >= LPrev) then
        LOk := False;
      LPrev := LRank;
    end;
    GCounter.Ok('ConvRank order (n1, dcc64) ' + LOrder, LOk);
  end;
end;

{ The reference, procedural, array, pointer and parameter-mode ranks
  (stages 3, 5, 6, 7, 8): the orders their probes measured, read off the
  rank functions alone. }
procedure TestRefRankOrders;
var
  LByte, LZero: TSemaArgConv;
begin
  // n3: a class to its parent > a farther ancestor > an interface it
  // lists > Pointer; an interface to its parent > Variant; nil Pointer >
  // typed pointer > procedural > class > interface > class reference >
  // dynamic array.
  GCounter.Ok('RefConvRank: parent > grandparent',
    RefConvRank(rcClassUp, 1) > RefConvRank(rcClassUp, 2));
  GCounter.Ok('RefConvRank: TObject > interface',
    RefConvRank(rcClassUp, 9) > RefConvRank(rcClassIntf, 0));
  GCounter.Ok('RefConvRank: interface > Pointer',
    RefConvRank(rcClassIntf, 0) > RefConvRank(rcClassPointer, 0));
  GCounter.Ok('RefConvRank: an interface''s parent > Variant',
    RefConvRank(rcIntfUp, 1) > RefConvRank(rcIntfVariant, 0));
  GCounter.Ok('RefConvRank: nil Pointer > typed pointer > procedural',
    (RefConvRank(rcNilPointer, 0) > RefConvRank(rcNilTypedPointer, 0)) and
    (RefConvRank(rcNilTypedPointer, 0) > RefConvRank(rcNilProc, 0)));
  GCounter.Ok('RefConvRank: nil procedural > class > interface > class ref > dyn array',
    (RefConvRank(rcNilProc, 0) > RefConvRank(rcNilClass, 0)) and
    (RefConvRank(rcNilClass, 0) > RefConvRank(rcNilIntf, 0)) and
    (RefConvRank(rcNilIntf, 0) > RefConvRank(rcNilClassRef, 0)) and
    (RefConvRank(rcNilClassRef, 0) > RefConvRank(rcNilDynArray, 0)));
  // n7: a typed pointer to its own base under $T+ > Pointer; a class
  // reference to its parent's > Pointer.
  GCounter.Ok('pointer ranks: same base ($T+) > Pointer',
    CPtrRankSameBase > CPtrRankPointer);
  GCounter.Ok('RefConvRank: class ref parent > class ref Pointer',
    RefConvRank(rcClassRefUp, 1) > RefConvRank(rcClassRefPointer, 0));
  // n5: own type (exact) > a function's exact result > the signature > a
  // `reference to` type > another reference type.
  GCounter.Ok('ProcConvRank: result exact > same sig > to reference > ref copy',
    (ProcConvRank(pcResultExact) > ProcConvRank(pcSameSig)) and
    (ProcConvRank(pcSameSig) > ProcConvRank(pcToReference)) and
    (ProcConvRank(pcToReference) > ProcConvRank(pcRefCopy)));
  // n6: a dynamic array to Pointer > Variant.
  GCounter.Ok('array ranks: Pointer > Variant', CArrRankPointer > CArrRankVariant);
  // n8: an untyped parameter between a Byte's lossless conversions and
  // its Variant line - Integer > untyped > Variant > ShortInt.
  LByte := Default(TSemaArgConv);
  LByte.Kind := cnkByte;
  LByte.Facts.Cat := tcInteger;
  GCounter.Ok('untyped: Byte -> Integer > untyped > Variant > ShortInt',
    (ConvRank(LByte, cnkInteger, False) >
      UntypedParamRank(@LByte, tcInteger, False, False)) and
    (UntypedParamRank(@LByte, tcInteger, False, False) >
      ConvRank(LByte, cnkVariant, False)) and
    (ConvRank(LByte, cnkVariant, False) > ConvRank(LByte, cnkShortInt, False)));
  // n7: an integer constant 0 - a typed pointer > Pointer, both below the
  // value's Variant.
  LZero := Default(TSemaArgConv);
  LZero.Kind := cnkShortInt;
  LZero.Facts.Cat := tcInteger;
  LZero.Facts.IntConst := True;
  GCounter.Ok('ZeroPointerRank: typed > Pointer, below Variant',
    (ZeroPointerRank(True, ConvThreshold(LZero, False)) >
      ZeroPointerRank(False, ConvThreshold(LZero, False))) and
    (ConvRank(LZero, cnkVariant, False) >
      ZeroPointerRank(True, ConvThreshold(LZero, False))));
end;

var
  LDir: string;
  LDump: Boolean;
begin
  GCounter.Init;
  LDump := FindCmdLineSwitch('dump', ['-', '/'], True);
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_convsmoke');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'System.pas'), SYS_UNIT);
  TFile.WriteAllText(TPath.Combine(LDir, 'Classes.pas'), CLS_UNIT);
  TFile.WriteAllText(TPath.Combine(LDir, 'ConvU.pas'), UnitSource);
  TFile.WriteAllText(TPath.Combine(LDir, 'ConvP.dpr'),
    'program ConvP;'#10'uses ConvU;'#10'begin'#10'end.'#10);
  GProj := TPasSemaProject.Create(pfWin64, [LDir], []);
  try
    GProj.AnalyzeProject(TPath.Combine(LDir, 'ConvP.dpr'));
    GUnit := -1;
    for var LId := 0 to GProj.ModelCount - 1 do
      if GProj.Model(LId).UnitNameLower = 'convu' then
        GUnit := LId;
    if GUnit < 0 then
      raise Exception.Create('ConvSmoke: ConvU not analyzed');
    TestGrid(LDump);
    TestPairs(LDump);
    if not LDump then
    begin
      TestConvRankOrders;
      TestRefRankOrders;
    end;
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;
  if not LDump and GCounter.Finish('ConvSmoke') then
    ExitCode := 1;
end.
