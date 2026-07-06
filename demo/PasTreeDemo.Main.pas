unit PasTreeDemo.Main;

{
  PasTree demo — a small VCL host that opens a Delphi project, parses it with
  PasTree, and shows the source (SynEdit tabs), the project files (VirtualTree)
  and the diagnostics + AST JSON. UI is built at runtime (no designer .dfm) so
  the third-party controls need no design-time package.
}

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Generics.Collections,
  System.JSON,
  Winapi.Windows, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls,
  Vcl.ExtCtrls, Vcl.Dialogs, Vcl.Graphics,
  SynEdit, SynEditHighlighter, SynHighlighterPas, SynHighlighterJSON,
  VirtualTrees, VirtualTrees.Types,
  PasTree.Platforms, PasTree.Preprocessor, PasTree.Ast, PasTree.Ast.Json,
  PasTree.Parser, PasTree.Project,
  PasTree.Sema.Diagnostics, PasTree.Sema.Model, PasTree.Sema.Builtins,
  PasTree.Sema.Types, PasTree.Sema.Resolver, PasTree.Sema.Project,
  PasTree.Sema.Dump;

type
  // VirtualTree node payload: an index into FFileList (unmanaged, so the tree
  // needs no per-node finalization).
  TPasNodeData = record
    Index: Integer;
  end;
  PPasNodeData = ^TPasNodeData;

  TfrmMain = class(TForm)
    procedure FormCreate(Sender: TObject);
  private
    FToolbar: TPanel;
    FOpenBtn: TButton;
    FParseBtn: TButton;
    FPlatformCombo: TComboBox;
    FTree: TVirtualStringTree;
    FLeftSplitter: TSplitter;
    FPages: TPageControl;
    FBottomSplitter: TSplitter;
    FMessages: TMemo;
    FJsonTab: TTabSheet;
    FJsonEdit: TSynEdit;
    FSemaTab: TTabSheet;
    FSemaEdit: TSynEdit;
    FFileList: TStringList;               // full paths shown in the tree
    FOpenFiles: TStringList;              // path -> TTabSheet (Objects)
    FProjectDir: string;
    FMainSource: string;
    FPlatform: TPasPlatform;
    procedure BuildUI;
    procedure EnsureSampleProject;
    function ExeDir: string;
    procedure OpenProject(const AProjectFile: string);
    procedure PopulateTree;
    function OpenFileTab(const APath: string): TSynEdit;
    procedure RunParse;
    procedure Log(const AText: string);
    // event handlers
    procedure OpenBtnClick(Sender: TObject);
    procedure ParseBtnClick(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure TreeGetText(Sender: TBaseVirtualTree; Node: PVirtualNode;
      Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);
    procedure TreeChange(Sender: TBaseVirtualTree; Node: PVirtualNode);
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.dfm}

type
  // A source tab that owns its editor (pattern borrowed from the DelphiAST
  // TestApp), so we can recover the editor from the tab without casts.
  TSourceTab = class(TTabSheet)
    Editor: TSynEdit;
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

// Re-indent the compact AST JSON for display (2 spaces, like the TestApp).
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
  BuildUI;
  EnsureSampleProject;
  // Open the bundled sample by default so there is always something to parse,
  // and analyze it immediately so the Semantics tab is populated on launch.
  OpenProject(TPath.Combine(TPath.Combine(ExeDir, 'Sample'), 'Sample.dpr'));
  RunParse;
end;

procedure TfrmMain.BuildUI;
begin
  Caption := 'PasTree Demo';
  KeyPreview := True;
  OnKeyDown := FormKeyDown;

  // --- toolbar (top) ---
  FToolbar := TPanel.Create(Self);
  FToolbar.Parent := Self;
  FToolbar.Align := alTop;
  FToolbar.Height := 40;
  FToolbar.BevelOuter := bvNone;

  FOpenBtn := TButton.Create(Self);
  FOpenBtn.Parent := FToolbar;
  FOpenBtn.SetBounds(8, 7, 120, 27);
  FOpenBtn.Caption := 'Open Project...';
  FOpenBtn.OnClick := OpenBtnClick;

  FParseBtn := TButton.Create(Self);
  FParseBtn.Parent := FToolbar;
  FParseBtn.SetBounds(136, 7, 120, 27);
  FParseBtn.Caption := 'Run Parse (F9)';
  FParseBtn.OnClick := ParseBtnClick;

  FPlatformCombo := TComboBox.Create(Self);
  FPlatformCombo.Parent := FToolbar;
  FPlatformCombo.SetBounds(300, 9, 100, 23);
  FPlatformCombo.Style := csDropDownList;
  FPlatformCombo.Items.Add('Win32');
  FPlatformCombo.Items.Add('Win64');
  FPlatformCombo.ItemIndex := 0;

  // --- messages (bottom) ---
  FMessages := TMemo.Create(Self);
  FMessages.Parent := Self;
  FMessages.Align := alBottom;
  FMessages.Height := 150;
  FMessages.ReadOnly := True;
  FMessages.ScrollBars := ssBoth;
  FMessages.WordWrap := False;
  FMessages.Font.Name := 'Consolas';
  FMessages.Font.Size := 9;

  FBottomSplitter := TSplitter.Create(Self);
  FBottomSplitter.Parent := Self;
  FBottomSplitter.Align := alBottom;
  FBottomSplitter.Height := 4;

  // --- project tree (left) ---
  FTree := TVirtualStringTree.Create(Self);
  FTree.Parent := Self;
  FTree.Align := alLeft;
  FTree.Width := 260;
  FTree.NodeDataSize := SizeOf(TPasNodeData);
  FTree.Header.Options := FTree.Header.Options - [hoVisible];
  FTree.TreeOptions.PaintOptions :=
    FTree.TreeOptions.PaintOptions - [toShowTreeLines, toShowRoot];
  FTree.OnGetText := TreeGetText;
  FTree.OnChange := TreeChange;

  FLeftSplitter := TSplitter.Create(Self);
  FLeftSplitter.Parent := Self;
  FLeftSplitter.Align := alLeft;
  FLeftSplitter.Width := 4;

  // --- editor tabs (center) ---
  FPages := TPageControl.Create(Self);
  FPages.Parent := Self;
  FPages.Align := alClient;

  // persistent AST JSON tab
  FJsonTab := TTabSheet.Create(FPages);
  FJsonTab.PageControl := FPages;
  FJsonTab.Caption := 'AST JSON';
  FJsonEdit := TSynEdit.Create(Self);
  FJsonEdit.Parent := FJsonTab;
  FJsonEdit.Align := alClient;
  FJsonEdit.ReadOnly := True;
  FJsonEdit.Gutter.ShowLineNumbers := True;
  FJsonEdit.Font.Name := 'Consolas';
  FJsonEdit.Highlighter := TSynJSONSyn.Create(Self);
  FJsonEdit.UseCodeFolding := True;

  // persistent semantic-model tab (scopes / symbols / refs / diagnostics)
  FSemaTab := TTabSheet.Create(FPages);
  FSemaTab.PageControl := FPages;
  FSemaTab.Caption := 'Semantics';
  FSemaEdit := TSynEdit.Create(Self);
  FSemaEdit.Parent := FSemaTab;
  FSemaEdit.Align := alClient;
  FSemaEdit.ReadOnly := True;
  FSemaEdit.Gutter.ShowLineNumbers := True;
  FSemaEdit.Font.Name := 'Consolas';
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
  FMessages.Lines.Add(AText);
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
  LExt := LowerCase(TPath.GetExtension(AProjectFile));
  FPlatform := pfWin32;
  if LExt = '.dproj' then
  begin
    if not TryReadDProj(AProjectFile, FPlatform, FMainSource) then
      FPlatform := pfWin32;
    FProjectDir := TPath.GetDirectoryName(AProjectFile);
    if (FMainSource <> '') and not TPath.IsPathRooted(FMainSource) then
      FMainSource := TPath.Combine(FProjectDir, FMainSource);
    if not TFile.Exists(FMainSource) then
      FMainSource := TPath.ChangeExtension(AProjectFile, '.dpr');
  end
  else
  begin
    FMainSource := AProjectFile;
    FProjectDir := TPath.GetDirectoryName(AProjectFile);
  end;

  case FPlatform of
    pfWin64: FPlatformCombo.ItemIndex := 1;
  else
    FPlatformCombo.ItemIndex := 0;
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
  FTree.Clear;
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
  FFileList.Sort;
  FTree.BeginUpdate;
  try
    for var LIndex := 0 to FFileList.Count - 1 do
    begin
      LNode := FTree.AddChild(nil);
      PPasNodeData(FTree.GetNodeData(LNode))^.Index := LIndex;
    end;
  finally
    FTree.EndUpdate;
  end;
end;

function TfrmMain.OpenFileTab(const APath: string): TSynEdit;
var
  LIdx: Integer;
  LTab: TSourceTab;
begin
  LIdx := FOpenFiles.IndexOf(APath);
  if LIdx >= 0 then
  begin
    LTab := TSourceTab(FOpenFiles.Objects[LIdx]);
    FPages.ActivePage := LTab;
    Exit(LTab.Editor);
  end;

  LTab := TSourceTab.Create(FPages);
  LTab.PageControl := FPages;
  LTab.Caption := TPath.GetFileName(APath);

  Result := TSynEdit.Create(LTab);
  Result.Parent := LTab;
  Result.Align := alClient;
  Result.Gutter.ShowLineNumbers := True;
  Result.Font.Name := 'Consolas';
  Result.Highlighter := TSynPasSyn.Create(Result);
  Result.UseCodeFolding := True;
  try
    Result.Lines.LoadFromFile(APath);
  except
    on E: Exception do
      Result.Text := '{ could not load: ' + E.Message + ' }';
  end;
  LTab.Editor := Result;
  FOpenFiles.AddObject(APath, LTab);
  FPages.ActivePage := LTab;
end;

procedure TfrmMain.RunParse;
var
  LProj: TPasSemaProject;
  LPlatform: TPasPlatform;
  LMain, LDiagTotal, LId, LDIdx: Integer;
  LModel: TPasSemaModel;
begin
  if (FProjectDir = '') or not TDirectory.Exists(FProjectDir) then
  begin
    Log('No project open.');
    Exit;
  end;
  if FPlatformCombo.ItemIndex = 1 then
    LPlatform := pfWin64
  else
    LPlatform := pfWin32;

  FMessages.Clear;
  Log('Analyzing ' + FProjectDir + ' (' + PlatformName(LPlatform) + ')...');
  Screen.Cursor := crHourGlass;
  try
    LProj := TPasSemaProject.Create(LPlatform, [FProjectDir], []);
    try
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
        FJsonEdit.Text := PrettyJson(AstToJson(LModel.Tree));
        FSemaEdit.Text := DumpSemaModel(LModel);
        FPages.ActivePage := FSemaTab;
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

procedure TfrmMain.OpenBtnClick(Sender: TObject);
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

procedure TfrmMain.ParseBtnClick(Sender: TObject);
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

procedure TfrmMain.TreeGetText(Sender: TBaseVirtualTree; Node: PVirtualNode;
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

procedure TfrmMain.TreeChange(Sender: TBaseVirtualTree; Node: PVirtualNode);
var
  LData: PPasNodeData;
begin
  if Node = nil then
    Exit;
  LData := PPasNodeData(Sender.GetNodeData(Node));
  if (LData <> nil) and (LData.Index >= 0) and (LData.Index < FFileList.Count) then
    OpenFileTab(FFileList[LData.Index]);
end;

end.
