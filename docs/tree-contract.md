# The tree contract

What a consumer may read from a PasTree tree, and from where. A node is a
kind, a span over the preprocessor's visible stream, an `Aux`, flags and
three links - no text (`source/PasTree.Ast.pas`). Every fact a consumer needs
comes from one of four places, and this document says which. It is checked,
not just written: the own-token table in `source/PasTree.Ast.Check.pas`
(`OWN_RULE_TEXT`) classifies every token every node owns, and the structural
printer (`source/PasTree.Printer.pas`) regenerates the source from these
four places alone and is compared with the original (see "How it is
checked").

## 1. The shape: kind, Aux, flags, child order

Every keyword and punctuation token a node owns is DERIVED - it follows from
the node's kind, its `Aux`, its flags and the order of its children, so a
consumer never needs to read it. The own-token table lists them per kind
(class `derived`); the kind comments in `PasTree.Ast.pas` say what `Aux` and
the flags mean. The expression and statement kinds read as follows (`c0`,
`c1`, ... the children in order; `[ ]` optional):

| Kind | Reads as |
|---|---|
| nkUnaryOp | the operator (see 3), `c0` |
| nkBinaryOp | `c0` operator `c1`; nfNegated: `c0 not in c1`, `c0 is not c1` |
| nkParen | `( c0 )` |
| nkCall | `c0 ( c1, c2, ... )`; a trailing comma leaves an nkMissing last |
| nkFormattedArg | `c0 : c1 [: c2]` |
| nkIndex | `c0 [ c1, ... ]` |
| nkMember | `c0 . c1` |
| nkDeref | `c0 ^` |
| nkTypeArgs | `c0 < c1, ... >` |
| nkSetCtor | `[ c0, ... ]` |
| nkRange | `c0 .. c1` |
| nkInlineIf | `if c0 then c1 else c2` |
| nkInherited | `inherited [c0]` |
| nkAnonMethod | `procedure` / `function` (a result-type child present), [nkParams], [`:` result type], nkDirective..., nkRoutineBody |
| nkNamedArg | `c0 := c1` |
| nkBlock | its statements, `;` between; `begin ... end` but where it stands for a list: the root of a statement parse, a try's, finally's or repeat's statements, an except part's catch-all (none), a case's or an except part's last child after handlers (`else ...`), a program's main block (`begin`, the `end` is the root's) |
| nkAssign | `c0 := c1` |
| nkExprStmt | `c0` |
| nkIfStmt | `if c0 then c1 [else c2]` |
| nkCaseStmt | `case c0 of` selectors (nkCaseSel `labels : statement`), [else nkBlock] `end` |
| nkForStmt | `for c0 := c1 to c2 do c3`; Aux 1: `downto`; `c0` an nkIdent or an nkInlineVar counter |
| nkForInStmt | `for c0 in c1 do c2` |
| nkWhileStmt | `while c0 do c1` |
| nkRepeatStmt | `repeat c0 until c1` |
| nkWithStmt | `with c0, ... do` last child |
| nkGotoStmt, nkLabeledStmt | `goto c0`; `c0 : c1` - the label c0 is an nkIdent, or an nkIntLit for a numeric one (a name label is bound by the resolver, a numeric one is not) |
| nkTryStmt | `try c0` then nkFinallyPart (`finally c0`) or nkExceptPart (`except` handlers, then the `else` block if any, or a catch-all block - `except else S` is that block too, 18.1.1), `end` |
| nkExceptOn | `on [c0 :] type do statement` - three children: the name first |
| nkRaiseStmt | `raise [c0 [at c1]]` |
| nkInlineVar | `var` names (nfName), [`:` type], [`:=` value when Aux is 1] |
| nkInlineConst | `const` name (nfName), [`:` type], `=` value |

The declaration kinds read as follows. Where a list of names ends is marked
on the names themselves (nfName), never by the separators after them; "a
type reference" is an nkIdent, nkMember or nkTypeArgs.

| Kind | Reads as |
|---|---|
| nkUnit | `unit c0` [hints: nkDirective...] `;` interface, implementation, [initialization], [finalization] `end.` |
| nkProgram, nkLibrary | `program` / `library c0` [nkProgramParams] `;` [uses] declarations [main nkBlock] `end.` |
| nkProgramParams | `( c0, ... )` - each a name that declares and refers to nothing; a library's is a parse error |
| nkPackage | `package c0 ;` its requires / contains clauses `end.` |
| nkUsesClause | `uses c0, ... ;` - in a package `requires` (Aux 1) or `contains` |
| nkUsesItem | `c0 [in c1]` |
| nkInterfaceSec, nkImplementationSec | `interface` / `implementation` [uses] declarations |
| nkInitSec, nkFinalSec | `initialization` (or a unit's legacy `begin`, see 3) / `finalization` statements, `;` between |
| nkExportsClause | `exports c0, ... ;` |
| nkExportsItem | the name (qualified), [nkParams], [`index` value - nfExtIndex], [`name` value - nfExtName], [`resident` - nfResident on the item]; dcc takes them in that order, each once (E2029 otherwise: a parse diagnostic here, flagged all the same) |
| nkTypeSec | `type` then each nkTypeDecl followed by `;` |
| nkConstSec | the head word (see 3), each nkConstDecl followed by `;` |
| nkVarSec | the head word (see 3) - in a struct body `var`, or `threadvar` (nfThreadvar, see 5) - each nkVarDecl followed by `;` |
| nkLabelSec | `label` labels `, ... ;` - each an nkIdent or an nkIntLit |
| nkTypeDecl | [attributes] name [nkGenericParams] `=` [`type` when Aux is 1] type [hints] |
| nkConstDecl | [attributes] name [`: type` - two children after the name before the hints] `=` value [hints] |
| nkVarDecl | [attributes] names (nfName) `:` type, then in their order hints and the initializer - `= value`, or `absolute X` when Aux is 1; also a field |
| nkAggregate | `( c0, ... )` - `;` after an nkAggregateField child, `,` otherwise |
| nkAggregateField | `c0 : c1` |
| nkSubrange | `c0 .. c1` |
| nkEnumType, nkEnumValue | `( c0, ... )`; `c0 [= c1]` |
| nkArrayType | [`packed` - nfPacked, see 5] `array [` index types `, ... ] of` element - no brackets without index types; Aux 1: `of const`, every child an index type |
| nkSetType, nkFileType, nkPointerType, nkStringType | [`packed` - nfPacked, see 5] `set of c0`; [`packed`] `file [of c0]`; `^c0`; `string[c0]` |
| nkClassOf | [`packed` - nfPacked, see 5] `class of c0`; Aux 1: `type of c0`, `type of interface` without a child |
| nkProcType | [`reference to` - Aux 2, see 5] `procedure` / `function` (a result-type child present), [nkParams], [`:` result type], [`of object` - Aux 1], nkDirective... - a `;` before the one whose Aux is 1 (`procedure; stdcall`) |
| nkClassType | [`packed` - nfPacked, see 5] `class` [`abstract` - nfAbstract] [`sealed` - nfSealed] [(ancestors: the leading type references)] members `end` [hints]; Aux 1: the forward `class` alone |
| nkRecordType | [`packed` - nfPacked, see 5] `record` members `end` [`align` the first non-member child] [hints] |
| nkObjectType | [`packed` - nfPacked, see 5] `object` [`abstract` - nfAbstract] [`sealed` - nfSealed] [(ancestor)] members `end` [hints] |
| nkInterfaceType | `interface`, `dispinterface` when Aux bit 1 is set, [(ancestor)] [nkGuid] members `end` [hints]; Aux bit 2: forward, the head alone |
| nkHelperType | `class helper` (`record helper` when Aux is 1) [(ancestor)] `for` the last leading type reference, members `end` [hints] |
| nkGuid | `[ c0 ]` - c0 the GUID's constant expression: a literal, a constant, a concatenation |
| nkVisibility | [`strict` - nfNegated] the word Aux 1..5 names: private, protected, public, published, automated |
| nkRoutine | the head word (see 3), the name segments (nfName) each with its [nkGenericParams], `.` between, [nkParams], [`:` result type] `;`, each nkDirective followed by `;`, [nkRoutineBody `;`] |
| nkParams | `( c0; ... )` - `[ ... ]` for a property's index parameters |
| nkParam | [attributes] [the mode - nfVar / nfConst / nfOut, see 5] [attributes] names (nfName; attributes may stand between them) [`:` type [`=` default]] |
| nkDirective | the word (see 3), then its children - its values; Aux 1 only in an nkProcType, see there. `external`: [the library] and each clause's value after its word - `name` (nfExtName), `index` (nfExtIndex), `dependency` then a `,`-separated list (nfExtDependency) - and `delayed` (nfDelayed on the directive) anywhere among them; see 5 |
| nkPropertyDecl | `property` name [nkParams] [`:` type] specifiers [hints] `;` [the trailing `default;`] |
| nkPropSpec | the word (see 3), its values `, ...`; `default` with no value is the trailing `default;` of an array property and owns its `;` |
| nkMethodResolution | the head word, the segments `.` between, `=` the last child `;` |
| nkVariantPart | `case` [tag `:`] type `of` branches `;` each - the tag when two children come before the branches |
| nkVariantBranch | labels `, ... : (` fields - each nkVarDecl followed by `;` - [nkVariantPart] `)` |
| nkGenericParams, nkGenericParam | `< c0; ... >`; names `, ...` [`:` nkConstraint `, ...`] |
| nkConstraint | its child, or its head word (see 3) |
| nkAttrGroup, nkAttribute | `[ c0, ... ]`; `c0 [( args, ... )]` when c0 is a type reference, else c0 alone - any one expression, which dcc drops (W1074) |
| nkRoutineBody | local declarations, then the nkBlock (`begin ... end`) or the nkAsmStmt |

A member with Aux 1 - a routine, a property, a struct body's var section -
is a `class` one; the `class` is the token of the list it stands in (see 5).
A struct body's var section starts at its first name: its `var` is the
struct's token too.

## 2. Leaf text

nkIdent, nkIntLit, nkRealLit, nkStrLit and nkCaretChar ARE their tokens. An
nkStrLit may span several adjacent string elements (`'a'#13'b'`, `^M^J`);
read the whole span. For a name as a key use `NodeNameLower` (it strips the
`&` escape and folds case); `NodeText` keeps the text exactly as written.

## 3. The contract reads

A few facts live in one token by design, read by a documented rule:

- the HEAD WORD at FirstToken of nkRoutine (`procedure`, `function`,
  `constructor`, `destructor`, `operator`), nkMethodResolution, nkDirective,
  nkPropSpec, nkConstSec (`const` / `resourcestring`), nkVarSec (`var` /
  `threadvar`; a `class var` run and a struct body's var section have none -
  Aux 1 marks the former), nkInitSec (`initialization` / a unit's legacy
  `begin`: one section, but other `.dcu` line records - F30) and a
  childless nkConstraint (`class`, `record`, `constructor`);
- the OPERATOR of nkUnaryOp and nkBinaryOp: the token its Aux names. One
  exception: `V.AsType<T>=5` lexes `>=` as one token that is both the `>`
  closing the type arguments and the `=` operator - the type arguments then
  end one token before it and own no `>`;
- the RANGE of nkAsmStmt: opaque by design, printed as written.

Nothing else. A consumer that reads another token - a separator, a keyword
beside a node - is reading what the tree should say; where it had to, the
fact was missing from the tree and belongs in section 4 until it is added.

## 4. What the tree does not hold yet

Nothing known: the last filed loss, a program's parameters (F17), is an
nkProgramParams since v0.88.0. A finding of the kind - a token only it holds
- is filed under its finding in the own-token table (class `loss`) until the
tree holds it. A consumer that needs one reads the token, and knows it does -
the printer does exactly that: it reads each such token where it stands
among its node's children and marks the item as a loss, so its print is the
same program, and T3 counts the losses per finding.

## 5. Span quirks

- nkMember's FirstToken is its dot; its left edge is `NodeLeftmostVis`.
- `class` before a member routine, property or `class var` is the enclosing
  type's token - or, before a class method's implementation, the section's
  or program's; the member has Aux 1. The `var` of a struct body's var
  section is the struct's token; so is its `threadvar` (`class threadvar`; nfThreadvar is on the section -
  a bare one is E2029).
- `reference to` lies outside its nkProcType's span (Aux 2): the enclosing
  type declaration's tokens.
- A parameter's mode (nfVar / nfConst / nfOut) stands at the parameter's
  left edge, unless a leading attribute group starts there - `const [Ref] X`
  and `[A] const X` are both dcc's, and only the group's own span tells the
  two apart. `out` is a directive word and a legal parameter NAME: a
  parameter whose first name is `out` and that carries no flag is one.
- An `external` directive's clause words - `name`, `index`, `dependency`, the `,`
  of a dependency list - stand right before their value, outside its span;
  the value carries the clause's flag. The library, the first value, right
  after `external`, carries none (`external index 3` is a library named
  `index` and a stray `3`: a word that ends the value before it is that
  value's own). `delayed` has no value: nfDelayed is on the directive, the
  word standing in the clause outside every value's span, in any place
  among the clauses. dcc takes each clause once (E1030 for a repeat - a
  parse diagnostic here, flagged all the same); `dependency` is accepted on
  the non-Windows compilers and `delayed` on the Windows ones, and PasTree
  takes both.
- An `exports` item's `index` and `name` stand right before their value, outside
  its span, the value carrying nfExtIndex / nfExtName; `resident` is the
  item's last token, nfResident on the item.
- `packed` lies outside the span of the type it packs (nfPacked): the
  token of that type's parent - a declaration, or the array or file
  whose element it is.
- An empty node owns no token: nkEmptyStmt and nkMissing stand BEFORE their
  FirstToken, and a node whose LastToken is FirstToken - 1 holds nothing.
- A root ends on the token after its final `end.` - the end sentinel, or
  text dcc ignores.

## 6. One tree, several spellings

The tree does not record which of these the source used; they are the same
program. The printer writes the first form, and its comparison maps the
original onto it (`PRINT_NORMALIZATION` in `PasTree.Printer`):

- statement lists: any run of `;` between statements is one, none before
  `end` / `until` / `else`; the printer writes one after every case selector
  and exception handler, because the one before a case's or an except part's
  `else` decides whose `else` it is;
- declaration lists: the `;` after the last field of a record, class, object
  or variant and after the last declaration of a struct body's var section
  may be missing before `end` or `)`; the printer writes one after every
  field, every variant, a routine's header, each of its directives and its
  body - a directive written before the header's `;`, `function F: Bool
  stdcall;`, is the same directive;
- keywords and directive words in any case;
- a fused `>=` after type arguments or generic parameters (`TFoo<T>= class`)
  as `>` and `=`;
- `[A][B]` and `[A, B]` (one nkAttrGroup), `[A()]` and `[A]`;
- `class(TBase);` and `class(TBase) end;`;
- a procedural type's directives written before or after its `of object`
  (`procedure stdcall of object`): the printer writes them after it. Where
  the `;` of `procedure; stdcall` stands the tree keeps (the directive after
  it has Aux 1, F29) - one program either way, but not one `.dcu`;
- a record constant's `;` after its last field value, `(X: 1; Y: 2;)`.
- `class abstract abstract` and `class abstract` (a repeated class or object
  modifier; the `.dcu` is the same).

Same program for dcc, the reprint through it says (T3x) - but not always the
same `.dcu`: dcc writes two of these apart in bytes the code does not
depend on. A list's last `;` before an `end` on the next line gives the
statement's end another line (the reprint keeps such `;`s where they
stand). `docs/dcu-reader.md` has the probes, and the ones for `procedure
stdcall` and `procedure; stdcall` (F29) and for a unit's `begin` and
`initialization` (F30), which the tree now keeps apart.

## 7. How it is checked

- `PasTreeTreeCheck` (tools): every token every node owns is covered by a
  rule of the own-token table, counts included - over the golden rows and
  every corpus. A token no rule covers fails.
- `PasTreePrint` (tools) and ParserSmoke, per golden row: T3 prints each
  clean file from its tree and compares the print with the visible stream,
  token for token - a token the print misses or misplaces is a defect, and
  so is a filed loss the print did not read; T3r renders the print one token
  per line and all on one
  line, parses both back and compares their trees with the original,
  fingerprint for fingerprint.
- Neither sees a grouping the parser gets wrong CONSISTENTLY - a dangling
  `else` given to the wrong `if` prints and reparses the same. That is what
  the compile-compare harness is for (`tools\fidelity.ps1`): it rewrites a
  unit along its tree and lets dcc judge the rewrite by the `.dcu` it
  produces.
