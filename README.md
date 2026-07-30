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
- **Go-to-declaration inside an opened `.inc` tab.** Navigating *into* an
  include file already works; resolving an identifier typed *inside* an
  already-open include tab does not yet (`IdentAt` is currently main-file-only).
- ~~**Zero-diagnostic parity on the real RTL/VCL/FMX.**~~ **Reached on
  2026-07-30.** The flattened RTL+VCL+FMX corpus (726 files) reports ZERO
  `E2003`/`E2034`/`E2035`; the only diagnostics left are honest `F1027`s for
  units genuinely absent from the flat directory. `BuildWinVCL.dpk` (271 units)
  and `BuildWinFMX.dpk` (362 units) are both clean end to end. Stable run to run
  and identical single-threaded. This is a floor to HOLD, not a finished job —
  the next corpus is the real project (see the AVImark note below), and the two
  precedence gaps below are known places where the binding is right-ish for the
  wrong reason.
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
- **Arity check in the intra-unit typer ignores inherited members.** The
  cross-unit check (`CheckCalls`) now yields to an inherited member before
  reporting, but `PasTree.Sema.Types.SelectOverload` has its own arity
  diagnostic and does not. It is gated to units with NO `uses` clause at all, so
  nothing in the RTL/VCL/FMX corpus reaches it — but a bare unit with an
  inherited method shadowed by a same-named global still gets a false `E2035`.
  Fixing it means the typer needs the ancestor walk the resolver already has.
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
- **Declaration-site precedence: inherited member vs used-unit global.** A name
  written inside a class DECLARATION is now found in the enclosing classes'
  ancestries (`CrossResolveDecl`), but only *after* the used units — dcc has it
  the other way round, so a used unit's global with the same name as an
  inherited member wins where it should lose. Closing it means deferring EVERY
  declaration-site name that does not resolve locally — that is every cross-unit
  type reference in every class in the closure, each through `FindMemberX`.
  Deliberately not paid for a collision nobody has hit yet.
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
- **Units with no source (`.dcu`-only third-party libraries).** The blocker for
  real projects: AVImark pulls in DevExpress, JCL, Orpheus, RaveReport and
  friends, and where only `.dcu` ships, every importer gets an `F1027` and — far
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
     Not hypothetical: the first real project run hit exactly this — AVImark's
     last 5 `F1027` are `VclTee.*`, and TeeChart ships `lib\win32\release\
     VclTee.Chart.dcu` plus `include\windows\vcl\VCLTee.Chart.hpp` with **no
     `.pas` anywhere** in the Studio tree. A `.hpp` reader would close that
     cluster without touching the `.dcu` format at all.
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
- **Navigation history (Back / Forward).** Ctrl+click jumps; nothing remembers
  where it jumped FROM, so getting back is manual. A stack of visited positions
  with Back (and Forward, which is nearly free once Back exists) — conventional
  bindings are Alt+Left/Alt+Right plus the mouse's XButton1/XButton2, which
  `TSynEdit.OnMouseDown` already receives.
  Two things decide whether this works or rots:
  - *Store file path + line/col, never node or symbol indices.* Every
    re-analysis (`ReanalyzeForNav`, armed by any edit) rebuilds `FSemaProject`
    from scratch, so every index into it is invalidated — a history holding them
    would jump to garbage after the first keystroke. A path and a caret position
    survive.
  - *Push the ORIGIN at jump time*, in `EditorMouseDown`'s deferred block, next
    to where the target caret is set — that block is the single place a jump
    actually happens. Collapse consecutive entries pointing at the same line so
    repeated clicks in one spot do not bury the history.
  Open question worth deciding rather than discovering: a jump into a unit that
  had no tab OPENS one, so Back may leave a trail of tabs the user never chose
  to open. Either close a tab Back retreats out of (if the jump opened it), or
  leave it and accept the clutter — but pick one deliberately.
- **Recent projects on `Open Project...` (split button).** The single most-worn
  path in the demo today: browse to the same `.dproj` by hand, every time. A
  drop-down of the last ~10, most-recent-first, deduped by full path,
  clicked-entry-moves-to-top.
  Persistence has no home yet — the demo currently reads the registry only for
  the IDE's own library paths (`ReadIdePaths`) and saves nothing of its own. So
  this needs the first piece of demo state, and it is worth putting the file
  where the next settings will also fit (platform, threading mode, highlighter
  choice, colour — all currently reset on every launch) rather than adding one
  registry value for one list. Prune entries whose file no longer exists at
  display time, not at save time, so a temporarily disconnected network path
  does not silently drop out of the list.
- **`.groupproj` (project groups), and a project TREE in the demo.** Today the
  demo opens one `.dproj` and shows its units as a FLAT list, which stops being
  readable at AVImark's 1542 files and cannot represent a group at all. Two
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
    any `.dproj` live (3790 analyzed vs 1542 listed for AVImark — the other
    2248 are library units nothing in the UI currently surfaces). Worth keeping
    those two axes distinct in the model rather than merging them into one list:
    "files the project declares" and "units the analysis reached" answer
    different questions, and the second is what the diagnostics are keyed to.
- **A 64-bit build of `PasTreeSemaProject`, and of the demo.** Already needed:
  the Win32 tool dies with `EOutOfMemory` on AVImark once the registry search
  paths are supplied (2631+ units, 168 MB of source), and the demo will hit the
  same wall as projects grow. Nothing in the library is 32-bit-specific — it is
  purely address space. Build the tool with
  `dcc64 -U"%BDS%\lib\win64\release" -U..\source -NSSystem;System.Win;Winapi;Data;Xml -N0out64 -Eout64 PasTreeSemaProject.dpr`;
  what is missing is making that the default rather than a manual step.
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
   diagnostics**. ✅ Reached 2026-07-30 on the flattened RTL+VCL+FMX corpus and
   on the `BuildWinVCL`/`BuildWinFMX` packages — see the To-do for what holding
   it now depends on.

## Requirements

- Delphi 13.0 Florence or later (the parser is written in the language it
  parses).

## License

[MIT](LICENSE) © 2026 Oleksandr Skliar.

PasTree is an independent open-source project, not affiliated with or
endorsed by Embarcadero Technologies. "Delphi" is a trademark of Embarcadero
Technologies, Inc.
