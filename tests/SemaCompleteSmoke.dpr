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
  System.IOUtils,
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
  PasTree.Sema.Project in '..\source\PasTree.Sema.Project.pas',
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
  // stage C: the mini-project the bridged collection cases run against
  GProj: TPasSemaProject;
  GProjMid: Integer;
  GCtx: TPasComplContext;
  GItems: TArray<TPasComplItem>;
  // §8: signature help
  GCall: TPasCallInfo;

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

{ Like CaretCase, but BRIDGED: the overlay is parsed against the mini-project
  built in the main block (GProj/GProjMid), and the whole CompleteAt pipeline
  runs — context classification plus candidate collection. }
procedure ProjCase(const ASource: string);
var
  LAt, LIdx, LLine, LCol: Integer;
  LClean: string;
  LPre: TPasPreprocessed;
  LDiags: TArray<TPasParseDiag>;
begin
  LAt := Pos('|', ASource);
  if LAt = 0 then
    raise Exception.Create('proj case has no | marker');
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
  LPre := GPP.ProcessText('mainu.pas', LClean);
  GTree := TPasParser.ParseFile(LPre, LDiags);
  GModel := TPasSemaResolver.Analyze(GTree);
  GComp := TPasCompletion.Create(GModel, GProj, GProjMid);
  GHit := GComp.CompleteAt(LLine, LCol, GInfo, GCtx, GItems);
end;

{ Like ProjCase, but runs CallAt at the marker — the §8B signature-help
  primitive over the same bridged mini-project. }
procedure CallCase(const ASource: string);
var
  LAt, LIdx, LLine, LCol: Integer;
  LClean: string;
  LPre: TPasPreprocessed;
  LDiags: TArray<TPasParseDiag>;
begin
  LAt := Pos('|', ASource);
  if LAt = 0 then
    raise Exception.Create('call case has no | marker');
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
  LPre := GPP.ProcessText('mainu.pas', LClean);
  GTree := TPasParser.ParseFile(LPre, LDiags);
  GModel := TPasSemaResolver.Analyze(GTree);
  GComp := TPasCompletion.Create(GModel, GProj, GProjMid);
  GHit := GComp.CallAt(LLine, LCol, GCall);
end;

// Number of CallAt targets carrying AName — the overload count, since
// CallAt reports each overload as its own target.
function TargetsNamed(const AName: string): Integer;
var
  LIdx: Integer;
begin
  Result := 0;
  for LIdx := 0 to High(GCall.Targets) do
    if SameText(GCall.Targets[LIdx].Name, AName) then
      Inc(Result);
end;

function TargetOf(const AName: string): TPasCallTarget;
var
  LIdx: Integer;
begin
  for LIdx := 0 to High(GCall.Targets) do
    if SameText(GCall.Targets[LIdx].Name, AName) then
      Exit(GCall.Targets[LIdx]);
  Result := Default(TPasCallTarget);
end;

function ItemNamed(const AName: string): TPasComplItem;
var
  LIdx: Integer;
begin
  for LIdx := 0 to High(GItems) do
    if SameText(GItems[LIdx].Name, AName) then
      Exit(GItems[LIdx]);
  Result := Default(TPasComplItem);
  Result.Sym := NIL_SYM;
end;

function Has(const AName: string): Boolean;
var
  LIdx: Integer;
begin
  for LIdx := 0 to High(GItems) do
    if SameText(GItems[LIdx].Name, AName) then
      Exit(True);
  Result := False;
end;

function BucketOf(const AName: string): TPasComplBucket;
var
  LIdx: Integer;
begin
  for LIdx := 0 to High(GItems) do
    if SameText(GItems[LIdx].Name, AName) then
      Exit(GItems[LIdx].Bucket);
  Result := cbKeyword;   // "not found" reads as the wrong bucket in a FAIL
end;

function OverloadsOf(const AName: string): Integer;
var
  LIdx: Integer;
begin
  for LIdx := 0 to High(GItems) do
    if SameText(GItems[LIdx].Name, AName) then
      Exit(GItems[LIdx].Overloads);
  Result := -1;
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

  // The mini-project (self-contained, no RTL on the path — deliberately, so
  // the suite stays a unit test: builtins remain seeds and TObject has no
  // real body to walk into).
  EXTA_UNIT =
    'unit exta;'#10 +
    'interface'#10 +
    'type'#10 +
    '  TBase = class'#10 +
    '  private'#10 +
    '    FSecret: Integer;'#10 +
    '  protected'#10 +
    '    FProt: Integer;'#10 +
    '  public'#10 +
    '    constructor Create;'#10 +
    '    class function CF: Integer;'#10 +
    '    procedure Pub;'#10 +
    '    procedure Over(A: Integer); overload;'#10 +
    '    procedure Over(A: string); overload;'#10 +
    '    property Prop: Integer read FProt;'#10 +
    '  end;'#10 +
    '  TExtGen<T> = class'#10 +
    '  public'#10 +
    '    procedure Put(AValue: T);'#10 +
    '    function Get: T;'#10 +
    '  end;'#10 +
    'procedure ExtProc;'#10 +
    'var'#10 +
    '  ExtVar: Integer;'#10 +
    'implementation'#10 +
    'constructor TBase.Create;'#10'begin'#10'end;'#10 +
    'class function TBase.CF: Integer;'#10'begin'#10'  Result := 0;'#10 +
    'end;'#10 +
    'procedure TBase.Pub;'#10'begin'#10'end;'#10 +
    'procedure TBase.Over(A: Integer);'#10'begin'#10'end;'#10 +
    'procedure TBase.Over(A: string);'#10'begin'#10'end;'#10 +
    'procedure TExtGen<T>.Put(AValue: T);'#10'begin'#10'end;'#10 +
    'function TExtGen<T>.Get: T;'#10'begin'#10'end;'#10 +
    'procedure ExtProc;'#10'begin'#10'end;'#10 +
    'end.'#10;
  PROJ_HEAD =                       // lines 1..21; the case line is 22
    'unit mainu;'#10 +
    'interface'#10 +
    'uses exta;'#10 +
    'type'#10 +
    '  TMy = class(TBase)'#10 +
    '  public'#10 +
    '    procedure Own;'#10 +
    '  end;'#10 +
    '  TArr = array of TBase;'#10 +
    '  PBase = ^TBase;'#10 +
    'implementation'#10 +
    'var'#10 +
    '  ImplVar: Integer;'#10 +
    'procedure TMy.Own;'#10 +
    'var'#10 +
    '  B: TBase;'#10 +
    '  G: TExtGen<Integer>;'#10 +
    '  M: TMy;'#10 +
    '  Arr: TArr;'#10 +
    '  PB: PBase;'#10 +
    'begin'#10;
  PROJ_TAIL =
    'end;'#10 +
    'end.'#10;

var
  GDir: string;

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

  // ======== stage C: context classification + bridged collection ==========
  GDir := TPath.Combine(TPath.GetTempPath, 'pastree_complete_smoke');
  if TDirectory.Exists(GDir) then
    TDirectory.Delete(GDir, True);
  TDirectory.CreateDirectory(GDir);
  TFile.WriteAllText(TPath.Combine(GDir, 'exta.pas'), EXTA_UNIT);
  // Never used by anything: only the search-path directory scan can offer
  // this one in a uses clause (the analyzed closure cannot).
  TFile.WriteAllText(TPath.Combine(GDir, 'Unused.Extb.pas'),
    'unit Unused.Extb;'#10'interface'#10'implementation'#10'end.'#10);
  TFile.WriteAllText(TPath.Combine(GDir, 'mainu.pas'),
    PROJ_HEAD + PROJ_TAIL);
  GProj := TPasSemaProject.Create(pfWin32, [GDir], []);
  GProjMid := GProj.AnalyzeProject(TPath.Combine(GDir, 'mainu.pas'));
  GCounter.Ok('mini-project analyzed', GProjMid >= 0);

  // --- member completion on a bridged type ---------------------------------
  ProjCase(PROJ_HEAD + '  B.|'#10 + PROJ_TAIL);
  GCounter.Ok('B.| classifies ccMember', GHit and (GCtx = ccMember));
  GCounter.Ok('B.| lists the public method', Has('Pub'));
  GCounter.Ok('B.| lists the property', Has('Prop'));
  GCounter.Ok('B.| lists the protected field (caret struct descends)',
    Has('FProt'));
  GCounter.Ok('B.| hides the private field of another unit',
    not Has('FSecret'));
  GCounter.Ok('B.| collapses the overload pair into one item',
    Has('Over') and (OverloadsOf('Over') = 1));

  // The parser steals the next line's identifier as the member name; the
  // LIST must be the same as for a clean trailing dot.
  ProjCase(PROJ_HEAD + '  B.|'#10'  ImplVar := 1;'#10 + PROJ_TAIL);
  GCounter.Ok('next-line theft: list still holds the members',
    GHit and (GCtx = ccMember) and Has('Pub'));

  // Instance of the OWN class: own members + bridged inherited ones.
  ProjCase(PROJ_HEAD + '  M.|'#10 + PROJ_TAIL);
  GCounter.Ok('M.| lists the own method', Has('Own'));
  GCounter.Ok('M.| lists the inherited method', Has('Pub'));

  // Class-side (type reference): constructors and class methods, not
  // instance members.
  ProjCase(PROJ_HEAD + '  TBase.|'#10 + PROJ_TAIL);
  GCounter.Ok('TBase.| lists the constructor', Has('Create'));
  GCounter.Ok('TBase.| lists the class function', Has('CF'));
  GCounter.Ok('TBase.| hides instance methods', not Has('Pub'));
  GCounter.Ok('TBase.| hides instance fields', not Has('FProt'));

  // Generic instantiation declared in the OVERLAY.
  ProjCase(PROJ_HEAD + '  G.|'#10 + PROJ_TAIL);
  GCounter.Ok('G.| lists the generic''s method', Has('Put'));

  // Indexing and dereferencing in the OVERLAY (no ExprTypeX cache there).
  ProjCase(PROJ_HEAD + '  Arr[0].|'#10 + PROJ_TAIL);
  GCounter.Ok('Arr[0].| lists the element type''s members', Has('Pub'),
    procedure
    begin
      Writeln('    ctx=', Ord(GCtx), ' items=', Length(GItems));
      for var LFi := 0 to High(GItems) do
        Writeln('      ', GItems[LFi].Name, ' mid=', GItems[LFi].Mid,
          ' sym=', GItems[LFi].Sym);
    end);
  ProjCase(PROJ_HEAD + '  PB^.|'#10 + PROJ_TAIL);
  GCounter.Ok('PB^.| lists the pointee''s members', Has('Pub'),
    procedure
    begin
      Writeln('    ctx=', Ord(GCtx), ' items=', Length(GItems));
    end);

  // `inherited |` — the ancestor's members, not the own class's.
  ProjCase(PROJ_HEAD + '  inherited |'#10 + PROJ_TAIL);
  GCounter.Ok('inherited | classifies ccInherited',
    GHit and (GCtx = ccInherited));
  GCounter.Ok('inherited | lists the ancestor method', Has('Pub'));
  GCounter.Ok('inherited | does not list the own method', not Has('Own'));

  // `goto |` — labels only.
  ProjCase(
    'unit mainu;'#10 +
    'interface'#10 +
    'implementation'#10 +
    'procedure P;'#10 +
    'label'#10 +
    '  Again;'#10 +
    'begin'#10 +
    '  Again:'#10 +
    '  goto |'#10 +
    'end;'#10 +
    'end.'#10);
  GCounter.Ok('goto | classifies ccLabel', GHit and (GCtx = ccLabel));
  GCounter.Ok('goto | lists the label', Has('Again'));
  GCounter.Ok('goto | lists nothing else', Length(GItems) = 1);

  // --- unqualified scope ----------------------------------------------------
  ProjCase(PROJ_HEAD + '  |'#10 + PROJ_TAIL);
  GCounter.Ok('body caret classifies ccStatement',
    GHit and (GCtx = ccStatement));
  GCounter.Ok('body: the local, as a local',
    Has('B') and (BucketOf('B') = cbLocal));
  GCounter.Ok('body: the own struct method through the join',
    Has('Own') and (BucketOf('Own') = cbStructMember));
  GCounter.Ok('body: the INHERITED method through the bridge',
    Has('Pub') and (BucketOf('Pub') = cbStructMember));
  GCounter.Ok('body: the implementation-section global', Has('ImplVar'));
  GCounter.Ok('body: the used unit''s routine, as an import',
    Has('ExtProc') and (BucketOf('ExtProc') = cbUses));
  GCounter.Ok('body: the used unit''s type', Has('TBase'));
  GCounter.Ok('body: a statement keyword', Has('begin'));
  GCounter.Ok('body: a compiler seed, as a builtin',
    Has('Integer') and (BucketOf('Integer') = cbBuiltin));

  // Interface-section caret: implementation names and implementation-only
  // uses must not leak (here: ImplVar).
  ProjCase(
    'unit mainu;'#10 +
    'interface'#10 +
    'uses exta;'#10 +
    '|'#10 +
    'implementation'#10 +
    'end.'#10);
  GCounter.Ok('interface: uses imports visible', Has('ExtProc'));
  GCounter.Ok('interface: declaration keywords', Has('type'));

  // --- type position --------------------------------------------------------
  ProjCase(PROJ_HEAD + '  var X: |'#10 + PROJ_TAIL);
  GCounter.Ok('var X: classifies ccType', GHit and (GCtx = ccType));
  GCounter.Ok('type position lists types', Has('TBase') and Has('TMy'));
  GCounter.Ok('type position filters non-types', not Has('ExtProc'));
  GCounter.Ok('type position keyword', Has('array'));

  // --- uses clause ----------------------------------------------------------
  ProjCase(
    'unit mainu;'#10 +
    'interface'#10 +
    'uses |'#10 +
    'implementation'#10 +
    'end.'#10);
  GCounter.Ok('uses caret classifies ccUses', GHit and (GCtx = ccUses));
  GCounter.Ok('uses lists the known unit', Has('exta'));
  GCounter.Ok('uses lists the search-path unit nothing analyzed',
    Has('Unused.Extb'));

  // Dotted uses prefixes: the caret's prefix and replace-span must cover the
  // WHOLE dotted chain typed so far, not the last segment — a client filters
  // 'Unused.Ex' against 'Unused.Extb' and replaces the full name.
  ProjCase(
    'unit mainu;'#10 +
    'interface'#10 +
    'uses exta, Unused.Ex|'#10 +
    'implementation'#10 +
    'end.'#10);
  GCounter.Ok('dotted uses prefix spans the chain',
    GHit and (GCtx = ccUses) and (GInfo.Prefix = 'Unused.Ex'));
  GCounter.Ok('dotted uses replace-span starts at the first segment',
    GInfo.PrefixColFrom = 12);
  ProjCase(
    'unit mainu;'#10 +
    'interface'#10 +
    'uses Unused.|'#10 +
    'implementation'#10 +
    'end.'#10);
  GCounter.Ok('uses after-dot prefix carries the qualifier',
    GHit and (GInfo.Prefix = 'Unused.') and (GInfo.PrefixColFrom = 6));

  // --- property accessor positions (read/write signature filter) -----------
  ProjCase(
    'unit mainu;'#10 +
    'interface'#10 +
    'uses exta;'#10 +
    'type'#10 +
    '  TP = class(TBase)'#10 +
    '  private'#10 +
    '    FVal: Integer;'#10 +
    '    function GetVal: Integer;'#10 +
    '    procedure SetVal(AValue: Integer);'#10 +
    '  public'#10 +
    '    property Val: Integer read |'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'end.'#10);
  GCounter.Ok('read | classifies ccPropRead', GHit and (GCtx = ccPropRead));
  GCounter.Ok('read | lists the field', Has('FVal'));
  GCounter.Ok('read | lists the getter function', Has('GetVal'));
  GCounter.Ok('read | filters the procedure', not Has('SetVal'));
  GCounter.Ok('read | reaches the INHERITED field', Has('FProt'));
  GCounter.Ok('read | offers no keywords', not Has('nil'));
  ProjCase(
    'unit mainu;'#10 +
    'interface'#10 +
    'uses exta;'#10 +
    'type'#10 +
    '  TP = class(TBase)'#10 +
    '  private'#10 +
    '    FVal: Integer;'#10 +
    '    function GetVal: Integer;'#10 +
    '    procedure SetVal(AValue: Integer);'#10 +
    '  public'#10 +
    '    property Val: Integer read FVal write |'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'end.'#10);
  GCounter.Ok('write | classifies ccPropWrite', GHit and (GCtx = ccPropWrite));
  GCounter.Ok('write | lists the setter procedure', Has('SetVal'));
  GCounter.Ok('write | filters the function', not Has('GetVal'));
  GCounter.Ok('write | lists the field', Has('FVal'));

  // --- overlay-generic frames -----------------------------------------------
  // The generic's argument is an OVERLAY-declared type: the frame must close
  // by bridging TMy into this file's last-good model, so Get's T substitutes
  // and the chained dot lists TMy's members. (Used to stay an open generic.)
  ProjCase(
    'unit mainu;'#10 +
    'interface'#10 +
    'uses exta;'#10 +
    'type'#10 +
    '  TMy = class(TBase)'#10 +
    '  public'#10 +
    '    procedure Own;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure P;'#10 +
    'var'#10 +
    '  GM: TExtGen<TMy>;'#10 +
    'begin'#10 +
    '  GM.Get.|'#10 +
    'end;'#10 +
    'end.'#10);
  GCounter.Ok('overlay-generic frame closes: chained dot sees the arg type',
    GHit and (GCtx = ccMember) and Has('Own'));
  GCounter.Ok('overlay-generic frame: inherited members through the arg',
    Has('Pub'));

  // --- keyword rows carry skKeyword ------------------------------------------
  ProjCase(PROJ_HEAD + '  |'#10 + PROJ_TAIL);
  GCounter.Ok('keyword rows carry skKeyword',
    Has('begin') and (ItemNamed('begin').Kind = skKeyword));

  // ======== §8A: per-item accessors ==========================================
  ProjCase(PROJ_HEAD + '  B.|'#10 + PROJ_TAIL);
  GCounter.Ok('ItemParamsText: parameterless method answers empty',
    GComp.ItemParamsText(ItemNamed('Pub')) = '');
  GCounter.Ok('ItemHasParams: parameterless method answers False',
    not GComp.ItemHasParams(ItemNamed('Pub')));
  GCounter.Ok('ItemParamsText: the first-listed overload''s params',
    GComp.ItemParamsText(ItemNamed('Over')) = '(A: Integer)');
  GCounter.Ok('ItemHasParams: a routine with a parameter answers True',
    GComp.ItemHasParams(ItemNamed('Over')));

  // Empty `()` must answer False (the auto-parenthesis driver), and a
  // multi-line list must collapse to one display line.
  ProjCase(
    'unit mainu;'#10 +
    'interface'#10 +
    'implementation'#10 +
    'procedure Q();'#10'begin'#10'end;'#10 +
    'procedure R(const S: string;'#10 +
    '  N: Integer);'#10'begin'#10'end;'#10 +
    'procedure P;'#10 +
    'begin'#10 +
    '  |'#10 +
    'end;'#10 +
    'end.'#10);
  GCounter.Ok('ItemHasParams: empty () answers False',
    Has('Q') and not GComp.ItemHasParams(ItemNamed('Q')));
  GCounter.Ok('ItemParamsText: empty () answers empty',
    GComp.ItemParamsText(ItemNamed('Q')) = '');
  GCounter.Ok('ItemParamsText: multi-line list collapses to one line',
    GComp.ItemParamsText(ItemNamed('R')) = '(const S: string; N: Integer)');
  // §8C: a compiler seed answers the curated display signature.
  GCounter.Ok('ItemParamsText: builtin answers the curated signature',
    GComp.ItemParamsText(ItemNamed('SetLength')) =
      '(var S; NewLength: NativeInt)');
  GCounter.Ok('ItemHasParams: builtin takes-arguments flag',
    GComp.ItemHasParams(ItemNamed('SetLength')));
  GCounter.Ok('ItemHasParams: optional-only builtin answers False',
    Has('Exit') and not GComp.ItemHasParams(ItemNamed('Exit')));

  // ======== §8B: CallAt ======================================================
  // The bridged member call, both overloads as separate signatures.
  CallCase(PROJ_HEAD + '  B.Over(|'#10 + PROJ_TAIL);
  GCounter.Ok('B.Over(| answers', GHit);
  GCounter.Ok('B.Over(| finds the ( position',
    (GCall.OpenLine = 22) and (GCall.OpenCol = 9));
  GCounter.Ok('B.Over(| argument 0', GCall.ArgIndex = 0);
  GCounter.Ok('B.Over(| reports BOTH overloads as separate targets',
    TargetsNamed('Over') = 2);
  GCounter.Ok('B.Over(| first overload params',
    TargetOf('Over').ParamsText = '(A: Integer)');
  GCounter.Ok('B.Over(| head word', TargetOf('Over').HeadWord = 'procedure');

  // Active argument: top-level commas; a nested call binds to ITS name.
  CallCase(PROJ_HEAD + '  B.Over(1, |'#10 + PROJ_TAIL);
  GCounter.Ok('B.Over(1, | argument 1', GHit and (GCall.ArgIndex = 1));
  CallCase(PROJ_HEAD + '  B.Over(Ord(|'#10 + PROJ_TAIL);
  GCounter.Ok('nested call: the INNERMOST call wins',
    GHit and (TargetsNamed('Ord') = 1));

  // The freshly typed CROSS-UNIT call — the gap the LSP interim cannot
  // close, and the reason CallAt exists (plan §8B).
  CallCase(PROJ_HEAD + '  ExtProc(|'#10 + PROJ_TAIL);
  GCounter.Ok('freshly typed cross-unit call resolves through the bridge',
    GHit and (TargetsNamed('ExtProc') = 1));
  GCounter.Ok('cross-unit target lives in the project space',
    TargetOf('ExtProc').Mid >= 0);

  // A builtin callee renders the curated signature (§8C through CallAt).
  CallCase(PROJ_HEAD + '  SetLength(|'#10 + PROJ_TAIL);
  GCounter.Ok('SetLength(| target params from the seed table',
    GHit and (TargetOf('SetLength').ParamsText =
      '(var S; NewLength: NativeInt)'));

  // A constructor is a target, with its head word.
  CallCase(PROJ_HEAD + '  TBase.Create(|'#10 + PROJ_TAIL);
  GCounter.Ok('TBase.Create(| resolves the constructor',
    GHit and (TargetOf('Create').HeadWord = 'constructor'));

  // A member call on an INDEXED base — the designator walk, not a name scan.
  CallCase(PROJ_HEAD + '  Arr[0].Pub(|'#10 + PROJ_TAIL);
  GCounter.Ok('Arr[0].Pub(| types the element and finds the method',
    GHit and (TargetsNamed('Pub') = 1));

  // Grouping parens and casts are stepped over to the enclosing call.
  CallCase(PROJ_HEAD + '  B.Over((1 + |'#10 + PROJ_TAIL);
  GCounter.Ok('grouping paren steps out to the call',
    GHit and (TargetsNamed('Over') = 2) and (GCall.ArgIndex = 0));
  CallCase(PROJ_HEAD + '  B.Over(Integer(|'#10 + PROJ_TAIL);
  GCounter.Ok('a cast steps out to the call',
    GHit and (TargetsNamed('Over') = 2));

  // Refusals: no call, and a DECLARATION's parameter list.
  CallCase(PROJ_HEAD + '  |'#10 + PROJ_TAIL);
  GCounter.Ok('statement caret is in no call', not GHit);
  CallCase(
    'unit mainu;'#10 +
    'interface'#10 +
    'implementation'#10 +
    'procedure T(|'#10 +
    'end.'#10);
  GCounter.Ok('a declaration''s parameter list is not a call', not GHit);

  GProj.Free;
  GProj := nil;

  if GCounter.Finish('SemaCompleteSmoke') then
    ExitCode := 1;
  GComp.Free;
  GModel.Free;
  GPP.Free;
  GDefines.Free;
  GSM.Free;
end.
