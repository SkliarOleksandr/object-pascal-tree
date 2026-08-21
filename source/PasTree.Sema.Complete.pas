unit PasTree.Sema.Complete;

{
  PasTree editor features — code completion, stage A: the caret primitive.

  Everything the completion engine will do starts with one question the
  existing navigator deliberately refuses to answer: "where does this caret
  SIT, lexically and semantically, in a buffer that is mid-keystroke?"
  TPasNavigator.IdentAt requires an exact identifier hit (the right contract
  for ctrl+click, the wrong one for typing), and nothing anywhere maps a
  position to the innermost AST NODE — NodeOfVis covers nkIdent nodes only.

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
  not errors. Main file only (FileId 0), like IdentAt — a caret inside an
  opened $I include is the same GAP navigation already has.

  Two parser facts this unit leans on (see PasTree.Parser):

  - `Foo.` always yields a LIVE nkMember node whose FirstToken is the DOT and
    whose first child is the base expression, even when the member name is
    missing — so the base of a dot-completion is FirstChild, never a text
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
                 // reserved word — a prefix being typed
    ckAfterDot,  // nearest visible token at/before the caret is a `.` and no
                 // prefix has been typed yet — member position, empty prefix
    ckFresh      // any other token precedes the caret — an empty-prefix
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
    { 1-based columns of the WHOLE anchor identifier on the caret's line —
      the range a host's completion replaces (mid-word invocation replaces
      the full word, the clangd behavior). For an empty prefix both equal
      the caret column. }
    PrefixColFrom: Integer;
    PrefixColTo: Integer;   // column AFTER the identifier's last character
    { The member-access BASE for a dot completion: the nkMember node's first
      child when the caret is after a dot (ckAfterDot), or when the ckIdent
      prefix's left visible neighbor is a dot (`Foo.Ba|`). NIL_NODE when the
      position is not a member access (including `end.` — the dot there
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
    ccExpression); // inside an expression: names in scope + expr keywords

  { Where a candidate came from — the ranking bucket (sortText prefix in the
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

  TPasComplItem = record
    Name: string;              // original spelling
    Kind: TSemaSymbolKind;     // meaningless when Bucket = cbKeyword
    Bucket: TPasComplBucket;
    Mid: Integer;              // declaring model id; -1 = the overlay model
    Sym: Integer;              // NIL_SYM for keywords/unit names
    Ctx: Integer;              // instantiation frame (project members)
    Overloads: Integer;        // same-name routines collapsed into this item
  end;

  { A type answer that may live in either space: the last-good PROJECT
    (X, a TSemaXType) or the OVERLAY being typed (OvSym, a type symbol of
    the fresh model) — or name a UNIT qualifier (UnitMid). IsTypeRef says
    the designator named the TYPE itself (class-side members) rather than
    a value of it. }
  TPasComplTypeRef = record
    X: TSemaXType;
    OvSym: Integer;
    UnitMid: Integer;
    IsTypeRef: Boolean;
  end;

  { Per-model caret queries and candidate collection. Build one per model
    SNAPSHOT — the constructor precomputes the raw->visible map (the same
    shape TPasNavigator caches per model); a host that keeps a model across
    requests keeps this with it, and the overlay pipeline creates both fresh
    per request.

    Two modes, one class: standalone (AProject = nil — the caret primitive
    and intra-model collection only) and BRIDGED (AProject + AProjectMid =
    the last-good analysis and this file's model id in it), where every name
    that leaves the overlay resolves through the project — see
    local/COMPLETION-PLAN.md §3 and the stage-B spike. }
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
    FContext: TPasComplContext;
    FCaretVis: Integer;            // block-scope positional visibility
    FClassSide: Boolean;           // member completion on a TYPE reference
    FAncestry: TArray<TPasExtRef>; // caret struct's bridged ancestor chain
    FAncestryBuilt: Boolean;
    FCaretScope: Integer;          // scope for EnsureAncestry
    function RawTokenAt(AOffset: Integer): Integer;
    function PrevVisibleRaw(ARaw: Integer): Integer;
    function LeftmostVis(ANode: Integer): Integer;
    function InnermostNodeAt(AVis: Integer): Integer;
    function MemberBaseOfDot(ADotRaw: Integer): Integer;
    // typing (mixed overlay/project space)
    function BridgeName(const AKey: string; out AMid, ASym: Integer): Boolean;
    function BridgeUnitMid(const AName: string): Integer;
    function TypeOfOverlaySym(ASym, ADepth: Integer): TPasComplTypeRef;
    function TypeOfProjectSym(AMid, ASym, ACtx, ADepth: Integer):
      TPasComplTypeRef;
    function ResolveTypeRefNode(ANode, ADepth: Integer): TPasComplTypeRef;
    function DesignatorType(ANode, ADepth: Integer): TPasComplTypeRef;
    function MemberOf(const ABase: TPasComplTypeRef; const AKey: string;
      ADepth: Integer): TPasComplTypeRef;
    function IsDescendantNode(ANode, AAncestor: Integer): Boolean;
    function UpChainKind(ANode: Integer;
      const AKinds: array of TPasNodeKind): TPasNodeKind;
    function OverlayStructDef(AOvSym: Integer): Integer;
    function OverlayHeritageRef(AOvSym, ADepth: Integer): TPasComplTypeRef;
    // collection
    procedure AddItem(const AName: string; AKind: TSemaSymbolKind;
      ABucket: TPasComplBucket; AMid, ASym, ACtx: Integer);
    procedure AddSym(AMid, ASym, ACtx: Integer; ABucket: TPasComplBucket);
    procedure AddKeywords(const AWords: array of string);
    procedure EnsureAncestry(ACaretScope: Integer);
    function MemberVisible(AMid, ASym: Integer): Boolean;
    function ClassSideMember(AModel: TPasSemaModel; ASym: Integer): Boolean;
    function RoutineNodeOf(AModel: TPasSemaModel; ASym: Integer): Integer;
    procedure CollectMembers(const ABase: TPasComplTypeRef);
    procedure CollectOverlayChain(AOvSym: Integer; AIncludeOwn: Boolean;
      ABucket: TPasComplBucket);
    procedure CollectProjectMembers(const AX: TSemaXType;
      ABucket: TPasComplBucket);
    procedure CollectScope(const AInfo: TPasCaretInfo);
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
      column past the end of its line clamps to the line end — hosts report
      such carets (SynEdit's virtual space) and they mean "at the end". }
    function CaretAt(ALine, ACol: Integer; out AInfo: TPasCaretInfo): Boolean;
    { The completion context the caret position calls for — token-first, with
      the (fresh) AST consulted to split the ambiguous tokens (`:` in a decl
      vs a case label, `of` in `array of` vs `case of`, ...). }
    function ClassifyAt(const AInfo: TPasCaretInfo): TPasComplContext;
    { The whole pipeline: caret -> context -> candidate list, deduplicated
      by name (first hit wins — buckets are enumerated in resolution
      precedence) with overloads collapsed. False only when the position
      offers nothing (ckNone). An empty list with True is a real answer
      (e.g. a dot whose base cannot be typed). }
    function CompleteAt(ALine, ACol: Integer; out AContext: TPasComplContext;
      out AItems: TArray<TPasComplItem>): Boolean;
    { The innermost struct type symbol whose member scope encloses AScope —
      the `Self` context: NodeScope's chain carries it both inside a struct
      DECLARATION (the sckStruct scope's own StructSym) and inside a method
      IMPLEMENTATION (stamped on the routine scope by the resolver).
      NIL_SYM outside any struct. }
    function EnclosingStructSym(AScope: Integer): Integer;
    property Model: TPasSemaModel read FModel;
  end;

implementation

uses
  System.SysUtils;

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
  FSeen := TDictionary<string, Integer>.Create;
  SetLength(FVisOfRaw, Length(FModel.Tree.Source.Files[0].Tokens));
  for LIdx := 0 to High(FVisOfRaw) do
    FVisOfRaw[LIdx] := -1;
  for LIdx := 0 to High(FModel.Tree.Source.Visible) do
    if FModel.Tree.Source.Visible[LIdx].FileId = 0 then
      FVisOfRaw[FModel.Tree.Source.Visible[LIdx].TokenIndex] := LIdx;
end;

destructor TPasCompletion.Destroy;
begin
  FSeen.Free;
  inherited;
end;

// The raw token of Files[0] covering AOffset (Start <= AOffset < EndPos), or
// -1. Tokens are gapless and sorted by Start — same search IdentAt/VisAt use.
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

// Nearest raw token at or before ARaw that has a visible mapping (skips
// trivia backward — a caret in trailing whitespace still belongs to whatever
// came before it, the same reading VisAt established). -1 when nothing
// visible precedes.
function TPasCompletion.PrevVisibleRaw(ARaw: Integer): Integer;
begin
  Result := ARaw;
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
// index order is not source order) — but child spans are source-ordered
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
      LFirst := LeftmostVis(LChild);
      if (LFirst >= 0) and (LFirst <= AVis) and
         (AVis <= FModel.Tree.Nodes[LChild].LastToken) then
      begin
        Result := LChild;
        LFound := True;
        Break;
      end;
      LChild := FModel.Tree.Nodes[LChild].NextSibling;
    end;
  until not LFound;
end;

// The member-access base for the dot at raw index ADotRaw: the innermost node
// containing the dot is the nkMember that OWNS it (the dot is inside no
// child's span — the base ends before it, the name starts after it), and the
// base is that node's first child. NIL_NODE when the dot belongs to no member
// access (`end.`, a float's dot never gets here — `1.5` is one raw token).
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
  LOffset, LLineEnd, LAnchorOff: Integer;
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
  if (ALine < 1) or (ALine - 1 > High(LTS.LineStarts)) or (ACol < 1) then
    Exit;
  LOffset := LTS.LineStarts[ALine - 1] + (ACol - 1);
  // Clamp a caret past the end of its line to the line end (before the line
  // break, when there is one — landing ON the break is fine too, the trivia
  // walk-back below reads both the same way).
  if ALine - 1 < High(LTS.LineStarts) then
    LLineEnd := LTS.LineStarts[ALine]
  else
    LLineEnd := Length(LTS.Source);
  if LOffset > LLineEnd then
    LOffset := LLineEnd;

  // Everything below reasons about the character position just LEFT of the
  // caret — that is where the text being completed attaches. A caret at the
  // very start of the file has nothing to attach to.
  if LOffset = 0 then
    Exit;
  LAnchorOff := LOffset - 1;

  // Dead code: a position inside a Skipped ($IFDEF'd-out) region has no
  // visible mapping at all, and walking backward from it would cross the
  // entire inactive region onto unrelated active code — refuse outright,
  // exactly as VisAt does for navigation.
  if FModel.Tree.Source.IsSkipped(0, LAnchorOff) then
    Exit;

  LRaw := RawTokenAt(LAnchorOff);
  if LRaw < 0 then
    Exit;
  LKind := LTS.Tokens[LRaw].Kind;

  // A prefix being typed: the caret sits inside (or at the right edge of) an
  // identifier or reserved word. Reserved words count — `begi|n` and a
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
      // (trivia is never a word; dead regions were refused above) — treat a
      // future exception as "no completion" rather than guessing a scope.
      AInfo.Kind := ckNone;
      Exit;
    end;
    AInfo.Prefix := Copy(LTS.Source, LTok.Start + 1, LOffset - LTok.Start);
    LTS.OffsetToLineCol(LTok.Start, LLine, AInfo.PrefixColFrom);
    AInfo.PrefixColTo := AInfo.PrefixColFrom + LTok.Len;
    // `Foo.Ba|` — the prefix continues a member access when its left visible
    // neighbor is a dot.
    LPrevRaw := PrevVisibleRaw(LRaw - 1);
    if (LPrevRaw >= 0) and (LTS.Tokens[LPrevRaw].Kind = tkDot) then
      AInfo.DotBase := MemberBaseOfDot(LPrevRaw);
  end
  // Strictly INSIDE a literal, comment, directive or asm text: no completion
  // (matches the IDE). Whitespace interior falls through instead — that is
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
  project — the resolution order mirrored is CrossResolve's (uses last-wins,
  then System/SysInit, then the compiler seeds). Everything project-side is
  a TSemaXType, so FindMemberX/EnumMembersX/SubstX apply unchanged. }

function ComplNilRef: TPasComplTypeRef;
begin
  Result.X := XNil;
  Result.OvSym := NIL_SYM;
  Result.UnitMid := -1;
  Result.IsTypeRef := False;
end;

function ComplValid(const ARef: TPasComplTypeRef): Boolean;
begin
  Result := XValid(ARef.X) or (ARef.OvSym <> NIL_SYM) or (ARef.UnitMid >= 0);
end;

// Resolve AKey as if written in this unit but NOT declared in it: the
// project-side half of unqualified resolution. Real declarations first
// (uses, last-wins, then the implicit System unit), then the compiler seeds
// of this file's own project model — the same effective order the analysis
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
  LM := FProj.Model(FProjMid);
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
// form (`Generics.Collections` -> System.Generics.Collections.pas) — good
// enough for names the project has ALREADY loaded, which is the only kind a
// bridge can answer anyway.
function TPasCompletion.BridgeUnitMid(const AName: string): Integer;
var
  LIdx: Integer;
  LBase: string;
begin
  Result := -1;
  if (FProj = nil) or (AName = '') then
    Exit;
  for LIdx := 0 to FProj.ModelCount - 1 do
  begin
    LBase := ChangeFileExt(ExtractFileName(FProj.ModelFile(LIdx)), '');
    if SameText(LBase, AName) then
      Exit(LIdx);
    if (Result < 0) and (Length(LBase) > Length(AName) + 1) and
       SameText(Copy(LBase, Length(LBase) - Length(AName), Length(AName) + 1),
         '.' + AName) then
      Result := LIdx;   // namespace-prefixed candidate; exact still preferred
  end;
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
        if FModel.Symbols[ASym].TypeNode <> NIL_NODE then
        begin
          Result := ResolveTypeRefNode(FModel.Symbols[ASym].TypeNode,
            ADepth + 1);
          Result.IsTypeRef := False;
        end
        else
        begin
          // `var X := expr` — an inline var with an inferred type: the
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
  LM := FProj.Model(AMid);
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
        if LSym <> NIL_SYM then
          Exit(TypeOfOverlaySym(LSym, ADepth + 1));
        LKey := FModel.Tree.NodeNameLower(ANode);
        if BridgeName(LKey, LMid, LSym) and
           (FProj.Model(LMid).Symbols[LSym].Kind in [skType, skBuiltinType])
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
        // space (an overlay type as an argument has no project identity yet);
        // otherwise fall back to the open generic — members still complete,
        // parameter types stay open.
        LArgs := nil;
        LAllProject := True;
        LChild := FModel.Tree.Nodes[LChild].NextSibling;
        while LChild <> NIL_NODE do
        begin
          LArg := ResolveTypeRefNode(LChild, ADepth + 1);
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
        // deref — resolve to the pointee directly (the same hop FindMemberX
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

// The type of an EXPRESSION (designator) node of the overlay — what a dot
// after it completes on.
function TPasCompletion.DesignatorType(ANode, ADepth: Integer):
  TPasComplTypeRef;
var
  LSym, LMid, LChild, LScope, LNode: Integer;
  LKey: string;
  LCallee: TPasComplTypeRef;
  LRes: TSemaXType;
begin
  Result := ComplNilRef;
  if (ANode = NIL_NODE) or (ADepth > 16) then
    Exit;
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
        // `Self` has no symbol anywhere (11.3.3) — answered structurally,
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
        if BridgeName(LKey, LMid, LSym) then
          Exit(TypeOfProjectSym(LMid, LSym, NIL_INST, ADepth + 1));
        Result.UnitMid := BridgeUnitMid(FModel.Tree.NodeText(ANode));
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
          // A cast — T(expr) — or a value-typed use of a constructor's
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
        Result := DesignatorType(FModel.Tree.Nodes[ANode].FirstChild,
          ADepth + 1);
        if XValid(Result.X) and (FProj <> nil) then
          Result.X := FProj.PointeeX(Result.X)
        else
          Result := ComplNilRef;   // overlay-space pointee: v2
      end;
  end;
end;

// One member hop by NAME, for typing intermediate designator segments
// (`A.B.` needs typeof(A.B), which needs member B of typeof(A)).
function TPasCompletion.MemberOf(const ABase: TPasComplTypeRef;
  const AKey: string; ADepth: Integer): TPasComplTypeRef;
var
  LM: TPasSemaModel;
  LSym, LScope, LMemMid, LMemSym, LCtx, LHop, LRoutine: Integer;
  LCur, LHeritage: TPasComplTypeRef;
begin
  Result := ComplNilRef;
  if (ADepth > 16) or (AKey = '') then
    Exit;
  if ABase.UnitMid >= 0 then
  begin
    if FProj = nil then
      Exit;
    LM := FProj.Model(ABase.UnitMid);
    if LM.InterfaceScope = NIL_SCOPE then
      Exit;
    LSym := LM.Resolve(LM.InterfaceScope, AKey);
    if LSym <> NIL_SYM then
      Result := TypeOfProjectSym(ABase.UnitMid, LSym, NIL_INST, ADepth + 1);
    Exit;
  end;
  LCur := ABase;
  // Overlay hops: the base type (and possibly its overlay-declared
  // ancestors) live in the buffer; the first hop that leaves it falls
  // through to the project branch below.
  for LHop := 1 to 16 do
  begin
    if LCur.OvSym = NIL_SYM then
      Break;
    LScope := FModel.Symbols[LCur.OvSym].MemberScope;
    if LScope <> NIL_SCOPE then
    begin
      LSym := FModel.FindLocalDeep(LScope, AKey);
      if LSym <> NIL_SYM then
      begin
        // A constructor names the CONSTRUCTED type: T.Create is a T value.
        LRoutine := RoutineNodeOf(FModel, LSym);
        if (LRoutine <> NIL_NODE) and
           FModel.Tree.Source.VisibleTextEquals(
             FModel.Tree.Nodes[LRoutine].FirstToken, 'constructor') then
        begin
          Result := ABase;
          Result.IsTypeRef := False;
          Exit;
        end;
        Result := TypeOfOverlaySym(LSym, ADepth + 1);
        Exit;
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
  begin
    if FProj.FindMemberX(FProjMid, LCur.X, AKey, LMemMid, LMemSym, LCtx) then
    begin
      if FProj.IsConstructorSym(LMemMid, LMemSym) then
      begin
        Result := LCur;
        Result.IsTypeRef := False;
        Exit;
      end;
      Result := TypeOfProjectSym(LMemMid, LMemSym, LCtx, ADepth + 1);
    end;
  end;
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
  Result := FModel.Tree.Nodes[LDecl].FirstChild;
  if Result = NIL_NODE then
    Exit;
  while FModel.Tree.Nodes[Result].NextSibling <> NIL_NODE do
    Result := FModel.Tree.Nodes[Result].NextSibling;
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
  end;
end;

{ ---- collection ----------------------------------------------------------- }

procedure TPasCompletion.AddItem(const AName: string; AKind: TSemaSymbolKind;
  ABucket: TPasComplBucket; AMid, ASym, ACtx: Integer);
var
  LKey: string;
  LIdx: Integer;
begin
  if AName = '' then
    Exit;
  LKey := PasNameKey(AName);
  if FSeen.TryGetValue(LKey, LIdx) then
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
  FSeen.Add(LKey, FCount);
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
    LM := FProj.Model(AMid);
  if LM.Symbols[ASym].Kind = skLabel then
    Exit;   // labels complete after `goto` only (stage E)
  // Type positions take only what can name a type.
  if (FContext = ccType) and not (LM.Symbols[ASym].Kind in
    [skType, skBuiltinType, skUnitRef, skGenericParam]) then
    Exit;
  AddItem(LM.Symbols[ASym].Name, LM.Symbols[ASym].Kind, ABucket, AMid, ASym,
    ACtx);
end;

procedure TPasCompletion.AddKeywords(const AWords: array of string);
var
  LIdx: Integer;
begin
  for LIdx := 0 to High(AWords) do
    AddItem(AWords[LIdx], skType, cbKeyword, -1, NIL_SYM, NIL_INST);
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
// nested types, consts and enum values. KNOWN GAP: `class var` fields carry
// no marker the model exposes yet, so they are hidden class-side.
function TPasCompletion.ClassSideMember(AModel: TPasSemaModel;
  ASym: Integer): Boolean;
var
  LNode: Integer;
begin
  case AModel.Symbols[ASym].Kind of
    skType, skConst, skEnumValue:
      Result := True;
    skRoutine:
      begin
        LNode := RoutineNodeOf(AModel, ASym);
        Result := (LNode <> NIL_NODE) and
          ((AModel.Tree.Nodes[LNode].Aux = 1) and
             not AModel.Tree.Source.VisibleTextEquals(
               AModel.Tree.Nodes[LNode].FirstToken, 'destructor') or
           AModel.Tree.Source.VisibleTextEquals(
             AModel.Tree.Nodes[LNode].FirstToken, 'constructor'));
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
// test — built once per request, only when a member list needs it.
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
  LOv := EnclosingStructSym(ACaretScope);
  if LOv = NIL_SYM then
    Exit;
  for LDepth := 1 to 16 do
  begin
    LRef := OverlayHeritageRef(LOv, 0);
    if LRef.OvSym <> NIL_SYM then
    begin
      LOv := LRef.OvSym;
      Continue;
    end;
    LX := LRef.X;
    Break;
  end;
  if FProj = nil then
    Exit;
  for LDepth := 1 to 32 do
  begin
    if not XValid(LX) then
      Exit;
    LEntry.UnitId := LX.UnitId;
    LEntry.Sym := LX.Sym;
    FAncestry := FAncestry + [LEntry];
    LX := FProj.AncestorOfX(LX);
  end;
end;

// Visibility of a PROJECT member from this caret (11 §11.2.1): private is
// same-unit-friendly, protected needs the caret's struct to descend from the
// declaring one (non-strict protected is also same-unit-friendly), strict
// variants drop the friend rule. svDefault means "no section stated" and
// stays visible — hiding on a guess is the wrong failure mode for a list.
function TPasCompletion.MemberVisible(AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
  LDeclStruct, LIdx: Integer;
begin
  LM := FProj.Model(AMid);
  case LM.Symbols[ASym].Visibility of
    svStrictPrivate:
      Result := False;
    svPrivate:
      Result := AMid = FProjMid;
    svProtected, svStrictProtected:
      begin
        Result := (LM.Symbols[ASym].Visibility = svProtected) and
          (AMid = FProjMid);
        if Result then
          Exit;
        if LM.Symbols[ASym].Scope = NIL_SCOPE then
          Exit(True);
        LDeclStruct := LM.Scopes[LM.Symbols[ASym].Scope].StructSym;
        if LDeclStruct = NIL_SYM then
          Exit(True);
        for LIdx := 0 to High(FAncestry) do
          if (FAncestry[LIdx].UnitId = AMid) and
             (FAncestry[LIdx].Sym = LDeclStruct) then
            Exit(True);
        Result := False;
      end;
  else
    Result := True;
  end;
end;

procedure TPasCompletion.CollectProjectMembers(const AX: TSemaXType;
  ABucket: TPasComplBucket);
begin
  if (FProj = nil) or not XValid(AX) then
    Exit;
  FProj.EnumMembersX(FProjMid, AX,
    procedure(AMid, ASym, ACtx: Integer)
    begin
      if MemberVisible(AMid, ASym) and
         (not FClassSide or ClassSideMember(FProj.Model(AMid), ASym)) then
        AddSym(AMid, ASym, ACtx, ABucket);
    end);
end;

// Members of an OVERLAY-declared type: its own scope (deep — nested enums
// and intra-unit joins included), then each overlay ancestor's, then the
// first hop that leaves the buffer continues in project space.
// AIncludeOwn = False skips the FIRST scope — the caller already enumerated
// it through the caret's scope chain (a method body's joined member scope).
procedure TPasCompletion.CollectOverlayChain(AOvSym: Integer;
  AIncludeOwn: Boolean; ABucket: TPasComplBucket);
var
  LDepth, LScope: Integer;
  LRef: TPasComplTypeRef;
  LInclude: Boolean;
begin
  LInclude := AIncludeOwn;
  for LDepth := 1 to 16 do
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
            // Class constructors/destructors are never nameable.
            LNode := RoutineNodeOf(FModel, ASym);
            if (LNode <> NIL_NODE) and
               (FModel.Tree.Nodes[LNode].Aux = 1) and
               (FModel.Tree.Source.VisibleTextEquals(
                  FModel.Tree.Nodes[LNode].FirstToken, 'constructor') or
                FModel.Tree.Source.VisibleTextEquals(
                  FModel.Tree.Nodes[LNode].FirstToken, 'destructor')) then
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
end;

procedure TPasCompletion.CollectUnitInterface(AUid: Integer;
  ABucket: TPasComplBucket);
var
  LM: TPasSemaModel;
  LScope, LIdx, LSym: Integer;
begin
  if (FProj = nil) or (AUid < 0) then
    Exit;
  LM := FProj.Model(AUid);
  LScope := LM.InterfaceScope;
  if (LScope = NIL_SCOPE) or (LM.Scopes[LScope].Symbols = nil) then
    Exit;
  // OWN symbols only — the interface scope's Additional joins hold that
  // unit's builtin seeds (and its own uses' unit refs are not importable
  // names either, so skUnitRef is skipped).
  for LIdx := 0 to LM.Scopes[LScope].Symbols.Count - 1 do
  begin
    LSym := LM.Scopes[LScope].Symbols[LIdx];
    if LM.Symbols[LSym].Kind <> skUnitRef then
      AddSym(AUid, LSym, NIL_INST, ABucket);
  end;
end;

procedure TPasCompletion.CollectMembers(const ABase: TPasComplTypeRef);
begin
  if ABase.UnitMid >= 0 then
    CollectUnitInterface(ABase.UnitMid, cbMember)
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
// PROJECT model of this same file — its UsesList already carries resolved
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
            AnsiLowerCase(FModel.UsesList[LJdx].NameFull), True);
    end;
    PM := FProj.Model(FProjMid);
    for LIdx := High(PM.UsesList) downto 0 do
    begin
      LUid := PM.UsesList[LIdx].UnitId;
      if LUid < 0 then
        Continue;
      if LAllowed <> nil then
      begin
        LOk := LAllowed.ContainsKey(AnsiLowerCase(PM.UsesList[LIdx].NameFull));
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
  LScope, LIdx, LTarget, LBody, LOv: Integer;
  LInterfaceOnly: Boolean;
  LRef: TPasComplTypeRef;
begin
  FCaretVis := AInfo.VisToken;
  // 1. Enclosing UNOPENED with statements (cross-unit targets, ch.05 §5.7):
  // their members shadow everything, so they go first. Opened (intra-unit)
  // withs are ordinary sckWith scopes and come through the chain below.
  for LIdx := 0 to High(FModel.WithUnopened) do
  begin
    LBody := FModel.Tree.Nodes[FModel.WithUnopened[LIdx]].FirstChild;
    if LBody = NIL_NODE then
      Continue;
    while FModel.Tree.Nodes[LBody].NextSibling <> NIL_NODE do
      LBody := FModel.Tree.Nodes[LBody].NextSibling;
    if not IsDescendantNode(AInfo.Node, LBody) then
      Continue;
    LTarget := FModel.Tree.Nodes[FModel.WithUnopened[LIdx]].FirstChild;
    while (LTarget <> NIL_NODE) and (LTarget <> LBody) do
    begin
      LRef := DesignatorType(LTarget, 0);
      LRef.IsTypeRef := False;
      if ComplValid(LRef) then
      begin
        FClassSide := False;
        CollectMembers(LRef);
      end;
      LTarget := FModel.Tree.Nodes[LTarget].NextSibling;
    end;
  end;
  FClassSide := False;
  // 2. The lexical scope chain, deep (joined scopes included) — this is
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
        // (3.1.3) — the same positional rule ResolveAt applies.
        if (FModel.Scopes[AScopeOfSym].Kind = sckBlock) and
           FModel.DeclaredAfter(ASym, FCaretVis) then
          Exit;
        AddSym(-1, ASym, NIL_INST, LBucket);
      end);
    LScope := FModel.Scopes[LScope].Parent;
  end;
  // 3. INHERITED members of the enclosing struct — the chain join only
  // carries the struct's own scope; ancestors (overlay-declared and then
  // cross-unit) are walked explicitly. Skips the first scope: step 2 had it.
  LOv := EnclosingStructSym(AInfo.Scope);
  if LOv <> NIL_SYM then
    CollectOverlayChain(LOv, False, cbStructMember);
  // 4. Cross-unit names: uses (reverse, last-wins), System, SysInit.
  CollectUsesImports(LInterfaceOnly);
  // 5. Compiler seeds, last — every real declaration outranks a seed.
  if FModel.SystemScope <> NIL_SCOPE then
    FModel.EnumScopeDeep(FModel.SystemScope,
      procedure(ASym, AScopeOfSym: Integer)
      begin
        AddSym(-1, ASym, NIL_INST, cbBuiltin);
      end);
end;

// Uses-clause candidates: the units the last-good project knows about.
// (A search-path directory scan is a stage-E refinement; the analyzed
// closure is what navigation can already reach.)
procedure TPasCompletion.CollectUnitNames;
var
  LIdx: Integer;
begin
  if FProj = nil then
    Exit;
  for LIdx := 0 to FProj.ModelCount - 1 do
    if LIdx <> FProjMid then
      AddItem(ChangeFileExt(ExtractFileName(FProj.ModelFile(LIdx)), ''),
        skUnitRef, cbUnitName, LIdx, NIL_SYM, NIL_INST);
end;

// The innermost node of the given kinds on ANode's parent chain, stopping at
// statement/section boundaries — the disambiguator for `:`/`=`/`of`/`(`.
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
  // A uses clause first: any position inside one is a unit-name position —
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
  if (AInfo.DotBase <> NIL_NODE) or (AInfo.Kind = ckAfterDot) then
    Exit(ccMember);
  // The significant token LEFT of the (possibly empty) prefix decides.
  if AInfo.Kind = ckIdent then
    LPrev := PrevVisibleRaw(AInfo.RawToken - 1)
  else
    LPrev := AInfo.RawToken;
  if LPrev < 0 then
    Exit(ccStatement);
  LKind := LTS.Tokens[LPrev].Kind;
  case LKind of
    tkColon:
      // `x: |` is a TYPE in a declaration, a STATEMENT after a case label
      // or a goto label.
      if UpChainKind(AInfo.Node, [nkCaseSel, nkCaseLabels, nkLabeledStmt])
        <> nkError then
        Result := ccStatement
      else
        Result := ccType;
    tkEqual:
      if UpChainKind(AInfo.Node, [nkTypeDecl]) = nkTypeDecl then
        Result := ccType
      else
        Result := ccExpression;
    tkIs, tkAs:
      Result := ccType;
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
      // `TList<|` — inside a generic argument/parameter list.
      Result := ccType;
    tkSemicolon, tkBegin, tkThen, tkElse, tkDo, tkRepeat, tkTry, tkFinally,
    tkExcept, tkEnd:
      Result := ccStatement;
  else
    // A reserved word (interface/implementation/var/type/...) opens a
    // declaration head; anything else — an operator, `:=`, a bracket, a
    // literal — sits inside an expression.
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
  UNIT_WORDS: array[0..14 ] of string = ('type', 'var', 'const', 'uses',
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
  LInfo: TPasCaretInfo;
  LRef: TPasComplTypeRef;
begin
  AContext := ccNone;
  AItems := nil;
  Result := CaretAt(ALine, ACol, LInfo);
  if not Result then
    Exit;
  FContext := ClassifyAt(LInfo);
  AContext := FContext;
  FItems := nil;
  FCount := 0;
  FSeen.Clear;
  FAncestryBuilt := False;
  FClassSide := False;
  FCaretScope := LInfo.Scope;
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
          EnsureAncestry(LInfo.Scope);
          CollectMembers(LRef);
        end;
      end;
    ccUses:
      CollectUnitNames;
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
