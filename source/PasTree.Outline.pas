unit PasTree.Outline;

{
  PasTree - the outline of one module, in source order.

  Every declaration a parsed module makes (types, their members, variables,
  constants, properties, routine headers AND routine bodies), plus the
  structural landmarks a reader steers by (the module header, `interface`,
  `implementation`, `uses`), as a flat list in the order they appear in the
  source. This is what a "Go To" picker or an LSP documentSymbol response
  lists. The PROJECT-wide counterpart, one list over every unit's retained
  symbol table, is TPasNavigator.ProjectOutline (PasTree.Sema.Nav); it
  returns the same record so a picker draws both with one row painter.

  AST ONLY, no semantics. The walk reads the parse tree and nothing else, so
  it works on a module the resolver has not seen yet, on a module with parse
  errors (the error-tolerant parser still yields the declarations around a
  damaged one), and on a module that is being typed. The price is that a
  declaration behind an inactive `$IFDEF` is absent - the preprocessor never
  handed it to the parser - and that a method's declaration and its body are
  TWO entries, paired by nothing more than their names; the semantic pairing
  is TPasNavigator.GotoImplementation's job.

  What is deliberately NOT listed: enumeration values (a 200-member enum
  would drown the list they sit in), routine-local declarations and nested
  routines (they belong to the body, and the body is one entry), parameters.

  Positions are file/line/col of the declared NAME, in whichever file the
  name sits - a declaration that arrived through an $I include reports that
  file, the same way TPasNavigator's targets do.
}

interface

uses
  System.SysUtils,
  PasTree.Types,
  PasTree.Preprocessor,
  PasTree.Ast;

type
  { okModule: the `unit`/`program`/`library`/`package` header.
    okSection: `interface`, `implementation`, `initialization`,
      `finalization`, a program's main `begin`.
    okUses: a uses/requires/contains clause.
    okInclude: an $I / $INCLUDE directive - a landmark whose
      row sits where the directive is; Name is the file as written, Node is
      the index into TPasPreprocessed.IncludeRefs, the position the
      directive's own. Listed whether or not the file loaded (Detail says
      `(not found)` when it did not).
    okType/okVar/okConst/okProperty/okRoutine: declarations. A field is an
      okVar with an Owner; a method an okRoutine with an Owner.
    The module-level `type`/`const`/`var` words are NOT rows (since 0.32.0):
    a reader steers by the sections and the declarations, and a `var` word
    between every group of them was noise in a filtered list. }
  TPasOutlineKind = (okModule, okSection, okUses, okInclude, okType, okVar,
    okConst, okProperty, okRoutine);

  TPasOutlineSection = (osNone, osInterface, osImplementation,
    osInitialization, osFinalization);

  { A run of a detail text: Start 1-based into the string, Len characters. }
  TPasTextSpan = record
    Start: Integer;
    Len: Integer;
  end;

  TPasOutlineEntry = record
    Kind: TPasOutlineKind;
    { The head word as a host prints it before the name: 'unit', 'type',
      'class function', 'property', 'field', 'const', 'resourcestring',
      'class var'... Lower case; never ''. }
    Head: string;
    { The enclosing struct's qualified name ('TFoo', 'TOuter.TInner',
      'TList<T>') for a member or a method body header; '' at module level. }
    Owner: string;
    { The declared name, generic parameters included ('TList<T>'). '' for a
      landmark that has none (okSection, okUses). }
    Name: string;
    { What a host prints after the name, in a quieter colour: a routine's
      parameter list and result (`(const A: X): Y`), a variable's `: T`, a
      constant's `= 3` or `: T`, a type's `= class` / `= record` / `= (the
      type expression)`. '' when there is nothing to say. Whitespace runs
      are collapsed and long texts are cut with '...'. }
    Detail: string;
    Section: TPasOutlineSection;
    { A routine header WITH a body: the implementation of a declaration made
      elsewhere (or a plain implementation-only routine). }
    IsImpl: Boolean;
    Node: Integer;        // the declaration node (nkRoutine, nkTypeDecl...);
                          // an okInclude row: its IncludeRefs index
    FilePath: string;     // the file the NAME sits in (may be an include)
    Line, Col: Integer;   // 1-based, of the name (or the landmark's keyword)
    { PROJECT rows only (TPasNavigator.ProjectOutline): the model the symbol
      lives in, its symbol index, and the unit's name for display. A module
      outline row has UnitId = -1, Sym = -1, UnitName = ''. A project row
      carries NO position (Line = Col = 0; FilePath = the unit's main file):
      the list is built from the retained symbol table so it costs nothing
      on a demoted unit, and the host asks TPasNavigator.DeclHit(UnitId,
      Sym) for the landing when a row is chosen. }
    UnitId: Integer;
    Sym: Integer;
    UnitName: string;
    { The type names inside Detail, as 1-based (Start, Len) into Detail, in
      order, non-overlapping - what a host paints in its type colour, the
      way an editor's semantic highlighting does (pastree-lsp, 2026-09-22:
      the Go To picker's detail column). Empty when Detail names no type.
      The module walk marks them by the SLOT an identifier sits in (see
      TOutlineWalker.MarkTypes); the project outline marks every identifier
      of the resolved type text (PasIdentSpans). }
    DetailTypes: TArray<TPasTextSpan>;
  end;

{ The module's outline, in source order. Empty for a tree with no nodes. }
function PasModuleOutline(const ATree: TPasTree): TArray<TPasOutlineEntry>;

{ The identifier runs of AText from AFrom (1-based) on, as spans - for a
  detail whose every identifier IS a type name (a resolved type's text:
  `TList<TItem>`, `TArray<string>`). }
function PasIdentSpans(const AText: string; AFrom: Integer)
  : TArray<TPasTextSpan>;

implementation

const
  DETAIL_MAX = 80;   // a type expression or constant value is cut here

type
  TOutlineWalker = record
  private
    FTree: TPasTree;
    FItems: TArray<TPasOutlineEntry>;
    FKeys: TArray<Integer>;   // per item: the name's Visible index (sort key)
    FCount: Integer;
    FSection: TPasOutlineSection;
    function Kind(ANode: Integer): TPasNodeKind; inline;
    function FirstChild(ANode: Integer): Integer; inline;
    function NextSib(ANode: Integer): Integer; inline;
    function TokenKindAfter(ANode: Integer): TPasTokenKind;
    function TokenKindBefore(ANode: Integer): TPasTokenKind;
    function SpanText(ANode: Integer): string;
    function TypedSpanText(ANode: Integer; ARootIsType: Boolean;
      ABase: Integer; var ATypes: TArray<TPasTextSpan>): string;
    procedure MarkTypes(ANode: Integer; AInTypeSlot: Boolean;
      var AIdents: TArray<Integer>);
    function PosOf(ANode: Integer; out AFile: string;
      out ALine, ACol, AVisTok: Integer): Boolean;
    procedure MergeIncludes;
    procedure Emit(AKind: TPasOutlineKind; const AHead, AOwner, AName,
      ADetail: string; AIsImpl: Boolean; ANode, APosNode: Integer;
      const ADetailTypes: TArray<TPasTextSpan> = nil);
    procedure WalkRoot;
    procedure WalkDecls(AParent: Integer; const AOwner: string);
    procedure WalkDecl(ANode: Integer; const AOwner: string);
    procedure WalkMembers(AStruct: Integer; const AOwner: string);
    procedure WalkVariant(ANode: Integer; const AOwner: string);
    procedure TypeDecl(ANode: Integer; const AOwner: string);
    procedure VarDecl(ANode: Integer; const AOwner, AHead: string);
    procedure ConstDecl(ANode: Integer; const AOwner, AHead: string);
    procedure Routine(ANode: Integer; const AOwner: string);
    procedure PropertyDecl(ANode: Integer; const AOwner: string);
  public
    function Run(const ATree: TPasTree): TArray<TPasOutlineEntry>;
  end;

// Whitespace runs (a declaration wrapped over lines) become one space, and
// anything past DETAIL_MAX is cut - the detail column is a hint, not the
// declaration.
function Collapse(const AText: string): string;
var
  LIdx: Integer;
  LInSpace: Boolean;
  LBuf: TStringBuilder;
begin
  LBuf := TStringBuilder.Create(Length(AText));
  try
    LInSpace := False;
    for LIdx := 1 to Length(AText) do
      if AText[LIdx] <= ' ' then
      begin
        if not LInSpace and (LBuf.Length > 0) then
          LBuf.Append(' ');
        LInSpace := True;
      end
      else
      begin
        LBuf.Append(AText[LIdx]);
        LInSpace := False;
      end;
    Result := LBuf.ToString.TrimRight;
  finally
    LBuf.Free;
  end;
  if Length(Result) > DETAIL_MAX then
    Result := Copy(Result, 1, DETAIL_MAX - 3) + '...';
end;

function PasModuleOutline(const ATree: TPasTree): TArray<TPasOutlineEntry>;
var
  LWalker: TOutlineWalker;
begin
  Result := LWalker.Run(ATree);
end;

{ TOutlineWalker }

function TOutlineWalker.Run(const ATree: TPasTree): TArray<TPasOutlineEntry>;
begin
  FTree := ATree;
  FItems := nil;
  FCount := 0;
  FSection := osNone;
  if Length(FTree.Nodes) > 0 then
    WalkRoot;
  MergeIncludes;
  SetLength(FItems, FCount);
  Result := FItems;
end;

function TOutlineWalker.Kind(ANode: Integer): TPasNodeKind;
begin
  Result := FTree.Nodes[ANode].Kind;
end;

function TOutlineWalker.FirstChild(ANode: Integer): Integer;
begin
  Result := FTree.Nodes[ANode].FirstChild;
end;

function TOutlineWalker.NextSib(ANode: Integer): Integer;
begin
  Result := FTree.Nodes[ANode].NextSibling;
end;

// The visible token right after a node's span - the resolver's own test for
// "is this the last name before the colon" (SepKindAfter).
function TOutlineWalker.TokenKindAfter(ANode: Integer): TPasTokenKind;
var
  LNext: Integer;
begin
  Result := tkEndOfFile;
  LNext := FTree.Nodes[ANode].LastToken + 1;
  if (LNext >= 0) and (LNext <= High(FTree.Source.Visible)) then
    Result := FTree.Source.VisibleToken(LNext).Kind;
end;

function TOutlineWalker.TokenKindBefore(ANode: Integer): TPasTokenKind;
var
  LPrev: Integer;
begin
  Result := tkEndOfFile;
  LPrev := FTree.NodeLeftmostVis(ANode) - 1;
  if (LPrev >= 0) and (LPrev <= High(FTree.Source.Visible)) then
    Result := FTree.Source.VisibleToken(LPrev).Kind;
end;

function TOutlineWalker.SpanText(ANode: Integer): string;
begin
  if ANode = NIL_NODE then
    Result := ''
  else
    Result := Collapse(FTree.NodeSpanText(ANode));
end;

{ The identifier nodes under ANode that name a TYPE, by the slot they sit in
  - the tree has no symbols, so this is the syntax's own knowledge of where
  a type name can stand:
    - the operand of `set of`, `^`, `class of`, `file of`; every child of a
      generic argument list (the designator and the arguments);
    - an array's element type, and a dimension that is a bare name
      (`array[TEnum]`; `array[0..N]` is a range of constants);
    - a parameter's type (the child after the colon), not its names and not
      its default; a procedure type's result;
    - a dotted name in a type slot: its LAST segment (`TOuter.TInner`,
      `Vcl.Tabs.TTabSet` - the prefix may be a unit, the tree cannot tell);
    - the node itself when the caller says the root is a type slot (a
      field's type, a routine's result, a type alias).
  Not a type: enum values, a `string[N]`'s N, a range's bounds, default
  values and constant expressions. }
procedure TOutlineWalker.MarkTypes(ANode: Integer; AInTypeSlot: Boolean;
  var AIdents: TArray<Integer>);
var
  LChild, LLast: Integer;
  LNamesDone: Boolean;
begin
  if ANode = NIL_NODE then
    Exit;
  case Kind(ANode) of
    nkIdent:
      if AInTypeSlot then
        AIdents := AIdents + [ANode];
    nkMember:
      begin
        // Base first (not a type slot - a unit or an outer type, unknown),
        // the name segment last.
        LLast := NIL_NODE;
        LChild := FirstChild(ANode);
        while LChild <> NIL_NODE do
        begin
          LLast := LChild;
          LChild := NextSib(LChild);
        end;
        LChild := FirstChild(ANode);
        while LChild <> NIL_NODE do
        begin
          MarkTypes(LChild, AInTypeSlot and (LChild = LLast), AIdents);
          LChild := NextSib(LChild);
        end;
      end;
    nkTypeArgs, nkSetType, nkPointerType, nkClassOf, nkFileType,
    nkConstraint:
      begin
        LChild := FirstChild(ANode);
        while LChild <> NIL_NODE do
        begin
          MarkTypes(LChild, True, AIdents);
          LChild := NextSib(LChild);
        end;
      end;
    nkArrayType:
      begin
        // Dimensions, then the element type last.
        LChild := FirstChild(ANode);
        while LChild <> NIL_NODE do
        begin
          if NextSib(LChild) = NIL_NODE then
            MarkTypes(LChild, True, AIdents)
          else
            MarkTypes(LChild, Kind(LChild) in [nkIdent, nkMember], AIdents);
          LChild := NextSib(LChild);
        end;
      end;
    nkParam:
      begin
        // Attribute groups and names up to the colon, the type after it,
        // then a default value.
        LNamesDone := False;
        LChild := FirstChild(ANode);
        while LChild <> NIL_NODE do
        begin
          if not LNamesDone and (TokenKindBefore(LChild) = tkColon) then
          begin
            MarkTypes(LChild, True, AIdents);
            LNamesDone := True;
          end;
          LChild := NextSib(LChild);
        end;
      end;
    nkProcType:
      begin
        LChild := FirstChild(ANode);
        while LChild <> NIL_NODE do
        begin
          if Kind(LChild) = nkParams then
            MarkTypes(LChild, False, AIdents)
          else if TokenKindBefore(LChild) = tkColon then
            MarkTypes(LChild, True, AIdents);   // the result type
          LChild := NextSib(LChild);
        end;
      end;
    nkEnumType, nkRange, nkStringType:
      ;   // values, bounds, a length: never types
  else
    LChild := FirstChild(ANode);
    while LChild <> NIL_NODE do
    begin
      MarkTypes(LChild, False, AIdents);
      LChild := NextSib(LChild);
    end;
  end;
end;

{ SpanText with its type names located: the same collapse as Collapse, done
  character by character here so every kept character knows where it landed,
  then each marked identifier's token is mapped through. Spans are 1-based
  into the FINAL detail, ABase characters of prefix included (`: `, `= `,
  or the parameter list a result type follows), and a token the DETAIL_MAX
  cut removed or split is dropped. The two texts are identical by
  construction - a token has no whitespace to collapse. }
function TOutlineWalker.TypedSpanText(ANode: Integer; ARootIsType: Boolean;
  ABase: Integer; var ATypes: TArray<TPasTextSpan>): string;
var
  LFirst, LLast, LStart0, LIdx, LKept, LRel, LVis, LTokIdx: Integer;
  LFrom, LTo, LV: TPasVisibleToken;
  LRaw: string;
  LMap: TArray<Integer>;   // raw 1-based index -> collapsed 1-based, 0 = gone
  LBuf: TStringBuilder;
  LInSpace: Boolean;
  LIdents: TArray<Integer>;
  LSpan: TPasTextSpan;
  LTok: TPasToken;
begin
  Result := '';
  if ANode = NIL_NODE then
    Exit;
  LFirst := FTree.NodeLeftmostVis(ANode);
  LLast := FTree.Nodes[ANode].LastToken;
  if (LFirst < 0) or (LLast < LFirst) or
     (LLast > High(FTree.Source.Visible)) then
    Exit;
  LFrom := FTree.Source.Visible[LFirst];
  LTo := FTree.Source.Visible[LLast];
  if LFrom.FileId <> LTo.FileId then
    Exit;
  with FTree.Source.Files[LFrom.FileId] do
  begin
    LStart0 := Tokens[LFrom.TokenIndex].Start;
    LRaw := Copy(Source, LStart0 + 1, Tokens[LTo.TokenIndex].EndPos - LStart0);
  end;

  SetLength(LMap, Length(LRaw) + 1);
  LBuf := TStringBuilder.Create(Length(LRaw));
  try
    LInSpace := False;
    for LIdx := 1 to Length(LRaw) do
    begin
      LMap[LIdx] := 0;
      if LRaw[LIdx] <= ' ' then
      begin
        if not LInSpace and (LBuf.Length > 0) then
          LBuf.Append(' ');
        LInSpace := True;
      end
      else
      begin
        LBuf.Append(LRaw[LIdx]);
        LMap[LIdx] := LBuf.Length;
        LInSpace := False;
      end;
    end;
    Result := LBuf.ToString.TrimRight;
  finally
    LBuf.Free;
  end;
  LKept := Length(Result);
  if Length(Result) > DETAIL_MAX then
  begin
    LKept := DETAIL_MAX - 3;
    Result := Copy(Result, 1, LKept) + '...';
  end;

  LIdents := nil;
  MarkTypes(ANode, ARootIsType, LIdents);
  for LIdx := 0 to High(LIdents) do
  begin
    LVis := FTree.Nodes[LIdents[LIdx]].FirstToken;
    if (LVis < LFirst) or (LVis > LLast) then
      Continue;
    LV := FTree.Source.Visible[LVis];
    if LV.FileId <> LFrom.FileId then
      Continue;
    LTokIdx := LV.TokenIndex;
    LTok := FTree.Source.Files[LV.FileId].Tokens[LTokIdx];
    LRel := LTok.Start - LStart0 + 1;
    if (LRel < 1) or (LRel > Length(LRaw)) or (LMap[LRel] = 0) then
      Continue;
    if LMap[LRel] + LTok.Len - 1 > LKept then
      Continue;   // cut, wholly or in part
    LSpan.Start := ABase + LMap[LRel];
    LSpan.Len := LTok.Len;
    ATypes := ATypes + [LSpan];
  end;
end;

function PasIdentSpans(const AText: string; AFrom: Integer)
  : TArray<TPasTextSpan>;
var
  LIdx, LStart: Integer;
  LSpan: TPasTextSpan;
begin
  Result := nil;
  LIdx := AFrom;
  while LIdx <= Length(AText) do
  begin
    if CharInSet(AText[LIdx], ['A'..'Z', 'a'..'z', '_']) then
    begin
      LStart := LIdx;
      while (LIdx <= Length(AText)) and
            CharInSet(AText[LIdx], ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
        Inc(LIdx);
      LSpan.Start := LStart;
      LSpan.Len := LIdx - LStart;
      Result := Result + [LSpan];
    end
    else
      Inc(LIdx);
  end;
end;

// File/line/col of a node's leftmost visible token - the same landing
// TPasNavigator.TargetFromNode computes, so a picker row and a ctrl+click on
// the same name agree. False for a node without tokens (nothing to jump to).
function TOutlineWalker.PosOf(ANode: Integer; out AFile: string;
  out ALine, ACol, AVisTok: Integer): Boolean;
var
  LVis: TPasVisibleToken;
begin
  Result := False;
  if ANode = NIL_NODE then
    Exit;
  AVisTok := FTree.NodeLeftmostVis(ANode);
  if (AVisTok < 0) or (AVisTok > High(FTree.Source.Visible)) then
    Exit;
  LVis := FTree.Source.Visible[AVisTok];
  if (LVis.FileId < 0) or (LVis.FileId > High(FTree.Source.Files)) then
    Exit;
  var LTS := FTree.Source.Files[LVis.FileId];
  if (LVis.TokenIndex < 0) or (LVis.TokenIndex > High(LTS.Tokens)) then
    Exit;
  LTS.OffsetToLineCol(LTS.Tokens[LVis.TokenIndex].Start, ALine, ACol);
  AFile := FTree.Source.FileNames[LVis.FileId];
  Result := True;
end;

procedure TOutlineWalker.Emit(AKind: TPasOutlineKind; const AHead, AOwner,
  AName, ADetail: string; AIsImpl: Boolean; ANode, APosNode: Integer;
  const ADetailTypes: TArray<TPasTextSpan>);
var
  LEntry: TPasOutlineEntry;
  LKey: Integer;
begin
  if not PosOf(APosNode, LEntry.FilePath, LEntry.Line, LEntry.Col, LKey) then
    Exit;
  LEntry.Kind := AKind;
  LEntry.Head := AHead;
  LEntry.Owner := AOwner;
  LEntry.Name := AName;
  LEntry.Detail := ADetail;
  LEntry.DetailTypes := ADetailTypes;
  LEntry.Section := FSection;
  LEntry.IsImpl := AIsImpl;
  LEntry.Node := ANode;
  LEntry.UnitId := -1;
  LEntry.Sym := -1;
  LEntry.UnitName := '';
  if FCount = Length(FItems) then
  begin
    SetLength(FItems, FCount * 2 + 32);
    SetLength(FKeys, Length(FItems));
  end;
  FItems[FCount] := LEntry;
  FKeys[FCount] := LKey;
  Inc(FCount);
end;

// The include directives, slotted into the walk's rows by stream position: a
// directive's VisIndex is where its file's first token landed (or would have),
// so it goes before the first row whose name token is at or past it - the
// included file's own first declaration comes right after its directive, a
// directive at the end of a section before the next section's row. The row
// is positioned on the directive itself, in the INCLUDER's file.
procedure TOutlineWalker.MergeIncludes;
var
  LRefs: TArray<TPasIncludeRef>;
  LIdx, LAt, LMove: Integer;
  LEntry: TPasOutlineEntry;
  LTS: TPasTokenStream;
begin
  LRefs := FTree.Source.IncludeRefs;
  if Length(LRefs) = 0 then
    Exit;
  SetLength(FItems, FCount + Length(LRefs));
  SetLength(FKeys, Length(FItems));
  LAt := 0;
  for LIdx := 0 to High(LRefs) do
  begin
    if (LRefs[LIdx].FileId < 0) or
       (LRefs[LIdx].FileId > High(FTree.Source.Files)) then
      Continue;
    LTS := FTree.Source.Files[LRefs[LIdx].FileId];
    LEntry := Default(TPasOutlineEntry);
    LEntry.Kind := okInclude;
    LEntry.Head := 'include';
    LEntry.Name := LRefs[LIdx].Arg;
    if LRefs[LIdx].IncludedFileId < 0 then
      LEntry.Detail := '(not found)';
    LEntry.Section := osNone;
    LEntry.Node := LIdx;
    LEntry.UnitId := -1;
    LEntry.Sym := -1;
    LEntry.FilePath := FTree.Source.FileNames[LRefs[LIdx].FileId];
    LTS.OffsetToLineCol(LRefs[LIdx].Start, LEntry.Line, LEntry.Col);
    // Refs come in processing order, so the insertion point only moves on.
    while (LAt < FCount) and (FKeys[LAt] < LRefs[LIdx].VisIndex) do
      Inc(LAt);
    for LMove := FCount downto LAt + 1 do
    begin
      FItems[LMove] := FItems[LMove - 1];
      FKeys[LMove] := FKeys[LMove - 1];
    end;
    FItems[LAt] := LEntry;
    FKeys[LAt] := LRefs[LIdx].VisIndex;
    Inc(FCount);
    Inc(LAt);
  end;
end;

procedure TOutlineWalker.WalkRoot;
var
  LRoot, LChild, LName: Integer;
  LHead: string;
begin
  LRoot := 0;
  case Kind(LRoot) of
    nkUnit: LHead := 'unit';
    nkProgram: LHead := 'program';
    nkLibrary: LHead := 'library';
    nkPackage: LHead := 'package';
  else
    Exit;   // not a module root (a statement/declaration test parse)
  end;
  // The header: name = the qualified-name child (nkIdent or an nkMember
  // chain), which is the first child that is not an attribute.
  LName := FirstChild(LRoot);
  while (LName <> NIL_NODE) and (Kind(LName) = nkAttrGroup) do
    LName := NextSib(LName);
  if (LName <> NIL_NODE) and (Kind(LName) in [nkIdent, nkMember]) then
    Emit(okModule, LHead, '', SpanText(LName), '', False, LRoot, LName)
  else
    Emit(okModule, LHead, '', '', '', False, LRoot, LRoot);
  LChild := FirstChild(LRoot);
  while LChild <> NIL_NODE do
  begin
    case Kind(LChild) of
      nkInterfaceSec:
        begin
          FSection := osInterface;
          Emit(okSection, 'interface', '', '', '', False, LChild, LChild);
          WalkDecls(LChild, '');
        end;
      nkImplementationSec:
        begin
          FSection := osImplementation;
          Emit(okSection, 'implementation', '', '', '', False, LChild, LChild);
          WalkDecls(LChild, '');
        end;
      nkInitSec:
        begin
          FSection := osInitialization;
          // A legacy `begin` opens the initialization part too (1.1.2) -
          // print the word actually written.
          Emit(okSection, LowerCase(FTree.NodeText(LChild)), '', '', '',
            False, LChild, LChild);
        end;
      nkFinalSec:
        begin
          FSection := osFinalization;
          Emit(okSection, 'finalization', '', '', '', False, LChild, LChild);
        end;
      nkBlock:
        // A program's or library's main block.
        Emit(okSection, 'begin', '', '', '', False, LChild, LChild);
      nkIdent, nkMember, nkAttrGroup, nkDirective:
        ;   // the header's own name and hints
    else
      WalkDecl(LChild, '');   // program/library/package-level declarations
    end;
    LChild := NextSib(LChild);
  end;
end;

procedure TOutlineWalker.WalkDecls(AParent: Integer; const AOwner: string);
var
  LChild: Integer;
begin
  LChild := FirstChild(AParent);
  while LChild <> NIL_NODE do
  begin
    WalkDecl(LChild, AOwner);
    LChild := NextSib(LChild);
  end;
end;

// One child of a section, a struct body or a module root. AOwner = '' at
// module level; the struct's qualified name inside a struct body, where the
// section keywords are member-list punctuation rather than landmarks and
// therefore get no row of their own.
procedure TOutlineWalker.WalkDecl(ANode: Integer; const AOwner: string);
var
  LChild: Integer;
  LHead: string;
begin
  case Kind(ANode) of
    nkUsesClause:
      begin
        // A package's requires/contains share the node kind (Aux 1 =
        // requires); the head word is whatever was written.
        LHead := LowerCase(FTree.NodeText(ANode));
        if not ((LHead = 'uses') or (LHead = 'requires') or
                (LHead = 'contains')) then
          LHead := 'uses';
        Emit(okUses, LHead, '', '', '', False, ANode, ANode);
      end;
    nkTypeSec:
      begin
        LChild := FirstChild(ANode);
        while LChild <> NIL_NODE do
        begin
          if Kind(LChild) = nkTypeDecl then
            TypeDecl(LChild, AOwner);
          LChild := NextSib(LChild);
        end;
      end;
    nkConstSec:
      begin
        LHead := LowerCase(FTree.NodeText(ANode));
        if not ((LHead = 'const') or (LHead = 'resourcestring')) then
          LHead := 'const';   // headless recovery section
        LChild := FirstChild(ANode);
        while LChild <> NIL_NODE do
        begin
          if Kind(LChild) = nkConstDecl then
            ConstDecl(LChild, AOwner, LHead);
          LChild := NextSib(LChild);
        end;
      end;
    nkVarSec:
      begin
        if FTree.Nodes[ANode].Aux = 1 then
          LHead := 'class var'   // no head word of its own (see PasTree.Ast)
        else
        begin
          LHead := LowerCase(FTree.NodeText(ANode));
          if not ((LHead = 'var') or (LHead = 'threadvar')) then
            LHead := 'var';
          if AOwner <> '' then
            LHead := 'field';
        end;
        LChild := FirstChild(ANode);
        while LChild <> NIL_NODE do
        begin
          if Kind(LChild) = nkVarDecl then
            VarDecl(LChild, AOwner, LHead);
          LChild := NextSib(LChild);
        end;
      end;
    nkRoutine:
      Routine(ANode, AOwner);
    nkPropertyDecl:
      PropertyDecl(ANode, AOwner);
    nkVarDecl:
      // A bare field list in a struct body (no `var` marker).
      VarDecl(ANode, AOwner, 'field');
    nkVariantPart:
      WalkVariant(ANode, AOwner);
    // nkVisibility, nkAttrGroup, nkMethodResolution, nkGuid, nkLabelSec,
    // nkExportsClause, heritage type refs, hint directives: nothing to list.
  end;
end;

// A struct type's body: its members, each owned by the struct's name. The
// children also hold the heritage list and (interfaces) the GUID clause -
// WalkDecl lists nothing for those kinds, so a plain pass over every child
// is the whole dispatch.
procedure TOutlineWalker.WalkMembers(AStruct: Integer; const AOwner: string);
begin
  WalkDecls(AStruct, AOwner);
end;

// A record's variant part (9.1.3): [tag] type + branches, each branch a
// label list followed by fields, possibly another nested variant part. The
// tag itself is an nkVarDecl when it has a name.
procedure TOutlineWalker.WalkVariant(ANode: Integer; const AOwner: string);
var
  LChild, LInner: Integer;
begin
  LChild := FirstChild(ANode);
  while LChild <> NIL_NODE do
  begin
    case Kind(LChild) of
      nkVarDecl:
        VarDecl(LChild, AOwner, 'field');
      nkVariantBranch:
        begin
          LInner := FirstChild(LChild);
          while LInner <> NIL_NODE do
          begin
            case Kind(LInner) of
              nkVarDecl: VarDecl(LInner, AOwner, 'field');
              nkVariantPart: WalkVariant(LInner, AOwner);
            end;
            LInner := NextSib(LInner);
          end;
        end;
    end;
    LChild := NextSib(LChild);
  end;
end;

procedure TOutlineWalker.TypeDecl(ANode: Integer; const AOwner: string);
var
  LChild, LName, LTypeExpr: Integer;
  LNameText, LDetail, LQualified, LText: string;
  LTypes: TArray<TPasTextSpan>;
begin
  LTypes := nil;
  // [attrs] name [generic params] TypeExpr
  LChild := FirstChild(ANode);
  while (LChild <> NIL_NODE) and (Kind(LChild) = nkAttrGroup) do
    LChild := NextSib(LChild);
  if (LChild = NIL_NODE) or (Kind(LChild) <> nkIdent) then
    Exit;
  LName := LChild;
  LNameText := FTree.NodeText(LName);
  LChild := NextSib(LChild);
  if (LChild <> NIL_NODE) and (Kind(LChild) = nkGenericParams) then
  begin
    LNameText := LNameText + SpanText(LChild);
    LChild := NextSib(LChild);
  end;
  LTypeExpr := LChild;
  if AOwner = '' then
    LQualified := LNameText
  else
    LQualified := AOwner + '.' + LNameText;
  LDetail := '';
  if LTypeExpr <> NIL_NODE then
    case Kind(LTypeExpr) of
      nkClassType: LDetail := '= class';
      nkRecordType: LDetail := '= record';
      nkObjectType: LDetail := '= object';
      nkInterfaceType:
        if FTree.Nodes[LTypeExpr].Aux and 1 <> 0 then
          LDetail := '= dispinterface'
        else
          LDetail := '= interface';
      nkHelperType:
        if FTree.Nodes[LTypeExpr].Aux = 1 then
          LDetail := '= record helper'
        else
          LDetail := '= class helper';
    else
      if FTree.Nodes[ANode].Aux = 1 then
        LDetail := '= type '   // distinct alias (2.5.1)
      else
        LDetail := '= ';
      LText := TypedSpanText(LTypeExpr, True, Length(LDetail), LTypes);
      if LText = '' then
        LDetail := ''
      else
        LDetail := LDetail + LText;
    end;
  Emit(okType, 'type', AOwner, LNameText, LDetail, False, ANode, LName,
    LTypes);
  // Members follow their type row, in source order. A forward `class;`
  // has no members; a shorthand `class(TBase);` only heritage refs.
  if (LTypeExpr <> NIL_NODE) and (Kind(LTypeExpr) in [nkClassType,
     nkRecordType, nkObjectType, nkInterfaceType, nkHelperType]) then
    WalkMembers(LTypeExpr, LQualified);
end;

// `A, B: T` - one row per name. The names are the leading nkIdent children;
// the last one is the ident followed by ':' (the type may itself be a bare
// nkIdent, so the shape alone cannot tell the two apart - the separator can).
procedure TOutlineWalker.VarDecl(ANode: Integer; const AOwner, AHead: string);
var
  LChild, LType: Integer;
  LNames: TArray<Integer>;
  LDetail: string;
  LIdx: Integer;
  LTypes: TArray<TPasTextSpan>;
begin
  LChild := FirstChild(ANode);
  while (LChild <> NIL_NODE) and (Kind(LChild) = nkAttrGroup) do
    LChild := NextSib(LChild);
  LNames := nil;
  LType := NIL_NODE;
  while (LChild <> NIL_NODE) and (Kind(LChild) = nkIdent) do
  begin
    LNames := LNames + [LChild];
    if TokenKindAfter(LChild) = tkColon then
    begin
      LType := NextSib(LChild);
      Break;
    end;
    LChild := NextSib(LChild);
  end;
  LTypes := nil;
  LDetail := TypedSpanText(LType, True, 2, LTypes);
  if LDetail <> '' then
    LDetail := ': ' + LDetail;
  for LIdx := 0 to High(LNames) do
    Emit(okVar, AHead, AOwner, FTree.NodeText(LNames[LIdx]), LDetail, False,
      ANode, LNames[LIdx], LTypes);
end;

// `Name = Value` or `Name: T = Value` - the detail is the type when there
// is one (a typed constant's value is usually a long aggregate), else the
// value.
procedure TOutlineWalker.ConstDecl(ANode: Integer; const AOwner,
  AHead: string);
var
  LName, LNext: Integer;
  LDetail: string;
  LTypes: TArray<TPasTextSpan>;
begin
  LName := FirstChild(ANode);
  while (LName <> NIL_NODE) and (Kind(LName) = nkAttrGroup) do
    LName := NextSib(LName);
  if (LName = NIL_NODE) or (Kind(LName) <> nkIdent) then
    Exit;
  LNext := NextSib(LName);
  LDetail := '';
  LTypes := nil;
  if LNext <> NIL_NODE then
    if TokenKindAfter(LName) = tkColon then
      LDetail := ': ' + TypedSpanText(LNext, True, 2, LTypes)
    else
      LDetail := '= ' + SpanText(LNext);   // a value: no type names in it
  Emit(okConst, AHead, AOwner, FTree.NodeText(LName), LDetail, False, ANode,
    LName, LTypes);
end;

// A routine header, declared in a struct (AOwner = the struct) or at module
// level - where a dotted name (`TFoo<T>.Bar`, `TOuter.TInner.Baz`) names the
// owner itself. The body, when there is one, makes this an implementation
// row; its local declarations are not walked.
procedure TOutlineWalker.Routine(ANode: Integer; const AOwner: string);
var
  LChild, LFirstName, LParams, LResult: Integer;
  LSegments: TArray<string>;
  LHead, LOwner, LName, LDetail: string;
  LIsImpl: Boolean;
  LIdx: Integer;
  LTypes: TArray<TPasTextSpan>;
begin
  LHead := LowerCase(FTree.NodeText(ANode));
  if FTree.Nodes[ANode].Aux = 1 then
    LHead := 'class ' + LHead;
  LSegments := nil;
  LFirstName := NIL_NODE;
  LParams := NIL_NODE;
  LResult := NIL_NODE;
  LIsImpl := False;
  LChild := FirstChild(ANode);
  while LChild <> NIL_NODE do
  begin
    case Kind(LChild) of
      nkIdent:
        // A name segment - unless it is the result type (`: Integer`),
        // which is an nkIdent too, told apart by the colon before it.
        if (LParams = NIL_NODE) and (TokenKindBefore(LChild) <> tkColon) then
        begin
          LSegments := LSegments + [FTree.NodeText(LChild)];
          if LFirstName = NIL_NODE then
            LFirstName := LChild;
        end
        else if LResult = NIL_NODE then
          LResult := LChild;
      nkGenericParams:
        if Length(LSegments) > 0 then
          LSegments[High(LSegments)] :=
            LSegments[High(LSegments)] + SpanText(LChild);
      nkParams:
        LParams := LChild;
      nkDirective, nkAttrGroup:
        ;
      nkRoutineBody:
        LIsImpl := True;
    else
      // The result type in any other shape (a qualified name, `array of`,
      // a string type...): the child introduced by ':'.
      if (LResult = NIL_NODE) and (TokenKindBefore(LChild) = tkColon) then
        LResult := LChild;
    end;
    LChild := NextSib(LChild);
  end;
  if LFirstName = NIL_NODE then
    Exit;   // a nameless header mid-typing: nothing to list
  LName := LSegments[High(LSegments)];
  if Length(LSegments) > 1 then
  begin
    LOwner := LSegments[0];
    for LIdx := 1 to High(LSegments) - 1 do
      LOwner := LOwner + '.' + LSegments[LIdx];
  end
  else
    LOwner := AOwner;
  LTypes := nil;
  LDetail := TypedSpanText(LParams, False, 0, LTypes);
  if LResult <> NIL_NODE then
    LDetail := LDetail + ': ' +
      TypedSpanText(LResult, True, Length(LDetail) + 2, LTypes);
  Emit(okRoutine, LHead, LOwner, LName, LDetail, LIsImpl, ANode, LFirstName,
    LTypes);
end;

procedure TOutlineWalker.PropertyDecl(ANode: Integer; const AOwner: string);
var
  LChild, LName, LParams, LType: Integer;
  LHead, LDetail: string;
  LTypes: TArray<TPasTextSpan>;
begin
  LHead := 'property';
  if FTree.Nodes[ANode].Aux = 1 then
    LHead := 'class property';
  LChild := FirstChild(ANode);
  while (LChild <> NIL_NODE) and (Kind(LChild) = nkAttrGroup) do
    LChild := NextSib(LChild);
  if (LChild = NIL_NODE) or (Kind(LChild) <> nkIdent) then
    Exit;
  LName := LChild;
  LParams := NIL_NODE;
  LType := NIL_NODE;
  LChild := NextSib(LChild);
  if (LChild <> NIL_NODE) and (Kind(LChild) = nkParams) then
  begin
    LParams := LChild;
    LChild := NextSib(LChild);
  end;
  // The type is the child introduced by ':' - absent on a bare redeclaration
  // (`property X;`), where specifiers (if any) follow the name directly.
  if (LChild <> NIL_NODE) and (Kind(LChild) <> nkPropSpec) and
     (TokenKindBefore(LChild) = tkColon) then
    LType := LChild;
  LTypes := nil;
  LDetail := TypedSpanText(LParams, False, 0, LTypes);
  if LType <> NIL_NODE then
    LDetail := LDetail + ': ' +
      TypedSpanText(LType, True, Length(LDetail) + 2, LTypes);
  Emit(okProperty, LHead, AOwner, FTree.NodeText(LName), LDetail, False,
    ANode, LName, LTypes);
end;

end.
