object frmUnitPicker: TfrmUnitPicker
  Left = 0
  Top = 0
  Caption = 'View Unit'
  ClientHeight = 561
  ClientWidth = 484
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  KeyPreview = True
  Position = poMainFormCenter
  OnShow = FormShow
  TextHeight = 15
  object sbStatus: TStatusBar
    Left = 0
    Top = 542
    Width = 484
    Height = 19
    Panels = <
      item
        Text = 'units'
        Width = 150
      end
      item
        Text = 'project'
        Width = 500
      end>
  end
  object pnlButtons: TPanel
    Left = 0
    Top = 506
    Width = 484
    Height = 36
    Align = alBottom
    BevelOuter = bvNone
    ShowCaption = False
    TabOrder = 2
    DesignSize = (
      484
      36)
    object chkImplicits: TCheckBox
      Left = 8
      Top = 9
      Width = 97
      Height = 21
      Caption = 'Implicit Units'
      TabOrder = 0
      OnClick = chkImplicitsClick
    end
    object btnOK: TButton
      Left = 274
      Top = 3
      Width = 100
      Height = 27
      Anchors = [akTop, akRight]
      Caption = 'OK'
      Default = True
      TabOrder = 1
      OnClick = btnOKClick
    end
    object btnCancel: TButton
      Left = 380
      Top = 3
      Width = 100
      Height = 27
      Anchors = [akTop, akRight]
      Cancel = True
      Caption = 'Cancel'
      ModalResult = 2
      TabOrder = 2
    end
  end
  object edFilter: TEdit
    AlignWithMargins = True
    Left = 4
    Top = 4
    Width = 476
    Height = 23
    Margins.Left = 4
    Margins.Top = 4
    Margins.Right = 4
    Margins.Bottom = 2
    Align = alTop
    TabOrder = 0
    TextHint = 'Filter'
    OnChange = edFilterChange
    OnKeyDown = edFilterKeyDown
  end
  object lbUnits: TListBox
    AlignWithMargins = True
    Left = 4
    Top = 31
    Width = 476
    Height = 473
    Margins.Left = 4
    Margins.Top = 2
    Margins.Right = 4
    Margins.Bottom = 2
    Style = lbOwnerDrawFixed
    Align = alClient
    ItemHeight = 38
    TabOrder = 1
    OnClick = lbUnitsClick
    OnDblClick = lbUnitsDblClick
    OnDrawItem = lbUnitsDrawItem
  end
end
