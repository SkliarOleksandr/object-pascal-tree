# PasTree demo (VCL)

A small Win32 VCL host that drives PasTree interactively:

- **Toolbar** — *Open Project…* (`.dpr`/`.dproj`), *Run Parse* (F9), platform combo.
- **Left** — project files in a `TVirtualStringTree`; click a file to open it.
- **Center** — `TSynEdit` tabs (Pascal-highlighted); a file opens in its own tab
  (the `.dpr` opens by default). Two persistent tabs show the analysis of the
  main unit: **AST JSON** (the CST) and **Semantics** (the semantic model —
  scopes, symbols, resolution and cross-unit reference stats).
- **Bottom** — semantic diagnostics across all units
  (`file(line,col): E20xx message`) and a run summary.

*Run Parse* / F9 runs the full semantic pipeline (`TPasSemaProject`): parse →
scopes/symbols → cross-unit resolution → type checks → overload/arity. On first
launch it creates a `Sample\` folder next to the executable with a minimal
console `Sample.dpr`, opens it, and analyzes it so the Semantics tab is populated
immediately.

## Build

Needs the third-party sources (SynEdit + VirtualTreeView) under
`C:\Repos\3rdlib13`. Run:

```
demo\build.bat
```

which calls `rsvars.bat` then `dcc32` with the SynEdit/VirtualTrees unit and
include paths (see the script). Output goes to `demo\out\PasTreeDemo.exe`.

Alternatively open `PasTreeDemo.dproj` in the IDE (needs the SynEdit +
VirtualTreeView design packages installed).

> The static layout (toolbar, file tree, page control + JSON/Semantics tabs,
> messages) lives in the form designer (`PasTreeDemo.Main.dfm`). Source-file
> tabs are still created at runtime (one editor per opened file). The
> statically-linked `dcc32` build calls `RegisterClasses([TSynEdit,
> TVirtualStringTree])` so it can stream those controls without design packages.
