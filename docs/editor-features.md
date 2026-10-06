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
    falls back to the flat 59-word `DIRECTIVE_WORDS` list otherwise. Every
    directive the parser takes is a node - a procedural type's (`procedure
    stdcall`, `function: T; cdecl`), one before a routine header's `;` and
    one before an anonymous method's body included (0.60.0).

1.3 **Inactive-code greying** - tokens inside `$IFDEF`'d-out regions
    (`TPasPreprocessed.Skipped`) render `clGrayText`, checked before any
    other attribute. The `{$IFDEF}`/`{$ENDIF}` markers themselves stay
    normally colored (region boundary semantics), matching the IDE.

1.4 **Hover link rendering** - a `(from, to)` RAW-token range renders as a
    blue underlined link (all token kinds inside the range, including the
    dots of a qualified name). Set on ctrl+hover from `IdentAt`'s span.

1.5 **Semantic type coloring** (`TPasNavigator.SemanticTokens`) - the one
    color that does not come from the buffer's own lex/parse. After every
    analysis the host asks the navigator for the unit's identifier tokens
    with the KIND of the symbol each resolved to (`TPasSemanticToken`: raw
    token index, `TSemaSymbolKind`, IsDecl), and the highlighter paints an
    identifier that resolved to a type (`skType`, `skBuiltinType`) with the
    Type attribute - in a declaration slot, a cast, `TFoo.Create`,
    `SizeOf(TFoo)` alike, which is exactly what a syntax rule cannot tell
    from a variable. Identity is `SymbolAt`'s (declaration name from the
    symbol table, implementation header via `ImplHeaderSym`, otherwise
    RefMap/ExtRefMap), so what colors as a type is what Ctrl+Click takes
    to a type. Raw indices line up with the highlighter's own tokenization
    of the same text, so no position translation sits in between; includes
    are not covered. An unresolved identifier keeps its lexical color.

    Between an edit and the debounced re-analysis the marks are the LAST
    analysis's: aligned up to the edit point, drifting behind it for a few
    hundred ms. Kept rather than cleared, because clearing flickers every
    type name in the file on each keystroke. The demo's `cbTypeColor` combo
    picks the color (persisted as `TypeColor`), default Teal. Other kinds
    (fields, routines, constants...) are in the rows already; coloring them
    is a highlighter-side choice for later.

    pastree-lsp hand-off: `textDocument/semanticTokens/full` maps one row to
    one token; `IsDecl` becomes the `declaration` modifier.

## 2. Go-to-declaration (`source/PasTree.Sema.Nav.pas` + demo wiring)

Parity target: **ctrl+click on ANY identifier navigates to the place it is
declared**, exactly like the RAD Studio IDE. "Any" means all of:

**A unit that ships compiled only (v0.37.0).** When no `.pas` exists for a
unit anywhere on the paths, the analysis reads its `.dcu` and works on the
interface source PasTree generates from it (`docs/dcu-reader.md`). Every row
below then lands in that generated text: the target's `FilePath` is the
`.dcu` path, `Line`/`Col` are positions in the text `TPasSourceManager.
LoadFileTolerant` returns for it, and a host shows the tab read-only
(`TPasSourceManager.IsDcuPath`; the demo does). The IDE itself has nothing to
open there; this is one place the demo does more than the IDE, and the header
comment of the generated text says what it is and what it could not carry.

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
6. **Unit-file resolution** (`ResolveUnit`, rows 11-13): **pinned units**
   (a program's `in`-path once resolved, the host's `PinUnitFile` list - the
   .dproj's own units; they locate a unit for the WHOLE project, dcc
   semantics) -> `in`-path -> **unit aliases** -> `<dotted>.pas` against the
   **project dir** (dcc's implicit current directory), then the search paths
   in order, then the referring dir as a fallback -> **namespace prefixes**
   (`-NS` order) -> `<leaf>.pas` -> basename index. The project dir and the
   pins are what let a patched copy of a library unit inside the project
   shadow the original for every importer (0.31.0; pinned in
   `SemaProjectSmoke` "shadow/*").
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
| 6a | ...started FROM a method's qualified implementation header (`procedure TFoo.Bar;`), or from its class qualifier | the same - the header's name is answered structurally, overload-precisely, and the qualifier answers with the class | OK (0.39.1 - `ImplHeaderSym`; that header names no symbol, so `SymbolAt` used to decline it and Rename, Find References and the rest were all dead on the implementation side of every method) |
| 6b | A TYPE whose methods are implemented as `procedure TFoo.Bar;` - nested (`TOuter.TInner.Zap`), generic (`TBox<T>.Put`) and record methods included | declaration + every use + its name in every implementation header it qualifies, only the segment that names it | OK (0.56.0 - `ImplQualifierNodes`; the resolver binds no qualifier segment, so until then a class rename left every method implementation spelling the old name: E2003 on each) |
| 7 | Implicit `Result` | nothing - refused, no declaration site to rename | OK (by design, 3.3) |
| 8 | A compiler builtin (`Integer`, `Length`, `True`) | nothing - refused outright | OK (by design, 3.1) |
| 9 | A UNIT, from its own header name or from any `uses` item (any segment) | the header + every `uses` item project-wide, whole dotted spans | OK (3.8) |
| 10 | The FILE a renamed unit lives in | not renamed - the required name is HANDED BACK to the host | OK (by design, 3.8) |
| 10a | A program's or package's `X in '..\dir\X.pas'` naming that file | the file name inside the quotes, its directory kept; the line's preview carries both its edits | OK (0.87.0 - before, the path kept the old file name: F2613 once the host renamed the file, and in the IDE the project's entry for the unit named nothing; pastree-lsp patched it from the plan's line text) |
| 11 | A `uses` item spelled as a `-A` unit ALIAS | nothing - the whole unit rename is refused, named in the error | OK (by design, 3.8) |
| 12 | Anything declared in a LIBRARY source (RTL/VCL/third-party) | nothing - refused whole, naming the file | OK (by design, 3.9) |
| 13 | A property REDECLARED bare in descendants (`property Items;` promoting visibility, changing accessors or streaming specifiers - no type written), from any link | every declaration of the chain + every use bound to any of them; Find References shows the same set (the other links' declaration names are hits). A redeclaration WITH a type is a NEW property hiding the inherited one (dcc-probed 2026-09-09) - it and everything below it stay out | OK (0.21.0) |
| 13 | Anything whose declaration or ANY use sits in a read-only file | nothing - refused whole, naming the file | OK (by design, 3.9) |
| 13d | A DEFAULT array property (`property Cells[I: Integer]: TCell ...; default;`) used through brackets, `L[I]` - no name written | the declaration and the uses that WRITE the name; the bracket uses are Find References hits (`TPasRefHit.Implicit`, at the `[`) with nothing to rewrite | OK (0.76.0 - CrossType keys the use on the nkIndex; before, no search found one) |
| 13a | A component, handler or class a FORM FILE names (`object X: TC`, `OnClick = X`, `FocusControl = X`, `DataModule1.X`) | the form-file sites too, bound by TReader's rules | OK (0.59.0 - 3.9a) |
| 13b | A component whose handlers are named after it (`Button1Click` on Button1's OnClick), or whose caption reads its name | the handlers renamed with it everywhere, the caption follows - as the form designer does | OK (0.59.0 - 3.9a) |
| 13c | A published property or an enum value a form file spells; a binary form file | nothing - refused whole, naming the file and line | OK (by design, 3.9a) |
| 13e | A METHOD tied to others by name: a virtual slot, an interface method and its implementations, a hiding namesake calling it by a bare `inherited;` - from any of them | the whole family, each with its uses and form lines, listed in `AFamily`; refused whole for an overloaded name in the family, a slot whose root has no source, a member in a library | OK (0.86.0 - 3.9b) |
| 14 | Name-collision detection at an edit site | - | GAP (deliberate - see 3.5; form-file collisions ARE checked, 3.9a) |
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
    not a use). So the plan reaches past the reference list in exactly three
    structural ways, all language rules rather than heuristics: a
    parameter's counterpart in the peer header, paired by POSITION in the
    parameter list (never by name - the name is what is changing), the peer
    header's own routine name, and a type's name wherever it qualifies an
    implementation header (`ImplQualifierNodes` - identity from the routine
    scope's `StructSym`, read back outward through the declaring struct
    scopes, never from the text). Nothing else. The last two are what
    `FindReferences(..., AImplHeaders = True)` adds, which is how the plan
    takes them; a host shows them in a references list only when it asks -
    by default a form's class would list a row per event handler.

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

3.9a **FORM FILES** (0.59.0 - `PasTree.Dfm`, `PasTree.Sema.Dfm`,
    `FindFormSites`, `FindReferences(..., AFormFiles)`, `PlanRename`'s form
    edits; `tests/DfmSmoke.dpr`). A `.dfm`/`.fmx` names Pascal symbols and
    the RTL binds them at run time BY NAME only, so a rename that skipped one
    compiles and then fails when the form is created (a handler TReader
    cannot find is EReadError; a component whose field was renamed stays nil
    silently).

    - *Reading* is `System.Classes.TParser`, walked as ObjectTextToBinary
      walks it (`PasTree.Dfm`, a copy of its Convert* procedures that records
      positions instead of writing binary) - what counts as a form file is
      exactly what the RTL accepts. No round trip: the identifier bytes are
      edited in place. A binary form file is converted in memory, listed,
      and refused for a rename. Docs are cached by path + size + write time.
    - *Binding* is TReader's rules (`PasTree.Sema.Dfm`): `object X: TC` is
      the published field X of the LOOKUP ROOT's class - the form, or inside
      `inline F: TFrame1` the frame; a handler is a published method of the
      ROOT class, inline or not; `A.B.C` starts at a component of the lookup
      root, else at another module's root Name. Published means svPublished
      or svDefault (a TPersistent descendant compiles with $M+).
    - *References*: `FindFormSites` returns each site with what it IS
      (`TPasFormSiteKind`: component / class / handler / componentRef), the
      component it is on, the property it is the value of, and how it is
      reached (`TPasFormSiteVia`: own / inline / module - for a host whose
      forms a live designer holds, which propagates a rename differently
      along each). `FindReferences` lists them only when asked
      (`AFormFiles`): it reads every form file, and a caret highlight must
      not pay for that.
    - *Rename* takes them always and refuses whole (`SitesOf(ARename)`,
      `RenameRefusal`): a form file that may name the symbol but cannot be
      read or bound, a binary one, a published PROPERTY or an enum VALUE a
      form file spells (bound through a property's type, not resolved yet),
      a non-ASCII new name for a form file without a UTF-8 BOM, a member or
      component of the new name a streaming form already has.
    - *A component's rename carries along* what the form designer does when
      its Name changes (`CarriedBy`, `TPasCarriedRename` through the
      `PlanRename` overload with `ACarried`): each handler NAMED AFTER it on
      its own events - its name + the event's without "On" - renamed with it
      everywhere, and a `Caption`/`Text` reading exactly its old name
      (TControl.SetName's csSetCaption; an action's only without an `Action`
      link, as TContainedAction.SetName; `EditLabel.Caption` of a
      TLabeledEdit). A handler whose own rename would be refused keeps its
      name - it is bound by name wherever it is linked, so that never breaks.
      Each such edit writes its own `NewText`, which every plan's edits now
      carry.
    - `FormRoleOf` says where a symbol lives in the form files: what it is
      there, the class declaring it, and the form file whose ROOT is that
      class - the one a host's live designer holds it in.
    - `DescribeForm` (0.62.0) answers per FORM what the others answer per
      symbol: every object of one form file with its class and the published
      field its name fills, and every value naming a symbol - a handler, a
      component, a path into an inline frame or another module - bound by
      the same rules. A value that should name something and does not is
      listed unbound: an event whose method the root class lacks (EReadError
      when the form loads), a component path nothing answers. An inherited
      form lists its own file only; its ancestor's form is `FormRoleOf` of
      the ancestor class.

3.9b **A method's FAMILY** (0.86.0 - `RenameFamily`, `TPasRenameFamilyWhy`,
    the `AFamily` overload of `PlanRename`). Three ties by name make a
    rename of one method alone code that breaks, so the plan takes the
    others with it, each with its uses, implementation header and form
    lines, under the same new name:
    - the VMT slot (`rfwVirtual`): the method that introduced it and every
      `override` below - from any of them. One renamed alone is E2137.
    - an interface method and what implements it (`rfwInterface`): the
      class method the name finds from a class listing the interface or one
      EXTENDING it (dcc carries the base's methods into the extension, which
      Find Implementations does not walk), and from a class method, the
      interface methods it implements for its own class or a descendant
      listing one. One renamed alone is E2291.
    - a descendant's HIDING namesake that calls it by a bare `inherited;`
      (`rfwInherited`), both ways. That `inherited` names nothing and binds
      by the current method's name (12.1.2): with one of the two renamed it
      still compiles and calls nothing, or a grandparent's namesake - the
      one break no build reports. The client group's settings frames had
      it: a base frame's change handler, redeclared in a descendant frame
      that saves its parameters and calls `inherited;`, bound by name in
      both frames' form files (39 lines in 6 files, where a rename of the
      base alone planned 15 and silently stopped the descendant's controls
      reaching the base's handler).
    A worklist over methods of one name: each member is searched in turn.
    The ancestor's form line that binds a descendant's redeclaration and the
    ancestor's own method at once - a refusal for a rename of either alone
    (3.9a) - is a site of both when both are renamed (`SitesOf`'s
    `ATogether`). Refused whole, since the ties are matched by name as Find
    Overrides and Find Implementations match them: an overloaded name at any
    type of the family (they pair by signature), a slot whose root overrides
    a method this analysis has no source for, a member in a library or
    read-only file (an override of `TObject.Destroy` keeps the library's
    name) - each refusal names the member and its tie. Not reached: a
    method resolution clause (`procedure IBar.Baz = MyBaz;`), a delegated
    implementation (`implements`) - as in §5.


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
- a separator, then the two cursor-free define inventories (§10):
  `Find All > Defines` (`FindDefines`) and `Find All > Defines at cursor`
  (`DefinesAt`) - always enabled, no identity at the caret
- a separator, then the three `uses` checks (§12): `Find All > Unused Units`
  (the unit in the editor), `Find All > Unused Units in the Project` (every
  unit outside `LibraryPaths`) and `Find All > Units Nobody Uses` (§12.1)

`Implementations` and `Descendants` have no modifier and one answer each:
Descendants the whole transitive tree, Implementations the classes that
spell THIS interface's name (§5, §6). 0.24.0-0.24.1 put a Ctrl modifier on
both (`AIncludeIndirect`, "direct" plainly and "transitive" with Ctrl held);
0.25.0 took it out, because the direct Descendants answer was a flat list in
a page built to show a tree, and the transitive Implementations answer on a
base interface had no shape a list could show - the two questions it folded
together are Descendants on the interface and Implementations on the child.

Each entry keeps its own gating rule - the regrouping is presentation only. A
gated-out entry stays visible but disabled (the IDE greys out inapplicable
Refactor items the same way) so the submenu's shape never shifts with the
caret. Every command opens its own results page: `TFindRefTab.Kind`
(`stkRefs`, `stkRename`, `stkOverrides`, `stkImpls`, `stkDescendants`,
`stkAssigns`, `stkCreations`, `stkDestructions`, `stkDefines`,
`stkDefinesAt`, `stkUnused`, `stkUnusedProject`, `stkUnreferenced`) is part
of the page identity, so a repeated search refreshes
its own page and eight answers about one symbol never overwrite each other.

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
   `AncestorOfX`, following the SLOT rather than the text: an ancestor that
   does not declare the name is passed through (the slot is inherited across
   it, as the method is), one declaring it `override`/`message` is a link,
   one declaring it `virtual`/`dynamic` without `override` STARTED the slot
   and is the root (`reintroduce; virtual;` included - anything above it is
   a different slot this one hides), and an undecorated same-named
   declaration ends the climb below itself (no `override` can pass through
   it - E2170). So clicking an `override` anywhere down a chain answers for
   the whole chain, exactly like clicking the root does. (Until 0.39.1 the
   climb stopped at the first ancestor WITHOUT a same-named method, so an
   override whose virtual sat a few quiet ancestors up - a form overriding
   its base-form library's `DoSaveState` through intermediate forms that
   never touch it - reported itself as its own root, "1 in 1 units".)
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
| 6 | A `virtual`/`dynamic` method nothing overrides | its own single `pokRoot` row - the honest "nothing overrides this" | OK |
| 6a | A method with NONE of the chain directives | `MethodAt` declines - the command is not offered. It cannot be overridden (dcc rejects `override` against it; a same-named descendant declaration only hides it - row 5), so the only row a search could return is the declaration the caret is already on | OK (0.39.1 - it used to be offered on every method in the project and answer with that one row) |
| 7 | Started from a qualified implementation header (`procedure TFoo.Bar;`), or from anywhere inside the body | the same chain. `SymbolAt` answers for the header's own name directly since 0.39.1 (`ImplHeaderSym`); from inside the body `MethodAt` still takes the decl<->impl hop | OK |
| 8 | A method of a record, an interface, or a plain routine | `MethodAt` declines - the command is not offered | OK (by design) |
| 9 | An INTERFACE method's implementors (`TFoo = class(TObject, IBar)`) | - | not this search - a separate command, see §5 |
| 9a | The CLASSES below this method's class (no method question at all) | - | not this search either - Find Descendants, §6 |
| 10 | A class whose ancestor is written through a type ALIAS (`TB2 = TB;` then `class(TB2)`) | the same chain as through `TB` itself | OK (0.25.2 - the index keys on the type the alias names, `OvUnalias`; VirtualTrees declares every tree over `TVTBaseAncestor = TVTBaseAncestorVcl`) |
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
own heritage list, over the same reverse-heritage index §4 builds: every
class/`object` LISTING this interface, one hop.

| # | Declaration | Row | Status |
|---|-------------|-----|--------|
| 1 | The interface method itself | `pikRoot`, first; one row per overload the interface declares under that name | OK |
| 2 | A method of a class that lists the interface | `pikImplementor` | OK |
| 3 | A method of a class that lists a DESCENDANT interface (`class(TObject, IChild)` for a search on IBase) | no row | OK (by design, 0.25.0) - dcc does carry IBase's methods into IChild's implementors, but the interfaces below IBase are §6's axis and IChild's implementors are this search asked on IChild. 0.20.0-0.24.x walked the descendant interfaces too (0.24.0 behind a Ctrl modifier), and on a base interface with a hundred extending interfaces the answer had no shape a list could show |
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
same one hop stopped before the method: every class listing THIS interface.
Rows reuse `TPasImplHit`: `pikRoot` for the interface's declaration,
`pikImplementor` per class; `ViaTypeName` is `''` on every row here.

Not a row, by design: a class that gets the interface from its ANCESTOR
(`TBase = class(TObject, IBar)` then `TLeaf = class(TBase)`) - dcc treats
the ancestor as the implementor, and listing every descendant of every
implementor is §6's answer. Nor a class listing a DESCENDANT interface (row 3
above, 0.25.0; up to 0.24.x it was a row with `ViaTypeName` naming the
interface it wrote). GAPs shared with the method search: `implements`
delegation. An alias-named interface is reached since 0.25.2 (`OvUnalias`).

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
| 5 | A record, a helper, a non-type | `TypeAt` declines - the command is not offered | OK (by design) |
| 5a | A type ALIAS of a class or interface (`TVTBaseAncestor = TVTBaseAncestorVcl;`), at its declaration or where it is written | `TypeAt` answers the TYPE the alias names | OK (0.25.2, `OvUnalias`) |
| 6 | A descendant naming its ancestor through a type ALIAS | a row like any other | OK (0.25.2, see §4 row 10) |

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
| 2a | `TFooAlias.Create` where `TFooAlias = TFoo;` (VirtualTrees spells its base through such an alias) | Creations row on the alias name in the call | OK (0.25.2, `OvUnalias`) |
| 3 | `TBar.Create` for a descendant TBar | no row - that is a TBar; §6 says which those are | OK (by design) |
| 4 | `inherited Create` inside a descendant's constructor | no row - it constructs the object already being built | OK (by design) |
| 5 | A class method or plain routine NAMED Create | no row - the member binding is not a constructor | OK |
| 6 | `LClass.Create` through a class-reference VARIABLE (`LClass: TFooClass`) | - | GAP - the static type is a metaclass, the class a runtime value |
| 7 | `X.Free`, `X.Destroy`, `FreeAndNil(X)` where the designator X has the STATIC type of the class (aliases followed; `Self.FFoo.Free`, `Items[i].Free` and the like resolve through `WithTargetTypeX`) | Destructions row, positioned on X's own name (FFoo, not Self) | OK |
| 8 | The release routines themselves | matched as RESOLVED routine symbols named `free`/`destroy`/`freeandnil` - TObject's, System.SysUtils' FreeAndNil, or a project's own; a same-named method on an unrelated type is no row | OK |
| 8a | `X.Release` on a form - the call bound to `TCustomForm.Release` (Vcl.Forms) or `TCommonCustomForm.Release` (FMX.Forms), which frees the form once its queued CM_RELEASE is handled; the idiomatic way to free a form | Destructions row, like row 7 | OK (0.50.3) |
| 8b | A `Release` bound to anything else - a lock, a pool, a class not derived from a form, or a form class declaring its own `Release` | no row - matched by SYMBOL, never by name: those free nothing | OK (0.50.3) |
| 8c | `Action := caFree` in a form's OnClose, then `Close` | - | GAP - whether Close frees is decided at run time |
| 9 | A `TBar` instance freed through a `TBar`-typed variable (descendant) | no row for TFoo - its static type is TBar, the same rule row 3 applies to creation | OK (by design) |
| 10 | An instance freed through an ANCESTOR-typed variable (`var O: TObject; O := TFoo.Create; O.Free`) | - | GAP - static type is TObject; would need flow analysis |
| 11 | Ownership release (`TComponent` owner, `TObjectList` with OwnsObjects, interface refcount) | - | GAP - runtime facts, not in the source text at all |
| 12 | `inherited Destroy` inside the class's own destructor | no row - the parent node is nkInherited, not a member access | OK (by design) |
| 13 | `C := nil` after a Free | no row - an assignment (§7), not a release | OK |

`CanonTypeX` (alias links followed) was made public on `TPasSemaProject` for
row 7's comparison; it was private before because only overload typing
needed it.

## 9. Find References / Go to Definition for conditional symbols (`TPasNavigator.DefineAt`/`FindDefineReferences`/`GotoDefine` + demo wiring)

Status: IMPLEMENTED (PasTree 0.27.0) - `DefineAt`, `FindDefineReferences`,
`GotoDefine`, `IsProjectDefined` in `source/PasTree.Sema.Nav.pas`, the
`DefineRefs` record in `source/PasTree.Preprocessor.pas`, wired into the
demo's Find References command and ctrl+click, regression-covered by
`tests/SemaNavSmoke.dpr` (fixture `NavDef` + `NavDef.inc`).

The FOURTH identity next to symbol / unit / builtin (§2.1): the NAME in
`$DEFINE X`, `$UNDEF X`, `$IFDEF X`, `$IFNDEF X` and `Defined(X)` inside a
`$IF` / `$ELSEIF`. A conditional symbol has no symbol-table entry, no AST
node and no owning unit - a `$DEFINE` is unit-local, a `.dproj` or platform
define is global, and one name is routinely both - so, like a builtin, the
name is the only identity. Everything reads the preprocessor's own record,
never the text: `TPasPreprocessed.DefineRefs` lists every mention the
preprocessor walked, ACTIVE OR NOT, with the name's span, its kind and
whether the directive sat in live code. It is retained across `DemoteText`
(it is not text), so a project-wide search tests names without rehydrating
closed units and rehydrates only for the rows it reports.

| # | Shape | Row / target | Status |
|---|-------|--------------|--------|
| 1 | `{$DEFINE X}` / `{$UNDEF X}` | a row each (they ARE references; a name may have several sites or none), positioned on the name | OK |
| 2 | `{$IFDEF X}` / `{$IFNDEF x}` | row; comparison is case-insensitive as dcc's is; the row keeps the spelling as written | OK |
| 3 | `Defined(X)` in `$IF` / `$ELSEIF`, every occurrence - `Defined(A) and Defined(B)` lists B even when A is off and dcc never evaluated B | row (a tree walk in `PasTree.CondEval`, not a by-product of evaluation) | OK |
| 4 | A directive inside a DEAD branch (`{$IFNDEF X} {$DEFINE Y} {$ENDIF}` with X on) | row, `Active = False`; the demo prefixes it `[inactive]` | OK |
| 5 | A directive inside an include | row in the `.inc`; an include shared by N units produces one row, not N (collapsed by file/line/col, active if any including unit reached it) | OK |
| 6 | Go to Definition (ctrl+click on the name) | the nearest PRECEDING active `$DEFINE X` in the same model, in preprocessing order (an include's directives count where its `$I` sat) | OK |
| 7 | A project / platform define (`WIN32`, `MSWINDOWS`, a `.dproj` `DCC_Define`) | rows for every mention; Go to Definition lands on the MAIN MODULE's header (the program/library/package name) - the project is where it comes from, as System.pas is for a builtin; `IsProjectDefined` tells the two apart, the demo's caption says `[project define]`. No target only in an analysis without a main module (a bare directory of units) | OK (0.27.2) |
| 8 | `{$IFOPT X+}`, switch directives | - | not a conditional symbol, not a row |
| 9 | The directive WORD (`IFDEF`, `DEFINE`) under the cursor | `DefineAt` declines - only the name is the symbol | OK (by design) |
| 10 | Ctrl+click on a directive inside an opened `.inc` | - | GAP - an include has no model (the README's To-do) |
| 11 | Rename of a conditional symbol | - | not offered: the `.dproj` and the command line own part of the identity |

`DefineAt` accepts the caret one past the name's end, as `IdentAt` does for
an identifier; two past declines. It also hands back the directive's raw
token, which is the whole `{$...}` - the range the demo underlines.

### pastree-lsp hand-off

Not a new protocol surface. The server's `HandleReferences`,
`HandleDefinition` and the rename block-check already try the identities in
order (`UnitAt`, `SymbolAt`, `BuiltinNameAt`); this is one more `else if`
after `BuiltinNameAt` in each:

- references: `DefineAt` -> `FindDefineReferences`, each `TPasDefineHit.Hit`
  a `TPasRefHit` as before; `Kind`/`Active` are extra and may be dropped or
  carried into the item's context.
- definition: `DefineAt` -> `GotoDefine` (a single target, possibly none;
  `IsProjectDefined` distinguishes "project define" from "never defined" if
  the server wants to say so).
- rename: `DefineAt` true -> refuse, the same way a builtin is refused.

`cMinPasTreeVersion` moves to 0.27.0.

## 10. Find All Defines / Defines at cursor (`TPasNavigator.FindDefines`/`DefinesAt` + demo wiring)

Status: IMPLEMENTED (PasTree 0.28.0) - `FindDefines`, `DefinesAt` and the
`TPasDefineSite` row in `source/PasTree.Sema.Nav.pas`,
`TPasSemaProject.BaseDefineNames` and `TPasDefines.Names` underneath, wired
into the demo as `Find All > Defines` and `Find All > Defines at cursor`,
regression-covered by `tests/SemaNavSmoke.dpr` (fixtures `NavDef` +
`NavDef.inc`, and the `NavMain` project for the main-module landing).

Two inventories of the fourth identity (§9) that need NO identity at the
caret, so both commands are always offered. Both read the preprocessor's
retained `DefineRefs` (never the text) plus the project's base define set,
which `BaseDefineNames` splits into the `.dproj` / command-line names and
the platform's predefined ones.

**`FindDefines`** is the project-wide list: every `$DEFINE X` site in every
loaded model, live or dead (`Active`), sorted by file/line/col with a shared
include's copies collapsed as `FindDefineReferences` does - then one row per
project define, then one per platform define, each sorted by name. A row
is a `TPasDefineSite`: the `TPasRefHit`, the name and an origin (`doUnit` /
`doProject` / `doPlatform`). A unit row is positioned on the name inside its
directive, as a §9 row is; a project or platform row has no source site, so
its hit points at the MAIN MODULE's header (where `GotoDefine` sends a
project define, §9 row 7) with `Snippet` = the name itself and `HiFrom` /
`HiTo` spanning it, so a host shows it like any other row. In an analysis
with no main module the hit's `FilePath` is `''` and `Line`/`Col` are 0 - a
row to read, nothing to jump to (the demo ignores a double-click on it).

**`DefinesAt(AMid, ALine, ACol)`** is the set IN EFFECT at the cursor of a
model's main file - what an `$IFDEF` written there would see. It replays the
model's `DefineRefs` in preprocessing order up to the first main-file
directive past the cursor (an include's directives count where its `$I`
sat): a live `$DEFINE X` puts X in effect at that site, a live `$UNDEF X`
takes it out AND cancels the project / platform define of that name; dead
directives change nothing. One row per name, the LAST definition winning, so
a name defined by both the project and the unit is one row, the unit's - the
nearest definition, as `GotoDefine` lands. Unit rows first (by file), then
project, then platform names. `AMid < 0` (the file has no model) returns the
base set alone, so a host can offer the command in every editor.

| # | Shape | Row | Status |
|---|-------|-----|--------|
| 1 | `{$DEFINE X}` in a unit | `FindDefines`: a row per site; `DefinesAt`: the last one before the cursor | OK |
| 2 | `{$DEFINE X}` in an include | row in the `.inc`, once however many units include it | OK |
| 3 | `{$DEFINE X}` in a dead branch | `FindDefines` lists it `Active = False` (demo: `[inactive]`); `DefinesAt` never | OK |
| 4 | `{$UNDEF X}` before the cursor | not a row anywhere; takes X out of `DefinesAt`, a project define too | OK |
| 5 | A `.dproj` / command-line define | `doProject` row, main-module header, once | OK |
| 6 | A platform define (`MSWINDOWS`, `CPUX64`, `VERnnn`...) | `doPlatform` row, same shape | OK |
| 7 | A name both project- and unit-defined | `FindDefines`: both rows (they are two facts); `DefinesAt`: the unit's alone | OK |
| 8 | Cursor in an opened `.inc` | `DefinesAt` gets `AMid < 0` - base set only (an include has no model, the README's To-do) | GAP, as §9 row 10 |
| 9 | Defines that a USED unit made | - | none: a `$DEFINE` is unit-local, dcc's rule |

The demo shows `Find All > Defines` in the grouped Find-References shape -
files as groups, then `Project defines [n]` and `Platform defines [n]` as
two groups of their own (`PopulateFindRefTab` took an `AGroupKeys`
parameter for this) - and `Defines at cursor` as a FLAT list, one row per
name prefixed with the defining file and line (`AFlat`). Each command has
exactly one page (`SymSym` sentinels -4 / -5), refreshed on every call.

### pastree-lsp hand-off

No protocol surface maps onto "list all defines" directly; two candidates:

- `workspace/symbol` with a query the server recognizes (`$DEFINE` or
  `define:`) answered from `FindDefines`, each row a `SymbolInformation`
  whose location is the site (project / platform rows: the main-module
  header, or omitted when `FilePath = ''`) - cheap and every client shows it.
- A custom request (`pastree/definesAt` with a text document position ->
  `DefinesAt`) for the at-cursor set, since no standard request carries a
  position and returns an inventory; a code-lens or hover on a `$IFDEF` line
  could surface the same answer without a new request.

`TPasSemaProject.BaseDefineNames` is public so a server can also answer
"what does the project define" without a navigator, e.g. in its
`initialize` log. `cMinPasTreeVersion` moves to 0.28.0 only if one of these
is taken up; nothing in the existing handlers changes.

## 11. Go To - the module and project outline picker (`PasTree.Outline.PasModuleOutline`, `TPasNavigator.ProjectOutline` + demo `PasTreeDemo.GoToPicker`)

Status: IMPLEMENTED (PasTree 0.30.0; project tab and no keyword rows in
0.32.0) - `source/PasTree.Outline.pas` is the module list,
`TPasNavigator.ProjectOutline` in `source/PasTree.Sema.Nav.pas` the project
list, `demo/PasTreeDemo.GoToPicker.pas` the dialog, Ctrl+G / `Go To...` in
the source popup menu the wiring.

What the RAD Studio "Navigator - Go To" dialog does for one module: every
declaration and every routine body, in SOURCE ORDER, plus the landmarks a
reader steers by; type to filter, Enter or a double-click jumps. A filter
that is nothing but digits adds a `line N` row on top, so the same box is
go-to-line as well. A second tab widens the same box to the whole project
(11.3).

### 11.1 The outline (`PasModuleOutline(ATree)`)

AST only, no semantics: it reads the parse tree of one module and nothing
else, so it works on a module the resolver has not finished, on a module
with parse errors (the declarations around the damaged one are listed), and
it costs one walk of the tree. Consequences a host should know:

- a declaration behind an inactive `$IFDEF` is absent - the preprocessor
  never handed it to the parser;
- a routine's declaration and its body are TWO rows (`IsImpl` tells them
  apart), paired by nothing but their names - the semantic pairing stays
  `GotoImplementation`'s job;
- a declaration that arrived through an `$I` include reports the include
  file's path and line (`FilePath`/`Line`/`Col` are of the NAME, in whatever
  file it sits) - the same landing ctrl+click gives.

Rows, in the order they appear in the source:

| Kind | Rows | Head / Owner / Name / Detail |
|------|------|------------------------------|
| `okModule` | the `unit`/`program`/`library`/`package` header | `unit` / - / `Foo.Bar` / - |
| `okSection` | `interface`, `implementation`, `initialization`, `finalization`, a program's main `begin` | the word / - / - / - |
| `okUses` | each uses (package: requires/contains) clause | `uses` / - / - / - |
| `okInclude` | each `$I` / `$INCLUDE` directive (0.33.0), positioned on the directive in the INCLUDER and slotted before the first row the included text produces; listed even when the file did not load | `include` / - / the name as written / `(not found)` when it did not load |
| `okType` | every type declaration, nested ones included | `type` / `TOuter` / `TList<T>` / `= class`, `= record`, `= interface`, `= class helper`, `= type Integer`, `= array of Byte`... |
| `okVar` | one row PER NAME of `A, B: T`; fields (`field`), `class var`, module `var`/`threadvar`; variant-part fields too | head / `TFoo` / `FA` / `: Integer` |
| `okConst` | `const`/`resourcestring`, class constants | head / owner / `MaxN` / `= 10` or `: T` when typed |
| `okProperty` | `property` / `class property`, bare redeclarations included | head / `TFoo` / `Items` / `[I: Integer]: Integer` |
| `okRoutine` | headers in structs and at module level; `class` methods carry `class ` in the head; an implementation header's dotted name yields the owner (`TOuter.TInner`, `TList<T>`) | `class function` / `TShape` / `Kind` / `(A: X): Y` |

Not listed on purpose: enumeration values (they drown the list they sit
in), routine-local declarations and nested routines (the body is one row),
parameters, method-resolution clauses, visibility words, attributes. Since
0.32.0 the module-level `type`/`const`/`var` words are not rows either: a
reader steers by the sections and the declarations, and a `var` word between
every group of them was noise in a filtered list (the enum member
`okKeyword` is gone). `Detail` collapses whitespace and cuts at 80
characters.

Every row also carries `UnitId`, `Sym` and `UnitName`, all unset here (-1,
-1, `''`) - they are the project list's fields (11.3), present so both lists
are one record.

### 11.2 The dialog (demo)

- Owner-drawn rows: head word and detail in the quiet colour, the name in
  the text colour with the matched letters in bold, then `(declaration;
  interface section)` for a routine header, `(interface section)` for any
  other declaration, nothing for an implementation row or a landmark.
- Filter = case-insensitive substring over the name column (`Owner.Name`, or
  the head word for a landmark - so `impl` finds `implementation`). Digits
  only: `line N` first (clamped to the module's line count), then the rows
  whose names contain the digits.
- A right-aligned `:N` line column on rows that carry a position (the module tab; project rows have none until chosen); the row text is clipped short of it.
- Kind boxes: `All` (the default, one set test per row) or a subset of
  Types, Vars / Fields, Consts, Routines, Properties - ticking a kind
  unticks All, ticking All clears the kinds, unticking the last kind falls
  back to All; landmarks always show. A status bar counts rows shown of rows
  listed on the current tab. Size and boxes persist in the settings file
  (`GoToWidth`, `GoToHeight`, `GoToKinds`; bit 32 = All).
- The filter box sits above the tabs: one box, both lists.
- On open, the last row at or above the caret in the module's own file is
  selected (rows from includes carry other line numbers and do not compete),
  so Ctrl+G with an empty box answers "where am I".
- Up/Down/PgUp/PgDn move the list while the caret stays in the filter box;
  Ctrl+Tab flips between the two tabs with the filter text kept.
- The list box is virtual (`lbVirtualOwnerDraw`): a row is painted on
  demand from the filtered row array, so a project's tens of thousands of
  rows cost nothing to list and each keystroke is one filter pass.
- The outline is read off the ANALYZED tree of the tab's file (rehydrated
  on demand), under the same `FAnalyzing`/`FNav` guard as every other
  reader - positions refer to the source as analyzed, like ctrl+click.

### 11.3 The project tab (`TPasNavigator.ProjectOutline(AMids)`)

The dialog's second tab, named after the project file, lists every
declaration of every project unit: what the module tab shows for one file,
for all of them at once, filtered by the same box and the same kind boxes.

The list is built from the RETAINED symbol table, never from text - that is
the design decision the tab rests on. A closed unit's text layer is gone
(`DemoteClosedUnits`, `docs/incremental-analysis.md`); reading positions or
signatures off it would mean re-preprocessing hundreds of units on Ctrl+G
and creeping the memory that demotion freed. So a project row has:

- `Kind`/`Head` from the symbol kind (`type`; `var`; `field`; `const`;
  `property`) and, for a routine, from `TPasSemaModel.RoutineHead`
  (`procedure`, `function`, `constructor`, `destructor`, `operator`; the
  `class` prefix is NOT known without text, so a class method reads as a
  plain `function`);
- `Owner` = the enclosing struct chain off the scope's `StructSym`
  (`TOuter.TInner`); `Name` = the symbol's spelling (a generic type without
  its `<T>`);
- `Section` = `osInterface` or `osImplementation` from the root scope the
  declaration sits under;
- `Detail` = what the retained type descriptors say and no more (0.39.2):
  the resolved type's name after `: ` for a var, field, property, typed
  constant or function result (generic arguments included), `= class` /
  `= record` / `= interface` for a struct type; no parameters and no
  constant values, which are text; `Line = Col = 0`, `FilePath` = the
  unit's MAIN file;
- `UnitId`, `Sym` = the model and symbol index; `UnitName` = the file's
  base name, painted after the name so the row says where it is from.

Each model opens with two kinds of landmark row (0.33.0), both `Sym = -1`:
its header (`okModule`; `unit`/`program`/`library`/`package` by the root
node kind, named after the FILE since the header's own spelling is text;
landing = `UnitHeaderTarget(UnitId)`, the name in the header) and one row per
`$I`/`$INCLUDE` directive (`okInclude`; `Node` = the index into
`TPasPreprocessed.IncludeRefs`, `(not found)` in `Detail` for one that did
not load; landing = `IncludeSiteTarget(UnitId, Node)`, the directive in the
includer). `IncludeRefs` is new in 0.33.0: the preprocessor records every
directive site (includer file, offset, the name as written, the resolved
path, the included file's id or -1, and the Visible index its text starts
at) and keeps it through `DemoteText` like `DefineRefs`, which is what lets
the project list show includes without text.

The landing is `DeclHit(UnitId, Sym)` when a declaration row is chosen - the same call
Find References pins its declaration row with - which rehydrates that ONE
unit. The dialog takes the resolver as a callback (`TGoToResolve`) so the
picker stays a presentation unit; a declaration that cannot be placed keeps
the dialog open rather than landing somewhere else.

Listed: symbols of kind type/var/field/const/routine/property whose scope
chain (through struct and generic-parameter scopes) ends in the unit's
interface or implementation scope. Not listed: parameters, locals, nested
routines, enumeration values, generic parameters, labels, unit references,
builtins - and no landmarks, which are one module's shape. A routine is ONE
row, its declaration (the interface header, or the implementation header of
an implementation-only routine); `GotoImplementation` takes it from there.

Model order is `AMids` order (the demo passes its project tree's files that
have a model - library units reached through the search path are not project
files); within a model, symbol-table order, which is collection order. The
demo asks for the list lazily, on the first switch to the tab, and holds it
for the dialog's lifetime; no `line N` row on this tab.

### pastree-lsp hand-off

`textDocument/documentSymbol` is this list almost one-to-one:
`PasModuleOutline` on the document's model tree, each `okType`/`okVar`/
`okConst`/`okProperty`/`okRoutine` row a `SymbolInformation` (flat form -
the order and the `Owner` prefix give the client all it shows; the
hierarchical `DocumentSymbol` form needs a range per struct, which the
`nkTypeDecl` node's span provides if wanted). Landmarks (`okSection`,
`okUses`) have no `SymbolKind`; skip them or map `okModule` to `Module`.
Rows whose `FilePath` is not the document's own (an include) are dropped for
`documentSymbol`, which is per-document. `cMinPasTreeVersion` moves to
0.30.0 when this is taken up; 0.32.0 removed `okKeyword` from the enum, so a
server mapping the kinds must be built against 0.32.0 or later.

`workspace/symbol` is `ProjectOutline` over every model the server counts
as the workspace (the project files, or all models for an RTL-inclusive
search), filtered by the query the client sends, each row a
`SymbolInformation` whose `location` comes from `DeclHit(UnitId, Sym)` -
resolve it only for the rows returned (the protocol caps the result, so a
few hundred `DeclHit` calls, not one per declaration), and the
`containerName` is `Owner` or, when empty, `UnitName`.

## 12. Unused Units (`PasTree.Sema.Lint.FindUnusedUses` + demo wiring)

Status: IMPLEMENTED (PasTree 0.93.0) - `FindUnusedUses(ANav, AMids)` and
the `TPasUnusedUse` row in `source/PasTree.Sema.Lint.pas`, wired into the
demo as `Find All > Unused Units` (the unit in the editor) and `Find All >
Unused Units in the Project` (every model whose file is not under the
navigator's `LibraryPaths`, now public as `IsUnderLibraryPath`),
regression-covered by `tests/SemaNavSmoke.dpr` (`TestUnusedUses`), and
headless as `tools/PasTreeSemaProject <x.dproj> -dproj -unused`.

The rule is pastree-mcp's `lint unused-uses`, ported to one analysis: an
entry of a unit's `uses` none of whose names the unit uses. A name counts
for the unit listing it when dcc needs that unit in scope to bind it - a
unit-level declaration of its interface, an enum value, a helper's member.
A member reached through a value or a type (`List.Add`, `TFoo.Create`) does
not: dcc finds members wherever the type came from. Also counted: the
qualifier of `Unit.Name`; a class or a component link the unit's form file
(`.dfm`/`.fmx`) names, the unit of every ANCESTOR of such a class, and of
every component of a form the form inherits, with its ancestors (0.93.3,
0.93.4: dcc needs none of them, but the IDE's designer puts each back into
`uses` when it saves the form - System.ImageList for a TImageList,
System.Actions for a TActionList, the unit of a component that only the
base form's file names); a name bound through an alias of another
unit, or a name of the interface bound to a unit of the implementation
`uses` - every listed unit declaring that name is credited. A program, a
library or a package is not checked (its `uses` is its contents), nor an
entry whose unit did not resolve.

A unit an inline routine needs is used too. dcc expands a call of a routine
marked `inline` only when the CALLER's `uses` names every unit the routine
needs - otherwise the call compiles as a plain one and dcc says `H2443
Inline function 'X' has not been expanded because unit 'Y' is not specified
in USES list`: no error, but the code changes, so removing `Y` is not free
(the demo's own `System.UITypes`, which `MessageDlg`'s expansion needs, was
the case that showed it). Probed on dcc64 37.0, what the routine needs is
every unit of a symbol its declaration or body binds - a routine, a
variable, a typed or a string constant, a type, a member reached through a
value (`GetY.V`), its implementation `uses` alike - plus the units of those
symbols' declared types (`O := GetY` needs the unit of GetY's result type,
though the body names nothing of it), plus what an inline routine it calls
needs (nested expansion), a property read through an inline getter
included. An enum value, an ordinal constant, `SizeOf` and a cast of a
constant fold into the code and need nothing; the check leaves out only
the enum value and keeps the rest, so it errs toward keeping a unit, never
toward calling a needed one unused. The unit must be named by the caller
itself: one its `uses` reaches through another unit does not do. The
routine's flag is `sfInline`, stamped in Phase 1 like `sfVarArgs` (a
library model is usually text-demoted when asked); the body is found by
`TPasNavigator.RoutineImplNode`, which hydrates the declaring model - only
for a unit with an entry still unused, and once per routine.

What the index cannot decide is said on the row (`Doubts`), never decided:

- a name bound to nothing that the listed unit declares;
- a branch not compiled in this configuration naming the unit or a name of
  it (the demo analyzes one configuration; pastree-mcp weighs every
  analysis of a group);
- a routine called here that the listed unit declares too - dcc picks among
  the overloads of every unit in scope, and PasTree's pick may not be its;
- the initialization, finalization or resource the removal leaves out of
  the program: the units the program no longer reaches once the edge is
  gone (a unit can be in `uses` only for what its initialization
  registers). With no program in the analysis, the listed unit's own
  initialization alone is said.

The demo shows the rows in the grouped Find-References shape, one per entry,
the unit name highlighted in its `uses` line, a doubt appended after
`<- but`. The rows come sorted by the listing file's name (its path
breaking a tie, so one file's rows stay one group), then by the unused
unit's name. On this repository's demo project it gave the same rows as
pastree-mcp's `lint unused-uses` before the inline rule, and the same less
`System.UITypes` after it; pastree-mcp's rule does not know inline
expansion yet (it can call `FindUnusedUses`, or port `InlineDeps`).

### 12.1 Units Nobody Uses (`FindUnreferencedUnits`)

The unit-level question the entry-level one leads to: which project units
the build would no longer take in once every unused `uses` entry is gone.
The program's own `uses` is judged too (the IDE writes every unit of a
project into the `.dpr`, so "the program lists it" says nothing): an entry
there is a use only when the program's code names something of the unit -
`Application.CreateForm(TfrmMain, ...)` does. Every unused entry with no
doubt is taken out of the uses graph (an entry with one - a dead branch
naming the unit, a name bound to nothing - stays, the safe side), and what
the program no longer reaches from its root is the answer: a unit used only
by another such unit drops with it (a chain). A package is not judged (its
`contains` is never optional). With no program in the analysis (a
directory of units) there is nothing to reach from, and the answer is the
literal one: the units no other unit lists and uses, not repeated - else
every unit under a top one would drop with it.

A row is the unit's header, who still lists it, by file name with its
extension (`Project.dpr (no name of it used)`, `Old.pas (itself
unreferenced)`) and, for a unit with initialization or
finalization code or a resource, the doubt that it may be listed for what
that registers - such a unit is in no one's `uses` for its names. Rows come
sorted by unit name (case-insensitive, the path breaking a tie), the
listers in each row by file name. The demo shows it as a flat page, the
file in front of each row. On this
repository's demo project the answer is empty.

### 12.2 `loHideGlobalInit`

Both functions take `AOptions: TPasLintOptions` (default `[]`, the answers
above). With `loHideGlobalInit` a unit whose initialization reaches OUTSIDE
itself is not offered at all - a host that removes rows (pastree-lsp's
Remove) should not be handed one, and a doubt is too easy to click past:

- "outside" is a binding, in the `initialization` section or in the body
  of any routine of the unit it calls (to any depth), to a routine or a
  variable at another unit's unit level, or to a member of another unit's
  type named through the type - a class method, class var or class property
  (`RegisterClass(...)`, `Application.Title := ...`,
  `TPicture.RegisterFileFormat(...)`; no symbol flag marks `class`, so the
  qualifier being a type is the test); a constructor (`FList :=
  TList.Create`), a type, a constant, or a member reached through the unit's
  own variable (`FList.Add`) keeps to the unit;
- FindUnusedUses leaves out an entry naming such a unit - even when the
  program still reaches it another way, since it is listed for what it
  registers - and an entry whose removal would take one out of the program
  (a unit only it brings in);
- FindUnreferencedUnits treats such a unit as kept - the entries naming it
  are not dead edges, and a unit nobody uses that is the only path to one is
  kept too - and what a kept unit really uses stays reached with it.

Without a program in the analysis only the listed unit's own initialization
is judged. SemaNavSmoke: TestLintGlobalInit.

### pastree-lsp hand-off

A diagnostic per row (hint severity, `DiagnosticTag.Unnecessary` greys the
entry out) or a code action "remove unused unit" - the row's range is the
entry's name; a row with `Doubts` should not offer the quick fix, or offer
it with the doubt in its title.
