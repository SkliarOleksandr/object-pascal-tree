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
    FNamespaces: TArray<string>;                  // -NS prefixes, in order
    FAliases: TDictionary<string, string>;        // -A alias(lower) -> real
    FIncludeIndex: TDictionary<string, string>;  // basename -> full path
    FUnitIndex: TDictionary<string, string>;      // *.pas/*.dpr basename -> path
    FBuffers: TDictionary<string, string>;        // full path (lower) -> text
    // Unit-file lookup indexes, built LAZILY on the first FindUnitFile call
    // (a project may never resolve units at all). FSearchIndex maps a .pas
    // basename (lower) to its full path across ALL search paths — first path
    // wins, preserving exactly the priority order the un-indexed loop had.
    // FDirIndexes holds the same per single directory, for the referring-
    // file's dir (which outranks every search path). Replaces the previous
    // per-candidate TFile.Exists probing: a project-closure load was doing
    // hundreds of thousands of file-exists syscalls (each unqualified name
    // tries every namespace prefix against every search path) — measured at
    // 5.5s of a 6.7s real-project analysis before this index, ~0 after.
    FSearchIndex: TDictionary<string, string>;
    FDirIndexes: TObjectDictionary<string, TDictionary<string, string>>;
    function TryFile(const ADir, AName: string; out AResolved: string): Boolean;
    function DirIndex(const ADir: string): TDictionary<string, string>;
    function FindUnitFile(const AUnitName, AFromDir: string;
      out AResolved: string): Boolean;
  public
    constructor Create(const ASearchPaths: TArray<string>);
    destructor Destroy; override;
    { Unit-scope namespaces (dcc -NS / DCC_Namespace), tried IN ORDER as
      prefixes when an unqualified unit name has no file of its own:
      `uses Generics.Collections` -> System.Generics.Collections.pas. }
    procedure SetNamespaces(const ANamespaces: TArray<string>);
    { Unit aliases (dcc -A / DCC_UnitAlias): a whole-name match rewrites the
      unit name BEFORE resolution (WinTypes -> Winapi.Windows). }
    procedure AddUnitAlias(const AAlias, AReal: string);
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
  FDirIndexes.Free;
  FSearchIndex.Free;
  FAliases.Free;
  FBuffers.Free;
  FIncludeIndex.Free;
  FUnitIndex.Free;
  inherited;
end;

// The .pas files of one directory, indexed by lower-cased basename; built on
// first request, cached. '' and missing dirs yield an empty index.
function TPasSourceManager.DirIndex(const ADir: string):
  TDictionary<string, string>;
var
  LKey, LFile: string;
begin
  if FDirIndexes = nil then
    FDirIndexes := TObjectDictionary<string, TDictionary<string, string>>.
      Create([doOwnsValues]);
  LKey := LowerCase(ADir);
  if FDirIndexes.TryGetValue(LKey, Result) then
    Exit;
  Result := TDictionary<string, string>.Create;
  if (ADir <> '') and TDirectory.Exists(ADir) then
    for LFile in TDirectory.GetFiles(ADir, '*.pas') do
      Result.TryAdd(LowerCase(TPath.GetFileName(LFile)), LFile);
  FDirIndexes.Add(LKey, Result);
end;

procedure TPasSourceManager.SetNamespaces(const ANamespaces: TArray<string>);
begin
  FNamespaces := ANamespaces;
end;

procedure TPasSourceManager.AddUnitAlias(const AAlias, AReal: string);
begin
  if FAliases = nil then
    FAliases := TDictionary<string, string>.Create;
  FAliases.AddOrSetValue(LowerCase(AAlias), AReal);
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

// One candidate unit name (as-spelled) against the referring dir, then the
// search paths — the shared step ResolveUnit runs per candidate spelling.
// Index-backed (see FSearchIndex): two dictionary lookups, no file syscalls.
function TPasSourceManager.FindUnitFile(const AUnitName, AFromDir: string;
  out AResolved: string): Boolean;
var
  LDir, LFile: string;
begin
  if FSearchIndex = nil then
  begin
    FSearchIndex := TDictionary<string, string>.Create;
    // First path wins — same priority the sequential probing loop had.
    for LDir in FSearchPaths do
      if TDirectory.Exists(LDir) then
        for LFile in TDirectory.GetFiles(LDir, '*.pas') do
          FSearchIndex.TryAdd(LowerCase(TPath.GetFileName(LFile)), LFile);
  end;
  if DirIndex(AFromDir).TryGetValue(LowerCase(AUnitName) + '.pas',
     AResolved) then
    Exit(True);
  Result := FSearchIndex.TryGetValue(LowerCase(AUnitName) + '.pas', AResolved);
end;

function TPasSourceManager.ResolveUnit(const AUnitName, AInPath, AFromFile: string;
  out AResolved: string): Boolean;
var
  LDir, LLeaf, LCand, LUnitName: string;
  LNames: TArray<string>;
  LName: string;
  LDot: Integer;
begin
  // AFromFile = '' is legal: "resolve by search paths only, no anchor file"
  // (e.g. TPasSemaProject.EnsureSystemUnit, which has no referring unit to
  // anchor from). TPath.GetDirectoryName raises on '' instead of returning
  // '', so this must be guarded explicitly rather than passed through.
  if AFromFile = '' then
    LDir := ''
  else
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
    if AFromFile <> '' then
      LDir := TPath.GetDirectoryName(AFromFile);
  end;

  // 2. Unit alias (dcc -A): a whole-name match rewrites the spelling before
  // any file lookup (WinTypes -> Winapi.Windows), exactly once (dcc does not
  // chain aliases).
  LUnitName := AUnitName;
  if (FAliases <> nil) and FAliases.TryGetValue(LowerCase(AUnitName), LCand) then
    LUnitName := LCand;

  // 3. As spelled: <dotted>.pas relative to the referring file, then the
  // search paths.
  if FindUnitFile(LUnitName, LDir, AResolved) then
    Exit(True);

  // 4. Unit-scope namespaces (dcc -NS), IN ORDER, for an UNQUALIFIED name
  // only (dcc applies namespaces to generic names, not already-dotted ones):
  // `uses Generics.Collections` -> System.Generics.Collections.pas.
  LDot := LastDelimiter('.', LUnitName);
  if LDot = 0 then
    for LName in FNamespaces do
      if (LName <> '') and
         FindUnitFile(LName + '.' + LUnitName, LDir, AResolved) then
        Exit(True);

  // 5. Leaf-name tolerance for a dotted name (System.SysUtils -> SysUtils.pas
  // — pre-namespace-era file layouts).
  if LDot > 0 then
  begin
    LLeaf := Copy(LUnitName, LDot + 1, MaxInt);
    if FindUnitFile(LLeaf, LDir, AResolved) then
      Exit(True);
  end
  else
    LLeaf := LUnitName;

  // 6. Unit index (basename fallback).
  if FUnitIndex <> nil then
  begin
    LNames := [LUnitName + '.pas'];
    if not SameText(LLeaf, LUnitName) then
      LNames := LNames + [LLeaf + '.pas'];
    for LName in LNames do
      if FUnitIndex.TryGetValue(LowerCase(LName), LCand) then
      begin
        AResolved := LCand;
        Exit(True);
      end;
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
