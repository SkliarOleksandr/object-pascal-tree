unit PasTree.Sema.Nav;

{
  PasTree semantics — go-to-declaration over an analyzed TPasSemaProject.

  Maps an editor position (file, 1-based line/col) to the identifier token
  under it (IdentAt), and resolves that identifier to its declaration's
  file/line/col (ResolveDecl) through the resolver's RefMap (intra-unit) and
  the project's ExtRefMap (cross-unit — including the member references the
  Phase-3c cross typer discovers through ancestor chains and generics).

  Pure lookups over the immutable models; per-model lookup tables are built
  lazily and cached. Built for editor hosts: the demo today, an LSP later.
  Positions refer to the sources AS ANALYZED (on disk) — a host with unsaved
  edits must re-analyze before navigating.
}

interface

uses
  System.Generics.Collections,
  PasTree.Types,
  PasTree.Preprocessor,
  PasTree.Ast,
  PasTree.Sema.Model,
  PasTree.Sema.Project;

type
  // The identifier under a position, in a model's MAIN file (FileId 0).
  TPasNavIdent = record
    Node: Integer;       // nkIdent CST node index
    RawToken: Integer;   // raw token index in Files[0] (for highlighters)
    Line: Integer;       // 1-based line of the token start
    ColFrom: Integer;    // 1-based first column
    ColTo: Integer;      // 1-based column AFTER the token
    Name: string;
  end;

  TPasNavTarget = record
    UnitId: Integer;     // model id the declaration lives in
    FilePath: string;    // declaring source file (may be a $I include)
    Line: Integer;       // 1-based
    Col: Integer;        // 1-based
    Name: string;        // declared name (original spelling)
  end;

  TPasNavigator = class
  private type
    TNavCache = class
      VisOfRaw: TArray<Integer>;                 // raw idx -> visible idx | -1
      NodeOfVis: TDictionary<Integer, Integer>;  // visible idx -> nkIdent node
      destructor Destroy; override;
    end;
  private
    FProj: TPasSemaProject;
    FByPath: TDictionary<string, Integer>;       // full lower path -> model id
    FCaches: TObjectDictionary<Integer, TNavCache>;
    function CacheOf(AMid: Integer): TNavCache;
    function TargetFromNode(AMid, ANode: Integer; const AName: string;
      out ATarget: TPasNavTarget): Boolean;
    function FindInUsesDecl(AMid: Integer; const ANameLower: string;
      out ATMid, ASym: Integer): Boolean;
    function RoutineNameNodeOfSym(AMid, ASym: Integer): Integer;
  public
    constructor Create(AProject: TPasSemaProject);
    destructor Destroy; override;
    // Model id of an analyzed source file; -1 when the file wasn't analyzed.
    function ModelIdOf(const APath: string): Integer;
    // The identifier token at (line, col) of model AMid's main file.
    function IdentAt(AMid, ALine, ACol: Integer;
      out AIdent: TPasNavIdent): Boolean;
    // The declaration the identifier node resolved to. False for builtins
    // (no source declaration) and unresolved names.
    function ResolveDecl(AMid, ANode: Integer;
      out ATarget: TPasNavTarget): Boolean;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils;

{ TPasNavigator.TNavCache }

destructor TPasNavigator.TNavCache.Destroy;
begin
  NodeOfVis.Free;
  inherited;
end;

{ TPasNavigator }

constructor TPasNavigator.Create(AProject: TPasSemaProject);
var
  LMid: Integer;
begin
  inherited Create;
  FProj := AProject;
  FByPath := TDictionary<string, Integer>.Create;
  FCaches := TObjectDictionary<Integer, TNavCache>.Create([doOwnsValues]);
  for LMid := 0 to FProj.ModelCount - 1 do
    FByPath.AddOrSetValue(LowerCase(FProj.ModelFile(LMid)), LMid);
end;

destructor TPasNavigator.Destroy;
begin
  FCaches.Free;
  FByPath.Free;
  inherited;
end;

function TPasNavigator.ModelIdOf(const APath: string): Integer;
begin
  if not FByPath.TryGetValue(LowerCase(TPath.GetFullPath(APath)), Result) then
    Result := -1;
end;

function TPasNavigator.CacheOf(AMid: Integer): TNavCache;
var
  LM: TPasSemaModel;
  LIdx: Integer;
begin
  if FCaches.TryGetValue(AMid, Result) then
    Exit;
  Result := TNavCache.Create;
  LM := FProj.Model(AMid);
  SetLength(Result.VisOfRaw, Length(LM.Tree.Source.Files[0].Tokens));
  for LIdx := 0 to High(Result.VisOfRaw) do
    Result.VisOfRaw[LIdx] := -1;
  for LIdx := 0 to High(LM.Tree.Source.Visible) do
    if LM.Tree.Source.Visible[LIdx].FileId = 0 then
      Result.VisOfRaw[LM.Tree.Source.Visible[LIdx].TokenIndex] := LIdx;
  // nkIdent nodes are single-token; FirstToken is the visible index.
  Result.NodeOfVis := TDictionary<Integer, Integer>.Create;
  for LIdx := 0 to High(LM.Tree.Nodes) do
    if LM.Tree.Nodes[LIdx].Kind = nkIdent then
      Result.NodeOfVis.AddOrSetValue(LM.Tree.Nodes[LIdx].FirstToken, LIdx);
  FCaches.Add(AMid, Result);
end;

function TPasNavigator.IdentAt(AMid, ALine, ACol: Integer;
  out AIdent: TPasNavIdent): Boolean;
var
  LM: TPasSemaModel;
  LOffset, LLo, LHi, LMidTok, LRaw, LVis, LNode, LEndCol: Integer;
  LCache: TNavCache;
  LTS: TPasTokenStream;   // record copy — the arrays inside are shared refs
begin
  Result := False;
  if AMid < 0 then
    Exit;
  LM := FProj.Model(AMid);
  LTS := LM.Tree.Source.Files[0];
  if (ALine < 1) or (ALine - 1 > High(LTS.LineStarts)) or (ACol < 1) then
    Exit;
  LOffset := LTS.LineStarts[ALine - 1] + (ACol - 1);

  // Tokens are gapless and sorted by Start: binary-search the covering one.
  LLo := 0;
  LHi := High(LTS.Tokens);
  LRaw := -1;
  while LLo <= LHi do
  begin
    LMidTok := (LLo + LHi) div 2;
    if LTS.Tokens[LMidTok].Start > LOffset then
      LHi := LMidTok - 1
    else if LTS.Tokens[LMidTok].EndPos <= LOffset then
      LLo := LMidTok + 1
    else
    begin
      LRaw := LMidTok;
      Break;
    end;
  end;
  if (LRaw < 0) or (LTS.Tokens[LRaw].Kind <> tkIdentifier) then
    Exit;

  LCache := CacheOf(AMid);
  LVis := LCache.VisOfRaw[LRaw];
  if (LVis < 0) or not LCache.NodeOfVis.TryGetValue(LVis, LNode) then
    Exit;   // token is $IFDEF'd out, or not an identifier NODE position

  AIdent.Node := LNode;
  AIdent.RawToken := LRaw;
  LTS.OffsetToLineCol(LTS.Tokens[LRaw].Start, AIdent.Line, AIdent.ColFrom);
  LTS.OffsetToLineCol(LTS.Tokens[LRaw].EndPos, AIdent.Line, LEndCol);
  AIdent.ColTo := AIdent.ColFrom + LTS.Tokens[LRaw].Len;
  AIdent.Name := LTS.TokenText(LRaw);
  Result := True;
end;

// Builds a target from a declaration node in model AMid (its first visible
// token's file/line/col). False when the node has no visible token.
function TPasNavigator.TargetFromNode(AMid, ANode: Integer;
  const AName: string; out ATarget: TPasNavTarget): Boolean;
var
  LM: TPasSemaModel;
  LVisTok: Integer;
  LVis: TPasVisibleToken;
begin
  Result := False;
  if ANode = NIL_NODE then
    Exit;
  LM := FProj.Model(AMid);
  LVisTok := LM.Tree.Nodes[ANode].FirstToken;
  if (LVisTok < 0) or (LVisTok > High(LM.Tree.Source.Visible)) then
    Exit;
  LVis := LM.Tree.Source.Visible[LVisTok];
  var LTS := LM.Tree.Source.Files[LVis.FileId];
  LTS.OffsetToLineCol(LTS.Tokens[LVis.TokenIndex].Start,
    ATarget.Line, ATarget.Col);
  ATarget.UnitId := AMid;
  ATarget.FilePath := LM.Tree.Source.FileNames[LVis.FileId];
  ATarget.Name := AName;
  Result := True;
end;

// A same-named symbol WITH a real declaration in one of AMid's used units'
// interfaces, or (last resort) the implicit System unit. Handles a name that
// resolved locally to a compiler-seeded builtin (no DeclNode) but is actually
// declared somewhere real — e.g. TBytes resolves to the builtin yet is really
// declared in System.SysUtils; TObject/TArray<T>/IInterface/... are really
// declared in System, which every unit uses implicitly (never appears in
// UsesList — see TPasSemaProject.EnsureSystemUnit).
function TPasNavigator.FindInUsesDecl(AMid: Integer;
  const ANameLower: string; out ATMid, ASym: Integer): Boolean;
var
  LM, LUsed: TPasSemaModel;
  LIdx, LUid, LS: Integer;
begin
  Result := False;
  LM := FProj.Model(AMid);
  for LIdx := High(LM.UsesList) downto 0 do   // last uses wins, like resolution
  begin
    LUid := LM.UsesList[LIdx].UnitId;
    if LUid < 0 then
      Continue;
    LUsed := FProj.Model(LUid);
    if LUsed.InterfaceScope = NIL_SCOPE then
      Continue;
    LS := LUsed.Resolve(LUsed.InterfaceScope, ANameLower);
    if (LS <> NIL_SYM) and (LUsed.Symbols[LS].DeclNode <> NIL_NODE) then
    begin
      ATMid := LUid;
      ASym := LS;
      Exit(True);
    end;
  end;

  LUid := FProj.EnsureSystemUnit;
  if (LUid >= 0) and (LUid <> AMid) then
  begin
    LUsed := FProj.Model(LUid);
    if LUsed.InterfaceScope <> NIL_SCOPE then
    begin
      LS := LUsed.Resolve(LUsed.InterfaceScope, ANameLower);
      if (LS <> NIL_SYM) and (LUsed.Symbols[LS].DeclNode <> NIL_NODE) then
      begin
        ATMid := LUid;
        ASym := LS;
        Exit(True);
      end;
    end;
  end;
end;

// The routine-name ident node of the routine/anon scope owning ASym — used to
// send the implicit Result to its enclosing routine's declaration. Falls back
// to the scope's owner node itself for an anonymous method (no name).
function TPasNavigator.RoutineNameNodeOfSym(AMid, ASym: Integer): Integer;
var
  LM: TPasSemaModel;
  LScope, LOwner, LChild: Integer;
begin
  Result := NIL_NODE;
  LM := FProj.Model(AMid);
  LScope := LM.Symbols[ASym].Scope;
  if (LScope < 0) or (LScope >= LM.Scopes.Count) then
    Exit;
  LOwner := LM.Scopes[LScope].OwnerNode;
  if LOwner = NIL_NODE then
    Exit;
  LChild := LM.Tree.Nodes[LOwner].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LChild].Kind = nkIdent then
      Exit(LChild);
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
  Result := LOwner;
end;

function TPasNavigator.ResolveDecl(AMid, ANode: Integer;
  out ATarget: TPasNavTarget): Boolean;
var
  LM: TPasSemaModel;
  LExt: TPasExtRef;
  LTMid, LSym, LFbMid, LFbSym: Integer;
begin
  Result := False;
  if (AMid < 0) or (ANode = NIL_NODE) then
    Exit;
  LM := FProj.Model(AMid);
  LTMid := AMid;
  LSym := LM.RefMap[ANode];
  if LSym = NIL_SYM then
  begin
    if not LM.ExtRefMap.TryGetValue(ANode, LExt) then
      Exit;
    LTMid := LExt.UnitId;
    LSym := LExt.Sym;
  end;

  // A resolved symbol with a real declaration node — the common case.
  if FProj.Model(LTMid).Symbols[LSym].DeclNode <> NIL_NODE then
    Exit(TargetFromNode(LTMid, FProj.Model(LTMid).Symbols[LSym].DeclNode,
      FProj.Model(LTMid).Symbols[LSym].Name, ATarget));

  // No source declaration (a compiler builtin or the implicit Result):
  // 1) a builtin a used unit actually declares (TBytes -> System.SysUtils);
  if FindInUsesDecl(AMid, LowerCase(LM.Tree.NodeText(ANode)), LFbMid, LFbSym)
  then
    Exit(TargetFromNode(LFbMid, FProj.Model(LFbMid).Symbols[LFbSym].DeclNode,
      FProj.Model(LFbMid).Symbols[LFbSym].Name, ATarget));
  // 2) the implicit Result -> its enclosing routine's declaration.
  if (FProj.Model(LTMid).Symbols[LSym].Kind = skVar) and
     SameText(FProj.Model(LTMid).Symbols[LSym].Name, 'Result') then
    Exit(TargetFromNode(LTMid, RoutineNameNodeOfSym(LTMid, LSym), 'Result',
      ATarget));
end;

end.
