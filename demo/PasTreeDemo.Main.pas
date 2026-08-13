unit PasTreeDemo.Main;

{
  PasTree demo — a small VCL host that opens a Delphi project, analyzes it with
  PasTree (parse + full semantics) and shows the source (SynEdit tabs), the
  project files (VirtualTree), the AST JSON, the semantic model and diagnostics.

  The static layout lives in the form designer (PasTreeDemo.Main.dfm). Source
  tabs are created at runtime (one TSynEdit per opened file). Highlighters and
  the open dialog are created in code (non-visual). RegisterClasses (below) lets
  the statically-linked build stream the third-party controls from the .dfm.
}

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Generics.Collections,
  System.JSON, System.Diagnostics, System.Math, System.Win.Registry,
  Winapi.Windows, Winapi.Messages, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls,
  Vcl.ExtCtrls, Vcl.Dialogs, Vcl.Graphics, Vcl.Clipbrd,
  SynEdit, SynEditTypes, SynEditHighlighter, SynHighlighterJSON, SynFunc,
  SynHighlighterPas,
  VirtualTrees, VirtualTrees.Types,
  PasTree.Platforms, PasTree.Preprocessor, PasTree.Ast, PasTree.Ast.Json,
  PasTree.Parser, PasTree.Project, PasTree.DProj,
  PasTree.Sema.Diagnostics, PasTree.Sema.Model, PasTree.Sema.Builtins,
  PasTree.Sema.Types, PasTree.Sema.Resolver, PasTree.Sema.Project,
  PasTree.Sema.Nav, PasTree.Sema.Async,
  PasTree.Sema.Dump, VirtualTrees.BaseAncestorVCL, VirtualTrees.BaseTree, VirtualTrees.AncestorVCL, SynEditCodeFolding,
  PasTreeDemo.Highlighter, PasTreeDemo.Settings, PasTreeDemo.NavHistory,
  PasTreeDemo.Includes, PasTreeDemo.UnitList, PasTreeDemo.UnitPicker,
  PasTreeDemo.Coverage,
  Vcl.Menus, System.Actions, Vcl.ActnList, SynEditMiscClasses, SynEditSearch;
  // System

type
  // VirtualTree node payload: an index into FFileList (unmanaged, so the tree
  // needs no per-node finalization).
  TPasNodeData = record
    Index: Integer;
  end;
  PPasNodeData = ^TPasNodeData;

  // One message-window row. mkStatus rows (Opened project, Done: N units...)
  // are always shown; mkError rows are gated by chkShowErrors and carry a
  // navigation target (FilePath/Line/Col — resolved from the diagnostic's OWN
  // FileId at log time, which for an $I-included file is NOT the unit's main
  // file, so it must be captured here rather than re-derived at double-click
  // time). Kind will grow mkWarning/mkHint later (same navigation shape).
  TPasMsgKind = (mkStatus, mkError);
  TPasMsgRow = record
    Kind: TPasMsgKind;
    Text: string;
    FilePath: string;   // '' when the row names no source position
    Line, Col: Integer; // 0 when FilePath is ''
  end;
  { One missing unit in the closure-health summary: how many places import it,
    plus the FIRST place we did (lowest model id = discovery order, so this is
    literally where the analyzer first met the name). The summary row is
    double-clickable because of these three fields — a count alone tells you a
    library is missing but not which of your units asked for it. }
  TPasMissingUnit = record
    Count: Integer;
    FirstFile: string;
    FirstLine, FirstCol: Integer;
  end;
  // vtMessages node payload: an index into FMsgVisible (itself indexing the
  // master FMsgLog) — mirrors TPasNodeData/FFileList's own convention so a
  // managed field (string) never has to live in VST node data.
  TPasMsgNodeData = record
    Index: Integer;
  end;
  PPasMsgNodeData = ^TPasMsgNodeData;

  TfrmMain = class(TForm)
    pnlTop: TPanel;
    btnOpen: TButton;
    btnParse: TButton;
    btnParseRtl: TButton;
    cbPlatform: TComboBox;
    cbConfig: TComboBox;       // build configuration (Debug/Release/...)
    cbHighlighter: TComboBox;
    cbThreading: TComboBox;    // background-analysis "phase done/total"
    cbHighlightColor: TColorBox; // background color for "same identifier" highlight
    splLeft: TSplitter;
    vstFiles: TVirtualStringTree;
    pgc: TPageControl;
    tsJson: TTabSheet;
    edJson: TSynEdit;
    tsSema: TTabSheet;
    edSema: TSynEdit;
    tsCoverage: TTabSheet;
    edCoverage: TSynEdit;
    splBottom: TSplitter;
    SynJSONSyn1: TSynJSONSyn;
    ActionList1: TActionList;
    FindAction: TAction;
    btnNavBack: TButton;
    btnNavForward: TButton;
    NavBackAction: TAction;
    NavForwardAction: TAction;
    NavSep1: TMenuItem;
    NavBack1: TMenuItem;
    NavForward1: TMenuItem;
    GotoImplAction: TAction;
    GotoDeclAction: TAction;
    OpenFileAtCursorAction: TAction;
    OpenFileAtCursor1: TMenuItem;
    OpenSep1: TMenuItem;
    CopyMessageAction: TAction;
    CopyAllMessagesAction: TAction;
    SourcePopupMenu: TPopupMenu;
    Find1: TMenuItem;
    GotoImplementation1: TMenuItem;
    GotoDeclaration1: TMenuItem;
    MessagesPopupMenu: TPopupMenu;
    CopyMessage1: TMenuItem;
    SynEditSearch1: TSynEditSearch;
    pnlBottom: TPanel;
    Panel1: TPanel;
    chkShowErrors: TCheckBox;
    pnlSrc: TPanel;
    Panel2: TPanel;
    btnShowASTJson: TButton;
    btnShowSemantics: TButton;
    btnShowCoverage: TButton;
    lblProgress: TLabel;
    vtMessages: TVirtualStringTree;
    btnParseVcl: TButton;
    btnParseFmx: TButton;
    ViewUnitAction: TAction;
    btnViewUnit: TButton;
    FilesPopupMenu: TPopupMenu;
    ViewUnit1: TMenuItem;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure btnOpenClick(Sender: TObject);
    procedure btnParseClick(Sender: TObject);
    procedure btnParseRtlClick(Sender: TObject);
    procedure btnShowASTJsonClick(Sender: TObject);
    procedure btnShowSemanticsClick(Sender: TObject);
    procedure btnShowCoverageClick(Sender: TObject);
    procedure chkShowErrorsClick(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure vstFilesGetText(Sender: TBaseVirtualTree; Node: PVirtualNode;
      Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);
    procedure vstFilesChange(Sender: TBaseVirtualTree; Node: PVirtualNode);
    procedure vtMessagesGetText(Sender: TBaseVirtualTree; Node: PVirtualNode;
      Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);
    procedure vtMessagesDblClick(Sender: TObject);
    procedure cbConfigChange(Sender: TObject);
    procedure cbHighlighterChange(Sender: TObject);
    procedure cbHighlightColorChange(Sender: TObject);
    procedure cbHighlightColorGetColors(Sender: TCustomColorBox; Items: TStrings);
    procedure FindActionUpdate(Sender: TObject);
    procedure FindActionExecute(Sender: TObject);
    procedure GotoImplActionUpdate(Sender: TObject);
    procedure GotoImplActionExecute(Sender: TObject);
    procedure NavBackActionExecute(Sender: TObject);
    procedure NavBackActionUpdate(Sender: TObject);
    procedure NavForwardActionExecute(Sender: TObject);
    procedure NavForwardActionUpdate(Sender: TObject);
    procedure GotoDeclActionUpdate(Sender: TObject);
    procedure GotoDeclActionExecute(Sender: TObject);
    function ActiveEditor: TSynEdit;
    function NameAtCaret(AEditor: TSynEdit): string;
    function FileForName(const AName: string): string;
    function FindFileForName(const AName: string): string;
    function IncludeTargetAt(AEditor: TSynEdit; X, Y: Integer;
      out ARawFrom, ARawTo: Integer; out ATarget: TPasNavTarget): Boolean;
    procedure OpenFileAtCursorActionUpdate(Sender: TObject);
    procedure OpenFileAtCursorActionExecute(Sender: TObject);
    procedure CopyMessageActionUpdate(Sender: TObject);
    procedure CopyMessageActionExecute(Sender: TObject);
    procedure CopyAllMessagesActionUpdate(Sender: TObject);
    procedure CopyAllMessagesActionExecute(Sender: TObject);
    procedure btnParseVclClick(Sender: TObject);
    procedure btnParseFmxClick(Sender: TObject);
    procedure ViewUnitActionUpdate(Sender: TObject);
    procedure ViewUnitActionExecute(Sender: TObject);
  private
    FFileList: TStringList;  // full paths shown in the tree
    FOpenFiles: TStringList; // path -> TTabSheet (Objects)
    // Message window: FMsgLog is the full chronological history (status +
    // error rows, never filtered); FMsgVisible indexes the subset currently
    // shown in vtMessages (status rows always included, error rows gated by
    // chkShowErrors — see RebuildVisibleMessages/LogRow).
    FMsgLog: TList<TPasMsgRow>;
    FMsgVisible: TList<Integer>;
    FDProj: TPasDProj;       // Assigned only when a .dproj was opened
    FProjectDir: string;
    // The .dproj summary line, held back so it can be logged UNDER "Opened
    // project" rather than before it (the open may still fail after parsing).
    FDProjSummary: string;
    FMainSource: string;
    // The project as OPENED (after the .dpr -> .dproj redirect), so changing
    // the build configuration can re-open the same thing.
    FProjectFile: string;
    // Build configuration chosen in cbConfig; '' = the project's own default.
    // Reset on every new project, since the names are per-project.
    FConfigOverride: string;
    FPlatform: TPasPlatform;
    FSynPasHL: TSynPasSyn;   // shared SynEdit built-in highlighter (A/B compare)
    FSemaProject: TPasSemaProject; // kept alive after RunParse (navigation)
    FNav: TPasNavigator;           // go-to-declaration over FSemaProject
    FLinkTab: TObject;             // TSourceTab currently showing a link
    // Back/Forward. The list and its rules live in PasTreeDemo.NavHistory;
    // FNavBusy suppresses RECORDING while Back/Forward is itself jumping.
    FNavHistory: TNavHistory;
    FNavBusy: Boolean;
    // "Highlight other occurrences of the selected identifier" — the
    // background color, shared by every tab's own highlighter instance
    // (each set from cbHighlightColor; new tabs pick up the current value —
    // see OpenFileTab).
    FIdentHighlightColor: TColor;
    FReparseTimer: TTimer;         // debounces re-analysis after edits
    // Background (non-blocking) analysis. Opening a project and the edit-
    // debounce reanalysis run on FAsyncSession's worker thread; FAsyncTimer
    // polls its progress into lblProgress and, when it finishes, swaps the
    // built project/navigator in for the current ones (double-buffered — see
    // TPasAsyncSession). Run Parse stays synchronous and cancels this first.
    FAsyncSession: TPasAsyncSession;
    FAsyncTimer: TTimer;
    FAsyncLoud: Boolean;           // true = report diagnostics + populate views
    FAsyncStart: TStopwatch;       // wall-clock of the in-flight async build
    FLoadingFile: Boolean;         // suppresses OnChange during programmatic load
    // Guards every FNav/FSemaProject READ (ResolveAt, ActiveRoutineTarget)
    // against a real race: Analyze's own parallel passes (LoadFilesParallel/
    // CrossResolve/...) run via TParallel.&For, which — called from the MAIN
    // thread — pumps the message queue while waiting for worker threads, so
    // Application.OnIdle (and with it EVERY TAction.OnUpdate, incl. the new
    // GotoImpl/GotoDeclAction added today) can fire WHILE a background parse
    // is still writing into the very model these actions read — a proper
    // data race (TArray reallocation, half-written RefMap...), not just a
    // perf cost. This was always a latent gap (ResolveAt/ctrl+hover shared
    // it from day one) but went unnoticed since a mouse-move landing in that
    // exact window is rare; an idle-driven action re-checking many times a
    // second hits it constantly. Set for the FULL duration of Analyze.
    FAnalyzing: Boolean;
    // ExtraSearchPaths result cache: registry enumeration + validating ~140
    // candidate directories (TDirectory.Exists, one at a time — NOT the
    // parallel index SourceManager builds internally) is expensive on a
    // slow disk/AV-scanned machine, and Analyze() calls ExtraSearchPaths on
    // EVERY run — including the 500ms-debounced reanalysis after EVERY
    // edit. Recomputing that on every keystroke pause is the actual cost a
    // quick "Run Parse" click was never meant to pay repeatedly; the
    // result is static for a given platform for the whole session (the
    // installed IDE's library paths don't change), so cache it per
    // platform (FStudioRoot/registry never change at runtime either).
    FExtraSearchPathsCache: TArray<string>;
    FExtraSearchPathsPlat: Integer;   // cbPlatform.ItemIndex it was built for
    FExtraSearchPathsBuilt: Boolean;
    FAnalyzeOverhead: string;         // wrapper timings around the engine run
    // The search paths the LAST analysis ran with. Kept because Open File at
    // Cursor has to resolve a name the analysis never reached, and rebuilding
    // them per keystroke is the ~1s-per-run cost the overhead log exists to
    // catch.
    FLastSearchPaths: TArray<string>;
    // One-entry memo for FileForName. It exists for ctrl+HOVER: the mouse moves
    // many times over one `{$I ...}`, and the lookup behind it walks every
    // model's file list — 3747 of them on the real project. One entry is all the
    // pattern needs, since a hover asks the same question repeatedly.
    FNameCacheKey, FNameCacheFile: string;
    FStudioRoot: string;           // RAD Studio root (for RTL search paths)
    // Persisted demo settings (recent projects + the sticky combos), in an .ini
    // beside the executable. See PasTreeDemo.Settings.
    FSettings: TDemoSettings;
    FRecentMenu: TPopupMenu;       // the Open Project split button's drop-down
    FFindBar: TForm;                // floating find toolbar (TFindBar); lazy
    procedure ApplyHighlighterContext(AHL: TPasTreeSynHighlighter;
      const APath: string);
    procedure CloseAllTabs;
    // Navigation history — see NavigateTo.
    function CurrentNavPos(out AEntry: TNavHistoryEntry): Boolean;
    procedure NavigateTo(const APath: string; ALine, ACol: Integer);
    procedure GoToNavEntry(const AEntry: TNavHistoryEntry);
    // Called from TNavHistoryPlugin — see there and ShiftNavHistory.
    procedure ShiftNavHistory(const APath: string;
      AFirstLine, ACount: Integer; AInserted: Boolean);
    procedure AppMessage(var AMsg: TMsg; var AHandled: Boolean);
    procedure PopulateConfigCombo;
    function SelectedConfig: string;
    procedure SetupRecentMenu;
    procedure RecentMenuPopup(Sender: TObject);
    procedure RecentItemClick(Sender: TObject);
    procedure LoadSettings;
    procedure StoreSettings;
    procedure DoFindNext(const AText: string);
    // Shared by the Goto*Action Update/Execute pairs: the active source
    // tab's model + caret position, and (if AWantImpl) the implementation
    // or (else) the declaration at that position — the SAME lookup Nav.pas
    // documents as safe to call from an Update handler (its per-model index
    // is built once and cached; repeating the call in Execute is cheap).
    function ActiveRoutineTarget(AWantImpl: Boolean;
      out ATarget: TPasNavTarget): Boolean;
    procedure SetupControls;
    procedure ApplyPasTreePalette(AHL: TSynPasSyn);
    procedure EnsureSampleProject;
    function ExeDir: string;
    function ElapsedText(AMs: Int64): string;
    procedure LogMissingUnits(AMissing: TDictionary<string, TPasMissingUnit>);
    function EffectiveNamespaces(APlatform: TPasPlatform): TArray<string>;
    function StudioRoot: string;
    function ExtraSearchPaths: TArray<string>;
    procedure OpenProject(const AProjectFile: string);
    procedure PopulateTree;
    function OpenFileTab(const APath: string): TSynEdit;
    function BuildConfig(out APlatform: TPasPlatform;
      out ASearchPaths, ADefines: TArray<string>): Boolean;
    function Analyze: Boolean;
    procedure RunParse;
    procedure ReportProjectResult(AElapsedMs: Int64);
    procedure StartAsyncAnalyze(const APriorityFile: string; ALoud: Boolean);
    procedure CancelAsync;
    procedure AsyncTimerTick(Sender: TObject);
    procedure EditorChange(Sender: TObject);
    procedure ReparseTimerTick(Sender: TObject);
    procedure LogRow(AKind: TPasMsgKind; const AText, AFilePath: string;
      ALine, ACol: Integer);
    procedure Log(const AText: string);
    procedure LogError(const AFilePath: string; ALine, ACol: Integer;
      const AText: string);
    procedure RefreshFileNodes;
    procedure AdoptProjectMembers(AMainId: Integer);
    procedure ClearMessages;
    procedure RebuildVisibleMessages;
    procedure ScrollMessagesToEnd;
    function FindMainModel(out AModel: TPasSemaModel): Boolean;
    // go-to-declaration (ctrl+hover link / ctrl+click)
    function ResolveAt(AEditor: TSynEdit; X, Y: Integer;
      out ARawFrom, ARawTo: Integer; out ATarget: TPasNavTarget): Boolean;
    procedure SetLink(ATab: TObject; AFrom, ATo: Integer);
    procedure ClearLink;
    procedure EditorMouseMove(Sender: TObject; Shift: TShiftState;
      X, Y: Integer);
    procedure EditorMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure EditorKeyUp(Sender: TObject; var Key: Word;
      Shift: TShiftState);
    // "same identifier" highlight (plain name match, see
    // PasTreeDemo.Highlighter.SetSameIdentHighlight)
    procedure EditorStatusChange(Sender: TObject; Changes: TSynStatusChanges);
    function Win32UnitIndex: TDictionary<string, Boolean>;
    function IsNonWindowsUnitName(const AUnitName: string): Boolean;
    function WriteBuildPackage(const APackageFile, APackageName,
      ASourceSubDir: string): Boolean;
    procedure ParseGeneratedPackage(const APackageName, ASourceSubDir: string);
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.dfm}

type
  // A source tab that owns its editor, so we can recover the editor from the
  // tab without casts.
  TSourceTab = class(TTabSheet)
    Editor: TSynEdit;
    PasTreeHL: TPasTreeSynHighlighter; // kept even while SynEdit's is active
  public
    FilePath: string;                  // full path of the loaded file
  end;

  { Keeps the navigation history's recorded LINES pointing at the same text
    when an editor gains or loses lines.

    SynEdit already does this arithmetic for its own gutter marks, its
    indicators and its selections, and exposes the same two notifications to
    plugins — so this rides on machinery that is already correct and already
    called from the one place that knows (TCustomSynEdit.DoLinesInserted /
    DoLinesDeleted, driven by the string list's own notifications).

    A plugin rather than a TSynEditMark per entry: our history is a flat list
    of records with no per-entry object to hang a mark on, entries are dropped
    wholesale when a jump truncates the forward tail, and a mark exists to be
    DRAWN in the gutter. This wants the notification, not the object.

    The rules are copied from TSynIndicators, not from the mark shifting: the
    two disagree, and the indicator one is right. SynEdit's own comment states
    the convention — FirstLine is 0-based, a Line is 1-based — and indicators
    shift on `Line > FirstLine` while marks shift on `Mark.Line >= FirstLine`,
    which moves the line ABOVE an insertion point along with the text below it.
    Owned by the editor (TCustomSynEdit.FPlugins is an owning list). }
  TNavHistoryPlugin = class(TSynEditPlugin)
  private
    FForm: TObject;      // TfrmMain; typed loosely to avoid a forward class
    FFilePath: string;
  protected
    procedure LinesInserted(FirstLine, Count: TSynNativeInt); override;
    procedure LinesDeleted(FirstLine, Count: TSynNativeInt); override;
  public
    constructor Create(AOwner: TCustomSynEdit; AForm: TObject;
      const AFilePath: string); reintroduce;
  end;

  TNamedColor = record
    Name: string;
    Color: TColor;
  end;

  // Floating "Find" toolbar: non-modal (Show, not ShowModal) and always on
  // top (fsStayOnTop), built entirely in code (too small to earn a .dfm).
  // One instance, owned by frmMain and reused across searches. Every search
  // reads frmMain.pgc.ActivePage FRESH (see TfrmMain.DoFindNext) — moving
  // keyboard focus to this separate top-level window does not change which
  // tab is "active" in the page control, so the target editor stays correct
  // even while this toolbar has the focus.
  TFindBar = class(TForm)
  private
    FOwnerForm: TfrmMain;
    FEdit: TEdit;
    FBtn: TButton;
    procedure DoKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure BtnClick(Sender: TObject);
  public
    constructor CreateFor(AOwnerForm: TfrmMain);
    // Shows (or re-shows) the bar near AOwnerForm's top-right, pre-filling
    // AInitialText (the active editor's current selection, if any) only
    // when the box is still empty — repeated Ctrl+F keeps your last search.
    procedure PopUp(const AInitialText: string);
  end;

const
  // Pastel-ish background swatches (readable under normal black text) for
  // the "same identifier" highlight combo (cbHighlightColor) — SandyBrown
  // first/default, per request.
  IDENT_HIGHLIGHT_COLORS: array[0..9] of TNamedColor = (
    (Name: 'SandyBrown';   Color: $0060A4F4),
    (Name: 'Khaki';        Color: $008CE6F0),
    (Name: 'LightSkyBlue'; Color: $00FACE87),
    (Name: 'PaleGreen';    Color: $0098FB98),
    (Name: 'Plum';         Color: $00DDA0DD),
    (Name: 'Gold';         Color: $0000D7FF),
    (Name: 'Salmon';       Color: $007280FA),
    (Name: 'Thistle';      Color: $00D8BFD8),
    (Name: 'PowderBlue';   Color: $00E6E0B0),
    (Name: 'Wheat';        Color: $00B3DEF5)
  );

// Pascal identifier lexeme: letter/underscore, then letters/digits/
// underscores. Gates whether a text SELECTION is even eligible for the
// "same identifier" highlight — a multi-word or punctuation selection never
// matches any whole identifier token anyway (the highlighter compares the
// FULL token text), but this avoids bothering it with obvious non-identifier
// selections (whitespace, an expression, ...).
function IsPlainIdentifier(const S: string): Boolean;
var
  I: Integer;
begin
  Result := (S <> '') and CharInSet(S[1], ['A'..'Z', 'a'..'z', '_']);
  if Result then
    for I := 2 to Length(S) do
      if not CharInSet(S[I], ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
        Exit(False);
end;

constructor TFindBar.CreateFor(AOwnerForm: TfrmMain);
begin
  inherited CreateNew(AOwnerForm);
  FOwnerForm := AOwnerForm;
  BorderStyle := bsSizeToolWin;
  FormStyle := fsStayOnTop;
  Position := poDesigned;
  Caption := 'Find';
  ClientWidth := 400;
  ClientHeight := 36;
  KeyPreview := True;   // so F3/Escape are caught regardless of which child has focus
  OnKeyDown := DoKeyDown;

  FBtn := TButton.Create(Self);
  FBtn.Parent := Self;
  FBtn.Width := 100;
  FBtn.Align := alRight;
  FBtn.AlignWithMargins := True;
  FBtn.Caption := 'Find (F3)';
  FBtn.Default := True;   // Enter in FEdit triggers it (TEdit doesn't eat Enter)
  FBtn.OnClick := BtnClick;

  FEdit := TEdit.Create(Self);
  FEdit.Parent := Self;
  FEdit.Align := alClient;
  FEdit.AlignWithMargins := True;
end;

procedure TFindBar.PopUp(const AInitialText: string);
begin
  if not Visible then
  begin
    Left := FOwnerForm.Left + FOwnerForm.Width - Width - 40;
    Top := FOwnerForm.Top + 90;
  end;
  if (AInitialText <> '') and (FEdit.Text = '') then
    FEdit.Text := AInitialText;
  Show;
  BringToFront;
  FEdit.SetFocus;
  FEdit.SelectAll;
end;

procedure TFindBar.BtnClick(Sender: TObject);
begin
  FOwnerForm.DoFindNext(FEdit.Text);
end;

procedure TFindBar.DoKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
var
  LTab: TSourceTab;
begin
  case Key of
    VK_ESCAPE:
      begin
        Hide;
        Key := 0;
        // Return focus to the searched editor so typing resumes right there.
        if Assigned(FOwnerForm.pgc.ActivePage) and
           (FOwnerForm.pgc.ActivePage is TSourceTab) then
        begin
          LTab := TSourceTab(FOwnerForm.pgc.ActivePage);
          LTab.Editor.SetFocus;
        end;
      end;
    VK_F3:
      begin
        BtnClick(nil);
        Key := 0;
      end;
  end;
end;

const
  SAMPLE_DPR =
  '''
  program Sample;

  {$APPTYPE CONSOLE}

  uses
    System.SysUtils;

  type
    TMyInt = Integer;

  const
    CBYTESLEN = 8;

  var
    S: string;
    MyInt: TMyInt;
    Bytes: TBytes;
    Arr: TArray<Integer>;

  function CreateBytes(ALen: Integer): TBytes; forward;

  function CreateBytes(ALen: Integer): TBytes;
  begin
    SetLength(Result, ALen);
  end;

  begin
    S := System.sLineBreak;
    Arr := [1, 2, 3];
    MyInt := 42;
    Bytes := CreateBytes(CBYTESLEN);
    Writeln('Hello, world!');
    Readln;
  end.
  ''';

{ helpers }

// Re-indent the compact AST JSON for display (2 spaces).
function PrettyJson(const ACompact: string): string;
var
  LVal: TJSONValue;
begin
  LVal := TJSONObject.ParseJSONValue(ACompact);
  try
    if Assigned(LVal) then
      Result := LVal.Format(2)
    else
      Result := ACompact;
  finally
    LVal.Free;
  end;
end;

{ TfrmMain }

function TfrmMain.ExeDir: string;
begin
  Result := TPath.GetDirectoryName(ParamStr(0));
end;

procedure TfrmMain.FindActionExecute(Sender: TObject);
var
  LInitial: string;
begin
  if not Assigned(FFindBar) then
    FFindBar := TFindBar.CreateFor(Self);
  LInitial := '';
  if Assigned(pgc.ActivePage) and (pgc.ActivePage is TSourceTab) then
    LInitial := TSourceTab(pgc.ActivePage).Editor.SelText;
  TFindBar(FFindBar).PopUp(LInitial);
end;

procedure TfrmMain.FindActionUpdate(Sender: TObject);
begin
  // Enabled whenever a source tab is the ACTIVE one — not gated on which
  // control currently holds keyboard focus: a TTabSheet is a container, its
  // own Focused is essentially always False (the child SynEdit holds real
  // focus), so requiring it here would permanently disable this action.
  TAction(Sender).Enabled := Assigned(pgc.ActivePage) and
    (pgc.ActivePage is TSourceTab);
end;

// Finds AText forward from the caret in the CURRENTLY ACTIVE source tab,
// wrapping to the top of the document if not found before EOF. Case-
// insensitive (SynEdit's default when ssoMatchCase is omitted) — a quick-
// find bar, not the full Find/Replace dialog.
procedure TfrmMain.DoFindNext(const AText: string);
var
  LTab: TSourceTab;
  LFound: Boolean;
begin
  if (AText = '') or not Assigned(pgc.ActivePage) or
     not (pgc.ActivePage is TSourceTab) then
    Exit;
  LTab := TSourceTab(pgc.ActivePage);
  LFound := LTab.Editor.SearchReplace(AText, '', []) > 0;
  if not LFound then
    LFound := LTab.Editor.SearchReplace(AText, '', [ssoEntireScope]) > 0;
  if LFound then
    LTab.Editor.EnsureCursorPosVisible
  else
    Log('Not found: ' + AText);
end;

function TfrmMain.ActiveRoutineTarget(AWantImpl: Boolean;
  out ATarget: TPasNavTarget): Boolean;
var
  LTab: TSourceTab;
  LMid: Integer;
begin
  Result := False;
  if FAnalyzing or not Assigned(FNav) or not Assigned(pgc.ActivePage) or
     not (pgc.ActivePage is TSourceTab) then
    Exit;
  LTab := TSourceTab(pgc.ActivePage);
  LMid := FNav.ModelIdOf(LTab.FilePath);
  if LMid < 0 then
    Exit;
  if AWantImpl then
    Result := FNav.GotoImplementation(LMid, LTab.Editor.CaretY,
      LTab.Editor.CaretX, ATarget)
  else
    Result := FNav.GotoDeclaration(LMid, LTab.Editor.CaretY,
      LTab.Editor.CaretX, ATarget);
end;

// Go to implementation (Ctrl+Shift+Down): always the SAME unit/tab — Object
// Pascal never lets a routine's body live in a different unit from its
// declaration — so this only ever moves the caret in place, unlike ctrl+
// click (EditorMouseDown) which may open another tab.
procedure TfrmMain.GotoImplActionExecute(Sender: TObject);
var
  LTarget: TPasNavTarget;
begin
  if not ActiveRoutineTarget(True, {out} LTarget) then
    Exit;
  NavigateTo(LTarget.FilePath, LTarget.Line, LTarget.Col);
end;

procedure TfrmMain.GotoImplActionUpdate(Sender: TObject);
var
  LTarget: TPasNavTarget;
begin
  TAction(Sender).Enabled := ActiveRoutineTarget(True, {out} LTarget);
end;

// Go to declaration (Ctrl+Shift+Up) — the reverse direction.
procedure TfrmMain.GotoDeclActionExecute(Sender: TObject);
var
  LTarget: TPasNavTarget;
begin
  if not ActiveRoutineTarget(False, {out} LTarget) then
    Exit;
  NavigateTo(LTarget.FilePath, LTarget.Line, LTarget.Col);
end;

procedure TfrmMain.GotoDeclActionUpdate(Sender: TObject);
var
  LTarget: TPasNavTarget;
begin
  TAction(Sender).Enabled := ActiveRoutineTarget(False, {out} LTarget);
end;

{ The word under the caret, taken as a FILE or UNIT name: the maximal run of
  characters either can contain. Deliberately wider than an identifier —
  a unit name is dotted (`Vcl.Forms`), an include is `common.inc`, and a path in a
  string has separators — and deliberately stops at quotes, braces and
  whitespace, which is what keeps an $I directive's argument and a quoted
  '..\lib\x.inc' down to their file part. }
function TfrmMain.ActiveEditor: TSynEdit;
begin
  if Assigned(pgc.ActivePage) and (pgc.ActivePage is TSourceTab) then
    Result := TSourceTab(pgc.ActivePage).Editor
  else
    Result := nil;
end;

function TfrmMain.NameAtCaret(AEditor: TSynEdit): string;
const
  EXTRA = ['.', '_', '\', '/', ':', '-', '&', '~'];

  function Ok(ACh: Char): Boolean;
  begin
    Result := CharInSet(ACh, ['a'..'z', 'A'..'Z', '0'..'9']) or
      CharInSet(ACh, EXTRA);
  end;

var
  LLine: string;
  LFrom, LTo, LCaret: Integer;
begin
  Result := '';
  LLine := AEditor.LineText;
  if LLine = '' then
    Exit;
  // The caret sits BETWEEN characters; a caret just past the last character of
  // a name still means that name, so start the scan one to the left.
  LCaret := Min(Max(AEditor.CaretX, 1), Length(LLine) + 1);
  if (LCaret > Length(LLine)) or not Ok(LLine[LCaret]) then
    Dec(LCaret);
  if (LCaret < 1) or (LCaret > Length(LLine)) or not Ok(LLine[LCaret]) then
    Exit;
  LFrom := LCaret;
  while (LFrom > 1) and Ok(LLine[LFrom - 1]) do
    Dec(LFrom);
  LTo := LCaret;
  while (LTo < Length(LLine)) and Ok(LLine[LTo + 1]) do
    Inc(LTo);
  Result := Copy(LLine, LFrom, LTo - LFrom + 1);
  // A name cannot END in a dot, a dash or a tilde, and a stray one is what a
  // caret next to punctuation picks up.
  // Only the TAIL is trimmed. A leading dot is not noise: `..\lib\x.inc` is a
  // perfectly good relative path and trimming it would break exactly the case
  // an include directive is written in.
  while (Result <> '') and CharInSet(Result[Length(Result)], ['.', '-', '~']) do
    Delete(Result, Length(Result), 1);
end;

{ Delphi's Open File at Cursor, and the same three sources it accepts: a `uses`
  item, an `$I` argument and a path in a string.

  Resolution order matters and is the reverse of what looks natural: the
  ANALYSIS is asked first, because it already knows the resolved path of every
  unit AND of every included file in the closure — which is how an $I argument
  opens the right common.inc when three copies exist on different search paths, and
  how `uses Forms` opens Vcl.Forms.pas through the namespace/alias rules. Only
  then the filesystem, relative to the current file and to the project's search
  paths, which is what still works for a file the analysis never reached. }
function TfrmMain.FileForName(const AName: string): string;
begin
  if (AName <> '') and SameText(AName, FNameCacheKey) then
    Exit(FNameCacheFile);   // see the field: this is the ctrl+hover path
  Result := FindFileForName(AName);
  FNameCacheKey := AName;
  FNameCacheFile := Result;
end;

function TfrmMain.FindFileForName(const AName: string): string;
var
  LDir, LBase, LCand: string;
  LMid, LFid: Integer;
  LM: TPasSemaModel;

  // Does APath's file name match AName, with or without an extension?
  function Matches(const APath: string): Boolean;
  begin
    Result := SameText(TPath.GetFileName(APath), AName) or
      SameText(TPath.GetFileNameWithoutExtension(APath), AName);
  end;

begin
  Result := '';
  if AName = '' then
    Exit;
  // 1. Anything the analysis loaded: the models' own files first, then every
  // file their token streams came from (that second list is where includes
  // live — see TPasSemaProject.NodeSite on why an $I file is a different path).
  if Assigned(FSemaProject) then
  begin
    for LMid := 0 to FSemaProject.ModelCount - 1 do
      if Matches(FSemaProject.ModelFile(LMid)) then
        Exit(FSemaProject.ModelFile(LMid));
    for LMid := 0 to FSemaProject.ModelCount - 1 do
    begin
      LM := FSemaProject.Model(LMid);
      if LM = nil then
        Continue;
      for LFid := 0 to High(LM.Tree.Source.FileNames) do
        if Matches(LM.Tree.Source.FileNames[LFid]) then
          Exit(LM.Tree.Source.FileNames[LFid]);
    end;
  end;
  // 2. The filesystem. A bare name gets the extensions a Pascal project can
  // mean, in the order it is likely to mean them.
  LDir := '';
  if pgc.ActivePage is TSourceTab then
    LDir := TPath.GetDirectoryName(TSourceTab(pgc.ActivePage).FilePath);
  LBase := AName;
  for var LPath in [LDir] + FLastSearchPaths do
  begin
    if LPath = '' then
      Continue;
    if TPath.HasExtension(LBase) then
    begin
      LCand := TPath.Combine(LPath, LBase);
      if TFile.Exists(LCand) then
        Exit(TPath.GetFullPath(LCand));
    end
    else
      for var LExt in ['.pas', '.inc', '.dpr', '.dpk', '.dproj'] do
      begin
        LCand := TPath.Combine(LPath, LBase + LExt);
        if TFile.Exists(LCand) then
          Exit(TPath.GetFullPath(LCand));
      end;
  end;
  // 3. An absolute or already-relative path that resolves as written.
  if TFile.Exists(LBase) then
    Result := TPath.GetFullPath(LBase);
end;

procedure TfrmMain.OpenFileAtCursorActionExecute(Sender: TObject);
var
  LEditor: TSynEdit;
  LName, LFile: string;
begin
  LEditor := ActiveEditor;
  if LEditor = nil then
    Exit;
  LName := NameAtCaret(LEditor);
  LFile := FileForName(LName);
  if LFile = '' then
  begin
    // Said out loud rather than silently doing nothing: the caret is often one
    // character off the name, and a no-op looks like a broken command.
    LogRow(mkStatus, Format('Open File at Cursor: no file for "%s"', [LName]),
      '', 0, 0);
    Exit;
  end;
  NavigateTo(LFile, 1, 1);
end;

procedure TfrmMain.OpenFileAtCursorActionUpdate(Sender: TObject);
begin
  // Enabled on a NAME, not on a resolvable file: resolving walks the closure
  // and this runs on every idle. The execute path reports a miss instead.
  TAction(Sender).Enabled := (ActiveEditor <> nil) and
    (NameAtCaret(ActiveEditor) <> '');
end;

procedure TfrmMain.CopyMessageActionExecute(Sender: TObject);
var
  LData: PPasMsgNodeData;
begin
  if vtMessages.FocusedNode = nil then
    Exit;
  LData := PPasMsgNodeData(vtMessages.GetNodeData(vtMessages.FocusedNode));
  if (LData = nil) or (LData.Index < 0) or (LData.Index >= FMsgVisible.Count)
  then
    Exit;
  Clipboard.AsText := FMsgLog[FMsgVisible[LData.Index]].Text;
end;

// Only enabled while vtMessages itself has focus — Ctrl+C must not steal
// "copy" away from a focused SynEdit tab (which handles it natively as a
// text-edit shortcut) just because a message row happens to still be
// focused from an earlier click.
procedure TfrmMain.CopyMessageActionUpdate(Sender: TObject);
begin
  TAction(Sender).Enabled := vtMessages.Focused and
    Assigned(vtMessages.FocusedNode);
end;

// The WHOLE visible history, in one go — for pasting a run's log somewhere
// else. Copies what is actually on screen (FMsgVisible, i.e. honoring the
// Show Errors filter) rather than FMsgLog, so what you paste is what you see.
procedure TfrmMain.CopyAllMessagesActionExecute(Sender: TObject);
var
  LSB: TStringBuilder;
begin
  LSB := TStringBuilder.Create;
  try
    for var LIdx := 0 to FMsgVisible.Count - 1 do
      LSB.AppendLine(FMsgLog[FMsgVisible[LIdx]].Text);
    Clipboard.AsText := LSB.ToString;
  finally
    LSB.Free;
  end;
end;

procedure TfrmMain.CopyAllMessagesActionUpdate(Sender: TObject);
begin
  TAction(Sender).Enabled := FMsgVisible.Count > 0;
end;

{ The most-imported missing units, busiest first — the shortest description of
  a broken search-path setup there is. Sorted by import count because that is
  the order in which fixing them buys back closure.

  Each row carries the FIRST import site and is double-clickable, which is the
  whole point: the name says WHAT is missing, and the jump says who asked for
  it. Without it a single-site entry like `System.Internal.HelperHlpr` is a
  dead end — the F1027 rows only cover PROJECT files, and the unit that
  imported it is usually a library unit that is never listed. }
procedure TfrmMain.LogMissingUnits(AMissing: TDictionary<string,
  TPasMissingUnit>);
const
  MAX_SHOWN = 10;
var
  LNames: TStringList;
  LInfo: TPasMissingUnit;
  LText: string;
begin
  if AMissing.Count = 0 then
    Exit;
  LNames := TStringList.Create;
  try
    for var LPair in AMissing do
      // Zero-padded count as a sort key: TStringList sorts as TEXT, so '0009'
      // must not land after '0010'.
      LNames.Add(Format('%.6d|%s', [LPair.Value.Count, LPair.Key]));
    LNames.Sort;
    var LShown := 0;
    for var LI := LNames.Count - 1 downto 0 do
    begin
      if LShown >= MAX_SHOWN then
      begin
        Log(Format('    ... and %d more distinct unit(s)',
          [LNames.Count - LShown]));
        Break;
      end;
      var LParts := LNames[LI].Split(['|']);
      LText := Format('    %s import site(s): %s',
        [LParts[0].TrimLeft(['0']), LParts[1]]);
      if AMissing.TryGetValue(LParts[1], LInfo) and (LInfo.FirstFile <> '') then
        // Say the position in the text too, not only in the (invisible) row
        // payload — the line has to be readable when it is COPIED out of the
        // message window, where no amount of double-clicking is available.
        LogRow(mkStatus, LText + Format(', first at %s(%d,%d)',
          [TPath.GetFileName(LInfo.FirstFile), LInfo.FirstLine, LInfo.FirstCol]),
          LInfo.FirstFile, LInfo.FirstLine, LInfo.FirstCol)
      else
        Log(LText);
      Inc(LShown);
    end;
  finally
    LNames.Free;
  end;
end;

{ The -NS prefix list to analyze with: the .dproj's own when we have one,
  otherwise the IDE's default (PasDefaultNamespaces).

  A bare .dpr/.dpk states no namespaces, and dcc has none built in, so without
  the fallback every legacy unqualified import in untouched RTL/VCL sources is
  an F1027 -- `uses Windows, SysUtils, Classes, Graphics` in CtlPanel.pas was
  four of them, and the IDE compiles that file without complaint. An EMPTY list
  from a .dproj counts as absent too: it means we failed to read the option, not
  that the project genuinely wants zero prefixes (a real project always has
  some, or it could not compile its own RTL imports). }
function TfrmMain.EffectiveNamespaces(APlatform: TPasPlatform): TArray<string>;
begin
  if Assigned(FDProj) and (Length(FDProj.Namespaces) > 0) then
    Exit(FDProj.Namespaces);
  Result := PasDefaultNamespaces(APlatform);
end;

// Seconds with one decimal — a five-digit millisecond count is not something
// anyone reads comfortably.
function TfrmMain.ElapsedText(AMs: Int64): string;
begin
  Result := Format('%.1f s', [AMs / 1000]);
end;

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  FFileList := TStringList.Create;
  FOpenFiles := TStringList.Create;
  FMsgLog := TList<TPasMsgRow>.Create;
  FMsgVisible := TList<Integer>.Create;
  FNavHistory := TNavHistory.Create;
  // The mouse's back/forward buttons never reach a control's OnMouseDown —
  // see AppMessage.
  Application.OnMessage := AppMessage;
  FPlatform := pfWin32;
  FStudioRoot := StudioRoot;   // resolve once; RTL search paths reuse it
  // Debounces re-analysis while typing: an edit (re)starts the timer, and only
  // when it fires (the user paused) do we re-analyze to refresh navigation.
  FReparseTimer := TTimer.Create(Self);
  FReparseTimer.Enabled := False;
  FReparseTimer.Interval := 500;
  FReparseTimer.OnTimer := ReparseTimerTick;
  // Polls the background analysis (~150ms) for progress + completion.
  FAsyncTimer := TTimer.Create(Self);
  FAsyncTimer.Enabled := False;
  FAsyncTimer.Interval := 150;
  FAsyncTimer.OnTimer := AsyncTimerTick;
  FSettings := TDemoSettings.Create(DefaultSettingsFile);
  SetupControls;
  SetupRecentMenu;
  // After SetupControls, which fills the combos and picks their defaults —
  // the stored values are an override of those defaults, not a substitute.
  LoadSettings;
  EnsureSampleProject;
  // Open the bundled sample by default; OpenProject kicks off the background
  // analysis that populates the Semantics tab and navigation when it finishes.
  OpenProject(TPath.Combine(TPath.Combine(ExeDir, 'Sample'), 'Sample.dpr'));
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  // Before anything is torn down, and tolerant of failure: a read-only
  // directory must not turn closing the demo into an exception dialog.
  try
    StoreSettings;
    FSettings.Save;
  except
    on Exception do ;
  end;
  FreeAndNil(FSettings);
  CancelAsync;                 // cancel + drain the worker before tearing down
  FreeAndNil(FNav);
  FreeAndNil(FSemaProject);
  FreeAndNil(FDProj);
  Application.OnMessage := nil;   // before the form it dispatches to goes
  FNavHistory.Free;
  FMsgVisible.Free;
  FMsgLog.Free;
  FOpenFiles.Free;
  FFileList.Free;
end;

// Runtime-only control configuration (things awkward to set in the designer:
// the VST node payload/options, highlighters and code fonts).
procedure TfrmMain.SetupControls;
begin
  // Numeric ShortCut values are a pain to get right by hand in the .dfm —
  // Menus.ShortCut computes the correct encoding from the actual keys.
  GotoImplAction.ShortCut := Vcl.Menus.ShortCut(VK_DOWN, [ssCtrl, ssShift]);
  GotoDeclAction.ShortCut := Vcl.Menus.ShortCut(VK_UP, [ssCtrl, ssShift]);
  CopyMessageAction.ShortCut := Vcl.Menus.ShortCut(Ord('C'), [ssCtrl]);
  // Delphi's own key for it, and worth matching exactly: it is the command
  // people reach for when ctrl+click cannot help — an include file, or a unit
  // whose source the analysis never loaded.
  OpenFileAtCursorAction.ShortCut := Vcl.Menus.ShortCut(VK_RETURN, [ssCtrl]);
  // The conventional pair, matching every browser and IDE.
  NavBackAction.ShortCut := Vcl.Menus.ShortCut(VK_LEFT, [ssAlt]);
  NavForwardAction.ShortCut := Vcl.Menus.ShortCut(VK_RIGHT, [ssAlt]);

  vstFiles.NodeDataSize := SizeOf(TPasNodeData);
  vstFiles.Header.Options := vstFiles.Header.Options - [hoVisible];
  vstFiles.TreeOptions.PaintOptions :=
    vstFiles.TreeOptions.PaintOptions - [toShowTreeLines, toShowRoot];

  edJson.ReadOnly := True;
  edJson.Gutter.ShowLineNumbers := True;
  edJson.Font.Name := 'Consolas';
  edJson.UseCodeFolding := True;

  edSema.ReadOnly := True;
  edSema.Gutter.ShowLineNumbers := True;
  edSema.Font.Name := 'Consolas';

  // AST JSON / Semantics are lazily populated (see btnShowASTJsonClick/
  // btnShowSemanticsClick) and hidden until asked for — TabVisible keeps the
  // page usable as pgc.ActivePage without a header in the strip.
  tsJson.TabVisible := False;
  tsSema.TabVisible := False;

  vtMessages.NodeDataSize := SizeOf(TPasMsgNodeData);
  vtMessages.Header.Options := vtMessages.Header.Options - [hoVisible];
  vtMessages.TreeOptions.PaintOptions :=
    vtMessages.TreeOptions.PaintOptions - [toShowTreeLines, toShowRoot];
  vtMessages.Font.Name := 'Consolas';
  vtMessages.Font.Size := 9;

  if cbPlatform.Items.Count = 0 then
  begin
    cbPlatform.Items.Add('Win32');
    cbPlatform.Items.Add('Win64');
  end;
  cbPlatform.ItemIndex := 0;

  // Shared across every tab when "SynEdit" is selected — TSynPasSyn is a
  // stateless-per-call highlighter (unlike TPasTreeSynHighlighter, which
  // caches one buffer's tokenization), so one instance is safe to reuse.
  FSynPasHL := TSynPasSyn.Create(Self);
  ApplyPasTreePalette(FSynPasHL);
  if cbHighlighter.Items.Count = 0 then
  begin
    cbHighlighter.Items.Add('SynEdit');
    cbHighlighter.Items.Add('PasTree');
  end;
  cbHighlighter.ItemIndex := 1; // PasTree by default

  if cbThreading.Items.Count = 0 then
  begin
    cbThreading.Items.Add('SingleThread');
    cbThreading.Items.Add('MultiThread');
  end;
  cbThreading.ItemIndex := 1; // MultiThread by default

  FIdentHighlightColor := IDENT_HIGHLIGHT_COLORS[0].Color; // SandyBrown
  cbHighlightColor.Selected := FIdentHighlightColor;
end;

// Re-colors SynEdit's built-in highlighter with PasTreeDemo.Highlighter's own
// palette (PAS_* constants), so switching the combo compares RECOGNITION
// (which words/tokens get flagged) instead of two unrelated color schemes.
// TSynPasSyn distinguishes a few things ours doesn't (Float/Hex split from
// Number, Char split from String, a separate Type attribute for built-in
// type names) — those are folded into the nearest matching PasTree color so
// nothing stands out that our highlighter wouldn't also color that way.
procedure TfrmMain.ApplyPasTreePalette(AHL: TSynPasSyn);
begin
  AHL.CommentAttri.Foreground := PAS_COMMENT_COLOR;
  AHL.CommentAttri.Style := PAS_COMMENT_STYLE;
  AHL.DirectiveAttri.Foreground := PAS_DIRECTIVE_COLOR;
  AHL.DirectiveAttri.Style := PAS_DIRECTIVE_STYLE;
  AHL.KeyAttri.Foreground := PAS_KEYWORD_COLOR;
  AHL.KeyAttri.Style := PAS_KEYWORD_STYLE;
  AHL.StringAttri.Foreground := PAS_STRING_COLOR;
  AHL.CharAttri.Foreground := PAS_STRING_COLOR;
  AHL.NumberAttri.Foreground := PAS_NUMBER_COLOR;
  AHL.FloatAttri.Foreground := PAS_NUMBER_COLOR;
  AHL.HexAttri.Foreground := PAS_NUMBER_COLOR;
  AHL.AsmAttri.Background := PAS_ASM_BACKGROUND;
  // Ours never singles out built-in type names — match IdentifierAttri so
  // TypeAttri doesn't introduce a distinction our highlighter doesn't make.
  AHL.TypeAttri.Foreground := AHL.IdentifierAttri.Foreground;
  AHL.TypeAttri.Style := AHL.IdentifierAttri.Style;
end;

procedure TfrmMain.EnsureSampleProject;
var
  LDir, LDpr: string;
begin
  LDir := TPath.Combine(ExeDir, 'Sample');
  LDpr := TPath.Combine(LDir, 'Sample.dpr');
  if not TDirectory.Exists(LDir) then
    TDirectory.CreateDirectory(LDir);
  if not TFile.Exists(LDpr) then
    TFile.WriteAllText(LDpr, SAMPLE_DPR, TEncoding.UTF8);
end;

// Appends one row to the master log and, if it should be visible right now
// (status rows always; error rows only while chkShowErrors is checked),
// adds a real VST node for it — mirrors PopulateTree's own AddChild+
// GetNodeData convention (an Integer index in node data, never a managed
// string) rather than a virtual RootNodeCount+OnInitNode scheme.
procedure TfrmMain.LogRow(AKind: TPasMsgKind; const AText, AFilePath: string;
  ALine, ACol: Integer);
var
  LRow: TPasMsgRow;
  LNode: PVirtualNode;
begin
  LRow.Kind := AKind;
  LRow.Text := AText;
  LRow.FilePath := AFilePath;
  LRow.Line := ALine;
  LRow.Col := ACol;
  FMsgLog.Add(LRow);
  if (AKind = mkStatus) or chkShowErrors.Checked then
  begin
    FMsgVisible.Add(FMsgLog.Count - 1);
    LNode := vtMessages.AddChild(nil);
    PPasMsgNodeData(vtMessages.GetNodeData(LNode))^.Index :=
      FMsgVisible.Count - 1;
  end;
end;

procedure TfrmMain.Log(const AText: string);
begin
  LogRow(mkStatus, AText, '', 0, 0);
end;

// A diagnostic row — the future hint/warning entry points will call LogRow
// directly with mkWarning/mkHint once those severities exist.
procedure TfrmMain.LogError(const AFilePath: string; ALine, ACol: Integer;
  const AText: string);
begin
  LogRow(mkError, AText, AFilePath, ALine, ACol);
end;

procedure TfrmMain.ClearMessages;
begin
  FMsgLog.Clear;
  FMsgVisible.Clear;
  vtMessages.Clear;
end;

// Re-applies the chkShowErrors filter to the ENTIRE history — needed because
// toggling the checkbox must retroactively show/hide every already-logged
// error row, not just future ones ("даже если чекбокс нажат после завершения
// парсинга").
procedure TfrmMain.RebuildVisibleMessages;
var
  LIdx: Integer;
  LNode: PVirtualNode;
begin
  FMsgVisible.Clear;
  for LIdx := 0 to FMsgLog.Count - 1 do
    if (FMsgLog[LIdx].Kind = mkStatus) or chkShowErrors.Checked then
      FMsgVisible.Add(LIdx);
  vtMessages.BeginUpdate;
  try
    vtMessages.Clear;
    for LIdx := 0 to FMsgVisible.Count - 1 do
    begin
      LNode := vtMessages.AddChild(nil);
      PPasMsgNodeData(vtMessages.GetNodeData(LNode))^.Index := LIdx;
    end;
  finally
    vtMessages.EndUpdate;
  end;
  ScrollMessagesToEnd;
end;

procedure TfrmMain.ScrollMessagesToEnd;
var
  LNode: PVirtualNode;
begin
  LNode := vtMessages.GetLast;
  if Assigned(LNode) then
  begin
    vtMessages.FocusedNode := LNode;
    vtMessages.ScrollIntoView(LNode, False);
  end;
end;

// The main unit's model in the CURRENT FSemaProject, if any has been
// analyzed yet — shared by btnShowASTJsonClick/btnShowSemanticsClick (AST
// JSON/Semantics content is computed lazily FROM THIS at click time, always
// reflecting the latest analysis, including a quiet background reanalysis
// the user never saw a "Done" line for).
function TfrmMain.FindMainModel(out AModel: TPasSemaModel): Boolean;
var
  LId: Integer;
begin
  Result := False;
  AModel := nil;
  if not Assigned(FSemaProject) then
    Exit;
  for LId := 0 to FSemaProject.ModelCount - 1 do
    if SameText(FSemaProject.ModelFile(LId), FMainSource) then
    begin
      AModel := FSemaProject.Model(LId);
      Exit(True);
    end;
end;

procedure TfrmMain.btnShowASTJsonClick(Sender: TObject);
var
  LModel: TPasSemaModel;
begin
  if not FindMainModel(LModel) then
  begin
    Log('No analysis available yet.');
    Exit;
  end;
  edJson.Text := PrettyJson(AstToJson(LModel.Tree));
  tsJson.TabVisible := True;
  pgc.ActivePage := tsJson;
end;

procedure TfrmMain.btnShowSemanticsClick(Sender: TObject);
var
  LModel: TPasSemaModel;
begin
  if not FindMainModel(LModel) then
  begin
    Log('No analysis available yet.');
    Exit;
  end;
  edSema.Text := DumpSemaModel(LModel);
  tsSema.TabVisible := True;
  pgc.ActivePage := tsSema;
end;

// Test-coverage plan step 5 (demo part): needs no open project at all --
// unlike AST JSON/Semantics, this reads PasTree.Tests.Parser's own compiled-
// in tables plus (best-effort) the sibling checkouts, not the currently
// open unit.
procedure TfrmMain.btnShowCoverageClick(Sender: TObject);
var
  LSpecDir, LTestsDir: string;
begin
  LSpecDir := FSettings.ReadString('SpecDir', '');
  if (LSpecDir <> '') and not TDirectory.Exists(LSpecDir) then
    LSpecDir := '';
  if LSpecDir = '' then
    LSpecDir := GuessSpecDir;
  LTestsDir := FSettings.ReadString('TestsDir', '');
  if (LTestsDir <> '') and not TDirectory.Exists(LTestsDir) then
    LTestsDir := '';
  if LTestsDir = '' then
    LTestsDir := GuessTestsDir;
  edCoverage.Text := BuildCoverageReport(LSpecDir, LTestsDir);
  tsCoverage.TabVisible := True;
  pgc.ActivePage := tsCoverage;
end;

procedure TfrmMain.chkShowErrorsClick(Sender: TObject);
begin
  RebuildVisibleMessages;
end;

procedure TfrmMain.vtMessagesGetText(Sender: TBaseVirtualTree;
  Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType;
  var CellText: string);
var
  LData: PPasMsgNodeData;
begin
  LData := PPasMsgNodeData(Sender.GetNodeData(Node));
  if (LData <> nil) and (LData.Index >= 0) and
     (LData.Index < FMsgVisible.Count) then
    CellText := FMsgLog[FMsgVisible[LData.Index]].Text
  else
    CellText := '';
end;

// Double-click a row that NAMES A POSITION: open (or focus) its file and land
// the caret exactly there. Gated on the position, not on Kind — the
// closure-health summary rows are mkStatus yet do carry the first import site
// of a unit we could not find, and jumping to it is the only way to see who
// asked for that unit. A row with no position, or one whose file no longer
// exists (edited/deleted since analysis), does nothing.
procedure TfrmMain.vtMessagesDblClick(Sender: TObject);
var
  LData: PPasMsgNodeData;
  LRow: TPasMsgRow;
begin
  if vtMessages.FocusedNode = nil then
    Exit;
  LData := PPasMsgNodeData(vtMessages.GetNodeData(vtMessages.FocusedNode));
  if (LData = nil) or (LData.Index < 0) or (LData.Index >= FMsgVisible.Count)
  then
    Exit;
  LRow := FMsgLog[FMsgVisible[LData.Index]];
  if (LRow.FilePath = '') or not TFile.Exists(LRow.FilePath) then
    Exit;
  NavigateTo(LRow.FilePath, LRow.Line, LRow.Col);
end;

procedure TfrmMain.OpenProject(const AProjectFile: string);
var
  LFile, LExt, LSiblingDProj: string;
begin
  if not TFile.Exists(AProjectFile) then
  begin
    Log('Project not found: ' + AProjectFile);
    Exit;
  end;
  // A DIFFERENT project drops the chosen configuration: the names are the
  // project's own, so carrying "Release" into a project that has no such
  // configuration would silently fall back to its default anyway. Compared
  // before FProjectFile is reassigned, and against the path as OPENED, so the
  // re-open cbConfigChange performs keeps the choice it just made.
  if not SameText(TPath.GetFullPath(AProjectFile), FProjectFile) then
    FConfigOverride := '';
  ClearMessages;
  // Including the tabs: a source tab belongs to the project it was opened
  // under, both in what it shows and in the context it paints with. See
  // CloseAllTabs.
  CloseAllTabs;
  FNavHistory.Clear;   // its entries point into the tabs just closed
  // A NEW project starts with a clean slate: no carried-over AST/Semantics
  // dump from whatever was open before.
  tsJson.TabVisible := False;
  tsSema.TabVisible := False;
  LFile := AProjectFile;
  LExt := LowerCase(TPath.GetExtension(LFile));
  // Opening the bare main source of a real project should behave exactly like
  // opening its .dproj (same search paths/defines/full file list) — a real
  // IDE does this too. Redirect BEFORE anything else reads LExt/LFile.
  //
  // A PACKAGE is the same arrangement with a different main source: `.dpk`
  // beside its own `.dproj`, and the RTL/VCL/FMX packages this analyzer is
  // measured against are exactly that. Both extensions redirect, since
  // everything downstream cares about the .dproj, not about which file named
  // it.
  if (LExt = '.dpr') or (LExt = '.dpk') then
  begin
    LSiblingDProj := TPath.ChangeExtension(LFile, '.dproj');
    if TFile.Exists(LSiblingDProj) then
    begin
      LFile := LSiblingDProj;
      LExt := '.dproj';
    end;
  end;
  FreeAndNil(FDProj);
  FDProjSummary := '';   // a previous project's summary must not leak forward
  FPlatform := pfWin32;
  if LExt = '.dproj' then
  begin
    FDProj := TPasDProj.Create;
    // FConfigOverride is '' for a fresh open (the project's own default) and
    // set only when cbConfig re-opens the SAME project — see cbConfigChange.
    if FDProj.Load(LFile, '', FConfigOverride) then
    begin
      FPlatform := FDProj.Platform;
      FMainSource := FDProj.MainSource;
      FProjectDir := FDProj.Dir;
      // Deferred: this belongs UNDER the "Opened project" line, which is only
      // logged once the whole open has succeeded.
      FDProjSummary := Format(
        '  .dproj: config %s, %d search path(s), %d define(s), ' +
        '%d unit alias(es)', [FDProj.Config, Length(FDProj.SearchPaths),
        Length(FDProj.Defines), Length(FDProj.UnitAliases)]);
    end
    else
    begin
      // Fall back to the lightweight platform/mainsource-only reader.
      FreeAndNil(FDProj);
      if not TryReadDProj(LFile, FPlatform, FMainSource) then
        FPlatform := pfWin32;
      FProjectDir := TPath.GetDirectoryName(LFile);
      if (FMainSource <> '') and not TPath.IsPathRooted(FMainSource) then
        FMainSource := TPath.Combine(FProjectDir, FMainSource);
      // Last resort when the .dproj named no main source we could find: the
      // sibling of the same name. A PACKAGE's is a `.dpk`, so both are tried
      // rather than assuming a program.
      if not TFile.Exists(FMainSource) then
      begin
        FMainSource := TPath.ChangeExtension(LFile, '.dpr');
        if not TFile.Exists(FMainSource) then
          FMainSource := TPath.ChangeExtension(LFile, '.dpk');
      end;
    end;
  end
  else
  begin
    FMainSource := LFile;
    FProjectDir := TPath.GetDirectoryName(LFile);
  end;

  case FPlatform of
    pfWin64: cbPlatform.ItemIndex := 1;
  else
    cbPlatform.ItemIndex := 0;
  end;
  FProjectFile := LFile;
  PopulateConfigCombo;

  Caption := 'PasTree Demo — ' + TPath.GetFileName(LFile);
  // Remembered here, at the one point every route into a project passes
  // through, and with LFile — the .dproj the .dpr was redirected to, not the
  // .dpr the caller happened to name.
  if Assigned(FSettings) then
    FSettings.AddRecent(LFile);
  PopulateTree;
  if TFile.Exists(FMainSource) then
    OpenFileTab(FMainSource);
  Log('Opened project: ' + LFile +
    '  (platform ' + PlatformName(FPlatform) + ', ' +
    IntToStr(FFileList.Count) + ' files)');
  if FDProjSummary <> '' then
    Log(FDProjSummary);
  // Kick off the background analysis (non-blocking); it populates navigation
  // and (if chkShowErrors is checked) the error list when it finishes. The
  // open main file is front-loaded so it is ready first.
  // The configuration is named here and not only in the .dproj summary line,
  // because a bare .dpr has no summary line and still has a configuration —
  // it is what decides whether DEBUG is defined.
  Log('Analyzing ' + TPath.GetFileName(FMainSource) + ' in ' + FProjectDir +
    ' (' + cbPlatform.Text + ', ' + SelectedConfig +
    ') in the background...');
  // The TOTAL search-path set, not just the .dproj's own: the rest comes from
  // the IDE's registry library/browsing paths (ExtraSearchPaths), and that set
  // is what decides how much of the `uses` graph resolves — so how many units
  // the closure ends up with, and hence the run time. Two runs of the same
  // project differing in unit count differ HERE, and without this line there
  // was no way to tell from a log.
  var LDbgPlat: TPasPlatform;
  var LDbgPaths, LDbgDefines: TArray<string>;
  var LFromDProj := 0;
  if Assigned(FDProj) then
    LFromDProj := Length(FDProj.SearchPaths);
  if BuildConfig(LDbgPlat, LDbgPaths, LDbgDefines) then
  begin
    Log(Format('  search paths: %d total = 1 project dir + %d from .dproj + ' +
      '%d from the IDE registry; %d define(s)',
      [Length(LDbgPaths), LFromDProj, Length(ExtraSearchPaths),
       Length(LDbgDefines)]));
    // WHERE the -NS list came from. A wrong or missing prefix list shows up as
    // F1027 on units that obviously exist, so the log must not leave it
    // implicit.
    if Assigned(FDProj) and (Length(FDProj.Namespaces) > 0) then
      Log(Format('  unit scope names: %d from .dproj — %s',
        [Length(FDProj.Namespaces), string.Join(';', FDProj.Namespaces)]))
    else
      Log(Format('  unit scope names: %d IDE defaults (no .dproj list) — %s',
        [Length(EffectiveNamespaces(LDbgPlat)),
         string.Join(';', EffectiveNamespaces(LDbgPlat))]));
  end;
  StartAsyncAnalyze(FMainSource, {ALoud} True);
end;

procedure TfrmMain.PopulateTree;
var
  LFile: string;
begin
  FFileList.Clear;   // RefreshFileNodes below clears the tree to match

  if Assigned(FDProj) and (Length(FDProj.Files) > 0) then
  begin
    // Source of truth: the .dproj's own compiled-unit list (DCCReference),
    // not a directory scan — this also correctly reaches units that live
    // outside FProjectDir (e.g. '..\source\*.pas' referenced by the .dproj).
    for LFile in FDProj.Files do
      if TFile.Exists(LFile) then
        FFileList.Add(LFile);
  end
  else if (FMainSource <> '') and TFile.Exists(FMainSource) then
    // No .dproj for this project (OpenProject already redirects to a sibling
    // .dproj when one exists — see there). Start with just the main file:
    // its own members are only knowable once it has been parsed, so
    // AdoptProjectMembers adds them when the analysis lands.
    FFileList.Add(FMainSource);

  RefreshFileNodes;
end;

// Sorts FFileList and rebuilds the file tree's nodes from it. Shared by
// PopulateTree and AdoptProjectMembers (which grows the list after analysis).
procedure TfrmMain.RefreshFileNodes;
var
  LNode: PVirtualNode;
begin
  FFileList.Sort;
  vstFiles.BeginUpdate;
  try
    vstFiles.Clear;
    for var LIndex := 0 to FFileList.Count - 1 do
    begin
      LNode := vstFiles.AddChild(nil);
      PPasNodeData(vstFiles.GetNodeData(LNode))^.Index := LIndex;
    end;
  finally
    vstFiles.EndUpdate;
  end;
end;

{ Adds the main source's OWN units to the project file list.

  A bare .dpr/.dpk with no sibling .dproj leaves FFileList holding nothing but
  the main file, because at PopulateTree time nothing has parsed it yet. That
  is not just a thin tree: ReportProjectResult LISTS diagnostics only for
  FFileList members (everything else is RTL reach, counted but not listed), so
  the message window stayed empty while the Done line honestly reported
  hundreds — the count and the list disagreeing for a real reason, but looking
  exactly like a lie.

  The main source's uses/contains entries carrying an `in 'path'` clause ARE
  the project's own unit list. That is Delphi's own convention — the IDE
  writes `in` for a project member and a bare name for a library unit — and it
  is how the shipped BuildWinRTL.dpk names all ~310 of its units, as well as
  how the demo's generated VCL/FMX packages name theirs. }
procedure TfrmMain.AdoptProjectMembers(AMainId: Integer);
var
  LModel: TPasSemaModel;
  LPath: string;
  LAdded: Boolean;
begin
  // A .dproj's DCCReference list is authoritative; never second-guess it.
  if Assigned(FDProj) and (Length(FDProj.Files) > 0) then
    Exit;
  if (AMainId < 0) or (AMainId >= FSemaProject.ModelCount) then
    Exit;
  LModel := FSemaProject.Model(AMainId);
  LAdded := False;
  for var LIdx := 0 to High(LModel.UsesList) do
  begin
    if (LModel.UsesList[LIdx].InPath = '') or
       (LModel.UsesList[LIdx].UnitId < 0) then
      Continue;   // a library unit, or one that did not resolve
    LPath := FSemaProject.ModelFile(LModel.UsesList[LIdx].UnitId);
    if (LPath <> '') and (FFileList.IndexOf(LPath) < 0) then
    begin
      FFileList.Add(LPath);
      LAdded := True;
    end;
  end;
  if LAdded then
    RefreshFileNodes;
end;

function TfrmMain.OpenFileTab(const APath: string): TSynEdit;
var
  LIdx: Integer;
  LTab: TSourceTab;
  LHL: TPasTreeSynHighlighter;
begin
  LIdx := FOpenFiles.IndexOf(APath);
  if LIdx >= 0 then
  begin
    LTab := TSourceTab(FOpenFiles.Objects[LIdx]);
    pgc.ActivePage := LTab;
    Exit(LTab.Editor);
  end;

  LTab := TSourceTab.Create(pgc);
  LTab.PageControl := pgc;
  LTab.Caption := TPath.GetFileName(APath);

  Result := TSynEdit.Create(LTab);
  Result.Parent := LTab;
  Result.Align := alClient;
  Result.Gutter.ShowLineNumbers := True;
  Result.Font.Name := 'Consolas';
  Result.UseCodeFolding := True;
  // go-to-declaration: ctrl+hover shows a link, ctrl+click jumps.
  Result.OnMouseMove := EditorMouseMove;
  Result.OnMouseDown := EditorMouseDown;
  Result.OnKeyUp := EditorKeyUp;
  Result.OnChange := EditorChange;   // edits debounce a nav re-analysis
  Result.OnStatusChange := EditorStatusChange; // "same identifier" highlight
  Result.PopupMenu := SourcePopupMenu;
  Result.SearchEngine := SynEditSearch1;

  // Our own PasTree-lexer-driven highlighter — one instance per tab (it
  // caches the tokenization of its own attached buffer, so instances can't
  // be shared across editors). Kept alive even when SynEdit's highlighter is
  // the active one, so cbHighlighterChange can switch back without recreating it.
  LHL := TPasTreeSynHighlighter.Create(Result);
  LHL.SourceLines := Result.Lines;
  // Give it the same context the ANALYSIS runs under. Without it the
  // highlighter preprocesses the buffer under a placeholder name and no search
  // paths, so every `{$I ...}` fails — and an include that DEFINES symbols then
  // flips which branches look live. One library unit greyed out `SizeInt = Integer`
  // under `{$IFDEF CPU32}` (CPU32 comes from a config include reached through
  // its own `$I`) while ctrl+click navigated to that very line, because
  // navigation reads the real analysis. Two sources of truth, visibly
  // disagreeing on the same line.
  ApplyHighlighterContext(LHL, APath);
  LHL.SetSameIdentColor(FIdentHighlightColor);
  if cbHighlighter.ItemIndex = 0 then
    Result.Highlighter := FSynPasHL
  else
    Result.Highlighter := LHL;
  FLoadingFile := True;   // don't let the programmatic load arm the reparse timer
  try
    try
      Result.Lines.LoadFromFile(APath);
    except
      on E: Exception do
        Result.Text := '{ could not load: ' + E.Message + ' }';
    end;
  finally
    FLoadingFile := False;
  end;
  LTab.Editor := Result;
  LTab.PasTreeHL := LHL;
  LTab.FilePath := TPath.GetFullPath(APath);
  // Keeps recorded positions in THIS file pointing at the same text as it is
  // edited. Created after FilePath is known and after the initial load, and
  // owned by the editor — see TNavHistoryPlugin.
  TNavHistoryPlugin.Create(Result, Self, LTab.FilePath);
  FOpenFiles.AddObject(APath, LTab);
  pgc.ActivePage := LTab;
end;

{ go-to-declaration }

// The (raw token, declaration target) under pixel (X, Y) of an editor —
// shared by hover-link display and the actual ctrl+click jump.
function TfrmMain.ResolveAt(AEditor: TSynEdit; X, Y: Integer;
  out ARawFrom, ARawTo: Integer; out ATarget: TPasNavTarget): Boolean;
var
  LTab: TSourceTab;
  LMid: Integer;
  LBC: TBufferCoord;
  LIdent: TPasNavIdent;
begin
  Result := False;
  if FAnalyzing or (FNav = nil) then
    Exit;
  LTab := TSourceTab(AEditor.Parent);
  LMid := FNav.ModelIdOf(LTab.FilePath);
  if LMid < 0 then
    Exit;   // file not part of the last analysis
  LBC := AEditor.DisplayToBufferPos(AEditor.PixelsToRowColumn(X, Y));
  if not FNav.IdentAt(LMid, LBC.Line, LBC.Char, {out} LIdent) then
    Exit;
  if not FNav.ResolveDecl(LMid, LIdent.Node, {out} ATarget) then
    Exit;
  ARawFrom := LIdent.RawToken;
  ARawTo := LIdent.RawTokenTo;
  Result := True;
end;

{ The file named by an $I / $INCLUDE directive under pixel (X, Y), as a
  navigation target — the include half of ctrl+click.

  It cannot go through TPasNav at all: a directive is TRIVIA, it has no
  identifier and no AST node, so nothing the resolver produced knows about it.
  What it does have is a single raw token covering the whole directive, which is
  exactly the link range to underline, and a file name that FileForName already
  knows how to resolve. So this is a line-level scan plus that lookup, and it
  works in a file the analysis never reached.

  Deliberately NOT the reverse direction: an identifier typed inside an opened
  .inc still resolves to nothing, for the model-keyed reason in the README's
  To-do. This is the direction that matters — getting INTO the include from the
  unit that includes it. }
function TfrmMain.IncludeTargetAt(AEditor: TSynEdit; X, Y: Integer;
  out ARawFrom, ARawTo: Integer; out ATarget: TPasNavTarget): Boolean;
var
  LTab: TSourceTab;
  LBC: TBufferCoord;
  LLine, LName, LFile: string;
  LFrom, LTo: Integer;
begin
  Result := False;
  if not (AEditor.Parent is TSourceTab) then
    Exit;
  LTab := TSourceTab(AEditor.Parent);
  LBC := AEditor.DisplayToBufferPos(AEditor.PixelsToRowColumn(X, Y));
  if (LBC.Line < 1) or (LBC.Line > AEditor.Lines.Count) then
    Exit;
  LLine := AEditor.Lines[LBC.Line - 1];
  if not TryIncludeArgSpan(LLine, LBC.Char, {out} LFrom, {out} LTo) then
    Exit;
  LName := Copy(LLine, LFrom, LTo - LFrom + 1);
  LFile := FileForName(LName);
  if LFile = '' then
    Exit;
  // The whole directive is ONE raw token, so one index underlines it.
  ARawFrom := LTab.PasTreeHL.RawTokenAt(LBC.Line, LFrom);
  ARawTo := ARawFrom;
  ATarget := Default(TPasNavTarget);
  ATarget.FilePath := LFile;
  ATarget.Line := 1;
  ATarget.Col := 1;
  Result := ARawFrom >= 0;
end;

procedure TfrmMain.SetLink(ATab: TObject; AFrom, ATo: Integer);
var
  LTab: TSourceTab;
begin
  if (FLinkTab = ATab) and TSourceTab(ATab).PasTreeHL.LinkRangeEquals(AFrom,
    ATo) then
    Exit;
  ClearLink;
  LTab := TSourceTab(ATab);
  LTab.PasTreeHL.SetLinkRange(AFrom, ATo);
  LTab.Editor.Cursor := crHandPoint;
  LTab.Editor.Invalidate;
  FLinkTab := ATab;
end;

procedure TfrmMain.ClearLink;
var
  LTab: TSourceTab;
begin
  if FLinkTab = nil then
    Exit;
  LTab := TSourceTab(FLinkTab);
  LTab.PasTreeHL.SetLinkRange(-1, -1);
  LTab.Editor.Cursor := crIBeam;
  LTab.Editor.Invalidate;
  FLinkTab := nil;
end;

procedure TfrmMain.EditorMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Integer);
var
  LFrom, LTo: Integer;
  LTarget: TPasNavTarget;
begin
  // The include branch is tried SECOND: an identifier is the overwhelmingly
  // common case and the one that must stay fast, and the two cannot both match
  // (a directive carries no identifier).
  if (ssCtrl in Shift) and
     (ResolveAt(TSynEdit(Sender), X, Y, {out} LFrom, {out} LTo,
        {out} LTarget) or
      IncludeTargetAt(TSynEdit(Sender), X, Y, {out} LFrom, {out} LTo,
        {out} LTarget)) then
    SetLink(TSynEdit(Sender).Parent, LFrom, LTo)
  else
    ClearLink;
end;

procedure TfrmMain.EditorMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  LEditor: TSynEdit;
  LFrom, LTo: Integer;
  LTarget: TPasNavTarget;
begin
  if (Button <> mbLeft) or not (ssCtrl in Shift) then
    Exit;
  LEditor := TSynEdit(Sender);
  if not ResolveAt(LEditor, X, Y, {out} LFrom, {out} LTo, {out} LTarget) and
     not IncludeTargetAt(LEditor, X, Y, {out} LFrom, {out} LTo, {out} LTarget)
  then
    Exit;
  ClearLink;
  // SynEdit's own MouseDown moves the caret to the click position AFTER this
  // handler returns (inherited MouseDown fires us, THEN MoveDisplayPosAnd-
  // Selection), clobbering our jump — which is why it previously only "worked"
  // on a double-click, where SynEdit bails early on ssDouble. Defer the jump so
  // it runs after SynEdit's caret move, and a single ctrl+click lands correctly.
  TThread.ForceQueue(nil,
    procedure
    begin
      // NavigateTo opens the tab when the target is in another unit and finds
      // the existing one when it is not, so the same-file case needs no
      // special path here — but the ORIGIN it records must be this editor's
      // caret, which SynEdit has by now moved to the click. That is the right
      // origin: it is where the user was looking.
      NavigateTo(LTarget.FilePath, LTarget.Line, LTarget.Col);
    end);
end;

procedure TfrmMain.EditorKeyUp(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_CONTROL then
    ClearLink;
end;

// Platform + search paths + defines for the current project — shared by the
// synchronous Analyze and the background StartAsyncAnalyze so they never drift.
// False if no project is open.
function TfrmMain.BuildConfig(out APlatform: TPasPlatform;
  out ASearchPaths, ADefines: TArray<string>): Boolean;
begin
  Result := False;
  if (FProjectDir = '') or not TDirectory.Exists(FProjectDir) then
    Exit;
  if cbPlatform.ItemIndex = 1 then
    APlatform := pfWin64
  else
    APlatform := pfWin32;
  if Assigned(FDProj) then
  begin
    ASearchPaths := [FProjectDir] + FDProj.SearchPaths;
    ADefines := FDProj.Defines;
  end
  else
  begin
    ASearchPaths := [FProjectDir];
    // No .dproj to read the configuration's defines from, so synthesize the
    // one that matters: the IDE's stock Debug configuration defines DEBUG and
    // Release does not, and real code branches on it (`{$IFDEF DEBUG}
    // FastMM4,` in a project's own uses clause). Without this the combo would
    // be decoration for a bare .dpr.
    if SameText(SelectedConfig, 'Debug') then
      ADefines := ['DEBUG']
    else
      ADefines := [];
  end;
  ASearchPaths := ASearchPaths + ExtraSearchPaths;   // System.* -> RTL sources
  Result := True;
end;

// Analysis core, shared by the loud RunParse and the quiet ReanalyzeForNav.
// Recreates FSemaProject/FNav (the previous ones, and any hover link into
// them, die here) and — crucially — feeds every OPEN editor's current text as
// a buffer override, so analysis (and thus navigation) matches what's on
// screen, including unsaved edits. Returns False only if no project is open.
function TfrmMain.Analyze: Boolean;
var
  LPlatform: TPasPlatform;
  LSearchPaths, LDefines: TArray<string>;
  LIdx: Integer;
  LTab: TSourceTab;
  LSW: TStopwatch;
begin
  Result := False;
  // Overhead OUTSIDE the engine's own StageTimings, logged so a perf report
  // can't hide time in the wrapper (this is exactly how the invisible
  // ~1s-per-run ExtraSearchPaths cost was eventually found).
  FAnalyzeOverhead := '';
  LSW := TStopwatch.StartNew;
  if not BuildConfig(LPlatform, LSearchPaths, LDefines) then
    Exit;
  FAnalyzeOverhead := Format('paths=%d;', [LSW.ElapsedMilliseconds]);
  FLastSearchPaths := LSearchPaths;   // see the field

  ClearLink;
  FAnalyzing := True;
  try
    LSW := TStopwatch.StartNew;
    FreeAndNil(FNav);
    FreeAndNil(FSemaProject);
    FAnalyzeOverhead := FAnalyzeOverhead +
      Format('destroy=%d;', [LSW.ElapsedMilliseconds]);
    FSemaProject := TPasSemaProject.Create(LPlatform, LSearchPaths, LDefines);
    FSemaProject.SingleThreaded := cbThreading.ItemIndex = 0;
    // ALWAYS on in the demo, which is the host whose job is to show what the
    // analyzer still gets wrong: an unresolved member after a dot is a real gap
    // and hiding it hides progress. The LIBRARY default stays off (the property
    // is False unless a host asks), because an editor embedding PasTree wants
    // the error-tolerant mode. chkShowErrors then filters DISPLAY only, so
    // toggling it stays instant instead of costing a re-analysis.
    FSemaProject.ReportUnresolvedMembers := True;
    FSemaProject.ReportGuessedIfs := True;   // same philosophy: show the guesses
    FSemaProject.SetNamespaces(EffectiveNamespaces(LPlatform)); // Forms -> Vcl.Forms
    // Defaults ALWAYS, then the project's on top: the IDE prepends a project's
    // own aliases to the defaults rather than replacing them, and AddUnitAlias
    // is last-wins, so this order gives the project precedence on a collision.
    for var LDef in PasDefaultUnitAliases(LPlatform) do
      FSemaProject.AddUnitAlias(LDef.Alias, LDef.UnitName);
    if Assigned(FDProj) then
      for var LAlias in FDProj.UnitAliases do
        FSemaProject.AddUnitAlias(LAlias.Alias, LAlias.UnitName);
    for LIdx := 0 to FOpenFiles.Count - 1 do
    begin
      LTab := TSourceTab(FOpenFiles.Objects[LIdx]);
      FSemaProject.SetBuffer(LTab.FilePath, LTab.Editor.Text);
    end;

    // Same engine as the background path (AnalyzeStaged, run here to
    // completion on THIS thread instead of a worker) — its uses-closure walk
    // from FMainSource covers a plain .dpr just as well as the old
    // AnalyzeDirectory fallback did (StartAsyncAnalyze has used it
    // unconditionally, dproj or not, since the async path shipped). The one
    // real payoff: AOnProgress fires synchronously on the UI thread, so
    // lblProgress can show live progress during a blocking Run Parse —
    // Update forces an immediate repaint since we're not pumping messages.
    LSW := TStopwatch.StartNew;
    FSemaProject.AnalyzeStaged([FMainSource], [], nil,
      procedure(AProgress: TPasStagedProgress)
      begin
        lblProgress.Caption := Format('%s %d/%d',
          [AProgress.Phase, AProgress.FullDone, AProgress.Total]);
        lblProgress.Update;
      end);
    FAnalyzeOverhead := FAnalyzeOverhead +
      Format('engine=%d;', [LSW.ElapsedMilliseconds]);
    LSW := TStopwatch.StartNew;
    FNav := TPasNavigator.Create(FSemaProject);
    FAnalyzeOverhead := FAnalyzeOverhead +
      Format('nav=%d;', [LSW.ElapsedMilliseconds]);
  finally
    FAnalyzing := False;
  end;
  Result := True;
end;

// Reports the CURRENT FSemaProject's diagnostics + Done line and populates the
// AST/Semantics views for the main unit. Shared by the synchronous RunParse
// and the background async swap; AElapsedMs is the analysis wall-clock.
procedure TfrmMain.ReportProjectResult(AElapsedMs: Int64);
var
  LMain, LDiagTotal, LDiagListed, LId, LDIdx, LFileId: Integer;
  LTotalLines, LTotalChars, LTotalFiles: Int64;
  LUnresUses, LUnitsGated: Integer;
  LMissing: TDictionary<string, TPasMissingUnit>;
  LModel: TPasSemaModel;
  LDiagFile, LVolume: string;
  LOwnFile: Boolean;
begin
  // Locate the main unit's model, and report diagnostics. The analyzed
  // closure now includes the whole RTL/VCL/3rd-party reach (for nav), so
  // only PROJECT files' diagnostics are LISTED (external ones would bury
  // the user's own in noise); the total still counts everything. AST JSON/
  // Semantics are NOT computed here anymore — btnShowASTJsonClick/
  // btnShowSemanticsClick compute them lazily, from whatever is current at
  // the moment the user actually asks to see them.
  LMain := -1;
  LDiagTotal := 0;
  LDiagListed := 0;
  LTotalLines := 0;
  LTotalChars := 0;
  LTotalFiles := 0;
  LUnresUses := 0;
  LUnitsGated := 0;
  LMissing := TDictionary<string, TPasMissingUnit>.Create;
  try
  // Locate the main unit BEFORE the diagnostics loop: the loop's own listing
  // filter reads FFileList, and for a .dproj-less project that list is not
  // complete until the main unit's members have been adopted into it.
  for LId := 0 to FSemaProject.ModelCount - 1 do
    if SameText(FSemaProject.ModelFile(LId), FMainSource) then
    begin
      LMain := LId;
      Break;
    end;
  AdoptProjectMembers(LMain);
  vtMessages.BeginUpdate;
  try
    for LId := 0 to FSemaProject.ModelCount - 1 do
    begin
      LModel := FSemaProject.Model(LId);
      // Source volume, accumulated BEFORE the listing filter below: this
      // measures what the PARSER chewed through, which is the whole closure,
      // not just the project's own files.
      for LFileId := 0 to High(LModel.Tree.Source.Files) do
      begin
        Inc(LTotalFiles);
        Inc(LTotalLines, Length(LModel.Tree.Source.Files[LFileId].LineStarts));
        Inc(LTotalChars, Length(LModel.Tree.Source.Files[LFileId].Source));
      end;
      // Closure HEALTH, the number that says whether the unit count above can
      // be trusted. A `uses` name that did not resolve means a whole subtree
      // the compiler WOULD compile is missing here — so the unit count is an
      // under-count — and it also GATES E2003 for that unit, so the diagnostic
      // count is an under-count too. dcc treats an unresolvable uses as fatal
      // (F1027), so on a project that really builds, a healthy run is zero.
      // This is what distinguishes "the project got smaller" from "we resolved
      // less of it": without it, a run with too few search paths looks fast and
      // clean instead of incomplete.
      for LDIdx := 0 to High(LModel.UsesList) do
        if LModel.UsesList[LDIdx].UnitId < 0 then
        begin
          Inc(LUnresUses);
          // Group by NAME: thousands of import sites are usually a handful of
          // libraries missing from the search path, and the name list says
          // which. The per-site F1027 rows answer "where"; this answers "what"
          // — and keeps the FIRST site so the summary row can answer "where"
          // as well, for the (common) case where the importer is a library
          // unit whose F1027 is never listed.
          var LMiss: TPasMissingUnit;
          if not LMissing.TryGetValue(LModel.UsesList[LDIdx].NameFull, LMiss)
          then
          begin
            // First sighting wins: models are numbered in discovery order, and
            // UsesList is in source order within a model, so this really is the
            // earliest place the analyzer saw the name.
            LMiss := Default(TPasMissingUnit);
            FSemaProject.NodeSite(LId, LModel.UsesList[LDIdx].NameNode,
              {out} LMiss.FirstFile, {out} LMiss.FirstLine, {out} LMiss.FirstCol);
          end;
          Inc(LMiss.Count);
          LMissing.AddOrSetValue(LModel.UsesList[LDIdx].NameFull, LMiss);
        end;
      if not LModel.AllUsesResolved then
        Inc(LUnitsGated);
      // EVERY diagnostic is listed, project file or library unit. Counting one
      // silently was the wrong trade twice over: the Done line said 906 and the
      // window showed 5, which reads as the tool contradicting itself — and the
      // 901 it hid were OUR OWN false positives in third-party code (283 of
      // them turned out to be a single parser bug in one third-party unit). A
      // diagnostic nobody can see is a bug nobody can report.
      LOwnFile := FFileList.IndexOf(FSemaProject.ModelFile(LId)) >= 0;
      for LDIdx := 0 to High(LModel.Diags) do
      begin
        Inc(LDiagTotal);
        if LOwnFile then
          Inc(LDiagListed);
        // A diagnostic's FileId is the MODEL'S OWN file table — for one
        // raised inside an $I-included file this is NOT the unit's main
        // file, so resolve it properly rather than assuming ModelFile(LId).
        LFileId := LModel.Diags[LDIdx].FileId;
        if (LFileId >= 0) and
           (LFileId <= High(LModel.Tree.Source.FileNames)) then
          LDiagFile := LModel.Tree.Source.FileNames[LFileId]
        else
          LDiagFile := FSemaProject.ModelFile(LId);
        LogError(LDiagFile, LModel.Diags[LDIdx].Line, LModel.Diags[LDIdx].Col,
          Format('[Error] %s(%d,%d): %s',
            [TPath.GetFileName(LDiagFile), LModel.Diags[LDIdx].Line,
             LModel.Diags[LDIdx].Col, LModel.Diags[LDIdx].Msg]));
      end;
    end;
  finally
    vtMessages.EndUpdate;
  end;
  // Say WHERE the diagnostics are, not just how many. The total spans the
  // whole analyzed closure while only project files are listed, so a bare
  // total next to an empty message window reads as the tool contradicting
  // itself — which is exactly how the .dproj-less case used to look.
  if LDiagListed = LDiagTotal then
    Log(Format('Done: %d units, %d diagnostics in %s (%s).',
      [FSemaProject.ModelCount, LDiagTotal, ElapsedText(AElapsedMs),
       cbThreading.Text]))
  else
    Log(Format('Done: %d units, %d diagnostics in %s (%s) — %d in project ' +
      'files, %d in library units. ALL are listed below.',
      [FSemaProject.ModelCount, LDiagTotal, ElapsedText(AElapsedMs),
       cbThreading.Text, LDiagListed, LDiagTotal - LDiagListed]));
  // Volume the parser actually processed. An $I include is counted once per
  // INCLUDING unit, because that is how many times it was really lexed and
  // parsed — the figure is work done, not distinct bytes on disk. Chars, not
  // bytes: the source is UTF-16 in memory, and for (essentially ASCII)
  // Pascal source one char is one byte on disk, so this also reads as the
  // on-disk size.
  if LTotalLines > 0 then
  begin
    LVolume := Format('  source: %s lines, %.1f MB, %s file(s)',
      [FormatFloat('#,##0', LTotalLines), LTotalChars / (1024 * 1024),
       FormatFloat('#,##0', LTotalFiles)]);
    if AElapsedMs > 0 then
      LVolume := LVolume + Format(' — %s lines/s',
        [FormatFloat('#,##0', LTotalLines * 1000 / AElapsedMs)]);
    Log(LVolume);
  end;
  if LUnresUses = 0 then
    Log(Format('  closure: complete — every `uses` resolved across %d unit(s)',
      [FSemaProject.ModelCount]))
  else
  begin
    Log(Format('  closure: INCOMPLETE — %d unresolved `uses` name(s) over %d ' +
      'distinct unit(s); %d of %d unit(s) have their E2003 suppressed. Unit ' +
      'and diagnostic counts are both under-counts; check the search paths ' +
      'above. Each site is an F1027 in the list below.',
      [LUnresUses, LMissing.Count, LUnitsGated, FSemaProject.ModelCount]));
    LogMissingUnits(LMissing);
  end;
  // Units WE failed to parse. Distinct from F1027 on purpose: the source is
  // right there and the analyzer is what broke, so this is our bug, not a
  // project misconfiguration. It used to be silent, which let an internal
  // ERangeError present itself as "no source on the search path".
  if Length(FSemaProject.LoadFailures) > 0 then
  begin
    Log(Format('  INTERNAL: %d unit(s) failed to parse — analyzer defect, not a ' +
      'missing file. Their importers report F1027 as a consequence.',
      [Length(FSemaProject.LoadFailures)]));
    for var LFail in FSemaProject.LoadFailures do
      Log('    ' + LFail);
  end;
  if FSemaProject.StageTimings <> '' then
    Log('  stages: ' + FSemaProject.StageTimings);
  if FAnalyzeOverhead <> '' then
    Log('  wrapper: ' + FAnalyzeOverhead);
  if LMain < 0 then
    Log('Main source not found among analyzed units: ' + FMainSource);
  ScrollMessagesToEnd;
  finally
    LMissing.Free;
  end;
end;

procedure TfrmMain.RunParse;
var
  LSW: TStopwatch;
begin
  if (FProjectDir = '') or not TDirectory.Exists(FProjectDir) then
  begin
    Log('No project open.');
    Exit;
  end;
  CancelAsync;                      // a synchronous parse supersedes the background one
  FReparseTimer.Enabled := False;   // this analysis supersedes a pending one
  ClearMessages;
  // Name the MAIN SOURCE, not just the directory: with several projects in one
  // tree the directory alone does not say which one is being analyzed.
  Log('Analyzing ' + TPath.GetFileName(FMainSource) + ' in ' + FProjectDir +
    ' (' + cbPlatform.Text + ')...');
  Screen.Cursor := crHourGlass;
  try
    LSW := TStopwatch.StartNew;
    if not Analyze then
    begin
      Log('Analysis failed.');
      Exit;
    end;
    LSW.Stop;
    ReportProjectResult(LSW.ElapsedMilliseconds);
  finally
    Screen.Cursor := crDefault;
  end;
end;

// Starts (or restarts) the background analysis. The current FSemaProject/FNav
// stay live and usable until the new build finishes and AsyncTimerTick swaps
// them in — so opening a project or re-analyzing after an edit never blocks
// the UI. APriorityFile (the active editor's file) is front-loaded so it is
// ready first. ALoud = report diagnostics + populate the AST/Semantics views
// when done (open project); quiet = just refresh navigation (edit debounce).
procedure TfrmMain.StartAsyncAnalyze(const APriorityFile: string;
  ALoud: Boolean);
var
  LPlatform: TPasPlatform;
  LSearchPaths, LDefines, LRoots, LPriority: TArray<string>;
  LIdx: Integer;
  LTab: TSourceTab;
begin
  CancelAsync;
  if (FMainSource = '') or not BuildConfig(LPlatform, LSearchPaths, LDefines)
  then
    Exit;
  LRoots := [FMainSource];
  if (APriorityFile <> '') and TFile.Exists(APriorityFile) then
    LPriority := [APriorityFile]
  else
    LPriority := [];

  FLastSearchPaths := LSearchPaths;   // see the field
  FAsyncSession := TPasAsyncSession.Create(LPlatform, LSearchPaths, LDefines,
    LRoots, LPriority);
  FAsyncSession.SetSingleThreadedInner(cbThreading.ItemIndex = 0);
  FAsyncSession.SetReportUnresolvedMembers(True);   // see the synchronous path
  FAsyncSession.SetReportGuessedIfs(True);
  FAsyncSession.SetNamespaces(EffectiveNamespaces(LPlatform));
  for var LDef in PasDefaultUnitAliases(LPlatform) do  // defaults, then project
    FAsyncSession.AddUnitAlias(LDef.Alias, LDef.UnitName);
  if Assigned(FDProj) then
    for var LAlias in FDProj.UnitAliases do
      FAsyncSession.AddUnitAlias(LAlias.Alias, LAlias.UnitName);
  // Snapshot every open editor's current text (main thread) so the background
  // analysis matches what's on screen, unsaved edits included.
  for LIdx := 0 to FOpenFiles.Count - 1 do
  begin
    LTab := TSourceTab(FOpenFiles.Objects[LIdx]);
    FAsyncSession.SetBuffer(LTab.FilePath, LTab.Editor.Text);
  end;

  FAsyncLoud := ALoud;
  FAnalyzeOverhead := '';      // async build reports no wrapper/stage timings
  FAsyncStart := TStopwatch.StartNew;
  FAsyncSession.Start;
  lblProgress.Caption := 'analyzing...';
  FAsyncTimer.Enabled := True;
end;

// Cancels and drains the in-flight background analysis (if any). Called before
// a new analysis supersedes it, on Run Parse, and on shutdown.
procedure TfrmMain.CancelAsync;
begin
  FAsyncTimer.Enabled := False;
  if Assigned(FAsyncSession) then
  begin
    FAsyncSession.Cancel;
    FreeAndNil(FAsyncSession);   // Destroy waits for the worker to drain
  end;
end;

procedure TfrmMain.AsyncTimerTick(Sender: TObject);
var
  LProgress: TPasStagedProgress;
  LError: string;
begin
  if not Assigned(FAsyncSession) then
  begin
    FAsyncTimer.Enabled := False;
    Exit;
  end;
  LProgress := FAsyncSession.Progress;
  lblProgress.Caption := Format('%s %d/%d',
    [LProgress.Phase, LProgress.FullDone, LProgress.Total]);
  if not FAsyncSession.IsDone then
    Exit;

  // Build finished — swap in the new project/navigator on this (UI) thread.
  FAsyncTimer.Enabled := False;
  FAsyncStart.Stop;
  LError := FAsyncSession.LastError;
  ClearLink;
  FreeAndNil(FNav);
  FreeAndNil(FSemaProject);
  FSemaProject := FAsyncSession.TakeProject;
  FreeAndNil(FAsyncSession);
  if Assigned(FSemaProject) then
    FNav := TPasNavigator.Create(FSemaProject);

  if LError <> '' then
    Log('Background analysis error: ' + LError);
  if FAsyncLoud and Assigned(FSemaProject) then
    ReportProjectResult(FAsyncStart.ElapsedMilliseconds);
end;

procedure TfrmMain.ReparseTimerTick(Sender: TObject);
var
  LActive: string;
begin
  FReparseTimer.Enabled := False;
  // Re-analyze in the background (non-blocking, quiet) so navigation keeps
  // matching the edited buffer; the edited (active) file is front-loaded.
  LActive := '';
  if Assigned(pgc.ActivePage) and (pgc.ActivePage is TSourceTab) then
    LActive := TSourceTab(pgc.ActivePage).FilePath;
  StartAsyncAnalyze(LActive, {ALoud} False);
end;

// Any real edit (re)arms the debounce timer; programmatic loads are excluded.
procedure TfrmMain.EditorChange(Sender: TObject);
begin
  if FLoadingFile then
    Exit;
  // Tell the PasTree highlighter its buffer changed — see EnsureFresh's
  // header comment: without this it can only detect a change by rebuilding
  // and comparing the WHOLE buffer on every repainted line, which is what
  // made opening a large file (e.g. System.SysUtils.pas via go-to-
  // declaration) hang. PasTreeHL stays assigned even while SynEdit's own
  // highlighter is the active one, so this is safe regardless of cbHighlighter.
  TSourceTab(TSynEdit(Sender).Parent).PasTreeHL.MarkDirty;
  ClearLink;                        // the stale model no longer matches the text
  FReparseTimer.Enabled := False;
  FReparseTimer.Enabled := True;
end;

{ TNavHistoryPlugin }

constructor TNavHistoryPlugin.Create(AOwner: TCustomSynEdit; AForm: TObject;
  const AFilePath: string);
begin
  // Only the two handlers we act on: a plugin registered for everything is
  // called back on every paint and every line PUT as well.
  inherited Create(AOwner, [phLinesInserted, phLinesDeleted]);
  FForm := AForm;
  FFilePath := AFilePath;
end;

procedure TNavHistoryPlugin.LinesInserted(FirstLine, Count: TSynNativeInt);
begin
  TfrmMain(FForm).ShiftNavHistory(FFilePath, FirstLine, Count, True);
end;

procedure TNavHistoryPlugin.LinesDeleted(FirstLine, Count: TSynNativeInt);
begin
  TfrmMain(FForm).ShiftNavHistory(FFilePath, FirstLine, Count, False);
end;

{ navigation history — Back / Forward }

// Loading a file REPLACES its whole text, which arrives as one enormous
// insertion — nothing has moved as far as the history is concerned. The rules
// themselves are TNavHistory.Shift's.
procedure TfrmMain.ShiftNavHistory(const APath: string;
  AFirstLine, ACount: Integer; AInserted: Boolean);
begin
  if not FLoadingFile then
    FNavHistory.Shift(APath, AFirstLine, ACount, AInserted);
end;

// Where the caret is now, as a history entry. False if no source tab is open.
function TfrmMain.CurrentNavPos(out AEntry: TNavHistoryEntry): Boolean;
var
  LTab: TSourceTab;
begin
  Result := False;
  if not (pgc.ActivePage is TSourceTab) then
    Exit;
  LTab := TSourceTab(pgc.ActivePage);
  AEntry.FilePath := LTab.FilePath;
  AEntry.Line := LTab.Editor.CaretY;
  AEntry.Col := LTab.Editor.CaretX;
  Result := AEntry.FilePath <> '';
end;

{ THE jump. Every navigation goes through here — ctrl+click, the Goto
  Declaration/Implementation pair, and a double-click in the message window —
  so "where did I come from" is recorded in one place instead of three that
  drift apart. (The To-do called the ctrl+click handler "the single place a
  jump happens"; it was not, once the Goto actions and the message window
  existed. This makes the statement true rather than working around it.)

  The ORIGIN is pushed before the target: it is what Back returns to. }
procedure TfrmMain.NavigateTo(const APath: string; ALine, ACol: Integer);
var
  LOrigin, LTarget: TNavHistoryEntry;
  LHasOrigin: Boolean;
  LEditor: TSynEdit;
begin
  // Read BEFORE the jump, obviously — but also before OpenFileTab, which can
  // change the active page and with it what "here" means.
  LHasOrigin := not FNavBusy and CurrentNavPos({out} LOrigin);
  LEditor := OpenFileTab(APath);   // the existing tab if it is already open
  if LEditor = nil then
    Exit;
  LEditor.CaretXY := BufferCoord(ACol, ALine);
  LEditor.EnsureCursorPosVisible;
  if LEditor.CanFocus then
    LEditor.SetFocus;
  if FNavBusy then
    Exit;   // Back/Forward is moving the index itself
  LTarget.FilePath := APath;
  LTarget.Line := ALine;
  LTarget.Col := ACol;
  FNavHistory.RecordJump(LOrigin, LHasOrigin, LTarget);
end;

// Moves to a recorded position without recording anything, refreshing the
// entry being LEFT from the live caret first — see TNavHistory.UpdateCurrent.
procedure TfrmMain.GoToNavEntry(const AEntry: TNavHistoryEntry);
begin
  FNavBusy := True;
  try
    NavigateTo(AEntry.FilePath, AEntry.Line, AEntry.Col);
  finally
    FNavBusy := False;
  end;
end;

{ The mouse's back/forward buttons.

  Not through TSynEdit.OnMouseDown: VCL's `TMouseButton` is (mbLeft, mbRight,
  mbMiddle) and never reports an X button, so the handler is never called for
  them. WM_XBUTTONDOWN goes to the focused control, which is the editor, so
  Application.OnMessage is the one place that sees it without subclassing every
  editor as it is created. Kept to an integer compare — this runs for every
  message in the application. }
procedure TfrmMain.AppMessage(var AMsg: TMsg; var AHandled: Boolean);
const
  // winuser.h; Winapi.Windows declares the VK_ forms but not these.
  XBUTTON_BACK = 1;
  XBUTTON_FORWARD = 2;
begin
  if AMsg.message <> WM_XBUTTONDOWN then
    Exit;
  case HiWord(AMsg.wParam) of
    XBUTTON_BACK:
      if NavBackAction.Enabled then
      begin
        NavBackAction.Execute;
        AHandled := True;
      end;
    XBUTTON_FORWARD:
      if NavForwardAction.Enabled then
      begin
        NavForwardAction.Execute;
        AHandled := True;
      end;
  end;
end;

procedure TfrmMain.NavBackActionExecute(Sender: TObject);
var
  LHere, LEntry: TNavHistoryEntry;
begin
  if CurrentNavPos({out} LHere) then
    FNavHistory.UpdateCurrent(LHere);
  if FNavHistory.GoBack({out} LEntry) then
    GoToNavEntry(LEntry);
end;

procedure TfrmMain.NavBackActionUpdate(Sender: TObject);
begin
  TAction(Sender).Enabled := FNavHistory.CanGoBack;
end;

procedure TfrmMain.NavForwardActionExecute(Sender: TObject);
var
  LHere, LEntry: TNavHistoryEntry;
begin
  if CurrentNavPos({out} LHere) then
    FNavHistory.UpdateCurrent(LHere);
  if FNavHistory.GoForward({out} LEntry) then
    GoToNavEntry(LEntry);
end;

procedure TfrmMain.NavForwardActionUpdate(Sender: TObject);
begin
  TAction(Sender).Enabled := FNavHistory.CanGoForward;
end;

{ highlighter context }

// The context a tab's highlighter must preprocess under: exactly what the
// ANALYSIS runs with, from the one function that computes it.
procedure TfrmMain.ApplyHighlighterContext(AHL: TPasTreeSynHighlighter;
  const APath: string);
var
  LPlat: TPasPlatform;
  LPaths, LDefines: TArray<string>;
begin
  if BuildConfig(LPlat, LPaths, LDefines) then
    AHL.SetContext(APath, LPaths, LDefines, LPlat);
end;

{ Closes every source tab.

  Called when a project is (re-)opened, and that is the whole reason it exists:
  a tab carries a preprocessing context — search paths, defines, platform —
  fixed when it was created. Keeping tabs across an open leaves them painting
  under the PREVIOUS project's context, or the previous build configuration's,
  which is visible as the wrong branches greyed out. Re-applying the context to
  survivors would fix the colours and still leave files from a project that is
  no longer open sitting in the tab strip. }
procedure TfrmMain.CloseAllTabs;
var
  LIdx: Integer;
begin
  ClearLink;   // FLinkTab is about to be freed
  for LIdx := FOpenFiles.Count - 1 downto 0 do
    TSourceTab(FOpenFiles.Objects[LIdx]).Free;
  FOpenFiles.Clear;
end;

{ build configuration }

const
  // What the IDE's own project template offers, and the only two names that
  // mean anything without a .dproj to read them from.
  DEFAULT_CONFIGS: array[0..1] of string = ('Debug', 'Release');

{ Fills cbConfig for the project just opened and selects the active one.

  With a .dproj, the names come from the project — a real one rarely stops at
  Debug/Release, and a name we invented would silently evaluate to the
  project's fallback instead. `Base` is dropped: it is the shared parent every
  configuration inherits from, not something you build. }
procedure TfrmMain.PopulateConfigCombo;
var
  LName: string;
  LIdx: Integer;
begin
  cbConfig.Items.BeginUpdate;
  try
    cbConfig.Items.Clear;
    if Assigned(FDProj) and (Length(FDProj.Configurations) > 0) then
    begin
      for LName in FDProj.Configurations do
        if not SameText(LName, 'Base') then
          cbConfig.Items.Add(LName);
    end;
    // No .dproj, or one that declares nothing usable.
    if cbConfig.Items.Count = 0 then
      for LName in DEFAULT_CONFIGS do
        cbConfig.Items.Add(LName);
  finally
    cbConfig.Items.EndUpdate;
  end;
  // The one actually in effect: what the .dproj resolved to, else Debug.
  LIdx := -1;
  if Assigned(FDProj) and (FDProj.Config <> '') then
    LIdx := cbConfig.Items.IndexOf(FDProj.Config);
  if LIdx < 0 then
    LIdx := cbConfig.Items.IndexOf(DEFAULT_CONFIGS[0]);
  if LIdx < 0 then
    LIdx := 0;
  // Assigning ItemIndex does NOT fire OnChange, so this cannot re-enter
  // OpenProject through the handler below.
  cbConfig.ItemIndex := LIdx;
end;

// The active configuration name, whatever the project turned out to be.
function TfrmMain.SelectedConfig: string;
begin
  if cbConfig.ItemIndex >= 0 then
    Result := cbConfig.Items[cbConfig.ItemIndex]
  else
    Result := DEFAULT_CONFIGS[0];
end;

procedure TfrmMain.cbConfigChange(Sender: TObject);
begin
  if FProjectFile = '' then
    Exit;
  // Re-OPEN rather than just re-analyze: a configuration changes the defines,
  // the search paths and — through per-config DCCReference conditions — the
  // file list itself, so nothing short of reading the .dproj again is honest.
  FConfigOverride := SelectedConfig;
  OpenProject(FProjectFile);
end;

{ recent projects — the Open Project split button's drop-down }

// Turns the plain button into a split button whose arrow drops the list. A
// real bsSplitButton rather than a second button next to it: the primary click
// must keep doing exactly what it always did (browse), and Windows draws and
// keyboard-handles the arrow half for us.
procedure TfrmMain.SetupRecentMenu;
begin
  FRecentMenu := TPopupMenu.Create(Self);
  FRecentMenu.OnPopup := RecentMenuPopup;
  btnOpen.DropDownMenu := FRecentMenu;
end;

// Rebuilt on every drop, not kept in sync as projects are opened: the list is
// RECENT_MAX items at most, and the alternative is remembering to touch the
// menu everywhere a project can be opened (the browse dialog, the .dpk
// buttons, the RTL/VCL/FMX shortcuts, the startup sample).
procedure TfrmMain.RecentMenuPopup(Sender: TObject);
var
  LItem: TMenuItem;
  LPaths: TArray<string>;
  LIdx: Integer;
begin
  FRecentMenu.Items.Clear;
  LPaths := FSettings.ExistingRecent;
  if Length(LPaths) = 0 then
  begin
    // An empty menu drops an empty grey box, which reads as a glitch. Say why.
    LItem := TMenuItem.Create(FRecentMenu);
    LItem.Caption := '(no recent projects)';
    LItem.Enabled := False;
    FRecentMenu.Items.Add(LItem);
    Exit;
  end;
  for LIdx := 0 to High(LPaths) do
  begin
    LItem := TMenuItem.Create(FRecentMenu);
    // Numbered 1..N in list order, plainly. It used to be `(LIdx + 1) mod 10`,
    // which was reaching for a single-digit ACCELERATOR and, once the list
    // grew past ten, printed 1..9, 0, then 1..9 again: numbers that repeat and
    // appear to run backwards at the tenth row.
    //
    // The accelerator is what the `&` was for, so it is kept exactly where it
    // is unambiguous — the first nine. `&10` would bind the key `1`, which
    // item 1 already owns, and Windows resolves such a clash by cycling rather
    // than choosing: a shortcut that opens the wrong project half the time is
    // worse than no shortcut on that row.
    //
    // File name first, directory after: twenty full paths into a component
    // tree are unreadable, and the leaf is what tells them apart.
    if LIdx < 9 then
      LItem.Caption := Format('&%d  %s', [LIdx + 1,
        TPath.GetFileName(LPaths[LIdx])])
    else
      LItem.Caption := Format('%d  %s', [LIdx + 1,
        TPath.GetFileName(LPaths[LIdx])]);
    LItem.Caption := LItem.Caption + '   ' +
      TPath.GetDirectoryName(LPaths[LIdx]);
    LItem.Hint := LPaths[LIdx];
    LItem.Tag := LIdx;
    LItem.OnClick := RecentItemClick;
    FRecentMenu.Items.Add(LItem);
  end;
end;

procedure TfrmMain.RecentItemClick(Sender: TObject);
var
  LPaths: TArray<string>;
  LIdx: Integer;
begin
  // Re-read rather than trusting the Tag against a stale list: the menu was
  // built at drop time and a file can have gone since.
  LPaths := FSettings.ExistingRecent;
  LIdx := TMenuItem(Sender).Tag;
  if (LIdx >= 0) and (LIdx <= High(LPaths)) then
    OpenProject(LPaths[LIdx]);
end;

{ persisted settings }

const
  // Key names, so a hand-edited .ini and the code agree.
  SET_HIGHLIGHTER = 'Highlighter';
  SET_THREADING = 'Threading';
  SET_HIGHLIGHTCOLOR = 'HighlightColor';

procedure TfrmMain.LoadSettings;
begin
  // Clamped to the items actually present: a hand-edited or stale .ini must
  // not leave a combo with an out-of-range ItemIndex (-1, blank).
  cbHighlighter.ItemIndex := EnsureRange(
    FSettings.ReadInt(SET_HIGHLIGHTER, cbHighlighter.ItemIndex),
    0, cbHighlighter.Items.Count - 1);
  cbThreading.ItemIndex := EnsureRange(
    FSettings.ReadInt(SET_THREADING, cbThreading.ItemIndex),
    0, cbThreading.Items.Count - 1);
  FIdentHighlightColor := TColor(FSettings.ReadInt(SET_HIGHLIGHTCOLOR,
    Integer(FIdentHighlightColor)));
  cbHighlightColor.Selected := FIdentHighlightColor;
  // NB the target PLATFORM is deliberately NOT persisted. OpenProject sets it
  // from the .dproj being opened, so a stored value would be overwritten
  // before it was ever visible — remembering it would be a setting that does
  // nothing.
end;

procedure TfrmMain.StoreSettings;
begin
  FSettings.WriteInt(SET_HIGHLIGHTER, cbHighlighter.ItemIndex);
  FSettings.WriteInt(SET_THREADING, cbThreading.ItemIndex);
  FSettings.WriteInt(SET_HIGHLIGHTCOLOR, Integer(FIdentHighlightColor));
end;

{ event handlers }

procedure TfrmMain.btnOpenClick(Sender: TObject);
var
  LDlg: TOpenDialog;
begin
  LDlg := TOpenDialog.Create(Self);
  try
    LDlg.Filter :=
      'Delphi project (*.dpr;*.dpk;*.dproj)|*.dpr;*.dpk;*.dproj|' +
      'All files|*.*';
    LDlg.Options := LDlg.Options + [ofFileMustExist];
    if LDlg.Execute then
      OpenProject(LDlg.FileName);
  finally
    LDlg.Free;
  end;
end;

procedure TfrmMain.btnParseClick(Sender: TObject);
begin
  RunParse;
end;

// The RAD Studio installation root: %BDS% (set under a RAD Studio command
// prompt) if present, else the registry (current user then machine-wide,
// highest installed version). '' if none found.
function TfrmMain.StudioRoot: string;
const
  ROOTS: array [0 .. 1] of HKEY = (HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE);
var
  LReg: TRegistry;
  LKeys: TStringList;
  LIdx: Integer;
  LBest: Double;
  LVer: Double;
  LDir: string;
begin
  Result := GetEnvironmentVariable('BDS');
  if (Result <> '') and TDirectory.Exists(Result) then
    Exit(ExcludeTrailingPathDelimiter(Result));
  Result := '';
  LBest := 0;
  LKeys := TStringList.Create;
  try
    for LIdx := Low(ROOTS) to High(ROOTS) do
    begin
      LReg := TRegistry.Create(KEY_READ);
      try
        LReg.RootKey := ROOTS[LIdx];
        if not LReg.OpenKeyReadOnly('SOFTWARE\Embarcadero\BDS') then
          Continue;
        LKeys.Clear;
        LReg.GetKeyNames(LKeys);
        for var LKey in LKeys do
          if TryStrToFloat(LKey, LVer, TFormatSettings.Invariant) and
             (LVer > LBest) and
             LReg.OpenKeyReadOnly('\SOFTWARE\Embarcadero\BDS\' + LKey) then
          begin
            LDir := LReg.ReadString('RootDir');
            if (LDir <> '') and TDirectory.Exists(LDir) then
            begin
              LBest := LVer;
              // WITHOUT the trailing '\' the registry writes ('...\23.0\'):
              // ReadIdePaths matches this value against the same RootDir
              // through ExcludeTrailingPathDelimiter, and while the slash
              // survived here the two never compared equal — so EVERY
              // version was skipped and the whole IDE library/browsing set
              // was silently lost, leaving only the four bare-RTL fallback
              // dirs. That is what turned Vcl.Forms and every third-party
              // FastMM4 into F1027 on a project that compiles.
              Result := ExcludeTrailingPathDelimiter(LDir);
            end;
          end;
      finally
        LReg.Free;
      end;
    end;
  finally
    LKeys.Free;
  end;
end;

// Source directories the IDE ITSELF uses to resolve go-to-declaration
// beyond the project's own paths: the registry Library `Search Path` (for
// the active platform — third-party component sources land
// here) and the `Browsing Path` ($(BDS)\SOURCE\VCL, rtl\sys/common/win,
// fmx, ...). Macros ($(BDS), $(Platform), and user-defined ones like
// $(avi3rdlib) from the `Environment Variables` key) are expanded; only
// directories that exist survive. Falls back to the bare RTL source dirs
// when Studio/registry aren't available.
function TfrmMain.ExtraSearchPaths: TArray<string>;
var
  LSeen: TDictionary<string, Boolean>;
  LVars: TDictionary<string, string>;
  LList: TList<string>;

  function Expand(const APath: string): string;
  var
    LFrom, LTo: Integer;
    LName, LVal: string;
  begin
    Result := APath;
    LFrom := Pos('$(', Result);
    while LFrom > 0 do
    begin
      LTo := Pos(')', Result, LFrom);
      if LTo = 0 then
        Exit;
      LName := Copy(Result, LFrom + 2, LTo - LFrom - 2);
      if not LVars.TryGetValue(LowerCase(LName), LVal) then
        LVal := GetEnvironmentVariable(LName);   // '' when undefined
      Result := Copy(Result, 1, LFrom - 1) + LVal +
        Copy(Result, LTo + 1, MaxInt);
      LFrom := Pos('$(', Result);
    end;
  end;

  procedure AddPaths(const ASemiList: string);
  var
    LDir: string;
  begin
    for var LOne in ASemiList.Split([';']) do
    begin
      LDir := Expand(Trim(LOne));
      if (LDir = '') or (Pos('$(', LDir) > 0) then
        Continue;   // unresolvable macro left — not a usable dir
      if TDirectory.Exists(LDir) and
         not LSeen.ContainsKey(LowerCase(LDir)) then
      begin
        LSeen.Add(LowerCase(LDir), True);
        LList.Add(LDir);
      end;
    end;
  end;

  procedure ReadIdePaths;
  var
    LReg: TRegistry;
    LKey, LPlat: string;
    LNames: TStringList;
  begin
    // Version-specific key of the FStudioRoot install: try every BDS\<ver>
    // whose RootDir matches, falling back to the highest with the values.
    if cbPlatform.ItemIndex = 1 then
      LPlat := 'Win64'
    else
      LPlat := 'Win32';
    LReg := TRegistry.Create(KEY_READ);
    LNames := TStringList.Create;
    try
      LReg.RootKey := HKEY_CURRENT_USER;
      if not LReg.OpenKeyReadOnly('SOFTWARE\Embarcadero\BDS') then
        Exit;
      LReg.GetKeyNames(LNames);
      LNames.Sort;   // ascending; iterate from the highest version down
      for var LIdx := LNames.Count - 1 downto 0 do
      begin
        LKey := '\SOFTWARE\Embarcadero\BDS\' + LNames[LIdx];
        if not LReg.OpenKeyReadOnly(LKey) then
          Continue;
        if not SameText(ExcludeTrailingPathDelimiter(
             LReg.ReadString('RootDir')), FStudioRoot) then
          Continue;
        // Macro seeds: $(BDS)/$(BDSLIB)/$(Platform) + user-defined env vars.
        LVars.AddOrSetValue('bds', FStudioRoot);
        LVars.AddOrSetValue('bdslib', TPath.Combine(FStudioRoot, 'lib'));
        LVars.AddOrSetValue('platform', LPlat);
        if LReg.OpenKeyReadOnly(LKey + '\Environment Variables') then
        begin
          LNames.Clear;
          LReg.GetValueNames(LNames);
          for var LName in LNames do
            LVars.AddOrSetValue(LowerCase(LName), LReg.ReadString(LName));
        end;
        if LReg.OpenKeyReadOnly(LKey + '\Library\' + LPlat) then
        begin
          AddPaths(LReg.ReadString('Search Path'));
          AddPaths(LReg.ReadString('Browsing Path'));
        end;
        Break;
      end;
    finally
      LNames.Free;
      LReg.Free;
    end;
  end;

begin
  if FExtraSearchPathsBuilt and (FExtraSearchPathsPlat = cbPlatform.ItemIndex)
  then
    Exit(FExtraSearchPathsCache);
  Result := [];
  if FStudioRoot = '' then
    Exit;
  LSeen := TDictionary<string, Boolean>.Create;
  LVars := TDictionary<string, string>.Create;
  LList := TList<string>.Create;
  try
    ReadIdePaths;
    // Bare-RTL fallback/completion (also covers a registry-less Studio).
    var LRtl := TPath.Combine(FStudioRoot, 'source\rtl');
    for var LSub in ['sys', 'common', 'win', 'net'] do
      AddPaths(TPath.Combine(LRtl, LSub));
    Result := LList.ToArray;
  finally
    LList.Free;
    LVars.Free;
    LSeen.Free;
  end;
  FExtraSearchPathsCache := Result;
  FExtraSearchPathsPlat := cbPlatform.ItemIndex;
  FExtraSearchPathsBuilt := True;
end;

// Opens and analyzes the installed Studio's Win RTL package project
// (source\rtl\BuildWinRTL.dproj — its `contains` list is the full Windows
// RTL, ~310 units) through the regular project flow.
procedure TfrmMain.btnParseRtlClick(Sender: TObject);
var
  LDProj: string;
begin
  LDProj := TPath.Combine(FStudioRoot, 'source\rtl\BuildWinRTL.dproj');
  if not TFile.Exists(LDProj) then
  begin
    Log('RTL project not found: ' + LDProj);
    Log('(is RAD Studio installed with sources?)');
    Exit;
  end;
  OpenProject(LDProj);
  RunParse;
end;

const
  CDPKTemplate = '''
package %s;

{$R *.res}
{$IFDEF IMPLICITBUILDING This IFDEF should not be used by users}
{$ALIGN 8}
{$ASSERTIONS ON}
{$BOOLEVAL OFF}
{$DEBUGINFO OFF}
{$EXTENDEDSYNTAX ON}
{$IMPORTEDDATA ON}
{$IOCHECKS ON}
{$LOCALSYMBOLS ON}
{$LONGSTRINGS ON}
{$OPENSTRINGS ON}
{$OPTIMIZATION ON}
{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}
{$REFERENCEINFO OFF}
{$SAFEDIVIDE OFF}
{$STACKFRAMES OFF}
{$TYPEDADDRESS OFF}
{$VARSTRINGCHECKS ON}
{$WRITEABLECONST OFF}
{$MINENUMSIZE 1}
{$IMAGEBASE $400000}
{$DEFINE RELEASE}
{$ENDIF IMPLICITBUILDING}
{$RUNONLY}
{$IMPLICITBUILD OFF}

requires
  rtl;

contains
%s;
end.
''';

const
  { Dot-delimited name SEGMENTS marking a unit as belonging to a non-Windows
    platform. Matched as whole segments, never as substrings, so a name like
    'FMX.Macros' cannot read as a Mac unit. This is only the FALLBACK filter
    for a Studio install with no compiled lib directory — Win32UnitIndex below
    is the real one, and is strictly better (see its own comment). }
  CNonWindowsSegments: array[0..9] of string = (
    'mac', 'osx', 'ios', 'android', 'linux', 'posix', 'cocoa', 'gles',
    'metal', 'jni');

{ Basenames (lower-cased, extension-less) of every unit the installed Studio
  actually COMPILES for Win32: exactly those with a .dcu under
  lib\win32\release. This is Embarcadero's own answer to "is this unit part of
  the Win32 build", which beats any name-based guess — measured against
  Studio 37.0's source tree it additionally excludes:
    - FMX.BiometricAuth and FMX.Media.AVFoundation — Apple-only, but with no
      platform word anywhere in the name;
    - the IDE's own timestamped backup files left in the source tree
      ('FMX.ScrollBox-2025-10-02 14.17.14.pas'), which are not compilable
      units at all;
  while KEEPING Win32 units a 'Vcl.*'-style mask would have dropped
  (CtlConsts, CtlPanel, StdMain). Empty when the lib directory is missing (a
  sources-only install); the caller then falls back to the name filter. }
function TfrmMain.Win32UnitIndex: TDictionary<string, Boolean>;
var
  LLibDir: string;
begin
  Result := TDictionary<string, Boolean>.Create;
  if FStudioRoot = '' then
    Exit;
  LLibDir := TPath.Combine(FStudioRoot, 'lib\win32\release');
  if not TDirectory.Exists(LLibDir) then
    Exit;
  for var LDcu in TDirectory.GetFiles(LLibDir, '*.dcu') do
    Result.AddOrSetValue(
      LowerCase(TPath.GetFileNameWithoutExtension(LDcu)), True);
end;

function TfrmMain.IsNonWindowsUnitName(const AUnitName: string): Boolean;
begin
  Result := False;
  for var LSegment in AUnitName.Split(['.']) do
    for var LBad in CNonWindowsSegments do
      if SameText(LSegment, LBad) then
        Exit(True);
end;

{ Writes a package whose `contains` list is every unit of ASourceSubDir that
  belongs to the Win32 build. The parser reads a package's `contains` as a
  uses graph (see TPasParser's package branch), so analyzing this one file
  pulls in the whole closure — the same trick the Parse RTL button gets for
  free from the shipped BuildWinRTL.dproj, which is why VCL/FMX need one
  generated: Studio ships no equivalent for them.

  Unit paths are ABSOLUTE on purpose: the generated package lives next to the
  demo, not in the (read-only) Studio source tree, so a bare `in 'X.pas'`
  would resolve against the wrong directory. }
function TfrmMain.WriteBuildPackage(const APackageFile, APackageName,
  ASourceSubDir: string): Boolean;
var
  LIndex: TDictionary<string, Boolean>;
  LUnits: TStringBuilder;
  LSourceDir, LUnitName: string;
  LKept, LSkipped: Integer;
begin
  Result := False;
  LSourceDir := TPath.Combine(FStudioRoot, ASourceSubDir);
  if not TDirectory.Exists(LSourceDir) then
  begin
    Log('Source directory not found: ' + LSourceDir);
    Log('(is RAD Studio installed with sources?)');
    Exit;
  end;
  LKept := 0;
  LSkipped := 0;
  LIndex := Win32UnitIndex;
  LUnits := TStringBuilder.Create;
  try
    for var LFileName in TDirectory.GetFiles(LSourceDir, '*.pas') do
    begin
      LUnitName := TPath.GetFileNameWithoutExtension(LFileName);
      if LIndex.Count > 0 then
      begin
        if not LIndex.ContainsKey(LowerCase(LUnitName)) then
        begin
          Inc(LSkipped);
          Continue;
        end;
      end
      else if IsNonWindowsUnitName(LUnitName) then
      begin
        Inc(LSkipped);
        Continue;
      end;
      if LKept > 0 then
        LUnits.Append(',').AppendLine;
      LUnits.Append(Format('  %s in ''%s''', [LUnitName, LFileName]));
      Inc(LKept);
    end;
    if LKept = 0 then
    begin
      Log('No Win32 units found under ' + LSourceDir);
      Exit;
    end;
    TFile.WriteAllText(APackageFile,
      Format(CDPKTemplate, [APackageName, LUnits.ToString]));
    Result := True;
    if LIndex.Count > 0 then
      Log(Format('%s: %d unit(s); %d skipped (no Win32 .dcu — not part of ' +
        'this platform''s build)', [APackageName, LKept, LSkipped]))
    else
      Log(Format('%s: %d unit(s); %d skipped by name (no compiled lib dir — ' +
        'using the fallback filter)', [APackageName, LKept, LSkipped]));
  finally
    LUnits.Free;
    LIndex.Free;
  end;
end;

{ Regenerates the package and opens it through the regular project flow.
  Always regenerates rather than reusing a previous file: the unit list is a
  function of the installed Studio and its compiled lib set, and a stale one
  would silently analyze the wrong thing. A directory listing is cheap next
  to the analysis it feeds. }
procedure TfrmMain.ParseGeneratedPackage(const APackageName,
  ASourceSubDir: string);
var
  LDir, LPackageFile: string;
begin
  if FStudioRoot = '' then
  begin
    Log('RAD Studio installation not found.');
    Exit;
  end;
  LDir := TPath.Combine(ExeDir, 'Sample');
  if not TDirectory.Exists(LDir) then
    TDirectory.CreateDirectory(LDir);
  LPackageFile := TPath.Combine(LDir, APackageName + '.dpk');
  // Gate on the WRITE, not on the file existing: a previous run leaves one
  // behind, so an existence check would silently reopen a stale package if
  // regeneration failed (Studio sources removed, say).
  if not WriteBuildPackage(LPackageFile, APackageName, ASourceSubDir) then
    Exit;   // WriteBuildPackage already logged why
  OpenProject(LPackageFile);
  RunParse;
end;

procedure TfrmMain.btnParseVclClick(Sender: TObject);
begin
  ParseGeneratedPackage('BuildWinVCL', 'source\vcl');
end;

procedure TfrmMain.btnParseFmxClick(Sender: TObject);
begin
  ParseGeneratedPackage('BuildWinFMX', 'source\fmx');
end;

procedure TfrmMain.FormKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_F9 then
  begin
    RunParse;
    Key := 0;
  end;
end;

procedure TfrmMain.vstFilesGetText(Sender: TBaseVirtualTree; Node: PVirtualNode;
  Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);
var
  LData: PPasNodeData;
begin
  LData := PPasNodeData(Sender.GetNodeData(Node));
  if (LData <> nil) and (LData.Index >= 0) and (LData.Index < FFileList.Count) then
    CellText := ExtractRelativePath(IncludeTrailingPathDelimiter(FProjectDir),
      FFileList[LData.Index])
  else
    CellText := '';
end;

procedure TfrmMain.vstFilesChange(Sender: TBaseVirtualTree; Node: PVirtualNode);
var
  LData: PPasNodeData;
begin
  if Node = nil then
    Exit;
  LData := PPasNodeData(Sender.GetNodeData(Node));
  if (LData <> nil) and (LData.Index >= 0) and (LData.Index < FFileList.Count) then
    OpenFileTab(FFileList[LData.Index]);
end;

{ View Unit (Ctrl+F12) — a modal picker over the project's units.

  Enabled whenever the project has files to show; the picker's own "Uses Units"
  box is what depends on an analysis, and it asks for that state itself while
  it is open (see TfrmUnitPicker) rather than being told once. }
procedure TfrmMain.ViewUnitActionUpdate(Sender: TObject);
begin
  ViewUnitAction.Enabled := FFileList.Count > 0;
end;

procedure TfrmMain.ViewUnitActionExecute(Sender: TObject);
var
  LSource: TPasUnitPickerSource;
  LPath: string;
begin
  LSource.ProjectName := TPath.GetFileName(FProjectFile);
  if LSource.ProjectName = '' then
    LSource.ProjectName := TPath.GetFileName(FMainSource);
  LSource.ProjectFiles :=
    function: TArray<string>
    begin
      Result := FFileList.ToStringArray;
    end;
  // The analysed CLOSURE, which is a superset of the project's own files and
  // includes every RTL/VCL unit reached. Read on the UI thread only, and only
  // when UsesReady said yes — the same FAnalyzing/FAsyncSession guard every
  // other FSemaProject reader here uses, for the reason FAnalyzing documents.
  LSource.UsesFiles :=
    function: TArray<string>
    var
      LIdx: Integer;
    begin
      Result := nil;
      if not Assigned(FSemaProject) then
        Exit;
      SetLength(Result, FSemaProject.ModelCount);
      for LIdx := 0 to FSemaProject.ModelCount - 1 do
        Result[LIdx] := FSemaProject.ModelFile(LIdx);
    end;
  LSource.UsesReady :=
    function: Boolean
    begin
      Result := Assigned(FSemaProject) and not Assigned(FAsyncSession) and
        not FAnalyzing;
    end;
  LPath := PickUnit(Self, LSource);
  if LPath <> '' then
    OpenFileTab(LPath);   // the same call the file tree's own click makes
end;

// Swaps the highlighter on every currently-open source tab so an already-open
// file can be A/B compared without reopening it.
procedure TfrmMain.cbHighlighterChange(Sender: TObject);
var
  LIdx: Integer;
  LTab: TSourceTab;
begin
  for LIdx := 0 to FOpenFiles.Count - 1 do
  begin
    LTab := TSourceTab(FOpenFiles.Objects[LIdx]);
    if cbHighlighter.ItemIndex = 0 then
      LTab.Editor.Highlighter := FSynPasHL
    else
      LTab.Editor.Highlighter := LTab.PasTreeHL;
  end;
end;

{ "same identifier" highlight }

// TColorBox's own [cbCustomColors] style calls this to populate the
// dropdown — the standard VCL color-picker combo, restricted to exactly our
// curated palette (no standard/extended/system colors mixed in). Swatch +
// name drawing, custom-color entry, keyboard nav etc. all come from the
// component itself; nothing to hand-roll here.
procedure TfrmMain.cbHighlightColorGetColors(Sender: TCustomColorBox;
  Items: TStrings);
var
  LColor: TNamedColor;
begin
  for LColor in IDENT_HIGHLIGHT_COLORS do
    Items.AddObject(LColor.Name, TObject(LColor.Color));
end;

// Broadcasts the newly picked background color to every open tab's OWN
// highlighter instance (each caches its own buffer, so there is no single
// shared highlighter to update — see TSourceTab/OpenFileTab) and repaints
// them. New tabs opened afterward pick up FIdentHighlightColor at creation
// (see OpenFileTab).
procedure TfrmMain.cbHighlightColorChange(Sender: TObject);
var
  LIdx: Integer;
  LTab: TSourceTab;
begin
  FIdentHighlightColor := cbHighlightColor.Selected;
  for LIdx := 0 to FOpenFiles.Count - 1 do
  begin
    LTab := TSourceTab(FOpenFiles.Objects[LIdx]);
    LTab.PasTreeHL.SetSameIdentColor(FIdentHighlightColor);
    LTab.Editor.Invalidate;
  end;
end;

// SynEdit's own selection-change notification — fires for any selection
// change regardless of input method (mouse drag, double-click word-select,
// Shift+arrow, Ctrl+A, ...). A plain identifier selection arms the "same
// identifier" highlight on THIS tab's own highlighter instance; anything
// else (no selection, a multi-word/punctuation selection) clears it. Plain
// NAME match, no semantic resolution — see PasTreeDemo.Highlighter.
// SetSameIdentHighlight's own header comment.
procedure TfrmMain.EditorStatusChange(Sender: TObject;
  Changes: TSynStatusChanges);
var
  LEditor: TSynEdit;
  LTab: TSourceTab;
  LText: string;
  LTok: Integer;
begin
  // FLoadingFile: LTab.PasTreeHL isn't assigned until AFTER OpenFileTab's own
  // Result.Lines.LoadFromFile call returns (see its own comments) — loading
  // text can itself fire a selection-change notification, which would
  // otherwise dereference a still-nil PasTreeHL below.
  if FLoadingFile or not (scSelection in Changes) then
    Exit;
  LEditor := TSynEdit(Sender);
  LTab := TSourceTab(LEditor.Parent);
  LText := LEditor.SelText;
  if LEditor.SelAvail and IsPlainIdentifier(LText) then
  begin
    LTok := LTab.PasTreeHL.RawTokenAt(LEditor.BlockBegin.Line,
      LEditor.BlockBegin.Char);
    LTab.PasTreeHL.SetSameIdentHighlight(LText, LTok, LTok);
  end
  else
    LTab.PasTreeHL.SetSameIdentHighlight('', -1, -1);
  LEditor.Invalidate;
end;

initialization
  // The .dfm streams these third-party controls; ensure the statically-linked
  // build (no design-time packages) can find their classes.
  RegisterClasses([TSynEdit, TVirtualStringTree]);

end.
