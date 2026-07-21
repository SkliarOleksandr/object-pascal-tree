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
  PasTree.Sema.Model;

type
  TPasSemaTyper = class
  private
    M: TPasSemaModel;
    T: TPasTree;
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
    procedure CheckAssign(N: Integer);
    function TypeNode(N: Integer): Integer;
    procedure Run;
  public
    class procedure Check(AModel: TPasSemaModel); static;
  end;

implementation

uses
  System.SysUtils,
  PasTree.Preprocessor,
  PasTree.Sema.Diagnostics;

class procedure TPasSemaTyper.Check(AModel: TPasSemaModel);
var
  LT: TPasSemaTyper;
begin
  LT := TPasSemaTyper.Create;
  try
    LT.M := AModel;
    LT.T := AModel.Tree;
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
function TPasSemaTyper.SelectOverload(ACall, AHead: Integer): Integer;
var
  LCand, LBest, LArgs, LReq, LTot, LScore, LBestScore: Integer;
  LMinReq, LMaxTot: Integer;
  LAnyFit, LAllHaveParams, LAnyVariadic, LVariadic: Boolean;
  LParams: TArray<Integer>;
  LP: Integer;
begin
  LArgs := ArgCount(ACall);
  LBest := AHead; LBestScore := -1;
  LAnyFit := False; LAllHaveParams := True; LAnyVariadic := False;
  LMinReq := MaxInt; LMaxTot := -1;

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
  TypeNode(0);
end;

end.
