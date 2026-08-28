# PasTree editor features - specification

Status: living document. Describes the editor-facing features built on the
PasTree engine (demo today, LSP later), their required behavior (parity
target: the real RAD Studio IDE), and the resolution pipeline each relies
on. Sections marked GAP describe behavior that is specified but not yet
implemented; each gets removed when closed.

## 1. Syntax highlighting (`demo/PasTreeDemo.Highlighter.pas`)

`TPasTreeSynHighlighter`, a SynEdit highlighter driven by the REAL lexer +
preprocessor + parser - not regex approximations.

1.1 **Token coloring** - keywords, identifiers, numbers, strings, comments,
    directives ({$...}), symbols, BASM. Whole-buffer re-tokenize on change,
    O(tokens); a dirty flag (not a text compare) gates re-scan.

1.2 **Smart weak-keyword coloring** - context words (`read`, `deprecated`,
    `platform`, visibility words, routine directives...) are keyword-colored
    ONLY where the AST proves them to be directives (nkDirective /
    nkVisibility / nkPropSpec node spans). The same words as plain
    identifiers stay identifier-colored. Requires a successful parse;
    falls back to the flat 59-word `DIRECTIVE_WORDS` list otherwise.

1.3 **Inactive-code greying** - tokens inside `$IFDEF`'d-out regions
    (`TPasPreprocessed.Skipped`) render `clGrayText`, checked before any
    other attribute. The `{$IFDEF}`/`{$ENDIF}` markers themselves stay
    normally colored (region boundary semantics), matching the IDE.

1.4 **Hover link rendering** - a `(from, to)` RAW-token range renders as a
    blue underlined link (all token kinds inside the range, including the
    dots of a qualified name). Set on ctrl+hover from `IdentAt`'s span.

## 2. Go-to-declaration (`source/PasTree.Sema.Nav.pas` + demo wiring)

Parity target: **ctrl+click on ANY identifier navigates to the place it is
declared**, exactly like the RAD Studio IDE. "Any" means all of:

| # | Identifier class | Target | Status |
|---|------------------|--------|--------|
| 1 | Local/global var, const, type, routine, param, field (same unit) | its declaration | OK |
| 2 | Name from an explicitly `uses`-d unit | decl in that unit's interface | OK |
| 3 | Member access (`X.Field`, `Obj.Method`), incl. through ancestors/generics/aliases cross-unit | member decl | OK (Phase 3c) |
| 4 | Name from the IMPLICIT `System` unit (`sLineBreak`) | System.pas decl | OK |
| 5 | Builtin whose REAL decl exists in a used unit / System (`TBytes`, `TObject`) | real decl | OK |
| 6 | Compiler intrinsic with NO source decl (`Integer`, `Length`, `True`) | **System.pas unit header** (like the IDE) | OK |
| 7 | Implicit `Result` | enclosing routine's name | OK |
| 8 | `uses` clause unit name (single or dotted; any segment) | that unit's file, its `unit` header | OK |
| 9 | Qualifier of a qualified expression (`System` in `System.sLineBreak`; longest-match: `System.SysUtils` wins in `System.SysUtils.TBytes`) | that unit's file | OK |
| 10 | Identifier inside ANY unit of the project closure (not just the main file) | as above | OK (`AnalyzeProject`) |
| 11 | Name from a unit found only via IDE library/browsing paths (`Application` → Vcl.Forms, `TSynCustomHighlighter` → SynEditHighlighter) | decl in that unit | OK (demo registry paths) |
| 12 | Unqualified unit name needing a namespace prefix (`uses Generics.Collections` → System.Generics.Collections.pas, per `-NS`) | resolved unit | OK |
| 13 | Aliased unit name (`-A` / DCC_UnitAlias) | aliased-to unit | OK |
| 14 | Identifier inside an opened `$I` include file tab | decl | GAP (IdentAt is main-file-only; nav INTO includes works) |
| 15 | Overload-precise jump (CallTarget) / decl↔impl toggle | exact overload | GAP (jumps to head symbol) |

Hover highlight span rules: a plain identifier highlights itself; a dotted
`uses` name or expression QUALIFIER highlights the whole qualifier (all
segments + dots, never the trailing member); the trailing member of a
qualified expression highlights only itself.

### 2.1 Resolution pipeline (what makes each row work)

1. **Phase 1** (per-unit): RefMap - rows 1, 7.
2. **Phase 2** `CrossResolve`: ExtRefMap via explicit uses (row 2), the
   implicit System unit (row 4), qualified-expression unit prefixes with
   greedy longest-match (row 9).
3. **Phase 3c** `CrossType`/`FindMemberX`: member refs cross-unit, through
   builtins redirected by `ResolveRealDecl` (rows 3, 5).
4. **Nav fallbacks** (`ResolveDecl`): skUnitRef → unit file (row 8);
   DeclNode-less builtin → `ResolveRealDecl` (row 5) → else the real
   System unit's header (row 6); synthetic Result → routine (row 7).
5. **Closure analysis** (`AnalyzeProject`, row 10): the transitive uses
   closure from the main source is loaded, and EVERY loaded model gets the
   cross passes - not just the main file (which is `AnalyzeFile`'s narrower
   contract, kept for tools).
6. **Unit-file resolution** (`ResolveUnit`, rows 11-13): `in`-path →
   `<dotted>.pas`/`<leaf>.pas` against referring dir + search paths →
   **unit aliases** → **namespace prefixes** (`-NS` order) → basename index.
7. **Search path assembly** (demo, row 11): project dir + .dproj
   DCC_UnitSearchPath + the IDE's REAL resolution sources, read from the
   registry (`HKCU\SOFTWARE\Embarcadero\BDS\<ver>`): `Library\<Platform>\
   Search Path` + `Browsing Path`, with `$(BDS)`/`$(Platform)`/user
   Environment Variables (e.g. `$(avi3rdlib)`) expanded - this is exactly
   how the IDE itself finds VCL and third-party sources.

### 2.2 Non-goals (for now)

- Keywords are not navigation targets (`string`, `inherited`) - IDE parity.
- Diagnostics remain zero-false-positive-first: navigation reach (System,
  browsing paths) must NEVER add new E2003s relative to the same analysis
  without them.
