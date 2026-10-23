unit PasTree.Preprocessor;

{
  PasTree - the preprocessor (spec: object-pascal-spec 1.3, B.2.2).

  Consumes raw token streams from the lexer and produces the VISIBLE token
  stream the parser reads:
  - evaluates conditional compilation ($IFDEF $IFNDEF $IF $ELSEIF $ELSE
    $ENDIF $IFEND $IFOPT) against a define set and switch state;
  - handles $DEFINE / $UNDEF (scoped to the unit being processed);
  - splices $I / $INCLUDE files, with an include stack (cycle guard) and
    per-token file identity, so spans always point into the right file;
  - tracks single-letter switch state (+/-, ON/OFF long forms) and the
    $PUSHOPT / $POPOPT stack; $IFOPT reads it;
  - records skipped (inactive) regions per file so raw-lexer diagnostics
    inside them can be suppressed;
  - conditional state spans include boundaries, as a tolerance: dcc 37.0
    refuses a conditional that crosses one (opened in an include and closed
    by the includer: E2280 at the include; an include's $ELSE/$ENDIF acting
    on the includer's conditional: E2280 or a garbled includer), so each
    crossing is diagnosed where it happens and the tokens follow the
    author's evident intent (F22).

  The visible stream is an array of (FileId, TokenIndex) pairs referencing
  the retained raw streams - full fidelity is preserved underneath.
}

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  PasTree.Types,
  PasTree.SourceManager;

type
  TPasVisibleToken = record
    FileId: Integer;
    TokenIndex: Integer;
  end;

  TPasPPDiagCode = (
    ppUnbalancedElse,
    ppUnbalancedEndif,
    ppUnterminatedConditional,
    ppIncludeNotFound,
    ppIncludeCycle,
    ppIncludeTooDeep,
    ppBadIfExpression,
    ppIfNeedsSemantics,       // $IF references symbols (Ord(x), unit consts)
                              // only the semantic phase can evaluate. The
                              // GUESS sits at the leaf, so the verdict is
                              // frequently True (`{$IF not Declared(X)}` is
                              // the flagship case) - "treated as False" was
                              // never the whole story. Informational.
    ppUnsupportedInsertion,   // no longer reported: dcc reads {$I %VAR%}
                              // as a file name (audit B63)
    ppPopWithoutPush,
    ppCrossIncludeConditional // an include's $ELSE/$ELSEIF/$ENDIF/$IFEND
                              // on a conditional its includer opened
  );

  TPasSymbolQuery = (sqConstValue, sqSizeOfType, sqLengthOf, sqDeclared,
    sqHighOf, sqLowOf);   // High(T) / Low(T) of an ordinal type

  // A symbol question nobody could answer - recorded (deduplicated, source
  // order) exactly like UnresolvedDeclared, and consumed by the same second
  // pass to decide whether re-preprocessing could learn anything.
  TPasUnresolvedSymbol = record
    Query: TPasSymbolQuery;
    Name: string;
  end;

  // One `$IF Declared(X)` ask nobody could answer, and where it stood: the
  // directive's file (an index into FileNames) and offset. Every ask is kept,
  // duplicates too - dcc answers a unit's OWN names by position (1.3.2), so
  // one name can be declared at one ask and not yet at an earlier one.
  TPasDeclaredAsk = record
    Name: string;
    FileId: Integer;
    Offset: Integer;
  end;

  TPasPPDiagnostic = record
    Code: TPasPPDiagCode;
    FileId: Integer;
    Start: Integer;
    Len: Integer;
    Detail: string;
    // For ppIfNeedsSemantics: exactly what this evaluation could not answer.
    // The distinction a later pass needs is UNVERIFIED versus CONFIRMED: a
    // `Declared(X)` guess becomes provably correct the moment a full symbol
    // table says X is declared nowhere (the overwhelmingly common
    // platform-guard case), whereas `SizeOf(SomeExoticType)` may stay
    // unanswerable forever. Without this list the two are indistinguishable
    // and reporting both floods normal code - see
    // TPasSemaProject.ReportGuessedIfs.
    Unanswered: TArray<TPasUnresolvedSymbol>;
  end;

  TPasSkippedRegion = record
    Start: Integer;
    EndPos: Integer;
  end;

  // One {$SCOPEDENUMS ON/OFF} state change, positioned in the VISIBLE stream:
  // the new value applies to every visible token at index >= VisIndex. This
  // is the first positional directive-state record (the "Show Defines" plan
  // needs the same shape for $DEFINE later): the resolver needs to know the
  // state AT AN ENUM'S DECLARATION SITE, which a single final flag cannot
  // answer - System.Threading turns it ON for the whole unit while most of
  // the RTL never does, and one unit routinely toggles it around a group of
  // declarations.
  TPasScopedEnumsEvent = record
    VisIndex: Integer;
    Value: Boolean;
  end;

  // One {$Z1/2/4} / {$MINENUMSIZE} state change, positioned like the
  // SCOPEDENUMS events above and for the same reason: an enum's SIZE (what
  // `$IF SizeOf(TEnum)` needs on the second pass) depends on the state AT
  // ITS DECLARATION SITE, and System.pas flips the switch mid-file.
  // {$Z+} is {$Z4} and {$Z-} is {$Z1}, dcc's own equivalences.
  TPasMinEnumEvent = record
    VisIndex: Integer;
    Bytes: Integer;   // 1, 2 or 4
  end;

  // One {$A}/{$ALIGN} state change, positioned exactly like the two above and
  // for the same reason: a record's SIZE depends on the alignment cap at ITS
  // declaration site, and a unit routinely brackets one type with it.
  //
  // The value is the CAP on any single field's alignment, not a forced
  // alignment: dcc-probed, `{$ALIGN 16}` and `{$ALIGN 8}` produce identical
  // layouts because no builtin's natural alignment exceeds 8, while
  // {$ALIGN 4/2/1} really do shrink it. {$A-} is {$A1} and {$A+} is {$A8},
  // dcc's own equivalences.
  TPasAlignEvent = record
    VisIndex: Integer;
    Bytes: Integer;   // 1, 2, 4, 8 or 16
  end;

  // A live `{$APPTYPE CONSOLE}` / `{$APPTYPE GUI}`, at the visible-stream
  // position it was met. A program's last one before its `uses` clause is
  // what decides CONSOLE for every other unit dcc compiles with it (1.3.2;
  // TPasSemaProject.ConsoleTarget). An APPTYPE with any other argument is
  // not recorded.
  TPasAppTypeEvent = record
    VisIndex: Integer;
    Console: Boolean;
  end;

  // One mention of a CONDITIONAL SYMBOL by name - the operand of $DEFINE /
  // $UNDEF / $IFDEF / $IFNDEF, or the argument of `Defined(X)` inside a $IF
  // or $ELSEIF expression. Recorded for every directive the preprocessor
  // walks, ACTIVE OR NOT (an $IFDEF nested in a dead branch is still a
  // reference a search must show, flagged so the reader can tell), in
  // PROCESSING order - an include's directives land where its {$I} was hit,
  // so "the nearest preceding $DEFINE" is a backward scan of this array.
  // Start/Len span the NAME as written in Files[FileId].Source, never the
  // whole directive. This is what Find References / Go to Definition on a
  // define read; nothing in parsing or resolution does.
  TPasDefineRefKind = (drDefine, drUndef, drIfdef, drIfndef, drDefined);
  // Name is POOLED per preprocessor (see TPasSpellingPool): the client closure
  // has 908k rows over 3101 distinct names. Field order is layout - Name last
  // makes the record 24 bytes instead of 32.
  TPasDefineRef = record
    FileId: Integer;
    Start: Integer;
    Len: Integer;
    Kind: TPasDefineRefKind;
    Active: Boolean;   // the directive itself sits in live code
    Name: string;
  end;

  // One mention of a name that is NOT a conditional symbol inside a `$IF` /
  // `$ELSEIF` expression - `CompilerVersion` of `{$IF CompilerVersion < 31}`,
  // a unit constant, the argument of `Declared(X)` or `SizeOf(T)`, a callee
  // (`SizeOf`, `Defined`, `Declared`) - so a hover or a jump on it has
  // something to find (pastree-lsp, 2026-10-07: neither answered there).
  // Recorded for active and dead directives alike, like TPasDefineRef - a
  // `$ELSEIF` after a taken branch and a `$IF` in a skipped region are parsed
  // for their names without being evaluated (0.94.1; until then neither
  // recorded anything) - and in the same coordinates: Start/Len span the name as
  // written in Files[FileId].Source. Resolution is the reader's - the name is
  // looked up as the unit's code would see it (TPasNavigator.IfNameAt).
  TPasIfNameRef = record
    FileId: Integer;
    Start: Integer;
    Len: Integer;
    Active: Boolean;
    Name: string;
  end;

  // One `{$I file}` / `{$INCLUDE file}` directive SITE, in the includer's file
  // coordinates - what a Go To list shows as an `include` row and what a jump
  // to "where is this file pulled in" lands on. Recorded whether or not the
  // include loaded: IncludedFileId is the pulled-in file's index into Files,
  // or -1 when it was not found, cycled or nested too deep (the diagnostic
  // says which). VisIndex is the index the FIRST visible token of the
  // included text would take (= Visible count when the directive was met),
  // so a source-ordered list can slot the row between the tokens around it.
  // Retained across DemoteText like DefineRefs (it is not text).
  TPasIncludeRef = record
    FileId: Integer;          // the includer
    Start: Integer;           // the directive's offset in that file
    Len: Integer;
    Arg: string;              // the file name as written
    Path: string;             // resolved full path; '' when not found
    IncludedFileId: Integer;  // index into Files; -1 when not loaded
    VisIndex: Integer;
  end;

  // Where a `$IF` directive stands, for an oracle that answers by position
  // (TPasDeclaredQuery, TPasCondSymbolQuery).
  TPasCondPos = record
    FileName: string;    // as the preprocessed unit's FileNames spells it
    Offset: Integer;     // the directive's offset in that file
  end;

  // What an oracle hands back for a symbol question. A constant is not always
  // a number: the version-guard idiom compares STRINGS -- Indy's
  // `$IF gsIdVersion >= '10.5.5'` -- and a numeric-only answer has to refuse
  // those, which turns a decidable guard into a residual guess.
  TPasSymbolValue = record
    IsStr: Boolean;
    Num: Double;
    Str: string;
    // Set when the oracle returned False because the NAME EXISTS NOWHERE, as
    // opposed to "it exists but I cannot fold its value". The two are
    // different questions: the first has a determined dcc answer to copy (see
    // PasTree.CondEval's abort rules), the second is a genuine open question
    // and the only one worth reporting. Only meaningful when the query
    // returned False, and only trustworthy when the asking unit's imports all
    // resolved -- a missing `uses` can hide a declaration. Also set for a
    // name that exists but is no constant to a `$IF` - a variable, a typed
    // constant - which dcc reads exactly like one declared nowhere (1.3.2).
    NoSymbol: Boolean;
    // Set when a DOTTED name's prefix names nothing at all - no unit, no
    // declaration: dcc's error token that reads False in every shape and
    // never aborts (1.3.2). Same trust condition as NoSymbol.
    UnknownPrefix: Boolean;
  end;

  { Answers symbol questions from a `$IF` expression - the widened sibling of
    TPasDeclaredQuery, same three-state contract: the RESULT says whether the
    oracle could answer at all, AValue is the answer when it could. Nil on the
    first pass; TPasSemaProject.SymbolQueryFor supplies it on the second.

    APos says where the directive stands, as for TPasDeclaredQuery: dcc
    reads the asking unit's own constants and types by position. FileName
    '' when there is no directive to place (a question asked again after
    the pass); the oracle then answers position-free. }
  TPasCondSymbolQuery = reference to function(AQuery: TPasSymbolQuery;
    const AName: string; const APos: TPasCondPos;
    out AValue: TPasSymbolValue): Boolean;

  TPasSwitchState = array['A'..'Z'] of Boolean;

  // {$RTTI mode METHODS(set) PROPERTIES(set) FIELDS(set)} (19.2.1) -- unlike
  // the single-letter switches this has real grammar to parse, not just an
  // ON/OFF flag: a mode word plus up to three category clauses, each an
  // explicit visibility set (or a AA..BB range). HasXxx tells "was this
  // category clause present at all" apart from "present with an empty set".
  TPasRttiVisibility = (rvPrivate, rvProtected, rvPublic, rvPublished);
  TPasRttiVisibilitySet = set of TPasRttiVisibility;
  TPasRttiMode = (rmInherit, rmExplicit);

  TPasRttiState = record
    Mode: TPasRttiMode;               // dcc default: INHERIT
    HasMethods: Boolean;
    Methods: TPasRttiVisibilitySet;
    HasFields: Boolean;
    Fields: TPasRttiVisibilitySet;
    HasProperties: Boolean;
    Properties: TPasRttiVisibilitySet;
  end;

  // Everything {$PUSHOPT} must save: the single-letter switches PLUS the
  // long-form-only options tracked individually (real dcc's PUSHOPT/POPOPT
  // covers all compiler options, SCOPEDENUMS and RTTI included).
  // Also the state a unit STARTS in (TPasPreprocessor.StartState): the
  // project's switches, which dcc takes from its command line (`-$D-`,
  // `-$A4`; a .dproj's DCC_* properties become exactly those) - only
  // Switches, MinEnumSize and Align have a command-line form, the rest start
  // at dcc's defaults whatever the record holds.
  TPasOptState = record
    Switches: TPasSwitchState;
    ScopedEnums: Boolean;
    Rtti: TPasRttiState;
    VarPropSetter: Boolean;
    MinEnumSize: Integer;
    Align: Integer;
  end;

  // One tracked option of TPasOptState: a single-letter switch (optA..optZ, in
  // letter order - $A carries the alignment cap and $Z the minimum enum size
  // too) or a long-form-only one.
  TPasOption = (optA, optB, optC, optD, optE, optF, optG, optH, optI, optJ, optK, optL,
    optM, optN, optO, optP, optQ, optR, optS, optT, optU, optV, optW, optX, optY, optZ,
    optScopedEnums, optRtti, optVarPropSetter);
  TPasOptions = set of TPasOption;

  // One LIVE directive that changed the option state - a switch group, a
  // tracked long form, `$PUSHOPT` or `$POPOPT` - in processing order, an
  // include's where its `{$I}` was hit, exactly as TPasDefineRef. Options are
  // positional and linear (1.3.1): an include's switch outlives the include,
  // a `$PUSHOPT` in one pairs with the includer's `$POPOPT`, a switch in a
  // routine body outlives its `end`, and nothing reaches another unit. A
  // dead directive changes nothing and is not recorded, nor is a `$POPOPT`
  // with no snapshot (W1078). Touched names the options the directive WROTE,
  // even to the value they already had (orSet only); State is the whole state
  // after it, so the options at a position are the last row before it -
  // and where each came from is a replay with a stack of its own
  // (TPasNavigator.OptionsAt). Start/Len span the whole directive.
  // Retained across DemoteText (it is not text). Not read by parsing or
  // resolution.
  TPasOptionRefKind = (orSet, orPush, orPop);
  TPasOptionRef = record
    FileId: Integer;
    Start: Integer;
    Len: Integer;
    Kind: TPasOptionRefKind;
    Touched: TPasOptions;
    State: TPasOptState;
  end;

  TPasPreprocessed = record
  public
    FileNames: TArray<string>;              // [0] = main file
    Files: TArray<TPasTokenStream>;
    Visible: TArray<TPasVisibleToken>;
    Skipped: TArray<TArray<TPasSkippedRegion>>;  // per file, sorted
    // Per file, sorted: every directive that is itself dead code - the
    // spans Skipped leaves out of a dead branch. Skipped never holds a
    // directive (each one closes the region, which reopens after it), so a
    // `{$DEFINE X}` or a nested `{$IFDEF}` inside a dead branch was a hole
    // in it (pastree-lsp's inactive-code greying, 2026-10-09). A directive
    // is dead when the state it is read in is: a `$IF`/`$IFDEF`/`$IFNDEF`/
    // `$IFOPT` or any other directive when the code before it is dead, a
    // `$ELSEIF`/`$ELSE`/`$ENDIF` when its chain's enclosing state is - so
    // the markers of a chain in live code are never in it, whichever branch
    // was taken. Skipped plus this, merged, is everything dcc ignores.
    DeadDirectives: TArray<TArray<TPasSkippedRegion>>;
    Diagnostics: TArray<TPasPPDiagnostic>;
    // {$SCOPEDENUMS} state changes, ascending by VisIndex; empty for the
    // overwhelming majority of units (the switch defaults to OFF).
    ScopedEnumsEvents: TArray<TPasScopedEnumsEvent>;
    // Names a `$IF Declared(X)` guard asked about that no one could answer,
    // in source order, deduplicated. Empty unless the unit uses that guard AND
    // the run had no OnDeclared to ask - which is the signal a caller with a
    // symbol table uses to decide the unit is worth preprocessing again.
    UnresolvedDeclared: TArray<string>;
    // The same asks with their positions, processing order - see
    // TPasDeclaredAsk.
    DeclaredAsks: TArray<TPasDeclaredAsk>;
    // Same contract for the symbol questions (const values, SizeOf, Length)
    // no OnSymbol could answer - see TPasUnresolvedSymbol.
    UnresolvedSymbols: TArray<TPasUnresolvedSymbol>;
    // {$Z}/{$MINENUMSIZE} state changes, ascending by VisIndex; empty for
    // the overwhelming majority of units (the default is 1).
    MinEnumEvents: TArray<TPasMinEnumEvent>;
    // {$A}/{$ALIGN} state changes, ascending by VisIndex; empty for the
    // overwhelming majority of units (the default is 8).
    AlignEvents: TArray<TPasAlignEvent>;
    // {$APPTYPE} directives taken, ascending by VisIndex - see
    // TPasAppTypeEvent. Retained across DemoteText (it is not text).
    AppTypeEvents: TArray<TPasAppTypeEvent>;
    // Every conditional-symbol mention, processing order - see TPasDefineRef.
    // Retained across DemoteText (it is not text), so a project-wide define
    // search never rehydrates a unit just to test a name.
    DefineRefs: TArray<TPasDefineRef>;
    // Every `{$I}`/`{$INCLUDE}` directive site, processing order - see
    // TPasIncludeRef. Retained across DemoteText for the same reason.
    IncludeRefs: TArray<TPasIncludeRef>;
    // Every other name a `$IF`/`$ELSEIF` expression mentions - see
    // TPasIfNameRef. Retained across DemoteText too.
    IfNameRefs: TArray<TPasIfNameRef>;
    // Every live directive that changed the option state, processing order -
    // see TPasOptionRef. Retained across DemoteText too.
    OptionRefs: TArray<TPasOptionRef>;
    function VisibleToken(AIndex: Integer): TPasToken;
    function VisibleText(AIndex: Integer): string;
    { SameText(VisibleText(AIndex), AWord) without materializing the text -
      the parser's word tests run through here (see PasTree.Types.
      SliceEqualsWord for the folding contract). }
    function VisibleTextEquals(AIndex: Integer; const AWord: string): Boolean;
    { The raw (PChar, Len) slice of one visible token, for callers that test
      the same token against SEVERAL words (IsDirectiveWord's 30-word loop
      would otherwise re-resolve file and token per word). }
    procedure VisibleSlice(AIndex: Integer; out AText: PChar;
      out ALen: Integer);
    function IsSkipped(AFileId, AOffset: Integer): Boolean;
    // The SCOPEDENUMS state in effect at visible-stream position AVisIndex
    // (False = unscoped, the default). Binary search over the event list.
    function ScopedEnumsAt(AVisIndex: Integer): Boolean;
    // The minimum-enum-size in effect at AVisIndex (1 = the default).
    function MinEnumSizeAt(AVisIndex: Integer): Integer;
    // The record field-alignment CAP in effect at AVisIndex (8 = the default).
    function AlignAt(AVisIndex: Integer): Integer;
    // The last {$APPTYPE} taken before visible position AVisIndex: False
    // when there is none, else AConsole says which.
    function AppTypeBefore(AVisIndex: Integer; out AConsole: Boolean): Boolean;
  end;

const
  { The compiler the analyzer emulates when the host names none - see
    PasTree.Platforms, which republishes it under the same name. }
  DEFAULT_COMPILER_VERSION = 37.0;

  // The long name of each tracked option, the one its long-form directive
  // spells - '' for E, F, K and N, letters with no switch of their own.
  PAS_OPTION_NAMES: array[TPasOption] of string = (
    'ALIGN', 'BOOLEVAL', 'ASSERTIONS', 'DEBUGINFO', '', '', 'IMPORTEDDATA',
    'LONGSTRINGS', 'IOCHECKS', 'WRITEABLECONST', '', 'LOCALSYMBOLS',
    'TYPEINFO', '', 'OPTIMIZATION', 'OPENSTRINGS', 'OVERFLOWCHECKS',
    'RANGECHECKS', 'STACKCHECKS', 'TYPEDADDRESS', 'SAFEDIVIDE',
    'VARSTRINGCHECKS', 'STACKFRAMES', 'EXTENDEDSYNTAX', 'REFERENCEINFO',
    'MINENUMSIZE', 'SCOPEDENUMS', 'RTTI', 'VARPROPSETTER');

type
  TPasDefines = class
  private
    FMap: TDictionary<string, Boolean>;
    constructor Create(ACapacity: Integer); overload;   // Clone's pre-size
  public
    constructor Create; overload;
    constructor Create(const ANames: array of string); overload;
    destructor Destroy; override;
    procedure Define(const AName: string);
    procedure Undefine(const AName: string);
    function IsDefined(const AName: string): Boolean;
    function Clone: TPasDefines;
    // Every defined name, sorted case-insensitively - the enumeration a
    // "list all defines" command needs; nothing in preprocessing reads it.
    function Names: TArray<string>;
  end;

  { Answers a `$IF Declared(X)` guard. The preprocessor cannot: the symbol
    table it would need is built from the token stream this very decision
    produces. So the question is handed OUT to whoever has one - see
    TPasSemaProject.RunDeclaredPass, which supplies it on a second pass once
    every unit has a model. Nil means "nobody can answer", the ordinary
    first-pass state.

    A three-state answer, because "I do not know" is a real and common case:
    the RESULT says whether the query could answer at all, ADeclared is the
    answer when it could. A query that knows only the compiler-provided names
    can run on the FIRST pass - it needs no models - and takes the big RTL
    units out of the second pass entirely, which is most of what that pass
    would otherwise cost.

    APos says where the directive stands. dcc answers the asking unit's OWN
    names by position - declared above the directive and in scope there -
    so an oracle that answers those needs it; one that answers only from
    outside the unit ignores it (TPasCondPos). }
  TPasDeclaredQuery = reference to function(const AName: string;
    const APos: TPasCondPos; out ADeclared: Boolean): Boolean;

  // A preprocessor's conditional-symbol spellings: Intern returns the one heap
  // string of a slice's exact (case-sensitive) text, so DefineRefs rows share
  // their Name - and a slice already pooled costs no allocation at all.
  // Per instance and single-threaded, like the preprocessor itself.
  // Open addressing, pow2 capacity, at most half full, FNV-1a over the chars.
  TPasSpellingPool = record
  private
    FSlots: TArray<string>;
    FCount: Integer;
    procedure Grow;
  public
    function Intern(AText: PChar; ALen: Integer): string;
  end;

  TPasPreprocessor = class
  private type
    // The long switch names HandleDirective acts on, classified from the
    // directive's slice (ClassifyLongSwitch); lsNone is every other long
    // word - EXTERNALSYM, REGION, HPPEMIT, WARN ... - passthrough trivia,
    // dropped before anything is materialized.
    TLongSwitch = (lsNone, lsRangeChecks, lsOverflowChecks, lsIOChecks,
      lsOptimization, lsBoolEval, lsWriteableConst, lsTypedAddress,
      lsExtendedSyntax, lsLongStrings, lsStackFrames, lsSafeDivide,
      lsOpenStrings, lsAssertions, lsDebugInfo, lsLocalSymbols,
      lsReferenceInfo, lsTypeInfo, lsDefinitionInfo, lsStackChecks, lsYD,
      lsAppType, lsImportedData, lsVarStringChecks, lsScopedEnums, lsRtti,
      lsMinEnumSize, lsAlign, lsVarPropSetter);
  private
    FSourceManager: TPasSourceManager;
    FBaseDefines: TPasDefines;   // caller-owned project defines
    FDefines: TPasDefines;       // per-run clone: $DEFINE is unit-local!
    FSwitches: TPasSwitchState;
    FScopedEnums: Boolean;
    FScopedEnumsEvents: TList<TPasScopedEnumsEvent>;
    FRttiState: TPasRttiState;
    FVarPropSetter: Boolean;
    FMinEnumSize: Integer;
    FMinEnumEvents: TList<TPasMinEnumEvent>;
    FAlign: Integer;
    FAlignEvents: TList<TPasAlignEvent>;
    FDefineRefs: TList<TPasDefineRef>;
    FDefineNames: TPasSpellingPool;   // DefineRefs' Name, across runs
    FIncludeRefs: TList<TPasIncludeRef>;
    FIfNameRefs: TList<TPasIfNameRef>;
    FSwitchStack: TStack<TPasOptState>;
    FOptionRefs: TList<TPasOptionRef>;
    FTouched: TPasOptions;   // what the directive being handled wrote
    FStartState: TPasOptState;
    FProgramFile: string;
    FProgramDefines: TPasDefines;   // caller-owned; nil = FBaseDefines
    FAppTypeEvents: TList<TPasAppTypeEvent>;
    FFileNames: TList<string>;
    FFiles: TList<TPasTokenStream>;
    // Inside a live asm body: the lexing mode ProcessFile wants for live
    // text, across include boundaries (F26).
    FLiveAsm: Boolean;
    // StopAtImplementation (light mode): the property, whether this run has
    // stopped, and where it is - 0 before the first live `implementation`,
    // 1 right after it, 2 inside the `uses` clause that follows.
    FStopAtImpl: Boolean;
    FStopped: Boolean;
    FStopPhase: Integer;
    // The kind of the last live visible token: an `asm` after a dot is a
    // member name, not a block (spec B.8, the lexer's rule).
    FLastVisKind: TPasTokenKind;
    FVisible: TList<TPasVisibleToken>;
    FSkipped: TObjectList<TList<TPasSkippedRegion>>;
    FDeadDirectives: TObjectList<TList<TPasSkippedRegion>>;
    FDiags: TList<TPasPPDiagnostic>;
    FIncludePathStack: TList<string>;
    // Conditional stack - shared across include boundaries (a tolerance,
    // diagnosed: see the unit header). FCondOpener holds each entry's
    // opening directive (FileId, Start, Len); FCondBase is the depth at
    // which the file being processed began - an entry below it is its
    // includer's.
    FCondParentActive: TList<Boolean>;
    FCondAnyTaken: TList<Boolean>;
    FCondThisActive: TList<Boolean>;
    FCondSeenElse: TList<Boolean>;
    FCondOpener: TList<TPasIncludeRef>;
    FCondBase: Integer;
    FCompilerVersion: Double;
    FTarget: TPasBuiltinTarget;
    FOnDeclared: TPasDeclaredQuery;
    FOnSymbol: TPasCondSymbolQuery;
    FUnresolvedDeclared: TList<string>;
    FDeclaredAsks: TList<TPasDeclaredAsk>;
    FUnresolvedSymbols: TList<TPasUnresolvedSymbol>;
    function Active: Boolean;
    procedure Diag(ACode: TPasPPDiagCode; AFileId, AStart, ALen: Integer;
      const ADetail: string = '');
    procedure DiagUn(ACode: TPasPPDiagCode; AFileId, AStart, ALen: Integer;
      const ADetail: string;
      const AUnanswered: TArray<TPasUnresolvedSymbol>);
    procedure MarkSkipped(AFileId, AStart, AEnd: Integer);
    procedure ProcessFile(AFileId: Integer);
    procedure HandleDirective(AFileId: Integer; const AToken: TPasToken);
    procedure HandleInclude(AFileId: Integer; const AToken: TPasToken;
      const AArg: string);
    procedure AddCondOpener(AFileId: Integer; const AToken: TPasToken);
    procedure CheckCrossInclude(AFileId: Integer; const AToken: TPasToken;
      ATop: Integer);
    procedure ResetSwitches;
    procedure ApplySwitches(const ABody: string);
    procedure ApplyLongSwitch(AKind: TLongSwitch; const AArg: string);
    function CurrentOptState: TPasOptState;
    procedure AddOptionRef(AFileId: Integer; const AToken: TPasToken;
      AKind: TPasOptionRefKind);
    procedure SetScopedEnums(AValue: Boolean);
    procedure SetMinEnumSize(AValue: Integer);
    procedure SetAlign(AValue: Integer);
    procedure ApplyRtti(const AArg: string);
    // AExprStart: file offset of AExpr's first character, so the
    // `Defined(X)` spans CondEval reports relative to the text can be recorded
    // as DefineRefs in file coordinates. AActive: the enclosing state, the
    // flag those refs carry.
    function EvalIfExpression(const AExpr: string; AFileId, AExprStart: Integer;
      AActive: Boolean; const AToken: TPasToken): Boolean;
    // An expression that is not evaluated - a `$ELSEIF` after a taken
    // branch, a `$IF` in a skipped region - still names what it names: its
    // refs are recorded from a parse alone (Alex, 2026-10-09: no hint on
    // MACOS in `{$ELSEIF Defined(MACOS)}` after a taken `$IF`).
    procedure RecordUnevaluatedIf(const AExpr: string; AFileId,
      AExprStart: Integer; AActive: Boolean);
  public
    { APointerBytes / AExtendedBytes / ALongBytes / AExtendedAlign
      parameterize SizeOf() in $IF expressions for the target platform
      (TPasPlatformInfo's fields of those names: Win32 4 / 10 / 4 / 8, Win64
      8 / 8 / 4 / 8, OSX64 8 / 16 / 8 / 16). }
    constructor Create(ASourceManager: TPasSourceManager;
      ADefines: TPasDefines; ACompilerVersion: Double = DEFAULT_COMPILER_VERSION;
      APointerBytes: Integer = 8; AExtendedBytes: Integer = 8;
      ALongBytes: Integer = 4; AExtendedAlign: Integer = 8);
    destructor Destroy; override;
    { Preprocesses a main file loaded via the source manager. The instance
      can be reused for another file afterwards. }
    function Process(const AFileName: string): TPasPreprocessed;
    { Same, but with the main file's text supplied directly (tests, LSP
      buffers). AFileName is used for include resolution and reporting. }
    function ProcessText(const AFileName, ASource: string): TPasPreprocessed;
    { LIGHT MODE: the next runs stop at the end of the unit's implementation
      `uses` clause - after the first LIVE `implementation`, and after the
      `;` of the `uses` clause when one follows it at once (the part of a
      light unit the parser reads, pmInterfaceAndImplUses). The main file is
      lexed only that far too (TPasLexer.Tokenize's stop); the lexer cannot
      tell a live `implementation` from one in a branch not compiled, so when
      the preprocessor reaches the end of a truncated stream without having
      stopped, it goes on lexing from there in pull mode until a live stop
      or the real end of the text (the resume rule: a dead `implementation`
      in the interface must not cut it). An `implementation` written in an
      include stops the unit there. After a stop no conditional is reported
      unterminated (one may legally span the sections), and what lies after
      it - its skipped regions, define, option, include and `` name rows -
      is not recorded. A pooled preprocessor keeps the value: the caller
      sets it for each run. }
    property StopAtImplementation: Boolean read FStopAtImpl
      write FStopAtImpl;
    // The last run stopped early (StopAtImplementation).
    property Stopped: Boolean read FStopped;
    { Set to answer a `$IF Declared(X)` guard - see TPasDeclaredQuery. While
      set the expression is no longer flagged as needing semantics, because it
      no longer does. }
    property OnDeclared: TPasDeclaredQuery read FOnDeclared write FOnDeclared;
    { The symbol oracle for `$IF` const/SizeOf/Length questions - nil on the
      first pass, supplied by the project's second pass exactly like
      OnDeclared. See TPasCondSymbolQuery. }
    property OnSymbol: TPasCondSymbolQuery read FOnSymbol write FOnSymbol;
    { The switch state every file starts in - dcc's no-config state unless
      the host sets the project's (PasStartOptState). Read at the start of
      each Process/ProcessText call. }
    property StartState: TPasOptState read FStartState write FStartState;
    { The define set for the one file AFile (a full path, compared without
      case) when it differs from the set the instance was created with: a
      program's own text sees CONSOLE only under -CC, while the units
      compiled with it follow its APPTYPE directive (TPasSemaProject.
      ConsoleTarget). ADefines stays the caller's; nil drops the exception. }
    procedure SetProgramDefines(const AFile: string; ADefines: TPasDefines);
    { The single-letter switch state as of the end of the last Process/
      ProcessText call -- reset per file (like $DEFINE), so this answers
      "where did the unit leave it", exactly what $IFOPT itself reads.
      1.3.1/1.3.4 (switch directives, $PUSHOPT/$POPOPT) have no AST shape
      of their own to dump -- this is their observation surface, direct
      rather than round-tripped through a conditional's taken/not-taken
      branch (though that path is also tested - see 1.3.1's own case). }
    function SwitchState(ASwitch: Char): Boolean;
    { Same idea for `SCOPEDENUMS`, whose positional history is already on
      TPasPreprocessed.ScopedEnumsEvents/ScopedEnumsAt -- this is just the
      value at END OF FILE, the one a PUSHOPT/POPOPT round-trip case needs. }
    function ScopedEnumsFinal: Boolean;
    { The `RTTI` directive state as of the end of the last Process/ProcessText call --
      reset per file, same "where did the unit leave it" contract as
      SwitchState/ScopedEnumsFinal. 19.2.1: unlike a plain switch this has
      structured content (mode + three optional visibility-set clauses), so
      it is a record, not a Boolean. }
    function RttiState: TPasRttiState;
    { 13.1.6 `VARPROPSETTER` -- long-form-only ON/OFF, OFF by default, and the
      gate on whether a property SETTER may take a `var` parameter (dcc32
      37.0: without it that declaration is a hard
      `E2282 Property setters cannot take var parameters`, reported at the
      PROPERTY declaration rather than at the setter's own; with it the same
      code compiles). Tracked as state only -- PasTree emits no E2282 of its
      own, so nothing here can turn a legal unit into a reported one. A real
      E2282 check would want this POSITIONALLY (the state at each property's
      declaration site, the way `TPasScopedEnumsEvent` does for enums), not
      just the end-of-file value this accessor answers. }
    function VarPropSetterFinal: Boolean;
  end;

{ The state a unit starts in under dcc's command-line switches ASwitches, in
  order, each as dcc takes it (`-$D-`, `$O-`, `A4`, `-$YD`; the `-` and `$`
  are optional): dcc's no-config start state (1.3.2: A C D G H I L N O P V X
  Y on, $A8, $Z1) with each applied by the same rules as an in-file
  switch directive. Probed dcc64 37.0: `-$D0` is D-, `-$D1`/`-$D2` D+, `-$YD`
  Y+, `-$A4` A+, `-$A1` A-, `-$Z2` Z+. An argument the rules do not read
  changes nothing. }
function PasStartOptState(const ASwitches: array of string): TPasOptState;

{ AOption's value in AState as its long form takes it: ON / OFF, the byte
  count of ALIGN and MINENUMSIZE, the RTTI clause (its mode word and each
  category clause given, e.g. `EXPLICIT METHODS([vcPublic])`). }
function PasOptionValue(const AState: TPasOptState;
  AOption: TPasOption): string;

const
  PP_DIAG_MESSAGES: array[TPasPPDiagCode] of string = (
    '$ELSE/$ELSEIF without matching $IF',
    '$ENDIF/$IFEND without matching $IF',
    'Unterminated conditional block',
    'Include file not found',
    'Circular include',
    'Include nesting too deep',
    'Cannot evaluate $IF expression',
    '$IF needs semantic info (unknown leaves guessed False)',
    'Insertion form {$I %...%} is not supported',
    '$POPOPT without $PUSHOPT',
    'Conditional directive acts on a conditional opened outside this ' +
      'include file'
  );

implementation

uses
  System.Classes,   // EStreamError: an include that exists and cannot be read
  System.Generics.Defaults,
  PasTree.Lexer,
  // Legal circularity, deliberate: Parser interface-uses THIS unit (for
  // TPasPreprocessed), and CondEval implementation-uses Parser - the `$IF`
  // grammar is the language's own expression grammar, parsed by the one
  // real parser instead of a private re-implementation. Only the EVALUATION
  // lives in CondEval; see its unit comment.
  PasTree.CondEval;

const
  MAX_INCLUDE_DEPTH = 32;

type
  { Case-insensitive comparer for the defines dictionary: hashes and compares
    without allocating, where the previous scheme paid a LowerCase(Trim(...))
    copy on EVERY Define/Undefine/IsDefined - i.e. per `$IFDEF` / `Defined()`
    evaluation across the whole closure. The fold is PasFoldChar, the
    identifiers' (audit E2-27, B2-09). }
  TDefinesNameComparer = class(TEqualityComparer<string>)
  public
    function Equals(const Left, Right: string): Boolean; overload; override;
    function GetHashCode(const Value: string): Integer; overload; override;
  end;

var
  GDefinesComparer: IEqualityComparer<string>;

function TDefinesNameComparer.Equals(const Left, Right: string): Boolean;
begin
  Result := PasSameName(Left, Right);
end;

{ WRAPAROUND IS THE ALGORITHM, so the overflow check is turned off HERE rather
  than left to whoever compiles this unit. FNV-1a multiplies by 16777619 and
  keeps the low 32 bits; under $Q+ every one of those multiplications raises
  EIntOverflow instead. The same applies to the two sibling hashes, in
  PasTree.Sema.Model (SourceFingerprint) and PasTree.Sema.Project
  (TSemaInstanceComparer.GetHashCode).

  NOT THEORETICAL, and the reason it is spelled out three times rather than
  assumed: this library is compiled by whatever project links it, and RAD
  Studio's stock Debug configuration turns integer overflow checking ON. On
  2026-09-02 that produced an EAccessViolation with no visible cause in an LSP
  server built from the IDE, while the same sources built by the reference
  script were fine - the raise landed inside TPasSemaProject.Create, and the
  destructor of the half-built object then faulted on top of it and hid the
  real exception entirely. A library must not depend on its host's switches. }
{$IFOPT Q+}{$DEFINE PT_RESTORE_Q}{$OVERFLOWCHECKS OFF}{$ENDIF}
function TDefinesNameComparer.GetHashCode(const Value: string): Integer;
var
  LIdx: Integer;
  LHash: Cardinal;
begin
  // FNV-1a over PasFoldChar-folded UTF-16 code units: dcc folds a
  // conditional symbol as an identifier (local/probe-b65 D, DF1-DF5).
  LHash := 2166136261;
  for LIdx := 1 to Length(Value) do
    LHash := (LHash xor Ord(PasFoldChar(Value[LIdx]))) * 16777619;
  Result := Integer(LHash);
end;
{$IFDEF PT_RESTORE_Q}{$OVERFLOWCHECKS ON}{$UNDEF PT_RESTORE_Q}{$ENDIF}

{ Directive text helpers ---------------------------------------------------- }

type
  // Every directive HandleDirective dispatches on by NAME. pdSwitch is any
  // single-letter word except I (which is {$I file} or the {$I+}/{$I-} switch,
  // told apart by its argument); pdLong is every other multi-letter word -
  // the tracked long switches and passthrough trivia alike.
  TPPDirKind = (pdLong, pdSwitch, pdIfdef, pdIfndef, pdIf, pdIfopt, pdElseif,
    pdElse, pdEndif, pdDefine, pdUndef, pdInclude, pdPushopt, pdPopopt);

// Classifies the directive word without materializing a string. AText/ALen is
// the word run ([A-Za-z]+) at the start of the directive body.
function ClassifyDirective(AText: PChar; ALen: Integer): TPPDirKind;
begin
  Result := pdLong;
  if ALen = 1 then
  begin
    if (AText^ = 'I') or (AText^ = 'i') then
      Exit(pdInclude);
    Exit(pdSwitch);
  end;
  case AText^ of
    'I', 'i':
      if SliceEqualsWord(AText, ALen, 'IF') then Exit(pdIf)
      else if SliceEqualsWord(AText, ALen, 'IFDEF') then Exit(pdIfdef)
      else if SliceEqualsWord(AText, ALen, 'IFNDEF') then Exit(pdIfndef)
      else if SliceEqualsWord(AText, ALen, 'IFOPT') then Exit(pdIfopt)
      else if SliceEqualsWord(AText, ALen, 'IFEND') then Exit(pdEndif)
      else if SliceEqualsWord(AText, ALen, 'INCLUDE') then Exit(pdInclude);
    'E', 'e':
      if SliceEqualsWord(AText, ALen, 'ENDIF') then Exit(pdEndif)
      else if SliceEqualsWord(AText, ALen, 'ELSE') then Exit(pdElse)
      else if SliceEqualsWord(AText, ALen, 'ELSEIF') then Exit(pdElseif);
    'D', 'd':
      if SliceEqualsWord(AText, ALen, 'DEFINE') then Exit(pdDefine);
    'U', 'u':
      if SliceEqualsWord(AText, ALen, 'UNDEF') then Exit(pdUndef);
    'P', 'p':
      if SliceEqualsWord(AText, ALen, 'PUSHOPT') then Exit(pdPushopt)
      else if SliceEqualsWord(AText, ALen, 'POPOPT') then Exit(pdPopopt);
  end;
end;

const
  cLongSwitchNames: array[TPasPreprocessor.TLongSwitch] of string = ('',
    'RANGECHECKS', 'OVERFLOWCHECKS', 'IOCHECKS', 'OPTIMIZATION', 'BOOLEVAL',
    'WRITEABLECONST', 'TYPEDADDRESS', 'EXTENDEDSYNTAX', 'LONGSTRINGS',
    'STACKFRAMES', 'SAFEDIVIDE', 'OPENSTRINGS', 'ASSERTIONS', 'DEBUGINFO',
    'LOCALSYMBOLS', 'REFERENCEINFO', 'TYPEINFO', 'DEFINITIONINFO',
    'STACKCHECKS', 'YD', 'APPTYPE', 'IMPORTEDDATA', 'VARSTRINGCHECKS',
    'SCOPEDENUMS', 'RTTI', 'MINENUMSIZE', 'ALIGN', 'VARPROPSETTER');

// The long switch the word AText/ALen names (any case), lsNone for any other
// - a length test first, so a passthrough word builds no string and compares
// characters only against the few names of its length.
function ClassifyLongSwitch(AText: PChar; ALen: Integer)
  : TPasPreprocessor.TLongSwitch;
begin
  for Result := Succ(lsNone) to High(Result) do
    if (Length(cLongSwitchNames[Result]) = ALen) and
      SliceEqualsWord(AText, ALen, cLongSwitchNames[Result]) then
      Exit;
  Result := lsNone;
end;

{ TPasPreprocessed ----------------------------------------------------------- }

function TPasPreprocessed.VisibleToken(AIndex: Integer): TPasToken;
begin
  Result := Files[Visible[AIndex].FileId].Tokens[Visible[AIndex].TokenIndex];
end;

function TPasPreprocessed.VisibleText(AIndex: Integer): string;
begin
  Result := Files[Visible[AIndex].FileId].TokenText(
    Files[Visible[AIndex].FileId].Tokens[Visible[AIndex].TokenIndex]);
end;

function TPasPreprocessed.VisibleTextEquals(AIndex: Integer;
  const AWord: string): Boolean;
var
  LText: PChar;
  LLen: Integer;
begin
  VisibleSlice(AIndex, LText, LLen);
  Result := SliceEqualsWord(LText, LLen, AWord);
end;

procedure TPasPreprocessed.VisibleSlice(AIndex: Integer; out AText: PChar;
  out ALen: Integer);
var
  LFileId, LTokIdx: Integer;
begin
  LFileId := Visible[AIndex].FileId;
  LTokIdx := Visible[AIndex].TokenIndex;
  // Pointer() keeps the string field's refcount untouched; the slice is only
  // valid while this record (and its Files) stay alive, which every caller
  // guarantees by holding the TPasPreprocessed itself.
  AText := PChar(Pointer(Files[LFileId].Source)) +
    Files[LFileId].Tokens[LTokIdx].Start;
  ALen := Files[LFileId].Tokens[LTokIdx].Len;
end;

function TPasPreprocessed.IsSkipped(AFileId, AOffset: Integer): Boolean;
var
  LLo, LHi, LMid: Integer;
begin
  Result := False;
  if (AFileId < 0) or (AFileId > High(Skipped)) then
    Exit;
  LLo := 0;
  LHi := High(Skipped[AFileId]);
  while LLo <= LHi do
  begin
    LMid := (LLo + LHi) div 2;
    if AOffset < Skipped[AFileId][LMid].Start then
      LHi := LMid - 1
    else if AOffset >= Skipped[AFileId][LMid].EndPos then
      LLo := LMid + 1
    else
      Exit(True);
  end;
end;

function TPasPreprocessed.ScopedEnumsAt(AVisIndex: Integer): Boolean;
var
  LLo, LHi, LMid: Integer;
begin
  // Greatest event with VisIndex <= AVisIndex; none -> the OFF default.
  Result := False;
  LLo := 0;
  LHi := High(ScopedEnumsEvents);
  while LLo <= LHi do
  begin
    LMid := (LLo + LHi) div 2;
    if ScopedEnumsEvents[LMid].VisIndex <= AVisIndex then
    begin
      Result := ScopedEnumsEvents[LMid].Value;
      LLo := LMid + 1;
    end
    else
      LHi := LMid - 1;
  end;
end;

function TPasPreprocessed.MinEnumSizeAt(AVisIndex: Integer): Integer;
var
  LLo, LHi, LMid: Integer;
begin
  // Greatest event with VisIndex <= AVisIndex; none -> the {$Z1} default.
  Result := 1;
  LLo := 0;
  LHi := High(MinEnumEvents);
  while LLo <= LHi do
  begin
    LMid := (LLo + LHi) div 2;
    if MinEnumEvents[LMid].VisIndex <= AVisIndex then
    begin
      Result := MinEnumEvents[LMid].Bytes;
      LLo := LMid + 1;
    end
    else
      LHi := LMid - 1;
  end;
end;

function TPasPreprocessed.AppTypeBefore(AVisIndex: Integer;
  out AConsole: Boolean): Boolean;
var
  LIdx: Integer;
begin
  AConsole := False;
  for LIdx := High(AppTypeEvents) downto 0 do
    if AppTypeEvents[LIdx].VisIndex <= AVisIndex then
    begin
      AConsole := AppTypeEvents[LIdx].Console;
      Exit(True);
    end;
  Result := False;
end;

function TPasPreprocessed.AlignAt(AVisIndex: Integer): Integer;
var
  LLo, LHi, LMid: Integer;
begin
  // Greatest event with VisIndex <= AVisIndex; none -> the {$A8} default.
  Result := 8;
  LLo := 0;
  LHi := High(AlignEvents);
  while LLo <= LHi do
  begin
    LMid := (LLo + LHi) div 2;
    if AlignEvents[LMid].VisIndex <= AVisIndex then
    begin
      Result := AlignEvents[LMid].Bytes;
      LLo := LMid + 1;
    end
    else
      LHi := LMid - 1;
  end;
end;

{ TPasSpellingPool ----------------------------------------------------------- }

// $Q-: the FNV wraparound IS the algorithm, and the checked test build
// compiles with $Q+ (as PasNameHash in PasTree.Sema.Model).
{$IFOPT Q+}{$DEFINE PT_RESTORE_Q}{$OVERFLOWCHECKS OFF}{$ENDIF}
function SpellingHash(AText: PChar; ALen: Integer): Cardinal;
var
  LIdx: Integer;
begin
  Result := 2166136261;
  for LIdx := 0 to ALen - 1 do
    Result := (Result xor Cardinal(Ord(AText[LIdx]))) * 16777619;
end;
{$IFDEF PT_RESTORE_Q}{$OVERFLOWCHECKS ON}{$UNDEF PT_RESTORE_Q}{$ENDIF}

procedure TPasSpellingPool.Grow;
var
  LOld: TArray<string>;
  LIdx, LSlot, LMask: Integer;
begin
  LOld := FSlots;
  FSlots := nil;
  if Length(LOld) = 0 then
    SetLength(FSlots, 64)
  else
    SetLength(FSlots, Length(LOld) * 2);
  LMask := High(FSlots);
  for LIdx := 0 to High(LOld) do
    if Pointer(LOld[LIdx]) <> nil then
    begin
      LSlot := Integer(SpellingHash(PChar(Pointer(LOld[LIdx])),
        Length(LOld[LIdx])) and Cardinal(LMask));
      while Pointer(FSlots[LSlot]) <> nil do
        LSlot := (LSlot + 1) and LMask;
      FSlots[LSlot] := LOld[LIdx];
    end;
end;

function TPasSpellingPool.Intern(AText: PChar; ALen: Integer): string;
var
  LSlot, LMask: Integer;
begin
  if ALen <= 0 then
    Exit('');
  if FCount * 2 >= Length(FSlots) then
    Grow;
  LMask := High(FSlots);
  LSlot := Integer(SpellingHash(AText, ALen) and Cardinal(LMask));
  while Pointer(FSlots[LSlot]) <> nil do
  begin
    if (Length(FSlots[LSlot]) = ALen) and
       CompareMem(Pointer(FSlots[LSlot]), AText, ALen * SizeOf(Char)) then
      Exit(FSlots[LSlot]);
    LSlot := (LSlot + 1) and LMask;
  end;
  SetString(Result, AText, ALen);
  FSlots[LSlot] := Result;
  Inc(FCount);
end;

{ TPasDefines ---------------------------------------------------------------- }

constructor TPasDefines.Create;
begin
  inherited Create;
  FMap := TDictionary<string, Boolean>.Create(GDefinesComparer);
end;

constructor TPasDefines.Create(ACapacity: Integer);
begin
  inherited Create;
  FMap := TDictionary<string, Boolean>.Create(ACapacity, GDefinesComparer);
end;

constructor TPasDefines.Create(const ANames: array of string);
var
  LName: string;
begin
  Create;
  for LName in ANames do
    Define(LName);
end;

destructor TPasDefines.Destroy;
begin
  FMap.Free;
  inherited;
end;

// Trim only: the comparer folds case at hash/compare time, so no lowered
// copy is materialized (and Trim itself returns the SAME string, refcount
// bump only, when there is nothing to trim - the overwhelmingly common case).
procedure TPasDefines.Define(const AName: string);
begin
  FMap.AddOrSetValue(Trim(AName), True);
end;

procedure TPasDefines.Undefine(const AName: string);
begin
  FMap.Remove(Trim(AName));
end;

function TPasDefines.IsDefined(const AName: string): Boolean;
begin
  Result := FMap.ContainsKey(Trim(AName));
end;

// Names and Clone enumerate the dictionary itself, never FMap.Keys: the RTL
// creates the Keys collection lazily, writing a field of the dictionary
// without a lock, and a base define set is cloned by many preprocessors at
// once (TPasProject.ParseFiles) - each losing creation leaked a collection.
// The pair enumerator is a fresh object per loop and writes nothing shared.

function TPasDefines.Names: TArray<string>;
var
  LIdx: Integer;
begin
  SetLength(Result, FMap.Count);
  LIdx := 0;
  for var LPair in FMap do
  begin
    Result[LIdx] := LPair.Key;
    Inc(LIdx);
  end;
  TArray.Sort<string>(Result, TIStringComparer.Ordinal);
end;

function TPasDefines.Clone: TPasDefines;
begin
  // Pre-sized: this runs once per FILE (defines are unit-local), and growing
  // through rehashes cost more than the clone itself.
  Result := TPasDefines.Create(FMap.Count);
  for var LPair in FMap do
    Result.FMap.Add(LPair.Key, True);
end;

{ TPasPreprocessor ----------------------------------------------------------- }

constructor TPasPreprocessor.Create(ASourceManager: TPasSourceManager;
  ADefines: TPasDefines; ACompilerVersion: Double;
  APointerBytes: Integer; AExtendedBytes: Integer; ALongBytes: Integer;
  AExtendedAlign: Integer);
begin
  inherited Create;
  FSourceManager := ASourceManager;
  FBaseDefines := ADefines;
  FCompilerVersion := ACompilerVersion;
  FTarget := PasBuiltinTargetOf(APointerBytes, AExtendedBytes, AExtendedAlign,
    ALongBytes);
  FSwitchStack := TStack<TPasOptState>.Create;
  FOptionRefs := TList<TPasOptionRef>.Create;
  FScopedEnumsEvents := TList<TPasScopedEnumsEvent>.Create;
  FMinEnumEvents := TList<TPasMinEnumEvent>.Create;
  FAlignEvents := TList<TPasAlignEvent>.Create;
  FDefineRefs := TList<TPasDefineRef>.Create;
  FIncludeRefs := TList<TPasIncludeRef>.Create;
  FIfNameRefs := TList<TPasIfNameRef>.Create;
  FFileNames := TList<string>.Create;
  FFiles := TList<TPasTokenStream>.Create;
  FVisible := TList<TPasVisibleToken>.Create;
  FSkipped := TObjectList<TList<TPasSkippedRegion>>.Create(True);
  FDeadDirectives := TObjectList<TList<TPasSkippedRegion>>.Create(True);
  FDiags := TList<TPasPPDiagnostic>.Create;
  FIncludePathStack := TList<string>.Create;
  FUnresolvedDeclared := TList<string>.Create;
  FDeclaredAsks := TList<TPasDeclaredAsk>.Create;
  FUnresolvedSymbols := TList<TPasUnresolvedSymbol>.Create;
  FCondParentActive := TList<Boolean>.Create;
  FCondAnyTaken := TList<Boolean>.Create;
  FCondThisActive := TList<Boolean>.Create;
  FCondSeenElse := TList<Boolean>.Create;
  FCondOpener := TList<TPasIncludeRef>.Create;
  FAppTypeEvents := TList<TPasAppTypeEvent>.Create;
  FStartState := PasStartOptState([]);
  ResetSwitches;
end;

procedure TPasPreprocessor.SetProgramDefines(const AFile: string;
  ADefines: TPasDefines);
begin
  FProgramFile := AFile;
  FProgramDefines := ADefines;
end;

function TPasPreprocessor.SwitchState(ASwitch: Char): Boolean;
begin
  Result := FSwitches[UpCase(ASwitch)];
end;

function TPasPreprocessor.ScopedEnumsFinal: Boolean;
begin
  Result := FScopedEnums;
end;

function TPasPreprocessor.RttiState: TPasRttiState;
begin
  Result := FRttiState;
end;

function TPasPreprocessor.VarPropSetterFinal: Boolean;
begin
  Result := FVarPropSetter;
end;

procedure TPasPreprocessor.ResetSwitches;
begin
  // Re-applied per processed file: switch changes are unit-local, like
  // defines. The start is the host's (StartState), dcc's no-config state by
  // default - see PasStartOptState.
  FSwitches := FStartState.Switches;
end;

// dcc's no-config start state, the same on every dcc 37.0 target (probed
// with $IFOPT over A..Z: A C D G H I L N O P V X Y on).
function NoConfigOptState: TPasOptState;
var
  LCh: Char;
begin
  Result := Default(TPasOptState);
  for LCh := 'A' to 'Z' do
    Result.Switches[LCh] := False;
  Result.Switches['A'] := True;   // field alignment: the default IS {$A8}, so '+'
  Result.Switches['C'] := True;   // assertions
  Result.Switches['D'] := True;   // debug info
  Result.Switches['G'] := True;   // imported data
  Result.Switches['H'] := True;   // long strings
  Result.Switches['I'] := True;   // I/O checking
  Result.Switches['L'] := True;   // local symbols
  Result.Switches['N'] := True;   // numeric coprocessor (obsolete, still N+)
  Result.Switches['O'] := True;   // optimization
  Result.Switches['P'] := True;   // open strings
  Result.Switches['V'] := True;   // var-string checks
  Result.Switches['X'] := True;   // extended syntax
  Result.Switches['Y'] := True;   // symbol reference info
  Result.MinEnumSize := 1;        // {$Z1}
  Result.Align := 8;              // {$A8}
end;

// One group of single-letter switches - `X+`, `X-`, `X+,Y-`, `Zn`, `An`,
// `Dn`, `YD` - applied to AState, the one reader of an in-file `{$...}`
// switch and of a command-line `-$...` (PasStartOptState). Anything else
// (`R *.res`) ends the group with no state to track. ATouched gains each
// letter the group wrote (TPasOptionRef).
procedure ApplySwitchText(var AState: TPasOptState; const ABody: string;
  var ATouched: TPasOptions);

  procedure SkipSeparators(var AIdx: Integer);
  begin
    // Comma-separated list: {$O+,W-}
    while (AIdx <= Length(ABody)) and CharInSet(ABody[AIdx], [',', ' ', #9]) do
      Inc(AIdx);
  end;

var
  LIdx: Integer;
  LSwitch: Char;
begin
  LIdx := 1;
  while LIdx < Length(ABody) do
  begin
    if not CharInSet(ABody[LIdx], ['A'..'Z', 'a'..'z']) then
      Exit;
    LSwitch := UpCase(ABody[LIdx]);
    if CharInSet(ABody[LIdx + 1], ['+', '-']) then
    begin
      AState.Switches[LSwitch] := ABody[LIdx + 1] = '+';
      Include(ATouched, TPasOption(Ord(LSwitch) - Ord('A')));
      // {$Z+} is {$Z4} and {$Z-} is {$Z1} - dcc's own equivalences; the
      // boolean table above keeps its generic entry ($IFOPT Z reads it),
      // the SIZE is what SizeOf-of-an-enum needs.
      if LSwitch = 'Z' then
        if ABody[LIdx + 1] = '+' then
          AState.MinEnumSize := 4
        else
          AState.MinEnumSize := 1;
      // {$A+} is {$A8} and {$A-} is {$A1}, the same shape one switch over.
      if LSwitch = 'A' then
        if ABody[LIdx + 1] = '+' then
          AState.Align := 8
        else
          AState.Align := 1;
      LIdx := LIdx + 2;
      SkipSeparators(LIdx);
    end
    else if (LSwitch = 'Z') and CharInSet(ABody[LIdx + 1], ['1', '2', '4']) then
    begin
      // {$Z1/2/4}: minimum enum size, tracked positionally (see
      // TPasMinEnumEvent). $IFOPT Z+ is any size above 1.
      AState.MinEnumSize := Ord(ABody[LIdx + 1]) - Ord('0');
      AState.Switches['Z'] := AState.MinEnumSize > 1;
      Include(ATouched, optZ);
      LIdx := LIdx + 2;
      SkipSeparators(LIdx);
    end
    else if (LSwitch = 'A') and
            CharInSet(ABody[LIdx + 1], ['1', '2', '4', '8']) then
    begin
      // {$A1/2/4/8/16}: the record field-alignment cap, tracked positionally
      // (see TPasAlignEvent). Two digits only for 16, and 16 caps nothing a
      // builtin can exceed - it lands on the same layout as 8, but it is
      // recorded as written rather than normalized. $IFOPT A+ is any cap
      // above 1.
      if (ABody[LIdx + 1] = '1') and (LIdx + 2 <= Length(ABody)) and
         (ABody[LIdx + 2] = '6') then
      begin
        AState.Align := 16;
        LIdx := LIdx + 3;
      end
      else
      begin
        AState.Align := Ord(ABody[LIdx + 1]) - Ord('0');
        LIdx := LIdx + 2;
      end;
      AState.Switches['A'] := AState.Align > 1;
      Include(ATouched, optA);
      SkipSeparators(LIdx);
    end
    else if (LSwitch = 'D') and CharInSet(ABody[LIdx + 1], ['0', '1', '2']) then
    begin
      // {$D0} is D-, {$D1} and {$D2} D+ (dcc64 37.0; the .dproj's
      // DCC_DebugInformation 0 reaches dcc as -$D0). The group goes on.
      AState.Switches['D'] := ABody[LIdx + 1] <> '0';
      Include(ATouched, optD);
      LIdx := LIdx + 2;
      SkipSeparators(LIdx);
    end
    else if (LSwitch = 'Y') and CharInSet(ABody[LIdx + 1], ['D', 'd']) then
    begin
      // {$YD}, definitions only, is Y+ to $IFOPT - and dcc reads nothing of
      // the group after it: `{$R-}{$YD,R+}` leaves R- (dcc64 37.0).
      AState.Switches['Y'] := True;
      Include(ATouched, optY);
      Exit;
    end
    else
      Exit; // {$R *.res} etc. - no state to track
  end;
end;

function PasStartOptState(const ASwitches: array of string): TPasOptState;
var
  LArg: string;
  LTouched: TPasOptions;
begin
  Result := NoConfigOptState;
  LTouched := [];
  for LArg in ASwitches do
    if LArg.StartsWith('-$') then
      ApplySwitchText(Result, Copy(LArg, 3, MaxInt), LTouched)
    else if LArg.StartsWith('$') then
      ApplySwitchText(Result, Copy(LArg, 2, MaxInt), LTouched)
    else
      ApplySwitchText(Result, LArg, LTouched);
end;

function PasOptionValue(const AState: TPasOptState;
  AOption: TPasOption): string;

  function OnOff(AValue: Boolean): string;
  begin
    if AValue then
      Result := 'ON'
    else
      Result := 'OFF';
  end;

  function Clause(const AName: string; AHas: Boolean;
    AVis: TPasRttiVisibilitySet): string;
  const
    CVis: array[TPasRttiVisibility] of string =
      ('vcPrivate', 'vcProtected', 'vcPublic', 'vcPublished');
  var
    LVis: TPasRttiVisibility;
    LList: string;
  begin
    Result := '';
    if not AHas then
      Exit;
    LList := '';
    for LVis := Low(TPasRttiVisibility) to High(TPasRttiVisibility) do
      if LVis in AVis then
      begin
        if LList <> '' then
          LList := LList + ',';
        LList := LList + CVis[LVis];
      end;
    Result := ' ' + AName + '([' + LList + '])';
  end;

begin
  case AOption of
    optA: Result := IntToStr(AState.Align);
    optZ: Result := IntToStr(AState.MinEnumSize);
    optScopedEnums: Result := OnOff(AState.ScopedEnums);
    optVarPropSetter: Result := OnOff(AState.VarPropSetter);
    optRtti:
      begin
        if AState.Rtti.Mode = rmInherit then
          Result := 'INHERIT'
        else
          Result := 'EXPLICIT';
        Result := Result +
          Clause('METHODS', AState.Rtti.HasMethods, AState.Rtti.Methods) +
          Clause('FIELDS', AState.Rtti.HasFields, AState.Rtti.Fields) +
          Clause('PROPERTIES', AState.Rtti.HasProperties,
            AState.Rtti.Properties);
      end;
  else
    Result := OnOff(AState.Switches[Char(Ord('A') + Ord(AOption))]);
  end;
end;

destructor TPasPreprocessor.Destroy;
begin
  FDefines.Free;   // the per-run clone; FBaseDefines is caller-owned
  FCondOpener.Free;
  FCondSeenElse.Free;
  FCondThisActive.Free;
  FCondAnyTaken.Free;
  FCondParentActive.Free;
  FIncludePathStack.Free;
  FUnresolvedDeclared.Free;
  FDeclaredAsks.Free;
  FUnresolvedSymbols.Free;
  FDiags.Free;
  FDeadDirectives.Free;
  FSkipped.Free;
  FVisible.Free;
  FFiles.Free;
  FFileNames.Free;
  FScopedEnumsEvents.Free;
  FMinEnumEvents.Free;
  FAlignEvents.Free;
  FAppTypeEvents.Free;
  FDefineRefs.Free;
  FIncludeRefs.Free;
  FIfNameRefs.Free;
  FOptionRefs.Free;
  FSwitchStack.Free;
  inherited;
end;

function TPasPreprocessor.Active: Boolean;
begin
  Result := (FCondThisActive.Count = 0) or
    FCondThisActive[FCondThisActive.Count - 1];
end;

procedure TPasPreprocessor.Diag(ACode: TPasPPDiagCode; AFileId, AStart,
  ALen: Integer; const ADetail: string);
begin
  DiagUn(ACode, AFileId, AStart, ALen, ADetail, nil);
end;

procedure TPasPreprocessor.DiagUn(ACode: TPasPPDiagCode; AFileId, AStart,
  ALen: Integer; const ADetail: string;
  const AUnanswered: TArray<TPasUnresolvedSymbol>);
var
  LDiag: TPasPPDiagnostic;
begin
  LDiag.Code := ACode;
  LDiag.FileId := AFileId;
  LDiag.Start := AStart;
  LDiag.Len := ALen;
  LDiag.Detail := ADetail;
  LDiag.Unanswered := AUnanswered;
  FDiags.Add(LDiag);
end;

procedure TPasPreprocessor.MarkSkipped(AFileId, AStart, AEnd: Integer);
var
  LList: TList<TPasSkippedRegion>;
  LRegion: TPasSkippedRegion;
begin
  if AEnd <= AStart then
    Exit;
  LList := FSkipped[AFileId];
  // Merge with the previous region when adjacent/overlapping.
  if (LList.Count > 0) and (LList[LList.Count - 1].EndPos >= AStart) then
  begin
    LRegion := LList[LList.Count - 1];
    if AEnd > LRegion.EndPos then
    begin
      LRegion.EndPos := AEnd;
      LList[LList.Count - 1] := LRegion;
    end;
  end
  else
  begin
    LRegion.Start := AStart;
    LRegion.EndPos := AEnd;
    LList.Add(LRegion);
  end;
end;

function TPasPreprocessor.Process(const AFileName: string): TPasPreprocessed;
begin
  Result := ProcessText(AFileName, FSourceManager.LoadText(AFileName));
end;

function TPasPreprocessor.ProcessText(const AFileName,
  ASource: string): TPasPreprocessed;
var
  LStream: TPasTokenStream;
  LIdx: Integer;
  LEof: TPasVisibleToken;
begin
  // Reset per-run state. $DEFINE/$UNDEF are LOCAL to the unit being
  // processed (matching dcc): work on a fresh clone of the project
  // defines, so one file's defines never leak into the next
  // (System.ObjAuto.pas mis-branched when an earlier unit's define
  // survived into its X64ASM chain).
  FDefines.Free;
  if (FProgramDefines <> nil) and SameText(AFileName, FProgramFile) then
    FDefines := FProgramDefines.Clone
  else
    FDefines := FBaseDefines.Clone;
  ResetSwitches;
  FFileNames.Clear;
  FFiles.Clear;
  // Count := 0, not Clear: Clear drops CAPACITY, and this instance is reused
  // across files (the project driver pools preprocessors) - a 100k-token unit
  // would otherwise re-grow the list through ~17 doublings every time.
  FVisible.Count := 0;
  FSkipped.Clear;
  FDeadDirectives.Clear;
  FDiags.Clear;
  FIncludePathStack.Clear;
  FUnresolvedDeclared.Clear;
  FDeclaredAsks.Clear;
  FUnresolvedSymbols.Clear;
  FCondParentActive.Clear;
  FCondAnyTaken.Clear;
  FCondThisActive.Clear;
  FCondSeenElse.Clear;
  FCondOpener.Clear;
  FCondBase := 0;
  FSwitchStack.Clear;
  FScopedEnums := False;         // dcc default; unit-local like the switches
  FScopedEnumsEvents.Clear;
  FMinEnumSize := 1;             // dcc default ({$Z1}); unit-local likewise
  FMinEnumEvents.Clear;
  FAlign := 8;                   // dcc default ({$A8}); unit-local likewise
  FAlignEvents.Clear;
  FDefineRefs.Clear;
  FIncludeRefs.Clear;
  FIfNameRefs.Clear;
  FOptionRefs.Clear;
  FRttiState := Default(TPasRttiState);   // Mode = rmInherit, the dcc default
  FVarPropSetter := False;                // dcc default: OFF (13.1.6)
  FAppTypeEvents.Clear;
  // The host's $A / $Z start (the project's -$A4, -$Z4): an event at the
  // first token when it is not dcc's default, so AlignAt / MinEnumSizeAt
  // answer it - the setters record only a change.
  SetMinEnumSize(FStartState.MinEnumSize);
  SetAlign(FStartState.Align);
  FLiveAsm := False;
  FLastVisKind := tkEndOfFile;
  FStopped := False;
  FStopPhase := 0;

  LStream := TPasLexer.Tokenize(ASource, FStopAtImpl);
  // Visible tokens <= the main file's raw tokens (trivia and skipped regions
  // only subtract; includes add, and then the list grows the ordinary way).
  if FVisible.Capacity < Length(LStream.Tokens) then
    FVisible.Capacity := Length(LStream.Tokens);
  FFileNames.Add(AFileName);
  FFiles.Add(LStream);
  FSkipped.Add(TList<TPasSkippedRegion>.Create);
  FDeadDirectives.Add(TList<TPasSkippedRegion>.Create);
  FIncludePathStack.Add(LowerCase(AFileName));
  try
    ProcessFile(0);
  finally
    FIncludePathStack.Clear;
  end;

  // An entry an include opened was diagnosed at that include's end. A run
  // that stopped at the implementation has no end to judge it by.
  if not FStopped then
  for LIdx := 0 to FCondOpener.Count - 1 do
    if FCondOpener[LIdx].FileId = 0 then
    begin
      Diag(ppUnterminatedConditional, 0, Length(LStream.Source), 0);
      Break;
    end;

  // Terminate the visible stream with the main file's EOF sentinel.
  LEof.FileId := 0;
  LEof.TokenIndex := High(FFiles[0].Tokens);
  FVisible.Add(LEof);

  Result.FileNames := FFileNames.ToArray;
  Result.Files := FFiles.ToArray;
  Result.Visible := FVisible.ToArray;
  Result.Diagnostics := FDiags.ToArray;
  Result.ScopedEnumsEvents := FScopedEnumsEvents.ToArray;
  Result.UnresolvedDeclared := FUnresolvedDeclared.ToArray;
  Result.DeclaredAsks := FDeclaredAsks.ToArray;
  Result.UnresolvedSymbols := FUnresolvedSymbols.ToArray;
  Result.MinEnumEvents := FMinEnumEvents.ToArray;
  Result.AlignEvents := FAlignEvents.ToArray;
  Result.AppTypeEvents := FAppTypeEvents.ToArray;
  Result.DefineRefs := FDefineRefs.ToArray;
  Result.IncludeRefs := FIncludeRefs.ToArray;
  Result.IfNameRefs := FIfNameRefs.ToArray;
  Result.OptionRefs := FOptionRefs.ToArray;
  SetLength(Result.Skipped, FSkipped.Count);
  for LIdx := 0 to FSkipped.Count - 1 do
    Result.Skipped[LIdx] := FSkipped[LIdx].ToArray;
  SetLength(Result.DeadDirectives, FDeadDirectives.Count);
  for LIdx := 0 to FDeadDirectives.Count - 1 do
    Result.DeadDirectives[LIdx] := FDeadDirectives[LIdx].ToArray;
end;

// Where an asm body ends is the preprocessor's to say (F26; dcc32 37.0,
// probes of 2026-09-29): only LIVE text switches the mode - a live `asm`
// opens BASM mode, a live `end` in it closes it, a dead `asm` or a dead
// `end` does neither - and dead text is always scanned as Pascal, inside an
// asm body too (a dead `cmp al, "{"` there opens a comment that swallows
// the $ENDIF after it, dcc's E2280). The mode runs on through include
// boundaries: an include inside an asm body is BASM text, and an `end` in
// it closes the body. The file's stream came from TPasLexer.Tokenize, which
// had to guess; each token's mode (tfAsm) is checked against the one these
// rules want, and from the first that disagrees the rest of the file is
// lexed again, token by token, in the mode wanted at each step - into a
// stream of this unit's own (an include's stream is shared).
procedure TPasPreprocessor.ProcessFile(AFileId: Integer);
var
  LTokens: TArray<TPasToken>;
  LTok: TPasToken;
  LIdx: Integer;
  LVis: TPasVisibleToken;
  LSkipStart: Integer;
  LLexer: TPasLexer;
  LPull, LWantAsm: Boolean;
begin
  LTokens := FFiles[AFileId].Tokens;
  LSkipStart := -1;
  LPull := False;
  LIdx := 0;
  while True do
  begin
    // StopAtImplementation: this file, or an include it opened, stopped.
    if FStopped then
      Break;
    LWantAsm := FLiveAsm and Active;
    if LPull then
    begin
      if LIdx = LLexer.Count then
      begin
        if LLexer.AtEnd then
          Break;
        LLexer.Step(LWantAsm);
      end;
      LTok := LLexer.Token(LIdx);
    end
    else
    begin
      if LIdx > High(LTokens) then
        Break;
      LTok := LTokens[LIdx];
      if (LTok.Kind <> tkEndOfFile) and ((tfAsm in LTok.Flags) <> LWantAsm)
      then
      begin
        LLexer.Resume(FFiles[AFileId], LIdx);
        LPull := True;
        Continue;
      end;
    end;
    case LTok.Kind of
      tkDirective:
        begin
          // Close a pending skipped region before the directive; the
          // directive itself is never part of a skipped span (it may be
          // the one that reactivates output).
          if LSkipStart >= 0 then
          begin
            MarkSkipped(AFileId, LSkipStart, LTok.Start);
            LSkipStart := -1;
          end;
          HandleDirective(AFileId, LTok);
          if not Active then
            LSkipStart := LTok.EndPos;
        end;
      tkEndOfFile:
        // The resume rule (see StopAtImplementation): the lexer stopped at
        // an `implementation` this run has not stopped at - a dead one, or
        // the live one whose `uses` clause is still to come. Lex on, in pull
        // mode, from the end of the truncated stream.
        if FStopAtImpl and not LPull and FFiles[AFileId].Truncated then
        begin
          LLexer.Resume(FFiles[AFileId], LIdx);
          LPull := True;
          Continue;
        end;
        // else handled by Process for the main file
    else
      if Active then
      begin
        if not IsTrivia(LTok.Kind) then
        begin
          // StopAtImplementation: a live `implementation` and then its
          // `uses` clause to its `;`; anything else after the keyword ends
          // the run before it is added.
          if FStopAtImpl then
            case FStopPhase of
              0:
                if LTok.Kind = tkImplementation then
                  FStopPhase := 1;
              1:
                if LTok.Kind = tkUses then
                  FStopPhase := 2
                else
                begin
                  FStopped := True;
                  Break;
                end;
            end;
          LVis.FileId := AFileId;
          LVis.TokenIndex := LIdx;
          FVisible.Add(LVis);
          if FLiveAsm then
            FLiveAsm := LTok.Kind <> tkEnd
          else
            FLiveAsm := (LTok.Kind = tkAsm) and (FLastVisKind <> tkDot);
          FLastVisKind := LTok.Kind;
          if (FStopPhase = 2) and (LTok.Kind = tkSemicolon) then
          begin
            FStopped := True;
            Break;
          end;
        end;
      end
      else if LSkipStart < 0 then
        LSkipStart := LTok.Start;
    end;
    Inc(LIdx);
  end;
  // The main file ends here once its includes are done: an asm body still
  // open is unterminated. An include may end inside one (the includer
  // closes it).
  if LPull then
    FFiles[AFileId] := LLexer.Finish((AFileId = 0) and FLiveAsm and
      not FStopped);
  if LSkipStart >= 0 then
    MarkSkipped(AFileId, LSkipStart, Length(FFiles[AFileId].Source));
end;

procedure TPasPreprocessor.HandleDirective(AFileId: Integer;
  const AToken: TPasToken);
var
  LText: PChar;
  LLen, LNameLen: Integer;
  LKind: TPPDirKind;
  LLong: TLongSwitch;
  LBody, LArg: string;
  LParent, LTaken: Boolean;
  LTop: Integer;
  LSwitch: Char;
  LWant: Boolean;
  LDead: TPasSkippedRegion;
  // File offset of Arg's / SymbolArg's first character, set by each call -
  // the DefineRefs need the name in file coordinates.
  LArgStart, LSymLen: Integer;

  // The argument after the name run, left-trimmed (the right edge was trimmed
  // with the body) - materialized ONLY by the branches that consume one.
  function Arg: string;
  var
    LP: PChar;
    LN: Integer;
  begin
    LP := LText + LNameLen;
    LN := LLen - LNameLen;
    while (LN > 0) and (LP^ <= ' ') do
    begin
      Inc(LP);
      Dec(LN);
    end;
    LArgStart := LP - PChar(Pointer(FFiles[AFileId].Source));
    SetString(Result, LP, LN);
  end;

  // Records the symbol SymbolArg just isolated (LArgStart/LSymLen) as one
  // TPasDefineRef. Nothing is recorded for an empty name (`{$IFDEF}`).
  procedure AddSymbolRef(const AName: string; AKind: TPasDefineRefKind;
    AActive: Boolean);
  var
    LRef: TPasDefineRef;
  begin
    if LSymLen = 0 then
      Exit;
    LRef.FileId := AFileId;
    LRef.Start := LArgStart;
    LRef.Len := LSymLen;
    LRef.Name := AName;
    LRef.Kind := AKind;
    LRef.Active := AActive;
    FDefineRefs.Add(LRef);
  end;

  // The SYMBOL a $IFDEF/$IFNDEF/$DEFINE/$UNDEF names: the leading identifier
  // of the argument, whatever follows it ignored - dcc-probed (35.0 and 37.0
  // agree): `{$ifdef CPU386)}` tests CPU386, `{$define FOO BAR}` defines FOO
  // only. Delphi 11's getmem.inc ships the stray paren, and reading the whole
  // argument as the name put Win32 on the Win64 branch (Move8 undeclared).
  function SymbolArg: string;
  var
    LP: PChar;
    LN, LIdent: Integer;
  begin
    LP := LText + LNameLen;
    LN := LLen - LNameLen;
    while (LN > 0) and (LP^ <= ' ') do
    begin
      Inc(LP);
      Dec(LN);
    end;
    // dcc's identifier characters (PasIsIdentChar): a name starting with
    // A-umlaut is that name, where the ASCII scan read the empty name and
    // every non-ASCII IFDEF was true (dcc64 37.0, local/probe-b57 D1).
    LIdent := 0;
    while (LIdent < LN) and PasIsIdentChar(LP[LIdent]) do
      Inc(LIdent);
    LArgStart := LP - PChar(Pointer(FFiles[AFileId].Source));
    LSymLen := LIdent;
    Result := FDefineNames.Intern(LP, LIdent);
  end;

begin
  // The directive body as a SLICE of the file source - this runs for every
  // {$...} token, including those inside skipped regions, and the old
  // TokenText -> DirectiveBody -> SplitDirective chain materialized four to
  // five strings per directive before a single branch was taken. Classify
  // from the slice; materialize only what the taken branch consumes.
  LText := PChar(Pointer(FFiles[AFileId].Source)) + AToken.Start;
  LLen := AToken.Len;
  if (LLen >= 2) and (LText^ = '{') then
  begin
    Inc(LText, 2);                            // '{$'
    Dec(LLen, 2);
    if (LLen >= 1) and (LText[LLen - 1] = '}') then
      Dec(LLen);
  end
  else if (LLen >= 3) and (LText^ = '(') then
  begin
    Inc(LText, 3);                            // '(*$'
    Dec(LLen, 3);
    if (LLen >= 2) and (LText[LLen - 2] = '*') and (LText[LLen - 1] = ')') then
      Dec(LLen, 2);
  end;
  while (LLen > 0) and (LText^ <= ' ') do     // Trim, both edges
  begin
    Inc(LText);
    Dec(LLen);
  end;
  while (LLen > 0) and (LText[LLen - 1] <= ' ') do
    Dec(LLen);
  LNameLen := 0;
  while (LNameLen < LLen) and
        (((LText[LNameLen] >= 'A') and (LText[LNameLen] <= 'Z')) or
         ((LText[LNameLen] >= 'a') and (LText[LNameLen] <= 'z'))) do
    Inc(LNameLen);
  LKind := ClassifyDirective(LText, LNameLen);

  // Is the directive itself dead code? See TPasPreprocessed.DeadDirectives.
  // Recorded here, before anything below can recurse into an include.
  LTop := FCondThisActive.Count - 1;
  if LKind in [pdElseif, pdElse, pdEndif] then
    LParent := (LTop < 0) or FCondParentActive[LTop]
  else
    LParent := Active;
  if not LParent then
  begin
    LDead.Start := AToken.Start;
    LDead.EndPos := AToken.Start + AToken.Len;
    FDeadDirectives[AFileId].Add(LDead);
  end;

  // ---- conditionals (always processed, active or not) ----
  if LKind = pdIfdef then
  begin
    LArg := SymbolArg;
    LParent := Active;
    AddSymbolRef(LArg, drIfdef, LParent);
    LTaken := LParent and FDefines.IsDefined(LArg);
    FCondParentActive.Add(LParent);
    FCondAnyTaken.Add(LTaken);
    FCondThisActive.Add(LTaken);
    FCondSeenElse.Add(False);
    AddCondOpener(AFileId, AToken);
  end
  else if LKind = pdIfndef then
  begin
    LArg := SymbolArg;
    LParent := Active;
    AddSymbolRef(LArg, drIfndef, LParent);
    LTaken := LParent and not FDefines.IsDefined(LArg);
    FCondParentActive.Add(LParent);
    FCondAnyTaken.Add(LTaken);
    FCondThisActive.Add(LTaken);
    FCondSeenElse.Add(False);
    AddCondOpener(AFileId, AToken);
  end
  else if LKind = pdIf then
  begin
    LParent := Active;
    LArg := Arg;
    if LParent then
      LTaken := EvalIfExpression(LArg, AFileId, LArgStart, LParent, AToken)
    else
    begin
      LTaken := False;
      RecordUnevaluatedIf(LArg, AFileId, LArgStart, LParent);
    end;
    FCondParentActive.Add(LParent);
    FCondAnyTaken.Add(LTaken);
    FCondThisActive.Add(LTaken);
    FCondSeenElse.Add(False);
    AddCondOpener(AFileId, AToken);
  end
  else if LKind = pdIfopt then
  begin
    LArg := Arg;
    LParent := Active;
    LTaken := False;
    if (Length(LArg) >= 2) and CharInSet(LArg[1], ['A'..'Z', 'a'..'z']) and
       CharInSet(LArg[2], ['+', '-']) then
    begin
      LSwitch := UpCase(LArg[1]);
      LWant := LArg[2] = '+';
      LTaken := LParent and (FSwitches[LSwitch] = LWant);
    end;
    FCondParentActive.Add(LParent);
    FCondAnyTaken.Add(LTaken);
    FCondThisActive.Add(LTaken);
    FCondSeenElse.Add(False);
    AddCondOpener(AFileId, AToken);
  end
  else if LKind = pdElseif then
  begin
    LTop := FCondThisActive.Count - 1;
    CheckCrossInclude(AFileId, AToken, LTop);
    if LTop < 0 then
      Diag(ppUnbalancedElse, AFileId, AToken.Start, AToken.Len)
    else if FCondSeenElse[LTop] then
      Diag(ppUnbalancedElse, AFileId, AToken.Start, AToken.Len)
    else
    begin
      LArg := Arg;
      if FCondParentActive[LTop] and not FCondAnyTaken[LTop] then
        LTaken := EvalIfExpression(LArg, AFileId, LArgStart,
          FCondParentActive[LTop], AToken)
      else
      begin
        LTaken := False;
        RecordUnevaluatedIf(LArg, AFileId, LArgStart, FCondParentActive[LTop]);
      end;
      FCondThisActive[LTop] := LTaken;
      if LTaken then
        FCondAnyTaken[LTop] := True;
    end;
  end
  else if LKind = pdElse then
  begin
    LTop := FCondThisActive.Count - 1;
    CheckCrossInclude(AFileId, AToken, LTop);
    if LTop < 0 then
      Diag(ppUnbalancedElse, AFileId, AToken.Start, AToken.Len)
    else
    begin
      // NB: dcc tolerates MULTIPLE $ELSE in one chain (System.ObjAuto.pas
      // ships `...{$ELSE}...{$ELSE OTHERCPU}...`). Each $ELSE activates
      // iff no earlier branch was taken - so we deliberately do NOT error
      // on a repeated $ELSE.
      FCondSeenElse[LTop] := True;
      FCondThisActive[LTop] :=
        FCondParentActive[LTop] and not FCondAnyTaken[LTop];
      if FCondThisActive[LTop] then
        FCondAnyTaken[LTop] := True;
    end;
  end
  else if LKind = pdEndif then
  begin
    LTop := FCondThisActive.Count - 1;
    CheckCrossInclude(AFileId, AToken, LTop);
    if LTop < 0 then
      Diag(ppUnbalancedEndif, AFileId, AToken.Start, AToken.Len)
    else
    begin
      FCondParentActive.Delete(LTop);
      FCondAnyTaken.Delete(LTop);
      FCondThisActive.Delete(LTop);
      FCondSeenElse.Delete(LTop);
      FCondOpener.Delete(LTop);
      if LTop < FCondBase then
        FCondBase := LTop;
    end;
  end
  // $DEFINE/$UNDEF are RECORDED whether active or not (a search must show a
  // dead branch's define, flagged) but APPLIED only in live code.
  else if LKind in [pdDefine, pdUndef] then
  begin
    LArg := SymbolArg;
    LParent := Active;
    if LKind = pdDefine then
      AddSymbolRef(LArg, drDefine, LParent)
    else
      AddSymbolRef(LArg, drUndef, LParent);
    if not LParent then
      // ignore
    else if LKind = pdDefine then
      FDefines.Define(LArg)
    else
      FDefines.Undefine(LArg);
  end
  // ---- everything below acts only in active regions ----
  else if not Active then
    // ignore
  else if LKind = pdInclude then
  begin
    LArg := Arg;
    if (LArg <> '') and CharInSet(LArg[1], ['+', '-']) then
    begin
      // {$I+} / {$I-}: the IOCHECKS switch, not an include. And it can HEAD A
      // GROUP - `{$I-,R+}` - so the remainder goes through the ordinary
      // switch parser instead of being dropped on the floor.
      FTouched := [optI];
      FSwitches['I'] := LArg[1] = '+';
      if Length(LArg) > 1 then
        ApplySwitches('I' + LArg);
      AddOptionRef(AFileId, AToken, orSet);
    end
    else
      // %DATE% too: dcc64 37.0 has no insertion form, {$I %DATE%} is
      // F1026 '%DATE%.pas' (local/probe-b63 misc PI) - a file name like any.
      HandleInclude(AFileId, AToken, LArg);
  end
  else if LKind = pdPushopt then
  begin
    FSwitchStack.Push(CurrentOptState);
    AddOptionRef(AFileId, AToken, orPush);
  end
  else if LKind = pdPopopt then
  begin
    if FSwitchStack.Count > 0 then
    begin
      var LOpt := FSwitchStack.Pop;
      FSwitches := LOpt.Switches;
      SetScopedEnums(LOpt.ScopedEnums);
      FRttiState := LOpt.Rtti;
      FVarPropSetter := LOpt.VarPropSetter;
      SetMinEnumSize(LOpt.MinEnumSize);
      SetAlign(LOpt.Align);
      AddOptionRef(AFileId, AToken, orPop);
    end
    else
      Diag(ppPopWithoutPush, AFileId, AToken.Start, AToken.Len);
  end
  else if LKind = pdSwitch then
  begin
    // Single-letter switch directive(s): {$R-}, {$O+,W-}, {$Z4}, {$R *.res}
    SetString(LBody, LText, LLen);
    FTouched := [];
    ApplySwitches(LBody);
    if FTouched <> [] then
      AddOptionRef(AFileId, AToken, orSet);
  end
  else
  begin
    // Long-form switches we track; everything else is passthrough trivia,
    // classified from the slice and dropped with no string built (audit
    // C1-05: about 100,000 EXTERNALSYM / REGION / HPPEMIT in RTL+VCL).
    LLong := ClassifyLongSwitch(LText, LNameLen);
    if LLong = lsNone then
      Exit;
    FTouched := [];
    ApplyLongSwitch(LLong, Arg);
    if FTouched <> [] then
      AddOptionRef(AFileId, AToken, orSet);
  end;
end;

function TPasPreprocessor.CurrentOptState: TPasOptState;
begin
  Result.Switches := FSwitches;
  Result.ScopedEnums := FScopedEnums;
  Result.Rtti := FRttiState;
  Result.VarPropSetter := FVarPropSetter;
  Result.MinEnumSize := FMinEnumSize;
  Result.Align := FAlign;
end;

procedure TPasPreprocessor.AddOptionRef(AFileId: Integer;
  const AToken: TPasToken; AKind: TPasOptionRefKind);
var
  LRef: TPasOptionRef;
begin
  LRef.FileId := AFileId;
  LRef.Start := AToken.Start;
  LRef.Len := AToken.Len;
  LRef.Kind := AKind;
  if AKind = orSet then
    LRef.Touched := FTouched
  else
    LRef.Touched := [];
  LRef.State := CurrentOptState;
  FOptionRefs.Add(LRef);
end;

procedure TPasPreprocessor.HandleInclude(AFileId: Integer;
  const AToken: TPasToken; const AArg: string);
var
  LResolved, LKey: string;
  LNewId, LRefIdx, LBase, LIdx: Integer;
  LFound: Boolean;
  LStream: TPasTokenStream;
  LRef: TPasIncludeRef;
begin
  // The site is recorded FIRST, whatever becomes of the file: a Go To list
  // shows the directive that is there, and a broken include is the one a
  // reader most wants to jump to. IncludedFileId is patched in below once
  // the file has an id.
  LRef.FileId := AFileId;
  LRef.Start := AToken.Start;
  LRef.Len := AToken.Len;
  LRef.Arg := AArg;
  LRef.Path := '';
  LRef.IncludedFileId := -1;
  LRef.VisIndex := FVisible.Count;
  LRefIdx := FIncludeRefs.Add(LRef);
  // Looked up beside the MAIN file (id 0), whichever file names it - dcc's
  // rule; the naming file is only the manager's last-resort tolerance. A
  // name the manager refuses is not found; a file-system raise past that
  // (a device name that exists and cannot be read) is too - dcc's F1026 at
  // the directive, never an exception that drops the whole unit.
  try
    LFound := FSourceManager.ResolveInclude(FFileNames[0],
      FFileNames[AFileId], AArg, LResolved);
  except
    on EInOutError do
      LFound := False;
    on EArgumentException do
      LFound := False;
  end;
  if not LFound then
  begin
    Diag(ppIncludeNotFound, AFileId, AToken.Start, AToken.Len, AArg);
    Exit;
  end;
  LRef.Path := LResolved;
  FIncludeRefs[LRefIdx] := LRef;
  LKey := LowerCase(LResolved);
  if FIncludePathStack.Contains(LKey) then
  begin
    Diag(ppIncludeCycle, AFileId, AToken.Start, AToken.Len, LResolved);
    Exit;
  end;
  if FIncludePathStack.Count >= MAX_INCLUDE_DEPTH then
  begin
    Diag(ppIncludeTooDeep, AFileId, AToken.Start, AToken.Len, LResolved);
    Exit;
  end;

  // Shared across includers (see TPasSourceManager.FIncludeStreams): the
  // stream is includer-independent; the per-includer conditional state only
  // decides which of its tokens land in THIS unit's Visible/Skipped.
  try
    LStream := FSourceManager.IncludeStream(LResolved);
  except
    on E: EInOutError do
    begin
      Diag(ppIncludeNotFound, AFileId, AToken.Start, AToken.Len, AArg);
      Exit;
    end;
    on E: EStreamError do
    begin
      Diag(ppIncludeNotFound, AFileId, AToken.Start, AToken.Len, AArg);
      Exit;
    end;
  end;
  FFileNames.Add(LResolved);
  FFiles.Add(LStream);
  FSkipped.Add(TList<TPasSkippedRegion>.Create);
  FDeadDirectives.Add(TList<TPasSkippedRegion>.Create);
  LNewId := FFiles.Count - 1;
  LRef.IncludedFileId := LNewId;
  FIncludeRefs[LRefIdx] := LRef;

  LBase := FCondBase;
  FCondBase := FCondThisActive.Count;
  FIncludePathStack.Add(LKey);
  try
    ProcessFile(LNewId);
  finally
    FIncludePathStack.Delete(FIncludePathStack.Count - 1);
  end;
  // A conditional the include opened and left open: dcc's E2280, at the
  // include (F22). It stays open here and the includer may close it. Not
  // after a stop inside the include (StopAtImplementation).
  if not FStopped then
  for LIdx := 0 to FCondOpener.Count - 1 do
    if FCondOpener[LIdx].FileId = LNewId then
      Diag(ppUnterminatedConditional, LNewId, FCondOpener[LIdx].Start,
        FCondOpener[LIdx].Len);
  if LBase < FCondThisActive.Count then
    FCondBase := LBase
  else
    FCondBase := FCondThisActive.Count;
end;

procedure TPasPreprocessor.AddCondOpener(AFileId: Integer;
  const AToken: TPasToken);
var
  LOpener: TPasIncludeRef;
begin
  LOpener := Default(TPasIncludeRef);
  LOpener.FileId := AFileId;
  LOpener.Start := AToken.Start;
  LOpener.Len := AToken.Len;
  FCondOpener.Add(LOpener);
end;

// An $ELSE/$ELSEIF/$ENDIF/$IFEND whose conditional (ATop) the includer of
// this file opened: dcc 37.0 never pairs a directive across an include
// boundary (F22). Acted on all the same - the tolerance of the unit header.
procedure TPasPreprocessor.CheckCrossInclude(AFileId: Integer;
  const AToken: TPasToken; ATop: Integer);
begin
  if (ATop >= 0) and (ATop < FCondBase) then
    Diag(ppCrossIncludeConditional, AFileId, AToken.Start, AToken.Len);
end;

procedure TPasPreprocessor.ApplySwitches(const ABody: string);
var
  LOpt: TPasOptState;
begin
  // One reader for the in-file switch and the command line (ApplySwitchText);
  // a changed $A / $Z goes through its setter, which records the event.
  LOpt := Default(TPasOptState);
  LOpt.Switches := FSwitches;
  LOpt.MinEnumSize := FMinEnumSize;
  LOpt.Align := FAlign;
  ApplySwitchText(LOpt, ABody, FTouched);
  FSwitches := LOpt.Switches;
  SetMinEnumSize(LOpt.MinEnumSize);
  SetAlign(LOpt.Align);
end;

procedure TPasPreprocessor.ApplyLongSwitch(AKind: TLongSwitch;
  const AArg: string);

  procedure SetSwitch(ALetter: Char);
  begin
    if SameText(AArg, 'ON') then
      FSwitches[ALetter] := True
    else if SameText(AArg, 'OFF') then
      FSwitches[ALetter] := False
    else
      Exit;
    Include(FTouched, TPasOption(Ord(ALetter) - Ord('A')));
  end;

begin
  if AKind = lsRangeChecks then SetSwitch('R')
  else if AKind = lsOverflowChecks then SetSwitch('Q')
  else if AKind = lsIOChecks then SetSwitch('I')
  else if AKind = lsOptimization then SetSwitch('O')
  else if AKind = lsBoolEval then SetSwitch('B')
  else if AKind = lsWriteableConst then SetSwitch('J')
  else if AKind = lsTypedAddress then SetSwitch('T')
  else if AKind = lsExtendedSyntax then SetSwitch('X')
  else if AKind = lsLongStrings then SetSwitch('H')
  else if AKind = lsStackFrames then SetSwitch('W')
  else if AKind = lsSafeDivide then SetSwitch('U')
  else if AKind = lsOpenStrings then SetSwitch('P')
  else if AKind = lsAssertions then SetSwitch('C')
  else if AKind = lsDebugInfo then SetSwitch('D')
  else if AKind = lsLocalSymbols then SetSwitch('L')
  else if AKind = lsReferenceInfo then SetSwitch('Y')
  // The long forms with no entry here before - dcc64 37.0 moves the letter
  // $IFOPT reads for each (local/probe-b62 T): TYPEINFO is $M (19.1.1),
  // DEFINITIONINFO is $YD, Y+ to $IFOPT, and its OFF is Y-; STACKCHECKS is
  // $S. A `{$IFOPT M+}` after `{$TYPEINFO ON}` took the other branch (audit
  // E2-17).
  else if AKind = lsTypeInfo then SetSwitch('M')
  else if AKind = lsDefinitionInfo then SetSwitch('Y')
  else if AKind = lsStackChecks then SetSwitch('S')
  // `{$YD}` is a two-letter word, so it is classified here, not as a
  // switch group; it is Y+ and ends the group (ApplySwitchText's rule).
  else if AKind = lsYD then
  begin
    FSwitches['Y'] := True;
    Include(FTouched, optY);
  end
  else if AKind = lsAppType then
  begin
    if SameText(AArg, 'CONSOLE') or SameText(AArg, 'GUI') then
    begin
      var LApp: TPasAppTypeEvent;
      LApp.VisIndex := FVisible.Count;
      LApp.Console := SameText(AArg, 'CONSOLE');
      FAppTypeEvents.Add(LApp);
    end;
  end
  else if AKind = lsImportedData then SetSwitch('G')
  else if AKind = lsVarStringChecks then SetSwitch('V')
  else if AKind = lsScopedEnums then
  begin
    // Long-form only (no single-letter twin). Positional: the resolver reads
    // the state at each enum's declaration site - see TPasScopedEnumsEvent.
    if SameText(AArg, 'ON') then
      SetScopedEnums(True)
    else if SameText(AArg, 'OFF') then
      SetScopedEnums(False)
    else
      Exit;
    Include(FTouched, optScopedEnums);
  end
  else if AKind = lsRtti then
  begin
    ApplyRtti(AArg);
    Include(FTouched, optRtti);
  end
  else if AKind = lsMinEnumSize then
  begin
    // The long form of {$Z1/2/4} (13.0 docs list both). Positional - see
    // TPasMinEnumEvent.
    if (Length(AArg) = 1) and CharInSet(AArg[1], ['1', '2', '4']) then
    begin
      SetMinEnumSize(Ord(AArg[1]) - Ord('0'));
      Include(FTouched, optZ);
    end;
  end
  else if AKind = lsAlign then
  begin
    // The long form of {$A1/2/4/8/16}, plus ON/OFF for {$A+}/{$A-}.
    // Positional - see TPasAlignEvent. dcc rejects any other value (E1030 on
    // `{$ALIGN 32}`), so an unrecognized argument changes nothing rather than
    // inventing a cap.
    if SameText(AArg, 'ON') then
      SetAlign(8)
    else if SameText(AArg, 'OFF') then
      SetAlign(1)
    else if (AArg = '1') or (AArg = '2') or (AArg = '4') or (AArg = '8') or
            (AArg = '16') then
      SetAlign(StrToInt(AArg))
    else
      Exit;
    Include(FTouched, optA);
  end
  else if AKind = lsVarPropSetter then
  begin
    // 13.1.6. Long-form-only ON/OFF like SCOPEDENUMS, but NOT positional:
    // nothing reads it per-declaration yet, because PasTree emits no E2282.
    if SameText(AArg, 'ON') then
      FVarPropSetter := True
    else if SameText(AArg, 'OFF') then
      FVarPropSetter := False
    else
      Exit;
    Include(FTouched, optVarPropSetter);
  end;
end;

// {$RTTI mode METHODS(set) FIELDS(set) PROPERTIES(set)} (19.2.1). Real
// grammar, not an ON/OFF flag -- AArg is everything after the word RTTI,
// e.g. 'EXPLICIT METHODS([vcPublic,vcPublished]) FIELDS([vcPrivate..vcPublic])'.
// A malformed clause simply stops the scan (leaving whatever was parsed so
// far) rather than raising a diagnostic -- this mirrors ApplySwitches'
// existing "no boolean state to track, just stop" tolerance, since a
// misparsed RTTI directive must never cascade into an unrelated E-code the
// way the brace-comment/`{$SCOPEDENUMS}` lesson (test-coverage-plan batch 5)
// warns about for directive text in general.
procedure TPasPreprocessor.ApplyRtti(const AArg: string);
var
  LPos: Integer;

  procedure SkipWs;
  begin
    while (LPos <= Length(AArg)) and CharInSet(AArg[LPos], [' ', #9]) do
      Inc(LPos);
  end;

  function ReadIdent: string;
  var
    LStart: Integer;
  begin
    SkipWs;
    LStart := LPos;
    while (LPos <= Length(AArg)) and
      CharInSet(AArg[LPos], ['A'..'Z', 'a'..'z']) do
      Inc(LPos);
    Result := UpperCase(Copy(AArg, LStart, LPos - LStart));
  end;

  function ReadVisibility(out AVis: TPasRttiVisibility): Boolean;
  var
    LName: string;
  begin
    LName := ReadIdent;
    if LName = 'VCPRIVATE' then AVis := rvPrivate
    else if LName = 'VCPROTECTED' then AVis := rvProtected
    else if LName = 'VCPUBLIC' then AVis := rvPublic
    else if LName = 'VCPUBLISHED' then AVis := rvPublished
    else Exit(False);
    Result := True;
  end;

  function ReadVisibilitySet(out ASet: TPasRttiVisibilitySet): Boolean;
  var
    LFrom, LTo, LV: TPasRttiVisibility;
  begin
    ASet := [];
    SkipWs;
    if (LPos > Length(AArg)) or (AArg[LPos] <> '[') then
      Exit(False);
    Inc(LPos); // '['
    SkipWs;
    while (LPos <= Length(AArg)) and (AArg[LPos] <> ']') do
    begin
      if not ReadVisibility(LFrom) then
        Exit(False);
      LTo := LFrom;
      SkipWs;
      if (LPos + 1 <= Length(AArg)) and (AArg[LPos] = '.') and
        (AArg[LPos + 1] = '.') then
      begin
        Inc(LPos, 2);
        if not ReadVisibility(LTo) then
          Exit(False);
      end;
      for LV := LFrom to LTo do
        Include(ASet, LV);
      SkipWs;
      if (LPos <= Length(AArg)) and (AArg[LPos] = ',') then
      begin
        Inc(LPos);
        SkipWs;
      end;
    end;
    if (LPos > Length(AArg)) or (AArg[LPos] <> ']') then
      Exit(False);
    Inc(LPos); // ']'
    Result := True;
  end;

  // METHODS/FIELDS/PROPERTIES ( [set] ) -- AName already read.
  function ReadCategory(const AName: string; out ASet: TPasRttiVisibilitySet)
    : Boolean;
  begin
    Result := False;
    SkipWs;
    if (LPos > Length(AArg)) or (AArg[LPos] <> '(') then
      Exit;
    Inc(LPos); // '('
    if not ReadVisibilitySet(ASet) then
      Exit;
    SkipWs;
    if (LPos > Length(AArg)) or (AArg[LPos] <> ')') then
      Exit;
    Inc(LPos); // ')'
    Result := True;
  end;

var
  LWord: string;
  LSet: TPasRttiVisibilitySet;
begin
  LPos := 1;
  LWord := ReadIdent;
  if LWord = 'EXPLICIT' then
    FRttiState.Mode := rmExplicit
  else if LWord = 'INHERIT' then
    FRttiState.Mode := rmInherit
  else
    Exit; // no recognizable mode word -- nothing else to trust either

  while True do
  begin
    SkipWs;
    if LPos > Length(AArg) then
      Exit;
    LWord := ReadIdent;
    if LWord = '' then
      Exit;
    if LWord = 'METHODS' then
    begin
      if not ReadCategory(LWord, LSet) then Exit;
      FRttiState.HasMethods := True;
      FRttiState.Methods := LSet;
    end
    else if LWord = 'FIELDS' then
    begin
      if not ReadCategory(LWord, LSet) then Exit;
      FRttiState.HasFields := True;
      FRttiState.Fields := LSet;
    end
    else if LWord = 'PROPERTIES' then
    begin
      if not ReadCategory(LWord, LSet) then Exit;
      FRttiState.HasProperties := True;
      FRttiState.Properties := LSet;
    end
    else
      Exit; // unrecognized clause -- stop rather than guess
  end;
end;

// Flips the {$SCOPEDENUMS} state and journals the change at the CURRENT end
// of the visible stream: the directive token itself is trivia (never visible),
// so the new state holds from the next visible token on. No-op (and no event)
// when the value does not actually change, so the journal stays minimal.
procedure TPasPreprocessor.SetScopedEnums(AValue: Boolean);
var
  LEvent: TPasScopedEnumsEvent;
begin
  if FScopedEnums = AValue then
    Exit;
  FScopedEnums := AValue;
  LEvent.VisIndex := FVisible.Count;
  LEvent.Value := AValue;
  FScopedEnumsEvents.Add(LEvent);
end;

// Same journaling contract as SetScopedEnums, for {$Z}/{$MINENUMSIZE}.
procedure TPasPreprocessor.SetMinEnumSize(AValue: Integer);
var
  LEvent: TPasMinEnumEvent;
begin
  // The boolean table and the SIZE are two views of one setting, and every
  // writer has to keep both: `{$Z4}` and `{$MINENUMSIZE 4}` used to move the
  // size only, so `{$IFOPT Z+}` right after them read the stale default.
  // dcc's own equivalence is {$Z+} = {$Z4}, so anything above 1 is "+".
  FSwitches['Z'] := AValue > 1;
  if FMinEnumSize = AValue then
    Exit;
  FMinEnumSize := AValue;
  LEvent.VisIndex := FVisible.Count;
  LEvent.Bytes := AValue;
  FMinEnumEvents.Add(LEvent);
end;

// Same journaling contract again, for {$A}/{$ALIGN}. See TPasAlignEvent.
procedure TPasPreprocessor.SetAlign(AValue: Integer);
var
  LEvent: TPasAlignEvent;
begin
  FSwitches['A'] := AValue > 1;   // {$A+} is {$A8} - see SetMinEnumSize
  if FAlign = AValue then
    Exit;
  FAlign := AValue;
  LEvent.VisIndex := FVisible.Count;
  LEvent.Bytes := AValue;
  FAlignEvents.Add(LEvent);
end;

// The DefineRefs and IfNameRefs of one `$IF`/`$ELSEIF` expression, from spans
// relative to its text (CondEval's DefinedSpans / NameSpans). Not a method:
// TPasCondSpan is CondEval's, which only the implementation may use.
procedure RecordIfRefs(APre: TPasPreprocessor; const AExpr: string;
  AFileId, AExprStart: Integer; AActive: Boolean;
  const ADefined, ANames: TArray<TPasCondSpan>);
var
  LIdx: Integer;
  LRef: TPasDefineRef;
  LNameRef: TPasIfNameRef;
begin
  for LIdx := 0 to High(ADefined) do
  begin
    LRef.FileId := AFileId;
    LRef.Start := AExprStart + ADefined[LIdx].Start;
    LRef.Len := ADefined[LIdx].Len;
    LRef.Name := APre.FDefineNames.Intern(
      PChar(Pointer(AExpr)) + ADefined[LIdx].Start, LRef.Len);
    LRef.Kind := drDefined;
    LRef.Active := AActive;
    APre.FDefineRefs.Add(LRef);
  end;
  // CompilerVersion, a constant, a callee - for a hover or a jump on it, see
  // TPasIfNameRef.
  for LIdx := 0 to High(ANames) do
  begin
    LNameRef.FileId := AFileId;
    LNameRef.Start := AExprStart + ANames[LIdx].Start;
    LNameRef.Len := ANames[LIdx].Len;
    LNameRef.Name := APre.FDefineNames.Intern(
      PChar(Pointer(AExpr)) + ANames[LIdx].Start, LNameRef.Len);
    LNameRef.Active := AActive;
    APre.FIfNameRefs.Add(LNameRef);
  end;
end;

procedure TPasPreprocessor.RecordUnevaluatedIf(const AExpr: string; AFileId,
  AExprStart: Integer; AActive: Boolean);
var
  LDefined, LNames: TArray<TPasCondSpan>;
begin
  CollectCondSpans(AExpr, LDefined, LNames);
  RecordIfRefs(Self, AExpr, AFileId, AExprStart, AActive, LDefined, LNames);
end;

// The `$IF`/`$ELSEIF` expression: parsed by the REAL parser and evaluated by
// PasTree.CondEval (tri-state; see its unit comment for grammar ownership,
// Kleene and/or, and the dcc-probed divergence on genuinely undeclared
// names). Trailing junk after a complete expression is tolerated by
// construction - the parser consumes one expression and ignores the rest,
// which is dcc's own behavior (System.ObjAuto.pas ships
// '$IF SizeOf(Extended) >= 10)' with a stray closing paren).
function TPasPreprocessor.EvalIfExpression(const AExpr: string;
  AFileId, AExprStart: Integer; AActive: Boolean;
  const AToken: TPasToken): Boolean;
var
  LCtx: TPasCondContext;
  LValue: TPasCondValue;
  LBad, LSeen: Boolean;
  LName: string;
  LSym: TPasUnresolvedSymbol;
  LIdx: Integer;
  LAsk: TPasDeclaredAsk;
begin
  LCtx := Default(TPasCondContext);
  LCtx.Defines := FDefines;
  LCtx.OnDeclared := FOnDeclared;
  LCtx.DirPos.FileName := FFileNames[AFileId];
  LCtx.DirPos.Offset := AToken.Start;
  LCtx.OnSymbol := FOnSymbol;
  LCtx.CompilerVersion := FCompilerVersion;
  LCtx.Target := FTarget;
  LValue := EvalCondText(AExpr, LCtx, LBad);
  // Every Defined(X) the expression MENTIONS (a tree walk in CondEval, not
  // the evaluation - `Defined(A) and Defined(B)` short-circuits past B when A
  // is off, and B is still a reference), and every other name it mentions.
  RecordIfRefs(Self, AExpr, AFileId, AExprStart, AActive, LCtx.DefinedSpans,
    LCtx.NameSpans);
  // Unanswered Declared() names and symbol questions feed the second pass
  // (RunDeclaredPass) - but only when they could still CHANGE anything: a
  // verdict settled by a clean side alone (`False and Declared(X)`) is final
  // no matter what X turns out to be, so recording X would only buy a wasted
  // re-parse. A FAILED expression still records, the old evaluator's
  // deliberate behavior - a half-parsed expression that mentioned a name is
  // still a case worth a second look.
  if LBad or LValue.Guessed then
  begin
    for LName in LCtx.UnknownDeclared do
    begin
      // Case-insensitively, like UnresolvedSymbols below: `Declared(Foo)`
      // and `Declared(foo)` are one name (audit B2-11).
      LSeen := False;
      for LIdx := 0 to FUnresolvedDeclared.Count - 1 do
        if SameText(FUnresolvedDeclared[LIdx], LName) then
        begin
          LSeen := True;
          Break;
        end;
      if not LSeen then
        FUnresolvedDeclared.Add(LName);
      LAsk.Name := LName;
      LAsk.FileId := AFileId;
      LAsk.Offset := AToken.Start;
      FDeclaredAsks.Add(LAsk);
    end;
    for LSym in LCtx.UnknownSymbols do
    begin
      LSeen := False;
      for LIdx := 0 to FUnresolvedSymbols.Count - 1 do
        if (FUnresolvedSymbols[LIdx].Query = LSym.Query) and
           SameText(FUnresolvedSymbols[LIdx].Name, LSym.Name) then
        begin
          LSeen := True;
          Break;
        end;
      if not LSeen then
        FUnresolvedSymbols.Add(LSym);
    end;
  end;
  if LBad then
  begin
    Diag(ppBadIfExpression, AFileId, AToken.Start, AToken.Len, AExpr);
    Exit(False);
  end;
  // Flagged only when a guess actually REACHED the verdict, not whenever an
  // unknown name was merely touched: `Defined(FPC) and (FPC_FULLVERSION <
  // 30301)` decides False on the left side alone, exactly as dcc's
  // short-circuit does, and a second pass could not change it.
  if LValue.Guessed then
    DiagUn(ppIfNeedsSemantics, AFileId, AToken.Start, AToken.Len, AExpr,
      LCtx.UnknownSymbols);
  Result := CondAsBool(LValue);
end;

initialization
  // One shared, immutable comparer for every defines dictionary; interface-
  // refcounted, so no finalization pair is needed.
  GDefinesComparer := TDefinesNameComparer.Create;

end.
