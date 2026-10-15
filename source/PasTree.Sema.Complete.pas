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
    { An ANONYMOUS array type, which no symbol names: its nkArrayType node
      (`var A: array of TRec`, an open-array parameter, the row of `array of
      array of T`) in model ArrMid (-1 = the overlay), with ArrSkip of its
      index types already consumed (`M[I]` over `array[0..1, 0..1] of T` is
      a row), closed over the frame ArrCtx. A named array keeps its symbol
      until a bracket leaves a row of it. }
    ArrMid: Integer;
    ArrNode: Integer;
    ArrSkip: Integer;
    ArrCtx: Integer;
    { The value is a POINTER to the type the other fields name: an inline
      `^T` resolves to T for the implicit deref (`P.X`), and this keeps the
      level an explicit `P^` or a `P[I]` takes. }
    ViaPointer: Boolean;
  end;

  { The display signature of a routine or a procedural value - see
    TPasCompletion.SymSignature. }
  TPasSymSignature = record
    HeadWord: string;     // 'function' / 'procedure' / ...; '' for no routine
    ParamsText: string;   // '(...)'; '' when parameterless
    HasParams: Boolean;
    ResultText: string;   // '' for a procedure
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
    { The nkCall node the caret is inside, NIL_NODE when the call was
      recovered from a broken parse (the `ident(` shape). A host that wants
      the ARGUMENT nodes - to annotate them, to count them - reads the
      tree from here rather than re-walking tokens (0.29.0). }
    CallNode: Integer;
    { The overload the RESOLVER bound the call to - SelectOverload's arity
      and type-score winner (or the RefMap/ExtRefMap binding of the name) -
      as one of Targets' (Mid, Sym) pairs; BoundSym = NIL_SYM when nothing
      bound. Targets lists the whole family, this says which member of it
      the call is a call OF - the one question a family cannot answer. }
    BoundMid: Integer;
    BoundSym: Integer;
    { True when (BoundMid, BoundSym) is the resolver's CallTarget for
      CallNode - a choice made over the ARGUMENTS. False when the name was
      bound by lookup alone (a bridged cross-unit name, a member found by
      name): then BoundSym is the family's head, not a selection, and a
      host that must pick one overload has to do its own arity match. }
    BoundExact: Boolean;
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
    // Per item: the `override`s listed under its name whose ancestor slot
    // the walk has not met yet (AddItem's overload count).
    FPendingOverrides: TArray<Integer>;
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
    // The caret is inside a method body - a struct's routine, or a routine or
    // anonymous method nested in one (11.2.1: a GENERIC class's plain
    // protected is reachable there, and only there).
    FInMethodBody: Boolean;
    // ccType where only a type IDENTIFIER may stand - a parameter's, a
    // result's, a property's type (6.2 ParamType = TypeRef): no subrange
    // bounds, so no constants and no enum values.
    FTypeNameOnly: Boolean;
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
    function OwnModelTypeX(AOvSym: Integer;
      ADepth: Integer = 0): TSemaXType;
    function OwnModelParamX(AOvSym: Integer): TSemaXType;
    function MethodBodyScope(AScope: Integer): Integer;
    function IsOverrideSym(AMid, ASym: Integer): Boolean;
    function MethodHasSelf(AMethodScope: Integer): Boolean;
    function TypeNameOnlyAt(const AInfo: TPasCaretInfo): Boolean;
    function IsStructMemberStart(const AInfo: TPasCaretInfo): Boolean;
    function StatementSiteKind(const AInfo: TPasCaretInfo): TPasNodeKind;
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
    function SymSignature(AMid, ASym: Integer): TPasSymSignature;
    procedure ParamsOf(AModel: TPasSemaModel; AParams: Integer;
      var ASig: TPasSymSignature);
    function IsTypeSym(AMid, ASym: Integer): Boolean;
    procedure ExtendUsesPrefix(ALine: Integer; var AInfo: TPasCaretInfo);
    // CallAt internals
    function DesignatorNodeAtVis(AVis: Integer): Integer;
    function CalleeSyms(ANode, ACallNode: Integer;
      out AMid, ASym, ACtx: Integer): Boolean;
    procedure AddCallTargets(AMid, ASym, ACtx: Integer;
      var AInfo: TPasCallInfo);
    procedure AppendCallTarget(AMid, ASym, ACtx: Integer;
      var AInfo: TPasCallInfo; ASkipSameSig: Boolean = False);
    function IsDescendantNode(ANode, AAncestor: Integer): Boolean;
    function UpChainNode(ANode: Integer; AKind: TPasNodeKind): Integer;
    function ForwardTypeAbove(ASym, ATypeSec: Integer): Boolean;
    function UpChainKind(ANode: Integer;
      const AKinds: array of TPasNodeKind): TPasNodeKind;
    function AggregateTypeOf(AAggNode, ADepth: Integer): TPasComplTypeRef;
    function OverlayStructDef(AOvSym: Integer): Integer;
    function OverlayHeritageRef(AOvSym, ADepth: Integer): TPasComplTypeRef;
    function ProjectTypeDef(const AX: TSemaXType): Integer;
    function ArrayElemRef(AMid, ADef, ACtx,
      ADepth: Integer): TPasComplTypeRef;
    function ElementTypeOf(const ABase: TPasComplTypeRef;
      ACount, ADepth: Integer): TPasComplTypeRef;
    function DesignatorSymOf(ANode, ADepth: Integer;
      out AMid, ASym: Integer): Boolean;
    function IsArrayPropertyDesignator(ANode, ADepth: Integer): Boolean;
    function ScopeOfNode(ANode: Integer): Integer;
    function IsUnitLevelSym(ASym: Integer): Boolean;
    function StructNestMember(ANode: Integer; const AKey: string;
      ADepth: Integer; out AMid, ASym, ACtx: Integer): Boolean;
    function BareNameSym(ANode, ADepth: Integer;
      out AMid, ASym, ACtx: Integer): Boolean;
    function IsResultRoutine(AMid, ASym: Integer): Boolean;
    function ArityOverload(AMid, ASym, ACall: Integer): Integer;
    function IsInheritedHead(ANode: Integer): Boolean;
    function WithMemberSym(ANode: Integer; const AKey: string;
      ADepth: Integer; out AMid, ASym, ACtx: Integer): Boolean;
    function ValueOfTypeRef(const ARef: TPasComplTypeRef;
      ADepth: Integer): TPasComplTypeRef;
    function ForInElementRef(ACollNode, ADepth: Integer): TPasComplTypeRef;
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
    procedure CollectMembers(const ABase: TPasComplTypeRef;
      ABucket: TPasComplBucket = cbMember);
    procedure AddSeeds;
    function IsDynArrayRef(const ARef: TPasComplTypeRef;
      ADepth: Integer): Boolean;
    function HeaderQualifierStruct(const AInfo: TPasCaretInfo): Integer;
    function IsRecordAggregate(AAggNode: Integer;
      AAnchor: TPasTokenKind): Boolean;
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
  PasTree.Sema.Builtins,
  PasTree.Sema.Types;

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
// -1.
function TPasCompletion.RawTokenAt(AOffset: Integer): Integer;
begin
  Result := FModel.Tree.Source.Files[0].RawTokenAt(AOffset);
end;

// 1-based (line, col) -> character offset into Files[0], clamped to the line
// end the way every host position is read (SynEdit's virtual space means "at
// the end"). False when the line itself is out of range.
function TPasCompletion.CaretOffset(ALine, ACol: Integer;
  out AOffset: Integer): Boolean;
begin
  // Clamped to the line end, before its break - landing ON the break is
  // fine too, the trivia walk-back reads both the same way.
  Result := FModel.Tree.Source.Files[0].OffsetOf(ALine, ACol, AOffset);
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
  // A `//` comment always runs to the line end, so its right edge - where
  // typing in it happens - is inside it too (audit A1-34).
  else if ((LOffset < LTS.Tokens[LRaw].EndPos) or
           (tfUnterminated in LTS.Tokens[LRaw].Flags) or
           (LKind = tkCommentLine)) and
          (LKind in [tkCommentLine, tkCommentBrace, tkCommentParen,
            tkDirective, tkStringLiteral, tkMultilineString, tkControlChar,
            tkCaretChar, tkIntLiteral, tkRealLiteral, tkAsmChunk, tkUnknown]) then
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
  Result.ArrMid := -1;
  Result.ArrNode := NIL_NODE;
  Result.ArrSkip := 0;
  Result.ArrCtx := NIL_INST;
  Result.ViaPointer := False;
end;

function ComplValid(const ARef: TPasComplTypeRef): Boolean;
begin
  Result := XValid(ARef.X) or (ARef.OvSym <> NIL_SYM) or (ARef.UnitMid >= 0) or
    (ARef.ArrNode <> NIL_NODE);
end;

// An anonymous array definition as a type reference (see ArrNode).
function ComplArrRef(AMid, ANode, ASkip, ACtx: Integer): TPasComplTypeRef;
begin
  Result := ComplNilRef;
  Result.ArrMid := AMid;
  Result.ArrNode := ANode;
  Result.ArrSkip := ASkip;
  Result.ArrCtx := ACtx;
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
         PasSameName(LPM.UsesList[LIdx].NameFull, AName) then
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
  symbol needs no bridging at all. A NESTED type is found through its outer
  type's twin (`TServicePair` declared in a class and written bare in its
  methods, `TList<TServicePair>`), ADepth bounding the nest. }
function TPasCompletion.OwnModelTypeX(AOvSym: Integer;
  ADepth: Integer): TSemaXType;
var
  LM: TPasSemaModel;
  LScope, LSym: Integer;
  LOuter: TSemaXType;
begin
  Result := XNil;
  if (AOvSym = NIL_SYM) or (FProj = nil) or (FProjMid < 0) or
     (ADepth > 16) then
    Exit;
  if not (FModel.Symbols[AOvSym].Kind in [skType, skBuiltinType]) then
    Exit;
  if FIsProjectModel then
    Exit(XPlain(FProjMid, AOvSym));
  LM := ProjModel(FProjMid, 'OwnModelTypeX');
  LScope := FModel.Symbols[AOvSym].Scope;
  if (LScope <> NIL_SCOPE) and (FModel.Scopes[LScope].Kind = sckStruct) then
  begin
    LOuter := OwnModelTypeX(FModel.Scopes[LScope].StructSym, ADepth + 1);
    if not XValid(LOuter) or (LOuter.UnitId <> FProjMid) or
       (LM.Symbols[LOuter.Sym].MemberScope = NIL_SCOPE) then
      Exit;
    LSym := LM.FindLocal(LM.Symbols[LOuter.Sym].MemberScope,
      FModel.Symbols[AOvSym].NameLower);
    if (LSym <> NIL_SYM) and (LM.Symbols[LSym].Kind = skType) then
      Result := XPlain(FProjMid, LSym);
    Exit;
  end;
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
  LMid, LSym, LIdx, LDecl, LInit, LOwner, LCtx: Integer;
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
            Exit(ValueOfTypeRef(Result, ADepth + 1));
          // An inferred one - a true constant, a resourcestring (always a
          // string, 3.2.3) - as the analysis recorded it.
          if FModel.Symbols[ASym].TypeNode = NIL_NODE then
          begin
            Result.X := FProj.DeclTypeX(FProjMid, ASym);
            if XValid(Result.X) then
              Exit;
          end;
        end;
        if FModel.Symbols[ASym].TypeNode <> NIL_NODE then
          Result := ValueOfTypeRef(ResolveTypeRefNode(
            FModel.Symbols[ASym].TypeNode, ADepth + 1), ADepth + 1)
        else if (FModel.Symbols[ASym].Kind = skProperty) and
                (FModel.Symbols[ASym].Scope <> NIL_SCOPE) then
        begin
          // A typeless REDECLARATION (`property Font;`, 13.1.1) is the
          // property it republishes: one link up the owner's heritage
          // (audit A1-28 - the analysis's SymDeclTypeX climb, which only the
          // project model reached).
          LOwner := FModel.Scopes[FModel.Symbols[ASym].Scope].StructSym;
          if (LOwner <> NIL_SYM) and MemberSymOf(OverlayHeritageRef(LOwner,
               ADepth + 1), FModel.Symbols[ASym].NameLower, ADepth + 1, LMid,
               LSym, LCtx) and ((LMid >= 0) or (LSym <> ASym)) then
          begin
            if LMid < 0 then
              Result := TypeOfOverlaySym(LSym, ADepth + 1)
            else
              Result := TypeOfProjectSym(LMid, LSym, LCtx, ADepth + 1);
          end;
        end
        else
        begin
          // `for var X in Coll` (5.5.2): the inline var is the for-in's
          // first child with no initializer - its type is the collection's
          // element (audit A1-29).
          LDecl := FModel.Symbols[ASym].DeclNode;
          if (LDecl <> NIL_NODE) and
             (FModel.Tree.Nodes[LDecl].Parent <> NIL_NODE) then
          begin
            LInit := FModel.Tree.Nodes[LDecl].Parent;
            if (FModel.Tree.Nodes[LInit].Kind = nkInlineVar) and
               (FModel.Tree.Nodes[LInit].Parent <> NIL_NODE) and
               (FModel.Tree.Nodes[FModel.Tree.Nodes[LInit].Parent].Kind =
                 nkForInStmt) and
               (FModel.Tree.Nodes[FModel.Tree.Nodes[LInit].Parent].
                 FirstChild = LInit) then
              Exit(ForInElementRef(FModel.Tree.Nodes[LInit].NextSibling,
                ADepth + 1));
          end;
          // `var X := expr` - an inline var with an inferred type: the
          // initializer is the last child of the nkInlineVar (3.1.3). A true
          // constant with no type (`C = 'abc'`, 3.2.1) has the same shape,
          // and its type is its initializer's: `C.Substring(` binds through
          // the string helper only once C types as a string.
          LDecl := FModel.Symbols[ASym].DeclNode;
          if (LDecl <> NIL_NODE) and
             (FModel.Tree.Nodes[LDecl].Parent <> NIL_NODE) and
             (FModel.Tree.Nodes[FModel.Tree.Nodes[LDecl].Parent].Kind
               in [nkInlineVar, nkInlineConst, nkConstDecl]) then
          begin
            // The last child short of a constant's trailing hints (`C =
            // 'abc' deprecated;` - nkDirective children).
            var LCh := FModel.Tree.Nodes[
              FModel.Tree.Nodes[LDecl].Parent].FirstChild;
            LInit := NIL_NODE;
            while LCh <> NIL_NODE do
            begin
              if FModel.Tree.Nodes[LCh].Kind <> nkDirective then
                LInit := LCh;
              LCh := FModel.Tree.Nodes[LCh].NextSibling;
            end;
            if (LInit <> NIL_NODE) and (LInit <> LDecl) and
               (FModel.Tree.Nodes[LInit].Kind <> nkAttrGroup) then
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
        Result := ValueOfTypeRef(ResolveTypeRefNode(
          FModel.Symbols[ASym].TypeNode, ADepth + 1), ADepth + 1);
    skEnumValue:
      if FModel.Symbols[ASym].TypeSym <> NIL_SYM then
        Result.OvSym := FModel.Symbols[ASym].TypeSym;   // value, not type ref
    skGenericParam:
      // A value typed as an unbound parameter has its CONSTRAINTS' members
      // (16 sec. 16.4.1) - the walk lives in EnumMembersX/FindMemberX, which
      // need a project-space identity: the symbol itself when this model IS
      // the project's, else its twin in the last-good model.
      if FIsProjectModel then
        Result.X := XPlain(FProjMid, ASym)
      else
        Result.X := OwnModelParamX(ASym);
  end;
end;

{ An overlay generic parameter's twin in the last-good model of this file,
  where ConstraintsOfParamX can read its constraints: the same-named
  parameter of the project twin of the type or method that declares it.
  A method body's `<T>` repeats no constraint (16.4.1: they are written once,
  on the declaration), so the body's T is looked up on its struct - the
  struct's own parameters, then a generic method of the segment's name
  (`TArray.BinarySearch<T>`). XNil when nothing matches. }
function TPasCompletion.OwnModelParamX(AOvSym: Integer): TSemaXType;
var
  LM: TPasSemaModel;
  LDecl, LList, LOwner, LChild, LSegment, LScope, LOvStruct, LCand: Integer;
  LStructX: TSemaXType;
  LKey, LSegKey: string;

  function MatchIn(ASym: Integer): TSemaXType;
  var
    LIdent, LParam: Integer;
  begin
    Result := XNil;
    for LIdent in TPasSemaProject.GenericParamIdentsOf(LM, ASym) do
      if LM.Tree.NodeNameLower(LIdent) = LKey then
      begin
        LParam := LM.RefMap[LIdent];
        if (LParam <> NIL_SYM) and (LM.Symbols[LParam].Kind = skGenericParam)
        then
          Exit(XPlain(FProjMid, LParam));
      end;
  end;

begin
  Result := XNil;
  if (FProj = nil) or (FProjMid < 0) then
    Exit;
  // ident -> nkGenericParam -> nkGenericParams -> the declaring node
  LDecl := FModel.Symbols[AOvSym].DeclNode;
  if (LDecl = NIL_NODE) or (FModel.Tree.Nodes[LDecl].Parent = NIL_NODE) then
    Exit;
  LList := FModel.Tree.Nodes[FModel.Tree.Nodes[LDecl].Parent].Parent;
  if (LList = NIL_NODE) or
     (FModel.Tree.Nodes[LList].Kind <> nkGenericParams) then
    Exit;
  LOwner := FModel.Tree.Nodes[LList].Parent;
  if LOwner = NIL_NODE then
    Exit;
  LKey := FModel.Symbols[AOvSym].NameLower;
  LM := ProjModel(FProjMid, 'OwnModelParamX');
  // A type's own `<T>`: the nkTypeDecl's name is the type.
  if FModel.Tree.Nodes[LOwner].Kind = nkTypeDecl then
  begin
    LChild := FModel.Tree.Nodes[LOwner].FirstChild;
    while (LChild <> NIL_NODE) and
          (FModel.Tree.Nodes[LChild].Kind <> nkIdent) do
      LChild := FModel.Tree.Nodes[LChild].NextSibling;
    if LChild = NIL_NODE then
      Exit;
    LStructX := OwnModelTypeX(FModel.RefMap[LChild]);
    if XValid(LStructX) and (LStructX.UnitId = FProjMid) then
      Result := MatchIn(LStructX.Sym);
    Exit;
  end;
  if FModel.Tree.Nodes[LOwner].Kind <> nkRoutine then
    Exit;
  // A routine header: the name segment the list follows says whose it is.
  LSegment := NIL_NODE;
  LChild := FModel.Tree.Nodes[LOwner].FirstChild;
  while (LChild <> NIL_NODE) and (LChild <> LList) do
  begin
    if nfName in FModel.Tree.Nodes[LChild].Flags then
      LSegment := LChild;
    LChild := FModel.Tree.Nodes[LChild].NextSibling;
  end;
  if LSegment = NIL_NODE then
    Exit;
  LSegKey := FModel.Tree.NodeNameLower(LSegment);
  LOvStruct := NIL_SYM;
  LScope := FModel.Symbols[AOvSym].Scope;
  while LScope <> NIL_SCOPE do
  begin
    if FModel.Scopes[LScope].StructSym <> NIL_SYM then
    begin
      LOvStruct := FModel.Scopes[LScope].StructSym;
      Break;
    end;
    LScope := FModel.Scopes[LScope].Parent;
  end;
  if LOvStruct = NIL_SYM then
    Exit;
  LStructX := OwnModelTypeX(LOvStruct);
  if not XValid(LStructX) or (LStructX.UnitId <> FProjMid) then
    Exit;
  if LM.Symbols[LStructX.Sym].NameLower = LSegKey then
    Exit(MatchIn(LStructX.Sym));
  if LM.Symbols[LStructX.Sym].MemberScope = NIL_SCOPE then
    Exit;
  LCand := LM.FindLocal(LM.Symbols[LStructX.Sym].MemberScope, LSegKey);
  while LCand <> NIL_SYM do
  begin
    if LM.Symbols[LCand].Kind = skRoutine then
    begin
      Result := MatchIn(LCand);
      if XValid(Result) then
        Exit;
    end;
    LCand := LM.Symbols[LCand].NextOverload;
  end;
end;

// The same, for a PROJECT symbol found through the bridge or a member walk.
function TPasCompletion.TypeOfProjectSym(AMid, ASym, ACtx, ADepth: Integer):
  TPasComplTypeRef;
var
  LM: TPasSemaModel;
  LIdx, LNode: Integer;
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
      // An inline `array ... of T` or `^T` slot names no type: the
      // declaration's own node is the type (audit A1-22, A1-24).
      LNode := LM.Symbols[ASym].TypeNode;
      if not XValid(Result.X) and (LNode <> NIL_NODE) then
        case LM.Tree.Nodes[LNode].Kind of
          nkArrayType:
            Exit(ComplArrRef(AMid, LNode, 0, ACtx));
          nkPointerType:
            begin
              Result.X := FProj.ResolveTypeExpr(AMid,
                LM.Tree.Nodes[LNode].FirstChild);
              Result.ViaPointer := True;
            end;
        end;
      if (ACtx <> NIL_INST) and XValid(Result.X) then
        Result.X := FProj.SubstX(Result.X, ACtx, 0);
      Result := ValueOfTypeRef(Result, ADepth + 1);
    end;
  end;
end;

// A TYPE EXPRESSION node of the overlay (a declared type, a heritage entry,
// a generic argument) resolved to a mixed-space TYPE reference.
function TPasCompletion.ResolveTypeRefNode(ANode, ADepth: Integer):
  TPasComplTypeRef;
var
  LSym, LMid, LChild, LCount, LArgNode, LNameNode: Integer;
  LKey: string;
  LBase, LArg, LOvGeneric: TPasComplTypeRef;
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
        begin
          // A BARE name Phase 1 bound to a generic of this unit names the
          // arity-0 declaration when there is one (16.1.2): `class(
          // TdxBarAccessibilityHelper)` beside an own `TdxBarAccessibility
          // Helper<T>` is the used unit's plain class. Not for the base of
          // `Name<Args>`, whose own branch picks the arity.
          LChild := FModel.Tree.Nodes[ANode].Parent;
          if (FModel.Symbols[LSym].Kind = skType) and
             (sfGeneric in FModel.Symbols[LSym].Flags) and
             (FProj <> nil) and (FProjMid >= 0) and
             not ((LChild <> NIL_NODE) and
                  (FModel.Tree.Nodes[LChild].Kind = nkTypeArgs) and
                  (FModel.Tree.Nodes[LChild].FirstChild = ANode)) then
          begin
            Result.X := OwnModelTypeX(LSym);
            if XValid(Result.X) then
            begin
              Result.X := FProj.PreferNonGenericByName(FProjMid,
                Result.X.UnitId, Result.X.Sym,
                FModel.Tree.NodeNameLower(ANode));
              if XValid(Result.X) and not (sfGeneric in ProjModel(
                 Result.X.UnitId, 'ResolveTypeRefIdent').Symbols[
                 Result.X.Sym].Flags) then
              begin
                Result.IsTypeRef := True;
                Exit;
              end;
            end;
            Result := ComplNilRef;
          end;
          Exit(TypeOfOverlaySym(LSym, ADepth + 1));
        end;
        LKey := FModel.Tree.NodeNameLower(ANode);
        if BridgeName(LKey, LMid, LSym) and
           (ProjModel(LMid, 'ResolveTypeRefIdent').Symbols[LSym].Kind in
             [skType, skBuiltinType])
        then
        begin
          Result.X := XPlain(LMid, LSym);
          // A name with no type arguments names the arity-0 declaration
          // (16.1.2) - the bridge's last-uses-wins lookup may land on a
          // generic of that name (`TList` with Classes listed before
          // Generics.Collections; audit A1-21).
          if sfGeneric in ProjModel(LMid, 'ResolveTypeRefIdent').
             Symbols[LSym].Flags then
            Result.X := FProj.PreferNonGenericByName(FProjMid, LMid, LSym,
              LKey);
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
        // A NON-generic type of the edited unit bound by name is the wrong
        // arity (`TList<TCollectionItem>` inside System.Classes, which
        // declares a plain TList): its last-good twin starts the arity
        // search below.
        if (LBase.OvSym <> NIL_SYM) and
           not (sfGeneric in FModel.Symbols[LBase.OvSym].Flags) then
        begin
          LBase.X := OwnModelTypeX(LBase.OvSym);
          LBase.OvSym := NIL_SYM;
        end;
        // An overlay GENERIC written with arguments: its last-good twin,
        // instantiated below, carries the frame - `TObjectList<T: class> =
        // class(TList<T>)` in one unit types TList's `First: T` as
        // TObjectList's T, constraint and all. Only when every argument lands
        // in project space; otherwise the overlay generic itself, whose
        // members are enumerable but whose parameters stay open.
        LOvGeneric := ComplNilRef;
        if LBase.OvSym <> NIL_SYM then
        begin
          LOvGeneric := LBase;
          LBase.X := OwnModelTypeX(LBase.OvSym);
          LBase.OvSym := NIL_SYM;
          if not XValid(LBase.X) then
            Exit(LOvGeneric);
        end;
        if not XValid(LBase.X) or (FProj = nil) or (FProjMid < 0) then
          Exit;
        // The declaration of the WRITTEN arity (16.1.2) - the by-name bridge
        // took whichever `TArray` was imported last, and System.Generics.
        // Collections' non-generic TArray class is not `TArray<T>` (audit
        // A1-21). The project's own rule, TypeAtArityX.
        LCount := 0;
        LArgNode := FModel.Tree.Nodes[LChild].NextSibling;
        while LArgNode <> NIL_NODE do
        begin
          Inc(LCount);
          LArgNode := FModel.Tree.Nodes[LArgNode].NextSibling;
        end;
        LNameNode := LChild;
        if FModel.Tree.Nodes[LNameNode].Kind = nkMember then
        begin
          LNameNode := FModel.Tree.Nodes[LNameNode].FirstChild;
          while (LNameNode <> NIL_NODE) and
                (FModel.Tree.Nodes[LNameNode].NextSibling <> NIL_NODE) do
            LNameNode := FModel.Tree.Nodes[LNameNode].NextSibling;
        end;
        if LNameNode <> NIL_NODE then
          LBase.X := FProj.TypeAtArityX(FProjMid, LBase.X, LCount, NIL_NODE,
            FModel.Tree.NodeNameLower(LNameNode));
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
        if (LOvGeneric.OvSym <> NIL_SYM) and
           not (LAllProject and (Length(LArgs) > 0)) then
          Exit(LOvGeneric);
        Result := LBase;
        if LAllProject and (Length(LArgs) > 0) then
          Result.X.Inst := FProj.Instantiate(LBase.X, LArgs);
      end;
    nkPointerType:
      begin
        // A value of an inline `^T` reaches T's members through the implicit
        // deref - resolve to the pointee directly (the same hop FindMemberX
        // makes for a NAMED pointer type), marked so `P^` and `P[I]` still
        // take the level (audit A1-24).
        Result := ResolveTypeRefNode(FModel.Tree.Nodes[ANode].FirstChild,
          ADepth + 1);
        Result.IsTypeRef := False;
        Result.ViaPointer := True;
      end;
    // An inline `array ... of T`: the node is the type (audit A1-22).
    nkArrayType:
      Result := ComplArrRef(-1, ANode, 0, NIL_INST);
    // An anonymous struct written inline (`var R: record X: T; end`): the
    // symbol DeclareAnonStruct gave it (audit B2-31).
    nkRecordType, nkClassType, nkInterfaceType, nkObjectType:
      begin
        Result.OvSym := FModel.StructSymAtNode(ANode);
        Result.IsTypeRef := True;
      end;
    // `string[N]` is a ShortString (7.1.3).
    nkStringType:
      if BridgeName('shortstring', LMid, LSym) then
      begin
        Result.X := XPlain(LMid, LSym);
        Result.IsTypeRef := True;
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
  LSym, LMid, LChild, LScope, LNode, LCtx: Integer;
  LKey: string;
  LCallee: TPasComplTypeRef;
  LRes, LCached: TSemaXType;
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
      Exit(ValueOfTypeRef(Result, ADepth + 1));
    end;
  case FModel.Tree.Nodes[ANode].Kind of
    nkParen:
      Result := DesignatorType(FModel.Tree.Nodes[ANode].FirstChild,
        ADepth + 1);
    nkIntLit, nkRealLit, nkStrLit, nkCaretChar:
      // A literal - `'abc'.Substring(`, or the initializer of an untyped
      // constant - types as dcc types it: `'x'` is a Char, `'xy'` a string,
      // which decides the helper (TCharHelper or TStringHelper).
      if FProj <> nil then
      begin
        LKey := FProj.LiteralTypeName(FModel.Tree, ANode, False);
        if (LKey <> '') and BridgeName(LKey, LMid, LSym) then
          Result.X := XPlain(LMid, LSym);
      end;
    nkUnaryOp, nkBinaryOp:
      begin
        // `X as T` is a T (12.4.1) - the type, wherever it is declared,
        // which the intra-unit typer cannot reach across units.
        LChild := FModel.Tree.Nodes[ANode].FirstChild;
        if (FModel.Tree.Nodes[ANode].Kind = nkBinaryOp) and
           (LChild <> NIL_NODE) and
           (FModel.Tree.Nodes[LChild].NextSibling <> NIL_NODE) and
           (FModel.Tree.Source.VisibleToken(
             FModel.Tree.Nodes[ANode].Aux).Kind = tkAs) then
        begin
          Result := ResolveTypeRefNode(FModel.Tree.Nodes[LChild].NextSibling,
            ADepth + 1);
          Result.IsTypeRef := False;
          Exit;
        end;
        // `C = 'AB' + 'CD'`, `-1`: the intra-unit typer's answer, which is
        // category-level (a sum of Chars is a string, any integer Integer) -
        // right for choosing a helper, which is all this is asked for.
        if FModel.ExprType[ANode] <> NIL_SYM then
        begin
          Result := TypeOfOverlaySym(FModel.ExprType[ANode], ADepth + 1);
          Result.IsTypeRef := False;
        end;
      end;
    nkIdent:
      begin
        LKey := FModel.Tree.NodeNameLower(ANode);
        // `Self` has no symbol anywhere (11.3.3) - answered structurally,
        // the same way the analysis answers it (StructSymOfNode). In a
        // CLASS method it is the class reference: class-side members only
        // (audit B2-28; dcc: an instance field there is E2124).
        if (LKey = 'self') and (FModel.RefMap[ANode] = NIL_SYM) then
        begin
          Result.OvSym := EnclosingStructSym(ScopeOfNode(ANode));
          LNode := ANode;
          while (LNode <> NIL_NODE) and
                (FModel.Tree.Nodes[LNode].Kind <> nkRoutine) do
            LNode := FModel.Tree.Nodes[LNode].Parent;
          Result.IsTypeRef := (LNode <> NIL_NODE) and
            (FModel.Tree.Nodes[LNode].Aux = 1);
          Exit;
        end;
        if BareNameSym(ANode, ADepth, LMid, LSym, LCtx) then
        begin
          if LMid < 0 then
            Exit(TypeOfOverlaySym(LSym, ADepth + 1));
          if FProj = nil then
            Exit;
          if ProjModel(LMid, 'DesignatorExtRef').Symbols[LSym].Kind
             in [skType, skBuiltinType, skUnitRef] then
            Exit(TypeOfProjectSym(LMid, LSym, NIL_INST, ADepth + 1));
          // The analysis's own CROSS-UNIT binding (an analyzed model only;
          // overlays have an empty ExtRefMap) comes with a cached expression
          // type for a VALUE, which also carries the closed instantiation
          // frame - `Statics` on a WinRT import class is typed as the bound
          // ARGUMENT, which nothing downstream can recover from the symbol
          // alone (the corpus oracle's whole `Statics.*` bucket).
          if FModel.ExprTypeX.TryGetValue(ANode, LCached) and
             XValid(LCached) then
          begin
            Result.X := LCached;
            Exit(ValueOfTypeRef(Result, ADepth + 1));
          end;
          Exit(TypeOfProjectSym(LMid, LSym, LCtx, ADepth + 1));
        end;
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
        // The routine the call binds to - the analysis's or Phase 1's
        // argument-matched overload (CallTargetX / CallTarget), the one
        // signature help shows - types it by its result: the overload chain's
        // head, which the callee's name alone gives, is another overload's
        // result (audit A1-26). A constructor keeps the walk below (its
        // value is the NAMED class), and so does a cast.
        if CalleeSyms(FModel.Tree.Nodes[ANode].FirstChild, ANode, LMid, LSym,
           LCtx) and IsResultRoutine(LMid, LSym) then
        begin
          if LMid >= 0 then
            LSym := ArityOverload(LMid, LSym, ANode);
          // Both answer a routine by its result as a VALUE (ValueOfTypeRef:
          // a class reference stays class side).
          if LMid < 0 then
            Result := TypeOfOverlaySym(LSym, ADepth + 1)
          else
            Result := TypeOfProjectSym(LMid, LSym, LCtx, ADepth + 1);
          if ComplValid(Result) then
            Exit;
        end;
        LCallee := DesignatorType(FModel.Tree.Nodes[ANode].FirstChild,
          ADepth + 1);
        if not ComplValid(LCallee) then
        begin
          // A compiler intrinsic has no declared result - `Copy(S, 1, 2).`,
          // `Chr(65).`: the intra-unit typer's answer, a seeded type bridged
          // to its real declaration (audit A1-27).
          if FModel.ExprType[ANode] <> NIL_SYM then
          begin
            Result := TypeOfOverlaySym(FModel.ExprType[ANode], ADepth + 1);
            Result.IsTypeRef := False;
          end;
          Exit;
        end;
        if LCallee.IsTypeRef then
        begin
          // A cast - T(expr) - or a value-typed use of a constructor's
          // class (T.Create is already an instance by MemberOf's ctor rule).
          // A cast to a class-reference type is class side.
          Exit(ValueOfTypeRef(LCallee, ADepth + 1));
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
        LChild := FModel.Tree.Nodes[ANode].FirstChild;
        Result := DesignatorType(LChild, ADepth + 1);
        // An array property's declared type is already the element's: the
        // brackets consume its parameters and peel nothing (13.1.2; audit
        // A1-20, E2-45 - `Components[0].` indexed TComponent again).
        if not IsArrayPropertyDesignator(LChild, ADepth + 1) then
        begin
          // One dimension per index expression (8.1.2; audit A1-25).
          LScope := 0;
          LNode := FModel.Tree.Nodes[LChild].NextSibling;
          while LNode <> NIL_NODE do
          begin
            Inc(LScope);
            LNode := FModel.Tree.Nodes[LNode].NextSibling;
          end;
          Result := ElementTypeOf(Result, LScope, ADepth + 1);
        end;
        // An indexed value - a value already, as both answers give it
        // (class side for a class reference).
      end;
  end;
end;

// The scope in effect at ANode: the innermost NodeScope up its parents.
function TPasCompletion.ScopeOfNode(ANode: Integer): Integer;
begin
  Result := NIL_SCOPE;
  while ANode <> NIL_NODE do
  begin
    if (ANode <= High(FModel.NodeScope)) and
       (FModel.NodeScope[ANode] <> NIL_SCOPE) then
      Exit(FModel.NodeScope[ANode]);
    ANode := FModel.Tree.Nodes[ANode].Parent;
  end;
end;

// Is an overlay symbol declared at UNIT level (a unit's interface or
// implementation, or the compiler seeds) - a binding a member of the
// caret's class nest outranks (3.3.2)?
function TPasCompletion.IsUnitLevelSym(ASym: Integer): Boolean;
var
  LScope: Integer;
begin
  LScope := FModel.Symbols[ASym].Scope;
  Result := (LScope <> NIL_SCOPE) and (FModel.Scopes[LScope].Kind in
    [sckSystem, sckUnit, sckImplementation]);
end;

{ A bare name inside a method looked up as dcc looks it up there (3.3.2):
  the class scope - the method's class and its ancestors, the cross-unit
  ones included - and then each class the method's class is nested in,
  before anything at unit level. MemberSymOf over each nest level: overlay
  heritage, then the bridged ancestry (FindMemberX). False outside a
  struct, or when no member carries the name. }
function TPasCompletion.StructNestMember(ANode: Integer; const AKey: string;
  ADepth: Integer; out AMid, ASym, ACtx: Integer): Boolean;
var
  LOv, LNext, LHop, LUp: Integer;
  LBase: TPasComplTypeRef;
begin
  Result := False;
  AMid := -1;
  ASym := NIL_SYM;
  ACtx := NIL_INST;
  if (AKey = '') or (ADepth > 16) then
    Exit;
  // Inside a routine's BODY only - its declarations and statements. In a
  // type's declaration and in a routine heading, a method's implementation
  // heading included, a member named like a unit does not hide it:
  // `F: ImageEnView.TIEMouseInteractItems` beside an inherited property
  // ImageEnView qualifies by the unit (3.3.2; dcc64 37.0, probe-b48 P1-P4).
  LUp := ANode;
  while (LUp <> NIL_NODE) and
        (FModel.Tree.Nodes[LUp].Kind <> nkRoutineBody) do
    LUp := FModel.Tree.Nodes[LUp].Parent;
  if LUp = NIL_NODE then
    Exit;
  LOv := EnclosingStructSym(ScopeOfNode(ANode));
  for LHop := 1 to 8 do
  begin
    if LOv = NIL_SYM then
      Break;
    LBase := ComplNilRef;
    LBase.OvSym := LOv;
    // A private member of another unit is passed over (3.3.2's filter: the
    // search goes on outward).
    if MemberSymOf(LBase, AKey, ADepth + 1, AMid, ASym, ACtx) and
       ((AMid < 0) or (AMid = FProjMid) or not (ProjModel(AMid,
         'StructNestMember').Symbols[ASym].Visibility in
         [svPrivate, svStrictPrivate])) then
      Exit(True);
    if FModel.Symbols[LOv].Scope = NIL_SCOPE then
      Break;
    LNext := FModel.Scopes[FModel.Symbols[LOv].Scope].StructSym;
    if LNext = LOv then
      Break;
    LOv := LNext;
  end;
  AMid := -1;
  ASym := NIL_SYM;
  ACtx := NIL_INST;
end;

{ What a bare identifier binds to (AMid = -1: an overlay symbol): a local, a
  parameter or a member the overlay bound; the analysis's cross-unit
  binding; a member of the caret's class nest - the inherited members of a
  class in another unit, which Phase 1 cannot see (`Canvas.`, `Owner.` in a
  form's method; audit A1-18) - before a unit-level binding or a name the
  bridge finds in the used units. On an analyzed model the analysis has
  already moved a unit-level binding a member outranks, so its RefMap is
  taken as it stands. }
function TPasCompletion.BareNameSym(ANode, ADepth: Integer;
  out AMid, ASym, ACtx: Integer): Boolean;
var
  LSym, LOv: Integer;
  LExt: TPasExtRef;
  LKey: string;
begin
  Result := True;
  AMid := -1;
  ASym := NIL_SYM;
  ACtx := NIL_INST;
  LKey := FModel.Tree.NodeNameLower(ANode);
  // `inherited Name` (12.1.2): the search starts at the ancestor of the
  // method's class - Phase 1 cannot follow an ancestry into another unit and
  // may have bound the class's own method of that name (`inherited
  // Remove(` in TObjectList is TList.Remove, not TObjectList.Remove).
  if not FIsProjectModel and IsInheritedHead(ANode) then
  begin
    LOv := EnclosingStructSym(ScopeOfNode(ANode));
    if (LOv <> NIL_SYM) and MemberSymOf(OverlayHeritageRef(LOv, ADepth + 1),
       LKey, ADepth + 1, AMid, ASym, ACtx) then
      Exit;
    AMid := -1;
    ASym := NIL_SYM;
    ACtx := NIL_INST;
    Exit(False);
  end;
  // An enclosing UNOPENED with (5.7) shadows everything: Phase 1 could not
  // open a target typed in another unit (`with InAddr do S_un_b.s_b1 :=`),
  // so its members are looked up here, innermost statement first and the
  // last target of one statement first. An analyzed model's with pass has
  // bound them already.
  if not FIsProjectModel and WithMemberSym(ANode, LKey, ADepth, AMid, ASym,
     ACtx) then
    Exit;
  LSym := FModel.RefMap[ANode];
  if (LSym <> NIL_SYM) and (FIsProjectModel or not IsUnitLevelSym(LSym)) then
  begin
    AMid := -1;
    ASym := LSym;
    ACtx := NIL_INST;
    Exit;
  end;
  if (FProj <> nil) and FModel.ExtRefMap.TryGetValue(ANode, LExt) then
  begin
    AMid := LExt.UnitId;
    ASym := LExt.Sym;
    ACtx := NIL_INST;
    Exit;
  end;
  if StructNestMember(ANode, LKey, ADepth, AMid, ASym, ACtx) then
    Exit;
  if LSym <> NIL_SYM then
  begin
    ASym := LSym;
    Exit;
  end;
  if (LKey <> '') and BridgeName(LKey, AMid, ASym) then
    Exit;
  AMid := -1;
  ASym := NIL_SYM;
  Result := False;
end;

// Is ANode the name `inherited` names - `inherited Foo`, the callee of
// `inherited Foo(...)`, the head of `inherited Foo.Bar`?
function TPasCompletion.IsInheritedHead(ANode: Integer): Boolean;
var
  LUp: Integer;
begin
  Result := False;
  for var LHop := 1 to 16 do
  begin
    LUp := FModel.Tree.Nodes[ANode].Parent;
    if LUp = NIL_NODE then
      Exit;
    if FModel.Tree.Nodes[LUp].Kind = nkInherited then
      Exit(True);
    if not (FModel.Tree.Nodes[LUp].Kind in [nkCall, nkMember, nkIndex]) or
       (FModel.Tree.Nodes[LUp].FirstChild <> ANode) then
      Exit;
    ANode := LUp;
  end;
end;

// A member of an enclosing UNOPENED with's target that ANode names - see
// BareNameSym.
function TPasCompletion.WithMemberSym(ANode: Integer; const AKey: string;
  ADepth: Integer; out AMid, ASym, ACtx: Integer): Boolean;
var
  LIdx, LBody, LTarget: Integer;
  LTargets: TArray<Integer>;
  LRef: TPasComplTypeRef;
begin
  Result := False;
  AMid := -1;
  ASym := NIL_SYM;
  ACtx := NIL_INST;
  if (AKey = '') or (ADepth > 16) then
    Exit;
  for LIdx := High(FModel.WithUnopened) downto 0 do
  begin
    LBody := FModel.Tree.Nodes[FModel.WithUnopened[LIdx]].FirstChild;
    if LBody = NIL_NODE then
      Continue;
    while FModel.Tree.Nodes[LBody].NextSibling <> NIL_NODE do
      LBody := FModel.Tree.Nodes[LBody].NextSibling;
    if not IsDescendantNode(ANode, LBody) then
      Continue;
    LTargets := nil;
    LTarget := FModel.Tree.Nodes[FModel.WithUnopened[LIdx]].FirstChild;
    while (LTarget <> NIL_NODE) and (LTarget <> LBody) do
    begin
      LTargets := LTargets + [LTarget];
      LTarget := FModel.Tree.Nodes[LTarget].NextSibling;
    end;
    for var LTi := High(LTargets) downto 0 do
    begin
      LRef := DesignatorType(LTargets[LTi], ADepth + 1);
      LRef.IsTypeRef := False;
      if ComplValid(LRef) and
         MemberSymOf(LRef, AKey, ADepth + 1, AMid, ASym, ACtx) then
        Exit(True);
    end;
  end;
  AMid := -1;
  ASym := NIL_SYM;
  ACtx := NIL_INST;
end;

{ A project routine found by NAME is its overload family's head; the
  overlay has no scorer for another unit's family, so the call's argument
  count picks the first member that takes it (6.2.5; TPasSemaTyper.ArityFits,
  the project's own arity rule) - `B.GetObj(1).` is the overload with a
  parameter. The analysis's exact choice (CallTargetX) already fits and is
  kept. }
function TPasCompletion.ArityOverload(AMid, ASym, ACall: Integer): Integer;
var
  LM: TPasSemaModel;
  LArgs, LReq, LTot, LCur, LHop: Integer;
  LTrailing, LVariadic: Boolean;
begin
  Result := ASym;
  if (FProj = nil) or (AMid < 0) or (ACall = NIL_NODE) or
     (FModel.Tree.Nodes[ACall].Kind <> nkCall) then
    Exit;
  LM := ProjModel(AMid, 'ArityOverload');
  LArgs := CallArgCount(FModel.Tree, ACall, LTrailing);
  LCur := ASym;
  for LHop := 1 to 64 do
  begin
    if LCur = NIL_SYM then
      Break;
    if (LM.Symbols[LCur].Kind = skRoutine) and
       FProj.RoutineArity(AMid, LCur, LReq, LTot, LVariadic) and
       (LVariadic or TPasSemaTyper.ArityFits(LArgs, LReq, LTot,
         LTrailing)) then
      Exit(LCur);
    LCur := LM.Symbols[LCur].NextOverload;
  end;
end;

// A routine whose call is typed by its declared result - not a constructor,
// whose value is the class it is called on (MemberOf's rule).
function TPasCompletion.IsResultRoutine(AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
  LRoutine: Integer;
begin
  Result := False;
  if (ASym = NIL_SYM) or not SymModelOf(AMid, 'IsResultRoutine', LM) or
     (LM.Symbols[ASym].Kind <> skRoutine) then
    Exit;
  if AMid >= 0 then
    Exit(not FProj.IsConstructorSym(AMid, ASym));
  LRoutine := RoutineNodeOf(FModel, ASym);
  Result := (LRoutine = NIL_NODE) or (FModel.Tree.Source.VisibleToken(
    FModel.Tree.Nodes[LRoutine].FirstToken).Kind <> tkConstructor);
end;

{ A VALUE of the type ARef names. A class-reference type's value is the
  class it refers to, class side (15.2.1): `C: TFooClass; C.` lists what
  `TFoo.` lists, not instance members (audit B2-27; dcc: an instance field
  through C is E2124). }
function TPasCompletion.ValueOfTypeRef(const ARef: TPasComplTypeRef;
  ADepth: Integer): TPasComplTypeRef;
var
  LDef: Integer;
  LX: TSemaXType;
begin
  Result := ARef;
  Result.IsTypeRef := False;
  if ADepth > 16 then
    Exit;
  if ARef.OvSym <> NIL_SYM then
  begin
    LDef := OverlayStructDef(ARef.OvSym);
    if (LDef <> NIL_NODE) and
       (FModel.Tree.Nodes[LDef].Kind = nkClassOf) then
    begin
      Result := ResolveTypeRefNode(FModel.Tree.Nodes[LDef].FirstChild,
        ADepth + 1);
      Result.IsTypeRef := True;
    end;
    Exit;
  end;
  if (FProj <> nil) and XValid(ARef.X) then
  begin
    LX := FProj.ClassRefTargetX(ARef.X);
    if XValid(LX) then
    begin
      Result := ComplNilRef;
      Result.X := LX;
      Result.IsTypeRef := True;
    end;
  end;
end;

{ The element of a `for var X in Coll` loop (5.5.2), as the project's
  ForInElementX reads it: a struct's enumerator - GetEnumerator's result,
  then its Current - and otherwise the collection's element (an array, a
  string; audit A1-29). }
function TPasCompletion.ForInElementRef(ACollNode,
  ADepth: Integer): TPasComplTypeRef;
var
  LColl, LEnum: TPasComplTypeRef;
begin
  Result := ComplNilRef;
  if (ACollNode = NIL_NODE) or (ADepth > 16) then
    Exit;
  LColl := DesignatorType(ACollNode, ADepth + 1);
  if not ComplValid(LColl) then
    Exit;
  LColl.IsTypeRef := False;
  LEnum := MemberOf(LColl, 'getenumerator', ADepth + 1);
  if ComplValid(LEnum) then
  begin
    Result := MemberOf(LEnum, 'current', ADepth + 1);
    if ComplValid(Result) then
    begin
      Result.IsTypeRef := False;
      Exit;
    end;
  end;
  Result := ElementTypeOf(LColl, 1, ADepth + 1);
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
      // The deep walk follows Phase 1's join into a same-unit ancestor; a
      // GENERIC one's member is reached through the heritage instead, whose
      // frame types its T (`Items[0].` in TObjectList<T: class> =
      // class(TList<T>) is TObjectList's T, not TList's open one).
      if (LSym <> NIL_SYM) and (FModel.Symbols[LSym].Scope <> NIL_SCOPE) then
      begin
        var LOwner := FModel.Scopes[FModel.Symbols[LSym].Scope].StructSym;
        if (LOwner <> NIL_SYM) and (LOwner <> LCur.OvSym) and
           (sfGeneric in FModel.Symbols[LOwner].Flags) then
          LSym := NIL_SYM;
      end;
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
// cross-model twin; both read TPasSemaProject.TypeDefNodeIn (audit D1-33).
function TPasCompletion.ProjectTypeDef(const AX: TSemaXType): Integer;
begin
  Result := NIL_NODE;
  if (FProj = nil) or not XValid(AX) then
    Exit;
  Result := TPasSemaProject.TypeDefNodeIn(ProjModel(AX.UnitId,
    'ProjectTypeDef'), AX.Sym);
end;

{ The type of an array's ELEMENT node, read in the model that holds it
  (AMid = -1: the overlay), closed over ACtx: another anonymous array (the
  row of `array of array of T`), an inline pointer, `array of const`'s
  TVarRec (6.2.6), or a type reference. }
function TPasCompletion.ArrayElemRef(AMid, ADef, ACtx,
  ADepth: Integer): TPasComplTypeRef;
var
  LM: TPasSemaModel;
  LElem, LMid, LSym: Integer;
begin
  Result := ComplNilRef;
  if not SymModelOf(AMid, 'ArrayElemRef', LM) then
    Exit;
  if LM.Tree.Nodes[ADef].Aux = 1 then
  begin
    if BridgeName('tvarrec', LMid, LSym) then
      Result.X := XPlain(LMid, LSym);
    Exit;
  end;
  LElem := PasArrayElemNode(LM.Tree, ADef);
  if LElem = NIL_NODE then
    Exit;
  if LM.Tree.Nodes[LElem].Kind = nkArrayType then
    Exit(ComplArrRef(AMid, LElem, 0, ACtx));
  // The element as a VALUE (ValueOfTypeRef: an array of class references
  // indexes to a class reference, class side).
  if AMid < 0 then
    Exit(ValueOfTypeRef(ResolveTypeRefNode(LElem, ADepth + 1), ADepth + 1));
  if LM.Tree.Nodes[LElem].Kind = nkPointerType then
  begin
    Result.X := FProj.ResolveTypeExpr(AMid, LM.Tree.Nodes[LElem].FirstChild);
    Result.ViaPointer := True;
  end
  else
    Result.X := FProj.ResolveTypeExpr(AMid, LElem);
  if (ACtx <> NIL_INST) and XValid(Result.X) then
    Result.X := FProj.SubstX(Result.X, ACtx, 0);
  if not Result.ViaPointer then
    Result := ValueOfTypeRef(Result, ADepth + 1);
end;

{ typeof(base[i1, .., iN]) - ACount index expressions applied to ABase, one
  DIMENSION each (8.1.2: `M[I, J]` is `M[I][J]`): an array consumes as many
  as it has index types and hands the rest to its element - a row of a
  multi-dimensional array, which has no type of its own, stays an ArrNode
  with ArrSkip dimensions consumed (audit A1-25); a string yields its
  character (AnsiChar for the 1-byte kinds, the project's StringElementX); a
  pointer its pointee (`P[I]`); a struct with a DEFAULT array property that
  property's type (13.1.2; the property takes the bracket's indices). Alias
  links are chased on both sides - an own-unit `TFooArray = TArray<TFoo>`
  was the everyday shape the overlay half missed (audit A1-23); an overlay
  struct's default property is asked of its last-good project twin. Where
  no ExprTypeX cache exists - every live overlay - this is the only answer. }
function TPasCompletion.ElementTypeOf(const ABase: TPasComplTypeRef;
  ACount, ADepth: Integer): TPasComplTypeRef;
var
  LCur, LNext: TPasComplTypeRef;
  LM: TPasSemaModel;
  LRem, LHop, LDef, LDims, LPropMid, LPropSym: Integer;
  LX: TSemaXType;
  LOwner: TSemaXType;
begin
  Result := ComplNilRef;
  if ADepth > 16 then
    Exit;
  LCur := ABase;
  LCur.IsTypeRef := False;
  LRem := ACount;
  for LHop := 1 to 64 do
  begin
    if LRem <= 0 then
      Exit(LCur);   // a value - class side when it is a class reference
    // An anonymous array definition in hand: consume its dimensions.
    if LCur.ArrNode <> NIL_NODE then
    begin
      if not SymModelOf(LCur.ArrMid, 'ElementTypeOf', LM) then
        Exit;
      LDims := PasArrayDims(LM.Tree, LCur.ArrNode) - LCur.ArrSkip;
      if LRem < LDims then
      begin
        Result := LCur;
        Inc(Result.ArrSkip, LRem);
        Exit;
      end;
      Dec(LRem, LDims);
      LCur := ArrayElemRef(LCur.ArrMid, LCur.ArrNode, LCur.ArrCtx, ADepth);
      Continue;
    end;
    // An inline `^T` value is resolved to T (the implicit deref); indexing
    // it is pointer indexing, which takes that level.
    if LCur.ViaPointer then
    begin
      LCur.ViaPointer := False;
      Dec(LRem);
      Continue;
    end;
    if LCur.OvSym <> NIL_SYM then
    begin
      LDef := OverlayStructDef(LCur.OvSym);
      if LDef = NIL_NODE then
        Exit;
      case FModel.Tree.Nodes[LDef].Kind of
        nkArrayType:
          LCur := ComplArrRef(-1, LDef, 0, NIL_INST);
        nkPointerType:
          begin
            LCur := ResolveTypeRefNode(FModel.Tree.Nodes[LDef].FirstChild,
              ADepth + 1);
            LCur.IsTypeRef := False;
            Dec(LRem);
          end;
        nkIdent, nkMember, nkTypeArgs:
          begin
            // An alias - chase it and index THAT.
            LNext := ResolveTypeRefNode(LDef, ADepth + 1);
            if LNext.OvSym = LCur.OvSym then
              Exit;
            LCur := LNext;
          end;
        nkClassType, nkRecordType, nkObjectType, nkInterfaceType:
          begin
            // A default array property: asked of the last-good twin.
            LX := OwnModelTypeX(LCur.OvSym);
            if not XValid(LX) then
              Exit;
            LCur := ComplNilRef;
            LCur.X := LX;
          end;
      else
        Exit;
      end;
      Continue;
    end;
    if (FProj = nil) or not XValid(LCur.X) then
      Exit;
    LM := ProjModel(LCur.X.UnitId, 'ElementTypeOf');
    // Indexing a STRING yields its character type - AnsiChar for the 1-byte
    // kinds, `string[N]` and the code-page strings included (7.2.1).
    LX := FProj.StringElementX(LCur.X.UnitId, LCur.X);
    if XValid(LX) then
    begin
      LCur := ComplNilRef;
      LCur.X := LX;
      Dec(LRem);
      Continue;
    end;
    // A character pointer's element is its character (no declaration node).
    if LM.Symbols[LCur.X.Sym].Kind = skBuiltinType then
    begin
      LX := FProj.PointeeX(LCur.X);
      LCur := ComplNilRef;
      LCur.X := LX;
      Dec(LRem);
      Continue;
    end;
    LDef := ProjectTypeDef(LCur.X);
    if LDef = NIL_NODE then
      Exit;
    case LM.Tree.Nodes[LDef].Kind of
      nkArrayType:
        LCur := ComplArrRef(LCur.X.UnitId, LDef, 0, LCur.X.Inst);
      nkPointerType:
        begin
          LX := FProj.PointeeX(LCur.X);   // P[I] - pointer indexing
          LCur := ComplNilRef;
          LCur.X := LX;
          Dec(LRem);
        end;
      nkIdent, nkMember, nkTypeArgs:
        begin
          // An alias - chase it and index THAT.
          LX := FProj.ResolveTypeExpr(LCur.X.UnitId, LDef);
          if (LCur.X.Inst <> NIL_INST) and XValid(LX) then
            LX := FProj.SubstX(LX, LCur.X.Inst, 0);
          if not XValid(LX) or ((LX.UnitId = LCur.X.UnitId) and
             (LX.Sym = LCur.X.Sym)) then
            Exit;
          LCur := ComplNilRef;
          LCur.X := LX;
        end;
      nkClassType, nkRecordType, nkObjectType, nkInterfaceType:
        begin
          // `L[I]` reads L.Items[I]: the default property's declared type is
          // the element's, closed over the frame it was found in; the
          // property takes the bracket's indices (a comma list read on past
          // it is dcc's E2016 - typed leniently, as the project typer does).
          if not FProj.DefaultArrayPropX(LCur.X, LPropMid, LPropSym,
             LOwner) then
            Exit;
          LCur := TypeOfProjectSym(LPropMid, LPropSym, LOwner.Inst,
            ADepth + 1);
          LRem := 0;
        end;
    else
      Exit;
    end;
  end;
end;

// typeof(base^): the pointee - project pointers via PointeeX, overlay
// pointer types via their definition node, alias links chased on both
// sides (`PRecAlias = PRec`, audit A1-23), and an inline `^T` value, which
// is resolved to T already, just loses its pointer mark (audit A1-24).
function TPasCompletion.PointeeTypeOf(const ABase: TPasComplTypeRef;
  ADepth: Integer): TPasComplTypeRef;
var
  LDef: Integer;
  LNext: TPasComplTypeRef;
begin
  Result := ComplNilRef;
  if ADepth > 16 then
    Exit;
  if ABase.ViaPointer then
  begin
    Result := ABase;
    Result.ViaPointer := False;
    Exit;
  end;
  if ABase.OvSym <> NIL_SYM then
  begin
    LDef := OverlayStructDef(ABase.OvSym);
    if LDef = NIL_NODE then
      Exit;
    case FModel.Tree.Nodes[LDef].Kind of
      nkPointerType:
        Result := ResolveTypeRefNode(FModel.Tree.Nodes[LDef].FirstChild,
          ADepth + 1);
      nkIdent, nkMember, nkTypeArgs:
        begin
          LNext := ResolveTypeRefNode(LDef, ADepth + 1);
          if LNext.OvSym <> ABase.OvSym then
            Result := PointeeTypeOf(LNext, ADepth + 1);
        end;
    end;
    Exit;
  end;
  if (FProj <> nil) and XValid(ABase.X) then
    Result.X := FProj.PointeeX(ABase.X);
end;

// The type-definition node of an overlay type symbol (TypeDefNodeIn: the
// child after the name and the generic parameters; an anonymous struct's own
// node).
function TPasCompletion.OverlayStructDef(AOvSym: Integer): Integer;
begin
  Result := TPasSemaProject.TypeDefNodeIn(FModel, AOvSym);
end;

{ The symbol a designator names, for the nkIndex rule below: an overlay
  binding (AMid = -1), the analysis's cross-unit one, or the member a dot
  hop finds. False when nothing names it. }
function TPasCompletion.DesignatorSymOf(ANode, ADepth: Integer;
  out AMid, ASym: Integer): Boolean;
var
  LExt: TPasExtRef;
  LChild, LCtx: Integer;
begin
  Result := False;
  AMid := -1;
  ASym := NIL_SYM;
  if (ANode = NIL_NODE) or (ADepth > 16) then
    Exit;
  case FModel.Tree.Nodes[ANode].Kind of
    nkIdent:
      begin
        ASym := FModel.RefMap[ANode];
        if ASym <> NIL_SYM then
          Exit(True);
        if FModel.ExtRefMap.TryGetValue(ANode, LExt) then
        begin
          AMid := LExt.UnitId;
          ASym := LExt.Sym;
          Exit(True);
        end;
        // Unbound on the overlay - an inherited member Phase 1 could not
        // reach (`Items[0]` through a generic ancestor): the same lookup
        // DesignatorType typed it by.
        Result := BareNameSym(ANode, ADepth + 1, AMid, ASym, LCtx);
      end;
    nkMember:
      begin
        LChild := FModel.Tree.Nodes[ANode].FirstChild;
        if LChild = NIL_NODE then
          Exit;
        Result := MemberSymOf(DesignatorType(LChild, ADepth + 1),
          FModel.Tree.NodeNameLower(FModel.Tree.Nodes[LChild].NextSibling),
          ADepth + 1, AMid, ASym, LCtx);
      end;
    nkParen:
      Result := DesignatorSymOf(FModel.Tree.Nodes[ANode].FirstChild,
        ADepth + 1, AMid, ASym);
  end;
end;

{ Does the designator ANode name an ARRAY property (13.1.2)? Then the
  brackets after it consume the property's parameters and the property's
  declared type IS the result - the rule CrossType's nkIndex applies
  (TPasSemaProject.IsArrayPropertySym); an overlay property reads its own
  declaration. }
function TPasCompletion.IsArrayPropertyDesignator(ANode,
  ADepth: Integer): Boolean;
var
  LMid, LSym: Integer;
begin
  Result := False;
  if not DesignatorSymOf(ANode, ADepth, LMid, LSym) then
    Exit;
  if LMid >= 0 then
    Exit((FProj <> nil) and FProj.IsArrayPropertySym(LMid, LSym));
  if FModel.Symbols[LSym].Kind <> skProperty then
    Exit;
  // `property Items;` - typeless: the parameters are the republished
  // declaration's, which only the analysis links.
  if FIsProjectModel then
    Exit(FProj.IsArrayPropertySym(FProjMid, LSym));
  Result := PasPropertyHasParams(FModel.Tree, FModel.Symbols[LSym].DeclNode);
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
        // A struct's ancestor is its FIRST child when that is a type
        // reference (PasHeritageRef - never a record's `end align`
        // operand); a helper's leading run ends with its extended type.
        if FModel.Tree.Nodes[LDef].Kind = nkHelperType then
        begin
          LChild := FModel.Tree.Nodes[LDef].FirstChild;
          if (LChild <> NIL_NODE) and not (FModel.Tree.Nodes[LChild].Kind in
             [nkIdent, nkMember, nkTypeArgs]) then
            LChild := NIL_NODE;
        end
        else
          LChild := PasHeritageRef(FModel.Tree, LDef);
        if LChild <> NIL_NODE then
        begin
          // For a helper, walk to the last leading ref.
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
// Is the routine ASym declared `override`? A flag the resolver stamps from
// either heading - kept by a text-demoted model, so no text is read.
function TPasCompletion.IsOverrideSym(AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
begin
  if ASym = NIL_SYM then
    Exit(False);
  if AMid < 0 then
    LM := FModel
  else
    LM := ProjModel(AMid, 'IsOverrideSym');
  Result := sfOverrideDirective in LM.Symbols[ASym].Flags;
end;

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
    // is an overload of the one already listed, not a new row - unless it is
    // the ancestor slot an `override` already listed redeclares: the walks
    // go from the type to its ancestors, so each override met earlier stands
    // for one declaration met later, and `Destroy` over TList, TEnumerable
    // and TObject is one signature, not three.
    if (AKind = skRoutine) and (FItems[LIdx].Kind = skRoutine) and
       (FItems[LIdx].Bucket <> cbKeyword) then
    begin
      if FPendingOverrides[LIdx] > 0 then
        Dec(FPendingOverrides[LIdx])
      else
        Inc(FItems[LIdx].Overloads);
      if IsOverrideSym(AMid, ASym) then
        Inc(FPendingOverrides[LIdx]);
    end;
    Exit;
  end;
  if FCount = Length(FItems) then
  begin
    if FCount = 0 then
      SetLength(FItems, 64)
    else
      SetLength(FItems, FCount * 2);
    SetLength(FPendingOverrides, Length(FItems));
  end;
  FPendingOverrides[FCount] := Ord((AKind = skRoutine) and
    IsOverrideSym(AMid, ASym));
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
  // A `class operator` is never reachable by name (9.3.1: `V.Add`,
  // `TVec.Add(V, V)` are E2003; audit E2-47), and a class constructor or
  // destructor can never be named (15.1.5; audit B2-29).
  if (LM.Symbols[ASym].Kind = skRoutine) and
     ((LM.RoutineHead(ASym) = rhOperator) or LM.IsClassCtorDtor(ASym)) then
    Exit;
  // Type positions take what can name a type - consts and enum values
  // included, because a SUBRANGE type's bounds are constant expressions
  // (`TVCLElements = teCategoryButtons..teTextLabel`, 2.2.5).
  if (FContext = ccType) and not (LM.Symbols[ASym].Kind in
    [skType, skBuiltinType, skUnitRef, skGenericParam, skConst,
     skEnumValue]) then
    Exit;
  // ... except where the type must be NAMED: `procedure P(A: 1..2)` and
  // `function F: 1..2` are E2029, `(A: K)` E2005 (local/probe-cc P5a-P5e).
  if FTypeNameOnly and (LM.Symbols[ASym].Kind in [skConst, skEnumValue]) then
    Exit;
  // `inherited X` names a method or a property of an ancestor; a field, a
  // class var, a nested type or a const there is E2096 Method identifier
  // expected (12.1.2; local/probe-cc P7).
  if (FContext = ccInherited) and
     not (LM.Symbols[ASym].Kind in [skRoutine, skProperty]) then
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
    // The overlay half needs no project - a standalone request still sees
    // an ancestor's strict protected members (audit B2-38).
    if FProj = nil then
      Continue;
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

// Visibility of a PROJECT member from this caret (11 sec. 11.2.1): private and
// protected are same-unit-friendly - the member's unit, or (protected) a base
// whose type this unit declares; a generic's protected is open in a method
// body; strict protected needs the caret's struct to descend from the
// declaring one, and the strict variants drop the friend rule. svDefault
// means "no section stated" and stays visible - hiding on a guess is the
// wrong failure mode for a list.
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
        // method bodies (spec 11.2.1) - spring4d's collections depend on the
        // access being legal there. From a unit-level routine, a main block
        // or an anonymous method in one it is E2362 (local/probe-cc P2a,
        // P2f, P2j): `L.Notify` in a program's main block is no candidate.
        if FInMethodBody and (LM.Symbols[ASym].Visibility = svProtected) and
           (LM.Symbols[ASym].Scope <> NIL_SCOPE) then
        begin
          LDeclStruct := LM.Scopes[LM.Symbols[ASym].Scope].StructSym;
          if (LDeclStruct <> NIL_SYM) and
             (sfGeneric in LM.Symbols[LDeclStruct].Flags) then
            Exit(True);
        end;
        // Plain `protected` has no descendant rule of its own: in a
        // descendant's method in another unit, TA's protected P is legal
        // through Self or a value of a class declared in that unit (the
        // friend rule above) and E2362 through a TA, a sibling or even a
        // further descendant declared elsewhere (local/probe-cc UB, UE).
        if LM.Symbols[ASym].Visibility = svProtected then
          Exit(False);
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
    // A type parameter of this unit is no type of it: `V.GetDisposed` on a
    // `T: class` value is E2362 in its own generic (local/probe-cc P1a).
    if (AX.UnitId = FProjMid) and (ProjModel(AX.UnitId,
       'CollectProjMembers').Symbols[AX.Sym].Kind <> skGenericParam) then
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
          begin
            // Class constructors / destructors and class operators are
            // AddSym's to refuse, as for every other walk.
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
  if (LScope = NIL_SCOPE) or (LM.Scopes[LScope].Symbols.Count = 0) then
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

procedure TPasCompletion.CollectMembers(const ABase: TPasComplTypeRef;
  ABucket: TPasComplBucket);
var
  LScope, LIdx, LSym: Integer;
begin
  if ABase.UnitMid >= 0 then
  begin
    // The edited unit qualifying ITSELF (`u4.`) reaches its unit-level
    // declarations of either section made so far (3.3.2 step 4) - the
    // overlay's own, typed since the last analysis included (audit B2-32).
    if (ABase.UnitMid = FProjMid) and (FModel.InterfaceScope <> NIL_SCOPE) then
    begin
      for LScope := 0 to FModel.Scopes.Count - 1 do
        if (LScope = FModel.InterfaceScope) or
           (FModel.Scopes[LScope].Kind = sckImplementation) then
          for LIdx := 0 to FModel.Scopes[LScope].Symbols.Count - 1 do
          begin
            LSym := FModel.Scopes[LScope].Symbols[LIdx];
            if (FModel.Symbols[LSym].Kind <> skUnitRef) and
               ((FCaretVis < 0) or
                not FModel.DeclaredAfter(LSym, FCaretVis)) then
              AddSym(-1, LSym, NIL_INST, ABucket);
          end;
      Exit;
    end;
    CollectUnitInterface(ABase.UnitMid, ABucket);
    // dcc lets `System.` qualify EVERY compiler-provided name (System.Delete,
    // System.PAnsiChar), so the System unit's list carries the seeds too -
    // and only System's: seeds are per-model copies, not anyone's exports.
    if (FProj <> nil) and (ABase.UnitMid = FProj.EnsureSystemUnit) then
      AddSeeds;
  end
  else
  begin
    if ABase.OvSym <> NIL_SYM then
      CollectOverlayChain(ABase.OvSym, True, ABucket)
    else if XValid(ABase.X) then
      CollectProjectMembers(ABase.X, ABucket);
    // `TBytes.Create(...)`: a dynamic array TYPE has the pseudo-constructor
    // (8.2.3), which no declaration carries (audit E2-48).
    if ABase.IsTypeRef and IsDynArrayRef(ABase, 0) then
      AddItem('Create', 'create', skRoutine, ABucket, -1, NIL_SYM,
        NIL_INST);
  end;
end;

// Does ARef name a DYNAMIC array type - an own-unit `array of T`, through
// aliases, or a project type (TPasSemaProject.IsDynArrayTypeX)?
function TPasCompletion.IsDynArrayRef(const ARef: TPasComplTypeRef;
  ADepth: Integer): Boolean;
var
  LDef: Integer;
  LNext: TPasComplTypeRef;
begin
  Result := False;
  if ADepth > 16 then
    Exit;
  if ARef.OvSym <> NIL_SYM then
  begin
    LDef := OverlayStructDef(ARef.OvSym);
    if LDef = NIL_NODE then
      Exit;
    case FModel.Tree.Nodes[LDef].Kind of
      nkArrayType:
        Result := (FModel.Tree.Nodes[LDef].Aux <> 1) and
          (FModel.Tree.Nodes[LDef].FirstChild <> NIL_NODE) and
          (FModel.Tree.Nodes[FModel.Tree.Nodes[LDef].FirstChild].NextSibling =
            NIL_NODE);
      nkIdent, nkMember, nkTypeArgs:
        begin
          LNext := ResolveTypeRefNode(LDef, ADepth + 1);
          if LNext.OvSym <> ARef.OvSym then
            Result := IsDynArrayRef(LNext, ADepth + 1);
        end;
    end;
  end
  else if XValid(ARef.X) and (FProj <> nil) then
    Result := FProj.IsDynArrayTypeX(ARef.X);
end;

// The compiler seeds of this model's System scope, as cbBuiltin rows.
procedure TPasCompletion.AddSeeds;
begin
  if FModel.SystemScope <> NIL_SCOPE then
    FModel.EnumScopeDeep(FModel.SystemScope,
      procedure(ASym, AScopeOfSym: Integer)
      begin
        AddSym(-1, ASym, NIL_INST, cbBuiltin);
      end);
end;

{ The struct an implementation heading's qualifier names, when the caret
  is the dot after it (`procedure TFoo.|Bar;`, `procedure TOuter.TInner.|`):
  the header's name segments are no bound designator (the resolver binds no
  qualifier segment), so they are looked up here - the first in the unit's
  scope, each next one among the previous struct's members. NIL_SYM when
  the caret is no such dot. }
function TPasCompletion.HeaderQualifierStruct(
  const AInfo: TPasCaretInfo): Integer;
var
  LTS: TPasTokenStream;
  LDot, LPrev, LVis, LNode, LRoutine, LSeg, LSym, LScope: Integer;
begin
  Result := NIL_SYM;
  LTS := FModel.Tree.Source.Files[0];
  if AInfo.Kind = ckAfterDot then
    LDot := AInfo.RawToken
  else if AInfo.Kind = ckIdent then
    LDot := PrevVisibleRaw(AInfo.RawToken - 1)
  else
    Exit;
  if (LDot < 0) or (LTS.Tokens[LDot].Kind <> tkDot) then
    Exit;
  LPrev := PrevVisibleRaw(LDot - 1);
  if (LPrev < 0) or (LPrev > High(FVisOfRaw)) then
    Exit;
  LVis := FVisOfRaw[LPrev];
  if LVis < 0 then
    Exit;
  LNode := InnermostNodeAt(LVis);
  if (LNode = NIL_NODE) or (FModel.Tree.Nodes[LNode].Kind <> nkIdent) or
     not (nfName in FModel.Tree.Nodes[LNode].Flags) then
    Exit;
  LRoutine := FModel.Tree.Nodes[LNode].Parent;
  if (LRoutine = NIL_NODE) or
     (FModel.Tree.Nodes[LRoutine].Kind <> nkRoutine) then
    Exit;
  LScope := ScopeOfNode(FModel.Tree.Nodes[LRoutine].Parent);
  LSeg := FModel.Tree.Nodes[LRoutine].FirstChild;
  LSym := NIL_SYM;
  while LSeg <> NIL_NODE do
  begin
    if (FModel.Tree.Nodes[LSeg].Kind = nkIdent) and
       (nfName in FModel.Tree.Nodes[LSeg].Flags) then
    begin
      if LSym = NIL_SYM then
      begin
        if LScope = NIL_SCOPE then
          Exit;
        LSym := FModel.Resolve(LScope, FModel.Tree.NodeNameLower(LSeg));
      end
      else if FModel.Symbols[LSym].MemberScope <> NIL_SCOPE then
        LSym := FModel.FindLocal(FModel.Symbols[LSym].MemberScope,
          FModel.Tree.NodeNameLower(LSeg))
      else
        LSym := NIL_SYM;
      if (LSym = NIL_SYM) or (FModel.Symbols[LSym].Kind <> skType) then
        Exit(NIL_SYM);
      if LSeg = LNode then
        Exit(LSym);
    end;
    LSeg := FModel.Tree.Nodes[LSeg].NextSibling;
  end;
end;

{ Is the aggregate a RECORD's (3.2.2), so that a fresh spot after its `(`
  or `;` is a field-name position? A `;` separates fields, a `,` array
  elements; after the `(` it is a record when a field is already written or
  the declared type is a record. An array constant's `(1, |` is an
  expression (audit A1-35). }
function TPasCompletion.IsRecordAggregate(AAggNode: Integer;
  AAnchor: TPasTokenKind): Boolean;
var
  LChild, LDef: Integer;
  LRef: TPasComplTypeRef;
  LM: TPasSemaModel;
begin
  case AAnchor of
    tkSemicolon:
      Exit(True);
    tkLParen:
      ;
  else
    Exit(False);
  end;
  LChild := FModel.Tree.Nodes[AAggNode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if FModel.Tree.Nodes[LChild].Kind = nkAggregateField then
      Exit(True);
    LChild := FModel.Tree.Nodes[LChild].NextSibling;
  end;
  Result := False;
  LRef := AggregateTypeOf(AAggNode, 0);
  if LRef.OvSym <> NIL_SYM then
  begin
    LDef := OverlayStructDef(LRef.OvSym);
    Result := (LDef <> NIL_NODE) and
      (FModel.Tree.Nodes[LDef].Kind = nkRecordType);
  end
  else if XValid(LRef.X) and (FProj <> nil) then
  begin
    LM := ProjModel(LRef.X.UnitId, 'IsRecordAggregate');
    LDef := ProjectTypeDef(LRef.X);
    Result := (LDef <> NIL_NODE) and
      (LM.Tree.Nodes[LDef].Kind = nkRecordType);
  end;
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
  LScope, LIdx, LTarget, LBody, LWith: Integer;
  LTargets, LJoins: TArray<Integer>;
  LStructDone: TArray<Boolean>;
  LOnSym: TPasSymEnumProc;
  LInterfaceOnly: Boolean;
  LRef: TPasComplTypeRef;
  LChainBucket: TPasComplBucket;
  LCaretTypeSec: Integer;
  // The caret is a slot that may name a type declared later in its own
  // section: a pointer's target (`^|`) or a class reference's (`class of |`).
  LEarlySlot: Boolean;

  // The inherited members of the caret struct whose own member scope AScope
  // is - once per struct.
  procedure CollectInheritedAt(AScope: Integer);
  var
    LI: Integer;
  begin
    if FModel.Scopes[AScope].StructSym = NIL_SYM then
      Exit;
    for LI := 0 to High(FCaretStructs) do
      if not LStructDone[LI] and
         (FModel.Scopes[AScope].StructSym = FCaretStructs[LI]) then
      begin
        LStructDone[LI] := True;
        CollectOverlayChain(FCaretStructs[LI], False, cbStructMember);
      end;
  end;

begin
  FCaretVis := AInfo.VisToken;
  // 1. The enclosing WITH statements (5.7), one walk: innermost statement
  // first and, within one statement, the LAST target first - the shadowing
  // order, and AddItem keeps the FIRST hit for a name. Opened (same-unit)
  // and unopened targets alike: an outer unopened with must not beat an
  // inner opened one, and an opened with's join is Phase 1's guess (audit
  // B2-34, D1-32). Each target through the with pass's own typer on an
  // analyzed model (an INDEXED target - `with Palette.palPalEntry[I] do` -
  // is typed by nothing else), DesignatorType on an overlay; its own members
  // before its ancestors, as cbWithMember rows.
  LWith := AInfo.Node;
  while LWith <> NIL_NODE do
  begin
    if FModel.Tree.Nodes[LWith].Kind = nkWithStmt then
    begin
      LBody := FModel.Tree.Nodes[LWith].FirstChild;
      while (LBody <> NIL_NODE) and
            (FModel.Tree.Nodes[LBody].NextSibling <> NIL_NODE) do
        LBody := FModel.Tree.Nodes[LBody].NextSibling;
      if (LBody <> NIL_NODE) and
         (LBody <> FModel.Tree.Nodes[LWith].FirstChild) and
         IsDescendantNode(AInfo.Node, LBody) then
      begin
        LTargets := nil;
        LTarget := FModel.Tree.Nodes[LWith].FirstChild;
        while (LTarget <> NIL_NODE) and (LTarget <> LBody) do
        begin
          LTargets := LTargets + [LTarget];
          LTarget := FModel.Tree.Nodes[LTarget].NextSibling;
        end;
        for var LTi := High(LTargets) downto 0 do
        begin
          LRef := ComplNilRef;
          if FIsProjectModel then
            LRef.X := FProj.WithTargetTypeX(FProjMid, LTargets[LTi]);
          if not ComplValid(LRef) then
          begin
            LRef := DesignatorType(LTargets[LTi], 0);
            LRef.IsTypeRef := False;
          end;
          if ComplValid(LRef) then
          begin
            FClassSide := False;
            CollectMembers(LRef, cbWithMember);
          end;
        end;
      end;
    end;
    LWith := FModel.Tree.Nodes[LWith].Parent;
  end;
  FClassSide := False;
  // `Self` has no symbol (11.3.3), so no scope lists it: a method body with
  // one names it beside its parameters (3.3.2 step 2).
  LScope := MethodBodyScope(AInfo.Scope);
  if (FContext in [ccStatement, ccExpression]) and (LScope <> NIL_SCOPE) and
     MethodHasSelf(LScope) then
    AddItem('Self', 'self', skParam, cbLocal, -1, NIL_SYM, NIL_INST);
  // 2. The lexical scope chain, deep (joined scopes included) - this is
  // exactly what unqualified lookup sees intra-unit: locals, params, the
  // enclosing struct's own members through the method-body join, enum
  // values, and the unit's own names; a with scope was step 1's. The
  // builtin seeds joined into the interface scope are skipped here and
  // added LAST (a real name must win the dedup against a seed).
  //
  // The BUCKET is the chain scope's (audit B2-36): a unit's own enum values
  // are unit symbols, not locals; a struct member joined into a method body
  // stays a struct member.
  EnsureAncestry(AInfo.Scope);
  SetLength(LStructDone, Length(FCaretStructs));
  LChainBucket := cbLocal;
  LCaretTypeSec := UpChainNode(AInfo.Node, nkTypeSec);
  if AInfo.Kind = ckIdent then
    LIdx := PrevVisibleRaw(AInfo.RawToken - 1)
  else
    LIdx := AInfo.RawToken;
  LEarlySlot := (LIdx >= 0) and
    ((FModel.Tree.Source.Files[0].Tokens[LIdx].Kind = tkCaret) or
     ((FModel.Tree.Source.Files[0].Tokens[LIdx].Kind = tkOf) and
      (UpChainKind(AInfo.Node, [nkClassOf, nkArrayType, nkSetType,
        nkFileType, nkCaseStmt]) = nkClassOf)));
  LOnSym :=
    procedure(ASym, AScopeOfSym: Integer)
    var
      LBucket: TPasComplBucket;
    begin
      case FModel.Scopes[AScopeOfSym].Kind of
        sckSystem:
          Exit;   // seeds come last, as cbBuiltin
        sckStruct:
          LBucket := cbStructMember;
      else
        LBucket := LChainBucket;
      end;
      // A declaration is visible only BELOW itself (3.3.2, "position
      // counts"): an inline var or const (3.1.3), and a unit-level or a
      // routine's own declaration alike - an implementation-section const,
      // type or routine under the caret is E2003 there, and so is a local
      // declared after a nested routine that names it (local/probe-cc
      // U3a-U3d). A struct's members are the exception: every method body
      // sees all of them. So is a type the caret's own `type` section
      // completes below it, where the language allows naming it early: a
      // pointer's target (`P = ^T; T = record`, 10.1.1), a class reference's
      // (`TC = class of T; T = class`, P10d), and a class whose
      // forward `TFoo = class;` stands above the caret (11.1.1; the
      // symbol's DeclNode is the completing declaration) - nothing else,
      // `TA = record X: TB; end; TB = Integer;` is E2003 (local/probe-cc
      // P10a-P10c).
      // (The section holding the caret, or one around it: a class's nested
      // `public type` section sits inside the unit's.)
      if not (FModel.Scopes[AScopeOfSym].Kind in [sckStruct, sckSystem]) and
         FModel.DeclaredAfter(ASym, FCaretVis) then
      begin
        if (LCaretTypeSec = NIL_NODE) or
           (FModel.Symbols[ASym].Kind <> skType) then
          Exit;
        var LSymSec := UpChainNode(FModel.Symbols[ASym].DeclNode, nkTypeSec);
        if (LSymSec = NIL_NODE) or not IsDescendantNode(AInfo.Node, LSymSec)
           or not (LEarlySlot or ForwardTypeAbove(ASym, LSymSec)) then
          Exit;
      end;
      AddSym(-1, ASym, NIL_INST, LBucket);
    end;
  LScope := AInfo.Scope;
  LInterfaceOnly := True;
  while LScope <> NIL_SCOPE do
  begin
    case FModel.Scopes[LScope].Kind of
      sckImplementation:
        begin
          LInterfaceOnly := False;
          LChainBucket := cbUnitSym;
        end;
      sckUnit:
        LChainBucket := cbUnitSym;
      sckStruct:
        LChainBucket := cbStructMember;
    else
      LChainBucket := cbLocal;
    end;
    if FModel.Scopes[LScope].Kind = sckWith then
    begin
      LScope := FModel.Scopes[LScope].Parent;
      Continue;
    end;
    // EnumScopeDeep's order, one join at a time: the shadowing joins, the
    // scope's own names, then its additional joins innermost first - and
    // after a caret struct's own member scope, that struct's INHERITED
    // members. The class scope, ancestors included, comes before any
    // enclosing scope (3.3.2): a unit global or an outer class's member of
    // the same name must not take the row of the inherited member the name
    // binds to (audit A1-19). A method body joins its class's member scope
    // and the outer classes' (innermost last); a struct declaration is its
    // own member scope.
    LJoins := FModel.Scopes[LScope].Shadowing;
    for LIdx := High(LJoins) downto 0 do
      FModel.EnumScopeDeep(LJoins[LIdx], LOnSym, 1);
    for LIdx := 0 to FModel.Scopes[LScope].Symbols.Count - 1 do
      LOnSym(FModel.Scopes[LScope].Symbols[LIdx], LScope);
    CollectInheritedAt(LScope);
    LJoins := FModel.Scopes[LScope].Additional;
    for LIdx := High(LJoins) downto 0 do
    begin
      FModel.EnumScopeDeep(LJoins[LIdx], LOnSym, 1);
      CollectInheritedAt(LJoins[LIdx]);
    end;
    LScope := FModel.Scopes[LScope].Parent;
  end;
  // 3. A nest level the chain never named (a scope shape the walk above does
  // not recognize) still gets its ancestors, last.
  for LIdx := 0 to High(FCaretStructs) do
    if not LStructDone[LIdx] then
      CollectOverlayChain(FCaretStructs[LIdx], False, cbStructMember);
  // 4. Cross-unit names: uses (reverse, last-wins), System, SysInit.
  CollectUsesImports(LInterfaceOnly);
  // 5. Compiler seeds, last - every real declaration outranks a seed.
  AddSeeds;
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
  LIdx, LRoot: Integer;
  LName, LKey, LOwn: string;
  LM: TPasSemaModel;
begin
  if FProj = nil then
    Exit;
  // Never a candidate (audit B2-30): the edited unit itself (F2092), the
  // implicit System and SysInit (`uses System` is E2004), and a program,
  // library or package (F2047) - only units can be used.
  LOwn := FModel.UnitNameLower;
  for LIdx := 0 to FProj.ModelCount - 1 do
    if LIdx <> FProjMid then
    begin
      LM := FProj.Model(LIdx);
      if (LM = nil) or (LM.Tree.Nodes = nil) then
        Continue;
      LRoot := LM.Tree.Nodes[0].FirstChild;
      if (LRoot <> NIL_NODE) and (LM.Tree.Nodes[LRoot].Kind in
         [nkProgram, nkLibrary, nkPackage]) then
        Continue;
      LName := ChangeFileExt(ExtractFileName(FProj.ModelFile(LIdx)), '');
      LKey := PasNameKey(LName);
      if (LKey = LOwn) or (LKey = 'system') or (LKey = 'sysinit') then
        Continue;
      AddItem(LName, LKey, skUnitRef, cbUnitName, LIdx, NIL_SYM, NIL_INST);
    end;
  // Mid = -1 for a path-scanned name: there is no model to point at. A
  // cbUnitName item's identity is its NAME either way - nothing resolves
  // these rows further.
  for LName in FProj.SearchPathUnitNames do
  begin
    LKey := PasNameKey(LName);
    if (LKey = LOwn) or (LKey = 'system') or (LKey = 'sysinit') then
      Continue;
    AddItem(LName, LKey, skUnitRef, cbUnitName, -1, NIL_SYM, NIL_INST);
  end;
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
// Does the `type` section ATypeSec declare ASym's FORWARD (`TFoo = class;`,
// `IFoo = interface;`) above the caret? The resolver moved the symbol's
// DeclNode to the completing declaration, so the section is read for it.
function TPasCompletion.ForwardTypeAbove(ASym, ATypeSec: Integer): Boolean;
var
  LDecl, LChild: Integer;
begin
  Result := False;
  LDecl := FModel.Tree.Nodes[ATypeSec].FirstChild;
  while (LDecl <> NIL_NODE) and
        (FModel.Tree.Nodes[LDecl].FirstToken <= FCaretVis) do
  begin
    if FModel.Tree.Nodes[LDecl].Kind = nkTypeDecl then
    begin
      LChild := FModel.Tree.Nodes[LDecl].FirstChild;
      while (LChild <> NIL_NODE) and
            (FModel.Tree.Nodes[LChild].Kind <> nkIdent) do
        LChild := FModel.Tree.Nodes[LChild].NextSibling;
      if (LChild <> NIL_NODE) and (FModel.RefMap[LChild] = ASym) then
        while LChild <> NIL_NODE do
        begin
          case FModel.Tree.Nodes[LChild].Kind of
            nkClassType:
              if FModel.Tree.Nodes[LChild].Aux = 1 then
                Exit(True);
            nkInterfaceType:
              if FModel.Tree.Nodes[LChild].Aux and 2 <> 0 then
                Exit(True);
          end;
          LChild := FModel.Tree.Nodes[LChild].NextSibling;
        end;
    end;
    LDecl := FModel.Tree.Nodes[LDecl].NextSibling;
  end;
end;

// The nearest node of AKind on ANode's parent chain (ANode included), or
// NIL_NODE.
function TPasCompletion.UpChainNode(ANode: Integer;
  AKind: TPasNodeKind): Integer;
begin
  Result := ANode;
  while (Result <> NIL_NODE) and (FModel.Tree.Nodes[Result].Kind <> AKind) do
    Result := FModel.Tree.Nodes[Result].Parent;
end;

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
  // So are a program's parameters (F17), names no scope has.
  if (LPrev <> NIL_NODE) and (FModel.Tree.Nodes[LPrev].Kind in
    [nkUnit, nkProgram, nkLibrary, nkPackage, nkProgramParams]) then
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
     (LTS.Tokens[AInfo.RawToken].Kind in [tkLParen, tkSemicolon]) and
     IsRecordAggregate(AInfo.Node, LTS.Tokens[AInfo.RawToken].Kind) then
    Exit(ccRecField);
  // The significant token LEFT of the (possibly empty) prefix decides.
  if AInfo.Kind = ckIdent then
    LPrev := PrevVisibleRaw(AInfo.RawToken - 1)
  else
    LPrev := AInfo.RawToken;
  if LPrev < 0 then
    Exit(ccStatement);
  LKind := LTS.Tokens[LPrev].Kind;
  // A visibility section word is identifier-lexed (a directive, 11.2.1) -
  // inside a structured type the caret after it starts a member.
  if (LKind = tkIdentifier) and (UpChainKind(AInfo.Node, [nkClassType,
     nkRecordType, nkObjectType, nkInterfaceType, nkHelperType]) <> nkError)
  then
    for var LWord in ['private', 'protected', 'public', 'published',
      'automated', 'strict'] do
      if SameText(Copy(LTS.Source, LTS.Tokens[LPrev].Start + 1,
         LTS.Tokens[LPrev].Len), LWord) then
        Exit(ccStatement);
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
    tkSemicolon, tkBegin, tkDo, tkRepeat, tkTry, tkFinally, tkExcept, tkEnd:
      Result := ccStatement;
    tkThen, tkElse:
      // The branches of an inline `if` are EXPRESSIONS (5.4.1).
      if UpChainKind(AInfo.Node, [nkInlineIf, nkIfStmt, nkCaseStmt]) =
         nkInlineIf then
        Result := ccExpression
      else
        Result := ccStatement;
    // Words that open or continue an EXPRESSION - a condition, a bound, a
    // selector, a raised object, an operand (audit A1-33: `if no|` never
    // offered `not`).
    tkIf, tkWhile, tkUntil, tkTo, tkDownto, tkCase, tkRaise, tkAnd, tkOr,
    tkXor, tkNot, tkDiv, tkMod, tkShl, tkShr, tkIn:
      Result := ccExpression;
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

{ A ccType position after a colon that a heading owns - a parameter's type,
  a function's result, a property's type, those of a procedural type: the
  grammar takes a type identifier there and no other type expression (6.2
  ParamType = TypeRef). A var, field, const or type declaration's colon is
  not one of them (a subrange is legal there, `X: 1..9`). }
function TPasCompletion.TypeNameOnlyAt(const AInfo: TPasCaretInfo): Boolean;
var
  LPrev: Integer;
begin
  Result := False;
  if AInfo.Kind = ckIdent then
    LPrev := PrevVisibleRaw(AInfo.RawToken - 1)
  else
    LPrev := AInfo.RawToken;
  if (LPrev < 0) or
     (FModel.Tree.Source.Files[0].Tokens[LPrev].Kind <> tkColon) then
    Exit;
  Result := UpChainKind(AInfo.Node, [nkParam, nkPropertyDecl, nkRoutine,
    nkProcType, nkVarDecl, nkVarSec, nkConstDecl, nkTypeDecl, nkInlineVar,
    nkInlineConst]) in [nkParam, nkPropertyDecl, nkRoutine, nkProcType];
end;

{ The construct a statement-class caret (ccStatement) stands in: the
  innermost statement list, routine declaration part or structured type on
  the chain - a caret right after a construct's closing `;` / `end` is past
  that construct. nkError when none is (unit level). }
function TPasCompletion.StatementSiteKind(
  const AInfo: TPasCaretInfo): TPasNodeKind;
var
  LNode: Integer;
begin
  LNode := AInfo.Node;
  if (LNode <> NIL_NODE) and
     (FModel.Tree.Nodes[LNode].LastToken = AInfo.VisToken) and
     (FModel.Tree.Source.Files[0].Tokens[AInfo.RawToken].Kind in
       [tkSemicolon, tkEnd]) then
    LNode := FModel.Tree.Nodes[LNode].Parent;
  // A record's variant part is no member start: its labels are constant
  // expressions (`msAny: ();`, 9.1.3).
  Result := UpChainKind(LNode, [nkBlock, nkInitSec, nkFinalSec, nkRoutine,
    nkVariantPart, nkClassType, nkRecordType, nkObjectType, nkInterfaceType,
    nkHelperType]);
end;

{ The start of a member in a structured type's declaration (11.1): what can
  stand there is a keyword (a visibility, `procedure`, `property`, `class`,
  `type`, `const`, `var`, ...) or the NAME of a new field - nothing to
  complete - so no declared name is a candidate; a type stands only after
  the field's colon or inside an attribute's brackets, other contexts. }
function TPasCompletion.IsStructMemberStart(
  const AInfo: TPasCaretInfo): Boolean;
var
  LPrev: Integer;
begin
  Result := False;
  if FContext <> ccStatement then
    Exit;
  // Only where a member STARTS: after a `;`, a section word, the type's
  // opening word or its heritage / GUID bracket. After `procedure` or
  // `function` an interface's name may stand - a method resolution clause,
  // `procedure IFoo.M = DoM;` (14.2.2).
  if AInfo.Kind = ckIdent then
    LPrev := PrevVisibleRaw(AInfo.RawToken - 1)
  else
    LPrev := AInfo.RawToken;
  if (LPrev < 0) or not (FModel.Tree.Source.Files[0].Tokens[LPrev].Kind in
     [tkSemicolon, tkIdentifier, tkClass, tkRecord, tkObject, tkInterface,
      tkDispinterface, tkRParen, tkRBracket, tkEnd]) then
    Exit;
  case StatementSiteKind(AInfo) of
    nkClassType, nkRecordType, nkObjectType, nkInterfaceType, nkHelperType:
      Result := True;
    nkError:
      Result := (AInfo.Scope <> NIL_SCOPE) and
        (FModel.Scopes[AInfo.Scope].Kind = sckStruct);
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
  // A routine's declaration part, before its `begin` (6.1).
  ROUTINE_WORDS: array[0..7] of string = ('var', 'const', 'type', 'label',
    'procedure', 'function', 'begin', 'asm');
  // A parameter's, a result's, a property's type (TypeNameOnlyAt).
  PARAM_TYPE_WORDS: array[0..2] of string = ('array', 'string', 'file');
begin
  case FContext of
    ccExpression:
      AddKeywords(EXPR_WORDS);
    ccType:
      if FTypeNameOnly then
        AddKeywords(PARAM_TYPE_WORDS)
      else
        AddKeywords(TYPE_WORDS);
    ccStatement:
      begin
        // Decided by the NODE (audit A1-32): a statement list - a block, a
        // program's main block, an initialization or finalization section -
        // takes statement words; a routine's declaration part declaration
        // words; elsewhere the scope says unit level or a struct body.
        case StatementSiteKind(AInfo) of
          nkBlock, nkInitSec, nkFinalSec:
            AddKeywords(STMT_WORDS);
          nkRoutine:
            AddKeywords(ROUTINE_WORDS);
        else
          if AInfo.Scope <> NIL_SCOPE then
            case FModel.Scopes[AInfo.Scope].Kind of
              sckUnit, sckImplementation:
                AddKeywords(UNIT_WORDS);
              sckStruct:
                AddKeywords(STRUCT_WORDS);
            else
              AddKeywords(STMT_WORDS);
            end;
        end;
      end;
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
begin
  Result := '';
  if (AItem.Kind <> skRoutine) or (AItem.Sym = NIL_SYM) or
     (AItem.Bucket = cbKeyword) then
    Exit;
  Result := SymSignature(AItem.Mid, AItem.Sym).HeadWord;
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

{ The signature of a routine - or of a procedural VALUE, through its type -
  as display text: one place for the builtin table, the declared routine and
  the procedural type, so a completion row and a signature-help target say
  the same (audit B2-37: a builtin row had no head word while its call
  target was a 'function'; B2-35: a procedural value showed no parameters
  and its type's name as the result). The model is resolved once. }
function TPasCompletion.SymSignature(AMid, ASym: Integer): TPasSymSignature;
var
  LM, LDefM: TPasSemaModel;
  LSig: TPasBuiltinSig;
  LParams, LChild, LDef, LResult: Integer;
  LX: TSemaXType;
  LRef: TPasComplTypeRef;
begin
  Result := Default(TPasSymSignature);
  if (ASym = NIL_SYM) or not SymModelOf(AMid, 'SymSignature', LM) then
    Exit;
  if sfBuiltin in LM.Symbols[ASym].Flags then
  begin
    if LM.Symbols[ASym].Kind <> skRoutine then
      Exit;
    if PasBuiltinSignature(LM.Symbols[ASym].NameLower, LSig) then
    begin
      Result.ParamsText := LSig.Params;
      Result.HasParams := LSig.HasArgs;
      Result.ResultText := LSig.ResultType;
    end;
    // The seeds have no head token; the table says which head fits - a
    // function whose result depends on its arguments (High, Copy, Abs) has
    // no result text but is a function all the same (audit D1-16).
    if LSig.IsFunction then
      Result.HeadWord := 'function'
    else
      Result.HeadWord := 'procedure';
    Exit;
  end;
  if LM.Symbols[ASym].Kind = skRoutine then
  begin
    Result.HeadWord := SymHeadWord(LM, ASym);
    LParams := SymParamsNode(LM, ASym);
    ParamsOf(LM, LParams, Result);
    if AMid >= 0 then
    begin
      LX := FProj.SymDeclTypeX(AMid, ASym);
      if XValid(LX) then
        Result.ResultText := FProj.XTypeText(LX);
    end
    else if LM.Symbols[ASym].TypeNode <> NIL_NODE then
    begin
      // The overlay's own routine: its result type bridged as the project
      // types it (HINST, not ''), else the written text.
      LRef := ResolveTypeRefNode(LM.Symbols[ASym].TypeNode, 0);
      if XValid(LRef.X) and (FProj <> nil) then
        Result.ResultText := FProj.XTypeText(LRef.X)
      else if LRef.OvSym <> NIL_SYM then
        Result.ResultText := LM.Symbols[LRef.OvSym].Name
      else
        Result.ResultText := CollapseSpaces(
          LM.Tree.NodeSpanText(LM.Symbols[ASym].TypeNode));
    end;
    Exit;
  end;
  if not (LM.Symbols[ASym].Kind in [skVar, skParam, skField, skProperty,
     skConst]) then
    Exit;
  // A procedural value: the nkProcType its declared type is (6.6.1),
  // written inline or named.
  LDefM := LM;
  LDef := LM.Symbols[ASym].TypeNode;
  if (LDef = NIL_NODE) or (LM.Tree.Nodes[LDef].Kind <> nkProcType) then
  begin
    LDef := NIL_NODE;
    if AMid >= 0 then
      LX := FProj.SymDeclTypeX(AMid, ASym)
    else
    begin
      LX := XNil;
      if LM.Symbols[ASym].TypeNode <> NIL_NODE then
      begin
        LRef := ResolveTypeRefNode(LM.Symbols[ASym].TypeNode, 0);
        if LRef.OvSym <> NIL_SYM then
          LDef := OverlayStructDef(LRef.OvSym)
        else
          LX := LRef.X;
      end;
    end;
    if XValid(LX) and (FProj <> nil) then
    begin
      LDefM := ProjModel(LX.UnitId, 'SymSignature');
      LDef := TPasSemaProject.TypeDefNodeIn(LDefM, LX.Sym);
    end;
    if (LDef = NIL_NODE) or (LDefM.Tree.Nodes[LDef].Kind <> nkProcType) then
      Exit;
  end;
  LParams := NIL_NODE;
  LResult := NIL_NODE;
  LChild := LDefM.Tree.Nodes[LDef].FirstChild;
  while LChild <> NIL_NODE do
  begin
    case LDefM.Tree.Nodes[LChild].Kind of
      nkParams:
        LParams := LChild;
      nkDirective, nkAttrGroup:
        ;
    else
      if LResult = NIL_NODE then
        LResult := LChild;
    end;
    LChild := LDefM.Tree.Nodes[LChild].NextSibling;
  end;
  ParamsOf(LDefM, LParams, Result);
  if LResult <> NIL_NODE then
  begin
    Result.HeadWord := 'function';
    Result.ResultText := CollapseSpaces(LDefM.Tree.NodeSpanText(LResult));
  end
  else
    Result.HeadWord := 'procedure';
end;

// The display text of a parameter list node and whether it declares any
// parameter - an empty `()` renders as '' and takes none.
procedure TPasCompletion.ParamsOf(AModel: TPasSemaModel; AParams: Integer;
  var ASig: TPasSymSignature);
var
  LChild: Integer;
begin
  ASig.ParamsText := '';
  ASig.HasParams := False;
  if AParams = NIL_NODE then
    Exit;
  LChild := AModel.Tree.Nodes[AParams].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if AModel.Tree.Nodes[LChild].Kind = nkParam then
    begin
      ASig.HasParams := True;
      ASig.ParamsText := CollapseSpaces(AModel.Tree.NodeSpanText(AParams));
      Exit;
    end;
    LChild := AModel.Tree.Nodes[LChild].NextSibling;
  end;
end;

function TPasCompletion.ItemParamsText(const AItem: TPasComplItem): string;
begin
  Result := '';
  if (AItem.Kind = skRoutine) and (AItem.Sym <> NIL_SYM) and
     (AItem.Bucket <> cbKeyword) then
    Result := SymSignature(AItem.Mid, AItem.Sym).ParamsText;
end;

function TPasCompletion.ItemHasParams(const AItem: TPasComplItem): Boolean;
begin
  Result := (AItem.Kind = skRoutine) and (AItem.Sym <> NIL_SYM) and
    (AItem.Bucket <> cbKeyword) and
    SymSignature(AItem.Mid, AItem.Sym).HasParams;
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
  LExt: TPasExtRef;
  LSym: Integer;
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
    // Phase 1's choice - unless, on an overlay, it is a unit-level routine
    // a bare name in a method reaches only when no member of the class nest
    // carries that name (BareNameSym: a TStream descendant's `Write(` is the
    // inherited method, not the intrinsic), or the name `inherited` calls,
    // which Phase 1 cannot follow into another unit's ancestor.
    if FModel.CallTarget.TryGetValue(ACallNode, LSym) and
       (LSym <> NIL_SYM) then
    begin
      if (FModel.Tree.Nodes[ANode].Kind = nkIdent) and not FIsProjectModel then
        if IsInheritedHead(ANode) then
        begin
          if BareNameSym(ANode, 0, AMid, ASym, ACtx) then
            Exit(True);
        end
        else if IsUnitLevelSym(LSym) and
                StructNestMember(ANode, FModel.Tree.NodeNameLower(ANode), 0,
                  AMid, ASym, ACtx) then
          Exit(True);
      AMid := -1;
      ASym := LSym;
      ACtx := NIL_INST;
      Exit(True);
    end;
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
      Result := BareNameSym(ANode, 0, AMid, ASym, ACtx);
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
  var AInfo: TPasCallInfo; ASkipSameSig: Boolean);
var
  LM: TPasSemaModel;
  LSig: TPasSymSignature;
  LT: TPasCallTarget;
begin
  if not SymModelOf(AMid, 'AppendCallTarget', LM) then
    Exit;
  // Each identity once: the family walks below may meet a member twice.
  for var LIdx := 0 to High(AInfo.Targets) do
    if (AInfo.Targets[LIdx].Mid = AMid) and (AInfo.Targets[LIdx].Sym = ASym) then
      Exit;
  LSig := SymSignature(AMid, ASym);
  // An ancestor's member with a signature already listed is the one an
  // override redeclares - one signature, shown once.
  if ASkipSameSig then
    for var LIdx := 0 to High(AInfo.Targets) do
      if SameText(AInfo.Targets[LIdx].ParamsText, LSig.ParamsText) and
         SameText(AInfo.Targets[LIdx].ResultText, LSig.ResultText) then
        Exit;
  LT := Default(TPasCallTarget);
  LT.Mid := AMid;
  LT.Sym := ASym;
  LT.Ctx := ACtx;
  LT.Name := LM.Symbols[ASym].Name;
  LT.HeadWord := LSig.HeadWord;
  LT.ParamsText := LSig.ParamsText;
  LT.HasParams := LSig.HasParams;
  LT.ResultText := LSig.ResultText;
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
  LM, LAM: TPasSemaModel;
  LHead, LScope, LOther, LStruct, LHop: Integer;
  LKey: string;
  LX: TSemaXType;
  LRef: TPasComplTypeRef;
  LOverload: Boolean;

  // One overload chain from its head - every member, however long (audit
  // A1-31: a cap of 16 dropped TStringBuilder.Append's multi-parameter
  // forms; the chain cannot loop, the count only guards a corrupt graph).
  procedure AddChain(AChainMid, AHead: Integer;
    AAncestor: Boolean = False);
  var
    LCM: TPasSemaModel;
    LNext, LCount: Integer;
  begin
    if (AHead = NIL_SYM) or not SymModelOf(AChainMid, 'AddChain', LCM) then
      Exit;
    LNext := AHead;
    LCount := 0;
    while (LNext <> NIL_SYM) and (LCount <= LCM.SymCount) do
    begin
      if LCM.Symbols[LNext].Kind = skRoutine then
        AppendCallTarget(AChainMid, LNext, ACtx, AInfo, AAncestor);
      LNext := LCM.Symbols[LNext].NextOverload;
      Inc(LCount);
    end;
  end;

  // Does the set headed by AHead let the family go on into the ancestors?
  // A member saying `overload` does, and so does an `override` -
  // overriding is not hiding (the project's candidate rule, audit B33).
  function GoesOn(AModel: TPasSemaModel; AHead: Integer): Boolean;
  var
    LNext, LCount: Integer;
  begin
    Result := False;
    LNext := AHead;
    LCount := 0;
    while (LNext <> NIL_SYM) and (LCount <= AModel.SymCount) do
    begin
      if AModel.RoutineSaysOverload(LNext) or
         (sfOverrideDirective in AModel.Symbols[LNext].Flags) then
        Exit(True);
      LNext := AModel.Symbols[LNext].NextOverload;
      Inc(LCount);
    end;
  end;

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
  LKey := LM.Symbols[ASym].NameLower;
  LHead := ASym;
  LScope := LM.Symbols[ASym].Scope;
  if LScope <> NIL_SCOPE then
  begin
    LHead := LM.FindLocal(LScope, LKey);
    if LHead = NIL_SYM then
      LHead := ASym;
  end;
  AddChain(AMid, LHead);
  if LScope <> NIL_SCOPE then
  begin
    // A unit routine's interface overloads and its implementation-only ones
    // are two chains in two scopes, and a call scores both (6.3.1; audit
    // B2-33).
    LOther := NIL_SCOPE;
    if LScope = LM.InterfaceScope then
    begin
      for var LS := 0 to LM.Scopes.Count - 1 do
        if LM.Scopes[LS].Kind = sckImplementation then
        begin
          LOther := LS;
          Break;
        end;
    end
    else if LM.Scopes[LScope].Kind = sckImplementation then
      LOther := LM.InterfaceScope;
    if LOther <> NIL_SCOPE then
      AddChain(AMid, LM.FindLocal(LOther, LKey));
    // A method's family goes on into the ancestors while each set says
    // `overload` (6.3.1, 12.1.1): the overloads a base class declares are
    // callable through the descendant.
    LStruct := NIL_SYM;
    if LM.Scopes[LScope].Kind = sckStruct then
      LStruct := LM.Scopes[LScope].StructSym;
    LOverload := GoesOn(LM, LHead);
    LX := XNil;
    if (LStruct <> NIL_SYM) and LOverload then
    begin
      if AMid >= 0 then
        LX := XPlain(AMid, LStruct)
      else
      begin
        // The overlay's own ancestors first, then the bridged ones.
        LRef := ComplNilRef;
        LRef.OvSym := LStruct;
        for LHop := 1 to 64 do
        begin
          LRef := OverlayHeritageRef(LRef.OvSym, 0);
          if LRef.OvSym = NIL_SYM then
            Break;
          if FModel.Symbols[LRef.OvSym].MemberScope = NIL_SCOPE then
            Break;
          LHead := FModel.FindLocal(FModel.Symbols[LRef.OvSym].MemberScope,
            LKey);
          if LHead <> NIL_SYM then
          begin
            AddChain(-1, LHead, True);
            if not GoesOn(FModel, LHead) then
            begin
              LOverload := False;
              Break;
            end;
          end;
        end;
        if LOverload and XValid(LRef.X) then
          LX := LRef.X
        else
          LX := XNil;
        // Walk the bridged part from LX itself (the overlay chain ended
        // AT it), not from its ancestor.
        if XValid(LX) and (FProj <> nil) then
        begin
          if not SymModelOf(LX.UnitId, 'AddCallTargets', LAM) then
            LX := XNil
          else if LAM.Symbols[LX.Sym].MemberScope <> NIL_SCOPE then
          begin
            LHead := LAM.FindLocal(LAM.Symbols[LX.Sym].MemberScope, LKey);
            if LHead <> NIL_SYM then
            begin
              AddChain(LX.UnitId, LHead, True);
              if not GoesOn(LAM, LHead) then
                LX := XNil;
            end;
          end;
        end;
      end;
      for LHop := 1 to 64 do
      begin
        if not XValid(LX) or (FProj = nil) then
          Break;
        LX := FProj.AncestorOfX(LX);
        if not XValid(LX) then
          Break;
        if not SymModelOf(LX.UnitId, 'AddCallTargets', LAM) then
          Break;
        if LAM.Symbols[LX.Sym].MemberScope = NIL_SCOPE then
          Continue;
        LHead := LAM.FindLocal(LAM.Symbols[LX.Sym].MemberScope, LKey);
        if LHead = NIL_SYM then
          Continue;
        AddChain(LX.UnitId, LHead, True);
        if not GoesOn(LAM, LHead) then
          Break;
      end;
    end;
  end;
  // The bound overload is one of Targets, whatever the walks met (the
  // TPasCallInfo contract; audit A1-31).
  AppendCallTarget(AMid, ASym, ACtx, AInfo);
end;

function TPasCompletion.CallAt(ALine, ACol: Integer;
  out AInfo: TPasCallInfo): Boolean;
var
  LTS: TPasTokenStream;
  LOffset, LRaw, LPrev, LArgs, LDepth, LSteps, LCaretRaw: Integer;
  LVis, LNode, LDesig, LOpen: Integer;
  LMid, LSym, LCtx, LCallNode: Integer;
  LResolved, LFound: Boolean;
begin
  Result := False;
  AInfo := Default(TPasCallInfo);
  AInfo.CallNode := NIL_NODE;
  AInfo.BoundMid := -1;
  AInfo.BoundSym := NIL_SYM;
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
  LCaretRaw := LRaw;

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
  LCallNode := NIL_NODE;
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
        begin
          // An ARGUMENT can hold these at depth 0 - an inline `if C then 1
          // else 2` (5.4.1) or an anonymous method's `begin ... end`
          // (17.2.1): the whole construct is one opaque argument, so the
          // walk resumes before it (audit A1-30). Anything else left the
          // statement without meeting an open paren.
          LNode := NIL_NODE;
          if FVisOfRaw[LRaw] >= 0 then
            LNode := InnermostNodeAt(FVisOfRaw[LRaw]);
          while (LNode <> NIL_NODE) and not (FModel.Tree.Nodes[LNode].Kind
                in [nkInlineIf, nkAnonMethod, nkCall, nkBlock,
                  nkRoutine]) do
            LNode := FModel.Tree.Nodes[LNode].Parent;
          // An anonymous method's own body block sits under it.
          if (LNode <> NIL_NODE) and
             (FModel.Tree.Nodes[LNode].Kind = nkBlock) then
          begin
            LDesig := LNode;
            while (LDesig <> NIL_NODE) and not (FModel.Tree.Nodes[LDesig].Kind
                  in [nkAnonMethod, nkRoutine, nkCall]) do
              LDesig := FModel.Tree.Nodes[LDesig].Parent;
            if (LDesig <> NIL_NODE) and
               (FModel.Tree.Nodes[LDesig].Kind = nkAnonMethod) then
              LNode := LDesig;
          end;
          if (LNode = NIL_NODE) or not (FModel.Tree.Nodes[LNode].Kind in
             [nkInlineIf, nkAnonMethod]) then
            Exit;
          // A caret INSIDE an anonymous method is in its own statements,
          // not in the outer call's argument list.
          if (FModel.Tree.Nodes[LNode].Kind = nkAnonMethod) and
             (FModel.Tree.Source.Visible[
               FModel.Tree.Nodes[LNode].LastToken].TokenIndex >= LCaretRaw)
          then
            Exit;
          LVis := LeftmostVis(LNode);
          if (LVis < 0) or (FModel.Tree.Source.Visible[LVis].FileId <> 0) then
            Exit;
          LRaw := PrevVisibleRaw(
            FModel.Tree.Source.Visible[LVis].TokenIndex - 1);
          Inc(LSteps);
          Continue;
        end;
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
  AInfo.CallNode := LCallNode;
  AInfo.BoundExact := (LCallNode <> NIL_NODE) and
    (FModel.CallTarget.ContainsKey(LCallNode) or
     FModel.CallTargetX.ContainsKey(LCallNode));
  if LResolved then
  begin
    AInfo.BoundMid := LMid;
    AInfo.BoundSym := LSym;
    AddCallTargets(LMid, LSym, LCtx, AInfo);
  end;
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
  FCaretVis := LInfo.VisToken;
  FContext := ClassifyAt(LInfo);
  AContext := FContext;
  if FContext = ccUses then
  begin
    // Unit names are dotted; the caret's prefix/replace-span must be too.
    ExtendUsesPrefix(ALine, LInfo);
    ACaret := LInfo;
  end;
  FItems := nil;
  FPendingOverrides := nil;
  FCount := 0;
  // Not Clear: it discards the table's capacity AND virtual-notifies every
  // old entry - recreating at the same capacity is cheaper at list scale.
  FSeen.Free;
  FSeen := TDictionary<string, Integer>.Create(4096);
  FAncestryBuilt := False;
  FClassSide := False;
  FFieldsOnly := False;
  FBaseOwnUnit := False;
  FInMethodBody := MethodBodyScope(LInfo.Scope) <> NIL_SCOPE;
  FTypeNameOnly := (FContext = ccType) and TypeNameOnlyAt(LInfo);
  case FContext of
    ccNone:
      Exit(False);
    ccMember:
      if LInfo.DotBase = NIL_NODE then
      begin
        // `procedure TFoo.|Bar;` - an implementation heading's qualifier:
        // the struct's declared routines and nested types (audit E2-48).
        LNode := HeaderQualifierStruct(LInfo);
        if (LNode <> NIL_SYM) and
           (FModel.Symbols[LNode].MemberScope <> NIL_SCOPE) then
        begin
          var LMembers := FModel.Symbols[LNode].MemberScope;
          for var LI := 0 to FModel.Scopes[LMembers].Symbols.Count - 1 do
          begin
            var LMem := FModel.Scopes[LMembers].Symbols[LI];
            if FModel.Symbols[LMem].Kind in [skRoutine, skType] then
              AddSym(-1, LMem, NIL_INST, cbMember);
          end;
        end;
      end
      else
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
      // A member's start in a type declaration takes keywords alone.
      if not IsStructMemberStart(LInfo) then
      begin
        EnsureAncestry(LInfo.Scope);
        CollectScope(LInfo);
      end;
      AddContextKeywords(LInfo);
    end;
  end;
  SetLength(FItems, FCount);
  AItems := FItems;
  FItems := nil;
  FPendingOverrides := nil;
  FCount := 0;
end;

function TPasCompletion.EnclosingStructSym(AScope: Integer): Integer;
begin
  Result := FModel.EnclosingStructSymOfScope(AScope);
end;

{ The routine scope of the method whose body holds AScope - the innermost
  routine scope on the chain that names its struct, past nested routines and
  anonymous methods - or NIL_SCOPE outside every method body: unit level, a
  main block, a struct's declaration. }
function TPasCompletion.MethodBodyScope(AScope: Integer): Integer;
begin
  while AScope <> NIL_SCOPE do
  begin
    case FModel.Scopes[AScope].Kind of
      sckRoutine:
        if FModel.Scopes[AScope].StructSym <> NIL_SYM then
          Exit(AScope);
      sckStruct, sckUnit, sckImplementation:
        Break;
    end;
    AScope := FModel.Scopes[AScope].Parent;
  end;
  Result := NIL_SCOPE;
end;

{ Does the method of AMethodScope have `Self` (3.3.2's body rule): an
  instance method, a constructor, a non-static class method do; a `class
  ... static` one does not, and only its declaration says `static` - the
  implementation heading never repeats it, so the struct's same-named class
  routine is asked. }
function TPasCompletion.MethodHasSelf(AMethodScope: Integer): Boolean;
var
  LRoutine, LChild, LName, LMembers, LDecl, LDeclRoutine: Integer;
begin
  Result := True;
  LRoutine := FModel.Scopes[AMethodScope].OwnerNode;
  if (LRoutine = NIL_NODE) or
     (FModel.Tree.Nodes[LRoutine].Kind <> nkRoutine) or
     (FModel.Tree.Nodes[LRoutine].Aux <> 1) then
    Exit;
  LName := NIL_NODE;
  LChild := FModel.Tree.Nodes[LRoutine].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if nfName in FModel.Tree.Nodes[LChild].Flags then
      LName := LChild
    else if FModel.Tree.Nodes[LChild].Kind = nkDirective then
      if FModel.Tree.NodeTextEquals(LChild, 'static') then
        Exit(False);
    LChild := FModel.Tree.Nodes[LChild].NextSibling;
  end;
  LMembers := FModel.Symbols[FModel.Scopes[AMethodScope].StructSym].MemberScope;
  if (LName = NIL_NODE) or (LMembers = NIL_SCOPE) then
    Exit;
  LDecl := FModel.FindLocal(LMembers, FModel.Tree.NodeNameLower(LName));
  while LDecl <> NIL_SYM do
  begin
    LDeclRoutine := RoutineNodeOf(FModel, LDecl);
    if (LDeclRoutine <> NIL_NODE) and (LDeclRoutine <> LRoutine) and
       (FModel.Tree.Nodes[LDeclRoutine].Aux = 1) then
    begin
      LChild := FModel.Tree.Nodes[LDeclRoutine].FirstChild;
      while LChild <> NIL_NODE do
      begin
        if (FModel.Tree.Nodes[LChild].Kind = nkDirective) and
           FModel.Tree.NodeTextEquals(LChild, 'static') then
          Exit(False);
        LChild := FModel.Tree.Nodes[LChild].NextSibling;
      end;
    end;
    LDecl := FModel.Symbols[LDecl].NextOverload;
  end;
end;

end.
