unit PasTreeDemo.Main;

{
  PasTree demo - a small VCL host that opens a Delphi project, analyzes it with
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
  System.Generics.Defaults,
  System.JSON, System.Diagnostics, System.Math, System.Win.Registry,
  Winapi.Windows, Winapi.Messages, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls,
  Vcl.ExtCtrls, Vcl.Dialogs, Vcl.Graphics, Vcl.Clipbrd,
  SynEdit, SynEditTypes, SynEditHighlighter, SynHighlighterJSON, SynFunc,
  SynHighlighterPas, SynCompletionProposal,
  VirtualTrees, VirtualTrees.Types,
  PasTree.Types, PasTree.Platforms, PasTree.SourceManager, PasTree.Preprocessor,
  PasTree.Ast,
  PasTree.Ast.Json,
  PasTree.Parser, PasTree.Project, PasTree.DProj,
  PasTree.Sema.Diagnostics, PasTree.Sema.Model, PasTree.Sema.Builtins,
  PasTree.Sema.Types, PasTree.Sema.Resolver, PasTree.Sema.Project,
  PasTree.Sema.Nav, PasTree.Sema.Async, PasTree.Sema.Complete,
  PasTree.Sema.Dump, PasTree.Version, VirtualTrees.BaseAncestorVCL, VirtualTrees.BaseTree, VirtualTrees.AncestorVCL, SynEditCodeFolding,
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
  // navigation target (FilePath/Line/Col - resolved from the diagnostic's OWN
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
    double-clickable because of these three fields - a count alone tells you a
    library is missing but not which of your units asked for it. }
  TPasMissingUnit = record
    Count: Integer;
    FirstFile: string;
    FirstLine, FirstCol: Integer;
  end;
  // vtMessages node payload: an index into FMsgVisible (itself indexing the
  // master FMsgLog) - mirrors TPasNodeData/FFileList's own convention so a
  // managed field (string) never has to live in VST node data.
  TPasMsgNodeData = record
    Index: Integer;
  end;
  PPasMsgNodeData = ^TPasMsgNodeData;

  { Find References results, one tab per search (see FindReferencesAction).

    The tree has THREE row shapes: one flat DECL row at the very top (where
    the symbol is defined - never counted in the tab caption, which is a USE
    count), then a GROUP node per file ("<name> [<count>]", the Delphi Search
    Results panel this mirrors), a HIT node per reference underneath each.
    All three share one node-data shape - never a managed field in it, same
    discipline TPasMsgNodeData's own comment states (VST's raw node-data
    blocks are never finalized) - so every row's string text lives on the
    TAB object instead, indexed by Index. }
  TPasRefNodeKind = (rnDecl, rnGroup, rnHit);
  TPasRefNodeData = record
    Kind: TPasRefNodeKind;
    Index: Integer;   // Groups[Index] or Hits[Index] - unused for rnDecl,
                       // there is at most one
  end;
  PPasRefNodeData = ^TPasRefNodeData;

  TFindRefGroup = record
    FilePath: string;
    FirstHit, Count: Integer;   // Hits is sorted (FilePath, Line) already
  end;

  // Display-ready form of one TPasRefHit: "Line N: " prefixed, leading
  // snippet whitespace trimmed off, HiFrom/HiTo shifted to match both -
  // computed once at tab-population time so FindRefTreeGetText and
  // FindRefTreeDrawText can never disagree about what those two steps did
  // to the offsets. PrefixLen marks where the "Line N: " run ends and the
  // CODE run begins, for DrawText's own coloring (see FindRefTreeDrawText);
  // HiFrom is always >= PrefixLen, since the match is always somewhere in
  // the code, never inside the line-number prefix.
  TFindRefDisplay = record
    Text: string;
    PrefixLen, HiFrom, HiTo: Integer;
  end;

  // One colored/styled run of text, painted left to right by DrawRefRuns -
  // the one thing FindRefTreeDrawText needs for all three row shapes, each
  // of which just builds a different short run list.
  TPasRefRun = record
    Text: string;
    Color: TColor;
    Bold, Underline: Boolean;
  end;

  TFindRefTab = class(TTabSheet)
  public
    Tree: TVirtualStringTree;
    // The identity this tab searches for - how a repeated search finds and
    // refreshes this SAME tab instead of opening a duplicate (see
    // FindReferencesActionExecute). SymSym = -1 means SymMid is a UNIT
    // target (FNav.UnitAt), not a symbol; SymSym = -2 means this is a
    // BUILTIN-name search (FNav.BuiltinNameAt) and SymBuiltinName is what
    // actually gets compared, SymMid being meaningless there.
    SymMid, SymSym: Integer;
    SymBuiltinName: string;
    Hits: TArray<TPasRefHit>;
    Groups: TArray<TFindRefGroup>;
    Display: TArray<TFindRefDisplay>;
    HasDecl: Boolean;
    DeclHit: TPasRefHit;         // raw position, for double-click navigation
    DeclDisplay: TFindRefDisplay;
  end;

  TfrmMain = class(TForm)
    pnlTop: TPanel;
    btnOpen: TButton;
    btnParse: TButton;
    btnParseRtl: TButton;
    cbPlatform: TComboBox;
    cbConfig: TComboBox;       // build configuration (Debug/Release/...)
    cbHighlighter: TComboBox;
    cbThreading: TComboBox;    // background-analysis "phase done/total"
    { Incremental reanalysis (PasTree 0.9.0), ON by default. Checked, an edit
      first tries TPasAsyncSession.CreateForModule - re-parse and re-analyze
      just the edited unit in place, milliseconds instead of a closure
      rebuild - and any refusal falls back to an ordinary rebuild that adopts
      the current project as a PARSE DONOR. Unchecked, the demo behaves
      exactly as it did before: every edit rebuilds the closure from scratch.

      It also turns DemoteClosedUnits OFF, and that is the real trade this
      switch exposes: a demoted unit has no text layer, so it is a donor MISS
      and a fast-path refusal. Memory against edit latency, the dial the LSP
      host has to set too. }
    chkIncremental: TCheckBox;
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
    btnStop: TButton;
    lblProgress: TLabel;
    vtMessages: TVirtualStringTree;
    btnParseVcl: TButton;
    btnParseFmx: TButton;
    ViewUnitAction: TAction;
    btnViewUnit: TButton;
    FilesPopupMenu: TPopupMenu;
    ViewUnit1: TMenuItem;
    pgcBottom: TPageControl;
    tsMessages: TTabSheet;
    BottomTabsPopupMenu: TPopupMenu;
    CloseSearchTab1: TMenuItem;
    CloseAllSearchTabs1: TMenuItem;
    FindReferencesAction: TAction;
    FindReferences1: TMenuItem;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure btnOpenClick(Sender: TObject);
    procedure btnParseClick(Sender: TObject);
    procedure btnParseRtlClick(Sender: TObject);
    procedure btnShowASTJsonClick(Sender: TObject);
    procedure btnShowSemanticsClick(Sender: TObject);
    procedure btnShowCoverageClick(Sender: TObject);
    procedure btnStopClick(Sender: TObject);
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
    procedure FindReferencesActionUpdate(Sender: TObject);
    procedure FindReferencesActionExecute(Sender: TObject);
    procedure pgcBottomMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure CloseSearchTabClick(Sender: TObject);
    procedure CloseAllSearchTabsClick(Sender: TObject);
    procedure FindRefTreeGetText(Sender: TBaseVirtualTree;
      Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType;
      var CellText: string);
    procedure FindRefTreeDblClick(Sender: TObject);
    procedure FindRefTreeDrawText(Sender: TBaseVirtualTree;
      TargetCanvas: TCanvas; Node: PVirtualNode; Column: TColumnIndex;
      const Text: string; const CellRect: TRect; var DefaultDraw: Boolean);
  private
    FFileList: TStringList;  // full paths shown in the tree
    FOpenFiles: TStringList; // path -> TTabSheet (Objects)
    // Message window: FMsgLog is the full chronological history (status +
    // error rows, never filtered); FMsgVisible indexes the subset currently
    // shown in vtMessages (status rows always included, error rows gated by
    // chkShowErrors - see RebuildVisibleMessages/LogRow).
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
    // "Highlight other occurrences of the selected identifier" - the
    // background color, shared by every tab's own highlighter instance
    // (each set from cbHighlightColor; new tabs pick up the current value -
    // see OpenFileTab).
    FIdentHighlightColor: TColor;
    FReparseTimer: TTimer;         // debounces re-analysis after edits
    // Background (non-blocking) analysis. Opening a project and the edit-
    // debounce reanalysis run on FAsyncSession's worker thread; FAsyncTimer
    // polls its progress into lblProgress and, when it finishes, swaps the
    // built project/navigator in for the current ones (double-buffered - see
    // TPasAsyncSession). Run Parse stays synchronous and cancels this first.
    FAsyncSession: TPasAsyncSession;
    FAsyncTimer: TTimer;
    FAsyncLoud: Boolean;           // true = report diagnostics + populate views
    { The in-flight session is a SINGLE-MODULE reanalysis (CreateForModule):
      it owns FSemaProject rather than building a new one, so the swap in
      AsyncTimerTick takes the same project back instead of replacing it, and
      a refusal starts an ordinary rebuild. See chkIncremental. }
    FAsyncModule: Boolean;
    FAsyncModulePath: string;
    { Files edited since the last COMPLETED analysis. The fast path applies to
      exactly one changed unit; two dirty tabs go straight to a rebuild (the
      library offers no multi-module entry point, and looping the single-module
      one would need its own guard story). }
    FDirtyFiles: TStringList;
    // Did the LAST completed build demote its closed units? Then an opened tab
    // needs a re-analysis to get its text and transient maps back; otherwise
    // opening one is free. See OpenFileTab.
    FLastBuildDemoted: Boolean;
    // The main source the CURRENT FSemaProject was built from. A donor only
    // makes sense for the same project - switching projects changes the
    // search paths, so the gate would refuse it anyway; without this we would
    // log a refusal every time somebody opens a different project.
    FSemaProjectRoot: string;
    // An opened tab wanted a re-analysis while a build was already running.
    // Arming the debounce there would CANCEL that build and restart it quiet,
    // which is how opening a project used to lose its own report - so the
    // wish is remembered and re-checked after the build lands.
    FPendingTabReanalyze: Boolean;
    FAsyncStart: TStopwatch;       // wall-clock of the in-flight async build
    FLoadingFile: Boolean;         // suppresses OnChange during programmatic load
    // Guards every FNav/FSemaProject READ (ResolveAt, ActiveRoutineTarget)
    // against a real race: Analyze's own parallel passes (LoadFilesParallel/
    // CrossResolve/...) run via TParallel.&For, which - called from the MAIN
    // thread - pumps the message queue while waiting for worker threads, so
    // Application.OnIdle (and with it EVERY TAction.OnUpdate, incl. the new
    // GotoImpl/GotoDeclAction added today) can fire WHILE a background parse
    // is still writing into the very model these actions read - a proper
    // data race (TArray reallocation, half-written RefMap...), not just a
    // perf cost. This was always a latent gap (ResolveAt/ctrl+hover shared
    // it from day one) but went unnoticed since a mouse-move landing in that
    // exact window is rare; an idle-driven action re-checking many times a
    // second hits it constantly. Set for the FULL duration of Analyze.
    FAnalyzing: Boolean;
    // ExtraSearchPaths result cache: registry enumeration + validating ~140
    // candidate directories (TDirectory.Exists, one at a time - NOT the
    // parallel index SourceManager builds internally) is expensive on a
    // slow disk/AV-scanned machine, and Analyze() calls ExtraSearchPaths on
    // EVERY run - including the 500ms-debounced reanalysis after EVERY
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
    // model's file list - 3747 of them on the real project. One entry is all the
    // pattern needs, since a hover asks the same question repeatedly.
    FNameCacheKey, FNameCacheFile: string;
    FStudioRoot: string;           // RAD Studio root (for RTL search paths)
    // Persisted demo settings (recent projects + the sticky combos), in an .ini
    // beside the executable. See PasTreeDemo.Settings.
    FSettings: TDemoSettings;
    FRecentMenu: TPopupMenu;       // the Open Project split button's drop-down
    FFindBar: TForm;                // floating find toolbar (TFindBar); lazy
    // Code completion (ctrl+space / after `.`): the SynEdit popup plus the
    // cached overlay-preprocessor stack. Per request the CURRENT buffer is
    // parsed fresh (ProcessText + ParseFile + phase-1 Analyze - the overlay
    // model) and TPasCompletion bridges every name that leaves it into the
    // LAST-GOOD FSemaProject; see local/COMPLETION-PLAN.md sec. 3. The SM/PP pair
    // is cached because TPasSourceManager indexes ~140 search paths on
    // Create - a per-keystroke cost this field structure exists to avoid -
    // and invalidated whenever the analysis configuration changes.
    FCompl: TSynCompletionProposal;
    FComplSM: TPasSourceManager;
    FComplDefines: TPasDefines;
    FComplPP: TPasPreprocessor;
    FLastDefines: TArray<string>;  // defines the LAST analysis ran with
    procedure ApplyHighlighterContext(AHL: TPasTreeSynHighlighter;
      const APath: string);
    procedure CloseAllTabs;
    // Navigation history - see NavigateTo.
    function CurrentNavPos(out AEntry: TNavHistoryEntry): Boolean;
    procedure NavigateTo(const APath: string; ALine, ACol: Integer);
    procedure GoToNavEntry(const AEntry: TNavHistoryEntry);
    // Called from TNavHistoryPlugin - see there and ShiftNavHistory.
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
    // or (else) the declaration at that position - the SAME lookup Nav.pas
    // documents as safe to call from an Update handler (its per-model index
    // is built once and cached; repeating the call in Execute is cheap).
    function ActiveRoutineTarget(AWantImpl: Boolean;
      out ATarget: TPasNavTarget): Boolean;
    // Same shape, for Find References: the active tab's caret (or the
    // START of a selection - see the implementation) resolved to a symbol
    // identity (FNav.SymbolAt) rather than a navigation target. TSourceTab
    // itself is declared in the implementation section (below), so this
    // returns the two pieces callers actually need rather than the tab.
    function ActiveEditorPos(out AFilePath: string; out AEditor: TSynEdit;
      out ALine, ACol: Integer): Boolean;
    function ActiveSymbolTarget(out ATMid, ASym: Integer;
      out AName: string): Boolean;
    function ActiveUnitTarget(out ATargetMid: Integer;
      out AName: string): Boolean;
    // The third identity: a compiler-seeded builtin with no declaration
    // anywhere (FNav.BuiltinNameAt) -- a NAME, not a (unit, symbol) pair.
    function ActiveBuiltinTarget(out AName: string): Boolean;
    function FindExistingSearchTab(ATMid, ASym: Integer;
      const ABuiltinName: string = ''): TFindRefTab;
    function MakeFindRefDisplay(const AHit: TPasRefHit;
      const APrefix: string): TFindRefDisplay;
    procedure PopulateFindRefTab(LTab: TFindRefTab; const AName: string;
      const AHits: TArray<TPasRefHit>; AHasDecl: Boolean;
      const ADeclHit: TPasRefHit);
    function MakeRun(const AText: string; AColor: TColor;
      ABold, AUnderline: Boolean): TPasRefRun;
    procedure DrawRefRuns(ACanvas: TCanvas; const ACellRect: TRect;
      const ARuns: TArray<TPasRefRun>);
    procedure SetupControls;
    procedure InvalidateComplPipeline;
    function EnsureComplPP: Boolean;
    procedure ComplExecute(Kind: SynCompletionType; Sender: TObject;
      var CurrentInput: string; var x, y: Integer; var CanExecute: Boolean);
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
    { The fast path: hand FSemaProject to a single-module session for APath.
      False = not applicable (switch off, no project, path not in the analyzed
      closure, more than one dirty tab, a build already running) and the
      caller must do an ordinary rebuild. True only means the session STARTED
      - the guards may still refuse, which AsyncTimerTick handles. }
    function TryModuleReanalyze(const APath: string): Boolean;
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
    plugins - so this rides on machinery that is already correct and already
    called from the one place that knows (TCustomSynEdit.DoLinesInserted /
    DoLinesDeleted, driven by the string list's own notifications).

    A plugin rather than a TSynEditMark per entry: our history is a flat list
    of records with no per-entry object to hang a mark on, entries are dropped
    wholesale when a jump truncates the forward tail, and a mark exists to be
    DRAWN in the gutter. This wants the notification, not the object.

    The rules are copied from TSynIndicators, not from the mark shifting: the
    two disagree, and the indicator one is right. SynEdit's own comment states
    the convention - FirstLine is 0-based, a Line is 1-based - and indicators
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
  // reads frmMain.pgc.ActivePage FRESH (see TfrmMain.DoFindNext) - moving
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
    // when the box is still empty - repeated Ctrl+F keeps your last search.
    procedure PopUp(const AInitialText: string);
  end;

const
  // Pastel-ish background swatches (readable under normal black text) for
  // the "same identifier" highlight combo (cbHighlightColor) - SandyBrown
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
// "same identifier" highlight - a multi-word or punctuation selection never
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
  // Enabled whenever a source tab is the ACTIVE one - not gated on which
  // control currently holds keyboard focus: a TTabSheet is a container, its
  // own Focused is essentially always False (the child SynEdit holds real
  // focus), so requiring it here would permanently disable this action.
  TAction(Sender).Enabled := Assigned(pgc.ActivePage) and
    (pgc.ActivePage is TSourceTab);
end;

// Finds AText forward from the caret in the CURRENTLY ACTIVE source tab,
// wrapping to the top of the document if not found before EOF. Case-
// insensitive (SynEdit's default when ssoMatchCase is omitted) - a quick-
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

// Go to implementation (Ctrl+Shift+Down): always the SAME unit/tab - Object
// Pascal never lets a routine's body live in a different unit from its
// declaration - so this only ever moves the caret in place, unlike ctrl+
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

// Go to declaration (Ctrl+Shift+Up) - the reverse direction.
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

// The active source tab plus the position Find References/SymbolAt should
// query: a SELECTED identifier's own START (double-click, shift+arrow,
// drag) - the caret itself sits at whichever END the selection was made
// TOWARD, often one character past the identifier's last letter, which
// IdentAt (an exact-token hit test) refuses - or, with no selection, the
// plain caret. Returns False (leaving LTab/ALine/ACol untouched) when
// there's nothing to query at all, so both ActiveSymbolTarget and
// ActiveUnitTarget share one Exit path for that.
function TfrmMain.ActiveEditorPos(out AFilePath: string; out AEditor: TSynEdit;
  out ALine, ACol: Integer): Boolean;
var
  LTab: TSourceTab;
begin
  Result := not FAnalyzing and Assigned(FNav) and Assigned(pgc.ActivePage) and
    (pgc.ActivePage is TSourceTab);
  if not Result then
    Exit;
  LTab := TSourceTab(pgc.ActivePage);
  AFilePath := LTab.FilePath;
  AEditor := LTab.Editor;
  if AEditor.SelAvail then
  begin
    ALine := AEditor.BlockBegin.Line;
    ACol := AEditor.BlockBegin.Char;
  end
  else
  begin
    ALine := AEditor.CaretY;
    ACol := AEditor.CaretX;
  end;
end;

function TfrmMain.ActiveSymbolTarget(out ATMid, ASym: Integer;
  out AName: string): Boolean;
var
  LFilePath: string;
  LEditor: TSynEdit;
  LMid, LLine, LCol: Integer;
begin
  Result := False;
  if not ActiveEditorPos(LFilePath, LEditor, LLine, LCol) then
    Exit;
  LMid := FNav.ModelIdOf(LFilePath);
  if LMid < 0 then
    Exit;
  Result := FNav.SymbolAt(LMid, LLine, LCol, ATMid, ASym, AName);
end;

// The unit counterpart: a click on THIS file's own header name, or on a
// `uses` clause item - see FNav.UnitAt for what counts as which.
function TfrmMain.ActiveUnitTarget(out ATargetMid: Integer;
  out AName: string): Boolean;
var
  LFilePath: string;
  LEditor: TSynEdit;
  LMid, LLine, LCol: Integer;
begin
  Result := False;
  if not ActiveEditorPos(LFilePath, LEditor, LLine, LCol) then
    Exit;
  LMid := FNav.ModelIdOf(LFilePath);
  if LMid < 0 then
    Exit;
  Result := FNav.UnitAt(LMid, LLine, LCol, ATargetMid, AName);
end;

function TfrmMain.ActiveBuiltinTarget(out AName: string): Boolean;
var
  LFilePath: string;
  LEditor: TSynEdit;
  LMid, LLine, LCol: Integer;
begin
  Result := False;
  if not ActiveEditorPos(LFilePath, LEditor, LLine, LCol) then
    Exit;
  LMid := FNav.ModelIdOf(LFilePath);
  if LMid < 0 then
    Exit;
  Result := FNav.BuiltinNameAt(LMid, LLine, LCol, AName);
end;

procedure TfrmMain.FindReferencesActionUpdate(Sender: TObject);
var
  LTMid, LSym: Integer;
  LName: string;
begin
  TAction(Sender).Enabled := ActiveSymbolTarget(LTMid, LSym, LName) or
    ActiveUnitTarget(LTMid, LName) or ActiveBuiltinTarget(LName);
end;

// A repeated search for the SAME identity (not just the same spelling - two
// unrelated locals named the same must not collide) reuses and refreshes
// its own tab rather than stacking a duplicate; ModelByName-style search is
// small (one page per open search) so a linear scan is fine. ABuiltinName
// non-empty means "match by name, ASym/ATMid don't matter" - see
// TFindRefTab's own comment on the SymSym = -1 / -2 sentinels.
function TfrmMain.FindExistingSearchTab(ATMid, ASym: Integer;
  const ABuiltinName: string): TFindRefTab;
var
  LIdx: Integer;
  LTab: TFindRefTab;
begin
  Result := nil;
  for LIdx := 0 to pgcBottom.PageCount - 1 do
  begin
    if not (pgcBottom.Pages[LIdx] is TFindRefTab) then
      Continue;
    LTab := TFindRefTab(pgcBottom.Pages[LIdx]);
    if ABuiltinName <> '' then
    begin
      if (LTab.SymSym = -2) and SameText(LTab.SymBuiltinName, ABuiltinName)
      then
        Exit(LTab);
    end
    else if (LTab.SymMid = ATMid) and (LTab.SymSym = ASym) then
      Exit(LTab);
  end;
end;

procedure TfrmMain.FindReferencesActionExecute(Sender: TObject);
var
  LTMid, LSym: Integer;
  LName, LBuiltinName: string;
  LTab: TFindRefTab;
  LDeclHit: TPasRefHit;
  LHasDecl: Boolean;
  LHits: TArray<TPasRefHit>;
begin
  LBuiltinName := '';
  if ActiveSymbolTarget(LTMid, LSym, LName) then
  begin
    LHasDecl := FNav.DeclHit(LTMid, LSym, {out} LDeclHit);
    LHits := FNav.FindReferences(LTMid, LSym);
  end
  else if ActiveUnitTarget(LTMid, LName) then
  begin
    // -1: never a real symbol index, so (LTMid, -1) can't collide with an
    // ordinary search's own key - the sentinel FindExistingSearchTab needs
    // to tell "searching for the unit itself" apart from any real symbol.
    LSym := -1;
    LHasDecl := FNav.UnitDeclHit(LTMid, {out} LDeclHit);
    LHits := FNav.FindUnitReferences(LTMid);
  end
  else if ActiveBuiltinTarget(LName) then
  begin
    // No (unit, symbol) or even a single target model exists for a builtin
    // -- LTMid/LSym are meaningless placeholders here, matching is by name.
    LTMid := -1;
    LSym := -2;
    LBuiltinName := LName;
    LHasDecl := False;   // a builtin has no declaration site anywhere
    LHits := FNav.FindBuiltinReferences(LName);
  end
  else
    Exit;
  LTab := FindExistingSearchTab(LTMid, LSym, LBuiltinName);
  if not Assigned(LTab) then
  begin
    LTab := TFindRefTab.Create(pgcBottom);
    LTab.PageControl := pgcBottom;
    LTab.SymMid := LTMid;
    LTab.SymSym := LSym;
    LTab.SymBuiltinName := LBuiltinName;
  end;
  PopulateFindRefTab(LTab, LName, LHits, LHasDecl, LDeclHit);
  pgcBottom.ActivePage := LTab;
end;

// "Line N: " for a hit row, "<file> (Line N): " for the standalone
// declaration row - the one place both prefix shapes are built, so
// PopulateFindRefTab and nothing else needs to know their exact wording.
function TfrmMain.MakeFindRefDisplay(const AHit: TPasRefHit;
  const APrefix: string): TFindRefDisplay;
var
  LTrimmed: string;
  LShift: Integer;
begin
  LTrimmed := TrimLeft(AHit.Snippet);
  LShift := Length(AHit.Snippet) - Length(LTrimmed);
  Result.Text := APrefix + LTrimmed;
  Result.PrefixLen := Length(APrefix);
  Result.HiFrom := Result.PrefixLen + Max(0, AHit.HiFrom - LShift);
  Result.HiTo := Result.PrefixLen + Max(0, AHit.HiTo - LShift);
end;

// (Re)builds an existing or brand-new tab's whole tree from scratch - one
// path for both "new search" and "repeated search reusing its own tab",
// since a refresh IS a rebuild (the analysis may have changed underneath).
procedure TfrmMain.PopulateFindRefTab(LTab: TFindRefTab; const AName: string;
  const AHits: TArray<TPasRefHit>; AHasDecl: Boolean;
  const ADeclHit: TPasRefHit);
var
  LGroup: TFindRefGroup;
  LIdx, LStart: Integer;
  LDeclNode, LGroupNode, LHitNode: PVirtualNode;
begin
  LTab.Caption := Format('Search for ''%s'' (%d)', [AName, Length(AHits)]);
  LTab.Hits := AHits;
  LTab.HasDecl := AHasDecl;
  LTab.DeclHit := ADeclHit;
  if AHasDecl then
    LTab.DeclDisplay := MakeFindRefDisplay(ADeclHit,
      Format('%s (Line %d): ', [TPath.GetFileName(ADeclHit.FilePath),
        ADeclHit.Line]));

  SetLength(LTab.Display, Length(AHits));
  for LIdx := 0 to High(AHits) do
    LTab.Display[LIdx] :=
      MakeFindRefDisplay(AHits[LIdx], Format('Line %d: ', [AHits[LIdx].Line]));

  LTab.Groups := nil;
  LIdx := 0;
  while LIdx < Length(AHits) do
  begin
    LStart := LIdx;
    while (LIdx < Length(AHits)) and
          SameText(AHits[LIdx].FilePath, AHits[LStart].FilePath) do
      Inc(LIdx);
    LGroup.FilePath := AHits[LStart].FilePath;
    LGroup.FirstHit := LStart;
    LGroup.Count := LIdx - LStart;
    LTab.Groups := LTab.Groups + [LGroup];
  end;

  if not Assigned(LTab.Tree) then
  begin
    LTab.Tree := TVirtualStringTree.Create(LTab);
    LTab.Tree.Parent := LTab;
    LTab.Tree.Align := alClient;
    LTab.Tree.NodeDataSize := SizeOf(TPasRefNodeData);
    LTab.Tree.DefaultNodeHeight := 19;
    LTab.Tree.Header.AutoSizeIndex := 0;
    LTab.Tree.Header.Height := 15;
    LTab.Tree.Header.MainColumn := -1;
    LTab.Tree.TreeOptions.SelectionOptions :=
      [toRightClickSelect, toSelectNextNodeOnRemoval];
    LTab.Tree.OnGetText := FindRefTreeGetText;
    LTab.Tree.OnDblClick := FindRefTreeDblClick;
    LTab.Tree.OnDrawText := FindRefTreeDrawText;
  end;

  LTab.Tree.BeginUpdate;
  try
    LTab.Tree.Clear;
    if AHasDecl then
    begin
      LDeclNode := LTab.Tree.AddChild(nil);
      PPasRefNodeData(LTab.Tree.GetNodeData(LDeclNode)).Kind := rnDecl;
      PPasRefNodeData(LTab.Tree.GetNodeData(LDeclNode)).Index := 0;
    end;
    for LIdx := 0 to High(LTab.Groups) do
    begin
      LGroupNode := LTab.Tree.AddChild(nil);
      PPasRefNodeData(LTab.Tree.GetNodeData(LGroupNode)).Kind := rnGroup;
      PPasRefNodeData(LTab.Tree.GetNodeData(LGroupNode)).Index := LIdx;
      for LStart := LTab.Groups[LIdx].FirstHit to
        LTab.Groups[LIdx].FirstHit + LTab.Groups[LIdx].Count - 1 do
      begin
        LHitNode := LTab.Tree.AddChild(LGroupNode);
        PPasRefNodeData(LTab.Tree.GetNodeData(LHitNode)).Kind := rnHit;
        PPasRefNodeData(LTab.Tree.GetNodeData(LHitNode)).Index := LStart;
      end;
      LTab.Tree.Expanded[LGroupNode] := True;
    end;
  finally
    LTab.Tree.EndUpdate;
  end;
end;

procedure TfrmMain.FindRefTreeGetText(Sender: TBaseVirtualTree;
  Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType;
  var CellText: string);
var
  LTab: TFindRefTab;
  LData: PPasRefNodeData;
begin
  LTab := TFindRefTab(TVirtualStringTree(Sender).Owner);
  LData := PPasRefNodeData(Sender.GetNodeData(Node));
  if LData = nil then
  begin
    CellText := '';
    Exit;
  end;
  case LData.Kind of
    rnDecl:
      CellText := LTab.DeclDisplay.Text;
    rnGroup:
      CellText := Format('%s [%d]', [TPath.GetFileName(
        LTab.Groups[LData.Index].FilePath), LTab.Groups[LData.Index].Count]);
  else
    CellText := LTab.Display[LData.Index].Text;
  end;
end;

procedure TfrmMain.FindRefTreeDblClick(Sender: TObject);
var
  LTree: TVirtualStringTree;
  LTab: TFindRefTab;
  LData: PPasRefNodeData;
  LHit: TPasRefHit;
begin
  LTree := TVirtualStringTree(Sender);
  if LTree.FocusedNode = nil then
    Exit;
  LTab := TFindRefTab(LTree.Owner);
  LData := PPasRefNodeData(LTree.GetNodeData(LTree.FocusedNode));
  if LData = nil then
    Exit;
  case LData.Kind of
    rnDecl:
      begin
        if not LTab.HasDecl then
          Exit;
        LHit := LTab.DeclHit;
      end;
    rnHit:
      begin
        if (LData.Index < 0) or (LData.Index > High(LTab.Hits)) then
          Exit;
        LHit := LTab.Hits[LData.Index];
      end;
  else
    Exit;   // rnGroup: nothing to navigate to
  end;
  NavigateTo(LHit.FilePath, LHit.Line, LHit.Col);
end;

// Bolds/colors the matched identifier, Delphi Search-Results style: a
// GROUP row's file name in navy bold, its [count] in amber; a HIT or DECL
// row's "Line N: "/"<file> (Line N): " prefix in gray, the code plain, and
// the matched identifier itself in red, bold and underlined. Group rows
// need no highlight span at all (the whole thing is two colored runs);
// hit/decl rows share PrefixLen/HiFrom/HiTo, already shifted to agree with
// the exact Text VST resolved (see TFindRefDisplay/MakeFindRefDisplay).
procedure TfrmMain.FindRefTreeDrawText(Sender: TBaseVirtualTree;
  TargetCanvas: TCanvas; Node: PVirtualNode; Column: TColumnIndex;
  const Text: string; const CellRect: TRect; var DefaultDraw: Boolean);
const
  CLR_FILE = clNavy;
  CLR_COUNT = TColor($0000A5FF);   // amber/orange (RGB $FF,$A5,$00), BGR-packed
  CLR_PREFIX = TColor($00808080);  // muted gray
  CLR_MATCH = clMaroon;
var
  LTab: TFindRefTab;
  LData: PPasRefNodeData;
  LDisp: TFindRefDisplay;
  LRuns: TArray<TPasRefRun>;
  LGroupNameLen: Integer;
begin
  LData := PPasRefNodeData(Sender.GetNodeData(Node));
  if LData = nil then
    Exit;
  LTab := TFindRefTab(TVirtualStringTree(Sender).Owner);
  case LData.Kind of
    rnGroup:
      begin
        if (LData.Index < 0) or (LData.Index > High(LTab.Groups)) then
          Exit;
        LGroupNameLen :=
          Length(TPath.GetFileName(LTab.Groups[LData.Index].FilePath));
        if LGroupNameLen >= Length(Text) then
          Exit;   // malformed -- keep VST's own draw rather than guess
        LRuns := [
          MakeRun(Copy(Text, 1, LGroupNameLen), CLR_FILE, True, False),
          MakeRun(Copy(Text, LGroupNameLen + 1, MaxInt), CLR_COUNT, True,
            False)];
      end;
    rnDecl, rnHit:
      begin
        if LData.Kind = rnDecl then
        begin
          if not LTab.HasDecl then
            Exit;
          LDisp := LTab.DeclDisplay;
        end
        else
        begin
          if (LData.Index < 0) or (LData.Index > High(LTab.Display)) then
            Exit;
          LDisp := LTab.Display[LData.Index];
        end;
        if (LDisp.PrefixLen < 0) or (LDisp.HiTo > Length(Text)) or
           (LDisp.HiFrom < LDisp.PrefixLen) or (LDisp.HiFrom >= LDisp.HiTo)
        then
          Exit;   // out of range for the CURRENT text -- keep default draw
        LRuns := [
          MakeRun(Copy(Text, 1, LDisp.PrefixLen), CLR_PREFIX, False, False),
          MakeRun(Copy(Text, LDisp.PrefixLen + 1, LDisp.HiFrom -
            LDisp.PrefixLen), clWindowText, False, False),
          MakeRun(Copy(Text, LDisp.HiFrom + 1, LDisp.HiTo - LDisp.HiFrom),
            CLR_MATCH, True, True),
          MakeRun(Copy(Text, LDisp.HiTo + 1, MaxInt), clWindowText, False,
            False)];
      end;
  else
    Exit;
  end;
  DefaultDraw := False;
  DrawRefRuns(TargetCanvas, CellRect, LRuns);
end;

function TfrmMain.MakeRun(const AText: string; AColor: TColor;
  ABold, AUnderline: Boolean): TPasRefRun;
begin
  Result.Text := AText;
  Result.Color := AColor;
  Result.Bold := ABold;
  Result.Underline := AUnderline;
end;

// Paints ARuns left to right starting at CellRect's own text origin
// (cDefaultTextMargin in from the left, vertically centered) -- the one
// place that actually touches the canvas, so every row shape above just
// describes WHAT to draw, never HOW.
procedure TfrmMain.DrawRefRuns(ACanvas: TCanvas; const ACellRect: TRect;
  const ARuns: TArray<TPasRefRun>);
var
  LIdx, LX, LY: Integer;
  LStyle: TFontStyles;
begin
  // TextMargin itself is `protected` on TBaseVirtualTree (visible only
  // inside VST's own unit) -- cDefaultTextMargin is what it defaults to and
  // nothing here ever changes it, so it stays the right offset.
  LX := ACellRect.Left + cDefaultTextMargin;
  LY := (ACellRect.Top + ACellRect.Bottom - ACanvas.TextHeight('Hg')) div 2;
  ACanvas.Brush.Style := bsClear;
  for LIdx := 0 to High(ARuns) do
  begin
    LStyle := [];
    if ARuns[LIdx].Bold then
      Include(LStyle, fsBold);
    if ARuns[LIdx].Underline then
      Include(LStyle, fsUnderline);
    ACanvas.Font.Style := LStyle;
    ACanvas.Font.Color := ARuns[LIdx].Color;
    ACanvas.TextOut(LX, LY, ARuns[LIdx].Text);
    Inc(LX, ACanvas.TextWidth(ARuns[LIdx].Text));
  end;
end;

procedure TfrmMain.pgcBottomMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  LIdx: Integer;
begin
  if Button <> mbRight then
    Exit;
  LIdx := pgcBottom.IndexOfTabAt(X, Y);
  if LIdx >= 0 then
    pgcBottom.ActivePage := pgcBottom.Pages[LIdx];
end;

// Both handlers no-op on tsMessages: it is never a TFindRefTab, so a right-
// click that lands on it (or on empty tab-strip space, which leaves
// ActivePage wherever it already was) closes nothing.
procedure TfrmMain.CloseSearchTabClick(Sender: TObject);
begin
  if pgcBottom.ActivePage is TFindRefTab then
    pgcBottom.ActivePage.Free;
end;

procedure TfrmMain.CloseAllSearchTabsClick(Sender: TObject);
var
  LIdx: Integer;
begin
  for LIdx := pgcBottom.PageCount - 1 downto 0 do
    if pgcBottom.Pages[LIdx] is TFindRefTab then
      pgcBottom.Pages[LIdx].Free;
end;

{ The word under the caret, taken as a FILE or UNIT name: the maximal run of
  characters either can contain. Deliberately wider than an identifier -
  a unit name is dotted (`Vcl.Forms`), an include is `common.inc`, and a path in a
  string has separators - and deliberately stops at quotes, braces and
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
  unit AND of every included file in the closure - which is how an $I argument
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
  // live - see TPasSemaProject.NodeSite on why an $I file is a different path).
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

// Only enabled while vtMessages itself has focus - Ctrl+C must not steal
// "copy" away from a focused SynEdit tab (which handles it natively as a
// text-edit shortcut) just because a message row happens to still be
// focused from an earlier click.
procedure TfrmMain.CopyMessageActionUpdate(Sender: TObject);
begin
  TAction(Sender).Enabled := vtMessages.Focused and
    Assigned(vtMessages.FocusedNode);
end;

// The WHOLE visible history, in one go - for pasting a run's log somewhere
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

{ The most-imported missing units, busiest first - the shortest description of
  a broken search-path setup there is. Sorted by import count because that is
  the order in which fixing them buys back closure.

  Each row carries the FIRST import site and is double-clickable, which is the
  whole point: the name says WHAT is missing, and the jump says who asked for
  it. Without it a single-site entry like `System.Internal.HelperHlpr` is a
  dead end - the F1027 rows only cover PROJECT files, and the unit that
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
        // payload - the line has to be readable when it is COPIED out of the
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

// Seconds with one decimal - a five-digit millisecond count is not something
// anyone reads comfortably.
function TfrmMain.ElapsedText(AMs: Int64): string;
begin
  Result := Format('%.1f s', [AMs / 1000]);
end;

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  // Which PasTree this demo is built against - the caption is the one place
  // visible on every screenshot and in every bug report.
  Caption := 'PasTree Demo v' + PasTreeVersion;
  FFileList := TStringList.Create;
  FOpenFiles := TStringList.Create;
  FDirtyFiles := TStringList.Create;   // edits since the last analysis
  FMsgLog := TList<TPasMsgRow>.Create;
  FMsgVisible := TList<Integer>.Create;
  FNavHistory := TNavHistory.Create;
  // The mouse's back/forward buttons never reach a control's OnMouseDown -
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
  // After SetupControls, which fills the combos and picks their defaults -
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
  InvalidateComplPipeline;
  FreeAndNil(FNav);
  FreeAndNil(FSemaProject);
  FreeAndNil(FDProj);
  Application.OnMessage := nil;   // before the form it dispatches to goes
  FNavHistory.Free;
  FMsgVisible.Free;
  FMsgLog.Free;
  FOpenFiles.Free;
  FDirtyFiles.Free;
  FFileList.Free;
end;

// Runtime-only control configuration (things awkward to set in the designer:
// the VST node payload/options, highlighters and code fonts).
procedure TfrmMain.SetupControls;
begin
  // Numeric ShortCut values are a pain to get right by hand in the .dfm -
  // Menus.ShortCut computes the correct encoding from the actual keys.
  GotoImplAction.ShortCut := Vcl.Menus.ShortCut(VK_DOWN, [ssCtrl, ssShift]);
  GotoDeclAction.ShortCut := Vcl.Menus.ShortCut(VK_UP, [ssCtrl, ssShift]);
  CopyMessageAction.ShortCut := Vcl.Menus.ShortCut(Ord('C'), [ssCtrl]);
  // Delphi's own key for it, and worth matching exactly: it is the command
  // people reach for when ctrl+click cannot help - an include file, or a unit
  // whose source the analysis never loaded.
  OpenFileAtCursorAction.ShortCut := Vcl.Menus.ShortCut(VK_RETURN, [ssCtrl]);
  // The conventional pair, matching every browser and IDE.
  NavBackAction.ShortCut := Vcl.Menus.ShortCut(VK_LEFT, [ssAlt]);
  NavForwardAction.ShortCut := Vcl.Menus.ShortCut(VK_RIGHT, [ssAlt]);

  // Code completion popup, shared by every source tab (OpenFileTab calls
  // AddEditor per editor): ctrl+space on demand, and the built-in timer
  // fires it right after a typed `.`, matching the IDE. The work happens in
  // ComplExecute - overlay parse of the current buffer + the bridged
  // collection engine (PasTree.Sema.Complete).
  FCompl := TSynCompletionProposal.Create(Self);
  FCompl.Options := DefaultProposalOptions +
    [scoUseBuiltInTimer, scoUseInsertList, scoUsePrettyText];
  FCompl.TriggerChars := '.';
  FCompl.TimerInterval := 350;
  FCompl.ShortCut := Vcl.Menus.ShortCut(VK_SPACE, [ssCtrl]);
  FCompl.Columns.Add.ColumnWidth := 90;   // the kind word, dimmed
  FCompl.Resizeable := True;              // drag the popup's edge to grow it
  FCompl.OnExecute := ComplExecute;

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
  // btnShowSemanticsClick) and hidden until asked for - TabVisible keeps the
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

  // Shared across every tab when "SynEdit" is selected - TSynPasSyn is a
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
// type names) - those are folded into the nearest matching PasTree color so
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
  // Ours never singles out built-in type names - match IdentifierAttri so
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
// adds a real VST node for it - mirrors PopulateTree's own AddChild+
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

// A diagnostic row - the future hint/warning entry points will call LogRow
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

// Re-applies the chkShowErrors filter to the ENTIRE history - needed because
// toggling the checkbox must retroactively show/hide every already-logged
// error row, not just future ones: the request was explicitly that ticking the
// box AFTER the analysis has finished still reveals the errors it already
// logged.
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
// analyzed yet - shared by btnShowASTJsonClick/btnShowSemanticsClick (AST
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
// the caret exactly there. Gated on the position, not on Kind - the
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
  // opening its .dproj (same search paths/defines/full file list) - a real
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
    // set only when cbConfig re-opens the SAME project - see cbConfigChange.
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

  Caption := Format('PasTree Demo v%s - %s',
    [PasTreeVersion, TPath.GetFileName(LFile)]);
  // Remembered here, at the one point every route into a project passes
  // through, and with LFile - the .dproj the .dpr was redirected to, not the
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
  // because a bare .dpr has no summary line and still has a configuration -
  // it is what decides whether DEBUG is defined.
  Log('Analyzing ' + TPath.GetFileName(FMainSource) + ' in ' + FProjectDir +
    ' (' + cbPlatform.Text + ', ' + SelectedConfig +
    ') in the background...');
  // The TOTAL search-path set, not just the .dproj's own: the rest comes from
  // the IDE's registry library/browsing paths (ExtraSearchPaths), and that set
  // is what decides how much of the `uses` graph resolves - so how many units
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
      Log(Format('  unit scope names: %d from .dproj - %s',
        [Length(FDProj.Namespaces), string.Join(';', FDProj.Namespaces)]))
    else
      Log(Format('  unit scope names: %d IDE defaults (no .dproj list) - %s',
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
    // not a directory scan - this also correctly reaches units that live
    // outside FProjectDir (e.g. '..\source\*.pas' referenced by the .dproj).
    for LFile in FDProj.Files do
      if TFile.Exists(LFile) then
        FFileList.Add(LFile);
  end
  else if (FMainSource <> '') and TFile.Exists(FMainSource) then
    // No .dproj for this project (OpenProject already redirects to a sibling
    // .dproj when one exists - see there). Start with just the main file:
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
  hundreds - the count and the list disagreeing for a real reason, but looking
  exactly like a lie.

  The main source's uses/contains entries carrying an `in 'path'` clause ARE
  the project's own unit list. That is Delphi's own convention - the IDE
  writes `in` for a project member and a bare name for a library unit - and it
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

  // Our own PasTree-lexer-driven highlighter - one instance per tab (it
  // caches the tokenization of its own attached buffer, so instances can't
  // be shared across editors). Kept alive even when SynEdit's highlighter is
  // the active one, so cbHighlighterChange can switch back without recreating it.
  LHL := TPasTreeSynHighlighter.Create(Result);
  LHL.SourceLines := Result.Lines;
  // Give it the same context the ANALYSIS runs under. Without it the
  // highlighter preprocesses the buffer under a placeholder name and no search
  // paths, so every `{$I ...}` fails - and an include that DEFINES symbols then
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
      // The ANALYSIS's own loader, not TStrings.LoadFromFile - for the same
      // reason ApplyHighlighterContext exists a few lines up: two loaders are
      // two sources of truth, and they disagree exactly on the files that are
      // hardest to read. LoadFromFile RAISES on a malformed byte ("No mapping
      // for the Unicode character exists in the target multi-byte code page"),
      // so this tab used to show that message instead of the unit - on the one
      // file where reading the source mattered most. Now the editor shows the
      // recovered text character-for-character as the analyzer sees it, which
      // also keeps every reported line/column pointing at the right place.
      Result.Text := TPasSourceManager.LoadFileTolerant(APath);
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
  FCompl.AddEditor(Result);   // code completion (ctrl+space / after `.`)
  // Keeps recorded positions in THIS file pointing at the same text as it is
  // edited. Created after FilePath is known and after the initial load, and
  // owned by the editor - see TNavHistoryPlugin.
  TNavHistoryPlugin.Create(Result, Self, LTab.FilePath);
  FOpenFiles.AddObject(APath, LTab);
  pgc.ActivePage := LTab;
  // A re-analysis here is needed ONLY when this tab's unit cannot answer in
  // full already: the file is outside the analyzed closure, or the last build
  // demoted it (DemoteClosedUnits frees the text layer and the transient maps
  // completion reads, for everything that was not an open tab back then).
  //
  // With incremental analysis on we do not demote at all, so merely LOOKING at
  // a unit that is already in the closure must cost nothing - it used to
  // rebuild the whole closure per opened tab, which is exactly the progress
  // bar you would see while just clicking through the file list.
  if Assigned(FSemaProject) and
     (FLastBuildDemoted or (FSemaProject.ModelIdOf(LTab.FilePath) < 0)) then
  begin
    // ...and never ON TOP of a running build: arming the debounce cancels it
    // and restarts it QUIET, which is how opening a project used to lose its
    // own "Done:" report (and log a second donor refusal). The build in
    // flight most likely covers this tab anyway; if it does not, the check
    // runs again when it lands.
    if Assigned(FAsyncSession) then
      FPendingTabReanalyze := True
    else
    begin
      FReparseTimer.Enabled := False;
      FReparseTimer.Enabled := True;
    end;
  end;
end;

{ go-to-declaration }

// The (raw token, declaration target) under pixel (X, Y) of an editor -
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
  navigation target - the include half of ctrl+click.

  It cannot go through TPasNav at all: a directive is TRIVIA, it has no
  identifier and no AST node, so nothing the resolver produced knows about it.
  What it does have is a single raw token covering the whole directive, which is
  exactly the link range to underline, and a file name that FileForName already
  knows how to resolve. So this is a line-level scan plus that lookup, and it
  works in a file the analysis never reached.

  Deliberately NOT the reverse direction: an identifier typed inside an opened
  .inc still resolves to nothing, for the model-keyed reason in the README's
  To-do. This is the direction that matters - getting INTO the include from the
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
  // Selection), clobbering our jump - which is why it previously only "worked"
  // on a double-click, where SynEdit bails early on ssDouble. Defer the jump so
  // it runs after SynEdit's caret move, and a single ctrl+click lands correctly.
  TThread.ForceQueue(nil,
    procedure
    begin
      // NavigateTo opens the tab when the target is in another unit and finds
      // the existing one when it is not, so the same-file case needs no
      // special path here - but the ORIGIN it records must be this editor's
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

// Platform + search paths + defines for the current project - shared by the
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
procedure TfrmMain.InvalidateComplPipeline;
begin
  FreeAndNil(FComplPP);
  FreeAndNil(FComplDefines);
  FreeAndNil(FComplSM);
end;

// The completion overlay's preprocessor stack, cached until the analysis
// configuration changes (see the field comment): TPasSourceManager indexes
// every search path on Create, which must not happen per keystroke.
function TfrmMain.EnsureComplPP: Boolean;
var
  LName: string;
begin
  if FComplPP = nil then
  begin
    if Length(FLastSearchPaths) = 0 then
      Exit(False);
    FComplSM := TPasSourceManager.Create(FLastSearchPaths);
    // The REAL platform define set, then the project's on top - the same
    // context the analysis (and the highlighter) run under; a thinner set
    // fakes parse errors in the RTL (see CreatePlatformDefines).
    FComplDefines := CreatePlatformDefines(FPlatform);
    for LName in FLastDefines do
      FComplDefines.Define(LName);
    FComplPP := TPasPreprocessor.Create(FComplSM, FComplDefines);
  end;
  Result := True;
end;

// The dimmed kind word of one completion row.
function ComplKindWord(const AItem: TPasComplItem): string;
begin
  if AItem.Bucket = cbKeyword then
    Exit('keyword');
  if AItem.Bucket = cbUnitName then
    Exit('unit');
  case AItem.Kind of
    skType, skBuiltinType, skGenericParam:
      Result := 'type';
    skVar:
      Result := 'var';
    skConst:
      Result := 'const';
    skField:
      Result := 'field';
    skRoutine:
      Result := 'routine';
    skParam:
      Result := 'param';
    skProperty:
      Result := 'property';
    skEnumValue:
      Result := 'value';
    skUnitRef:
      Result := 'unit';
  else
    Result := '';
  end;
end;

// Code completion: the whole per-request pipeline, on the UI thread - an
// overlay parse of the CURRENT buffer (~30 ms worst case, measured on
// System.pas), phase-1 resolve, then the collection engine bridging every
// name that leaves the buffer into the last-good FSemaProject.
procedure TfrmMain.ComplExecute(Kind: SynCompletionType; Sender: TObject;
  var CurrentInput: string; var x, y: Integer; var CanExecute: Boolean);
var
  LTab: TSourceTab;
  LPre: TPasPreprocessed;
  LDiags: TArray<TPasParseDiag>;
  LTree: TPasTree;
  LModel: TPasSemaModel;
  LEngine: TPasCompletion;
  LCtx: TPasComplContext;
  LItems: TArray<TPasComplItem>;
  LMid, LIdx, LKeep: Integer;
  LName, LDetail, LKindWord: string;
  LX: TSemaXType;
  LWithTypes: Boolean;
  LCaret: TPasCaretInfo;
begin
  CanExecute := False;
  if FAnalyzing or not Assigned(FSemaProject) or not Assigned(FNav) or
     not (pgc.ActivePage is TSourceTab) or not EnsureComplPP then
    Exit;
  // The barrier: this runs from SynEdit's timer/shortcut dispatch, and an
  // exception here (a mid-typed `{$I}` failing I/O, an engine defect) would
  // otherwise pop a modal error dialog and REARM every 350 ms while the
  // caret sits after the dot. No completion beats a dialog loop.
  try
  LTab := TSourceTab(pgc.ActivePage);
  LPre := FComplPP.ProcessText(LTab.FilePath, LTab.Editor.Text);
  LTree := TPasParser.ParseFile(LPre, LDiags);
  LModel := TPasSemaResolver.Analyze(LTree, False, FPlatform);
  LEngine := nil;
  try
    LMid := FNav.ModelIdOf(LTab.FilePath);
    LEngine := TPasCompletion.Create(LModel, FSemaProject, LMid);
    if not LEngine.CompleteAt(LTab.Editor.CaretY, LTab.Editor.CaretX,
         LCaret, LCtx, LItems) or (Length(LItems) = 0) then
      Exit;
    // Pre-filter by the typed prefix (the engine's replace span, not a
    // re-tokenization): sorting and formatting 20k rows so the popup can
    // filter them again dwarfed the engine's own cost on statement lists.
    if LCaret.Prefix <> '' then
    begin
      LKeep := 0;
      for LIdx := 0 to High(LItems) do
        if LItems[LIdx].Name.StartsWith(LCaret.Prefix, True) then
        begin
          LItems[LKeep] := LItems[LIdx];
          Inc(LKeep);
        end;
      SetLength(LItems, LKeep);
      if LKeep = 0 then
        Exit;
    end;
    TArray.Sort<TPasComplItem>(LItems, TComparer<TPasComplItem>.Construct(
      function(const A, B: TPasComplItem): Integer
      begin
        Result := Ord(A.Bucket) - Ord(B.Bucket);
        if Result = 0 then
          Result := CompareText(A.Name, B.Name);
      end));
    // Declared-type detail is a real (cheap, on-demand) resolve per row -
    // worth it for a member list, noise-cost on a 1700-row scope list.
    LWithTypes := Length(LItems) <= 512;
    FCompl.ItemList.BeginUpdate;
    FCompl.InsertList.BeginUpdate;
    try
      FCompl.ItemList.Clear;
      FCompl.InsertList.Clear;
      for LIdx := 0 to High(LItems) do
      begin
        LName := LItems[LIdx].Name;
        // The kind column: routines get their real head word (constructor/
        // function/...) - the generic fallback covers everything else.
        LKindWord := '';
        if LItems[LIdx].Kind = skRoutine then
          LKindWord := LEngine.ItemHeadWord(LItems[LIdx]);
        if LKindWord = '' then
          LKindWord := ComplKindWord(LItems[LIdx]);
        LDetail := '';
        if LWithTypes and (LItems[LIdx].Mid >= 0) and
           (LItems[LIdx].Sym <> NIL_SYM) and
           (LItems[LIdx].Kind in [skVar, skConst, skField, skParam,
             skProperty, skRoutine]) then
        begin
          LX := FSemaProject.SymDeclTypeX(LItems[LIdx].Mid, LItems[LIdx].Sym);
          if LItems[LIdx].Ctx <> NIL_INST then
            LX := FSemaProject.SubstX(LX, LItems[LIdx].Ctx, 0);
          if XValid(LX) then
            LDetail := '\color{clGrayText}: ' + FSemaProject.XTypeText(LX);
        end;
        if LItems[LIdx].Overloads > 0 then
          LDetail := LDetail + Format('\color{clGrayText} (+%d)',
            [LItems[LIdx].Overloads]);
        FCompl.ItemList.Add(Format(
          '\color{clGrayText}%s\column{}\color{clWindowText}\style{+B}%s\style{-B}%s',
          [LKindWord, LName, LDetail]));
        FCompl.InsertList.Add(LName);
      end;
    finally
      FCompl.InsertList.EndUpdate;
      FCompl.ItemList.EndUpdate;
    end;
    CanExecute := True;
  finally
    LEngine.Free;
    LModel.Free;
  end;
  except
    on Exception do
      CanExecute := False;
  end;
end;

// Recreates FSemaProject/FNav (the previous ones, and any hover link into
// them, die here) and - crucially - feeds every OPEN editor's current text as
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
  FLastDefines := LDefines;
  InvalidateComplPipeline;            // config may have changed

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
    // completion on THIS thread instead of a worker) - its uses-closure walk
    // from FMainSource covers a plain .dpr just as well as the old
    // AnalyzeDirectory fallback did (StartAsyncAnalyze has used it
    // unconditionally, dproj or not, since the async path shipped). The one
    // real payoff: AOnProgress fires synchronously on the UI thread, so
    // lblProgress can show live progress during a blocking Run Parse -
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
    // Same as the async swap: the project is immutable from here on (every
    // re-analysis builds a fresh one), so drop the closed units' transient
    // maps - see ReleaseTransientMaps.
    FSemaProject.DemoteClosedUnits(FOpenFiles.ToStringArray);
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
  // Semantics are NOT computed here anymore - btnShowASTJsonClick/
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
      // the compiler WOULD compile is missing here - so the unit count is an
      // under-count - and it also GATES E2003 for that unit, so the diagnostic
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
          // - and keeps the FIRST site so the summary row can answer "where"
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
      // window showed 5, which reads as the tool contradicting itself - and the
      // 901 it hid were OUR OWN false positives in third-party code (283 of
      // them turned out to be a single parser bug in one third-party unit). A
      // diagnostic nobody can see is a bug nobody can report.
      LOwnFile := FFileList.IndexOf(FSemaProject.ModelFile(LId)) >= 0;
      for LDIdx := 0 to High(LModel.Diags) do
      begin
        Inc(LDiagTotal);
        if LOwnFile then
          Inc(LDiagListed);
        // A diagnostic's FileId is the MODEL'S OWN file table - for one
        // raised inside an $I-included file this is NOT the unit's main
        // file, so resolve it properly rather than assuming ModelFile(LId).
        LFileId := LModel.Diags[LDIdx].FileId;
        if (LFileId >= 0) and
           (LFileId <= High(LModel.Tree.Source.FileNames)) then
          LDiagFile := LModel.Tree.Source.FileNames[LFileId]
        else
          LDiagFile := FSemaProject.ModelFile(LId);
        // The label comes from the CODE, not a hardcoded "Error": a PPIF
        // reports our own inability to decide an $IF, and calling that an
        // error in the user's code is a lie (see DiagSeverityLabel).
        LogError(LDiagFile, LModel.Diags[LDIdx].Line, LModel.Diags[LDIdx].Col,
          Format('[%s] %s(%d,%d): %s',
            [DiagSeverityLabel(LModel.Diags[LDIdx].Code),
             TPath.GetFileName(LDiagFile), LModel.Diags[LDIdx].Line,
             LModel.Diags[LDIdx].Col, LModel.Diags[LDIdx].Msg]));
      end;
    end;
  finally
    vtMessages.EndUpdate;
  end;
  // Say WHERE the diagnostics are, not just how many. The total spans the
  // whole analyzed closure while only project files are listed, so a bare
  // total next to an empty message window reads as the tool contradicting
  // itself - which is exactly how the .dproj-less case used to look.
  // Memory beside the time, and for the same reason: on a 32-bit host the
  // address space is the binding constraint on a large project long before
  // speed is, and an EOutOfMemory reads as an analyzer defect unless the
  // figure that explains it is on screen. AllocatedBytes is what the analysis
  // HOLDS (models, token streams, node arenas) - see its own comment.
  if LDiagListed = LDiagTotal then
    Log(Format('Done: %d units, %d diagnostics in %s, %s held (%s).',
      [FSemaProject.ModelCount, LDiagTotal, ElapsedText(AElapsedMs),
       MemoryText(AllocatedBytes), cbThreading.Text]))
  else
    Log(Format('Done: %d units, %d diagnostics in %s, %s held (%s) - %d in ' +
      'project files, %d in library units. ALL are listed below.',
      [FSemaProject.ModelCount, LDiagTotal, ElapsedText(AElapsedMs),
       MemoryText(AllocatedBytes), cbThreading.Text, LDiagListed,
       LDiagTotal - LDiagListed]));
  // Volume the parser actually processed. An $I include is counted once per
  // INCLUDING unit, because that is how many times it was really lexed and
  // parsed - the figure is work done, not distinct bytes on disk. Chars, not
  // bytes: the source is UTF-16 in memory, and for (essentially ASCII)
  // Pascal source one char is one byte on disk, so this also reads as the
  // on-disk size.
  if LTotalLines > 0 then
  begin
    LVolume := Format('  source: %s lines, %.1f MB, %s file(s)',
      [FormatFloat('#,##0', LTotalLines), LTotalChars / (1024 * 1024),
       FormatFloat('#,##0', LTotalFiles)]);
    if AElapsedMs > 0 then
      LVolume := LVolume + Format(' - %s lines/s',
        [FormatFloat('#,##0', LTotalLines * 1000 / AElapsedMs)]);
    Log(LVolume);
  end;
  if LUnresUses = 0 then
    Log(Format('  closure: complete - every `uses` resolved across %d unit(s)',
      [FSemaProject.ModelCount]))
  else
  begin
    Log(Format('  closure: INCOMPLETE - %d unresolved `uses` name(s) over %d ' +
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
    Log(Format('  INTERNAL: %d unit(s) failed to parse - analyzer defect, not a ' +
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
// them in - so opening a project or re-analyzing after an edit never blocks
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
  // ...and any PENDING one: a debounce armed a moment ago (an edit, a tab, the
  // project that was open before this one) would otherwise fire mid-build,
  // cancel this run and restart the same work QUIET - which is how opening a
  // project lost its own "Done:" report. This run supersedes it, exactly as
  // the synchronous path already assumes.
  FReparseTimer.Enabled := False;
  if (FMainSource = '') or not BuildConfig(LPlatform, LSearchPaths, LDefines)
  then
    Exit;
  LRoots := [FMainSource];
  if (APriorityFile <> '') and TFile.Exists(APriorityFile) then
    LPriority := [APriorityFile]
  else
    LPriority := [];

  FLastSearchPaths := LSearchPaths;   // see the field
  FLastDefines := LDefines;
  InvalidateComplPipeline;            // config may have changed
  FAsyncModule := False;
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

  // PARSE DONOR (PasTree 0.9.0): the current project stays alive until the
  // swap in AsyncTimerTick, which is exactly the donor's contract - every
  // unit whose text is byte-identical skips preprocessing, lexing and
  // parsing.
  //
  // Only for the SAME project: another project means other search paths, so
  // the gate would refuse the donor by definition, and offering it would log
  // a "refused" line every time somebody opens something else. A refusal for
  // the same project IS worth reporting - it means the configuration moved
  // under us.
  if chkIncremental.Checked and Assigned(FSemaProject) and
     SameText(FSemaProjectRoot, FMainSource) then
    if not FAsyncSession.SetParseDonor(FSemaProject) then
      Log('Parse donor refused (configuration changed) - full rebuild.');

  FAsyncLoud := ALoud;
  FAnalyzeOverhead := '';      // async build reports no wrapper/stage timings
  FAsyncStart := TStopwatch.StartNew;
  FAsyncSession.Start;
  lblProgress.Caption := 'analyzing...';
  btnStop.Enabled := True;
  FAsyncTimer.Enabled := True;
end;

{ The single-module fast path (incremental plan stage B). The session TAKES
  OWNERSHIP of FSemaProject: the pointer stays valid and pointing at the same
  object throughout, but its models are being rewritten on the worker thread,
  so FAnalyzing is raised for the duration - the same guard the synchronous
  Analyze uses over every FNav/FSemaProject read.

  Applicability is deliberately narrow (see the declaration). Everything past
  that is the library's decision, reported by AsyncTimerTick. }
function TfrmMain.TryModuleReanalyze(const APath: string): Boolean;
var
  LIdx: Integer;
  LTab: TSourceTab;
begin
  Result := False;
  if not chkIncremental.Checked or Assigned(FAsyncSession) or
     not Assigned(FSemaProject) or (APath = '') then
    Exit;
  // Exactly one edited file, and it must be the one we were asked about.
  if (FDirtyFiles.Count <> 1) or not SameText(FDirtyFiles[0], APath) then
    Exit;
  // ...and it must already BE in the analyzed closure: a file the analysis
  // never loaded has no model to replace.
  if FSemaProject.ModelIdOf(APath) < 0 then
    Exit;

  FReparseTimer.Enabled := False;
  ClearLink;
  FreeAndNil(FNav);            // rebuilt after the swap, over the new models
  InvalidateComplPipeline;
  FAsyncModule := True;
  FAsyncModulePath := APath;
  FAsyncLoud := False;
  FAnalyzing := True;          // see the header
  FAsyncSession := TPasAsyncSession.CreateForModule(FSemaProject, APath);
  // Every open tab's current text, exactly like the full path - the edited
  // one is what this run is about, the rest keep their overlays alive.
  for LIdx := 0 to FOpenFiles.Count - 1 do
  begin
    LTab := TSourceTab(FOpenFiles.Objects[LIdx]);
    FAsyncSession.SetBuffer(LTab.FilePath, LTab.Editor.Text);
  end;
  FAnalyzeOverhead := '';
  FAsyncStart := TStopwatch.StartNew;
  FAsyncSession.Start;
  lblProgress.Caption := 'module...';
  FAsyncTimer.Enabled := True;
  Result := True;
end;

// The Stop button: user-requested cancellation of the in-flight analysis.
// Cancellation is cooperative and now lands MID-PASS (see FCancelCheck in
// TPasSemaProject), so the drain inside CancelAsync is short even on a big
// project. The previous project/navigator were never touched by the aborted
// build (double-buffering), so navigation keeps working on the older model.
procedure TfrmMain.btnStopClick(Sender: TObject);
begin
  if not Assigned(FAsyncSession) then
    Exit;
  CancelAsync;
  lblProgress.Caption := 'cancelled';
  Log('Analysis cancelled by user - keeping the previous results.');
end;

// Cancels and drains the in-flight background analysis (if any). Called before
// a new analysis supersedes it, on Run Parse, and on shutdown.
procedure TfrmMain.CancelAsync;
begin
  FAsyncTimer.Enabled := False;
  btnStop.Enabled := False;
  if Assigned(FAsyncSession) then
  begin
    FAsyncSession.Cancel;
    // A module session OWNS our project - Destroy would take it with it. It
    // also cannot be cancelled part-way (one commit point, milliseconds), so
    // let it finish and reclaim the project either way.
    if FAsyncModule then
    begin
      FAsyncSession.WaitFor;
      FSemaProject := FAsyncSession.TakeProject;
      FAnalyzing := False;
      FAsyncModule := False;
      if Assigned(FSemaProject) and not Assigned(FNav) then
        FNav := TPasNavigator.Create(FSemaProject);
    end;
    FreeAndNil(FAsyncSession);   // Destroy waits for the worker to drain
  end;
end;

procedure TfrmMain.AsyncTimerTick(Sender: TObject);
var
  LProgress: TPasStagedProgress;
  LError, LTimings: string;
  LAccepted: Boolean;
begin
  if not Assigned(FAsyncSession) then
  begin
    FAsyncTimer.Enabled := False;
    Exit;
  end;
  if not FAsyncModule then
  begin
    LProgress := FAsyncSession.Progress;
    lblProgress.Caption := Format('%s %d/%d',
      [LProgress.Phase, LProgress.FullDone, LProgress.Total]);
  end;
  if not FAsyncSession.IsDone then
    Exit;

  // ---- the single-module fast path finished ----
  if FAsyncModule then
  begin
    FAsyncTimer.Enabled := False;
    FAsyncStart.Stop;
    LError := FAsyncSession.LastError;
    LAccepted := FAsyncSession.ModuleAccepted;
    FSemaProject := FAsyncSession.TakeProject;   // ours again, either way
    LTimings := '';
    if Assigned(FSemaProject) then
      LTimings := FSemaProject.StageTimings;
    FreeAndNil(FAsyncSession);
    FAsyncModule := False;
    FAnalyzing := False;
    if Assigned(FSemaProject) then
      FNav := TPasNavigator.Create(FSemaProject);
    if LError <> '' then
      Log('Module reanalysis error: ' + LError);
    if LAccepted then
    begin
      FDirtyFiles.Clear;
      // The label is a PROGRESS indicator and ends where every other path
      // ends - at 'done'. The timing belongs in the message log, which the
      // line below writes.
      lblProgress.Caption := 'done';
      Log(Format('Reanalyzed %s only - %d ms (%s)',
        [TPath.GetFileName(FAsyncModulePath), FAsyncStart.ElapsedMilliseconds,
         LTimings]));
    end
    else
    begin
      // Refused (an interface change, an unresolved $IF, a demoted model...).
      // The reason is in StageTimings; the rebuild below adopts this project
      // as a parse donor, so the fallback is not a cold build either.
      Log('Module fast path refused (' + LTimings + ') - rebuilding.');
      StartAsyncAnalyze(FAsyncModulePath, {ALoud} False);
    end;
    Exit;
  end;

  // Build finished - swap in the new project/navigator on this (UI) thread.
  FAsyncTimer.Enabled := False;
  btnStop.Enabled := False;
  FAsyncStart.Stop;
  LError := FAsyncSession.LastError;
  ClearLink;
  FreeAndNil(FNav);
  FreeAndNil(FSemaProject);
  FSemaProject := FAsyncSession.TakeProject;
  FreeAndNil(FAsyncSession);
  if Assigned(FSemaProject) then
  begin
    FNav := TPasNavigator.Create(FSemaProject);
    // MEMORY-AUDIT sec. 6.4-4 stage 1: this project is now IMMUTABLE for us -
    // every re-analysis goes through a fresh session - so the per-unit maps
    // nothing reads after analysis can go, except for the open tabs'
    // (completion reads the ACTIVE file's). ~10% of a big closure's RSS.
    // A tab opened later than a build that demoted then re-analyzes to get
    // its unit back in full - and ONLY then (see OpenFileTab).
    //
    // NOT while chkIncremental is on: a demoted unit has no text layer, so it
    // is a parse-donor MISS and a fast-path refusal. That is the trade the
    // switch exists to show - memory against edit latency.
    FLastBuildDemoted := not chkIncremental.Checked;
    if FLastBuildDemoted then
      FSemaProject.DemoteClosedUnits(FOpenFiles.ToStringArray);
    FDirtyFiles.Clear;   // this build saw every edit made so far
    FSemaProjectRoot := FMainSource;   // what this project was built from
  end;
  // A tab opened while this build was running asked for a re-analysis; now
  // that it has landed, ask again - most of the time the answer is no,
  // because the build covered that unit.
  if FPendingTabReanalyze then
  begin
    FPendingTabReanalyze := False;
    if Assigned(FSemaProject) and FLastBuildDemoted then
    begin
      FReparseTimer.Enabled := False;
      FReparseTimer.Enabled := True;
    end
    else if Assigned(FSemaProject) then
      for var LIdx := 0 to FOpenFiles.Count - 1 do
        if FSemaProject.ModelIdOf(
             TSourceTab(FOpenFiles.Objects[LIdx]).FilePath) < 0 then
        begin
          FReparseTimer.Enabled := False;
          FReparseTimer.Enabled := True;
          Break;
        end;
  end;

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
  // One edited unit already in the closure goes through the fast path; the
  // rebuild below is both the general case and the refusal fallback.
  if TryModuleReanalyze(LActive) then
    Exit;
  StartAsyncAnalyze(LActive, {ALoud} False);
end;

// Any real edit (re)arms the debounce timer; programmatic loads are excluded.
procedure TfrmMain.EditorChange(Sender: TObject);
begin
  if FLoadingFile then
    Exit;
  // Tell the PasTree highlighter its buffer changed - see EnsureFresh's
  // header comment: without this it can only detect a change by rebuilding
  // and comparing the WHOLE buffer on every repainted line, which is what
  // made opening a large file (e.g. System.SysUtils.pas via go-to-
  // declaration) hang. PasTreeHL stays assigned even while SynEdit's own
  // highlighter is the active one, so this is safe regardless of cbHighlighter.
  TSourceTab(TSynEdit(Sender).Parent).PasTreeHL.MarkDirty;
  ClearLink;                        // the stale model no longer matches the text
  // Which units the next analysis must account for - the fast path applies to
  // exactly one (see FDirtyFiles).
  var LPath := TSourceTab(TSynEdit(Sender).Parent).FilePath;
  if (LPath <> '') and (FDirtyFiles.IndexOf(LPath) < 0) then
    FDirtyFiles.Add(LPath);
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

{ navigation history - Back / Forward }

// Loading a file REPLACES its whole text, which arrives as one enormous
// insertion - nothing has moved as far as the history is concerned. The rules
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

{ THE jump. Every navigation goes through here - ctrl+click, the Goto
  Declaration/Implementation pair, and a double-click in the message window -
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
  // Read BEFORE the jump, obviously - but also before OpenFileTab, which can
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
// entry being LEFT from the live caret first - see TNavHistory.UpdateCurrent.
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
  editor as it is created. Kept to an integer compare - this runs for every
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
  a tab carries a preprocessing context - search paths, defines, platform -
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

  With a .dproj, the names come from the project - a real one rarely stops at
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
  // the search paths and - through per-config DCCReference conditions - the
  // file list itself, so nothing short of reading the .dproj again is honest.
  FConfigOverride := SelectedConfig;
  OpenProject(FProjectFile);
end;

{ recent projects - the Open Project split button's drop-down }

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
    // is unambiguous - the first nine. `&10` would bind the key `1`, which
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
  // before it was ever visible - remembering it would be a setting that does
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
              // survived here the two never compared equal - so EVERY
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
// the active platform - third-party component sources land
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
        Continue;   // unresolvable macro left - not a usable dir
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
// (source\rtl\BuildWinRTL.dproj - its `contains` list is the full Windows
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
    for a Studio install with no compiled lib directory - Win32UnitIndex below
    is the real one, and is strictly better (see its own comment). }
  CNonWindowsSegments: array[0..9] of string = (
    'mac', 'osx', 'ios', 'android', 'linux', 'posix', 'cocoa', 'gles',
    'metal', 'jni');

{ Basenames (lower-cased, extension-less) of every unit the installed Studio
  actually COMPILES for Win32: exactly those with a .dcu under
  lib\win32\release. This is Embarcadero's own answer to "is this unit part of
  the Win32 build", which beats any name-based guess - measured against
  Studio 37.0's source tree it additionally excludes:
    - FMX.BiometricAuth and FMX.Media.AVFoundation - Apple-only, but with no
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
  pulls in the whole closure - the same trick the Parse RTL button gets for
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
      Log(Format('%s: %d unit(s); %d skipped (no Win32 .dcu - not part of ' +
        'this platform''s build)', [APackageName, LKept, LSkipped]))
    else
      Log(Format('%s: %d unit(s); %d skipped by name (no compiled lib dir - ' +
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

{ View Unit (Ctrl+F12) - a modal picker over the project's units.

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
  // when UsesReady said yes - the same FAnalyzing/FAsyncSession guard every
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
// dropdown - the standard VCL color-picker combo, restricted to exactly our
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
// shared highlighter to update - see TSourceTab/OpenFileTab) and repaints
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

// SynEdit's own selection-change notification - fires for any selection
// change regardless of input method (mouse drag, double-click word-select,
// Shift+arrow, Ctrl+A, ...). A plain identifier selection arms the "same
// identifier" highlight on THIS tab's own highlighter instance; anything
// else (no selection, a multi-word/punctuation selection) clears it. Plain
// NAME match, no semantic resolution - see PasTreeDemo.Highlighter.
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
  // Result.Lines.LoadFromFile call returns (see its own comments) - loading
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
