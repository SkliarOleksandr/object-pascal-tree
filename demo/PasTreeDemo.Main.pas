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
  System.JSON,
  Winapi.Windows, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls,
  Vcl.ExtCtrls, Vcl.Dialogs, Vcl.Graphics,
  SynEdit, SynEditHighlighter, SynHighlighterJSON, SynHighlighterPas,
  VirtualTrees, VirtualTrees.Types,
  PasTree.Platforms, PasTree.Preprocessor, PasTree.Ast, PasTree.Ast.Json,
  PasTree.Parser, PasTree.Project, PasTree.DProj,
  PasTree.Sema.Diagnostics, PasTree.Sema.Model, PasTree.Sema.Builtins,
  PasTree.Sema.Types, PasTree.Sema.Resolver, PasTree.Sema.Project,
  PasTree.Sema.Dump, VirtualTrees.BaseAncestorVCL, VirtualTrees.BaseTree, VirtualTrees.AncestorVCL, SynEditCodeFolding,
  PasTreeDemo.Highlighter;

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
    cbPlatform: TComboBox;
    cbHighlighter: TComboBox;
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
    procedure SetupControls;
    procedure ApplyPasTreePalette(AHL: TSynPasSyn);
    procedure EnsureSampleProject;
    function ExeDir: string;
    procedure OpenProject(const AProjectFile: string);
    procedure PopulateTree;
    function OpenFileTab(const APath: string): TSynEdit;
    procedure RunParse;
    procedure Log(const AText: string);
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
  end;

const
  SAMPLE_DPR =
    'program Sample;'#13#10 +
    #13#10 +
    '{$APPTYPE CONSOLE}'#13#10 +
    #13#10 +
    'uses'#13#10 +
    '  System.SysUtils;'#13#10 +
    #13#10 +
    'begin'#13#10 +
    '  Writeln(''Hello, world!'');'#13#10 +
    '  Readln;'#13#10 +
    'end.'#13#10;

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
  SetupControls;
  EnsureSampleProject;
  // Open the bundled sample by default and analyze it immediately so the
  // Semantics tab is populated on launch.
  OpenProject(TPath.Combine(TPath.Combine(ExeDir, 'Sample'), 'Sample.dpr'));
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
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
  try
    Result.Lines.LoadFromFile(APath);
  except
    on E: Exception do
      Result.Text := '{ could not load: ' + E.Message + ' }';
  end;
  LTab.Editor := Result;
  LTab.PasTreeHL := LHL;
  FOpenFiles.AddObject(APath, LTab);
  pgc.ActivePage := LTab;
end;

procedure TfrmMain.RunParse;
var
  LProj: TPasSemaProject;
  LPlatform: TPasPlatform;
  LMain, LDiagTotal, LId, LDIdx: Integer;
  LModel: TPasSemaModel;
  LSearchPaths, LDefines: TArray<string>;
begin
  if (FProjectDir = '') or not TDirectory.Exists(FProjectDir) then
  begin
    Log('No project open.');
    Exit;
  end;
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

  mmMessages.Clear;
  Log('Analyzing ' + FProjectDir + ' (' + PlatformName(LPlatform) + ')...');
  Screen.Cursor := crHourGlass;
  try
    LProj := TPasSemaProject.Create(LPlatform, LSearchPaths, LDefines);
    try
      // A .dproj drives the real uses-graph from its main source (correctly
      // reaching units outside FProjectDir); a plain .dpr falls back to
      // "everything under this folder" for simplicity.
      if Assigned(FDProj) and (FMainSource <> '') then
        LProj.AnalyzeFile(FMainSource)
      else
        LProj.AnalyzeDirectory(FProjectDir);

      // Locate the main unit's model, and report every unit's diagnostics.
      LMain := -1;
      LDiagTotal := 0;
      for LId := 0 to LProj.ModelCount - 1 do
      begin
        LModel := LProj.Model(LId);
        if SameText(LProj.ModelFile(LId), FMainSource) then
          LMain := LId;
        for LDIdx := 0 to High(LModel.Diags) do
        begin
          Inc(LDiagTotal);
          Log(Format('%s(%d,%d): %s',
            [TPath.GetFileName(LProj.ModelFile(LId)),
             LModel.Diags[LDIdx].Line, LModel.Diags[LDIdx].Col,
             LModel.Diags[LDIdx].Msg]));
        end;
      end;
      Log(Format('Done: %d units, %d diagnostics.',
        [LProj.ModelCount, LDiagTotal]));

      if LMain >= 0 then
      begin
        LModel := LProj.Model(LMain);
        edJson.Text := PrettyJson(AstToJson(LModel.Tree));
        edSema.Text := DumpSemaModel(LModel);
        pgc.ActivePage := tsSema;
      end
      else
        Log('Main source not found among analyzed units: ' + FMainSource);
    finally
      LProj.Free;
    end;
  finally
    Screen.Cursor := crDefault;
  end;
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
