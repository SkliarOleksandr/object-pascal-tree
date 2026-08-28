program NavHistorySmoke;

{ The demo's Back/Forward list: the browser rules, and the line arithmetic that
  keeps recorded positions pointing at the same text while a file is edited.

  Both halves are invisible in the running program. A wrong rule does not look
  like a bug when it happens - Back simply lands somewhere slightly unexpected,
  three clicks after the mistake, and by then the history that would explain it
  is gone. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  PasTreeDemo.NavHistory in '..\demo\PasTreeDemo.NavHistory.pas',
  PasTree.TestKit in 'PasTree.TestKit.pas';

var
  GCounter: TPasSuiteCounter;
  GHist: TNavHistory;

procedure Ok(const AName: string; ACond: Boolean);
begin
  GCounter.Ok(AName, ACond);
end;

function E(const APath: string; ALine: Integer; ACol: Integer = 1):
  TNavHistoryEntry;
begin
  Result.FilePath := APath;
  Result.Line := ALine;
  Result.Col := ACol;
end;

// A jump FROM (APath,AFrom) TO (BPath,BLine), the shape the form produces.
procedure Jump(const AFromPath: string; AFromLine: Integer;
  const AToPath: string; AToLine: Integer);
begin
  GHist.RecordJump(E(AFromPath, AFromLine), True, E(AToPath, AToLine));
end;

// Back, reporting where it landed as 'file:line'; '-' when it refused.
function Back: string;
var
  LEntry: TNavHistoryEntry;
begin
  if GHist.GoBack({out} LEntry) then
    Result := Format('%s:%d', [LEntry.FilePath, LEntry.Line])
  else
    Result := '-';
end;

function Fwd: string;
var
  LEntry: TNavHistoryEntry;
begin
  if GHist.GoForward({out} LEntry) then
    Result := Format('%s:%d', [LEntry.FilePath, LEntry.Line])
  else
    Result := '-';
end;

begin
  GCounter.Init;
  GHist := TNavHistory.Create;
  try
    // ---- empty ----
    Ok('nothing to go back to', not GHist.CanGoBack);
    Ok('nothing to go forward to', not GHist.CanGoForward);
    Ok('Back on an empty history refuses', Back = '-');

    // ---- the first jump records BOTH ends ----
    // Without the origin there would be nothing to come back TO: the target is
    // where we now are, not where we were.
    Jump('a.pas', 10, 'b.pas', 20);
    Ok('first jump records origin and target', GHist.Count = 2);
    Ok('...and we are at the target', GHist.Index = 1);
    Ok('Back returns to the origin', Back = 'a.pas:10');
    Ok('Forward returns to the target', Fwd = 'b.pas:20');

    // ---- a chain ----
    Jump('b.pas', 20, 'c.pas', 30);
    Ok('a second jump appends only the target', GHist.Count = 3);
    Ok('Back walks it', Back = 'b.pas:20');
    Ok('Back walks it twice', Back = 'a.pas:10');
    Ok('and stops at the start', Back = '-');

    // ---- a jump from the middle discards the forward tail ----
    // The browser rule. Without it Forward would offer a branch the user
    // abandoned, which is worse than offering nothing.
    Ok('mid-history Forward still available', GHist.CanGoForward);
    Jump('a.pas', 10, 'd.pas', 40);
    Ok('the tail is gone', GHist.Count = 2);
    Ok('nothing to go forward to now', not GHist.CanGoForward);
    Ok('Back goes to where the branch left', Back = 'a.pas:10');

    // ---- consecutive entries on one line collapse ----
    GHist.Clear;
    Jump('a.pas', 10, 'b.pas', 20);
    // Clicking the same target again from the same spot: nothing new happened.
    Jump('b.pas', 20, 'b.pas', 20);
    Ok('a jump that goes nowhere adds nothing', GHist.Count = 2);

    // ---- the current entry is refreshed from the live caret ----
    // Land on b.pas:20, scroll/type your way to b.pas:26, then go Back and
    // Forward: Forward must return to 26, not to 20.
    GHist.Clear;
    Jump('a.pas', 10, 'b.pas', 20);
    GHist.UpdateCurrent(E('b.pas', 26));
    Ok('Back still goes to the origin', Back = 'a.pas:10');
    Ok('Forward returns where the caret ACTUALLY was', Fwd = 'b.pas:26');
    // A caret in a DIFFERENT file is not a fresher reading of this entry.
    GHist.UpdateCurrent(E('zzz.pas', 999));
    Ok('a foreign caret does not overwrite the entry', Back = 'a.pas:10');
    Ok('...the entry is intact', Fwd = 'b.pas:26');

    // ---- line arithmetic: insertion ----
    // AFirstLine is 0-BASED, a recorded Line is 1-based (SynEdit's own
    // convention). Inserting at 0-based 4 means "before 1-based line 5", so
    // line 5 moves and line 4 does NOT. Getting this boundary wrong is exactly
    // the bug in SynEdit's own mark shifting, which uses >= where its
    // indicator code uses >.
    GHist.Clear;
    GHist.RecordJump(E('a.pas', 4), True, E('a.pas', 5));
    GHist.Shift('a.pas', 4, 3, True);
    Ok('insert: line 4 is ABOVE the point and does not move', Back = 'a.pas:4');
    Ok('insert: line 5 is BELOW it and moves by 3', Fwd = 'a.pas:8');

    // Another file is untouched by an edit in this one.
    GHist.Clear;
    GHist.RecordJump(E('other.pas', 50), True, E('a.pas', 5));
    GHist.Shift('a.pas', 0, 10, True);
    Ok('an edit in one file leaves other files alone', Back = 'other.pas:50');

    // ---- line arithmetic: deletion ----
    // Deleting 3 lines at 0-based 4 removes 1-based lines 5,6,7.
    GHist.Clear;
    GHist.RecordJump(E('a.pas', 4), True, E('a.pas', 9));
    GHist.Shift('a.pas', 4, 3, False);
    Ok('delete: line 4 is above the block and stays', Back = 'a.pas:4');
    Ok('delete: line 9 is after it and moves up by 3', Fwd = 'a.pas:6');

    // A position INSIDE the deleted block collapses rather than disappearing:
    // dropping it would renumber the history under the user.
    GHist.Clear;
    GHist.RecordJump(E('a.pas', 1), True, E('a.pas', 6));
    GHist.Shift('a.pas', 4, 3, False);
    Ok('an entry inside the deleted block survives', GHist.Count = 2);
    Ok('...the origin is untouched', Back = 'a.pas:1');
    Ok('...and it collapsed to where the block was, line 5', Fwd = 'a.pas:5');

    // ---- Clear ----
    GHist.Clear;
    Ok('Clear empties it', GHist.Count = 0);
    Ok('...and resets the index', not GHist.CanGoBack);
  finally
    GHist.Free;
  end;

  if GCounter.Finish('NavHistorySmoke') then
    ExitCode := 1;
end.
