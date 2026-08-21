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
  PasTree.Types,
  PasTree.Preprocessor,
  PasTree.Ast,
  PasTree.Sema.Model;

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

  { Per-model caret queries. Build one per model SNAPSHOT — the constructor
    precomputes the raw->visible map (the same shape TPasNavigator caches
    per model); a host that keeps a model across requests keeps this with
    it, and the overlay pipeline creates both fresh per request. }
  TPasCompletion = class
  private
    FModel: TPasSemaModel;
    FVisOfRaw: TArray<Integer>;   // Files[0] raw idx -> visible idx | -1
    function RawTokenAt(AOffset: Integer): Integer;
    function PrevVisibleRaw(ARaw: Integer): Integer;
    function LeftmostVis(ANode: Integer): Integer;
    function InnermostNodeAt(AVis: Integer): Integer;
    function MemberBaseOfDot(ADotRaw: Integer): Integer;
  public
    constructor Create(AModel: TPasSemaModel);
    { Classifies the caret at 1-based (line, col) of the model's main file.
      False = ckNone (AInfo.Kind still says so); True fills every field. A
      column past the end of its line clamps to the line end — hosts report
      such carets (SynEdit's virtual space) and they mean "at the end". }
    function CaretAt(ALine, ACol: Integer; out AInfo: TPasCaretInfo): Boolean;
    { The innermost struct type symbol whose member scope encloses AScope —
      the `Self` context: NodeScope's chain carries it both inside a struct
      DECLARATION (the sckStruct scope's own StructSym) and inside a method
      IMPLEMENTATION (stamped on the routine scope by the resolver).
      NIL_SYM outside any struct. }
    function EnclosingStructSym(AScope: Integer): Integer;
    property Model: TPasSemaModel read FModel;
  end;

implementation

{ TPasCompletion }

constructor TPasCompletion.Create(AModel: TPasSemaModel);
var
  LIdx: Integer;
begin
  inherited Create;
  FModel := AModel;
  SetLength(FVisOfRaw, Length(FModel.Tree.Source.Files[0].Tokens));
  for LIdx := 0 to High(FVisOfRaw) do
    FVisOfRaw[LIdx] := -1;
  for LIdx := 0 to High(FModel.Tree.Source.Visible) do
    if FModel.Tree.Source.Visible[LIdx].FileId = 0 then
      FVisOfRaw[FModel.Tree.Source.Visible[LIdx].TokenIndex] := LIdx;
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
