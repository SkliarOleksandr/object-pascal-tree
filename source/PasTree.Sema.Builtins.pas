unit PasTree.Sema.Builtins;

{
  PasTree semantics - seeds a unit's implicit System scope with the built-in
  types (categorized for the type checker), constants and intrinsic routines,
  so intra-unit references to them resolve. Adapted from AST.Delphi.SysTypes /
  DataTypes groupings.

  SHARED-TEMPLATE SEEDING (the audit's "shared immutable builtin scope", done
  the identity-preserving way): the ~180 symbols are built ONCE per platform
  bitness at unit init, and every model then bulk-adopts them - the symbol
  RECORDS are copied per model (so a builtin's identity stays (mid, sym),
  which the helper registry's '~name' canonicalization and every per-model
  seed retry rely on; string fields share their heap data by refcount), while
  the scope's Names (names and declaration order) are the template's own,
  referenced read-only by every model. That is safe precisely because they
  are immutable after init - and future-proofed anyway: a write through
  BindName/AddToOrder copy-on-writes them (TSemaScope.EnsureOwnedContainers).
  A model whose symbol arena is not empty at seed time falls back to the
  original symbol-by-symbol path below.
}

interface

uses
  PasTree.Platforms,
  PasTree.Sema.Model;

// Creates and populates the system scope; returns its scope index.
// APlatform gates the few intrinsics that exist on 64-bit targets only.
function SeedSystemScope(AModel: TPasSemaModel;
  APlatform: TPasPlatform = pfWin32): Integer;

type
  { A curated DISPLAY signature for one intrinsic routine (completion plan
    sec. 8C). The seeds have no DeclNode, so every declaration-span consumer
    (parameter text, signature help, auto-parenthesis) shows them bare
    without this. These are documentation-style pseudo-signatures FOR HUMANS
    - `(var S; NewLength: NativeInt)` - never input to the typer; where the
    real signature is type-dependent (High, Abs, Ord, ...) the text stays
    honest about the shape and the result is left blank. The result text is
    DERIVED from the typer's shape (TPasIntrinsicResult), so the display
    cannot disagree with what the typers give the call (audit B2-15, D1-16:
    Hi / Lo showed Byte while the typers said Integer and dcc says Word). }
  TPasBuiltinSig = record
    Params: string;      // '(...)' display text; '' for a parameterless name
    ResultType: string;  // result display text; '' for procedures and
                         // type-dependent results
    { A value-returning intrinsic, whether its result is fixed or not - the
      head word `function` against `procedure` (High, Copy, Abs have no
      fixed result text but are functions). }
    IsFunction: Boolean;
    { The auto-parenthesis driver, ItemHasParams's builtin answer: True when
      the normal call form takes at least one REQUIRED argument. False both
      for the truly parameterless (Pi, ReturnAddress) and for names whose
      every argument is optional (Exit, Halt, Break) - those must complete
      bare, exactly like an empty-() declaration. Params may still be
      non-empty when HasArgs is False: Exit renders '(ExitValue)' in
      signature help but never auto-parenthesizes. }
    HasArgs: Boolean;
  end;

{ The display signature of a compiler-seeded routine, by NameLower. False for
  names this table does not know - including every seeded CONST (True, nil,
  CompilerVersion) and any real declaration, which carry a DeclNode and never
  need this. }
function PasBuiltinSignature(const ANameLower: string;
  out ASig: TPasBuiltinSig): Boolean;

{ The seeded names that denote ONE type, as a group - `Cardinal`, `LongWord` and
  (through System.pas's `UInt32 = Cardinal`) `UInt32` are the same type, not
  three compatible ones. Returns the group for a name that is in one, and just
  the name otherwise; the caller therefore never needs to know which.

  dcc32 37.0-probed with a `record helper for Cardinal`: it applies to values
  declared `Cardinal`, `LongWord` and `UInt32` alike, and is `E2671` on an
  `Integer` - so this is identity, not assignment compatibility, and the five
  groups below are exactly the ones a helper crosses. The same probe run for
  `Integer`/`LongInt`/`Int32`, `Char`/`WideChar` and `string`/`UnicodeString`;
  `Word` against the Integer helper is the negative that pins the boundary.
  `PChar`/`PWideChar` too: of a helper for each, the later is the active one
  for both (audit B2-14). Overload resolution takes the same identity - an
  argument spelled with one name is an EXACT match for a parameter spelled
  with the other (6.3.1; dcc64 37.0, local/probe-b31 O1) - through
  PasBuiltinCanonSym.

  `NativeInt` and `NativeUInt` join the group of the integer of their size
  (APointerBytes): dcc 37.0 defines WEAK_NATIVEINT on every target - a weak
  alias - and System.SysUtils then declares no TNativeIntHelper, so
  `N.ToString` of a NativeInt is TIntegerHelper's on dcc32 and TInt64Helper's
  on dcc64 (`N.Size` 4 and 8). Both ways: a helper for Integer is a
  NativeInt's on dcc32, a helper for NativeUInt a Cardinal's there and a
  UInt64's on dcc64 (probed, local/fidelity/x-f20/probes/helper).

  `LongInt` and `LongWord` join Integer / Cardinal only where they are 4
  bytes (ALongBytes, TPasPlatformInfo.LongBytes): on the LP64 targets they are
  8-byte types of their own - not Int64 either (dccaarm64 / dccosx64 37.0:
  F(LongInt) and F(Int64) are two overloads, a helper for Int64 is no
  LongInt's; audit A1-10). }
function PasBuiltinAliasGroup(const ANameLower: string;
  APointerBytes: Integer; ALongBytes: Integer = 4): TArray<string>;

{ One id per seeded TYPE: the seed index of the first name of ASym's alias
  group (PasBuiltinAliasGroup on the target's pointer size) - `LongInt`'s is
  `Integer`'s, `WideChar`'s `Char`'s, a 64-bit `NativeInt`'s `Int64`'s - and
  ASym itself for every other symbol. AModel's seeds sit at the template's
  indexes (SeedSystemScope adopts them into an empty arena, which is why
  XSameType already compares two models' seeds by index); a symbol that is
  not a seed is answered unchanged. The ONE table both overload scorers, the
  instance key and XSameType read, so the two typers cannot drift. }
function PasBuiltinCanonSym(AModel: TPasSemaModel; ASym: Integer;
  APlatform: TPasPlatform): Integer;

{ Is ASym the seeded `Char` (or `WideChar`) - the type of a one-character
  literal, which an overload taking `Char` fits better than one taking a
  string, and one taking `AnsiChar` worse (dcc64 37.0, local/probe-b31 O2:
  'a' picks WideChar over AnsiChar, string over AnsiChar). }
function PasBuiltinIsChar(AModel: TPasSemaModel; ASym: Integer;
  APlatform: TPasPlatform): Boolean;

type
  { How a value-returning intrinsic's RESULT type is decided (4.11.4). Every
    shape below is a dcc 37.0 probe on BOTH compilers, read through the type
    dcc USES - the overload a call of the result picks and the type
    `var X := Intrinsic(...)` infers (local/probe-b38: one overload per
    builtin type, `F(Ord(AC)).R_Byte`) - not through the E2010 text of a
    direct assignment, which names Integer for every narrow result (audit
    A1-14, E1-38: the first table was read that way). A CONSTANT argument -
    a literal, a true constant, an enumeration value - folds: Ord, Hi, Lo
    and Swap of one are Integer. The two typers (PasTree.Sema.Types
    intra-unit, PasTree.Sema.Project cross-unit) dispatch on this and apply
    the same rules to their own type descriptors; a name that is not here
    (a procedure, or Slice) stays untyped. }
  TPasIntrinsicResult = (
    irNone,
    // Fixed type, whatever the arguments: SizeOf, FilePos and FileSize are
    // Integer, Trunc/Round/MulDivInt64 are Int64 even of a Single, Chr is
    // Char, Pi is Extended (dcc64 prints it as Double, which is what
    // Extended IS on a 64-bit target), the address family and TypeInfo/
    // TypeHandle/TypeOf are the untyped Pointer, NameOf is string.
    irInteger, irInt64, irBoolean, irChar, irExtended, irPointer, irString,
    // Length: Integer, except NativeInt for a DYNAMIC array (Int64 on
    // dcc64, Integer on dcc32 - the one platform-dependent Length).
    irLength,
    // Abs: an integer widens by WIDTH (Byte..Cardinal -> Integer, 64-bit ->
    // Int64, NativeInt/NativeUInt -> NativeInt); a real is Extended on a
    // 32-bit target, and on a 64-bit one Currency stays Currency and Comp
    // stays Comp (their arithmetic is integral there) while every other
    // real is Extended. A Variant is Extended.
    irAbs,
    // Sqr: an integer widens like Abs except that a 32-bit UNSIGNED stays
    // Cardinal and the 64-bit ones keep their signedness (UInt64 -> UInt64,
    // NativeUInt -> NativeUInt); every real, Currency and Comp included, and
    // a Variant are Extended.
    irSqr,
    // Pred, Succ: an integer narrower than 32 bits, or an integer subrange,
    // is Integer; a 32- or 64-bit builtin keeps its type (Cardinal,
    // UInt64, NativeUInt); an enum, Char, AnsiChar or Boolean keeps its own
    // type, and a subrange of one is its base type (`Pred(CS)` of a
    // `'a'..'z'` is Char).
    irOrdinal,
    // Low, High: an ordinal type or value as irOrdinal (`High(Cardinal)`
    // Cardinal, `High(Byte)` Integer); a static array's INDEX type the same
    // way (`array[Byte]` bounds are Integer, an enum-indexed array's the
    // enum, a Char-indexed one's Char); a dynamic array's Low is Integer and
    // its High NativeInt; any string's are Integer (High of the long-string
    // TYPE itself is E2198).
    irBounds,
    // Swap: a 16- or 32-bit integer keeps its type (Word, SmallInt, Integer,
    // Cardinal), a Byte or ShortInt is SmallInt, an Int64 and a constant
    // Integer.
    irSwap,
    // Ord: a 32-bit-or-narrower integer keeps its type (Ord(B) Byte,
    // Ord(C) Cardinal), a 64-bit one is Integer; Char / WideChar is Word,
    // AnsiChar Byte; ByteBool Byte, WordBool Word, LongBool Integer; an
    // enumeration, Boolean or subrange value the narrowest of ShortInt,
    // Byte, SmallInt, Word, Integer, Cardinal holding its range (Boolean and
    // `'a'..'z'` ShortInt, `0..200` Byte, `0..1000` SmallInt, `0..60000`
    // Word); a constant Integer.
    irOrd,
    // Hi, Lo: Word, whatever the width; of a constant Integer.
    irHiLo,
    // The first argument's own type: Copy (a string kind stays that kind, a
    // dynamic array stays that array, a literal is string) and the Atomic*
    // family (Increment/Decrement/Exchange/CmpExchange over an integer or a
    // Pointer).
    irFirstArg,
    // Concat: arguments of ONE type keep it (AnsiString+AnsiString is
    // AnsiString, TDynI+TDynI is TDynI) with two exceptions - ShortString+
    // ShortString is AnsiString and AnsiChar+AnsiChar is ShortString; mixed
    // string kinds, Char operands and literals are `string`.
    irConcat,
    // Default(T): T itself for a record, an ordinal, a real, a string, a
    // STATIC array; the untyped Pointer for every reference type - class,
    // interface, dynamic array, procedural type, class reference, pointer
    // (`var X := Default(TObj); X.Free` is E2018 under dcc).
    irDefault,
    // GetTypeKind: System.TTypeKind, a real declaration in System.pas that
    // only the project level can reach.
    irTypeKind);

{ The result shape of the seeded intrinsic ROUTINE named ANameLower - irNone
  for a procedure, for Slice, and for any name that is not an intrinsic. }
function PasIntrinsicResult(const ANameLower: string): TPasIntrinsicResult;

{ Does AShape read its ARGUMENTS' types? False for the fixed-type shapes, so
  a caller can skip typing the arguments of `Ord(X)` or `SizeOf(T)`. }
function PasIntrinsicReadsArgs(AShape: TPasIntrinsicResult): Boolean; inline;

{ The display text of a FIXED result shape ('Integer', 'Word' for Hi / Lo,
  'TTypeKind'); '' for an argument-dependent shape and for irNone. What
  PasBuiltinSignature shows - one source for the display and the typers. }
function PasIntrinsicResultText(AShape: TPasIntrinsicResult): string;

implementation

uses
  System.SysUtils,
  System.Generics.Collections,
  PasTree.Ast;

function PasBuiltinAliasGroup(const ANameLower: string;
  APointerBytes: Integer; ALongBytes: Integer): TArray<string>;
const
  // Only the SEEDED names need to be here: a real declaration like System.pas's
  // `UInt32 = Cardinal` is an alias the type walk already follows.
  CGroups: array[0..4] of TArray<string> = (
    ['integer', 'longint'],
    ['cardinal', 'longword'],
    ['char', 'widechar'],
    ['string', 'unicodestring'],
    ['pchar', 'pwidechar']);
  // The weak native aliases by the target's pointer size, looked up first:
  // on a 32-bit target they extend the first two groups above.
  CNative: array[Boolean, 0..1] of TArray<string> = (
    (['integer', 'longint', 'nativeint'],
     ['cardinal', 'longword', 'nativeuint']),
    (['int64', 'nativeint'], ['uint64', 'nativeuint']));
var
  LIdx, LName: Integer;
begin
  if (ALongBytes = 8) and
     ((ANameLower = 'longint') or (ANameLower = 'longword')) then
  begin
    Result := [ANameLower];
    Exit;
  end;
  for LIdx := 0 to 1 do
    for LName := 0 to High(CNative[APointerBytes = 8][LIdx]) do
      if CNative[APointerBytes = 8][LIdx][LName] = ANameLower then
        Exit(CNative[APointerBytes = 8][LIdx]);
  for LIdx := 0 to High(CGroups) do
    for LName := 0 to High(CGroups[LIdx]) do
      if CGroups[LIdx][LName] = ANameLower then
      begin
        Result := CGroups[LIdx];
        // On LP64 the 8-byte LongInt / LongWord are no member of the group.
        if ALongBytes = 8 then
          Result := [Result[0]];
        Exit;
      end;
  Result := [ANameLower];
end;

type
  // Where an intrinsic exists: everywhere, on every target but Win32 (the
  // VarArg family), or on a 64-bit target only (AtomicCmpExchange128).
  TIntrinsicGate = (igAll, igVarArg, ig64Bit);

  TIntrinsicEntry = record
    Name: string;        // the seed's spelling; NameLower is the key
    Params: string;
    HasArgs: Boolean;
    Shape: TPasIntrinsicResult;
    Gate: TIntrinsicGate;
  end;

const
  { THE intrinsic table - one entry per seeded intrinsic ROUTINE, in seed
    order; SeedSystemScopeOwn seeds from it (by Gate), the typers read Shape
    (PasIntrinsicResult) and completion the display columns
    (PasBuiltinSignature), whose result text is derived from Shape. Three
    hand-kept lists had drifted apart before (audit B2-15, D1-16: Hi / Lo
    displayed Byte, FilePos / FileSize / NameOf / AtomicCmpExchange128 showed
    a result no typer gave). Params follow the documented "Delphi Intrinsic
    Routines" catalog; optional arguments are shown in [] the way the docs
    write them. }
  CIntrinsics: array[0..98] of TIntrinsicEntry = (
    (Name: 'Length'; Params: '(const S: <string|array>)';
     HasArgs: True; Shape: irLength; Gate: igAll),
    (Name: 'SetLength'; Params: '(var S; NewLength: NativeInt)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'SetString'; Params: '(var S: string; Buffer: PChar; Len: Integer)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'High'; Params: '(const X: <type|array|string>)';
     HasArgs: True; Shape: irBounds; Gate: igAll),
    (Name: 'Low'; Params: '(const X: <type|array|string>)';
     HasArgs: True; Shape: irBounds; Gate: igAll),
    (Name: 'Ord'; Params: '(const X: <ordinal>)';
     HasArgs: True; Shape: irOrd; Gate: igAll),
    (Name: 'Chr'; Params: '(X: Byte)';
     HasArgs: True; Shape: irChar; Gate: igAll),
    (Name: 'Assigned'; Params: '(const P)';
     HasArgs: True; Shape: irBoolean; Gate: igAll),
    (Name: 'Inc'; Params: '(var X[; N])';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'Dec'; Params: '(var X[; N])';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'SizeOf'; Params: '(const X)';
     HasArgs: True; Shape: irInteger; Gate: igAll),
    (Name: 'Assert'; Params: '(Condition: Boolean[; Message: string])';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'Copy'; Params: '(const S[; Index, Count: Integer])';
     HasArgs: True; Shape: irFirstArg; Gate: igAll),
    (Name: 'New'; Params: '(var P: Pointer)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'Dispose'; Params: '(var P: Pointer)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'Include'; Params: '(var S: <set>; Element)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'Exclude'; Params: '(var S: <set>; Element)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'Write'; Params: '([var F: Text;] Args)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'Writeln'; Params: '([var F: Text;] Args)';
     HasArgs: False; Shape: irNone; Gate: igAll),
    (Name: 'Read'; Params: '([var F: Text;] Args)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'Readln'; Params: '([var F: Text;] Args)';
     HasArgs: False; Shape: irNone; Gate: igAll),
    (Name: 'Exit'; Params: '([ExitValue])';
     HasArgs: False; Shape: irNone; Gate: igAll),
    (Name: 'Break'; Params: '';
     HasArgs: False; Shape: irNone; Gate: igAll),
    (Name: 'Continue'; Params: '';
     HasArgs: False; Shape: irNone; Gate: igAll),
    (Name: 'TypeInfo'; Params: '(TypeIdent)';
     HasArgs: True; Shape: irPointer; Gate: igAll),
    (Name: 'Delete'; Params: '(var S; Index, Count: Integer)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'Insert'; Params: '(const Source; var S; Index: Integer)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'FillChar'; Params: '(var X; Count: NativeInt; Value)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'Odd'; Params: '(X: Integer)';
     HasArgs: True; Shape: irBoolean; Gate: igAll),
    (Name: 'Pred'; Params: '(const X: <ordinal>)';
     HasArgs: True; Shape: irOrdinal; Gate: igAll),
    (Name: 'Succ'; Params: '(const X: <ordinal>)';
     HasArgs: True; Shape: irOrdinal; Gate: igAll),
    (Name: 'Default'; Params: '(TypeIdent)';
     HasArgs: True; Shape: irDefault; Gate: igAll),
    (Name: 'Trunc'; Params: '(X: Extended)';
     HasArgs: True; Shape: irInt64; Gate: igAll),
    (Name: 'Round'; Params: '(X: Extended)';
     HasArgs: True; Shape: irInt64; Gate: igAll),
    (Name: 'Abs'; Params: '(X)';
     HasArgs: True; Shape: irAbs; Gate: igAll),
    (Name: 'Sqr'; Params: '(X)';
     HasArgs: True; Shape: irSqr; Gate: igAll),
    (Name: 'Pi'; Params: '';
     HasArgs: False; Shape: irExtended; Gate: igAll),
    (Name: 'Concat'; Params: '(const S1, S2, ...)';
     HasArgs: True; Shape: irConcat; Gate: igAll),
    (Name: 'Str'; Params: '(X[: Width[: Decimals]]; var S: string)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'Val'; Params: '(const S: string; var V; var Code: Integer)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'Swap'; Params: '(X)';
     HasArgs: True; Shape: irSwap; Gate: igAll),
    (Name: 'Hi'; Params: '(X)';
     HasArgs: True; Shape: irHiLo; Gate: igAll),
    (Name: 'Lo'; Params: '(X)';
     HasArgs: True; Shape: irHiLo; Gate: igAll),
    (Name: 'Addr'; Params: '(var X)';
     HasArgs: True; Shape: irPointer; Gate: igAll),
    (Name: 'Ptr'; Params: '(Address: Integer)';
     HasArgs: True; Shape: irPointer; Gate: igAll),
    (Name: 'Slice'; Params: '(var A: <array>; Count: Integer)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'RunError'; Params: '([ErrorCode: Byte])';
     HasArgs: False; Shape: irNone; Gate: igAll),
    (Name: 'Initialize'; Params: '(var V[; Count: NativeInt])';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'Finalize'; Params: '(var V[; Count: NativeInt])';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'GetTypeKind'; Params: '(TypeIdent)';
     HasArgs: True; Shape: irTypeKind; Gate: igAll),
    (Name: 'IsManagedType'; Params: '(TypeIdent)';
     HasArgs: True; Shape: irBoolean; Gate: igAll),
    (Name: 'IsConstValue'; Params: '(const X)';
     HasArgs: True; Shape: irBoolean; Gate: igAll),
    (Name: 'HasWeakRef'; Params: '(TypeIdent)';
     HasArgs: True; Shape: irBoolean; Gate: igAll),
    (Name: 'TypeHandle'; Params: '(TypeIdent)';
     HasArgs: True; Shape: irPointer; Gate: igAll),
    (Name: 'TypeOf'; Params: '(const X: <object>)';
     HasArgs: True; Shape: irPointer; Gate: igAll),
    (Name: 'ReturnAddress'; Params: '';
     HasArgs: False; Shape: irPointer; Gate: igAll),
    (Name: 'AddressOfReturnAddress'; Params: '';
     HasArgs: False; Shape: irPointer; Gate: igAll),
    (Name: 'AtomicIncrement'; Params: '(var Target[; Increment])';
     HasArgs: True; Shape: irFirstArg; Gate: igAll),
    (Name: 'AtomicDecrement'; Params: '(var Target[; Decrement])';
     HasArgs: True; Shape: irFirstArg; Gate: igAll),
    (Name: 'AtomicExchange'; Params: '(var Target; Value)';
     HasArgs: True; Shape: irFirstArg; Gate: igAll),
    (Name: 'AtomicCmpExchange';
     Params: '(var Target; NewValue, Comparand[; out Succeeded: Boolean])';
     HasArgs: True; Shape: irFirstArg; Gate: igAll),
    (Name: 'MulDivInt64';
     Params: '(AValue, AMultiplier, ADivisor: Int64[; out Remainder: Int64])';
     HasArgs: True; Shape: irInt64; Gate: igAll),
    (Name: 'Fail'; Params: '';
     HasArgs: False; Shape: irNone; Gate: igAll),
    // Sibling of the Atomic* family and equally undeclared: System.pas does not
    // declare MemoryBarrier anywhere, and a unit with an EMPTY uses clause
    // resolves it under dcc32 37.0. Found by a third-party library's reflection
    // unit, which calls it inside a critical section.
    (Name: 'MemoryBarrier'; Params: '';
     HasArgs: False; Shape: irNone; Gate: igAll),
    // Flow. (`Abort` is NOT one of these - it is a real System.SysUtils
    // routine, so code using it without that unit must still get E2003;
    // it was previously in this list, wrongly making us accept such code.)
    (Name: 'Halt'; Params: '([ExitCode: Integer])';
     HasArgs: False; Shape: irNone; Gate: igAll),
    // Memory (by-ref). None of these three is declared in System.pas - the
    // only GetMem/FreeMem/ReallocMem there are FIELDS of the deprecated
    // TMemoryManager record, which is why a source grep suggests otherwise.
    (Name: 'GetMem'; Params: '(var P: Pointer; Size: NativeInt)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'FreeMem'; Params: '(var P: Pointer[; Size: NativeInt])';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'ReallocMem'; Params: '(var P: Pointer; Size: NativeInt)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    // Classic file I/O (by-ref file var) - the whole Turbo-era family is
    // compiler-magic, none of it declared: real dcc resolves every one of
    // these in a unit with an empty uses clause.
    (Name: 'Assign'; Params: '(var F; FileName: string)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'AssignFile'; Params: '(var F; FileName: string)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'Reset'; Params: '(var F[; RecSize: Integer])';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'Rewrite'; Params: '(var F[; RecSize: Integer])';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'Append'; Params: '(var F: Text)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'Close'; Params: '(var F)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'CloseFile'; Params: '(var F)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'Seek'; Params: '(var F; N: Integer)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'Eof'; Params: '([var F])';
     HasArgs: False; Shape: irBoolean; Gate: igAll),
    (Name: 'Eoln'; Params: '([var F: Text])';
     HasArgs: False; Shape: irBoolean; Gate: igAll),
    (Name: 'SeekEof'; Params: '([var F: Text])';
     HasArgs: False; Shape: irBoolean; Gate: igAll),
    (Name: 'SeekEoln'; Params: '([var F: Text])';
     HasArgs: False; Shape: irBoolean; Gate: igAll),
    (Name: 'FilePos'; Params: '(var F)';
     HasArgs: True; Shape: irInteger; Gate: igAll),
    (Name: 'FileSize'; Params: '(var F)';
     HasArgs: True; Shape: irInteger; Gate: igAll),
    (Name: 'Truncate'; Params: '(var F)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'Erase'; Params: '(var F)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'Rename'; Params: '(var F; NewName: string)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'BlockRead';
     Params: '(var F: File; var Buf; Count: Integer[; var AmtTransferred: Integer])';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'BlockWrite';
     Params: '(var F: File; var Buf; Count: Integer[; var AmtTransferred: Integer])';
     HasArgs: True; Shape: irNone; Gate: igAll),
    // dcc-verified absent from System.pas, unlike its neighbours IOResult,
    // Flush, SetLineBreakStyle and TextOpen, which are all really declared
    // there and so must NOT be seeded.
    (Name: 'SetTextBuf'; Params: '(var F: Text; var Buf[; Size: Integer])';
     HasArgs: True; Shape: irNone; Gate: igAll),
    // Directory: only GetDir is intrinsic - ChDir/MkDir/RmDir ARE declared
    // in System.pas (verified), so they must not be seeded here.
    (Name: 'GetDir'; Params: '(Drive: Byte; var S: string)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    // Variants. Again fields of TVariantManager, not declarations; only
    // these four resolve bare (VarCastOle/VarCopyNoInd/VarArrayGet/
    // VarArrayPut do NOT - real dcc E2003s them).
    (Name: 'VarClear'; Params: '(var V: Variant)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'VarCast';
     Params: '(var Dest: Variant; const Source: Variant; VarType: Integer)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'VarCopy'; Params: '(var Dest: Variant; const Source: Variant)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    (Name: 'VarArrayRedim'; Params: '(var A: Variant; HighBound: Integer)';
     HasArgs: True; Shape: irNone; Gate: igAll),
    // 13.0 (see ch.04 sec. 4.11.1).
    (Name: 'NameOf'; Params: '(Identifier)';
     HasArgs: True; Shape: irString; Gate: igAll),
    // Not on Win32 (Gate igVarArg). The varargs family is the same System.pas
    // trap as CompilerVersion: its only mention there is four COMMENTED-OUT
    // signatures, so a source grep says "declared" and dcc says otherwise.
    // Verified per name with the usual probe (does a unit with an EMPTY uses
    // clause resolve it?) - dcc64 answers with `E2029 '(' expected`, which
    // means the name is known and only the call syntax is wrong; a genuinely
    // undeclared control name answers E2003. dcc32 answers E2003 for each,
    // dccaarm (Android32) knows them (audit A1-16, which found the false
    // E2003s inside System.pas on Android32).
    (Name: 'VarArgStart'; Params: '(var ArgList)';
     HasArgs: True; Shape: irNone; Gate: igVarArg),
    (Name: 'VarArgEnd'; Params: '(var ArgList)';
     HasArgs: True; Shape: irNone; Gate: igVarArg),
    (Name: 'VarArgCopy'; Params: '(var Src, Dest)';
     HasArgs: True; Shape: irNone; Gate: igVarArg),
    (Name: 'VarArgGetValue'; Params: '(var ArgList; var Value)';
     HasArgs: True; Shape: irNone; Gate: igVarArg),
    // Sibling of AtomicCmpExchange above, but a SEPARATE name and 64-bit only
    // (Gate ig64Bit) - the 128-bit compare-and-swap the RTL's lock-free paths
    // use (dcc32 and dccaarm answer E2003).
    (Name: 'AtomicCmpExchange128';
     Params: '(var Target; NewValueHigh, NewValueLow: Int64; var Comparand)';
     HasArgs: True; Shape: irBoolean; Gate: ig64Bit)
  );

type
  // One prebuilt seed per platform CLASS - what the list below depends on:
  // the pointer size (NativeInt's rank, AtomicCmpExchange128), whether the
  // VarArg intrinsics exist (every target but Win32) and LongInt's width
  // (8 on the LP64 targets). Win32; Android32; Win64 and WinArm64 (LLP64);
  // the 64-bit POSIX targets (LP64).
  TSeedClass = (scWin32, scPosix32, scLLP64, scLP64);

  TSeedTemplate = record
    Syms: TArray<TSemaSymbol>;
    Names: TSemaNames;                     // names + order, immutable after init
    Canon: TArray<Integer>;                // seed index -> PasBuiltinCanonSym
    CharSym: Integer;                      // the seeded `Char`
  end;

var
  GSeedTemplates: array[TSeedClass] of TSeedTemplate;
  GSigIndex: TDictionary<string, Integer>;  // NameLower -> CIntrinsics index

function SeedClassOf(APlatform: TPasPlatform): TSeedClass;
var
  LInfo: TPasPlatformInfo;
begin
  LInfo := PlatformInfo(APlatform);
  if not LInfo.Is64Bit then
  begin
    if LInfo.HasVarArgIntrinsics then
      Result := scPosix32
    else
      Result := scWin32;
  end
  else if LInfo.LongBytes = 8 then
    Result := scLP64
  else
    Result := scLLP64;
end;

function PasBuiltinCanonSym(AModel: TPasSemaModel; ASym: Integer;
  APlatform: TPasPlatform): Integer;
var
  LClass: TSeedClass;
begin
  Result := ASym;
  LClass := SeedClassOf(APlatform);
  if (ASym >= 0) and (ASym <= High(GSeedTemplates[LClass].Canon)) and
     (ASym < AModel.SymCount) and
     (sfBuiltin in AModel.Symbols[ASym].Flags) then
    Result := GSeedTemplates[LClass].Canon[ASym];
end;

function PasBuiltinIsChar(AModel: TPasSemaModel; ASym: Integer;
  APlatform: TPasPlatform): Boolean;
begin
  Result := (ASym >= 0) and (ASym < AModel.SymCount) and
    (sfBuiltin in AModel.Symbols[ASym].Flags) and
    (PasBuiltinCanonSym(AModel, ASym, APlatform) =
     GSeedTemplates[SeedClassOf(APlatform)].CharSym);
end;

function PasBuiltinSignature(const ANameLower: string;
  out ASig: TPasBuiltinSig): Boolean;
var
  LIdx: Integer;
begin
  Result := GSigIndex.TryGetValue(ANameLower, LIdx);
  if Result then
  begin
    ASig.Params := CIntrinsics[LIdx].Params;
    ASig.ResultType := PasIntrinsicResultText(CIntrinsics[LIdx].Shape);
    ASig.HasArgs := CIntrinsics[LIdx].HasArgs;
    // Slice is a function with no type of its own: its result exists only
    // as an open-array argument.
    ASig.IsFunction := (CIntrinsics[LIdx].Shape <> irNone) or
      (ANameLower = 'slice');
  end
  else
    ASig := Default(TPasBuiltinSig);
end;

function PasIntrinsicResultText(AShape: TPasIntrinsicResult): string;
begin
  case AShape of
    irInteger: Result := 'Integer';
    irInt64: Result := 'Int64';
    irBoolean: Result := 'Boolean';
    irChar: Result := 'Char';
    irExtended: Result := 'Extended';
    irPointer: Result := 'Pointer';
    irString: Result := 'string';
    irHiLo: Result := 'Word';
    irTypeKind: Result := 'TTypeKind';
  else
    Result := '';   // argument-dependent, or a procedure
  end;
end;

// The original per-symbol seeding - the template builder runs it once per
// bitness, and it stays the FALLBACK for a model whose arena is not empty.
function SeedSystemScopeOwn(AModel: TPasSemaModel;
  APlatform: TPasPlatform): Integer; forward;

function SeedSystemScope(AModel: TPasSemaModel;
  APlatform: TPasPlatform = pfWin32): Integer;
var
  LClass: TSeedClass;
begin
  LClass := SeedClassOf(APlatform);
  Result := AModel.AddScope(sckSystem, NIL_SCOPE, NIL_NODE);
  if AModel.AdoptSeededSymbols(GSeedTemplates[LClass].Syms, Result) then
  begin
    AModel.Scopes[Result].Names := GSeedTemplates[LClass].Names;
    AModel.Scopes[Result].SharedContainers := True;
  end
  else
  begin
    // Non-empty arena: the template's name->index map would be wrong. Remove
    // the scope we just minted and seed the classic way.
    AModel.Scopes.DropLast;
    Result := SeedSystemScopeOwn(AModel, APlatform);
  end;
end;

procedure BuildSeedTemplates;
const
  // A platform of each class: the template is built from its facts.
  CClassPlatform: array[TSeedClass] of TPasPlatform = (pfWin32, pfAndroid32,
    pfWin64, pfAndroid64);
var
  LClass: TSeedClass;
  LModel: TPasSemaModel;
  LScope, LSym, LHead: Integer;
  LPlat: TPasPlatform;
  LGroup: TArray<string>;
begin
  for LClass := Low(TSeedClass) to High(TSeedClass) do
  begin
    LPlat := CClassPlatform[LClass];
    LModel := TPasSemaModel.Create(Default(TPasTree));
    try
      LScope := SeedSystemScopeOwn(LModel, LPlat);
      GSeedTemplates[LClass].Syms := Copy(LModel.Symbols, 0, LModel.SymCount);
      // Take the containers (value types: the arrays are shared by
      // refcount), cut to exact length - an adopting scope shares them and
      // must never find spare capacity it could write into in place.
      GSeedTemplates[LClass].Names := LModel.Scopes[LScope].Names;
      GSeedTemplates[LClass].Names.MakeUnique;
      // The alias groups' heads, by index.
      SetLength(GSeedTemplates[LClass].Canon, LModel.SymCount);
      for LSym := 0 to LModel.SymCount - 1 do
      begin
        GSeedTemplates[LClass].Canon[LSym] := LSym;
        if LModel.Symbols[LSym].Kind <> skBuiltinType then
          Continue;
        LGroup := PasBuiltinAliasGroup(LModel.Symbols[LSym].NameLower,
          PlatformInfo(LPlat).PointerBytes, PlatformInfo(LPlat).LongBytes);
        if Length(LGroup) < 2 then
          Continue;
        LHead := LModel.FindLocal(LScope, LGroup[0]);
        if (LHead <> NIL_SYM) and
           (LModel.Symbols[LHead].Kind = skBuiltinType) then
          GSeedTemplates[LClass].Canon[LSym] := LHead;
      end;
      GSeedTemplates[LClass].CharSym := LModel.FindLocal(LScope, 'char');
    finally
      LModel.Free;
    end;
  end;
end;

function SeedSystemScopeOwn(AModel: TPasSemaModel;
  APlatform: TPasPlatform): Integer;
var
  LSys, LBool, LInt, LExt: Integer;
  LInfo: TPasPlatformInfo;
  LEntry: TIntrinsicEntry;

  function T(const AName: string; ACat: TSemaTypeCat; ARank: Byte = 0): Integer;
  begin
    Result := AModel.AddSymbol(LSys, skBuiltinType, AName, NIL_NODE);
    AModel.Symbols[Result].Flags := AModel.Symbols[Result].Flags + [sfBuiltin];
    AModel.Symbols[Result].TypeCat := ACat;
    AModel.Symbols[Result].NumRank := ARank;
    AModel.BindName(LSys, Result);
  end;

  procedure K(const AName: string; AKind: TSemaSymbolKind; ATypeSym: Integer);
  begin
    var LS := AModel.AddSymbol(LSys, AKind, AName, NIL_NODE);
    AModel.Symbols[LS].Flags := AModel.Symbols[LS].Flags + [sfBuiltin];
    AModel.Symbols[LS].TypeSym := ATypeSym;
    AModel.BindName(LSys, LS);
  end;

begin
  LSys := AModel.AddScope(sckSystem, NIL_SCOPE, NIL_NODE);

  // Integers (NumRank by width: 8-bit=1 .. 64-bit=4).
  T('Byte', tcInteger, 1); T('ShortInt', tcInteger, 1);
  T('Word', tcInteger, 2); T('SmallInt', tcInteger, 2);
  T('Cardinal', tcInteger, 3); LInt := T('Integer', tcInteger, 3);
  // LongInt / LongWord are 8 bytes on the LP64 targets (audit A1-10).
  if PlatformInfo(APlatform).LongBytes = 8 then
  begin
    T('LongInt', tcInteger, 4); T('LongWord', tcInteger, 4);
  end
  else
  begin
    T('LongInt', tcInteger, 3); T('LongWord', tcInteger, 3);
  end;
  T('UInt64', tcInteger, 4); T('Int64', tcInteger, 4);
  // CORRECTION (2026-08-14): earlier assumed real declarations -- checked
  // the actual System.pas and there is none. `PNativeInt = ^NativeInt;`
  // exists, and the NAME is used as a parameter/field type throughout, but
  // `NativeInt = ...` itself is never written anywhere. Genuine compiler
  // intrinsics, same as Integer/Cardinal on this same line -- confirmed by
  // removing them experimentally: 2091 new false E2003 on rtlflat, 2319 on
  // bigflat, 100% attributable to these two names. Stays seeded.
  // The RANK is the one platform-dependent fact here, and the template is
  // already built per bitness - these two are 32-bit wide on a 32-bit target
  // (2.2.1), so ranking them 64-bit everywhere was simply wrong.
  if PlatformInfo(APlatform).Is64Bit then
  begin
    T('NativeInt', tcInteger, 4); T('NativeUInt', tcInteger, 4);
  end
  else
  begin
    T('NativeInt', tcInteger, 3); T('NativeUInt', tcInteger, 3);
  end;
  // Floats.
  T('Single', tcFloat, 1); T('Double', tcFloat, 2);
  LExt := T('Extended', tcFloat, 3);
  T('Real', tcFloat, 2); T('Currency', tcFloat, 2); T('Comp', tcFloat, 2);
  // REMOVED (2026-08-14): `TDateTime = type Double;` is a real declaration
  // in System.pas (unconditional, not inside any $IFDEF/comment).
  // T('TDateTime', tcFloat, 2);
  // The legacy 6-byte float (2.5.1). Compiler-provided like Comp: System.pas
  // mentions it only in a `{$NODEFINE Real48}` line and inside comments, so a
  // source grep says "declared" and dcc says otherwise - the same trap the
  // intrinsic-routine list below documents. 11 false E2003 on one real project.
  T('Real48', tcFloat, 2);
  // The 10-byte x87 storage type beside Win64's 8-byte Extended - the same
  // NODEFINE-only trap as Real48 (System.pas names it in `NODEFINE
  // Extended80` alone), on every target (dcc32, dcc64, dccaarm, dccaarm64,
  // dccosx64 37.0; local/probe-b38 X80; audit E2-35: six false E2003 in a
  // component library's storage units).
  T('Extended80', tcFloat, 3);
  // Booleans.
  LBool := T('Boolean', tcBoolean);
  T('ByteBool', tcBoolean); T('WordBool', tcBoolean); T('LongBool', tcBoolean);
  // Chars.
  T('Char', tcChar); T('AnsiChar', tcChar); T('WideChar', tcChar);
  // Strings.
  T('string', tcString); T('UnicodeString', tcString); T('AnsiString', tcString);
  T('WideString', tcString); T('ShortString', tcString);
  // REMOVED (2026-08-14): both real (`type AnsiString(N)`, the codepage-
  // parameterized form, real code under System.pas's non-NEXTGEN branch --
  // our own tool always targets desktop/VCL, never NEXTGEN).
  // T('RawByteString', tcString); T('UTF8String', tcString);
  // Pointers.
  T('Pointer', tcPointer); T('PChar', tcPointer); T('PAnsiChar', tcPointer);
  // REMOVED (2026-08-14): `PByte = ^Byte;` is real ({$NODEFINE} only gates
  // C++Builder .hpp generation, irrelevant to our Pascal resolver).
  T('PWideChar', tcPointer);
  // T('PByte', tcPointer);
  // Variants / structured / misc.
  T('Variant', tcVariant); T('OleVariant', tcVariant);
  // Classic open-string parameter type (B.4.3): compiler-provided, NOT
  // declared in System.pas. dcc only accepts it in a `var` parameter's type
  // slot (`procedure P(var S: OpenString)`); anywhere else it is E2005 'not a
  // type identifier'. That positional rule is beyond what resolution needs -
  // registering the NAME is what keeps it from reading as undeclared.
  T('OpenString', tcString);
  // EXPERIMENTAL BUILD (2026-08-14): all eight really are Pascal declarations
  // (TObject/Exception/TClass/IInterface/IUnknown/TGUID/TArray in
  // System.pas itself; TBytes/Exception additionally in System.SysUtils) --
  // commented out to rely on the ordinary used-unit/implicit-System
  // fallback (CrossResolve) instead of a per-model seed. Measured on
  // rtlflat/bigflat/spring4d/both AVImark corpora: ZERO new diagnostics --
  // every real-world unit that bares these names already carries the
  // `uses` clause dcc itself would require, TObject/TClass/IInterface/
  // IUnknown/TGUID/TArray live in the ALWAYS-searched implicit System unit
  // regardless. Restore by uncommenting if THIS build regresses something
  // the measured corpora didn't exercise.
  // T('TObject', tcClass); T('Exception', tcClass); T('TClass', tcClassOf);
  // T('IInterface', tcInterface); T('IUnknown', tcInterface);
  // T('TGUID', tcRecord); T('TArray', tcArray); T('TBytes', tcArray);
  // 10.3: `Text` AND `TextFile` are both predefined, and neither has a source
  // declaration in System.pas to fall back on - so a missing seed here is a
  // guaranteed false E2003 (`var f: textfile` in DSiWin32).
  T('Text', tcFile); T('TextFile', tcFile);
  T('_nil', tcNil);   // synthetic type of the nil literal

  // Constants. MaxInt/MaxLongint are compiler-provided too - real System.pas
  // declares NEITHER ("Predefined ... do not have actual declarations").
  K('True', skConst, LBool);
  K('False', skConst, LBool);
  K('nil', skConst, NIL_SYM);
  // MaxInt and MaxLongint are Integer, CompilerVersion Extended (dcc64 prints
  // Double, what Extended is there) - `S := MaxInt` is E2010, `var X :=
  // MaxInt; X.Bogus` E2018 (audit E2-38: they had no type, so neither
  // fired and `MaxInt.ToString` named nothing).
  K('MaxInt', skConst, LInt);
  K('MaxLongint', skConst, LInt);
  // System.pas's own `CompilerVersion = 0.0` sits inside a (* ... *) COMMENT
  // ("assigned a value by the compiler when the system unit is compiled") -
  // so, unlike RTLVersion (a real const), nothing declares it and it must be
  // seeded here. A grep-based audit is fooled by that commented-out block;
  // dcc resolves it with no uses clause, which is the check that matters.
  K('CompilerVersion', skConst, LExt);

  // Intrinsic routines - the documented "Delphi Intrinsic Routines" set, i.e.
  // spec B.4.3's catalog, from CIntrinsics: compiler-magic names with NO
  // declaration anywhere, so nothing else can ever resolve them. Names the
  // RTL DOES declare (Move, Pos, Sqrt, Flush, ChDir/MkDir/RmDir, Mark/
  // Release, ...) are deliberately NOT there - they resolve through the real
  // System unit like any other name. The dividing line was verified per-name
  // against dcc (does a unit with NO uses clause resolve it?) plus this
  // project's own dump of System.pas's interface scope; grepping the source
  // alone is not enough, since some names appear only as record FIELDS
  // (TMemoryManager.GetMem, TVariantManager.VarClear) or inside a comment
  // (CompilerVersion) and so read as "declared" when they are not. The
  // platform-conditional entries are not a nicety: seeding a name dcc32
  // rejects would make a Win32 analysis accept code its compiler does not.
  LInfo := PlatformInfo(APlatform);
  for LEntry in CIntrinsics do
    if (LEntry.Gate = igAll) or
       ((LEntry.Gate = igVarArg) and LInfo.HasVarArgIntrinsics) or
       ((LEntry.Gate = ig64Bit) and LInfo.Is64Bit) then
      K(LEntry.Name, skRoutine, NIL_SYM);

  Result := LSys;
end;

var
  GIntrResult: TDictionary<string, TPasIntrinsicResult>;

procedure BuildIntrResult;
begin
  GIntrResult := TDictionary<string, TPasIntrinsicResult>.Create(96);
  for var LEntry in CIntrinsics do
    if LEntry.Shape <> irNone then
      GIntrResult.Add(LowerCase(LEntry.Name), LEntry.Shape);
end;

function PasIntrinsicResult(const ANameLower: string): TPasIntrinsicResult;
begin
  if not GIntrResult.TryGetValue(ANameLower, Result) then
    Result := irNone;
end;

function PasIntrinsicReadsArgs(AShape: TPasIntrinsicResult): Boolean;
begin
  Result := AShape in [irLength, irAbs, irSqr, irOrdinal, irBounds, irSwap,
    irOrd, irFirstArg, irConcat, irDefault];
end;

procedure BuildSigIndex;
var
  LIdx: Integer;
begin
  GSigIndex := TDictionary<string, Integer>.Create(Length(CIntrinsics) * 2);
  for LIdx := 0 to High(CIntrinsics) do
    GSigIndex.Add(LowerCase(CIntrinsics[LIdx].Name), LIdx);
end;

initialization
  BuildSeedTemplates;
  BuildSigIndex;
  BuildIntrResult;

finalization
  GIntrResult.Free;
  GSigIndex.Free;

end.
