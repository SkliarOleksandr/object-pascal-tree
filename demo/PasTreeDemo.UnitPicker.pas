unit PasTreeDemo.UnitPicker;

{
  PasTree demo — the View Unit dialog (Ctrl+F12).

  A modal picker over the open project's units: type to filter, Enter or a
  double-click opens. Built in CODE rather than from a .dfm, for two reasons
  that are worth stating because the rest of this demo does use a .dfm: the
  dialog is ~10 controls with no designer-visible state worth keeping in a
  second file, and everything about it that can be WRONG (which units, in what
  order, what a filter keeps) lives in PasTreeDemo.UnitList, where a console
  test can reach it without a VCL form.

  What is here is presentation and the two behaviours a list cannot express:

  - each row is TWO lines, the name over its directory, drawn by hand
    (lbOwnerDrawFixed). A name-only list is unusable exactly when it matters —
    with "Uses Units" on, the closure of a real project holds `System.Types.pas`
    and `Vcl.Types.pas`, which are the same nine characters in that column.
  - "Uses Units" is enabled from a LIVE query, not from a snapshot taken when
    the dialog opened. A modal loop does not stop the host's async timer, so a
    background analysis can finish while this is on screen; snapshotting means
    "you opened it too early, close and reopen".
}

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Types,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Graphics,
  PasTreeDemo.UnitList;

type
  { What the dialog asks its host, so it needs no reference to the main form.
    UsesFiles is called only when the box is ticked; UsesReady answers "is a
    finished analysis available", polled while the dialog is open. }
  TPasUnitPickerSource = record
    ProjectFiles: TFunc<TArray<string>>;
    UsesFiles: TFunc<TArray<string>>;
    UsesReady: TFunc<Boolean>;
  end;

  TfrmUnitPicker = class(TForm)
  private
    FEdit: TEdit;
    FList: TListBox;
    FBottom: TPanel;
    FChkUses: TCheckBox;
    FStatus: TLabel;
    FBtnOK: TButton;
    FBtnCancel: TButton;
    FTimer: TTimer;
    FSource: TPasUnitPickerSource;
    FAll: TPasUnitList;       // the current source list, unfiltered
    FShown: TPasUnitList;     // what FList is showing
    FSelected: string;        // the chosen full path, '' when cancelled
    procedure BuildControls;
    procedure Rebuild;        // re-reads the source (the checkbox changed)
    procedure Refilter;       // re-applies the edit's text to FAll
    procedure EditChange(Sender: TObject);
    procedure EditKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure ListDblClick(Sender: TObject);
    procedure ListDrawItem(AControl: TWinControl; AIndex: Integer;
      ARect: TRect; AState: TOwnerDrawState);
    procedure UsesClick(Sender: TObject);
    procedure TimerTick(Sender: TObject);
    procedure OKClick(Sender: TObject);
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
  System.Math, System.UITypes;

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
  inherited CreateNew(AOwner);
  FSource := ASource;
  BuildControls;
  Rebuild;
end;

procedure TfrmUnitPicker.BuildControls;
var
  LWork: TRect;
begin
  Caption := 'View Unit';
  BorderStyle := bsSizeable;
  Position := poMainFormCenter;
  KeyPreview := True;
  Font.Name := 'Segoe UI';
  Font.Height := -12;
  // 400x800 as specified, but never taller than the monitor's WORK area: the
  // requested height is most of a 1080p screen once Windows scaling is on, and
  // a dialog whose OK button sits under the taskbar cannot be finished with
  // the mouse. Constraints keep a resize usable rather than merely possible.
  LWork := Screen.MonitorFromPoint(Mouse.CursorPos).WorkareaRect;
  ClientWidth := 400;
  ClientHeight := Min(800, LWork.Height - 80);
  Constraints.MinWidth := 320;
  Constraints.MinHeight := 240;

  FBottom := TPanel.Create(Self);
  FBottom.Parent := Self;
  FBottom.Align := alBottom;
  FBottom.Height := 41;
  FBottom.BevelOuter := bvNone;
  FBottom.Padding.SetBounds(8, 6, 8, 6);

  FBtnCancel := TButton.Create(Self);
  FBtnCancel.Parent := FBottom;
  FBtnCancel.Caption := 'Cancel';
  FBtnCancel.ModalResult := mrCancel;
  FBtnCancel.Cancel := True;
  FBtnCancel.Width := 80;
  FBtnCancel.Align := alRight;
  FBtnCancel.AlignWithMargins := True;

  FBtnOK := TButton.Create(Self);
  FBtnOK.Parent := FBottom;
  FBtnOK.Caption := 'OK';
  FBtnOK.Default := True;      // Enter opens, as asked
  FBtnOK.Width := 80;
  FBtnOK.Align := alRight;
  FBtnOK.AlignWithMargins := True;
  FBtnOK.OnClick := OKClick;

  FChkUses := TCheckBox.Create(Self);
  FChkUses.Parent := FBottom;
  FChkUses.Caption := 'Uses Units';
  FChkUses.Align := alLeft;
  FChkUses.Width := 100;
  FChkUses.AlignWithMargins := True;
  FChkUses.OnClick := UsesClick;

  FStatus := TLabel.Create(Self);
  FStatus.Parent := FBottom;
  FStatus.Align := alClient;
  FStatus.Layout := tlCenter;
  FStatus.AlignWithMargins := True;
  FStatus.EllipsisPosition := epPathEllipsis;

  FEdit := TEdit.Create(Self);
  FEdit.Parent := Self;
  FEdit.Align := alTop;
  FEdit.AlignWithMargins := True;
  FEdit.Margins.SetBounds(8, 8, 8, 4);
  FEdit.TextHint := 'Filter';
  FEdit.OnChange := EditChange;
  FEdit.OnKeyDown := EditKeyDown;

  FList := TListBox.Create(Self);
  FList.Parent := Self;
  FList.Align := alClient;
  FList.AlignWithMargins := True;
  FList.Margins.SetBounds(8, 4, 8, 4);
  FList.Style := lbOwnerDrawFixed;
  // Two text lines plus breathing room, measured from the font rather than
  // assumed, so this survives a 150% display.
  FList.ItemHeight := Abs(Font.Height) * 2 + 14;
  FList.OnDrawItem := ListDrawItem;
  FList.OnDblClick := ListDblClick;
  FList.OnClick := EditChange;   // refresh the status line's path

  ActiveControl := FEdit;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 300;
  FTimer.OnTimer := TimerTick;
  FTimer.Enabled := True;
end;

procedure TfrmUnitPicker.Rebuild;
var
  LProject, LUses: TArray<string>;
begin
  LProject := nil;
  LUses := nil;
  if Assigned(FSource.ProjectFiles) then
    LProject := FSource.ProjectFiles();
  if FChkUses.Checked and Assigned(FSource.UsesFiles) then
    LUses := FSource.UsesFiles();
  FAll := BuildUnitList(LProject, LUses, FChkUses.Checked);
  Refilter;
end;

procedure TfrmUnitPicker.Refilter;
var
  LIdx, LKeep: Integer;
  LWanted: string;
begin
  // Keep the selected file across a filter change when it survives it — the
  // list is rebuilt on every keystroke and losing the selection mid-typing is
  // what makes such a dialog feel like it is fighting back.
  LWanted := '';
  if (FList.ItemIndex >= 0) and (FList.ItemIndex <= High(FShown)) then
    LWanted := FShown[FList.ItemIndex].FullPath;
  FShown := FilterUnitList(FAll, FEdit.Text);
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    for LIdx := 0 to High(FShown) do
      FList.Items.Add(FShown[LIdx].Name);
  finally
    FList.Items.EndUpdate;
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
  FList.ItemIndex := LKeep;
  EditChange(nil);   // status line
end;

procedure TfrmUnitPicker.EditChange(Sender: TObject);
var
  LPath: string;
begin
  if Sender = FEdit then
    Refilter;
  LPath := '';
  if (FList.ItemIndex >= 0) and (FList.ItemIndex <= High(FShown)) then
    LPath := FShown[FList.ItemIndex].FullPath;
  FStatus.Caption := Format('%d of %d  %s',
    [Length(FShown), Length(FAll), LPath]);
  FBtnOK.Enabled := FList.ItemIndex >= 0;
end;

procedure TfrmUnitPicker.EditKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  // Up/Down move the LIST while the caret stays in the filter box: typing and
  // choosing are one gesture, and it is the reason focus never has to leave
  // the edit (which is where Enter has to work).
  case Key of
    VK_DOWN:
      if FList.ItemIndex < FList.Items.Count - 1 then
      begin
        FList.ItemIndex := FList.ItemIndex + 1;
        EditChange(nil);
        Key := 0;
      end;
    VK_UP:
      if FList.ItemIndex > 0 then
      begin
        FList.ItemIndex := FList.ItemIndex - 1;
        EditChange(nil);
        Key := 0;
      end;
  end;
end;

procedure TfrmUnitPicker.ListDblClick(Sender: TObject);
begin
  OKClick(Sender);
  if FSelected <> '' then
    ModalResult := mrOk;
end;

procedure TfrmUnitPicker.ListDrawItem(AControl: TWinControl; AIndex: Integer;
  ARect: TRect; AState: TOwnerDrawState);
var
  LCanvas: TCanvas;
  LTop: Integer;
begin
  if (AIndex < 0) or (AIndex > High(FShown)) then
    Exit;
  LCanvas := FList.Canvas;
  LCanvas.FillRect(ARect);
  LTop := ARect.Top + 3;
  LCanvas.Font.Style := [];
  LCanvas.TextOut(ARect.Left + 6, LTop, FShown[AIndex].Name);
  Inc(LTop, Abs(Font.Height) + 4);
  // The directory in a quieter colour — but NOT when the row is selected,
  // where the system's highlight colour is the only one guaranteed to be
  // readable against the highlight background (a fixed grey is not).
  if not (odSelected in AState) then
    LCanvas.Font.Color := clGrayText;
  LCanvas.TextOut(ARect.Left + 6, LTop, FShown[AIndex].Directory);
end;

procedure TfrmUnitPicker.UsesClick(Sender: TObject);
begin
  Rebuild;
end;

procedure TfrmUnitPicker.TimerTick(Sender: TObject);
var
  LReady: Boolean;
begin
  LReady := Assigned(FSource.UsesReady) and FSource.UsesReady();
  if FChkUses.Enabled = LReady then
    Exit;
  FChkUses.Enabled := LReady;
  if LReady then
    FChkUses.Hint := ''
  else
    FChkUses.Hint := 'Available once the project analysis has finished';
  // A finished analysis while the box was ticked-and-disabled cannot happen
  // (it can only be ticked while enabled), so nothing to rebuild here.
end;

procedure TfrmUnitPicker.OKClick(Sender: TObject);
begin
  FSelected := '';
  if (FList.ItemIndex >= 0) and (FList.ItemIndex <= High(FShown)) then
    FSelected := FShown[FList.ItemIndex].FullPath;
end;

end.
