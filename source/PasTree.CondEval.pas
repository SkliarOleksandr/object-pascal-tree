unit PasTree.CondEval;

{
  PasTree - the `$IF` / `$ELSEIF` expression evaluator (spec 1.3.2, B.2.2).

  The GRAMMAR is not here: the expression text is parsed by the real
  TPasParser (ParseExpressionText), so the preprocessor's conditional
  expressions and the language's expressions can never drift apart - any
  construct the parser learns is automatically legal in `$IF`. This unit
  only EVALUATES the resulting tree, under a context of things the
  preprocessor knows (defines, compiler version, seeded type sizes, an
  optional Declared() oracle).

  A name only the semantic phase could resolve (a unit constant, an
  unanswered Declared(), SizeOf of a user type, Ord(x)) evaluates as a
  GUESS AT THE LEAF - False (0 for SizeOf) - and computation proceeds
  normally, exactly as the old string-walking evaluator did. The leaf-level
  guess is LOAD-BEARING, found the hard way (a Kleene draft of this unit
  propagated "unknown" to the top instead, and a corpus diff caught 6 RTL
  units taking different branches): the RTL's fallback idiom is

      $IF not Declared(socklen_t) ... declare it ... $ENDIF

  and only `not False = True` takes the fallback, which is what keeps the
  name resolvable either way. The second pass is calibrated to the same
  guess: RunDeclaredPass re-preprocesses exactly the units where a recorded
  name turns out DECLARED - the one case where the False guess was wrong.

  What the guess taints, however, is tracked: TPasCondValue.Guessed rides
  along, and an and/or whose verdict is settled by a CLEAN side alone drops
  the other side's taint (dcc32 37.0-probed: dcc short-circuits
  left-to-right, so `Defined(FPC) and (FPC_FULLVERSION < 30301)` - the
  RTL's own System.Skia.API shape - never evaluates the undeclared name;
  same verdict here, and no needs-semantics flag, because no second pass
  could change it).

  dcc's ABORT RULES, reproduced here rather than diverged from. When dcc
  actually EVALUATES an identifier that resolves nowhere it abandons the whole
  expression with a fixed verdict, and the verdict depends on the position the
  name sat in (probed by executing both branches on dcc64 36.0 and 37.0 -
  identical, so this is long-standing, not a beta quirk; the full table is in
  the language spec, 1.3.2):

    - arithmetic or relational-against-a-number  -> the whole $IF is TRUE,
      and the abort survives everything outside it: `not (UNDECL > 3)`,
      `((UNDECL > 3))` and `(UNDECL > 3) and False` all take the TRUE branch.
    - bare boolean (`$IF UNDECL`, `$IF not UNDECL`), compared against a
      string/char/Boolean literal, or any dotted name with an unknown prefix
      -> FALSE, which is what the plain guess already produced.

  Short-circuit comes first, because dcc evaluates strictly left to right and
  never reaches the name: `Defined(NOPE) and (UNDECL > 3)` is False.

  The abort is gated on KNOWING the name resolves nowhere, which only a full
  symbol table can say (TPasSymbolValue.NoSymbol, second pass). On the first
  pass, and for a name that exists but whose value we cannot fold, the False
  guess stands and the taint below records the open question - the two cases
  must not be confused: the first is dcc parity, the second is a finding.
}

interface

uses
  PasTree.Types,
  PasTree.Ast,
  PasTree.Preprocessor;

type
  TPasCondKind = (cvBool, cvNum, cvStr);

  TPasCondValue = record
    Kind: TPasCondKind;
    Bool: Boolean;
    Num: Double;
    Str: string;
    // A guessed leaf contributed to THIS value. Cleared when an and/or was
    // settled by a clean side alone - the flag's consumer is the
    // needs-semantics diagnostic, i.e. "could a second pass change this
    // verdict", and a Kleene-decided verdict it could not.
    Guessed: Boolean;
    // This leaf is a name that a FULL symbol table says exists nowhere. Not a
    // guess: dcc's verdict for it is determined, and the two flags below carry
    // it. See the dcc abort rules in the unit comment.
    Undef: Boolean;
    // dcc abandoned the whole expression with True. Propagates to the top
    // through every operator, `not` and parens included.
    AbortTrue: Boolean;
  end;

  TPasCondContext = record
    // Inputs.
    Defines: TPasDefines;            // nil tolerated (tree-eval of const
                                     // initializers has no define set; a
                                     // Defined() there just guesses)
    OnDeclared: TPasDeclaredQuery;   // nil = nobody can answer Declared()
    OnSymbol: TPasCondSymbolQuery;   // nil = nobody can answer const/SizeOf/
                                     // Length questions (the first pass)
    CompilerVersion: Double;         // answers RTLVersion too (equal since XE2)
    PointerBytes: Integer;
    ExtendedBytes: Integer;
    // Outputs.
    UnknownDeclared: TArray<string>; // Declared() names nobody answered
    UnknownSymbols: TArray<TPasUnresolvedSymbol>; // ...and symbol questions
  end;

{ Evaluates the expression rooted at ANode. Never raises; anything it cannot
  prove evaluates as a False/0 guess with Guessed set. }
function EvalCondNode(const ATree: TPasTree; ANode: Integer;
  var ACtx: TPasCondContext): TPasCondValue;

{ Lex + parse (TPasParser.ParseExpressionText) + evaluate AExpr. ABadExpr is
  the old `Failed`: the text does not parse as an expression at all. The tree
  is still evaluated in that case - solely so UnknownDeclared gets recorded,
  matching the old evaluator's deliberate behavior ("a half-parsed expression
  that mentioned a name is still a case a second pass could learn from"). }
function EvalCondText(const AExpr: string; var ACtx: TPasCondContext;
  out ABadExpr: Boolean): TPasCondValue;

{ The branch verdict. }
function CondAsBool(const AValue: TPasCondValue): Boolean;
function CondAsNum(const AValue: TPasCondValue): Double;

{ SizeOf(X) for the SEEDED builtin types only, parameterized by target.
  Public because the projects symbol oracle sizes record FIELDS with it. }
function PasBuiltinSizeOf(const AName: string; APointerBytes,
  AExtendedBytes: Integer; out ASize: Double): Boolean;

{ The same table, with ALIGNMENT - which is NOT derivable from the size.
  ShortString is 256 bytes aligned to 1, a set is up to 32 bytes aligned to 1,
  and Extended is 10 bytes aligned to 8 (Win32). Anything that lays out a
  record must ask this rather than clipping the size to 8. }
function PasBuiltinLayout(const AName: string; APointerBytes,
  AExtendedBytes: Integer; out ASize: Double; out AAlign: Integer): Boolean;

implementation

uses
  System.SysUtils,
  System.Math,
  PasTree.Parser;

function MkBool(AValue: Boolean): TPasCondValue;
begin
  Result := Default(TPasCondValue);
  Result.Kind := cvBool;
  Result.Bool := AValue;
end;

function MkNum(AValue: Double): TPasCondValue;
begin
  Result := Default(TPasCondValue);
  Result.Kind := cvNum;
  Result.Num := AValue;
end;

// The leaf guess: False for a boolean position, 0 where a number is wanted
// (the SizeOf case constructs its own). See the unit comment for why the
// guess sits at the LEAF and not at the top.
function MkGuess: TPasCondValue;
begin
  Result := MkBool(False);
  Result.Guessed := True;
end;

// True when this value can settle a branch on its own - no guess in it, and
// no dcc abort riding on it either.
function CondIsClean(const AValue: TPasCondValue): Boolean;
begin
  Result := not AValue.Guessed and not AValue.Undef and not AValue.AbortTrue;
end;

// The leaf for a name a full symbol table says exists nowhere. It reads as
// False (dcc's verdict in a bare boolean position) until an operator puts it
// in a numeric position, where MkAbortTrue takes over.
function MkUndef: TPasCondValue;
begin
  Result := Default(TPasCondValue);
  Result.Kind := cvBool;
  Result.Undef := True;
end;

function MkAbortTrue: TPasCondValue;
begin
  Result := Default(TPasCondValue);
  Result.Kind := cvBool;
  Result.Bool := True;
  Result.AbortTrue := True;
end;

function CondAsBool(const AValue: TPasCondValue): Boolean;
begin
  if AValue.AbortTrue then
    Exit(True);
  case AValue.Kind of
    cvBool: Result := AValue.Bool;
    cvNum: Result := AValue.Num <> 0;
  else
    Result := AValue.Str <> '';
  end;
end;

function CondAsNum(const AValue: TPasCondValue): Double;
begin
  case AValue.Kind of
    cvNum: Result := AValue.Num;
    cvBool: Result := Ord(AValue.Bool);
  else
    Result := 0;
  end;
end;

// Token text -> number. Handles what the LEXER can hand us: decimal, real,
// $hex, %binary, digit separators. (The old string-walking evaluator only
// knew bare decimals - `$IF $10 > 15` was a bad expression; the real lexer
// tokenizes it, so it now evaluates.)
function CondNumOfText(const AText: string; out ANum: Double): Boolean;
var
  LClean: string;
  L64: Int64;
  LIdx: Integer;
begin
  ANum := 0;
  LClean := AText.Replace('_', '');
  if LClean = '' then
    Exit(False);
  case LClean[1] of
    '$':
      begin
        Result := TryStrToInt64(LClean, L64);
        if Result then
          ANum := L64;
      end;
    '%':
      begin
        if Length(LClean) < 2 then
          Exit(False);
        // The digit COUNT is checked first: past 63 significant bits the
        // doubling below overflows Int64 - a silent wrap under {$Q-} and an
        // EIntOverflow in the checked builds this project is tested with,
        // where the hex path beside it uses TryStrToInt64 and simply fails.
        L64 := 0;
        for LIdx := 2 to Length(LClean) do
          case LClean[LIdx] of
            '0', '1':
              begin
                if (L64 < 0) or ((L64 shr 62) <> 0) then
                  Exit(False);
                L64 := L64 * 2;
                if LClean[LIdx] = '1' then
                  L64 := L64 + 1;
              end;
          else
            Exit(False);
          end;
        ANum := L64;
        Result := True;
      end;
  else
    Result := TryStrToFloat(LClean, ANum, TFormatSettings.Invariant);
  end;
end;

// Token text -> string value: strip the outer quotes, un-double the inner
// ones. #-char forms come back as written (the old evaluator had no support
// for them either; nothing in a real `$IF` compares control characters).
function CondStrOfText(const AText: string): string;
var
  LIdx: Integer;
begin
  if (AText = '') or (AText[1] <> '''') then
    Exit(AText);
  Result := '';
  LIdx := 2;
  while LIdx <= Length(AText) do
  begin
    if AText[LIdx] = '''' then
    begin
      if (LIdx < Length(AText)) and (AText[LIdx + 1] = '''') then
      begin
        Result := Result + '''';
        Inc(LIdx, 2);
      end
      else
        Break;
    end
    else
    begin
      Result := Result + AText[LIdx];
      Inc(LIdx);
    end;
  end;
end;

// A Declared() argument is a DESIGNATOR, not a bare identifier - the RTL
// writes `Declared(System.Embedded)`. '' = a shape we cannot name (and the
// caller guesses).
function DottedNameOf(const ATree: TPasTree; ANode: Integer): string;
var
  LChild: Integer;
begin
  case ATree.Nodes[ANode].Kind of
    nkIdent:
      Result := ATree.NodeText(ANode);
    nkMember:
      begin
        Result := '';
        LChild := ATree.Nodes[ANode].FirstChild;
        while LChild <> NIL_NODE do
        begin
          if ATree.Nodes[LChild].Kind <> nkIdent then
            Exit('');
          if Result <> '' then
            Result := Result + '.';
          Result := Result + ATree.NodeText(LChild);
          LChild := ATree.Nodes[LChild].NextSibling;
        end;
      end;
  else
    Result := '';
  end;
end;

function PasBuiltinSizeOf(const AName: string; APointerBytes,
  AExtendedBytes: Integer; out ASize: Double): Boolean;
var
  LAlign: Integer;
begin
  Result := PasBuiltinLayout(AName, APointerBytes, AExtendedBytes, ASize,
    LAlign);
end;

function PasBuiltinLayout(const AName: string; APointerBytes,
  AExtendedBytes: Integer; out ASize: Double; out AAlign: Integer): Boolean;
begin
  // The reference-counted and pointer-like intrinsics: one machine pointer,
  // aligned as one. `string` and friends are reserved words or compiler
  // intrinsics, so nothing in a unit can shadow them with a different size.
  if SameText(AName, 'string') or SameText(AName, 'UnicodeString') or
     SameText(AName, 'AnsiString') or SameText(AName, 'WideString') or
     SameText(AName, 'UTF8String') or SameText(AName, 'RawByteString') or
     SameText(AName, 'PChar') or SameText(AName, 'PAnsiChar') or
     SameText(AName, 'PWideChar') then
  begin
    ASize := APointerBytes;
    AAlign := APointerBytes;
    Exit(True);
  end;
  // 256 bytes of storage, but byte-aligned - the case that makes alignment a
  // separate question from size.
  if SameText(AName, 'ShortString') then
  begin
    ASize := 256;
    AAlign := 1;
    Exit(True);
  end;
  // TVarData: 16 bytes on a 32-bit target, 24 on 64-bit, aligned to 8 on
  // BOTH (dcc-probed: `record A: Byte; V: Variant; end` is 24 on Win32).
  if SameText(AName, 'Variant') or SameText(AName, 'OleVariant') then
  begin
    if APointerBytes = 4 then
      ASize := 16
    else
      ASize := 24;
    AAlign := 8;
    Exit(True);
  end;

  Result := True;
  if SameText(AName, 'Pointer') or SameText(AName, 'NativeInt') or
     SameText(AName, 'NativeUInt') then
    ASize := APointerBytes
  else if SameText(AName, 'Extended') then
    ASize := AExtendedBytes
  else if SameText(AName, 'Int64') or SameText(AName, 'UInt64') or
    SameText(AName, 'Double') or SameText(AName, 'Currency') then
    ASize := 8
  else if SameText(AName, 'Integer') or SameText(AName, 'Cardinal') or
    SameText(AName, 'LongInt') or SameText(AName, 'LongWord') or
    SameText(AName, 'Single') then
    ASize := 4
  else if SameText(AName, 'Char') or SameText(AName, 'WideChar') or
    SameText(AName, 'Word') or SameText(AName, 'SmallInt') then
    ASize := 2
  else if SameText(AName, 'AnsiChar') or SameText(AName, 'Byte') or
    SameText(AName, 'ShortInt') or SameText(AName, 'Boolean') then
    ASize := 1
  else
  begin
    ASize := 0;
    Result := False;
  end;
  // Every remaining builtin is a scalar, and a scalar aligns to its own size
  // capped at 8 - Extended (10 bytes on Win32) is the only one where that
  // clipping does real work.
  if Result then
    AAlign := Min(Trunc(ASize), 8)
  else
    AAlign := 1;
end;

// A shift count dcc would accept: a clean (unguessed) whole number in 0..63.
// Anything else refuses, which leaves the expression a guess rather than
// inventing a value.
{ Trunc that cannot raise. Every integer operator below folds through a Double
  (a `$IF` literal too big for Int64 lands there via TryStrToFloat), and
  RTL Trunc raises EInvalidOp outside Int64 range - which would kill the whole
  preprocess run of the unit and break this unit's "never raises" contract.
  Out of range, or NaN, is simply "no answer": the caller guesses. }
function CondTryTrunc(const AValue: Double; out ANum: Int64): Boolean;
const
  LIMIT = 9223372036854775808.0;   // 2^63; exclusive on both ends
begin
  ANum := 0;
  Result := (AValue > -LIMIT) and (AValue < LIMIT);
  if Result then
    ANum := Trunc(AValue);
end;

function CondShiftCount(const AValue: TPasCondValue; out ACount: Integer):
  Boolean;
var
  LNum: Double;
begin
  ACount := 0;
  if AValue.Guessed or (AValue.Kind = cvStr) then
    Exit(False);
  LNum := CondAsNum(AValue);
  Result := (LNum >= 0) and (LNum <= 63) and (Frac(LNum) = 0);
  if Result then
    ACount := Trunc(LNum);
end;

{ An ordinal type-cast in a constant expression - `Byte(UnsignedBit shl 5)`,
  `NativeUInt(1)`, FastMM4's whole const block. dcc folds these; without them a
  cast reads as an unknown function call and poisons every constant downstream
  of it. Only the INTEGRAL builtins cast here: they are the ones whose result
  is a number a `$IF` can compare. Truncation is real (a cast to Byte wraps),
  so the folded value matches dcc rather than approximating it. }
function PasBuiltinCast(const AName: string; APointerBytes: Integer;
  const AValue: TPasCondValue; out ANum: Double): Boolean;
var
  LBytes, LBits: Integer;
  LSigned: Boolean;
  LRaw: Int64;
  LMask: UInt64;
begin
  ANum := 0;
  Result := False;
  if AValue.Kind = cvStr then
    Exit;
  LSigned := False;
  if SameText(AName, 'Byte') or SameText(AName, 'AnsiChar') then
    LBytes := 1
  else if SameText(AName, 'ShortInt') then
  begin
    LBytes := 1;
    LSigned := True;
  end
  else if SameText(AName, 'Word') or SameText(AName, 'WideChar') or
          SameText(AName, 'Char') then
    LBytes := 2
  else if SameText(AName, 'SmallInt') then
  begin
    LBytes := 2;
    LSigned := True;
  end
  else if SameText(AName, 'Cardinal') or SameText(AName, 'LongWord') then
    LBytes := 4
  else if SameText(AName, 'Integer') or SameText(AName, 'LongInt') then
  begin
    LBytes := 4;
    LSigned := True;
  end
  else if SameText(AName, 'UInt64') then
    LBytes := 8
  else if SameText(AName, 'Int64') then
  begin
    LBytes := 8;
    LSigned := True;
  end
  else if SameText(AName, 'NativeUInt') then
    LBytes := APointerBytes
  else if SameText(AName, 'NativeInt') then
  begin
    LBytes := APointerBytes;
    LSigned := True;
  end
  else
    Exit;

  // A value outside Int64 has no bit pattern to mask - refuse rather than
  // let Trunc raise (see CondTryTrunc): `{$IF Byte(1E300) = 0}` is a guess.
  if not CondTryTrunc(CondAsNum(AValue), LRaw) then
    Exit;
  LBits := LBytes * 8;
  if LBits >= 64 then
    ANum := LRaw
  else
  begin
    LMask := (UInt64(1) shl LBits) - 1;
    LRaw := Int64(UInt64(LRaw) and LMask);
    // Sign-extend from the cast width, exactly as the narrower signed type
    // would read the bits back.
    if LSigned and ((UInt64(LRaw) and (UInt64(1) shl (LBits - 1))) <> 0) then
      LRaw := LRaw - Int64(LMask) - 1;
    ANum := LRaw;
  end;
  Result := True;
end;

function EvalCondNode(const ATree: TPasTree; ANode: Integer;
  var ACtx: TPasCondContext): TPasCondValue;

  // Records one unanswerable question. sqDeclared additionally feeds
  // UnknownDeclared, which RunDeclaredPass's candidate filter reads.
  procedure AddUnknown(AQuery: TPasSymbolQuery; const AName: string);
  var
    LSym: TPasUnresolvedSymbol;
  begin
    LSym.Query := AQuery;
    LSym.Name := AName;
    ACtx.UnknownSymbols := ACtx.UnknownSymbols + [LSym];
    if AQuery = sqDeclared then
      ACtx.UnknownDeclared := ACtx.UnknownDeclared + [AName];
  end;

  // A symbol question: ask the oracle when there is one, otherwise record
  // the question (kind + name) for the second pass and return the guess -
  // exactly the Declared() contract, widened.
  function AskSymbol(AQuery: TPasSymbolQuery; const AName: string;
    const AGuess: TPasCondValue): TPasCondValue;
  var
    LAns: TPasSymbolValue;
  begin
    LAns := Default(TPasSymbolValue);
    if Assigned(ACtx.OnSymbol) then
    begin
      if ACtx.OnSymbol(AQuery, AName, LAns) then
      begin
        if not LAns.IsStr then
          Exit(MkNum(LAns.Num));
        Result := Default(TPasCondValue);
        Result.Kind := cvStr;
        Result.Str := LAns.Str;
        Exit;
      end;
      // The name exists NOWHERE: not an open question but a determined dcc
      // verdict, so it is neither guessed nor recorded - it is copied. Only
      // the const-value query can say this; a SizeOf/Length question about a
      // missing name is still a question.
      if LAns.NoSymbol and (AQuery = sqConstValue) then
        Exit(MkUndef);
      // SizeOf of a type that exists NOWHERE is 4 for dcc (spec 1.3.2) - a
      // determined answer, not a question. Left as a guessed 0, the wrong
      // branch survived the second pass and the unit stayed a candidate for
      // re-decision forever.
      if LAns.NoSymbol and (AQuery = sqSizeOfType) then
        Exit(MkNum(4));
    end;
    AddUnknown(AQuery, AName);
    Result := AGuess;
    Result.Guessed := True;
  end;

  function EvalCall(ACallNode: Integer): TPasCondValue;
  var
    LCallee, LArg: Integer;
    LName, LArgName: string;
    LKnown: Boolean;
    LSize: Double;
    LArgVal: TPasCondValue;
  begin
    Result := MkGuess;
    LCallee := ATree.Nodes[ACallNode].FirstChild;
    if (LCallee = NIL_NODE) or (ATree.Nodes[LCallee].Kind <> nkIdent) then
      Exit;
    LName := ATree.NodeText(LCallee);
    LArg := ATree.Nodes[LCallee].NextSibling;
    if LArg = NIL_NODE then
      Exit;

    if SameText(LName, 'Defined') then
    begin
      if (ATree.Nodes[LArg].Kind = nkIdent) and Assigned(ACtx.Defines) then
        Result := MkBool(ACtx.Defines.IsDefined(ATree.NodeText(LArg)));
    end
    else if SameText(LName, 'Declared') then
    begin
      LArgName := DottedNameOf(ATree, LArg);
      if LArgName = '' then
        Exit;
      if Assigned(ACtx.OnDeclared) and ACtx.OnDeclared(LArgName, LKnown) then
        // Somebody with a symbol table answered - see TPasDeclaredQuery.
        // Not recorded, because it is not a guess.
        Result := MkBool(LKnown)
      else
        // Nobody can answer yet: the symbol table that knows is built from
        // the token stream this very decision produces. False is the guess -
        // the guarded text is by construction the text that does NOT compile
        // when the name IS declared, and `not Declared(X)` fallbacks then
        // come out True, keeping the name resolvable. The NAME is recorded
        // so a caller with a symbol table can come back and ask properly -
        // twice over: UnknownDeclared drives RunDeclaredPass's candidate
        // filter, UnknownSymbols rides on the diagnostic so a reporter can
        // tell an UNVERIFIED guess from one a full symbol table later
        // CONFIRMED (see TPasPPDiagnostic.Unanswered).
        AddUnknown(sqDeclared, LArgName);
    end
    else if SameText(LName, 'SizeOf') then
    begin
      if (ATree.Nodes[LArg].Kind = nkIdent) and
         PasBuiltinSizeOf(ATree.NodeText(LArg), ACtx.PointerBytes,
           ACtx.ExtendedBytes, LSize) then
        Result := MkNum(LSize)
      else
      begin
        // A user type's size: the oracle's question; guessed 0 (like the
        // old evaluator) when nobody answers.
        LArgName := DottedNameOf(ATree, LArg);
        if LArgName <> '' then
          Result := AskSymbol(sqSizeOfType, LArgName, MkNum(0))
        else
        begin
          Result := MkNum(0);
          Result.Guessed := True;
        end;
      end;
    end
    else if SameText(LName, 'Length') then
    begin
      // Length(X) of an array constant/variable - System.pas guards on
      // `Length(RegisteredTypeInfoTable)`. Guess 0 when unanswered.
      LArgName := DottedNameOf(ATree, LArg);
      if LArgName <> '' then
        Result := AskSymbol(sqLengthOf, LArgName, MkNum(0));
    end
    else
    begin
      // An ordinal type-cast folds like dcc does - but ONLY when its operand
      // is clean. A cast wrapped around a guess would turn the guess into a
      // confident-looking number and hide the open question.
      LArgVal := EvalCondNode(ATree, LArg, ACtx);
      // CondIsClean, not just "not Guessed": an Undef or abort-True operand
      // folded to a confident number too (`{$IF Byte(UNDECL) = 1}` came out a
      // clean False where dcc aborts True), which is exactly the hiding of an
      // open question the comment above forbids.
      if CondIsClean(LArgVal) and
         PasBuiltinCast(LName, ACtx.PointerBytes, LArgVal, LSize) then
        Exit(MkNum(LSize));
      // Anything else (Ord(x), a unit function, ...) stays a guess - but the
      // CALLEE is recorded so a reporter can say what it choked on. Without
      // this the guess carries no question at all, and a filter that trusts
      // "no open questions" would call it verified.
      AddUnknown(sqConstValue, LName + '()');
    end;
  end;

  function EvalRel(AOp: TPasTokenKind; const L, R: TPasCondValue):
    TPasCondValue;
  var
    LCmp: Integer;
  begin
    // dcc's abort, and the ONE place its direction is decided. A name that
    // exists nowhere aborts the whole $IF to True when it is compared against
    // a NUMBER (or against another such name); against a string, a char or a
    // Boolean literal it stays the error token that reads as False.
    if L.AbortTrue or R.AbortTrue then
      Exit(MkAbortTrue);
    if L.Undef or R.Undef then
    begin
      if (L.Undef or (L.Kind = cvNum)) and (R.Undef or (R.Kind = cvNum)) then
        Exit(MkAbortTrue);
      // The error-token exit, but it must NOT launder the other side's guess:
      // an Undef against a GUESSED Boolean left as a clean False also left
      // EvalIfExpression with nothing to copy, so no UnknownSymbols reached
      // the stream, no ppIfNeedsSemantics was emitted, and the second-pass
      // question simply vanished.
      Result := MkBool(False);
      Result.Guessed := L.Guessed or R.Guessed;
      Exit;
    end;
    if (L.Kind = cvStr) and (R.Kind = cvStr) then
    begin
      // dcc-probed, and both of these used to be wrong: string comparison is
      // case-SENSITIVE (`$IF 'ABC' = 'abc'` takes the ELSE branch), and the
      // ORDERING operators really order - they are the whole point of the
      // version-guard idiom (`$IF gsIdVersion >= '10.5.5'`), which a blanket
      // False answered by taking the wrong branch every time.
      LCmp := CompareStr(L.Str, R.Str);
      if AOp = tkEqual then
        Result := MkBool(LCmp = 0)
      else if AOp = tkNotEqual then
        Result := MkBool(LCmp <> 0)
      else if AOp = tkLess then
        Result := MkBool(LCmp < 0)
      else if AOp = tkGreater then
        Result := MkBool(LCmp > 0)
      else if AOp = tkLessEqual then
        Result := MkBool(LCmp <= 0)
      else
        Result := MkBool(LCmp >= 0);
    end
    else if AOp = tkEqual then
      Result := MkBool(CondAsNum(L) = CondAsNum(R))
    else if AOp = tkNotEqual then
      Result := MkBool(CondAsNum(L) <> CondAsNum(R))
    else if AOp = tkLess then
      Result := MkBool(CondAsNum(L) < CondAsNum(R))
    else if AOp = tkGreater then
      Result := MkBool(CondAsNum(L) > CondAsNum(R))
    else if AOp = tkLessEqual then
      Result := MkBool(CondAsNum(L) <= CondAsNum(R))
    else
      Result := MkBool(CondAsNum(L) >= CondAsNum(R));
    Result.Guessed := L.Guessed or R.Guessed;
  end;

  function EvalBinary(ABinNode: Integer): TPasCondValue;
  var
    LLeftNode, LRightNode: Integer;
    LOp: TPasTokenKind;
    L, R: TPasCondValue;
    LShift: Integer;
    LLeft, LRight: Int64;   // CondTryTrunc's answers - see there
  begin
    Result := MkGuess;
    LLeftNode := ATree.Nodes[ABinNode].FirstChild;
    if LLeftNode = NIL_NODE then
      Exit;
    LRightNode := ATree.Nodes[LLeftNode].NextSibling;
    if LRightNode = NIL_NODE then
      Exit;
    if ATree.Nodes[ABinNode].Aux < 0 then
      Exit;
    // The operator's token KIND - every operator here is a reserved word or
    // punctuation with a dedicated kind, so no text is built to dispatch.
    LOp := ATree.Source.VisibleToken(ATree.Nodes[ABinNode].Aux).Kind;

    L := EvalCondNode(ATree, LLeftNode, ACtx);
    R := EvalCondNode(ATree, LRightNode, ACtx);

    // and/or: a CLEAN side that settles the verdict alone drops the other
    // side's taint - the verdict cannot change no matter what the guessed
    // part turns out to be, so no second pass needs to look at it. This is
    // dcc's own left-to-right short-circuit, applied symmetrically (see the
    // unit comment for the probed divergence on undeclared names).
    // Short-circuit is checked BEFORE any abort, and in dcc's own left-to-
    // right order: `Defined(NOPE) and (UNDECL > 3)` is False because dcc never
    // reaches the name, while `(UNDECL > 3) and False` is True because it
    // aborted before it could look at the right-hand side.
    if LOp = tkAnd then
    begin
      if CondIsClean(L) and not CondAsBool(L) then
        Exit(MkBool(False));
      if L.AbortTrue then
        Exit(MkAbortTrue);
      if CondIsClean(R) and not CondAsBool(R) then
        Exit(MkBool(False));
      if R.AbortTrue then
        Exit(MkAbortTrue);
      Result := MkBool(CondAsBool(L) and CondAsBool(R));
      Result.Guessed := L.Guessed or R.Guessed;
      Exit;
    end;
    if LOp = tkOr then
    begin
      if CondIsClean(L) and CondAsBool(L) then
        Exit(MkBool(True));
      if L.AbortTrue then
        Exit(MkAbortTrue);
      if CondIsClean(R) and CondAsBool(R) then
        Exit(MkBool(True));
      if R.AbortTrue then
        Exit(MkAbortTrue);
      Result := MkBool(CondAsBool(L) or CondAsBool(R));
      Result.Guessed := L.Guessed or R.Guessed;
      Exit;
    end;
    if LOp = tkXor then
    begin
      if L.AbortTrue or R.AbortTrue then
        Exit(MkAbortTrue);
      Result := MkBool(CondAsBool(L) xor CondAsBool(R));
      Result.Guessed := L.Guessed or R.Guessed;
      Exit;
    end;

    if LOp in [tkEqual, tkNotEqual, tkLess, tkGreater, tkLessEqual,
       tkGreaterEqual] then
      Exit(EvalRel(LOp, L, R));

    // Arithmetic on a name that exists nowhere is the other half of the abort
    // rule: `UNDECL + 1 = 1` and `1 shl UNDECL = 2` both take the TRUE branch.
    if L.Undef or R.Undef or L.AbortTrue or R.AbortTrue then
      Exit(MkAbortTrue);

    if LOp = tkPlus then
      Result := MkNum(CondAsNum(L) + CondAsNum(R))
    else if LOp = tkMinus then
      Result := MkNum(CondAsNum(L) - CondAsNum(R))
    else if LOp = tkStar then
      Result := MkNum(CondAsNum(L) * CondAsNum(R))
    else if (LOp = tkSlash) and (CondAsNum(R) <> 0) then
      Result := MkNum(CondAsNum(L) / CondAsNum(R))
    else if (LOp = tkDiv) and CondTryTrunc(CondAsNum(L), LLeft) and
            CondTryTrunc(CondAsNum(R), LRight) and (LRight <> 0) then
      Result := MkNum(LLeft div LRight)
    else if (LOp = tkMod) and CondTryTrunc(CondAsNum(L), LLeft) and
            CondTryTrunc(CondAsNum(R), LRight) and (LRight <> 0) then
      Result := MkNum(LLeft mod LRight)
    else if (LOp = tkShl) and CondShiftCount(R, LShift) and
            CondTryTrunc(CondAsNum(L), LLeft) then
      Result := MkNum(LLeft shl LShift)
    else if (LOp = tkShr) and CondShiftCount(R, LShift) and
            CondTryTrunc(CondAsNum(L), LLeft) then
      Result := MkNum(LLeft shr LShift)
    else
      // `in`, division by zero, an out-of-range shift count, an operand too
      // big to be an integer at all - a guess, never a crash.
      Exit;
    Result.Guessed := L.Guessed or R.Guessed;
  end;

var
  LText: string;
  LNum: Double;
  LChild: Integer;
  LVal: TPasCondValue;
begin
  Result := MkGuess;
  if (ANode = NIL_NODE) or (ANode > High(ATree.Nodes)) then
    Exit;
  case ATree.Nodes[ANode].Kind of
    nkIntLit, nkRealLit:
      if CondNumOfText(ATree.NodeText(ANode), LNum) then
        Result := MkNum(LNum);
    nkStrLit:
      begin
        Result := Default(TPasCondValue);
        Result.Kind := cvStr;
        Result.Str := CondStrOfText(ATree.NodeText(ANode));
      end;
    nkIdent:
      begin
        LText := ATree.NodeText(ANode);
        if SameText(LText, 'True') then
          Result := MkBool(True)
        else if SameText(LText, 'False') then
          Result := MkBool(False)
        else if SameText(LText, 'CompilerVersion') or
                SameText(LText, 'RTLVersion') then
          Result := MkNum(ACtx.CompilerVersion)
        else
          // Any other bare name is a CONSTANT only semantics could resolve
          // (`$IF GenericVariants`, System.VarUtils) - the oracle's
          // question; guessed False when nobody answers (`$ELSEIF CPUX64`
          // in the RTL is a DEFINE used bare; dcc evaluates the undeclared
          // name by its quirk, we by the guess).
          Result := AskSymbol(sqConstValue, LText, MkBool(False));
      end;
    nkMember:
      begin
        // A dotted constant reference (`Unit.Const`) - same oracle question
        // with the dotted name; a shape we cannot name stays a guess.
        LText := DottedNameOf(ATree, ANode);
        if LText <> '' then
          Result := AskSymbol(sqConstValue, LText, MkBool(False));
      end;
    nkParen:
      begin
        LChild := ATree.Nodes[ANode].FirstChild;
        if LChild <> NIL_NODE then
          Result := EvalCondNode(ATree, LChild, ACtx);
      end;
    nkUnaryOp:
      begin
        LChild := ATree.Nodes[ANode].FirstChild;
        if (LChild = NIL_NODE) or (ATree.Nodes[ANode].Aux < 0) then
          Exit;
        var LOpKind :=
          ATree.Source.VisibleToken(ATree.Nodes[ANode].Aux).Kind;
        LVal := EvalCondNode(ATree, LChild, ACtx);
        // An abort ignores the operator entirely - `not (UNDECL > 3)` is True,
        // not False. A bare unresolvable name under `not` stays False (dcc's
        // boolean-position verdict), but under unary minus it is arithmetic,
        // so it aborts.
        if LVal.AbortTrue or (LVal.Undef and (LOpKind = tkMinus)) then
          Exit(MkAbortTrue);
        if LVal.Undef then
          Exit(MkBool(False));
        if LOpKind = tkNot then
          Result := MkBool(not CondAsBool(LVal))
        else if LOpKind = tkMinus then
          Result := MkNum(-CondAsNum(LVal))
        else if LOpKind = tkPlus then
          Result := LVal;
        Result.Guessed := LVal.Guessed;
      end;
    nkBinaryOp:
      Result := EvalBinary(ANode);
    nkCall:
      Result := EvalCall(ANode);
    // Everything else: a designator only semantics could resolve - a guess.
  end;
end;

function EvalCondText(const AExpr: string; var ACtx: TPasCondContext;
  out ABadExpr: Boolean): TPasCondValue;
var
  LTree: TPasTree;
  LRoot: Integer;
  LDiags: TArray<TPasParseDiag>;
begin
  LTree := TPasParser.ParseExpressionText(AExpr, LRoot, LDiags);
  ABadExpr := Length(LDiags) > 0;
  Result := EvalCondNode(LTree, LRoot, ACtx);
  if ABadExpr then
    Result := MkBool(False);
end;

end.
