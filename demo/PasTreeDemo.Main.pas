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
  PasTree.Sema.Nav,
  PasTree.Sema.Dump, VirtualTrees.BaseAncestorVCL, VirtualTrees.BaseTree, VirtualTrees.AncestorVCL, SynEditCodeFolding,
  PasTreeDemo.Highlighter;
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
    FLoadingFile: Boolean;         // suppresses OnChange during programmatic load
    FStudioRoot: string;           // RAD Studio root (for RTL search paths)
    procedure SetupControls;
    procedure ApplyPasTreePalette(AHL: TSynPasSyn);
    procedure EnsureSampleProject;
    function ExeDir: string;
    function StudioRoot: string;
    function ExtraSearchPaths: TArray<string>;
    procedure OpenProject(const AProjectFile: string);
    procedure PopulateTree;
    function OpenFileTab(const APath: string): TSynEdit;
    function Analyze: Boolean;
    procedure RunParse;
    procedure ReanalyzeForNav;
    procedure EditorChange(Sender: TObject);
    procedure ReparseTimerTick(Sender: TObject);
    procedure Log(const AText: string);
    // go-to-declaration (ctrl+hover link / ctrl+click)
    function ResolveAt(AEditor: TSynEdit; X, Y: Integer;
      out ARawToken: Integer; out ATarget: TPasNavTarget): Boolean;
    procedure SetLink(ATab: TObject; ARawToken: Integer);
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

  function CreateBytes(ALen: Integer): TBytes;
  begin
    SetLength(Result, ALen);
  end;

  begin
    S := '';
    Arr := [];
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
  SetupControls;
  EnsureSampleProject;
  // Open the bundled sample by default and analyze it immediately so the
  // Semantics tab (and navigation) are populated on launch.
  OpenProject(TPath.Combine(TPath.Combine(ExeDir, 'Sample'), 'Sample.dpr'));
  RunParse;
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
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
  LExt: string;
begin
  if not TFile.Exists(AProjectFile) then
  begin
    Log('Project not found: ' + AProjectFile);
    Exit;
  end;
  FreeAndNil(FDProj);
  LExt := LowerCase(TPath.GetExtension(AProjectFile));
  FPlatform := pfWin32;
  if LExt = '.dproj' then
  begin
    FDProj := TPasDProj.Create;
    if FDProj.Load(AProjectFile) then
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
      if not TryReadDProj(AProjectFile, FPlatform, FMainSource) then
        FPlatform := pfWin32;
      FProjectDir := TPath.GetDirectoryName(AProjectFile);
      if (FMainSource <> '') and not TPath.IsPathRooted(FMainSource) then
        FMainSource := TPath.Combine(FProjectDir, FMainSource);
      if not TFile.Exists(FMainSource) then
        FMainSource := TPath.ChangeExtension(AProjectFile, '.dpr');
    end;
  end
  else
  begin
    FMainSource := AProjectFile;
    FProjectDir := TPath.GetDirectoryName(AProjectFile);
  end;

  case FPlatform of
    pfWin64: cbPlatform.ItemIndex := 1;
  else
    cbPlatform.ItemIndex := 0;
  end;

  Caption := 'PasTree Demo — ' + TPath.GetFileName(AProjectFile);
  PopulateTree;
  if TFile.Exists(FMainSource) then
    OpenFileTab(FMainSource);
  Log('Opened project: ' + AProjectFile +
    '  (platform ' + PlatformName(FPlatform) + ', ' +
    IntToStr(FFileList.Count) + ' files)');
end;

procedure TfrmMain.PopulateTree;
var
  LAll: TArray<string>;
  LFile, LExt: string;
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
  else
  begin
    if not TDirectory.Exists(FProjectDir) then
      Exit;
    LAll := TDirectory.GetFiles(FProjectDir, '*.*',
      TSearchOption.soAllDirectories);
    for LFile in LAll do
    begin
      LExt := LowerCase(TPath.GetExtension(LFile));
      if (LExt = '.pas') or (LExt = '.dpr') or (LExt = '.dpk') or
         (LExt = '.inc') then
        FFileList.Add(LFile);
    end;
  end;

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
  out ARawToken: Integer; out ATarget: TPasNavTarget): Boolean;
var
  LTab: TSourceTab;
  LMid: Integer;
  LBC: TBufferCoord;
  LIdent: TPasNavIdent;
begin
  Result := False;
  if FNav = nil then
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
  ARawToken := LIdent.RawToken;
  Result := True;
end;

procedure TfrmMain.SetLink(ATab: TObject; ARawToken: Integer);
var
  LTab: TSourceTab;
begin
  if (FLinkTab = ATab) and
     (TSourceTab(ATab).PasTreeHL.LinkToken = ARawToken) then
    Exit;
  ClearLink;
  LTab := TSourceTab(ATab);
  LTab.PasTreeHL.LinkToken := ARawToken;
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
  LTab.PasTreeHL.LinkToken := -1;
  LTab.Editor.Cursor := crIBeam;
  LTab.Editor.Invalidate;
  FLinkTab := nil;
end;

procedure TfrmMain.EditorMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Integer);
var
  LRaw: Integer;
  LTarget: TPasNavTarget;
begin
  if (ssCtrl in Shift) and
     ResolveAt(TSynEdit(Sender), X, Y, {out} LRaw, {out} LTarget) then
    SetLink(TSynEdit(Sender).Parent, LRaw)
  else
    ClearLink;
end;

procedure TfrmMain.EditorMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  LEditor: TSynEdit;
  LSameFile: Boolean;
  LRaw: Integer;
  LTarget: TPasNavTarget;
begin
  if (Button <> mbLeft) or not (ssCtrl in Shift) then
    Exit;
  LEditor := TSynEdit(Sender);
  if not ResolveAt(LEditor, X, Y, {out} LRaw, {out} LTarget) then
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
begin
  Result := False;
  if (FProjectDir = '') or not TDirectory.Exists(FProjectDir) then
    Exit;
  if cbPlatform.ItemIndex = 1 then
    LPlatform := pfWin64
  else
    LPlatform := pfWin32;

  if Assigned(FDProj) then
  begin
    LSearchPaths := [FProjectDir] + FDProj.SearchPaths;
    LDefines := FDProj.Defines;
  end
  else
  begin
    LSearchPaths := [FProjectDir];
    LDefines := [];
  end;
  LSearchPaths := LSearchPaths + ExtraSearchPaths;   // System.* -> RTL sources

  ClearLink;
  FreeAndNil(FNav);
  FreeAndNil(FSemaProject);
  FSemaProject := TPasSemaProject.Create(LPlatform, LSearchPaths, LDefines);
  FSemaProject.SingleThreaded := cbThreading.ItemIndex = 0;
  for LIdx := 0 to FOpenFiles.Count - 1 do
  begin
    LTab := TSourceTab(FOpenFiles.Objects[LIdx]);
    FSemaProject.SetBuffer(LTab.FilePath, LTab.Editor.Text);
  end;

  // A .dproj drives the real uses-graph from its main source (correctly
  // reaching units outside FProjectDir); a plain .dpr falls back to
  // "everything under this folder" for simplicity.
  if Assigned(FDProj) and (FMainSource <> '') then
    FSemaProject.AnalyzeFile(FMainSource)
  else
    FSemaProject.AnalyzeDirectory(FProjectDir);
  FNav := TPasNavigator.Create(FSemaProject);
  Result := True;
end;

procedure TfrmMain.RunParse;
var
  LMain, LDiagTotal, LId, LDIdx: Integer;
  LModel: TPasSemaModel;
  LSW: TStopwatch;
begin
  if (FProjectDir = '') or not TDirectory.Exists(FProjectDir) then
  begin
    Log('No project open.');
    Exit;
  end;
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

    // Locate the main unit's model, and report every unit's diagnostics.
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
        Log(Format('%s(%d,%d): %s',
          [TPath.GetFileName(FSemaProject.ModelFile(LId)),
           LModel.Diags[LDIdx].Line, LModel.Diags[LDIdx].Col,
           LModel.Diags[LDIdx].Msg]));
      end;
    end;
    Log(Format('Done: %d units, %d diagnostics in %d ms (%s).',
      [FSemaProject.ModelCount, LDiagTotal, LSW.ElapsedMilliseconds,
       cbThreading.Text]));

    if LMain >= 0 then
    begin
      LModel := FSemaProject.Model(LMain);
      edJson.Text := PrettyJson(AstToJson(LModel.Tree));
      edSema.Text := DumpSemaModel(LModel);
      pgc.ActivePage := tsSema;
    end
    else
      Log('Main source not found among analyzed units: ' + FMainSource);
  finally
    Screen.Cursor := crDefault;
  end;
end;

// Quiet re-analysis after an edit: rebuilds the model + navigator so
// ctrl+hover/click keep matching the edited buffer, WITHOUT touching the tabs,
// the AST/Semantics views or the message log (that would fight the typist).
procedure TfrmMain.ReanalyzeForNav;
begin
  if (FProjectDir = '') or not TDirectory.Exists(FProjectDir) then
    Exit;
  Screen.Cursor := crHourGlass;
  try
    Analyze;
  finally
    Screen.Cursor := crDefault;
  end;
end;

procedure TfrmMain.ReparseTimerTick(Sender: TObject);
begin
  FReparseTimer.Enabled := False;
  ReanalyzeForNav;
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

// RTL source directories to add to every project's search paths, so `uses
// System.SysUtils` (and other System.* units) resolve and get analyzed —
// which is what makes cross-unit go-to-declaration into the RTL work (e.g.
// ctrl+click TBytes -> System.SysUtils). Empty when Studio isn't found; a
// unit's own $I includes resolve relative to it, so listing the unit dirs
// (sys/common/win/net) is enough.
function TfrmMain.ExtraSearchPaths: TArray<string>;
var
  LRtl, LDir: string;
begin
  Result := [];
  if FStudioRoot = '' then
    Exit;
  LRtl := TPath.Combine(FStudioRoot, 'source\rtl');
  for var LSub in ['sys', 'common', 'win', 'net'] do
  begin
    LDir := TPath.Combine(LRtl, LSub);
    if TDirectory.Exists(LDir) then
      Result := Result + [LDir];
  end;
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
