program UnitListSmoke;

{ The View Unit picker's list and filter (PasTreeDemo.UnitList).

  Split out of the dialog for the reason NavHistorySmoke's header gives about
  the history: none of this is observable while the program runs. A wrong rule
  here does not look like a bug - it looks like a list with two rows that both
  say `Types.pas`, or like a unit that is simply not in the list, and by the
  time anyone notices, the thing that would explain it is a filter box that has
  since been retyped. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  PasTreeDemo.UnitList in '..\demo\PasTreeDemo.UnitList.pas',
  PasTree.TestKit in 'PasTree.TestKit.pas';

var
  GCounter: TPasSuiteCounter;

procedure Ok(const AName: string; ACond: Boolean);
begin
  GCounter.Ok(AName, ACond);
end;

// The list's names, joined - one string is a readable failure, six index
// assertions are not.
function Names(const AList: TPasUnitList): string;
var
  LIdx: Integer;
begin
  Result := '';
  for LIdx := 0 to High(AList) do
  begin
    if Result <> '' then
      Result := Result + ',';
    Result := Result + AList[LIdx].Name;
  end;
end;

function PathOf(const AList: TPasUnitList; const AName: string): string;
var
  LIdx: Integer;
begin
  Result := '';
  for LIdx := 0 to High(AList) do
    if SameText(AList[LIdx].Name, AName) then
      Exit(AList[LIdx].FullPath);
end;

procedure TestBuild;
const
  PROJ: array[0..2] of string = (
    'C:\proj\Main.dpr', 'C:\proj\Vcl.Types.pas', 'C:\proj\System.Types.pas');
  USES_: array[0..2] of string = (
    'C:\rtl\System.SysUtils.pas',
    'C:\rtl\System.Types.pas',     // same NAME as a project file
    'C:\rtl\System.Classes.pas');
var
  LList: TPasUnitList;
begin
  LList := BuildUnitList(PROJ, USES_, False);
  Ok('uses files are absent when the box is off',
    Names(LList) = 'Main.dpr,System.Types.pas,Vcl.Types.pas');

  LList := BuildUnitList(PROJ, USES_, True);
  Ok('with the box on, both lists appear, sorted by name',
    Names(LList) = 'Main.dpr,System.Classes.pas,System.SysUtils.pas,' +
      'System.Types.pas,Vcl.Types.pas');
  // The name appears once, and it is the PROJECT's copy that is openable:
  // that is the file the analysis itself used.
  Ok('a name shared by the project and the closure is ONE entry, the project''s',
    PathOf(LList, 'System.Types.pas') = 'C:\proj\System.Types.pas');
  Ok('the directory is the path without the file, and without a trailing slash',
    LList[0].Directory = 'C:\proj');

  // Case-insensitively equal names are the same entry, and the sort does not
  // depend on case either.
  LList := BuildUnitList(['C:\a\Beta.pas', 'C:\b\alpha.pas', 'C:\c\BETA.PAS'],
    [], False);
  Ok('duplicate names differ only by case, and still collapse',
    Names(LList) = 'alpha.pas,Beta.pas');

  LList := BuildUnitList([], [], True);
  Ok('an empty project is an empty list, not a crash', Length(LList) = 0);
end;

procedure TestFilter;
var
  LList, LGot: TPasUnitList;
begin
  LList := BuildUnitList(
    ['C:\proj\Main.dpr', 'C:\rtl\System.Types.pas', 'C:\vcl\Vcl.Forms.pas'],
    [], False);

  Ok('an empty filter keeps everything',
    Names(FilterUnitList(LList, '')) = Names(LList));
  Ok('...and so does a whitespace-only one',
    Names(FilterUnitList(LList, '   ')) = Names(LList));

  // A SUBSTRING, not a prefix: the names are dotted, so the memorable part is
  // usually in the middle.
  LGot := FilterUnitList(LList, 'types');
  Ok('a substring matches, case-insensitively',
    Names(LGot) = 'System.Types.pas');
  LGot := FilterUnitList(LList, 'SYSTEM.');
  Ok('the filter''s own case does not matter either',
    Names(LGot) = 'System.Types.pas');

  // The path is SHOWN per row but deliberately not matched: a hit invisible in
  // the row it selects reads as a bug.
  LGot := FilterUnitList(LList, 'vcl\');
  Ok('the directory is not searched', Length(LGot) = 0);
  LGot := FilterUnitList(LList, 'Vcl.');
  Ok('...though a name that starts with the same word still matches',
    Names(LGot) = 'Vcl.Forms.pas');

  Ok('no match is an empty list',
    Length(FilterUnitList(LList, 'nothing-here')) = 0);
end;

begin
  try
    TestBuild;
    TestFilter;
    Writeln;
    if GCounter.Finish('UnitListSmoke') then
      ExitCode := 1;
  except
    on E: Exception do
    begin
      Writeln('EXCEPTION: ', E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
