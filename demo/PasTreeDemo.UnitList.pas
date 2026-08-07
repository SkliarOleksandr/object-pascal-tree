unit PasTreeDemo.UnitList;

{
  PasTree demo — the list behind View Unit (Ctrl+F12), and the filter over it.

  Data only, no form: what goes in the list, in what order, and what a typed
  filter keeps. The dialog owns the widgets and this owns the rules, the same
  split PasTreeDemo.NavHistory makes and for the same reason — the rules have
  cases that are invisible when they are wrong. A duplicate name does not look
  like a bug, it looks like a list with two rows that both say `Types.pas`, and
  the one that opens is whichever happened to be added first.

  Two decisions are worth stating here rather than in the dialog:

  - the key is the file NAME, lowercased, not the path. Two copies of a unit on
    different search paths are ONE entry, because the analyzer will only ever
    reach one of them, and offering both would let the user open a file the
    analysis never looked at. The project's own files are added first, so a
    project copy wins over a library one — which is the same precedence
    AnalyzeProject applies when it builds the closure.
  - the filter matches a SUBSTRING of the name, case-insensitively. Not a
    prefix: the names are dotted (`System.Types.pas`), so a prefix filter makes
    the part people actually remember unreachable. The path is deliberately NOT
    matched — it is shown per row, but a hit invisible in the row it selects
    reads as a bug.
}

interface

uses
  System.SysUtils, System.Generics.Collections, System.Generics.Defaults;

type
  { One row: the name as shown, the directory shown under it, and the path the
    caller opens. Directory carries no trailing delimiter (it is a label, not a
    path to combine with). }
  TPasUnitEntry = record
    Name: string;
    Directory: string;
    FullPath: string;
  end;

  TPasUnitList = TArray<TPasUnitEntry>;

{ The picker's list. AProjectFiles is the project's own file list; AUsesFiles is
  everything the finished analysis reached (empty, or ignored, when the
  "Uses Units" box is off). Sorted by name, case-insensitively, with the
  directory as a tie-break so the order is stable rather than merely sorted. }
function BuildUnitList(const AProjectFiles, AUsesFiles: array of string;
  AIncludeUses: Boolean): TPasUnitList;

{ True when AEntry survives AFilter. An empty (or whitespace-only) filter keeps
  everything. }
function MatchesUnitFilter(const AEntry: TPasUnitEntry;
  const AFilter: string): Boolean;

{ AList filtered by AFilter, order preserved. }
function FilterUnitList(const AList: TPasUnitList;
  const AFilter: string): TPasUnitList;

implementation

uses
  System.IOUtils, System.StrUtils;

function BuildUnitList(const AProjectFiles, AUsesFiles: array of string;
  AIncludeUses: Boolean): TPasUnitList;
var
  LSeen: TDictionary<string, Boolean>;
  LItems: TList<TPasUnitEntry>;

  procedure AddPath(const APath: string);
  var
    LEntry: TPasUnitEntry;
    LKey: string;
  begin
    if APath = '' then
      Exit;
    LEntry.Name := TPath.GetFileName(APath);
    if LEntry.Name = '' then
      Exit;
    LKey := LowerCase(LEntry.Name);
    if LSeen.ContainsKey(LKey) then
      Exit;
    LSeen.Add(LKey, True);
    LEntry.Directory := ExcludeTrailingPathDelimiter(
      TPath.GetDirectoryName(APath));
    LEntry.FullPath := APath;
    LItems.Add(LEntry);
  end;

var
  LPath: string;
begin
  LSeen := TDictionary<string, Boolean>.Create;
  LItems := TList<TPasUnitEntry>.Create;
  try
    // Project files first: theirs is the path that wins a name collision.
    for LPath in AProjectFiles do
      AddPath(LPath);
    if AIncludeUses then
      for LPath in AUsesFiles do
        AddPath(LPath);
    LItems.Sort(TComparer<TPasUnitEntry>.Construct(
      function(const A, B: TPasUnitEntry): Integer
      begin
        Result := CompareText(A.Name, B.Name);
        if Result = 0 then
          Result := CompareText(A.Directory, B.Directory);
      end));
    Result := LItems.ToArray;
  finally
    LItems.Free;
    LSeen.Free;
  end;
end;

function MatchesUnitFilter(const AEntry: TPasUnitEntry;
  const AFilter: string): Boolean;
var
  LNeedle: string;
begin
  LNeedle := Trim(AFilter);
  if LNeedle = '' then
    Exit(True);
  Result := ContainsText(AEntry.Name, LNeedle);
end;

function FilterUnitList(const AList: TPasUnitList;
  const AFilter: string): TPasUnitList;
var
  LIdx, LCount: Integer;
begin
  SetLength(Result, Length(AList));
  LCount := 0;
  for LIdx := 0 to High(AList) do
    if MatchesUnitFilter(AList[LIdx], AFilter) then
    begin
      Result[LCount] := AList[LIdx];
      Inc(LCount);
    end;
  SetLength(Result, LCount);
end;

end.
