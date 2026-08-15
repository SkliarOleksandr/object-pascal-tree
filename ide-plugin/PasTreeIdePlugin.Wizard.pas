unit PasTreeIdePlugin.Wizard;

{
  Registers a "Find References (PasTree)" entry in the editor's local
  (right-click) context menu, next to the IDE's own "Find References",
  under the Refactor category (cEdMenuCatRefactor).

  Modelled on the official samples shipped with RAD Studio:
    Samples\Object Pascal\ToolsAPI\Editor Demos\Editor Local Menu Demo
    Samples\Object Pascal\ToolsAPI\Editor Demos\Editor Raw Read Demo
}

interface

procedure Register;

implementation

uses
  System.SysUtils, Vcl.ActnList, Vcl.Dialogs, Vcl.Forms, ToolsAPI, ToolsAPI.UI,
  PasTreeIdePlugin.FindReferences;

const
  cMenuCategory = 'PasTreeIdePluginMenuCategory';

type
  TMenuManager = class
  private
    FActionList: TActionList;
    FEditorServices: IOTAEditorServices;
    FRegistered: Boolean;
    procedure AddActions;
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
    // Insert right after the IDE's own Refactor section (Find, Find References,
    // Find Local References, ...) so ours sits alongside the built-in one.
    LLocalMenuIntf.RegisterActionList(FActionList, cMenuCategory, cEdMenuCatRefactor);
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
      LLocalMenuIntf.UnregisterActionList(cMenuCategory);
    end;
  end;
  FreeAndNil(FActionList);
  inherited;
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
end;

destructor TIDEWizard.Destroy;
begin
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
