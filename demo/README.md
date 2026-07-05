# PasTree demo (VCL)

A small Win32 VCL host that drives PasTree interactively:

- **Toolbar** — *Open Project…* (`.dpr`/`.dproj`), *Run Parse* (F9), platform combo.
- **Left** — project files in a `TVirtualStringTree`; click a file to open it.
- **Center** — `TSynEdit` tabs (Pascal-highlighted); a file opens in its own tab
  (the `.dpr` opens by default). A persistent **AST JSON** tab shows the parse
  result and is activated after a run.
- **Bottom** — diagnostics (`file(line,col): message`) and a run summary.

On first launch it creates a `Sample\` folder next to the executable containing a
minimal console `Sample.dpr` (hello-world) and opens it, so there is always
something to parse.

## Build

Needs the third-party sources (SynEdit + VirtualTreeView) under
`C:\Repos\3rdlib13`. Run:

```
demo\build.bat
```

which calls `rsvars.bat` then `dcc32` with the SynEdit/VirtualTrees unit and
include paths (see the script). Output goes to `demo\out\PasTreeDemo.exe`.

> The UI is constructed at runtime (the `.dfm` is just an empty form shell), so
> no design-time packages for the third-party controls are required.
