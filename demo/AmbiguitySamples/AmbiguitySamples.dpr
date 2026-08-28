program AmbiguitySamples;

{
  Weak-keyword ambiguity samples for PasTreeDemo.Highlighter - open this
  project in the demo (Open Project...) to browse each unit and eyeball the
  coloring. Every unit here demonstrates spec B.4.2 directives / visibility
  words used in a position where they're NOT keywords, contrasted against
  real directive/property-specifier/visibility usage where they ARE. See
  each unit's header comment for what to expect.
}

{$APPTYPE CONSOLE}

uses
  DirectivesAsFields in 'DirectivesAsFields.pas',
  DirectivesAsProperties in 'DirectivesAsProperties.pas',
  DirectivesAsVariables in 'DirectivesAsVariables.pas',
  VisibilityWordEscaping in 'VisibilityWordEscaping.pas';

begin
end.
