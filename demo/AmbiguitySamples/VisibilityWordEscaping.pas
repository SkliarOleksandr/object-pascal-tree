unit VisibilityWordEscaping;

{
  Ambiguity sample: VISIBILITY words (private/protected/public/published/
  strict/automated) are stricter than other weak keywords. Per
  TPasParser.IsVisibilityWord (PasTree.Parser.pas): a BARE visibility word at
  the START of a member declaration is ALWAYS read as a section marker -
  unlike other directives, there is no grammar position where it's just an
  ordinary name. The only way to declare a field literally named `private`
  is the `&`-escape (spec B.3): `&private`. Escaping changes the token's
  TEXT (the lexer keeps the leading `&`), which is why it's exempt even from
  the flat-word-list fallback the highlighter uses if a parse fails - `&`
  + word never matches a plain 'private'/'public'/etc. lookup either way.

  (The commented-out line below is what NOT to write: `private: Integer;`
  right after the `private` section keyword would be parsed as an EMPTY
  member list re-declaring the section, not a field - it wouldn't even be a
  parse error, just silently not what you meant.)
}

interface

type
  TDemo = class
  private
    // private: Integer;   // WRONG: re-opens/re-declares the visibility section
    &private: Integer;      // RIGHT: escaped -> a field literally named "private"
    FValue: Integer;
  public
    property Value: Integer read FValue write FValue;
    property Escaped: Integer read &private write &private;
  end;

implementation

end.
