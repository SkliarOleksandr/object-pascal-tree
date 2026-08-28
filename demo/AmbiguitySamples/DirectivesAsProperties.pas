unit DirectivesAsProperties;

{
  Ambiguity sample: weak keywords used as PROPERTY names. `property` always
  wants a plain identifier next, so this is never actually ambiguous to the
  parser - but it's a good contrast case for the highlighter: the property
  NAME (e.g. `override`) must render as Identifier, while the trailing `read`
  specifier on the SAME line must render as Keyword. Both are the same
  tkIdentifier token kind from the lexer; only AST position tells them apart
  (see PasTreeDemo.Highlighter's BuildWeakKeywordSpans).

  Adapted from the user's own DelphiAST test corpus (TestScripts\Names
  Overloading\ASTTest.NamesOverloading.DirsAsProps.pas) - real,
  dcc-verified Delphi syntax. PasTree parses it with 0 diagnostics.
}

interface

type
  TDirectivesAsProperties = class
  private
    FData: string;
  public
    property on: string read FData;
    property protected: string read FData;
    property sealed: string read FData;
    property abstract: string read FData;
    property readonly: string read FData;
    property writeonly: string read FData;
    property dispid: string read FData;
    property default: string read FData;
    property stored: string read FData;
    property index: string read FData;
    property register: string read FData;
    property safecall: string read FData;
    property stdcall: string read FData;
    property cdecl: string read FData;
    property assembler: string read FData;
    property export: string read FData;
    property helper: string read FData;
    property forward: string read FData;
    property virtual: string read FData;
    property override: string read FData;
    property varargs: string read FData;
  end;

implementation

end.
