unit PasTree.Preprocessor;

{
  PasTree — the preprocessor (spec: object-pascal-spec 1.3, B.2.2).

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
  the retained raw streams — full fidelity is preserved underneath.
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
                              // only the semantic phase can evaluate; the
                              // expression was treated as False. Informational.
    ppUnsupportedInsertion,   // {$I %VAR%}
    ppPopWithoutPush
  );

  TPasPPDiagnostic = record
    Code: TPasPPDiagCode;
    FileId: Integer;
    Start: Integer;
    Len: Integer;
    Detail: string;
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
  // answer — System.Threading turns it ON for the whole unit while most of
  // the RTL never does, and one unit routinely toggles it around a group of
  // declarations.
  TPasScopedEnumsEvent = record
    VisIndex: Integer;
    Value: Boolean;
  end;

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
    // the run had no OnDeclared to ask — which is the signal a caller with a
    // symbol table uses to decide the unit is worth preprocessing again.
    UnresolvedDeclared: TArray<string>;
    function VisibleToken(AIndex: Integer): TPasToken;
    function VisibleText(AIndex: Integer): string;
    function IsSkipped(AFileId, AOffset: Integer): Boolean;
    // The SCOPEDENUMS state in effect at visible-stream position AVisIndex
    // (False = unscoped, the default). Binary search over the event list.
    function ScopedEnumsAt(AVisIndex: Integer): Boolean;
  end;

  TPasDefines = class
  private
    FMap: TDictionary<string, Boolean>;
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
    produces. So the question is handed OUT to whoever has one — see
    TPasSemaProject.RunDeclaredPass, which supplies it on a second pass once
    every unit has a model. Nil means "nobody can answer", the ordinary
    first-pass state.

    A three-state answer, because "I do not know" is a real and common case:
    the RESULT says whether the query could answer at all, ADeclared is the
    answer when it could. A query that knows only the compiler-provided names
    can run on the FIRST pass — it needs no models — and takes the big RTL
    units out of the second pass entirely, which is most of what that pass
    would otherwise cost. }
  TPasDeclaredQuery = reference to function(const AName: string;
    out ADeclared: Boolean): Boolean;

  TPasSwitchState = array['A'..'Z'] of Boolean;

  // Everything {$PUSHOPT} must save: the single-letter switches PLUS the
  // long-form-only options tracked individually (real dcc's PUSHOPT/POPOPT
  // covers all compiler options, SCOPEDENUMS included).
  TPasOptState = record
    Switches: TPasSwitchState;
    ScopedEnums: Boolean;
  end;

  TPasPreprocessor = class
  private
    FSourceManager: TPasSourceManager;
    FBaseDefines: TPasDefines;   // caller-owned project defines
    FDefines: TPasDefines;       // per-run clone: $DEFINE is unit-local!
    FSwitches: TPasSwitchState;
    FScopedEnums: Boolean;
    FScopedEnumsEvents: TList<TPasScopedEnumsEvent>;
    FSwitchStack: TStack<TPasOptState>;
    FFileNames: TList<string>;
    FFiles: TList<TPasTokenStream>;
    FVisible: TList<TPasVisibleToken>;
    FSkipped: TObjectList<TList<TPasSkippedRegion>>;
    FDiags: TList<TPasPPDiagnostic>;
    FIncludePathStack: TList<string>;
    // Conditional stack — shared across include boundaries by design.
    FCondParentActive: TList<Boolean>;
    FCondAnyTaken: TList<Boolean>;
    FCondThisActive: TList<Boolean>;
    FCondSeenElse: TList<Boolean>;
    FCompilerVersion: Double;
    FPointerBytes: Integer;
    FExtendedBytes: Integer;
    FOnDeclared: TPasDeclaredQuery;
    FUnresolvedDeclared: TList<string>;
    function Active: Boolean;
    procedure Diag(ACode: TPasPPDiagCode; AFileId, AStart, ALen: Integer;
      const ADetail: string = '');
    procedure MarkSkipped(AFileId, AStart, AEnd: Integer);
    procedure ProcessFile(AFileId: Integer);
    procedure HandleDirective(AFileId: Integer; const AToken: TPasToken);
    procedure HandleInclude(AFileId: Integer; const AToken: TPasToken;
      const AArg: string);
    procedure ResetSwitches;
    procedure ApplySwitches(const ABody: string);
    procedure ApplyLongSwitch(const AName, AArg: string);
    procedure SetScopedEnums(AValue: Boolean);
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
    { Set to answer a `$IF Declared(X)` guard — see TPasDeclaredQuery. While
      set the expression is no longer flagged as needing semantics, because it
      no longer does. }
    property OnDeclared: TPasDeclaredQuery read FOnDeclared write FOnDeclared;
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
    '$IF needs semantic info (treated as False)',
    'Insertion form {$I %...%} is not supported',
    '$POPOPT without $PUSHOPT'
  );

implementation

uses
  PasTree.Lexer;

const
  MAX_INCLUDE_DEPTH = 32;

{ Directive text helpers ---------------------------------------------------- }

// Extracts the body of a directive token: brace or paren-star form,
// e.g. '{$IFDEF X}' -> 'IFDEF X' and '(*$I file*)' -> 'I file'.
function DirectiveBody(const AText: string): string;
var
  LFrom, LTo: Integer;
begin
  if AText.StartsWith('{$') then
  begin
    LFrom := 3;
    LTo := Length(AText);
    if (LTo >= 1) and (AText[LTo] = '}') then
      Dec(LTo);
  end
  else if AText.StartsWith('(*$') then
  begin
    LFrom := 4;
    LTo := Length(AText);
    if (LTo >= 2) and (AText[LTo - 1] = '*') and (AText[LTo] = ')') then
      Dec(LTo, 2);
  end
  else
  begin
    LFrom := 1;
    LTo := Length(AText);
  end;
  Result := Trim(Copy(AText, LFrom, LTo - LFrom + 1));
end;

{ Splits 'IFDEF FOO' into name ('IFDEF', uppercased) and arg ('FOO'). The
  name is the leading run of letters; anything else stops it, so switch
  forms like 'R-' or 'I-' yield a one-letter name. }
procedure SplitDirective(const ABody: string; out AName, AArg: string);
var
  LIdx: Integer;
begin
  LIdx := 1;
  while (LIdx <= Length(ABody)) and CharInSet(ABody[LIdx], ['A'..'Z', 'a'..'z']) do
    Inc(LIdx);
  AName := UpperCase(Copy(ABody, 1, LIdx - 1));
  AArg := Trim(Copy(ABody, LIdx, MaxInt));
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

{ TPasDefines ---------------------------------------------------------------- }

constructor TPasDefines.Create;
begin
  inherited Create;
  FMap := TDictionary<string, Boolean>.Create;
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

procedure TPasDefines.Define(const AName: string);
begin
  FMap.AddOrSetValue(LowerCase(Trim(AName)), True);
end;

procedure TPasDefines.Undefine(const AName: string);
begin
  FMap.Remove(LowerCase(Trim(AName)));
end;

function TPasDefines.IsDefined(const AName: string): Boolean;
begin
  Result := FMap.ContainsKey(LowerCase(Trim(AName)));
end;

function TPasDefines.Clone: TPasDefines;
var
  LKey: string;
begin
  Result := TPasDefines.Create;
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
  FFileNames := TList<string>.Create;
  FFiles := TList<TPasTokenStream>.Create;
  FVisible := TList<TPasVisibleToken>.Create;
  FSkipped := TObjectList<TList<TPasSkippedRegion>>.Create(True);
  FDiags := TList<TPasPPDiagnostic>.Create;
  FIncludePathStack := TList<string>.Create;
  FUnresolvedDeclared := TList<string>.Create;
  FCondParentActive := TList<Boolean>.Create;
  FCondAnyTaken := TList<Boolean>.Create;
  FCondThisActive := TList<Boolean>.Create;
  FCondSeenElse := TList<Boolean>.Create;
  ResetSwitches;
end;

procedure TPasPreprocessor.ResetSwitches;
var
  LCh: Char;
begin
  // Reasonable defaults for the switch state (release-ish). Re-applied per
  // processed file: switch changes are unit-local, like defines.
  for LCh := 'A' to 'Z' do
    FSwitches[LCh] := False;
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
  FDiags.Free;
  FSkipped.Free;
  FVisible.Free;
  FFiles.Free;
  FFileNames.Free;
  FScopedEnumsEvents.Free;
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
var
  LDiag: TPasPPDiagnostic;
begin
  LDiag.Code := ACode;
  LDiag.FileId := AFileId;
  LDiag.Start := AStart;
  LDiag.Len := ALen;
  LDiag.Detail := ADetail;
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
  FVisible.Clear;
  FSkipped.Clear;
  FDiags.Clear;
  FIncludePathStack.Clear;
  FUnresolvedDeclared.Clear;
  FCondParentActive.Clear;
  FCondAnyTaken.Clear;
  FCondThisActive.Clear;
  FCondSeenElse.Clear;
  FSwitchStack.Clear;
  FScopedEnums := False;         // dcc default; unit-local like the switches
  FScopedEnumsEvents.Clear;

  LStream := TPasLexer.Tokenize(ASource);
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
  LBody, LName, LArg: string;
  LParent, LTaken: Boolean;
  LTop: Integer;
  LSwitch: Char;
  LWant: Boolean;
begin
  LBody := DirectiveBody(FFiles[AFileId].TokenText(AToken));
  SplitDirective(LBody, LName, LArg);

  // ---- conditionals (always processed, active or not) ----
  if LName = 'IFDEF' then
  begin
    LParent := Active;
    LTaken := LParent and FDefines.IsDefined(LArg);
    FCondParentActive.Add(LParent);
    FCondAnyTaken.Add(LTaken);
    FCondThisActive.Add(LTaken);
    FCondSeenElse.Add(False);
  end
  else if LName = 'IFNDEF' then
  begin
    LParent := Active;
    LTaken := LParent and not FDefines.IsDefined(LArg);
    FCondParentActive.Add(LParent);
    FCondAnyTaken.Add(LTaken);
    FCondThisActive.Add(LTaken);
    FCondSeenElse.Add(False);
  end
  else if LName = 'IF' then
  begin
    LParent := Active;
    LTaken := LParent and EvalIfExpression(LArg, AFileId, AToken);
    FCondParentActive.Add(LParent);
    FCondAnyTaken.Add(LTaken);
    FCondThisActive.Add(LTaken);
    FCondSeenElse.Add(False);
  end
  else if LName = 'IFOPT' then
  begin
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
  else if LName = 'ELSEIF' then
  begin
    LTop := FCondThisActive.Count - 1;
    if LTop < 0 then
      Diag(ppUnbalancedElse, AFileId, AToken.Start, AToken.Len)
    else if FCondSeenElse[LTop] then
      Diag(ppUnbalancedElse, AFileId, AToken.Start, AToken.Len)
    else
    begin
      LTaken := FCondParentActive[LTop] and not FCondAnyTaken[LTop] and
        EvalIfExpression(LArg, AFileId, AToken);
      FCondThisActive[LTop] := LTaken;
      if LTaken then
        FCondAnyTaken[LTop] := True;
    end;
  end
  else if LName = 'ELSE' then
  begin
    LTop := FCondThisActive.Count - 1;
    if LTop < 0 then
      Diag(ppUnbalancedElse, AFileId, AToken.Start, AToken.Len)
    else
    begin
      // NB: dcc tolerates MULTIPLE $ELSE in one chain (System.ObjAuto.pas
      // ships `...{$ELSE}...{$ELSE OTHERCPU}...`). Each $ELSE activates
      // iff no earlier branch was taken — so we deliberately do NOT error
      // on a repeated $ELSE.
      FCondSeenElse[LTop] := True;
      FCondThisActive[LTop] :=
        FCondParentActive[LTop] and not FCondAnyTaken[LTop];
      if FCondThisActive[LTop] then
        FCondAnyTaken[LTop] := True;
    end;
  end
  else if (LName = 'ENDIF') or (LName = 'IFEND') then
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
  else if LName = 'DEFINE' then
    FDefines.Define(LArg)
  else if LName = 'UNDEF' then
    FDefines.Undefine(LArg)
  else if (LName = 'I') or (LName = 'INCLUDE') then
  begin
    if (LArg <> '') and CharInSet(LArg[1], ['+', '-']) then
      // {$I+} / {$I-}: the IOCHECKS switch, not an include.
      FSwitches['I'] := LArg[1] = '+'
    else if (LArg <> '') and (LArg[1] = '%') then
      Diag(ppUnsupportedInsertion, AFileId, AToken.Start, AToken.Len, LArg)
    else if LName = 'I' then
      HandleInclude(AFileId, AToken, LArg)
    else
      HandleInclude(AFileId, AToken, LArg);
  end
  else if LName = 'PUSHOPT' then
  begin
    var LOpt: TPasOptState;
    LOpt.Switches := FSwitches;
    LOpt.ScopedEnums := FScopedEnums;
    FSwitchStack.Push(LOpt);
  end
  else if LName = 'POPOPT' then
  begin
    if FSwitchStack.Count > 0 then
    begin
      var LOpt := FSwitchStack.Pop;
      FSwitches := LOpt.Switches;
      SetScopedEnums(LOpt.ScopedEnums);
    end
    else
      Diag(ppPopWithoutPush, AFileId, AToken.Start, AToken.Len);
  end
  else if Length(LName) = 1 then
    // Single-letter switch directive(s): {$R-}, {$O+,W-}, {$Z4}, {$R *.res}
    ApplySwitches(LBody)
  else
    // Long-form switches we track; everything else is passthrough trivia.
    ApplyLongSwitch(LName, LArg);
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

  LStream := TPasLexer.Tokenize(FSourceManager.LoadText(LResolved));
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
  // Forms: X+  X-  X+,Y-  Xn (numeric: ignored)  X <arg> (e.g. $R res: ignored)
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
      LIdx := LIdx + 2;
      // Comma-separated list: {$O+,W-}
      while (LIdx <= Length(ABody)) and
        CharInSet(ABody[LIdx], [',', ' ', #9]) do
        Inc(LIdx);
    end
    else
      Exit; // {$Z4}, {$R *.res}, {$A8} etc. — no boolean state to track
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
    // the state at each enum's declaration site — see TPasScopedEnumsEvent.
    if SameText(AArg, 'ON') then
      SetScopedEnums(True)
    else if SameText(AArg, 'OFF') then
      SetScopedEnums(False);
  end;
  // Unknown names: passthrough (WARN, HINTS, REGION, HPPEMIT, RTTI, ...)
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

{ ---- $IF expression evaluator ---------------------------------------------

  Grammar, subset sufficient for real-world sources — star = repetition,
  brackets = optional. NB: no EBNF braces here, they would end this comment:
    OrExpr  = AndExpr (("or"/"xor") AndExpr)*
    AndExpr = RelExpr ("and" RelExpr)*
    RelExpr = AddExpr [relop AddExpr]         relop: = <> < > <= >=
    AddExpr = Term (("+"/"-") Term)*
    Term    = "not" Term / "(" OrExpr ")" / Value
    Value   = Defined(X) / Declared(X) / True / False
            / CompilerVersion / RTLVersion / SizeOf(X) / number / 'string'
  Unknown identifiers evaluate to False rather than failing. }

type
  TIfValueKind = (ivBool, ivNum, ivStr);

  TIfValue = record
    Kind: TIfValueKind;
    Bool: Boolean;
    Num: Double;
    Str: string;
  end;

  TIfEval = record
    Text: string;
    Pos: Integer;      // 1-based
    Failed: Boolean;
    HasUnknown: Boolean;  // expression referenced symbols we cannot resolve
    Defines: TPasDefines;
    OnDeclared: TPasDeclaredQuery;      // nil = nobody can answer Declared()
    UnknownDeclared: TArray<string>;    // ...and these are what it asked
    CompilerVersion: Double;
    PointerBytes: Integer;
    ExtendedBytes: Integer;
    procedure SkipWs;
    function Word: string;         // peeks+consumes an identifier
    function TryWord(const AWord: string): Boolean;
    function ParseOr: TIfValue;
    function ParseAnd: TIfValue;
    function ParseRel: TIfValue;
    function ParseAdd: TIfValue;
    function ParseTerm: TIfValue;
    function AsBool(const AValue: TIfValue): Boolean;
    function AsNum(const AValue: TIfValue): Double;
  end;

procedure TIfEval.SkipWs;
begin
  while (Pos <= Length(Text)) and CharInSet(Text[Pos], [' ', #9, #13, #10]) do
    Inc(Pos);
end;

function TIfEval.Word: string;
var
  LStart: Integer;
begin
  SkipWs;
  LStart := Pos;
  while (Pos <= Length(Text)) and
    CharInSet(Text[Pos], ['A'..'Z', 'a'..'z', '0'..'9', '_', '.']) do
    Inc(Pos);
  Result := Copy(Text, LStart, Pos - LStart);
end;

function TIfEval.TryWord(const AWord: string): Boolean;
var
  LSave: Integer;
  LWord: string;
begin
  LSave := Pos;
  LWord := Word;
  Result := SameText(LWord, AWord);
  if not Result then
    Pos := LSave;
end;

function TIfEval.AsBool(const AValue: TIfValue): Boolean;
begin
  case AValue.Kind of
    ivBool: Result := AValue.Bool;
    ivNum: Result := AValue.Num <> 0;
  else
    Result := AValue.Str <> '';
  end;
end;

function TIfEval.AsNum(const AValue: TIfValue): Double;
begin
  case AValue.Kind of
    ivNum: Result := AValue.Num;
    ivBool: Result := Ord(AValue.Bool);
  else
    Result := 0;
  end;
end;

function TIfEval.ParseOr: TIfValue;
var
  LRight: TIfValue;
  LIsXor: Boolean;
begin
  Result := ParseAnd;
  while True do
  begin
    LIsXor := False;
    if TryWord('or') then
      // fallthrough
    else if TryWord('xor') then
      LIsXor := True
    else
      Break;
    LRight := ParseAnd;
    Result.Kind := ivBool;
    if LIsXor then
      Result.Bool := AsBool(Result) xor AsBool(LRight)
    else
      Result.Bool := AsBool(Result) or AsBool(LRight);
  end;
end;

function TIfEval.ParseAnd: TIfValue;
var
  LRight: TIfValue;
begin
  Result := ParseRel;
  while TryWord('and') do
  begin
    LRight := ParseRel;
    Result.Kind := ivBool;
    Result.Bool := AsBool(Result) and AsBool(LRight);
  end;
end;

function TIfEval.ParseRel: TIfValue;
var
  LRight: TIfValue;
  LOp: string;
begin
  Result := ParseAdd;
  SkipWs;
  if Pos > Length(Text) then
    Exit;
  LOp := '';
  case Text[Pos] of
    '=': begin LOp := '='; Inc(Pos); end;
    '<':
      begin
        Inc(Pos);
        if (Pos <= Length(Text)) and (Text[Pos] = '>') then
        begin
          LOp := '<>'; Inc(Pos);
        end
        else if (Pos <= Length(Text)) and (Text[Pos] = '=') then
        begin
          LOp := '<='; Inc(Pos);
        end
        else
          LOp := '<';
      end;
    '>':
      begin
        Inc(Pos);
        if (Pos <= Length(Text)) and (Text[Pos] = '=') then
        begin
          LOp := '>='; Inc(Pos);
        end
        else
          LOp := '>';
      end;
  end;
  if LOp = '' then
    Exit;
  LRight := ParseAdd;
  if (Result.Kind = ivStr) and (LRight.Kind = ivStr) then
  begin
    if LOp = '=' then
      Result.Bool := SameText(Result.Str, LRight.Str)
    else if LOp = '<>' then
      Result.Bool := not SameText(Result.Str, LRight.Str)
    else
      Result.Bool := False;
  end
  else if LOp = '=' then
    Result.Bool := AsNum(Result) = AsNum(LRight)
  else if LOp = '<>' then
    Result.Bool := AsNum(Result) <> AsNum(LRight)
  else if LOp = '<' then
    Result.Bool := AsNum(Result) < AsNum(LRight)
  else if LOp = '>' then
    Result.Bool := AsNum(Result) > AsNum(LRight)
  else if LOp = '<=' then
    Result.Bool := AsNum(Result) <= AsNum(LRight)
  else
    Result.Bool := AsNum(Result) >= AsNum(LRight);
  Result.Kind := ivBool;
end;

function TIfEval.ParseAdd: TIfValue;
var
  LRight: TIfValue;
  LMinus: Boolean;
begin
  Result := ParseTerm;
  while True do
  begin
    SkipWs;
    if (Pos <= Length(Text)) and (Text[Pos] = '+') then
      LMinus := False
    else if (Pos <= Length(Text)) and (Text[Pos] = '-') then
      LMinus := True
    else
      Break;
    Inc(Pos);
    LRight := ParseTerm;
    Result.Num := AsNum(Result);
    if LMinus then
      Result.Num := Result.Num - AsNum(LRight)
    else
      Result.Num := Result.Num + AsNum(LRight);
    Result.Kind := ivNum;
  end;
end;

function TIfEval.ParseTerm: TIfValue;
var
  LWord, LArg: string;
  LStart: Integer;
  LNum: string;
  LKnown: Boolean;
begin
  Result.Kind := ivBool;
  Result.Bool := False;
  Result.Num := 0;
  Result.Str := '';
  SkipWs;
  if Pos > Length(Text) then
  begin
    Failed := True;
    Exit;
  end;

  // not X
  if TryWord('not') then
  begin
    Result := ParseTerm;
    Result.Bool := not AsBool(Result);
    Result.Kind := ivBool;
    Exit;
  end;

  case Text[Pos] of
    '(':
      begin
        Inc(Pos);
        Result := ParseOr;
        SkipWs;
        if (Pos <= Length(Text)) and (Text[Pos] = ')') then
          Inc(Pos)
        else
          Failed := True;
        Exit;
      end;
    '''':
      begin
        Inc(Pos);
        LStart := Pos;
        while (Pos <= Length(Text)) and (Text[Pos] <> '''') do
          Inc(Pos);
        Result.Kind := ivStr;
        Result.Str := Copy(Text, LStart, Pos - LStart);
        if Pos <= Length(Text) then
          Inc(Pos)
        else
          Failed := True;
        Exit;
      end;
    '0'..'9':
      begin
        LStart := Pos;
        while (Pos <= Length(Text)) and
          CharInSet(Text[Pos], ['0'..'9', '.', '_']) do
          Inc(Pos);
        LNum := Copy(Text, LStart, Pos - LStart).Replace('_', '');
        Result.Kind := ivNum;
        Result.Num := StrToFloatDef(LNum, 0,
          TFormatSettings.Invariant);
        Exit;
      end;
  end;

  LWord := Word;
  if LWord = '' then
  begin
    Failed := True;
    Exit;
  end;
  if SameText(LWord, 'True') then
  begin
    Result.Kind := ivBool;
    Result.Bool := True;
  end
  else if SameText(LWord, 'False') then
  begin
    Result.Kind := ivBool;
    Result.Bool := False;
  end
  else if SameText(LWord, 'Defined') or SameText(LWord, 'Declared') then
  begin
    SkipWs;
    if (Pos <= Length(Text)) and (Text[Pos] = '(') then
    begin
      Inc(Pos);
      LArg := Word;
      // Declared() takes a DESIGNATOR, not a bare identifier — the RTL writes
      // `Declared(System.Embedded)`. Stopping at the dot asks about `System`,
      // which is a unit name and answers True, taking the opposite branch.
      while (Pos <= Length(Text)) and (Text[Pos] = '.') do
      begin
        Inc(Pos);
        LArg := LArg + '.' + Word;
      end;
      SkipWs;
      if (Pos <= Length(Text)) and (Text[Pos] = ')') then
        Inc(Pos)
      else
        Failed := True;
      Result.Kind := ivBool;
      if SameText(LWord, 'Defined') then
        Result.Bool := Defines.IsDefined(LArg)
      else if Assigned(OnDeclared) and OnDeclared(LArg, LKnown) then
        // Somebody with a symbol table answered — see TPasDeclaredQuery. Not
        // flagged and not recorded, because it is not a guess.
        Result.Bool := LKnown
      else
      begin
        // Nobody can answer yet: Declared() asks whether an IDENTIFIER is in
        // scope, and the symbol table that knows is built from the token
        // stream this very decision produces. False is the branch taken —
        // there is no safer default, since the guarded text is by
        // construction the text that does NOT compile when the name IS
        // declared — but the NAME is recorded so a caller that does have a
        // symbol table can come back and ask properly.
        UnknownDeclared := UnknownDeclared + [LArg];
        HasUnknown := True;
        Result.Bool := False;
      end;
    end
    else
      Failed := True;
  end
  else if SameText(LWord, 'CompilerVersion') or SameText(LWord, 'RTLVersion')
  then
  begin
    Result.Kind := ivNum;
    Result.Num := CompilerVersion;
  end
  else if SameText(LWord, 'SizeOf') then
  begin
    // SizeOf(X) in $IF: assume 64-bit target defaults.
    SkipWs;
    if (Pos <= Length(Text)) and (Text[Pos] = '(') then
    begin
      Inc(Pos);
      LArg := Word;
      SkipWs;
      if (Pos <= Length(Text)) and (Text[Pos] = ')') then
        Inc(Pos)
      else
        Failed := True;
      Result.Kind := ivNum;
      if SameText(LArg, 'Pointer') or SameText(LArg, 'NativeInt') or
         SameText(LArg, 'NativeUInt') then
        Result.Num := PointerBytes
      else if SameText(LArg, 'Extended') then
        Result.Num := ExtendedBytes
      else if SameText(LArg, 'Int64') or SameText(LArg, 'UInt64') or
        SameText(LArg, 'Double') or SameText(LArg, 'Currency') then
        Result.Num := 8
      else if SameText(LArg, 'Integer') or SameText(LArg, 'Cardinal') or
        SameText(LArg, 'LongInt') or SameText(LArg, 'LongWord') or
        SameText(LArg, 'Single') then
        Result.Num := 4
      else if SameText(LArg, 'Char') or SameText(LArg, 'WideChar') or
        SameText(LArg, 'Word') or SameText(LArg, 'SmallInt') then
        Result.Num := 2
      else if SameText(LArg, 'AnsiChar') or SameText(LArg, 'Byte') or
        SameText(LArg, 'ShortInt') or SameText(LArg, 'Boolean') then
        Result.Num := 1
      else
      begin
        HasUnknown := True;
        Result.Num := 0;
      end;
    end
    else
      Failed := True;
  end
  else
  begin
    // Unknown identifier or pseudo-function (Ord(x), unit constants, ...):
    // only the semantic phase could resolve these. Consume a balanced
    // argument list if present, mark the expression, evaluate as False.
    HasUnknown := True;
    SkipWs;
    if (Pos <= Length(Text)) and (Text[Pos] = '(') then
    begin
      LStart := 1; // nesting depth
      Inc(Pos);
      while (Pos <= Length(Text)) and (LStart > 0) do
      begin
        case Text[Pos] of
          '(': Inc(LStart);
          ')': Dec(LStart);
        end;
        Inc(Pos);
      end;
      if LStart > 0 then
        Failed := True;
    end;
    Result.Kind := ivBool;
    Result.Bool := False;
  end;
end;

function TPasPreprocessor.EvalIfExpression(const AExpr: string;
  AFileId: Integer; const AToken: TPasToken): Boolean;
var
  LEval: TIfEval;
  LValue: TIfValue;
begin
  LEval := Default(TIfEval);
  LEval.Text := AExpr;
  LEval.Pos := 1;
  LEval.Defines := FDefines;
  LEval.OnDeclared := FOnDeclared;
  LEval.CompilerVersion := FCompilerVersion;
  LEval.PointerBytes := FPointerBytes;
  LEval.ExtendedBytes := FExtendedBytes;
  LValue := LEval.ParseOr;
  // Recorded even for an expression that FAILED to parse: the caller's only
  // use for these is deciding whether a second pass could learn anything, and
  // a half-parsed expression that mentioned a name is still such a case.
  for var LName in LEval.UnknownDeclared do
    if FUnresolvedDeclared.IndexOf(LName) < 0 then
      FUnresolvedDeclared.Add(LName);
  // NB: trailing junk after a complete expression is deliberately ignored —
  // dcc tolerates it (System.ObjAuto.pas ships '$IF SizeOf(Extended) >= 10)'
  // with a stray closing paren).
  if LEval.Failed then
  begin
    Diag(ppBadIfExpression, AFileId, AToken.Start, AToken.Len, AExpr);
    Exit(False);
  end;
  if LEval.HasUnknown then
    Diag(ppIfNeedsSemantics, AFileId, AToken.Start, AToken.Len, AExpr);
  Result := LEval.AsBool(LValue);
end;

end.
