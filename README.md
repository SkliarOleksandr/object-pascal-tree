# PasTree

**A simple, extensible, multithreaded Object Pascal parser and semantic
analyzer — source in, AST + symbol table out — with a live editor host
(SynEdit syntax highlighting, IDE-parity go-to-declaration and
declaration↔implementation navigation) built on top of it.**

PasTree parses Delphi source files (`.pas`, `.dpr`, `.dpk`, with full `.inc`
support) into an abstract syntax tree, resolves and type-checks it into a
project-wide symbol model, and exposes both through a small VCL demo that
behaves like a slice of the real RAD Studio IDE. It targets the language as
implemented by **Delphi 13.x Florence** and specified by
[object-pascal-spec](https://github.com/SkliarOleksandr/object-pascal-spec) —
the companion specification this parser is built from.

> **Status: in progress.** Lexer, preprocessor, parser, and the semantic
> layer (cross-unit resolution, overloads, generics, `.dproj`-aware project
> loading) are all working end to end, and the demo already does real
> go-to-declaration and decl↔impl navigation over real projects (including
> the Delphi RTL/VCL) — with analysis now running fully asynchronously, so
> opening a project or editing a file never blocks the editor. See
> [To do](#to-do) for what's still open.

## Versioning

`PasTreeVersion` lives in `source/PasTree.Version.pas`. Two rules, and the same
two hold in the repository that builds on this one
([`pastree-lsp`](https://github.com/SkliarOleksandr/pastree-lsp) — the LSP
server and its clients, which share one version between them), counting its
own commits:

- **Every commit bumps the PATCH.** `0.2.1` → `0.2.2` → `0.2.3`, mechanically,
  no judgement call about whether a change "deserves" it.
- **A substantial change bumps the MINOR** and resets the patch: a new
  capability, a reworked subsystem, anything a consumer might reasonably need to
  *require*.

The per-commit patch bump exists so that a version identifies a **build**,
unambiguously. This library is linked into tools that get deployed and then
debugged from the outside — the LSP server reports `PasTreeVersion` in its
`serverInfo` precisely so a client can ask "does the analysis in this server
have the fix I need" — and a number that only moved on release could not answer
that.

Compatibility is expressed by the consumers rather than by this number: each
declares the oldest version of its dependency it works with
(`cMinPasTreeVersion` in the server, `cMinServerVersion` in the plugin) and says
so when the requirement is not met. Those constants move only when a real
dependency appears. Usually that means naming a MINOR — but not always, and the
exception matters: a resolver **fix** is a patch here and can still be a hard
requirement for a consumer, so a `cMin...` naming a patch version is correct,
not a mistake.

## What it does

1. **Parses** a unit into a full-fidelity syntax tree — every token and every
   piece of trivia (comments, whitespace, disabled `{$IFDEF}` regions) is
   preserved, so tokens + trivia reconstruct the source byte-for-byte. Parsing
   never fails: malformed input produces error nodes with diagnostics instead
   of aborting (an editor/LSP has to parse broken code all day).
2. **Resolves** a whole project's `uses` closure into a symbol model: scopes,
   declarations, cross-unit references, overload resolution, generic
   instantiation, and compiler-intrinsic/builtin handling (`Integer`,
   `TObject`, the implicit `System` unit) — modeled closely enough on `dcc`'s
   own rules to reproduce its precedence and its diagnostics.
3. **Drives an editor** (the VCL demo today, an LSP host later) with that
   model: real syntax highlighting, ctrl+click go-to-declaration, and a
   declaration↔implementation toggle, all reading the actual AST/symbol
   table instead of approximating with regex or heuristics.

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│ 1. SourceManager   files, encodings/BOM, text cache,        │
│                    .inc path resolution, .dproj parsing     │
├────────────────────────────────────────────────────────────┤
│ 2. Lexer           text → flat token array                  │
│                    (incl. directives and trivia)             │
├────────────────────────────────────────────────────────────┤
│ 3. Preprocessor    $IFDEF/$IF branching, $I splicing        │
│                    (include stack), option-state stack      │
│                    → visible token stream                   │
├────────────────────────────────────────────────────────────┤
│ 4. Parser          recursive descent + Pratt expressions    │
│                    → homogeneous AST                        │
├────────────────────────────────────────────────────────────┤
│ 5. Sema            per-unit scopes/symbols → cross-unit     │
│                    resolution → type checking → overloads/  │
│                    generics → project-wide diagnostics      │
├────────────────────────────────────────────────────────────┤
│ 6. Nav             pure lookups over the analyzed model:    │
│                    go-to-declaration, decl↔impl toggle      │
└────────────────────────────────────────────────────────────┘
```

Data model: index-based, allocation-friendly — tokens and nodes are records in
contiguous per-unit arrays (an arena per unit); references are integer
indices, not object pointers. Unit trees are immutable once built, which is
also what makes the parallelism below safe.

## Multithreading

Parsing and analyzing a unit is a pure function `(text, defines) → model`,
with no shared mutable state on the hot path, so a whole project's `uses`
closure fans out across cores instead of being processed one file at a time:

- **Parse + Phase 1** (lex → preprocess → parse → per-unit scopes/symbols)
  run one worker per core (`TParallel.&For`) over every file in the closure;
  results are registered back **in input order** afterwards, so model IDs stay
  deterministic regardless of which worker finishes first.
- **Cross-unit resolution** is split into a parallel *compute* step (every
  worker only reads other units' already-built reference maps) and a
  sequential *commit* step, so the one pass that has a true ordering
  dependency (dcc resolves inherited members before used units, before the
  implicit `System` unit) still runs safely without locking the hot read
  path. The few structures that genuinely need a lock (e.g. the shared
  generic-instance cache) are guarded explicitly; everything else relies on
  "workers only read, one thread commits."
- **Cold-start I/O is a separate pool from CPU-bound parsing.** A first
  analysis run pays for antivirus scan-on-first-touch and MFT lookups per
  file, which is a latency problem, not a throughput one — so file prefetch
  and the search-path index build use a deep-queue I/O pool (many reads in
  flight) that hands back raw bytes only, while decoding to text and parsing
  stays on the per-core CPU pool. Both pools are the shared default
  `TParallel` pool (machine-sized, already warm) rather than a private
  thread pool — an earlier custom pool caused `SetMaxWorkerThreads` to
  silently no-op below the machine's core count on higher-core machines.
- A `SingleThreaded` switch runs every stage on the calling thread instead,
  for baseline timing comparisons and debugging — results are identical
  either way, since the parallel stages are pure per unit.
- **The thread pool's width is pinned** (`TPasSemaProject.ConfigureThreadPool`,
  physical-core width by default). Left to grow, `TThreadPool` adds workers when
  it believes they are blocked — and it cannot tell blocking from the memory
  manager *spinning* on allocation contention, which every one of these passes
  produces in quantity. Measured, it added threads until the same work cost an
  order of magnitude more CPU **and** more wall time (2643 ms vs 1853 ms, ~20.5 s
  of CPU vs ~5.8 s). Wider is not faster here.

## Start from the spec

[object-pascal-spec](https://github.com/SkliarOleksandr/object-pascal-spec) is
the reference this parser is written against, not documentation written after the
fact. **Before fixing or adding anything, read the section that governs it and
work from there.** In order:

1. **Find the rule.** If the spec already states it, the fix follows its wording.
   A fix that needs *more cases than the spec has rules* is a signal you are
   patching symptoms — §5.7 says a `with` target is a structured-typed
   designator, one rule, while the implementation grew a case per shape.
2. **If the spec is silent, ask dcc, then write it down.** A probe compiled
   against `dcc32` settles it; the answer belongs in the spec in the same
   session, with the probe's shape as evidence. Otherwise the next person
   re-derives it.
3. **If the spec and the code disagree, do not assume the spec is right.** It is
   evidence, not scripture: §1.2.2 once cited `Generics.Collections` as the
   example for a rule that excluded dotted names — the example was right and the
   rule was wrong, and only dcc could say which. Correct whichever loses.
4. **Check before you write.** §13.1.4 already described default array
   properties, including the `default;` versus `default 0;` distinction, and was
   nearly duplicated by someone who fixed it first and read it after.

Reading first is usually *faster*, not slower: several fixes here were
re-derivations of something the spec already said in one line, and one of them
(`&Foo` and `Foo` being the same identifier, §B.3) would have gone straight to
the both-ends conclusion instead of half of it.

## Performance discipline

Every change ships with a timing run, not just a correctness run. This is not
advice; it is a rule the project learned twice the hard way, both times reported
by the user rather than caught by a measurement:

- a lock + string keys memoizing a member lookup cost **+16%** while the scan it
  memoized cost 4 ms;
- a defensive `PasNameKey` call added inside `FindLocal` — the hottest function
  in the analyzer — cost **3.3x total analysis time**.

Both passed every test. Diagnostic counts do not detect a slowdown.

**Before/after protocol**

1. `tools\out\PasTreeSemaProject.exe <corpus-dir>` over a flattened corpus, and
   read the `stages:` line — a total alone cannot tell you which phase moved.
2. Take the **best of 5** runs, never a single one. Machine noise on the
   665-unit corpus is roughly ±150 ms.
3. Compare against the *preceding commit*, rebuilt and run in the same session.
   A number from yesterday is not a baseline: it may itself contain a regression
   (one such stale figure sent an entire investigation at the wrong phase).
4. If a corpus count moves, confirm the analysis did not otherwise change:
   the tool's full dump should be byte-identical unless the change was meant to
   alter resolutions (`-st` versus parallel is the cheapest such check).
5. Say the honest size in the commit message, including when a change is
   *inside the noise* — a stage-level win that does not move the total should be
   described that way, so the next person does not over-credit it.

Build the suites with `-$R+ -$Q+` when anything looks flaky: the tool builds ship
without range checks, so an out-of-range index reads adjacent memory instead of
failing, which once presented as *non-determinism* (three different outcomes in
eight runs) rather than as the one-line bug it was.

## Asynchronous analysis

Opening a project, or editing a file, never blocks the editor: analysis runs
on a background worker while the previous (still-valid) model stays live and
usable.

- **Two-wave staged pipeline** (`TPasSemaProject.AnalyzeStaged`): wave 1
  parses every unit of the `uses` closure **interface-only**, breadth-first,
  with the open file's own direct dependencies front-loaded so they're ready
  first; wave 2 upgrades each unit to a full parse (revealing any
  implementation-only dependencies wave 1 couldn't see); a finalizer then
  runs the existing cross-unit passes over the whole closure. Each module
  tracks its own progress — `msQueued → msIntfReady → msFullReady →
  msCrossReady` — so a consumer can gate on "just enough" instead of waiting
  for everything.
- **Snapshot swap, not mutation.** A module's tree/model is an immutable
  snapshot; the interface→full upgrade parses a *new* tree — reusing the
  interface wave's own lexed/preprocessed token stream, not re-lexing — and
  atomically swaps it in. A reader always sees a complete snapshot, old or
  new, never a half-built one.
- **`TPasAsyncSession`** runs the whole pipeline on a background thread with
  double-buffered ownership: the host polls a lock-guarded progress snapshot
  (`phase done/total`, with total growing as the closure is discovered) and,
  once finished, swaps the built project in on its own thread — no shared
  mutable state between the worker and the UI to race. Cancellation is
  cooperative, checked between chunks/passes, so switching projects or
  closing the app never waits on a stale in-flight analysis.
- On a large real-world project, background analysis now runs at
  near-parity with the synchronous batch driver (~11s either way) after
  chunked parallel upgrading and reusing the interface wave's lex/preprocess
  pass in wave 2 — the two-wave split buys non-blocking, progressively-ready
  analysis without a meaningful throughput cost.

## Current features

- **Non-blocking background analysis** — opening a project or editing a file
  kicks off analysis on a worker thread (see [Asynchronous
  analysis](#asynchronous-analysis)); the demo shows live `phase done/total`
  progress and swaps in the finished model without ever freezing the editor.
- **Syntax highlighting for SynEdit** (`TPasTreeSynHighlighter`) — a real
  `TSynCustomHighlighter` driven by PasTree's own lexer/preprocessor/parser,
  not a regex approximation: keyword/identifier/number/string/comment/
  directive/BASM coloring, context-sensitive "weak keyword" coloring (`read`,
  `deprecated`, visibility words, routine directives, a package's `package` /
  `requires` / `contains`...) that only lights up where the AST actually proves
  them to be directives, `$IFDEF`'d-out code greyed out like the real IDE, and
  ctrl+hover link rendering.
- **Go-to-declaration** (ctrl+click) — parity target is "any identifier
  navigates exactly like the real IDE does," and the current matrix covers:
  local and cross-unit declarations, member access through inheritance/
  generics/aliases, the implicit `System` unit, compiler intrinsics with no
  source declaration (routed to `System.pas`'s header, like the IDE),
  `Result`, `uses` clause names and qualifiers, the whole project closure
  (not just the main file), units only reachable via the IDE's own registry-
  read library/browsing search paths, unit namespaces (`-NS`) and aliases
  (`-A`).
- **Include files open like anything else** — ctrl+click (and ctrl+hover's link)
  on the file name in an `$I` / `$INCLUDE` directive jumps into it, and
  **Open File at Cursor** (Ctrl+Enter, Delphi's own command, first in the
  editor's context menu) opens whatever the caret names: a `uses` item, an `$I`
  argument, a quoted path. Both ask the ANALYSIS before the filesystem, which is
  what picks the right `common.inc` when three copies sit on different search paths
  and what makes `uses Forms` open `Vcl.Forms.pas` through the namespace and
  alias rules; the filesystem fallback (the current file's directory, then the
  last analysis's search paths, then the name as written) still opens a file the
  analysis never reached. An `$I` argument is TRIVIA with no identifier and no
  AST node, so neither goes through the resolver — the span is a line scan
  (`PasTreeDemo.Includes`, 18 shapes pinned in `DemoSettingsSmoke`, including the
  three that must NOT match: `$I+`, `$I-` and `$I%`), and the link range is the
  directive's own raw token.
- **View Unit** (Ctrl+F12, the top toolbar, or the file tree's context menu) —
  a modal picker over the project's units: type to filter (substring, case-
  insensitive), Up/Down while the caret stays in the filter box, Enter or a
  double-click opens. Each row is two lines, the name over its directory,
  because the name alone stops being an identifier the moment the list widens:
  its **Implicit Units** box adds everything the finished analysis reached, and
  a real closure holds both `System.Types.pas` and `Vcl.Types.pas`. Names are
  deduplicated (a project copy wins over a library one — the same precedence
  the analysis itself applied), and the box is enabled from a LIVE query rather
  than a snapshot, since a background analysis can finish while the dialog is
  open. A status bar carries the counts and the project's name. The list and
  filter rules live in `PasTreeDemo.UnitList`, apart from the form and tested
  there (`UnitListSmoke`).
- **Declaration ↔ implementation toggle** (Ctrl+Shift+Down / Ctrl+Shift+Up) —
  jumps from a method or routine's forward declaration to its body's first
  statement and back to its name, overload-precise (matched by full
  parameter-type signature, not just arity), correctly handling comment-only
  bodies and refusing to cross from inactive `$IFDEF`'d-out code into active
  code.
- **Semantic diagnostics** — project-wide `E20xx`-style errors from a
  `.dproj`-aware loader (search paths, namespaces, unit aliases, platforms),
  validated continuously against the real Delphi RTL/VCL/FMX source tree.
  Opens a program or a **package**: `.dpr`, `.dpk` or `.dproj`, with a bare main
  source redirected to its sibling `.dproj` when there is one, so naming either
  file opens the same project. The packages this analyzer is measured against
  (`BuildWinRTL/VCL/FMX.dpk`) are the reason the `.dpk` half is not decoration.

## Layout

| Path | Contents |
|---|---|
| `source/` | the library: `PasTree.Types`, `PasTree.SourceManager`, `PasTree.Lexer`, `PasTree.Preprocessor`, `PasTree.Ast`, `PasTree.Parser`, `PasTree.DProj`, `PasTree.Platforms`, `PasTree.Ast.Json`, `PasTree.Project`, and the semantic layer `PasTree.Sema.*` (`Model`, `Resolver`, `Types`, `Project`, `Builtins`, `Nav`, `Async`, `Diagnostics`, `Dump`) |
| `source/PasTree.Version.pas` | this library's semver (`PasTreeVersion`), `CompareVersions`, and `BinaryBuiltOn`. Deliberately a standalone unit that pulls in nothing else, so a consumer can report which PasTree it is built against without linking the analysis machinery - which is how the LSP server can put it in its `serverInfo` |
| `demo/` | `PasTreeDemo` — a VCL host (SynEdit + VirtualTreeView) exercising the highlighter and navigation features interactively over real projects |
| `tests/` | 10 DUnitX-style smoke suites (`ParserSmoke`, `StagedParseSmoke`, `DProjSmoke`, `SemaSmoke`, `SemaTypeSmoke`, `SemaXTypeSmoke`, `SemaOverloadSmoke`, `SemaProjectSmoke`, `SemaNavSmoke`, `AsyncSmoke`) plus golden JSON trees and full-corpus runs |
| `tools/` | CLI drivers per pipeline stage (`PasTreeLex`, `PasTreePP`, `PasTreeParse`, `PasTreeJson`, `PasTreeSema`, `PasTreeSemaProject`) and the node-kinds generator |
| `docs/` | `editor-features.md` — the living IDE-parity spec for the demo's editor features |

## To do

Still open, roughly in the order we're tackling it:

- **Incremental reanalysis.** Every analysis today rebuilds the whole closure,
  and the LSP server (`c:\Repos\pastree-lsp`) has made the cost
  concrete: on the demo's own 197-unit closure a rebuild is **5.3 s**, and the
  server pays it for every real edit. The host side is already as good as it
  can get without library support — versioned overlay buffers, a 300 ms
  debounce, a background session, mid-pass cancellation, and a gate that skips
  rebuilding when a document's text does not actually differ from what was
  analyzed — so what remains is here. Measured split (the server logs
  `StageTimings`):

  | stage | demo closure | share |
  |---|---|---|
  | `intf` — interface-only closure parse | 1088 ms | 21% |
  | `full` — upgrade to full parse | 1418 ms | 27% |
  | `cross` — every cross-unit pass | 2757 ms | 52% |

  So parsing is only about half of it, which rules out "cache the parse" as a
  complete answer and splits the work in two.

  **A. Reuse the parse artifacts across analyses.** A cache keyed by (full
  path, content hash, define set, platform) handing back the parsed
  `TPasTree`; an unchanged unit is neither re-lexed nor re-parsed and can be
  registered straight as `msFullReady`, skipping BOTH waves. Worth ~48% (5.3 s
  → ~2.8 s on the demo), and it is sound by construction rather than by
  argument: **a tree is immutable once parsed** — the only `Tree :=` anywhere
  outside the parser is `PasTree.Project.pas`'s assembly of the parse result —
  so a shared tree cannot be corrupted by the model that borrows it. Two
  things it must respect: a unit whose preprocessing consumed the `$IF
  Declared(...)`/symbol oracle is NOT a pure function of its own text (that is
  exactly what `RunDeclaredPass` re-parses), so anything with a non-empty
  `Tree.Source.UnresolvedDeclared` or a recorded symbol question stays
  uncached — a dozen units in the whole RTL; and the cache owns the trees, so
  its lifetime must outlive any one project while the models only ever
  reference them (the ownership `TPasSemaModel` already documents).

  **B. Reanalyze ONE module.** This is the actual editor target — a keystroke
  inside a routine body should cost ~100 ms, not a closure rebuild — and it is
  structurally within reach, because the cross passes are already written as
  "one body per model" (`ForEachIndex` over `CrossResolve`, `CheckCalls`,
  `BindTypesX`, ...). What blocks it is that **symbol identity is an index**:

  - every other model's `ExtRefMap` holds `(UnitId, Sym)` pairs pointing into
    the edited unit, and `FInstances` / the helper index hold the same shape;
  - interface symbol indices are stable across a re-parse only while the
    interface TEXT is unchanged (the collect walk is deterministic), which is
    the common typing case but must be verified, not assumed;
  - implementation symbol indices shift on the most ordinary edit there is —
    adding a local variable — so any instance or helper entry that references
    an implementation-local symbol of that unit goes stale, and a stale
    instance index is silent corruption, not an error.

  Hence the shape: `AnalyzeModuleOnly(AId)` re-parses the file, then GUARDS —
  the interface symbol list (name + kind + order) must be unchanged, and no
  instance/helper entry may reference an implementation-local symbol of that
  model — and falls back to a full rebuild whenever a guard fails. Being
  unclever there is the whole design: a wrong fast path shows up as navigation
  that lands somewhere plausible but wrong, which is the hardest class of bug
  this project has. Also needed: per-model entry points for the passes that
  currently loop rounds over everything (`RunDeclaredPass`,
  `CrossResolveDecl`'s round loop, `RunInheritedPass`'s pending lists,
  `RunCrossTypePass`), and `PasTree.Sema.Async` needs a "reanalyze this
  module" mode for the host to drive it.

  The deliverable of B that matters is not the speed-up but the **differential
  harness**: run the full pipeline and the incremental one over the same edit
  sequence and compare RefMap, ExtRefMap and diagnostics across the entire
  closure. Without that, "it seems right on the demo" is not evidence, and the
  corpus suites only prove the FULL path still works.

- **A source with no BOM is decoded as ANSI, and every editor disagrees.**
  `DecodeBytes` defaults a preamble-less file to `TEncoding.Default` — the
  system ANSI codepage — because that is what dcc does, and matching the
  compiler is the right instinct. But every modern editor defaults to UTF-8,
  and THIS repository's own sources are UTF-8 without a BOM and full of
  em-dashes in comments, so the analyzer and the editor genuinely read
  different text out of the same bytes: a 3-byte UTF-8 dash arrives as three
  ANSI characters. Two consequences, both found while wiring the LSP server:

  - **Positions shift.** A column on a line that contains a non-ASCII
    character *before* the identifier is off by the byte inflation. Harmless
    on a comment-only line, wrong the moment code follows a non-ASCII string
    literal or comment on the same line — and invisible, because nothing
    reports it: navigation just lands next to the name.
  - **It looked like a performance bug.** Every such file appeared MODIFIED to
    a host comparing the editor buffer against a fresh load, which cost the
    server two full closure rebuilds per peeked declaration (~14 s) before it
    learned to compare bytes instead. That symptom is fixed host-side; the
    skew above is not, and cannot be — a host would have to re-decode every
    file the analysis reads to work around the library's own choice.

  What to decide (it is a behaviour decision, not a bug fix): whether a
  preamble-less file whose bytes are VALID UTF-8 should be decoded as UTF-8,
  falling back to ANSI only when the bytes are not valid UTF-8. That is what
  editors do, it is a superset of the current behaviour for pure-ASCII files
  (the overwhelming majority), and the tolerant recovery path already exists
  for the failure case. Against it: dcc really does read such a file as ANSI,
  so a source with an ANSI-encoded string literal would then analyze
  differently from how it COMPILES — which is the same fidelity argument that
  put ANSI there in the first place. If the answer is "match dcc", the
  alternative is to make it a switch the way `ReportUnresolvedMembers` is, so
  an editor host can opt into UTF-8-first while the CLI stays dcc-faithful.
  Either way the corpus needs a re-run: this changes what the analyzer reads.

- ~~**Overlay buffers and cancellation in the library facade**~~ — **Done
  2026-08-16**, the two preconditions for hosting PasTree out-of-process (the
  LSP server lives in `c:\Repos\pastree-lsp`, spec there). Most of it
  turned out to already exist: `SetBuffer` overlays were consulted before the
  Prefetch cache and the disk everywhere (LoadText AND IncludeStream), and
  `AnalyzeStaged` already polled its cancel predicate every 64-file chunk and
  between cross passes. What was actually missing and got added: (1) overlay
  buffers carry the HOST's version stamp (`SetBuffer` takes `AVersion`,
  `BufferVersion` reads it back through session → project → source manager),
  so an async host can recognize a result computed from older text; (2)
  cancellation now lands MID-PASS — `ForEachIndex` reads the running staged
  analysis's predicate and turns the rest of a pass into no-ops (safe because
  every commit loop already tolerated a nil/unset slot, the same shape as a
  worker that threw), plus checks in the sequential finalizer loops
  (ResolveUses, BindTypesX, after RunDeclaredPass and RunCrossTypePass) — a
  cancel no longer waits out a multi-second cross pass on a big project. The
  demo grew a **Stop** button that cancels the in-flight background analysis
  and logs it; the previous project stays live (double-buffering).
- ~~**An interface's implicit `IInterface` ancestor is not walked.**~~ **Done
  2026-08-06** — `FindMemberX` makes the same hop for a heritage-less interface
  that it already made for a heritage-less class (14 §14.1.1: the default
  ancestor is `IInterface`, or `IDispatch` for a dispinterface), so
  `with I do QueryInterface(G, O)` resolves. Worth recording that the audit
  predicted this hop would also clear the WinRT `_AddRef`/`_Release` flood and
  was WRONG about that — see the constraint entry below for what actually did.
- ~~**A third-party collections/DI library is a corpus now.**~~ **Clean since
  2026-08-05.** Three package projects of 73, 121 and 71 units, run like any
  `.dproj`. Its value was density — compiling projects of ordinary size that
  reported more than the 3747-unit client project does: **27 false diagnostics
  in the base package, now ZERO**, and 34 in the core package, now 2 — both of
  those the same honest `F1027`, and an instructive one. The core package sets
  `DCC_UnitSearchPath=..\..\Source` (not recursive) and reaches a unit one
  directory deeper through its `requires` of the base package; the source DOES
  exist in that tree. So a host that followed the `requires` closure to the
  required PACKAGE's own search paths would resolve it — the one concrete lead
  the source-less-units item below has.

  Four causes, all four fixed, and three of the four were "a name that is also
  something else" again:

  ~~The 19 `E2010 Incompatible types: 'Pointer' and '_nil'`~~ — **fixed
  2026-08-05, all 19 with one rule.** They were one cause, traced to its
  declaration site: its base unit declares a GENERIC record named `Pointer<T>`,
  and a bare reference to `Pointer` bound to it instead of to the builtin, so
  every `Pointer(X) := nil` and `Result := nil` in a `Pointer`-returning routine
  became a type error. **Arity is part of a type's identity** (§16.1.2), and the
  project pass already knew it for CROSS-unit references
  (`PreferNonGeneric`/`FindTypeInUsesArity`) — the resolver's own binding did
  not, so `RefMap` was wrong before any of that ran, which also sent ctrl+click
  to the generic. Now a name that lands on the WRONG arity keeps looking
  (`TPasSemaModel.ResolveByArityAt`): the same-scope chain, then joined scopes,
  then outward — the joined step being what reaches the SEEDED `Pointer`, a case
  §16.1.2 did not mention and now does. The guards are tested inline in that
  order, for the reason `PreferNonGeneric` documents: the common case pays one
  set membership and no call.

  ~~The 2 `E2015` on `not HasValue`~~ — **the same rule the other way round.**
  That base unit also declares `Nullable = record class var HasValue: string; end`
  beside `Nullable<T>`, whose `HasValue` is a Boolean property — so a parameter
  typed `Nullable<T>` was resolving to the arity-0 record and `not
  other.HasValue` became `not <string>`. §16.1.2 states both directions and the
  project pass had both (`FindTypeInUsesArity` takes an arity); the resolver now
  does too, which is why one function serves both.

  Two deliberate limits: with only the other arity in scope the binding is KEPT
  (dcc errors there, but dropping the reference would cost navigation for
  nothing), and an identifier inside `<...>` counts as bare, since
  `TDict<Pointer, TList>` means the arity-0 `Pointer`.

  ~~The 5 `E2004 Identifier redeclared`~~ — **a LEXER gap.** `class function
  &&op_Equality(...)` is how that library's `TValue` declares its comparison
  operators, and only the FIRST `&` escapes (B.3): the rest belong to the name,
  so `&&op_Equality` names `&op_Equality`, a different member from
  `op_Equality`. dcc-verified in both directions — it accepts the two in one
  record, and rejects `&op_Equality` beside `op_Equality` as a redeclaration, and
  it accepts `&&&op` too, so the escape is one `&` and not a pair. We emitted a
  stray `tkUnknown` for the second `&`, which derailed the whole class body: its
  parameters, result type and `static` were declared into the enclosing scope,
  and the next such declaration collided with them. `PasNameKey` already strips
  exactly one leading `&`, so the name key came out right the moment the token
  did. Across `3rdlib13` this removed 34 unknown tokens.

  ~~The 1 `E2003 MemoryBarrier`~~ — an unseeded compiler intrinsic, dcc-probed
  the way that seed list demands (a unit with an EMPTY uses clause resolves it),
  and a sibling of the `Atomic*` family already there.
- ~~**Unresolved MEMBERS after a dot are reported only behind a FLAG.**~~
  **Its work list is EMPTY as of 2026-08-07** — every RTL/VCL/FMX corpus reports
  zero, from 8 348 when the flag was new. The flag itself stays (see below: the
  LIBRARY default is off on purpose), and this entry stays with it because what
  the floods turned out to be is the useful part. `O.Read` where the class has no
  `Read` is `E2003` for dcc and silence for us; only unresolved BARE identifiers
  are diagnosed by the LIBRARY by default — and that default is deliberate:
  **error-tolerant is the analyzer's primary mode**, because that is what an
  editor embedding it needs, while a compiler FRONT END needs every unresolved
  name visible. The switch is what makes both modes available:
  `TPasSemaProject.ReportUnresolvedMembers`
  (`TPasAsyncSession.SetReportUnresolvedMembers` on the background path, CLI
  `PasTreeSemaProject -members`).

  **The demo turns it on unconditionally**, and there is no checkbox for it: this
  host's job is to show what the analyzer still gets wrong, and a switch that
  hides a real gap also hides progress towards closing it. *Show Errors* then
  means all of them, and stays a pure DISPLAY filter — toggling it re-filters the
  list instead of costing a re-analysis, which is what a control that changed the
  analysis would have cost (15 s on the client project). Until member binding is
  overload- and generic-aware, expect that list to be long and mostly binding
  gaps; the counts and their three causes are below.

  It reports at the single place a member
  reference is finally given up on — `CrossType`'s `nkMember` branch, after
  `RefMap`, `ExtRefMap` and `FindMemberX` have all failed, and only when the
  container type is KNOWN, the unit's `uses` all resolved, and the site is not in
  an unopened `with`. Off, the analysis is byte-identical.

  On, 2026-08-05, it was a **flood, and the shape of the flood was the
  finding** — three mechanisms, not hundreds of cases. **All three are closed
  now**, and what is left is a short tail of unrelated shapes:

  | corpus | 2026-08-05 | frames | + builtin helpers | + body constraints | + `Create`/`Free` | + seed shadowing | + alias identity | what is left |
  |---|---|---|---|---|---|---|---|---|
  | rtlflat (403) | 8 348 | 104 | 51 | 23 | 6 | 6 | **0** | — |
  | BuildWinRTL (317) | — | — | 51 | 23 | 5 | 5 | **0** | — |
  | BuildWinVCL (271) | — | — | | | | | **0** | — |
  | bigflat (726) | 8 638 | 387 | 194 | 162 | 136 | 110 | **0** | — |
  | BuildWinFMX (362) | — | — | | | | 89 | **0** | — |
  | client project (3747) | 3 609 | | | | | 824 | **7** | 5 charting-component `F1027` + 2 true positives |
  | server project (2121) | | | | | | 56 | **0** | — |
  | library, base (73) | 70 | 60 | 60 | 60 | 60 | 19 | **0** | — |
  | library, core (121) | | | | | | 27 | **3** | 2 honest `F1027` + 1 `AsType` |
  | library, data (71) | | | | | | 20 | **1** | the same honest `F1027` |

  **Every RTL/VCL/FMX corpus reports NOTHING under the member flag as of
  2026-08-07** — `rtlflat`, `bigflat`, and all three real packages. That is the
  same bar definition-of-done item 4 sets for `E2003`, now met by the opt-in
  check written to find what those corpora could not see.

  The VCL's last two were one rule: **writing the name of a parameterless
  function reference CALLS it**, so `ValueFunc.GetValue` on a `TFunc<IValue>`
  asks IValue for the member, not the closure (`System.Bindings.Outputs`,
  6 §6.6.1 — which stated the syntax and not this). The hop carries the
  instantiation frame, since `TFunc<TResult>` declares its result as a
  PARAMETER; a proc type with parameters and a `procedure` type both end the
  walk instead.

  **The server project, 2026-08-08: 56 -> ZERO.** Nine causes over two passes. The
  first four took it to 9, and the first of THOSE was not in the analyzer at
  all:

  - **the demo saw four IDE search paths instead of 141** — `StudioRoot`
    returned the registry's `RootDir` verbatim, trailing `\` and all, while
    `ExtraSearchPaths` matched it against the same value passed through
    `ExcludeTrailingPathDelimiter`. The two never compared equal, so every
    BDS version was skipped and the whole `Library`/`Browsing` set was lost —
    `Vcl.Forms` and every third-party unit came back as `F1027` on a
    project that compiles. A missing unit GATES its importers' diagnostics, so
    this one bug both invented reports and hid them.
  - **explicit generic-method type arguments** (~30 of the 56):
    `Unsafe.Cast<TSomeEdit>(Edit).ActiveProperties`. `InferMethodFrame`
    reads the frame off the ARGUMENTS, and a component suite's `Cast<T: class>(AObject:
    TObject): T` declares every parameter concretely — nothing to infer from,
    so the call stayed typed as the open `T`. `ExplicitMethodFrame` uses the
    written list, which 16.5.1 says wins outright; inference supplies only what
    was not written. Its other half: a call written `Name<...>` must skip a
    NON-generic of that name, or `TJSONObject.GetValue(Name)` swallows
    `TJSONValue.GetValue<T>(APath)` and the chain after it loses everything.
  - **a helper indexed under only one of its target's identities** (10):
    An editor component's helper unit writes `record helper for TRect` with
    `Winapi.Windows` last in its uses, so it registered Winapi's ALIAS, while
    another of its units declares `R: TRect` with `System.Types` in its
    implementation uses. Same type, different key, helper invisible.
    `BuildHelperMap.Publish` now indexes the whole plain-alias chain — the
    non-builtin twin of the per-model seed rule above.
  - **`inherited Name` where the class REDECLARES that name** (7):
    `inherited Alignment.Horz` in two of a suite's editor units, where the derived
    `Alignment` is an enum and the ancestor's is an object. The inherited pass
    only retries names that bound NOWHERE, so a redeclared one never reached
    it; the head of an inherited chain is now resolved from the ancestor in
    `CrossType` regardless of what it already bound to (12.1.2).

  The remaining 9 were five more, each a singleton or a pair, and four of the
  five are one theme — **a rule stated for the common case and never widened**:

  - **a `with` target indexed through a DEFAULT array property** (2, and a
    2447-report near-miss). `with Values[I - 1] do` over a TcxValuesViewInfo
    means its `property Values[Index]: TcxValueInfo ... default`, so the body
    opens the ELEMENT — the intra-unit resolver opened the COLLECTION, which
    also has a `Values` member, so `Values.Separator` bound to the element and
    lost `Separator` with no diagnostic anywhere near the cause. The
    pass-through it replaced is still right when the base designator IS an
    array property (its declared type is per-element already); getting that
    distinction wrong first cost 2447 reports from a single `.inc`, which is
    the amplification pattern in its purest form.
  - **`T.Create` under a bare `constructor` constraint** (1). Only a class can
    satisfy it — a record has no constructor to require — so it is a class
    constraint that additionally promises `Create`. Only `class` was
    recognised (`Atomic<I; T: constructor>`, a threading library).
  - **several constraints on one parameter** (2). `TKey: IComparable<TKey>,
    IEquatable<TKey>, IHashable` guarantees the members of ALL of them
    (16 §16.4.1); the hop took the FIRST, and a utility library calls `AKey
    .GetHashCode` (the third) and `A.Equals(B)` (the second) in adjacent
    methods.
  - **a parameterless-except-for-defaults function reference** (1).
    `TVTStyleServicesFunc = function(AControl: TControl = nil):
    TCustomStyleServices` is called by writing its name, so the rule is "no
    parameter the caller MUST supply", not "no parameters".
  - **a bare name used as a QUALIFIER** (1) means the PARAMETERLESS overload:
    an RPC library declares `function Add(anEntity): Integer` ahead of `function Add:
    TRODLEntity`, and `Add.Assign(...)` typed as Integer.

  Plus two last binding gaps: a bare reference to a same-named GENERIC keeps
  the intra-unit binding even when the arity says otherwise (`FCollection
  Enumerator: TCollectionEnumerator` declared inside `TCollectionEnumerator<T>`
  — the non-generic is System.Classes', and the resolver's own arity rule can
  only see one unit), and an alias to another class's NESTED type
  (`TNotify = TRESTComponentAdapter.TNotify`) had no definition at all, because
  nothing binds the last segment of a dotted nested name — `ResolveTypeExpr
  Nested` is the answer there, for the fourth time in a different function.

  **The client project, 2026-08-08: 824 -> 8, and only ONE of those eight is
  unexplained.** Five are the charting component's `F1027`s (it ships no `.pas`
  anywhere) and two are `InnerGetParentByType`, a confirmed true positive dcc
  reports too. Two causes covered 732 of the 816:

  - **the instantiation frame was dropped on the OVERRIDE path** (~700). The
    inherited pass carries a member's substituted type with it, because
    nothing downstream can recover which hop it came from — but only on the
    branch for names that arrived UNBOUND. A name that arrives BOUND is there
    to be overridden (a unit reference or a compiler seed), and that branch
    parked `XNil`. Invisible until a name was BOTH: `uses UITest.Params`
    registers the unit under `Params`, and `TUITest<TParams>.Params: TParams`
    is the member that outranks it — so every `Params.field` in the client project's UI
    tests typed as the OPEN parameter, fell back to its CONSTRAINT, and
    resolved the base params class's fields while failing on the actual one's.
    The symptom was only ever *which* field name was undeclared.
  - **a SAME-UNIT helper now hides the extended type's own member** (~60), the
    long-standing precedence gap this To-do listed. 15.3.3 says the helper
    wins; `JoinHelperScopes` joined it as an ordinary fallback, so
    `FindLocalDeep` found the type's own first. Scopes grew a `Shadowing` list
    searched BEFORE their own names, and helper injection is its only user —
    everything else joined there (uses, with, ancestors, enums) is genuinely a
    fallback. A suite's rich-edit units are what need it: a `class
    helper for TTagBase` there redeclares `Importer` at the DERIVED importer type,
    and the whole HTML importer reads members off that.

  The last one closed the same day and was **not** the helper it looked like.
  A component suite's layout-unit converter declares `LayoutUnitsToPixels` for TSize,
  TPoint and TRect at one arity; `XSameType` compares SYMBOLS, and the
  argument's `TRect` and the parameter's `TRect` are read in different units,
  so all three candidates scored 0 and the FIRST — TSize — won the tie. The
  call then typed as TSize, and nothing said so until `.ToRectF` was read off
  it two units away. Two changes: argument and parameter types are
  canonicalized through their plain alias links before comparison
  (`CanonTypeX`, the non-builtin twin of the seed canonicalization the helper
  index does), and — the first crack in "ScoreCandidate never REJECTS" — two
  DIFFERENT record types now reject the candidate outright. That corner is
  decidable where the general rule is not: distinct records are not assignable,
  and the one thing that could make them so, a `class operator Implicit` or
  `Explicit`, is a MEMBER and can be looked for.

  **The third-party library, 2026-08-08: base 19 -> 0, core 27 -> 2, data
  20 -> 1 — and all three left are the honest `F1027` above.** Three causes,
  every one a rule that was right for the single shape it was written against
  and had never met a second:

  - **16.1.2 by COUNT, not just generic-vs-not** (16 of the data package's 20).
    The intra-unit arity rule asked one question — is the name
    written with type arguments or not — and `TNodes<T>` and `TNodes<TKey,
    TValue>` are BOTH generic. Only a name's head is registered, so
    `TNodes<TKey, TValue>.PNestedRef` bound the arity-1 declaration's
    nested type, and both arities declare that name. The wrong node record
    differs from the right one in exactly one field (`fKey` where the other has
    `fPair`), which is the whole reason it went unnoticed for so long: nothing
    fails until a field is read. Same NextOverload walk the
    qualified-implementation-name case already did.
  - **a helper's ANCESTOR helper** (2 in the core package). `class helper (X)
    for T` (15.3) inherits X's members, and since at most ONE helper is active
    per type, the derived one is the only route to them. One of its units
    declares `TRttiMethodHelper = class helper(<its base unit's own helper>) for
    TRttiMethod`; a unit using only the base resolved `ReturnTypeHandle` and one
    using both did not — **adding a used unit REMOVED members.**
    `HelperMemberHit` now walks that chain, still reading helper member scopes
    only, so a malformed helper graph cannot cycle.
  - **an ARRAY parameter meeting a record/class/interface argument** now rejects
    the candidate — the third narrow bite out of "`ScoreCandidate` never
    REJECTS". A binding stops at the FIRST declaration of a name, and there a
    derived interface declares only the `TArray<T>` overload of a method while
    INHERITING the single-item one: the array overload was the only candidate,
    fitted on arity, and typed the call as `TArray<...>`. Rejecting it is what
    lets the existing "nothing in the type's own chain fits, so this means an
    INHERITED routine" fallback do its job.

  FMX's 89 were four shapes, and all four are about **what a QUALIFIER means**:

  - **a NESTED type as a type ARGUMENT** — `TDispatchMessageWithValue<
    TCustomMemoModel.TLineInfo>`, where nothing binds that last segment
    cross-unit this early (the same gap a HERITAGE reference has, and the same
    helper answers it). Losing one argument loses the whole instantiation
    FRAME, and with it every member of a field typed by the parameter: **82 of
    the 89** were `Message.Value.<anything>` through this one miss.
  - **a NESTED type as a member QUALIFIER** — `TObjectAppearance.TDataMembers
    .Create(...)`, where that nested name is an alias of `TArray<TDataMember>`.
    A dotted name binds on its LAST SEGMENT, so the "is this a type?" test read
    nothing off the `nkMember` node and the dynamic-array pseudo-constructor did
    not apply. Third time that particular lesson has been learnt this week.
  - **the re-export idiom, `X = X`** (2 §2.5.1, written up from this): the right
    side means the OUTER X, since a declaration cannot alias itself. Bound to
    itself instead, the alias is a type whose definition is itself — no
    diagnostic, and every member reached through it simply absent. FMX does this
    twice, and the resolver now resolves such a right side with the symbol being
    declared excluded.
  - **a member NAME that collides with a compiler SEED** — `Model.Text`, where
    `Text` is the predefined FILE type. A seed is never anyone's member, so a
    binding that says otherwise is corrected rather than trusted. This is the
    member-side twin of the seed-shadowing fix above, and it needed its own rule
    because a member name is resolved through its qualifier and so never reaches
    the pass that fixed the bare-name side.

  The seed-shadowing column is the one to read carefully: it changed 14 of
  rtlflat's dump lines and none of its six reports. A wrong binding costs no
  diagnostic — that is the whole reason this table cannot be the only
  measurement.

  The last two causes, both found by running the RTL package once the tail was
  short enough to read:

  - **a builtin type has several NAMES, and a helper targets the type.**
    `TUInt32Helper = record helper for UInt32` (System.Classes) must answer for
    a value declared `Cardinal`; dcc-probed, a Cardinal helper applies to
    `Cardinal`, `LongWord` and `UInt32` alike and is `E2671` on an `Integer`.
    Two halves: follow a plain alias (`UInt32 = Cardinal`) to what it names, and
    group the separately-seeded names by hand (`PasBuiltinAliasGroup`).

    The measurement earned its keep immediately: the first version registered
    `TEditMask = type string`'s helper under `string` too and **added 17 false
    reports** while removing 14, because `= type` declares a DISTINCT type and
    at most one helper is active per type (15 §15.3.3) — so it HID
    TStringHelper across FMX.MaskEdit. The parser marks that form with `Aux = 1`
    on the `nkTypeDecl`, which is the whole difference between the two.
  - **a generic METHOD's constraints are on its own declaration** (16 §16.2.1),
    where the body repeats a bare `<T>` exactly as a generic type's does.
    `System.Rtti.GetNamedObject<T: TRttiNamedObject>` calls `Obj.HasName` in its
    body — the RTL's last two member reports. The parsing detail that decides
    it: an implementation name is a FLAT run of segments, each able to carry its
    own parameter list, so the owner of a list is the segment immediately before
    it. Taking the first segment answers with the CLASS's name, which is what
    the first attempt did.

  The three mechanisms named when the flag was new, each one gap rather than
  hundreds:

  - ~~**a generic ANCESTOR's member typed by its parameter.**~~ **Fixed
    2026-08-06 — and it took the two flat corpora from 8 300 / 8 590 reports to
    104 / 387.** 535 `CreateInstance` + 134 `CreateInstanceWithOwner` + hundreds
    of `get_XxxProperty` in the WinRT units are all `Statics.X` where `Statics`
    comes from `TWinRTGenericImportS<S>` and its type IS `S`.

    Both mechanisms the diagnosis had suspected really were present, as the
    previous session's narrowing said: `AncestorOfX` composes frames,
    `ResolveTypeExpr`'s `nkTypeArgs` branch creates one for a heritage
    reference, and the two-unit fixture proved it end to end — the inherited
    pass typed bare `Statics` as the ARGUMENT (`IController`), frame and all.
    **The loss was one node later.** `CrossType`'s `nkIdent` branch types an
    identifier from `RefMap`/`ExtRefMap` — the member's DECLARED type, which for
    this shape is the open `S` — and never looked at `ExprTypeX`, where the
    inherited pass had already parked the frame-substituted answer. So the next
    dot searched an open parameter and gave up. The branch now prefers that
    answer, gated on what it computed being an open parameter (or nothing), so
    the common identifier still costs no dictionary lookup on that hot path.

    The general lesson is the one `TPasInhPending.X` already states and this
    walk did not honour: **a frame cannot be recovered downstream** — nothing at
    a node says which hop its member came from — so wherever one pass computed a
    type WITH a frame, a later pass must read that type rather than re-derive it
    from the declaration.

    Measured: no honest diagnostic moves (rtlflat 0, bigflat its 9 known
    `F1027`s, that library's base package 0, suites 859), the only dump lines that change are
    the `refs:`/`typed exprs:` summaries, unresolved references drop by 8 203 on
    rtlflat and 8 236 on bigflat, and the clock is unchanged (966–1 000 ms
    rtlflat, ~1 960 ms bigflat, both before and after).
  - ~~**helpers on a builtin-typed value.**~~ **Fixed 2026-08-06 — rtlflat 104 →
    51, bigflat 387 → 194.** `Trim`, `StartsWith`, `ToLower`, `IsEmpty`,
    `Length`: `TStringHelper`/`TCharHelper` members reached through a chain.

    **A builtin type has no single identity** — every model SEEDS its own
    `string`, so which symbol a value carries depends on where its type was
    read. `S.Trim` on a local worked (this model's seed, which is exactly what
    `BuildHelperMap`'s `Publish` indexes), while `UpperCase(S).Trim` carried
    System.SysUtils' seed and `Give(S).Trim` a third unit's, and both missed a
    helper that was active, correctly registered and looked up by the right
    name. Four probe lines in one program separated those cases in a minute,
    which is worth more than the fix: the corpus reports named `Trim` and
    `ToLower` and said nothing about WHICH `string`.

    `HelperMemberHit` now canonicalizes to the referring model's own seed and
    probes once more. Both guards keep it off the hot path — the retry runs only
    for a `skBuiltinType` that came from ANOTHER model, and only after the
    ordinary integer-keyed probe missed. Registering every model's seed up front
    was the alternative and is quadratic; this pays a name lookup on a miss
    instead. Clock unchanged (1 962–1 971 ms on bigflat over three runs).

    What the leftovers turned out to be is worth the next session's attention:
    `Text.IsEmpty` in the FMX canvas units is **not** a helper gap at all —
    `Text` is a seeded builtin (the FILE type, 10.3) and it beat the enclosing
    class's own `Text` property, so the base is typed as a file. That is the
    "a name that is also something else" family again, and this time it is a
    WRONG BINDING rather than a missing one.
  - ~~**`_AddRef` / `_Release` / `QueryInterface`**~~ — **fixed 2026-08-06, and
    NOT by the `IInterface` hop the audit predicted** (that hop was already
    there). The real cause is one line up: `System.Win.WinRT` declares
    `class var FFactory: F` with `F: IInspectable`, so the walk arrived at a
    generic PARAMETER and stopped, having no rule for one. 16 §16.4.1 says what
    it should do — a value typed by an unbound parameter has the members its
    CONSTRAINT guarantees — and from `IInspectable` the existing interface hop
    reaches `IInterface` and those three names. 48 reports gone (all `_AddRef`
    and `_Release`, 39 of 40 `QueryInterface`), the frame is deliberately dropped
    on the hop because a constraint is written in the DECLARING scope.

    ~~The surviving `QueryInterface` is a different shape still to look at.~~
    **It was the same rule, one scope out — fixed 2026-08-06, rtlflat 51 → 23
    and the whole `System.Net.Mime` cluster with it.** The constraint hop read
    the parameter's OWN `nkGenericParam` group, and a method BODY's `<T>` has no
    constraints in it: 16 §16.4.1 puts them on the declaration and dcc REFUSES
    them on the implementation header (`procedure TListBase<T>.Add;`). So the
    hop worked exactly where constrained parameters are rarely used and failed
    where they always are — `TAcceptValueListBase<T: TAcceptValueItem,
    constructor>` accounted for 26 of the RTL package's 51 reports on its own,
    every one of them `LItem.FWeight` / `LItem.Parse` / `T.Create` inside a
    method body.

    `ConstraintOfParamX` now falls back to the DECLARING type's same-named
    parameter. Two details are load-bearing: the link is the parameter SYMBOL's
    scope chain and not the node's (a header's generic-parameter idents are
    declared into the routine scope but never stamped into `NodeScope`, so
    `StructSymOfNode` had nothing to walk), and parameters are matched by NAME,
    so a body that renames them finds nothing rather than the wrong constraint.
  - ~~**`Create` and `Free`, the tail after those three.**~~ **Fixed 2026-08-06 —
    rtlflat 23 → 6, the RTL package 23 → 5.** Two unrelated rules wearing one
    pair of names, and the spec had neither, so both were settled by dcc probes
    and both are now written down (§8.2.3 is new; §16.4.1 grew the table):

    - **`T: class` guarantees TObject's members.** §16.4.1 listed the constraint
      KINDS and never said which members each makes reachable, which is the only
      question a member lookup asks. `V.Free` compiles under a bare `T: class`
      and is `E2003` under `T: record` or a lone `T: constructor` — so exactly
      one kind keyword answers a type, and `TObjectList<T: class>.Notify`'s
      `Value.Free` was the RTL's whole `Free` bucket.
    - **A dynamic array type has a `Create` pseudo-constructor.** `TBytes
      .Create($EF, $BB, $BF)` builds the array and no `Create` is declared
      anywhere — there is no member to bind, so this is typed (as the array,
      like any constructor) and deliberately left unbound. The two negatives are
      what make it safe, and both are dcc's: a STATIC array and a VARIABLE
      qualifier are `E2671`. Aliases hide the shape (`TBytes` is `TArray<Byte>`
      is `array of T`), and the seeded `TBytes`/`TArray` have no declaration at
      all, so the test follows the alias chain and answers from the seed's
      category when it runs out.

  One refinement the flag earned immediately: **a member on a `Variant` is never
  reported**, because late binding makes any name compile and dcc checks nothing
  — 312 `ActiveWorkbook` and 94 `Worksheets` on one real project, 740 reports in
  total, all from OLE automation. That rule is in the check now.

  So the flag did its job: it converted "the corpora say nothing about
  member-lookup completeness" into three named mechanisms and a number to beat,
  and two days later all three are closed and the number is 51 / 194. The demo
  runs with it on for exactly that reason — the number is the work list, and a
  host that hides it cannot show the list shrinking. The LIBRARY default stays
  off until those numbers are near zero, because an editor embedding PasTree
  should not inherit a work list as diagnostics.

  What is left on rtlflat is six reports: `HasName` ×2, `FromBytes` ×2,
  `ToString`, `Wrap`. bigflat's 136 are a longer tail of the same kind, led by
  `Index` (20), `Length` (15) and the `Text` binding bug below. There is no
  bucket left to name — from here it is one site at a time.
- ~~**Inline `var`/`const` visibility is not POSITIONAL.**~~ **Done 2026-07-31**
  (`TPasSemaModel.ResolveAt`/`DeclaredAfter`) — the entry outlived the fix and is
  corrected here on 2026-08-07, the second one in this list to do that. 3 §3.1.3
  scopes an inline variable "from its declaration to the end of the enclosing
  block", and only a REFERENCE lookup consults the position, for `sckBlock`
  scopes alone, so everything the language keeps order-independent stays that
  way. The comparison is on the visible-stream token index, monotonic in source
  order across include boundaries.

  Re-probed against dcc32 37.0 on 2026-08-07, five shapes, and we match on all
  five: a reference above the declaration binds OUTWARD (`E2010`), an inline
  var's own INITIALIZER still sees the outer name (`var GX: Integer := GX + 1`
  compiles), a nested block's inline name does not leak out, inline `const`
  follows the same rule, and with no outer name at all the earlier reference is
  `E2003`.

  One dcc diagnostic we do NOT emit, and it is a missing check rather than a
  wrong binding: dcc adds `E2004 Identifier redeclared` at the inline
  declaration when a reference above it already resolved the name in that block.
  Belongs with the other missing checks below if it is ever worth having.
- ~~**Member visibility is recorded but not ENFORCED.**~~ **Both halves are done
  — recording 2026-07-31, enforcement 2026-08-05, and its tail worked down to
  TWO reports on 2026-08-07** (from 546 / 998). What is still deliberately
  absent is named at the end of this entry: `protected` (`E2362`, needs an
  ancestry walk) and the BARE-name half, which dcc reports as `E2003` and which
  therefore belongs in the member walk rather than in a check after it.
  Recording landed on
  2026-07-31 — `CollectStruct` tracks the section as it walks and stamps every
  symbol a child declares, `automated` included (kept distinct from
  `published`). Members before any section marker stay `svDefault` rather than
  taking a guess: the real default is `published` under `{$M+}` and `public`
  otherwise, which depends on a directive AND on the ancestry.

  **Enforcement landed 2026-08-05 as an opt-in** —
  `TPasSemaProject.ReportVisibility`, CLI `-visibility`, default OFF, with the
  analysis byte-identical when off. It covers a QUALIFIED access to a `private`
  or `strict private` member, reported as dcc spells it: `E2361 Cannot access
  private symbol TType.Member`. Every rule was probed, and the two that keep
  code LEGAL matter most: `private` is visible to the whole declaring UNIT (the
  "friend" rule), so `A.FPriv` from a sibling class one line below is fine and
  enforcing per-type would reject correct code everywhere; `strict private` is
  refused even there. Both directions are pinned in `SemaProjectSmoke`.

  **Its first measurement found a BINDING bug rather than visibility errors —
  546 reports on rtlflat, 998 on bigflat — and fixing that took it to 170 and
  261.** The top names gave it away: `Exception.Create` (475 on bigflat),
  `TMonitor.Enter`/`Exit`, `TThread.Synchronize` — each of those types declares a
  PRIVATE member of that name beside the PUBLIC one people call (`Exception` has a
  private `class constructor Create` at the top of its private section and the
  public `constructor Create(const Msg: string)` fifteen lines below). The
  argument-matched overload was already being SELECTED for every call and recorded
  in `CallTargetX` for navigation — but `RefMap`/`ExtRefMap` still held the chain
  HEAD, so anything reading a binding saw the first candidate. Two changes, both
  2026-08-05:

  - **the callee's binding is re-pointed to the selected overload**
    (`RepointCallee`, same discipline as `CheckCalls`' own re-point: own model's
    `RefMap` directly, another model's through the deferred dictionary). The maps
    now agree with `CallTargetX` instead of contradicting it, which fixes every
    binding consumer at once and not just this check.
  - **the visibility check moved out of the cross pass into its own pass after
    it** (`RunVisibilityPass`). A member's binding is not final while that pass
    runs — the nkMember node is visited before the enclosing nkCall selects — so a
    check running inline necessarily judged the head. Any future check that
    inspects a binding rather than producing one belongs there too.

  Measured effect on the corpora: the only dump lines that move are the `refs:`
  summaries (bindings shifting between local and cross-unit), the total
  UNRESOLVED count is identical, and no symbol line changes — 139 572 unresolved
  before and after on rtlflat. client project still the known 7, server zero.

  **Then class-vs-instance took it to 52 and 111.** A callee qualified by a TYPE
  (`TMonitor.Enter(X)`) cannot mean an INSTANCE method, and that alone separated
  the pair arity and argument scores could not: System's `TMonitor` declares a
  private instance `function Enter(Timeout: Cardinal): Boolean` beside the public
  `class procedure Enter(const AObject: TObject)` — same arity, so whenever the
  argument's own cross-type is unknown both score zero and the first candidate,
  the private one, won. `TMonitor.Enter` went from 150 reports to 2. The test is
  cheap and needs no new bookkeeping: the parser already marks a `class` method
  with `Aux = 1` on its `nkRoutine` (6.1), and a CONSTRUCTOR counts as callable
  on the type because `TFoo.Create(...)` is how one is called.

  **Then the tail, worked one site at a time on 2026-08-07: 546 → 2 on rtlflat
  and 998 → 2 on bigflat, in two rounds.** Eight causes between them, and not
  one was a visibility rule — the flag has now said the same thing about every
  flood it has produced. The first four:

  - **an anonymous method LITERAL rejects a candidate outright** (41 of
    bigflat's 111). `TThread.Synchronize(nil, procedure ... end)` fits the
    private `(ASyncRec: PSynchronizeRecord; QueueEvent: Boolean = False;
    ForceQueue: Boolean = False)` on arity, `nil` scores the same against either
    first parameter, and the first candidate won the tie. This is the
    "`ScoreCandidate` never REJECTS" gap named below, deliberately taken in its
    narrowest SYNTACTIC form: a written-out `procedure ... end` is a value of
    procedural type and nothing else. The general rule cannot be had so cheaply
    — it would have to answer for record `Implicit` operators, `Variant`,
    untyped parameters, and the rule that a parameterless function reference in
    a value position is CALLED (which is exactly why a `tcProc` ARGUMENT may
    legitimately meet a `Boolean` parameter, see `E2012`). A literal cannot be
    called that way, so it is provable at the node.
  - **`strict private` reaches a NESTED type** (the `FJSONWriter`/`FParentTypes`
    family, and the FIELD accesses that had no selection to read). dcc-probed
    both ways and the relation is asymmetric: a nested class may read the outer
    class's strict private member, and the outer class may NOT read a nested
    one's — that direction is dcc's own `E2361`. Now in 11 §11.2.1.
  - **a `class constructor` is never what a name means** (15 §15.1.5 said "not
    callable" and stopped there). `TRegistry` declares a private one fourteen
    lines above the public parameterless `constructor Create`, so the member
    walk stopped at it. Two traps on the way: the `class` keyword is NOT in the
    routine node's token span (the struct-body parser consumes it and records
    `Aux = 1`), so `IsConstructorSym` answers True for these and only the PAIR
    separates them; and the name is not fixed — `class constructor Init;`
    compiles.
  - **when nothing in a type's own chain fits, the call means an INHERITED
    routine** (`TButton.Create(Self)` is TComponent's). A binding stops at the
    first declaration of the name, so the ancestor's overloads were never
    candidates. One `FindMemberX` from the owner's ancestor, run only when
    nothing fit, which keeps it off the common path.

  **The last twelve, read end to end the same day: 6 → 2 on rtlflat and 12 → 2
  on bigflat.** Four more causes, four more binding gaps:

  - **a UNIT-QUALIFIED type is still a type qualifier.** `System.TMonitor
    .Enter(X)` writes the type as `UNIT.TYPE`, so the callee's qualifier is
    itself an `nkMember` and neither map holds anything for that node — the
    class-vs-instance test read nothing and let the private INSTANCE `Enter`
    back in. Its last segment is the type name.
  - **a `class constructor` that is a class's ONLY own `Create` must not end the
    member walk.** The overload-chain skip added an hour earlier only helped
    where there WAS a chain; `FEngineClass.Create` (Vcl.Themes, through a class
    reference) has one strict private class constructor and nothing else, so the
    walk has to carry on to the ancestor — dcc-probed, that call is TObject's.
  - **a declaration site is inside its own type.** `FGlow: TSystemTitlebarButton
    .TGlowWindow` declared IN `TSystemTitlebarButton`, whose `TGlowWindow` is
    `strict private type` — `StructSymOfNode` deliberately answers NIL for a
    node in a type declaration, so the check thought the class was an outsider
    to itself. `DeclStructsOfNode` answers for declaration sites.
  - **a PROCEDURE designator rejects a non-procedural parameter**, the same rule
    as the anonymous-method literal and for the same reason one step on:
    `TThread.Synchronize(nil, DoProvide)` passes a method VALUE, and the implicit
    call that lets a procedural argument meet an ordinary parameter needs a
    FUNCTION and its result. A procedure has none.

  What still reports is **two sites, the same one twice**:
  `AURIStr.IndexOfAny(['@', '/', '\', '?', '#'], Pos, Limit + 1 - Pos)`, where
  `TStringHelper` declares `IndexOfAny(const Values: array of string; var Index:
  Integer; StartIndex: Integer)` beside the public `(const AnyOf: array of Char;
  StartIndex, Count: Integer)`. Same arity, and both parameters accept what is
  written — a one-character literal is assignment-compatible with `string` too,
  so this is dcc PREFERRING the exact element type, not rejecting the other. It
  therefore needs the bracket constructor's ELEMENTS typed and the open-array
  parameter's element type scored, which is the general typing work the entry
  below names and not another special case.

  Still not covered, and each named rather than approximated: `protected` /
  `strict protected` (`E2362`, needs an ancestry walk to answer "is the accessing
  type a descendant"), and a BARE name in a descendant, where dcc reports
  `E2003 Undeclared identifier` instead — an inaccessible member is not in scope
  rather than in scope and refused, so that half belongs in the member WALK, not
  in a check after it.

  Two rules also come out RIGHT today *because* the walk ignores visibility, and
  both must survive: a nested enum's VALUES leak out of a `private` type
  (2 §2.2.4) and a `strict private` nested helper still activates (15 §15.4).
  Both are pinned by tests, and neither is a member ACCESS, so neither reaches
  the new check.
- **Missing semantic CHECKS the spec names, none of which can produce a false
  positive** — collected here rather than as separate items because they share
  a shape: we accept code dcc rejects. In rough order of how often the shape
  occurs:
  - ~~no "ordinal type required" check anywhere~~ — **done 2026-08-05**
    (`E2001` for an array index type, a `set of` base and a `case` selector,
    `E2032` for a `for` counter). Half of the old entry here was a SPEC BUG, not
    a missing
    check: dcc accepts a sparse (explicit-valued) enum in every one of those
    positions, so the code was right to accept it, and §2.1.1/§2.2.4 have been
    corrected. dcc also splits the rule per POSITION — `Variant` is an error as
    an index/base/counter and legal as a `case` selector or an `if` condition —
    which is now a table in §2.1.1. The `case` selector followed the same day,
    once the guard check below gave it the typer's result to work from, and so
    did the 64-bit `set of` base — see the entry below;
  - ~~`set of` base-type limit of 256 values / ordinals in `0..255`~~ — **done
    2026-08-05** (`E2028`, one code for both halves, including a negative lower
    bound). Reported only for a cardinality it can compute exactly: a builtin
    whose range is fixed on every target (so not `NativeInt`, the 64-bit types
    or the `*Bool` ones), a subrange with two LITERAL bounds, or an enum whose
    values are literals or implicit — tracked in order, so `(cA = 250, cB, cC,
    cD, cE, cF, cG)` is caught and its six-element sibling is not, both
    dcc-verified. A named constant as a bound is left alone rather than folded.
    `set of Char` (and `set of 'a'..'z'`) is honoured by staying silent, since
    dcc makes it `W1050`, a warning. A **64-bit ordinal base is dcc's other
    code**, `E2001` — and `NativeInt`/`NativeUInt` are 64-bit only where the
    target says so, which is why the typer now takes a platform: the same
    `set of NativeInt` is `E2028` under `dcc32` and `E2001` under `dcc64`, both
    verified. `ByteBool` is `E2028` despite being one byte, while `Boolean` is
    fine. Not reported: `FixedInt` and `UCS4Char`, which have real declarations
    in `System.pas` rather than seeds, so their category is cross-unit and
    unknown intra-unit;
  - ~~conditions are not required to be Boolean~~ — **done 2026-08-05**
    (`E2012`, plus `E2001` for the `case` selector, which needs the same
    expression types). Three exemptions, each dcc-verified and each necessary:
    `Variant` (legal as a guard AND a selector), records as guards only (an
    `Implicit` operator to `Boolean` makes one legal, to `Integer` illegal — the
    answer is in its operators, so guards exempt records and selectors do not),
    and procedural types in both, because a parameterless function reference in
    a value position is CALLED and the guard's type is its RESULT. That last one
    was found by the corpora and not by reasoning: six `if AShouldStop then`
    conditions in a component suite, all `reference to function: Boolean`, after the
    suites and both flat corpora were green. Still not reported: a record guard
    with no Boolean conversion, which is the exemption above;
  - ~~assigning to a `for` counter inside the body~~ — **done 2026-07-31**
    (`E2081`, all three shapes dcc reports: a direct assignment, `Inc`/`Dec`,
    and an inline `for var` counter). Zero new diagnostics across ~12 000
    corpus units, which is the bar every remaining entry here has to clear;
  - ~~bare `raise` outside an exception handler~~ — **done 2026-08-05**
    (`E2145`). The context turned out to be purely lexical and decided by the
    NEAREST enclosing part of a `try` statement, so a `finally` or a `try` block
    resets what an outer handler established, while an anonymous method body
    does not — all dcc-verified, and now written into §18.3.1, which had said
    only "the analyzer must track handler context". Zero new diagnostics across
    all four corpora;
  - ~~`Slice` outside an open-array argument position (4 §4.11)~~ — **done
    2026-08-05** (`E2193`), and dcc turned out to be stricter than §4.11 said:
    an argument of an INTRINSIC is never a valid position either, not even
    `Insert`'s, whose parameter really is an open array. Reported for every
    position — assignment RHS, statement, index base, array-constructor element,
    any intrinsic's argument, `Slice` of a `Slice`, and a non-open-array
    PARAMETER of an ordinary call. That last one needs the parameter at an
    argument index, and it is taken only from a SINGLE unambiguous candidate: a
    plain callee name bound to a routine with no further overload and with its
    params visible in this unit. An overload set is deliberately not ranked —
    picking the wrong candidate would invent a diagnostic, and `Slice` is far too
    rare for that trade. So `Over(Slice(A, 3))` against an overloaded `Over`
    stays silent, as does any cross-unit callee. Still not implemented and now
    the only gap: `Slice`'s first argument may not be a DYNAMIC array
    (`E2016 Array type required`), which is a different check on a different
    argument;
  - ~~multiline-string indentation (B §B.6.3)~~ — **done 2026-08-05**
    (`dcInconsistentIndentChars`, dcc's `E2657 Inconsistent indent characters`).
    The lexer already found the terminator; it now compares the closing run's
    indentation against every content line. dcc compares CHARACTERS, not widths,
    and stops at the end of a short line — one rule that explains all six probed
    shapes: a tab where the closer has spaces is an error, a whitespace-only line
    shorter than the closer is not, and anything past the matched prefix is free.
    §B.6.3 said "less indented", which predicts neither of those; it now has the
    table. One report per offending line, dcc-verified.

    Two things about the measurement, since they matter more here than usual: the
    diagnostic is a LEXER one, so it does not reach the sema report and the bar
    had to be met with `PasTreeLex` instead (zero across ~16 000 files: both flat
    corpora, both real project trees, `3rdlib13` and the whole Studio source tree) —
    and that corpus is **thin for this feature specifically**: the whole ~16 000
    files hold exactly ONE multiline literal (an embedded JS function in
    one client-project unit, which is in that project's analysis
    closure and lexes clean), the feature being Delphi 12 and most of this code
    older. So the corpora prove no regression (full sema dumps byte-identical,
    lexer throughput 94.6 vs 93.5 MB/s) plus that one accepted literal, and the
    dcc-matched probes carry the rest of the weight.
    Still not implemented, and now the only known gap in B.6.3:
    the token's VALUE is raw source text, not de-indented — harmless today
    because nothing folds string constants.
- ~~**Three rules the CODE implements that the SPEC never states.**~~ **Written
  up on 2026-07-31**: helper inheritance and its class-vs-record asymmetry
  (§15.3.1), the dynamic `array of array of T` indexing sugar (§8.2.1), and a
  `TypeRef` position resolving to a TYPE over a nearer same-named non-type
  (§B.11). Behaviour unchanged — the code already did all three.
- **Where the audit stands (2026-08-05).** ALL FIFTEEN of its items are closed —
  both false-positive/wrong-binding defects (`IInterface`, inline-var position),
  visibility recording, the three spec write-ups, `E2081`, `E2145`, `E2193`, the
  whole ordinal/Boolean/set-limit family (`E2001`, `E2012`, `E2028`, `E2032`) —
  where one of the items turned out to be a wrong spec rule rather than a missing
  check — and multiline-string indentation. **That is every "missing check" the
  audit named**, bar the two one-line residues noted in this list (`Slice`'s
  first argument may not be a dynamic array; `FixedInt`/`UCS4Char` set bases are
  invisible intra-unit). The last two — member-lookup reporting and visibility
  enforcement — shipped as OPT-IN switches, since both
  can only ADD diagnostics. They shared one acceptance bar, met by
  every check added so far and worth restating rather than re-deriving — **zero
  new diagnostics across rtlflat, bigflat, both real projects and a third-party
  library's base and core packages (~12 000
  units), plus a probe whose output matches `dcc` line for line.** It has earned
  its keep once already: `E2012` passed every suite and both flat corpora while
  wrongly rejecting six `if AFunctionReference then` conditions, and only the
  3747-unit third-party closure showed it.

  What replaces this list is one
  finding the last three checks produced independently, and it is worth carrying
  forward as the next objective rather than as three anecdotes: **where this
  analyzer is
  imprecise, it is imprecise in BINDING, and every check that trusts a binding
  inherits that.** The member flag's 8 348 reports are generic-ancestor frames and
  builtin-type helpers; `E2012`'s six false rejections were parameterless function
  references; `-visibility`'s 998 are constructor overloads picked first out of a
  member scope. Three checks, three binding gaps, no rule wrong in any of them.

  So the work the switches are waiting on, in the order that unlocks the most.
  The first item is **done**: a call's callee is re-pointed to the
  argument-matched overload, and a type-qualified callee no longer considers
  instance methods — 998 visibility reports on bigflat became 111 in two steps.
  Argument TYPES were already weighed by `ScoreCandidate`; what it still does not
  do is REJECT a candidate whose argument types definitely do not fit (a mismatch
  scores 0 rather than -1), which is the next refinement there and wants its own
  measurement, since it can change a selection rather than only break a tie.
  The second item, **generic-ancestor frames** in the member walk, is done too
  (2026-08-06: 8 300 → 104 on rtlflat, and the gap was a later pass re-deriving
  a type instead of reading the frame-substituted one an earlier pass had
  already computed). So is the third, **helpers on builtin-typed values**
  (rtlflat 104 → 51: a builtin type is seeded PER MODEL, so the helper index was
  keyed on one `string` and asked about another).

  All three named buckets are therefore closed, and a fourth that only became
  visible once they were: a constrained parameter used in a method BODY
  (rtlflat 51 → 23). The list is out of named items, so the next objective comes
  from reading the tail rather than from here. What the tail says today:

  - ~~`Create` (12 on rtlflat) and `Free` (5)~~ — **done the same day, and they
    were two unrelated rules sharing a pair of names** (rtlflat 23 → 6): a
    `class` constraint guarantees TObject's members, and a dynamic array type
    has a `Create` pseudo-constructor. Both were spec gaps, now filled — this is
    the first tail item where the spec had to be WRITTEN before the code could
    be, and both probes are in it;
  - ~~a seeded builtin name beating a class's own member~~ — **done 2026-08-06,
    bigflat 136 → 110, and the point of it is the reports it did NOT change.**
    `Text` is a predefined FILE type (10 §10.3) and also an inherited property
    on FMX's `TTextLayout`; dcc gives the member precedence throughout the
    method body (`Text.IsEmpty` compiles, and `var F: Text;` there is `E2007` —
    it wins in a TYPE position too, both probed and now in 11 §11.4). We bound
    the seed, so the name RESOLVED and only the member after the dot failed:
    a wrong binding produces no diagnostic of its own, which is why the fix
    shows up in the dumps (14 unit summaries move on rtlflat, whose report count
    does not budge) rather than in a count.

    The inherited pass already re-decided nodes that arrive bound — that is how
    a unit reference loses to a member — so this is one more kind admitted to
    that queue. The reason it was not there already is written in the old
    comment: queueing every seed-bound identifier measured **+3.6%**, since
    `Length` and `Integer` are seed-bound in every method body. Two attempts to
    filter by NAME were both net losses (RTL member names overlap the intrinsics
    heavily, and the name test itself allocated); what worked is memoizing the
    MISSES per worker on an integer key — `(struct, the symbol it is bound to)`,
    no string built, no lock — which is **+1.2%**, and the difference from the
    +16% memo this file's history records is exactly that key.

    Known and deliberate imprecision: the walk ignores visibility, so a
    `private` ancestor member in another unit — invisible to dcc — can win here.
    That is the same imprecision `-visibility` exists to measure, not a new one,
    and its numbers did not move (52 / 111).
  - `ScoreCandidate` never REJECTING a type-mismatched overload — taken in two
    narrow forms so far. **2026-08-07:** an anonymous method LITERAL rejects a
    non-procedural parameter, provable at the node, 41 of the 111 false
    `E2361`. **2026-08-08:** two DIFFERENT RECORD types reject each other,
    which is decidable because distinct records are not assignable and the one
    thing that could make them so is a `class operator Implicit`/`Explicit` —
    a MEMBER, so it can be looked for. That one also needed argument and
    parameter types canonicalized through their alias links first
    (`CanonTypeX`), since the two sides are read in different units and
    `XSameType` compares symbols. The GENERAL rule is still open and still
    wants its own measurement, because "these types do not fit" has to answer
    for `Variant`, untyped parameters and implicit calls of parameterless
    function references;
  - on rtlflat there are exactly six member reports left, so that corpus can no
    longer drive this — `bigflat`'s 110 and the client project are the ones with
    anything to say.
- **Audit coverage, so the next pass knows where to start.** The 2026-07-31
  sweep ran pass 1 (spec → code) over every chapter and pass 2 (code → spec)
  over the member-lookup, property, interface, helper, array and generic
  machinery, with `dcc` probes for anything either side left unstated. What
  pass 2 has still NOT covered: the parser's own branch set (appendix B and the
  statement/declaration grammar), the preprocessor's, and the typer's —
  `PasTree.Sema.Types` in particular has never been read against ch.02 §2.6.1,
  which is where the assignment-compatibility contract lives.

- ~~**One cross-model expression typer, not two.**~~ **Tried on 2026-07-29 and
  rejected on measurement — do not repeat it hoping for a different answer.**

  There are two: `CrossType`'s `Walk`, which types every expression node, and
  `WithTargetTypeX`, which types a `with` target. They are not
  subset-and-superset — each lacks kinds the other has (`Walk` no `nkIndex`/
  `nkDeref`/`nkBinaryOp`, `WithTargetTypeX` no `nkTypeArgs`/`nkInlineIf`) — so
  the duplication is real and a shape fixed in one can stay broken in the other.
  Unifying them still lost on the only test that matters here, *simple and fast*:

  | step | total | what it bought |
  |---|---|---|
  | baseline | 1893 ms | — |
  | `Walk` gains the designator kinds | 1952 ms | +35k typed exprs, 0 diagnostics |
  | + split `BindTypesX`, share `DeclTypeX` | 1999 ms | one shared primitive |

  **+5.6% wall time, zero diagnostic change, and MORE code** — an `AInBodies`
  parameter, a two-phase ordering protocol, four extra call sites, a fallback
  chain. The 35k extra expression types produced nothing observable. Reverted.

  What the attempt *did* establish, and what makes it cheap to retry only if a
  real need appears:

  - The two cannot share the ident primitive without `BindTypesX` running before
    the body passes, and that reorder is **not** free: of 53,643 symbols
    untypeable right after `CrossResolve`, 43,470 are declared inside a method
    body, and the inherited pass unlocks 42,039 of them (the with pass a further
    4). Moving all of `BindTypesX` early loses 181k of 874k cross-model types
    with diagnostic counts completely unmoved. Splitting it by declaration site
    works to within 17 symbols, so the dependency is precisely *method locals* —
    not "the body passes" in general.
  - Three of the four `with` defects fixed that day had one root cause, and it
    was never the shape list: code asking `RefMap`/`ExtRefMap` for a binding that
    a LATER pass produces. At with-pass time those maps are legitimately
    incomplete; the rule is "derive from types, never read the ref maps". That
    rule lives in one place (`DesignatorSymX`'s fallback), and new special cases
    should be routed through it rather than grown. **That** is the cheap
    generalization; merging the typers is not.
- ~~**Zero-diagnostic parity on the real RTL/VCL/FMX.**~~ **Reached on
  2026-07-30.** The flattened RTL+VCL+FMX corpus (726 files) reports ZERO
  `E2003`/`E2034`/`E2035`; the only diagnostics left are honest `F1027`s for
  units genuinely absent from the flat directory. `BuildWinVCL.dpk` (271 units)
  and `BuildWinFMX.dpk` (362 units) are both clean end to end. Stable run to run
  and identical single-threaded. This is a floor to HOLD, not a finished job —
  and the two precedence gaps below are known places where the binding is
  right-ish for the wrong reason.

  **Held, and raised on 2026-08-07:** the same five corpora also report zero
  under `-members`, which is the stricter bar — it asks about every member
  after a dot, not only bare names. The gaps that bar found were all bindings,
  and the "right-ish for the wrong reason" worry above is exactly what it was
  measuring.

  **Two real applications are clean too as of 2026-07-31.** The 3747-unit /
  7.2M-line client reports 7 diagnostics, not one of them a defect we can fix
  here: five `F1027` for a charting library that ships `.dcu` + `.hpp` and no
  `.pas` (the source-less-units item below), and two a CONFIRMED true positive
  — a method-resolution clause whose right-hand side is declared nowhere in the
  shipped sources, which `dcc` reports identically on a reduced probe. Down
  from 899 on 2026-07-28. Its 2121-unit Win64 server reports **zero**, down
  from 94 the same day.
- **Two `with`-target diagnostics we accept where dcc refuses**, both found by
  auditing 5.7 against the implementation rather than by the corpus, and both
  missing-diagnostic rather than false-positive:
  - `with P do` over a pointer. The implicit dereference that makes `P.Field`
    legal does NOT extend to a with target — dcc says `E2018 Record, object or
    class type required` and then `E2003` on every member. `FindMemberX`'s
    pointer hop is shared with member access, so we open the scope happily.
  - `with (R) do X := 1`. Parentheses demote the target to a VALUE: dcc opens
    the scope but reports `E2064 Left side cannot be assigned to`. We have no
    assignability model for with members, so the write is accepted.
- **OLE named arguments are exempted syntactically, not by callee type.** 4.11.3:
  `Name := Value` is an argument only when the callee is `Variant`/`OleVariant`
  — on a class method, an interface, a statically typed `dispinterface`, or a
  plain routine (even one whose parameter really is named `Name`) dcc reports
  `E2003` on the name. Nothing knows the callee's type at parse time, so the
  parser accepts the form anywhere and the resolver never looks the name up. A
  lost diagnostic, never a false one. Closing it means deferring the decision to
  the typer, which knows whether the callee is `Variant`. We also do not
  implement `E2166` (named arguments must follow positional ones).
- **Two over-permissive bindings, both found on 2026-08-08 and both left in
  deliberately** — they can only ADD a binding, never invent a diagnostic, and
  each would cost precision elsewhere to fix properly:
  - *A lone `constructor` constraint unlocks all of TObject, where dcc unlocks
    only `T.Create`.* 16 §16.4.1 is explicit and probed: under `T: constructor`
    alone, `V.Free` on a VALUE of that type is `E2003`, while `T.Create` on the
    type is legal. `ConstraintOfParamX` maps the kind constraint to TObject
    wholesale, so both resolve. Doing it exactly means splitting the
    type-designator use from the value use at the constraint hop.
  - *An inherited overload set is merged whether or not the declarations say
    `overload`.* dcc-verified this day, in both directions: with `IMore =
    interface(IBase)` redeclaring a name, the ancestor's signature is callable
    when both carry `overload` and `E2010 Incompatible types` when neither
    does — the derived declaration hides. Our "nothing in the type's own chain
    fits, so this means an INHERITED routine" fallback does not read the
    directive, so it accepts the hidden call too. Now in the spec (6 §6.3.1).
- **Invert the overload chain: `PrevOverload`, nearest-declaration-wins.**
  Today `DeclareSym` keeps the FIRST declaration registered under the name and
  chains later ones forward through `NextOverload`. Object Pascal's rule is the
  opposite — the NEAREST declaration wins and shadows what came before — so
  every place that needs "what does this name mean here?" has to work against
  the grain, and every place that needs "all the overloads" has to know where
  the chain starts. Suggested from a previous parser where the inverted link
  handled every case; the evidence here agrees:
  - We already hand-rolled nearest-wins once, as a special case: a declaration
    that HIDES a used unit's leaf name re-binds the name to the newer symbol
    (`DeclareSym`'s `skUnitRef` branch). With `PrevOverload` that is just the
    normal path.
  - An implementation-section overload joining the interface set needed the
    same fix written twice, in `CheckCalls` and in `SelectOverload`, because the
    two declarations live in different SCOPES and nothing linked them. A prev
    link established at declaration time — looking UP the scope chain, not only
    in the current scope — carries that relation once, and every consumer that
    walks "what I shadow" gets it for free.
  - Walking outward is also the order resolution actually wants: nearest scope,
    then enclosing, then interface, then imports.
  Surface is small: 19 `NextOverload` references across four units.
  ⚠️ *What it does NOT solve, so the work is not mistaken for more than it is:*
  the CROSS-UNIT cases. Whether one unit's `TObjectList` shadows another's
  depends on the REFERRING unit's `uses` order, so the relation differs per
  importer and cannot be a single per-symbol link — `FindTypeInUsesArity` and
  friends stay either way. Of the three overload/shadowing defects fixed on
  2026-07-30 and -31, this design would have prevented one.
  ⚠️ *Migration risk is the symbol IDENTITY change:* whatever `FindLocal`
  returns becomes the newest rather than the oldest declaration, and
  navigation, dumps and several tests assert on which symbol that is. Hold it to
  the same test as any other refactor here (README's own rule, and the
  merged-typers episode above): fewer special cases AND no slower, measured —
  not "cleaner".
- **Arity check in the intra-unit typer ignores inherited members.** The
  cross-unit check (`CheckCalls`) now yields to an inherited member before
  reporting, but `PasTree.Sema.Types.SelectOverload` has its own arity
  diagnostic and does not. It is gated to units with NO `uses` clause at all, so
  nothing in the RTL/VCL/FMX corpus reaches it — but a bare unit with an
  inherited method shadowed by a same-named global still gets a false `E2035`.
  Fixing it means the typer needs the ancestor walk the resolver already has.
- ~~**Helper precedence inside the same-unit join.**~~ **Fixed on 2026-08-08**
  — the ordering exception this item asked for is a `Shadowing` list on a
  scope, searched by `FindLocalDeep` BEFORE the scope's own names, and
  `JoinHelperScopes` is its only user. Everything else joined onto a scope
  (uses, with, ancestors, enums) is a fallback and stays in `Additional`. It
  was worth ~60 reports on the client project, all in a suite's HTML
  importer, where a helper redeclares `Importer` at a derived type.
- **Declaration-site precedence: inherited member vs used-unit global.** A name
  written inside a class DECLARATION is now found in the enclosing classes'
  ancestries (`CrossResolveDecl`), but only *after* the used units — dcc has it
  the other way round, so a used unit's global with the same name as an
  inherited member wins where it should lose. Closing it means deferring EVERY
  declaration-site name that does not resolve locally — that is every cross-unit
  type reference in every class in the closure, each through `FindMemberX`.
  Deliberately not paid for a collision nobody has hit yet.
- ~~**`{$IF Declared(X)}` cannot be answered, and the wrong branch is taken.**~~
  **Done on 2026-07-31.** `Declared()` asks whether an identifier is in scope,
  and the symbol table that knows sits behind the token stream this very
  decision produces — so it is answered in **two stages** instead of guessed:
  - the first pass answers the compiler-provided names, which need no models at
    all, and RECORDS every other name it was asked about;
  - `RunDeclaredPass` then re-preprocesses only the units whose recorded names
    now answer differently, once their imports have models and before any cross
    pass — the one window where the imports exist and nothing yet holds a
    reference into the models being replaced.

  The two-stage split is what makes it affordable: the commonest guards
  (`DECLARED(AnsiChar)`, `declared(UInt64)`) sit in the largest RTL units, and
  answering them in stage one took the second pass from 7 units to 2 and a +4%
  regression to nothing. ONE round, deliberately — see the code for what that
  gives up. The query also excludes the unit's OWN declarations, without which
  the idiom it exists for (`{$IF not declared(X)} X = ...`) would oscillate.
- **An AST printer, and the two very different tests it enables.** Item 2 of the
  definition of done is a *token*-level roundtrip (concatenated tokens + trivia
  == source, byte-for-byte), which proves the LEXER lossless and says nothing
  about the tree. A printer that regenerates source from the AST is the next
  rung, and it is worth being precise about what each variant actually tests:
  - **Verbatim printing → parser/AST fidelity.** Print the tree and diff against
    the original. Every mismatch is a node that DROPPED information — a directive
    the parser swallowed, an operand order it normalized, a construct it folded.
    This is a strong, cheap, fully automatable check over the whole RTL, and it
    is the one to build first. It does NOT test the semantic layer: the tree is
    the same tree whether or not a single name resolved.
  - **Qualified printing → the semantic layer, end to end.** Print every
    unqualified reference in its FULLY QUALIFIED form (`Unit.Type.Member`,
    each `with` body member rewritten to `target.member` — literally what §5.7's
    parser guidance suggests keeping the tree shaped for). Now the output encodes
    every binding decision, so a diff against a known-good rendering is a total
    test of resolution, not of parsing. Better still, the result must still
    COMPILE under dcc32 and must produce byte-identical `.dcu`s — which makes
    dcc the oracle and removes the need for a hand-maintained expectation file.
    This is the "жир": a wrong binding stops being invisible and becomes a
    compile error or a binary difference.
- **Follow a package's `requires` closure to the required package's search
  paths.** Small, and it is the whole of the last honest `F1027` we still
  report: a `.dpk` whose own `DCC_UnitSearchPath` is one non-recursive
  directory reaches units that live a level deeper only because it `requires`
  another package whose paths do cover them. dcc resolves it through the
  required `.dcp`; a host reading `.dproj`/`.dpk` files can resolve it by
  reading the required project's paths. Worth doing before the source-less-unit
  work below, because it costs a `.dpk` parse and removes a whole class of
  reports that look like ours and are not.
- **Units with no source (`.dcu`-only third-party libraries).** The blocker for
  real projects: the client project pulls in several large third-party component
  suites, and where only `.dcu` ships, every importer gets an `F1027` and — far
  worse — its diagnostics are then gated off entirely by the `AllUsesResolved`
  rule, so the unit reads as clean when it was never analyzed. Target design:
  produce a **virtual, in-memory interface-only `.pas`** for such a unit and feed
  it to the ordinary pipeline, so nothing downstream needs to know the
  declarations did not come from a file. Navigation then opens that generated
  buffer as a read-only tab — the mechanism already exists for `$I` includes,
  which likewise resolve to a path that is not the model's own file.
  Staged, cheapest-first, because the last stage is the expensive one:
  1. **Stub search path.** Accept a directory of hand- or tool-written
     interface-only `.pas` files that stand in for missing units. No new format
     work at all, unblocks a real project immediately, and it is the same
     ingestion path every later stage feeds. Do this first regardless.
  2. **Whatever the vendor already ships.** `.hpp` headers (C++Builder
     export) and `.int` files where they exist are already declaration-only text.
     Not hypothetical: the first real project run hit exactly this — the client
     project's last 5 `F1027` are one charting component's, which ships its
     `.dcu` under `lib\win32\release` plus a C++Builder `.hpp` with **no `.pas`
     anywhere** in the Studio tree. A `.hpp` reader would close that cluster
     without touching the `.dcu` format at all — and those 5 are now the only
     project-file diagnostics that corpus has.
  3. **A `.dcu` reader.** ⚠️ *Do not budget this as a small job.* The format is
     undocumented, proprietary, and changes with essentially every compiler
     release — a version magic at the head and per-version tag tables. The
     public knowledge is reverse-engineered (`dcu32int`, IDR), lags current
     releases, and nothing published covers 37.0. It cannot be written from
     documentation; it has to be reverse-engineered against samples.
     The one big lever: the RTL ships **source and `.dcu` side by side for ~700
     units**, which is a labelled training corpus almost nobody else has — take a
     unit whose interface we already parse correctly, and the `.dcu` is the
     answer key for what the encoding must mean. Scope the reader to what the
     analyzer actually needs (unit name, uses list, exported type/const/var/
     routine declarations with signatures) and stop there — code, debug info and
     line tables are out of scope.
     Resist one shortcut: scraping identifier NAMES out of the `.dcu` string
     table and treating "name is present" as resolution. It suppresses `E2003`
     without types, so every member access through such a name silently
     degrades, and real errors get hidden along with the false ones. A stub with
     honest types (stage 1) beats a name list.
- ~~**Navigation history (Back / Forward).**~~ **Done on 2026-07-31.**
  Alt+Left / Alt+Right, the mouse's back/forward buttons, and two items on the
  editor's context menu. Entries are file path + line/col, never node or symbol
  indices: every re-analysis (`ReanalyzeForNav`, armed by any edit) rebuilds
  `FSemaProject` from scratch and invalidates every index into it.

  Two things the plan above got wrong, both found by building it:
  - *`EditorMouseDown` was not "the single place a jump happens"* — the Goto
    Declaration/Implementation actions and the message window's double-click
    jump too, and a history fed from one of four sites is worse than none. All
    four now go through `NavigateTo`, which is what the plan wanted to be true.
  - *`TSynEdit.OnMouseDown` does NOT receive the X buttons.* VCL's
    `TMouseButton` is `(mbLeft, mbRight, mbMiddle)` and has no XButton member at
    all, so the handler is never called for them. `WM_XBUTTONDOWN` goes to the
    focused control, so `Application.OnMessage` is the one place that sees it
    without subclassing every editor as it is created.

  One decision taken in advance held: a jump may open a closed unit and Back
  never closes anything. Positions also die with the project — opening one
  closes every tab, so entries pointing into them would point at nothing.

  The other, "recorded positions drift after an edit and are jumped to
  anyway", turned out **not** to be necessary. The plan's own suggestion was
  right: SynEdit already does this arithmetic, for its gutter marks, its
  indicators and its selections, and offers the same two notifications to
  plugins — so `TNavHistoryPlugin` (one per editor, `phLinesInserted` +
  `phLinesDeleted`) shifts the recorded lines and there is no drift to accept.
  Two things worth knowing before reusing it:
  - *the convention is asymmetric and stated only in passing:* `FirstLine` is
    **0-based** while a mark/indicator `Line` is **1-based**
    (`TSynIndicators.LinesInserted`'s comment is where SynEdit says so);
  - *SynEdit's two implementations disagree by one.* Indicators shift on
    `Line > FirstLine`, gutter marks on `Mark.Line >= FirstLine` — which drags
    the line ABOVE an insertion point down with the text below it. The
    indicator rule is the correct one; `NavHistorySmoke` pins that boundary,
    and swapping in the mark rule fails exactly that test.

  The list rules and the arithmetic live in `PasTreeDemo.NavHistory`, apart
  from the form, because none of it is observable in the running program: a
  wrong rule shows up as Back landing somewhere slightly unexpected several
  clicks later, by which time the history that would explain it is gone.
- ~~**Recent projects on `Open Project...` (split button).**~~ **Done on
  2026-07-31** (`PasTreeDemo.Settings`). `Open Project...` is a real
  `bsSplitButton`, so its primary half still browses and Windows handles the
  arrow; the drop-down lists the last **20** (2026-08-07; ten before),
  most-recent-first, deduped by full path and numbered 1..N in that order. The
  numbers used to be `(index + 1) mod 10`, which was reaching for a
  single-digit accelerator and, past ten entries, printed 1..9, 0, 1..9 again —
  numbers that repeat and appear to run backwards at the tenth row. The
  accelerator is kept only where it is unambiguous, the first nine: `&10` binds
  the key `1`, which row 1 already owns, and Windows resolves that by cycling
  rather than choosing. The `.ini` sits beside the executable and carries the sticky settings
  too (highlighter, threading, highlight colour) — but NOT the platform, which
  `OpenProject` sets from the `.dproj` and would overwrite before it was ever
  seen. A missing file stays REMEMBERED and is only left out of the menu, so a
  disconnected share does not silently drop off the list.

  Tested in `DemoSettingsSmoke`, which is worth the suite for one reason: none
  of this shows itself until a drop-down opens, and the rules that make the
  list useful (order, one entry per project however it was spelled, a cap that
  shrinks the FILE and not just the list) are exactly the ones that break
  quietly.
- **`.groupproj` (project groups), and a project TREE in the demo.** Today the
  demo opens one `.dproj` and shows its units as a FLAT list, which stops being
  readable at the client project's 1542 files and cannot represent a group at all. Two
  halves, and the second is the one with design in it:
  - *Reading `.groupproj`.* MSBuild XML like `.dproj`, so `PasTree.DProj` is the
    place — an `ItemGroup` of `<Projects Include="...">` plus per-project
    `<Dependencies>`. Straightforward, but note the analyzer already has the
    hard part: several projects in a group share most of their closure, and
    `TPasSemaProject` caches by full path (`FByPath`), so ONE project instance
    across the whole group parses each shared unit once. Building a project
    instance per group member would multiply the 7.4M-line closure by the
    member count for no gain.
  - *The tree.* Group → project → the .dproj's own grouping (Contains /
    Requires for a package, unit vs form vs resource), and separately the
    closure a project actually pulls in, which is where the units NOT listed in
    any `.dproj` live (3747 analyzed vs 1542 listed for the client project — the other
    2205 are library units nothing in the UI currently surfaces). Worth keeping
    those two axes distinct in the model rather than merging them into one list:
    "files the project declares" and "units the analysis reached" answer
    different questions, and the second is what the diagnostics are keyed to.
- **A 64-bit build of `PasTreeSemaProject`.** ~~and of the demo~~ — **the demo
  is Win64-only as of 2026-08-13** (`demo\build.bat` calls `dcc64`; see
  `demo\README.md`, which records the requirement and why it is not a
  preference). Nothing in the library is 32-bit-specific — it is purely
  address space, and the figure is now measured rather than assumed: the
  client project's closure (3750 units) **holds 3.5 GB**, printed on the
  demo's `Done:` line and in the tool's report via
  `PasTree.Types.AllocatedBytes`. That also rules out `LARGEADDRESSAWARE` as
  a workaround (3.5 GB against a 4 GB ceiling).

  A Win32 OOM is worth recognising by its *shape*, because it does not look
  like what it is: every unit that fails to load gates its importers, so the
  run reports tens of thousands of unresolved `uses`, suppresses every unit's
  `E2003`, prints `0 diagnostics`, and files the OOM under
  `INTERNAL: N unit(s) failed to parse — analyzer defect`. One cause, many
  costumes.

  Still open for the TOOL: build it with
  `dcc64 -U"%BDS%\lib\win64\release" -U..\source -NSSystem;System.Win;Winapi;Data;Xml -N0out64 -Eout64 PasTreeSemaProject.dpr`
  — what is missing is making that the default rather than a manual step.
- **LSP/LSIF server.** The demo (VCL-hosted) is the only editor integration
  today; a Language Server Protocol server (live highlighting/navigation/
  diagnostics/rename/etc. over the same Sema/Nav layer) plus LSIF dump
  generation (precomputed navigation for code browsing without a live
  server) are the planned next consumers.
- **ToolTip Insight** — hover any identifier and get a popup hint saying where
  it is DECLARED: `<module>: <line>`, plus enough of the declaration to be worth
  reading (kind and name at minimum — `property TTextLayout.Text: string`).
  Cheapest of the wish-list items and the one with the best ratio, because the
  answer is already computed and already reachable: ctrl+click resolves exactly
  this, so the hint is the same `(unitId, sym)` lookup rendered as text instead
  of as a jump. Build it on the SAME entry point the click uses, never a second
  resolution path — two of them would drift, and a hint that disagrees with
  where the click lands is worse than no hint.

  Three things to decide, and each has a right answer already visible elsewhere
  in this codebase:
  - *what to show when the click has nowhere to go — and the answer is always a
    WORD, never a blank hint or a made-up line.* An intrinsic says so:
    `Length — compiler intrinsic`, because it has no source declaration at all
    (go-to-declaration routes those to `System.pas`'s header, which is a
    navigation convenience and not where they are declared). An identifier
    nothing resolves says `<unknown id>`, spelled exactly that way — the user's
    own wording, and the honest one: this analyzer is error-tolerant by design,
    so "we could not bind this" is a normal state and worth showing plainly
    rather than hiding. `Result`, a `uses` name (show the resolved FILE) and the
    dynamic-array `Create` this session added (bound to nothing on purpose) each
    need their own word for the same reason.
  - *when a hint is WRONG rather than missing.* The seed-shadowing bug fixed on
    2026-08-06 is the cautionary one: `Text` resolved, to the predefined file
    type instead of the class's property, and nothing reported it. A hint makes
    every such binding visible to the user for the first time — which is a
    feature (it is a free audit of the binding tables) and a risk (the tail in
    the To-do above is exactly what it will surface).
  - *hover timing and cancellation.* The analysis is asynchronous and a hover is
    not a click: the hint must never block the UI thread and must be dropped if
    the caret moves or a re-analysis lands. `TPasAsyncSession` already owns that
    discipline for the message window; reuse it rather than re-deriving it.
- **Find References** — for any identifier, list every place it's actually
  USED (by resolved symbol identity via `RefMap`/`ExtRefMap`/`CallTargetX`,
  not a text search — two same-named locals in different scopes must not
  cross-pollute, and an overload-precise call site must land on the actual
  overload, not just any same-named routine), in its own results window
  (module / line / a trimmed source snippet around the identifier), double-
  click to navigate — same shape as the existing message window, but with
  REAL columns (the message window today is a single flat text column;
  this needs `Header.MainColumn`/actual `TVirtualStringTree.Columns`, a
  first for this codebase's VST usage). Walks every loaded model's
  RefMap/ExtRefMap/CallTargetX for a match against the target (unitId, sym)
  pair — cross-unit by construction, no new resolution needed, just a new
  consumer of data already computed. This is also the direct PREREQUISITE
  for Rename Symbol below (rename = find references + apply edits) — build
  this first.
- **Rename symbol** (Ctrl+E) — rename any identifier and every reference to
  it project-wide, using the same resolved symbol model Find References
  above already walks (so a rename only touches the actual declaration's
  references, not textually-matching names from an unrelated scope).
- **Show Defines** — for the identifier/position under the cursor, list
  every preprocessor define ACTIVE there (module where `$DEFINE`d / project-
  or platform-level, line, the define name), in its own results window,
  click to navigate to the `$DEFINE` site. Needs NEW preprocessor
  infrastructure, not just a UI: `TPasDefines` is a live flag set
  (`Define`/`Undefine`/`IsDefined`) with no positional history — nothing
  today records WHERE in the token stream a define turned on/off, so
  "what's active at offset N" can't be answered from the current model.
  Requires logging (position, name, on/off) events during preprocessing
  and replaying them up to a query position; also needs to decide how
  project/platform-level defines (`MSWINDOWS`, `WIN32`, ...) are attributed
  in the module column (no real `$DEFINE` site — "project settings" or
  similar sentinel).
- **Show Units Dependency** — a dependency tree (TreeView, root = the open
  project's main source, children = each unit it `uses`, recursively) in
  its own window, off `TPasSemaModel.UsesList`/`UnitId` (the same graph
  `AnalyzeProject`/`AnalyzeStaged`'s BFS closure walk already has, just not
  currently exposed anywhere) — real dcc disallows genuine `uses` cycles so
  this is a DAG, though a diamond dependency (two units sharing a common
  base) will naturally repeat in a plain tree view, same as a real IDE's
  own uses-browser. The SAME window should also offer a flat INITIALIZATION
  ORDER list (dependencies-first) — this is NOT just "the order units were
  discovered" (`TPasSemaProject`'s model list is BFS-discovery order, which
  does not guarantee a unit's own dependencies were already fully
  discovered first); it needs an actual topological sort over the uses
  graph to match how dcc really sequences unit `initialization` sections.
- **Generate method body from declaration** (Ctrl+Shift+C) — given a method
  or routine declaration with no implementation yet, emit an empty matching
  body (right unit, right place, right signature), the inverse of the
  existing decl→impl navigation.
- **Formatter** — reformat source to a configurable style, off the same AST
  the highlighter and navigation already use rather than a separate
  regex-based pass.
- **Error Insight** (live diagnostics, à la Embarcadero's own IDE feature) —
  today's diagnostics are error-only (`E20xx`) and shown as a flat list after
  a full analysis run; this extends it to a live, severity-classified feed
  (errors/warnings/hints) in its own panel, plus squiggly underlines in the
  editor itself, color-coded by severity, on the offending expression's own
  span as analysis re-runs on edit.
- Longer-term / exploratory: a compiler front-end built on the same model.

### Definition of done (v1)

1. Lexes and parses the **entire Delphi 13 source tree** (RTL/VCL/FMX/…) with
   zero errors.
2. Roundtrip: concatenated tokens + trivia == original source, byte-for-byte.
3. Golden AST tests keyed to the spec's feature numbering (e.g. test `5.4.1`
   covers the inline-`if` expression).
4. Semantic analysis over the same tree produces **zero false-positive
   diagnostics**. ✅ Reached 2026-07-30 on the flattened RTL+VCL+FMX corpus and
   on the `BuildWinVCL`/`BuildWinFMX` packages, and **extended on 2026-08-08 to
   every corpus we measure**: two real applications (3747 and 2121 units) and a
   third-party library's three packages report no false `E2003` under the
   opt-in member flag either. What is left anywhere is a unit whose source
   genuinely is not on the search path, plus one confirmed true positive. See
   the To-do for what holding that now depends on.

## Requirements

- Delphi 13.0 Florence or later (the parser is written in the language it
  parses).

## License

[MIT](LICENSE) © 2026 Oleksandr Skliar.

PasTree is an independent open-source project, not affiliated with or
endorsed by Embarcadero Technologies. "Delphi" is a trademark of Embarcadero
Technologies, Inc.
