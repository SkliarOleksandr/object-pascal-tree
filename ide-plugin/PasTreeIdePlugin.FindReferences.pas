unit PasTreeIdePlugin.FindReferences;

{
  Find References entry point, wired to the "Find References (PasTree)" editor
  menu item (see PasTreeIdePlugin.Wizard).

  Current state: scaffold only.
    - Identifier-under-cursor extraction works today, using plain ToolsAPI
      (IOTAEditPosition.MoveCursor / Read) as a first pass. This is a rough
      word-boundary heuristic, not real tokenization.
    - Project source collection (GatherProjectUnits) works today, reading
      every module in the active project through IOTASourceEditor.CreateReader.
    - The actual find-references search is NOT wired to PasTree yet: this
      unit does not depend on any PasTree.* unit. That is deliberate for this
      first scaffold, so the package compiles and the menu item / plumbing
      can be verified in the IDE before pulling in the analyzer.

  TODO (next session):
    1. Add the PasTree source path to this package's search path (or a
       dedicated designtime-safe subset of it) and add PasTree.Sema.Project /
       PasTree.Lexer to the uses clause.
    2. Replace the identifier heuristic below with a real PasTree lexer call,
       so the boundary matches what the analyzer actually tokenizes.
     3. Replace TODO in ExecuteFindReferences: build a PasTree project from
        the gathered unit texts, resolve the identifier at (UnitName, Row,
        Col), and enumerate its references - same identity logic as the demo's
        Find References (see local/ or demo/PasTreeDemo.Main.pas for how the
        demo does this today: symbol / unit / builtin identities).
    4. Feed results into ReportReferences below instead of the placeholder.
}

interface

uses
  ToolsAPI;

type
  TSourceLocation = record
    FileName: string;
    Row: Integer;
    Col: Integer;
  end;

  TUnitSource = record
    FileName: string;
    Text: string;
  end;

/// <summary>
/// Entry point called from the editor's local menu action.
/// </summary>
procedure ExecuteFindReferences(const AView: IOTAEditView);

/// <summary>
/// Best-effort identifier under the given view's cursor, using plain
/// ToolsAPI word-boundary skipping. Returns '' if the cursor is not on a
/// word character. This is a placeholder for real PasTree tokenization.
/// </summary>
function IdentifierUnderCursor(const AView: IOTAEditView; out ALocation: TSourceLocation): string;

/// <summary>
/// Reads every module belonging to AProject's active project through the
/// ToolsAPI source editor interfaces (so unsaved edits are included).
/// </summary>
function GatherProjectUnits(const AProject: IOTAProject): TArray<TUnitSource>;

implementation

uses
  System.SysUtils, System.Classes, System.Generics.Collections, Vcl.Dialogs, Vcl.Forms,
  ToolsAPI.UI, Winapi.ActiveX, IStreams;

function GetActiveProject: IOTAProject;
var
  LModuleServices: IOTAModuleServices;
  LGroup: IOTAProjectGroup;
begin
  Result := nil;
  if Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
  begin
    LGroup := LModuleServices.MainProjectGroup;
    if Assigned(LGroup) then
      Result := LGroup.ActiveProject;
  end;
end;

function ReadUnitText(const AModule: IOTAModuleInfo): string;
var
  LBuffer: IOTAEditBuffer;
  LEditorContent: IOTAEditorContent;
  LIStream: IStream;
  LIMemStream: TIMemoryStream;
  LMemStream: TMemoryStream;
  LFileContent: UTF8String;
begin
  // Deliberately using the same technique as RAD Studio's own official
  // "Editor Raw Read Demo" (StreamReadGetFileData): IOTAEditorContent.Content
  // gives direct access to the buffer's own memory stream. An earlier version
  // of this function used the legacy IOTAEditReader.GetText loop instead,
  // which triggered heap/stack corruption (an access violation showing up
  // much later, in unrelated IDE code, on the *next* menu click) - GetText's
  // Count-respecting behavior is apparently not safe to assume here. Do not
  // reintroduce IOTAEditReader for this without re-verifying against the
  // official samples first.
  Result := '';
  if not Supports(AModule.OpenModule.GetModuleFileEditor(0), IOTAEditBuffer, LBuffer) then
    Exit;

  LEditorContent := LBuffer as IOTAEditorContent;
  LIStream := LEditorContent.Content;
  LIMemStream := LIStream as TIMemoryStream;
  LMemStream := LIMemStream.MemoryStream;
  SetLength(LFileContent, LMemStream.Size);
  LMemStream.Position := 0;
  if LMemStream.Size <> 0 then
    LMemStream.Read(LFileContent[1], Length(LFileContent));
  Result := UTF8ToString(LFileContent);
end;

function IsPascalSourceModule(const AModule: IOTAModuleInfo): Boolean;
begin
  // IOTAModuleInfo.ModuleType also covers non-source entries - notably
  // omtPackageImport, which is what a *package* project's Requires section
  // (rtl, vcl, designide, ...) shows up as. Calling OpenModule on one of
  // those asks the IDE to open ITS project, which - since the rtl/vcl
  // sources ship on disk - the IDE resolves by trying to (re)build rtl.dcp
  // into Program Files\bin, and that write fails without elevation. Only
  // treat actual Pascal units as candidates; skip everything else (resources,
  // libs, type libraries, and especially package imports).
  case AModule.ModuleType of
    omtForm, omtDataModule, omtProjUnit, omtUnit:
      Result := SameText(ExtractFileExt(AModule.FileName), '.pas');
  else
    Result := False;
  end;
end;

procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage(AMessage);
end;

function GatherProjectUnits(const AProject: IOTAProject): TArray<TUnitSource>;
var
  I: Integer;
  LModule: IOTAModuleInfo;
  LUnits: TList<TUnitSource>;
begin
  SetLength(Result, 0);
  if not Assigned(AProject) then
    Exit;

  LUnits := TList<TUnitSource>.Create;
  try
    for I := 0 to AProject.GetModuleCount - 1 do
    begin
      LModule := AProject.GetModule(I);
      if not Assigned(LModule) then
        Continue;
      if not IsPascalSourceModule(LModule) then
        Continue;
      try
        var LUnit: TUnitSource;
        LUnit.FileName := LModule.FileName;
        LUnit.Text := ReadUnitText(LModule);
        LUnits.Add(LUnit);
      except
        on E: Exception do
          // Scaffold diagnostics: identify exactly which module/operation is
          // failing instead of guessing. Remove once the real cause is fixed.
          LogDiagnostic(Format('PasTree Find References: failed on module #%d '
            + '(ModuleType=%d, Name=%s, FileName=%s): %s: %s',
            [I, LModule.ModuleType, LModule.Name, LModule.FileName, E.ClassName, E.Message]));
      end;
    end;
    Result := LUnits.ToArray;
  finally
    LUnits.Free;
  end;
end;

function IdentifierUnderCursor(const AView: IOTAEditView; out ALocation: TSourceLocation): string;
var
  LPos: IOTAEditPosition;
  LOriginalRow, LOriginalCol: Integer;
  LStartCol, LEndCol: Integer;
begin
  // Deliberately read-only: Move / IsWordCharacter / Read only navigate and
  // peek, they never mutate the buffer. An earlier version used RipText,
  // whose name ("rip" - read-and-delete in this legacy editor API family)
  // means it may well remove the matched characters from the source instead
  // of just returning them. Do not reintroduce RipText or MoveCursor masks
  // here without confirming their exact semantics against the official docs
  // first - getting this wrong silently corrupts the user's source file.
  Result := '';
  ALocation.FileName := '';
  ALocation.Row := 0;
  ALocation.Col := 0;
  if not Assigned(AView) then
    Exit;

  LPos := AView.Buffer.EditPosition;
  LOriginalRow := LPos.Row;
  LOriginalCol := LPos.Column;
  try
    LPos.Move(LOriginalRow, LOriginalCol);
    if not LPos.IsWordCharacter then
      Exit;

    // Walk left one column at a time while still on a word character.
    LStartCol := LOriginalCol;
    while LStartCol > 1 do
    begin
      LPos.Move(LOriginalRow, LStartCol - 1);
      if not LPos.IsWordCharacter then
        Break;
      Dec(LStartCol);
    end;

    // Walk right one column at a time while still on a word character.
    LEndCol := LOriginalCol;
    while True do
    begin
      LPos.Move(LOriginalRow, LEndCol);
      if not LPos.IsWordCharacter then
        Break;
      Inc(LEndCol);
    end;

    LPos.Move(LOriginalRow, LStartCol);
    Result := LPos.Read(LEndCol - LStartCol);
    ALocation.FileName := AView.Buffer.FileName;
    ALocation.Row := LOriginalRow;
    ALocation.Col := LStartCol;
  finally
    LPos.Move(LOriginalRow, LOriginalCol);
  end;
end;

const
  cMessageGroupName = 'PasTree References';
  cMessagePrefix = 'PasTree';

function GetOrCreateMessageGroup(const AMessageServices: IOTAMessageServices): IOTAMessageGroup;
begin
  Result := AMessageServices.GetGroup(cMessageGroupName);
  if not Assigned(Result) then
    Result := AMessageServices.AddMessageGroup(cMessageGroupName);
end;

/// <summary>
/// Reports every found reference as its own line in a dedicated "PasTree
/// References" tab in the Messages panel (distinct from the Build tab, and
/// reused across searches - each call clears it first). Each line carries a
/// file/line/column, so the IDE's own message-view navigation (double-click,
/// Enter, F8/Shift+F8 next/previous message) jumps straight to that location,
/// same as compiler errors or Find in Files results - no custom UI needed.
/// </summary>
procedure ReportReferences(const AIdentifier: string; const AReferences: TArray<TSourceLocation>);
var
  LMessageServices: IOTAMessageServices;
  LGroup: IOTAMessageGroup;
  LLineRef: Pointer;
  LRef: TSourceLocation;
begin
  if not Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    Exit;

  LGroup := GetOrCreateMessageGroup(LMessageServices);
  LMessageServices.ClearMessageGroup(LGroup);

  LMessageServices.AddTitleMessage(
    Format('PasTree Find References: "%s" - %d reference(s) found'
      + ' (search not wired up to PasTree yet - scaffold shows the definition site only)',
      [AIdentifier, Length(AReferences)]),
    LGroup);

  for LRef in AReferences do
    LMessageServices.AddToolMessage(LRef.FileName,
      Format('%s: "%s"', [cMessagePrefix, AIdentifier]),
      cMessagePrefix, LRef.Row, LRef.Col, nil, LLineRef, LGroup);

  LMessageServices.ShowMessageView(LGroup);
end;

procedure ExecuteFindReferences(const AView: IOTAEditView);
var
  LIdentifier: string;
  LLocation: TSourceLocation;
  LProject: IOTAProject;
  LUnits: TArray<TUnitSource>;
  LReferences: TArray<TSourceLocation>;
begin
  try
    LIdentifier := IdentifierUnderCursor(AView, LLocation);
    if LIdentifier = '' then
    begin
      (BorlandIDEServices as INTAIDEUIServices).MessageDlg(
        'No identifier under the cursor.', mtInformation, [mbOK], -1);
      Exit;
    end;

    LProject := GetActiveProject;
    LUnits := GatherProjectUnits(LProject);

    // TODO: hand LUnits + LIdentifier + LLocation to a PasTree-backed resolver
    // and report every real reference instead of this one-element placeholder
    // (currently just the definition site itself).
    LReferences := [LLocation];
    ReportReferences(LIdentifier, LReferences);
  except
    // Scaffold diagnostics: surface the real exception in the Messages panel
    // instead of letting an unhandled one pop the IDE's generic "Error"
    // dialog with no context. Remove once the pipeline is stable.
    on E: Exception do
      LogDiagnostic(Format('PasTree Find References: unhandled %s: %s', [E.ClassName, E.Message]));
  end;
end;

end.
