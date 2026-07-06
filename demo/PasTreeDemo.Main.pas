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
    pnlTop: TPanel;
    btnOpen: TButton;
    btnParse: TButton;
    cbPlatform: TComboBox;
    splLeft: TSplitter;
    vstFiles: TVirtualStringTree;
    pgc: TPageControl;
    tsJson: TTabSheet;
    edJson: TSynEdit;
    tsSema: TTabSheet;
    edSema: TSynEdit;
    splBottom: TSplitter;
    mmMessages: TMemo;
    procedure FormCreate(Sender: TObject);
    procedure btnOpenClick(Sender: TObject);
    procedure btnParseClick(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure vstFilesGetText(Sender: TBaseVirtualTree; Node: PVirtualNode;
      Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);
    procedure vstFilesChange(Sender: TBaseVirtualTree; Node: PVirtualNode);
  private
    FPasHL: TSynPasSyn;      // shared Pascal highlighter (source tabs)
    FJsonHL: TSynJSONSyn;    // JSON highlighter (AST JSON tab)
    FFileList: TStringList;  // full paths shown in the tree
    FOpenFiles: TStringList; // path -> TTabSheet (Objects)
    FProjectDir: string;
    FMainSource: string;
    FPlatform: TPasPlatform;
    procedure SetupControls;
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
  RunParse;
end;

// Runtime-only control configuration (things awkward to set in the designer:
// the VST node payload/options, highlighters and code fonts).
procedure TfrmMain.SetupControls;
begin
  vstFiles.NodeDataSize := SizeOf(TPasNodeData);
  vstFiles.Header.Options := vstFiles.Header.Options - [hoVisible];
  vstFiles.TreeOptions.PaintOptions :=
    vstFiles.TreeOptions.PaintOptions - [toShowTreeLines, toShowRoot];

  FPasHL := TSynPasSyn.Create(Self);
  FJsonHL := TSynJSONSyn.Create(Self);

  edJson.ReadOnly := True;
  edJson.Highlighter := FJsonHL;
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
  Result.Highlighter := FPasHL;
  Result.UseCodeFolding := True;
  try
    Result.Lines.LoadFromFile(APath);
  except
    on E: Exception do
      Result.Text := '{ could not load: ' + E.Message + ' }';
  end;
  LTab.Editor := Result;
  FOpenFiles.AddObject(APath, LTab);
  pgc.ActivePage := LTab;
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
  if cbPlatform.ItemIndex = 1 then
    LPlatform := pfWin64
  else
    LPlatform := pfWin32;

  mmMessages.Clear;
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

initialization
  // The .dfm streams these third-party controls; ensure the statically-linked
  // build (no design-time packages) can find their classes.
  RegisterClasses([TSynEdit, TVirtualStringTree]);

end.
