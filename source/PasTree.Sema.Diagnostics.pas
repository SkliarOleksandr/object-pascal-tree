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

function MakeDiag(const ACode, AMsg: string; ADeclNode, AFileId, ALine,
  ACol: Integer): TSemaDiag;

implementation

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

end.
