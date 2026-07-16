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
      // Declaration<->implementation pairing (routine decl<->impl toggle),
      // built lazily on first use — most editing sessions never need it.
      RoutinesBuilt: Boolean;
      RoutineOfVis: TArray<Integer>;      // visible idx -> innermost enclosing
                                          // nkRoutine node, or NIL_NODE
      DeclKey, ImplKey: TDictionary<string, Integer>;       // exact arity
      DeclKeyLoose, ImplKeyLoose: TDictionary<string, Integer>; // arity-blind
                                                                 // fallback
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
    // Declaration<->implementation toggle helpers (all pure CST walks — no
    // dependency on the resolver's symbol table, so a redeclaration or an
    // unusual overload shape can never break navigation, only miss it).
    function VisAt(AMid, ALine, ACol: Integer): Integer;
    function TargetFromVis(AMid, AVisIdx: Integer; const AName: string;
      out ATarget: TPasNavTarget): Boolean;
    function RTIsStructKind(AKind: TPasNodeKind): Boolean;
    function RTFindChildKind(LM: TPasSemaModel; ANode: Integer;
      AKind: TPasNodeKind): Integer;
    function RTSkipAttr(LM: TPasSemaModel; AChild: Integer): Integer;
    function RTSepAfter(LM: TPasSemaModel; ANode: Integer): string;
    function RTSegments(LM: TPasSemaModel; ANode: Integer;
      out AQualIdents: TArray<Integer>; out ANameNode: Integer): Boolean;
    function RTParamCount(LM: TPasSemaModel; ANode: Integer): Integer;
    function RTEnclosingRoutine(LM: TPasSemaModel; ANode: Integer): Integer;
    function RTEnclosingTypeChain(LM: TPasSemaModel;
      ADeclNode: Integer): TArray<string>;
    function RTMethodKey(const AChain: TArray<string>; const AName: string;
      AParamCount: Integer): string;
    function RTRoutineKey(AContainer: Integer; const AName: string;
      AParamCount: Integer): string;
    procedure EnsureRoutinePairs(AMid: Integer; ACache: TNavCache);
    function RoutineBodyEntryVis(LM: TPasSemaModel; AImplNode: Integer):
      Integer;
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
    { Cursor on (or inside) a routine DECLARATION with no body — a `uses`-
      section/class-member header, or a `forward`-declared global/nested
      proc — that has a matching implementation elsewhere in the SAME unit
      (Object Pascal requires it there; this never crosses units). Target
      is the first statement of the implementation's body (or, for an empty
      `begin end`, the `end` itself). False when the cursor isn't on/in a
      declaration, or no implementation matches. Also serves as the
      Enabled check for the "go to implementation" command — call with a
      throwaway ATarget. }
    function GotoImplementation(AMid, ALine, ACol: Integer;
      out ATarget: TPasNavTarget): Boolean;
    { Cursor anywhere inside a routine's IMPLEMENTATION (header or body) that
      has a separate declaration — a qualified method impl (TFoo.Bar) whose
      class declares Bar, or a global/nested proc completing a `forward`.
      Target is the declaration's own name. False when the cursor isn't
      inside an implementation, or it has no separate declaration (e.g. a
      plain routine defined directly with no forward decl — nothing to jump
      to). Also serves as the Enabled check for "go to declaration". }
    function GotoDeclaration(AMid, ALine, ACol: Integer;
      out ATarget: TPasNavTarget): Boolean;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.Generics.Defaults;

{ TPasNavigator.TNavCache }

destructor TPasNavigator.TNavCache.Destroy;
begin
  NodeOfVis.Free;
  DeclKey.Free;
  ImplKey.Free;
  DeclKeyLoose.Free;
  ImplKeyLoose.Free;
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

{ Declaration <-> implementation toggle.

  Object Pascal never lets a routine's implementation live in a different
  unit from its declaration (a `forward`-declared or class-member routine
  MUST be completed in the same unit), so this whole feature is a pure,
  intra-model CST walk — no project/cross-unit involvement, unlike the rest
  of this file. Two routine shapes get paired:

    - A METHOD: a class/record/interface/object member declaration (always
      unqualified, always body-less) paired with its qualified
      implementation (`TFoo.Bar`, or `TOuter.TInner.Bar` for a nested
      class) elsewhere in the unit. Matched by the type's own name CHAIN
      (walking the declaration's enclosing nkTypeDecl nodes outward, and
      the implementation's qualifier segments — see RTEnclosingTypeChain/
      RTSegments) + method name + parameter count.

    - A GLOBAL or NESTED routine: an unqualified `forward`-declared header
      (interface section, or directly in the implementation section, or
      inside another routine's local declarations for a nested proc) paired
      with its later same-name implementation in the SAME lexical
      container (the unit itself, or the enclosing routine — see
      RTEnclosingRoutine) + parameter count.

  Parameter count (not full type matching) disambiguates overloads — the
  same arity-only precision the resolver's OWN interface<->impl linking
  already uses elsewhere in this codebase (CollectRoutine); ties fall back
  to an arity-blind key (first-registered wins), so the common
  non-overloaded case still works even if the count comes out wrong for
  some unanticipated grammar shape. }

function TPasNavigator.VisAt(AMid, ALine, ACol: Integer): Integer;
var
  LM: TPasSemaModel;
  LTS: TPasTokenStream;
  LCache: TNavCache;
  LOffset, LLo, LHi, LMidTok, LRaw: Integer;
begin
  Result := -1;
  LM := FProj.Model(AMid);
  LTS := LM.Tree.Source.Files[0];
  if (ALine < 1) or (ALine - 1 > High(LTS.LineStarts)) or (ACol < 1) then
    Exit;
  LOffset := LTS.LineStarts[ALine - 1] + (ACol - 1);
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
  if LRaw < 0 then
    Exit;
  // The raw token containing this position may be whitespace/a comment —
  // real lexical content, but stripped before the Visible stream, so
  // VisOfRaw has no entry for it (e.g. right after `begin`, before the
  // next real token: SynEdit reports that caret column as sitting IN the
  // trailing newline). Walk BACKWARD to the nearest raw token that DOES
  // have a visible mapping — "still within whatever came before" is the
  // natural reading of a caret sitting in trailing whitespace, and matches
  // how IdentAt's identifier-only search already behaves at any OTHER
  // non-identifier position (it simply requires an exact hit); this one
  // needs the fallback because, unlike IdentAt, "anywhere in the body" is
  // the whole point.
  LCache := CacheOf(AMid);
  while (LRaw >= 0) and (LCache.VisOfRaw[LRaw] < 0) do
    Dec(LRaw);
  if LRaw < 0 then
    Exit;
  Result := LCache.VisOfRaw[LRaw];
end;

// Like TargetFromNode, but for a node whose OWN FirstToken is already known
// to be its true leftmost position (any ordinary statement/declaration node
// — NOT an nkMember, whose FirstToken is the dot; callers here never pass
// one of those) — so no leftmost-descendant walk is needed.
function TPasNavigator.TargetFromVis(AMid, AVisIdx: Integer;
  const AName: string; out ATarget: TPasNavTarget): Boolean;
var
  LM: TPasSemaModel;
  LVis: TPasVisibleToken;
  LTS: TPasTokenStream;
begin
  Result := False;
  LM := FProj.Model(AMid);
  if (AVisIdx < 0) or (AVisIdx > High(LM.Tree.Source.Visible)) then
    Exit;
  LVis := LM.Tree.Source.Visible[AVisIdx];
  LTS := LM.Tree.Source.Files[LVis.FileId];
  ATarget.UnitId := AMid;
  ATarget.FilePath := LM.Tree.Source.FileNames[LVis.FileId];
  LTS.OffsetToLineCol(LTS.Tokens[LVis.TokenIndex].Start, ATarget.Line,
    ATarget.Col);
  ATarget.Name := AName;
  Result := True;
end;

function TPasNavigator.RTIsStructKind(AKind: TPasNodeKind): Boolean;
begin
  Result := AKind in [nkClassType, nkRecordType, nkInterfaceType, nkObjectType,
    nkHelperType];
end;

function TPasNavigator.RTFindChildKind(LM: TPasSemaModel; ANode: Integer;
  AKind: TPasNodeKind): Integer;
begin
  Result := LM.Tree.Nodes[ANode].FirstChild;
  while (Result <> NIL_NODE) and (LM.Tree.Nodes[Result].Kind <> AKind) do
    Result := LM.Tree.Nodes[Result].NextSibling;
end;

function TPasNavigator.RTSkipAttr(LM: TPasSemaModel; AChild: Integer): Integer;
begin
  Result := AChild;
  if (Result <> NIL_NODE) and (LM.Tree.Nodes[Result].Kind = nkAttrGroup) then
    Result := LM.Tree.Nodes[Result].NextSibling;
end;

function TPasNavigator.RTSepAfter(LM: TPasSemaModel; ANode: Integer): string;
var
  LNext: Integer;
begin
  LNext := LM.Tree.Nodes[ANode].LastToken + 1;
  if (LNext >= 0) and (LNext <= High(LM.Tree.Source.Visible)) then
    Result := LM.Tree.Source.VisibleText(LNext)
  else
    Result := '';
end;

// Mirrors CollectRoutine's own name-segment walk exactly (PasTree.Sema.
// Resolver.pas): each segment is `ident [<generic params/type args>]`; a
// '.' after a segment means it's a QUALIFIER (the last segment is the real
// name). Declarations are always unqualified (AQualIdents = []); a qualified
// method implementation is the one shape that isn't.
function TPasNavigator.RTSegments(LM: TPasSemaModel; ANode: Integer;
  out AQualIdents: TArray<Integer>; out ANameNode: Integer): Boolean;
var
  LChild, LSegIdent, LSegLast: Integer;
begin
  AQualIdents := nil;
  ANameNode := NIL_NODE;
  LChild := RTSkipAttr(LM, LM.Tree.Nodes[ANode].FirstChild);
  while (LChild <> NIL_NODE) and (LM.Tree.Nodes[LChild].Kind = nkIdent) do
  begin
    LSegIdent := LChild;
    LSegLast := LChild;
    LChild := LM.Tree.Nodes[LChild].NextSibling;
    while (LChild <> NIL_NODE) and
          (LM.Tree.Nodes[LChild].Kind in [nkGenericParams, nkTypeArgs]) do
    begin
      LSegLast := LChild;
      LChild := LM.Tree.Nodes[LChild].NextSibling;
    end;
    if RTSepAfter(LM, LSegLast) = '.' then
      AQualIdents := AQualIdents + [LSegIdent]
    else
    begin
      ANameNode := LSegIdent;
      Break;
    end;
  end;
  Result := ANameNode <> NIL_NODE;
end;

// Total parameter NAME count (mirrors CollectRoutine's own arity-matching
// logic) — 0 for a parameterless routine or one with no repeated param list
// at all (a body-less external/forward completion; rare enough here that
// the loose, arity-blind key covers it).
function TPasNavigator.RTParamCount(LM: TPasSemaModel; ANode: Integer):
  Integer;
var
  LParams, LParam, LChild: Integer;
begin
  Result := 0;
  LParams := RTFindChildKind(LM, ANode, nkParams);
  if LParams = NIL_NODE then
    Exit;
  LParam := LM.Tree.Nodes[LParams].FirstChild;
  while LParam <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LParam].Kind = nkParam then
    begin
      LChild := RTSkipAttr(LM, LM.Tree.Nodes[LParam].FirstChild);
      while (LChild <> NIL_NODE) and (LM.Tree.Nodes[LChild].Kind = nkIdent) do
      begin
        Inc(Result);
        if RTSepAfter(LM, LChild) = ':' then
          Break;
        LChild := LM.Tree.Nodes[LChild].NextSibling;
        if (LChild <> NIL_NODE) and (LM.Tree.Nodes[LChild].Kind <> nkIdent)
        then
          Break;
      end;
    end;
    LParam := LM.Tree.Nodes[LParam].NextSibling;
  end;
end;

// The nearest ENCLOSING nkRoutine ancestor of ANode itself (climbing from
// its parent) — NIL_NODE for anything at unit top level. The lexical
// "container" that scopes a nested proc's forward-decl<->impl pairing
// (distinct nested procs of the same name in different outer routines must
// never match each other); for a top-level global routine, both the
// interface declaration and the implementation-section definition share
// the same NIL_NODE container.
function TPasNavigator.RTEnclosingRoutine(LM: TPasSemaModel;
  ANode: Integer): Integer;
begin
  Result := LM.Tree.Nodes[ANode].Parent;
  while (Result <> NIL_NODE) and (LM.Tree.Nodes[Result].Kind <> nkRoutine) do
    Result := LM.Tree.Nodes[Result].Parent;
end;

// For a class-member DECLARATION node (ANode's parent is a struct-type body):
// the dotted chain of ENCLOSING type names, outer to inner (["touter",
// "tinner"] for a method of TOuter.TInner) — climbs struct-type node ->
// its OWN nkTypeDecl (has the name) -> whatever adopted that nkTypeDecl
// (another struct-type body, if nested one level further out; anything
// else ends the climb). Compared against a qualified implementation's own
// QUALIFIER segments (RTSegments), which spell out the identical chain.
function TPasNavigator.RTEnclosingTypeChain(LM: TPasSemaModel;
  ADeclNode: Integer): TArray<string>;
var
  LCur, LTypeDecl, LNameNode: Integer;
begin
  Result := nil;
  LCur := LM.Tree.Nodes[ADeclNode].Parent;
  while (LCur <> NIL_NODE) and RTIsStructKind(LM.Tree.Nodes[LCur].Kind) do
  begin
    LTypeDecl := LM.Tree.Nodes[LCur].Parent;
    if (LTypeDecl = NIL_NODE) or
       (LM.Tree.Nodes[LTypeDecl].Kind <> nkTypeDecl) then
      Break;
    LNameNode := LM.Tree.Nodes[LTypeDecl].FirstChild;
    if (LNameNode = NIL_NODE) or (LM.Tree.Nodes[LNameNode].Kind <> nkIdent)
    then
      Break;
    Result := [LowerCase(LM.Tree.NodeText(LNameNode))] + Result;
    LCur := LM.Tree.Nodes[LTypeDecl].Parent;
    // A `type` SECTION nested inside a class body (`type TInner = class ...
    // end; end;`) wraps its nkTypeDecl children in an nkTypeSec — one more
    // hop to reach the OUTER struct body itself, same as a bare nested
    // nkTypeDecl (adopted directly, no section wrapper) would already be.
    if (LCur <> NIL_NODE) and (LM.Tree.Nodes[LCur].Kind = nkTypeSec) then
      LCur := LM.Tree.Nodes[LCur].Parent;
  end;
end;

function TPasNavigator.RTMethodKey(const AChain: TArray<string>;
  const AName: string; AParamCount: Integer): string;
begin
  Result := 'M#' + string.Join('.', AChain) + '#' + AName + '#' +
    IntToStr(AParamCount);
end;

function TPasNavigator.RTRoutineKey(AContainer: Integer; const AName: string;
  AParamCount: Integer): string;
begin
  Result := 'U#' + IntToStr(AContainer) + '#' + AName + '#' +
    IntToStr(AParamCount);
end;

// Builds RoutineOfVis + the four Decl/Impl key dictionaries for ACache, once
// (RoutinesBuilt guards re-entry). Two passes over the model's (typically
// few dozen to low hundreds) nkRoutine nodes: position index first, then
// the key index.
procedure TPasNavigator.EnsureRoutinePairs(AMid: Integer; ACache: TNavCache);
var
  LM: TPasSemaModel;
  LIdx, LR, LParent: Integer;
  LRoutineIds: TArray<Integer>;
  LQualIdents: TArray<Integer>;
  LNameNode: Integer;
  LName, LKey, LKeyLoose: string;
  LChain: TArray<string>;
  LIsMethod, LHasBody: Boolean;
  LFrom, LTo: Integer;
begin
  if ACache.RoutinesBuilt then
    Exit;
  ACache.RoutinesBuilt := True;
  LM := FProj.Model(AMid);
  ACache.DeclKey := TDictionary<string, Integer>.Create;
  ACache.ImplKey := TDictionary<string, Integer>.Create;
  ACache.DeclKeyLoose := TDictionary<string, Integer>.Create;
  ACache.ImplKeyLoose := TDictionary<string, Integer>.Create;

  LRoutineIds := nil;
  for LIdx := 0 to High(LM.Tree.Nodes) do
    if LM.Tree.Nodes[LIdx].Kind = nkRoutine then
      LRoutineIds := LRoutineIds + [LIdx];

  // Position index: widest (outermost) span first, so a later, NARROWER
  // (nested) routine's marking correctly overwrites its outer's — avoids an
  // O(tokens x nesting-depth) full-tree walk, since only the (few) routine
  // nodes' own spans are marked, not every node's.
  TArray.Sort<Integer>(LRoutineIds, TComparer<Integer>.Construct(
    function(const A, B: Integer): Integer
    begin
      Result := (LM.Tree.Nodes[B].LastToken - LM.Tree.Nodes[B].FirstToken) -
        (LM.Tree.Nodes[A].LastToken - LM.Tree.Nodes[A].FirstToken);
    end));
  SetLength(ACache.RoutineOfVis, Length(LM.Tree.Source.Visible));
  for LIdx := 0 to High(ACache.RoutineOfVis) do
    ACache.RoutineOfVis[LIdx] := NIL_NODE;
  for LR in LRoutineIds do
  begin
    LFrom := LM.Tree.Nodes[LR].FirstToken;
    if LFrom < 0 then
      LFrom := 0;
    LTo := LM.Tree.Nodes[LR].LastToken;
    if LTo > High(ACache.RoutineOfVis) then
      LTo := High(ACache.RoutineOfVis);
    for LIdx := LFrom to LTo do
      ACache.RoutineOfVis[LIdx] := LR;
  end;

  // Declaration <-> implementation key index.
  for LR in LRoutineIds do
  begin
    if not RTSegments(LM, LR, LQualIdents, LNameNode) then
      Continue;
    LName := LowerCase(LM.Tree.NodeText(LNameNode));
    LParent := LM.Tree.Nodes[LR].Parent;
    LIsMethod := (LQualIdents <> nil) or
      ((LParent <> NIL_NODE) and RTIsStructKind(LM.Tree.Nodes[LParent].Kind));
    LHasBody := RTFindChildKind(LM, LR, nkRoutineBody) <> NIL_NODE;
    if LIsMethod then
    begin
      if LQualIdents <> nil then
      begin
        // The qualified side is always the implementation.
        SetLength(LChain, Length(LQualIdents));
        for LIdx := 0 to High(LQualIdents) do
          LChain[LIdx] := LowerCase(LM.Tree.NodeText(LQualIdents[LIdx]));
      end
      else
        // Unqualified but struct-parented: always the class-member decl.
        LChain := RTEnclosingTypeChain(LM, LR);
      LKey := RTMethodKey(LChain, LName, RTParamCount(LM, LR));
      LKeyLoose := RTMethodKey(LChain, LName, -1);
    end
    else
    begin
      LKey := RTRoutineKey(RTEnclosingRoutine(LM, LR), LName,
        RTParamCount(LM, LR));
      LKeyLoose := RTRoutineKey(RTEnclosingRoutine(LM, LR), LName, -1);
    end;
    if LHasBody then
    begin
      if not ACache.ImplKey.ContainsKey(LKey) then
        ACache.ImplKey.Add(LKey, LR);
      if not ACache.ImplKeyLoose.ContainsKey(LKeyLoose) then
        ACache.ImplKeyLoose.Add(LKeyLoose, LR);
    end
    else
    begin
      if not ACache.DeclKey.ContainsKey(LKey) then
        ACache.DeclKey.Add(LKey, LR);
      if not ACache.DeclKeyLoose.ContainsKey(LKeyLoose) then
        ACache.DeclKeyLoose.Add(LKeyLoose, LR);
    end;
  end;
end;

// The implementation's own body-entry position: the first statement's
// FirstToken, or (an empty `begin end`) the block's own `end`; for a raw
// `asm ... end` block (no statement children at all) — the token right
// after `asm`. -1 if AImplNode somehow has no body (guarded by callers).
function TPasNavigator.RoutineBodyEntryVis(LM: TPasSemaModel;
  AImplNode: Integer): Integer;
var
  LBody, LBlockOrAsm, LFirstStmt: Integer;
begin
  Result := -1;
  LBody := RTFindChildKind(LM, AImplNode, nkRoutineBody);
  if LBody = NIL_NODE then
    Exit;
  LBlockOrAsm := LM.Tree.Nodes[LBody].FirstChild;
  while (LBlockOrAsm <> NIL_NODE) and
        (LM.Tree.Nodes[LBlockOrAsm].NextSibling <> NIL_NODE) do
    LBlockOrAsm := LM.Tree.Nodes[LBlockOrAsm].NextSibling;
  if LBlockOrAsm = NIL_NODE then
    Exit;
  case LM.Tree.Nodes[LBlockOrAsm].Kind of
    nkBlock:
      begin
        LFirstStmt := LM.Tree.Nodes[LBlockOrAsm].FirstChild;
        if LFirstStmt <> NIL_NODE then
          Result := LM.Tree.Nodes[LFirstStmt].FirstToken
        else
          Result := LM.Tree.Nodes[LBlockOrAsm].LastToken;   // empty `begin end`
      end;
    nkAsmStmt:
      Result := LM.Tree.Nodes[LBlockOrAsm].FirstToken + 1;
  end;
end;

function TPasNavigator.GotoImplementation(AMid, ALine, ACol: Integer;
  out ATarget: TPasNavTarget): Boolean;
var
  LM: TPasSemaModel;
  LCache: TNavCache;
  LVis, LDeclNode, LImplNode, LNameNode, LContainer, LBodyVis: Integer;
  LQualIdents: TArray<Integer>;
  LName, LKey, LKeyLoose: string;
  LChain: TArray<string>;
  LIsMethod: Boolean;
begin
  Result := False;
  if AMid < 0 then
    Exit;
  LM := FProj.Model(AMid);
  LCache := CacheOf(AMid);
  EnsureRoutinePairs(AMid, LCache);
  LVis := VisAt(AMid, ALine, ACol);
  if LVis < 0 then
    Exit;
  LDeclNode := LCache.RoutineOfVis[LVis];
  if LDeclNode = NIL_NODE then
    Exit;
  if RTFindChildKind(LM, LDeclNode, nkRoutineBody) <> NIL_NODE then
    Exit;   // cursor is already on/in an implementation
  if not RTSegments(LM, LDeclNode, LQualIdents, LNameNode) then
    Exit;
  LName := LowerCase(LM.Tree.NodeText(LNameNode));
  LIsMethod := (LM.Tree.Nodes[LDeclNode].Parent <> NIL_NODE) and
    RTIsStructKind(LM.Tree.Nodes[LM.Tree.Nodes[LDeclNode].Parent].Kind);
  if LIsMethod then
  begin
    LChain := RTEnclosingTypeChain(LM, LDeclNode);
    LKey := RTMethodKey(LChain, LName, RTParamCount(LM, LDeclNode));
    LKeyLoose := RTMethodKey(LChain, LName, -1);
  end
  else
  begin
    LContainer := RTEnclosingRoutine(LM, LDeclNode);
    LKey := RTRoutineKey(LContainer, LName, RTParamCount(LM, LDeclNode));
    LKeyLoose := RTRoutineKey(LContainer, LName, -1);
  end;
  if not LCache.ImplKey.TryGetValue(LKey, LImplNode) then
    if not LCache.ImplKeyLoose.TryGetValue(LKeyLoose, LImplNode) then
      Exit;
  LBodyVis := RoutineBodyEntryVis(LM, LImplNode);
  if LBodyVis < 0 then
    Exit;
  Result := TargetFromVis(AMid, LBodyVis, LName, ATarget);
end;

function TPasNavigator.GotoDeclaration(AMid, ALine, ACol: Integer;
  out ATarget: TPasNavTarget): Boolean;
var
  LM: TPasSemaModel;
  LCache: TNavCache;
  LVis, LImplNode, LDeclNode, LNameNode, LContainer, LIdx: Integer;
  LQualIdents: TArray<Integer>;
  LName, LKey, LKeyLoose: string;
  LChain: TArray<string>;
  LIsMethod: Boolean;
begin
  Result := False;
  if AMid < 0 then
    Exit;
  LM := FProj.Model(AMid);
  LCache := CacheOf(AMid);
  EnsureRoutinePairs(AMid, LCache);
  LVis := VisAt(AMid, ALine, ACol);
  if LVis < 0 then
    Exit;
  LImplNode := LCache.RoutineOfVis[LVis];
  if LImplNode = NIL_NODE then
    Exit;
  if RTFindChildKind(LM, LImplNode, nkRoutineBody) = NIL_NODE then
    Exit;   // cursor is already on/in a declaration
  if not RTSegments(LM, LImplNode, LQualIdents, LNameNode) then
    Exit;
  LName := LowerCase(LM.Tree.NodeText(LNameNode));
  LIsMethod := LQualIdents <> nil;
  if LIsMethod then
  begin
    SetLength(LChain, Length(LQualIdents));
    for LIdx := 0 to High(LQualIdents) do
      LChain[LIdx] := LowerCase(LM.Tree.NodeText(LQualIdents[LIdx]));
    LKey := RTMethodKey(LChain, LName, RTParamCount(LM, LImplNode));
    LKeyLoose := RTMethodKey(LChain, LName, -1);
  end
  else
  begin
    LContainer := RTEnclosingRoutine(LM, LImplNode);
    LKey := RTRoutineKey(LContainer, LName, RTParamCount(LM, LImplNode));
    LKeyLoose := RTRoutineKey(LContainer, LName, -1);
  end;
  if not LCache.DeclKey.TryGetValue(LKey, LDeclNode) then
    if not LCache.DeclKeyLoose.TryGetValue(LKeyLoose, LDeclNode) then
      Exit;
  if not RTSegments(LM, LDeclNode, LQualIdents, LNameNode) then
    Exit;
  Result := TargetFromVis(AMid, LM.Tree.Nodes[LNameNode].FirstToken, LName,
    ATarget);
end;

end.
