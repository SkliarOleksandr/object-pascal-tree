# Coverage: where PasTree is narrower than the language

What this file is: the list of places where PasTree knowingly implements LESS
than `object-pascal-spec` describes. Every entry is keyed by the spec section
it belongs to, so the pair reads in one direction - the spec says what Object
Pascal is, this says how far we currently follow it.

**Why it lives here and not in the spec.** These are facts about this parser,
not about the language. A spec section that says "PasTree does not implement
X yet" is unverifiable by anyone reading the spec, rots the moment the code
changes, and has no owner: nothing fails when it goes stale. Three such notes
were written into the spec on 2026-08-31 and were already FALSE a day later
(inline-var structural types, subrange categorization, the named-constant GUID
clause - all fixed in v0.14.0/v0.14.1). Here they sit beside the code that
makes them true or false, and a reviewer touching that code sees them.

The spec keeps exactly one PasTree-facing convention, and it earns its place:
the `*AST:*` hints, which name the node kind a construct lowers to. Those are
a vocabulary contract, and `tools/KindsCheck` mechanically cross-checks them.

**Status: as of v0.14.1 (2026-09-01).** A gap is either listed here or it is
not a known gap. When you close one, delete the entry in the same commit.

Not listed here, deliberately: bugs (those are fixed, not documented) and
error-tolerance decisions (PasTree analyzes broken source on purpose - see the
README's own section on that).

---

## 01-program-structure.md

### 1.1.1 The program file
- the legacy `(Input, Output)` parameter list's tokens
  are skipped opaquely; no AST nodes are produced for them.

### 1.3.2 Conditional compilation
- strict IFEND-vs-ENDIF pairing is not implemented -
  `$IFEND` and `$ENDIF` are treated as the same terminator unconditionally,
  and `{$LEGACYIFEND}` is passthrough trivia; the strict pairing check is not
  available even as an opt-in.

### 1.3.3 Include files
- the `{$I %ENV%}` / `{$I %DATE%}` insertion forms are
  diagnosed (ppUnsupportedInsertion) but no value is injected.

### 1.3.5 Compiler-version symbols
- VERxxx seeding is hardcoded to VER370 regardless of the
  compiler-version parameter; there is no per-version derivation.

## 02-fundamental-types.md

### 2.2.4 Enumerated types
- the layout oracle refuses enums containing negative
  explicit ordinals, so a `$IF SizeOf(...)` over such an enum stays a guess.

### 2.5.1 Type aliases — weak vs. distinct
- the parser marks distinctness (Aux=1) but no semantic
  layer reads the flag - distinct aliases are typed identically to weak
  aliases, with no assignment-identity distinction.

### 2.6.1 Identity, compatibility, assignment-compatibility
- the intra-unit typer implements only category-level
  scalar rules - no ordinal-range compatibility, no type identity, no
  string-kind distinctions.

## 03-variables-constants.md

### 3.1.3 Inline variables & type inference
- `var X := Expr` type inference is not implemented in the semantic layer -
  such locals stay untyped. (The parser DOES take structural types in the
  type slot as of v0.14.0.)

## 04-expressions-operators.md

## 4.11 Compiler-intrinsic quasi-operators
- intrinsics are seeded untyped - result typing (Ord,
  Chr, Length, Trunc, Round, ...) is deferred, so intrinsic calls produce
  untyped expressions; Slice's only-as-open-array-argument restriction (E2193)
  is not modeled.

## 4.12 Operator overloading (cross-reference)
- declared `class operator` overloads are never consulted
  by the analyzer's typing - non-scalar operands are exempted wholesale from
  operator checks.

## 05-statements.md

### 5.5.2 `for … in` (for-in loop)
- an untyped `for var E in C` element is typed from the collection at the
  project level only (arrays incl. `TArray<T>`, strings, sets, and a
  class/record/interface's `GetEnumerator` result's `Current` property); the
  intra-unit typer still has no ExprType for it, and a `GetEnumerator`
  supplied by a helper on a non-struct type is not chased.

## 06-routines.md

## 6.2 Parameters
- the const/var/out modifiers leave no AST node on
parameters, so declaration-to-implementation pairing ignores them - two
same-arity overloads differing only in modifiers can mis-pair.

### 6.3.1 The `overload` directive
- overload resolution is a conservative
  arity-plus-assignability score, not formal betterness ranking; ties go to
  the first candidate.

## 6.10 Inline assembly (`asm … end`)
- a bare `end` inside a skipped $IFDEF branch of an asm
  body still closes the asm block at the raw-lexing level (the raw lexer
  cannot know the live branch).

## 07-strings.md

### 7.1.2 `AnsiString` (with code page)
- `AnsiString(codepage)` declarations parse via the
  generic call-selector path (an nkCall in type position); there is no
  dedicated AST shape for the codepage clause.

## 08-arrays.md

### 8.1.2 Multidimensional static arrays
- index expressions are untyped by the intra-unit typer
  (no ExprType case); the project-level element typing descends to the
  innermost element type regardless of how many indices were written
  (documented shortcut).

## 09-records.md

### 9.1.2 `packed` records & alignment
- `packed` is consumed with no AST representation (no
  node, flag, or Aux) - consumers must re-scan tokens to detect it; the same
  applies to packed arrays.

## 11-classes.md

### 11.2.1 `private` / `protected` / `public` / `published` (+ `strict`)
- visibility enforcement is opt-in (ReportVisibility) and
  covers only private/strict-private on QUALIFIED access; protected (E2362)
  and the descendant bare-name case are not enforced, and ordinary name
  lookup never filters by visibility.

### 11.4.1 Nested type/const declarations
- for declaration-site names, a used unit's global still
  outranks an inherited member - dcc has it the other way; recorded as a
  known divergence.

## 12-inheritance-polymorphism.md

### 12.1.2 `inherited`
- a general `inherited X` expression is not typed
  intra-unit; only with-target usage is modeled.

## 13-properties-events.md

### 13.1.3 Indexed properties (`index` directive)
- the `index` specifier's dispatch typing is not modeled;
  accessors are resolved as names only. Default array properties are not
  typed on the completion overlay path.

## 14-interfaces.md

### 14.2.1 Classes implementing interfaces
- heritage walks (member lookup, descent checks) follow
  only the FIRST heritage entry - a class's implemented interfaces (second
  and later entries) are invisible to member search and descent tests.

## 15-class-mechanics-helpers.md

### 15.2.1 `class of` types
- member/constructor access through a metaclass value is
  not typed intra-unit, and the project-level walk reaches instance members
  through `class of` values without filtering them out.

## 16-generics.md

### 16.3.1 Generic instantiation syntax
- there is no intra-unit instantiation - members of
  `TList<TFoo>` type as the open generic's members; project-level frames
  exist, but overlay (mid-edit) generic frames stay unsubstituted.

### 16.4.1 Type-parameter constraints
- interface constraints and the `constructor` constraint
  are not validated at instantiation sites (class/record/class-type
  constraints are); constraint members are available for lookup.

### 16.5.1 Inference for generic methods & inline vars
- inference handles only the direct shape (the
  parameter's declared type IS the type parameter); structural matching
  (`TArray<T>` against `TArray<Integer>`) is not implemented.

## 17-anonymous-methods.md

### 17.2.1 Inline `procedure`/`function` literals
- no contextual signature inference for anonymous method
  literals; `Result` is typed only when the result type is written
  explicitly.

## 20-memory-management.md

### 20.3.1 The managed-type set
- the managed-type test ignores generic instantiation
  frames (a record instantiated with a managed argument reads as unmanaged
  when the field's declared type is the open parameter) and does not follow
  `= type X` distinct aliases.

## B-lexical-grammar.md

### B.6.1 Quoted string & character literals
- the lexer emits adjacent string elements as separate
  tokens by design (full-fidelity contract); folding them into one literal is
  the consumer's job.

### B.6.2 Caret control characters
- the raw lexer always emits `^` as its own token; caret control-char vs
  pointer dereference is decided by the parser positionally.

