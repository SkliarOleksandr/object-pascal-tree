program DemoSettingsSmoke;

{ The demo's persisted settings: the recent-projects list (order, dedup, cap,
  round-trip through the file) and the value getters.

  Worth a suite despite living in the demo, for one reason: none of this is
  checkable by looking at the running program. The list only shows itself when
  a drop-down opens, and the rules that make it useful — most-recent-first,
  one entry per project however it was spelled, a cap that does not leave a
  tail behind in the file — are exactly the ones that break silently. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.IOUtils,
  PasTreeDemo.Settings in '..\demo\PasTreeDemo.Settings.pas';

var
  GPassed, GFailed: Integer;
  GDir: string;

procedure Ok(const AName: string; ACond: Boolean);
begin
  if ACond then
    Inc(GPassed)
  else
  begin
    Inc(GFailed);
    Writeln('FAIL: ', AName);
  end;
end;

// A real file on disk, so AddRecent's existence-insensitivity and
// ExistingRecent's pruning can be told apart.
function MakeFile(const AName: string): string;
begin
  Result := TPath.Combine(GDir, AName);
  TFile.WriteAllText(Result, '{}');
end;

// Lower-cased, because re-adding an entry stores the spelling just used —
// `AddRecent(UpperCase(P))` leaves the path upper-cased, which is right (it is
// what the user typed) and would otherwise make these comparisons about case.
function Joined(const A: TArray<string>): string;
var
  LIdx: Integer;
begin
  Result := '';
  for LIdx := 0 to High(A) do
    Result := Result + LowerCase(TPath.GetFileName(A[LIdx])) + ';';
end;

var
  LSet: TDemoSettings;
  LIni, LA, LB, LC, LGone: string;
  LIdx: Integer;
begin
  GPassed := 0; GFailed := 0;
  GDir := TPath.Combine(TPath.GetTempPath, 'PasTreeDemoSettings');
  TDirectory.CreateDirectory(GDir);
  LIni := TPath.Combine(GDir, 'demo.ini');
  if TFile.Exists(LIni) then
    TFile.Delete(LIni);

  LA := MakeFile('A.dproj');
  LB := MakeFile('B.dproj');
  LC := MakeFile('C.dproj');
  LGone := TPath.Combine(GDir, 'Vanished.dproj');   // deliberately not created

  LSet := TDemoSettings.Create(LIni);
  try
    Ok('empty to start', Length(LSet.Recent) = 0);

    LSet.AddRecent(LA);
    LSet.AddRecent(LB);
    LSet.AddRecent(LC);
    Ok('most-recent-first', Joined(LSet.Recent) = 'c.dproj;b.dproj;a.dproj;');

    // Re-opening an entry MOVES it, it does not duplicate it.
    LSet.AddRecent(LA);
    Ok('re-open moves to front, no duplicate',
      Joined(LSet.Recent) = 'a.dproj;c.dproj;b.dproj;');

    // The filesystem is case-insensitive here, so a differently-cased or
    // relative spelling is the SAME project — the commonest way a list like
    // this fills up with the same entry three times.
    LSet.AddRecent(UpperCase(LB));
    Ok('case-insensitive dedup', Length(LSet.Recent) = 3);
    LSet.AddRecent(TPath.Combine(TPath.Combine(GDir, 'sub'), '..\C.dproj'));
    Ok('relative spelling dedups too', Length(LSet.Recent) = 3);

    // A missing file is REMEMBERED (it may be a disconnected share) but not
    // OFFERED. Those are two different lists on purpose.
    LSet.AddRecent(LGone);
    Ok('a missing project is still remembered', Length(LSet.Recent) = 4);
    Ok('...but not offered', Length(LSet.ExistingRecent) = 3);
    Ok('...and the offered list keeps its order',
      Joined(LSet.ExistingRecent) = 'c.dproj;b.dproj;a.dproj;');

    for LIdx := 1 to RECENT_MAX + 5 do
      LSet.AddRecent(MakeFile(Format('Bulk%d.dproj', [LIdx])));
    Ok('capped at RECENT_MAX', Length(LSet.Recent) = RECENT_MAX);

    LSet.WriteInt('Threading', 1);
    LSet.Save;
  finally
    LSet.Free;
  end;

  // Reload: the cap must have SHRUNK the file, not just the in-memory list —
  // leaving the old tail under its own keys would read straight back.
  LSet := TDemoSettings.Create(LIni);
  try
    Ok('round-trips at the cap', Length(LSet.Recent) = RECENT_MAX);
    Ok('round-trips in order',
      TPath.GetFileName(LSet.Recent[0]) = Format('Bulk%d.dproj',
        [RECENT_MAX + 5]));
    Ok('a stored value round-trips', LSet.ReadInt('Threading', 0) = 1);
    Ok('an absent value falls back', LSet.ReadInt('NoSuchKey', 42) = 42);
  finally
    LSet.Free;
  end;

  // A file that cannot be read is not an error: every getter has a default.
  LSet := TDemoSettings.Create(TPath.Combine(GDir, 'does-not-exist.ini'));
  try
    Ok('a missing .ini is empty, not fatal',
      (Length(LSet.Recent) = 0) and (LSet.ReadInt('Threading', 7) = 7));
  finally
    LSet.Free;
  end;

  TDirectory.Delete(GDir, True);
  Writeln(Format('=== DemoSettingsSmoke: %d passed, %d failed ===',
    [GPassed, GFailed]));
  if GFailed > 0 then
    ExitCode := 1;
end.
