program ResilienceSmoke;

{ Typing resilience of the parser and Phase 1.

  The module path analyzes the buffer at every pause in typing, and the
  differential harness proved that what the parser does with an UNFINISHED
  declaration decides whether an edit is a 200 ms module step or a 25 s
  rebuild with hundreds of false E2003 (docs/incremental-analysis.md 4b). Four
  such shapes were found one at a time, each by replaying a typing sequence
  against the client corpus. This suite enumerates them instead.

  For every (insertion point, snippet) below, every PREFIX of the snippet -
  each keystroke state - is typed into a fixture unit and analyzed through
  Phase 1. The invariant: every symbol the fixture had (kind, name, owner)
  is still there. The recovery may lose the declaration being typed; it must
  never lose a neighbour, and the analysis must never raise. A failure names
  the first prefix that breaks it and what went missing, which is exactly the
  reproduction the parser fix then needs.

  Win32 with range and overflow checks on, like every suite: a NextSib(-1)
  is a range error here and a stack overflow in the release build. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Generics.Collections,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.Sema.Diagnostics in '..\source\PasTree.Sema.Diagnostics.pas',
  PasTree.Sema.Model in '..\source\PasTree.Sema.Model.pas',
  PasTree.Sema.Builtins in '..\source\PasTree.Sema.Builtins.pas',
  PasTree.Sema.Resolver in '..\source\PasTree.Sema.Resolver.pas',
  PasTree.TestKit in 'PasTree.TestKit.pas';

const
  { One unit with every kind of declaration site. The at-marker comments (see the source) are the
    insertion points; a comment parses as nothing, so the untouched fixture is
    the baseline. }
  FIXTURE =
    'unit U;'#10 +
    'interface'#10 +
    'uses'#10 +
    '  System.Types,'#10 +
    '  {@USES}'#10 +
    '  System.Classes;'#10 +
    'type'#10 +
    '  THdr = packed record'#10 +
    '    Layout: Byte;'#10 +
    '    Check: LongWord;'#10 +
    '    {@REC}'#10 +
    '    Reserve: array[1..3] of Byte;'#10 +
    '  end;'#10 +
    '  {@TYPE}'#10 +
    '  TRecno = Integer;'#10 +
    '  TKind = (kA, kB);'#10 +
    '  IA = interface'#10 +
    '    [''{6BD11B25-82E3-4C87-8E99-AE4C313F12A9}'']'#10 +
    '    procedure M;'#10 +
    '    {@INTF}'#10 +
    '    function GetP: Integer;'#10 +
    '    property P: Integer read GetP;'#10 +
    '  end;'#10 +
    '  TC = class(TObject)'#10 +
    '  private'#10 +
    '    FX: Integer;'#10 +
    '    {@CLASS}'#10 +
    '    procedure Q;'#10 +
    '  public'#10 +
    '    property X: Integer read FX;'#10 +
    '  end;'#10 +
    'const'#10 +
    '  C1 = 1;'#10 +
    '  {@CONST}'#10 +
    '  C2 = 2;'#10 +
    'var'#10 +
    '  V1: Integer;'#10 +
    '  {@VAR}'#10 +
    '  V2: Byte;'#10 +
    'procedure GlobalProc(A: Integer);'#10 +
    '{@DECL}'#10 +
    'function GlobalFunc: string;'#10 +
    'implementation'#10 +
    'procedure GlobalProc(A: Integer); begin end;'#10 +
    '{@IMPL}'#10 +
    'function GlobalFunc: string; begin Result := ''''; end;'#10 +
    'procedure TC.Q;'#10 +
    'var L: Integer;'#10 +
    'begin'#10 +
    '  {@BODY}'#10 +
    '  L := 1;'#10 +
    'end;'#10 +
    'end.'#10;

type
  TCase = record
    Marker: string;   // which at-marker the snippet goes into
    Snippet: string;  // typed prefix by prefix
    { Symbol keys (kind|name|owner) that MAY go missing for this snippet, with
      the reason in the case. Only for a typing state that is token-identical
      to valid code the corpora contain, where the parser must choose the
      valid reading: the loss is then the price of not breaking real units. }
    Allowed: string;
  end;

const
  CASES: array[0..27] of TCase = (
    (Marker: 'USES'; Snippet: 'System.SysUtils,'),
    (Marker: 'REC'; Snippet: 'Extra: Integer;'),
    (Marker: 'REC'; Snippet: 'F1, F2: array[1..3] of Byte;'),
    (Marker: 'REC'; Snippet: 'case Tag: Byte of 0: (A: Integer); 1: (B: Byte);'),
    (Marker: 'TYPE'; Snippet: 'TNew = Integer;'),
    (Marker: 'TYPE'; Snippet: 'TG = class(TObject) procedure Z; end;'),
    // `procedure(A:` above `TRecno = Integer;` reads as a parameter of type
    // TRecno with default Integer - the same tokens as a wrapped parameter
    // `AAlign:` NEWLINE `TSeGlyphAlign = kgfaCenter)` in Vcl.StyleAPI, which
    // must keep parsing clean. TRecno is lost for that one keystroke.
    (Marker: 'TYPE'; Snippet: 'TP = procedure(A: Integer) of object;';
     Allowed: '0|trecno|'),
    (Marker: 'TYPE'; Snippet: 'TE = (eA, eB);'),
    (Marker: 'TYPE'; Snippet: 'TS = set of TKind;'),
    (Marker: 'TYPE'; Snippet: 'TR = record A: Integer; end;'),
    (Marker: 'TYPE'; Snippet: 'TL = TList<Integer>;'),
    (Marker: 'TYPE'; Snippet: 'TArr = array of string;'),
    (Marker: 'TYPE'; Snippet: 'PInt = ^Integer;'),
    (Marker: 'INTF'; Snippet: 'function GetN: Integer;'),
    (Marker: 'INTF'; Snippet: 'property N: Integer read GetN;'),
    (Marker: 'CLASS'; Snippet: 'FY: Integer;'),
    (Marker: 'CLASS'; Snippet: 'procedure R(A: Integer); virtual;'),
    (Marker: 'CLASS'; Snippet: 'property Y: Integer read FX write FX;'),
    (Marker: 'CLASS'; Snippet: 'class var CV: Integer;'),
    (Marker: 'CLASS'; Snippet: 'type TInner = Integer;'),
    (Marker: 'CLASS'; Snippet: 'const CI = 1;'),
    (Marker: 'CONST'; Snippet: 'C3 = 3;'),
    // `C4:` above `C2 = 2;` reads as a typed constant of type C2 with value 2 -
    // the same tokens as a wrapped typed constant `X: array[..] of` NEWLINE
    // `TClass = (nil, ...)` in a client unit, which must keep parsing clean.
    // C2 is lost for that one keystroke.
    (Marker: 'CONST'; Snippet: 'C4: Integer = 4;'; Allowed: '2|c2|'),
    (Marker: 'VAR'; Snippet: 'V3: Integer;'),
    (Marker: 'VAR'; Snippet: 'V4, V5: Byte;'),
    (Marker: 'DECL'; Snippet: 'procedure NewProc(A: Integer);'),
    (Marker: 'IMPL'; Snippet: 'procedure ImplProc; begin end;'),
    (Marker: 'BODY'; Snippet: 'if L > 0 then L := L - 1;')
  );

var
  GSM: TPasSourceManager;
  GDefines: TPasDefines;
  GPP: TPasPreprocessor;
  GCounter: TPasSuiteCounter;

// Phase 1 over one text. Raises what the analysis raises - that IS a failure.
function AnalyzeText(const ASource: string): TPasSemaModel;
var
  LPre: TPasPreprocessed;
  LDiags: TArray<TPasParseDiag>;
  LTree: TPasTree;
begin
  LPre := GPP.ProcessText('U.pas', ASource);
  LTree := TPasParser.ParseFile(LPre, LDiags);
  Result := TPasSemaResolver.Analyze(LTree);
end;

{ Every symbol as `kind|name|owner`, owner = the name of the type or routine
  whose scope declares it ('' at unit level). Names, never indices: the
  indices are exactly what an insertion moves. Builtins (the System scope's
  seed) are skipped - they are the same in every model. }
function SymbolKeys(AModel: TPasSemaModel): TDictionary<string, Integer>;
var
  LOwner: TArray<string>;
  LIdx, LScope: Integer;
  LKey: string;
  LCount: Integer;
begin
  Result := TDictionary<string, Integer>.Create;
  SetLength(LOwner, AModel.Scopes.Count);
  for LIdx := 0 to AModel.SymCount - 1 do
    if (AModel.Symbols[LIdx].MemberScope <> NIL_SCOPE) and
       (AModel.Symbols[LIdx].MemberScope <= High(LOwner)) and
       (LOwner[AModel.Symbols[LIdx].MemberScope] = '') then
      LOwner[AModel.Symbols[LIdx].MemberScope] := AModel.Symbols[LIdx].NameLower;
  for LIdx := 0 to AModel.SymCount - 1 do
  begin
    LScope := AModel.Symbols[LIdx].Scope;
    if (LScope <> NIL_SCOPE) and (AModel.Scopes[LScope].Kind = sckSystem) then
      Continue;
    if AModel.Symbols[LIdx].DeclNode = NIL_NODE then
      Continue;
    LKey := Format('%d|%s|%s', [Ord(AModel.Symbols[LIdx].Kind),
      AModel.Symbols[LIdx].NameLower, LOwner[LScope]]);
    if Result.TryGetValue(LKey, LCount) then
      Result[LKey] := LCount + 1
    else
      Result.Add(LKey, 1);
  end;
end;

// The keys of ABase that AOther lacks (or has fewer of), for the report -
// minus the case's allowed losses.
function Missing(ABase, AOther: TDictionary<string, Integer>;
  const AAllowed: string): string;
var
  LCount: Integer;
begin
  Result := '';
  for var LPair in ABase do
  begin
    if not AOther.TryGetValue(LPair.Key, LCount) then
      LCount := 0;
    if (LCount < LPair.Value) and
       (Pos(' ' + LPair.Key + ' ', ' ' + AAllowed + ' ') = 0) then
    begin
      if Result <> '' then
        Result := Result + ' ';
      Result := Result + LPair.Key;
      if Length(Result) > 160 then
        Exit(Result + ' ...');
    end;
  end;
end;

function WithMarker(const AMarker, AText: string): string;
begin
  Result := StringReplace(FIXTURE, '{@' + AMarker + '}', AText, [rfReplaceAll]);
end;

procedure RunCase(const ACase: TCase);
var
  LBase, LNow: TDictionary<string, Integer>;
  LModel: TPasSemaModel;
  LPrefix, LLost, LFirstBad, LName: string;
  LLen, LBadCount: Integer;
begin
  LModel := AnalyzeText(FIXTURE);
  try
    LBase := SymbolKeys(LModel);
  finally
    LModel.Free;
  end;
  LFirstBad := '';
  LBadCount := 0;
  try
    for LLen := 1 to Length(ACase.Snippet) do
    begin
      LPrefix := Copy(ACase.Snippet, 1, LLen);
      try
        LModel := AnalyzeText(WithMarker(ACase.Marker, LPrefix));
      except
        on E: Exception do
        begin
          Inc(LBadCount);
          if LFirstBad = '' then
            LFirstBad := Format('"%s" raised %s: %s', [LPrefix, E.ClassName, E.Message]);
          Continue;
        end;
      end;
      try
        LNow := SymbolKeys(LModel);
        try
          LLost := Missing(LBase, LNow, ACase.Allowed);
        finally
          LNow.Free;
        end;
      finally
        LModel.Free;
      end;
      if LLost <> '' then
      begin
        Inc(LBadCount);
        if LFirstBad = '' then
          LFirstBad := Format('"%s" lost: %s', [LPrefix, LLost]);
      end;
    end;
  finally
    LBase.Free;
  end;
  LName := Format('%s <- %s', [ACase.Marker, ACase.Snippet]);
  GCounter.Ok(LName, LBadCount = 0,
    procedure
    begin
      Writeln(Format('  %d of %d prefixes broke the fixture; first: %s',
        [LBadCount, Length(ACase.Snippet), LFirstBad]));
    end);
end;

var
  LCase: TCase;
begin
  GSM := TPasSourceManager.Create([]);
  GDefines := TPasDefines.Create(['MSWINDOWS', 'WIN32']);
  GPP := TPasPreprocessor.Create(GSM, GDefines);
  try
    GCounter.Init;
    for LCase in CASES do
      RunCase(LCase);
    if GCounter.Finish('ResilienceSmoke') then
      ExitCode := 1;
  finally
    GPP.Free;
    GDefines.Free;
    GSM.Free;
  end;
end.
