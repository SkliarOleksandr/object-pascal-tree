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
| 11 | Name from a unit found only via IDE library/browsing paths (`Application` -> Vcl.Forms, `TSynCustomHighlighter` -> SynEditHighlighter) | decl in that unit | OK (demo registry paths) |
| 12 | Unqualified unit name needing a namespace prefix (`uses Generics.Collections` -> System.Generics.Collections.pas, per `-NS`) | resolved unit | OK |
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
4. **Nav fallbacks** (`ResolveDecl`): skUnitRef -> unit file (row 8);
   DeclNode-less builtin -> `ResolveRealDecl` (row 5) -> else the real
   System unit's header (row 6); synthetic Result -> routine (row 7).
5. **Closure analysis** (`AnalyzeProject`, row 10): the transitive uses
   closure from the main source is loaded, and EVERY loaded model gets the
   cross passes - not just the main file (which is `AnalyzeFile`'s narrower
   contract, kept for tools).
6. **Unit-file resolution** (`ResolveUnit`, rows 11-13): `in`-path ->
   `<dotted>.pas`/`<leaf>.pas` against referring dir + search paths ->
   **unit aliases** -> **namespace prefixes** (`-NS` order) -> basename index.
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

## 3. Rename (`TPasNavigator.PlanRename`/`PlanUnitRename` + demo wiring)

Status: IMPLEMENTED (PasTree 0.13.1) - `PlanRename`, `PlanUnitRename`,
`IsValidRenameName`, `IsValidUnitRenameName` in
`source/PasTree.Sema.Nav.pas`, wired into the demo as ctrl+E / the editor
context menu, regression-covered by `tests/SemaNavSmoke.dpr` (fixtures
`NavRen`, `NavRenP`, plus the existing `NavA`/`NavB`/`Namespace.NavD` set for
the unit half).

Rename is Find References with the answer applied: the SAME identity search
(declaration + every resolved use), turned into a set of text edits.
Nothing about it is textual - two same-named locals in different scopes can
never cross-pollute, and an overloaded routine renames only the overload the
caret is on, exactly as its reference list already showed.

It covers TWO of the three identities Find References offers - a symbol and a
unit - and deliberately not the third: a compiler builtin is never
renameable (3.1).

Parity target: the RAD Studio IDE's own Refactor > Rename. What each
identifier class does here:

| # | Renamed from | Covered positions | Status |
|---|--------------|-------------------|--------|
| 1 | Local/global var, const, type, field, param, routine (same unit) | its declaration + every use | OK |
| 2 | A name used cross-unit (its declaration, or any use of it) | declaration + every use in EVERY analyzed unit | OK |
| 3 | An overloaded routine, from one overload | only that overload's declaration and call sites | OK |
| 4 | A `forward`/interface routine's PARAMETER, from either header | both headers + the body's uses (a language rule - see 3.4) | OK |
| 5 | A class method's parameter, from the class body or the implementation | both headers + the body's uses | OK |
| 6 | A routine NAME with two headers (`forward`, method impl) | both headers + every call site | OK |
| 7 | Implicit `Result` | nothing - refused, no declaration site to rename | OK (by design, 3.3) |
| 8 | A compiler builtin (`Integer`, `Length`, `True`) | nothing - refused outright | OK (by design, 3.1) |
| 9 | A UNIT, from its own header name or from any `uses` item (any segment) | the header + every `uses` item project-wide, whole dotted spans | OK (3.8) |
| 10 | The FILE a renamed unit lives in | not renamed - the required name is HANDED BACK to the host | OK (by design, 3.8) |
| 11 | A `uses` item spelled as a `-A` unit ALIAS | nothing - the whole unit rename is refused, named in the error | OK (by design, 3.8) |
| 12 | Name-collision detection at an edit site | - | GAP (deliberate - see 3.5) |
| 13 | Identifier inside an opened `$I` include file | - | GAP (`IdentAt` is main-file-only, same limit go-to-declaration has) |

3.1 **Scope.** Two identities: a symbol (`SymbolAt` -> `PlanRename`) and a
    unit (`UnitAt` -> `PlanUnitRename`, see 3.8). A compiler BUILTIN is
    never renameable and `PlanRename` refuses one outright, by an explicit
    `sfBuiltin` test rather than as a side effect of having no declaration
    node: the name is the compiler's (`Integer`, `Length`, `True`), the
    seeding is per model, and "every use of it" would mean every unit in the
    language. It stays a Find References-only target (`FindBuiltinReferences`
    exists precisely because reading those uses is still useful).

3.2 **The plan** (`PlanRename(ATMid, ASym, ANewName)`) returns one
    `TPasRenameEdit` per position: the old identifier's file/line/col/length,
    an `IsDecl` flag for the declaration site, and a PREVIEW - the line as it
    reads after every edit ON THAT LINE has been applied, plus the new name's
    highlight span in it. Two hits on one line move each other, so the
    preview shifts each later span by the accumulated length delta.

3.3 **Refusals** (plan returns False with host-displayable text, no edits):
    a new name that is not a legal identifier or IS a reserved word
    (`IsValidRenameName`, exposed so a host can gate its OK button as the
    user types), the unchanged current name, and a symbol with no
    declaration site (an implicit `Result`) - that last one would otherwise
    half-apply, renaming the uses and leaving the declaration behind.

3.4 **Paired headers**. Object Pascal requires an implementation header to
    repeat its declaration EXACTLY, parameter names included - dcc rejects a
    mismatch with E2037 plus an E2003 on the body's now-undeclared name, for
    a `forward` routine and a class method alike. Each header declares its
    OWN parameter symbols, and a routine's two headers are one symbol whose
    second spelling Find References deliberately never reports (a header is
    not a use). So the plan reaches past the reference list in exactly two
    structural ways, both language rules rather than heuristics: a
    parameter's counterpart in the peer header, paired by POSITION in the
    parameter list (never by name - the name is what is changing), and the
    peer header's own routine name. Nothing else.

3.5 **Not checked**: whether the new name COLLIDES with something already
    visible at an edit site. Object Pascal scoping makes that a full
    re-resolution question rather than a lookup; the host re-analyzes after
    applying and any collision surfaces as an ordinary diagnostic.

3.6 **Applying** is the host's job - `PlanRename` touches no files. Edits
    arrive sorted ascending, so a host applies each file's edits from the
    LAST backwards (or shifts columns by hand).

3.7 **Demo wiring**: ctrl+E, or the editor context menu's `Rename...`, on
    the identifier under the caret (or the start of a selection - the same
    position rule Find References uses). An input dialog pre-filled with the
    current name (and saying whether a symbol or a unit is being renamed);
    OK applies the edits to BUFFERS, never to files, and opens a Find
    References-shaped results page whose snippets are the POST-rename lines.
    A file that is already OPEN is edited through its editor - one undoable
    step per file, and the ordinary reanalysis debounce. A file that is NOT
    open is edited in an in-memory overlay instead (`FRenameBuffers`, fed to
    the analysis beside the open tabs and handed to the editor if that file
    is opened later): renaming a name used across a closure must not open a
    tab per touched file. Every position is verified against the buffer
    first: a buffer edited since the last analysis has moved them, and one
    mismatch cancels the whole rename before anything changes rather than
    applying a partial one.

3.8 **Unit rename** (`PlanUnitRename(ATargetMid, ANewName)`) is the same
    shape for the OTHER identity: a unit has no single symbol shared across
    referring units (each gets its own local `skUnitRef`), so the target
    MODEL is the identity - exactly what `FindUnitReferences` already keys
    on. The plan is that unit's own header name (the `IsDecl` row) plus
    every `uses` item project-wide that resolved to it. Three rules are its
    own:

    - a dotted name is ONE name: the WHOLE written span is replaced, not the
      segment the caret was over (`IsValidUnitRenameName` accepts dots, each
      segment still an identifier and not a reserved word);
    - a `uses` item written as the bare LEAF (a `-NS` namespace prefix
      resolved it) stays bare when the prefix is unchanged, and is rewritten
      in full when it is not;
    - a `uses` item spelled as anything else - a `-A` unit alias - REFUSES
      the whole rename, naming the file and line. Leaving one `uses` clause
      pointing at a name that no longer exists is a build break, which is
      the one outcome worse than doing nothing.

    Object Pascal ties a unit's name to its file name, so the plan also
    returns `ARequiredFileName` (`<new name>.pas`). It does NOT rename the
    file - a host either does it or tells the user, but must not stay
    silent. The demo, which never writes files, says so in a dialog.

