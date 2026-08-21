program SemaCompleteSmoke;

{ Caret-primitive smoke tests for code completion (stage A): given a source
  with a `|` caret marker, TPasCompletion.CaretAt must classify the position
  (prefix / after-dot / fresh / none), anchor it to the right token and node,
  find the scope in effect, and expose the member-access base for a dot.
  Mirrors SemaSmoke's harness: one fixture analyzed, several Ok() asserts
  against it. The caret cases deliberately include the parser-recovery
  shapes the plan calls traps: `Foo.` stealing the next line's identifier,
  carets in trivia, comments, strings and $IFDEF'd-out regions. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
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
  PasTree.Sema.Complete in '..\source\PasTree.Sema.Complete.pas',
  PasTree.TestKit in 'PasTree.TestKit.pas';

var
  GSM: TPasSourceManager;
  GDefines: TPasDefines;
  GPP: TPasPreprocessor;
  GCounter: TPasSuiteCounter;
  GModel: TPasSemaModel;
  GTree: TPasTree;
  GComp: TPasCompletion;
  GInfo: TPasCaretInfo;
  GHit: Boolean;

{ Parses/analyzes ASource with its single `|` caret marker STRIPPED, then runs
  CaretAt at the marker's (line, col). The marker means "the caret is here";
  what the analysis sees never contains it. }
procedure CaretCase(const ASource: string);
var
  LAt, LIdx, LLine, LCol: Integer;
  LClean: string;
  LPre: TPasPreprocessed;
  LDiags: TArray<TPasParseDiag>;
begin
  LAt := Pos('|', ASource);
  if LAt = 0 then
    raise Exception.Create('caret case has no | marker');
  LClean := StringReplace(ASource, '|', '', []);
  LLine := 1;
  LCol := LAt;
  for LIdx := 1 to LAt - 1 do
    if ASource[LIdx] = #10 then
    begin
      Inc(LLine);
      LCol := LAt - LIdx;
    end;

  GComp.Free;
  GComp := nil;
  GModel.Free;
  LPre := GPP.ProcessText('test.pas', LClean);
  GTree := TPasParser.ParseFile(LPre, LDiags);
  GModel := TPasSemaResolver.Analyze(GTree);
  GComp := TPasCompletion.Create(GModel);
  GHit := GComp.CaretAt(LLine, LCol, GInfo);
end;

// The scope chain at the caret resolves ANameLower (the assertion that the
// caret landed in the RIGHT scope, not merely in some scope).
function ScopeSees(const ANameLower: string): Boolean;
begin
  Result := (GInfo.Scope <> NIL_SCOPE) and
    (GModel.ResolveAt(GInfo.Scope, ANameLower, -1) <> NIL_SYM);
end;

function DotBaseText: string;
begin
  if GInfo.DotBase = NIL_NODE then
    Result := ''
  else
    Result := GTree.NodeText(GInfo.DotBase);
end;

function StructName: string;
var
  LSym: Integer;
begin
  LSym := GComp.EnclosingStructSym(GInfo.Scope);
  if LSym = NIL_SYM then
    Result := ''
  else
    Result := GModel.Symbols[LSym].Name;
end;

const
  // One unit, reused by most carets: a record type with members, a global,
  // and a routine with a local of that type.
  FIXTURE_HEAD =
    'unit u;'#10 +
    'interface'#10 +
    'type'#10 +
    '  TPoint = record'#10 +
    '    X, Y: Integer;'#10 +
    '  end;'#10 +
    'var'#10 +
    '  GTotal: Integer;'#10 +
    'implementation'#10 +
    'procedure P;'#10 +
    'var'#10 +
    '  Foo: TPoint;'#10 +
    'begin'#10;
  FIXTURE_TAIL =
    'end;'#10 +
    'end.'#10;

begin
  GSM := TPasSourceManager.Create([]);
  GDefines := TPasDefines.Create(['MSWINDOWS', 'WIN32']);
  GPP := TPasPreprocessor.Create(GSM, GDefines);
  GCounter.Init;

  // --- dot completion, empty prefix -----------------------------------------
  CaretCase(FIXTURE_HEAD + '  Foo.|'#10 + FIXTURE_TAIL);
  GCounter.Ok('Foo.| classifies ckAfterDot', GHit and (GInfo.Kind = ckAfterDot));
  GCounter.Ok('Foo.| base is the Foo expression', DotBaseText = 'Foo');
  GCounter.Ok('Foo.| scope sees the local', ScopeSees('foo'));
  GCounter.Ok('Foo.| scope sees the unit global through the chain',
    ScopeSees('gtotal'));
  GCounter.Ok('Foo.| prefix is empty', GInfo.Prefix = '');

  // The parser adopts the NEXT LINE's identifier as the member name (`Foo.X`
  // out of `Foo.` + `X := 1;`). The caret answer must be immune: still a dot
  // position, still base Foo — the stolen name is what completion REPLACES.
  CaretCase(FIXTURE_HEAD + '  Foo.|'#10'  GTotal := 1;'#10 + FIXTURE_TAIL);
  GCounter.Ok('next-line theft: still ckAfterDot',
    GHit and (GInfo.Kind = ckAfterDot));
  GCounter.Ok('next-line theft: base is still Foo', DotBaseText = 'Foo');

  // A caret past the end of the line (virtual space) clamps to the line end.
  // Reuses the previous fixture's analysis, re-asking at a far column of the
  // `  Foo.` line (line 14 of the fixture).
  CaretCase(FIXTURE_HEAD + '  Foo.|'#10 + FIXTURE_TAIL);
  GHit := GComp.CaretAt(14, 200, GInfo);
  GCounter.Ok('caret past EOL clamps and still answers ckAfterDot',
    GHit and (GInfo.Kind = ckAfterDot) and (DotBaseText = 'Foo'));

  // --- dot completion, prefix being typed ------------------------------------
  CaretCase(FIXTURE_HEAD + '  Foo.Ba|'#10 + FIXTURE_TAIL);
  GCounter.Ok('Foo.Ba| classifies ckIdent', GHit and (GInfo.Kind = ckIdent));
  GCounter.Ok('Foo.Ba| prefix is Ba', GInfo.Prefix = 'Ba');
  GCounter.Ok('Foo.Ba| base is Foo', DotBaseText = 'Foo');

  // Mid-word invocation: the prefix stops at the caret, the replace range
  // covers the whole word.
  CaretCase(FIXTURE_HEAD + '  Foo.X| := 1;'#10 + FIXTURE_TAIL);
  GCounter.Ok('Foo.X| prefix is X', GHit and (GInfo.Prefix = 'X'));
  GCounter.Ok('Foo.X| replace range is one column wide',
    GInfo.PrefixColTo = GInfo.PrefixColFrom + 1);

  CaretCase(FIXTURE_HEAD + '  GTo|tal := 1;'#10 + FIXTURE_TAIL);
  GCounter.Ok('GTo|tal prefix stops at the caret',
    GHit and (GInfo.Kind = ckIdent) and (GInfo.Prefix = 'GTo'));
  GCounter.Ok('GTo|tal replace range covers the whole word',
    GInfo.PrefixColTo - GInfo.PrefixColFrom = 6);
  GCounter.Ok('GTo|tal is not a member position', GInfo.DotBase = NIL_NODE);

  // A RESERVED word under the caret is still a prefix (`th` of `then`) — the
  // candidate list legitimately contains keywords.
  CaretCase(FIXTURE_HEAD + '  if True th|en GTotal := 1;'#10 + FIXTURE_TAIL);
  GCounter.Ok('caret inside a keyword is a prefix',
    GHit and (GInfo.Kind = ckIdent) and (GInfo.Prefix = 'th'));

  // --- fresh (empty-prefix) positions ----------------------------------------
  CaretCase(FIXTURE_HEAD + '  |'#10'  GTotal := 1;'#10 + FIXTURE_TAIL);
  GCounter.Ok('statement position classifies ckFresh',
    GHit and (GInfo.Kind = ckFresh));
  GCounter.Ok('statement position scope sees the local', ScopeSees('foo'));

  CaretCase(
    'unit u;'#10 +
    'interface'#10 +
    '|'#10 +
    'implementation'#10 +
    'end.'#10);
  GCounter.Ok('interface-section caret classifies ckFresh',
    GHit and (GInfo.Kind = ckFresh));
  GCounter.Ok('interface-section caret lands in the unit scope',
    (GInfo.Scope <> NIL_SCOPE) and
    (GModel.Scopes[GInfo.Scope].Kind = sckUnit));

  // --- struct context ---------------------------------------------------------
  CaretCase(
    'unit u;'#10 +
    'interface'#10 +
    'type'#10 +
    '  TFoo = class'#10 +
    '    FBar: Integer;'#10 +
    '    |'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'end.'#10);
  GCounter.Ok('caret inside a class declaration sees the struct',
    GHit and (StructName = 'TFoo'));

  CaretCase(
    'unit u;'#10 +
    'interface'#10 +
    'type'#10 +
    '  TFoo = class'#10 +
    '    procedure M;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure TFoo.M;'#10 +
    'begin'#10 +
    '  |'#10 +
    'end;'#10 +
    'end.'#10);
  GCounter.Ok('caret inside a method body sees the struct (Self context)',
    GHit and (StructName = 'TFoo'));
  GCounter.Ok('caret inside a method body has an enclosing routine',
    GInfo.Routine <> NIL_NODE);

  // --- refusals ---------------------------------------------------------------
  CaretCase(FIXTURE_HEAD + '  { a comm|ent }'#10 + FIXTURE_TAIL);
  GCounter.Ok('caret inside a comment refuses', not GHit);

  CaretCase(FIXTURE_HEAD + '  GTotal := Ord(''a|b'');'#10 + FIXTURE_TAIL);
  GCounter.Ok('caret inside a string literal refuses', not GHit);

  CaretCase(FIXTURE_HEAD + '  GTotal := 12|34;'#10 + FIXTURE_TAIL);
  GCounter.Ok('caret inside a number literal refuses', not GHit);

  CaretCase(FIXTURE_HEAD +
    '{$IFDEF NEVER_DEFINED}'#10'  Foo|'#10'{$ENDIF}'#10 + FIXTURE_TAIL);
  GCounter.Ok('caret in an $IFDEF''d-out region refuses', not GHit);

  CaretCase('|unit u;'#10'interface'#10'implementation'#10'end.'#10);
  GCounter.Ok('caret at the very start of the file refuses', not GHit);

  // After the final `end.` dot there is no member access: an after-dot
  // classification with NO base — the classifier upstairs sees DotBase =
  // NIL_NODE and offers nothing.
  CaretCase('unit u;'#10'interface'#10'implementation'#10'end.|'#10);
  GCounter.Ok('the end. dot is after-dot with no base',
    GHit and (GInfo.Kind = ckAfterDot) and (GInfo.DotBase = NIL_NODE));

  if GCounter.Finish('SemaCompleteSmoke') then
    ExitCode := 1;
  GComp.Free;
  GModel.Free;
  GPP.Free;
  GDefines.Free;
  GSM.Free;
end.
