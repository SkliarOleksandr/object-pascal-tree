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
  OnResize = FormResize
  OnShow = FormShow
  TextHeight = 15
  object pnlButtons: TPanel
    Left = 0
    Top = 543
    Width = 900
    Height = 36
    Align = alBottom
    BevelOuter = bvNone
    ShowCaption = False
    TabOrder = 2
    DesignSize = (
      900
      36)
    object chkAll: TCheckBox
      Left = 8
      Top = 9
      Width = 44
      Height = 21
      Caption = 'All'
      Checked = True
      State = cbChecked
      TabOrder = 0
      OnClick = AllChanged
    end
    object chkTypes: TCheckBox
      Left = 56
      Top = 9
      Width = 60
      Height = 21
      Caption = 'Types'
      TabOrder = 1
      OnClick = FilterChanged
    end
    object chkVars: TCheckBox
      Left = 120
      Top = 9
      Width = 90
      Height = 21
      Caption = 'Vars / Fields'
      TabOrder = 2
      OnClick = FilterChanged
    end
    object chkConsts: TCheckBox
      Left = 216
      Top = 9
      Width = 64
      Height = 21
      Caption = 'Consts'
      TabOrder = 3
      OnClick = FilterChanged
    end
    object chkRoutines: TCheckBox
      Left = 286
      Top = 9
      Width = 76
      Height = 21
      Caption = 'Routines'
      TabOrder = 4
      OnClick = FilterChanged
    end
    object chkProps: TCheckBox
      Left = 368
      Top = 9
      Width = 84
      Height = 21
      Caption = 'Properties'
      TabOrder = 5
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
      TabOrder = 6
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
      TabOrder = 7
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
  object tcScope: TTabControl
    AlignWithMargins = True
    Left = 4
    Top = 31
    Width = 892
    Height = 510
    Margins.Left = 4
    Margins.Top = 4
    Margins.Right = 4
    Margins.Bottom = 2
    Align = alClient
    TabOrder = 1
    TabStop = False
    Tabs.Strings = (
      'Module'
      'Project')
    TabIndex = 0
    OnChange = tcScopeChange
    object lbItems: TListBox
      AlignWithMargins = True
      Left = 8
      Top = 28
      Width = 876
      Height = 495
      Margins.Left = 4
      Margins.Top = 2
      Margins.Right = 4
      Margins.Bottom = 4
      Style = lbVirtualOwnerDraw
      Align = alClient
      ItemHeight = 22
      TabOrder = 0
      OnClick = lbItemsClick
      OnDblClick = lbItemsDblClick
      OnDrawItem = lbItemsDrawItem
    end
  end
  object sbStatus: TStatusBar
    Left = 0
    Top = 579
    Width = 900
    Height = 21
    Panels = <>
    SimplePanel = True
  end
end
