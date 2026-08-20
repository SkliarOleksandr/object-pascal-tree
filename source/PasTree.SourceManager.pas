unit PasTree.SourceManager;

{
  PasTree — source file loading and include resolution.

  Loading is tolerant: BOMs are honored, a file WITHOUT one is UTF-8 when its
  bytes are valid UTF-8 and ANSI when they are not, and a file that fails STRICT
  decoding under a DECLARED encoding is decoded again leniently rather than
  rejected — it keeps that encoding and gets U+FFFD for the bad sequence. Every
  fallback skips the preamble. DecodeBytes carries the reasoning for all of it:
  dcc accepts such files, treating one malformed byte as fatal loses the whole
  unit, and reading a preamble-less UTF-8 file as ANSI silently shifted every
  column after a non-ASCII character.
}

interface

uses
  System.SysUtils,
  System.Threading,
  System.Generics.Collections,
  PasTree.Types;

type
  TPasSourceManager = class
  private type
    // An overlay buffer (SetBuffer): the text analysis sees for a path, plus
    // the HOST's version stamp for it. The version means nothing here — it is
    // carried so an asynchronous host (the demo, the LSP server) can compare
    // a finished analysis against the document version it currently holds and
    // discard a stale result instead of navigating with wrong positions.
    TBufferEntry = record
      Text: string;
      Version: Integer;
    end;
  private
    FSearchPaths: TArray<string>;
    FNamespaces: TArray<string>;                  // -NS prefixes, in order
    FAliases: TDictionary<string, string>;        // -A alias(lower) -> real
    FIncludeIndex: TDictionary<string, string>;  // basename -> full path
    FUnitIndex: TDictionary<string, string>;      // *.pas/*.dpr basename -> path
    FBuffers: TDictionary<string, TBufferEntry>;  // full path (lower) -> entry
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
    // Lexed include files, shared across every including unit: an include's
    // Source text and token array are includer-INDEPENDENT (what differs per
    // includer is which tokens end up visible/skipped, and that lives in the
    // includer's own TPasPreprocessed) — so re-lexing widely shared .inc
    // files per includer only duplicated identical strings and arrays.
    // Guarded by FIncludeLock: HandleInclude runs on the parse workers.
    // TPasTokenStream is a record of refcounted string/arrays, so handing a
    // copy out under the lock is two refcount bumps, not a data copy.
    FIncludeStreams: TDictionary<string, TPasTokenStream>;
    FIncludeLock: TObject;
    // Files whose bytes did not decode under their DECLARED encoding and had
    // to be recovered (path -> how). Guarded because decoding runs on the
    // parse workers. Empty for every ordinary corpus — a preamble-less file
    // landing on ANSI is the rule rather than a recovery and is deliberately
    // NOT recorded here; see the end of DecodeBytes.
    FRecovered: TDictionary<string, string>;
    FRecoveredLock: TObject;
    function TryFile(const ADir, AName: string; out AResolved: string): Boolean;
    function DirIndex(const ADir: string): TDictionary<string, string>;
    function FindUnitFile(const AUnitName, AFromDir: string;
      out AResolved: string): Boolean;
    function ReadFileText(const APath: string): string;
    function DecodeText(const ABytes: TBytes; const APath: string): string;
    procedure NoteRecovered(const APath, AHow: string);
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
      LoadText). Keyed by full-path, case-insensitive. Set before analyzing.
      AVersion is the host's version stamp for the document (an LSP
      `didChange` version, an editor change counter) — stored verbatim,
      readable back via BufferVersion, never interpreted here. }
    procedure SetBuffer(const APath, AText: string; AVersion: Integer = 0);
    procedure ClearBuffers;
    { The version stamp SetBuffer stored for APath, or -1 when no overlay is
      set for it. An async host compares this against the version it holds
      NOW to recognize a result that was computed from older text. }
    function BufferVersion(const APath: string): Integer;
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
    { The lexed token stream of an include file, shared across includers (see
      FIncludeStreams). APath must already be RESOLVED (ResolveInclude's out
      value). An editor-buffer override (SetBuffer) is tokenized fresh and
      stays OUT of the shared cache — buffers are per-analysis mutable state. }
    function IncludeStream(const APath: string): TPasTokenStream;
    { Drops the analysis-scoped caches once a project run has finished: the
      raw-bytes repository (a complete second copy of every closure file that
      nothing reads after analysis — post-analysis text access goes through
      the token streams' own Source) and the shared include-stream cache's
      OWN references (the models keep theirs; the arrays stay alive exactly
      as long as a model still uses them). A later analysis on the same
      manager just re-Prefetches and re-lexes — correctness is unaffected. }
    procedure ReleaseAnalysisCaches;
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
    { How APath had to be RECOVERED to be read at all, or '' when it decoded
      cleanly. A caller turns this into a diagnostic (PPENC): the text after
      the bad byte may not be what the author wrote, and staying silent about
      it once cost ~1700 downstream false reports. }
    function RecoveryNote(const APath: string): string;
    { The decode itself, without an instance. Exposed because a HOST must show
      the reader exactly the text the analysis ran on: a separate loader is a
      second source of truth, and the two disagree precisely on the files that
      are hardest to read. `TStrings.LoadFromFile` raises on a malformed byte
      (`No mapping for the Unicode character exists in the target multi-byte
      code page`), so the demo used to display that message INSTEAD of the
      unit — the one file where seeing the source actually mattered. }
    class function DecodeBytes(const ABytes: TBytes;
      out AHow: string): string; static;
    class function LoadFileTolerant(const APath: string): string; static;
  end;

implementation

uses
  System.Classes,
  System.IOUtils,
  PasTree.Lexer;

{ TPasSourceManager }

constructor TPasSourceManager.Create(const ASearchPaths: TArray<string>);
begin
  inherited Create;
  FSearchPaths := ASearchPaths;
  FRecoveredLock := TObject.Create;
  FIncludeLock := TObject.Create;
end;

destructor TPasSourceManager.Destroy;
begin
  FRecovered.Free;
  FRecoveredLock.Free;
  FIncludeStreams.Free;
  FIncludeLock.Free;
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

procedure TPasSourceManager.SetBuffer(const APath, AText: string;
  AVersion: Integer);
var
  LEntry: TBufferEntry;
begin
  if FBuffers = nil then
    FBuffers := TDictionary<string, TBufferEntry>.Create;
  LEntry.Text := AText;
  LEntry.Version := AVersion;
  FBuffers.AddOrSetValue(LowerCase(TPath.GetFullPath(APath)), LEntry);
end;

procedure TPasSourceManager.ClearBuffers;
begin
  FreeAndNil(FBuffers);
end;

function TPasSourceManager.BufferVersion(const APath: string): Integer;
var
  LEntry: TBufferEntry;
begin
  if (FBuffers <> nil) and
     FBuffers.TryGetValue(LowerCase(TPath.GetFullPath(APath)), LEntry) then
    Result := LEntry.Version
  else
    Result := -1;
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
  // SEARCH PATHS FIRST, referring directory only as a fallback. dcc-verified,
  // and the order matters more than it looks: with `b.pas` and `c.pas` sitting
  // together in one directory and ANOTHER `c.pas` earlier on the search path,
  // dcc compiles b against the search-path one — the importer's own directory
  // carries no priority at all. This is how a project SHADOWS a third-party
  // unit: it drops a patched copy into its own tree and puts that directory
  // first. Probing the referring directory first quietly undid that, and the
  // patched member then read as undeclared at every use — reported, of course,
  // in the patched file itself, three units away from the actual mistake.
  //
  // The fallback stays because it is strictly more tolerant than dcc: a unit
  // reached from a directory NOBODY listed is an F1027 for dcc, and an F1027
  // here GATES its importers' diagnostics rather than reporting them.
  if FSearchIndex.TryGetValue(LowerCase(AUnitName) + '.pas', AResolved) then
    Exit(True);
  Result := DirIndex(AFromDir).TryGetValue(LowerCase(AUnitName) + '.pas',
    AResolved);
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

  // 3. As spelled: <dotted>.pas on the search paths, then — beyond what dcc
  // accepts — relative to the referring file. See FindUnitFile for the order.
  if FindUnitFile(LUnitName, LDir, AResolved) then
    Exit(True);

  // 4. Unit-scope namespaces (dcc -NS), IN ORDER, applied to the name AS
  // SPELLED — dotted or not. `uses Generics.Collections` with -NS System
  // resolves to System.Generics.Collections.pas, and there is no
  // Generics.Collections.pas anywhere, so the prefix is the ONLY way to find
  // it: dcc-verified, compiles with -NSSystem and cannot be explained by any
  // other rule here. This used to be gated on an unqualified name, which
  // refused exactly the example the comment cited. Real cost: 16 of the 27
  // unresolvable imports left on a 3789-unit project were this one line.
  //
  // Tried only AFTER the as-spelled lookup above, so a name that names a real
  // file (Vcl.Forms) can never be captured by a prefix.
  for LName in FNamespaces do
    if (LName <> '') and
       FindUnitFile(LName + '.' + LUnitName, LDir, AResolved) then
      Exit(True);
  LDot := LastDelimiter('.', LUnitName);

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

{ Bytes -> string, tolerantly. A BOM is honored; a file without one is UTF-8 if
  its bytes ARE valid UTF-8, and ANSI otherwise.

  UTF-8-FIRST FOR PREAMBLE-LESS FILES, decided 2026-08-20 (the open question in
  the README, now closed). It used to default to TEncoding.Default — the system
  ANSI codepage — because that is what dcc does, and matching the compiler is
  the right instinct. It is the wrong answer here, for a reason that only became
  visible once an editor was hosting this library:

  - Every modern editor decodes a preamble-less .pas as UTF-8. This repository's
    own sources are UTF-8 with no BOM and full of em-dashes in comments, so the
    analyzer and the editor genuinely read DIFFERENT TEXT out of the same bytes:
    a 3-byte dash arrived as three ANSI characters. Every column on a line with
    a non-ASCII character before the identifier was then off by the byte
    inflation — silently, because nothing reports it. Navigation just lands next
    to the name, or inside the preceding string literal.
  - The two decodes disagreeing also defeated the LSP server's rebuild gate,
    which compares an editor buffer against the file's BYTES (a decode
    difference is not an edit). Sound as far as rebuilding goes, but it left the
    analysis holding its own ANSI reading of a file the editor had open, and no
    rebuild was ever due to correct it. That is not a host bug that can be
    worked around host-side: a host would have to re-decode every file the
    analysis reads.
  - What "matching dcc" buys is smaller than it looks. Identifiers are ASCII, so
    the semantic model is unaffected either way; the difference is confined to
    the CONTENTS of string literals and comments — where dcc, reading UTF-8
    bytes as ANSI, produces mojibake. Reproducing that faithfully has no value
    to a caller, while the position skew costs correctness everywhere.

  Pure-ASCII files (the overwhelming majority) decode identically under both
  rules, so this is a superset of the old behaviour rather than a change of
  policy for them. A genuinely ANSI-encoded source — high bytes that are NOT
  valid UTF-8 — still falls back to ANSI, via the same recovery path below, and
  is still noted through AHow.

  THE FAILURE PATHS, which is where the subtlety always was. Delphi's
  TEncoding.UTF8 raises EEncodingError on a malformed sequence, and real sources
  contain them: one Windows-1252 apostrophe survives in a `///` comment in
  Alcinoe.FMX.Dynamic.Objects.pas, and dcc compiles that file without complaint.
  Two things must therefore hold.

  First, a file that DECLARED itself UTF-8 with a BOM is still UTF-8 — one bad
  byte is not a reason to reinterpret the whole thing as ANSI. It is decoded
  again with a LENIENT UTF-8 that substitutes U+FFFD for the bad sequence and
  leaves everything else intact, and that IS reported (PPENC), because the text
  may no longer be what the author wrote. A preamble-less file is the opposite
  case in both respects: its bad byte is EVIDENCE about the encoding, since
  nothing declared UTF-8, so it becomes ANSI — which is how a Windows-1251
  source still reads correctly — and nothing is reported, because nothing went
  wrong. See the end of the implementation.

  Second, and this was the actual bug: the fallback must skip the PREAMBLE.
  Decoding from offset 0 turned the three BOM bytes into text, so the file
  began with garbage instead of `unit`. The lexer rejected it at line 1, the
  parser produced a single node, the model came out EMPTY — and every unit
  that imported it lost every name it declared. One byte in a comment cost
  ~1700 false "undeclared identifier" reports on the Alcinoe package. }
class function TPasSourceManager.DecodeBytes(const ABytes: TBytes;
  out AHow: string): string;
var
  LEnc, LLenient: TEncoding;
  LStart: Integer;
  LDeclared: Boolean;
begin
  AHow := '';
  LEnc := nil;
  LStart := TEncoding.GetBufferEncoding(ABytes, LEnc, TEncoding.UTF8);
  // A preamble was found, so the file SAYS what it is; without one, UTF-8 above
  // is an assumption this may have to take back.
  LDeclared := LStart > 0;
  try
    Result := LEnc.GetString(ABytes, LStart, Length(ABytes) - LStart);
  except
    on E: EEncodingError do
      if LDeclared and (LEnc.CodePage = CP_UTF8) then
      begin
        // Same encoding, no error flags: substitute rather than raise.
        LLenient := TUTF8Encoding.Create(CP_UTF8, 0, 0);
        try
          Result := LLenient.GetString(ABytes, LStart, Length(ABytes) - LStart);
        finally
          LLenient.Free;
        end;
        AHow := 'UTF-8|leniently, substituting U+FFFD';
      end
      else
      begin
        Result := TEncoding.ANSI.GetString(ABytes, LStart,
          Length(ABytes) - LStart);
        if LDeclared then
          AHow := LEnc.EncodingName + '|by re-reading it as ANSI';
        // ...and NOTHING is noted when nothing was declared: reaching ANSI
        // because the bytes are not valid UTF-8 is the RULE for a
        // preamble-less file, not a recovery from a failed one. AHow feeds
        // PPENC, whose whole meaning is "the recovered text may not be what
        // the author wrote" - which is false here: ANSI decoding is total and
        // loses nothing, and the Latin-1 name in a SynEdit copyright header
        // reads exactly right. Noting it anyway produced 10 warnings on a
        // 197-unit closure that named a correct reading as a problem (9 in
        // SynEdit, 1 in the RTL's System.DateUtils), which is how a
        // diagnostics list stops being read at all.
      end;
  end;
end;

class function TPasSourceManager.LoadFileTolerant(const APath: string): string;
var
  LHow: string;
begin
  Result := DecodeBytes(TFile.ReadAllBytes(APath), LHow);
end;

function TPasSourceManager.DecodeText(const ABytes: TBytes;
  const APath: string): string;
var
  LHow: string;
begin
  Result := DecodeBytes(ABytes, LHow);
  if LHow <> '' then
    NoteRecovered(APath, LHow);
end;

procedure TPasSourceManager.NoteRecovered(const APath, AHow: string);
begin
  if FRecoveredLock = nil then
    Exit;   // never nil after Create; the guard keeps a torn-down manager safe
  TMonitor.Enter(FRecoveredLock);
  try
    if FRecovered = nil then
      FRecovered := TDictionary<string, string>.Create;
    FRecovered.AddOrSetValue(LowerCase(TPath.GetFullPath(APath)), AHow);
  finally
    TMonitor.Exit(FRecoveredLock);
  end;
end;

function TPasSourceManager.RecoveryNote(const APath: string): string;
begin
  Result := '';
  if (FRecovered = nil) or (FRecoveredLock = nil) then
    Exit;
  TMonitor.Enter(FRecoveredLock);
  try
    FRecovered.TryGetValue(LowerCase(TPath.GetFullPath(APath)), Result);
  finally
    TMonitor.Exit(FRecoveredLock);
  end;
end;

// One tolerant disk read (BOM honored; ANSI fallback on decode failure) —
// LoadText's direct-from-disk path.
function TPasSourceManager.ReadFileText(const APath: string): string;
begin
  Result := DecodeText(TFile.ReadAllBytes(APath), APath);
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
  LEntry: TBufferEntry;
begin
  LKey := LowerCase(TPath.GetFullPath(APath));
  if FBuffers <> nil then
  begin
    if FBuffers.TryGetValue(LKey, LEntry) then
      Exit(LEntry.Text);
  end;
  if (FContentCache <> nil) and FContentCache.TryGetValue(LKey, LRaw) then
    Exit(DecodeText(LRaw, APath));
  Result := ReadFileText(APath);
end;

function TPasSourceManager.IncludeStream(const APath: string): TPasTokenStream;
var
  LKey: string;
begin
  LKey := LowerCase(TPath.GetFullPath(APath));
  // An unsaved-buffer override changes per analysis — never share it.
  if (FBuffers <> nil) and FBuffers.ContainsKey(LKey) then
    Exit(TPasLexer.Tokenize(LoadText(APath)));
  TMonitor.Enter(FIncludeLock);
  try
    if (FIncludeStreams <> nil) and
       FIncludeStreams.TryGetValue(LKey, Result) then
      Exit;
  finally
    TMonitor.Exit(FIncludeLock);
  end;
  // Decode + lex OUTSIDE the lock: both are the expensive part, and two
  // workers racing to the same include at worst lex it twice — the loser
  // then adopts the winner's copy below, so every includer still ends up
  // sharing one stream.
  Result := TPasLexer.Tokenize(LoadText(APath));
  TMonitor.Enter(FIncludeLock);
  try
    if FIncludeStreams = nil then
      FIncludeStreams := TDictionary<string, TPasTokenStream>.Create;
    if not FIncludeStreams.TryAdd(LKey, Result) then
      Result := FIncludeStreams[LKey];
  finally
    TMonitor.Exit(FIncludeLock);
  end;
end;

procedure TPasSourceManager.ReleaseAnalysisCaches;
begin
  FreeAndNil(FContentCache);
  TMonitor.Enter(FIncludeLock);
  try
    FreeAndNil(FIncludeStreams);
  finally
    TMonitor.Exit(FIncludeLock);
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
