unit PasTreeDemo.Settings;

{
  PasTree demo - persisted settings, in a plain .ini next to the executable.

  Everything the demo used to forget on every launch: the target platform, the
  highlighter and threading choices, the identifier-highlight colour, and the
  list of recently opened projects.

  A file rather than the registry, deliberately: it travels with the checkout,
  can be inspected and hand-edited, and a corrupt or missing one costs nothing
  - every getter takes a default. The registry is still read for the IDE's own
  library paths (that is the IDE's data, not ours).

  Layout:

      [Settings]
      Platform=1
      Highlighter=1
      Threading=1
      HighlightColor=16032864

      [Recent]
      Project0=C:\Repos\...\Some.dproj
      Project1=...

  Recent entries are most-recent-first, deduplicated by full path (case-
  insensitively, matching the filesystem), and capped - see RECENT_MAX.
}

interface

uses
  System.SysUtils, System.Classes, System.IniFiles;

const
  // Twenty still fits a drop-down without scrolling on any usable screen, and
  // covers more than the working week ten did - the list is the fastest way
  // back into a project that was open two days ago. The cap is applied on ADD,
  // so the file never grows unbounded whatever this is set to.
  RECENT_MAX = 20;

type
  TDemoSettings = class
  private
    FIni: TMemIniFile;
    FRecent: TStringList;
    procedure LoadRecent;
    procedure SaveRecent;
  public
    constructor Create(const AFileName: string);
    destructor Destroy; override;

    // Values, with the caller's default when the key is absent or unparsable.
    function ReadInt(const AName: string; ADefault: Integer): Integer;
    procedure WriteInt(const AName: string; AValue: Integer);
    function ReadString(const AName, ADefault: string): string;
    procedure WriteString(const AName, AValue: string);

    { Moves AProjectFile to the front, or inserts it there. Existence is NOT
      checked here: a project on a disconnected network share is still the last
      thing the user opened, and dropping it at save time would lose it for
      good. The display side does the pruning - see ExistingRecent. }
    procedure AddRecent(const AProjectFile: string);
    // Every remembered entry, most-recent-first, including missing files.
    function Recent: TArray<string>;
    { The subset that exists RIGHT NOW, for the menu. Checked per call rather
      than cached: a share can come back between two drops of the list. }
    function ExistingRecent: TArray<string>;

    procedure Save;
  end;

// The settings file for this executable: <exe dir>\PasTreeDemo.ini.
function DefaultSettingsFile: string;

implementation

uses
  System.IOUtils;

const
  SEC_SETTINGS = 'Settings';
  SEC_RECENT = 'Recent';
  KEY_PROJECT = 'Project';

function DefaultSettingsFile: string;
begin
  Result := TPath.ChangeExtension(ParamStr(0), '.ini');
end;

constructor TDemoSettings.Create(const AFileName: string);
begin
  inherited Create;
  // TMemIniFile reads once and writes once (UpdateFile), so nothing here
  // touches the disk between Create and Save - the recent list is rewritten on
  // every open, and a file write per click is not something to pay for.
  FIni := TMemIniFile.Create(AFileName, TEncoding.UTF8);
  FRecent := TStringList.Create;
  FRecent.CaseSensitive := False;
  LoadRecent;
end;

destructor TDemoSettings.Destroy;
begin
  FRecent.Free;
  FIni.Free;
  inherited;
end;

procedure TDemoSettings.LoadRecent;
var
  LIdx: Integer;
  LPath: string;
begin
  FRecent.Clear;
  // Read by INDEX, not by enumerating the section: the order IS the data here,
  // and ReadSection gives no guarantee about it.
  for LIdx := 0 to RECENT_MAX - 1 do
  begin
    LPath := FIni.ReadString(SEC_RECENT, KEY_PROJECT + IntToStr(LIdx), '');
    if (LPath <> '') and (FRecent.IndexOf(LPath) < 0) then
      FRecent.Add(LPath);
  end;
end;

procedure TDemoSettings.SaveRecent;
var
  LIdx: Integer;
begin
  // Erased first: shortening the list must not leave the old tail behind under
  // its own keys, where the next load would read it back.
  FIni.EraseSection(SEC_RECENT);
  for LIdx := 0 to FRecent.Count - 1 do
    FIni.WriteString(SEC_RECENT, KEY_PROJECT + IntToStr(LIdx), FRecent[LIdx]);
end;

function TDemoSettings.ReadInt(const AName: string; ADefault: Integer): Integer;
begin
  Result := FIni.ReadInteger(SEC_SETTINGS, AName, ADefault);
end;

procedure TDemoSettings.WriteInt(const AName: string; AValue: Integer);
begin
  FIni.WriteInteger(SEC_SETTINGS, AName, AValue);
end;

function TDemoSettings.ReadString(const AName, ADefault: string): string;
begin
  Result := FIni.ReadString(SEC_SETTINGS, AName, ADefault);
end;

procedure TDemoSettings.WriteString(const AName, AValue: string);
begin
  FIni.WriteString(SEC_SETTINGS, AName, AValue);
end;

procedure TDemoSettings.AddRecent(const AProjectFile: string);
var
  LFull: string;
  LIdx: Integer;
begin
  if AProjectFile = '' then
    Exit;
  // Normalized before comparing, so the same project reached through a
  // relative path or a different case is one entry, not two.
  LFull := TPath.GetFullPath(AProjectFile);
  LIdx := FRecent.IndexOf(LFull);   // CaseSensitive=False
  if LIdx >= 0 then
    FRecent.Delete(LIdx);
  FRecent.Insert(0, LFull);
  while FRecent.Count > RECENT_MAX do
    FRecent.Delete(FRecent.Count - 1);
end;

function TDemoSettings.Recent: TArray<string>;
begin
  Result := FRecent.ToStringArray;
end;

function TDemoSettings.ExistingRecent: TArray<string>;
var
  LPath: string;
begin
  Result := nil;
  for LPath in FRecent do
    if TFile.Exists(LPath) then
      Result := Result + [LPath];
end;

procedure TDemoSettings.Save;
begin
  SaveRecent;
  FIni.UpdateFile;
end;

end.
