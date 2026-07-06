unit PasTree.Sema.Builtins;

{
  PasTree semantics — seeds a unit's implicit System scope with the built-in
  types, constants and intrinsic routines, so intra-unit references to them
  resolve. Minimal seed list adapted from AST.Delphi.SysTypes.pas.

  Phase 1 seeds these per model (a few dozen symbols). A shared, read-only
  system symbol space is a Phase 2 optimization once symbols span units.
}

interface

uses
  PasTree.Sema.Model;

// Creates and populates the system scope; returns its scope index.
function SeedSystemScope(AModel: TPasSemaModel): Integer;

implementation

uses
  PasTree.Ast;

const
  BUILTIN_TYPES: array [0..45] of string = (
    'Byte', 'ShortInt', 'Word', 'SmallInt', 'Cardinal', 'Integer', 'LongInt',
    'LongWord', 'UInt64', 'Int64', 'NativeInt', 'NativeUInt',
    'Single', 'Double', 'Extended', 'Real', 'Currency', 'Comp',
    'Boolean', 'ByteBool', 'WordBool', 'LongBool',
    'Char', 'AnsiChar', 'WideChar',
    'string', 'UnicodeString', 'AnsiString', 'WideString', 'ShortString',
    'RawByteString', 'UTF8String',
    'Pointer', 'PChar', 'PAnsiChar', 'PWideChar',
    'Variant', 'OleVariant',
    'TObject', 'TClass', 'Exception', 'IInterface', 'IUnknown',
    'Text', 'TDateTime', 'TGUID');

  BUILTIN_CONSTS: array [0..2] of string = ('True', 'False', 'nil');

  BUILTIN_ROUTINES: array [0..19] of string = (
    'Length', 'SetLength', 'High', 'Low', 'Ord', 'Chr', 'Assigned',
    'Inc', 'Dec', 'SizeOf', 'Assert', 'Copy', 'New', 'Dispose',
    'Include', 'Exclude', 'Write', 'Writeln', 'Read', 'Readln');

function SeedSystemScope(AModel: TPasSemaModel): Integer;

  procedure Seed(AKind: TSemaSymbolKind; const AName: string);
  begin
    var LSym := AModel.AddSymbol(Result, AKind, AName, NIL_NODE);
    AModel.Symbols[LSym].Flags := AModel.Symbols[LSym].Flags + [sfBuiltin];
    AModel.BindName(Result, LSym);
  end;

var
  LName: string;
begin
  Result := AModel.AddScope(sckSystem, NIL_SCOPE, NIL_NODE);
  for LName in BUILTIN_TYPES do
    Seed(skBuiltinType, LName);
  for LName in BUILTIN_CONSTS do
    Seed(skConst, LName);
  for LName in BUILTIN_ROUTINES do
    Seed(skRoutine, LName);
end;

end.
