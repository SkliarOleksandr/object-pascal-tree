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
| nkGotoStmt, nkLabeledStmt | `goto c0`; `c0 : c1` - see 4 for numeric labels |
| nkTryStmt | `try c0` then nkFinallyPart (`finally c0`) or nkExceptPart (`except` handlers or a catch-all block), `end` |
| nkExceptOn | `on [c0 :] type do statement` - three children: the name first |
| nkRaiseStmt | `raise [c0 [at c1]]` |
| nkInlineVar | `var` names (nfName), [`:` type], [`:=` value when Aux is 1] |
| nkInlineConst | `const` name (nfName), [`:` type], `=` value |

Declarations follow the table and the kind comments too; where a list of
names ends is marked on the names themselves (nfName), never by the
separators after them.

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
  Aux 1 marks the former) and a childless nkConstraint (`class`, `record`,
  `constructor`);
- the OPERATOR of nkUnaryOp and nkBinaryOp: the token its Aux names. One
  exception: `V.AsType<T>=5` lexes `>=` as one token that is both the `>`
  closing the type arguments and the `=` operator - the type arguments then
  end one token before it and own no `>`;
- the RANGE of nkAsmStmt: opaque by design, printed as written.

Nothing else. A consumer that reads another token - a separator, a keyword
beside a node - is reading what the tree should say; where it had to, the
fact was missing from the tree and belongs in section 4 until it is added.

## 4. What the tree does not hold yet

Each is a token only it holds, filed under its finding in the own-token table
(class `loss`). A consumer that needs one reads the token, and knows it does.

| Finding | Not in the tree |
|---|---|
| F3 | `packed` |
| F4 | `class abstract`, `class sealed` |
| F9 | `class threadvar` (reads as `class var`) |
| F12 | the message of a routine's `deprecated 'msg'` |
| F13 | inside `external`: which child is the library, the name, the index; `delayed` |
| F14 | in `exports`: which child is the index and which the name; `resident` |
| F15 | an interface GUID written as a string literal |
| F16 | a numeric label: `goto 10`, `10: S`, `label 10` |
| F17 | program parameters, `program X(Input, Output);` |
| F18 | a parameter's `var` / `const` mode (`out` is Aux) |

## 5. Span quirks

- nkMember's FirstToken is its dot; its left edge is `NodeLeftmostVis`.
- `class` before a member routine, property or `class var` is the enclosing
  type's token; the member has Aux 1.
- `reference to` lies outside its nkProcType's span (Aux 2).
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
- keywords and directive words in any case;
- a fused `>=` after type arguments as `>` and `=`;
- in declarations (the printer does not regenerate them yet): `[A][B]` and
  `[A, B]`, `[A()]` and `[A]`, `class(TBase);` and `class(TBase) end;`, a
  unit's `begin` for `initialization`, `procedure; stdcall` and
  `procedure stdcall`.

## 7. How it is checked

- `PasTreeTreeCheck` (tools): every token every node owns is covered by a
  rule of the own-token table, counts included - over the golden rows and
  every corpus. A token no rule covers fails.
- `PasTreePrint` (tools) and ParserSmoke, per golden row: T3 prints each
  clean file from its tree and compares the print with the visible stream,
  token for token - a token the print misses or misplaces is a defect, but
  for a filed loss; T3r renders the print one token per line and all on one
  line, parses both back and compares their trees with the original,
  fingerprint for fingerprint.
- Neither sees a grouping the parser gets wrong CONSISTENTLY - a dangling
  `else` given to the wrong `if` prints and reparses the same. That is what
  the compile-compare harness is for (`tools\fidelity.ps1`): it rewrites a
  unit along its tree and lets dcc judge the rewrite by the `.dcu` it
  produces.
