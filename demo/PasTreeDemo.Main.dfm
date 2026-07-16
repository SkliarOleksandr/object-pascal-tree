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
  OnDestroy = FormDestroy
  OnKeyDown = FormKeyDown
  TextHeight = 15
  object splLeft: TSplitter
    Left = 260
    Top = 41
    Width = 4
    Height = 524
  end
  object splBottom: TSplitter
    Left = 0
    Top = 565
    Width = 1180
    Height = 4
    Cursor = crVSplit
    Align = alBottom
  end
  object pnlTop: TPanel
    Left = 0
    Top = 0
    Width = 1180
    Height = 41
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    ExplicitWidth = 1174
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
    object cbHighlighter: TComboBox
      Left = 412
      Top = 9
      Width = 120
      Height = 23
      Style = csDropDownList
      ItemIndex = 1
      TabOrder = 3
      Text = 'PasTree'
      OnChange = cbHighlighterChange
      Items.Strings = (
        'SynEdit'
        'PasTree')
    end
    object cbThreading: TComboBox
      Left = 544
      Top = 9
      Width = 110
      Height = 23
      Style = csDropDownList
      ItemIndex = 1
      TabOrder = 4
      Text = 'MultiThread'
      Items.Strings = (
        'SingleThread'
        'MultiThread')
    end
    object btnParseRtl: TButton
      Left = 662
      Top = 7
      Width = 100
      Height = 27
      Caption = 'Parse RTL'
      TabOrder = 5
      OnClick = btnParseRtlClick
    end
  end
  object vstFiles: TVirtualStringTree
    Left = 0
    Top = 41
    Width = 260
    Height = 524
    Align = alLeft
    DefaultNodeHeight = 19
    Header.AutoSizeIndex = 0
    Header.Height = 15
    Header.MainColumn = -1
    TabOrder = 1
    OnChange = vstFilesChange
    OnGetText = vstFilesGetText
    Touch.InteractiveGestures = [igPan, igPressAndTap]
    Touch.InteractiveGestureOptions = [igoPanSingleFingerHorizontal, igoPanSingleFingerVertical, igoPanInertia, igoPanGutter, igoParentPassthrough]
    Columns = <>
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
    ExplicitTop = 552
    ExplicitWidth = 1174
  end
  object pgc: TPageControl
    Left = 264
    Top = 41
    Width = 916
    Height = 524
    ActivePage = tsJson
    Align = alClient
    TabOrder = 3
    ExplicitWidth = 910
    ExplicitHeight = 507
    object tsJson: TTabSheet
      Caption = 'AST JSON'
      object edJson: TSynEdit
        Left = 0
        Top = 0
        Width = 908
        Height = 494
        Align = alClient
        CaseSensitive = True
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clWindowText
        Font.Height = -13
        Font.Name = 'Consolas'
        Font.Style = []
        Font.Quality = fqClearTypeNatural
        TabOrder = 0
        UseCodeFolding = True
        Gutter.Font.Charset = DEFAULT_CHARSET
        Gutter.Font.Color = clWindowText
        Gutter.Font.Height = -11
        Gutter.Font.Name = 'Consolas'
        Gutter.Font.Style = []
        Gutter.Font.Quality = fqClearTypeNatural
        Gutter.Bands = <>
        Highlighter = SynJSONSyn1
        IndentGuides.Visible = False
        IndentGuides.StructureHighlight = False
        ScrollbarAnnotations = <>
        ExplicitWidth = 902
        ExplicitHeight = 477
      end
    end
    object tsSema: TTabSheet
      Caption = 'Semantics'
      ImageIndex = 1
      object edSema: TSynEdit
        Left = 0
        Top = 0
        Width = 908
        Height = 494
        Align = alClient
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clWindowText
        Font.Height = -13
        Font.Name = 'Consolas'
        Font.Style = []
        Font.Quality = fqClearTypeNatural
        TabOrder = 0
        UseCodeFolding = False
        Gutter.Font.Charset = DEFAULT_CHARSET
        Gutter.Font.Color = clWindowText
        Gutter.Font.Height = -11
        Gutter.Font.Name = 'Consolas'
        Gutter.Font.Style = []
        Gutter.Font.Quality = fqClearTypeNatural
        Gutter.Bands = <>
        ScrollbarAnnotations = <>
      end
    end
  end
  object SynJSONSyn1: TSynJSONSyn
    Left = 532
    Top = 163
  end
  object ActionList1: TActionList
    Left = 388
    Top = 155
    object FindAction: TAction
      Caption = 'Find'
      ShortCut = 16454
      OnExecute = FindActionExecute
      OnUpdate = FindActionUpdate
    end
    object GotoImplAction: TAction
      Caption = 'Go to Implementation'
      OnExecute = GotoImplActionExecute
      OnUpdate = GotoImplActionUpdate
    end
    object GotoDeclAction: TAction
      Caption = 'Go to Declaration'
      OnExecute = GotoDeclActionExecute
      OnUpdate = GotoDeclActionUpdate
    end
  end
  object SourcePopupMenu: TPopupMenu
    Left = 548
    Top = 339
    object Find1: TMenuItem
      Action = FindAction
    end
    object GotoImplementation1: TMenuItem
      Action = GotoImplAction
    end
    object GotoDeclaration1: TMenuItem
      Action = GotoDeclAction
    end
  end
  object SynEditSearch1: TSynEditSearch
    Left = 340
    Top = 299
  end
end
