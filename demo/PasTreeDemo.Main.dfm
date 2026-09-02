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
  ShowHint = True
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  OnKeyDown = FormKeyDown
  TextHeight = 15
  object splLeft: TSplitter
    Left = 260
    Top = 73
    Width = 4
    Height = 479
    Color = clAppWorkSpace
    ParentColor = False
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
      Style = bsSplitButton
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
      Hint = 'Back (Alt+Left, or the mouse'#39's back button)'
      Action = NavBackAction
      TabOrder = 10
    end
    object btnNavForward: TButton
      Left = 136
      Top = 40
      Width = 120
      Height = 27
      Hint = 'Forward (Alt+Right, or the mouse'#39's forward button)'
      Action = NavForwardAction
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
      Selected = clScrollBar
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
    object chkIncremental: TCheckBox
      Left = 880
      Top = 44
      Width = 130
      Height = 17
      Hint =
        'Incremental reanalysis: an edit re-analyzes just that unit (millise' +
        'conds) and falls back to a rebuild that reuses the previous parse. ' +
        'Also keeps closed units' + #39' text in memory - a demoted unit canno' +
        't take either fast path.'
      Caption = 'Incremental'
      Checked = True
      ParentShowHint = False
      ShowHint = True
      State = cbChecked
      TabOrder = 13
    end
    object btnViewUnit: TButton
      Left = 918
      Top = 7
      Width = 120
      Height = 27
      Hint = 'View Unit (Ctrl+F12)'
      Action = ViewUnitAction
      ShowHint = True
      TabOrder = 12
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
    PopupMenu = FilesPopupMenu
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
    object pgcBottom: TPageControl
      Left = 0
      Top = 0
      Width = 1180
      Height = 164
      Align = alClient
      TabOrder = 0
      PopupMenu = BottomTabsPopupMenu
      OnMouseDown = pgcBottomMouseDown
      object tsMessages: TTabSheet
        Caption = 'Messages'
        object Panel1: TPanel
          Left = 0
          Top = 0
          Width = 1172
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
            Hint =
              'Show every diagnostic the analysis produced, including an unresolv' +
              'ed member after a dot. Filters this list only - nothing is re-anal' +
              'yzed.'
            Caption = 'Show Errors'
            ParentShowHint = False
            ShowHint = True
            TabOrder = 0
            OnClick = chkShowErrorsClick
          end
        end
        object vtMessages: TVirtualStringTree
          Left = 0
          Top = 25
          Width = 1172
          Height = 108
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
      object tsCoverage: TTabSheet
        Caption = 'Coverage'
        ImageIndex = 2
        TabVisible = False
        object edCoverage: TSynEdit
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
      object btnShowCoverage: TButton
        Left = 223
        Top = 2
        Width = 106
        Height = 25
        Caption = 'Test Coverage'
        TabOrder = 2
        OnClick = btnShowCoverageClick
      end
      object btnStop: TButton
        Left = 335
        Top = 2
        Width = 60
        Height = 25
        Caption = 'Stop'
        Enabled = False
        TabOrder = 3
        OnClick = btnStopClick
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
    object ViewUnitAction: TAction
      Caption = 'View Unit...'
      ShortCut = 16507
      OnExecute = ViewUnitActionExecute
      OnUpdate = ViewUnitActionUpdate
    end
    object OpenFileAtCursorAction: TAction
      Caption = 'Open File at Cursor'
      Hint =
        'Opens the unit or include file named at the caret - a `uses` item, ' +
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
    object FindReferencesAction: TAction
      Caption = 'Find References'
      OnExecute = FindReferencesActionExecute
      OnUpdate = FindReferencesActionUpdate
    end
    object RenameAction: TAction
      Caption = 'Rename...'
      Hint =
        'Renames the symbol at the caret and every resolved reference to it' +
        ' - the same identity Find References uses'
      ShortCut = 24645
      OnExecute = RenameActionExecute
      OnUpdate = RenameActionUpdate
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
    object FindReferences1: TMenuItem
      Action = FindReferencesAction
    end
    object Rename1: TMenuItem
      Action = RenameAction
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
  object FilesPopupMenu: TPopupMenu
    Left = 120
    Top = 400
    object ViewUnit1: TMenuItem
      Action = ViewUnitAction
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
  object BottomTabsPopupMenu: TPopupMenu
    Left = 616
    Top = 400
    object CloseSearchTab1: TMenuItem
      Caption = 'Close'
      OnClick = CloseSearchTabClick
    end
    object CloseAllSearchTabs1: TMenuItem
      Caption = 'Close All Search Tabs'
      OnClick = CloseAllSearchTabsClick
    end
  end
  object SynEditSearch1: TSynEditSearch
    Left = 340
    Top = 299
  end
end
