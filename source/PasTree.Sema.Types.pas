unit PasTree.Sema.Types;

{
  PasTree semantics - Phase 3a type checker (intra-unit).

  Runs after name resolution: categorizes user-declared types, computes a type
  symbol for each expression node (ExprType), and emits E2010 (incompatible
  assignment) / E2015 (operator not applicable). Deliberately conservative -
  only definite scalar mismatches are flagged; anything with an unknown/external
  operand or a class/record/enum/set/array/pointer/variant operand (where
  inheritance or operator overloading could make it legal) is allowed. Overload
  ranking, argument-count and cross-unit typing are later slices.
}

interface

uses
  PasTree.Types,
  PasTree.Ast,
  PasTree.Platforms,
  PasTree.Sema.Model;

type
  { What dcc types a built-in operator expression as (4.2.1), as a rule over
    facts rather than over one typer's handles: the unit's typer
    (BinaryResult / UnaryResult) and the project's (OperatorResultX) each
    reduce an operand to TSemaOpFacts and map the answer to their own type
    symbols. The Phase-1 copy had drifted - the wider operand's type, so
    `B + B` over Bytes was a Byte, `Sg * Sg` a Single and Cardinal + Integer
    a Cardinal, and an alias of a builtin had no rank (audit A4-15, A4-14,
    D2-08).

    oaNone: no built-in rule applies (a record, class, Variant or mismatched
    pair - the typer's own business); oaUntyped: the operator applies but
    the type is not decided here (two string kinds dcc mixes); oaLeft /
    oaRight: the (canonical) left / right operand's own type. }
  TSemaOpAnswer = (oaNone, oaUntyped, oaBoolean, oaInteger, oaInt64, oaLeft,
    oaRight, oaExtended, oaCurrency, oaString, oaAnsiString, oaPointer,
    oaShortInt, oaByte, oaSmallInt, oaWord, oaCardinal, oaUInt64, oaComp,
    oaWideString, oaShortString);

  { The string kind of a text operand (4.2.1's text rows): stkUni string /
    UnicodeString, stkChar a Char / WideChar value, stkWide WideString,
    stkShort ShortString or `string[N]`, stkAnsi AnsiString, stkCodePage a
    code-page string (`UTF8String = type AnsiString(65001)`), stkRaw
    RawByteString, stkAnsiChar, stkLit a string literal, stkCharLit a
    one-character literal; stkNone anything else. }
  TSemaTextKind = (stkNone, stkUni, stkChar, stkWide, stkShort, stkAnsi,
    stkCodePage, stkRaw, stkAnsiChar, stkLit, stkCharLit);

  { What a `[...]` argument is passed to (CtorElemFit): an open array of T,
    a dynamic array of T - `TArray<T>`, a named `array of T` - or `array of
    const`. }
  TSemaCtorTarget = (ctOpenArray, ctDynArray, ctArrayOfConst);

  { One operand, after its aliases are chased to the builtin they name - a
    distinct `type X` of a number too, whose storage is its base's (audit
    A3-32, B4-08). Rank: that builtin's NumRank (8-bit 1 .. 64-bit 4 for an
    integer, Single 1 .. Extended 3 for a real), 0 for a rankless type - a
    subrange, a type not bound here. Unsigned: Byte, Word, Cardinal,
    LongWord, UInt64, NativeUInt. Curr / Comp: a Currency / Comp VALUE (a
    variable, a typed constant). IntConst: an integer constant of value
    IntValue (a literal, signed or not, or a true constant naming one) - it
    adapts to the other operand when it fits (A3-31). RealLit: a real
    literal or a true constant naming one; CurrLit: one dcc64 reads as
    Currency (3.1.3); CurrNamed: that constant is a NAME (`KCur + 1` is
    Currency where `1.5 + 1` is Extended). Text: the string kind of a text
    operand. SetCtor: the operand is a `[...]`, which has no type of its own
    (E3-43). }
  TSemaOpFacts = record
    Cat: TSemaTypeCat;
    Rank: Byte;
    Unsigned, Curr, Comp, IntConst, RealLit, CurrLit, CurrNamed: Boolean;
    IntValue: Int64;
    SetCtor: Boolean;
    Text: TSemaTextKind;
  end;

  { What Ord, Pred / Succ and Low / High read of an ordinal argument
    (4.11.4; OrdAnswer, OrdStepAnswer). Builtin: the NameLower of the
    builtin it is stored as (aliases and distinct `type X` of a number
    chased), '' for an enumeration or subrange of its own; Rank that
    builtin's NumRank. IsConst: a constant expression dcc folds
    (ConstExprKind) - Ord / Hi / Lo / Swap of one is Integer. HasRange:
    Lo..Hi is the ordinal range of the enumeration or subrange type. }
  TSemaOrdFacts = record
    Cat: TSemaTypeCat;
    Builtin: string;
    Rank: Byte;
    IsConst, HasRange: Boolean;
    Lo, Hi: Int64;
  end;

  { The ordinal value a NAME node of the tree stands for - an enumeration
    value, a true constant, True / False - for OrdinalNodeValue; each typer
    supplies its own binding lookup. ADepth guards a cycle of constants. }
  TSemaOrdNameValue = reference to function(ANode, ADepth: Integer;
    out AValue: Int64): Boolean;

  { How dcc reads a constant expression (B.10, 3.2.1; dcc64 37.0, PasTree
    local/const-intrinsics-2026-11) - ConstExprKind's answer.
    - sckNone: not one - `const X = <it>` is E2026: a variable, a typed
      constant, `@X`, an inline `if`, Copy, Assigned, `Length(S)`.
    - sckValue: folded, and read by its VALUE as a literal is: an overload
      takes the narrowest parameter holding it (`FI(Low(Byte))` the ShortInt
      one), a `[...]` element ranks below `array of const` (6.3.1).
    - sckTyped: folded, but its outermost operation names a type and it is a
      value of that type there: a typecast (`Integer(5)`, `Byte(300)`,
      `Pointer(nil)`), Default(T), Ptr(X), `nil`, and a true constant whose
      value is one - `J([Integer(5)])` takes `TArray<Integer>` over `array
      of const`, `FI(Byte(300))` the Byte overload.
    Ord, Hi, Lo and Swap of either folded kind are Integer (4.11.4). }
  TSemaConstKind = (sckNone, sckValue, sckTyped);

  { What ConstExprKind reads of one node, from the typer that asks. Role:
    scrConst a true constant or an enumeration value (Typed: its value is
    sckTyped); scrType a type name; scrIntrinsic a seeded intrinsic routine,
    Intrinsic its NameLower; scrValue anything else with a value - a
    variable, a typed constant, a parameter, an expression; scrOther what the
    typer cannot tell. The type of the value, or the type named: Cat its
    category; RunTime a long string or a dynamic array, whose High and Length
    are run-time values; OpenArray an open-array parameter (SizeOf too);
    StaticArray a static array, whose Length is a constant. }
  TSemaConstRole = (scrOther, scrConst, scrType, scrIntrinsic, scrValue);
  TSemaConstFacts = record
    Role: TSemaConstRole;
    Intrinsic: string;
    Cat: TSemaTypeCat;
    Typed, RunTime, OpenArray, StaticArray: Boolean;
  end;
  TSemaConstFactsFunc = reference to function(ANode, ADepth: Integer):
    TSemaConstFacts;

  // The type, as one of THIS model's symbols, of an ident the model itself no
  // longer binds (its binding lives in ExtRefMap) - NIL_SYM when it cannot be
  // named in this model's terms. Supplied by the project for recheck mode.
  TSemaExtTypeFunc = reference to function(ANode: Integer): Integer;
  // Did the project's with pass type every target of with statement AWith?
  TSemaWithTypedFunc = reference to function(AWith: Integer): Boolean;

  TPasSemaTyper = class
  private
    M: TPasSemaModel;
    T: TPasTree;
    // Only ONE rule needs it: a 64-bit ordinal `set of` base is E2001 while a
    // 32-bit one is E2028, and `NativeInt` is whichever the target says
    // (dcc32 E2028, dcc64 E2001 for the same source).
    FPlatform: TPasPlatform;
    Int, Ext, Str, Chr, Bool, Ptr, Nul: Integer;   // cached builtin type syms
    // The rest of what the intrinsic result rules (IntrinsicResult) name.
    I64, NInt, AStr, SStr: Integer;
    // What the operator facts (OpFacts) and the intrinsic rules compare a
    // canonical builtin with - ids, not names (audit A4-14).
    NUInt, Cur, Comp, Card, LWord, AChr, WChr, UStr: Integer;
    Byt, ShInt, Wrd, SmInt, U64, WStr: Integer;
    FIs64: Boolean;   // the target's pointer width, read once (audit C2-15)
    function Kind(N: Integer): TPasNodeKind; inline;
    function Child(N: Integer): Integer; inline;
    function Sib(N: Integer): Integer; inline;
    function Txt(N: Integer): string; inline;
    function OpKind(N: Integer): TPasTokenKind;
    function CatOf(ASym: Integer): TSemaTypeCat;
    function RankOf(ASym: Integer): Byte;
    function Head(N: Integer): Integer;
    function TypeDefNode(ASym: Integer): Integer;
    function CatOfSubrangeBound(ALo: Integer): TSemaTypeCat;
    function CatFromNode(ADef: Integer): TSemaTypeCat;
    procedure CategorizeTypes;
    function CatOfTypeNode(ANode: Integer): TSemaTypeCat;
    procedure CheckOrdinalTypePositions;
    procedure CheckConditionTypes;
    function OrdLiteral(ANode: Integer; out AValue: Int64): Boolean;
    procedure CheckSetCardinality;
    function StorageBase(ASym: Integer): Integer;
    function OpFacts(ASym, ANode: Integer): TSemaOpFacts;
    function OpSym(AAns: TSemaOpAnswer; ALeft, ARight: Integer;
      AKeepOwn: Boolean): Integer;
    function TypeOfIdent(N: Integer): Integer;
    function InlineIfResult(N: Integer): Integer;
    function BinaryResult(N: Integer): Integer;
    function UnaryResult(N: Integer): Integer;
    function CallResult(N: Integer): Integer;
    function ProcTypeResult(ASym: Integer): Integer;
    function IntrinsicResult(ACall, AHead: Integer): Integer;
    function WidenOrdinal(ASym: Integer): Integer;
    function OrdNameValue: TSemaOrdNameValue;
    function ConstFacts: TSemaConstFactsFunc;
    function IsConstArg(ANode: Integer): Boolean;
    function IsConstExpr(ANode: Integer): Boolean;
    function OrdFacts(ANode, ASym: Integer): TSemaOrdFacts;
    function OrdStep(ASym: Integer): Integer;
    function ArrayDefOf(ASym: Integer): Integer;
    function IsDynArrayDef(ADef: Integer): Boolean;
    function ArrayBoundType(ADef: Integer): Integer;
    function ParamsOf(AScope: Integer): TArray<Integer>;
    function ArgListTruncated(ACall: Integer): Boolean;
    function WeakAliasEnd(ASym: Integer): Integer;
    function IsProcDesignator(N: Integer): Boolean;
    function ClassRefTarget(ASym: Integer): Integer;
    function IsValuePos(N: Integer): Boolean;
    function DeclaresConversion(ASym: Integer; AExplicitToo: Boolean): Boolean;
    function ScoreArgs(ACall: Integer; const AParams: TArray<Integer>): Integer;
    { One argument against the parameter AParam: AArg its node, or NIL_NODE
      for a comparison an nkAmbiguous stands for (no node shape to read);
      AAt its type. On the doubled scale of CtorElemFit: 4 exact, 2
      assignable, 0 no evidence, -1 rejected - a `[...]`'s odd steps
      between. }
    function ScoreArg(AArg, AAt, AParam: Integer): Integer;
    // ScoreArg's rule against the type APt, on ArgFitCanonX's scale: 2
    // exact, 1 assignable (the element of an array a `[...]`'s element is
    // scored against too).
    function ScoreArgAs(AArg, AAt, APt: Integer): Integer;
    // ScoreArg for an open-array parameter - see the implementation.
    function OpenArrayScore(AArg, AAt, ADef: Integer): Integer;
    // ScoreArg for a `[...]` - see the implementation.
    function CtorScore(ACtor, AElem: Integer;
      ATarget: TSemaCtorTarget): Integer;
    // The type symbol an element type node names - see the implementation.
    function ElemTypeSym(ANode: Integer): Integer;
    { The type of the comparison `ALeft < ARight` / `ALeft > ARight` an
      nkAmbiguous stands for: Boolean once both operands are typed. }
    function CompareType(ALeft, ARight: Integer): Integer;

    function SelectOverload(ACall, AHead: Integer): Integer;
    function MemberResult(N: Integer): Integer;
    procedure Diag(const ACode, AMsg: string; ANode: Integer);
    function Assignable(ADst, ASrc: Integer): Boolean;
    function InterfaceCounterpart(AHead: Integer): Integer;
    function IsTypeNameOperand(N: Integer): Boolean;
    procedure CheckAssign(N: Integer);
    function CharCompatibleSource(N: Integer): Boolean;
    procedure CheckCondition(AStmt: Integer);
    function ExprRoot(N: Integer): Integer;
    function HoldsPastStructName(ARoot: Integer): Boolean;
    function TypeNode(N: Integer): Integer;
    procedure Prepare;
    procedure Run;
  private
    // Set while the walks Diag may withhold for PastStructRecheck run (the
    // TypeNode walk and the condition check - what a recheck re-runs).
    FPastWithhold: Boolean;
    // RECHECK mode (see RecheckWithBodies): the with-body suppression in Diag
    // is off, and an ident this model no longer binds (RefMap cleared by the
    // project's commit, ExtRefMap holding the cross-unit member) is typed
    // through the host's callback instead of read as "unknown".
    FRecheck: Boolean;
    FExtTypeOf: TSemaExtTypeFunc;
    // A recheck's node set: the three whole-tree sweeps visit only these
    // (nil = every node). See RecheckWithBodies.
    FSweepOnly: TArray<Boolean>;
    function SweepKind(AIdx: Integer): TPasNodeKind;
    procedure CheckCountersIn;
  public
    // Shared with the project pass (CheckCalls): one arity rule, one place.
    class function ArityFits(AArgs, AReq, ATot: Integer;
      ATrailing: Boolean): Boolean; static;
    class procedure Check(AModel: TPasSemaModel;
      APlatform: TPasPlatform = pfWin32); static;
    class procedure RecheckWithBodies(AModel: TPasSemaModel;
      APlatform: TPasPlatform; const AExtTypeOf: TSemaExtTypeFunc;
      const ATargetsTyped: TSemaWithTypedFunc = nil); static;
  end;

{ Overload scoring rules shared by the unit's typer (ScoreArgs) and the
  project's cross-unit selection (ScoreCandidate), so one call scores alike
  whichever pass decides it.

  StrLitUnits: the UTF-16 units of the nkStrLit ANode, counted over EVERY
  visible token of it - the parser joins `#13#10` and `'a'#0` into one node,
  whose NodeText is only the first piece (audit A4-07) - and capped at 2;
  -1 when a piece cannot be read (a multiline string). A caret char is one
  unit, a `#` code above $FFFF two (a surrogate pair).

  IsOneCharLiteralNode: the literal is ONE character: 'x', '''', #65, #$41,
  ^M. dcc gives such a literal the type Char (B.6.1), and it converts to a
  string too. Both passes type every literal `string`, so it scored the
  string overload of `P(C: Char)` / `P(const S: string)` exact and the Char
  one nothing - and dcc picks the Char one. A Char parameter scores it 3,
  above the string's exact 2, which leaves every pair without a Char overload
  as it was (`P(PChar)` / `P(string)` still picks the string one).

  IsCharLiteralExpr: the same constant written through parentheses or as
  both branches of an inline `if` - `('x')`, `if B then 'a' else 'b'` (or
  `^M`): dcc still takes it as a Char (6.3.1, local/probe-b32 P1), where
  both typers read the parenthesis's or the then-branch's `string` (A4-10).

  PeelParens: ANode with its enclosing parentheses taken off.

  IsScalarToReference: an argument of a scalar category (integer, float,
  Boolean, Char, string) cannot be passed to a class, interface or
  class-reference parameter at all - not assignable, no conversion - so the
  candidate is rejected rather than scored "assignable". The conservative
  rule allowed every non-scalar destination, and an Integer argument tied
  `F(const A: IFoo)` with `F(A: TId)` (`TId = type Integer`): the first
  declared won, and its sibling's calls were listed as its references. A
  record parameter is not in the rule: a string constant converts to TGUID. }
function StrLitUnits(const ATree: TPasTree; ANode: Integer): Integer;
function IsOneCharLiteralNode(const ATree: TPasTree; ANode: Integer): Boolean;
function IsCharLiteralExpr(const ATree: TPasTree; ANode: Integer): Boolean;
function PeelParens(const ATree: TPasTree; ANode: Integer): Integer;
function IsScalarToReference(ADst, ASrc: TSemaTypeCat): Boolean;

{ The overload-scoring rejections both scorers apply - what makes a candidate
  OUT rather than a weak fit (6.3.1). The two passes had diverged (audit
  A4-08): the project's ScoreCandidate had learned these, the unit's
  ScoreArgs had not, so one call scored differently by which pass decided it.

  ArgShapeRejects - decided at the argument NODE: an anonymous-method
  literal or a procedure designator (ACoreKind nkAnonMethod / AIsProcDesig)
  is a procedural value and nothing else, so a parameter of another category
  rejects it (`Make(1, procedure begin end)` / `Make(1, Noop)` take the
  `reference to procedure` overload over `B: Boolean = False`, probe-b32 P1);
  a `[...]` (nkSetCtor) rejects what IsBracketToScalar names. A generic
  parameter, a Variant and an unknown category never reject.

  ArgCatRejects - decided on the two categories: IsScalarToReference,
  ScalarEnumMismatch, or an ordinal / float / Char value for an array.

  ArgStructRejects - two types already known NOT to be the same type: two
  records, or an array against a record, class or interface, when no side
  that could convert declares an Implicit / Explicit operator (AParConv,
  AArgConv). }
function ArgShapeRejects(ACoreKind: TPasNodeKind; AIsProcDesig: Boolean;
  AParCat: TSemaTypeCat; AParIsGenericParam: Boolean): Boolean;
function ArgCatRejects(AParCat, AArgCat: TSemaTypeCat): Boolean;
function ArgStructRejects(AParCat, AArgCat: TSemaTypeCat;
  AParConv, AArgConv: Boolean): Boolean;
{ Whether ArgStructRejects' answer for these categories can turn on a
  conversion operator at all: when not, it is False whatever AParConv and
  AArgConv say, and the operators need not be looked for - a member search
  per argument of every candidate scored (perf audit 2026-10, C11). }
function ArgStructNeedsConv(AParCat, AArgCat: TSemaTypeCat): Boolean;

{ An argument against an OPEN-ARRAY parameter (6.2.6), which names no type
  of its own: the rule both scorers apply to what each knows of the
  argument (TPasSemaProject.OpenArrFitX, TPasSemaTyper.OpenArrayScore), on
  the overload scores' doubled scale (CtorElemFit). The element type of
  `array of const` is System.TVarRec - it takes what an `array of TVarRec`
  takes. A `[...]` has a rule of its own (CtorElemFit).
  - an ARRAY, static or dynamic, whose element is the parameter's element
    type exactly (AElemFit 1) fits, at 2: below the exact match (4) of a
    parameter of the argument's own type, which a `TArray<string>` argument
    takes over `array of string` in either declaration order. An array of
    another element (AElemFit -1) is out - elements are not converted:
    `TArray<TComponent>` for `array of TObject` and `TArray<string>` for
    `array of const` are E2010, so `string.Join(',', A)` calls
    TStringHelper's `array of string` overload, declared after the `array
    of const` one. AElemFit 0: the element is not known. An array whose
    type is written inline - `var A: array of string`, an open-array
    parameter passed on - is such an array too (AArgCat tcArray), its
    element read off its declaration;
  - one value of the element type (AIsElem) is a one-element array when it
    is a VARIABLE, but a constant is E2192 and any other expression E2010:
    no evidence, as before (`P(1)` beside `P(X: Double)` stays Double's);
  - one value of another type is out: a Byte variable for `array of
    Integer`, a TComponent one for `array of TObject`, a string or an
    Integer one for `array of const` (E2010);
  - an argument whose type is not known (AArgCat tcUnknown) or `nil`:
    no evidence.
  dcc64 37.0, 2026-11-02 (spec 6.2.6, 6.3.1; local/compl-c1c2-2026-11/fc,
  fd). }
function OpenArrayArgFit(AArgCat: TSemaTypeCat; AIsElem: Boolean;
  AElemFit: Integer): Integer;

{ One ELEMENT of a `[...]` against what the brackets are passed to (ATarget:
  an open array, a dynamic array, `array of const`) - the rule both scorers
  apply to what each knows of it (TPasSemaProject.CtorFitX,
  TPasSemaTyper.CtorScore), the brackets fitting as their WORST element
  does: dcc ranks the overloads by that one, however many others fit better
  (`[B, B, B, B, I]` takes `array of Integer` over `array of Byte`), and an
  element out puts the overload out. A range in the brackets makes them a
  set, which no array takes; `[]` gives no evidence (6.3.1). On the overload
  scores' DOUBLED scale - an argument's ArgFitCanonX 3 / 2 / 1 / 0 / -1
  counts 6 / 4 / 2 / 0 / -1 in a candidate's score - whose odd steps are the
  dynamic array's:
  - `array of const` takes an element of any type a TVarRec holds at 2,
    just below an exact match - an integer, a Char, a Boolean, a float, a
    string, a pointer, an object, a class reference, an interface, a
    Variant, a dynamic array, `nil` (AElemCat). An enumeration, a record, a
    set and a static array (AStaticArray) are E2150, out; an element of no
    known type, a procedural value and a file give no evidence;
  - an open array of T: AValueFit, the element's score as a VALUE argument
    of T (the scorers' one rule: 2 exact, 3 a one-character literal for
    Char, 1 assignable, 0 no evidence, -1 out), doubled, with two
    corrections. A Char value (ACharValue: a one-character literal, a Char
    variable, constant or cast) fits a Char element best, at 6, and a string
    (UnicodeString) one next, at 4 - as exactly as its own type, against
    `array of const` (AParChar, AParString: T is Char, string). And a merely
    assignable element gives no evidence: dcc ranks `array of const` above
    every conversion, and the kinds of conversion against each other, which
    the scorers do not;
  - a dynamic array of T takes what the open array of T takes, each element
    a step below it: an exact one at 3 (a Char value 5 for Char), above
    `array of const` and below the open array. An exact CONSTANT other than
    a string or a character (AConstant: a number, True, a true constant, an
    enumeration value, a class name, an operator over constants) dcc ranks
    below `array of const` and above a conversion; here it gives no
    evidence, as a conversion does: the scorers type every integer literal
    Integer, so `[5000000000]` or `[1]` beside `array of Byte` would take
    `TArray<Integer>` (dcc: `TArray<Int64>`, `array of Byte`).
  So `array of T` beats `array of const` when every element is exact for T -
  `string.Join(',', ['a', S])` calls TStringHelper's `array of string`
  overload, declared after the `array of const` one - and loses to it when
  one is not (`[S, I]`, `[1, 'b']`, a Byte for `array of Integer`, an
  AnsiString for `array of string`); `S.Split([','])` takes `array of Char`,
  `S.Split([', '])` and `S.Split([',', 'ab'])` `array of string`; `['a', S]`
  takes `TArray<string>` over `array of const` and `array of string` over
  `TArray<string>`, `[I]` `TArray<Integer>` over `array of const` and
  `[1, 2]` `array of const` over `TArray<Integer>`. dcc64 37.0, 2026-11-02
  (spec 6.3.1; local/compl-c1c2-2026-11/fd, fe). }
function CtorElemFit(ATarget: TSemaCtorTarget; AElemCat: TSemaTypeCat;
  AStaticArray, ACharValue, AConstant, AParChar, AParString: Boolean;
  AValueFit: Integer): Integer;

{ The present arguments of the nkCall ACall - its children after the callee,
  the nkMissing slot a trailing comma leaves (`F(1, 2,)`, ParseArgList) not
  counted - and whether that slot is there (ATrailing). The one count every
  arity test reads with TPasSemaTyper.ArityFits (6.2.5; audit B3-32 /
  D2-15: the project scorer counted the slot as an argument). An nkAmbiguous
  argument counts as the arguments it stands for (AModel.AmbigArgCount), and
  the count is -1 while one of them is unknown: no arity can be judged then.
  ACall may itself be an nkAmbiguous read as a generic call - its one
  argument is the tail (CallFirstArg). }
function CallArgCount(const AModel: TPasSemaModel; ACall: Integer;
  out ATrailing: Boolean): Integer;
{ The first argument node of ACall: the one after the callee of an nkCall, the
  parenthesised tail of an nkAmbiguous read as a generic call. }
function CallFirstArg(const ATree: TPasTree; ACall: Integer): Integer;

{ Category-level assignability, the one rule of TPasSemaTyper.Assignable and
  TPasSemaProject.XAssignableX: conservative - only a definite scalar
  mismatch is False. `nil` goes to the pointer-like categories, and to a
  record only when the record declares a `class operator Implicit`
  (ARecordTakesNil): `Q := nil` with Implicit(Value: Pointer) compiles
  (probe-b32 P1, audit A4-11; the RTL's TResourceValue does it). }
function CatAssignable(D, S: TSemaTypeCat; ARecordTakesNil: Boolean): Boolean;

{ ScalarEnumMismatch: an enumeration argument for an integer, float,
  Boolean or Char parameter, or one of those for an enumeration parameter -
  no implicit conversion either way, so the candidate is rejected (6.3.1;
  dcc64 37.0, local/probe-b31 O3: `Seek(0, soCurrent)` against
  Seek(Longint; Word) and Seek(Int64; TSeekOrigin)). }
function ScalarEnumMismatch(ADst, ASrc: TSemaTypeCat): Boolean;

{ A `[...]` argument (nkSetCtor: a set constructor, an open array constructor
  or a dynamic array constant, B.9) is a set or an array and nothing else: a
  parameter of these categories cannot take it, so the candidate is rejected
  rather than scored nothing. `M(1, 'x', ['a'])` tied `M(A: Integer; const S:
  string = ''; const Id: string = '')` with `M(A: Integer; const S: string;
  const L: array of string)` - the bracket scored neither - and the first
  declared won: the second's calls were the first's references and the second
  read "none found" (pastree-mcp's task pilot on the client group, F6.2).
  dcc32 37.0 probed: `[...]` and `[]` pick the open array, the set or the
  dynamic array overload in either declaration order, and a string parameter
  alone is E2010. A record (an Implicit operator) and a Variant are left out,
  as is anything unknown. }
function IsBracketToScalar(ADst: TSemaTypeCat): Boolean;

{ The 4.2.1 rule table, both typers' one copy (dcc32 / dcc64 37.0,
  local/probe-b36 M1 M2 N1):
  - an integer constant takes the other operand's type when its value fits
    it (`C + 1`, `C and $FF` over a Cardinal are Cardinal), otherwise its
    own: ShortInt for -128..127, Byte to 255, SmallInt down to -32768,
    Integer, Cardinal, Int64 (`C + (-1)` is Int64, `B and 300` Integer);
  - `+ - * div mod`: at least Integer; a 64-bit operand gives Int64, UInt64
    when an unsigned one is 64-bit; a 32-bit unsigned operand with a signed
    one of any width is Int64 (`C + Sh`), with an unsigned one Cardinal;
  - `and or xor`: the narrowest of ShortInt / Byte / SmallInt / Word /
    Integer covering both narrow operands (`Sh and B` SmallInt), Cardinal
    beside any 32-bit unsigned, UInt64 beside a 64-bit unsigned;
  - `shl shr`: the left operand's type, at least Integer;
  - unary `-`: at least Integer, Int64 of a Cardinal; `not` keeps its
    operand's type (the caller keeps a distinct type there);
  - reals: Extended, except on a 64-bit target (AIs64), where a Currency
    value operand makes Currency, Comp with integers or Comp makes Comp,
    two Currency-shaped real constants added or subtracted make Currency (a
    named one with an integer too), and
    `/` is Currency for Currency over an integer or a real value, or an
    integer over Currency, Comp for an integer over Comp;
  - `+` over text: string when either side is UniText, the one type of two
    equal string operands (ASameType), AnsiString for AnsiString with
    AnsiChar. Sets and pointer arithmetic keep the set / pointer operand; a
    comparison is Boolean. AUnary: AR is not read.
  An integer result names the builtin of its shape, never an operand's own
  type (`NI + I` is Int64 on Win64). }
function OperatorAnswer(AOp: TPasTokenKind; AUnary: Boolean;
  const AL, AR: TSemaOpFacts; ASameType, AIs64: Boolean): TSemaOpAnswer;

{ `+` over two text operands (4.2.1, dcc32 / dcc64 37.0, local/probe-b36 M2
  N1; audit A3-34): a literal takes the other operand's string type when
  that is one (`A + 'x'` AnsiString, `WS + 'x'` WideString, `U8 + 'x'`
  UTF8String; with ShortString AnsiString, with a Char string); then string
  when a side is string or Char, WideString when a side is WideString, the
  type of two equal operands (ShortString with itself AnsiString, AnsiChar
  with itself ShortString), RawByteString beside an Ansi kind the left
  operand's, AnsiString among ShortString / AnsiString / AnsiChar, string
  among Ansi kinds of different code pages. Concat folds it left to right. }
function TextJoinAnswer(const AL, AR: TSemaOpFacts;
  ASameType: Boolean): TSemaOpAnswer;

{ The type of `if C then L else R` from its branches (5.4.1, local/probe-b36
  M2 N1; audit E3-19): one type stays itself (a distinct one too);
  integers meet in the narrowest of ShortInt / Byte / SmallInt / Word /
  Integer / Cardinal / Int64 / UInt64 covering both, a constant adapting
  (`if C then B else W` Word, `C else I` Int64, `1 else C` Cardinal); two
  reals Extended, Currency on a 64-bit target with a Currency value; text
  string when a side is string, Char or a literal - a Char value with a
  one-character literal stays Char - WideString beside WideString. oaNone
  for a pair dcc rejects or this does not decide (an integer with a real);
  `nil`, classes and set constructors are the typer's. }
function InlineIfAnswer(const AL, AR: TSemaOpFacts;
  ASameType, AIs64: Boolean): TSemaOpAnswer;

{ The value of integer constant ANode of ATree - a decimal, `$` hex or `%`
  binary literal with digit separators, under parentheses and signs. False
  for anything else, and for a literal above High(Int64). }
function IntLiteralValue(const ATree: TPasTree; ANode: Integer;
  out AValue: Int64): Boolean;

{ The real literal under ANode's parentheses and signs, NIL_NODE if none. }
function RealLiteralNode(const ATree: TPasTree; ANode: Integer): Integer;

{ The builtin type name ('char', 'string', 'integer', 'currency', ...) dcc
  gives literal ANode of ATree where a type is inferred from it (3.1.3,
  TPasSemaProject.LiteralTypeX documents the rules); AIs64: the target's
  Extended is Double-sized, so a short real literal is Currency. '' when
  unreadable. }
function PasLiteralTypeName(const ATree: TPasTree; ANode: Integer;
  ANegated, AIs64: Boolean): string;

{ The ordinal value of constant ANode of ATree: an integer literal under
  parentheses and signs, a one-character literal ('a', #65, #$41, ^A), or a
  name AName resolves (an enumeration value, a true constant). False for
  anything else, and past ADepth 8. }
function OrdinalNodeValue(const ATree: TPasTree; ANode, ADepth: Integer;
  const AName: TSemaOrdNameValue; out AValue: Int64): Boolean;

{ Is expression ANode of ATree a constant dcc folds, and how is it read
  (TSemaConstKind)? The one rule both typers ask through AFacts (TPasSemaTyper
  .IsConstArg, TPasSemaProject.IsConstArgX), from dcc64 37.0's answers
  (local/const-intrinsics-2026-11): a literal, `nil`, a true constant, an
  enumeration value; an operator or a set constructor over constants (not
  `@X`); a typecast of a constant, but a string or character one to a pointer
  type (`PChar('abc')` is E2026); a call of a seeded intrinsic by its
  TPasIntrinsicFold - `Low(X)`, `SizeOf(X)`, `High` of a type or of a value
  its type alone gives (`High(I)`, a static array, a short string), `Length`
  of a string constant or a static array, `Ord` / `Succ` / `Hi` / ... of
  constants (`Ord(High(Char))`, `Swap(Byte(5))`), `Sqr` of an integer one,
  `Default` but of a record, a static array or a Variant. sckNone past
  ADepth 8 (a chain of constants). }
function ConstExprKind(const ATree: TPasTree; ANode, ADepth: Integer;
  const AFacts: TSemaConstFactsFunc): TSemaConstKind;

{ The ordinal of enumeration element AElem (an nkEnumValue node of ATree):
  its explicit value, else one past the previous element's (the first is
  0). dcc keeps an explicit value's low 32 bits, signed (2.2.4). }
function EnumElemValue(const ATree: TPasTree; AElem, ADepth: Integer;
  const AName: TSemaOrdNameValue; out AValue: Int64): Boolean;

{ The ordinal range of type definition ADef of ATree - an nkEnumType (its
  elements' least and greatest values) or an nkSubrange (its bounds). }
function OrdinalDefRange(const ATree: TPasTree; ADef: Integer;
  const AName: TSemaOrdNameValue; out ALo, AHi: Int64): Boolean;

{ Ord's result (4.11.4; dcc32 / dcc64 37.0, local/probe-b38 T64 T32 Q2): a
  constant argument is Integer; a builtin integer keeps its type (oaLeft)
  unless 64-bit (Integer); Char / WideChar is Word, AnsiChar Byte; Boolean
  ShortInt, ByteBool Byte, WordBool Word, LongBool Integer; an enumeration
  or subrange the narrowest of ShortInt, Byte, SmallInt, Word, Integer,
  Cardinal holding its range (`0..1000` SmallInt, `0..60000` Word); Integer
  where the range is not known. }
function OrdAnswer(const AF: TSemaOrdFacts): TSemaOpAnswer;

{ The integer rule of Pred / Succ / Low / High (4.11.4): a builtin narrower
  than 32 bits is Integer, a 32- or 64-bit one keeps its type (oaLeft:
  `Succ(C)` Cardinal, `High(UInt64)` UInt64); a subrange is Integer, Int64
  when its range is past Integer's. }
function OrdStepAnswer(const AF: TSemaOrdFacts): TSemaOpAnswer;

implementation

uses
  System.SysUtils,
  System.Generics.Collections,
  PasTree.Preprocessor,
  PasTree.Sema.Builtins,
  PasTree.Sema.Diagnostics;

function StrLitUnits(const ATree: TPasTree; ANode: Integer): Integer;
var
  LTxt: string;
  LTok, LIdx: Integer;
  LU: UInt64;
  LSkipLetter: Boolean;
begin
  Result := 0;
  LSkipLetter := False;
  for LTok := ATree.Nodes[ANode].FirstToken to ATree.Nodes[ANode].LastToken do
  begin
    if (LTok < 0) or (LTok > High(ATree.Source.Visible)) then
      Exit(-1);
    if LSkipLetter then
    begin
      LSkipLetter := False;
      Continue;
    end;
    LTxt := ATree.Source.VisibleText(LTok);
    if LTxt = '' then
      Exit(-1);
    if LTxt[1] = '^' then
    begin
      // Caret char (B.6.2): `^[` is one token, `^M` is `^` plus a one-letter
      // identifier token - one unit either way.
      LSkipLetter := Length(LTxt) = 1;
      Inc(Result);
    end
    else if LTxt[1] = '#' then
    begin
      // #nnn / #$hh / #%bbb - one unit unless the value needs a surrogate
      // pair.
      LTxt := StringReplace(LTxt, '_', '', [rfReplaceAll]);
      LTxt := Copy(LTxt, 2, MaxInt);
      if (LTxt <> '') and (LTxt[1] = '%') then
        Inc(Result)   // a binary escape is at most 8 bits in practice
      else if TryStrToUInt64(LTxt, LU) then
      begin
        if LU > $FFFF then
          Inc(Result, 2)
        else
          Inc(Result);
      end
      else
        Exit(-1);
    end
    else if (Length(LTxt) >= 2) and (LTxt[1] = '''') then
    begin
      // Quoted: each character one unit, a doubled quote one unit.
      LIdx := 2;
      while LIdx < Length(LTxt) do
      begin
        if LTxt[LIdx] = '''' then
          Inc(LIdx);   // the escape's second quote
        Inc(Result);
        Inc(LIdx);
      end;
    end
    else
      Exit(-1);   // a multiline string or anything unexpected
    if Result > 1 then
      Exit(2);
  end;
end;

function IsOneCharLiteralNode(const ATree: TPasTree; ANode: Integer): Boolean;
begin
  Result := (ANode <> NIL_NODE) and (ATree.Nodes[ANode].Kind = nkStrLit) and
    (StrLitUnits(ATree, ANode) = 1);
end;

function PeelParens(const ATree: TPasTree; ANode: Integer): Integer;
begin
  Result := ANode;
  while (Result <> NIL_NODE) and (ATree.Nodes[Result].Kind = nkParen) and
        (ATree.Nodes[Result].FirstChild <> NIL_NODE) do
    Result := ATree.Nodes[Result].FirstChild;
end;

function IsCharLiteralExpr(const ATree: TPasTree; ANode: Integer): Boolean;
var
  LThen, LElse: Integer;
begin
  ANode := PeelParens(ATree, ANode);
  if ANode = NIL_NODE then
    Exit(False);
  case ATree.Nodes[ANode].Kind of
    nkCaretChar:
      Result := True;
    nkStrLit:
      Result := StrLitUnits(ATree, ANode) = 1;
    nkInlineIf:
      begin
        // cond, then, else - each branch a Char constant.
        LThen := ATree.Nodes[ANode].FirstChild;
        if LThen <> NIL_NODE then
          LThen := ATree.Nodes[LThen].NextSibling;
        if LThen = NIL_NODE then
          Exit(False);
        LElse := ATree.Nodes[LThen].NextSibling;
        Result := (LElse <> NIL_NODE) and IsCharLiteralExpr(ATree, LThen) and
          IsCharLiteralExpr(ATree, LElse);
      end;
  else
    Result := False;
  end;
end;

function IsScalarToReference(ADst, ASrc: TSemaTypeCat): Boolean;
begin
  Result := (ASrc in [tcInteger, tcFloat, tcBoolean, tcChar, tcString]) and
    (ADst in [tcClass, tcInterface, tcClassOf]);
end;

function ArgShapeRejects(ACoreKind: TPasNodeKind; AIsProcDesig: Boolean;
  AParCat: TSemaTypeCat; AParIsGenericParam: Boolean): Boolean;
begin
  Result := False;
  if AParIsGenericParam then
    Exit;
  if ((ACoreKind = nkAnonMethod) or AIsProcDesig) and
     not (AParCat in [tcProc, tcVariant, tcUnknown]) then
    Exit(True);
  if (ACoreKind = nkSetCtor) and IsBracketToScalar(AParCat) then
    Exit(True);
end;

function ArgCatRejects(AParCat, AArgCat: TSemaTypeCat): Boolean;
begin
  // ...and an ordinal, float or Char value where an array is wanted: no
  // conversion makes `B[0]` a TBytes, so `Write(B[0], N)` takes TStream's
  // untyped `Write(const Buffer; Count)` (local/probe-b33 O1: P(1) beside
  // P(const A: array of Integer) calls P(Double)). A string is left out.
  Result := IsScalarToReference(AParCat, AArgCat) or
    ScalarEnumMismatch(AParCat, AArgCat) or
    ((AParCat = tcArray) and
     (AArgCat in [tcInteger, tcFloat, tcBoolean, tcChar, tcEnum]));
end;

function ArgStructRejects(AParCat, AArgCat: TSemaTypeCat;
  AParConv, AArgConv: Boolean): Boolean;
begin
  // Two DIFFERENT record types: distinct records are not assignable to one
  // another unless a conversion operator - a member, so it can be looked
  // for - makes them so.
  if (AParCat = tcRecord) and (AArgCat = tcRecord) then
    Exit(not AParConv and not AArgConv);
  // An array against a record, class or interface, either way round.
  Result := ((AParCat = tcArray) and
             (AArgCat in [tcRecord, tcClass, tcInterface]) and not AArgConv) or
            ((AArgCat = tcArray) and
             (AParCat in [tcRecord, tcClass, tcInterface]) and not AParConv);
end;

function OpenArrayArgFit(AArgCat: TSemaTypeCat; AIsElem: Boolean;
  AElemFit: Integer): Integer;
begin
  Result := 0;
  if AIsElem or (AArgCat in [tcUnknown, tcNil]) then
    Exit;
  if AArgCat = tcArray then
  begin
    if AElemFit > 0 then
      Exit(2);
    Exit(AElemFit);
  end;
  Result := -1;
end;

function CtorElemFit(ATarget: TSemaCtorTarget; AElemCat: TSemaTypeCat;
  AStaticArray, ACharValue, AConstant, AParChar, AParString: Boolean;
  AValueFit: Integer): Integer;
begin
  if ATarget = ctArrayOfConst then
  begin
    case AElemCat of
      tcUnknown, tcProc, tcFile:
        Result := 0;
      tcEnum, tcRecord, tcSet:
        Result := -1;
    else
      if AStaticArray then
        Result := -1
      else
        Result := 2;
    end;
    Exit;
  end;
  if ACharValue and AParChar then
    Result := 6
  else if ACharValue and AParString then
    Result := 4
  else if AValueFit < 0 then
    Exit(-1)
  else if AValueFit < 2 then
    Exit(0)   // a conversion, or nothing known
  else if (ATarget = ctDynArray) and AConstant and
          not (AElemCat in [tcString, tcChar]) then
    Exit(0)   // below `array of const`; see above
  else
    Result := 4;
  if ATarget = ctDynArray then
    Dec(Result);
end;

function ArgStructNeedsConv(AParCat, AArgCat: TSemaTypeCat): Boolean;
begin
  // ArgStructRejects' three cases, without the operators.
  Result := ((AParCat = tcRecord) and (AArgCat = tcRecord)) or
            ((AParCat = tcArray) and
             (AArgCat in [tcRecord, tcClass, tcInterface])) or
            ((AArgCat = tcArray) and
             (AParCat in [tcRecord, tcClass, tcInterface]));
end;

function CallFirstArg(const ATree: TPasTree; ACall: Integer): Integer;
begin
  if ATree.Nodes[ACall].Kind = nkAmbiguous then
    Exit(ATree.LastChild(ACall));
  Result := ATree.Nodes[ACall].FirstChild;   // the callee
  if Result <> NIL_NODE then
    Result := ATree.Nodes[Result].NextSibling;
end;

function CallArgCount(const AModel: TPasSemaModel; ACall: Integer;
  out ATrailing: Boolean): Integer;
var
  LArg, LN: Integer;
begin
  Result := 0;
  ATrailing := False;
  LArg := CallFirstArg(AModel.Tree, ACall);
  while LArg <> NIL_NODE do
  begin
    case AModel.Tree.Nodes[LArg].Kind of
      nkMissing:
        ATrailing := True;
      nkAmbiguous:
        begin
          LN := AModel.AmbigArgCount(LArg);
          if LN < 0 then
            Exit(-1);
          Inc(Result, LN);
        end;
    else
      Inc(Result);
    end;
    LArg := AModel.Tree.Nodes[LArg].NextSibling;
  end;
end;

function CatAssignable(D, S: TSemaTypeCat; ARecordTakesNil: Boolean): Boolean;
begin
  if (D = tcUnknown) or (S = tcUnknown) then
    Exit(True);
  if S = tcNil then
    Exit((D in [tcPointer, tcClass, tcInterface, tcProc, tcClassOf, tcVariant,
      tcArray]) or ((D = tcRecord) and ARecordTakesNil));
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

function ScalarEnumMismatch(ADst, ASrc: TSemaTypeCat): Boolean;
const
  CScalar = [tcInteger, tcFloat, tcBoolean, tcChar];
begin
  Result := ((ASrc = tcEnum) and (ADst in CScalar)) or
    ((ADst = tcEnum) and (ASrc in CScalar));
end;

function IsBracketToScalar(ADst: TSemaTypeCat): Boolean;
begin
  Result := ADst in [tcInteger, tcFloat, tcBoolean, tcChar, tcString,
    tcPointer, tcNil, tcEnum, tcClass, tcInterface, tcProc, tcClassOf, tcFile];
end;

// Does AValue fit the integer type of rank ARank / signedness AUns?
function OpFits(AValue: Int64; ARank: Integer; AUns: Boolean): Boolean;
begin
  case ARank of
    1:
      if AUns then
        Result := (AValue >= 0) and (AValue <= High(Byte))
      else
        Result := (AValue >= Low(ShortInt)) and (AValue <= High(ShortInt));
    2:
      if AUns then
        Result := (AValue >= 0) and (AValue <= High(Word))
      else
        Result := (AValue >= Low(SmallInt)) and (AValue <= High(SmallInt));
    3:
      if AUns then
        Result := (AValue >= 0) and (AValue <= High(Cardinal))
      else
        Result := (AValue >= Low(Integer)) and (AValue <= High(Integer));
  else
    Result := not AUns or (AValue >= 0);
  end;
end;

// The (rank, signedness) integer operand AF computes in beside AOther: a
// rankless type is an Integer; a constant takes AOther's shape when its
// value fits it, else the shape of its value.
procedure OpShape(const AF, AOther: TSemaOpFacts; out ARank: Integer;
  out AUns: Boolean);
var
  LV: Int64;
begin
  ARank := AF.Rank;
  AUns := AF.Unsigned;
  if ARank = 0 then
  begin
    ARank := 3;
    AUns := False;
  end;
  if not AF.IntConst then
    Exit;
  if (AOther.Cat = tcInteger) and not AOther.IntConst then
  begin
    OpShape(AOther, AF, ARank, AUns);
    if OpFits(AF.IntValue, ARank, AUns) then
      Exit;
  end;
  LV := AF.IntValue;
  AUns := False;
  if (LV >= Low(ShortInt)) and (LV <= High(ShortInt)) then
    ARank := 1
  else if (LV >= 0) and (LV <= High(Byte)) then
  begin
    ARank := 1;
    AUns := True;
  end
  else if (LV >= Low(SmallInt)) and (LV < 0) then
    ARank := 2
  else if (LV >= Low(Integer)) and (LV <= High(Integer)) then
    ARank := 3
  else if (LV >= 0) and (LV <= High(Cardinal)) then
  begin
    ARank := 3;
    AUns := True;
  end
  else
    ARank := 4;
end;

function OperatorAnswer(AOp: TPasTokenKind; AUnary: Boolean;
  const AL, AR: TSemaOpFacts; ASameType, AIs64: Boolean): TSemaOpAnswer;

  // The builtin of integer shape (ARank, AUns) - never an operand's own
  // name: dcc says Int64 for `NI + I` on Win64 and for `Lg + I` on the LP64
  // targets, where LongInt is a type of its own (local/probe-b37 L).
  function IntAns(ARank: Integer; AUns: Boolean; ARL, ARR: Integer;
    ALU, ARU: Boolean): TSemaOpAnswer;
  begin
    case ARank of
      1:
        if AUns then Result := oaByte else Result := oaShortInt;
      2:
        if AUns then Result := oaWord else Result := oaSmallInt;
      3:
        if AUns then Result := oaCardinal else Result := oaInteger;
    else
      if AUns then Result := oaUInt64 else Result := oaInt64;
    end;
  end;

  function IsInt(const AF: TSemaOpFacts): Boolean;
  begin
    Result := AF.Cat = tcInteger;
  end;

  // A real result (audit A3-33, B4-07, B4-09).
  function RealAns: TSemaOpAnswer;
  begin
    Result := oaExtended;
    if not AIs64 then
      Exit;
    if AUnary then
    begin
      if AL.Curr or AL.CurrLit then
        Result := oaCurrency
      else if AL.Comp then
        Result := oaComp;
    end
    else if AOp = tkSlash then
    begin
      if AL.Curr and not AR.Curr then
      begin
        if IsInt(AR) or ((AR.Cat = tcFloat) and not AR.RealLit) then
          Result := oaCurrency;
      end
      else if AR.Curr and not AL.Curr then
      begin
        if IsInt(AL) then
          Result := oaCurrency;
      end
      else if AR.Comp and IsInt(AL) then
        Result := oaComp;
    end
    else if AL.Curr or AR.Curr then
      Result := oaCurrency
    else if AL.Comp or AR.Comp then
    begin
      if (AL.Comp or IsInt(AL)) and (AR.Comp or IsInt(AR)) then
        Result := oaComp;
    end
    else if AOp in [tkPlus, tkMinus] then
    begin
      // Two Currency-shaped constants add as Currency, and so does a NAMED
      // one with an integer; a literal with an integer is Extended
      // (local/probe-b36 C2, C3).
      if (AL.CurrLit and AR.CurrLit) or
         (AL.CurrLit and AL.CurrNamed and IsInt(AR)) or
         (AR.CurrLit and AR.CurrNamed and IsInt(AL)) then
        Result := oaCurrency;
    end;
  end;

  function Arith: TSemaOpAnswer;
  var
    LRL, LRR: Integer;
    LLU, LRU: Boolean;
  begin
    if (AL.Cat = tcFloat) or (AR.Cat = tcFloat) then
      Exit(RealAns);
    OpShape(AL, AR, LRL, LLU);
    OpShape(AR, AL, LRR, LRU);
    if (LRL < 3) and (LRR < 3) then
      Exit(oaInteger);
    if (LRL = 4) or (LRR = 4) then
      Exit(IntAns(4, ((LRL = 4) and LLU) or ((LRR = 4) and LRU), LRL, LRR,
        LLU, LRU));
    // A 32-bit unsigned operand beside a signed one meets it in Int64.
    if LLU <> LRU then
    begin
      if ((LRL = 3) and LLU) or ((LRR = 3) and LRU) then
        Exit(oaInt64);
      Exit(IntAns(3, False, LRL, LRR, LLU, LRU));
    end;
    Result := IntAns(3, LLU, LRL, LRR, LLU, LRU);
  end;

  function Bitwise: TSemaOpAnswer;
  const
    CLo: array[0..4] of Int64 = (Low(ShortInt), 0, Low(SmallInt), 0,
      Low(Integer));
    CHi: array[0..4] of Int64 = (High(ShortInt), High(Byte), High(SmallInt),
      High(Word), High(Integer));
    CRank: array[0..4] of Integer = (1, 1, 2, 2, 3);
    CUns: array[0..4] of Boolean = (False, True, False, True, False);
  var
    LRL, LRR, LIdx: Integer;
    LLU, LRU: Boolean;
    LLo, LHi: Int64;

    procedure Cover(ARank: Integer; AUns: Boolean);
    var
      LI: Integer;
    begin
      for LI := 0 to 4 do
        if (CRank[LI] = ARank) and (CUns[LI] = AUns) then
        begin
          if CLo[LI] < LLo then
            LLo := CLo[LI];
          if CHi[LI] > LHi then
            LHi := CHi[LI];
        end;
    end;

  begin
    OpShape(AL, AR, LRL, LLU);
    OpShape(AR, AL, LRR, LRU);
    if (LRL = 4) or (LRR = 4) then
      Exit(IntAns(4, ((LRL = 4) and LLU) or ((LRR = 4) and LRU), LRL, LRR,
        LLU, LRU));
    if (LRL = 3) or (LRR = 3) then
      Exit(IntAns(3, ((LRL = 3) and LLU) or ((LRR = 3) and LRU), LRL, LRR,
        LLU, LRU));
    LLo := 0;
    LHi := 0;
    Cover(LRL, LLU);
    Cover(LRR, LRU);
    for LIdx := 0 to 4 do
      if (CLo[LIdx] <= LLo) and (CHi[LIdx] >= LHi) then
        Exit(IntAns(CRank[LIdx], CUns[LIdx], LRL, LRR, LLU, LRU));
    Result := oaInteger;
  end;

  // `shl` / `shr` and unary `-` / `+`: the left operand alone decides.
  function LeftOnly(ANegate: Boolean): TSemaOpAnswer;
  var
    LRL: Integer;
    LLU: Boolean;
  begin
    OpShape(AL, Default(TSemaOpFacts), LRL, LLU);
    if LRL < 3 then
      Result := oaInteger
    else if ANegate and (LRL = 3) and LLU then
      Result := oaInt64     // `-C` of a Cardinal (B4-06)
    else
      Result := IntAns(LRL, LLU, LRL, 0, LLU, False);
  end;

var
  LNum: Boolean;
begin
  Result := oaNone;
  if AUnary then
  begin
    case AOp of
      tkMinus, tkPlus:
        case AL.Cat of
          tcInteger: Result := LeftOnly(AOp = tkMinus);
          tcFloat: Result := RealAns;
        end;
      tkNot:
        case AL.Cat of
          tcBoolean: Result := oaBoolean;
          tcInteger: Result := oaLeft;   // `not B` over a Byte is a Byte
        end;
      tkAt:
        Result := oaPointer;
    end;
    Exit;
  end;
  if AOp in [tkEqual, tkNotEqual, tkLess, tkLessEqual, tkGreater,
     tkGreaterEqual, tkIn, tkIs] then
    Exit(oaBoolean);
  LNum := (AL.Cat in [tcInteger, tcFloat]) and (AR.Cat in [tcInteger, tcFloat]);
  case AOp of
    tkPlus:
      if LNum then
        Result := Arith
      else if (AL.Cat in [tcChar, tcString]) and
              (AR.Cat in [tcChar, tcString]) then
        Result := TextJoinAnswer(AL, AR, ASameType)
      else if (AL.Cat = tcSet) and ((AR.Cat = tcSet) or AR.SetCtor) then
        Result := oaLeft
      else if (AL.Cat = tcPointer) and (AR.Cat = tcInteger) then
        Result := oaLeft
      else if (AL.Cat = tcInteger) and (AR.Cat = tcPointer) then
        Result := oaRight;
    tkMinus, tkStar:
      if LNum then
        Result := Arith
      else if (AL.Cat = tcSet) and ((AR.Cat = tcSet) or AR.SetCtor) then
        Result := oaLeft   // `St - [e1]` is St's type; `[e1] + St` is not
      else if (AOp = tkMinus) and (AL.Cat = tcPointer) and
              (AR.Cat = tcInteger) then
        Result := oaLeft;
    tkSlash:
      if LNum then
        Result := RealAns;
    tkDiv, tkMod:
      if IsInt(AL) and IsInt(AR) then
        Result := Arith;
    tkShl, tkShr:
      if IsInt(AL) and IsInt(AR) then
        Result := LeftOnly(False);
    tkAnd, tkOr, tkXor:
      if (AL.Cat = tcBoolean) and (AR.Cat = tcBoolean) then
        Result := oaBoolean
      else if IsInt(AL) and IsInt(AR) then
        Result := Bitwise;
  end;
end;

function TextJoinAnswer(const AL, AR: TSemaOpFacts;
  ASameType: Boolean): TSemaOpAnswer;
const
  CLit = [stkLit, stkCharLit];
  CAnsiKinds = [stkShort, stkAnsi, stkCodePage, stkRaw, stkAnsiChar];
var
  LOther: TSemaTextKind;
  LOwn: TSemaOpAnswer;
begin
  if (AL.Text in CLit) or (AR.Text in CLit) then
  begin
    if (AL.Text in CLit) and (AR.Text in CLit) then
      Exit(oaString);
    if AL.Text in CLit then
    begin
      LOther := AR.Text;
      LOwn := oaRight;
    end
    else
    begin
      LOther := AL.Text;
      LOwn := oaLeft;
    end;
    case LOther of
      stkUni, stkChar, stkAnsiChar: Result := oaString;
      stkAnsi, stkWide, stkCodePage, stkRaw: Result := LOwn;
      stkShort: Result := oaAnsiString;
    else
      Result := oaUntyped;
    end;
    Exit;
  end;
  if (AL.Text in [stkUni, stkChar]) or (AR.Text in [stkUni, stkChar]) then
    Exit(oaString);
  if (AL.Text = stkWide) or (AR.Text = stkWide) then
    Exit(oaWideString);
  if ASameType then
    case AL.Text of
      stkShort: Exit(oaAnsiString);
      stkAnsiChar: Exit(oaShortString);
      stkAnsi, stkCodePage, stkRaw: Exit(oaLeft);
    else
      Exit(oaUntyped);
    end;
  if not (AL.Text in CAnsiKinds) or not (AR.Text in CAnsiKinds) then
    Exit(oaUntyped);
  // RawByteString takes the other Ansi kind on its left (`U8 + RB` UTF8String,
  // `RB + A` RawByteString).
  if (AL.Text = stkRaw) or (AR.Text = stkRaw) then
  begin
    if AL.Text in [stkAnsi, stkCodePage, stkRaw] then
      Exit(oaLeft);
    Exit(oaUntyped);
  end;
  if (AL.Text in [stkShort, stkAnsi, stkAnsiChar]) and
     (AR.Text in [stkShort, stkAnsi, stkAnsiChar]) then
    Exit(oaAnsiString);
  // Two code pages (`U8 + A`, `SS + U8`, `U8 + AC`) meet in string.
  Result := oaString;
end;

function InlineIfAnswer(const AL, AR: TSemaOpFacts;
  ASameType, AIs64: Boolean): TSemaOpAnswer;
const
  CLo: array[0..6] of Int64 = (Low(ShortInt), 0, Low(SmallInt), 0,
    Low(Integer), 0, Low(Int64));
  CHi: array[0..6] of Int64 = (High(ShortInt), High(Byte), High(SmallInt),
    High(Word), High(Integer), High(Cardinal), High(Int64));
  CAns: array[0..6] of TSemaOpAnswer = (oaShortInt, oaByte, oaSmallInt,
    oaWord, oaInteger, oaCardinal, oaInt64);
  CRank: array[0..6] of Integer = (1, 1, 2, 2, 3, 3, 4);
  CUns: array[0..6] of Boolean = (False, True, False, True, False, True,
    False);
var
  LRL, LRR, LIdx: Integer;
  LLU, LRU: Boolean;
  LLo, LHi: Int64;

  procedure Cover(ARank: Integer; AUns: Boolean);
  var
    LI: Integer;
  begin
    for LI := 0 to 6 do
      if (CRank[LI] = ARank) and (CUns[LI] = AUns) then
      begin
        if CLo[LI] < LLo then
          LLo := CLo[LI];
        if CHi[LI] > LHi then
          LHi := CHi[LI];
      end;
  end;

begin
  if ASameType then
    Exit(oaLeft);
  if (AL.Cat in [tcChar, tcString]) and (AR.Cat in [tcChar, tcString]) then
  begin
    if (AL.Text = stkChar) and (AR.Text = stkCharLit) then
      Exit(oaLeft);
    if (AR.Text = stkChar) and (AL.Text = stkCharLit) then
      Exit(oaRight);
    if (AL.Text in [stkUni, stkChar, stkLit, stkCharLit]) or
       (AR.Text in [stkUni, stkChar, stkLit, stkCharLit]) then
      Exit(oaString);
    if (AL.Text = stkWide) or (AR.Text = stkWide) then
      Exit(oaWideString);
    Exit(oaNone);
  end;
  if (AL.Cat = tcInteger) and (AR.Cat = tcInteger) then
  begin
    OpShape(AL, AR, LRL, LLU);
    OpShape(AR, AL, LRR, LRU);
    if ((LRL = 4) and LLU) or ((LRR = 4) and LRU) then
      Exit(oaUInt64);
    LLo := 0;
    LHi := 0;
    Cover(LRL, LLU);
    Cover(LRR, LRU);
    for LIdx := 0 to 6 do
      if (CLo[LIdx] <= LLo) and (CHi[LIdx] >= LHi) then
        Exit(CAns[LIdx]);
    Exit(oaUInt64);
  end;
  if (AL.Cat = tcFloat) and (AR.Cat = tcFloat) then
  begin
    if AIs64 and (AL.Curr or AR.Curr) then
      Exit(oaCurrency);
    Exit(oaExtended);
  end;
  Result := oaNone;
end;

function IntLiteralValue(const ATree: TPasTree; ANode: Integer;
  out AValue: Int64): Boolean;
var
  LTxt: string;
  LU: UInt64;
  LIdx: Integer;
begin
  Result := False;
  AValue := 0;
  ANode := PeelParens(ATree, ANode);
  if ANode = NIL_NODE then
    Exit;
  if (ATree.Nodes[ANode].Kind = nkUnaryOp) and
     (ATree.Nodes[ANode].Aux >= 0) and
     (ATree.Nodes[ANode].Aux <= High(ATree.Source.Visible)) and
     (ATree.Source.VisibleKind(ATree.Nodes[ANode].Aux) in
      [tkMinus, tkPlus]) then
  begin
    if not IntLiteralValue(ATree, ATree.Nodes[ANode].FirstChild, AValue) then
      Exit;
    if ATree.Source.VisibleKind(ATree.Nodes[ANode].Aux) = tkMinus then
      AValue := -AValue;
    Exit(True);
  end;
  if ATree.Nodes[ANode].Kind <> nkIntLit then
    Exit;
  LTxt := StringReplace(ATree.NodeText(ANode), '_', '', [rfReplaceAll]);
  if LTxt = '' then
    Exit;
  if LTxt[1] = '%' then
  begin
    LU := 0;
    for LIdx := 2 to Length(LTxt) do
    begin
      if not CharInSet(LTxt[LIdx], ['0', '1']) or
         (LU > High(UInt64) shr 1) then
        Exit;
      LU := (LU shl 1) or UInt64(Ord(LTxt[LIdx]) - Ord('0'));
    end;
  end
  else if not TryStrToUInt64(LTxt, LU) then
    Exit;
  if LU > UInt64(High(Int64)) then
    Exit;
  AValue := Int64(LU);
  Result := True;
end;

function OrdinalNodeValue(const ATree: TPasTree; ANode, ADepth: Integer;
  const AName: TSemaOrdNameValue; out AValue: Int64): Boolean;
var
  LTxt: string;
begin
  Result := False;
  AValue := 0;
  if ADepth > 8 then
    Exit;
  ANode := PeelParens(ATree, ANode);
  if ANode = NIL_NODE then
    Exit;
  case ATree.Nodes[ANode].Kind of
    nkIntLit, nkUnaryOp:
      begin
        Result := IntLiteralValue(ATree, ANode, AValue);
        // `-K` of a named constant.
        if not Result and (ATree.Nodes[ANode].Kind = nkUnaryOp) and
           (ATree.Nodes[ANode].Aux >= 0) and
           (ATree.Nodes[ANode].Aux <= High(ATree.Source.Visible)) and
           (ATree.Source.VisibleKind(ATree.Nodes[ANode].Aux) =
            tkMinus) and
           OrdinalNodeValue(ATree, ATree.Nodes[ANode].FirstChild, ADepth + 1,
             AName, AValue) then
        begin
          AValue := -AValue;
          Result := True;
        end;
      end;
    nkStrLit:
      begin
        LTxt := ATree.NodeText(ANode);
        if (Length(LTxt) = 3) and (LTxt[1] = '''') and (LTxt[3] = '''') then
        begin
          AValue := Ord(LTxt[2]);
          Result := True;
        end
        else if LTxt = '''''''''' then
        begin
          AValue := Ord('''');
          Result := True;
        end
        else if (Length(LTxt) > 1) and (LTxt[1] = '#') and
                (Pos('#', LTxt, 2) = 0) and (Pos('''', LTxt) = 0) then
          Result := TryStrToInt64(StringReplace(Copy(LTxt, 2, MaxInt), '_',
            '', [rfReplaceAll]), AValue);
      end;
    nkCaretChar:
      begin
        LTxt := ATree.NodeText(ANode);
        if Length(LTxt) = 2 then
        begin
          AValue := Ord(UpCase(LTxt[2])) xor $40;
          Result := True;
        end;
      end;
    nkIdent, nkMember:
      Result := Assigned(AName) and AName(ANode, ADepth + 1, AValue);
  end;
end;

function ConstExprKind(const ATree: TPasTree; ANode, ADepth: Integer;
  const AFacts: TSemaConstFactsFunc): TSemaConstKind;

  function IsConst(N: Integer): Boolean;
  begin
    Result := ConstExprKind(ATree, N, ADepth, AFacts) <> sckNone;
  end;

  // Is every node from AFrom on, along its siblings, a constant (one at
  // least)?
  function AllConst(AFrom: Integer): Boolean;
  begin
    Result := AFrom <> NIL_NODE;
    while Result and (AFrom <> NIL_NODE) do
    begin
      Result := IsConst(AFrom);
      AFrom := ATree.Nodes[AFrom].NextSibling;
    end;
  end;

var
  LCallee, LArg: Integer;
  LF, LA: TSemaConstFacts;
begin
  Result := sckNone;
  if ADepth > 8 then
    Exit;
  ANode := PeelParens(ATree, ANode);
  if ANode = NIL_NODE then
    Exit;
  case ATree.Nodes[ANode].Kind of
    nkIntLit, nkRealLit, nkStrLit, nkCaretChar:
      Result := sckValue;
    nkNilLit:
      Result := sckTyped;   // `[nil]` takes TArray<Pointer>
    nkUnaryOp:
      if not ((ATree.Nodes[ANode].Aux >= 0) and
              (ATree.Nodes[ANode].Aux <= High(ATree.Source.Visible)) and
              (ATree.Source.VisibleKind(ATree.Nodes[ANode].Aux) = tkAt)) and
         AllConst(ATree.Nodes[ANode].FirstChild) then
        Result := sckValue;
    nkBinaryOp, nkRange:
      if AllConst(ATree.Nodes[ANode].FirstChild) then
        Result := sckValue;
    nkSetCtor:
      // `[]` too.
      if (ATree.Nodes[ANode].FirstChild = NIL_NODE) or
         AllConst(ATree.Nodes[ANode].FirstChild) then
        Result := sckValue;
    nkIdent, nkMember:
      begin
        LF := AFacts(ANode, ADepth);
        if LF.Role = scrConst then
        begin
          if LF.Typed then
            Result := sckTyped
          else
            Result := sckValue;
        end
        // A bare parameterless intrinsic: Pi.
        else if (LF.Role = scrIntrinsic) and
                (PasIntrinsicFold(LF.Intrinsic) = ifAlways) then
          Result := sckValue;
      end;
    nkCall:
      begin
        LCallee := ATree.Nodes[ANode].FirstChild;
        if LCallee = NIL_NODE then
          Exit;
        LArg := ATree.Nodes[LCallee].NextSibling;
        LF := AFacts(LCallee, ADepth);
        case LF.Role of
          scrType:
            // A typecast of one constant - a string or a character one to
            // a pointer type is an address, no constant (`PChar('abc')`,
            // `PChar(KC)`); what the argument is must be known for that.
            if (LArg <> NIL_NODE) and
               (ATree.Nodes[LArg].NextSibling = NIL_NODE) and IsConst(LArg) then
            begin
              if LF.Cat <> tcPointer then
                Exit(sckTyped);
              LA := AFacts(LArg, ADepth);
              if not (LA.Cat in [tcUnknown, tcString, tcChar]) then
                Result := sckTyped;
            end;
          scrIntrinsic:
            case PasIntrinsicFold(LF.Intrinsic) of
              ifAlways:
                Result := sckValue;
              ifSizeOf:
                if (LArg <> NIL_NODE) and
                   not AFacts(LArg, ADepth).OpenArray then
                  Result := sckValue;
              ifArgs:
                if AllConst(LArg) then
                  Result := sckValue;
              ifPtr:
                if AllConst(LArg) then
                  Result := sckTyped;
              ifIntArg:
                if (LArg <> NIL_NODE) and IsConst(LArg) and
                   (AFacts(LArg, ADepth).Cat = tcInteger) then
                  Result := sckValue;
              ifHigh:
                if LArg <> NIL_NODE then
                begin
                  LA := AFacts(LArg, ADepth);
                  if (LA.Role = scrType) or
                     ((LA.Role in [scrConst, scrValue]) and
                      (LA.Cat <> tcUnknown) and not LA.RunTime and
                      not LA.OpenArray) then
                    Result := sckValue;
                end;
              ifLength:
                if (LArg <> NIL_NODE) and
                   (AFacts(LArg, ADepth).StaticArray or IsConst(LArg)) then
                  Result := sckValue;
              ifDefault:
                if LArg <> NIL_NODE then
                begin
                  LA := AFacts(LArg, ADepth);
                  if (LA.Role = scrType) and not LA.StaticArray and
                     not (LA.Cat in [tcUnknown, tcRecord, tcVariant]) then
                    Result := sckTyped;
                end;
            end;
        end;
      end;
  end;
end;

function EnumElemValue(const ATree: TPasTree; AElem, ADepth: Integer;
  const AName: TSemaOrdNameValue; out AValue: Int64): Boolean;
var
  LCur, LValue: Integer;
  LNext: Int64;
begin
  Result := False;
  AValue := -1;
  if (AElem = NIL_NODE) or (ATree.Nodes[AElem].Parent = NIL_NODE) then
    Exit;
  LCur := ATree.Nodes[ATree.Nodes[AElem].Parent].FirstChild;
  while LCur <> NIL_NODE do
  begin
    if ATree.Nodes[LCur].Kind = nkEnumValue then
    begin
      // nkEnumValue children: the name, then an optional value.
      LValue := ATree.Nodes[LCur].FirstChild;
      if LValue <> NIL_NODE then
        LValue := ATree.Nodes[LValue].NextSibling;
      if LValue = NIL_NODE then
        Inc(AValue)
      else if OrdinalNodeValue(ATree, LValue, ADepth + 1, AName, LNext) then
      begin
        AValue := LNext and $FFFFFFFF;
        if AValue > High(Integer) then
          AValue := AValue - $100000000;
      end
      else
        Exit;
    end;
    if LCur = AElem then
      Exit(True);
    LCur := ATree.Nodes[LCur].NextSibling;
  end;
end;

function OrdinalDefRange(const ATree: TPasTree; ADef: Integer;
  const AName: TSemaOrdNameValue; out ALo, AHi: Int64): Boolean;
var
  LCur: Integer;
  LV: Int64;
  LAny: Boolean;
begin
  Result := False;
  ALo := 0;
  AHi := 0;
  if ADef = NIL_NODE then
    Exit;
  case ATree.Nodes[ADef].Kind of
    nkEnumType:
      begin
        LAny := False;
        LCur := ATree.Nodes[ADef].FirstChild;
        while LCur <> NIL_NODE do
        begin
          if ATree.Nodes[LCur].Kind = nkEnumValue then
          begin
            if not EnumElemValue(ATree, LCur, 0, AName, LV) then
              Exit;
            if not LAny or (LV < ALo) then
              ALo := LV;
            if not LAny or (LV > AHi) then
              AHi := LV;
            LAny := True;
          end;
          LCur := ATree.Nodes[LCur].NextSibling;
        end;
        Result := LAny;
      end;
    nkSubrange:
      begin
        LCur := ATree.Nodes[ADef].FirstChild;
        Result := (LCur <> NIL_NODE) and
          OrdinalNodeValue(ATree, LCur, 0, AName, ALo) and
          (ATree.Nodes[LCur].NextSibling <> NIL_NODE) and
          OrdinalNodeValue(ATree, ATree.Nodes[LCur].NextSibling, 0, AName,
            AHi) and (ALo <= AHi);
      end;
  end;
end;

function OrdAnswer(const AF: TSemaOrdFacts): TSemaOpAnswer;
begin
  if AF.IsConst then
    Exit(oaInteger);
  if AF.Builtin <> '' then
    case AF.Cat of
      tcInteger:
        if AF.Rank = 4 then
          Exit(oaInteger)
        else
          Exit(oaLeft);
      tcChar:
        if AF.Builtin = 'ansichar' then
          Exit(oaByte)
        else
          Exit(oaWord);
      tcBoolean:
        if AF.Builtin = 'boolean' then
          Exit(oaShortInt)
        else if AF.Builtin = 'bytebool' then
          Exit(oaByte)
        else if AF.Builtin = 'wordbool' then
          Exit(oaWord)
        else
          Exit(oaInteger);
    end;
  if not AF.HasRange then
    Exit(oaInteger);
  if (AF.Lo >= -128) and (AF.Hi <= 127) then
    Result := oaShortInt
  else if (AF.Lo >= 0) and (AF.Hi <= 255) then
    Result := oaByte
  else if (AF.Lo >= -32768) and (AF.Hi <= 32767) then
    Result := oaSmallInt
  else if (AF.Lo >= 0) and (AF.Hi <= 65535) then
    Result := oaWord
  else if (AF.Lo >= 0) and (AF.Hi > High(Integer)) and
          (AF.Hi <= High(Cardinal)) then
    Result := oaCardinal
  else
    Result := oaInteger;
end;

function OrdStepAnswer(const AF: TSemaOrdFacts): TSemaOpAnswer;
begin
  if AF.Builtin <> '' then
  begin
    if AF.Rank <= 2 then
      Result := oaInteger
    else
      Result := oaLeft;
  end
  else if AF.HasRange and
          ((AF.Lo < Low(Integer)) or (AF.Hi > High(Integer))) then
    Result := oaInt64
  else
    Result := oaInteger;
end;

function RealLiteralNode(const ATree: TPasTree; ANode: Integer): Integer;
begin
  Result := PeelParens(ATree, ANode);
  while (Result <> NIL_NODE) and (ATree.Nodes[Result].Kind = nkUnaryOp) and
        (ATree.Nodes[Result].Aux >= 0) and
        (ATree.Nodes[Result].Aux <= High(ATree.Source.Visible)) and
        (ATree.Source.VisibleKind(ATree.Nodes[Result].Aux) in
         [tkMinus, tkPlus]) do
    Result := PeelParens(ATree, ATree.Nodes[Result].FirstChild);
  if (Result <> NIL_NODE) and (ATree.Nodes[Result].Kind <> nkRealLit) then
    Result := NIL_NODE;
end;

function PasLiteralTypeName(const ATree: TPasTree; ANode: Integer;
  ANegated, AIs64: Boolean): string;
var
  LTxt: string;
  LIdx, LUnits, LFrac: Integer;
  LU: UInt64;
  LHasExp, LInFrac: Boolean;
  LVal: Extended;
begin
  Result := '';
  if ANode = NIL_NODE then
    Exit;
  case ATree.Nodes[ANode].Kind of
    nkIntLit:
      begin
        LTxt := PasNumLiteralText(ATree.NodeText(ANode));
        if LTxt = '' then
          Exit;
        if LTxt[1] = '%' then
        begin
          // Binary: TryStrToUInt64 knows `$` but not `%`.
          LU := 0;
          for LIdx := 2 to Length(LTxt) do
          begin
            if not CharInSet(LTxt[LIdx], ['0', '1']) or (LU > High(UInt64) shr 1) then
              Exit;
            LU := (LU shl 1) or UInt64(Ord(LTxt[LIdx]) - Ord('0'));
          end;
        end
        else if not TryStrToUInt64(LTxt, LU) then
          Exit;
        if ANegated then
        begin
          if LU <= UInt64(High(Integer)) + 1 then
            Result := 'integer'
          else if LU <= UInt64(High(Int64)) + 1 then
            Result := 'int64';
          // Beyond that dcc rejects the literal; nothing to infer.
        end
        else if LU <= UInt64(High(Integer)) then
          Result := 'integer'
        else if LU <= UInt64(High(Cardinal)) then
          Result := 'cardinal'
        else if LU <= UInt64(High(Int64)) then
          Result := 'int64'
        else
          Result := 'uint64';
      end;

    nkRealLit:
      begin
        Result := 'extended';
        if not AIs64 then
          Exit;
        LTxt := StringReplace(ATree.NodeText(ANode), '_', '',
          [rfReplaceAll]);
        LHasExp := False;
        LInFrac := False;
        LFrac := 0;
        for LIdx := 1 to Length(LTxt) do
          case LTxt[LIdx] of
            'e', 'E':
              LHasExp := True;
            '.':
              LInFrac := True;
          else
            if LInFrac and not LHasExp then
              Inc(LFrac);
          end;
        if LHasExp or (LFrac > 4) then
          Exit;
        // Currency's range: |v| <= 922337203685477.5807. The text is decimal
        // with at most four fractional digits, so an Extended reads it
        // exactly enough for this comparison (the boundary itself has 19
        // significant digits, within Extended's 64-bit mantissa on Win32;
        // on a Double-sized Extended it rounds, and dcc's own comparison is
        // over the same Double - probed at the boundary both ways).
        if not TryStrToFloat(LTxt, LVal, TFormatSettings.Invariant) then
          Exit;
        if Abs(LVal) > 922337203685477.5807 then
          Exit;
        Result := 'currency';
      end;

    nkCaretChar:
      Result := 'char';

    nkStrLit:
      begin
        // UTF-16 units over every visible token of the node (StrLitUnits,
        // the one count the scorers read too - audit A4-07).
        LUnits := StrLitUnits(ATree, ANode);
        if LUnits < 0 then
          Exit;   // a multiline string or anything unexpected: not a Char
        if LUnits = 1 then
          Result := 'char'
        else
          Result := 'string';
      end;
  end;
end;


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

// The operator's token KIND (Aux points at the operator token). Every
// operator this typer dispatches on has a dedicated kind, so no text is
// materialized - the old string version paid a LowerCase(VisibleText(...))
// copy per binary/unary node in the corpus. tkUnknown when Aux is unset, or
// when the tree has no text (a demoted model - this typer runs in Phase 1 on
// full text, so that is a caller outside the pipeline; answering "unknown"
// beats reading a nil token array, see TPasSemaProject.BinaryOpIsAs).
function TPasSemaTyper.OpKind(N: Integer): TPasTokenKind;
var
  LOpTok: Integer;
begin
  LOpTok := T.Nodes[N].Aux;
  if (LOpTok >= 0) and (LOpTok <= High(T.Source.Visible)) then
    Result := T.Source.VisibleKind(LOpTok)
  else
    Result := tkUnknown;
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

{ The category a subrange's LOW BOUND establishes - see CatFromNode: a
  literal, signed or not; True / False; an enumeration value bound here (its
  enumeration); a same-unit constant, by its declared type or else by its own
  value, followed the same way (`const N = 5; TNeg = -N..N` is an integer
  subrange, `TWork = dMon..dTue` an enumeration one - dcc picks P(TDay) for a
  TWork argument, audit E3-18, local/probe-b35 P1). A bound this cannot read
  is answered tcUnknown, which every check below treats as "say nothing";
  the project categorizes a bound bound in another unit (CrossResolve). }
function TPasSemaTyper.CatOfSubrangeBound(ALo: Integer): TSemaTypeCat;
var
  LDepth, LSym, LVal: Integer;
begin
  Result := tcUnknown;
  for LDepth := 1 to 8 do
  begin
    // A signed bound (`-5..5`, `-N..N`) is an nkUnaryOp over it.
    while (ALo <> NIL_NODE) and (Kind(ALo) = nkUnaryOp) and
          (OpKind(ALo) in [tkMinus, tkPlus]) do
      ALo := Child(ALo);
    if ALo = NIL_NODE then
      Exit;
    case Kind(ALo) of
      nkIntLit:
        Exit(tcInteger);
      nkStrLit:
        if IsOneCharLiteralNode(T, ALo) then
          Exit(tcChar)
        else
          Exit;
      nkCaretChar:
        Exit(tcChar);
      nkIdent:
        begin
          if T.NodeTextEquals(ALo, 'True') or
             T.NodeTextEquals(ALo, 'False') then
            Exit(tcBoolean);
          LSym := M.RefMap[ALo];
          if LSym = NIL_SYM then
            Exit;
          case M.Symbols[LSym].Kind of
            skEnumValue:
              Exit(CatOf(M.Symbols[LSym].TypeSym));
            skConst:
              begin
                if M.Symbols[LSym].TypeSym <> NIL_SYM then
                  Exit(CatOf(M.Symbols[LSym].TypeSym));
                // A true constant: its value, the name's next sibling.
                LVal := M.Symbols[LSym].DeclNode;
                if (LVal = NIL_NODE) or (T.Nodes[LVal].Parent = NIL_NODE) or
                   (Kind(T.Nodes[LVal].Parent) <> nkConstDecl) then
                  Exit;
                ALo := Sib(LVal);
              end;
          else
            Exit;
          end;
        end;
    else
      Exit;
    end;
  end;
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
    // A subrange is the category of its BOUNDS, not always an integer one:
    // `'a'..'z'` is a Char subrange and `False..True` a Boolean one, and
    // calling both tcInteger made `C := R` a false E2010 and a Boolean
    // subrange in an `if` a false E2012 - against this typer's
    // zero-false-positive rule. Anything the literal test cannot settle
    // (a named constant, an Ord() expression) stays UNKNOWN, which reports
    // nothing.
    nkSubrange: Result := CatOfSubrangeBound(Child(ADef));
    nkIdent, nkMember, nkTypeArgs:   // alias to another named type
      Result := CatOf(Head(ADef));   // may be tcUnknown until target computed
    // `UTF8String = type AnsiString(65001)`: a code-page string reads as a
    // call of the string type (audit A3-34 - it had no category, so no
    // string rule ever saw a UTF8String or RawByteString operand).
    nkCall:
      if CatOf(Head(Child(ADef))) = tcString then
        Result := tcString
      else
        Result := tcUnknown;
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

{ The category a type EXPRESSION node denotes - CatFromNode plus the named-type
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

{ 2 sec. 2.1.1 / sec. 2.4.1: only an ORDINAL type may be an array's index type or a
  set's base type - dcc reports `E2001 Ordinal type required`. Same rule, same
  code, for the `for` counter's declared type, except that dcc has a dedicated
  message there: `E2032 For loop control variable must have ordinal type`.

  Verified against dcc32 37.0, and two of the answers are not guessable:

  - `Variant` is NOT ordinal in these positions (`array[Variant]`, `set of
    Variant`, `for V := 1 to 3` are all errors) even though it IS accepted as a
    `case` selector and as an `if` condition. Per-position, not per-type.
  - a SPARSE (explicitly-valued) enum is fine everywhere - as an index, a set
    base, a `case` selector and a `for` counter. sec. 2.1.1/sec. 2.2.4 claimed the
    opposite; the spec was corrected rather than the code, since dcc accepts
    `array[(spA = 0, spB = 10, spC = 99)]` and `set of` it without a murmur.

  Reports only a category that is DEFINITELY not ordinal. `tcUnknown` covers
  every cross-unit type (an imported enum's category is not computed intra-unit)
  and every generic parameter, so those stay silent - a missed report, never a
  false one. Records are included deliberately: an `Implicit` operator to an
  ordinal does NOT rescue any of these positions (dcc-verified for `case`, which
  is the one place a conversion could plausibly have applied). }
procedure TPasSemaTyper.CheckOrdinalTypePositions;
const
  // Everything that is not ordinal AND not "we do not know" - tcNil cannot
  // appear in a type position at all.
  CNotOrdinal = [tcFloat, tcString, tcPointer, tcSet, tcArray, tcRecord,
    tcClass, tcInterface, tcProc, tcClassOf, tcVariant, tcFile];
var
  LIdx, LChild, LLast, LSym, LType: Integer;
begin
  for LIdx := 0 to High(T.Nodes) do
    case SweepKind(LIdx) of
      nkArrayType:
        begin
          // Children are the index types followed by the element type - except
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

{ The two EXPRESSION positions of the same family (2 sec. 2.2.2, sec. 2.1.1), so this one
  runs after TypeNode has filled ExprType rather than beside CategorizeTypes:

  - an `if`/`while`/`until` condition must be Boolean - `E2012 Type of expression
    must be BOOLEAN`;
  - a `case` selector must be ordinal - `E2001`, the same code as the type
    positions above.

  The two exempt sets differ, and dcc32 37.0 is the only reason to know how:

  - `Variant` is accepted in BOTH a condition and a `case` selector, though it is
    an error as an array index, a set base or a `for` counter.
  - a RECORD is accepted as a condition when it has an `Implicit` operator to
    Boolean, and rejected when it has one to Integer - so whether a record
    condition is legal depends on its operators, which is not a question asked
    here. Records are therefore exempt in conditions and NOT exempt as `case`
    selectors, where dcc rejects one even with `Implicit` to an ordinal.
  - a PROCEDURAL type is exempt in both, because a parameterless function
    reference in a value position is CALLED: `if AShouldStop then` where the
    parameter is `reference to function: Boolean` is ordinary, correct code, and
    the type of the condition is the function's RESULT. Found the honest way -
    six such conditions in one component suite lit up on a real
    corpus the first time this check ran. In a TYPE position (an array index, a
    set base) a procedural type stays an error, since nothing is called there.

  Everything else is reported only when the category is definite; an unknown
  expression type (a cross-unit member, an untyped intrinsic result, a deref)
  says nothing. `Diag` additionally withholds anything inside an unresolved
  `with` body, where a binding - and so a type - is only a guess. }
procedure TPasSemaTyper.CheckConditionTypes;
const
  // The statements CheckCondition judges - it ignores every other kind, so
  // the sweep does not call it per node. Keep in step with its case.
  CCondStmts = [nkIfStmt, nkWhileStmt, nkRepeatStmt, nkCaseStmt];
var
  LIdx: Integer;
begin
  for LIdx := 0 to High(T.Nodes) do
    if SweepKind(LIdx) in CCondStmts then
      CheckCondition(LIdx);
end;

// One statement's part of CheckConditionTypes - a recheck re-runs it for the
// condition it re-typed (see RecheckWithBodies).
procedure TPasSemaTyper.CheckCondition(AStmt: Integer);
const
  // Not Boolean and not "we do not know". tcRecord, tcVariant and tcProc are
  // absent deliberately - see CheckConditionTypes' header.
  CNotBoolean = [tcInteger, tcFloat, tcChar, tcString, tcEnum, tcSet, tcArray,
    tcClass, tcInterface, tcClassOf, tcPointer, tcFile];
  // Not ordinal and not "we do not know". Variant is legal HERE; a record is
  // not, whatever operators it has.
  CNotSelector = [tcFloat, tcString, tcPointer, tcSet, tcArray, tcRecord,
    tcClass, tcInterface, tcClassOf, tcFile];
var
  LCond: Integer;
begin
  LCond := NIL_NODE;
  case Kind(AStmt) of
    nkIfStmt, nkWhileStmt:
      LCond := Child(AStmt);
    nkRepeatStmt:
      // body block, then the `until` expression.
      if Child(AStmt) <> NIL_NODE then
        LCond := Sib(Child(AStmt));
    nkCaseStmt:
      begin
        LCond := Child(AStmt);
        if (LCond <> NIL_NODE) and not IsTypeNameOperand(LCond) and
           (CatOf(M.ExprType[LCond]) in CNotSelector) then
          Diag('E2001', SE2001_OrdinalTypeRequired, LCond);
        Exit;
      end;
  end;
  // A condition bound to a TYPE name is the mis-binding CheckAssign
  // withholds judgement on - an inherited cross-unit member named `Byte`
  // (`if Byte then`) - not a non-Boolean value (audit A4-13).
  if (LCond <> NIL_NODE) and not IsTypeNameOperand(LCond) and
     (CatOf(M.ExprType[LCond]) in CNotBoolean) then
    Diag('E2012', SE2012_MustBeBoolean, LCond);
end;

{ The ordinal value of a LITERAL bound, and only of a literal: a decimal or `$`
  hex integer, either of those negated, or a one-character string literal. Named
  constants and `Ord(...)` expressions deliberately answer False - the set check
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
  if (Kind(ANode) = nkUnaryOp) and (OpKind(ANode) = tkMinus) then
  begin
    // A hex literal above High(Int64) reads as its Int64 bits (B.5.1), so a
    // negative literal here is one: `-$8000000000000000` is Low(Int64) itself
    // and anything larger is dcc's E2099, not a value.
    if OrdLiteral(Child(ANode), LNeg) then
      if LNeg = Low(Int64) then
      begin
        AValue := Low(Int64);
        Result := True;
      end
      else if (LNeg >= 0) or (Kind(Child(ANode)) <> nkIntLit) then
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
        // Digit separators are legal in a literal (B.5.1) and carry no value,
        // and neither does a leading `&` (B.3).
        LTxt := PasNumLiteralText(LTxt);
        if LTxt.StartsWith('%') then
        begin
          // Binary (B.5.1): `set of 0..%111111111` is E2028 like 0..511.
          Result := (Length(LTxt) > 1) and (Length(LTxt) <= 64);
          for var LCh in LTxt.Substring(1) do
            if CharInSet(LCh, ['0', '1']) then
              AValue := (AValue shl 1) or (Ord(LCh) - Ord('0'))
            else
              Exit(False);
        end
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

{ 2 sec. 2.4.1: a set's base type may have at most 256 values and those values must
  lie in `0..255` - one code for both, `E2028 Sets may have at most 256
  elements`, which dcc32 37.0 also uses for a NEGATIVE lower bound (`set of
  -5..5`) rather than a separate message.

  A 64-BIT ordinal base is the exception, and not a small one: dcc answers
  `E2001 Ordinal type required` there rather than E2028, even though `Int64` is
  perfectly ordinal. `NativeInt`/`NativeUInt` follow the TARGET - dcc32 says
  E2028 for `set of NativeInt` and dcc64 says E2001 for the same line - which is
  the one thing in this typer that needs to know the platform.

  `set of Char` (and `WideChar`) is only a WARNING, `W1050 WideChar reduced to
  byte char`, so it is passed over. The `*Bool` interop types are NOT: dcc
  reports E2028 for `set of ByteBool` although it is a single byte, while
  `set of Boolean` is fine.

  Reports only a cardinality it can compute exactly:

  - a named builtin, each answer probed against dcc (both compilers for the two
    platform-sized ones).
  - a subrange with two LITERAL bounds (`OrdLiteral`, so no folded constants);
    bounds that fit neither Integer nor Cardinal make it 64-bit, so E2001.
  - an enum whose element values are literals or implicit, tracked in order so
    that `(a = 250, b, c, d, e, f, g)` is caught as well as an explicit 256. One
    non-literal explicit value abandons the whole enum.

  A named base type is followed one definition at a time (`TNeg = -5..5;
  set of TNeg`), which is also how an alias chain is handled. }
procedure TPasSemaTyper.CheckSetCardinality;
const
  // 0..255 exactly, so a set over the whole type is legal.
  CFits: array[0..2] of string = ('byte', 'boolean', 'ansichar');
  // More than 256 values but not 64-bit. `ShortInt` is here for its NEGATIVE
  // half, and the three `*Bool`s because dcc says so - `ByteBool` is one byte
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
              // A 64-bit ordinal is E2001 by its width: Int64 / UInt64, a
              // 64-bit NativeInt, and LongInt / LongWord on the LP64 targets
              // (ranked 4 there - audit A1-10).
              if (M.Symbols[LSym].TypeCat = tcInteger) and
                 (M.Symbols[LSym].NumRank = 4) then
                Exit('E2001');
              for LIdx := Low(CTooMany) to High(CTooMany) do
                if LName = CTooMany[LIdx] then
                  Exit('E2028');
              for LIdx := Low(CSixtyFour) to High(CSixtyFour) do
                if LName = CSixtyFour[LIdx] then
                  Exit('E2001');
              // The two platform-sized names are 64-bit only where the target
              // is, and dcc's code follows the width, not the spelling.
              if (LName = 'nativeint') or (LName = 'nativeuint') then
                if FIs64 then
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
            // A Char subrange base is reduced to a byte char - W1050 past
            // 256 values, silence otherwise, never E2028: `set of
            // 'a'..#$100`, `set of #$410..#$42F` (2.4.1, local/probe-b35
            // S1; audit A4-12). Only integer bounds are E2028 material.
            if CatOfSubrangeBound(Child(ANode)) = tcChar then
              Exit;
            if not OrdLiteral(Child(ANode), LLo) then
              Exit;
            if not OrdLiteral(Sib(Child(ANode)), LHi) then
              Exit;
            if LLo > LHi then
              Exit;   // E2011, not a set's business
            // Bounds that fit neither Integer nor Cardinal together make a
            // 64-bit host type, and that is E2001 like `set of Int64`.
            if not (((LLo >= Low(Integer)) and (LHi <= High(Integer))) or
              ((LLo >= 0) and (LHi <= High(Cardinal)))) then
              Exit('E2001');
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
                  Exit   // a named constant or an expression: give up
                else
                begin
                  // dcc keeps an explicit value's low 32 bits, signed, and
                  // says nothing (2 sec. 2.2.4): `(a = $100000005)` IS 5.
                  LCur := LCur and $FFFFFFFF;
                  if LCur > High(Integer) then
                    LCur := LCur - $100000000;
                end;
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
    if SweepKind(LIdx) = nkSetType then
    begin
      LCode := BaseVerdict(Child(LIdx));
      if LCode = 'E2028' then
        Diag(LCode, SE2028_SetTooLarge, Child(LIdx))
      else if LCode = 'E2001' then
        Diag(LCode, SE2001_OrdinalTypeRequired, Child(LIdx));
    end;
end;

{ The builtin a NUMBER type ASym is stored as: weak aliases and distinct
  `type X` links followed (`TMyI64 = type Int64` computes as an Int64 -
  audit A3-32, B4-08); ASym itself when it ends at no builtin. }
function TPasSemaTyper.StorageBase(ASym: Integer): Integer;
var
  LDepth, LDef, LNext: Integer;
begin
  Result := ASym;
  for LDepth := 1 to 8 do
  begin
    if (Result = NIL_SYM) or (M.Symbols[Result].Kind <> skType) then
      Exit;
    LDef := TypeDefNode(Result);
    if (LDef = NIL_NODE) or not (Kind(LDef) in [nkIdent, nkMember]) then
      Exit;
    LNext := Head(LDef);
    if (LNext = NIL_SYM) or (LNext = Result) then
      Exit;
    Result := LNext;
  end;
end;

// The operator facts of operand node ANode of type ASym: its category, the
// rank and identity of the builtin it is stored as (`TBig = Int64` ranks as
// Int64 - audit A4-14), and whether it is a literal.
function TPasSemaTyper.OpFacts(ASym, ANode: Integer): TSemaOpFacts;
var
  LB, LLit: Integer;
begin
  Result := Default(TSemaOpFacts);
  Result.Cat := CatOf(ASym);
  LLit := PeelParens(T, ANode);
  Result.SetCtor := (LLit <> NIL_NODE) and (Kind(LLit) = nkSetCtor);
  if (LLit <> NIL_NODE) and (Kind(LLit) in [nkStrLit, nkCaretChar]) then
  begin
    // A literal is its own kind whatever ExprType says (string or Char).
    if (Kind(LLit) = nkCaretChar) or IsOneCharLiteralNode(T, LLit) then
      Result.Text := stkCharLit
    else
      Result.Text := stkLit;
    Exit;
  end;
  case Result.Cat of
    tcInteger:
      Result.IntConst := IntLiteralValue(T, ANode, Result.IntValue);
    tcFloat:
      begin
        LLit := RealLiteralNode(T, ANode);
        Result.RealLit := LLit <> NIL_NODE;
        Result.CurrLit := Result.RealLit and
          (PasLiteralTypeName(T, LLit, False, FIs64) = 'currency');
      end;
  end;
  if Result.Cat in [tcInteger, tcFloat] then
    LB := StorageBase(ASym)
  else
    LB := WeakAliasEnd(ASym);
  if (LB = NIL_SYM) or (M.Symbols[LB].Kind <> skBuiltinType) then
    Exit;
  Result.Rank := M.Symbols[LB].NumRank;
  Result.Unsigned := (LB = Byt) or (LB = Wrd) or (LB = Card) or
    (LB = LWord) or (LB = U64) or (LB = NUInt);
  Result.Curr := (LB = Cur) and not Result.RealLit;
  Result.Comp := LB = Comp;
  if Result.Cat in [tcChar, tcString] then
    if (LB = Str) or (LB = UStr) then
      Result.Text := stkUni
    else if (LB = Chr) or (LB = WChr) then
      Result.Text := stkChar
    else if LB = WStr then
      Result.Text := stkWide
    else if LB = SStr then
      Result.Text := stkShort
    else if LB = AStr then
      Result.Text := stkAnsi
    else if LB = AChr then
      Result.Text := stkAnsiChar;
end;

// The type symbol OperatorAnswer's AAns names for the operands ALeft /
// ARight - a number operand as the builtin it is stored as, unless AKeepOwn
// (`not` keeps a distinct type); NIL_SYM where it names none.
function TPasSemaTyper.OpSym(AAns: TSemaOpAnswer; ALeft, ARight: Integer;
  AKeepOwn: Boolean): Integer;

  function Own(ASym: Integer): Integer;
  begin
    if not AKeepOwn and (CatOf(ASym) in [tcInteger, tcFloat]) then
      Result := StorageBase(ASym)
    else
      Result := WeakAliasEnd(ASym);
  end;

begin
  case AAns of
    oaBoolean: Result := Bool;
    oaInteger: Result := Int;
    oaInt64: Result := I64;
    oaLeft: Result := Own(ALeft);
    oaRight: Result := Own(ARight);
    oaExtended: Result := Ext;
    oaCurrency: Result := Cur;
    oaString: Result := Str;
    oaAnsiString: Result := AStr;
    oaPointer: Result := Ptr;
    oaShortInt: Result := ShInt;
    oaByte: Result := Byt;
    oaSmallInt: Result := SmInt;
    oaWord: Result := Wrd;
    oaCardinal: Result := Card;
    oaUInt64: Result := U64;
    oaComp: Result := Comp;
    oaWideString: Result := WStr;
    oaShortString: Result := SStr;
  else
    Result := NIL_SYM;
  end;
end;

// Is N where a bare routine name is a value - a member qualifier, a `with`
// target, an inline initializer (CrossType's IsValuePosition)?
function TPasSemaTyper.IsValuePos(N: Integer): Boolean;
var
  LParent: Integer;
begin
  LParent := T.Nodes[N].Parent;
  if LParent = NIL_NODE then
    Exit(False);
  case Kind(LParent) of
    nkMember:
      Result := Child(LParent) = N;
    nkWithStmt:
      Result := Sib(N) <> NIL_NODE;
    nkInlineVar, nkInlineConst:
      Result := (Sib(N) = NIL_NODE) and ((M.RefMap[N] = NIL_SYM) or
        (M.Symbols[M.RefMap[N]].DeclNode <> N));
  else
    Result := False;
  end;
end;

{ `if C then L else R` (5.4.1): the branches' common type - `nil` takes the
  other branch, a `[...]` the other branch's set type, the rest by the
  shared rule (InlineIfAnswer; audit E3-19: the THEN branch's type was the
  whole's). Two different classes are left to the project, which sees the
  whole ancestry; a branch this unit cannot type leaves the whole untyped. }
function TPasSemaTyper.InlineIfResult(N: Integer): Integer;
var
  LThen, LElse, LT, LE: Integer;
  LSame: Boolean;
begin
  Result := NIL_SYM;
  LThen := Child(N);   // cond, then, else
  if LThen <> NIL_NODE then
    LThen := Sib(LThen);
  if LThen = NIL_NODE then
    Exit;
  LElse := Sib(LThen);
  LT := M.ExprType[LThen];
  if LElse = NIL_NODE then
    Exit(LT);
  LE := M.ExprType[LElse];
  if CatOf(LT) = tcNil then
  begin
    if CatOf(LE) = tcNil then
      Exit(Ptr);
    Exit(LE);
  end;
  if CatOf(LE) = tcNil then
    Exit(LT);
  if (Kind(PeelParens(T, LElse)) = nkSetCtor) and (CatOf(LT) = tcSet) then
    Exit(WeakAliasEnd(LT));
  if (Kind(PeelParens(T, LThen)) = nkSetCtor) and (CatOf(LE) = tcSet) then
    Exit(WeakAliasEnd(LE));
  if (LT = NIL_SYM) or (LE = NIL_SYM) then
    Exit;
  LSame := WeakAliasEnd(LT) = WeakAliasEnd(LE);
  if LSame then
    Exit(WeakAliasEnd(LT));
  if (CatOf(LT) in [tcClass, tcInterface]) or
     (CatOf(LE) in [tcClass, tcInterface]) then
    Exit;
  Result := OpSym(InlineIfAnswer(OpFacts(LT, LThen), OpFacts(LE, LElse),
    False, FIs64), LT, LE, False);
end;

function TPasSemaTyper.TypeOfIdent(N: Integer): Integer;
var
  LSym: Integer;
begin
  LSym := M.RefMap[N];
  if LSym = NIL_SYM then
  begin
    // External / unresolved - unless the host can name the external binding's
    // type in THIS model's terms (recheck mode; a builtin, or a type declared
    // here). NIL_SYM otherwise, as before.
    if Assigned(FExtTypeOf) then
      Exit(FExtTypeOf(N));
    Exit(NIL_SYM);
  end;
  // A bare overloaded routine name where it is a VALUE means the overload
  // that needs no argument (6.6.1): `GetRec.R2` with GetRec(I): TR1 declared
  // before GetRec: TR2 (audit A3-18, local/probe-b34 P1).
  if (M.Symbols[LSym].Kind = skRoutine) and IsValuePos(N) then
  begin
    var LParamless := M.ParamlessOverload(LSym);
    if LParamless <> NIL_SYM then
      LSym := LParamless;
  end;
  case M.Symbols[LSym].Kind of
    skVar, skConst, skField, skParam, skRoutine, skProperty, skEnumValue:
      begin
        Result := M.Symbols[LSym].TypeSym;   // value / result / property type
        // An inline `string[N]` slot names no type symbol: a ShortString
        // (audit E2-36).
        if (Result = NIL_SYM) and (M.Symbols[LSym].TypeNode <> NIL_NODE) and
           (Kind(M.Symbols[LSym].TypeNode) = nkStringType) then
          Result := SStr;
        // A parameterless intrinsic written bare - `Pi`, `ReturnAddress`,
        // `Eof` - is a call without its parentheses (4.11).
        if (Result = NIL_SYM) and (M.Symbols[LSym].Kind = skRoutine) and
           (sfBuiltin in M.Symbols[LSym].Flags) then
          Result := IntrinsicResult(N, LSym);
      end;
    skType, skBuiltinType:
      Result := LSym;                       // type designator (casts)
  else
    Result := NIL_SYM;
  end;
end;

{ A binary operator's type by the shared 4.2.1 table (OperatorAnswer); E2015
  only for two scalar operands no rule takes. An operand bound to a TYPE
  name says nothing - the inherited cross-unit member named `Word` / `Byte`
  that Phase 1 binds to the seeded type (CheckAssign, audit A4-13). }
function TPasSemaTyper.BinaryResult(N: Integer): Integer;
const
  CScalar = [tcInteger, tcFloat, tcBoolean, tcChar, tcString];
var
  LLeft, LRight, LL, LR: Integer;
  LOp: TPasTokenKind;
  LAns: TSemaOpAnswer;
begin
  LLeft := Child(N);
  LRight := Sib(LLeft);
  LL := M.ExprType[LLeft];
  LR := M.ExprType[LRight];
  Result := NIL_SYM;
  // A `[...]` right operand has no type, but `St + [e1]` is St's (E3-43).
  if (LL = NIL_SYM) or ((LR = NIL_SYM) and
     (Kind(PeelParens(T, LRight)) <> nkSetCtor)) then
    Exit;
  LOp := OpKind(N);
  if LOp in [tkEqual, tkNotEqual, tkLess, tkLessEqual, tkGreater,
     tkGreaterEqual, tkIn, tkIs] then
    Exit(Bool);
  if IsTypeNameOperand(LLeft) or IsTypeNameOperand(LRight) then
    Exit;
  LAns := OperatorAnswer(LOp, False, OpFacts(LL, LLeft), OpFacts(LR, LRight),
    WeakAliasEnd(LL) = WeakAliasEnd(LR), FIs64);
  if LAns = oaNone then
  begin
    // dcc's code depends on the pair (4.2.1; dcc64 37.0, local/probe-park/
    // e321 O1-O12): a string with an Integer, Boolean or real operand is
    // E2010 naming the string's type first, whatever the operator and the
    // order (`'ab' + 1`, `I xor S`); any other scalar mismatch is E2008
    // under `+` (`I + True`, `Ch + I`) and E2015 under the rest (audit E3-21).
    if (CatOf(LL) in CScalar) and (CatOf(LR) in CScalar) then
    begin
      if (CatOf(LL) = tcString) and
         (CatOf(LR) in [tcInteger, tcFloat, tcBoolean]) then
        Diag('E2010', Format(SE2010_IncompatibleTypes,
          [M.Symbols[LL].Name, M.Symbols[LR].Name]), N)
      else if (CatOf(LR) = tcString) and
              (CatOf(LL) in [tcInteger, tcFloat, tcBoolean]) then
        Diag('E2010', Format(SE2010_IncompatibleTypes,
          [M.Symbols[LR].Name, M.Symbols[LL].Name]), N)
      else if LOp = tkPlus then
        Diag('E2008', SE2008_IncompatibleTypes, N)
      else
        Diag('E2015', SE2015_OperatorNotApplicable, N);
    end;
    Exit;
  end;
  Result := OpSym(LAns, LL, LR, False);
end;

function TPasSemaTyper.UnaryResult(N: Integer): Integer;
var
  LOperand, LO: Integer;
  LOp: TPasTokenKind;
  LAns: TSemaOpAnswer;
begin
  LOperand := Child(N);
  LO := M.ExprType[LOperand];
  Result := NIL_SYM;
  LOp := OpKind(N);
  if LOp = tkAt then
    Exit(Ptr);
  if (LO = NIL_SYM) or IsTypeNameOperand(LOperand) then
    Exit;
  LAns := OperatorAnswer(LOp, True, OpFacts(LO, LOperand),
    Default(TSemaOpFacts),
    False, FIs64);
  if LAns = oaNone then
  begin
    if (LOp in [tkMinus, tkPlus, tkNot]) and
       (CatOf(LO) in [tcInteger, tcFloat, tcBoolean, tcChar, tcString]) then
      Diag('E2015', SE2015_OperatorNotApplicable, N);
    Exit;
  end;
  Result := OpSym(LAns, LO, NIL_SYM, LOp = tkNot);
end;

function TPasSemaTyper.ParamsOf(AScope: Integer): TArray<Integer>;
var
  LList: TSemaSymList;
  LIdx, LCount: Integer;
begin
  // Indexed two-pass (count, size once, fill) - runs per overload candidate;
  // the for-in enumerator and the per-append copy were both allocations.
  Result := nil;
  if AScope = NIL_SCOPE then
    Exit;
  LList := M.Scopes[AScope].Symbols;
  if LList.Count = 0 then
    Exit;   // lazy scope list - never bound
  LCount := 0;
  for LIdx := 0 to LList.Count - 1 do
    if M.Symbols[LList[LIdx]].Kind = skParam then
      Inc(LCount);
  SetLength(Result, LCount);
  LCount := 0;
  for LIdx := 0 to LList.Count - 1 do
    if M.Symbols[LList[LIdx]].Kind = skParam then
    begin
      Result[LCount] := LList[LIdx];
      Inc(LCount);
    end;
end;

// Does a candidate with (AReq, ATot) parameters admit AArgs present arguments?
// Plain: AReq <= AArgs <= ATot. After a trailing comma (6.2.5, dcc-probed):
// only when every parameter is supplied AND the last one has a default -
// the empty slot is the default, already given. dcc also refuses the comma
// on an OVERLOADED callee (E2034 even when one candidate fits); not modelled
// here, since the candidate set is rarely provably complete - a tolerant miss
// beats a false E2034.
class function TPasSemaTyper.ArityFits(AArgs, AReq, ATot: Integer;
  ATrailing: Boolean): Boolean;
begin
  if ATrailing then
    Result := (AArgs = ATot) and (AReq < ATot)
  else
    Result := (AArgs >= AReq) and (AArgs <= ATot);
end;

function TPasSemaTyper.ArgListTruncated(ACall: Integer): Boolean;
var
  LArg: Integer;
begin
  Result := False;
  LArg := CallFirstArg(T, ACall);
  while LArg <> NIL_NODE do
  begin
    if Kind(LArg) = nkError then
      Exit(True);
    LArg := Sib(LArg);
  end;
end;

{ The type a WEAK alias chain ends at: `TId = Integer`, `TMyRc = TRc` are
  their targets' own type (2.5.1), so the scorer compares the ends - an
  alias argument tied every merely assignable sibling and the first declared
  won (audit A4-08, probe-b32 P1: `F(I)` takes F(A: TId) beside F(Int64)).
  Never past a distinct `type X` (nkTypeDecl Aux = 1), never into an
  instantiation (a `TList<Integer>` is its own type). Same-unit links only,
  like ArrayDefOf: a cross-unit target is unbound here. }
function TPasSemaTyper.WeakAliasEnd(ASym: Integer): Integer;
var
  LDepth, LDef, LNext: Integer;
begin
  Result := ASym;
  for LDepth := 1 to 8 do
  begin
    if (Result = NIL_SYM) or (M.Symbols[Result].Kind <> skType) then
      Exit;
    LDef := TypeDefNode(Result);
    if (LDef = NIL_NODE) or not (Kind(LDef) in [nkIdent, nkMember]) or
       (T.Nodes[T.Nodes[LDef].Parent].Aux = 1) then
      Exit;
    LNext := Head(LDef);
    if (LNext = NIL_SYM) or (LNext = Result) then
      Exit;
    Result := LNext;
  end;
end;

// The class a `class of` type ASym (through weak aliases) refers to;
// NIL_SYM when it is not one or the target is not bound here.
function TPasSemaTyper.ClassRefTarget(ASym: Integer): Integer;
var
  LDef: Integer;
begin
  Result := NIL_SYM;
  ASym := WeakAliasEnd(ASym);
  if (ASym = NIL_SYM) or (M.Symbols[ASym].Kind <> skType) then
    Exit;
  LDef := TypeDefNode(ASym);
  if (LDef <> NIL_NODE) and (Kind(LDef) = nkClassOf) and
     (Child(LDef) <> NIL_NODE) then
    Result := WeakAliasEnd(Head(Child(LDef)));
end;

// A bare designator naming a PROCEDURE - a routine with no result - is a
// method value and nothing else (the project's IsProcedureDesignator; Head
// reads `DoIt<Integer>` through its nkTypeArgs, audit B3-27).
function TPasSemaTyper.IsProcDesignator(N: Integer): Boolean;
var
  LSym: Integer;
begin
  Result := False;
  if not (Kind(N) in [nkIdent, nkMember, nkTypeArgs]) then
    Exit;
  LSym := Head(N);
  // A seeded intrinsic has no TypeNode whatever it returns: `ErrorAt(Byte(X),
  // ReturnAddress)` is a function call (System.pas), never a method value; a
  // constructor (no TypeNode either) is called by `Put(TFoo.Create)` (A3-19).
  Result := (LSym <> NIL_SYM) and (M.Symbols[LSym].Kind = skRoutine) and
    (M.Symbols[LSym].TypeNode = NIL_NODE) and
    not (sfBuiltin in M.Symbols[LSym].Flags) and
    (M.RoutineHead(LSym) <> rhConstructor);
end;

// Does the record type ASym (through weak aliases) declare `class operator
// Implicit` (or, AExplicitToo, Explicit)? Only the type's OWN members: an
// operator is not inherited.
function TPasSemaTyper.DeclaresConversion(ASym: Integer;
  AExplicitToo: Boolean): Boolean;
var
  LScope: Integer;
begin
  Result := False;
  ASym := WeakAliasEnd(ASym);
  if ASym = NIL_SYM then
    Exit;
  LScope := M.Symbols[ASym].MemberScope;
  if LScope = NIL_SCOPE then
    Exit;
  Result := (M.DeclaresOperator(LScope, 'implicit')) or
    (AExplicitToo and (M.DeclaresOperator(LScope, 'explicit')));
end;

// Sum a conservative match score of the call's args against a param list.
// Takes the params the caller already built (SelectOverload had called
// ParamsOf twice per fitting candidate - one TArray allocation each).
// The rules are the project's ScoreCandidate's, through the shared helpers
// (ArgShapeRejects, ArgCatRejects, ArgStructRejects, IsCharLiteralExpr).
function TPasSemaTyper.ScoreArgs(ACall: Integer;
  const AParams: TArray<Integer>): Integer;
var
  LArg, LIdx, LScore, LK, LL, LR: Integer;
begin
  Result := 0;
  LArg := CallFirstArg(T, ACall);
  LIdx := 0;
  while (LArg <> NIL_NODE) and (LIdx <= High(AParams)) do
  begin
    // The empty slot of a trailing comma is not an argument (CallArgCount).
    if Kind(LArg) = nkMissing then
      Break;
    if (Kind(LArg) = nkAmbiguous) and (M.AmbigReadingOf(LArg) = arCompare) then
    begin
      // `F(A < B, C > (D))` (16.3.1): the arguments it stands for, each
      // comparison a Boolean of its own with no node to read a shape off.
      for LK := 0 to M.AmbigArgCount(LArg) - 1 do
      begin
        if LIdx > High(AParams) then
          Exit;
        if M.AmbigArg(LArg, LK, LL, LR) then
          LScore := ScoreArg(NIL_NODE, CompareType(LL, LR), AParams[LIdx])
        else
          LScore := ScoreArg(LL, M.ExprType[LL], AParams[LIdx]);
        if LScore < 0 then
          Exit(-1);
        Inc(Result, LScore);
        Inc(LIdx);
      end;
    end
    else
    begin
      LScore := ScoreArg(LArg, M.ExprType[LArg], AParams[LIdx]);
      if LScore < 0 then
        Exit(-1);
      Inc(Result, LScore);
      Inc(LIdx);
    end;
    LArg := Sib(LArg);
  end;
end;

function TPasSemaTyper.CompareType(ALeft, ARight: Integer): Integer;
begin
  Result := NIL_SYM;
  if (M.ExprType[ALeft] <> NIL_SYM) and (M.ExprType[ARight] <> NIL_SYM) then
    Result := Bool;
end;

function TPasSemaTyper.ScoreArg(AArg, AAt, AParam: Integer): Integer;
var
  LDef, LPt, LCore, LElem: Integer;
begin
  // A parameter's type is a type identifier or `array of` (6.2.6): an
  // array definition in the slot is an open array, which names no type.
  LDef := M.Symbols[AParam].TypeNode;
  if (LDef <> NIL_NODE) and (Kind(LDef) = nkArrayType) then
    Exit(OpenArrayScore(AArg, AAt, LDef));
  LPt := M.Symbols[AParam].TypeSym;
  // A `[...]` for a dynamic array of a type this unit can see is scored by
  // its elements, as for the open array; one of an element not known here
  // (`TArray<string>`, an instantiation) gives no evidence. Peeled only
  // when it may be one: this runs for every argument of every candidate.
  if (AArg <> NIL_NODE) and (LPt <> NIL_SYM) and
     (Kind(AArg) in [nkSetCtor, nkParen]) then
  begin
    LCore := PeelParens(T, AArg);
    if Kind(LCore) = nkSetCtor then
    begin
      LDef := ArrayDefOf(LPt);
      if (LDef <> NIL_NODE) and IsDynArrayDef(LDef) then
      begin
        LElem := ElemTypeSym(PasArrayElemNode(T, LDef));
        if LElem = NIL_SYM then
          Exit(0);
        Exit(CtorScore(LCore, LElem, ctDynArray));
      end;
    end;
  end;
  Result := ScoreArgAs(AArg, AAt, LPt);
  if Result > 0 then
    Result := 2 * Result;
end;

function TPasSemaTyper.ScoreArgAs(AArg, AAt, APt: Integer): Integer;
var
  LCore, LPt, LCAt, LCPt: Integer;
  LParCat: TSemaTypeCat;
begin
  Result := 0;
  LPt := APt;
  if LPt = NIL_SYM then
    Exit;
  LParCat := CatOf(LPt);
  if AArg <> NIL_NODE then
  begin
    LCore := PeelParens(T, AArg);
    // A class TYPE NAME is a class reference (15.2.1), not an instance:
    // `Reg(TFoo)` takes Reg(C: TFooClass) over Reg(O: TFoo) - the
    // project scorer's rule (audit E3-25, local/probe-b34 P1). Its own
    // class's reference scores exact, another's assignable.
    if (Kind(LCore) in [nkIdent, nkMember]) and (AAt <> NIL_SYM) and
       (Head(LCore) = AAt) and (M.Symbols[AAt].Kind = skType) and
       (CatOf(AAt) = tcClass) then
    begin
      case LParCat of
        tcClassOf:
          if ClassRefTarget(LPt) = WeakAliasEnd(AAt) then
            Result := 2
          else
            Result := 1;
        tcClass, tcRecord, tcInterface, tcInteger, tcFloat, tcBoolean,
        tcChar, tcString, tcEnum, tcSet, tcArray:
          Result := -1;
      end;
      Exit;
    end;
    // An anonymous method, a procedure designator, a `[...]` against a
    // parameter it cannot be passed to - provable at the node, typed or
    // not (neither has a type of its own here).
    if ArgShapeRejects(Kind(LCore), IsProcDesignator(LCore), LParCat,
       M.Symbols[LPt].Kind = skGenericParam) then
      Exit(-1);
    // A one-character literal - through parentheses, or both branches of
    // an inline `if` - is typed `string` here but is a Char constant:
    // `Char` fits it best, `AnsiChar` below a string parameter
    // (local/probe-b31 O2, probe-b32 P1).
    if (LParCat = tcChar) and IsCharLiteralExpr(T, LCore) then
    begin
      if PasBuiltinIsChar(M, WeakAliasEnd(LPt), FPlatform) then
        Exit(3);
      Exit(1);
    end;
  end;
  if AAt <> NIL_SYM then
  begin
    // The same type under two names is an exact match: a weak alias
    // (WeakAliasEnd), one type under two seeded names (Integer /
    // LongInt, Char / WideChar - PasBuiltinCanonSym, audit A3-17).
    LCAt := PasBuiltinCanonSym(M, WeakAliasEnd(AAt), FPlatform);
    LCPt := PasBuiltinCanonSym(M, WeakAliasEnd(LPt), FPlatform);
    if (AAt = LPt) or (LCAt = LCPt) then
      Result := 2
    else if ArgCatRejects(LParCat, CatOf(AAt)) or
       (ArgStructNeedsConv(LParCat, CatOf(AAt)) and
        ArgStructRejects(LParCat, CatOf(AAt),
          DeclaresConversion(LPt, True),
          DeclaresConversion(AAt, True))) then
      Result := -1
    else if Assignable(LPt, AAt) then
      Result := 1;
  end;
end;

{ ScoreArg for an OPEN-ARRAY parameter whose `array of` definition is ADef:
  OpenArrayArgFit, the rule, over what this unit knows - the project's
  OpenArrFitX reads the same in project space - and a `[...]` by its
  elements (CtorScore). The element is a builtin or a type of this unit
  (ElemTypeSym), `array of const`'s System.TVarRec known here only as the
  record of that name. An argument typed by another unit's type is untyped
  here and decides nothing, and so do a generic parameter and a type name
  (a class reference, no variable). An array whose type is written INLINE
  at the declaration the argument names - a variable, a field, a typed
  constant, an open-array parameter passed on - has no type to be typed by:
  its element is read off that declaration, `array of const`'s as TVarRec. }
function TPasSemaTyper.OpenArrayScore(AArg, AAt, ADef: Integer): Integer;
var
  LCore, LElem, LArgDef, LArgElem, LElemFit, LSym: Integer;
  LOfConst: Boolean;
  LArgCat: TSemaTypeCat;

  // Is ASym the record System.TVarRec, as far as this unit can tell?
  function IsVarRec(ASym: Integer): Boolean;
  begin
    Result := (CatOf(ASym) = tcRecord) and
      (M.Symbols[WeakAliasEnd(ASym)].NameLower = 'tvarrec');
  end;

  // Is the type ASym the parameter's element type?
  function IsElem(ASym: Integer): Boolean;
  begin
    if LOfConst then
      Result := IsVarRec(ASym)
    else
      Result := (ASym = LElem) or
        (PasBuiltinCanonSym(M, WeakAliasEnd(ASym), FPlatform) =
         PasBuiltinCanonSym(M, WeakAliasEnd(LElem), FPlatform));
  end;

begin
  Result := 0;
  LOfConst := T.Nodes[ADef].Aux = 1;
  LElem := NIL_SYM;
  if not LOfConst then
  begin
    LElem := ElemTypeSym(PasArrayElemNode(T, ADef));
    if LElem = NIL_SYM then
      Exit;
  end;
  LCore := NIL_NODE;
  if AArg <> NIL_NODE then
    LCore := PeelParens(T, AArg);
  if (LCore <> NIL_NODE) and (Kind(LCore) = nkSetCtor) then
  begin
    if LOfConst then
      Exit(CtorScore(LCore, LElem, ctArrayOfConst));
    Exit(CtorScore(LCore, LElem, ctOpenArray));
  end;
  LArgDef := NIL_NODE;
  if AAt <> NIL_SYM then
  begin
    if (M.Symbols[AAt].Kind = skGenericParam) or
       (LCore <> NIL_NODE) and (Kind(LCore) in [nkIdent, nkMember]) and
       (Head(LCore) = AAt) and (M.Symbols[AAt].Kind = skType) then
      Exit;
    LArgCat := CatOf(AAt);
    if LArgCat = tcArray then
      LArgDef := ArrayDefOf(AAt);
  end
  else
  begin
    if (LCore = NIL_NODE) or not (Kind(LCore) in [nkIdent, nkMember]) then
      Exit;
    LSym := Head(LCore);
    if (LSym = NIL_SYM) or
       not (M.Symbols[LSym].Kind in [skVar, skParam, skField, skConst]) then
      Exit;
    LArgDef := M.Symbols[LSym].TypeNode;
    if (LArgDef = NIL_NODE) or (Kind(LArgDef) <> nkArrayType) then
      Exit;
    LArgCat := tcArray;
  end;
  LElemFit := 0;
  if LArgDef <> NIL_NODE then
    if T.Nodes[LArgDef].Aux = 1 then
    begin
      // `array of const` passed on: an array of TVarRec.
      if LOfConst or IsVarRec(LElem) then
        LElemFit := 1
      else
        LElemFit := -1;
    end
    else if PasArrayDims(T, LArgDef) = 1 then
    begin
      LArgElem := ElemTypeSym(PasArrayElemNode(T, LArgDef));
      if LArgElem <> NIL_SYM then
        if IsElem(LArgElem) then
          LElemFit := 1
        else
          LElemFit := -1;
    end;
  Result := OpenArrayArgFit(LArgCat, (AAt <> NIL_SYM) and IsElem(AAt),
    LElemFit);
end;

{ ScoreArg for the `[...]` ACtor passed to ATarget - an open or a dynamic
  array of AElem, `array of const` (AElem NIL_SYM): CtorElemFit over each
  element as this unit types it - its category, ScoreArgAs against AElem,
  and against a dynamic array whether an exact element is a constant
  (IsConstExpr, or a type name: a class reference) - the worst deciding; the
  project's CtorFitX reads the same in project space. A range makes the
  brackets a set constructor, which no array takes. }
function TPasSemaTyper.CtorScore(ACtor, AElem: Integer;
  ATarget: TSemaCtorTarget): Integer;
var
  LKid, LAt, LDef, LFit, LElemEnd: Integer;
  LFirst, LOfConst, LParChar, LParString, LStatic, LConst: Boolean;
  LCat: TSemaTypeCat;
begin
  Result := 0;
  LOfConst := ATarget = ctArrayOfConst;
  LParChar := False;
  LParString := False;
  if not LOfConst then
  begin
    LElemEnd := WeakAliasEnd(AElem);
    LParChar := PasBuiltinIsChar(M, LElemEnd, FPlatform);
    LParString := not LParChar and PasBuiltinIsUString(M, LElemEnd, FPlatform);
  end;
  LFirst := True;
  LKid := Child(ACtor);
  while LKid <> NIL_NODE do
  begin
    if Kind(LKid) = nkRange then
      Exit(-1);
    LAt := M.ExprType[LKid];
    LCat := tcUnknown;
    if (LAt <> NIL_SYM) and (M.Symbols[LAt].Kind <> skGenericParam) then
      LCat := CatOf(LAt);
    LStatic := False;
    if LCat = tcArray then
    begin
      LDef := ArrayDefOf(LAt);
      LStatic := (LDef <> NIL_NODE) and (T.Nodes[LDef].Aux <> 1) and
        not IsDynArrayDef(LDef);
    end;
    LFit := 0;
    LConst := False;
    if not LOfConst then
    begin
      LFit := ScoreArgAs(LKid, LAt, AElem);
      // Only an exact element against a dynamic array asks.
      LConst := (ATarget = ctDynArray) and (LFit >= 2) and
        (IsConstExpr(LKid) or (LAt <> NIL_SYM) and
         (M.Symbols[LAt].Kind = skType) and
         (Kind(LKid) in [nkIdent, nkMember]) and (Head(LKid) = LAt));
    end;
    LFit := CtorElemFit(ATarget, LCat, LStatic,
      IsCharLiteralExpr(T, LKid) or (LCat = tcChar) and
      PasBuiltinIsChar(M, WeakAliasEnd(LAt), FPlatform),
      LConst, LParChar, LParString, LFit);
    if LFit < 0 then
      Exit(-1);
    if LFirst or (LFit < Result) then
      Result := LFit;
    LFirst := False;
    LKid := Sib(LKid);
  end;
end;

{ The type symbol the type node ANode names when this unit can see it - a
  builtin or a type of its own, named or qualified; NIL_SYM for a generic
  parameter, an instantiation, an inline type and an imported type. }
function TPasSemaTyper.ElemTypeSym(ANode: Integer): Integer;
begin
  Result := NIL_SYM;
  if (ANode = NIL_NODE) or not (Kind(ANode) in [nkIdent, nkMember]) then
    Exit;
  Result := Head(ANode);
  if (Result <> NIL_SYM) and
     not (M.Symbols[Result].Kind in [skType, skBuiltinType]) then
    Result := NIL_SYM;
end;



// Pick the best overload for typing/navigation; emit an arg-count diagnostic
// only when it is unambiguous. Returns the chosen routine's result type.
{ The INTERFACE-section counterpart of an implementation-section routine head,
  or NIL_SYM.

  6.3.1: overloads declared in the IMPLEMENTATION section join the interface
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
  LTrailing, LAnyOverload: Boolean;
begin
  LAnyOverload := False;
  LArgs := CallArgCount(M, ACall, LTrailing);
  // An nkAmbiguous argument whose head nothing has bound yet (16.3.1): one
  // argument or several, so no overload can be chosen and no count judged.
  if LArgs < 0 then
    Exit(NIL_SYM);
  LBest := AHead; LBestScore := -1;
  LAnyFit := False; LAllHaveParams := True; LAnyVariadic := False;
  LMinReq := MaxInt; LMaxTot := -1;

  LIfaceHead := InterfaceCounterpart(AHead);
  LCand := AHead;
  while LCand <> NIL_SYM do
  begin
    if M.Symbols[LCand].Kind <> skRoutine then
      Break;
    if M.RoutineSaysOverload(LCand) then
      LAnyOverload := True;
    if M.Symbols[LCand].MemberScope = NIL_SCOPE then
      LAllHaveParams := False   // e.g. a builtin - no param info
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
      // A `varargs` directive (cdecl external) accepts any number of
      // trailing args - stamped by the resolver (StampRetainedFlags).
      LVariadic := sfVarArgs in M.Symbols[LCand].Flags;
      if LVariadic then
        LAnyVariadic := True;
      if LReq < LMinReq then LMinReq := LReq;
      if LTot > LMaxTot then LMaxTot := LTot;
      if LVariadic or ArityFits(LArgs, LReq, LTot, LTrailing) then
      begin
        LAnyFit := True;
        LScore := ScoreArgs(ACall, LParams);
        if LScore > LBestScore then
        begin
          LBestScore := LScore;
          LBest := LCand;
        end;
      end;
    end;
    LCand := M.Symbols[LCand].NextOverload;
    // 6.3.1: the interface section's overloads of the same name are part of the
    // set, and they are a separate chain in a separate scope - see
    // InterfaceCounterpart.
    if LCand = NIL_SYM then
    begin
      LCand := LIfaceHead;
      LIfaceHead := NIL_SYM;
    end;
  end;

  // Every candidate the arity admits was REJECTED by an argument (score -1):
  // none of them is the callee, whatever the uses clause says - the call is
  // dcc's E2250, or (with imports) a used unit's overload that fits. Neither
  // the head nor its result type is the answer (audit A4-09: a local
  // `Pick(O: TFoo)` typed `Pick(11)` that calls an imported Pick(Integer)).
  if LAnyFit and (LBestScore < 0) then
    Exit(NIL_SYM);

  M.CallTarget.AddOrSetValue(ACall, LBest);

  // Arg-count is only reliable when the candidate set is complete:
  //  - a plain GLOBAL routine (methods/constructors are inherited/overloaded
  //    across the class hierarchy, which we don't model),
  //  - the unit has NO `uses` (with imports, same-named overloads can live in
  //    another unit and Delphi merges them - we don't yet; cross-unit overload
  //    merging is a later slice), and
  //  - the CALL SITE is not inside a struct. That last one is the same rule
  //    from the other end, and it is not the ancestor walk the To-do assumed:
  //    inside a method, dcc searches the type's members - own AND inherited -
  //    before the unit's globals, so a same-named global we resolved to may
  //    not be the real callee at all. Walking the same-unit ancestry would
  //    not be enough to prove otherwise, because EVERY class also inherits
  //    TObject, which a `uses`-less unit has no model of (no System unit is
  //    loaded, and TObject is deliberately not seeded) - `ToString(X)` in a
  //    method of such a unit really can mean TObject.ToString. Since the
  //    candidate set inside a method is therefore never provably complete,
  //    the diagnostic stays out of methods entirely and keeps its
  //    zero-false-positive promise where it does fire: unit-level code and
  //    plain global routines. Probed: a global `Bar` beside an inherited
  //    `TBase.Bar(A: Integer)` used to report a false E2034 on `Bar(1)`,
  //    which dcc compiles.
  //  - and no candidate says `overload`: the search then goes on past this
  //    unit into System (6.3.1, 3.3.2 step 7), so a uses-less unit's own
  //    `Pos(C: Char; const S: string; X, Y: Integer); overload;` leaves
  //    System's `Pos('ab', 'xabc')` callable (dcc64 37.0, local/probe-b25
  //    P4). Phase 1 has no System; CheckCalls measures such a set.
  var LGlobal := (M.Scopes[M.Symbols[AHead].Scope].Kind in
    [sckUnit, sckImplementation]) and (Length(M.UsesList) = 0) and
    (M.EnclosingStructSym(ACall) = NIL_SYM) and not LAnyOverload;

  // Deterministic arg-count diagnostic (independent of implicit rules).
  // Not on a list the parser cut short (`Foo(1, &4M4)` - ParseArgList adopts
  // an nkError when `)` never came): the parse error is the diagnostic.
  if LGlobal and LAllHaveParams and not LAnyVariadic and not LAnyFit and
     (LMaxTot >= 0) and not ArgListTruncated(ACall) then
  begin
    // After a trailing comma the verdict is dcc's: a parameter still due is
    // E2029 (the comma promised it), anything else E2034 (no default to
    // stand in, or too many).
    if LTrailing then
    begin
      if LArgs < LMaxTot then
        Diag('E2029', SE2029_ExpressionExpectedRParen, ACall)
      else
        Diag('E2034', SE2034_TooManyActualParams, ACall);
    end
    else if LArgs < LMinReq then
      Diag('E2035', SE2035_NotEnoughActualParams, ACall)
    else if LArgs > LMaxTot then
      Diag('E2034', SE2034_TooManyActualParams, ACall);
  end;

  // When NO local candidate admits the argument count, the real callee is
  // most likely a same-named overload in another unit (e.g. SysUtils calling
  // the 3-arg Winapi.Windows.GetEnvironmentVariable while declaring a 1-arg
  // one itself) - claiming the local head's result type would poison E2010.
  if LAllHaveParams and not LAnyVariadic and not LAnyFit and (LMaxTot >= 0) then
    Exit(NIL_SYM);

  // Same caution for argument TYPES: the unit imports something, and the
  // arity-fitting local candidates showed NO type evidence at all for a call
  // with typed arguments (best score 0 - not even one loosely-assignable
  // arg). dcc merges same-named overloads from used units into one candidate
  // set; we cannot in a pure per-unit pass - so don't claim the local result
  // type (a local `Pick(Boolean)` would mistype `Pick(11)` that really calls
  // an imported `Pick(Integer)`, poisoning E2010). The cross-unit pass
  // (CrossType) retypes the call against the properly MERGED set.
  if (Length(M.UsesList) > 0) and LAnyFit and (LBestScore = 0) then
  begin
    var LArg := CallFirstArg(T, ACall);
    while LArg <> NIL_NODE do
    begin
      if M.ExprType[LArg] <> NIL_SYM then
        Exit(NIL_SYM);   // a typed arg matched nothing local - stay silent
      LArg := Sib(LArg);
    end;
  end;

  Result := M.Symbols[LBest].TypeSym;   // result type of the chosen overload
end;

{ The RESULT type of the procedural type ASym (through plain aliases), the
  type a value of it has once CALLED; NIL_SYM for a procedure type or anything
  that is not a procedural type at all. }
function TPasSemaTyper.ProcTypeResult(ASym: Integer): Integer;
var
  LDepth, LDef, LChild: Integer;
begin
  Result := NIL_SYM;
  for LDepth := 1 to 8 do
  begin
    if (ASym = NIL_SYM) or (M.Symbols[ASym].Kind <> skType) then
      Exit;
    LDef := TypeDefNode(ASym);
    if LDef = NIL_NODE then
      Exit;
    case Kind(LDef) of
      nkIdent:
        ASym := M.RefMap[LDef];   // alias link - follow it
      nkProcType:
        begin
          LChild := Child(LDef);
          if (LChild <> NIL_NODE) and (Kind(LChild) = nkParams) then
            LChild := Sib(LChild);   // the result type follows the list
          if (LChild = NIL_NODE) or (Kind(LChild) = nkDirective) then
            Exit;   // a procedure type (`procedure stdcall`): no result
          Exit(Head(LChild));
        end;
    else
      Exit;
    end;
  end;
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
    // Not a designator (`GetFunc(1)(2)`, `Handlers[I](Sender)`): the callee
    // is an expression whose type, if procedural, is called.
    Exit(ProcTypeResult(M.ExprType[LCallee]));
  case M.Symbols[LHead].Kind of
    skType, skBuiltinType:
      Result := LHead;                    // type cast T(x) -> T
    skRoutine:
      // A seeded intrinsic has no declaration to select an overload from -
      // its result follows the rules the seed documents (4.11).
      if sfBuiltin in M.Symbols[LHead].Flags then
        Result := IntrinsicResult(N, LHead)
      else
        Result := SelectOverload(N, LHead); // choose overload + maybe arg-count
    skVar, skConst, skField, skParam, skProperty:
      // A VALUE of a procedural type called with arguments -
      // `Gateway(True, False).FillDevices` where Gateway: reference to
      // function(...): IPaymentServer. The call has the procedural type's
      // RESULT type; the project-level typer takes the same hop through
      // ProcResultX for the cross-unit case.
      Result := ProcTypeResult(M.Symbols[LHead].TypeSym);
  end;
end;

{ The widened ordinal type dcc gives Pred/Succ/Low/High/Abs of an integer
  ASym: NativeInt keeps its (platform-sized) name, a 64-bit one is Int64, and
  everything narrower - Byte, Word, SmallInt, ShortInt, Cardinal, a subrange -
  is Integer. UInt64 too: `Succ(U64)` is an Int64 under dcc. }
function TPasSemaTyper.WidenOrdinal(ASym: Integer): Integer;
begin
  // An alias of a builtin is that builtin (`TBig = Int64`, audit A4-14).
  ASym := WeakAliasEnd(ASym);
  if (ASym <> NIL_SYM) and (M.Symbols[ASym].Kind = skBuiltinType) then
  begin
    if (ASym = NInt) or (ASym = NUInt) then
      Exit(NInt);
    if RankOf(ASym) = 4 then
      Exit(I64);
  end;
  Result := Int;
end;

// The ordinal value of a name bound here: an enumeration value of this
// unit, a true constant (its value, followed), True / False.
function TPasSemaTyper.OrdNameValue: TSemaOrdNameValue;
begin
  Result :=
    function(ANode, ADepth: Integer; out AValue: Int64): Boolean
    var
      LName, LSym, LDecl: Integer;
    begin
      Result := False;
      AValue := 0;
      LName := ANode;
      if Kind(LName) = nkMember then
      begin
        LName := Child(LName);
        while (LName <> NIL_NODE) and (Sib(LName) <> NIL_NODE) do
          LName := Sib(LName);
      end;
      if (LName = NIL_NODE) or (Kind(LName) <> nkIdent) then
        Exit;
      LSym := M.RefMap[LName];
      if LSym = NIL_SYM then
        Exit;
      LDecl := M.Symbols[LSym].DeclNode;
      case M.Symbols[LSym].Kind of
        skEnumValue:
          Result := (LDecl <> NIL_NODE) and
            (T.Nodes[LDecl].Parent <> NIL_NODE) and
            (Kind(T.Nodes[LDecl].Parent) = nkEnumValue) and
            EnumElemValue(T, T.Nodes[LDecl].Parent, ADepth, OrdNameValue(),
              AValue);
        skConst:
          if sfBuiltin in M.Symbols[LSym].Flags then
          begin
            Result := (M.Symbols[LSym].NameLower = 'true') or
              (M.Symbols[LSym].NameLower = 'false');
            AValue := Ord(M.Symbols[LSym].NameLower = 'true');
          end
          else if (M.Symbols[LSym].TypeNode = NIL_NODE) and
                  (LDecl <> NIL_NODE) and (T.Nodes[LDecl].Parent <> NIL_NODE)
                  and (Kind(T.Nodes[LDecl].Parent) = nkConstDecl) then
            Result := OrdinalNodeValue(T, Sib(LDecl), ADepth, OrdNameValue(),
              AValue);
      end;
    end;
end;

{ ConstExprKind's view of a node of this unit (TSemaConstFacts): a name by
  its binding here - a true constant's category and Typed read off its
  initializer - anything else by its ExprType; an array or a string written
  inline at a declaration (`A: array of Integer`, `S: string[10]`) by that
  declaration's type node. }
function TPasSemaTyper.ConstFacts: TSemaConstFactsFunc;
begin
  Result :=
    function(ANode, ADepth: Integer): TSemaConstFacts
    var
      LSym, LType, LDecl, LInit, LDef: Integer;
    begin
      Result := Default(TSemaConstFacts);
      ANode := PeelParens(T, ANode);
      if ANode = NIL_NODE then
        Exit;
      Result.Role := scrValue;
      case Kind(ANode) of
        nkIntLit: Result.Cat := tcInteger;
        nkRealLit: Result.Cat := tcFloat;
        nkCaretChar: Result.Cat := tcChar;
        nkNilLit: Result.Cat := tcNil;
        nkStrLit:
          if IsOneCharLiteralNode(T, ANode) then
            Result.Cat := tcChar
          else
          begin
            Result.Cat := tcString;
            Result.RunTime := True;   // a long string: `High(KS)` is E2026
          end;
      end;
      if Result.Cat <> tcUnknown then
        Exit;
      LType := M.ExprType[ANode];
      LDef := NIL_NODE;
      LSym := NIL_SYM;
      if Kind(ANode) in [nkIdent, nkMember, nkTypeArgs] then
        LSym := Head(ANode);
      if LSym <> NIL_SYM then
        case M.Symbols[LSym].Kind of
          skEnumValue:
            Result.Role := scrConst;
          skConst:
            if sfBuiltin in M.Symbols[LSym].Flags then
              Result.Role := scrConst   // True, False, MaxInt
            else if M.Symbols[LSym].TypeNode <> NIL_NODE then
              LDef := M.Symbols[LSym].TypeNode   // a typed constant: a value
            else
            begin
              Result.Role := scrConst;
              LDecl := M.Symbols[LSym].DeclNode;
              if (LDecl <> NIL_NODE) and (T.Nodes[LDecl].Parent <> NIL_NODE) and
                 (Kind(T.Nodes[LDecl].Parent) = nkConstDecl) then
              begin
                LInit := Sib(LDecl);
                Result.Typed := ConstExprKind(T, LInit, ADepth + 1,
                  ConstFacts()) = sckTyped;
                if LType = NIL_SYM then
                begin
                  // The type of the value it names.
                  var LV := ConstFacts()(LInit, ADepth + 1);
                  Result.Cat := LV.Cat;
                  Result.RunTime := LV.RunTime;
                  Exit;
                end;
              end;
            end;
          skType, skBuiltinType:
            begin
              Result.Role := scrType;
              LType := LSym;
            end;
          skRoutine:
            if sfBuiltin in M.Symbols[LSym].Flags then
            begin
              Result.Role := scrIntrinsic;
              Result.Intrinsic := M.Symbols[LSym].NameLower;
            end
            else
              Result.Role := scrOther;
          skVar, skParam, skField, skProperty:
            LDef := M.Symbols[LSym].TypeNode;
        else
          Result.Role := scrOther;
        end;
      if (LDef <> NIL_NODE) and (Kind(LDef) in [nkArrayType, nkStringType]) then
      begin
        // An inline array: static with an index, else dynamic - or an open
        // array, a parameter's. An inline `string[N]` is a short string.
        if Kind(LDef) = nkStringType then
          Result.Cat := tcString
        else
        begin
          Result.Cat := tcArray;
          Result.StaticArray := (Child(LDef) <> NIL_NODE) and
            (Sib(Child(LDef)) <> NIL_NODE);
          Result.OpenArray := not Result.StaticArray and
            (M.Symbols[LSym].Kind = skParam);
          Result.RunTime := not Result.StaticArray and not Result.OpenArray;
        end;
        Exit;
      end;
      Result.Cat := CatOf(LType);
      case Result.Cat of
        tcArray:
          begin
            LDef := ArrayDefOf(LType);
            if LDef <> NIL_NODE then
            begin
              Result.RunTime := IsDynArrayDef(LDef);
              Result.StaticArray := not Result.RunTime;
            end;
          end;
        tcString:
          begin
            // A long string, but ShortString or a `string[N]` type.
            LType := WeakAliasEnd(LType);
            LDef := NIL_NODE;
            if M.Symbols[LType].Kind = skType then
              LDef := TypeDefNode(LType);
            Result.RunTime := (LType <> SStr) and
              ((LDef = NIL_NODE) or (Kind(LDef) <> nkStringType));
          end;
      end;
    end;
end;

{ Is argument ANode a constant dcc folds (ConstExprKind) - Ord / Hi / Lo /
  Swap of one are Integer, 4.11.4: `Ord(High(Char))`, `Hi(SizeOf(T))`,
  `Swap(Byte(5))`, `Ord(N + 1)` as `Ord('A')`. A typed constant is a
  variable here. }
function TPasSemaTyper.IsConstArg(ANode: Integer): Boolean;
begin
  Result := ConstExprKind(T, ANode, 0, ConstFacts()) <> sckNone;
end;

{ Is ANode a constant a `[...]`'s element is ranked as against a dynamic
  array (CtorElemFit) - one dcc folds and reads by VALUE (ConstExprKind's
  sckValue): a literal, a true constant, an enumeration value, an operator
  or an intrinsic over constants (`N + 1`, `Low(Integer)`). A typecast,
  Default, Ptr and `nil` are values of their type (sckTyped), exact as any
  value: `[Integer(5)]` takes TArray<Integer> over `array of const`. }
function TPasSemaTyper.IsConstExpr(ANode: Integer): Boolean;
begin
  Result := ConstExprKind(T, ANode, 0, ConstFacts()) = sckValue;
end;

// What Ord and the Pred / Succ / Low / High integer rule read of argument
// ANode (NIL_NODE: a type) of type ASym - TSemaOrdFacts.
function TPasSemaTyper.OrdFacts(ANode, ASym: Integer): TSemaOrdFacts;
var
  LB: Integer;
begin
  Result := Default(TSemaOrdFacts);
  Result.Cat := CatOf(ASym);
  Result.IsConst := (ANode <> NIL_NODE) and IsConstArg(ANode);
  if Result.Cat = tcInteger then
    LB := StorageBase(ASym)
  else
    LB := WeakAliasEnd(ASym);
  if LB = NIL_SYM then
    Exit;
  if M.Symbols[LB].Kind = skBuiltinType then
  begin
    Result.Builtin := M.Symbols[LB].NameLower;
    Result.Rank := M.Symbols[LB].NumRank;
  end
  else if M.Symbols[LB].Kind = skType then
    Result.HasRange := OrdinalDefRange(T, TypeDefNode(LB), OrdNameValue(),
      Result.Lo, Result.Hi);
end;

{ Pred / Succ / Low / High of an ordinal of type ASym (4.11.4): an integer
  by OrdStepAnswer; an enumeration, Char or Boolean keeps its type, a
  subrange of one is its base (`Pred(CS)` of a `'a'..'z'` is Char, of an
  `e1..e2` the enumeration - local/probe-b38). NIL_SYM for a non-ordinal. }
function TPasSemaTyper.OrdStep(ASym: Integer): Integer;
var
  LB, LDef, LLo, LBound: Integer;
begin
  Result := NIL_SYM;
  case CatOf(ASym) of
    tcInteger:
      Result := OpSym(OrdStepAnswer(OrdFacts(NIL_NODE, ASym)), ASym, NIL_SYM,
        False);
    tcEnum:
      begin
        Result := ASym;
        LB := WeakAliasEnd(ASym);
        if (LB = NIL_SYM) or (M.Symbols[LB].Kind <> skType) then
          Exit;
        LDef := TypeDefNode(LB);
        if (LDef = NIL_NODE) or (Kind(LDef) <> nkSubrange) then
          Exit;
        LLo := Child(LDef);
        if (LLo = NIL_NODE) or (Kind(LLo) <> nkIdent) then
          Exit;
        LBound := M.RefMap[LLo];
        if (LBound <> NIL_SYM) and
           (M.Symbols[LBound].Kind in [skEnumValue, skConst]) and
           (M.Symbols[LBound].TypeSym <> NIL_SYM) then
          Result := M.Symbols[LBound].TypeSym;
      end;
    tcChar:
      begin
        LB := WeakAliasEnd(ASym);
        if (LB <> NIL_SYM) and (M.Symbols[LB].Kind = skBuiltinType) then
          Result := LB
        else
          Result := Chr;
      end;
    tcBoolean:
      Result := ASym;
  end;
end;

{ The nkArrayType node type symbol ASym denotes, through plain aliases;
  NIL_NODE for anything else. An ANONYMOUS inline array (`A: array of T`) has
  no type symbol and so answers nothing here - the project level reads the
  declaration's own type node for those. }
function TPasSemaTyper.ArrayDefOf(ASym: Integer): Integer;
var
  LDepth, LDef: Integer;
begin
  Result := NIL_NODE;
  for LDepth := 1 to 8 do
  begin
    if (ASym = NIL_SYM) or (M.Symbols[ASym].Kind <> skType) then
      Exit;
    LDef := TypeDefNode(ASym);
    if LDef = NIL_NODE then
      Exit;
    case Kind(LDef) of
      nkArrayType:
        Exit(LDef);
      nkIdent:
        ASym := M.RefMap[LDef];   // alias link - follow it
    else
      Exit;
    end;
  end;
end;

// `array of T` (no index child, not `array of const`) - the shape whose Length
// and High are NativeInt rather than Integer.
function TPasSemaTyper.IsDynArrayDef(ADef: Integer): Boolean;
var
  LFirst: Integer;
begin
  LFirst := Child(ADef);
  Result := (LFirst <> NIL_NODE) and (Sib(LFirst) = NIL_NODE) and
    (T.Nodes[ADef].Aux <> 1);
end;

{ The type of a STATIC array's bounds (its first index dimension, the one
  Low/High read): an explicit `lo..hi` by the category of its low bound - an
  integer literal is Integer, a character literal Char, True/False Boolean, an
  enum member its enum; a NAMED index type by the ordinal rule (`array[Word]`
  bounds are Integer, `array[TEnum]` bounds are TEnum). NIL_SYM when the bound
  cannot be read. }
function TPasSemaTyper.ArrayBoundType(ADef: Integer): Integer;
var
  LIdx, LLo, LSym: Integer;
begin
  Result := NIL_SYM;
  LIdx := Child(ADef);
  if (LIdx = NIL_NODE) or (Sib(LIdx) = NIL_NODE) then
    Exit;   // dynamic array - the caller has its own answer
  case Kind(LIdx) of
    nkSubrange:
      begin
        LLo := Child(LIdx);
        case CatOfSubrangeBound(LLo) of
          tcInteger: Exit(Int);
          tcChar: Exit(Chr);
          tcBoolean: Exit(Bool);
        end;
        // `eA..eC` - an enum member's type, which is the bound type itself;
        // only an integer one widens (ArrayBoundTypeX's rule; `High(A)` of
        // an `array[eA..eC]` is TE, dcc64 - audit A4-16). A signed literal
        // was categorized above, so what is left is a bare name.
        if (LLo <> NIL_NODE) and (Kind(LLo) = nkIdent) then
        begin
          LSym := M.RefMap[LLo];
          if (LSym <> NIL_SYM) and
             (M.Symbols[LSym].Kind in [skConst, skEnumValue]) and
             (M.Symbols[LSym].TypeSym <> NIL_SYM) then
          begin
            LSym := M.Symbols[LSym].TypeSym;
            case CatOf(LSym) of
              tcInteger: Exit(WidenOrdinal(LSym));
              tcEnum, tcChar, tcBoolean: Exit(LSym);
            end;
          end;
        end;
      end;
    nkIdent:
      begin
        LSym := M.RefMap[LIdx];
        if (LSym <> NIL_SYM) and
           (M.Symbols[LSym].Kind in [skType, skBuiltinType]) then
          Exit(OrdStep(LSym));
      end;
  end;
end;

{ The result type of a call to the seeded intrinsic AHead (4.11), by the shape
  PasTree.Sema.Builtins documents for its name. Argument types are this
  typer's own ExprType - a type-name argument (`Low(TEnum)`, `Default(TRec)`,
  `SizeOf(TRec)`) reads as that type through TypeOfIdent's cast rule, which
  is exactly what the type-argument intrinsics want. NIL_SYM wherever a rule
  needs something this unit cannot see (a cross-unit array type, System's
  TTypeKind, a Variant operand of Abs). }
function TPasSemaTyper.IntrinsicResult(ACall, AHead: Integer): Integer;
var
  LShape: TPasIntrinsicResult;
  LArg, LA, LAC, LDef, LCur: Integer;
  LSame: Boolean;
  LFacts, LNextF: TSemaOpFacts;
begin
  Result := NIL_SYM;
  LShape := PasIntrinsicResult(M.Symbols[AHead].NameLower);
  if LShape = irNone then
    Exit;
  // The first argument, if any - a bare `Pi` is an nkIdent with no children.
  LArg := NIL_NODE;
  if (Kind(ACall) = nkCall) and (Child(ACall) <> NIL_NODE) then
    LArg := CallFirstArg(T, ACall);
  LA := NIL_SYM;
  if (LArg <> NIL_NODE) and PasIntrinsicReadsArgs(LShape) then
    LA := M.ExprType[LArg];
  // The builtin an alias argument names - the rules below compare that
  // (`Sqr(X)` of a `TMy = Int64` is Int64, audit A4-14 / D2-08).
  LAC := WeakAliasEnd(LA);
  // A VALUE-taking intrinsic whose argument resolved to a TYPE NAME is the
  // same mis-binding CheckAssign withholds judgement on: a member named
  // `Word` (`Copy(Word, 1, I)` in a spell checker, where Word is a string
  // property) reads as the builtin type here because the member is inherited
  // and cross-unit. Only Low/High/Default/SizeOf/TypeInfo take a type; for
  // the others a type argument means "do not know", never "an integer".
  if (LA <> NIL_SYM) and IsTypeNameOperand(LArg) and
     (LShape in [irLength, irAbs, irSqr, irOrdinal, irSwap, irOrd,
       irFirstArg, irConcat]) then
    Exit;
  case LShape of
    irInteger:  Result := Int;
    irString:   Result := Str;
    irHiLo:
      if (LArg <> NIL_NODE) and IsConstArg(LArg) then
        Result := Int
      else
        Result := Wrd;
    irOrd:
      if (LArg <> NIL_NODE) and IsConstArg(LArg) then
        Result := Int
      else if CatOf(LA) in [tcInteger, tcChar, tcBoolean, tcEnum] then
        Result := OpSym(OrdAnswer(OrdFacts(LArg, LA)), LA, NIL_SYM, False);
    irInt64:    Result := I64;
    irBoolean:  Result := Bool;
    irChar:     Result := Chr;
    irExtended: Result := Ext;
    irPointer:  Result := Ptr;
    irTypeKind: Result := NIL_SYM;   // System.TTypeKind - project level only
    irLength:
      begin
        Result := Int;
        LDef := ArrayDefOf(LA);
        if (LDef <> NIL_NODE) and IsDynArrayDef(LDef) then
          Result := NInt;
      end;
    irAbs:
      case CatOf(LA) of
        tcVariant: Result := Ext;
        tcInteger: Result := WidenOrdinal(LA);
        tcFloat:
          if FIs64 and ((LAC = Cur) or (LAC = Comp)) then
            Result := LAC
          else
            Result := Ext;
      end;
    irSqr:
      case CatOf(LA) of
        tcInteger:
          if (LAC <> NIL_SYM) and (M.Symbols[LAC].Kind = skBuiltinType) and
             ((RankOf(LAC) = 4) or (LAC = Card) or (LAC = LWord) or
              (LAC = NInt) or (LAC = NUInt)) then
            Result := LAC
          else
            Result := Int;
        tcFloat, tcVariant: Result := Ext;
      end;
    irOrdinal:
      Result := OrdStep(LA);
    irBounds:
      case CatOf(LA) of
        tcInteger, tcEnum, tcChar, tcBoolean: Result := OrdStep(LA);
        tcString: Result := Int;
        tcArray:
          begin
            LDef := ArrayDefOf(LA);
            if LDef = NIL_NODE then
              Exit;
            if IsDynArrayDef(LDef) then
            begin
              if M.Symbols[AHead].NameLower = 'high' then
                Result := NInt
              else
                Result := Int;
            end
            else
              Result := ArrayBoundType(LDef);
          end;
      end;
    irSwap:
      if (CatOf(LA) = tcInteger) and IsConstArg(LArg) then
        Result := Int
      else if (CatOf(LA) = tcInteger) and (LAC <> NIL_SYM) and
         (M.Symbols[LAC].Kind = skBuiltinType) and (RankOf(LAC) = 1) then
        Result := SmInt   // `Swap(B)` of a Byte or ShortInt (local/probe-b38)
      else if (CatOf(LA) = tcInteger) and (LAC <> NIL_SYM) and
         (M.Symbols[LAC].Kind = skBuiltinType) and (RankOf(LAC) in [2, 3]) and
         (LAC <> NInt) and (LAC <> NUInt) then
        Result := LAC
      else if CatOf(LA) = tcInteger then
        Result := Int;
    irFirstArg:
      if CatOf(LA) in [tcString, tcArray, tcInteger, tcPointer] then
        Result := LA;
    irConcat:
      begin
        if LA = NIL_SYM then
          Exit;
        if CatOf(LA) = tcArray then
        begin
          // One array type throughout.
          LSame := True;
          LCur := Sib(LArg);
          while LCur <> NIL_NODE do
          begin
            if M.ExprType[LCur] <> LA then
              LSame := False;
            LCur := Sib(LCur);
          end;
          if LSame then
            Result := LA;
          Exit;
        end;
        // Text: `+` folded left to right (TextJoinAnswer; audit A3-34:
        // Concat(A, 'x') is AnsiString, Concat(WS, A) WideString).
        LFacts := OpFacts(LA, LArg);
        if not (LFacts.Cat in [tcString, tcChar]) then
          Exit;
        Result := WeakAliasEnd(LA);
        if LFacts.Text in [stkLit, stkCharLit] then
          Result := Str;
        LCur := Sib(LArg);
        while LCur <> NIL_NODE do
        begin
          LNextF := OpFacts(M.ExprType[LCur], LCur);
          Result := OpSym(TextJoinAnswer(LFacts, LNextF,
            not (LFacts.Text in [stkLit, stkCharLit]) and
            not (LNextF.Text in [stkLit, stkCharLit]) and
            (Result = WeakAliasEnd(M.ExprType[LCur]))), Result,
            M.ExprType[LCur], False);
          if Result = NIL_SYM then
            Exit;
          LFacts := OpFacts(Result, NIL_NODE);
          LCur := Sib(LCur);
        end;
      end;
    irDefault:
      begin
        if (LA = NIL_SYM) or
           not (M.Symbols[LA].Kind in [skType, skBuiltinType]) then
          Exit;   // not a type argument, or a generic parameter
        case CatOf(LA) of
          tcClass, tcInterface, tcPointer, tcProc, tcClassOf:
            Result := Ptr;
          tcArray:
            begin
              LDef := ArrayDefOf(LA);
              if LDef = NIL_NODE then
                Exit;
              if IsDynArrayDef(LDef) then
                Result := Ptr
              else
                Result := LA;
            end;
          tcUnknown:
            Result := NIL_SYM;
        else
          Result := LA;
        end;
      end;
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
    // NodeNameLower, not LowerCase(Txt()): member keys are PasNameKey-
    // normalized (leading '&' stripped), so the LowerCase form could never
    // find an escaped member like X.&End - and it allocated twice.
    LMem := M.FindLocal(LScope, PasNodeKey(T, LName));
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
  // name's binding - and therefore its TYPE - is only a guess: a cross-unit
  // member of the target outranks it and the project's with pass may rebind
  // it (see TPasSemaModel.WithUnopened). Type-checking a guess produces
  // confident nonsense, e.g. E2010 'Double' vs 'string' where the real member
  // is a string, so withhold every diagnostic over such a node instead.
  //
  // Withheld, not dropped: once the project's with pass has committed the
  // real bindings, RecheckWithBodies re-types exactly these bodies with the
  // suppression off, so a GENUINE error there is still reported - later, and
  // against the right binding.
  if not FRecheck and M.InUnopenedWithBody(ANode) then
    Exit;
  // The same for a name of a method body Phase 1 bound PAST the method's
  // type (TPasSemaModel.BoundPastStruct): an inherited member of that name,
  // which the project's inherited pass may find, outranks it - `Padding :=
  // 'inner'` in a nested class's method read an outer Integer field where
  // the ancestor's string field was meant (F40). The whole expression is
  // withheld and re-typed once the pass has committed.
  if FPastWithhold and not FRecheck then
  begin
    var LRoot := ExprRoot(ANode);
    if HoldsPastStructName(LRoot) then
    begin
      var LSeen := False;
      for var LHeld in M.PastStructRecheck do
        if LHeld = LRoot then
        begin
          LSeen := True;
          Break;
        end;
      if not LSeen then
        M.PastStructRecheck := M.PastStructRecheck + [LRoot];
      Exit;
    end;
  end;
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

// The node a recheck re-types for a diagnostic at N: the outermost
// expression N belongs to, or the assignment / expression statement holding
// it - TypeNode over that runs every check the walk ran over N.
function TPasSemaTyper.ExprRoot(N: Integer): Integer;
var
  LParent: Integer;
begin
  Result := N;
  while True do
  begin
    LParent := T.Nodes[Result].Parent;
    if LParent = NIL_NODE then
      Exit;
    case Kind(LParent) of
      nkIdent..nkInherited:
        Result := LParent;
      nkAssign, nkExprStmt:
        Exit(LParent);
    else
      Exit;
    end;
  end;
end;

// True when an identifier under ARoot is TPasSemaModel.BoundPastStruct.
// Asked only for a diagnostic about to be emitted - rare by construction.
function TPasSemaTyper.HoldsPastStructName(ARoot: Integer): Boolean;
var
  LStack: TArray<Integer>;
  LTop, LNode, LChild: Integer;
begin
  Result := False;
  SetLength(LStack, 16);
  LStack[0] := ARoot;
  LTop := 1;
  while LTop > 0 do
  begin
    Dec(LTop);
    LNode := LStack[LTop];
    if (Kind(LNode) = nkIdent) and M.BoundPastStruct(LNode) then
      Exit(True);
    LChild := Child(LNode);
    while LChild <> NIL_NODE do
    begin
      if LTop > High(LStack) then
        SetLength(LStack, 2 * Length(LStack));
      LStack[LTop] := LChild;
      Inc(LTop);
      LChild := Sib(LChild);
    end;
  end;
end;

// Conservative: only reject definite scalar mismatches (CatAssignable).
function TPasSemaTyper.Assignable(ADst, ASrc: Integer): Boolean;
var
  D, S: TSemaTypeCat;
begin
  D := CatOf(ADst); S := CatOf(ASrc);
  Result := CatAssignable(D, S, (S = tcNil) and (D = tcRecord) and
    DeclaresConversion(ADst, False));
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
  LDst, LSrc, LDstT, LSrcT: Integer;
begin
  LDst := Child(N);
  if LDst = NIL_NODE then
    Exit;
  LSrc := Sib(LDst);
  if LSrc = NIL_NODE then
    Exit;
  LDstT := M.ExprType[LDst];
  LSrcT := M.ExprType[LSrc];
  if (LDstT = NIL_SYM) or (LSrcT = NIL_SYM) then
    Exit;
  // A string literal is char-compatible (C := 'x'); don't flag it - nor one
  // in parentheses, nor an inline `if` whose branches are each such a
  // literal or a Char (`if B then 'a' else Ch`): the node takes the
  // then-branch's `string` (audit A4-10, probe-b32 P1). Lenient on purpose:
  // `C := 'abc'` passes too.
  if (CatOf(LDstT) = tcChar) and CharCompatibleSource(LSrc) then
    Exit;
  // An operand that resolved to a TYPE NAME is a mis-binding, not a type
  // mismatch, so this is the wrong diagnostic for it and the numbers say so:
  // dcc has its own errors for a type used as a value. It happens when a
  // MEMBER shadows a builtin type name - a class with `property Word: string`
  // makes bare `Word` in a descendant's method mean the property (dcc-verified),
  // but Phase 1 sees only the seeded type, because the member is INHERITED and
  // cross-unit and only the project's later pass can reach it. That pass cannot
  // unsay a diagnostic this one already emitted, so the judgement has to be
  // withheld here. 12 false E2010 on one real code base, all of them a member
  // named `Word`.
  if IsTypeNameOperand(LDst) or IsTypeNameOperand(LSrc) then
    Exit;
  if not Assignable(LDstT, LSrcT) then
  begin
    // dcc names the nil literal's type `Pointer`; the seed is `_nil`.
    var LSrcName := M.Symbols[LSrcT].Name;
    if CatOf(LSrcT) = tcNil then
      LSrcName := 'Pointer';
    Diag('E2010', Format(SE2010_IncompatibleTypes,
      [M.Symbols[LDstT].Name, LSrcName]), LSrc);
  end;
end;

function TPasSemaTyper.CharCompatibleSource(N: Integer): Boolean;
var
  LThen, LElse: Integer;
begin
  N := PeelParens(T, N);
  if N = NIL_NODE then
    Exit(False);
  case Kind(N) of
    nkStrLit, nkCaretChar:
      Result := True;
    nkInlineIf:
      begin
        LThen := Child(N);
        if LThen <> NIL_NODE then
          LThen := Sib(LThen);
        if LThen = NIL_NODE then
          Exit(False);
        LElse := Sib(LThen);
        Result := (LElse <> NIL_NODE) and CharCompatibleSource(LThen) and
          CharCompatibleSource(LElse);
      end;
  else
    Result := CatOf(M.ExprType[N]) = tcChar;
  end;
end;

function TPasSemaTyper.TypeNode(N: Integer): Integer;
var
  LChild, LNode: Integer;
  LKind: TPasNodeKind;
begin
  if N = NIL_NODE then
    Exit(NIL_SYM);
  LKind := Kind(N);
  LChild := Child(N);
  // An operator chain's left spine is as deep as the chain is long (audit
  // A1-01, see TPasSemaResolver.WalkOperatorChain): walked in a loop, the
  // operands recursively, each operator typed after its operands - the
  // order the recursion had.
  if (LKind = nkBinaryOp) and (LChild <> NIL_NODE) and
     (Kind(LChild) = nkBinaryOp) then
  begin
    LNode := N;
    while (Child(LNode) <> NIL_NODE) and (Kind(Child(LNode)) = nkBinaryOp) do
      LNode := Child(LNode);
    TypeNode(Child(LNode));
    repeat
      LChild := Child(LNode);
      if LChild <> NIL_NODE then
        LChild := Sib(LChild);
      while LChild <> NIL_NODE do
      begin
        TypeNode(LChild);
        LChild := Sib(LChild);
      end;
      Result := BinaryResult(LNode);
      M.ExprType[LNode] := Result;
      if LNode = N then
        Break;
      LNode := T.Nodes[LNode].Parent;
    until False;
    Exit;
  end;
  while LChild <> NIL_NODE do   // type children first (bottom-up)
  begin
    TypeNode(LChild);
    LChild := Sib(LChild);
  end;

  case LKind of
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
    // The generic call or cast an nkAmbiguous may be (16.3.1): CallResult
    // reads its head as the callee and its tail as the one argument. Read as
    // comparisons it is several arguments and no one value.
    nkAmbiguous:
      if M.AmbigReadingOf(N) = arGeneric then
        Result := CallResult(N)
      else
        Result := NIL_SYM;
    nkInlineIf:
      Result := InlineIfResult(N);
  else
    Result := NIL_SYM;
  end;
  M.ExprType[N] := Result;

  if LKind = nkAssign then
    CheckAssign(N);
end;

{ The bodies of the model's WithUnopened statements, re-typed after the
  project's with pass has committed the bindings the intra-unit pass could only
  guess at (see TPasSemaModel.WithUnopened). Every diagnostic Diag withheld in
  the first pass over these bodies is decided here instead - a genuine
  `with C do Local := 'x'` (Local an Integer, not a member of anything) was
  simply never reported before this existed, in every with over a cross-unit
  or half-open target type.

  OUTERMOST bodies only: a with nested inside another unopened with's body is
  re-typed as part of the outer body's walk, and walking it again would emit
  its diagnostics twice. TypeNode's own bottom-up walk is what re-runs, so the
  checks that ride on it (CheckAssign) are what this recovers; the whole-tree
  sweeps (CheckConditionTypes, CheckOrdinalTypePositions, CheckSetCardinality)
  are not re-run - they would re-report everything OUTSIDE the bodies too.

  Then the expressions held for a name bound past a method's type
  (PastStructRecheck - see Diag), each with its own condition check. }
class procedure TPasSemaTyper.RecheckWithBodies(AModel: TPasSemaModel;
  APlatform: TPasPlatform; const AExtTypeOf: TSemaExtTypeFunc;
  const ATargetsTyped: TSemaWithTypedFunc);
var
  LT: TPasSemaTyper;
  LIdx, LWith, LBody, LRoot, LStmt, LCond, LNode: Integer;
  LAny: Boolean;

  // An expression inside another one held too (in an anonymous method's
  // body): typing the outer one types it, and twice would report twice.
  function HeldUnder(ANode: Integer): Boolean;
  var
    LUp: Integer;
  begin
    LUp := AModel.Tree.Nodes[ANode].Parent;
    while LUp <> NIL_NODE do
    begin
      for var LHeld in AModel.PastStructRecheck do
        if LHeld = LUp then
          Exit(True);
      LUp := AModel.Tree.Nodes[LUp].Parent;
    end;
    Result := False;
  end;

begin
  if (Length(AModel.WithUnopened) = 0) and
     (Length(AModel.PastStructRecheck) = 0) then
    Exit;
  LT := TPasSemaTyper.Create;
  try
    LT.M := AModel;
    LT.T := AModel.Tree;
    LT.FPlatform := APlatform;
    LT.FRecheck := True;
    LT.FExtTypeOf := AExtTypeOf;
    LT.Prepare;
    SetLength(LT.FSweepOnly, Length(AModel.Tree.Nodes));
    LAny := False;
    for LIdx := 0 to High(AModel.WithUnopened) do
    begin
      LWith := AModel.WithUnopened[LIdx];
      if (LWith < 0) or (LWith > High(AModel.Tree.Nodes)) or
         AModel.InUnopenedWithBody(LWith) then
        Continue;
      // A target the project's with pass could not type either committed
      // nothing: the body's bindings are still Phase 1's guesses, and the
      // diagnostics over them stay withheld (audit B4-23).
      if Assigned(ATargetsTyped) and not ATargetsTyped(LWith) then
        Continue;
      LBody := AModel.Tree.WithBody(LWith);
      if LBody = NIL_NODE then
        Continue;
      LT.TypeNode(LBody);
      // The body's nodes, for the sweeps below.
      LNode := LBody;
      while LNode <> NIL_NODE do
      begin
        LT.FSweepOnly[LNode] := True;
        LAny := True;
        if AModel.Tree.Nodes[LNode].FirstChild <> NIL_NODE then
          LNode := AModel.Tree.Nodes[LNode].FirstChild
        else
        begin
          while (LNode <> LBody) and
                (AModel.Tree.Nodes[LNode].NextSibling = NIL_NODE) do
            LNode := AModel.Tree.Nodes[LNode].Parent;
          if LNode = LBody then
            Break;
          LNode := AModel.Tree.Nodes[LNode].NextSibling;
        end;
      end;
    end;
    // The whole-tree sweeps and the for-counter check, over the rechecked
    // bodies only: what Diag withheld there in the first pass - E2012,
    // E2001, E2032, E2028 (audit E4-03) and the resolver's E2081 (B4-13) -
    // is decided against the committed bindings, once.
    if LAny then
    begin
      LT.CheckOrdinalTypePositions;
      LT.CheckSetCardinality;
      LT.CheckConditionTypes;
      LT.CheckCountersIn;
    end;
    LT.FSweepOnly := nil;
    // The expressions Diag withheld over a name bound past a method's type
    // (PastStructRecheck), now typed against what the inherited pass
    // committed; a condition gets its condition check again too. One inside
    // an unopened with body was never withheld for this - the with rule
    // came first - and is re-typed with that body above.
    for LIdx := 0 to High(AModel.PastStructRecheck) do
    begin
      LRoot := AModel.PastStructRecheck[LIdx];
      if (LRoot < 0) or (LRoot > High(AModel.Tree.Nodes)) or
         HeldUnder(LRoot) then
        Continue;
      LT.TypeNode(LRoot);
      LStmt := AModel.Tree.Nodes[LRoot].Parent;
      if LStmt = NIL_NODE then
        Continue;
      LCond := NIL_NODE;
      case AModel.Tree.Nodes[LStmt].Kind of
        nkIfStmt, nkWhileStmt, nkCaseStmt:
          LCond := AModel.Tree.Nodes[LStmt].FirstChild;
        nkRepeatStmt:
          if AModel.Tree.Nodes[LStmt].FirstChild <> NIL_NODE then
            LCond := AModel.Tree.Nodes[
              AModel.Tree.Nodes[LStmt].FirstChild].NextSibling;
      end;
      if LCond = LRoot then
        LT.CheckCondition(LStmt);
    end;
  finally
    LT.Free;
  end;
end;

// The kind a whole-tree sweep sees at AIdx: nkMissing - a kind no sweep
// handles - for a node outside a recheck's set.
function TPasSemaTyper.SweepKind(AIdx: Integer): TPasNodeKind;
begin
  if (FSweepOnly <> nil) and not FSweepOnly[AIdx] then
    Result := nkMissing
  else
    Result := Kind(AIdx);
end;

{ E2081 in a rechecked with body: a write to an enclosing for loop's counter
  (PasCounterWrites - the resolver's shapes), judged on the committed
  binding. The resolver's
  CheckForCounters leaves these nodes to the recheck - Phase 1 bound `Tag` in
  `for Tag := ... do with C do Tag := 7` to the counter where the target's
  inherited member is meant (audit B4-13). }
procedure TPasSemaTyper.CheckCountersIn;

  // One written name: E2081 when an enclosing loop's body holds it and that
  // loop's counter is the name's symbol.
  procedure Judge(ATarget: Integer);
  var
    LSym, LUp, LFrom, LFirst, LBody, LCounter: Integer;
  begin
    LSym := M.RefMap[ATarget];
    if LSym = NIL_SYM then
      Exit;
    LFrom := ATarget;
    LUp := T.Nodes[ATarget].Parent;
    while LUp <> NIL_NODE do
    begin
      if Kind(LUp) in [nkForStmt, nkForInStmt] then
      begin
        LBody := Child(LUp);
        while (LBody <> NIL_NODE) and (Sib(LBody) <> NIL_NODE) do
          LBody := Sib(LBody);
        LFirst := Child(LUp);
        LCounter := NIL_SYM;
        if (LFirst <> NIL_NODE) and (Kind(LFirst) = nkInlineVar) and
           (Child(LFirst) <> NIL_NODE) then
          LCounter := M.RefMap[Child(LFirst)]
        else if (LFirst <> NIL_NODE) and (Kind(LFirst) = nkIdent) then
          LCounter := M.RefMap[LFirst];
        if (LFrom = LBody) and (LCounter = LSym) then
        begin
          Diag('E2081', Format(SE2081_AssignToForLoopVar,
            [M.Symbols[LSym].Name]), ATarget);
          Break;
        end;
      end;
      LFrom := LUp;
      LUp := T.Nodes[LUp].Parent;
    end;
  end;

var
  LIdx, LTarget: Integer;
begin
  for LIdx := 0 to High(T.Nodes) do
    if FSweepOnly[LIdx] then
      for LTarget in PasCounterWrites(T, LIdx) do
        Judge(LTarget);
end;

// The builtin-symbol cache and the type categories - what both Run and
// RecheckWithBodies need before the first TypeNode.
procedure TPasSemaTyper.Prepare;
var
  LIdx: Integer;
begin
  Int := NIL_SYM; Ext := NIL_SYM; Str := NIL_SYM; Chr := NIL_SYM;
  Bool := NIL_SYM; Ptr := NIL_SYM; Nul := NIL_SYM;
  I64 := NIL_SYM; NInt := NIL_SYM; AStr := NIL_SYM; SStr := NIL_SYM;
  NUInt := NIL_SYM; Cur := NIL_SYM; WStr := NIL_SYM; Comp := NIL_SYM;
  Card := NIL_SYM; LWord := NIL_SYM; AChr := NIL_SYM; WChr := NIL_SYM;
  UStr := NIL_SYM; Byt := NIL_SYM; ShInt := NIL_SYM; Wrd := NIL_SYM;
  SmInt := NIL_SYM; U64 := NIL_SYM;
  FIs64 := PlatformInfo(FPlatform).Is64Bit;
  for LIdx := 0 to M.SymCount - 1 do
    if M.Symbols[LIdx].Kind = skBuiltinType then
      if M.Symbols[LIdx].NameLower = 'integer' then Int := LIdx
      else if M.Symbols[LIdx].NameLower = 'extended' then Ext := LIdx
      else if M.Symbols[LIdx].NameLower = 'string' then Str := LIdx
      else if M.Symbols[LIdx].NameLower = 'char' then Chr := LIdx
      else if M.Symbols[LIdx].NameLower = 'boolean' then Bool := LIdx
      else if M.Symbols[LIdx].NameLower = 'pointer' then Ptr := LIdx
      else if M.Symbols[LIdx].NameLower = '_nil' then Nul := LIdx
      else if M.Symbols[LIdx].NameLower = 'int64' then I64 := LIdx
      else if M.Symbols[LIdx].NameLower = 'nativeint' then NInt := LIdx
      else if M.Symbols[LIdx].NameLower = 'ansistring' then AStr := LIdx
      else if M.Symbols[LIdx].NameLower = 'shortstring' then SStr := LIdx
      else if M.Symbols[LIdx].NameLower = 'nativeuint' then NUInt := LIdx
      else if M.Symbols[LIdx].NameLower = 'currency' then Cur := LIdx
      else if M.Symbols[LIdx].NameLower = 'comp' then Comp := LIdx
      else if M.Symbols[LIdx].NameLower = 'cardinal' then Card := LIdx
      else if M.Symbols[LIdx].NameLower = 'longword' then LWord := LIdx
      else if M.Symbols[LIdx].NameLower = 'ansichar' then AChr := LIdx
      else if M.Symbols[LIdx].NameLower = 'widechar' then WChr := LIdx
      else if M.Symbols[LIdx].NameLower = 'unicodestring' then UStr := LIdx
      else if M.Symbols[LIdx].NameLower = 'byte' then Byt := LIdx
      else if M.Symbols[LIdx].NameLower = 'shortint' then ShInt := LIdx
      else if M.Symbols[LIdx].NameLower = 'word' then Wrd := LIdx
      else if M.Symbols[LIdx].NameLower = 'smallint' then SmInt := LIdx
      else if M.Symbols[LIdx].NameLower = 'uint64' then U64 := LIdx
      else if M.Symbols[LIdx].NameLower = 'widestring' then WStr := LIdx;

  CategorizeTypes;
end;

procedure TPasSemaTyper.Run;
begin
  Prepare;
  CheckOrdinalTypePositions;   // needs CategorizeTypes - see its own header
  CheckSetCardinality;         // needs RefMap only - see its own header
  FPastWithhold := True;       // what RecheckWithBodies re-runs - see Diag
  TypeNode(0);
  CheckConditionTypes;         // needs ExprType - see its own header
  FPastWithhold := False;
end;

end.
