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

  Backward/Forward history (2026-08-15): a successful jump registers with
  IOTAHistoryServices (PushHistoryAndNavigate/TPasHistoryItem), the same
  global stack the IDE's own Alt+Left/Alt+Right toolbar buttons use - so
  they work across our jumps too, not just the native ones. Every
  TPasHistoryItem we hand to the IDE is tracked (GHistoryItems) and removed
  via RemoveHistoryItem at package unload (ClearHistoryItems, called from
  FinalizeGotoDeclaration) - left registered, a stale entry would call
  .Execute on an object living in unloaded package code the next time the
  user pressed Alt-Left/Right, exactly the class of AV this project has
  already hit more than once with package hot-reload.
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
  System.SysUtils, System.Types, System.Classes, System.UITypes,
  System.Generics.Collections, Vcl.Controls, ToolsAPI.Editor,
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
/// Standalone (not tied to the mouse-notifier instance) so the Ctrl+Click
/// path, the explicit menu item, and TPasHistoryItem.Execute (below - what
/// actually runs when the user presses Alt+Left/Alt+Right through the
/// history stack) all share the exact same logic and logging. Takes a
/// plain file/row/col rather than a TPasRefHit so a history item (which
/// only ever stores/replays a position, never re-resolves anything) can
/// call it without depending on PasTree.Sema.Nav.
/// </summary>
procedure NavigateToPosition(const AFileName: string; ARow, ACol: Integer);
var
  LModuleServices: IOTAModuleServices;
  LModule: IOTAModule;
  LSourceEditor: IOTASourceEditor;
  LView: IOTAEditView;
begin
  if not Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
  begin
    LogDiagnostic('Goto Declaration: IOTAModuleServices unavailable.');
    Exit;
  end;
  LModule := LModuleServices.OpenModule(AFileName);
  if not Assigned(LModule) then
  begin
    LogDiagnostic(Format('Goto Declaration: OpenModule("%s") returned nil.', [AFileName]));
    Exit;
  end;

  // OpenModule loads the module but doesn't itself create a visible editor
  // view for a file that wasn't already open - EditViewCount is 0 right
  // after OpenModule alone. Show creates/reveals the default editor (and
  // its view) for the module; only after that does EditViews[0] exist.
  LModule.Show;

  if not Supports(LModule.GetModuleFileEditor(0), IOTASourceEditor, LSourceEditor) then
  begin
    LogDiagnostic(Format('Goto Declaration: "%s" has no IOTASourceEditor at file index 0.',
      [AFileName]));
    Exit;
  end;
  if LSourceEditor.EditViewCount = 0 then
  begin
    LogDiagnostic(Format('Goto Declaration: "%s" has no edit views even after Show.',
      [AFileName]));
    Exit;
  end;

  LView := LSourceEditor.EditViews[0];
  LView.Position.GotoLine(ARow);
  LView.Position.Move(ARow, ACol);
  LView.MoveViewToCursor;
end;

type
  /// <summary>
  /// Narrow interface TPasHistoryItem also implements, purely so IsEqual can
  /// compare two history items' positions without an unsafe cast back to a
  /// concrete class through an interface reference - Supports(Item,
  /// IPasHistoryPosition, ...) is the correct way to ask "is this one of
  /// ours, and if so, what position does it hold", and correctly returns
  /// False (not equal) for the IDE's own or another plugin's history items.
  /// </summary>
  IPasHistoryPosition = interface
    ['{5C1E5F5D-8B7A-4B7E-9C6C-4B8E1A2F9D01}']
    function GetFileName: string;
    function GetRow: Integer;
    function GetCol: Integer;
  end;

  /// <summary>
  /// One entry in the IDE's global Backward/Forward navigation stack
  /// (IOTAHistoryServices) - what makes Alt+Left/Alt+Right return to (and
  /// back out of) a Go to Declaration jump, the same way they already do
  /// for the IDE's own native navigation. Execute just replays the stored
  /// position via NavigateToPosition; nothing is re-resolved through
  /// PasTree - a history entry is a plain (file, row, col) fact.
  /// </summary>
  TPasHistoryItem = class(TNotifierObject, IOTAHistoryItem, IPasHistoryPosition)
  private
    FFileName: string;
    FRow, FCol: Integer;
  public
    constructor Create(const AFileName: string; ARow, ACol: Integer);
    { IOTAHistoryItem }
    procedure Execute;
    function GetItemCaption: string;
    function IsEqual(const Item: IOTAHistoryItem): Boolean;
    { IPasHistoryPosition }
    function GetFileName: string;
    function GetRow: Integer;
    function GetCol: Integer;
  end;

constructor TPasHistoryItem.Create(const AFileName: string; ARow, ACol: Integer);
begin
  inherited Create;
  FFileName := AFileName;
  FRow := ARow;
  FCol := ACol;
end;

procedure TPasHistoryItem.Execute;
begin
  NavigateToPosition(FFileName, FRow, FCol);
end;

function TPasHistoryItem.GetItemCaption: string;
begin
  Result := Format('%s (%d)', [ExtractFileName(FFileName), FRow]);
end;

function TPasHistoryItem.IsEqual(const Item: IOTAHistoryItem): Boolean;
var
  LOther: IPasHistoryPosition;
begin
  Result := Supports(Item, IPasHistoryPosition, LOther)
    and SameText(LOther.GetFileName, FFileName)
    and (LOther.GetRow = FRow)
    and (LOther.GetCol = FCol);
end;

function TPasHistoryItem.GetFileName: string;
begin
  Result := FFileName;
end;

function TPasHistoryItem.GetRow: Integer;
begin
  Result := FRow;
end;

function TPasHistoryItem.GetCol: Integer;
begin
  Result := FCol;
end;

var
  // Every TPasHistoryItem we've ever handed to IOTAHistoryServices - tracked
  // so ClearHistoryItems can remove them all at package unload. Left
  // registered, they'd be exactly the kind of dangling-object AV this
  // project has already hit more than once (see project memory on
  // package-hot-reload): pressing Alt-Left/Right after an unload would call
  // .Execute on an instance living in unloaded package code.
  GHistoryItems: TList<IOTAHistoryItem>;

procedure TrackHistoryItem(const AItem: IOTAHistoryItem);
begin
  if not Assigned(GHistoryItems) then
    GHistoryItems := TList<IOTAHistoryItem>.Create;
  GHistoryItems.Add(AItem);
end;

procedure ClearHistoryItems;
var
  LHistoryServices: IOTAHistoryServices;
  LItem: IOTAHistoryItem;
begin
  if not Assigned(GHistoryItems) then
    Exit;
  if Supports(BorlandIDEServices, IOTAHistoryServices, LHistoryServices) then
    for LItem in GHistoryItems do
      LHistoryServices.RemoveHistoryItem(LItem);
  FreeAndNil(GHistoryItems);
end;

/// <summary>
/// Registers the jump with the IDE's Backward/Forward history (so
/// Alt+Left/Alt+Right work across it, same as the IDE's own navigation),
/// then performs it via IOTAHistoryServices.Execute - which both sets the
/// stack pointer to the new position AND calls NewItem.Execute for us, so
/// this does not also call NavigateToPosition itself. Falls back to a
/// direct NavigateToPosition call only if the history service is
/// unavailable (defensive - it's a core IDE service, expected to always be
/// there).
/// </summary>
procedure PushHistoryAndNavigate(const AFromFile: string; AFromRow, AFromCol: Integer;
  const AToFile: string; AToRow, AToCol: Integer);
var
  LHistoryServices: IOTAHistoryServices;
  LCurItem, LNewItem: IOTAHistoryItem;
begin
  LCurItem := TPasHistoryItem.Create(AFromFile, AFromRow, AFromCol);
  LNewItem := TPasHistoryItem.Create(AToFile, AToRow, AToCol);
  if Supports(BorlandIDEServices, IOTAHistoryServices, LHistoryServices) then
  begin
    LHistoryServices.AddHistoryItem(LCurItem, LNewItem);
    TrackHistoryItem(LCurItem);
    TrackHistoryItem(LNewItem);
    LHistoryServices.Execute(LNewItem);
  end
  else
    NavigateToPosition(AToFile, AToRow, AToCol);
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

    // BuildNavigator's result is cache-owned (see PasTreeIdePlugin.Analysis
    // - "Caching") - do not free LNav/LSema, they outlive this call.
    LNav := BuildNavigator(LProject, LSema, LMainFile);

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
      PushHistoryAndNavigate(AFileName, ARow, ACol, LHit.FilePath, LHit.Line, LHit.Col)
    else
      LogDiagnostic('Goto Declaration: no identifier/declaration resolved at cursor.');
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
  ClearHistoryItems;
end;

end.
