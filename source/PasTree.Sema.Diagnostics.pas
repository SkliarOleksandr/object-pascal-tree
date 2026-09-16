unit PasTree.Sema.Diagnostics;

{
  PasTree semantics - diagnostic records and the (growing) EXXXX catalog.

  Codes and message wording mirror Delphi's compiler (and the DelphiAST
  reference, AST.Delphi.Errors.pas) so downstream tooling can match dcc output.
  Most of the catalog is emitted today - E2003, E2004, E2081, F1027, E2010,
  E2515, E2361, E2001, E2012, E2015, E2028, E2032, E2034, E2035, E2145,
  E2193, plus the preprocessor's own PPINT/PPENC. The rest are declared for
  the phases that follow.
}

interface

uses
  PasTree.Types;

type
  TSemaDiag = record
    Code: string;      // e.g. 'E2004'
    Msg: string;       // fully formatted, code-prefixed
    DeclNode: Integer; // CST node the diagnostic anchors to (-1 if none)
    FileId: Integer;   // index into TPasPreprocessed.FileNames
    Line: Integer;     // 1-based
    Col: Integer;      // 1-based
  end;

const
  // Delphi-matched message templates (single %s = identifier name).
  SE2003_UndeclaredIdentifier = 'E2003 Undeclared identifier: ''%s''';
  SE2004_IdentifierRedeclared = 'E2004 Identifier redeclared: ''%s''';
  SE2081_AssignToForLoopVar = 'E2081 Assignment to FOR-Loop variable ''%s''';
  // Takes no argument: a bare `raise` has nothing to name (18 sec. 18.3.1).
  SE2145_ReRaiseOutsideHandler =
    'E2145 Re-raising an exception only allowed in exception handler';
  // Likewise argument-free; dcc's wording says "standard function" (4 sec. 4.11).
  SE2193_SliceOutsideOpenArray =
    'E2193 Slice standard function only allowed as open array argument';
  // The ordinal/Boolean family (2 sec. 2.1.1, sec. 2.2.2, sec. 2.4.1). None takes an
  // argument - dcc names neither the type nor the position.
  SE2001_OrdinalTypeRequired = 'E2001 Ordinal type required';
  SE2012_MustBeBoolean = 'E2012 Type of expression must be BOOLEAN';
  SE2028_SetTooLarge = 'E2028 Sets may have at most 256 elements';
  // 11 sec. 11.2.1. The single %s is the QUALIFIED member name, `TType.Member`,
  // which is how dcc spells it.
  SE2361_CannotAccessPrivate = 'E2361 Cannot access private symbol %s';
  SE2032_ForCounterNotOrdinal =
    'E2032 For loop control variable must have ordinal type';
  SE2005_NotATypeIdentifier   = 'E2005 ''%s'' is not a type identifier';
  // E2010 takes two type names (dst, src). E2015 takes NOTHING - dcc's own
  // wording names no operator, so the template has no %s and every call site
  // passes it verbatim.
  SE2010_IncompatibleTypes    = 'E2010 Incompatible types: ''%s'' and ''%s''';
  SE2015_OperatorNotApplicable =
    'E2015 Operator not applicable to this operand type';
  // A `uses` name with no SOURCE on any search path. dcc's own code, but its
  // wording is "Unit not found: 'X' or binary equivalents (.dcu)" because the
  // compiler accepts a precompiled unit; a source analyzer cannot, so the
  // message says source explicitly. That difference is real and not cosmetic:
  // a library shipped as .dcu only builds fine and is still unanalyzable here.
  SF1027_UnitSourceNotFound =
    'F1027 Unit not found: ''%s'' (no source on the search path)';
  SE2034_TooManyActualParams  = 'E2034 Too many actual parameters';
  SE2035_NotEnoughActualParams = 'E2035 Not enough actual parameters';
  // A trailing comma in a call (`F(1,)`) with a parameter still due: dcc's
  // syntax wording, from the arity check - the parser accepts the comma
  // (6.2.5, it compiles when the last parameter has a default).
  SE2029_ExpressionExpectedRParen =
    'E2029 Expression expected but '')'' found';
  // Generic type-parameter constraints (16.4.1). Wording and codes verified
  // against dcc32 37.0; the single %s is the PARAMETER name (E2515 takes the
  // constraint type name second).
  SE2511_MustBeClass = 'E2511 Type parameter ''%s'' must be a class type';
  SE2512_MustBeValueType =
    'E2512 Type parameter ''%s'' must be a non-nullable value type';
  SE2515_NotCompatibleWith =
    'E2515 Type parameter ''%s'' is not compatible with type ''%s''';

  { OUR OWN failures, not the source's - the two ways an analysis can go wrong
    quietly and leave a host staring at a flood of downstream nonsense.

    PPINT is an exception escaping a pass. Whatever it was working on is
    incomplete, so every name that unit declared is missing and its importers
    report rubbish; the one thing that must not happen is for that to be
    silent.

    PPENC is a file whose bytes did not decode under its own declared
    encoding. We recover (see TPasSourceManager.DecodeText) rather than reject
    it, because dcc accepts such files - but the recovered text is not
    necessarily what the author wrote, so it is worth saying so. This is the
    one that was missing: a malformed byte in a comment cost ~1700 false
    reports across the Alcinoe package and nothing in the log pointed at it. }
  SPPINT_PassFailed = 'Internal failure in the %s pass: %s: %s. This unit''s ' +
    'analysis is incomplete, so diagnostics in units that import it may be ' +
    'wrong.';
  SPPENC_Recovered = 'File did not decode as %s and was recovered %s. Text ' +
    'after the bad byte may differ from the source.';

function MakeDiag(const ACode, AMsg: string; ADeclNode, AFileId, ALine,
  ACol: Integer): TSemaDiag;

{ How a host should LABEL a diagnostic. Not every code is an error, and a host
  that says "Error" for all of them overstates the ones that report OUR
  limitation rather than the source's: `PPIF` means an `$IF` we could not
  decide, so the branch taken may be the wrong one - worth seeing, not a
  defect in the code being analyzed. Codes are classified by their letter, the
  way dcc's own numbering already works (E/F fatal-ish, W/H advisory), with
  the PP* pair spelled out. }
function DiagSeverityLabel(const ACode: string): string;

{ The lexer's diagnostics, worded as dcc words them (probed dcc64 35.0,
  2026-09-16): an unterminated string is E2052, an unterminated comment E2057
  naming the line it opened on, a stray byte E2038 with the character and its
  code, a `#` with no value E2026. Two are NOT errors for dcc - a bare `$` or
  `%` with no digits compiles as the literal 0 - so they are reported as the
  advisory WLEX, because the text almost certainly is not what was meant
  (`%@461` in a demo sample) yet dcc would accept it. Returns the code and the
  code-prefixed message the way MakeDiag wants them; AStartLine is the
  1-based line of the diagnostic's own start, used by E2057. }
procedure LexDiagText(const ADiag: TPasDiagnostic; const AStream: TPasTokenStream;
  AStartLine: Integer; out ACode, AMsg: string);

{ True for a diagnostic that the lexer or the parser raised - a SYNTAX
  finding, dcc's "expected but found" family - as opposed to one the semantic
  passes raised over a well-formed tree. Hosts filter on it: the demo has one
  checkbox for each family. The test is by code, so TSemaDiag keeps its shape
  for the consumers that already read it (pastree-lsp). }
function IsSyntaxDiagCode(const ACode: string): Boolean;

implementation

uses
  System.SysUtils;

procedure LexDiagText(const ADiag: TPasDiagnostic; const AStream: TPasTokenStream;
  AStartLine: Integer; out ACode, AMsg: string);
var
  LCh: Char;
begin
  case ADiag.Code of
    dcInvalidChar:
      begin
        ACode := 'E2038';
        if (ADiag.Start >= 0) and (ADiag.Start < Length(AStream.Source)) then
          LCh := AStream.Source[ADiag.Start + 1]
        else
          LCh := #0;
        AMsg := Format('E2038 Illegal character in input file: ''%s'' (#$%.2X)',
          [LCh, Ord(LCh)]);
      end;
    dcInvalidAmpersand:
      begin
        ACode := 'E2029';
        AMsg := 'E2029 Identifier expected after ''&''';
      end;
    dcMissingHexDigits:
      begin
        ACode := 'WLEX';
        AMsg := 'WLEX ''$'' with no hexadecimal digits reads as 0';
      end;
    dcMissingBinDigits:
      begin
        ACode := 'WLEX';
        AMsg := 'WLEX ''%'' with no binary digits reads as 0';
      end;
    dcMissingControlCharValue:
      begin
        ACode := 'E2026';
        AMsg := 'E2026 Constant expression expected';
      end;
    dcUnterminatedString, dcUnterminatedMultilineString:
      begin
        ACode := 'E2052';
        AMsg := 'E2052 Unterminated string';
      end;
    dcUnterminatedComment:
      begin
        ACode := 'E2057';
        AMsg := Format('E2057 Unexpected end of file in comment started on ' +
          'line %d', [AStartLine]);
      end;
    dcUnterminatedDirective:
      begin
        ACode := 'E2057';
        AMsg := Format('E2057 Unexpected end of file in compiler directive ' +
          'started on line %d', [AStartLine]);
      end;
    dcUnterminatedAsm:
      begin
        ACode := 'E2029';
        AMsg := 'E2029 ''END'' expected but end of file found';
      end;
    dcInconsistentIndentChars:
      begin
        ACode := 'E2657';
        AMsg := 'E2657 Inconsistent indentation characters in multiline string';
      end;
  else
    ACode := 'E2029';
    AMsg := 'E2029 Lexical error';
  end;
end;

function IsSyntaxDiagCode(const ACode: string): Boolean;
begin
  Result := (ACode = 'E2029') or (ACode = 'E2038') or (ACode = 'E2052') or
    (ACode = 'E2057') or (ACode = 'E2026') or (ACode = 'E2657') or
    (ACode = 'WLEX');
end;

function MakeDiag(const ACode, AMsg: string; ADeclNode, AFileId, ALine,
  ACol: Integer): TSemaDiag;
begin
  Result.Code := ACode;
  Result.Msg := AMsg;
  Result.DeclNode := ADeclNode;
  Result.FileId := AFileId;
  Result.Line := ALine;
  Result.Col := ACol;
end;

function DiagSeverityLabel(const ACode: string): string;
begin
  if ACode = 'PPIF' then
    // Ours, not the source's: an $IF we could not decide. The chosen branch
    // may be wrong, which is worth surfacing without calling it an error.
    Result := 'Warning'
  else if ACode = 'PPBAD' then
    // The source's: a conditional expression that does not parse. dcc would
    // reject it too wherever that branch is live.
    Result := 'Error'
  else if ACode = 'PPINT' then
    // Ours, and the loudest thing we can say: a pass failed, so this unit is
    // only partly analyzed and its importers cannot be trusted.
    Result := 'Error'
  else if ACode = 'PPENC' then
    // Ours: the file was recovered, not rejected. Worth seeing precisely
    // because the alternative is silence.
    Result := 'Warning'
  else if (ACode <> '') and CharInSet(UpCase(ACode[1]), ['W', 'H']) then
    Result := 'Warning'
  else
    Result := 'Error';
end;

end.
