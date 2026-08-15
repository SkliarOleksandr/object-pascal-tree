# PasTree IDE Plugin

A RAD Studio IDE package that surfaces PasTree's analysis inside the Delphi
editor itself, starting with **Find References** (the feature already
available in `demo/`).

## Status: scaffold

This is the initial skeleton, built directly from RAD Studio's own official
samples (`Samples\Object Pascal\ToolsAPI\Editor Demos\Editor Local Menu Demo`
and `...\Editor Raw Read Demo`), not from an unofficial/community API surface.

What works today:
- The package registers a "Find References (PasTree)" entry in the editor's
  right-click menu, next to the IDE's own Refactor section
  (`cEdMenuCatRefactor` in `ToolsAPI.pas`).
- Identifier-under-cursor extraction (rough word-boundary heuristic).
- Reading every unit's live buffer text for the active project.

What's not wired up yet:
- No dependency on `PasTree.*` units at all yet. `PasTreeIdePlugin.FindReferences.pas`
  has a `TODO` list at the top of the unit for the next session: add PasTree's
  source path, build a project from the gathered unit texts, resolve the
  identifier at its location, and enumerate references using the same
  symbol/unit/builtin identity logic the demo's Find References already uses
  (see `demo/PasTreeDemo.Main.pas`).
- Results currently go to a single placeholder line in the Messages panel
  (`IOTAMessageServices.AddTitleMessage`) instead of one message per
  reference with double-click navigation.

## Files

- `PasTreeIdePlugin.dpk` - package project. `requires: rtl, vcl, designide`.
  No `.dproj` yet: open the `.dpk` in RAD Studio and let it generate one, or
  hand-write one modelled on `demo/PasTreeDemo.dproj` (target `Win32` -
  IDE packages load into the 32-bit IDE process regardless of what platforms
  the analyzer itself targets).
- `PasTreeIdePlugin.Wizard.pas` - `TIDEWizard` (`IOTAWizard`) + menu
  registration/unregistration.
- `PasTreeIdePlugin.FindReferences.pas` - the actual logic: identifier
  extraction, project source gathering, and (for now) a placeholder report.

## Why no PasTree dependency yet

Wiring in `PasTree.Sema.Project` etc. pulls in the whole analyzer's search
path and its `{$DEFINE}`s into a *designtime* package that loads inside every
RAD Studio session on this machine - worth getting the ToolsAPI plumbing
compiling and verified in the IDE on its own first, before adding that
weight. Next session: add the PasTree source path, wire
`PasTreeIdePlugin.FindReferences.ExecuteFindReferences`, done.
