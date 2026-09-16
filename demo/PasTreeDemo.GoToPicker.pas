unit PasTreeDemo.GoToPicker;

{
  PasTree demo - the Go To dialog (Ctrl+G).

  A modal picker with two tabs. The MODULE tab is one module's outline
  (PasTree.Outline): every declaration and every routine body in source
  order, plus the landmarks (`unit`, `interface`, `uses`, `implementation`).
  Type to filter, Enter or a double-click jumps. A filter that is nothing but
  digits adds a `line N` row on top, so the same box is the go-to-line
  command. The PROJECT tab is every declaration of every project unit
  (TPasNavigator.ProjectOutline), built lazily on the first switch; its rows
  carry no position, so the jump goes through a resolver the host supplies
  (DeclHit on the row's model and symbol, which rehydrates that one unit).

  The dialog owns presentation only:

  - each row is drawn by hand (lbVirtualOwnerDraw, so a project's fifty
    thousand rows cost nothing to list): the head word and the detail in a
    quieter colour, the name in the window text colour with the matched
    letters in bold, then the unit name (project tab) and the section note
    in the quiet colour again - so a list of five hundred rows still reads
    as columns.
  - the boxes at the bottom filter by KIND: All (the default) or a subset
    of types, vars/fields, consts, routines/methods, properties - ticking a
    kind unticks All, ticking All clears the kinds; the landmarks always
    show. The status bar counts the rows shown of the rows listed.
  - the filter box sits ABOVE the tabs: it is one box for both lists.
  - the row nearest ABOVE the caret is selected when the module tab opens,
    so Ctrl+G with an empty box answers "where am I" before anything is
    typed.
  - Ctrl+Tab switches the tab from the filter box; the filter text stays.
  - size and the boxes' state persist through TDemoSettings.

  What is in the lists and in what order is the library's decision, where a
  console test can reach it; the row filter (FilterRows) is a plain function
  here for the same reason.
}

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Types,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls,
  Vcl.Graphics,
  PasTree.Outline,
  PasTreeDemo.Settings;

type
  TGoToRowKind = (grEntry, grLine);

  { One visible row: an outline entry, or the synthetic `line N`. MatchFrom/
    MatchLen (0-based, into the row's NAME COLUMN text - see NameColumn)
    mark the filter hit to embolden; MatchLen = 0 when nothing to mark. }
  TGoToRow = record
    Kind: TGoToRowKind;
    Entry: Integer;          // index into the outline (grEntry)
    LineNo: Integer;         // the requested line (grLine)
    MatchFrom, MatchLen: Integer;
  end;

  TGoToKinds = set of TPasOutlineKind;

  { The project tab's list, asked for once, on the first switch to it. }
  TGoToProjectSource = reference to function: TArray<TPasOutlineEntry>;

  { The landing of a row that carries no position of its own (a project row:
    UnitId/Sym set, Line = 0). False when the declaration cannot be placed -
    the dialog then stays open. }
  TGoToResolve = reference to function(const AEntry: TPasOutlineEntry;
    out AFile: string; out ALine, ACol: Integer): Boolean;

  TfrmGoTo = class(TForm)
    tcScope: TTabControl;
    edFilter: TEdit;
    lbItems: TListBox;
    pnlButtons: TPanel;
    sbStatus: TStatusBar;
    chkAll: TCheckBox;
    chkTypes: TCheckBox;
    chkVars: TCheckBox;
    chkConsts: TCheckBox;
    chkRoutines: TCheckBox;
    chkProps: TCheckBox;
    btnGo: TButton;
    btnCancel: TButton;
    procedure FormShow(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure edFilterChange(Sender: TObject);
    procedure edFilterKeyDown(Sender: TObject; var Key: Word;
      Shift: TShiftState);
    procedure lbItemsClick(Sender: TObject);
    procedure lbItemsDblClick(Sender: TObject);
    procedure lbItemsDrawItem(AControl: TWinControl; AIndex: Integer;
      ARect: TRect; AState: TOwnerDrawState);
    procedure FilterChanged(Sender: TObject);
    procedure AllChanged(Sender: TObject);
    procedure btnGoClick(Sender: TObject);
    procedure tcScopeChange(Sender: TObject);
    procedure FormResize(Sender: TObject);
  private
    FModuleEntries: TArray<TPasOutlineEntry>;
    FProjectEntries: TArray<TPasOutlineEntry>;
    FProjectLoaded: Boolean;
    FProjectSource: TGoToProjectSource;   // nil = no project tab
    FResolve: TGoToResolve;
    FRows: TArray<TGoToRow>;
    FModuleFile: string;      // the module's main file (for the caret row)
    FCaretLine: Integer;
    FLineCount: Integer;      // the module's line count (line N is clamped)
    FSettings: TDemoSettings; // may be nil
    FChosen: Boolean;
    FChosenFile: string;
    FChosenLine, FChosenCol: Integer;
    FHeadWidth: Integer;      // the head-word column, measured per tab
    FLoadingState: Boolean;   // boxes being set in bulk: rules and refilter off
    function ProjectTab: Boolean;
    function Entries: TArray<TPasOutlineEntry>;
    function Kinds: TGoToKinds;
    procedure MeasureHeadColumn;
    procedure Refilter(ASelectNearCaret: Boolean);
    procedure MoveSelection(ADelta: Integer);
    procedure LoadState;
    procedure SaveState;
  public
    constructor CreateWith(AOwner: TComponent;
      const AEntries: TArray<TPasOutlineEntry>; const AModuleFile: string;
      ACaretLine, ALineCount: Integer; const AProjectName: string;
      AProjectSource: TGoToProjectSource; AResolve: TGoToResolve;
      ASettings: TDemoSettings); reintroduce;
  end;

{ The visible rows for a filter text and a kind set, in outline order. A
  digits-only filter puts a `line N` row first (N clamped to 1..ALineCount)
  and still lists the entries whose text contains the digits; ALineCount <= 0
  means "no line row" (the project tab has no line to go to). The match is a
  case-insensitive substring over the row's name column (Owner.Name, or the
  head word for a landmark). Landmarks pass the kind filter unconditionally.
  Exposed for a console test. }
function FilterRows(const AEntries: TArray<TPasOutlineEntry>;
  const AFilter: string; AKinds: TGoToKinds; ALineCount: Integer):
  TArray<TGoToRow>;

{ The name column of an entry: `Owner.Name`, or the head word alone for a
  landmark with no name (`interface`, `uses`). }
function NameColumn(const AEntry: TPasOutlineEntry): string;

{ Shows the dialog modally. True and the target when the user chose a row.
  AProjectSource nil hides the project tab; AResolve places a project row. }
function ShowGoTo(AOwner: TComponent;
  const AEntries: TArray<TPasOutlineEntry>; const AModuleFile: string;
  ACaretLine, ALineCount: Integer; const AProjectName: string;
  AProjectSource: TGoToProjectSource; AResolve: TGoToResolve;
  ASettings: TDemoSettings;
  out AFile: string; out ALine, ACol: Integer): Boolean;

implementation

uses
  System.Math, System.UITypes, System.StrUtils, System.IOUtils;

{$R *.dfm}

const
  SET_WIDTH = 'GoToWidth';
  SET_HEIGHT = 'GoToHeight';
  SET_KINDS = 'GoToKinds';   // a bit per checkbox, all set by default

  ALL_KINDS: TGoToKinds = [okType, okVar, okConst, okProperty, okRoutine];

function NameColumn(const AEntry: TPasOutlineEntry): string;
begin
  if AEntry.Name = '' then
    Exit(AEntry.Head);
  if AEntry.Owner <> '' then
    Result := AEntry.Owner + '.' + AEntry.Name
  else
    Result := AEntry.Name;
end;

function IsDigits(const AText: string): Boolean;
var
  LIdx: Integer;
begin
  Result := AText <> '';
  for LIdx := 1 to Length(AText) do
    if not CharInSet(AText[LIdx], ['0'..'9']) then
      Exit(False);
end;

function FilterRows(const AEntries: TArray<TPasOutlineEntry>;
  const AFilter: string; AKinds: TGoToKinds; ALineCount: Integer):
  TArray<TGoToRow>;
var
  LFilter, LText: string;
  LIdx, LCount, LPos, LLine: Integer;
  LRow: TGoToRow;
begin
  LFilter := Trim(AFilter);
  SetLength(Result, Length(AEntries) + 1);
  LCount := 0;
  if (ALineCount > 0) and IsDigits(LFilter) then
  begin
    LLine := StrToIntDef(LFilter, 0);
    if LLine < 1 then
      LLine := 1;
    if LLine > ALineCount then
      LLine := ALineCount;
    LRow := Default(TGoToRow);
    LRow.Kind := grLine;
    LRow.LineNo := LLine;
    Result[LCount] := LRow;
    Inc(LCount);
  end;
  LFilter := LowerCase(LFilter);
  for LIdx := 0 to High(AEntries) do
  begin
    if (AEntries[LIdx].Kind in ALL_KINDS) and
       not (AEntries[LIdx].Kind in AKinds) then
      Continue;
    LRow := Default(TGoToRow);
    LRow.Kind := grEntry;
    LRow.Entry := LIdx;
    if LFilter <> '' then
    begin
      LText := NameColumn(AEntries[LIdx]);
      LPos := Pos(LFilter, LowerCase(LText));
      if LPos = 0 then
        Continue;
      LRow.MatchFrom := LPos - 1;
      LRow.MatchLen := Length(LFilter);
    end;
    Result[LCount] := LRow;
    Inc(LCount);
  end;
  SetLength(Result, LCount);
end;

function ShowGoTo(AOwner: TComponent;
  const AEntries: TArray<TPasOutlineEntry>; const AModuleFile: string;
  ACaretLine, ALineCount: Integer; const AProjectName: string;
  AProjectSource: TGoToProjectSource; AResolve: TGoToResolve;
  ASettings: TDemoSettings;
  out AFile: string; out ALine, ACol: Integer): Boolean;
var
  LForm: TfrmGoTo;
begin
  LForm := TfrmGoTo.CreateWith(AOwner, AEntries, AModuleFile, ACaretLine,
    ALineCount, AProjectName, AProjectSource, AResolve, ASettings);
  try
    LForm.ShowModal;
    Result := LForm.FChosen;
    AFile := LForm.FChosenFile;
    ALine := LForm.FChosenLine;
    ACol := LForm.FChosenCol;
  finally
    LForm.Free;
  end;
end;

{ TfrmGoTo }

constructor TfrmGoTo.CreateWith(AOwner: TComponent;
  const AEntries: TArray<TPasOutlineEntry>; const AModuleFile: string;
  ACaretLine, ALineCount: Integer; const AProjectName: string;
  AProjectSource: TGoToProjectSource; AResolve: TGoToResolve;
  ASettings: TDemoSettings);
begin
  inherited Create(AOwner);   // loads the .dfm, and with it the design PPI
  FModuleEntries := AEntries;
  FModuleFile := AModuleFile;
  FCaretLine := ACaretLine;
  FLineCount := ALineCount;
  FProjectSource := AProjectSource;
  FResolve := AResolve;
  FSettings := ASettings;
  // The tabs are named after what they list - the file and the project -
  // so the dialog says where a chosen row can land.
  tcScope.Tabs[0] := TPath.GetFileName(AModuleFile);
  if Assigned(FProjectSource) then
  begin
    if AProjectName <> '' then
      tcScope.Tabs[1] := AProjectName
    else
      tcScope.Tabs[1] := 'Project';
  end
  else
    tcScope.Tabs.Delete(1);
  tcScope.TabIndex := 0;
  // One text line plus breathing room, from the font in effect after
  // scaling - the designer cannot state a row height in font terms.
  lbItems.ItemHeight := Abs(Font.Height) + 9;
  LoadState;
end;

function TfrmGoTo.ProjectTab: Boolean;
begin
  Result := tcScope.TabIndex = 1;
end;

function TfrmGoTo.Entries: TArray<TPasOutlineEntry>;
begin
  if not ProjectTab then
    Exit(FModuleEntries);
  if not FProjectLoaded then
  begin
    FProjectLoaded := True;
    if Assigned(FProjectSource) then
      FProjectEntries := FProjectSource();
  end;
  Result := FProjectEntries;
end;

procedure TfrmGoTo.MeasureHeadColumn;
var
  LEntries: TArray<TPasOutlineEntry>;
  LIdx: Integer;
begin
  // The head column: wide enough for the longest head word actually present,
  // so names line up whatever mix of `class function` and `var` the list
  // has. Measured here, where the canvas has the scaled font.
  lbItems.Canvas.Font.Assign(lbItems.Font);
  FHeadWidth := lbItems.Canvas.TextWidth('line');
  LEntries := Entries;
  for LIdx := 0 to High(LEntries) do
    FHeadWidth := Max(FHeadWidth, lbItems.Canvas.TextWidth(LEntries[LIdx].Head));
end;

procedure TfrmGoTo.FormShow(Sender: TObject);
begin
  Height := Min(Height, Screen.MonitorFromWindow(Handle).WorkareaRect.Height);
  Width := Min(Width, Screen.MonitorFromWindow(Handle).WorkareaRect.Width);
  MeasureHeadColumn;
  Refilter(True);
  ActiveControl := edFilter;
end;

procedure TfrmGoTo.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  SaveState;
end;

procedure TfrmGoTo.LoadState;
var
  LBits: Integer;
begin
  if FSettings = nil then
    Exit;
  Width := Max(400, FSettings.ReadInt(SET_WIDTH, Width));
  Height := Max(300, FSettings.ReadInt(SET_HEIGHT, Height));
  // Bit 32 = All. A value saved before All existed (0.32.0) has no such
  // bit: five set boxes then read as All, anything else as a real subset.
  LBits := FSettings.ReadInt(SET_KINDS, 32);
  if LBits and 31 = 31 then
    LBits := 32;
  FLoadingState := True;
  try
    chkAll.Checked := LBits and 32 <> 0;
    chkTypes.Checked := LBits and 1 <> 0;
    chkVars.Checked := LBits and 2 <> 0;
    chkConsts.Checked := LBits and 4 <> 0;
    chkRoutines.Checked := LBits and 8 <> 0;
    chkProps.Checked := LBits and 16 <> 0;
    if LBits and 63 = 0 then
      chkAll.Checked := True;
  finally
    FLoadingState := False;
  end;
end;

procedure TfrmGoTo.SaveState;
var
  LBits: Integer;
begin
  if FSettings = nil then
    Exit;
  if WindowState = wsNormal then
  begin
    FSettings.WriteInt(SET_WIDTH, Width);
    FSettings.WriteInt(SET_HEIGHT, Height);
  end;
  LBits := 0;
  if chkAll.Checked then LBits := LBits or 32;
  if chkTypes.Checked then LBits := LBits or 1;
  if chkVars.Checked then LBits := LBits or 2;
  if chkConsts.Checked then LBits := LBits or 4;
  if chkRoutines.Checked then LBits := LBits or 8;
  if chkProps.Checked then LBits := LBits or 16;
  FSettings.WriteInt(SET_KINDS, LBits);
  FSettings.Save;
end;

function TfrmGoTo.Kinds: TGoToKinds;
begin
  if chkAll.Checked then
    Exit(ALL_KINDS);
  Result := [];
  if chkTypes.Checked then Include(Result, okType);
  if chkVars.Checked then Include(Result, okVar);
  if chkConsts.Checked then Include(Result, okConst);
  if chkRoutines.Checked then Include(Result, okRoutine);
  if chkProps.Checked then Include(Result, okProperty);
end;

procedure TfrmGoTo.Refilter(ASelectNearCaret: Boolean);
var
  LEntries: TArray<TPasOutlineEntry>;
  LIdx, LKeep, LKeepEntry, LLineCount: Integer;
begin
  // Keep the selected entry across a filter change when it survives it -
  // losing the selection mid-typing is what makes a picker feel like it is
  // fighting back. On first show the caret decides instead.
  LKeepEntry := -1;
  if (lbItems.ItemIndex >= 0) and (lbItems.ItemIndex <= High(FRows)) and
     (FRows[lbItems.ItemIndex].Kind = grEntry) then
    LKeepEntry := FRows[lbItems.ItemIndex].Entry;
  LEntries := Entries;
  if ProjectTab then
    LLineCount := 0    // no `line N` row: there is no one file to go to
  else
    LLineCount := FLineCount;
  FRows := FilterRows(LEntries, edFilter.Text, Kinds, LLineCount);
  // Virtual list: the count is the whole update, every row is painted from
  // FRows on demand.
  lbItems.Count := Length(FRows);
  LKeep := -1;
  if ASelectNearCaret and not ProjectTab then
  begin
    // The last row at or above the caret, in the module's own file - an
    // include's rows carry other line numbers and must not compete.
    for LIdx := 0 to High(FRows) do
      if FRows[LIdx].Kind = grEntry then
        with LEntries[FRows[LIdx].Entry] do
          if SameText(FilePath, FModuleFile) and (Line <= FCaretLine) then
            LKeep := LIdx;
  end
  else if LKeepEntry >= 0 then
    for LIdx := 0 to High(FRows) do
      if (FRows[LIdx].Kind = grEntry) and (FRows[LIdx].Entry = LKeepEntry) then
      begin
        LKeep := LIdx;
        Break;
      end;
  if (LKeep < 0) and (Length(FRows) > 0) then
    LKeep := 0;
  lbItems.ItemIndex := LKeep;
  btnGo.Enabled := LKeep >= 0;
  // Shown of listed - the `line N` row is not an entry and is not counted.
  LIdx := Length(FRows);
  if (LIdx > 0) and (FRows[0].Kind = grLine) then
    Dec(LIdx);
  sbStatus.SimpleText := Format('  %d of %d', [LIdx, Length(LEntries)]);
end;

procedure TfrmGoTo.tcScopeChange(Sender: TObject);
begin
  // A tab switch is a new list: the old selection means nothing in it, the
  // module tab reselects by caret, the project tab starts at the top.
  lbItems.ItemIndex := -1;
  FRows := nil;
  MeasureHeadColumn;
  Refilter(True);
  ActiveControl := edFilter;
end;

// A list box repaints only the pixels a resize exposes; the `:N` column is
// anchored to the RIGHT edge, so every row must be painted again or the old
// numbers stay where the edge used to be.
procedure TfrmGoTo.FormResize(Sender: TObject);
begin
  lbItems.Invalidate;
end;

procedure TfrmGoTo.edFilterChange(Sender: TObject);
begin
  Refilter(False);
end;

// The kind boxes are All OR a subset, never both: ticking a kind unticks
// All, ticking All clears the kinds, and unticking the last kind falls back
// to All (an empty list is never what a click meant). While the saved state
// loads, the boxes are set in bulk and the rules stay out of it.
procedure TfrmGoTo.FilterChanged(Sender: TObject);
begin
  if FLoadingState then
    Exit;
  FLoadingState := True;   // a programmatic Checked change fires OnClick too
  try
    if TCheckBox(Sender).Checked then
      chkAll.Checked := False
    else if not (chkTypes.Checked or chkVars.Checked or chkConsts.Checked or
                 chkRoutines.Checked or chkProps.Checked) then
      chkAll.Checked := True;
  finally
    FLoadingState := False;
  end;
  Refilter(False);
end;

procedure TfrmGoTo.AllChanged(Sender: TObject);
begin
  if FLoadingState then
    Exit;
  FLoadingState := True;
  try
    if chkAll.Checked then
    begin
      chkTypes.Checked := False;
      chkVars.Checked := False;
      chkConsts.Checked := False;
      chkRoutines.Checked := False;
      chkProps.Checked := False;
    end
    else if not (chkTypes.Checked or chkVars.Checked or chkConsts.Checked or
                 chkRoutines.Checked or chkProps.Checked) then
      chkAll.Checked := True;   // nothing else is on: All cannot go off
  finally
    FLoadingState := False;
  end;
  Refilter(False);
end;

procedure TfrmGoTo.MoveSelection(ADelta: Integer);
var
  LNew: Integer;
begin
  if lbItems.Count = 0 then
    Exit;
  LNew := EnsureRange(lbItems.ItemIndex + ADelta, 0, lbItems.Count - 1);
  lbItems.ItemIndex := LNew;
  btnGo.Enabled := True;
end;

procedure TfrmGoTo.edFilterKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
var
  LPage: Integer;
begin
  // Up/Down/PgUp/PgDn move the LIST while the caret stays in the filter box:
  // typing and choosing are one gesture, and Enter keeps working from here.
  // Ctrl+Tab flips the tab the same way, filter text intact.
  LPage := Max(1, lbItems.ClientHeight div Max(1, lbItems.ItemHeight) - 1);
  case Key of
    VK_DOWN: begin MoveSelection(1); Key := 0; end;
    VK_UP: begin MoveSelection(-1); Key := 0; end;
    VK_NEXT: begin MoveSelection(LPage); Key := 0; end;
    VK_PRIOR: begin MoveSelection(-LPage); Key := 0; end;
    VK_TAB:
      if (ssCtrl in Shift) and (tcScope.Tabs.Count > 1) then
      begin
        tcScope.TabIndex := 1 - tcScope.TabIndex;
        tcScopeChange(tcScope);
        Key := 0;
      end;
  end;
end;

procedure TfrmGoTo.lbItemsClick(Sender: TObject);
begin
  btnGo.Enabled := lbItems.ItemIndex >= 0;
end;

procedure TfrmGoTo.lbItemsDblClick(Sender: TObject);
begin
  btnGoClick(Sender);
end;

procedure TfrmGoTo.btnGoClick(Sender: TObject);
var
  LRow: TGoToRow;
  LEntries: TArray<TPasOutlineEntry>;
begin
  if (lbItems.ItemIndex < 0) or (lbItems.ItemIndex > High(FRows)) then
    Exit;
  LRow := FRows[lbItems.ItemIndex];
  LEntries := Entries;
  case LRow.Kind of
    grLine:
      begin
        FChosenFile := FModuleFile;
        FChosenLine := LRow.LineNo;
        FChosenCol := 1;
      end;
    grEntry:
      if LEntries[LRow.Entry].UnitId >= 0 then
      begin
        // A project row: no position of its own, the host places it (and
        // rehydrates the unit if it has to) - a declaration by its symbol,
        // a unit header or an include site by its kind. A row that cannot
        // be placed keeps the dialog open rather than landing somewhere else.
        if not Assigned(FResolve) or
           not FResolve(LEntries[LRow.Entry], {out} FChosenFile,
             {out} FChosenLine, {out} FChosenCol) then
          Exit;
      end
      else
      begin
        FChosenFile := LEntries[LRow.Entry].FilePath;
        FChosenLine := LEntries[LRow.Entry].Line;
        FChosenCol := LEntries[LRow.Entry].Col;
      end;
  end;
  FChosen := True;
  ModalResult := mrOk;
end;

// The section note after the detail: `(declaration; interface section)` for
// a routine header without a body, `(interface section)` for any other
// declaration, nothing for an implementation row (its section is implied)
// or a landmark. A project row (one row per routine, never a body) reads
// `(interface section)` for a routine too.
function SectionNote(const AEntry: TPasOutlineEntry): string;
const
  NAMES: array[TPasOutlineSection] of string = ('', 'interface',
    'implementation', 'initialization', 'finalization');
begin
  Result := '';
  if not (AEntry.Kind in ALL_KINDS) or AEntry.IsImpl or
     (AEntry.Section = osNone) then
    Exit;
  Result := NAMES[AEntry.Section] + ' section';
  if (AEntry.Kind = okRoutine) and (AEntry.Sym < 0) then
    Result := 'declaration; ' + Result;
  Result := '(' + Result + ')';
end;

procedure TfrmGoTo.lbItemsDrawItem(AControl: TWinControl; AIndex: Integer;
  ARect: TRect; AState: TOwnerDrawState);
var
  LCanvas: TCanvas;
  LRow: TGoToRow;
  LEntries: TArray<TPasOutlineEntry>;
  LQuiet, LStrong: TColor;
  LX, LY, LLineRight, LSaved: Integer;
  LName, LNote: string;

  procedure Put(const AText: string; AColor: TColor; ABold: Boolean);
  begin
    if AText = '' then
      Exit;
    LCanvas.Font.Color := AColor;
    if ABold then
      LCanvas.Font.Style := [fsBold]
    else
      LCanvas.Font.Style := [];
    LCanvas.TextOut(LX, LY, AText);
    Inc(LX, LCanvas.TextWidth(AText));
  end;

begin
  LCanvas := lbItems.Canvas;
  LCanvas.FillRect(ARect);
  if (AIndex < 0) or (AIndex > High(FRows)) then
    Exit;
  LRow := FRows[AIndex];
  // A selected row keeps the system's highlight text colour for everything:
  // it is the only colour guaranteed readable on the highlight background.
  if odSelected in AState then
  begin
    LQuiet := LCanvas.Font.Color;
    LStrong := LCanvas.Font.Color;
  end
  else
  begin
    LQuiet := clGrayText;
    LStrong := clWindowText;
  end;
  LX := ARect.Left + 6;
  LY := ARect.Top + (ARect.Height - LCanvas.TextHeight('Xg')) div 2;
  if LRow.Kind = grLine then
  begin
    Put('line', LQuiet, False);
    LX := ARect.Left + 6 + FHeadWidth + 8;
    Put(IntToStr(LRow.LineNo), LStrong, True);
    Exit;
  end;
  LEntries := Entries;
  if LRow.Entry > High(LEntries) then
    Exit;
  with LEntries[LRow.Entry] do
  begin
    // The line column, right-aligned as `:N`, for a row that knows its line
    // (the module tab; a project row has no position until it is chosen).
    // Drawn FIRST, and the row text is then clipped short of it, so a long
    // detail runs out under the column instead of over it.
    LLineRight := ARect.Right;
    if Line > 0 then
    begin
      LNote := ':' + IntToStr(Line);
      LCanvas.Font.Style := [];
      LLineRight := ARect.Right - 6 - LCanvas.TextWidth(LNote);
      LX := LLineRight;
      Put(LNote, LQuiet, False);
      LX := ARect.Left + 6;
      LLineRight := LLineRight - 8;
    end;
    LSaved := SaveDC(LCanvas.Handle);
    IntersectClipRect(LCanvas.Handle, ARect.Left, ARect.Top, LLineRight,
      ARect.Bottom);
    // The name column is `Owner.Name` - or, for a landmark, the head word
    // itself, which then takes the head column and the match highlight.
    LName := NameColumn(LEntries[LRow.Entry]);
    if Name <> '' then
    begin
      Put(Head, LQuiet, False);
      LX := ARect.Left + 6 + FHeadWidth + 8;
    end;
    if LRow.MatchLen > 0 then
    begin
      Put(Copy(LName, 1, LRow.MatchFrom), LStrong, False);
      Put(Copy(LName, LRow.MatchFrom + 1, LRow.MatchLen), LStrong, True);
      Put(Copy(LName, LRow.MatchFrom + LRow.MatchLen + 1, MaxInt), LStrong,
        False);
    end
    else
      Put(LName, LStrong, False);
    if Detail <> '' then
      Put('  ' + Detail, LQuiet, False);
    // A project row says which unit it is from; the module tab's rows are
    // all from the one module the tab is named after. The unit's own header
    // row already IS that name - printing it twice read as a stutter.
    if (UnitName <> '') and (Kind <> okModule) then
      Put('  ' + UnitName, LQuiet, False);
    LNote := SectionNote(LEntries[LRow.Entry]);
    if LNote <> '' then
      Put('  ' + LNote, LQuiet, False);
    RestoreDC(LCanvas.Handle, LSaved);
  end;
end;

end.
