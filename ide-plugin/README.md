# PasTree IDE Plugin

A RAD Studio IDE package that surfaces PasTree's analysis inside the Delphi
editor itself. Two features so far: **Find References** (the feature
already available in `demo/`) and **Go to Declaration**, replacing RAD
Studio's own DelphiLSP-based navigation (reported to work poorly on large
projects) - both the native menu item and Ctrl+Click.

## Status: PoC — confirmed working in-process, on small/test projects

Built directly from RAD Studio's own official samples
(`Samples\Object Pascal\ToolsAPI\Editor Demos\...`), not from an
unofficial/community API surface.

### Menu

Both "Find Declaration (PasTree)" and "Find References (PasTree)" live
together at the top of the editor's right-click menu, in the Identifier
category (`cEdMenuCatIdentifier` in `ToolsAPI.pas`) - the exact slot RAD
Studio's native "Find Declaration" used to occupy alone. See "Go to
Declaration" below for how the native item got replaced.

### Find References

- Results go to a dedicated "Find References" tab in the Messages panel
  (`IOTAMessageServices.AddMessageGroup`), grouped by file (one header row
  per file via `AddToolMessage`'s own `Parent`/`LineRef` mechanism - same
  tree structure "Find in Files" uses), each hit carrying file/line/column
  so the IDE's own message navigation (double-click, Enter, F8/Shift+F8)
  jumps straight to it.

### Go to Declaration

Two ways to trigger the same resolve+navigate logic
(`PasTreeIdePlugin.GotoDeclaration.ResolveAndNavigate`), both **confirmed
working**:

- **Native menu item replaced.** The built-in "Find Declaration" is removed
  via `INTAEditorLocalMenu.UnregisterActionList(cEdMenuCatIdentifier)` and
  replaced with our own action registered under that same category string
  (`PasTreeIdePlugin.Wizard.TMenuManager` - lands in the exact same, first,
  menu position). **Caveat:** this is a one-way door within a running IDE
  session - there's no handle to the native action list to restore it, so
  uninstalling the package without restarting the IDE would leave "Find
  Declaration" missing until restart (which the project's own workflow
  already does after every rebuild - see project memory on package
  hot-reload).
- **Ctrl+Click override.** Hooks `INTACodeEditorServices.AddEditorEventsNotifier`
  (`ToolsAPI.Editor.pas`, the same mechanism the official "KeyboardMouse
  Events Demo" sample uses) and intercepts
  `OnEditorMouseDownEx`/`OnEditorMouseUpEx`: on Ctrl+Left-click it resolves
  the identifier under the cursor and navigates there itself, setting
  `Handled := True` to suppress RAD Studio's own default handling
  (documented as "prevent further processing" - `ToolsAPI.Editor.pas:804-806`).

### Shared analysis pipeline

Both Go to Declaration entry points, and Find References, call
`PasTreeIdePlugin.Analysis.BuildNavigator`, which:
- Resolves the active project's real `.dpr`/`.dpk` (`IOTAProject.FileName`
  is the `.dproj` MSBuild wrapper, unparseable by PasTree).
- Overlays live buffer text for every currently-**open** unit
  (`IOTAModuleServices.Modules` - never forcing anything open; an earlier
  version walked every project unit via `IOTAProject.GetModule`+`OpenModule`,
  which force-instantiated every unopened form's design surface).
- Builds a `TPasSemaProject` (`SingleThreaded := True` - see below) and
  `TPasNavigator`, whose three-identity lookup (symbol / unit / builtin -
  see `source/PasTree.Sema.Nav.pas`) resolves whatever's at a given
  file/line/column.

### Diagnostics

Logged only on failure (no active project, cursor's file not analyzed, no
identifier resolved, unhandled exception) - not on every step or on
success. Go to Declaration fires on every Ctrl+Click, far more often than a
menu click, so logging progress/success would be much noisier than useful.
Goes to the IDE's own default Messages tab (the "Build" tab -
`AddTitleMessage` with no group), tagged `[pastree]` so it's identifiable
alongside compiler/linker output, rather than into a dedicated tab of its
own.

## Architecture: in-process for now, by design

This runs the full `TPasSemaProject` analysis **inside the 32-bit designtime
package**, synchronously, rebuilding the project from scratch on every call
(every menu click, and every Ctrl+Click). That's a deliberate, accepted
limitation for this PoC stage - not an oversight:

- A designtime package is forced to run **Win32** (the IDE itself is a
  32-bit process) - there is no way to make this package itself Win64.
- The real target project this plugin is ultimately for is large enough to
  need **Win64 and several GB** to analyze (see project memory - the same
  codebase OOMs when analyzed as Win32). Running that analysis inside this
  Win32 package is expected to fail or be unusable at that scale.
- Re-analyzing the whole project synchronously on every single call has no
  caching yet either - fine for a small test project, not for a real one,
  and now doubly so with Go to Declaration firing on every Ctrl+Click.

The intended fix, once this moves past PoC: an **out-of-process Win64
helper** (extending `tools\PasTreeSemaProject.dpr`) that this plugin talks
to instead of calling `TPasSemaProject` directly in-process. Deliberately
not built yet - see the architecture note at the top of
`PasTreeIdePlugin.FindReferences.pas`.

## Known first-pass limitations

- `uses` resolution only searches the active project's own directory and
  every open unit's directory - it does not know the RTL/VCL/ToolsAPI
  source paths, so `TActionList`, `IOTAWizard`, and anything else declared
  outside the active project won't resolve. A `GetIDESourcePaths` function
  exists in `PasTreeIdePlugin.Analysis.pas` (rooted at
  `IOTAServices.GetRootDirectory`, no hardcoded version) but is
  **disabled** - adding those search paths triggered an access violation on
  a real multi-unit project (heap/stack corruption surfacing later, in
  unrelated IDE code, on a subsequent click - suspect it's inside PasTree's
  own `TPasSourceManager`/preprocessor at RTL/VCL scale, not this plugin's
  code). See `CollectSearchPaths`'s comment before re-enabling it.
- Project `$DEFINE`s aren't read from the `.dproj` yet - `TPasSemaProject`
  is created with an empty extra-defines list.
- Platform is read from `IOTAProject.CurrentPlatform` and mapped to the
  closest `TPasPlatform` (`MapPlatform`) - PasTree doesn't model every RAD
  Studio target (no ARM64EC, no 32-bit non-Windows), those fall back to the
  nearest 64-bit equivalent or `pfWin32`.
- Rebuilding this package inside the same running IDE session is unreliable
  even with an explicit Uninstall/Build/Install cycle - always restart the
  IDE before testing a rebuild (see project memory on package hot-reload;
  the likely cause is `AddEditorEventsNotifier` not being fully torn down
  by the IDE's own Uninstall step).

## Files

- `PasTreeIdePlugin.dpk` / `.dproj` - package project, `Win32`.
  `requires: rtl, vcl, designide`; `contains` the plugin's own four units
  plus the same ~20 `source/PasTree.*.pas` units `demo/PasTreeDemo.dproj`
  already depends on (copied as-is rather than trimmed to a minimal subset,
  since that combination is already proven to compile together).
- `PasTreeIdePlugin.Wizard.pas` - `TIDEWizard` (`IOTAWizard`): owns the
  single editor-menu action list (Find Declaration + Find References,
  both under Identifier) and the Ctrl+Click notifier's lifetime.
- `PasTreeIdePlugin.Analysis.pas` - shared plumbing: active-project lookup,
  live-buffer gathering, search-path/platform resolution, and
  `BuildNavigator` (the `TPasSemaProject`+`TPasNavigator` pipeline every
  feature calls).
- `PasTreeIdePlugin.FindReferences.pas` - Find References logic and
  Messages-panel reporting. Its unit header has the fuller architecture
  note and a TODO list for what's next (caching, out-of-process, real
  defines, snippet highlighting).
- `PasTreeIdePlugin.GotoDeclaration.pas` - the Ctrl+Click override plus the
  shared `ResolveAndNavigate`/`ExecuteGotoDeclaration` used by both Go to
  Declaration entry points: mouse event interception, cursor
  pixel→file-position conversion, and navigation.
