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
  SE2005_NotATypeIdentifier   = 'E2005 ''%s'' is not a type identifier';
  // E2010 takes two type names (dst, src); E2015 takes the operator lexeme.
  SE2010_IncompatibleTypes    = 'E2010 Incompatible types: ''%s'' and ''%s''';
  SE2015_OperatorNotApplicable =
    'E2015 Operator not applicable to this operand type';

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
