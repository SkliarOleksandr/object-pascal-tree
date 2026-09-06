# Incremental analysis

How PasTree avoids re-analyzing a whole closure when one file changes, what it
refuses to do and why, and what is still open.

Shipped in 0.9.0 (the parse donor and single-module reanalysis for body
edits); 0.10.0 added the consumer redo, which puts INTERFACE edits on the fast
path too; 0.11.0 made the blast-radius ceiling a tunable property after
measuring it; 0.15.7-0.15.8 replaced "redo everyone who can see the unit"
with a diff of the interface and a name-level choice of who is redone. The demo host drives both mechanisms behind its `Incremental`
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
edit in an interface         -> module + the consumers that  ~70 ms / ~0.5 s
                                can SEE the change
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

### The blast radius, and who inside it is redone

`AffectedConsumers` walks the REVERSE `uses` graph from the edited unit (over
a reverse index built per call - a few tens of thousands of steps, where the
first cut rescanned every model per frontier unit):

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
library unit reaches 28 models; a core types unit that half the project
imports reaches **1260** - a third of the closure, which at ~57 ms per model
would cost twice a rebuild. Until 0.15.8 the whole reach WAS the redo set, so
typing a new constant into that unit refused (`too-many-consumers`) and cost
a 24 s donor rebuild every time.

The reach is only the upper bound now. `DiffInterface` compares the old and
new interface over `MatchSymbols`' map (guard 2 below) and sorts every old
symbol into unchanged / changed / removed - changed meaning a Phase-1
attribute differs or the declaration no longer reads the same token for
token (`DeclRootOf` + `SpanTokensEqual`) - and collects the NAMES of added
symbols another unit could reach by name (globals, members, enum values; not
parameters). A class, interface, record or object is compared with its
MEMBERS masked out (`SpanTokensEqualMasked`, each member's span plus its
terminating `;`): each member is a symbol with its own verdict, so a method
added to a hub class, or a field typed into a hub record, is an added name,
not a changed type, and only the models mentioning that name are redone.
Enums keep the whole-declaration comparison - a value added in the middle
moves the ordinals after it. The one consumer that can depend on a record's
LAYOUT without naming a field is a `$IF` that asks the oracle for `SizeOf`;
such a consumer's stream cannot be re-decided by a redo that keeps its tree,
so any oracle-built stream in the reach is a refusal (`consumer-oracle`),
which also covers a constant's value folded the same way. `SelectConsumers`
then keeps, out of the reach, only:

- a model holding a pair (unit, changed-or-removed symbol) in any of its
  four cross-unit maps, or an instance tainted by one;
- a model whose tree MENTIONS an added name anywhere - the shadowing test:
  that name may have resolved elsewhere, or nowhere, and may now bind here.
  A token scan with a length filter, no allocation for the bulk of nodes.

Everyone else in the reach is UNTOUCHED: `RenumberConsumer` follows its
bindings into the unit through the map and nothing else about it changes -
its diagnostics included. A helper type among the changed/added/removed
forces the whole reach, because a helper attaches by TYPE and no name test
can find who it now affects. The `ModuleRedoLimit` ceiling applies to the
SELECTED set.

Measured on the same closure, every step verified identical to a full
build: a new const, type or routine in the core types unit is now a
one-module run of ~500 ms (`reach=1260;renumbered=1259`); a unit appended to
its interface `uses` selects the 82 models that mention the new unit's name
and takes 4.2 s; a body edit there is 337 ms. The STAGE string carries the
accounting: `intfchanged=1;changed=C;removed=R;added=A;reach=N;renumbered=K;`
plus `helpers=1;` when the fallback fired.

### The guards

1. **Interface prefix reproduced exactly** - the symbol arena and the scope
   index space up to the implementation section: name, kind, order, scope
   shape. Same SHAPE is not the same interface, though: Phase 1 does not
   resolve a heritage clause, a cross-unit type name or a constant's value,
   so `TA = class` becoming `TA = class(TBase)` leaves the arena identical.
   Until 0.15.9 that edit passed as a body edit and a consumer inheriting
   from TA kept its stale members - found by the harness's `parent` kind, not
   by any user. The declaration TEXT is therefore diffed on this path too
   (over the identity map), and any difference sends the edit down the
   interface path above.

   Interface membership is decided by walking a scope's PARENT chain, not by
   comparing indices: the implementation scope is created with the unit (index
   2 in every unit measured) while an interface class's member scope gets a
   much higher index. The scan also continues past the boundary and refuses if
   anything interface-side follows it, rather than trusting the collect order.

2. **The instance table** is carried across the swap. It survives every pass
   and is keyed by (unit, symbol), so an entry naming a symbol of this model
   at or past the boundary would dangle once the numbering moved. Until
   0.15.7 that was a refusal on every interface edit of a unit whose generics
   anybody instantiates - which on the client closure is every hub unit.
   Now `MatchSymbols` pairs old and new symbols by identity - (kind, name,
   declaring scope named structurally by its owning symbol, ordinal, generic
   arity) - and `RepointInstances` rewrites the entries in place and rehashes
   the key dictionary. Instance INDICES do not move, which is what makes it
   safe: every model's `SymTypeX`/`ExprTypeX` carries them, and none of those
   models is touched. The one shape that still refuses is an instance whose
   generic has no successor (the generic was deleted, or an overload before
   it changed its identity): `instance-unmatched-sym(<name>)`.

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
| `too-many-consumers(N>L)` | the SELECTED redo set N exceeds `ModuleRedoLimit` (128; 0 or less lifts the ceiling). The number is reported because "too many" alone says nothing about whether the limit is set sensibly |
| `consumer-demoted` | a consumer to redo has no text layer any more (see the memory dial) |
| `consumer-oracle(<unit>)` | a consumer in the reach has an oracle-built token stream: its `$IF`s may have folded this unit's constants or record sizes, and only a re-preprocess can re-decide them |
| `instance-unmatched-sym(<name>)` | an instance names a symbol of this unit that the new text no longer declares (a deleted generic, or an overload whose ordinal moved) - see guard 2 |

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
| client, 3676 units | 6-130 ms | 21-200 ms | ~29 000 ms |

The client rows are 0.15.11 numbers: a body edit is 6 ms in a library unit
and 119 ms in the 300 KB core types unit (all of it the re-parse); a new
const, type, routine or method in that core unit is ~250 ms, of which the
passes are ~15 ms and the rest is the parse (~100 ms) plus the decision over
1260 models (~70 ms); the whole edit is ~190 ms. Before 0.15.7 the same interface edits refused and cost a 24 s
rebuild; before 0.15.10 every module run carried a fixed 141-159 ms of
`BuildHelperMap`.

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

- `-script:<file>` replaces the synthetic sampling: one `kind <path>` per
  line, kind = `body`, `intf`, `blank`, `comment`, `const`, `type` (the last
  four land at the end of the interface section - the "start typing in a big
  interface" shapes), `implvar`/`implvartop` (a variable at the end / the top
  of the implementation section), `intfuses` (a unit appended to the
  interface uses clause - the edit that renumbers every interface symbol),
  `member` (a method added to the first interface class), `overload` (a
  second declaration of that class's first method - the name exists, the
  overload link is what changes), `recfield` (a field added to the first
  interface record), `parent` (the first parentless class gets an explicit
  `(TObject)` - a no-op for dcc and for Phase 1, a changed declaration for
  the diff), and `insert <path>|<line>|<text>` / `replace` for replaying an
  exact typing sequence. On the client closure every one of these in the hub
  types unit (1260 models in reach) is a one-module step of ~170-200 ms
  against a 29 s rebuild; `intfuses` selects the ~80 models that mention the
  new unit's leaf name;
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

## 4b. The parser is part of the fast path

The module path analyzes whatever the buffer holds at each pause in typing,
and most of those states are not valid Pascal. What the parser does with an
UNFINISHED declaration therefore decides how many symbols the diff sees as
removed. Until 0.15.12 a type name alone on a line (`ttt`, the author about
to type `= Integer;`) took the rest of its section with it: the missing `=`
was reported, the next line was read as this declaration's type, the `;` was
missing too, the section loop ended on the stray `=`, and every following
token went down as "declaration expected" until the next section keyword.
In the client hub unit that was 326 interface symbols gone per keystroke,
348 consumers to redo, a refusal, a 25 s rebuild and hundreds of false E2003
until the line was finished. The replayed typing sequence (`insert` /
`replace` harness kinds) is what found it; the harness's own edits were all
complete declarations.

Now a declaration ends where the next one begins (`TPasParser.AtDeclHead`):
a declaration cut short before its `=` / `:` / type is closed as it is - its
name IS declared - and a declaration missing its `;` skips to the next
declaration head or section boundary and loses only itself. Every state of
typing `ttt = integer;` into the hub unit is a one-module run of 170-290 ms
with `removed=0`; the flat corpora still parse with zero diagnostics.

The same day, the same method found the second shape: `property` typed into
an interface body, no name yet. The parser's specifier loop ate the `end`
of the interface (one error, one token, repeat), and the resolver, handed a
PropertyDecl with no children, asked `NextSib(NIL_NODE)` - Nodes[-1], which
in a release build came back as the root node, so Collect recursed into the
whole unit until the stack ran out. The module path saw an exception and
refused with `parse-failed`; the host rebuilt. The specifier loop now stops
at a stray token, the child-navigation helpers answer NIL_NODE for NIL_NODE,
and a refusal names the exception: `parse-failed(EClass: message)`. Every
state of typing that property is a module step of 200-400 ms.

Third shape, same day: `type s =` typed above a method. `s = procedure
SetData(...)` read as a procedural type and swallowed the method; where the
header's failed `;` then skipped past the class's `end`, the rest of the unit
became that class's members - 17959 symbols with a new identity, a refusal.
A `procedure` / `function` followed by a NAME is now not a type expression
(the declaration is left without a type, the header is left for the member
loop); `S = procedure stdcall` still is one.

Fourth shape: a bare `function` at section level above `TRecno = ...`. The
routing keyword took TRecno as its name, `= umcsTypes.TRecno` as a method
resolution clause, and the section loop then had no keyword to resume on -
every following token "declaration expected" again. A routine whose next
token is `Ident =` has no name (a method resolution clause is always
dotted) and ends there; and `ParseDeclSections` treats a declaration head
with no keyword in front as the resumption of the last section kind (or of
what the head's shape says - `:` and `,` mean var), so the section goes on.

Fifth, the `uses` clause (0.15.13). A unit typed into the list without its
comma yet ended the clause, and every unit after the cursor became a stray
token - 15 imports gone. The clause now reads on over a missing comma. And
the name test no longer counts a unit REFERENCE as an added name: nobody
outside can name this unit's uses entry, while its leaf (`Classes`,
`Windows`) is an identifier half the closure mentions - typing `System.Classes`
into the hub unit's uses selected 1103 models. Every state of typing a unit
into the list is a one-module run now.

**The resilience suite (0.15.14) enumerates these instead of waiting for the
next report.** `testsResilienceSmoke.dpr` types 28 snippets into a fixture
unit at nine kinds of declaration site - uses, record body, type section,
interface body, class body, const, var, routine declarations, routine body,
statements - one keystroke at a time, and checks after every prefix that
every symbol the fixture had (kind, name, owner) is still there and that
Phase 1 did not raise. Its first run found 15 failing snippets; they came
down to a handful of parser rules, now in place: a declaration head on its
own line where a type, an ancestor, a type argument, a subrange bound or a
variant tag was due is the NEXT declaration (`TokenStartsLine` /
`AtLineDeclHead` - the line break is recovery-only evidence, consulted after
the grammar has already failed to parse the state); `Ident =` is never a
field, so a class body meeting one has no `end` yet; a property specifier
must be one of the ten specifier words; a named `procedure`/`function` is
not an anonymous method; an unfinished variant part or branch does not take
the fields behind it. One state is left ambiguous on purpose and declared so
in the suite: `procedure(A:` above `TRecno = Integer;` reads as a wrapped
parameter with a default, because that is what it IS in Vcl.StyleAPI - the
line heuristic is off inside parameter lists (`FParamDepth`), the corpora
stay at zero diagnostics, and TRecno is lost for that one keystroke.

## 5. Open - what could still be improved

Ordered by evidence, not by interest.

**A. DONE (0.15.10) - the helper registry is incremental on the module
path.** `UpdateHelperMap` keeps the registry and the per-model index from the
last run: pairs naming the renumbered unit follow the symbol map, the redone
models recollect their declared helpers, and the index is republished for
them and - only when a redone model's exported helpers actually differ - for
their direct importers. `BuildHelperMap` (wholesale, parallel) remains the
full pipeline's. Measured on the client closure: the `helpers` stage went
from 141-159 ms to 0-5 ms, the whole pass tail of a one-module run from
~155 ms to 3-14 ms. The per-stage split is in `StageTimings` as
`mp=resolve:N,helpers:N,decl:N,inherited:N,with:N,calls:N,bindx:N,xtype:N;`.
What is left of the fixed cost is the re-parse of the edited unit (~100 ms
for the 300 KB core unit) and, on an interface edit, the decision over the
reach: `decide=` in the stage string, split as
`dec=shape:N,match:N,diff:N,reach:N,select:N,inst:N` (cumulative). 0.15.11
took that from 136 to 62-81 ms on the 1260-model reach: `MatchSymbols` keys
symbols by a record (kind, name, interned scope id, arity, ordinal) instead
of a Format'd string per symbol (56 -> 26 ms); `AffectedConsumers` counts
and preallocates its reverse index instead of appending (22 -> 5 ms); the
consumer scan and the renumbering run in parallel over the reach
(`ParallelFor`), and the identifier scan compares characters against the
candidates of the identifier's own length without building a string - the
allocating version was SLOWER in parallel than sequential, the threads
queuing on the memory manager (commit 47 -> 8 ms, select 41 -> 28 ms).

**B. DONE - the radius ceiling was measured and raised, 24 -> 128.** It is now
the `ModuleRedoLimit` property (0 or less = no ceiling), and the harness can
override it per run with `-redolimit:N`. What the measurement said on the
3676-unit closure: a radius of 28 models costs 1.8-2.1 s against a 29 s
rebuild - about 300 ms fixed plus ~57 ms per model - so break-even sits near
500 models, and the old 24 was refusing a case 15x cheaper than its own
fallback. 128 keeps the worst case near 7 s; a host that knows its closure can
tune the property.

**C. DONE (0.15.7) - the instance table follows a renumbered unit.** Old and
new declarations are matched by identity and the entries repointed (guard 2
above). Measured on the client closure: a body edit in a generics-heavy
library unit that used to refuse `instance-impl-sym` is a 166 ms module step;
an interface edit or a new interface `uses` entry in a project types unit
that used to refuse `instance-into-changed-intf` is a 4-model redo at 1.35 s
against a 28 s rebuild. Harness kinds `body`/`intf`/`intfuses` on those
units are the gate.

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
