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

None of the parser's - the resolver's are in section 6. One is fixed for Win64 only: the DCU reader hung a routine's nested
routines under an anonymous method's body written just before it (F5);
Win64's `$pdata$` names say each one's owner and the reader follows them,
while Win32's file says nothing of it (docs/dcu-reader.md, known gaps).

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
constant there, both dcc's, gave parse errors. A program's parameters (F17,
the last loss) are an nkProgramParams of names. An attribute (F32) is a name
with its arguments or any one expression - `['abc']`, `[1 + 2]`, `[C + 1]`,
`[(TA)]`, which dcc compiles and drops (W1074); they were parse errors.
A conditional crossing an include boundary (F22, invalid code only) was
accepted in silence, and the preprocessor's own comment called that dcc's
rule; dcc refuses every such shape - an include that opens one and leaves it
open is E2280 there, an include's `$ELSE` or `$ENDIF` on its includer's
conditional is E2280 or a garbled includer. The tokens still follow the
shared stack, and each crossing is a diagnostic where it happens.
In a broken file the root stopped where the parse stopped (F8): one extra
`end;` in a routine body, or a construct broken above it, closed the module
there, and every declaration after it was in no node - no symbol, no
outline, no navigation for the rest of the file. An `end` with no `.` after
it and text behind it is now said as before (`"." expected`) and the section
goes on; whatever a parse still leaves before the end of the file is one
error node, so the root spans the file. Text after a real `end.` is dcc's to
ignore and stays as it was.

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
Studio's Windows RTL package and every extra corpus, and the resolver's rung
(section 6): `tqm` over the self-host and the Studio units, its selftests
`tqs` and `tms` over the Studio units (an extra corpus takes them on
request). About six minutes on twelve workers for the tree's stages, as
many again for the rung's;
`-Studio all` takes every rtl/vcl/fmx unit, `-Stage` a subset.

The rung's names it cannot judge - bound to nothing, to a unit no name at
the site can come from, or a member whose base PasTree types against its own
binding - are counted, and each count is a FLOOR in the expectations
(`@unbound`, `@invisible`, `@mismatch`; the Studio's per unit list,
`studio-rtl` or `studio-all`): a resolver change that raises one is a
regression no `.dcu` shows, one that lowers it asks for the floor to follow.

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

## 6. The second rung: the resolver through the same harness

The tree being dcc's, the same harness judges what the analysis BINDS. Mode
`tq` writes every name PasTree bound so that dcc can only read it as the
declaration PasTree chose - a unit-level declaration of any unit, System's
builtins and the unit's own included, as `<Unit>.Name` with the unit
spelled as its uses entry writes it (under `uses Windows`, resolved to
Winapi.Windows through the unit scope names, `Winapi.Windows.X` does not
compile: dcc finds a qualifier's first segment among the names the uses
clauses write, and System); a field,
method or property of the method's own type, reached bare in its body, as
`Self.Name` - and the unit compiles to the original's `.dcu` exactly when
every rewritten binding is dcc's. A wrong unit, a member taken for a
unit-level name, an inherited member missed: the code changes or the compile
stops, and the localizer names the name. `tqs` is its selftest, as `ts` is
`t1`'s: in each routine one name qualified with another visible unit's
variable or routine of that name, which must be seen and localized alone.

`tq` takes PasTree's project analysis of the unit (the Studio source trees,
or `-OraclePath`) and edits that analysis's own tree; it compiles under
`t2`'s switches. The rules it follows, each from a probe:

- `Self.X` and a qualified name in a stored body change only the `$93`
  symbol-reference record under dcc's defaults: `-$Y-` (with `t2`'s
  `-$O- -$D- -$L-`); a unit whose own text turns `DEFINITIONINFO` or
  `REFERENCEINFO` on overrides it, and takes unit qualifiers outside
  stored bodies only - no `Self.`, no cast; with `REFERENCEINFO` itself on
  (`$Y+`, not `$YD`) every reference is recorded and a unit qualifier
  changes the record as well (`System.Byte` for `Byte`): none at all;
- in a generic's body `Self.X` after a call of a method changes one flag
  byte of the stored body and its checksum - no code, but another `.dcu`:
  no `Self.` there;
- an overload set dcc merges across units records every unit's routine it
  looked at as an import, used or not - and behind a routine marked
  `overload` every declaration of the name it meets, of any kind (spec
  6.3.1) - and a builtin System also declares
  (`Flush`) is another routine when qualified: such a name is not written;
- a qualifier whose first segment a name in scope hides does not resolve
  (spec 1.2.3) - a field named like the unit, a member of an ancestor of
  another unit, a `with` target's member, even a member named like the head
  of a dotted uses entry - and in a method of a class whose ancestry leaves
  what PasTree can read (a form descending from a type of a unit present
  as a `.dcu` only), any head may be such a member: no qualifier there;
  nor does a qualified name of the unit's own declared further down
  (`PFoo = ^TFoo`);
- `Slice`, the head of what follows `inherited`, a procedural field standing
  as a statement (`FProc;`), a function's own name in its body (its
  old-style result, `F[I] := C` included, or a recursive call), a property's
  specifiers, a method resolution clause, an exports item, a directive's
  arguments, an attribute's name, a record constant's field name have no
  qualified spelling and are left as written.

A binding to a unit no name at the site can come from - an implementation
uses entry seen from the interface, a unit the unit does not use - is wrong
whatever dcc says: it is reported (`INVISIBLE`, each listed in sites.txt),
not compiled. A name PasTree bound to nothing is counted (`UNBOUND`).

Mode `tm` judges the MEMBERS the same way: every member reached after a dot
is written through a hard cast to the type PasTree says declares it -
`Owner(Base).Name`, `Owner(P^).Name` for a pointer the original dereferences
implicitly; a default array property is spelled, `Owner(Base).Items[I]`; a
name in a `with` body that a target's member answers is written through
that target, `Owner(Target).Name`. dcc then looks the name up in the owner,
so a member of another type - a descendant's namesake hiding it, the other
target of two - changes the code or stops the compile. `tqm` runs both
halves, `tms` is the member half's selftest: in each routine one member cast
to the nearest ancestor declaring another field or routine of that name.
The rules, each from a probe:

- a cast naming a type the unit has not named yet adds an import record to
  the `.dcu`, and one naming it earlier than the unit did reorders them -
  the code unchanged. So every cast's type of another unit is named first,
  by a preamble (a procedure whose locals name them) before the top-level
  declaration holding the cast, in the ORIGINAL's compile as in every
  rewrite's: the original side of `tm` is the rewrite with no site;
- a class variable or method spelled through another type name imports that
  type's class reference: a type base is left as written; so is a class
  reference base (no named metaclass of the owner to cast to), `Self` in a
  class method among them - `TFoo(Self).Create` would call the
  constructor on an instance;
- on Win32, a write through a cast of an enclosing routine's variable from
  a nested routine, after another reference to one, moves dcc32's frame
  slots - the same code over another frame (dcc64 keeps the layout): no
  cast of such a base on Win32;
- a record returned by a call takes no hard cast (a property read through a
  getter does); a protected or private member of another unit's type does
  not survive the cast to it (reached through a descendant the unit
  declares, or from a method of one, it is legal; through the owner, E2362);
- a cast in a generic's or an inline routine's body changes the stored body,
  and so does a cast to an ancestor of a member that such a body reads
  anywhere in the unit: neither is written;
- in a unit whose text turns optimization on, a cast of a base that is no
  plain name defeats dcc's reuse of the loaded value: only plain bases;
- a `with` target is written only when it is a parameter, a local variable
  or `Self`: a field or a global the `with` reads once into a temporary, the
  spelling at every name.

And one more for `tq`: a bare `Default(X)` in a nested type whose outer type
has a member `Default` is the intrinsic only if the unit wrote a bare
`Default(...)` before it - qualifying the earlier ones turns it into the
member (dcc's lookup keeps a history; System.Threading). `Default` is left
as written. So are `Flush`, `ChDir`, `MkDir` and `RmDir`: System declares
them, but a bare call gets the `{$I+}` I/O check dcc gives a file
intrinsic, and `System.Flush(T)` none - the same routine, another code
(spec B.4; first filed as a resolver finding, F41). A qualifier spelling
SysInit, like one spelling System or the unit's own name, is no symbol's
(`SysInit.HInstance`, Vcl.Dialogs): not an unbound name (0.93.28). Nor is a
name in a `with` body bound to one overload of a set the target's member walk
answers with the head of (`with Stream do ReadBuffer(Level, SizeOf(Level))`,
TStream's four ReadBuffers): no contradiction - the cast lets dcc choose
again (F55, 0.93.31).

What the rung cannot see: the overload chosen INSIDE one unit's set and the
unit of a set merged across units; a virtual or interface member's
declaring type (the call goes through the slot); the declaring type when it
is higher than the one PasTree chose (the cast to a descendant still finds
the ancestor's member); locals, parameters, `Result`, labels and generic
parameters, which have no qualified form; members of generic types (the
cast would need the instantiation), of helpers, after a type or a class
reference, in stored bodies; members in a class method and of an outer type
reached bare.

As of 2026-10-03 (v0.91.0), `tqm` over the self-host is 29/29 on Win64 and
Win32 (51 601 names rewritten, 14 163 more than `tq` alone); `tm` over the 310
units of the Studio's Windows RTL package 308 on both platforms (12 117
members), the rest the unit that does not compile standalone and one
resolver finding; `tqm` 305, the four others the `tq` findings of before;
`tms` 18 planted members in 12 units, each seen and localized alone. The
findings `tm` added (plan F42-F46): the probe typing a member's base as an
open generic parameter (`for var P in IntMap` over a nested alias of a
generic record, WinRT statics) - 38 bindings PasTree's own typing
contradicts, listed, not compiled; a member of `TThreadList<T>` bound in the
non-generic `TThreadList`; `M^^` through an anonymous pointer to a pointer
typed one dereference short; and 123 selectors PasTree binds to nothing -
an element through a pointer to an array, a record field of a record field,
a helper's member on a string element, an operator's result, a parameter of
a nested record type.

As of 2026-10-04 (v0.92.0) the rung has run wide. `tqm` over the self-host
is 29/29 on Win64 (51 477 names) and Win32 (50 880); over all 661 Studio
rtl/vcl/fmx units 641 OK (1 039 708 names), the five that do not compile
standalone, one NONDET and 14 resolver findings; `tqs` there plants 64
names in 19 units and `tms` 151 members in 44, every one seen and localized
alone. Over third-party libraries built into bases of their own: spring4d
134/148 (the rest 11 units that do not compile standalone and three
findings), Alcinoe 57/60, mORMot 57/60 on Win64 and 59/62 on Win32,
cnwizards 397/400. The rules above that came from these runs: a qualifier
spelled as the uses entry writes it, a head hidden by a with target's or an
ancestor's member or by an ancestry PasTree cannot read, `$Y+` against
`$YD`, a function's own name, `Self` of a class method, the Win32 frame.
The resolver findings (plan F37-F50, each a gate expectation): a member's
visibility from another unit ignored - a private method of a VCL ancestor
taken for a bare name dcc finds in a unit (F38, fixed in 0.93.5); an
inherited member missed for a unit-level or System name (F40, fixed in
0.93.6); `Flush` and `ChDir`, standard procedures System also declares
(F41 - the harness's, not the resolver's, 0.93.7: see above); a name in a
`with` body falling past Self's inherited members to a System type or a
unit-level declaration (F49, fixed in 0.93.9: the with pass asks Self's
ancestry for a name no target has, as the inherited pass does outside a
with); a nested class whose ancestor is a same-named nested class reaching
the outer type's members (F48, gone by 0.93.18 - the declaration-site order
of 0.93.10 and 0.93.11 - and pinned by a test in 0.93.19); `Length(Self)` in a helper for a
`type string` bound to TStringHelper's Length - a distinct type's member walk
went on into `string` and asked string's helper there (F50, fixed in
0.93.16); `M^^` over `M: ^PResStringModule` typed one dereference short, the
pointee of M's own declaration read for `M^` as a base (F45, fixed in
0.93.17); the constant named by an interface's GUID clause bound to nothing
(F39, fixed in 0.93.18); a name in the interface section bound through an
implementation `uses` entry - `PByte` in System.Hash's interface to
System.Types, the WinRT aliases of System.Win.ShareContract to
Winapi.CommonTypes past the interface's own Winapi.ApplicationModel.DataTransfer
(F35, F36, fixed in 0.93.20); a member already bound typed in its base's
frame when an alias or a generic ancestor declares it - `LPair.Value` over
TPasIntMap<V>'s `TSlot = TPair<Integer, V>`, WinRT's `TFooImport.Statics`
- left as the open parameter (F43, fixed in 0.93.21); a declaration typed
with another unit's nested type (`MinTarget: TAniCalculations.TTarget`) typed
to nothing in the cross-type pass, so the members read through it were bound
to nothing - the largest shape of the rung's unbound selectors (F46, that
shape fixed in 0.93.22; an operator applied to a record, `(B - A).Len`,
typed as its `class operator`'s result in 0.93.25; an array of such a nested
type and a member through an inline `^T` in 0.93.26; a character pointer's
Char (`FormatPtr^.IsNumber`) and an implementation routine qualified with
the unit's own name in 0.93.27; a pointer to a record indexed and a result
type hidden by a parameter or a local of the same name in 0.93.29); the
member after `TThreadList<IInterface>.` looked up in the unit's own plain
`TThreadList` the head was first bound to, once the head
itself had moved to the used unit's generic (F44, fixed in 0.93.15); `Self` in
a helper's method typed as the helper rather than the extended type -
spring4d's `Self.Names[i]` in its TStringsHelper (F56, fixed in 0.93.30). And
one regression the rung caught: a bare `Pointer` bound to a used unit's
generic `Pointer<T>` (F51, from 0.92.1's search of the used
units for a declaration hiding a predefined name, which ignored arity; fixed
in 0.93.8). Probing the shapes the rung met turned up more of the same
family: in a nested type's method the outer type's members come only after
the unit's own declarations made so far (F52, fixed in 0.93.10); in a
type's DECLARATION its own members rank after them too and its ancestors'
are out of reach - a used unit's declaration is what such a name means,
while a type nested in it sees the outer types' ancestry ahead of the used
units (F53, fixed in 0.93.11, the method's implementation heading alike);
and a unit type declared above a generic hides the generic's same-named
parameter, in its declaration and its method bodies, where a generic
method's own keeps it (F54, fixed in 0.93.11). The language spec's sec.
3.3.2 has the whole order.
