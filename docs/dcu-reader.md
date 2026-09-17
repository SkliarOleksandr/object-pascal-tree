# Reading `.dcu` files: findings, the decision, what was built

Status: **shipped 2026-09-17 (v0.37.0)** - `source/PasTree.Dcu.pas` reads a
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
  every record kind the three Studios write; skips the data block, fixups,
  line tables, debug tables and inline bodies for their length only. The
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

**What the text does not carry, said where it would be.** A typed constant
is printed as `var X: T;` with a comment - its value is compiled data this
reader does not decode. A resourcestring gets an empty value. A type the
printer cannot resolve is spelled `__PasTreeUnresolved`, declared nowhere, so
each use is an honest `E2003` in the generated unit; the header comment lists
every such fallback. Strict visibility, `abstract`/`sealed` on classes,
`reintroduce`/`abstract`/`final` on methods and enumeration scoping are not
stored in a form the reader knows and are left out. A generic type's
parameter names are not stored beside it: they are recovered from the unit's
own instantiation of the type with its parameters, else from the parameter
types its members mention, else synthesized - members always print the same
entries, so header and body agree. Whether a helper is a class or a record
helper is decided by the helped type's kind (an imported class cannot be
told from an imported record; it is printed as a record helper, which the
resolver treats the same).

**Gates, all green on 2026-09-17.**
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
