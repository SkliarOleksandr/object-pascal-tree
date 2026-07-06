# PasTree demo (VCL)

A small Win32 VCL host that drives PasTree interactively:

- **Toolbar** — *Open Project…* (`.dpr`/`.dproj`), *Run Parse* (F9), platform combo.
- **Left** — project files in a `TVirtualStringTree`; click a file to open it.
- **Center** — `TSynEdit` tabs, highlighted by **`PasTreeDemo.Highlighter`**
  (`TPasTreeSynHighlighter`) — a custom `TSynCustomHighlighter` driven directly
  by PasTree's own lexer (`PasTree.Lexer.TPasLexer`), not SynEdit's built-in
  Pascal scanner. Every color on screen comes straight from a `TPasTokenKind`
  the lexer assigned, so it doubles as a live correctness visualizer for the
  lexer (a wrong color is a lexer bug). Unterminated strings/comments/
  directives are flagged in a distinct error style. One cosmetic exception:
  "weak keywords" (`private`/`override`/`virtual`/`stdcall`/...) are lexically
  plain identifiers — the language only gives them meaning by position — so
  they're colored like keywords via a small static word list, matching what a
  real IDE looks like; that specific coloring is a word-list judgment call,
  not a lexer signal (see the unit header comment). A file opens in its own
  tab (the `.dpr` opens by default). Two persistent tabs show the analysis of
  the main unit: **AST JSON** (the CST) and **Semantics** (the semantic model —
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
> tabs are still created at runtime (one editor + one `TPasTreeSynHighlighter`
> instance per opened file — the highlighter caches its own buffer's
> tokenization, so instances aren't shareable across tabs). The
> statically-linked `dcc32` build calls `RegisterClasses([TSynEdit,
> TVirtualStringTree])` so it can stream those controls without design packages.
> `TPasTreeSynHighlighter` itself is created purely in code (no `Register`
> procedure, no design-time package needed for it).
