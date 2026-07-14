unit PasTree.SourceManager;

{
  PasTree — source file loading and include resolution.

  Loading is tolerant: BOMs are honored; files without a BOM that fail
  strict decoding fall back to a raw ANSI decode (token boundaries are what
  matter to the lexer; only string/comment payloads could mis-decode).
}

interface

uses
  System.SysUtils,
  System.Generics.Collections;

type
  TPasSourceManager = class
  private
    FSearchPaths: TArray<string>;
    FIncludeIndex: TDictionary<string, string>;  // basename -> full path
    FUnitIndex: TDictionary<string, string>;      // *.pas/*.dpr basename -> path
    FBuffers: TDictionary<string, string>;        // full path (lower) -> text
    function TryFile(const ADir, AName: string; out AResolved: string): Boolean;
  public
    constructor Create(const ASearchPaths: TArray<string>);
    destructor Destroy; override;
    { In-memory buffer overrides: LoadText returns the given text for APath
      instead of reading the file. Editor hosts push unsaved buffers here so
      analysis sees what's on screen (main file AND its $I includes go through
      LoadText). Keyed by full-path, case-insensitive. Set before analyzing. }
    procedure SetBuffer(const APath, AText: string);
    procedure ClearBuffers;
    function LoadText(const APath: string): string;
    { Indexes every *.inc under ARoot by basename as a last-resort include
      resolver (corpus runs without real project search paths). The first
      occurrence of an ambiguous name wins. }
    procedure BuildIncludeIndex(const ARoot: string);
    { Resolves an include argument (possibly quoted) against the directory
      of the including file, then the search paths, then the index. }
    function ResolveInclude(const AIncludingFile, AName: string;
      out AResolved: string): Boolean;
    { Indexes every *.pas/*.dpr under ARoot by basename, for unit-name
      resolution when there are no real search paths (project-dir fallback). }
    procedure BuildUnitIndex(const ARoot: string);
    { Resolves a unit name (e.g. 'System.SysUtils') to a .pas file: tries the
      explicit `in` path first, then <dotted>.pas and <leaf>.pas relative to
      the referring file, the search paths, and the unit index. }
    function ResolveUnit(const AUnitName, AInPath, AFromFile: string;
      out AResolved: string): Boolean;
  end;

implementation

uses
  System.Classes,
  System.IOUtils;

{ TPasSourceManager }

constructor TPasSourceManager.Create(const ASearchPaths: TArray<string>);
begin
  inherited Create;
  FSearchPaths := ASearchPaths;
end;

destructor TPasSourceManager.Destroy;
begin
  FBuffers.Free;
  FIncludeIndex.Free;
  FUnitIndex.Free;
  inherited;
end;

procedure TPasSourceManager.SetBuffer(const APath, AText: string);
begin
  if FBuffers = nil then
    FBuffers := TDictionary<string, string>.Create;
  FBuffers.AddOrSetValue(LowerCase(TPath.GetFullPath(APath)), AText);
end;

procedure TPasSourceManager.ClearBuffers;
begin
  FreeAndNil(FBuffers);
end;

function TPasSourceManager.TryFile(const ADir, AName: string;
  out AResolved: string): Boolean;
var
  LCandidate: string;
begin
  Result := False;
  if (ADir = '') or (AName = '') then
    Exit;
  LCandidate := TPath.Combine(ADir, AName);
  if TFile.Exists(LCandidate) then
  begin
    AResolved := TPath.GetFullPath(LCandidate);
    Result := True;
  end;
end;

procedure TPasSourceManager.BuildUnitIndex(const ARoot: string);
var
  LFile, LKey, LExt: string;
begin
  FreeAndNil(FUnitIndex);
  FUnitIndex := TDictionary<string, string>.Create;
  for LFile in TDirectory.GetFiles(ARoot, '*.*', TSearchOption.soAllDirectories) do
  begin
    LExt := LowerCase(TPath.GetExtension(LFile));
    if (LExt = '.pas') or (LExt = '.dpr') then
    begin
      LKey := LowerCase(TPath.GetFileName(LFile));
      if not FUnitIndex.ContainsKey(LKey) then
        FUnitIndex.Add(LKey, LFile);
    end;
  end;
end;

function TPasSourceManager.ResolveUnit(const AUnitName, AInPath, AFromFile: string;
  out AResolved: string): Boolean;
var
  LDir, LLeaf, LCand: string;
  LNames: TArray<string>;
  LName: string;
  LDot: Integer;
begin
  LDir := TPath.GetDirectoryName(AFromFile);

  // 1. Explicit `in 'path'`.
  if AInPath <> '' then
  begin
    if TPath.IsPathRooted(AInPath) and TFile.Exists(AInPath) then
    begin
      AResolved := TPath.GetFullPath(AInPath);
      Exit(True);
    end;
    if TryFile(LDir, AInPath, AResolved) then
      Exit(True);
    for LDir in FSearchPaths do
      if TryFile(LDir, AInPath, AResolved) then
        Exit(True);
    LDir := TPath.GetDirectoryName(AFromFile);
  end;

  // Candidate file names: <dotted>.pas then <leaf>.pas.
  LDot := LastDelimiter('.', AUnitName);
  if LDot > 0 then
    LLeaf := Copy(AUnitName, LDot + 1, MaxInt)
  else
    LLeaf := AUnitName;
  LNames := [AUnitName + '.pas'];
  if not SameText(LLeaf, AUnitName) then
    LNames := LNames + [LLeaf + '.pas'];

  // 2. Relative to the referring file, then search paths.
  for LName in LNames do
  begin
    if TryFile(LDir, LName, AResolved) then
      Exit(True);
    for LCand in FSearchPaths do
      if TryFile(LCand, LName, AResolved) then
        Exit(True);
  end;

  // 3. Unit index (basename fallback).
  if FUnitIndex <> nil then
    for LName in LNames do
      if FUnitIndex.TryGetValue(LowerCase(LName), LCand) then
      begin
        AResolved := LCand;
        Exit(True);
      end;

  Result := False;
end;

procedure TPasSourceManager.BuildIncludeIndex(const ARoot: string);
var
  LFile, LKey: string;
begin
  FreeAndNil(FIncludeIndex);
  FIncludeIndex := TDictionary<string, string>.Create;
  for LFile in TDirectory.GetFiles(ARoot, '*.inc',
    TSearchOption.soAllDirectories) do
  begin
    LKey := LowerCase(TPath.GetFileName(LFile));
    if not FIncludeIndex.ContainsKey(LKey) then
      FIncludeIndex.Add(LKey, LFile);
  end;
end;

function TPasSourceManager.LoadText(const APath: string): string;
var
  LBytes: TBytes;
begin
  if (FBuffers <> nil) and
     FBuffers.TryGetValue(LowerCase(TPath.GetFullPath(APath)), Result) then
    Exit;
  try
    Result := TFile.ReadAllText(APath);
  except
    on E: EEncodingError do
    begin
      LBytes := TFile.ReadAllBytes(APath);
      Result := TEncoding.ANSI.GetString(LBytes);
    end;
  end;
end;

function TPasSourceManager.ResolveInclude(const AIncludingFile, AName: string;
  out AResolved: string): Boolean;
var
  LName, LCandidate, LDir: string;
begin
  LName := Trim(AName);
  if (Length(LName) >= 2) and (LName[1] = '''') and
     (LName[Length(LName)] = '''') then
    LName := Copy(LName, 2, Length(LName) - 2);
  if LName = '' then
    Exit(False);

  // 1. Relative to the including file.
  LDir := TPath.GetDirectoryName(AIncludingFile);
  if LDir <> '' then
  begin
    LCandidate := TPath.Combine(LDir, LName);
    if TFile.Exists(LCandidate) then
    begin
      AResolved := TPath.GetFullPath(LCandidate);
      Exit(True);
    end;
  end;

  // 2. Search paths.
  for LDir in FSearchPaths do
  begin
    LCandidate := TPath.Combine(LDir, LName);
    if TFile.Exists(LCandidate) then
    begin
      AResolved := TPath.GetFullPath(LCandidate);
      Exit(True);
    end;
  end;

  // 3. Basename index (corpus fallback).
  if (FIncludeIndex <> nil) and
     FIncludeIndex.TryGetValue(LowerCase(TPath.GetFileName(LName)), LCandidate)
  then
  begin
    AResolved := LCandidate;
    Exit(True);
  end;

  Result := False;
end;

end.
