unit PasTreeDemo.UnitPicker;

{
  PasTree demo — the View Unit dialog (Ctrl+F12).

  A modal picker over the open project's units: type to filter, Enter or a
  double-click opens. An ordinary designed form, with the same font and design
  PixelsPerInch as the main one, so the VCL scales it on a high-DPI display
  exactly as it scales the rest of the demo — a code-built form (CreateNew)
  carries the CURRENT screen's PPI, which means no scaling ever happens and
  every control comes out visibly smaller than the window that opened it.

  What the code here owns is presentation and the two behaviours a plain list
  cannot express:

  - each row is TWO lines, the name over its directory, drawn by hand
    (lbOwnerDrawFixed). A name-only list is unusable exactly when it matters —
    with "Uses Units" on, the closure of a real project holds
    `System.Types.pas` and `Vcl.Types.pas`, which are the same nine characters
    in that column.
  - "Uses Units" is enabled from a LIVE query, not from a snapshot taken when
    the dialog opened. A modal loop does not stop the host's async timer, so a
    background analysis can finish while this is on screen; snapshotting means
    "you opened it too early, close and reopen".

  What goes in the list, in what order, and what a filter keeps is NOT here —
  that is PasTreeDemo.UnitList, where a console test can reach it.
}

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Types,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls,
  Vcl.Graphics,
  PasTreeDemo.UnitList;

type
  { What the dialog asks its host, so it needs no reference to the main form.
    UsesFiles is called only when the box is ticked; UsesReady answers "is a
    finished analysis available", polled while the dialog is open. }
  TPasUnitPickerSource = record
    ProjectName: string;
    ProjectFiles: TFunc<TArray<string>>;
    UsesFiles: TFunc<TArray<string>>;
    UsesReady: TFunc<Boolean>;
  end;

  TfrmUnitPicker = class(TForm)
    edFilter: TEdit;
    lbUnits: TListBox;
    pnlButtons: TPanel;
    chkUses: TCheckBox;
    btnOK: TButton;
    btnCancel: TButton;
    sbStatus: TStatusBar;
    procedure FormShow(Sender: TObject);
    procedure edFilterChange(Sender: TObject);
    procedure edFilterKeyDown(Sender: TObject; var Key: Word;
      Shift: TShiftState);
    procedure lbUnitsClick(Sender: TObject);
    procedure lbUnitsDblClick(Sender: TObject);
    procedure lbUnitsDrawItem(AControl: TWinControl; AIndex: Integer;
      ARect: TRect; AState: TOwnerDrawState);
    procedure chkUsesClick(Sender: TObject);
    procedure btnOKClick(Sender: TObject);
  private
    FTimer: TTimer;
    FSource: TPasUnitPickerSource;
    FAll: TPasUnitList;       // the current source list, unfiltered
    FShown: TPasUnitList;     // what lbUnits is showing
    FSelected: string;        // the chosen full path, '' when cancelled
    procedure Rebuild;        // re-reads the source (the checkbox changed)
    procedure Refilter;       // re-applies the filter text to FAll
    procedure UpdateStatus;
    procedure TimerTick(Sender: TObject);
  public
    constructor CreateWith(AOwner: TComponent;
      const ASource: TPasUnitPickerSource); reintroduce;
    property Selected: string read FSelected;
  end;

{ Shows the picker modally and returns the chosen file's full path, or '' when
  it was cancelled. }
function PickUnit(AOwner: TComponent;
  const ASource: TPasUnitPickerSource): string;

implementation

uses
  System.Math, System.UITypes, System.IOUtils;

{$R *.dfm}

function PickUnit(AOwner: TComponent;
  const ASource: TPasUnitPickerSource): string;
var
  LForm: TfrmUnitPicker;
begin
  LForm := TfrmUnitPicker.CreateWith(AOwner, ASource);
  try
    LForm.ShowModal;
    Result := LForm.Selected;
  finally
    LForm.Free;
  end;
end;

constructor TfrmUnitPicker.CreateWith(AOwner: TComponent;
  const ASource: TPasUnitPickerSource);
begin
  inherited Create(AOwner);   // loads the .dfm, and with it the design PPI
  FSource := ASource;
  // Two text lines plus breathing room, measured from the font actually in
  // effect after scaling rather than left at the designed 38 — the row is the
  // one control whose height the designer cannot state in font terms.
  lbUnits.ItemHeight := Abs(Font.Height) * 2 + 14;
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 300;
  FTimer.OnTimer := TimerTick;
  FTimer.Enabled := True;
  Rebuild;
end;

procedure TfrmUnitPicker.FormShow(Sender: TObject);
begin
  // Never taller than the monitor's WORK area: the designed height is most of
  // a 1080p screen once Windows scaling is on, and a dialog whose OK button
  // sits under the taskbar cannot be finished with the mouse.
  Height := Min(Height, Screen.MonitorFromWindow(Handle).WorkareaRect.Height);
  ActiveControl := edFilter;
end;

procedure TfrmUnitPicker.Rebuild;
var
  LProject, LUses: TArray<string>;
begin
  LProject := nil;
  LUses := nil;
  if Assigned(FSource.ProjectFiles) then
    LProject := FSource.ProjectFiles();
  if chkUses.Checked and Assigned(FSource.UsesFiles) then
    LUses := FSource.UsesFiles();
  FAll := BuildUnitList(LProject, LUses, chkUses.Checked);
  Refilter;
end;

procedure TfrmUnitPicker.Refilter;
var
  LIdx, LKeep: Integer;
  LWanted: string;
begin
  // Keep the selected file across a filter change when it survives it — the
  // list is rebuilt on every keystroke, and losing the selection mid-typing is
  // what makes such a dialog feel like it is fighting back.
  LWanted := '';
  if (lbUnits.ItemIndex >= 0) and (lbUnits.ItemIndex <= High(FShown)) then
    LWanted := FShown[lbUnits.ItemIndex].FullPath;
  FShown := FilterUnitList(FAll, edFilter.Text);
  lbUnits.Items.BeginUpdate;
  try
    lbUnits.Items.Clear;
    for LIdx := 0 to High(FShown) do
      lbUnits.Items.Add(FShown[LIdx].Name);
  finally
    lbUnits.Items.EndUpdate;
  end;
  LKeep := -1;
  if LWanted <> '' then
    for LIdx := 0 to High(FShown) do
      if SameText(FShown[LIdx].FullPath, LWanted) then
      begin
        LKeep := LIdx;
        Break;
      end;
  if (LKeep < 0) and (Length(FShown) > 0) then
    LKeep := 0;
  lbUnits.ItemIndex := LKeep;
  UpdateStatus;
end;

procedure TfrmUnitPicker.UpdateStatus;
begin
  if Length(FShown) = Length(FAll) then
    sbStatus.Panels[0].Text := Format('%d units', [Length(FAll)])
  else
    sbStatus.Panels[0].Text := Format('%d of %d units',
      [Length(FShown), Length(FAll)]);
  sbStatus.Panels[1].Text := FSource.ProjectName;
  btnOK.Enabled := lbUnits.ItemIndex >= 0;
end;

procedure TfrmUnitPicker.edFilterChange(Sender: TObject);
begin
  Refilter;
end;

procedure TfrmUnitPicker.edFilterKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  // Up/Down move the LIST while the caret stays in the filter box: typing and
  // choosing are one gesture, and it is the reason focus never has to leave
  // the edit — which is where Enter has to keep working.
  case Key of
    VK_DOWN:
      if lbUnits.ItemIndex < lbUnits.Items.Count - 1 then
      begin
        lbUnits.ItemIndex := lbUnits.ItemIndex + 1;
        UpdateStatus;
        Key := 0;
      end;
    VK_UP:
      if lbUnits.ItemIndex > 0 then
      begin
        lbUnits.ItemIndex := lbUnits.ItemIndex - 1;
        UpdateStatus;
        Key := 0;
      end;
  end;
end;

procedure TfrmUnitPicker.lbUnitsClick(Sender: TObject);
begin
  UpdateStatus;
end;

procedure TfrmUnitPicker.lbUnitsDblClick(Sender: TObject);
begin
  btnOKClick(Sender);   // same path as OK, including the ModalResult
end;

procedure TfrmUnitPicker.lbUnitsDrawItem(AControl: TWinControl;
  AIndex: Integer; ARect: TRect; AState: TOwnerDrawState);
var
  LCanvas: TCanvas;
  LTop: Integer;
begin
  if (AIndex < 0) or (AIndex > High(FShown)) then
    Exit;
  LCanvas := lbUnits.Canvas;
  LCanvas.FillRect(ARect);
  LTop := ARect.Top + 3;
  LCanvas.TextOut(ARect.Left + 6, LTop, FShown[AIndex].Name);
  Inc(LTop, Abs(Font.Height) + 4);
  // The directory in a quieter colour — but NOT when the row is selected,
  // where the system's highlight text colour is the only one guaranteed to be
  // readable against the highlight background (a fixed grey is not).
  if not (odSelected in AState) then
    LCanvas.Font.Color := clGrayText;
  LCanvas.TextOut(ARect.Left + 6, LTop, FShown[AIndex].Directory);
end;

procedure TfrmUnitPicker.chkUsesClick(Sender: TObject);
begin
  Rebuild;
end;

procedure TfrmUnitPicker.TimerTick(Sender: TObject);
var
  LReady: Boolean;
begin
  LReady := Assigned(FSource.UsesReady) and FSource.UsesReady();
  if chkUses.Enabled = LReady then
    Exit;
  chkUses.Enabled := LReady;
  if LReady then
    chkUses.Hint := ''
  else
    chkUses.Hint := 'Available once the project analysis has finished';
  // A finished analysis while the box was ticked-and-disabled cannot happen
  // (it can only be ticked while enabled), so there is nothing to rebuild.
end;

procedure TfrmUnitPicker.btnOKClick(Sender: TObject);
begin
  FSelected := '';
  if (lbUnits.ItemIndex >= 0) and (lbUnits.ItemIndex <= High(FShown)) then
    FSelected := FShown[lbUnits.ItemIndex].FullPath;
  ModalResult := mrOk;
end;

end.
