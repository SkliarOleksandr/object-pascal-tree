unit PasTree.Sema.Complete;

{
  PasTree editor features - code completion, stage A: the caret primitive.

  Everything the completion engine will do starts with one question the
  existing navigator deliberately refuses to answer: "where does this caret
  SIT, lexically and semantically, in a buffer that is mid-keystroke?"
  TPasNavigator.IdentAt requires an exact identifier hit (the right contract
  for ctrl+click, the wrong one for typing), and nothing anywhere maps a
  position to the innermost AST NODE - NodeOfVis covers nkIdent nodes only.

  This unit answers it. Given (line, col) over ONE analyzed model, CaretAt
  classifies the position (a prefix being typed / right after a dot / a fresh
  empty-prefix spot / no completion here) and anchors it to a raw token, a
  visible token, the innermost node whose span contains it, and the scope in
  effect there (NodeScope, parent-climbed). Later stages build the candidate
  collection on top; nothing here decides WHAT to offer.

  Contract, same as the navigator's: positions refer to the model's text AS
  ANALYZED. The completion pipeline satisfies it by parsing the CURRENT
  buffer into a fresh overlay model per request (the demo highlighter's
  proven per-keystroke path), so "as analyzed" and "as typed" are the same
  text; a caller that aims this at a stale project model gets stale answers,
  not errors. Main file only (FileId 0), like IdentAt - a caret inside an
  opened $I include is the same GAP navigation already has.

  Two parser facts this unit leans on (see PasTree.Parser):

  - `Foo.` always yields a LIVE nkMember node whose FirstToken is the DOT and
    whose first child is the base expression, even when the member name is
    missing - so the base of a dot-completion is FirstChild, never a text
    scan backward.
  - That same recovery will happily adopt an identifier from the NEXT LINE as
    the member name (`Foo.` + newline + `Bar := 1;` parses as `Foo.Bar`).
    Harmless here by construction: the base is still FirstChild, and a
    stolen name can never become the PREFIX because a prefix requires the
    caret to sit inside its own token.
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
  TPasCaretKind = (
    ckNone,      // no completion at this position: dead ($IFDEF'd-out) code,
                 // the interior of a comment/string/number literal/asm chunk,
                 // or nothing before the caret at all
    ckIdent,     // caret inside or at the right edge of an identifier or
                 // reserved word - a prefix being typed
    ckAfterDot,  // nearest visible token at/before the caret is a `.` and no
                 // prefix has been typed yet - member position, empty prefix
    ckFresh      // any other token precedes the caret - an empty-prefix
                 // position (statement start, after `:=`, after `uses`, ...)
  );

  TPasCaretInfo = record
    Kind: TPasCaretKind;
    { The lexical anchor: for ckIdent the prefix token itself; for ckAfterDot
      the dot; for ckFresh the nearest visible token at or before the caret.
      Raw index into Files[0]; -1 for ckNone. }
    RawToken: Integer;
    VisToken: Integer;   // the anchor's visible-stream index; -1 for ckNone
    Node: Integer;       // innermost node whose span contains VisToken
    Scope: Integer;      // scope in effect at Node; NIL_SCOPE for ckNone
    Routine: Integer;    // innermost enclosing nkRoutine node; NIL_NODE
    { The typed prefix: the anchor identifier's text UP TO the caret (so
      `Foo.Ba|zzz` filters on 'Ba'). '' unless ckIdent. }
    Prefix: string;
    { 1-based columns of the WHOLE anchor identifier on the caret's line -
      the range a host's completion replaces (mid-word invocation replaces
      the full word, the clangd behavior). For an empty prefix both equal
      the caret column. }
    PrefixColFrom: Integer;
    PrefixColTo: Integer;   // column AFTER the identifier's last character
    { The member-access BASE for a dot completion: the nkMember node's first
      child when the caret is after a dot (ckAfterDot), or when the ckIdent
      prefix's left visible neighbor is a dot (`Foo.Ba|`). NIL_NODE when the
      position is not a member access (including `end.` - the dot there
      belongs to no nkMember). }
    DotBase: Integer;
  end;

  { What kind of candidate list the position calls for. Decided from TOKENS
    and the (fresh) overlay AST around the caret, before any scope work. }
  TPasComplContext = (
    ccNone,        // no completion here
    ccMember,      // after a dot: members of the base designator's type
    ccUses,        // inside a uses clause: unit names
    ccType,        // a type is expected (after `:` in a decl, `= ` in a type
                   // decl, `class(`, `is`/`as`, `array of`, ...)
    ccStatement,   // statement/declaration head: names in scope + keywords
    ccExpression,  // inside an expression: names in scope + expr keywords
    ccRecField,    // a FIELD NAME in a record aggregate initializer (3.2.2):
                   // the record type's fields, nothing else
    ccInherited,   // right after `inherited `: the ancestor's members
    ccLabel,       // right after `goto `: the labels in scope
    // A property ACCESSOR position (13.1.1): after `read` / `write` in a
    // property declaration only a field or a method of this class (or an
    // ancestor) may stand - the collection is the struct chain alone, and
    // AddSym filters by SHAPE (fields always; functions for read,
    // procedures for write). Type compatibility is deliberately not
    // checked: a wrong-typed member is the compiler's E2258 to report,
    // and hiding near-misses helps nobody.
    ccPropRead,
    ccPropWrite);

  { Where a candidate came from - the ranking bucket (sortText prefix in the
    LSP mapping; display grouping in the demo). Declaration order IS priority
    order: dedup keeps the first hit, so the enum mirrors resolution
    precedence (with > locals/struct > unit > uses > System > builtins). }
  TPasComplBucket = (
    cbMember,       // member completion (after a dot)
    cbWithMember,   // member of an enclosing with target
    cbLocal,        // params/locals of the enclosing routine chain
    cbStructMember, // Self context: own + inherited struct members
    cbUnitSym,      // this unit's interface/implementation names
    cbUses,         // used units' interface names
    cbSystem,       // the implicit System/SysInit units
    cbBuiltin,      // compiler-seeded names
    cbKeyword,
    cbUnitName);    // uses-clause candidates

  { LIFETIME: Name/Kind/Bucket/Overloads are plain values, but Mid/Sym/Ctx
    (and everything derived from them - ItemHeadWord, a host's SymDeclTypeX
    detail) are only meaningful while BOTH the overlay model (Mid = -1) and
    the project GENERATION this request ran against are alive. A host doing
    deferred resolution (LSP completionItem/resolve) must materialize what it
    needs before the next analysis swap, not hold (Mid, Sym) across it. }
  TPasComplItem = record
    Name: string;              // original spelling
    Kind: TSemaSymbolKind;     // skKeyword when Bucket = cbKeyword
    Bucket: TPasComplBucket;
    Mid: Integer;              // declaring model id; -1 = the overlay model
    Sym: Integer;              // NIL_SYM for keywords/unit names
    Ctx: Integer;              // instantiation frame (project members)
    Overloads: Integer;        // same-name routines collapsed into this item
  end;

  { A type answer that may live in either space: the last-good PROJECT
    (X, a TSemaXType) or the OVERLAY being typed (OvSym, a type symbol of
    the fresh model) - or name a UNIT qualifier (UnitMid). IsTypeRef says
    the designator named the TYPE itself (class-side members) rather than
    a value of it. }
  TPasComplTypeRef = record
    X: TSemaXType;
    OvSym: Integer;
    UnitMid: Integer;
    IsTypeRef: Boolean;
    { A dotted-qualifier PREFIX that is not a unit YET: `Winapi` of
      `Winapi.CommonTypes.IBackgroundTaskInstance` names no unit and no
      symbol, but the next segment may complete a unit name - greedy
      longest-match, accumulated segment by segment (the same rule
      navigation's QualifierUnitAt applies). Not a "valid" ref by itself. }
    PendingUnit: string;
  end;

  { One resolved target of a located call (CallAt): a routine its designator
    may bind to - one entry PER OVERLOAD, unlike completion rows, which
    collapse the family (a host renders each as its own signature). The
    display fields are materialized eagerly; Mid/Sym/Ctx follow the same
    LIFETIME rule as TPasComplItem's. }
  TPasCallTarget = record
    Mid: Integer;         // declaring model id; -1 = the overlay model
    Sym: Integer;
    Ctx: Integer;         // instantiation frame (project members); NIL_INST
    Name: string;         // original spelling
    HeadWord: string;     // 'function'/'procedure'/'constructor'/... ; ''
    ParamsText: string;   // '(...)' display text; '' when parameterless
    HasParams: Boolean;   // same semantics as ItemHasParams
    ResultText: string;   // result type display text; '' for procedures
  end;

  { CallAt's answer: where the enclosing call opens, which argument the caret
    is in, and what the callee resolves to. Targets may be EMPTY with CallAt
    still True - a real call whose name nothing can resolve is an honest
    empty, the same contract as CompleteAt's empty list. }
  TPasCallInfo = record
    OpenLine: Integer;    // 1-based position of the call's '('
    OpenCol: Integer;
    ArgIndex: Integer;    // active argument: top-level commas before caret
    Targets: TArray<TPasCallTarget>;
  end;

  { Per-model caret queries and candidate collection. Build one per model
    SNAPSHOT - the constructor precomputes the raw->visible map (the same
    shape TPasNavigator caches per model); a host that keeps a model across
    requests keeps this with it, and the overlay pipeline creates both fresh
    per request.

    Two modes, one class: standalone (AProject = nil - the caret primitive
    and intra-model collection only) and BRIDGED (AProject + AProjectMid =
    the last-good analysis and this file's model id in it), where every name
    that leaves the overlay resolves through the project - see
    local/COMPLETION-PLAN.md sec. 3 and the stage-B spike. }
  TPasCompletion = class
  private
    FModel: TPasSemaModel;
    FProj: TPasSemaProject;        // may be nil (standalone)
    FProjMid: Integer;             // this file's model id in FProj; -1
    FVisOfRaw: TArray<Integer>;    // Files[0] raw idx -> visible idx | -1
    // collection state (valid during one CompleteAt)
    FItems: TArray<TPasComplItem>;
    FCount: Integer;
    FSeen: TDictionary<string, Integer>;   // NameLower -> item index
    FUnitMids: TDictionary<string, Integer>;  // lazy: unit basename -> mid
    FContext: TPasComplContext;
    FCaretVis: Integer;            // block-scope positional visibility
    FClassSide: Boolean;           // member completion on a TYPE reference
    FFieldsOnly: Boolean;          // ccRecField: aggregate wants skField only
    // True when FModel IS the project's own model of this file (the oracle /
    // any completion over unedited text): overlay symbol indices are then
    // project symbol indices, so overlay-space dead ends (a generic
    // parameter's constraints) can hop straight into project machinery.
    FIsProjectModel: Boolean;
    // The member walk's BASE type is declared in this unit - which is what
    // legalizes NON-STRICT protected members of its ancestors (11 sec. 11.2.1's
    // module rule, and the whole point of the same-unit protected-access
    // cast idiom: `TProtectedAccess = class(TComponent)` here makes
    // `TProtectedAccess(C).UpdateRegistry` compile).
    FBaseOwnUnit: Boolean;
    FAncestry: TArray<TPasExtRef>; // caret struct's bridged ancestor chain
    // The caret's enclosing struct NEST, innermost first: the method's own
    // class, then each class it is nested IN (overlay symbols). Same-class
    // strict-private access and a nested method's reach into the OUTER
    // class's inherited members both key off this.
    FCaretStructs: TArray<Integer>;
    // Overlay-space ancestors of the caret structs - see OverlayMemberVisible.
    FOverlayAncestry: TArray<Integer>;
    FAncestryBuilt: Boolean;
    // The last-good model's sckImplementation scope (lazy; -2 = not yet
    // looked up, NIL_SCOPE = the model has none) - OwnModelTypeX resolves
    // from it so implementation-section types bridge too.
    FOwnImplScope: Integer;
    function RawTokenAt(AOffset: Integer): Integer;
    function CaretOffset(ALine, ACol: Integer; out AOffset: Integer): Boolean;
    function PrevVisibleRaw(ARaw: Integer): Integer;
    function LeftmostVis(ANode: Integer): Integer;
    function InnermostNodeAt(AVis: Integer): Integer;
    function MemberBaseOfDot(ADotRaw: Integer): Integer;
    // typing (mixed overlay/project space)
    function ProjModel(AMid: Integer; const AWhere: string): TPasSemaModel;
    function BridgeName(const AKey: string; out AMid, ASym: Integer): Boolean;
    function BridgeUnitMid(const AName: string): Integer;
    function OwnModelTypeX(AOvSym: Integer): TSemaXType;
    function TypeOfOverlaySym(ASym, ADepth: Integer): TPasComplTypeRef;
    function TypeOfProjectSym(AMid, ASym, ACtx, ADepth: Integer):
      TPasComplTypeRef;
    function ResolveTypeRefNode(ANode, ADepth: Integer): TPasComplTypeRef;
    function DesignatorType(ANode, ADepth: Integer): TPasComplTypeRef;
    function MemberOf(const ABase: TPasComplTypeRef; const AKey: string;
      ADepth: Integer): TPasComplTypeRef;
    function MemberSymOf(const ABase: TPasComplTypeRef; const AKey: string;
      ADepth: Integer; out AMid, ASym, ACtx: Integer): Boolean;
    // accessors' shared core (AMid = -1 means the overlay model)
    function SymModelOf(AMid: Integer; const AWhere: string;
      out AModel: TPasSemaModel): Boolean;
    function SymHeadWord(AModel: TPasSemaModel; ASym: Integer): string;
    function SymParamsNode(AModel: TPasSemaModel; ASym: Integer): Integer;
    function SymParamsText(AMid, ASym: Integer): string;
    function SymHasParams(AMid, ASym: Integer): Boolean;
    function IsTypeSym(AMid, ASym: Integer): Boolean;
    procedure ExtendUsesPrefix(ALine: Integer; var AInfo: TPasCaretInfo);
    // CallAt internals
    function DesignatorNodeAtVis(AVis: Integer): Integer;
    function CalleeSyms(ANode, ACallNode: Integer;
      out AMid, ASym, ACtx: Integer): Boolean;
    procedure AddCallTargets(AMid, ASym, ACtx: Integer;
      var AInfo: TPasCallInfo);
    procedure AppendCallTarget(AMid, ASym, ACtx: Integer;
      var AInfo: TPasCallInfo);
    function IsDescendantNode(ANode, AAncestor: Integer): Boolean;
    function UpChainKind(ANode: Integer;
      const AKinds: array of TPasNodeKind): TPasNodeKind;
    function AggregateTypeOf(AAggNode, ADepth: Integer): TPasComplTypeRef;
    function OverlayStructDef(AOvSym: Integer): Integer;
    function OverlayHeritageRef(AOvSym, ADepth: Integer): TPasComplTypeRef;
    function ProjectTypeDef(const AX: TSemaXType): Integer;
    function ElementTypeOf(const ABase: TPasComplTypeRef;
      ADepth: Integer): TPasComplTypeRef;
    function PointeeTypeOf(const ABase: TPasComplTypeRef;
      ADepth: Integer): TPasComplTypeRef;
    // collection
    procedure AddItem(const AName, AKey: string; AKind: TSemaSymbolKind;
      ABucket: TPasComplBucket; AMid, ASym, ACtx: Integer);
    procedure AddSym(AMid, ASym, ACtx: Integer; ABucket: TPasComplBucket);
    procedure AddKeywords(const AWords: array of string);
    procedure EnsureAncestry(ACaretScope: Integer);
    function MemberVisible(AMid, ASym: Integer): Boolean;
    function OverlayMemberVisible(ASym: Integer): Boolean;
    function ClassSideMember(AModel: TPasSemaModel; ASym: Integer): Boolean;
    function RoutineNodeOf(AModel: TPasSemaModel; ASym: Integer): Integer;
    procedure CollectMembers(const ABase: TPasComplTypeRef);
    procedure CollectOverlayChain(AOvSym: Integer; AIncludeOwn: Boolean;
      ABucket: TPasComplBucket);
    procedure CollectProjectMembers(const AX: TSemaXType;
      ABucket: TPasComplBucket);
    procedure CollectScope(const AInfo: TPasCaretInfo);
    procedure CollectLabels(const AInfo: TPasCaretInfo);
    procedure CollectUsesImports(AInterfaceOnly: Boolean);
    procedure CollectUnitInterface(AUid: Integer; ABucket: TPasComplBucket);
    procedure CollectUnitNames;
    procedure AddContextKeywords(const AInfo: TPasCaretInfo);
  public
    constructor Create(AModel: TPasSemaModel;
      AProject: TPasSemaProject = nil; AProjectMid: Integer = -1);
    destructor Destroy; override;
    { Classifies the caret at 1-based (line, col) of the model's main file.
      False = ckNone (AInfo.Kind still says so); True fills every field. A
      column past the end of its line clamps to the line end - hosts report
      such carets (SynEdit's virtual space) and they mean "at the end". }
    function CaretAt(ALine, ACol: Integer; out AInfo: TPasCaretInfo): Boolean;
    { The completion context the caret position calls for - token-first, with
      the (fresh) AST consulted to split the ambiguous tokens (`:` in a decl
      vs a case label, `of` in `array of` vs `case of`, ...). }
    function ClassifyAt(const AInfo: TPasCaretInfo): TPasComplContext;
    { The whole pipeline: caret -> context -> candidate list, deduplicated
      by name (first hit wins - buckets are enumerated in resolution
      precedence) with overloads collapsed. False only when the position
      offers nothing (ckNone). An empty list with True is a real answer
      (e.g. a dot whose base cannot be typed). The first overload also hands
      back the caret classification - a host building textEdits needs the
      REPLACE SPAN (ACaret.PrefixColFrom/PrefixColTo) the engine already
      computed, and must not re-derive tokenization. }
    function CompleteAt(ALine, ACol: Integer; out ACaret: TPasCaretInfo;
      out AContext: TPasComplContext;
      out AItems: TArray<TPasComplItem>): Boolean; overload;
    function CompleteAt(ALine, ACol: Integer; out AContext: TPasComplContext;
      out AItems: TArray<TPasComplItem>): Boolean; overload;
    { The head keyword of a ROUTINE item ('procedure', 'function',
      'constructor', 'destructor', 'operator'), '' for anything else - what
      separates an LSP Constructor kind from a Function, and what a display
      column shows instead of the generic "routine". }
    function ItemHeadWord(const AItem: TPasComplItem): string;
    { The declaration's parameter list as display text - '(const AName:
      string; ACount: Integer)' - whitespace runs collapsed to one space
      (a multi-line list must read as one line; any length cap is the
      host's). '' for parameterless routines and non-routines. Builtins
      answer from the curated seed-table signatures (PasBuiltinSignature). }
    function ItemParamsText(const AItem: TPasComplItem): string;
    { Does calling this routine take at least one argument? SEMANTICS: an
      empty `()` declaration answers False - this drives a host's auto-
      parenthesis, and a parameterless routine must stay bare (which is why
      RoutineHasParams's "has an nkParams" definition is the wrong one
      here). Builtins answer the seed table's takes-arguments flag: names
      whose every argument is optional (Exit, Halt, Writeln) are False. }
    function ItemHasParams(const AItem: TPasComplItem): Boolean;
    { The `///` doc-comment block above the item's declaration (plan sec. 8D) -
      TPasTree.DeclDocComment over the item's Mid/Sym, for
      completionItem.documentation and the RAD client's Help Insight. '' for
      keywords, unit names, builtins (no source) and undocumented
      declarations. Raw text: XML-tag rendering is the host's. }
    function ItemDocComment(const AItem: TPasComplItem): string;
    { The call context for signature help: locates the innermost call whose
      ARGUMENT LIST encloses the caret (backward token walk - nesting over
      ()/[] respected, strings/comments are single tokens and cannot fool
      it; an enclosing indexer or grouping paren is stepped over to the
      call outside it, and a designator that names a TYPE is a cast, also
      stepped over), counts the active argument (top-level commas), and
      resolves the designator through the overlay+bridge - the same
      DesignatorType/MemberOf machinery member completion uses, so
      `Obj.Method(|` and freshly typed cross-unit calls both answer.
      False when the caret sits in no call's arguments (including a
      DECLARATION's parameter list). True with empty Targets is a real
      answer: a call whose name nothing resolves. }
    function CallAt(ALine, ACol: Integer; out AInfo: TPasCallInfo): Boolean;
    { The innermost struct type symbol whose member scope encloses AScope -
      the `Self` context: NodeScope's chain carries it both inside a struct
      DECLARATION (the sckStruct scope's own StructSym) and inside a method
      IMPLEMENTATION (stamped on the routine scope by the resolver).
      NIL_SYM outside any struct. }
    function EnclosingStructSym(AScope: Integer): Integer;
    property Model: TPasSemaModel read FModel;
  end;

implementation

uses
  System.SysUtils,
  PasTree.Sema.Builtins;

{ TPasCompletion }

constructor TPasCompletion.Create(AModel: TPasSemaModel;
  AProject: TPasSemaProject; AProjectMid: Integer);
var
  LIdx: Integer;
begin
  inherited Create;
  FModel := AModel;
  FProj := AProject;
  FProjMid := AProjectMid;
  FOwnImplScope := -2;
  FIsProjectModel := (FProj <> nil) and (FProjMid >= 0) and
    (FProjMid < FProj.ModelCount) and (FProj.Model(FProjMid) = FModel);
  // Pre-sized: a statement-context list runs to thousands of names, and
  // TDictionary.Clear throws its capacity away - CompleteAt recreates with
  // the same capacity per request instead (the review's finding #2).
  FSeen := TDictionary<string, Integer>.Create(4096);
  SetLength(FVisOfRaw, Length(FModel.Tree.Source.Files[0].Tokens));
  for LIdx := 0 to High(FVisOfRaw) do
    FVisOfRaw[LIdx] := -1;
  for LIdx := 0 to High(FModel.Tree.Source.Visible) do
    if FModel.Tree.Source.Visible[LIdx].FileId = 0 then
      FVisOfRaw[FModel.Tree.Source.Visible[LIdx].TokenIndex] := LIdx;
end;

destructor TPasCompletion.Destroy;
begin
  FUnitMids.Free;
  FSeen.Free;
  inherited;
end;

// The raw token of Files[0] covering AOffset (Start <= AOffset < EndPos), or
// -1. Tokens are gapless and sorted by Start - same search IdentAt/VisAt use.
function TPasCompletion.RawTokenAt(AOffset: Integer): Integer;
var
  LTS: TPasTokenStream;
  LLo, LHi, LMid: Integer;
begin
  Result := -1;
  LTS := FModel.Tree.Source.Files[0];
  LLo := 0;
  LHi := High(LTS.Tokens);
  while LLo <= LHi do
  begin
    LMid := (LLo + LHi) div 2;
    if LTS.Tokens[LMid].Start > AOffset then
      LHi := LMid - 1
    else if LTS.Tokens[LMid].EndPos <= AOffset then
      LLo := LMid + 1
    else
      Exit(LMid);
  end;
end;

// 1-based (line, col) -> character offset into Files[0], clamped to the line
// end the way every host position is read (SynEdit's virtual space means "at
// the end"). False when the line itself is out of range.
function TPasCompletion.CaretOffset(ALine, ACol: Integer;
  out AOffset: Integer): Boolean;
var
  LTS: TPasTokenStream;
  LLineEnd: Integer;
begin
  Result := False;
  AOffset := 0;
  LTS := FModel.Tree.Source.Files[0];
  if (ALine < 1) or (ALine - 1 > High(LTS.LineStarts)) or (ACol < 1) then
    Exit;
  AOffset := LTS.LineStarts[ALine - 1] + (ACol - 1);
  // Clamp a caret past the end of its line to the line end (before the line
  // break, when there is one - landing ON the break is fine too, the trivia
  // walk-back reads both the same way).
  // LineStarts[ALine] is the FIRST CHARACTER OF THE NEXT LINE, i.e. already
  // past the break - clamping there put the caret on the next line, so the
  // replace span landed at its column 1 and a line ending in an identifier
  // never classified as ckIdent. Walk back over the break instead.
  if ALine - 1 < High(LTS.LineStarts) then
  begin
    LLineEnd := LTS.LineStarts[ALine];
    while (LLineEnd > LTS.LineStarts[ALine - 1]) and
          CharInSet(LTS.Source[LLineEnd], [#10, #13]) do
      Dec(LLineEnd);
  end
  else
    LLineEnd := Length(LTS.Source);
  if AOffset > LLineEnd then
    AOffset := LLineEnd;
  Result := True;
end;

// Nearest raw token at or before ARaw that has a visible mapping (skips
// trivia backward - a caret in trailing whitespace still belongs to whatever
// came before it, the same reading VisAt established). -1 when nothing
// visible precedes.
function TPasCompletion.PrevVisibleRaw(ARaw: Integer): Integer;
begin
  Result := ARaw;
  if Result > High(FVisOfRaw) then
    Result := High(FVisOfRaw);
  while (Result >= 0) and (FVisOfRaw[Result] < 0) do
    Dec(Result);
end;

// A node's TRUE leftmost visible token. Nodes whose FirstToken is not their
// left edge exist by design (nkMember's FirstToken is the DOT; consumers
// everywhere walk to the leftmost descendant), so take the smaller of the
// node's own FirstToken and its deepest-first-child's.
function TPasCompletion.LeftmostVis(ANode: Integer): Integer;
var
  LNode, LTok: Integer;
begin
  Result := FModel.Tree.Nodes[ANode].FirstToken;
  LNode := FModel.Tree.Nodes[ANode].FirstChild;
  while LNode <> NIL_NODE do
  begin
    LTok := FModel.Tree.Nodes[LNode].FirstToken;
    if (LTok >= 0) and ((Result < 0) or (LTok < Result)) then
      Result := LTok;
    LNode := FModel.Tree.Nodes[LNode].FirstChild;
  end;
end;

// Innermost node whose [leftmost visible .. LastToken] span contains AVis: a
// descent from the root, taking the first child that covers the position at
// each level. The arena cannot be binary-searched for this (Adopt re-parents
// an already-built expression under a LATER-created operator node, so node
// index order is not source order) - but child spans are source-ordered
// within a parent, so the descent is linear in tree depth times fan-out.
function TPasCompletion.InnermostNodeAt(AVis: Integer): Integer;
var
  LChild, LFirst: Integer;
  LFound: Boolean;
begin
  Result := NIL_NODE;
  if (AVis < 0) or (Length(FModel.Tree.Nodes) = 0) then
    Exit;
  Result := 0;
  repeat
    LFound := False;
    LChild := FModel.Tree.Nodes[Result].FirstChild;
    while LChild <> NIL_NODE do
    begin
      // Pre-gate on the O(1) LastToken before paying for the leftmost
      // descent: siblings are source-ordered, so everything ending before
      // AVis is skipped with one field read, and the FIRST sibling ending at
      // or after it is the only containment candidate - if its left edge is
      // past AVis, the position sits between siblings and the walk stops.
      // (Scanning thousands of unit-level declarations with a LeftmostVis
      // each was the review's finding #3.)
      if FModel.Tree.Nodes[LChild].LastToken >= AVis then
      begin
        LFirst := LeftmostVis(LChild);
        if (LFirst >= 0) and (LFirst <= AVis) then
        begin
          Result := LChild;
          LFound := True;
        end;
        Break;
      end;
      LChild := FModel.Tree.Nodes[LChild].NextSibling;
    end;
  until not LFound;
end;

// The member-access base for the dot at raw index ADotRaw: the innermost node
// containing the dot is the nkMember that OWNS it (the dot is inside no
// child's span - the base ends before it, the name starts after it), and the
// base is that node's first child. NIL_NODE when the dot belongs to no member
// access (`end.`, a float's dot never gets here - `1.5` is one raw token).
function TPasCompletion.MemberBaseOfDot(ADotRaw: Integer): Integer;
var
  LVis, LNode: Integer;
begin
  Result := NIL_NODE;
  if (ADotRaw < 0) or (ADotRaw > High(FVisOfRaw)) then
    Exit;
  LVis := FVisOfRaw[ADotRaw];
  if LVis < 0 then
    Exit;
  LNode := InnermostNodeAt(LVis);
  if (LNode <> NIL_NODE) and (FModel.Tree.Nodes[LNode].Kind = nkMember) then
    Result := FModel.Tree.Nodes[LNode].FirstChild;
end;

function TPasCompletion.CaretAt(ALine, ACol: Integer;
  out AInfo: TPasCaretInfo): Boolean;
var
  LTS: TPasTokenStream;
  LOffset, LAnchorOff: Integer;
  LRaw, LPrevRaw: Integer;
  LKind: TPasTokenKind;
  LTok: TPasToken;
  LNode, LScope, LLine: Integer;
begin
  Result := False;
  AInfo := Default(TPasCaretInfo);
  AInfo.Kind := ckNone;
  AInfo.RawToken := -1;
  AInfo.VisToken := -1;
  AInfo.Node := NIL_NODE;
  AInfo.Scope := NIL_SCOPE;
  AInfo.Routine := NIL_NODE;
  AInfo.DotBase := NIL_NODE;

  LTS := FModel.Tree.Source.Files[0];
  if not CaretOffset(ALine, ACol, LOffset) then
    Exit;

  // Everything below reasons about the character position just LEFT of the
  // caret - that is where the text being completed attaches. A caret at the
  // very start of the file has nothing to attach to.
  if LOffset = 0 then
    Exit;
  LAnchorOff := LOffset - 1;

  // Dead code: a position inside a Skipped ($IFDEF'd-out) region has no
  // visible mapping at all, and walking backward from it would cross the
  // entire inactive region onto unrelated active code - refuse outright,
  // exactly as VisAt does for navigation.
  if FModel.Tree.Source.IsSkipped(0, LAnchorOff) then
    Exit;

  LRaw := RawTokenAt(LAnchorOff);
  if LRaw < 0 then
    Exit;
  LKind := LTS.Tokens[LRaw].Kind;

  // A prefix being typed: the caret sits inside (or at the right edge of) an
  // identifier or reserved word. Reserved words count - `begi|n` and a
  // half-typed `f|or` lex as what they are, and the host is filtering a
  // list that legitimately contains keywords.
  if (LKind = tkIdentifier) or (LKind >= tkAnd) then
  begin
    LTok := LTS.Tokens[LRaw];
    AInfo.Kind := ckIdent;
    AInfo.RawToken := LRaw;
    AInfo.VisToken := FVisOfRaw[LRaw];
    if AInfo.VisToken < 0 then
    begin
      // An active-region word with no visible mapping does not exist today
      // (trivia is never a word; dead regions were refused above) - treat a
      // future exception as "no completion" rather than guessing a scope.
      AInfo.Kind := ckNone;
      Exit;
    end;
    AInfo.Prefix := Copy(LTS.Source, LTok.Start + 1, LOffset - LTok.Start);
    LTS.OffsetToLineCol(LTok.Start, LLine, AInfo.PrefixColFrom);
    AInfo.PrefixColTo := AInfo.PrefixColFrom + LTok.Len;
    // `Foo.Ba|` - the prefix continues a member access when its left visible
    // neighbor is a dot.
    LPrevRaw := PrevVisibleRaw(LRaw - 1);
    if (LPrevRaw >= 0) and (LTS.Tokens[LPrevRaw].Kind = tkDot) then
      AInfo.DotBase := MemberBaseOfDot(LPrevRaw);
  end
  // Strictly INSIDE a literal, comment, directive or asm text: no completion
  // (matches the IDE). Whitespace interior falls through instead - that is
  // the ordinary "caret in trivia" case the walk-back below reads as "after
  // whatever came before". An unterminated string/comment extends to the
  // line end, so its right EDGE still counts as inside.
  else if ((LOffset < LTS.Tokens[LRaw].EndPos) or
           (tfUnterminated in LTS.Tokens[LRaw].Flags)) and
          (LKind in [tkCommentLine, tkCommentBrace, tkCommentParen,
            tkDirective, tkStringLiteral, tkMultilineString, tkControlChar,
            tkIntLiteral, tkRealLiteral, tkAsmChunk, tkUnknown]) then
    Exit;

  if AInfo.Kind = ckNone then
  begin
    // Empty prefix: anchor to the nearest visible token at or before the
    // caret and classify by what it is.
    LRaw := PrevVisibleRaw(LRaw);
    if LRaw < 0 then
      Exit;
    AInfo.RawToken := LRaw;
    AInfo.VisToken := FVisOfRaw[LRaw];
    if LTS.Tokens[LRaw].Kind = tkDot then
    begin
      AInfo.Kind := ckAfterDot;
      AInfo.DotBase := MemberBaseOfDot(LRaw);
    end
    else
      AInfo.Kind := ckFresh;
    LTS.OffsetToLineCol(LOffset, LLine, AInfo.PrefixColFrom);
    AInfo.PrefixColTo := AInfo.PrefixColFrom;
  end;

  // Semantic anchors: innermost node, scope in effect, enclosing routine.
  AInfo.Node := InnermostNodeAt(AInfo.VisToken);
  LNode := AInfo.Node;
  while LNode <> NIL_NODE do
  begin
    if LNode <= High(FModel.NodeScope) then
    begin
      LScope := FModel.NodeScope[LNode];
      if LScope <> NIL_SCOPE then
      begin
        AInfo.Scope := LScope;
        Break;
      end;
    end;
    LNode := FModel.Tree.Nodes[LNode].Parent;
  end;
  LNode := AInfo.Node;
  while (LNode <> NIL_NODE) and (FModel.Tree.Nodes[LNode].Kind <> nkRoutine) do
    LNode := FModel.Tree.Nodes[LNode].Parent;
  AInfo.Routine := LNode;

  Result := True;
end;

{ ---- mixed-space typing ---------------------------------------------------
  The overlay is fresh but alone; the project is complete but stale. A
  designator's type is derived by walking the overlay's own bindings (RefMap,
  member scopes) until a name leaves the buffer, then BRIDGING into the
  project - the resolution order mirrored is CrossResolve's (uses last-wins,
  then System/SysInit, then the compiler seeds). Everything project-side is
  a TSemaXType, so FindMemberX/EnumMembersX/SubstX apply unchanged. }

function ComplNilRef: TPasComplTypeRef;
begin
  Result.X := XNil;
  Result.OvSym := NIL_SYM;
  Result.UnitMid := -1;
  Result.IsTypeRef := False;
  Result.PendingUnit := '';
end;

function ComplValid(const ARef: TPasComplTypeRef): Boolean;
begin
  Result := XValid(ARef.X) or (ARef.OvSym <> NIL_SYM) or (ARef.UnitMid >= 0);
end;

// Every project-model access in this engine goes through here, so a wrong
// model id raises NAMING ITS SITE instead of a bare list-range error three
// frames deeper. Kept after the bug that motivated it was fixed: this engine
// hand-builds cross-space identities, a wrong one navigates somewhere
// plausible-but-wrong (the hardest bug class this project has), and two
// integer compares per call is not a hot-path cost.
function TPasCompletion.ProjModel(AMid: Integer;
  const AWhere: string): TPasSemaModel;
begin
  if (AMid < 0) or (AMid >= FProj.ModelCount) then
    raise Exception.CreateFmt('bad model id %d at %s', [AMid, AWhere]);
  Result := FProj.Model(AMid);
end;

// Resolve AKey as if written in this unit but NOT declared in it: the
// project-side half of unqualified resolution. Real declarations first
// (uses, last-wins, then the implicit System unit), then the compiler seeds
// of this file's own project model - the same effective order the analysis
// produces (a seed BINDS first intra-unit but is redirected to its real
// declaration; asking for the real one directly collapses the two steps).
function TPasCompletion.BridgeName(const AKey: string;
  out AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
begin
  Result := False;
  if (FProj = nil) or (FProjMid < 0) then
    Exit;
  if FProj.ResolveRealDecl(FProjMid, AKey, AMid, ASym) then
    Exit(True);
  LM := ProjModel(FProjMid, 'BridgeName');
  if LM.SystemScope <> NIL_SCOPE then
  begin
    ASym := LM.Resolve(LM.SystemScope, AKey);
    if ASym <> NIL_SYM then
    begin
      AMid := FProjMid;
      Exit(True);
    end;
  end;
end;

// Project model id of a unit named AName (as written in a uses clause or as
// a qualifier). Exact dotted-name match first, then the namespace-prefixed
// form (`Generics.Collections` -> System.Generics.Collections.pas) - good
// enough for names the project has ALREADY loaded, which is the only kind a
// bridge can answer anyway.
function TPasCompletion.BridgeUnitMid(const AName: string): Integer;
var
  LIdx: Integer;
  LPM: TPasSemaModel;
begin
  Result := -1;
  if (FProj = nil) or (AName = '') then
    Exit;
  if FProjMid >= 0 then
  begin
    // The unit's OWN name first - a unit may qualify its own exports
    // (`ctX = REST.Types.ctX` inside REST.Types itself)...
    if SameText(ChangeFileExt(ExtractFileName(FProj.ModelFile(FProjMid)), ''),
       AName) then
      Exit(FProjMid);
    // ...then the RESOLVED uses list of this file's project model: a unit is
    // qualified by the name it was IMPORTED under, and the resolution there
    // already applied unit ALIASES and namespace prefixes (`Classes.
    // MakeObjectInstance` means System.Classes through the default -A list -
    // a plain file-name scan cannot know that).
    LPM := ProjModel(FProjMid, 'BridgeUnitMid');
    for LIdx := 0 to High(LPM.UsesList) do
      if (LPM.UsesList[LIdx].UnitId >= 0) and
         SameText(LPM.UsesList[LIdx].NameFull, AName) then
        Exit(LPM.UsesList[LIdx].UnitId);
  end;
  // Exact full-dotted spellings last, via a lazily built basename index -
  // the linear scan allocated two strings per model per lookup, and a
  // dotted-qualifier chain does several lookups. No suffix guessing:
  // qualifying a unit requires having USED it, so the uses-list pass above
  // already covers every namespace-shortened or aliased form dcc accepts -
  // and a suffix guess false-matched `REST` (of a self-qualified REST.Types)
  // onto an unrelated `*.REST` unit on the reference project.
  if FUnitMids = nil then
  begin
    FUnitMids := TDictionary<string, Integer>.Create(FProj.ModelCount * 2);
    for LIdx := 0 to FProj.ModelCount - 1 do
      FUnitMids.AddOrSetValue(PasNameKey(
        ChangeFileExt(ExtractFileName(FProj.ModelFile(LIdx)), '')), LIdx);
  end;
  if not FUnitMids.TryGetValue(PasNameKey(AName), Result) then
    Result := -1;
end;

{ The last-good PROJECT identity of an OVERLAY-declared TYPE, by name: the
  overlay is an edit of FProjMid's file, so a type it declares usually still
  exists in the last-good model - which gives an instantiation frame a
  project-space argument where the overlay symbol alone has none
  (`TList<TMyOwnClass>` used to stay an OPEN generic; plan sec. 5.C). Resolved
  from the implementation scope so implementation-section types bridge too
  (its parent chain covers the interface). A freshly typed type that the
  last-good analysis never saw still answers XNil - the frame then stays
  open, exactly the old behavior. When this model IS the project's, the
  symbol needs no bridging at all. }
function TPasCompletion.OwnModelTypeX(AOvSym: Integer): TSemaXType;
var
  LM: TPasSemaModel;
  LScope, LSym: Integer;
begin
  Result := XNil;
  if (AOvSym = NIL_SYM) or (FProj = nil) or (FProjMid < 0) then
    Exit;
  if not (FModel.Symbols[AOvSym].Kind in [skType, skBuiltinType]) then
    Exit;
  if FIsProjectModel then
    Exit(XPlain(FProjMid, AOvSym));
  LM := ProjModel(FProjMid, 'OwnModelTypeX');
  if FOwnImplScope = -2 then
  begin
    FOwnImplScope := NIL_SCOPE;
    for LScope := 0 to LM.Scopes.Count - 1 do
      if LM.Scopes[LScope].Kind = sckImplementation then
      begin
        FOwnImplScope := LScope;
        Break;
      end;
    if (FOwnImplScope = NIL_SCOPE) and (LM.InterfaceScope <> NIL_SCOPE) then
      FOwnImplScope := LM.InterfaceScope;
  end;
  if FOwnImplScope = NIL_SCOPE then
    Exit;
  LSym := LM.Resolve(FOwnImplScope, FModel.Symbols[AOvSym].NameLower);
  if (LSym <> NIL_SYM) and
     (LM.Symbols[LSym].Kind in [skType, skBuiltinType]) then
    Result := XPlain(FProjMid, LSym);
end;

// The declared type of an OVERLAY value/type symbol, as a mixed-space ref.
function TPasCompletion.TypeOfOverlaySym(ASym, ADepth: Integer):
  TPasComplTypeRef;
var
  LMid, LSym, LIdx, LDecl, LInit: Integer;
begin
  Result := ComplNilRef;
  if (ASym = NIL_SYM) or (ADepth > 16) then
    Exit;
  case FModel.Symbols[ASym].Kind of
    skType:
      begin
        Result.OvSym := ASym;
        Result.IsTypeRef := True;
      end;
    skBuiltinType:
      if BridgeName(FModel.Symbols[ASym].NameLower, LMid, LSym) then
      begin
        Result.X := XPlain(LMid, LSym);
        Result.IsTypeRef := True;
      end;
    skUnitRef:
      for LIdx := 0 to High(FModel.UsesList) do
        if FModel.UsesList[LIdx].Sym = ASym then
        begin
          Result.UnitMid := BridgeUnitMid(FModel.UsesList[LIdx].NameFull);
          Break;
        end;
    skVar, skParam, skField, skConst, skProperty:
      begin
        // The analysis's own answer first when this model IS the project's:
        // SymDeclTypeX already handles the type-slot quirks a node walk
        // re-trips over (a member named like its own type, `TouchInput:
        // TouchInput` - its TypeSlotByNameX fallback exists for exactly
        // this).
        if FIsProjectModel then
        begin
          Result.X := FProj.SymDeclTypeX(FProjMid, ASym);
          if XValid(Result.X) then
            Exit;
        end;
        if FModel.Symbols[ASym].TypeNode <> NIL_NODE then
        begin
          Result := ResolveTypeRefNode(FModel.Symbols[ASym].TypeNode,
            ADepth + 1);
          Result.IsTypeRef := False;
        end
        else
        begin
          // `var X := expr` - an inline var with an inferred type: the
          // initializer is the last child of the nkInlineVar (3.1.3).
          LDecl := FModel.Symbols[ASym].DeclNode;
          if (LDecl <> NIL_NODE) and
             (FModel.Tree.Nodes[LDecl].Parent <> NIL_NODE) and
             (FModel.Tree.Nodes[FModel.Tree.Nodes[LDecl].Parent].Kind
               in [nkInlineVar, nkInlineConst]) then
          begin
            LInit := FModel.Tree.Nodes[
              FModel.Tree.Nodes[LDecl].Parent].FirstChild;
            while (LInit <> NIL_NODE) and
                  (FModel.Tree.Nodes[LInit].NextSibling <> NIL_NODE) do
              LInit := FModel.Tree.Nodes[LInit].NextSibling;
            if (LInit <> NIL_NODE) and (LInit <> LDecl) then
            begin
              Result := DesignatorType(LInit, ADepth + 1);
              Result.IsTypeRef := False;
            end;
          end;
        end;
      end;
    skRoutine:
      // Writing a parameterless function's name is a CALL; its type for a
      // trailing dot is the RESULT type (the routine symbol's TypeNode).
      if FModel.Symbols[ASym].TypeNode <> NIL_NODE then
      begin
        Result := ResolveTypeRefNode(FModel.Symbols[ASym].TypeNode,
          ADepth + 1);
        Result.IsTypeRef := False;
      end;
    skEnumValue:
      if FModel.Symbols[ASym].TypeSym <> NIL_SYM then
        Result.OvSym := FModel.Symbols[ASym].TypeSym;   // value, not type ref
    skGenericParam:
      // A value typed as an unbound parameter has its CONSTRAINTS' members
      // (16 sec. 16.4.1) - the walk lives in EnumMembersX/FindMemberX, which
      // need a project-space identity. Available only when this model IS
      // the project's (overlay generic bodies are a stage-E gap).
      if FIsProjectModel then
        Result.X := XPlain(FProjMid, ASym);
  end;
end;

// The same, for a PROJECT symbol found through the bridge or a member walk.
function TPasCompletion.TypeOfProjectSym(AMid, ASym, ACtx, ADepth: Integer):
  TPasComplTypeRef;
var
  LM: TPasSemaModel;
  LIdx: Integer;
begin
  Result := ComplNilRef;
  if (FProj = nil) or (AMid < 0) or (ASym = NIL_SYM) or (ADepth > 16) then
    Exit;
  LM := ProjModel(AMid, 'TypeOfProjectSym');
  case LM.Symbols[ASym].Kind of
    skType, skBuiltinType:
      begin
        Result.X := XPlain(AMid, ASym);
        if ACtx <> NIL_INST then
          Result.X := FProj.SubstX(Result.X, ACtx, 0);
        Result.IsTypeRef := True;
      end;
    skUnitRef:
      for LIdx := 0 to High(LM.UsesList) do
        if LM.UsesList[LIdx].Sym = ASym then
        begin
          Result.UnitMid := LM.UsesList[LIdx].UnitId;
          Break;
        end;
  else
    begin
      Result.X := FProj.SymDeclTypeX(AMid, ASym);
      if ACtx <> NIL_INST then
        Result.X := FProj.SubstX(Result.X, ACtx, 0);
      Result.IsTypeRef := False;
    end;
  end;
end;

// A TYPE EXPRESSION node of the overlay (a declared type, a heritage entry,
// a generic argument) resolved to a mixed-space TYPE reference.
function TPasCompletion.ResolveTypeRefNode(ANode, ADepth: Integer):
  TPasComplTypeRef;
var
  LSym, LMid, LChild: Integer;
  LKey: string;
  LBase, LArg: TPasComplTypeRef;
  LArgs: TArray<TSemaXType>;
  LAllProject: Boolean;
begin
  Result := ComplNilRef;
  if (ANode = NIL_NODE) or (ADepth > 16) then
    Exit;
  case FModel.Tree.Nodes[ANode].Kind of
    nkIdent:
      begin
        LSym := FModel.RefMap[ANode];
        // A TYPE SLOT that phase 1 bound to a NON-TYPE is the self-shadow
        // shape (`TouchInput: TouchInput` - the parameter shadows its own
        // type's name): only a type can stand here, so fall through to the
        // cross-unit lookup instead of chasing the value in a circle.
        if (LSym <> NIL_SYM) and
           (FModel.Symbols[LSym].Kind in [skType, skBuiltinType, skUnitRef,
             skGenericParam]) then
          Exit(TypeOfOverlaySym(LSym, ADepth + 1));
        LKey := FModel.Tree.NodeNameLower(ANode);
        if BridgeName(LKey, LMid, LSym) and
           (ProjModel(LMid, 'ResolveTypeRefIdent').Symbols[LSym].Kind in
             [skType, skBuiltinType])
        then
        begin
          Result.X := XPlain(LMid, LSym);
          Result.IsTypeRef := True;
        end;
      end;
    nkMember:
      begin
        // Qualified type name: Unit.Type or Outer.Nested.
        LBase := DesignatorType(FModel.Tree.Nodes[ANode].FirstChild,
          ADepth + 1);
        LChild := FModel.Tree.Nodes[ANode].FirstChild;
        if LChild <> NIL_NODE then
          LChild := FModel.Tree.Nodes[LChild].NextSibling;
        if LChild <> NIL_NODE then
          Result := MemberOf(LBase, FModel.Tree.NodeNameLower(LChild),
            ADepth + 1);
      end;
    nkTypeArgs:
      begin
        LChild := FModel.Tree.Nodes[ANode].FirstChild;
        LBase := ResolveTypeRefNode(LChild, ADepth + 1);
        if LBase.OvSym <> NIL_SYM then
          Exit(LBase);   // overlay generic: members enumerable, frame v2
        if not XValid(LBase.X) or (FProj = nil) then
          Exit;
        // Build the instantiation frame when EVERY argument lands in project
        // space. An OVERLAY-declared argument type is bridged by NAME into
        // this file's own last-good model first (OwnModelTypeX) - the
        // `TList<TMyOwnClass>` frame closes that way; only a type the
        // last-good analysis never saw falls back to the open generic
        // (members still complete, parameter types stay open).
        LArgs := nil;
        LAllProject := True;
        LChild := FModel.Tree.Nodes[LChild].NextSibling;
        while LChild <> NIL_NODE do
        begin
          LArg := ResolveTypeRefNode(LChild, ADepth + 1);
          if not XValid(LArg.X) then
            LArg.X := OwnModelTypeX(LArg.OvSym);
          if XValid(LArg.X) then
            LArgs := LArgs + [LArg.X]
          else
            LAllProject := False;
          LChild := FModel.Tree.Nodes[LChild].NextSibling;
        end;
        Result := LBase;
        if LAllProject and (Length(LArgs) > 0) then
          Result.X.Inst := FProj.Instantiate(LBase.X, LArgs);
      end;
    nkPointerType:
      begin
        // A value of an inline `^T` reaches T's members through the implicit
        // deref - resolve to the pointee directly (the same hop FindMemberX
        // makes for a NAMED pointer type).
        Result := ResolveTypeRefNode(FModel.Tree.Nodes[ANode].FirstChild,
          ADepth + 1);
        Result.IsTypeRef := False;
      end;
    nkClassOf:
      begin
        Result := ResolveTypeRefNode(FModel.Tree.Nodes[ANode].FirstChild,
          ADepth + 1);
        Result.IsTypeRef := True;   // a class-reference value is class-side
      end;
  end;
end;

// The type of an EXPRESSION (designator) node of the overlay - what a dot
// after it completes on.
function TPasCompletion.DesignatorType(ANode, ADepth: Integer):
  TPasComplTypeRef;
var
  LSym, LMid, LChild, LScope, LNode: Integer;
  LKey: string;
  LCallee: TPasComplTypeRef;
  LRes, LCached: TSemaXType;
  LExt: TPasExtRef;
begin
  Result := ComplNilRef;
  if (ANode = NIL_NODE) or (ADepth > 16) then
    Exit;
  // An ANALYZED model already typed its expressions (the cross passes fill
  // ExprTypeX, frames closed) - for VALUE-shaped nodes that answer beats any
  // re-derivation, and covers what the walk below does not (indexing and
  // derefs). Only value shapes: a bare type designator may also carry its
  // type here, and treating THAT as a value would offer instance members on
  // `TFoo.`. An overlay model has no cache and falls through everywhere.
  if FModel.Tree.Nodes[ANode].Kind in [nkCall, nkParen, nkIndex, nkDeref] then
    if FModel.ExprTypeX.TryGetValue(ANode, LCached) and XValid(LCached) then
    begin
      Result.X := LCached;
      Exit;
    end;
  case FModel.Tree.Nodes[ANode].Kind of
    nkParen:
      Result := DesignatorType(FModel.Tree.Nodes[ANode].FirstChild,
        ADepth + 1);
    nkIdent:
      begin
        LSym := FModel.RefMap[ANode];
        if LSym <> NIL_SYM then
          Exit(TypeOfOverlaySym(LSym, ADepth + 1));
        LKey := FModel.Tree.NodeNameLower(ANode);
        // `Self` has no symbol anywhere (11.3.3) - answered structurally,
        // the same way the analysis answers it (StructSymOfNode).
        if LKey = 'self' then
        begin
          LNode := ANode;
          LScope := NIL_SCOPE;
          while LNode <> NIL_NODE do
          begin
            if (LNode <= High(FModel.NodeScope)) and
               (FModel.NodeScope[LNode] <> NIL_SCOPE) then
            begin
              LScope := FModel.NodeScope[LNode];
              Break;
            end;
            LNode := FModel.Tree.Nodes[LNode].Parent;
          end;
          Result.OvSym := EnclosingStructSym(LScope);
          Exit;
        end;
        // The analysis's own CROSS-UNIT binding first (an analyzed model
        // only; overlays have an empty ExtRefMap): unlike a re-resolve by
        // name it knows the symbol, and for a VALUE the cached expression
        // type also carries the closed instantiation frame - `Statics` on a
        // WinRT import class is typed as the bound ARGUMENT, which nothing
        // downstream can recover from the symbol alone (the corpus oracle's
        // whole `Statics.*` bucket).
        if FModel.ExtRefMap.TryGetValue(ANode, LExt) then
        begin
          if FProj = nil then
            Exit;
          if ProjModel(LExt.UnitId, 'DesignatorExtRef').Symbols[LExt.Sym].Kind
             in [skType, skBuiltinType, skUnitRef] then
            Exit(TypeOfProjectSym(LExt.UnitId, LExt.Sym, NIL_INST,
              ADepth + 1));
          if FModel.ExprTypeX.TryGetValue(ANode, LCached) and
             XValid(LCached) then
          begin
            Result.X := LCached;
            Exit;
          end;
          Exit(TypeOfProjectSym(LExt.UnitId, LExt.Sym, NIL_INST, ADepth + 1));
        end;
        if BridgeName(LKey, LMid, LSym) then
          Exit(TypeOfProjectSym(LMid, LSym, NIL_INST, ADepth + 1));
        Result.UnitMid := BridgeUnitMid(FModel.Tree.NodeText(ANode));
        // No unit either - maybe the FIRST SEGMENT of a longer dotted unit
        // name (`Winapi` of Winapi.CommonTypes.X): keep it pending.
        if Result.UnitMid < 0 then
          Result.PendingUnit := FModel.Tree.NodeText(ANode);
      end;
    nkMember:
      begin
        LCallee := DesignatorType(FModel.Tree.Nodes[ANode].FirstChild,
          ADepth + 1);
        LChild := FModel.Tree.Nodes[ANode].FirstChild;
        if LChild <> NIL_NODE then
          LChild := FModel.Tree.Nodes[LChild].NextSibling;
        if LChild <> NIL_NODE then
          Result := MemberOf(LCallee, FModel.Tree.NodeNameLower(LChild),
            ADepth + 1);
      end;
    nkCall:
      begin
        LCallee := DesignatorType(FModel.Tree.Nodes[ANode].FirstChild,
          ADepth + 1);
        if not ComplValid(LCallee) then
          Exit;
        if LCallee.IsTypeRef then
        begin
          // A cast - T(expr) - or a value-typed use of a constructor's
          // class (T.Create is already an instance by MemberOf's ctor rule).
          Result := LCallee;
          Result.IsTypeRef := False;
          Exit;
        end;
        Result := LCallee;
        // A callee that is a VALUE of a procedural type: calling it takes
        // the result type (parameterless-func values were already unwrapped
        // at the symbol, so this only fires for real proc-type values).
        if XValid(Result.X) and (FProj <> nil) then
        begin
          LRes := FProj.ProcResultX(Result.X);
          if XValid(LRes) then
            Result.X := LRes;
        end;
      end;
    nkTypeArgs:
      Result := ResolveTypeRefNode(ANode, ADepth);
    nkDeref:
      begin
        Result := PointeeTypeOf(DesignatorType(
          FModel.Tree.Nodes[ANode].FirstChild, ADepth + 1), ADepth + 1);
        Result.IsTypeRef := False;   // a dereferenced value is an INSTANCE
      end;
    nkIndex:
      begin
        Result := ElementTypeOf(DesignatorType(
          FModel.Tree.Nodes[ANode].FirstChild, ADepth + 1), ADepth + 1);
        Result.IsTypeRef := False;   // an indexed value is an INSTANCE
      end;
  end;
end;

{ The member SYMBOL one dot-hop names - the SEARCH half of MemberOf, shared
  with CallAt (which reports the symbol as a signature-help target where
  MemberOf converts it to a TYPE for the next hop). Three spaces, in order:
  a unit qualifier's exports (Resolve, not FindLocal - the deep lookup also
  reaches the compiler seeds joined into the interface scope, which is what
  makes `System.Delete` mean the intrinsic; a unit's own USES items live
  there too but are not exports, so skUnitRef never chains), the overlay's
  member scopes walking overlay heritage (64 hops, not 16 - same-unit
  interface chains really run past 16, see EnsureAncestry), then the bridged
  project ancestry (FindMemberX). False when nothing is found - including
  the longer-dotted-unit-name and pending-qualifier shapes, which are
  MemberOf's own business. }
function TPasCompletion.MemberSymOf(const ABase: TPasComplTypeRef;
  const AKey: string; ADepth: Integer;
  out AMid, ASym, ACtx: Integer): Boolean;
var
  LM: TPasSemaModel;
  LSym, LScope, LHop: Integer;
  LCur, LHeritage: TPasComplTypeRef;
begin
  Result := False;
  AMid := -1;
  ASym := NIL_SYM;
  ACtx := NIL_INST;
  if (ADepth > 16) or (AKey = '') then
    Exit;
  if ABase.UnitMid >= 0 then
  begin
    if FProj = nil then
      Exit;
    LM := ProjModel(ABase.UnitMid, 'MemberSymOfUnit');
    if LM.InterfaceScope = NIL_SCOPE then
      Exit;
    LSym := LM.Resolve(LM.InterfaceScope, AKey);
    if (LSym <> NIL_SYM) and (LM.Symbols[LSym].Kind = skUnitRef) then
      LSym := NIL_SYM;
    if LSym = NIL_SYM then
      Exit;
    AMid := ABase.UnitMid;
    ASym := LSym;
    Exit(True);
  end;
  if ABase.PendingUnit <> '' then
    Exit;
  LCur := ABase;
  for LHop := 1 to 64 do
  begin
    if LCur.OvSym = NIL_SYM then
      Break;
    LScope := FModel.Symbols[LCur.OvSym].MemberScope;
    if LScope <> NIL_SCOPE then
    begin
      LSym := FModel.FindLocalDeep(LScope, AKey);
      if LSym <> NIL_SYM then
      begin
        ASym := LSym;   // AMid stays -1: an overlay symbol
        Exit(True);
      end;
    end;
    LHeritage := OverlayHeritageRef(LCur.OvSym, ADepth + 1);
    if LHeritage.OvSym <> NIL_SYM then
    begin
      LCur.OvSym := LHeritage.OvSym;
      Continue;
    end;
    LCur.OvSym := NIL_SYM;
    LCur.X := LHeritage.X;
    Break;
  end;
  if XValid(LCur.X) and (FProj <> nil) then
    Result := FProj.FindMemberX(FProjMid, LCur.X, AKey, AMid, ASym, ACtx);
end;

// One member hop by NAME, for typing intermediate designator segments
// (`A.B.` needs typeof(A.B), which needs member B of typeof(A)).
function TPasCompletion.MemberOf(const ABase: TPasComplTypeRef;
  const AKey: string; ADepth: Integer): TPasComplTypeRef;
var
  LMemMid, LMemSym, LCtx, LRoutine: Integer;
  LFull: string;
begin
  Result := ComplNilRef;
  if (ADepth > 16) or (AKey = '') then
    Exit;
  if MemberSymOf(ABase, AKey, ADepth, LMemMid, LMemSym, LCtx) then
  begin
    // A constructor names the CONSTRUCTED type: T.Create is a T value - and
    // the NAMED base, not the hop the walk had reached when the constructor
    // was found: `TFoo.Create` constructs TFoo even when Create itself is
    // inherited from another unit's TBar - returning the hop typed the
    // value as TBar and silently lost TFoo's own members (the review's
    // finding #1).
    if LMemMid < 0 then
    begin
      LRoutine := RoutineNodeOf(FModel, LMemSym);
      if (LRoutine <> NIL_NODE) and
         (FModel.Tree.Source.VisibleToken(
            FModel.Tree.Nodes[LRoutine].FirstToken).Kind = tkConstructor)
      then
      begin
        Result := ABase;
        Result.IsTypeRef := False;
        Exit;
      end;
      Exit(TypeOfOverlaySym(LMemSym, ADepth + 1));
    end;
    if (FProj <> nil) and FProj.IsConstructorSym(LMemMid, LMemSym) then
    begin
      Result := ABase;
      Result.IsTypeRef := False;
      Exit;
    end;
    Exit(TypeOfProjectSym(LMemMid, LMemSym, LCtx, ADepth + 1));
  end;
  // No member - the qualifier may be the PREFIX of a longer dotted UNIT
  // name (`System.AnsiStrings.FloatToText`: `System` resolved as a unit,
  // but the real qualifier is System.AnsiStrings). Greedy longest-match;
  // when even the longer name is no unit yet, it stays PENDING for the
  // next segment (`System.Win.ComObj` needs two hops).
  if ABase.UnitMid >= 0 then
  begin
    if FProj = nil then
      Exit;
    LFull := ChangeFileExt(ExtractFileName(FProj.ModelFile(ABase.UnitMid)),
      '') + '.' + AKey;
    Result.UnitMid := BridgeUnitMid(LFull);
    if Result.UnitMid < 0 then
      Result.PendingUnit := LFull;
  end
  else if ABase.PendingUnit <> '' then
  begin
    LFull := ABase.PendingUnit + '.' + AKey;
    Result.UnitMid := BridgeUnitMid(LFull);
    if Result.UnitMid < 0 then
      Result.PendingUnit := LFull;
  end;
end;

// The type-definition node of a PROJECT type symbol - OverlayStructDef's
// cross-model twin (same trailing-directive rule).
function TPasCompletion.ProjectTypeDef(const AX: TSemaXType): Integer;
var
  LM: TPasSemaModel;
  LDecl: Integer;
begin
  Result := NIL_NODE;
  if (FProj = nil) or not XValid(AX) then
    Exit;
  LM := ProjModel(AX.UnitId, 'ProjectTypeDef');
  LDecl := LM.Symbols[AX.Sym].DeclNode;
  if LDecl = NIL_NODE then
    Exit;
  LDecl := LM.Tree.Nodes[LDecl].Parent;
  if (LDecl = NIL_NODE) or (LM.Tree.Nodes[LDecl].Kind <> nkTypeDecl) then
    Exit;
  LDecl := LM.Tree.Nodes[LDecl].FirstChild;
  while LDecl <> NIL_NODE do
  begin
    if not (LM.Tree.Nodes[LDecl].Kind in [nkDirective, nkAttrGroup]) then
      Result := LDecl;
    LDecl := LM.Tree.Nodes[LDecl].NextSibling;
  end;
end;

// typeof(base[...]): an ARRAY type's element, a STRING's Char, a POINTER's
// pointee (pointer indexing) - enough for `A[I].` in a live overlay, where
// no ExprTypeX cache exists. Default array properties are a stage-E+ item.
function TPasCompletion.ElementTypeOf(const ABase: TPasComplTypeRef;
  ADepth: Integer): TPasComplTypeRef;
var
  LDef, LElem, LMid, LSym: Integer;
  LM: TPasSemaModel;
begin
  Result := ComplNilRef;
  if ADepth > 16 then
    Exit;
  if ABase.OvSym <> NIL_SYM then
  begin
    LDef := OverlayStructDef(ABase.OvSym);
    if (LDef <> NIL_NODE) and
       (FModel.Tree.Nodes[LDef].Kind = nkArrayType) then
    begin
      LElem := FModel.Tree.Nodes[LDef].FirstChild;
      while (LElem <> NIL_NODE) and
            (FModel.Tree.Nodes[LElem].NextSibling <> NIL_NODE) do
        LElem := FModel.Tree.Nodes[LElem].NextSibling;
      Exit(ResolveTypeRefNode(LElem, ADepth + 1));
    end;
    Exit;
  end;
  if (FProj = nil) or not XValid(ABase.X) then
    Exit;
  LM := ProjModel(ABase.X.UnitId, 'ElementTypeOf');
  // Indexing a STRING yields its Char (7.1) - the seeds have no def node.
  if (LM.Symbols[ABase.X.Sym].Kind = skBuiltinType) and
     (LM.Symbols[ABase.X.Sym].TypeCat = tcString) then
  begin
    if BridgeName('char', LMid, LSym) then
    begin
      Result.X := XPlain(LMid, LSym);
      Result.IsTypeRef := False;
    end;
    Exit;
  end;
  LDef := ProjectTypeDef(ABase.X);
  if LDef = NIL_NODE then
    Exit;
  case LM.Tree.Nodes[LDef].Kind of
    nkArrayType:
      begin
        LElem := LM.Tree.Nodes[LDef].FirstChild;
        while (LElem <> NIL_NODE) and
              (LM.Tree.Nodes[LElem].NextSibling <> NIL_NODE) do
          LElem := LM.Tree.Nodes[LElem].NextSibling;
        if LElem <> NIL_NODE then
        begin
          Result.X := FProj.ResolveTypeExpr(ABase.X.UnitId, LElem);
          if ABase.X.Inst <> NIL_INST then
            Result.X := FProj.SubstX(Result.X, ABase.X.Inst, 0);
        end;
      end;
    nkPointerType:
      Result.X := FProj.PointeeX(ABase.X);   // P[I] - pointer indexing
    nkStringType:
      if BridgeName('char', LMid, LSym) then
        Result.X := XPlain(LMid, LSym);
    nkIdent, nkMember, nkTypeArgs:
      begin
        // An alias - chase it and index THAT.
        Result.X := FProj.ResolveTypeExpr(ABase.X.UnitId, LDef);
        if ABase.X.Inst <> NIL_INST then
          Result.X := FProj.SubstX(Result.X, ABase.X.Inst, 0);
        if XValid(Result.X) and ((Result.X.UnitId <> ABase.X.UnitId) or
           (Result.X.Sym <> ABase.X.Sym)) then
          Exit(ElementTypeOf(Result, ADepth + 1));
        Result := ComplNilRef;
      end;
  end;
end;

// typeof(base^): the pointee - project pointers via PointeeX, overlay
// pointer types via their definition node.
function TPasCompletion.PointeeTypeOf(const ABase: TPasComplTypeRef;
  ADepth: Integer): TPasComplTypeRef;
var
  LDef: Integer;
begin
  Result := ComplNilRef;
  if ADepth > 16 then
    Exit;
  if ABase.OvSym <> NIL_SYM then
  begin
    LDef := OverlayStructDef(ABase.OvSym);
    if (LDef <> NIL_NODE) and
       (FModel.Tree.Nodes[LDef].Kind = nkPointerType) then
      Result := ResolveTypeRefNode(FModel.Tree.Nodes[LDef].FirstChild,
        ADepth + 1);
    Exit;
  end;
  if (FProj <> nil) and XValid(ABase.X) then
    Result.X := FProj.PointeeX(ABase.X);
end;

// The type-definition node of an overlay type symbol: the LAST child of its
// nkTypeDecl (name and generic params come first).
function TPasCompletion.OverlayStructDef(AOvSym: Integer): Integer;
var
  LDecl: Integer;
begin
  Result := NIL_NODE;
  LDecl := FModel.Symbols[AOvSym].DeclNode;
  if LDecl = NIL_NODE then
    Exit;
  LDecl := FModel.Tree.Nodes[LDecl].Parent;
  if (LDecl = NIL_NODE) or (FModel.Tree.Nodes[LDecl].Kind <> nkTypeDecl) then
    Exit;
  // The LAST child that is not a trailing hint directive: `TAlias =
  // Other.TType deprecated 'msg'` hangs the nkDirective after the type
  // expression, and taking the literal last child returned the directive.
  LDecl := FModel.Tree.Nodes[LDecl].FirstChild;
  while LDecl <> NIL_NODE do
  begin
    if not (FModel.Tree.Nodes[LDecl].Kind in [nkDirective, nkAttrGroup]) then
      Result := LDecl;
    LDecl := FModel.Tree.Nodes[LDecl].NextSibling;
  end;
end;

// Where an overlay type's member walk goes NEXT: the first heritage entry
// (which may itself be another overlay type, or bridge into the project),
// the implicit TObject/IInterface/IDispatch root for a heritage-less
// class/interface, or the target of a type alias. Invalid = walk ends.
function TPasCompletion.OverlayHeritageRef(AOvSym, ADepth: Integer):
  TPasComplTypeRef;
var
  LDef, LChild, LMid, LSym: Integer;
  LRootName: string;
begin
  Result := ComplNilRef;
  if ADepth > 16 then
    Exit;
  LDef := OverlayStructDef(AOvSym);
  if LDef = NIL_NODE then
    Exit;
  case FModel.Tree.Nodes[LDef].Kind of
    nkClassType, nkInterfaceType, nkRecordType, nkObjectType, nkHelperType:
      begin
        LChild := FModel.Tree.Nodes[LDef].FirstChild;
        while (LChild <> NIL_NODE) and not (FModel.Tree.Nodes[LChild].Kind in
          [nkIdent, nkMember, nkTypeArgs]) do
          LChild := FModel.Tree.Nodes[LChild].NextSibling;
        if LChild <> NIL_NODE then
        begin
          // A helper's LAST leading ref is its extended type; a struct's
          // FIRST is its ancestor. For a helper, walk to the last.
          if FModel.Tree.Nodes[LDef].Kind = nkHelperType then
            while (FModel.Tree.Nodes[LChild].NextSibling <> NIL_NODE) and
                  (FModel.Tree.Nodes[
                    FModel.Tree.Nodes[LChild].NextSibling].Kind in
                    [nkIdent, nkMember, nkTypeArgs]) do
              LChild := FModel.Tree.Nodes[LChild].NextSibling;
          Exit(ResolveTypeRefNode(LChild, ADepth + 1));
        end;
        LRootName := '';
        case FModel.Tree.Nodes[LDef].Kind of
          nkClassType:
            LRootName := 'tobject';
          nkInterfaceType:
            if FModel.Tree.Nodes[LDef].Aux = 1 then
              LRootName := 'idispatch'
            else
              LRootName := 'iinterface';
        end;
        if (LRootName <> '') and BridgeName(LRootName, LMid, LSym) then
        begin
          Result.X := XPlain(LMid, LSym);
          Result.IsTypeRef := True;
        end;
      end;
    nkIdent, nkMember, nkTypeArgs:
      Result := ResolveTypeRefNode(LDef, ADepth + 1);   // type alias
    nkPointerType, nkClassOf:
      // `PFoo = ^TFoo` / `TFooClass = class of TFoo`: member access walks
      // into the pointee / referenced class, the same implicit hop
      // FindMemberX makes for these kinds.
      Result := ResolveTypeRefNode(FModel.Tree.Nodes[LDef].FirstChild,
        ADepth + 1);
  end;
end;

{ ---- collection ----------------------------------------------------------- }

{ AKey is the caller's ALREADY-NORMALIZED dedup key (a symbol's NameLower, a
  keyword's own lowercase spelling). Not derived here from AName on purpose:
  this runs once per CANDIDATE, thousands of times per request, and PasNameKey
  allocates - the exact "cheap-looking normalization on a shared hot path"
  this codebase has paid for three times (see FindLocal's own comment). }
procedure TPasCompletion.AddItem(const AName, AKey: string;
  AKind: TSemaSymbolKind; ABucket: TPasComplBucket; AMid, ASym, ACtx: Integer);
var
  LIdx: Integer;
begin
  if AName = '' then
    Exit;
  if FSeen.TryGetValue(AKey, LIdx) then
  begin
    // First hit wins (buckets run in precedence order); a same-name routine
    // is an overload of the one already listed, not a new row.
    if (AKind = skRoutine) and (FItems[LIdx].Kind = skRoutine) and
       (FItems[LIdx].Bucket <> cbKeyword) then
      Inc(FItems[LIdx].Overloads);
    Exit;
  end;
  if FCount = Length(FItems) then
    if FCount = 0 then
      SetLength(FItems, 64)
    else
      SetLength(FItems, FCount * 2);
  FItems[FCount].Name := AName;
  FItems[FCount].Kind := AKind;
  FItems[FCount].Bucket := ABucket;
  FItems[FCount].Mid := AMid;
  FItems[FCount].Sym := ASym;
  FItems[FCount].Ctx := ACtx;
  FItems[FCount].Overloads := 0;
  FSeen.Add(AKey, FCount);
  Inc(FCount);
end;

procedure TPasCompletion.AddSym(AMid, ASym, ACtx: Integer;
  ABucket: TPasComplBucket);
var
  LM: TPasSemaModel;
begin
  if AMid < 0 then
    LM := FModel
  else
    LM := ProjModel(AMid, 'AddSym');
  // Labels complete after `goto` and NOWHERE else - and after `goto`,
  // nothing but a label means anything.
  if (LM.Symbols[ASym].Kind = skLabel) <> (FContext = ccLabel) then
    Exit;
  // Type positions take what can name a type - consts and enum values
  // included, because a SUBRANGE type's bounds are constant expressions
  // (`TVCLElements = teCategoryButtons..teTextLabel`, 2.2.5).
  if (FContext = ccType) and not (LM.Symbols[ASym].Kind in
    [skType, skBuiltinType, skUnitRef, skGenericParam, skConst,
     skEnumValue]) then
    Exit;
  // Property accessor positions take members of the right SHAPE only:
  // fields always, routines split by head - a function can stand after
  // `read`, a procedure after `write`, nothing else (13.1.1).
  if FContext in [ccPropRead, ccPropWrite] then
    case LM.Symbols[ASym].Kind of
      skField, skVar:
        ;
      skRoutine:
        if ((FContext = ccPropRead) and
            (SymHeadWord(LM, ASym) <> 'function')) or
           ((FContext = ccPropWrite) and
            (SymHeadWord(LM, ASym) <> 'procedure')) then
          Exit;
    else
      Exit;
    end;
  AddItem(LM.Symbols[ASym].Name, LM.Symbols[ASym].NameLower,
    LM.Symbols[ASym].Kind, ABucket, AMid, ASym, ACtx);
end;

procedure TPasCompletion.AddKeywords(const AWords: array of string);
var
  LIdx: Integer;
begin
  // The word lists are lowercase already - they are their own keys.
  for LIdx := 0 to High(AWords) do
    AddItem(AWords[LIdx], AWords[LIdx], skKeyword, cbKeyword, -1, NIL_SYM,
      NIL_INST);
end;

function TPasCompletion.RoutineNodeOf(AModel: TPasSemaModel;
  ASym: Integer): Integer;
begin
  Result := AModel.Symbols[ASym].DeclNode;
  while (Result <> NIL_NODE) and
        (AModel.Tree.Nodes[Result].Kind <> nkRoutine) do
    Result := AModel.Tree.Nodes[Result].Parent;
end;

// Can this member be named on the TYPE itself (TFoo.X)? Constructors, class
// methods (nkRoutine.Aux = 1), class properties (nkPropertyDecl.Aux = 1),
// class vars (their nkVarSec's Aux = 1), nested types, consts, enum values.
function TPasCompletion.ClassSideMember(AModel: TPasSemaModel;
  ASym: Integer): Boolean;
var
  LNode: Integer;
begin
  case AModel.Symbols[ASym].Kind of
    skType, skConst, skEnumValue:
      Result := True;
    skVar, skField:
      begin
        // The decl chain: name ident -> nkVarDecl -> nkVarSec (Aux = 1 for
        // a `class var` run - the parser eats both keywords and marks it).
        LNode := AModel.Symbols[ASym].DeclNode;
        while (LNode <> NIL_NODE) and
              (AModel.Tree.Nodes[LNode].Kind <> nkVarSec) and
              not (AModel.Tree.Nodes[LNode].Kind in [nkClassType,
                nkRecordType, nkInterfaceType, nkObjectType, nkHelperType]) do
          LNode := AModel.Tree.Nodes[LNode].Parent;
        Result := (LNode <> NIL_NODE) and
          (AModel.Tree.Nodes[LNode].Kind = nkVarSec) and
          (AModel.Tree.Nodes[LNode].Aux = 1);
      end;
    skRoutine:
      begin
        // RoutineHead, not a raw VisibleToken read: this runs during member
        // LIST BUILDING over foreign models, which may be text-demoted - the
        // head word is exactly what DemoteText snapshots per symbol.
        LNode := RoutineNodeOf(AModel, ASym);
        Result := (LNode <> NIL_NODE) and
          ((AModel.Tree.Nodes[LNode].Aux = 1) and
             (AModel.RoutineHead(ASym) <> rhDestructor) or
           (AModel.RoutineHead(ASym) = rhConstructor));
      end;
    skProperty:
      begin
        LNode := AModel.Symbols[ASym].DeclNode;
        if LNode <> NIL_NODE then
          LNode := AModel.Tree.Nodes[LNode].Parent;
        Result := (LNode <> NIL_NODE) and
          (AModel.Tree.Nodes[LNode].Kind = nkPropertyDecl) and
          (AModel.Tree.Nodes[LNode].Aux = 1);
      end;
  else
    Result := False;
  end;
end;

// The caret struct's bridged ancestor chain, for the protected-visibility
// test - built once per request, only when a member list needs it.
procedure TPasCompletion.EnsureAncestry(ACaretScope: Integer);
var
  LOv, LDepth: Integer;
  LRef: TPasComplTypeRef;
  LX: TSemaXType;
  LEntry: TPasExtRef;
begin
  if FAncestryBuilt then
    Exit;
  FAncestryBuilt := True;
  FAncestry := nil;
  FCaretStructs := nil;
  FOverlayAncestry := nil;
  LOv := EnclosingStructSym(ACaretScope);
  if LOv = NIL_SYM then
    Exit;
  // The struct NEST: the innermost class, then each class it is declared
  // inside (a nested class's DeclNode sits in the outer's member scope,
  // whose StructSym names the outer). Winapi-scale code nests freely.
  LDepth := 0;
  while (LOv <> NIL_SYM) and (LDepth < 8) do
  begin
    FCaretStructs := FCaretStructs + [LOv];
    Inc(LDepth);
    if FModel.Symbols[LOv].Scope = NIL_SCOPE then
      Break;
    LOv := FModel.Scopes[FModel.Symbols[LOv].Scope].StructSym;
    if (Length(FCaretStructs) > 0) and
       (LOv = FCaretStructs[High(FCaretStructs)]) then
      Break;
  end;
  if FProj = nil then
    Exit;
  // The bridged ancestry of EVERY nest level (a nested class's method also
  // reaches the OUTER class's inherited members - the corpus's
  // TWinGestureEngine.TRealTimeStylus method calling the engine's inherited
  // IsGesture bare).
  //
  // LX starts INVALID and stays so when a walk never leaves the overlay -
  // the corpus oracle caught exactly that as stack garbage flowing into
  // AncestorOfX when a same-unit interface chain ran past the old cap of 16
  // (Winapi.WebView2 chains ICoreWebView2_18 down to ICoreWebView2, all in
  // one unit). 64 covers any sane declaration chain; past it the bridged
  // half of the ancestry is simply absent, never garbage.
  for var LSIdx := 0 to High(FCaretStructs) do
  begin
    LOv := FCaretStructs[LSIdx];
    LX := XNil;
    for LDepth := 1 to 64 do
    begin
      LRef := OverlayHeritageRef(LOv, 0);
      if LRef.OvSym <> NIL_SYM then
      begin
        LOv := LRef.OvSym;
        // The OVERLAY half of the same chain, kept for the overlay-side
        // visibility rule (see OverlayMemberVisible): strict protected is
        // legal from a descendant, and in the buffer's own space FAncestry's
        // project ids cannot express that.
        FOverlayAncestry := FOverlayAncestry + [LOv];
        Continue;
      end;
      LX := LRef.X;
      Break;
    end;
    for LDepth := 1 to 32 do
    begin
      if not XValid(LX) then
        Break;
      LEntry.UnitId := LX.UnitId;
      LEntry.Sym := LX.Sym;
      FAncestry := FAncestry + [LEntry];
      LX := FProj.AncestorOfX(LX);
    end;
  end;
end;

// Visibility of a PROJECT member from this caret (11 sec. 11.2.1): private is
// same-unit-friendly, protected needs the caret's struct to descend from the
// declaring one (non-strict protected is also same-unit-friendly), strict
// variants drop the friend rule. svDefault means "no section stated" and
// stays visible - hiding on a guess is the wrong failure mode for a list.
function TPasCompletion.MemberVisible(AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
  LDeclStruct, LIdx: Integer;
begin
  LM := ProjModel(AMid, 'MemberVisible');
  case LM.Symbols[ASym].Visibility of
    svStrictPrivate:
      begin
        // Visible ONLY inside the declaring class itself (or a class the
        // caret's is nested in - the asymmetric nesting rule, 11 sec. 11.2.1).
        // Testable only when overlay indices ARE project indices.
        Result := False;
        if FIsProjectModel and (AMid = FProjMid) and
           (LM.Symbols[ASym].Scope <> NIL_SCOPE) then
        begin
          LDeclStruct := LM.Scopes[LM.Symbols[ASym].Scope].StructSym;
          for LIdx := 0 to High(FCaretStructs) do
            if FCaretStructs[LIdx] = LDeclStruct then
              Exit(True);
        end;
      end;
    svPrivate:
      Result := AMid = FProjMid;
    svProtected, svStrictProtected:
      begin
        Result := (LM.Symbols[ASym].Visibility = svProtected) and
          ((AMid = FProjMid) or FBaseOwnUnit);
        if Result then
          Exit;
        // dcc enforces a GENERIC class's plain `protected` only outside
        // method bodies (dcc32 37.0-probed; spec 11.2.1) - and completion
        // positions are method bodies in every case that matters, so a
        // generic's protected members stay visible. spring4d's collections
        // depend on the access being legal.
        if (LM.Symbols[ASym].Visibility = svProtected) and
           (LM.Symbols[ASym].Scope <> NIL_SCOPE) then
        begin
          LDeclStruct := LM.Scopes[LM.Symbols[ASym].Scope].StructSym;
          if (LDeclStruct <> NIL_SYM) and
             (sfGeneric in LM.Symbols[LDeclStruct].Flags) then
            Exit(True);
        end;
        if LM.Symbols[ASym].Scope = NIL_SCOPE then
          Exit(True);
        LDeclStruct := LM.Scopes[LM.Symbols[ASym].Scope].StructSym;
        if LDeclStruct = NIL_SYM then
          Exit(True);
        for LIdx := 0 to High(FAncestry) do
          if (FAncestry[LIdx].UnitId = AMid) and
             (FAncestry[LIdx].Sym = LDeclStruct) then
            Exit(True);
        // The declaring class IS one of the caret's own nest (same-class
        // strict-protected access) - overlay indices are project indices
        // only in project-model mode.
        if FIsProjectModel and (AMid = FProjMid) then
          for LIdx := 0 to High(FCaretStructs) do
            if FCaretStructs[LIdx] = LDeclStruct then
              Exit(True);
        Result := False;
      end;
  else
    Result := True;
  end;
end;

{ The visibility rule for an OVERLAY-declared member (11.2.1), the half
  MemberVisible cannot answer: overlay symbol indices are not project indices,
  so that function's model lookup does not apply here.

  Everything in the overlay is the edited unit's own, so `private` and plain
  `protected` are visible by the friend rule. The STRICT forms are not, and
  used to be offered anyway - a strict private member of a same-unit class was
  listed outside its declaring class, which is precisely what strict means. }
function TPasCompletion.OverlayMemberVisible(ASym: Integer): Boolean;
var
  LDeclStruct, LIdx: Integer;
begin
  if not (FModel.Symbols[ASym].Visibility in
     [svStrictPrivate, svStrictProtected]) then
    Exit(True);
  Result := False;
  if FModel.Symbols[ASym].Scope = NIL_SCOPE then
    Exit(True);   // not a struct member after all
  LDeclStruct := FModel.Scopes[FModel.Symbols[ASym].Scope].StructSym;
  if LDeclStruct = NIL_SYM then
    Exit(True);
  // The caret's own class, or one it is nested in.
  for LIdx := 0 to High(FCaretStructs) do
    if FCaretStructs[LIdx] = LDeclStruct then
      Exit(True);
  // strict protected additionally reaches DESCENDANTS - the caret's ancestry,
  // recorded in overlay space by EnsureAncestry.
  if FModel.Symbols[ASym].Visibility = svStrictProtected then
    for LIdx := 0 to High(FOverlayAncestry) do
      if FOverlayAncestry[LIdx] = LDeclStruct then
        Exit(True);
end;

procedure TPasCompletion.CollectProjectMembers(const AX: TSemaXType;
  ABucket: TPasComplBucket);
var
  LSaveOwn: Boolean;
begin
  if (FProj = nil) or not XValid(AX) then
    Exit;
  // The flag is PER BASE, not per request. Left set, the first own-unit base
  // walk legalized plain `protected` on every unrelated foreign base walked
  // after it in the same request.
  LSaveOwn := FBaseOwnUnit;
  try
    if AX.UnitId = FProjMid then
      FBaseOwnUnit := True;
    FProj.EnumMembersX(FProjMid, AX,
      procedure(AMid, ASym, ACtx: Integer)
      begin
        if FFieldsOnly and
           (ProjModel(AMid, 'FieldsOnly').Symbols[ASym].Kind <> skField) then
          Exit;
        if MemberVisible(AMid, ASym) and
           (not FClassSide or
            ClassSideMember(ProjModel(AMid, 'CollectProjMembers'), ASym)) then
          AddSym(AMid, ASym, ACtx, ABucket);
      end);
  finally
    FBaseOwnUnit := LSaveOwn;
  end;
end;

// Members of an OVERLAY-declared type: its own scope (deep - nested enums
// and intra-unit joins included), then each overlay ancestor's, then the
// first hop that leaves the buffer continues in project space.
// AIncludeOwn = False skips the FIRST scope - the caller already enumerated
// it through the caret's scope chain (a method body's joined member scope).
procedure TPasCompletion.CollectOverlayChain(AOvSym: Integer;
  AIncludeOwn: Boolean; ABucket: TPasComplBucket);
var
  LDepth, LScope: Integer;
  LRef: TPasComplTypeRef;
  LInclude, LSaveOwn: Boolean;
begin
  // An overlay-declared base IS a type of this unit - its bridged ancestors'
  // non-strict protected members are reachable (the module rule above).
  // Saved and restored, like CollectProjectMembers: the flag is per BASE.
  LSaveOwn := FBaseOwnUnit;
  try
  FBaseOwnUnit := True;
  LInclude := AIncludeOwn;
  for LDepth := 1 to 64 do
  begin
    if AOvSym = NIL_SYM then
      Exit;
    if LInclude then
    begin
      LScope := FModel.Symbols[AOvSym].MemberScope;
      if LScope <> NIL_SCOPE then
        FModel.EnumScopeDeep(LScope,
          procedure(ASym, AScopeOfSym: Integer)
          var
            LNode: Integer;
          begin
            // Class constructors/destructors are never nameable. Kind-gated
            // and token-KIND-tested - this closure is the per-candidate hot
            // path, and a parent walk per field/const was pure waste (the
            // review's finding #4; the token-kind policy is the one
            // IsConstructorSym documents for itself).
            if FModel.Symbols[ASym].Kind = skRoutine then
            begin
              LNode := RoutineNodeOf(FModel, ASym);
              if (LNode <> NIL_NODE) and
                 (FModel.Tree.Nodes[LNode].Aux = 1) and
                 (FModel.Tree.Source.VisibleToken(
                    FModel.Tree.Nodes[LNode].FirstToken).Kind in
                    [tkConstructor, tkDestructor]) then
                Exit;
            end;
            if FFieldsOnly and (FModel.Symbols[ASym].Kind <> skField) then
              Exit;
            if not OverlayMemberVisible(ASym) then
              Exit;
            if not FClassSide or ClassSideMember(FModel, ASym) then
              AddSym(-1, ASym, NIL_INST, ABucket);
          end);
    end;
    LInclude := True;
    LRef := OverlayHeritageRef(AOvSym, 0);
    if LRef.OvSym <> NIL_SYM then
    begin
      AOvSym := LRef.OvSym;
      Continue;
    end;
    CollectProjectMembers(LRef.X, ABucket);
    Exit;
  end;
  finally
    FBaseOwnUnit := LSaveOwn;
  end;
end;

procedure TPasCompletion.CollectUnitInterface(AUid: Integer;
  ABucket: TPasComplBucket);
var
  LM: TPasSemaModel;
  LScope, LIdx, LSym: Integer;
begin
  if (FProj = nil) or (AUid < 0) then
    Exit;
  LM := ProjModel(AUid, 'CollectUnitInterface');
  LScope := LM.InterfaceScope;
  if (LScope = NIL_SCOPE) or (LM.Scopes[LScope].Symbols = nil) then
    Exit;
  // OWN symbols, not a blind deep walk - the interface scope's Additional
  // joins hold that unit's builtin seeds (a per-model copy every unit has;
  // offering them as THIS unit's exports would be wrong), and its own uses'
  // unit refs are not importable names either, so skUnitRef is skipped.
  for LIdx := 0 to LM.Scopes[LScope].Symbols.Count - 1 do
  begin
    LSym := LM.Scopes[LScope].Symbols[LIdx];
    if LM.Symbols[LSym].Kind <> skUnitRef then
      AddSym(AUid, LSym, NIL_INST, ABucket);
  end;
  // The one Additional join that IS the unit's own export: an unscoped
  // enum's value scope ({$SCOPEDENUMS OFF}, the default) - `ffFixed` is
  // importable from System.SysUtils exactly like TFloatFormat itself. The
  // corpus oracle caught these missing from every used-unit list.
  for LIdx := 0 to High(LM.Scopes[LScope].Additional) do
    if LM.Scopes[LM.Scopes[LScope].Additional[LIdx]].Kind = sckEnum then
      LM.EnumScopeDeep(LM.Scopes[LScope].Additional[LIdx],
        procedure(ASym, AScopeOfSym: Integer)
        begin
          AddSym(AUid, ASym, NIL_INST, ABucket);
        end);
end;

procedure TPasCompletion.CollectMembers(const ABase: TPasComplTypeRef);
begin
  if ABase.UnitMid >= 0 then
  begin
    CollectUnitInterface(ABase.UnitMid, cbMember);
    // dcc lets `System.` qualify EVERY compiler-provided name (System.Delete,
    // System.PAnsiChar), so the System unit's list carries the seeds too -
    // and only System's: seeds are per-model copies, not anyone's exports.
    if (FProj <> nil) and (ABase.UnitMid = FProj.EnsureSystemUnit) and
       (FModel.SystemScope <> NIL_SCOPE) then
      FModel.EnumScopeDeep(FModel.SystemScope,
        procedure(ASym, AScopeOfSym: Integer)
        begin
          AddSym(-1, ASym, NIL_INST, cbBuiltin);
        end);
  end
  else if ABase.OvSym <> NIL_SYM then
    CollectOverlayChain(ABase.OvSym, True, cbMember)
  else
    CollectProjectMembers(ABase.X, cbMember);
end;

function TPasCompletion.IsDescendantNode(ANode, AAncestor: Integer): Boolean;
begin
  while ANode <> NIL_NODE do
  begin
    if ANode = AAncestor then
      Exit(True);
    ANode := FModel.Tree.Nodes[ANode].Parent;
  end;
  Result := False;
end;

// Used units' interface names + the implicit System/SysInit, through the
// PROJECT model of this same file - its UsesList already carries resolved
// model ids with namespaces and aliases applied (stage-B spike note). When
// the caret sits in the INTERFACE section, implementation-section uses are
// excluded (the overlay's own symbols say which section each item is in).
procedure TPasCompletion.CollectUsesImports(AInterfaceOnly: Boolean);
var
  PM: TPasSemaModel;
  LIdx, LUid, LJdx: Integer;
  LAllowed: TDictionary<string, Boolean>;
  LOk: Boolean;
begin
  if (FProj = nil) or (FProjMid < 0) then
    Exit;
  LAllowed := nil;
  try
    if AInterfaceOnly then
    begin
      LAllowed := TDictionary<string, Boolean>.Create;
      for LJdx := 0 to High(FModel.UsesList) do
        if (FModel.UsesList[LJdx].Sym <> NIL_SYM) and
           (FModel.Symbols[FModel.UsesList[LJdx].Sym].Scope =
             FModel.InterfaceScope) then
          LAllowed.AddOrSetValue(
            PasNameKey(FModel.UsesList[LJdx].NameFull), True);
    end;
    PM := ProjModel(FProjMid, 'CollectUsesImports');
    for LIdx := High(PM.UsesList) downto 0 do
    begin
      LUid := PM.UsesList[LIdx].UnitId;
      if LUid < 0 then
        Continue;
      if LAllowed <> nil then
      begin
        LOk := LAllowed.ContainsKey(PasNameKey(PM.UsesList[LIdx].NameFull));
        if not LOk then
          Continue;
      end;
      CollectUnitInterface(LUid, cbUses);
    end;
  finally
    LAllowed.Free;
  end;
  CollectUnitInterface(FProj.EnsureSystemUnit, cbSystem);
  CollectUnitInterface(FProj.EnsureSysInitUnit, cbSystem);
end;

procedure TPasCompletion.CollectScope(const AInfo: TPasCaretInfo);
var
  LScope, LIdx, LTarget, LBody: Integer;
  LTargets: TArray<Integer>;
  LInterfaceOnly: Boolean;
  LRef: TPasComplTypeRef;
begin
  FCaretVis := AInfo.VisToken;
  // 1. Enclosing UNOPENED with statements (cross-unit targets, ch.05 sec. 5.7):
  // their members shadow everything, so they go first. Opened (intra-unit)
  // withs are ordinary sckWith scopes and come through the chain below.
  //
  // INNERMOST FIRST, and within one statement LAST TARGET FIRST - that is the
  // shadowing order 5.7 gives, and AddItem keeps the FIRST hit for a name. In
  // source order the OUTER target's member identity survived where the inner
  // one must shadow it: the inserted text was the same, but the (Mid, Sym)
  // behind it - and so the detail, doc and kind shown - belonged to the wrong
  // member. WithUnopened is in source order, so a descending walk is
  // innermost-first for the nested case.
  for LIdx := High(FModel.WithUnopened) downto 0 do
  begin
    LBody := FModel.Tree.Nodes[FModel.WithUnopened[LIdx]].FirstChild;
    if LBody = NIL_NODE then
      Continue;
    while FModel.Tree.Nodes[LBody].NextSibling <> NIL_NODE do
      LBody := FModel.Tree.Nodes[LBody].NextSibling;
    if not IsDescendantNode(AInfo.Node, LBody) then
      Continue;
    // Targets of THIS statement, gathered so they can be walked backwards.
    LTargets := nil;
    LTarget := FModel.Tree.Nodes[FModel.WithUnopened[LIdx]].FirstChild;
    while (LTarget <> NIL_NODE) and (LTarget <> LBody) do
    begin
      LTargets := LTargets + [LTarget];
      LTarget := FModel.Tree.Nodes[LTarget].NextSibling;
    end;
    for var LTi := High(LTargets) downto 0 do
    begin
      LTarget := LTargets[LTi];
      // The with pass's own target typer first, when this model IS the
      // project's: it covers shapes the caches do not (an INDEXED target -
      // `with Palette.palPalEntry[I] do` - is typed by nothing else).
      LRef := ComplNilRef;
      if FIsProjectModel then
        LRef.X := FProj.WithTargetTypeX(FProjMid, LTarget);
      if not ComplValid(LRef) then
      begin
        LRef := DesignatorType(LTarget, 0);
        LRef.IsTypeRef := False;
      end;
      if ComplValid(LRef) then
      begin
        FClassSide := False;
        CollectMembers(LRef);
      end;
    end;
  end;
  FClassSide := False;
  // 2. The lexical scope chain, deep (joined scopes included) - this is
  // exactly what unqualified lookup sees intra-unit: locals, params, the
  // enclosing struct's own members through the method-body join, opened
  // withs, enum values, and the unit's own names. The builtin seeds joined
  // into the interface scope are skipped here and added LAST (a real name
  // must win the dedup against a seed).
  LScope := AInfo.Scope;
  LInterfaceOnly := True;
  while LScope <> NIL_SCOPE do
  begin
    if FModel.Scopes[LScope].Kind = sckImplementation then
      LInterfaceOnly := False;
    // An OPENED (intra-unit) with joins only the target's OWN member scope -
    // and that join is phase 1's GUESS, which the cross with pass revises in
    // the BINDINGS without touching the scope (the oracle's Orpheus
    // `with CT[J] do` was joined to the wrong struct entirely). So: walk the
    // joined structs' cross-unit ancestors (the TListActionLink/FClient
    // shape), and in project-model mode ALSO re-type the with's own targets
    // with the with pass's typer and inject those members - the authoritative
    // answer, deduped against whatever the join already provided.
    if FModel.Scopes[LScope].Kind = sckWith then
    begin
      for LIdx := 0 to High(FModel.Scopes[LScope].Additional) do
      begin
        LTarget := FModel.Scopes[
          FModel.Scopes[LScope].Additional[LIdx]].StructSym;
        if LTarget <> NIL_SYM then
          CollectOverlayChain(LTarget, False, cbWithMember);
      end;
      if FIsProjectModel then
      begin
        LTarget := FModel.Scopes[LScope].OwnerNode;
        if (LTarget <> NIL_NODE) and
           (FModel.Tree.Nodes[LTarget].Kind = nkWithStmt) and
           (FModel.Tree.Nodes[LTarget].FirstChild <> NIL_NODE) then
        begin
          LBody := FModel.Tree.Nodes[LTarget].FirstChild;
          while FModel.Tree.Nodes[LBody].NextSibling <> NIL_NODE do
            LBody := FModel.Tree.Nodes[LBody].NextSibling;
          LTarget := FModel.Tree.Nodes[LTarget].FirstChild;
          while (LTarget <> NIL_NODE) and (LTarget <> LBody) do
          begin
            CollectProjectMembers(
              FProj.WithTargetTypeX(FProjMid, LTarget), cbWithMember);
            LTarget := FModel.Tree.Nodes[LTarget].NextSibling;
          end;
        end;
      end;
    end;
    FModel.EnumScopeDeep(LScope,
      procedure(ASym, AScopeOfSym: Integer)
      var
        LBucket: TPasComplBucket;
      begin
        case FModel.Scopes[AScopeOfSym].Kind of
          sckSystem:
            Exit;   // seeds come last, as cbBuiltin
          sckStruct:
            LBucket := cbStructMember;
          sckWith:
            LBucket := cbWithMember;
          sckUnit, sckImplementation:
            LBucket := cbUnitSym;
        else
          LBucket := cbLocal;
        end;
        // Inline vars/consts are visible only BELOW their declaration
        // (3.1.3) - the same positional rule ResolveAt applies.
        if (FModel.Scopes[AScopeOfSym].Kind = sckBlock) and
           FModel.DeclaredAfter(ASym, FCaretVis) then
          Exit;
        AddSym(-1, ASym, NIL_INST, LBucket);
      end);
    LScope := FModel.Scopes[LScope].Parent;
  end;
  // 3. INHERITED members of the enclosing struct NEST - the chain join only
  // carries the structs' own scopes; ancestors (overlay-declared and then
  // cross-unit) are walked explicitly, for EVERY nesting level (a nested
  // class's method reaches the outer class's inherited members too). Skips
  // each first scope: step 2 had them.
  EnsureAncestry(AInfo.Scope);
  for LIdx := 0 to High(FCaretStructs) do
    CollectOverlayChain(FCaretStructs[LIdx], False, cbStructMember);
  // 4. Cross-unit names: uses (reverse, last-wins), System, SysInit.
  CollectUsesImports(LInterfaceOnly);
  // 5. Compiler seeds, last - every real declaration outranks a seed.
  if FModel.SystemScope <> NIL_SCOPE then
    FModel.EnumScopeDeep(FModel.SystemScope,
      procedure(ASym, AScopeOfSym: Integer)
      begin
        AddSym(-1, ASym, NIL_INST, cbBuiltin);
      end);
end;

// `goto |`: labels live in `label` sections of the lexical chain and nowhere
// else - running the full CollectScope pipeline (with typing, ancestry
// bridging, every used unit's interface) only for AddSym to reject all of it
// was measured waste (the review's finding #1).
procedure TPasCompletion.CollectLabels(const AInfo: TPasCaretInfo);
var
  LScope: Integer;
begin
  FCaretVis := AInfo.VisToken;
  LScope := AInfo.Scope;
  while LScope <> NIL_SCOPE do
  begin
    FModel.EnumScopeDeep(LScope,
      procedure(ASym, AScopeOfSym: Integer)
      begin
        AddSym(-1, ASym, NIL_INST, cbLocal);   // AddSym keeps only skLabel
      end);
    LScope := FModel.Scopes[LScope].Parent;
  end;
end;

{ ccUses: unit names are DOTTED, but the lexical anchor is one SEGMENT - a
  client filtering candidates ('System.SysUtils') against the bare segment
  prefix ('Sys' of `System.Sys|`) matches nothing, and its textEdit would
  replace half a name. So the prefix and replace-span are extended LEFT
  across the `ident . ident` chain (same line only - a replace span covers
  one line) before the caret leaves the engine: the prefix reads
  'System.Sys' and the span covers the whole dotted name typed so far.
  (Plan sec. 5.C's "dotted uses prefixes filter per segment", solved engine-side
  so every client gets it.) }
procedure TPasCompletion.ExtendUsesPrefix(ALine: Integer;
  var AInfo: TPasCaretInfo);
var
  LTS: TPasTokenStream;
  LCur, LPrev, LLine, LCol, LFrom: Integer;
  LHead: string;
begin
  LTS := FModel.Tree.Source.Files[0];
  if AInfo.RawToken < 0 then
    Exit;
  LCur := AInfo.RawToken;   // ckIdent: the segment; ckAfterDot: the dot
  if AInfo.Kind = ckIdent then
  begin
    LPrev := PrevVisibleRaw(LCur - 1);
    if (LPrev < 0) or (LTS.Tokens[LPrev].Kind <> tkDot) then
      Exit;
    LCur := LPrev;
  end
  else if (AInfo.Kind <> ckAfterDot) or
          (LTS.Tokens[LCur].Kind <> tkDot) then
    Exit;
  // Accumulate whole `ident .` pairs leftward; apply only what stayed
  // consistent (a chain continuing on an earlier line stops the walk with
  // the same-line part intact).
  LHead := '';
  LFrom := -1;
  while (LCur >= 0) and (LTS.Tokens[LCur].Kind = tkDot) do
  begin
    LPrev := PrevVisibleRaw(LCur - 1);
    if (LPrev < 0) or (LTS.Tokens[LPrev].Kind <> tkIdentifier) then
      Break;
    LTS.OffsetToLineCol(LTS.Tokens[LPrev].Start, LLine, LCol);
    if LLine <> ALine then
      Break;
    LHead := Copy(LTS.Source, LTS.Tokens[LPrev].Start + 1,
      LTS.Tokens[LPrev].Len) + '.' + LHead;
    LFrom := LCol;
    LCur := PrevVisibleRaw(LPrev - 1);
  end;
  if LFrom < 0 then
    Exit;
  AInfo.Prefix := LHead + AInfo.Prefix;
  AInfo.PrefixColFrom := LFrom;
end;

// Uses-clause candidates: the units the last-good project knows about, plus
// the units the search paths could REACH - a `uses` may legitimately name a
// unit nothing has analyzed yet (that is what typing a new uses item IS), so
// the project's cached search-path scan fills in the rest. Both name sets
// are full dotted names; loaded models win the dedup (they carry a real
// model id where a path-scanned name has none).
procedure TPasCompletion.CollectUnitNames;
var
  LIdx: Integer;
  LName: string;
begin
  if FProj = nil then
    Exit;
  for LIdx := 0 to FProj.ModelCount - 1 do
    if LIdx <> FProjMid then
    begin
      LName := ChangeFileExt(ExtractFileName(FProj.ModelFile(LIdx)), '');
      AddItem(LName, PasNameKey(LName), skUnitRef, cbUnitName, LIdx,
        NIL_SYM, NIL_INST);
    end;
  // Mid = -1 for a path-scanned name: there is no model to point at. A
  // cbUnitName item's identity is its NAME either way - nothing resolves
  // these rows further.
  for LName in FProj.SearchPathUnitNames do
    AddItem(LName, PasNameKey(LName), skUnitRef, cbUnitName, -1,
      NIL_SYM, NIL_INST);
end;

// The record type an aggregate initializer fills: the declared type of the
// typed const/var whose initializer this is, or - for a NESTED aggregate -
// the type of the field the enclosing aggregate assigns it to
// (`uguid: (guid: (D1: ...))`). Invalid for an ARRAY element aggregate
// (element types come off declaration nodes; a stage-E refinement).
function TPasCompletion.AggregateTypeOf(AAggNode, ADepth: Integer):
  TPasComplTypeRef;
var
  LParent, LChild, LName: Integer;
begin
  Result := ComplNilRef;
  if (AAggNode = NIL_NODE) or (ADepth > 16) then
    Exit;
  LParent := FModel.Tree.Nodes[AAggNode].Parent;
  if LParent = NIL_NODE then
    Exit;
  case FModel.Tree.Nodes[LParent].Kind of
    nkAggregateField:
      begin
        LName := FModel.Tree.Nodes[LParent].FirstChild;
        Result := MemberOf(
          AggregateTypeOf(FModel.Tree.Nodes[LParent].Parent, ADepth + 1),
          FModel.Tree.NodeNameLower(LName), ADepth + 1);
      end;
    nkConstDecl, nkVarDecl:
      begin
        // A typed const's shape is name, TYPE EXPR, initializer - the type
        // is the child between the name and this aggregate.
        LChild := FModel.Tree.Nodes[LParent].FirstChild;
        LChild := FModel.Tree.Nodes[LChild].NextSibling;   // past the name
        while (LChild <> NIL_NODE) and (LChild <> AAggNode) do
        begin
          Result := ResolveTypeRefNode(LChild, ADepth + 1);
          LChild := FModel.Tree.Nodes[LChild].NextSibling;
        end;
        Result.IsTypeRef := False;
      end;
  end;
end;

// The innermost node of the given kinds on ANode's parent chain, stopping at
// statement/section boundaries - the disambiguator for `:`/`=`/`of`/`(`.
function TPasCompletion.UpChainKind(ANode: Integer;
  const AKinds: array of TPasNodeKind): TPasNodeKind;
var
  LIdx: Integer;
  LKind: TPasNodeKind;
begin
  Result := nkError;
  while ANode <> NIL_NODE do
  begin
    LKind := FModel.Tree.Nodes[ANode].Kind;
    for LIdx := 0 to High(AKinds) do
      if LKind = AKinds[LIdx] then
        Exit(LKind);
    if LKind in [nkBlock, nkInterfaceSec, nkImplementationSec, nkUnit,
      nkProgram, nkLibrary, nkPackage] then
      Exit;
    ANode := FModel.Tree.Nodes[ANode].Parent;
  end;
end;

function TPasCompletion.ClassifyAt(const AInfo: TPasCaretInfo):
  TPasComplContext;
var
  LTS: TPasTokenStream;
  LPrev: Integer;
  LKind: TPasTokenKind;
begin
  if AInfo.Kind = ckNone then
    Exit(ccNone);
  LTS := FModel.Tree.Source.Files[0];
  // A uses clause first: any position inside one is a unit-name position -
  // but a caret whose anchor is a SEMICOLON sits after the clause's own
  // terminator (the `;` is the clause node's last token, so the node test
  // alone over-reaches by one token): that is the next declaration, not a
  // unit name.
  if LTS.Tokens[AInfo.RawToken].Kind <> tkSemicolon then
  begin
    if UpChainKind(AInfo.Node, [nkUsesClause, nkUsesItem]) <> nkError then
      Exit(ccUses);
    if LTS.Tokens[AInfo.RawToken].Kind = tkUses then
      Exit(ccUses);
  end;
  // The MODULE HEADER's own (possibly dotted) name is a naming position -
  // nothing to offer while the unit names itself. (AInfo.Node is never
  // NIL_NODE for a valid caret - the parser always allocates a root - but
  // the guard keeps this self-defending rather than resting on a parser
  // invariant stated two units away.)
  LPrev := AInfo.Node;
  while (LPrev <> NIL_NODE) and
        (FModel.Tree.Nodes[LPrev].Kind in [nkIdent, nkMember]) do
    LPrev := FModel.Tree.Nodes[LPrev].Parent;
  if (LPrev <> NIL_NODE) and (FModel.Tree.Nodes[LPrev].Kind in
    [nkUnit, nkProgram, nkLibrary, nkPackage]) then
    Exit(ccNone);
  if (AInfo.DotBase <> NIL_NODE) or (AInfo.Kind = ckAfterDot) then
    Exit(ccMember);
  // A property ACCESSOR position: the caret sits inside an nkPropSpec whose
  // specifier word is `read`/`write`. Checked before the generic token rules
  // below - the word left of the caret is an identifier-LEXED directive word
  // the token switch cannot tell from any other name. The other specifiers
  // (index, stored, default, implements) keep the ordinary expression
  // treatment: their right sides really are expressions.
  LPrev := AInfo.Node;
  while (LPrev <> NIL_NODE) and
        not (FModel.Tree.Nodes[LPrev].Kind in [nkPropSpec, nkPropertyDecl,
          nkBlock, nkInterfaceSec, nkImplementationSec, nkUnit]) do
    LPrev := FModel.Tree.Nodes[LPrev].Parent;
  if (LPrev <> NIL_NODE) and
     (FModel.Tree.Nodes[LPrev].Kind = nkPropSpec) then
  begin
    if FModel.Tree.Source.VisibleTextEquals(
         FModel.Tree.Nodes[LPrev].FirstToken, 'read') then
      Exit(ccPropRead);
    if FModel.Tree.Source.VisibleTextEquals(
         FModel.Tree.Nodes[LPrev].FirstToken, 'write') then
      Exit(ccPropWrite);
  end;
  // A record aggregate's FIELD NAME (3.2.2, `(flDensity: 1.0; flDe|`): the
  // typed prefix that IS an nkAggregateField's name child, or a fresh spot
  // right after the aggregate's `(`/`;`/`,`.
  if AInfo.Kind = ckIdent then
  begin
    LPrev := FModel.Tree.Nodes[AInfo.Node].Parent;
    if (LPrev <> NIL_NODE) and
       (FModel.Tree.Nodes[LPrev].Kind = nkAggregateField) and
       (FModel.Tree.Nodes[LPrev].FirstChild = AInfo.Node) then
      Exit(ccRecField);
  end
  else if (AInfo.Node <> NIL_NODE) and
     (FModel.Tree.Nodes[AInfo.Node].Kind = nkAggregate) and
     (LTS.Tokens[AInfo.RawToken].Kind in [tkLParen, tkSemicolon, tkComma])
  then
    Exit(ccRecField);
  // The significant token LEFT of the (possibly empty) prefix decides.
  if AInfo.Kind = ckIdent then
    LPrev := PrevVisibleRaw(AInfo.RawToken - 1)
  else
    LPrev := AInfo.RawToken;
  if LPrev < 0 then
    Exit(ccStatement);
  LKind := LTS.Tokens[LPrev].Kind;
  case LKind of
    tkInherited:
      // `inherited |` - the ancestor's members (12.1.2).
      Result := ccInherited;
    tkGoto:
      Result := ccLabel;
    tkColon:
      // `x: |` is a TYPE in a declaration, a STATEMENT after a case/goto
      // label, an EXPRESSION in an aggregate initializer's `field: value`
      // or a Write width spec - the INNERMOST enclosing construct decides.
      case UpChainKind(AInfo.Node, [nkCaseSel, nkCaseLabels, nkLabeledStmt,
        nkAggregateField, nkFormattedArg]) of
        nkCaseSel, nkCaseLabels, nkLabeledStmt:
          Result := ccStatement;
        nkAggregateField, nkFormattedArg:
          Result := ccExpression;
      else
        Result := ccType;
      end;
    tkEqual:
      // `TFoo = |` in a type decl is a type; `= |` anywhere else - a const
      // initializer, a parameter DEFAULT, an aggregate value, a comparison -
      // is an expression. The innermost construct decides again: a param
      // default sits lexically inside a type declaration, and the old
      // nkTypeDecl-anywhere test called `AEnabled: Boolean = |` a type
      // position (the oracle's 'False' [type] misses).
      case UpChainKind(AInfo.Node, [nkTypeDecl, nkConstDecl, nkVarDecl,
        nkInlineVar, nkInlineConst, nkParam, nkAggregateField, nkEnumValue,
        nkMethodResolution]) of
        nkTypeDecl:
          Result := ccType;
      else
        // nkEnumValue included above: `CURLINFO_X = CURLINFO_DOUBLE + 10` is
        // an ordinal EXPRESSION inside a type declaration. A METHOD
        // RESOLUTION's right side (14.2.2) names one of this class's own
        // methods - the scope chain has them, ccExpression lists them.
        Result := ccExpression;
      end;
    tkIs, tkAs:
      // Nominally a class type - but dcc accepts any class-REFERENCE
      // expression on the right (`if FModel is DefineModelClass then`, a
      // class FUNCTION - shipped in the FMX sources), so a hard types-only
      // filter hides legal names. ccExpression lists types too.
      Result := ccExpression;
    tkOf:
      // `array of |`/`set of |`/`class of |` want a type; `case x of |`
      // wants label EXPRESSIONS.
      if UpChainKind(AInfo.Node, [nkArrayType, nkSetType, nkFileType,
        nkClassOf, nkCaseStmt]) in [nkArrayType, nkSetType, nkFileType,
        nkClassOf] then
        Result := ccType
      else
        Result := ccExpression;
    tkLParen, tkComma:
      // A heritage list (`= class(|`, `class(A, |`) or a generic parameter
      // list is a type position; any other paren/comma is an argument.
      if UpChainKind(AInfo.Node, [nkClassType, nkInterfaceType,
        nkGenericParams, nkCall, nkParen, nkSetCtor]) in
        [nkClassType, nkInterfaceType, nkGenericParams] then
        Result := ccType
      else
        Result := ccExpression;
    tkLess:
      // `TList<|` - a generic argument/parameter list - but only when the
      // parse says so: a bare `x < |` is a COMPARISON (the oracle's
      // `Result := x < y` misses). A generic list mid-typing that has not
      // parsed as nkTypeArgs yet degrades to ccExpression, which still
      // lists every type - only the keyword set differs.
      if UpChainKind(AInfo.Node, [nkTypeArgs, nkGenericParams]) <> nkError then
        Result := ccType
      else
        Result := ccExpression;
    tkSemicolon, tkBegin, tkThen, tkElse, tkDo, tkRepeat, tkTry, tkFinally,
    tkExcept, tkEnd:
      Result := ccStatement;
  else
    // A reserved word (interface/implementation/var/type/...) opens a
    // declaration head; anything else - an operator, `:=`, a bracket, a
    // literal - sits inside an expression.
    if LKind >= tkAnd then
      Result := ccStatement
    else
      Result := ccExpression;
  end;
end;

procedure TPasCompletion.AddContextKeywords(const AInfo: TPasCaretInfo);
const
  STMT_WORDS: array[0..21] of string = ('begin', 'end', 'if', 'then', 'else',
    'case', 'while', 'do', 'repeat', 'until', 'for', 'to', 'downto', 'with',
    'try', 'finally', 'except', 'raise', 'goto', 'asm', 'inherited', 'var');
  UNIT_WORDS: array[0..14] of string = ('type', 'var', 'const', 'uses',
    'procedure', 'function', 'implementation', 'initialization',
    'finalization', 'end', 'begin', 'resourcestring', 'threadvar', 'label',
    'class');
  STRUCT_WORDS: array[0..15] of string = ('private', 'protected', 'public',
    'published', 'strict', 'procedure', 'function', 'constructor',
    'destructor', 'property', 'class', 'var', 'const', 'type', 'end', 'case');
  EXPR_WORDS: array[0..13] of string = ('nil', 'not', 'and', 'or', 'xor',
    'div', 'mod', 'shl', 'shr', 'is', 'as', 'in', 'inherited', 'function');
  TYPE_WORDS: array[0..11] of string = ('array', 'set', 'file', 'record',
    'class', 'interface', 'procedure', 'function', 'packed', 'string',
    'reference', 'of');
begin
  case FContext of
    ccExpression:
      AddKeywords(EXPR_WORDS);
    ccType:
      AddKeywords(TYPE_WORDS);
    ccStatement:
      if (AInfo.Scope <> NIL_SCOPE) then
        case FModel.Scopes[AInfo.Scope].Kind of
          sckUnit, sckImplementation:
            AddKeywords(UNIT_WORDS);
          sckStruct:
            AddKeywords(STRUCT_WORDS);
        else
          AddKeywords(STMT_WORDS);
        end
      else
        AddKeywords(STMT_WORDS);
  end;
end;

function TPasCompletion.CompleteAt(ALine, ACol: Integer;
  out AContext: TPasComplContext; out AItems: TArray<TPasComplItem>): Boolean;
var
  LCaret: TPasCaretInfo;
begin
  Result := CompleteAt(ALine, ACol, LCaret, AContext, AItems);
end;

// The model a (Mid, Sym) identity lives in: the overlay for -1, the project
// model otherwise. False only for a project id with no project attached.
function TPasCompletion.SymModelOf(AMid: Integer; const AWhere: string;
  out AModel: TPasSemaModel): Boolean;
begin
  if AMid < 0 then
  begin
    AModel := FModel;
    Exit(True);
  end;
  Result := FProj <> nil;
  if Result then
  begin
    AModel := ProjModel(AMid, AWhere);
    // The callers of this accessor are the item DETAIL readers (params text,
    // doc comment, signature help) - per selected item, not per candidate -
    // so rehydrating a text-demoted model here is cheap and gives them the
    // real text back. On failure they degrade through their bounds guards.
    if (AModel <> nil) and AModel.Demoted then
      FProj.EnsureHydrated(AMid);
  end
  else
    AModel := nil;
end;

function TPasCompletion.SymHeadWord(AModel: TPasSemaModel;
  ASym: Integer): string;
begin
  // Through the model's RoutineHead (this runs per display row): it answers
  // from the head token on a live model and from DemoteText's snapshot on a
  // text-demoted one - no raw token read either way.
  case AModel.RoutineHead(ASym) of
    rhProcedure:
      Result := 'procedure';
    rhFunction:
      Result := 'function';
    rhConstructor:
      Result := 'constructor';
    rhDestructor:
      Result := 'destructor';
    rhOperator:
      Result := 'operator';
  else
    Result := '';
  end;
end;

function TPasCompletion.ItemHeadWord(const AItem: TPasComplItem): string;
var
  LM: TPasSemaModel;
begin
  Result := '';
  if (AItem.Kind <> skRoutine) or (AItem.Sym = NIL_SYM) or
     (AItem.Bucket = cbKeyword) then
    Exit;
  if SymModelOf(AItem.Mid, 'ItemHeadWord', LM) then
    Result := SymHeadWord(LM, AItem.Sym);
end;

// The nkParams child of a routine symbol's declaration; NIL_NODE when the
// routine declares none (and for builtins, whose DeclNode is NIL_NODE).
function TPasCompletion.SymParamsNode(AModel: TPasSemaModel;
  ASym: Integer): Integer;
var
  LRoutine: Integer;
begin
  LRoutine := RoutineNodeOf(AModel, ASym);
  if LRoutine = NIL_NODE then
    Exit(NIL_NODE);
  Result := AModel.Tree.Nodes[LRoutine].FirstChild;
  while (Result <> NIL_NODE) and
        (AModel.Tree.Nodes[Result].Kind <> nkParams) do
    Result := AModel.Tree.Nodes[Result].NextSibling;
end;

// Whitespace runs collapsed to a single space - a multi-line parameter list
// must read as one display line. Interior comments survive as their own
// text; a declaration that comments its parameters is rare enough that
// stripping them is not worth a token-wise rebuild here.
function CollapseSpaces(const AText: string): string;
var
  LIdx, LOut: Integer;
  LCh: Char;
  LWasSpace: Boolean;
begin
  SetLength(Result, Length(AText));
  LOut := 0;
  LWasSpace := False;
  for LIdx := 1 to Length(AText) do
  begin
    LCh := AText[LIdx];
    if CharInSet(LCh, [#9, #10, #13, ' ']) then
      LWasSpace := True
    else
    begin
      if LWasSpace and (LOut > 0) then
      begin
        Inc(LOut);
        Result[LOut] := ' ';
      end;
      LWasSpace := False;
      Inc(LOut);
      Result[LOut] := LCh;
    end;
  end;
  SetLength(Result, LOut);
end;

function TPasCompletion.SymParamsText(AMid, ASym: Integer): string;
var
  LM: TPasSemaModel;
  LSig: TPasBuiltinSig;
  LParams, LChild: Integer;
begin
  Result := '';
  if (ASym = NIL_SYM) or not SymModelOf(AMid, 'SymParamsText', LM) then
    Exit;
  if sfBuiltin in LM.Symbols[ASym].Flags then
  begin
    if PasBuiltinSignature(LM.Symbols[ASym].NameLower, LSig) then
      Result := LSig.Params;
    Exit;
  end;
  // An empty `()` renders as '' - "parameterless" is about the PARAMETERS,
  // not the punctuation, and both spellings must display the same way.
  LParams := SymParamsNode(LM, ASym);
  if LParams = NIL_NODE then
    Exit;
  LChild := LM.Tree.Nodes[LParams].FirstChild;
  while (LChild <> NIL_NODE) and
        (LM.Tree.Nodes[LChild].Kind <> nkParam) do
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  if LChild <> NIL_NODE then
    Result := CollapseSpaces(LM.Tree.NodeSpanText(LParams));
end;

function TPasCompletion.SymHasParams(AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
  LSig: TPasBuiltinSig;
  LChild: Integer;
begin
  Result := False;
  if (ASym = NIL_SYM) or not SymModelOf(AMid, 'SymHasParams', LM) then
    Exit;
  if sfBuiltin in LM.Symbols[ASym].Flags then
  begin
    if PasBuiltinSignature(LM.Symbols[ASym].NameLower, LSig) then
      Result := LSig.HasArgs;
    Exit;
  end;
  // An nkParams with no nkParam child is an empty `()` - False by contract.
  LChild := SymParamsNode(LM, ASym);
  if LChild <> NIL_NODE then
    LChild := LM.Tree.Nodes[LChild].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LChild].Kind = nkParam then
      Exit(True);
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
end;

function TPasCompletion.ItemParamsText(const AItem: TPasComplItem): string;
begin
  Result := '';
  if (AItem.Kind = skRoutine) and (AItem.Sym <> NIL_SYM) and
     (AItem.Bucket <> cbKeyword) then
    Result := SymParamsText(AItem.Mid, AItem.Sym);
end;

function TPasCompletion.ItemHasParams(const AItem: TPasComplItem): Boolean;
begin
  Result := (AItem.Kind = skRoutine) and (AItem.Sym <> NIL_SYM) and
    (AItem.Bucket <> cbKeyword) and SymHasParams(AItem.Mid, AItem.Sym);
end;

function TPasCompletion.ItemDocComment(const AItem: TPasComplItem): string;
var
  LM: TPasSemaModel;
begin
  Result := '';
  if (AItem.Sym = NIL_SYM) or (AItem.Bucket in [cbKeyword, cbUnitName]) or
     not SymModelOf(AItem.Mid, 'ItemDocComment', LM) then
    Exit;
  Result := LM.Tree.DeclDocComment(LM.Symbols[AItem.Sym].DeclNode);
end;

{ ---- signature help (CallAt) ---------------------------------------------- }

function TPasCompletion.IsTypeSym(AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
begin
  Result := (ASym <> NIL_SYM) and SymModelOf(AMid, 'IsTypeSym', LM) and
    (LM.Symbols[ASym].Kind in [skType, skBuiltinType]);
end;

// The largest designator-shaped node ending exactly at AVis - the callee of
// a call whose nkCall node a broken parse did not produce. Climbs from the
// innermost node while the parent is still designator-shaped AND still ends
// at AVis (an nkCall parent ends past the '(', so the climb stops below it).
function TPasCompletion.DesignatorNodeAtVis(AVis: Integer): Integer;
var
  LParent: Integer;
begin
  Result := NIL_NODE;
  if AVis < 0 then
    Exit;
  Result := InnermostNodeAt(AVis);
  while Result <> NIL_NODE do
  begin
    LParent := FModel.Tree.Nodes[Result].Parent;
    if (LParent = NIL_NODE) or
       not (FModel.Tree.Nodes[LParent].Kind in
         [nkIdent, nkMember, nkParen, nkTypeArgs, nkIndex, nkDeref]) or
       (FModel.Tree.Nodes[LParent].LastToken > AVis) then
      Break;
    Result := LParent;
  end;
end;

{ The (Mid, Sym, Ctx) the call designator binds to - the analysis's own
  arbitration first (CallTargetX/CallTarget on the nkCall node, filled on
  analyzed models and for the overlay's intra-buffer calls), then the
  structural walk the member-completion path uses: RefMap/ExtRefMap on a
  plain name, BridgeName for one that leaves the buffer, DesignatorType +
  MemberSymOf for a dotted one - which is exactly the bridged-designator
  resolution the LSP's interim locator cannot do (`Obj.Method(|`, freshly
  typed cross-unit calls). ACallNode is the nkCall when the AST produced
  one; NIL_NODE from the broken-parse fallback. }
function TPasCompletion.CalleeSyms(ANode, ACallNode: Integer;
  out AMid, ASym, ACtx: Integer): Boolean;
var
  LKey: string;
  LExt: TPasExtRef;
  LBase: TPasComplTypeRef;
  LName, LPeel: Integer;
begin
  Result := False;
  AMid := -1;
  ASym := NIL_SYM;
  ACtx := NIL_INST;
  if ACallNode <> NIL_NODE then
  begin
    if (FProj <> nil) and
       FModel.CallTargetX.TryGetValue(ACallNode, LExt) then
    begin
      AMid := LExt.UnitId;
      ASym := LExt.Sym;
      Exit(True);
    end;
    if FModel.CallTarget.TryGetValue(ACallNode, ASym) and
       (ASym <> NIL_SYM) then
      Exit(True);
    ASym := NIL_SYM;
  end;
  // Peel grouping parens and a generic-arguments wrapper down to the name.
  LPeel := 0;
  while (ANode <> NIL_NODE) and (LPeel < 8) and
        (FModel.Tree.Nodes[ANode].Kind in [nkParen, nkTypeArgs]) do
  begin
    ANode := FModel.Tree.Nodes[ANode].FirstChild;
    Inc(LPeel);
  end;
  if ANode = NIL_NODE then
    Exit;
  case FModel.Tree.Nodes[ANode].Kind of
    nkIdent:
      begin
        ASym := FModel.RefMap[ANode];
        if ASym <> NIL_SYM then
          Exit(True);   // AMid stays -1: bound in this model
        if (FProj <> nil) and FModel.ExtRefMap.TryGetValue(ANode, LExt) then
        begin
          AMid := LExt.UnitId;
          ASym := LExt.Sym;
          Exit(True);
        end;
        LKey := FModel.Tree.NodeNameLower(ANode);
        if LKey <> '' then
          Result := BridgeName(LKey, AMid, ASym);
      end;
    nkMember:
      begin
        LName := FModel.Tree.Nodes[ANode].FirstChild;
        LBase := DesignatorType(LName, 0);
        if LName <> NIL_NODE then
          LName := FModel.Tree.Nodes[LName].NextSibling;
        if (LName <> NIL_NODE) and ComplValid(LBase) then
          Result := MemberSymOf(LBase, FModel.Tree.NodeNameLower(LName), 0,
            AMid, ASym, ACtx);
      end;
  end;
end;

procedure TPasCompletion.AppendCallTarget(AMid, ASym, ACtx: Integer;
  var AInfo: TPasCallInfo);
var
  LM: TPasSemaModel;
  LSig: TPasBuiltinSig;
  LT: TPasCallTarget;
  LX: TSemaXType;
begin
  if not SymModelOf(AMid, 'AppendCallTarget', LM) then
    Exit;
  LT := Default(TPasCallTarget);
  LT.Mid := AMid;
  LT.Sym := ASym;
  LT.Ctx := ACtx;
  LT.Name := LM.Symbols[ASym].Name;
  if sfBuiltin in LM.Symbols[ASym].Flags then
  begin
    if PasBuiltinSignature(LM.Symbols[ASym].NameLower, LSig) then
    begin
      LT.ParamsText := LSig.Params;
      LT.HasParams := LSig.HasArgs;
      LT.ResultText := LSig.ResultType;
    end;
    // The seeds have no head token; the curated result says which head fits.
    if LT.ResultText <> '' then
      LT.HeadWord := 'function'
    else
      LT.HeadWord := 'procedure';
  end
  else
  begin
    LT.HeadWord := SymHeadWord(LM, ASym);
    LT.ParamsText := SymParamsText(AMid, ASym);
    LT.HasParams := SymHasParams(AMid, ASym);
    if AMid >= 0 then
    begin
      LX := FProj.SymDeclTypeX(AMid, ASym);
      if XValid(LX) then
        LT.ResultText := FProj.XTypeText(LX);
    end
    else if LM.Symbols[ASym].TypeSym <> NIL_SYM then
      LT.ResultText := LM.Symbols[LM.Symbols[ASym].TypeSym].Name;
  end;
  AInfo.Targets := AInfo.Targets + [LT];
end;

{ Expands one bound callee into targets: a routine reports its WHOLE overload
  family - the chain from its scope's HEAD, because the bound symbol may sit
  mid-chain (resolution binds the arity match) and each collapsed overload is
  its own signature here, unlike completion rows. A procedural VALUE (proc-
  type variable/parameter/field) reports itself alone. }
procedure TPasCompletion.AddCallTargets(AMid, ASym, ACtx: Integer;
  var AInfo: TPasCallInfo);
var
  LM: TPasSemaModel;
  LHead, LNext, LCount, LScope: Integer;
begin
  if (ASym = NIL_SYM) or not SymModelOf(AMid, 'AddCallTargets', LM) then
    Exit;
  if LM.Symbols[ASym].Kind <> skRoutine then
  begin
    if LM.Symbols[ASym].Kind in [skVar, skParam, skField, skProperty,
       skConst] then
      AppendCallTarget(AMid, ASym, ACtx, AInfo);
    Exit;   // units, labels, enum values offer nothing to call
  end;
  LHead := ASym;
  LScope := LM.Symbols[ASym].Scope;
  if LScope <> NIL_SCOPE then
  begin
    LNext := LM.FindLocal(LScope, LM.Symbols[ASym].NameLower);
    if LNext <> NIL_SYM then
      LHead := LNext;
  end;
  LNext := LHead;
  LCount := 0;
  while (LNext <> NIL_SYM) and (LCount < 16) do
  begin
    if LM.Symbols[LNext].Kind = skRoutine then
      AppendCallTarget(AMid, LNext, ACtx, AInfo);
    LNext := LM.Symbols[LNext].NextOverload;
    Inc(LCount);
  end;
end;

function TPasCompletion.CallAt(ALine, ACol: Integer;
  out AInfo: TPasCallInfo): Boolean;
var
  LTS: TPasTokenStream;
  LOffset, LRaw, LPrev, LArgs, LDepth, LSteps: Integer;
  LVis, LNode, LDesig, LOpen: Integer;
  LMid, LSym, LCtx, LCallNode: Integer;
  LResolved, LFound: Boolean;
begin
  Result := False;
  AInfo := Default(TPasCallInfo);
  if not CaretOffset(ALine, ACol, LOffset) then
    Exit;
  if LOffset = 0 then
    Exit;
  // Dead ($IFDEF'd-out) positions refuse outright, as CaretAt does: walking
  // backward from one would cross the whole inactive region onto unrelated
  // active code.
  if FModel.Tree.Source.IsSkipped(0, LOffset - 1) then
    Exit;
  LTS := FModel.Tree.Source.Files[0];
  LRaw := RawTokenAt(LOffset - 1);
  if LRaw < 0 then
    Exit;
  LRaw := PrevVisibleRaw(LRaw);

  // Backward over VISIBLE tokens: nesting over ()/[], top-level commas count
  // arguments, a statement boundary at depth 0 means no call at all. Trivia
  // never appears here, and a string or number is a single token, so parens
  // and commas inside either cannot fool the walk.
  LDepth := 0;
  LArgs := 0;
  LSteps := 0;
  LOpen := -1;
  LMid := -1;
  LSym := NIL_SYM;
  LCtx := NIL_INST;
  LResolved := False;
  LFound := False;
  while (LRaw >= 0) and (LSteps < 4096) and not LFound do
  begin
    case LTS.Tokens[LRaw].Kind of
      tkRParen, tkRBracket:
        Inc(LDepth);
      tkLBracket:
        if LDepth = 0 then
          // The caret sits inside an INDEXER (or set constructor): the
          // innermost CALL is further out, and the commas counted so far
          // were the bracket's own, not the call's.
          LArgs := 0
        else
          Dec(LDepth);
      tkLParen:
        if LDepth = 0 then
        begin
          LVis := FVisOfRaw[LRaw];
          LNode := NIL_NODE;
          if LVis >= 0 then
            LNode := InnermostNodeAt(LVis);
          // The '(' of a DECLARATION's parameter list: not a call, and
          // walking out of a declaration head helps nobody.
          if (LNode <> NIL_NODE) and
             (FModel.Tree.Nodes[LNode].Kind = nkParams) then
            Exit;
          LDesig := NIL_NODE;
          LCallNode := NIL_NODE;
          if (LNode <> NIL_NODE) and
             (FModel.Tree.Nodes[LNode].Kind = nkCall) then
          begin
            // A well-formed call owns its '(' directly: the callee child
            // ends before it, the arguments start after it.
            LCallNode := LNode;
            LDesig := FModel.Tree.Nodes[LNode].FirstChild;
          end
          else if (LNode = NIL_NODE) or
                  (FModel.Tree.Nodes[LNode].Kind <> nkParen) then
          begin
            // A parse broken around the caret: accept the `ident(` shape,
            // recovering the designator from the token to the left.
            LPrev := PrevVisibleRaw(LRaw - 1);
            if (LPrev >= 0) and
               (LTS.Tokens[LPrev].Kind = tkIdentifier) then
              LDesig := DesignatorNodeAtVis(FVisOfRaw[LPrev]);
          end;
          if LDesig <> NIL_NODE then
          begin
            LResolved := CalleeSyms(LDesig, LCallNode, LMid, LSym, LCtx);
            // A designator that names a TYPE is a cast, not a call - step
            // over it to the enclosing call, which is what a caret inside
            // `CheckResult(HRESULT(x|` wants to see.
            if LResolved and IsTypeSym(LMid, LSym) then
              LResolved := False
            else
            begin
              LOpen := LRaw;
              LFound := True;
            end;
          end;
          if not LFound then
            // Grouping paren (or a cast): the commas counted so far were
            // its own - reset and keep walking.
            LArgs := 0;
        end
        else
          Dec(LDepth);
      tkComma:
        if LDepth = 0 then
          Inc(LArgs);
      tkSemicolon, tkBegin, tkEnd, tkThen, tkDo, tkElse:
        if LDepth = 0 then
          Exit;   // left the statement without meeting an open paren
    end;
    if not LFound then
    begin
      LRaw := PrevVisibleRaw(LRaw - 1);
      Inc(LSteps);
    end;
  end;
  if LOpen < 0 then
    Exit;

  LTS.OffsetToLineCol(LTS.Tokens[LOpen].Start, AInfo.OpenLine, AInfo.OpenCol);
  AInfo.ArgIndex := LArgs;
  if LResolved then
    AddCallTargets(LMid, LSym, LCtx, AInfo);
  Result := True;
end;

function TPasCompletion.CompleteAt(ALine, ACol: Integer;
  out ACaret: TPasCaretInfo; out AContext: TPasComplContext;
  out AItems: TArray<TPasComplItem>): Boolean;
var
  LInfo: TPasCaretInfo;
  LRef: TPasComplTypeRef;
  LNode: Integer;
begin
  AContext := ccNone;
  AItems := nil;
  Result := CaretAt(ALine, ACol, LInfo);
  ACaret := LInfo;
  if not Result then
    Exit;
  FContext := ClassifyAt(LInfo);
  AContext := FContext;
  if FContext = ccUses then
  begin
    // Unit names are dotted; the caret's prefix/replace-span must be too.
    ExtendUsesPrefix(ALine, LInfo);
    ACaret := LInfo;
  end;
  FItems := nil;
  FCount := 0;
  // Not Clear: it discards the table's capacity AND virtual-notifies every
  // old entry - recreating at the same capacity is cheaper at list scale.
  FSeen.Free;
  FSeen := TDictionary<string, Integer>.Create(4096);
  FAncestryBuilt := False;
  FClassSide := False;
  FFieldsOnly := False;
  FBaseOwnUnit := False;
  case FContext of
    ccNone:
      Exit(False);
    ccMember:
      if LInfo.DotBase <> NIL_NODE then
      begin
        LRef := DesignatorType(LInfo.DotBase, 0);
        if ComplValid(LRef) then
        begin
          FClassSide := LRef.IsTypeRef;
          // `@TClass.Method` takes an INSTANCE method's address through the
          // class name (the vtable-building idiom) - the class-side filter
          // stands down under an address-of.
          if FClassSide then
          begin
            LNode := LInfo.DotBase;
            while FModel.Tree.Nodes[LNode].FirstChild <> NIL_NODE do
              LNode := FModel.Tree.Nodes[LNode].FirstChild;
            LNode := FModel.Tree.Nodes[LNode].FirstToken;   // visible idx
            if (LNode >= 0) and (LNode <= High(FModel.Tree.Source.Visible))
               and (FModel.Tree.Source.Visible[LNode].FileId = 0) then
            begin
              LNode := PrevVisibleRaw(
                FModel.Tree.Source.Visible[LNode].TokenIndex - 1);
              if (LNode >= 0) and
                 (FModel.Tree.Source.Files[0].Tokens[LNode].Kind = tkAt) then
                FClassSide := False;
            end;
          end;
          EnsureAncestry(LInfo.Scope);
          CollectMembers(LRef);
        end;
      end;
    ccUses:
      CollectUnitNames;
    ccInherited:
      begin
        // The ancestor of the innermost enclosing struct, instance side.
        EnsureAncestry(LInfo.Scope);
        if Length(FCaretStructs) > 0 then
        begin
          LRef := OverlayHeritageRef(FCaretStructs[0], 0);
          FBaseOwnUnit := True;
          if LRef.OvSym <> NIL_SYM then
            CollectOverlayChain(LRef.OvSym, True, cbMember)
          else
            CollectProjectMembers(LRef.X, cbMember);
        end;
      end;
    ccLabel:
      CollectLabels(LInfo);
    ccPropRead, ccPropWrite:
      begin
        // Only this class's (and its ancestors') members are legal after
        // read/write - the struct chain alone, no scope pipeline. The shape
        // filter (fields; functions vs procedures) lives in AddSym.
        EnsureAncestry(LInfo.Scope);
        for LNode := 0 to High(FCaretStructs) do
          CollectOverlayChain(FCaretStructs[LNode], True, cbStructMember);
      end;
    ccRecField:
      begin
        // The enclosing aggregate's record type, fields only.
        LNode := LInfo.Node;
        while (LNode <> NIL_NODE) and
              (FModel.Tree.Nodes[LNode].Kind <> nkAggregate) do
          LNode := FModel.Tree.Nodes[LNode].Parent;
        LRef := AggregateTypeOf(LNode, 0);
        if ComplValid(LRef) then
        begin
          FFieldsOnly := True;
          EnsureAncestry(LInfo.Scope);
          CollectMembers(LRef);
        end;
      end;
  else
    begin
      EnsureAncestry(LInfo.Scope);
      CollectScope(LInfo);
      AddContextKeywords(LInfo);
    end;
  end;
  SetLength(FItems, FCount);
  AItems := FItems;
  FItems := nil;
  FCount := 0;
end;

function TPasCompletion.EnclosingStructSym(AScope: Integer): Integer;
begin
  Result := NIL_SYM;
  while AScope <> NIL_SCOPE do
  begin
    if FModel.Scopes[AScope].StructSym <> NIL_SYM then
      Exit(FModel.Scopes[AScope].StructSym);
    AScope := FModel.Scopes[AScope].Parent;
  end;
end;

end.
