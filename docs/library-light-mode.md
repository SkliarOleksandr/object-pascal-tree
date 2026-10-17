# Light mode: library units interface-only

PasTree analyzes the whole `uses` closure of a project, library code
included: every RTL, VCL and third-party unit is parsed, resolved and typed in
full, bodies and all. For an editor host most of that work is wasted - the
user edits their own units, and their own units bind only to what the library
units' INTERFACES declare. Light mode lets a host say which directory trees
hold somebody else's code; the units there are analyzed interface-only for
good, and the project's own units are analyzed exactly as before.

Measured on a 3,782-unit closure (1,684 own units, the rest RTL, VCL and a
third-party component suite):

| | units | analysis | CPU | held | after `DemoteText` |
| --- | --- | --- | --- | --- | --- |
| full | 3,782 | 3.1 s | 32 s | 2.3 GB | 1.5 GB |
| light (every library tree) | 3,047 | 1.8 s | 15 s | 1.5 GB | 0.87 GB |

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

- **No implementation section.** No routine bodies, no implementation `uses`,
  no initialization or finalization, no implementation-only types.
- **Units reachable only through a light unit's implementation `uses` are not
  loaded.** On the closure above that is 735 units. That includes own units
  whose only importers are library implementation sections (patched library
  copies kept in the project's tree are the usual case).
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
`StageTimings`): the module path would parse it fully, and turning a light unit
into a full one needs rules of its own (promotion). An own unit's module run
beside light units works as before.

## What a host no longer sees

A host that sets `LightPaths` should say so where it answers from library
code:

- **Navigation into a library body**: `RoutineImplNode` / `GotoImplementation`
  on a light unit's routine find no body (`NIL_NODE` / False) - say "not
  loaded".
- **Dispatch from library bodies into own code**: a library body calling a
  virtual or interface method an own class implements, an event handler a
  library assigns, a class created through a class reference. `callers`,
  impact and override/implementation queries lose those rows. Library code
  does not otherwise reference genuine own units.
- **References to a library symbol inside library bodies**: own code and
  library interfaces are searched; library bodies are not.
- **Unit lists and the uses graph**: units reachable only through library
  implementations are absent, and a light unit has no implementation edges.
- **Diagnostics of library units**: interface only.
- **The uses lint** reads library implementations (an inline routine's body,
  a unit's initialization): until it learns light mode, run it on a full
  analysis.

## Hosts

Every host already computes its library trees for the navigator
(`TPasNavigator.LibraryPaths`): the IDE's library and browsing paths plus the
Studio source trees, minus the project's own trees. That list is the natural
`LightPaths`. A host switching light mode on by default should wait until it
can promote a unit to a full parse on demand and until the lint handles light
units.

The command-line tool takes `-light:<spec>` (repeatable): `lib` = every `-L`
path plus the Studio source trees, `studio` = the Studio source trees only,
anything else = one directory tree; it prints `light: N units` after the
analysis line.
