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
  System.Threading,
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
    // In-memory file-content repository, filled by Prefetch (below): LoadText
    // serves from here before touching the disk. Same lifetime as this
    // manager — one analysis run — so no external-change invalidation is
    // needed (a fresh run re-reads via the OS cache anyway). Holds raw BYTES,
    // not strings: the I/O workers must stay allocation-light (see Prefetch),
    // so decoding happens on the consumer's (per-core parse worker's) thread.
    FContentCache: TDictionary<string, TBytes>;
    function TryFile(const ADir, AName: string; out AResolved: string): Boolean;
    function DirIndex(const ADir: string): TDictionary<string, string>;
    function FindUnitFile(const AUnitName, AFromDir: string;
      out AResolved: string): Boolean;
    function ReadFileText(const APath: string): string;
    function DecodeText(const ABytes: TBytes): string;
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
    { Reads every file of APaths into the in-memory repository CONCURRENTLY,
      with an I/O-depth pool (32 workers) rather than the per-core parse
      pool: a COLD read's cost is dominated by per-file latency (antivirus
      scan-on-first-touch, MFT lookups), not throughput, so it pays to keep
      many requests in flight while the CPU-bound parse workers stay
      per-core. Call before a parse batch; LoadText then serves from memory.
      Failed reads are skipped silently — LoadText's own error path reports
      them, as before. }
    procedure Prefetch(const APaths: TArray<string>);
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
  FContentCache.Free;
  FDirIndexes.Free;
  FSearchIndex.Free;
  FAliases.Free;
  FBuffers.Free;
  FIncludeIndex.Free;
  FUnitIndex.Free;
  inherited;
end;

{ Prefetch and the search-index build run their concurrent I/O on the
  DEFAULT thread pool — deliberately NOT a private TThreadPool. A private
  pool was tried (a fixed 16-worker one) and behaved pathologically on a
  machine with more cores than the dev box: TThreadPool.SetMaxWorkerThreads
  REJECTS values below the default MinWorkerThreads (= CPU count), so the
  "16-worker" pool silently became something else entirely there, its
  phases ran an order of magnitude slower, and destroying it (a fresh
  source manager per analysis = a pool shutdown per analysis, 16 worker
  stops with their wait timeouts) burned ~a second of every re-analysis.
  The default pool is shared, already warm, sized to the machine, and
  never shut down. The cold-latency win of the prefetch comes from
  SEPARATING the I/O phase from the CPU phase, not from any particular
  queue depth. }

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
  LFile: string;
  LListings: TArray<TArray<string>>;
  LIdx: Integer;
begin
  if FSearchIndex = nil then
  begin
    FSearchIndex := TDictionary<string, string>.Create;
    // Enumerate every search path CONCURRENTLY (a cold directory listing is
    // latency-bound, like a cold file read — see Prefetch) into per-path
    // slots, then merge SEQUENTIALLY in path order: first path wins, the
    // same priority the sequential probing loop had.
    SetLength(LListings, Length(FSearchPaths));
    TParallel.&For(0, High(FSearchPaths),
      procedure(AIndex: Integer)
      begin
        if TDirectory.Exists(FSearchPaths[AIndex]) then
          LListings[AIndex] := TDirectory.GetFiles(FSearchPaths[AIndex], '*.pas')
        else
          LListings[AIndex] := nil;
      end);
    for LIdx := 0 to High(LListings) do
      for LFile in LListings[LIdx] do
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

// Bytes -> string with the same tolerant semantics TFile.ReadAllText has
// (honor a BOM, default to ANSI without one, raw-ANSI fallback if strict
// decoding fails). Runs on the CONSUMER's thread — never on the I/O pool.
function TPasSourceManager.DecodeText(const ABytes: TBytes): string;
var
  LEnc: TEncoding;
  LStart: Integer;
begin
  LEnc := nil;
  LStart := TEncoding.GetBufferEncoding(ABytes, LEnc, TEncoding.Default);
  try
    Result := LEnc.GetString(ABytes, LStart, Length(ABytes) - LStart);
  except
    on E: EEncodingError do
      Result := TEncoding.ANSI.GetString(ABytes);
  end;
end;

// One tolerant disk read (BOM honored; ANSI fallback on decode failure) —
// LoadText's direct-from-disk path.
function TPasSourceManager.ReadFileText(const APath: string): string;
begin
  Result := DecodeText(TFile.ReadAllBytes(APath));
end;

procedure TPasSourceManager.Prefetch(const APaths: TArray<string>);
var
  LBytes: TArray<TBytes>;
  LIdx: Integer;
begin
  if APaths = nil then
    Exit;
  if FContentCache = nil then
    FContentCache := TDictionary<string, TBytes>.Create;
  // Concurrent reads into per-index slots, sequential commit — no locks, and
  // the dictionary is never mutated while parse workers might read it. The
  // workers read raw BYTES only (one allocation per file): decoding to a
  // UTF-16 string doubles the memory traffic and, under
  // NeverSleepOnMMThreadContention=True, memory-manager contention across
  // many threads SPINS — 32 workers decoding multi-MB sources concurrently
  // spin-convoyed an 185-unit analysis into the 16-second range. Decoding
  // happens per-core in the parse workers instead (LoadText/DecodeText).
  SetLength(LBytes, Length(APaths));
  TParallel.&For(0, High(APaths),
    procedure(AIndex: Integer)
    begin
      try
        LBytes[AIndex] := TFile.ReadAllBytes(APaths[AIndex]);
      except
        LBytes[AIndex] := nil;   // unreadable — LoadText's disk path reports it
      end;
    end);
  for LIdx := 0 to High(APaths) do
    if LBytes[LIdx] <> nil then
      FContentCache.AddOrSetValue(LowerCase(TPath.GetFullPath(APaths[LIdx])),
        LBytes[LIdx]);
end;

function TPasSourceManager.LoadText(const APath: string): string;
var
  LKey: string;
  LRaw: TBytes;
begin
  LKey := LowerCase(TPath.GetFullPath(APath));
  if (FBuffers <> nil) and FBuffers.TryGetValue(LKey, Result) then
    Exit;
  if (FContentCache <> nil) and FContentCache.TryGetValue(LKey, LRaw) then
    Exit(DecodeText(LRaw));
  Result := ReadFileText(APath);
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
