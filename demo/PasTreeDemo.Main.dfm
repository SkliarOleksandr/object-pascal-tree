object frmMain: TfrmMain
  Left = 0
  Top = 0
  Caption = 'PasTree Demo'
  ClientHeight = 720
  ClientWidth = 1180
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  KeyPreview = True
  Position = poScreenCenter
  OnCreate = FormCreate
  OnKeyDown = FormKeyDown
  TextHeight = 15
  object pnlTop: TPanel
    Left = 0
    Top = 0
    Width = 1180
    Height = 41
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object btnOpen: TButton
      Left = 8
      Top = 7
      Width = 120
      Height = 27
      Caption = 'Open Project...'
      TabOrder = 0
      OnClick = btnOpenClick
    end
    object btnParse: TButton
      Left = 136
      Top = 7
      Width = 120
      Height = 27
      Caption = 'Run Parse (F9)'
      TabOrder = 1
      OnClick = btnParseClick
    end
    object cbPlatform: TComboBox
      Left = 300
      Top = 9
      Width = 100
      Height = 23
      Style = csDropDownList
      ItemIndex = 0
      TabOrder = 2
      Text = 'Win32'
      Items.Strings = (
        'Win32'
        'Win64')
    end
  end
  object vstFiles: TVirtualStringTree
    Left = 0
    Top = 41
    Width = 260
    Height = 524
    Align = alLeft
    TabOrder = 1
    OnChange = vstFilesChange
    OnGetText = vstFilesGetText
  end
  object splLeft: TSplitter
    Left = 260
    Top = 41
    Height = 524
    Width = 4
  end
  object mmMessages: TMemo
    Left = 0
    Top = 569
    Width = 1180
    Height = 151
    Align = alBottom
    ReadOnly = True
    ScrollBars = ssBoth
    TabOrder = 2
    WordWrap = False
  end
  object splBottom: TSplitter
    Left = 0
    Top = 565
    Width = 1180
    Height = 4
    Cursor = crVSplit
    Align = alBottom
  end
  object pgc: TPageControl
    Left = 264
    Top = 41
    Width = 916
    Height = 524
    ActivePage = tsSema
    Align = alClient
    TabOrder = 3
    object tsJson: TTabSheet
      Caption = 'AST JSON'
      object edJson: TSynEdit
        Left = 0
        Top = 0
        Width = 908
        Height = 496
        Align = alClient
        TabOrder = 0
      end
    end
    object tsSema: TTabSheet
      Caption = 'Semantics'
      ImageIndex = 1
      object edSema: TSynEdit
        Left = 0
        Top = 0
        Width = 908
        Height = 496
        Align = alClient
        TabOrder = 0
      end
    end
  end
end
