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

function TPasNavigator.ResolveDecl(AMid, ANode: Integer;
  out ATarget: TPasNavTarget): Boolean;
var
  LM, LTM: TPasSemaModel;
  LExt: TPasExtRef;
  LTMid, LSym, LDecl, LVisTok: Integer;
  LVis: TPasVisibleToken;
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

  LTM := FProj.Model(LTMid);
  LDecl := LTM.Symbols[LSym].DeclNode;
  if LDecl = NIL_NODE then
    Exit;   // a builtin — no source declaration to jump to

  LVisTok := LTM.Tree.Nodes[LDecl].FirstToken;
  if (LVisTok < 0) or (LVisTok > High(LTM.Tree.Source.Visible)) then
    Exit;
  LVis := LTM.Tree.Source.Visible[LVisTok];
  var LTS := LTM.Tree.Source.Files[LVis.FileId];
  LTS.OffsetToLineCol(LTS.Tokens[LVis.TokenIndex].Start,
    ATarget.Line, ATarget.Col);
  ATarget.UnitId := LTMid;
  ATarget.FilePath := LTM.Tree.Source.FileNames[LVis.FileId];
  ATarget.Name := LTM.Symbols[LSym].Name;
  Result := True;
end;

end.
