program SemaXTypeSmoke;

{ Phase-3c cross-model typing smoke tests: writes tiny unit fixtures to a
  temp dir, runs the project analyzer, and checks ExprTypeX — cross-unit
  Var.Field access, ancestor/alias member walks, constructor calls, and
  generic-parameter substitution (TWrap<Integer>.Get -> Integer). }

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
  PasTree.Project in '..\source\PasTree.Project.pas',
  PasTree.Sema.Diagnostics in '..\source\PasTree.Sema.Diagnostics.pas',
  PasTree.Sema.Model in '..\source\PasTree.Sema.Model.pas',
  PasTree.Sema.Builtins in '..\source\PasTree.Sema.Builtins.pas',
  PasTree.Sema.Resolver in '..\source\PasTree.Sema.Resolver.pas',
  PasTree.Sema.Dump in '..\source\PasTree.Sema.Dump.pas',
  PasTree.Sema.Project in '..\source\PasTree.Sema.Project.pas';

var
  GProj: TPasSemaProject;
  GPassed, GFailed: Integer;

const
  UNIT_XA =
    'unit XA;'#10'interface'#10 +
    'type'#10 +
    '  TPair = record'#10 +
    '    X: Integer;'#10 +
    '    Y: Integer;'#10 +
    '  end;'#10 +
    '  TBase = class'#10 +
    '    FP: TPair;'#10 +
    '    constructor Create;'#10 +
    '    function Half: Integer;'#10 +
    '  end;'#10 +
    '  TDerived = class(TBase)'#10 +
    '    FS: string;'#10 +
    '  end;'#10 +
    '  TAlias = TDerived;'#10 +
    'implementation'#10 +
    'constructor TBase.Create; begin end;'#10 +
    'function TBase.Half: Integer; begin Result := 0; end;'#10 +
    'end.'#10;

  UNIT_XG =
    'unit XG;'#10'interface'#10 +
    'type'#10 +
    '  TWrap<T> = class'#10 +
    '    FValue: T;'#10 +
    '    constructor Create;'#10 +
    '    function Get: T;'#10 +
    '    property Value: T read FValue;'#10 +
    '  end;'#10 +
    '  TPairWrap<TKey, TVal> = class'#10 +
    '    FKey: TKey;'#10 +
    '    FVal: TVal;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'constructor TWrap<T>.Create; begin end;'#10 +
    'function TWrap<T>.Get: T; begin Result := FValue; end;'#10 +
    'end.'#10;

  UNIT_XU =
    'unit XU;'#10'interface'#10'uses XA, XG;'#10 +
    'var'#10 +
    '  GD: TDerived;'#10 +
    '  GA: TAlias;'#10 +
    '  GW: TWrap<Integer>;'#10 +
    '  GN: TWrap<TWrap<string>>;'#10 +
    '  GP: TPairWrap<string, Boolean>;'#10 +
    'implementation'#10 +
    'procedure Use;'#10 +
    'var'#10 +
    '  LI: Integer;'#10 +
    '  LS: string;'#10 +
    'begin'#10 +
    '  LI := GD.FP.X;'#10 +
    '  LI := GD.Half;'#10 +
    '  LS := GA.FS;'#10 +
    '  LI := GW.FValue;'#10 +
    '  LI := GW.Get;'#10 +
    '  LI := GW.Value;'#10 +
    '  LS := GN.FValue.FValue;'#10 +
    '  LS := GP.FKey;'#10 +
    '  GD := TDerived.Create;'#10 +
    '  GW := TWrap<Integer>.Create;'#10 +
    'end;'#10 +
    'end.'#10;

  // A helper declared ALONGSIDE the type it extends (15.3.4): its members
  // must be reachable from a DIFFERENT unit, since the join lives inside XH's
  // own model and FindMemberX walks into it. Nested inside another class on
  // purpose — dcc-verified that nesting only namespaces the helper's TYPE
  // name and never confines its activation (spec 15.3.4).
  UNIT_XH =
    'unit XH;'#10'interface'#10 +
    'type'#10 +
    '  TMat = record'#10 +
    '    m11: Integer;'#10 +
    '  end;'#10 +
    '  TOwner = class'#10 +
    '  strict private'#10 +
    '    type'#10 +
    '      TMatHelper = record helper for TMat'#10 +
    '        function Twice: Integer;'#10 +
    '      end;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TOwner.TMatHelper.Twice: Integer; begin Result := m11 * 2; end;'#10 +
    'end.'#10;

  UNIT_XI =
    'unit XI;'#10'interface'#10'uses XH;'#10 +
    'var'#10 +
    '  GM: TMat;'#10 +
    'implementation'#10 +
    'procedure UseHelper;'#10 +
    'var'#10 +
    '  LI: Integer;'#10 +
    'begin'#10 +
    '  LI := GM.m11;'#10 +
    '  LI := GM.Twice;'#10 +
    'end;'#10 +
    'end.'#10;

  // A property specifier naming an accessor INHERITED from another unit:
  // `read GetWordProp` where GetWordProp is TBase's, in XP. The ancestor walk
  // only ever ran for nodes inside a METHOD BODY, so a specifier — which sits
  // in the type declaration — got a straight E2003 (System.Win.
  // InternetExplorer over OleControls' TOleControl, 47 of the RTL's).
  // The bare-inherited-member uses in Work are the control: they already
  // worked, and deferring the WHOLE declaration to the inherited pass (rather
  // than just specifiers) breaks them, because the ancestor reference
  // `class(TBase)` would then be resolved in the same round as the lookups
  // that read it. TNested exists to cover exactly that shape.
  UNIT_XP =
    'unit XP;'#10'interface'#10 +
    'type'#10 +
    '  TBase = class'#10 +
    '  protected'#10 +
    '    FCount: Integer;'#10 +
    '    function GetWordProp(Index: Integer): Boolean;'#10 +
    '    procedure SetWordProp(Index: Integer; Value: Boolean);'#10 +
    '  public'#10 +
    '    procedure Bump;'#10 +
    '    property Count: Integer read FCount;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TBase.GetWordProp(Index: Integer): Boolean; begin Result := False; end;'#10 +
    'procedure TBase.SetWordProp(Index: Integer; Value: Boolean); begin end;'#10 +
    'procedure TBase.Bump; begin Inc(FCount); end;'#10 +
    'end.'#10;

  UNIT_XQ =
    'unit XQ;'#10'interface'#10'uses XP;'#10 +
    'type'#10 +
    '  TDerived = class(TBase)'#10 +
    '  public'#10 +
    '    property Flag: Boolean index 204 read GetWordProp write SetWordProp;'#10 +
    '    procedure Work;'#10 +
    '  end;'#10 +
    '  TOuter = class'#10 +
    '  public type'#10 +
    '    TNested = class(TBase)'#10 +
    '      procedure Deep;'#10 +
    '    end;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure TDerived.Work;'#10 +
    'begin'#10 +
    '  Bump;'#10 +
    '  FCount := FCount + 1;'#10 +
    '  if Count > 0 then Exit;'#10 +
    'end;'#10 +
    'procedure TOuter.TNested.Deep;'#10 +
    'begin'#10 +
    '  Bump;'#10 +               // nested class, ancestor method across units
    '  FCount := 0;'#10 +
    'end;'#10 +
    'end.'#10;

  // with-targets whose TYPE lives in another unit — the shapes Phase 1 cannot
  // resolve on its own, so only the cross-unit pass can. Mirrors
  // System.ObjAuto (`with TVarData(X) do`) and System.Variants (`with P^ do`,
  // `with FindVarData(V)^ do`), where TVarData/PVarData come from System.
  UNIT_XW =
    'unit XW;'#10'interface'#10 +
    'type'#10 +
    '  TVarLike = record'#10 +
    '    VType: Word;'#10 +
    '  end;'#10 +
    '  PVarLike = ^TVarLike;'#10 +
    '  PAlias = PVarLike;'#10 +
    'function FindVar: PVarLike;'#10 +
    'implementation'#10 +
    'function FindVar: PVarLike; begin Result := nil; end;'#10 +
    'end.'#10;

  UNIT_XY =
    'unit XY;'#10'interface'#10'uses XW;'#10 +
    'implementation'#10 +
    'procedure UseWith;'#10 +
    'var'#10 +
    '  Buf: array[0..3] of Integer;'#10 +
    '  LP: PVarLike;'#10 +
    '  LA: PAlias;'#10 +
    'begin'#10 +
    '  with TVarLike(Buf) do'#10 +
    '    VType := 1;'#10 +
    '  with LP^ do'#10 +
    '    VType := 2;'#10 +
    '  with LA^ do'#10 +
    '    VType := 3;'#10 +
    '  with FindVar^ do'#10 +
    '    VType := 4;'#10 +
    '  with XW.TVarLike(Buf) do'#10 +   // qualified cast
    '    VType := 5;'#10 +
    'end;'#10 +
    'end.'#10;

  // ---- cross-unit helper injection (15.3, README's former To do) ----
  // HA: the extended types. HB: helpers in ANOTHER unit — the common
  // real-world arrangement (TGUIDHelper in SysUtils for System's TGUID).
  // Lo's body reads D1 BARE (direction 2: helper body sees T through the
  // implicit Self — the RTL's own `Move(D1, ...)` false E2003). Mark exists
  // on BOTH the type and the helper with different types: dcc-verified, the
  // HELPER member hides the type's own. TStrHelper extends the intrinsic
  // string — the by-name ('~') canonical-key path. HB2 declares a competing
  // Version; HC lists HB LAST, so HB's must win (dcc-verified
  // last-uses-wins). HD's helper lives in the IMPLEMENTATION section and
  // must stay invisible to HE (dcc-verified, 15.3.4).
  UNIT_HA =
    'unit HA;'#10'interface'#10 +
    'type'#10 +
    '  TGuidLike = record'#10 +
    '    D1: Cardinal;'#10 +
    '  end;'#10 +
    '  TTag = class'#10 +
    '    function Mark: string;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TTag.Mark: string; begin Result := ''own''; end;'#10 +
    'end.'#10;

  UNIT_HB =
    'unit HB;'#10'interface'#10'uses HA;'#10 +
    'type'#10 +
    '  TGuidHelper = record helper for TGuidLike'#10 +
    '    function Lo: Cardinal;'#10 +
    '  end;'#10 +
    '  TTagHelperA = class helper for TTag'#10 +
    '    function Version: string;'#10 +
    '    function Mark: Integer;'#10 +
    '  end;'#10 +
    '  TStrHelper = record helper for string'#10 +
    '    function Doubled: Integer;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TGuidHelper.Lo: Cardinal;'#10 +
    'begin'#10 +
    '  Result := D1;'#10 +               // direction 2, the D1 shape
    'end;'#10 +
    'function TTagHelperA.Version: string; begin Result := ''A''; end;'#10 +
    'function TTagHelperA.Mark: Integer; begin Result := 1; end;'#10 +
    'function TStrHelper.Doubled: Integer; begin Result := 2; end;'#10 +
    'end.'#10;

  UNIT_HB2 =
    'unit HB2;'#10'interface'#10'uses HA;'#10 +
    'type'#10 +
    '  TTagHelperB = class helper for TTag'#10 +
    '    function Version: Integer;'#10 +   // competing; loses to HB in HC
    '  end;'#10 +
    'implementation'#10 +
    'function TTagHelperB.Version: Integer; begin Result := 2; end;'#10 +
    'end.'#10;

  UNIT_HC =
    'unit HC;'#10'interface'#10'uses HA, HB2, HB;'#10 +   // HB LAST -> wins
    'var'#10 +
    '  GT: TTag;'#10 +
    '  GG: TGuidLike;'#10 +
    '  GS: string;'#10 +
    'implementation'#10 +
    'procedure UseIt;'#10 +
    'var'#10 +
    '  S: string;'#10 +
    '  I: Integer;'#10 +
    '  C: Cardinal;'#10 +
    'begin'#10 +
    '  S := GT.Version;'#10 +   // HB''s (string), not HB2''s (Integer)
    '  I := GT.Mark;'#10 +      // helper hides the type''s own Mark: string
    '  C := GG.Lo;'#10 +        // direction 1, qualified
    '  I := GS.Doubled;'#10 +   // intrinsic-type helper (builtin key)
    'end;'#10 +
    'end.'#10;

  UNIT_HD =
    'unit HD;'#10'interface'#10'uses HA;'#10 +
    'procedure Poke;'#10 +
    'implementation'#10 +
    'type'#10 +
    '  TTagLocal = class helper for TTag'#10 +
    '    function Hidden: Integer;'#10 +
    '  end;'#10 +
    'function TTagLocal.Hidden: Integer; begin Result := 9; end;'#10 +
    'procedure Poke;'#10 +
    'var'#10 +
    '  T: TTag;'#10 +
    '  I: Integer;'#10 +
    'begin'#10 +
    '  I := T.Hidden;'#10 +     // legal HERE (own unit)
    'end;'#10 +
    'end.'#10;

  UNIT_HE =
    'unit HE;'#10'interface'#10'uses HA, HD;'#10 +
    'implementation'#10 +
    'procedure TryIt;'#10 +
    'var'#10 +
    '  T: TTag;'#10 +
    '  I: Integer;'#10 +
    'begin'#10 +
    '  I := T.Hidden;'#10 +     // must NOT resolve: HD''s helper is impl-local
    'end;'#10 +
    'end.'#10;

  // `with` over a call whose result is a generic INSTANTIATION from another
  // unit — System.Threading's `with FThreads.LockList do Count`, the largest
  // single with-bucket shape. Two things must both work: the method's result
  // type must exist at all (see SemaSmoke's genresult case for the parsing
  // bug that ate it), and the member's declared type must be substituted in
  // the base's instantiation frame (TWrap<T>.Get -> Integer, not T).
  UNIT_XZ =
    'unit XZ;'#10'interface'#10'uses XG;'#10 +
    'type'#10 +
    '  TPool<T> = class'#10 +
    '    FList: TWrap<T>;'#10 +
    '    function Lock: TWrap<T>;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TPool<T>.Lock: TWrap<T>; begin Result := FList; end;'#10 +
    'end.'#10;

  UNIT_XR =
    'unit XR;'#10'interface'#10'uses XG, XZ;'#10 +
    'var'#10 +
    '  GPool: TPool<Integer>;'#10 +
    'implementation'#10 +
    'procedure UseIt;'#10 +
    'var'#10 +
    '  I: Integer;'#10 +
    'begin'#10 +
    '  with GPool.Lock do'#10 +
    '    I := FValue;'#10 +
    'end;'#10 +
    'end.'#10;

  // 16.5.1 — a generic METHOD's type parameters inferred from the ARGUMENT
  // types, with no explicit <>. Declared in another unit so the inference runs
  // cross-model. Max exercises two calls of the same method inferring
  // DIFFERENT T; Wrap exercises a result that is an instantiation OF the
  // inferred parameter (TBox<T> -> TBox<Integer>), which only works if the
  // frame is applied through SubstX rather than by swapping one symbol.
  // Pair<K,V> checks a two-parameter method, and Untyped checks that a
  // parameter which cannot be inferred leaves the call as it was rather than
  // producing a half-substituted type.
  UNIT_GM =
    'unit GM;'#10'interface'#10 +
    'type'#10 +
    '  TBox<T> = class'#10 +
    '    FV: T;'#10 +
    '  end;'#10 +
    '  TGen = class'#10 +
    '    function Max<T>(const A, B: T): T;'#10 +
    '    function Wrap<T>(const A: T): TBox<T>;'#10 +
    '    function Pair<K, V>(const AK: K; const AV: V): V;'#10 +
    '    function Untyped<T>: T;'#10 +          // nothing to infer from
    '    procedure Take<T>(const A: T);'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TGen.Max<T>(const A, B: T): T; begin Result := A; end;'#10 +
    'function TGen.Wrap<T>(const A: T): TBox<T>; begin Result := nil; end;'#10 +
    'function TGen.Pair<K, V>(const AK: K; const AV: V): V;'#10 +
    'begin Result := AV; end;'#10 +
    'function TGen.Untyped<T>: T; begin end;'#10 +
    'procedure TGen.Take<T>(const A: T); begin end;'#10 +
    'end.'#10;

  UNIT_GU =
    'unit GU;'#10'interface'#10'uses GM;'#10 +
    'var'#10 +
    '  G: TGen;'#10 +
    'implementation'#10 +
    'procedure UseGen;'#10 +
    'var'#10 +
    '  I: Integer;'#10 +
    '  S: string;'#10 +
    'begin'#10 +
    '  I := G.Max(3, 7);'#10 +
    '  S := G.Max(''a'', ''b'');'#10 +
    '  I := G.Wrap(5).FV;'#10 +
    '  S := G.Pair(1, ''x'');'#10 +
    '  G.Take(9);'#10 +
    'end;'#10 +
    'end.'#10;

  // 16.5.1's other half: the type arguments WRITTEN at the call site. Nothing
  // here can be inferred from the arguments — `Cast<T>(AObject: TObject): T`
  // declares every parameter concretely — so the written list is the only
  // source, and a call typed without it loses every member after the dot
  // (a suite's `Unsafe.Cast<TFoo>(X).Bar`, ~30 reports on one project).
  //
  // `Fetch` is the OTHER half of the same shape: a non-generic member of the
  // same name on the DERIVED class must not swallow a call written with type
  // arguments (System.JSON: `TJSONObject.GetValue(Name)` beside
  // `TJSONValue.GetValue<T>(APath)`).
  UNIT_GX =
    'unit GX;'#10'interface'#10 +
    'type'#10 +
    '  TThing = class'#10 +
    '    function Ping: Integer;'#10 +
    '  end;'#10 +
    '  TCastBase = class'#10 +
    '    function Fetch<T>(const AName: string): T; overload;'#10 +
    '  end;'#10 +
    '  TCastBag = class(TCastBase)'#10 +
    '    function Fetch(const AName: string): TObject; overload;'#10 +
    '  end;'#10 +
    '  Unsafe = class'#10 +
    '    class function Cast<T: class>(AObject: TObject): T; static;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TThing.Ping: Integer; begin Result := 1; end;'#10 +
    'function TCastBase.Fetch<T>(const AName: string): T; begin end;'#10 +
    'function TCastBag.Fetch(const AName: string): TObject;'#10 +
    'begin Result := nil; end;'#10 +
    'class function Unsafe.Cast<T>(AObject: TObject): T; begin Result := nil;'#10 +
    'end;'#10 +
    'end.'#10;

  UNIT_GY =
    'unit GY;'#10'interface'#10'uses GX;'#10 +
    'var'#10 +
    '  GBag: TCastBag;'#10 +
    '  GObj: TObject;'#10 +
    'implementation'#10 +
    'procedure UseCast;'#10 +
    'var'#10 +
    '  I: Integer;'#10 +
    'begin'#10 +
    '  I := Unsafe.Cast<TThing>(GObj).Ping;'#10 +
    '  I := GBag.Fetch<TThing>(''x'').Ping;'#10 +
    'end;'#10 +
    'end.'#10;

  // A helper whose target NAME is an alias of the type: `UA.TSpot` is another
  // symbol for `UB.TSpot`, and which one a value carries depends on the unit
  // its declaration was read in. The helper must answer for both (SynEdit's
  // TRectHelper, written against Winapi.Windows' TRect, applied to a local
  // declared through System.Types').
  UNIT_AL1 =
    'unit AL1;'#10'interface'#10 +
    'type'#10 +
    '  TSpot = record'#10 +
    '    X: Integer;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'end.'#10;

  UNIT_AL2 =
    'unit AL2;'#10'interface'#10'uses AL1;'#10 +
    'type'#10 +
    '  TSpot = AL1.TSpot;'#10 +          // a plain alias: the SAME type
    'implementation'#10 +
    'end.'#10;

  UNIT_AL3 =
    'unit AL3;'#10'interface'#10'uses AL1, AL2;'#10 +
    'type'#10 +
    '  TSpotHelper = record helper for TSpot'#10 +   // binds AL2's alias
    '    function Doubled: Integer;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TSpotHelper.Doubled: Integer; begin Result := X * 2; end;'#10 +
    'end.'#10;

  UNIT_AL4 =
    'unit AL4;'#10'interface'#10'uses AL1, AL3;'#10 +   // AL1's TSpot, not AL2's
    'var'#10 +
    '  GSpot: TSpot;'#10 +
    'implementation'#10 +
    'procedure UseSpot;'#10 +
    'var'#10 +
    '  I: Integer;'#10 +
    'begin'#10 +
    '  I := GSpot.Doubled;'#10 +
    'end;'#10 +
    'end.'#10;

  // 12.1.2: `inherited Name` is the ANCESTOR's member even when the class
  // REDECLARES that name — and two suite editor units redeclare it at a different
  // TYPE, so the whole chain after it depends on getting this right.
  UNIT_IN1 =
    'unit IN1;'#10'interface'#10 +
    'type'#10 +
    '  TAlign = class'#10 +
    '    FHorz: Integer;'#10 +
    '  end;'#10 +
    '  TBaseProps = class'#10 +
    '    function GetAlignment: TAlign;'#10 +
    '    property Alignment: TAlign read GetAlignment;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TBaseProps.GetAlignment: TAlign; begin Result := nil; end;'#10 +
    'end.'#10;

  UNIT_IN2 =
    'unit IN2;'#10'interface'#10'uses IN1;'#10 +
    'type'#10 +
    '  TMemoProps = class(TBaseProps)'#10 +
    '    function GetOwn: string;'#10 +
    '    function Probe: Integer;'#10 +
    '    property Alignment: string read GetOwn;'#10 +   // shadows, other type
    '  end;'#10 +
    'implementation'#10 +
    'function TMemoProps.GetOwn: string; begin Result := ''''; end;'#10 +
    'function TMemoProps.Probe: Integer;'#10 +
    'begin'#10 +
    '  Result := inherited Alignment.FHorz;'#10 +
    'end;'#10 +
    'end.'#10;

  // Five shapes that took a real project's member-flag tail to zero, in one
  // unit because each is a couple of declarations:
  //
  //   1. `with Values[I] do` over a class with a DEFAULT array property —
  //      the brackets mean that property, so the body opens the ELEMENT. The
  //      collection ALSO has a `Values` member, so opening it instead was a
  //      wrong binding, not a missing one (a suite's filter control).
  //   2. `T.Create` under a bare `constructor` constraint — only a class can
  //      satisfy it (a threading library's `Atomic<I; T: constructor>`).
  //   3. a parameter with SEVERAL constraints guarantees the members of all
  //      of them, not the first (a utility library's `TKey: IComparable<TKey>,
  //      IEquatable<TKey>, IHashable`).
  //   4. a bare name used as a QUALIFIER means the PARAMETERLESS overload
  //      (an RPC library's `Add.Assign(...)`).
  //   5. a function reference whose every parameter has a DEFAULT is still
  //      called by writing its name (VirtualTrees' TVTStyleServicesFunc).
  UNIT_TL1 =
    'unit TL1;'#10'interface'#10 +
    'type'#10 +
    '  IHashy = interface'#10 +
    '    function Hash: Integer;'#10 +
    '  end;'#10 +
    '  ICompy = interface'#10 +
    '    function Cmp: Integer;'#10 +
    '  end;'#10 +
    '  TItem = class'#10 +
    '    Tag: Integer;'#10 +
    '  end;'#10 +
    '  TItems = class'#10 +
    '  private'#10 +
    '    FSep: string;'#10 +
    '    function GetItem(Index: Integer): TItem;'#10 +
    '  public'#10 +
    '    property Separator: string read FSep;'#10 +
    '    property Values[Index: Integer]: TItem read GetItem; default;'#10 +
    '  end;'#10 +
    '  TRow = class'#10 +
    '  private'#10 +
    '    FValues: TItems;'#10 +
    '  public'#10 +
    '    property Values: TItems read FValues;'#10 +
    '  end;'#10 +
    '  TMaker<T: constructor> = class'#10 +
    '    class function Make: TObject;'#10 +
    '  end;'#10 +
    '  TKeyed<K: ICompy, IHashy> = class'#10 +
    '    function HashOf(const AKey: K): Integer;'#10 +
    '  end;'#10 +
    '  TAdder = class'#10 +
    '    function Add(AItem: TItem): Integer; overload;'#10 +
    '    function Add: TItem; overload;'#10 +
    '    procedure Poke;'#10 +
    '  end;'#10 +
    '  TStyler = class'#10 +
    '    function Color: Integer;'#10 +
    '  end;'#10 +
    '  TStylerFunc = function(AOwner: TObject = nil): TStyler;'#10 +
    'var'#10 +
    '  GStylerFunc: TStylerFunc;'#10 +
    'procedure DrawRow(ARow: TRow);'#10 +
    'implementation'#10 +
    'function TItems.GetItem(Index: Integer): TItem; begin Result := nil; end;'#10 +
    'class function TMaker<T>.Make: TObject; begin Result := T.Create; end;'#10 +
    'function TKeyed<K>.HashOf(const AKey: K): Integer;'#10 +
    'begin'#10 +
    '  Result := AKey.Hash;'#10 +          // the SECOND constraint
    'end;'#10 +
    'function TAdder.Add(AItem: TItem): Integer; begin Result := 0; end;'#10 +
    'function TAdder.Add: TItem; begin Result := nil; end;'#10 +
    'procedure TAdder.Poke;'#10 +
    'begin'#10 +
    '  Add.Tag := 1;'#10 +                 // the PARAMETERLESS overload
    'end;'#10 +
    'function TStyler.Color: Integer; begin Result := 0; end;'#10 +
    'procedure DrawRow(ARow: TRow);'#10 +
    'var'#10 +
    '  I, N: Integer;'#10 +
    '  S: string;'#10 +
    'begin'#10 +
    '  with ARow do'#10 +
    '    with Values[0] do'#10 +
    '    begin'#10 +
    '      I := Tag;'#10 +                 // the ELEMENT is open...
    '      S := Values.Separator;'#10 +    // ...and the outer Values still is
    '    end;'#10 +
    '  N := GStylerFunc.Color;'#10 +       // all-defaulted function reference
    'end;'#10 +
    'end.'#10;

  // Two things one third-party library needs and nothing else in the corpora does.
  //
  // 1. `class helper (X) for T` — the derived helper is the ACTIVE one (at most
  //    one is, per type), so its ANCESTOR's members are only reachable through
  //    it. Spring.Reflection declares `TRttiMethodHelper = class helper(Spring
  //    .TRttiMethodHelper) for TRttiMethod`, and a unit using BOTH units lost
  //    `ReturnTypeHandle`/`IsAbstract` — a unit using only Spring kept them.
  // 2. 16.1.2 by COUNT, not just generic-vs-not: `TNodes<T>` and
  //    `TNodes<TKey, TValue>` both declare a nested `PRedBlackTreeNode`, so
  //    binding the qualifier to the wrong arity silently resolved the wrong
  //    nested type — the node records differ only in `fKey` vs `fPair`
  //    (Spring.Collections.Trees, 16 reports).
  UNIT_SP_A =
    'unit SPA;'#10'interface'#10 +
    'type'#10 +
    '  TThing = class'#10 +
    '    Own: Integer;'#10 +
    '  end;'#10 +
    '  TThingHelperBase = class helper for TThing'#10 +
    '    function FromBase: Integer;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TThingHelperBase.FromBase: Integer; begin Result := Own; end;'#10 +
    'end.'#10;

  UNIT_SP_B =
    'unit SPB;'#10'interface'#10'uses SPA;'#10 +
    'type'#10 +
    '  TThingHelperMore = class helper(SPA.TThingHelperBase) for TThing'#10 +
    '    function FromDerived: Integer;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TThingHelperMore.FromDerived: Integer; begin Result := 1; end;'#10 +
    'end.'#10;

  UNIT_SP_C =
    'unit SPC;'#10'interface'#10'uses SPA, SPB;'#10 +   // BOTH: SPB's is active
    'procedure Poke(AThing: TThing);'#10 +
    'implementation'#10 +
    'procedure Poke(AThing: TThing);'#10 +
    'var'#10 +
    '  I: Integer;'#10 +
    'begin'#10 +
    '  I := AThing.FromDerived;'#10 +   // the active helper''s own
    '  I := AThing.FromBase;'#10 +      // ...and its helper ANCESTOR''s
    '  I := AThing.Own;'#10 +           // ...and the type''s own, still
    'end;'#10 +
    'end.'#10;

  UNIT_SP_N =
    'unit SPN;'#10'interface'#10 +
    'type'#10 +
    '  TNodes<T> = record'#10 +
    '  strict private type'#10 +
    '    PNode = ^TNode;'#10 +
    '    TNode = record'#10 +
    '    private'#10 +
    '      fKey: T;'#10 +
    '    end;'#10 +
    '  public type'#10 +
    '    PPublicNode = PNode;'#10 +
    '  end;'#10 +
    '  TNodes<TKey, TValue> = record'#10 +
    '  strict private type'#10 +
    '    PNode = ^TNode;'#10 +
    '    TNode = record'#10 +
    '    private'#10 +
    '      fKeyed: TKey;'#10 +          // the arity-2 side''s DIFFERENT field
    '    end;'#10 +
    '  public type'#10 +
    '    PPublicNode = PNode;'#10 +
    '  end;'#10 +
    '  TTree<T> = class'#10 +
    '  private type'#10 +
    '    PNode = TNodes<T>.PPublicNode;'#10 +
    '  protected'#10 +
    '    function Make1(const key: T): PNode;'#10 +
    '  end;'#10 +
    '  TTree<TKey, TValue> = class'#10 +
    '  private type'#10 +
    '    PNode = TNodes<TKey, TValue>.PPublicNode;'#10 +
    '  protected'#10 +
    '    function Make2(const key: TKey): PNode;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TTree<T>.Make1(const key: T): PNode;'#10 +
    'begin'#10 +
    '  Result := nil;'#10 +
    '  Result.fKey := key;'#10 +
    'end;'#10 +
    'function TTree<TKey, TValue>.Make2(const key: TKey): PNode;'#10 +
    'begin'#10 +
    '  Result := nil;'#10 +
    '  Result.fKeyed := key;'#10 +
    'end;'#10 +
    'end.'#10;

  // Overload selection between RECORD parameters of one arity, where the two
  // sides name the same type through DIFFERENT symbols. `AL2.TSpot` is an
  // alias of `AL1.TSpot`, so a symbol comparison matches neither candidate,
  // both score 0, and declaration order decides — which is how
  // `LayoutUnitsToPixels(TRect, Single, Single)` lost to the TSize overload
  // declared above it (dxDocumentLayoutUnitConverter), typed the call as
  // TSize, and left `.ToRectF` undeclared two units away.
  UNIT_OV =
    'unit OV;'#10'interface'#10'uses AL1, AL2;'#10 +
    'type'#10 +
    '  TOther = record'#10 +
    '    Y: Integer;'#10 +
    '  end;'#10 +
    // TWO different symbols for the one type: the parameter is declared
    // through AL2's alias, the argument through AL1's own declaration.
    '  TSpotAlias = AL2.TSpot;'#10 +
    '  TSpotDirect = AL1.TSpot;'#10 +
    '  IBase = interface'#10 +
    '    function Take(const A: TSpotDirect): Integer;'#10 +
    '  end;'#10 +
    // Declares ONLY the array overload and INHERITS the single-item one, so
    // the derived interface's own has to be rejected on argument types for the
    // ancestor's to be looked for at all.
    '  IMore = interface(IBase)'#10 +
    '    function Take(const A: TArray<TSpotDirect>): string;'#10 +
    '  end;'#10 +
    '  TConv = class'#10 +
    '    function Conv(const A: TOther; const B, C: Integer): TOther; overload;'#10 +
    '    function Conv(const A: TSpotAlias; const B, C: Integer): TSpotAlias;'#10 +
    '      overload;'#10 +
    '  end;'#10 +
    'procedure Run(AConv: TConv; const AMore: IMore; const S: TSpotDirect);'#10 +
    'implementation'#10 +
    'function TConv.Conv(const A: TOther; const B, C: Integer): TOther;'#10 +
    'begin Result := A; end;'#10 +
    'function TConv.Conv(const A: TSpotAlias; const B, C: Integer): TSpotAlias;'#10 +
    'begin Result := A; end;'#10 +
    'procedure Run(AConv: TConv; const AMore: IMore; const S: TSpotDirect);'#10 +
    'var'#10 +
    '  I: Integer;'#10 +
    'begin'#10 +
    '  I := AConv.Conv(S, 1, 1).X;'#10 +   // X is on TSpot, not on TOther
    '  I := AMore.Take(S);'#10 +           // the ANCESTOR''s overload
    'end;'#10 +
    'end.'#10;

  // 15.3.3 the SAME-UNIT way: a helper declared beside (here: below) its
  // extended type still HIDES that type's own member of the same name. The
  // cross-unit direction was always right; this one bound own-first, and
  // A suite's rich-edit units lean on it — `TTagBaseInnerHelper = class helper for
  // TdxTagBase` redeclares `Importer` at the DERIVED importer type, so every
  // `Importer.TagsStack` in that unit reads the helper's (60+ reports).
  UNIT_SH =
    'unit SH;'#10'interface'#10 +
    'type'#10 +
    '  TBaseImp = class'#10 +
    '    Common: Integer;'#10 +
    '  end;'#10 +
    '  TRealImp = class(TBaseImp)'#10 +
    '    Stack: Integer;'#10 +           // only on the DERIVED one
    '  end;'#10 +
    '  TTag = class'#10 +
    '  private'#10 +
    '    FImp: TBaseImp;'#10 +
    '  public'#10 +
    '    property Imp: TBaseImp read FImp;'#10 +
    '    function Probe: Integer;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'type'#10 +
    '  TTagInner = class helper for TTag'#10 +
    '  private'#10 +
    '    function GetImp: TRealImp;'#10 +
    '  public'#10 +
    '    property Imp: TRealImp read GetImp;'#10 +   // hides TTag.Imp
    '  end;'#10 +
    'function TTagInner.GetImp: TRealImp;'#10 +
    'begin'#10 +
    '  Result := TRealImp(inherited Imp);'#10 +
    'end;'#10 +
    'function TTag.Probe: Integer;'#10 +
    'begin'#10 +
    '  Result := Imp.Stack;'#10 +        // the HELPER's Imp, or Stack is lost
    'end;'#10 +
    'end.'#10;

  // A member reached through a GENERIC ancestor whose bare name is ALSO the
  // last segment of a dotted `uses`. Both halves are needed: the unit name
  // makes the ident arrive at the inherited pass already BOUND (to the unit),
  // and that override path used to drop the instantiation frame — so `Params`
  // typed as the open TParams, fell back to its CONSTRAINT, and only the
  // CONSTRAINT's members resolved. A real project's UI tests are this shape ~700
  // times over, and `uses UITest.Params` is what made it visible.
  UNIT_NS_P =
    'unit NS.Params;'#10'interface'#10 +
    'type'#10 +
    '  TParamsBase = class'#10 +
    '    Shared: Integer;'#10 +          // reachable via the CONSTRAINT too
    '  end;'#10 +
    '  TMyParams = class(TParamsBase)'#10 +
    '    Mine: Integer;'#10 +            // ONLY via the instantiation frame
    '  end;'#10 +
    'implementation'#10 +
    'end.'#10;

  UNIT_NS_R =
    'unit NS.Runner;'#10'interface'#10'uses NS.Params;'#10 +
    'type'#10 +
    '  TRunner = class'#10 +
    '    function Params: TParamsBase;'#10 +
    '  end;'#10 +
    '  TRunner<TP: TParamsBase> = class(TRunner)'#10 +
    '    function Params: TP;'#10 +
    '    procedure Execute; virtual; abstract;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TRunner.Params: TParamsBase; begin Result := nil; end;'#10 +
    'function TRunner<TP>.Params: TP; begin Result := nil; end;'#10 +
    'end.'#10;

  UNIT_NS_T =
    'unit NS.Test;'#10'interface'#10'uses NS.Runner, NS.Params;'#10 +
    'type'#10 +
    '  TMyTest = class(TRunner<TMyParams>)'#10 +
    '    procedure Execute; override;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure TMyTest.Execute;'#10 +
    'var'#10 +
    '  I: Integer;'#10 +
    'begin'#10 +
    '  I := Params.Mine;'#10 +
    'end;'#10 +
    'end.'#10;

  // Cross-unit overload selection by ARGUMENT TYPES: three global overloads
  // (mirrors System.Math.Min's shape) + method overloads + a generic method
  // whose parameter needs instantiation-frame substitution before scoring.
  UNIT_XO =
    'unit XO;'#10'interface'#10 +
    'function Pick(A: Integer): Integer; overload;'#10 +
    'function Pick(A: Double): Double; overload;'#10 +
    'function Pick(A: string): string; overload;'#10 +
    'type'#10 +
    '  TBox = class'#10 +
    '    function Add(A: Integer): Integer; overload;'#10 +
    '    function Add(A: string): string; overload;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function Pick(A: Integer): Integer; begin Result := A; end;'#10 +
    'function Pick(A: Double): Double; begin Result := A; end;'#10 +
    'function Pick(A: string): string; begin Result := A; end;'#10 +
    'function TBox.Add(A: Integer): Integer; begin Result := A; end;'#10 +
    'function TBox.Add(A: string): string; begin Result := A; end;'#10 +
    'end.'#10;

  UNIT_XV =
    'unit XV;'#10'interface'#10'uses XO, XG;'#10 +
    'var'#10 +
    '  GB: TBox;'#10 +
    '  GWD: TWrap<Double>;'#10 +
    // A LOCAL same-named overload: merged with XO''s set, exact match wins.
    'function Pick(A: Boolean): Boolean; overload;'#10 +
    'implementation'#10 +
    'function Pick(A: Boolean): Boolean; begin Result := A; end;'#10 +
    'procedure UseIt;'#10 +
    'var'#10 +
    '  LI: Integer;'#10 +
    '  LD: Double;'#10 +
    '  LS: string;'#10 +
    '  LB: Boolean;'#10 +
    'begin'#10 +
    '  LI := Pick(11);'#10 +
    '  LD := Pick(2.5);'#10 +
    '  LS := Pick(''s'');'#10 +
    '  LB := Pick(True);'#10 +
    '  LI := GB.Add(7);'#10 +
    '  LS := GB.Add(''x'');'#10 +
    '  LD := GWD.Get;'#10 +
    'end;'#10 +
    'end.'#10;

function ModelByName(const ANameLower: string): TPasSemaModel;
begin
  Result := nil;
  for var LId := 0 to GProj.ModelCount - 1 do
    if GProj.Model(LId).UnitNameLower = ANameLower then
      Exit(GProj.Model(LId));
end;

// The node's source text: its visible tokens joined without whitespace
// ('GD.FP.X') — enough to address an expression in the fixtures uniquely.
// An nkMember's own FirstToken is the '.', so the span starts at the
// LEFTMOST DESCENDANT's first token (the base expression), not the node's.
function SpanText(AModel: TPasSemaModel; ANode: Integer): string;
var
  LLeft, LFirst, LLast, LTok: Integer;
begin
  LLeft := ANode;
  LFirst := AModel.Tree.Nodes[ANode].FirstToken;
  while AModel.Tree.Nodes[LLeft].FirstChild <> NIL_NODE do
  begin
    LLeft := AModel.Tree.Nodes[LLeft].FirstChild;
    if (AModel.Tree.Nodes[LLeft].FirstToken >= 0) and
       (AModel.Tree.Nodes[LLeft].FirstToken < LFirst) then
      LFirst := AModel.Tree.Nodes[LLeft].FirstToken;
  end;
  LLast := AModel.Tree.Nodes[ANode].LastToken;
  Result := '';
  for LTok := LFirst to LLast do
    if (LTok >= 0) and (LTok <= High(AModel.Tree.Source.Visible)) then
      Result := Result + AModel.Tree.Source.VisibleText(LTok);
end;

// XTypeText of the expression spelled AExpr (first node with a cross type;
// falls back to the intra-unit type name; '?' when untyped).
function XTypeOf(AModel: TPasSemaModel; const AExpr: string): string;
var
  LX: TSemaXType;
begin
  Result := '?';
  for var LNode := 0 to High(AModel.RefMap) do
    if (AModel.Tree.Nodes[LNode].Kind in [nkIdent, nkMember, nkCall,
        nkTypeArgs]) and (SpanText(AModel, LNode) = AExpr) then
    begin
      if AModel.ExprTypeX.TryGetValue(LNode, LX) then
        Exit(GProj.XTypeText(LX));
      if AModel.ExprType[LNode] <> NIL_SYM then
        Exit(AModel.Symbols[AModel.ExprType[LNode]].Name);
    end;
end;

// The unit name of the overload CrossType selected for the call spelled
// AExpr ('?' when no CallTargetX was recorded) — the future overload-precise
// navigation jump reads the same map.
function CallTargetUnitOf(AModel: TPasSemaModel; const AExpr: string): string;
var
  LExt: TPasExtRef;
begin
  Result := '?';
  for var LNode := 0 to High(AModel.RefMap) do
    if (AModel.Tree.Nodes[LNode].Kind = nkCall) and
       (SpanText(AModel, LNode) = AExpr) and
       AModel.CallTargetX.TryGetValue(LNode, LExt) then
      Exit(GProj.Model(LExt.UnitId).UnitNameLower);
end;

procedure Ok(const AName: string; ACond: Boolean);
begin
  if ACond then
    Inc(GPassed)
  else
  begin
    Inc(GFailed);
    Writeln('FAIL: ', AName);
  end;
end;

procedure Eq(const AName, AGot, AWant: string);
begin
  if AGot = AWant then
    Inc(GPassed)
  else
  begin
    Inc(GFailed);
    Writeln('FAIL: ', AName, ' — got "', AGot, '", want "', AWant, '"');
  end;
end;

var
  LDir: string;
  LU, LV, LH, LW, LQ, LR, LB, LC, LE, LG: TPasSemaModel;
begin
  GPassed := 0; GFailed := 0;
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_xtype');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'XA.pas'), UNIT_XA);
  TFile.WriteAllText(TPath.Combine(LDir, 'XG.pas'), UNIT_XG);
  TFile.WriteAllText(TPath.Combine(LDir, 'XU.pas'), UNIT_XU);
  TFile.WriteAllText(TPath.Combine(LDir, 'XO.pas'), UNIT_XO);
  TFile.WriteAllText(TPath.Combine(LDir, 'XV.pas'), UNIT_XV);
  TFile.WriteAllText(TPath.Combine(LDir, 'XH.pas'), UNIT_XH);
  TFile.WriteAllText(TPath.Combine(LDir, 'XI.pas'), UNIT_XI);
  TFile.WriteAllText(TPath.Combine(LDir, 'XW.pas'), UNIT_XW);
  TFile.WriteAllText(TPath.Combine(LDir, 'XY.pas'), UNIT_XY);
  TFile.WriteAllText(TPath.Combine(LDir, 'XZ.pas'), UNIT_XZ);
  TFile.WriteAllText(TPath.Combine(LDir, 'XR.pas'), UNIT_XR);
  TFile.WriteAllText(TPath.Combine(LDir, 'HA.pas'), UNIT_HA);
  TFile.WriteAllText(TPath.Combine(LDir, 'HB.pas'), UNIT_HB);
  TFile.WriteAllText(TPath.Combine(LDir, 'HB2.pas'), UNIT_HB2);
  TFile.WriteAllText(TPath.Combine(LDir, 'HC.pas'), UNIT_HC);
  TFile.WriteAllText(TPath.Combine(LDir, 'HD.pas'), UNIT_HD);
  TFile.WriteAllText(TPath.Combine(LDir, 'HE.pas'), UNIT_HE);
  TFile.WriteAllText(TPath.Combine(LDir, 'GM.pas'), UNIT_GM);
  TFile.WriteAllText(TPath.Combine(LDir, 'GU.pas'), UNIT_GU);
  TFile.WriteAllText(TPath.Combine(LDir, 'SPA.pas'), UNIT_SP_A);
  TFile.WriteAllText(TPath.Combine(LDir, 'SPB.pas'), UNIT_SP_B);
  TFile.WriteAllText(TPath.Combine(LDir, 'SPC.pas'), UNIT_SP_C);
  TFile.WriteAllText(TPath.Combine(LDir, 'SPN.pas'), UNIT_SP_N);
  TFile.WriteAllText(TPath.Combine(LDir, 'OV.pas'), UNIT_OV);
  TFile.WriteAllText(TPath.Combine(LDir, 'SH.pas'), UNIT_SH);
  TFile.WriteAllText(TPath.Combine(LDir, 'NS.Params.pas'), UNIT_NS_P);
  TFile.WriteAllText(TPath.Combine(LDir, 'NS.Runner.pas'), UNIT_NS_R);
  TFile.WriteAllText(TPath.Combine(LDir, 'NS.Test.pas'), UNIT_NS_T);
  TFile.WriteAllText(TPath.Combine(LDir, 'TL1.pas'), UNIT_TL1);
  TFile.WriteAllText(TPath.Combine(LDir, 'GX.pas'), UNIT_GX);
  TFile.WriteAllText(TPath.Combine(LDir, 'GY.pas'), UNIT_GY);
  TFile.WriteAllText(TPath.Combine(LDir, 'AL1.pas'), UNIT_AL1);
  TFile.WriteAllText(TPath.Combine(LDir, 'AL2.pas'), UNIT_AL2);
  TFile.WriteAllText(TPath.Combine(LDir, 'AL3.pas'), UNIT_AL3);
  TFile.WriteAllText(TPath.Combine(LDir, 'AL4.pas'), UNIT_AL4);
  TFile.WriteAllText(TPath.Combine(LDir, 'IN1.pas'), UNIT_IN1);
  TFile.WriteAllText(TPath.Combine(LDir, 'IN2.pas'), UNIT_IN2);
  TFile.WriteAllText(TPath.Combine(LDir, 'XP.pas'), UNIT_XP);
  TFile.WriteAllText(TPath.Combine(LDir, 'XQ.pas'), UNIT_XQ);

  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.AnalyzeDirectory(LDir);
    LU := ModelByName('xu');
    Ok('XU loaded', Assigned(LU));
    Ok('XU: no diags at all', Length(LU.Diags) = 0);

    // Cross-unit member access, nested and through the ancestor / alias.
    Eq('GD.FP is TPair', XTypeOf(LU, 'GD.FP'), 'TPair');
    Eq('GD.FP.X is Integer', XTypeOf(LU, 'GD.FP.X'), 'Integer');
    Eq('GD.Half is Integer', XTypeOf(LU, 'GD.Half'), 'Integer');
    Eq('GA.FS is string (alias walk)', XTypeOf(LU, 'GA.FS'), 'string');

    // Generic instantiation + parameter substitution.
    Eq('GW.FValue is Integer', XTypeOf(LU, 'GW.FValue'), 'Integer');
    Eq('GW.Get is Integer', XTypeOf(LU, 'GW.Get'), 'Integer');
    Eq('GW.Value is Integer (property)', XTypeOf(LU, 'GW.Value'), 'Integer');
    Eq('GN.FValue is TWrap<string> (nested)',
      XTypeOf(LU, 'GN.FValue'), 'TWrap<string>');
    Eq('GN.FValue.FValue is string', XTypeOf(LU, 'GN.FValue.FValue'), 'string');
    Eq('GP.FKey is string (multi-param)', XTypeOf(LU, 'GP.FKey'), 'string');

    // Constructor calls yield the class type (incl. the instantiated one).
    Eq('TDerived.Create is TDerived',
      XTypeOf(LU, 'TDerived.Create'), 'TDerived');
    Eq('TWrap<Integer>.Create is TWrap<Integer>',
      XTypeOf(LU, 'TWrap<Integer>.Create'), 'TWrap<Integer>');

    // Instances are deduped WITHIN one referring model: XU's TWrap<Integer>
    // used twice -> one entry; plus TWrap<string>, TWrap<TWrap<string>>,
    // TPairWrap<string,Boolean>, XV's TWrap<Double>. The with-over-generic
    // fixtures add TPool<Integer>, an open TWrap<T> per DISTINCT parameter
    // symbol (TPool's T and TWrap's own T are different types — two
    // entries), and a second TWrap<Integer>: XR's Integer arg is ITS model's
    // builtin symbol, not XU's, so the key differs — dedup is per-model for
    // builtin args by construction (each model seeds its own builtins; see
    // PasTree.Sema.Builtins). Cross-model canonicalization of builtin args
    // would shrink this to 8; until then the count documents the behavior.
    // The table also holds GENERIC METHOD frames now (Max<Integer>,
    // Max<string>, Wrap<Integer>, Pair<Integer,string>, Take<Integer> —
    // keyed on the ROUTINE symbol, substitution frames only, never types;
    // see InferMethodFrame), plus the TBox<Integer> those produce.
    //
    // Two further known-harmless duplications, both from per-symbol identity:
    // an OPEN TBox<T> appears twice because a method's interface declaration
    // and its implementation each declare their own T symbol, so the keys
    // differ; and TWrap<Integer> appears twice for the builtin-arg reason
    // above. Neither affects typing — same text, same members — so the count
    // is documented rather than deduplicated.
    // 19 since GY: the two calls written `Cast<TThing>` / `Fetch<TThing>` add
    // one EXPLICIT method frame each (ExplicitMethodFrame keys them on the
    // routine symbol, exactly as the inferred ones are). 20 since NS.Test:
    // `TRunner<TMyParams>` is one more instantiation. 22 since SPN: the two
    // `TNodes<...>` arities are two.
    Eq('instance table (see comment)', IntToStr(GProj.InstanceCount), '22');

    // ---- Cross-unit overload selection by ARGUMENT TYPES ----
    LV := ModelByName('xv');
    Ok('XV loaded', Assigned(LV));
    Ok('XV: no diags (esp. no false E2010 from the local-overload shadow)',
      Length(LV.Diags) = 0);
    // Three same-arity imported overloads (the System.Math.Min shape): the
    // argument's type picks the overload — and thus the call's result type.
    Eq('Pick(11) -> Integer overload', XTypeOf(LV, 'Pick(11)'), 'Integer');
    Eq('Pick(2.5) -> Double overload', XTypeOf(LV, 'Pick(2.5)'), 'Double');
    Eq('Pick(''s'') -> string overload',
      XTypeOf(LV, 'Pick(''s'')'), 'string');
    // The LOCAL same-named overload joins the merged candidate set and wins
    // on an exact match — dcc's merge semantics.
    Eq('Pick(True) -> the local Boolean overload',
      XTypeOf(LV, 'Pick(True)'), 'Boolean');
    // Method overloads across units.
    Eq('GB.Add(7) -> Integer method overload',
      XTypeOf(LV, 'GB.Add(7)'), 'Integer');
    Eq('GB.Add(''x'') -> string method overload',
      XTypeOf(LV, 'GB.Add(''x'')'), 'string');
    // Generic member result substituted in the instantiation frame (control).
    Eq('GWD.Get -> Double', XTypeOf(LV, 'GWD.Get'), 'Double');
    // The chosen overload is recorded (mid, sym) for navigation.
    Eq('CallTargetX: Pick(2.5) selected XO''s overload',
      CallTargetUnitOf(LV, 'Pick(2.5)'), 'xo');
    Eq('CallTargetX: Pick(True) selected the local one',
      CallTargetUnitOf(LV, 'Pick(True)'), 'xv');

    // ---- Helper members reachable ACROSS units (15.3.4) ----
    // The helper is declared in XH beside TMat and nested inside a class,
    // strict private; XI never names TOwner. Both must type identically.
    LH := ModelByName('xi');
    Ok('XI loaded', Assigned(LH));
    Ok('XI: no diags at all', Length(LH.Diags) = 0);
    Eq('GM.m11 is Integer (plain field, control)',
      XTypeOf(LH, 'GM.m11'), 'Integer');
    Eq('GM.Twice is Integer (nested strict-private helper, cross-unit)',
      XTypeOf(LH, 'GM.Twice'), 'Integer');

    // ---- inherited members reached from another unit ----
    LQ := ModelByName('xq');
    Ok('XQ loaded', Assigned(LQ));
    Ok('XQ: no diags (inherited accessors in property specifiers, and bare '
      + 'inherited members in nested-class method bodies)',
      Length(LQ.Diags) = 0);
    // Positive: the specifier's accessor must type to its declared result,
    // so this cannot pass by merely staying quiet.
    Eq('a property specifier binds to the ANCESTOR''s accessor',
      XTypeOf(LQ, 'GetWordProp'), 'Boolean');

    // ---- with-targets whose type lives in another unit ----
    // Cast, deref of a variable, deref through an alias chain, deref of a
    // call result, and a qualified cast. Every VType write below must bind to
    // XW's field; a miss leaves the with-body unresolved and E2003s.
    LW := ModelByName('xy');
    Ok('XY loaded', Assigned(LW));
    Ok('XY: no diags at all (cast / deref with-targets)',
      Length(LW.Diags) = 0);
    // Positive, so the check cannot pass merely by staying silent: the
    // with-body's VType must actually TYPE to XW's field type.
    Eq('with-target member types through to the field',
      XTypeOf(LW, 'VType'), 'Word');

    // ---- cross-unit helper injection ----
    LB := ModelByName('hb');
    Ok('HB loaded', Assigned(LB));
    Ok('HB: no diags (helper body reads the target''s D1 bare — direction 2)',
      Length(LB.Diags) = 0);
    Eq('helper body: bare D1 types to the target''s field',
      XTypeOf(LB, 'D1'), 'Cardinal');
    LC := ModelByName('hc');
    Ok('HC loaded', Assigned(LC));
    Ok('HC: no diags at all', Length(LC.Diags) = 0);
    Eq('direction 1: qualified GG.Lo via the cross-unit helper',
      XTypeOf(LC, 'GG.Lo'), 'Cardinal');
    Eq('last-uses-wins: HB''s Version (string) beats HB2''s (Integer)',
      XTypeOf(LC, 'GT.Version'), 'string');
    Eq('a helper member HIDES the type''s own (Mark -> Integer, dcc-verified)',
      XTypeOf(LC, 'GT.Mark'), 'Integer');
    Eq('intrinsic-type helper (record helper for string, ''~'' key path)',
      XTypeOf(LC, 'GS.Doubled'), 'Integer');
    LE := ModelByName('hd');
    Ok('HD loaded', Assigned(LE));
    Ok('HD: no diags (its own impl-section helper works locally)',
      Length(LE.Diags) = 0);
    Eq('HD: T.Hidden resolves in the declaring unit',
      XTypeOf(LE, 'T.Hidden'), 'Integer');
    LE := ModelByName('he');
    Ok('HE loaded', Assigned(LE));
    Eq('HE: an implementation-section helper does NOT export (15.3.4)',
      XTypeOf(LE, 'T.Hidden'), '?');

    // ---- 16.5.1 generic-method type inference ----
    LG := ModelByName('gu');
    Ok('GU loaded', Assigned(LG));
    Ok('GU: no diags at all', Length(LG.Diags) = 0);
    Eq('Max(3,7) infers T=Integer', XTypeOf(LG, 'G.Max(3,7)'), 'Integer');
    Eq('Max(''a'',''b'') infers T=string — same method, different T',
      XTypeOf(LG, 'G.Max(''a'',''b'')'), 'string');
    Eq('Wrap(5) infers T through an INSTANTIATED result',
      XTypeOf(LG, 'G.Wrap(5)'), 'TBox<Integer>');
    Eq('...and its member types in that frame',
      XTypeOf(LG, 'G.Wrap(5).FV'), 'Integer');
    Eq('Pair(1,''x'') infers two parameters, result is V',
      XTypeOf(LG, 'G.Pair(1,''x'')'), 'string');

    // ---- 16.5.1 EXPLICIT type arguments at the call site ----
    LG := ModelByName('gy');
    Ok('GY loaded', Assigned(LG));
    Ok('GY: no diags at all', Length(LG.Diags) = 0);
    Eq('Cast<TThing>(X) types as the WRITTEN argument, not the open T',
      XTypeOf(LG, 'Unsafe.Cast<TThing>(GObj)'), 'TThing');
    Eq('...so the member after it resolves',
      XTypeOf(LG, 'Unsafe.Cast<TThing>(GObj).Ping'), 'Integer');
    Eq('a call written with <T> skips the derived NON-generic of that name',
      XTypeOf(LG, 'GBag.Fetch<TThing>(''x'')'), 'TThing');

    // ---- a helper reached through the target's alias identity ----
    LE := ModelByName('al4');
    Ok('AL4 loaded', Assigned(LE));
    Ok('AL4: no diags at all', Length(LE.Diags) = 0);
    Eq('helper written against an ALIAS answers for the aliased type too',
      XTypeOf(LE, 'GSpot.Doubled'), 'Integer');

    // ---- 12.1.2 inherited head vs a redeclared name ----
    LE := ModelByName('in2');
    Ok('IN2 loaded', Assigned(LE));
    Ok('IN2: no diags at all', Length(LE.Diags) = 0);
    // NB not `XTypeOf(LE, 'Alignment')` — that text matches the class's own
    // property DECLARATION first. The chain is the unambiguous probe, and it
    // is also the thing that was broken: the head bound to the class's own
    // `Alignment: string`, so `.FHorz` had nowhere to resolve.
    Eq('`inherited Alignment` is the ANCESTOR''s (its FHorz resolves)',
      XTypeOf(LE, 'Alignment.FHorz'), 'Integer');

    // ---- a helper's ANCESTOR helper, and arity by COUNT ----
    LE := ModelByName('spc');
    Ok('SPC loaded', Assigned(LE));
    Ok('SPC: no diags at all', Length(LE.Diags) = 0);
    Eq('the ACTIVE (derived) helper''s own member',
      XTypeOf(LE, 'AThing.FromDerived'), 'Integer');
    Eq('...and its helper ANCESTOR''s, reachable only through it (15.3)',
      XTypeOf(LE, 'AThing.FromBase'), 'Integer');
    Eq('...and the extended type''s own is still there',
      XTypeOf(LE, 'AThing.Own'), 'Integer');
    LE := ModelByName('spn');
    Ok('SPN loaded', Assigned(LE));
    Ok('SPN: no diags at all — both arities pick their OWN nested type',
      Length(LE.Diags) = 0);
    Eq('arity 1 reaches TNodes<T>''s node record', XTypeOf(LE, 'Result.fKey'),
      'T');
    Eq('arity 2 reaches TNodes<TKey,TValue>''s — a DIFFERENT nested type',
      XTypeOf(LE, 'Result.fKeyed'), 'TKey');

    // ---- overload selection across an alias identity ----
    LE := ModelByName('ov');
    Ok('OV loaded', Assigned(LE));
    Ok('OV: no diags at all', Length(LE.Diags) = 0);
    // `X` is TSpot's; reaching it means the TSpot overload won, and it could
    // only win by canonicalizing the alias — the argument and the parameter
    // are declared through different symbols for the one type.
    Eq('the record overload matching through an ALIAS wins the tie',
      XTypeOf(LE, 'AConv.Conv(S,1,1)'), 'TSpotAlias');
    // The derived interface's own overload takes an ARRAY, so it has to be
    // rejected on argument types before the ancestor's is even looked for.
    Eq('an array parameter rejects a record argument, reaching the ancestor''s',
      XTypeOf(LE, 'AMore.Take(S)'), 'Integer');

    // ---- a SAME-UNIT helper hides the type's own member (15.3.3) ----
    LE := ModelByName('sh');
    Ok('SH loaded', Assigned(LE));
    Ok('SH: no diags at all', Length(LE.Diags) = 0);
    Eq('the helper''s Imp wins over the class''s own, so Stack resolves',
      XTypeOf(LE, 'Imp.Stack'), 'Integer');

    // ---- generic-ancestor frame survives a unit-name override ----
    LE := ModelByName('ns.test');
    Ok('NS.Test loaded', Assigned(LE));
    Ok('NS.Test: no diags at all', Length(LE.Diags) = 0);
    // `Mine` exists only on the ARGUMENT: reaching it proves the frame was
    // carried through the override, not that the constraint was searched.
    Eq('`Params.Mine` — the frame survives, not just the constraint',
      XTypeOf(LE, 'Params.Mine'), 'Integer');

    // ---- a real project's tail: five shapes, one unit ----
    LE := ModelByName('tl1');
    Ok('TL1 loaded', Assigned(LE));
    Ok('TL1: no diags at all', Length(LE.Diags) = 0);
    Eq('a default array property decides what `with Values[0]` opens',
      XTypeOf(LE, 'Tag'), 'Integer');
    Eq('...and the ENCLOSING with still answers for the collection',
      XTypeOf(LE, 'Values.Separator'), 'string');
    // NB no `T.Create` case here: the `constructor` constraint resolves
    // through TObject, and this corpus is a bare directory with no System
    // unit to resolve it in. It is covered by the corpus measurement instead
    // (a real project's threading-library report) — the same reason the RTL
    // helper cases below assert types rather than absence.
    Eq('a member on the SECOND of several constraints (16.4.1)',
      XTypeOf(LE, 'AKey.Hash'), 'Integer');
    Eq('a bare QUALIFIER means the parameterless overload',
      XTypeOf(LE, 'Add.Tag'), 'Integer');
    Eq('an all-defaulted function reference is still called by its name',
      XTypeOf(LE, 'GStylerFunc.Color'), 'Integer');

    // ---- with over a generic-instantiation call result ----
    LR := ModelByName('xr');
    Ok('XR loaded', Assigned(LR));
    Ok('XR: no diags (with GPool.Lock do FValue)', Length(LR.Diags) = 0);
    // Substitution, not just membership: FValue must come back as Integer
    // (the instantiation frame applied), not as the open parameter T.
    Eq('with-body member substituted in the instantiation frame',
      XTypeOf(LR, 'FValue'), 'Integer');
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  Writeln(Format('=== SemaXTypeSmoke: %d passed, %d failed ===',
    [GPassed, GFailed]));
  if GFailed > 0 then
    ExitCode := 1;
end.
