unit PasTree.Sema.Builtins;

{
  PasTree semantics — seeds a unit's implicit System scope with the built-in
  types (categorized for the type checker), constants and intrinsic routines,
  so intra-unit references to them resolve. Adapted from AST.Delphi.SysTypes /
  DataTypes groupings.

  Phase 1 seeds these per model (a few dozen symbols). A shared, read-only
  system symbol space is a later optimization once symbols span units.
}

interface

uses
  PasTree.Platforms,
  PasTree.Sema.Model;

// Creates and populates the system scope; returns its scope index.
// APlatform gates the few intrinsics that exist on 64-bit targets only.
function SeedSystemScope(AModel: TPasSemaModel;
  APlatform: TPasPlatform = pfWin32): Integer;

{ The seeded names that denote ONE type, as a group — `Cardinal`, `LongWord` and
  (through System.pas's `UInt32 = Cardinal`) `UInt32` are the same type, not
  three compatible ones. Returns the group for a name that is in one, and just
  the name otherwise; the caller therefore never needs to know which.

  dcc32 37.0-probed with a `record helper for Cardinal`: it applies to values
  declared `Cardinal`, `LongWord` and `UInt32` alike, and is `E2671` on an
  `Integer` — so this is identity, not assignment compatibility, and the four
  groups below are exactly the ones a helper crosses. The same probe run for
  `Integer`/`LongInt`/`Int32`, `Char`/`WideChar` and `string`/`UnicodeString`;
  `Word` against the Integer helper is the negative that pins the boundary. }
function PasBuiltinAliasGroup(const ANameLower: string): TArray<string>;

implementation

uses
  System.Generics.Collections,
  PasTree.Ast;

function PasBuiltinAliasGroup(const ANameLower: string): TArray<string>;
const
  // Only the SEEDED names need to be here: a real declaration like System.pas's
  // `UInt32 = Cardinal` is an alias the type walk already follows.
  CGroups: array[0..3] of TArray<string> = (
    ['integer', 'longint'],
    ['cardinal', 'longword'],
    ['char', 'widechar'],
    ['string', 'unicodestring']);
var
  LIdx, LName: Integer;
begin
  for LIdx := 0 to High(CGroups) do
    for LName := 0 to High(CGroups[LIdx]) do
      if CGroups[LIdx][LName] = ANameLower then
        Exit(CGroups[LIdx]);
  Result := [ANameLower];
end;

function SeedSystemScope(AModel: TPasSemaModel;
  APlatform: TPasPlatform = pfWin32): Integer;
var
  LSys, LBool: Integer;

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
  // ~180 names land below, in EVERY model: pre-size the lazy containers once
  // instead of letting the dictionary rehash its way up per unit.
  AModel.Scopes[LSys].Names := TDictionary<string, Integer>.Create(256);
  AModel.Scopes[LSys].Symbols := TList<Integer>.Create;
  AModel.Scopes[LSys].Symbols.Capacity := 224;

  // Integers (NumRank by width: 8-bit=1 .. 64-bit=4).
  T('Byte', tcInteger, 1); T('ShortInt', tcInteger, 1);
  T('Word', tcInteger, 2); T('SmallInt', tcInteger, 2);
  T('Cardinal', tcInteger, 3); T('Integer', tcInteger, 3);
  T('LongInt', tcInteger, 3); T('LongWord', tcInteger, 3);
  T('UInt64', tcInteger, 4); T('Int64', tcInteger, 4);
  // CORRECTION (2026-08-14): earlier assumed real declarations -- checked
  // the actual System.pas and there is none. `PNativeInt = ^NativeInt;`
  // exists, and the NAME is used as a parameter/field type throughout, but
  // `NativeInt = ...` itself is never written anywhere. Genuine compiler
  // intrinsics, same as Integer/Cardinal on this same line -- confirmed by
  // removing them experimentally: 2091 new false E2003 on rtlflat, 2319 on
  // bigflat, 100% attributable to these two names. Stays seeded.
  T('NativeInt', tcInteger, 4); T('NativeUInt', tcInteger, 4);
  // Floats.
  T('Single', tcFloat, 1); T('Double', tcFloat, 2); T('Extended', tcFloat, 3);
  T('Real', tcFloat, 2); T('Currency', tcFloat, 2); T('Comp', tcFloat, 2);
  // REMOVED (2026-08-14): `TDateTime = type Double;` is a real declaration
  // in System.pas (unconditional, not inside any $IFDEF/comment).
  // T('TDateTime', tcFloat, 2);
  // The legacy 6-byte float (2.5.1). Compiler-provided like Comp: System.pas
  // mentions it only in a `{$NODEFINE Real48}` line and inside comments, so a
  // source grep says "declared" and dcc says otherwise — the same trap the
  // intrinsic-routine list below documents. 11 false E2003 on one real project.
  T('Real48', tcFloat, 2);
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
  // type identifier'. That positional rule is beyond what resolution needs —
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
  // declaration in System.pas to fall back on — so a missing seed here is a
  // guaranteed false E2003 (`var f: textfile` in DSiWin32).
  T('Text', tcFile); T('TextFile', tcFile);
  T('_nil', tcNil);   // synthetic type of the nil literal

  // Constants. MaxInt/MaxLongint are compiler-provided too — real System.pas
  // declares NEITHER ("Predefined ... do not have actual declarations").
  K('True', skConst, LBool);
  K('False', skConst, LBool);
  K('nil', skConst, NIL_SYM);
  K('MaxInt', skConst, NIL_SYM);
  K('MaxLongint', skConst, NIL_SYM);
  // System.pas's own `CompilerVersion = 0.0` sits inside a (* ... *) COMMENT
  // ("assigned a value by the compiler when the system unit is compiled") —
  // so, unlike RTLVersion (a real const), nothing declares it and it must be
  // seeded here. A grep-based audit is fooled by that commented-out block;
  // dcc resolves it with no uses clause, which is the check that matters.
  K('CompilerVersion', skConst, NIL_SYM);

  // Intrinsic routines (result typing deferred) — the documented "Delphi
  // Intrinsic Routines" set, i.e. spec B.4.3's catalog: compiler-magic names
  // with NO declaration anywhere, so nothing else can ever resolve them.
  // Names the RTL DOES declare (Move, Pos, Sqrt, Flush, ChDir/MkDir/RmDir,
  // Mark/Release, ...) are deliberately NOT here — they resolve through the
  // real System unit like any other name. The dividing line was verified
  // per-name against dcc (does a unit with NO uses clause resolve it?) plus
  // this project's own dump of System.pas's interface scope; grepping the
  // source alone is not enough, since some names appear only as record
  // FIELDS (TMemoryManager.GetMem, TVariantManager.VarClear) or inside a
  // comment (CompilerVersion) and so read as "declared" when they are not.
  for var LName in ['Length', 'SetLength', 'SetString', 'High', 'Low', 'Ord',
    'Chr', 'Assigned', 'Inc', 'Dec', 'SizeOf', 'Assert', 'Copy', 'New',
    'Dispose', 'Include', 'Exclude', 'Write', 'Writeln', 'Read', 'Readln',
    'Exit', 'Break', 'Continue', 'TypeInfo', 'Delete', 'Insert',
    'FillChar', 'Odd', 'Pred', 'Succ', 'Default', 'Trunc', 'Round', 'Abs',
    'Sqr', 'Pi', 'Concat', 'Str', 'Val', 'Swap', 'Hi', 'Lo', 'Addr', 'Ptr',
    'Slice', 'RunError', 'Initialize', 'Finalize', 'GetTypeKind',
    'IsManagedType', 'IsConstValue', 'HasWeakRef', 'TypeHandle', 'TypeOf',
    'ReturnAddress', 'AddressOfReturnAddress', 'AtomicIncrement',
    'AtomicDecrement', 'AtomicExchange', 'AtomicCmpExchange', 'MulDivInt64',
    'Fail',
    // Sibling of the Atomic* family and equally undeclared: System.pas does not
    // declare MemoryBarrier anywhere, and a unit with an EMPTY uses clause
    // resolves it under dcc32 37.0. Found by a third-party library's reflection unit,
    // which calls it inside a critical section.
    'MemoryBarrier',
    // Flow. (`Abort` is NOT one of these — it is a real System.SysUtils
    // routine, so code using it without that unit must still get E2003;
    // it was previously in this list, wrongly making us accept such code.)
    'Halt',
    // Memory (by-ref). None of these three is declared in System.pas — the
    // only GetMem/FreeMem/ReallocMem there are FIELDS of the deprecated
    // TMemoryManager record, which is why a source grep suggests otherwise.
    'GetMem', 'FreeMem', 'ReallocMem',
    // Classic file I/O (by-ref file var) — the whole Turbo-era family is
    // compiler-magic, none of it declared: real dcc resolves every one of
    // these in a unit with an empty uses clause.
    'Assign', 'AssignFile', 'Reset', 'Rewrite', 'Append', 'Close',
    'CloseFile', 'Seek', 'Eof', 'Eoln', 'SeekEof', 'SeekEoln', 'FilePos',
    'FileSize', 'Truncate', 'Erase', 'Rename', 'BlockRead', 'BlockWrite',
    // dcc-verified absent from System.pas, unlike its neighbours IOResult,
    // Flush, SetLineBreakStyle and TextOpen, which are all really declared
    // there and so must NOT be seeded.
    'SetTextBuf',
    // Directory: only GetDir is intrinsic — ChDir/MkDir/RmDir ARE declared
    // in System.pas (verified), so they must not be seeded here.
    'GetDir',
    // Variants. Again fields of TVariantManager, not declarations; only
    // these four resolve bare (VarCastOle/VarCopyNoInd/VarArrayGet/
    // VarArrayPut do NOT — real dcc E2003s them).
    'VarClear', 'VarCast', 'VarCopy', 'VarArrayRedim',
    // 13.0 (see ch.04 §4.11.1).
    'NameOf'] do
    K(LName, skRoutine, NIL_SYM);

  // 64-BIT ONLY. The first platform-conditional entries in this seed, and the
  // condition is not a nicety: dcc32 reports `E2003 Undeclared identifier` for
  // every one of these while dcc64 accepts them, so seeding them everywhere
  // would make a Win32 analysis accept code the Win32 compiler rejects.
  //
  // The varargs family is the same System.pas trap as CompilerVersion: its
  // only mention there is four COMMENTED-OUT signatures, so a source grep says
  // "declared" and dcc says otherwise. Verified per name with the usual probe
  // (does a unit with an EMPTY uses clause resolve it?) — dcc64 answers with
  // `E2029 '(' expected`, which means the name is known and only the call
  // syntax is wrong; a genuinely undeclared control name answers E2003.
  //
  // The gate is Is64Bit because that is what the two probes support (Win32 no,
  // Win64 yes); whether a 32-bit ARM target would agree is untested.
  if PlatformInfo(APlatform).Is64Bit then
    for var LName in ['VarArgStart', 'VarArgEnd', 'VarArgCopy',
      'VarArgGetValue',
      // Sibling of AtomicCmpExchange above, but a SEPARATE name and 64-bit
      // only — the 128-bit compare-and-swap the RTL's lock-free paths use.
      'AtomicCmpExchange128'] do
      K(LName, skRoutine, NIL_SYM);

  Result := LSys;
end;

end.
