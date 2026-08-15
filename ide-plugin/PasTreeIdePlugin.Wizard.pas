unit PasTreeIdePlugin.Wizard;

{
  Replaces the native "Find Declaration" menu item (Identifier category,
  first in the editor's right-click menu) with our own PasTree-backed one,
  and adds "Find References (PasTree)" right alongside it in that same
  category; plus the Ctrl+Click "Go to Declaration" override (see
  PasTreeIdePlugin.GotoDeclaration).

  The replacement works via INTAEditorLocalMenu.UnregisterActionList
  (cEdMenuCatIdentifier) - removing whatever action list the IDE itself
  registered under that category - followed by RegisterActionList of our
  own TActionList under that SAME category string, so both of our entries
  land in that exact (first) menu position. CAVEAT: this is a one-way door
  within a running IDE session - we have no handle to the native action
  list to restore it, so if this package is ever uninstalled without an IDE
  restart, "Find Declaration" would be gone until the IDE restarts (which
  the project's own workflow already does after every rebuild anyway - see
  project memory on package hot-reload).

  Modelled on the official samples shipped with RAD Studio:
    Samples\Object Pascal\ToolsAPI\Editor Demos\Editor Local Menu Demo
    Samples\Object Pascal\ToolsAPI\Editor Demos\Editor Raw Read Demo
    Samples\Object Pascal\ToolsAPI\Editor Demos\KeyboardMouse Events Demo
}

interface

procedure Register;

implementation

uses
  System.SysUtils, Vcl.ActnList, Vcl.Dialogs, Vcl.Forms, ToolsAPI, ToolsAPI.UI,
  PasTreeIdePlugin.FindReferences, PasTreeIdePlugin.GotoDeclaration,
  PasTreeIdePlugin.Analysis;

const
  cMenuCategory = 'PasTreeIdePluginMenuCategory';

type
  TMenuManager = class
  private
    FActionList: TActionList;
    FEditorServices: IOTAEditorServices;
    FRegistered: Boolean;
    procedure AddActions;
    procedure OnFindDeclarationExecute(Sender: TObject);
    procedure OnFindDeclarationUpdate(Sender: TObject);
    procedure OnFindReferencesExecute(Sender: TObject);
    procedure OnFindReferencesUpdate(Sender: TObject);
  public
    constructor Create;
    destructor Destroy; override;
  end;

  TIDEWizard = class(TNotifierObject, IOTAWizard)
  private
    FMenuManager: TMenuManager;
  public
    constructor Create;
    destructor Destroy; override;
    function GetIDString: string;
    procedure Execute;
    function GetName: string;
    function GetState: TWizardState;
  end;

procedure Register;
begin
  RegisterPackageWizard(TIDEWizard.Create);
end;

{ TMenuManager }

procedure TMenuManager.AddActions;
var
  LAction: TAction;
begin
  // Replaces the native "Find Declaration" - see unit header for the
  // mechanism and its one-way-door caveat.
  LAction := TAction.Create(FActionList);
  LAction.Name := 'PasTreeFindDeclaration';
  LAction.Caption := 'Find Declaration (PasTree)';
  LAction.Category := 'PasTreeFindDeclaration';
  LAction.OnUpdate := OnFindDeclarationUpdate;
  LAction.OnExecute := OnFindDeclarationExecute;
  LAction.Enabled := True;
  LAction.ActionList := FActionList;

  LAction := TAction.Create(FActionList);
  LAction.Name := 'PasTreeFindReferences';
  LAction.Caption := 'Find References (PasTree)';
  LAction.Category := 'PasTreeFindReferences';
  LAction.OnUpdate := OnFindReferencesUpdate;
  LAction.OnExecute := OnFindReferencesExecute;
  LAction.Enabled := True;
  LAction.ActionList := FActionList;
end;

constructor TMenuManager.Create;
begin
  inherited;
  FActionList := TActionList.Create(nil);

  if Supports(BorlandIDEServices, IOTAEditorServices, FEditorServices) then
  begin
    var LLocalMenuIntf := FEditorServices.GetEditorLocalMenu;
    // Remove the native "Find Declaration" action list and take over its
    // category slot with our own (see unit header for the caveat).
    LLocalMenuIntf.UnregisterActionList(cEdMenuCatIdentifier);
    LLocalMenuIntf.RegisterActionList(FActionList, cEdMenuCatIdentifier);
    FRegistered := True;
    AddActions;
  end
  else
    FRegistered := False;
end;

destructor TMenuManager.Destroy;
var
  LEditorServices: IOTAEditorServices;
begin
  // Must unregister before the package unloads, otherwise the IDE throws when
  // it next tries to build the local menu and calls our (freed) OnUpdate.
  if FRegistered then
  begin
    if Supports(BorlandIDEServices, IOTAEditorServices, LEditorServices) then
    begin
      var LLocalMenuIntf := LEditorServices.GetEditorLocalMenu;
      LLocalMenuIntf.UnregisterActionList(cEdMenuCatIdentifier);
    end;
  end;
  FreeAndNil(FActionList);
  inherited;
end;

procedure TMenuManager.OnFindDeclarationUpdate(Sender: TObject);
begin
  TAction(Sender).Enabled := FEditorServices.TopView <> nil;
end;

procedure TMenuManager.OnFindDeclarationExecute(Sender: TObject);
begin
  ExecuteGotoDeclaration(FEditorServices.TopView);
end;

procedure TMenuManager.OnFindReferencesUpdate(Sender: TObject);
begin
  TAction(Sender).Enabled := FEditorServices.TopView <> nil;
end;

procedure TMenuManager.OnFindReferencesExecute(Sender: TObject);
begin
  ExecuteFindReferences(FEditorServices.TopView);
end;

{ TIDEWizard }

constructor TIDEWizard.Create;
begin
  FMenuManager := TMenuManager.Create;
  InitializeGotoDeclaration;
end;

destructor TIDEWizard.Destroy;
begin
  FinalizeGotoDeclaration;
  FinalizeFindReferencesMessageGroup;
  FinalizeAnalysisCache;
  FreeAndNil(FMenuManager);
  inherited;
end;

procedure TIDEWizard.Execute;
begin
end;

function TIDEWizard.GetIDString: string;
begin
  Result := '[9E6C7B9A-6F1D-4C3E-9A2A-5B7B7C6E9C10]';
end;

function TIDEWizard.GetName: string;
begin
  Result := 'PasTreeIdePlugin.Wizard';
end;

function TIDEWizard.GetState: TWizardState;
begin
  Result := [wsEnabled];
end;

end.
