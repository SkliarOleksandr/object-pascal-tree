object frmUnitPicker: TfrmUnitPicker
  Left = 0
  Top = 0
  Caption = 'View Unit'
  ClientHeight = 800
  ClientWidth = 800
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
    Top = 781
    Width = 800
    Height = 19
    Panels = <
      item
        Text = 'units'
        Width = 220
      end
      item
        Text = 'project'
        Width = 500
      end>
  end
  object pnlButtons: TPanel
    Left = 0
    Top = 736
    Width = 800
    Height = 45
    Align = alBottom
    BevelOuter = bvNone
    ShowCaption = False
    TabOrder = 2
    object chkUses: TCheckBox
      Left = 8
      Top = 13
      Width = 140
      Height = 21
      Caption = 'Uses Units'
      TabOrder = 0
      OnClick = chkUsesClick
    end
    object btnOK: TButton
      Left = 584
      Top = 9
      Width = 100
      Height = 27
      Anchors = [akTop, akRight]
      Caption = 'OK'
      Default = True
      TabOrder = 1
      OnClick = btnOKClick
    end
    object btnCancel: TButton
      Left = 692
      Top = 9
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
    Left = 8
    Top = 8
    Width = 784
    Height = 23
    Margins.Left = 8
    Margins.Top = 8
    Margins.Right = 8
    Margins.Bottom = 4
    Align = alTop
    TabOrder = 0
    TextHint = 'Filter'
    OnChange = edFilterChange
    OnKeyDown = edFilterKeyDown
  end
  object lbUnits: TListBox
    AlignWithMargins = True
    Left = 8
    Top = 39
    Width = 784
    Height = 693
    Margins.Left = 8
    Margins.Top = 4
    Margins.Right = 8
    Margins.Bottom = 4
    Align = alClient
    ItemHeight = 38
    Style = lbOwnerDrawFixed
    TabOrder = 1
    OnClick = lbUnitsClick
    OnDblClick = lbUnitsDblClick
    OnDrawItem = lbUnitsDrawItem
  end
end
