program PasTreeXform;

{
  The source side of the compile-compare harness (tools\fidelity.ps1 is the
  driver): dcc judges the tree through the .dcu. A transformation that keeps
  the meaning FOR OUR TREE compiles to a byte-identical .dcu exactly when our
  tree agrees with dcc's, so nothing here needs an expectation file.

  Reads one unit with the inputs its compile gets (platform defines, -D
  defines, include paths) and writes a transformed copy of it AND of every
  include the preprocessor read into an output directory, plus sites.txt:
  what was changed where, and in which routine - the name the .dcu dump
  locates a difference by.

  Modes:
    t0  every file unchanged - the identity the harness must get right first
    ts  selftest: in each routine ONE deliberately WRONG regrouping of an
        operator chain the tree read left-associatively - `a - b + c` becomes
        `a - (b + c)`, `a div b * c` becomes `a div (b * c)`. Every unit with a
        site must compile to a different .dcu: a comparator that cannot see
        this cannot see anything.
    t0f the preprocessor's own decisions written into the text (plan T0'):
        every region it skipped and every conditional directive ($IF $IFDEF
        $IFNDEF $IFOPT $ELSEIF $ELSE $ENDIF $IFEND) blanked to spaces, every
        line break kept, so line numbers do not move - but for the few
        that stay as probes (see Flatten: dcc records what some of them
        consult, in any branch); any other directive kept where it was live
        and blanked where it was not; every include flattened the same way.
        dcc then compiles what PasTree saw - a branch taken differently
        shows as a different .dcu or a failed compile.
        sites.txt lists the preprocessor's diagnostics instead of edits: a
        guessed or unreadable $IF is where a DIFF is likeliest to come from.
    t1  parentheses along the tree (plan T1): every operator node - binary,
        unary, inline if - wrapped in `(` `)`. A correct tree leaves the
        .dcu identical; one grouping dcc makes differently changes the code
        or stops the compile. Only OPERATORS are wrapped: dcc keeps a
        parenthesized designator as a value of its own - `(@P) := X` is
        E2064 where `@P := X` assigns a procedural variable, and an inline
        routine's stored expression tree records `not (A.B)` differently
        from `not A.B` while the code is the same (plan S5). Not wrapped
        either, counted instead: an operator that starts a subrange TYPE - a
        `(` there opens an enumerated type in every type position
        (`excluded-type`); one whose left edge is a `[...]` constructor -
        parenthesized, dcc types it without the target, `A := ([X] + A)` is
        E2008 (`excluded-ctor`); every `@` - `@P` of a procedural variable is
        a designator for dcc (`excluded-at`); one that starts the value of a
        typed constant or an initialized variable, an aggregate element or a
        record constant's field value - a `(` there opens an aggregate
        (`excluded-init`, see CollectInitStarts); in a unit whose own text turns
        debug info on, an operator whose last token does not share a line
        with the next (`excluded-lines`, see LinesKept). Every site is one line of
        sites.txt; -sites: applies a subset (the driver's localizer bisects a
        DIFF down to the node with it).
    t2  blocks along the tree (plan T2): every statement node in a statement
        position - a statement list's item, an if's branch, a case branch's
        body, the body of a loop, a with or an exception handler, the
        statement a label marks - wrapped in `begin` `end`, an empty one
        replaced by `begin end`; the `end` goes right before the token
        after the statement, whose line dcc gives an Assert (see
        AddBlockSite). A correct tree leaves the .dcu identical;
        an `else` or a statement's end placed differently from dcc changes
        the code or stops the compile. Not wrapped, counted: an inline var
        or const (the block would end its scope - `excluded-inline`), a
        labeled statement itself (its statement is wrapped -
        `excluded-label`), asm (`excluded-asm`), a call statement standing
        as a list item (dcc finalizes a discarded managed result at the end
        of the list - `excluded-call`), in a generic's or an inline
        routine's body a statement not on one line with the token after it
        (dcc stores such a body with its lines - `excluded-stored`), the
        same in a unit whose own text turns debug or symbol info on
        (`excluded-lines`, see LinesKept; all three see T2Walk); never a
        routine's own block or the statement lists of
        a case-else, a try, an except, a finally or a repeat, which are no
        statements - their items are.
    t3  the unit printed from its tree (plan T3, PasTree.Printer) IN PLACE:
        each item of the print written into the slot of the token T3
        matched it to, in print order (see T3Walk) - every keyword and
        punctuation regenerated, the canonical spellings of the printer's
        normalization list applied, the filed losses read where they stand;
        everything else of every file kept byte for byte, so each token
        stays on its line and the directives, the inactive code and the
        include files stay what they are. A list's `;` the print does not
        need stays too (dcc gives a statement's end the line of the token
        after it). A correct tree and printer leave the .dcu identical.
        One site per node whose slots change; a case-only change (a
        keyword in lower case) is always applied. Refused when the unit
        does not parse clean or its print has a T3 defect.
    t3x t3 with t1's parentheses and t2's blocks over the print - the plan's
        final gate: the unit printed from its tree alone, fully
        parenthesized and fully blocked, compiled by dcc to the same .dcu.
        t3's sites first, then t1's, then t2's; both under t2's line rule.
    tq  the RESOLVER judged (plan S12-S13, the second rung): every name the
        project analysis bound written so that dcc can only read it as the
        declaration PasTree chose - a unit-level declaration of any unit,
        System's builtins and the unit's own included, as
        `<unit.full.name>.Name`; a field, method or property of the method's
        own type, reached bare in its body, as `Self.Name`. A correct
        binding leaves the .dcu identical under t2's switches; a name dcc
        binds elsewhere changes the code or stops the compile. Always takes
        the project analysis (-S, -NS as -oracle) and edits ITS tree. Not
        written, counted (see TQIdent): locals - variables, parameters,
        Result, Self, generic parameters, labels - which have no qualified
        form; a member outside a body or a constant or type member
        (excluded-member), in a with body (excluded-with), in a class method
        (excluded-static), of an outer type (excluded-nested), Self in a
        generic's body (excluded-stored); a qualifier a name of the unit
        hides (excluded-shadowed), a routine of an overload set merged
        across units (excluded-overload), a position with no qualified
        spelling (excluded-position); a name PasTree bound to nothing
        (unbound, each listed in sites.txt). The selector after a dot is
        tm's.
    tm  the resolver's MEMBERS judged (plan S15): every member reached
        after a dot written through a hard cast to the type PasTree says
        declares it - `Owner(Base).Name`, `Owner(P^).Name` for a pointer
        dereferenced implicitly; a default array property spelled -
        `Owner(Base).Items[I]`; a name in a with body bound to a target's
        member written through that target - `Owner(Target).Name`. A
        member of another type (a descendant's namesake hiding it, the
        other target of two) changes the code or stops the compile. A
        preamble names every cast's type of another unit first, in the
        original's compile too (see TMPreamble). Not written, counted (see
        TTMExcl): type and unit bases, class references, helpers, generic
        or hidden owners, stored bodies, record call results, protected
        members of another unit, members a stored body reads, untyped
        bases; a member PasTree's own typing contradicts is listed
        (mismatch).
    tqm tq and tm together.
    tms tm's selftest: in each routine ONE member cast to the nearest
        ancestor declaring another field or routine of that name (see
        TMWrongOwner) - which must DIFF or stop the compile.
    tqs tq's selftest (plan S14): in each routine ONE unit-level name
        written with a WRONG qualifier dcc accepts - another used unit's,
        or System's, variable or routine of that name (see
        TQWrongQualifier) - and nothing else. A unit with such a site must
        compile to another .dcu or not at all.

  Usage:
    PasTreeXform <unit.pas> -mode:t0|ts|t0f|t1|t2|t3|t3x|tq|tqs|tm|tqm|tms -out:<dir> [-p:<platform>]
                 [-D:X;Y]... [-Undef:X;Y]... [-I:<dir>[;<dir>]]...
                 [-sites:<ids>]
  -sites (ts, t1, t2, t3, t3x): only the sites with these ids take their edit - a
  comma list of ids and ranges, `1-40,57`; the ids are those of the full
  run, so sites.txt means the same in every run over the same unit.
  `-sites:none` applies no site at all: tm's original side, its preamble
  alone.
  -Undef takes names out of the define set after the platform's and -D's -
  with -D, a way to try another predefined set without rebuilding.
  -oracle: when a $IF of the unit asked what a bare preprocessor cannot
  answer (Declared, a constant, SizeOf), the stream flattened (t0f) or
  parsed (ts, t1, t2) is the one a project analysis makes - its first pass
  answers compiler-provided names, its second asks the loaded units (the
  Declared/SizeOf oracle) - over the -S search paths plus the -I ones, with
  the -NS:X;Y unit scope names (default: the IDE's for the platform). That
  is the stream PasTree analyzes, and the only way to judge the oracle
  against dcc.

  Output, all of it under <dir>:
  - the files, mirrored under the common directory of the unit, its includes
    and the -I directories, so a relative `$I` include resolves as it did;
  - sites.txt, tab-separated: id, kind, operators, span
    `file(line,col)-(line,col)`, routine, the edit, applied (1, or 0 when
    -sites left it out); t2's ops column is `<position>:<statement>` -
    `else:if`, `list::=`, `then:empty`, `on:begin`;
  - on stdout `main <path>` (the transformed unit), one `file <from> <to>`
    per file written, one `idir <from> <to>` per -I directory (the compile
    of the copy searches <to>), `sites <n>` (with `dropped`, `excluded`,
    `applied` counts where they apply), `parse <n>` - the parse diagnostics
    of the tree ts, t1 and t2 edit along; <from> and <to> tab-separated.
    t0f adds `copy <from> <to>` per extra instance copy of an include (see
    below), `argmap <new> <old>` per include argument rewritten to name one
    (the .dcu records each inclusion under its name as written: the driver
    maps these back before it compares) and one `flatten ...` line of
    counts.

  What a compile reads besides the text is kept too:
  - the source MTIME, copied as the exact FILETIME - dcc stores it in the
    .dcu, so a fresh timestamp alone makes a copy compile differently;
  - the ENCODING: an edit is spliced into the original BYTES at the byte
    offset of its token (the prefix re-counted in the file's own encoding),
    so no untouched byte is ever re-encoded. A file whose bytes do not
    round-trip through its decoding (a lenient U+FFFD recovery) is refused.

  A file included more than once takes no ts, t1 or t2 edit (one text serves
  several preprocessing states); a site that would need one - or whose
  parentheses or begin and end would land in two files - is dropped and
  counted.
  t0f flattens every inclusion on its own, since each has its own state: the
  inclusions whose flattened texts agree share the file, and each different
  text is written to a copy in a `~<n>` directory beside it, its `$I`
  argument rewritten to name that copy.

  Which directive was live, t0f asks the preprocessor itself rather than
  re-deciding it: a second run over the same files, with a marker comment
  before every directive and after every conditional, reports each marker in
  a region it skipped - a comment decides nothing, so the run decides as the
  first did. Checked, not assumed: the two runs must read the same files and
  see the same visible tokens, every marker must come back, and the markers
  must agree with the preprocessor's own records (includes followed, define
  mentions) and with a rebuilt conditional stack.
}

{$APPTYPE CONSOLE}
{$MAXSTACKSIZE $01000000}   // 16 MB per thread: README, "The stack every host should reserve"

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.StrUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Dcu in '..\source\PasTree.Dcu.pas',
  PasTree.Dcu.Source in '..\source\PasTree.Dcu.Source.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.Ast.Check in '..\source\PasTree.Ast.Check.pas',
  PasTree.Printer in '..\source\PasTree.Printer.pas',
  PasTree.Sema.Diagnostics in '..\source\PasTree.Sema.Diagnostics.pas',
  PasTree.Sema.Model in '..\source\PasTree.Sema.Model.pas',
  PasTree.Sema.Builtins in '..\source\PasTree.Sema.Builtins.pas',
  PasTree.Sema.Resolver in '..\source\PasTree.Sema.Resolver.pas',
  PasTree.Sema.Project in '..\source\PasTree.Sema.Project.pas',
  PasTree.Version in '..\source\PasTree.Version.pas';

type
  TXformMode = (xmT0, xmTS, xmT0F, xmT1, xmT2, xmT3, xmT3X, xmTQ, xmTQS, xmTM,
    xmTQM, xmTMS);

const
  cModeNames: array[TXformMode] of string = ('t0', 'ts', 't0f', 't1', 't2',
    't3', 't3x', 'tq', 'tqs', 'tm', 'tqm', 'tms');
  // The modes that judge the resolver over the project analysis (S13-S15).
  cQModes = [xmTQ, xmTQS, xmTM, xmTQM, xmTMS];
type
  // tm: why a member is left as written (the `excluded-<name>` of the sites
  // line): a selector outside every body; one after a unit name, already
  // qualified; after a type name (a class var or method spelled through
  // another type imports that type's class reference, Q67); after a class
  // reference (no named metaclass of the owner to cast to); a helper's
  // member (no cast reaches it); an owner that is generic, declared inside a
  // routine or anonymous, or a nested type another unit hides; a record
  // returned by a call (E2089 on the cast, Q69); a base PasTree could not
  // type; an owner in a unit no name at the site comes from; in a stored
  // body (a generic's or an inline routine's: the cast changes the stored
  // tree, Q81, Q82, Q84); a cast's first segment hidden at the site; an own
  // owner declared further down; a with target that is no parameter,
  // local variable or Self (a field or a global the with reads once into a
  // temporary, the spelling again each time - System.Win.Registry);
  // a position with no cast spelling (after `inherited`); a protected or
  // private member of another unit's type (reached through a descendant
  // the unit declares, or from a method of one: through the owner it is
  // E2362); a member a stored body of the unit also reads (a cast to an
  // ancestor before it changes that body's stored flags, probes P02, P03);
  // in a unit whose text turns optimization on, a base that is no plain
  // name (the cast defeats dcc's reuse of the loaded element, P04).
  TTMExcl = (tmeOutside, tmeQualified, tmeTypeBase, tmeClassRef, tmeHelper,
    tmeGeneric, tmeLocalType, tmeHidden, tmeRValue, tmeUntyped, tmeUnseen,
    tmeStored, tmeShadowed, tmeForward, tmeWithTarget, tmePosition,
    tmeProtected, tmeStoredUse, tmeOptimized, tmeSymInfo, tmeUpLevel);

const
  cTMExclNames: array[TTMExcl] of string = ('outside', 'qualified',
    'typebase', 'classref', 'helper', 'generic', 'localtype', 'hidden',
    'rvalue', 'untyped', 'unseen', 'caststored', 'castshadowed',
    'castforward', 'withtarget', 'castposition', 'protected', 'storeduse',
    'optimized', 'castsyminfo', 'uplevel');
  // t3: a print slot's replacement sorts after every insertion at its offset
  // - a `(` or a `begin` that opens there, an `end` closing before it.
  cSlotOrder = 100;

type
  // One text insertion into one file, or a replacement of Len characters
  // there. Order breaks ties at the same offset: a closing paren must land
  // before an opening one there (`c)(d`), which is what T1 will need when
  // many parens meet; TS never puts two at one spot, and t0f's replacements
  // never overlap.
  TEdit = record
    FileId: Integer;
    Offset: Integer;     // UTF-16 offset in the file's decoded text
    Len: Integer;        // characters replaced from Offset; 0 inserts
    Order: Integer;
    Text: string;
  end;

  // ts, t1 and t2: OpenText goes before visible token OpenVis and CloseText
  // after CloseVis - `(` and `)`, or `begin` and `end` - with their Orders
  // at an offset other edits share (see AddEdit); an empty CloseText is no
  // edit. t0f's sites are diagnostics, OpenVis -1. A t3 site is its Edits,
  // the print's replacements of one node's slots (see T3Walk).
  TSite = record
    Kind: string;
    Ops: string;
    Span: string;
    Routine: string;
    Edit: string;
    OpenVis: Integer;
    CloseVis: Integer;
    OpenAfter: Boolean;     // OpenText goes AFTER token OpenVis (t2's empty)
    CloseBefore: Boolean;   // CloseText goes BEFORE token CloseVis (t2's end)
    OpenText: string;
    CloseText: string;
    OpenOrder: Integer;
    CloseOrder: Integer;
    Edits: TArray<TEdit>;
  end;

var
  GPre: TPasPreprocessed;
  GTree: TPasTree;
  GEdits: TList<TEdit>;
  GSites: TList<TSite>;
  GIncludedTwice: TArray<Boolean>;   // per FileId: its path occurs twice
  GDropped: Integer;                 // sites refused for an include used twice
  GExcluded: Integer;                // t1: operators starting a subrange type
  GExcludedCtor: Integer;            // t1: operators starting with `[`
  GExcludedAt: Integer;              // t1: `@` operators
  GExcludedInline: Integer;          // t2: inline var / const statements
  GExcludedLabel: Integer;           // t2: labeled statements themselves
  GExcludedAsm: Integer;             // t2: asm statements
  GExcludedCall: Integer;            // t2: call statements in a list
  GExcludedStored: Integer;          // t2: in a stored body, off one line
  GExcludedLines: Integer;           // t1, t2: line info on in the source
  GExcludedInit: Integer;            // t1: operators starting an initializer
  GExcludedPrint: Integer;           // t3: slots kept, in an include used twice
  GPrintCase: TList<TEdit>;          // t3: keyword case alone, always applied
  GPrintStats: string;               // t3: the `print` line's counts
  // t1: the first visible token of every initializer value (see
  // CollectInitStarts)
  GInitStarts: TDictionary<Integer, Boolean>;
  // t1, t2: the unit's own text turns line-keeping info on (see LinesKept)
  GLinesKept: Boolean;
  // t2: the last name part, lower case, of every routine declared `inline`
  // anywhere in the unit (see IsStoredBody).
  GInlineNames: TDictionary<string, Boolean>;
  GUnitName: string;
  // t0f: per FileId, the file it is written as - its own path, or an
  // instance copy's (see Flatten) - and the counts of the `flatten` line.
  GOutName: TArray<string>;
  GIsCopy: TArray<Boolean>;
  GFlatStats: string;
  // t0f: every include argument rewritten to name an instance copy, the new
  // spelling -> the one it replaced, quotes off - the .dcu records each
  // inclusion under its name as written, so the driver maps them back.
  GArgMap: TDictionary<string, string>;
  // tq: the project analysis whose bindings are judged, the unit's model in
  // it, and the names left as written, by why: a local (a variable,
  // parameter, Result, Self, generic parameter, label of a routine), a
  // member outside a body or of a kind Self cannot reach, in a with body
  // (S15), in a class method, of an outer type, a qualifier hidden by a name
  // of the unit's (Q11), a routine of an overload set merged across units
  // (see TQOverloadMerged), Self in a generic's body (see TQGenericBody),
  // a position with no qualified spelling, a name
  // PasTree did not bind (each listed in sites.txt), the selector after a
  // dot (S15's).
  GQProject: TPasSemaProject;
  GQMid: Integer;
  GQExt: TPasExtRef;
  GQLocal, GQMember, GQWith, GQStatic, GQNested, GQShadowed, GQPosition,
    GQUnbound, GQSelector, GQOverload, GQStored, GQForward, GQInvisible,
    GQSymInfo: Integer;
  // tq, tm: the unit's own text turns DEFINITIONINFO / REFERENCEINFO on
  // ($Y+, $YD), overriding the harness's -$Y-. The symbol-reference record
  // ($93) then records `Self.X`, a hard cast and a qualified name in a stored
  // body (plan S12, Q04, Q05, Q12 under the defaults; S16, a third-party
  // include turning DEFINITIONINFO on: every such unit DIFFed in raw bytes
  // only). Such a unit takes unit qualifiers outside stored bodies alone
  // (Q01: SAME under the defaults) - the whole unit, whatever the
  // directive's position, as LinesKept.
  GQSymInfoOn: Boolean;
  // REFERENCEINFO itself on (`$Y+`, not `$YD`): every reference is recorded,
  // and a unit qualifier changes the record too (S16 probes, scratch g1-g8:
  // `System.Byte` for `Byte` under `$Y+`) - no unit qualifier at all.
  GQRefInfoOn: Boolean;
  // Win32: see TMUpLevel.
  GQWin32: Boolean;
  GQUnboundList: TStringList;
  // tq: bindings to a unit no name at the site can come from (see
  // TQUnitVisible) - wrong whatever dcc says, listed in sites.txt.
  GQInvisibleList: TStringList;
  // tq: the first token of the implementation section (MaxInt when there is
  // none) and the models of System and SysInit, -1 when not analyzed.
  GQImplTok, GQSystemMid, GQSysInitMid: Integer;
  // tqs: the mode, and the routines that already took their planted site.
  GQSelftest: Boolean;
  GQPlanted: TDictionary<string, Boolean>;
  // tq, tm: which halves run - unit-level names and Self (tq, tqs, tqm),
  // members reached after a dot, through a default array property or a with
  // target (tm, tms, tqm); tms: the member half's selftest.
  GQUnits, GQMembers, GQMemberSelftest: Boolean;
  // tm: the probe every base expression is typed through, the members left
  // as written by why (see TTMExcl), the bindings PasTree's own typing
  // contradicts (each listed in sites.txt). A selector PasTree bound to
  // nothing counts with tq's unbound names.
  GQProbe: TPasXProbe;
  // tq: name (lower case) -> the last token of a bare use of it in a method
  // of a NESTED type (TQCollectHistory) - an earlier bare use there is dcc's
  // lookup history and stays as written (F42).
  GQHistory: TDictionary<string, Integer>;
  GMExcl: array[TTMExcl] of Integer;
  GMMismatch: Integer;
  GMMismatchList: TStringList;
  // tm: the type of every cast, of another unit, in first-use order - the
  // preamble that imports them ahead of the unit's own code (see
  // TMPreamble).
  GMPreamble: TStringList;
  // tm: the preamble's declarations by the top-level declaration they go
  // before (see TMAnchor), the unit's text turns optimization on, and every
  // member a stored body reads (model id shl 32 or symbol).
  GMAnchors: TDictionary<Integer, string>;
  GMOptimized: Boolean;
  GMStoredUse: TDictionary<Int64, Boolean>;

function VisOffset(AVis: Integer; out AFileId: Integer): Integer;
var
  LTok: TPasVisibleToken;
begin
  LTok := GPre.Visible[AVis];
  AFileId := LTok.FileId;
  Result := GPre.Files[LTok.FileId].Tokens[LTok.TokenIndex].Start;
end;

function VisEnd(AVis: Integer; out AFileId: Integer): Integer;
var
  LTok: TPasVisibleToken;
begin
  LTok := GPre.Visible[AVis];
  AFileId := LTok.FileId;
  Result := GPre.Files[LTok.FileId].Tokens[LTok.TokenIndex].EndPos;
end;

// `File.pas(12,5)` for a file offset - 1-based, the dcc message form.
function PosText(AFileId, AOffset: Integer): string;
var
  LLine, LCol: Integer;
begin
  GPre.Files[AFileId].OffsetToLineCol(AOffset, LLine, LCol);
  Result := Format('%s(%d,%d)', [TPath.GetFileName(GPre.FileNames[AFileId]),
    LLine, LCol]);
end;

function SpanText(AFirstVis, ALastVis: Integer): string;
var
  LFile, LEndFile, LLine, LCol: Integer;
  LStart, LEnd: Integer;
begin
  LStart := VisOffset(AFirstVis, LFile);
  LEnd := VisEnd(ALastVis, LEndFile);
  Result := PosText(LFile, LStart);
  // The LAST character's position, inclusive, like an editor selection.
  GPre.Files[LEndFile].OffsetToLineCol(LEnd - 1, LLine, LCol);
  Result := Result + Format('-(%d,%d)', [LLine, LCol]);
end;

function Child(ANode, AIndex: Integer): Integer;
begin
  Result := GTree.Nodes[ANode].FirstChild;
  while (Result <> NIL_NODE) and (AIndex > 0) do
  begin
    Result := GTree.Nodes[Result].NextSibling;
    Dec(AIndex);
  end;
end;

function OpText(ANode: Integer): string;
begin
  Result := LowerCase(GPre.VisibleText(GTree.Nodes[ANode].Aux));
end;

{ A routine's name as the .dcu spells it: the leading name idents of the
  header, dotted (`TFoo.Bar`, `TOuter.TInner.Bar`), generic parameter lists
  left out - the driver compares names without them. A name part after the
  first follows a dot: the result type of a routine with no parameter list,
  `function TFoo.Get: TBar`, is the next ident child too. }
function RoutineName(ARoutine: Integer): string;
var
  LChild, LVis: Integer;
begin
  Result := '';
  LChild := GTree.Nodes[ARoutine].FirstChild;
  while LChild <> NIL_NODE do
  begin
    case GTree.Nodes[LChild].Kind of
      nkIdent:
        begin
          LVis := GTree.Nodes[LChild].FirstToken;
          if Result <> '' then
          begin
            if (LVis < 1) or (GPre.VisibleToken(LVis - 1).Kind <> tkDot) then
              Break;
            Result := Result + '.';
          end;
          // `&Type` names a routine `Type`: the ampersand is no part of it.
          Result := Result + GTree.NodeText(LChild).TrimLeft(['&']);
        end;
      nkGenericParams, nkTypeArgs:
        ;
    else
      Break;
    end;
    LChild := GTree.Nodes[LChild].NextSibling;
  end;
end;

{ The unit's name as written in its header, `PasTree.Ast` - the name of the
  routine a .dcu gives the initialization section's code. }
function HeaderName: string;
var
  LVis: Integer;
begin
  // ident { . ident } - a hint directive after it (`unit U platform;`) is
  // not part of the name.
  Result := '';
  LVis := GTree.Nodes[0].FirstToken + 1;
  while LVis <= High(GPre.Visible) do
  begin
    if GPre.VisibleToken(LVis).Kind <> tkIdentifier then
      Break;
    Result := Result + GPre.VisibleText(LVis).TrimLeft(['&']);
    if (LVis + 1 > High(GPre.Visible)) or
       (GPre.VisibleToken(LVis + 1).Kind <> tkDot) then
      Break;
    Result := Result + '.';
    Inc(LVis, 2);
  end;
end;

{ One text insertion before (AAfter False) or after visible token AVis.
  AOrder sorts the insertions that meet at one offset, lowest first: ts and
  t1 put a `)` (0) before a `(` (1), `c)(d`; t2 an empty statement's
  `begin end` (0), then the `end` of every statement that ends there (1) -
  an empty statement is the last part of the statement around it, `do;` ->
  `do begin end end;` - then a `begin` (2). }
procedure AddEdit(AVis: Integer; AAfter: Boolean; AOrder: Integer;
  const AText: string);
var
  LEdit: TEdit;
begin
  if AAfter then
    LEdit.Offset := VisEnd(AVis, LEdit.FileId)
  else
    LEdit.Offset := VisOffset(AVis, LEdit.FileId);
  LEdit.Len := 0;
  LEdit.Order := AOrder;
  LEdit.Text := AText;
  GEdits.Add(LEdit);
end;

// The text of visible token AVis.
function VisText(AVis: Integer): string;
var
  LTok: TPasVisibleToken;
begin
  LTok := GPre.Visible[AVis];
  Result := GPre.Files[LTok.FileId].TokenText(LTok.TokenIndex);
end;

{ ts, t1: the site's edit is a pair of parentheses - with a space where the
  paren would fuse with its neighbour into another token: `.)` is the digraph
  of `]` and `(.` of `[`, `(*` opens a comment. A real literal written with a
  trailing dot, `100.` (an application's report code: `... *` / `100. - X`),
  parenthesized to `100.)` read as `100` and `]` - E2029 (plan S7). }
procedure SetParens(var ASite: TSite);
var
  LText: string;
begin
  ASite.OpenAfter := False;
  ASite.CloseBefore := False;
  ASite.OpenText := '(';
  LText := VisText(ASite.OpenVis);
  if (LText <> '') and CharInSet(LText[1], ['.', '*']) then
    ASite.OpenText := '( ';
  ASite.OpenOrder := 1;
  ASite.CloseText := ')';
  if VisText(ASite.CloseVis).EndsWith('.') then
    ASite.CloseText := ' )';
  ASite.CloseOrder := 0;
end;

{ TS: the site class of binary op P, 0 when it is not a candidate. P reads
  (A op1 B) op2 R; the wrong grouping is A op1 (B op2 R). Only pairs where
  that is a DIFFERENT computation for every operand type the original allows,
  and still type-checks: op1 is the non-associative one. `(a + b) - c` ->
  `a + (b - c)` is the same integer, and `and`/`or` chains short-circuit to
  the same jumps, so both could compile identically and prove nothing. }
function SiteClass(AP: Integer): Integer;
var
  LL: Integer;
  LOp1, LOp2: string;
begin
  Result := 0;
  LL := Child(AP, 0);
  if (LL = NIL_NODE) or (GTree.Nodes[LL].Kind <> nkBinaryOp) or
     (Child(AP, 1) = NIL_NODE) or (Child(LL, 1) = NIL_NODE) then
    Exit;
  LOp1 := OpText(LL);
  LOp2 := OpText(AP);
  if (LOp1 = '-') and ((LOp2 = '+') or (LOp2 = '-')) then
    Result := 1
  else if (((LOp1 = 'div') or (LOp1 = 'mod')) and
           ((LOp2 = '*') or (LOp2 = 'div') or (LOp2 = 'mod'))) or
          ((LOp1 = '/') and ((LOp2 = '*') or (LOp2 = '/'))) or
          ((LOp1 = '*') and ((LOp2 = 'div') or (LOp2 = 'mod'))) then
    Result := 2
  else if ((LOp1 = 'shl') or (LOp1 = 'shr')) and
          ((LOp2 = 'shl') or (LOp2 = 'shr')) then
    Result := 3;
end;

{ The candidate operator chains of one routine's statements, source order.
  Not descended: an anonymous method (compiled as a routine of its own, under
  a compiler-made name), case labels (a regrouped label can collide with
  another one and stop the compile), asm. }
procedure CollectCandidates(ANode: Integer; ACandidates: TList<Integer>);
var
  LChild: Integer;
begin
  case GTree.Nodes[ANode].Kind of
    nkAnonMethod, nkRoutine, nkCaseLabels, nkAsmStmt:
      Exit;
    nkBinaryOp:
      if SiteClass(ANode) > 0 then
        ACandidates.Add(ANode);
  end;
  LChild := GTree.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    CollectCandidates(LChild, ACandidates);
    LChild := GTree.Nodes[LChild].NextSibling;
  end;
end;

procedure PickSite(ABlock: Integer; const ARoutine: string);
var
  LCandidates: TList<Integer>;
  LBest, LClass, LCand, LP, LB, LR: Integer;
  LFirst, LLast, LFileA, LFileB: Integer;
  LSite: TSite;
begin
  LCandidates := TList<Integer>.Create;
  try
    CollectCandidates(ABlock, LCandidates);
    // The best class first, the first in source order within it.
    LP := NIL_NODE;
    LBest := MaxInt;
    for LCand in LCandidates do
    begin
      LClass := SiteClass(LCand);
      if LClass < LBest then
      begin
        LBest := LClass;
        LP := LCand;
      end;
    end;
    if LP = NIL_NODE then
      Exit;
    LB := Child(Child(LP, 0), 1);
    LR := Child(LP, 1);
    LFirst := GTree.NodeLeftmostVis(LB);
    LLast := GTree.Nodes[LR].LastToken;
    VisOffset(LFirst, LFileA);
    VisOffset(LLast, LFileB);
    if (LFileA <> LFileB) or GIncludedTwice[LFileA] then
    begin
      Inc(GDropped);
      Exit;
    end;
    LSite.OpenVis := LFirst;
    LSite.CloseVis := LLast;
    SetParens(LSite);
    LSite.Kind := GTree.KindName(GTree.Nodes[LP].Kind);
    LSite.Ops := OpText(Child(LP, 0)) + '/' + OpText(LP);
    LSite.Span := SpanText(GTree.NodeLeftmostVis(LP), GTree.Nodes[LP].LastToken);
    LSite.Routine := ARoutine;
    LSite.Edit := Format('( at %s, ) after %s', [
      SpanText(LFirst, LFirst), SpanText(LLast, LLast)]);
    GSites.Add(LSite);
  finally
    LCandidates.Free;
  end;
end;

{ Every routine with a body, nested ones named `Outer.Inner` (the name the
  .dcu dump gives an embedded routine under its parent), plus the
  initialization and finalization sections under the names dcc gives their
  code. }
procedure VisitRoutines(ANode: Integer; const AOuter: string);
var
  LChild, LBodyChild: Integer;
  LName: string;
begin
  case GTree.Nodes[ANode].Kind of
    nkAnonMethod:
      Exit;
    nkRoutine:
      begin
        LName := RoutineName(ANode);
        if AOuter <> '' then
          LName := AOuter + '.' + LName;
        LChild := GTree.Nodes[ANode].FirstChild;
        while LChild <> NIL_NODE do
        begin
          if GTree.Nodes[LChild].Kind = nkRoutineBody then
          begin
            LBodyChild := GTree.Nodes[LChild].FirstChild;
            while LBodyChild <> NIL_NODE do
            begin
              case GTree.Nodes[LBodyChild].Kind of
                nkRoutine:
                  VisitRoutines(LBodyChild, LName);
                nkBlock:
                  PickSite(LBodyChild, LName);
              end;
              LBodyChild := GTree.Nodes[LBodyChild].NextSibling;
            end;
          end;
          LChild := GTree.Nodes[LChild].NextSibling;
        end;
        Exit;
      end;
    nkInitSec:
      begin
        PickSite(ANode, GUnitName);
        Exit;
      end;
    nkFinalSec:
      begin
        PickSite(ANode, 'Finalization');
        Exit;
      end;
  end;
  LChild := GTree.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    VisitRoutines(LChild, AOuter);
    LChild := GTree.Nodes[LChild].NextSibling;
  end;
end;

{ t1: the operator as the report spells it - `is not` and `not in` from the
  node's flag, `if` for an inline if. }
function OpsOf(ANode: Integer): string;
begin
  if GTree.Nodes[ANode].Kind = nkInlineIf then
    Exit('if');
  Result := OpText(ANode);
  if nfNegated in GTree.Nodes[ANode].Flags then
    if Result = 'is' then
      Result := 'is not'
    else
      Result := 'not ' + Result;
end;

{ t1: a site wrapping ANode's whole span, from its leftmost token (an
  operator's FirstToken is the operator, not its left edge) to its last.
  Dropped and counted when the two ends lie in different files or in a file
  included twice. }
procedure AddParenSite(const AKind, AOps: string; ANode: Integer;
  const ARoutine: string);
var
  LFirst, LLast, LFileA, LFileB: Integer;
  LSite: TSite;
begin
  LFirst := GTree.NodeLeftmostVis(ANode);
  LLast := GTree.Nodes[ANode].LastToken;
  VisOffset(LFirst, LFileA);
  VisOffset(LLast, LFileB);
  if (LFileA <> LFileB) or GIncludedTwice[LFileA] then
  begin
    Inc(GDropped);
    Exit;
  end;
  LSite.Kind := AKind;
  LSite.Ops := AOps;
  LSite.Span := SpanText(LFirst, LLast);
  LSite.Routine := ARoutine;
  LSite.Edit := '()';
  LSite.OpenVis := LFirst;
  LSite.CloseVis := LLast;
  SetParens(LSite);
  GSites.Add(LSite);
end;

{ t1: every operator node of the subtree at ANode as a site, in pre-order
  (an operator before its operands). ARoutine names the code the node
  compiles into, for the report: the dotted routine name the .dcu dump uses
  ('' outside every body - a constant, a type, a default value; an anonymous
  method counts as the routine it is written in). ATypeStart is the leftmost
  token of the enclosing subrange TYPE (-2 outside one): a `(` there makes
  dcc read an enumerated type, in every type position probed - a type
  declaration, the type of a var, field, typed constant or inline var, an
  array index in any dimension, `set of`, `array of` (plan S5, probes
  ty01..ty28) - so an operator starting there is not wrapped, only counted
  (GExcluded). Case labels, variant labels, set elements, typed-constant
  values, default parameters and property specifiers are expressions and
  take the parentheses.

  Nor is an operator whose left edge is a `[...]` constructor (counted in
  GExcludedCtor): dcc types a constructor from the TARGET only while the
  expression is not parenthesized - `A := [X] + A` concatenates dynamic
  arrays, `A := ([X] + A)` is E2008 and `F(([X] + A))` E2008, `[X]` read as
  a set; `A + [X]` is typed from A and takes the parentheses (plan S5,
  probes dynarr). A set expression starting with `[` loses its check with
  them - it cannot be told from an array at parse time.

  Nor is any `@` (GExcludedAt): of a procedural variable, `@P` is a
  designator - `@P := GetProcAddress(...)` assigns the variable and `(@P)`
  is E2064 there, `F(@P)` passes it to a var parameter and `F((@P))` is
  E2197, and in an inline routine `LPARAM((@P))` is stored differently -
  and a parse cannot tell a procedural variable from any other. The
  operator around it is still wrapped: `(@F = nil)`.

  Nor an operator that starts an initializer's value (GExcludedInit, see
  CollectInitStarts).

  Nor, in a unit whose own text turns D or L on (GLinesKept, see
  LinesKept), an operator whose last token does not share a line with the
  next (GExcludedLines). }
function EndsOnLineOfNext(ANode: Integer): Boolean; forward;

{ t1: the first token of every value where a `(` opens an AGGREGATE when
  the value's type is structured - the value of a typed constant or of an
  initialized variable, an element of an aggregate, the value of a record
  constant's field. An array of Char takes a string expression there, and
  parenthesized it is a one-element array constant: `C: array[0..5] of
  AnsiChar = 'abc' + 'def'` compiles, `= ('abc' + 'def')` is E2010
  'AnsiChar' and 'string', in each of the four positions; `(1 + 2)` for an
  Integer, a string, a set or a Byte element compiles (plan S7, probes
  init-paren; a third-party library's char tables). A parse cannot tell a structured type
  from a scalar one behind a name, so every such value start is recorded;
  an untyped constant's value takes the parentheses (no aggregate there). }
procedure CollectInitStarts(ANode: Integer);
var
  LChild, LFirst: Integer;
  LTyped: Boolean;
begin
  case GTree.Nodes[ANode].Kind of
    nkConstDecl, nkVarDecl:
      begin
        // A constant is typed when a `:` follows its name; a variable with
        // an initializer always is. The value is the child right after `=`.
        LTyped := GTree.Nodes[ANode].Kind = nkVarDecl;
        if not LTyped then
        begin
          LChild := GTree.Nodes[ANode].FirstChild;
          while (LChild <> NIL_NODE) and (GTree.Nodes[LChild].Kind <> nkIdent) do
            LChild := GTree.Nodes[LChild].NextSibling;
          LTyped := (LChild <> NIL_NODE) and
            (GTree.Nodes[LChild].LastToken < High(GPre.Visible)) and
            (GPre.VisibleToken(GTree.Nodes[LChild].LastToken + 1).Kind = tkColon);
        end;
        if LTyped then
        begin
          LChild := GTree.Nodes[ANode].FirstChild;
          while LChild <> NIL_NODE do
          begin
            LFirst := GTree.NodeLeftmostVis(LChild);
            if (LFirst > 0) and (GPre.VisibleToken(LFirst - 1).Kind = tkEqual) then
              GInitStarts.AddOrSetValue(LFirst, True);
            LChild := GTree.Nodes[LChild].NextSibling;
          end;
        end;
      end;
    nkAggregate:
      begin
        LChild := GTree.Nodes[ANode].FirstChild;
        while LChild <> NIL_NODE do
        begin
          if GTree.Nodes[LChild].Kind <> nkAggregateField then
            GInitStarts.AddOrSetValue(GTree.NodeLeftmostVis(LChild), True);
          LChild := GTree.Nodes[LChild].NextSibling;
        end;
      end;
    nkAggregateField:
      begin
        LChild := GTree.Nodes[ANode].FirstChild;       // the field name
        if LChild <> NIL_NODE then
          LChild := GTree.Nodes[LChild].NextSibling;   // its value
        if LChild <> NIL_NODE then
          GInitStarts.AddOrSetValue(GTree.NodeLeftmostVis(LChild), True);
      end;
  end;
  LChild := GTree.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    CollectInitStarts(LChild);
    LChild := GTree.Nodes[LChild].NextSibling;
  end;
end;

procedure T1Walk(ANode: Integer; const ARoutine: string; ATypeStart: Integer);
var
  LChild: Integer;
  LRoutine: string;
begin
  LRoutine := ARoutine;
  case GTree.Nodes[ANode].Kind of
    nkAsmStmt:
      Exit;
    nkRoutine:
      begin
        LRoutine := RoutineName(ANode);
        if ARoutine <> '' then
          LRoutine := ARoutine + '.' + LRoutine;
      end;
    nkInitSec:
      LRoutine := GUnitName;
    nkFinalSec:
      LRoutine := 'Finalization';
    nkSubrange:
      ATypeStart := GTree.NodeLeftmostVis(ANode);
    nkBinaryOp, nkUnaryOp, nkInlineIf:
      begin
        if GTree.NodeLeftmostVis(ANode) = ATypeStart then
          Inc(GExcluded)
        else if GPre.VisibleToken(GTree.NodeLeftmostVis(ANode)).Kind =
                tkLBracket then
          Inc(GExcludedCtor)
        else if GInitStarts.ContainsKey(GTree.NodeLeftmostVis(ANode)) then
          Inc(GExcludedInit)
        else if (GTree.Nodes[ANode].Kind = nkUnaryOp) and
                (OpText(ANode) = '@') then
          Inc(GExcludedAt)
        else if GLinesKept and not EndsOnLineOfNext(ANode) then
          Inc(GExcludedLines)
        else
          AddParenSite(GTree.KindName(GTree.Nodes[ANode].Kind), OpsOf(ANode),
            ANode, ARoutine);
      end;
  end;
  LChild := GTree.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    T1Walk(LChild, LRoutine, ATypeStart);
    LChild := GTree.Nodes[LChild].NextSibling;
  end;
end;

{ tq: the scope in effect at ANode in the unit's model - the nearest
  scope-owning ancestor's (NodeScope is stamped on the nodes that open one). }
function TQScopeAt(ANode: Integer): Integer;
var
  LM: TPasSemaModel;
begin
  LM := GQProject.Model(GQMid);
  Result := NIL_SCOPE;
  while ANode <> NIL_NODE do
  begin
    if ANode <= High(LM.NodeScope) then
    begin
      Result := LM.NodeScope[ANode];
      if Result <> NIL_SCOPE then
        Exit;
    end;
    ANode := GTree.Nodes[ANode].Parent;
  end;
end;

{ tq: is the qualifier's first segment, at ANode, a name the unit itself
  declares or binds - a field named like the unit hides it there, and the
  qualified spelling stops the compile (plan S12, Q11: E2018). The unit's
  own scopes are asked, then the members of every open with target and of
  the method's own type, ancestors of other units included: in a logging
  library's `with TLog.Family do Level := LOG_ALL`, the family class's
  method `Logger` hides the unit Logger, and `logger.LOG_ALL` is E2003
  (spec 1.2.3 and 5.7; S16 probes N06-N09: E2018 for an inherited member, a
  with target's, a field named like a dotted entry's head). A with target
  PasTree cannot type counts as hiding it. }
function TMWithMember(ANode: Integer; const ANameLower: string;
  out ATarget, AMid, ASym: Integer; out AX: TSemaXType;
  out AUncertain: Boolean): Boolean; forward;
function TQMethodScope(AScope: Integer): Integer; forward;

{ tq: does AX's ancestry leave what PasTree can see - a class or interface
  whose chain stops short of System, its heritage naming a type of a unit
  read from a .dcu alone (cnwizards' forms descend from the IDE's
  TDockableForm, DockForm of designide)? Any name can then be a member there
  (`Controls`, TWinControl's array property, hid unit Controls: E2029), so
  the method's Self counts as hiding every qualifier head. }
function TQAncestryOpen(const AX: TSemaXType): Boolean;
var
  LCur, LNext: TSemaXType;
  LDepth: Integer;
begin
  Result := False;
  LCur := GQProject.CanonTypeX(AX);
  for LDepth := 1 to 48 do
  begin
    if not XValid(LCur) then
      Exit;
    LNext := GQProject.AncestorOfX(LCur);
    if not XValid(LNext) then
      Exit((LCur.UnitId <> GQSystemMid) and (GQProject.Model(LCur.UnitId).
        Symbols[LCur.Sym].TypeCat in [tcClass, tcInterface]));
    LCur := GQProject.CanonTypeX(LNext);
  end;
end;

{ tq: is ANameLower the name of the routine ARoutine (`TFoo.Bar`, a nested
  routine `TFoo.Bar.Inner`) or of one enclosing it? A function's own name in
  its body is its old-style result as an assignment's target - `F := X`,
  `F[I] := C` (cnwizards DCU_Out's ShortString function) - and a recursive
  call elsewhere: qualified, `Unit.F[I] :=` calls it (E2035) and
  `Self.Root :=` in `function TURI.Root` is E2064 (S16, mORMot). Neither is
  written, whatever its position. }
function TQOwnRoutine(const ARoutine, ANameLower: string): Boolean;
var
  LPart: string;
begin
  Result := False;
  for LPart in ARoutine.Split(['.']) do
    if SameText(LPart, ANameLower) then
      Exit(True);
end;

function TQShadowed(ANode: Integer; const AQualifier: string): Boolean;
var
  LM: TPasSemaModel;
  LFirst: string;
  LSym, LDot, LTarget, LMid, LCtx, LMeth: Integer;
  LX: TSemaXType;
  LUncertain: Boolean;
begin
  LM := GQProject.Model(GQMid);
  LFirst := LowerCase(AQualifier);
  LDot := Pos('.', LFirst);
  if LDot > 0 then
    LFirst := Copy(LFirst, 1, LDot - 1);
  LSym := LM.ResolveAt(TQScopeAt(ANode), LFirst,
    GTree.Nodes[ANode].FirstToken);
  Result := (LSym <> NIL_SYM) and (LM.Symbols[LSym].Kind <> skUnitRef);
  if Result then
    Exit;
  if TMWithMember(ANode, LFirst, LTarget, LMid, LSym, LX, LUncertain) or
     LUncertain then
    Exit(True);
  LMeth := TQMethodScope(TQScopeAt(ANode));
  if (LMeth <> NIL_SCOPE) and (LM.Scopes[LMeth].StructSym <> NIL_SYM) then
  begin
    LX.UnitId := GQMid;
    LX.Sym := LM.Scopes[LMeth].StructSym;
    LX.Inst := NIL_INST;
    Result := GQProject.FindMemberX(GQMid, LX, LFirst, LMid, LSym, LCtx) or
      TQAncestryOpen(LX);
  end;
end;

{ tq: the method whose body holds the scope AScope - the nearest routine
  scope a struct is stamped on (a method implementation's: TFoo in
  TFoo.Bar), through nested routines and anonymous methods, whose Self is
  the method's. NIL_SCOPE outside every method. }
function TQMethodScope(AScope: Integer): Integer;
var
  LM: TPasSemaModel;
begin
  LM := GQProject.Model(GQMid);
  Result := AScope;
  while Result <> NIL_SCOPE do
  begin
    if (LM.Scopes[Result].Kind = sckRoutine) and
       (LM.Scopes[Result].StructSym <> NIL_SYM) then
      Exit;
    Result := LM.Scopes[Result].Parent;
  end;
end;

{ tq: the units whose interface a bare name at ANode can come from, in
  dcc's search order: the unit itself, its uses entries from the last to
  the first - an implementation uses entry only inside the implementation -
  then SysInit and System, which every unit uses without naming them. An
  entry the analysis did not resolve is left out. }
function TQVisibleUnits(ANode: Integer): TArray<Integer>;
var
  LM: TPasSemaModel;
  LIdx, LId: Integer;
begin
  LM := GQProject.Model(GQMid);
  Result := [GQMid];
  for LIdx := High(LM.UsesList) downto 0 do
  begin
    if (LM.UsesList[LIdx].NameNode <> NIL_NODE) and
       (GTree.Nodes[LM.UsesList[LIdx].NameNode].FirstToken > GQImplTok) and
       (GTree.Nodes[ANode].FirstToken < GQImplTok) then
      Continue;
    LId := LM.UsesList[LIdx].UnitId;
    if (LId >= 0) and (LId <> GQMid) then
      Result := Result + [LId];
  end;
  if GQSysInitMid >= 0 then
    Result := Result + [GQSysInitMid];
  if GQSystemMid >= 0 then
    Result := Result + [GQSystemMid];
end;

{ tq: the qualifier that names unit AMid in this unit's code - the unit's
  own name, `system` / `sysinit`, else its uses entry AS WRITTEN. dcc finds
  a qualifier's first segment among the names written in the uses clauses
  (and System): under `uses Windows` (Winapi.Windows through -NS),
  `Winapi.Windows.X` is E2003 on `Winapi`, `Windows.X` is the same .dcu
  (spec 1.2.3; S16 probes N01-N05: `System.Classes.X` under `uses Classes`
  compiles only because its first segment is System). The full name when
  no entry names the unit (a binding TQUnitVisible then refuses). }
function TQUnitSpelling(AMid: Integer): string;
var
  LM: TPasSemaModel;
  LIdx: Integer;
begin
  if AMid = GQSystemMid then
    Exit('system');
  if AMid = GQSysInitMid then
    Exit('sysinit');
  if AMid <> GQMid then
  begin
    LM := GQProject.Model(GQMid);
    for LIdx := 0 to High(LM.UsesList) do
      if (LM.UsesList[LIdx].UnitId = AMid) and
         (LM.UsesList[LIdx].NameFull <> '') then
        Exit(LowerCase(LM.UsesList[LIdx].NameFull));
  end;
  Result := GQProject.Model(AMid).UnitNameLower;
end;

{ tq: the symbol named like ANode that unit AMid declares where an importer
  - or, for the unit itself, the unit's own code - finds it: its interface,
  and for the unit itself its implementation too. NIL_SYM when none. }
function TQUnitDecl(AMid: Integer; const AName: string): Integer;
var
  LU: TPasSemaModel;
  LIdx: Integer;
begin
  Result := NIL_SYM;
  LU := GQProject.Model(AMid);
  if LU.InterfaceScope <> NIL_SCOPE then
    Result := LU.FindLocal(LU.InterfaceScope, AName);
  if (Result = NIL_SYM) and (AMid = GQMid) then
    for LIdx := 0 to LU.Scopes.Count - 1 do
      if LU.Scopes[LIdx].Kind = sckImplementation then
      begin
        Result := LU.FindLocal(LIdx, AName);
        Break;
      end;
end;

{ tq: the unit whose declaration a bound name names - System for one of
  the builtins every model seeds (ASystem), else ATMid. -1 when System is
  no model of the analysis. }
function TQChosenUnit(ATMid: Integer; ASystem: Boolean): Integer;
begin
  if ASystem then
    Result := GQSystemMid
  else
    Result := ATMid;
end;

{ tq: does another unit visible at ANode declare a routine named like it?
  Then the name is one of an overload set dcc merges across units (plan
  S12, Q09) and the qualified spelling does not keep the .dcu: dcc records
  every unit's routine it LOOKED at as an import, used or not - in
  PasTree.Dcu.Source `IfThen(B, 2, 1)` is System.Math's and the original
  imports System.StrUtils' IfThen too; in System.AnsiStrings its own
  FormatBuf and AnsiUpperCase merge with System.SysUtils'. The qualified
  spelling looks at one unit, so the import record differs, or the call
  takes another overload of the set. Not judged: which unit of a merged set
  a call takes (the count says how often that is left). }
{ tq: is routine ASym of model AMid one of an overload set - more than one
  routine of the name, or a declaration carrying `overload` (the model sets
  sfOverload only on a chain's later links). }
function TQMarkedOverload(AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
  LNode, LChild: Integer;
begin
  LM := GQProject.Model(AMid);
  if LM.Symbols[ASym].Kind <> skRoutine then
    Exit(False);
  if LM.Symbols[ASym].NextOverload <> NIL_SYM then
    Exit(True);
  Result := False;
  LNode := LM.Symbols[ASym].DeclNode;
  if LNode = NIL_NODE then
    Exit;
  if LM.Tree.Nodes[LNode].Kind = nkIdent then
    LNode := LM.Tree.Nodes[LNode].Parent;
  if LNode = NIL_NODE then
    Exit;
  LChild := LM.Tree.Nodes[LNode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if (LM.Tree.Nodes[LChild].Kind = nkDirective) and
       SameText(LM.Tree.NodeText(LChild), 'overload') then
      Exit(True);
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
end;

function TQOverloadMerged(ANode, ATMid: Integer; ASystem: Boolean): Boolean;
var
  LName: string;
  LChosen, LId, LSym: Integer;
  LOverload: Boolean;
begin
  Result := False;
  LName := LowerCase(GTree.NodeText(ANode).TrimLeft(['&']));
  LChosen := TQChosenUnit(ATMid, ASystem);
  // A builtin System.pas also DECLARES: bare `Flush(Output)` is the
  // intrinsic, with its I/O check, `System.Flush(Output)` the function
  // declared there, without one - another call, whichever of the two PasTree
  // took (S14, System.SysUtils.ShowException: the function).
  if (ASystem or (ATMid = GQSystemMid)) and (GQSystemMid >= 0) then
  begin
    LSym := TQUnitDecl(GQSystemMid, LName);
    if (LSym <> NIL_SYM) and
       (GQProject.Model(GQSystemMid).Symbols[LSym].Kind = skRoutine) and
       not (sfBuiltin in GQProject.Model(GQSystemMid).Symbols[LSym].Flags) and
       (GQProject.Model(GQMid).SystemScope <> NIL_SCOPE) then
    begin
      LSym := GQProject.Model(GQMid).FindLocal(
        GQProject.Model(GQMid).SystemScope, LName);
      if (LSym <> NIL_SYM) and
         (sfBuiltin in GQProject.Model(GQMid).Symbols[LSym].Flags) then
        Exit(True);
    end;
  end;
  // A routine marked `overload` makes dcc search on through the other units,
  // and it imports whatever declaration of the name it meets there, of any
  // kind: a library unit calls its own overloaded `Lock`, a unit it uses
  // declares a record `Lock`, and the bare call imports the record (spec
  // 6.3.1; S16 probes O01-O05: O01 a type, O05 an unchosen overload of
  // another unit DIFF, O02 without `overload` SAME).
  LOverload := False;
  if LChosen >= 0 then
  begin
    LSym := TQUnitDecl(LChosen, LName);
    LOverload := (LSym <> NIL_SYM) and TQMarkedOverload(LChosen, LSym);
  end;
  for LId in TQVisibleUnits(ANode) do
  begin
    if LId = LChosen then
      Continue;
    LSym := TQUnitDecl(LId, LName);
    if (LSym <> NIL_SYM) and
       (LOverload or
        (GQProject.Model(LId).Symbols[LSym].Kind = skRoutine)) and
       not (sfBuiltin in GQProject.Model(LId).Symbols[LSym].Flags) then
      Exit(True);
  end;
end;

{ tq: is ATMid (ASystem: System) one of the units a name at ANode can come
  from at all? A binding to any other unit is wrong whatever dcc says - an
  interface name bound through an implementation uses entry, a declaration
  of a unit the unit does not use - and the qualified spelling would only
  stop the compile (E2003 on the qualifier). Such a binding is reported, not
  written (see TQIdent). }
function TQUnitVisible(ANode, ATMid: Integer; ASystem: Boolean): Boolean;
var
  LChosen, LId: Integer;
begin
  if ASystem then
    Exit(True);
  LChosen := TQChosenUnit(ATMid, ASystem);
  for LId in TQVisibleUnits(ANode) do
    if LId = LChosen then
      Exit(True);
  Result := False;
end;

{ tq: is ARoutine's body one dcc stores as a GENERIC's - its name has
  generic parameters at any level (`TG<T>.M`, `TFoo.M<T>`)? `Self.F` after a
  call of a method there changes one flag byte of the stored body and its
  checksum - in the method's own body, and in an inline method's, in the
  body of the method that expands it (plan S13, probes Q43 and Q46 DIFF for
  a record and a class, Q44, Q45, Q47 SAME for a plain and an inline
  method of a plain type; Q40 for the inline case; dcc64 and dcc32 37.0):
  no code, but no identical .dcu either. }
function TQGenericBody(ARoutine: Integer): Boolean;
var
  LChild: Integer;
begin
  Result := False;
  LChild := GTree.Nodes[ARoutine].FirstChild;
  while (LChild <> NIL_NODE) and
        (GTree.Nodes[LChild].Kind in [nkIdent, nkGenericParams, nkTypeArgs]) do
  begin
    if GTree.Nodes[LChild].Kind <> nkIdent then
      Exit(True);
    LChild := GTree.Nodes[LChild].NextSibling;
  end;
end;

{ tqs: a WRONG qualifier for ANode, bound by PasTree to a declaration of
  unit ATMid (ASystem: one of System's): another unit visible there whose
  interface declares a variable or a routine of that name, a distinct
  entity dcc would accept the spelling of. Not a type or a constant: an
  alias or an equal value would compile to the same .dcu, and the selftest
  would blame the comparator for a site that is not wrong. '' when there is
  none. }
function TQWrongQualifier(ANode, ATMid: Integer; ASystem: Boolean): string;
var
  LU: TPasSemaModel;
  LName: string;
  LChosen, LId, LSym: Integer;
begin
  Result := '';
  LName := LowerCase(GTree.NodeText(ANode).TrimLeft(['&']));
  LChosen := TQChosenUnit(ATMid, ASystem);
  for LId in TQVisibleUnits(ANode) do
  begin
    if (LId = LChosen) or (LId = GQMid) then
      Continue;
    LU := GQProject.Model(LId);
    LSym := TQUnitDecl(LId, LName);
    if (LSym <> NIL_SYM) and (LU.Symbols[LSym].Kind in [skVar, skRoutine]) and
       not (sfBuiltin in LU.Symbols[LSym].Flags) and
       not TQShadowed(ANode, TQUnitSpelling(LId)) then
      Exit(TQUnitSpelling(LId) + '.');
  end;
end;

{ tq: is ANode the first segment of a unit name written as a qualifier -
  the base of a member access, spelling a prefix of the unit's own name,
  System's, SysInit's or a used unit's? Only some of those are bound to a
  uses entry; the unit's own name and the two implicit units are no symbol
  at all (`SysInit.HInstance`, Vcl.Dialogs). }
function TQUnitSegment(ANode: Integer): Boolean;
var
  LM: TPasSemaModel;
  LText, LName: string;
  LIdx: Integer;

  function Prefix(const AUnit: string): Boolean;
  begin
    Result := SameText(AUnit, LText) or
      AUnit.StartsWith(LText + '.', True);
  end;

begin
  Result := False;
  if (GTree.Nodes[ANode].Parent = NIL_NODE) or
     (GTree.Nodes[GTree.Nodes[ANode].Parent].Kind <> nkMember) or
     (GTree.Nodes[GTree.Nodes[ANode].Parent].FirstChild <> ANode) then
    Exit;
  LM := GQProject.Model(GQMid);
  LText := GTree.NodeText(ANode).TrimLeft(['&']);
  if Prefix(LM.UnitNameLower) or Prefix('system') or Prefix('sysinit') then
    Exit(True);
  for LIdx := 0 to High(LM.UsesList) do
  begin
    LName := LM.UsesList[LIdx].NameFull;
    if Prefix(LName) then
      Exit(True);
  end;
end;

function IsStoredBody(ARoutine: Integer): Boolean; forward;
procedure CollectInlineNames(ANode: Integer); forward;

{ tq: GQHistory - every bare name in the body of a method of a NESTED type
  (`procedure TOuter.TInner.M`) that an OUTER type has as a member, with the
  last token it is written at. dcc resolves such a name to the outer type's
  member unless the unit wrote it bare BEFORE, meaning a used unit's
  declaration or an intrinsic (spec 3.3.2, step 5; F42): Vcl.StdCtrls'
  `StyleServices(Self)` calls make
  TScrollBarStyleHook.TScrollWindow.WMPaint's `StyleServices` Vcl.Themes'
  function, and qualifying them turns WMPaint into an E2124. The earlier
  bare uses of such a name are left as written - `Default`'s rule (S15)
  without the list of names. }
procedure TQCollectHistory(ANode: Integer; const AOuters: TArray<TSemaXType>);
var
  LChild, LName, LParent, LOld, LCount, LMid, LSym, LCtx: Integer;
  LSegs: TArray<Integer>;
  LOuters: TArray<TSemaXType>;
  LX: TSemaXType;
  LM: TPasSemaModel;
  LKey: string;
begin
  LOuters := AOuters;
  case GTree.Nodes[ANode].Kind of
    nkRoutine:
      begin
        // An implementation's qualified name is a run of flat children
        // marked nfName; with three or more (`TOuter.TInner.M`) the ones
        // before the method's own type are its OUTER types.
        LSegs := nil;
        LName := GTree.Nodes[ANode].FirstChild;
        while LName <> NIL_NODE do
        begin
          if nfName in GTree.Nodes[LName].Flags then
            LSegs := LSegs + [LName];
          LName := GTree.Nodes[LName].NextSibling;
        end;
        if Length(LSegs) >= 3 then
        begin
          // The segments are declaration names, in no map: the first is
          // looked up from the routine's own scope, each further one as a
          // member of the one before.
          LOuters := nil;
          LM := GQProject.Model(GQMid);
          LSym := NIL_SYM;
          if (ANode <= High(LM.NodeScope)) and
             (LM.NodeScope[ANode] <> NIL_SCOPE) then
            LSym := LM.Resolve(LM.NodeScope[ANode],
              LowerCase(GTree.NodeText(LSegs[0])));
          if (LSym <> NIL_SYM) and (LM.Symbols[LSym].Kind = skType) then
          begin
            LX := XPlain(GQMid, LSym);
            LOuters := [LX];
            for LCount := 1 to High(LSegs) - 2 do
              if GQProject.FindMemberX(GQMid, LX,
                   LowerCase(GTree.NodeText(LSegs[LCount])), LMid, LSym,
                   LCtx) and
                 (GQProject.Model(LMid).Symbols[LSym].Kind = skType) then
              begin
                LX := XPlain(LMid, LSym);
                LOuters := LOuters + [LX];
              end
              else
                Break;
          end;
        end;
      end;
    nkIdent:
      if LOuters <> nil then
      begin
        LParent := GTree.Nodes[ANode].Parent;
        if not ((LParent <> NIL_NODE) and
           (GTree.Nodes[LParent].Kind = nkMember) and
           (GTree.Nodes[LParent].FirstChild <> ANode)) then
        begin
          LKey := LowerCase(GTree.NodeText(ANode).TrimLeft(['&']));
          // Only a name an outer type has as a member: the only one whose
          // meaning the history can change.
          for LCount := 0 to High(LOuters) do
            if GQProject.FindMemberX(GQMid, LOuters[LCount], LKey, LMid, LSym,
               LCtx) then
            begin
              if not GQHistory.TryGetValue(LKey, LOld) or
                 (LOld < GTree.Nodes[ANode].FirstToken) then
                GQHistory.AddOrSetValue(LKey, GTree.Nodes[ANode].FirstToken);
              Break;
            end;
        end;
      end;
  end;
  LChild := GTree.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    TQCollectHistory(LChild, LOuters);
    LChild := GTree.Nodes[LChild].NextSibling;
  end;
end;

{ tm: the node defining type symbol ASym of model AMid - the struct, alias
  or other type expression after the name (TPasSemaProject.TypeDefNodeIn,
  which is private, read the same way). NIL_NODE for anything else. }
function TMTypeDef(AMid, ASym: Integer): Integer;
var
  LM: TPasSemaModel;
  LName, LParent: Integer;
begin
  Result := NIL_NODE;
  LM := GQProject.Model(AMid);
  if LM.Symbols[ASym].Kind <> skType then
    Exit;
  LName := LM.Symbols[ASym].DeclNode;
  if LName = NIL_NODE then
    Exit;
  if LM.Tree.Nodes[LName].Kind in [nkRecordType, nkClassType, nkInterfaceType,
     nkObjectType, nkHelperType] then
    Exit(LName);
  LParent := LM.Tree.Nodes[LName].Parent;
  if (LParent = NIL_NODE) or (LM.Tree.Nodes[LParent].Kind <> nkTypeDecl) then
    Exit;
  Result := LM.Tree.Nodes[LName].NextSibling;
  while (Result <> NIL_NODE) and
        (LM.Tree.Nodes[Result].Kind = nkGenericParams) do
    Result := LM.Tree.Nodes[Result].NextSibling;
end;

{ tm: the spelling that names type ASym of model AMid from any unit that
  sees it - `<unit.full.name>.TName`, a nested type through its outer
  types, `unit.TOuter.TInner`. '' with AWhy when there is none a cast can
  use: a generic type (the cast would need its arguments), one declared in
  a routine or anonymous, a nested type of another unit declared outside its
  public sections. }
function TMTypeSpelling(AMid, ASym: Integer; out AWhy: TTMExcl): string;
var
  LU: TPasSemaModel;
  LScope: Integer;
begin
  Result := '';
  AWhy := tmeLocalType;
  LU := GQProject.Model(AMid);
  if (ASym = NIL_SYM) or (LU.Symbols[ASym].Kind <> skType) or
     (LU.Symbols[ASym].DeclNode = NIL_NODE) or
     (GQProject.Model(AMid).Tree.Nodes[LU.Symbols[ASym].DeclNode].Kind <>
      nkIdent) then
    Exit;
  if sfGeneric in LU.Symbols[ASym].Flags then
  begin
    AWhy := tmeGeneric;
    Exit;
  end;
  LScope := LU.Symbols[ASym].Scope;
  if LScope = NIL_SCOPE then
    Exit;
  case LU.Scopes[LScope].Kind of
    sckUnit, sckImplementation:
      if LU.UnitNameLower <> '' then
        Result := TQUnitSpelling(AMid) + '.' + LU.Symbols[ASym].Name;
    sckStruct:
      begin
        if (AMid <> GQMid) and (LU.Symbols[ASym].Visibility in
           [svStrictPrivate, svPrivate, svStrictProtected, svProtected]) then
        begin
          AWhy := tmeHidden;
          Exit;
        end;
        Result := TMTypeSpelling(AMid, LU.Scopes[LScope].StructSym, AWhy);
        if Result <> '' then
          Result := Result + '.' + LU.Symbols[ASym].Name;
      end;
  end;
end;

{ tm: the type that declares member ASym of model AMid - the struct whose
  member scope holds it. False for anything that is no struct's member. }
function TMOwner(AMid, ASym: Integer; out AOwner: TSemaXType): Boolean;
var
  LU: TPasSemaModel;
  LScope: Integer;
begin
  Result := False;
  AOwner := XNil;
  LU := GQProject.Model(AMid);
  LScope := LU.Symbols[ASym].Scope;
  if (LScope = NIL_SCOPE) or (LU.Scopes[LScope].Kind <> sckStruct) or
     (LU.Scopes[LScope].StructSym = NIL_SYM) then
    Exit;
  AOwner := XPlain(AMid, LU.Scopes[LScope].StructSym);
  Result := True;
end;

{ tm: the category of type AX through its alias links - a class, a pointer,
  a class reference... - tcUnknown when there is no type. }
function TMCategory(const AX: TSemaXType): TSemaTypeCat;
var
  LX: TSemaXType;
begin
  Result := tcUnknown;
  if not XValid(AX) then
    Exit;
  LX := GQProject.CanonTypeX(AX);
  if XValid(LX) then
    Result := GQProject.Model(LX.UnitId).Symbols[LX.Sym].TypeCat;
end;

{ tm: is AOwner AX itself or one of its ancestors - a class's, an
  interface's - through alias links? An instantiation frame is not compared:
  the owner is the declaration. }
function TMDescends(const AX, AOwner: TSemaXType): Boolean;
var
  LCur: TSemaXType;
  LDepth: Integer;
begin
  Result := False;
  LCur := AX;
  for LDepth := 1 to 48 do
  begin
    if not XValid(LCur) then
      Exit;
    LCur := GQProject.CanonTypeX(LCur);
    if (LCur.UnitId = AOwner.UnitId) and (LCur.Sym = AOwner.Sym) then
      Exit(True);
    LCur := GQProject.AncestorOfX(LCur);
  end;
end;

{ tm: is ANode, a base expression, a unit name or a prefix of one written
  as a qualifier - `SysUtils`, `System.SysUtils`? }
function TMUnitChain(ANode: Integer): Boolean;
var
  LM: TPasSemaModel;
  LText, LName: string;
  LIdx: Integer;

  function Prefix(const AUnit: string): Boolean;
  begin
    Result := SameText(AUnit, LText) or AUnit.StartsWith(LText + '.', True);
  end;

  function Chain(N: Integer): string;
  begin
    case GTree.Nodes[N].Kind of
      nkIdent:
        Result := GTree.NodeText(N).TrimLeft(['&']);
      nkMember:
        if (GTree.Nodes[N].FirstChild <> NIL_NODE) and
           (GTree.Nodes[GTree.Nodes[N].FirstChild].NextSibling <> NIL_NODE) and
           (GTree.Nodes[GTree.Nodes[GTree.Nodes[N].FirstChild].NextSibling].
             Kind = nkIdent) then
        begin
          Result := Chain(GTree.Nodes[N].FirstChild);
          if Result <> '' then
            Result := Result + '.' + GTree.NodeText(
              GTree.Nodes[GTree.Nodes[N].FirstChild].NextSibling).TrimLeft(['&']);
        end
        else
          Result := '';
    else
      Result := '';
    end;
  end;

begin
  Result := False;
  LText := Chain(ANode);
  if LText = '' then
    Exit;
  LM := GQProject.Model(GQMid);
  if Prefix(LM.UnitNameLower) or Prefix('system') or Prefix('sysinit') then
    Exit(True);
  for LIdx := 0 to High(LM.UsesList) do
  begin
    LName := LM.UsesList[LIdx].NameFull;
    if Prefix(LName) then
      Exit(True);
  end;
end;

procedure TMExclude(AWhy: TTMExcl);
begin
  Inc(GMExcl[AWhy]);
end;

procedure TMMismatch(ANode: Integer; const AWhat, ARoutine: string);
begin
  Inc(GMMismatch);
  GMMismatchList.Add(SpanText(GTree.Nodes[ANode].FirstToken,
    GTree.Nodes[ANode].FirstToken) + #9 + GTree.NodeText(ANode) + #9 +
    ARoutine + #9 + AWhat);
end;

{ tm: may member (AMid, ASym) be reached through a cast to its owner at
  all? Not a protected or private member of another unit's type, and not
  one a stored body of the unit reads (see TTMExcl). Counts the refusal. }
function TMMemberCastable(AMid, ASym: Integer): Boolean;
begin
  Result := False;
  if (AMid <> GQMid) and (GQProject.Model(AMid).Symbols[ASym].Visibility in
     [svStrictPrivate, svPrivate, svStrictProtected, svProtected]) then
  begin
    TMExclude(tmeProtected);
    Exit;
  end;
  if GMStoredUse.ContainsKey((Int64(AMid) shl 32) or Cardinal(ASym)) then
  begin
    TMExclude(tmeStoredUse);
    Exit;
  end;
  Result := True;
end;

{ tm: GMStoredUse - every member a stored body (a generic's, an inline
  routine's) of the subtree at ANode reads: the binding of each identifier
  and default-property index node there that names a struct's member. }
procedure TMCollectStored(ANode: Integer; AStored: Boolean);
var
  LChild, LMid, LSym, LScope: Integer;
  LM: TPasSemaModel;
  LExt: TPasExtRef;
begin
  if (GTree.Nodes[ANode].Kind = nkRoutine) and IsStoredBody(ANode) then
    AStored := True;
  if AStored and (GTree.Nodes[ANode].Kind in [nkIdent, nkIndex]) then
  begin
    LM := GQProject.Model(GQMid);
    LMid := GQMid;
    LSym := LM.RefMap[ANode];
    if (LSym = NIL_SYM) and LM.ExtRefMap.TryGetValue(ANode, LExt) then
    begin
      LMid := LExt.UnitId;
      LSym := LExt.Sym;
    end;
    if LSym <> NIL_SYM then
    begin
      LScope := GQProject.Model(LMid).Symbols[LSym].Scope;
      if (LScope <> NIL_SCOPE) and
         (GQProject.Model(LMid).Scopes[LScope].Kind = sckStruct) then
        GMStoredUse.AddOrSetValue((Int64(LMid) shl 32) or Cardinal(LSym), True);
    end;
  end;
  LChild := GTree.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    TMCollectStored(LChild, AStored);
    LChild := GTree.Nodes[LChild].NextSibling;
  end;
end;

{ tm: may a cast to AOwner (spelled ASpelling) stand at ANode? The owner's
  unit must be one a name there can come from, an own owner declared
  already, the spelling's first segment not hidden there. Counts the
  refusal. }
function TMCastAllowed(ANode: Integer; const AOwner: TSemaXType;
  const ASpelling: string): Boolean;
var
  LU: TPasSemaModel;
begin
  Result := False;
  if not TQUnitVisible(ANode, AOwner.UnitId, False) then
  begin
    TMExclude(tmeUnseen);
    Exit;
  end;
  LU := GQProject.Model(AOwner.UnitId);
  if (AOwner.UnitId = GQMid) and
     (GTree.Nodes[LU.Symbols[AOwner.Sym].DeclNode].FirstToken >
      GTree.Nodes[ANode].FirstToken) then
  begin
    TMExclude(tmeForward);
    Exit;
  end;
  if TQShadowed(ANode, ASpelling) then
  begin
    TMExclude(tmeShadowed);
    Exit;
  end;
  Result := True;
end;

{ tm: the top-level declaration holding ANode, where its preamble goes (see
  TMPreamble): the child of the implementation section (of a program's
  root) it lies in, an attribute group before it included; for the
  finalization section the initialization section - nothing may stand
  between the two. }
function TMAnchor(ANode: Integer): Integer;
var
  LParent, LPrev, LChild: Integer;
begin
  Result := ANode;
  LParent := GTree.Nodes[Result].Parent;
  while (LParent <> NIL_NODE) and not (GTree.Nodes[LParent].Kind in
        [nkImplementationSec, nkUnit, nkProgram, nkLibrary]) do
  begin
    Result := LParent;
    LParent := GTree.Nodes[Result].Parent;
  end;
  if LParent = NIL_NODE then
    Exit;
  LPrev := NIL_NODE;
  LChild := GTree.Nodes[LParent].FirstChild;
  while (LChild <> NIL_NODE) and (LChild <> Result) do
  begin
    if (GTree.Nodes[Result].Kind = nkFinalSec) and
       (GTree.Nodes[LChild].Kind = nkInitSec) then
      Exit(LChild);
    LPrev := LChild;
    LChild := GTree.Nodes[LChild].NextSibling;
  end;
  if (LPrev <> NIL_NODE) and (GTree.Nodes[LPrev].Kind = nkAttrGroup) then
    Result := LPrev;
end;

{ tm: a cast at ANode names type ASpelling of unit AOwnerMid - the
  preamble names it first, before ANode's top-level declaration, unless an
  earlier preamble did or the type is the unit's own. }
procedure TMNeedType(ANode: Integer; const ASpelling: string;
  AOwnerMid: Integer);
var
  LAnchor: Integer;
  LText: string;
begin
  if (AOwnerMid = GQMid) or (GMPreamble.IndexOf(ASpelling) >= 0) then
    Exit;
  GMPreamble.Add(ASpelling);
  LAnchor := TMAnchor(ANode);
  if not GMAnchors.TryGetValue(LAnchor, LText) then
    LText := '';
  GMAnchors.AddOrSetValue(LAnchor, LText + Format(' V%d: %s;',
    [GMPreamble.Count, ASpelling]));
end;

{ tm: a site casting the base expression ABase to ASpelling -
  `<ASpelling>(Base)` - with `^` inside the cast for a pointer the original
  dereferences implicitly, and ATail after it (a default property's name).
  The opening sorts before every other insertion at its token, an outer
  cast (the longer base) first. The type joins the preamble when it is
  another unit's. Dropped and counted when the base spans two files or lies
  in a file included twice. }
procedure AddCastSite(const AKind, ASpelling: string; ABase: Integer;
  ADeref: Boolean; const ATail, AOps, ARoutine: string; AOwnerMid: Integer);
var
  LFirst, LLast, LFileA, LFileB: Integer;
  LSite: TSite;
begin
  if GQSymInfoOn then
  begin
    TMExclude(tmeSymInfo);
    Exit;
  end;
  LFirst := GTree.NodeLeftmostVis(ABase);
  LLast := GTree.Nodes[ABase].LastToken;
  VisOffset(LFirst, LFileA);
  VisOffset(LLast, LFileB);
  if (LFileA <> LFileB) or GIncludedTwice[LFileA] then
  begin
    Inc(GDropped);
    Exit;
  end;
  LSite := Default(TSite);
  LSite.Kind := AKind;
  LSite.Ops := AOps;
  LSite.Span := SpanText(LFirst, LLast);
  LSite.Routine := ARoutine;
  LSite.Edit := ASpelling + '()' + ATail;
  LSite.OpenVis := LFirst;
  LSite.CloseVis := LLast;
  LSite.OpenText := ASpelling + '(';
  LSite.OpenOrder := -1 - LLast;
  if ADeref then
    LSite.CloseText := '^)' + ATail
  else
    LSite.CloseText := ')' + ATail;
  LSite.CloseOrder := 0;
  GSites.Add(LSite);
  TMNeedType(ABase, ASpelling, AOwnerMid);
end;

{ tms: a WRONG owner for member (AMid, ASym) of AOwner - the nearest
  ancestor of AOwner declaring a field or routine of that name that is
  another entity: not one an `override` of the member continues (one VMT
  slot, one code). '' when there is none, or none a cast can spell. }
function TMWrongOwner(ANode, AMid, ASym: Integer;
  const AOwner: TSemaXType; out AWrong: TSemaXType): string;
var
  LU: TPasSemaModel;
  LAnc: TSemaXType;
  LMid, LSym, LCtx, LChild, LDecl: Integer;
  LWhy: TTMExcl;
begin
  Result := '';
  AWrong := XNil;
  LU := GQProject.Model(AMid);
  if not (LU.Symbols[ASym].Kind in [skField, skRoutine]) then
    Exit;
  // An override shares its ancestor's slot.
  LDecl := LU.Symbols[ASym].DeclNode;
  if (LDecl <> NIL_NODE) and (LU.Tree.Nodes[LDecl].Parent <> NIL_NODE) and
     (LU.Tree.Nodes[LU.Tree.Nodes[LDecl].Parent].Kind = nkRoutine) then
  begin
    LChild := LU.Tree.Nodes[LU.Tree.Nodes[LDecl].Parent].FirstChild;
    while LChild <> NIL_NODE do
    begin
      if (LU.Tree.Nodes[LChild].Kind = nkDirective) and
         SameText(LU.Tree.NodeText(LChild), 'override') then
        Exit;
      LChild := LU.Tree.Nodes[LChild].NextSibling;
    end;
  end;
  // A routine marked overload: the call may land in an ancestor's overload,
  // and the planted owner be the right one (S16: Vcl.WinXCtrls
  // `FButtonImages.Draw(C, X, Y, I, E)` is TCustomImageList's, PasTree took
  // TVirtualImageList's `Draw(..., Name: String)` - the blind spot of a
  // declaring type above the chosen one). No plant there.
  if TQMarkedOverload(AMid, ASym) then
    Exit;
  LAnc := GQProject.AncestorOfX(AOwner);
  if not XValid(LAnc) then
    Exit;
  if not GQProject.FindMemberX(GQMid, LAnc, LU.Symbols[ASym].NameLower, LMid,
     LSym, LCtx) then
    Exit;
  if (LMid = AMid) and (LSym = ASym) then
    Exit;
  if GQProject.Model(LMid).Symbols[LSym].Kind <> LU.Symbols[ASym].Kind then
    Exit;
  // One dcc would accept: not another unit's hidden member (E2362).
  if (LMid <> GQMid) and (GQProject.Model(LMid).Symbols[LSym].Visibility in
     [svStrictPrivate, svPrivate, svStrictProtected, svProtected]) then
    Exit;
  if not TMOwner(LMid, LSym, AWrong) then
    Exit;
  Result := TMTypeSpelling(AWrong.UnitId, AWrong.Sym, LWhy);
  if (Result <> '') and (not TQUnitVisible(ANode, AWrong.UnitId, False) or
     TQShadowed(ANode, Result)) then
    Result := '';
end;

{ tm: the member, bound to (AMid, ASym), reached through base expression
  ABase - the selector of `Base.Name`, or a default array property's
  `Base[I]` (ATail `.Name`). The site casts the base to the type PasTree
  says declares the member (plan S15): dcc then looks the name up there, so
  a member of another type - a descendant's namesake hiding it (Q13, Q78),
  another field of the same name - changes the code or stops the compile.
  Whatever the cast cannot say is counted (TTMExcl), and a binding PasTree's
  own typing of the base contradicts is listed. }
{ tm: is ABase a bare `Self` in a class method (its routine node's Aux 1,
  as tq's static rule reads it), through nested routines? }
function TMClassSelf(ABase: Integer): Boolean;
var
  LMeth: Integer;
begin
  Result := False;
  if (GTree.Nodes[ABase].Kind <> nkIdent) or
     not SameText(GTree.NodeText(ABase), 'self') then
    Exit;
  LMeth := TQMethodScope(TQScopeAt(ABase));
  Result := (LMeth <> NIL_SCOPE) and
    (GTree.Nodes[GQProject.Model(GQMid).Scopes[LMeth].OwnerNode].Aux = 1);
end;

{ tm, Win32 only: is ABase a plain variable or parameter of an ENCLOSING
  routine, reached from a nested one (or the outer method's Self)? dcc32
  lays out the frame slots of such variables by their references, and a
  write through a cast of one after another up-level reference moves the
  slots - the same code over another frame (S16 probes m5/m6; mORMot
  SynCrtSock `integer(ClientSock.fCompressAcceptHeader) := 0` in the nested
  SendResponse). dcc64 keeps the layout. }
function TMUpLevel(ABase: Integer): Boolean;
var
  LM: TPasSemaModel;
  LScope, LRoutine, LSym: Integer;
begin
  Result := False;
  if not GQWin32 or (GTree.Nodes[ABase].Kind <> nkIdent) then
    Exit;
  LM := GQProject.Model(GQMid);
  LScope := TQScopeAt(ABase);
  LRoutine := LScope;
  while (LRoutine <> NIL_SCOPE) and (LM.Scopes[LRoutine].Kind <> sckRoutine) do
    LRoutine := LM.Scopes[LRoutine].Parent;
  if LRoutine = NIL_SCOPE then
    Exit;
  if SameText(GTree.NodeText(ABase), 'self') then
    Exit(LM.Scopes[LRoutine].StructSym = NIL_SYM);
  LSym := LM.ResolveAt(LScope, LowerCase(GTree.NodeText(ABase)),
    GTree.Nodes[ABase].FirstToken);
  Result := (LSym <> NIL_SYM) and (LM.Symbols[LSym].Kind in [skVar, skParam]) and
    (LM.Symbols[LSym].Scope <> NIL_SCOPE) and
    (LM.Scopes[LM.Symbols[LSym].Scope].Kind = sckRoutine) and
    (LM.Symbols[LSym].Scope <> LRoutine);
end;

procedure TMMember(ASite, ABase, AMid, ASym: Integer; const ATail,
  AKind, ARoutine: string; AStored: Boolean);
var
  LU: TPasSemaModel;
  LOwner, LBX, LWrong: TSemaXType;
  LSpelling: string;
  LWhy: TTMExcl;
  LDeref: Boolean;
  LBMid, LBSym, LDef, LHead: Integer;
begin
  LU := GQProject.Model(AMid);
  if not TMOwner(AMid, ASym, LOwner) then
  begin
    TMExclude(tmeLocalType);
    Exit;
  end;
  // The base names a type or a unit, not a value.
  if TMUnitChain(ABase) then
  begin
    TMExclude(tmeQualified);
    Exit;
  end;
  if GTree.Nodes[ABase].Kind = nkInherited then
  begin
    TMExclude(tmePosition);
    Exit;
  end;
  // A base at the head of what follows `inherited` - `inherited
  // Padding.PaddingRect(R)` (FMX.Forms): `inherited TBounds(Padding).X` is
  // no designator (E2003 on the cast's unit), as tq leaves the head itself.
  LHead := ABase;
  while (GTree.Nodes[LHead].Parent <> NIL_NODE) and
        (GTree.Nodes[GTree.Nodes[LHead].Parent].Kind in [nkCall, nkIndex,
          nkMember]) and
        (GTree.Nodes[GTree.Nodes[LHead].Parent].FirstChild = LHead) do
    LHead := GTree.Nodes[LHead].Parent;
  if (GTree.Nodes[LHead].Parent <> NIL_NODE) and
     (GTree.Nodes[GTree.Nodes[LHead].Parent].Kind = nkInherited) then
  begin
    TMExclude(tmePosition);
    Exit;
  end;
  if GQProject.DesignatorSymX(GQMid, ABase, LBMid, LBSym) then
    case GQProject.Model(LBMid).Symbols[LBSym].Kind of
      skType, skBuiltinType:
        if not (GTree.Nodes[ABase].Kind in [nkCall, nkIndex, nkDeref]) then
        begin
          TMExclude(tmeTypeBase);
          Exit;
        end;
      skUnitRef:
        begin
          TMExclude(tmeQualified);
          Exit;
        end;
    end
  else
  begin
    LBMid := NIL_SYM;
    LBSym := NIL_SYM;
  end;
  if AStored then
  begin
    TMExclude(tmeStored);
    Exit;
  end;
  LDef := TMTypeDef(LOwner.UnitId, LOwner.Sym);
  if (LDef <> NIL_NODE) and
     (GQProject.Model(LOwner.UnitId).Tree.Nodes[LDef].Kind = nkHelperType) then
  begin
    TMExclude(tmeHelper);
    Exit;
  end;
  LSpelling := TMTypeSpelling(LOwner.UnitId, LOwner.Sym, LWhy);
  if LSpelling = '' then
  begin
    TMExclude(LWhy);
    Exit;
  end;
  // `Self` in a class method is the class: `TFoo(Self).Create(...)` would
  // call the constructor on an instance (mORMot's `raise self.Create(...)`
  // in a class procedure: another code). PasTree types it as the class.
  if TMClassSelf(ABase) then
  begin
    TMExclude(tmeClassRef);
    Exit;
  end;
  if TMUpLevel(ABase) then
  begin
    TMExclude(tmeUpLevel);
    Exit;
  end;
  LBX := GQProject.WithTargetTypeX(GQMid, ABase, GQProbe);
  if not XValid(LBX) then
  begin
    TMExclude(tmeUntyped);
    Exit;
  end;
  LDeref := False;
  case TMCategory(LBX) of
    tcPointer:
      begin
        LBX := GQProject.PointeeX(GQProject.CanonTypeX(LBX));
        LDeref := True;
        if not XValid(LBX) then
        begin
          TMExclude(tmeUntyped);
          Exit;
        end;
      end;
    tcClassOf:
      begin
        TMExclude(tmeClassRef);
        Exit;
      end;
  end;
  if not TMDescends(LBX, LOwner) then
  begin
    TMMismatch(ASite, 'base ' + GQProject.XTypeText(LBX) + ' is no ' +
      LSpelling, ARoutine);
    Exit;
  end;
  // A record returned by a call takes no hard cast (E2089, Q69 - a generic
  // method's too, `V.AsType<TRec>.F`); a variable, a field, an element, a
  // property read through a getter does (Q70).
  if not LDeref and (TMCategory(LOwner) = tcRecord) and
     (not (GTree.Nodes[ABase].Kind in [nkIdent, nkMember, nkIndex, nkDeref]) or
      (LBSym = NIL_SYM) or
      (GQProject.Model(LBMid).Symbols[LBSym].Kind = skRoutine)) then
  begin
    TMExclude(tmeRValue);
    Exit;
  end;
  if not TMMemberCastable(AMid, ASym) then
    Exit;
  if GMOptimized and (GTree.Nodes[ABase].Kind <> nkIdent) then
  begin
    TMExclude(tmeOptimized);
    Exit;
  end;
  if not TMCastAllowed(ABase, LOwner, LSpelling) then
    Exit;
  if GQMemberSelftest then
  begin
    if GQPlanted.ContainsKey(ARoutine) then
      Exit;
    LSpelling := TMWrongOwner(ABase, AMid, ASym, LOwner, LWrong);
    if LSpelling <> '' then
    begin
      GQPlanted.Add(ARoutine, True);
      AddCastSite('planted', LSpelling, ABase, LDeref, ATail,
        LU.Symbols[ASym].Name, ARoutine, LWrong.UnitId);
    end;
    Exit;
  end;
  AddCastSite(AKind, LSpelling, ABase, LDeref, ATail, LU.Symbols[ASym].Name,
    ARoutine, LOwner.UnitId);
end;

{ tm: the binding of identifier (or, for a default array property, index)
  node ANode - RefMap or ExtRefMap. }
function TMBinding(ANode: Integer; out AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
  LExt: TPasExtRef;
begin
  LM := GQProject.Model(GQMid);
  AMid := GQMid;
  ASym := LM.RefMap[ANode];
  if ASym <> NIL_SYM then
    Exit(True);
  Result := LM.ExtRefMap.TryGetValue(ANode, LExt);
  if Result then
  begin
    AMid := LExt.UnitId;
    ASym := LExt.Sym;
  end;
end;

{ tm: the selector ANode of `Base.Name`. }
procedure TMSelector(ANode: Integer; const ARoutine: string; AInBody,
  AStored: Boolean);
var
  LMid, LSym, LScope, LBase: Integer;
  LU: TPasSemaModel;
begin
  LBase := GTree.Nodes[GTree.Nodes[ANode].Parent].FirstChild;
  if not TMBinding(ANode, LMid, LSym) then
  begin
    // A segment of a dotted unit name is no symbol's.
    if TMUnitChain(GTree.Nodes[ANode].Parent) then
      Exit;
    if not AInBody then
    begin
      TMExclude(tmeOutside);
      Exit;
    end;
    // A dynamic array type's `Create` is compiler magic - no declaration
    // (`TBytes.Create`, `TArray<TGUID>.Create`).
    if (GTree.Nodes[LBase].Kind = nkTypeArgs) or
       (GQProject.DesignatorSymX(GQMid, LBase, LMid, LSym) and
        (GQProject.Model(LMid).Symbols[LSym].Kind in [skType, skBuiltinType])) then
    begin
      TMExclude(tmeTypeBase);
      Exit;
    end;
    Inc(GQUnbound);
    GQUnboundList.Add(SpanText(GTree.Nodes[ANode].FirstToken,
      GTree.Nodes[ANode].FirstToken) + #9 + GTree.NodeText(ANode) + #9 +
      ARoutine + #9 + 'selector');
    Exit;
  end;
  if not AInBody then
  begin
    TMExclude(tmeOutside);
    Exit;
  end;
  LU := GQProject.Model(LMid);
  LScope := LU.Symbols[LSym].Scope;
  if LScope = NIL_SCOPE then
  begin
    TMExclude(tmeQualified);
    Exit;
  end;
  case LU.Scopes[LScope].Kind of
    sckStruct:
      TMMember(ANode, LBase, LMid, LSym, '', 'member', ARoutine, AStored);
    sckEnum:
      TMExclude(tmeTypeBase);
  else
    TMExclude(tmeQualified);
  end;
end;

{ tm: `Base[I]` - when PasTree read it through a default array property
  (keyed on the nkIndex node, see TPasSemaProject.CrossType), the site
  writes the property: `Owner(Base).Items[I]`. }
procedure TMIndex(ANode: Integer; const ARoutine: string; AInBody,
  AStored: Boolean);
var
  LMid, LSym: Integer;
begin
  if not TMBinding(ANode, LMid, LSym) then
    Exit;
  if GQProject.Model(LMid).Symbols[LSym].Kind <> skProperty then
    Exit;
  if not AInBody then
  begin
    TMExclude(tmeOutside);
    Exit;
  end;
  TMMember(ANode, GTree.Nodes[ANode].FirstChild, LMid, LSym,
    '.' + GQProject.Model(LMid).Symbols[LSym].Name, 'default', ARoutine,
    AStored);
end;

{ tm: does a target of a with around ANode, open there, have a member named
  ANameLower? Climbs as dcc looks: the innermost with first, its targets
  from the last to the first; a target sees only the targets before it.
  ATarget is the target that has it, AMid/ASym the member it found, AX the
  target's type. AUncertain: a target on the way PasTree could not type - it
  may have the name. }
function TMWithMember(ANode: Integer; const ANameLower: string;
  out ATarget, AMid, ASym: Integer; out AX: TSemaXType;
  out AUncertain: Boolean): Boolean;
var
  LCur, LParent, LChild, LLast, LFrom, LIdx, LCtx: Integer;
  LTargets: TArray<Integer>;
begin
  Result := False;
  ATarget := NIL_NODE;
  AX := XNil;
  AUncertain := False;
  LCur := ANode;
  LParent := GTree.Nodes[LCur].Parent;
  while LParent <> NIL_NODE do
  begin
    if GTree.Nodes[LParent].Kind = nkWithStmt then
    begin
      LTargets := nil;
      LChild := GTree.Nodes[LParent].FirstChild;
      LLast := LChild;
      while (LLast <> NIL_NODE) and (GTree.Nodes[LLast].NextSibling <> NIL_NODE) do
        LLast := GTree.Nodes[LLast].NextSibling;
      while (LChild <> NIL_NODE) and (LChild <> LLast) do
      begin
        LTargets := LTargets + [LChild];
        LChild := GTree.Nodes[LChild].NextSibling;
      end;
      LFrom := -1;
      if LCur = LLast then
        LFrom := High(LTargets)
      else
        for LIdx := 0 to High(LTargets) do
          if LTargets[LIdx] = LCur then
          begin
            LFrom := LIdx - 1;
            Break;
          end;
      for LIdx := LFrom downto 0 do
      begin
        AX := GQProject.WithTargetTypeX(GQMid, LTargets[LIdx], GQProbe);
        if not XValid(AX) then
          AUncertain := True;
        if XValid(AX) and GQProject.FindMemberX(GQMid, AX, ANameLower, AMid,
           ASym, LCtx) then
        begin
          ATarget := LTargets[LIdx];
          Exit(True);
        end;
      end;
    end;
    LCur := LParent;
    LParent := GTree.Nodes[LCur].Parent;
  end;
end;

{ tm: identifier ANode, bound to member (AMid, ASym), in the body of a with.
  When a target there has a member of its name, the name is that target's -
  dcc's rule, and PasTree's own (FindInEnclosingWith) - and the site writes
  the target and the owner before it: `Owner(Target).Name` (Q74; the wrong
  target of two, Q75, DIFFs). The target must be a plain variable, Self or
  a parameter whose name means the same inside the body. False when no
  target has the name: the member is Self's, or none of the with's. A
  target PasTree could not type counts the name excluded-with. }
function TMWithName(ANode, AMid, ASym: Integer; const ARoutine: string;
  AStored: Boolean): Boolean;
var
  LU: TPasSemaModel;
  LTarget, LFMid, LFSym, LTMid, LTSym, LDef: Integer;
  LX, LOwner, LDummy: TSemaXType;
  LSpelling, LText: string;
  LWhy: TTMExcl;
  LDeref, LUncertain: Boolean;
  LSite: TSite;
  LFile: Integer;
begin
  LU := GQProject.Model(AMid);
  if not TMWithMember(ANode, LU.Symbols[ASym].NameLower, LTarget, LFMid,
     LFSym, LX, LUncertain) then
  begin
    // A target PasTree could not type may have the name: neither the
    // target's nor Self's, then.
    if LUncertain then
    begin
      Inc(GQWith);
      Exit(True);
    end;
    Exit(False);
  end;
  Result := True;
  // One overload set: the member walk stops at the set's HEAD, the binding
  // names the overload the call chose (`with Stream do ReadBuffer(Level,
  // SizeOf(Level))` - TStream's ReadBuffer has four). Same name, both
  // routines, the bound one an overload: no contradiction, and the cast
  // through the bound overload's owner lets dcc choose again (the rung does
  // not see the choice inside a set - docs/parser-fidelity.md). F55.
  if ((LFMid <> AMid) or (LFSym <> ASym)) and
     (GQProject.Model(LFMid).Symbols[LFSym].Kind = skRoutine) and
     (LU.Symbols[ASym].Kind = skRoutine) and
     (sfOverload in LU.Symbols[ASym].Flags) and
     (GQProject.Model(LFMid).Symbols[LFSym].NameLower =
      LU.Symbols[ASym].NameLower) then
  begin
    LFMid := AMid;
    LFSym := ASym;
  end;
  if (LFMid <> AMid) or (LFSym <> ASym) then
  begin
    TMMismatch(ANode, 'the with target has ' +
      GQProject.Model(LFMid).Symbols[LFSym].Name + ' of another type',
      ARoutine);
    Exit;
  end;
  if AStored then
  begin
    TMExclude(tmeStored);
    Exit;
  end;
  // A parameter, a local variable or Self: the with evaluates its target
  // once, the spelling at every name - a call or a getter would run twice,
  // and a field or a global the with reads into a temporary is read again
  // (System.Win.Registry, `with FRegIniFile do`: another code).
  LText := '';
  if GTree.Nodes[LTarget].Kind = nkIdent then
  begin
    LText := GTree.NodeText(LTarget);
    if not SameText(LText, 'Self') then
      if not GQProject.DesignatorSymX(GQMid, LTarget, LTMid, LTSym) or
         (LTMid <> GQMid) or
         not ((GQProject.Model(LTMid).Symbols[LTSym].Kind = skParam) or
              ((GQProject.Model(LTMid).Symbols[LTSym].Kind = skVar) and
               (GQProject.Model(LTMid).Symbols[LTSym].Scope <> NIL_SCOPE) and
               (GQProject.Model(LTMid).Scopes[GQProject.Model(LTMid).
                 Symbols[LTSym].Scope].Kind in [sckRoutine, sckBlock]))) then
        LText := '';
  end;
  // The target's name must mean the target inside the body too.
  if (LText <> '') and TMWithMember(ANode, LowerCase(LText.TrimLeft(['&'])),
     LTMid, LFMid, LFSym, LDummy, LUncertain) or LUncertain then
    LText := '';
  if LText = '' then
  begin
    TMExclude(tmeWithTarget);
    Exit;
  end;
  if not TMOwner(AMid, ASym, LOwner) then
  begin
    TMExclude(tmeLocalType);
    Exit;
  end;
  LDef := TMTypeDef(LOwner.UnitId, LOwner.Sym);
  if (LDef <> NIL_NODE) and
     (GQProject.Model(LOwner.UnitId).Tree.Nodes[LDef].Kind = nkHelperType) then
  begin
    TMExclude(tmeHelper);
    Exit;
  end;
  LSpelling := TMTypeSpelling(LOwner.UnitId, LOwner.Sym, LWhy);
  if LSpelling = '' then
  begin
    TMExclude(LWhy);
    Exit;
  end;
  LDeref := False;
  case TMCategory(LX) of
    tcPointer:
      begin
        LX := GQProject.PointeeX(GQProject.CanonTypeX(LX));
        LDeref := True;
      end;
    tcClassOf:
      begin
        TMExclude(tmeClassRef);
        Exit;
      end;
  end;
  if not TMDescends(LX, LOwner) then
  begin
    TMMismatch(ANode, 'with target ' + GQProject.XTypeText(LX) + ' is no ' +
      LSpelling, ARoutine);
    Exit;
  end;
  if not TMMemberCastable(AMid, ASym) then
    Exit;
  if not TMCastAllowed(ANode, LOwner, LSpelling) then
    Exit;
  if GQMemberSelftest then
    Exit;
  VisOffset(GTree.Nodes[ANode].FirstToken, LFile);
  if GIncludedTwice[LFile] then
  begin
    Inc(GDropped);
    Exit;
  end;
  LSite := Default(TSite);
  LSite.Kind := 'with';
  LSite.Ops := GTree.NodeText(ANode);
  LSite.Span := SpanText(GTree.Nodes[ANode].FirstToken,
    GTree.Nodes[ANode].FirstToken);
  LSite.Routine := ARoutine;
  if LDeref then
    LSite.OpenText := LSpelling + '(' + LText + '^).'
  else
    LSite.OpenText := LSpelling + '(' + LText + ').';
  LSite.Edit := LSite.OpenText;
  LSite.OpenVis := GTree.Nodes[ANode].FirstToken;
  LSite.CloseVis := LSite.OpenVis;
  LSite.OpenOrder := 0;
  GSites.Add(LSite);
  TMNeedType(ANode, LSpelling, LOwner.UnitId);
end;

{ tm: the preamble - before each top-level declaration of the
  implementation (a routine, the initialization section) that holds a cast
  naming a type of another unit the unit's preamble has not named yet, a
  procedure whose locals name those types, on that declaration's first line,
  into the original's compile as into every rewrite's (PasTreeXform
  -sites:none). dcc records an imported type where the unit first names
  it: a cast naming a type the unit did not name before adds an import
  record (Q79: `TBaseM`, the code unchanged), and one naming it earlier
  than the unit did reorders them. Named first, in both, they are one list
  (Q65-Q79 SAME with it). One preamble per declaration, not one for the
  unit: a line holds 1023 characters (F2069, System.Classes). }
procedure TMPreamble;
var
  LPair: TPair<Integer, string>;
  LIdx, LTok: Integer;
begin
  LIdx := 0;
  for LPair in GMAnchors do
  begin
    Inc(LIdx);
    // A class method's `class` lies before its node.
    LTok := GTree.NodeLeftmostVis(LPair.Key);
    if (LTok > 0) and (GPre.VisibleToken(LTok - 1).Kind = PasTree.Types.tkClass) then
      Dec(LTok);
    AddEdit(LTok, False, 0,
      Format('procedure PasTreeTmImports%d; var%s begin end; ',
        [LIdx, LPair.Value]));
  end;
end;

{ tq: a site that writes AQualifier before the identifier ANode. Dropped
  and counted in a file included twice. }
procedure AddQualifySite(const AKind, AQualifier: string; ANode: Integer;
  const ARoutine: string);
var
  LVis, LFile: Integer;
  LSite: TSite;
begin
  LVis := GTree.Nodes[ANode].FirstToken;
  VisOffset(LVis, LFile);
  if GIncludedTwice[LFile] then
  begin
    Inc(GDropped);
    Exit;
  end;
  LSite := Default(TSite);
  LSite.Kind := AKind;
  LSite.Ops := GTree.NodeText(ANode);
  LSite.Span := SpanText(LVis, LVis);
  LSite.Routine := ARoutine;
  LSite.Edit := AQualifier;
  LSite.OpenVis := LVis;
  LSite.CloseVis := LVis;
  LSite.OpenText := AQualifier;
  LSite.CloseText := '';
  LSite.OpenOrder := 0;
  GSites.Add(LSite);
end;

{ tq: one identifier. A name that is a reference PasTree bound - in any
  position where a qualified spelling means the same declaration - takes the
  spelling that can only mean the declaration PasTree chose (plan S12-S13):
  a unit-level declaration of any unit, System's builtins included,
  `<Unit>.Name`; a member of the method's own type in its body `Self.Name`.
  Every name left as written is counted by why (see the GQ counters). }
procedure TQIdent(ANode: Integer; const ARoutine: string; AInBody,
  AStored, ACastStored: Boolean; AInWith: Integer);
var
  LParent, LIndex, LTMid, LSym, LScope, LMeth, LOwner, LOldTok: Integer;
  LM, LTM: TPasSemaModel;
  LPk: TPasNodeKind;
  LQual: string;
begin
  if nfName in GTree.Nodes[ANode].Flags then
    Exit;
  // A keyword spelled as a type (`string`) has no qualified form.
  if GPre.VisibleToken(GTree.Nodes[ANode].FirstToken).Kind <> tkIdentifier then
    Exit;
  LParent := GTree.Nodes[ANode].Parent;
  LIndex := 0;
  LPk := nkError;
  if LParent <> NIL_NODE then
  begin
    LPk := GTree.Nodes[LParent].Kind;
    LSym := GTree.Nodes[LParent].FirstChild;
    while (LSym <> NIL_NODE) and (LSym <> ANode) do
    begin
      Inc(LIndex);
      LSym := GTree.Nodes[LSym].NextSibling;
    end;
  end;
  // The selector after a dot is bound by the type before it: tm's.
  if (LPk = nkMember) and (LIndex = 1) then
  begin
    if GQMembers then
      TMSelector(ANode, ARoutine, AInBody, ACastStored)
    else
      Inc(GQSelector);
    Exit;
  end;
  // A declared name.
  if (LIndex = 0) and (LPk in [nkTypeDecl, nkConstDecl, nkEnumValue,
     nkPropertyDecl, nkGenericParam, nkUnit, nkProgram, nkLibrary, nkPackage,
     nkUsesItem]) then
    Exit;
  // Positions with no qualified spelling: a property's specifiers, a method
  // resolution clause, an exports item, a directive's arguments, a label,
  // a program parameter, an attribute's name, a record constant's field
  // name, a named argument, the name after `inherited`.
  if (LPk in [nkPropSpec, nkMethodResolution, nkExportsItem, nkDirective,
     nkGotoStmt, nkLabeledStmt, nkLabelSec, nkProgramParams, nkInherited,
     nkUsesItem]) or
     ((LIndex = 0) and (LPk in [nkAttribute, nkAggregateField, nkNamedArg])) then
  begin
    Inc(GQPosition);
    Exit;
  end;
  // The head of what follows `inherited`, `inherited Create(X)`: the
  // name is looked up in the ancestor, and `inherited Self.Create` is no
  // spelling at all.
  LSym := ANode;
  while (GTree.Nodes[LSym].Parent <> NIL_NODE) and
        (GTree.Nodes[GTree.Nodes[LSym].Parent].Kind in [nkCall, nkIndex,
          nkMember]) and
        (GTree.Nodes[GTree.Nodes[LSym].Parent].FirstChild = LSym) do
    LSym := GTree.Nodes[LSym].Parent;
  if (GTree.Nodes[LSym].Parent <> NIL_NODE) and
     (GTree.Nodes[GTree.Nodes[LSym].Parent].Kind = nkInherited) then
  begin
    Inc(GQPosition);
    Exit;
  end;
  if SameText(GTree.NodeText(ANode), 'Self') then
  begin
    Inc(GQLocal);
    Exit;
  end;
  LM := GQProject.Model(GQMid);
  LTMid := GQMid;
  LSym := LM.RefMap[ANode];
  if LSym = NIL_SYM then
  begin
    if not LM.ExtRefMap.TryGetValue(ANode, GQExt) then
    begin
      // A unit name's segment written as a qualifier is no symbol's.
      if TQUnitSegment(ANode) then
        Exit;
      if not GQUnits then
        Exit;
      Inc(GQUnbound);
      GQUnboundList.Add(SpanText(GTree.Nodes[ANode].FirstToken,
        GTree.Nodes[ANode].FirstToken) + #9 + GTree.NodeText(ANode) + #9 +
        ARoutine);
      Exit;
    end;
    LTMid := GQExt.UnitId;
    LSym := GQExt.Sym;
  end;
  LTM := GQProject.Model(LTMid);
  if (LTMid = GQMid) and (LTM.Symbols[LSym].DeclNode = ANode) then
    Exit;
  case LTM.Symbols[LSym].Kind of
    skUnitRef, skKeyword:
      Exit;
    skLabel, skParam, skGenericParam:
      begin
        Inc(GQLocal);
        Exit;
      end;
  end;
  LScope := LTM.Symbols[LSym].Scope;
  if LScope = NIL_SCOPE then
  begin
    Inc(GQLocal);
    Exit;
  end;
  // An unscoped enum's value is declared in the enum's own scope, whose
  // parent is where the type is declared.
  if LTM.Scopes[LScope].Kind = sckEnum then
  begin
    LScope := LTM.Scopes[LScope].Parent;
    if (LScope = NIL_SCOPE) or (LTM.Scopes[LScope].Kind = sckStruct) then
    begin
      Inc(GQMember);
      Exit;
    end;
  end;
  case LTM.Scopes[LScope].Kind of
    sckSystem, sckUnit, sckImplementation:
      begin
        if not GQUnits then
          Exit;
        // An old-style function result: the function's own name assigned to.
        if (LTM.Symbols[LSym].Kind = skRoutine) and (LPk = nkAssign) and
           (LIndex = 0) then
        begin
          Inc(GQPosition);
          Exit;
        end;
        // `Slice` is compiler magic only as written: `System.Slice(A, N)` is
        // E2193 (S14, System.Classes). (A bare `Default(...)` was here too,
        // S15's System.Threading 3514: dcc's lookup history, now the general
        // rule below.) `Flush`, `ChDir`, `MkDir`, `RmDir` are System
        // routines a bare call of which dcc follows with the $I+ I/O check,
        // as it does a file intrinsic's - `System.Flush(T)` has none: the
        // same routine, another code (F41; spec B.4 note, probed on dcc64
        // 37.0: SAME under $I-).
        if (SameText(LTM.Symbols[LSym].Name, 'Slice') or
            SameText(LTM.Symbols[LSym].Name, 'Flush') or
            SameText(LTM.Symbols[LSym].Name, 'ChDir') or
            SameText(LTM.Symbols[LSym].Name, 'MkDir') or
            SameText(LTM.Symbols[LSym].Name, 'RmDir')) and
           ((LTM.Scopes[LScope].Kind = sckSystem) or (LTMid = GQSystemMid)) then
        begin
          Inc(GQPosition);
          Exit;
        end;
        // Another unit's declaration (or System's) written bare BEFORE a
        // bare use of the name in a nested type's method: dcc's lookup
        // history, left as written (TQCollectHistory, F42).
        if ((LTMid <> GQMid) or (LTM.Scopes[LScope].Kind = sckSystem)) and
           GQHistory.TryGetValue(LTM.Symbols[LSym].NameLower, LOldTok) and
           (GTree.Nodes[ANode].FirstToken < LOldTok) then
        begin
          Inc(GQPosition);
          Exit;
        end;
        if LTM.Scopes[LScope].Kind = sckSystem then
          LQual := 'System'
        else
          LQual := TQUnitSpelling(LTMid);
        if LQual = '' then
        begin
          Inc(GQUnbound);
          Exit;
        end;
        if not TQUnitVisible(ANode, LTMid,
           LTM.Scopes[LScope].Kind = sckSystem) then
        begin
          Inc(GQInvisible);
          GQInvisibleList.Add(SpanText(GTree.Nodes[ANode].FirstToken,
            GTree.Nodes[ANode].FirstToken) + #9 + GTree.NodeText(ANode) + #9 +
            ARoutine + #9 + LQual);
          Exit;
        end;
        // A declaration of the unit's own further down - a pointer type's
        // target, `PFoo = ^TFoo`, a forward-declared class's full
        // declaration: the qualified name must be declared already (E2003).
        if (LTMid = GQMid) and (LTM.Symbols[LSym].DeclNode <> NIL_NODE) and
           (GTree.Nodes[LTM.Symbols[LSym].DeclNode].FirstToken >
            GTree.Nodes[ANode].FirstToken) then
        begin
          Inc(GQForward);
          Exit;
        end;
        if TQShadowed(ANode, LQual) then
        begin
          Inc(GQShadowed);
          Exit;
        end;
        if GQSymInfoOn and (AStored or GQRefInfoOn) then
        begin
          Inc(GQSymInfo);
          Exit;
        end;
        if (LTM.Symbols[LSym].Kind = skRoutine) and
           TQOwnRoutine(ARoutine, LTM.Symbols[LSym].NameLower) then
        begin
          Inc(GQPosition);
          Exit;
        end;
        if (LTM.Symbols[LSym].Kind = skRoutine) and
           TQOverloadMerged(ANode, LTMid,
             LTM.Scopes[LScope].Kind = sckSystem) then
        begin
          Inc(GQOverload);
          Exit;
        end;
        if GQSelftest then
        begin
          // The selftest: one wrong qualifier per routine, where there is one.
          if GQPlanted.ContainsKey(ARoutine) then
            Exit;
          LQual := TQWrongQualifier(ANode, LTMid,
            LTM.Scopes[LScope].Kind = sckSystem);
          if LQual <> '' then
          begin
            GQPlanted.Add(ARoutine, True);
            AddQualifySite('planted', LQual, ANode, ARoutine);
          end;
          Exit;
        end;
        AddQualifySite('unit', LQual + '.', ANode, ARoutine);
      end;
    sckStruct:
      begin
        // A with target's member: tm's.
        if GQMembers and AInBody and (AInWith > 0) and
           TMWithName(ANode, LTMid, LSym, ARoutine, ACastStored) then
          Exit;
        if not GQUnits then
          Exit;
        if not AInBody or
           not (LTM.Symbols[LSym].Kind in [skField, skVar, skRoutine,
             skProperty]) then
        begin
          Inc(GQMember);
          Exit;
        end;
        // In a with body, unless tm found no target with the name.
        if (AInWith > 0) and not GQMembers then
        begin
          Inc(GQWith);
          Exit;
        end;
        LMeth := TQMethodScope(TQScopeAt(ANode));
        if LMeth = NIL_SCOPE then
        begin
          Inc(GQMember);
          Exit;
        end;
        // A class method's Self is its class, and a static one has none -
        // only its declaration says which (S15 takes them).
        if GTree.Nodes[LM.Scopes[LMeth].OwnerNode].Aux = 1 then
        begin
          Inc(GQStatic);
          Exit;
        end;
        // A nested type's method reaches its outer types' members bare too,
        // and those are no member of Self.
        LOwner := LM.Scopes[LMeth].StructSym;
        if (LM.Symbols[LOwner].Scope = NIL_SCOPE) or
           (LM.Scopes[LM.Symbols[LOwner].Scope].Kind = sckStruct) then
        begin
          Inc(GQNested);
          Exit;
        end;
        if AStored then
        begin
          Inc(GQStored);
          Exit;
        end;
        if GQSymInfoOn then
        begin
          Inc(GQSymInfo);
          Exit;
        end;
        // An old-style function result in a method: `Root := X` in the body
        // of `function TURI.Root` is the result; `Self.Root := X` is E2064
        // (S16, a third-party record method); `Root[I] := X` alike.
        if (LTM.Symbols[LSym].Kind = skRoutine) and (((LPk = nkAssign) and
           (LIndex = 0)) or TQOwnRoutine(ARoutine,
           LTM.Symbols[LSym].NameLower)) then
        begin
          Inc(GQPosition);
          Exit;
        end;
        // A field of a procedural type standing as a statement calls it -
        // `FProc;` - and `Self.FProc;` of a `reference to` type is E2014
        // "statement expected" (S14, System.Threading).
        if (LTM.Symbols[LSym].Kind in [skField, skVar, skProperty]) and
           (LPk = nkExprStmt) then
        begin
          Inc(GQPosition);
          Exit;
        end;
        if not GQSelftest then
          AddQualifySite('self', 'Self.', ANode, ARoutine);
      end;
  else
    Inc(GQLocal);
  end;
end;

{ tq: every identifier of the subtree at ANode, in pre-order. ARoutine as
  in T1Walk; AInBody - inside a routine body or an initialization or
  finalization section, where a member reached bare is Self's; AInWith - the
  with statements around the node, whose targets' members a bare name may
  be; AStored - in a generic's body (tq's Self rule), ACastStored - in a
  generic's or an inline routine's (tm's cast rule). }
procedure TQWalk(ANode: Integer; const ARoutine: string; AInBody,
  AStored, ACastStored: Boolean; AInWith: Integer);
var
  LChild, LIndex: Integer;
  LRoutine: string;
begin
  LRoutine := ARoutine;
  case GTree.Nodes[ANode].Kind of
    nkAsmStmt:
      Exit;
    nkRoutine:
      begin
        LRoutine := RoutineName(ANode);
        if ARoutine <> '' then
          LRoutine := ARoutine + '.' + LRoutine;
        AStored := AStored or TQGenericBody(ANode);
        ACastStored := ACastStored or AStored or IsStoredBody(ANode);
      end;
    nkRoutineBody:
      AInBody := True;
    nkInitSec:
      begin
        LRoutine := GUnitName;
        AInBody := True;
      end;
    nkFinalSec:
      begin
        LRoutine := 'Finalization';
        AInBody := True;
      end;
    nkIdent:
      TQIdent(ANode, ARoutine, AInBody, AStored, ACastStored, AInWith);
    nkIndex:
      if GQMembers then
        TMIndex(ANode, ARoutine, AInBody, ACastStored);
    nkWithStmt:
      begin
        // `with A, B do S`: B is read in A's scope, S in both.
        LIndex := 0;
        LChild := GTree.Nodes[ANode].FirstChild;
        while LChild <> NIL_NODE do
        begin
          TQWalk(LChild, LRoutine, AInBody, AStored, ACastStored,
            AInWith + Ord(LIndex > 0));
          Inc(LIndex);
          LChild := GTree.Nodes[LChild].NextSibling;
        end;
        Exit;
      end;
  end;
  LChild := GTree.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    TQWalk(LChild, LRoutine, AInBody, AStored, ACastStored, AInWith);
    LChild := GTree.Nodes[LChild].NextSibling;
  end;
end;

{ t2: whether AChild, the AIndex-th child (from 0) of AParent, stands where
  a statement does: an item of a statement list - a compound statement, a
  routine's or a program's block, the list of a case-else, a try, an
  except, a finally or a repeat, an initialization or finalization section
  - an if's then or else, a case branch's body, the body of a for, a while,
  a with or an exception handler, the statement a label marks. A statement
  list itself stands in none: `try`, `except`, `repeat` and the rest
  bracket it with words of their own. }
function InStatementPosition(AParent, AIndex, AChild: Integer): Boolean;
begin
  case GTree.Nodes[AParent].Kind of
    nkBlock, nkInitSec, nkFinalSec:
      Result := True;
    nkIfStmt, nkCaseSel:
      Result := AIndex >= 1;
    nkForStmt, nkForInStmt, nkWhileStmt, nkWithStmt, nkExceptOn,
    nkLabeledStmt:
      Result := GTree.Nodes[AChild].NextSibling = NIL_NODE;
  else
    Result := False;
  end;
end;

{ t2, for the report: where statement AIndex of AParent stands. }
function PositionName(AParent, AIndex: Integer): string;
var
  LUp: Integer;
begin
  case GTree.Nodes[AParent].Kind of
    nkBlock:
      begin
        LUp := GTree.Nodes[AParent].Parent;
        if LUp = NIL_NODE then
          Exit('list');
        case GTree.Nodes[LUp].Kind of
          nkCaseStmt: Result := 'case-else';
          nkTryStmt: Result := 'try';
          nkFinallyPart: Result := 'finally';
          nkExceptPart:
            if GTree.Nodes[GTree.Nodes[LUp].FirstChild].Kind = nkExceptOn then
              Result := 'except-else'
            else
              Result := 'except';
          nkRepeatStmt: Result := 'repeat';
          nkRoutineBody, nkProgram, nkLibrary: Result := 'body';
        else
          Result := 'begin';
        end;
      end;
    nkInitSec: Result := 'init';
    nkFinalSec: Result := 'final';
    nkIfStmt:
      if AIndex = 1 then
        Result := 'then'
      else
        Result := 'else';
    nkCaseSel: Result := 'case';
    nkExceptOn: Result := 'on';
    nkLabeledStmt: Result := 'label';
  else
    Result := 'do';
  end;
end;

{ t2, for the report: the statement's head - `if-else`, `raise-at`... }
function StatementHead(ANode: Integer): string;
var
  LLast: Integer;
begin
  LLast := GTree.Nodes[ANode].FirstChild;
  while (LLast <> NIL_NODE) and (GTree.Nodes[LLast].NextSibling <> NIL_NODE) do
    LLast := GTree.Nodes[LLast].NextSibling;
  case GTree.Nodes[ANode].Kind of
    nkBlock: Result := 'begin';
    nkEmptyStmt: Result := 'empty';
    nkAssign: Result := ':=';
    nkExprStmt: Result := 'call';
    nkIfStmt:
      if Child(ANode, 2) <> NIL_NODE then
        Result := 'if-else'
      else
        Result := 'if';
    nkCaseStmt:
      if (LLast <> NIL_NODE) and (GTree.Nodes[LLast].Kind = nkBlock) then
        Result := 'case-else'
      else
        Result := 'case';
    nkForStmt: Result := 'for';
    nkForInStmt: Result := 'for-in';
    nkWhileStmt: Result := 'while';
    nkRepeatStmt: Result := 'repeat';
    nkWithStmt: Result := 'with';
    nkGotoStmt: Result := 'goto';
    nkTryStmt:
      if (LLast <> NIL_NODE) and (GTree.Nodes[LLast].Kind = nkFinallyPart) then
        Result := 'try-finally'
      else
        Result := 'try-except';
    nkRaiseStmt:
      if Child(ANode, 1) <> NIL_NODE then
        Result := 'raise-at'
      else
        Result := 'raise';
  else
    Result := GTree.KindName(GTree.Nodes[ANode].Kind);
  end;
end;

{ t2: a site wrapping statement ANode (child AIndex of AParent) in `begin`
  `end`: the `begin` right before its leftmost token, the `end` right BEFORE
  the token after it, on that token's line. dcc takes a line from the token
  that follows a statement, and Assert passes it to the code: a then-branch
  `Assert(X)` with `else` on the next line reports the `else`'s line, and an
  `end` right after the `)` would give the Assert a line of its own (plan
  S7, probes assert-line). When the token after lies in another file, the
  `end` goes right after the statement. An empty statement owns no token:
  it becomes `begin end` right AFTER the token before it - the `then`,
  `else`, `do` or `:` of the statement it ends, ahead of that statement's
  own `end` (`if A then ;` -> `if A then begin end  end ;`). Dropped and
  counted like t1's: both ends in one file, not in a file included twice.
  The words go in with a blank on either side - `do(P).X` and `F(X)else`
  would glue to them otherwise. }
procedure AddBlockSite(AParent, AIndex, ANode: Integer; const ARoutine: string);
var
  LFirst, LLast, LFileA, LFileB: Integer;
  LSite: TSite;
begin
  if GTree.Nodes[ANode].Kind = nkEmptyStmt then
  begin
    LFirst := GTree.Nodes[ANode].FirstToken - 1;
    LLast := LFirst;
  end
  else
  begin
    LFirst := GTree.NodeLeftmostVis(ANode);
    LLast := GTree.Nodes[ANode].LastToken;
  end;
  VisOffset(LFirst, LFileA);
  VisOffset(LLast, LFileB);
  if (LFileA <> LFileB) or GIncludedTwice[LFileA] then
  begin
    Inc(GDropped);
    Exit;
  end;
  LSite.Kind := GTree.KindName(GTree.Nodes[ANode].Kind);
  LSite.Ops := PositionName(AParent, AIndex) + ':' + StatementHead(ANode);
  LSite.Span := SpanText(LFirst, LLast);
  LSite.Routine := ARoutine;
  LSite.OpenVis := LFirst;
  LSite.CloseVis := LLast;
  LSite.CloseBefore := False;
  if GTree.Nodes[ANode].Kind = nkEmptyStmt then
  begin
    LSite.Edit := 'begin end after';
    LSite.OpenAfter := True;
    LSite.OpenText := ' begin end ';
    LSite.OpenOrder := 0;
    LSite.CloseText := '';
    LSite.CloseOrder := 0;
  end
  else
  begin
    LSite.Edit := 'begin/end';
    LSite.OpenAfter := False;
    LSite.OpenText := ' begin ';
    LSite.OpenOrder := 2;
    LSite.CloseText := ' end ';
    LSite.CloseOrder := 1;
    if LLast < High(GPre.Visible) then
    begin
      VisOffset(LLast + 1, LFileB);
      if LFileB = LFileA then
      begin
        LSite.CloseVis := LLast + 1;
        LSite.CloseBefore := True;
      end;
    end;
  end;
  GSites.Add(LSite);
end;

{ t2: the last name part of routine ARoutine, lower case - `m` for
  `function TG<T>.M`. }
function LastNamePart(ARoutine: Integer): string;
var
  LName: string;
begin
  LName := RoutineName(ARoutine);
  Result := LowerCase(Copy(LName, LastDelimiter('.', LName) + 1, MaxInt));
end;

{ t2: GInlineNames - every routine with an `inline` directive, at its
  declaration or its implementation (a method's is usually on the one in
  the class). }
procedure CollectInlineNames(ANode: Integer);
var
  LChild: Integer;
begin
  if GTree.Nodes[ANode].Kind = nkRoutine then
  begin
    LChild := GTree.Nodes[ANode].FirstChild;
    while LChild <> NIL_NODE do
    begin
      if (GTree.Nodes[LChild].Kind = nkDirective) and
         SameText(GTree.NodeText(LChild), 'inline') then
        GInlineNames.AddOrSetValue(LastNamePart(ANode), True);
      LChild := GTree.Nodes[LChild].NextSibling;
    end;
  end;
  LChild := GTree.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    CollectInlineNames(LChild);
    LChild := GTree.Nodes[LChild].NextSibling;
  end;
end;

{ t2: whether routine ARoutine's body is one dcc STORES in the .dcu - a
  generic's (its name has generic parameters at any level: `TG<T>.M`,
  `TFoo.M<T>`, `TOuter<T>.TInner.M`), to be instantiated elsewhere, or an
  inline routine's, to be expanded elsewhere. A stored body keeps source
  LINES, whatever -$D, -$L and -$Y say (probed on dcc64 37.0; -$C-, -$O+
  change nothing either). Around a statement that spans lines, or whose
  next token lies on another line, a begin/end changes the stored bytes -
  `FIdx :=` / `3;` / `Result := True;` by 5 bytes in a generic method and
  in an inline function; a then-branch followed by `else` on the next line
  in Studio's inline getters and generic methods, where the line comes from
  the token after the statement, as in the code-lines record, and the
  begin/end makes that token its `end`. Around a statement that shares one
  line with the token after it they never did, in any position probed
  (plan S6, probes pairs-generic*, pairs-inline). A name declared `inline`
  counts for every routine of that name in the unit: an overload not
  declared so is left out too, which only costs sites. }
function IsStoredBody(ARoutine: Integer): Boolean;
var
  LChild: Integer;
begin
  LChild := GTree.Nodes[ARoutine].FirstChild;
  while (LChild <> NIL_NODE) and
        (GTree.Nodes[LChild].Kind in [nkIdent, nkGenericParams, nkTypeArgs]) do
  begin
    if GTree.Nodes[LChild].Kind <> nkIdent then
      Exit(True);
    LChild := GTree.Nodes[LChild].NextSibling;
  end;
  Result := GInlineNames.ContainsKey(LastNamePart(ARoutine));
end;

// The line visible token AVis starts on, and its file.
function VisLine(AVis: Integer; out AFileId: Integer): Integer;
var
  LCol: Integer;
begin
  GPre.Files[GPre.Visible[AVis].FileId].OffsetToLineCol(
    VisOffset(AVis, AFileId), Result, LCol);
end;

{ t2: whether statement ANode, AND the token after it, lie on one line - the
  only shape a stored body takes a begin/end around unchanged (see
  IsStoredBody). An empty statement: the tokens before and after it. }
function OnOneLine(ANode: Integer): Boolean;
var
  LFirst, LLast, LFile, LLine, LOtherFile: Integer;
begin
  if GTree.Nodes[ANode].Kind = nkEmptyStmt then
  begin
    LFirst := GTree.Nodes[ANode].FirstToken - 1;
    LLast := LFirst;
  end
  else
  begin
    LFirst := GTree.NodeLeftmostVis(ANode);
    LLast := GTree.Nodes[ANode].LastToken;
  end;
  LLine := VisLine(LFirst, LFile);
  Result := (VisLine(LLast, LOtherFile) = LLine) and (LOtherFile = LFile);
  if Result and (LLast < High(GPre.Visible)) then
    Result := (VisLine(LLast + 1, LOtherFile) = LLine) and (LOtherFile = LFile);
end;

{ t1: whether the last token of node ANode and the token after it lie on
  one line - the `)` then leaves every line the unit records as it was (see
  LinesKept). }
function EndsOnLineOfNext(ANode: Integer): Boolean;
var
  LLast, LFile, LOtherFile: Integer;
begin
  LLast := GTree.Nodes[ANode].LastToken;
  Result := (LLast >= High(GPre.Visible)) or
    ((VisLine(LLast + 1, LOtherFile) = VisLine(LLast, LFile)) and
     (LOtherFile = LFile));
end;


{ t2: every statement of the subtree at ANode as a site, in pre-order (a
  statement before the ones inside it); ARoutine as in T1Walk. AStored:
  ANode lies in a stored body (IsStoredBody). AInList: ANode stands as an
  item of a statement list - directly, or as the statement a label marks
  that does.

  Besides the kinds never wrapped (see the header), two rules, each from a
  probe (plan S6):
  - a CALL statement standing as a list item is not wrapped (counted in
    GExcludedCall): when the call discards a managed result - a string, an
    interface, a dynamic array, a record with managed fields - dcc
    finalizes the temporary holding it at the end of the statement LIST
    the call stands in (a routine's own list: in its epilogue), so a
    begin/end of its own moves the finalization up to the call - `S;` /
    `Y := 1;` differs from `begin S end;` / `Y := 1;` by 17 bytes. A parse
    cannot tell a function from a procedure, nor a managed result from any
    other. As the body of an if, a loop, a case branch, a with or an
    exception handler the temporary is the statement's own and the
    begin/end changes nothing; under a label it is the label's list's.
  - in a stored body, a statement that does not share one line with the
    token after it (counted in GExcludedStored) - see IsStoredBody; the
    same in a unit whose own text turns D, L or Y on (GLinesKept, counted
    in GExcludedLines) - see LinesKept. }
procedure T2Walk(ANode: Integer; const ARoutine: string; AStored,
  AInList: Boolean);
var
  LChild, LIndex: Integer;
  LRoutine: string;
  LInList: Boolean;
begin
  LRoutine := ARoutine;
  case GTree.Nodes[ANode].Kind of
    nkAsmStmt:
      Exit;
    nkRoutine:
      begin
        LRoutine := RoutineName(ANode);
        if ARoutine <> '' then
          LRoutine := ARoutine + '.' + LRoutine;
        // A nested routine or an anonymous method is part of the body it
        // is written in: stored with it.
        AStored := AStored or IsStoredBody(ANode);
      end;
    nkInitSec:
      LRoutine := GUnitName;
    nkFinalSec:
      LRoutine := 'Finalization';
  end;
  LChild := GTree.Nodes[ANode].FirstChild;
  LIndex := 0;
  while LChild <> NIL_NODE do
  begin
    LInList := (GTree.Nodes[ANode].Kind in [nkBlock, nkInitSec, nkFinalSec]) or
      ((GTree.Nodes[ANode].Kind = nkLabeledStmt) and AInList and
       (GTree.Nodes[LChild].NextSibling = NIL_NODE));
    if InStatementPosition(ANode, LIndex, LChild) then
      case GTree.Nodes[LChild].Kind of
        nkInlineVar, nkInlineConst:
          Inc(GExcludedInline);
        nkLabeledStmt:
          Inc(GExcludedLabel);
        nkAsmStmt:
          Inc(GExcludedAsm);
        nkBlock, nkEmptyStmt, nkAssign, nkExprStmt, nkIfStmt, nkCaseStmt,
        nkForStmt, nkForInStmt, nkWhileStmt, nkRepeatStmt, nkWithStmt,
        nkGotoStmt, nkTryStmt, nkRaiseStmt:
          if (GTree.Nodes[LChild].Kind = nkExprStmt) and LInList then
            Inc(GExcludedCall)
          else if AStored and not OnOneLine(LChild) then
            Inc(GExcludedStored)
          else if GLinesKept and not OnOneLine(LChild) then
            Inc(GExcludedLines)
          else
            AddBlockSite(ANode, LIndex, LChild, LRoutine);
      end;
    T2Walk(LChild, LRoutine, AStored, LInList);
    LChild := GTree.Nodes[LChild].NextSibling;
    Inc(LIndex);
  end;
end;

type
  TSiteRange = record
    Lo, Hi: Integer;
  end;

var
  // -sites: the ids (1-based) whose edits are applied; empty = all.
  GSiteRanges: TList<TSiteRange>;
  // -sites:none - no site at all: what tm's original side compiles, its
  // preamble alone (see TMPreamble).
  GNoSites: Boolean;

procedure ParseSiteList(const AText: string);
var
  LPart: string;
  LDash: Integer;
  LRange: TSiteRange;
begin
  if SameText(Trim(AText), 'none') then
  begin
    GNoSites := True;
    Exit;
  end;
  for LPart in AText.Split([',']) do
  begin
    if Trim(LPart) = '' then
      Continue;
    LDash := Pos('-', LPart);
    if LDash > 0 then
    begin
      LRange.Lo := StrToInt(Trim(Copy(LPart, 1, LDash - 1)));
      LRange.Hi := StrToInt(Trim(Copy(LPart, LDash + 1, MaxInt)));
    end
    else
    begin
      LRange.Lo := StrToInt(Trim(LPart));
      LRange.Hi := LRange.Lo;
    end;
    GSiteRanges.Add(LRange);
  end;
  if GSiteRanges.Count = 0 then
    raise Exception.Create('-sites: no id given');
end;

function SiteSelected(AId: Integer): Boolean;
var
  LRange: TSiteRange;
begin
  if GNoSites then
    Exit(False);
  if GSiteRanges.Count = 0 then
    Exit(True);
  for LRange in GSiteRanges do
    if (AId >= LRange.Lo) and (AId <= LRange.Hi) then
      Exit(True);
  Result := False;
end;

{ t0f: the word of directive token AText, upper-cased, read the way
  TPasPreprocessor.HandleDirective reads it - the body between the
  delimiters, trimmed, then the run of LETTERS at its start (`IFDEF_X` is
  IFDEF with the argument `_X`, there and here); AWordStart is its 0-based
  offset in AText. }
function DirectiveWord(const AText: string; out AWordStart: Integer): string;
var
  LFirst, LLast, LName: Integer;
begin
  LFirst := 1;
  LLast := Length(AText);
  if (LLast >= 2) and (AText[1] = '{') then
  begin
    LFirst := 3;                                   // after the brace and $
    if (LLast >= 3) and (AText[LLast] = '}') then
      Dec(LLast);
  end
  else if (LLast >= 3) and (AText[1] = '(') then
  begin
    LFirst := 4;                                   // after paren, star, $
    if (LLast >= 5) and (AText[LLast - 1] = '*') and (AText[LLast] = ')') then
      Dec(LLast, 2);
  end;
  while (LFirst <= LLast) and (AText[LFirst] <= ' ') do
    Inc(LFirst);
  LName := LFirst;
  while (LName <= LLast) and CharInSet(AText[LName], ['A'..'Z', 'a'..'z']) do
    Inc(LName);
  AWordStart := LFirst - 1;
  Result := UpperCase(Copy(AText, LFirst, LName - LFirst));
end;

// The text after the word of directive token AText, trimmed, without the
// closing delimiter: `!FOO` for an $ENDIF written with that comment.
function DirectiveTrail(const AText: string): string;
var
  LStart, LEnd: Integer;
begin
  DirectiveWord(AText, LStart);
  LStart := LStart + 1;
  while (LStart <= Length(AText)) and
        CharInSet(AText[LStart], ['A'..'Z', 'a'..'z']) do
    Inc(LStart);
  LEnd := Length(AText);
  if AText.StartsWith('(') then
  begin
    if AText.EndsWith('*)') then
      Dec(LEnd, 2);
  end
  else if AText.EndsWith('}') then
    Dec(LEnd);
  Result := Trim(Copy(AText, LStart, LEnd - LStart + 1));
end;

{ The words that dispatch handles as conditionals. A copy of its list on
  purpose: a word read differently here than there shows up as a DIFF, it
  cannot hide one. }
function IsConditionalWord(const AWord: string): Boolean;
begin
  Result := (AWord = 'IF') or (AWord = 'IFDEF') or (AWord = 'IFNDEF') or
    (AWord = 'IFOPT') or (AWord = 'ELSEIF') or (AWord = 'ELSE') or
    (AWord = 'ENDIF') or (AWord = 'IFEND');
end;

{ Whether directive token AText turns on a switch of ALetters, from the
  family whose records keep source lines: D (DEBUGINFO), L (LOCALSYMBOLS),
  Y (REFERENCEINFO; YD and DEFINITIONINFO turn it on for definitions) -
  and, for tm, O (OPTIMIZATION, see TMMember); lower-case r asks for
  REFERENCEINFO itself, `$Y+`, not `$YD` (see GQRefInfoOn) -
  `$D+`, `$O-,Y+`, `$YD`, `$DEFINITIONINFO ON` (braces left out here: a
  directive in a brace comment ends it). `$L file.obj` and `$D text` are
  other directives. }
function LineInfoOn(const AText: string; const ALetters: TSysCharSet): Boolean;
var
  LWord, LBody: string;
  LStart, LIdx: Integer;
begin
  LWord := DirectiveWord(AText, LStart);
  LBody := UpperCase(DirectiveTrail(AText));
  if (LWord = 'DEBUGINFO') or (LWord = 'LOCALSYMBOLS') or
     (LWord = 'REFERENCEINFO') or (LWord = 'DEFINITIONINFO') or
     (LWord = 'OPTIMIZATION') then
  begin
    if not (LBody.StartsWith('ON') and
            ((Length(LBody) = 2) or not CharInSet(LBody[3], ['A'..'Z']))) then
      Exit(False);
    if LWord[1] = 'O' then
      Exit(CharInSet('O', ALetters));
    if LWord[1] = 'R' then
      Exit(CharInSet('Y', ALetters) or CharInSet('r', ALetters))
    else if LWord[1] = 'D' then
      if LWord = 'DEBUGINFO' then
        Exit(CharInSet('D', ALetters))
      else
        Exit(CharInSet('Y', ALetters));
    Exit(CharInSet('L', ALetters));
  end;
  if LWord = 'YD' then
    Exit(CharInSet('Y', ALetters));
  Result := False;
  if Length(LWord) <> 1 then
    Exit;
  // The short form, a comma list: X+ X- YD Zn ...
  LBody := LWord + LBody;
  LIdx := 1;
  while LIdx < Length(LBody) do
  begin
    if not CharInSet(LBody[LIdx], ['A'..'Z']) then
      Exit;
    if CharInSet(LBody[LIdx + 1], ['+', '-']) then
    begin
      if (LBody[LIdx + 1] = '+') and (CharInSet(LBody[LIdx], ALetters) or
         ((LBody[LIdx] = 'Y') and CharInSet('r', ALetters))) then
        Exit(True);
    end
    else if (LBody[LIdx] = 'Y') and (LBody[LIdx + 1] = 'D') then
    begin
      if CharInSet('Y', ALetters) then
        Exit(True);
    end
    else if not CharInSet(LBody[LIdx + 1], ['0'..'9']) then
      Exit;
    Inc(LIdx, 2);
    while (LIdx <= Length(LBody)) and
          CharInSet(LBody[LIdx], ['0'..'9', ',', ' ', #9]) do
      Inc(LIdx);
  end;
end;

{ t1, t2 (rule R3): whether the unit's own text - the unit or an include,
  outside every region the preprocessor skipped - turns on a switch of
  ALetters (see LineInfoOn). The harness compiles t1 with -$D- -$L- and t2
  with -$Y- as well, because those records keep the line of the token AFTER
  a construct (plan S5, S6); a directive in the source overrides the
  command line. Spring4D's include turns DEFINITIONINFO on: a then-branch
  constructing a generic of the unit's own, `X := TField<Int64>.Create(...)`
  with `else` on the next line, records the `else`'s line, and its
  begin/end - or moving the `else` up a line, no block at all - changes one
  byte (plan S7, probes geninst3 yd-*, and the unit itself). Such a unit
  takes a site only where no recorded line can move: t2 a statement on one
  line with the token after it (as in a stored body), t1 an operator whose
  last token shares a line with the next. A whole unit, whatever the
  directive's position - conservative, and rare (no Studio unit). }
function LinesKept(const ALetters: TSysCharSet): Boolean;
var
  LFile, LTok, LStart: Integer;
  LRegion: TPasSkippedRegion;
  LLive: Boolean;
begin
  for LFile := 0 to High(GPre.Files) do
    for LTok := 0 to High(GPre.Files[LFile].Tokens) do
      if (GPre.Files[LFile].Tokens[LTok].Kind = tkDirective) and
         LineInfoOn(GPre.Files[LFile].TokenText(LTok), ALetters) then
      begin
        LStart := GPre.Files[LFile].Tokens[LTok].Start;
        LLive := True;
        for LRegion in GPre.Skipped[LFile] do
          if (LStart >= LRegion.Start) and (LStart < LRegion.EndPos) then
          begin
            LLive := False;
            Break;
          end;
        if LLive then
          Exit(True);
      end;
  Result := False;
end;

const
  cMarkBefore = '{PTXM';
  cMarkAfter = '{PTXA';

// The marker the liveness run puts before (AAfter = False) or after token
// ATok of distinct file APath: a brace comment no real unit spells. A comment
// decides nothing and parses to nothing - the -oracle run parses the unit, an
// identifier would break its uses clause - and a comment inside asm is still
// a comment. Whether the run skipped the region it lies in is the answer.
function MarkerText(APath, ATok: Integer; AAfter: Boolean): string;
const
  cPrefix: array[Boolean] of string = (cMarkBefore, cMarkAfter);
begin
  Result := Format('%s%d_%d}', [cPrefix[AAfter], APath, ATok]);
end;

function ParseMarker(const AText: string; out APath, ATok: Integer;
  out AAfter: Boolean): Boolean;
var
  LSep: Integer;
begin
  Result := False;
  if AText.StartsWith(cMarkBefore) then
    AAfter := False
  else if AText.StartsWith(cMarkAfter) then
    AAfter := True
  else
    Exit;
  LSep := Pos('_', AText);
  if (LSep = 0) or not AText.EndsWith('}') then
    Exit;
  Result := TryStrToInt(Copy(AText, Length(cMarkBefore) + 1,
    LSep - Length(cMarkBefore) - 1), APath) and
    TryStrToInt(Copy(AText, LSep + 1, Length(AText) - LSep - 1), ATok);
end;

// ASource[AOffset..AOffset+ALen) with every character but CR and LF turned
// into a space: the line count, and so every later line number, stays.
function Blank(const ASource: string; AOffset, ALen: Integer): string;
var
  LIdx: Integer;
begin
  Result := Copy(ASource, AOffset + 1, ALen);
  for LIdx := 1 to Length(Result) do
    if (Result[LIdx] <> #13) and (Result[LIdx] <> #10) then
      Result[LIdx] := ' ';
end;

function MakeEdit(AFileId, AOffset, ALen: Integer; const AText: string): TEdit;
begin
  Result.FileId := AFileId;
  Result.Offset := AOffset;
  Result.Len := ALen;
  Result.Order := 0;
  Result.Text := AText;
end;

// AText with AEdits applied - sorted by offset, none overlapping.
function ApplyEdits(const AText: string; AEdits: TList<TEdit>): string;
var
  LSB: TStringBuilder;
  LPos: Integer;
  LEdit: TEdit;
begin
  LSB := TStringBuilder.Create;
  try
    LPos := 0;
    for LEdit in AEdits do
    begin
      LSB.Append(AText, LPos, LEdit.Offset - LPos);
      LSB.Append(LEdit.Text);
      LPos := LEdit.Offset + LEdit.Len;
    end;
    LSB.Append(AText, LPos, Length(AText) - LPos);
    Result := LSB.ToString;
  finally
    LSB.Free;
  end;
end;

{ t3 and t3x: the unit printed from its tree (PasTree.Printer) IN PLACE. The
  print is a sequence of items, each read from the tree; T3 (CompareT3)
  matched every one but the separators to the visible token it stands for.
  Each item goes into that token's SLOT - the token's own characters - in
  print order: an item whose token lies before one already filled (the print
  reorders a few spellings, PRINT_NORMALIZATION N10) joins the last filled
  slot; a separator takes a `;` the original has between the items around
  it and the print dropped (N1), else it opens the next item's slot. A slot
  with several items joins them with blanks; a slot no item reached - a `;`
  or a spelling the canonical form drops - becomes blanks, its line breaks
  kept. Everything else of the file stays byte for byte: comments,
  directives, inactive code, every token on its line (dcc keeps lines, not
  columns - probe s10\probes\col), so dcc compiles the print with the
  unit's own switches and include files.
  A slot whose text changes only in case - a keyword regenerated in lower
  case - takes its edit always; every other change is one site per node
  (the node of the items moved into a slot, or the owner of a token the
  print dropped), so a subset of the sites is a valid program and the
  localizer can bisect them. A slot in a file included twice keeps its
  token (excluded-print). The print must be T3-clean: a defect is refused. }
procedure T3Walk;
var
  LItems: TPasPrintItems;
  LT3: TPasT3Result;
  LReport: TPasCheckReport;
  LOwner, LKey, LNextAt, LSiteOf, LFirstOf, LLastOf: TArray<Integer>;
  LText: TArray<string>;
  LOrig: string;
  LHas, LMatched: TArray<Boolean>;
  LCursor, LIdx, LVis, LSlot, LFile, LStart, LLen, LLast, LFirst, LNode,
    LChanged, LMoved, LSepOwn, LSepNew, LKeptSep: Integer;
  LNew, LSrc: string;
  LEdit: TEdit;
  LSite: TSite;
  LSites: TList<TSite>;

  procedure Place(ASlot, AItem: Integer; AMoved: Boolean);
  begin
    if LText[ASlot] <> '' then
      LText[ASlot] := LText[ASlot] + ' ';
    LText[ASlot] := LText[ASlot] + LItems[AItem].Text;
    LHas[ASlot] := True;
    // The slot's site is the node of the item moved into it, else of its
    // first item.
    if AMoved then
    begin
      Inc(LMoved);
      LKey[ASlot] := LItems[AItem].Node;
    end
    else if LKey[ASlot] < 0 then
      LKey[ASlot] := LItems[AItem].Node;
  end;

  function EnclosingRoutine(ANode: Integer): string;
  begin
    Result := '';
    while ANode <> NIL_NODE do
    begin
      case GTree.Nodes[ANode].Kind of
        nkRoutine:
          if Result = '' then
            Result := RoutineName(ANode)
          else
            Result := RoutineName(ANode) + '.' + Result;
        nkInitSec:
          if Result = '' then
            Result := GUnitName;
        nkFinalSec:
          if Result = '' then
            Result := 'Finalization';
      end;
      ANode := GTree.Nodes[ANode].Parent;
    end;
  end;

  function IsBlank(AChar: Char): Boolean;
  begin
    Result := CharInSet(AChar, [' ', #9, #10, #13]);
  end;

begin
  LItems := PrintNode(GTree, 0);
  if not CompareT3(GTree, 0, LT3, 1) then
    raise Exception.CreateFmt('the print has %d T3 defects, the first at ' +
      '%s: %s', [LT3.Defects, VisSiteText(GPre, LT3.Sites[0].Vis),
      LT3.Sites[0].Msg]);
  SetLength(LOwner, Length(GPre.Visible));
  for LIdx := 0 to High(LOwner) do
    LOwner[LIdx] := -1;
  LReport.Init(1);
  CheckTree(GTree, True, LReport,
    procedure(ANode, AVisIndex, ACell, ARule: Integer)
    begin
      LOwner[AVisIndex] := ANode;
    end);
  SetLength(LText, Length(GPre.Visible));
  SetLength(LHas, Length(GPre.Visible));
  SetLength(LMatched, Length(GPre.Visible));
  SetLength(LKey, Length(GPre.Visible));
  for LIdx := 0 to High(LKey) do
    LKey[LIdx] := -1;
  for LIdx := 0 to High(LItems) do
    if LT3.ItemAt[LIdx] >= 0 then
      LMatched[LT3.ItemAt[LIdx]] := True;
  // Per item: the token the next matched item stands for (-1: none).
  SetLength(LNextAt, Length(LItems) + 1);
  LNextAt[Length(LItems)] := -1;
  for LIdx := High(LItems) downto 0 do
    if LT3.ItemAt[LIdx] >= 0 then
      LNextAt[LIdx] := LT3.ItemAt[LIdx]
    else
      LNextAt[LIdx] := LNextAt[LIdx + 1];
  LCursor := -1;
  LMoved := 0;
  LSepOwn := 0;
  LSepNew := 0;
  LKeptSep := 0;
  for LIdx := 0 to High(LItems) do
  begin
    LVis := LT3.ItemAt[LIdx];
    if LVis < 0 then
    begin
      if LItems[LIdx].Cls <> pcSeparator then
        raise Exception.CreateFmt('print item %d (%s) matched no token',
          [LIdx, LItems[LIdx].Text]);
      // The original's own `;` between the items around it, dropped by N1.
      LSlot := -1;
      LLast := LNextAt[LIdx + 1];
      if LLast < 0 then
        LLast := High(GPre.Visible);
      for LVis := LCursor + 1 to LLast - 1 do
        if (GPre.VisibleToken(LVis).Kind = tkSemicolon) and
           not LMatched[LVis] and not LHas[LVis] then
        begin
          LSlot := LVis;
          Break;
        end;
      if LSlot >= 0 then
      begin
        Inc(LSepOwn);
        Place(LSlot, LIdx, False);
        LKey[LSlot] := LItems[LIdx].Node;
        LCursor := LSlot;
      end
      else
      begin
        // It opens the next item's slot - or, with none left, joins the last.
        Inc(LSepNew);
        LSlot := LNextAt[LIdx + 1];
        if (LSlot < 0) or (LSlot < LCursor) then
          LSlot := LCursor;
        if LSlot < 0 then
          raise Exception.Create('a separator before any token');
        Place(LSlot, LIdx, True);
        if LSlot > LCursor then
          LCursor := LSlot;
      end;
      Continue;
    end;
    if LVis >= LCursor then
    begin
      Place(LVis, LIdx, False);
      LCursor := LVis;
    end
    else
      Place(LCursor, LIdx, True);
  end;

  // The edits, slot by slot; the sites by key node, in the order of their
  // first slot.
  LSites := TList<TSite>.Create;
  try
    SetLength(LSiteOf, Length(GTree.Nodes));
    for LIdx := 0 to High(LSiteOf) do
      LSiteOf[LIdx] := -1;
    SetLength(LFirstOf, 0);
    SetLength(LLastOf, 0);
    LFirst := GTree.NodeLeftmostVis(0);
    LLast := GTree.Nodes[0].LastToken;
    // A root stops on the token after its final `.` (N4, N5): untouched.
    if GTree.Nodes[0].Kind in [nkUnit, nkProgram, nkLibrary, nkPackage] then
      Dec(LLast);
    LChanged := 0;
    for LVis := LFirst to LLast do
    begin
      if GPre.VisibleToken(LVis).Kind = tkEndOfFile then
        Continue;
      LNew := '';
      if LHas[LVis] then
        LNew := LText[LVis]
      else if (GPre.VisibleToken(LVis).Kind = tkSemicolon) and
         (LOwner[LVis] >= 0) and
         (GTree.Nodes[LOwner[LVis]].Kind in [nkBlock, nkCaseStmt, nkExceptPart,
           nkInitSec, nkFinalSec, nkClassType, nkRecordType, nkObjectType,
           nkHelperType, nkInterfaceType, nkVariantPart, nkVariantBranch,
           nkVarSec, nkRoutine, nkPropertyDecl]) then
      begin
        // A list's `;` the print does not need (N1) stays: dcc gives the code
        // at a statement's end the line of the token AFTER it - an Assert's
        // line, the line tables, a stored body - and dropping `S;` before an
        // `end` on the next line moves that token there.
        Inc(LKeptSep);
        Continue;
      end;
      LOrig := VisText(LVis);
      if LNew = LOrig then
        Continue;
      LStart := VisOffset(LVis, LFile);
      LLen := VisEnd(LVis, LFile) - LStart;
      if GIncludedTwice[LFile] then
      begin
        Inc(GExcludedPrint);
        Continue;
      end;
      LSrc := GPre.Files[LFile].Source;
      LEdit := MakeEdit(LFile, LStart, LLen, LNew);
      LEdit.Order := cSlotOrder;
      if SameText(LNew, LOrig) then
      begin
        GPrintCase.Add(LEdit);
        Continue;
      end;
      Inc(LChanged);
      if LNew = '' then
        LEdit.Text := Blank(LSrc, LStart, LLen)
      else
      begin
        // Apart from the characters around it, which stay as they were.
        if (LStart > 0) and not IsBlank(LSrc[LStart]) then
          LEdit.Text := ' ' + LEdit.Text;
        if (LStart + LLen < Length(LSrc)) and
           not IsBlank(LSrc[LStart + LLen + 1]) then
          LEdit.Text := LEdit.Text + ' ';
      end;
      LNode := LKey[LVis];
      if LNode < 0 then
        LNode := LOwner[LVis];
      if LNode < 0 then
        LNode := 0;
      if LSiteOf[LNode] < 0 then
      begin
        LSite := Default(TSite);
        LSite.Kind := 'print';
        LSite.Ops := GTree.KindName(GTree.Nodes[LNode].Kind);
        LSite.Routine := EnclosingRoutine(LNode);
        LSite.OpenVis := LVis;
        LSite.CloseVis := LVis;
        LSite.CloseText := '';
        LSite.Edit := '';
        LSiteOf[LNode] := LSites.Count;
        LSites.Add(LSite);
        SetLength(LFirstOf, LSites.Count);
        SetLength(LLastOf, LSites.Count);
        LFirstOf[LSites.Count - 1] := LVis;
      end;
      LSite := LSites[LSiteOf[LNode]];
      LSite.Edits := LSite.Edits + [LEdit];
      if LSite.Edit <> '' then
        LSite.Edit := LSite.Edit + ' ';
      LSite.Edit := LSite.Edit + '`' + LOrig + '`->`' + LNew + '`';
      LSites[LSiteOf[LNode]] := LSite;
      LLastOf[LSiteOf[LNode]] := LVis;
    end;
    for LIdx := 0 to LSites.Count - 1 do
    begin
      LSite := LSites[LIdx];
      LSite.Span := SpanText(LFirstOf[LIdx], LLastOf[LIdx]);
      LSite.Edit := LSite.Edit.Replace(#9, ' ').Replace(#13, ' ').
        Replace(#10, ' ');
      GSites.Add(LSite);
    end;
    GPrintStats := Format('items=%d losses=%d slots-changed=%d case=%d ' +
      'moved=%d separators-own=%d separators-new=%d separators-kept=%d',
      [Length(LItems), LT3.Losses, LChanged, GPrintCase.Count, LMoved,
      LSepOwn, LSepNew, LKeptSep]);
  finally
    LSites.Free;
  end;
end;

// The argument of include directive AText (`$I x` in braces, or `INCLUDE x`
// in parens and stars): its offset in AText (0-based) and length, the
// delimiters and blanks outside.
procedure IncludeArg(const AText: string; out AStart, ALen: Integer);
var
  LFirst, LLast: Integer;
begin
  if AText.StartsWith('(') then
  begin
    LFirst := 4;
    LLast := Length(AText) - 2;
  end
  else
  begin
    LFirst := 3;
    LLast := Length(AText) - 1;
  end;
  while (LFirst <= LLast) and (AText[LFirst] <= ' ') do
    Inc(LFirst);
  while (LFirst <= LLast) and CharInSet(AText[LFirst], ['A'..'Z', 'a'..'z']) do
    Inc(LFirst);
  while (LFirst <= LLast) and (AText[LFirst] <= ' ') do
    Inc(LFirst);
  while (LLast >= LFirst) and (AText[LLast] <= ' ') do
    Dec(LLast);
  AStart := LFirst - 1;
  ALen := LLast - LFirst + 1;
end;

// Include argument AArg made to name the instance copy ACopy beside the file
// it named: `~2\` put before the file-name part, quotes kept.
function CopyArg(const AArg: string; ACopy: Integer): string;
var
  LName: string;
  LQuoted: Boolean;
  LSlash, LIdx: Integer;
begin
  LName := AArg;
  LQuoted := (Length(LName) >= 2) and (LName[1] = '''') and
    (LName[Length(LName)] = '''');
  if LQuoted then
    LName := Copy(LName, 2, Length(LName) - 2);
  LSlash := 0;
  for LIdx := 1 to Length(LName) do
    if CharInSet(LName[LIdx], ['\', '/']) then
      LSlash := LIdx;
  Insert('~' + IntToStr(ACopy) + '\', LName, LSlash + 1);
  if LQuoted then
    LName := '''' + LName + '''';
  Result := LName;
end;

// The index of the token of AStream that covers offset AOffset.
function TokenAt(const AStream: TPasTokenStream; AOffset: Integer): Integer;
var
  LLo, LHi, LMid: Integer;
begin
  LLo := 0;
  LHi := High(AStream.Tokens);
  Result := -1;
  while LLo <= LHi do
  begin
    LMid := (LLo + LHi) div 2;
    if AStream.Tokens[LMid].Start <= AOffset then
    begin
      Result := LMid;
      LLo := LMid + 1;
    end
    else
      LHi := LMid - 1;
  end;
end;

function InstanceCopyPath(const APath: string; ACopy: Integer): string;
begin
  Result := TPath.Combine(TPath.Combine(TPath.GetDirectoryName(APath),
    '~' + IntToStr(ACopy)), TPath.GetFileName(APath));
end;

type
  // One open conditional of the processing-order walk in Flatten - the
  // preprocessor's own stack, rebuilt from what the markers saw.
  TCondFrame = record
    ParentActive: Boolean;
    AnyTaken: Boolean;
    SeenElse: Boolean;
  end;

  // Preprocesses the unit once more with ATexts[i] standing in for the file
  // APaths[i] - the liveness run - exactly as the stream being flattened was
  // made: a bare preprocessor, or a project analysis under -oracle.
  TLivenessRun = reference to function(const APaths,
    ATexts: TArray<string>): TPasPreprocessed;

{ t0f. Fills GEdits with every inclusion's blanking and include rewrites,
  GOutName/GIsCopy with the file each inclusion is written as, GFlatStats
  with the counts. ALiveness repeats the run that made GPre (see
  TLivenessRun).

  Some directives survive as PROBES, because dcc records what they consult
  and blanking them changes the .dcu with no change of code (all probed on
  dcc64 37.0):
  - every $IF and $ELSEIF, live or not, stays where it was as an empty
    conditional, closed at once (an $ELSEIF reads as $IF). dcc evaluates
    EVERY such expression it meets - in a skipped branch, after a taken one
    - and records each name it finds as an import of the unit
    (`$IF RTLVersion >= 36` imports System's RTLVersion; the first self-host
    run's one DIFF; a skipped `$IF SizeOf(tagSTATSTG)` imports that type).
    The .dcu comes out the same whether the expression stood in a live or a
    dead branch, so the probe needs no liveness. An $IFDEF, $IFNDEF or
    $IFOPT records nothing and is blanked.

  - dcc stores the text after an $ELSE, $ENDIF or $IFEND when it starts with
    `!` - System.Contnrs' `$ENDIF !AUTOREFCOUNT` - provided the state after
    the directive is live (any other leading character stores nothing, nor
    does an $ELSE that turns code off); `$REGION` does the same, with a
    byte-identical result. Such a directive becomes `$REGION !text` +
    `$ENDREGION` in its place.
  The branches are still the preprocessor's: a probe chooses nothing. }
procedure Flatten(const ALiveness: TLivenessRun);
var
  LCount, LFile, LTok, LPath, LIdx, LJdx, LCopy, LWordStart: Integer;
  LPaths: TDictionary<string, Integer>;       // lower-cased path -> index
  LPathOf: TArray<Integer>;                   // FileId -> path index
  LRep: TList<Integer>;                       // path index -> first FileId
  LWord: TArray<TArray<string>>;              // FileId, token -> its word
  // FileId, token: a marker before / after it lay in live code; the marker
  // came back at all.
  LBefore, LAfter, LSeenBefore, LSeenAfter: TArray<TArray<Boolean>>;
  LAug, LAugPaths: TArray<string>;            // path index -> marked text
  LSB: TStringBuilder;
  LStream: TPasTokenStream;
  LMark: TPasPreprocessed;
  LText: string;
  LAfterMark: Boolean;
  LOwn: TArray<TList<TEdit>>;                 // FileId -> its blanking
  LKeys: TDictionary<string, Integer>;
  LKeyOf, LCopyOf: TArray<Integer>;
  LCopies: TDictionary<Integer, Integer>;
  LKey: TStringBuilder;
  LRef: TPasIncludeRef;
  LRegion: TPasSkippedRegion;
  LArgStart, LArgLen: Integer;
  LEdits: TList<TEdit>;
  LIncludeAt: TDictionary<Int64, Integer>;    // FileId:offset -> included
  LStack: TList<TCondFrame>;
  LBlankRegions, LBlankCond, LBlankDead, LKept, LProbes, LCopyFiles: Integer;
  LByOffset: IComparer<TEdit>;

  function IsCond(AFile, ATok: Integer): Boolean;
  begin
    Result := IsConditionalWord(LWord[AFile][ATok]);
  end;

  // The preprocessor's walk, in its order - an include is processed where
  // its directive stands - with its conditional stack rebuilt from the
  // markers: an opening conditional's after-marker says whether it was
  // taken, and so on. Checks the markers against what the stack implies
  // wherever that is determined: a marker read wrongly shows up here.
  procedure Walk(AFile: Integer);
  var
    LT, LTop, LIncluded: Integer;
    LW: string;
    LFrame: TCondFrame;

    procedure Mismatch;
    begin
      raise Exception.CreateFmt('the markers contradict the conditional ' +
        'stack at %s', [PosText(AFile, GPre.Files[AFile].Tokens[LT].Start)]);
    end;

  begin
    for LT := 0 to High(GPre.Files[AFile].Tokens) do
    begin
      LW := LWord[AFile][LT];
      if LW = '' then
        Continue;
      LTop := LStack.Count - 1;
      if (LW = 'IF') or (LW = 'IFDEF') or (LW = 'IFNDEF') or (LW = 'IFOPT') then
      begin
        if LAfter[AFile][LT] and not LBefore[AFile][LT] then
          Mismatch;
        LFrame.ParentActive := LBefore[AFile][LT];
        LFrame.AnyTaken := LAfter[AFile][LT];
        LFrame.SeenElse := False;
        LStack.Add(LFrame);
      end
      else if LW = 'ELSEIF' then
      begin
        if (LTop >= 0) and not LStack[LTop].SeenElse then
        begin
          LFrame := LStack[LTop];
          if LAfter[AFile][LT] and
             not (LFrame.ParentActive and not LFrame.AnyTaken) then
            Mismatch;
          if LAfter[AFile][LT] then
            LFrame.AnyTaken := True;
          LStack[LTop] := LFrame;
        end;
      end
      else if LW = 'ELSE' then
      begin
        if LTop >= 0 then
        begin
          LFrame := LStack[LTop];
          if LAfter[AFile][LT] <> (LFrame.ParentActive and
             not LFrame.AnyTaken) then
            Mismatch;
          LFrame.SeenElse := True;
          if LAfter[AFile][LT] then
            LFrame.AnyTaken := True;
          LStack[LTop] := LFrame;
        end;
      end
      else if (LW = 'ENDIF') or (LW = 'IFEND') then
      begin
        if LTop >= 0 then
        begin
          if LAfter[AFile][LT] <> LStack[LTop].ParentActive then
            Mismatch;
          LStack.Delete(LTop);
        end;
      end
      else if LIncludeAt.TryGetValue(Int64(AFile) shl 32 or
              GPre.Files[AFile].Tokens[LT].Start, LIncluded) then
        Walk(LIncluded);
    end;
  end;

begin
  LCount := Length(GPre.Files);
  LByOffset := TComparer<TEdit>.Construct(
    function(const A, B: TEdit): Integer
    begin
      Result := A.Offset - B.Offset;
    end);
  LPaths := TDictionary<string, Integer>.Create;
  LRep := TList<Integer>.Create;
  LKeys := TDictionary<string, Integer>.Create;
  LCopies := TDictionary<Integer, Integer>.Create;
  LIncludeAt := TDictionary<Int64, Integer>.Create;
  LStack := TList<TCondFrame>.Create;
  LSB := TStringBuilder.Create;
  LKey := TStringBuilder.Create;
  SetLength(LOwn, LCount);
  try
    SetLength(LPathOf, LCount);
    SetLength(LWord, LCount);
    SetLength(LBefore, LCount);
    SetLength(LAfter, LCount);
    SetLength(LSeenBefore, LCount);
    SetLength(LSeenAfter, LCount);
    for LFile := 0 to LCount - 1 do
    begin
      LText := LowerCase(TPath.GetFullPath(GPre.FileNames[LFile]));
      if not LPaths.TryGetValue(LText, LPath) then
      begin
        LPath := LRep.Add(LFile);
        LPaths.Add(LText, LPath);
      end;
      LPathOf[LFile] := LPath;
      LStream := GPre.Files[LFile];
      SetLength(LWord[LFile], Length(LStream.Tokens));
      SetLength(LBefore[LFile], Length(LStream.Tokens));
      SetLength(LAfter[LFile], Length(LStream.Tokens));
      SetLength(LSeenBefore[LFile], Length(LStream.Tokens));
      SetLength(LSeenAfter[LFile], Length(LStream.Tokens));
      for LTok := 0 to High(LStream.Tokens) do
        if LStream.Tokens[LTok].Kind = tkDirective then
        begin
          LWord[LFile][LTok] := DirectiveWord(LStream.TokenText(LTok),
            LWordStart);
          // A directive with no word at all still needs to tell itself
          // apart from a token that is none.
          if LWord[LFile][LTok] = '' then
            LWord[LFile][LTok] := '?';
        end;
    end;
    for LRef in GPre.IncludeRefs do
      if LRef.IncludedFileId >= 0 then
        LIncludeAt.AddOrSetValue(Int64(LRef.FileId) shl 32 or LRef.Start,
          LRef.IncludedFileId);

    // The liveness run: a marker before every directive of every file and
    // one after every conditional, the same inputs otherwise. A marker that
    // lies in a region the run skipped stood in dead code.
    SetLength(LAug, LRep.Count);
    SetLength(LAugPaths, LRep.Count);
    for LPath := 0 to LRep.Count - 1 do
    begin
      LFile := LRep[LPath];
      LStream := GPre.Files[LFile];
      LSB.Clear;
      LIdx := 0;
      for LTok := 0 to High(LStream.Tokens) do
        if LStream.Tokens[LTok].Kind = tkDirective then
        begin
          LSB.Append(LStream.Source, LIdx, LStream.Tokens[LTok].Start - LIdx);
          LSB.Append(MarkerText(LPath, LTok, False));
          LSB.Append(LStream.Source, LStream.Tokens[LTok].Start,
            LStream.Tokens[LTok].Len);
          if IsCond(LFile, LTok) then
            LSB.Append(MarkerText(LPath, LTok, True));
          LIdx := LStream.Tokens[LTok].EndPos;
        end;
      LSB.Append(LStream.Source, LIdx, Length(LStream.Source) - LIdx);
      LAug[LPath] := LSB.ToString;
      LAugPaths[LPath] := GPre.FileNames[LFile];
    end;
    LMark := ALiveness(LAugPaths, LAug);
    if Length(LMark.FileNames) <> LCount then
      raise Exception.CreateFmt('the liveness run read %d files, the first ' +
        'run %d', [Length(LMark.FileNames), LCount]);
    for LFile := 0 to LCount - 1 do
      if not SameText(LMark.FileNames[LFile], GPre.FileNames[LFile]) then
        raise Exception.CreateFmt('the liveness run read %s where the first ' +
          'run read %s', [LMark.FileNames[LFile], GPre.FileNames[LFile]]);
    // Comments are never visible: the two runs must see the same tokens.
    if Length(LMark.Visible) <> Length(GPre.Visible) then
      raise Exception.CreateFmt('the liveness run saw %d tokens, the first ' +
        '%d', [Length(LMark.Visible), Length(GPre.Visible)]);
    for LIdx := 0 to High(LMark.Visible) do
      if (GPre.Visible[LIdx].FileId <> LMark.Visible[LIdx].FileId) or
         (GPre.VisibleText(LIdx) <> LMark.VisibleText(LIdx)) then
        raise Exception.CreateFmt('the liveness run diverged from the first ' +
          'at visible token %d', [LIdx]);
    for LFile := 0 to LCount - 1 do
    begin
      LStream := LMark.Files[LFile];
      for LTok := 0 to High(LStream.Tokens) do
        if (LStream.Tokens[LTok].Kind = tkCommentBrace) and
           ParseMarker(LStream.TokenText(LTok), LPath, LJdx, LAfterMark) then
        begin
          if (LPath <> LPathOf[LFile]) or (LJdx < 0) or
             (LJdx > High(LBefore[LFile])) or
             (LWord[LFile][LJdx] = '') then
            raise Exception.CreateFmt('marker %s met in file %d',
              [LStream.TokenText(LTok), LFile]);
          if LAfterMark then
            LAfter[LFile][LJdx] := not LMark.IsSkipped(LFile,
              LStream.Tokens[LTok].Start)
          else
            LBefore[LFile][LJdx] := not LMark.IsSkipped(LFile,
              LStream.Tokens[LTok].Start);
          if LAfterMark then
            LSeenAfter[LFile][LJdx] := True
          else
            LSeenBefore[LFile][LJdx] := True;
        end;
    end;
    // Every marker must have come back as a comment of its own.
    for LFile := 0 to LCount - 1 do
      for LTok := 0 to High(LWord[LFile]) do
        if (LWord[LFile][LTok] <> '') and (not LSeenBefore[LFile][LTok] or
           (IsCond(LFile, LTok) and not LSeenAfter[LFile][LTok])) then
          raise Exception.CreateFmt('a marker of the directive at %s was ' +
            'lost', [PosText(LFile, GPre.Files[LFile].Tokens[LTok].Start)]);
    // Two records the preprocessor keeps of its own say the same thing for
    // some directives: an include it followed was live, and a $DEFINE or
    // $UNDEF carries the state it was met in.
    for LRef in GPre.IncludeRefs do
    begin
      LTok := TokenAt(GPre.Files[LRef.FileId], LRef.Start);
      if (LTok < 0) or not LBefore[LRef.FileId][LTok] then
        raise Exception.CreateFmt('an include the preprocessor followed ' +
          'reads as dead at %s', [PosText(LRef.FileId, LRef.Start)]);
    end;
    // Every define mention carries the state it was met in: a $DEFINE's or
    // $UNDEF's own, the enclosing one for an $IFDEF/$IFNDEF - both what the
    // marker before the directive saw.
    for LIdx := 0 to High(GPre.DefineRefs) do
      if GPre.DefineRefs[LIdx].Kind in [drDefine, drUndef, drIfdef, drIfndef]
      then
      begin
        LFile := GPre.DefineRefs[LIdx].FileId;
        LTok := TokenAt(GPre.Files[LFile], GPre.DefineRefs[LIdx].Start);
        if (LTok < 0) or
           (GPre.Files[LFile].Tokens[LTok].Kind <> tkDirective) or
           (LBefore[LFile][LTok] <> GPre.DefineRefs[LIdx].Active) then
          raise Exception.CreateFmt('a define''s recorded state disagrees ' +
            'with the liveness run at %s', [PosText(LFile,
            GPre.DefineRefs[LIdx].Start)]);
      end;
    Walk(0);

    // Each inclusion's own edits: the regions the preprocessor skipped and
    // every directive that was not live blanked; every conditional blanked
    // too, but for the probes (see above).
    LBlankRegions := 0;
    LBlankCond := 0;
    LBlankDead := 0;
    LKept := 0;
    LProbes := 0;
    for LFile := 0 to LCount - 1 do
    begin
      LStream := GPre.Files[LFile];
      LOwn[LFile] := TList<TEdit>.Create;
      for LRegion in GPre.Skipped[LFile] do
      begin
        LOwn[LFile].Add(MakeEdit(LFile, LRegion.Start,
          LRegion.EndPos - LRegion.Start, Blank(LStream.Source, LRegion.Start,
          LRegion.EndPos - LRegion.Start)));
        Inc(LBlankRegions);
      end;
      for LTok := 0 to High(LStream.Tokens) do
        if LStream.Tokens[LTok].Kind = tkDirective then
        begin
          if (LWord[LFile][LTok] = 'IF') or
             (LWord[LFile][LTok] = 'ELSEIF') then
          begin
            // `$ELSEIF expr` reads `$IF expr`, then the empty body closes.
            LText := LStream.TokenText(LTok);
            if LWord[LFile][LTok] = 'ELSEIF' then
            begin
              DirectiveWord(LText, LWordStart);
              LText := Copy(LText, 1, LWordStart) + 'IF' +
                Copy(LText, LWordStart + 7, MaxInt);
            end;
            LOwn[LFile].Add(MakeEdit(LFile, LStream.Tokens[LTok].Start,
              LStream.Tokens[LTok].Len, LText + '{$IFEND}'));
            Inc(LProbes);
            Continue;
          end;
          if ((LWord[LFile][LTok] = 'ENDIF') or
              (LWord[LFile][LTok] = 'IFEND') or
              (LWord[LFile][LTok] = 'ELSE')) and LAfter[LFile][LTok] then
          begin
            LText := DirectiveTrail(LStream.TokenText(LTok));
            if LText.StartsWith('!') then
            begin
              LOwn[LFile].Add(MakeEdit(LFile, LStream.Tokens[LTok].Start,
                LStream.Tokens[LTok].Len,
                '{$REGION ' + LText + '}{$ENDREGION}'));
              Inc(LProbes);
              Continue;
            end;
          end;
          if IsCond(LFile, LTok) then
            Inc(LBlankCond)
          else if not LBefore[LFile][LTok] then
            Inc(LBlankDead)
          else
          begin
            Inc(LKept);
            Continue;
          end;
          LOwn[LFile].Add(MakeEdit(LFile, LStream.Tokens[LTok].Start,
            LStream.Tokens[LTok].Len, Blank(LStream.Source,
            LStream.Tokens[LTok].Start, LStream.Tokens[LTok].Len)));
        end;
      LOwn[LFile].Sort(LByOffset);
    end;

    // Which inclusions read the same text. Leaf-first - an include's FileId
    // is always above its includer's - so a key can name the keys of the
    // inclusions inside it: equal keys, equal files.
    SetLength(LKeyOf, LCount);
    for LFile := LCount - 1 downto 0 do
    begin
      LKey.Clear;
      LKey.Append(ApplyEdits(GPre.Files[LFile].Source, LOwn[LFile]));
      for LRef in GPre.IncludeRefs do
        if (LRef.FileId = LFile) and (LRef.IncludedFileId >= 0) then
          LKey.Append(#0).Append(LRef.Start).Append(':').Append(
            LKeyOf[LRef.IncludedFileId]);
      LText := LKey.ToString;
      if not LKeys.TryGetValue(LText, LIdx) then
      begin
        LIdx := LKeys.Count;
        LKeys.Add(LText, LIdx);
      end;
      LKeyOf[LFile] := LIdx;
    end;
    // Per file, the first text keeps the file's own place; every other
    // distinct text gets copy 2, 3, ...
    SetLength(LCopyOf, LCount);
    SetLength(GOutName, LCount);
    SetLength(GIsCopy, LCount);
    LCopyFiles := 0;
    for LPath := 0 to LRep.Count - 1 do
    begin
      LCopies.Clear;
      for LFile := 0 to LCount - 1 do
        if LPathOf[LFile] = LPath then
        begin
          if not LCopies.TryGetValue(LKeyOf[LFile], LCopy) then
          begin
            LCopy := LCopies.Count + 1;
            LCopies.Add(LKeyOf[LFile], LCopy);
            if LCopy > 1 then
              Inc(LCopyFiles);
          end;
          LCopyOf[LFile] := LCopy;
          GIsCopy[LFile] := LCopy > 1;
          if LCopy > 1 then
            GOutName[LFile] := InstanceCopyPath(GPre.FileNames[LFile], LCopy)
          else
            GOutName[LFile] := GPre.FileNames[LFile];
        end;
    end;

    // The edits: the blanking, plus the argument of every include whose
    // inclusion reads a copy.
    for LFile := 0 to LCount - 1 do
    begin
      LEdits := LOwn[LFile];
      for LRef in GPre.IncludeRefs do
        if (LRef.FileId = LFile) and (LRef.IncludedFileId >= 0) and
           (LCopyOf[LRef.IncludedFileId] > 1) then
        begin
          LText := Copy(GPre.Files[LFile].Source, LRef.Start + 1, LRef.Len);
          IncludeArg(LText, LArgStart, LArgLen);
          LEdits.Add(MakeEdit(LFile, LRef.Start + LArgStart, LArgLen,
            CopyArg(Copy(LText, LArgStart + 1, LArgLen),
            LCopyOf[LRef.IncludedFileId])));
          GArgMap.AddOrSetValue(
            CopyArg(Copy(LText, LArgStart + 1, LArgLen),
            LCopyOf[LRef.IncludedFileId]).DeQuotedString,
            Copy(LText, LArgStart + 1, LArgLen).DeQuotedString);
        end;
      LEdits.Sort(LByOffset);
      GEdits.AddRange(LEdits);
    end;

    GFlatStats := Format('inclusions=%d files=%d copies=%d skipped-regions=%d ' +
      'conditionals=%d if-probes=%d dead-directives=%d live-directives=%d',
      [LCount, LRep.Count, LCopyFiles, LBlankRegions, LBlankCond, LProbes,
      LBlankDead, LKept]);
  finally
    for LIdx := 0 to High(LOwn) do
      LOwn[LIdx].Free;
    LKey.Free;
    LSB.Free;
    LStack.Free;
    LIncludeAt.Free;
    LCopies.Free;
    LKeys.Free;
    LRep.Free;
    LPaths.Free;
  end;
end;

{ The encoding the source manager decoded AFileName's bytes with - the same
  decision as TPasSourceManager.DecodeBytes. False for its lenient UTF-8
  recovery, whose U+FFFD substitutions have no byte-exact inverse. }
function FileEncoding(const ABytes: TBytes; out AEnc: TEncoding;
  out APreamble: Integer): Boolean;
begin
  AEnc := nil;
  APreamble := TEncoding.GetBufferEncoding(ABytes, AEnc, TEncoding.UTF8);
  Result := True;
  if (AEnc.CodePage = CP_UTF8) and
     not TPasSourceManager.IsValidUtf8(ABytes, APreamble) then
  begin
    if APreamble > 0 then
      Exit(False);
    AEnc := TEncoding.ANSI;
  end;
end;

procedure CopyFileTime(const AFrom, ATo: string);
var
  LFrom, LTo: THandle;
  LCreate, LAccess, LWrite: TFileTime;
begin
  LFrom := CreateFile(PChar(AFrom), GENERIC_READ, FILE_SHARE_READ or
    FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
  if LFrom = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  try
    if not GetFileTime(LFrom, @LCreate, @LAccess, @LWrite) then
      RaiseLastOSError;
  finally
    CloseHandle(LFrom);
  end;
  LTo := CreateFile(PChar(ATo), FILE_WRITE_ATTRIBUTES, 0, nil, OPEN_EXISTING,
    0, 0);
  if LTo = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  try
    if not SetFileTime(LTo, @LCreate, @LAccess, @LWrite) then
      RaiseLastOSError;
  finally
    CloseHandle(LTo);
  end;
end;

{ Writes file AFileId's bytes with its edits spliced in at byte offsets. }
procedure WriteFile(AFileId: Integer; const AOutPath: string);
var
  LBytes, LOut: TBytes;
  LEnc: TEncoding;
  LPreamble, LTextPos, LBytePos, LCount, LIdx: Integer;
  LText: string;
  LEdits: TList<TEdit>;
  LEdit: TEdit;
  LStream: TBytesStream;
  LIns: TBytes;
begin
  LBytes := TFile.ReadAllBytes(GPre.FileNames[AFileId]);
  if not FileEncoding(LBytes, LEnc, LPreamble) then
    raise Exception.CreateFmt('%s: not valid UTF-8 despite its BOM - no ' +
      'byte-exact edit is possible', [GPre.FileNames[AFileId]]);
  LText := LEnc.GetString(LBytes, LPreamble, Length(LBytes) - LPreamble);
  // The offsets are the lexer's: they index the text IT read.
  if LText <> GPre.Files[AFileId].Source then
    raise Exception.CreateFmt('%s: decodes differently from the text the ' +
      'lexer read', [GPre.FileNames[AFileId]]);
  if LEnc.GetByteCount(LText, 0, Length(LText), 0) <>
     Length(LBytes) - LPreamble then
    raise Exception.CreateFmt('%s: the %s decoding does not round-trip',
      [GPre.FileNames[AFileId], LEnc.EncodingName]);
  LEdits := TList<TEdit>.Create;
  LStream := TBytesStream.Create;
  try
    for LEdit in GEdits do
      if LEdit.FileId = AFileId then
        LEdits.Add(LEdit);
    LEdits.Sort(TComparer<TEdit>.Construct(
      function(const A, B: TEdit): Integer
      begin
        Result := A.Offset - B.Offset;
        if Result = 0 then
          Result := A.Order - B.Order;
      end));
    if LPreamble > 0 then
      LStream.WriteBuffer(LBytes[0], LPreamble);
    LTextPos := 0;
    LBytePos := LPreamble;
    for LIdx := 0 to LEdits.Count - 1 do
    begin
      LEdit := LEdits[LIdx];
      LCount := LEnc.GetByteCount(LText, LTextPos, LEdit.Offset - LTextPos, 0);
      if LCount > 0 then
        LStream.WriteBuffer(LBytes[LBytePos], LCount);
      Inc(LBytePos, LCount);
      LTextPos := LEdit.Offset;
      LIns := LEnc.GetBytes(LEdit.Text);
      if Length(LIns) > 0 then
        LStream.WriteBuffer(LIns[0], Length(LIns));
      // A replacement: the bytes of the replaced characters are skipped.
      if LEdit.Len > 0 then
      begin
        Inc(LBytePos, LEnc.GetByteCount(LText, LEdit.Offset, LEdit.Len, 0));
        Inc(LTextPos, LEdit.Len);
      end;
    end;
    if LBytePos < Length(LBytes) then
      LStream.WriteBuffer(LBytes[LBytePos], Length(LBytes) - LBytePos);
    LOut := Copy(LStream.Bytes, 0, LStream.Size);
  finally
    LStream.Free;
    LEdits.Free;
  end;
  TDirectory.CreateDirectory(TPath.GetDirectoryName(AOutPath));
  TFile.WriteAllBytes(AOutPath, LOut);
  CopyFileTime(GPre.FileNames[AFileId], AOutPath);
end;

function NoSlash(const APath: string): string;
begin
  Result := ExcludeTrailingPathDelimiter(TPath.GetFullPath(APath));
end;

// The deepest directory containing both - '' when they share no root.
function CommonDir(const A, B: string): string;
var
  LA, LB: TArray<string>;
  LIdx: Integer;
begin
  LA := A.Split([PathDelim]);
  LB := B.Split([PathDelim]);
  Result := '';
  LIdx := 0;
  while (LIdx < Length(LA)) and (LIdx < Length(LB)) and
        SameText(LA[LIdx], LB[LIdx]) do
  begin
    if LIdx = 0 then
      Result := LA[0]
    else
      Result := Result + PathDelim + LA[LIdx];
    Inc(LIdx);
  end;
end;

// APath's place under AOut, mirrored from ARoot (a directory APath is under).
function Mirror(const APath, ARoot, AOut: string): string;
begin
  if not SameText(Copy(APath, 1, Length(ARoot) + 1), ARoot + PathDelim) and
     not SameText(APath, ARoot) then
    raise Exception.CreateFmt('%s is not under %s', [APath, ARoot]);
  Result := AOut + Copy(APath, Length(ARoot) + 1, MaxInt);
end;

const
  cPPCodeNames: array[TPasPPDiagCode] of string = ('unbalanced-else',
    'unbalanced-endif', 'unterminated-conditional', 'include-not-found',
    'include-cycle', 'include-too-deep', 'if-unreadable', 'if-guessed',
    'unsupported-insertion', 'popopt-without-pushopt',
    'cross-include-conditional');

{ -oracle: does the project's analysis preprocess this unit differently from
  a bare preprocessor? Only where a $IF asked what a bare one cannot answer -
  a Declared() name, a constant, a SizeOf - and the guess could matter: the
  preprocessor records exactly those, and a guessed or unreadable $IF says
  so too. Anything else comes out the same, so it is left to the cheap run. }
function OracleCouldMatter(const APre: TPasPreprocessed): Boolean;
var
  LIdx: Integer;
begin
  Result := (Length(APre.UnresolvedDeclared) > 0) or
    (Length(APre.UnresolvedSymbols) > 0);
  for LIdx := 0 to High(APre.Diagnostics) do
    if APre.Diagnostics[LIdx].Code in [ppIfNeedsSemantics, ppBadIfExpression] then
      Result := True;
end;

var
  GArg, GFile, GOut, GRoot, GPath, GLine: string;
  GMode: TXformMode;
  GPlatform: TPasPlatform;
  GExcl: TTMExcl;
  GInfo: TPasPlatformInfo;
  GIncDirs, GDefNames, GUndefNames, GSearch: TList<string>;
  GOracle, GOracleUsed: Boolean;
  GProject: TPasSemaProject;
  GProjectId: Integer;
  GLiveness: TLivenessRun;
  GSM: TPasSourceManager;
  GDefines: TPasDefines;
  GPP: TPasPreprocessor;
  GDiags: TArray<TPasParseDiag>;
  GIdx, GJdx, GNonInfo, GOffset, GApplied: Integer;
  GSite: TSite;
  GEdit: TEdit;
  GName: string;
  GWritten: TDictionary<string, Boolean>;
  GSitesText, GFileLines: TStringList;
  GNamespaces: TArray<string>;
  GHasNamespaces: Boolean;

{ -oracle: the unit scope names the project analysis resolves a unit name
  with - the compile's own (-NS:, the driver passes dcc's), else the IDE's
  default for the platform. Without them `uses AnsiStrings` found nothing
  and a `$IF Declared(StrScan)` after it stayed a guess (plan S7: a harness
  defect, not PasTree's - every other tool sets them). }
function ProjectNamespaces: TArray<string>;
begin
  if GHasNamespaces then
    Result := GNamespaces
  else
    Result := PasDefaultNamespaces(GPlatform);
end;

begin
  try
    GMode := xmT0;
    GPlatform := pfWin64;
    GFile := '';
    GOut := '';
    GIncDirs := TList<string>.Create;
    GDefNames := TList<string>.Create;
    GUndefNames := TList<string>.Create;
    GSearch := TList<string>.Create;
    GSiteRanges := TList<TSiteRange>.Create;
    GOracle := False;
    GOracleUsed := False;
    GProject := nil;
    for GIdx := 1 to ParamCount do
    begin
      GArg := ParamStr(GIdx);
      if SameText(GArg, '-oracle') then
      begin
        GOracle := True;
        Continue;
      end;
      if GArg.StartsWith('-S:', True) then
      begin
        for GName in Copy(GArg, 4, MaxInt).Split([';']) do
          if Trim(GName) <> '' then
            GSearch.Add(NoSlash(Trim(GName)));
        Continue;
      end;
      if GArg.StartsWith('-NS:', True) then
      begin
        GNamespaces := nil;
        for GName in Copy(GArg, 5, MaxInt).Split([';']) do
          if Trim(GName) <> '' then
            GNamespaces := GNamespaces + [Trim(GName)];
        GHasNamespaces := True;
        Continue;
      end;
      if GArg.StartsWith('-sites:', True) then
      begin
        ParseSiteList(Copy(GArg, 8, MaxInt));
        Continue;
      end;
      if GArg.StartsWith('-mode:', True) then
      begin
        GArg := LowerCase(Copy(GArg, 7, MaxInt));
        if GArg = 't0' then GMode := xmT0
        else if GArg = 'ts' then GMode := xmTS
        else if GArg = 't0f' then GMode := xmT0F
        else if GArg = 't1' then GMode := xmT1
        else if GArg = 't2' then GMode := xmT2
        else if GArg = 't3' then GMode := xmT3
        else if GArg = 't3x' then GMode := xmT3X
        else if GArg = 'tq' then GMode := xmTQ
        else if GArg = 'tqs' then GMode := xmTQS
        else if GArg = 'tm' then GMode := xmTM
        else if GArg = 'tqm' then GMode := xmTQM
        else if GArg = 'tms' then GMode := xmTMS
        else raise Exception.Create('unknown mode: ' + GArg);
      end
      else if GArg.StartsWith('-Undef:', True) then
      begin
        for GName in Copy(GArg, 8, MaxInt).Split([';']) do
          if Trim(GName) <> '' then
            GUndefNames.Add(Trim(GName));
      end
      else if GArg.StartsWith('-out:', True) then
        GOut := NoSlash(Copy(GArg, 6, MaxInt))
      else if GArg.StartsWith('-p:', True) then
      begin
        if not TryParsePlatformName(Copy(GArg, 4, MaxInt), GPlatform) then
          raise Exception.Create('unknown platform: ' + Copy(GArg, 4, MaxInt));
      end
      else if GArg.StartsWith('-D:', True) then
      begin
        for GName in Copy(GArg, 4, MaxInt).Split([';']) do
          if Trim(GName) <> '' then
            GDefNames.Add(Trim(GName));
      end
      else if GArg.StartsWith('-I:', True) then
      begin
        for GName in Copy(GArg, 4, MaxInt).Split([';']) do
          if Trim(GName) <> '' then
            GIncDirs.Add(NoSlash(Trim(GName)));
      end
      else if GArg.StartsWith('-') then
        raise Exception.Create('unknown option: ' + GArg)
      else
        GFile := TPath.GetFullPath(GArg);
    end;
    if (GFile = '') or (GOut = '') then
    begin
      Writeln(ErrOutput, 'Usage: PasTreeXform <unit.pas> -mode:t0|ts|t0f|t1|t2|t3|t3x|tq|tqs|tm|tqm|tms ' +
        '-out:<dir> [-p:<platform>] [-D:X;Y]... [-Undef:X;Y]... ' +
        '[-I:<dir>[;<dir>]]... [-oracle [-S:<dir>[;<dir>]]...] ' +
        '[-sites:<ids>]');
      ExitCode := 1;
      Exit;
    end;

    GInfo := PlatformInfo(GPlatform);
    GSM := TPasSourceManager.Create(GIncDirs.ToArray);
    GDefines := CreatePlatformDefines(GPlatform);
    for GName in GDefNames do
      GDefines.Define(GName);
    for GName in GUndefNames do
      GDefines.Undefine(GName);
    GPP := TPasPreprocessor.Create(GSM, GDefines, DEFAULT_COMPILER_VERSION,
      GInfo.PointerBytes, GInfo.ExtendedBytes);
    GEdits := TList<TEdit>.Create;
    GPrintCase := TList<TEdit>.Create;
    GSites := TList<TSite>.Create;
    GArgMap := TDictionary<string, string>.Create;
    GInlineNames := TDictionary<string, Boolean>.Create;
    GInitStarts := TDictionary<Integer, Boolean>.Create;
    GQUnboundList := TStringList.Create;
    GQPlanted := TDictionary<string, Boolean>.Create;
    GQHistory := TDictionary<string, Integer>.Create;
    GQInvisibleList := TStringList.Create;
    GQSelftest := GMode = xmTQS;
    GQMemberSelftest := GMode = xmTMS;
    GQUnits := GMode in [xmTQ, xmTQS, xmTQM];
    GQMembers := GMode in [xmTM, xmTQM, xmTMS];
    GMMismatchList := TStringList.Create;
    GMPreamble := TStringList.Create;
    GMAnchors := TDictionary<Integer, string>.Create;
    GMStoredUse := TDictionary<Int64, Boolean>.Create;
    GWritten := TDictionary<string, Boolean>.Create;
    GSitesText := TStringList.Create;
    GFileLines := TStringList.Create;
    try
      GPre := GPP.Process(GFile);
      // A preprocessor diagnostic is worth seeing: an include not found here
      // is a file the copy will lack. $IF-needs-semantics is informational.
      GNonInfo := 0;
      for GIdx := 0 to High(GPre.Diagnostics) do
        if GPre.Diagnostics[GIdx].Code <> ppIfNeedsSemantics then
        begin
          Inc(GNonInfo);
          Writeln(ErrOutput, 'PP ', PosText(GPre.Diagnostics[GIdx].FileId,
            GPre.Diagnostics[GIdx].Start), ': ',
            PP_DIAG_MESSAGES[GPre.Diagnostics[GIdx].Code], ' ',
            GPre.Diagnostics[GIdx].Detail);
        end;

      if GOracle and (GUndefNames.Count > 0) then
        raise Exception.Create('-Undef cannot reach a project analysis: ' +
          'use -oracle without it');
      if GMode in cQModes then
      begin
        // tq judges the bindings of the project analysis itself: its model
        // of the unit, the tree that model was built on and the stream it
        // was built from - the oracle's, whatever the unit's $IFs ask.
        GQProject := TPasSemaProject.Create(GPlatform,
          GSearch.ToArray + GIncDirs.ToArray, GDefNames.ToArray);
        GQProject.SetNamespaces(ProjectNamespaces);
        GQMid := GQProject.AnalyzeProject(GFile);
        if (GQMid < 0) or
           (Length(GQProject.Model(GQMid).Tree.Source.Files) = 0) then
          raise Exception.Create('the project analysis kept no ' +
            'preprocessed text of the unit');
        if GQProject.Model(GQMid).Demoted or
           (GQProject.Model(GQMid).NodeScope = nil) then
          raise Exception.Create('the project analysis kept no scopes of ' +
            'the unit');
        GPre := GQProject.Model(GQMid).Tree.Source;
        GQProbe := TPasXProbe.Create;
        if not SameText(NoSlash(GPre.FileNames[0]), NoSlash(GFile)) then
          raise Exception.CreateFmt('the project analyzed %s',
            [GPre.FileNames[0]]);
        GOracleUsed := True;
      end
      else if GOracle and OracleCouldMatter(GPre) then
      begin
        // The stream PasTree really analyzes: the project's first pass
        // (compiler-provided names answered) and its second, the oracle's.
        GProject := TPasSemaProject.Create(GPlatform,
          GSearch.ToArray + GIncDirs.ToArray, GDefNames.ToArray);
        GProject.SetNamespaces(ProjectNamespaces);
        GProjectId := GProject.AnalyzeProject(GFile);
        if (GProjectId < 0) or
           (Length(GProject.Model(GProjectId).Tree.Source.Files) = 0) then
          raise Exception.Create('the project analysis kept no ' +
            'preprocessed text of the unit');
        GPre := GProject.Model(GProjectId).Tree.Source;
        if not SameText(NoSlash(GPre.FileNames[0]), NoSlash(GFile)) then
          raise Exception.CreateFmt('the project analyzed %s',
            [GPre.FileNames[0]]);
        GOracleUsed := True;
      end;

      SetLength(GIncludedTwice, Length(GPre.FileNames));
      for GIdx := 0 to High(GPre.FileNames) do
        for GJdx := 0 to High(GPre.FileNames) do
          if (GIdx <> GJdx) and
             SameText(GPre.FileNames[GIdx], GPre.FileNames[GJdx]) then
            GIncludedTwice[GIdx] := True;

      GDiags := nil;
      GApplied := 0;
      if GMode in [xmTS, xmT1, xmT2, xmT3, xmT3X] + cQModes then
      begin
        GTree := TPasParser.ParseFile(GPre, GDiags);
        // tq: the parse above counts the diagnostics; the sites are the
        // analysis's own nodes.
        if GMode in cQModes then
          GTree := GQProject.Model(GQMid).Tree;
        for GIdx := 0 to High(GDiags) do
          if GDiags[GIdx].VisIndex <= High(GPre.Visible) then
          begin
            GOffset := VisOffset(GDiags[GIdx].VisIndex, GJdx);
            Writeln(ErrOutput, 'PARSE ', PosText(GJdx, GOffset), ': ',
              GDiags[GIdx].Msg);
          end
          else
            Writeln(ErrOutput, 'PARSE <eof>: ', GDiags[GIdx].Msg);
        GUnitName := HeaderName;
        // The printer is for valid code only.
        if (GMode in [xmT3, xmT3X]) and (Length(GDiags) > 0) then
          raise Exception.CreateFmt('the unit parses with %d diagnostics: no ' +
            'print', [Length(GDiags)]);
        case GMode of
          xmTS: VisitRoutines(0, '');
          xmT1:
            begin
              GLinesKept := LinesKept(['D', 'L']);
              CollectInitStarts(0);
              T1Walk(0, '', -2);
            end;
          xmT2:
            begin
              GLinesKept := LinesKept(['D', 'L', 'Y']);
              CollectInlineNames(0);
              T2Walk(0, '', False, False);
            end;
          xmT3:
            T3Walk;
          xmTQ, xmTQS, xmTM, xmTQM, xmTMS:
            begin
              GQImplTok := MaxInt;
              GJdx := GTree.Nodes[0].FirstChild;
              while GJdx <> NIL_NODE do
              begin
                if GTree.Nodes[GJdx].Kind = nkImplementationSec then
                  GQImplTok := GTree.Nodes[GJdx].FirstToken;
                GJdx := GTree.Nodes[GJdx].NextSibling;
              end;
              GQSystemMid := -1;
              GQSysInitMid := -1;
              for GIdx := 0 to GQProject.ModelCount - 1 do
                if GQProject.Model(GIdx).UnitNameLower = 'system' then
                  GQSystemMid := GIdx
                else if GQProject.Model(GIdx).UnitNameLower = 'sysinit' then
                  GQSysInitMid := GIdx;
              if GQMembers then
              begin
                CollectInlineNames(0);
                TMCollectStored(0, False);
                GMOptimized := LinesKept(['O']);
              end;
              GQSymInfoOn := LinesKept(['Y']);
              GQRefInfoOn := LinesKept(['r']);
              GQWin32 := GPlatform = pfWin32;
              GQHistory.Clear;
              TQCollectHistory(0, nil);
              TQWalk(0, '', False, False, False, 0);
              if GQMembers then
                TMPreamble;
            end;
        else
          // t3x: the print, then t1's parentheses and t2's blocks over it -
          // their sites after its own, under t2's line rule for both.
          T3Walk;
          GLinesKept := LinesKept(['D', 'L', 'Y']);
          CollectInitStarts(0);
          T1Walk(0, '', -2);
          CollectInlineNames(0);
          T2Walk(0, '', False, False);
        end;
        for GEdit in GPrintCase do
          GEdits.Add(GEdit);
        for GIdx := 0 to GSites.Count - 1 do
          if SiteSelected(GIdx + 1) then
          begin
            GSite := GSites[GIdx];
            if Length(GSite.Edits) > 0 then
              for GEdit in GSite.Edits do
                GEdits.Add(GEdit)
            else
            begin
              AddEdit(GSite.OpenVis, GSite.OpenAfter, GSite.OpenOrder,
                GSite.OpenText);
              if GSite.CloseText <> '' then
                AddEdit(GSite.CloseVis, not GSite.CloseBefore,
                  GSite.CloseOrder, GSite.CloseText);
            end;
            Inc(GApplied);
          end;
      end
      else if GMode = xmT0F then
      begin
        if GOracleUsed then
          GLiveness :=
            function(const APaths, ATexts: TArray<string>): TPasPreprocessed
            var
              LProject: TPasSemaProject;
              LId, LIdx: Integer;
            begin
              LProject := TPasSemaProject.Create(GPlatform,
                GSearch.ToArray + GIncDirs.ToArray, GDefNames.ToArray);
              try
                LProject.SetNamespaces(ProjectNamespaces);
                for LIdx := 0 to High(APaths) do
                  LProject.SetBuffer(APaths[LIdx], ATexts[LIdx]);
                LId := LProject.AnalyzeProject(GFile);
                if LId < 0 then
                  raise Exception.Create('the liveness analysis failed');
                Result := LProject.Model(LId).Tree.Source;
              finally
                LProject.Free;
              end;
            end
        else
          GLiveness :=
            function(const APaths, ATexts: TArray<string>): TPasPreprocessed
            var
              LSM: TPasSourceManager;
              LPP: TPasPreprocessor;
              LIdx: Integer;
            begin
              LSM := TPasSourceManager.Create(GIncDirs.ToArray);
              LPP := TPasPreprocessor.Create(LSM, GDefines,
                DEFAULT_COMPILER_VERSION, GInfo.PointerBytes,
                GInfo.ExtendedBytes);
              try
                for LIdx := 0 to High(APaths) do
                  LSM.SetBuffer(APaths[LIdx], ATexts[LIdx]);
                Result := LPP.ProcessText(GFile, ATexts[0]);
              finally
                LPP.Free;
                LSM.Free;
              end;
            end;
        Flatten(GLiveness);
        if GOracleUsed then
          GFlatStats := GFlatStats + ' stream=project'
        else
          GFlatStats := GFlatStats + ' stream=preprocessor';
        // The sites of t0f are the preprocessor's diagnostics: a guessed or
        // unreadable $IF is where a DIFF most likely comes from.
        for GIdx := 0 to High(GPre.Diagnostics) do
        begin
          GSite.Kind := cPPCodeNames[GPre.Diagnostics[GIdx].Code];
          GSite.Ops := GPre.Diagnostics[GIdx].Detail.Replace(#9, ' ').
            Replace(#13, ' ').Replace(#10, ' ');
          GSite.Span := PosText(GPre.Diagnostics[GIdx].FileId,
            GPre.Diagnostics[GIdx].Start);
          GSite.Routine := '';
          GSite.Edit := '';
          GSite.OpenVis := -1;
          GSite.CloseVis := -1;
          GSites.Add(GSite);
        end;
      end;

      // The mirror root: every file read and every -I directory under it.
      GRoot := NoSlash(TPath.GetDirectoryName(GFile));
      for GIdx := 1 to High(GPre.FileNames) do
        GRoot := CommonDir(GRoot, NoSlash(TPath.GetDirectoryName(
          GPre.FileNames[GIdx])));
      for GPath in GIncDirs do
        GRoot := CommonDir(GRoot, GPath);
      if GRoot = '' then
        raise Exception.Create('the unit, its includes and the -I ' +
          'directories share no root directory');

      // One file per distinct output: t0f writes each inclusion as its own
      // file or as an instance copy, the others every file as itself.
      for GIdx := 0 to High(GPre.FileNames) do
      begin
        if GMode = xmT0F then
          GPath := Mirror(NoSlash(GOutName[GIdx]), GRoot, GOut)
        else
          GPath := Mirror(NoSlash(GPre.FileNames[GIdx]), GRoot, GOut);
        if GWritten.ContainsKey(LowerCase(GPath)) then
          Continue;
        GWritten.Add(LowerCase(GPath), True);
        WriteFile(GIdx, GPath);
        if (GMode = xmT0F) and GIsCopy[GIdx] then
          GFileLines.Add('copy ' + NoSlash(GPre.FileNames[GIdx]) + #9 + GPath)
        else
          GFileLines.Add('file ' + NoSlash(GPre.FileNames[GIdx]) + #9 + GPath);
      end;

      GSitesText.Add(Format('# PasTreeXform %s  mode=%s  platform=%s  ' +
        'files=%d  parse-diagnostics=%d  pp-diagnostics=%d  ' +
        'dropped-sites=%d  excluded-type=%d  excluded-ctor=%d  ' +
        'excluded-at=%d  excluded-inline=%d  excluded-label=%d  ' +
        'excluded-asm=%d  excluded-call=%d  excluded-stored=%d  ' +
        'excluded-lines=%d  excluded-init=%d  excluded-print=%d  ' +
        'applied=%d  stream=%s',
        [PasTreeVersion, cModeNames[GMode], PlatformName(GPlatform),
        Length(GPre.FileNames), Length(GDiags), GNonInfo, GDropped, GExcluded,
        GExcludedCtor, GExcludedAt, GExcludedInline, GExcludedLabel,
        GExcludedAsm, GExcludedCall, GExcludedStored, GExcludedLines,
        GExcludedInit, GExcludedPrint, GApplied, IfThen(GOracleUsed, 'project',
        'preprocessor')]));
      if GMode in [xmT3, xmT3X] then
        GSitesText.Add('# print ' + GPrintStats);
      if GMode in cQModes then
      begin
        GSitesText.Add(Format('# names locals=%d  excluded-member=%d  ' +
          'excluded-with=%d  excluded-static=%d  excluded-nested=%d  ' +
          'excluded-shadowed=%d  excluded-overload=%d  excluded-stored=%d  ' +
          'excluded-forward=%d  excluded-position=%d  unbound=%d  ' +
          'invisible=%d  selectors=%d', [GQLocal, GQMember, GQWith, GQStatic,
          GQNested, GQShadowed, GQOverload, GQStored, GQForward, GQPosition,
          GQUnbound, GQInvisible, GQSelector]));
        for GLine in GQUnboundList do
          GSitesText.Add('# unbound' + #9 + GLine);
        for GLine in GQInvisibleList do
          GSitesText.Add('# invisible' + #9 + GLine);
        if GQMembers then
        begin
          GLine := '# members mismatch=' + IntToStr(GMMismatch);
          for GExcl := Low(TTMExcl) to High(TTMExcl) do
            GLine := GLine + Format('  excluded-%s=%d',
              [cTMExclNames[GExcl], GMExcl[GExcl]]);
          GSitesText.Add(GLine);
          GSitesText.Add('# preamble' + #9 + GMPreamble.CommaText);
          for GLine in GMMismatchList do
            GSitesText.Add('# mismatch' + #9 + GLine);
        end;
      end;
      GSitesText.Add('# ' + GFile);
      GSitesText.Add('# id' + #9 + 'kind' + #9 + 'ops' + #9 + 'span' + #9 +
        'routine' + #9 + 'edit' + #9 + 'applied');
      for GIdx := 0 to GSites.Count - 1 do
      begin
        GSite := GSites[GIdx];
        GSitesText.Add(Format('%d'#9'%s'#9'%s'#9'%s'#9'%s'#9'%s'#9'%d',
          [GIdx + 1, GSite.Kind, GSite.Ops, GSite.Span, GSite.Routine,
          GSite.Edit, Ord((GSite.OpenVis >= 0) and SiteSelected(GIdx + 1))]));
      end;
      TDirectory.CreateDirectory(GOut);
      GSitesText.WriteBOM := False;
      GSitesText.LineBreak := #13#10;
      GSitesText.SaveToFile(TPath.Combine(GOut, 'sites.txt'), TEncoding.UTF8);

      Writeln('main ', Mirror(NoSlash(GFile), GRoot, GOut));
      for GLine in GFileLines do
        Writeln(GLine);
      for GPath in GIncDirs do
        Writeln('idir ', GPath, #9, Mirror(GPath, GRoot, GOut));
      GLine := IntToStr(GSites.Count);
      if GDropped > 0 then
        GLine := GLine + ' dropped ' + IntToStr(GDropped);
      if GExcluded > 0 then
        GLine := GLine + ' excluded-type ' + IntToStr(GExcluded);
      if GExcludedCtor > 0 then
        GLine := GLine + ' excluded-ctor ' + IntToStr(GExcludedCtor);
      if GExcludedAt > 0 then
        GLine := GLine + ' excluded-at ' + IntToStr(GExcludedAt);
      if GExcludedInline > 0 then
        GLine := GLine + ' excluded-inline ' + IntToStr(GExcludedInline);
      if GExcludedLabel > 0 then
        GLine := GLine + ' excluded-label ' + IntToStr(GExcludedLabel);
      if GExcludedAsm > 0 then
        GLine := GLine + ' excluded-asm ' + IntToStr(GExcludedAsm);
      if GExcludedCall > 0 then
        GLine := GLine + ' excluded-call ' + IntToStr(GExcludedCall);
      if GExcludedStored > 0 then
        GLine := GLine + ' excluded-stored ' + IntToStr(GExcludedStored);
      if GExcludedLines > 0 then
        GLine := GLine + ' excluded-lines ' + IntToStr(GExcludedLines);
      if GExcludedInit > 0 then
        GLine := GLine + ' excluded-init ' + IntToStr(GExcludedInit);
      if GExcludedPrint > 0 then
        GLine := GLine + ' excluded-print ' + IntToStr(GExcludedPrint);
      if GMode in cQModes then
      begin
        if GQMember > 0 then
          GLine := GLine + ' excluded-member ' + IntToStr(GQMember);
        if GQWith > 0 then
          GLine := GLine + ' excluded-with ' + IntToStr(GQWith);
        if GQStatic > 0 then
          GLine := GLine + ' excluded-static ' + IntToStr(GQStatic);
        if GQNested > 0 then
          GLine := GLine + ' excluded-nested ' + IntToStr(GQNested);
        if GQShadowed > 0 then
          GLine := GLine + ' excluded-shadowed ' + IntToStr(GQShadowed);
        if GQOverload > 0 then
          GLine := GLine + ' excluded-overload ' + IntToStr(GQOverload);
        if GQForward > 0 then
          GLine := GLine + ' excluded-forward ' + IntToStr(GQForward);
        if GQStored > 0 then
          GLine := GLine + ' excluded-stored ' + IntToStr(GQStored);
        if GQSymInfo > 0 then
          GLine := GLine + ' excluded-syminfo ' + IntToStr(GQSymInfo);
        if GQPosition > 0 then
          GLine := GLine + ' excluded-position ' + IntToStr(GQPosition);
        // Locals have no qualified form at all: said, not added to the
        // excluded total the driver sums.
        GLine := GLine + ' locals ' + IntToStr(GQLocal);
        if GQUnbound > 0 then
          GLine := GLine + ' unbound ' + IntToStr(GQUnbound);
        if GQInvisible > 0 then
          GLine := GLine + ' invisible ' + IntToStr(GQInvisible);
        if GQMembers then
        begin
          for GExcl := Low(TTMExcl) to High(TTMExcl) do
            if GMExcl[GExcl] > 0 then
              GLine := GLine + ' excluded-' + cTMExclNames[GExcl] + ' ' +
                IntToStr(GMExcl[GExcl]);
          if GMMismatch > 0 then
            GLine := GLine + ' mismatch ' + IntToStr(GMMismatch);
        end;
      end;
      if GMode in [xmTS, xmT1, xmT2, xmT3, xmT3X] + cQModes then
        GLine := GLine + ' applied ' + IntToStr(GApplied);
      Writeln('sites ', GLine);
      if GMode in [xmTS, xmT1, xmT2, xmT3, xmT3X] + cQModes then
        Writeln('parse ', Length(GDiags));
      if GMode in [xmT3, xmT3X] then
        Writeln('print ', GPrintStats);
      if GOracleUsed and (GMode <> xmT0F) then
        Writeln('stream project');
      if GMode = xmT0F then
      begin
        for GName in GArgMap.Keys do
          Writeln('argmap ', GName, #9, GArgMap[GName]);
        Writeln('flatten ', GFlatStats);
      end;
    finally
      GInitStarts.Free;
      GQUnboundList.Free;
      GQPlanted.Free;
      GQHistory.Free;
      GQInvisibleList.Free;
      GMMismatchList.Free;
      GMPreamble.Free;
      GMAnchors.Free;
      GMStoredUse.Free;
      GQProbe.Free;
      GQProject.Free;
      GPrintCase.Free;
      GInlineNames.Free;
      GArgMap.Free;
      GFileLines.Free;
      GSitesText.Free;
      GWritten.Free;
      GSites.Free;
      GEdits.Free;
      GPP.Free;
      GDefines.Free;
      GSM.Free;
      GIncDirs.Free;
      GDefNames.Free;
      GUndefNames.Free;
      GSearch.Free;
      GSiteRanges.Free;
      GProject.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
