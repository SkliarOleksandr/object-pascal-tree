unit PasTree.Dcu;

{
  PasTree - reading a compiled unit (.dcu) into declarations.

  A third-party library that ships only .dcu files leaves every importer with
  an F1027 and its diagnostics gated off (README, "units with no source").
  This unit reads such a file far enough to know what the unit DECLARES: its
  uses lists, the names it imports from them, every constant, type, variable
  and routine header, every class, record and interface member with its
  visibility and property accessors. Code, fixups, line tables, debug tables
  and the string data block are skipped, never interpreted - this is a
  declaration reader, not a decompiler. The consumer is PasTree.Dcu.Source,
  which prints these declarations as an interface-only unit for the ordinary
  lexer -> parser -> resolver pipeline.

  THE FORMAT. Nothing here is documented by the compiler's vendor. The layout
  below draws on Alexei Hmelnov's public reverse engineering (DCU32INT) and on
  this repository's own probe over the Studio 22.0 / 23.0 / 37.0 libraries
  (docs/dcu-reader.md: the Delphi 12 additions, the address-table numbering
  rules). Only what the probe verified is accepted: version bytes $23..$25
  (Delphi 11, 12, 13) on Win32 and Win64. Anything else is refused with a
  message naming the byte, never guessed - see DcuVersionSupported.

  THREE TABLES drive the whole file, and every record cross-references them
  by 1-based index:
  - The ADDRESS table: one slot per named declaration in reading order,
    plus one per uses entry and per imported name. A record names its target
    (a property its accessor, a method its header, a fixup its owner) by slot.
    The rules for which records take a slot and when a slot is filled out of
    order are the subtle part of this format; see AddAddr / ReserveAddr /
    the drProcAddInfo anchor, and DropLastAddr for the one shape the public
    parser numbered wrongly for three Studio versions.
  - The TYPE table: one entry per type DEFINITION record and per imported
    type name. A declaration `TFoo = ...` is a separate record that NAMES an
    entry (possibly ahead of the definition, see the placeholder in
    NameType); a field, a parameter, a variable refers to its type by entry.
  - The USES list, by position: an import knows the unit it came from.

  The variable-length integer ("index") encoding, the `<len> <chars>` names
  and the record tags are in the reader's implementation, each beside the
  reason it reads the way it does. Version-dependent branches for compilers
  older than Delphi 11 were deliberately NOT carried over: a branch no test
  exercises is a place a silent misread can hide.
}

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections;

type
  EPasDcuError = class(Exception);

  TPasDcuPlatform = (dcuWin32, dcuWin64);

  TPasDcuCallKind = (dcRegister, dcCdecl, dcPascal, dcStdCall, dcSafeCall);

  { What a declaration record is. The compiler's record tags map onto these
    kinds one to one except where noted. }
  TPasDcuDeclKind = (
    dkUnitRef,        // a uses entry (takes an address slot)
    dkImport,         // a name imported from a used unit (type or address)
    dkType,           // `TName = ...` naming a type-table entry
    dkVmt,            // the compiler's VMT object of a class (drTypeP) - never printed
    dkConst,          // a true constant with its value in the record
    dkResString,      // a resourcestring (value lives in the data block)
    dkVar,            // a global variable
    dkThreadVar,      // a threadvar
    dkAbsVar,         // `var X: T absolute Y`
    dkTypedConst,     // `const X: T = ...` (value lives in the data block)
    dkStrConst,       // a string literal's data block (compiler-internal)
    dkLabel,
    dkExport,         // an `exports` entry
    dkParam,          // a routine parameter or local (Tag tells which)
    dkField,          // a record/class/object field
    dkMethod,         // a class/record/interface method header entry
    dkConstructor,
    dkDestructor,
    dkClassVar,
    dkProperty,
    dkDispProperty,   // a dispinterface property
    dkRoutine,        // a procedure/function/method IMPLEMENTATION header
    dkSysRoutine,     // a compiler magic routine (System only)
    dkUnitAddInfo,    // a unit-level info record with a sub-list
    dkSpecVar,        // storage the compiler allocated for class vars etc.
    dkParamDefault,   // `= value` of a parameter: ConstSlot for ArgSlot
    dkCopy,           // a repeat of an earlier declaration by slot
    dkDelayedImport,  // a `delayed` DLL import
    dkORec,           // an anonymous-method frame record
    dkGenericParams); // a generic parameter list (A6 record)

  { What a type-table entry defines. }
  TPasDcuTypeKind = (
    tkPending,        // named by a declaration, definition not read yet
    tkImport,         // a type imported from another unit
    tkRange,          // an ordinal range: integers, Char, WideChar, Boolean (Tag tells which)
    tkEnum,
    tkFloat,
    tkPointer,
    tkText,
    tkFile,
    tkSet,
    tkShortString,
    tkString,         // AnsiString / WideString / UnicodeString (Tag tells which)
    tkArray,          // a static array
    tkVariant,
    tkClassRef,       // `class of T`
    tkRecord,
    tkProcType,       // procedure/function type, method pointer, method reference
    tkObject,         // old-style object
    tkClass,
    tkMetaClass,
    tkInterface,      // interface or dispinterface (IsDispInterface)
    tkVoid,           // the compiler's "no type": a procedure's result, raw data
    tkDynArray,
    tkGenericParam,   // a `T` of a generic declaration
    tkGenericInst);   // `TList<Integer>`: a generic applied to arguments

  TPasDcuType = class;

  TPasDcuDecl = class
  public
    Kind: TPasDcuDeclKind;
    Tag: Byte;                 // the record tag, after the Delphi 2006+ remap (see FixTag)
    Name: string;              // as stored: '' or a dot-prefixed name for compiler-made items,
                               // `Name`N` for a generic, `Outer.Inner` for a nested type
    Slot: Integer;             // 1-based address-table slot, 0 = none
    Flags: Integer;            // F of a flagged declaration; $40 = declared in the interface part
    Flags1: Integer;           // F1
    Inf: Cardinal;
    TypeIdx: Integer;          // the type-table index this declaration refers to / names
    // imports and uses entries
    UnitIdx: Integer;          // index into TPasDcuUnit.UsesList, -1 when not an import
    IsTypeImport: Boolean;     // the import is a type (it also occupies TypeIdx)
    IsAliasImport: Boolean;    // imported through `A = type B` (drImpTypeDef)
    ImportInf: Cardinal;       // the exporting unit's stamp for the name
    // a true constant's value (dkConst)
    ValueKind: Integer;        // 0 ordinal, 1 AnsiString, 2 resourcestring, 3 float, 4 set / nil, 5 UnicodeString
    ValueInt: Int64;           // the ordinal when ValueBytes is empty
    ValueBytes: TBytes;        // the value's bytes when it is not an ordinal
    // members and locals
    LocFlags: Integer;         // the member flags word (virtual/dynamic/message/override, const-param)
    LocFlagsX: Integer;        // visibility and `class` bits, normalized (see lfXxx)
    Offset: Integer;           // a field's byte offset; a method's address slot of its header
                               // (in an interface: the type index of its procedure type);
                               // a parameter's frame offset or register
    IntfIdx: Integer;          // NDXB of an interface member, -1 otherwise
    ImportSlot: Integer;       // a method's hImport
    // properties
    IndexValue: Integer;
    HasIndex: Boolean;
    ReadSlot, WriteSlot, StoredSlot: Integer;
    ReadOrigSlot, WriteOrigSlot: Integer;
    DefaultValue: Integer;
    HasDefault: Boolean;
    // routine headers (dkRoutine / dkSysRoutine)
    ProcFlags: Integer;        // VProc: $800 overload, $2000000 inline
    ResultTypeIdx: Integer;    // the type index of the result; a tkVoid entry for a procedure
    ClassSlot: Integer;        // hClass: 0 for a plain routine
    CallKind: TPasDcuCallKind;
    CodeSize: Integer;
    IsUnnamed: Boolean;        // a compiler-made routine (name '', '.', '..', '.x', '$x')
    // The parameter list as stored: arVal/arVar rows are the parameters
    // (`Self` and a constructor's flag argument `.` included), a dkConst
    // named `.` is a default value, a dkParamDefault row binds it to its
    // parameter by slot, an arResult row and the locals follow.
    Args: TList<TPasDcuDecl>;
    Embedded: TList<TPasDcuDecl>;  // nested routines and local types
    GenericParams: TList<TPasDcuDecl>; // the A6 list of a generic routine (dkType rows naming tkGenericParam entries)
    GenericParamTypes: TArray<Integer>; // A7: type index per generic parameter
    // ConstAddInfo
    CaiFlags: Integer;         // $1 deprecated, $2 platform, $4 library
    HasDeprecated: Boolean;
    DeprecatedMsg: string;
    // dkCopy
    BaseSlot: Integer;
    Base: TPasDcuDecl;
    // dkParamDefault
    ConstSlot, ArgSlot: Integer;
    // dkGenericParams, dkORec, dkUnitAddInfo
    Items: TList<TPasDcuDecl>;
    // the type whose member list this declaration sits in, nil at unit level
    OwnerType: TPasDcuType;
    // the routine whose parameter/local/embedded list this sits in
    OwnerRoutine: TPasDcuDecl;
    constructor Create;
    destructor Destroy; override;
    function IsInterfaceVisible: Boolean;   // Flags and $40
    function Visibility: Integer;           // lfXxx scope value of a member
    function IsClassMember: Boolean;        // `class` method / var / property
    function BareName: string;              // the text after the last '.'
  end;

  TPasDcuType = class
  public
    Kind: TPasDcuTypeKind;
    Tag: Byte;
    Index: Integer;            // 1-based type-table index
    Name: string;              // the declaration's spelling, '' when only referenced inline
    DeclSlot: Integer;         // address slot of the declaration that named it, 0 = none
    Size: Int64;
    RttiSize: Integer;
    AddrSlot: Integer;         // hAddrDef
    Extra: Integer;            // X
    // import
    UnitIdx: Integer;
    ImportName: string;
    ImportInf: Cardinal;
    IsAliasImport: Boolean;
    // range / enum / set / pointer / file / dyn array / class ref / generic inst
    BaseIdx: Integer;          // hDTBase, hRefDT, hBaseDT, hObjDT, hDT
    Low, High: Int64;
    RangeFlag: Integer;        // B
    EnumNdx: Integer;
    FloatKind: Byte;           // 0 Real48, 1 Single, 2 Double, 3 Extended, 4 Comp, 5 Currency
    SetStart: Byte;
    // array / string
    IndexIdx, ElemIdx: Integer;
    ArrayFlag: Byte;           // B1
    CodePage: Integer;
    VariantFlag: Byte;
    // structured: proc type, record, object, class, interface
    ResultTypeIdx: Integer;
    CallKind: TPasDcuCallKind;
    ProcFlags: Integer;        // NDX0: $10 = of object
    Members: TList<TPasDcuDecl>;
    ParentIdx: Integer;
    VmCount: Integer;
    RecFlags: array[0..3] of Integer;    // B2, B1, X0, X
    RecExtra: array[0..2] of Integer;    // the three trailing indices
    ClassFlags: array[0..3] of Integer;  // BX, BX1, BX2, B04
    ClassInfo: array[0..5] of Integer;   // InstBaseRTTISz, InstBaseSz, InstBaseV, NdxFE, PropCnt, BX3
    Interfaces: TArray<Integer>;         // type index per implemented interface
    InterfaceMethodCounts: TArray<Integer>;
    InterfaceNames: TArray<string>;      // Delphi 12+: the string stored per entry
    Guid: TGUID;
    IntfFlags: Integer;        // B: $4 = dispinterface
    IntfFlagsX: Integer;       // BX
    IsDispInterface: Boolean;
    ObjVmtOfs, ObjVmtSlot: Integer;
    ObjFlags: array[0..3] of Integer;   // B03, BX, BX1, BX2
    MetaClassIdx: Integer;     // hCl of a metaclass
    // generics
    GenericParamTypes: TArray<Integer>;  // A7 on a generic type: type index per parameter
    GenericArgs: TArray<Integer>;        // tkGenericInst: the arguments
    InstFullIdx: Integer;                // tkGenericInst: hDTFull
    ParamTable: TArray<Integer>;         // tkGenericParam: its table (constraints)
    ParamExtra: Integer;                 // tkGenericParam: V5
    constructor Create;
    destructor Destroy; override;
    function IsStructured: Boolean;
  end;

  TPasDcuUsesSection = (usInterface, usImplementation, usDll);

  TPasDcuUses = class
  public
    Name: string;
    Section: TPasDcuUsesSection;
    Ref: TPasDcuDecl;                 // the dkUnitRef slot holder
    Imports: TList<TPasDcuDecl>;      // dkImport rows, in file order
    constructor Create;
    destructor Destroy; override;
  end;

  TPasDcuUnit = class
  private
    FOwned: TObjectList<TPasDcuDecl>;
  public
    FileName: string;
    VersionByte: Byte;          // $23 = Delphi 11, $24 = 12, $25 = 13
    ProductVersion: Integer;    // 11, 12, 13
    Platform: TPasDcuPlatform;
    UnitName: string;           // from the main source file's name
    SourceFiles: TArray<string>;
    Stamp: Cardinal;
    UnitFlags: Integer;
    UsesList: TObjectList<TPasDcuUses>;
    Types: TObjectList<TPasDcuType>;   // 1-based through TypeAt; [0] is index 1
    Addrs: TList<TPasDcuDecl>;         // 1-based through AddrAt; a slot may be nil
    Decls: TList<TPasDcuDecl>;         // the main declaration list, in file order
    Warnings: TArray<string>;
    constructor Create;
    destructor Destroy; override;
    function NewDecl(AKind: TPasDcuDeclKind): TPasDcuDecl;
    function TypeAt(AIdx: Integer): TPasDcuType;      // nil when out of range
    function AddrAt(ASlot: Integer): TPasDcuDecl;     // nil when out of range or empty
    { The uses entry a slot or type belongs to, nil when it is the unit's own. }
    function UsesOf(AUnitIdx: Integer): TPasDcuUses;
  end;

  TPasDcuTraceProc = reference to procedure(const ALine: string);

{ Loads a .dcu. Raises EPasDcuError for an unsupported version or platform
  and for any record the reader cannot follow; the message names the file
  offset and the tag. ATrace, when given, receives one `<offset> <tag>` line
  per record and one line per address-table event - the diffing tool
  docs/dcu-reader.md describes for finding the next format change. }
function LoadDcu(const APath: string;
  const ATrace: TPasDcuTraceProc = nil): TPasDcuUnit;
function LoadDcuFromBytes(const ABytes: TBytes; const APath: string;
  const ATrace: TPasDcuTraceProc = nil): TPasDcuUnit;

{ The header sniff: the version and platform bytes of the magic, without
  reading anything else. False when the bytes are not a .dcu of the modern
  scheme at all. }
function DcuHeader(const ABytes: TBytes; out AVersionByte,
  APlatformByte: Byte): Boolean;
function DcuVersionSupported(AVersionByte: Byte): Boolean;
function DcuPlatformSupported(APlatformByte: Byte): Boolean;
{ 'Delphi 13' for $25, 'version byte $1B' for an unknown one. }
function DcuVersionName(AVersionByte: Byte): string;

const
  // Member flag bits (LocFlags), as the compiler stores them.
  lfMethodKind = $C0;
  lfVirtual = $40;
  lfDynamic = $80;
  lfMessage = $C0;
  lfOverride = $20;      // on a method
  lfDefaultProp = $20;   // on a property: `; default`
  // LocFlagsX after normalization (see TPasDcuDecl.LocFlagsX).
  lfClass = $01;
  lfScope = $0E;
  lfPrivate = $00;
  lfPublic = $02;
  lfProtected = $04;
  lfPublished = $0A;
  // A parameter's LocFlags low bits: $1 = const.
  lfParamConst = $01;
  // VProc bits of a routine header.
  pfOverload = $800;
  pfInline = $2000000;
  // NDX0 of a procedure type.
  ptOfObject = $10;
  // ConstAddInfo flags.
  caiDeprecated = $1;
  caiPlatform = $2;
  caiLibrary = $4;

implementation

uses
  System.IOUtils;

const
  // Record tags. Letters in comments are the byte's ASCII glyph, which is how
  // the public parser refers to them; a tag stream in a trace reads better
  // with them in mind.
  drStop = $00;
  drUnitFlags = $96;
  drSrc = $70;             // 'p'
  drObj = $71;             // 'q'
  drRes = $72;             // 'r'
  drAsm = $73;             // 's'
  drUnitInlineSrc = $76;   // 'v'
  drUnit = $64;            // 'd' - a unit of the interface uses
  drUnit1 = $65;           // 'e' - a unit of the implementation uses
  drDLL = $68;             // 'h'
  drImpType = $66;         // 'f'
  drImpVal = $67;          // 'g'
  drImpTypeDef = $6E;      // 'n'
  drStop1 = $63;           // 'c' - end of a nested list
  drStop2 = $9F;
  drExport = $69;          // 'i'
  drEmbeddedProcStart = $6A; // 'j'
  drEmbeddedProcEnd = $6B;   // 'k'
  drCBlock = $6C;          // 'l' - the data block
  drFixUp = $6D;           // 'm'
  drORec = $6F;            // 'o'
  drConst = $25;           // '%'
  drResStr = $32;          // '2'
  drType = $2A;            // '*'
  drTypeP = $26;           // '&'
  drProc = $28;            // '('
  drSysProc = $29;         // ')'
  drVoid = $40;            // '@'
  drVar = $20;             // ' '
  drThreadVar = $31;       // '1'
  drVarC = $27;            // '''
  drUnitAddInfo = $34;     // '4'
  drStrConstRec = $35;     // '5'
  drSpecVar = $37;         // '7'
  drBoolRangeDef = $41;    // 'A'
  drChRangeDef = $42;      // 'B'
  drEnumDef = $43;         // 'C'
  drRangeDef = $44;        // 'D'
  drPtrDef = $45;          // 'E'
  drClassDef = $46;        // 'F'
  drObjVMTDef = $47;       // 'G'
  drProcTypeDef = $48;     // 'H'
  drFloatDef = $49;        // 'I'
  drSetDef = $4A;          // 'J'
  drShortStrDef = $4B;     // 'K'
  drArrayDef = $4C;        // 'L'
  drRecDef = $4D;          // 'M'
  drObjDef = $4E;          // 'N'
  drFileDef = $4F;         // 'O'
  drTextDef = $50;         // 'P'
  drWCharRangeDef = $51;   // 'Q'
  drStringDef = $52;       // 'R'
  drVariantDef = $53;      // 'S'
  drInterfaceDef = $54;    // 'T'
  drWideStrDef = $55;      // 'U'
  drWideRangeDef = $56;    // 'V'
  drMetaClassDef = $57;    // 'W'
  drDynArrayDef = $58;     // 'X'
  drTemplateArgDef = $59;  // 'Y'
  drTemplateCall = $5A;    // 'Z'
  drUnicodeStringDef = $5B; // '['
  drCodeLines = $90;
  drLinNum = $91;
  drStrucScope = $92;
  drSymbolRef = $93;
  drLocVarTbl = $94;
  drCPPFlags = $98;
  drConstAddInfo = $9C;
  drProcAddInfo = $9E;
  drCLine = $A0;
  drA1Info = $A1;
  drA2Info = $A2;
  arCopyDecl = $A3;
  drA5Info = $A5;
  drA6Info = $A6;
  drA7Info = $A7;
  drA8Info = $A8;
  drA9Info = $A9;
  drDelayedImpInfo = $B0;
  drSegInfo = $B1;
  drAddrToSegInfo = $B2;
  drDependencyInfo = $B5;
  drNextOverload = $B6;
  arFinalFlag = $C2;
  arAnonymousBlock = $01;
  arVal = $21;             // '!'
  arVar = $22;             // '"'
  arResult = $23;          // '#'
  arAbsLocVar = $24;       // '$'
  arLabel = $2B;           // '+'
  arFld = $2C;             // ','
  arMethod = $2D;          // '-'  (after FixTag)
  arConstr = $2E;          // '.'
  arDestr = $2F;           // '/'
  arProperty = $30;        // '0'
  arClassVar = $36;        // '6'
  arSetDeft = $9A;
  arCDecl = $81;
  arSafeCall = $84;

  // The magic's low bits shared by every compiler since XE2.
  cMagicScheme = $00000049;
  cMagicSchemeMask = $00FF00F9;
  cMagicPlatformFamily = $4D;
  cMinVersionByte = $23;   // Delphi 11 - the oldest the probe verified
  cMaxVersionByte = $25;   // Delphi 13
  cPlatformWin32 = $03;
  cPlatformWin64 = $23;

type
  TListKind = (lkMain, lkArgs, lkArgsT, lkEmbedded, lkFields, lkClass,
    lkInterface, lkDispInterface, lkUnitAddInfo, lkA6);

  TPasDcuReader = class
  private
    FBytes: TBytes;
    FPos: Integer;
    FEnd: Integer;
    FDefStart: Integer;      // offset of the record being read (for messages)
    FTag: Byte;              // the current record tag
    FNdxHi: Integer;         // high dword of the last 64-bit index read
    FUnit: TPasDcuUnit;
    FTrace: TPasDcuTraceProc;
    FNextAddr: Integer;      // > 0: the slot the next declaration must fill (drProcAddInfo)
    FTypeDefCount: Integer;  // definitions read so far = next definition's index - 1
    FEmbedDepth: Integer;
    FInProcTemplate: Boolean;
    FDataBlockSeen: Boolean;
    FFixupsSeen: Boolean;
    FSegCount: Integer;
    FLastAddedType: TPasDcuType;
    procedure Trace(const AFmt: string; const AArgs: array of const);
    procedure Error(const AMsg: string); overload;
    procedure Error(const AFmt: string; const AArgs: array of const); overload;
    procedure Warn(const AFmt: string; const AArgs: array of const);
    // byte-level input
    procedure Need(ASize: Integer);
    function ReadByte: Byte;
    function ReadWord: Word;
    function ReadULong: Cardinal;
    function ReadTag: Byte;
    procedure Skip(ASize: Integer);
    function ReadName: string;            // <len> <chars>, len $FF = <dword len>
    function ReadShortName: string;       // <len byte> <chars>
    function ReadUIndex: Integer;
    function ReadIndex: Integer;
    function ReadIndex64: Int64;
    function ReadNdxStr: string;          // <UIndex len> <chars>
    procedure SkipD12Str;                 // <UIndex len+1> <chars>, 0 = none
    function ReadD12Str: string;
    procedure ReadD12TypeRefExtra;
    function ReadBytes(ACount: Integer): TBytes;
    // tables
    function AddAddr(ADecl: TPasDcuDecl): Integer;
    function AppendAddr(ADecl: TPasDcuDecl): Integer;
    procedure ReserveAddr(ASlot: Integer);
    procedure DropLastAddr(ADecl: TPasDcuDecl);
    procedure SetProcAddInfo(AValue: Integer);
    function NewType(AKind: TPasDcuTypeKind; ATag: Byte): TPasDcuType;
    procedure NameType(AIdx, ASlot: Integer; const AName: string);
    function FixTag(ATag: Byte): Byte;
    // records
    procedure ReadHeader;
    procedure ReadSourceFiles;
    procedure ReadUses(ATag: Byte; ASection: TPasDcuUsesSection);
    function ReadConstAddInfo: Integer;
    procedure ReadInlineInfo;
    procedure ReadAttribute;
    procedure ReadConstValue(ADecl: TPasDcuDecl);
    procedure ReadDeclList(AKind: TListKind; AOwnerType: TPasDcuType;
      AOwnerRoutine: TPasDcuDecl; AList: TList<TPasDcuDecl>);
    function NewNamedDecl(AKind: TPasDcuDeclKind; ATag: Byte;
      AWithSlot: Boolean = True): TPasDcuDecl;
    procedure ReadFlagged(ADecl: TPasDcuDecl; ANoInf: Boolean);
    function ReadTypeDecl(AKind: TListKind): TPasDcuDecl;
    function ReadVarDecl(AKind: TPasDcuDeclKind; ATag: Byte): TPasDcuDecl;
    function ReadConstDecl: TPasDcuDecl;
    function ReadProcDecl(AEmbedded: TList<TPasDcuDecl>; ANoInf: Boolean;
      AOwnerType: TPasDcuType): TPasDcuDecl;
    function ReadLocalDecl(AKind: TListKind; ATag: Byte;
      AOwnerType: TPasDcuType): TPasDcuDecl;
    function ReadMethodDecl(AKind: TListKind; ATag: Byte;
      AOwnerType: TPasDcuType): TPasDcuDecl;
    function ReadPropDecl(AOwnerType: TPasDcuType): TPasDcuDecl;
    function ReadCallKind: TPasDcuCallKind;
    function ReadA6List(AOwnerRoutine: TPasDcuDecl): TPasDcuDecl;
    procedure ReadA7(AOwnerType: TPasDcuType; AOwnerDecl: TPasDcuDecl);
    procedure ReadClassInterfaces(AType: TPasDcuType);
    procedure ReadMembers(AType: TPasDcuType; AKind: TListKind);
    // type definitions
    procedure ReadTypeDefBase(AType: TPasDcuType);
    procedure ReadRangeDef(ATag: Byte);
    procedure ReadEnumDef;
    procedure ReadFloatDef;
    procedure ReadPtrDef(ATag: Byte);
    procedure ReadFileDef;
    procedure ReadSetDef;
    procedure ReadArrayDef(ATag: Byte; AKind: TPasDcuTypeKind);
    procedure ReadVariantDef;
    procedure ReadClassRefDef;
    procedure ReadRecDef;
    procedure ReadProcTypeDef;
    procedure ReadObjDef;
    procedure ReadClassDef(ATag: Byte);
    procedure ReadInterfaceDef;
    procedure ReadVoidDef;
    procedure ReadTemplateArgDef;
    procedure ReadTemplateCall;
    // skipped tables
    procedure SkipFixups;
    procedure SkipCodeLines;
    procedure SkipLineRanges;
    procedure SkipStrucScope;
    procedure SkipSymbolInfo;
    procedure SkipLocVarTbl;
    procedure SkipSegInfo;
    procedure SkipAddrToSegInfo;
    procedure SkipDependencyInfo;
  public
    constructor Create(const ABytes: TBytes; AUnit: TPasDcuUnit;
      const ATrace: TPasDcuTraceProc);
    procedure Load;
  end;

{ TPasDcuDecl }

constructor TPasDcuDecl.Create;
begin
  inherited Create;
  UnitIdx := -1;
  IntfIdx := -1;
end;

destructor TPasDcuDecl.Destroy;
begin
  Args.Free;
  Embedded.Free;
  GenericParams.Free;
  Items.Free;
  inherited;
end;

function TPasDcuDecl.IsInterfaceVisible: Boolean;
begin
  Result := (Flags and $40) <> 0;
end;

function TPasDcuDecl.Visibility: Integer;
begin
  Result := LocFlagsX and lfScope;
end;

function TPasDcuDecl.IsClassMember: Boolean;
begin
  Result := (LocFlagsX and lfClass) <> 0;
end;

function TPasDcuDecl.BareName: string;
var
  LDot: Integer;
begin
  Result := Name;
  LDot := Result.LastIndexOf('.');
  if LDot >= 0 then
    Result := Result.Substring(LDot + 1);
end;

{ TPasDcuType }

constructor TPasDcuType.Create;
begin
  inherited Create;
  UnitIdx := -1;
end;

destructor TPasDcuType.Destroy;
begin
  Members.Free;
  inherited;
end;

function TPasDcuType.IsStructured: Boolean;
begin
  Result := Kind in [tkRecord, tkProcType, tkObject, tkClass, tkMetaClass,
    tkInterface];
end;

{ TPasDcuUses }

constructor TPasDcuUses.Create;
begin
  inherited Create;
  Imports := TList<TPasDcuDecl>.Create;
end;

destructor TPasDcuUses.Destroy;
begin
  Imports.Free;
  inherited;
end;

{ TPasDcuUnit }

constructor TPasDcuUnit.Create;
begin
  inherited Create;
  FOwned := TObjectList<TPasDcuDecl>.Create(True);
  UsesList := TObjectList<TPasDcuUses>.Create(True);
  Types := TObjectList<TPasDcuType>.Create(True);
  Addrs := TList<TPasDcuDecl>.Create;
  Decls := TList<TPasDcuDecl>.Create;
end;

destructor TPasDcuUnit.Destroy;
begin
  Decls.Free;
  Addrs.Free;
  Types.Free;
  UsesList.Free;
  FOwned.Free;
  inherited;
end;

function TPasDcuUnit.NewDecl(AKind: TPasDcuDeclKind): TPasDcuDecl;
begin
  Result := TPasDcuDecl.Create;
  Result.Kind := AKind;
  FOwned.Add(Result);
end;

function TPasDcuUnit.TypeAt(AIdx: Integer): TPasDcuType;
begin
  if (AIdx <= 0) or (AIdx > Types.Count) then
    Result := nil
  else
    Result := Types[AIdx - 1];
end;

function TPasDcuUnit.AddrAt(ASlot: Integer): TPasDcuDecl;
begin
  if (ASlot <= 0) or (ASlot > Addrs.Count) then
    Result := nil
  else
    Result := Addrs[ASlot - 1];
end;

function TPasDcuUnit.UsesOf(AUnitIdx: Integer): TPasDcuUses;
begin
  if (AUnitIdx < 0) or (AUnitIdx >= UsesList.Count) then
    Result := nil
  else
    Result := UsesList[AUnitIdx];
end;

{ Header helpers }

function DcuHeader(const ABytes: TBytes; out AVersionByte,
  APlatformByte: Byte): Boolean;
var
  LMagic: Cardinal;
begin
  AVersionByte := 0;
  APlatformByte := 0;
  if Length(ABytes) < 4 then
    Exit(False);
  LMagic := PCardinal(@ABytes[0])^;
  // Every compiler since XE2 writes `<version> <platform> 00 <family>`, the
  // family being $4D from XE6 on; the low bits $49 under mask $FF00F9 are
  // what all of them share.
  if (LMagic and cMagicSchemeMask) <> cMagicScheme then
    Exit(False);
  if (LMagic and $FF) <> cMagicPlatformFamily then
    Exit(False);
  AVersionByte := LMagic shr 24;
  APlatformByte := (LMagic shr 8) and $FF;
  Result := True;
end;

function DcuVersionSupported(AVersionByte: Byte): Boolean;
begin
  Result := (AVersionByte >= cMinVersionByte) and
    (AVersionByte <= cMaxVersionByte);
end;

function DcuPlatformSupported(APlatformByte: Byte): Boolean;
begin
  Result := (APlatformByte = cPlatformWin32) or (APlatformByte = cPlatformWin64);
end;

function DcuVersionName(AVersionByte: Byte): string;
begin
  case AVersionByte of
    $23: Result := 'Delphi 11';
    $24: Result := 'Delphi 12';
    $25: Result := 'Delphi 13';
  else
    Result := Format('version byte $%.2x', [AVersionByte]);
  end;
end;

function LoadDcuFromBytes(const ABytes: TBytes; const APath: string;
  const ATrace: TPasDcuTraceProc): TPasDcuUnit;
var
  LReader: TPasDcuReader;
begin
  Result := TPasDcuUnit.Create;
  try
    Result.FileName := APath;
    LReader := TPasDcuReader.Create(ABytes, Result, ATrace);
    try
      LReader.Load;
    finally
      LReader.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function LoadDcu(const APath: string; const ATrace: TPasDcuTraceProc): TPasDcuUnit;
begin
  Result := LoadDcuFromBytes(TFile.ReadAllBytes(APath), APath, ATrace);
end;

{ TPasDcuReader }

constructor TPasDcuReader.Create(const ABytes: TBytes; AUnit: TPasDcuUnit;
  const ATrace: TPasDcuTraceProc);
begin
  inherited Create;
  FBytes := ABytes;
  FEnd := Length(ABytes);
  FUnit := AUnit;
  FTrace := ATrace;
end;

procedure TPasDcuReader.Trace(const AFmt: string; const AArgs: array of const);
begin
  if Assigned(FTrace) then
    FTrace(Format(AFmt, AArgs));
end;

procedure TPasDcuReader.Error(const AMsg: string);
begin
  raise EPasDcuError.CreateFmt('%s at $%x (record at $%x, tag $%.2x) in %s',
    [AMsg, FPos, FDefStart, FTag, TPath.GetFileName(FUnit.FileName)]);
end;

procedure TPasDcuReader.Error(const AFmt: string; const AArgs: array of const);
begin
  Error(Format(AFmt, AArgs));
end;

procedure TPasDcuReader.Warn(const AFmt: string; const AArgs: array of const);
begin
  FUnit.Warnings := FUnit.Warnings +
    [Format(AFmt, AArgs) + Format(' at $%x', [FPos])];
end;

{ Byte-level input }

procedure TPasDcuReader.Need(ASize: Integer);
begin
  if (ASize < 0) or (FPos + ASize > FEnd) then
    Error('Read past the end of the file (%d bytes wanted)', [ASize]);
end;

function TPasDcuReader.ReadByte: Byte;
begin
  Need(1);
  Result := FBytes[FPos];
  Inc(FPos);
end;

function TPasDcuReader.ReadWord: Word;
begin
  Need(2);
  Result := FBytes[FPos] or (Word(FBytes[FPos + 1]) shl 8);
  Inc(FPos, 2);
end;

function TPasDcuReader.ReadULong: Cardinal;
begin
  Need(4);
  Result := PCardinal(@FBytes[FPos])^;
  Inc(FPos, 4);
end;

function TPasDcuReader.ReadTag: Byte;
begin
  FDefStart := FPos;
  Result := ReadByte;
  FTag := Result;
  if Assigned(FTrace) then
    FTrace(Format('%.5x %.2x', [FDefStart, Result]));
end;

procedure TPasDcuReader.Skip(ASize: Integer);
begin
  Need(ASize);
  Inc(FPos, ASize);
end;

function TPasDcuReader.ReadBytes(ACount: Integer): TBytes;
begin
  Need(ACount);
  Result := Copy(FBytes, FPos, ACount);
  Inc(FPos, ACount);
end;

// A name is `<len> <chars>`; since Delphi 2009 a length byte of $FF means a
// dword length follows (generic instantiation names run past 255).
function TPasDcuReader.ReadName: string;
var
  LLen: Integer;
begin
  LLen := ReadByte;
  if LLen = $FF then
    LLen := Integer(ReadULong);
  Need(LLen);
  Result := TEncoding.UTF8.GetString(FBytes, FPos, LLen);
  Inc(FPos, LLen);
end;

function TPasDcuReader.ReadShortName: string;
var
  LLen: Integer;
begin
  LLen := ReadByte;
  Need(LLen);
  Result := TEncoding.UTF8.GetString(FBytes, FPos, LLen);
  Inc(FPos, LLen);
end;

// The variable-length integer every record is built from. The count of low
// set bits in the first byte gives the width: xxxxxxx0 = 7 bits in one byte,
// xxxxxx01 = 14 bits in two, xxxxx011 = 21 in three, xxxx0111 = 28 in four,
// xxxx1111 = a full dword in the NEXT four bytes; in that last form a nonzero
// high nibble of the first byte announces a further dword (64-bit values).
function TPasDcuReader.ReadUIndex: Integer;
var
  LB0, LB1, LB2, LB3: Byte;
  LVal: Cardinal;
begin
  FNdxHi := 0;
  LB0 := ReadByte;
  if (LB0 and $01) = 0 then
    Exit(LB0 shr 1);
  LB1 := ReadByte;
  if (LB0 and $02) = 0 then
    Exit((LB0 or (Cardinal(LB1) shl 8)) shr 2);
  LB2 := ReadByte;
  if (LB0 and $04) = 0 then
    Exit((LB0 or (Cardinal(LB1) shl 8) or (Cardinal(LB2) shl 16)) shr 3);
  LB3 := ReadByte;
  if (LB0 and $08) = 0 then
  begin
    LVal := LB0 or (Cardinal(LB1) shl 8) or (Cardinal(LB2) shl 16) or
      (Cardinal(LB3) shl 24);
    Exit(Integer(LVal shr 4));
  end;
  // Five-byte form: the dword is bytes 1..4 (LB1..LB3 and one more).
  LVal := LB1 or (Cardinal(LB2) shl 8) or (Cardinal(LB3) shl 16) or
    (Cardinal(ReadByte) shl 24);
  Result := Integer(LVal);
  if (LB0 and $F0) <> 0 then
    FNdxHi := Integer(ReadULong);
end;

// Arithmetic shift right of a signed 32-bit value (Delphi's shr is logical).
function SarInt(AValue: Integer; AShift: Integer): Integer; inline;
begin
  if AValue < 0 then
    Result := not ((not AValue) shr AShift)
  else
    Result := AValue shr AShift;
end;

function TPasDcuReader.ReadIndex: Integer;
var
  LB0, LB1, LB2, LB3: Byte;
  LVal: Integer;
begin
  LB0 := ReadByte;
  if (LB0 and $01) = 0 then
    Result := SarInt(ShortInt(LB0), 1)
  else
  begin
    LB1 := ReadByte;
    if (LB0 and $02) = 0 then
      Result := SarInt(SmallInt(LB0 or (Word(LB1) shl 8)), 2)
    else
    begin
      LB2 := ReadByte;
      if (LB0 and $04) = 0 then
      begin
        // Three bytes: the third is sign-extended into the high word.
        LVal := Integer(LB0 or (Cardinal(LB1) shl 8) or
          (Cardinal(LB2) shl 16));
        if (LB2 and $80) <> 0 then
          LVal := LVal or Integer($FF000000);
        Result := SarInt(LVal, 3);
      end
      else
      begin
        LB3 := ReadByte;
        if (LB0 and $08) = 0 then
        begin
          LVal := Integer(LB0 or (Cardinal(LB1) shl 8) or
            (Cardinal(LB2) shl 16) or (Cardinal(LB3) shl 24));
          Result := SarInt(LVal, 4);
        end
        else
        begin
          Result := Integer(LB1 or (Cardinal(LB2) shl 8) or
            (Cardinal(LB3) shl 16) or (Cardinal(ReadByte) shl 24));
          if (LB0 and $F0) <> 0 then
          begin
            FNdxHi := Integer(ReadULong);
            Exit;
          end;
        end;
      end;
    end;
  end;
  if Result < 0 then
    FNdxHi := -1
  else
    FNdxHi := 0;
end;

function TPasDcuReader.ReadIndex64: Int64;
var
  LLo: Integer;
begin
  LLo := ReadIndex;
  Result := (Int64(FNdxHi) shl 32) or Cardinal(LLo);
end;

// `<UIndex len> <chars>` - the encoding inside ConstAddInfo records (a
// deprecation message, an EXTERNALSYM name).
function TPasDcuReader.ReadNdxStr: string;
var
  LLen: Integer;
begin
  LLen := ReadUIndex;
  if (LLen < 0) or (LLen > $100000) then
    Error('Implausible string length %d', [LLen]);
  Need(LLen);
  Result := TEncoding.UTF8.GetString(FBytes, FPos, LLen);
  Inc(FPos, LLen);
end;

// Delphi 12's strings are `<UIndex len+1> <chars>`, 0 meaning none - a
// different convention from ReadNdxStr in the same file, which took three
// samples to see (docs/dcu-reader.md).
function TPasDcuReader.ReadD12Str: string;
var
  LLen: Integer;
begin
  LLen := ReadUIndex;
  if LLen <= 0 then
    Exit('');
  Dec(LLen);
  Need(LLen);
  Result := TEncoding.UTF8.GetString(FBytes, FPos, LLen);
  Inc(FPos, LLen);
end;

procedure TPasDcuReader.SkipD12Str;
var
  LLen: Integer;
begin
  LLen := ReadUIndex;
  if LLen > 0 then
    Skip(LLen - 1);
end;

// Delphi 12+: after a generic parameter or a generic argument, `<kind>
// [payload]` describing the referenced type; kind 6 carries name and unit of
// a type aliased from another unit, kind 10 a name and an index.
procedure TPasDcuReader.ReadD12TypeRefExtra;
var
  LKind: Integer;
begin
  if FUnit.VersionByte < $24 then
    Exit;
  LKind := ReadUIndex;
  case LKind of
    0, 4: ;
    1: ReadUIndex;
    6: begin SkipD12Str; SkipD12Str; end;
    10: begin SkipD12Str; ReadUIndex; end;
  else
    Error('Unknown type-reference kind %d', [LKind]);
  end;
end;

{ Tables }

// A declaration takes the next slot - unless a drProcAddInfo record named
// the slot it must fill (a slot RESERVED earlier by a forward reference).
function TPasDcuReader.AddAddr(ADecl: TPasDcuDecl): Integer;
var
  LName: string;
begin
  if FNextAddr > 0 then
  begin
    Result := FNextAddr;
    if Result > FUnit.Addrs.Count then
      Error('Anchor slot %d beyond the address table (%d)',
        [Result, FUnit.Addrs.Count]);
    if FUnit.Addrs[Result - 1] <> nil then
    begin
      // Seen in one VCL unit (D11..D13): an abstract method anchored to a slot
      // an earlier member already holds. Appending keeps the numbering the
      // compiler's records then continue to use.
      LName := FUnit.Addrs[Result - 1].Name;
      Warn('Slot %d already used by %s - appending', [Result, LName]);
      FNextAddr := 0;
      FUnit.Addrs.Add(ADecl);
      Result := FUnit.Addrs.Count;
      Trace('  Add #%x (anchor collision)', [Result]);
      Exit;
    end;
    FUnit.Addrs[Result - 1] := ADecl;
    Trace('  Fill #%x', [Result]);
    Inc(FNextAddr);
    Exit;
  end;
  FUnit.Addrs.Add(ADecl);
  Result := FUnit.Addrs.Count;
  Trace('  Add #%x', [Result]);
end;

// A copy record ignores the anchor and always goes to the end.
function TPasDcuReader.AppendAddr(ADecl: TPasDcuDecl): Integer;
begin
  FUnit.Addrs.Add(ADecl);
  Result := FUnit.Addrs.Count;
  Trace('  Append #%x', [Result]);
end;

// A forward reference (a property naming an accessor declared later, an
// attribute its constructor) reserves EVERY slot up to it; each reserved
// slot is later claimed through its own drProcAddInfo anchor. Reserving only
// the one slot was the public parser's second numbering defect.
procedure TPasDcuReader.ReserveAddr(ASlot: Integer);
begin
  if ASlot > FUnit.Addrs.Count then
  begin
    if ASlot <> FUnit.Addrs.Count + 1 then
      Trace('  Reserve #%x..#%x', [FUnit.Addrs.Count + 1, ASlot]);
    while FUnit.Addrs.Count < ASlot do
      FUnit.Addrs.Add(nil);
  end;
end;

// Inside a standalone generic parameter list the copy records take no slot
// (proven by the ConstAddInfo indices of D11..D13), while the type-parameter
// records in the same list do. The public parser gave both a slot, and every
// later index in the unit was off by the number of such copies - the cause of
// misattributed property accessors in System.Classes and Vcl.Themes.
procedure TPasDcuReader.DropLastAddr(ADecl: TPasDcuDecl);
begin
  if (FUnit.Addrs.Count > 0) and
     (FUnit.Addrs[FUnit.Addrs.Count - 1] = ADecl) and
     (ADecl.Slot = FUnit.Addrs.Count) then
  begin
    FUnit.Addrs.Delete(FUnit.Addrs.Count - 1);
    Trace('  Drop #%x', [ADecl.Slot]);
    ADecl.Slot := 0;
  end;
end;

procedure TPasDcuReader.SetProcAddInfo(AValue: Integer);
begin
  if AValue = -1 then
    FNextAddr := 0
  else if AValue >= 1 then
    FNextAddr := AValue;
end;

function TPasDcuReader.NewType(AKind: TPasDcuTypeKind; ATag: Byte): TPasDcuType;
begin
  Result := TPasDcuType.Create;
  Result.Kind := AKind;
  Result.Tag := ATag;
end;

// A declaration names a type-table entry, possibly one whose definition has
// not been read yet (a forward class, a pointer's target): a pending entry
// holds the name until the definition arrives and adopts it. A definition
// referenced by several declarations keeps the first name that is not a
// compiler-made one (those start with '.' or ':' or carry a backquote).
procedure TPasDcuReader.NameType(AIdx, ASlot: Integer; const AName: string);
var
  LType: TPasDcuType;

  function IsAux(const AName: string): Boolean;
  begin
    Result := (AName <> '') and
      ((AName[1] = '.') or (AName[1] = ':') or (AName.IndexOf('`') >= 0));
  end;

begin
  if AIdx <= 0 then
    Exit;
  while FUnit.Types.Count < AIdx do
    FUnit.Types.Add(nil);
  LType := FUnit.Types[AIdx - 1];
  if LType = nil then
  begin
    LType := NewType(tkPending, 0);
    LType.Index := AIdx;
    LType.Name := AName;
    LType.DeclSlot := ASlot;
    FUnit.Types[AIdx - 1] := LType;
    Exit;
  end;
  if LType.Name = '' then
    LType.Name := AName
  else if not IsAux(AName) and IsAux(LType.Name) then
    LType.Name := AName;
  if LType.DeclSlot = 0 then
    LType.DeclSlot := ASlot;
end;

// The definition takes the next type index; a pending entry there (a
// declaration named it ahead of time) hands over its name and slot.
procedure TPasDcuReader.ReadTypeDefBase(AType: TPasDcuType);
var
  LPending: TPasDcuType;
  LIdx: Integer;
begin
  AType.RttiSize := ReadUIndex;
  AType.Size := ReadIndex64;
  AType.AddrSlot := ReadUIndex;
  AType.Extra := ReadUIndex;
  LIdx := FTypeDefCount + 1;
  while FUnit.Types.Count < LIdx do
    FUnit.Types.Add(nil);
  LPending := FUnit.Types[LIdx - 1];
  if LPending <> nil then
  begin
    if LPending.Kind <> tkPending then
      Error('Type definition #%x overrides an existing one', [LIdx]);
    AType.Name := LPending.Name;
    AType.DeclSlot := LPending.DeclSlot;
    FUnit.Types[LIdx - 1] := nil;   // the list owns it: replacing frees it
  end;
  FUnit.Types[LIdx - 1] := AType;
  AType.Index := LIdx;
  FTypeDefCount := LIdx;
  FLastAddedType := AType;
  Trace('  Type #%x kind %d', [LIdx, Ord(AType.Kind)]);
end;

// Delphi 2006 shifted the member tags $2D..$36 up by one ($2D became the
// class-var tag); reading the raw byte back to the older numbering keeps
// one set of constants.
function TPasDcuReader.FixTag(ATag: Byte): Byte;
begin
  Result := ATag;
  if (Result >= $2D) and (Result <= $36) then
  begin
    Dec(Result);
    if Result < $2D then
      Result := $36;
  end;
end;

{ Header }

procedure TPasDcuReader.ReadHeader;
var
  LMagic, LSize: Cardinal;
  LVer, LPlat: Byte;
begin
  LMagic := ReadULong;
  if not DcuHeader(FBytes, LVer, LPlat) then
    raise EPasDcuError.CreateFmt('Not a .dcu of a supported compiler ' +
      '(magic $%.8x) in %s', [LMagic, TPath.GetFileName(FUnit.FileName)]);
  if not DcuVersionSupported(LVer) then
    raise EPasDcuError.CreateFmt('%s is not supported (Delphi 11 to 13 are) - %s',
      [DcuVersionName(LVer), TPath.GetFileName(FUnit.FileName)]);
  if not DcuPlatformSupported(LPlat) then
    raise EPasDcuError.CreateFmt('Platform byte $%.2x is not supported ' +
      '(Win32 and Win64 are) - %s', [LPlat, TPath.GetFileName(FUnit.FileName)]);
  FUnit.VersionByte := LVer;
  FUnit.ProductVersion := 11 + (LVer - cMinVersionByte);
  if LPlat = cPlatformWin64 then
    FUnit.Platform := dcuWin64
  else
    FUnit.Platform := dcuWin32;
  LSize := ReadULong;
  if LSize <> Cardinal(FEnd) then
    Error('Size in header $%x differs from the file size $%x', [LSize, FEnd]);
  ReadULong;                     // file time
  FUnit.Stamp := ReadULong;
  ReadByte;
  ReadByte;
  AddAddr(nil);                  // slot 1: the unit itself
  ReadShortName;                 // sName - always empty in the samples
  ReadUIndex;
  ReadUIndex;
  ReadTag;
  if FTag = drUnitFlags then
  begin
    FUnit.UnitFlags := ReadUIndex;
    ReadUIndex;                  // Flags1
    ReadUIndex;                  // unit priority
    ReadTag;
  end;
end;

// The source files the unit was compiled from; the one with F = 0 is the
// main file and names the unit.
procedure TPasDcuReader.ReadSourceFiles;
var
  LName, LMain: string;
  LFlag: Integer;
begin
  LMain := '';
  while FTag in [drSrc, drRes, drObj, drAsm, drUnitInlineSrc] do
  begin
    LName := ReadName;
    ReadULong;                   // file time
    LFlag := ReadUIndex;
    if (LFlag = 0) and (LMain = '') then
      LMain := LName;
    FUnit.SourceFiles := FUnit.SourceFiles + [LName];
    ReadTag;
  end;
  if Length(FUnit.SourceFiles) = 0 then
    Error('No source files');
  if LMain = '' then
    LMain := FUnit.SourceFiles[0];
  // Any separator: the path may carry '/' from a build machine.
  LMain := LMain.Replace('/', '\');
  LMain := TPath.GetFileNameWithoutExtension(LMain);
  FUnit.UnitName := LMain;
end;

// One entry per used unit: the unit's slot, then every name imported from it
// (each a slot, a type also a type-table entry), closed by drStop1. A
// drProcAddInfo may sit between two entries.
procedure TPasDcuReader.ReadUses(ATag: Byte; ASection: TPasDcuUsesSection);
var
  LUses: TPasDcuUses;
  LImp: TPasDcuDecl;
  LType: TPasDcuType;
  LUnitIdx: Integer;
begin
  while FTag = ATag do
  begin
    LUses := TPasDcuUses.Create;
    LUses.Section := ASection;
    LUses.Name := ReadName;
    LUnitIdx := FUnit.UsesList.Add(LUses);
    if ATag <> drDLL then
      ReadUIndex;                // package index
    ReadUIndex;                  // the used unit's stamp
    if ATag = drDLL then
      ReadULong;
    ReadUIndex;
    LUses.Ref := FUnit.NewDecl(dkUnitRef);
    LUses.Ref.Tag := ATag;
    LUses.Ref.Name := LUses.Name;
    LUses.Ref.UnitIdx := LUnitIdx;
    LUses.Ref.Slot := AddAddr(LUses.Ref);
    repeat
      ReadTag;
      case FTag of
        drImpType, drImpTypeDef:
          begin
            if ATag = drDLL then
              Break;
            LImp := FUnit.NewDecl(dkImport);
            LImp.Tag := FTag;
            LImp.Name := ReadName;
            LImp.UnitIdx := LUnitIdx;
            LImp.IsTypeImport := True;
            LImp.IsAliasImport := FTag = drImpTypeDef;
            if LImp.IsAliasImport then
              ReadUIndex;        // RTTI size
            LImp.ImportInf := ReadULong;
            LType := NewType(tkImport, FTag);
            LType.UnitIdx := LUnitIdx;
            LType.ImportName := LImp.Name;
            LType.ImportInf := LImp.ImportInf;
            LType.IsAliasImport := LImp.IsAliasImport;
            // An aliased import (`A = type B`) is named later by the type
            // declaration that imports it; a plain one carries its own name.
            if not LType.IsAliasImport then
              LType.Name := LImp.Name;
            FUnit.Types.Add(LType);
            LType.Index := FUnit.Types.Count;
            FTypeDefCount := FUnit.Types.Count;
            LImp.TypeIdx := LType.Index;
            LImp.Slot := AddAddr(LImp);
            LType.DeclSlot := LImp.Slot;
            LUses.Imports.Add(LImp);
          end;
        drImpVal:
          begin
            LImp := FUnit.NewDecl(dkImport);
            LImp.Tag := FTag;
            LImp.Name := ReadName;
            LImp.UnitIdx := LUnitIdx;
            LImp.ImportInf := ReadULong;
            LImp.Slot := AddAddr(LImp);
            LUses.Imports.Add(LImp);
          end;
        drStop2:
          ReadULong;
        drConstAddInfo:
          ReadConstAddInfo;
      else
        Break;
      end;
    until False;
    if FTag <> drStop1 then
      Error('Unexpected tag $%.2x in the uses list', [FTag]);
    ReadTag;
    if FTag = drProcAddInfo then
    begin
      SetProcAddInfo(ReadIndex);
      ReadTag;
    end;
  end;
end;

{ ConstAddInfo: attributes of a declaration named by slot - deprecation,
  platform, inline bodies, attribute instances, and a few unexplained pairs
  of indices. Everything is read for its length; the flags and the
  deprecation message are kept. }

function TPasDcuReader.ReadConstAddInfo: Integer;
const
  cStop = $FF;
var
  LSub, LFlags, LCount, LIdx, LFlag2, LKind: Integer;
  LDecl: TPasDcuDecl;
  LSingle: Boolean;
begin
  Result := -1;
  repeat
    LSub := ReadByte;
    if LSub >= cStop then
      Break;
    case LSub of
      $01:
        begin
          Result := ReadUIndex;
          LFlags := ReadUIndex;
          LDecl := FUnit.AddrAt(Result);
          if Assigned(FTrace) then
          begin
            if LDecl <> nil then
              Trace('  CAI #%x F=%x -> %s', [Result, LFlags, LDecl.Name])
            else
              Trace('  CAI #%x F=%x -> (empty)', [Result, LFlags]);
          end;
          if LDecl <> nil then
            LDecl.CaiFlags := LFlags;
          if (LFlags and $800000) <> 0 then
            ReadUIndex;
          if (LFlags and caiDeprecated) <> 0 then
          begin
            if LDecl <> nil then
            begin
              LDecl.HasDeprecated := True;
              LDecl.DeprecatedMsg := ReadNdxStr;
            end
            else
              ReadNdxStr;
          end;
          if (LFlags and Integer($80000000)) <> 0 then
          begin
            LCount := ReadUIndex;
            for LIdx := 1 to LCount do
              ReadAttribute;
          end;
          if (LFlags and $40000) <> 0 then
            ReadInlineInfo;
          if (LFlags and $80000) <> 0 then
            ReadUIndex;
        end;
      $04:
        begin ReadUIndex; ReadUIndex; end;
      $06, $07:
        begin Result := ReadUIndex; ReadUIndex; ReadUIndex; ReadUIndex; end;
      $08, $16:
        begin
          Result := ReadUIndex;
          Skip(ReadUIndex);
        end;
      $09:
        begin Result := ReadUIndex; ReadUIndex; end;
      $0A:
        begin
          Result := ReadUIndex;
          ReadUIndex;
          LFlag2 := ReadUIndex;
          if (LFlag2 and $01) <> 0 then ReadUIndex;
          if (LFlag2 and $02) <> 0 then ReadUIndex;
          if (LFlag2 and $04) <> 0 then ReadUIndex;
          if (LFlag2 and $08) <> 0 then ReadUIndex;
          if (LFlag2 and $10) <> 0 then ReadUIndex;
          if (LFlag2 and $20) <> 0 then ReadUIndex;
          if (LFlag2 and $40) <> 0 then
          begin
            LCount := ReadUIndex;
            for LIdx := 1 to LCount do
            begin
              ReadNdxStr; ReadUIndex; ReadUIndex; ReadUIndex;
            end;
          end;
          if (LFlag2 and $80) <> 0 then
          begin ReadUIndex; ReadUIndex; ReadUIndex; end;
          if (LFlag2 and $100) <> 0 then ReadNdxStr;
          if (LFlag2 and $200) <> 0 then ReadNdxStr;
          if (LFlag2 and $400) <> 0 then ReadUIndex;
          if (LFlag2 and $800) <> 0 then ReadUIndex;
          if (LFlag2 and $1000) <> 0 then ReadUIndex;
          if (LFlag2 and $2000) <> 0 then ReadUIndex;
          if (LFlag2 and $4000) <> 0 then ReadUIndex;
        end;
      $0C:
        begin Result := ReadUIndex; ReadUIndex; ReadUIndex; end;
      $0D:
        begin Result := ReadUIndex; ReadNdxStr; end;
      $10:
        begin
          ReadUIndex;
          LIdx := ReadUIndex;
          // An address index that can point one slot AHEAD of the table in
          // Delphi 13 (generic method instantiations): reserve it, or every
          // later index is off by one.
          if (LIdx > 0) and (FUnit.VersionByte >= $24) then
            ReserveAddr(LIdx);
          ReadUIndex;
        end;
      $11:
        begin
          ReserveAddr(ReadUIndex);
          ReserveAddr(ReadUIndex);
        end;
      $12:
        begin ReadUIndex; ReadUIndex; end;
      $13:
        begin
          ReserveAddr(ReadUIndex);
          ReadUIndex;
          ReadUIndex;
          ReadNdxStr;              // $EXTERNALSYM
          ReadNdxStr;
          ReadNdxStr;              // $OBJTYPENAME
        end;
      $14:
        begin
          ReadUIndex;
          ReadUIndex;
          LCount := ReadUIndex;
          for LIdx := 1 to LCount do
          begin
            ReadUIndex; ReadUIndex; ReadUIndex; ReadNdxStr;
          end;
        end;
      $15:
        begin ReadUIndex; ReadUIndex; ReadUIndex; end;
      $17:
        begin
          // Delphi 12+: <hDef> then items <kind> <payload> closed by kind 0;
          // a leading kind 0 wraps exactly one item without the closing 0.
          if FUnit.VersionByte < $24 then
            Error('Subtag $17 in a Delphi 11 file');
          ReadUIndex;
          LKind := ReadUIndex;
          LSingle := LKind = 0;
          if LSingle then
            LKind := ReadUIndex;
          repeat
            case LKind of
              0, 4: ;
              1: ReadUIndex;
              6: begin SkipD12Str; SkipD12Str; end;
              10: begin SkipD12Str; ReadUIndex; end;
            else
              Error('Subtag $17: unknown kind %d', [LKind]);
            end;
            if LSingle then
              Break;
            LKind := ReadUIndex;
          until LKind = 0;
        end;
    else
      Break;
    end;
  until False;
  if LSub <> cStop then
    Error('Unexpected subtag $%.2x in ConstAddInfo', [LSub]);
end;

// An attribute instance on a declaration: constructor slot, member, type,
// then the arguments (a constant value or a TypeInfo reference).
procedure TPasDcuReader.ReadAttribute;
var
  LCount, LIdx, LKind: Integer;
  LTmp: TPasDcuDecl;
begin
  ReserveAddr(ReadUIndex);       // constructor
  ReadUIndex;                    // member
  ReadUIndex;                    // attribute type
  LCount := ReadUIndex;
  LTmp := TPasDcuDecl.Create;
  try
    for LIdx := 1 to LCount do
    begin
      LKind := ReadUIndex;
      case LKind of
        0:
          begin
            ReadUIndex;          // the value's type
            ReadConstValue(LTmp);
          end;
        1:
          begin
            ReadUIndex;          // type index
            ReserveAddr(ReadUIndex);
          end;
      else
        Error('Unexpected attribute argument kind %d', [LKind]);
      end;
    end;
  finally
    LTmp.Free;
  end;
end;

// The inline body of an inline routine: an expression tree plus address and
// type tables it refers to. Nothing of it is kept, but the slots it names
// must be reserved exactly as the compiler numbered them.
procedure TPasDcuReader.ReadInlineInfo;
var
  LCountA, LCountT, LUnits, LCount, LIdx, LJ, LKind, LMore, LUnitIdx,
    LZ: Integer;
begin
  ReadUIndex;
  ReadUIndex;
  Skip(ReadUIndex);              // the expression tree's code bytes
  ReadUIndex;
  ReadUIndex;
  ReadUIndex;
  ReadUIndex;                    // root node
  ReadUIndex;                    // result variable count
  ReadUIndex;
  ReadUIndex;
  LCountA := ReadUIndex;
  ReadUIndex;                    // start line
  ReadUIndex;
  LCount := ReadUIndex;          // code line count
  Skip(LCount * 4);
  for LIdx := 1 to LCountA do
  begin
    ReserveAddr(ReadUIndex);     // address
    ReadUIndex;                  // type
    ReadUIndex;                  // member
    ReadUIndex;
    LZ := ReadUIndex;
    ReadUIndex;
    for LJ := 1 to LZ do
      ReadUIndex;
  end;
  LCountT := ReadUIndex;
  for LIdx := 1 to LCountT do
  begin
    LKind := ReadUIndex;
    case LKind of
      1:
        begin
          ReserveAddr(ReadUIndex);
          ReadUIndex;
          LMore := 1;
        end;
      2: begin ReadUIndex; LMore := 0; end;
      3: begin ReadUIndex; LMore := 2; end;
      4: begin ReadUIndex; LMore := 1; end;
      5: begin ReadUIndex; LMore := 3; end;
      6, 7: begin ReadUIndex; LMore := 1; end;
    else
      Error('Unexpected inline type-table kind %d', [LKind]);
      LMore := 0;
    end;
    for LJ := 1 to LMore do
      ReadUIndex;
  end;
  LUnits := ReadUIndex;
  for LIdx := 1 to LUnits do
  begin
    LUnitIdx := ReadUIndex;
    LCount := ReadUIndex;
    for LJ := 1 to LCount do
    begin
      LZ := ReadUIndex;
      if LUnitIdx = 0 then
        ReserveAddr(LZ);
    end;
  end;
  LCount := ReadUIndex;
  for LIdx := 1 to LCount do
    ReadUIndex;
  ReadUIndex;
  ReserveAddr(ReadUIndex);
  ReadUIndex;
end;

// A constant's value: kind, then either an inline ordinal (64-bit through
// the index encoding's high dword) or a byte block of the given size.
procedure TPasDcuReader.ReadConstValue(ADecl: TPasDcuDecl);
var
  LSize: Integer;
begin
  ADecl.ValueKind := ReadUIndex;
  if (ADecl.ValueKind < 0) or (ADecl.ValueKind > 5) then
    Error('Unknown constant kind %d', [ADecl.ValueKind]);
  LSize := ReadUIndex;
  if LSize = 0 then
  begin
    ADecl.ValueBytes := nil;
    // Kind 4 with no bytes is a nil pointer: no value follows at all.
    if ADecl.ValueKind <> 4 then
      ADecl.ValueInt := ReadIndex64
    else
      ADecl.ValueInt := 0;
  end
  else
  begin
    ADecl.ValueBytes := ReadBytes(LSize);
    ADecl.ValueInt := 0;
  end;
end;

{ Declaration records }

function TPasDcuReader.NewNamedDecl(AKind: TPasDcuDeclKind; ATag: Byte;
  AWithSlot: Boolean): TPasDcuDecl;
begin
  Result := FUnit.NewDecl(AKind);
  Result.Tag := ATag;
  if AWithSlot then
    Result.Slot := AddAddr(Result);
  Result.Name := ReadName;
  if Assigned(FTrace) then
    Trace('  Decl %d %s', [Ord(AKind), Result.Name]);
end;

// The flag words of a top-level declaration: F ($40 = interface part), F1,
// a third word, an Inf dword when the declaration is exported and the
// record kind carries one, and B2 when F1 says so.
procedure TPasDcuReader.ReadFlagged(ADecl: TPasDcuDecl; ANoInf: Boolean);
begin
  ADecl.Flags := ReadUIndex;
  ADecl.Flags1 := ReadUIndex;
  ReadUIndex;
  if (not ANoInf) and ((ADecl.Flags and $40) <> 0) then
    ADecl.Inf := ReadULong;
  if (ADecl.Flags1 and $80) <> 0 then
    ADecl.TypeIdx := ReadUIndex;   // B2, adopted as hDef by a type declaration
end;

function TPasDcuReader.ReadTypeDecl(AKind: TListKind): TPasDcuDecl;
var
  LDef: Integer;
begin
  Result := NewNamedDecl(dkType, drType);
  ReadFlagged(Result, AKind in [lkArgs, lkArgsT, lkFields, lkClass,
    lkInterface, lkDispInterface]);
  LDef := ReadUIndex;
  if Result.TypeIdx = 0 then
    Result.TypeIdx := LDef;
  NameType(Result.TypeIdx, Result.Slot, Result.Name);
end;

function TPasDcuReader.ReadVarDecl(AKind: TPasDcuDeclKind; ATag: Byte): TPasDcuDecl;
begin
  Result := NewNamedDecl(AKind, ATag);
  ReadFlagged(Result, False);
  Result.TypeIdx := ReadUIndex;
  Result.Offset := ReadUIndex;
  if AKind = dkAbsVar then
    ReserveAddr(Result.Offset);  // `absolute` names its target by slot
end;

function TPasDcuReader.ReadConstDecl: TPasDcuDecl;
begin
  Result := NewNamedDecl(dkConst, drConst);
  ReadFlagged(Result, False);
  Result.TypeIdx := ReadUIndex;
  ReadConstValue(Result);
end;

function TPasDcuReader.ReadCallKind: TPasDcuCallKind;
begin
  Result := dcRegister;
  if (FTag >= arCDecl) and (FTag <= arSafeCall) then
  begin
    Result := TPasDcuCallKind(FTag - arCDecl + 1);
    ReadTag;
  end;
end;

// A routine header: code size, result and class, calling convention, an
// optional generic parameter list, then the parameter list which continues
// into the locals (the leading arVal/arVar entries are the parameters).
function TPasDcuReader.ReadProcDecl(AEmbedded: TList<TPasDcuDecl>;
  ANoInf: Boolean; AOwnerType: TPasDcuType): TPasDcuDecl;
var
  LName: string;
begin
  Result := NewNamedDecl(dkRoutine, drProc);
  ReadFlagged(Result, ANoInf);
  Result.Embedded := AEmbedded;
  Result.Args := TList<TPasDcuDecl>.Create;
  Result.OwnerType := AOwnerType;
  LName := Result.Name;
  Result.IsUnnamed := (LName = '') or (LName = '.') or (LName = '..') or
    (LName[1] = '.') or (LName[1] = '$');
  ReadUIndex;                    // B0
  Result.CodeSize := ReadUIndex;
  ReadByte;
  if Result.IsUnnamed then
    Exit;
  Result.ProcFlags := ReadUIndex;
  Result.ResultTypeIdx := ReadUIndex;
  Result.ClassSlot := ReadUIndex;
  ReadTag;
  Result.CallKind := ReadCallKind;
  if FTag = drA5Info then
    ReadTag;
  if FTag = drA6Info then
  begin
    FInProcTemplate := True;
    try
      Result.GenericParams := TList<TPasDcuDecl>.Create;
      ReadTag;
      ReadDeclList(lkA6, nil, Result, Result.GenericParams);
      if FTag <> drStop1 then
        Error('Generic parameter list of %s not closed', [LName]);
    finally
      FInProcTemplate := False;
    end;
    ReadTag;
  end;
  // One list holds the parameters (arVal/arVar rows), the unnamed constants
  // that are their default values, the dkParamDefault rows binding the two,
  // the Result row and the locals; the consumer picks by tag.
  ReadDeclList(lkArgs, nil, Result, Result.Args);
  if FTag <> drStop1 then
    Error('Parameter list of %s not closed', [LName]);
end;

// A parameter, local, field, class var, or the base part of a method entry.
function TPasDcuReader.ReadLocalDecl(AKind: TListKind; ATag: Byte;
  AOwnerType: TPasDcuType): TPasDcuDecl;
var
  LIsMethod: Boolean;
  LKind: TPasDcuDeclKind;
  LX: Integer;
begin
  case ATag of
    arFld: LKind := dkField;
    arMethod: LKind := dkMethod;
    arConstr: LKind := dkConstructor;
    arDestr: LKind := dkDestructor;
    arClassVar: LKind := dkClassVar;
    arProperty: LKind := dkDispProperty;
  else
    LKind := dkParam;
  end;
  Result := NewNamedDecl(LKind, ATag);
  Result.OwnerType := AOwnerType;
  LIsMethod := ATag in [arMethod, arConstr, arDestr];
  Result.LocFlags := ReadUIndex;
  LX := ReadUIndex;
  // The stored word has the `class` bit at $10 and the scope above it;
  // normalized so that scope reads at $0E and `class` at $01.
  Result.LocFlagsX := ((LX and not $10) shl 1) or ((LX and $10) shr 4);
  ReadUIndex;                    // B3
  if (AKind in [lkArgs, lkArgsT]) and ((Result.LocFlags and $40) <> 0) then
    ReadULong;                   // seen after a [ref] decorator
  if LIsMethod then
    Result.TypeIdx := ReadIndex
  else
    Result.TypeIdx := ReadUIndex;
  if AKind in [lkInterface, lkDispInterface] then
    Result.IntfIdx := ReadUIndex
  else
    Result.IntfIdx := -1;
  if LIsMethod then
    Result.Offset := ReadUIndex
  else
    Result.Offset := ReadIndex;
  if ATag = arAbsLocVar then
    ReserveAddr(Result.Offset);
end;

// A method entry inside a class/record/interface body. Outside an interface
// it carries the address slot of its header; a run of flag bytes of unknown
// meaning follows an ordinary method, skipped by value set - the one
// heuristic in this reader, carried over from the public parser and verified
// by the sweep over three Studio versions.
function TPasDcuReader.ReadMethodDecl(AKind: TListKind; ATag: Byte;
  AOwnerType: TPasDcuType): TPasDcuDecl;
const
  cSkip: set of Byte = [0, 1, 2, 4, 7, 8, 9, $10, $18, $20, $21, $22, $28,
    $38, $41, $42, $47, $4F, $60, $61, $80, $84, $A1];
begin
  Result := ReadLocalDecl(AKind, ATag, AOwnerType);
  if not (AKind in [lkInterface, lkDispInterface]) then
  begin
    if Result.Name <> '' then
      ReadByte;
    Result.ImportSlot := ReadUIndex;
    if ATag = arMethod then
      while (FPos < FEnd) and (FBytes[FPos] in cSkip) do
        Inc(FPos);
  end;
end;

function TPasDcuReader.ReadPropDecl(AOwnerType: TPasDcuType): TPasDcuDecl;
var
  LX: Integer;
begin
  Result := NewNamedDecl(dkProperty, arProperty);
  Result.OwnerType := AOwnerType;
  Result.LocFlags := ReadIndex;
  LX := ReadUIndex;
  Result.LocFlagsX := ((LX and not $10) shl 1) or ((LX and $10) shr 4);
  ReadUIndex;                    // X4
  Result.TypeIdx := ReadUIndex;
  Result.Offset := ReadIndex;
  Result.IndexValue := ReadIndex;
  Result.HasIndex := Result.IndexValue <> Integer($80000000);
  Result.ReadSlot := ReadUIndex;
  Result.WriteSlot := ReadUIndex;
  Result.StoredSlot := ReadUIndex;
  // Accessors may be declared later in the class (or in a class declared
  // later, when the source forward-declared it): forward slots.
  if Result.ReadSlot <> 0 then ReserveAddr(Result.ReadSlot);
  if Result.WriteSlot <> 0 then ReserveAddr(Result.WriteSlot);
  if Result.StoredSlot <> 0 then ReserveAddr(Result.StoredSlot);
  Result.ReadOrigSlot := ReadUIndex;
  if Result.ReadOrigSlot <> 0 then ReserveAddr(Result.ReadOrigSlot);
  Result.WriteOrigSlot := ReadUIndex;
  if Result.WriteOrigSlot <> 0 then ReserveAddr(Result.WriteOrigSlot);
  Result.DefaultValue := ReadIndex;
  Result.HasDefault := Result.DefaultValue <> Integer($80000000);
end;

// A generic parameter list (an A6 record): drType rows naming tkGenericParam
// entries, copy rows for parameters shared with an outer declaration.
function TPasDcuReader.ReadA6List(AOwnerRoutine: TPasDcuDecl): TPasDcuDecl;
begin
  Result := FUnit.NewDecl(dkGenericParams);
  Result.Tag := drA6Info;
  Result.Items := TList<TPasDcuDecl>.Create;
  ReadTag;
  ReadDeclList(lkA6, nil, AOwnerRoutine, Result.Items);
  if FTag <> drStop1 then
    Error('Generic parameter list not closed');
end;

// The A7 record: the type indices of a generic declaration's parameters.
// With a nonzero head it belongs to the type definition just read; else to
// the owner of the list it sits in (a routine's parameter list, a type's
// member list).
procedure TPasDcuReader.ReadA7(AOwnerType: TPasDcuType; AOwnerDecl: TPasDcuDecl);
var
  LHead, LCount, LIdx: Integer;
  LTable: TArray<Integer>;
begin
  LHead := ReadUIndex;
  LCount := ReadUIndex;
  SetLength(LTable, LCount);
  for LIdx := 0 to LCount - 1 do
  begin
    LTable[LIdx] := ReadUIndex;
    ReadD12TypeRefExtra;
  end;
  if LHead <> 0 then
  begin
    if FLastAddedType <> nil then
      FLastAddedType.GenericParamTypes := LTable;
  end
  else if AOwnerType <> nil then
    AOwnerType.GenericParamTypes := LTable
  else if AOwnerDecl <> nil then
    AOwnerDecl.GenericParamTypes := LTable;
end;

// The interface table of a class: per implemented interface its type index,
// a method count, then (Delphi 2010+) the mapping of its methods by name,
// and (Delphi 12+) a string.
procedure TPasDcuReader.ReadClassInterfaces(AType: TPasDcuType);
var
  LCount, LIdx, LMatch, LJ: Integer;
begin
  LCount := ReadIndex;
  if LCount <= 0 then
    Exit;
  SetLength(AType.Interfaces, LCount);
  SetLength(AType.InterfaceMethodCounts, LCount);
  SetLength(AType.InterfaceNames, LCount);
  for LIdx := 0 to LCount - 1 do
  begin
    AType.Interfaces[LIdx] := ReadUIndex;
    AType.InterfaceMethodCounts[LIdx] := ReadUIndex;
    ReadUIndex;                  // X1
    LMatch := ReadUIndex;
    ReadUIndex;                  // X3
    ReadUIndex;                  // X4
    for LJ := 1 to LMatch do
    begin
      ReadByte;
      ReadName;
      ReadUIndex;
      ReadUIndex;
    end;
    if FUnit.VersionByte >= $24 then
      AType.InterfaceNames[LIdx] := ReadD12Str;
  end;
end;

procedure TPasDcuReader.ReadMembers(AType: TPasDcuType; AKind: TListKind);
begin
  AType.Members := TList<TPasDcuDecl>.Create;
  ReadTag;
  ReadDeclList(AKind, AType, nil, AType.Members);
  if FTag <> drStop1 then
    Error('Member list of %s not closed', [AType.Name]);
end;

{ Type definitions }

procedure TPasDcuReader.ReadRangeDef(ATag: Byte);
var
  LType: TPasDcuType;
begin
  LType := NewType(tkRange, ATag);
  ReadTypeDefBase(LType);
  LType.BaseIdx := ReadUIndex;
  LType.Low := ReadIndex64;
  LType.High := ReadIndex64;
  LType.RangeFlag := ReadUIndex;
end;

procedure TPasDcuReader.ReadEnumDef;
var
  LType: TPasDcuType;
begin
  LType := NewType(tkEnum, drEnumDef);
  ReadTypeDefBase(LType);
  LType.BaseIdx := ReadUIndex;
  ReadUIndex;
  LType.EnumNdx := ReadIndex;
  LType.Low := ReadIndex64;
  LType.High := ReadIndex64;
  LType.RangeFlag := ReadUIndex;
end;

procedure TPasDcuReader.ReadFloatDef;
var
  LType: TPasDcuType;
  LKind: Byte;
begin
  LType := NewType(tkFloat, drFloatDef);
  ReadTypeDefBase(LType);
  LKind := ReadByte;
  if (LKind and $80) <> 0 then
  begin
    LKind := LKind and not $80;
    ReadByte;
  end;
  if LKind > 5 then
    Error('Unknown float kind %d', [LKind]);
  LType.FloatKind := LKind;
end;

procedure TPasDcuReader.ReadPtrDef(ATag: Byte);
var
  LType: TPasDcuType;
begin
  if ATag = drDynArrayDef then
    LType := NewType(tkDynArray, ATag)
  else
    LType := NewType(tkPointer, ATag);
  ReadTypeDefBase(LType);
  LType.BaseIdx := ReadUIndex;
  ReadUIndex;
end;

procedure TPasDcuReader.ReadFileDef;
var
  LType: TPasDcuType;
begin
  LType := NewType(tkFile, drFileDef);
  ReadTypeDefBase(LType);
  LType.BaseIdx := ReadUIndex;
end;

procedure TPasDcuReader.ReadSetDef;
var
  LType: TPasDcuType;
begin
  LType := NewType(tkSet, drSetDef);
  ReadTypeDefBase(LType);
  LType.SetStart := ReadByte;
  LType.BaseIdx := ReadUIndex;
end;

procedure TPasDcuReader.ReadArrayDef(ATag: Byte; AKind: TPasDcuTypeKind);
var
  LType: TPasDcuType;
begin
  LType := NewType(AKind, ATag);
  ReadTypeDefBase(LType);
  LType.ArrayFlag := ReadByte;
  LType.IndexIdx := ReadUIndex;
  LType.ElemIdx := ReadUIndex;
  if AKind in [tkShortString, tkString] then
    LType.CodePage := ReadUIndex;
end;

procedure TPasDcuReader.ReadVariantDef;
var
  LType: TPasDcuType;
begin
  LType := NewType(tkVariant, drVariantDef);
  ReadTypeDefBase(LType);
  LType.VariantFlag := ReadByte;
end;

procedure TPasDcuReader.ReadClassRefDef;
var
  LType: TPasDcuType;
begin
  LType := NewType(tkClassRef, drObjVMTDef);
  ReadTypeDefBase(LType);
  LType.BaseIdx := ReadUIndex;
  ReadUIndex;                    // VMT size
end;

procedure TPasDcuReader.ReadRecDef;
var
  LType: TPasDcuType;
begin
  LType := NewType(tkRecord, drRecDef);
  ReadTypeDefBase(LType);
  LType.RecFlags[0] := ReadByte;
  LType.RecFlags[1] := ReadByte;
  LType.RecFlags[2] := ReadByte;
  LType.RecFlags[3] := ReadUIndex;
  LType.RecExtra[0] := ReadUIndex;
  LType.RecExtra[1] := ReadUIndex;
  LType.RecExtra[2] := ReadUIndex;
  ReadMembers(LType, lkFields);
end;

// A procedure type: result, then calling convention and generic info
// records until the parameter list opens with drEmbeddedProcStart; a type
// closed by drStop1 right away has no parameters at all.
procedure TPasDcuReader.ReadProcTypeDef;
var
  LType: TPasDcuType;
  LKind: TPasDcuCallKind;
begin
  LType := NewType(tkProcType, drProcTypeDef);
  ReadTypeDefBase(LType);
  LType.ProcFlags := ReadUIndex;
  LType.ResultTypeIdx := ReadUIndex;
  LType.Members := TList<TPasDcuDecl>.Create;
  ReadTag;
  while FTag <> drEmbeddedProcStart do
  begin
    if FTag = drStop1 then
      Exit;
    LKind := ReadCallKind;
    if LKind = dcRegister then
    begin
      case FTag of
        drA5Info: ;
        drA7Info: ReadA7(LType, nil);
        drA8Info: ReadUIndex;
      end;
      ReadTag;
    end
    else
      LType.CallKind := LKind;
  end;
  ReadTag;
  ReadDeclList(lkArgsT, LType, nil, LType.Members);
  if FTag <> drStop1 then
    Error('Parameter list of a procedure type not closed');
end;

procedure TPasDcuReader.ReadObjDef;
var
  LType: TPasDcuType;
begin
  LType := NewType(tkObject, drObjDef);
  ReadTypeDefBase(LType);
  LType.ObjFlags[0] := ReadByte;
  LType.ObjFlags[1] := ReadUIndex;
  LType.ObjFlags[2] := ReadByte;
  LType.ParentIdx := ReadUIndex;
  LType.ObjVmtOfs := ReadUIndex;
  LType.ObjVmtSlot := ReadIndex;
  LType.VmCount := ReadIndex;
  LType.ObjFlags[3] := ReadUIndex;
  ReadMembers(LType, lkFields);
end;

procedure TPasDcuReader.ReadClassDef(ATag: Byte);
var
  LType: TPasDcuType;
begin
  if ATag = drMetaClassDef then
    LType := NewType(tkMetaClass, ATag)
  else
    LType := NewType(tkClass, ATag);
  ReadTypeDefBase(LType);
  LType.ClassFlags[0] := ReadByte;
  LType.ClassFlags[1] := ReadByte;
  LType.ClassFlags[2] := ReadByte;
  LType.ParentIdx := ReadUIndex;
  LType.ClassInfo[0] := ReadUIndex;    // instance RTTI size
  LType.ClassInfo[1] := ReadIndex;     // instance size
  LType.ClassInfo[2] := ReadUIndex;    // VMT address
  LType.VmCount := ReadUIndex;
  LType.ClassInfo[3] := ReadUIndex;    // NdxFE
  LType.ClassInfo[4] := ReadUIndex;    // property count
  LType.ClassFlags[3] := ReadUIndex;   // B04
  LType.ClassInfo[5] := ReadUIndex;    // BX3
  if ATag = drMetaClassDef then
  begin
    LType.MetaClassIdx := ReadUIndex;
    ReadUIndex;
  end;
  ReadClassInterfaces(LType);
  ReadMembers(LType, lkClass);
end;

procedure TPasDcuReader.ReadInterfaceDef;
var
  LType: TPasDcuType;
  LCount, LIdx: Integer;
  LKind: TListKind;
begin
  LType := NewType(tkInterface, drInterfaceDef);
  ReadTypeDefBase(LType);
  LType.IntfFlagsX := ReadByte;
  LType.ParentIdx := ReadUIndex;
  LType.VmCount := ReadIndex;
  Need(SizeOf(TGUID));
  Move(FBytes[FPos], LType.Guid, SizeOf(TGUID));
  Inc(FPos, SizeOf(TGUID));
  LType.IntfFlags := ReadByte;
  LType.IsDispInterface := (LType.IntfFlags and $4) <> 0;
  if LType.IsDispInterface then
    LKind := lkDispInterface
  else
    LKind := lkInterface;
  ReadUIndex;
  LCount := ReadUIndex;
  for LIdx := 1 to LCount do
  begin
    ReadUIndex;
    ReadUIndex;
  end;
  ReadMembers(LType, LKind);
end;

procedure TPasDcuReader.ReadVoidDef;
var
  LType: TPasDcuType;
begin
  LType := NewType(tkVoid, drVoid);
  ReadTypeDefBase(LType);
  ReadByte;
end;

procedure TPasDcuReader.ReadTemplateArgDef;
var
  LType: TPasDcuType;
  LCount, LIdx: Integer;
begin
  LType := NewType(tkGenericParam, drTemplateArgDef);
  ReadTypeDefBase(LType);
  LCount := ReadUIndex;
  SetLength(LType.ParamTable, LCount);
  for LIdx := 0 to LCount - 1 do
    LType.ParamTable[LIdx] := ReadUIndex;
  LType.ParamExtra := ReadUIndex;
end;

procedure TPasDcuReader.ReadTemplateCall;
var
  LType: TPasDcuType;
  LCount, LIdx: Integer;
begin
  LType := NewType(tkGenericInst, drTemplateCall);
  ReadTypeDefBase(LType);
  ReadByte;
  LType.BaseIdx := ReadUIndex;
  LCount := ReadUIndex;
  SetLength(LType.GenericArgs, LCount);
  for LIdx := 0 to LCount - 1 do
  begin
    LType.GenericArgs[LIdx] := ReadUIndex;
    ReadD12TypeRefExtra;
  end;
  LType.InstFullIdx := ReadUIndex;
end;

{ Tables read only for their length }

procedure TPasDcuReader.SkipFixups;
var
  LCount, LIdx: Integer;
begin
  if FFixupsSeen then
    Error('Second fixup table');
  FFixupsSeen := True;
  LCount := ReadUIndex;
  for LIdx := 1 to LCount do
  begin
    ReadUIndex;                  // offset delta
    ReadByte;                    // kind
    ReadUIndex;                  // target slot
  end;
end;

procedure TPasDcuReader.SkipCodeLines;
var
  LCount, LIdx: Integer;
begin
  LCount := ReadUIndex;
  for LIdx := 1 to LCount do
  begin
    ReadIndex;
    ReadUIndex;
  end;
end;

procedure TPasDcuReader.SkipLineRanges;
var
  LCount, LIdx: Integer;
begin
  LCount := ReadUIndex;
  for LIdx := 1 to LCount do
  begin
    ReadUIndex; ReadUIndex; ReadUIndex;
  end;
end;

procedure TPasDcuReader.SkipStrucScope;
var
  LCount, LIdx: Integer;
begin
  LCount := ReadUIndex;
  for LIdx := 1 to LCount * 6 do
    ReadUIndex;
end;

procedure TPasDcuReader.SkipSymbolInfo;
var
  LCount, LIdx, LSize, LJ: Integer;
begin
  LCount := ReadUIndex;
  ReadUIndex;                    // primary count
  for LIdx := 1 to LCount do
  begin
    ReadUIndex;
    ReadUIndex;
    LSize := ReadUIndex;
    ReadUIndex;
    for LJ := 1 to LSize do
      ReadUIndex;
  end;
end;

// The local-variable table of a debug build. On Win64 each routine opens
// with three records whose third field is unsigned, the rest signed; the
// count in the header does not include the extra two - which is why a
// routine is recognized by its slot resolving to a header.
procedure TPasDcuReader.SkipLocVarTbl;
var
  LCount, LIdx, LSym, LProcRec: Integer;
  LDecl: TPasDcuDecl;
begin
  LCount := ReadUIndex;
  if FUnit.Platform <> dcuWin64 then
  begin
    for LIdx := 1 to LCount do
    begin
      ReadUIndex; ReadUIndex; ReadIndex;
    end;
    Exit;
  end;
  LProcRec := 0;
  LIdx := 0;
  while LIdx < LCount do
  begin
    LSym := ReadUIndex;
    if (LProcRec = 0) and (LSym <> 0) then
    begin
      LDecl := FUnit.AddrAt(LSym);
      if (LDecl <> nil) and (LDecl.Kind in [dkRoutine, dkSysRoutine]) then
      begin
        LProcRec := 3;
        Dec(LIdx);
      end;
    end;
    ReadUIndex;
    if LProcRec > 1 then
      ReadUIndex
    else
      ReadIndex;
    Inc(LIdx);
    if LProcRec > 0 then
      Dec(LProcRec);
  end;
end;

procedure TPasDcuReader.SkipSegInfo;
var
  LCount, LIdx: Integer;
begin
  LCount := ReadUIndex;
  FSegCount := LCount;
  for LIdx := 1 to LCount do
  begin
    ReadShortName;
    ReadByte;
    ReadUIndex;
  end;
end;

procedure TPasDcuReader.SkipAddrToSegInfo;
var
  LCount, LIdx: Integer;
begin
  LCount := ReadUIndex;
  for LIdx := 1 to LCount do
  begin
    ReadUIndex;                  // address slot
    ReadUIndex;                  // segment
    ReadByte;
    ReadUIndex;
    ReadUIndex;
    ReadUIndex;
    ReadUIndex;
  end;
end;

procedure TPasDcuReader.SkipDependencyInfo;
var
  LCount, LIdx, LLen, LJ: Integer;
begin
  LCount := ReadUIndex;
  for LIdx := 1 to LCount do
  begin
    if ReadByte <> 0 then
      Error('Unexpected dependency item head');
    ReadShortName;
    ReadWord;
    ReadUIndex;
    LLen := ReadUIndex;
    for LJ := 1 to LLen do
      ReadUIndex;
  end;
end;

{ The declaration list: every record kind in one loop, exactly the set the
  three Studio versions write. An unknown tag ENDS the list (the enclosing
  reader then checks what it was); for the main list that is the final tag. }

procedure TPasDcuReader.ReadDeclList(AKind: TListKind; AOwnerType: TPasDcuType;
  AOwnerRoutine: TPasDcuDecl; AList: TList<TPasDcuDecl>);
var
  LTag: Byte;
  LDecl, LLast: TPasDcuDecl;
  LEmbedded: TList<TPasDcuDecl>;
  LEmbedEndCount, LCount, LIdx: Integer;
begin
  LEmbedded := nil;
  LEmbedEndCount := 0;
  try
    while True do
    begin
      LTag := FixTag(FTag);
      LDecl := nil;
      case LTag of
        drType:
          LDecl := ReadTypeDecl(AKind);
        drTypeP:
          LDecl := ReadVarDecl(dkVmt, LTag);
        drConst:
          LDecl := ReadConstDecl;
        drResStr:
          LDecl := ReadVarDecl(dkResString, LTag);
        drSysProc:
          begin
            LDecl := ReadProcDecl(nil, True, AOwnerType);
            LDecl.Kind := dkSysRoutine;
            LDecl.Tag := drSysProc;
          end;
        drProc:
          begin
            LDecl := ReadProcDecl(LEmbedded, False, AOwnerType);
            LEmbedded := nil;    // owned by the routine now
          end;
        drEmbeddedProcStart:
          begin
            if LEmbedEndCount > 0 then
              Dec(LEmbedEndCount)
            else
            begin
              // Local declarations of the routine that follows.
              if LEmbedded = nil then
                LEmbedded := TList<TPasDcuDecl>.Create;
              Inc(FEmbedDepth);
              ReadTag;
              ReadDeclList(lkEmbedded, nil, AOwnerRoutine, LEmbedded);
              Dec(FEmbedDepth);
              if FTag <> drEmbeddedProcEnd then
                Error('Embedded list not closed');
            end;
          end;
        drEmbeddedProcEnd:
          begin
            if not (AKind in [lkArgs, lkArgsT]) then
              Break;
            Inc(LEmbedEndCount);
          end;
        drVar:
          case AKind of
            lkArgs, lkArgsT:
              LDecl := ReadLocalDecl(AKind, LTag, AOwnerType);
          else
            LDecl := ReadVarDecl(dkVar, LTag);
          end;
        drThreadVar:
          LDecl := ReadVarDecl(dkThreadVar, LTag);
        drVarC:
          LDecl := ReadVarDecl(dkTypedConst, LTag);
        drSpecVar:
          LDecl := ReadVarDecl(dkSpecVar, LTag);
        drExport:
          begin
            LDecl := NewNamedDecl(dkExport, LTag);
            LDecl.BaseSlot := ReadUIndex;
            LDecl.IndexValue := ReadUIndex;
            if FUnit.VersionByte >= $24 then
              ReadUIndex;
          end;
        arVal, arVar, arResult, arFld:
          LDecl := ReadLocalDecl(AKind, LTag, AOwnerType);
        arAbsLocVar:
          if AKind = lkMain then
            LDecl := ReadVarDecl(dkAbsVar, LTag)
          else
            LDecl := ReadLocalDecl(AKind, LTag, AOwnerType);
        arLabel:
          begin
            LDecl := NewNamedDecl(dkLabel, LTag);
            ReadUIndex; ReadUIndex; ReadUIndex;
          end;
        arMethod, arConstr, arDestr:
          LDecl := ReadMethodDecl(AKind, LTag, AOwnerType);
        arClassVar:
          LDecl := ReadLocalDecl(AKind, LTag, AOwnerType);
        arProperty:
          if AKind = lkDispInterface then
            LDecl := ReadLocalDecl(AKind, LTag, AOwnerType)
          else
            LDecl := ReadPropDecl(AOwnerType);
        arCDecl..arSafeCall:
          ;                      // a calling convention marker, no data
        arSetDeft:
          begin
            // A parameter default: no slot, no name.
            LDecl := FUnit.NewDecl(dkParamDefault);
            LDecl.Tag := LTag;
            LDecl.ConstSlot := ReadUIndex;
            LDecl.ArgSlot := ReadUIndex;
          end;
        drStop2:
          ReadULong;
        drStrConstRec:
          begin
            LDecl := NewNamedDecl(dkStrConst, LTag);
            ReadFlagged(LDecl, False);
            LDecl.Offset := ReadUIndex;
            LDecl.CodeSize := ReadUIndex;
            ReadByte;
          end;
        // ---- type definitions ----
        drRangeDef, drChRangeDef, drBoolRangeDef, drWCharRangeDef, drWideRangeDef:
          ReadRangeDef(LTag);
        drEnumDef: ReadEnumDef;
        drFloatDef: ReadFloatDef;
        drPtrDef, drDynArrayDef: ReadPtrDef(LTag);
        drTextDef:
          ReadTypeDefBase(NewType(tkText, LTag));
        drFileDef: ReadFileDef;
        drSetDef: ReadSetDef;
        drShortStrDef: ReadArrayDef(LTag, tkShortString);
        drStringDef, drWideStrDef, drUnicodeStringDef: ReadArrayDef(LTag, tkString);
        drArrayDef: ReadArrayDef(LTag, tkArray);
        drVariantDef: ReadVariantDef;
        drObjVMTDef: ReadClassRefDef;
        drRecDef: ReadRecDef;
        drProcTypeDef: ReadProcTypeDef;
        drObjDef: ReadObjDef;
        drClassDef, drMetaClassDef: ReadClassDef(LTag);
        drInterfaceDef: ReadInterfaceDef;
        drVoid: ReadVoidDef;
        drTemplateArgDef: ReadTemplateArgDef;
        drTemplateCall: ReadTemplateCall;
        // ---- tables and info records ----
        drCBlock:
          begin
            if AKind <> lkMain then
              Break;
            if FDataBlockSeen then
              Error('Second data block');
            FDataBlockSeen := True;
            Skip(ReadUIndex);
          end;
        drFixUp: SkipFixups;
        drCodeLines: SkipCodeLines;
        drLinNum: SkipLineRanges;
        drStrucScope: SkipStrucScope;
        drLocVarTbl: SkipLocVarTbl;
        drSymbolRef: SkipSymbolInfo;
        drUnitAddInfo:
          begin
            LDecl := NewNamedDecl(dkUnitAddInfo, LTag);
            ReadFlagged(LDecl, False);
            ReadUIndex;
            LDecl.Items := TList<TPasDcuDecl>.Create;
            ReadTag;
            ReadDeclList(lkUnitAddInfo, nil, nil, LDecl.Items);
          end;
        drConstAddInfo:
          ReadConstAddInfo;
        drProcAddInfo:
          SetProcAddInfo(ReadIndex);
        drNextOverload:
          ReserveAddr(ReadUIndex);
        drDependencyInfo: SkipDependencyInfo;
        drORec:
          begin
            LDecl := NewNamedDecl(dkORec, LTag);
            ReadULong;
            ReadByte;
            ReadByte;
            LDecl.Items := TList<TPasDcuDecl>.Create;
            ReadTag;
            ReadDeclList(lkA6, nil, nil, LDecl.Items);
            if FTag <> drStop1 then
              Error('Frame record list not closed');
          end;
        drCPPFlags:
          begin ReadByte; ReadUIndex; end;
        drCLine:
          begin
            ReadByte;
            Skip(ReadUIndex);
          end;
        drA1Info:
          begin
            ReadUIndex; ReadUIndex; ReadUIndex; ReadUIndex;
            LCount := ReadUIndex;
            for LIdx := 1 to LCount do
              ReadUIndex;
          end;
        drA2Info, drA5Info:
          ;
        arCopyDecl:
          begin
            LDecl := FUnit.NewDecl(dkCopy);
            LDecl.Tag := LTag;
            LDecl.Slot := AppendAddr(LDecl);
            LDecl.BaseSlot := ReadUIndex;
            LDecl.Base := FUnit.AddrAt(LDecl.BaseSlot);
            if LDecl.Base = nil then
              Error('Copy of an empty slot #%x', [LDecl.BaseSlot]);
            LDecl.Name := LDecl.Base.Name;
            LDecl.OwnerType := AOwnerType;
            if AKind = lkA6 then
              DropLastAddr(LDecl);
          end;
        drA6Info:
          LDecl := ReadA6List(AOwnerRoutine);
        drA7Info:
          ReadA7(AOwnerType, AOwnerRoutine);
        drA8Info, drA9Info:
          ReadUIndex;
        arAnonymousBlock:
          begin ReadUIndex; ReadUIndex; end;
        drDelayedImpInfo:
          begin
            LDecl := NewNamedDecl(dkDelayedImport, LTag);
            ReadULong;
            ReserveAddr(ReadUIndex);
          end;
        drSegInfo: SkipSegInfo;
        drAddrToSegInfo: SkipAddrToSegInfo;
        arFinalFlag:
          ReadUIndex;
      else
        Break;
      end;
      if LDecl <> nil then
      begin
        if LDecl.OwnerType = nil then
          LDecl.OwnerType := AOwnerType;
        if LDecl.OwnerRoutine = nil then
          LDecl.OwnerRoutine := AOwnerRoutine;
        AList.Add(LDecl);
      end;
      ReadTag;
    end;
  finally
    // An embedded list nobody claimed (a routine that never followed):
    // keep its rows reachable through the enclosing list.
    if LEmbedded <> nil then
    begin
      for LLast in LEmbedded do
        AList.Add(LLast);
      LEmbedded.Free;
    end;
  end;
end;

procedure TPasDcuReader.Load;
begin
  FPos := 0;
  ReadHeader;
  ReadSourceFiles;
  ReadUses(drUnit, usInterface);
  ReadUses(drUnit1, usImplementation);
  ReadUses(drDLL, usDll);
  ReadDeclList(lkMain, nil, nil, FUnit.Decls);
  // Everything the reader knows how to read ends at the data block and the
  // fixups; stopping anywhere earlier means a record it did not understand.
  if not (FDataBlockSeen and FFixupsSeen) then
    Error('Unknown record ended the declaration list');
end;

end.
