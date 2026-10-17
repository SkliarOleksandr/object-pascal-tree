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
| light (every library tree) | 3,086 | 1.9 s | 16 s | 1.5 GB | 0.89 GB |

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
  ` Declared()` pass brings in - `RelinkNotLoaded`).
- **Its interface is analyzed in full**, the expression typer included - a
  light model is permanent, not the staged driver's transient interface wave.
- **Its diagnostics are its interface's only.**
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
- `TPasAsyncSession.CreateForPromotion(AProject, APath)`: `CreateForModule`'s
  contract (ownership, `ModuleOutcome`) with `PromoteUnit` as the worker's
  call. As after any module run, a host recreates its `TPasNavigator` over the
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
`System.Classes` and two of the component suite's - promotes in 37-183 ms with
`module=1` and no consumer redone, taking in 0-12 implementation-only units;
every binding of each promoted unit is identical to the full analysis's, and
every own unit's is unchanged.

## What a host no longer sees

A host that sets `LightPaths` should say so where it answers from library
code:

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

Measured on the 3,782-unit closure, the client's 1,566 listed units: full mode
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

The command-line tool takes `-light:<spec>` (repeatable): `lib` = every `-L`
path plus the Studio source trees, `studio` = the Studio source trees only,
anything else = one directory tree; it prints `light: N units` after the
analysis line. `-promote:<file>` promotes a light unit (`PromoteUnit`; any
other goes through `AnalyzeModuleOnly`), `-fpafter:<file>` fingerprints the own
units again after the promotions, `-fpunit:<file>` adds a library unit to every
fingerprint.
