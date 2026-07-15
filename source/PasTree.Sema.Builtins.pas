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
  PasTree.Sema.Model;

// Creates and populates the system scope; returns its scope index.
function SeedSystemScope(AModel: TPasSemaModel): Integer;

implementation

uses
  PasTree.Ast;

function SeedSystemScope(AModel: TPasSemaModel): Integer;
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

  // Integers (NumRank by width: 8-bit=1 .. 64-bit=4).
  T('Byte', tcInteger, 1); T('ShortInt', tcInteger, 1);
  T('Word', tcInteger, 2); T('SmallInt', tcInteger, 2);
  T('Cardinal', tcInteger, 3); T('Integer', tcInteger, 3);
  T('LongInt', tcInteger, 3); T('LongWord', tcInteger, 3);
  T('UInt64', tcInteger, 4); T('Int64', tcInteger, 4);
  T('NativeInt', tcInteger, 4); T('NativeUInt', tcInteger, 4);
  // Floats.
  T('Single', tcFloat, 1); T('Double', tcFloat, 2); T('Extended', tcFloat, 3);
  T('Real', tcFloat, 2); T('Currency', tcFloat, 2); T('Comp', tcFloat, 2);
  T('TDateTime', tcFloat, 2);
  // Booleans.
  LBool := T('Boolean', tcBoolean);
  T('ByteBool', tcBoolean); T('WordBool', tcBoolean); T('LongBool', tcBoolean);
  // Chars.
  T('Char', tcChar); T('AnsiChar', tcChar); T('WideChar', tcChar);
  // Strings.
  T('string', tcString); T('UnicodeString', tcString); T('AnsiString', tcString);
  T('WideString', tcString); T('ShortString', tcString);
  T('RawByteString', tcString); T('UTF8String', tcString);
  // Pointers.
  T('Pointer', tcPointer); T('PChar', tcPointer); T('PAnsiChar', tcPointer);
  T('PWideChar', tcPointer); T('PByte', tcPointer);
  // Variants / structured / misc.
  T('Variant', tcVariant); T('OleVariant', tcVariant);
  T('TObject', tcClass); T('Exception', tcClass); T('TClass', tcClassOf);
  T('IInterface', tcInterface); T('IUnknown', tcInterface);
  T('TGUID', tcRecord); T('TArray', tcArray); T('TBytes', tcArray);
  T('Text', tcFile);
  T('_nil', tcNil);   // synthetic type of the nil literal

  // Constants. MaxInt/MaxLongint are compiler-provided too — real System.pas
  // declares NEITHER ("Predefined ... do not have actual declarations").
  K('True', skConst, LBool);
  K('False', skConst, LBool);
  K('nil', skConst, NIL_SYM);
  K('MaxInt', skConst, NIL_SYM);
  K('MaxLongint', skConst, NIL_SYM);

  // Intrinsic routines (result typing deferred) — the documented "Delphi
  // Intrinsic Routines" set (compiler-magic, no System.pas declaration);
  // names System.pas DOES declare (Move, GetMem, Halt, ...) are deliberately
  // NOT here — they resolve through the real unit like any other name.
  for var LName in ['Length', 'SetLength', 'SetString', 'High', 'Low', 'Ord',
    'Chr', 'Assigned', 'Inc', 'Dec', 'SizeOf', 'Assert', 'Copy', 'New',
    'Dispose', 'Include', 'Exclude', 'Write', 'Writeln', 'Read', 'Readln',
    'Exit', 'Break', 'Continue', 'Abort', 'TypeInfo', 'Delete', 'Insert',
    'FillChar', 'Odd', 'Pred', 'Succ', 'Default', 'Trunc', 'Round', 'Abs',
    'Sqr', 'Pi', 'Concat', 'Str', 'Val', 'Swap', 'Hi', 'Lo', 'Addr', 'Ptr',
    'Slice', 'RunError', 'Initialize', 'Finalize', 'GetTypeKind',
    'IsManagedType', 'IsConstValue', 'HasWeakRef', 'TypeHandle', 'TypeOf',
    'ReturnAddress', 'AddressOfReturnAddress', 'AtomicIncrement',
    'AtomicDecrement', 'AtomicExchange', 'AtomicCmpExchange', 'MulDivInt64',
    'Fail'] do
    K(LName, skRoutine, NIL_SYM);

  Result := LSys;
end;

end.
