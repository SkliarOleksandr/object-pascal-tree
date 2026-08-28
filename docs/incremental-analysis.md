# Incremental analysis

How PasTree avoids re-analyzing a whole closure when one file changes, what it
refuses to do and why, and what is still open.

Shipped in 0.9.0 (the parse donor and single-module reanalysis for body
edits); 0.10.0 added the consumer redo, which puts INTERFACE edits on the fast
path too; 0.11.0 made the blast-radius ceiling a tunable property after
measuring it. The demo host drives both mechanisms behind its `Incremental`
checkbox and is the worked example of the host-side contract below.

The problem it solves: an editor host re-analyzes on every pause in typing, and
a full closure rebuild costs seconds - 3.4 s on the demo's own 200-unit
closure, 29 s on a 3676-unit client project. The cost splits roughly as
interface parse 21%, full parse 27%, cross passes 52%, so caching the parse
alone can never be the whole answer.

There are two mechanisms. They are independent, both opt-in, and a host that
calls neither gets exactly the previous behaviour.

```
edit inside a routine body   -> single-module reanalysis   ~20 ms / ~300 ms
edit in an interface         -> module + affected consumers ~70 ms / ~1.5 s
anything refused             -> ordinary rebuild WITH the parse donor
a different project opened   -> ordinary rebuild
                                        (demo closure / big client closure)
```

## 1. The parse donor

`TPasSemaProject.AdoptParseDonor(ADonor)` - the host offers its still-alive
last-good project as a source of parse results for the next `Analyze*` call.

For every file whose donor model is a clean full parse of byte-identical text
(the main file and every `$I` include are re-read and compared exactly), the
preprocessing, lexing and parse are skipped: Phase 1 runs over the donor's
tree, which is immutable, and the new model shares its arrays. Everything else
- edited files, demoted units, oracle-reprocessed streams, units with
parse-time unresolved `$IF` guards - takes the normal path.

Why a donor project rather than a standalone cache:

- **No new lifetime.** A host already double-buffers: the last-good project
  stays alive while the next one builds, and is freed after the swap. That
  window IS the cache lifetime - no eviction policy, no ownership entity, no
  invalidation beyond the text compare.
- **No memory conflict.** A standalone cache would pin every tree the text
  demotion work learned to free. The donor pins nothing beyond the
  two-generation overlap that already exists.

Contract: the adoption is valid for the NEXT `Analyze*` call only and is
consumed by it (cleared in its `finally`, cancelled exits included); the donor
must stay alive until that call returns. `False` = configuration mismatch
(platform, extra defines, search paths, namespaces, aliases) and the run
proceeds donor-less. `StageTimings` reports `donorhits=..;donormiss=..;`.

Measured on the demo closure: 192 of 200 parses reused, interface+full waves
1894 -> 1326 ms. On the client closure a rebuild goes 29 -> 23 s. This is a
fallback optimization: it never makes an edit cheap, it makes the expensive
path less expensive.

## 2. Single-module reanalysis

`TPasSemaProject.AnalyzeModuleOnly(APath): Boolean` - re-parse ONE
already-analyzed unit, check the guards, swap the model into the project in
place, and re-run the passes for that unit and for the units a change in it
could reach. Nothing else in the closure is touched.

`False` means REFUSED and the project is UNCHANGED - the caller must rebuild.
Refusals are deliberately generous: a wrong fast path shows up as navigation
that lands somewhere plausible but wrong, which is the worst bug class here,
while a needless rebuild only costs time.

### What runs

```
re-parse      the edited unit
re-Phase-1    each affected consumer - no preprocessing, no parse: a fresh
              Phase 1 over the tree it already holds
cross passes  the same set, decl/inherited/with fixpoints included
```

The consumers are NOT patched, they are recomputed. Their text did not change,
so Phase 1 over their existing (immutable) tree is deterministic and
reproduces their own symbol numbering exactly; their cross-unit references are
then rebuilt against the new module from scratch. This is why a shifted symbol
index in the edited unit harms nobody, and why no old-to-new index matching is
needed.

### The blast radius

`AffectedConsumers` walks the REVERSE `uses` graph from the edited unit:

- every direct importer is in the set, whichever section imported it;
- the walk continues THROUGH a unit only if it imported in its INTERFACE
  section - such a unit may republish types from the edited one. An
  implementation-only importer cannot, so it is a leaf;
- over `ModuleRedoLimit` models (128 by default, a MEASURED value - see the
  open list) the call refuses and the host rebuilds.

The interface/implementation distinction needs no new data: the unit-reference
symbol's scope is either the interface one or the implementation one.

For a body edit the radius is always 1 - nothing outside the unit can see the
change.

What real radii look like, measured on the 3676-unit closure: a COM type
library unit reaches 28 models and is redone in ~1.8 s; a core types unit
that half the project imports reaches **1181** - a third of the closure, which
at ~57 ms per model would cost twice a rebuild. So a wide interface edit
rebuilding is not the fast path failing, it is the fast path being right; the
rebuild is still donor-assisted (23 s against 29 s). Editing the BODY of that
same core unit takes 303 ms.

### The guards

1. **Interface prefix reproduced exactly** - the symbol arena and the scope
   index space up to the implementation section: name, kind, order, scope
   shape. When it holds, only the edited unit is redone. When it does not, the
   consumers above are redone with it.

   Interface membership is decided by walking a scope's PARENT chain, not by
   comparing indices: the implementation scope is created with the unit (index
   2 in every unit measured) while an interface class's member scope gets a
   much higher index. The scan also continues past the boundary and refuses if
   anything interface-side follows it, rather than trusting the collect order.

2. **The instance table** must hold no entry naming a symbol of this model at
   or past the boundary. That table survives every pass and is keyed by
   (unit, symbol), so such an entry would dangle after the swap.

`sfExternalUnresolved` is excluded from the symbol comparison: `ResolveUses`
clears it on an analyzed model, so the old (post-pass) model and the new (raw
Phase 1) one legitimately differ there. Any future project-side symbol
mutation needs the same treatment, or the guard silently stops firing.

### Why a call is refused

Every refusal names itself in `StageTimings` as `module=refused:<reason>` -
log it, because a fast path that quietly stops firing is indistinguishable
from a slow analyzer.

| reason | meaning |
|---|---|
| `unknown-file`, `not-full` | not an analyzed unit of this project |
| `demoted` | the model's text layer was freed (see the memory dial below) |
| `parse-failed` | unparsable now; the closure changed, a rebuild's job |
| `unresolved-if` | the stream depends on the `$IF` oracle, i.e. on the whole generation's symbol state - never reproducible per module |
| `new-dependency(X)` | an import resolves to a file the closure never loaded |
| `no-clean-boundary-*` | no implementation scope, or the arena is not split cleanly at it |
| `intf-sym#N`, `intf-scope#N` | the interface prefix moved in a way the redo cannot express |
| `too-many-consumers(N>L)` | the blast radius N exceeds `ModuleRedoLimit` (128; 0 or less lifts the ceiling). The number is reported because "too many" alone says nothing about whether the limit is set sensibly |
| `instance-impl-sym`, `instance-into-changed-intf` | the instance table points into the part being renumbered |

### Driving it from a host

`TPasAsyncSession.CreateForModule(AProject, APath)` takes OWNERSHIP of the
host's last-good project, runs the call on its worker, and hands the project
back through `TakeProject` - accepted or refused, it always comes back and is
always consistent. `ModuleAccepted` says which happened. The buffer goes in
with `SetBuffer` BEFORE `Start`, exactly like a full session, and no other
thread may read the project during the call: it mutates models in place.

A host's edit path then reads:

```pascal
LSess := TPasAsyncSession.CreateForModule(FProject, LPath);
FProject := nil;                       // the session owns it until TakeProject
LSess.SetBuffer(LPath, LText, LVersion);
LSess.Start;  ...  LSess.WaitFor;
FProject := LSess.TakeProject;
if not LSess.ModuleAccepted then
  <ordinary rebuild session, with FProject as SetParseDonor>;
```

After an accepted run only the re-analyzed module's diagnostics are new;
every other module's are untouched, so a host that publishes per-file
diagnostics republishes one file.

**The memory dial.** `DemoteClosedUnits` frees the text layer of every unit
that is not open, which is worth a lot of RSS - and a demoted unit is a donor
MISS and a fast-path refusal. Before 0.9.0 that traded memory for nothing
measurable; now it trades memory against the latency of every edit. The demo
exposes the choice as a checkbox; a host has to make it deliberately.

## 3. What it costs (measured, every step verified identical to a full build)

| closure | body edit | interface edit | full rebuild |
|---|---:|---:|---:|
| demo, 200 units | 19-33 ms | 29-204 ms | ~3400 ms |
| client, 3676 units | 310 ms | 1525 ms | ~29 000 ms |

Hit rate on the demo closure over 40 synthetic edits: 19 of 20 body edits
accepted (the refusal is a unit whose stream depends on the `$IF` oracle -
permanent for that unit), and interface edits accepted whenever the radius
fits the limit.

Note what the numbers say about the shape of the cost: a body edit
(`module=1`) and an interface edit pulling in 12 models
(`module=12`) cost the SAME on the demo closure. The redo set is not what
dominates - see the open list.

## 4. How it is verified

`tools\PasTreeDiffHarness.dpr` runs an edit sequence through the full pipeline
AND the incremental path over the same closure and compares RefMap, ExtRefMap
and diagnostics across the ENTIRE closure after every step. The corpus suites
only ever prove the full path.

- default mode: the donor CHAIN (rebuild k adopts rebuild k-1);
- `-module`: single-module reanalysis, falling back to a donor rebuild on
  refusal, exactly as a host must;
- `-selftest`: the negative control. The incremental side is fed the PRE-edit
  text of each step, and every edit step is REQUIRED to mismatch - a blind
  comparator would make every green run above worthless;
- `-st`: both sides single-threaded, for ruling a concurrency effect in or out.

**A differential gate needs a FROZEN corpus.** Running it against a working
copy somebody is editing produces exactly the signature of an analyzer defect
- different units diverging on different runs. That cost a full investigation
once; the give-away was a unit whose source LENGTH changed between two builds
of "the same" corpus. Snapshot first.

Unit-level coverage lives in `tests\SemaProjectSmoke.dpr` (donor + module
paths, refusals, the consumer redo) and `tests\AsyncSmoke.dpr` (the session
wrapper).

## 5. Open - what could still be improved

Ordered by evidence, not by interest.

**A. The helper registry is the module path's fixed cost.** `BuildHelperMap`
rebuilds over EVERY model on every module run, and `PrepareDeclWork` /
`SizeCrossWork` size their arrays over every model too. That is why a
1-model and a 12-model redo cost the same ~157 ms on the demo closure. Making
it incremental should take the module path into the tens of milliseconds and
helps every edit. Nothing else here is worth as much.

**B. DONE - the radius ceiling was measured and raised, 24 -> 128.** It is now
the `ModuleRedoLimit` property (0 or less = no ceiling), and the harness can
override it per run with `-redolimit:N`. What the measurement said on the
3676-unit closure: a radius of 28 models costs 1.8-2.1 s against a 29 s
rebuild - about 300 ms fixed plus ~57 ms per model - so break-even sits near
500 models, and the old 24 was refusing a case 15x cheaper than its own
fallback. 128 keeps the worst case near 7 s; a host that knows its closure can
tune the property.

**C. The instance table forces a refusal on interface changes.** Fixable by
matching old declarations to new ones (name, kind, nesting), repointing the
entries and rehashing the key dictionary. Measured frequency: once in three
interface edits on the client closure, never on the demo. Do it when it bites.

**D. A new `uses` entry falls back to a rebuild.** The newcomer needs loading,
Phase 1 and cross passes of its own - bounded work that could be done
incrementally, but typing an import is rarer than typing code.

**E. Multi-file edits are not expressible.** The entry point takes one path
while the machinery already redoes a SET, so the natural shape is an overload
taking several edited files: re-parse each, union their radii, one pass run.
Matters for refactorings and file watchers, not for typing.

**F. `$IF`-oracle units are excluded forever** and that is correct: their
token stream is a function of the whole generation's symbol state.

**G. Sub-file incremental parsing: deliberately not done.** We re-parse the
whole edited file: 20-33 ms on demo units, ~300 ms on the biggest client unit,
against a fixed ~157 ms of pass overhead (item A). Reusing parts of one file's
tree is a large, error-prone piece of work whose prize is currently smaller
than A's. Revisit if A lands and the parse becomes the dominant term.

**H. A frozen library image** - analyze the IDE's own sources once and reuse
them across projects. They are a closed subset (they never use project units),
so their cross state is self-contained; the obstacles are the project-wide
tables (instances, helpers), which would need a frozen half and a project
half, and the memory the image holds. Scoped as in-memory only, "library" =
everything under the IDE root, third-party excluded (those differ per
project). Different axis from everything above: it speeds up OPENING a
project, not editing one.

Rejected on measurement, recorded so it is not retried: memoizing the
generic member lookup. The repeat rate is real - 533k queries over 193k
distinct keys in one run, 2.76x - but a per-model lock-free cache moved no
time at all on any corpus, because the walk itself is cheap and hashing the
key costs what it saves. The counters survive behind the
`PASTREE_MEMBERSTATS` define.
