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
| 16 | An inline `var`'s OWN declaration name (`var L := Expr`, caret on L) | its type, for a type-of query | GAP (SymbolAt does not claim the declaration name; a USE of L answers normally - measured through pastree-lsp 2026-09-07) |
| 17 | The NAME of a bare property redeclaration (`property Items;` republishing an inherited property, caret on the declaration itself) | ONE link up the chain: the nearest ancestor's declaration of the same property, which may itself be a redeclaration - a second ctrl+click climbs again; a typed declaration stays put | OK (0.21.0; a USE of the property still lands on the nearest declaration, as before) |

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

Status: IMPLEMENTED (PasTree 0.15.0) - `PlanRename`, `PlanUnitRename`,
`IsValidRenameName`, `IsValidUnitRenameName`, `RenameBlockReason` and
`LibraryPaths` in `source/PasTree.Sema.Nav.pas`, wired into the demo as
ctrl+shift+E / the editor context menu, regression-covered by `tests/SemaNavSmoke.dpr` (fixtures
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
| 12 | Anything declared in a LIBRARY source (RTL/VCL/third-party) | nothing - refused whole, naming the file | OK (by design, 3.9) |
| 13 | A property REDECLARED bare in descendants (`property Items;` promoting visibility, changing accessors or streaming specifiers - no type written), from any link | every declaration of the chain + every use bound to any of them; Find References shows the same set (the other links' declaration names are hits). A redeclaration WITH a type is a NEW property hiding the inherited one (dcc-probed 2026-09-09) - it and everything below it stay out | OK (0.21.0) |
| 13 | Anything whose declaration or ANY use sits in a read-only file | nothing - refused whole, naming the file | OK (by design, 3.9) |
| 14 | Name-collision detection at an edit site | - | GAP (deliberate - see 3.5) |
| 15 | Identifier inside an opened `$I` include file | - | GAP (`IdentAt` is main-file-only, same limit go-to-declaration has) |

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

3.7 **Demo wiring**: ctrl+shift+E, or the editor context menu's
    `Rename...`, on the identifier under the caret (or the start of a selection - the same
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

3.9 **Off-limits FILES** (both plans, `RenameBlockReason`). Two refusals are
    about the file rather than the symbol, and either one refuses the WHOLE
    rename with the file named - the same all-or-nothing rule as the
    unit-alias refusal in 3.8, for the same reason:

    - the file lives under a `LibraryPaths` tree - the INSTALLED library
      sources (RTL/VCL/third-party). Renaming a name there would mean
      renaming it for every project on the machine, in sources that are not
      the user's to change, and the plan can only see the uses inside THIS
      project's closure anyway;
    - the file is read-only on disk (a source-control lock, a shipped
      library copied in). A path that does not EXIST is not blocked - a host
      may have analyzed an unsaved buffer - but a path that cannot be
      statted at all is: "unknown" is not "writable".

    `LibraryPaths` is the HOST's declaration and is empty by default: only
    the host knows which of its search paths hold the user's own sources.
    The demo feeds it the IDE's registry library/browsing paths
    (`ExtraSearchPaths`) and deliberately keeps the project directory and the
    `.dproj` search paths OUT - those are the user's units, and renaming
    across them is the point of the feature. The test is a path prefix over
    the whole tree, subdirectories included.

    A host can call `RenameBlockReason(APath)` itself to gate its command
    before asking for a new name; the demo's `Rename...` is disabled while
    the caret sits in a blocked file.


## 3.10 Demo menu: one `Find All` submenu

Status: IMPLEMENTED (demo, 0.22.0; no engine change). The editor context
menu groups every "find" question under one `Find All` submenu, one entry
per identity question, References first (the one always available) and the
rest in the order this document describes them:

- `Find All > References` (§2/§3 identity - `SymbolAt`/`UnitAt`/`BuiltinNameAt`)
- `Find All > Overrides` (§4 - `MethodAt`)
- `Find All > Implementations` (§5 - `InterfaceMethodAt` OR `InterfaceAt`)
- `Find All > Descendants` (§6 - `TypeAt`)
- `Find All > Assignments` (§7 - `AssignableAt`)
- `Find All > Creations` (§8 - `ClassAt`)
- `Find All > Destructions` (§8 - `ClassAt`)

Each entry keeps its own gating rule - the regrouping is presentation only. A
gated-out entry stays visible but disabled (the IDE greys out inapplicable
Refactor items the same way) so the submenu's shape never shifts with the
caret. Every command opens its own results page: `TFindRefTab.Kind`
(`stkRefs`, `stkRename`, `stkOverrides`, `stkImpls`, `stkDescendants`,
`stkAssigns`, `stkCreations`, `stkDestructions`) is part of the page
identity, so a repeated search refreshes its own page and eight answers
about one symbol never overwrite each other.

## 4. Find Overrides (`TPasNavigator.MethodAt`/`FindOverrides` + demo wiring)

Status: IMPLEMENTED (PasTree 0.19.0) - `MethodAt`, `FindOverrides`,
`TPasOverrideHit`/`TPasOverrideKind` in `source/PasTree.Sema.Nav.pas`, wired
into the demo as `Find Overrides` in the editor context menu (next to Find
References), regression-covered by `tests/SemaNavSmoke.dpr` (fixtures
`NavOvrA`, `NavOvrB`).

The question it answers is "where does this method go when the object is
really a descendant" - every declaration sharing one VMT (or message-table)
slot, across the whole analyzed closure. It is NOT a reference search: no
call site is a row, and a same-named method in an unrelated hierarchy never
is either.

Two walks, both over resolved bindings:

1. **Up**, from the class of the method under the caret through
   `AncestorOfX`, while each ancestor still declares a same-named method
   carrying `virtual`/`dynamic`/`override`/`message`. The topmost one is the
   chain's root - so clicking an `override` halfway down answers for the
   whole chain, exactly like clicking the root does.
2. **Down**, over a reverse-heritage index built for that one call from
   every class's `class(TBase)` reference AS THE RESOLVER BOUND IT
   (RefMap/ExtRefMap), then breadth-first. The index is the reason this is
   affordable: the alternative, `XDescendsFrom` per class in the closure,
   re-walks every ancestor chain in the project.

What each declaration shape does:

| # | Declaration | Row | Status |
|---|-------------|-----|--------|
| 1 | The `virtual`/`dynamic` declaration that introduced the slot | `pokRoot`, always first; one row per OVERLOAD the root class declares under that name (`TStream.Read` is six) - the chain is reported by name, not by signature match | OK |
| 2 | `override`, any depth, any unit of the closure | `pokOverride` | OK |
| 3 | `reintroduce` (deliberately NOT an override) | `pokReintroduce` - reported because a reader must not mistake it for one | OK |
| 4 | A `message <expr>` handler in a descendant - implicitly virtual, and dcc rejects `override` on one | `pokMessage`, matched by name + directive | OK |
| 5 | A same-named method with NONE of those directives (an ordinary hiding declaration, dcc's W1010) | no row, by design - it shares no slot, and it would drown every `Create`/`Destroy` result | OK (by design) |
| 6 | A non-virtual method, or a virtual one nothing overrides | its own single `pokRoot` row - the honest "nothing overrides this" | OK |
| 7 | Started from a qualified implementation header (`procedure TFoo.Bar;`) | the same chain (`MethodAt` takes the decl<->impl hop; the header's own name binds to no symbol, so `SymbolAt` alone declines it) | OK |
| 8 | A method of a record, an interface, or a plain routine | `MethodAt` declines - the command is not offered | OK (by design) |
| 9 | An INTERFACE method's implementors (`TFoo = class(TObject, IBar)`) | - | not this search - a separate command, see §5 |
| 9a | The CLASSES below this method's class (no method question at all) | - | not this search either - Find Descendants, §6 |
| 10 | A class whose ancestor is written through a type ALIAS (`TB2 = TB;` then `class(TB2)`) | - | GAP - the index keys on the symbol the heritage name bound to, which is the alias |
| 11 | An event handler wired only through a `.dfm` (`OnClick`) | - | not an override at all: it is an assignment to a property, reached by Find References |
| 12 | A class PROPERTY (`MethodAt` accepts it since 0.21.0) | its redeclaration chain: the declaration that writes the type is `pokRoot`, every bare `property Items;` below it `pokRedeclared`, hierarchy order; a redeclaration WITH a type is a new property - no row, and its branch is closed. A lone root is the honest "declared nowhere else" | OK (0.21.0) |

Measured on the flattened RTL corpus (342 models, 2.5 s to analyze):
`TObject.Destroy` = 136 rows in 8 ms, `TPersistent.Assign` = 8 rows in 6 ms,
`TStream.Read` = 23 in 6 ms. The reverse-heritage index is rebuilt per call
and is not what costs - so no cache, and no invalidation story to get wrong
against incremental reanalysis.

**Cost note for hosts.** The chain of a method as universal as `Destroy`
legitimately covers every class in the closure, and each model holding a row
is rehydrated to read its directives (the same rule `FindReferences`
follows). Gate the command on `MethodAt`, never on "the caret is on an
identifier".

## 5. Find Implementations (`TPasNavigator.InterfaceMethodAt`/`FindImplementations` + demo wiring)

Status: IMPLEMENTED (PasTree 0.20.0) - `InterfaceMethodAt`,
`FindImplementations`, `TPasImplHit`/`TPasImplKind` in
`source/PasTree.Sema.Nav.pas`, wired into the demo as `Find Implementations`
in the editor context menu (next to Find Overrides), regression-covered by
`tests/SemaNavSmoke.dpr` (fixtures `NavIntfA`, `NavIntfB`).

The interface-side twin of §4, and a SEPARATE command for a separate
identity: an interface method has no override chain, a class method has no
implementors, and one command for both would have to guess which the user
meant on a class that does both.

The hard part is that there is no keyword to key on. An interface method is
implicitly virtual and an implementing class writes NO directive at all - dcc
pairs the two by name and signature. So the tie this searches is the class's
own heritage list, over the same reverse-heritage index §4 builds:

1. the interface's own DESCENDANT interfaces (`IChild = interface(IBase)`),
   transitively - a class implementing IChild implements IBase's methods too;
2. every class/`object` LISTING one of those interfaces.

| # | Declaration | Row | Status |
|---|-------------|-----|--------|
| 1 | The interface method itself | `pikRoot`, first; one row per overload the interface declares under that name | OK |
| 2 | A method of a class that lists the interface | `pikImplementor` | OK |
| 3 | A method of a class that lists a DESCENDANT interface (`class(TObject, IChild)`) | `pikImplementor` | OK |
| 4 | The class lists the interface but declares no such method - an ANCESTOR's method satisfies it | `pikInherited`, positioned on the ancestor's declaration (the code that runs) with `ViaTypeName` naming the class that took the interface on | OK |
| 5 | The same inherited declaration reached through many classes (fifty classes over one `TInterfacedObject._AddRef`) | ONE row, first reach wins - fifty rows on one line is not an answer | OK (by design) |
| 6 | A same-named method on a class that implements nothing | no row | OK |
| 7 | A method RESOLUTION clause (`procedure IBar.Baz = MyBaz;`) | - | GAP - the implementor is a differently NAMED method; nothing in the name search can find it |
| 8 | A delegated implementation (`property Impl: IBar read FImpl implements IBar`) | - | GAP - the implementor is whatever object the property returns, a value question rather than a declaration one |
| 9 | Signature-precise pairing of an OVERLOADED interface method | - | GAP (by design) - every same-named candidate is a row, the same choice §4 makes for a chain |
| 10 | An ancestor or interface named through a type ALIAS | - | GAP - the index's own limit, see §4 |

Measured on the VCL closure of a `uses Vcl.Forms, Vcl.ComCtrls, Vcl.Grids`
program (103 models): `IInterface.QueryInterface` = 9 rows across 3 files in
1 ms, `IStreamPersist.LoadFromStream` = 3 rows in 1 ms.

### 5.1 From the interface NAME: which classes implement it

Status: IMPLEMENTED (PasTree 0.22.0) - `InterfaceAt`,
`FindInterfaceImplementors`; the demo's `Find All > Implementations` is
enabled by either `InterfaceMethodAt` or `InterfaceAt` and picks the search
accordingly.

`FindImplementations` answers "who implements this METHOD". With the caret on
the interface TYPE itself the coarser question is "which CLASSES implement
it" - one row per class, positioned on the class's own declaration name, the
same two hops stopped one level earlier (the interface's descendant
interfaces, then every class listing any of them; a class listing both IBase
and IChild is one row). Rows reuse `TPasImplHit`: `pikRoot` for the
interface's declaration, `pikImplementor` per class, with `ViaTypeName`
naming the DESCENDANT interface the class actually wrote when that is not
the one asked about (`class(TObject, IChild)` for a search on IBase).

Not a row, by design: a class that gets the interface from its ANCESTOR
(`TBase = class(TObject, IBar)` then `TLeaf = class(TBase)`) - dcc treats
the ancestor as the implementor, and listing every descendant of every
implementor is §6's answer. GAPs shared with the method search: `implements`
delegation, an alias-named interface.

### 5.2 "Does it only search the current file?" - no, and how to tell

Both searches are project-wide by construction (the index sweeps every loaded
model), and both demo pages put the unit count in the tab caption -
`Overrides of 'Paint' (5 in 3 units)` - precisely so this question has an
answer visible without scrolling. Measured cross-unit reach at the time of
writing: `TObject.Destroy` 136 rows across 49 files of the flattened RTL;
`TWinControl.CreateParams` 54 rows across 8 files of the VCL; 991 classes in
that closure, ZERO with an unresolved heritage reference (so no missing
edges).

When a result LOOKS current-file-only, the closure is what to check, not the
search:

- the demo analyzed ONE FILE (`Parse` on a .pas, `AnalyzeFile`) rather than a
  project - there is only one model to search;
- the descendants live in units the analyzed project never imports (nothing
  in the closure names them, so nothing loaded them);
- the chain's root is in the RTL/VCL and those sources are not on the search
  paths - the climb then stops at the caret's own class, and its overrides
  are the only rows left.

## 6. Find Descendants (`TPasNavigator.TypeAt`/`FindDescendants` + demo wiring)

Status: IMPLEMENTED (PasTree 0.22.0) - `TypeAt`, `FindDescendants`,
`TPasDescendantHit`/`TPasDescendantKind` in `source/PasTree.Sema.Nav.pas`,
wired into the demo as `Find All > Descendants`, regression-covered by
`tests/SemaNavSmoke.dpr` over the `NavOvrA`/`NavOvrB`/`NavIntfA` fixtures.

A different question than §4/§5: given a class, `object` or interface, list
every TYPE below it - the declarations themselves (`TFoo = class(TBase)`),
never a member. The same reverse-heritage index §4 builds, walked
breadth-first along ONE kind of edge: ancestor edges between classes for a
class, extends-edges between interfaces for an interface. Breadth-first IS
hierarchy order, so rows arrive as all depth-1 children, then depth-2, and a
host indenting by `Depth` gets the tree without sorting; `ParentTypeName` is
the direct ancestor each row was reached through.

| # | Started from | Row | Status |
|---|--------------|-----|--------|
| 1 | A class/`object` declaration, or its name at any use | `pdkRoot` (the type itself, always first), then every class transitively below it, one row per declaration, project-wide | OK |
| 2 | An interface declaration or its name | the interfaces transitively extending it (`IChild = interface(IBase)`) | OK |
| 3 | The classes IMPLEMENTING a found interface | no row, by design - one axis per command: that is §5.1's answer, and a list mixing class rows and interface rows would have to explain itself | OK (by design) |
| 4 | A type nothing descends from | its single `pdkRoot` row - the honest "no descendants" | OK |
| 5 | A record, a helper, an alias, a non-type | `TypeAt` declines - the command is not offered | OK (by design) |
| 6 | A descendant naming its ancestor through a type ALIAS | - | GAP - the index's own limit, see §4 row 10 |

Cost note for hosts: `TObject`'s descendants are every class in the closure,
each row's model rehydrated to position the hit - gate on `TypeAt`, not on
"the caret is on an identifier". The demo caption counts descendants
excluding the root (`Descendants of 'TOvBase' (4 in 2 units)`).

## 7. Find All Assignments (`TPasNavigator.AssignableAt`/`FindAssignments` + demo wiring)

Status: IMPLEMENTED (PasTree 0.22.0) - `AssignableAt`, `FindAssignments` in
`source/PasTree.Sema.Nav.pas`, wired into the demo as `Find All >
Assignments`, regression-covered by `tests/SemaNavSmoke.dpr` (fixture
`NavAsg`).

Find References with the answer narrowed to WRITES: the same resolved-
identity scan (`CollectReferencesOf`, the property redeclaration chain
included), keeping only the hits that sit in an assignment-target position.
The filter is a node-kind walk from the hit's identifier (`IsAssignTarget`,
no text read, so it runs on demoted models): climb out of the trailing NAME
of a member chain (`Obj.Field := ` writes Field) and out of the BASE of an
index (`A[i] := ` writes into A), then the identifier counts if what it
reached is the left side of `:=` or the counter of a `for`. Anything else on
the way up - a dereference, a call, an argument list - means it is read.

| # | Target | Row | Status |
|---|--------|-----|--------|
| 1 | A local/global var, a field, a parameter | every `X := `, `Obj.X := `, `X[i] := `, `for X := ` project-wide | OK |
| 2 | A property with a `write` specifier (field or setter method) | every write through the PROPERTY syntax (`Obj.Prop := X`), across its redeclaration chain; the setter's own body writes to the FIELD, and a direct call to the setter is a reference to the setter - neither is a row here | OK |
| 3 | A property with NO `write` specifier | `AssignableAt` declines - the command is not offered (nothing to find is not an error); a bare redeclaration asks the whole chain, so `property Items;` under a writable root is writable | OK (by design) |
| 4 | A constant, a type, a routine, `Result` | `AssignableAt` declines | OK (by design) |
| 5 | The declaration site | not a row, as in Find References; the demo pins `DeclHit` above the list | OK |
| 6 | A write THROUGH the symbol (`P^ := `, `Obj.Field := ` with the caret on `Obj`) | no row - the target is what the symbol refers to, not the symbol | OK (by design) |
| 7 | `var`/`out` argument passing (`Foo(X)` with a `var` parameter) | - | GAP - a write to X that reads as a call site; needs the resolved parameter list per argument, left for a later pass |
| 8 | `Inc(X)`/`Dec(X)` and the other mutating intrinsics | - | GAP - same reason as row 7, intrinsic side |
| 9 | Identifier inside an opened `$I` include file | - | GAP (`IdentAt` is main-file-only, the shared limit) |

Rows 7 and 8 are the two the reader of a write list will notice missing;
both need "is this argument position a `var`/`out` parameter" from the
resolver's overload choice, which nothing in the navigator reads yet. When
that lands, `IsAssignTarget` grows one case (`nkCall` argument -> the bound
routine's parameter mode) and nothing else changes.

## 8. Find Creations / Find Destructions (`TPasNavigator.ClassAt`/`FindCreations`/`FindDestructions` + demo wiring)

Status: IMPLEMENTED (PasTree 0.23.0) - `ClassAt`, `FindCreations`,
`FindDestructions` in `source/PasTree.Sema.Nav.pas`, wired into the demo as
`Find All > Creations` and `Find All > Destructions`, regression-covered by
`tests/SemaNavSmoke.dpr` (fixture `NavCD`).

Where instances of one CLASS begin and end. Two commands rather than one
"lifetime" list because the two are read for different reasons - "who makes
these" against "who owns and frees these" - and both are gated by `ClassAt`
(`TypeAt` narrowed to classes/`object`s: an interface has no instances of its
own to create or free). Both read the resolver's BINDINGS around a call,
never the spelling `Create`/`Free`, and both are limited to what the static
text says - the table's "not a row" lines are runtime facts.

| # | Shape | Row | Status |
|---|-------|-----|--------|
| 1 | `TFoo.Create(...)` - qualifier bound to the class, member bound to a constructor (the class's own OR an inherited one: `TFoo.Create` with Create declared on TObject still makes a TFoo) | Creations row, positioned on the class name in the call; one per call, overloads included | OK |
| 2 | `TFoo<T>.Create` (qualifier wrapped in type arguments) | Creations row | OK |
| 3 | `TBar.Create` for a descendant TBar | no row - that is a TBar; §6 says which those are | OK (by design) |
| 4 | `inherited Create` inside a descendant's constructor | no row - it constructs the object already being built | OK (by design) |
| 5 | A class method or plain routine NAMED Create | no row - the member binding is not a constructor | OK |
| 6 | `LClass.Create` through a class-reference VARIABLE (`LClass: TFooClass`) | - | GAP - the static type is a metaclass, the class a runtime value |
| 7 | `X.Free`, `X.Destroy`, `FreeAndNil(X)` where the designator X has the STATIC type of the class (aliases followed; `Self.FFoo.Free`, `Items[i].Free` and the like resolve through `WithTargetTypeX`) | Destructions row, positioned on X's own name (FFoo, not Self) | OK |
| 8 | The release routines themselves | matched as RESOLVED routine symbols named `free`/`destroy`/`freeandnil` - TObject's, System.SysUtils' FreeAndNil, or a project's own; a same-named method on an unrelated type is no row | OK |
| 9 | A `TBar` instance freed through a `TBar`-typed variable (descendant) | no row for TFoo - its static type is TBar, the same rule row 3 applies to creation | OK (by design) |
| 10 | An instance freed through an ANCESTOR-typed variable (`var O: TObject; O := TFoo.Create; O.Free`) | - | GAP - static type is TObject; would need flow analysis |
| 11 | Ownership release (`TComponent` owner, `TObjectList` with OwnsObjects, interface refcount) | - | GAP - runtime facts, not in the source text at all |
| 12 | `inherited Destroy` inside the class's own destructor | no row - the parent node is nkInherited, not a member access | OK (by design) |
| 13 | `C := nil` after a Free | no row - an assignment (§7), not a release | OK |

`CanonTypeX` (alias links followed) was made public on `TPasSemaProject` for
row 7's comparison; it was private before because only overload typing
needed it.
