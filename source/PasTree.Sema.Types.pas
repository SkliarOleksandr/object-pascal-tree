unit PasTree.Sema.Types;

{
  PasTree semantics — Phase 3a type checker (intra-unit).

  Runs after name resolution: categorizes user-declared types, computes a type
  symbol for each expression node (ExprType), and emits E2010 (incompatible
  assignment) / E2015 (operator not applicable). Deliberately conservative —
  only definite scalar mismatches are flagged; anything with an unknown/external
  operand or a class/record/enum/set/array/pointer/variant operand (where
  inheritance or operator overloading could make it legal) is allowed. Overload
  ranking, argument-count and cross-unit typing are later slices.
}

interface

uses
  PasTree.Ast,
  PasTree.Platforms,
  PasTree.Sema.Model;

type
  TPasSemaTyper = class
  private
    M: TPasSemaModel;
    T: TPasTree;
    // Only ONE rule needs it: a 64-bit ordinal `set of` base is E2001 while a
    // 32-bit one is E2028, and `NativeInt` is whichever the target says
    // (dcc32 E2028, dcc64 E2001 for the same source).
    FPlatform: TPasPlatform;
    Int, Ext, Str, Chr, Bool, Ptr, Nul: Integer;   // cached builtin type syms
    function Kind(N: Integer): TPasNodeKind; inline;
    function Child(N: Integer): Integer; inline;
    function Sib(N: Integer): Integer; inline;
    function Txt(N: Integer): string; inline;
    function OpText(N: Integer): string;
    function CatOf(ASym: Integer): TSemaTypeCat;
    function RankOf(ASym: Integer): Byte;
    function Head(N: Integer): Integer;
    function TypeDefNode(ASym: Integer): Integer;
    function CatFromNode(ADef: Integer): TSemaTypeCat;
    procedure CategorizeTypes;
    function CatOfTypeNode(ANode: Integer): TSemaTypeCat;
    procedure CheckOrdinalTypePositions;
    procedure CheckConditionTypes;
    function OrdLiteral(ANode: Integer; out AValue: Int64): Boolean;
    procedure CheckSetCardinality;
    function WiderNum(A, B: Integer): Integer;
    function TypeOfIdent(N: Integer): Integer;
    function BinaryResult(N: Integer): Integer;
    function UnaryResult(N: Integer): Integer;
    function CallResult(N: Integer): Integer;
    function ParamsOf(AScope: Integer): TArray<Integer>;
    function ArgCount(ACall: Integer): Integer;
    function ScoreArgs(ACall, AScope: Integer): Integer;
    function IsVarargs(AScope: Integer): Boolean;
    function SelectOverload(ACall, AHead: Integer): Integer;
    function MemberResult(N: Integer): Integer;
    procedure Diag(const ACode, AMsg: string; ANode: Integer);
    function Assignable(ADst, ASrc: Integer): Boolean;
    function InterfaceCounterpart(AHead: Integer): Integer;
    function IsTypeNameOperand(N: Integer): Boolean;
    procedure CheckAssign(N: Integer);
    function TypeNode(N: Integer): Integer;
    procedure Run;
  public
    class procedure Check(AModel: TPasSemaModel;
      APlatform: TPasPlatform = pfWin32); static;
  end;

implementation

uses
  System.SysUtils,
  PasTree.Preprocessor,
  PasTree.Sema.Diagnostics;

class procedure TPasSemaTyper.Check(AModel: TPasSemaModel;
  APlatform: TPasPlatform = pfWin32);
var
  LT: TPasSemaTyper;
begin
  LT := TPasSemaTyper.Create;
  try
    LT.M := AModel;
    LT.T := AModel.Tree;
    LT.FPlatform := APlatform;
    LT.Run;
  finally
    LT.Free;
  end;
end;

function TPasSemaTyper.Kind(N: Integer): TPasNodeKind;
begin
  Result := T.Nodes[N].Kind;
end;

function TPasSemaTyper.Child(N: Integer): Integer;
begin
  Result := T.Nodes[N].FirstChild;
end;

function TPasSemaTyper.Sib(N: Integer): Integer;
begin
  Result := T.Nodes[N].NextSibling;
end;

function TPasSemaTyper.Txt(N: Integer): string;
begin
  Result := T.NodeText(N);
end;

function TPasSemaTyper.OpText(N: Integer): string;
begin
  if T.Nodes[N].Aux >= 0 then
    Result := LowerCase(T.Source.VisibleText(T.Nodes[N].Aux))
  else
    Result := '';
end;

function TPasSemaTyper.CatOf(ASym: Integer): TSemaTypeCat;
begin
  if ASym = NIL_SYM then
    Result := tcUnknown
  else
    Result := M.Symbols[ASym].TypeCat;
end;

function TPasSemaTyper.RankOf(ASym: Integer): Byte;
begin
  if ASym = NIL_SYM then
    Result := 0
  else
    Result := M.Symbols[ASym].NumRank;
end;

// Symbol a type designator resolved to (reads RefMap).
function TPasSemaTyper.Head(N: Integer): Integer;
var
  LLast: Integer;
begin
  case Kind(N) of
    nkIdent:
      Result := M.RefMap[N];
    nkMember:
      begin
        LLast := Child(N);
        while (LLast <> NIL_NODE) and (Sib(LLast) <> NIL_NODE) do
          LLast := Sib(LLast);
        if LLast <> NIL_NODE then
          Result := M.RefMap[LLast]
        else
          Result := NIL_SYM;
      end;
    nkTypeArgs:
      Result := Head(Child(N));
  else
    Result := NIL_SYM;
  end;
end;

// The type-expression node defining a user type symbol.
function TPasSemaTyper.TypeDefNode(ASym: Integer): Integer;
var
  LName, LParent: Integer;
begin
  Result := NIL_NODE;
  LName := M.Symbols[ASym].DeclNode;
  if LName = NIL_NODE then
    Exit;
  LParent := T.Nodes[LName].Parent;
  if (LParent = NIL_NODE) or (Kind(LParent) <> nkTypeDecl) then
    Exit;
  Result := Sib(LName);
  while (Result <> NIL_NODE) and (Kind(Result) = nkGenericParams) do
    Result := Sib(Result);
end;

function TPasSemaTyper.CatFromNode(ADef: Integer): TSemaTypeCat;
begin
  case Kind(ADef) of
    nkRecordType, nkObjectType: Result := tcRecord;
    nkClassType: Result := tcClass;
    nkInterfaceType: Result := tcInterface;
    nkEnumType: Result := tcEnum;
    nkSetType: Result := tcSet;
    nkArrayType: Result := tcArray;
    nkPointerType: Result := tcPointer;
    nkClassOf: Result := tcClassOf;
    nkProcType: Result := tcProc;
    nkStringType: Result := tcString;
    nkFileType: Result := tcFile;
    nkSubrange: Result := tcInteger;
    nkIdent, nkMember, nkTypeArgs:   // alias to another named type
      Result := CatOf(Head(ADef));   // may be tcUnknown until target computed
  else
    Result := tcUnknown;
  end;
end;

procedure TPasSemaTyper.CategorizeTypes;
var
  LPass, LIdx, LDef: Integer;
  LChanged: Boolean;
  LCat: TSemaTypeCat;
begin
  for LPass := 1 to 8 do   // fixpoint for alias chains
  begin
    LChanged := False;
    for LIdx := 0 to M.SymCount - 1 do
      if (M.Symbols[LIdx].Kind = skType) and
         (M.Symbols[LIdx].TypeCat = tcUnknown) then
      begin
        LDef := TypeDefNode(LIdx);
        if LDef = NIL_NODE then
          Continue;
        LCat := CatFromNode(LDef);
        if LCat <> tcUnknown then
        begin
          M.Symbols[LIdx].TypeCat := LCat;
          LChanged := True;
        end;
      end;
    if not LChanged then
      Break;
  end;
end;

{ The category a type EXPRESSION node denotes — CatFromNode plus the named-type
  case, which CatFromNode delegates through Head. Separate because the ordinal
  checks below ask about type nodes written in a position (an array's index, a
  set's base), not about type symbols. }
function TPasSemaTyper.CatOfTypeNode(ANode: Integer): TSemaTypeCat;
begin
  if ANode = NIL_NODE then
    Result := tcUnknown
  else
    Result := CatFromNode(ANode);
end;

{ 2 §2.1.1 / §2.4.1: only an ORDINAL type may be an array's index type or a
  set's base type — dcc reports `E2001 Ordinal type required`. Same rule, same
  code, for the `for` counter's declared type, except that dcc has a dedicated
  message there: `E2032 For loop control variable must have ordinal type`.

  Verified against dcc32 37.0, and two of the answers are not guessable:

  - `Variant` is NOT ordinal in these positions (`array[Variant]`, `set of
    Variant`, `for V := 1 to 3` are all errors) even though it IS accepted as a
    `case` selector and as an `if` condition. Per-position, not per-type.
  - a SPARSE (explicitly-valued) enum is fine everywhere — as an index, a set
    base, a `case` selector and a `for` counter. §2.1.1/§2.2.4 claimed the
    opposite; the spec was corrected rather than the code, since dcc accepts
    `array[(spA = 0, spB = 10, spC = 99)]` and `set of` it without a murmur.

  Reports only a category that is DEFINITELY not ordinal. `tcUnknown` covers
  every cross-unit type (an imported enum's category is not computed intra-unit)
  and every generic parameter, so those stay silent — a missed report, never a
  false one. Records are included deliberately: an `Implicit` operator to an
  ordinal does NOT rescue any of these positions (dcc-verified for `case`, which
  is the one place a conversion could plausibly have applied). }
procedure TPasSemaTyper.CheckOrdinalTypePositions;
const
  // Everything that is not ordinal AND not "we do not know" — tcNil cannot
  // appear in a type position at all.
  CNotOrdinal = [tcFloat, tcString, tcPointer, tcSet, tcArray, tcRecord,
    tcClass, tcInterface, tcProc, tcClassOf, tcVariant, tcFile];
var
  LIdx, LChild, LLast, LSym, LType: Integer;
begin
  for LIdx := 0 to High(T.Nodes) do
    case Kind(LIdx) of
      nkArrayType:
        begin
          // Children are the index types followed by the element type — except
          // for `array of const`, which has no element child (Aux = 1). A
          // dynamic array's single child is the element type, so it has none of
          // its own to check.
          LLast := NIL_NODE;
          if T.Nodes[LIdx].Aux <> 1 then
          begin
            LLast := Child(LIdx);
            while (LLast <> NIL_NODE) and (Sib(LLast) <> NIL_NODE) do
              LLast := Sib(LLast);
          end;
          LChild := Child(LIdx);
          while (LChild <> NIL_NODE) and (LChild <> LLast) do
          begin
            if CatOfTypeNode(LChild) in CNotOrdinal then
              Diag('E2001', SE2001_OrdinalTypeRequired, LChild);
            LChild := Sib(LChild);
          end;
        end;
      nkSetType:
        if CatOfTypeNode(Child(LIdx)) in CNotOrdinal then
          Diag('E2001', SE2001_OrdinalTypeRequired, Child(LIdx));
      nkForStmt:
        begin
          // The counter: an inline `for var K` declaration's name, or an
          // ordinary reference. Its declared TYPE is what must be ordinal, so
          // an inline counter with no type annotation (inferred from the bound)
          // has nothing to check here.
          LChild := Child(LIdx);
          if LChild = NIL_NODE then
            Continue;
          if Kind(LChild) = nkInlineVar then
            LChild := Child(LChild);
          if (LChild = NIL_NODE) or (Kind(LChild) <> nkIdent) then
            Continue;
          LSym := M.RefMap[LChild];
          if LSym = NIL_SYM then
            Continue;
          LType := M.Symbols[LSym].TypeSym;
          if (LType <> NIL_SYM) and (CatOf(LType) in CNotOrdinal) then
            Diag('E2032', SE2032_ForCounterNotOrdinal, LChild);
        end;
    end;
end;

{ The two EXPRESSION positions of the same family (2 §2.2.2, §2.1.1), so this one
  runs after TypeNode has filled ExprType rather than beside CategorizeTypes:

  - an `if`/`while`/`until` condition must be Boolean — `E2012 Type of expression
    must be BOOLEAN`;
  - a `case` selector must be ordinal — `E2001`, the same code as the type
    positions above.

  The two exempt sets differ, and dcc32 37.0 is the only reason to know how:

  - `Variant` is accepted in BOTH a condition and a `case` selector, though it is
    an error as an array index, a set base or a `for` counter.
  - a RECORD is accepted as a condition when it has an `Implicit` operator to
    Boolean, and rejected when it has one to Integer — so whether a record
    condition is legal depends on its operators, which is not a question asked
    here. Records are therefore exempt in conditions and NOT exempt as `case`
    selectors, where dcc rejects one even with `Implicit` to an ordinal.
  - a PROCEDURAL type is exempt in both, because a parameterless function
    reference in a value position is CALLED: `if AShouldStop then` where the
    parameter is `reference to function: Boolean` is ordinary, correct code, and
    the type of the condition is the function's RESULT. Found the honest way —
    six such conditions in DevExpress's cxShellCommon lit up on the AVImark
    corpus the first time this check ran. In a TYPE position (an array index, a
    set base) a procedural type stays an error, since nothing is called there.

  Everything else is reported only when the category is definite; an unknown
  expression type (a cross-unit member, an untyped intrinsic result, a deref)
  says nothing. `Diag` additionally withholds anything inside an unresolved
  `with` body, where a binding — and so a type — is only a guess. }
procedure TPasSemaTyper.CheckConditionTypes;
const
  // Not Boolean and not "we do not know". tcRecord, tcVariant and tcProc are
  // absent deliberately — see the header.
  CNotBoolean = [tcInteger, tcFloat, tcChar, tcString, tcEnum, tcSet, tcArray,
    tcClass, tcInterface, tcClassOf, tcPointer, tcFile];
  // Not ordinal and not "we do not know". Variant is legal HERE; a record is
  // not, whatever operators it has.
  CNotSelector = [tcFloat, tcString, tcPointer, tcSet, tcArray, tcRecord,
    tcClass, tcInterface, tcClassOf, tcFile];
var
  LIdx, LCond: Integer;
begin
  for LIdx := 0 to High(T.Nodes) do
  begin
    LCond := NIL_NODE;
    case Kind(LIdx) of
      nkIfStmt, nkWhileStmt:
        LCond := Child(LIdx);
      nkRepeatStmt:
        // body block, then the `until` expression.
        if Child(LIdx) <> NIL_NODE then
          LCond := Sib(Child(LIdx));
      nkCaseStmt:
        begin
          LCond := Child(LIdx);
          if (LCond <> NIL_NODE) and (CatOf(M.ExprType[LCond]) in CNotSelector)
          then
            Diag('E2001', SE2001_OrdinalTypeRequired, LCond);
          Continue;
        end;
    end;
    if (LCond <> NIL_NODE) and (CatOf(M.ExprType[LCond]) in CNotBoolean) then
      Diag('E2012', SE2012_MustBeBoolean, LCond);
  end;
end;

{ The ordinal value of a LITERAL bound, and only of a literal: a decimal or `$`
  hex integer, either of those negated, or a one-character string literal. Named
  constants and `Ord(...)` expressions deliberately answer False — the set check
  below reports nothing it cannot compute exactly, and constant folding is not
  this pass's job. }
function TPasSemaTyper.OrdLiteral(ANode: Integer; out AValue: Int64): Boolean;
var
  LTxt: string;
  LNeg: Int64;
begin
  Result := False;
  AValue := 0;
  if ANode = NIL_NODE then
    Exit;
  if (Kind(ANode) = nkUnaryOp) and (OpText(ANode) = '-') then
  begin
    if OrdLiteral(Child(ANode), LNeg) then
    begin
      AValue := -LNeg;
      Result := True;
    end;
    Exit;
  end;
  LTxt := Txt(ANode);
  case Kind(ANode) of
    nkIntLit:
      begin
        // Digit separators are legal in a literal (B.5.1) and carry no value.
        LTxt := StringReplace(LTxt, '_', '', [rfReplaceAll]);
        if LTxt.StartsWith('$') then
          Result := TryStrToInt64('$' + LTxt.Substring(1), AValue)
        else
          Result := TryStrToInt64(LTxt, AValue);
      end;
    nkStrLit:
      // A single-character literal is a Char constant (B.6.1). Three characters
      // because the quotes are part of the text; '''' (an escaped quote) is
      // four and so is skipped, which costs nothing.
      if (Length(LTxt) = 3) and (LTxt[1] = '''') and (LTxt[3] = '''') then
      begin
        AValue := Ord(LTxt[2]);
        Result := True;
      end;
  end;
end;

{ 2 §2.4.1: a set's base type may have at most 256 values and those values must
  lie in `0..255` — one code for both, `E2028 Sets may have at most 256
  elements`, which dcc32 37.0 also uses for a NEGATIVE lower bound (`set of
  -5..5`) rather than a separate message.

  A 64-BIT ordinal base is the exception, and not a small one: dcc answers
  `E2001 Ordinal type required` there rather than E2028, even though `Int64` is
  perfectly ordinal. `NativeInt`/`NativeUInt` follow the TARGET — dcc32 says
  E2028 for `set of NativeInt` and dcc64 says E2001 for the same line — which is
  the one thing in this typer that needs to know the platform.

  `set of Char` (and `WideChar`) is only a WARNING, `W1050 WideChar reduced to
  byte char`, so it is passed over. The `*Bool` interop types are NOT: dcc
  reports E2028 for `set of ByteBool` although it is a single byte, while
  `set of Boolean` is fine.

  Reports only a cardinality it can compute exactly:

  - a named builtin, each answer probed against dcc (both compilers for the two
    platform-sized ones).
  - a subrange with two LITERAL bounds (`OrdLiteral`, so no folded constants).
  - an enum whose element values are literals or implicit, tracked in order so
    that `(a = 250, b, c, d, e, f)` is caught as well as an explicit 256. One
    non-literal explicit value abandons the whole enum.

  A named base type is followed one definition at a time (`TNeg = -5..5;
  set of TNeg`), which is also how an alias chain is handled. }
procedure TPasSemaTyper.CheckSetCardinality;
const
  // 0..255 exactly, so a set over the whole type is legal.
  CFits: array[0..2] of string = ('byte', 'boolean', 'ansichar');
  // More than 256 values but not 64-bit. `ShortInt` is here for its NEGATIVE
  // half, and the three `*Bool`s because dcc says so — `ByteBool` is one byte
  // and still E2028, while `Boolean` above is fine.
  CTooMany: array[0..11] of string = ('shortint', 'word', 'smallint', 'integer',
    'cardinal', 'longint', 'longword', 'fixedint', 'fixeduint',
    'bytebool', 'wordbool', 'longbool');
  // 64-bit ordinals, which dcc rejects with the OTHER code.
  CSixtyFour: array[0..1] of string = ('int64', 'uint64');

  // '' when the base is fine or not decidable here, else the code dcc reports.
  function BaseVerdict(ANode: Integer): string;
  var
    LDepth, LSym, LElem, LValue, LIdx: Integer;
    LLo, LHi, LCur: Int64;
    LName: string;
  begin
    Result := '';
    LDepth := 0;
    while (ANode <> NIL_NODE) and (LDepth < 8) do
    begin
      Inc(LDepth);
      case Kind(ANode) of
        nkIdent, nkMember, nkTypeArgs:
          begin
            LSym := Head(ANode);
            if LSym = NIL_SYM then
              Exit;
            LName := M.Symbols[LSym].NameLower;
            if M.Symbols[LSym].Kind = skBuiltinType then
            begin
              for LIdx := Low(CFits) to High(CFits) do
                if LName = CFits[LIdx] then
                  Exit;
              for LIdx := Low(CTooMany) to High(CTooMany) do
                if LName = CTooMany[LIdx] then
                  Exit('E2028');
              for LIdx := Low(CSixtyFour) to High(CSixtyFour) do
                if LName = CSixtyFour[LIdx] then
                  Exit('E2001');
              // The two platform-sized names are 64-bit only where the target
              // is, and dcc's code follows the width, not the spelling.
              if (LName = 'nativeint') or (LName = 'nativeuint') then
                if PlatformInfo(FPlatform).Is64Bit then
                  Exit('E2001')
                else
                  Exit('E2028');
              Exit;   // Char and WideChar are W1050, a warning: not ours
            end;
            if M.Symbols[LSym].Kind <> skType then
              Exit;
            ANode := TypeDefNode(LSym);   // follow the alias / named subrange
          end;
        nkSubrange:
          begin
            if not OrdLiteral(Child(ANode), LLo) then
              Exit;
            if not OrdLiteral(Sib(Child(ANode)), LHi) then
              Exit;
            if (LLo < 0) or (LHi > 255) then
              Exit('E2028')
            else
              Exit;
          end;
        nkEnumType:
          begin
            LCur := -1;
            LElem := Child(ANode);
            while LElem <> NIL_NODE do
            begin
              if Kind(LElem) = nkEnumValue then
              begin
                // nkEnumValue children: the name, then an optional value.
                LValue := Child(LElem);
                if LValue <> NIL_NODE then
                  LValue := Sib(LValue);
                if LValue = NIL_NODE then
                  Inc(LCur)
                else if not OrdLiteral(LValue, LCur) then
                  Exit;   // a named constant or an expression: give up
                if (LCur < 0) or (LCur > 255) then
                  Exit('E2028');
              end;
              LElem := Sib(LElem);
            end;
            Exit;
          end;
      else
        Exit;   // a non-ordinal base is E2001's business, not this one
      end;
    end;
  end;

var
  LIdx: Integer;
  LCode: string;
begin
  for LIdx := 0 to High(T.Nodes) do
    if Kind(LIdx) = nkSetType then
    begin
      LCode := BaseVerdict(Child(LIdx));
      if LCode = 'E2028' then
        Diag(LCode, SE2028_SetTooLarge, Child(LIdx))
      else if LCode = 'E2001' then
        Diag(LCode, SE2001_OrdinalTypeRequired, Child(LIdx));
    end;
end;

// Wider of two numeric type symbols (float wins over int; higher rank wins).
function TPasSemaTyper.WiderNum(A, B: Integer): Integer;
begin
  if (CatOf(A) = tcFloat) and (CatOf(B) <> tcFloat) then
    Exit(A);
  if (CatOf(B) = tcFloat) and (CatOf(A) <> tcFloat) then
    Exit(B);
  if RankOf(A) >= RankOf(B) then
    Result := A
  else
    Result := B;
end;

function TPasSemaTyper.TypeOfIdent(N: Integer): Integer;
var
  LSym: Integer;
begin
  LSym := M.RefMap[N];
  if LSym = NIL_SYM then
    Exit(NIL_SYM);   // external / unresolved
  case M.Symbols[LSym].Kind of
    skVar, skConst, skField, skParam, skRoutine, skProperty:
      Result := M.Symbols[LSym].TypeSym;   // value / result / property type
    skType, skBuiltinType:
      Result := LSym;                       // type designator (casts)
  else
    Result := NIL_SYM;
  end;
end;

function TPasSemaTyper.BinaryResult(N: Integer): Integer;
var
  LL, LR: Integer;
  LcL, LcR: TSemaTypeCat;
  LOp: string;

  function BothNum: Boolean;
  begin
    Result := (LcL in [tcInteger, tcFloat]) and (LcR in [tcInteger, tcFloat]);
  end;
  function BothInt: Boolean;
  begin
    Result := (LcL = tcInteger) and (LcR = tcInteger);
  end;
  function BothScalar: Boolean;
  begin
    Result := (LcL in [tcInteger, tcFloat, tcBoolean, tcChar, tcString]) and
              (LcR in [tcInteger, tcFloat, tcBoolean, tcChar, tcString]);
  end;
  function Bad: Integer;
  begin
    if BothScalar then
      Diag('E2015', SE2015_OperatorNotApplicable, N);
    Result := NIL_SYM;
  end;

begin
  LL := M.ExprType[Child(N)];
  LR := M.ExprType[Sib(Child(N))];
  Result := NIL_SYM;
  if (LL = NIL_SYM) or (LR = NIL_SYM) then
    Exit;
  LcL := CatOf(LL); LcR := CatOf(LR);
  LOp := OpText(N);

  if (LOp = '=') or (LOp = '<>') or (LOp = '<') or (LOp = '<=') or
     (LOp = '>') or (LOp = '>=') or (LOp = 'in') or (LOp = 'is') then
    Exit(Bool);

  if LOp = '+' then
  begin
    if BothNum then Exit(WiderNum(LL, LR));
    // char/string concatenation in any combination -> string
    if (LcL in [tcChar, tcString]) and (LcR in [tcChar, tcString]) then
      Exit(Str);
    Exit(Bad);
  end;
  if (LOp = '-') or (LOp = '*') then
  begin
    if BothNum then Exit(WiderNum(LL, LR));
    Exit(Bad);
  end;
  if LOp = '/' then
  begin
    if BothNum then Exit(Ext);
    Exit(Bad);
  end;
  if (LOp = 'div') or (LOp = 'mod') or (LOp = 'shl') or (LOp = 'shr') then
  begin
    if BothInt then Exit(WiderNum(LL, LR));
    Exit(Bad);
  end;
  if (LOp = 'and') or (LOp = 'or') or (LOp = 'xor') then
  begin
    if (LcL = tcBoolean) and (LcR = tcBoolean) then Exit(Bool);
    if BothInt then Exit(WiderNum(LL, LR));
    Exit(Bad);
  end;
end;

function TPasSemaTyper.UnaryResult(N: Integer): Integer;
var
  LO: Integer;
  LOp: string;
  LCat: TSemaTypeCat;
begin
  LO := M.ExprType[Child(N)];
  Result := NIL_SYM;
  LOp := OpText(N);
  if LOp = '@' then
    Exit(Ptr);
  if LO = NIL_SYM then
    Exit;
  LCat := CatOf(LO);
  if (LOp = '-') or (LOp = '+') then
  begin
    if LCat in [tcInteger, tcFloat] then Exit(LO);
    if LCat in [tcBoolean, tcChar, tcString] then
      Diag('E2015', SE2015_OperatorNotApplicable, N);
    Exit(NIL_SYM);
  end;
  if LOp = 'not' then
  begin
    if LCat in [tcBoolean, tcInteger] then Exit(LO);
    if LCat in [tcFloat, tcChar, tcString] then
      Diag('E2015', SE2015_OperatorNotApplicable, N);
    Exit(NIL_SYM);
  end;
end;

function TPasSemaTyper.ParamsOf(AScope: Integer): TArray<Integer>;
var
  LS: Integer;
begin
  Result := nil;
  if AScope = NIL_SCOPE then
    Exit;
  for LS in M.Scopes[AScope].Symbols do
    if M.Symbols[LS].Kind = skParam then
      Result := Result + [LS];
end;

function TPasSemaTyper.ArgCount(ACall: Integer): Integer;
var
  LArg: Integer;
begin
  Result := 0;
  LArg := Sib(Child(ACall));   // first child is the callee
  while LArg <> NIL_NODE do
  begin
    Inc(Result);
    LArg := Sib(LArg);
  end;
end;

// Sum a conservative match score of the call's args against a param scope.
function TPasSemaTyper.ScoreArgs(ACall, AScope: Integer): Integer;
var
  LParams: TArray<Integer>;
  LArg, LIdx, LAt, LPt: Integer;
begin
  Result := 0;
  LParams := ParamsOf(AScope);
  LArg := Sib(Child(ACall));
  LIdx := 0;
  while (LArg <> NIL_NODE) and (LIdx <= High(LParams)) do
  begin
    LAt := M.ExprType[LArg];
    LPt := M.Symbols[LParams[LIdx]].TypeSym;
    if (LAt <> NIL_SYM) and (LPt <> NIL_SYM) then
      if LAt = LPt then
        Inc(Result, 2)
      else if Assignable(LPt, LAt) then
        Inc(Result, 1);
    LArg := Sib(LArg);
    Inc(LIdx);
  end;
end;

// A `varargs` directive (cdecl external) accepts any number of trailing args.
function TPasSemaTyper.IsVarargs(AScope: Integer): Boolean;
var
  LRoutine, LChild: Integer;
begin
  Result := False;
  LRoutine := M.Scopes[AScope].OwnerNode;
  if LRoutine = NIL_NODE then
    Exit;
  LChild := Child(LRoutine);
  while LChild <> NIL_NODE do
  begin
    if (Kind(LChild) = nkDirective) and SameText(Txt(LChild), 'varargs') then
      Exit(True);
    LChild := Sib(LChild);
  end;
end;

// Pick the best overload for typing/navigation; emit an arg-count diagnostic
// only when it is unambiguous. Returns the chosen routine's result type.
{ The INTERFACE-section counterpart of an implementation-section routine head,
  or NIL_SYM.

  6.4: overloads declared in the IMPLEMENTATION section join the interface
  section's set for the same unit. They are separate SYMBOLS in separate scopes,
  deliberately -- chaining them would export an implementation-only overload to
  every importer -- so each consumer that reasons over "all the overloads" has
  to consult both chains. dcc-verified: a 3-parameter `Conv` in the interface
  and a 4-parameter `Conv` in the implementation, and both calls compile.
  Missing it makes the call to the INTERFACE one look short of arguments. }
function TPasSemaTyper.InterfaceCounterpart(AHead: Integer): Integer;
begin
  Result := NIL_SYM;
  if (AHead = NIL_SYM) or (M.Symbols[AHead].Scope = NIL_SCOPE) or
     (M.Scopes[M.Symbols[AHead].Scope].Kind <> sckImplementation) then
    Exit;
  Result := M.FindLocal(M.InterfaceScope, M.Symbols[AHead].NameLower);
  if (Result <> NIL_SYM) and (M.Symbols[Result].Kind <> skRoutine) then
    Result := NIL_SYM;
end;

function TPasSemaTyper.SelectOverload(ACall, AHead: Integer): Integer;
var
  LCand, LBest, LArgs, LReq, LTot, LScore, LBestScore: Integer;
  LMinReq, LMaxTot: Integer;
  LAnyFit, LAllHaveParams, LAnyVariadic, LVariadic: Boolean;
  LParams: TArray<Integer>;
  LP, LIfaceHead: Integer;
begin
  LArgs := ArgCount(ACall);
  LBest := AHead; LBestScore := -1;
  LAnyFit := False; LAllHaveParams := True; LAnyVariadic := False;
  LMinReq := MaxInt; LMaxTot := -1;

  LIfaceHead := InterfaceCounterpart(AHead);
  LCand := AHead;
  while LCand <> NIL_SYM do
  begin
    if M.Symbols[LCand].Kind <> skRoutine then
      Break;
    if M.Symbols[LCand].MemberScope = NIL_SCOPE then
      LAllHaveParams := False   // e.g. a builtin — no param info
    else
    begin
      LParams := ParamsOf(M.Symbols[LCand].MemberScope);
      LTot := Length(LParams);
      LReq := 0;
      for LP in LParams do
        if sfHasDefault in M.Symbols[LP].Flags then
          Break
        else
          Inc(LReq);
      LVariadic := IsVarargs(M.Symbols[LCand].MemberScope);
      if LVariadic then
        LAnyVariadic := True;
      if LReq < LMinReq then LMinReq := LReq;
      if LTot > LMaxTot then LMaxTot := LTot;
      if LVariadic or ((LArgs >= LReq) and (LArgs <= LTot)) then
      begin
        LAnyFit := True;
        LScore := ScoreArgs(ACall, M.Symbols[LCand].MemberScope);
        if LScore > LBestScore then
        begin
          LBestScore := LScore;
          LBest := LCand;
        end;
      end;
    end;
    LCand := M.Symbols[LCand].NextOverload;
    // 6.4: the interface section's overloads of the same name are part of the
    // set, and they are a separate chain in a separate scope — see
    // InterfaceCounterpart.
    if LCand = NIL_SYM then
    begin
      LCand := LIfaceHead;
      LIfaceHead := NIL_SYM;
    end;
  end;

  M.CallTarget.AddOrSetValue(ACall, LBest);

  // Arg-count is only reliable when the candidate set is complete:
  //  - a plain GLOBAL routine (methods/constructors are inherited/overloaded
  //    across the class hierarchy, which we don't model), and
  //  - the unit has NO `uses` (with imports, same-named overloads can live in
  //    another unit and Delphi merges them — we don't yet; cross-unit overload
  //    merging is a later slice). This keeps arity zero-false-positive.
  var LGlobal := (M.Scopes[M.Symbols[AHead].Scope].Kind in
    [sckUnit, sckImplementation]) and (Length(M.UsesList) = 0);

  // Deterministic arg-count diagnostic (independent of implicit rules).
  if LGlobal and LAllHaveParams and not LAnyVariadic and not LAnyFit and
     (LMaxTot >= 0) then
  begin
    if LArgs < LMinReq then
      Diag('E2035', SE2035_NotEnoughActualParams, ACall)
    else if LArgs > LMaxTot then
      Diag('E2034', SE2034_TooManyActualParams, ACall);
  end;

  // When NO local candidate admits the argument count, the real callee is
  // most likely a same-named overload in another unit (e.g. SysUtils calling
  // the 3-arg Winapi.Windows.GetEnvironmentVariable while declaring a 1-arg
  // one itself) — claiming the local head's result type would poison E2010.
  if LAllHaveParams and not LAnyVariadic and not LAnyFit and (LMaxTot >= 0) then
    Exit(NIL_SYM);

  // Same caution for argument TYPES: the unit imports something, and the
  // arity-fitting local candidates showed NO type evidence at all for a call
  // with typed arguments (best score 0 — not even one loosely-assignable
  // arg). dcc merges same-named overloads from used units into one candidate
  // set; we cannot in a pure per-unit pass — so don't claim the local result
  // type (a local `Pick(Boolean)` would mistype `Pick(11)` that really calls
  // an imported `Pick(Integer)`, poisoning E2010). The cross-unit pass
  // (CrossType) retypes the call against the properly MERGED set.
  if (Length(M.UsesList) > 0) and LAnyFit and (LBestScore = 0) then
  begin
    var LArg := Sib(Child(ACall));
    while LArg <> NIL_NODE do
    begin
      if M.ExprType[LArg] <> NIL_SYM then
        Exit(NIL_SYM);   // a typed arg matched nothing local — stay silent
      LArg := Sib(LArg);
    end;
  end;

  Result := M.Symbols[LBest].TypeSym;   // result type of the chosen overload
end;

function TPasSemaTyper.CallResult(N: Integer): Integer;
var
  LCallee, LHead: Integer;
begin
  LCallee := Child(N);
  Result := NIL_SYM;
  if LCallee = NIL_NODE then
    Exit;
  LHead := Head(LCallee);
  if LHead = NIL_SYM then
    Exit;
  case M.Symbols[LHead].Kind of
    skType, skBuiltinType:
      Result := LHead;                    // type cast T(x) -> T
    skRoutine:
      Result := SelectOverload(N, LHead); // choose overload + maybe arg-count
  end;
end;

function TPasSemaTyper.MemberResult(N: Integer): Integer;
var
  LName, LMem, LBaseTy, LScope: Integer;
begin
  Result := NIL_SYM;
  LName := Sib(Child(N));
  if LName = NIL_NODE then
    Exit;
  LMem := M.RefMap[LName];                   // resolved intra-unit member?
  if LMem = NIL_SYM then
  begin
    LBaseTy := M.ExprType[Child(N)];
    if LBaseTy = NIL_SYM then
      Exit;
    LScope := M.Symbols[LBaseTy].MemberScope;
    if LScope = NIL_SCOPE then
      Exit;
    LMem := M.FindLocal(LScope, LowerCase(Txt(LName)));
  end;
  if LMem <> NIL_SYM then
    Result := M.Symbols[LMem].TypeSym;
end;

procedure TPasSemaTyper.Diag(const ACode, AMsg: string; ANode: Integer);
var
  LVis: TPasVisibleToken;
  LFile, LLine, LCol, LTok: Integer;
begin
  // Inside a `with` whose target type could not be resolved intra-unit, a
  // name's binding — and therefore its TYPE — is only a guess: a cross-unit
  // member of the target outranks it and the project's with pass may rebind
  // it (see TPasSemaModel.WithUnopened). Type-checking a guess produces
  // confident nonsense, e.g. E2010 'Double' vs 'string' where the real member
  // is a string, so withhold every diagnostic over such a node instead.
  if M.InUnopenedWithBody(ANode) then
    Exit;
  LFile := 0; LLine := 0; LCol := 0;
  LTok := T.Nodes[ANode].FirstToken;
  if (LTok >= 0) and (LTok <= High(T.Source.Visible)) then
  begin
    LVis := T.Source.Visible[LTok];
    LFile := LVis.FileId;
    T.Source.Files[LVis.FileId].OffsetToLineCol(
      T.Source.Files[LVis.FileId].Tokens[LVis.TokenIndex].Start, LLine, LCol);
  end;
  M.AddDiag(MakeDiag(ACode, AMsg, ANode, LFile, LLine, LCol));
end;

// Conservative: only reject definite scalar mismatches.
function TPasSemaTyper.Assignable(ADst, ASrc: Integer): Boolean;
var
  D, S: TSemaTypeCat;
begin
  D := CatOf(ADst); S := CatOf(ASrc);
  if (D = tcUnknown) or (S = tcUnknown) then
    Exit(True);
  if S = tcNil then
    Exit(D in [tcPointer, tcClass, tcInterface, tcProc, tcClassOf, tcVariant,
      tcArray]);
  case D of
    tcString:  Result := S in [tcString, tcChar];
    tcInteger: Result := S = tcInteger;
    tcFloat:   Result := S in [tcFloat, tcInteger];
    tcBoolean: Result := S = tcBoolean;
    tcChar:    Result := S = tcChar;
  else
    Result := True;   // non-scalar destination -> allow (later phases)
  end;
  // Only a scalar source can turn this into a real rejection.
  if not Result and
     not (S in [tcInteger, tcFloat, tcBoolean, tcChar, tcString]) then
    Result := True;
end;

// True when N is a bare designator that resolved to a TYPE rather than to a
// value. Deliberately narrow: only an nkIdent bound straight to a type symbol,
// so a genuine cast (`Byte(I)`, an nkCall) is untouched.
function TPasSemaTyper.IsTypeNameOperand(N: Integer): Boolean;
var
  LSym: Integer;
begin
  Result := False;
  if Kind(N) <> nkIdent then
    Exit;
  LSym := M.RefMap[N];
  Result := (LSym <> NIL_SYM) and
    (M.Symbols[LSym].Kind in [skType, skBuiltinType]);
end;

procedure TPasSemaTyper.CheckAssign(N: Integer);
var
  LDst, LSrc: Integer;
begin
  LDst := Child(N);
  if LDst = NIL_NODE then
    Exit;
  LSrc := Sib(LDst);
  if LSrc = NIL_NODE then
    Exit;
  if (M.ExprType[LDst] = NIL_SYM) or (M.ExprType[LSrc] = NIL_SYM) then
    Exit;
  // A string literal is char-compatible (C := 'x'); don't flag it.
  if (CatOf(M.ExprType[LDst]) = tcChar) and (Kind(LSrc) = nkStrLit) then
    Exit;
  // An operand that resolved to a TYPE NAME is a mis-binding, not a type
  // mismatch, so this is the wrong diagnostic for it and the numbers say so:
  // dcc has its own errors for a type used as a value. It happens when a
  // MEMBER shadows a builtin type name — a class with `property Word: string`
  // makes bare `Word` in a descendant's method mean the property (dcc-verified),
  // but Phase 1 sees only the seeded type, because the member is INHERITED and
  // cross-unit and only the project's later pass can reach it. That pass cannot
  // unsay a diagnostic this one already emitted, so the judgement has to be
  // withheld here. 12 false E2010 on one real code base, all of them a member
  // named `Word`.
  if IsTypeNameOperand(LDst) or IsTypeNameOperand(LSrc) then
    Exit;
  if not Assignable(M.ExprType[LDst], M.ExprType[LSrc]) then
    Diag('E2010', Format(SE2010_IncompatibleTypes,
      [M.Symbols[M.ExprType[LDst]].Name, M.Symbols[M.ExprType[LSrc]].Name]),
      LSrc);
end;

function TPasSemaTyper.TypeNode(N: Integer): Integer;
var
  LChild, LThen: Integer;
begin
  if N = NIL_NODE then
    Exit(NIL_SYM);
  LChild := Child(N);
  while LChild <> NIL_NODE do   // type children first (bottom-up)
  begin
    TypeNode(LChild);
    LChild := Sib(LChild);
  end;

  case Kind(N) of
    nkIntLit: Result := Int;
    nkRealLit: Result := Ext;
    nkStrLit: Result := Str;
    nkCaretChar: Result := Chr;
    nkNilLit: Result := Nul;
    nkIdent: Result := TypeOfIdent(N);
    nkParen: Result := M.ExprType[Child(N)];
    nkUnaryOp: Result := UnaryResult(N);
    nkBinaryOp: Result := BinaryResult(N);
    nkCall: Result := CallResult(N);
    nkMember: Result := MemberResult(N);
    nkTypeArgs: Result := M.ExprType[Child(N)];
    nkInlineIf:
      begin
        LThen := Sib(Child(N));   // cond, then, else
        if LThen <> NIL_NODE then
          Result := M.ExprType[LThen]
        else
          Result := NIL_SYM;
      end;
  else
    Result := NIL_SYM;
  end;
  M.ExprType[N] := Result;

  if Kind(N) = nkAssign then
    CheckAssign(N);
end;

procedure TPasSemaTyper.Run;
var
  LIdx: Integer;
begin
  Int := NIL_SYM; Ext := NIL_SYM; Str := NIL_SYM; Chr := NIL_SYM;
  Bool := NIL_SYM; Ptr := NIL_SYM; Nul := NIL_SYM;
  for LIdx := 0 to M.SymCount - 1 do
    if M.Symbols[LIdx].Kind = skBuiltinType then
      if M.Symbols[LIdx].NameLower = 'integer' then Int := LIdx
      else if M.Symbols[LIdx].NameLower = 'extended' then Ext := LIdx
      else if M.Symbols[LIdx].NameLower = 'string' then Str := LIdx
      else if M.Symbols[LIdx].NameLower = 'char' then Chr := LIdx
      else if M.Symbols[LIdx].NameLower = 'boolean' then Bool := LIdx
      else if M.Symbols[LIdx].NameLower = 'pointer' then Ptr := LIdx
      else if M.Symbols[LIdx].NameLower = '_nil' then Nul := LIdx;

  CategorizeTypes;
  CheckOrdinalTypePositions;   // needs CategorizeTypes — see its own header
  CheckSetCardinality;         // needs RefMap only — see its own header
  TypeNode(0);
  CheckConditionTypes;         // needs ExprType — see its own header
end;

end.
