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
  System.JSON, System.Diagnostics, System.Win.Registry,
  Winapi.Windows, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls,
  Vcl.ExtCtrls, Vcl.Dialogs, Vcl.Graphics,
  SynEdit, SynEditTypes, SynEditHighlighter, SynHighlighterJSON,
  SynHighlighterPas,
  VirtualTrees, VirtualTrees.Types,
  PasTree.Platforms, PasTree.Preprocessor, PasTree.Ast, PasTree.Ast.Json,
  PasTree.Parser, PasTree.Project, PasTree.DProj,
  PasTree.Sema.Diagnostics, PasTree.Sema.Model, PasTree.Sema.Builtins,
  PasTree.Sema.Types, PasTree.Sema.Resolver, PasTree.Sema.Project,
  PasTree.Sema.Nav, PasTree.Sema.Async,
  PasTree.Sema.Dump, VirtualTrees.BaseAncestorVCL, VirtualTrees.BaseTree, VirtualTrees.AncestorVCL, SynEditCodeFolding,
  PasTreeDemo.Highlighter, Vcl.Menus, System.Actions, Vcl.ActnList, SynEditMiscClasses, SynEditSearch;
  // System

type
  // VirtualTree node payload: an index into FFileList (unmanaged, so the tree
  // needs no per-node finalization).
  TPasNodeData = record
    Index: Integer;
  end;
  PPasNodeData = ^TPasNodeData;

  TfrmMain = class(TForm)
    pnlTop: TPanel;
    btnOpen: TButton;
    btnParse: TButton;
    btnParseRtl: TButton;
    cbPlatform: TComboBox;
    cbHighlighter: TComboBox;
    cbThreading: TComboBox;
    lblProgress: TLabel;    // background-analysis "phase done/total"
    splLeft: TSplitter;
    vstFiles: TVirtualStringTree;
    pgc: TPageControl;
    tsJson: TTabSheet;
    edJson: TSynEdit;
    tsSema: TTabSheet;
    edSema: TSynEdit;
    splBottom: TSplitter;
    mmMessages: TMemo;
    SynJSONSyn1: TSynJSONSyn;
    ActionList1: TActionList;
    FindAction: TAction;
    GotoImplAction: TAction;
    GotoDeclAction: TAction;
    SourcePopupMenu: TPopupMenu;
    Find1: TMenuItem;
    GotoImplementation1: TMenuItem;
    GotoDeclaration1: TMenuItem;
    SynEditSearch1: TSynEditSearch;
    pnlBottom: TPanel;
    Panel1: TPanel;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure btnOpenClick(Sender: TObject);
    procedure btnParseClick(Sender: TObject);
    procedure btnParseRtlClick(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure vstFilesGetText(Sender: TBaseVirtualTree; Node: PVirtualNode;
      Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);
    procedure vstFilesChange(Sender: TBaseVirtualTree; Node: PVirtualNode);
    procedure cbHighlighterChange(Sender: TObject);
    procedure FindActionUpdate(Sender: TObject);
    procedure FindActionExecute(Sender: TObject);
    procedure GotoImplActionUpdate(Sender: TObject);
    procedure GotoImplActionExecute(Sender: TObject);
    procedure GotoDeclActionUpdate(Sender: TObject);
    procedure GotoDeclActionExecute(Sender: TObject);
  private
    FFileList: TStringList;  // full paths shown in the tree
    FOpenFiles: TStringList; // path -> TTabSheet (Objects)
    FDProj: TPasDProj;       // Assigned only when a .dproj was opened
    FProjectDir: string;
    FMainSource: string;
    FPlatform: TPasPlatform;
    FSynPasHL: TSynPasSyn;   // shared SynEdit built-in highlighter (A/B compare)
    FSemaProject: TPasSemaProject; // kept alive after RunParse (navigation)
    FNav: TPasNavigator;           // go-to-declaration over FSemaProject
    FLinkTab: TObject;             // TSourceTab currently showing a link
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
    FStudioRoot: string;           // RAD Studio root (for RTL search paths)
    FFindBar: TForm;                // floating find toolbar (TFindBar); lazy
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
    procedure Log(const AText: string);
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
  LTab: TSourceTab;
begin
  if not ActiveRoutineTarget(True, {out} LTarget) then
    Exit;
  LTab := TSourceTab(pgc.ActivePage);
  LTab.Editor.CaretXY := BufferCoord(LTarget.Col, LTarget.Line);
  LTab.Editor.EnsureCursorPosVisible;
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
  LTab: TSourceTab;
begin
  if not ActiveRoutineTarget(False, {out} LTarget) then
    Exit;
  LTab := TSourceTab(pgc.ActivePage);
  LTab.Editor.CaretXY := BufferCoord(LTarget.Col, LTarget.Line);
  LTab.Editor.EnsureCursorPosVisible;
end;

procedure TfrmMain.GotoDeclActionUpdate(Sender: TObject);
var
  LTarget: TPasNavTarget;
begin
  TAction(Sender).Enabled := ActiveRoutineTarget(False, {out} LTarget);
end;

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  FFileList := TStringList.Create;
  FOpenFiles := TStringList.Create;
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
  SetupControls;
  EnsureSampleProject;
  // Open the bundled sample by default; OpenProject kicks off the background
  // analysis that populates the Semantics tab and navigation when it finishes.
  OpenProject(TPath.Combine(TPath.Combine(ExeDir, 'Sample'), 'Sample.dpr'));
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  CancelAsync;                 // cancel + drain the worker before tearing down
  FreeAndNil(FNav);
  FreeAndNil(FSemaProject);
  FreeAndNil(FDProj);
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

  mmMessages.Font.Name := 'Consolas';
  mmMessages.Font.Size := 9;

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

procedure TfrmMain.Log(const AText: string);
begin
  mmMessages.Lines.Add(AText);
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
  LFile := AProjectFile;
  LExt := LowerCase(TPath.GetExtension(LFile));
  // Opening the bare .dpr of a real project should behave exactly like
  // opening its .dproj (same search paths/defines/full file list) — a real
  // IDE does this too. Redirect BEFORE anything else reads LExt/LFile.
  if LExt = '.dpr' then
  begin
    LSiblingDProj := TPath.ChangeExtension(LFile, '.dproj');
    if TFile.Exists(LSiblingDProj) then
    begin
      LFile := LSiblingDProj;
      LExt := '.dproj';
    end;
  end;
  FreeAndNil(FDProj);
  FPlatform := pfWin32;
  if LExt = '.dproj' then
  begin
    FDProj := TPasDProj.Create;
    if FDProj.Load(LFile) then
    begin
      FPlatform := FDProj.Platform;
      FMainSource := FDProj.MainSource;
      FProjectDir := FDProj.Dir;
      Log(Format('  .dproj: config %s, %d search path(s), %d define(s), ' +
        '%d unit alias(es)', [FDProj.Config, Length(FDProj.SearchPaths),
        Length(FDProj.Defines), Length(FDProj.UnitAliases)]));
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
      if not TFile.Exists(FMainSource) then
        FMainSource := TPath.ChangeExtension(LFile, '.dpr');
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

  Caption := 'PasTree Demo — ' + TPath.GetFileName(LFile);
  PopulateTree;
  if TFile.Exists(FMainSource) then
    OpenFileTab(FMainSource);
  Log('Opened project: ' + LFile +
    '  (platform ' + PlatformName(FPlatform) + ', ' +
    IntToStr(FFileList.Count) + ' files)');
  // Kick off the background analysis (non-blocking); it populates the
  // Semantics/AST views and navigation when it finishes. The open main file
  // is front-loaded so it is ready first.
  mmMessages.Clear;
  Log('Analyzing ' + FProjectDir + ' (' + cbPlatform.Text +
    ') in the background...');
  StartAsyncAnalyze(FMainSource, {ALoud} True);
end;

procedure TfrmMain.PopulateTree;
var
  LFile: string;
  LNode: PVirtualNode;
begin
  FFileList.Clear;
  vstFiles.Clear;

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
    // .dproj when one exists — see there): a rare case, not worth a directory
    // scan or a `uses`-clause parse. Show just the main file itself.
    FFileList.Add(FMainSource);

  FFileList.Sort;
  vstFiles.BeginUpdate;
  try
    for var LIndex := 0 to FFileList.Count - 1 do
    begin
      LNode := vstFiles.AddChild(nil);
      PPasNodeData(vstFiles.GetNodeData(LNode))^.Index := LIndex;
    end;
  finally
    vstFiles.EndUpdate;
  end;
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
  Result.PopupMenu := SourcePopupMenu;
  Result.SearchEngine := SynEditSearch1;

  // Our own PasTree-lexer-driven highlighter — one instance per tab (it
  // caches the tokenization of its own attached buffer, so instances can't
  // be shared across editors). Kept alive even when SynEdit's highlighter is
  // the active one, so cbHighlighterChange can switch back without recreating it.
  LHL := TPasTreeSynHighlighter.Create(Result);
  LHL.SourceLines := Result.Lines;
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
  if (ssCtrl in Shift) and
     ResolveAt(TSynEdit(Sender), X, Y, {out} LFrom, {out} LTo, {out} LTarget)
  then
    SetLink(TSynEdit(Sender).Parent, LFrom, LTo)
  else
    ClearLink;
end;

procedure TfrmMain.EditorMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  LEditor: TSynEdit;
  LSameFile: Boolean;
  LFrom, LTo: Integer;
  LTarget: TPasNavTarget;
begin
  if (Button <> mbLeft) or not (ssCtrl in Shift) then
    Exit;
  LEditor := TSynEdit(Sender);
  if not ResolveAt(LEditor, X, Y, {out} LFrom, {out} LTo, {out} LTarget) then
    Exit;
  ClearLink;
  LSameFile := SameText(LTarget.FilePath, TSourceTab(LEditor.Parent).FilePath);
  // SynEdit's own MouseDown moves the caret to the click position AFTER this
  // handler returns (inherited MouseDown fires us, THEN MoveDisplayPosAnd-
  // Selection), clobbering our jump — which is why it previously only "worked"
  // on a double-click, where SynEdit bails early on ssDouble. Defer the jump so
  // it runs after SynEdit's caret move, and a single ctrl+click lands correctly.
  TThread.ForceQueue(nil,
    procedure
    var
      LTargetEd: TSynEdit;
    begin
      if LSameFile then
        LTargetEd := LEditor                        // same unit: jump in place
      else
        LTargetEd := OpenFileTab(LTarget.FilePath); // other unit: (re)open a tab
      LTargetEd.CaretXY := BufferCoord(LTarget.Col, LTarget.Line);
      LTargetEd.EnsureCursorPosVisible;
      if LTargetEd.CanFocus then
        LTargetEd.SetFocus;
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
    if Assigned(FDProj) then
    begin
      FSemaProject.SetNamespaces(FDProj.Namespaces); // `uses Forms` -> Vcl.Forms
      for var LAlias in FDProj.UnitAliases do
        FSemaProject.AddUnitAlias(LAlias.Alias, LAlias.UnitName);
    end;
    for LIdx := 0 to FOpenFiles.Count - 1 do
    begin
      LTab := TSourceTab(FOpenFiles.Objects[LIdx]);
      FSemaProject.SetBuffer(LTab.FilePath, LTab.Editor.Text);
    end;

    // A .dproj drives the real uses-graph from its main source (correctly
    // reaching units outside FProjectDir) — the FULL transitive closure, so
    // go-to-declaration works inside every dependency unit, not just the
    // main file; a plain .dpr falls back to "everything under this folder".
    LSW := TStopwatch.StartNew;
    if Assigned(FDProj) and (FMainSource <> '') then
      FSemaProject.AnalyzeProject(FMainSource)
    else
      FSemaProject.AnalyzeDirectory(FProjectDir);
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
  LMain, LDiagTotal, LId, LDIdx: Integer;
  LModel: TPasSemaModel;
begin
  // Locate the main unit's model, and report diagnostics. The analyzed
  // closure now includes the whole RTL/VCL/3rd-party reach (for nav), so
  // only PROJECT files' diagnostics are LISTED (external ones would bury
  // the user's own in noise); the total still counts everything.
  LMain := -1;
  LDiagTotal := 0;
  for LId := 0 to FSemaProject.ModelCount - 1 do
  begin
    LModel := FSemaProject.Model(LId);
    if SameText(FSemaProject.ModelFile(LId), FMainSource) then
      LMain := LId;
    for LDIdx := 0 to High(LModel.Diags) do
    begin
      Inc(LDiagTotal);
      if FFileList.IndexOf(FSemaProject.ModelFile(LId)) >= 0 then
        Log(Format('%s(%d,%d): %s',
          [TPath.GetFileName(FSemaProject.ModelFile(LId)),
           LModel.Diags[LDIdx].Line, LModel.Diags[LDIdx].Col,
           LModel.Diags[LDIdx].Msg]));
    end;
  end;
  Log(Format('Done: %d units, %d diagnostics in %d ms (%s).',
    [FSemaProject.ModelCount, LDiagTotal, AElapsedMs, cbThreading.Text]));
  if FSemaProject.StageTimings <> '' then
    Log('  stages: ' + FSemaProject.StageTimings);
  if FAnalyzeOverhead <> '' then
    Log('  wrapper: ' + FAnalyzeOverhead);

  if LMain >= 0 then
  begin
    LModel := FSemaProject.Model(LMain);
    edJson.Text := PrettyJson(AstToJson(LModel.Tree));
    edSema.Text := DumpSemaModel(LModel);
    pgc.ActivePage := tsSema;
  end
  else
    Log('Main source not found among analyzed units: ' + FMainSource);
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
  mmMessages.Clear;
  Log('Analyzing ' + FProjectDir + ' (' + cbPlatform.Text + ')...');
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

  FAsyncSession := TPasAsyncSession.Create(LPlatform, LSearchPaths, LDefines,
    LRoots, LPriority);
  FAsyncSession.SetSingleThreadedInner(cbThreading.ItemIndex = 0);
  if Assigned(FDProj) then
  begin
    FAsyncSession.SetNamespaces(FDProj.Namespaces);
    for var LAlias in FDProj.UnitAliases do
      FAsyncSession.AddUnitAlias(LAlias.Alias, LAlias.UnitName);
  end;
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

{ event handlers }

procedure TfrmMain.btnOpenClick(Sender: TObject);
var
  LDlg: TOpenDialog;
begin
  LDlg := TOpenDialog.Create(Self);
  try
    LDlg.Filter := 'Delphi project (*.dpr;*.dproj)|*.dpr;*.dproj|All files|*.*';
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
    Exit;
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
              Result := LDir;
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
// the active platform — third-party sources like SynEdit/DevExpress land
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

initialization
  // The .dfm streams these third-party controls; ensure the statically-linked
  // build (no design-time packages) can find their classes.
  RegisterClasses([TSynEdit, TVirtualStringTree]);

end.
