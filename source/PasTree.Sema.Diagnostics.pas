unit PasTree.Sema.Diagnostics;

{
  PasTree semantics — diagnostic records and the (growing) EXXXX catalog.

  Codes and message wording mirror Delphi's compiler (and the DelphiAST
  reference, AST.Delphi.Errors.pas) so downstream tooling can match dcc output.
  Phase 1 only emits E2004; the rest are declared for the phases that follow.
}

interface

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
  // Takes no argument: a bare `raise` has nothing to name (18 §18.3.1).
  SE2145_ReRaiseOutsideHandler =
    'E2145 Re-raising an exception only allowed in exception handler';
  // Likewise argument-free; dcc's wording says "standard function" (4 §4.11).
  SE2193_SliceOutsideOpenArray =
    'E2193 Slice standard function only allowed as open array argument';
  // The ordinal/Boolean family (2 §2.1.1, §2.2.2, §2.4.1). None takes an
  // argument — dcc names neither the type nor the position.
  SE2001_OrdinalTypeRequired = 'E2001 Ordinal type required';
  SE2012_MustBeBoolean = 'E2012 Type of expression must be BOOLEAN';
  SE2028_SetTooLarge = 'E2028 Sets may have at most 256 elements';
  // 11 §11.2.1. The single %s is the QUALIFIED member name, `TType.Member`,
  // which is how dcc spells it.
  SE2361_CannotAccessPrivate = 'E2361 Cannot access private symbol %s';
  SE2032_ForCounterNotOrdinal =
    'E2032 For loop control variable must have ordinal type';
  SE2005_NotATypeIdentifier   = 'E2005 ''%s'' is not a type identifier';
  // E2010 takes two type names (dst, src); E2015 takes the operator lexeme.
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
  // Generic type-parameter constraints (16.4.1). Wording and codes verified
  // against dcc32 37.0; the single %s is the PARAMETER name (E2515 takes the
  // constraint type name second).
  SE2511_MustBeClass = 'E2511 Type parameter ''%s'' must be a class type';
  SE2512_MustBeValueType =
    'E2512 Type parameter ''%s'' must be a non-nullable value type';
  SE2515_NotCompatibleWith =
    'E2515 Type parameter ''%s'' is not compatible with type ''%s''';

  { OUR OWN failures, not the source's — the two ways an analysis can go wrong
    quietly and leave a host staring at a flood of downstream nonsense.

    PPINT is an exception escaping a pass. Whatever it was working on is
    incomplete, so every name that unit declared is missing and its importers
    report rubbish; the one thing that must not happen is for that to be
    silent.

    PPENC is a file whose bytes did not decode under its own declared
    encoding. We recover (see TPasSourceManager.DecodeText) rather than reject
    it, because dcc accepts such files — but the recovered text is not
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
  decide, so the branch taken may be the wrong one — worth seeing, not a
  defect in the code being analyzed. Codes are classified by their letter, the
  way dcc's own numbering already works (E/F fatal-ish, W/H advisory), with
  the PP* pair spelled out. }
function DiagSeverityLabel(const ACode: string): string;

implementation

uses
  System.SysUtils;

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
