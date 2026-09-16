unit PasTreeDemo.GoToPicker;

{
  PasTree demo - the Go To dialog (Ctrl+G).

  A modal picker over ONE module's outline (PasTree.Outline): every
  declaration and every routine body in source order, plus the landmarks
  (`unit`, `interface`, `uses`, each `type`/`const`/`var` word). Type to
  filter, Enter or a double-click jumps. A filter that is nothing but digits
  adds a `line N` row on top, so the same box is the go-to-line command.

  The dialog owns presentation only:

  - each row is drawn by hand (lbOwnerDrawFixed): the head word and the
    detail in a quieter colour, the name in the window text colour with the
    matched letters in bold, the section note in the quiet colour again -
    so a list of five hundred rows still reads as columns.
  - the five boxes at the bottom filter by KIND (types, vars/fields,
    consts, routines/methods, properties); the landmarks always show.
  - the row nearest ABOVE the caret is selected when the dialog opens, so
    Ctrl+G with an empty box answers "where am I" before anything is typed.
  - size and the boxes' state persist through TDemoSettings.

  What is in the list and in what order is PasTree.Outline's decision, where
  a console test can reach it; the row filter (FilterRows) is a plain
  function here for the same reason.
}

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Types,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Graphics,
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

  TfrmGoTo = class(TForm)
    edFilter: TEdit;
    lbItems: TListBox;
    pnlButtons: TPanel;
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
    procedure btnGoClick(Sender: TObject);
  private
    FEntries: TArray<TPasOutlineEntry>;
    FRows: TArray<TGoToRow>;
    FModuleFile: string;      // the module's main file (for the caret row)
    FCaretLine: Integer;
    FLineCount: Integer;      // the module's line count (line N is clamped)
    FSettings: TDemoSettings; // may be nil
    FChosen: Boolean;
    FChosenFile: string;
    FChosenLine, FChosenCol: Integer;
    FHeadWidth: Integer;      // the head-word column, measured on show
    function Kinds: TGoToKinds;
    procedure Refilter(ASelectNearCaret: Boolean);
    procedure MoveSelection(ADelta: Integer);
    procedure LoadState;
    procedure SaveState;
  public
    constructor CreateWith(AOwner: TComponent;
      const AEntries: TArray<TPasOutlineEntry>; const AModuleFile: string;
      ACaretLine, ALineCount: Integer; ASettings: TDemoSettings); reintroduce;
  end;

{ The visible rows for a filter text and a kind set, in outline order. A
  digits-only filter puts a `line N` row first (N clamped to 1..ALineCount)
  and still lists the entries whose text contains the digits. The match is a
  case-insensitive substring over the row's name column (Owner.Name, or the
  head word for a landmark). Landmarks pass the kind filter unconditionally.
  Exposed for a console test. }
function FilterRows(const AEntries: TArray<TPasOutlineEntry>;
  const AFilter: string; AKinds: TGoToKinds; ALineCount: Integer):
  TArray<TGoToRow>;

{ The name column of an entry: `Owner.Name`, or the head word alone for a
  landmark with no name (`interface`, `uses`). }
function NameColumn(const AEntry: TPasOutlineEntry): string;

{ Shows the dialog modally. True and the target when the user chose a row. }
function ShowGoTo(AOwner: TComponent;
  const AEntries: TArray<TPasOutlineEntry>; const AModuleFile: string;
  ACaretLine, ALineCount: Integer; ASettings: TDemoSettings;
  out AFile: string; out ALine, ACol: Integer): Boolean;

implementation

uses
  System.Math, System.UITypes, System.StrUtils;

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
  if IsDigits(LFilter) then
  begin
    LLine := StrToIntDef(LFilter, 0);
    if LLine < 1 then
      LLine := 1;
    if (ALineCount > 0) and (LLine > ALineCount) then
      LLine := ALineCount;
    LRow := Default(TGoToRow);
    LRow.Kind := grLine;
    LRow.LineNo := LLine;
    Result[LCount] := LRow;
    Inc(LCount);
  end;
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
      LPos := Pos(LowerCase(LFilter), LowerCase(LText));
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
  ACaretLine, ALineCount: Integer; ASettings: TDemoSettings;
  out AFile: string; out ALine, ACol: Integer): Boolean;
var
  LForm: TfrmGoTo;
begin
  LForm := TfrmGoTo.CreateWith(AOwner, AEntries, AModuleFile, ACaretLine,
    ALineCount, ASettings);
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
  ACaretLine, ALineCount: Integer; ASettings: TDemoSettings);
begin
  inherited Create(AOwner);   // loads the .dfm, and with it the design PPI
  FEntries := AEntries;
  FModuleFile := AModuleFile;
  FCaretLine := ACaretLine;
  FLineCount := ALineCount;
  FSettings := ASettings;
  // One text line plus breathing room, from the font in effect after
  // scaling - the designer cannot state a row height in font terms.
  lbItems.ItemHeight := Abs(Font.Height) + 9;
  LoadState;
end;

procedure TfrmGoTo.FormShow(Sender: TObject);
begin
  Height := Min(Height, Screen.MonitorFromWindow(Handle).WorkareaRect.Height);
  Width := Min(Width, Screen.MonitorFromWindow(Handle).WorkareaRect.Width);
  // The head column: wide enough for the longest head word actually present,
  // so names line up whatever mix of `class function` and `var` the module
  // has. Measured here, where the canvas has the scaled font.
  lbItems.Canvas.Font.Assign(lbItems.Font);
  FHeadWidth := lbItems.Canvas.TextWidth('line');
  for var LIdx := 0 to High(FEntries) do
    FHeadWidth := Max(FHeadWidth, lbItems.Canvas.TextWidth(FEntries[LIdx].Head));
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
  LBits := FSettings.ReadInt(SET_KINDS, 31);
  chkTypes.Checked := LBits and 1 <> 0;
  chkVars.Checked := LBits and 2 <> 0;
  chkConsts.Checked := LBits and 4 <> 0;
  chkRoutines.Checked := LBits and 8 <> 0;
  chkProps.Checked := LBits and 16 <> 0;
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
  Result := [];
  if chkTypes.Checked then Include(Result, okType);
  if chkVars.Checked then Include(Result, okVar);
  if chkConsts.Checked then Include(Result, okConst);
  if chkRoutines.Checked then Include(Result, okRoutine);
  if chkProps.Checked then Include(Result, okProperty);
end;

procedure TfrmGoTo.Refilter(ASelectNearCaret: Boolean);
var
  LIdx, LKeep, LKeepEntry: Integer;
begin
  // Keep the selected entry across a filter change when it survives it -
  // losing the selection mid-typing is what makes a picker feel like it is
  // fighting back. On first show the caret decides instead.
  LKeepEntry := -1;
  if (lbItems.ItemIndex >= 0) and (lbItems.ItemIndex <= High(FRows)) and
     (FRows[lbItems.ItemIndex].Kind = grEntry) then
    LKeepEntry := FRows[lbItems.ItemIndex].Entry;
  FRows := FilterRows(FEntries, edFilter.Text, Kinds, FLineCount);
  lbItems.Items.BeginUpdate;
  try
    lbItems.Items.Clear;
    for LIdx := 0 to High(FRows) do
      lbItems.Items.Add('');   // drawn from FRows, the string is unused
  finally
    lbItems.Items.EndUpdate;
  end;
  LKeep := -1;
  if ASelectNearCaret then
  begin
    // The last row at or above the caret, in the module's own file - an
    // include's rows carry other line numbers and must not compete.
    for LIdx := 0 to High(FRows) do
      if FRows[LIdx].Kind = grEntry then
        with FEntries[FRows[LIdx].Entry] do
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
end;

procedure TfrmGoTo.edFilterChange(Sender: TObject);
begin
  Refilter(False);
end;

procedure TfrmGoTo.FilterChanged(Sender: TObject);
begin
  Refilter(False);
end;

procedure TfrmGoTo.MoveSelection(ADelta: Integer);
var
  LNew: Integer;
begin
  if lbItems.Items.Count = 0 then
    Exit;
  LNew := EnsureRange(lbItems.ItemIndex + ADelta, 0, lbItems.Items.Count - 1);
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
  LPage := Max(1, lbItems.ClientHeight div Max(1, lbItems.ItemHeight) - 1);
  case Key of
    VK_DOWN: begin MoveSelection(1); Key := 0; end;
    VK_UP: begin MoveSelection(-1); Key := 0; end;
    VK_NEXT: begin MoveSelection(LPage); Key := 0; end;
    VK_PRIOR: begin MoveSelection(-LPage); Key := 0; end;
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
begin
  if (lbItems.ItemIndex < 0) or (lbItems.ItemIndex > High(FRows)) then
    Exit;
  LRow := FRows[lbItems.ItemIndex];
  case LRow.Kind of
    grLine:
      begin
        FChosenFile := FModuleFile;
        FChosenLine := LRow.LineNo;
        FChosenCol := 1;
      end;
    grEntry:
      begin
        FChosenFile := FEntries[LRow.Entry].FilePath;
        FChosenLine := FEntries[LRow.Entry].Line;
        FChosenCol := FEntries[LRow.Entry].Col;
      end;
  end;
  FChosen := True;
  ModalResult := mrOk;
end;

// The section note after the detail: `(declaration; interface section)` for
// a routine header without a body, `(interface section)` for any other
// declaration, nothing for an implementation row (its section is implied)
// or a landmark.
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
  if AEntry.Kind = okRoutine then
    Result := 'declaration; ' + Result;
  Result := '(' + Result + ')';
end;

procedure TfrmGoTo.lbItemsDrawItem(AControl: TWinControl; AIndex: Integer;
  ARect: TRect; AState: TOwnerDrawState);
var
  LCanvas: TCanvas;
  LRow: TGoToRow;
  LQuiet, LStrong: TColor;
  LX, LY: Integer;
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
  if (AIndex < 0) or (AIndex > High(FRows)) then
    Exit;
  LCanvas := lbItems.Canvas;
  LCanvas.FillRect(ARect);
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
  with FEntries[LRow.Entry] do
  begin
    // The name column is `Owner.Name` - or, for a landmark, the head word
    // itself, which then takes the head column and the match highlight.
    LName := NameColumn(FEntries[LRow.Entry]);
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
    LNote := SectionNote(FEntries[LRow.Entry]);
    if LNote <> '' then
      Put('  ' + LNote, LQuiet, False);
  end;
end;

end.
