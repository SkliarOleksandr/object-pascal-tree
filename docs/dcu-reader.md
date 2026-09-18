# Reading `.dcu` files: findings, the decision, what was built

Status: **shipped 2026-09-17 (v0.37.0), values and modifiers added 2026-09-18 (v0.38.0)** - `source/PasTree.Dcu.pas` reads a
compiled unit, `source/PasTree.Dcu.Source.pas` prints its interface section,
and `TPasSourceManager` falls back to a `.dcu` when no `.pas` exists for a
unit name. This is README stage 3 of "units with no source": when a
third-party library ships only `.dcu`, every importer used to get `F1027` and
its diagnostics were gated off, so the unit read as clean when it was never
analyzed. Now the unit's declarations come from the `.dcu` itself, as
generated interface text fed to the ordinary pipeline, so nothing downstream
knows they did not come from a file. The first two sections below are the
probe that made the decision; the last is what exists and where it stops.

## What the probe established

The README budgeted this as "reverse-engineer against samples, nothing
published covers 37.0". A one-day probe with the public DCU32INT parser
(Alexei Hmelnov's reverse engineering, maintained in forks up to Delphi 11.3)
showed the gap to Delphi 12 and 13 is small and additive:

- The version byte in the magic is `$23` = 11, `$24` = 12, `$25` = 13 (the
  header reads `4D 03 00 xx` for Win32, `4D 23 00 xx` for Win64). Delphi 12
  and 13 needed the same set of changes; not one difference between them was
  found. Win32 and Win64 differ only in that platform byte.
- Every 11 -> 12 change is a field added to an existing record, encoded like
  everything else (the variable-length "UIndex" integer). No record moved, no
  tag changed meaning. Strings in the new fields are `<UIndex len+1> <chars>`,
  0 meaning no string.
- After porting those fields, the parser decodes every unit of the RTL,
  VCL, FMX, FireDAC and the rest of `lib\<platform>\release` for Studio 22.0,
  23.0 and 37.0, Win32 and Win64, to the end: 1639 / 1790 / 1805 units on
  Win64, 1508 / 1721 / 1736 on Win32, zero failures, zero unresolved types in
  the interface text.
- The probe also found and fixed a numbering bug the public parser had since
  Delphi 11 (address-table drift that misattributed property accessors), which
  is why its baseline on Delphi 11 was 1545 of 1639 before the fix.

The additive fields, by record, are the working knowledge a reader of our own
needs beyond the public description of the format:

| Record | Added in 12 |
|---|---|
| ConstAddInfo (`$9C`) | subtag `$17`: `<hDef> <kind> <payload>`; kinds 1 `<idx> 0`, 4 `0`, 6 `<str name> <str unit> 0` (a type aliased from another unit), 10 `<str> <idx> 0`; a leading kind 0 wraps one item without the closing 0 |
| ConstAddInfo subtag `$10` | its second index can point one slot ahead of the address table (generic method instantiations); the slot must be reserved |
| Export (`$69`) | one more index at the end |
| Class definition (`$46`), interface table | a string per implemented interface (holds the interface name for imported ones) |
| Generic parameter list (`$A7`) | after every parameter: `<kind> [payload]`, same kind table as `$17` |
| Template call (`$5A`) | after every type argument: the same `<kind> [payload]` |

Two facts about the address table that are not version specific but were
wrong in the public parser: inside a standalone template parameter list the
copy records (`$A3`) take no slot while the type-parameter records (`$2A`)
do; and a property accessor may reference a member several slots ahead, so a
forward reference reserves every slot up to it, each later claimed by its own
ProcAddInfo anchor.

The working paper with the byte-level evidence, the patched parser, the
sweep script and the per-unit outputs lives in `local/dcu32int/` (ignored).

## Decision: our own reader, the patched parser as the oracle

Three options were weighed:

1. **Vendor the parser's files.** Its notice permits it (use for any purpose,
   alter and redistribute, keep the notice, mark altered versions; compatible
   with this repository's MIT). But the parsing core is 16 thousand lines of
   2000s-era Delphi built around global state (current unit, scan position,
   current tag), text output through a global writer, and the disassembler
   and fixup machinery it cannot be separated from without rewriting. It does
   not fit a library that analyzes in parallel under a single-owner contract.
2. **Drive the external executable and parse its text.** No licence question
   at all, but the text is a decompiler's rendering (qualified accessor names,
   backquoted generic arity, cast-wrapped constants, truncated long names),
   and a process per unit. Acceptable as a stopgap only.
3. **Write our own module.** The format is a fact, not a work; we copy no
   code. Scope it to what the analyzer needs and stop there: unit name, uses,
   exported constants, types (classes, interfaces, records, enums, sets,
   arrays, pointers, procedural types, generics as name plus arity), variables,
   routine headers with calling convention, class and interface members with
   visibility, property accessors. Code, fixups, line tables, debug info and
   the implementation part are out of scope and never read.

Option 3 is the decision. Estimated size is three to four thousand lines,
reading straight into PasTree symbols rather than into text.

The patched parser stays in `local/` as the **oracle**: for every RTL unit of
every installed Studio there is a reference interface text, and the regression
gate for our reader is a differential over the whole `lib` directory, the same
way the completion oracle worked. The two things the probe proved most
valuable carry over as test tooling: a tag trace (`<offset> <tag>` for every
record read) and the drift detector (every ConstAddInfo names its target by
address index, so a trace of slot assignments against those indices pins the
first record whose numbering disagrees with the compiler's). When a new
Studio version arrives, the method is: run the same unit through the previous
version's reader, diff the tag streams, and the last tag before the failure is
the record that grew.

Attribution: the README will state that the format knowledge draws on
DCU32INT by Alexei Hmelnov. The notice does not require it for a reader that
shares no code; it is owed anyway.

## What was built

Two units and one fallback, in the shape the decision above asked for, with
one change of plan: the reader does not produce symbols, it produces
declarations that a printer turns into **interface source text**, and the
ordinary lexer, parser and resolver do the rest. That is one printer instead
of a second symbol-table builder, positions in the text are real positions
(Ctrl+Click on a member lands on its line), and every existing feature -
completion, references, rename refusal on library paths, the outline - works
on such a unit without knowing where it came from.

- **`PasTree.Dcu`** (~1900 lines): the format reader. Accepts version bytes
  `$23`..`$25` (Delphi 11, 12, 13) on Win32 and Win64 and refuses anything
  else by name (`DcuVersionName`). Reads the header, the source-file list,
  the three uses lists with their imports, and the declaration list with
  every record kind the three Studios write; keeps the data block and the
  fixup table (the values of typed constants are read from them, see below)
  and skips line tables, debug tables and inline bodies for their length only. The
  three tables (address slots, type entries, uses) are reproduced exactly,
  including the two numbering rules the probe found (`DropLastAddr`,
  `ReserveAddr`). `LoadDcu(path, trace)` gives the `<offset> <tag>` stream
  and the slot events the probe method needs for the next compiler version.
  Branches for compilers older than Delphi 11 were deliberately not carried
  over: a branch no test exercises is where a silent misread hides.
- **`PasTree.Dcu.Source`** (~2200 lines): `DcuInterfaceSource(unit)`. Prints
  `unit X; interface uses ...; <declarations> implementation end.` -
  constants with values, types of every kind (classes, records, objects,
  interfaces and dispinterfaces with GUIDs, enumerations from their member
  constants, sets, arrays, pointers, procedural and method-pointer types,
  anonymous method types (`reference to`, stored as an interface with an
  `Invoke` method and a flag), generics with recovered parameter names,
  class and record helpers (stored as a metaclass whose target is the helped
  type), generic instantiations `TList<Integer>`), variables, routine headers
  with calling convention, `overload`, `inline`, default parameter values
  (an unnamed constant in the parameter list bound by a `$9A` row), members
  with visibility, `virtual`/`override`/`dynamic`/`message`, `static`, class
  constructors (`Create@`), operators (`&op_Addition` -> `class operator
  Add`), properties with `index`/`read`/`write`/`stored`/`default`, array
  properties, redeclarations, `dispid`, hint directives. Names from other
  units are qualified only where the name is imported from more than one
  unit or also declared locally. Reserved words used as names get `&`.
- **The fallback** (`TPasSourceManager`): the search-path index now lists
  `.dcu` files too; `ResolveUnit` tries them LAST - a `.pas` anywhere beats
  a `.dcu` anywhere, so a library shipping both is analyzed from source.
  `LoadText` of a `.dcu` path returns the generated text (cached per path),
  `LoadFileTolerant` does the same for a host, `IsDcuPath` tells a host to
  show the tab read-only (the demo does). A `.dcu` the reader refuses makes
  its importer's `F1027` say so: `its .dcu could not be read: Delphi 10.4 is
  not supported` (`SF1027_UnitDcuUnreadable`) rather than "no source".

**What the text does not carry, said where it would be.** A type the
printer cannot resolve is spelled `__PasTreeUnresolved`, declared nowhere, so
each use is an honest `E2003` in the generated unit; the header comment lists
every such fallback. A typed constant whose value cannot be laid out (see
"Values in the data block" below) is printed as `var X: T;` with the reason in
a comment, so its type is right even then. `reintroduce` on a method and
`abstract` on a class are not in the file (see the gaps) and are left out;
enumeration scoping is not either. A generic type's parameter names are not
stored beside it: they are recovered from the unit's own instantiation of
the type with its parameters, else from the parameter types its members
mention, else synthesized - members always print the same entries, so header
and body agree.

**Values in the data block (added 2026-09-18, v0.38.0).** A typed constant's
bytes, a string literal's characters and a class's VMT all live in the `$6C`
data block, and the `$6D` fixup table says where: a row of kind 0 (`fxStart`)
opens the bytes of the declaration whose address slot it names, the next
kind 0 or kind 1 (`fxEnd`) row closes them, and every other kind patches a
pointer-sized slot at that offset with the address of the slot it names
(kind 4 on Win32, 14 on Win64 - the reader does not care which). The reader
keeps the block (`TPasDcuUnit.DataBlock`), reads the table for real
(`Fixups`, offsets made absolute) and assigns every declaration its range
(`DataOffset`/`DataSize`). The printer's `TryDataValue` walks a value by its
type: ordinals, enumerations (member names), Booleans, characters, sets,
Single/Double/Extended (10 bytes on Win32, 8 on Win64), Currency (scaled by
10000), Comp, ShortString, static arrays, records (field by field, in
`(X: 1; Y: 2)` form), `TGUID` as its string literal, and the pointer-shaped
kinds - `string`/`AnsiString` (the pointer lands 12 bytes into the literal
block, past its StrRec header), `PChar`/`PAnsiChar` (a bare run of
characters), `nil`, a routine's name for a procedural type, a class name for
a class reference (the fixup names the `.TFoo` VMT declaration), `@Var`. A
resourcestring's text is the unnamed `.` constant in the slot right after it.

An imported type carries only its name in this file. System's types are
known by name (`ImportSize`, with the compiler's own `@AnsiChr`/`@PAnsiChr`
spellings mapped back); any other import is followed into **its own unit's
`.dcu` beside this file** (`ForeignUnit`/`ResolveImport`, cached per
printer), which is what turns `const PKEY_X: TPropertyKey = ...` in a Winapi
unit into `(fmtid: '{...}'; pid: 7)` and reads `TColor` arrays, imported
enumerations and sets with their member names. The same lookup decides
whether a helper of an imported type is a class or a record helper (25 of
the RTL's 75 helpers were printed as record helpers before). Over the Delphi
13 Win64 RTL, 14,473 typed constants print with a value and 58 fall back -
33 are `DBID` (a record with a variant part), the rest are pointer values
into things this reader does not name (a `Pointer` whose fixup targets an
imported routine, `DPI_AWARENESS_CONTEXT(-1)`, a `WideString`).

**Modifiers, probed 2026-09-18** by compiling one-difference units and
reading the dumps: `strict` is bit `$10` of a member's normalized flag word
beside the scope (`$10` strict private, `$14` strict protected; records
too); a method header's `VProc` carries `abstract` as `$20` and `final` as
`$40000`; a class definition's `B04` carries `sealed` as `$40`. Its `$4` is
NOT the `abstract` keyword: it is also set on every class with an abstract
method anywhere in its ancestry, including one that overrides that method,
so it is not printed. `reintroduce` leaves no trace at all (the header and
the member row are byte-identical with and without it).

**Gates, all green on 2026-09-17 and again on 2026-09-18 (v0.38.0: 10,199 units read and parsed, `DcuSmoke` 126 checks, client project 0 diagnostics).**
- Reader + printer + parser over every `lib\<platform>\release` of Studio
  22.0, 23.0 and 37.0, Win32 and Win64: 10,199 units read to the end, 10,199
  generated sources with zero syntax diagnostics (`tools\PasTreeDcu.exe <dir>
  -parse`). This is the regression gate for a new compiler version: run it
  and read the first failure's tag.
- `tests\DcuSmoke.dpr` (112 checks): compiles a fixture unit with the
  installed dcc32 and dcc64, keeps its source out of the library directory,
  and checks the tables, each printed declaration shape, a parse of the
  text, a project importing the unit (no `E2003`/`F1027`/`E2034`, a `.pas`
  beside a `.dcu` wins, an unreadable `.dcu` names its reason) and Ctrl+Click
  landing on the declaration's line of the generated text.
- The client project (3767 units): **7 -> 0 diagnostics** with `-members` -
  the five charting-library `F1027`s were its only ones, and TeeChart's units
  (compiled only, under `lib\win32\release`) now analyze clean. The Win64
  server project stays at zero (2127 units, 4.1 s).
- Two fixes to the parser came out of it: a property's hint directive sits
  BEFORE its semicolon (`property P: Integer read FP deprecated;`, dcc-probed
  - `read FP; deprecated;` is an error), and a variable of an inline
  procedural type cannot carry one at all (dcc reads it as a calling
  convention, `E1030`).

**Method for the next Studio version** (unchanged from the decision): run
the same unit through the previous version's reader with a trace, diff the
tag streams, and the last tag before the failure is the record that grew;
compare that record's bytes in both files, the extra bytes are the new
field. Then raise the accepted version range - never before the sweep is
green. The patched public parser in `local/dcu32int/` remains the oracle for
a record whose meaning is in doubt.

## Known gaps, for a future session

Three different kinds, not one. Keep them apart - the fix, and whether a fix
is even possible, differs by kind.

**1. In the file; this reader does not decode it yet.**

- **Typed constants the value walker refuses** (58 of 14,531 in the Delphi
  13 Win64 RTL, all listed in each unit's header comment): a record with a
  variant part (`DBID` in Winapi.OleDB - the overlapping fields would print
  as one flat tuple, which is not a legal initializer), a `Pointer` or
  procedural value whose fixup targets an imported routine (`SysInit`'s
  delay-load hooks - the target is a `dkImport` row, which `TryPointerValue`
  does not name), a pointer type holding a non-nil literal without a fixup
  (`DPI_AWARENESS_CONTEXT(-1)`, printable as a typed cast), and `WideString`
  (a BSTR literal block this reader does not follow). Each is a small case
  in `TryDataValue` / `TryPointerValue` in `PasTree.Dcu.Source.pas`; the
  tally recipe is `PasTreeDcu <unit> -src` over `lib\win64\release` and a
  grep for `could not be decoded`.
- **Generic parameter names via self-instantiation is a fallback, not a
  read.** The DCU does not link an A6 parameter-list entry to the type
  declaration it belongs to; `GenericParamNames` in
  `PasTree.Dcu.Source.pas` guesses from the unit's own instantiation of the
  generic, then from member reference order, then `T1..Tn`. Works on the
  whole RTL sweep but is inference, not extraction - a generic never
  self-instantiated and never referencing its own parameter in a
  recoverable position would print wrong names.

**2. Not in the file; no read can recover it.**

- **`reintroduce`.** Probed 2026-09-18: a method declared with and without
  it produces byte-identical header and member rows. It only silences
  W1010 and the compiler keeps nothing of it.
- **`abstract` on a class.** The one candidate bit (`$4` of `B04`) is set
  for `class abstract` AND for any class with an abstract method somewhere
  in its ancestry, implemented or not (`TFromAbsMethod`, which overrides the
  only abstract method, still carries it). A class that is abstract by
  keyword alone cannot be told from one that merely inherits from an
  abstract-method class, so the keyword is not printed; instantiating such a
  class would be `E2402` against the real unit and nothing against the text.

- **`{$SCOPEDENUMS}`.** An enum's members are ordinary named constants in
  the DCU with no scoping bit; the printer emits them unscoped
  (`TColor = (cRed, cGreen)`, never `TColor.cRed`). This is a strict
  superset for name resolution (an unscoped member resolves everywhere a
  scoped one would, plus bare), so it never causes a false `E2003` - but a
  real source file relying on scoping to allow `TFoo.cRed` alongside a
  same-named `cRed` elsewhere would not compile against the generated text
  the same way it compiles against the real unit.
- **`array of const`'s element type.** The DCU stores this parameter as a
  plain open array of `TVarRec`; the printer recognizes the pattern
  (`ParamsText` in `PasTree.Dcu.Source.pas`) and spells it `array of const`,
  but nothing in the file distinguishes "the source literally wrote `array
  of const`" from "the source wrote `array of TVarRec`" - they compile to
  the same thing, and only the former is legal source. Not worth chasing:
  the two are interchangeable at every call site that matters.
- **Comments, and any order the compiler was free to reshuffle.** Obvious,
  but worth stating: the generated text is not a decompilation of the
  source, it is a text that declares the same things. Byte-identical
  round-trip against the original `.pas` is not a goal and was never tested
  for.

**3. Outside the verified range; extending it is mechanical, not free.**

- **Version bytes below `$23` (pre-Delphi-11) and above `$25` (Delphi 14+
  when it exists).** `DcuVersionSupported` refuses them by construction.
  The reader's `Ver >= verXxx` structure (mirroring the oracle's) would
  probably extend downward with few changes - the additive-fields pattern
  the probe found for 11->12->13 suggests older deltas are removals, not a
  different shape - but nothing here has run against a Delphi 10.x or
  earlier `.dcu` even once, so "probably" is doing real work in that
  sentence. Extending upward for a future compiler is the documented
  trace-diff method above; extending downward would need old installs to
  test against, which is a different kind of blocker.
- **Platforms other than Win32/Win64.** `DcuPlatformSupported` only accepts
  `$03`/`$23`. The oracle's magic table has entries for OSX32/64, Android
  32/64, iOS device/simulator, Linux64 - PasTree itself is Windows-only
  today, so there was no reason to test them, but if that changes, the
  platform byte -> `TPasDcuPlatform` mapping in `DcuHeader` is where they
  would be added, following the oracle's `ReadMagic` table verbatim.
