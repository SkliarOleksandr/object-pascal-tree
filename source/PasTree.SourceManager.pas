unit PasTree.SourceManager;

{
  PasTree - source file loading and include resolution.

  Loading is tolerant: BOMs are honored, a file WITHOUT one is UTF-8 when its
  bytes are valid UTF-8 and ANSI when they are not, and a file that fails STRICT
  decoding under a DECLARED encoding is decoded again leniently rather than
  rejected - it keeps that encoding and gets U+FFFD for the bad sequence. Every
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
    // the HOST's version stamp for it. The version means nothing here - it is
    // carried so an asynchronous host (the demo, the LSP server) can compare
    // a finished analysis against the document version it currently holds and
    // discard a stale result instead of navigating with wrong positions.
    TBufferEntry = record
      Text: string;
      Version: Integer;
    end;
    // What ResolveUnit's search steps (alias, as spelled, namespaces, leaf,
    // unit index, .dcu) answer for one unit name, computed once (see
    // FUnitMemo). The only input that varies per call is the REFERRING
    // directory, probed after the project dir and the search paths of each
    // candidate spelling: DirNames are the candidate basenames that the probe
    // order would have tried there BEFORE reaching Path, in that order. A
    // call checks them against its own directory first and takes Path when
    // none is there - exactly the answer the step-by-step probing gave.
    TUnitMemo = record
      DirNames: TArray<string>;   // '<candidate>.pas', lower-cased
      Found: Boolean;
      Path: string;      // full: every listing behind it is of a full path
      PathKey: string;   // LowerCase(Path), the project's key for the file
      // Every candidate spelling probed, lower-cased, in probe order (alias
      // or as spelled, each unit scope prefix, the leaf), and the index of
      // the one whose file was found (-1: found by the unit index or a .dcu,
      // or not found). ResolveUnit checks the pins against them - see there.
      Candidates: TArray<string>;
      MatchIdx: Integer;
    end;
    // One include candidate asked on disk (see FIncludePaths): whether the
    // file was there, its directory's last-write time read before the probe,
    // when it was probed, and the include epoch of the probe.
    TIncludePath = record
      Exists: Boolean;
      Stamp: TDateTime;
      ProbedAt: TDateTime;
      Epoch: Integer;
    end;
    // A directory's last-write time and the include epoch it was read in.
    TIncludeDirStamp = record
      Stamp: TDateTime;
      Epoch: Integer;
    end;
  private
    FSearchPaths: TArray<string>;
    FNamespaces: TArray<string>;                  // -NS prefixes, in order
    FAliases: TDictionary<string, string>;        // -A alias(lower) -> real
    FIncludeIndex: TDictionary<string, string>;  // basename -> full path
    FUnitIndex: TDictionary<string, string>;      // *.pas/*.dpr basename -> path
    FBuffers: TDictionary<string, TBufferEntry>;  // full path (lower) -> entry
    // Unit-file lookup indexes, built by PrepareIndexes at every analysis
    // entry, or lazily by the first resolution. FSearchIndex maps a .pas
    // basename (lower) to its full path across ALL search paths - first path
    // wins, preserving exactly the priority order the un-indexed loop had.
    // FDirIndexes holds the same per single directory, for the referring-
    // file's dir (which outranks every search path). Replaces the previous
    // per-candidate TFile.Exists probing: a project-closure load was doing
    // hundreds of thousands of file-exists syscalls (each unqualified name
    // tries every namespace prefix against every search path) - measured at
    // 5.5s of a 6.7s real-project analysis before this index, ~0 after.
    FSearchIndex: TDictionary<string, string>;
    FDirIndexes: TObjectDictionary<string, TDictionary<string, string>>;
    // What the indexes were built from, so a later analysis on this manager
    // can tell whether the disk moved under them (BeginRun): each search
    // path's listing (.pas and .dcu) with the directory's last-write time
    // taken BEFORE it was listed, and the same stamp per FDirIndexes entry.
    // A directory's last-write time moves when a file is created, deleted
    // or renamed in it - exactly the events that change a listing.
    FPathListings: TArray<TArray<string>>;
    FPathStamps: TArray<TDateTime>;
    FPathListedAt: TArray<TDateTime>;   // when each was listed
    FDirStamps: TDictionary<string, TDateTime>;
    // The run each listing was last checked in (BeginRun counts the runs,
    // FRunEpoch): FDirChecked per directory index, FListingsEpoch for the
    // search paths. FMemoStale: the project directory moved, so FUnitMemo
    // is dropped at the next ResolveUnit (not inside the memo build that
    // noticed it).
    FRunEpoch: Integer;
    FListingsEpoch: Integer;
    FDirChecked: TDictionary<string, Integer>;
    FMemoStale: Boolean;
    // Compiled units on the search paths (a `.dcu` basename, lower, without
    // its extension -> full path; first path wins), built with FSearchIndex.
    // The LAST resort of ResolveUnit: a unit with no .pas anywhere is read
    // from its .dcu (PasTree.Dcu) and analyzed from the interface source
    // PasTree.Dcu.Source prints for it - README "units with no source". A
    // .pas anywhere on the paths beats a .dcu anywhere, so a library that
    // ships both is still analyzed from its source.
    FDcuIndex: TDictionary<string, string>;
    // The generated interface text per .dcu path (lower), so a unit's text
    // is generated once whatever the number of readers (the parse workers, a
    // later rehydration). Kept for the manager's life - a demoted unit
    // rehydrates from it - and so stamped (FDcuStamps): a .dcu rebuilt during
    // a session is generated afresh, not served from the old text. Guarded
    // by FDcuLock.
    FDcuTexts: TDictionary<string, string>;
    // Why a .dcu could not be read (path lower -> message): the F1027 an
    // importer then reports names the real cause instead of "no source".
    FDcuFailures: TDictionary<string, string>;
    // The file's write time and size when its text or failure was recorded.
    FDcuStamps: TDictionary<string, string>;
    // Other units' .dcu files DcuText's prints read for the layout, members
    // and enumeration names of imported types (DcuForeign), by folded full
    // path: (the stamp read at, the TPasDcuUnit or nil when unreadable).
    // Shared by every print of this manager - a printer's own cache lived
    // for one unit, and System.dcu was read again for each unit that
    // imported from it (audit C1-37). A unit read again after a rebuild
    // retires the old object to FDcuRetired: a print on another worker may
    // still be reading it. Both are freed by ReleaseAnalysisCaches, when no
    // print runs. Guarded by FDcuLock.
    FDcuUnits: TDictionary<string, TPair<string, TObject>>;
    FDcuRetired: TObjectList<TObject>;
    FDcuForeignLoads: Integer;
    FDcuLock: TObject;
    // In-memory file-content repository, filled by Prefetch (below): LoadText
    // serves from here before touching the disk. One analysis long - dropped
    // by ReleaseAnalysisCaches and by BeginRun - so no external-change
    // invalidation is needed (the next run re-reads via the OS cache). Holds raw BYTES,
    // not strings: the I/O workers must stay allocation-light (see Prefetch),
    // so decoding happens on the consumer's (per-core parse worker's) thread.
    FContentCache: TDictionary<string, TBytes>;
    // Lexed include files, shared across every including unit: an include's
    // Source text and token array are includer-INDEPENDENT (what differs per
    // includer is which tokens end up visible/skipped, and that lives in the
    // includer's own TPasPreprocessed) - so re-lexing widely shared .inc
    // files per includer only duplicated identical strings and arrays.
    // Guarded by FIncludeLock: HandleInclude runs on the parse workers.
    // TPasTokenStream is a record of refcounted string/arrays, so handing a
    // copy out under the lock is a handful of refcount bumps, not a data copy.
    FIncludeStreams: TDictionary<string, TPasTokenStream>;
    FIncludeLock: TObject;
    // Files whose bytes did not decode under their DECLARED encoding and had
    // to be recovered (path -> how). Guarded because decoding runs on the
    // parse workers. Empty for every ordinary corpus - a preamble-less file
    // landing on ANSI is the rule rather than a recovery and is deliberately
    // NOT recorded here; see the end of DecodeBytes.
    FRecovered: TDictionary<string, string>;
    FRecoveredLock: TObject;
    FSearchNames: TArray<string>;   // SearchPathUnitNames' cache
    FSearchNamesBuilt: Boolean;
    // Units LOCATED for the whole project - unit name (lower) -> full path.
    // dcc semantics: a `uses Foo in 'patched\Foo.pas'` in the program file
    // decides where Foo lives for EVERY unit that imports it, not just for
    // the program; the IDE's project file list (DCCReference) means the same
    // thing. Consulted before any path probing, because this is how a
    // project SHADOWS a third-party unit with a patched copy that sits in no
    // search path at all - and without it the third-party units importing
    // Foo resolved the ORIGINAL from the library path, so the closure held
    // two different Foos and analyzed everything foreign against the wrong
    // one. Filled by ResolveUnit itself (an in-path resolving) and by PinUnit.
    FPinned: TDictionary<string, string>;
    // The keys of FPinned an in-path put there during an analysis, as
    // opposed to a host's PinUnit: the analysis's own, dropped when a full
    // analysis starts (BeginRun), so an edited `in` clause cannot keep
    // binding the old file. A host's pins stay until the host changes them.
    FInPathPins: TDictionary<string, Boolean>;
    // AnalyzeModuleOnly's snapshot of both (SavePins), put back when it
    // refuses: a refused run leaves the project as it was.
    FSavedPins: TDictionary<string, string>;
    FSavedInPath: TDictionary<string, Boolean>;
    // The pins ResolveUnit has seen exist (lower name), so each is checked
    // on disk once per analysis, not on every import of it.
    FPinnedSeen: TDictionary<string, Boolean>;
    // The project's own directory - dcc's implicit "current directory",
    // searched BEFORE every -U path. A patched copy dropped beside the .dpr
    // is found there by the IDE without any search-path entry; it must be
    // found here too, ahead of the library paths. '' = none (a directory
    // root, an open-documents-only host).
    FProjectDir: string;
    // Unit name (lower) -> its resolution (TUnitMemo). A unit is named by
    // every importer, in several stages, and an unqualified name walks every
    // -NS prefix before it hits: probing it afresh each time was 17% of all
    // allocations of a client analysis. Everything the memo derives from is
    // manager-lifetime (the search, dir and unit indexes, aliases,
    // namespaces, project dir), so it lives as long; the setters of the
    // configuration it depends on clear it (ForgetUnitResolution), and so
    // does BeginRun when a listing the indexes hold moved on disk. Pins and
    // in-paths are answered outside it and never enter it (a pin is checked
    // against the memo's candidate spellings, see ResolveUnit). Buffers
    // (SetBuffer) play no part: an overlay cannot make a unit file exist.
    // Driver-thread only, like the rest of ResolveUnit (DirIndex and FPinned
    // are unguarded too): every caller - discovery in the load engine,
    // ResolveUses, EnsureSystemUnit before the parallel passes - runs there.
    FUnitMemo: TDictionary<string, TUnitMemo>;
    // The referring file of the last ResolveUnit call and its directory's
    // index: an importer's uses are resolved in a row, so the directory is
    // split off and lower-cased once per importer instead of once per probe.
    FMemoFrom: string;
    FMemoFromIndex: TDictionary<string, string>;
    // (unit path and including path, each up to its last separator, + the
    // include argument, #0 between, all as spelled) -> resolved path, '' for
    // not found. ResolveInclude asks a candidate of FIncludePaths (the disk
    // behind it) and runs for every include of every includer. Same lifetime
    // as FIncludeStreams - one analysis, AnalyzeModuleOnly's included (both
    // are dropped by BeginRun) - and guarded by the same FIncludeLock (it
    // runs on the parse workers), so a later analysis on this manager sees
    // an include created or edited in between; SetProjectDir drops it too.
    // Its entries keyed #1 + the file name are the search paths' answer for
    // that name, which depends on nothing else (SearchPathInclude).
    FIncludeMemo: TDictionary<string, string>;
    // File probes made for includes (ResolveIncludeIn), for the tests.
    FIncludeProbes: Integer;
    // The include candidates asked on disk (folded full path -> the answer)
    // and the last-write times of their directories (folded path). The memo
    // above lives one run, and a light-mode query takes units in over
    // several runs, each resolving its includes anew: a miss probed the
    // unit's directory, the project's and every search path again - 2.9 s of
    // a 9 s `find` on the client group, where jcl.inc and jvcl.inc name
    // dozens of includes of other compilers. These outlive the runs. A
    // directory's time is read once per FIncludeEpoch (moved wherever the
    // memo is dropped) - it moves when a file is created, deleted or renamed
    // in it - and an answer holds while it equals the time read before the
    // probe. A whole listing per directory was tried first: on the client
    // the 490 candidates of 23 names in 148 directories cost 18,806 names
    // listed, 90 ms where the probes take about 10. The probes and the time
    // reads run outside FIncludeLock (parse workers); only the dictionaries
    // are under it.
    FIncludePaths: TDictionary<string, TIncludePath>;
    FIncludeDirStamps: TDictionary<string, TIncludeDirStamp>;
    FIncludeEpoch: Integer;
    FIncludeDiskChecks: Integer;   // TFile.Exists calls made, for the tests
    // Step 3 of the include search (SearchPathInclude): every file name of
    // the search paths (folded) -> the first path holding it, from the
    // listings EnsureSearchIndex takes anyway - they kept .pas and .dcu
    // alone, and a light-mode `find` on the client asked the disk 16,763
    // times, about 80 names no path holds (jvcl.inc's jvcld20win32.inc ..
    // jvcld37win32.inc, in branches no build compiles) times every search
    // path. A copy of the listings, their stamps and listing times: the
    // workers build its names on first use and check it once per run
    // (FRunEpoch; EnsureIncludeIndexFresh) and
    // list a moved path again, apart from the driver's RefreshListings. Under
    // FIncludeLock. FIncCheckedRun: the run it was last checked in; FIncBusy:
    // a worker is building or checking it; FIncGen: driver merges, so a
    // worker's late result never replaces a fresher listing.
    FIncNames: TDictionary<string, Integer>;
    FIncListings: TArray<TArray<string>>;
    FIncStamps, FIncListedAt: TArray<TDateTime>;
    FIncCheckedRun, FIncGen: Integer;
    FIncBusy: Boolean;
    FIncIndexRefreshes: Integer;   // relisted by a worker, for the tests
    function TryFile(const ADir, AName: string; out AResolved: string): Boolean;
    function TryIncludeFile(const ADir, AName: string;
      out AResolved: string): Boolean;
    function IncludeFileExists(const APath: string): Boolean;
    procedure DropIncludeMemo;
    function DirIndex(const ADir: string): TDictionary<string, string>;
    procedure EnsureSearchIndex;
    function BuildUnitMemo(const AKey: string): TUnitMemo;
    function FromDirIndex(const AFromFile: string): TDictionary<string, string>;
    procedure ForgetUnitResolution;
    procedure MergeSearchIndex;
    function EnsureIncludeIndexFresh: Boolean;
    function IncludeFromIndex(const AName: string;
      out AResolved: string): Boolean;
    function RefreshListings: Boolean;
    function PinnedFile(const AKey: string; out AResolved: string): Boolean;
    procedure PinInPath(const AUnitName, APath: string);
    function ResolveIncludeIn(const AUnitFile, AIncludingFile, AName: string;
      out AResolved: string): Boolean;
    function SearchPathInclude(const AName: string;
      out AResolved: string): Boolean;
    function FindDcuFile(const AUnitName: string; out AResolved: string): Boolean;
    function DcuText(const APath: string): string;
    function DcuForeign(const APath: string): TObject;
    procedure FreeDcuUnits;
    function ReadFileText(const APath: string): string;
    function DecodeText(const ABytes: TBytes; const APath: string): string;
    procedure NoteRecovered(const APath, AHow: string);
  public
    constructor Create(const ASearchPaths: TArray<string>);
    destructor Destroy; override;
    { Builds the search-path index now, on the calling thread. The index is
      otherwise built lazily by the first unit resolution that needs it, with
      a TParallel.For over the search paths - which deadlocks when that first
      resolution runs while every pool thread is busy (the project's load
      engine occupies the whole pinned pool, see
      TPasSemaProject.ConfigureThreadPool). TPasSemaProject calls this at
      every Analyze* entry, on the driver, before any engine starts. Built
      once per manager; later calls return at once. }
    procedure PrepareIndexes;
    { True once PrepareIndexes (or a resolution) built the index. }
    function IndexesReady: Boolean;
    { Starts an analysis on this manager - TPasSemaProject calls it at every
      Analyze* entry, AnalyzeModuleOnly's included, on the driver before any
      engine starts. The manager lives as long as its project, and a module
      run used to inherit every cache of the run before it (audit A4-18,
      A4-19): an include edited or created on disk stayed stale or missing,
      and a unit file created on disk was never found by name. It drops the
      include streams and memo and the content cache, forgets which pins
      were seen on disk, and starts a new run count: every listing the
      indexes were built from is checked against its directory's stamp once
      in this run - a directory index on its first use, the search paths on
      the first resolution that misses - and listed again when it moved. AFullRun also drops the pins in-paths added
      (FInPathPins): a full analysis re-reads every `in` clause, and an
      edited one must not keep its old file. }
    procedure BeginRun(AFullRun: Boolean);
    { AnalyzeModuleOnly's snapshot of the pins, put back by RestorePins when
      it refuses (a newcomer's in-path may have pinned before the refusal)
      and dropped by DropSavedPins when it commits. }
    procedure SavePins;
    procedure RestorePins;
    procedure DropSavedPins;
    { The file an `in 'path'` clause names for a unit written in AFromFile -
      ResolveUnit's step 1 without its pin: relative to the referring file,
      the project directory, each search path; a rooted path as is. }
    function ResolveInPath(const AInPath, AFromFile: string;
      out AResolved: string): Boolean;
    { The unit an alias (dcc -A) rewrites AName to, '' when it is none. }
    function UnitAlias(const AName: string): string;
    { Unit-scope namespaces (dcc -NS / DCC_Namespace), tried IN ORDER as
      prefixes when an unqualified unit name has no file of its own:
      `uses Generics.Collections` -> System.Generics.Collections.pas. }
    procedure SetNamespaces(const ANamespaces: TArray<string>);
    { Unit aliases (dcc -A / DCC_UnitAlias): a whole-name match rewrites the
      unit name BEFORE resolution (WinTypes -> Winapi.Windows). }
    procedure AddUnitAlias(const AAlias, AReal: string);
    { Locates AUnitName at APath for the whole project, ahead of every path
      lookup (see FPinned). What a program's `in 'path'` clause does in dcc;
      a host hands the project file's own unit list through here. The FIRST
      pin for a name wins - a later, different location is dcc's "unit found
      in two places", and the program's word stays authoritative. A pin to a
      file that does not exist (on disk or as a buffer) when the unit is
      resolved is dropped, and the unit is looked up as if never pinned: dcc
      takes a `uses X in 'gone\X.pas'` from the search path. }
    procedure PinUnit(const AUnitName, APath: string);
    { The project directory - searched before the search paths, as dcc's
      implicit current directory is (see FProjectDir). The analysis drivers
      set it from the main file when a host has not. }
    procedure SetProjectDir(const ADir: string);
    function ProjectDir: string;
    { A canonical signature of everything that decides WHICH file a unit name
      resolves to: search paths (in order - order is priority), namespaces (in
      order - tried in order), aliases (sorted - a dictionary has no order).
      Two managers with equal signatures resolve every unit name identically,
      which is what TPasSemaProject.AdoptParseDonor gates on. The project
      directory leads it; AWithProjectDir = False leaves it out, for the gate's
      check before a run has decided the directory. }
    function ConfigSignature(AWithProjectDir: Boolean = True): string;
    { In-memory buffer overrides: LoadText returns the given text for APath
      instead of reading the file. Editor hosts push unsaved buffers here so
      analysis sees what's on screen (main file AND its $I includes go through
      LoadText). Keyed by full-path, case-insensitive. Set before analyzing.
      AVersion is the host's version stamp for the document (an LSP
      `didChange` version, an editor change counter) - stored verbatim,
      readable back via BufferVersion, never interpreted here. }
    procedure SetBuffer(const APath, AText: string; AVersion: Integer = 0);
    procedure ClearBuffers;
    { Whether APath can be READ by this analysis: a file on disk, or a buffer
      SetBuffer gave for a path with no file behind it yet. The second is a
      unit created in the IDE and never saved - the program's
      `Unit2 in 'Unit2.pas'` names it the moment it exists, and the editor
      holds its text. Every gate that asks "is there a unit here" asks this,
      never TFile.Exists alone: a disk-only gate dropped such a unit from the
      closure, so it was analyzed nowhere until the first save (a new data
      module in a real project, 2026-09-25). }
    function SourceExists(const APath: string): Boolean;
    { The version stamp SetBuffer stored for APath, or -1 when no overlay is
      set for it. An async host compares this against the version it holds
      NOW to recognize a result that was computed from older text. }
    function BufferVersion(const APath: string): Integer;
    { Reads every file of APaths into the in-memory repository CONCURRENTLY.
      A COLD read's cost is dominated by per-file latency (antivirus
      scan-on-first-touch, MFT lookups) rather than throughput, so the reads
      are farmed out rather than serialized - on the DEFAULT pool, deliberately
      (the private 32-worker I/O pool this once described is gone; see the
      implementation). Call before a parse batch; LoadText then serves from
      memory.
      Failed reads are skipped silently - LoadText's own error path reports
      them, as before. }
    procedure Prefetch(const APaths: TArray<string>);
    function LoadText(const APath: string): string;
    { The lexed token stream of an include file, shared across includers (see
      FIncludeStreams). APath must already be RESOLVED (ResolveInclude's out
      value). An editor-buffer override (SetBuffer) is tokenized fresh and
      stays OUT of the shared cache - buffers are per-analysis mutable state. }
    function IncludeStream(const APath: string): TPasTokenStream;
    { Drops the analysis-scoped caches once a project run has finished: the
      raw-bytes repository (a complete second copy of every closure file that
      nothing reads after analysis - post-analysis text access goes through
      the token streams' own Source) and the shared include-stream cache's
      OWN references (the models keep theirs; the arrays stay alive exactly
      as long as a model still uses them). A later analysis on the same
      manager just re-Prefetches and re-lexes - correctness is unaffected. }
    procedure ReleaseAnalysisCaches;
    { Indexes every *.inc under ARoot by basename as a last-resort include
      resolver (corpus runs without real project search paths). The first
      occurrence of an ambiguous name wins. }
    procedure BuildIncludeIndex(const ARoot: string); overload;
    { The same index from the *.inc files of a listing the caller took
      anyway (TPasProject.ParseDirectory: one walk for its sources and its
      includes). }
    procedure BuildIncludeIndex(const AFiles: TArray<string>); overload;
    { Resolves an include argument (possibly quoted) as dcc does: beside
      AUnitFile - the unit (or program) being compiled, whichever file names
      the include - then the project directory, then the search paths; then,
      as a tolerance where dcc finds nothing, beside AIncludingFile; then the
      index. The name is PasIncludeFileName's (`.pas` added to one without an
      extension), the bare name a tolerance after that; an unsaved buffer
      counts as a file. See ResolveIncludeIn. }
    function ResolveInclude(const AUnitFile, AIncludingFile, AName: string;
      out AResolved: string): Boolean;
    { The file probes ResolveInclude has made on this manager - a directory
      asked whether it holds the file. For the tests. }
    property IncludeProbes: Integer read FIncludeProbes;
    { The candidates ResolveInclude has asked the disk about on this manager
      - again when its directory moved since the last answer. For the tests. }
    property IncludeDiskChecks: Integer read FIncludeDiskChecks;
    { The times a worker found a search path moved and listed it again for
      the include index. For the tests. }
    property IncludeIndexRefreshes: Integer read FIncIndexRefreshes;
    { Indexes every *.pas/*.dpr under ARoot by basename, for unit-name
      resolution when there are no real search paths (project-dir fallback).
      Returns the files it listed, full paths in listing order - the
      directory driver's roots, so it does not walk the tree again. }
    function BuildUnitIndex(const ARoot: string): TArray<string>;
    { The files under ARoot (below it too when ARecursive) whose extension is
      one of AExts ('.pas', lower case, with the dot; none = every file), as
      TDirectory lists them. Raises as TDirectory.GetFiles does - a caller
      that tolerates an unreadable directory catches. }
    class function ListFiles(const ARoot: string; ARecursive: Boolean;
      const AExts: array of string): TArray<string>; static;
    { Resolves a unit name (e.g. 'System.SysUtils') to a file, in this
      order: a unit the project located (a pin: the program's in-path, the
      host's PinUnit) under the name as written; the explicit `in` path;
      then per candidate spelling - the alias or the name as spelled, each
      unit scope prefix, the leaf - the pins, the project directory and the
      search paths, the referring directory as a tolerance past dcc; the
      unit index; a .dcu. See BuildUnitMemo and spec 1.2.2. }
    function ResolveUnit(const AUnitName, AInPath, AFromFile: string;
      out AResolved: string): Boolean; overload;
    { The same answer - a full path, the search paths and index roots being
      made full before they are listed - and its key, LowerCase(AResolved),
      the one TPasSemaProject's path maps use: memoized with the unit's
      resolution, so a caller does not canonicalize every answer again. }
    function ResolveUnit(const AUnitName, AInPath, AFromFile: string;
      out AResolved, AKey: string): Boolean; overload;
    { Every unit NAME a `uses` can reach by its file - the project
      directory's *.pas, then the search paths' (first one wins on a
      duplicate basename), each with its original spelling and no
      extension, then the units the paths hold only compiled - completion's
      uses-clause candidate set, in ResolveUnit's order. Cached until BeginRun
      finds a listing moved. }
    function SearchPathUnitNames: TArray<string>;
    { How APath had to be RECOVERED to be read at all, or '' when it decoded
      cleanly. A caller turns this into a diagnostic (PPENC): the text after
      the bad byte may not be what the author wrote, and staying silent about
      it once cost ~1700 downstream false reports. }
    function RecoveryNote(const APath: string): string;
    { True when APath is a compiled unit ResolveUnit fell back to (its text
      is generated, see FDcuIndex): a host shows it read-only, and the
      analyzer's importer reports DcuFailure when LoadText raised. }
    class function IsDcuPath(const APath: string): Boolean; static;
    { Why the .dcu at APath could not be read in this analysis, '' when it
      could (or was never asked for). }
    function DcuFailure(const APath: string): string;
    { How many times a print of a compiled unit's interface read ANOTHER
      unit's .dcu from disk for its imported types - once per file and
      stamp, whatever the number of units importing from it. }
    property DcuForeignLoads: Integer read FDcuForeignLoads;
    { The decode itself, without an instance. Exposed because a HOST must show
      the reader exactly the text the analysis ran on: a separate loader is a
      second source of truth, and the two disagree precisely on the files that
      are hardest to read. `TStrings.LoadFromFile` raises on a malformed byte
      (`No mapping for the Unicode character exists in the target multi-byte
      code page`), so the demo used to display that message INSTEAD of the
      unit - the one file where seeing the source actually mattered. }
    { Strict UTF-8 validity of ABytes from AStart: the same rule the strict
      TEncoding.UTF8 enforces (no overlong forms, no surrogates, nothing past
      U+10FFFF, no truncated sequence), so DecodeBytes can take its fallback
      WITHOUT raising first. Exposed for the tests. }
    class function IsValidUtf8(const ABytes: TBytes; AStart: Integer): Boolean;
    class function DecodeBytes(const ABytes: TBytes;
      out AHow: string): string; static;
    class function LoadFileTolerant(const APath: string): string; static;
  end;

{ The file name dcc looks for when an include directive names AArg: trimmed,
  its quotes dropped, and `.pas` appended when it has no extension (dcc64
  37.0: `$I inc2` reads inc2.pas with a bare inc2 beside it, `$I inc3` with
  only inc3.inc is F1026 'inc3.pas', the quoted form and `-I` alike; spec
  1.3.3). The name an F1026 for it quotes. }
function PasIncludeFileName(const AArg: string): string;

{ True when AName ends in AExt ('.pas': lower case, with the dot), the case
  of AName's ASCII letters aside. }
function HasExt(const AName, AExt: string): Boolean;

implementation

uses
  System.Classes,
  System.IOUtils,
  System.SyncObjs,
  PasTree.Lexer,
  PasTree.Dcu,
  PasTree.Dcu.Source;

const
  // An include probe made this soon after its directory's last change is
  // made again in the next epoch (TPasSourceManager.IncludeFileExists).
  RACY_PROBE = 2 / SecsPerDay;

// True when AName ends in AExt ('.pas', ASCII, any case) - what
// SameText(TPath.GetExtension(AName), AExt) answers for an extension without
// a dot of its own, minus the string GetExtension allocates per file listed.
function HasExt(const AName, AExt: string): Boolean;
var
  LOff, LIdx: Integer;
  LCh: Char;
begin
  LOff := Length(AName) - Length(AExt);
  if LOff < 0 then
    Exit(False);
  for LIdx := 1 to Length(AExt) do
  begin
    LCh := AName[LOff + LIdx];
    if (LCh >= 'A') and (LCh <= 'Z') then
      LCh := Char(Ord(LCh) + 32);
    if LCh <> AExt[LIdx] then
      Exit(False);
  end;
  Result := True;
end;

function PathTextUsable(const APath: string): Boolean; forward;

// AFiles into ADict by folded file name, the first file of a name winning -
// the rule of every index here (audit D2-36).
procedure IndexByBaseName(const AFiles: TArray<string>;
  ADict: TDictionary<string, string>);
var
  LFile: string;
begin
  for LFile in AFiles do
    ADict.TryAdd(PasFoldName(TPath.GetFileName(LFile)), LFile);
end;

{ TPasSourceManager }

class function TPasSourceManager.ListFiles(const ARoot: string;
  ARecursive: Boolean; const AExts: array of string): TArray<string>;
var
  LExts: TArray<string>;
  LOption: TSearchOption;
begin
  // A copy: an open array cannot be captured by the predicate.
  SetLength(LExts, Length(AExts));
  for var LIdx := 0 to High(AExts) do
    LExts[LIdx] := AExts[LIdx];
  if ARecursive then
    LOption := TSearchOption.soAllDirectories
  else
    LOption := TSearchOption.soTopDirectoryOnly;
  // The predicate sees the name before TDirectory builds the full path, and
  // HasExt tests it without the string GetExtension allocates.
  Result := TDirectory.GetFiles(ARoot, LOption,
    function(const APath: string; const ASearchRec: TSearchRec): Boolean
    var
      LExt: string;
    begin
      if LExts = nil then
        Exit(True);
      for LExt in LExts do
        if HasExt(ASearchRec.Name, LExt) then
          Exit(True);
      Result := False;
    end);
end;

// APath made full, or as given when it cannot be ('', a path GetFullPath
// rejects): a listing of a full directory holds full paths.
function FullPathOrSelf(const APath: string): string;
begin
  Result := APath;
  if PathTextUsable(APath) then
    try
      Result := TPath.GetFullPath(APath);
    except
      Result := APath;
    end;
end;

constructor TPasSourceManager.Create(const ASearchPaths: TArray<string>);
var
  LIdx: Integer;
begin
  inherited Create;
  // Full before anything lists them, so every answer ResolveUnit gives from
  // a listing is full (audit D2-35).
  SetLength(FSearchPaths, Length(ASearchPaths));
  for LIdx := 0 to High(ASearchPaths) do
    FSearchPaths[LIdx] := FullPathOrSelf(ASearchPaths[LIdx]);
  FRecoveredLock := TObject.Create;
  FIncludeLock := TObject.Create;
  FDcuLock := TObject.Create;
  FIncCheckedRun := -1;
end;

destructor TPasSourceManager.Destroy;
begin
  FIncludeMemo.Free;
  FIncNames.Free;
  FIncludePaths.Free;
  FIncludeDirStamps.Free;
  FUnitMemo.Free;
  FreeDcuUnits;
  FDcuFailures.Free;
  FDcuTexts.Free;
  FDcuStamps.Free;
  FDirStamps.Free;
  FDirChecked.Free;
  FInPathPins.Free;
  FSavedPins.Free;
  FSavedInPath.Free;
  FDcuIndex.Free;
  FDcuLock.Free;
  FRecovered.Free;
  FRecoveredLock.Free;
  FIncludeStreams.Free;
  FIncludeLock.Free;
  FContentCache.Free;
  FDirIndexes.Free;
  FSearchIndex.Free;
  FAliases.Free;
  FPinned.Free;
  FPinnedSeen.Free;
  FBuffers.Free;
  FIncludeIndex.Free;
  FUnitIndex.Free;
  inherited;
end;

{ Prefetch and the search-index build run their concurrent I/O on the
  DEFAULT thread pool - deliberately NOT a private TThreadPool. A private
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

// A directory's last-write time, 0 when there is none to read (no such
// directory, '', access denied): what BeginRun compares to tell a listing
// that moved.
function DirStamp(const ADir: string): TDateTime;
begin
  Result := 0;
  if ADir = '' then
    Exit;
  try
    if TDirectory.Exists(ADir) then
      Result := TDirectory.GetLastWriteTime(ADir);
  except
    Result := 0;
  end;
end;

// Every file of one search path, for EnsureSearchIndex: its .pas and .dcu
// files for the unit indexes, all of them for the include index (an include
// has any extension - SearchPathInclude).
function ListSearchPath(const ADir: string): TArray<string>;
begin
  Result := nil;
  try
    if TDirectory.Exists(ADir) then
      Result := TPasSourceManager.ListFiles(ADir, False, []);
  except
    Result := nil;   // unreadable: nothing found there, as DirIndex says
  end;
end;

// The .pas files of one directory, indexed by lower-cased basename; built on
// first request, cached until BeginRun sees the directory move. '' and
// missing dirs yield an empty index.
function TPasSourceManager.DirIndex(const ADir: string):
  TDictionary<string, string>;
var
  LKey: string;
  LChecked: Integer;
  LStamp: TDateTime;
begin
  if FDirIndexes = nil then
    FDirIndexes := TObjectDictionary<string, TDictionary<string, string>>.
      Create([doOwnsValues]);
  if FDirChecked = nil then
    FDirChecked := TDictionary<string, Integer>.Create;
  LKey := PasFoldName(ADir);
  if FDirIndexes.TryGetValue(LKey, Result) then
  begin
    // Listed by an earlier analysis: its stamp is checked once per run, on
    // the first use - a referring directory only when a resolution reaches
    // it, so a keystroke run stats the few it touches, not the hundreds a
    // closure lists. Moved, it is listed again; the project directory's
    // move also invalidates the memoized resolutions (see FMemoStale).
    if not FDirChecked.TryGetValue(LKey, LChecked) or
       (LChecked = FRunEpoch) then
      Exit;
    FDirChecked[LKey] := FRunEpoch;
    if (FDirStamps <> nil) and FDirStamps.TryGetValue(LKey, LStamp) and
       (DirStamp(ADir) = LStamp) then
      Exit;
    if Result = FMemoFromIndex then
    begin
      FMemoFromIndex := nil;
      FMemoFrom := '';
    end;
    FDirIndexes.Remove(LKey);   // owned: freed here
    if SameText(ExcludeTrailingPathDelimiter(ADir), FProjectDir) then
      FMemoStale := True;
    FSearchNamesBuilt := False;
  end;
  // The stamp BEFORE the listing: a file created while it is taken moves the
  // stamp past this one, and the next check lists the directory again.
  if FDirStamps = nil then
    FDirStamps := TDictionary<string, TDateTime>.Create;
  FDirStamps.AddOrSetValue(LKey, DirStamp(ADir));
  FDirChecked.AddOrSetValue(LKey, FRunEpoch);
  Result := TDictionary<string, string>.Create;
  // The enumeration can RAISE after Exists says yes (an access-denied
  // directory is the ordinary case), and the fresh dictionary is not owned by
  // anything until the Add below - so it has to be registered whatever
  // happens: an empty index for an unreadable directory is the right answer
  // anyway, and a leak per such directory was the alternative.
  try
    if (ADir <> '') and TDirectory.Exists(ADir) then
      IndexByBaseName(ListFiles(ADir, False, ['.pas']), Result);
  except
    Result.Clear;
  end;
  FDirIndexes.Add(LKey, Result);
end;

procedure TPasSourceManager.SetNamespaces(const ANamespaces: TArray<string>);
begin
  FNamespaces := ANamespaces;
  ForgetUnitResolution;
end;

procedure TPasSourceManager.AddUnitAlias(const AAlias, AReal: string);
begin
  if FAliases = nil then
    FAliases := TDictionary<string, string>.Create;
  FAliases.AddOrSetValue(PasFoldName(AAlias), AReal);
  ForgetUnitResolution;
end;

procedure TPasSourceManager.PinUnit(const AUnitName, APath: string);
begin
  if (AUnitName = '') or (APath = '') then
    Exit;
  if FPinned = nil then
    FPinned := TDictionary<string, string>.Create;
  FPinned.TryAdd(PasFoldName(AUnitName), TPath.GetFullPath(APath));
end;

// An in-path's pin (ResolveUnit step 1): PinUnit's first-wins rule, and the
// key recorded as the analysis's own when it is new (see FInPathPins).
procedure TPasSourceManager.PinInPath(const AUnitName, APath: string);
var
  LKey: string;
begin
  if (AUnitName = '') or (APath = '') then
    Exit;
  if FPinned = nil then
    FPinned := TDictionary<string, string>.Create;
  LKey := PasFoldName(AUnitName);
  if FPinned.TryAdd(LKey, TPath.GetFullPath(APath)) then
  begin
    if FInPathPins = nil then
      FInPathPins := TDictionary<string, Boolean>.Create;
    FInPathPins.AddOrSetValue(LKey, True);
  end;
end;

// The pinned file of the unit name AKey (lower-cased), when there is one
// that can be read. A pin to a missing file is dropped: dcc, given
// `uses X in 'gone\X.pas'` (or a .dproj listing that file), compiles the X
// the search path finds, and only when there is none says F1026
// 'gone\X.pas'. Kept, it answered with a file LoadFile cannot read, and
// every importer of a unit the build compiles fine reported F1027. Checked
// here rather than in PinUnit: a host pins before it hands over its buffers.
function TPasSourceManager.PinnedFile(const AKey: string;
  out AResolved: string): Boolean;
begin
  Result := False;
  if (FPinned = nil) or not FPinned.TryGetValue(AKey, AResolved) then
    Exit;
  if FPinnedSeen = nil then
    FPinnedSeen := TDictionary<string, Boolean>.Create;
  if FPinnedSeen.ContainsKey(AKey) then
    Exit(True);
  if SourceExists(AResolved) then
  begin
    FPinnedSeen.Add(AKey, True);
    Exit(True);
  end;
  FPinned.Remove(AKey);
  if FInPathPins <> nil then
    FInPathPins.Remove(AKey);
  AResolved := '';
end;

function TPasSourceManager.ResolveInPath(const AInPath, AFromFile: string;
  out AResolved: string): Boolean;
var
  LDir: string;
begin
  Result := False;
  if not PathTextUsable(AInPath) then
    Exit;
  if TPath.IsPathRooted(AInPath) and SourceExists(AInPath) then
  begin
    AResolved := TPath.GetFullPath(AInPath);
    Exit(True);
  end;
  // AFromFile = '' is legal: "resolve by search paths only, no anchor
  // file" (e.g. TPasSemaProject.EnsureSystemUnit, which has no referring
  // unit to anchor from). TPath.GetDirectoryName raises on '' instead of
  // returning '', so this must be guarded explicitly.
  if AFromFile = '' then
    LDir := ''
  else
    LDir := TPath.GetDirectoryName(AFromFile);
  if TryFile(LDir, AInPath, AResolved) or
     TryFile(FProjectDir, AInPath, AResolved) then
    Exit(True);
  for LDir in FSearchPaths do
    if TryFile(LDir, AInPath, AResolved) then
      Exit(True);
end;

procedure TPasSourceManager.SetProjectDir(const ADir: string);
begin
  if ADir = '' then
    FProjectDir := ''
  else
    FProjectDir := ExcludeTrailingPathDelimiter(TPath.GetFullPath(ADir));
  ForgetUnitResolution;
  // An include is looked up in the project directory as well.
  TMonitor.Enter(FIncludeLock);
  try
    DropIncludeMemo;
  finally
    TMonitor.Exit(FIncludeLock);
  end;
end;

function TPasSourceManager.ProjectDir: string;
begin
  Result := FProjectDir;
end;

function TPasSourceManager.ConfigSignature(AWithProjectDir: Boolean): string;
var
  LItem: string;
  LPairs: TArray<string>;
  LPair: TPair<string, string>;
begin
  // The project directory is a search path in all but name (BuildUnitMemo
  // probes it first), so it decides resolution exactly as the paths do.
  if AWithProjectDir then
    Result := PasFoldName(FProjectDir) + '|'
  else
    Result := '|';
  for LItem in FSearchPaths do
    Result := Result + LItem + #1;
  Result := Result + '|';
  for LItem in FNamespaces do
    Result := Result + LItem + #1;
  Result := Result + '|';
  if FAliases <> nil then
  begin
    LPairs := nil;
    for LPair in FAliases do
      LPairs := LPairs + [LPair.Key + '=' + LPair.Value];
    TArray.Sort<string>(LPairs);
    for LItem in LPairs do
      Result := Result + LItem + #1;
  end;
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
  FBuffers.AddOrSetValue(PasFoldName(TPath.GetFullPath(APath)), LEntry);
  // A buffer can be an include no file stands behind yet: the memo's
  // misses may be hits now (audit B4-39).
  TMonitor.Enter(FIncludeLock);
  try
    DropIncludeMemo;
  finally
    TMonitor.Exit(FIncludeLock);
  end;
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
     FBuffers.TryGetValue(PasFoldName(TPath.GetFullPath(APath)), LEntry) then
    Result := LEntry.Version
  else
    Result := -1;
end;

// True when TPath can be handed APath without raising: not empty, no control
// character (CR/LF included - an unterminated include directive runs to the
// next brace, lines and all), nothing HasValidPathChars rejects (`"`, `<`,
// `>`, `|`, and `*`/`?`, on which IsPathRooted raises too). A uses in-path or
// an include name is source text: one that fails here names no file, and is
// "not found" - never an exception that aborts the whole analysis.
function PathTextUsable(const APath: string): Boolean;
var
  LCh: Char;
begin
  if APath = '' then
    Exit(False);
  for LCh in APath do
    if LCh < #32 then
      Exit(False);
  Result := TPath.HasValidPathChars(APath, False);
end;

function TPasSourceManager.SourceExists(const APath: string): Boolean;
begin
  if TFile.Exists(APath) then
    Exit(True);
  Result := False;
  if (FBuffers = nil) or (APath = '') then
    Exit;
  try
    Result := FBuffers.ContainsKey(PasFoldName(TPath.GetFullPath(APath)));
  except
    // A path GetFullPath rejects (an `in` string with characters no file
    // name may hold) names no buffer either.
    Result := False;
  end;
end;

function TPasSourceManager.TryFile(const ADir, AName: string;
  out AResolved: string): Boolean;
var
  LCandidate: string;
begin
  Result := False;
  if not PathTextUsable(ADir) or not PathTextUsable(AName) then
    Exit;
  LCandidate := TPath.Combine(ADir, AName);
  if SourceExists(LCandidate) then
  begin
    AResolved := TPath.GetFullPath(LCandidate);
    Result := True;
  end;
end;

// TryFile for an include: the candidate looked up in its directory's listing
// (IncludeFileExists) instead of on disk.
function TPasSourceManager.TryIncludeFile(const ADir, AName: string;
  out AResolved: string): Boolean;
var
  LCandidate: string;
begin
  Result := False;
  if not PathTextUsable(ADir) or not PathTextUsable(AName) then
    Exit;
  LCandidate := TPath.Combine(ADir, AName);
  if IncludeFileExists(LCandidate) then
  begin
    AResolved := TPath.GetFullPath(LCandidate);
    Result := True;
  end;
end;

// SourceExists for an include candidate, by FIncludePaths: a buffer, or the
// disk's answer for the path - kept across runs while its directory's
// last-write time, read once per include epoch, equals the one read before
// the probe. A probe made within RACY_PROBE of that time may have missed a
// file created in the same clock tick, the time unmoved (git's racy index):
// it holds for its own epoch and is made again in the next. The probe and
// the time read run outside FIncludeLock, the parse workers resolving
// includes concurrently; two workers asking the same path at once both
// probe, and either answer is the disk's.
function TPasSourceManager.IncludeFileExists(const APath: string): Boolean;
var
  LFull, LDir, LKey, LDirKey: string;
  LEpoch: Integer;
  LDirStamp: TIncludeDirStamp;
  LEntry: TIncludePath;
  LHaveStamp, LHaveEntry: Boolean;
begin
  Result := False;
  try
    LFull := TPath.GetFullPath(APath);
  except
    Exit;   // a path GetFullPath rejects names no file and no buffer
  end;
  LKey := PasFoldName(LFull);
  if (FBuffers <> nil) and FBuffers.ContainsKey(LKey) then
    Exit(True);
  LDir := ExtractFileDir(LFull);
  LDirKey := PasFoldName(LDir);
  TMonitor.Enter(FIncludeLock);
  try
    LEpoch := FIncludeEpoch;
    LHaveStamp := (FIncludeDirStamps <> nil) and
      FIncludeDirStamps.TryGetValue(LDirKey, LDirStamp) and
      (LDirStamp.Epoch = LEpoch);
    LHaveEntry := (FIncludePaths <> nil) and
      FIncludePaths.TryGetValue(LKey, LEntry);
  finally
    TMonitor.Exit(FIncludeLock);
  end;
  if LHaveEntry and (LEntry.Epoch = LEpoch) then
    Exit(LEntry.Exists);
  if not LHaveStamp then
  begin
    // Read BEFORE the probe: a file created after it moves the time past
    // this one, and the next epoch probes again.
    LDirStamp.Stamp := DirStamp(LDir);
    LDirStamp.Epoch := LEpoch;
  end;
  if LHaveEntry and (LEntry.Stamp = LDirStamp.Stamp) and
     (LEntry.ProbedAt - LEntry.Stamp >= RACY_PROBE) then
  begin
    Result := LEntry.Exists;
    LEntry.Epoch := LEpoch;
  end
  else
  begin
    TInterlocked.Increment(FIncludeDiskChecks);
    LEntry.Stamp := LDirStamp.Stamp;
    LEntry.ProbedAt := Now;
    LEntry.Exists := TFile.Exists(LFull);
    LEntry.Epoch := LEpoch;
    Result := LEntry.Exists;
  end;
  TMonitor.Enter(FIncludeLock);
  try
    if FIncludePaths = nil then
    begin
      FIncludePaths := TDictionary<string, TIncludePath>.Create;
      FIncludeDirStamps := TDictionary<string, TIncludeDirStamp>.Create;
    end;
    if not LHaveStamp then
      FIncludeDirStamps.AddOrSetValue(LDirKey, LDirStamp);
    FIncludePaths.AddOrSetValue(LKey, LEntry);
  finally
    TMonitor.Exit(FIncludeLock);
  end;
end;

// The include answers of one run dropped, and the disk answers behind them
// due for a check (FIncludePaths). Under FIncludeLock.
procedure TPasSourceManager.DropIncludeMemo;
begin
  FreeAndNil(FIncludeMemo);
  Inc(FIncludeEpoch);
end;

function TPasSourceManager.BuildUnitIndex(const ARoot: string): TArray<string>;
begin
  FreeAndNil(FUnitIndex);
  ForgetUnitResolution;
  FUnitIndex := TDictionary<string, string>.Create;
  Result := ListFiles(FullPathOrSelf(ARoot), True, ['.pas', '.dpr']);
  IndexByBaseName(Result, FUnitIndex);
end;

procedure TPasSourceManager.PrepareIndexes;
begin
  EnsureSearchIndex;
end;

function TPasSourceManager.IndexesReady: Boolean;
begin
  Result := FSearchIndex <> nil;
end;

// The search-path indexes (FSearchIndex, FDcuIndex): one listing per path,
// kept with its stamp (see FPathListings) so BeginRun can re-list only what
// moved. Index-backed resolution is two dictionary lookups per candidate, no
// file syscalls.
procedure TPasSourceManager.EnsureSearchIndex;
var
  LListings: TArray<TArray<string>>;
  LStamps, LListedAt: TArray<TDateTime>;
begin
  if FSearchIndex <> nil then
    Exit;
  // Enumerate every search path CONCURRENTLY (a cold directory listing is
  // latency-bound, like a cold file read - see Prefetch) into per-path
  // slots; MergeSearchIndex then merges them in path order. One listing per
  // path serves both indexes.
  SetLength(LListings, Length(FSearchPaths));
  SetLength(LStamps, Length(FSearchPaths));
  SetLength(LListedAt, Length(FSearchPaths));
  TParallel.&For(0, High(FSearchPaths),
    procedure(AIndex: Integer)
    begin
      LStamps[AIndex] := DirStamp(FSearchPaths[AIndex]);
      LListedAt[AIndex] := Now;
      LListings[AIndex] := ListSearchPath(FSearchPaths[AIndex]);
    end);
  FPathListings := LListings;
  FPathStamps := LStamps;
  FPathListedAt := LListedAt;
  FListingsEpoch := FRunEpoch;   // just listed
  MergeSearchIndex;
end;

// FSearchIndex and FDcuIndex from FPathListings, merged SEQUENTIALLY in path
// order: first path wins, the priority the sequential probing loop had.
procedure TPasSourceManager.MergeSearchIndex;
var
  LFile: string;
  LIdx: Integer;
begin
  FreeAndNil(FSearchIndex);
  FreeAndNil(FDcuIndex);
  FSearchIndex := TDictionary<string, string>.Create;
  FDcuIndex := TDictionary<string, string>.Create;
  for LIdx := 0 to High(FPathListings) do
    for LFile in FPathListings[LIdx] do
      if HasExt(LFile, '.dcu') then
        FDcuIndex.TryAdd(
          PasFoldName(TPath.GetFileNameWithoutExtension(LFile)), LFile)
      else if HasExt(LFile, '.pas') then
        FSearchIndex.TryAdd(PasFoldName(TPath.GetFileName(LFile)), LFile);
  // The include index takes its own copy: the parse workers read it, and
  // refresh it on their own when a run finds a path moved
  // (EnsureIncludeIndexFresh) - never this driver-side state. Its names are
  // built lazily, by the first include that reaches step 3 (a cold client
  // analysis asks step 3 three times; the 20,000 names cost 24 ms on the
  // driver when built here).
  TMonitor.Enter(FIncludeLock);
  try
    FIncListings := Copy(FPathListings);
    FIncStamps := Copy(FPathStamps);
    FIncListedAt := Copy(FPathListedAt);
    SetLength(FIncListedAt, Length(FIncStamps));
    FIncCheckedRun := FRunEpoch;
    FreeAndNil(FIncNames);
    Inc(FIncGen);
  finally
    TMonitor.Exit(FIncludeLock);
  end;
end;

// Every file name of AListings, folded, to the first path holding it.
function BuildIncludeNames(const AListings: TArray<TArray<string>>):
  TDictionary<string, Integer>;
var
  LIdx: Integer;
  LFile: string;
begin
  Result := TDictionary<string, Integer>.Create;
  for LIdx := 0 to High(AListings) do
    for LFile in AListings[LIdx] do
      Result.TryAdd(PasFoldName(TPath.GetFileName(LFile)), LIdx);
end;

// The include index made ready for this run: its names built if they are
// not, and - once per run (FRunEpoch: only a new run can find the disk
// moved; a buffer is answered apart, IncludeFromIndex) unless the driver
// listed the paths in it already - checked against the search paths'
// last-write times, a moved path or one listed within RACY_PROBE of its time
// listed again. One worker does it, outside the lock; True when the index
// may answer, False while another worker is at it (the caller probes
// meanwhile) or before EnsureSearchIndex listed the paths.
function TPasSourceManager.EnsureIncludeIndexFresh: Boolean;
var
  LRun, LGen, LIdx: Integer;
  LCheck, LAny: Boolean;
  LListings: TArray<TArray<string>>;
  LStamps, LListedAt: TArray<TDateTime>;
  LNames: TDictionary<string, Integer>;
  LStamp: TDateTime;
begin
  TMonitor.Enter(FIncludeLock);
  try
    if FIncListings = nil then
      Exit(False);
    LRun := FRunEpoch;
    if (FIncCheckedRun = LRun) and (FIncNames <> nil) then
      Exit(True);
    if FIncBusy then
      Exit(False);
    FIncBusy := True;
    LGen := FIncGen;
    LCheck := FIncCheckedRun <> LRun;
    LListings := Copy(FIncListings);
    LStamps := Copy(FIncStamps);
    LListedAt := Copy(FIncListedAt);
  finally
    TMonitor.Exit(FIncludeLock);
  end;
  LNames := nil;
  LAny := False;
  try
    if LCheck then
      for LIdx := 0 to High(LStamps) do
      begin
        LStamp := DirStamp(FSearchPaths[LIdx]);
        if (LStamp = LStamps[LIdx]) and
           (LListedAt[LIdx] - LStamps[LIdx] >= RACY_PROBE) then
          Continue;
        LAny := True;
        LStamps[LIdx] := LStamp;
        LListedAt[LIdx] := Now;
        LListings[LIdx] := ListSearchPath(FSearchPaths[LIdx]);
      end;
    LNames := BuildIncludeNames(LListings);
  finally
    TMonitor.Enter(FIncludeLock);
    try
      // A driver-side merge since then is fresher than this: keep it, and
      // let the next include build its names.
      if (LNames <> nil) and (FIncGen = LGen) then
      begin
        if LAny then
        begin
          FIncListings := LListings;
          FIncStamps := LStamps;
          FIncListedAt := LListedAt;
          Inc(FIncIndexRefreshes);
        end;
        FIncNames.Free;
        FIncNames := LNames;
        LNames := nil;
        FIncCheckedRun := LRun;
      end;
      FIncBusy := False;
      Result := (FIncCheckedRun = FRunEpoch) and (FIncNames <> nil);
    finally
      TMonitor.Exit(FIncludeLock);
    end;
    LNames.Free;
  end;
end;

// The search paths' and the project directory's stamps against the ones the
// indexes were listed under, once per run and only when a resolution MISSES
// (ResolveUnit): a unit file created on disk is a name that did not resolve
// before, while a hit needs no check - 210 stats on the client closure were
// a fixed 18 ms on every keystroke run when this ran eagerly. A search path
// that moved is listed again (sequentially: the driver may hold the pool's
// threads in an engine). True when anything moved - the memoized
// resolutions derived from the old listings are then forgotten.
function TPasSourceManager.RefreshListings: Boolean;
var
  LIdx: Integer;
  LStamp: TDateTime;
begin
  Result := False;
  if FListingsEpoch = FRunEpoch then
    Exit;
  FListingsEpoch := FRunEpoch;
  if FSearchIndex <> nil then
  begin
    for LIdx := 0 to High(FSearchPaths) do
    begin
      if LIdx > High(FPathStamps) then
        Break;   // not listed by this manager: EnsureSearchIndex's business
      LStamp := DirStamp(FSearchPaths[LIdx]);
      if LStamp = FPathStamps[LIdx] then
        Continue;
      FPathStamps[LIdx] := LStamp;
      if LIdx <= High(FPathListedAt) then
        FPathListedAt[LIdx] := Now;
      FPathListings[LIdx] := ListSearchPath(FSearchPaths[LIdx]);
      Result := True;
    end;
    if Result then
      MergeSearchIndex;
  end;
  if FProjectDir <> '' then
    DirIndex(FProjectDir);   // checks its stamp, sets FMemoStale on a move
  Result := Result or FMemoStale;
end;

procedure TPasSourceManager.BeginRun(AFullRun: Boolean);
begin
  FreeAndNil(FContentCache);
  TMonitor.Enter(FIncludeLock);
  try
    FreeAndNil(FIncludeStreams);
    DropIncludeMemo;
  finally
    TMonitor.Exit(FIncludeLock);
  end;
  // Every listing is re-checked lazily against the disk in this run: a
  // directory index on its first use, the search paths on the first miss
  // (see DirIndex, RefreshListings).
  Inc(FRunEpoch);
  FreeAndNil(FPinnedSeen);
  if AFullRun and (FInPathPins <> nil) then
  begin
    if FPinned <> nil then
      for var LKey in FInPathPins.Keys do
        FPinned.Remove(LKey);
    FInPathPins.Clear;
  end;
end;

procedure TPasSourceManager.SavePins;
begin
  FreeAndNil(FSavedPins);
  FreeAndNil(FSavedInPath);
  if FPinned <> nil then
    FSavedPins := TDictionary<string, string>.Create(FPinned)
  else
    FSavedPins := TDictionary<string, string>.Create;
  if FInPathPins <> nil then
    FSavedInPath := TDictionary<string, Boolean>.Create(FInPathPins)
  else
    FSavedInPath := TDictionary<string, Boolean>.Create;
end;

procedure TPasSourceManager.RestorePins;
begin
  if FSavedPins = nil then
    Exit;
  FPinned.Free;
  FPinned := FSavedPins;
  FSavedPins := nil;
  FInPathPins.Free;
  FInPathPins := FSavedInPath;
  FSavedInPath := nil;
  FreeAndNil(FPinnedSeen);
end;

procedure TPasSourceManager.DropSavedPins;
begin
  FreeAndNil(FSavedPins);
  FreeAndNil(FSavedInPath);
end;

function TPasSourceManager.UnitAlias(const AName: string): string;
begin
  Result := '';
  if FAliases <> nil then
    FAliases.TryGetValue(PasFoldName(AName), Result);
end;

// The .dcu of a unit name, exactly as spelled: no leaf tolerance and no
// referring-directory probe - a compiled unit is a library artifact, and the
// library's directory is on the search path or the unit is not available.
function TPasSourceManager.FindDcuFile(const AUnitName: string;
  out AResolved: string): Boolean;
begin
  EnsureSearchIndex;
  Result := FDcuIndex.TryGetValue(PasFoldName(AUnitName), AResolved);
end;

class function TPasSourceManager.IsDcuPath(const APath: string): Boolean;
begin
  Result := HasExt(APath, '.dcu');
end;

function TPasSourceManager.DcuFailure(const APath: string): string;
begin
  Result := '';
  TMonitor.Enter(FDcuLock);
  try
    if FDcuFailures <> nil then
      FDcuFailures.TryGetValue(PasFoldName(TPath.GetFullPath(APath)), Result);
  finally
    TMonitor.Exit(FDcuLock);
  end;
end;

// A file's write time and size as one string, '' when it cannot be read:
// what tells a .dcu rebuilt during a session from the one its text came from.
function FileStamp(const APath: string): string;
var
  LRec: TSearchRec;
begin
  Result := '';
  if FindFirst(APath, faAnyFile, LRec) = 0 then
  try
    Result := Format('%.12f/%d', [Double(LRec.TimeStamp), LRec.Size]);
  finally
    FindClose(LRec);
  end;
end;

// Another unit's .dcu for DcuText's printer, shared (see FDcuUnits): read
// outside the lock, a racing reader's copy adopted and this one freed.
function TPasSourceManager.DcuForeign(const APath: string): TObject;
var
  LKey, LStamp: string;
  LHit: TPair<string, TObject>;
  LUnit: TPasDcuUnit;
begin
  LKey := PasFoldName(TPath.GetFullPath(APath));
  LStamp := FileStamp(APath);
  TMonitor.Enter(FDcuLock);
  try
    if (FDcuUnits <> nil) and FDcuUnits.TryGetValue(LKey, LHit) and
       (LHit.Key = LStamp) then
      Exit(LHit.Value);
  finally
    TMonitor.Exit(FDcuLock);
  end;
  try
    LUnit := LoadDcu(APath);
  except
    LUnit := nil;
  end;
  TMonitor.Enter(FDcuLock);
  try
    Inc(FDcuForeignLoads);
    if FDcuUnits = nil then
      FDcuUnits := TDictionary<string, TPair<string, TObject>>.Create;
    if FDcuUnits.TryGetValue(LKey, LHit) then
    begin
      if LHit.Key = LStamp then
      begin
        LUnit.Free;
        Exit(LHit.Value);
      end;
      if LHit.Value <> nil then
      begin
        if FDcuRetired = nil then
          FDcuRetired := TObjectList<TObject>.Create(True);
        FDcuRetired.Add(LHit.Value);
      end;
    end;
    FDcuUnits.AddOrSetValue(LKey, TPair<string, TObject>.Create(LStamp, LUnit));
    Result := LUnit;
  finally
    TMonitor.Exit(FDcuLock);
  end;
end;

procedure TPasSourceManager.FreeDcuUnits;
begin
  TMonitor.Enter(FDcuLock);
  try
    if FDcuUnits <> nil then
      for var LHit in FDcuUnits.Values do
        LHit.Value.Free;
    FreeAndNil(FDcuUnits);
    FreeAndNil(FDcuRetired);
  finally
    TMonitor.Exit(FDcuLock);
  end;
end;

// The interface source of a compiled unit, generated once per path and
// stamp. A failure is remembered for DcuFailure and re-raised: the caller's
// tolerant load path (TPasSemaProject.LoadFile) turns it into the
// importer's F1027, which then names this message. Both are kept for the
// manager's life (a demoted unit rehydrates from the text) under the file's
// stamp: a .dcu rebuilt since is read again, and its new text or failure
// replaces the old (audit B4-41).
function TPasSourceManager.DcuText(const APath: string): string;
var
  LKey, LMsg, LStamp, LOld: string;
  LUnit: TPasDcuUnit;
  LNotes: TArray<string>;
begin
  LKey := PasFoldName(TPath.GetFullPath(APath));
  LStamp := FileStamp(APath);
  TMonitor.Enter(FDcuLock);
  try
    if (FDcuStamps <> nil) and FDcuStamps.TryGetValue(LKey, LOld) and
       (LOld = LStamp) then
    begin
      if (FDcuTexts <> nil) and FDcuTexts.TryGetValue(LKey, Result) then
        Exit;
      if (FDcuFailures <> nil) and FDcuFailures.TryGetValue(LKey, LMsg) then
        raise EPasDcuError.Create(LMsg);
    end;
  finally
    TMonitor.Exit(FDcuLock);
  end;
  // Read and print OUTSIDE the lock (two workers racing to the same unit at
  // worst generate it twice; the loser adopts the winner's text). The unit
  // itself is this print's own - the printer writes to its constants - and
  // the units it imports from are the shared ones.
  try
    LUnit := LoadDcu(APath);
    try
      Result := DcuInterfaceSource(LUnit,
        function(const AForeign: string): TPasDcuUnit
        begin
          Result := TPasDcuUnit(DcuForeign(AForeign));
        end, LNotes);
    finally
      LUnit.Free;
    end;
  except
    on E: Exception do
    begin
      TMonitor.Enter(FDcuLock);
      try
        if FDcuFailures = nil then
          FDcuFailures := TDictionary<string, string>.Create;
        if FDcuStamps = nil then
          FDcuStamps := TDictionary<string, string>.Create;
        FDcuFailures.AddOrSetValue(LKey, E.Message);
        if FDcuTexts <> nil then
          FDcuTexts.Remove(LKey);
        FDcuStamps.AddOrSetValue(LKey, LStamp);
      finally
        TMonitor.Exit(FDcuLock);
      end;
      raise;
    end;
  end;
  TMonitor.Enter(FDcuLock);
  try
    if FDcuTexts = nil then
      FDcuTexts := TDictionary<string, string>.Create;
    if FDcuStamps = nil then
      FDcuStamps := TDictionary<string, string>.Create;
    if FDcuStamps.TryGetValue(LKey, LOld) and (LOld = LStamp) and
       FDcuTexts.TryGetValue(LKey, LMsg) then
      Result := LMsg   // a racing worker's copy of the same file
    else
    begin
      FDcuTexts.AddOrSetValue(LKey, Result);
      FDcuStamps.AddOrSetValue(LKey, LStamp);
      if FDcuFailures <> nil then
        FDcuFailures.Remove(LKey);
    end;
  finally
    TMonitor.Exit(FDcuLock);
  end;
end;

function TPasSourceManager.SearchPathUnitNames: TArray<string>;
var
  LPath: string;
  LIdx: Integer;
  LProject: TDictionary<string, string>;
begin
  if not FSearchNamesBuilt then
  begin
    FSearchNamesBuilt := True;
    EnsureSearchIndex;
    // The project directory first: ResolveUnit probes it before the search
    // paths, so a unit beside the .dpr that nothing imports yet is one a
    // `uses` can name (audit B4-40). A basename the paths hold too is listed
    // once.
    LProject := nil;
    if FProjectDir <> '' then
      LProject := DirIndex(FProjectDir);
    if LProject <> nil then
      SetLength(FSearchNames, LProject.Count + FSearchIndex.Count +
        FDcuIndex.Count)
    else
      SetLength(FSearchNames, FSearchIndex.Count + FDcuIndex.Count);
    LIdx := 0;
    if LProject <> nil then
      for LPath in LProject.Values do
        if not FSearchIndex.ContainsKey(PasFoldName(TPath.GetFileName(LPath))) then
        begin
          FSearchNames[LIdx] := TPath.GetFileNameWithoutExtension(LPath);
          Inc(LIdx);
        end;
    // The VALUES carry the original-case filenames; the keys are lowered.
    for LPath in FSearchIndex.Values do
    begin
      FSearchNames[LIdx] := TPath.GetFileNameWithoutExtension(LPath);
      Inc(LIdx);
    end;
    // A unit that exists only compiled is still a unit a `uses` can name.
    for LPath in FDcuIndex.Values do
      if not FSearchIndex.ContainsKey(
           PasFoldName(TPath.GetFileNameWithoutExtension(LPath)) + '.pas') then
      begin
        FSearchNames[LIdx] := TPath.GetFileNameWithoutExtension(LPath);
        Inc(LIdx);
      end;
    SetLength(FSearchNames, LIdx);
  end;
  Result := FSearchNames;
end;

procedure TPasSourceManager.ForgetUnitResolution;
begin
  FreeAndNil(FUnitMemo);
  FreeAndNil(FPinnedSeen);
end;

function TPasSourceManager.FromDirIndex(const AFromFile: string):
  TDictionary<string, string>;
begin
  // AFromFile = '' is legal (see ResolveUnit) and means no referring
  // directory: DirIndex('') is the empty index.
  if (FMemoFromIndex = nil) or (AFromFile <> FMemoFrom) then
  begin
    if AFromFile = '' then
      FMemoFromIndex := DirIndex('')
    else
      FMemoFromIndex := DirIndex(TPath.GetDirectoryName(AFromFile));
    FMemoFrom := AFromFile;
  end;
  Result := FMemoFromIndex;
end;

// ResolveUnit's search steps 2-7 for the lower-cased unit name AKey, with the
// referring directory's probes RECORDED (DirNames) instead of made - see
// TUnitMemo. Every lookup below is case-insensitive (lower-cased keys), so
// the lower-cased name answers for every spelling of it.
function TPasSourceManager.BuildUnitMemo(const AKey: string): TUnitMemo;
var
  LMemo: TUnitMemo;
  LName, LLeaf, LCand, LNs: string;
  LDot: Integer;

  // One candidate spelling (lower, no extension): project dir, search paths,
  // then - recorded - the referring dir.
  function Probe(const ABase: string): Boolean;
  var
    LFile: string;
  begin
    // SEARCH PATHS FIRST, referring directory only as a fallback. dcc-verified,
    // and the order matters more than it looks: with `b.pas` and `c.pas`
    // sitting together in one directory and ANOTHER `c.pas` earlier on the
    // search path, dcc compiles b against the search-path one - the importer's
    // own directory carries no priority at all. This is how a project SHADOWS
    // a third-party unit: it drops a patched copy into its own tree and puts
    // that directory first. Probing the referring directory first quietly
    // undid that, and the patched member then read as undeclared at every use
    // - reported, of course, in the patched file itself, three units away from
    // the actual mistake.
    //
    // The fallback stays because it is strictly more tolerant than dcc: a unit
    // reached from a directory NOBODY listed is an F1027 for dcc, and an F1027
    // here GATES its importers' diagnostics rather than reporting them.
    //
    // And before the search paths, the PROJECT DIRECTORY: dcc's implicit
    // current directory, ahead of every -U entry (dcc-verified: a Foo.pas
    // beside the .dpr beats the Foo.pas on the search path, no path entry
    // needed). The IDE compiles such a copy; this used to resolve the
    // library's.
    LMemo.Candidates := LMemo.Candidates + [ABase];
    LFile := ABase + '.pas';
    Result := ((FProjectDir <> '') and
        DirIndex(FProjectDir).TryGetValue(LFile, LMemo.Path)) or
      FSearchIndex.TryGetValue(LFile, LMemo.Path);
    if Result then
    begin
      LMemo.Found := True;
      LMemo.MatchIdx := High(LMemo.Candidates);
    end
    else
      LMemo.DirNames := LMemo.DirNames + [LFile];
  end;

  // AMemo with its path's key, the project's (LowerCase of the full path).
  function KeyedMemo(const AMemo: TUnitMemo): TUnitMemo;
  begin
    Result := AMemo;
    Result.PathKey := LowerCase(AMemo.Path);
  end;

begin
  EnsureSearchIndex;
  LMemo := Default(TUnitMemo);
  LMemo.MatchIdx := -1;
  // 2. Unit alias (dcc -A): a whole-name match rewrites the spelling before
  // any file lookup (WinTypes -> Winapi.Windows), exactly once (dcc does not
  // chain aliases).
  LName := AKey;
  if (FAliases <> nil) and FAliases.TryGetValue(AKey, LCand) then
    LName := PasFoldName(LCand);
  LDot := LastDelimiter('.', LName);
  if LDot > 0 then
    LLeaf := Copy(LName, LDot + 1, MaxInt)
  else
    LLeaf := LName;

  // 3. As spelled: <dotted>.pas on the search paths, then - beyond what dcc
  // accepts - relative to the referring file. See Probe for the order.
  if Probe(LName) then
    Exit(KeyedMemo(LMemo));

  // 4. Unit-scope namespaces (dcc -NS), IN ORDER, applied to the name AS
  // SPELLED - dotted or not. `uses Generics.Collections` with -NS System
  // resolves to System.Generics.Collections.pas, and there is no
  // Generics.Collections.pas anywhere, so the prefix is the ONLY way to find
  // it: dcc-verified, compiles with -NSSystem and cannot be explained by any
  // other rule here. This used to be gated on an unqualified name, which
  // refused exactly the example the comment cited. Real cost: 16 of the 27
  // unresolvable imports left on a 3789-unit project were this one line.
  //
  // Tried only AFTER the as-spelled lookup above, so a name that names a real
  // file (Vcl.Forms) can never be captured by a prefix.
  for LNs in FNamespaces do
    if (LNs <> '') and Probe(PasFoldName(LNs) + '.' + LName) then
      Exit(KeyedMemo(LMemo));

  // 5. Leaf-name tolerance for a dotted name (System.SysUtils -> SysUtils.pas
  // - pre-namespace-era file layouts).
  if (LDot > 0) and Probe(LLeaf) then
    Exit(KeyedMemo(LMemo));

  // 6. Unit index (basename fallback).
  if FUnitIndex <> nil then
    if FUnitIndex.TryGetValue(LName + '.pas', LCand) or
       ((LLeaf <> LName) and FUnitIndex.TryGetValue(LLeaf + '.pas', LCand)) then
    begin
      LMemo.Found := True;
      LMemo.Path := LCand;
      Exit(KeyedMemo(LMemo));
    end;

  // 7. No source anywhere: a compiled unit on the search paths, as spelled
  // and then with the namespace prefixes - what dcc itself compiles against
  // when a library ships .dcu only. See FDcuIndex for what happens next.
  LMemo.Found := FindDcuFile(LName, LMemo.Path);
  if not LMemo.Found then
    for LNs in FNamespaces do
      if (LNs <> '') and FindDcuFile(LNs + '.' + LName, LMemo.Path) then
      begin
        LMemo.Found := True;
        Break;
      end;
  if not LMemo.Found then
    LMemo.Path := '';
  Result := KeyedMemo(LMemo);
end;

function TPasSourceManager.ResolveUnit(const AUnitName, AInPath, AFromFile: string;
  out AResolved: string): Boolean;
var
  LKey: string;
begin
  Result := ResolveUnit(AUnitName, AInPath, AFromFile, AResolved, LKey);
end;

function TPasSourceManager.ResolveUnit(const AUnitName, AInPath, AFromFile: string;
  out AResolved, AKey: string): Boolean;
var
  LKey, LFile: string;
  LMemo: TUnitMemo;
  LFrom: TDictionary<string, string>;
  LLast: Integer;
begin
  LKey := PasFoldName(AUnitName);

  // 0. A unit already LOCATED for the project (see FPinned) - the program's
  // in-path or the project file's unit list - beats every lookup below, the
  // referring unit's own in-path included: dcc reports a unit found in two
  // places rather than resolving it twice, and the program's word wins. See
  // PinnedFile for a pin to a missing file.
  if PinnedFile(LKey, AResolved) then
  begin
    AKey := LowerCase(AResolved);   // a pin is full (PinUnit)
    Exit(True);
  end;

  // 1. Explicit `in 'path'`. Whatever it resolves to is pinned for the whole
  // project: the next importer of this unit gets THIS file, through every
  // spelling that reaches it - checked per candidate below.
  if ResolveInPath(AInPath, AFromFile, AResolved) then
  begin
    PinInPath(AUnitName, AResolved);
    AKey := LowerCase(AResolved);   // full (ResolveInPath)
    Exit(True);
  end;

  // 2-7. The search proper, answered once per unit name (see TUnitMemo);
  // only the pins and the referring directory's candidates are checked per
  // call.
  if FMemoStale then
  begin
    FreeAndNil(FUnitMemo);
    FMemoStale := False;
  end;
  if FUnitMemo = nil then
    FUnitMemo := TDictionary<string, TUnitMemo>.Create;
  if not FUnitMemo.TryGetValue(LKey, LMemo) then
  begin
    LMemo := BuildUnitMemo(LKey);
    FUnitMemo.Add(LKey, LMemo);
  end;
  // A miss may be a file created on disk since the listings were taken -
  // a unit copied in, checked out, written by an agent (audit A4-18): the
  // listings are checked once per run, and when one moved every memoized
  // answer is recomputed from the new ones.
  if not LMemo.Found and RefreshListings then
  begin
    FMemoStale := False;
    FSearchNamesBuilt := False;
    FUnitMemo.Clear;
    LMemo := BuildUnitMemo(LKey);
    FUnitMemo.Add(LKey, LMemo);
  end;
  // A pin answers for every candidate spelling up to the one whose file was
  // found, in probe order (spec 1.2.2): `uses Forms` under -NS Acme reaches
  // a pinned Acme.Forms ahead of the library's copy, `uses Foo` reaches it
  // through an alias, but a Forms.pas of its own on the path is found first.
  // Kept out of the memo, so a pin added later (a newcomer's in-path) needs
  // no memo rebuilt. Answered under the name as written only, an importer
  // that spelled the unit any other way bound the library's copy beside the
  // pinned one - two models of one unit (audit E4-01).
  if (FPinned <> nil) and (FPinned.Count > 0) then
  begin
    if LMemo.MatchIdx >= 0 then
      LLast := LMemo.MatchIdx
    else
      LLast := High(LMemo.Candidates);
    for var LIdx := 0 to LLast do
      if (LMemo.Candidates[LIdx] <> LKey) and
         PinnedFile(LMemo.Candidates[LIdx], AResolved) then
      begin
        AKey := LowerCase(AResolved);
        Exit(True);
      end;
  end;
  if LMemo.DirNames <> nil then
  begin
    LFrom := FromDirIndex(AFromFile);
    for LFile in LMemo.DirNames do
      if LFrom.TryGetValue(LFile, AResolved) then
      begin
        // The referring file's directory, full when the referring file is
        // - every TPasSemaProject caller's is; a host's may not be.
        AResolved := FullPathOrSelf(AResolved);
        AKey := LowerCase(AResolved);
        Exit(True);
      end;
  end;
  AResolved := LMemo.Path;
  AKey := LMemo.PathKey;
  Result := LMemo.Found;
end;

procedure TPasSourceManager.BuildIncludeIndex(const ARoot: string);
begin
  BuildIncludeIndex(ListFiles(FullPathOrSelf(ARoot), True, ['.inc']));
end;

procedure TPasSourceManager.BuildIncludeIndex(const AFiles: TArray<string>);
var
  LFiles: TArray<string>;
  LCount: Integer;
  LFile: string;
begin
  FreeAndNil(FIncludeIndex);
  TMonitor.Enter(FIncludeLock);
  try
    DropIncludeMemo;   // its misses may be hits now
  finally
    TMonitor.Exit(FIncludeLock);
  end;
  FIncludeIndex := TDictionary<string, string>.Create;
  // Full, as every index value here (a no-op for the root overload's
  // listing; a caller's listing may be of a relative root).
  SetLength(LFiles, Length(AFiles));
  LCount := 0;
  for LFile in AFiles do
    if HasExt(LFile, '.inc') then
    begin
      LFiles[LCount] := FullPathOrSelf(LFile);
      Inc(LCount);
    end;
  SetLength(LFiles, LCount);
  IndexByBaseName(LFiles, FIncludeIndex);
end;

{ Bytes -> string, tolerantly. A BOM is honored; a file without one is UTF-8 if
  its bytes ARE valid UTF-8, and ANSI otherwise.

  UTF-8-FIRST FOR PREAMBLE-LESS FILES, decided 2026-08-20 (the open question in
  the README, now closed). It used to default to TEncoding.Default - the system
  ANSI codepage - because that is what dcc does, and matching the compiler is
  the right instinct. It is the wrong answer here, for a reason that only became
  visible once an editor was hosting this library:

  - Every modern editor decodes a preamble-less .pas as UTF-8. This repository's
    own sources are UTF-8 with no BOM and full of em-dashes in comments, so the
    analyzer and the editor genuinely read DIFFERENT TEXT out of the same bytes:
    a 3-byte dash arrived as three ANSI characters. Every column on a line with
    a non-ASCII character before the identifier was then off by the byte
    inflation - silently, because nothing reports it. Navigation just lands next
    to the name, or inside the preceding string literal.
  - The two decodes disagreeing also defeated the LSP server's rebuild gate,
    which compares an editor buffer against the file's BYTES (a decode
    difference is not an edit). Sound as far as rebuilding goes, but it left the
    analysis holding its own ANSI reading of a file the editor had open, and no
    rebuild was ever due to correct it. That is not a host bug that can be
    worked around host-side: a host would have to re-decode every file the
    analysis reads.
  - What "matching dcc" buys is smaller than it looks. Identifiers are almost
    always ASCII, so the semantic model rarely differs; the difference is confined to
    the CONTENTS of string literals and comments - where dcc, reading UTF-8
    bytes as ANSI, produces mojibake. Reproducing that faithfully has no value
    to a caller, while the position skew costs correctness everywhere.

  Pure-ASCII files (the overwhelming majority) decode identically under both
  rules, so this is a superset of the old behaviour rather than a change of
  policy for them. A genuinely ANSI-encoded source - high bytes that are NOT
  valid UTF-8 - still falls back to ANSI, via the same recovery path below, and
  is still noted through AHow.

  THE FAILURE PATHS, which is where the subtlety always was. Delphi's
  TEncoding.UTF8 raises EEncodingError on a malformed sequence, and real sources
  contain them: one Windows-1252 apostrophe survives in a `///` comment in
  Alcinoe.FMX.Dynamic.Objects.pas, and dcc compiles that file without complaint.
  Two things must therefore hold.

  First, a file that DECLARED itself UTF-8 with a BOM is still UTF-8 - one bad
  byte is not a reason to reinterpret the whole thing as ANSI. It is decoded
  again with a LENIENT UTF-8 that substitutes U+FFFD for the bad sequence and
  leaves everything else intact, and that IS reported (PPENC), because the text
  may no longer be what the author wrote. A preamble-less file is the opposite
  case in both respects: its bad byte is EVIDENCE about the encoding, since
  nothing declared UTF-8, so it becomes ANSI - which is how a Windows-1251
  source still reads correctly - and nothing is reported, because nothing went
  wrong. See the end of the implementation.

  Second, and this was the actual bug: the fallback must skip the PREAMBLE.
  Decoding from offset 0 turned the three BOM bytes into text, so the file
  began with garbage instead of `unit`. The lexer rejected it at line 1, the
  parser produced a single node, the model came out EMPTY - and every unit
  that imported it lost every name it declared. One byte in a comment cost
  ~1700 false "undeclared identifier" reports on the Alcinoe package. }
var
  // The non-validating UTF-8 decoder: the lenient fallback for a file with a
  // UTF-8 BOM, and the decode of bytes IsValidUtf8 has already passed (the
  // strict TEncoding.UTF8 would validate them a second time, audit C2-22).
  // Stateless, so shared by every worker; created in initialization.
  GUtf8NoCheck: TEncoding;

class function TPasSourceManager.IsValidUtf8(const ABytes: TBytes;
  AStart: Integer): Boolean;
const
  cHighBits: UInt64 = $8080808080808080;
var
  LIdx, LEnd, LNeed: Integer;
  LB, LMin2: Byte;
begin
  LIdx := AStart;
  LEnd := Length(ABytes);
  while LIdx < LEnd do
  begin
    // Eight ASCII bytes at a time - nearly all of a source file (audit C2-22).
    if (LEnd - LIdx >= 8) and
      ((PUInt64(@ABytes[LIdx])^ and cHighBits) = 0) then
    begin
      Inc(LIdx, 8);
      Continue;
    end;
    LB := ABytes[LIdx];
    if LB < $80 then
    begin
      Inc(LIdx);
      Continue;
    end;
    // Lead byte -> continuation count, plus the range of the SECOND byte that
    // rules out overlong forms (E0, F0), surrogates (ED) and > U+10FFFF (F4).
    LMin2 := $80;
    case LB of
      $C2..$DF: LNeed := 1;
      $E0: begin LNeed := 2; LMin2 := $A0; end;
      $E1..$EF: LNeed := 2;
      $F0: begin LNeed := 3; LMin2 := $90; end;
      $F1..$F4: LNeed := 3;
    else
      Exit(False);   // C0, C1, F5..FF, or a stray continuation byte
    end;
    if LIdx + LNeed >= LEnd then
      Exit(False);   // truncated sequence
    if (ABytes[LIdx + 1] < LMin2) or (ABytes[LIdx + 1] > $BF) or
       ((LB = $ED) and (ABytes[LIdx + 1] > $9F)) or
       ((LB = $F4) and (ABytes[LIdx + 1] > $8F)) then
      Exit(False);
    if (LNeed >= 2) and ((ABytes[LIdx + 2] and $C0) <> $80) then
      Exit(False);
    if (LNeed = 3) and ((ABytes[LIdx + 3] and $C0) <> $80) then
      Exit(False);
    Inc(LIdx, LNeed + 1);
  end;
  Result := True;
end;

class function TPasSourceManager.DecodeBytes(const ABytes: TBytes;
  out AHow: string): string;
var
  LEnc: TEncoding;
  LStart: Integer;
  LDeclared, LValid: Boolean;
begin
  AHow := '';
  LEnc := nil;
  LStart := TEncoding.GetBufferEncoding(ABytes, LEnc, TEncoding.UTF8);
  // A preamble was found, so the file SAYS what it is; without one, UTF-8 above
  // is an assumption this may have to take back.
  LDeclared := LStart > 0;
  // Decided by a byte scan, NOT by letting the strict decoder raise: the
  // outcome is the same, but a raise per ANSI file is a first-chance stop in
  // the debugger on every one of them (a project with hundreds of Windows-1251
  // sources became unusable under the IDE that way, 2026-09-03) and an
  // exception's worth of time on a load path that is the closure's fixed cost.
  if LEnc.CodePage = CP_UTF8 then
  begin
    // Validated, it is decoded with no second validation by the strict
    // decoder; a declared UTF-8 that fails is decoded leniently, with no
    // error flags: substitute rather than raise.
    LValid := IsValidUtf8(ABytes, LStart);
    if LValid or LDeclared then
    begin
      Result := GUtf8NoCheck.GetString(ABytes, LStart,
        Length(ABytes) - LStart);
      if not LValid then
        AHow := 'UTF-8|leniently, substituting U+FFFD';
    end
    else
      Result := TEncoding.ANSI.GetString(ABytes, LStart,
        Length(ABytes) - LStart);
      // ...and NOTHING is noted for the preamble-less case - see below.
    Exit;
  end;
  try
    Result := LEnc.GetString(ABytes, LStart, Length(ABytes) - LStart);
  except
    // Kept for the non-UTF-8 preambles (UTF-16/32 are total decoders, but the
    // contract stays: a decode failure is never fatal to the load).
    on E: EEncodingError do
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
  LUnit: TPasDcuUnit;
begin
  // A host opening a compiled unit sees the same generated text the
  // analysis ran on - generated afresh here, since a class function has no
  // instance cache; it is one unit, on a user action.
  if IsDcuPath(APath) then
  begin
    LUnit := LoadDcu(APath);
    try
      Exit(DcuInterfaceSource(LUnit));
    finally
      LUnit.Free;
    end;
  end;
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
    // Never nil after Create. The guard covers a ZEROED instance only - a
    // DESTROYED one still holds the freed pointer (Destroy does not nil it),
    // so this is not, and cannot be, a use-after-free net.
    Exit;
  TMonitor.Enter(FRecoveredLock);
  try
    if FRecovered = nil then
      FRecovered := TDictionary<string, string>.Create;
    FRecovered.AddOrSetValue(PasFoldName(TPath.GetFullPath(APath)), AHow);
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
    FRecovered.TryGetValue(PasFoldName(TPath.GetFullPath(APath)), Result);
  finally
    TMonitor.Exit(FRecoveredLock);
  end;
end;

// One tolerant disk read (BOM honored; ANSI fallback on decode failure) -
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
  // Concurrent reads into per-index slots, sequential commit - no locks, and
  // the dictionary is never mutated while parse workers might read it. The
  // workers read raw BYTES only (one allocation per file): decoding to a
  // UTF-16 string doubles the memory traffic and, under
  // NeverSleepOnMMThreadContention=True, memory-manager contention across
  // many threads SPINS - 32 workers decoding multi-MB sources concurrently
  // spin-convoyed an 185-unit analysis into the 16-second range. Decoding
  // happens per-core in the parse workers instead (LoadText/DecodeText).
  SetLength(LBytes, Length(APaths));
  TParallel.&For(0, High(APaths),
    procedure(AIndex: Integer)
    begin
      try
        LBytes[AIndex] := TFile.ReadAllBytes(APaths[AIndex]);
      except
        LBytes[AIndex] := nil;   // unreadable - LoadText's disk path reports it
      end;
    end);
  for LIdx := 0 to High(APaths) do
    if LBytes[LIdx] <> nil then
      FContentCache.AddOrSetValue(PasFoldName(TPath.GetFullPath(APaths[LIdx])),
        LBytes[LIdx]);
end;

function TPasSourceManager.LoadText(const APath: string): string;
var
  LKey: string;
  LRaw: TBytes;
  LEntry: TBufferEntry;
begin
  LKey := PasFoldName(TPath.GetFullPath(APath));
  if FBuffers <> nil then
  begin
    if FBuffers.TryGetValue(LKey, LEntry) then
      Exit(LEntry.Text);
  end;
  // A compiled unit's "text" is generated from its declarations - checked
  // before the byte cache, which a Prefetch of the closure may have filled
  // with the binary.
  if IsDcuPath(APath) then
    Exit(DcuText(APath));
  if (FContentCache <> nil) and FContentCache.TryGetValue(LKey, LRaw) then
    Exit(DecodeText(LRaw, APath));
  Result := ReadFileText(APath);
end;

function TPasSourceManager.IncludeStream(const APath: string): TPasTokenStream;
var
  LKey: string;
begin
  LKey := PasFoldName(TPath.GetFullPath(APath));
  // An unsaved-buffer override changes per analysis - never share it.
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
  // workers racing to the same include at worst lex it twice - the loser
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
  FreeDcuUnits;
  TMonitor.Enter(FIncludeLock);
  try
    FreeAndNil(FIncludeStreams);
    DropIncludeMemo;
  finally
    TMonitor.Exit(FIncludeLock);
  end;
end;

function TPasSourceManager.ResolveInclude(const AUnitFile, AIncludingFile,
  AName: string; out AResolved: string): Boolean;
var
  LKey: string;
begin
  // The answer depends on the two files' DIRECTORIES only, so every unit of
  // a directory shares one entry per include (see FIncludeMemo). The key
  // holds each path up to its last separator - equal prefixes give equal
  // directories whatever TPath.GetDirectoryName makes of them, and unlike it
  // this cannot raise - kept as spelled, since the resolved path carries the
  // spelling of both.
  LKey := Copy(AUnitFile, 1, LastDelimiter('\/:', AUnitFile)) + #0 +
    Copy(AIncludingFile, 1, LastDelimiter('\/:', AIncludingFile)) + #0 +
    AName;
  TMonitor.Enter(FIncludeLock);
  try
    if (FIncludeMemo <> nil) and FIncludeMemo.TryGetValue(LKey, AResolved) then
      Exit(AResolved <> '');
  finally
    TMonitor.Exit(FIncludeLock);
  end;
  // Probe OUTSIDE the lock (file-system calls); two workers racing to the
  // same key compute the same answer. A raise (an unusable including path)
  // leaves no entry behind, so it raises again next time, as it always did.
  Result := ResolveIncludeIn(AUnitFile, AIncludingFile, AName, AResolved);
  TMonitor.Enter(FIncludeLock);
  try
    if FIncludeMemo = nil then
      FIncludeMemo := TDictionary<string, string>.Create;
    FIncludeMemo.AddOrSetValue(LKey, AResolved);
  finally
    TMonitor.Exit(FIncludeLock);
  end;
end;

// ResolveInclude's probing proper, unmemoized.
//
// dcc 37.0's order, probed (dcc32 and dcc64, an include named by the unit and
// one named by an include, plain and with a subdirectory): beside the UNIT
// being compiled, then the current directory, then -I, then the project
// file's directory - and never beside the include file that names it, nor on
// -U alone. PasTree's search paths are the IDE's -I (the IDE passes the one
// search path to -U, -I, -O and -R), the project directory stands for dcc's
// current directory (an IDE build runs in it; the .dpr's own place after -I
// is then the same directory). Beside the naming include comes last, a
// tolerance only: it finds a file where dcc says F1026, never another file
// than dcc's. The name is dcc's (PasIncludeFileName: `.pas` added to one with
// no extension); the bare name as written is a last tolerance after the whole
// sweep missed - again only where dcc says F1026 (audit E4-02 = E1-12). A
// file is one on disk or a host's unsaved buffer (SourceExists, as every unit
// gate asks; audit B4-39).
function TPasSourceManager.ResolveIncludeIn(const AUnitFile, AIncludingFile,
  AName: string; out AResolved: string): Boolean;
var
  LName, LBare: string;

  function TryDir(const ADir: string): Boolean;
  begin
    TInterlocked.Increment(FIncludeProbes);
    Result := TryIncludeFile(ADir, LName, AResolved);
  end;

  function Sweep: Boolean;
  var
    LCandidate, LUnitDir, LIncDir: string;
  begin
    Result := True;
    // 1. Beside the unit.
    LUnitDir := TPath.GetDirectoryName(AUnitFile);
    if TryDir(LUnitDir) then
      Exit;

    // 2. The project directory (dcc's current directory).
    if TryDir(FProjectDir) then
      Exit;

    // 3. Search paths.
    if SearchPathInclude(LName, AResolved) then
      Exit;

    // 4. Beside the include that names it - where dcc finds nothing.
    LIncDir := TPath.GetDirectoryName(AIncludingFile);
    if not SameText(LIncDir, LUnitDir) and TryDir(LIncDir) then
      Exit;

    // 5. Basename index (corpus fallback).
    if (FIncludeIndex <> nil) and
       FIncludeIndex.TryGetValue(PasFoldName(TPath.GetFileName(LName)),
         LCandidate) then
    begin
      AResolved := LCandidate;
      Exit;
    end;
    AResolved := '';
    Result := False;
  end;

begin
  AResolved := '';
  LBare := PasIncludeFileName(AName);
  LName := LBare;
  if not PathTextUsable(LName) then
    Exit(False);   // dcc says F1026 for a name no file can have
  if Sweep then
    Exit(True);
  LBare := Trim(AName);
  if (Length(LBare) >= 2) and (LBare[1] = '''') and
     (LBare[Length(LBare)] = '''') then
    LBare := Copy(LBare, 2, Length(LBare) - 2);
  if SameText(LBare, LName) then
    Exit(False);
  LName := LBare;
  Result := Sweep;
end;

// ResolveIncludeIn's step 3, the search paths in order. Their answer depends
// on the name alone, while ResolveInclude's memo is keyed by the unit's and
// the includer's directories too: every unit directory that missed steps 1
// and 2 probed every path again - one TFile.Exists per path, about 145 on the
// client (audit C2-23). Memoized by the name as spelled (#1 + AName in
// FIncludeMemo, so the same lock and the same lifetime: one analysis, dropped
// with every other include answer by BeginRun, SetBuffer, SetProjectDir...).
function TPasSourceManager.SearchPathInclude(const AName: string;
  out AResolved: string): Boolean;
var
  LKey, LDir: string;
begin
  LKey := #1 + AName;
  TMonitor.Enter(FIncludeLock);
  try
    if (FIncludeMemo <> nil) and FIncludeMemo.TryGetValue(LKey, AResolved) then
      Exit(AResolved <> '');
  finally
    TMonitor.Exit(FIncludeLock);
  end;
  AResolved := '';
  if not IncludeFromIndex(AName, AResolved) then
    for LDir in FSearchPaths do
    begin
      TInterlocked.Increment(FIncludeProbes);
      if TryIncludeFile(LDir, AName, AResolved) then
        Break;
    end;
  TMonitor.Enter(FIncludeLock);
  try
    if FIncludeMemo = nil then
      FIncludeMemo := TDictionary<string, string>.Create;
    FIncludeMemo.AddOrSetValue(LKey, AResolved);
  finally
    TMonitor.Exit(FIncludeLock);
  end;
  Result := AResolved <> '';
end;

// Step 3 from the include index: True when it answered (AResolved the file
// on the first search path holding it, '' when none does); False when it
// cannot - not built (no PrepareIndexes on this manager), a name with a
// directory in it, or a check of it in progress - and the paths are probed.
// A host's buffer counts as a file, as it does for a probe.
function TPasSourceManager.IncludeFromIndex(const AName: string;
  out AResolved: string): Boolean;
var
  LName, LKey, LBufDir: string;
  LIdx, LPath: Integer;
begin
  AResolved := '';
  if (AName = '') or (LastDelimiter('\/:', AName) > 0) or
     not PathTextUsable(AName) then
    Exit(False);
  if not EnsureIncludeIndexFresh then
    Exit(False);
  LName := PasFoldName(AName);
  TMonitor.Enter(FIncludeLock);
  try
    if (FIncNames = nil) or not FIncNames.TryGetValue(LName, LIdx) then
      LIdx := Length(FSearchPaths);
  finally
    TMonitor.Exit(FIncludeLock);
  end;
  if FBuffers <> nil then
    for LKey in FBuffers.Keys do
      if ExtractFileName(LKey) = LName then
      begin
        LBufDir := ExtractFileDir(LKey);
        for LPath := 0 to LIdx - 1 do
          if PathTextUsable(FSearchPaths[LPath]) and
             (PasFoldName(ExcludeTrailingPathDelimiter(
             TPath.GetFullPath(FSearchPaths[LPath]))) = LBufDir) then
          begin
            LIdx := LPath;
            Break;
          end;
      end;
  if LIdx < Length(FSearchPaths) then
    AResolved := TPath.GetFullPath(TPath.Combine(FSearchPaths[LIdx], AName));
  Result := True;
end;

function PasIncludeFileName(const AArg: string): string;
begin
  Result := Trim(AArg);
  if (Length(Result) >= 2) and (Result[1] = '''') and
     (Result[Length(Result)] = '''') then
    Result := Copy(Result, 2, Length(Result) - 2);
  if (Result <> '') and PathTextUsable(Result) and
     (TPath.GetExtension(Result) = '') then
    Result := Result + '.pas';
end;

initialization
  GUtf8NoCheck := TUTF8Encoding.Create(CP_UTF8, 0, 0);

finalization
  FreeAndNil(GUtf8NoCheck);

end.
