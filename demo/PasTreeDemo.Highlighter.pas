unit PasTreeDemo.Highlighter;

{
  PasTree demo — a TSynEdit syntax highlighter driven directly by PasTree's
  own lexer (PasTree.Lexer.TPasLexer), instead of SynEdit's built-in
  hand-rolled Pascal scanner (TSynPasSyn). Its purpose is to be a live
  correctness visualizer for the lexer: every color you see on screen comes
  straight from a TPasTokenKind the lexer assigned, so a wrong color is a
  lexer bug, not a highlighter quirk.

  Design — whole-buffer re-tokenize, not incremental:
  TSynCustomHighlighter's contract is inherently line-based (SetLine one line
  at a time, with a Range pointer meant to carry state across lines for
  resumable incremental scanning). PasTree's lexer has no such per-line API —
  TPasLexer.Tokenize consumes the whole source in one shot. Rather than build
  a second, parallel incremental lexer, this highlighter re-tokenizes the
  ENTIRE current buffer (via the attached SourceLines) whenever the cached
  copy goes stale (a single string comparison per SetLine call — the actual
  TPasLexer.Tokenize call only fires once per real edit), then answers each
  line by locating the token(s) that overlap it in the cached, contiguous,
  full-fidelity token array (binary search by offset) and clipping their span
  to the current line. A token that spans multiple lines (a block comment, a
  triple-quoted string) is simply re-located and re-clipped on each line it
  touches — no Range/GetRange/SetRange state is needed at all, which also
  means there is no incremental-state bug class to worry about: every line is
  always answered from a fully fresh, whole-buffer-consistent tokenization.

  Scope: mostly lexical (TPasLexer output drives every color), but weak
  keywords (below) are resolved with real POSITION information from the full
  pipeline (TPasPreprocessor + TPasParser), not just a flat word list.
  $IFDEF'd-out (not-compiled-under-current-defines) regions ARE greyed out —
  a single flat PAS_INACTIVE_COLOR overriding every other color uniformly,
  same as real Delphi IDE — via TPasPreprocessed.Skipped (see MarkInactiveTokens).

  One deliberate, clearly-scoped exception to "raw lexer output only": true
  reserved words (spec B.4.1 — begin/end/if/class/...) get their Keyword color
  straight from TPasTokenKind, no list needed — that part IS the lexer talking.
  But Object Pascal's "weak keywords" (private/override/virtual/stdcall/...,
  spec B.4.2) are, by design, plain tkIdentifier at the lexer level — the
  language only gives them meaning by *position* (`var dynamic: Integer;` is a
  perfectly legal variable named `dynamic`). A flat word-list can't tell that
  apart from `procedure Foo; dynamic;` — both are just an identifier token
  spelled "dynamic". Precision needs the PARSER, which already builds
  dedicated AST nodes for every position where a directive/visibility/
  property-specifier word actually means something: nkVisibility, nkDirective,
  nkPropSpec (PasTree.Ast). So EnsureFresh now runs the real pipeline
  (TPasPreprocessor.ProcessText -> TPasParser.ParseFile) in addition to the
  lexer, and BuildWeakKeywordSpans walks the resulting TPasTree once, marking
  exactly the "bare word" token(s) of each such node (a node's own span MINUS
  its adopted child spans — the child is the getter/setter/arg expression,
  which must stay Identifier-colored, e.g. `read` colors but `GetFoo` in
  `read GetFoo` doesn't). This is precise: `var dynamic: Integer;` no longer
  lights up, because the parser never builds an nkDirective there at all.
  Fallback: preprocessing/parsing a buffer mid-keystroke can hit an
  intermediate state the parser doesn't handle gracefully (belt-and-suspenders
  — PasTree's parser is error-tolerant by design and this hasn't been observed
  in practice); if EITHER step raises, IsWeakKeyword falls back to the OLD flat
  PasTree.Types.DIRECTIVE_WORDS + VISIBILITY_WORDS word-list check for that
  pass, so the highlighter never goes blank or crashes — it just loses
  precision for one re-tokenize cycle. Either way, this whole mechanism stays a
  cosmetic overlay on top of the identifier token, not a lexer reclassification
  — unlike every other color in this highlighter, which IS a lexer-correctness
  signal straight from TPasTokenKind.

  Demo-only: lives in demo/, not source/, and is created purely at runtime —
  no `Register` procedure, no design-time package.
}

interface

uses
  System.Classes,
  System.SysUtils,
  System.Generics.Collections,
  Vcl.Graphics,
  SynFunc,
  SynEditTypes,
  SynEditHighlighter,
  PasTree.Types,
  PasTree.Lexer,
  PasTree.SourceManager,
  PasTree.Preprocessor,
  PasTree.Ast,
  PasTree.Parser,
  PasTree.Platforms;

const
  { The palette below, named so it can be reused verbatim to re-color
    SynEdit's own TSynPasSyn (see PasTreeDemo.Main.SetupControls) — makes an
    apples-to-apples comparison between the two highlighters about
    RECOGNITION, not incidental color-scheme differences. }
  PAS_KEYWORD_COLOR = clNavy;
  PAS_KEYWORD_STYLE = [fsBold];
  PAS_COMMENT_COLOR = clGreen;
  PAS_COMMENT_STYLE = [fsItalic];
  PAS_DIRECTIVE_COLOR = clOlive;
  PAS_DIRECTIVE_STYLE = [fsItalic, fsBold];
  PAS_STRING_COLOR = clMaroon;
  PAS_NUMBER_COLOR = clPurple;
  PAS_ASM_BACKGROUND = clInfoBk;
  { $IFDEF'd-out (not compiled under the current defines) source — a flat,
    unstyled grey, deliberately overriding every OTHER color uniformly (a
    keyword or a string inside dead code is still just dead code, same as
    real Delphi IDE behavior: the whole excluded block goes one flat shade,
    not a de-saturated version of each token's usual color). }
  PAS_INACTIVE_COLOR = clGrayText;

type
  TPasTreeSynHighlighter = class(TSynCustomHighlighter)
  private
    FSourceLines: TStrings;        // attached editor buffer (not owned)
    FCachedSource: string;         // last text actually tokenized
    FCachedLineCount: Integer;     // FSourceLines.Count as of FCachedSource
    FDirty: Boolean;               // True: EnsureFresh must re-check on next call
    FTokenStream: TPasTokenStream;
    FTokenCount: Integer;
    FLineStartAbs: Integer;        // absolute offset of the current line
    FCurTokenIdx: Integer;         // index into FTokenStream.Tokens
    FCurTokenAbsIdx: Integer;      // raw token index of the token last reported by Next
    FCurKind: TPasTokenKind;       // kind of the token last reported by Next
    FCurUnterminated: Boolean;     // tfUnterminated on that token
    FSourceManager: TPasSourceManager; // no search paths — single in-memory buffer
    FDefines: TPasDefines;         // Win32 platform preset (see EnsureFresh)
    FPreprocessor: TPasPreprocessor;   // reused across EnsureFresh calls
    FHaveAst: Boolean;             // True when FWeakKeywordToken is AST-precise
    FWeakKeywordToken: TArray<Boolean>; // AST-precise, indexed by raw token idx
    FInactiveToken: TArray<Boolean>; // True: raw token lies in a skipped $IFDEF region
    FWhitespaceAttri: TSynHighlighterAttributes;
    FCommentAttri: TSynHighlighterAttributes;
    FDirectiveAttri: TSynHighlighterAttributes;
    FIdentifierAttri: TSynHighlighterAttributes;
    FKeywordAttri: TSynHighlighterAttributes;
    FNumberAttri: TSynHighlighterAttributes;
    FStringAttri: TSynHighlighterAttributes;
    FSymbolAttri: TSynHighlighterAttributes;
    FAsmAttri: TSynHighlighterAttributes;
    FErrorAttri: TSynHighlighterAttributes;
    FWeakKeywords: TDictionary<string, Boolean>; // DIRECTIVE_WORDS + VISIBILITY_WORDS
    FLinkAttri: TSynHighlighterAttributes;
    FLinkFrom: Integer;            // raw token idx range shown as a
    FLinkTo: Integer;              // ctrl+hover link (inclusive); -1 = none
    FInactiveAttri: TSynHighlighterAttributes;
    function IsWeakKeyword: Boolean;
    procedure BuildWeakKeywordSpans(const ATree: TPasTree;
      const APreprocessed: TPasPreprocessed);
    procedure MarkInactiveTokens(const ASkipped: TArray<TPasSkippedRegion>);
    procedure EnsureFresh;
    function LineStartOffset(ALineNumber: Integer): Integer;
    function LocateStartToken(AOffset: Integer): Integer;
    procedure SetSourceLines(const Value: TStrings);
  protected
    function GetDefaultAttribute(Index: Integer): TSynHighlighterAttributes;
      override;
    procedure DoSetLine(const Value: string; LineNumber: TSynNativeInt);
      override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    class function GetLanguageName: string; override;
    class function GetFriendlyLanguageName: string; override;
    function GetEol: Boolean; override;
    function GetTokenKind: TSynNativeInt; override;
    function GetTokenAttribute: TSynHighlighterAttributes; override;
    procedure Next; override;
    { The TStrings this highlighter re-tokenizes on demand (typically the
      TSynEdit.Lines it is attached to). Not owned/freed by this class. }
    property SourceLines: TStrings read FSourceLines write SetSourceLines;
    { Tells EnsureFresh the attached buffer may have changed since its last
      real check — call this from the HOST's edit notification (e.g. the
      owning TSynEdit's OnChange). See EnsureFresh's header comment for why
      this exists: without it, EnsureFresh's own change-detection is not
      cheap enough to call on every SetLine/repaint for a large file. }
    procedure MarkDirty;
    { Raw token index RANGE (inclusive, into this buffer's token stream)
      rendered as a clickable go-to-declaration link (blue + underline) —
      IDE-style ctrl+hover. A plain identifier is a single-token range; a
      `uses` clause's dotted unit name (e.g. System.SysUtils) is a multi-
      token range covering every segment + dot, so hovering ANY part of it
      links and underlines the WHOLE qualified name, not just one word.
      AFrom = -1 clears the link. The HOST invalidates the editor on change. }
    procedure SetLinkRange(AFrom, ATo: Integer);
    function LinkRangeEquals(AFrom, ATo: Integer): Boolean;
    { Diagnostics from the last tokenize pass (unterminated string/comment/
      directive, invalid char, ...) — handy for a future "N issues" readout. }
    function LexerDiagnosticCount: Integer;
  end;

implementation

{ TPasTreeSynHighlighter }

constructor TPasTreeSynHighlighter.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  // We bypass the base class's own char-by-char scanning entirely (Next is
  // fully overridden), so its case-folding machinery is just unused overhead
  // — but leaving it case-sensitive keeps GetToken returning the original,
  // un-lowercased source text.
  fCaseSensitive := True;
  fDefaultFilter := 'Pascal Files (*.pas;*.dpr;*.dpk;*.inc)|*.pas;*.dpr;*.dpk;*.inc';

  FWhitespaceAttri := TSynHighlighterAttributes.Create('Whitespace', 'Whitespace');
  AddAttribute(FWhitespaceAttri);

  FCommentAttri := TSynHighlighterAttributes.Create('Comment', 'Comment');
  FCommentAttri.Foreground := PAS_COMMENT_COLOR;
  FCommentAttri.Style := PAS_COMMENT_STYLE;
  AddAttribute(FCommentAttri);

  FDirectiveAttri := TSynHighlighterAttributes.Create('Directive', 'Compiler directive');
  FDirectiveAttri.Foreground := PAS_DIRECTIVE_COLOR;
  FDirectiveAttri.Style := PAS_DIRECTIVE_STYLE;
  AddAttribute(FDirectiveAttri);

  FIdentifierAttri := TSynHighlighterAttributes.Create('Identifier', 'Identifier');
  AddAttribute(FIdentifierAttri);

  FKeywordAttri := TSynHighlighterAttributes.Create('Keyword', 'Reserved word');
  FKeywordAttri.Foreground := PAS_KEYWORD_COLOR;
  FKeywordAttri.Style := PAS_KEYWORD_STYLE;
  AddAttribute(FKeywordAttri);

  FNumberAttri := TSynHighlighterAttributes.Create('Number', 'Number literal');
  FNumberAttri.Foreground := PAS_NUMBER_COLOR;
  AddAttribute(FNumberAttri);

  FStringAttri := TSynHighlighterAttributes.Create('String', 'String literal');
  FStringAttri.Foreground := PAS_STRING_COLOR;
  AddAttribute(FStringAttri);

  FSymbolAttri := TSynHighlighterAttributes.Create('Symbol', 'Punctuation/operator');
  AddAttribute(FSymbolAttri);

  FAsmAttri := TSynHighlighterAttributes.Create('Asm', 'Opaque BASM chunk');
  FAsmAttri.Background := PAS_ASM_BACKGROUND;
  AddAttribute(FAsmAttri);

  FErrorAttri := TSynHighlighterAttributes.Create('Error', 'Invalid / unterminated');
  FErrorAttri.Foreground := clRed;
  FErrorAttri.Style := [fsBold, fsUnderline];
  AddAttribute(FErrorAttri);

  FLinkAttri := TSynHighlighterAttributes.Create('Link', 'Ctrl+hover link');
  FLinkAttri.Foreground := clBlue;
  FLinkAttri.Style := [fsUnderline];
  AddAttribute(FLinkAttri);
  FLinkFrom := -1;
  FLinkTo := -1;

  FInactiveAttri := TSynHighlighterAttributes.Create('Inactive',
    'Inactive $IFDEF''d-out code');
  FInactiveAttri.Foreground := PAS_INACTIVE_COLOR;
  AddAttribute(FInactiveAttri);

  SetAttributesOnChange(DefHighlightChange);

  FWeakKeywords := TDictionary<string, Boolean>.Create;
  for var LWord in PasTree.Types.DIRECTIVE_WORDS do
    FWeakKeywords.AddOrSetValue(LWord, True);
  for var LWord in PasTree.Types.VISIBILITY_WORDS do
    FWeakKeywords.AddOrSetValue(LWord, True);

  // Full pipeline for AST-precise weak-keyword spans (see unit header). No
  // search paths: a single in-memory editor buffer has no project context, so
  // $I includes and unit resolution simply won't resolve — same accepted
  // scope limit as $IFDEF regions not being greyed out. Reused across every
  // EnsureFresh call (ProcessText resets its own per-run state internally).
  FSourceManager := TPasSourceManager.Create([]);
  FDefines := CreatePlatformDefines(pfWin32);
  FPreprocessor := TPasPreprocessor.Create(FSourceManager, FDefines,
    37.0, PlatformInfo(pfWin32).PointerBytes, PlatformInfo(pfWin32).ExtendedBytes);

  FCachedSource := #0; // guarantee the first EnsureFresh call actually tokenizes
  FCachedLineCount := -1;
  FDirty := True;
  FLineStartAbs := 0;
  FCurTokenIdx := 0;
end;

destructor TPasTreeSynHighlighter.Destroy;
begin
  FPreprocessor.Free;
  FDefines.Free;      // caller-owned — TPasPreprocessor only frees its own clone
  FSourceManager.Free;
  FWeakKeywords.Free;
  inherited;
end;

class function TPasTreeSynHighlighter.GetLanguageName: string;
begin
  Result := 'PasTreeObjectPascal';
end;

class function TPasTreeSynHighlighter.GetFriendlyLanguageName: string;
begin
  Result := 'Object Pascal (PasTree lexer)';
end;

function TPasTreeSynHighlighter.GetDefaultAttribute(
  Index: Integer): TSynHighlighterAttributes;
begin
  case Index of
    SYN_ATTR_COMMENT: Result := FCommentAttri;
    SYN_ATTR_IDENTIFIER: Result := FIdentifierAttri;
    SYN_ATTR_KEYWORD: Result := FKeywordAttri;
    SYN_ATTR_STRING: Result := FStringAttri;
    SYN_ATTR_WHITESPACE: Result := FWhitespaceAttri;
    SYN_ATTR_SYMBOL: Result := FSymbolAttri;
  else
    Result := nil;
  end;
end;

procedure TPasTreeSynHighlighter.SetSourceLines(const Value: TStrings);
begin
  FSourceLines := Value;
  FCachedSource := #0; // force a re-tokenize against the newly attached buffer
  FCachedLineCount := -1;
  FDirty := True;
end;

procedure TPasTreeSynHighlighter.MarkDirty;
begin
  FDirty := True;
end;

procedure TPasTreeSynHighlighter.SetLinkRange(AFrom, ATo: Integer);
begin
  FLinkFrom := AFrom;
  FLinkTo := ATo;
end;

function TPasTreeSynHighlighter.LinkRangeEquals(AFrom, ATo: Integer): Boolean;
begin
  Result := (FLinkFrom = AFrom) and (FLinkTo = ATo);
end;

function TPasTreeSynHighlighter.LexerDiagnosticCount: Integer;
begin
  Result := Length(FTokenStream.Diagnostics);
end;

// Re-tokenizes (and re-parses, for weak-keyword precision) the WHOLE attached
// buffer iff its text changed since last time. The actual lex+parse only runs
// once per real edit, regardless of how many lines get re-painted — but doing
// so requires detecting "did it change" WITHOUT touching the buffer at all in
// the common (unchanged) case, which is why this checks FDirty (an O(1) flag
// the HOST sets via MarkDirty on its own edit notification) before anything
// else. `DoSetLine` calls this on EVERY line, including the N calls SynEdit
// makes while painting/scanning an N-line file — for a real RTL unit this N
// is tens of thousands. The PREVIOUS version's only guard was `FSourceLines.
// Text = FCachedSource`: fetching `.Text` reconstructs and compares the WHOLE
// buffer, so doing that on every one of those N calls is O(N * buffer size),
// not O(buffer size) — a genuine hang on a large file (e.g. opening System.
// SysUtils.pas, 37.6k lines/1.1MB, via go-to-declaration: ~37,600 full-buffer
// rebuilds+compares before a single keystroke). FDirty collapses that back to
// O(1) for every call except the (at most one) real change. FCachedLineCount
// is a second, still-O(1) guard against a same-line-count edit slipping past
// a missed/late MarkDirty call — belt-and-suspenders, not the primary check.
procedure TPasTreeSynHighlighter.EnsureFresh;
var
  LText: string;
  LPreprocessed: TPasPreprocessed;
  LTree: TPasTree;
  LParseDiags: TArray<TPasParseDiag>;
  LPreprocessedOk: Boolean;
begin
  if not Assigned(FSourceLines) then
    Exit;
  if not FDirty and (FSourceLines.Count = FCachedLineCount) then
    Exit;
  LText := FSourceLines.Text;
  FDirty := False;
  FCachedLineCount := FSourceLines.Count;
  if LText = FCachedSource then
    Exit;
  FCachedSource := LText;
  FHaveAst := False;
  LPreprocessedOk := True;

  try
    LPreprocessed := FPreprocessor.ProcessText('buffer.pas', LText);
    FTokenStream := LPreprocessed.Files[0]; // same TPasTokenStream shape as before
  except
    // Belt-and-suspenders: fall back to a bare lex so line display keeps
    // working even if the preprocessor somehow chokes on some intermediate
    // live-typing buffer state (not observed in practice — see header comment).
    LPreprocessedOk := False;
    FTokenStream := TPasLexer.Tokenize(LText);
  end;
  FTokenCount := Length(FTokenStream.Tokens);
  // SetLength alone does NOT zero the retained portion when FTokenCount does
  // not exceed the array's previous length — stale True marks from an
  // earlier parse (this instance's own previous buffer content, e.g. before
  // the keystroke that triggered this EnsureFresh) would otherwise survive
  // at whatever raw indices they occupied, coloring unrelated tokens on the
  // NEW content as keywords. Explicit clear on every pass, not just on growth.
  SetLength(FWeakKeywordToken, FTokenCount);
  if FTokenCount > 0 then
    FillChar(FWeakKeywordToken[0], FTokenCount * SizeOf(Boolean), 0);
  SetLength(FInactiveToken, FTokenCount);
  if FTokenCount > 0 then
    FillChar(FInactiveToken[0], FTokenCount * SizeOf(Boolean), 0);

  // Skipped ($IFDEF'd-out) regions are a PREPROCESSOR-only concept, known
  // whether or not the subsequent parse succeeds — mark them regardless of
  // FHaveAst below. LPreprocessed.Skipped[0] is the main buffer's own list
  // (per-file, sorted); a bare-lex fallback (LPreprocessedOk = False) has
  // no such list, so FInactiveToken correctly stays all-False (just reset).
  if LPreprocessedOk and (Length(LPreprocessed.Skipped) > 0) then
    MarkInactiveTokens(LPreprocessed.Skipped[0]);

  if LPreprocessedOk then
    try
      LTree := TPasParser.ParseFile(LPreprocessed, LParseDiags);
      BuildWeakKeywordSpans(LTree, LPreprocessed);
      FHaveAst := True;
    except
      FHaveAst := False; // IsWeakKeyword falls back to the flat word list
    end;
end;

// Marks every raw token whose start offset falls inside a skipped $IFDEF
// region as inactive — a single linear merge over both (sorted) lists, same
// complexity discipline as the rest of this highlighter (see EnsureFresh's
// header comment on why an O(tokens) pass, not per-token binary search,
// matters for large real files). Directive tokens themselves ({$IFDEF}/
// {$ELSE}/{$ENDIF}) are never inside a region (PasTree.Preprocessor.
// MarkSkipped starts a region AFTER the deactivating directive and ends it
// AT the reactivating one), so they keep their normal Directive color —
// matching real Delphi IDE behavior where the markers stay visible and only
// the body between them greys out.
procedure TPasTreeSynHighlighter.MarkInactiveTokens(
  const ASkipped: TArray<TPasSkippedRegion>);
var
  LTok, LReg: Integer;
begin
  LReg := 0;
  for LTok := 0 to FTokenCount - 1 do
  begin
    while (LReg < Length(ASkipped)) and
          (FTokenStream.Tokens[LTok].Start >= ASkipped[LReg].EndPos) do
      Inc(LReg);
    if LReg >= Length(ASkipped) then
      Break;
    if FTokenStream.Tokens[LTok].Start >= ASkipped[LReg].Start then
      FInactiveToken[LTok] := True;
  end;
end;

// Walks the parsed tree once, marking every raw token index that is a "bare"
// weak-keyword word — i.e. within an nkVisibility/nkDirective/nkPropSpec
// node's own span but NOT within one of its adopted child spans (a child is
// always an argument/getter/setter expression, e.g. the `GetFoo` in
// `read GetFoo`, which must stay Identifier-colored, not Keyword-colored).
procedure TPasTreeSynHighlighter.BuildWeakKeywordSpans(const ATree: TPasTree;
  const APreprocessed: TPasPreprocessed);

  // Marks every raw token covered by visible-stream range [AFirst..ALast].
  procedure MarkVisibleRange(AFirst, ALast: Integer);
  var
    LVis, LRaw: Integer;
  begin
    for LVis := AFirst to ALast do
    begin
      if (LVis < 0) or (LVis > High(APreprocessed.Visible)) then
        Continue;
      if APreprocessed.Visible[LVis].FileId <> 0 then
        Continue; // only the main buffer — no $I includes in a live editor buffer
      LRaw := APreprocessed.Visible[LVis].TokenIndex;
      if (LRaw >= 0) and (LRaw < Length(FWeakKeywordToken)) then
        FWeakKeywordToken[LRaw] := True;
    end;
  end;

  // For one directive-ish node: its own span minus every direct child's span.
  procedure MarkBareWords(ANode: Integer);
  var
    LChild, LCursor: Integer;
  begin
    LCursor := ATree.Nodes[ANode].FirstToken;
    LChild := ATree.Nodes[ANode].FirstChild;
    while LChild <> NIL_NODE do
    begin
      if ATree.Nodes[LChild].FirstToken > LCursor then
        MarkVisibleRange(LCursor, ATree.Nodes[LChild].FirstToken - 1);
      LCursor := ATree.Nodes[LChild].LastToken + 1;
      LChild := ATree.Nodes[LChild].NextSibling;
    end;
    if LCursor <= ATree.Nodes[ANode].LastToken then
      MarkVisibleRange(LCursor, ATree.Nodes[ANode].LastToken);
  end;

var
  LIdx: Integer;
begin
  for LIdx := 0 to High(ATree.Nodes) do
    case ATree.Nodes[LIdx].Kind of
      nkVisibility, nkDirective, nkPropSpec:
        MarkBareWords(LIdx);
    end;
end;

function TPasTreeSynHighlighter.LineStartOffset(ALineNumber: Integer): Integer;
begin
  if Length(FTokenStream.LineStarts) = 0 then
    Exit(0);
  // SynEdit's real interactive paint path (SynEdit.pas PaintTextLines) passes
  // a 1-based line number (TBufferCoord.Line convention — also why the
  // WhitespaceColor reset workaround uses the literal SetLine('', 1) to mean
  // "line one"), but FTokenStream.LineStarts is 0-based. Off-by-one here
  // silently shifts every line to the next line's token(s).
  Dec(ALineNumber);
  if ALineNumber < 0 then
    ALineNumber := 0
  else if ALineNumber > High(FTokenStream.LineStarts) then
    ALineNumber := High(FTokenStream.LineStarts);
  Result := FTokenStream.LineStarts[ALineNumber];
end;

// Lower-bound binary search for the first token with EndPos > AOffset. Since
// the token stream is contiguous and gapless (full fidelity: EndPos[i] =
// Start[i+1]), this uniquely identifies "the token covering AOffset" —
// including one that started on an earlier line and continues past it.
function TPasTreeSynHighlighter.LocateStartToken(AOffset: Integer): Integer;
var
  LLo, LHi, LMid: Integer;
begin
  if FTokenCount = 0 then
    Exit(0);
  LLo := 0;
  LHi := FTokenCount - 1;
  while LLo < LHi do
  begin
    LMid := (LLo + LHi) div 2;
    if FTokenStream.Tokens[LMid].EndPos > AOffset then
      LHi := LMid
    else
      LLo := LMid + 1;
  end;
  Result := LLo;
end;

// True when the CURRENT token (an identifier, per FCurKind) is a weak
// keyword. AST-precise when available (FHaveAst — see BuildWeakKeywordSpans):
// this correctly excludes `var dynamic: Integer;`, since the parser never
// builds an nkDirective there. Falls back to the flat, position-blind
// word-list check only if this pass's parse failed. Cosmetic overlay only
// either way — see the unit header comment.
function TPasTreeSynHighlighter.IsWeakKeyword: Boolean;
begin
  if FHaveAst then
    Result := (FCurTokenAbsIdx >= 0) and
      (FCurTokenAbsIdx < Length(FWeakKeywordToken)) and
      FWeakKeywordToken[FCurTokenAbsIdx]
  else
    Result := FWeakKeywords.ContainsKey(LowerCase(GetToken));
end;

procedure TPasTreeSynHighlighter.DoSetLine(const Value: string;
  LineNumber: TSynNativeInt);
begin
  inherited DoSetLine(Value, LineNumber); // sets fLineStr/fLine/fLineLen/Run:=0
  EnsureFresh;
  FLineStartAbs := LineStartOffset(LineNumber);
  FCurTokenIdx := LocateStartToken(FLineStartAbs);
end;

// NB: EOL is Run > fLineLen, not Run >= fLineLen — a token that ends EXACTLY
// at the line's end (e.g. the last token on the line) must still be reported
// once before EOL is signalled. This mirrors TSynJSONSyn's own convention
// (GetEol = Run = fLineLen+1): callers do "while not GetEol do (use; Next)",
// so if the just-positioned token already satisfied Run=fLineLen, an EOL
// defined as Run>=fLineLen would make that final token invisible — it would
// never get processed before the loop exits. Next (below) advances Run to
// fLineLen+1 as an explicit "truly nothing left" sentinel, one call after
// the last real token was reported.
function TPasTreeSynHighlighter.GetEol: Boolean;
begin
  Result := Run > fLineLen;
end;

function TPasTreeSynHighlighter.GetTokenKind: TSynNativeInt;
begin
  Result := Ord(FCurKind);
end;

function TPasTreeSynHighlighter.GetTokenAttribute: TSynHighlighterAttributes;
begin
  // Inactive code overrides EVERYTHING else uniformly — a keyword, string or
  // "unterminated" token inside a skipped $IFDEF region is not a real error
  // (dcc never looks at it either); it's just dead text.
  if (FCurTokenAbsIdx >= 0) and (FCurTokenAbsIdx < Length(FInactiveToken)) and
     FInactiveToken[FCurTokenAbsIdx] then
    Exit(FInactiveAttri);
  // Ctrl+hover link: checked for EVERY token kind, not just identifiers —
  // a `uses` clause's dotted unit name (System.SysUtils) links as ONE span
  // covering the dot too, so the whole qualified name underlines together.
  if (FLinkFrom >= 0) and (FCurTokenAbsIdx >= FLinkFrom) and
     (FCurTokenAbsIdx <= FLinkTo) then
    Exit(FLinkAttri);
  if FCurUnterminated then
    Exit(FErrorAttri);
  case FCurKind of
    tkUnknown:
      Result := FErrorAttri;
    tkWhitespace, tkEndOfFile:
      Result := FWhitespaceAttri;
    tkCommentLine, tkCommentBrace, tkCommentParen:
      Result := FCommentAttri;
    tkDirective:
      Result := FDirectiveAttri;
    tkIdentifier:
      if IsWeakKeyword then
        Result := FKeywordAttri
      else
        Result := FIdentifierAttri;
    tkIntLiteral, tkRealLiteral, tkControlChar:
      Result := FNumberAttri;
    tkStringLiteral, tkMultilineString:
      Result := FStringAttri;
    tkAsmChunk:
      Result := FAsmAttri;
  else
    // Whatever's left is either punctuation (tkPlus..tkAssign) or a reserved
    // word (tkAnd..tkXor) — split by the lexer's own IsKeyword predicate.
    if PasTree.Types.IsKeyword(FCurKind) then
      Result := FKeywordAttri
    else
      Result := FSymbolAttri;
  end;
end;

procedure TPasTreeSynHighlighter.Next;
var
  LTok: TPasToken;
  LTokStartAbs, LTokEndAbs, LLineEndAbs, LPrevRun: Integer;
begin
  if Run > fLineLen then
    Exit; // already terminal (see GetEol) — nothing more to do

  LPrevRun := Run;
  LLineEndAbs := FLineStartAbs + fLineLen;

  // Skip any token that's already fully behind the current position (mainly
  // a safety net; FCurTokenIdx is normally already exactly where it should
  // be, advanced either here or freshly by DoSetLine's LocateStartToken).
  while (FCurTokenIdx < FTokenCount) and
        (FTokenStream.Tokens[FCurTokenIdx].EndPos <= FLineStartAbs + Run) do
    Inc(FCurTokenIdx);

  if (FCurTokenIdx >= FTokenCount) or
     (FTokenStream.Tokens[FCurTokenIdx].Start >= LLineEndAbs) then
  begin
    // Nothing left to report on this line: advance past fLineLen so GetEol
    // (Run > fLineLen) reports true from here on.
    Run := fLineLen + 1;
    Exit;
  end;

  LTok := FTokenStream.Tokens[FCurTokenIdx];
  LTokStartAbs := LTok.Start;
  LTokEndAbs := LTok.EndPos;
  if LTokStartAbs < FLineStartAbs then
    LTokStartAbs := FLineStartAbs;   // token started on an earlier line
  if LTokEndAbs > LLineEndAbs then
    LTokEndAbs := LLineEndAbs;       // token continues onto a later line

  fTokenPos := LTokStartAbs - FLineStartAbs;
  Run := LTokEndAbs - FLineStartAbs;
  FCurKind := LTok.Kind;
  FCurUnterminated := tfUnterminated in LTok.Flags;
  FCurTokenAbsIdx := FCurTokenIdx; // raw index of LTok, before the Inc below

  if LTok.EndPos <= LLineEndAbs then
    Inc(FCurTokenIdx)
  // else: token continues past this line — keep FCurTokenIdx so the next
  // DoSetLine (next line) re-locates and keeps clipping the same token.
  ;

  if Run <= LPrevRun then
  begin
    // Defensive: guarantee forward progress no matter what (never let the
    // painter's "while not GetEol do Next" loop hang).
    fTokenPos := LPrevRun;
    Run := fLineLen + 1;
  end;
end;

end.
