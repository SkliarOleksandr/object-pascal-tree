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

function SymCountOf(const ANameLower: string; AKind: TSemaSymbolKind): Integer;
begin
  Result := 0;
  for var LIdx := 0 to GModel.SymCount - 1 do
    if (GModel.Symbols[LIdx].NameLower = ANameLower) and
       (GModel.Symbols[LIdx].Kind = AKind) then
      Inc(Result);
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
    'implementation'#10 +
    'function GetRec: TRec; begin Result.F := 1; end;'#10 +
    'function GetPtr: PVarLike; begin Result := nil; end;'#10 +
    'procedure P;'#10 +
    'var'#10 +
    '  Buf: array[0..3] of Integer;'#10 +
    '  LP: PVarLike;'#10 +
    '  LA: PAlias;'#10 +
    '  LI: Integer;'#10 +
    'begin'#10 +
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

  // 9c-quater. with-target shapes: cast, deref (plain / aliased / of a call).
  Analyze(SRC_WITHSHAPES);
  Ok('withshapes: no false E2003', DiagCount('E2003') = 0);
  Ok('withshapes: no diags at all', Length(GModel.Diags) = 0);
  Ok('withshapes: every VType reference resolves to the field',
    AllRefsResolved('VType') and RefResolvesTo('VType', 'VType'));
  Ok('withshapes: the call-target control still resolves (F)',
    RefResolvesTo('F', 'F'));
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

  Writeln(Format('=== SemaSmoke: %d passed, %d failed ===', [GPassed, GFailed]));
  if GFailed > 0 then
    ExitCode := 1;
  GPP.Free;
  GDefines.Free;
  GSM.Free;
end.
