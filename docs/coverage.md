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

**Status: as of v0.18.0 (2026-09-07).** A gap is either listed here or it is
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
- the VERxxx symbol and CompilerVersion/RTLVersion follow the one
  compiler version a project is created with (default 37.0); a host
  cannot mix versions inside one project, and no other version-dependent
  behaviour (language features gated per release) is emulated.

## 02-fundamental-types.md

### 2.2.4 Enumerated types
- the layout oracle refuses enums containing negative
  explicit ordinals, so a `$IF SizeOf(...)` over such an enum stays a guess.

### 2.5.1 Type aliases - weak vs. distinct
- the parser marks distinctness (Aux=1) but no semantic
  layer reads the flag - distinct aliases are typed identically to weak
  aliases, with no assignment-identity distinction.

### 2.6.1 Identity, compatibility, assignment-compatibility
- the intra-unit typer implements only category-level
  scalar rules - no ordinal-range compatibility, no type identity, no
  string-kind distinctions.

## 03-variables-constants.md

### 3.1.3 Inline variables & type inference
- `var X := Expr` / `const C = Expr` in a body and a `for var I := From`
  counter are typed from the initializer at the PROJECT level (CrossType);
  the intra-unit typer still has no ExprType for them. The inference refuses
  rather than guesses: a designator naming a routine that still requires
  arguments (dcc's E2035), a call whose overload selection tied between
  different result types, a bare type name (a class reference with no named
  `class of` type), `nil`, and a set constructor (an anonymous type) all
  leave the declaration untyped.
- a CONSTRUCTOR call does not type the declaration either: `var L :=
  TFoo.Create` leaves L untyped and every member behind it goes dark, while
  `var L := MakeFoo` (a parameterless function) types and resolves. Unlike
  the refusals above this one is not a decision - a constructor's result is
  its class, and nothing about the shape is ambiguous - so it is a gap, and
  a common idiom's worth of one. Measured 2026-09-07 through pastree-lsp:
  neither a type-of query on L nor a member access behind it answers.
- A literal initializer gets dcc's exact type (LiteralTypeX, probed on both
  compilers): Integer/Cardinal/Int64/UInt64 by magnitude with the sign
  folded, Char for a one-unit string literal, Currency for an exponent-free
  real with at most four fractional digits on a 64-bit target (Extended
  otherwise). An OPERATOR expression over literals takes the intra-unit
  typer's category-level answer, which does not fold magnitudes:
  `var X := 5000000000 + 1` reads Integer where dcc says Int64. The Currency
  rule was probed on Win64 only; the other 64-bit targets are assumed to
  share it.

### 3.2.1 True constants
- a section-level `const C = Expr` is typed from its initializer in the
  declared-type pass (BindTypesX), so another unit's `C.ToString` binds; the
  same literal, operator and intrinsic (4.11.4) rules as 3.1.3 apply.

## 04-expressions-operators.md

### 4.11.4 Result types of the value-returning intrinsics
- the result rules are implemented in both typers from the spec's probe
  table, with these edges left out: a named subrange whose bounds exceed
  32 bits (`1..5000000000`) reads Integer under Low/High/Pred/Succ/Abs where
  dcc says Int64 (the bounds are not folded); `GetTypeKind` is typed at the
  project level only (System.TTypeKind is a real declaration the intra-unit
  typer cannot see); `Slice` stays untyped (it is legal in one position only,
  where its type is never read).
- a VALUE-taking intrinsic whose argument resolved to a TYPE NAME (a member
  named `Word` bound to the builtin, the CheckAssign mis-binding case) types
  as nothing rather than as that type.

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
  the first candidate. A tie between candidates with DIFFERENT result types
  is recorded (CrossType's LAmbig) and refuses inline-var inference from the
  call, but the call node itself still carries the first candidate's type.
- a bare routine name in a value position - a member qualifier or an inline
  initializer - means the parameterless overload (6.6.1); the same rule is
  NOT applied in other value positions (an argument, an assignment's right
  side), where the first-declared overload still wins.

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

