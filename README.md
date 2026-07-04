# PasTree

**A simple, extensible, multithreaded Object Pascal parser — source in, AST out.**

PasTree parses Delphi source files (`.pas`, `.dpr`, `.dpk`, with full `.inc`
support) into an abstract syntax tree, targeting the language as implemented by
**Delphi 13.x Florence** and specified by
[object-pascal-spec](https://github.com/SkliarOleksandr/object-pascal-spec) —
the companion specification this parser is built from.

> **Status: early development.** The architecture is settled; the lexer is the
> first milestone.

## Goals

- **Simple & extensible** — homogeneous AST (one node type + kind), so new
  language syntax means a new node kind and a parse rule, never a new data model.
- **Full fidelity** — trivia (comments, whitespace, disabled `{$IFDEF}` regions)
  is preserved; tokens + trivia reconstruct the source byte-for-byte. Built for
  refactoring tools, not just analysis.
- **Correct preprocessing** — `{$IFDEF}`/`{$IF}` evaluation, `{$I}` include
  splicing with a proper include stack (spans always point into the right file),
  `{$PUSHOPT}`-style option state.
- **Multithreaded** — parsing a unit is a pure function `(text, defines) → tree`;
  whole projects parse with one worker per core, no locks on the hot path.
- **Error-tolerant** — parsing never fails; malformed input produces error nodes
  with diagnostics (an LSP server parses broken code all day).

Intended consumers: static analysis, refactoring tools, code generation — and,
down the road, an LSP implementation and possibly a compiler front-end.

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│ 1. SourceManager   files, encodings/BOM, text cache,        │
│                    .inc path resolution                     │
├────────────────────────────────────────────────────────────┤
│ 2. Lexer           text → flat token array                  │
│                    (incl. directives and trivia)            │
├────────────────────────────────────────────────────────────┤
│ 3. Preprocessor    $IFDEF/$IF branching, $I splicing        │
│                    (include stack), option-state stack      │
│                    → visible token stream                   │
├────────────────────────────────────────────────────────────┤
│ 4. Parser          recursive descent + Pratt expressions    │
│                    → homogeneous AST                        │
└────────────────────────────────────────────────────────────┘
```

Data model: index-based, allocation-friendly — tokens and nodes are records in
contiguous per-unit arrays (an arena per unit); references are integer indices,
not object pointers. Unit trees are immutable once built.

## Layout

| Path | Contents |
|---|---|
| `source/` | the library: `PasTree.Types`, `PasTree.SourceManager`, `PasTree.Lexer`, `PasTree.Preprocessor`, `PasTree.Ast`, `PasTree.Ast.Kinds` (generated from the spec), `PasTree.Parser.*`, `PasTree.Ast.Json`, `PasTree.Project` |
| `tests/` | DUnitX tests: golden JSON trees per spec feature, byte-for-byte roundtrip, full-corpus runs |
| `tools/` | the node-kinds generator (spec `*AST:*` blocks → `PasTree.Ast.Kinds.pas`) |

## Definition of done (v1)

1. Lexes and parses the **entire Delphi 13 source tree** (RTL/VCL/FMX/…) with
   zero errors.
2. Roundtrip: concatenated tokens + trivia == original source, byte-for-byte.
3. Golden AST tests keyed to the spec's feature numbering (e.g. test `5.4.1`
   covers the inline-`if` expression).

## Requirements

- Delphi 13.0 Florence or later (the parser is written in the language it parses).

## License

[MIT](LICENSE) © 2026 Oleksandr Skliar.

PasTree is an independent open-source project, not affiliated with or endorsed
by Embarcadero Technologies. "Delphi" is a trademark of Embarcadero
Technologies, Inc.
