unit PasTree.Sema.Nav;

{
  PasTree semantics - go-to-declaration over an analyzed TPasSemaProject.

  Maps an editor position (file, 1-based line/col) to the identifier token
  under it (IdentAt), and resolves that identifier to its declaration's
  file/line/col (ResolveDecl) through the resolver's RefMap (intra-unit) and
  the project's ExtRefMap (cross-unit - including the member references the
  Phase-3c cross typer discovers through ancestor chains, generics, AND now
  through compiler-seeded builtins redirected to their real declaration via
  TPasSemaProject.ResolveRealDecl/EnsureSystemUnit - e.g. `Obj.Free` where
  Obj: TObject resolves into System.pas's real TObject class body).

  Pure lookups over the immutable models; per-model lookup tables are built
  lazily and cached. Built for editor hosts: the demo today, an LSP later.
  Positions refer to the sources AS ANALYZED (on disk) - a host with unsaved
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
  // was actually over - the whole name is one logical reference, so
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

  // One USE of a symbol found by FindReferences - never the declaration
  // itself (see FindReferences' own comment for why). Snippet is the RAW
  // source line (leading whitespace intact, only the trailing break
  // stripped - TPasTokenStream.LineText), so HiFrom/HiTo stay valid offsets
  // into it; a host that trims leading whitespace for display must shift
  // both by the same amount rather than re-deriving them from the trimmed
  // text.
  TPasRefHit = record
    FilePath: string;
    Line, Col: Integer;      // 1-based, for NavigateTo
    Snippet: string;
    HiFrom, HiTo: Integer;   // 0-based offsets into Snippet to highlight
  end;

  { One text replacement produced by PlanRename - the SAME identifier
    positions Find References reports (the declaration plus every resolved
    USE), turned into edits. Line/Col/Len address the OLD identifier in the
    file as analyzed; Snippet/HiFrom/HiTo are the PREVIEW: the line as it
    reads AFTER every edit on that same line has been applied, with the new
    name highlighted - so a host can show the RESULT of the rename in the
    very same results panel it shows a search in, without applying anything
    first.

    A host applying these must walk each file's edits from the LAST position
    backwards (they arrive sorted ascending), or shift by hand: two edits on
    one line move each other whenever the name changes length. }
  TPasRenameEdit = record
    FilePath: string;
    Line, Col: Integer;      // 1-based, of the OLD identifier
    Len: Integer;            // length of the OLD identifier
    OldText: string;         // the exact text being replaced, for a host's
                             // own "has the buffer moved since?" check
    IsDecl: Boolean;         // this is the declaration site itself
    Snippet: string;         // the line AFTER all of its own edits
    HiFrom, HiTo: Integer;   // 0-based offsets of the NEW name in Snippet
  end;

  TPasNavigator = class
  private type
    TNavCache = class
      // The model snapshot this cache was built from. If the project later
      // publishes a different snapshot at the same model id (the async
      // parser's intf->full upgrade, or an edit-reanalysis), CacheOf detects
      // the mismatch and rebuilds - the cached raw/visible/node indices are
      // only valid for the exact tree they came from.
      SourceModel: TPasSemaModel;
      VisOfRaw: TArray<Integer>;                 // raw idx -> visible idx | -1
      NodeOfVis: TDictionary<Integer, Integer>;  // visible idx -> nkIdent node
      // Declaration<->implementation pairing (routine decl<->impl toggle),
      // built lazily on first use - most editing sessions never need it.
      RoutinesBuilt: Boolean;
      RoutineOfVis: TArray<Integer>;      // visible idx -> innermost enclosing
                                          // nkRoutine node, or NIL_NODE
      DeclKey, ImplKey: TDictionary<string, Integer>;       // exact arity
      DeclKeyLoose, ImplKeyLoose: TDictionary<string, Integer>; // arity-blind
                                                                 // fallback
      // Reverse of every symbol's OWN DeclNode -- lets SymbolAt answer "Find
      // References" from the DECLARATION site itself (a type's own name, a
      // field, a routine header...), not only from a place that USES it.
      // Built eagerly alongside NodeOfVis, same cost shape (one pass, bounded
      // by this model's own symbol count rather than its node count).
      DeclSymOfNode: TDictionary<Integer, Integer>;
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
    function CalleeCallOf(LM: TPasSemaModel; ANode: Integer): Integer;
    function UsesQualifierInfo(AMid, ANode: Integer;
      out ALeaf, ASpanFirstVis, ASpanLastVis: Integer): Boolean;
    function ResolveUnitRefTarget(AMid, ASym: Integer;
      out ATarget: TPasNavTarget): Boolean;
    function TargetForUnitId(AUid: Integer; const AName: string;
      out ATarget: TPasNavTarget): Boolean;
    function ResolveSymbolAt(AMid, ANode: Integer;
      out ATMid, ASym: Integer): Boolean;
    function IsDeclSelfName(LM: TPasSemaModel; ASym, ANode: Integer): Boolean;
    function IsOwnUnitNameNode(LM: TPasSemaModel; ANode: Integer): Boolean;
    function HitFromNode(LM: TPasSemaModel; ANode: Integer;
      out AHit: TPasRefHit): Boolean;
    // Declaration<->implementation toggle helpers (all pure CST walks - no
    // dependency on the resolver's symbol table, so a redeclaration or an
    // unusual overload shape can never break navigation, only miss it).
    function VisAt(AMid, ALine, ACol: Integer): Integer;
    function TargetFromVis(AMid, AVisIdx: Integer; const AName: string;
      out ATarget: TPasNavTarget): Boolean;
    function RTIsStructKind(AKind: TPasNodeKind): Boolean;
    function RTFindChildKind(LM: TPasSemaModel; ANode: Integer;
      AKind: TPasNodeKind): Integer;
    function RTSkipAttr(LM: TPasSemaModel; AChild: Integer): Integer;
    function RTSepAfter(LM: TPasSemaModel; ANode: Integer): TPasTokenKind;
    function RTSegments(LM: TPasSemaModel; ANode: Integer;
      out AQualIdents: TArray<Integer>; out ANameNode: Integer): Boolean;
    function RTSpanText(LM: TPasSemaModel; ANode: Integer): string;
    function RTParamSignature(LM: TPasSemaModel; ANode: Integer): string;
    function RTEnclosingRoutine(LM: TPasSemaModel; ANode: Integer): Integer;
    function RTEnclosingTypeChain(LM: TPasSemaModel;
      ADeclNode: Integer): TArray<string>;
    function RTMethodKey(const AChain: TArray<string>;
      const AName, ASignature: string): string;
    function RTMethodKeyLoose(const AChain: TArray<string>;
      const AName: string): string;
    function RTRoutineKey(AContainer: Integer;
      const AName, ASignature: string): string;
    function RTRoutineKeyLoose(AContainer: Integer; const AName: string):
      string;
    procedure EnsureRoutinePairs(AMid: Integer; ACache: TNavCache);
    function RoutinePeerNode(AMid, ARoutine: Integer): Integer;
    function RTParamNames(LM: TPasSemaModel;
      ARoutine: Integer): TArray<Integer>;
    function PeerDeclSym(AMid, ASym: Integer): Integer;
    function PeerRoutineNameNode(AMid, ASym: Integer): Integer;
    function UnitNameHit(LM: TPasSemaModel; ANode: Integer;
      out AHit: TPasRefHit): Boolean;
    function RoutineBodyEntry(AMid: Integer; LM: TPasSemaModel;
      AImplNode: Integer; out ATarget: TPasNavTarget): Boolean;
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
    // IdentAt + ResolveSymbolAt in one step - the identity Find References
    // searches for, and the Enabled test for the command that starts one.
    function SymbolAt(AMid, ALine, ACol: Integer;
      out ATMid, ASym: Integer; out AName: string): Boolean;
    // Every place ASym (declared in model ATMid) is actually USED, by
    // resolved symbol identity - never a text search. See the
    // implementation comment for what that does and does not cover.
    function FindReferences(ATMid, ASym: Integer): TArray<TPasRefHit>;
    // The declaration site FindReferences itself always excludes (see its
    // own comment) - a separate call because a host that wants "where is
    // this defined, plus every use" (Find References' own results list,
    // with the declaration pinned first) needs the two answers kept apart:
    // the USE count must not include it. False when ASym has no DeclNode at
    // all - the implicit Result, or a symbol SymbolAt would have declined
    // in the first place (SymbolAt is expected to have gated those already;
    // this is the same test repeated so the two can never disagree).
    function DeclHit(ATMid, ASym: Integer; out AHit: TPasRefHit): Boolean;
    { Rename: the whole edit set for giving (ATMid, ASym) a new name -
      DeclHit + FindReferences, nothing else. Deliberately the SAME identity
      search Find References runs, so a rename can never touch a
      same-spelled unrelated symbol, and never reaches further than the
      references panel already showed.

      False (AError set, AEdits empty) when the new name is not a legal
      Object Pascal identifier, is a reserved word, is the current name
      unchanged, or the symbol has no declaration site (see DeclHit) - the
      last one keeps a rename from half-applying to the uses while leaving
      the declaration behind. AError is host-displayable text.

      What this does NOT do: it does not check whether the new name COLLIDES
      with something already visible at each edit site (Object Pascal
      scoping makes that a full re-resolution question, not a lookup), and
      it does not touch files - a host applies the edits and re-analyzes.
      Renaming a UNIT is not this API either (that is a file rename plus
      every `uses` clause - see FindUnitReferences). }
    function PlanRename(ATMid, ASym: Integer; const ANewName: string;
      out AEdits: TArray<TPasRenameEdit>; out AError: string): Boolean;
    { The UNIT counterpart of PlanRename: ATargetMid's own header name plus
      every `uses` item across the project that resolved to it (the same two
      answers UnitDeclHit/FindUnitReferences give, as edits). A dotted new
      name is legal here and only here - `Namespace.Foo` is one unit name.

      ARequiredFileName is what the FILE must be called for the rename to
      compile (`<new name>.pas`, dots included - Object Pascal ties a unit's
      name to its file name). This API never touches files, so a host either
      renames it or tells the user; either way it must not be left silent.

      Refuses (False, AError set, no edits) on an invalid name - each dotted
      segment must be an identifier and not a reserved word - on the
      unchanged name, and on a `uses` item whose WRITTEN text is neither the
      unit's full name nor its bare leaf (a `-A` alias, or a spelling this
      code has no rule for). That last one is a refusal rather than a skip
      on purpose: a rename that silently leaves one `uses` clause pointing
      at a name that no longer exists produces a build break, which is the
      one outcome worse than doing nothing. }
    function PlanUnitRename(ATargetMid: Integer; const ANewName: string;
      out AEdits: TArray<TPasRenameEdit>; out ARequiredFileName: string;
      out AError: string): Boolean;
    { The unit counterpart of SymbolAt/FindReferences/DeclHit: a click on
      THIS model's own header name, or on a `uses` clause item (any
      segment), resolved to the TARGET model id rather than a (unit, symbol)
      pair - a `uses` name has no single symbol identity shared across
      referring units (each gets its OWN local skUnitRef symbol), so
      searching by NAME/model instead is the only identity that means
      anything project-wide here. }
    function UnitAt(AMid, ALine, ACol: Integer; out ATargetMid: Integer;
      out AName: string): Boolean;
    // Every `uses` clause that resolved to ATargetMid, across the project.
    function FindUnitReferences(ATargetMid: Integer): TArray<TPasRefHit>;
    // ATargetMid's own header position - always available (see
    // TargetForUnitId's own comment: every analyzed model has one).
    function UnitDeclHit(ATargetMid: Integer;
      out AHit: TPasRefHit): Boolean;
    { The THIRD identity, for a compiler-seeded builtin with no source
      declaration anywhere (SymbolAt declines these - see its own comment).
      Builtins are seeded PER MODEL, so there is no (unit, symbol) pair or
      even a single target model to key a search on; the NAME is the only
      identity left, and FindBuiltinReferences below is restricted enough
      (sfBuiltin-flagged bindings only) that this stays a resolved-identity
      search, not the text search the rest of this file avoids. }
    function BuiltinNameAt(AMid, ALine, ACol: Integer;
      out AName: string): Boolean;
    // Every reference bound to a compiler-seeded builtin named AName, across
    // every loaded model.
    function FindBuiltinReferences(const AName: string): TArray<TPasRefHit>;
    { Cursor on (or inside) a routine DECLARATION with no body - a `uses`-
      section/class-member header, or a `forward`-declared global/nested
      proc - that has a matching implementation elsewhere in the SAME unit
      (Object Pascal requires it there; this never crosses units). Target
      is the first statement of the implementation's body (or, for an empty
      `begin end`, the `end` itself). False when the cursor isn't on/in a
      declaration, or no implementation matches. Also serves as the
      Enabled check for the "go to implementation" command - call with a
      throwaway ATarget. }
    function GotoImplementation(AMid, ALine, ACol: Integer;
      out ATarget: TPasNavTarget): Boolean;
    { Cursor anywhere inside a routine's IMPLEMENTATION (header or body) that
      has a separate declaration - a qualified method impl (TFoo.Bar) whose
      class declares Bar, or a global/nested proc completing a `forward`.
      Target is the declaration's own name. False when the cursor isn't
      inside an implementation, or it has no separate declaration (e.g. a
      plain routine defined directly with no forward decl - nothing to jump
      to). Also serves as the Enabled check for "go to declaration". }
    function GotoDeclaration(AMid, ALine, ACol: Integer;
      out ATarget: TPasNavTarget): Boolean;
  end;

// True when AName is a legal, unescaped Object Pascal identifier that is not
// a reserved word - PlanRename's own name test, exposed so a host can gate
// its OK button as the user types rather than only on submit.
function IsValidRenameName(const AName: string): Boolean;

// The same test for a UNIT name, where dots are part of the name: every
// segment must pass IsValidRenameName (`Namespace.Foo`, never `.Foo` or
// `Foo..Bar`). PlanUnitRename's own test, exposed for the same reason.
function IsValidUnitRenameName(const AName: string): Boolean;

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
  DeclSymOfNode.Free;
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
  LM := FProj.Model(AMid);
  if FCaches.TryGetValue(AMid, Result) then
  begin
    if Result.SourceModel = LM then
      Exit;
    // Stale: the project swapped in a new snapshot at this id. Drop the cache
    // (doOwnsValues frees it) and rebuild against the current model.
    FCaches.Remove(AMid);
  end;
  Result := TNavCache.Create;
  Result.SourceModel := LM;
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
  Result.DeclSymOfNode := TDictionary<Integer, Integer>.Create;
  for LIdx := 0 to LM.SymCount - 1 do
    if LM.Symbols[LIdx].DeclNode <> NIL_NODE then
      Result.DeclSymOfNode.AddOrSetValue(LM.Symbols[LIdx].DeclNode, LIdx);
  FCaches.Add(AMid, Result);
end;

// Walks up from ANode (an nkIdent) through any nested nkMember parents to the
// outermost one; if THAT node's own parent is nkUsesItem, ANode is a segment
// of a `uses` clause's (possibly dotted) unit name. Returns the name's LEAF
// segment (the deepest last-child - e.g. SysUtils in System.SysUtils; ANode
// itself for a plain undotted name) and the VISIBLE-index span covering every
// segment and dot (leftmost descendant's FirstToken .. the outermost node's
// own LastToken - deliberately excludes a trailing `in 'path'` sibling,
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
  LTS: TPasTokenStream;   // record copy - the arrays inside are shared refs
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
    // Not a `uses` name - but LNode may still be a namespace-qualifier
    // segment of a dotted EXPRESSION (`System`/`SysUtils` in `System.
    // SysUtils.TBytes`): widen the span to the WHOLE qualifier (never the
    // trailing member), same "any segment links the same way" UX as a
    // `uses` clause's dotted name. Node is NOT redirected here (unlike the
    // `uses` case) - ResolveDecl's qualifier check climbs from wherever it's
    // given, so the originally-clicked node already works.
    // GUARD: only when LNode has NO resolution of its own (RefMap AND
    // ExtRefMap both miss) - QualifierUnitAt climbs to the outermost member
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
  // A demoted model's text layer comes back on demand (per goto - cheap);
  // when the file changed underneath, "no target" beats a wrong position.
  if not FProj.EnsureHydrated(AMid) then
    Exit;
  LM := FProj.Model(AMid);
  // An nkMember's OWN FirstToken is the '.' (see PasTree.Ast), not its first
  // visible character - descend to the leftmost descendant so a dotted
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
// clause's own name, in THIS unit - jumping there would just land on
// itself); it's the FILE that unit resolved to. Falls back to (1,1) of that
// file if the target unit's own name node isn't available for some reason
// (never observed - every analyzed model has one, see CollectRoot), so
// "open the file" still works even in that edge case. False when the use
// never resolved to a real file (ASym.Flags has sfExternalUnresolved and no
// UsesList entry names a UnitId - nothing to open).
// A target that just opens AUid's own file, at its own declaration (node 0's
// FirstChild, per CollectRoot's known shape) - falls back to (1,1) of that
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
// System unit - e.g. TBytes resolves locally to a builtin yet is really
// declared in System.SysUtils; TObject/TArray<T>/... in System.

// The routine-name ident node of the routine/anon scope owning ASym - used to
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

// The nkCall whose CALLEE the identifier ANode names - either directly
// (`Pick(...)`: the ident IS the call's first child) or as the member-name
// segment of the callee designator (`GB.Add(...)`, `XO.Pick(...)`,
// `TWrap<Integer>.Create(...)`: the ident is the LAST child of an nkMember
// that is the call's first child). NIL_NODE when ANode is not a callee name
// (including a qualifier/base segment - `GB` in `GB.Add(7)` is the object,
// not the routine).
function TPasNavigator.CalleeCallOf(LM: TPasSemaModel; ANode: Integer): Integer;
var
  LP, LPP: Integer;
begin
  Result := NIL_NODE;
  LP := LM.Tree.Nodes[ANode].Parent;
  if LP = NIL_NODE then
    Exit;
  if (LM.Tree.Nodes[LP].Kind = nkCall) and
     (LM.Tree.Nodes[LP].FirstChild = ANode) then
    Exit(LP);
  if (LM.Tree.Nodes[LP].Kind = nkMember) and
     (LM.Tree.Nodes[LP].FirstChild <> ANode) and
     (LM.Tree.Nodes[ANode].NextSibling = NIL_NODE) then
  begin
    LPP := LM.Tree.Nodes[LP].Parent;
    if (LPP <> NIL_NODE) and (LM.Tree.Nodes[LPP].Kind = nkCall) and
       (LM.Tree.Nodes[LPP].FirstChild = LP) then
      Exit(LPP);
  end;
end;

// Resolves ANode to the (unit id, symbol) pair that IS the identity every
// other reference to the same entity is recorded against - RefMap for a
// same-model reference, ExtRefMap for a cross-model one. False only for a
// node that names nothing at all: no local binding, no cross-unit one.
//
// Deliberately stops HERE rather than reaching for ResolveDecl's further
// fallbacks (a bare namespace-qualifier segment via QualifierUnitAt, a
// builtin redirected to a used unit's real declaration via ResolveRealDecl,
// the intrinsic-with-no-declaration-anywhere case) - those answer WHERE TO
// NAVIGATE, a different question from WHAT is being asked about, and none of
// them hands back a stable (unit, symbol) pair a project-wide scan could
// search FOR: a namespace qualifier has no symbol of its own at all, and
// ResolveRealDecl's redirect only ever fires transiently inside a member/
// ancestor walk (FindMemberX and friends), never as the identity actually
// stored at a plain identifier reference - every OTHER unit's own bare use
// of the same builtin NAME still binds to that unit's own separately-seeded
// symbol (builtins are seeded PER MODEL - PasTree.Sema.Builtins), so
// redirecting here would not make the scan any more complete, only harder
// to reason about. The implicit `Result` variable needs no special case:
// it IS a real, ordinary RefMap hit (a per-routine symbol, just body-less by
// construction), so it falls out of the plain lookup below for free.
function TPasNavigator.ResolveSymbolAt(AMid, ANode: Integer;
  out ATMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
  LExt: TPasExtRef;
begin
  Result := False;
  ATMid := -1;
  ASym := NIL_SYM;
  if (AMid < 0) or (ANode = NIL_NODE) then
    Exit;
  LM := FProj.Model(AMid);
  ATMid := AMid;
  ASym := LM.RefMap[ANode];
  if ASym = NIL_SYM then
  begin
    if not LM.ExtRefMap.TryGetValue(ANode, LExt) then
      Exit;
    ATMid := LExt.UnitId;
    ASym := LExt.Sym;
  end;
  Result := True;
end;

function TPasNavigator.ResolveDecl(AMid, ANode: Integer;
  out ATarget: TPasNavTarget): Boolean;
var
  LM: TPasSemaModel;
  LExt: TPasExtRef;
  LTMid, LSym, LFbMid, LFbSym, LQUid, LMatchNode, LCall: Integer;
begin
  Result := False;
  if (AMid < 0) or (ANode = NIL_NODE) then
    Exit;
  LM := FProj.Model(AMid);

  // OVERLOAD-PRECISE: the clicked identifier names the callee of a call whose
  // argument-matched overload was recorded - CallTargetX (CrossType's merged
  // cross-model selection) first, the intra-unit CallTarget as fallback. Jump
  // to THAT overload's declaration instead of the name-resolution head: the
  // real IDE navigates `Pick(2.5)` to the Double overload, not to whichever
  // overload happens to head the chain. Falls through to the ordinary paths
  // below when the call has no recorded target (nothing fit / a cast / not a
  // callee at all).
  LCall := CalleeCallOf(LM, ANode);
  if LCall <> NIL_NODE then
  begin
    if LM.CallTargetX.TryGetValue(LCall, LExt) and
       (FProj.Model(LExt.UnitId).Symbols[LExt.Sym].DeclNode <> NIL_NODE) then
      Exit(TargetFromNode(LExt.UnitId,
        FProj.Model(LExt.UnitId).Symbols[LExt.Sym].DeclNode,
        FProj.Model(LExt.UnitId).Symbols[LExt.Sym].Name, ATarget));
    if LM.CallTarget.TryGetValue(LCall, LSym) and (LSym <> NIL_SYM) and
       (LM.Symbols[LSym].DeclNode <> NIL_NODE) then
      Exit(TargetFromNode(AMid, LM.Symbols[LSym].DeclNode,
        LM.Symbols[LSym].Name, ATarget));
  end;

  if not ResolveSymbolAt(AMid, ANode, LTMid, LSym) then
  begin
    // Not a value/type reference at all - ANode may still be a NAMESPACE
    // QUALIFIER segment of a bigger dotted expression (`System`/`SysUtils`
    // in `System.SysUtils.TBytes`, `System` alone in `System.sLineBreak`):
    // real dcc lets you click/hover the qualifier itself, same as a `uses`
    // clause name, distinct from the MEMBER (TBytes/sLineBreak), which
    // resolves via ResolveSymbolAt's ordinary ExtRefMap path above instead.
    LQUid := FProj.QualifierUnitAt(AMid, ANode, LMatchNode);
    if LQUid >= 0 then
      Exit(TargetForUnitId(LQUid, LM.Tree.NodeText(ANode), ATarget));
    Exit;
  end;

  // A `uses` clause name (skUnitRef): its own DeclNode is just the clause's
  // own spelling in THIS unit, not a useful jump target - go to the
  // REFERENCED unit's file instead.
  if FProj.Model(LTMid).Symbols[LSym].Kind = skUnitRef then
    Exit(ResolveUnitRefTarget(LTMid, LSym, ATarget));

  // A resolved symbol with a real declaration node - the common case.
  if FProj.Model(LTMid).Symbols[LSym].DeclNode <> NIL_NODE then
    Exit(TargetFromNode(LTMid, FProj.Model(LTMid).Symbols[LSym].DeclNode,
      FProj.Model(LTMid).Symbols[LSym].Name, ATarget));

  // No source declaration (a compiler builtin or the implicit Result):
  // 1) a builtin a used unit (or the implicit System unit) actually declares
  //    (TBytes -> System.SysUtils; TObject/TArray<T> -> System);
  if FProj.ResolveRealDecl(AMid, LM.Tree.NodeNameLower(ANode), LFbMid,
    LFbSym) then
    Exit(TargetFromNode(LFbMid, FProj.Model(LFbMid).Symbols[LFbSym].DeclNode,
      FProj.Model(LFbMid).Symbols[LFbSym].Name, ATarget));
  // 2) the implicit Result -> its enclosing routine's declaration.
  if (FProj.Model(LTMid).Symbols[LSym].Kind = skVar) and
     SameText(FProj.Model(LTMid).Symbols[LSym].Name, 'Result') then
    Exit(TargetFromNode(LTMid, RoutineNameNodeOfSym(LTMid, LSym), 'Result',
      ATarget));
  // 3) a compiler INTRINSIC with no source declaration anywhere (Integer,
  //    Length, True... - real System.pas literally says "Predefined
  //    constants, types, procedures, and functions do not have actual
  //    declarations"): target the real System unit's own header, exactly
  //    what the RAD Studio IDE does for these.
  Result := TargetForUnitId(FProj.EnsureSystemUnit,
    FProj.Model(LTMid).Symbols[LSym].Name, ATarget);
end;

// IdentAt + ResolveSymbolAt in one step. False exactly when there is nothing
// under the cursor with a STABLE identity: no identifier at all, or one that
// resolves to a compiler intrinsic with no source declaration ANYWHERE
// (Length, Integer, True...).
//
// A seeded builtin that DOES have a real declaration somewhere reachable
// (TObject/Exception/TBytes/TArray...) is redirected there - the same
// ResolveRealDecl hop ResolveDecl's own fallback (1) uses for navigation,
// reused here for identity. Builtins are seeded PER MODEL (PasTree.Sema.
// Builtins), so this is NOT a complete project-wide answer: every OTHER
// unit's own bare use of the same name still binds to ITS OWN separately-
// seeded copy, never to this redirected symbol - but the declaring unit's
// OWN body resolves the name to the REAL declaration directly (a real
// declaration outranks a seed in its own scope, same precedence a member
// gets over a predefined name - 11 sec. 11.4), so the search is genuinely
// complete within THAT unit, just not beyond it. Showing that is more
// honest than an outright refusal, which is what this used to do.
//
// The implicit `Result` needs no gate: no DeclNode either, but a plain
// lookup already handles it correctly - see ResolveSymbolAt's own comment.
function TPasNavigator.SymbolAt(AMid, ALine, ACol: Integer;
  out ATMid, ASym: Integer; out AName: string): Boolean;
var
  LIdent: TPasNavIdent;
  LCache: TNavCache;
  LFbMid, LFbSym: Integer;
begin
  Result := False;
  if not IdentAt(AMid, ALine, ACol, LIdent) then
    Exit;
  // The DECLARATION site itself - a type's own name, a field, a routine
  // header (interface OR implementation; each overload's own DeclNode is
  // distinct and reliable, unlike the ordinary REFERENCE binding those
  // headers ALSO carry - see IsDeclSelfName), a parameter, anything with a
  // real DeclNode. Checked before the ordinary reference path below so a
  // click here always answers with ITS OWN identity, never something an
  // incidental self-reference happened to resolve to.
  //
  // skUnitRef is excluded: a `uses` name's DeclNode is its LEAF segment
  // (CollectUsesItem), but that symbol means nothing outside the referring
  // unit - UnitAt/FindUnitReferences is the right tool for it, not this.
  LCache := CacheOf(AMid);
  if LCache.DeclSymOfNode.TryGetValue(LIdent.Node, ASym) and
     (FProj.Model(AMid).Symbols[ASym].Kind <> skUnitRef) then
  begin
    ATMid := AMid;
    AName := FProj.Model(AMid).Symbols[ASym].Name;
    Exit(True);
  end;
  if not ResolveSymbolAt(AMid, LIdent.Node, ATMid, ASym) then
    Exit;
  if (FProj.Model(ATMid).Symbols[ASym].DeclNode = NIL_NODE) and
     not SameText(FProj.Model(ATMid).Symbols[ASym].Name, 'Result') then
  begin
    if not FProj.ResolveRealDecl(AMid,
      FProj.Model(ATMid).Symbols[ASym].NameLower, LFbMid, LFbSym) then
      Exit;
    ATMid := LFbMid;
    ASym := LFbSym;
  end;
  AName := FProj.Model(ATMid).Symbols[ASym].Name;
  Result := True;
end;

// True when ANode (a same-model RefMap hit - never reached for a cross-
// model ExtRefMap one, see FindReferences: a routine's decl and impl are
// ALWAYS in the same unit, and no unit's ExtRefMap entry can ever literally
// BE another unit's own declaration node) is the entity NAMING ITSELF in a
// declaration or implementation header, rather than a genuine use.
//
// The routine case is checked STRUCTURALLY, not by symbol identity, because
// identity is exactly what is unreliable here: an unqualified routine's own
// name in EITHER its declaration or its implementation header resolves via
// the ordinary Phase-1 lookup, which has no argument list to disambiguate
// an overload by, so EVERY overload's own header name lands on whichever
// symbol heads the chain - dcc-verified harmless everywhere else (nothing
// needs a header's own name bound to ITS SPECIFIC overload; decl<->impl
// pairing uses RTSegments' own structural match, never RefMap), but it is
// precisely the imprecision Find References must not surface: without this
// filter, searching for the FIRST overload turns up every sibling
// overload's header too, and searching for a LATER one turns up nothing of
// its own. "Is ANode the trailing name segment of the nkRoutine ANode sits
// directly inside" sidesteps the question entirely - true for every
// overload's own header regardless of which symbol RefMap happened to bind
// it to.
//
// Every other declaration (a type, a variable, a field, a routine with no
// separate implementation...) has no such ambiguity - one symbol, one
// DeclNode - and a plain equality against it also catches a type naming
// itself in its own declaration (`TThing = record`), which the resolver
// does write into RefMap.
function TPasNavigator.IsDeclSelfName(LM: TPasSemaModel;
  ASym, ANode: Integer): Boolean;
var
  LParent, LNameNode: Integer;
  LQualIdents: TArray<Integer>;
begin
  LParent := LM.Tree.Nodes[ANode].Parent;
  if (LParent <> NIL_NODE) and (LM.Tree.Nodes[LParent].Kind = nkRoutine) and
     RTSegments(LM, LParent, LQualIdents, LNameNode) and
     (LNameNode = ANode) then
    Exit(True);
  Result := ANode = LM.Symbols[ASym].DeclNode;
end;

// One hit's position + snippet from the node RefMap/ExtRefMap point at (or,
// for FindUnitReferences/UnitDeclHit, a `uses` item's whole name node or a
// unit's own header). False only when the node has no visible token
// (defensive - every node a real caller passes came from a live map entry
// or CollectRoot's own guarantee, so this should not happen in practice;
// mirrors TargetFromNode's own guard). Descends to the leftmost child first
// (same reason TargetFromNode does: an nkMember's OWN FirstToken is the DOT,
// not its first visible character) - a no-op for the common case, an
// ordinary reference's node, which is always the leaf nkIdent already (the
// CrossResolve comment on the nkMember case: "the member name of A.B is
// resolved via A's scope... never as a plain identifier"); load-bearing
// only for a dotted UNIT name, the one hit shape that can be a whole
// nkMember chain rather than its leaf.
function TPasNavigator.HitFromNode(LM: TPasSemaModel; ANode: Integer;
  out AHit: TPasRefHit): Boolean;
var
  LVisTok, LTokLen, LFirst: Integer;
  LVis: TPasVisibleToken;
  LTS: TPasTokenStream;
begin
  Result := False;
  LFirst := ANode;
  while LM.Tree.Nodes[LFirst].FirstChild <> NIL_NODE do
    LFirst := LM.Tree.Nodes[LFirst].FirstChild;
  LVisTok := LM.Tree.Nodes[LFirst].FirstToken;
  if (LVisTok < 0) or (LVisTok > High(LM.Tree.Source.Visible)) then
    Exit;
  LVis := LM.Tree.Source.Visible[LVisTok];
  LTS := LM.Tree.Source.Files[LVis.FileId];
  AHit.FilePath := LM.Tree.Source.FileNames[LVis.FileId];
  LTS.OffsetToLineCol(LTS.Tokens[LVis.TokenIndex].Start, AHit.Line, AHit.Col);
  AHit.Snippet := LTS.LineText(AHit.Line);
  LTokLen := LTS.Tokens[LVis.TokenIndex].Len;
  // The snippet is the RAW line (LineText strips only the trailing break),
  // so these offsets are directly Col-relative - see TPasRefHit's comment.
  AHit.HiFrom := AHit.Col - 1;
  AHit.HiTo := AHit.HiFrom + LTokLen;
  Result := True;
end;

{ Every place ASym (declared in model ATMid) is actually USED - resolved
  symbol identity via RefMap (same-model references) and ExtRefMap
  (cross-model), never a text search: two same-named locals in different
  scopes can never cross-pollute, and an overload-precise call site lands on
  the actual overload rather than any same-named routine.

  No separate CallTargetX scan is needed: every successful SelectCallTarget
  is immediately followed by RepointCallee (PasTree.Sema.Project.pas, the
  nkCall branch of CrossType), which writes that SAME (unit, symbol) pair
  into RefMap/ExtRefMap at the callee node - so by the time analysis has
  finished, the ordinary scan below is already overload-precise for calls,
  for free.

  A declaration's own name binds to itself surprisingly often (a type names
  itself in `TThing = record`; a routine's own header, decl AND impl alike,
  resolves its own bare name the same way any other reference does) - see
  IsDeclSelfName, called below, for what filters those back out and why the
  routine half of that needs a structural test rather than a symbol-identity
  one. Only genuine USES survive; that is also the ONLY place this scan can
  drop something the underlying maps recorded - everything else is kept.

  RefMap is scanned only for the model that IS ATMid - its entries are
  symbol ids local to that ONE model's table, so testing them against ASym
  from any OTHER model's RefMap would compare unrelated integers.
  IsDeclSelfName is likewise only ever checked there, never against an
  ExtRefMap hit: a routine's decl and impl are ALWAYS in the same unit, so a
  cross-model entry can never literally BE that unit's own declaration node.
  ExtRefMap is scanned in every model (including ATMid's own, since a
  same-unit reference can still be recorded there rather than in RefMap,
  though in practice the resolver never double-writes a node into both -
  CrossResolve's own guard skips a node whose RefMap entry is already set). }
function TPasNavigator.FindReferences(ATMid, ASym: Integer): TArray<TPasRefHit>;
var
  LHits: TList<TPasRefHit>;
  LMi, LNode: Integer;
  LM: TPasSemaModel;
  LPair: TPair<Integer, TPasExtRef>;
  LHit: TPasRefHit;
begin
  LHits := TList<TPasRefHit>.Create;
  try
    for LMi := 0 to FProj.ModelCount - 1 do
    begin
      LM := FProj.Model(LMi);
      // EnsureHydrated sits AFTER the match tests: only a model that
      // actually holds a hit pays a rehydration, so references to a hot RTL
      // symbol re-preprocess the units that USE it, not the whole closure.
      // A model that fails to rehydrate contributes no hits (HitFromNode's
      // bounds guards) rather than wrong ones.
      if LMi = ATMid then
        for LNode := 0 to High(LM.RefMap) do
          if (LM.RefMap[LNode] = ASym) and
             not IsDeclSelfName(LM, ASym, LNode) and
             FProj.EnsureHydrated(LMi) and
             HitFromNode(LM, LNode, LHit) then
            LHits.Add(LHit);
      for LPair in LM.ExtRefMap do
        if (LPair.Value.UnitId = ATMid) and (LPair.Value.Sym = ASym) and
           FProj.EnsureHydrated(LMi) and
           HitFromNode(LM, LPair.Key, LHit) then
          LHits.Add(LHit);
    end;
    Result := LHits.ToArray;
  finally
    LHits.Free;
  end;
  TArray.Sort<TPasRefHit>(Result, TComparer<TPasRefHit>.Construct(
    function(const A, B: TPasRefHit): Integer
    begin
      Result := CompareText(A.FilePath, B.FilePath);
      if Result = 0 then
        Result := A.Line - B.Line;
    end));
end;

function TPasNavigator.DeclHit(ATMid, ASym: Integer;
  out AHit: TPasRefHit): Boolean;
var
  LM: TPasSemaModel;
  LDeclNode: Integer;
begin
  Result := False;
  if ATMid < 0 then
    Exit;
  LM := FProj.Model(ATMid);
  LDeclNode := LM.Symbols[ASym].DeclNode;
  if LDeclNode = NIL_NODE then
    Exit;
  Result := HitFromNode(LM, LDeclNode, AHit);
end;

// True when ANode is (part of) THIS model's OWN unit/program/library name
// header - node 0's FirstChild, per CollectRoot's shape (TargetForUnitId
// already relies on the same node for the reverse direction: unit id ->
// its own name position). Climbs from ANode through Parent links, so any
// segment of a dotted header (`unit Namespace.Foo;`) counts, same "any
// segment links the same way" convention IdentAt's uses-clause handling
// already applies.
function TPasNavigator.IsOwnUnitNameNode(LM: TPasSemaModel;
  ANode: Integer): Boolean;
var
  LHeader, LCur: Integer;
begin
  Result := False;
  LHeader := LM.Tree.Nodes[0].FirstChild;
  if LHeader = NIL_NODE then
    Exit;
  LCur := ANode;
  while LCur <> NIL_NODE do
  begin
    if LCur = LHeader then
      Exit(True);
    LCur := LM.Tree.Nodes[LCur].Parent;
  end;
end;

function TPasNavigator.UnitAt(AMid, ALine, ACol: Integer;
  out ATargetMid: Integer; out AName: string): Boolean;
var
  LIdent: TPasNavIdent;
  LM: TPasSemaModel;
  LSym, LIdx: Integer;
begin
  Result := False;
  if not IdentAt(AMid, ALine, ACol, LIdent) then
    Exit;
  LM := FProj.Model(AMid);
  if IsOwnUnitNameNode(LM, LIdent.Node) then
  begin
    ATargetMid := AMid;
    AName := LM.Tree.NodeText(LM.Tree.Nodes[0].FirstChild);
    Exit(True);
  end;
  // IdentAt already redirects any segment of a dotted `uses` name to its
  // LEAF (UsesQualifierInfo), which is exactly where CollectUsesItem put
  // the local skUnitRef symbol's own DeclNode - so a plain RefMap read
  // here is enough, no separate qualifier climb needed.
  LSym := LM.RefMap[LIdent.Node];
  if (LSym = NIL_SYM) or (LM.Symbols[LSym].Kind <> skUnitRef) then
    Exit;
  for LIdx := 0 to High(LM.UsesList) do
    if LM.UsesList[LIdx].Sym = LSym then
    begin
      if LM.UsesList[LIdx].UnitId < 0 then
        Exit;   // unresolved uses -- nothing to search for
      ATargetMid := LM.UsesList[LIdx].UnitId;
      AName := LM.Symbols[LSym].Name;
      Exit(True);
    end;
end;

// Every `uses` clause that resolved to ATargetMid, across the project - the
// unit counterpart of FindReferences. UsesList's own NameNode may be a
// dotted nkMember chain (CollectUsesItem stores the WHOLE name, not just
// the leaf, unlike the symbol's own DeclNode) - HitFromNode's own leftmost
// descent handles that shape directly.
function TPasNavigator.FindUnitReferences(
  ATargetMid: Integer): TArray<TPasRefHit>;
var
  LHits: TList<TPasRefHit>;
  LMi, LIdx: Integer;
  LM: TPasSemaModel;
  LHit: TPasRefHit;
begin
  LHits := TList<TPasRefHit>.Create;
  try
    for LMi := 0 to FProj.ModelCount - 1 do
    begin
      LM := FProj.Model(LMi);
      for LIdx := 0 to High(LM.UsesList) do
        if (LM.UsesList[LIdx].UnitId = ATargetMid) and
           HitFromNode(LM, LM.UsesList[LIdx].NameNode, LHit) then
          LHits.Add(LHit);
    end;
    Result := LHits.ToArray;
  finally
    LHits.Free;
  end;
  TArray.Sort<TPasRefHit>(Result, TComparer<TPasRefHit>.Construct(
    function(const A, B: TPasRefHit): Integer
    begin
      Result := CompareText(A.FilePath, B.FilePath);
      if Result = 0 then
        Result := A.Line - B.Line;
    end));
end;

function TPasNavigator.UnitDeclHit(ATargetMid: Integer;
  out AHit: TPasRefHit): Boolean;
var
  LM: TPasSemaModel;
  LHeader: Integer;
begin
  Result := False;
  if ATargetMid < 0 then
    Exit;
  LM := FProj.Model(ATargetMid);
  LHeader := LM.Tree.Nodes[0].FirstChild;
  Result := (LHeader <> NIL_NODE) and HitFromNode(LM, LHeader, AHit);
end;

function TPasNavigator.BuiltinNameAt(AMid, ALine, ACol: Integer;
  out AName: string): Boolean;
var
  LIdent: TPasNavIdent;
  LM: TPasSemaModel;
  LSym, LFbMid, LFbSym: Integer;
begin
  Result := False;
  if not IdentAt(AMid, ALine, ACol, LIdent) then
    Exit;
  LM := FProj.Model(AMid);
  LSym := LM.RefMap[LIdent.Node];
  if (LSym = NIL_SYM) or not (sfBuiltin in LM.Symbols[LSym].Flags) then
    Exit;
  // A builtin that DOES have a real declaration reachable somewhere is
  // SymbolAt's job (its own ResolveRealDecl redirect gives a precise
  // (unit, symbol) identity) -- this name-based fallback is only for the
  // ones that genuinely have none.
  if FProj.ResolveRealDecl(AMid, LM.Symbols[LSym].NameLower, LFbMid, LFbSym)
  then
    Exit;
  AName := LM.Symbols[LSym].Name;
  Result := True;
end;

function TPasNavigator.FindBuiltinReferences(
  const AName: string): TArray<TPasRefHit>;
var
  LHits: TList<TPasRefHit>;
  LMi, LNode, LSym: Integer;
  LM: TPasSemaModel;
  LHit: TPasRefHit;
begin
  LHits := TList<TPasRefHit>.Create;
  try
    for LMi := 0 to FProj.ModelCount - 1 do
    begin
      LM := FProj.Model(LMi);
      for LNode := 0 to High(LM.RefMap) do
      begin
        LSym := LM.RefMap[LNode];
        if (LSym <> NIL_SYM) and (sfBuiltin in LM.Symbols[LSym].Flags) and
           SameText(LM.Symbols[LSym].Name, AName) and
           HitFromNode(LM, LNode, LHit) then
          LHits.Add(LHit);
      end;
    end;
    Result := LHits.ToArray;
  finally
    LHits.Free;
  end;
  TArray.Sort<TPasRefHit>(Result, TComparer<TPasRefHit>.Construct(
    function(const A, B: TPasRefHit): Integer
    begin
      Result := CompareText(A.FilePath, B.FilePath);
      if Result = 0 then
        Result := A.Line - B.Line;
    end));
end;

{ Declaration <-> implementation toggle.

  Object Pascal never lets a routine's implementation live in a different
  unit from its declaration (a `forward`-declared or class-member routine
  MUST be completed in the same unit), so this whole feature is a pure,
  intra-model CST walk - no project/cross-unit involvement, unlike the rest
  of this file. Two routine shapes get paired:

    - A METHOD: a class/record/interface/object member declaration (always
      unqualified, always body-less) paired with its qualified
      implementation (`TFoo.Bar`, or `TOuter.TInner.Bar` for a nested
      class) elsewhere in the unit. Matched by the type's own name CHAIN
      (walking the declaration's enclosing nkTypeDecl nodes outward, and
      the implementation's qualifier segments - see RTEnclosingTypeChain/
      RTSegments) + method name + parameter count.

    - A GLOBAL or NESTED routine: an unqualified `forward`-declared header
      (interface section, or directly in the implementation section, or
      inside another routine's local declarations for a nested proc) paired
      with its later same-name implementation in the SAME lexical
      container (the unit itself, or the enclosing routine - see
      RTEnclosingRoutine) + parameter count.

  Parameter count (not full type matching) disambiguates overloads - the
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
  // A position inside a Skipped ($IFDEF'd-out) region has NO visible
  // mapping at all - not even its real identifier/keyword tokens are
  // promoted to the Visible stream (the preprocessor drops the whole
  // inactive branch, so the parser/AST never sees it). Walking backward
  // from there would cross the ENTIRE inactive region and land on
  // unrelated ACTIVE code before it - refuse outright instead: a caret
  // sitting in dead code has no valid nav target, active or otherwise.
  if LM.Tree.Source.IsSkipped(0, LOffset) then
    Exit;
  // The raw token containing this position may be whitespace/a comment -
  // real lexical content, but stripped before the Visible stream, so
  // VisOfRaw has no entry for it (e.g. right after `begin`, before the
  // next real token: SynEdit reports that caret column as sitting IN the
  // trailing newline). Walk BACKWARD to the nearest raw token that DOES
  // have a visible mapping - "still within whatever came before" is the
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
// - NOT an nkMember, whose FirstToken is the dot; callers here never pass
// one of those) - so no leftmost-descendant walk is needed.
function TPasNavigator.TargetFromVis(AMid, AVisIdx: Integer;
  const AName: string; out ATarget: TPasNavTarget): Boolean;
var
  LM: TPasSemaModel;
  LVis: TPasVisibleToken;
  LTS: TPasTokenStream;
begin
  Result := False;
  if not FProj.EnsureHydrated(AMid) then   // same contract as TargetFromNode
    Exit;
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

// Kind, not text: both consumers test a single punctuation token, and the
// kind answers without a string copy (mirrors the resolver's SepKindAfter).
function TPasNavigator.RTSepAfter(LM: TPasSemaModel;
  ANode: Integer): TPasTokenKind;
var
  LNext: Integer;
begin
  LNext := LM.Tree.Nodes[ANode].LastToken + 1;
  if (LNext >= 0) and (LNext <= High(LM.Tree.Source.Visible)) then
    Result := LM.Tree.Source.VisibleToken(LNext).Kind
  else
    Result := tkUnknown;
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
    if RTSepAfter(LM, LSegLast) = tkDot then
      AQualIdents := AQualIdents + [LSegIdent]
    else
    begin
      ANameNode := LSegIdent;
      Break;
    end;
  end;
  Result := ANameNode <> NIL_NODE;
end;

// Raw source text spanning ANode's own tokens (leftmost descendant's
// FirstToken - an nkMember's OWN FirstToken is the dot, see PasTree.Ast -
// through ANode's LastToken), concatenated with no separators. Used to
// render a parameter's TYPE EXPRESSION verbatim regardless of shape (a
// plain `string`/`PChar` ident, or something with its own internal tokens
// like `TArray<Integer>`), for signature matching below.
function TPasNavigator.RTSpanText(LM: TPasSemaModel; ANode: Integer): string;
var
  LFirstNode, LFirst, LLast, LIdx: Integer;
begin
  Result := '';
  if ANode = NIL_NODE then
    Exit;
  LFirstNode := ANode;
  while LM.Tree.Nodes[LFirstNode].FirstChild <> NIL_NODE do
    LFirstNode := LM.Tree.Nodes[LFirstNode].FirstChild;
  LFirst := LM.Tree.Nodes[LFirstNode].FirstToken;
  LLast := LM.Tree.Nodes[ANode].LastToken;
  if (LFirst < 0) or (LLast < 0) or (LFirst > LLast) or
     (LLast > High(LM.Tree.Source.Visible)) then
    Exit;
  for LIdx := LFirst to LLast do
    Result := Result + LM.Tree.Source.VisibleText(LIdx);
end;

// Parameter-list SIGNATURE: one lowercased type-text entry per parameter
// SLOT (`S1, S2: string` contributes "string" TWICE, matching how each
// name gets its own arity slot), joined with '|'. '' for a parameterless
// routine or one with no repeated param list at all (a body-less external/
// forward completion - rare enough here that the loose, signature-blind
// key covers it).
//
// Replaces a plain parameter COUNT (the first version of this feature):
// two overloads with the SAME arity but different parameter TYPES - e.g.
// `AnsiCompareFileName(PChar,Integer,PChar,Integer,Boolean)` vs the
// `(string,Integer,string,Integer,Boolean)` overload, both arity 5 - used
// to collide on the exact key, and which of the two "won" (first-
// registered, in the position index's span-size-descending processing
// order - NOT source order) had no relation to which the user actually
// clicked. Default values are NOT part of the signature - real Object
// Pascal only allows them on the declaration side, never repeated in the
// implementation, so comparing them would always mismatch by design.
// Parameter MODIFIERS (const/var/out) are not distinguished either: the
// keyword is consumed by the parser without leaving an AST node of its own
// (see ParseParamList), so there is nothing here to compare it against -
// an accepted, narrower gap than the arity-only collision this replaces.
function TPasNavigator.RTParamSignature(LM: TPasSemaModel;
  ANode: Integer): string;
var
  LParams, LParam, LChild, LType, LNameCount, LI: Integer;
  LTypeText: string;
begin
  Result := '';
  LParams := RTFindChildKind(LM, ANode, nkParams);
  if LParams = NIL_NODE then
    Exit;
  LParam := LM.Tree.Nodes[LParams].FirstChild;
  while LParam <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LParam].Kind = nkParam then
    begin
      LChild := RTSkipAttr(LM, LM.Tree.Nodes[LParam].FirstChild);
      LNameCount := 0;
      LType := NIL_NODE;
      while (LChild <> NIL_NODE) and (LM.Tree.Nodes[LChild].Kind = nkIdent) do
      begin
        Inc(LNameCount);
        if RTSepAfter(LM, LChild) = tkColon then
        begin
          LType := LM.Tree.Nodes[LChild].NextSibling;
          Break;
        end;
        LChild := LM.Tree.Nodes[LChild].NextSibling;
        if (LChild <> NIL_NODE) and (LM.Tree.Nodes[LChild].Kind <> nkIdent)
        then
          Break;
      end;
      if LType <> NIL_NODE then
        LTypeText := LowerCase(RTSpanText(LM, LType))
      else
        LTypeText := '?';   // untyped param - rare (`var X` with no type)
      for LI := 1 to LNameCount do
        Result := Result + LTypeText + '|';
    end;
    LParam := LM.Tree.Nodes[LParam].NextSibling;
  end;
end;

// The nearest ENCLOSING nkRoutine ancestor of ANode itself (climbing from
// its parent) - NIL_NODE for anything at unit top level. The lexical
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
// "tinner"] for a method of TOuter.TInner) - climbs struct-type node ->
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
    Result := [LM.Tree.NodeNameLower(LNameNode)] + Result;
    LCur := LM.Tree.Nodes[LTypeDecl].Parent;
    // A `type` SECTION nested inside a class body (`type TInner = class ...
    // end; end;`) wraps its nkTypeDecl children in an nkTypeSec - one more
    // hop to reach the OUTER struct body itself, same as a bare nested
    // nkTypeDecl (adopted directly, no section wrapper) would already be.
    if (LCur <> NIL_NODE) and (LM.Tree.Nodes[LCur].Kind = nkTypeSec) then
      LCur := LM.Tree.Nodes[LCur].Parent;
  end;
end;

function TPasNavigator.RTMethodKey(const AChain: TArray<string>;
  const AName, ASignature: string): string;
begin
  Result := 'M#' + string.Join('.', AChain) + '#' + AName + '#' + ASignature;
end;

// Signature-blind fallback key - a DIFFERENT tag ('ML#'), not just AMethodKey
// called with an empty signature: a genuinely parameterless routine already
// has signature '', so reusing that as the "don't care" marker would let a
// 0-arg routine's exact key collide with another routine's loose key.
function TPasNavigator.RTMethodKeyLoose(const AChain: TArray<string>;
  const AName: string): string;
begin
  Result := 'ML#' + string.Join('.', AChain) + '#' + AName;
end;

function TPasNavigator.RTRoutineKey(AContainer: Integer;
  const AName, ASignature: string): string;
begin
  Result := 'U#' + IntToStr(AContainer) + '#' + AName + '#' + ASignature;
end;

function TPasNavigator.RTRoutineKeyLoose(AContainer: Integer;
  const AName: string): string;
begin
  Result := 'UL#' + IntToStr(AContainer) + '#' + AName;
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

  // Count-tracked doubling - `+ [x]` re-copied the array per routine, which
  // is O(routines^2) on every cache build.
  LRoutineIds := nil;
  var LRCount := 0;
  for LIdx := 0 to High(LM.Tree.Nodes) do
    if LM.Tree.Nodes[LIdx].Kind = nkRoutine then
    begin
      if LRCount = Length(LRoutineIds) then
        SetLength(LRoutineIds, LRCount * 2 + 16);
      LRoutineIds[LRCount] := LIdx;
      Inc(LRCount);
    end;
  SetLength(LRoutineIds, LRCount);

  // Position index: widest (outermost) span first, so a later, NARROWER
  // (nested) routine's marking correctly overwrites its outer's - avoids an
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
    LName := LM.Tree.NodeNameLower(LNameNode);
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
          LChain[LIdx] := LM.Tree.NodeNameLower(LQualIdents[LIdx]);
      end
      else
        // Unqualified but struct-parented: always the class-member decl.
        LChain := RTEnclosingTypeChain(LM, LR);
      LKey := RTMethodKey(LChain, LName, RTParamSignature(LM, LR));
      LKeyLoose := RTMethodKeyLoose(LChain, LName);
    end
    else
    begin
      LKey := RTRoutineKey(RTEnclosingRoutine(LM, LR), LName,
        RTParamSignature(LM, LR));
      LKeyLoose := RTRoutineKeyLoose(RTEnclosingRoutine(LM, LR), LName);
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

// The implementation's own body-entry target: the first statement's own
// start, OR - for a body with NO statements at all - the line right AFTER
// the opening `begin`/`asm` keyword, column 1. That covers both a truly
// empty `begin end` (nothing else to land on but `end`, computed by simply
// being the next line) AND a body that holds only a COMMENT (PasTree drops
// comments before the AST entirely, so `begin // note\nend;` looks
// STRUCTURALLY identical to a bare empty body here) - the caller-visible
// bug this fixes: it used to jump past a comment straight to the `end`
// keyword, when "the first line after begin" (which the comment IS
// sitting on) is what a real IDE shows and what the original feature
// request literally asked for. Computed directly from the RAW token
// stream (not the Visible one TargetFromVis uses), since a lone comment
// has no Visible-stream position to target at all.
function TPasNavigator.RoutineBodyEntry(AMid: Integer; LM: TPasSemaModel;
  AImplNode: Integer; out ATarget: TPasNavTarget): Boolean;
var
  LBody, LBlockOrAsm, LFirstStmt, LOpenVis: Integer;
  LVis: TPasVisibleToken;
  LTS: TPasTokenStream;
  LOpenLine, LOpenCol: Integer;
begin
  Result := False;
  LBody := RTFindChildKind(LM, AImplNode, nkRoutineBody);
  if LBody = NIL_NODE then
    Exit;
  LBlockOrAsm := LM.Tree.Nodes[LBody].FirstChild;
  while (LBlockOrAsm <> NIL_NODE) and
        (LM.Tree.Nodes[LBlockOrAsm].NextSibling <> NIL_NODE) do
    LBlockOrAsm := LM.Tree.Nodes[LBlockOrAsm].NextSibling;
  if LBlockOrAsm = NIL_NODE then
    Exit;
  LFirstStmt := NIL_NODE;
  case LM.Tree.Nodes[LBlockOrAsm].Kind of
    nkBlock: LFirstStmt := LM.Tree.Nodes[LBlockOrAsm].FirstChild;
    nkAsmStmt: ;   // never has statement children - always the empty path
  else
    Exit;
  end;
  if LFirstStmt <> NIL_NODE then
    Exit(TargetFromVis(AMid, LM.Tree.Nodes[LFirstStmt].FirstToken, '',
      ATarget));
  LOpenVis := LM.Tree.Nodes[LBlockOrAsm].FirstToken;   // 'begin' or 'asm'
  if (LOpenVis < 0) or (LOpenVis > High(LM.Tree.Source.Visible)) then
    Exit;
  LVis := LM.Tree.Source.Visible[LOpenVis];
  LTS := LM.Tree.Source.Files[LVis.FileId];
  LTS.OffsetToLineCol(LTS.Tokens[LVis.TokenIndex].Start, LOpenLine, LOpenCol);
  ATarget.UnitId := AMid;
  ATarget.FilePath := LM.Tree.Source.FileNames[LVis.FileId];
  ATarget.Line := LOpenLine + 1;
  ATarget.Col := 1;
  ATarget.Name := '';
  Result := True;
end;

function TPasNavigator.GotoImplementation(AMid, ALine, ACol: Integer;
  out ATarget: TPasNavTarget): Boolean;
var
  LM: TPasSemaModel;
  LCache: TNavCache;
  LVis, LDeclNode, LImplNode, LNameNode, LContainer: Integer;
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
  LName := LM.Tree.NodeNameLower(LNameNode);
  LIsMethod := (LM.Tree.Nodes[LDeclNode].Parent <> NIL_NODE) and
    RTIsStructKind(LM.Tree.Nodes[LM.Tree.Nodes[LDeclNode].Parent].Kind);
  if LIsMethod then
  begin
    LChain := RTEnclosingTypeChain(LM, LDeclNode);
    LKey := RTMethodKey(LChain, LName, RTParamSignature(LM, LDeclNode));
    LKeyLoose := RTMethodKeyLoose(LChain, LName);
  end
  else
  begin
    LContainer := RTEnclosingRoutine(LM, LDeclNode);
    LKey := RTRoutineKey(LContainer, LName, RTParamSignature(LM, LDeclNode));
    LKeyLoose := RTRoutineKeyLoose(LContainer, LName);
  end;
  if not LCache.ImplKey.TryGetValue(LKey, LImplNode) then
    if not LCache.ImplKeyLoose.TryGetValue(LKeyLoose, LImplNode) then
      Exit;
  Result := RoutineBodyEntry(AMid, LM, LImplNode, ATarget);
  if Result then
    ATarget.Name := LName;
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
  LName := LM.Tree.NodeNameLower(LNameNode);
  LIsMethod := LQualIdents <> nil;
  if LIsMethod then
  begin
    SetLength(LChain, Length(LQualIdents));
    for LIdx := 0 to High(LQualIdents) do
      LChain[LIdx] := LM.Tree.NodeNameLower(LQualIdents[LIdx]);
    LKey := RTMethodKey(LChain, LName, RTParamSignature(LM, LImplNode));
    LKeyLoose := RTMethodKeyLoose(LChain, LName);
  end
  else
  begin
    LContainer := RTEnclosingRoutine(LM, LImplNode);
    LKey := RTRoutineKey(LContainer, LName, RTParamSignature(LM, LImplNode));
    LKeyLoose := RTRoutineKeyLoose(LContainer, LName);
  end;
  if not LCache.DeclKey.TryGetValue(LKey, LDeclNode) then
    if not LCache.DeclKeyLoose.TryGetValue(LKeyLoose, LDeclNode) then
      Exit;
  if not RTSegments(LM, LDeclNode, LQualIdents, LNameNode) then
    Exit;
  Result := TargetFromVis(AMid, LM.Tree.Nodes[LNameNode].FirstToken, LName,
    ATarget);
end;

{ The routine node paired with ARoutine - a body-less declaration's
  implementation, or an implementation's own declaration - or NIL_NODE when
  it has no counterpart (an ordinary routine defined once). The same keys
  GotoImplementation/GotoDeclaration match on, in one node-level form: those
  two answer "where do I jump", this answers "which OTHER header spells the
  same routine", which is what a rename of a parameter needs. }
function TPasNavigator.RoutinePeerNode(AMid, ARoutine: Integer): Integer;
var
  LM: TPasSemaModel;
  LCache: TNavCache;
  LNameNode, LContainer, LIdx: Integer;
  LQualIdents: TArray<Integer>;
  LName, LKey, LKeyLoose: string;
  LChain: TArray<string>;
  LIsImpl, LIsMethod: Boolean;
begin
  Result := NIL_NODE;
  if (AMid < 0) or (ARoutine = NIL_NODE) then
    Exit;
  LM := FProj.Model(AMid);
  LCache := CacheOf(AMid);
  EnsureRoutinePairs(AMid, LCache);
  if LM.Tree.Nodes[ARoutine].Kind <> nkRoutine then
    Exit;
  LIsImpl := RTFindChildKind(LM, ARoutine, nkRoutineBody) <> NIL_NODE;
  if not RTSegments(LM, ARoutine, LQualIdents, LNameNode) then
    Exit;
  LName := LM.Tree.NodeNameLower(LNameNode);
  if LIsImpl then
    // A qualified implementation (TFoo.Bar) is a method's; an unqualified
    // one completes a `forward` in its own lexical container.
    LIsMethod := LQualIdents <> nil
  else
    // A declaration is a method's when a struct-type body adopted it.
    LIsMethod := (LM.Tree.Nodes[ARoutine].Parent <> NIL_NODE) and
      RTIsStructKind(LM.Tree.Nodes[LM.Tree.Nodes[ARoutine].Parent].Kind);
  if LIsMethod then
  begin
    if LIsImpl then
    begin
      SetLength(LChain, Length(LQualIdents));
      for LIdx := 0 to High(LQualIdents) do
        LChain[LIdx] := LM.Tree.NodeNameLower(LQualIdents[LIdx]);
    end
    else
      LChain := RTEnclosingTypeChain(LM, ARoutine);
    LKey := RTMethodKey(LChain, LName, RTParamSignature(LM, ARoutine));
    LKeyLoose := RTMethodKeyLoose(LChain, LName);
  end
  else
  begin
    LContainer := RTEnclosingRoutine(LM, ARoutine);
    LKey := RTRoutineKey(LContainer, LName, RTParamSignature(LM, ARoutine));
    LKeyLoose := RTRoutineKeyLoose(LContainer, LName);
  end;
  if LIsImpl then
  begin
    if not LCache.DeclKey.TryGetValue(LKey, Result) then
      if not LCache.DeclKeyLoose.TryGetValue(LKeyLoose, Result) then
        Result := NIL_NODE;
  end
  else
    if not LCache.ImplKey.TryGetValue(LKey, Result) then
      if not LCache.ImplKeyLoose.TryGetValue(LKeyLoose, Result) then
        Result := NIL_NODE;
end;

// A routine's parameter NAME nodes in source order, flattened across the
// groups a header writes them in (`(A, B: Integer; C: string)` is three).
// Position in this list is the only thing that pairs a declaration's
// parameter with the implementation's - the names are what a rename is
// changing, so they cannot be the key.
function TPasNavigator.RTParamNames(LM: TPasSemaModel;
  ARoutine: Integer): TArray<Integer>;
var
  LParams, LParam, LChild, LCount: Integer;
begin
  Result := nil;
  LCount := 0;
  LParams := RTFindChildKind(LM, ARoutine, nkParams);
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
        if LCount = Length(Result) then
          SetLength(Result, LCount * 2 + 8);
        Result[LCount] := LChild;
        Inc(LCount);
        // A colon ends the name list of this group - what follows is the
        // TYPE, which is a reference, never a parameter name.
        if RTSepAfter(LM, LChild) = tkColon then
          Break;
        LChild := LM.Tree.Nodes[LChild].NextSibling;
      end;
    end;
    LParam := LM.Tree.Nodes[LParam].NextSibling;
  end;
  SetLength(Result, LCount);
end;

{ The symbol that MUST be renamed together with ASym, or NIL_SYM.

  Object Pascal requires a routine's implementation header to repeat its
  declaration EXACTLY, parameter names included - dcc rejects a mismatch
  with E2037 ("Declaration differs from previous declaration") and then
  E2003 on the body's now-undeclared name. But a declaration's parameter and
  its implementation's parameter are two different SYMBOLS (each routine
  scope declares its own), so renaming by symbol identity alone renames one
  header and leaves the other - code that no longer compiles. This is the
  one place a rename must reach past the identity Find References reports,
  and it is a language rule, not a heuristic.

  Paired by POSITION in the parameter list, never by name (the name is what
  is being changed, and a mismatch is exactly the state a half-done rename
  leaves behind). The routine NAME itself needs the same treatment for a
  different reason - see PeerRoutineNameNode. }
function TPasNavigator.PeerDeclSym(AMid, ASym: Integer): Integer;
var
  LM: TPasSemaModel;
  LCache: TNavCache;
  LDecl, LRoutine, LPeer, LIdx: Integer;
  LNames, LPeerNames: TArray<Integer>;
begin
  Result := NIL_SYM;
  if AMid < 0 then
    Exit;
  LM := FProj.Model(AMid);
  if LM.Symbols[ASym].Kind <> skParam then
    Exit;
  LDecl := LM.Symbols[ASym].DeclNode;
  if LDecl = NIL_NODE then
    Exit;
  LRoutine := RTEnclosingRoutine(LM, LDecl);
  if LRoutine = NIL_NODE then
    Exit;
  LPeer := RoutinePeerNode(AMid, LRoutine);
  if LPeer = NIL_NODE then
    Exit;
  LCache := CacheOf(AMid);
  LNames := RTParamNames(LM, LRoutine);
  LPeerNames := RTParamNames(LM, LPeer);
  for LIdx := 0 to High(LNames) do
    if LNames[LIdx] = LDecl then
    begin
      if LIdx > High(LPeerNames) then
        Exit;   // headers disagree on arity - not this function's problem
      if not LCache.DeclSymOfNode.TryGetValue(LPeerNames[LIdx], Result) then
        Result := NIL_SYM;
      Exit;
    end;
end;

{ The OTHER header's own name node for a routine symbol, or NIL_NODE.

  A routine's declaration and its implementation share ONE symbol, so this
  is not a second identity - but FindReferences deliberately reports neither
  header (IsDeclSelfName filters a routine's own header, decl and impl
  alike: they are not uses), and DeclHit answers with only one of them. A
  rename that took just those would leave `function Foo(...)` in the
  implementation while the declaration said `function Bar(...)` - E2037, the
  same breakage the parameter case produces. So the peer header's name is
  looked up structurally and added as an edit position. }
function TPasNavigator.PeerRoutineNameNode(AMid, ASym: Integer): Integer;
var
  LM: TPasSemaModel;
  LDecl, LRoutine, LPeer, LNameNode: Integer;
  LQualIdents: TArray<Integer>;
begin
  Result := NIL_NODE;
  if AMid < 0 then
    Exit;
  LM := FProj.Model(AMid);
  if LM.Symbols[ASym].Kind <> skRoutine then
    Exit;
  LDecl := LM.Symbols[ASym].DeclNode;
  if LDecl = NIL_NODE then
    Exit;
  LRoutine := RTEnclosingRoutine(LM, LDecl);
  if LRoutine = NIL_NODE then
    Exit;
  LPeer := RoutinePeerNode(AMid, LRoutine);
  if LPeer = NIL_NODE then
    Exit;
  if RTSegments(LM, LPeer, LQualIdents, LNameNode) then
    Result := LNameNode;
end;

{ Rename }

function IsValidRenameName(const AName: string): Boolean;
var
  LIdx: Integer;
begin
  Result := False;
  if AName = '' then
    Exit;
  if not CharInSet(AName[1], ['A'..'Z', 'a'..'z', '_']) then
    Exit;
  for LIdx := 2 to Length(AName) do
    if not CharInSet(AName[LIdx], ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
      Exit;
  // A reserved word would not parse as a name here, and `&`-escaping one is
  // a deliberate act - never something a rename should do behind the user.
  Result := KeywordKind(PChar(AName), Length(AName)) = tkIdentifier;
end;

function IsValidUnitRenameName(const AName: string): Boolean;
var
  LSeg: string;
begin
  Result := False;
  if AName = '' then
    Exit;
  for LSeg in AName.Split(['.']) do
    if not IsValidRenameName(LSeg) then
      Exit;
  Result := True;
end;

{ A `uses` item's or a unit header's WHOLE written name as one hit -
  HitFromNode deliberately reports only the first token (its highlight
  convention: one identifier), but a dotted unit name is ONE name, and a
  rename replaces all of it or none of it. False when the name spans files
  or lines (nothing legitimate does; a rename must not guess at it). }
function TPasNavigator.UnitNameHit(LM: TPasSemaModel; ANode: Integer;
  out AHit: TPasRefHit): Boolean;
var
  LFirstVis, LLastVis, LLineTo, LColTo: Integer;
  LFrom, LTo: TPasVisibleToken;
  LTS: TPasTokenStream;
begin
  Result := False;
  if (ANode = NIL_NODE) or (ANode > High(LM.Tree.Nodes)) then
    Exit;
  LFirstVis := LM.Tree.NodeLeftmostVis(ANode);
  LLastVis := LM.Tree.Nodes[ANode].LastToken;
  if (LFirstVis < 0) or (LLastVis < LFirstVis) or
     (LLastVis > High(LM.Tree.Source.Visible)) then
    Exit;
  LFrom := LM.Tree.Source.Visible[LFirstVis];
  LTo := LM.Tree.Source.Visible[LLastVis];
  if LFrom.FileId <> LTo.FileId then
    Exit;
  LTS := LM.Tree.Source.Files[LFrom.FileId];
  AHit.FilePath := LM.Tree.Source.FileNames[LFrom.FileId];
  LTS.OffsetToLineCol(LTS.Tokens[LFrom.TokenIndex].Start, AHit.Line, AHit.Col);
  LTS.OffsetToLineCol(LTS.Tokens[LTo.TokenIndex].EndPos, LLineTo, LColTo);
  if LLineTo <> AHit.Line then
    Exit;
  AHit.Snippet := LTS.LineText(AHit.Line);
  AHit.HiFrom := AHit.Col - 1;
  AHit.HiTo := LColTo - 1;
  Result := AHit.HiTo > AHit.HiFrom;
end;

{ Unit rename - the header plus every `uses` item that resolved here.

  Unlike PlanRename there is no symbol identity to search: each referring
  unit gets its OWN local skUnitRef symbol, so the shared identity is the
  TARGET MODEL, which is exactly what FindUnitReferences already keys on
  (its own comment says why). What this adds is the header itself, whole
  dotted spans instead of first segments, and the file-name obligation. }
function TPasNavigator.PlanUnitRename(ATargetMid: Integer;
  const ANewName: string; out AEdits: TArray<TPasRenameEdit>;
  out ARequiredFileName: string; out AError: string): Boolean;
var
  LM: TPasSemaModel;
  LList: TList<TPasRenameEdit>;
  LEdit: TPasRenameEdit;
  LHit: TPasRefHit;
  LMi, LIdx, LHeader: Integer;
  LOldFull, LOldLeaf, LNewLeaf, LWritten, LText: string;

  procedure AddHit(const AHitRec: TPasRefHit; const AText: string;
    AIsDecl: Boolean);
  begin
    LEdit.FilePath := AHitRec.FilePath;
    LEdit.Line := AHitRec.Line;
    LEdit.Col := AHitRec.Col;
    LEdit.Len := AHitRec.HiTo - AHitRec.HiFrom;
    LEdit.OldText := Copy(AHitRec.Snippet, AHitRec.HiFrom + 1, LEdit.Len);
    LEdit.IsDecl := AIsDecl;
    // The preview is built here rather than by the shared per-line pass
    // PlanRename uses: two `uses` items on one line can be replaced by
    // DIFFERENT texts (a full name here, a bare leaf there), which that
    // pass's single new-name assumption cannot express.
    LEdit.Snippet := Copy(AHitRec.Snippet, 1, AHitRec.HiFrom) + AText +
      Copy(AHitRec.Snippet, AHitRec.HiTo + 1, MaxInt);
    LEdit.HiFrom := AHitRec.HiFrom;
    LEdit.HiTo := AHitRec.HiFrom + Length(AText);
    LList.Add(LEdit);
  end;

begin
  Result := False;
  AEdits := nil;
  ARequiredFileName := '';
  AError := '';
  if (ATargetMid < 0) or (ATargetMid >= FProj.ModelCount) then
  begin
    AError := 'No unit to rename.';
    Exit;
  end;
  if not IsValidUnitRenameName(ANewName) then
  begin
    AError := Format('"%s" is not a valid unit name.', [ANewName]);
    Exit;
  end;
  LM := FProj.Model(ATargetMid);
  LHeader := LM.Tree.Nodes[0].FirstChild;
  if not UnitNameHit(LM, LHeader, {out} LHit) then
  begin
    AError := 'This unit has no readable name in its own header.';
    Exit;
  end;
  LOldFull := Copy(LHit.Snippet, LHit.HiFrom + 1, LHit.HiTo - LHit.HiFrom);
  if ANewName = LOldFull then
  begin
    AError := 'The new name is the same as the old one.';
    Exit;
  end;
  LOldLeaf := LOldFull;
  if LOldLeaf.Contains('.') then
    LOldLeaf := LOldLeaf.Substring(LOldLeaf.LastDelimiter('.') + 1);
  LNewLeaf := ANewName;
  if LNewLeaf.Contains('.') then
    LNewLeaf := LNewLeaf.Substring(LNewLeaf.LastDelimiter('.') + 1);

  LList := TList<TPasRenameEdit>.Create;
  try
    AddHit(LHit, ANewName, True);
    for LMi := 0 to FProj.ModelCount - 1 do
    begin
      LM := FProj.Model(LMi);
      for LIdx := 0 to High(LM.UsesList) do
      begin
        if LM.UsesList[LIdx].UnitId <> ATargetMid then
          Continue;
        if not UnitNameHit(LM, LM.UsesList[LIdx].NameNode, {out} LHit) then
        begin
          AError := Format('A `uses` reference in %s could not be read as ' +
            'one name - rename refused, nothing planned.',
            [TPath.GetFileName(FProj.ModelFile(LMi))]);
          Exit;
        end;
        LWritten := Copy(LHit.Snippet, LHit.HiFrom + 1,
          LHit.HiTo - LHit.HiFrom);
        // Written in full -> write the new full name. Written as the bare
        // leaf (a namespace prefix resolved it) -> keep it bare, which
        // stays correct only while the prefix itself is unchanged;
        // otherwise the full name is the safe spelling.
        if SameText(LWritten, LOldFull) then
          LText := ANewName
        else if SameText(LWritten, LOldLeaf) then
        begin
          if SameText(Copy(LOldFull, 1, Length(LOldFull) - Length(LOldLeaf)),
             Copy(ANewName, 1, Length(ANewName) - Length(LNewLeaf))) then
            LText := LNewLeaf
          else
            LText := ANewName;
        end
        else
        begin
          AError := Format('%s line %d spells this unit as "%s", which is ' +
            'neither its name nor its leaf (a unit alias?) - rename ' +
            'refused, nothing planned.',
            [TPath.GetFileName(LHit.FilePath), LHit.Line, LWritten]);
          Exit;
        end;
        AddHit(LHit, LText, False);
      end;
    end;
    AEdits := LList.ToArray;
  finally
    LList.Free;
  end;

  TArray.Sort<TPasRenameEdit>(AEdits, TComparer<TPasRenameEdit>.Construct(
    function(const A, B: TPasRenameEdit): Integer
    begin
      Result := CompareText(A.FilePath, B.FilePath);
      if Result = 0 then
        Result := A.Line - B.Line;
      if Result = 0 then
        Result := A.Col - B.Col;
    end));
  ARequiredFileName := ANewName + '.pas';
  Result := True;
end;

{ Decl + every use, turned into edits with a per-line preview. The preview is
  built per (file, line) GROUP rather than per edit, because two hits on one
  line each move the other: applying them left to right shifts every later
  HiFrom/HiTo by the accumulated length delta, and a preview that ignored
  that would highlight the wrong span on exactly the lines a rename is most
  likely to get wrong. }
function TPasNavigator.PlanRename(ATMid, ASym: Integer;
  const ANewName: string; out AEdits: TArray<TPasRenameEdit>;
  out AError: string): Boolean;
var
  LDecl: TPasRefHit;
  LList: TList<TPasRenameEdit>;
  LArr: TArray<TPasRenameEdit>;
  LIdx, LStart, LRun, LDelta, LNewLen, LPeer: Integer;
  LLine: string;

  // One CST node's own position, as an edit - for the peer routine header,
  // which is the same symbol and therefore not reachable through any
  // symbol-identity scan (see PeerRoutineNameNode).
  procedure AddNodeEdit(AList: TList<TPasRenameEdit>; ANode: Integer);
  var
    LHit: TPasRefHit;
    LEdit: TPasRenameEdit;
  begin
    if (ANode = NIL_NODE) or
       not HitFromNode(FProj.Model(ATMid), ANode, LHit) then
      Exit;
    LEdit.FilePath := LHit.FilePath;
    LEdit.Line := LHit.Line;
    LEdit.Col := LHit.Col;
    LEdit.Len := LHit.HiTo - LHit.HiFrom;
    LEdit.OldText := Copy(LHit.Snippet, LHit.HiFrom + 1, LEdit.Len);
    LEdit.IsDecl := False;
    LEdit.Snippet := LHit.Snippet;
    LEdit.HiFrom := LHit.HiFrom;
    LEdit.HiTo := LHit.HiTo;
    AList.Add(LEdit);
  end;

  // One symbol's own declaration + every use, as edits. AMarkDecl flags the
  // declaration row for a host to pin at the top of its results; only the
  // symbol the user actually clicked gets it, so a peer header's own
  // parameter declaration lists as an ordinary edit.
  procedure AddSymEdits(AList: TList<TPasRenameEdit>; AMid, ASymbol: Integer;
    AMarkDecl: Boolean);
  var
    LHits: TArray<TPasRefHit>;
    LHit: TPasRefHit;
    LEdit: TPasRenameEdit;
    LI: Integer;
  begin
    if DeclHit(AMid, ASymbol, {out} LHit) then
    begin
      LEdit.FilePath := LHit.FilePath;
      LEdit.Line := LHit.Line;
      LEdit.Col := LHit.Col;
      LEdit.Len := LHit.HiTo - LHit.HiFrom;
      LEdit.OldText := Copy(LHit.Snippet, LHit.HiFrom + 1, LEdit.Len);
      LEdit.IsDecl := AMarkDecl;
      LEdit.Snippet := LHit.Snippet;
      LEdit.HiFrom := LHit.HiFrom;
      LEdit.HiTo := LHit.HiTo;
      AList.Add(LEdit);
    end;
    LHits := FindReferences(AMid, ASymbol);
    for LI := 0 to High(LHits) do
    begin
      LEdit.FilePath := LHits[LI].FilePath;
      LEdit.Line := LHits[LI].Line;
      LEdit.Col := LHits[LI].Col;
      LEdit.Len := LHits[LI].HiTo - LHits[LI].HiFrom;
      LEdit.OldText := Copy(LHits[LI].Snippet, LHits[LI].HiFrom + 1,
        LEdit.Len);
      LEdit.IsDecl := False;
      LEdit.Snippet := LHits[LI].Snippet;
      LEdit.HiFrom := LHits[LI].HiFrom;
      LEdit.HiTo := LHits[LI].HiTo;
      AList.Add(LEdit);
    end;
  end;

begin
  Result := False;
  AEdits := nil;
  AError := '';
  if (ATMid < 0) or (ASym = NIL_SYM) then
  begin
    AError := 'No symbol to rename.';
    Exit;
  end;
  if not IsValidRenameName(ANewName) then
  begin
    AError := Format('"%s" is not a valid identifier.', [ANewName]);
    Exit;
  end;
  if ANewName = FProj.Model(ATMid).Symbols[ASym].Name then
  begin
    AError := 'The new name is the same as the old one.';
    Exit;
  end;
  // A compiler-seeded builtin is never renameable, even where one happens to
  // carry a declaration node: the name is the COMPILER's (`Integer`,
  // `Length`, `True`), the seeding is per model, and "every use" would mean
  // every unit in the language. SymbolAt already declines the seeds with no
  // real declaration (its own comment says why); this is the explicit rule
  // for the rest, so a host cannot reach one through any other path.
  if sfBuiltin in FProj.Model(ATMid).Symbols[ASym].Flags then
  begin
    AError := Format('"%s" is a compiler builtin - it cannot be renamed.',
      [FProj.Model(ATMid).Symbols[ASym].Name]);
    Exit;
  end;
  if not DeclHit(ATMid, ASym, {out} LDecl) then
  begin
    AError := 'This symbol has no declaration site to rename ' +
      '(an implicit Result, or a compiler builtin).';
    Exit;
  end;
  // The peer header's own parameter symbol, when there is one (see
  // PeerDeclSym): a language rule, not an extra search - the two headers
  // must keep spelling the parameter the same way.
  LPeer := PeerDeclSym(ATMid, ASym);

  LList := TList<TPasRenameEdit>.Create;
  try
    AddSymEdits(LList, ATMid, ASym, True);
    if (LPeer <> NIL_SYM) and (LPeer <> ASym) then
      AddSymEdits(LList, ATMid, LPeer, False);
    AddNodeEdit(LList, PeerRoutineNameNode(ATMid, ASym));
    LArr := LList.ToArray;
  finally
    LList.Free;
  end;

  TArray.Sort<TPasRenameEdit>(LArr, TComparer<TPasRenameEdit>.Construct(
    function(const A, B: TPasRenameEdit): Integer
    begin
      Result := CompareText(A.FilePath, B.FilePath);
      if Result = 0 then
        Result := A.Line - B.Line;
      if Result = 0 then
        Result := A.Col - B.Col;
    end));

  // The declaration site can also arrive as a hit through a map the decl
  // filter does not cover (IsDeclSelfName is structural, and guards only the
  // declaring model's own RefMap) - one POSITION must never be edited twice,
  // or the second edit would land inside the first one's new text.
  LIdx := 1;
  while LIdx <= High(LArr) do
    if (LArr[LIdx].Line = LArr[LIdx - 1].Line) and
       (LArr[LIdx].Col = LArr[LIdx - 1].Col) and
       SameText(LArr[LIdx].FilePath, LArr[LIdx - 1].FilePath) then
    begin
      LArr[LIdx - 1].IsDecl := LArr[LIdx - 1].IsDecl or LArr[LIdx].IsDecl;
      Delete(LArr, LIdx, 1);
    end
    else
      Inc(LIdx);

  LNewLen := Length(ANewName);
  LIdx := 0;
  while LIdx <= High(LArr) do
  begin
    LStart := LIdx;
    LLine := LArr[LStart].Snippet;
    LDelta := 0;
    while (LIdx <= High(LArr)) and (LArr[LIdx].Line = LArr[LStart].Line) and
          SameText(LArr[LIdx].FilePath, LArr[LStart].FilePath) do
    begin
      // 1-based Copy offsets, from the 0-based hit offsets.
      LLine := Copy(LLine, 1, LArr[LIdx].HiFrom + LDelta) + ANewName +
        Copy(LLine, LArr[LIdx].HiTo + LDelta + 1, MaxInt);
      LArr[LIdx].HiFrom := LArr[LIdx].HiFrom + LDelta;
      LArr[LIdx].HiTo := LArr[LIdx].HiFrom + LNewLen;
      Inc(LDelta, LNewLen - LArr[LIdx].Len);
      Inc(LIdx);
    end;
    for LRun := LStart to LIdx - 1 do
      LArr[LRun].Snippet := LLine;
  end;

  AEdits := LArr;
  Result := True;
end;

end.
