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
  - conditional state deliberately spans include boundaries, matching the
    compiler (an .inc may open a conditional the includer closes).

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
    ppUnsupportedInsertion,   // {$I %VAR%}
    ppPopWithoutPush
  );

  TPasSymbolQuery = (sqConstValue, sqSizeOfType, sqLengthOf, sqDeclared);

  // A symbol question nobody could answer - recorded (deduplicated, source
  // order) exactly like UnresolvedDeclared, and consumed by the same second
  // pass to decide whether re-preprocessing could learn anything.
  TPasUnresolvedSymbol = record
    Query: TPasSymbolQuery;
    Name: string;
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
    // resolved -- a missing `uses` can hide a declaration.
    NoSymbol: Boolean;
  end;

  { Answers symbol questions from a `$IF` expression - the widened sibling of
    TPasDeclaredQuery, same three-state contract: the RESULT says whether the
    oracle could answer at all, AValue is the answer when it could. Nil on the
    first pass; TPasSemaProject.SymbolQueryFor supplies it on the second. }
  TPasCondSymbolQuery = reference to function(AQuery: TPasSymbolQuery;
    const AName: string; out AValue: TPasSymbolValue): Boolean;

  TPasPreprocessed = record
  public
    FileNames: TArray<string>;              // [0] = main file
    Files: TArray<TPasTokenStream>;
    Visible: TArray<TPasVisibleToken>;
    Skipped: TArray<TArray<TPasSkippedRegion>>;  // per file, sorted
    Diagnostics: TArray<TPasPPDiagnostic>;
    // {$SCOPEDENUMS} state changes, ascending by VisIndex; empty for the
    // overwhelming majority of units (the switch defaults to OFF).
    ScopedEnumsEvents: TArray<TPasScopedEnumsEvent>;
    // Names a `$IF Declared(X)` guard asked about that no one could answer,
    // in source order, deduplicated. Empty unless the unit uses that guard AND
    // the run had no OnDeclared to ask - which is the signal a caller with a
    // symbol table uses to decide the unit is worth preprocessing again.
    UnresolvedDeclared: TArray<string>;
    // Same contract for the symbol questions (const values, SizeOf, Length)
    // no OnSymbol could answer - see TPasUnresolvedSymbol.
    UnresolvedSymbols: TArray<TPasUnresolvedSymbol>;
    // {$Z}/{$MINENUMSIZE} state changes, ascending by VisIndex; empty for
    // the overwhelming majority of units (the default is 1).
    MinEnumEvents: TArray<TPasMinEnumEvent>;
    // {$A}/{$ALIGN} state changes, ascending by VisIndex; empty for the
    // overwhelming majority of units (the default is 8).
    AlignEvents: TArray<TPasAlignEvent>;
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
  end;

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
    would otherwise cost. }
  TPasDeclaredQuery = reference to function(const AName: string;
    out ADeclared: Boolean): Boolean;

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
  TPasOptState = record
    Switches: TPasSwitchState;
    ScopedEnums: Boolean;
    Rtti: TPasRttiState;
    VarPropSetter: Boolean;
    MinEnumSize: Integer;
    Align: Integer;
  end;

  TPasPreprocessor = class
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
    FSwitchStack: TStack<TPasOptState>;
    FFileNames: TList<string>;
    FFiles: TList<TPasTokenStream>;
    FVisible: TList<TPasVisibleToken>;
    FSkipped: TObjectList<TList<TPasSkippedRegion>>;
    FDiags: TList<TPasPPDiagnostic>;
    FIncludePathStack: TList<string>;
    // Conditional stack - shared across include boundaries by design.
    FCondParentActive: TList<Boolean>;
    FCondAnyTaken: TList<Boolean>;
    FCondThisActive: TList<Boolean>;
    FCondSeenElse: TList<Boolean>;
    FCompilerVersion: Double;
    FPointerBytes: Integer;
    FExtendedBytes: Integer;
    FOnDeclared: TPasDeclaredQuery;
    FOnSymbol: TPasCondSymbolQuery;
    FUnresolvedDeclared: TList<string>;
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
    procedure ResetSwitches;
    procedure ApplySwitches(const ABody: string);
    procedure ApplyLongSwitch(const AName, AArg: string);
    procedure SetScopedEnums(AValue: Boolean);
    procedure SetMinEnumSize(AValue: Integer);
    procedure SetAlign(AValue: Integer);
    procedure ApplyRtti(const AArg: string);
    function EvalIfExpression(const AExpr: string; AFileId: Integer;
      const AToken: TPasToken): Boolean;
  public
    { APointerBytes/AExtendedBytes parameterize SizeOf() in $IF expressions
      for the target platform (Win32: 4/10; 64-bit targets: 8/8). }
    constructor Create(ASourceManager: TPasSourceManager;
      ADefines: TPasDefines; ACompilerVersion: Double = 37.0;
      APointerBytes: Integer = 8; AExtendedBytes: Integer = 8);
    destructor Destroy; override;
    { Preprocesses a main file loaded via the source manager. The instance
      can be reused for another file afterwards. }
    function Process(const AFileName: string): TPasPreprocessed;
    { Same, but with the main file's text supplied directly (tests, LSP
      buffers). AFileName is used for include resolution and reporting. }
    function ProcessText(const AFileName, ASource: string): TPasPreprocessed;
    { Set to answer a `$IF Declared(X)` guard - see TPasDeclaredQuery. While
      set the expression is no longer flagged as needing semantics, because it
      no longer does. }
    property OnDeclared: TPasDeclaredQuery read FOnDeclared write FOnDeclared;
    { The symbol oracle for `$IF` const/SizeOf/Length questions - nil on the
      first pass, supplied by the project's second pass exactly like
      OnDeclared. See TPasCondSymbolQuery. }
    property OnSymbol: TPasCondSymbolQuery read FOnSymbol write FOnSymbol;
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
    '$POPOPT without $PUSHOPT'
  );

implementation

uses
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
  { ASCII-fold case-insensitive comparer for the defines dictionary: hashes
    and compares without allocating, where the previous scheme paid a
    LowerCase(Trim(...)) copy on EVERY Define/Undefine/IsDefined - i.e. per
    `$IFDEF` / `Defined()` evaluation across the whole closure. ASCII-only
    folding is the same contract the old LowerCase normalization had. }
  TDefinesNameComparer = class(TEqualityComparer<string>)
  public
    function Equals(const Left, Right: string): Boolean; overload; override;
    function GetHashCode(const Value: string): Integer; overload; override;
  end;

var
  GDefinesComparer: IEqualityComparer<string>;

function TDefinesNameComparer.Equals(const Left, Right: string): Boolean;
begin
  Result := SliceEqualsWord(PChar(Pointer(Left)), Length(Left), Right);
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
  LCh: Char;
  LHash: Cardinal;
begin
  // FNV-1a over ASCII-folded UTF-16 code units.
  LHash := 2166136261;
  for LIdx := 1 to Length(Value) do
  begin
    LCh := Value[LIdx];
    if (LCh >= 'A') and (LCh <= 'Z') then
      Inc(LCh, 32);
    LHash := (LHash xor Ord(LCh)) * 16777619;
  end;
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

function TPasDefines.Clone: TPasDefines;
var
  LKey: string;
begin
  // Pre-sized: this runs once per FILE (defines are unit-local), and growing
  // through rehashes cost more than the clone itself.
  Result := TPasDefines.Create(FMap.Count);
  for LKey in FMap.Keys do
    Result.FMap.Add(LKey, True);
end;

{ TPasPreprocessor ----------------------------------------------------------- }

constructor TPasPreprocessor.Create(ASourceManager: TPasSourceManager;
  ADefines: TPasDefines; ACompilerVersion: Double;
  APointerBytes: Integer; AExtendedBytes: Integer);
begin
  inherited Create;
  FSourceManager := ASourceManager;
  FBaseDefines := ADefines;
  FCompilerVersion := ACompilerVersion;
  FPointerBytes := APointerBytes;
  FExtendedBytes := AExtendedBytes;
  FSwitchStack := TStack<TPasOptState>.Create;
  FScopedEnumsEvents := TList<TPasScopedEnumsEvent>.Create;
  FMinEnumEvents := TList<TPasMinEnumEvent>.Create;
  FAlignEvents := TList<TPasAlignEvent>.Create;
  FFileNames := TList<string>.Create;
  FFiles := TList<TPasTokenStream>.Create;
  FVisible := TList<TPasVisibleToken>.Create;
  FSkipped := TObjectList<TList<TPasSkippedRegion>>.Create(True);
  FDiags := TList<TPasPPDiagnostic>.Create;
  FIncludePathStack := TList<string>.Create;
  FUnresolvedDeclared := TList<string>.Create;
  FUnresolvedSymbols := TList<TPasUnresolvedSymbol>.Create;
  FCondParentActive := TList<Boolean>.Create;
  FCondAnyTaken := TList<Boolean>.Create;
  FCondThisActive := TList<Boolean>.Create;
  FCondSeenElse := TList<Boolean>.Create;
  ResetSwitches;
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
var
  LCh: Char;
begin
  // Reasonable defaults for the switch state (release-ish). Re-applied per
  // processed file: switch changes are unit-local, like defines.
  for LCh := 'A' to 'Z' do
    FSwitches[LCh] := False;
  FSwitches['A'] := True;   // field alignment: the default IS {$A8}, so '+'
  FSwitches['C'] := True;   // assertions
  FSwitches['D'] := True;   // debug info
  FSwitches['G'] := True;   // imported data
  FSwitches['H'] := True;   // long strings
  FSwitches['I'] := True;   // I/O checking
  FSwitches['L'] := True;   // local symbols
  FSwitches['O'] := True;   // optimization
  FSwitches['P'] := True;   // open strings
  FSwitches['V'] := True;   // var-string checks
  FSwitches['X'] := True;   // extended syntax
  FSwitches['Y'] := True;   // symbol reference info
end;

destructor TPasPreprocessor.Destroy;
begin
  FDefines.Free;   // the per-run clone; FBaseDefines is caller-owned
  FCondSeenElse.Free;
  FCondThisActive.Free;
  FCondAnyTaken.Free;
  FCondParentActive.Free;
  FIncludePathStack.Free;
  FUnresolvedDeclared.Free;
  FUnresolvedSymbols.Free;
  FDiags.Free;
  FSkipped.Free;
  FVisible.Free;
  FFiles.Free;
  FFileNames.Free;
  FScopedEnumsEvents.Free;
  FMinEnumEvents.Free;
  FAlignEvents.Free;
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
  FDefines := FBaseDefines.Clone;
  ResetSwitches;
  FFileNames.Clear;
  FFiles.Clear;
  // Count := 0, not Clear: Clear drops CAPACITY, and this instance is reused
  // across files (the project driver pools preprocessors) - a 100k-token unit
  // would otherwise re-grow the list through ~17 doublings every time.
  FVisible.Count := 0;
  FSkipped.Clear;
  FDiags.Clear;
  FIncludePathStack.Clear;
  FUnresolvedDeclared.Clear;
  FUnresolvedSymbols.Clear;
  FCondParentActive.Clear;
  FCondAnyTaken.Clear;
  FCondThisActive.Clear;
  FCondSeenElse.Clear;
  FSwitchStack.Clear;
  FScopedEnums := False;         // dcc default; unit-local like the switches
  FScopedEnumsEvents.Clear;
  FMinEnumSize := 1;             // dcc default ({$Z1}); unit-local likewise
  FMinEnumEvents.Clear;
  FAlign := 8;                   // dcc default ({$A8}); unit-local likewise
  FAlignEvents.Clear;
  FRttiState := Default(TPasRttiState);   // Mode = rmInherit, the dcc default
  FVarPropSetter := False;                // dcc default: OFF (13.1.6)

  LStream := TPasLexer.Tokenize(ASource);
  // Visible tokens <= the main file's raw tokens (trivia and skipped regions
  // only subtract; includes add, and then the list grows the ordinary way).
  if FVisible.Capacity < Length(LStream.Tokens) then
    FVisible.Capacity := Length(LStream.Tokens);
  FFileNames.Add(AFileName);
  FFiles.Add(LStream);
  FSkipped.Add(TList<TPasSkippedRegion>.Create);
  FIncludePathStack.Add(LowerCase(AFileName));
  try
    ProcessFile(0);
  finally
    FIncludePathStack.Clear;
  end;

  if FCondThisActive.Count > 0 then
    Diag(ppUnterminatedConditional, 0, Length(LStream.Source), 0);

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
  Result.UnresolvedSymbols := FUnresolvedSymbols.ToArray;
  Result.MinEnumEvents := FMinEnumEvents.ToArray;
  Result.AlignEvents := FAlignEvents.ToArray;
  SetLength(Result.Skipped, FSkipped.Count);
  for LIdx := 0 to FSkipped.Count - 1 do
    Result.Skipped[LIdx] := FSkipped[LIdx].ToArray;
end;

procedure TPasPreprocessor.ProcessFile(AFileId: Integer);
var
  LTokens: TArray<TPasToken>;
  LIdx: Integer;
  LVis: TPasVisibleToken;
  LSkipStart: Integer;
begin
  LTokens := FFiles[AFileId].Tokens;
  LSkipStart := -1;
  for LIdx := 0 to High(LTokens) do
  begin
    case LTokens[LIdx].Kind of
      tkDirective:
        begin
          // Close a pending skipped region before the directive; the
          // directive itself is never part of a skipped span (it may be
          // the one that reactivates output).
          if LSkipStart >= 0 then
          begin
            MarkSkipped(AFileId, LSkipStart, LTokens[LIdx].Start);
            LSkipStart := -1;
          end;
          HandleDirective(AFileId, LTokens[LIdx]);
          if not Active then
            LSkipStart := LTokens[LIdx].EndPos;
        end;
      tkEndOfFile:
        ; // handled by Process for the main file
    else
      if Active then
      begin
        if not IsTrivia(LTokens[LIdx].Kind) then
        begin
          LVis.FileId := AFileId;
          LVis.TokenIndex := LIdx;
          FVisible.Add(LVis);
        end;
      end
      else if LSkipStart < 0 then
        LSkipStart := LTokens[LIdx].Start;
    end;
  end;
  if LSkipStart >= 0 then
    MarkSkipped(AFileId, LSkipStart, Length(FFiles[AFileId].Source));
end;

procedure TPasPreprocessor.HandleDirective(AFileId: Integer;
  const AToken: TPasToken);
var
  LText: PChar;
  LLen, LNameLen, LIdx: Integer;
  LKind: TPPDirKind;
  LBody, LName, LArg: string;
  LParent, LTaken: Boolean;
  LTop: Integer;
  LSwitch: Char;
  LWant: Boolean;

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
    SetString(Result, LP, LN);
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

  // ---- conditionals (always processed, active or not) ----
  if LKind = pdIfdef then
  begin
    LArg := Arg;
    LParent := Active;
    LTaken := LParent and FDefines.IsDefined(LArg);
    FCondParentActive.Add(LParent);
    FCondAnyTaken.Add(LTaken);
    FCondThisActive.Add(LTaken);
    FCondSeenElse.Add(False);
  end
  else if LKind = pdIfndef then
  begin
    LParent := Active;
    LTaken := LParent and not FDefines.IsDefined(Arg);
    FCondParentActive.Add(LParent);
    FCondAnyTaken.Add(LTaken);
    FCondThisActive.Add(LTaken);
    FCondSeenElse.Add(False);
  end
  else if LKind = pdIf then
  begin
    LParent := Active;
    LTaken := LParent and EvalIfExpression(Arg, AFileId, AToken);
    FCondParentActive.Add(LParent);
    FCondAnyTaken.Add(LTaken);
    FCondThisActive.Add(LTaken);
    FCondSeenElse.Add(False);
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
  end
  else if LKind = pdElseif then
  begin
    LTop := FCondThisActive.Count - 1;
    if LTop < 0 then
      Diag(ppUnbalancedElse, AFileId, AToken.Start, AToken.Len)
    else if FCondSeenElse[LTop] then
      Diag(ppUnbalancedElse, AFileId, AToken.Start, AToken.Len)
    else
    begin
      LTaken := FCondParentActive[LTop] and not FCondAnyTaken[LTop] and
        EvalIfExpression(Arg, AFileId, AToken);
      FCondThisActive[LTop] := LTaken;
      if LTaken then
        FCondAnyTaken[LTop] := True;
    end;
  end
  else if LKind = pdElse then
  begin
    LTop := FCondThisActive.Count - 1;
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
    if LTop < 0 then
      Diag(ppUnbalancedEndif, AFileId, AToken.Start, AToken.Len)
    else
    begin
      FCondParentActive.Delete(LTop);
      FCondAnyTaken.Delete(LTop);
      FCondThisActive.Delete(LTop);
      FCondSeenElse.Delete(LTop);
    end;
  end
  // ---- everything below acts only in active regions ----
  else if not Active then
    // ignore
  else if LKind = pdDefine then
    FDefines.Define(Arg)
  else if LKind = pdUndef then
    FDefines.Undefine(Arg)
  else if LKind = pdInclude then
  begin
    LArg := Arg;
    if (LArg <> '') and CharInSet(LArg[1], ['+', '-']) then
    begin
      // {$I+} / {$I-}: the IOCHECKS switch, not an include. And it can HEAD A
      // GROUP - `{$I-,R+}` - so the remainder goes through the ordinary
      // switch parser instead of being dropped on the floor.
      FSwitches['I'] := LArg[1] = '+';
      if Length(LArg) > 1 then
        ApplySwitches('I' + LArg);
    end
    else if (LArg <> '') and (LArg[1] = '%') then
      Diag(ppUnsupportedInsertion, AFileId, AToken.Start, AToken.Len, LArg)
    else
      HandleInclude(AFileId, AToken, LArg);
  end
  else if LKind = pdPushopt then
  begin
    var LOpt: TPasOptState;
    LOpt.Switches := FSwitches;
    LOpt.ScopedEnums := FScopedEnums;
    LOpt.Rtti := FRttiState;
    LOpt.VarPropSetter := FVarPropSetter;
    LOpt.MinEnumSize := FMinEnumSize;
    LOpt.Align := FAlign;
    FSwitchStack.Push(LOpt);
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
    end
    else
      Diag(ppPopWithoutPush, AFileId, AToken.Start, AToken.Len);
  end
  else if LKind = pdSwitch then
  begin
    // Single-letter switch directive(s): {$R-}, {$O+,W-}, {$Z4}, {$R *.res}
    SetString(LBody, LText, LLen);
    ApplySwitches(LBody);
  end
  else
  begin
    // Long-form switches we track; everything else is passthrough trivia.
    // ApplyLongSwitch dispatches on the UPPERCASED name, as SplitDirective
    // used to hand it.
    SetString(LName, LText, LNameLen);
    for LIdx := 1 to LNameLen do
      if (LName[LIdx] >= 'a') and (LName[LIdx] <= 'z') then
        LName[LIdx] := Char(Ord(LName[LIdx]) - 32);
    ApplyLongSwitch(LName, Arg);
  end;
end;

procedure TPasPreprocessor.HandleInclude(AFileId: Integer;
  const AToken: TPasToken; const AArg: string);
var
  LResolved, LKey: string;
  LNewId: Integer;
  LStream: TPasTokenStream;
begin
  if not FSourceManager.ResolveInclude(FFileNames[AFileId], AArg, LResolved)
  then
  begin
    Diag(ppIncludeNotFound, AFileId, AToken.Start, AToken.Len, AArg);
    Exit;
  end;
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
  LStream := FSourceManager.IncludeStream(LResolved);
  FFileNames.Add(LResolved);
  FFiles.Add(LStream);
  FSkipped.Add(TList<TPasSkippedRegion>.Create);
  LNewId := FFiles.Count - 1;

  FIncludePathStack.Add(LKey);
  try
    ProcessFile(LNewId);
  finally
    FIncludePathStack.Delete(FIncludePathStack.Count - 1);
  end;
end;

procedure TPasPreprocessor.ApplySwitches(const ABody: string);
var
  LIdx: Integer;
  LSwitch: Char;
begin
  // Forms: X+  X-  X+,Y-  Zn / An (tracked, below)  X <arg> ($R res: ignored)
  LIdx := 1;
  while LIdx < Length(ABody) do
  begin
    if not CharInSet(ABody[LIdx], ['A'..'Z', 'a'..'z']) then
      Exit;
    LSwitch := UpCase(ABody[LIdx]);
    if (LIdx + 1 <= Length(ABody)) and
       CharInSet(ABody[LIdx + 1], ['+', '-']) then
    begin
      FSwitches[LSwitch] := ABody[LIdx + 1] = '+';
      // {$Z+} is {$Z4} and {$Z-} is {$Z1} - dcc's own equivalences; the
      // boolean table above keeps its generic entry ($IFOPT Z reads it),
      // the SIZE is what SizeOf-of-an-enum needs.
      if LSwitch = 'Z' then
        if ABody[LIdx + 1] = '+' then
          SetMinEnumSize(4)
        else
          SetMinEnumSize(1);
      // {$A+} is {$A8} and {$A-} is {$A1}, the same shape one switch over.
      if LSwitch = 'A' then
        if ABody[LIdx + 1] = '+' then
          SetAlign(8)
        else
          SetAlign(1);
      LIdx := LIdx + 2;
      // Comma-separated list: {$O+,W-}
      while (LIdx <= Length(ABody)) and
        CharInSet(ABody[LIdx], [',', ' ', #9]) do
        Inc(LIdx);
    end
    else if (LSwitch = 'Z') and (LIdx + 1 <= Length(ABody)) and
            CharInSet(ABody[LIdx + 1], ['1', '2', '4']) then
    begin
      // {$Z1/2/4}: minimum enum size, tracked positionally (see
      // TPasMinEnumEvent). The only numeric switch with state we consume.
      SetMinEnumSize(Ord(ABody[LIdx + 1]) - Ord('0'));
      LIdx := LIdx + 2;
      while (LIdx <= Length(ABody)) and
        CharInSet(ABody[LIdx], [',', ' ', #9]) do
        Inc(LIdx);
    end
    else if (LSwitch = 'A') and (LIdx + 1 <= Length(ABody)) and
            CharInSet(ABody[LIdx + 1], ['1', '2', '4', '8']) then
    begin
      // {$A1/2/4/8/16}: the record field-alignment cap, tracked positionally
      // (see TPasAlignEvent). Two digits only for 16, and 16 caps nothing a
      // builtin can exceed - it lands on the same layout as 8, but it is
      // recorded as written rather than normalized.
      if (ABody[LIdx + 1] = '1') and (LIdx + 2 <= Length(ABody)) and
         (ABody[LIdx + 2] = '6') then
      begin
        SetAlign(16);
        LIdx := LIdx + 3;
      end
      else
      begin
        SetAlign(Ord(ABody[LIdx + 1]) - Ord('0'));
        LIdx := LIdx + 2;
      end;
      while (LIdx <= Length(ABody)) and
        CharInSet(ABody[LIdx], [',', ' ', #9]) do
        Inc(LIdx);
    end
    else
      Exit; // {$R *.res} etc. - no state to track
  end;
end;

procedure TPasPreprocessor.ApplyLongSwitch(const AName, AArg: string);

  procedure SetSwitch(ALetter: Char);
  begin
    if SameText(AArg, 'ON') then
      FSwitches[ALetter] := True
    else if SameText(AArg, 'OFF') then
      FSwitches[ALetter] := False;
  end;

begin
  if AName = 'RANGECHECKS' then SetSwitch('R')
  else if AName = 'OVERFLOWCHECKS' then SetSwitch('Q')
  else if AName = 'IOCHECKS' then SetSwitch('I')
  else if AName = 'OPTIMIZATION' then SetSwitch('O')
  else if AName = 'BOOLEVAL' then SetSwitch('B')
  else if AName = 'WRITEABLECONST' then SetSwitch('J')
  else if AName = 'TYPEDADDRESS' then SetSwitch('T')
  else if AName = 'EXTENDEDSYNTAX' then SetSwitch('X')
  else if AName = 'LONGSTRINGS' then SetSwitch('H')
  else if AName = 'STACKFRAMES' then SetSwitch('W')
  else if AName = 'SAFEDIVIDE' then SetSwitch('U')
  else if AName = 'OPENSTRINGS' then SetSwitch('P')
  else if AName = 'ASSERTIONS' then SetSwitch('C')
  else if AName = 'DEBUGINFO' then SetSwitch('D')
  else if AName = 'LOCALSYMBOLS' then SetSwitch('L')
  else if AName = 'REFERENCEINFO' then SetSwitch('Y')
  else if AName = 'IMPORTEDDATA' then SetSwitch('G')
  else if AName = 'VARSTRINGCHECKS' then SetSwitch('V')
  else if AName = 'SCOPEDENUMS' then
  begin
    // Long-form only (no single-letter twin). Positional: the resolver reads
    // the state at each enum's declaration site - see TPasScopedEnumsEvent.
    if SameText(AArg, 'ON') then
      SetScopedEnums(True)
    else if SameText(AArg, 'OFF') then
      SetScopedEnums(False);
  end
  else if AName = 'RTTI' then
    ApplyRtti(AArg)
  else if AName = 'MINENUMSIZE' then
  begin
    // The long form of {$Z1/2/4} (13.0 docs list both). Positional - see
    // TPasMinEnumEvent.
    if (Length(AArg) = 1) and CharInSet(AArg[1], ['1', '2', '4']) then
      SetMinEnumSize(Ord(AArg[1]) - Ord('0'));
  end
  else if AName = 'ALIGN' then
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
      SetAlign(StrToInt(AArg));
  end
  else if AName = 'VARPROPSETTER' then
  begin
    // 13.1.6. Long-form-only ON/OFF like SCOPEDENUMS, but NOT positional:
    // nothing reads it per-declaration yet, because PasTree emits no E2282.
    if SameText(AArg, 'ON') then
      FVarPropSetter := True
    else if SameText(AArg, 'OFF') then
      FVarPropSetter := False;
  end;
  // Unknown names: passthrough (WARN, HINTS, REGION, HPPEMIT, ...)
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

// The `$IF`/`$ELSEIF` expression: parsed by the REAL parser and evaluated by
// PasTree.CondEval (tri-state; see its unit comment for grammar ownership,
// Kleene and/or, and the dcc-probed divergence on genuinely undeclared
// names). Trailing junk after a complete expression is tolerated by
// construction - the parser consumes one expression and ignores the rest,
// which is dcc's own behavior (System.ObjAuto.pas ships
// '$IF SizeOf(Extended) >= 10)' with a stray closing paren).
function TPasPreprocessor.EvalIfExpression(const AExpr: string;
  AFileId: Integer; const AToken: TPasToken): Boolean;
var
  LCtx: TPasCondContext;
  LValue: TPasCondValue;
  LBad, LSeen: Boolean;
  LName: string;
  LSym: TPasUnresolvedSymbol;
  LIdx: Integer;
begin
  LCtx := Default(TPasCondContext);
  LCtx.Defines := FDefines;
  LCtx.OnDeclared := FOnDeclared;
  LCtx.OnSymbol := FOnSymbol;
  LCtx.CompilerVersion := FCompilerVersion;
  LCtx.PointerBytes := FPointerBytes;
  LCtx.ExtendedBytes := FExtendedBytes;
  LValue := EvalCondText(AExpr, LCtx, LBad);
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
      if FUnresolvedDeclared.IndexOf(LName) < 0 then
        FUnresolvedDeclared.Add(LName);
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
