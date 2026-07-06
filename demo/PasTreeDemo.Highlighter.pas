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

  Scope: purely lexical (TPasLexer only — no preprocessor, no parser). Weak
  keywords/directives and predefined identifiers are shown as plain
  Identifier, exactly as the lexer classifies them (see PasTree.Types) —
  deliberately NOT overlaid with a static keyword-like word list, so the
  colors reflect the lexer's actual output, nothing embellished. $IFDEF'd-out
  regions are not greyed out (that needs the preprocessor, a different tier).

  Demo-only: lives in demo/, not source/, and is created purely at runtime —
  no `Register` procedure, no design-time package.
}

interface

uses
  System.Classes,
  System.SysUtils,
  Vcl.Graphics,
  SynFunc,
  SynEditTypes,
  SynEditHighlighter,
  PasTree.Types,
  PasTree.Lexer;

type
  TPasTreeSynHighlighter = class(TSynCustomHighlighter)
  private
    FSourceLines: TStrings;        // attached editor buffer (not owned)
    FCachedSource: string;         // last text actually tokenized
    FTokenStream: TPasTokenStream;
    FTokenCount: Integer;
    FLineStartAbs: Integer;        // absolute offset of the current line
    FCurTokenIdx: Integer;         // index into FTokenStream.Tokens
    FCurKind: TPasTokenKind;       // kind of the token last reported by Next
    FCurUnterminated: Boolean;     // tfUnterminated on that token
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
    class function GetLanguageName: string; override;
    class function GetFriendlyLanguageName: string; override;
    function GetEol: Boolean; override;
    function GetTokenKind: TSynNativeInt; override;
    function GetTokenAttribute: TSynHighlighterAttributes; override;
    procedure Next; override;
    { The TStrings this highlighter re-tokenizes on demand (typically the
      TSynEdit.Lines it is attached to). Not owned/freed by this class. }
    property SourceLines: TStrings read FSourceLines write SetSourceLines;
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
  FCommentAttri.Foreground := clGreen;
  FCommentAttri.Style := [fsItalic];
  AddAttribute(FCommentAttri);

  FDirectiveAttri := TSynHighlighterAttributes.Create('Directive', 'Compiler directive');
  FDirectiveAttri.Foreground := clOlive;
  FDirectiveAttri.Style := [fsItalic, fsBold];
  AddAttribute(FDirectiveAttri);

  FIdentifierAttri := TSynHighlighterAttributes.Create('Identifier', 'Identifier');
  AddAttribute(FIdentifierAttri);

  FKeywordAttri := TSynHighlighterAttributes.Create('Keyword', 'Reserved word');
  FKeywordAttri.Foreground := clNavy;
  FKeywordAttri.Style := [fsBold];
  AddAttribute(FKeywordAttri);

  FNumberAttri := TSynHighlighterAttributes.Create('Number', 'Number literal');
  FNumberAttri.Foreground := clPurple;
  AddAttribute(FNumberAttri);

  FStringAttri := TSynHighlighterAttributes.Create('String', 'String literal');
  FStringAttri.Foreground := clMaroon;
  AddAttribute(FStringAttri);

  FSymbolAttri := TSynHighlighterAttributes.Create('Symbol', 'Punctuation/operator');
  AddAttribute(FSymbolAttri);

  FAsmAttri := TSynHighlighterAttributes.Create('Asm', 'Opaque BASM chunk');
  FAsmAttri.Background := clInfoBk;
  AddAttribute(FAsmAttri);

  FErrorAttri := TSynHighlighterAttributes.Create('Error', 'Invalid / unterminated');
  FErrorAttri.Foreground := clRed;
  FErrorAttri.Style := [fsBold, fsUnderline];
  AddAttribute(FErrorAttri);

  SetAttributesOnChange(DefHighlightChange);

  FCachedSource := #0; // guarantee the first EnsureFresh call actually tokenizes
  FLineStartAbs := 0;
  FCurTokenIdx := 0;
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
end;

function TPasTreeSynHighlighter.LexerDiagnosticCount: Integer;
begin
  Result := Length(FTokenStream.Diagnostics);
end;

// Re-tokenizes the WHOLE attached buffer iff its text changed since last
// time. Cheap when nothing changed (one string compare); the actual lex only
// runs once per real edit, regardless of how many lines get re-painted.
procedure TPasTreeSynHighlighter.EnsureFresh;
var
  LText: string;
begin
  if not Assigned(FSourceLines) then
    Exit;
  LText := FSourceLines.Text;
  if LText = FCachedSource then
    Exit;
  FCachedSource := LText;
  FTokenStream := TPasLexer.Tokenize(LText);
  FTokenCount := Length(FTokenStream.Tokens);
end;

function TPasTreeSynHighlighter.LineStartOffset(ALineNumber: Integer): Integer;
begin
  if Length(FTokenStream.LineStarts) = 0 then
    Exit(0);
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
