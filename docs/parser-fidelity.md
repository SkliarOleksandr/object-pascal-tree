# Parser fidelity: how the tree is proven dcc's

What it means that PasTree's parser is exact, how that is checked, what the
checks cannot see, and the one command that runs them before a parser,
preprocessor or printer change is committed (`tools\fidelity-gate.ps1`).
The companion documents: `docs/tree-contract.md` - what a consumer may read
from a tree and from where, the losses and the spellings the tree does not
keep; `docs/dcu-reader.md` ("Comparing two compiles byte for byte") - every
fact about dcc's `.dcu` output the comparisons below depend on.

## 1. The claim, stated so it can fail

"The parser is exact" is three claims, each checked on its own:

1. **Coverage.** Every visible token of a valid unit is inside the tree:
   inside the root's span, owned by exactly one node, nothing swallowed.
2. **Structure.** Every grouping decision - operator precedence and
   associativity, the extent of each expression and statement, a dangling
   `else`, a case's `else` against an if's, generic arguments against
   comparisons, an aggregate against a parenthesized expression - is the
   one dcc makes.
3. **Completeness.** The tree alone - kind, Aux, flags, child order and the
   text of the leaf tokens - is enough to reproduce the unit. No fact
   survives only in a token no node describes, but the losses the contract
   lists.

The first is judged without a compiler. The second and third are judged by
dcc itself: a rewrite of the unit computed from the tree compiles to the
same `.dcu` exactly when the tree is the one dcc built. In one line: **print
the unit from the tree alone, fully parenthesized and fully blocked, and
dcc compiles it to the same `.dcu`.**

A token-level round trip (tokens plus trivia equal the source, byte for
byte - definition of done item 2) proves the LEXER lossless and says nothing
about the tree; everything below is about the tree.

## 2. The checks

### Without a compiler

- **The tree checker** (`source/PasTree.Ast.Check.pas`, `tools/PasTreeTreeCheck`).
  Invariants over any tree: indices in range and every span a span (I1),
  children ordered, disjoint and inside their parent (I2), the links
  consistent and every node reachable - the few unreachable shapes the
  parser builds on purpose counted, never silenced (I3), the root covering
  the stream (I4), Aux and flags inside each kind's domain, an operator's Aux
  its own token, and a declaration's names marked where the separators say
  (I6), two parses building the same arena and the interface-only parse a
  prefix of the full one (I7), and in valid code no nkError and no nkMissing
  but a trailing comma's (I8). **I5, the own-token table** (`OWN_RULE_TEXT`):
  every token a node owns, per kind, is `derived` (follows from the kind, Aux,
  flags and children), a `leaf`, a documented `contract` read, `insig`nificant
  (a spelling the tree takes as one) or a filed `loss` - with its count. A
  token no rule covers fails, and so does a broken count.
- **The structural printer** (`source/PasTree.Printer.pas`, `tools/PasTreePrint`).
  A template per kind prints the unit from the tree alone: keywords and
  punctuation from the kinds, text only from leaves and the contract reads,
  a filed loss read where it stands and counted. **T3** compares the print
  with the parsed tokens under a written normalization list (N1-N12,
  `PRINT_NORMALIZATION`): a token missed or misplaced is a defect. **T3r**
  renders the print one token per line and all on one line, parses both
  back and compares the trees, fingerprint for fingerprint.

Both run over every golden row of ParserSmoke (the statement and
declaration rows and the custom cases that parse a tree of their own) and
over any directory. Neither sees a grouping the parser gets wrong
CONSISTENTLY: a dangling `else` given to the wrong `if` prints and reparses
the same. That is what the compiler is for.

### Through dcc: the compile-compare harness

`tools\fidelity.ps1` compiles the original and a rewrite (`tools\PasTreeXform`)
of each listed unit, each as an isolated copy at the same path, and compares
the two `.dcu` files byte for byte (the header's compile time masked).
Nothing is expected by hand: dcc is the judge. The rewrites, one layer each:

| Mode | The rewrite | What an identical `.dcu` proves |
|---|---|---|
| `t0` | none - an unchanged copy | the comparison itself is fair |
| `ts` | planted errors (a wrong operator, a swapped operand) | the comparison SEES an error, and the localizer names it (the selftest) |
| `t0f` | the preprocessor's decisions written into the text: skipped regions and conditionals blanked, each include flattened per inclusion | the preprocessor took every branch dcc took |
| `t1` | every operator parenthesized along the tree | every expression grouped as dcc groups it |
| `t2` | every statement in a statement position wrapped in `begin`/`end` | every statement extent, `else` and empty statement as dcc reads them |
| `t3` | the unit reprinted from its tree, in place of its own tokens | the tree holds the program - the print is the same unit for dcc |
| `t3x` | `t3` with `t1`'s parentheses and `t2`'s blocks over it | all of it at once: the final gate |

A DIFF names the routines whose code differs (`PasTreeDcu -dump` of both
sides); the **localizer** then bisects the rewrite's sites by recompiling
subsets - a correct site changes nothing, so a subset differs exactly when
it holds a wrong one - and names the node, about 2 log2(n) compiles per
culprit.

### The rules the rewrites follow, each from a probe

A rewrite that is correct for the tree must still leave the bytes dcc does
not derive from the program alone. What those are is in `docs/dcu-reader.md`;
the harness follows from them:

- both sides compile a copy in a directory of its own, at the same path,
  with the original's mtimes;
- `t1` and `t2` compile under `-$O- -$D- -$L-` (dead-store elimination hid
  a wrong tree; the line tables give code the line of the NEXT token), `t2`
  and `t3x` also `-$Y-`; `t0f` and `t3` under dcc's defaults - the state the
  preprocessor starts from, and the strictest judge of a print that must
  change nothing;
- sites a correct rewrite would still change, never rewritten: `t1` - an
  operator at the start of a subrange type or an initializer's value (a `(`
  there opens an enum or an aggregate), one whose left operand starts with
  `[`, the operand of `@`; `t2` - a call statement as a list item (its
  discarded managed result is finalized at the end of the list), inline
  declarations, labeled statements, asm, and in a stored body (a generic or
  inline routine) a statement not on one line with its next token; both -
  a unit whose own text turns debug or symbol info back on takes only sites
  that share a line with the token after them;
- an added `end` goes right before the token after the statement, never
  right behind it (an `Assert` passes the line of the next token);
- `t3` prints IN PLACE: each item into the byte slot of the token it
  matched, everything else - comments, directives, inactive code, includes -
  byte for byte, so lines never move (dcc keeps lines, not columns), and a
  list's last `;` the print does not need stays where it stands;
- a DIFF is believed only when the original compiled again gives its own
  `.dcu` and the copy compiled again never gives the original's (four times
  each): otherwise the unit is NONDET, counted and not judged.

## 3. What the checks cannot see

Written down, not pretended away:

- **String concatenation**: dcc flattens `+` over strings, so their
  associativity leaves no trace.
- **Generic arguments against comparisons** where PasTree reads a generic
  and dcc comparisons: `t1` inserts nothing inside type arguments, so the
  text does not change. Only the opposite direction is caught.
- **Facts with neither code nor a trace in the `.dcu`**: `reintroduce`,
  comments, some hints.
- **asm bodies**: opaque by design, printed as written.
- **Units that do not compile standalone** although their program does: a
  reserved unit name (`System`, `SysInit`), unit cycles through generics
  (F2051 against a partner's `.dcu`), units dcc crashes on standalone,
  code the compiler version refuses. A program whose build cannot be
  reproduced headless is not judged at all.
- **Sites never rewritten** (section 2): an initializer's first operator,
  a call statement as a list item, a stored body's multi-line statements.
  Their extent is fixed by `;` and the list's end, or covered by `t3`.
- **dcc's own nondeterminism**: a few units give different `.dcu` files
  for one text from run to run - one of the VCL's under `-$O-` always,
  another VCL unit and one RTL unit rarely (the RTL one seen twice in two
  gate runs on twelve workers, under `t0f` once and `t3x` once, never
  before). Such a unit is NONDET, not judged; a variation rarer than the
  harness's recompiles could still pass as a DIFF - nondeterminism can fake
  a DIFF, never an OK.
- **Spellings the tree does not keep and dcc writes apart**
  (`docs/tree-contract.md` sec. 6): the reprint of those units differs in
  bytes the code does not depend on.

## 4. Where it stands

As of 2026-09-28 (v0.64.2):

- the tree checker and the printer, over the Studio 37 source, two
  flattened RTL corpora and two trees of third-party libraries - about 93M
  tokens: no violation of any invariant and no token outside the own-token
  table in any clean file; no token the print misses or misplaces (T3);
  every file parses back to its own tree (T3r), in both layouts;
- the harness, `t0f`, `t1` and `t2`: over the self-host, the Studio units
  (rtl, vcl, fmx; Win64 and Win32), four third-party libraries and two
  applications (one of them partially - its build cannot be reproduced
  whole), every unit that compiles standalone compiles to the original's
  `.dcu` but for the findings below and dcc's nondeterminism;
- `t3` and `t3x`: the same over the self-host, the Studio units on both
  platforms and one third-party library - the reprint from the tree is the
  same program everywhere, and the same `.dcu`.

The dangling `else`, a case's `else`, every statement extent, operator
precedence and associativity - including `is`, the inline `if`, a unary
minus before a member call - agree with dcc everywhere they were met.

### Findings still open

| Id | Where | What |
|---|---|---|
| F13, F14, F16, F17 | the tree | tokens only they hold - the losses of `docs/tree-contract.md` sec. 4; each is read in place and counted, none changes a grouping |
| F5 | the DCU reader | a routine's nested routines listed under its anonymous method's body; only the dump's nesting |
| F8 | the parser, error mode | the root stops where a broken parse stopped, the rest of the file in no node |
| F22 | the preprocessor | a conditional crossing an include boundary is accepted; dcc refuses it (invalid code only) |

Fixed on the way, each by its own reviewed change: a subrange bound that
swallowed an initializer's `=` (F6, silent on a variable), directives of a
procedural type or a routine header that left no node (F1, F2, F10, F11,
F27 - several were parse errors on valid code, one misread a directive as
a call), where a declaration's name list ends (F19), `Declared` of a unit's
own earlier declaration (F21, positional as dcc), the right operand of
`is` (F24 - `O is TFoo and C` was `O is (TFoo and C)`) and two recovery
rules that read a line break inside a variant part (F28 - `case` NEWLINE
`Tag: Byte of`, and a qualified label's member on the next line, were
parse errors on valid code; T3r's token-per-line print found them) and
where a procedural type's `;` stands (F29 - `procedure stdcall` and
`procedure; stdcall` are one type, not one `.dcu`; the directive after the
`;` has Aux 1 now) and which word opens a unit's initialization part (F30 -
a legacy `begin` and `initialization` are one section, not one `.dcu`; the
head word is a contract read now, and a `begin` followed by `finalization`
is a parse error, as it is dcc's) and where an asm body ends (F26 - the
lexer guessed it before any branch was decided, and a dead `asm` lexed the
live code after it as asm; the preprocessor now checks every token's mode
and lexes again where the guess was wrong) and the predefined conditional
set (F20 - `DCC`, `NATIVECODE`, the `WEAK*` family were missing, `CPUINTEL`
extra; the sets are now what every installed dcc 37.0 answers, the switch
start state has `N+`, and NativeInt's helper is the one of the integer of
its size) and where an include is looked for (F23 - beside the including
file first, where dcc looks beside the unit, then the current directory,
then `-I`; the naming file's directory is now a last-resort tolerance) and
which declaration a `$IF` over a constant's value reads (F25 - the first
pass's model, where a guard the second pass flips still held the unit's own
fallback: `CPP_ABI_ADJUST = 0` instead of System's 24 on Win64; now the own
declaration above the directive in the decided stream, else the import's -
filed first as a vendor build define, which it was not) and where
an attribute group after a section stands (F7 - `var X: Integer; [A] procedure
Foo;` parsed the group and dropped it, after a `const` too, and a type
section kept it; the section now ends before a group no declaration of it
follows, and the group stands beside the member after it, as dcc hangs it
there - across a visibility word too) and `packed` (F3 - the word left
no mark, and a record's layout read the token before it; nfPacked is on
the record, array, set, file, class, class-of or object type it packs, the
word outside the type's span as `reference to` is, and `packed` where dcc
refuses it - before a type name, a subrange, `string`, an interface, in a
parameter's type - is a parse error) and `class abstract` / `class
sealed` (F4 - the words left no mark, and after `record` a field named
`abstract` or `sealed` was eaten as one - parse errors on valid code;
nfAbstract / nfSealed are on the class or object type, the words read
after `class` and `object` only, as dcc reads them), `class threadvar` (F9 -
it read as `class var`; nfThreadvar is on the struct body's var section,
the word outside its span as `var` is; a bare `threadvar` in a body is
E2029) and the message of a routine's `deprecated 'msg'` (F12 - an nkStrLit
child of the directive, as a declaration hint's always was) and a
parameter's `var` / `const` / `out` mode (F18, the largest loss by count:
nfVar / nfConst / nfOut on the parameter, the word written where dcc wrote
it - before or after a leading attribute group, as the group's own span
says). An interface's GUID clause (F15) is one constant expression, its
child - a literal had no leaf, and a concatenation or a parenthesized
constant there, both dcc's, gave parse errors.

## 5. The gate

Run before committing any change to the lexer, the preprocessor, the
parser, the printer or the harness:

```
tools\fidelity-gate.ps1
```

It builds the four tools (Win64, range and overflow checks on), runs the
comparator's selftest over the self-host, the tree checker and the printer
over the golden rows, the repository's own sources and the Studio source,
then `t0f`, `t1`, `t2`, `t3` and `t3x` over the self-host, the units of the
Studio's Windows RTL package and every extra corpus. About six minutes on
twelve workers;
`-Studio all` takes every rtl/vcl/fmx unit, `-Stage` a subset.

Every outcome other than OK that is known today is an EXPECTATION with its
reason (`tools\fidelity-gate.txt`; an extra corpus's in its own file): a unit
no line names must be OK, a named one must show an outcome its line allows,
a T3r failure must be listed; a NONDET unit (dcc gave two `.dcu` for one
text) is shown and not judged. A fix shows up as "now OK (drop the
expectation)"; a regression as a FAIL line with the unit's result. An extra
corpus - a third-party library built into a base of its own, the way the
harness needs it - is a `.ps1` returning its name, `fidelity.ps1`'s
parameters and its expectations; its paths stay out of the repository.

What a failure means: a new DIFF or XFORM-FAIL is a unit dcc reads
differently from the tree now - the localizer's culprits name the nodes; a
tree-stage failure is a file of valid code that no longer parses clean, a
broken invariant, a token the table does not cover, or a print that no
longer matches or parses back.

The gate was proven able to fail: with the parser handing a dangling `else`
to the outer `if` it failed in every stage that can see it - 23 files no
longer parsing clean, `t2` 10 self-host units and 44 of the RTL's, `t3` 21
(20 it cannot reprint, one reprinted as another program) - and a known
exception taken off the
list failed `t3` on exactly that unit. A tree stage alone would have missed
most of it: the misparse prints and reparses the same wherever the file
still parses.
