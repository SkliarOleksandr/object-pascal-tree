unit PasTreeDemo.NavHistory;

{
  PasTree demo - the Back/Forward list behind ctrl+click, Go to
  Declaration/Implementation, and the message window's double-click.

  Everything here is data: a list of visited positions, an index into it, and
  the rules for moving that index. The form keeps what needs a form - reading
  the caret, opening tabs, enabling the actions. Split this way because the
  rules have edge cases (a jump discards the forward tail; consecutive entries
  on one line collapse; positions move when the file is edited) that are
  invisible in the running program and only show up as "Back went one too far"
  three clicks later.

  Positions are a file PATH plus line/col, never a node or symbol index: every
  re-analysis rebuilds the semantic project from scratch and invalidates every
  index into it, so a history holding them would jump to garbage after the
  first keystroke.
}

interface

uses
  System.SysUtils, System.Generics.Collections;

type
  TNavHistoryEntry = record
    FilePath: string;
    Line: Integer;
    Col: Integer;
  end;

  TNavHistory = class
  private
    FEntries: TList<TNavHistoryEntry>;
    FIndex: Integer;
    function GetCount: Integer;
    procedure Push(const AEntry: TNavHistoryEntry);
  public
    constructor Create;
    destructor Destroy; override;

    procedure Clear;

    { Records a jump. AHasOrigin is False when there was nowhere to come from
      (no source tab open yet), which happens for the very first navigation of
      a session.

      The origin goes in FIRST - it is what Back returns to - and anything to
      the RIGHT of where we currently are is discarded, the conventional
      browser rule and the only one that keeps Forward meaning something. }
    procedure RecordJump(const AOrigin: TNavHistoryEntry; AHasOrigin: Boolean;
      const ATarget: TNavHistoryEntry);

    { Overwrites the entry for where we are with a fresher position - the live
      caret, which has usually moved since we landed. Called before stepping
      away, so Back-then-Forward returns to where the user actually was.
      Ignored unless it still names the same file, since a caret in a
      different tab is not a fresher reading of this entry. }
    procedure UpdateCurrent(const AEntry: TNavHistoryEntry);

    function CanGoBack: Boolean;
    function CanGoForward: Boolean;
    function GoBack(out AEntry: TNavHistoryEntry): Boolean;
    function GoForward(out AEntry: TNavHistoryEntry): Boolean;

    { Moves every recorded line in APath past an insertion or deletion.

      AFirstLine is 0-BASED and a recorded Line is 1-based - SynEdit's own
      convention, stated in TSynIndicators, and the reason the rules below look
      off by one until you know it. Inserting at AFirstLine pushes down
      everything strictly below it; deleting takes out the ACount lines
      starting at AFirstLine + 1 and pulls up everything after them.

      A position INSIDE a deleted block collapses to where the block was
      instead of being dropped. Dropping would silently renumber the history -
      Back starts landing one entry further away than the user counted - and
      "where that text used to be" is the honest answer anyway. }
    procedure Shift(const APath: string; AFirstLine, ACount: Integer;
      AInserted: Boolean);

    property Count: Integer read GetCount;   // visited positions, in order
    property Index: Integer read FIndex;
  end;

implementation

constructor TNavHistory.Create;
begin
  inherited Create;
  FEntries := TList<TNavHistoryEntry>.Create;
  FIndex := -1;
end;

destructor TNavHistory.Destroy;
begin
  FEntries.Free;
  inherited;
end;

procedure TNavHistory.Clear;
begin
  FEntries.Clear;
  FIndex := -1;
end;

function TNavHistory.GetCount: Integer;
begin
  Result := FEntries.Count;
end;

// Appends, unless it would repeat the line already on top. Repeated clicks
// around one spot would otherwise bury the history under entries that are all
// the same place.
procedure TNavHistory.Push(const AEntry: TNavHistoryEntry);
begin
  if (FEntries.Count > 0) and
     SameText(FEntries[FEntries.Count - 1].FilePath, AEntry.FilePath) and
     (FEntries[FEntries.Count - 1].Line = AEntry.Line) then
    Exit;
  FEntries.Add(AEntry);
end;

procedure TNavHistory.RecordJump(const AOrigin: TNavHistoryEntry;
  AHasOrigin: Boolean; const ATarget: TNavHistoryEntry);
begin
  while FEntries.Count > FIndex + 1 do
    FEntries.Delete(FEntries.Count - 1);
  if AHasOrigin then
    Push(AOrigin);
  Push(ATarget);
  FIndex := FEntries.Count - 1;
end;

procedure TNavHistory.UpdateCurrent(const AEntry: TNavHistoryEntry);
begin
  if (FIndex < 0) or (FIndex >= FEntries.Count) then
    Exit;
  if not SameText(FEntries[FIndex].FilePath, AEntry.FilePath) then
    Exit;
  FEntries[FIndex] := AEntry;
end;

function TNavHistory.CanGoBack: Boolean;
begin
  Result := FIndex > 0;
end;

function TNavHistory.CanGoForward: Boolean;
begin
  Result := FIndex < FEntries.Count - 1;
end;

function TNavHistory.GoBack(out AEntry: TNavHistoryEntry): Boolean;
begin
  Result := CanGoBack;
  if not Result then
    Exit;
  Dec(FIndex);
  AEntry := FEntries[FIndex];
end;

function TNavHistory.GoForward(out AEntry: TNavHistoryEntry): Boolean;
begin
  Result := CanGoForward;
  if not Result then
    Exit;
  Inc(FIndex);
  AEntry := FEntries[FIndex];
end;

procedure TNavHistory.Shift(const APath: string; AFirstLine, ACount: Integer;
  AInserted: Boolean);
var
  LIdx: Integer;
  LEntry: TNavHistoryEntry;
begin
  for LIdx := 0 to FEntries.Count - 1 do
  begin
    LEntry := FEntries[LIdx];
    if not SameText(LEntry.FilePath, APath) then
      Continue;
    if AInserted then
    begin
      if LEntry.Line <= AFirstLine then
        Continue;
      Inc(LEntry.Line, ACount);
    end
    else if LEntry.Line > AFirstLine + ACount then
      Dec(LEntry.Line, ACount)
    else if LEntry.Line > AFirstLine then
    begin
      LEntry.Line := AFirstLine + 1;
      LEntry.Col := 1;   // the column it named went with the text
    end
    else
      Continue;
    FEntries[LIdx] := LEntry;
  end;
end;

end.
