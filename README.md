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
  `deprecated`, visibility words, routine directives...) that only lights up
  where the AST actually proves them to be directives, `$IFDEF`'d-out code
  greyed out like the real IDE, and ctrl+hover link rendering.
- **Go-to-declaration** (ctrl+click) — parity target is "any identifier
  navigates exactly like the real IDE does," and the current matrix covers:
  local and cross-unit declarations, member access through inheritance/
  generics/aliases, the implicit `System` unit, compiler intrinsics with no
  source declaration (routed to `System.pas`'s header, like the IDE),
  `Result`, `uses` clause names and qualifiers, the whole project closure
  (not just the main file), units only reachable via the IDE's own registry-
  read library/browsing search paths, unit namespaces (`-NS`) and aliases
  (`-A`).
- **Declaration ↔ implementation toggle** (Ctrl+Shift+Down / Ctrl+Shift+Up) —
  jumps from a method or routine's forward declaration to its body's first
  statement and back to its name, overload-precise (matched by full
  parameter-type signature, not just arity), correctly handling comment-only
  bodies and refusing to cross from inactive `$IFDEF`'d-out code into active
  code.
- **Semantic diagnostics** — project-wide `E20xx`-style errors from a
  `.dproj`-aware loader (search paths, namespaces, unit aliases, platforms),
  validated continuously against the real Delphi RTL/VCL/FMX source tree.

## Layout

| Path | Contents |
|---|---|
| `source/` | the library: `PasTree.Types`, `PasTree.SourceManager`, `PasTree.Lexer`, `PasTree.Preprocessor`, `PasTree.Ast`, `PasTree.Parser`, `PasTree.DProj`, `PasTree.Platforms`, `PasTree.Ast.Json`, `PasTree.Project`, and the semantic layer `PasTree.Sema.*` (`Model`, `Resolver`, `Types`, `Project`, `Builtins`, `Nav`, `Async`, `Diagnostics`, `Dump`) |
| `demo/` | `PasTreeDemo` — a VCL host (SynEdit + VirtualTreeView) exercising the highlighter and navigation features interactively over real projects |
| `tests/` | 10 DUnitX-style smoke suites (`ParserSmoke`, `StagedParseSmoke`, `DProjSmoke`, `SemaSmoke`, `SemaTypeSmoke`, `SemaXTypeSmoke`, `SemaOverloadSmoke`, `SemaProjectSmoke`, `SemaNavSmoke`, `AsyncSmoke`) plus golden JSON trees and full-corpus runs |
| `tools/` | CLI drivers per pipeline stage (`PasTreeLex`, `PasTreePP`, `PasTreeParse`, `PasTreeJson`, `PasTreeSema`, `PasTreeSemaProject`) and the node-kinds generator |
| `docs/` | `editor-features.md` — the living IDE-parity spec for the demo's editor features |

## To do

Still open, roughly in the order we're tackling it:

- **One cross-model expression typer, not two.** There are currently two:
  `CrossType`'s `Walk`, which types every expression node, and
  `WithTargetTypeX`, a hand-rolled subset that types a `with` target. The
  duplication is real and it is why `with` needed a run of shape-by-shape
  fixes — a `with` target is simply *an expression whose type must be a
  structured type*, and it deserves the general typer rather than a case list.
  What blocks the naive merge is pass ORDER, and the cycle is genuine: the with
  pass must commit its bindings before `CrossType` runs, because `CrossType`
  types with-*body* expressions using exactly those bindings — so the with pass
  cannot call `CrossType` for its target. Unifying them means making the two one
  iterated pass (the with pass already runs to a fixpoint, so the machinery
  exists). That is a refactor of the largest procedure in the codebase for
  maintainability, not for diagnostics, and it wants the byte-identical-dump
  check (`-st` vs parallel, plus both corpora) as its safety net.

  Worth recording *why* the shape list grew, because it was not really about
  shapes: three of the four `with` defects fixed on 2026-07-29 had one root
  cause — code asking `RefMap`/`ExtRefMap` for a binding that a LATER pass
  produces. At with-pass time those maps are legitimately incomplete, and the
  rule is "derive from types, never read the ref maps". That rule now lives in
  one place (`DesignatorSymX`'s fallback); the remaining special cases should be
  converted to go through it rather than grown.
- **Go-to-declaration inside an opened `.inc` tab.** Navigating *into* an
  include file already works; resolving an identifier typed *inside* an
  already-open include tab does not yet (`IdentAt` is currently main-file-only).
- **Zero-diagnostic parity on the real RTL/VCL/FMX.** Analysis is stable and
  crash-free over the full source tree, but still produces a nonzero, tracked
  count of `E2003`-style false positives to work down to zero — the v1
  "definition of done" below.
- **Helper precedence inside the same-unit join.** Cross-unit helper
  injection is done (`BuildHelperMap`/`ActiveHelperFor`/`FindMemberX`,
  dcc-verified rules: per-referring-unit last-uses-wins, helper member hides
  the type's own, implementation-section helpers stay unit-local) — but the
  SAME-unit path still resolves through `JoinHelperScopes`' scope join, which
  checks the type's OWN names before the joined helper scope. When a
  same-unit helper deliberately shadows a member of its own extended type,
  Phase 1 binds the type's member where dcc binds the helper's. Confined to
  same-unit shadow pairs; fixing it means teaching the join (or
  `FindLocalDeep`) an ordering exception.
- **LSP/LSIF server.** The demo (VCL-hosted) is the only editor integration
  today; a Language Server Protocol server (live highlighting/navigation/
  diagnostics/rename/etc. over the same Sema/Nav layer) plus LSIF dump
  generation (precomputed navigation for code browsing without a live
  server) are the planned next consumers.
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
   diagnostics**.

## Requirements

- Delphi 13.0 Florence or later (the parser is written in the language it
  parses).

## License

[MIT](LICENSE) © 2026 Oleksandr Skliar.

PasTree is an independent open-source project, not affiliated with or
endorsed by Embarcadero Technologies. "Delphi" is a trademark of Embarcadero
Technologies, Inc.
