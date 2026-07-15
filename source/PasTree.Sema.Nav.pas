unit PasTree.Sema.Nav;

{
  PasTree semantics — go-to-declaration over an analyzed TPasSemaProject.

  Maps an editor position (file, 1-based line/col) to the identifier token
  under it (IdentAt), and resolves that identifier to its declaration's
  file/line/col (ResolveDecl) through the resolver's RefMap (intra-unit) and
  the project's ExtRefMap (cross-unit — including the member references the
  Phase-3c cross typer discovers through ancestor chains, generics, AND now
  through compiler-seeded builtins redirected to their real declaration via
  TPasSemaProject.ResolveRealDecl/EnsureSystemUnit — e.g. `Obj.Free` where
  Obj: TObject resolves into System.pas's real TObject class body).

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
  // Usually a single token (RawToken = RawTokenTo). A `uses` clause's
  // qualified unit name (e.g. `System.SysUtils`) is the one exception: Node
  // is redirected to the name's LEAF segment (whichever segment the cursor
  // was actually over — the whole name is one logical reference, so
  // ResolveDecl must see the same node regardless of which word was
  // clicked), and RawToken..RawTokenTo spans ALL segments + dots, so a host
  // highlights/links the entire qualified name, not just one word of it.
  TPasNavIdent = record
    Node: Integer;       // nkIdent CST node index (leaf, for a uses name)
    RawToken: Integer;   // first raw token of the span, in Files[0]
    RawTokenTo: Integer; // last raw token of the span (= RawToken normally)
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
    function RoutineNameNodeOfSym(AMid, ASym: Integer): Integer;
    function UsesQualifierInfo(AMid, ANode: Integer;
      out ALeaf, ASpanFirstVis, ASpanLastVis: Integer): Boolean;
    function ResolveUnitRefTarget(AMid, ASym: Integer;
      out ATarget: TPasNavTarget): Boolean;
    function TargetForUnitId(AUid: Integer; const AName: string;
      out ATarget: TPasNavTarget): Boolean;
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

// Walks up from ANode (an nkIdent) through any nested nkMember parents to the
// outermost one; if THAT node's own parent is nkUsesItem, ANode is a segment
// of a `uses` clause's (possibly dotted) unit name. Returns the name's LEAF
// segment (the deepest last-child — e.g. SysUtils in System.SysUtils; ANode
// itself for a plain undotted name) and the VISIBLE-index span covering every
// segment and dot (leftmost descendant's FirstToken .. the outermost node's
// own LastToken — deliberately excludes a trailing `in 'path'` sibling,
// which is outside the name node entirely). False when ANode is not part of
// a uses item's name at all (the ordinary case).
function TPasNavigator.UsesQualifierInfo(AMid, ANode: Integer;
  out ALeaf, ASpanFirstVis, ASpanLastVis: Integer): Boolean;
var
  LM: TPasSemaModel;
  LTop, LParent, LLeaf, LFirst: Integer;
begin
  Result := False;
  LM := FProj.Model(AMid);
  LTop := ANode;
  LParent := LM.Tree.Nodes[LTop].Parent;
  while (LParent <> NIL_NODE) and (LM.Tree.Nodes[LParent].Kind = nkMember) do
  begin
    LTop := LParent;
    LParent := LM.Tree.Nodes[LTop].Parent;
  end;
  if (LParent = NIL_NODE) or (LM.Tree.Nodes[LParent].Kind <> nkUsesItem) then
    Exit;

  LLeaf := LTop;
  while LM.Tree.Nodes[LLeaf].Kind = nkMember do
  begin
    LLeaf := LM.Tree.Nodes[LLeaf].FirstChild;
    while LM.Tree.Nodes[LLeaf].NextSibling <> NIL_NODE do
      LLeaf := LM.Tree.Nodes[LLeaf].NextSibling;
  end;

  LFirst := LTop;
  while LM.Tree.Nodes[LFirst].FirstChild <> NIL_NODE do
    LFirst := LM.Tree.Nodes[LFirst].FirstChild;

  ALeaf := LLeaf;
  ASpanFirstVis := LM.Tree.Nodes[LFirst].FirstToken;
  ASpanLastVis := LM.Tree.Nodes[LTop].LastToken;
  Result := True;
end;

function TPasNavigator.IdentAt(AMid, ALine, ACol: Integer;
  out AIdent: TPasNavIdent): Boolean;
var
  LM: TPasSemaModel;
  LOffset, LLo, LHi, LMidTok, LRaw, LVis, LNode, LEndCol: Integer;
  LCache: TNavCache;
  LTS: TPasTokenStream;   // record copy — the arrays inside are shared refs
  LLeaf, LSpanFirstVis, LSpanLastVis, LRawFrom, LRawTo: Integer;
  LQUid, LMatchNode, LFirst: Integer;
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
  AIdent.Name := LTS.TokenText(LRaw);
  LRawFrom := LRaw;
  LRawTo := LRaw;

  // A `uses` name is ONE logical reference regardless of which segment was
  // clicked: redirect Node to the leaf (so ResolveDecl always targets the
  // same unit) and widen the span to cover every segment + dot.
  if UsesQualifierInfo(AMid, LNode, LLeaf, LSpanFirstVis, LSpanLastVis) then
  begin
    AIdent.Node := LLeaf;
    if (LSpanFirstVis >= 0) and (LSpanFirstVis <= High(LM.Tree.Source.Visible))
       and (LM.Tree.Source.Visible[LSpanFirstVis].FileId = 0) then
      LRawFrom := LM.Tree.Source.Visible[LSpanFirstVis].TokenIndex;
    if (LSpanLastVis >= 0) and (LSpanLastVis <= High(LM.Tree.Source.Visible))
       and (LM.Tree.Source.Visible[LSpanLastVis].FileId = 0) then
      LRawTo := LM.Tree.Source.Visible[LSpanLastVis].TokenIndex;
  end
  else
  begin
    // Not a `uses` name — but LNode may still be a namespace-qualifier
    // segment of a dotted EXPRESSION (`System`/`SysUtils` in `System.
    // SysUtils.TBytes`): widen the span to the WHOLE qualifier (never the
    // trailing member), same "any segment links the same way" UX as a
    // `uses` clause's dotted name. Node is NOT redirected here (unlike the
    // `uses` case) — ResolveDecl's qualifier check climbs from wherever it's
    // given, so the originally-clicked node already works.
    // GUARD: only when LNode has NO resolution of its own (RefMap AND
    // ExtRefMap both miss) — QualifierUnitAt climbs to the outermost member
    // regardless of which node it's given, so calling it unconditionally
    // would ALSO fire for the trailing MEMBER itself (e.g. `sLineBreak` in
    // `System.sLineBreak`, already correctly resolved via ExtRefMap below)
    // and wrongly steal its span to point at the qualifier instead. Mirrors
    // the exact gate ResolveDecl already uses before its own QualifierUnitAt
    // call.
    if (LM.RefMap[LNode] = NIL_SYM) and not LM.ExtRefMap.ContainsKey(LNode) then
    begin
      LQUid := FProj.QualifierUnitAt(AMid, LNode, LMatchNode);
      if LQUid >= 0 then
      begin
        LFirst := LMatchNode;
        while LM.Tree.Nodes[LFirst].FirstChild <> NIL_NODE do
          LFirst := LM.Tree.Nodes[LFirst].FirstChild;
        LSpanFirstVis := LM.Tree.Nodes[LFirst].FirstToken;
        LSpanLastVis := LM.Tree.Nodes[LMatchNode].LastToken;
        if (LSpanFirstVis >= 0) and
           (LSpanFirstVis <= High(LM.Tree.Source.Visible)) and
           (LM.Tree.Source.Visible[LSpanFirstVis].FileId = 0) then
          LRawFrom := LM.Tree.Source.Visible[LSpanFirstVis].TokenIndex;
        if (LSpanLastVis >= 0) and
           (LSpanLastVis <= High(LM.Tree.Source.Visible)) and
           (LM.Tree.Source.Visible[LSpanLastVis].FileId = 0) then
          LRawTo := LM.Tree.Source.Visible[LSpanLastVis].TokenIndex;
      end;
    end;
  end;

  AIdent.RawToken := LRawFrom;
  AIdent.RawTokenTo := LRawTo;
  LTS.OffsetToLineCol(LTS.Tokens[LRawFrom].Start, AIdent.Line, AIdent.ColFrom);
  LTS.OffsetToLineCol(LTS.Tokens[LRawTo].EndPos, AIdent.Line, LEndCol);
  AIdent.ColTo := AIdent.ColFrom + (LTS.Tokens[LRawTo].EndPos -
    LTS.Tokens[LRawFrom].Start);
  Result := True;
end;

// Builds a target from a declaration node in model AMid (its first visible
// token's file/line/col). False when the node has no visible token.
function TPasNavigator.TargetFromNode(AMid, ANode: Integer;
  const AName: string; out ATarget: TPasNavTarget): Boolean;
var
  LM: TPasSemaModel;
  LFirst, LVisTok: Integer;
  LVis: TPasVisibleToken;
begin
  Result := False;
  if ANode = NIL_NODE then
    Exit;
  LM := FProj.Model(AMid);
  // An nkMember's OWN FirstToken is the '.' (see PasTree.Ast), not its first
  // visible character — descend to the leftmost descendant so a dotted
  // declaration name (`unit Namespace.NavD;`) lands on "Namespace", not on
  // the dot. A no-op for any childless node (nkIdent has none).
  LFirst := ANode;
  while LM.Tree.Nodes[LFirst].FirstChild <> NIL_NODE do
    LFirst := LM.Tree.Nodes[LFirst].FirstChild;
  LVisTok := LM.Tree.Nodes[LFirst].FirstToken;
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

// A `uses` reference's target isn't its own DeclNode (that's just the
// clause's own name, in THIS unit — jumping there would just land on
// itself); it's the FILE that unit resolved to. Falls back to (1,1) of that
// file if the target unit's own name node isn't available for some reason
// (never observed — every analyzed model has one, see CollectRoot), so
// "open the file" still works even in that edge case. False when the use
// never resolved to a real file (ASym.Flags has sfExternalUnresolved and no
// UsesList entry names a UnitId — nothing to open).
// A target that just opens AUid's own file, at its own declaration (node 0's
// FirstChild, per CollectRoot's known shape) — falls back to (1,1) of that
// file if the name node is somehow unavailable, so "open the file" still
// works either way. Shared by ResolveUnitRefTarget (a `uses` clause name)
// and ResolveDecl's qualifier-segment case (System/SysUtils clicked directly
// in an expression like System.SysUtils.TBytes).
function TPasNavigator.TargetForUnitId(AUid: Integer; const AName: string;
  out ATarget: TPasNavTarget): Boolean;
var
  LNameNode: Integer;
begin
  Result := False;
  if AUid < 0 then
    Exit;
  LNameNode := FProj.Model(AUid).Tree.Nodes[0].FirstChild;
  if TargetFromNode(AUid, LNameNode, AName, ATarget) then
    Exit(True);
  ATarget.UnitId := AUid;
  ATarget.FilePath := FProj.ModelFile(AUid);
  ATarget.Line := 1;
  ATarget.Col := 1;
  ATarget.Name := AName;
  Result := True;
end;

function TPasNavigator.ResolveUnitRefTarget(AMid, ASym: Integer;
  out ATarget: TPasNavTarget): Boolean;
var
  LM: TPasSemaModel;
  LIdx, LUid: Integer;
begin
  LM := FProj.Model(AMid);
  LUid := -1;
  for LIdx := 0 to High(LM.UsesList) do
    if LM.UsesList[LIdx].Sym = ASym then
    begin
      LUid := LM.UsesList[LIdx].UnitId;
      Break;
    end;
  Result := TargetForUnitId(LUid, LM.Symbols[ASym].Name, ATarget);
end;

// TPasSemaProject.ResolveRealDecl handles this: a same-named symbol WITH a
// real declaration in AMid's used units, or (last resort) the implicit
// System unit — e.g. TBytes resolves locally to a builtin yet is really
// declared in System.SysUtils; TObject/TArray<T>/... in System.

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
  LTMid, LSym, LFbMid, LFbSym, LQUid, LMatchNode: Integer;
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
    begin
      // Not a value/type reference at all — ANode may still be a NAMESPACE
      // QUALIFIER segment of a bigger dotted expression (`System`/`SysUtils`
      // in `System.SysUtils.TBytes`, `System` alone in `System.sLineBreak`):
      // real dcc lets you click/hover the qualifier itself, same as a `uses`
      // clause name, distinct from the MEMBER (TBytes/sLineBreak), which
      // resolves via the ordinary ExtRefMap path above/below instead.
      LQUid := FProj.QualifierUnitAt(AMid, ANode, LMatchNode);
      if LQUid >= 0 then
        Exit(TargetForUnitId(LQUid, LM.Tree.NodeText(ANode), ATarget));
      Exit;
    end;
    LTMid := LExt.UnitId;
    LSym := LExt.Sym;
  end;

  // A `uses` clause name (skUnitRef): its own DeclNode is just the clause's
  // own spelling in THIS unit, not a useful jump target — go to the
  // REFERENCED unit's file instead.
  if FProj.Model(LTMid).Symbols[LSym].Kind = skUnitRef then
    Exit(ResolveUnitRefTarget(LTMid, LSym, ATarget));

  // A resolved symbol with a real declaration node — the common case.
  if FProj.Model(LTMid).Symbols[LSym].DeclNode <> NIL_NODE then
    Exit(TargetFromNode(LTMid, FProj.Model(LTMid).Symbols[LSym].DeclNode,
      FProj.Model(LTMid).Symbols[LSym].Name, ATarget));

  // No source declaration (a compiler builtin or the implicit Result):
  // 1) a builtin a used unit (or the implicit System unit) actually declares
  //    (TBytes -> System.SysUtils; TObject/TArray<T> -> System);
  if FProj.ResolveRealDecl(AMid, LowerCase(LM.Tree.NodeText(ANode)), LFbMid,
    LFbSym) then
    Exit(TargetFromNode(LFbMid, FProj.Model(LFbMid).Symbols[LFbSym].DeclNode,
      FProj.Model(LFbMid).Symbols[LFbSym].Name, ATarget));
  // 2) the implicit Result -> its enclosing routine's declaration.
  if (FProj.Model(LTMid).Symbols[LSym].Kind = skVar) and
     SameText(FProj.Model(LTMid).Symbols[LSym].Name, 'Result') then
    Exit(TargetFromNode(LTMid, RoutineNameNodeOfSym(LTMid, LSym), 'Result',
      ATarget));
  // 3) a compiler INTRINSIC with no source declaration anywhere (Integer,
  //    Length, True... — real System.pas literally says "Predefined
  //    constants, types, procedures, and functions do not have actual
  //    declarations"): target the real System unit's own header, exactly
  //    what the RAD Studio IDE does for these.
  Result := TargetForUnitId(FProj.EnsureSystemUnit,
    FProj.Model(LTMid).Symbols[LSym].Name, ATarget);
end;

end.
