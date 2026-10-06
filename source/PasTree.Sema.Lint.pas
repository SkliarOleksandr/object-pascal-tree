unit PasTree.Sema.Lint;

{ Unused `uses` entries: a unit listed in a unit's `uses` none of whose names
  the unit uses - removing it shortens every build of the importer.

  A name counts for the unit listing it when dcc needs that unit in scope to
  bind it: a unit-level declaration of its interface, an enum value, a
  helper's member. A member reached through a value or a type (`List.Add`,
  `TFoo.Create`) does not: dcc finds members wherever the type came from, and
  the type named is the use. So do the qualifier of `Unit.Name`, the unit's
  form file naming a class or a module the listed unit declares, a name bound
  through an alias of another unit (`TModalResult` of Vcl.Controls is
  System.UITypes'), a name of the interface PasTree bound to a unit of the
  implementation `uses`, and a unit an inline routine the unit calls needs
  for its expansion (InlineDeps).

  What the index cannot see is said on the entry (Doubts) rather than decided:
  a name bound to nothing that the unit declares, a branch not compiled here
  naming it, a routine called here that the unit declares too (dcc picks
  among every unit's overloads), and - since a unit can be in `uses` for what
  its initialization does, registering a class or a graphic format - the
  initialization a removal leaves out of the program: the units no other path
  of the program reaches any more, those with initialization or finalization
  code or a resource named.

  One analysis, one configuration: an entry used only in a branch the
  analysis does not compile is reported (with the doubt that names it). The
  same rule is pastree-mcp's `lint unused-uses`, which weighs every analysis
  of a group. }

interface

uses
  PasTree.Sema.Project,
  PasTree.Sema.Nav;

type
  TPasUnusedUse = record
    Hit: TPasRefHit;          // the entry's name in its `uses` clause
    UnitName: string;         // as written
    InInterface: Boolean;
    // Why removing it may be wrong, one sentence each; empty when nothing
    // the index sees speaks against the removal.
    Doubts: TArray<string>;
  end;

  { loHideGlobalInit: leave out what a removal would cost a unit's
    initialization that reaches OUTSIDE the unit - an unused entry naming
    such a unit (even one the program reaches another way), or whose
    removal leaves one out of the program, a unit nobody uses that
    has one (or is the only path to one). "Outside" is a routine or a
    variable of another unit, or a member of one's type named through the
    type (`RegisterClass`, `Application.Title := ...`,
    `TPicture.RegisterFileFormat`, `TProviders.Register(...)`), named in the
    initialization or in a routine of the unit it calls; a constructor, a
    type, a constant or a member reached through the unit's own variable
    (`FList := TList.Create`, `FList.Add`) stays inside. Such a unit is in
    `uses` for what it registers, which no index of names can see, so a host
    acting on the rows (removing them) is better off not offered it at all.
    Without the option those rows come with a doubt, as before. }
  TPasLintOption = (loHideGlobalInit);
  TPasLintOptions = set of TPasLintOption;

  TPasUnreferencedUnit = record
    Hit: TPasRefHit;          // the unit's name in its own header
    UnitName: string;
    // Who lists it, by file name: 'Main.pas (no name of it used)',
    // 'Project.dpr (no name of it used)', 'Old.pas (itself unreferenced)'.
    // Empty when nothing does (a directory analysis).
    ListedBy: TArray<string>;
    Doubts: TArray<string>;   // as TPasUnusedUse's
  end;

// The units AMids no other unit really uses: what the program would no
// longer reach once every unused `uses` entry is gone - its own included,
// where the IDE lists every unit of a project. An entry with a doubt (a
// dead branch naming the unit, a name bound to nothing) is kept as a use.
// Without a program in the analysis (a directory), the units no other unit
// lists and uses. A unit with initialization or
// finalization code or a resource carries a doubt: it may be listed for
// what that registers. Sorted by unit name (ListedBy too). AOptions: see
// TPasLintOption.
function FindUnreferencedUnits(ANav: TPasNavigator;
  const AMids: TArray<Integer>;
  AOptions: TPasLintOptions = []): TArray<TPasUnreferencedUnit>;

// The unused `uses` entries of the units AMids of ANav's project, sorted by
// the listing file's name (its path breaking a tie), then by the unused
// unit's name. A program, a library or a package is skipped: its
// `uses` is its contents. An entry whose unit did not resolve is not judged.
// The navigator pairs an inline routine's declaration with its body.
// AOptions: see TPasLintOption.
function FindUnusedUses(ANav: TPasNavigator;
  const AMids: TArray<Integer>;
  AOptions: TPasLintOptions = []): TArray<TPasUnusedUse>;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.StrUtils,
  System.Math,
  System.Character,
  System.RegularExpressions,
  System.Generics.Collections,
  System.Generics.Defaults,
  PasTree.Types,
  PasTree.Preprocessor,
  PasTree.Ast,
  PasTree.Dfm,
  PasTree.Sema.Model;

const
  // Units, places or calls named in one doubt; past them, counted.
  MAX_NAMED = 3;

type
  TLintPlace = record
    FilePath: string;
    Line: Integer;
  end;

  TLintEntry = record
    Name: string;
    NameNode: Integer;
    UnitId, Sym: Integer;
    InInterface, Used: Boolean;
    Doubts: TArray<string>;
  end;

  // What is read more than once over the units checked: the interface names
  // of the units they list, the uses graph, what each program reaches, which
  // units run code at start.
  TUsesLint = class
  private
    FNav: TPasNavigator;
    FProj: TPasSemaProject;
    // An inline routine (model shl 32 or symbol) -> the units its expansion
    // needs; nil while it is being computed (a recursive inline routine).
    FInline: TDictionary<Int64, TArray<Integer>>;
    // A property -> its accessors marked inline.
    FAccessors: TDictionary<Int64, TArray<Int64>>;
    FNames: TObjectDictionary<Integer, TDictionary<string, Integer>>;
    FEffect: TDictionary<Integer, string>;
    FReach: TDictionary<Integer, TArray<Boolean>>;
    FStart, FEdges: TArray<Integer>;
    FRoots: TArray<Integer>;
    FRows: TList<TPasUnusedUse>;
    FDeadEdges: TDictionary<Int64, Boolean>;   // From shl 32 or Target
    FOptions: TPasLintOptions;
    FGlobalInit: TDictionary<Integer, Boolean>;
    procedure BuildGraph;
    function GlobalInit(AMid: Integer): Boolean;
    function DropsGlobalInit(AFrom, ATo: Integer): Boolean;
    function ReachOf(ARoot, ASkipFrom, ASkipTo: Integer): TArray<Boolean>;
    function FullReach(ARoot: Integer): TArray<Boolean>;
    function EffectsFrom(AStart: Integer;
      const ALost: TArray<Boolean>): TArray<string>;
    function NamesOf(AMid: Integer): TDictionary<string, Integer>;
    function LinkEffect(AMid: Integer): string;
    function NeedsItsUnit(const AExt: TPasExtRef): Boolean;
    function UnitNameOf(AMid: Integer): string;
    function DropsText(AFrom, ATo: Integer): string;
    procedure AddNodeUnits(AMid, ANode: Integer;
      AUnits: TDictionary<Integer, Boolean>);
    procedure AddTypeUnits(AMid, ASym: Integer;
      AUnits: TDictionary<Integer, Boolean>);
    function InlineAccessors(AMid, ASym: Integer): TArray<Int64>;
    function InlineDeps(AMid, ASym: Integer): TArray<Integer>;
    // AEdges: record the unused entries no doubt holds back as FDeadEdges
    // instead of rows - a program's too (its `uses` lists units the build
    // takes in, what FindUnreferencedUnits weighs).
    procedure CheckUnit(AMid: Integer; AEdges: Boolean = False);
    function LiveUnits: TArray<Boolean>;
  public
    constructor Create(ANav: TPasNavigator);
    destructor Destroy; override;
  end;

function IsIdentChar(ACh: Char): Boolean;
begin
  Result := CharInSet(ACh, ['a'..'z', 'A'..'Z', '0'..'9', '_']) or
    ((ACh > #127) and ACh.IsLetterOrDigit);
end;

// 'a, b and 2 more'.
function NamedList(const AItems: TArray<string>; AMax: Integer): string;
begin
  Result := '';
  for var LI := 0 to Min(Length(AItems), AMax) - 1 do
  begin
    if LI > 0 then
      Result := Result + IfThen(LI = Length(AItems) - 1, ' and ', ', ');
    Result := Result + AItems[LI];
  end;
  if Length(AItems) > AMax then
    Result := Result + Format(' and %d more', [Length(AItems) - AMax]);
end;

// The module node: the root itself, or its child.
function ModuleNode(LM: TPasSemaModel): Integer;
var
  LC: Integer;
begin
  Result := NIL_NODE;
  if Length(LM.Tree.Nodes) = 0 then
    Exit;
  if LM.Tree.Nodes[0].Kind in [nkUnit, nkProgram, nkLibrary, nkPackage] then
    Exit(0);
  LC := LM.Tree.Nodes[0].FirstChild;
  while LC <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LC].Kind in [nkUnit, nkProgram, nkLibrary, nkPackage] then
      Exit(LC);
    LC := LM.Tree.Nodes[LC].NextSibling;
  end;
end;

// The module's child of kind AKind, NIL_NODE when it has none.
function ModuleChild(LM: TPasSemaModel; AKind: TPasNodeKind): Integer;
var
  LMod: Integer;
begin
  Result := NIL_NODE;
  LMod := ModuleNode(LM);
  if LMod = NIL_NODE then
    Exit;
  Result := LM.Tree.Nodes[LMod].FirstChild;
  while (Result <> NIL_NODE) and (LM.Tree.Nodes[Result].Kind <> AKind) do
    Result := LM.Tree.Nodes[Result].NextSibling;
end;

// Whether ANode's subtree holds anything but empty blocks: an
// `initialization` with a statement in it.
function HasStatements(LM: TPasSemaModel; ANode: Integer): Boolean;
var
  LC: Integer;
begin
  Result := False;
  LC := LM.Tree.Nodes[ANode].FirstChild;
  while LC <> NIL_NODE do
  begin
    if not (LM.Tree.Nodes[LC].Kind in [nkBlock, nkEmptyStmt]) or
       HasStatements(LM, LC) then
      Exit(True);
    LC := LM.Tree.Nodes[LC].NextSibling;
  end;
end;

function InUsesClause(LM: TPasSemaModel; ANode: Integer): Boolean;
var
  LP: Integer;
begin
  LP := ANode;
  while LP <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LP].Kind = nkUsesClause then
      Exit(True);
    LP := LM.Tree.Nodes[LP].Parent;
  end;
  Result := False;
end;

// The 1-based line of ANode's first token, in the file it is written in.
procedure NodePlace(LM: TPasSemaModel; ANode: Integer; out AFile: string;
  out ALine: Integer);
var
  LVisTok, LCol: Integer;
  LVis: TPasVisibleToken;
  LTS: TPasTokenStream;
begin
  AFile := '';
  ALine := 0;
  LVisTok := LM.Tree.NodeLeftmostVis(ANode);
  if (LVisTok < 0) or (LVisTok > High(LM.Tree.Source.Visible)) then
    Exit;
  LVis := LM.Tree.Source.Visible[LVisTok];
  LTS := LM.Tree.Source.Files[LVis.FileId];
  AFile := LM.Tree.Source.FileNames[LVis.FileId];
  LTS.OffsetToLineCol(LTS.Tokens[LVis.TokenIndex].Start, ALine, LCol);
end;

// The row of a `uses` entry: its whole (dotted) name highlighted.
function EntryHit(LM: TPasSemaModel; ANode: Integer;
  out AHit: TPasRefHit): Boolean;
var
  LFirstVis, LLastVis, LLineTo, LColTo: Integer;
  LFrom, LTo: TPasVisibleToken;
  LTS: TPasTokenStream;
begin
  Result := False;
  AHit := Default(TPasRefHit);
  LFirstVis := LM.Tree.NodeLeftmostVis(ANode);
  LLastVis := LM.Tree.Nodes[ANode].LastToken;
  if (LFirstVis < 0) or (LLastVis < LFirstVis) or
     (LLastVis > High(LM.Tree.Source.Visible)) then
    Exit;
  LFrom := LM.Tree.Source.Visible[LFirstVis];
  LTo := LM.Tree.Source.Visible[LLastVis];
  LTS := LM.Tree.Source.Files[LFrom.FileId];
  AHit.FilePath := LM.Tree.Source.FileNames[LFrom.FileId];
  LTS.OffsetToLineCol(LTS.Tokens[LFrom.TokenIndex].Start, AHit.Line, AHit.Col);
  AHit.Snippet := LTS.LineText(AHit.Line);
  AHit.HiFrom := AHit.Col - 1;
  AHit.HiTo := AHit.HiFrom + LTS.Tokens[LFrom.TokenIndex].Len;
  // A name written over several lines (or files) highlights its first
  // segment alone.
  if LTo.FileId = LFrom.FileId then
  begin
    LTS.OffsetToLineCol(LTS.Tokens[LTo.TokenIndex].EndPos, LLineTo, LColTo);
    if LLineTo = AHit.Line then
      AHit.HiTo := LColTo - 1;
  end;
  Result := True;
end;

// The words of LM's branches not compiled here, lower case -> the first
// place each is written. Only the unit's own files (FileId 0 and its
// includes): a library include's dead branches say nothing of this unit.
function SkippedWordPlaces(LM: TPasSemaModel): TDictionary<string, TLintPlace>;
var
  LText, LWord: string;
  LAt, LEnd, LCol: Integer;
  LPlace: TLintPlace;
begin
  Result := TDictionary<string, TLintPlace>.Create;
  for var LFi := 0 to Min(High(LM.Tree.Source.Skipped),
    High(LM.Tree.Source.Files)) do
    for var LR in LM.Tree.Source.Skipped[LFi] do
    begin
      LText := Copy(LM.Tree.Source.Files[LFi].Source, LR.Start + 1,
        LR.EndPos - LR.Start);
      LAt := 1;
      while LAt <= Length(LText) do
      begin
        if not IsIdentChar(LText[LAt]) or ((LAt > 1) and
          IsIdentChar(LText[LAt - 1])) then
        begin
          Inc(LAt);
          Continue;
        end;
        LEnd := LAt;
        while (LEnd <= Length(LText)) and IsIdentChar(LText[LEnd]) do
          Inc(LEnd);
        LWord := LowerCase(Copy(LText, LAt, LEnd - LAt));
        if not Result.ContainsKey(LWord) then
        begin
          LM.Tree.Source.Files[LFi].OffsetToLineCol(LR.Start + LAt - 1,
            LPlace.Line, LCol);
          LPlace.FilePath := LM.Tree.Source.FileNames[LFi];
          Result.Add(LWord, LPlace);
        end;
        LAt := LEnd;
      end;
    end;
end;

// The identifiers of LM bound to nothing, lower case -> the first node: a
// name the index could not resolve may be one of a unit called unused. A
// member name after a dot is left out - the unit of its base decides it.
function UnboundWords(LM: TPasSemaModel): TDictionary<string, Integer>;
var
  LP, LMod: Integer;
  LSkip: TArray<TPair<Integer, Integer>>;   // token ranges: the module's
                                            // name, its uses clauses
  LOut: Boolean;
begin
  Result := TDictionary<string, Integer>.Create;
  LSkip := nil;
  LMod := ModuleNode(LM);
  if LMod <> NIL_NODE then
    LP := LM.Tree.Nodes[LMod].FirstChild
  else
    LP := NIL_NODE;
  if LP <> NIL_NODE then
    LSkip := LSkip + [TPair<Integer, Integer>.Create(
      LM.Tree.Nodes[LP].FirstToken, LM.Tree.Nodes[LP].LastToken)];
  for var LNode := 0 to High(LM.Tree.Nodes) do
    if LM.Tree.Nodes[LNode].Kind = nkUsesClause then
      LSkip := LSkip + [TPair<Integer, Integer>.Create(
        LM.Tree.Nodes[LNode].FirstToken, LM.Tree.Nodes[LNode].LastToken)];
  for var LNode := 0 to Min(High(LM.Tree.Nodes), High(LM.RefMap)) do
  begin
    if LM.Tree.Nodes[LNode].Kind <> nkIdent then
      Continue;
    LOut := False;
    for var LR in LSkip do
      if (LM.Tree.Nodes[LNode].FirstToken >= LR.Key) and
         (LM.Tree.Nodes[LNode].FirstToken <= LR.Value) then
        LOut := True;
    if LOut or (nfName in LM.Tree.Nodes[LNode].Flags) or
       (LM.RefMap[LNode] <> NIL_SYM) or LM.ExtRefMap.ContainsKey(LNode) then
      Continue;
    LP := LM.Tree.Nodes[LNode].Parent;
    if (LP <> NIL_NODE) and (LM.Tree.Nodes[LP].FirstChild <> LNode) and
       (LM.Tree.Nodes[LP].Kind = nkMember) then
      Continue;
    if (LP <> NIL_NODE) and (LM.Tree.Nodes[LP].FirstChild = LNode) and
       (LM.Tree.Nodes[LP].Kind in [nkNamedArg, nkAggregateField]) then
      Continue;
    Result.TryAdd(LowerCase(LM.Tree.NodeText(LNode)), LNode);
  end;
end;

{ TUsesLint }

constructor TUsesLint.Create(ANav: TPasNavigator);
var
  LM: TPasSemaModel;
  LMod: Integer;
begin
  inherited Create;
  FNav := ANav;
  FProj := ANav.Project;
  FInline := TDictionary<Int64, TArray<Integer>>.Create;
  FAccessors := TDictionary<Int64, TArray<Int64>>.Create;
  FNames := TObjectDictionary<Integer, TDictionary<string, Integer>>.Create(
    [doOwnsValues]);
  FEffect := TDictionary<Integer, string>.Create;
  FReach := TDictionary<Integer, TArray<Boolean>>.Create;
  FRows := TList<TPasUnusedUse>.Create;
  FDeadEdges := TDictionary<Int64, Boolean>.Create;
  FGlobalInit := TDictionary<Integer, Boolean>.Create;
  for var LMid := 0 to FProj.ModelCount - 1 do
  begin
    LM := FProj.Model(LMid);
    LMod := ModuleNode(LM);
    if (LMod <> NIL_NODE) and
       (LM.Tree.Nodes[LMod].Kind in [nkProgram, nkLibrary, nkPackage]) then
      FRoots := FRoots + [LMid];
  end;
end;

destructor TUsesLint.Destroy;
begin
  FGlobalInit.Free;
  FAccessors.Free;
  FInline.Free;
  FDeadEdges.Free;
  FRows.Free;
  FReach.Free;
  FEffect.Free;
  FNames.Free;
  inherited;
end;

function TUsesLint.UnitNameOf(AMid: Integer): string;
begin
  Result := TPath.GetFileNameWithoutExtension(FProj.ModelFile(AMid));
end;

function TUsesLint.NamesOf(AMid: Integer): TDictionary<string, Integer>;
var
  UM: TPasSemaModel;
  LNames: TDictionary<string, Integer>;
begin
  if FNames.TryGetValue(AMid, Result) then
    Exit;
  LNames := TDictionary<string, Integer>.Create;
  FNames.Add(AMid, LNames);
  Result := LNames;
  UM := FProj.Model(AMid);
  if (UM.InterfaceScope < 0) or (UM.InterfaceScope >= UM.Scopes.Count) then
    Exit;
  UM.EnumScopeDeep(UM.InterfaceScope,
    procedure(ASym, AScope: Integer)
    begin
      if (UM.Scopes[AScope].Kind in [sckUnit, sckEnum]) and
         (UM.Symbols[ASym].Kind <> skUnitRef) then
        LNames.TryAdd(UM.Symbols[ASym].NameLower, ASym);
    end);
end;

// What linking AMid into a program does by itself, '' for nothing: it has
// initialization or finalization code, or links a resource in.
function TUsesLint.LinkEffect(AMid: Integer): string;
var
  LM: TPasSemaModel;
  LSec: Integer;
  LText: string;
begin
  if FEffect.TryGetValue(AMid, Result) then
    Exit;
  LM := FProj.Model(AMid);
  Result := '';
  LSec := ModuleChild(LM, nkInitSec);
  if (LSec <> NIL_NODE) and HasStatements(LM, LSec) then
    Result := 'initialization';
  LSec := ModuleChild(LM, nkFinalSec);
  if (Result = '') and (LSec <> NIL_NODE) and HasStatements(LM, LSec) then
    Result := 'finalization';
  // `{$R WindowsXP.res}` - Vcl.XPMan does nothing else. A form file's
  // `{$R *.dfm}` is not counted: its class is what a program would use.
  if Result = '' then
  begin
    try
      LText := TFile.ReadAllText(FProj.ModelFile(AMid));
    except
      LText := '';
    end;
    for var LMatch in TRegEx.Matches(LText,
      '\{\$(R|RESOURCE)\s+([^}]*)\}', [roIgnoreCase]) do
      if not TRegEx.IsMatch(LMatch.Groups[2].Value,
        '^\s*[+-]|\*\.(dfm|fmx|xfm)', [roIgnoreCase]) then
      begin
        Result := 'a resource';
        Break;
      end;
  end;
  FEffect.Add(AMid, Result);
end;

// Whether a binding to AExt needs its unit in `uses`: a unit-level
// declaration of its interface, an enum value, a helper's member - not a
// member reached through a value or a type.
function TUsesLint.NeedsItsUnit(const AExt: TPasExtRef): Boolean;
var
  UM: TPasSemaModel;
  LScope, LOwner: Integer;
begin
  Result := False;
  if (AExt.UnitId < 0) or (AExt.UnitId >= FProj.ModelCount) then
    Exit;
  UM := FProj.Model(AExt.UnitId);
  if (AExt.Sym < 0) or (AExt.Sym >= UM.SymCount) then
    Exit;
  LScope := UM.Symbols[AExt.Sym].Scope;
  if (LScope < 0) or (LScope >= UM.Scopes.Count) then
    Exit;
  case UM.Scopes[LScope].Kind of
    sckUnit, sckEnum:
      Result := True;
    sckStruct:
      begin
        LOwner := UM.Scopes[LScope].OwnerNode;
        Result := (LOwner >= 0) and (LOwner <= High(UM.Tree.Nodes)) and
          (UM.Tree.Nodes[LOwner].Kind = nkHelperType);
      end;
  end;
end;

procedure TUsesLint.BuildGraph;
var
  LN, LTo: Integer;
  LFill: TArray<Integer>;
  LM: TPasSemaModel;
begin
  if FStart <> nil then
    Exit;
  LN := FProj.ModelCount;
  SetLength(FStart, LN + 1);
  for var LMid := 0 to LN - 1 do
  begin
    LM := FProj.Model(LMid);
    for var LU := 0 to High(LM.UsesList) do
    begin
      LTo := LM.UsesList[LU].UnitId;
      if (LTo >= 0) and (LTo < LN) then
        Inc(FStart[LMid + 1]);
    end;
  end;
  for var LI := 1 to LN do
    Inc(FStart[LI], FStart[LI - 1]);
  SetLength(FEdges, FStart[LN]);
  LFill := Copy(FStart);
  for var LMid := 0 to LN - 1 do
  begin
    LM := FProj.Model(LMid);
    for var LU := 0 to High(LM.UsesList) do
    begin
      LTo := LM.UsesList[LU].UnitId;
      if (LTo >= 0) and (LTo < LN) then
      begin
        FEdges[LFill[LMid]] := LTo;
        Inc(LFill[LMid]);
      end;
    end;
  end;
end;

// The units ARoot reaches through `uses`, the edge ASkipFrom -> ASkipTo left
// out (-1: none). nil when ASkipTo is reached all the same: whatever the edge
// led to is then reached through another path, and nothing is lost.
function TUsesLint.ReachOf(ARoot, ASkipFrom, ASkipTo: Integer): TArray<Boolean>;
var
  LQueue: TList<Integer>;
  LAt, LU: Integer;
begin
  BuildGraph;
  Result := nil;
  SetLength(Result, FProj.ModelCount);
  LQueue := TList<Integer>.Create;
  try
    Result[ARoot] := True;
    LQueue.Add(ARoot);
    LAt := 0;
    while LAt < LQueue.Count do
    begin
      LU := LQueue[LAt];
      for var LE := FStart[LU] to FStart[LU + 1] - 1 do
        if not Result[FEdges[LE]] and
           not ((LU = ASkipFrom) and (FEdges[LE] = ASkipTo)) then
        begin
          if (ASkipTo >= 0) and (FEdges[LE] = ASkipTo) then
            Exit(nil);
          Result[FEdges[LE]] := True;
          LQueue.Add(FEdges[LE]);
        end;
      Inc(LAt);
    end;
  finally
    LQueue.Free;
  end;
end;

function TUsesLint.FullReach(ARoot: Integer): TArray<Boolean>;
begin
  if not FReach.TryGetValue(ARoot, Result) then
  begin
    Result := ReachOf(ARoot, -1, -1);
    FReach.Add(ARoot, Result);
  end;
end;

// The units with an effect AStart reaches through the units in ALost,
// 'Name (initialization)'.
function TUsesLint.EffectsFrom(AStart: Integer;
  const ALost: TArray<Boolean>): TArray<string>;
var
  LSeen: TArray<Boolean>;
  LQueue: TList<Integer>;
  LAt, LU: Integer;
begin
  Result := nil;
  SetLength(LSeen, FProj.ModelCount);
  LQueue := TList<Integer>.Create;
  try
    LSeen[AStart] := True;
    LQueue.Add(AStart);
    LAt := 0;
    while LAt < LQueue.Count do
    begin
      LU := LQueue[LAt];
      if LinkEffect(LU) <> '' then
        Result := Result + [Format('%s (%s)', [UnitNameOf(LU),
          LinkEffect(LU)])];
      for var LE := FStart[LU] to FStart[LU + 1] - 1 do
        if ALost[FEdges[LE]] and not LSeen[FEdges[LE]] then
        begin
          LSeen[FEdges[LE]] := True;
          LQueue.Add(FEdges[LE]);
        end;
      Inc(LAt);
    end;
  finally
    LQueue.Free;
  end;
end;

// 'removing it leaves X (initialization) out of P', '' when it leaves
// nothing with an effect out. With no program in the analysis (a directory
// of units) only the listed unit's own effect is known.
function TUsesLint.DropsText(AFrom, ATo: Integer): string;
var
  LFull, LLess, LLost: TArray<Boolean>;
  LUnits, LPrograms, LEffects: TArray<string>;
begin
  Result := '';
  if FRoots = nil then
  begin
    if LinkEffect(ATo) <> '' then
      Result := Format('%s has %s - a program may need it linked in',
        [UnitNameOf(ATo), LinkEffect(ATo)]);
    Exit;
  end;
  LUnits := nil;
  LPrograms := nil;
  for var LRoot in FRoots do
  begin
    LFull := FullReach(LRoot);
    if not LFull[AFrom] then
      Continue;
    LLess := ReachOf(LRoot, AFrom, ATo);
    if LLess = nil then
      Continue;
    SetLength(LLost, Length(LFull));
    for var LMid := 0 to High(LFull) do
      LLost[LMid] := LFull[LMid] and not LLess[LMid];
    LEffects := EffectsFrom(ATo, LLost);
    for var LU in LEffects do
      if not MatchText(LU, LUnits) then
        LUnits := LUnits + [LU];
    if (LEffects <> nil) and not MatchText(UnitNameOf(LRoot), LPrograms) then
      LPrograms := LPrograms + [UnitNameOf(LRoot)];
  end;
  if LUnits <> nil then
    Result := Format('removing it leaves %s out of %s', [NamedList(LUnits,
      MAX_NAMED), NamedList(LPrograms, MAX_NAMED)]);
end;

// Whether AMid's initialization reaches outside the unit - see
// TPasLintOption. The section's subtree is walked, and the body of every
// routine of the unit it calls, to any depth; a binding to another unit
// decides by what it binds to.
function TUsesLint.GlobalInit(AMid: Integer): Boolean;
var
  LM, UM: TPasSemaModel;
  LSec, LNode, LChild, LScope, LBody: Integer;
  LStack: TList<Integer>;
  LSeen: TDictionary<Integer, Boolean>;   // own routine symbols walked
  LExt: TPasExtRef;
  LSym: Integer;

  // Whether ANode is the member name of `Q.Name` with Q a TYPE (`TReg.Add`,
  // `Unit.TReg.Add`) - a class member, reached without an object; a member
  // reached through a variable (`FList.Add`) is not.
  function TypeQualified(ANode: Integer): Boolean;
  var
    LP, LQ, LC: Integer;
    LQExt: TPasExtRef;
  begin
    Result := False;
    LP := LM.Tree.Nodes[ANode].Parent;
    if (LP = NIL_NODE) or (LM.Tree.Nodes[LP].Kind <> nkMember) or
       (LM.Tree.Nodes[LP].FirstChild = ANode) then
      Exit;
    LQ := LM.Tree.Nodes[LP].FirstChild;
    // A qualified qualifier: its last segment.
    while (LQ <> NIL_NODE) and (LM.Tree.Nodes[LQ].Kind = nkMember) do
    begin
      LC := LM.Tree.Nodes[LQ].FirstChild;
      while (LC <> NIL_NODE) and (LM.Tree.Nodes[LC].NextSibling <> NIL_NODE) do
        LC := LM.Tree.Nodes[LC].NextSibling;
      LQ := LC;
    end;
    if LQ = NIL_NODE then
      Exit;
    if LM.ExtRefMap.TryGetValue(LQ, LQExt) then
      Result := (LQExt.UnitId >= 0) and (LQExt.UnitId < FProj.ModelCount) and
        (LQExt.Sym >= 0) and (LQExt.Sym < FProj.Model(LQExt.UnitId).SymCount) and
        (FProj.Model(LQExt.UnitId).Symbols[LQExt.Sym].Kind = skType)
    else if (LQ <= High(LM.RefMap)) and (LM.RefMap[LQ] <> NIL_SYM) and
       (LM.RefMap[LQ] < LM.SymCount) then
      Result := LM.Symbols[LM.RefMap[LQ]].Kind = skType;
  end;

  // A binding of ANode to another unit that acts on that unit's state.
  function Outside(ANode: Integer; const AExt: TPasExtRef): Boolean;
  begin
    Result := False;
    if (AExt.UnitId < 0) or (AExt.UnitId >= FProj.ModelCount) or
       (AExt.UnitId = AMid) then
      Exit;
    UM := FProj.Model(AExt.UnitId);
    if (AExt.Sym < 0) or (AExt.Sym >= UM.SymCount) then
      Exit;
    LScope := UM.Symbols[AExt.Sym].Scope;
    if (LScope < 0) or (LScope >= UM.Scopes.Count) then
      Exit;
    case UM.Scopes[LScope].Kind of
      sckUnit:
        Result := UM.Symbols[AExt.Sym].Kind in [skVar, skRoutine];
      // A class method, class var or class property: by the type's name.
      // (No symbol flag says `class` - sfClassMember is never set.)
      sckStruct:
        Result := (UM.Symbols[AExt.Sym].Kind in [skVar, skField, skRoutine,
          skProperty]) and
          not FProj.IsConstructorSym(AExt.UnitId, AExt.Sym) and
          TypeQualified(ANode);
    end;
  end;

begin
  if FGlobalInit.TryGetValue(AMid, Result) then
    Exit;
  Result := False;
  // Nodes and both maps only, as LinkEffect and AddNodeUnits: a
  // text-demoted model answers without hydrating (RoutineImplNode hydrates
  // what it pairs).
  LM := FProj.Model(AMid);
  LSec := ModuleChild(LM, nkInitSec);
  if (LSec <> NIL_NODE) and HasStatements(LM, LSec) then
  begin
    LStack := TList<Integer>.Create;
    LSeen := TDictionary<Integer, Boolean>.Create;
    try
      LStack.Add(LSec);
      while (LStack.Count > 0) and not Result do
      begin
        LNode := LStack.Last;
        LStack.Delete(LStack.Count - 1);
        if LM.ExtRefMap.TryGetValue(LNode, LExt) then
          Result := Outside(LNode, LExt)
        else if LNode <= High(LM.RefMap) then
        begin
          // A routine of this unit: its body runs too.
          LSym := LM.RefMap[LNode];
          if (LSym <> NIL_SYM) and (LSym < LM.SymCount) and
             (LM.Symbols[LSym].Kind = skRoutine) and
             not LSeen.ContainsKey(LSym) then
          begin
            LSeen.Add(LSym, True);
            LBody := FNav.RoutineImplNode(AMid, LSym);
            if LBody <> NIL_NODE then
              LStack.Add(LBody);
          end;
        end;
        LChild := LM.Tree.Nodes[LNode].FirstChild;
        while LChild <> NIL_NODE do
        begin
          LStack.Add(LChild);
          LChild := LM.Tree.Nodes[LChild].NextSibling;
        end;
      end;
    finally
      LSeen.Free;
      LStack.Free;
    end;
  end;
  FGlobalInit.Add(AMid, Result);
end;

// Whether removing AFrom's entry for ATo leaves a unit with a global
// initialization out of a program - ATo itself, or one only it brought in.
// With no program in the analysis, ATo's own.
function TUsesLint.DropsGlobalInit(AFrom, ATo: Integer): Boolean;
var
  LFull, LLess: TArray<Boolean>;
begin
  if FRoots = nil then
    Exit(GlobalInit(ATo));
  for var LRoot in FRoots do
  begin
    LFull := FullReach(LRoot);
    if not LFull[AFrom] then
      Continue;
    LLess := ReachOf(LRoot, AFrom, ATo);
    if LLess = nil then
      Continue;
    for var LMid := 0 to High(LFull) do
      if LFull[LMid] and not LLess[LMid] and GlobalInit(LMid) then
        Exit(True);
  end;
  Result := False;
end;

// What the program reaches through the edges FDeadEdges leaves.
function TUsesLint.LiveUnits: TArray<Boolean>;
var
  LQueue: TList<Integer>;
  LAt, LU, LN: Integer;

  function Dead(AFrom, ATo: Integer): Boolean;
  begin
    Result := FDeadEdges.ContainsKey((Int64(AFrom) shl 32) or Cardinal(ATo));
  end;

begin
  BuildGraph;
  LN := FProj.ModelCount;
  Result := nil;
  SetLength(Result, LN);
  if FRoots <> nil then
  begin
    LQueue := TList<Integer>.Create;
    try
      for var LRoot in FRoots do
      begin
        Result[LRoot] := True;
        LQueue.Add(LRoot);
      end;
      LAt := 0;
      while LAt < LQueue.Count do
      begin
        LU := LQueue[LAt];
        for var LE := FStart[LU] to FStart[LU + 1] - 1 do
          if not Result[FEdges[LE]] and not Dead(LU, FEdges[LE]) then
          begin
            Result[FEdges[LE]] := True;
            LQueue.Add(FEdges[LE]);
          end;
        Inc(LAt);
      end;
    finally
      LQueue.Free;
    end;
    Exit;
  end;
  // No program: nothing to reach from, so a unit is live while another unit
  // lists it and uses it. Not repeated: in a directory of units every unit
  // under a top one would drop with it, and the top ones are what the
  // directory is for.
  for LU := 0 to LN - 1 do
    for var LE := FStart[LU] to FStart[LU + 1] - 1 do
      if (FEdges[LE] <> LU) and not Dead(LU, FEdges[LE]) then
        Result[FEdges[LE]] := True;
end;

// The routine node a routine symbol's declaration sits in, NIL_NODE if none.
function RoutineNodeOf(LM: TPasSemaModel; ASym: Integer): Integer;
begin
  Result := LM.Symbols[ASym].DeclNode;
  while (Result <> NIL_NODE) and (LM.Tree.Nodes[Result].Kind <> nkRoutine) do
    Result := LM.Tree.Nodes[Result].Parent;
end;

// The units the bindings in ANode's subtree of model AMid belong to - a
// routine body left out (a declaration that holds its body gives its header).
// Nodes and both maps only: a text-demoted model answers too.
procedure TUsesLint.AddNodeUnits(AMid, ANode: Integer;
  AUnits: TDictionary<Integer, Boolean>);
var
  LM: TPasSemaModel;
  LStack: TList<Integer>;
  LNode, LChild: Integer;
  LExt: TPasExtRef;
begin
  if ANode = NIL_NODE then
    Exit;
  LM := FProj.Model(AMid);
  LStack := TList<Integer>.Create;
  try
    LStack.Add(ANode);
    while LStack.Count > 0 do
    begin
      LNode := LStack.Last;
      LStack.Delete(LStack.Count - 1);
      if LM.ExtRefMap.TryGetValue(LNode, LExt) then
        AUnits.AddOrSetValue(LExt.UnitId, True)
      else if (LNode <= High(LM.RefMap)) and (LM.RefMap[LNode] <> NIL_SYM) then
        AUnits.AddOrSetValue(AMid, True);
      LChild := LM.Tree.Nodes[LNode].FirstChild;
      while LChild <> NIL_NODE do
      begin
        if LM.Tree.Nodes[LChild].Kind <> nkRoutineBody then
          LStack.Add(LChild);
        LChild := LM.Tree.Nodes[LChild].NextSibling;
      end;
    end;
  finally
    LStack.Free;
  end;
end;

// The units of what a symbol's declaration names as its type: a routine's
// parameter and result types, a variable's, field's, parameter's, constant's
// or property's declared type. An inline body binding `GetY` needs the unit
// of GetY's result type though it names no symbol of it (`O := GetY`, probe
// UX3 in local/probe-inline: H2443 naming that unit).
procedure TUsesLint.AddTypeUnits(AMid, ASym: Integer;
  AUnits: TDictionary<Integer, Boolean>);
var
  LM: TPasSemaModel;
begin
  LM := FProj.Model(AMid);
  case LM.Symbols[ASym].Kind of
    skRoutine:
      AddNodeUnits(AMid, RoutineNodeOf(LM, ASym), AUnits);
    skVar, skConst, skField, skParam, skProperty:
      AddNodeUnits(AMid, LM.Symbols[ASym].TypeNode, AUnits);
  end;
end;

// A property's accessors marked inline (model shl 32 or symbol): the
// routines its `read`/`write` specifiers bind. A republished property
// (`property Caption;`) has none of its own and takes its ancestor's.
function TUsesLint.InlineAccessors(AMid, ASym: Integer): TArray<Int64>;
var
  LKey: Int64;
  LM, BM: TPasSemaModel;
  LMid, LSym, LDecl, LChild, LName, LPrevMid, LPrevSym: Integer;
  LExt: TPasExtRef;
  LBound: Boolean;
begin
  LKey := (Int64(AMid) shl 32) or Cardinal(ASym);
  if FAccessors.TryGetValue(LKey, Result) then
    Exit;
  Result := nil;
  for var LDepth := 1 to 16 do
  begin
    LM := FProj.Model(AMid);
    if LM.Symbols[ASym].DeclNode = NIL_NODE then
      Break;
    LDecl := LM.Tree.Nodes[LM.Symbols[ASym].DeclNode].Parent;
    if (LDecl = NIL_NODE) or (LM.Tree.Nodes[LDecl].Kind <> nkPropertyDecl) then
      Break;
    LBound := False;
    LChild := LM.Tree.Nodes[LDecl].FirstChild;
    while LChild <> NIL_NODE do
    begin
      LName := LM.Tree.Nodes[LChild].FirstChild;
      if (LM.Tree.Nodes[LChild].Kind = nkPropSpec) and (LName <> NIL_NODE) and
         (LM.Tree.Nodes[LName].Kind = nkIdent) then
      begin
        LMid := -1;
        LSym := NIL_SYM;
        if (LName <= High(LM.RefMap)) and (LM.RefMap[LName] <> NIL_SYM) then
        begin
          LMid := AMid;
          LSym := LM.RefMap[LName];
        end
        else if LM.ExtRefMap.TryGetValue(LName, LExt) then
        begin
          LMid := LExt.UnitId;
          LSym := LExt.Sym;
        end;
        if LMid >= 0 then
        begin
          BM := FProj.Model(LMid);
          if BM.Symbols[LSym].Kind in [skRoutine, skField] then
            LBound := True;
          if (BM.Symbols[LSym].Kind = skRoutine) and
             (sfInline in BM.Symbols[LSym].Flags) then
            Result := Result + [(Int64(LMid) shl 32) or Cardinal(LSym)];
        end;
      end;
      LChild := LM.Tree.Nodes[LChild].NextSibling;
    end;
    if LBound or not FProj.PropertyRedeclPrev(AMid, ASym, LPrevMid,
      LPrevSym) then
      Break;
    AMid := LPrevMid;
    ASym := LPrevSym;
  end;
  FAccessors.Add(LKey, Result);
end;

{ The units dcc needs in a caller's `uses` to expand a call of the inline
  routine ASym of model AMid: without one of them the call is compiled as a
  plain call and dcc says H2443 - the code changes, so the unit is used.
  Probed on dcc64 37.0 (local/probe-inline): every unit whose symbol the
  routine's declaration or body binds - a routine, a variable, a typed or a
  string constant, a type, a member reached through a value (`GetY.V`) -
  and the units of those symbols' declared types (`O := GetY`); the units an
  inline routine it calls needs (nested expansion), a property's inline
  getter included; units of the routine's implementation `uses` alike. An
  enum value folds into the code and asks for no unit; so do an ordinal
  constant, SizeOf and a cast of a constant, which this keeps (the error is
  on the safe side: a unit kept, never one called unused that is needed).
  The caller's `uses` must name each unit itself - one reaching it through
  another unit's `uses` does not do. }
function TUsesLint.InlineDeps(AMid, ASym: Integer): TArray<Integer>;
var
  LKey: Int64;
  LM: TPasSemaModel;
  LUnits: TDictionary<Integer, Boolean>;
  LNested: TList<Int64>;
  LStack: TList<Integer>;
  LDecl, LImpl, LNode, LChild: Integer;
  LExt: TPasExtRef;

  procedure Bind(ABMid, ABSym: Integer);
  var
    BM: TPasSemaModel;
  begin
    if (ABMid < 0) or (ABMid >= FProj.ModelCount) then
      Exit;
    BM := FProj.Model(ABMid);
    if (ABSym < 0) or (ABSym >= BM.SymCount) or
       (BM.Symbols[ABSym].Kind = skEnumValue) then
      Exit;
    LUnits.AddOrSetValue(ABMid, True);
    AddTypeUnits(ABMid, ABSym, LUnits);
    case BM.Symbols[ABSym].Kind of
      skRoutine:
        if sfInline in BM.Symbols[ABSym].Flags then
          LNested.Add((Int64(ABMid) shl 32) or Cardinal(ABSym));
      skProperty:
        LNested.AddRange(InlineAccessors(ABMid, ABSym));
    end;
  end;

  procedure Walk(ARoot: Integer);
  begin
    LStack.Clear;
    LStack.Add(ARoot);
    while LStack.Count > 0 do
    begin
      LNode := LStack.Last;
      LStack.Delete(LStack.Count - 1);
      if LM.ExtRefMap.TryGetValue(LNode, LExt) then
        Bind(LExt.UnitId, LExt.Sym)
      else if (LNode <= High(LM.RefMap)) and (LM.RefMap[LNode] <> NIL_SYM) then
        Bind(AMid, LM.RefMap[LNode]);
      LChild := LM.Tree.Nodes[LNode].FirstChild;
      while LChild <> NIL_NODE do
      begin
        LStack.Add(LChild);
        LChild := LM.Tree.Nodes[LChild].NextSibling;
      end;
    end;
  end;

begin
  LKey := (Int64(AMid) shl 32) or Cardinal(ASym);
  if FInline.TryGetValue(LKey, Result) then
    Exit;
  FInline.Add(LKey, nil);
  LUnits := TDictionary<Integer, Boolean>.Create;
  LNested := TList<Int64>.Create;
  LStack := TList<Integer>.Create;
  try
    LImpl := FNav.RoutineImplNode(AMid, ASym);
    LM := FProj.Model(AMid);
    LDecl := RoutineNodeOf(LM, ASym);
    if LDecl <> NIL_NODE then
      Walk(LDecl);
    if (LImpl <> NIL_NODE) and (LImpl <> LDecl) then
      Walk(LImpl);
    for var LInner in LNested do
      if LInner <> LKey then
        for var LU in InlineDeps(LInner shr 32, Integer(LInner and $FFFFFFFF)) do
          LUnits.AddOrSetValue(LU, True);
    Result := LUnits.Keys.ToArray;
  finally
    LStack.Free;
    LNested.Free;
    LUnits.Free;
  end;
  FInline[LKey] := Result;
end;

procedure TUsesLint.CheckUnit(AMid: Integer; AEdges: Boolean);
var
  LM: TPasSemaModel;
  LEntries: TList<TLintEntry>;
  LByName: TDictionary<string, Integer>;
  LByUnit, LBySym: TDictionary<Integer, Integer>;
  LOrphans: TList<TPair<Integer, TPasExtRef>>;
  LImplSec, LImplTok, LE, LNode, LSym, LLine: Integer;
  LInIface: Boolean;
  LEntry: TLintEntry;
  LKey, LName, LFile, LFormFile, LText: string;
  LDoc: IPasDfmDoc;
  LFormWords: TDictionary<string, Integer>;
  LUnbound: TDictionary<string, Integer>;
  LSkipped: TDictionary<string, TLintPlace>;
  LOverCalls: TDictionary<string, Integer>;   // called routine name -> a call
  LNames: TDictionary<string, Integer>;
  LInline: TDictionary<Integer, Boolean>;   // units inline expansions need
  LExtM: TPasSemaModel;
  LKeys: TArray<Int64>;
  LRow: TPasUnusedUse;

  procedure MarkUse(AIdx: Integer);
  var
    LX: TLintEntry;
  begin
    LX := LEntries[AIdx];
    LX.Used := True;
    LEntries[AIdx] := LX;
  end;

  procedure AddDoubt(AIdx: Integer; const AText: string);
  var
    LX: TLintEntry;
  begin
    LX := LEntries[AIdx];
    if MatchText(AText, LX.Doubts) then
      Exit;
    LX.Doubts := LX.Doubts + [AText];
    LEntries[AIdx] := LX;
  end;

begin
  if not FProj.EnsureHydrated(AMid) then
    Exit;
  LM := FProj.Model(AMid);
  // A program, a library, a package: its uses are its contents - but which
  // of them the build would still take in is a question of reach. A
  // package's `contains` is never optional.
  if (ModuleChild(LM, nkInterfaceSec) = NIL_NODE) and (not AEdges or
    (ModuleNode(LM) = NIL_NODE) or
    (LM.Tree.Nodes[ModuleNode(LM)].Kind in [nkUnit, nkPackage])) then
    Exit;
  LImplSec := ModuleChild(LM, nkImplementationSec);
  if LImplSec = NIL_NODE then
    LImplTok := MaxInt
  else
    LImplTok := LM.Tree.Nodes[LImplSec].FirstToken;
  LEntries := TList<TLintEntry>.Create;
  LByName := TDictionary<string, Integer>.Create;
  LByUnit := TDictionary<Integer, Integer>.Create;
  LBySym := TDictionary<Integer, Integer>.Create;
  LOrphans := TList<TPair<Integer, TPasExtRef>>.Create;
  LUnbound := nil;
  LSkipped := nil;
  LOverCalls := nil;
  LFormWords := nil;
  try
    for var LU in LM.UsesList do
    begin
      if (LU.UnitId < 0) or (LU.NameNode = NIL_NODE) then
        Continue;
      LKey := LowerCase(LU.NameFull);
      if LByName.ContainsKey(LKey) then
        Continue;   // listed twice (E2004): one entry
      LEntry := Default(TLintEntry);
      LEntry.Name := LU.NameFull;
      LEntry.NameNode := LU.NameNode;
      LEntry.UnitId := LU.UnitId;
      LEntry.Sym := LU.Sym;
      LEntry.InInterface := LM.Tree.Nodes[LU.NameNode].FirstToken < LImplTok;
      LE := LEntries.Add(LEntry);
      LByName.Add(LKey, LE);
      LByUnit.AddOrSetValue(LU.UnitId, LE);
      if LU.Sym <> NIL_SYM then
        LBySym.AddOrSetValue(LU.Sym, LE);
    end;
    if LEntries.Count = 0 then
      Exit;

    // What the unit binds to each entry. An interface name needs an
    // interface entry; the implementation sees both.
    for var LPair in LM.ExtRefMap do
    begin
      if not NeedsItsUnit(LPair.Value) then
        Continue;
      LInIface := LM.Tree.Nodes[LPair.Key].FirstToken < LImplTok;
      if LByUnit.TryGetValue(LPair.Value.UnitId, LE) and
         (LEntries[LE].InInterface or not LInIface) then
        MarkUse(LE)
      else if (LPair.Value.UnitId <> AMid) and not MatchText(FProj.Model(
        LPair.Value.UnitId).UnitNameLower, ['system', 'sysinit']) then
        LOrphans.Add(LPair);
    end;
    // A name bound to a unit not in `uses` came through one that is: an
    // alias of it there, which the index binds through to what it names; or
    // a name of the interface bound to a unit of the implementation `uses`.
    // Every listed unit declaring the name is credited.
    for var LPair in LOrphans do
    begin
      LName := FProj.Model(LPair.Value.UnitId).Symbols[
        LPair.Value.Sym].NameLower;
      LInIface := LM.Tree.Nodes[LPair.Key].FirstToken < LImplTok;
      for LE := 0 to LEntries.Count - 1 do
        if not LEntries[LE].Used and
           (LEntries[LE].InInterface or not LInIface) and
           NamesOf(LEntries[LE].UnitId).ContainsKey(LName) then
          MarkUse(LE);
    end;
    // `Unit.Name`: the qualifier binds to the uses entry itself.
    if LBySym.Count > 0 then
      for LNode := 0 to High(LM.RefMap) do
      begin
        LSym := LM.RefMap[LNode];
        if (LSym <> NIL_SYM) and LBySym.TryGetValue(LSym, LE) and
           not LEntries[LE].Used and not InUsesClause(LM, LNode) then
          MarkUse(LE);
      end;
    // The unit's form file naming a declaration of a listed unit - a
    // component class, a link to another module's component (`PopupMenu =
    // dmData.pmMain`) - uses it: the designer keeps such a unit in `uses`,
    // and a class a form streams must be linked in.
    LFile := FProj.ModelFile(AMid);
    for var LExt in ['.dfm', '.fmx'] do
      if (LFormWords = nil) and FileExists(ChangeFileExt(LFile, LExt)) then
      begin
        LDoc := PasDfmLoad(ChangeFileExt(LFile, LExt));
        if (LDoc = nil) or (LDoc.Doc.Error <> '') then
          Continue;
        LFormFile := ChangeFileExt(LFile, LExt);
        LFormWords := TDictionary<string, Integer>.Create;
        for var LI := 0 to High(LDoc.Doc.Idents) do
          if (LDoc.Doc.Idents[LI].Role = dirClassName) or
             ((LDoc.Doc.Idents[LI].Role = dirValue) and
             (LDoc.Doc.Idents[LI].Seg = 0) and
             (LDoc.Doc.Idents[LI].SegCount > 1)) then
            LFormWords.TryAdd(LowerCase(LDoc.Doc.IdentText(LI)),
              LDoc.Doc.LineOf(LDoc.Doc.Idents[LI].Offset));
      end;
    if LFormWords <> nil then
      for LE := 0 to LEntries.Count - 1 do
        if not LEntries[LE].Used then
        begin
          LNames := NamesOf(LEntries[LE].UnitId);
          for var LW in LFormWords do
            if LNames.ContainsKey(LW.Key) then
            begin
              MarkUse(LE);
              Break;
            end;
        end;
    // A unit the expansion of an inline routine called here needs - read or
    // written through a property too. Asked only while an entry is left: a
    // body's pairing hydrates the model declaring it.
    LInline := nil;
    for LEntry in LEntries do
      if not LEntry.Used then
      begin
        LInline := TDictionary<Integer, Boolean>.Create;
        Break;
      end;
    if LInline <> nil then
    begin
      for var LPair in LM.ExtRefMap do
      begin
        LExtM := FProj.Model(LPair.Value.UnitId);
        if (LPair.Value.Sym < 0) or (LPair.Value.Sym >= LExtM.SymCount) then
          Continue;
        LKeys := nil;
        case LExtM.Symbols[LPair.Value.Sym].Kind of
          skRoutine:
            if sfInline in LExtM.Symbols[LPair.Value.Sym].Flags then
              LKeys := [(Int64(LPair.Value.UnitId) shl 32) or
                Cardinal(LPair.Value.Sym)];
          skProperty:
            LKeys := InlineAccessors(LPair.Value.UnitId, LPair.Value.Sym);
        end;
        for var LK in LKeys do
          for var LU in InlineDeps(LK shr 32, Integer(LK and $FFFFFFFF)) do
            LInline.AddOrSetValue(LU, True);
      end;
      for LE := 0 to LEntries.Count - 1 do
        if not LEntries[LE].Used and LInline.ContainsKey(LEntries[LE].UnitId)
        then
          MarkUse(LE);
    end;

    // What may make a removal wrong.
    for LE := 0 to LEntries.Count - 1 do
    begin
      if LEntries[LE].Used then
        Continue;
      LEntry := LEntries[LE];
      LNames := NamesOf(LEntry.UnitId);
      if LUnbound = nil then
        LUnbound := UnboundWords(LM);
      if LSkipped = nil then
        LSkipped := SkippedWordPlaces(LM);
      // A name bound to nothing here that the unit declares.
      for var LW in LUnbound do
        if LNames.ContainsKey(LW.Key) then
        begin
          NodePlace(LM, LW.Value, LText, LLine);
          AddDoubt(LE, Format('`%s` at %s:%d is bound to nothing and %s ' +
            'declares it', [LM.Tree.NodeText(LW.Value),
            ExtractFileName(LText), LLine, LEntry.Name]));
        end;
      // A branch not compiled here naming the unit or a name of it.
      LName := LowerCase(LEntry.Name);
      if LName.Contains('.') then
        LName := Copy(LName, LName.LastIndexOf('.') + 2, MaxInt);
      for var LW in LSkipped do
        if LNames.ContainsKey(LW.Key) or (LW.Key = LName) then
          AddDoubt(LE, Format('a branch not compiled here names `%s` at ' +
            '%s:%d', [LW.Key, ExtractFileName(LW.Value.FilePath),
            LW.Value.Line]));
      // A routine of another unit called here that this unit declares too:
      // dcc picks among the overloads of every unit in scope, and PasTree's
      // pick may not be its.
      if LOverCalls = nil then
      begin
        LOverCalls := TDictionary<string, Integer>.Create;
        for var LPair in LM.ExtRefMap do
          if NeedsItsUnit(LPair.Value) and (FProj.Model(
            LPair.Value.UnitId).Symbols[LPair.Value.Sym].Kind = skRoutine) then
            LOverCalls.TryAdd(FProj.Model(LPair.Value.UnitId).Symbols[
              LPair.Value.Sym].NameLower, LPair.Key);
      end;
      for var LW in LOverCalls do
        if LNames.TryGetValue(LW.Key, LSym) and
           (FProj.Model(LEntry.UnitId).Symbols[LSym].Kind = skRoutine) then
        begin
          NodePlace(LM, LW.Value, LText, LLine);
          AddDoubt(LE, Format('it declares an overload of `%s`, called at ' +
            '%s:%d - removed, the call may take another overload',
            [LM.Tree.NodeText(LW.Value), ExtractFileName(LText), LLine]));
        end;
      if not AEdges then
      begin
        LText := DropsText(AMid, LEntry.UnitId);
        if LText <> '' then
          AddDoubt(LE, LText);
      end;
    end;

    if AEdges then
    begin
      for LEntry in LEntries do
        // A unit with a global initialization stays reached: the program
        // keeps it for what it registers, and so keeps what it lists.
        if not LEntry.Used and (LEntry.Doubts = nil) and
           not ((loHideGlobalInit in FOptions) and
           GlobalInit(LEntry.UnitId)) then
          FDeadEdges.AddOrSetValue((Int64(AMid) shl 32) or
            Cardinal(LEntry.UnitId), True);
      Exit;
    end;
    for LEntry in LEntries do
    begin
      if LEntry.Used or not EntryHit(LM, LEntry.NameNode, LRow.Hit) then
        Continue;
      // The entry's own unit whether or not the program still reaches it
      // another way: it is in this `uses` for what it registers.
      if (loHideGlobalInit in FOptions) and
         (GlobalInit(LEntry.UnitId) or
         DropsGlobalInit(AMid, LEntry.UnitId)) then
        Continue;
      LRow.UnitName := LEntry.Name;
      LRow.InInterface := LEntry.InInterface;
      LRow.Doubts := LEntry.Doubts;
      FRows.Add(LRow);
    end;
  finally
    LFormWords.Free;
    LOverCalls.Free;
    LSkipped.Free;
    LUnbound.Free;
    LOrphans.Free;
    LBySym.Free;
    LByUnit.Free;
    LByName.Free;
    LEntries.Free;
  end;
end;

function FindUnreferencedUnits(ANav: TPasNavigator;
  const AMids: TArray<Integer>;
  AOptions: TPasLintOptions): TArray<TPasUnreferencedUnit>;

  // Whether AMid, or a unit only it brings into the program (not live),
  // has a global initialization.
  function BringsGlobalInit(ALint: TUsesLint; AMid: Integer;
    const ALive: TArray<Boolean>): Boolean;
  var
    LSeen: TArray<Boolean>;
    LQueue: TList<Integer>;
    LAt, LU: Integer;
  begin
    Result := False;
    SetLength(LSeen, Length(ALive));
    LQueue := TList<Integer>.Create;
    try
      LSeen[AMid] := True;
      LQueue.Add(AMid);
      LAt := 0;
      while (LAt < LQueue.Count) and not Result do
      begin
        LU := LQueue[LAt];
        Result := ALint.GlobalInit(LU);
        for var LE := ALint.FStart[LU] to ALint.FStart[LU + 1] - 1 do
          if not ALive[ALint.FEdges[LE]] and not LSeen[ALint.FEdges[LE]] then
          begin
            LSeen[ALint.FEdges[LE]] := True;
            LQueue.Add(ALint.FEdges[LE]);
          end;
        Inc(LAt);
      end;
    finally
      LQueue.Free;
    end;
  end;

var
  LLint: TUsesLint;
  LLive: TArray<Boolean>;
  LRows: TList<TPasUnreferencedUnit>;
  LRow: TPasUnreferencedUnit;
  LM: TPasSemaModel;
  LMod, LName: Integer;
  LProj: TPasSemaProject;
  LSeeds: TArray<Integer>;
  LQueue: TList<Integer>;
  LAt, LU: Integer;
begin
  LProj := ANav.Project;
  LLint := TUsesLint.Create(ANav);
  LRows := TList<TPasUnreferencedUnit>.Create;
  try
    LLint.FOptions := AOptions;
    for var LRoot in LLint.FRoots do
      LLint.CheckUnit(LRoot, True);
    for var LMid in AMids do
      if (LMid >= 0) and (LMid < LProj.ModelCount) then
        LLint.CheckUnit(LMid, True);
    LLive := LLint.LiveUnits;
    // A unit kept for its global initialization - its own, or one only it
    // brings in - is not reported, and it keeps what it really uses: the
    // seeds first (against the live set as computed), then their reach over
    // the edges that are not dead.
    if loHideGlobalInit in AOptions then
    begin
      LSeeds := nil;
      for var LMid in AMids do
        if (LMid >= 0) and (LMid < LProj.ModelCount) and not LLive[LMid] and
           BringsGlobalInit(LLint, LMid, LLive) then
          LSeeds := LSeeds + [LMid];
      LQueue := TList<Integer>.Create;
      try
        for var LMid in LSeeds do
        begin
          LLive[LMid] := True;
          LQueue.Add(LMid);
        end;
        LAt := 0;
        while LAt < LQueue.Count do
        begin
          LU := LQueue[LAt];
          for var LE := LLint.FStart[LU] to LLint.FStart[LU + 1] - 1 do
            if not LLive[LLint.FEdges[LE]] and
               not LLint.FDeadEdges.ContainsKey((Int64(LU) shl 32) or
               Cardinal(LLint.FEdges[LE])) then
            begin
              LLive[LLint.FEdges[LE]] := True;
              LQueue.Add(LLint.FEdges[LE]);
            end;
          Inc(LAt);
        end;
      finally
        LQueue.Free;
      end;
    end;
    for var LMid in AMids do
    begin
      if (LMid < 0) or (LMid >= LProj.ModelCount) or LLive[LMid] or
         not LProj.EnsureHydrated(LMid) then
        Continue;
      LM := LProj.Model(LMid);
      LMod := ModuleNode(LM);
      if (LMod = NIL_NODE) or (LM.Tree.Nodes[LMod].Kind <> nkUnit) then
        Continue;
      LName := LM.Tree.Nodes[LMod].FirstChild;
      LRow := Default(TPasUnreferencedUnit);
      if (LName = NIL_NODE) or not EntryHit(LM, LName, LRow.Hit) then
        Continue;
      LRow.UnitName := LLint.UnitNameOf(LMid);
      // One row per listing file, named with its extension: a program's
      // `.dpr` and a unit's `.pas` are told apart at a glance.
      for var LFrom := 0 to LProj.ModelCount - 1 do
        for var LE := LLint.FStart[LFrom] to LLint.FStart[LFrom + 1] - 1 do
          if (LLint.FEdges[LE] = LMid) and (LFrom <> LMid) then
          begin
            if LLint.FDeadEdges.ContainsKey((Int64(LFrom) shl 32) or
              Cardinal(LMid)) then
              LRow.ListedBy := LRow.ListedBy + [ExtractFileName(
                LProj.ModelFile(LFrom)) + ' (no name of it used)']
            else
              LRow.ListedBy := LRow.ListedBy + [ExtractFileName(
                LProj.ModelFile(LFrom)) + ' (itself unreferenced)'];
            Break;   // listed twice (E2004): one row
          end;
      TArray.Sort<string>(LRow.ListedBy, TIStringComparer.Ordinal);
      if LLint.LinkEffect(LMid) <> '' then
        LRow.Doubts := [Format('it has %s - a unit can be listed only for ' +
          'what that registers', [LLint.LinkEffect(LMid)])];
      LRows.Add(LRow);
    end;
    Result := LRows.ToArray;
  finally
    LRows.Free;
    LLint.Free;
  end;
  TArray.Sort<TPasUnreferencedUnit>(Result,
    TComparer<TPasUnreferencedUnit>.Construct(
    function(const A, B: TPasUnreferencedUnit): Integer
    begin
      Result := CompareText(A.UnitName, B.UnitName);
      if Result = 0 then
        Result := CompareText(A.Hit.FilePath, B.Hit.FilePath);
    end));
end;

function FindUnusedUses(ANav: TPasNavigator;
  const AMids: TArray<Integer>;
  AOptions: TPasLintOptions): TArray<TPasUnusedUse>;
var
  LLint: TUsesLint;
begin
  LLint := TUsesLint.Create(ANav);
  try
    LLint.FOptions := AOptions;
    for var LMid in AMids do
      if (LMid >= 0) and (LMid < ANav.Project.ModelCount) then
        LLint.CheckUnit(LMid);
    Result := LLint.FRows.ToArray;
  finally
    LLint.Free;
  end;
  TArray.Sort<TPasUnusedUse>(Result, TComparer<TPasUnusedUse>.Construct(
    function(const A, B: TPasUnusedUse): Integer
    begin
      // By the listing file's name (a host groups by file, so one file's
      // rows stay together: the path breaks a tie of names), then by the
      // unused unit's name.
      Result := CompareText(ExtractFileName(A.Hit.FilePath),
        ExtractFileName(B.Hit.FilePath));
      if Result = 0 then
        Result := CompareText(A.Hit.FilePath, B.Hit.FilePath);
      if Result = 0 then
        Result := CompareText(A.UnitName, B.UnitName);
      if Result = 0 then
        Result := A.Hit.Line - B.Hit.Line;
      if Result = 0 then
        Result := A.Hit.Col - B.Hit.Col;
    end));
end;

end.
