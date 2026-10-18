# Light mode: library units interface-only

PasTree analyzes the whole `uses` closure of a project, library code
included: every RTL, VCL and third-party unit is parsed, resolved and typed in
full, bodies and all. For an editor host most of that work is wasted - the
user edits their own units, and their own units bind only to what the library
units' INTERFACES declare. Light mode lets a host say which directory trees
hold somebody else's code; the units there are analyzed interface-only for
good, and the project's own units are analyzed exactly as before.

Measured on a 3,782-unit closure (1,695 own units, the rest RTL, VCL and a
third-party component suite):

| | units | analysis | CPU | held | after `DemoteText` |
| --- | --- | --- | --- | --- | --- |
| full | 3,782 | 3.0 s | 31 s | 2.3 GB | 1.5 GB |
| light (every library tree) | 3,086 | 1.8 s | 14 s | 1.2 GB | 0.86 GB |

"After `DemoteText`" keeps the own units warm, as a long-running host does.
Every binding the analysis makes in the own units - references, expression
types, external references, call targets, cross-unit types, diagnostics - is
identical in both modes (compared per unit by identity: file, symbol name and
declaring node, never by model id).

Light mode is opt-in. The drivers (`AnalyzeProject`, `AnalyzeStaged`,
`AnalyzeFile`, `AnalyzeDirectory`) default to full mode, and the corpus gates
that measure the analyzer run in full mode.

## API

`TPasSemaProject`:

- `LightPaths: TArray<string>` - the directory TREES whose units are light.
  Stored normalized (full path, lower case, trailing delimiter: the
  navigator's `LibraryPaths` form, `PasNormalizeDirTrees`), matched by prefix
  (`PasUnderDirTrees`). Empty - the default - means no light unit. Set before
  a run; a later run with other trees is allowed.
- `IsLightFile(APath)` - whether the file loads as a light unit: under a
  `LightPaths` tree and not exempt (below).
- `IsLight(AMid)` - the model's flag, `TPasSemaModel.Light`.
- `LightCount` - how many models are light, for status lines and logs.

`TPasAsyncSession.SetLightPaths` forwards the trees to the session's project;
set it before `Start`, like the other switches (after `Start` it raises
`EInvalidOperation`).

## Exempt: what is never light

A light own unit gives wrong answers with no error, so the rule errs toward
own:

- every file the host pinned with `PinUnitFile` - the project's listed files;
  own always wins;
- the run's roots: the main file, `AnalyzeStaged`'s roots (a library file a
  host opens as a root is analyzed in full), a directory run's files;
- everything under the project directory (`SetProjectDir`, or the main file's
  directory when the host set none) - a host that put its own tree into the
  list does not get light own units.

The exempt set is a snapshot taken when a run starts; `IsLightFile` is called
from parse workers and reads only that snapshot. A unit's own
`uses X in 'path'` does not exempt X - a program's listed files are exempt
through the host's pins, not through the in-path pins the resolver adds while
it runs.

A program, library or package under a light tree is not light: it has no
interface section and parses fully whatever the tree says.

## What a light unit is

- **Its implementation is its `uses` clause alone** (0.116.0): the parse
  (`TPasParser.ParseFile(..., pmInterfaceAndImplUses)`) reads the interface,
  then the implementation section's node and the `uses` clause after it, and
  stops - no routine bodies, no initialization or finalization, no
  implementation-only types. The tree is still a prefix of the full parse
  (invariant I7, with its own documented delta).
- **Its implementation `uses` entries are resolved, not followed.**
  `TPasUsesRef.InImpl` marks them. One naming a unit that is loaded anyway is
  an ordinary edge (`UnitId` is that model); one naming another light unit
  that nothing else loads is `UNIT_NOT_LOADED` - resolved to a file and on
  purpose not loaded: no F1027, no E2003 gate, counted as resolved by
  everything that counts unresolved names, and passed by every "is there a
  model" test like `NIL_SYM`. An entry that resolves to nothing stays
  `NIL_SYM`, a real F1027. On the closure above 696 units are never loaded.
- **An own unit named there IS loaded**, in full: the patched library copies
  a project keeps in its own tree, whose only importers are library
  implementation sections (11 on the closure above, plus the 28 library
  units they bring in, light - 0.1 s, 0.6 s of CPU and 15 MB after
  `DemoteText`). Every own unit is in the index, as in a full analysis.
- **The uses graph is exact where it can be**: every implementation edge of
  a light unit into a loaded unit is there; the `UNIT_NOT_LOADED` ones point
  at a unit once something loads it (a promotion's newcomer, a unit the
  `$IF Declared()` pass brings in - `RelinkNotLoaded`).
- **Its interface is analyzed in full**, the expression typer included - a
  light model is permanent, not the staged driver's transient interface wave.
- **Its diagnostics are its interface's only.**
- **Its text is lexed and preprocessed only as far as the parse reads it**
  (0.117.0): to the end of its implementation `uses` clause - the first LIVE
  `implementation`, then the `;` of the clause after it if one follows
  (`TPasPreprocessor.StopAtImplementation`, `TPasLexer.Tokenize` with its
  stop, `TPasTokenStream.Truncated`). The lexer cannot tell a live
  `implementation` from one in a branch the build does not compile, so it
  stops at the first and the preprocessor, reaching the end of a truncated
  stream without having stopped, lexes on from there (the resume rule: a dead
  `{$IFDEF CPUX64}! Implementation error{$ENDIF}` in an interface must not
  cut it). An `implementation` coming from an include stops the unit there.
  What lies after the stop is not recorded: Find All Defines, Options at
  cursor and the `defines` answers see a light unit's interface and its
  implementation `uses` only until their demand is met (`DemandDefines`,
  `DemandPosition` - a preprocess-only completion beside the model, or the
  unit promoted), and a conditional left open across the stop is not
  reported. A `$IF` written in its implementation is never asked - the
  full analysis answers it, the light one has nothing to answer it about.
  Every preprocess of a light unit takes the same stop - its load, the
  declared pass's rounds, a rehydration after `DemoteText`, a demoted parse
  donor's identity check - which is what keeps the streams comparable; a
  promotion reads the whole file.
- `sfHasBody` is never set on its interface routines (the flag comes from the
  implementation). Nothing reads it today but the module path's interface
  comparison; any later reader must handle light models.
- `TPasSemaModel.Light` is set by the loader before the model is registered
  and never written after it; it survives `DemoteText`. Module status cannot
  say "light": after the cross passes a light model is `msCrossReady` like any
  other. During the staged run a light model stays `msIntfReady` (it is never
  upgraded), and the progress counts it as done in the full wave.

Every load path applies the same rule: the load engine in both waves, the
`LoadFile` route (System and SysInit are light in a Studio tree - System.pas is
one of the largest single parses), the parallel batch loader, and the
`$IF Declared()` pass's re-parse, which keeps a light unit interface-only. A
parse donor (`AdoptParseDonor`) is reused only when its light-ness agrees with
this run's: a light donor's nodes are never handed out as a full model, and a
full donor is not kept for a unit that is now light.

`AnalyzeModuleOnly` refuses a light unit (`module=refused:light` in
`StageTimings`): an edit would parse it fully, and turning a light unit into a
full one is promotion's job, with rules of its own (below). An own unit's
module run beside light units works as before.

## Promotion: a light unit made full on demand

`PromoteUnit(APath)` turns one light unit into a fully analyzed one in place -
the editor's "the user opened System.pas", go to implementation into a library
body, the text of a library routine. It is the module path
(`docs/incremental-analysis.md`) in its second mode: the whole file parsed, its
bodies bound, the units only its implementation `uses` names loaded beside it
(light, when they lie under a light tree), the unit's consumers left alone.

- **True**: the unit is fully analyzed now - or already was: an own unit, a
  unit promoted before (`promote=already-full;`, nothing done).
- **False**: refused, the project unchanged, the reason in `StageTimings` as
  `module=refused:<reason>`, the module path's convention: `unknown-file`, the
  module path's own refusals, and `promote-needs-rebuild(<why>)` (below).
- `PromotedFiles` / `ForgetPromotions`: the promoted set. `IsLightFile` is
  False for a promoted file, so a rebuild with the project as parse donor
  (`AdoptParseDonor` copies the donor's set - the donor is what the last run
  knew) keeps it full; `ForgetPromotions` makes the next run light again.
- `TPasAsyncSession.CreateForPromotion(AProject, APath)` (a class function -
  a second constructor with `CreateForModule`'s parameters is W1029):
  `CreateForModule`'s contract (ownership, `ModuleOutcome`) with
  `PromoteUnit` as the worker's call. As after any module run, a host recreates its `TPasNavigator` over the
  project it takes back.

What makes it a one-unit step:

- **No false interface change.** An interface routine gets `sfHasBody` from its
  implementation, which a light model never parsed; compared, every promotion
  read as an interface change and redid the unit's consumers (476 of them for
  one hub unit). The module path's comparison leaves the flag out when the old
  model is light. On every unit measured nothing else differed - the light
  parse is a prefix of the full one.
- **The unit's `$IF` questions are re-decided** as the full analysis's declared
  pass decides them - `System.pas` and `System.Classes` ask (`Length` of a
  constant array, `SizeOf` of an interface type), and the module path refuses
  such a stream for an edit (`unresolved-if`). For a promotion the first-pass
  model stands in for the unit while the declared pass's rounds and symbol
  iterations run over it, its `uses` linked. That is exact only when every
  unit its `uses` names is loaded already: an import that is not
  (`new-import`) or does not resolve (`unresolved-uses`) refuses with
  `promote-needs-rebuild(<why>)` and puts the file into `PromotedFiles`, so the
  host's rebuild loads it full - never a guessed stream.
- A demoted light model is rehydrated first, as the module path does for any
  demoted module.

Measured on the 3,782-unit closure in light mode (release build): each of
seven units - two of the VCL's largest, `System.SysUtils`, `System.pas`,
`System.Classes` and two of the component suite's - promotes in 37-198 ms with
`module=1` and no consumer redone, taking in 0-12 implementation-only units;
every binding of each promoted unit is identical to the full analysis's, and
every own unit's is unchanged.

## What a host no longer sees

Without the demand step of the next section, a host that sets `LightPaths`
should say so where it answers from library code (every query of a wired
family says how much it left out: `TPasNavigator.NotSearched`):

- **Navigation into a library body**: `RoutineImplNode` / `GotoImplementation`
  on a light unit's routine find no body (`NIL_NODE` / False) - promote the
  unit (`PromoteUnit`), or say "not loaded".
- **Dispatch from library bodies into own code**: a library body calling a
  virtual or interface method an own class implements, an event handler a
  library assigns, a class created through a class reference. `callers`,
  impact and override/implementation queries lose those rows. Library code
  does not otherwise reference genuine own units.
- **References to a library symbol inside library bodies**: own code and
  library interfaces are searched; library bodies are not.
- **Unit lists and the uses graph**: library units reachable only through
  library implementations are absent; a light unit's implementation edges to
  them are `UNIT_NOT_LOADED` (`unit_deps` can list them as "not analyzed").
- **Diagnostics of library units**: interface only.
- **The uses lint** reads library implementations - see below: on its own it
  answers them on the safe side, with `LintPromotions` exactly.

## Full answers in light mode (0.118.0)

The rule: every query answers in light mode exactly what it answers in a full
analysis. Light mode may cost time when a question needs library bodies; it
may never answer less, and never silently. Three steps make it so, and a
fourth checks it:

1. **Demand** - per query, the units whose bodies can change its answer:
   `TPasNavigator.DemandReferences` / `DemandReferencesOfAll` /
   `DemandCreations` / `DemandDestructions` / `DemandFile` and the rest
   of the families table below, `DemandFilePath` for a library file the
   light closure has not loaded (taken in when the full closure would have
   it), `PasTree.Sema.Lint.DemandLint`; underneath,
   `TPasSemaProject.DemandOf(asks)` and `DemandOfFiles(files)`. A
   `TPasDemand` lists the files to make fully analyzed (`Full`), the units
   to load light on the way to one (`LoadOnly`), and how many units the
   query would leave out now (`NotSearched`). Empty, at no cost, when no
   unit is light.
2. **Ensure** - `TPasSemaProject.EnsureFull(demand)` makes them full:
   light units promoted in one batch, units nobody loaded taken in.
3. **Completeness** - every query of a wired family sets
   `TPasNavigator.NotSearched` (the lint's two reports too): the units of its
   demand that were not fully analyzed when it ran - 0 in a full analysis and
   after `EnsureFull`, the gap otherwise ("library implementations not
   searched: N units").
4. **The oracle** - `tools/PasTreeLightSmoke` (below) runs every public query
   full and light-with-demand over a sample and requires equal answers.

`PasEnsureDemand(nav, demandFunc, result, rounds)` is the host's loop: ask
the demand of the current navigator, `EnsureFull`, recreate the navigator
over the changed models (its `LibraryPaths` kept), again until the demand is
empty - a promotion loads its unit's implementation-only units, and a query
may need those in turn. It stops with `eoNeedsRebuild` (rebuild with the
project as parse donor - it carries the promoted set - and call again),
`eoEscalate` (rebuild with `LightPaths` cleared; the session stays full) or
`eoPartial` (a unit refused; the answer leaves it out and `NotSearched` says
so).

### Who can name a declaration

The demand of a reference query is a visibility question, settled in the spec
(`03` sec. 3.3.2, "What a unit can reach of a unit it does not use"; dcc64
37.0 probes): a unit-level declaration of unit U is named only in U and in the
units that list U in a `uses` clause (every unit for `System` and `SysInit`);
a member of U's types - and an enum value written after its type - also
through any type another unit's interface declares or republishes: an inline
`var` inferred from a function result, a `with`, a `TList<TFoo>`, a
descendant class, an alias, a helper, over any number of interface hops; never
through a unit that uses U only in its implementation. So:

- `dsUnit` - U and its listers, for a unit-level declaration of U's
  interface;
- `dsMember` - I(U), U and every unit whose interface `uses` reach U through
  interface `uses` alone, plus every unit with a `uses` entry into I(U), for a
  member or an enum value;
- `dsSelf` - U alone, for an implementation-section or local declaration;
- `dsAll` - every unit.

The graph is the one the full closure would have: the loaded models' `uses`
(a light unit's implementation entries included, 0.116.0) and, past a
`UNIT_NOT_LOADED` entry, the `uses` names the word index scans in the units
nobody loaded - every name, conditional or not, counted as an interface edge.
Over-approximating only promotes more; the answer stays exact.

### The implementation word index

A unit in the set can hold a use only if it spells the name. Per light unit
the index holds the identifiers of its implementation (from its first
`implementation` keyword on, the include files it names merged in); per unit
nobody loaded, those of its whole text and its `uses` names
(`PasTree.WordIndex`: sorted 32-bit hashes of the folded spelling, a scanner
that skips comments, strings and directives and evaluates no conditional, so a
dead branch only adds words; a collision only promotes one more unit). Built
lazily, on the first demand, for every light unit at once on the worker pool.
Uses written without the name are not filtered by it: a default array
property (`L[I]`) and a class operator have no word test at all, the for-in
methods (`GetEnumerator`, `MoveNext`, `Current`) match the word `in`, and an
attribute class also matches its name without `Attribute`. A bare
`inherited` needs no word of its own: the method it sits in spells the name.

A unit nobody loaded is needed only when it is reachable: `EnsureFull` takes
it in from a light unit's `UNIT_NOT_LOADED` entry (the demand's frontier) -
full when its body is needed, light (`LoadOnly`) when it only lies on the
way to one - and the next round's demand reaches past it. With no frontier
left, a needed unit is not in the full closure either, and counts for
nothing.

### EnsureFull

- **The batch**: the light units are parsed and Phase-1'd in parallel (the
  load engine's worker body); every one whose interface reads as its light
  model's (`sfHasBody` masked, as a promotion does) and whose stream asks no
  `$IF` question is swapped in together, their implementation-only imports
  loaded once, and the module passes run once over the whole set. The rest
  take the one-unit path (`PromoteUnit`'s).
- **Newcomers' `$IF` questions**: a newcomer whose stream asks one (a unit
  under a `{$IF Declared(...)}`) no longer refuses (`new-dependency-oracle`,
  which cost a rebuild): it is registered and its questions are re-decided as
  a full run's declared pass decides them (`RedecideStream`, a light
  newcomer's stream stopped as at its load).
- **New imports, then the re-decision**: a unit whose `$IF` questions name a
  unit not loaded yet - `promote-needs-rebuild(new-import)` for
  `PromoteUnit` - has its imports taken in first and is then re-decided in
  place.
- **Escalation**: when the volume made full so far plus the demand's passes
  `EscalationPercent` (default 40) of the library's source volume,
  `EnsureFull` returns `eoEscalate` without doing anything: a rebuild without
  `LightPaths` is cheaper then. `TObject`'s descendants, `Free`'s references
  and most questions about a hub class's members end here.
- `PromoteUnit` itself is unchanged: it refuses as before, and its contract
  ("False: the project unchanged") stands. `EnsureFull` may load units even
  when it ends in `eoPartial` or `eoNeedsRebuild`: recreate the navigator.

### The families

| family | queries | demand | since |
| --- | --- | --- | --- |
| references | `FindReferences`, `FindAssignments`, `CollectReferencesOfAll` | `DemandReferences` / `DemandReferencesOfAll`: each symbol (each link of a property's redeclaration chain) by its scope, its name spelled | 0.118.0 |
| creations | `FindCreations` | `DemandCreations`: `dsMember` of the class's unit, one of the class's constructor names spelled | 0.118.0 |
| destructions | `FindDestructions` | `DemandDestructions`: `dsMember` of the class's unit, `Free`/`Destroy`/`FreeAndNil`/`Release` spelled | 0.118.0 |
| uses lint | `FindUnusedUses`, `FindUnreferencedUnits`, `LintPromotions` | `DemandLint` = `LintPromotions` (0.115.0) | 0.118.0 |
| one library file | `SemanticTokens`, `RoutineImplNode`, a library file's outline | `DemandFile`: the unit itself | 0.118.0 |
| positions | `IdentAt`, `SymbolAt`, `SymbolAtFile`, `ResolveDecl`, `GotoDeclaration`, `GotoImplementation`, `GotoBareInherited`, `MethodAt`, `InterfaceMethodAt`, `InterfaceAt`, `TypeAt`, `AssignableAt`, `ClassAt`, `UnitAt`, `BuiltinNameAt`, `DefineAt`, `DefineSpanAt`, `IfNameAt`, `GotoDefine`, `DefinesAt`, `OptionsAt` | `DemandPosition`: the file when it is light, and the unit of the symbol there when it is light (Go to Implementation lands in its body) | 0.119.0 |
| hierarchy | `FindDescendants`, `FindOverrides`, `FindImplementations`, `FindInterfaceImplementors`, `RenameFamily` | `DemandDescendants` / `DemandOverrides` / `DemandImplementations` / `DemandInterfaceImplementors` / `DemandRenameFamily`: every type below the question's types over the heritage edges, by name and alias, in `dsMember` of its unit; an implicit root (`TObject`, `IInterface`, `IDispatch`) by `class` / `interface` / `dispinterface` - an escalation | 0.119.0 |
| defines | `FindDefines`, `FindDefineReferences` | `DemandDefines` / `DemandDefineReferences`: the light units with a `$DEFINE` (the name) in a directive past their stop - a preprocess-only completion, no promotion; units nobody loaded taken in light first | 0.119.0 |
| built-in names | `FindBuiltinReferences` | `DemandBuiltin`: every light and not-loaded unit spelling the name | 0.119.0 |
| renames | `PlanRename` | `DemandRename`: the references of the rename family and a property's chain, and the family's hierarchy (a library symbol is refused anyway) | 0.119.0 |
| none needed | `FindUnitReferences`, `UnitDeclHit`, `UnitHeaderTarget`, `PlanUnitRename` (a light unit's implementation `uses` entries are recorded); `DeclHit`, `ProjectOutline`, completion, hover, `IsProjectDefined`, `IsUnderLibraryPath`, `RenameBlockReason`, `ModelIdOf`, `IncludeSiteTarget` (interfaces and project facts, analyzed in full); `FindFormSites`, `FormRoleOf`, `DescribeForm` (the form files) | - | - |

A query without a row here is a defect: every new public query of
`TPasNavigator` or `PasTree.Sema.Lint` gets one - a demand, or "none,
because".

Measured with the oracle (release build), the 3,782-unit closure in light
mode (3,086 units, 1,391 light): the word index's first build - every light
unit's implementation and the 700-odd units nobody loaded, the graph with
them - 1.3 s and 12 MB. A question about a leaf library routine
(`TPath.Combine`): one round, 10 units promoted and 21 taken in, 1.1 s. A
mid-size one (`IntToStr`, `Max`, `TControl.Visible`): 2-3 rounds, 230-330
promoted and 300-390 taken in, 2.6-2.8 s. A hub (`TObject`, `Free`,
`TStrings.Add`, `TComponent.Create`, `TList.Count`, `FreeAndNil`):
escalated at once - the rebuild without light paths and the question, about
4.3 s. The uses lint over the 1,566 listed units: three rounds, 113 units
promoted and 88 taken in, the same 12,098 and 137 rows as the full analysis.
Of 3,704 own symbols asked, two escalated - a property redeclared in an own
class, whose chain reaches the VCL's `Font`. Every answer of every wired
family equal to the full analysis's, `NotSearched` 0, on this closure and on
the demo's (209 units).

With every family wired (0.119.0), the same closure, 25,273 questions over
27 families, every answer equal and `NotSearched` 0 (and on the demo's
closure, 82,590 questions; the two spring4d packages, 38,674). What the
light side paid, per family, for the questions whose demand did anything
(an escalation is answered by the rebuild without light paths - a full
analysis, about 3.3 s on this closure - and is counted, not timed):

- **Find All Defines**: one question, the preprocess-only completion of
  1,623 light units in five rounds, 21 units promoted (their streams ask a
  `$IF` only the declared pass answers) and 541 taken in, 1.2 s - no unit
  made full for its directives alone.
- **Define references**: 13 names, five with work - 68 completions, one
  promotion, at most 83 ms.
- **Built-in references**: 10 names (`Length`, `Inc`, `Exit`, `SizeOf`, ...);
  nine are spelled across the library and escalate, one promoted 315 units
  in 2.2 s.
- **Hierarchy**: of 211 types asked for descendants, nine needed bodies and
  seven escalated (`TObject`, `IInterface` and the hubs below them); of 1,438
  methods asked for overrides, 47 - 33 escalated, mostly `Destroy` and the
  other slots `TObject` introduces - the rest promoted at most 2.7 s worth;
  rename families six, five escalated; interface implementors one escalation
  (`IInterface`).
- **Positions** and **one library file**: one unit promoted per question,
  at most 0.3 s.
- **Renames** of 3,600 own symbols: nothing beyond the references' demand
  of the same symbols, asked first.

A refusal of `RenameFamily` with several refusals in the family is the one
at the type declared first in the source (file, line, column): it was the
first the walk met, and the walk's order follows model numbering, which a
light closure does not share - two client renames named a different
overloaded type in the two modes.

An own symbol's demand is the same rule, and it is empty unless a library
unit's implementation lists an own unit - the patched library copies a
project keeps in its own tree (S2 loads them; their symbols' demand promotes
the library units that use them).

## The uses lint in light mode

`FindUnusedUses` / `FindUnreferencedUnits` (`PasTree.Sema.Lint`) read library
code in four places, each of which a light unit does not have:

| reader | what it reads | light, on its own |
| --- | --- | --- |
| `InlineDeps`, `InlineAccessors` | an inline routine's body - the units dcc needs to expand a call (H2443) | every unused entry of the unit gets "the expansion of an inline routine of X called here is not known (analyzed interface-only) - it may need this unit" |
| `LinkEffect`, via the reach | the initialization and finalization of the units a removal leaves out of the program | the light ones among them are named apart: "removing it leaves X out of P, analyzed interface-only - what their initialization and implementation bring in is not known" |
| `GlobalInit` (`loHideGlobalInit`) | the initialization and the routines it calls | unknown counts as global: the row is held back |
| the reach itself | the uses graph, implementation edges included | a light unit's edges to units nobody loads are missing, so a removal can only seem to leave MORE out (a superset - never less) |

So a light lint never calls a needed unit unused without saying why it may be
wrong. A light row is the full row, or the same row with more doubts, or a row
the full lint does not have, carrying one of the doubts above.

`LintPromotions(ANav, AMids, AOptions)` makes it exact: the light units the
same lint over AMids had to treat as unknown. The host promotes them
(`PromoteUnit`), asks again - a promotion loads the unit's implementation-only
units light, and they may be needed in turn - until the answer is empty,
recreates its navigator and lints. A promotion that asks for a rebuild
(`promote-needs-rebuild`) gets one, with the project as parse donor.

Measured on the 3,782-unit closure, its 1,566 listed units: full mode
12,098 unused entries and 137 unreferenced units; light with the promotions -
four rounds, 111 units promoted, two refused, then one rebuild - the same 137
units and the same 12,098 entries with the same doubts, row for row (0.115.0,
without the implementation edges of light units, still had seven rows whose
"removing it leaves" list was a strict superset of the full one). 24 s
against 7.7 s for the full analysis and lint; the lint itself takes 2.7 s (it
took 25 s before 0.115.0, which caches the form files the designer rule reads).
Without the promotions, the light lint is on the safe side as above: 34 rows
the full lint does not have, each with a light doubt, and 4,817 rows with more
doubts.

## Hosts

Every host already computes its library trees for the navigator
(`TPasNavigator.LibraryPaths`): the IDE's library and browsing paths plus the
Studio source trees, minus the project's own trees. That list is the natural
`LightPaths`. A host switching light mode on by default promotes a unit when
the user opens it or navigates into its bodies, and runs `LintPromotions`
before the lint.

## In the demo

The `Light libraries` checkbox (persisted, off by default) analyzes the units
under the IDE's library and browsing paths and the Studio sources light -
the navigator's library set plus the Studio source tree, minus every tree
that holds the project directory or a file the `.dproj` lists. Toggling it
re-analyzes; the message log's `Light libraries: N of M units` line says how
many are light. Opening a light unit in a tab promotes it in the background
(`CreateForPromotion`, with `Incremental` on - a build with it off released
the maps the module path needs); `promote-needs-rebuild` rebuilds with the
project as donor, so the unit comes back full. Find All > Unused Units and
Units Nobody Uses run `LintPromotions` and promote first, on the UI thread.

## The tool

The command-line tool takes `-light:<spec>` (repeatable): `lib` = every `-L`
path plus the Studio source trees, `studio` = the Studio source trees only,
anything else = one directory tree; it prints `light: N units` after the
analysis line. `-promote:<file>` promotes a light unit (`PromoteUnit`; any
other goes through `AnalyzeModuleOnly`), `-fpafter:<file>` fingerprints the own
units again after the promotions, `-fpunit:<file>` adds a library unit to every
fingerprint, and `-lintpromote` (with `-unused`) runs the host's preparation
step - `LintPromotions` and `PromoteUnit` until nothing is left, a rebuild with
the project as donor when a promotion asks for one - before the lint.

`tools/PasTreeLightSmoke` is the oracle of "Full answers in light mode": it
analyzes a `.dproj` twice in one process - full, and light - and asks both
every public query of `TPasNavigator` and `PasTree.Sema.Lint` over a sample:
every n-th symbol of the project's own units (`-own:<n>`), their units and
every n-th identifier position of their text (`-ownunits:<n>`, `-pos:<n>`),
a library sample (`-sym:Unit.Type.Member`, a default set of RTL and VCL
names; each on a fresh light project unless `-shared`), and every n-th
position of the sample's library files (`-libpos:<n>`, the one-library-file
family). The light side meets each question's demand first, as a host does
(`PasEnsureDemand`, a rebuild with the donor on `eoNeedsRebuild`; on
`eoEscalate` the host's rebuild without light paths is a full analysis of
the same configuration - the full side, which G2 holds byte-identical to
it - so the question is answered there and the light project is started
again for the next one). Answers are compared by identity -
file, line, column, kind, name - never by model id. It prints per family the
questions, the equal and differing answers and the light answers whose
`NotSearched` was not 0, then what each question cost the light side
(rounds, units promoted and taken in, rebuilds, escalations, time). A family
whose demand is wired must be equal with `NotSearched` 0 (exit 1 otherwise);
a family not wired yet is listed as an expected difference with its counts.

## What is still open

- Every public query has its demand (0.119.0, the table above); the smoke
  tool reports no expected difference any more.
- The hosts (demo, language server, MCP server) still promote one unit at a
  time and run `LintPromotions`; they move to `PasEnsureDemand` before every
  Find All / references / callers / related query, with progress, cancel and
  `NotSearched` shown.
