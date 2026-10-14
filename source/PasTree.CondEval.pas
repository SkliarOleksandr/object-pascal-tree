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
    // With Undef: the error token of a DOTTED name whose prefix names nothing
    // (`Foo.Bar`) - it reads False through every operator, arithmetic and
    // `not` included, and never aborts (1.3.2: `Foo.Bar + 1 = 1` and
    // `not Foo.Bar` are both False).
    NoAbort: Boolean;
    // dcc abandoned the whole expression with True. Propagates to the top
    // through every operator, `not` and parens included.
    AbortTrue: Boolean;
  end;

  // One `Defined(X)` argument's span, relative to the expression text
  // EvalCondText was given - the preprocessor turns it into a TPasDefineRef.
  TPasCondSpan = record
    Start: Integer;
    Len: Integer;
  end;

  TPasCondContext = record
    // Inputs.
    Defines: TPasDefines;            // nil tolerated (tree-eval of const
                                     // initializers has no define set; a
                                     // Defined() there just guesses)
    OnDeclared: TPasDeclaredQuery;   // nil = nobody can answer Declared()
    DirPos: TPasCondPos;             // where the directive stands - passed
                                     // to OnDeclared (see TPasCondPos)
    OnSymbol: TPasCondSymbolQuery;   // nil = nobody can answer const/SizeOf/
                                     // Length questions (the first pass)
    CompilerVersion: Double;         // answers RTLVersion too (equal since XE2)
    Target: TPasBuiltinTarget;
    // Outputs.
    UnknownDeclared: TArray<string>; // Declared() names nobody answered
    UnknownSymbols: TArray<TPasUnresolvedSymbol>; // ...and symbol questions
    // Every Defined(<ident>) the expression CONTAINS, source order - a walk
    // of the tree, not a by-product of evaluation, which short-circuits.
    // EvalCondText fills it; EvalCondNode never touches it.
    DefinedSpans: TArray<TPasCondSpan>;
    // Every OTHER name the expression contains - `CompilerVersion`,
    // `RTLVersion`, a unit constant, a `Declared(X)` or `SizeOf(T)` argument,
    // a callee (`Defined`, `SizeOf`) - source order, what a hover or a jump
    // on that name reads. Not a Defined() argument (a conditional symbol,
    // DefinedSpans'); of a dotted `System.CompilerVersion` only the last
    // segment. Filled by EvalCondText (and CollectCondSpans) alongside
    // DefinedSpans.
    NameSpans: TArray<TPasCondSpan>;
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

{ DefinedSpans and NameSpans of AExpr without evaluating it - for a `$ELSEIF`
  after a taken branch and a `$IF` in a skipped region, which are never
  evaluated and whose names a hover still reads. }
procedure CollectCondSpans(const AExpr: string;
  out ADefinedSpans, ANameSpans: TArray<TPasCondSpan>);

{ The branch verdict. }
function CondAsBool(const AValue: TPasCondValue): Boolean;
function CondAsNum(const AValue: TPasCondValue): Double;

{ SizeOf(X) for the SEEDED builtin types only, parameterized by target.
  Public because the projects symbol oracle sizes record FIELDS with it. }
function PasBuiltinSizeOf(const AName: string;
  const ATarget: TPasBuiltinTarget; out ASize: Double): Boolean;

{ The same table, with ALIGNMENT - which is NOT derivable from the size.
  ShortString is 256 bytes aligned to 1, a set is up to 32 bytes aligned to 1,
  and Extended is 10 bytes aligned to 8 (Win32), 16 aligned to 16 (OSX64).
  Anything that lays out a record must ask this rather than clipping the
  size to 8. }
function PasBuiltinLayout(const AName: string;
  const ATarget: TPasBuiltinTarget; out ASize: Double;
  out AAlign: Integer): Boolean;

{ The value range of a builtin ordinal type - the integers by width and
  sign (LongInt by the target's long, NativeInt by its pointer), Boolean,
  ByteBool, Char / WideChar and AnsiChar (AKind cvStr: characters) - the one
  table for `High` / `Low` in a `$IF` and the layout oracle's index and set
  bases (audit D2-02: its own list had drifted). False for any other name. }
function PasBuiltinOrdinalRange(const AName: string;
  const ATarget: TPasBuiltinTarget; out ALo, AHi: Double;
  out AKind: TPasCondKind): Boolean;

{ A target from its four facts (tests and hosts that hold no platform). }
function PasBuiltinTargetOf(APointerBytes, AExtendedBytes, AExtendedAlign,
  ALongBytes: Integer): TPasBuiltinTarget;

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

// The dotted error token (TPasCondValue.NoAbort).
function MkNoAbortErr: TPasCondValue;
begin
  Result := MkUndef;
  Result.NoAbort := True;
end;

function MkStr(const AValue: string): TPasCondValue;
begin
  Result := Default(TPasCondValue);
  Result.Kind := cvStr;
  Result.Str := AValue;
end;

// An operand in a NUMERIC position - arithmetic, `in`, a cast, an
// intrinsic's argument: a name declared nowhere (or a variable, a typed
// constant) aborts the whole `$IF` to True there, the dotted error token
// stays False (1.3.2). True when AValue is such an operand; AResult is then
// the verdict to hand on.
function CondNumericPosition(const AValue: TPasCondValue;
  out AResult: TPasCondValue): Boolean;
begin
  Result := AValue.AbortTrue or AValue.Undef;
  if AValue.AbortTrue or (AValue.Undef and not AValue.NoAbort) then
    AResult := MkAbortTrue
  else if AValue.Undef then
    AResult := MkNoAbortErr;
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
  LU: UInt64;
  LIdx: Integer;
begin
  ANum := 0;
  LClean := PasNumLiteralText(AText);
  if LClean = '' then
    Exit(False);
  case LClean[1] of
    '$':
      begin
        // UInt64: a hex literal above High(Int64) is unsigned for dcc -
        // `$FFFFFFFFFFFFFFFF > 0` is True, `= -1` False (audit B1-08).
        Result := TryStrToUInt64(LClean, LU);
        if Result then
          ANum := LU;
      end;
    '%':
      begin
        if Length(LClean) < 2 then
          Exit(False);
        // The magnitude is checked BEFORE each doubling: past 64 significant
        // bits the shift overflows - a silent wrap with overflow checking
        // off, an EIntOverflow with it on. Rejecting the literal is the
        // behaviour both builds must have, so neither is left to decide it.
        LU := 0;
        for LIdx := 2 to Length(LClean) do
          case LClean[LIdx] of
            '0', '1':
              begin
                if LU > (High(UInt64) shr 1) then
                  Exit(False);
                LU := LU shl 1;
                if LClean[LIdx] = '1' then
                  LU := LU or 1;
              end;
          else
            Exit(False);
          end;
        ANum := LU;
        Result := True;
      end;
  else
    Result := TryStrToFloat(LClean, ANum, TFormatSettings.Invariant);
  end;
end;

// Token text -> string value: quoted runs with their inner quotes un-doubled,
// and `#65` / `#$41` characters between them - one token, `'a'#66'c'` is
// 'aBc' and `#66 = 'B'` holds for dcc (1.3.2, local/probe-b59 P2). False for
// any other spelling (a caret character): the caller guesses.
function CondStrOfText(const AText: string; out AStr: string): Boolean;
var
  LIdx, LStart: Integer;
  LCode: Integer;
  LDigits: string;
begin
  AStr := '';
  Result := False;
  if AText = '' then
    Exit;
  LIdx := 1;
  while LIdx <= Length(AText) do
    case AText[LIdx] of
      '''':
        begin
          Inc(LIdx);
          while True do
          begin
            if LIdx > Length(AText) then
              Exit;   // unterminated
            if AText[LIdx] = '''' then
            begin
              if (LIdx < Length(AText)) and (AText[LIdx + 1] = '''') then
              begin
                AStr := AStr + '''';
                Inc(LIdx, 2);
              end
              else
              begin
                Inc(LIdx);
                Break;
              end;
            end
            else
            begin
              AStr := AStr + AText[LIdx];
              Inc(LIdx);
            end;
          end;
        end;
      '#':
        begin
          Inc(LIdx);
          LStart := LIdx;
          if (LIdx <= Length(AText)) and (AText[LIdx] = '$') then
            Inc(LIdx);
          while (LIdx <= Length(AText)) and
                CharInSet(AText[LIdx], ['0'..'9', 'a'..'f', 'A'..'F', '_']) do
            Inc(LIdx);
          LDigits := PasNumLiteralText(Copy(AText, LStart, LIdx - LStart));
          if not TryStrToInt(LDigits, LCode) or (LCode < 0) or
             (LCode > $FFFF) then
            Exit;
          AStr := AStr + Char(LCode);
        end;
    else
      Exit;
    end;
  Result := True;
end;

// An nkStrLit's value: its adjacent elements - one token each, `'a'#66'c'`
// is three - concatenated (B.6.1).
function CondStrOfNode(const ATree: TPasTree; ANode: Integer;
  out AStr: string): Boolean;
var
  LTok: Integer;
  LP: PChar;
  LLen: Integer;
  LText, LPart: string;
begin
  AStr := '';
  Result := False;
  if (ATree.Nodes[ANode].FirstToken < 0) or
     (ATree.Nodes[ANode].LastToken > High(ATree.Source.Visible)) then
    Exit;
  for LTok := ATree.Nodes[ANode].FirstToken to ATree.Nodes[ANode].LastToken do
  begin
    ATree.Source.VisibleSlice(LTok, LP, LLen);
    SetString(LText, LP, LLen);
    if not CondStrOfText(LText, LPart) then
      Exit;
    AStr := AStr + LPart;
  end;
  Result := True;
end;

function PasBuiltinTargetOf(APointerBytes, AExtendedBytes, AExtendedAlign,
  ALongBytes: Integer): TPasBuiltinTarget;
begin
  Result.PointerBytes := APointerBytes;
  Result.ExtendedBytes := AExtendedBytes;
  Result.ExtendedAlign := AExtendedAlign;
  Result.LongBytes := ALongBytes;
end;

function PasBuiltinSizeOf(const AName: string;
  const ATarget: TPasBuiltinTarget; out ASize: Double): Boolean;
var
  LAlign: Integer;
begin
  Result := PasBuiltinLayout(AName, ATarget, ASize, LAlign);
end;

function PasBuiltinLayout(const AName: string;
  const ATarget: TPasBuiltinTarget; out ASize: Double;
  out AAlign: Integer): Boolean;
var
  LPointerBytes: Integer;
begin
  LPointerBytes := ATarget.PointerBytes;
  // The reference-counted and pointer-like intrinsics: one machine pointer,
  // aligned as one. `string` and friends are reserved words or compiler
  // intrinsics, so nothing in a unit can shadow them with a different size.
  if SameText(AName, 'string') or SameText(AName, 'UnicodeString') or
     SameText(AName, 'AnsiString') or SameText(AName, 'WideString') or
     SameText(AName, 'UTF8String') or SameText(AName, 'RawByteString') or
     SameText(AName, 'PChar') or SameText(AName, 'PAnsiChar') or
     SameText(AName, 'PWideChar') then
  begin
    ASize := LPointerBytes;
    AAlign := LPointerBytes;
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
    if LPointerBytes = 4 then
      ASize := 16
    else
      ASize := 24;
    AAlign := 8;
    Exit(True);
  end;

  // Text / TextFile is TTextRec: 730 bytes on a 32-bit target, 754 on a
  // 64-bit one, pointer-aligned (`record A: Byte; T: TextFile end` is 736 /
  // 768 - dcc32, dcc64, dccaarm, dccaarm64, dccosx64; local/probe-b37 T, A;
  // audit D1-15: the rows were missing and SizeOf refused).
  if SameText(AName, 'Text') or SameText(AName, 'TextFile') then
  begin
    if LPointerBytes = 4 then
      ASize := 730
    else
      ASize := 754;
    AAlign := LPointerBytes;
    Exit(True);
  end;
  // Extended has its own alignment: 8 for the 10-byte Win32 one, 16 for the
  // 16-byte one of the Intel 64-bit POSIX targets (TPasPlatformInfo).
  if SameText(AName, 'Extended') then
  begin
    ASize := ATarget.ExtendedBytes;
    AAlign := ATarget.ExtendedAlign;
    Exit(True);
  end;
  // LongInt / LongWord are 8 bytes on the LP64 targets.
  if SameText(AName, 'LongInt') or SameText(AName, 'LongWord') then
  begin
    ASize := ATarget.LongBytes;
    AAlign := ATarget.LongBytes;
    Exit(True);
  end;

  // Extended80: the 10-byte x87 storage type, aligned to 8 - except on
  // the targets whose Extended is the 16-byte one, where it IS Extended
  // (dccosx64 37.0: SizeOf 16, `record A: Byte; E: Extended80 end` 32;
  // local/probe-b38 X80b). dccosxarm64 aligns its 10 bytes to 16, a fact
  // TPasBuiltinTarget does not carry (docs/coverage.md 2.3.1).
  if SameText(AName, 'Extended80') then
  begin
    if ATarget.ExtendedBytes = 16 then
    begin
      ASize := 16;
      AAlign := 16;
    end
    else
    begin
      ASize := 10;
      AAlign := 8;
    end;
    Exit(True);
  end;

  // The legacy 6-byte float: 6 bytes of storage aligned to 8, not to 6 -
  // dcc-probed (`record A: Byte; F: Real48; end` is 16 on both targets), so
  // the scalar rule below would get it wrong.
  if SameText(AName, 'Real48') then
  begin
    ASize := 6;
    AAlign := 8;
    Exit(True);
  end;

  // The names below are the ones SeedSystemScope registers as BUILTIN types
  // (skBuiltinType, no declaration to walk) - every one of them must have a
  // row here, or SizeOf() of a record holding it refuses. Real/Comp and the
  // sized Booleans were missing until 2026-09-11: Delphi 11's TValueData has
  // an FAsComp branch, so `{$IF SizeOf(TValue) = 32}` in its System.Rtti
  // stayed undecidable.
  Result := True;
  if SameText(AName, 'Pointer') or SameText(AName, 'NativeInt') or
     SameText(AName, 'NativeUInt') then
    ASize := LPointerBytes
  else if SameText(AName, 'Int64') or SameText(AName, 'UInt64') or
    SameText(AName, 'Double') or SameText(AName, 'Currency') or
    SameText(AName, 'Real') or SameText(AName, 'Comp') then
    ASize := 8
  else if SameText(AName, 'Integer') or SameText(AName, 'Cardinal') or
    SameText(AName, 'Single') or SameText(AName, 'LongBool') then
    ASize := 4
  else if SameText(AName, 'Char') or SameText(AName, 'WideChar') or
    SameText(AName, 'Word') or SameText(AName, 'SmallInt') or
    SameText(AName, 'WordBool') then
    ASize := 2
  else if SameText(AName, 'AnsiChar') or SameText(AName, 'Byte') or
    SameText(AName, 'ShortInt') or SameText(AName, 'Boolean') or
    SameText(AName, 'ByteBool') then
    ASize := 1
  else
  begin
    ASize := 0;
    Result := False;
  end;
  // Every remaining builtin is a scalar, and a scalar aligns to its own size
  // (Extended, the one that needed a cap, has its row above).
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
function PasBuiltinCast(const AName: string; const ATarget: TPasBuiltinTarget;
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
  else if SameText(AName, 'Cardinal') then
    LBytes := 4
  else if SameText(AName, 'LongWord') then
    LBytes := ATarget.LongBytes
  else if SameText(AName, 'Integer') then
  begin
    LBytes := 4;
    LSigned := True;
  end
  else if SameText(AName, 'LongInt') then
  begin
    LBytes := ATarget.LongBytes;
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
    LBytes := ATarget.PointerBytes
  else if SameText(AName, 'NativeInt') then
  begin
    LBytes := ATarget.PointerBytes;
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

function PasBuiltinOrdinalRange(const AName: string;
  const ATarget: TPasBuiltinTarget; out ALo, AHi: Double;
  out AKind: TPasCondKind): Boolean;
var
  LBits: Integer;
begin
  Result := True;
  AKind := cvNum;
  ALo := 0;
  AHi := 0;
  if SameText(AName, 'Byte') or SameText(AName, 'UInt8') then
    AHi := 255
  else if SameText(AName, 'ShortInt') or SameText(AName, 'Int8') then
  begin
    ALo := -128;
    AHi := 127;
  end
  else if SameText(AName, 'Word') or SameText(AName, 'UInt16') then
    AHi := 65535
  else if SameText(AName, 'SmallInt') or SameText(AName, 'Int16') then
  begin
    ALo := -32768;
    AHi := 32767;
  end
  else if SameText(AName, 'Integer') or SameText(AName, 'Int32') or
          SameText(AName, 'FixedInt') then
  begin
    ALo := -2147483648.0;
    AHi := 2147483647;
  end
  else if SameText(AName, 'Cardinal') or SameText(AName, 'UInt32') or
          SameText(AName, 'FixedUInt') then
    AHi := 4294967295.0
  else if SameText(AName, 'Int64') then
  begin
    ALo := -9223372036854775808.0;
    AHi := 9223372036854775807.0;
  end
  else if SameText(AName, 'UInt64') then
    AHi := 18446744073709551615.0
  else if SameText(AName, 'LongInt') or SameText(AName, 'NativeInt') or
          SameText(AName, 'LongWord') or SameText(AName, 'NativeUInt') then
  begin
    if SameText(AName, 'LongInt') or SameText(AName, 'LongWord') then
      LBits := ATarget.LongBytes * 8
    else
      LBits := ATarget.PointerBytes * 8;
    if SameText(AName, 'LongInt') or SameText(AName, 'NativeInt') then
    begin
      AHi := Power(2, LBits - 1) - 1;
      ALo := -Power(2, LBits - 1);
    end
    else
      AHi := Power(2, LBits) - 1;
  end
  else if SameText(AName, 'Boolean') or SameText(AName, 'ByteBool') then
  begin
    AKind := cvBool;
    AHi := 1;
  end
  else if SameText(AName, 'Char') or SameText(AName, 'WideChar') then
  begin
    AKind := cvStr;
    AHi := 65535;
  end
  else if SameText(AName, 'AnsiChar') then
  begin
    AKind := cvStr;
    AHi := 255;
  end
  else
    Result := False;
end;

// High or Low of a builtin ordinal type, as the value `$IF` compares: a
// number, a character (`High(Char) = #65535`) or a Boolean (`High(Boolean)`).
// dcc64 37.0, local/probe-b59 P1, P2. False for any other name.
function PasBuiltinOrdinalBound(const AName: string;
  const ATarget: TPasBuiltinTarget; AHigh: Boolean;
  out AValue: TPasCondValue): Boolean;
var
  LLo, LHi: Double;
  LKind: TPasCondKind;
begin
  Result := PasBuiltinOrdinalRange(AName, ATarget, LLo, LHi, LKind);
  if not Result then
    Exit;
  if not AHigh then
    LHi := LLo;
  case LKind of
    cvBool: AValue := MkBool(LHi <> 0);
    cvStr: AValue := MkStr(Char(Trunc(LHi)));
  else
    AValue := MkNum(LHi);
  end;
end;

// The ordinal of a clean value: an integer, a Boolean, one character.
function CondOrdinal(const AValue: TPasCondValue; out AOrd: Int64): Boolean;
begin
  AOrd := 0;
  case AValue.Kind of
    cvNum: Result := (Frac(AValue.Num) = 0) and CondTryTrunc(AValue.Num, AOrd);
    cvBool:
      begin
        AOrd := Ord(AValue.Bool);
        Result := True;
      end;
  else
    begin
      Result := Length(AValue.Str) = 1;
      if Result then
        AOrd := Ord(AValue.Str[1]);
    end;
  end;
end;

// Ord, Chr, Succ, Pred, Abs and Odd over a CLEAN argument, as dcc folds
// them in `$IF` (1.3.2, local/probe-b59 P1, P2). False when AName is none of
// them or the argument has no such value.
function CondFoldIntrinsic(const AName: string; const AArg: TPasCondValue;
  out AValue: TPasCondValue): Boolean;
var
  LOrd: Int64;
begin
  Result := False;
  if SameText(AName, 'Ord') then
  begin
    if CondOrdinal(AArg, LOrd) then
    begin
      AValue := MkNum(LOrd);
      Result := True;
    end;
  end
  else if SameText(AName, 'Chr') then
  begin
    if (AArg.Kind = cvNum) and CondOrdinal(AArg, LOrd) and (LOrd >= 0) and
       (LOrd <= $FFFF) then
    begin
      AValue := MkStr(Char(LOrd));
      Result := True;
    end;
  end
  else if SameText(AName, 'Succ') or SameText(AName, 'Pred') then
  begin
    if not CondOrdinal(AArg, LOrd) then
      Exit;
    if SameText(AName, 'Succ') then
      Inc(LOrd)
    else
      Dec(LOrd);
    case AArg.Kind of
      cvNum: AValue := MkNum(LOrd);
      cvBool:
        if (LOrd < 0) or (LOrd > 1) then
          Exit
        else
          AValue := MkBool(LOrd = 1);
    else
      if (LOrd < 0) or (LOrd > $FFFF) then
        Exit
      else
        AValue := MkStr(Char(LOrd));
    end;
    Result := True;
  end
  else if SameText(AName, 'Abs') then
  begin
    if AArg.Kind = cvNum then
    begin
      AValue := MkNum(Abs(AArg.Num));
      Result := True;
    end;
  end
  else if SameText(AName, 'Odd') then
  begin
    if (AArg.Kind = cvNum) and CondOrdinal(AArg, LOrd) then
    begin
      AValue := MkBool(Odd(LOrd));
      Result := True;
    end;
  end;
end;

// The names a cast or an intrinsic folds under - the operand of each sits in
// a numeric position (CondNumericPosition).
function CondIsFoldingCallee(const AName: string;
  const ATarget: TPasBuiltinTarget): Boolean;
var
  LDummy: Double;
begin
  Result := SameText(AName, 'Ord') or SameText(AName, 'Chr') or
    SameText(AName, 'Succ') or SameText(AName, 'Pred') or
    SameText(AName, 'Abs') or SameText(AName, 'Odd') or
    PasBuiltinCast(AName, ATarget, MkNum(0), LDummy);
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
      if ACtx.OnSymbol(AQuery, AName, ACtx.DirPos, LAns) then
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
      // A dotted name whose prefix names nothing: dcc's error token that
      // never aborts (`Foo.Bar < 5` is False, audit E2-24).
      if LAns.UnknownPrefix and (AQuery = sqConstValue) then
        Exit(MkNoAbortErr);
      // High / Low of a name declared nowhere sits in a numeric position:
      // `High(UNDX) > 1` aborts True (local/probe-b59 P2).
      if LAns.NoSymbol and (AQuery in [sqHighOf, sqLowOf]) then
        Exit(MkAbortTrue);
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
      LArgName := ATree.DottedText(LArg);
      if LArgName = '' then
        Exit;
      if Assigned(ACtx.OnDeclared) and
         ACtx.OnDeclared(LArgName, ACtx.DirPos, LKnown) then
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
         PasBuiltinSizeOf(ATree.NodeText(LArg), ACtx.Target, LSize) then
        Result := MkNum(LSize)
      else
      begin
        // A user type's size: the oracle's question; guessed 0 (like the
        // old evaluator) when nobody answers.
        LArgName := ATree.DottedText(LArg);
        // An instantiation, `TPair<Byte, Int64>`, goes to the oracle as its
        // text: the head and each actual a name (audit E2-25).
        if (LArgName = '') and (ATree.Nodes[LArg].Kind = nkTypeArgs) then
        begin
          var LPart := ATree.Nodes[LArg].FirstChild;
          if LPart <> NIL_NODE then
            LArgName := ATree.DottedText(LPart);
          var LArgs := '';
          if LArgName <> '' then
            LPart := ATree.Nodes[LPart].NextSibling;
          while (LArgName <> '') and (LPart <> NIL_NODE) do
          begin
            var LOne := ATree.DottedText(LPart);
            if LOne = '' then
              LArgName := ''
            else if LArgs = '' then
              LArgs := LOne
            else
              LArgs := LArgs + ',' + LOne;
            LPart := ATree.Nodes[LPart].NextSibling;
          end;
          if (LArgName <> '') and (LArgs <> '') then
            LArgName := LArgName + '<' + LArgs + '>'
          else
            LArgName := '';
        end;
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
      LArgName := ATree.DottedText(LArg);
      if LArgName <> '' then
        Result := AskSymbol(sqLengthOf, LArgName, MkNum(0))
      else if ATree.Nodes[LArg].Kind = nkStrLit then
      begin
        // `Length('xy')` and `Length('a'#66'c')` fold (dcc64 37.0,
        // local/probe-b58 P2, local/probe-b59 P2).
        if CondStrOfNode(ATree, LArg, LArgName) then
          Result := MkNum(Length(LArgName));
      end;
    end
    else if SameText(LName, 'High') or SameText(LName, 'Low') then
    begin
      // A builtin ordinal answers from the table; an enum or a subrange is
      // the oracle's question (`High(TE) = e3`, local/probe-b59 P1).
      if (ATree.Nodes[LArg].Kind = nkIdent) and
         PasBuiltinOrdinalBound(ATree.NodeText(LArg), ACtx.Target,
           SameText(LName, 'High'), Result) then
        Exit;
      LArgName := ATree.DottedText(LArg);
      if LArgName = '' then
        Exit;
      if SameText(LName, 'High') then
        Result := AskSymbol(sqHighOf, LArgName, MkNum(0))
      else
        Result := AskSymbol(sqLowOf, LArgName, MkNum(0));
    end
    else
    begin
      // An ordinal type-cast or intrinsic folds like dcc does - but ONLY
      // when its operand is clean. A cast wrapped around a guess would turn
      // the guess into a confident-looking number and hide the open
      // question.
      LArgVal := EvalCondNode(ATree, LArg, ACtx);
      // Its operand sits in a numeric position: a name declared nowhere
      // aborts the `$IF` to True (`Byte(UNDECL) = 1`, `Ord(UNDECL) = 1`,
      // `Odd(UNDECL)` - audit E2-19), the dotted error token stays False.
      if CondIsFoldingCallee(LName, ACtx.Target) and
         CondNumericPosition(LArgVal, Result) then
        Exit;
      if CondIsClean(LArgVal) then
      begin
        if CondFoldIntrinsic(LName, LArgVal, Result) then
          Exit;
        if PasBuiltinCast(LName, ACtx.Target, LArgVal, LSize) then
          Exit(MkNum(LSize));
      end;
      Result := MkGuess;
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
      // The dotted error token never aborts (`Foo.Bar < 5` is False).
      if (L.Undef and L.NoAbort) or (R.Undef and R.NoAbort) then
        Result := MkNoAbortErr
      else if (L.Undef or (L.Kind = cvNum)) and
              (R.Undef or (R.Kind = cvNum)) then
        Exit(MkAbortTrue)
      else
        // The error token survives the comparison: an enclosing `not` must
        // not invert it - `not (UNDECL >= '1.0')` and `(not UNDECL) = False`
        // are False for dcc (audit E2-18).
        Result := MkUndef;
      // ...and it must NOT launder the other side's guess: an Undef against
      // a GUESSED Boolean left clean also left EvalIfExpression with nothing
      // to copy, so no UnknownSymbols reached the stream, no
      // ppIfNeedsSemantics was emitted, and the second-pass question simply
      // vanished.
      Result.Guessed := L.Guessed or R.Guessed;
      Exit;
    end;
    // A string against a number or a Boolean is dcc's E2008, no ordering:
    // two clean such operands compare as nothing. A guessed side keeps the
    // numeric reading the first pass was calibrated on.
    if ((L.Kind = cvStr) <> (R.Kind = cvStr)) and not L.Guessed and
       not R.Guessed then
      Exit(MkGuess);
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

  // A binary node evaluable as such: both operands and the operator token.
  // Anything else evaluates as a guess without looking at its operands.
  function BinaryShape(ABinNode: Integer;
    out ALeftNode, ARightNode: Integer): Boolean;
  begin
    Result := False;
    ARightNode := NIL_NODE;
    ALeftNode := ATree.Nodes[ABinNode].FirstChild;
    if ALeftNode = NIL_NODE then
      Exit;
    ARightNode := ATree.Nodes[ALeftNode].NextSibling;
    Result := (ARightNode <> NIL_NODE) and (ATree.Nodes[ABinNode].Aux >= 0);
  end;

  function CombineBinary(ABinNode: Integer;
    const L, R: TPasCondValue): TPasCondValue; forward;

  // An operator chain is a LEFT spine as deep as it is long (`1 + 1 + ...`,
  // a generated `$IF`): recursing per operand overflowed the stack at about
  // 1,560 operands (audit B1-02). The spine is walked down iteratively and
  // folded back up - the operands are still evaluated left to right, the
  // order the oracle's questions and recorded unknowns were always in.
  function EvalBinary(ABinNode: Integer): TPasCondValue;
  var
    LSpine: TArray<Integer>;
    LCount, LIdx, LNode, LLeftNode, LRightNode: Integer;
    L: TPasCondValue;
  begin
    Result := MkGuess;
    if not BinaryShape(ABinNode, LLeftNode, LRightNode) then
      Exit;
    LCount := 0;
    LNode := ABinNode;
    while True do
    begin
      if LCount = Length(LSpine) then
        SetLength(LSpine, LCount * 2 + 8);
      LSpine[LCount] := LNode;
      Inc(LCount);
      if (ATree.Nodes[LLeftNode].Kind <> nkBinaryOp) or
         not BinaryShape(LLeftNode, LNode, LRightNode) then
        Break;
      // LNode is now the left child's left operand; step onto the child.
      LIdx := LNode;
      LNode := LLeftNode;
      LLeftNode := LIdx;
    end;
    L := EvalCondNode(ATree, LLeftNode, ACtx);
    for LIdx := LCount - 1 downto 0 do
    begin
      BinaryShape(LSpine[LIdx], LNode, LRightNode);
      L := CombineBinary(LSpine[LIdx], L,
        EvalCondNode(ATree, LRightNode, ACtx));
    end;
    Result := L;
  end;

  // `X in [...]` over a set constructor of numbers, ranges, characters and
  // enum values (`3 in [1..5]`, `'b' in ['a'..'c']`, `e2 in [e1, e2]` -
  // audit E2-23). An element in a numeric position aborts like an operand
  // (`1 in [UNDECL]` is True); one with no clean ordinal leaves a miss a
  // guess.
  function EvalIn(ABinNode: Integer; const L: TPasCondValue): TPasCondValue;
  var
    LLeftNode, LSetNode, LElem, LLoNode: Integer;
    LWanted, LLo, LHi: Int64;
    LLoVal, LHiVal: TPasCondValue;
    LOpen, LFound: Boolean;
  begin
    Result := MkGuess;
    if not BinaryShape(ABinNode, LLeftNode, LSetNode) or
       (ATree.Nodes[LSetNode].Kind <> nkSetCtor) then
      Exit;
    LOpen := not CondIsClean(L) or not CondOrdinal(L, LWanted);
    LFound := False;
    LElem := ATree.Nodes[LSetNode].FirstChild;
    while LElem <> NIL_NODE do
    begin
      if ATree.Nodes[LElem].Kind in [nkRange, nkSubrange] then
      begin
        LLoNode := ATree.Nodes[LElem].FirstChild;
        LLoVal := EvalCondNode(ATree, LLoNode, ACtx);
        if LLoNode <> NIL_NODE then
          LHiVal := EvalCondNode(ATree, ATree.Nodes[LLoNode].NextSibling, ACtx)
        else
          LHiVal := MkGuess;
      end
      else
      begin
        LLoVal := EvalCondNode(ATree, LElem, ACtx);
        LHiVal := LLoVal;
      end;
      if CondNumericPosition(LLoVal, Result) or
         CondNumericPosition(LHiVal, Result) then
        Exit;
      if CondIsClean(LLoVal) and CondIsClean(LHiVal) and
         CondOrdinal(LLoVal, LLo) and CondOrdinal(LHiVal, LHi) then
      begin
        if not LOpen and (LWanted >= LLo) and (LWanted <= LHi) then
          LFound := True;
      end
      else
        LOpen := True;
      LElem := ATree.Nodes[LElem].NextSibling;
    end;
    Result := MkBool(LFound);
    Result.Guessed := not LFound and LOpen;
  end;

  function CombineBinary(ABinNode: Integer;
    const L, R: TPasCondValue): TPasCondValue;
  var
    LOp: TPasTokenKind;
    LShift: Integer;
    LLeft, LRight: Int64;   // CondTryTrunc's answers - see there
  begin
    Result := MkGuess;
    // The operator's token KIND - every operator here is a reserved word or
    // punctuation with a dedicated kind, so no text is built to dispatch.
    LOp := ATree.Source.VisibleToken(ATree.Nodes[ABinNode].Aux).Kind;

    // and/or/xor of two integers are BITWISE in a constant expression:
    // `(6 and 1) <> 0` is False, `(1 or 2) = 3` True (audit E2-22).
    if (LOp in [tkAnd, tkOr, tkXor]) and (L.Kind = cvNum) and
       (R.Kind = cvNum) and (Frac(L.Num) = 0) and (Frac(R.Num) = 0) and
       CondTryTrunc(L.Num, LLeft) and CondTryTrunc(R.Num, LRight) then
    begin
      case LOp of
        tkAnd: Result := MkNum(LLeft and LRight);
        tkOr: Result := MkNum(LLeft or LRight);
      else
        Result := MkNum(LLeft xor LRight);
      end;
      Result.Guessed := L.Guessed or R.Guessed;
      Exit;
    end;

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
    // rule: `UNDECL + 1 = 1` and `1 shl UNDECL = 2` both take the TRUE branch;
    // the dotted error token stays False (`Foo.Bar + 1 = 1`). Left first, as
    // dcc reads it.
    if CondNumericPosition(L, Result) or CondNumericPosition(R, Result) then
      Exit;

    if LOp = tkIn then
      Exit(EvalIn(ABinNode, L));

    // Strings concatenate (`'ab' + 'cd' = 'abcd'`, a constant `'10.' + '5'`);
    // any other arithmetic on a string is dcc's E2008 - a guess, never the
    // number 0 that compared equal to every string (audit A1-12).
    if (L.Kind = cvStr) or (R.Kind = cvStr) then
    begin
      if (LOp = tkPlus) and (L.Kind = cvStr) and (R.Kind = cvStr) then
      begin
        Result := MkStr(L.Str + R.Str);
        Result.Guessed := L.Guessed or R.Guessed;
      end;
      Exit;
    end;

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
      // Division by zero, an out-of-range shift count, an operand too big to
      // be an integer at all - a guess, never a crash.
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
      if CondStrOfNode(ATree, ANode, LText) then
        Result := MkStr(LText);
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
        LText := ATree.DottedText(ANode);
        // `System.CompilerVersion` is the compiler's value like the bare
        // name: System.pas declares it 0.0 and dcc assigns it (dcc64 37.0
        // takes `$IF System.CompilerVersion >= 36`, local/probe-b58 P1).
        if SameText(LText, 'System.CompilerVersion') or
           SameText(LText, 'System.RTLVersion') then
          Result := MkNum(ACtx.CompilerVersion)
        else if LText <> '' then
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
        // not False. An unresolvable name under `not` stays the error token
        // that reads False - `not not UNDECL` is False too (audit E2-18) -
        // while under unary minus or plus it is arithmetic, so it aborts; the
        // dotted error token stays False under every operator.
        if LVal.AbortTrue then
          Exit(MkAbortTrue);
        if LVal.Undef then
        begin
          if LVal.NoAbort then
            Exit(MkNoAbortErr);
          if LOpKind = tkNot then
          begin
            Result := MkUndef;
            Result.Guessed := LVal.Guessed;
            Exit;
          end;
          Exit(MkAbortTrue);
        end;
        if (LOpKind = tkNot) and (LVal.Kind = cvNum) then
        begin
          // Bitwise on an integer: `not 0 = -1` (audit E2-22).
          var LInt: Int64;
          if (Frac(LVal.Num) = 0) and CondTryTrunc(LVal.Num, LInt) then
            Result := MkNum(not LInt);
        end
        else if LOpKind = tkNot then
          Result := MkBool(not CondAsBool(LVal))
        else if LOpKind = tkMinus then
          Result := MkNum(-CondAsNum(LVal))
        else if LOpKind = tkPlus then
          Result := LVal;
        Result.Guessed := Result.Guessed or LVal.Guessed;
      end;
    nkBinaryOp:
      Result := EvalBinary(ANode);
    nkCall:
      Result := EvalCall(ANode);
    // Everything else: a designator only semantics could resolve - a guess.
  end;
end;

// Appends the span of every `Defined(<ident>)` argument under ANode to
// ASpans. Source order (a pre-order walk of a source-ordered tree).
procedure CollectDefinedSpans(const ATree: TPasTree; ANode: Integer;
  var ASpans: TArray<TPasCondSpan>);
var
  LCallee, LArg, LChild, LTok: Integer;
  LSpan: TPasCondSpan;
begin
  if ANode = NIL_NODE then
    Exit;
  if ATree.Nodes[ANode].Kind = nkCall then
  begin
    LCallee := ATree.Nodes[ANode].FirstChild;
    if (LCallee <> NIL_NODE) and (ATree.Nodes[LCallee].Kind = nkIdent) and
       ATree.NodeTextEquals(LCallee, 'Defined') then
    begin
      LArg := ATree.Nodes[LCallee].NextSibling;
      if (LArg <> NIL_NODE) and (ATree.Nodes[LArg].Kind = nkIdent) then
      begin
        LTok := ATree.Nodes[LArg].FirstToken;
        if (LTok >= 0) and (LTok <= High(ATree.Source.Visible)) then
        begin
          LSpan.Start := ATree.Source.VisibleToken(LTok).Start;
          LSpan.Len := ATree.Source.VisibleToken(LTok).Len;
          ASpans := ASpans + [LSpan];
        end;
      end;
    end;
  end;
  LChild := ATree.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    CollectDefinedSpans(ATree, LChild, ASpans);
    LChild := ATree.Nodes[LChild].NextSibling;
  end;
end;

// Appends the span of every name under ANode that is not a Defined()
// argument - see TPasCondContext.NameSpans. A dotted name gives its last
// segment (nkMember: qualifier first, the member name last). Source order, as
// CollectDefinedSpans.
procedure CollectNameSpans(const ATree: TPasTree; ANode: Integer;
  var ASpans: TArray<TPasCondSpan>);
var
  LChild, LTok, LCallee: Integer;
  LSpan: TPasCondSpan;
begin
  if ANode = NIL_NODE then
    Exit;
  case ATree.Nodes[ANode].Kind of
    nkIdent:
      begin
        LTok := ATree.Nodes[ANode].FirstToken;
        if (LTok >= 0) and (LTok <= High(ATree.Source.Visible)) then
        begin
          LSpan.Start := ATree.Source.VisibleToken(LTok).Start;
          LSpan.Len := ATree.Source.VisibleToken(LTok).Len;
          ASpans := ASpans + [LSpan];
        end;
        Exit;
      end;
    nkMember:
      begin
        // The qualifier (a unit name, mostly) is skipped; the name is the
        // last child.
        LChild := ATree.Nodes[ANode].FirstChild;
        while (LChild <> NIL_NODE) and
              (ATree.Nodes[LChild].NextSibling <> NIL_NODE) do
          LChild := ATree.Nodes[LChild].NextSibling;
        if (LChild <> NIL_NODE) and (ATree.Nodes[LChild].Kind = nkIdent) then
          CollectNameSpans(ATree, LChild, ASpans);
        Exit;
      end;
    nkCall:
      begin
        LCallee := ATree.Nodes[ANode].FirstChild;
        if LCallee = NIL_NODE then
          Exit;
        // The callee is a name too - `SizeOf` is System's, `Defined` and
        // `Declared` the directive's own (Alex, 2026-10-09: no hint there).
        CollectNameSpans(ATree, LCallee, ASpans);
        // Defined(X): X is a conditional symbol, DefinedSpans' row.
        if (ATree.Nodes[LCallee].Kind = nkIdent) and
           ATree.NodeTextEquals(LCallee, 'Defined') then
          Exit;
        LChild := ATree.Nodes[LCallee].NextSibling;   // the arguments
        while LChild <> NIL_NODE do
        begin
          CollectNameSpans(ATree, LChild, ASpans);
          LChild := ATree.Nodes[LChild].NextSibling;
        end;
        Exit;
      end;
  end;
  LChild := ATree.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    CollectNameSpans(ATree, LChild, ASpans);
    LChild := ATree.Nodes[LChild].NextSibling;
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
  ACtx.DefinedSpans := nil;
  CollectDefinedSpans(LTree, LRoot, ACtx.DefinedSpans);
  ACtx.NameSpans := nil;
  CollectNameSpans(LTree, LRoot, ACtx.NameSpans);
  Result := EvalCondNode(LTree, LRoot, ACtx);
  if ABadExpr then
    Result := MkBool(False);
end;

procedure CollectCondSpans(const AExpr: string;
  out ADefinedSpans, ANameSpans: TArray<TPasCondSpan>);
var
  LTree: TPasTree;
  LRoot: Integer;
  LDiags: TArray<TPasParseDiag>;
begin
  LTree := TPasParser.ParseExpressionText(AExpr, LRoot, LDiags);
  ADefinedSpans := nil;
  CollectDefinedSpans(LTree, LRoot, ADefinedSpans);
  ANameSpans := nil;
  CollectNameSpans(LTree, LRoot, ANameSpans);
end;

end.
