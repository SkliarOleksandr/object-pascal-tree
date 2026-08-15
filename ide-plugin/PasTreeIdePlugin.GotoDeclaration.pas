unit PasTreeIdePlugin.GotoDeclaration;

{
  Ctrl+Click "Go to Declaration" override, backed by PasTree instead of RAD
  Studio's own DelphiLSP-based navigation (reported to work poorly on large
  projects - the whole reason for this unit).

  Mechanism: INTACodeEditorServices.AddEditorEventsNotifier with a
  TNTACodeEditorNotifier subclass (ToolsAPI.Editor.pas), hooked on
  OnEditorMouseDownEx/OnEditorMouseUpEx - both carry a `var Handled: Boolean`
  documented as "Set to True to mark the event as handled and prevent
  further processing" (ToolsAPI.Editor.pas:804-806, on the 370 notifier
  interface). Same technique RAD Studio's own official "KeyboardMouse
  Events Demo" sample uses (Samples\...\Editor Demos\KeyboardMouse Events
  Demo) - just for navigation instead of a status readout.

  Split across the two events:
    - MouseDown with Ctrl+Left: only sets Handled := True (suppress
      whatever default down-side processing exists, e.g. starting a text
      selection) - no navigation here.
    - MouseUp with Ctrl+Left: sets Handled := True AND does the actual
      resolve+navigate, via PasTreeIdePlugin.Analysis.BuildNavigator (the
      same pipeline PasTreeIdePlugin.FindReferences uses) + TPasNavigator's
      SymbolAt/UnitAt (+ DeclHit/UnitDeclHit for the declaration site).
      BuiltinNameAt is deliberately NOT handled here - a compiler builtin
      has no source declaration anywhere, so there is nothing to navigate
      to; native behavior is still suppressed (Handled stays True) rather
      than falling back to the slow/broken native path, but nothing happens
      instead of an error.

  CONFIRMED WORKING (2026-08-15): this override does intercept RAD Studio's
  native Ctrl+Click declaration navigation via this TCodeEditorEvents mouse
  chain - not just a documented-but-untested claim anymore.

  Failures here are deliberately quiet (logged, not shown as a dialog): this
  fires on every Ctrl+Click, far more often than the Find References menu
  item, so a modal popup on every miss would be much more disruptive than
  useful. See LogDiagnostic.
}

interface

uses
  ToolsAPI;

/// <summary>
/// Registers the Ctrl+Click override for the lifetime of the package. Call
/// once (from PasTreeIdePlugin.Wizard's TIDEWizard.Create).
/// </summary>
procedure InitializeGotoDeclaration;

/// <summary>
/// Unregisters the override. Call once (from TIDEWizard.Destroy) - must be
/// called before the package unloads, same reason the editor local menu's
/// action list must be unregistered (see PasTreeIdePlugin.Wizard).
/// </summary>
procedure FinalizeGotoDeclaration;

/// <summary>
/// Entry point for the "Find Declaration (PasTree)" editor menu item
/// (PasTreeIdePlugin.Wizard - the replacement for RAD Studio's native "Find
/// Declaration") - runs the exact same resolve+navigate logic as the
/// Ctrl+Click override, from the cursor position, but through an explicit
/// menu click.
/// </summary>
procedure ExecuteGotoDeclaration(const AView: IOTAEditView);

implementation

uses
  System.SysUtils, System.Types, System.Classes, System.UITypes, Vcl.Controls,
  ToolsAPI.Editor,
  PasTree.Sema.Project, PasTree.Sema.Nav, PasTreeIdePlugin.Analysis;

type
  // AllowedEvents can only be customized by overriding it - there is no
  // event property for it on TNTACodeEditorNotifier, unlike the mouse/
  // keyboard callbacks below (see the official KeyboardMouse Events Demo,
  // which does the same subclassing for the same reason).
  TGotoDeclarationNotifier = class(TNTACodeEditorNotifier)
  protected
    function AllowedEvents: TCodeEditorEvents; override;
  end;

function TGotoDeclarationNotifier.AllowedEvents: TCodeEditorEvents;
begin
  Result := [cevMouseEvents];
end;

/// <summary>
/// Goes to the IDE's own default Messages tab (nil group = the "Build" tab)
/// rather than a dedicated tab of our own, tagged "[pastree]" to stay
/// identifiable alongside compiler/linker noise - same convention as
/// PasTreeIdePlugin.FindReferences's own LogDiagnostic. Deliberately no
/// ShowMessageView: this fires on every Ctrl+Click, so forcing the Messages
/// panel open on a miss would be far more disruptive than the miss itself.
/// </summary>
procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

type
  TGotoDeclarationManager = class
  private
    FEditorServices: INTACodeEditorServices;
    FNotifier: TGotoDeclarationNotifier;
    FNotifierIndex: Integer;
    function TryGetPosition(const Editor: TWinControl; X, Y: Integer;
      out AView: IOTAEditView; out ARow, ACol: Integer): Boolean;
    procedure DoMouseDown(const Editor: TWinControl; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer; var Handled: Boolean);
    procedure DoMouseUp(const Editor: TWinControl; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer; var Handled: Boolean);
  public
    constructor Create;
    destructor Destroy; override;
  end;

var
  GManager: TGotoDeclarationManager;

function TGotoDeclarationManager.TryGetPosition(const Editor: TWinControl; X, Y: Integer;
  out AView: IOTAEditView; out ARow, ACol: Integer): Boolean;
var
  LState: INTACodeEditorState;
  LLineState: INTACodeEditorLineState;
  LColumn, LVisibleLine: Integer;
begin
  Result := False;
  AView := FEditorServices.GetViewForEditor(Editor);
  if not Assigned(AView) then
    Exit;

  LState := FEditorServices.EditorState[Editor];
  if not Assigned(LState) then
    Exit;
  if not LState.PointToCharacterPos(Point(X, Y), LColumn, LVisibleLine) then
    Exit;

  // LVisibleLine is a screen-visible line index, which can differ from the
  // file's own line numbering under code folding (elided sections). Convert
  // through LineState to get the LogicalLineNum PasTree's row numbers
  // actually correspond to.
  LLineState := LState.LineState[LVisibleLine];
  if not Assigned(LLineState) then
    Exit;

  ARow := LLineState.LogicalLineNum;
  ACol := LColumn;
  Result := True;
end;

/// <summary>
/// Standalone (not tied to the mouse-notifier instance) so both the
/// Ctrl+Click path (DoMouseUp) and the explicit menu item
/// (ExecuteGotoDeclaration) share the exact same logic and logging.
/// </summary>
procedure NavigateToHit(const AHit: TPasRefHit);
var
  LModuleServices: IOTAModuleServices;
  LModule: IOTAModule;
  LSourceEditor: IOTASourceEditor;
  LView: IOTAEditView;
begin
  if not Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
    Exit;
  LModule := LModuleServices.OpenModule(AHit.FilePath);
  if not Assigned(LModule) then
    Exit;
  if not Supports(LModule.GetModuleFileEditor(0), IOTASourceEditor, LSourceEditor) then
    Exit;
  if LSourceEditor.EditViewCount = 0 then
    Exit;

  LView := LSourceEditor.EditViews[0];
  LView.Position.GotoLine(AHit.Line);
  LView.Position.Move(AHit.Line, AHit.Col);
  LView.MoveViewToCursor;
  LModule.Show;
end;

/// <summary>
/// The actual resolve+navigate logic, shared by the Ctrl+Click override
/// (DoMouseUp) and the "Find Declaration (PasTree)" menu item
/// (ExecuteGotoDeclaration) - see this unit's header for why both exist.
/// Only logs on failure (LogDiagnostic/[pastree]) - this fires on every
/// Ctrl+Click, so logging every successful step would be far noisier than
/// useful; a miss is still always visible and says where it happened.
/// </summary>
procedure ResolveAndNavigate(const AFileName: string; ARow, ACol: Integer);
var
  LProject: IOTAProject;
  LMainFile: string;
  LSema: TPasSemaProject;
  LNav: TPasNavigator;
  LMid, LTMid, LSym, LTargetMid: Integer;
  LName: string;
  LHit: TPasRefHit;
  LFound: Boolean;
begin
  try
    LProject := GetActiveProject;
    if not Assigned(LProject) then
    begin
      LogDiagnostic('Goto Declaration: no active project.');
      Exit;
    end;

    LNav := BuildNavigator(LProject, LSema, LMainFile);
    try
      LMid := LNav.ModelIdOf(AFileName);
      if LMid < 0 then
      begin
        LogDiagnostic(Format('Goto Declaration: "%s" was not part of '
          + 'the analyzed project.', [AFileName]));
        Exit;
      end;

      LFound := False;
      if LNav.SymbolAt(LMid, ARow, ACol, LTMid, LSym, LName) then
        LFound := LNav.DeclHit(LTMid, LSym, LHit)
      else if LNav.UnitAt(LMid, ARow, ACol, LTargetMid, LName) then
        LFound := LNav.UnitDeclHit(LTargetMid, LHit);
      // BuiltinNameAt: no source declaration exists anywhere for a
      // compiler builtin - correctly nothing to navigate to.

      if LFound then
        NavigateToHit(LHit)
      else
        LogDiagnostic('Goto Declaration: no identifier/declaration resolved at cursor.');
    finally
      LNav.Free;
      LSema.Free;
    end;
  except
    on E: Exception do
      LogDiagnostic(Format('Goto Declaration: unhandled %s: %s', [E.ClassName, E.Message]));
  end;
end;

procedure ExecuteGotoDeclaration(const AView: IOTAEditView);
begin
  if not Assigned(AView) then
    Exit;
  ResolveAndNavigate(AView.Buffer.FileName, AView.Buffer.EditPosition.Row,
    AView.Buffer.EditPosition.Column);
end;

procedure TGotoDeclarationManager.DoMouseDown(const Editor: TWinControl;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer; var Handled: Boolean);
begin
  // Suppress default down-side handling only (e.g. starting a text
  // selection drag) - the actual navigation happens on mouse-up, below.
  if (ssCtrl in Shift) and (Button = mbLeft) then
    Handled := True;
end;

procedure TGotoDeclarationManager.DoMouseUp(const Editor: TWinControl;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer; var Handled: Boolean);
var
  LView: IOTAEditView;
  LRow, LCol: Integer;
begin
  if not ((ssCtrl in Shift) and (Button = mbLeft)) then
    Exit;

  // Always suppress the native handler for Ctrl+Left-click, even if we end
  // up resolving nothing below - the whole point is to stop the slow/broken
  // LSP-based one from running, not to fall back to it on a miss.
  Handled := True;

  if not TryGetPosition(Editor, X, Y, LView, LRow, LCol) then
  begin
    LogDiagnostic('Goto Declaration: could not resolve click position to a file/row/col.');
    Exit;
  end;

  ResolveAndNavigate(LView.Buffer.FileName, LRow, LCol);
end;

constructor TGotoDeclarationManager.Create;
begin
  inherited;
  FNotifierIndex := -1;
  if not Supports(BorlandIDEServices, INTACodeEditorServices, FEditorServices) then
    Exit;
  FNotifier := TGotoDeclarationNotifier.Create;
  FNotifier.OnEditorMouseDownEx := DoMouseDown;
  FNotifier.OnEditorMouseUpEx := DoMouseUp;
  FNotifierIndex := FEditorServices.AddEditorEventsNotifier(FNotifier);
end;

destructor TGotoDeclarationManager.Destroy;
begin
  if Assigned(FEditorServices) and (FNotifierIndex >= 0) then
    FEditorServices.RemoveEditorEventsNotifier(FNotifierIndex);
  inherited;
end;

procedure InitializeGotoDeclaration;
begin
  if not Assigned(GManager) then
    GManager := TGotoDeclarationManager.Create;
end;

procedure FinalizeGotoDeclaration;
begin
  FreeAndNil(GManager);
end;

end.
