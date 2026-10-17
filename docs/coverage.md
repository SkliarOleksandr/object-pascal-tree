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

**Status: as of v0.64.1 (2026-09-28).** A gap is either listed here or it is
not a known gap. When you close one, delete the entry in the same commit.

Not listed here, deliberately: bugs (those are fixed, not documented) and
error-tolerance decisions (PasTree analyzes broken source on purpose - see the
README's own section on that). Two neighbours hold the rest: the facts a
parse keeps only in a token, which a consumer still reads there
(`docs/tree-contract.md` sec. 4 - a few of them are also entries below, by
section), and the parser-fidelity findings still open with what the checks
against dcc cannot see (`docs/parser-fidelity.md`).

Not listed either: what light mode leaves out on purpose
(`TPasSemaProject.LightPaths` - a library unit analyzed interface-only, its
text read to the end of its implementation `uses`). That is a host's choice
of less work, not a gap in following the language; its consequences are in
`docs/library-light-mode.md`. Every entry below holds in both modes.

---

## 01-program-structure.md

### 1.2.3 Qualified name resolution
- a unit qualifier's missing member (`System.Missing`, `ThisUnit.Missing`) is
  E2003 except inside a `with` body, a method body or a type declaration: a
  name that reads as a unit qualifier there may be a with member or an
  inherited member, which only later passes decide, so the verdict is not
  given. dcc reports those too.

### 1.3.1 Switch & parameter directives
- every switch is TRACKED - the letters `A`..`Z`, groups (`{$R+,Q-}`), the
  long forms, `{$PUSHOPT}` / `{$POPOPT}` and the host's start state - but
  only three change what the analysis computes, each by position:
  `{$SCOPEDENUMS}` (enum value names), `{$Z}` / `{$MINENUMSIZE}` (enum size)
  and `{$A}` / `{$ALIGN}` (record field alignment). Every other switch is
  read by `{$IFOPT}` alone. Not modelled, and not yet probed on dcc for what
  each changes:
  - `{$H-}` / `{$LONGSTRINGS OFF}`: a bare `string` is `ShortString` - its
    size, its element type, overload choice and the type an inline `var`
    infers;
  - `{$T+}` / `{$TYPEDADDRESS ON}`: `@X` is a typed pointer `^T`, not
    `Pointer` - assignment compatibility and overload choice;
  - `{$X-}` / `{$EXTENDEDSYNTAX OFF}`: a function called as a statement,
    `Result` and the PChar extensions are not available;
  - `{$J+}` / `{$WRITEABLECONST ON}`: a typed constant may be assigned;
  - `{$P+}` / `{$OPENSTRINGS ON}`: a `var` string parameter is an open
    string;
  - `{$V-}` / `{$VARSTRINGCHECKS OFF}`: a `var` short-string parameter
    takes any short-string length;
  - `{$B+}` / `{$BOOLEVAL ON}` and the code-generation and checking
    switches (`$O`, `$R`, `$Q`, `$I`, `$C`, `$D`, `$L`, `$Y`, `$W`, `$U`,
    `$G`, `$M`, `$S`): no effect on names or types expected, only on the
    code dcc emits (`$M` aside: RTTI, 19.1.1).
  The order for each is the usual one: the spec's 1.3.1 first, a dcc probe
  for what it leaves open, then the code.

### 1.3.2 Conditional compilation
- strict IFEND-vs-ENDIF pairing is not implemented -
  `$IFEND` and `$ENDIF` are treated as the same terminator unconditionally,
  and `{$LEGACYIFEND}` is passthrough trivia; the strict pairing check is not
  available even as an opt-in.
- the predefined sets (`PasTree.Platforms`) are the installed dcc 37.0
  compilers' answers for eight targets; Linux64's and WinArm64's are not
  probed (no compiler installed): Linux64 follows the other LLVM targets,
  WinArm64 the release notes. They are 37.0's for every compiler version a
  project names - an older version's set (no `MANAGED_RECORD` before 10.4)
  is not modelled.
- a shipped unit is evaluated under the project's defines, not the ones its
  own `.dcu` was built with. No corpus shows a difference: the one case that
  looked like it (`CPP_ABI_ADJUST`, 24 on Win64) is defined by System.pas
  itself, and PasTree's wrong value there was a stale read, fixed (F25).
- `Declared(TE.e2)` over a type the asking unit declares itself reads False:
  the unit's own declarations answer Declared() by position only for a bare
  name and one its own unit name qualifies (`Declared(UQ.X)`); a type's
  member is answered for an imported type. dcc answers it True when TE
  stands above the guard.
- `Length` in a `$IF` refuses an array whose index type is written
  qualified (`array[UC.TE]`): the ordinal walk takes a bare type name, and
  the first-pass guess (0) stands.
- a `$IF` computes in Double: integers past 2^53 compare by their nearest
  Double, so `$8000000000000000 > $7FFFFFFFFFFFFFFF` reads False where dcc
  says True (both round to 2^63). No such guard is known in a corpus.
- `High` / `Low` in a `$IF` fold for a builtin ordinal, an enum, a subrange
  and an alias of one; of an array or a value they stay a guess, and a
  character subrange answers its ordinals, which compare with nothing.
- CONSOLE follows the MAIN program only: `AnalyzeDirectory` has none, so
  there every unit and program sees CONSOLE exactly when the host's
  `ConsoleTarget` (-CC) is set, whatever a `.dpr` in the directory says; a
  library's or a package's `{$APPTYPE}` decides nothing.
- the switch start state is what the host sets (`SwitchStart`): a `.dproj`
  gives its DCC_* switch properties (`TPasDProj.Switches`), a bare `.dpr`
  dcc's no-config state. A `dcc64.cfg` beside the project, which plain dcc
  reads and msbuild's `--no-config` does not, is not read.
- a conditional symbol folds case as an identifier does (spec B.3,
  PasFoldChar). dcc folds a symbol name more on 14 of 1925 probed letter
  pairs (a title-case digraph, the final sigma, three Greek symbol
  variants, the ohm, Angstrom and capital sharp s signs; spec 1.3.2):
  `{$DEFINE <U+01C5>X}` then `{$IFDEF <U+01C6>X}` is true for dcc, false
  here.

### 1.3.3 Include files
- dcc 37.0 has no insertion form: `{$I %DATE%}` names the file
  `%DATE%.pas`, read as such (F1026 when it is not there).
- an include is looked up as dcc 37.0 does (beside the unit, the project
  directory, the search paths) and then, where dcc finds nothing (F1026),
  beside the include file that names it - a tolerance: it never picks
  another file than dcc's, but accepts a layout dcc refuses. A name with no
  extension is dcc's `name.pas`; the bare `name` is a further tolerance,
  after that whole sweep missed. A host's unsaved buffer is a file. The
  project directory stands for dcc's current directory, and the search
  paths for its `-I` (the IDE passes one path to both `-U` and `-I`); a
  project that sets a separate include path is read with its unit path.
- a missing or recursive include is reported in dcc's words (F1026,
  E2245), and like an unresolved import it gates the unit's E2003s - its
  declarations are missing, not the names after it. dcc stops at the
  F1026; the rest of the unit is still analyzed here. The preprocessor's
  other rows are dcc's too: E1030 for an `{$ELSE}`/`{$ENDIF}` with
  nothing open, E2280 for an unterminated conditional, W1078 for a lone
  `{$POPOPT}`. An include nested deeper than PasTree's limit gates the
  E2003s but has no row of its own.
- the text after the final `end.` produces no lexer row; dcc's W1011
  for it is not reported.
- a conditional that crosses an include boundary - opened in an include
  and closed by its includer, or an include's `$ELSE`/`$ELSEIF`/`$ENDIF`
  on the includer's conditional - is refused by dcc 37.0 (E2280, or a
  garbled includer) and diagnosed in the preprocessor's rows
  (ppUnterminatedConditional at the include, ppCrossIncludeConditional;
  only the first reaches a model, as E2280), but read as one stack: the tokens
  follow what the author evidently meant, not dcc's recovery.

### 1.3.5 Compiler-version symbols
- the VERxxx symbol and CompilerVersion/RTLVersion follow the one
  compiler version a project is created with (default 37.0); a host
  cannot mix versions inside one project, and no other version-dependent
  behaviour (language features gated per release) is emulated.

## 02-fundamental-types.md

### 2.2.1 Integer types
- on the LP64 targets LongInt / LongWord are seeded as 8-byte types of their
  own, and sized, cast and ranked so; overload choice has no width
  preference beyond exact identity, so `F(Lg)` against F(Integer) and
  F(Int64) - dcc takes F(Int64) - ties, and the first declared wins. The
  Linux64 facts (LongInt 8, Extended 16 aligned to 16) are Embarcadero's
  table; no dcclinux64 was installed to probe them.

### 2.2.4 Enumerated types
- the layout oracle refuses enums containing negative
  explicit ordinals, so a `$IF SizeOf(...)` over such an enum stays a guess.
- an unscoped enum's value that takes a name already declared where it
  counts - or that a later declaration takes - is E2004, but not for an enum
  written after an include that did not load: that file may switch
  SCOPEDENUMS on, so its values clash with nothing (CollectEnum). dcc would
  stop at the missing include anyway.

### 2.2.5 Subrange types
- a subrange's category comes from its LOW bound: a literal, True / False,
  an enumeration value or a constant (followed to its value), in this unit
  or another. A bound that is an expression (`Ord(X)..`, `N + 1..`) leaves
  the type uncategorized, which every check reads as "say nothing", and a
  subrange argument scores against its base type as any other type of its
  category would (no exact match).

### 2.3.1 Real types
- `Extended80` is sized 10 aligned to 8, or as the 16-byte `Extended` where
  that is the target's: on OSXARM64 dcc aligns its 10 bytes to 16, a fact
  the target record does not carry, so a `SizeOf` of a record holding one
  is short there.

### 2.5.1 Type aliases - weak vs. distinct
- the parser marks distinctness (Aux=1); CanonTypeX and the helper map stop
  there, and the operator table computes a distinct number in its base's
  storage (StorageBaseX - `TMyI64 + TMyI64` is Int64, `not MW` keeps
  TMyW). What is not modelled is assignment identity: a distinct type is
  assignable wherever its base is.

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
  arguments (dcc's E2035), a call WITH an argument list whose overload
  selection tied between different result types (a paren-less call of two
  overloads tied on defaulted parameters - dcc's E2251 - is typed by the
  first), a bare type name (a class reference with no named
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
  otherwise). An OPERATOR initializer is typed from its operands with the
  4.2.1 rules (OperatorResultX), literals read exactly - `var X :=
  5000000000 + 1` is an Int64. The Currency rule was probed on Win64 only;
  the other 64-bit targets are assumed to share it.
- an inline declaration or a routine's local that takes a name its body
  already holds is E2004 (dcc64 37.0), and PasTree reports it
  (RedeclaresBodyName, RoutineHolds) but for three shapes that pass without
  a diagnostic: a parameter named Self, one named like the method's own type
  parameter - dcc reports both once, at the body's begin - and `Self` in a
  class method, which a static one does not have and only its declaration
  says which.

### 3.2.1 True constants
- a section-level `const C = Expr` is typed from its initializer in the
  declared-type pass (BindTypesX), so another unit's `C.ToString` binds; the
  same literal, operator (4.2.1) and intrinsic (4.11.4) rules as 3.1.3
  apply, whether the operands are literals or other constants.
- what PasTree gives a true constant is the type an inline `var X := C`
  would get - dcc's WIDENED answer - not the constant's own type, which dcc
  keeps narrower and which is what a member lookup on the constant sees
  (the spec's 3.2.1 table): an integer constant is sized by its VALUE
  (`100` finds TShortIntHelper, `200` TByteHelper, `Ord('A')` TWordHelper,
  `High(Byte)` TByteHelper - here all TIntegerHelper), a Currency-shaped
  real literal is Currency on Win32 too, `Double(1.5)` is Extended, and a
  folded `not Byte(5)` is a signed value, not a Byte. Modelling it needs a
  constant folder, which PasTree does not have; the navigation that results
  lands on a sibling helper of the same family, never on nothing.
- a set constructor (`[1, 2]`, `[meA, meB]`) and `nil` give a constant no
  type: dcc's are anonymous, and nothing in PasTree can name them.

### 3.2.2 Typed constants
- an aggregate label that names no field of its record (`C: TRec = (A: 1;
  Zz: 2)`) is not reported: dcc's E2003 there is left out, so a typo in a
  label is silent. Every label that does name a field is bound - a record
  from any unit, an array of records per dimension, an anonymous record.

## 04-expressions-operators.md

### 4.2.1 Result type of an operator expression
- one rule table (OperatorAnswer in PasTree.Sema.Types) serves both typers:
  the intra-unit one inside a body, OperatorResultX at the project level for
  the positions the first leaves untyped - an operand that is a true
  constant or another unit's name - and for every inline-var initializer.
  An operand that Phase 1 bound to a TYPE name (an inherited cross-unit
  member named `Word`) types the operator as nothing and is not judged.
- an arithmetic result over two Bytes or Words is an anonymous subrange of
  Integer in dcc, and so is `B and 300` (dcc's E2010 names both Integer,
  but its overload resolution then prefers a narrower parameter); PasTree
  says Integer. A rankless subrange operand computes as an Integer
  (`Sub and Sub` over `0..9` is ShortInt in dcc). A true constant
  operand adapts to the other operand by its value only when it is a
  literal or names one - a folded constant expression (`N + 1` in a
  constant) is read as its declared shape. `AnsiChar + AnsiChar` (dcc's
  anonymous short string) is typed ShortString; pointer minus pointer is
  left untyped. The intra-unit typer cannot tell a code-page string declared
  in another unit (UTF8String, RawByteString) from a plain AnsiString-kind
  type it does not see, so those joins are the project level's.

### 4.9 Type-test & type-cast operators (`is`, `as`)
- a type name on the right of `is` ends that operand (`O is TFoo and C` is
  `(O is TFoo) and C`), any other operand follows the precedence table - and
  which names are types is not known to the parser, so a NAME-SHAPED operand
  (an identifier, a dotted chain, type arguments) is taken for a type. dcc
  compiles one shape that groups otherwise: a name-shaped VALUE whose
  overloaded operator yields a class reference - `O is R and C` with R a
  record variable (or a parameterless function returning one) and a `class
  operator LogicalAnd(...): TClass` is `O is (R and C)` for dcc, `(O is R) and
  C` in the tree. Written `O is (R) and C` or `O is RA[0] and C` it parses as
  dcc groups it (dcc64 37.0, probed 2026-09-26).

### 4.11.4 Result types of the value-returning intrinsics
- the result rules are implemented in both typers from the spec's probe
  table, with these edges left out: `Ord` of an enumeration or subrange
  reads its range only from literal bounds and values, enumeration values
  and true constants naming them - a bound or an explicit value that is an
  expression (`N + 1`, `Ord(X)`) leaves the range unknown and `Ord` Integer;
  `Abs` of a subrange past 32 bits reads Integer where dcc says Int64;
  `GetTypeKind` is typed at the
  project level only (System.TTypeKind is a real declaration the intra-unit
  typer cannot see); `Slice` stays untyped (it is legal in one position only,
  where its type is never read); the intra-unit typer gives `Pred` /
  `Succ` of an enumeration subrange bounded by ANOTHER unit's value the
  subrange, which the project pass then types as its base.
- a VALUE-taking intrinsic whose argument resolved to a TYPE NAME (a member
  named `Word` bound to the builtin, the CheckAssign mis-binding case) types
  as nothing rather than as that type.

## 4.12 Operator overloading (cross-reference)
- declared `class operator` overloads are never consulted
  by the analyzer's typing - non-scalar operands are exempted wholesale from
  operator checks.

## 05-statements.md

### 5.4.1 Inline `if` expression
- the branches are unified by the spec's rule in both typers; a pair the
  rule leaves open - an integer with a real (dcc rejects one order and
  accepts the other), two classes neither descending from the other, two
  unrelated string kinds - is untyped, and the intra-unit typer leaves any
  two different classes to the project, which sees the whole ancestry.

### 5.5.2 `for … in` (for-in loop)
- an untyped `for var E in C` element is typed from the collection at the
  project level only (arrays incl. `TArray<T>`, strings, sets, and a
  class/record/interface's `GetEnumerator` result's `Current` property); the
  intra-unit typer still has no ExprType for it, and a `GetEnumerator`
  supplied by a helper on a non-struct type is not chased.

### 5.7 The `with` statement
- the target is typed by the project's expression walk (the same one the
  cross-type pass runs, as a probe over the target's subtree), so every
  designator form that walk types is a legal target; the two position rules
  dcc adds are NOT modelled: a parenthesised target (`with (R) do`) is opened
  like `R` and writes to its members are not refused (dcc: E2064), and a
  pointer written without `^` (`with P do`) is opened over the pointee where
  dcc reports E2018. A non-struct target gets no E2018 either - the body's
  names simply resolve in the enclosing scope.
- the intra-unit resolver opens only member sets it can see in its own unit;
  a target of a cross-unit type, or a same-unit type with a cross-unit
  ancestor, is completed by the project pass. Navigation before the project
  pass has run therefore sees a subset.

## 06-routines.md

### 6.3.1 The `overload` directive
- which declaration an implementation header completes is decided by
  parameter modes and type identity as far as the unit itself can follow
  it (plain aliases declared in the unit). A type named through another
  unit's alias is compared by name: an `overload` header spelling one so
  completes the one declaration all of whose other slots match, and
  stays a routine of its own when two are as likely (the resolver's
  CompletionOf).
- overload resolution is a conservative
  arity-plus-assignability score, not formal betterness ranking; ties go to
  the first candidate. A tie between candidates with DIFFERENT result types
  is recorded (CrossType's LAmbig) and refuses inline-var inference from the
  call, but the call node itself still carries the first candidate's type.
  A few corners are decided rather than scored: a scalar argument (integer,
  float, Boolean, Char, string) rejects a class, interface or class-reference
  parameter, an enumeration and another scalar reject each other, and a
  one-character literal - a Char constant, in parentheses and as both
  branches of an inline `if` too, never the joint `#13#10` - scores a Char
  parameter above a string one and a string one above AnsiChar (both passes
  type literals `string`). An anonymous-method literal or a procedure
  designator rejects a non-procedural parameter, two distinct records (no
  conversion operator) reject each other, and so do an array and a record,
  class or interface. One type under two seeded names (Integer / LongInt,
  Char / WideChar, PChar / PWideChar, a native integer and its sized twin),
  and a weak alias and its target, are an exact match - the unit pass chases
  aliases declared in the unit only. A call whose every arity-fitting local
  candidate is rejected stays untyped in the unit pass. Both scorers share
  these rules (Sema.Types: ArgShapeRejects, ArgCatRejects, ArgStructRejects,
  IsCharLiteralExpr, CallArgCount). Other non-assignable scalar pairs (a Boolean argument for a
  Cardinal parameter) are scored 0, not rejected, and a helper's overloads
  are not merged with the extended type's own (`TGUID.Create` from
  TGUIDHelper binds a helper overload, not System's). A
  distinct alias (`TId = type Integer`) is still only "assignable" from its
  base, so it wins over an overload the argument fits no better, not over
  an exact one. A `[...]` argument (set, open array or dynamic array
  constructor) rejects a parameter it cannot be passed to - a string, a
  scalar, a pointer, an enum, a class, an interface, a class reference, a
  procedural type - so it picks the open-array, set or dynamic-array overload
  in either declaration order (dcc32 37.0 probed); a record or Variant
  parameter is still only scored.
- a bare routine name in a value position - a member qualifier, a `with`
  target or an inline initializer - means the overload that needs no
  argument (6.6.1): one with no parameters, else one whose parameters all
  have defaults; a method's set on the qualifying or enclosing type and its
  ancestors, a unit-level routine's set across the units its search meets.
  The same rule is NOT applied in other value positions (an argument, an
  assignment's right side), where the first-declared overload still wins.
- the argument-count check measures a bare call against every used unit's
  routines of the name whether or not the set found first says `overload`
  (dcc stops at a set without it, and admits a later routine only when it
  is overloaded itself - E2250). Only System's and SysInit's routines follow
  the rule; for a used unit the check stays lenient, so `F(1.5)` beside a
  plain `F(D: Double)` of a used unit and the unit's own `F(X: Integer);
  overload;` is not reported.

## 6.10 Inline assembly (`asm … end`)
- where an asm body ends is decided by the preprocessor, which knows the
  live branches (F26): only live text switches the mode, dead text is
  scanned as Pascal even inside an asm body, and the mode runs on through
  an include, as dcc does. `TPasLexer.Tokenize` used on its own - no
  preprocessor, as `ParseExpressionText` and a highlighter without a model
  use it - still guesses: an `asm` opened in a conditional branch is closed
  by that branch's `$ELSE`, and a dead `asm` or `end` switches the mode.

## 07-strings.md

### 7.1.2 `AnsiString` (with code page)
- `AnsiString(codepage)` declarations parse via the
  generic call-selector path (an nkCall in type position); there is no
  dedicated AST shape for the codepage clause.

### 7.2.1 String indexing
- an element of a 1-byte string or a PAnsiChar is AnsiChar everywhere; dcc
  types it so too but, beside an `AnsiString` overload, calls that overload
  for `F(PA[0])`, `F(S20[1])` of a `string[N]` and `F(Cy[1])` of a code-page
  string (not for `F(A[1])` or `F(PA^)`) - PasTree binds the AnsiChar one
  there.

## 08-arrays.md

### 8.1.2 Multidimensional static arrays
- index expressions are untyped by the intra-unit typer (no ExprType
  case); the project level peels one level per index expression, a chain
  from its root, and leaves an anonymous row (`J[1]` over `array of array
  of T`) untyped - no E2018 is reported on a member after one. A
  multi-dimensional row (`High(M[0])` of `array[a, b] of T`) has no bounds
  type.

## 09-records.md

### 9.1.2 Record layout (the `$IF SizeOf` oracle)
- a field's type name resolves where the record is written only as far as
  interface vs implementation: a type local to a routine, and a class's or
  object's ancestor, resolve from the implementation scope.
- a used unit's type named like a builtin (`Text`, `Single`) loses to the
  builtin: the oracle's lookup meets System's seeded name before the
  imports. The unit's own declaration wins, as in dcc.
- `SizeOf` of an instantiation in a `$IF` takes a bare generic name and
  plain names as its actuals; a qualified head or a nested instantiation
  (`TPair<Byte, TList<Integer>>`) stays a guess.

## 11-classes.md

### 11.2.1 `private` / `protected` / `public` / `published` (+ `strict`)
- visibility enforcement is opt-in (ReportVisibility) and
  covers only private/strict-private on QUALIFIED access; protected (E2362)
  and the descendant bare-name case are not enforced, and ordinary name
  lookup never filters by visibility.

## 12-inheritance-polymorphism.md

### 12.1.2 `inherited`
- a general `inherited X` expression is not typed
  intra-unit; only with-target usage is modeled.
- a bare `inherited` in a `message` method is looked up by the method's
  name; dcc dispatches it by the message id (the ancestor's handler of that
  id, whatever its name, else DefaultHandler), so Go To on it and its typing
  as a value can name the wrong method or none.

## 13-properties-events.md

### 13.1.3 Indexed properties (`index` directive)
- the `index` specifier's dispatch typing is not modeled;
  accessors are resolved as names only. On the completion overlay a default
  array property of a type declared in the edited unit is read off that
  type's last-good analysis, so one typed since then is not seen.

### 13.1.4 Default array properties
- `L[I]` is a use of L's default array property with no name written: bound
  by CrossType, keyed on the nkIndex node (a Find References hit at the `[`,
  `Implicit`). The property is the first one `DefaultArrayPropX` meets up
  the ancestors - two default properties overloaded by index type are not
  told apart. A class helper's default property is not consulted. A comma
  list carried from an array into a default property (`A[0, 1]` over
  `array of TCells`) is dcc's E2016 (object-pascal-spec 13.1.4); PasTree
  types and binds it leniently, through the property.

## 14-interfaces.md

### 14.1.1 The GUID clause
- whether the first bracket after `interface` is the GUID or the first
  member's attribute group is dcc's call by what its name binds to (a true
  constant is the GUID, an attribute class an attribute). The tree keeps
  one shape: a bracket that starts with a string or `(`, or a name, dotted
  or not, followed by `]` or `+`, is an nkGuid; the resolver binds the name
  as an attribute's, suffix first, as dcc does - so `[Mark]` is a reference
  to MarkAttribute and `[Unit.SID]` to the constant - but the node stays an
  nkGuid, not an attribute group of the first member. Not modelled: a typed
  TGUID constant (`[GT]`) is dropped by dcc (W1074, no GUID), and a comma
  list in that bracket (`[GT, S]`, S's GUID) is read as an attribute group.

### 14.2.1 Classes implementing interfaces
- heritage walks (member lookup, descent checks) follow
  only the FIRST heritage entry - a class's implemented interfaces (second
  and later entries) are invisible to member search and descent tests.

## 15-class-mechanics-helpers.md

### 15.2.1 `class of` types
- member/constructor access through a metaclass value is
  not typed intra-unit, and the project-level walk reaches instance members
  through `class of` values without filtering them out.

### 15.3.3 Helper scope-resolution rule
- the active helper is decided per unit, not per position: a unit's own
  helper declared below a routine body already applies in it, and with two
  helpers for one type in a unit the later one applies above it too (dcc
  counts only the helpers declared before the position).
- in a `with` over a record of the unit itself whose helper lives in a unit
  that uses this one, a helper member named like a declaration of the
  enclosing scope keeps that declaration.

## 16-generics.md

### 16.3.1 Generic instantiation syntax
- there is no intra-unit instantiation - members of
  `TList<TFoo>` type as the open generic's members; project-level frames
  exist, and on the completion overlay an own-unit generic written with
  arguments takes its last-good twin's frame (`class(TList<T>)`,
  `class(TSensor<TCustomLocationSensor>)`); a generic or an argument the
  last analysis never saw stays unsubstituted - the overlay generic's
  members, its parameters open.
- `Id<...>` in an expression is told from a comparison by syntax, where dcc
  decides by what the head names (spec 16.3.1): `F(A < B, C > (D))` - two
  comparisons for dcc - is read as a generic call or cast with one
  argument (the corpora hold none of those and several generic calls of
  that shape), and a Variant chain `VA < VB > -VC` written after a member
  (`R.VA < ...`) as type arguments.

### 16.4.1 Type-parameter constraints
- interface constraints and the `constructor` constraint
  are not validated at instantiation sites (class/record/class-type
  constraints are); constraint members are available for lookup.
- an explicitly instantiated generic METHOD (`F.Pick<TObject>(O)`) is checked
  against the overload the call bound; a call whose overload is not decided
  is not checked.
- a class-type constraint (and the attribute check of 19.3.2) is reported
  only when the argument's ancestry is followed to its end: an ancestor
  that does not resolve - its unit missing from the search path - leaves
  the argument unchecked, where dcc would know.
- a lone `constructor` constraint unlocks `T.Create` and no other member,
  as in dcc; the member walk does not tell the type `T` from a value `V: T`,
  so `V.Create` (dcc: E2003) is accepted and completion lists `Create` on
  `V.` too.

### 16.5.1 Inference for generic methods & inline vars
- inference handles only the direct shape (the
  parameter's declared type IS the type parameter); structural matching
  (`TArray<T>` against `TArray<Integer>`) is not implemented.

## 17-anonymous-methods.md

### 17.2.1 Inline `procedure`/`function` literals
- no contextual signature inference for anonymous method
  literals; `Result` is typed only when the result type is written
  explicitly.

## 19-rtti-attributes.md

### 19.3.2 Applying attributes
- an attribute is a name with its arguments or ONE expression (the
  expression form dcc drops with W1074). dcc is wider still: after a name
  that is no attribute class it skips tokens up to the `,` or `]` - `[C + + ]`
  and `[C (]` compile - and PasTree reads an expression there, so token runs
  that are no expression are parse errors. `[C < 1]` reads as type arguments.
- a name attribute that names no attribute class is W1074 for dcc and
  dropped; PasTree reports no warning. As dcc, it gives no E2003 for a name
  that starts with an undeclared identifier nor in the arguments of one
  naming no type (`[C(Undeclared)]`); a unit qualifier's missing member is
  E2003 (`[System.Undeclared]`), within the limits of 1.2.3.
- a target before an attribute is read for any word followed by `:`
  (`[Result: Tag]`; dcc drops one with another word, and PasTree binds no
  name in it); dcc's E2289 for `Result:` before anything but a function is
  not reported, nor its `E2029 ':' expected` for `[Result]` alone, and an
  expression before the colon (`[1: Tag]`, W1074 for dcc) is a parse error.
- `[X]` binds `XAttribute` first, in the unit, the used units and System,
  as dcc does - except on a parameter of a method's implementation header,
  where a name the unit does not declare goes to the inherited pass, which
  looks the bare name up first. An attribute's arguments are not checked
  against its constructors (dcc's E2010 for `[Bar(1, 2)]` against
  `Create(const S: string)`).

## 20-memory-management.md

### 20.3.1 The managed-type set
- the managed-type test ignores generic instantiation
  frames (a record instantiated with a managed argument reads as unmanaged
  when the field's declared type is the open parameter) and does not follow
  `= type X` distinct aliases.

## B-lexical-grammar.md

### B.3 Identifiers & case rules
- identifier characters are dcc's (every non-surrogate unit from $80 up), in
  the lexer, the conditional-symbol scan, rename's name check, the outline's
  spans and lint; case folding is still ASCII only, so a define tested with
  another case of a non-ASCII letter (`{$IFDEF` a-umlaut X after
  `{$DEFINE` A-umlaut X) is not defined, where dcc folds it (audit B65).

### B.6.1 Quoted string & character literals
- the lexer emits adjacent string elements as separate
  tokens by design (full-fidelity contract); folding them into one literal is
  the consumer's job.

### B.6.2 Caret control characters
- `^` + a letter (`^M`) is two raw tokens, caret and identifier; the parser
  decides caret char vs pointer type vs dereference positionally. `^` + a
  printable non-letter (`^[ ^^ ^? ^1`) is one `tkCaretChar` token when the
  caret cannot be a postfix dereference. The lexer judges that from the
  tokens before it, not the position: a reserved-word member (`TC.Array^[0]`)
  and a generic call's closing `>` (`GetA<Integer>^[1]`, a bounded scan back
  to its `<`) end an operand; of the directive words that take a constant
  only `default` and `name` make the caret a character (`default ^[`).
- dcc also takes whitespace after the caret (`^ ` is chr 96, `^` + CR is
  `M`); PasTree reports "control character expected" instead - a token
  spanning a newline would break every line-based consumer, and no real
  code writes it.
- `^{`, `^(` and `^//` are not caret chars either: `{`, `(*` and `//` keep
  opening comments and directives, because real code glues a directive to a
  pointer-type caret (`{$IFNDEF CLR}^{$ENDIF}TBitmap` in the VCL).
- `^Mx` is diagnosed as one node over `^Mx` ("takes exactly one character")
  rather than split into `^M` and a stray `x` as dcc does.

