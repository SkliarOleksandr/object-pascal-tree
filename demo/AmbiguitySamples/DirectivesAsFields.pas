unit DirectivesAsFields;

{
  Ambiguity sample: weak keywords (spec B.4.2 directives, incl. the
  visibility word `protected`) used as ordinary FIELD names, comma-listed in
  a single field declaration. None of these sit in "directive position" here
  — they're just names in a list — so the parser never builds an nkDirective
  or nkVisibility node for them, and PasTreeDemo.Highlighter's AST-precise
  weak-keyword coloring should render every single one as a plain Identifier,
  never as a keyword. `protected` mid-list is the sharpest case: it IS one of
  PasTree.Types.VISIBILITY_WORDS, and a BARE visibility word at the START of
  a member declaration really would start a new visibility section — but
  here it's the 2nd name in an existing field list (after a comma), a
  position the grammar never treats as a section boundary.

  Adapted from the user's own DelphiAST test corpus (TestScripts\Names
  Overloading\ASTTest.NamesOverloading.DirsAsFields.pas) — real,
  dcc-verified Delphi syntax. PasTree parses it with 0 diagnostics.
}

interface

type
  TDirectivesAsFields = class
    on,
    protected,
    sealed,
    abstract,
    readonly,
    writeonly,
    dispid,
    default,
    stored,
    index,
    register,
    safecall,
    stdcall,
    cdecl,
    assembler,
    export,
    helper,
    forward,
    virtual,
    override,
    varargs,
    deprecated: string;
  end;

implementation

end.
