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
    Height = 511
    Color = clAppWorkSpace
    ParentColor = False
    ExplicitHeight = 524
  end
  object splBottom: TSplitter
    Left = 0
    Top = 552
    Width = 1180
    Height = 4
    Cursor = crVSplit
    Align = alBottom
    Color = clAppWorkSpace
    ParentColor = False
    ExplicitTop = 508
  end
  object pnlTop: TPanel
    Left = 0
    Top = 0
    Width = 1180
    Height = 73
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
    object btnNavBack: TButton
      Left = 8
      Top = 40
      Width = 120
      Height = 27
      Action = NavBackAction
      Hint = 'Back (Alt+Left, or the mouse'#39's back button)'
      ShowHint = True
      TabOrder = 10
    end
    object btnNavForward: TButton
      Left = 136
      Top = 40
      Width = 120
      Height = 27
      Action = NavForwardAction
      Hint = 'Forward (Alt+Right, or the mouse'#39's forward button)'
      ShowHint = True
      TabOrder = 11
    end
    object cbConfig: TComboBox
      Left = 300
      Top = 40
      Width = 100
      Height = 23
      Style = csDropDownList
      TabOrder = 9
      OnChange = cbConfigChange
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
    object cbHighlightColor: TColorBox
      Left = 770
      Top = 9
      Width = 140
      Height = 22
      Style = [cbCustomColors]
      TabOrder = 6
      OnChange = cbHighlightColorChange
      OnGetColors = cbHighlightColorGetColors
    end
    object btnParseVcl: TButton
      Left = 662
      Top = 40
      Width = 100
      Height = 27
      Caption = 'Parse VCL'
      TabOrder = 7
      OnClick = btnParseVclClick
    end
    object btnParseFmx: TButton
      Left = 768
      Top = 40
      Width = 100
      Height = 27
      Caption = 'Parse FMX'
      TabOrder = 8
      OnClick = btnParseFmxClick
    end
  end
  object vstFiles: TVirtualStringTree
    Left = 0
    Top = 73
    Width = 260
    Height = 479
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
  object pnlBottom: TPanel
    Left = 0
    Top = 556
    Width = 1180
    Height = 164
    Align = alBottom
    BevelOuter = bvNone
    ShowCaption = False
    TabOrder = 2
    object Panel1: TPanel
      Left = 0
      Top = 0
      Width = 1180
      Height = 25
      Align = alTop
      BevelOuter = bvNone
      ShowCaption = False
      TabOrder = 0
      object chkShowErrors: TCheckBox
        Left = 8
        Top = 6
        Width = 97
        Height = 17
        Caption = 'Show Errors'
        TabOrder = 0
        OnClick = chkShowErrorsClick
      end
      object chkMemberErrors: TCheckBox
        Left = 111
        Top = 6
        Width = 210
        Height = 17
        Hint =
          'Front-end mode: also report a member after a dot that no lookup c' +
          'ould resolve. Re-analyzes the project.'
        Caption = 'Report unresolved members'
        ParentShowHint = False
        ShowHint = True
        TabOrder = 1
        OnClick = chkMemberErrorsClick
      end
    end
    object vtMessages: TVirtualStringTree
      Left = 0
      Top = 25
      Width = 1180
      Height = 139
      Align = alClient
      DefaultNodeHeight = 19
      Header.AutoSizeIndex = 0
      Header.Height = 15
      Header.MainColumn = -1
      PopupMenu = MessagesPopupMenu
      TabOrder = 1
      TreeOptions.SelectionOptions = [toRightClickSelect, toSelectNextNodeOnRemoval]
      OnDblClick = vtMessagesDblClick
      OnGetText = vtMessagesGetText
      Touch.InteractiveGestures = [igPan, igPressAndTap]
      Touch.InteractiveGestureOptions = [igoPanSingleFingerHorizontal, igoPanSingleFingerVertical, igoPanInertia, igoPanGutter, igoParentPassthrough]
      Columns = <>
    end
  end
  object pnlSrc: TPanel
    Left = 264
    Top = 73
    Width = 916
    Height = 479
    Align = alClient
    BevelOuter = bvNone
    ShowCaption = False
    TabOrder = 3
    object pgc: TPageControl
      Left = 0
      Top = 0
      Width = 916
      Height = 446
      ActivePage = tsJson
      Align = alClient
      TabOrder = 0
      object tsJson: TTabSheet
        Caption = 'AST JSON'
        TabVisible = False
        object edJson: TSynEdit
          Left = 0
          Top = 0
          Width = 908
          Height = 436
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
        end
      end
      object tsSema: TTabSheet
        Caption = 'Semantics'
        ImageIndex = 1
        TabVisible = False
        object edSema: TSynEdit
          Left = 0
          Top = 0
          Width = 908
          Height = 436
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
    object Panel2: TPanel
      Left = 0
      Top = 446
      Width = 916
      Height = 33
      Align = alBottom
      BevelOuter = bvNone
      ShowCaption = False
      TabOrder = 1
      object lblProgress: TLabel
        AlignWithMargins = True
        Left = 858
        Top = 3
        Width = 55
        Height = 27
        Align = alRight
        Alignment = taRightJustify
        Caption = '0/0 Parsed'
        Layout = tlCenter
        ExplicitHeight = 15
      end
      object btnShowASTJson: TButton
        Left = 4
        Top = 2
        Width = 101
        Height = 25
        Caption = 'Show AST Json'
        TabOrder = 0
        OnClick = btnShowASTJsonClick
      end
      object btnShowSemantics: TButton
        Left = 111
        Top = 2
        Width = 106
        Height = 25
        Caption = 'Show Semantics'
        TabOrder = 1
        OnClick = btnShowSemanticsClick
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
    object NavBackAction: TAction
      Caption = 'Back'
      OnExecute = NavBackActionExecute
      OnUpdate = NavBackActionUpdate
    end
    object NavForwardAction: TAction
      Caption = 'Forward'
      OnExecute = NavForwardActionExecute
      OnUpdate = NavForwardActionUpdate
    end
    object GotoDeclAction: TAction
      Caption = 'Go to Declaration'
      OnExecute = GotoDeclActionExecute
      OnUpdate = GotoDeclActionUpdate
    end
    object OpenFileAtCursorAction: TAction
      Caption = 'Open File at Cursor'
      Hint =
        'Opens the unit or include file named at the caret — a `uses` item, ' +
        'an {$I ...} directive, or a path in a string'
      OnExecute = OpenFileAtCursorActionExecute
      OnUpdate = OpenFileAtCursorActionUpdate
    end
    object CopyMessageAction: TAction
      Caption = 'Copy Message'
      OnExecute = CopyMessageActionExecute
      OnUpdate = CopyMessageActionUpdate
    end
    object CopyAllMessagesAction: TAction
      Caption = 'Copy All'
      OnExecute = CopyAllMessagesActionExecute
      OnUpdate = CopyAllMessagesActionUpdate
    end
  end
  object SourcePopupMenu: TPopupMenu
    Left = 548
    Top = 339
    object OpenFileAtCursor1: TMenuItem
      Action = OpenFileAtCursorAction
    end
    object OpenSep1: TMenuItem
      Caption = '-'
    end
    object Find1: TMenuItem
      Action = FindAction
    end
    object GotoImplementation1: TMenuItem
      Action = GotoImplAction
    end
    object GotoDeclaration1: TMenuItem
      Action = GotoDeclAction
    end
    object NavSep1: TMenuItem
      Caption = '-'
    end
    object NavBack1: TMenuItem
      Action = NavBackAction
    end
    object NavForward1: TMenuItem
      Action = NavForwardAction
    end
  end
  object MessagesPopupMenu: TPopupMenu
    Left = 548
    Top = 400
    object CopyMessage1: TMenuItem
      Action = CopyMessageAction
    end
    object CopyAllMessages1: TMenuItem
      Action = CopyAllMessagesAction
    end
  end
  object SynEditSearch1: TSynEditSearch
    Left = 340
    Top = 299
  end
end
