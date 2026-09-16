object frmGoTo: TfrmGoTo
  Left = 0
  Top = 0
  Caption = 'Go To'
  ClientHeight = 600
  ClientWidth = 900
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  KeyPreview = True
  Position = poMainFormCenter
  OnClose = FormClose
  OnShow = FormShow
  TextHeight = 15
  object pnlButtons: TPanel
    Left = 0
    Top = 564
    Width = 900
    Height = 36
    Align = alBottom
    BevelOuter = bvNone
    ShowCaption = False
    TabOrder = 2
    DesignSize = (
      900
      36)
    object chkTypes: TCheckBox
      Left = 8
      Top = 9
      Width = 60
      Height = 21
      Caption = 'Types'
      Checked = True
      State = cbChecked
      TabOrder = 0
      OnClick = FilterChanged
    end
    object chkVars: TCheckBox
      Left = 72
      Top = 9
      Width = 90
      Height = 21
      Caption = 'Vars / Fields'
      Checked = True
      State = cbChecked
      TabOrder = 1
      OnClick = FilterChanged
    end
    object chkConsts: TCheckBox
      Left = 168
      Top = 9
      Width = 64
      Height = 21
      Caption = 'Consts'
      Checked = True
      State = cbChecked
      TabOrder = 2
      OnClick = FilterChanged
    end
    object chkRoutines: TCheckBox
      Left = 238
      Top = 9
      Width = 76
      Height = 21
      Caption = 'Routines'
      Checked = True
      State = cbChecked
      TabOrder = 3
      OnClick = FilterChanged
    end
    object chkProps: TCheckBox
      Left = 320
      Top = 9
      Width = 84
      Height = 21
      Caption = 'Properties'
      Checked = True
      State = cbChecked
      TabOrder = 4
      OnClick = FilterChanged
    end
    object btnGo: TButton
      Left = 690
      Top = 3
      Width = 100
      Height = 27
      Anchors = [akTop, akRight]
      Caption = 'Go'
      Default = True
      TabOrder = 5
      OnClick = btnGoClick
    end
    object btnCancel: TButton
      Left = 796
      Top = 3
      Width = 100
      Height = 27
      Anchors = [akTop, akRight]
      Cancel = True
      Caption = 'Cancel'
      ModalResult = 2
      TabOrder = 6
    end
  end
  object edFilter: TEdit
    AlignWithMargins = True
    Left = 4
    Top = 4
    Width = 892
    Height = 23
    Margins.Left = 4
    Margins.Top = 4
    Margins.Right = 4
    Margins.Bottom = 2
    Align = alTop
    TabOrder = 0
    TextHint = 'Type a name, or a line number'
    OnChange = edFilterChange
    OnKeyDown = edFilterKeyDown
  end
  object lbItems: TListBox
    AlignWithMargins = True
    Left = 4
    Top = 31
    Width = 892
    Height = 531
    Margins.Left = 4
    Margins.Top = 2
    Margins.Right = 4
    Margins.Bottom = 2
    Style = lbOwnerDrawFixed
    Align = alClient
    ItemHeight = 22
    TabOrder = 1
    OnClick = lbItemsClick
    OnDblClick = lbItemsDblClick
    OnDrawItem = lbItemsDrawItem
  end
end
