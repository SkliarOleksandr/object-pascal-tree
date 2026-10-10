unit PasTree.Dfm;

{
  PasTree - FORM FILES (.dfm, .fmx), read for the positions a rename and a
  reference search need.

  A form file is the text the RTL streams a component tree from: `object
  Name: TClass`, `Property = Value` lines, nested objects, `end`. It matters
  to an analyzer because it NAMES Pascal symbols - published fields,
  published methods, classes - and binds to them at run time by name only
  (TReader: FieldAddress, MethodAddress, GetFieldClass). A rename that leaves
  the form file behind compiles cleanly and fails when the form is created.
  This unit reads the file; PasTree.Sema.Dfm binds its names to symbols.

  THE RTL'S OWN LEXER, NOT A NEW ONE. System.Classes.TParser is the lexer
  ObjectTextToBinary is built on, and it hands out every token with its byte
  position (SourcePos). The walk below is a copy of ObjectTextToBinary's
  ConvertObject / ConvertHeader / ConvertProperty / ConvertValue that RECORDS
  identifier positions where the original writes binary - so what counts as
  a form file here is exactly what the RTL (and so the IDE) accepts, strings
  with `#nnn`, hex data blocks and all. Keep it a copy: a "simplification"
  would be a second grammar able to disagree with the first.

  NO ROUND TRIP. ObjectTextToBinary + ObjectBinaryToText would regenerate the
  whole file: a form file that is not byte-canonical (edited by hand, saved by
  an older IDE) comes back as a whole-file diff for a one-word rename, and the
  positions a reference search needs are gone. A host edits the identifier
  bytes in place instead, exactly as it edits a .pas.

  A BINARY form file (resource format - first byte $FF - or a bare 'TPF0'
  stream) is converted to text in memory by the RTL's ObjectResourceToText /
  ObjectBinaryToText, so its names can still be LISTED. Its positions are
  those of the converted text, which is why IsBinary is recorded: such a file
  cannot be edited in place, and a rename that needs it refuses.

  Identifiers are kept as POSITIONS into Bytes, not as strings. A large
  project holds ~280k of them across ~1000 form files (measured on a real
  one, 2026-09-27), and each is interesting only when its spelling matches
  the one name being searched for - which FindIdents tests on the bytes.
}

interface

uses
  System.SysUtils,
  System.Classes;

type
  TPasDfmObjectKind = (dokObject, dokInherited, dokInline);

  // What an identifier IS in the form file's grammar.
  TPasDfmIdentRole = (
    dirObjectName,  // `object X: TC` - X
    dirClassName,   // `object X: TC` - TC (or the whole header of an unnamed object)
    dirPropName,    // one segment of a property name path, `Font.Name`
    dirValue,       // one segment of an identifier value, `A.B.C` or `alClient`
    dirSetItem);    // an identifier element of a set literal, `[akLeft]`

  TPasDfmIdent = record
    Offset: Integer;    // 0-based byte offset into TPasDfmDoc.Bytes
    ByteLen: Integer;
    Role: TPasDfmIdentRole;
    Obj: Integer;       // the object it belongs to (a property's: the object it is set on)
    Prop: Integer;      // its property (dirPropName / dirValue / dirSetItem); -1 otherwise
    Seg: Integer;       // 0-based segment index within its dotted path
    SegCount: Integer;  // segments in that path (1 for a plain identifier)
    InItem: Boolean;    // inside a collection item, `< item ... end >`
  end;

  TPasDfmObject = record
    Kind: TPasDfmObjectKind;
    Parent: Integer;     // index into Objects; -1 for the root
    NameIdent: Integer;  // index into Idents; -1 for an unnamed object
    ClassIdent: Integer; // index into Idents
  end;

  TPasDfmProp = record
    Obj: Integer;
    FirstIdent: Integer; // its first name segment, in Idents
    SegCount: Integer;
    InItem: Boolean;
    // Inside a collection item: the collection property (an index into
    // Props) and the item's 0-based position in it. -1 otherwise. Two items
    // setting the same event are two bindings, not one (ItemPath).
    Owner, Item: Integer;
    // A value that is ONE string token (`Caption = 'Button1'`, not a `+`
    // concatenation): the byte offset of that token - its opening quote or
    // `#`. -1 for any other value. What a rename needs to follow a caption
    // that reads a component's name (PasTree.Sema.Dfm, CarriedBy).
    StrOffset: Integer;
  end;

  // How the text is encoded: a UTF-8 BOM, or none (the RTL then reads ANSI -
  // what every IDE writes unless an identifier needs more).
  TPasDfmEncoding = (dfeAnsi, dfeUtf8);

  TPasDfmDoc = class;

  { A reference-counted handle: the cache replaces a doc when its file
    changes, and a caller still reading the old one keeps it alive. }
  IPasDfmDoc = interface
    ['{4E7C2A51-8B3D-4F0A-9C6E-2D5B1A7F3E90}']
    function Doc: TPasDfmDoc;
  end;

  { One form file, read. Immutable once built, so one instance can be shared
    by every reader of the cache. }
  TPasDfmDoc = class(TInterfacedObject, IPasDfmDoc)
  private
    FLineStarts: TArray<Integer>;
    function DecodeRange(AFrom, ACount: Integer): string;
  public
    Path: string;
    // The text as read - or, for a binary form file, as converted.
    Bytes: TBytes;
    Encoding: TPasDfmEncoding;
    BomLen: Integer;
    IsBinary: Boolean;
    // '' when the whole file was read. Otherwise why not, and Objects/Props/
    // Idents hold what was read before that point.
    Error: string;
    // The byte offset of the first token after the root object's `end`; 0
    // when nothing follows it (the root comes first, so no token after it
    // is at 0). dcc's form conversion reads one object and drops the rest,
    // so nothing there is bound at run time; it is not read here either
    // (TrailingLine, MentionsTrailing).
    TrailingOffset: Integer;
    Objects: TArray<TPasDfmObject>;
    Props: TArray<TPasDfmProp>;
    Idents: TArray<TPasDfmIdent>;
    function Doc: TPasDfmDoc;
    // The line TrailingOffset is on; 0 when nothing follows the root.
    function TrailingLine: Integer;
    // Whether the text after the root's `end` spells ANameLower as a word -
    // what "no form file names it" owes a reader who greps the file.
    function MentionsTrailing(const ANameLower: string): Boolean;
    // The identifier's text as written.
    function IdentText(AIdx: Integer): string;
    // Every identifier spelled ANameLower (case-insensitively - form files
    // are read by the RTL with SameText rules); ANameLower must be lower case.
    function FindIdents(const ANameLower: string): TArray<Integer>;
    // Whether ANameLower occurs anywhere in the bytes - the one question an
    // UNREADABLE file can still answer ("might it name this symbol?").
    function MentionsText(const ANameLower: string): Boolean;
    function LineOf(AOffset: Integer): Integer;          // 1-based
    function ColOf(AOffset: Integer): Integer;           // 1-based, characters
    function LineText(ALine: Integer): string;           // trailing blanks trimmed
    function ObjectName(AObj: Integer): string;          // '' for an unnamed object
    function ObjectClassName(AObj: Integer): string;
    function PropPath(AProp: Integer): string;           // `Font.Name`
    // PropPath with the collection items it sits in, from the object down:
    // `Items[2].OnPrintText`, `Columns[0].Items[1].Action`.
    function ItemPath(AProp: Integer): string;
    // Whether property AProp's value is exactly AText, written as ONE plain
    // quoted literal - `'Button1'`: no `#nnn`, no doubled quote, no `+` - so
    // that the bytes between the quotes ARE the text and can be rewritten in
    // place. AByteLen is their length. ACaseSensitive False compares as
    // SameText does.
    function StringValueIs(AProp: Integer; const AText: string;
      ACaseSensitive: Boolean; out AByteLen: Integer): Boolean;
    function DecodeBytes(AOffset, AByteLen: Integer): string;
    function RootName: string;
    function RootClassName: string;
  end;

{ The form file at APath, read and cached by path + size + last write time.
  nil when no such file exists. A file that exists but cannot be read, or is
  malformed, comes back as a doc with Error set - never nil - so a caller can
  tell "no form file" from "a form file whose names are unknown". Thread-safe. }
function PasDfmLoad(const APath: string): IPasDfmDoc;

{ Reads ABytes as the form file APath, bypassing the cache - for a host that
  holds a form's text in memory. }
function PasDfmParse(const APath: string; const ABytes: TBytes): IPasDfmDoc;

{ Drops APath from the cache ('' drops everything) - for a host that rewrote a
  file within the file system's timestamp resolution. }
procedure PasDfmForget(const APath: string = '');

{ The form file of the unit at AUnitPath - `.dfm` beside it, else `.fmx` - or
  '' when there is none. The `$R *.dfm` directive names the resource after the
  unit's FILE, which is what makes the sibling the one the unit links. }
function PasDfmFileOfUnit(const AUnitPath: string): string;

implementation

uses
{$IFDEF MSWINDOWS}
  Winapi.Windows,
{$ENDIF}
  System.IOUtils,
  System.Generics.Collections;

type
  // HexToBinary's output. The bytes of a `{...}` block (bitmaps, icons) are
  // of no interest here, and a large form holds megabytes of them.
  TNullStream = class(TStream)
  public
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

  { The walk - a copy of ObjectTextToBinary's (see the unit header), with
    Writer calls replaced by recording. }
  TPasDfmReader = class
  private
    FDoc: TPasDfmDoc;
    FParser: TParser;
    FSink: TNullStream;
    FObjects: TArray<TPasDfmObject>;
    FObjCount: Integer;
    FProps: TArray<TPasDfmProp>;
    FPropCount: Integer;
    FIdents: TArray<TPasDfmIdent>;
    FIdentCount: Integer;
    function ByteLenOf(const AText: string): Integer;
    function AddIdent(AOffset: Integer; const AText: string;
      ARole: TPasDfmIdentRole; AObj, AProp, ASeg, ASegCount: Integer;
      AInItem: Boolean): Integer;
    procedure AddPath(AOffset: Integer; const AText: string;
      ARole: TPasDfmIdentRole; AObj, AProp: Integer; AInItem: Boolean);
    function AddObject(const AObj: TPasDfmObject): Integer;
    procedure SkipOrderModifier;
    procedure ReadObject(AParent: Integer);
    procedure ReadProperty(AObj: Integer; AInItem: Boolean;
      AOwner: Integer = -1; AItem: Integer = -1);
    procedure ReadValue(AObj, AProp: Integer; AInItem, ATop: Boolean);
  public
    procedure Run(ADoc: TPasDfmDoc);
  end;

  TPasDfmCacheEntry = record
    Size: Int64;
    Stamp: Int64;   // see FileStamp
    Doc: IPasDfmDoc;
  end;

var
  GCacheLock: TObject;
  GCache: TDictionary<string, TPasDfmCacheEntry>;
  // Bumped by every PasDfmForget, under GCacheLock: a load that read its file
  // before a Forget does not cache what it read (see PasDfmLoad).
  GForgetGen: Int64;

{ TNullStream }

function TNullStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;
end;

function TNullStream.Write(const Buffer; Count: Longint): Longint;
begin
  Result := Count;
end;

function TNullStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := 0;
end;

{ TPasDfmReader }

// Bytes of AText in the file. Without a BOM the RTL's TParser takes letters
// for identifiers only from ASCII (its CharType goes to Unicode categories
// for UTF-8 alone), so an ANSI file's identifiers are ASCII and one byte per
// character.
function TPasDfmReader.ByteLenOf(const AText: string): Integer;
begin
  if FDoc.Encoding = dfeUtf8 then
    Result := TEncoding.UTF8.GetByteCount(AText)
  else
    Result := Length(AText);
end;

function TPasDfmReader.AddIdent(AOffset: Integer; const AText: string;
  ARole: TPasDfmIdentRole; AObj, AProp, ASeg, ASegCount: Integer;
  AInItem: Boolean): Integer;
begin
  if FIdentCount = Length(FIdents) then
    SetLength(FIdents, 64 + 2 * Length(FIdents));
  Result := FIdentCount;
  FIdents[Result].Offset := AOffset;
  FIdents[Result].ByteLen := ByteLenOf(AText);
  FIdents[Result].Role := ARole;
  FIdents[Result].Obj := AObj;
  FIdents[Result].Prop := AProp;
  FIdents[Result].Seg := ASeg;
  FIdents[Result].SegCount := ASegCount;
  FIdents[Result].InItem := AInItem;
  Inc(FIdentCount);
end;

// A dotted identifier value - TParser.TokenComponentIdent reads `A.B.C` as
// ONE token - recorded as one identifier per segment, each at its own byte.
procedure TPasDfmReader.AddPath(AOffset: Integer; const AText: string;
  ARole: TPasDfmIdentRole; AObj, AProp: Integer; AInItem: Boolean);
var
  LParts: TArray<string>;
  LOffset, LSeg: Integer;
begin
  LParts := AText.Split(['.']);
  LOffset := AOffset;
  for LSeg := 0 to High(LParts) do
  begin
    AddIdent(LOffset, LParts[LSeg], ARole, AObj, AProp, LSeg, Length(LParts),
      AInItem);
    Inc(LOffset, ByteLenOf(LParts[LSeg]) + 1);
  end;
end;

function TPasDfmReader.AddObject(const AObj: TPasDfmObject): Integer;
begin
  if FObjCount = Length(FObjects) then
    SetLength(FObjects, 16 + 2 * Length(FObjects));
  Result := FObjCount;
  FObjects[Result] := AObj;
  Inc(FObjCount);
end;

// ConvertOrderModifier: the `[n]` child position after a header or `item`.
procedure TPasDfmReader.SkipOrderModifier;
begin
  if FParser.Token = '[' then
  begin
    FParser.NextToken;
    FParser.CheckToken(toInteger);
    FParser.NextToken;
    FParser.CheckToken(']');
    FParser.NextToken;
  end;
end;

// ConvertObject + ConvertHeader.
procedure TPasDfmReader.ReadObject(AParent: Integer);
var
  LObj: TPasDfmObject;
  LIdx, LFirstOffset: Integer;
  LFirst: string;
begin
  LObj.Parent := AParent;
  LObj.NameIdent := -1;
  if FParser.TokenSymbolIs('INHERITED') then
    LObj.Kind := dokInherited
  else if FParser.TokenSymbolIs('INLINE') then
    LObj.Kind := dokInline
  else
  begin
    FParser.CheckTokenSymbol('OBJECT');
    LObj.Kind := dokObject;
  end;
  FParser.NextToken;
  // The index this object is about to get - its identifiers point to it.
  LIdx := FObjCount;
  FParser.CheckToken(toSymbol);
  LFirst := FParser.TokenString;
  LFirstOffset := FParser.SourcePos;
  if FParser.NextToken = ':' then
  begin
    FParser.NextToken;
    FParser.CheckToken(toSymbol);
    LObj.NameIdent := AddIdent(LFirstOffset, LFirst, dirObjectName, LIdx, -1,
      0, 1, False);
    LObj.ClassIdent := AddIdent(FParser.SourcePos, FParser.TokenString,
      dirClassName, LIdx, -1, 0, 1, False);
    // Stored once its idents are: a raise in what follows (the order
    // modifier, `[x]` mid-typing) must not leave idents naming an object
    // the doc never got - a consumer indexed Objects past its end.
    AddObject(LObj);
    FParser.NextToken;
  end
  else
  begin
    LObj.ClassIdent := AddIdent(LFirstOffset, LFirst, dirClassName, LIdx, -1,
      0, 1, False);
    AddObject(LObj);
  end;
  SkipOrderModifier;
  while not FParser.TokenSymbolIs('END') and
    not FParser.TokenSymbolIs('OBJECT') and
    not FParser.TokenSymbolIs('INHERITED') and
    not FParser.TokenSymbolIs('INLINE') do
    ReadProperty(LIdx, False);
  while not FParser.TokenSymbolIs('END') do
    ReadObject(LIdx);
  FParser.NextToken;
end;

// ConvertProperty.
procedure TPasDfmReader.ReadProperty(AObj: Integer; AInItem: Boolean;
  AOwner: Integer = -1; AItem: Integer = -1);
var
  LProp: TPasDfmProp;
  LIdx, LSeg: Integer;
begin
  FParser.CheckToken(toSymbol);
  LIdx := FPropCount;
  LProp.Obj := AObj;
  LProp.InItem := AInItem;
  LProp.Owner := AOwner;
  LProp.Item := AItem;
  LProp.FirstIdent := FIdentCount;
  LProp.SegCount := 0;
  LProp.StrOffset := -1;
  // Stored before its path is read, and kept consistent after each segment:
  // a path cut after a dot (`Font.` mid-typing) raises, and the segments
  // read so far must name a property the doc holds.
  if FPropCount = Length(FProps) then
    SetLength(FProps, 64 + 2 * Length(FProps));
  FProps[LIdx] := LProp;
  Inc(FPropCount);
  while True do
  begin
    AddIdent(FParser.SourcePos, FParser.TokenString, dirPropName, AObj, LIdx,
      FProps[LIdx].SegCount, 0, AInItem);
    Inc(FProps[LIdx].SegCount);
    for LSeg := LProp.FirstIdent to FIdentCount - 1 do
      FIdents[LSeg].SegCount := FProps[LIdx].SegCount;
    FParser.NextToken;
    if FParser.Token <> '.' then
      Break;
    FParser.NextToken;
    FParser.CheckToken(toSymbol);
  end;
  FParser.CheckToken('=');
  FParser.NextToken;
  ReadValue(AObj, LIdx, AInItem, True);
end;

// ConvertValue. A string (CombineString) leaves the token AFTER it current
// and skips the final NextToken - in the RTL as here. ATop is the property's
// own value, as opposed to an element of a `( ... )` list.
procedure TPasDfmReader.ReadValue(AObj, AProp: Integer; AInItem, ATop: Boolean);
var
  LOffset, LItem: Integer;
  LSingle: Boolean;
begin
  if CharInSet(FParser.Token, [System.Classes.toString, toWString]) then
  begin
    LOffset := FParser.SourcePos;
    LSingle := True;
    while FParser.NextToken = '+' do
    begin
      LSingle := False;
      FParser.NextToken;
      if not CharInSet(FParser.Token, [System.Classes.toString, toWString]) then
        FParser.CheckToken(System.Classes.toString);
    end;
    // No property was added since this one (a string value has no nested
    // items), so the index still addresses it.
    if ATop and LSingle then
      FProps[AProp].StrOffset := LOffset;
    Exit;
  end;
  case FParser.Token of
    toSymbol:
      begin
        LOffset := FParser.SourcePos;
        AddPath(LOffset, FParser.TokenComponentIdent, dirValue, AObj, AProp,
          AInItem);
      end;
    toInteger, toFloat:
      ;
    '[':
      begin
        FParser.NextToken;
        if FParser.Token <> ']' then
          while True do
          begin
            if not CharInSet(FParser.Token,
              [toInteger, System.Classes.toString, toWString]) then
            begin
              FParser.CheckToken(toSymbol);
              AddIdent(FParser.SourcePos, FParser.TokenString, dirSetItem,
                AObj, AProp, 0, 1, AInItem);
            end;
            if FParser.NextToken = ']' then
              Break;
            FParser.CheckToken(',');
            FParser.NextToken;
          end;
      end;
    '(':
      begin
        FParser.NextToken;
        while FParser.Token <> ')' do
          ReadValue(AObj, AProp, AInItem, False);
      end;
    '{':
      FParser.HexToBinary(FSink);
    '<':
      begin
        FParser.NextToken;
        LItem := 0;
        while FParser.Token <> '>' do
        begin
          FParser.CheckTokenSymbol('item');
          FParser.NextToken;
          SkipOrderModifier;
          while not FParser.TokenSymbolIs('end') do
            ReadProperty(AObj, True, AProp, LItem);
          FParser.NextToken;
          Inc(LItem);
        end;
      end;
  else
    FParser.ErrorStr('Invalid property value');
  end;
  FParser.NextToken;
end;

procedure TPasDfmReader.Run(ADoc: TPasDfmDoc);
var
  LStream: TBytesStream;
begin
  FDoc := ADoc;
  FSink := TNullStream.Create;
  LStream := TBytesStream.Create(ADoc.Bytes);
  try
    try
      FParser := TParser.Create(LStream);
      try
        ReadObject(-1);
        // dcc's conversion reads ONE object and ignores the rest: text after
        // the root's `end` - a stray `end` closing it early - never reaches
        // the executable, and whatever it binds is not bound.
        if FParser.Token <> toEOF then
          ADoc.TrailingOffset := FParser.SourcePos;
      finally
        FreeAndNil(FParser);
      end;
    except
      on E: Exception do
        ADoc.Error := E.Message;
    end;
  finally
    LStream.Free;
    FSink.Free;
  end;
  SetLength(FObjects, FObjCount);
  SetLength(FProps, FPropCount);
  SetLength(FIdents, FIdentCount);
  ADoc.Objects := FObjects;
  ADoc.Props := FProps;
  ADoc.Idents := FIdents;
end;

{ TPasDfmDoc }

function TPasDfmDoc.Doc: TPasDfmDoc;
begin
  Result := Self;
end;

function TPasDfmDoc.DecodeRange(AFrom, ACount: Integer): string;
begin
  if ACount <= 0 then
    Exit('');
  if Encoding = dfeUtf8 then
    Result := TEncoding.UTF8.GetString(Bytes, AFrom, ACount)
  else
    Result := TEncoding.ANSI.GetString(Bytes, AFrom, ACount);
end;

function TPasDfmDoc.IdentText(AIdx: Integer): string;
begin
  Result := DecodeRange(Idents[AIdx].Offset, Idents[AIdx].ByteLen);
end;

function TPasDfmDoc.FindIdents(const ANameLower: string): TArray<Integer>;
var
  LList: TList<Integer>;
  LIdx, LChar, LLen: Integer;
  LAscii, LSame: Boolean;
  LByte: Byte;
begin
  Result := nil;
  LLen := Length(ANameLower);
  if LLen = 0 then
    Exit;
  LAscii := True;
  for LChar := 1 to LLen do
    if Ord(ANameLower[LChar]) > 127 then
    begin
      LAscii := False;
      Break;
    end;
  LList := TList<Integer>.Create;
  try
    for LIdx := 0 to High(Idents) do
    begin
      if LAscii then
      begin
        if Idents[LIdx].ByteLen <> LLen then
          Continue;
        LSame := True;
        for LChar := 0 to LLen - 1 do
        begin
          LByte := Bytes[Idents[LIdx].Offset + LChar];
          if (LByte >= Ord('A')) and (LByte <= Ord('Z')) then
            Inc(LByte, 32);
          if LByte <> Ord(ANameLower[LChar + 1]) then
          begin
            LSame := False;
            Break;
          end;
        end;
      end
      else
        LSame := AnsiSameText(IdentText(LIdx), ANameLower);
      if LSame then
        LList.Add(LIdx);
    end;
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

function TPasDfmDoc.MentionsText(const ANameLower: string): Boolean;
begin
  Result := Pos(ANameLower, LowerCase(DecodeRange(BomLen,
    Length(Bytes) - BomLen))) > 0;
end;

function TPasDfmDoc.TrailingLine: Integer;
begin
  if TrailingOffset <= 0 then
    Exit(0);
  Result := LineOf(TrailingOffset);
end;

function TPasDfmDoc.MentionsTrailing(const ANameLower: string): Boolean;
var
  LText: string;
  LAt: Integer;
begin
  Result := False;
  if (TrailingOffset <= 0) or (ANameLower = '') then
    Exit;
  LText := LowerCase(DecodeRange(TrailingOffset, Length(Bytes) -
    TrailingOffset));
  LAt := Pos(ANameLower, LText);
  while LAt > 0 do
  begin
    // A whole word: `OnClick = SaveClick` names SaveClick, not Save.
    if ((LAt = 1) or not CharInSet(LText[LAt - 1], ['a'..'z', '0'..'9', '_']))
       and ((LAt + Length(ANameLower) > Length(LText)) or
       not CharInSet(LText[LAt + Length(ANameLower)], ['a'..'z', '0'..'9',
       '_'])) then
      Exit(True);
    LAt := Pos(ANameLower, LText, LAt + 1);
  end;
end;

function TPasDfmDoc.LineOf(AOffset: Integer): Integer;
var
  LLo, LHi, LMid: Integer;
begin
  LLo := 0;
  LHi := High(FLineStarts);
  while LLo < LHi do
  begin
    LMid := (LLo + LHi + 1) div 2;
    if FLineStarts[LMid] <= AOffset then
      LLo := LMid
    else
      LHi := LMid - 1;
  end;
  Result := LLo + 1;
end;

function TPasDfmDoc.ColOf(AOffset: Integer): Integer;
var
  LStart: Integer;
begin
  LStart := FLineStarts[LineOf(AOffset) - 1];
  if LStart = 0 then
    LStart := BomLen;
  Result := Length(DecodeRange(LStart, AOffset - LStart)) + 1;
end;

function TPasDfmDoc.LineText(ALine: Integer): string;
var
  LStart, LEnd: Integer;
begin
  if (ALine < 1) or (ALine > Length(FLineStarts)) then
    Exit('');
  LStart := FLineStarts[ALine - 1];
  if LStart = 0 then
    LStart := BomLen;
  if ALine < Length(FLineStarts) then
    LEnd := FLineStarts[ALine]
  else
    LEnd := Length(Bytes);
  Result := TrimRight(DecodeRange(LStart, LEnd - LStart));
end;

function TPasDfmDoc.ObjectName(AObj: Integer): string;
begin
  if (AObj < 0) or (AObj > High(Objects)) or (Objects[AObj].NameIdent < 0) then
    Exit('');
  Result := IdentText(Objects[AObj].NameIdent);
end;

function TPasDfmDoc.ObjectClassName(AObj: Integer): string;
begin
  if (AObj < 0) or (AObj > High(Objects)) then
    Exit('');
  Result := IdentText(Objects[AObj].ClassIdent);
end;

function TPasDfmDoc.PropPath(AProp: Integer): string;
var
  LSeg: Integer;
begin
  Result := '';
  if (AProp < 0) or (AProp > High(Props)) then
    Exit;
  for LSeg := 0 to Props[AProp].SegCount - 1 do
  begin
    if LSeg > 0 then
      Result := Result + '.';
    Result := Result + IdentText(Props[AProp].FirstIdent + LSeg);
  end;
end;

function TPasDfmDoc.ItemPath(AProp: Integer): string;
var
  LDepth: Integer;
begin
  Result := PropPath(AProp);
  LDepth := 0;
  while (AProp >= 0) and (AProp <= High(Props)) and (Props[AProp].Owner >= 0)
    and (LDepth < 64) do
  begin
    Result := Format('%s[%d].%s', [PropPath(Props[AProp].Owner),
      Props[AProp].Item, Result]);
    AProp := Props[AProp].Owner;
    Inc(LDepth);
  end;
end;

function TPasDfmDoc.StringValueIs(AProp: Integer; const AText: string;
  ACaseSensitive: Boolean; out AByteLen: Integer): Boolean;
var
  LOff: Integer;
  LText: string;
begin
  Result := False;
  AByteLen := 0;
  if (AProp < 0) or (AProp > High(Props)) or (AText = '') then
    Exit;
  LOff := Props[AProp].StrOffset;
  if (LOff < 0) or (LOff >= Length(Bytes)) or (Bytes[LOff] <> Ord('''')) then
    Exit;
  if Encoding = dfeUtf8 then
    AByteLen := TEncoding.UTF8.GetByteCount(AText)
  else
    AByteLen := TEncoding.ANSI.GetByteCount(AText);
  // The closing quote right after the text, and nothing that would make the
  // token go on: TParser reads `'a'#13'b'` and `'a''b'` as ONE string.
  if (LOff + 1 + AByteLen >= Length(Bytes)) or
     (Bytes[LOff + 1 + AByteLen] <> Ord('''')) then
    Exit;
  if (LOff + 2 + AByteLen < Length(Bytes)) and
     ((Bytes[LOff + 2 + AByteLen] = Ord('''')) or
      (Bytes[LOff + 2 + AByteLen] = Ord('#'))) then
    Exit;
  LText := DecodeRange(LOff + 1, AByteLen);
  if ACaseSensitive then
    Result := LText = AText
  else
    Result := AnsiSameText(LText, AText);
end;

function TPasDfmDoc.DecodeBytes(AOffset, AByteLen: Integer): string;
begin
  Result := DecodeRange(AOffset, AByteLen);
end;

function TPasDfmDoc.RootName: string;
begin
  Result := ObjectName(0);
end;

function TPasDfmDoc.RootClassName: string;
begin
  Result := ObjectClassName(0);
end;

{ Reading }

// TestStreamFormat's binary test: the resource format opens with $FF, a bare
// object stream with the 'TPF0' signature (and a zero first word is binary to
// the RTL as well).
function LooksBinary(const ABytes: TBytes): Boolean;
begin
  Result := (Length(ABytes) >= 1) and (ABytes[0] = $FF);
  if not Result and (Length(ABytes) >= 4) then
    Result := ((ABytes[0] = Ord('T')) and (ABytes[1] = Ord('P')) and
      (ABytes[2] = Ord('F')) and (ABytes[3] = Ord('0'))) or
      ((ABytes[0] = 0) and (ABytes[1] = 0) and (ABytes[2] = 0) and
      (ABytes[3] = 0));
end;

function BinaryToText(const ABytes: TBytes; out AText: TBytes;
  out AError: string): Boolean;
var
  LIn: TBytesStream;
  LOut: TBytesStream;
begin
  Result := False;
  AError := '';
  LIn := TBytesStream.Create(ABytes);
  LOut := TBytesStream.Create;
  try
    try
      if ABytes[0] = $FF then
        ObjectResourceToText(LIn, LOut)
      else
        ObjectBinaryToText(LIn, LOut);
      AText := Copy(LOut.Bytes, 0, LOut.Size);
      Result := True;
    except
      on E: Exception do
        AError := 'binary form file: ' + E.Message;
    end;
  finally
    LOut.Free;
    LIn.Free;
  end;
end;

function PasDfmParse(const APath: string; const ABytes: TBytes): IPasDfmDoc;
var
  LDoc: TPasDfmDoc;
  LReader: TPasDfmReader;
  LText: TBytes;
  LError: string;
  LIdx, LCount: Integer;
begin
  LDoc := TPasDfmDoc.Create;
  Result := LDoc;
  LDoc.Path := APath;
  LDoc.Bytes := ABytes;
  if LooksBinary(ABytes) then
  begin
    LDoc.IsBinary := True;
    if not BinaryToText(ABytes, LText, LError) then
    begin
      LDoc.Bytes := nil;
      LDoc.Error := LError;
      LDoc.FLineStarts := [0];
      Exit;
    end;
    LDoc.Bytes := LText;
  end;
  if (Length(LDoc.Bytes) >= 3) and (LDoc.Bytes[0] = $EF) and
     (LDoc.Bytes[1] = $BB) and (LDoc.Bytes[2] = $BF) then
  begin
    LDoc.Encoding := dfeUtf8;
    LDoc.BomLen := 3;
  end;
  LCount := 1;
  for LIdx := 0 to High(LDoc.Bytes) do
    if LDoc.Bytes[LIdx] = 10 then
      Inc(LCount);
  SetLength(LDoc.FLineStarts, LCount);
  LDoc.FLineStarts[0] := 0;
  LCount := 1;
  for LIdx := 0 to High(LDoc.Bytes) do
    if LDoc.Bytes[LIdx] = 10 then
    begin
      LDoc.FLineStarts[LCount] := LIdx + 1;
      Inc(LCount);
    end;
  LReader := TPasDfmReader.Create;
  try
    LReader.Run(LDoc);
  finally
    LReader.Free;
  end;
end;

{ Size and last write time in ONE file system call. The cache asks this of
  every form file of a project on every search, and the three separate calls
  it started with (Exists, GetSize, GetLastWriteTimeUtc) cost 120 ms on
  ~1000 files - more than finding the names in all of them. }
function FileStamp(const APath: string; out ASize, AStamp: Int64): Boolean;
{$IFDEF MSWINDOWS}
var
  LData: TWin32FileAttributeData;
begin
  Result := GetFileAttributesEx(PChar(APath), GetFileExInfoStandard, @LData) and
    (LData.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY = 0);
  if Result then
  begin
    ASize := (Int64(LData.nFileSizeHigh) shl 32) or LData.nFileSizeLow;
    AStamp := (Int64(LData.ftLastWriteTime.dwHighDateTime) shl 32) or
      LData.ftLastWriteTime.dwLowDateTime;
  end;
end;
{$ELSE}
begin
  Result := TFile.Exists(APath);
  if Result then
  begin
    ASize := TFile.GetSize(APath);
    AStamp := Trunc(TFile.GetLastWriteTimeUtc(APath) * 86400000.0);
  end;
end;
{$ENDIF}

function PasDfmLoad(const APath: string): IPasDfmDoc;
var
  LKey: string;
  LEntry: TPasDfmCacheEntry;
  LSize, LStamp: Int64;
  LBytes: TBytes;
  LDoc: TPasDfmDoc;
  LGen: Int64;
begin
  Result := nil;
  if (APath = '') or not FileStamp(APath, LSize, LStamp) then
    Exit;
  LKey := AnsiLowerCase(TPath.GetFullPath(APath));
  TMonitor.Enter(GCacheLock);
  try
    if GCache.TryGetValue(LKey, LEntry) and (LEntry.Size = LSize) and
       (LEntry.Stamp = LStamp) then
      Exit(LEntry.Doc);
    LGen := GForgetGen;
  finally
    TMonitor.Exit(GCacheLock);
  end;
  try
    LBytes := TFile.ReadAllBytes(APath);
  except
    on E: Exception do
    begin
      LDoc := TPasDfmDoc.Create;
      Result := LDoc;
      LDoc.Path := APath;
      LDoc.Error := 'could not be read: ' + E.Message;
      LDoc.FLineStarts := [0];
      Exit;   // not cached: the next call tries again
    end;
  end;
  Result := PasDfmParse(APath, LBytes);
  // The read and the parse ran unlocked, so the cache may have moved since
  // the lookup. A Forget in between: the file may have been rewritten within
  // the stamp's resolution (what Forget is for), so what was read is not
  // cached - it is still this call's answer. Another load of the same file
  // version in between: its doc stays and is returned, so every caller holds
  // the same one (a binder that sees a different doc rebuilds its forms).
  TMonitor.Enter(GCacheLock);
  try
    if GForgetGen <> LGen then
      Exit;
    if GCache.TryGetValue(LKey, LEntry) and (LEntry.Size = LSize) and
       (LEntry.Stamp = LStamp) then
      Exit(LEntry.Doc);
    LEntry.Size := LSize;
    LEntry.Stamp := LStamp;
    LEntry.Doc := Result;
    GCache.AddOrSetValue(LKey, LEntry);
  finally
    TMonitor.Exit(GCacheLock);
  end;
end;

procedure PasDfmForget(const APath: string);
begin
  TMonitor.Enter(GCacheLock);
  try
    Inc(GForgetGen);
    if APath = '' then
      GCache.Clear
    else
      GCache.Remove(AnsiLowerCase(TPath.GetFullPath(APath)));
  finally
    TMonitor.Exit(GCacheLock);
  end;
end;

function PasDfmFileOfUnit(const AUnitPath: string): string;
begin
  Result := '';
  if AUnitPath = '' then
    Exit;
  Result := ChangeFileExt(AUnitPath, '.dfm');
  if TFile.Exists(Result) then
    Exit;
  Result := ChangeFileExt(AUnitPath, '.fmx');
  if TFile.Exists(Result) then
    Exit;
  Result := '';
end;

initialization
  GCacheLock := TObject.Create;
  GCache := TDictionary<string, TPasDfmCacheEntry>.Create;

finalization
  FreeAndNil(GCache);
  FreeAndNil(GCacheLock);

end.
