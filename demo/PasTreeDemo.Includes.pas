unit PasTreeDemo.Includes;

{
  One pure function, kept out of the form so it can be tested: locating the FILE
  NAME inside an $I / $INCLUDE directive on a source line.

  It is a line scan and not a use of the lexer on purpose. Ctrl+hover calls it on
  every mouse move, and it has to work in a buffer the analysis never saw — a
  file just opened, or one edited since the last parse.
}

interface

{ The 1-based, inclusive column span of the file name in the $I / $INCLUDE
  directive containing column ACol, or False when ACol is not inside one.

  Both comment forms are recognised: the brace one and the parenthesis-star one.
  Surrounding spaces and quotes are excluded, so a quoted path with a space
  comes back without them. Directives that merely START with I are rejected:
  $I+ and $I- are I/O checking and $I% is an environment-variable string, none
  of them an include. }
function TryIncludeArgSpan(const ALine: string; ACol: Integer;
  out AFrom, ATo: Integer): Boolean;

implementation

uses
  System.SysUtils;

function TryIncludeArgSpan(const ALine: string; ACol: Integer;
  out AFrom, ATo: Integer): Boolean;
var
  LIdx, LWordFrom, LEnd: Integer;
  LWord: string;
begin
  Result := False;
  AFrom := 0;
  ATo := 0;
  LIdx := 1;
  while LIdx < Length(ALine) do
  begin
    // Start of a directive: '{$' or '(*$'.
    if (ALine[LIdx] = '{') and (ALine[LIdx + 1] = '$') then
      Inc(LIdx, 2)
    else if (ALine[LIdx] = '(') and (LIdx + 2 <= Length(ALine)) and
            (ALine[LIdx + 1] = '*') and (ALine[LIdx + 2] = '$') then
      Inc(LIdx, 3)
    else
    begin
      Inc(LIdx);
      Continue;
    end;
    // The directive word.
    LWordFrom := LIdx;
    while (LIdx <= Length(ALine)) and
          CharInSet(ALine[LIdx], ['a'..'z', 'A'..'Z']) do
      Inc(LIdx);
    LWord := Copy(ALine, LWordFrom, LIdx - LWordFrom);
    // Its argument: everything up to the closing '}' or '*)'.
    LEnd := LIdx;
    while (LEnd <= Length(ALine)) and (ALine[LEnd] <> '}') and
          not ((ALine[LEnd] = '*') and (LEnd < Length(ALine)) and
               (ALine[LEnd + 1] = ')')) do
      Inc(LEnd);
    if SameText(LWord, 'I') or SameText(LWord, 'INCLUDE') then
    begin
      AFrom := LIdx;
      ATo := LEnd - 1;
      while (AFrom <= ATo) and CharInSet(ALine[AFrom], [' ', #9, '''', '"']) do
        Inc(AFrom);
      while (ATo >= AFrom) and CharInSet(ALine[ATo], [' ', #9, '''', '"']) do
        Dec(ATo);
      // A caret one past the last character still means the name — that is
      // where it sits after double-clicking it.
      if (AFrom <= ATo) and not CharInSet(ALine[AFrom], ['%', '+', '-']) and
         (ACol >= AFrom) and (ACol <= ATo + 1) then
        Exit(True);
    end;
    LIdx := LEnd;
  end;
  AFrom := 0;
  ATo := 0;
end;

end.
