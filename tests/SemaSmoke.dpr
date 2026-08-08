program SemaSmoke;

{ Phase-1 semantic smoke tests: symbol collection, intra-unit name/type
  resolution, overloads, external (uses) names, and E2004 redeclaration.
  Mirrors ParserSmoke's harness. }

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
  PasTree.Sema.Dump in '..\source\PasTree.Sema.Dump.pas';

var
  GSM: TPasSourceManager;
  GDefines: TPasDefines;
  GPP: TPasPreprocessor;
  GPassed, GFailed: Integer;
  GModel: TPasSemaModel;
  GTree: TPasTree;

procedure Analyze(const ASource: string);
var
  LPre: TPasPreprocessed;
  LDiags: TArray<TPasParseDiag>;
begin
  LPre := GPP.ProcessText('test.pas', ASource);
  GTree := TPasParser.ParseFile(LPre, LDiags);
  GModel := TPasSemaResolver.Analyze(GTree);
end;

{ As Analyze, for the handful of rules whose answer depends on the TARGET — the
  builtin seed's 64-bit intrinsics, and `set of NativeInt`. }
procedure AnalyzeOn(APlatform: TPasPlatform; const ASource: string);
var
  LPre: TPasPreprocessed;
  LDiags: TArray<TPasParseDiag>;
begin
  LPre := GPP.ProcessText('test.pas', ASource);
  GTree := TPasParser.ParseFile(LPre, LDiags);
  GModel := TPasSemaResolver.Analyze(GTree, False, APlatform);
end;

function SymCountOf(const ANameLower: string; AKind: TSemaSymbolKind): Integer;
begin
  Result := 0;
  for var LIdx := 0 to GModel.SymCount - 1 do
    if (GModel.Symbols[LIdx].NameLower = ANameLower) and
       (GModel.Symbols[LIdx].Kind = AKind) then
      Inc(Result);
end;

// The recorded visibility of the first symbol with that lower-cased name.
function VisOf(const ANameLower: string): TSemaVisibility;
begin
  Result := svDefault;
  for var LIdx := 0 to GModel.SymCount - 1 do
    if GModel.Symbols[LIdx].NameLower = ANameLower then
      Exit(GModel.Symbols[LIdx].Visibility);
end;

function HasSym(const AName: string; AKind: TSemaSymbolKind): Boolean;
begin
  Result := SymCountOf(LowerCase(AName), AKind) > 0;
end;

// A resolved *reference* (not the declaration itself) whose target symbol has
// the given name.
function RefResolvesTo(const ARefText, ATargetName: string): Boolean;
var
  LNode, LSym: Integer;
begin
  Result := False;
  for LNode := 0 to High(GModel.RefMap) do
    if (GTree.Nodes[LNode].Kind = nkIdent) and
       SameText(GTree.NodeText(LNode), ARefText) then
    begin
      LSym := GModel.RefMap[LNode];
      if (LSym <> NIL_SYM) and (LNode <> GModel.Symbols[LSym].DeclNode) and
         SameText(GModel.Symbols[LSym].Name, ATargetName) then
        Exit(True);
    end;
end;

{ Describes what the AOccurrence-th reference (0-based, source order) spelled
  ARefText bound to: 'builtin', 'generic', 'type', 'unbound' or 'missing'. For
  the arity rule, where both candidates share a NAME and only the kind and the
  generic flag tell them apart. }
function RefBindKind(const ARefText: string; AOccurrence: Integer): string;
var
  LNode, LSym, LSeen: Integer;
begin
  LSeen := 0;
  for LNode := 0 to High(GModel.RefMap) do
    if (GTree.Nodes[LNode].Kind = nkIdent) and
       SameText(GTree.NodeText(LNode), ARefText) then
    begin
      LSym := GModel.RefMap[LNode];
      if (LSym <> NIL_SYM) and (LNode = GModel.Symbols[LSym].DeclNode) then
        Continue;   // the declaration itself is not a reference
      if LSeen = AOccurrence then
      begin
        if LSym = NIL_SYM then
          Exit('unbound');
        if GModel.Symbols[LSym].Kind = skBuiltinType then
          Exit('builtin');
        if sfGeneric in GModel.Symbols[LSym].Flags then
          Exit('generic');
        Exit('type');
      end;
      Inc(LSeen);
    end;
  Result := 'missing';
end;

// True when EVERY bare reference spelled ARefText resolved to something (and
// there was at least one). Unlike RefResolvesTo this needs no target name, so
// it also covers symbols with no DeclNode at all — exactly the seeded
// builtins/intrinsics case.
function AllRefsResolved(const ARefText: string): Boolean;
var
  LNode, LSeen: Integer;
begin
  LSeen := 0;
  for LNode := 0 to High(GModel.RefMap) do
    if (GTree.Nodes[LNode].Kind = nkIdent) and
       SameText(GTree.NodeText(LNode), ARefText) then
    begin
      Inc(LSeen);
      if GModel.RefMap[LNode] = NIL_SYM then
        Exit(False);
    end;
  Result := LSeen > 0;
end;

function DiagCount(const ACode: string): Integer;
begin
  Result := 0;
  for var LIdx := 0 to High(GModel.Diags) do
    if GModel.Diags[LIdx].Code = ACode then
      Inc(Result);
end;

// Does any diagnostic with that code contain ASubstr in its message?
function DiagHasText(const ACode, ASubstr: string): Boolean;
begin
  Result := False;
  for var LIdx := 0 to High(GModel.Diags) do
    if (GModel.Diags[LIdx].Code = ACode) and
       GModel.Diags[LIdx].Msg.Contains(ASubstr) then
      Exit(True);
end;

// A declaration symbol's bound type name (or '' if unbound / missing).
function TypeOf(const ANameLower: string; AKind: TSemaSymbolKind): string;
begin
  Result := '';
  for var LIdx := 0 to GModel.SymCount - 1 do
    if (GModel.Symbols[LIdx].NameLower = ANameLower) and
       (GModel.Symbols[LIdx].Kind = AKind) then
    begin
      if GModel.Symbols[LIdx].TypeSym <> NIL_SYM then
        Result := GModel.Symbols[GModel.Symbols[LIdx].TypeSym].Name;
      Exit;
    end;
end;

procedure Ok(const AName: string; ACond: Boolean);
begin
  if ACond then
    Inc(GPassed)
  else
  begin
    Inc(GFailed);
    Writeln('FAIL: ', AName);
    Writeln(DumpSemaModel(GModel));
  end;
end;

const
  SRC_RECORD =
    'unit U;'#10'interface'#10 +
    'type TFoo = record X, Y: Integer; end;'#10 +
    'var G: TFoo;'#10'implementation'#10'end.'#10;

  SRC_ROUTINE =
    'unit U;'#10'interface'#10'implementation'#10 +
    'function Sum(const A, B: Integer): Integer;'#10 +
    'var I: Integer;'#10'begin Result := A + B; end;'#10'end.'#10;

  SRC_REDECL =
    'unit U;'#10'interface'#10 +
    'var X: Integer; X: Integer;'#10'implementation'#10'end.'#10;

  SRC_EXTERNAL =
    'unit U;'#10'interface'#10'uses System.SysUtils;'#10 +
    'var G: TStringList;'#10'implementation'#10'end.'#10;

  SRC_OVERLOAD =
    'unit U;'#10'interface'#10'implementation'#10 +
    'procedure P(A: Integer); begin end;'#10 +
    'procedure P(A: string); begin end;'#10'end.'#10;

  // Sibling for-loops reusing one inline var name: each `for var` is scoped
  // to ITS loop (dcc behavior), so this is NOT a redeclaration.
  SRC_FORVAR =
    'unit U;'#10'interface'#10'implementation'#10 +
    'const ARR: array[0..1] of string = (''a'', ''b'');'#10 +
    'procedure P;'#10'begin'#10 +
    '  for var W in ARR do Writeln(W);'#10 +
    '  for var W in ARR do Writeln(W);'#10 +
    '  for var I := 0 to 1 do Writeln(I);'#10 +
    '  for var I := 0 to 1 do Writeln(I);'#10 +
    'end;'#10'end.'#10;

  // Two sibling anonymous functions: each owns its locals AND its implicit
  // Result (typed by ITS result type, not the enclosing function's).
  SRC_ANON =
    'unit U;'#10'interface'#10'implementation'#10 +
    'type TFn = reference to function: Boolean;'#10 +
    'function Outer: string;'#10 +
    'var F, G: TFn;'#10 +
    'begin'#10 +
    '  F := function: Boolean var L: Integer; begin L := 1; Result := L > 0; end;'#10 +
    '  G := function: Boolean var L: Integer; begin L := 2; Result := L > 0; end;'#10 +
    '  Result := '''';'#10 +
    'end;'#10'end.'#10;

  // A type declaration legally hides a used unit's leaf name (WinSock2's
  // `QOS = ...` vs `uses Winapi.Qos`).
  SRC_UNITHIDE =
    'unit U;'#10'interface'#10'uses Winapi.Qos;'#10 +
    'type Qos = record V: Integer; end;'#10 +
    'implementation'#10'end.'#10;

  // A call no local overload admits: arg-count fires, but the call must stay
  // UNTYPED (the real callee may be an unseen overload from another unit) —
  // no bogus E2010 from the local head's result type.
  SRC_NOFIT =
    'unit U;'#10'interface'#10'implementation'#10 +
    'function F(A: Integer): string; begin Result := ''''; end;'#10 +
    'procedure P;'#10'var I: Integer;'#10'begin'#10 +
    '  I := F(1, 2);'#10 +
    'end;'#10'end.'#10;

  // Real bug report: an ARRAY property's index parameter name (`Index` in
  // `property Items[Index: Integer]`) is a pure declaration of the
  // property's own signature slot — nothing in real Object Pascal can ever
  // reference it — but the resolver fell through to a generic Collect() with
  // no case for nkParams/nkParam at all, so the name was never declared,
  // never marked as a declaration, and Resolve treated it as an ordinary
  // (undeclared) reference: false E2003. Mirrors System.Actions.pas's
  // TCustomShortCutList.ShortCuts exactly (private getter + one-param array
  // property reading it). Two properties reusing the SAME index name
  // ('Index') must NOT collide with each other either (E2004) — each gets
  // its own isolated scope, same as nkProcType's signature scope.
  SRC_PROPINDEX =
    'unit U;'#10 +
    'interface'#10 +
    'type'#10 +
    '  TThing = class'#10 +
    '  private'#10 +
    '    function GetItem(Index: Integer): string;'#10 +
    '    function GetPair(Index: Integer; Key: string): Integer;'#10 +
    '  public'#10 +
    '    property Items[Index: Integer]: string read GetItem;'#10 +
    '    property Pairs[Index: Integer; Key: string]: Integer read GetPair;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TThing.GetItem(Index: Integer): string;'#10 +
    'begin'#10 +
    '  Result := '''';'#10 +
    'end;'#10 +
    'function TThing.GetPair(Index: Integer; Key: string): Integer;'#10 +
    'begin'#10 +
    '  Result := Index;'#10 +
    'end;'#10 +
    'end.'#10;

  // Real bug report: an implementation may OMIT its own parameter list when
  // it exactly matches the declaration (`procedure Foo;` completing
  // `procedure Foo(AParam: Integer);` — legal dcc). CollectRoutine only
  // declares params from the IMPLEMENTATION'S OWN nkParams child, which does
  // not exist when omitted, so the body treated every such name as an
  // ordinary (undeclared) reference: false E2003. Mirrors
  // Vcl.CheckLst.pas's TCustomCheckListBox.ToggleClickCheck exactly (method
  // case) plus the same gap for a global routine.
  SRC_OMITPARAMS =
    'unit U;'#10 +
    'interface'#10 +
    'type'#10 +
    '  TThing = class'#10 +
    '    procedure Toggle(Index: Integer);'#10 +
    '  end;'#10 +
    'procedure GlobalToggle(Index: Integer); forward;'#10 +
    'implementation'#10 +
    'procedure TThing.Toggle;'#10 +
    'begin'#10 +
    '  if Index > 0 then'#10 +
    '    Index := Index - 1;'#10 +
    'end;'#10 +
    'procedure GlobalToggle;'#10 +
    'begin'#10 +
    '  if Index > 0 then'#10 +
    '    Index := Index - 1;'#10 +
    'end;'#10 +
    'end.'#10;

  // Real bug report: {$SCOPEDENUMS ON} (2.2.4) was IGNORED — CollectEnum
  // always injected enum values into the enclosing scope. The killer is not
  // the missing E2003 on a bare value; it is SHADOWING: System.Threading
  // (whole unit under SCOPEDENUMS ON) declares `TLoopStateFlags = (Exception,
  // ...)`, the leaked VALUE shadowed the `Exception` TYPE, heritage
  // `class(Exception)` resolved to an enum value, the ancestor walk died and
  // every inherited member below was a false E2003. TVal here plays
  // Exception; Ping plays Message. State is POSITIONAL: TOpen after
  // {$SCOPEDENUMS OFF} injects again, and the PUSHOPT/POPOPT pair must
  // restore ON for TAfterPop.
  // NB the shadowing mechanics, because the fixture depends on them: a type
  // in the unit's OWN scope cannot be shadowed by a leaked value (FindLocal-
  // Deep checks own Names before Additional). Threading's Exception was
  // shadowed precisely because it comes from a JOINED scope (the builtin
  // system scope) and the enum join is more recent — so the fixture names
  // its value `Exception`, the builtin, exactly like the real bug.
  SRC_SCOPEDENUMS =
    'unit U;'#10 +
    'interface'#10 +
    '{$SCOPEDENUMS ON}'#10 +
    'type'#10 +
    '  TFlags = (Exception, Broken);'#10 + // value named like the BUILTIN type
    '{$PUSHOPT}'#10 +
    '{$SCOPEDENUMS OFF}'#10 +
    'type'#10 +
    '  TOpen = (Alpha, Beta);'#10 +        // unscoped again: values inject
    '{$POPOPT}'#10 +
    'type'#10 +
    '  TAfterPop = (Gamma, Delta);'#10 +   // POPOPT restored ON: scoped
    'implementation'#10 +
    'procedure P;'#10 +
    'var'#10 +
    '  E: Exception;'#10 +                 // must bind the TYPE, not the value
    '  F: TFlags;'#10 +
    '  O: TOpen;'#10 +
    '  A: TAfterPop;'#10 +
    'begin'#10 +
    '  E := nil;'#10 +
    '  F := TFlags.Exception;'#10 +        // qualified access always works
    '  F := TFlags.Broken;'#10 +
    '  O := Alpha;'#10 +                   // injected (unscoped)
    '  A := TAfterPop.Gamma;'#10 +
    'end;'#10 +
    'end.'#10;

  { 5.7 — "a target member outranks EVERYTHING else in scope" applied to names
    Phase 1 ALREADY BOUND. The rule was stated and dcc-verified in the spec, and
    the implementation only honoured it for targets it could not open: a target
    whose type IS same-unit resolvable opened its scope and then kept the older
    binding, because ResolveNode only fills NIL_SYM.

    Every member here is a `string` and every shadowed name an `Integer`, so a
    wrong binding is not silent — it surfaces as E2010 on the assignment. All
    four shadow kinds from the 5.7 bullet, plus the implicit `Result`, which the
    bullet did not mention and dcc also lets the member win (W_res probe:
    `with R do Result := 'x'` compiles inside a function returning Integer). }
  SRC_WITHSHADOW =
    'unit U;'#10 +
    'interface'#10 +
    'type'#10 +
    '  TRec = record'#10 +
    '    Loc: string;'#10 +
    '    Par: string;'#10 +
    '    Glob: string;'#10 +
    '    Result: string;'#10 +
    '  end;'#10 +
    'var'#10 +
    '  Glob: Integer;'#10 +               // unit-level global
    'function F(Par: Integer): Integer;'#10 +
    'implementation'#10 +
    'function F(Par: Integer): Integer;'#10 +   // parameter
    'var'#10 +
    '  R: TRec;'#10 +
    '  Loc: Integer;'#10 +                // local
    'begin'#10 +
    '  Loc := 1;'#10 +
    '  Glob := 2;'#10 +
    '  with R do'#10 +
    '  begin'#10 +
    '    Loc := ''a'';'#10 +
    '    Par := ''b'';'#10 +
    '    Glob := ''c'';'#10 +
    '    Result := ''d'';'#10 +
    '  end;'#10 +
    '  Result := Loc;'#10 +               // outside: the INTEGER local again
    'end;'#10 +
    'end.'#10;

  { NESTED inline arrays -- `array of array of T`, one nkArrayType inside
    another, indexed with a single `[I, J]`. Peeling one level lands on the
    intermediate row type, which is ANONYMOUS and has no symbol, so the element
    type could not be named and `with AMatrix[I, J] do` opened over nothing.

    Descending to the innermost element is the same deliberate over-eagerness
    already accepted for the comma-dimension spelling `array[a, b] of T`: exact
    when the index count matches the nesting, one level too deep otherwise --
    where it can only find members of T instead of failing. }
  SRC_NESTEDARRAY =
    'unit U;'#10 +
    'interface'#10 +
    'function Calc: Integer;'#10 +
    'implementation'#10 +
    'type'#10 +
    '  TMatrixItem = record'#10 +
    '    Weight: Integer;'#10 +
    '    Direction: Byte;'#10 +
    '  end;'#10 +
    'function Calc: Integer;'#10 +
    'var'#10 +
    '  AMatrix: array of array of TMatrixItem;'#10 +
    '  I, J: Integer;'#10 +
    'begin'#10 +
    '  I := 1; J := 1;'#10 +
    '  with AMatrix[I, J] do'#10 +
    '  begin'#10 +
    '    Weight := 1;'#10 +
    '    Direction := 2;'#10 +
    '  end;'#10 +
    '  Result := 0;'#10 +
    'end;'#10 +
    'end.'#10;

  { An ANONYMOUS structured type, written inline in a declaration's type slot
    rather than given a name: `array[0..1] of record offset, minimum: Cardinal;
    end`. CollectStruct always gave it a member SCOPE, but no SYMBOL owned that
    scope -- and every cross-model type is a (unit, symbol) pair, so the element
    type could not be named at all and `with TAB[I] do` opened over nothing.
    A synthetic unnamed type symbol carries the scope; nothing can resolve to it
    by name, so it cannot collide or shadow. }
  SRC_ANONSTRUCT =
    'unit U;'#10 +
    'interface'#10 +
    'procedure Use;'#10 +
    'implementation'#10 +
    'const'#10 +
    '  TAB: packed array[0..1] of record'#10 +
    '    offset, minimum: Cardinal;'#10 +
    '  end = ('#10 +
    '    (offset: 1; minimum: 2),'#10 +
    '    (offset: 3; minimum: 4));'#10 +
    'procedure Use;'#10 +
    'var'#10 +
    '  I: Integer;'#10 +
    '  C: Cardinal;'#10 +
    'begin'#10 +
    '  I := 0;'#10 +
    '  with TAB[I] do'#10 +
    '  begin'#10 +
    '    C := offset;'#10 +
    '    if C < minimum then Exit;'#10 +
    '  end;'#10 +
    'end;'#10 +
    'end.'#10;

  { Two clusters from the first run over a real 3790-unit project.

    Real48 (2.5.1) is compiler-provided like Comp: System.pas names it only in a
    NODEFINE directive and in comments, so a source grep says "declared" and dcc
    says otherwise — exactly the trap the intrinsic-routine list in
    Sema.Builtins documents. 11 false E2003.

    Meth(Source := X) is an OLE-automation NAMED ARGUMENT (4.10.1), legal on a
    late-bound Variant call. dcc name-checks nothing on the left --
    V.Add(Nonexistent := 1) compiles -- and fully checks the right:
    V.Add(Source := Undeclared1) is E2003 on the value. Both dcc-verified, both
    asserted below. ~20 sites in that project's Excel automation code, each
    costing two parse diagnostics as well. }
  SRC_AVICLUSTERS =
    'unit U;'#10 +
    'interface'#10 +
    'procedure P;'#10 +
    'implementation'#10 +
    'procedure P;'#10 +
    'var'#10 +
    '  R: Real48;'#10 +                  // compiler-provided, not in System.pas
    '  MSExcel: Variant;'#10 +
    '  Counter: Integer;'#10 +
    'begin'#10 +
    '  Counter := 1;'#10 +
    '  R := 0;'#10 +
    '  MSExcel.Charts[1].SeriesCollection.Add(Source :='#10 +
    '    MSExcel.Worksheets[1].Range[Counter]);'#10 +
    'end;'#10 +
    'end.'#10;

  { A forward-declared GENERIC completing under a name that ALSO has a
    non-generic declaration. One library unit has all three, in this order:
    `TJclArrayIterator` (arity 0), `TJclArrayIterator<T> = class;` (the
    forward), then the real `TJclArrayIterator<T>`. FindLocal returns the HEAD
    of the name's overload chain — the arity-0 class — so the arity test read
    "a different type", the completion declared a THIRD symbol, and the empty
    forward stayed the arity-1 winner. Every method body of the real class then
    lost its own fields AND its inherited members: ~60 false E2003 in that one
    unit. The completion has to be searched along the whole chain.

    The non-generic sibling is load-bearing here — without it the shape does not
    reproduce at all, which is exactly why it took a real corpus to surface. }
  SRC_FWDGENERIC =
    'unit U;'#10 +
    'interface'#10 +
    'type'#10 +
    '  TIter = class'#10 +                // arity 0, FIRST
    '  private'#10 +
    '    FTag: Integer;'#10 +
    '  public'#10 +
    '    function Get: Integer;'#10 +
    '  end;'#10 +
    '  TIter<T> = class;'#10 +            // the forward, arity 1
    '  TIter<T> = class'#10 +             // the real one, arity 1
    '  private'#10 +
    '    FCursor: Integer;'#10 +
    '  public'#10 +
    '    function Next: Integer;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TIter.Get: Integer;'#10 +
    'begin'#10 +
    '  Result := FTag;'#10 +
    'end;'#10 +
    'function TIter<T>.Next: Integer;'#10 +
    'begin'#10 +
    '  Result := FCursor;'#10 +
    'end;'#10 +
    'end.'#10;

  { A directive WORD used as the name of the next declaration. Directives are
    context-sensitive identifiers, and `unsafe` is one — so ConsumeTrailingDirectives
    read a component suite's `Unsafe = class` as the `cdecl = nil` shape (a
    procedural VARIABLE whose initializer follows its calling convention) and
    swallowed the type declaration, everything the interface declared after it,
    and every use of any of it across the library: 283 false E2003 from one line.
    Only a VAR section can legitimately reach an '=' there.

    TSecond exists to prove the damage was not limited to the swallowed name —
    it is what "everything after it" means. The procedural-var shape the '='
    branch exists for is asserted alongside, so the fix cannot silently undo it. }
  SRC_DIRECTIVENAME =
    'unit U;'#10 +
    'interface'#10 +
    'type'#10 +
    '  TFirst = class'#10 +
    '    class function Cast(A: TObject): TObject; static;'#10 +
    '  end;'#10 +
    '  Unsafe = class'#10 +               // a ROUTINE_DIRECTIVE_WORD as a name
    '    class function Cast(A: TObject): TObject; static;'#10 +
    '  end;'#10 +
    '  TSecond = class'#10 +              // and everything after it
    '    Tag: Integer;'#10 +
    '  end;'#10 +
    'const'#10 +
    '  Alpha = 1;'#10 +
    '  Index = 2;'#10 +                   // ditto in a const section
    'var'#10 +
    '  Hook: procedure; cdecl = nil;'#10 +   // the shape the branch exists for
    'procedure P;'#10 +
    'implementation'#10 +
    'class function TFirst.Cast(A: TObject): TObject; begin Result := nil; end;'#10 +
    'class function Unsafe.Cast(A: TObject): TObject; begin Result := nil; end;'#10 +
    'procedure P;'#10 +
    'var'#10 +
    '  S: TSecond;'#10 +
    'begin'#10 +
    '  S := nil;'#10 +
    '  if Unsafe.Cast(S) = nil then'#10 +
    '    S.Tag := Alpha + Index;'#10 +
    'end;'#10 +
    'end.'#10;

  { 5.7 — four target FORMS from the section's table that nothing else covers.
    All four compile under dcc 37.0; `with TCanvas do` was the one that did not
    work here, because the nkIdent path asked for the symbol's DECLARED type and
    a type symbol has none — for a bare class name the target's type is the type
    ITSELF, the same reach a `class of` reference gives. }
  SRC_WITHFORMS =
    'unit U;'#10 +
    'interface'#10 +
    'type'#10 +
    '  TPen = class'#10 +
    '    Color: Integer;'#10 +
    '  end;'#10 +
    '  TCanvas = class'#10 +
    '  private'#10 +
    '    FPen: TPen;'#10 +
    '  public'#10 +
    '    class var Shared: Integer;'#10 +
    '    class procedure Tick;'#10 +
    '    property Pen: TPen read FPen;'#10 +
    '  end;'#10 +
    '  TCanvasClass = class of TCanvas;'#10 +
    '  IThing = interface'#10 +
    '    procedure Go;'#10 +
    '  end;'#10 +
    '  TBaseCtl = class'#10 +
    '  private'#10 +
    '    FCanvas: TCanvas;'#10 +
    '  public'#10 +
    '    property Canvas: TCanvas read FCanvas;'#10 +
    '  end;'#10 +
    '  TCtl = class(TBaseCtl)'#10 +
    '    procedure Paint;'#10 +
    '  end;'#10 +
    'procedure UseAll(AC: TCanvasClass; AI: IThing);'#10 +
    'implementation'#10 +
    'class procedure TCanvas.Tick;'#10 +
    'begin'#10 +
    '  Inc(Shared);'#10 +
    'end;'#10 +
    'procedure TCtl.Paint;'#10 +
    'begin'#10 +
    '  with inherited Canvas do'#10 +      // an INHERITED property
    '    Pen.Color := 1;'#10 +
    'end;'#10 +
    'procedure UseAll(AC: TCanvasClass; AI: IThing);'#10 +
    'begin'#10 +
    '  with AC do'#10 +                    // a class REFERENCE
    '    Tick;'#10 +
    '  with TCanvas do'#10 +               // a bare class TYPE NAME
    '    Tick;'#10 +
    '  with AI do'#10 +                    // an INTERFACE-typed designator
    '    Go;'#10 +
    'end;'#10 +
    'end.'#10;

  // The exception to SCOPEDENUMS, and it is forced rather than chosen: an
  // ANONYMOUS enum has no type NAME to qualify its values with, so scoping them
  // would make them unreachable by any spelling. dcc-verified under
  // {$SCOPEDENUMS ON}: `Include(S, SetChecked)` on `set of (SetChecked,
  // CallClick)` compiles, while the bare value of a NAMED enum does not.
  // FMX.StdCtrls (a SCOPEDENUMS unit) is the real case — TCustomSwitch's
  // `TNeededToDo = set of (SetChecked, CallClick)`, 8 false E2003.
  SRC_ANONENUM =
    'unit U;'#10 +
    'interface'#10 +
    '{$SCOPEDENUMS ON}'#10 +
    'type'#10 +
    '  TSwitch = class'#10 +
    '  private type'#10 +
    '    TNeededToDo = set of (SetChecked, CallClick);'#10 +   // nested
    '  private'#10 +
    '    FNeeded: TNeededToDo;'#10 +
    '  public'#10 +
    '    procedure Click;'#10 +
    '  end;'#10 +
    '  TTop = set of (Alpha, Beta);'#10 +                      // unit level
    '  TNamed = (Gamma, Delta);'#10 +                          // the control
    'var'#10 +
    '  GTop: TTop;'#10 +
    'implementation'#10 +
    'procedure TSwitch.Click;'#10 +
    'var'#10 +
    '  N: TNamed;'#10 +
    'begin'#10 +
    '  Include(FNeeded, SetChecked);'#10 +
    '  Exclude(FNeeded, CallClick);'#10 +
    '  Include(GTop, Alpha);'#10 +
    '  N := TNamed.Gamma;'#10 +          // the control: still QUALIFIED only
    'end;'#10 +
    'end.'#10;

  // Real bug report: an inline var declaring SEVERAL names (`var V, S:
  // string;`, 10.3+, dcc-verified) declared only the FIRST — every other name
  // was then an undeclared identifier, and the shared type bound to none of
  // them. Mirrors System.SysUtils' `var V, S: string` and System.TypInfo's
  // `var sType, sEnum: string`. The single-name and no-type-with-initializer
  // forms are the controls: an inline var's tail may be an initializer with
  // no type at all, and it still has to be collected.
  // Real bug report: a function whose RESULT TYPE is a generic instantiation
  // (`function LockList: TList<T>;` — System.Generics.Collections) lost its
  // result type entirely: CollectRoutine's name-segment loop consumed the
  // nkTypeArgs following the name ident as the SEGMENT's generic args, though
  // the ':' separator marks it as the result type. Only the separator tells
  // `Foo<T>` apart from `Foo: T<...>`. MakeNum is the control (plain result).
  SRC_GENRESULT =
    'unit U;'#10 +
    'interface'#10 +
    'type'#10 +
    '  TBox<T> = class'#10 +
    '    FV: T;'#10 +
    '  end;'#10 +
    'function MakeBox: TBox<Integer>;'#10 +
    'function MakeNum: Integer;'#10 +
    'implementation'#10 +
    'function MakeBox: TBox<Integer>; begin Result := nil; end;'#10 +
    'function MakeNum: Integer; begin Result := 0; end;'#10 +
    'end.'#10;

  SRC_INLINEVARS =
    'unit U;'#10 +
    'interface'#10 +
    'implementation'#10 +
    'function F(const A: string): Boolean;'#10 +
    'begin'#10 +
    '  var V, S: string;'#10 +          // two names, shared type
    '  var I, J: Integer;'#10 +         // ditto, another type
    '  var Solo: string;'#10 +          // control: single name + type
    '  var Init := A;'#10 +             // control: no type, initializer
    '  var Typed: string := A;'#10 +    // control: type AND initializer
    '  V := A;'#10 +
    '  S := V;'#10 +
    '  I := 1;'#10 +
    '  J := I;'#10 +
    '  Solo := S;'#10 +
    '  Result := (Init = Typed) and (Solo = V) and (I = J);'#10 +
    'end;'#10 +
    'end.'#10;

  // Real bug report: two with-target shapes the type-of-target walk did not
  // know. A CAST (`with TVarData(X) do`) and a DEREFERENCE (`with P^ do`) —
  // System.ObjAuto and System.Variants respectively, both writing to a
  // `VType` field that then read as undeclared. The cast branch existed in
  // Phase 1 but not in the cross-unit twin; nkDeref existed in NEITHER.
  // `with GetRec do` is the control: a parameterless CALL still has to type
  // to the routine's RESULT, not to the callee itself.
  SRC_WITHSHAPES =
    'unit U;'#10 +
    'interface'#10 +
    'type'#10 +
    '  TVarLike = record'#10 +
    '    VType: Word;'#10 +
    '    VPtr: Pointer;'#10 +
    '  end;'#10 +
    '  PVarLike = ^TVarLike;'#10 +
    '  PAlias = PVarLike;'#10 +   // alias chain: the walk must chase it
    '  TRec = record F: Integer; end;'#10 +
    '  TAncestor = class Base: Integer; end;'#10 +
    '  TChild = class(TAncestor) Tag: Integer; end;'#10 +
    'implementation'#10 +
    'function GetRec: TRec; begin Result.F := 1; end;'#10 +
    'function GetPtr: PVarLike; begin Result := nil; end;'#10 +
    'procedure P;'#10 +
    'var'#10 +
    '  Buf: array[0..3] of Integer;'#10 +
    '  LP: PVarLike;'#10 +
    '  LA: PAlias;'#10 +
    '  LI: Integer;'#10 +
    '  LO: TAncestor;'#10 +
    'begin'#10 +
    // An `as`-CAST target. Phase 1 reads the operator lexeme off nkBinaryOp's
    // Aux, which is a TOKEN index — passing it to NodeText (a NODE index) read
    // past the end of Nodes, so the comparison against 'as' usually came out
    // False on garbage and this target silently never opened. Invisible from
    // the project-level suites: the cross-model twin reads Aux correctly and
    // opened it there, masking the intra-unit failure. Only a single-model test
    // like this one can see it.
    '  with LO as TChild do'#10 +
    '    Tag := 9;'#10 +
    '  with TVarLike(Buf) do'#10 +          // cast
    '    VType := 1;'#10 +
    '  with LP^ do'#10 +                    // deref of a variable
    '    VType := 2;'#10 +
    '  with LA^ do'#10 +                    // deref through an alias chain
    '    VType := 3;'#10 +
    '  with GetPtr^ do'#10 +                // deref of a call result
    '    VType := 4;'#10 +
    '  with GetRec do'#10 +                 // control: call -> result type
    '    LI := F;'#10 +
    'end;'#10 +
    'end.'#10;

  // Real bug report: a `class/record helper for T` (15.3) injected nothing.
  // Its members were collected into a member scope of its OWN, unconnected to
  // T's, so a method of T referencing a helper member bare (`Result :=
  // Identity` in System.Math.Vectors' TMatrix.CreateRotation, where Identity
  // is a const of `TMatrixConstants = record helper for TMatrix`) was a false
  // E2003 — as was the reverse direction, the helper's own body reaching T's
  // fields through the implicit Self. Note `Double` here: a bare helper
  // METHOD whose name collides with a builtin type must reach the helper,
  // not System's Double (that one never E2003'd — it silently mis-resolved).
  // B.3 — an &-escaped identifier is the SAME identifier as the bare one; the
  // ampersand only stops the word being read as a keyword. Real bug report:
  // Vcl.Controls declares `var Message: TWMKeyDown` and then writes BOTH
  // `&Message.CmdType` and `Broadcast(Message)` in one routine, so the two
  // spellings must land on one symbol. dcc-verified in both directions, plus
  // `&begin` declaring an identifier literally named `begin`.
  SRC_AMPERSAND =
    'unit U;'#10 +
    'interface'#10 +
    'implementation'#10 +
    // declared PLAIN, referenced ESCAPED
    'procedure P1(var Message: Integer);'#10 +
    'begin'#10 +
    '  &Message := 1;'#10 +
    'end;'#10 +
    // declared ESCAPED, referenced PLAIN
    'procedure P2(var &Handled: Integer);'#10 +
    'begin'#10 +
    '  Handled := 2;'#10 +
    'end;'#10 +
    // escaping a genuine reserved word: the name IS `begin`
    'procedure P3;'#10 +
    'var'#10 +
    '  &begin: Integer;'#10 +
    'begin'#10 +
    '  &begin := 3;'#10 +
    'end;'#10 +
    'end.'#10;

  SRC_HELPERS =
    'unit U;'#10 +
    'interface'#10 +
    'type'#10 +
    '  TMatrix = record'#10 +
    '    class function CreateRotation(const A: Single): TMatrix; static;'#10 +
    '    m11: Single;'#10 +
    '  end;'#10 +
    '  TMatrixConstants = record helper for TMatrix'#10 +
    '    const Identity: TMatrix = (m11: 1);'#10 +
    '  end;'#10 +
    '  TThing = class'#10 +
    '    FValue: Integer;'#10 +
    '    procedure Bump;'#10 +
    '  end;'#10 +
    '  TThingHelper = class helper for TThing'#10 +
    '    const Step = 2;'#10 +
    '    procedure Double;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'class function TMatrix.CreateRotation(const A: Single): TMatrix;'#10 +
    'begin'#10 +
    '  Result := Identity;'#10 +
    '  Result.m11 := A;'#10 +
    'end;'#10 +
    'procedure TThing.Bump;'#10 +
    'begin'#10 +
    '  FValue := FValue + Step;'#10 +
    '  Double;'#10 +
    'end;'#10 +
    'procedure TThingHelper.Double;'#10 +
    'begin'#10 +
    '  FValue := FValue * 2;'#10 +
    'end;'#10 +
    'function Qualified: TMatrix;'#10 +
    'begin'#10 +
    '  Result := TMatrix.Identity;'#10 +
    'end;'#10 +
    'end.'#10;

  // `TFoo = record helper for TFoo` is malformed but parses, and the `for`
  // name resolves right back to the helper — the join must refuse it, or
  // FindLocalDeep recurses forever on the first failed lookup (hence the
  // deliberately undeclared name in the body: it forces a full miss).
  // Completing the analysis at all is the assertion.
  SRC_HELPER_SELF =
    'unit U;'#10 +
    'interface'#10 +
    'type'#10 +
    '  TFoo = record helper for TFoo'#10 +
    '    const K = 1;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure P;'#10 +
    'begin'#10 +
    '  WriteLn(NoSuchNameAnywhere);'#10 +
    'end;'#10 +
    'end.'#10;

  // Real bug report: a `label` section declared NOTHING (the parser emitted
  // nkLabelSec as a bare token span with no children, and Collect had no case
  // for it), while a labeled statement DID emit an nkIdent for its own name —
  // so `notAscii:` resolved to nothing and Phase 2 reported a false E2003.
  // Mirrors System.Generics.Defaults.AnsiIdentHash exactly. Numeric labels
  // (`goto 1`) declare no name and must stay diagnostic-free too.
  SRC_LABELS =
    'unit U;'#10 +
    'interface'#10 +
    'implementation'#10 +
    'function Hash(const S: string): Integer;'#10 +
    'label'#10 +
    '  notAscii, again;'#10 +
    'var'#10 +
    '  I: Integer;'#10 +
    'begin'#10 +
    '  Result := 0;'#10 +
    '  I := 0;'#10 +
    'again:'#10 +
    '  Inc(I);'#10 +
    '  if I > 10 then'#10 +
    '    goto notAscii;'#10 +
    '  goto again;'#10 +
    'notAscii:'#10 +
    '  begin'#10 +
    '    Result := Length(S);'#10 +
    '  end;'#10 +
    'end;'#10 +
    'procedure Numeric;'#10 +
    'label 1, 2;'#10 +
    'begin'#10 +
    '1:'#10 +
    '  goto 2;'#10 +
    '2:'#10 +
    '  Exit;'#10 +
    'end;'#10 +
    'end.'#10;

  // Real bug report: `with` statement member resolution was NOT IMPLEMENTED
  // at all (found via Vcl.ComCtrls.pas: `with FItems.Add do begin Caption :=
  // S; Result := Index; end;` — Caption/Index are members of the with-
  // target's OWN class, never declared as locals). `Result` here is the
  // ENCLOSING FUNCTION's own Result, not a with-target member — must not be
  // shadowed by the with-scope.
  SRC_WITHSTMT =
    'unit U;'#10 +
    'interface'#10 +
    'type'#10 +
    '  TItem = class'#10 +
    '    Caption: string;'#10 +
    '    Index: Integer;'#10 +
    '  end;'#10 +
    '  TItems = class'#10 +
    '    function Add: TItem;'#10 +
    '  end;'#10 +
    '  TThing = class'#10 +
    '    FItems: TItems;'#10 +
    '    function DoIt(const S: string): Integer;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TItems.Add: TItem;'#10 +
    'begin'#10 +
    '  Result := nil;'#10 +
    'end;'#10 +
    'function TThing.DoIt(const S: string): Integer;'#10 +
    'begin'#10 +
    '  with FItems.Add do'#10 +
    '  begin'#10 +
    '    Caption := S;'#10 +
    '    Result := Index;'#10 +
    '  end;'#10 +
    'end;'#10 +
    'end.'#10;

  // Multi-target precedence (ch.05 §5.7): `with A, B do` resolves a shared
  // name against the LAST target first. TA.X is Integer, TB.X is string —
  // if precedence were wrong (picked TA.X), `S := X` would be an
  // Integer->string assignment and fire E2010; correct precedence (TB.X)
  // assigns string->string, no diagnostic.
  SRC_WITHMULTI =
    'unit U;'#10 +
    'interface'#10 +
    'type'#10 +
    '  TA = class X: Integer; end;'#10 +
    '  TB = class X: string; end;'#10 +
    'implementation'#10 +
    'procedure UseIt(A: TA; B: TB);'#10 +
    'var S: string;'#10 +
    'begin'#10 +
    '  with A, B do'#10 +
    '    S := X;'#10 +
    'end;'#10 +
    'end.'#10;

  // Nested `with`: the inner target (B, a field of A) must resolve THROUGH
  // the outer with's scope, and the inner body sees both (innermost/last
  // wins on a shared name — here there is none, just confirming reach).
  SRC_WITHNESTED =
    'unit U;'#10 +
    'interface'#10 +
    'type'#10 +
    '  TInner = class Y: Integer; end;'#10 +
    '  TOuter = class B: TInner; end;'#10 +
    'implementation'#10 +
    'procedure UseIt(A: TOuter);'#10 +
    'var I: Integer;'#10 +
    'begin'#10 +
    '  with A do'#10 +
    '    with B do'#10 +
    '      I := Y;'#10 +
    'end;'#10 +
    'end.'#10;

  // Same-unit INHERITED member through a with-target (real bug report:
  // Vcl.ComCtrls.pas's TComboExItems.Add returns TComboExItem, whose
  // Caption/Index are declared on its ANCESTOR TListControlItem, not on
  // TComboExItem itself). CollectStruct never joins an ancestor's
  // MemberScope into the descendant's own — AncestorTypeSym/
  // FindMemberUpChain climb it (same-unit only) instead. TDerived's OWN
  // Index must still shadow anything of the same name an ancestor might
  // have (none here, but exercises the "own scope checked first" ordering).
  SRC_WITHINHERIT =
    'unit U;'#10 +
    'interface'#10 +
    'type'#10 +
    '  TBase = class'#10 +
    '    Caption: string;'#10 +
    '  end;'#10 +
    '  TDerived = class(TBase)'#10 +
    '    Index: Integer;'#10 +
    '  end;'#10 +
    '  TItems = class'#10 +
    '    function Add: TDerived;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TItems.Add: TDerived;'#10 +
    'begin'#10 +
    '  Result := nil;'#10 +
    'end;'#10 +
    'procedure UseIt(G: TItems; const S: string);'#10 +
    'begin'#10 +
    '  with G.Add do'#10 +
    '  begin'#10 +
    '    Caption := S;'#10 +
    '    Index := 1;'#10 +
    '  end;'#10 +
    'end;'#10 +
    'end.'#10;

  // Record variant parts (9.1.3), all four tag shapes plus nesting. The
  // optional TAG NAME is a real, storage-occupying, accessible field (dcc-
  // verified: R.data := 1 compiles; naming the tag grows SizeOf) -- nothing
  // used to declare it, so it read as an undeclared REFERENCE (real bug:
  // System.Curl.pas's `case data: Integer of`, plus 7 more tag names across
  // the RTL). The tag TYPE is an ordinal type, not just a type name: an
  // INLINE ANONYMOUS ENUM (spec 9.1.3's own example) used to derail the
  // parser entirely, turning branch LABELS into fields and `(Radius: Double)`
  // into an enum type. Every shape below is accepted by real dcc.
  SRC_VARIANT =
    'unit U;'#10'interface'#10 +
    'type'#10 +
    '  TAll = record'#10 +
    '    Head: Integer;'#10 +
    '    case data: Integer of'#10 +
    '      0: (whatever: Pointer);'#10 +
    '      1: (inner: Byte;'#10 +
    '          case sub: Boolean of'#10 +          // nested, itself tagged
    '            True:  (deep: Word);'#10 +
    '            False: (other: ShortInt));'#10 +
    '  end;'#10 +
    '  TShape = record'#10 +
    '    case Kind: (skCircle, skRect) of'#10 +    // inline anonymous enum
    '      skCircle: (Radius: Double);'#10 +
    '      skRect:   (W, H: Double);'#10 +
    '  end;'#10 +
    '  TSub = record'#10 +
    '    case Tag: 0..9 of'#10 +                   // subrange
    '      0: (A: Integer);'#10 +
    '  end;'#10 +
    '  TAnon = record'#10 +
    '    case Integer of'#10 +                     // anonymous: NO tag field
    '      0: (thing: Pointer);'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure P;'#10 +
    'var R: TAll; S: TShape;'#10 +
    'begin'#10 +
    '  R.data := 1; R.whatever := nil; R.inner := 2;'#10 +
    '  R.sub := True; R.deep := 3;'#10 +
    '  S.Kind := skCircle; S.Radius := 1.0;'#10 +
    'end;'#10'end.'#10;

  // Compiler intrinsics with NO declaration anywhere (spec B.4.3): the whole
  // classic file-I/O family, raw memory, Halt/GetDir, the Variant four,
  // CompilerVersion and the OpenString type. Every one of these must resolve
  // straight out of the seeded System scope — nothing else CAN resolve them
  // (real bug: the RTL's own System.Classes.pas got a false E2003 on GetMem).
  // The negative half matters just as much: `Abort` looks like a flow
  // intrinsic but is an ordinary System.SysUtils routine, so a unit that does
  // not use SysUtils must leave it UNRESOLVED.
  SRC_INTRINSICS =
    'unit U;'#10 +
    'interface'#10 +
    'implementation'#10 +
    'procedure P(var OS: OpenString);'#10 +
    'var'#10 +
    '  P1: Pointer;'#10 +
    '  F: file;'#10 +
    '  T: Text;'#10 +
    '  N: Integer;'#10 +
    '  D: string;'#10 +
    '  V1, V2: Variant;'#10 +
    'begin'#10 +
    '  GetMem(P1, 16); ReallocMem(P1, 32); FreeMem(P1);'#10 +
    '  AssignFile(T, ''x''); Reset(T); Eof(T); Eoln(T);'#10 +
    '  SeekEof(T); SeekEoln(T); Append(T); CloseFile(T);'#10 +
    '  Assign(F, ''y''); Rewrite(F); Seek(F, 0);'#10 +
    '  FilePos(F); FileSize(F); Truncate(F); Close(F);'#10 +
    '  BlockRead(F, P1, 1); BlockWrite(F, P1, 1);'#10 +
    '  Erase(F); Rename(F, ''z'');'#10 +
    '  GetDir(0, D);'#10 +
    '  VarClear(V1); VarCopy(V1, V2); VarCast(V1, V2, 0);'#10 +
    '  VarArrayRedim(V1, 4);'#10 +
    '  N := Trunc(CompilerVersion);'#10 +
    '  if N = 0 then Halt(1);'#10 +
    'end;'#10 +
    'end.'#10;

  // Companion negative case — see SRC_INTRINSICS.
  SRC_NOTINTRINSIC =
    'unit U;'#10 +
    'interface'#10 +
    'implementation'#10 +
    'procedure P;'#10 +
    'begin'#10 +
    '  Abort;'#10 +
    'end;'#10 +
    'end.'#10;

  // Interface-only symbol-id stability: the interface section declares types,
  // fields, a var and routines; the implementation adds bodies (and its own
  // locals). Because SeedSystemScope runs first (identical) and the interface
  // is collected before the implementation, every symbol id an interface-only
  // model assigns must equal the full model's symbol at the SAME id — the
  // guarantee that keeps other units' cross-references valid across the
  // intf->full snapshot swap (async parser plan §2.2).
  SRC_STAGED =
    'unit Staged;'#10 +
    'interface'#10 +
    'type'#10 +
    '  TFoo = class'#10 +
    '    FX: Integer;'#10 +
    '    function Bar(A: Integer): string;'#10 +
    '    procedure Baz;'#10 +
    '  end;'#10 +
    'var GCount: Integer;'#10 +
    'function Helper(N: Integer): Integer;'#10 +
    'implementation'#10 +
    'function TFoo.Bar(A: Integer): string;'#10 +
    'var LTmp: Integer;'#10 +
    'begin'#10 +
    '  LTmp := A;'#10 +
    '  Result := IntToStr(LTmp);'#10 +
    'end;'#10 +
    'procedure TFoo.Baz;'#10 +
    'begin'#10 +
    'end;'#10 +
    'function Helper(N: Integer): Integer;'#10 +
    'begin'#10 +
    '  Result := N + GCount;'#10 +
    'end;'#10 +
    'end.'#10;

begin
  GSM := TPasSourceManager.Create([]);
  GDefines := TPasDefines.Create(['MSWINDOWS', 'WIN32']);
  GPP := TPasPreprocessor.Create(GSM, GDefines);
  GPassed := 0;
  GFailed := 0;

  // 1. record + fields + var; type binding to a user type and a builtin
  Analyze(SRC_RECORD);
  Ok('record: TFoo type', HasSym('TFoo', skType));
  Ok('record: fields X,Y', (SymCountOf('x', skField) = 1) and
    (SymCountOf('y', skField) = 1));
  Ok('record: var G', HasSym('G', skVar));
  Ok('record: G : TFoo bound', TypeOf('g', skVar) = 'TFoo');
  Ok('record: field X : Integer bound', TypeOf('x', skField) = 'Integer');
  Ok('record: TFoo reference resolves', RefResolvesTo('TFoo', 'TFoo'));
  Ok('record: no diags', Length(GModel.Diags) = 0);
  GModel.Free;

  // 2. routine + params + local + body references
  Analyze(SRC_ROUTINE);
  Ok('routine: Sum', HasSym('Sum', skRoutine));
  Ok('routine: params A,B', HasSym('A', skParam) and HasSym('B', skParam));
  Ok('routine: local I', HasSym('I', skVar));
  Ok('routine: A referenced in body', RefResolvesTo('A', 'A'));
  Ok('routine: no diags', Length(GModel.Diags) = 0);
  GModel.Free;

  // 3. redeclaration -> E2004
  Analyze(SRC_REDECL);
  Ok('redecl: E2004 fired', DiagCount('E2004') = 1);
  GModel.Free;

  // 4. external (uses) names -> unresolved, NOT an error
  Analyze(SRC_EXTERNAL);
  Ok('external: SysUtils uses-ref', HasSym('SysUtils', skUnitRef));
  Ok('external: no E2003', DiagCount('E2003') = 0);
  Ok('external: no E2004', DiagCount('E2004') = 0);
  Ok('external: TStringList unbound', TypeOf('g', skVar) = '');
  GModel.Free;

  // 5. overloads -> two routines, no redeclaration error
  Analyze(SRC_OVERLOAD);
  Ok('overload: two P routines', SymCountOf('p', skRoutine) = 2);
  Ok('overload: no E2004', DiagCount('E2004') = 0);
  GModel.Free;

  // 6. sibling `for var` loops reusing a name -> loop-scoped, no E2004
  Analyze(SRC_FORVAR);
  Ok('for-var: no E2004', DiagCount('E2004') = 0);
  Ok('for-var: W referenced in body', RefResolvesTo('W', 'W'));
  GModel.Free;

  // 7. anonymous methods own their locals and implicit Result
  Analyze(SRC_ANON);
  Ok('anon: no E2004 (locals scoped)', DiagCount('E2004') = 0);
  Ok('anon: no E2010 (own Result)', DiagCount('E2010') = 0);
  GModel.Free;

  // 8. type declaration hides a used unit's leaf name
  Analyze(SRC_UNITHIDE);
  Ok('unit-hide: no E2004', DiagCount('E2004') = 0);
  Ok('unit-hide: Qos is the type', HasSym('Qos', skType));
  GModel.Free;

  // 9. call fitting no local overload stays untyped (no bogus E2010)
  Analyze(SRC_NOFIT);
  Ok('no-fit: E2034 fired', DiagCount('E2034') = 1);
  Ok('no-fit: no E2010', DiagCount('E2010') = 0);
  GModel.Free;

  // 9b. array-property index parameter name: not a false E2003, and two
  // properties reusing the SAME index name don't collide (E2004).
  Analyze(SRC_PROPINDEX);
  Ok('propindex: Items property declared', HasSym('Items', skProperty));
  Ok('propindex: Pairs property declared', HasSym('Pairs', skProperty));
  Ok('propindex: read Items -> GetItem resolves',
    RefResolvesTo('GetItem', 'GetItem'));
  Ok('propindex: read Pairs -> GetPair resolves',
    RefResolvesTo('GetPair', 'GetPair'));
  // The getter's OWN Index param (a different, ordinary routine-param scope)
  // still resolves normally inside its body — untouched by this fix.
  Ok('propindex: GetPair body Index resolves to its own param',
    RefResolvesTo('Index', 'Index'));
  Ok('propindex: no false E2003 (the index placeholder names)',
    DiagCount('E2003') = 0);
  Ok('propindex: no false E2004 (two properties reuse ''Index'')',
    DiagCount('E2004') = 0);
  GModel.Free;

  // 9c. implementation omits its own parameter list (method AND global
  // routine) — the omitted names must still resolve inside the body.
  Analyze(SRC_OMITPARAMS);
  Ok('omitparams: no false E2003', DiagCount('E2003') = 0);
  Ok('omitparams: method body Index resolves',
    RefResolvesTo('Index', 'Index'));
  GModel.Free;

  // 9c-septies. generic-instantiation result types survive name parsing.
  Analyze(SRC_GENRESULT);
  Ok('genresult: no diags at all', Length(GModel.Diags) = 0);
  Ok('genresult: TBox<Integer> result binds (was lost to the name loop)',
    TypeOf('makebox', skRoutine) = 'TBox');
  Ok('genresult: plain result still binds (control)',
    TypeOf('makenum', skRoutine) = 'Integer');
  GModel.Free;

  // 9c-sexies. {$SCOPEDENUMS} honored positionally.
  Analyze(SRC_SCOPEDENUMS);
  Ok('scopedenums: no diags at all', Length(GModel.Diags) = 0);
  // With the bug, `E: Exception` bound to the leaked enum VALUE, BindTypes
  // rejected it (not a type) and the declared type stayed empty.
  Ok('scopedenums: the builtin TYPE is not shadowed by the scoped value',
    TypeOf('e', skVar) = 'Exception');
  Ok('scopedenums: qualified TFlags.Broken resolves',
    AllRefsResolved('Broken'));
  Ok('scopedenums: unscoped TOpen still injects (bare Alpha)',
    RefResolvesTo('Alpha', 'Alpha'));
  Ok('scopedenums: POPOPT restored ON (TAfterPop.Gamma qualified works)',
    AllRefsResolved('Gamma'));
  GModel.Free;

  // 5.7 — a with member outranks a name Phase 1 already bound.
  Analyze(SRC_WITHSHADOW);
  Ok('withshadow: no diags at all', Length(GModel.Diags) = 0);
  // Each assignment is string-to-string ONLY if the member won; if the
  // local/param/global/implicit-Result binding survived it is Integer := string.
  Ok('withshadow: the member beats a local, a param, a global and Result',
    DiagCount('E2010') = 0);
  GModel.Free;

  // Real48 and OLE named arguments — both from that project's first run.
  Analyze(SRC_AVICLUSTERS);
  Ok('aviclusters: no diags at all', Length(GModel.Diags) = 0);
  Ok('aviclusters: Real48 is a seeded builtin', TypeOf('r', skVar) = 'Real48');
  // The named argument's NAME resolves to nothing and must not be a candidate;
  // the VALUE beside it is an ordinary expression and still binds.
  Ok('aviclusters: the named-arg NAME is not an undeclared-identifier candidate',
    DiagCount('E2003') = 0);
  Ok('aviclusters: the value beside it still resolves',
    RefResolvesTo('Counter', 'Counter'));
  GModel.Free;

  // A forward generic completing next to a non-generic sibling (a utility library's shape).
  Analyze(SRC_FWDGENERIC);
  Ok('fwdgeneric: no diags at all', Length(GModel.Diags) = 0);
  Ok('fwdgeneric: the generic method body sees its own field',
    DiagCount('E2003') = 0);
  Ok('fwdgeneric: the non-generic sibling still has its own',
    RefResolvesTo('FTag', 'FTag') and RefResolvesTo('FCursor', 'FCursor'));
  GModel.Free;

  // A directive word naming the next declaration (a component suite's shape).
  Analyze(SRC_DIRECTIVENAME);
  Ok('directivename: no diags at all', Length(GModel.Diags) = 0);
  Ok('directivename: the type named `Unsafe` is declared',
    HasSym('Unsafe', skType));
  Ok('directivename: and so is everything after it',
    HasSym('TSecond', skType) and HasSym('Index', skConst));
  Ok('directivename: the procedural var with `cdecl = nil` still parses',
    HasSym('Hook', skVar));
  GModel.Free;

  // 5.7 — target forms: inherited property, class reference, bare class type
  // name, interface.
  Analyze(SRC_WITHFORMS);
  Ok('withforms: no diags at all', Length(GModel.Diags) = 0);
  Ok('withforms: `with TCanvas do` reaches the class method',
    RefResolvesTo('Tick', 'Tick'));
  Ok('withforms: `with inherited Canvas do` reaches the property',
    RefResolvesTo('Pen', 'Pen'));
  Ok('withforms: `with AI do` reaches the interface method',
    RefResolvesTo('Go', 'Go'));
  GModel.Free;

  // Nested inline arrays indexed in one step.
  Analyze(SRC_NESTEDARRAY);
  Ok('nestedarray: no diags at all', Length(GModel.Diags) = 0);
  Ok('nestedarray: the with body sees the innermost element''s fields',
    RefResolvesTo('Weight', 'Weight') and RefResolvesTo('Direction', 'Direction'));
  GModel.Free;

  // An ANONYMOUS structured type in a declaration's type slot.
  Analyze(SRC_ANONSTRUCT);
  Ok('anonstruct: no diags at all', Length(GModel.Diags) = 0);
  Ok('anonstruct: the with body sees the inline record''s fields',
    RefResolvesTo('offset', 'offset') and RefResolvesTo('minimum', 'minimum'));
  GModel.Free;

  // ANONYMOUS enums are exempt from SCOPEDENUMS — there is no name to qualify.
  Analyze(SRC_ANONENUM);
  Ok('anonenum: no diags at all', Length(GModel.Diags) = 0);
  Ok('anonenum: a nested `set of (...)` injects its values',
    RefResolvesTo('SetChecked', 'SetChecked') and
    RefResolvesTo('CallClick', 'CallClick'));
  Ok('anonenum: a unit-level `set of (...)` does too',
    RefResolvesTo('Alpha', 'Alpha'));
  // Control: the exemption is keyed on ANONYMITY, so a named enum in the very
  // same unit must still be qualified-only (SRC_SCOPEDENUMS covers the bare-use
  // half; here it is enough that the qualified form is what compiles).
  Ok('anonenum: a NAMED enum in the same unit is still reached qualified',
    AllRefsResolved('Gamma'));
  GModel.Free;

  // 9c-quinquies. inline vars declaring several names at once.
  Analyze(SRC_INLINEVARS);
  Ok('inlinevars: no false E2003', DiagCount('E2003') = 0);
  Ok('inlinevars: no diags at all', Length(GModel.Diags) = 0);
  Ok('inlinevars: BOTH names of `var V, S: string` are declared',
    HasSym('V', skVar) and HasSym('S', skVar));
  Ok('inlinevars: BOTH names of `var I, J: Integer` are declared',
    HasSym('I', skVar) and HasSym('J', skVar));
  Ok('inlinevars: the shared type binds to the SECOND name too',
    (TypeOf('s', skVar) = 'string') and (TypeOf('j', skVar) = 'Integer'));
  Ok('inlinevars: the shared type still binds to the first',
    (TypeOf('v', skVar) = 'string') and (TypeOf('i', skVar) = 'Integer'));
  Ok('inlinevars: single-name control keeps its type',
    TypeOf('solo', skVar) = 'string');
  Ok('inlinevars: a type-less initializer is still resolved',
    RefResolvesTo('A', 'A'));
  GModel.Free;

  // 9c-quater. with-target shapes: cast, deref (plain / aliased / of a call).
  Analyze(SRC_WITHSHAPES);
  Ok('withshapes: no false E2003', DiagCount('E2003') = 0);
  Ok('withshapes: no diags at all', Length(GModel.Diags) = 0);
  Ok('withshapes: every VType reference resolves to the field',
    AllRefsResolved('VType') and RefResolvesTo('VType', 'VType'));
  // `with LO as TChild do Tag := 9` — the as-cast target, INTRA-UNIT.
  Ok('withshapes: as-cast target opens (Tag resolves)',
    AllRefsResolved('Tag') and RefResolvesTo('Tag', 'Tag'));
  Ok('withshapes: the call-target control still resolves (F)',
    RefResolvesTo('F', 'F'));
  GModel.Free;

  // 9c-quinquies. &-escaped identifiers (B.3) — same symbol as the bare form.
  Analyze(SRC_AMPERSAND);
  Ok('ampersand: no diags at all', Length(GModel.Diags) = 0);
  Ok('ampersand: no false E2003', DiagCount('E2003') = 0);
  // Declared plain, written `&Message` — the reference must reach the parameter.
  Ok('ampersand: &Message resolves to the plain-declared Message',
    RefResolvesTo('&Message', 'Message'));
  // Declared `&Handled`, written plain — the DECLARATION key must be stripped,
  // so the symbol is named `Handled` and the bare reference finds it.
  Ok('ampersand: plain Handled resolves to the &-declared parameter',
    RefResolvesTo('Handled', '&Handled'));
  Ok('ampersand: the &-declared symbol is keyed WITHOUT the ampersand',
    HasSym('Handled', skParam) and not HasSym('&Handled', skParam));
  // A genuine reserved word escaped into an identifier.
  Ok('ampersand: &begin declares and resolves an identifier named begin',
    RefResolvesTo('&begin', '&begin'));
  GModel.Free;

  // 9c-ter. class/record helper member injection, both directions.
  Analyze(SRC_HELPERS);
  Ok('helper: no false E2003', DiagCount('E2003') = 0);
  Ok('helper: bare const from the EXTENDED type''s own method',
    RefResolvesTo('Identity', 'Identity'));
  Ok('helper: qualified TMatrix.Identity resolves too',
    AllRefsResolved('Identity'));
  Ok('helper: bare const from a class method (Step)',
    RefResolvesTo('Step', 'Step'));
  Ok('helper: extended type''s field from the HELPER''s own body (FValue)',
    RefResolvesTo('FValue', 'FValue'));
  Ok('helper: bare helper method beats the same-named builtin (Double)',
    RefResolvesTo('Double', 'Double'));
  GModel.Free;

  // A helper for itself must not build a self-referential scope join.
  Analyze(SRC_HELPER_SELF);
  // Reaching this line at all IS the assertion: a self-join would have hung
  // (or blown the stack) inside Analyze above, never returning here.
  Ok('helper-self: analysis terminates (no scope-join cycle)', True);
  Ok('helper-self: the undeclared name is left unresolved, not bound',
    not AllRefsResolved('NoSuchNameAnywhere'));
  Ok('helper-self: K still declared in the helper', HasSym('K', skConst));
  GModel.Free;

  // 9c-bis. `label` sections declare their names; labeled statements and
  // `goto` bind to them. Numeric labels declare nothing and stay silent.
  Analyze(SRC_LABELS);
  Ok('labels: no false E2003', DiagCount('E2003') = 0);
  Ok('labels: no diags at all', Length(GModel.Diags) = 0);
  Ok('labels: notAscii declared as skLabel', HasSym('notAscii', skLabel));
  Ok('labels: again declared as skLabel', HasSym('again', skLabel));
  Ok('labels: every notAscii reference resolves',
    AllRefsResolved('notAscii'));
  Ok('labels: every again reference resolves', AllRefsResolved('again'));
  Ok('labels: numeric labels declare no symbol',
    (SymCountOf('1', skLabel) = 0) and (SymCountOf('2', skLabel) = 0));
  GModel.Free;

  // 9d. `with` statement member resolution.
  Analyze(SRC_WITHSTMT);
  Ok('with: no false E2003 (Caption/Index via the with-target)',
    DiagCount('E2003') = 0);
  Ok('with: Caption resolves to the with-target''s field',
    RefResolvesTo('Caption', 'Caption'));
  Ok('with: Index resolves to the with-target''s field',
    RefResolvesTo('Index', 'Index'));
  GModel.Free;

  Analyze(SRC_WITHMULTI);
  Ok('with-multi: no diags at all', Length(GModel.Diags) = 0);
  Ok('with-multi: last target (TB.X, string) wins over TA.X (Integer) — '
    + 'no E2010 from a wrong Integer->string assign',
    DiagCount('E2010') = 0);
  GModel.Free;

  Analyze(SRC_WITHNESTED);
  Ok('with-nested: no false E2003 (Y via nested with B, itself via A)',
    DiagCount('E2003') = 0);
  Ok('with-nested: Y resolves', RefResolvesTo('Y', 'Y'));
  GModel.Free;

  Analyze(SRC_WITHINHERIT);
  Ok('with-inherit: no diags at all', Length(GModel.Diags) = 0);
  Ok('with-inherit: Caption resolves (inherited from TBase)',
    RefResolvesTo('Caption', 'Caption'));
  Ok('with-inherit: Index resolves (TDerived''s own)',
    RefResolvesTo('Index', 'Index'));
  GModel.Free;

  // 9f. record variant parts: tag names are real fields, every tag-type form
  // parses, and an anonymous tag declares nothing.
  Analyze(SRC_VARIANT);
  Ok('variant: no diags at all', Length(GModel.Diags) = 0);
  for var LName in ['data', 'sub', 'Kind', 'Tag'] do
    Ok('variant: tag ' + LName + ' is a field', HasSym(LName, skField));
  for var LName in ['Head', 'whatever', 'inner', 'deep', 'other', 'thing',
    'Radius', 'W', 'H', 'A'] do
    Ok('variant: branch field ' + LName, HasSym(LName, skField));
  // The inline-enum tag type must yield real enum VALUES (they used to come
  // out as fields, with `(Radius: Double)` mis-parsed into an enum type).
  Ok('variant: inline enum tag values are enum values, not fields',
    HasSym('skCircle', skEnumValue) and HasSym('skRect', skEnumValue) and
    not HasSym('skCircle', skField));
  Ok('variant: Radius is a Double field, not an enum value',
    (TypeOf('radius', skField) = 'Double') and
    not HasSym('Radius', skEnumValue));
  Ok('variant: named tag binds its type (data : Integer)',
    TypeOf('data', skField) = 'Integer');
  // `case Integer of` must NOT invent a field named after the type.
  Ok('variant: anonymous tag declares no field',
    not HasSym('Integer', skField));

  // 9e. declaration-less compiler intrinsics (spec B.4.3) resolve from the
  // seeded System scope — and `Abort`, which is NOT one, still does not.
  Analyze(SRC_INTRINSICS);
  Ok('intrinsics: no diags at all', Length(GModel.Diags) = 0);
  for var LName in ['GetMem', 'FreeMem', 'ReallocMem', 'Assign', 'AssignFile',
    'Reset', 'Rewrite', 'Append', 'Close', 'CloseFile', 'Seek', 'Eof', 'Eoln',
    'SeekEof', 'SeekEoln', 'FilePos', 'FileSize', 'Truncate', 'Erase',
    'Rename', 'BlockRead', 'BlockWrite', 'GetDir', 'VarClear', 'VarCopy',
    'VarCast', 'VarArrayRedim', 'Halt', 'CompilerVersion', 'OpenString'] do
    Ok('intrinsics: ' + LName + ' resolves', AllRefsResolved(LName));
  GModel.Free;

  Analyze(SRC_NOTINTRINSIC);
  Ok('intrinsics: Abort is NOT seeded (needs System.SysUtils)',
    not AllRefsResolved('Abort'));
  GModel.Free;

  // 10. interface-only symbol ids are a prefix of the full model's ids
  begin
    var LPre := GPP.ProcessText('test.pas', SRC_STAGED);
    var LD: TArray<TPasParseDiag>;
    var LIntfTree := TPasParser.ParseFile(LPre, LD, {AInterfaceOnly} True);
    var LIntfModel := TPasSemaResolver.Analyze(LIntfTree);
    LPre := GPP.ProcessText('test.pas', SRC_STAGED);
    var LFullTree := TPasParser.ParseFile(LPre, LD, {AInterfaceOnly} False);
    var LFullModel := TPasSemaResolver.Analyze(LFullTree);
    try
      Ok('staged: intf model has fewer symbols than full',
        LIntfModel.SymCount < LFullModel.SymCount);
      // The interface declared these — all must exist in the intf-only model.
      var LHaveIntfSyms := True;
      var LNames: TArray<string> := ['TFoo', 'FX', 'Bar', 'Baz', 'GCount',
        'Helper'];
      for var LN in LNames do
      begin
        var LFound := False;
        for var LI := 0 to LIntfModel.SymCount - 1 do
          if SameText(LIntfModel.Symbols[LI].Name, LN) then
          begin
            LFound := True;
            Break;
          end;
        if not LFound then
          LHaveIntfSyms := False;
      end;
      Ok('staged: all interface symbols present in intf-only model',
        LHaveIntfSyms);
      // The id-stability invariant: every symbol the intf-only model holds
      // matches the full model's symbol at the SAME id (name + kind + scope).
      var LStable := True;
      for var LI := 0 to LIntfModel.SymCount - 1 do
        if not ((LIntfModel.Symbols[LI].Name = LFullModel.Symbols[LI].Name) and
          (LIntfModel.Symbols[LI].Kind = LFullModel.Symbols[LI].Kind) and
          (LIntfModel.Symbols[LI].Scope = LFullModel.Symbols[LI].Scope)) then
        begin
          LStable := False;
          Writeln(Format('  staged: sym %d differs: intf=%s/%d full=%s/%d',
            [LI, LIntfModel.Symbols[LI].Name,
             Ord(LIntfModel.Symbols[LI].Kind),
             LFullModel.Symbols[LI].Name, Ord(LFullModel.Symbols[LI].Kind)]));
        end;
      Ok('staged: interface symbol ids are a stable prefix of the full model',
        LStable);
    finally
      LIntfModel.Free;
      LFullModel.Free;
    end;
  end;


  // ---- member visibility is RECORDED (11.2.1) ----
  // Recording only: nothing enforces it yet, so this pins the data and, just
  // as importantly, the two rules that currently come out RIGHT because the
  // resolver ignores visibility and must keep doing so.
  Analyze(
    'unit u;'#10'interface'#10'type'#10 +
    '  TThing = class'#10 +
    '    FBeforeAny: Integer;'#10 +          // no section marker yet
    '  strict private'#10 +
    '    FStrictPriv: Integer;'#10 +
    '  private'#10 +
    '    FPriv: Integer;'#10 +
    '    type TInner = (ivOne, ivTwo);'#10 + // enum VALUES must still leak out
    '  strict protected'#10 +
    '    FStrictProt: Integer;'#10 +
    '  protected'#10 +
    '    FProt: Integer;'#10 +
    '  public'#10 +
    '    FPub, FPub2: Integer;'#10 +         // one child, two symbols
    '    procedure M;'#10 +
    '  published'#10 +
    '    property P: Integer read FPriv;'#10 +
    '  automated'#10 +
    '    FAuto: Integer;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure Use;'#10 +
    'var'#10 +
    '  E: Integer;'#10 +
    'begin'#10 +
    '  E := Ord(ivOne);'#10 +                // bare value from a PRIVATE nested type
    'end;'#10 +
    'procedure TThing.M; begin end;'#10 +
    'end.'#10);
  Ok('vis: before any section marker stays svDefault',
    VisOf('fbeforeany') = svDefault);
  Ok('vis: strict private', VisOf('fstrictpriv') = svStrictPrivate);
  Ok('vis: private', VisOf('fpriv') = svPrivate);
  Ok('vis: strict protected', VisOf('fstrictprot') = svStrictProtected);
  Ok('vis: protected', VisOf('fprot') = svProtected);
  Ok('vis: public', VisOf('fpub') = svPublic);
  Ok('vis: every name of a multi-name field group, not just the first',
    VisOf('fpub2') = svPublic);
  Ok('vis: a method too', VisOf('m') = svPublic);
  Ok('vis: published property', VisOf('p') = svPublished);
  Ok('vis: legacy automated is kept distinct from published',
    VisOf('fauto') = svAutomated);
  // The two accidental-correct rules. Enforcement must preserve both: 2.2.4
  // says a nested enum's VALUES leak into the enclosing section regardless of
  // the enum's or its container's visibility (dcc-verified), and the nested
  // TYPE name is itself private.
  Ok('vis: the nested type name carries its section''s visibility',
    VisOf('tinner') = svPrivate);
  Ok('vis: ...but its VALUES still resolve bare from outside the class',
    RefResolvesTo('ivOne', 'ivOne') and (DiagCount('E2003') = 0));
  GModel.Free;

  // ---- E2081: the for counter is read-only in the body (5.5.1) ----
  // All three shapes dcc reports, and the three that must stay silent.
  Analyze(
    'unit u;'#10'interface'#10'implementation'#10 +
    'procedure P;'#10 +
    'var I, J, N: Integer;'#10 +
    'begin'#10 +
    '  for I := 1 to 3 do'#10 +
    '    I := 5;'#10 +                    // 1: direct assignment
    '  for J := 1 to 3 do'#10 +
    '    Inc(J);'#10 +                    // 2: var-param mutation
    '  for N := 1 to 3 do'#10 +
    '  begin'#10 +
    '    I := N;'#10 +                    // reading the counter is fine
    '    Inc(I);'#10 +                    // mutating something else is fine
    '  end;'#10 +
    '  I := 9;'#10 +                      // after the loop is fine
    'end;'#10 +
    'procedure Q;'#10 +
    'begin'#10 +
    '  for var K := 1 to 3 do'#10 +
    '    K := 5;'#10 +                    // 3: inline counter
    'end;'#10 +
    'end.'#10);
  Ok('e2081: three reports, one per shape', DiagCount('E2081') = 3);
  Ok('e2081: names the variable', DiagHasText('E2081', '''I'''));
  Ok('e2081: and the inline one', DiagHasText('E2081', '''K'''));
  Ok('e2081: nothing else fires', DiagCount('E2003') = 0);
  GModel.Free;

  // A NESTED loop reusing the outer counter reports the write once, not once
  // per enclosing walk.
  Analyze(
    'unit u;'#10'interface'#10'implementation'#10 +
    'procedure P;'#10 +
    'var I, J: Integer;'#10 +
    'begin'#10 +
    '  for I := 1 to 3 do'#10 +
    '    for J := 1 to 3 do'#10 +
    '      I := 0;'#10 +
    'end;'#10 +
    'end.'#10);
  Ok('e2081: reported once from inside a nested loop', DiagCount('E2081') = 1);
  GModel.Free;

  // ---- E2145: a bare `raise` needs a handler (18.3.1) ----
  // The five shapes dcc rejects. Counted, not located, because the whole
  // fixture is one line.
  Analyze(
    'unit u;'#10'interface'#10'implementation'#10 +
    'procedure P;'#10 +
    'begin'#10 +
    '  raise;'#10 +                              // 1: plain body
    '  try raise; except end;'#10 +              // 2: the guarded block
    '  try finally raise; end;'#10 +             // 3: a finally part
    '  try except try finally raise; end; end;'#10 + // 4: finally in a handler
    '  try except try raise; except end; end;'#10 +  // 5: try body in a handler
    'end;'#10 +
    'procedure Q;'#10 +
    'begin'#10 +
    '  raise;'#10 +                              // 6: a second routine
    'end;'#10 +
    'end.'#10);
  Ok('e2145: one report per offending raise', DiagCount('E2145') = 6);
  Ok('e2145: dcc''s wording',
    DiagHasText('E2145', 'only allowed in exception handler'));
  GModel.Free;

  // Everything dcc accepts, including the two that surprise: a handler nested
  // inside a `finally` is a handler again, and an anonymous method body does
  // NOT reset the context the way a try part does.
  Analyze(
    'unit u;'#10'interface'#10'implementation'#10 +
    'type TProc = reference to procedure;'#10 +
    'type EMy = class end;'#10 +
    'procedure P;'#10 +
    'var LProc: TProc;'#10 +
    'begin'#10 +
    '  try except raise; end;'#10 +              // catch-all handler
    '  try except on E: EMy do raise; end;'#10 + // an on-handler
    '  try except on E: EMy do ; else raise; end;'#10 + // the else branch
    '  try finally try except raise; end; end;'#10 +    // handler in a finally
    '  try try except raise; end; finally end;'#10 +    // handler in a try body
    '  try except LProc := procedure begin raise; end; end;'#10 + // anon method
    'end;'#10 +
    'end.'#10);
  Ok('e2145: silent on every shape dcc accepts', DiagCount('E2145') = 0);
  GModel.Free;

  // A named nested routine is not lexically inside the handler, so its body
  // starts with no context — dcc rejects it and so must we.
  Analyze(
    'unit u;'#10'interface'#10'implementation'#10 +
    'procedure P;'#10 +
    '  procedure Inner;'#10 +
    '  begin'#10 +
    '    raise;'#10 +
    '  end;'#10 +
    'begin'#10 +
    '  try except Inner; end;'#10 +
    'end;'#10 +
    'end.'#10);
  Ok('e2145: a nested routine called FROM a handler is still not in one',
    DiagCount('E2145') = 1);
  GModel.Free;

  // `raise E` is never this diagnostic, wherever it sits.
  Analyze(
    'unit u;'#10'interface'#10'implementation'#10 +
    'type EMy = class constructor Create(const AMsg: string); end;'#10 +
    'constructor EMy.Create(const AMsg: string);'#10 +
    'begin'#10 +
    'end;'#10 +
    'procedure P;'#10 +
    'begin'#10 +
    '  raise EMy.Create(''boom'');'#10 +
    '  try finally raise EMy.Create(''x''); end;'#10 +
    'end;'#10 +
    'end.'#10);
  Ok('e2145: a raise WITH an operand is not a re-raise',
    DiagCount('E2145') = 0);
  GModel.Free;

  // ---- E2193: Slice only in an open-array argument position (4.11) ----
  // Every shape dcc rejects that does not need parameter types: the two
  // intrinsic ones are the surprise (`Insert`'s first parameter IS an open
  // array, and dcc rejects it anyway).
  Analyze(
    'unit u;'#10'interface'#10'implementation'#10 +
    'type TDyn = array of Integer;'#10 +
    'procedure TakesOpen(const A: array of Integer); begin end;'#10 +
    'procedure P;'#10 +
    'var LArr: array[0..9] of Integer; LD: TDyn; LI: Integer;'#10 +
    'begin'#10 +
    '  LD := Slice(LArr, 3);'#10 +                 // assignment RHS
    '  LI := Length(Slice(LArr, 3));'#10 +         // argument of an intrinsic
    '  Insert(Slice(LArr, 3), LD, 0);'#10 +        // ...even this one
    '  Slice(LArr, 3);'#10 +                       // a statement
    '  TakesOpen([Slice(LArr, 3)]);'#10 +          // an array constructor
    '  TakesOpen(Slice(Slice(LArr, 5), 3));'#10 +  // Slice of a Slice
    '  if Slice(LArr, 3)[0] = LI then Exit;'#10 +  // an index base
    'end;'#10 +
    'end.'#10);
  Ok('e2193: one report per bad position', DiagCount('E2193') = 7);
  Ok('e2193: dcc''s wording',
    DiagHasText('E2193', 'only allowed as open array argument'));
  GModel.Free;

  // The sanctioned position, in all three forms dcc accepts — including a
  // Slice of an open-array parameter, which is how the RTL uses it.
  Analyze(
    'unit u;'#10'interface'#10'implementation'#10 +
    'procedure TakesOpen(const A: array of Integer); begin end;'#10 +
    'procedure TakesOpenVar(var A: array of Integer); begin end;'#10 +
    'procedure Q(const A: array of Integer);'#10 +
    'begin'#10 +
    '  TakesOpen(Slice(A, 2));'#10 +
    'end;'#10 +
    'procedure P;'#10 +
    'var LArr: array[0..9] of Integer;'#10 +
    'begin'#10 +
    '  TakesOpen(Slice(LArr, 3));'#10 +
    '  TakesOpenVar(Slice(LArr, 3));'#10 +
    'end;'#10 +
    'end.'#10);
  Ok('e2193: silent in an argument position', DiagCount('E2193') = 0);
  GModel.Free;

  // A user routine that happens to be called Slice is an ordinary call, so
  // neither it nor its arguments are this rule's business.
  Analyze(
    'unit u;'#10'interface'#10'implementation'#10 +
    'type TDyn = array of Integer;'#10 +
    'function Slice(const A: TDyn; N: Integer): TDyn; begin end;'#10 +
    'procedure P;'#10 +
    'var LD: TDyn;'#10 +
    'begin'#10 +
    '  LD := Slice(LD, 3);'#10 +
    'end;'#10 +
    'end.'#10);
  Ok('e2193: a user routine of that name is not the intrinsic',
    DiagCount('E2193') = 0);
  GModel.Free;

  // An ordinary call whose parameter at that index is NOT an open array. Needs
  // a single unambiguous candidate, so the overloaded pair below must stay
  // silent even though dcc rejects it.
  Analyze(
    'unit u;'#10'interface'#10'implementation'#10 +
    'type TDyn = array of Integer;'#10 +
    'procedure TakesInt(A: Integer); begin end;'#10 +
    'procedure TakesDyn(const A: TDyn); begin end;'#10 +
    'procedure TakesTwo(N: Integer; const A: array of Integer); begin end;'#10 +
    'procedure TakesConst(const A: array of const); begin end;'#10 +
    'procedure Over(A: Integer); overload; begin end;'#10 +
    'procedure Over(const A: array of Integer); overload; begin end;'#10 +
    'procedure P;'#10 +
    'var LArr: array[0..9] of Integer;'#10 +
    'begin'#10 +
    '  TakesInt(Slice(LArr, 3));'#10 +          // reported
    '  TakesDyn(Slice(LArr, 3));'#10 +          // reported
    '  TakesTwo(1, Slice(LArr, 3));'#10 +       // the SECOND parameter is open
    '  TakesTwo(Slice(LArr, 3), LArr);'#10 +    // ...the first is not: reported
    '  TakesConst(Slice(LArr, 3));'#10 +        // `array of const` is open too
    '  Over(Slice(LArr, 3));'#10 +              // overloaded: not ranked here
    'end;'#10 +
    'end.'#10);
  Ok('e2193: a non-open-array parameter position', DiagCount('E2193') = 3);
  GModel.Free;

  // ---- E2001/E2032: only ordinal types index, base a set, count a loop ----
  Analyze(
    'unit u;'#10'interface'#10 +
    'type'#10 +
    '  TRec = record X: Integer; end;'#10 +
    '  TCls = class end;'#10 +
    '  TIntf = interface end;'#10 +
    '  TDyn = array of Integer;'#10 +
    '  TSetB = set of 0..7;'#10 +
    '  TProcT = procedure;'#10 +
    '  A1 = array[Double] of Integer;'#10 +
    '  A2 = array[string] of Integer;'#10 +
    '  A3 = array[TRec] of Integer;'#10 +
    '  A4 = array[TCls] of Integer;'#10 +
    '  A5 = array[TIntf] of Integer;'#10 +
    '  A6 = array[TDyn] of Integer;'#10 +
    '  A7 = array[TSetB] of Integer;'#10 +
    '  A8 = array[TProcT] of Integer;'#10 +
    '  A9 = array[Variant] of Integer;'#10 +   // NOT ordinal here (dcc)
    '  A10 = array[Pointer] of Integer;'#10 +
    '  S1 = set of Double;'#10 +
    '  S2 = set of string;'#10 +
    '  S3 = set of TRec;'#10 +
    '  S4 = set of Variant;'#10 +
    'implementation'#10'end.'#10);
  Ok('e2001: every definitely-non-ordinal index and base',
    DiagCount('E2001') = 14);
  Ok('e2001: dcc''s wording', DiagHasText('E2001', 'Ordinal type required'));
  GModel.Free;

  // The ordinal ones, including a SPARSE enum — which dcc accepts everywhere,
  // against what 2.1.1/2.2.4 used to claim.
  Analyze(
    'unit u;'#10'interface'#10 +
    'type'#10 +
    '  TSparse = (spA = 0, spB = 10, spC = 99);'#10 +
    '  TDense = (dA, dB, dC);'#10 +
    '  TSub = 1..10;'#10 +
    '  TNeg = -5..5;'#10 +
    '  B1 = array[TSparse] of Integer;'#10 +
    '  B2 = array[TDense] of Integer;'#10 +
    '  B3 = array[TSub] of Integer;'#10 +
    '  B4 = array[TNeg] of Integer;'#10 +
    '  B5 = array[Boolean] of Integer;'#10 +
    '  B6 = array[Char] of Integer;'#10 +
    '  B7 = array[0..9, TDense] of Integer;'#10 +
    '  B8 = array of TSub;'#10 +             // dynamic: no index to check
    '  C1 = set of TSparse;'#10 +
    '  C2 = set of TSub;'#10 +
    '  C3 = set of Boolean;'#10 +
    'implementation'#10'end.'#10);
  Ok('e2001: silent on every ordinal index and base, sparse enum included',
    DiagCount('E2001') = 0);
  GModel.Free;

  // E2032 — the same rule for a `for` counter, with dcc's own message. Variant
  // is an error HERE and legal as a `case` selector: per position, not per type.
  Analyze(
    'unit u;'#10'interface'#10'implementation'#10 +
    'type TRec = record X: Integer; end;'#10 +
    'procedure P;'#10 +
    'var LD: Double; LS: string; LR: TRec; LV: Variant;'#10 +
    '  LE: (eA, eB); LB: Boolean; LC: Char; LI: Integer;'#10 +
    'begin'#10 +
    '  for LD := 1 to 3 do LI := 0;'#10 +
    '  for LS := ''a'' to ''c'' do LI := 0;'#10 +
    '  for LR := 1 to 3 do LI := 0;'#10 +
    '  for LV := 1 to 3 do LI := 0;'#10 +
    '  for LE := eA to eB do LI := 0;'#10 +   // ordinal from here down
    '  for LB := False to True do LI := 0;'#10 +
    '  for LC := ''a'' to ''z'' do LI := 0;'#10 +
    '  for LI := 1 to 3 do LB := True;'#10 +
    'end;'#10 +
    'end.'#10);
  Ok('e2032: one per non-ordinal counter', DiagCount('E2032') = 4);
  Ok('e2032: dcc''s wording',
    DiagHasText('E2032', 'For loop control variable must have ordinal type'));
  GModel.Free;

  // ---- E2012 / E2001 in the two EXPRESSION positions (2.2.2, 2.1.1) ----
  Analyze(
    'unit u;'#10'interface'#10'implementation'#10 +
    'type'#10 +
    '  TCls = class end;'#10 +
    '  TIntf = interface end;'#10 +
    '  TSetB = set of 0..7;'#10 +
    '  TDyn = array of Integer;'#10 +
    'procedure P;'#10 +
    'var LI: Integer; LD: Double; LCh: Char; LS: string;'#10 +
    '  LE: (eA, eB); LSet: TSetB; LA: TDyn; LC: TCls; LIf: TIntf;'#10 +
    '  LB: Boolean;'#10 +
    'begin'#10 +
    '  if LI then LB := True;'#10 +
    '  while LD do LB := True;'#10 +
    '  repeat until LS;'#10 +
    '  if LCh then LB := True;'#10 +
    '  if LSet then LB := True;'#10 +
    '  if LA then LB := True;'#10 +
    '  if LC then LB := True;'#10 +
    '  if LIf then LB := True;'#10 +
    '  if LB then LB := False;'#10 +          // legal from here down
    '  while LB and (LI > 0) do LB := False;'#10 +
    '  repeat until LI = 0;'#10 +
    'end;'#10 +
    'end.'#10);
  Ok('e2012: one per definitely-non-Boolean guard', DiagCount('E2012') = 8);
  Ok('e2012: dcc''s wording',
    DiagHasText('E2012', 'Type of expression must be BOOLEAN'));
  GModel.Free;

  // The two exemptions dcc forces, and the one that cost six false positives on
  // a real-project corpus before it was understood: a parameterless function
  // reference in a value position is CALLED, so its RESULT is the condition's
  // type. A Variant guard is legal too.
  Analyze(
    'unit u;'#10'interface'#10'implementation'#10 +
    'type'#10 +
    '  TPred = reference to function: Boolean;'#10 +
    '  TRecB = record'#10 +
    '    class operator Implicit(const A: TRecB): Boolean;'#10 +
    '  end;'#10 +
    'class operator TRecB.Implicit(const A: TRecB): Boolean;'#10 +
    'begin'#10 +
    '  Result := True;'#10 +
    'end;'#10 +
    'procedure P(const AStop: TPred);'#10 +
    'var LV: Variant; LR: TRecB; LB: Boolean;'#10 +
    'begin'#10 +
    '  if AStop then LB := True;'#10 +
    '  if LV then LB := True;'#10 +
    '  if LR then LB := True;'#10 +
    '  case LV of 1: LB := True; end;'#10 +
    'end;'#10 +
    'end.'#10);
  Ok('e2012: silent on a function reference, a Variant and a Boolean-convertible'
    + ' record', DiagCount('E2012') = 0);
  Ok('e2001: a Variant case selector is legal', DiagCount('E2001') = 0);
  GModel.Free;

  // The `case` selector: same code as the type positions, different exemptions
  // — a record is an error here even with an Implicit operator to an ordinal.
  Analyze(
    'unit u;'#10'interface'#10'implementation'#10 +
    'type'#10 +
    '  TCls = class end;'#10 +
    '  TRecI = record'#10 +
    '    class operator Implicit(const A: TRecI): Integer;'#10 +
    '  end;'#10 +
    'class operator TRecI.Implicit(const A: TRecI): Integer;'#10 +
    'begin'#10 +
    '  Result := 0;'#10 +
    'end;'#10 +
    'procedure P;'#10 +
    'var LD: Double; LS: string; LC: TCls; LR: TRecI;'#10 +
    '  LI: Integer; LB: Boolean; LCh: Char;'#10 +
    'begin'#10 +
    '  case LD of 1: LB := True; end;'#10 +
    '  case LS of ''a'': LB := True; end;'#10 +
    '  case LC of  end;'#10 +
    '  case LR of 1: LB := True; end;'#10 +
    '  case LI of 1: LB := True; end;'#10 +      // ordinal from here down
    '  case LB of True: LI := 0; end;'#10 +
    '  case LCh of ''a'': LI := 0; end;'#10 +
    'end;'#10 +
    'end.'#10);
  Ok('e2001: one per non-ordinal case selector, records included',
    DiagCount('E2001') = 4);
  GModel.Free;

  // ---- E2028: a set base holds at most 256 values, all in 0..255 (2.4.1) ----
  Analyze(
    'unit u;'#10'interface'#10 +
    'type'#10 +
    '  TNeg = -5..5;'#10 +
    '  TBigEnum = (beA = 0, beB = 256);'#10 +
    // Implicit successors after an explicit value creep past 255 — dcc-verified
    // that six of them (ending at 255) are legal and seven are not.
    '  TCreep = (cA = 250, cB, cC, cD, cE, cF, cG);'#10 +
    '  S1 = set of Word;'#10 +
    '  S2 = set of Integer;'#10 +
    '  S3 = set of ShortInt;'#10 +
    '  S4 = set of 0..256;'#10 +
    '  S5 = set of -1..10;'#10 +
    '  S6 = set of TNeg;'#10 +              // through a named subrange
    '  S7 = set of TBigEnum;'#10 +
    '  S8 = set of TCreep;'#10 +
    '  S9 = set of $00..$100;'#10 +         // hex bounds
    'implementation'#10'end.'#10);
  Ok('e2028: one per oversized or out-of-range base',
    DiagCount('E2028') = 9);
  Ok('e2028: dcc''s wording',
    DiagHasText('E2028', 'Sets may have at most 256 elements'));
  GModel.Free;

  // Legal bases, plus the two dcc does NOT make an error and the ones this
  // check cannot compute and so must leave alone.
  Analyze(
    'unit u;'#10'interface'#10 +
    'const CHi = 300;'#10 +
    'type'#10 +
    '  TSparse = (spA = 0, spB = 10, spC = 99);'#10 +
    '  TDense = (dA, dB, dC);'#10 +
    '  T255 = 0..255;'#10 +
    '  S1 = set of Byte;'#10 +
    '  S2 = set of Boolean;'#10 +
    '  S3 = set of AnsiChar;'#10 +
    '  S4 = set of 0..255;'#10 +
    '  S5 = set of T255;'#10 +
    '  S6 = set of TSparse;'#10 +
    '  S7 = set of TDense;'#10 +
    '  S8 = set of ''a''..''z'';'#10 +      // W1050 in dcc, not an error
    '  S9 = set of Char;'#10 +              // likewise
    '  S12 = set of (fA = 250, fB, fC, fD, fE, fF);'#10 +   // ends at 255
    '  S11 = set of 0..CHi;'#10 +           // a named constant: not computed
    'implementation'#10'end.'#10);
  Ok('e2028: silent on every legal base, on `set of Char`, and on bounds it'
    + ' cannot fold', DiagCount('E2028') = 0);
  GModel.Free;

  // ---- ARITY is part of a type's identity (16.3) ----
  // One third-party library's base unit, exactly: a GENERIC record named `Pointer<T>`
  // beside the builtin. A bare `Pointer` means the builtin however much nearer
  // the generic is, so none of this is a type error.
  Analyze(
    'unit u;'#10'interface'#10 +
    'type'#10 +
    '  Pointer<T> = record'#10 +
    '    type P = ^T;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure P(out Obj);'#10 +
    'begin'#10 +
    '  Pointer(Obj) := nil;'#10 +
    'end;'#10 +
    'function Q: Pointer;'#10 +
    'begin'#10 +
    '  Result := nil;'#10 +
    'end;'#10 +
    'end.'#10);
  Ok('arity: a bare name binds to the BUILTIN, not the same-named generic',
    RefBindKind('Pointer', 0) = 'builtin');
  Ok('arity: ...and the return type too', RefBindKind('Pointer', 1) = 'builtin');
  Ok('arity: so `Pointer(X) := nil` is not a type error',
    DiagCount('E2010') = 0);
  GModel.Free;

  // The other direction: WITH type arguments the generic is what is meant.
  Analyze(
    'unit u;'#10'interface'#10 +
    'type'#10 +
    '  Pointer<T> = record'#10 +
    '    V: T;'#10 +
    '  end;'#10 +
    '  TUse = Pointer<Integer>;'#10 +
    'implementation'#10'end.'#10);
  Ok('arity: `Name<T>` still binds to the generic',
    RefBindKind('Pointer', 0) = 'generic');
  GModel.Free;

  // A non-generic of that name declared in the SAME unit beside the generic —
  // the same-scope chain rather than the system seed.
  Analyze(
    'unit u;'#10'interface'#10 +
    'type'#10 +
    '  TBox<T> = record'#10 +
    '    V: T;'#10 +
    '  end;'#10 +
    '  TBox = class'#10 +
    '    F: Integer;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure P;'#10 +
    'var LB: TBox;'#10 +
    'begin'#10 +
    '  LB := nil;'#10 +
    'end;'#10 +
    'end.'#10);
  Ok('arity: a bare name prefers the non-generic in its OWN scope',
    RefBindKind('TBox', 0) = 'type');
  GModel.Free;

  // And with NO non-generic anywhere the binding is kept rather than dropped:
  // dcc calls that an error, but losing the reference would cost navigation.
  Analyze(
    'unit u;'#10'interface'#10 +
    'type'#10 +
    '  TOnly<T> = record'#10 +
    '    V: T;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure P;'#10 +
    'var LO: TOnly;'#10 +
    'begin'#10 +
    'end;'#10 +
    'end.'#10);
  Ok('arity: with only a generic in scope the generic binding is kept',
    RefBindKind('TOnly', 0) = 'generic');
  GModel.Free;

  // The OTHER direction, and that library's other trap: `Nullable` (arity 0, with a
  // string class var `HasValue`) beside `Nullable<T>` (with a Boolean property
  // of that name). A reference WITH type arguments must select the generic, or
  // `other.HasValue` finds the string and `not other.HasValue` is E2015.
  Analyze(
    'unit u;'#10'interface'#10 +
    'type'#10 +
    '  Nul = record'#10 +
    '    class var HasValue: string;'#10 +
    '  end;'#10 +
    '  Nul<T> = record'#10 +
    '    function GetHasValue: Boolean;'#10 +
    '    function Equals(const other: Nul<T>): Boolean;'#10 +
    '    property HasValue: Boolean read GetHasValue;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function Nul<T>.GetHasValue: Boolean;'#10 +
    'begin'#10 +
    '  Result := True;'#10 +
    'end;'#10 +
    'function Nul<T>.Equals(const other: Nul<T>): Boolean;'#10 +
    'begin'#10 +
    '  if not HasValue then'#10 +
    '    Exit(not other.HasValue);'#10 +
    '  Result := True;'#10 +
    'end;'#10 +
    'end.'#10);
  Ok('arity: `Name<T>` skips the same-named NON-generic',
    RefBindKind('Nul', 0) = 'generic');
  Ok('arity: ...so a member on it is the generic''s, not the other record''s',
    DiagCount('E2015') = 0);
  GModel.Free;

  // ---- `&&`-prefixed names (B.3) ----
  // One '&' escapes and the rest belong to the NAME, so `&&op_Equality` is a
  // different member from `op_Equality` — dcc accepts both in one record and
  // rejects `&op_Equality` beside `op_Equality`. Before this, the stray '&'
  // token derailed the class body and its parameters were declared into the
  // enclosing scope (5 false E2004 in its TValue).
  Analyze(
    'unit u;'#10'interface'#10 +
    'type'#10 +
    '  TVal = record'#10 +
    '    class function &&op_Equality(const l, r: TVal): Boolean; static;'#10 +
    '    class function &&op_Inequality(const l, r: TVal): Boolean; static;'#10 +
    '    class function op_Equality(const l, r: TVal): Boolean; static;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'class function TVal.&&op_Equality(const l, r: TVal): Boolean;'#10 +
    'begin'#10 +
    '  Result := True;'#10 +
    'end;'#10 +
    'class function TVal.&&op_Inequality(const l, r: TVal): Boolean;'#10 +
    'begin'#10 +
    '  Result := False;'#10 +
    'end;'#10 +
    'class function TVal.op_Equality(const l, r: TVal): Boolean;'#10 +
    'begin'#10 +
    '  Result := True;'#10 +
    'end;'#10 +
    'end.'#10);
  Ok('amp: the class body survives, so no parameter is redeclared',
    DiagCount('E2004') = 0);
  Ok('amp: `&&op_Equality` and `op_Equality` are DIFFERENT members',
    (SymCountOf('&op_equality', skRoutine) = 1) and
    (SymCountOf('op_equality', skRoutine) = 1));
  GModel.Free;

  // MemoryBarrier is compiler-provided (dcc resolves it with an empty uses
  // clause) and was the last unseeded intrinsic that library needed.
  Analyze(
    'unit u;'#10'interface'#10'implementation'#10 +
    'procedure P;'#10 +
    'begin'#10 +
    '  MemoryBarrier;'#10 +
    'end;'#10 +
    'end.'#10);
  Ok('MemoryBarrier is seeded', DiagCount('E2003') = 0);
  GModel.Free;

  // A 64-bit ordinal base is dcc's OTHER code, and the two platform-sized names
  // follow the target: dcc32 E2028, dcc64 E2001 for the same source.
  Analyze(
    'unit u;'#10'interface'#10 +
    'type'#10 +
    '  S1 = set of Int64;'#10 +
    '  S2 = set of UInt64;'#10 +
    '  S3 = set of NativeInt;'#10 +
    '  S4 = set of NativeUInt;'#10 +
    '  S5 = set of ByteBool;'#10 +      // one byte, and still E2028
    '  S6 = set of Boolean;'#10 +       // ...unlike Boolean
    'implementation'#10'end.'#10);
  Ok('e2001: Int64 and UInt64 bases, plus 32-bit NativeInt as E2028',
    (DiagCount('E2001') = 2) and (DiagCount('E2028') = 3));
  GModel.Free;
  AnalyzeOn(pfWin64,
    'unit u;'#10'interface'#10 +
    'type'#10 +
    '  S1 = set of Int64;'#10 +
    '  S3 = set of NativeInt;'#10 +
    '  S4 = set of NativeUInt;'#10 +
    'implementation'#10'end.'#10);
  Ok('e2001: ...and all three as E2001 on a 64-bit target',
    (DiagCount('E2001') = 3) and (DiagCount('E2028') = 0));
  GModel.Free;
  Writeln(Format('=== SemaSmoke: %d passed, %d failed ===', [GPassed, GFailed]));
  if GFailed > 0 then
    ExitCode := 1;
  GPP.Free;
  GDefines.Free;
  GSM.Free;
end.
