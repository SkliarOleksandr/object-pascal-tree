# DelphiAST — analysis for PasTree golden comparison

Analysis of the user's **previous** hand-written Delphi parser at `C:\Repos\DelphiAST`
(git `master`, MIT © Oleksandr Skliar). Purpose: understand its `.pas.astjson`
golden dumps so PasTree can be validated against them later.

> **One-line verdict:** DelphiAST is a **semantic compiler front-end**, not a
> syntactic CST. Its `.astjson` dumps are a **declaration-signature summary** with
> resolved types and memory-address handles — **not** a faithful syntax tree.
> They are useful as a *declaration-inventory* cross-check for PasTree, nothing more.

---

## 1. What DelphiAST is

A ~11.6 KLOC recursive-descent parser **fused with full semantic analysis**:
name resolution, type checking, overload matching, and generic instantiation all
happen *inline during parse*. Two-pass per unit (interface-only, then full).

| Trait | DelphiAST | PasTree |
|---|---|---|
| Kind | Semantic front-end | Syntactic CST |
| Statement tree | **Discarded** (validated, not stored) | Full, per spec ch.05/18 |
| Trivia (comments/ws) | Lost | Full-fidelity, byte-roundtrip |
| Symbol table / types | Yes (scopes, overloads, generics) | No (future resolver) |
| Error handling | Stop-on-first (configurable) | Error-tolerant |
| Handles | Object memory address | Arena index (deterministic) |

### Pipeline
`Text → Lexer → Parser(+semantics) → symbol table`
- Entry: `TPascalProject.Compile` (`AST.Pascal.Project.pas:492`) →
  `TASTDelphiUnit.Compile` (`AST.Delphi.Parser.pas:2724`) →
  `Lexer.First` (`:2746`) → `ParseUnitDecl` (`:2756`) → `DoParse` (`:2771`, big dispatch `:2806`).
- Lexer: `Source/Lexers/AST.Lexer.pas` (generic `TGenericLexer`) +
  `AST.Lexer.Delphi.pas` (`TTokenID`, 150+ tokens). Character-driven; no trivia kept.
- Expressions: **RPN stack + precedence climbing** (`AST.Parser.Contexts.pas:42`,
  operator tables `AST.Delphi.Operators.pas:119`/`:170`).

### Two AST hierarchies
- **A — syntactic** (`AST.Classes.pas`: `TASTItem`/`TASTDeclaration`/`TASTKWxxx`,
  `TASTBlock`): mostly **stubs**. The `TASTWriter` (`AST.Writer.pas`) that walks
  statement bodies (`WriteKW_If`/`Loop`/`Case`/`Try`) is **not wired into `.astjson`**.
- **B — semantic** (`AST.Delphi.Classes.pas`: `TIDDeclaration` → `TIDType`/
  `TIDStructure`/`TIDProcedure`/`TIDVariable`/`TIDField`/`TIDParam`/…): the **real** AST.
  `TIDDeclaration = class(TASTDeclaration)` — B extends A.
- **`.astjson` is emitted from hierarchy B only** (declaration signatures).

---

## 2. The `.astjson` golden schema (what's actually emitted)

Schema classes: `AST.JsonSchema.pas` + `AST.Delphi.JsonSchema.pas`.
Emission: `ToJson` overrides in `AST.Delphi.Classes.pas`, driven by
`TPascalUnit.ToJson` (`AST.Pascal.Parser.pas:177`). Serialized with RTL
`REST.Json` in `TestApp` and written to `<file>.pas.astjson`.

### Root — `unit`
```jsonc
{ "fileName": "...", "intfDecls": [ ... ], "implDecls": [ ... ],
  "kind": "unit", "name": "...", "handle": 0, "srcRow": 0, "srcCol": 0 }
```

### Base fields on every declaration
`kind`, `name`, `handle`, `srcRow`, `srcCol`
(`TIDDeclaration.ToJson`, `AST.Delphi.Classes.pas:2967`).
- **`srcCol` = `Col − Length(name)`** → the *start* column of the identifier (1-based).
- **`handle` = `TASTHandle(Self)`** = the object's memory address
  (`AST.Classes.pas:852`). **Non-deterministic across runs.**

### `kind` values (`GetASTKind`)
`unit` · `function` (all procs/funcs/ctors/dtors/operators) · `type` · `variable` ·
`constant` · `property` · `field` · `parameter` · `uses` · `<unknown>`.

### Per-kind extra fields
- **`type`** — `typeKind` + `typeDecl` (usually `null`). `typeKind` (`GetASTTypeKind`,
  `:4013`): `pointer`·`range`·`enum`·`set`·`static-array`·`dynamic-array`·
  `open-array`·`proctype`·`record`·`class`·`classof`·`interface`·`generic-param`·`<unknown>`.
  (`alias` is defined in the schema but comes from a separate path.)
  Structured types (`record`/`class`/`interface`/`helper`) add
  **`ansestorName`**, `ansestorHandle`, **`members[]`** (`TIDStructure.ToJson:5751`;
  members include *expanded overloads*).
- **`function`** — `params[]`, `isVirtual`, `isOverload`, `prevOverload` (handle),
  `resultTypeName`/`resultTypeHandle`, **`body{}`** (`TIDProcedure.ToJson:3281`).
  **`body` is ALWAYS `{}`** — `WriteFuncs` is a stub (`AST.Writer.pas:115`),
  `BodyToJson` emits an empty `TASTJsonFunctionBody`. **No statement detail exists.**
- **`variable`/`field`** — `dataTypeName`, `dataTypeHandle` (`TIDVariable.ToJson:4865`;
  `<unknown>`/0 when unresolved).
- **`parameter`** — base + `dataTypeName`/`dataTypeHandle` + **`modifier`**
  (`const ` / `var` / `out` / `""`) (`TIDParam.ToJson:9722`).

### Quirks to expect
1. **`null` entries** in `intfDecls`/`implDecls`: imported `uses` units are skipped
   (slot left unassigned) and any decl whose `ToJson` returns `nil` serializes as `null`
   (`TPascalUnit.ToJson:184-201`).
2. **Only 95 golden files**, and many are essentially empty
   (`intfDecls:[]`, `implDecls:[]`) — e.g. all the `Classes.Inherited*`, `Enums.*`
   goldens. The richest are `Operators/Compare/*` (~13 KB).
3. No comments, no formatting, no statement bodies, no local vars, no expressions.

---

## 3. Implication for PasTree golden comparison

The goldens are **not** a CST oracle. A direct tree diff is impossible and pointless.
The only sound use is a **declaration-inventory projection**:

**Plan (deferred until PasTree has a projection layer):**
1. Build a PasTree → *declaration summary* projector that walks the CST and emits,
   per unit: ordered interface/implementation declarations with
   `{ kind, name, srcRow, srcCol(start), typeKind, ancestorName,
   members[], params[{modifier, name, typeName}], resultTypeName, isVirtual, isOverload }`.
2. **Normalize away** everything non-deterministic / semantic-only before compare:
   - drop **all** `*Handle` fields (memory addresses);
   - drop `dataTypeName`/`resultTypeName`/`ancestorName` **or** compare only as
     written text (DelphiAST resolves them; PasTree sees syntax) — start by dropping;
   - drop `body` (empty on both sides);
   - drop `null` array slots (uses-imports);
   - treat `procedure` vs `function` both as `kind:function` (DelphiAST merges them).
3. Compare **declaration name + kind + typeKind + ordered params(modifier,name) +
   member names/kinds + src start position**. That is the reliable overlap.
4. Expect mismatches where DelphiAST is semantic: expanded overloads in `members`,
   generic instance names (`GenericName + descriptor.DisplayName`), synthesized decls.

**Verdict:** treat `.astjson` as a **low-resolution declaration checklist**
(does PasTree see the same top-level/type-member declarations at the same positions?),
not as golden trees. PasTree's own numbered golden S-expr tests remain the primary oracle.

---

## 4. Project goal — semantic parity (future work)

DelphiAST's value is its **semantics**, and PasTree must eventually match it.
Stated goal: PasTree should reach **at least the same functional level** as
DelphiAST — i.e. grow a full semantic layer on top of the CST providing:

1. **Generic instantiation** (`List<T>` → `List<Integer>`).
2. **Overload resolution** (rank candidates, implicit-cast/data-loss tiers).
3. **Full type-checking** (assignability, operator typing, member access).
4. **Delphi-compatible `EXXXX` diagnostics** (same codes/messages as dcc).

PasTree remains a **superset**: it keeps CST / full-fidelity roundtrip /
error-tolerance (all of which DelphiAST lacks) *and* adds semantics — it is not a
reimplementation of DelphiAST. Byte-for-byte reconstruction was never a DelphiAST
goal; it is PasTree's distinguishing edge.

**Reference material in DelphiAST for the future resolver:**
- `AST.Delphi.Errors.pas` — 100+ `EXXXX`/resourcestring messages matched to Delphi.
- `AST.Delphi.System.pas` + `SysTypes`/`SysFunctions`/`SysOperators` — builtin
  type/function/operator bootstrap (Integer, TObject, Length, `+`, implicit casts…).
- `AST.Delphi.Classes.pas` + `AST.Delphi.Parser.pas` — scope model, overload
  matcher (`MatchOverloadProc`, match tiers), generic descriptor/instantiation.

---

## Appendix — key files
| File | Role |
|---|---|
| `AST.Delphi.Parser.pas` (405 KB) | recursive-descent parser + inline semantics |
| `AST.Delphi.Classes.pas` (305 KB) | semantic node hierarchy `TID*` + all `ToJson` |
| `AST.Classes.pas` | syntactic hierarchy `TAST*` (stubbed) |
| `AST.Writer.pas` | statement-body walker — **not used for `.astjson`** |
| `AST.JsonSchema.pas` / `AST.Delphi.JsonSchema.pas` | JSON DTO classes |
| `AST.Pascal.Parser.pas` | `TPascalUnit` base, `ToJson` root, scopes/state |
| `Source/Lexers/AST.Lexer*.pas` | generic + Delphi lexer |
| `AST.Parser.Contexts.pas` | RPN expression stack |
| `AST.Delphi.System*.pas`, `SysTypes/SysFunctions/SysOperators` | builtin bootstrap |
| `TestApp/` | GUI driver; calls `Module.ToJson` → writes `.pas.astjson` |
