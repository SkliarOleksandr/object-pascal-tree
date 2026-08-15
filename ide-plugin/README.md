# PasTree IDE Plugin

A RAD Studio IDE package that surfaces PasTree's analysis inside the Delphi
editor itself, starting with **Find References** (the feature already
available in `demo/`).

## Status: PoC — Find References works in-process, on small/test projects

Built directly from RAD Studio's own official samples
(`Samples\Object Pascal\ToolsAPI\Editor Demos\Editor Local Menu Demo` and
`...\Editor Raw Read Demo`), not from an unofficial/community API surface.

What works today:
- A "Find References (PasTree)" entry in the editor's right-click menu, next
  to the IDE's own Refactor section (`cEdMenuCatRefactor` in `ToolsAPI.pas`).
- Reading every unit's live buffer text for the active project
  (`GatherProjectUnits`, via `IOTAEditorContent.Content`).
- A real `TPasSemaProject` is built from those unit texts and analyzed
  (`TPasSemaProject.AnalyzeProject`), and `TPasNavigator`'s three-identity
  lookup (symbol / unit / builtin - see `source/PasTree.Sema.Nav.pas`)
  resolves whatever's under the cursor and enumerates its references.
- Results go to a dedicated "Find References" tab in the Messages panel
  (`IOTAMessageServices.AddMessageGroup`), one line per hit with
  file/line/column, so the IDE's own message navigation (double-click,
  Enter, F8/Shift+F8) jumps straight to it - same as compiler errors or
  Find in Files.

## Architecture: in-process for now, by design

This runs the full `TPasSemaProject` analysis **inside the 32-bit designtime
package**, synchronously, on every menu click, rebuilding the project from
scratch each time. That's a deliberate, accepted limitation for this PoC
stage - not an oversight:

- A designtime package is forced to run **Win32** (the IDE itself is a
  32-bit process) - there is no way to make this package itself Win64.
- The real target project this plugin is ultimately for is large enough to
  need **Win64 and several GB** to analyze (see project memory - the same
  codebase OOMs when analyzed as Win32). Running that analysis inside this
  Win32 package is expected to fail or be unusable at that scale.
- Re-analyzing the whole project synchronously on every single click has no
  caching yet either - fine for a small test project, not for a real one.

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
  exists (rooted at `IOTAServices.GetRootDirectory`, no hardcoded version)
  but is **disabled** - adding those search paths triggered an access
  violation on a real multi-unit project (heap/stack corruption surfacing
  later, in unrelated IDE code, on a subsequent click - suspect it's inside
  PasTree's own `TPasSourceManager`/preprocessor at RTL/VCL scale, not this
  plugin's code). See `CollectSearchPaths`'s comment before re-enabling it.
- Project `$DEFINE`s aren't read from the `.dproj` yet - `TPasSemaProject`
  is created with an empty extra-defines list.
- Platform is read from `IOTAProject.CurrentPlatform` and mapped to the
  closest `TPasPlatform` (`MapPlatform`) - PasTree doesn't model every RAD
  Studio target (no ARM64EC, no 32-bit non-Windows), those fall back to the
  nearest 64-bit equivalent or `pfWin32`.

## Files

- `PasTreeIdePlugin.dpk` / `.dproj` - package project, `Win32`.
  `requires: rtl, vcl, designide`; `contains` the plugin's own two units plus
  the same ~20 `source/PasTree.*.pas` units `demo/PasTreeDemo.dproj` already
  depends on (copied as-is rather than trimmed to a minimal subset, since
  that combination is already proven to compile together).
- `PasTreeIdePlugin.Wizard.pas` - `TIDEWizard` (`IOTAWizard`) + menu
  registration/unregistration.
- `PasTreeIdePlugin.FindReferences.pas` - the actual logic: project source
  gathering, `TPasSemaProject`/`TPasNavigator` wiring, and reporting hits to
  the Messages panel. Its unit header has the fuller architecture note and
  a TODO list for what's next (caching, out-of-process, real defines).
