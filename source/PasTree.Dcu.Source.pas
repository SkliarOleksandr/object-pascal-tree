unit PasTree.Dcu.Source;

{
  PasTree - the interface section a compiled unit stands for.

  Prints the declarations PasTree.Dcu read out of a .dcu as the text of an
  interface-only unit: `unit X; interface uses ...; <declarations>
  implementation end.` That text is what the analyzer parses when a unit has
  no .pas - the ordinary lexer, parser and resolver run over it and nothing
  downstream knows the declarations came from a binary. It is also what a
  host shows when navigation lands in such a unit (the README's "virtual
  interface-only .pas"): positions in the generated text are real positions,
  so Ctrl+Click on a member of a .dcu-only class lands on that member's line.

  WHAT IS PRINTED, AND HOW FAITHFULLY. Every declaration the compiler marked
  as belonging to the interface part: constants with their values, types
  (classes, records, interfaces, enumerations, sets, arrays, pointers,
  procedural types, generics with their parameters, helpers, anonymous method
  types), variables, routine headers with calling convention and default
  parameter values, members with visibility, property accessors, index,
  stored, default. Three things a .dcu stores only as compiled data are NOT
  reconstructed, and the text says so where they would be:
  - a typed constant (`const X: T = ...`) is printed as `var X: T;` - the
    type is right, the value is in the data block this reader never decodes;
  - a resourcestring is printed with an empty value;
  - a type the reader could not resolve is spelled __PasTreeUnresolved, an
    identifier that is declared nowhere, so its every use is an honest
    E2003 in the generated unit rather than a silently wrong binding. The
    header comment lists them.
  Visibility below `private` (strict private/protected), `abstract` and
  `sealed` on classes, `reintroduce`, `abstract` and `final` on methods are
  not stored in a form this reader knows and are left out; a caller must not
  rely on their absence.

  NAMES FROM OTHER UNITS are printed bare when only one unit reachable from
  the interface uses clause (or this unit) declares that name, and qualified
  (`Unit.Name`) otherwise - the compiler resolved the reference once, and the
  qualification keeps the resolver from re-deciding it differently. `string`
  is the one imported name that cannot be qualified and never is.

  GENERIC PARAMETER NAMES are not stored beside the generic type. They are
  recovered from the instantiation the unit itself makes of the type with its
  own parameters (`TList<T>` inside TList's members), else from the parameter
  types the members mention, else synthesized as T1..Tn - the members then
  print the same entries' names, so header and body agree.
}

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  PasTree.Types,
  PasTree.Dcu;

const
  { The spelling of a type the printer could not resolve. Declared nowhere,
    on purpose: every use is an E2003 that names the gap. }
  cDcuUnresolvedName = '__PasTreeUnresolved';

{ The interface source of AUnit. AUnresolved receives one line per place the
  printer had to fall back (an unresolved type, a property without a printable
  accessor); the same lines are in the text's header comment. }
function DcuInterfaceSource(AUnit: TPasDcuUnit): string; overload;
function DcuInterfaceSource(AUnit: TPasDcuUnit;
  out AUnresolved: TArray<string>): string; overload;

implementation

uses
  System.Math,
  System.StrUtils,
  System.Generics.Defaults;

type
  TSection = (secNone, secType, secConst, secVar, secThreadVar, secResString);

  TPasDcuPrinter = class
  private
    FUnit: TPasDcuUnit;
    FOut: TStringBuilder;
    FIndent: Integer;
    FSection: TSection;
    // A raw name (lower case, generic arity kept) -> how many units declare
    // it as seen from here: this unit's own declarations count as one source,
    // every interface uses entry that imports it as another. > 1 = qualify.
    FNameSources: TDictionary<string, Integer>;
    // Constants that are the members of an enumeration, keyed by the
    // enumeration's type index; printed inside `(...)`, never as constants.
    FEnumMembers: TDictionary<Integer, TList<TPasDcuDecl>>;
    FConsumed: TDictionary<TPasDcuDecl, Boolean>;
    // Type indices whose definition (or forward declaration) has been
    // printed: a class/interface referenced before that needs a forward.
    FDeclared: TDictionary<Integer, Boolean>;
    FDefined: TDictionary<Integer, Boolean>;    // full definition printed
    FPrinting: TDictionary<Integer, Boolean>;   // being printed right now
    // The forward declarations the current `type` block needs, inserted at
    // its start when the block closes (FBlockStart = insertion offset).
    FForwards: TList<string>;
    FBlockStart: Integer;
    FUnresolved: TList<string>;
    FGenericNames: TDictionary<Integer, TArray<string>>;
    // The instantiation record (tkGenericInst) that produced each expanded
    // generic type (its InstFullIdx), for spelling a reference to the latter.
    FInstOfFull: TDictionary<Integer, TPasDcuType>;
    procedure Line(const AText: string);
    procedure Blank;
    function Pad: string;
    procedure Note(const AFmt: string; const AArgs: array of const);
    function Unresolved(const AWhat: string): string;
    // names
    function IsHidden(const AName: string): Boolean;
    function Esc(const AName: string): string;
    function StripArity(const AName: string): string;
    function ExpandedRef(AType: TPasDcuType): string;
    procedure BuildNameSources;
    function NeedsQualifier(const ARawName: string): Boolean;
    function ImportRef(AType: TPasDcuType): string;
    function OwnRef(AType: TPasDcuType): string;
    function InstRef(AType: TPasDcuType): string;
    function GenericParamNames(AType: TPasDcuType): TArray<string>;
    function GenericHead(const AName: string; AType: TPasDcuType): string;
    function TypeRef(AIdx: Integer): string;
    function IsVoid(AIdx: Integer): Boolean;
    function AccessorName(ASlot: Integer): string;
    // values
    function CharLiteral(ACode: Integer): string;
    function StringLiteral(const AText: string): string;
    function FloatLiteral(const ABytes: TBytes; AScale: Integer): string;
    function StringConstText(const ABytes: TBytes; AUnicode: Boolean): string;
    function OrdinalText(ATypeIdx: Integer; AValue: Int64): string;
    function SetText(ASetType: TPasDcuType; const ABytes: TBytes): string;
    function ConstValueText(AConst: TPasDcuDecl; ATypeIdx: Integer): string;
    // sections and declarations
    procedure Section(ASection: TSection);
    procedure CloseTypeBlock;
    procedure PrintUses;
    procedure PrintTopDecl(ADecl: TPasDcuDecl);
    procedure PrintTypeDecl(ADecl: TPasDcuDecl; AInBody: Boolean);
    function OwnsDefinition(ADecl: TPasDcuDecl; AType: TPasDcuType): Boolean;
    function DefText(AType: TPasDcuType): string;
    procedure PrintStructured(AType: TPasDcuType; const AHead: string);
    procedure PrintMembers(AType: TPasDcuType);
    function ParamsText(AList: TList<TPasDcuDecl>;
      const AOpen: string = '('; const AClose: string = ')'): string;
    function RoutineHead(const AWord, AName: string; AList: TList<TPasDcuDecl>;
      AResultIdx: Integer): string;
    function ProcTypeText(AType: TPasDcuType; const APrefix: string): string;
    procedure PrintMethod(AMember: TPasDcuDecl; AOwner: TPasDcuType);
    procedure PrintProperty(AMember: TPasDcuDecl; AOwner: TPasDcuType);
    procedure PrintDispProperty(AMember: TPasDcuDecl);
    function DefaultAllowed(AType: TPasDcuType): Boolean;
    procedure PrintRoutine(ADecl: TPasDcuDecl);
    procedure PrintConst(ADecl: TPasDcuDecl);
    procedure PrintVar(ADecl: TPasDcuDecl; ASection: TSection);
    procedure CollectEnumMembers;
    function Modifiers(ADecl: TPasDcuDecl): string;
    function CallKindWord(AKind: TPasDcuCallKind): string;
    function OperatorName(const AName: string): string;
  public
    constructor Create(AUnit: TPasDcuUnit);
    destructor Destroy; override;
    function Print: string;
    property UnresolvedNotes: TList<string> read FUnresolved;
  end;

const
  cIndentStep = 2;
  cVisibilityWords: array[0..3] of string = ('private', 'public', 'protected',
    'published');

function DcuInterfaceSource(AUnit: TPasDcuUnit): string;
var
  LNotes: TArray<string>;
begin
  Result := DcuInterfaceSource(AUnit, LNotes);
end;

function DcuInterfaceSource(AUnit: TPasDcuUnit;
  out AUnresolved: TArray<string>): string;
var
  LPrinter: TPasDcuPrinter;
begin
  LPrinter := TPasDcuPrinter.Create(AUnit);
  try
    Result := LPrinter.Print;
    AUnresolved := LPrinter.UnresolvedNotes.ToArray;
  finally
    LPrinter.Free;
  end;
end;

{ TPasDcuPrinter }

constructor TPasDcuPrinter.Create(AUnit: TPasDcuUnit);
begin
  inherited Create;
  FUnit := AUnit;
  FOut := TStringBuilder.Create;
  FNameSources := TDictionary<string, Integer>.Create;
  FEnumMembers := TObjectDictionary<Integer, TList<TPasDcuDecl>>.Create([doOwnsValues]);
  FConsumed := TDictionary<TPasDcuDecl, Boolean>.Create;
  FDeclared := TDictionary<Integer, Boolean>.Create;
  FDefined := TDictionary<Integer, Boolean>.Create;
  FPrinting := TDictionary<Integer, Boolean>.Create;
  FForwards := TList<string>.Create;
  FUnresolved := TList<string>.Create;
  FGenericNames := TDictionary<Integer, TArray<string>>.Create;
  FInstOfFull := TDictionary<Integer, TPasDcuType>.Create;
end;

destructor TPasDcuPrinter.Destroy;
begin
  FInstOfFull.Free;
  FGenericNames.Free;
  FUnresolved.Free;
  FForwards.Free;
  FPrinting.Free;
  FDefined.Free;
  FDeclared.Free;
  FConsumed.Free;
  FEnumMembers.Free;
  FNameSources.Free;
  FOut.Free;
  inherited;
end;

procedure TPasDcuPrinter.Line(const AText: string);
begin
  FOut.Append(Pad).Append(AText).Append(#13#10);
end;

procedure TPasDcuPrinter.Blank;
begin
  FOut.Append(#13#10);
end;

function TPasDcuPrinter.Pad: string;
begin
  Result := StringOfChar(' ', FIndent);
end;

procedure TPasDcuPrinter.Note(const AFmt: string; const AArgs: array of const);
begin
  FUnresolved.Add(Format(AFmt, AArgs));
end;

function TPasDcuPrinter.Unresolved(const AWhat: string): string;
begin
  Note('%s', [AWhat]);
  Result := cDcuUnresolvedName;
end;

{ Names }

// Compiler-made names: '.'/':' anonymous types and helper items, '$' and '@'
// thunks and frames, '{Unit}Name<Args>' instantiations.
function TPasDcuPrinter.IsHidden(const AName: string): Boolean;
begin
  Result := (AName = '') or CharInSet(AName[1], ['.', ':', '$', '@', '{']);
end;

// A name that is a reserved word (`unit`, `type`, `string`, `label`, `end`
// as field, member or enumeration names in imported type libraries) is
// spelled with the `&` escape, segment by segment.
function TPasDcuPrinter.Esc(const AName: string): string;
var
  LSegs: TArray<string>;
  LIdx: Integer;
  LChanged: Boolean;
begin
  if AName.IndexOf('.') < 0 then
  begin
    if (AName <> '') and (AName[1] <> '&') and
       (KeywordKind(PChar(AName), Length(AName)) <> tkIdentifier) then
      Exit('&' + AName);
    Exit(AName);
  end;
  LSegs := AName.Split(['.']);
  LChanged := False;
  for LIdx := 0 to High(LSegs) do
    if (LSegs[LIdx] <> '') and (LSegs[LIdx][1] <> '&') and
       (KeywordKind(PChar(LSegs[LIdx]), Length(LSegs[LIdx])) <> tkIdentifier) then
    begin
      LSegs[LIdx] := '&' + LSegs[LIdx];
      LChanged := True;
    end;
  if LChanged then
    Result := string.Join('.', LSegs)
  else
    Result := AName;
end;

// `TList`1` -> `TList`, segment by segment (`TList`1.TEnumerator`).
function TPasDcuPrinter.StripArity(const AName: string): string;
var
  LSegs: TArray<string>;
  LIdx, LTick: Integer;
begin
  if AName.IndexOf('`') < 0 then
    Exit(AName);
  LSegs := AName.Split(['.']);
  for LIdx := 0 to High(LSegs) do
  begin
    LTick := LSegs[LIdx].IndexOf('`');
    if LTick >= 0 then
      LSegs[LIdx] := LSegs[LIdx].Substring(0, LTick);
  end;
  Result := string.Join('.', LSegs);
end;

procedure TPasDcuPrinter.BuildNameSources;
var
  LSeen: TDictionary<string, Boolean>;
  LUses: TPasDcuUses;
  LDecl: TPasDcuDecl;
  LKey: string;

  procedure Count(const AName: string);
  var
    LN: Integer;
  begin
    if LSeen.ContainsKey(AName) then
      Exit;
    LSeen.Add(AName, True);
    if FNameSources.TryGetValue(AName, LN) then
      FNameSources[AName] := LN + 1
    else
      FNameSources.Add(AName, 1);
  end;

begin
  LSeen := TDictionary<string, Boolean>.Create;
  try
    // The unit's own top-level names are one source.
    for LDecl in FUnit.Decls do
      if (LDecl.Name <> '') and not IsHidden(LDecl.Name) and
         (LDecl.Name.IndexOf('.') < 0) then
        Count(LowerCase(LDecl.Name));
    // Every interface uses entry is another - each name once per unit.
    for LUses in FUnit.UsesList do
    begin
      if LUses.Section <> usInterface then
        Continue;
      LSeen.Clear;
      for LDecl in LUses.Imports do
      begin
        LKey := LowerCase(LDecl.Name);
        if LKey <> '' then
          Count(LKey);
      end;
    end;
  finally
    LSeen.Free;
  end;
end;

function TPasDcuPrinter.NeedsQualifier(const ARawName: string): Boolean;
var
  LN: Integer;
begin
  Result := FNameSources.TryGetValue(LowerCase(ARawName), LN) and (LN > 1);
end;

function TPasDcuPrinter.ImportRef(AType: TPasDcuType): string;
var
  LRaw: string;
  LUses: TPasDcuUses;
begin
  LRaw := AType.ImportName;
  if LRaw = '' then
    LRaw := AType.Name;
  if LRaw = '' then
    Exit(Unresolved(Format('imported type #%d has no name', [AType.Index])));
  Result := StripArity(LRaw);
  // `string` is a reserved word: System.string is not a spelling.
  if SameText(Result, 'string') then
    Exit('string');
  LUses := FUnit.UsesOf(AType.UnitIdx);
  if (LUses <> nil) and NeedsQualifier(LRaw) then
    Result := LUses.Name + '.' + Result;
end;

// A type of this unit by name; a class or interface that is referenced
// before its definition gets a forward declaration in the current block.
function TPasDcuPrinter.OwnRef(AType: TPasDcuType): string;
var
  LHead: string;
begin
  Result := StripArity(AType.Name);
  if FDeclared.ContainsKey(AType.Index) or FPrinting.ContainsKey(AType.Index) then
    Exit;
  if AType.Kind in [tkClass, tkInterface] then
  begin
    // A nested type cannot be forward-declared from the outside; its owner's
    // definition carries it and precedes any legal use.
    if AType.Name.IndexOf('.') >= 0 then
      Exit;
    LHead := GenericHead(Result, AType);
    if AType.Kind = tkClass then
      FForwards.Add(LHead + ' = class;')
    else if AType.IsDispInterface then
      FForwards.Add(LHead + ' = dispinterface;')
    else
      FForwards.Add(LHead + ' = interface;');
    FDeclared.Add(AType.Index, True);
  end;
end;

// `TList<Integer>`: the generic's spelling with its arity replaced by the
// arguments, segment by segment for a nested generic (`TList<T>.TEnumerator`).
function TPasDcuPrinter.InstRef(AType: TPasDcuType): string;
var
  LBase: TPasDcuType;
  LRaw, LSeg: string;
  LSegs: TArray<string>;
  LIdx, LTick, LArity, LNext, LJ: Integer;
  LArgs: TArray<string>;
  LUses: TPasDcuUses;
begin
  LBase := FUnit.TypeAt(AType.BaseIdx);
  if LBase = nil then
    Exit(Unresolved(Format('generic base type #%d', [AType.BaseIdx])));
  SetLength(LArgs, Length(AType.GenericArgs));
  for LIdx := 0 to High(LArgs) do
    LArgs[LIdx] := TypeRef(AType.GenericArgs[LIdx]);
  if LBase.Kind = tkImport then
  begin
    LRaw := LBase.ImportName;
    if LRaw = '' then
      LRaw := LBase.Name;
  end
  else
  begin
    LRaw := LBase.Name;
    if (LBase.Kind in [tkClass, tkInterface]) and
       not FDeclared.ContainsKey(LBase.Index) and
       not FPrinting.ContainsKey(LBase.Index) and (LRaw.IndexOf('.') < 0) then
    begin
      // Same forward rule as OwnRef, spelled with the generic's parameters.
      if LBase.Kind = tkClass then
        FForwards.Add(GenericHead(StripArity(LRaw), LBase) + ' = class;')
      else
        FForwards.Add(GenericHead(StripArity(LRaw), LBase) + ' = interface;');
      FDeclared.Add(LBase.Index, True);
    end;
  end;
  if LRaw = '' then
    Exit(Unresolved(Format('generic base type #%d has no name', [LBase.Index])));
  // An instantiation of an anonymous type declared inside a generic (an
  // `array of T` field): its definition, with the parameter named as the
  // generic's own members name it.
  if IsHidden(LRaw) and not LBase.IsStructured then
    Exit(DefText(LBase));
  LSegs := LRaw.Split(['.']);
  LNext := 0;
  for LIdx := 0 to High(LSegs) do
  begin
    LSeg := LSegs[LIdx];
    LTick := LSeg.IndexOf('`');
    if LTick < 0 then
      Continue;
    LArity := StrToIntDef(LSeg.Substring(LTick + 1), 0);
    LSeg := LSeg.Substring(0, LTick) + '<';
    for LJ := 1 to LArity do
    begin
      if LJ > 1 then
        LSeg := LSeg + ', ';
      if LNext <= High(LArgs) then
        LSeg := LSeg + LArgs[LNext]
      else
        LSeg := LSeg + Unresolved(Format('generic argument %d of %s', [LNext, LRaw]));
      Inc(LNext);
    end;
    LSegs[LIdx] := LSeg + '>';
  end;
  Result := string.Join('.', LSegs);
  if LBase.Kind = tkImport then
  begin
    LUses := FUnit.UsesOf(LBase.UnitIdx);
    if (LUses <> nil) and NeedsQualifier(LRaw) then
      Result := LUses.Name + '.' + Result;
  end;
end;

// An expanded generic the unit references without an instantiation record
// of its own (`{System}TArray<System.string>`): the compiler's spelling,
// with the declaring unit's prefix turned into a qualifier where the name
// needs one, every argument's unit prefix dropped, and a reference to a
// generic's own parameter (`TList<T>.T`) reduced to the parameter.
function TPasDcuPrinter.ExpandedRef(AType: TPasDcuType): string;
var
  LClose: Integer;
  LUnitName, LRest: string;

  function StripUnitPrefix(const AText: string): string;
  var
    LUses: TPasDcuUses;
    LBest: string;
  begin
    LBest := '';
    for LUses in FUnit.UsesList do
      if AText.StartsWith(LUses.Name + '.', True) and
         (Length(LUses.Name) > Length(LBest)) then
        LBest := LUses.Name;
    if SameText(AText, 'System.string') then
      Exit('string');
    if AText.StartsWith('System.', True) and (LBest = '') then
      LBest := 'System';
    if LBest = '' then
      Exit(AText);
    Result := AText.Substring(Length(LBest) + 1);
  end;

  function SplitTopLevel(const AText: string): TArray<string>;
  var
    LDepth, LIdx, LStart: Integer;
  begin
    Result := nil;
    LDepth := 0;
    LStart := 1;
    for LIdx := 1 to Length(AText) do
      case AText[LIdx] of
        '<': Inc(LDepth);
        '>': Dec(LDepth);
        ',':
          if LDepth = 0 then
          begin
            Result := Result + [Trim(AText.Substring(LStart - 1, LIdx - LStart))];
            LStart := LIdx + 1;
          end;
      end;
    Result := Result + [Trim(AText.Substring(LStart - 1))];
  end;

  function Clean(const AText: string): string;
  var
    LOpen, LCloseIdx, LDepth, LIdx: Integer;
    LHead, LTail: string;
    LArgs: TArray<string>;
  begin
    LOpen := AText.IndexOf('<');
    if LOpen < 0 then
      Exit(Esc(StripUnitPrefix(AText)));
    // Matching '>' of the first '<'.
    LDepth := 0;
    LCloseIdx := -1;
    for LIdx := LOpen to Length(AText) - 1 do
    begin
      if AText.Chars[LIdx] = '<' then
        Inc(LDepth)
      else if AText.Chars[LIdx] = '>' then
      begin
        Dec(LDepth);
        if LDepth = 0 then
        begin
          LCloseIdx := LIdx;
          Break;
        end;
      end;
    end;
    if LCloseIdx < 0 then
      Exit(Esc(StripUnitPrefix(AText)));
    LTail := AText.Substring(LCloseIdx + 1);
    // `Generic<...>.T` is the generic's parameter T.
    if LTail.StartsWith('.') and (LTail.IndexOf('.', 1) < 0) and
       (LTail.IndexOf('<') < 0) then
      Exit(Esc(LTail.Substring(1)));
    LHead := Esc(StripUnitPrefix(AText.Substring(0, LOpen)));
    LArgs := SplitTopLevel(AText.Substring(LOpen + 1, LCloseIdx - LOpen - 1));
    for LIdx := 0 to High(LArgs) do
      LArgs[LIdx] := Clean(LArgs[LIdx]);
    Result := LHead + '<' + string.Join(', ', LArgs) + '>';
    if LTail <> '' then
      Result := Result + Clean(LTail.Substring(1)).Insert(0, '.');
  end;

var
  LOpen, LArity: Integer;
  LRaw: string;
begin
  LClose := AType.Name.IndexOf('}');
  if LClose < 0 then
    Exit(Unresolved(Format('expanded generic %s', [AType.Name])));
  LUnitName := AType.Name.Substring(1, LClose - 1);
  LRest := AType.Name.Substring(LClose + 1);
  Result := Clean(LRest);
  // Qualify the generic itself when its raw name is ambiguous here.
  LOpen := LRest.IndexOf('<');
  if (LOpen > 0) and (LUnitName <> '') and not SameText(LUnitName, FUnit.UnitName) then
  begin
    LArity := Length(SplitTopLevel(LRest.Substring(LOpen + 1,
      LRest.LastIndexOf('>') - LOpen - 1)));
    LRaw := LRest.Substring(0, LOpen) + '`' + IntToStr(LArity);
    if NeedsQualifier(LRaw) then
      Result := LUnitName + '.' + Result;
  end;
end;

// See the unit comment: the self-instantiation first, then the parameter
// types the members mention, then T1..Tn.
function TPasDcuPrinter.GenericParamNames(AType: TPasDcuType): TArray<string>;
var
  LArity, LIdx, LTick, LSeg: Integer;
  LInst, LArg: TPasDcuType;
  LAll: Boolean;
  LFound: TList<string>;
  LSeen: TDictionary<Integer, Boolean>;

  procedure Visit(ATypeIdx: Integer; ADepth: Integer);
  var
    LT: TPasDcuType;
    LM: TPasDcuDecl;
    LA: Integer;
  begin
    if (ADepth > 4) or (ATypeIdx <= 0) or (LFound.Count >= LArity) then
      Exit;
    LT := FUnit.TypeAt(ATypeIdx);
    if (LT = nil) or LSeen.ContainsKey(ATypeIdx) then
      Exit;
    LSeen.Add(ATypeIdx, True);
    case LT.Kind of
      tkGenericParam:
        if (LT.Name <> '') and (LFound.IndexOf(LT.Name) < 0) then
          LFound.Add(LT.Name);
      tkGenericInst:
        for LA in LT.GenericArgs do
          Visit(LA, ADepth + 1);
      tkPointer, tkDynArray, tkSet, tkClassRef:
        Visit(LT.BaseIdx, ADepth + 1);
      tkArray:
        Visit(LT.ElemIdx, ADepth + 1);
      tkProcType:
        begin
          Visit(LT.ResultTypeIdx, ADepth + 1);
          if LT.Members <> nil then
            for LM in LT.Members do
              Visit(LM.TypeIdx, ADepth + 1);
        end;
    end;
  end;

  procedure VisitMembers(AOwner: TPasDcuType);
  var
    LM, LR, LA: TPasDcuDecl;
  begin
    if AOwner.Members = nil then
      Exit;
    Visit(AOwner.ParentIdx, 1);
    for LM in AOwner.Members do
    begin
      case LM.Kind of
        dkField, dkClassVar, dkProperty:
          Visit(LM.TypeIdx, 1);
        dkMethod, dkConstructor, dkDestructor:
          begin
            LR := FUnit.AddrAt(LM.Offset);
            if (LR <> nil) and (LR.Kind = dkRoutine) and (LR.Args <> nil) then
            begin
              Visit(LR.ResultTypeIdx, 1);
              for LA in LR.Args do
                if LA.Tag in [$21, $22] then
                  Visit(LA.TypeIdx, 1);
            end;
          end;
      end;
      if LFound.Count >= LArity then
        Break;
    end;
  end;

begin
  if FGenericNames.TryGetValue(AType.Index, Result) then
    Exit;
  LTick := AType.Name.LastIndexOf('`');
  LArity := 0;
  if LTick >= 0 then
  begin
    LSeg := AType.Name.IndexOf('.', LTick);
    if LSeg < 0 then
      LSeg := Length(AType.Name);
    LArity := StrToIntDef(AType.Name.Substring(LTick + 1, LSeg - LTick - 1), 0);
  end;
  SetLength(Result, LArity);
  if LArity = 0 then
  begin
    FGenericNames.Add(AType.Index, Result);
    Exit;
  end;
  LFound := TList<string>.Create;
  LSeen := TDictionary<Integer, Boolean>.Create;
  try
    // 1. The instantiation of this generic with its own parameters.
    for LInst in FUnit.Types do
    begin
      if (LInst = nil) or (LInst.Kind <> tkGenericInst) or
         (LInst.BaseIdx <> AType.Index) or
         (Length(LInst.GenericArgs) <> LArity) then
        Continue;
      LAll := True;
      for LIdx := 0 to LArity - 1 do
      begin
        LArg := FUnit.TypeAt(LInst.GenericArgs[LIdx]);
        if (LArg = nil) or (LArg.Kind <> tkGenericParam) or (LArg.Name = '') then
        begin
          LAll := False;
          Break;
        end;
      end;
      if not LAll then
        Continue;
      for LIdx := 0 to LArity - 1 do
        Result[LIdx] := FUnit.TypeAt(LInst.GenericArgs[LIdx]).Name;
      FGenericNames.Add(AType.Index, Result);
      Exit;
    end;
    // 2. Parameter types the members mention, in order of first mention.
    VisitMembers(AType);
    for LIdx := 0 to LArity - 1 do
      if LIdx < LFound.Count then
        Result[LIdx] := LFound[LIdx]
      else if LArity = 1 then
        Result[LIdx] := 'T'
      else
        Result[LIdx] := 'T' + IntToStr(LIdx + 1);
    FGenericNames.Add(AType.Index, Result);
  finally
    LSeen.Free;
    LFound.Free;
  end;
end;

// `TList<T>` for the declaration head of a generic; the bare name otherwise.
function TPasDcuPrinter.GenericHead(const AName: string; AType: TPasDcuType): string;
var
  LNames: TArray<string>;
  LIdx: Integer;
begin
  Result := AName;
  if AType.Name.IndexOf('`') < 0 then
    Exit;
  LNames := GenericParamNames(AType);
  if Length(LNames) = 0 then
    Exit;
  for LIdx := 0 to High(LNames) do
    LNames[LIdx] := Esc(LNames[LIdx]);
  Result := Result + '<' + string.Join(', ', LNames) + '>';
end;

function TPasDcuPrinter.IsVoid(AIdx: Integer): Boolean;
var
  LType: TPasDcuType;
begin
  LType := FUnit.TypeAt(AIdx);
  Result := (LType <> nil) and (LType.Kind = tkVoid);
end;

// How a type is spelled at a use site: by name when it has one, inline when
// it is an anonymous definition (`set of Byte`, `^TFoo`, `0..3`).
function TPasDcuPrinter.TypeRef(AIdx: Integer): string;
var
  LType, LInst: TPasDcuType;
begin
  LType := FUnit.TypeAt(AIdx);
  if LType = nil then
    Exit(Unresolved(Format('type #%d is not in the type table', [AIdx])));
  case LType.Kind of
    tkPending:
      Exit(Unresolved(Format('type %s was named but never defined', [LType.Name])));
    tkImport:
      Exit(ImportRef(LType));
    tkGenericParam:
      begin
        if LType.Name = '' then
          Exit('T');
        Exit(LType.Name);
      end;
    tkGenericInst:
      Exit(InstRef(LType));
    tkVoid:
      Exit('Pointer');
  end;
  if (LType.Name <> '') and not IsHidden(LType.Name) then
    Exit(OwnRef(LType));
  // The expanded form of a generic instantiation (`{Unit}TList<T>`) is a
  // class of its own in the type table; a reference to it is spelled as the
  // instantiation that produced it.
  if (LType.Name <> '') and (LType.Name[1] = '{') then
  begin
    if FInstOfFull.TryGetValue(LType.Index, LInst) then
      Exit(InstRef(LInst));
    Exit(ExpandedRef(LType));
  end;
  if LType.IsStructured and (LType.Kind <> tkProcType) then
    Exit(Unresolved(Format('anonymous structured type #%d (kind %d)',
      [AIdx, Ord(LType.Kind)])));
  Result := DefText(LType);
end;

// The member a property accessor slot names, as it is spelled inside the
// class: a field, a method, an inherited member imported from the parent's
// unit (`TObject.Create` -> `Create`).
function TPasDcuPrinter.AccessorName(ASlot: Integer): string;
var
  LDecl: TPasDcuDecl;
begin
  Result := '';
  LDecl := FUnit.AddrAt(ASlot);
  if LDecl = nil then
    Exit;
  if LDecl.Kind = dkCopy then
    LDecl := LDecl.Base;
  if LDecl = nil then
    Exit;
  Result := LDecl.BareName;
  if IsHidden(Result) or (Result = '&') then
    Result := '';
end;

{ Values }

function TPasDcuPrinter.CharLiteral(ACode: Integer): string;
begin
  if (ACode >= 32) and (ACode < 127) then
  begin
    if ACode = Ord('''') then
      Result := ''''''''''
    else
      Result := '''' + Chr(ACode) + '''';
  end
  else
    Result := '#' + IntToStr(ACode);
end;

function TPasDcuPrinter.StringLiteral(const AText: string): string;
var
  LIdx: Integer;
  LCh: Char;
  LOpen: Boolean;
begin
  if AText = '' then
    Exit('''''');
  Result := '';
  LOpen := False;
  for LIdx := 1 to Length(AText) do
  begin
    LCh := AText[LIdx];
    if (Ord(LCh) < 32) or (Ord(LCh) = 127) then
    begin
      if LOpen then
      begin
        Result := Result + '''';
        LOpen := False;
      end;
      Result := Result + '#' + IntToStr(Ord(LCh));
    end
    else
    begin
      if not LOpen then
      begin
        Result := Result + '''';
        LOpen := True;
      end;
      if LCh = '''' then
        Result := Result + ''''''
      else
        Result := Result + LCh;
    end;
  end;
  if LOpen then
    Result := Result + '''';
end;

// A float constant's bytes: Single, Double, or the 80-bit Extended the Win32
// compiler stores (converted through its sign, exponent and mantissa - this
// code may itself be compiled for Win64 where Extended is 8 bytes).
function TPasDcuPrinter.FloatLiteral(const ABytes: TBytes; AScale: Integer): string;
var
  LSingle: Single;
  LDouble: Double;
  LMant: UInt64;
  LExp: Integer;
  LNeg: Boolean;
  LFmt: TFormatSettings;
begin
  LFmt := TFormatSettings.Invariant;
  case Length(ABytes) of
    4:
      begin
        Move(ABytes[0], LSingle, 4);
        LDouble := LSingle;
      end;
    8:
      Move(ABytes[0], LDouble, 8);
    10:
      begin
        Move(ABytes[0], LMant, 8);
        LExp := ABytes[8] or ((ABytes[9] and $7F) shl 8);
        LNeg := (ABytes[9] and $80) <> 0;
        if (LExp = 0) and (LMant = 0) then
          LDouble := 0
        else
          LDouble := (LMant / Power(2, 63)) * Power(2, LExp - 16383);
        if LNeg then
          LDouble := -LDouble;
      end;
  else
    Exit(Unresolved(Format('float constant of %d bytes', [Length(ABytes)])));
  end;
  if IsNan(LDouble) or IsInfinite(LDouble) then
    Exit('0.0');
  if AScale <> 1 then
    LDouble := LDouble / AScale;
  Result := FloatToStrF(LDouble, ffGeneral, 17, 0, LFmt);
  // Keep it a real literal: `3` would type as an integer.
  if (Result.IndexOf('.') < 0) and (Result.IndexOf('E') < 0) then
    Result := Result + '.0';
end;

// An ordinal of the given type as source: an enumeration member's name, a
// character, True/False, or the number.
function TPasDcuPrinter.OrdinalText(ATypeIdx: Integer; AValue: Int64): string;
var
  LType, LBase: TPasDcuType;
  LMembers: TList<TPasDcuDecl>;
  LMember: TPasDcuDecl;
  LName: string;
begin
  LType := FUnit.TypeAt(ATypeIdx);
  if LType <> nil then
  begin
    // A subrange of something: render as the something.
    if (LType.Kind = tkRange) and (LType.BaseIdx <> ATypeIdx) and
       (LType.BaseIdx > 0) then
    begin
      LBase := FUnit.TypeAt(LType.BaseIdx);
      if (LBase <> nil) and (LBase.Kind in [tkEnum, tkImport]) then
        Exit(OrdinalText(LType.BaseIdx, AValue));
    end;
    case LType.Kind of
      tkEnum:
        begin
          if FEnumMembers.TryGetValue(LType.Index, LMembers) then
            for LMember in LMembers do
              if LMember.ValueInt = AValue then
                Exit(Esc(LMember.BareName));
          LName := TypeRef(ATypeIdx);
          Exit(Format('%s(%d)', [LName, AValue]));
        end;
      tkRange:
        case LType.Tag of
          $41:   // Boolean
            if AValue = 0 then
              Exit('False')
            else if AValue = 1 then
              Exit('True');
          $42, $51:   // AnsiChar, WideChar
            Exit(CharLiteral(Integer(AValue)));
        end;
      tkImport:
        begin
          LName := LowerCase(LType.ImportName);
          if (LName = 'boolean') or (LName = 'bytebool') or
             (LName = 'wordbool') or (LName = 'longbool') then
          begin
            if AValue = 0 then
              Exit('False');
            if AValue = 1 then
              Exit('True');
          end
          else if (LName = 'char') or (LName = 'ansichar') or
                  (LName = 'widechar') then
            Exit(CharLiteral(Integer(AValue)))
          else if (LName = 'pointer') or (LName = 'tobject') or
                  (LName = 'tclass') or (LName = 'iinterface') then
          begin
            if AValue = 0 then
              Exit('nil');
          end
          else if (LName <> '') and (LName <> 'integer') and
                  (LName <> 'cardinal') and (LName <> 'byte') and
                  (LName <> 'word') and (LName <> 'shortint') and
                  (LName <> 'smallint') and (LName <> 'longint') and
                  (LName <> 'longword') and (LName <> 'int64') and
                  (LName <> 'uint64') and (LName <> 'nativeint') and
                  (LName <> 'nativeuint') and (LName <> 'int8') and
                  (LName <> 'uint8') and (LName <> 'int16') and
                  (LName <> 'uint16') and (LName <> 'int32') and
                  (LName <> 'uint32') and (LName <> 'fixedint') and
                  (LName <> 'fixeduint') and (LName <> 'intptr') and
                  (LName <> 'uintptr') then
            // An imported ordinal type that is not a number (an enumeration
            // declared in another unit, whose member names live there): a
            // typed cast keeps both the value and the type.
            Exit(Format('%s(%d)', [ImportRef(LType), AValue]));
        end;
      tkPointer, tkClass, tkInterface, tkClassRef, tkDynArray, tkString,
      tkProcType, tkMetaClass, tkGenericInst:
        if AValue = 0 then
          Exit('nil');
    end;
  end;
  Result := IntToStr(AValue);
end;

// A set constant's bytes as `[a, b, c]`; the bytes cover the set's storage
// from element SetStart * 8 up.
function TPasDcuPrinter.SetText(ASetType: TPasDcuType; const ABytes: TBytes): string;
var
  LIdx, LBit, LOrd: Integer;
  LItems: TList<string>;
  LBaseIdx: Integer;
begin
  LItems := TList<string>.Create;
  try
    LBaseIdx := 0;
    if ASetType <> nil then
      LBaseIdx := ASetType.BaseIdx;
    for LIdx := 0 to High(ABytes) do
      for LBit := 0 to 7 do
        if (ABytes[LIdx] and (1 shl LBit)) <> 0 then
        begin
          LOrd := LIdx * 8 + LBit;
          if ASetType <> nil then
            Inc(LOrd, ASetType.SetStart * 8);
          if LBaseIdx > 0 then
            LItems.Add(OrdinalText(LBaseIdx, LOrd))
          else
            LItems.Add(IntToStr(LOrd));
        end;
    Result := '[' + string.Join(', ', LItems.ToArray) + ']';
  finally
    LItems.Free;
  end;
end;

// The characters of a string constant. Since Delphi 2009 the record holds the
// string's memory image: a 12-byte header (code page, element size,
// reference count -1, length) and the characters with their terminator; an
// older layout, or a bare run of characters, has no header.
function TPasDcuPrinter.StringConstText(const ABytes: TBytes; AUnicode: Boolean): string;
var
  LLen, LElem, LStart, LCount: Integer;
begin
  LStart := 0;
  LCount := Length(ABytes);
  if (LCount >= 12) and (ABytes[4] = $FF) and (ABytes[5] = $FF) and
     (ABytes[6] = $FF) and (ABytes[7] = $FF) then
  begin
    LElem := ABytes[2] or (ABytes[3] shl 8);
    LLen := PInteger(@ABytes[8])^;
    if (LElem in [1, 2]) and (LLen >= 0) and (12 + LLen * LElem <= LCount) then
    begin
      LStart := 12;
      LCount := LLen * LElem;
      AUnicode := LElem = 2;
    end;
  end
  else
  begin
    // No header: the run ends at its terminator.
    if AUnicode then
    begin
      LCount := LCount and not 1;
      while (LCount >= 2) and (ABytes[LCount - 1] = 0) and (ABytes[LCount - 2] = 0) do
        Dec(LCount, 2);
    end
    else
      while (LCount > 0) and (ABytes[LCount - 1] = 0) do
        Dec(LCount);
  end;
  if LCount <= 0 then
    Exit('');
  if AUnicode then
    Result := TEncoding.Unicode.GetString(ABytes, LStart, LCount)
  else
    Result := TEncoding.ANSI.GetString(ABytes, LStart, LCount);
end;

function TPasDcuPrinter.ConstValueText(AConst: TPasDcuDecl; ATypeIdx: Integer): string;
var
  LType: TPasDcuType;
  LScale: Integer;
begin
  LType := FUnit.TypeAt(ATypeIdx);
  case AConst.ValueKind of
    0:
      begin
        if Length(AConst.ValueBytes) = 0 then
          Exit(OrdinalText(ATypeIdx, AConst.ValueInt));
        // An ordinal stored as bytes: a set, or an integer wider than the
        // index encoding carried.
        if (LType <> nil) and (LType.Kind = tkSet) then
          Exit(SetText(LType, AConst.ValueBytes));
        if Length(AConst.ValueBytes) <= 8 then
        begin
          AConst.ValueInt := 0;
          Move(AConst.ValueBytes[0], AConst.ValueInt, Length(AConst.ValueBytes));
          Exit(OrdinalText(ATypeIdx, AConst.ValueInt));
        end;
        Exit(Unresolved(Format('constant %s of %d bytes', [AConst.Name,
          Length(AConst.ValueBytes)])));
      end;
    1, 5:
      Exit(StringLiteral(StringConstText(AConst.ValueBytes, AConst.ValueKind = 5)));
    3:
      begin
        // A real constant the compiler typed as Currency (one with at most
        // four decimals - `3.25`) is stored SCALED by 10000, the way a
        // Currency variable is.
        LScale := 1;
        if (LType <> nil) and
           (((LType.Kind = tkFloat) and (LType.FloatKind = 5)) or
            ((LType.Kind = tkImport) and SameText(LType.ImportName, 'Currency'))) then
          LScale := 10000;
        Exit(FloatLiteral(AConst.ValueBytes, LScale));
      end;
    4:
      begin
        if Length(AConst.ValueBytes) = 0 then
          Exit('nil');
        Exit(SetText(LType, AConst.ValueBytes));
      end;
  end;
  Result := Unresolved(Format('constant %s of kind %d', [AConst.Name, AConst.ValueKind]));
end;

{ Sections }

procedure TPasDcuPrinter.Section(ASection: TSection);
const
  cWords: array[TSection] of string = ('', 'type', 'const', 'var', 'threadvar',
    'resourcestring');
begin
  if ASection = FSection then
    Exit;
  if FSection = secType then
    CloseTypeBlock;
  FSection := ASection;
  Blank;
  if cWords[ASection] <> '' then
  begin
    FIndent := 0;
    Line(cWords[ASection]);
    FIndent := cIndentStep;
  end
  else
    FIndent := 0;
  if ASection = secType then
    FBlockStart := FOut.Length;
end;

// Insert the forward declarations the block needed at its start.
procedure TPasDcuPrinter.CloseTypeBlock;
var
  LText: string;
  LIdx: Integer;
begin
  if FForwards.Count = 0 then
    Exit;
  LText := '';
  for LIdx := 0 to FForwards.Count - 1 do
    LText := LText + StringOfChar(' ', cIndentStep) + FForwards[LIdx] + #13#10;
  FOut.Insert(FBlockStart, LText);
  FForwards.Clear;
end;

procedure TPasDcuPrinter.PrintUses;
var
  LUses: TPasDcuUses;
  LNames: TList<string>;
  LLower: string;
begin
  LNames := TList<string>.Create;
  try
    for LUses in FUnit.UsesList do
    begin
      if LUses.Section <> usInterface then
        Continue;
      LLower := LowerCase(LUses.Name);
      // The two units every unit uses without naming them; naming them is
      // an error.
      if (LLower = 'system') or (LLower = 'sysinit') then
        Continue;
      LNames.Add(LUses.Name);
    end;
    if LNames.Count = 0 then
      Exit;
    Blank;
    Line('uses');
    Line('  ' + string.Join(', ', LNames.ToArray) + ';');
  finally
    LNames.Free;
  end;
end;

// Enumeration members are ordinary constants typed with the enumeration and
// numbered from the record; they are gathered per type here and printed
// inside the type's parentheses.
procedure TPasDcuPrinter.CollectEnumMembers;
var
  LDecl: TPasDcuDecl;
  LType: TPasDcuType;
  LList: TList<TPasDcuDecl>;
  LKey: Integer;
begin
  for LDecl in FUnit.Decls do
  begin
    if (LDecl.Kind <> dkConst) or (LDecl.ValueKind <> 0) or
       (Length(LDecl.ValueBytes) <> 0) or IsHidden(LDecl.Name) then
      Continue;
    LType := FUnit.TypeAt(LDecl.TypeIdx);
    if (LType = nil) or (LType.Kind <> tkEnum) then
      Continue;
    if not FEnumMembers.TryGetValue(LType.Index, LList) then
    begin
      LList := TList<TPasDcuDecl>.Create;
      FEnumMembers.Add(LType.Index, LList);
    end;
    LList.Add(LDecl);
    FConsumed.AddOrSetValue(LDecl, True);
  end;
  for LKey in FEnumMembers.Keys do
    FEnumMembers[LKey].Sort(TComparer<TPasDcuDecl>.Construct(
      function(const ALeft, ARight: TPasDcuDecl): Integer
      begin
        if ALeft.ValueInt < ARight.ValueInt then
          Result := -1
        else if ALeft.ValueInt > ARight.ValueInt then
          Result := 1
        else
          Result := ALeft.Slot - ARight.Slot;
      end));
end;

function TPasDcuPrinter.CallKindWord(AKind: TPasDcuCallKind): string;
begin
  case AKind of
    dcCdecl: Result := ' cdecl;';
    dcPascal: Result := ' pascal;';
    dcStdCall: Result := ' stdcall;';
    dcSafeCall: Result := ' safecall;';
  else
    Result := '';
  end;
end;

// `deprecated 'msg' platform library` from the ConstAddInfo flags.
function TPasDcuPrinter.Modifiers(ADecl: TPasDcuDecl): string;
begin
  Result := '';
  if ADecl = nil then
    Exit;
  if ADecl.HasDeprecated or ((ADecl.CaiFlags and caiDeprecated) <> 0) then
  begin
    Result := Result + ' deprecated';
    if ADecl.DeprecatedMsg <> '' then
      Result := Result + ' ' + StringLiteral(ADecl.DeprecatedMsg);
  end;
  if (ADecl.CaiFlags and caiPlatform) <> 0 then
    Result := Result + ' platform';
  if (ADecl.CaiFlags and caiLibrary) <> 0 then
    Result := Result + ' library';
end;

// The compiler names operator methods the C++ way (`&op_Addition`); the
// source spelling is the Delphi operator name.
function TPasDcuPrinter.OperatorName(const AName: string): string;
const
  cMap: array[0..31, 0..1] of string = (
    ('op_Implicit', 'Implicit'), ('op_Explicit', 'Explicit'),
    ('op_UnaryNegation', 'Negative'), ('op_UnaryPlus', 'Positive'),
    ('op_Increment', 'Inc'), ('op_Decrement', 'Dec'),
    ('op_LogicalNot', 'LogicalNot'), ('op_Trunc', 'Trunc'),
    ('op_Round', 'Round'), ('op_In', 'In'),
    ('op_Equality', 'Equal'), ('op_Inequality', 'NotEqual'),
    ('op_GreaterThan', 'GreaterThan'), ('op_GreaterThanOrEqual', 'GreaterThanOrEqual'),
    ('op_LessThan', 'LessThan'), ('op_LessThanOrEqual', 'LessThanOrEqual'),
    ('op_Addition', 'Add'), ('op_Subtraction', 'Subtract'),
    ('op_Multiply', 'Multiply'), ('op_Division', 'Divide'),
    ('op_IntDivide', 'IntDivide'), ('op_Modulus', 'Modulus'),
    ('op_LeftShift', 'LeftShift'), ('op_RightShift', 'RightShift'),
    ('op_LogicalAnd', 'LogicalAnd'), ('op_LogicalOr', 'LogicalOr'),
    ('op_LogicalXor', 'LogicalXor'), ('op_BitwiseAnd', 'BitwiseAnd'),
    ('op_BitwiseOr', 'BitwiseOr'), ('op_ExclusiveOr', 'BitwiseXor'),
    ('op_Initialize', 'Initialize'), ('op_Finalize', 'Finalize'));
var
  LIdx: Integer;
  LKey: string;
begin
  LKey := AName;
  if (LKey <> '') and (LKey[1] = '&') then
    LKey := LKey.Substring(1);
  for LIdx := 0 to High(cMap) do
    if SameText(cMap[LIdx, 0], LKey) then
      Exit(cMap[LIdx, 1]);
  if SameText(LKey, 'op_Assign') then
    Exit('Assign');
  Result := LKey.Substring(3);
end;

{ Routines and parameters }

// The parameters of a header or a procedure type: `const A: T; var B; out C:
// T = default` from the arVal/arVar rows, `Self` and a constructor's flag
// argument skipped, an open array spelled `array of T` (`array of const`
// for TVarRec), a default value looked up through the binding row.
function TPasDcuPrinter.ParamsText(AList: TList<TPasDcuDecl>;
  const AOpen, AClose: string): string;
var
  LParam, LBind, LConst: TPasDcuDecl;
  LItems: TList<string>;
  LText, LTypeText: string;
  LType, LElem: TPasDcuType;
  LOpenArray: Boolean;
  LIdx: Integer;
begin
  Result := '';
  if AList = nil then
    Exit;
  LItems := TList<string>.Create;
  try
    for LIdx := 0 to AList.Count - 1 do
    begin
      LParam := AList[LIdx];
      if not (LParam.Tag in [$21, $22]) then
        Continue;
      if (LParam.Name = 'Self') or IsHidden(LParam.Name) then
        Continue;
      // The low three bits of a parameter's flags: 1 = const (by value or,
      // on a var-tagged row, by reference); other patterns are plain
      // passing modes. Bit $80 on a var-tagged row is `out`.
      if LParam.Tag = $22 then
      begin
        if (LParam.LocFlags and $80) <> 0 then
          LText := 'out '
        else if (LParam.LocFlags and $7) = lfParamConst then
          LText := 'const '
        else
          LText := 'var ';
      end
      else if (LParam.LocFlags and $7) = lfParamConst then
        LText := 'const '
      else
        LText := '';
      LText := LText + Esc(LParam.Name);
      if not IsVoid(LParam.TypeIdx) then
      begin
        LType := FUnit.TypeAt(LParam.TypeIdx);
        // An open array parameter is an unnamed array of unknown size whose
        // high bound travels in the hidden `.` argument that follows.
        LOpenArray := (LType <> nil) and (LType.Kind = tkArray) and
          IsHidden(LType.Name) and (LIdx + 1 < AList.Count) and
          (AList[LIdx + 1].Name = '.');
        if LOpenArray then
        begin
          LElem := FUnit.TypeAt(LType.ElemIdx);
          if (LElem <> nil) and (LElem.Kind = tkImport) and
             SameText(LElem.ImportName, 'TVarRec') then
            LTypeText := 'array of const'
          else
            LTypeText := 'array of ' + TypeRef(LType.ElemIdx);
        end
        else
          LTypeText := TypeRef(LParam.TypeIdx);
        LText := LText + ': ' + LTypeText;
        // A default value: the binding row names the parameter's slot.
        for LBind in AList do
          if (LBind.Kind = dkParamDefault) and (LBind.ArgSlot = LParam.Slot) then
          begin
            LConst := FUnit.AddrAt(LBind.ConstSlot);
            if (LConst <> nil) and (LConst.Kind = dkConst) then
              LText := LText + ' = ' + ConstValueText(LConst, LParam.TypeIdx);
            Break;
          end;
      end;
      LItems.Add(LText);
    end;
    if LItems.Count > 0 then
      Result := AOpen + string.Join('; ', LItems.ToArray) + AClose;
  finally
    LItems.Free;
  end;
end;

function TPasDcuPrinter.RoutineHead(const AWord, AName: string;
  AList: TList<TPasDcuDecl>; AResultIdx: Integer): string;
begin
  Result := AWord + ' ' + AName + ParamsText(AList);
  if (AWord = 'function') or (AWord = 'class function') then
    Result := Result + ': ' + TypeRef(AResultIdx);
  Result := Result + ';';
end;

// `procedure(A: Integer) of object`, `function: Boolean` - a procedure type
// with APrefix ('' or 'reference to ') in front.
function TPasDcuPrinter.ProcTypeText(AType: TPasDcuType; const APrefix: string): string;
var
  LWord: string;
begin
  if IsVoid(AType.ResultTypeIdx) then
    LWord := 'procedure'
  else
    LWord := 'function';
  Result := APrefix + LWord + ParamsText(AType.Members);
  if LWord = 'function' then
    Result := Result + ': ' + TypeRef(AType.ResultTypeIdx);
  if ((AType.ProcFlags and ptOfObject) <> 0) and (APrefix = '') then
    Result := Result + ' of object';
  if AType.CallKind <> dcRegister then
    Result := Result + ';' + CallKindWord(AType.CallKind).TrimRight([';']);
end;

procedure TPasDcuPrinter.PrintMethod(AMember: TPasDcuDecl; AOwner: TPasDcuType);
var
  LRoutine: TPasDcuDecl;
  LProcType: TPasDcuType;
  LWord, LName, LText, LGenerics: string;
  LArgs: TList<TPasDcuDecl>;
  LResultIdx: Integer;
  LCallKind: TPasDcuCallKind;
  LHasSelf, LIsOperator, LClassCtor: Boolean;
  LHints: string;
  LParam: TPasDcuDecl;
begin
  LName := AMember.BareName;
  if IsHidden(LName) then
    Exit;
  LRoutine := nil;
  LProcType := nil;
  LArgs := nil;
  LResultIdx := 0;
  LCallKind := dcRegister;
  LGenerics := '';
  if AOwner.Kind = tkInterface then
  begin
    LProcType := FUnit.TypeAt(AMember.Offset);
    if (LProcType <> nil) and (LProcType.Kind = tkProcType) then
    begin
      LArgs := LProcType.Members;
      LResultIdx := LProcType.ResultTypeIdx;
      LCallKind := LProcType.CallKind;
    end
    else
      LProcType := nil;
  end
  else
  begin
    LRoutine := FUnit.AddrAt(AMember.Offset);
    if (LRoutine <> nil) and (LRoutine.Kind = dkRoutine) then
    begin
      LArgs := LRoutine.Args;
      LResultIdx := LRoutine.ResultTypeIdx;
      LCallKind := LRoutine.CallKind;
      if (LRoutine.GenericParams <> nil) and (LRoutine.GenericParams.Count > 0) then
      begin
        for LParam in LRoutine.GenericParams do
          if (LParam.Kind = dkType) and not IsHidden(LParam.Name) then
          begin
            if LGenerics <> '' then
              LGenerics := LGenerics + ', ';
            LGenerics := LGenerics + Esc(LParam.Name);
          end;
        if LGenerics <> '' then
          LGenerics := '<' + LGenerics + '>';
      end;
    end
    else
      LRoutine := nil;
  end;
  LIsOperator := LName.StartsWith('&op_') or LName.StartsWith('op_');
  // A class constructor/destructor is stored as a class method whose name
  // ends in '@'; it has no parameters and no other directive.
  LClassCtor := LName.EndsWith('@');
  if LClassCtor then
  begin
    LName := LName.Substring(0, Length(LName) - 1);
    if (AMember.Kind = dkDestructor) or SameText(LName, 'Destroy') then
      Line('class destructor ' + LName + ';')
    else
      Line('class constructor ' + LName + ';');
    Exit;
  end;
  case AMember.Kind of
    dkConstructor: LWord := 'constructor';
    dkDestructor: LWord := 'destructor';
  else
    if LIsOperator then
      LWord := 'class operator'
    else if (LArgs = nil) and (LRoutine = nil) and (LProcType = nil) then
      LWord := 'procedure'
    else if IsVoid(LResultIdx) then
      LWord := 'procedure'
    else
      LWord := 'function';
  end;
  if LIsOperator then
    LName := OperatorName(LName);
  if AMember.IsClassMember and not LIsOperator then
    LWord := 'class ' + LWord;
  LText := LWord + ' ' + Esc(LName) + LGenerics + ParamsText(LArgs);
  if (LWord = 'function') or (LWord = 'class function') or LIsOperator then
  begin
    if not IsVoid(LResultIdx) then
      LText := LText + ': ' + TypeRef(LResultIdx);
  end;
  LText := LText + ';';
  if (LRoutine = nil) and (LProcType = nil) then
    Note('method %s.%s has no header in the file', [AOwner.Name, LName]);
  // Directives.
  if (LRoutine <> nil) and ((LRoutine.ProcFlags and pfOverload) <> 0) then
    LText := LText + ' overload;';
  if AOwner.Kind <> tkInterface then
  begin
    if (AMember.LocFlags and lfOverride) <> 0 then
      LText := LText + ' override;'
    else
      case AMember.LocFlags and lfMethodKind of
        lfVirtual: LText := LText + ' virtual;';
        lfDynamic: LText := LText + ' dynamic;';
        lfMessage: LText := LText + Format(' message %d;', [AMember.TypeIdx and $FFFF]);
      end;
    // A class method without Self is static (Delphi XE7+ stores it so).
    if AMember.IsClassMember and (LRoutine <> nil) and not LIsOperator then
    begin
      LHasSelf := (LRoutine.Args <> nil) and (LRoutine.Args.Count > 0) and
        (LRoutine.Args[0].Name = 'Self');
      if not LHasSelf then
        LText := LText + ' static;';
    end;
    if (LRoutine <> nil) and ((LRoutine.ProcFlags and pfInline) <> 0) then
      LText := LText + ' inline;';
  end
  else if AOwner.IsDispInterface and (AMember.IntfIdx >= 0) then
    LText := LText + Format(' dispid %d;', [AMember.IntfIdx]);
  LText := LText + CallKindWord(LCallKind);
  LHints := Modifiers(AMember);
  if (LHints = '') and (LRoutine <> nil) then
    LHints := Modifiers(LRoutine);
  if LHints <> '' then
    LText := LText + LHints + ';';
  Line(LText);
end;

procedure TPasDcuPrinter.PrintProperty(AMember: TPasDcuDecl; AOwner: TPasDcuType);
var
  LText, LRead, LWrite, LStored: string;
  LType: TPasDcuType;
  LIsArray: Boolean;
begin
  if IsHidden(AMember.Name) then
    Exit;
  LText := 'property ' + Esc(AMember.Name);
  if AMember.IsClassMember then
    LText := 'class ' + LText;
  // No type: a redeclaration of an inherited property (`property Foo;`).
  if AMember.TypeIdx = 0 then
  begin
    LText := LText + Modifiers(AMember) + ';';
    if (AMember.LocFlags and lfDefaultProp) <> 0 then
      LText := LText + ' default;';
    Line(LText);
    Exit;
  end;
  LType := FUnit.TypeAt(AMember.TypeIdx);
  // An array property is typed by an unnamed procedure type whose
  // parameters are the indexes and whose result is the property type.
  LIsArray := (LType <> nil) and (LType.Kind = tkProcType) and IsHidden(LType.Name);
  if LIsArray then
  begin
    LText := LText + ParamsText(LType.Members, '[', ']');
    LText := LText + ': ' + TypeRef(LType.ResultTypeIdx);
  end
  else
    LText := LText + ': ' + TypeRef(AMember.TypeIdx);
  if AMember.HasIndex then
    LText := LText + Format(' index %d', [AMember.IndexValue]);
  LRead := AccessorName(AMember.ReadSlot);
  LWrite := AccessorName(AMember.WriteSlot);
  LStored := AccessorName(AMember.StoredSlot);
  if LRead <> '' then
    LText := LText + ' read ' + LRead;
  if LWrite <> '' then
    LText := LText + ' write ' + LWrite;
  if (LRead = '') and (LWrite = '') then
  begin
    if (AMember.ReadSlot <> 0) or (AMember.WriteSlot <> 0) then
      LText := LText + ' read ' + Unresolved(Format('accessor of %s.%s',
        [AOwner.Name, AMember.Name]))
    else
      Note('property %s.%s has no accessor', [AOwner.Name, AMember.Name]);
  end;
  if LStored <> '' then
    LText := LText + ' stored ' + LStored;
  // A default value is stored for every property; only an ordinal or set
  // property can declare one.
  if AMember.HasDefault and not LIsArray and DefaultAllowed(LType) then
  begin
    if LType.Kind = tkSet then
    begin
      if AMember.DefaultValue = 0 then
        LText := LText + ' default []'
      else
        LText := LText + ' default ' + SetText(LType,
          TBytes.Create(Byte(AMember.DefaultValue), Byte(AMember.DefaultValue shr 8),
            Byte(AMember.DefaultValue shr 16), Byte(AMember.DefaultValue shr 24)));
    end
    else
      LText := LText + ' default ' + OrdinalText(AMember.TypeIdx, AMember.DefaultValue);
  end;
  LText := LText + Modifiers(AMember) + ';';
  if LIsArray and ((AMember.LocFlags and lfDefaultProp) <> 0) then
    LText := LText + ' default;';
  Line(LText);
end;

// Whether a property of this type may carry `default <value>`: an ordinal or
// a set, by definition here or by an imported name that is not one of the
// non-ordinal builtins.
function TPasDcuPrinter.DefaultAllowed(AType: TPasDcuType): Boolean;
const
  cNonOrdinal: array[0..18] of string = ('string', 'unicodestring',
    'ansistring', 'widestring', 'shortstring', 'rawbytestring', 'pointer',
    'tobject', 'tclass', 'iinterface', 'single', 'double', 'extended',
    'currency', 'comp', 'real', 'variant', 'olevariant', 'tdatetime');
var
  LName: string;
  LBase: TPasDcuType;
begin
  if AType = nil then
    Exit(False);
  case AType.Kind of
    tkRange, tkEnum, tkSet:
      Exit(True);
    tkImport:
      begin
        LName := LowerCase(AType.ImportName);
        // Interface (`IFoo`) and pointer (`PFoo`) types by their naming
        // convention: a capital I or P followed by another capital.
        Result := (LName <> '') and (IndexStr(LName, cNonOrdinal) < 0) and
          not ((Length(AType.ImportName) > 1) and
               CharInSet(AType.ImportName[1], ['I', 'P']) and
               CharInSet(AType.ImportName[2], ['A'..'Z']));
        Exit;
      end;
    tkGenericInst, tkGenericParam:
      begin
        LBase := FUnit.TypeAt(AType.BaseIdx);
        Exit((LBase <> nil) and (AType.Kind = tkGenericInst) and
          (LBase.Kind in [tkRange, tkEnum, tkSet]));
      end;
  end;
  Result := False;
end;

// A dispinterface property: `property Name[params]: T readonly dispid N;`,
// an array property typed by an unnamed procedure type like a class's.
procedure TPasDcuPrinter.PrintDispProperty(AMember: TPasDcuDecl);
var
  LText: string;
  LType: TPasDcuType;
begin
  LText := 'property ' + Esc(AMember.Name);
  LType := FUnit.TypeAt(AMember.TypeIdx);
  if (LType <> nil) and (LType.Kind = tkProcType) and IsHidden(LType.Name) then
    LText := LText + ParamsText(LType.Members, '[', ']') + ': ' +
      TypeRef(LType.ResultTypeIdx)
  else
    LText := LText + ': ' + TypeRef(AMember.TypeIdx);
  case AMember.IntfIdx and $6 of
    $2: LText := LText + ' readonly';
    $4: LText := LText + ' writeonly';
  end;
  Line(LText + Format(' dispid %d;', [AMember.Offset]));
end;

{ Types }

function TPasDcuPrinter.OwnsDefinition(ADecl: TPasDcuDecl; AType: TPasDcuType): Boolean;
var
  LOwner: TPasDcuDecl;
begin
  if FDefined.ContainsKey(AType.Index) then
    Exit(False);
  if AType.DeclSlot = ADecl.Slot then
    Exit(True);
  // The definition's own declaration is one that never prints (a nested
  // type's unit-level `Outer.Inner` row, a compiler name): the first visible
  // declaration naming it prints it.
  LOwner := FUnit.AddrAt(AType.DeclSlot);
  Result := (LOwner = nil) or (LOwner.Kind <> dkType) or IsHidden(LOwner.Name) or
    (LOwner.Name.IndexOf('.') >= 0) or not LOwner.IsInterfaceVisible;
end;

// The text after `Name = ` for a definition of this unit.
function TPasDcuPrinter.DefText(AType: TPasDcuType): string;
var
  LBase: TPasDcuType;
  LMembers: TList<TPasDcuDecl>;
  LIdx: Integer;
  LItems: TList<string>;
  LText: string;
  LNext: Int64;
begin
  case AType.Kind of
    tkRange:
      begin
        if (AType.BaseIdx = AType.Index) or (AType.BaseIdx = 0) then
          Exit(Format('%d..%d', [AType.Low, AType.High]));
        Exit(OrdinalText(AType.BaseIdx, AType.Low) + '..' +
          OrdinalText(AType.BaseIdx, AType.High));
      end;
    tkEnum:
      begin
        if not FEnumMembers.TryGetValue(AType.Index, LMembers) or (LMembers.Count = 0) then
          Exit(Format('%d..%d', [AType.Low, AType.High]));
        LItems := TList<string>.Create;
        try
          LNext := 0;
          for LIdx := 0 to LMembers.Count - 1 do
          begin
            LText := Esc(LMembers[LIdx].BareName);
            if LMembers[LIdx].ValueInt <> LNext then
              LText := LText + ' = ' + IntToStr(LMembers[LIdx].ValueInt);
            LNext := LMembers[LIdx].ValueInt + 1;
            LItems.Add(LText);
          end;
          Exit('(' + string.Join(', ', LItems.ToArray) + ')');
        finally
          LItems.Free;
        end;
      end;
    tkFloat:
      case AType.FloatKind of
        0: Exit('Real48');
        1: Exit('Single');
        2: Exit('Double');
        3: Exit('Extended');
        4: Exit('Comp');
      else
        Exit('Currency');
      end;
    tkPointer:
      begin
        if IsVoid(AType.BaseIdx) or (AType.BaseIdx = 0) then
          Exit('Pointer');
        Exit('^' + TypeRef(AType.BaseIdx));
      end;
    tkDynArray:
      begin
        LBase := FUnit.TypeAt(AType.BaseIdx);
        if (LBase <> nil) and (LBase.Kind = tkArray) then
          Exit('array of ' + TypeRef(LBase.ElemIdx));
        Exit('array of ' + TypeRef(AType.BaseIdx));
      end;
    tkArray:
      begin
        if AType.Size < 0 then
          Exit('array of ' + TypeRef(AType.ElemIdx));
        Exit('array[' + TypeRef(AType.IndexIdx) + '] of ' + TypeRef(AType.ElemIdx));
      end;
    tkSet:
      Exit('set of ' + TypeRef(AType.BaseIdx));
    tkShortString:
      begin
        if (AType.Size < 0) or (AType.Size = 256) then
          Exit('ShortString');
        Exit(Format('string[%d]', [AType.Size - 1]));
      end;
    tkString:
      case AType.Tag of
        $55: Exit('WideString');
        $5B: Exit('UnicodeString');
      else
        if AType.CodePage <> 0 then
          Exit(Format('type AnsiString(%d)', [AType.CodePage]));
        Exit('AnsiString');
      end;
    tkVariant:
      if AType.VariantFlag <> 0 then
        Exit('OleVariant')
      else
        Exit('Variant');
    tkClassRef:
      Exit('class of ' + TypeRef(AType.BaseIdx));
    tkText:
      Exit('Text');
    tkFile:
      begin
        if IsVoid(AType.BaseIdx) or (AType.BaseIdx = 0) then
          Exit('file');
        Exit('file of ' + TypeRef(AType.BaseIdx));
      end;
    tkProcType:
      Exit(ProcTypeText(AType, ''));
    tkGenericInst:
      Exit(InstRef(AType));
    tkGenericParam:
      begin
        if AType.Name <> '' then
          Exit(AType.Name);
        Exit('T');
      end;
    tkVoid:
      Exit('Pointer');
  end;
  Result := Unresolved(Format('definition of a %d type', [Ord(AType.Kind)]));
end;

// A class, record, object, interface or helper: head line, members, `end`.
procedure TPasDcuPrinter.PrintStructured(AType: TPasDcuType; const AHead: string);
var
  LHead, LWord, LParent, LGuid: string;
  LParentType, LHelped: TPasDcuType;
  LIdx: Integer;
  LInvoke: TPasDcuDecl;
  LProcType: TPasDcuType;
begin
  FPrinting.AddOrSetValue(AType.Index, True);
  try
    case AType.Kind of
      tkRecord:
        LHead := AHead + ' = record';
      tkObject:
        begin
          LHead := AHead + ' = object';
          if AType.ParentIdx <> 0 then
            LHead := LHead + '(' + TypeRef(AType.ParentIdx) + ')';
        end;
      tkClass:
        begin
          LHead := AHead + ' = class';
          LParent := '';
          if AType.ParentIdx <> 0 then
            LParent := TypeRef(AType.ParentIdx);
          for LIdx := 0 to High(AType.Interfaces) do
          begin
            if LParent <> '' then
              LParent := LParent + ', ';
            LParent := LParent + TypeRef(AType.Interfaces[LIdx]);
          end;
          if LParent <> '' then
            LHead := LHead + '(' + LParent + ')';
          // A class with no members of its own is complete on its head line.
          if (AType.Members = nil) or (AType.Members.Count = 0) then
          begin
            Line(LHead + ';');
            Exit;
          end;
        end;
      tkMetaClass:
        begin
          // The compiler stores a helper as a metaclass whose target is the
          // helped type; its parent is System's TClassHelperBase unless the
          // helper itself descends from another helper.
          LHelped := FUnit.TypeAt(AType.MetaClassIdx);
          if (LHelped <> nil) and (LHelped.Kind in [tkClass, tkMetaClass]) then
            LWord := 'class helper'
          else
            LWord := 'record helper';
          LParent := '';
          LParentType := FUnit.TypeAt(AType.ParentIdx);
          if (LParentType <> nil) and
             not ((LParentType.Kind = tkImport) and
                  SameText(LParentType.ImportName, 'TClassHelperBase')) then
            LParent := '(' + TypeRef(AType.ParentIdx) + ')';
          LHead := AHead + ' = ' + LWord + LParent + ' for ' +
            TypeRef(AType.MetaClassIdx);
        end;
      tkInterface:
        begin
          // An anonymous method type is stored as an interface with one
          // method, Invoke, and a flag bit.
          if (AType.IntfFlags and $80) <> 0 then
          begin
            LInvoke := nil;
            if AType.Members <> nil then
              for LIdx := 0 to AType.Members.Count - 1 do
                if (AType.Members[LIdx].Kind = dkMethod) and
                   SameText(AType.Members[LIdx].Name, 'Invoke') then
                begin
                  LInvoke := AType.Members[LIdx];
                  Break;
                end;
            if LInvoke <> nil then
            begin
              LProcType := FUnit.TypeAt(LInvoke.Offset);
              if (LProcType <> nil) and (LProcType.Kind = tkProcType) then
              begin
                Line(AHead + ' = ' + ProcTypeText(LProcType, 'reference to ') + ';');
                Exit;
              end;
            end;
            Note('anonymous method type %s has no Invoke', [AType.Name]);
          end;
          if AType.IsDispInterface then
            LHead := AHead + ' = dispinterface'
          else
          begin
            LHead := AHead + ' = interface';
            if AType.ParentIdx <> 0 then
              LHead := LHead + '(' + TypeRef(AType.ParentIdx) + ')';
          end;
        end;
    end;
    Line(LHead);
    if (AType.Kind = tkInterface) and (AType.Guid <> TGUID.Empty) then
    begin
      LGuid := GUIDToString(AType.Guid);
      Line(StringOfChar(' ', cIndentStep) + '[''' + LGuid + ''']');
    end;
    PrintMembers(AType);
    Line('end;');
  finally
    FPrinting.Remove(AType.Index);
  end;
end;

// Members in stored order, which is source order: visibility words where
// the visibility changes, `type`/`const`/`var` sub-blocks for nested types,
// constants and fields that follow them.
procedure TPasDcuPrinter.PrintMembers(AType: TPasDcuType);
type
  TSub = (subNone, subType, subConst, subVar);
var
  LMember, LActual: TPasDcuDecl;
  LVis: Integer;
  LSub: TSub;
  LIsIntf: Boolean;

  procedure Visibility(AMember: TPasDcuDecl);
  var
    LNew: Integer;
  begin
    if LIsIntf then
      Exit;
    case AMember.Visibility of
      lfPublic: LNew := 1;
      lfProtected: LNew := 2;
      lfPublished: LNew := 3;
    else
      LNew := 0;
    end;
    if LNew <> LVis then
    begin
      LVis := LNew;
      LSub := subNone;
      FIndent := FIndent - cIndentStep;
      Line(cVisibilityWords[LNew]);
      FIndent := FIndent + cIndentStep;
    end;
  end;

  procedure OpenPublic;
  begin
    if LIsIntf then
      Exit;
    LVis := 1;
    LSub := subNone;
    FIndent := FIndent - cIndentStep;
    Line('public');
    FIndent := FIndent + cIndentStep;
  end;

  procedure SubBlock(ASub: TSub);
  const
    cWords: array[TSub] of string = ('', 'type', 'const', 'var');
  begin
    if ASub = LSub then
      Exit;
    // Fields after methods or properties need no `var`; after a type or
    // const block they do.
    if (ASub = subVar) and (LSub = subNone) then
    begin
      LSub := ASub;
      Exit;
    end;
    LSub := ASub;
    if cWords[ASub] <> '' then
    begin
      FIndent := FIndent - cIndentStep;
      Line(cWords[ASub]);
      FIndent := FIndent + cIndentStep;
    end;
  end;

begin
  if AType.Members = nil then
    Exit;
  LIsIntf := AType.Kind = tkInterface;
  LVis := -1;
  LSub := subNone;
  FIndent := FIndent + 2 * cIndentStep;
  try
    for LMember in AType.Members do
    begin
      LActual := LMember;
      if LActual.Kind = dkCopy then
        LActual := LActual.Base;
      if LActual = nil then
        Continue;
      case LActual.Kind of
        dkType:
          begin
            if IsHidden(LActual.Name) or FConsumed.ContainsKey(LActual) then
              Continue;
            // Nested types and constants carry no visibility bits; they open
            // the body as public so a use from outside the class resolves.
            if LVis < 0 then
              OpenPublic;
            SubBlock(subType);
            PrintTypeDecl(LActual, True);
          end;
        dkConst:
          begin
            if IsHidden(LActual.Name) or FConsumed.ContainsKey(LActual) then
              Continue;
            if LVis < 0 then
              OpenPublic;
            SubBlock(subConst);
            PrintConst(LActual);
          end;
        dkField:
          begin
            if IsHidden(LActual.Name) then
              Continue;
            Visibility(LActual);
            SubBlock(subVar);
            Line(Esc(LActual.Name) + ': ' + TypeRef(LActual.TypeIdx) +
              Modifiers(LActual) + ';');
          end;
        dkClassVar:
          begin
            if IsHidden(LActual.Name) then
              Continue;
            Visibility(LActual);
            SubBlock(subNone);
            Line('class var ' + Esc(LActual.Name) + ': ' + TypeRef(LActual.TypeIdx) + ';');
          end;
        dkMethod, dkConstructor, dkDestructor:
          begin
            Visibility(LActual);
            SubBlock(subNone);
            PrintMethod(LActual, AType);
          end;
        dkProperty:
          begin
            Visibility(LActual);
            SubBlock(subNone);
            PrintProperty(LActual, AType);
          end;
        dkDispProperty:
          begin
            if IsHidden(LActual.Name) then
              Continue;
            SubBlock(subNone);
            PrintDispProperty(LActual);
          end;
      end;
    end;
  finally
    FIndent := FIndent - 2 * cIndentStep;
  end;
end;

procedure TPasDcuPrinter.PrintTypeDecl(ADecl: TPasDcuDecl; AInBody: Boolean);
var
  LType: TPasDcuType;
  LName, LHead: string;
begin
  LName := ADecl.Name;
  if not AInBody then
  begin
    // A nested type is printed inside its owner; the unit-level row is the
    // compiler's `Outer.Inner` spelling.
    if LName.IndexOf('.') >= 0 then
      Exit;
    Section(secType);
  end
  else
    LName := ADecl.BareName;
  LType := FUnit.TypeAt(ADecl.TypeIdx);
  if LType = nil then
  begin
    Line(Esc(StripArity(LName)) + ' = ' +
      Unresolved(Format('type %s names entry #%d, which does not exist',
        [LName, ADecl.TypeIdx])) + ';');
    Exit;
  end;
  LHead := GenericHead(Esc(StripArity(LName)), LType);
  if OwnsDefinition(ADecl, LType) then
  begin
    FDefined.AddOrSetValue(LType.Index, True);
    if LType.Kind in [tkRecord, tkObject, tkClass, tkMetaClass, tkInterface] then
      PrintStructured(LType, LHead)
    else if LType.Kind = tkImport then
      // `TFoo = type Other.TBar`: an imported definition under a new name.
      Line(LHead + ' = ' + ImportRef(LType) + ';')
    else
      Line(LHead + ' = ' + DefText(LType) + Modifiers(ADecl) + ';');
    FDeclared.AddOrSetValue(LType.Index, True);
  end
  else
    // An alias of a type that has its own declaration.
    Line(LHead + ' = ' + TypeRef(LType.Index) + Modifiers(ADecl) + ';');
end;

procedure TPasDcuPrinter.PrintConst(ADecl: TPasDcuDecl);
var
  LType: TPasDcuType;
  LText: string;
begin
  LType := FUnit.TypeAt(ADecl.TypeIdx);
  LText := ADecl.BareName;
  // A typed value (a set, a float, a string) keeps its type when the source
  // declared one; a scalar of an ordinal type is plain.
  if (LType <> nil) and (LType.Kind = tkSet) and (LType.Name <> '') and
     not IsHidden(LType.Name) then
    LText := LText + ': ' + TypeRef(ADecl.TypeIdx);
  Line(LText + ' = ' + ConstValueText(ADecl, ADecl.TypeIdx) + Modifiers(ADecl) + ';');
end;

procedure TPasDcuPrinter.PrintVar(ADecl: TPasDcuDecl; ASection: TSection);
var
  LText, LTypeText: string;
  LTarget: TPasDcuDecl;
begin
  Section(ASection);
  LTypeText := TypeRef(ADecl.TypeIdx);
  LText := Esc(ADecl.Name) + ': ' + LTypeText;
  if ADecl.Kind = dkAbsVar then
  begin
    LTarget := FUnit.AddrAt(ADecl.Offset);
    if (LTarget <> nil) and not IsHidden(LTarget.Name) then
      LText := LText + ' absolute ' + LTarget.BareName;
  end;
  // A variable of an inline procedural type cannot carry a hint directive:
  // dcc reads the word as a calling convention (E1030, probed 2026-09-17).
  if LTypeText.StartsWith('procedure') or LTypeText.StartsWith('function') then
    LText := LText + ';'
  else
    LText := LText + Modifiers(ADecl) + ';';
  if ADecl.Kind = dkTypedConst then
    LText := LText + ' { typed constant; the value is compiled data this reader does not decode }';
  Line(LText);
end;

procedure TPasDcuPrinter.PrintRoutine(ADecl: TPasDcuDecl);
var
  LWord, LText: string;
begin
  Section(secNone);
  if IsVoid(ADecl.ResultTypeIdx) then
    LWord := 'procedure'
  else
    LWord := 'function';
  LText := RoutineHead(LWord, Esc(ADecl.Name), ADecl.Args, ADecl.ResultTypeIdx);
  if (ADecl.ProcFlags and pfOverload) <> 0 then
    LText := LText + ' overload;';
  if (ADecl.ProcFlags and pfInline) <> 0 then
    LText := LText + ' inline;';
  LText := LText + CallKindWord(ADecl.CallKind);
  if Modifiers(ADecl) <> '' then
    LText := LText + Modifiers(ADecl) + ';';
  Line(LText);
end;

procedure TPasDcuPrinter.PrintTopDecl(ADecl: TPasDcuDecl);
begin
  case ADecl.Kind of
    dkType:
      if ADecl.IsInterfaceVisible and not IsHidden(ADecl.Name) then
        PrintTypeDecl(ADecl, False);
    dkConst:
      if ADecl.IsInterfaceVisible and not IsHidden(ADecl.Name) and
         not FConsumed.ContainsKey(ADecl) then
      begin
        Section(secConst);
        PrintConst(ADecl);
      end;
    dkResString:
      if ADecl.IsInterfaceVisible and not IsHidden(ADecl.Name) then
      begin
        Section(secResString);
        Line(ADecl.Name + ' = ''''; { the text is compiled data this reader does not decode }');
      end;
    // A dotted name is a class variable's storage (`TThread.FCurrentThread`),
    // printed inside its class.
    dkVar, dkAbsVar:
      if ADecl.IsInterfaceVisible and not IsHidden(ADecl.Name) and
         (ADecl.Name.IndexOf('.') < 0) then
        PrintVar(ADecl, secVar);
    dkThreadVar:
      if ADecl.IsInterfaceVisible and not IsHidden(ADecl.Name) and
         (ADecl.Name.IndexOf('.') < 0) then
        PrintVar(ADecl, secThreadVar);
    dkTypedConst:
      if ADecl.IsInterfaceVisible and not IsHidden(ADecl.Name) and
         (ADecl.Name.IndexOf('.') < 0) then
        PrintVar(ADecl, secVar);
    dkRoutine:
      // The unit's initialization and finalization parts are stored as
      // routines of those names; they are not declarations.
      // The unit's own entry (slot 1, named after the unit) is its
      // initialization code, not a declaration either.
      if ADecl.IsInterfaceVisible and (ADecl.ClassSlot = 0) and
         not ADecl.IsUnnamed and not IsHidden(ADecl.Name) and
         (ADecl.Name.IndexOf('.') < 0) and (ADecl.Slot <> 1) and
         not SameText(ADecl.Name, FUnit.UnitName) and
         not SameText(ADecl.Name, 'Initialization') and
         not SameText(ADecl.Name, 'Finalization') then
        PrintRoutine(ADecl);
  end;
end;

function TPasDcuPrinter.Print: string;
var
  LDecl: TPasDcuDecl;
  LPlatform, LNote: string;
  LHeaderEnd: Integer;
  LNotes: string;
  LType: TPasDcuType;
begin
  BuildNameSources;
  CollectEnumMembers;
  for LType in FUnit.Types do
    if (LType <> nil) and (LType.Kind = tkGenericInst) and (LType.InstFullIdx > 0) then
      FInstOfFull.TryAdd(LType.InstFullIdx, LType);
  if FUnit.Platform = dcuWin64 then
    LPlatform := 'Win64'
  else
    LPlatform := 'Win32';
  Line('unit ' + FUnit.UnitName + ';');
  Blank;
  Line('{ Interface section reconstructed by PasTree from');
  Line('  ' + FUnit.FileName);
  Line(Format('  (compiled by %s for %s). Declarations only: the values of typed',
    [DcuVersionName(FUnit.VersionByte), LPlatform]));
  Line('  constants and resource strings are compiled data this text does not');
  Line('  carry, and there is no implementation. Generated text, not a source file.');
  LHeaderEnd := FOut.Length;
  Line('}');
  Blank;
  Line('interface');
  PrintUses;
  FSection := secNone;
  for LDecl in FUnit.Decls do
    PrintTopDecl(LDecl);
  if FSection = secType then
    CloseTypeBlock;
  FIndent := 0;
  Blank;
  Line('implementation');
  Blank;
  Line('end.');
  if FUnresolved.Count > 0 then
  begin
    LNotes := '  What could not be reconstructed (' + IntToStr(FUnresolved.Count) +
      '):' + #13#10;
    // Braces would close the comment these lines sit in.
    for LNote in FUnresolved do
      LNotes := LNotes + '    ' + LNote.Replace('{', '[').Replace('}', ']') + #13#10;
    FOut.Insert(LHeaderEnd, LNotes);
  end;
  Result := FOut.ToString;
end;

end.
