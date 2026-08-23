program SemaProjectSmoke;

{ Phase-2 cross-unit smoke tests: writes tiny unit fixtures to a temp dir and
  runs the project analyzer, checking external resolution, qualified access,
  E2003 (fired only when all uses resolve) and impl->interface linking. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Generics.Collections,
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
  PasTree.Sema.Nav in '..\source\PasTree.Sema.Nav.pas',
  PasTree.Sema.Project in '..\source\PasTree.Sema.Project.pas',
  PasTree.TestKit in 'PasTree.TestKit.pas';

var
  GProj: TPasSemaProject;
  GCounter: TPasSuiteCounter;

const
  UNIT_A =
    'unit UnitA;'#10'interface'#10 +
    'type TThing = record V: Integer; end;'#10 +
    'const KA = 7;'#10 +
    'function Foo: Integer;'#10 +
    'implementation'#10 +
    'function Foo: Integer; begin Result := KA; end;'#10'end.'#10;

  UNIT_B =
    'unit UnitB;'#10'interface'#10'uses UnitA;'#10 +
    'var GB: TThing;'#10'implementation'#10 +
    'procedure Bar;'#10'var L: Integer;'#10'begin'#10 +
    '  L := KA;'#10'  L := Foo;'#10'  L := UnitA.KA;'#10'end;'#10'end.'#10;

  UNIT_C =
    'unit UnitC;'#10'interface'#10'uses UnitA;'#10'implementation'#10 +
    'procedure Baz;'#10'begin'#10'  Nonexistent := 1;'#10'end;'#10'end.'#10;

  UNIT_D =
    'unit UnitD;'#10'interface'#10'uses NoSuchUnit;'#10'implementation'#10 +
    'procedure Q;'#10'begin'#10'  Whatever := 2;'#10'end;'#10'end.'#10;

  // A fixture for the IMPLICIT `System` unit (mirrors the real sLineBreak
  // shape) -- every unit uses it without a `uses` clause naming it. UnitE
  // below references SYS_CONST with NO uses clause at all; CrossResolve's
  // FindInSystemUnit fallback must resolve it (real dcc always can) instead
  // of firing a false E2003.
  // TObject lives here too, because a class with NO heritage clause still
  // inherits from it (11.1.1) — see UNIT_TOBJ below.
  UNIT_SYS =
    'unit System;'#10'interface'#10 +
    'const SYS_CONST = 42;'#10 +
    'type'#10 +
    // TGUID/IInterface: real declarations (PasTree.Sema.Builtins no longer
    // seeds either — both are genuine System.pas types), needed by
    // UNIT_IFACEROOT's heritage-less interface reaching QueryInterface.
    '  TGUID = record'#10 +
    '    D1: Cardinal;'#10 +
    '  end;'#10 +
    '  IInterface = interface'#10 +
    '    function QueryInterface(const IID: TGUID; out Obj): Integer;'#10 +
    '  end;'#10 +
    '  TObject = class'#10 +
    '    function ClassName: string;'#10 +
    '    procedure Free;'#10 +
    '  end;'#10 +
    // TArray is ALSO a seeded builtin (PasTree.Sema.Builtins), so a
    // `TArray<T>` reference resolves its head to a DeclNode-less symbol with
    // no generic parameter list — see UNIT_WSHAPES.
    '  TArray<T> = array of T;'#10 +
    // The element type of `array of const` (6.2.6). Real System.pas declares it
    // as a variant record; two fields are enough to prove the with scope opened.
    '  TVarRec = record'#10 +
    '    VType: Byte;'#10 +
    '    VInteger: Integer;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TObject.ClassName: string; begin Result := ''''; end;'#10 +
    'procedure TObject.Free; begin end;'#10 +
    'end.'#10;

  // Every `with`-target shape the RTL uses that the type-of-target walk did
  // not know, plus two neighbours found while closing them. Together these
  // were the last 39 false E2003s over the Win32 RTL, and the file mirrors
  // each real site:
  //   Arr[I]            — element type: inline array, named array, TArray<T>
  //                       (System.WideStrings' FList[Index], System.Variants'
  //                       LVarBounds[I], System.TypInfo's Entry.Aliases[...])
  //   P^[I]             — index over a dereference (System.AnsiStrings)
  //   Obj as T          — cast (System.Net.Socket)
  //   TFoo.Create(...)  — constructor call yields the CLASS (System.Win.VCLCom)
  //   P.Field           — IMPLICIT dereference in member access, which is what
  //                       reaches Entry.Aliases at all (System.TypInfo)
  //   Own.Unit.Name.X   — a unit qualifying with its OWN name, which is never
  //                       in its own uses list (Winapi.Windows' DrawText)
  //   helper for Alias  — a helper declared for an ALIAS of the struct whose
  //                       methods use it (Winapi.D2D1's SetProduct)
  UNIT_WSHAPES =
    'unit UnitWShapes;'#10'interface'#10 +
    'type'#10 +
    '  TElem = record'#10 +
    '    Name: string;'#10 +
    '    Value: Integer;'#10 +
    '  end;'#10 +
    '  TEntry = record'#10 +
    '    Aliases: TArray<TElem>;'#10 +
    '  end;'#10 +
    '  PEntry = ^TEntry;'#10 +
    '  TElemArray = array[0..3] of TElem;'#10 +
    '  PElemArray = ^TElemArray;'#10 +
    '  TThing = class'#10 +
    '    Tag: Integer;'#10 +
    '    constructor Create;'#10 +
    '  end;'#10 +
    '  TInner = record W: Integer; end;'#10 +
    '  TMid = record inner: TInner; end;'#10 +
    '  TOuter = record mid: TMid; end;'#10 +
    '  TSub = class(TThing)'#10 +
    '    Extra: Integer;'#10 +
    '    Box: TInner;'#10 +
    '  end;'#10 +
    '  TMat = record'#10 +
    '    m11: Single;'#10 +
    '    class operator Multiply(const L, R: TMat): TMat;'#10 +
    '  end;'#10 +
    '  TMatAlias = TMat;'#10 +
    '  TMatHelper = record helper for TMatAlias'#10 +
    '    class function SetProduct(const a, b: TMatAlias): TMatAlias; static;'#10 +
    '  end;'#10 +
    'function Pick: Integer;'#10 +
    'implementation'#10 +
    'constructor TThing.Create; begin end;'#10 +
    'class function TMatHelper.SetProduct(const a, b: TMatAlias): TMatAlias;'#10 +
    'begin'#10 +
    '  Result.m11 := a.m11 * b.m11;'#10 +
    'end;'#10 +
    'class operator TMat.Multiply(const L, R: TMat): TMat;'#10 +
    'begin'#10 +
    '  Result := SetProduct(L, R);'#10 +   // helper static via the ALIAS
    'end;'#10 +
    'function Pick: Integer; begin Result := 1; end;'#10 +
    'procedure UseShapes;'#10 +
    'var'#10 +
    '  Entry: PEntry;'#10 +
    '  Inline1: array[0..2] of TElem;'#10 +
    '  Named: TElemArray;'#10 +
    '  PArr: PElemArray;'#10 +
    '  Obj: TThing;'#10 +
    '  Outer: TOuter;'#10 +
    '  I: Integer;'#10 +
    'begin'#10 +
    '  with Entry.Aliases[I] do'#10 +     // implicit deref + TArray<T> element
    '  begin'#10 +
    '    Name := ''x'';'#10 +
    '    Value := 1;'#10 +
    '  end;'#10 +
    '  with Inline1[I] do'#10 +           // inline array element
    '    Value := 2;'#10 +
    '  with Named[I] do'#10 +             // named array type element
    '    Value := 3;'#10 +
    '  with PArr^[I] do'#10 +             // index over a dereference
    '    Value := 4;'#10 +
    '  with Obj as TSub do'#10 +          // as-cast
    '    Extra := 5;'#10 +
    '  with TThing.Create do'#10 +        // constructor call -> the class
    '    Tag := 6;'#10 +
    // MULTI-TARGET: every target after the first is resolved INSIDE the ones
    // before it, so `mid` is only findable through Outer and `inner` only
    // through mid. This is Vcl.Graphics' `with DIB, dsbm, dsbmih do` and
    // Vcl.Controls' `with TDragDockObject(ADragObject), FDockRect do`; both
    // used to leave the later targets — and then every member reached through
    // them in the body — undeclared.
    '  with Outer, mid, inner do'#10 +
    '    W := 7;'#10 +
    '  with TSub(Obj), Box do'#10 +       // cast first, then a field OF the cast
    '    W := 8;'#10 +
    '  I := UnitWShapes.Pick;'#10 +       // qualifying with our OWN unit name
    'end;'#10 +
    'end.'#10;

  // 16.4.1 — type-parameter constraints. The generics live in UnitCon and the
  // instantiations in UnitConUse, so the whole check runs CROSS-MODEL: the
  // constraint nodes belong to the declaring model while the arguments belong
  // to the using one, and reading either in the wrong model is the mistake
  // this fixture exists to catch. Accepted sets are dcc32 37.0-verified — see
  // CheckConstraints. TFree is the control: no constraint, anything goes.
  { 5.7 — a NESTED `with` whose INNER target is an inherited CROSS-UNIT
    property. Vcl.ColorGrd's real shape:

      else with CellRect do
      begin
        ...
        end else with Canvas do
        begin
          Pen.Color := clBlack;
          Rectangle(Left, Top, Right, Bottom);   // Left/Top from the OUTER with
        end;

    The inner target `Canvas` is a body node of the OUTER with, which is exactly
    the position the two earlier cross passes skip (deciding such a node needs a
    with-target type they are still producing). Only the with pass resolves it —
    and its bindings used to be committed after the whole round, so the body's
    `Pen` looked it up while still unbound, the inner with never opened, and
    every member of it became a false E2003. `Rectangle` was worse than
    undeclared: it bound to the 5-argument global instead, turning into a bogus
    E2035.

    Three units because both hops must be CROSS-model: the property is declared
    in the ancestor's unit, its type in a third. }
  { 5.7 — a MULTI-TARGET `with` whose first target's type lives in ANOTHER unit.
    Vcl.Graphics' real shape, `with DIB, dsbm, dsbmih do`, where DIB is a
    TDIBSection from Winapi.Windows and each later target is a field of the one
    before it.

    Distinct from the same-unit case in UNIT_WSHAPES, and it stayed broken after
    that one was fixed: a later TARGET is not inside any with BODY, so the cross
    passes classified it as an ordinary identifier, handed it to the inherited
    pass — which knows nothing about with scopes — and emitted E2003 for it.
    FindInEnclosingWith could already resolve it; nothing routed it there. }
  { 14.2.2 — METHOD RESOLUTION CLAUSES. `function IPersistStreamInit.Load =
    PersistStreamLoad;` maps an interface method to a differently-named class
    method. The segments arrive as a flat sibling list, so resolving them all as
    names in the CLASS scope reports the interface's own method as undeclared:
    6 sites in Vcl.AxCtrls, 49 across the corpus.

    Both interfaces declare `Load`, which is the point of the construct — and the
    control that a fix cannot cheat by picking the first match. }
  UNIT_MRIFACE =
    'unit UnitMRIface;'#10'interface'#10 +
    'type'#10 +
    '  IReaderLike = interface'#10 +
    '    function Load: Integer;'#10 +
    '  end;'#10 +
    '  IWriterLike = interface'#10 +
    '    function Load: Integer;'#10 +
    '  end;'#10 +
    'implementation'#10'end.'#10;
  UNIT_MRUSE =
    'unit UnitMRUse;'#10'interface'#10 +
    'uses UnitMRIface;'#10 +
    'type'#10 +
    '  TImplX = class(TObject, IReaderLike, IWriterLike)'#10 +
    '  protected'#10 +
    '    function IReaderLike.Load = ReaderLoad;'#10 +   // 7  cross-unit iface
    '    function IWriterLike.Load = WriterLoad;'#10 +   // 8  clashing name
    '    function ReaderLoad: Integer;'#10 +
    '    function WriterLoad: Integer;'#10 +
    '  end;'#10 +
    // Same-unit interface: the segment IS bindable, so this also covers the
    // navigable half of the fix.
    '  ILocalLike = interface'#10 +
    '    procedure Store;'#10 +
    '  end;'#10 +
    '  TImplY = class(TObject, ILocalLike)'#10 +
    '  protected'#10 +
    '    procedure ILocalLike.Store = DoStore;'#10 +     // 17 same-unit iface
    '    procedure DoStore;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TImplX.ReaderLoad: Integer; begin Result := 1; end;'#10 +
    'function TImplX.WriterLoad: Integer; begin Result := 2; end;'#10 +
    'procedure TImplY.DoStore; begin end;'#10 +
    'end.'#10;

  UNIT_MTREC =
    'unit UnitMTRec;'#10'interface'#10 +
    'type'#10 +
    '  TInnerRec = record W, H: Integer; end;'#10 +
    '  TOuterRec = record inner: TInnerRec; Flag: Integer; end;'#10 +
    // For the deref/member/index target shapes below. rgrc's type is an INLINE
    // array, which is the part that made it hard: the element type is reachable
    // only through the member SYMBOL's own type node.
    '  TParamsLike = record'#10 +
    '    rgrc: array[0..2] of TInnerRec;'#10 +
    '    Count: Integer;'#10 +
    '  end;'#10 +
    '  PParamsLike = ^TParamsLike;'#10 +
    // Indexing a POINTER to an array, `^` omitted before `[` and no POINTERMATH
    // — Vcl.Imaging.pngimage's pPixelLine/TPixelLine shape, 23 sites there and
    // 6 more in GIFImg. dcc-verified as both an expression and a with target.
    '  TQuadLike = record R, G, B: Byte; end;'#10 +
    '  TLineLike = array[0..255] of TQuadLike;'#10 +
    '  PLineLike = ^TLineLike;'#10 +
    // 13.1.4 default ARRAY property, inherited one level down — the
    // `with ActionManager.ActionBars[I] do` shape. TValueProp is the control:
    // a default VALUE spec on an ordinary property spells the same word and
    // must NOT be mistaken for it.
    '  TItemLike = class'#10 +
    '    Tag: Integer;'#10 +
    '  end;'#10 +
    '  TCanvasBaseKin = class'#10 +
    '    Mark: Integer;'#10 +
    '  end;'#10 +
    // 15.2.1 — a CLASS REFERENCE. `with TEngineClass(SomeEngine) do` reaches the
    // referenced class's members (Vcl.Themes does this for its class vars), so a
    // member walk must hop from `class of T` to T.
    '  TEngineKin = class'#10 +
    '    class var Registry: Integer;'#10 +
    '  end;'#10 +
    '  TEngineKinClass = class of TEngineKin;'#10 +
    '  TCollBase = class'#10 +
    '  private'#10 +
    '    function GetItem(const Index: Integer): TItemLike;'#10 +
    '  public'#10 +
    '    property Items[const Index: Integer]: TItemLike'#10 +
    '      read GetItem; default;'#10 +
    '  end;'#10 +
    '  TCollLike = class(TCollBase)'#10 +
    '    Count: Integer;'#10 +
    '  end;'#10 +
    // 13.1 — a bare property REDECLARATION: no type, no specifiers, it only
    // promotes visibility. Vcl.StdCtrls declares `Items: TStrings` on
    // TCustomListBox and republishes it on TListBox exactly like this, which is
    // why `with CatList.Items do` (Vcl.CustomizeDlg) typed to nothing: the
    // redeclaration is a real symbol with NO TypeNode of its own.
    '  TBoxBase = class'#10 +
    '  private'#10 +
    '    FItems: TCollLike;'#10 +
    '  protected'#10 +
    '    property Items: TCollLike read FItems;'#10 +
    '  end;'#10 +
    '  TBoxLike = class(TBoxBase)'#10 +
    '  published'#10 +
    '    property Items;'#10 +          // the redeclaration
    '  end;'#10 +
    '  TValueProp = class'#10 +
    '  private'#10 +
    '    FN: Integer;'#10 +
    '  public'#10 +
    '    property N: Integer read FN default 7;'#10 +
    '  end;'#10 +
    // A CONSTRUCTOR as the with target, in both spellings. Its own class is the
    // target type; Mark is inherited, so it only resolves if the walk reached
    // the class rather than the constructor's (absent) result type.
    '  TCanvasKin = class(TCanvasBaseKin)'#10 +
    '    Owner: TObject;'#10 +
    '    constructor Create; overload;'#10 +
    '    constructor Create(AOwner: TObject); overload;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TCollBase.GetItem(const Index: Integer): TItemLike;'#10 +
    'begin Result := nil; end;'#10 +
    'constructor TCanvasKin.Create; begin end;'#10 +
    'constructor TCanvasKin.Create(AOwner: TObject); begin end;'#10 +
    'end.'#10;
  UNIT_MTUSE =
    'unit UnitMTUse;'#10'interface'#10 +
    'uses UnitMTRec;'#10 +
    'procedure Go;'#10 +
    'implementation'#10 +
    'procedure Go;'#10 +
    'var'#10 +
    '  D: TOuterRec;'#10 +                 // 8  type from another unit
    'begin'#10 +
    '  with D, inner do'#10 +              // 10 `inner` is a field of D
    '  begin'#10 +
    '    W := 1;'#10 +                     // 12 reached only through inner
    '    H := D.Flag;'#10 +                // 13 and the target still works bare
    '  end;'#10 +
    'end;'#10 +
    // Target-expression shapes over CROSS-UNIT types, the Vcl.Forms
    // `with Params^.rgrc[0] do` family. A member whose declared type is an
    // inline array, indexed — DesignatorSymX has to find that member through
    // the base's TYPE, because the pass that records cross-unit member
    // references (CrossType) runs after the with pass that needs it.
    'procedure Shapes(P: PParamsLike);'#10 +
    'var'#10 +
    '  V: TParamsLike;'#10 +
    'begin'#10 +
    '  with P^ do'#10 +                    // 21 deref
    '    Count := 1;'#10 +
    '  with V.rgrc[0] do'#10 +             // 23 member + index
    '    W := 1;'#10 +
    '  with P^.rgrc[0] do'#10 +            // 25 deref + member + index
    '    H := 1;'#10 +
    'end;'#10 +
    // Indexing a pointer-to-array with the `^` omitted, as an expression and as
    // a with target. R is reachable only through the element type.
    'procedure Lines(L: PLineLike);'#10 +
    'begin'#10 +
    '  L[0].R := 1;'#10 +                  // expression form
    '  with L[1] do'#10 +                  // with-target form
    '    G := 2;'#10 +
    'end;'#10 +
    // Indexing a CLASS through its INHERITED default array property, unnamed —
    // the element type is the property's, not the collection's.
    'procedure Coll(C: TCollLike; V: TValueProp);'#10 +
    'begin'#10 +
    '  with C do'#10 +                     // 31 control: the collection itself
    '    Count := 1;'#10 +
    '  with C[0] do'#10 +                  // 33 default array property, unnamed
    '    Tag := 2;'#10 +
    '  with C.Items[0] do'#10 +            // 35 the same property, named
    '    Tag := 3;'#10 +
    '  with V do'#10 +                     // 37 control: a default VALUE spec
    '    if N = 0 then Exit;'#10 +         //    is not a default array property
    'end;'#10 +
    // 6.2.6 — `array of const` IS an array of System.TVarRec, so indexing one
    // opens over TVarRec's fields. A threading library's own units do
    // exactly this (`with aValues[i] do case VType of ...`), 56 sites.
    // 10.3 — `TextFile` is predefined and has no declaration to fall back on.
    // The redeclaration as a with TARGET, reached through a bare field of the
    // enclosing class — the Vcl.CustomizeDlg shape exactly.
    'type'#10 +
    '  TFormLike = class'#10 +
    '    CatList: TBoxLike;'#10 +
    '    procedure Fill;'#10 +
    '  end;'#10 +
    'procedure Consts(aValues: array of const; var F: textfile);'#10 +
    'var'#10 +
    '  I, N: Integer;'#10 +
    'begin'#10 +
    '  for I := Low(aValues) to High(aValues) do'#10 +
    '    with aValues[I] do'#10 +          // 47 element type is TVarRec
    '      if VType = 0 then'#10 +         // 48 a TVarRec field, bare
    // N, not I: assigning to the loop counter is E2081 (5.5.1) and dcc would
    // reject this fixture too. It went unnoticed until the check existed.
    '        N := VInteger;'#10 +
    'end;'#10 +
    // The property redeclaration as a with target, base = a bare field of the
    // enclosing class. Count is reachable ONLY through the with scope, so
    // binding it proves the redeclaration got the INHERITED declaration's type.
    'procedure TFormLike.Fill;'#10 +
    'var'#10 +
    '  N: Integer;'#10 +
    'begin'#10 +
    '  with CatList.Items do'#10 +
    '    N := Count;'#10 +
    'end;'#10 +
    // A CONSTRUCTOR call as the with target — the cross-unit case, where the
    // constructor is NOT bound yet when the with pass asks (CrossType records
    // that, and it runs later). Both spellings: paren-less and with arguments.
    'procedure Ctors;'#10 +
    'begin'#10 +
    '  with TCanvasKin.Create do'#10 +     // 44 paren-less
    '    Mark := 1;'#10 +
    '  with TCanvasKin.Create(nil) do'#10 + // 46 with arguments
    '    Owner := nil;'#10 +
    'end;'#10 +
    // A cast to a CLASS REFERENCE as the with target (15.2.1).
    'procedure Meta(E: TObject);'#10 +
    'begin'#10 +
    '  with TEngineKinClass(E) do'#10 +
    '    Registry := 1;'#10 +
    'end;'#10 +
    // 12.1.2 — `inherited Name` heads a designator naming an ANCESTOR member, so
    // its type comes from the ancestor. Vcl.ExtCtrls uses `with inherited Canvas
    // do`, where resolving the name against the class itself finds nothing.
    'type'#10 +
    '  TDerivedKin = class(TCanvasKin)'#10 +
    '    procedure Paint;'#10 +
    '  end;'#10 +
    'procedure TDerivedKin.Paint;'#10 +
    'begin'#10 +
    '  with inherited Owner do'#10 +       // the ancestor''s member
    '    ClassName;'#10 +
    'end;'#10 +
    'end.'#10;

  UNIT_NWCANVAS =
    'unit UnitNWCanvas;'#10'interface'#10 +
    'type'#10 +
    '  TCanvasLike = class'#10 +
    '  private'#10 +
    '    FPen: Integer;'#10 +
    '  public'#10 +
    '    property Pen: Integer read FPen write FPen;'#10 +
    '    procedure Rectangle(a, b, c, d: Integer);'#10 +
    '  end;'#10 +
    'procedure Rectangle(dc, a, b, c, d: Integer);'#10 +  // the 5-arg global
    'implementation'#10 +
    'procedure TCanvasLike.Rectangle(a, b, c, d: Integer); begin end;'#10 +
    'procedure Rectangle(dc, a, b, c, d: Integer); begin end;'#10 +
    'end.'#10;
  UNIT_NWBASE =
    'unit UnitNWBase;'#10'interface'#10 +
    'uses UnitNWCanvas;'#10 +
    'type'#10 +
    '  TBase = class'#10 +
    '  private'#10 +
    '    FCanvas: TCanvasLike;'#10 +
    '  protected'#10 +
    '    property Canvas: TCanvasLike read FCanvas;'#10 +
    '  end;'#10 +
    'implementation'#10'end.'#10;
  UNIT_NWUSE =
    'unit UnitNWUse;'#10'interface'#10 +
    'uses UnitNWBase;'#10 +
    'type'#10 +
    '  TRectLike = record Left, Top: Integer; end;'#10 +
    '  TDerived = class(TBase)'#10 +
    '    Cell: TRectLike;'#10 +
    '    procedure Paint;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure TDerived.Paint;'#10 +
    'begin'#10 +
    '  with Cell do'#10 +                    // 13
    '    with Canvas do'#10 +                // 14  inherited, CROSS-unit
    '    begin'#10 +
    '      Pen := Left;'#10 +                // 16  Pen: inner, Left: outer
    '      Rectangle(Left, Top, 3, 4);'#10 + // 17  the 4-arg METHOD, not global
    '    end;'#10 +
    'end;'#10 +
    'end.'#10;

  UNIT_CON =
    'unit UnitCon;'#10'interface'#10 +
    'type'#10 +
    '  TBase = class end;'#10 +
    '  TDeriv = class(TBase) end;'#10 +
    '  TOther = class end;'#10 +
    '  TRec = record X: Integer; end;'#10 +
    '  TEnum = (eA, eB);'#10 +
    '  TDyn = array of Integer;'#10 +
    '  TNeedClass<T: class> = class end;'#10 +
    '  TNeedRecord<T: record> = class end;'#10 +
    '  TNeedBase<T: TBase> = class end;'#10 +
    '  TFree<T> = class end;'#10 +
    'implementation'#10'end.'#10;

  UNIT_CONUSE =
    'unit UnitConUse;'#10'interface'#10'uses UnitCon;'#10 +
    'var'#10 +
    '  Bad1: TNeedClass<Integer>;'#10 +      // E2511
    '  Bad2: TNeedRecord<string>;'#10 +      // E2512 (managed)
    '  Bad3: TNeedRecord<TDyn>;'#10 +        // E2512 (array)
    '  Bad4: TNeedBase<TOther>;'#10 +        // E2515 (unrelated class)
    '  Ok1: TNeedClass<TBase>;'#10 +
    '  Ok2: TNeedRecord<TRec>;'#10 +
    '  Ok3: TNeedRecord<TEnum>;'#10 +
    '  Ok4: TNeedRecord<Integer>;'#10 +
    '  Ok5: TNeedBase<TDeriv>;'#10 +         // descendant
    '  Ok6: TNeedBase<TBase>;'#10 +          // the constraint type itself
    '  Ok7: TFree<string>;'#10 +
    'implementation'#10'end.'#10;

  // 16.1.2 — one generic name declared at several ARITIES. These are two
  // distinct types; CollectTypeDecl used to reuse the first symbol for the
  // second declaration (the forward-completion path) and overwrite its member
  // scope, orphaning the first type's members. TFwd is the control that
  // matters: the forward-completion path must keep working, and must NOT start
  // reporting a redeclaration now that the arities are compared.
  UNIT_ARITY =
    'unit UnitArity;'#10'interface'#10 +
    'type'#10 +
    '  TBox<T> = class'#10 +
    '    FV: T;'#10 +
    '    function Get: T;'#10 +
    '  end;'#10 +
    '  TBox<TKey, TVal> = class'#10 +
    '    FK: TKey;'#10 +
    '    FV: TVal;'#10 +
    '    function GetKey: TKey;'#10 +
    '  end;'#10 +
    '  TFwd = class;'#10 +
    '  TFwd = class'#10 +
    '    Z: Integer;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TBox<T>.Get: T; begin Result := FV; end;'#10 +
    'function TBox<TKey, TVal>.GetKey: TKey; begin Result := FK; end;'#10 +
    'procedure Use;'#10 +
    'var'#10 +
    '  B1: TBox<Integer>;'#10 +
    '  B2: TBox<string, Integer>;'#10 +
    '  I: Integer;'#10 +
    '  S: string;'#10 +
    '  F: TFwd;'#10 +
    'begin'#10 +
    '  I := B1.Get;'#10 +      // arity-1 member and its result
    '  I := B1.FV;'#10 +
    '  S := B2.GetKey;'#10 +   // arity-2 member, whose T is the FIRST param
    '  I := B2.FV;'#10 +       // same field NAME, different type per arity
    '  I := F.Z;'#10 +
    'end;'#10 +
    'end.'#10;

  // A bare member of the IMPLICIT TObject ancestor. Neither class below
  // names a heritage, so the ancestor walk used to stop at the class itself
  // and report ClassName/Free as undeclared. TSub also checks the walk
  // reaches TObject THROUGH an explicit ancestor that itself has none.
  UNIT_TOBJ =
    'unit UnitTObj;'#10'interface'#10 +
    'type'#10 +
    '  TPlain = class'#10 +
    '    procedure Go;'#10 +
    '  end;'#10 +
    '  TSub = class(TPlain)'#10 +
    '    procedure Deeper;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure TPlain.Go;'#10 +
    'begin'#10 +
    '  if ClassName = '''' then'#10 +
    '    Free;'#10 +
    'end;'#10 +
    'procedure TSub.Deeper;'#10 +
    'begin'#10 +
    '  if ClassName = '''' then'#10 +
    '    Exit;'#10 +
    'end;'#10 +
    'end.'#10;

  // A private nested type of the ANCESTOR OF A MIDDLE QUALIFIER SEGMENT.
  // TFlagSet belongs to TState; the method being implemented is
  // TPar.TState32.TFlag32.Check, so the type is reachable only by walking
  // TState32's ancestry — not TFlag32's, which is all the inherited pass used
  // to search. Mirrors System.Threading's TParallel.TLoopState32.
  // TLoopStateFlag32.ShouldExit over TLoopState's TLoopStateFlagSet (16 of
  // the RTL's false E2003s). TFlag32's OWN ancestry is exercised too, via
  // Tag, so the innermost segment keeps working and keeps its precedence.
  UNIT_QUAL =
    'unit UnitQual;'#10'interface'#10 +
    'type'#10 +
    '  TPar = class sealed'#10 +
    '  public type'#10 +
    '    TState = class'#10 +
    '    private type'#10 +
    '      TFlags = (Alpha, Beta);'#10 +
    '      TFlagSet = set of TFlags;'#10 +
    '      TFlag = class'#10 +
    '        Tag: Integer;'#10 +
    '      end;'#10 +
    '    end;'#10 +
    '    TState32 = class sealed(TState)'#10 +
    '    public type'#10 +
    '      TFlag32 = class(TState.TFlag)'#10 +
    '        function Check: Boolean;'#10 +
    '      end;'#10 +
    '    end;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TPar.TState32.TFlag32.Check: Boolean;'#10 +
    'var'#10 +
    '  F: TFlagSet;'#10 +          // ancestor-of-middle-segment nested type
    'begin'#10 +
    '  F := [TFlags.Alpha];'#10 +  // ditto, and its values
    '  Result := (F <> []) and (Tag > 0);'#10 +   // own ancestry still works
    'end;'#10 +
    'end.'#10;

  { A nested type whose ANCESTOR is a nested type of the ENCLOSING class's own
    ancestor — and that ancestor lives in ANOTHER unit, so only the cross pass
    can see it. Vcl.Skia/FMX.Skia's shape:

      TSkAnimatedPaintBox = class(TSkCustomAnimatedControl)
        TAnimation = class(TAnimationBase)   // ancestor's nested type, bare

    Six false E2003 per Skia unit came out of this one name, because the
    failure CASCADES: with the heritage unresolved the nested class has no
    ancestry at all, so its property specifiers (`read GetDuration`) and its
    methods' inherited consts (`Epsilon`) read as undeclared too. All three
    layers are asserted below, deliberately. }
  UNIT_NHBASE =
    'unit UnitNHBase;'#10'interface'#10 +
    'type'#10 +
    '  TAnim = class'#10 +
    '  protected const'#10 +
    '    Epsilon = 1;'#10 +
    '  protected'#10 +
    '    function GetSpan: Integer;'#10 +
    '    procedure SetSpan(const AValue: Integer);'#10 +
    '  end;'#10 +
    '  TCustomCtl = class'#10 +
    '  public type'#10 +
    '    TAnimationBase = class(TAnim)'#10 +
    '    end;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TAnim.GetSpan: Integer; begin Result := Epsilon; end;'#10 +
    'procedure TAnim.SetSpan(const AValue: Integer); begin end;'#10 +
    'end.'#10;

  UNIT_NHUSE =
    'unit UnitNHUse;'#10'interface'#10'uses UnitNHBase;'#10 +
    'type'#10 +
    '  TPaintBox = class(TCustomCtl)'#10 +
    '  public type'#10 +
    '    TAnimation = class(TAnimationBase)'#10 +   // enclosing's ancestor's
    '    published'#10 +
    '      property Span: Integer read GetSpan write SetSpan;'#10 +
    '    end;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'end.'#10;

  { 5.7 — three CROSS-UNIT with-target shapes, each a different mechanism and
    each a real VCL false E2003:

    - `with P^ do` where P is declared with an INLINE anonymous pointer type
      (`P: ^TExtPen`). No pointer type SYMBOL exists anywhere, so the pointee can
      only come from the declaration's type NODE. Vcl.Graphics.GetPenData's
      `PExtLogPen: ^TExtLogPen` + `with Result, PExtLogPen^ do`.
    - `with AZ, UnitWX do` where the later target names a FIELD of the earlier
      one AND a used UNIT. Phase 1 binds the unit reference — never a legal with
      target — and a "bound" node used not to be reconsidered, so the second
      target never opened. Vcl.Imaging.pngimage's `with ZStream, ZLIB do` against
      System.ZLib.
    - `with THook.TScrollWindow(X) do`: a cast to a NESTED type named through its
      outer one, in another unit. Nothing binds that segment before the with pass
      runs. Vcl.Forms' `with TScrollBarStyleHook.TScrollWindow(FMDIScrollSizeBox)
      do SizeBox := True`. }
  UNIT_WX =
    'unit UnitWX;'#10'interface'#10 +
    'type'#10 +
    '  TExtPen = record'#10 +
    '    elpColor: Integer;'#10 +
    '  end;'#10 +
    '  TZRec = record'#10 +
    '    next_out: Integer;'#10 +
    '  end;'#10 +
    '  TZRec2 = record'#10 +
    '    UnitWX: TZRec;'#10 +          // a field named like the USED UNIT
    '    Data: Integer;'#10 +
    '  end;'#10 +
    '  TObjBase = class'#10 +
    '  end;'#10 +
    '  THook = class'#10 +
    '  public type'#10 +
    '    TScrollWindow = class(TObjBase)'#10 +
    '    private'#10 +
    '      FSizeBox: Boolean;'#10 +
    '    public'#10 +
    '      property SizeBox: Boolean read FSizeBox write FSizeBox;'#10 +
    '    end;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'end.'#10;

  UNIT_WXUSE =
    'unit UnitWXUse;'#10'interface'#10'uses UnitWX;'#10 +
    'implementation'#10 +
    'procedure UseWX(var AZ: TZRec2; AWnd: TObjBase);'#10 +
    'var'#10 +
    '  P: ^TExtPen;'#10 +               // INLINE anonymous pointer type
    'begin'#10 +
    '  New(P);'#10 +
    '  with P^ do'#10 +
    '    elpColor := 1;'#10 +
    '  with AZ, UnitWX do'#10 +         // later target = field, shadows the unit
    '    next_out := Data;'#10 +
    '  with THook.TScrollWindow(AWnd) do'#10 +   // cast to a nested type
    '    SizeBox := True;'#10 +
    'end;'#10 +
    'end.'#10;

  { An ancestor named through its OUTER type, cross-unit:
    `TMemoTextSettings = class(TTextSettingsInfo.TCustomTextSettings)` (FMX.Memo,
    and the same line in 8 sibling units). Nothing binds that last segment before
    the passes that decide E2003, and as a HERITAGE reference the miss is silent
    and expensive — the class is left with no ancestry, so every inherited member
    its methods use goes undeclared. 12 false E2003 across FMX came from this one
    form. HorzAlign is the control: redeclared here, so it resolved even while
    the ancestry was broken, which is why only SOME members of each such class
    were reported. }
  UNIT_NABASE =
    'unit UnitNABase;'#10'interface'#10 +
    'type'#10 +
    '  TInfo = class'#10 +
    '  public type'#10 +
    '    TCustomSettings = class'#10 +
    '    private'#10 +
    '      FWordWrap: Boolean;'#10 +
    '      FHorzAlign: Integer;'#10 +
    '    public'#10 +
    '      property WordWrap: Boolean read FWordWrap write FWordWrap;'#10 +
    '      property HorzAlign: Integer read FHorzAlign write FHorzAlign;'#10 +
    '    end;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'end.'#10;

  UNIT_NAUSE =
    'unit UnitNAUse;'#10'interface'#10'uses UnitNABase;'#10 +
    'type'#10 +
    '  TMemoSettings = class(TInfo.TCustomSettings)'#10 +
    '  public'#10 +
    '    constructor Create;'#10 +
    '  published'#10 +
    '    property HorzAlign;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'constructor TMemoSettings.Create;'#10 +
    'begin'#10 +
    '  HorzAlign := 1;'#10 +
    '  WordWrap := False;'#10 +
    'end;'#10 +
    'end.'#10;

  { An INHERITED method outranks a unit-level global of the same name, even one
    in this unit's own implementation section — dcc-verified. CollectStruct never
    joins an ancestor's scope, so Phase 1 bound the 4-parameter procedure and the
    1-argument call looked short by three: `GetFileNames(FShellItems)` inside
    TCustomFileOpenDialog.GetResults (FMX.Dialogs.Win), the corpus's last E2035.
    The `uses` clause is load-bearing — the arity check that fires on this shape
    is the cross-unit one, and it only runs for a unit that has imports. }
  UNIT_DLG =
    'unit UnitDlg;'#10'interface'#10'uses UnitA;'#10 +
    'type'#10 +
    '  TBaseDlg = class'#10 +
    '  protected'#10 +
    '    function GetFileNames(Items: Integer): Integer; dynamic;'#10 +
    '  end;'#10 +
    '  TOpenDlg = class(TBaseDlg)'#10 +
    '  public'#10 +
    '    function GetResults: Integer;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TBaseDlg.GetFileNames(Items: Integer): Integer;'#10 +
    'begin'#10 +
    '  Result := Items;'#10 +
    'end;'#10 +
    'procedure GetFileNames(var A, B, C: Integer; D: Integer); forward;'#10 +
    'function TOpenDlg.GetResults: Integer;'#10 +
    'begin'#10 +
    '  Result := GetFileNames(1);'#10 +
    'end;'#10 +
    'procedure GetFileNames(var A, B, C: Integer; D: Integer);'#10 +
    'begin'#10 +
    'end;'#10 +
    'end.'#10;

  { A default array property INHERITED FROM A GENERIC ANCESTOR, two hops up and
    cross-unit. HTMLViewer's shape: `TAttributeList = class(TObjectList<TAttribute>)`
    with no `Items` of its own, then `with L[I] do case Which of ...`. `Items: T`
    lives in `TList<T>`, and only TObjectList<TAttribute>'s frame turns that `T`
    into TAttribute.

    Two frame bugs met here, and either alone leaves the element type as the OPEN
    parameter — so the with scope opens over nothing and every member in the body
    is a false E2003 (~250 across that one library):
      - AncestorOfX resolved each heritage reference WITHOUT composing the
        descendant's frame, so a frame survived only one hop;
      - ElementX substituted with the frame of the type it STARTED at rather than
        the hop the property was found at, which for TAttrList is empty.

    Two units, because the intra-unit resolver handles the same-unit case on its
    own and hides the defect completely. }
  UNIT_GENLIST =
    'unit UnitGenList;'#10'interface'#10 +
    'type'#10 +
    // The ancestor chain is written out rather than using
    // System.Generics.Collections: this suite analyses a temp DIRECTORY, whose
    // only search path is that directory, so an RTL import would not resolve and
    // the fixture would pass for the wrong reason. Same two-hop shape.
    '  TBaseList<T> = class'#10 +
    '  private'#10 +
    '    function GetItem(AIndex: Integer): T;'#10 +
    '  public'#10 +
    '    function Count: Integer;'#10 +
    '    property Items[AIndex: Integer]: T read GetItem; default;'#10 +
    '  end;'#10 +
    '  TObjList<T> = class(TBaseList<T>)'#10 +       // middle hop, no default
    '  end;'#10 +
    '  TAttr = class'#10 +
    '  public'#10 +
    '    Which: Integer;'#10 +
    '    Name: string;'#10 +
    '  end;'#10 +
    '  TAttrList = class(TObjList<TAttr>)'#10 +      // Items is TWO hops up
    '  end;'#10 +
    'implementation'#10 +
    'function TBaseList<T>.GetItem(AIndex: Integer): T;'#10 +
    'begin'#10 +
    '  Result := Default(T);'#10 +
    'end;'#10 +
    'function TBaseList<T>.Count: Integer;'#10 +
    'begin'#10 +
    '  Result := 0;'#10 +
    'end;'#10 +
    'end.'#10;

  UNIT_GENLISTUSE =
    'unit UnitGenListUse;'#10'interface'#10'uses UnitGenList;'#10 +
    'procedure Use(L: TAttrList);'#10 +
    'implementation'#10 +
    'procedure Use(L: TAttrList);'#10 +
    'var'#10 +
    '  I: Integer;'#10 +
    'begin'#10 +
    '  for I := 0 to L.Count - 1 do'#10 +
    '    with L[I] do'#10 +
    '      if Which = 0 then'#10 +
    '        Name := ''x'';'#10 +
    'end;'#10 +
    'end.'#10;

  { `$IF Declared(X)` — the portability guard, answered on a SECOND
    preprocessing pass (RunDeclaredPass) once every unit has a model.

    Both directions have to be checked, because getting one right by accident
    is easy: a guard whose name IS declared must skip its text (the first two
    below name a compiler-provided type and an imported class, and the text
    they guard is deliberate nonsense), and a guard whose name is NOT must
    take it (TFallback, used by a field afterwards). The third asks the
    question the other way round. Answering a flat False, as the first pass
    must, gets the first two wrong and the last two right. }
  { Inline var visibility is POSITIONAL (3.1.3): visible from its declaration
    to the end of the enclosing block, and NOT above it.

    Written so a wrong binding is a TYPE error rather than nothing: the outer
    `GName` is a string and the inline one an Integer, so binding the earlier
    reference to the inline declaration — which is what a plain block scope
    does — silently loses the E2010 that dcc reports there. That asymmetry is
    the only observable difference; a wrong binding costs no diagnostic of its
    own, which is exactly why this survived a zero-false-positive corpus.

    The second half is the rule that must NOT break: a routine's classic `var`
    section stays order-independent, so `LI` is visible above its own
    declaration in the sense that matters (it is declared before the body). }
  UNIT_INLINEPOS =
    'unit UnitInlinePos;'#10'interface'#10 +
    'procedure Use;'#10 +
    'implementation'#10 +
    'var'#10 +
    '  GName: string;'#10 +
    'procedure Use;'#10 +
    'var'#10 +
    '  LI: Integer;'#10 +
    'begin'#10 +
    '  LI := GName;'#10 +              // the unit-level STRING -> E2010
    '  var GName: Integer := 0;'#10 +
    '  LI := GName;'#10 +              // the inline INTEGER -> fine
    'end;'#10 +
    'end.'#10;

  { An interface's IMPLICIT ancestor (14.1.1). A heritage-less interface still
    descends from IInterface, so QueryInterface/_AddRef/_Release are reachable
    on any value of that type — the member walk has to make that hop the way it
    already makes the TObject one for a heritage-less class.

    Written as a `with` body on purpose: an unresolved MEMBER after a dot is not
    reported at all today, so `I.QueryInterface` would pass whether the hop
    works or not. Inside a `with` the same name is a BARE identifier and a miss
    is a real E2003 — which is how the defect was found. (The first probe used
    a name that happened to resolve anyway, and a silent analyzer and a correct
    one looked identical until a deliberately undeclared control name proved
    the diagnostic fires there at all.)

    IInterface is DECLARED in a fixture unit rather than taken from the RTL:
    this suite analyses a temp directory whose only search path is itself, so a
    real System.pas is not reachable. It has to be a SEPARATE unit — the hop
    goes through ResolveRealDecl, which searches used units and the System unit
    and deliberately not the current one — which also makes this the same
    cross-unit shape the real IInterface has. }
  UNIT_IFACEBASE =
    'unit UnitIfaceBase;'#10'interface'#10 +
    'type'#10 +
    '  IInterface = interface'#10 +
    '    function QueryInterface(const IID: TGUID; out Obj): Integer;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'end.'#10;

  UNIT_IFACEROOT =
    'unit UnitIfaceRoot;'#10'interface'#10'uses UnitIfaceBase;'#10 +
    'type'#10 +
    '  IFoo = interface'#10 +          // no heritage clause of its own
    '    procedure Go;'#10 +
    '  end;'#10 +
    'procedure Use(I: IFoo);'#10 +
    'implementation'#10 +
    'procedure Use(I: IFoo);'#10 +
    'var'#10 +
    '  R: Integer;'#10 +
    '  G: TGUID;'#10 +
    '  O: Pointer;'#10 +
    'begin'#10 +
    '  with I do'#10 +
    '  begin'#10 +
    '    Go;'#10 +
    '    R := QueryInterface(G, O);'#10 +
    '  end;'#10 +
    'end;'#10 +
    'end.'#10;

  UNIT_DCLBASE =
    'unit UnitDclBase;'#10'interface'#10 +
    'type'#10 +
    '  TKnownThing = class'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'end.'#10;

  UNIT_DCLUSE =
    'unit UnitDclUse;'#10'interface'#10'uses UnitDclBase;'#10 +
    'type'#10 +
    '  {$IF not declared(UInt64)}'#10 +      // compiler-provided: skip
    '  UInt64 = ZzFpcOnlyWord;'#10 +
    '  {$IFEND}'#10 +
    '  {$IF not declared(TKnownThing)}'#10 + // imported: skip
    '  TKnownThing = ZzAlsoNotAThing;'#10 +
    '  {$IFEND}'#10 +
    '  {$IF declared(TNeverDeclaredAnywhere)}'#10 +   // absent: skip
    '  TAlias = ZzThirdNonThing;'#10 +
    '  {$IFEND}'#10 +
    '  {$IF not declared(TDefinitelyMissing)}'#10 +   // absent: TAKE
    '  TFallback = Integer;'#10 +
    '  {$IFEND}'#10 +
    '  TUse = class'#10 +
    '    A: UInt64;'#10 +
    '    B: TKnownThing;'#10 +
    '    C: TFallback;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'end.'#10;

  { A NESTED type of a generic, returned by one of its own members: the frame
    has to travel WITH the type, because that type has no arguments of its own
    yet its definition is written in the enclosing generic's parameters.

    `TList<T>` declares `arrayofT = array of T` and returns it from
    `property List`; the RTL's own container does exactly this, so
    `with FSelections.List[I] do` is ordinary code. Substituting the member
    type over the T := TSelection frame handed back the bare nested-type symbol
    with that frame dropped, indexing it produced the OPEN `T`, and the scope
    opened over nothing — 78 of 94 diagnostics on one project, across two units
    of the same editor component. }
  UNIT_NGBASE =
    'unit UnitNGBase;'#10'interface'#10 +
    'type'#10 +
    '  TMyList<T> = class'#10 +
    '  public type'#10 +
    '    arrayofT = array of T;'#10 +
    '  private'#10 +
    '    FItems: arrayofT;'#10 +
    '    function GetList: arrayofT;'#10 +
    '  public'#10 +
    '    property List: arrayofT read GetList;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TMyList<T>.GetList: arrayofT;'#10 +
    'begin'#10 +
    '  Result := FItems;'#10 +
    'end;'#10 +
    'end.'#10;

  UNIT_NGUSE =
    'unit UnitNGUse;'#10'interface'#10'uses UnitNGBase;'#10 +
    'type'#10 +
    '  TSel = record'#10 +
    '    Line: Integer;'#10 +
    '    Ch: Integer;'#10 +
    '  end;'#10 +
    '  TOwner = class'#10 +
    '  private'#10 +
    '    FSel: TMyList<TSel>;'#10 +
    '  public'#10 +
    '    procedure Bump(I: Integer);'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure TOwner.Bump(I: Integer);'#10 +
    'begin'#10 +
    '  with FSel.List[I] do'#10 +
    '    if Line > 0 then Inc(Ch);'#10 +
    'end;'#10 +
    'end.'#10;

  { `with F do` where F has OVERLOADS and the parameterless one is inherited.
    A ribbon library's accessibility helper: the class overrides
    `GetScreenBounds(out ABounds: TRect): Boolean` and inherits a parameterless
    `GetScreenBounds: TRect`, then writes `with GetScreenBounds do Left + Right`.
    A bare with target has no argument list, so 6.3.1 picks the arity-0 one;
    the member walk answers with the nearest same-named member instead and the
    with opened over a Boolean. }
  UNIT_POBASE =
    'unit UnitPOBase;'#10'interface'#10 +
    'type'#10 +
    '  TBnds = record'#10 +
    '    Left, Right: Integer;'#10 +
    '  end;'#10 +
    '  TPOBase = class'#10 +
    '  public'#10 +
    '    function GetBounds(out ABounds: TBnds): Boolean; overload; virtual;'#10 +
    '    function GetBounds: TBnds; overload;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TPOBase.GetBounds(out ABounds: TBnds): Boolean;'#10 +
    'begin'#10 +
    '  Result := False;'#10 +
    'end;'#10 +
    'function TPOBase.GetBounds: TBnds;'#10 +
    'begin'#10 +
    '  GetBounds(Result);'#10 +
    'end;'#10 +
    'end.'#10;

  UNIT_POUSE =
    'unit UnitPOUse;'#10'interface'#10'uses UnitPOBase;'#10 +
    'type'#10 +
    '  TPODer = class(TPOBase)'#10 +
    '  public'#10 +
    '    function GetBounds(out ABounds: TBnds): Boolean; override;'#10 +
    '    function Mid: Integer;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TPODer.GetBounds(out ABounds: TBnds): Boolean;'#10 +
    'begin'#10 +
    '  Result := True;'#10 +
    'end;'#10 +
    'function TPODer.Mid: Integer;'#10 +
    'begin'#10 +
    '  with GetBounds do'#10 +
    '    Result := (Left + Right) div 2;'#10 +
    'end;'#10 +
    'end.'#10;

  { Two ARITIES of one name in the SAME unit, split across its sections: the
    generic in the interface, a plain instantiation alias in the
    implementation. An editor library writes exactly this to give the common
    instantiation a short name. The alias is the nearer declaration, so its own
    heritage reference `TSelfAr<TSCtl>` resolved to the alias ITSELF — leaving
    it with no ancestor and every inherited member in the generic's method
    bodies a false E2003. }
  UNIT_SABASE =
    'unit UnitSABase;'#10'interface'#10 +
    'type'#10 +
    '  TSCtl = class'#10 +
    '  public'#10 +
    '    Caption: string;'#10 +
    '  end;'#10 +
    '  TSAProv<T: TSCtl> = class'#10 +
    '  strict private'#10 +
    '    function GetControl: T;'#10 +
    '  public'#10 +
    '    property Control: T read GetControl;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TSAProv<T>.GetControl: T;'#10 +
    'begin'#10 +
    '  Result := nil;'#10 +
    'end;'#10 +
    'end.'#10;

  UNIT_SAUSE =
    'unit UnitSAUse;'#10'interface'#10'uses UnitSABase;'#10 +
    'type'#10 +
    '  TSelfAr<C: TSCtl> = class(TSAProv<C>)'#10 +
    '  public'#10 +
    '    function GetName: string;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'type'#10 +
    '  TSelfAr = class(TSelfAr<TSCtl>);'#10 +   // same name, arity 0, IMPL section
    'function TSelfAr<C>.GetName: string;'#10 +
    'begin'#10 +
    '  Result := Control.Caption;'#10 +
    'end;'#10 +
    'end.'#10;

  { The same generic ancestry, reached the other way round: not `L[I]` on a
    variable from outside, but `Items[I]` INSIDE the descendant's own method,
    naming the inherited property explicitly. HTMLSubs' shape:
    `TFloatingObjList = class(TObjectList<TFloatingObj>)` doing
    `with Items[I] do if StartCurs > N then ...`.

    A different code path and a separate bug: here `Items` is a bare ident the
    INHERITED pass binds, and that pass recorded only (unit, symbol) — no
    instantiation frame. So the with pass read `Items`' declared type straight
    off TBaseList<T> and got the OPEN `T`, indexed nothing, and every name in
    the body went undeclared. The frame is unrecoverable later: nothing
    downstream knows which hop the member came from. }
  UNIT_GENSELF =
    'unit UnitGenSelf;'#10'interface'#10'uses UnitGenList;'#10 +
    'type'#10 +
    '  TAttrList2 = class(TObjList<TAttr>)'#10 +
    '    procedure Decrement(N: Integer);'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure TAttrList2.Decrement(N: Integer);'#10 +
    'var'#10 +
    '  I: Integer;'#10 +
    'begin'#10 +
    '  for I := 0 to Count - 1 do'#10 +
    '    with Items[I] do'#10 +
    '      if Which > N then'#10 +
    '        Name := ''y'';'#10 +
    'end;'#10 +
    'end.'#10;

  { The same rule where BOTH declarations come from USED units, which is where
    it actually bites: `TObjectList` is a plain class in one RTL unit and a
    generic in another, and a unit importing both got whichever it imported
    LAST. Four classes in one debug library then inherited from the wrong
    TObjectList and lost every member of the real one — including TList.Get,
    reported three hops from the mistake.

    The first fix searched the used units with the ordinary last-uses-wins
    lookup, which returns the generic again and stops; arity is part of the
    identity, so a generic candidate must not END the search. dcc-verified. }
  { A dotted `uses` registers the unit under its LAST segment, so that segment
    used BARE binds to the unit -- and in a class that also has a member of that
    name, the member must win: a bare unit name is never a value (5.7 / 12.1.1).

    `with Header.Columns, PaintInfo do` is the shape, in a unit that imports
    `Something.Header` and derives from a class with a `Header` property. The
    target's base typed as nothing, so the with scope never opened and every
    member in the body was a false E2003.

    TWO guards had to move, and finding the second one is what took the time:
    queueing the unit-ref-bound node for the inherited pass did nothing on its
    own, because the pass's namespace-token exemption (QualifierUnitAt) ran
    BEFORE the member walk and skipped the node first. A member outranks a unit
    name, so the exemption belongs after the walk, not before it. }
  UNIT_HDR =
    'unit UnitPfx.Hdr;'#10'interface'#10 +
    'type'#10 +
    '  TColumns = class'#10 +
    '  public'#10 +
    '    function NextVisible(A: Integer): Integer;'#10 +
    '  end;'#10 +
    '  THdr = class'#10 +
    '  private'#10 +
    '    FColumns: TColumns;'#10 +
    '  public'#10 +
    '    property Columns: TColumns read FColumns;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TColumns.NextVisible(A: Integer): Integer;'#10 +
    'begin'#10 +
    '  Result := A;'#10 +
    'end;'#10 +
    'end.'#10;

  UNIT_HDRBASE =
    'unit UnitHdrBase;'#10'interface'#10'uses UnitPfx.Hdr;'#10 +
    'type'#10 +
    '  TBaseTree = class'#10 +
    '  private'#10 +
    '    FHeader: THdr;'#10 +
    '  public'#10 +
    '    property Header: THdr read FHeader;'#10 +   // same name as the UNIT's
    '  end;'#10 +                                    // last segment
    'implementation'#10 +
    'end.'#10;

  UNIT_HDRUSE =
    'unit UnitHdrUse;'#10'interface'#10 +
    'uses UnitPfx.Hdr, UnitHdrBase;'#10 +
    'type'#10 +
    '  TTree = class(TBaseTree)'#10 +
    '  public'#10 +
    '    procedure Adjust;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure TTree.Adjust;'#10 +
    'var'#10 +
    '  I: Integer;'#10 +
    'begin'#10 +
    '  with Header.Columns do'#10 +
    '    I := NextVisible(0);'#10 +
    'end;'#10 +
    'end.'#10;

  { 6.4 — an overload declared ONLY in the IMPLEMENTATION section joins the
    interface section's set for the same unit. The two are separate symbols in
    separate scopes, deliberately: chaining them would export an
    implementation-only overload to every importer. So a call written inside the
    implementation resolves to the nearer (impl) head and must still be measured
    against the interface ones.

    dcc-verified. Without it the call to the INTERFACE overload looks short of
    arguments -- 4 sites in one encoding unit, all on a 3-parameter interface
    overload sitting beside a 4-parameter implementation-only one. }
  UNIT_IMPLOVL =
    'unit UnitImplOvl;'#10'interface'#10'uses UnitA;'#10 +
    'function Conv(A, B, C: Integer): Integer; overload;'#10 +
    'implementation'#10 +
    'function Conv(A, B, C, D: Integer): Integer; overload;'#10 +
    'begin'#10 +
    '  Result := A;'#10 +
    'end;'#10 +
    'function Conv(A, B, C: Integer): Integer;'#10 +
    'begin'#10 +
    '  Result := B;'#10 +
    'end;'#10 +
    'procedure Use;'#10 +
    'var'#10 +
    '  I: Integer;'#10 +
    'begin'#10 +
    '  I := Conv(1, 2, 3);'#10 +      // the INTERFACE overload
    '  I := Conv(1, 2, 3, 4);'#10 +   // the implementation-only one
    '  if I = 0 then Exit;'#10 +
    'end;'#10 +
    'end.'#10;

  UNIT_ARPLAIN =
    'unit UnitArPlain;'#10'interface'#10 +
    'type'#10 +
    '  TObjList = class'#10 +
    '  protected'#10 +
    '    function Get(Index: Integer): Pointer;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TObjList.Get(Index: Integer): Pointer;'#10 +
    'begin'#10 +
    '  Result := nil;'#10 +
    'end;'#10 +
    'end.'#10;

  UNIT_ARGEN =
    'unit UnitArGen;'#10'interface'#10 +
    'type'#10 +
    '  TObjList<T: class> = class'#10 +
    '  public'#10 +
    '    function Peek: T;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TObjList<T>.Peek: T;'#10 +
    'begin'#10 +
    '  Result := nil;'#10 +
    'end;'#10 +
    'end.'#10;

  { The MIRROR of the same rule: a reference WITH type arguments must skip an
    imported NON-generic of that name. It hides better than the bare case,
    because `Name<T>` reads as unambiguous — but the ordinary lookup still
    returns whichever declaration was imported last, and a plain class of that
    name in another unit takes a whole ancestry with it. }
  UNIT_ARGENUSE =
    'unit UnitArGenUse;'#10'interface'#10 +
    'uses UnitArGen, UnitArPlain;'#10 +   // the NON-generic imported last
    'type'#10 +
    '  TItem = class'#10 +
    '  end;'#10 +
    '  TItemList = class(TObjList<TItem>)'#10 +   // one arg -> the GENERIC
    '  public'#10 +
    '    function Top: TItem;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TItemList.Top: TItem;'#10 +
    'begin'#10 +
    '  Result := Peek;'#10 +   // declared only on the generic
    'end;'#10 +
    'end.'#10;

  UNIT_ARUSES =
    'unit UnitArUses;'#10'interface'#10 +
    'uses UnitArPlain, UnitArGen;'#10 +   // generic imported LAST
    'type'#10 +
    '  TInfo = class'#10 +
    '  end;'#10 +
    '  TInfoList = class(TObjList)'#10 +      // bare -> the NON-generic one
    '  public'#10 +
    '    function GetItems(Index: Integer): TInfo;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TInfoList.GetItems(Index: Integer): TInfo;'#10 +
    'begin'#10 +
    '  Result := TInfo(Get(Index));'#10 +
    'end;'#10 +
    'end.'#10;

  { 16.1.2 — a reference supplying NO type arguments names the ARITY-0
    declaration, even when a same-named GENERIC is nearer in scope. dcc-verified.

    A component suite's shape: `TBarAccessibilityHelper` is a plain class in one unit
    and `TBarAccessibilityHelper<T: TWinControl>` a generic in
    another, which then writes both spellings. Taking the nearer
    (generic) one is not merely imprecise: the generic's OWN heritage is that
    same bare name, so it resolves to ITSELF and the self-reference guard stops
    the ancestor walk dead — 100+ false E2003 on members declared three hops up.

    TLocal is the control: an arity-1 reference must still mean the generic, and
    the fix must not "correct" the base of `T<...>` on its way through. }
  UNIT_ARBASE =
    'unit UnitArBase;'#10'interface'#10 +
    'type'#10 +
    '  TProv = class'#10 +
    '  private'#10 +
    '    FParent: Integer;'#10 +
    '  public'#10 +
    '    property Parent: Integer read FParent;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'end.'#10;

  UNIT_ARUSE =
    'unit UnitArUse;'#10'interface'#10'uses UnitArBase;'#10 +
    'type'#10 +
    '  TProv<T: class> = class(TProv)'#10 +   // same NAME, arity 1, heritage bare
    '  private'#10 +
    '    function GetElem: T;'#10 +
    '  public'#10 +
    '    property Elem: T read GetElem;'#10 +
    '  end;'#10 +
    '  TDerived = class(TProv)'#10 +          // zero args -> UnitArBase.TProv
    '  public'#10 +
    '    function Check: Boolean;'#10 +
    '  end;'#10 +
    '  TLocal = class(TProv<TObject>)'#10 +   // one arg -> the LOCAL generic
    '  public'#10 +
    '    function Peek: TObject;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TProv<T>.GetElem: T;'#10 +
    'begin'#10 +
    '  Result := nil;'#10 +
    'end;'#10 +
    'function TDerived.Check: Boolean;'#10 +
    'begin'#10 +
    '  Result := Parent > 0;'#10 +
    'end;'#10 +
    'function TLocal.Peek: TObject;'#10 +
    'begin'#10 +
    '  Result := Elem;'#10 +
    'end;'#10 +
    'end.'#10;

  { A member whose name equals its OWN TYPE's — `property Params: Params`, the
    routine shape in imported type-library interfaces. Phase 1 resolves that
    type slot inside the struct's member scope, finds the PROPERTY, and the
    declared type comes back empty; every member reached through it is then a
    false E2003. dcc resolves the TYPE there (verified).

    The fallback belongs in the DECLARATION-SLOT path only: folding a by-name
    type lookup into general type-expression resolution answers "yes, a type"
    for a VALUE that merely shares a name with one, and that broke 238
    previously-clean units when tried. }
  UNIT_SELFTYPED =
    'unit UnitSelfTyped;'#10'interface'#10 +
    'type'#10 +
    '  IElem = interface'#10 +
    '    function GetT: Integer;'#10 +
    '    property T: Integer read GetT;'#10 +
    '  end;'#10 +
    '  Params = interface'#10 +
    '    function Get_Item(Index: Integer): IElem;'#10 +
    '    property Item[Index: Integer]: IElem read Get_Item; default;'#10 +
    '  end;'#10 +
    '  IHost = interface'#10 +
    '    function Get_Params: Params;'#10 +
    '    property Params: Params read Get_Params;'#10 +   // name = its own type
    '  end;'#10 +
    'implementation'#10 +
    'end.'#10;

  UNIT_SELFTYPEDUSE =
    'unit UnitSelfTypedUse;'#10'interface'#10'uses UnitSelfTyped;'#10 +
    'procedure Use(const H: IHost);'#10 +
    'implementation'#10 +
    'procedure Use(const H: IHost);'#10 +
    'var'#10 +
    '  V: Integer;'#10 +
    'begin'#10 +
    '  with H.Params[0] do'#10 +
    '    V := T;'#10 +
    'end;'#10 +
    'end.'#10;

  { An explicit `Self` as the with target's base. Nothing DECLARES Self (11.3.3),
    so RefMap is empty for it and the qualifier typed as nothing — losing the
    whole with scope, and with it every member in the body. Inside a method its
    type is the enclosing struct. Real shape: `with Self.TreeViewControl do`. }
  UNIT_SELFBASE =
    'unit UnitSelfBase;'#10'interface'#10 +
    'type'#10 +
    '  TImages = class'#10 +
    '  public'#10 +
    '    Width: Integer;'#10 +
    '  end;'#10 +
    '  TTree = class'#10 +
    '  private'#10 +
    '    FCheckImages: TImages;'#10 +
    '  public'#10 +
    '    property CheckImages: TImages read FCheckImages;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'end.'#10;

  UNIT_SELFUSE =
    'unit UnitSelfUse;'#10'interface'#10'uses UnitSelfBase;'#10 +
    'type'#10 +
    '  THeader = class'#10 +
    '  private'#10 +
    '    FTree: TTree;'#10 +
    '  public'#10 +
    '    property TreeViewControl: TTree read FTree;'#10 +
    '    procedure Recalc;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure THeader.Recalc;'#10 +
    'var'#10 +
    '  W: Integer;'#10 +
    'begin'#10 +
    '  with Self.TreeViewControl do'#10 +
    '    if Assigned(CheckImages) then'#10 +
    '      W := CheckImages.Width;'#10 +
    'end;'#10 +
    'end.'#10;

  { A unit-level VAR of PROCEDURAL type shadowing an imported routine of the
    same name. Only a ROUTINE can join a used unit's same-named routines in an
    overload set; anything else shadows outright, so gathering the imported
    2-parameter function and arity-checking a 3-argument call against it is
    comparing against candidates that were never in the running. dcc-verified. }
  UNIT_PROCVARBASE =
    'unit UnitProcVarBase;'#10'interface'#10 +
    'function Compare(const S1, S2: string): Integer;'#10 +
    'implementation'#10 +
    'function Compare(const S1, S2: string): Integer;'#10 +
    'begin'#10 +
    '  Result := 0;'#10 +
    'end;'#10 +
    'end.'#10;

  UNIT_PROCVARUSE =
    'unit UnitProcVarUse;'#10'interface'#10'uses UnitProcVarBase;'#10 +
    'type'#10 +
    '  TCompareFunc = function (const W1, W2: string;'#10 +
    '    Locale: Integer): Integer;'#10 +
    'var'#10 +
    '  Compare: TCompareFunc;'#10 +
    'function Use(const A, B: string): Boolean;'#10 +
    'implementation'#10 +
    'function Use(const A, B: string): Boolean;'#10 +
    'begin'#10 +
    '  Result := Compare(A, B, 1) = 0;'#10 +
    'end;'#10 +
    'end.'#10;

  { A MEMBER whose name is a compiler-seeded BUILTIN. A class with
    `property Word: string` makes bare `Word` in a descendant's method mean the
    PROPERTY, not the type — dcc-verified; an inherited member outranks a
    predefined name exactly as it outranks a unit-level one (12.1.1).

    Phase 1 cannot see it: the member is INHERITED and cross-unit, so only the
    project's later pass can reach it, and by then the intra-unit TYPER has
    already judged `ATestWord := Word` as string-vs-Word and emitted E2010. A
    later pass cannot unsay a diagnostic, so the typer withholds judgement when
    an operand resolved to a TYPE NAME — that is a mis-binding, not a type
    mismatch, and dcc has its own errors for a type used as a value. 12 false
    E2010 on one real code base, every one of them a member named Word. }
  UNIT_SHADOWBUILTIN =
    'unit UnitShadowBuiltin;'#10'interface'#10 +
    'type'#10 +
    '  TStrategy = class'#10 +
    '  private'#10 +
    '    FWord: string;'#10 +
    '  protected'#10 +
    '    property Word: string read FWord;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'end.'#10;

  UNIT_SHADOWUSE =
    'unit UnitShadowUse;'#10'interface'#10'uses UnitShadowBuiltin;'#10 +
    'type'#10 +
    '  TNearMiss = class(TStrategy)'#10 +
    '  public'#10 +
    '    procedure CheckChangeOneLetter;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure TNearMiss.CheckChangeOneLetter;'#10 +
    'var'#10 +
    '  ATestWord: string;'#10 +
    'begin'#10 +
    '  ATestWord := Word;'#10 +
    '  if ATestWord = '''' then Exit;'#10 +
    'end;'#10 +
    'end.'#10;

  { A constructor called through a CLASS REFERENCE that is a function RESULT —
    the virtual-constructor factory shape, `with GetPainterClass.Create(...) do`.
    dcc-verified. The qualifier is not a type NAME, so the with-target typer's
    constructor branch had nothing to resolve: it must type the qualifier and
    unwrap `class of T` (15.2.1) instead. Cross-unit, because the class-reference
    ALIAS is what has to be chased and a same-unit fixture hides that. }
  UNIT_CREF =
    'unit UnitCRef;'#10'interface'#10 +
    'type'#10 +
    '  TPainter = class'#10 +
    '  public'#10 +
    '    constructor Create(ATag: Integer);'#10 +
    '    procedure MainPaint;'#10 +
    '  end;'#10 +
    '  TPainterClass = class of TPainter;'#10 +
    'implementation'#10 +
    'constructor TPainter.Create(ATag: Integer); begin end;'#10 +
    'procedure TPainter.MainPaint; begin end;'#10 +
    'end.'#10;

  UNIT_CREFUSE =
    'unit UnitCRefUse;'#10'interface'#10'uses UnitCRef;'#10 +
    'type'#10 +
    '  TView = class'#10 +
    '  protected'#10 +
    '    function GetPainterClass: TPainterClass;'#10 +
    '  public'#10 +
    '    procedure Paint;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TView.GetPainterClass: TPainterClass;'#10 +
    'begin'#10 +
    '  Result := TPainter;'#10 +
    'end;'#10 +
    'procedure TView.Paint;'#10 +
    'begin'#10 +
    '  with GetPainterClass.Create(1) do'#10 +
    '    MainPaint;'#10 +
    'end;'#10 +
    'end.'#10;

  UNIT_E =
    'unit UnitE;'#10'interface'#10'implementation'#10 +
    'procedure R;'#10'var L: Integer;'#10'begin'#10 +
    '  L := SYS_CONST;'#10'end;'#10'end.'#10;

  // Cross-unit overloads: F lives in two used units with different arities.
  UNIT_OVL1 =
    'unit UnitOvl1;'#10'interface'#10 +
    'function F(A: Integer): Integer; overload;'#10'implementation'#10 +
    'function F(A: Integer): Integer; overload; begin Result := A; end;'#10 +
    'end.'#10;
  UNIT_OVL2 =
    'unit UnitOvl2;'#10'interface'#10 +
    'function F(A, B: string): string; overload;'#10'implementation'#10 +
    'function F(A, B: string): string; overload; begin Result := A; end;'#10 +
    'end.'#10;
  UNIT_OVLUSE =
    'unit UnitOvlUse;'#10'interface'#10'uses UnitOvl1, UnitOvl2;'#10 +
    'implementation'#10'procedure T;'#10'var I: Integer;'#10'begin'#10 +
    '  I := F(1);'#10 +        // fits UnitOvl1.F(Integer)
    '  F(''a'', ''b'');'#10 +  // fits UnitOvl2.F(string,string) -> no false E2034
    '  F(1, 2, 3);'#10 +       // fits neither -> E2034
    'end;'#10'end.'#10;

  // Arity candidates must respect SHADOWING: a used unit's global is NOT a
  // candidate for an unqualified call that already binds to something nearer.
  // UnitGdi plays Winapi.Windows (a 3-parameter GetObject); UnitShadow calls
  // `GetObject(I)` with ONE argument in four positions where dcc binds it
  // elsewhere -- an own method, an inherited method from a CROSS-unit
  // ancestor, a nested routine, and a procedural-type field. Real bug: the
  // RTL's own System.Classes.pas:7230 (TStrings.IndexOfObject) plus 45 more
  // across 8 units, all this one cause.
  UNIT_GDI =
    'unit UnitGdi;'#10'interface'#10 +
    'function GetObject(P1, P2, P3: Integer): Integer;'#10 +
    'procedure Fire(S: TObject);'#10'implementation'#10 +
    'function GetObject(P1, P2, P3: Integer): Integer; begin Result := 0; end;'#10 +
    'procedure Fire(S: TObject); begin end;'#10'end.'#10;

  UNIT_ANCESTOR =
    'unit UnitAncestor;'#10'interface'#10 +
    'type'#10 +
    '  TBase = class'#10 +
    '    function GetObject(Index: Integer): TObject; virtual;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TBase.GetObject(Index: Integer): TObject;'#10 +
    'begin Result := nil; end;'#10'end.'#10;

  UNIT_SHADOW =
    'unit UnitShadow;'#10'interface'#10'uses UnitGdi, UnitAncestor;'#10 +
    'type'#10 +
    '  TProc1 = procedure(S: TObject) of object;'#10 +
    '  TOwn = class'#10 +
    '    function GetObject(Index: Integer): TObject; virtual;'#10 +
    '    function Find(O: TObject): Integer;'#10 +
    '  end;'#10 +
    '  TDeriv = class(TBase)'#10 +
    '    function Find(O: TObject): Integer;'#10 +
    '  end;'#10 +
    '  THold = class'#10 +
    '    GetObject: TProc1;'#10 +
    '    procedure Go(S: TObject);'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TOwn.GetObject(Index: Integer): TObject;'#10 +
    'begin Result := nil; end;'#10 +
    // own method wins over UnitGdi.GetObject
    'function TOwn.Find(O: TObject): Integer;'#10 +
    'begin Result := 0; if GetObject(1) = O then Result := 1; end;'#10 +
    // method inherited from a CROSS-unit ancestor also wins
    'function TDeriv.Find(O: TObject): Integer;'#10 +
    'begin Result := 0; if GetObject(1) = O then Result := 1; end;'#10 +
    // a procedural-type FIELD, called through its value
    'procedure THold.Go(S: TObject);'#10 +
    'begin GetObject(S); end;'#10 +
    // a NESTED routine shadows it too
    'procedure UseNested;'#10 +
    '  function GetObject(Index: Integer): TObject;'#10 +
    '  begin Result := nil; end;'#10 +
    'begin'#10 +
    '  if GetObject(0) = nil then Exit;'#10 +
    'end;'#10 +
    // ...but a genuinely cross-unit call with the wrong arity MUST still be
    // caught. At UNIT level nothing shadows GetObject (THold's field lives in
    // the struct scope, TOwn's in its own), so this binds to UnitGdi's
    // 3-parameter global and one argument really is too few.
    'procedure Genuine;'#10 +
    'begin GetObject(1); end;'#10 +
    'end.'#10;

  // `with` over a target whose TYPE lives in ANOTHER unit (5.7). The
  // intra-unit pass opens a with scope by JOINING the type's member scope,
  // which only works same-unit — so every cross-unit case fell through to a
  // false E2003 per member (real bug: System.DateUtils.pas:2612's
  // `with LTZ.StandardDate do`, 464 diagnostics across the RTL).
  UNIT_WTYPES =
    'unit UnitWTypes;'#10'interface'#10 +
    'type'#10 +
    '  TInner = record Deep: Integer; end;'#10 +
    '  TOuter = record Nest: TInner; Top: Integer; end;'#10 +
    '  TA = record Shared: Integer; OnlyA: Integer; end;'#10 +
    '  TB = record Shared: Integer; OnlyB: Integer; end;'#10 +
    'implementation'#10'end.'#10;

  UNIT_WITH =
    'unit UnitWith;'#10'interface'#10'uses UnitWTypes;'#10 +
    'type'#10 +
    '  TCls = class'#10 +
    '    procedure M;'#10 +
    '  end;'#10 +
    'procedure Plain;'#10 +
    'implementation'#10 +
    'procedure Plain;'#10 +
    'var O: TOuter; A: TA; B: TB;'#10 +
    'begin'#10 +
    '  with A do OnlyA := 1;'#10 +               // plain var target
    '  with O.Nest do Deep := 1;'#10 +          // MEMBER target (the RTL shape)
    '  with A, B do OnlyB := OnlyA;'#10 +       // multiple targets
    '  with O do'#10 +
    '    with O.Nest do Deep := Top;'#10 +      // nested: both levels visible
    'end;'#10 +
    // inside a METHOD the with-target's own type node is itself resolved by
    // the deferred inherited pass, so this only works once the with pass runs
    // after that pass has COMMITTED.
    'procedure TCls.M;'#10 +
    'var A: TA;'#10 +
    'begin'#10 +
    '  with A do OnlyA := 1;'#10 +
    '  with A do NoSuchMember := 1;'#10 +       // genuine error, MUST still fire
    'end;'#10 +
    'end.'#10;

  // A with-target member SHADOWS everything else (5.7). dcc-verified: all five
  // bodies below compile, so `Shared` means UWRec.TRec.Shared (string) in every
  // one — never the class field, the local, the parameter, the unit global, or
  // even the inline var declared inside the body. The intra-unit pass cannot
  // know that (TRec is cross-unit, so it never opens the scope) and binds each
  // to the nearest same-unit `Shared` instead; the project's with pass has to
  // OVERRIDE those bindings, not merely fill gaps.
  UNIT_WREC =
    'unit UWRec;'#10'interface'#10 +
    'type TRec = record Shared: string; end;'#10 +
    'implementation'#10'end.'#10;

  UNIT_WSHADOW =
    'unit UWShadow;'#10'interface'#10'uses UWRec;'#10 +
    'type'#10 +
    '  TCls = class'#10 +
    '    Shared: Integer;'#10 +                     // (a) class field
    '    procedure MClass;'#10 +
    '    procedure MLocal;'#10 +
    '    procedure MParam(Shared: Integer);'#10 +   // (c) parameter
    '    procedure MInline;'#10 +
    '  end;'#10 +
    'var'#10 +
    '  Shared: Integer;'#10 +                       // (d) unit global
    'procedure MGlobal;'#10 +
    'implementation'#10 +
    'var GR: TRec;'#10 +
    'procedure TCls.MClass; begin with GR do Shared := ''x''; end;'#10 +
    'procedure TCls.MLocal;'#10 +
    'var Shared: Integer;'#10 +                     // (b) local
    'begin with GR do Shared := ''x''; end;'#10 +
    'procedure TCls.MParam(Shared: Integer);'#10 +
    'begin with GR do Shared := ''x''; end;'#10 +
    'procedure TCls.MInline;'#10 +
    'begin'#10 +
    '  with GR do'#10 +
    '  begin'#10 +
    '    var Shared: Integer;'#10 +                 // (e) inline var in the body
    '    Shared := ''x'';'#10 +
    '  end;'#10 +
    'end;'#10 +
    'procedure MGlobal; begin with GR do Shared := ''x''; end;'#10 +
    'end.'#10;

  // 1.2.4: SysInit is implicitly visible to every OTHER unit, exactly like
  // System, via EnsureSysInitUnit's own ResolveUnit('SysInit', ...) lookup --
  // never tested at all before this (mirrors UNIT_SYS/UNIT_E's proof of the
  // implicit System unit, below).
  UNIT_SYSINIT =
    'unit SysInit;'#10'interface'#10 +
    'var HInstance: Integer;'#10 +
    'implementation'#10'end.'#10;

  UNIT_SYSINIT_USE =
    'unit UnitSysInitUse;'#10'interface'#10'implementation'#10 +
    'procedure R;'#10'var L: Integer;'#10'begin'#10 +
    '  L := HInstance;'#10'end;'#10'end.'#10;

function ModelByName(const ANameLower: string): TPasSemaModel;
begin
  Result := nil;
  for var LId := 0 to GProj.ModelCount - 1 do
    if GProj.Model(LId).UnitNameLower = ANameLower then
      Exit(GProj.Model(LId));
end;

function MidByName(const ANameLower: string): Integer;
begin
  Result := -1;
  for var LId := 0 to GProj.ModelCount - 1 do
    if GProj.Model(LId).UnitNameLower = ANameLower then
      Exit(LId);
end;

// A type NAMED ANameLower, declared in AUnitLower's interface, as the
// cross-model descriptor GProj.IsManagedTypeX (20.3.1) takes.
function TypeXOf(const AUnitLower, ANameLower: string): TSemaXType;
var
  LModel: TPasSemaModel;
begin
  Result.UnitId := MidByName(AUnitLower);
  Result.Inst := NIL_INST;
  Result.Sym := NIL_SYM;
  if Result.UnitId < 0 then
    Exit;
  LModel := GProj.Model(Result.UnitId);
  Result.Sym := LModel.Resolve(LModel.InterfaceScope, ANameLower);
end;

// A reference of the given text resolved cross-unit to a symbol named ATarget.
function CrossRefTo(AModel: TPasSemaModel; const ARefText, ATarget: string):
  Boolean;
var
  LExt: TPasExtRef;
begin
  Result := False;
  for var LNode := 0 to High(AModel.RefMap) do
    if (AModel.Tree.Nodes[LNode].Kind = nkIdent) and
       SameText(AModel.Tree.NodeText(LNode), ARefText) and
       AModel.ExtRefMap.TryGetValue(LNode, LExt) then
      if SameText(GProj.Model(LExt.UnitId).Symbols[LExt.Sym].Name, ATarget) then
        Exit(True);
end;

// How many references spelled ARefText resolved to a symbol named ATarget
// declared in unit AUnitLower — via ExtRefMap (a genuinely cross-unit hit)
// OR via RefMap (a SAME-unit one: RepointCallee's own-model branch writes
// RefMap directly and needs no ExtRefMap entry at all — see its own comment
// on why a stale one there would be a bug, not a feature). Unlike CrossRefTo
// this pins the OWNING UNIT, which is the whole point when the same name
// exists on both sides of the shadowing question (a `with` target's member
// vs the enclosing class's).
function CrossRefCountInUnit(AModel: TPasSemaModel;
  const ARefText, ATarget, AUnitLower: string): Integer;
var
  LExt: TPasExtRef;
  LSym: Integer;
begin
  Result := 0;
  for var LNode := 0 to High(AModel.RefMap) do
    if (AModel.Tree.Nodes[LNode].Kind = nkIdent) and
       SameText(AModel.Tree.NodeText(LNode), ARefText) then
    begin
      if AModel.ExtRefMap.TryGetValue(LNode, LExt) then
      begin
        if SameText(GProj.Model(LExt.UnitId).Symbols[LExt.Sym].Name,
             ATarget) and
           SameText(GProj.Model(LExt.UnitId).UnitNameLower, AUnitLower) then
          Inc(Result);
      end
      else
      begin
        LSym := AModel.RefMap[LNode];
        if (LSym <> NIL_SYM) and (AModel.Symbols[LSym].DeclNode <> LNode) and
           SameText(AModel.Symbols[LSym].Name, ATarget) and
           SameText(AModel.UnitNameLower, AUnitLower) then
          Inc(Result);
      end;
    end;
end;

// References spelled ARefText still bound LOCALLY (RefMap) to a symbol that is
// not their own declaration — i.e. genuine local references left over.
function LocalRefCount(AModel: TPasSemaModel; const ARefText: string): Integer;
var
  LSym: Integer;
begin
  Result := 0;
  for var LNode := 0 to High(AModel.RefMap) do
    if (AModel.Tree.Nodes[LNode].Kind = nkIdent) and
       SameText(AModel.Tree.NodeText(LNode), ARefText) then
    begin
      LSym := AModel.RefMap[LNode];
      if (LSym <> NIL_SYM) and (AModel.Symbols[LSym].DeclNode <> LNode) then
        Inc(Result);
    end;
end;

function DiagCount(AModel: TPasSemaModel; const ACode: string): Integer;
begin
  Result := 0;
  for var LIdx := 0 to High(AModel.Diags) do
    if AModel.Diags[LIdx].Code = ACode then
      Inc(Result);
end;

// Does any ACode diagnostic in AModel mention ASubstr?
function DiagHasText(AModel: TPasSemaModel; const ACode, ASubstr: string):
  Boolean;
begin
  Result := False;
  for var LIdx := 0 to High(AModel.Diags) do
    if (AModel.Diags[LIdx].Code = ACode) and
       AModel.Diags[LIdx].Msg.Contains(ASubstr) then
      Exit(True);
end;

function SymCountOf(AModel: TPasSemaModel; const ANameLower: string;
  AKind: TSemaSymbolKind): Integer;
begin
  Result := 0;
  for var LIdx := 0 to AModel.SymCount - 1 do
    if (AModel.Symbols[LIdx].NameLower = ANameLower) and
       (AModel.Symbols[LIdx].Kind = AKind) then
      Inc(Result);
end;

function HasBodyFlag(AModel: TPasSemaModel; const ANameLower: string): Boolean;
begin
  Result := False;
  for var LIdx := 0 to AModel.SymCount - 1 do
    if (AModel.Symbols[LIdx].NameLower = ANameLower) and
       (AModel.Symbols[LIdx].Kind = skRoutine) then
      Exit(sfHasBody in AModel.Symbols[LIdx].Flags);
end;

procedure Ok(const AName: string; ACond: Boolean);
begin
  GCounter.Ok(AName, ACond);
end;

var
  LDir: string;
  LA, LB, LC, LD, LE, LOvl: TPasSemaModel;
begin
  GCounter.Init;
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_proj');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitA.pas'), UNIT_A);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitB.pas'), UNIT_B);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitC.pas'), UNIT_C);
  TFile.WriteAllText(TPath.Combine(LDir, 'System.pas'), UNIT_SYS);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitE.pas'), UNIT_E);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitD.pas'), UNIT_D);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitOvl1.pas'), UNIT_OVL1);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitOvl2.pas'), UNIT_OVL2);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitOvlUse.pas'), UNIT_OVLUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitGdi.pas'), UNIT_GDI);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitAncestor.pas'), UNIT_ANCESTOR);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitShadow.pas'), UNIT_SHADOW);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitWTypes.pas'), UNIT_WTYPES);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitWith.pas'), UNIT_WITH);
  TFile.WriteAllText(TPath.Combine(LDir, 'UWRec.pas'), UNIT_WREC);
  TFile.WriteAllText(TPath.Combine(LDir, 'UWShadow.pas'), UNIT_WSHADOW);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitTObj.pas'), UNIT_TOBJ);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitQual.pas'), UNIT_QUAL);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitNABase.pas'), UNIT_NABASE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitNAUse.pas'), UNIT_NAUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitDlg.pas'), UNIT_DLG);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitSelfTyped.pas'), UNIT_SELFTYPED);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitSelfTypedUse.pas'),
    UNIT_SELFTYPEDUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitSelfBase.pas'), UNIT_SELFBASE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitSelfUse.pas'), UNIT_SELFUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitProcVarBase.pas'),
    UNIT_PROCVARBASE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitProcVarUse.pas'), UNIT_PROCVARUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitShadowBuiltin.pas'),
    UNIT_SHADOWBUILTIN);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitShadowUse.pas'), UNIT_SHADOWUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitCRef.pas'), UNIT_CREF);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitCRefUse.pas'), UNIT_CREFUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitPfx.Hdr.pas'), UNIT_HDR);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitHdrBase.pas'), UNIT_HDRBASE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitHdrUse.pas'), UNIT_HDRUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitImplOvl.pas'), UNIT_IMPLOVL);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitArPlain.pas'), UNIT_ARPLAIN);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitArGen.pas'), UNIT_ARGEN);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitArUses.pas'), UNIT_ARUSES);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitArGenUse.pas'), UNIT_ARGENUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitArBase.pas'), UNIT_ARBASE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitArUse.pas'), UNIT_ARUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitGenList.pas'), UNIT_GENLIST);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitGenListUse.pas'), UNIT_GENLISTUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitGenSelf.pas'), UNIT_GENSELF);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitPOBase.pas'), UNIT_POBASE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitPOUse.pas'), UNIT_POUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitSABase.pas'), UNIT_SABASE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitSAUse.pas'), UNIT_SAUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitInlinePos.pas'), UNIT_INLINEPOS);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitIfaceBase.pas'), UNIT_IFACEBASE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitIfaceRoot.pas'), UNIT_IFACEROOT);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitDclBase.pas'), UNIT_DCLBASE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitDclUse.pas'), UNIT_DCLUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitNGBase.pas'), UNIT_NGBASE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitNGUse.pas'), UNIT_NGUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitWX.pas'), UNIT_WX);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitWXUse.pas'), UNIT_WXUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitNHBase.pas'), UNIT_NHBASE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitNHUse.pas'), UNIT_NHUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitWShapes.pas'), UNIT_WSHAPES);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitMRIface.pas'), UNIT_MRIFACE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitMRUse.pas'), UNIT_MRUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitMTRec.pas'), UNIT_MTREC);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitMTUse.pas'), UNIT_MTUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitNWCanvas.pas'), UNIT_NWCANVAS);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitNWBase.pas'), UNIT_NWBASE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitNWUse.pas'), UNIT_NWUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitCon.pas'), UNIT_CON);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitConUse.pas'), UNIT_CONUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitArity.pas'), UNIT_ARITY);

  // AnalyzeFile first: the single-file driver had NO suite coverage, and its
  // pass chain diverges from the parallel drivers (it calls
  // CrossResolveInherited directly, not through RunInheritedPass) — which is
  // exactly how an unsized cross-work array shipped as an AV visible only
  // from this driver (found by the 2026-08-22 Prefetch stress repro).
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    var LFMid := GProj.AnalyzeFile(TPath.Combine(LDir, 'UnitB.pas'));
    Ok('AnalyzeFile: the single-file driver runs its whole pass chain',
      LFMid >= 0);
    Ok('AnalyzeFile: cross-unit refs resolve, no internal errors',
      (LFMid >= 0) and (DiagCount(GProj.Model(LFMid), 'E2003') = 0) and
      (DiagCount(GProj.Model(LFMid), 'PPINT') = 0));
  finally
    GProj.Free;
  end;

  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.AnalyzeDirectory(LDir);
    LA := ModelByName('unita');
    LB := ModelByName('unitb');
    LC := ModelByName('unitc');
    LD := ModelByName('unitd');

    Ok('all units loaded', Assigned(LA) and Assigned(LB) and Assigned(LC) and
      Assigned(LD));

    // impl links to interface: one Foo routine, marked with a body.
    Ok('A: single Foo routine', SymCountOf(LA, 'foo', skRoutine) = 1);
    Ok('A: Foo has body linked', HasBodyFlag(LA, 'foo'));
    Ok('A: no diags', Length(LA.Diags) = 0);

    // B: cross-unit references into A.
    Ok('B: KA resolved cross-unit', CrossRefTo(LB, 'KA', 'KA'));
    Ok('B: Foo resolved cross-unit', CrossRefTo(LB, 'Foo', 'Foo'));
    Ok('B: TThing resolved cross-unit', CrossRefTo(LB, 'TThing', 'TThing'));
    Ok('B: qualified UnitA.KA (member) resolved',
      CrossRefTo(LB, 'KA', 'KA')); // KA node appears both plain and qualified
    Ok('B: uses fully resolved', LB.AllUsesResolved);
    Ok('B: no E2003', DiagCount(LB, 'E2003') = 0);

    // C: undeclared id, all uses resolved -> E2003.
    Ok('C: uses fully resolved', LC.AllUsesResolved);
    Ok('C: E2003 for Nonexistent', DiagCount(LC, 'E2003') >= 1);

    // D: an unresolvable use -> E2003 suppressed, and the missing import
    // REPORTED. Both halves matter together: suppressing E2003 without saying
    // why made a unit look checked and clean when it was neither.
    Ok('D: uses NOT fully resolved', not LD.AllUsesResolved);
    Ok('D: E2003 suppressed', DiagCount(LD, 'E2003') = 0);
    Ok('D: the missing unit is reported as F1027',
      DiagCount(LD, 'F1027') = 1);
    Ok('D: F1027 names the unit that could not be found',
      (Length(LD.Diags) = 1) and LD.Diags[0].Msg.Contains('NoSuchUnit'));
    // Units whose imports all resolve must stay silent — F1027 is not a
    // per-uses-clause remark, it fires only on an actual failure.
    Ok('B: no F1027 when every uses resolves', DiagCount(LB, 'F1027') = 0);
    // NodeSite over the very `uses` item that failed: hosts need the IMPORT
    // SITE of a unit they could not find, so a closure-health summary row can
    // be clicked through to whoever asked for the unit. `uses NoSuchUnit;` is
    // UnitD line 3, and the name starts at column 6.
    var LSFile: string;
    var LSLine, LSCol: Integer;
    Ok('NodeSite: the failed uses item has a position',
      GProj.NodeSite(MidByName('unitd'), LD.UsesList[0].NameNode,
        {out} LSFile, {out} LSLine, {out} LSCol));
    Ok('NodeSite: line/col of `uses NoSuchUnit`',
      (LSLine = 3) and (LSCol = 6));
    Ok('NodeSite: names UnitD''s own file',
      SameText(TPath.GetFileName(LSFile), 'UnitD.pas'));
    // Out-of-range is a False, never an exception — a host may hold a node id
    // from a model that has since been replaced.
    Ok('NodeSite: bad model id is False',
      not GProj.NodeSite(GProj.ModelCount, 0,
        {out} LSFile, {out} LSLine, {out} LSCol));
    Ok('NodeSite: bad node id is False',
      not GProj.NodeSite(MidByName('unitd'), MaxInt,
        {out} LSFile, {out} LSLine, {out} LSCol));

    // E: NO `uses` clause at all, references a name declared ONLY in the
    // IMPLICIT System unit (mirrors the real sLineBreak shape) -- real dcc
    // always resolves this; CrossResolve's FindInSystemUnit fallback must
    // suppress the E2003 that would otherwise fire here.
    LE := ModelByName('unite');
    Ok('E: loaded', Assigned(LE));
    Ok('E: SYS_CONST resolved via implicit System',
      CrossRefTo(LE, 'SYS_CONST', 'SYS_CONST'));
    Ok('E: no E2003 (implicit System, not a false undeclared-id)',
      DiagCount(LE, 'E2003') = 0);

    // Cross-unit overload arity: merged candidate set from UnitOvl1 + UnitOvl2.
    LOvl := ModelByName('unitovluse');
    Ok('Ovl: use unit loaded', Assigned(LOvl));
    Ok('Ovl: uses fully resolved', LOvl.AllUsesResolved);
    Ok('Ovl: E2034 x1 (F(1,2,3) fits neither)', DiagCount(LOvl, 'E2034') = 1);
    Ok('Ovl: no E2035 (merge covers F(1) and F(a,b))',
      DiagCount(LOvl, 'E2035') = 0);

    // Shadowing beats used-unit arity candidates (see UNIT_SHADOW).
    var LShadow := ModelByName('unitshadow');
    Ok('Shadow: use unit loaded', Assigned(LShadow));
    Ok('Shadow: uses fully resolved', LShadow.AllUsesResolved);
    Ok('Shadow: no E2034 at all', DiagCount(LShadow, 'E2034') = 0);
    // Exactly ONE E2035: the genuine `Fire;` (0 args, needs 1). The four
    // shadowed GetObject(1) calls must contribute none.
    Ok('Shadow: exactly 1 E2035 — the genuine cross-unit arity error only, '
      + 'none from the four shadowed GetObject calls',
      DiagCount(LShadow, 'E2035') = 1);

    // `with` over a cross-unit target type (see UNIT_WITH).
    var LWith := ModelByName('unitwith');
    Ok('With: use unit loaded', Assigned(LWith));
    Ok('With: uses fully resolved', LWith.AllUsesResolved);
    // Exactly ONE E2003: the genuine NoSuchMember. Every real member across
    // all five with-shapes (plain var, member target, multi-target, nested,
    // and inside a method) must resolve.
    Ok('With: exactly 1 E2003 — the genuine NoSuchMember only',
      DiagCount(LWith, 'E2003') = 1);
    for var LName in ['OnlyA', 'OnlyB', 'Deep', 'Top'] do
      Ok('With: ' + LName + ' resolves cross-unit',
        CrossRefTo(LWith, LName, LName));

    // A with-target member SHADOWS the class field / local / parameter /
    // unit global / inline var of the same name (see UNIT_WSHADOW). All five
    // `Shared` REFERENCES must point at UWRec's record field; none may stay
    // bound to a UWShadow symbol.
    var LWSh := ModelByName('uwshadow');
    Ok('WithShadow: unit loaded', Assigned(LWSh));
    Ok('WithShadow: no diagnostics at all', Length(LWSh.Diags) = 0);
    Ok('WithShadow: all 5 Shared refs bind to UWRec.TRec.Shared',
      CrossRefCountInUnit(LWSh, 'Shared', 'Shared', 'uwrec') = 5);
    Ok('WithShadow: no Shared reference stays bound locally',
      LocalRefCount(LWSh, 'Shared') = 0);
    // The five same-named DECLARATIONS must survive untouched — only
    // references get re-pointed.
    Ok('WithShadow: the local Shared declarations are still declared',
      SymCountOf(LWSh, 'shared', skField) = 1);

    // Module status / snapshot API: AnalyzeDirectory takes the directory's
    // own units all the way to msCrossReady, and TryGetSnapshot gates on the
    // minimum requested status (never blocks — synchronously everything is
    // already ready).
    var LSnap: TPasSemaModel;
    Ok('status: unita is msCrossReady',
      GProj.ModuleStatus(0) = msCrossReady);
    Ok('status: TryGetSnapshot(msIntfReady) succeeds',
      GProj.TryGetSnapshot(0, msIntfReady, LSnap) and (LSnap = GProj.Model(0)));
    Ok('status: TryGetSnapshot(msCrossReady) succeeds',
      GProj.TryGetSnapshot(0, msCrossReady, LSnap));
    Ok('status: out-of-range id -> msQueued, snapshot fails',
      (GProj.ModuleStatus(9999) = msQueued) and
      (not GProj.TryGetSnapshot(9999, msIntfReady, LSnap)) and
      (LSnap = nil));

    // Members of the IMPLICIT TObject ancestor, reached bare from a class
    // with no heritage clause of its own — and from one whose explicit
    // ancestor has none either. The walk used to stop where the clause is
    // absent, making every such name a false E2003 (the RTL's `ClassName`).
    var LTObj := ModelByName('unittobj');
    Ok('tobject: UnitTObj loaded', Assigned(LTObj));
    Ok('tobject: no diags at all', Length(LTObj.Diags) = 0);
    // Positive and unit-pinned: both uses of ClassName (TPlain's own, and
    // TSub's one level further down) must land on System's TObject, so this
    // cannot pass by merely staying quiet.
    Ok('tobject: both ClassName uses resolve into System''s TObject',
      CrossRefCountInUnit(LTObj, 'ClassName', 'ClassName', 'system') = 2);
    Ok('tobject: Free resolves into System''s TObject',
      CrossRefCountInUnit(LTObj, 'Free', 'Free', 'system') = 1);

    // 16.1.2 — one generic name at two arities (see UNIT_ARITY).
    var LAR := ModelByName('unitarity');
    Ok('arity: UnitArity loaded', Assigned(LAR));
    Ok('arity: no diags — and in particular no E2004 for the second TBox '
      + 'nor for the forward-completed TFwd',
      Length(LAR.Diags) = 0);
    Ok('arity: TBox is TWO distinct type symbols, not one',
      SymCountOf(LAR, 'tbox', skType) = 2);
    Ok('arity: TFwd stays ONE symbol (forward completion, not an overload)',
      SymCountOf(LAR, 'tfwd', skType) = 1);
    // Positive: each arity's OWN member must be reachable. Before, the second
    // declaration overwrote the first's member scope, so Get was orphaned.
    Ok('arity: the 1-parameter type''s member resolves (Get)',
      LocalRefCount(LAR, 'Get') >= 1);
    Ok('arity: the 2-parameter type''s member resolves (GetKey/FK)',
      (LocalRefCount(LAR, 'GetKey') >= 1) and (LocalRefCount(LAR, 'FK') >= 1));

    // 16.4.1 constraints, checked cross-model (see UNIT_CON/UNIT_CONUSE).
    var LCU := ModelByName('unitconuse');
    Ok('constraints: UnitConUse loaded', Assigned(LCU));
    Ok('constraints: exactly 4 violations, no more',
      Length(LCU.Diags) = 4);
    Ok('constraints: E2511 for a non-class under `T: class`',
      DiagCount(LCU, 'E2511') = 1);
    Ok('constraints: E2512 twice — managed string and a dynamic array',
      DiagCount(LCU, 'E2512') = 2);
    Ok('constraints: E2515 for an unrelated class under `T: TBase`',
      DiagCount(LCU, 'E2515') = 1);
    // The declaring unit itself must stay clean: a constraint is not a
    // violation of itself, and the open parameter T inside the generic's own
    // body constrains nothing.
    var LCD := ModelByName('unitcon');
    Ok('constraints: the declaring unit has no diags', Length(LCD.Diags) = 0);

    // Every with-target shape the RTL uses (see UNIT_WSHAPES). One assertion
    // per shape would be eight lookups into the same body, so the no-diags
    // check carries them collectively — with the positive checks below it
    // cannot pass by failing to resolve, since an unresolved with-body member
    // IS an E2003 here (all uses resolve, so the gate is open).
    var LWS := ModelByName('unitwshapes');
    Ok('wshapes: UnitWShapes loaded', Assigned(LWS));
    Ok('wshapes: no diags at all (8 with-target/lookup shapes)',
      Length(LWS.Diags) = 0);
    Ok('wshapes: TElem.Value bound from every with body (5 sites)',
      LocalRefCount(LWS, 'Value') + CrossRefCountInUnit(LWS, 'Value', 'Value',
        'unitwshapes') >= 4);
    // The multi-target chain specifically: `W` is reachable ONLY through
    // Outer.mid.inner / TSub(Obj).Box, so two bindings prove both later
    // targets were opened (the no-diags check above proves they are not E2003).
    Ok('wshapes: multi-target `with Outer, mid, inner` binds W',
      LocalRefCount(LWS, 'W') + CrossRefCountInUnit(LWS, 'W', 'W',
        'unitwshapes') >= 2);
    Ok('wshapes: the helper''s static reached through the type ALIAS',
      LocalRefCount(LWS, 'SetProduct') +
      CrossRefCountInUnit(LWS, 'SetProduct', 'SetProduct', 'unitwshapes') >= 1);

    // METHOD RESOLUTION CLAUSES (see UNIT_MRUSE). The interface's own method
    // name must not be looked up in the class scope, and the class method after
    // `=` must still resolve there.
    var LMR := ModelByName('unitmruse');
    Ok('method resolution: UnitMRUse loaded', Assigned(LMR));
    Ok('method resolution: no diags at all', Length(LMR.Diags) = 0);
    Ok('method resolution: the interface method is not reported undeclared',
      DiagCount(LMR, 'E2003') = 0);
    Ok('method resolution: the impl methods still resolve',
      CrossRefTo(LMR, 'ReaderLoad', 'ReaderLoad') or
      (LocalRefCount(LMR, 'ReaderLoad') > 0));
    // Same-unit interface: the segment is bindable, so it navigates.
    Ok('method resolution: a same-unit interface method binds',
      LocalRefCount(LMR, 'Store') > 0);

    // MULTI-TARGET with over a CROSS-UNIT record (see UNIT_MTUSE). Three things
    // must hold together: the later target resolves at all, the members reached
    // only through it resolve, and no pass reports the target as undeclared
    // while a later one binds it.
    var LMT := ModelByName('unitmtuse');
    Ok('multi-target xunit: UnitMTUse loaded', Assigned(LMT));
    Ok('multi-target xunit: no diags at all', Length(LMT.Diags) = 0);
    Ok('multi-target xunit: the later target `inner` itself resolved',
      CrossRefTo(LMT, 'inner', 'inner'));
    Ok('multi-target xunit: W reached through it',
      CrossRefTo(LMT, 'W', 'W'));
    // The target-expression shapes in the same unit: deref, member+index over
    // an inline-array member, and the two combined. Collectively covered by the
    // no-diags check above; asserted here so a partial regression is named.
    Ok('target shapes: Count through a deref target',
      CrossRefTo(LMT, 'Count', 'Count'));
    Ok('target shapes: H through deref+member+index',
      CrossRefTo(LMT, 'H', 'H'));
    // Indexing a POINTER to an array, `^` omitted. G is a field of the element
    // type, so it binds only if the pointer was dereferenced on the way.
    Ok('pointer index: G through `with L[1] do`',
      CrossRefTo(LMT, 'G', 'G'));
    { KNOWN GAP, deliberately not asserted: the EXPRESSION form `L[0].R` across a
      unit boundary does not bind R, because CrossType's own walk has no nkIndex
      case and so cannot type `L[0]`. Giving it one was measured (+4% wall time,
      zero diagnostic change) and reverted — see the README To-do. It costs
      typing precision, not diagnostics: the corpus shows no E2003 from this
      form, since the intra-unit typer covers the same-unit case, which is what
      Vcl.Imaging.pngimage actually uses. }

    // Indexing a class through its inherited default array property. Tag can
    // ONLY be reached that way, so binding it proves the element type came from
    // the property and not from the collection.
    Ok('default array prop: Tag through the UNNAMED index',
      CrossRefTo(LMT, 'Tag', 'Tag'));
    Ok('default array prop: the collection''s own member still resolves',
      CrossRefTo(LMT, 'Count', 'Count'));
    Ok('default array prop: a default VALUE spec is not mistaken for one',
      CrossRefTo(LMT, 'N', 'N'));
    // A constructor target must yield its CLASS. Mark is inherited, so binding
    // it proves the walk reached the class and not the (absent) result type.
    Ok('ctor target: inherited Mark through a paren-less constructor',
      CrossRefTo(LMT, 'Mark', 'Mark'));
    Ok('ctor target: Owner through a constructor WITH arguments',
      CrossRefTo(LMT, 'Owner', 'Owner'));
    // A cast to `class of T` as the with target: Registry is a class var of T,
    // reachable only if the walk hopped from the class reference to T.
    Ok('class reference: a class var through TEngineKinClass(E)',
      CrossRefTo(LMT, 'Registry', 'Registry'));
    // `with inherited Owner do` — the ancestor's member, and ClassName then comes
    // from the type it yields. Both only bind if nkInherited types at all.
    Ok('inherited target: ClassName through `with inherited Owner do`',
      CrossRefTo(LMT, 'ClassName', 'ClassName'));
    // `array of const` indexed: VType/VInteger are TVarRec fields reachable ONLY
    // through the with scope, so binding them proves the element type resolved
    // to System.TVarRec rather than to nothing.
    Ok('array of const: VType binds to System.TVarRec',
      CrossRefTo(LMT, 'VType', 'VType'));
    Ok('array of const: VInteger too',
      CrossRefTo(LMT, 'VInteger', 'VInteger'));
    // `textfile` is a seeded predefined type — no declaration to resolve to.
    Ok('predefined: textfile resolves (a var of it is not E2003)',
      DiagCount(LMT, 'E2003') = 0);
    // A bare property REDECLARATION as the with target: `property Items;` has no
    // type of its own, so Count binds only if the inherited declaration's type
    // was found. Count is also a member of the collection reached ONLY that way.
    Ok('property redeclaration: with over it opens the inherited type',
      CrossRefTo(LMT, 'Count', 'Count'));

    // NESTED with whose INNER target is an inherited cross-unit property (see
    // UNIT_NWUSE for the Vcl.ColorGrd shape this reproduces). Both halves
    // matter: Pen must resolve at all, and `Rectangle` must pick the target's
    // 4-arg METHOD rather than the 5-arg global — binding the global is how
    // the old behaviour turned a missed with-scope into a bogus E2035.
    var LNW := ModelByName('unitnwuse');
    Ok('nested-with: UnitNWUse loaded', Assigned(LNW));
    Ok('nested-with: no diags at all', Length(LNW.Diags) = 0);
    Ok('nested-with: inner target''s Pen resolved (not E2003)',
      DiagCount(LNW, 'E2003') = 0);
    Ok('nested-with: Rectangle took the 4-arg method, no bogus E2035',
      DiagCount(LNW, 'E2035') = 0);
    Ok('nested-with: Pen binds cross-unit to UnitNWCanvas',
      CrossRefTo(LNW, 'Pen', 'Pen'));
    Ok('nested-with: Left still comes from the OUTER with',
      CrossRefCountInUnit(LNW, 'Left', 'Left', 'unitnwuse') +
      LocalRefCount(LNW, 'Left') >= 2);

    // An ancestor named through its OUTER type, cross-unit (the FMX shape).
    var LNA := ModelByName('unitnause');
    Ok('nested-ancestor: UnitNAUse loaded', Assigned(LNA));
    Ok('nested-ancestor: no diags at all', Length(LNA.Diags) = 0);
    Ok('nested-ancestor: the inherited WordWrap is found through it',
      CrossRefTo(LNA, 'WordWrap', 'WordWrap'));

    // An inherited method outranks a unit-level global of the same name.
    var LDlg := ModelByName('unitdlg');
    Ok('callee-precedence: UnitDlg loaded', Assigned(LDlg));
    Ok('callee-precedence: no bogus E2035 against the 4-param global',
      DiagCount(LDlg, 'E2035') = 0);
    Ok('callee-precedence: no diags at all', Length(LDlg.Diags) = 0);
    Ok('callee-precedence: the call re-points to the inherited METHOD',
      CrossRefCountInUnit(LDlg, 'GetFileNames', 'GetFileNames',
        'unitdlg') >= 1);

    // A member whose name equals its own type's.
    var LSt := ModelByName('unitselftypeduse');
    Ok('selftyped: UnitSelfTypedUse loaded', Assigned(LSt));
    Ok('selftyped: no diags at all', Length(LSt.Diags) = 0);
    Ok('selftyped: the member types to the TYPE, not to itself',
      CrossRefTo(LSt, 'T', 'T'));

    // An explicit Self as the with target's base.
    var LSlf := ModelByName('unitselfuse');
    Ok('self-target: UnitSelfUse loaded', Assigned(LSlf));
    Ok('self-target: no diags at all', Length(LSlf.Diags) = 0);
    Ok('11.3.3: the with body opens over Self.TreeViewControl',
      CrossRefTo(LSlf, 'CheckImages', 'CheckImages'));

    // A unit-level procedural-type VAR shadowing an imported routine.
    var LPv := ModelByName('unitprocvaruse');
    Ok('procvar-shadow: UnitProcVarUse loaded', Assigned(LPv));
    Ok('procvar-shadow: no bogus arity error against the imported routine',
      (DiagCount(LPv, 'E2034') = 0) and (DiagCount(LPv, 'E2035') = 0));

    // A member named like a builtin TYPE, inherited and cross-unit.
    var LShB := ModelByName('unitshadowuse');
    Ok('shadow-builtin: UnitShadowUse loaded', Assigned(LShB));
    Ok('shadow-builtin: no bogus E2010 for a member named Word',
      DiagCount(LShB, 'E2010') = 0);
    Ok('shadow-builtin: no diags at all', Length(LShB.Diags) = 0);

    // A constructor through a class reference that is a function RESULT.
    var LCRf := ModelByName('unitcrefuse');
    Ok('classref-ctor: UnitCRefUse loaded', Assigned(LCRf));
    Ok('classref-ctor: no diags at all', Length(LCRf.Diags) = 0);
    Ok('classref-ctor: the with body opens over the REFERENCED class',
      CrossRefTo(LCRf, 'MainPaint', 'MainPaint'));

    // The MIRROR: an arity-1 reference must skip an imported NON-generic.
    var LArg := ModelByName('unitargenuse');
    Ok('arity1-uses: UnitArGenUse loaded', Assigned(LArg));
    Ok('arity1-uses: no diags at all', Length(LArg.Diags) = 0);
    Ok('arity1-uses: the arity-1 reference reaches the GENERIC import',
      CrossRefTo(LArg, 'Peek', 'Peek'));

    // An implementation-only overload joining the interface set.
    var LIo := ModelByName('unitimplovl');
    Ok('impl-overload: UnitImplOvl loaded', Assigned(LIo));
    Ok('impl-overload: neither call is reported as wrong-arity',
      (DiagCount(LIo, 'E2035') = 0) and (DiagCount(LIo, 'E2034') = 0));
    Ok('impl-overload: no diags at all', Length(LIo.Diags) = 0);

    // A member outranking a same-named UNIT reference.
    var LHdr := ModelByName('unithdruse');
    Ok('unitref-shadow: UnitHdrUse loaded', Assigned(LHdr));
    Ok('unitref-shadow: no diags at all', Length(LHdr.Diags) = 0);
    Ok('unitref-shadow: the with target opens over the inherited property',
      CrossRefTo(LHdr, 'NextVisible', 'NextVisible'));

    // Same rule, both candidates coming from USED units.
    var LAru := ModelByName('unitaruses');
    Ok('arity0-uses: UnitArUses loaded', Assigned(LAru));
    Ok('arity0-uses: no diags at all', Length(LAru.Diags) = 0);
    Ok('arity0-uses: the bare heritage skips the generic import',
      CrossRefTo(LAru, 'Get', 'Get'));

    // 16.1.2 — a bare reference means the ARITY-0 declaration, even when a
    // same-named generic is nearer in scope (a component suite's shape).
    var LAr0 := ModelByName('unitaruse');
    Ok('arity0: UnitArUse loaded', Assigned(LAr0));
    Ok('arity0: no diags at all', Length(LAr0.Diags) = 0);
    Ok('arity0: the bare heritage reaches the imported arity-0 class',
      CrossRefTo(LAr0, 'Parent', 'Parent'));
    Ok('arity0: an arity-1 reference still means the LOCAL generic',
      (LocalRefCount(LAr0, 'Elem') +
       CrossRefCountInUnit(LAr0, 'Elem', 'Elem', 'unitaruse')) >= 1);

    // A default array property inherited from a GENERIC ancestor, cross-unit.
    var LGL := ModelByName('unitgenlistuse');
    Ok('genlist: UnitGenListUse loaded', Assigned(LGL));
    Ok('genlist: no diags at all', Length(LGL.Diags) = 0);
    Ok('genlist: the with body sees the ELEMENT type, not the open parameter',
      CrossRefTo(LGL, 'Which', 'Which') and CrossRefTo(LGL, 'Name', 'Name'));

    // The same ancestry named from INSIDE the descendant: `with Items[I] do`.
    var LGS := ModelByName('unitgenself');
    Ok('genself: UnitGenSelf loaded', Assigned(LGS));
    Ok('genself: no diags at all', Length(LGS.Diags) = 0);
    Ok('genself: an inherited property carries its ancestor''s frame',
      CrossRefTo(LGS, 'Which', 'Which') and CrossRefTo(LGS, 'Name', 'Name'));

    // A bare `with F do` selects the PARAMETERLESS overload, inherited or not.
    var LPO := ModelByName('unitpouse');
    Ok('paramless: UnitPOUse loaded', Assigned(LPO));
    Ok('paramless: no diags at all', Length(LPO.Diags) = 0);
    Ok('paramless: the with target is the arity-0 overload''s result type',
      CrossRefTo(LPO, 'Left', 'Left') and CrossRefTo(LPO, 'Right', 'Right'));

    // Two arities of one name in one unit, split across its sections.
    var LSA := ModelByName('unitsause');
    Ok('selfarity: UnitSAUse loaded', Assigned(LSA));
    Ok('selfarity: no diags at all', Length(LSA.Diags) = 0);
    Ok('selfarity: an impl-section alias does not shadow its own generic',
      CrossRefTo(LSA, 'Control', 'Control'));

    // Inline var visibility is positional: the reference ABOVE the inline
    // declaration must still see the unit-level string.
    var LIP := ModelByName('unitinlinepos');
    Ok('inlinepos: UnitInlinePos loaded', Assigned(LIP));
    Ok('inlinepos: the reference above the inline decl binds the OUTER name',
      DiagCount(LIP, 'E2010') = 1);
    Ok('inlinepos: no undeclared identifiers', DiagCount(LIP, 'E2003') = 0);
    Ok('inlinepos: and no false redeclaration', DiagCount(LIP, 'E2004') = 0);

    // A heritage-less interface still reaches IInterface's own members.
    var LIR := ModelByName('unitifaceroot');
    Ok('ifaceroot: UnitIfaceRoot loaded', Assigned(LIR));
    Ok('ifaceroot: no diags at all', Length(LIR.Diags) = 0);
    Ok('ifaceroot: QueryInterface resolves through the implicit IInterface',
      CrossRefTo(LIR, 'QueryInterface', 'QueryInterface'));

    // `$IF Declared(X)` answered on the second preprocessing pass.
    var LDC := ModelByName('unitdcluse');
    Ok('declared: UnitDclUse loaded', Assigned(LDC));
    Ok('declared: a guard whose name IS declared skips its text',
      Length(LDC.Diags) = 0);
    Ok('declared: a guard whose name is NOT declared still takes its text',
      SymCountOf(LDC, 'tfallback', skType) = 1);

    // A NESTED type of a generic carries the frame it was reached through.
    var LNG := ModelByName('unitnguse');
    Ok('nestedgen: UnitNGUse loaded', Assigned(LNG));
    Ok('nestedgen: no diags at all', Length(LNG.Diags) = 0);
    // The with pass records its bindings in ExtRefMap and clears RefMap, so
    // this is a CrossRefTo even though the record is declared in this unit.
    Ok('nestedgen: indexing `List` yields the ARGUMENT, not the open parameter',
      CrossRefTo(LNG, 'Line', 'Line') and CrossRefTo(LNG, 'Ch', 'Ch'));

    // Three cross-unit with-target shapes, one Ok each — see UNIT_WXUSE for
    // which real VCL unit every one of them comes from.
    var LWX := ModelByName('unitwxuse');
    Ok('wx: UnitWXUse loaded', Assigned(LWX));
    Ok('wx: no diags at all', Length(LWX.Diags) = 0);
    Ok('wx: `with P^` over an INLINE ^T declaration opens the pointee',
      CrossRefTo(LWX, 'elpColor', 'elpColor'));
    Ok('wx: a later target that is a field wins over the same-named used unit',
      CrossRefTo(LWX, 'next_out', 'next_out'));
    Ok('wx: a cast to a cross-unit NESTED type opens it',
      CrossRefTo(LWX, 'SizeBox', 'SizeBox'));

    // A nested type inheriting from the ENCLOSING class's ancestor's nested
    // type, cross-unit (the Skia shape — see UNIT_NHUSE). Each Ok is one layer
    // of the cascade: the heritage name itself, then what only resolves once
    // the nested class HAS an ancestry.
    var LNH := ModelByName('unitnhuse');
    Ok('nested-heritage: UnitNHUse loaded', Assigned(LNH));
    Ok('nested-heritage: no diags at all', Length(LNH.Diags) = 0);
    Ok('nested-heritage: TAnimationBase binds to the enclosing class''s ' +
      'ancestor''s nested type', CrossRefTo(LNH, 'TAnimationBase',
      'TAnimationBase'));
    Ok('nested-heritage: the property specifiers see the new ancestry',
      CrossRefTo(LNH, 'GetSpan', 'GetSpan') and
      CrossRefTo(LNH, 'SetSpan', 'SetSpan'));

    // A nested type of the ANCESTOR of a MIDDLE qualifier segment.
    var LQual := ModelByName('unitqual');
    Ok('qualsegs: UnitQual loaded', Assigned(LQual));
    Ok('qualsegs: no diags at all', Length(LQual.Diags) = 0);
    Ok('qualsegs: TFlagSet/TFlags found via the middle segment''s ancestor',
      DiagCount(LQual, 'E2003') = 0);
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  { ---- The IDE's DEFAULT unit scope names (PasDefaultNamespaces) ----
    A bare .dpk/.dpr states no -NS list and dcc has none built in, so a host
    analyzing one must supply the IDE's defaults or every legacy unqualified
    import fails. The shape below is CtlPanel.pas's real one: `uses Windows,
    SysUtils, Graphics` against files that only exist fully qualified. }
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_ns');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'Winapi.Windows.pas'),
    'unit Winapi.Windows;'#10'interface'#10'const WIN_MARK = 1;'#10 +
    'implementation'#10'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'Vcl.Graphics.pas'),
    'unit Vcl.Graphics;'#10'interface'#10'const GFX_MARK = 2;'#10 +
    'implementation'#10'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'NSLegacy.pas'),
    'unit NSLegacy;'#10'interface'#10'uses Windows, Graphics;'#10 +
    'implementation'#10'end.'#10);
  // The alias defaults (dcc -A) are the sibling case: `uses WinTypes` names no
  // file at all, only the alias makes it Winapi.Windows.
  TFile.WriteAllText(TPath.Combine(LDir, 'NSAlias.pas'),
    'unit NSAlias;'#10'interface'#10'uses WinTypes, WinProcs;'#10 +
    'implementation'#10'end.'#10);
  // The Windows group must be Windows-only, and the base group everywhere.
  Ok('defaults: Win32 carries the Winapi group',
    TArray.IndexOf<string>(PasDefaultNamespaces(pfWin32), 'Winapi') >= 0);
  Ok('defaults: Linux64 does NOT carry the Winapi group',
    TArray.IndexOf<string>(PasDefaultNamespaces(pfLinux64), 'Winapi') < 0);
  Ok('defaults: System is present on every platform',
    (TArray.IndexOf<string>(PasDefaultNamespaces(pfWin32), 'System') >= 0) and
    (TArray.IndexOf<string>(PasDefaultNamespaces(pfLinux64), 'System') >= 0));
  // Windows-conditioned entries come FIRST, as the IDE writes them.
  Ok('defaults: Winapi precedes Vcl',
    TArray.IndexOf<string>(PasDefaultNamespaces(pfWin32), 'Winapi') <
    TArray.IndexOf<string>(PasDefaultNamespaces(pfWin32), 'Vcl'));
  // Aliases split the same way: Generics.* everywhere, WinTypes/Dbi* only on
  // Windows (CodeGear.Common.Targets conditions them on the Win platforms).
  var LAliasNames := '';
  for var LDef in PasDefaultUnitAliases(pfWin32) do
    LAliasNames := LAliasNames + LDef.Alias + '=' + LDef.UnitName + ';';
  Ok('alias defaults: WinTypes -> Winapi.Windows on Win32',
    LAliasNames.Contains('WinTypes=Winapi.Windows;'));
  Ok('alias defaults: Generics.Collections is fully qualified',
    LAliasNames.Contains('Generics.Collections=System.Generics.Collections;'));
  var LPosixAliases := '';
  for var LDef in PasDefaultUnitAliases(pfLinux64) do
    LPosixAliases := LPosixAliases + LDef.Alias + ';';
  Ok('alias defaults: no WinTypes/Dbi* off Windows',
    not LPosixAliases.Contains('WinTypes') and
    not LPosixAliases.Contains('Dbi'));
  Ok('alias defaults: Generics.* still there off Windows',
    LPosixAliases.Contains('Generics.Collections'));

  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    // NEGATIVE first: without the list this is two F1027s -- the state the
    // demo was actually in, so the positive below cannot pass vacuously.
    GProj.AnalyzeDirectory(LDir);
    Ok('defaults: without -NS, legacy imports FAIL',
      DiagCount(ModelByName('nslegacy'), 'F1027') = 2);
    Ok('defaults: without -A, WinTypes/WinProcs FAIL',
      DiagCount(ModelByName('nsalias'), 'F1027') = 2);
  finally
    GProj.Free;
  end;
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.SetNamespaces(PasDefaultNamespaces(pfWin32));
    for var LDef in PasDefaultUnitAliases(pfWin32) do
      GProj.AddUnitAlias(LDef.Alias, LDef.UnitName);
    GProj.AnalyzeDirectory(LDir);
    var LLeg := ModelByName('nslegacy');
    Ok('defaults: NSLegacy loaded', Assigned(LLeg));
    Ok('defaults: `uses Windows` -> Winapi.Windows, `Graphics` -> Vcl.Graphics',
      DiagCount(LLeg, 'F1027') = 0);
    Ok('defaults: and its uses closure is complete', LLeg.AllUsesResolved);
    var LAl := ModelByName('nsalias');
    Ok('defaults: `uses WinTypes, WinProcs` both alias to Winapi.Windows',
      Assigned(LAl) and (DiagCount(LAl, 'F1027') = 0) and LAl.AllUsesResolved);
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  { ReportUnresolvedMembers — the opt-in "member after a dot" diagnostic.
    Error-tolerant (OFF) is the editor's mode and the default; ON is the
    compiler-front-end one. Both directions are pinned, because the value of the
    switch is that the OFF state stays silent. }
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_members');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'MemHost.pas'),
    'unit MemHost;'#10'interface'#10 +
    'type'#10 +
    '  TThing = class'#10 +
    '    Good: Integer;'#10 +
    '  end;'#10 +
    'implementation'#10'end.'#10);
  // One good member and one that does not exist, on a type from ANOTHER unit —
  // the cross-unit path, which is where the check lives.
  TFile.WriteAllText(TPath.Combine(LDir, 'MemUser.pas'),
    'unit MemUser;'#10'interface'#10'uses MemHost;'#10 +
    'procedure P;'#10 +
    'implementation'#10 +
    'procedure P;'#10 +
    'var LT: TThing;'#10 +
    'begin'#10 +
    '  LT.Good := 1;'#10 +
    '  LT.Nope := 2;'#10 +
    'end;'#10 +
    'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.AnalyzeDirectory(LDir);
    Ok('members: OFF by default, so an unresolved member is silent',
      DiagCount(ModelByName('memuser'), 'E2003') = 0);
  finally
    GProj.Free;
  end;
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.ReportUnresolvedMembers := True;
    GProj.AnalyzeDirectory(LDir);
    Ok('members: ON reports it once, and only the bad one',
      DiagCount(ModelByName('memuser'), 'E2003') = 1);
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  { A compiler-SEEDED name shadowed by an INHERITED member. dcc-probed both
    ways: a class with a `Text` property compiles `Text.IsEmpty` in a method
    body — the member beats the predefined FILE type — and `var F: Text;` in
    that same body is `E2007`, so the member wins in a type position too.

    This is a WRONG binding rather than a missing one, so the assertion that
    matters is where `Text` POINTS, not the diagnostic count: with the seed
    winning, `Text` still "resolved" and only the member after the dot failed.
    The control is a seeded name with no member of that name in sight, which
    must still bind to the seed. }
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_seedshadow');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  // TObject: real (PasTree.Sema.Builtins no longer seeds it) -- named
  // System.pas, not just any fixture unit, so SSBase/SSUse reach it through
  // the IMPLICIT unit exactly as real code does, with no `uses` clause of
  // their own to change (same convention as the file-level UNIT_SYS).
  TFile.WriteAllText(TPath.Combine(LDir, 'System.pas'),
    'unit System;'#10'interface'#10 +
    'type'#10 +
    '  TObject = class'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'SSBase.pas'),
    'unit SSBase;'#10'interface'#10 +
    'type'#10 +
    '  TBase = class'#10 +
    '  private'#10 +
    '    FText: TObject;'#10 +
    '  public'#10 +
    '    property Text: TObject read FText;'#10 +   // shadows the FILE seed
    '  end;'#10 +
    'implementation'#10 +
    'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'SSUse.pas'),
    'unit SSUse;'#10'interface'#10'uses SSBase;'#10 +
    'type'#10 +
    '  TDesc = class(TBase)'#10 +
    '    function Use: TObject;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TDesc.Use: TObject;'#10 +
    'var'#10 +
    '  LI: Integer;'#10 +                           // a seed with no rival
    'begin'#10 +
    '  LI := 0;'#10 +
    '  Result := Text;'#10 +
    '  if LI = 0 then Result := nil;'#10 +
    'end;'#10 +
    'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.ReportUnresolvedMembers := True;
    GProj.AnalyzeDirectory(LDir);
    var LSS := ModelByName('ssuse');
    Ok('seedshadow: SSUse loaded', Assigned(LSS));
    Ok('seedshadow: the inherited property beats the predefined `Text`',
      CrossRefTo(LSS, 'Text', 'Text'));
    Ok('seedshadow: a seed with no member of that name is left alone',
      LocalRefCount(LSS, 'Integer') = 1);
    Ok('seedshadow: and nothing new is reported', DiagCount(LSS, 'E2003') = 0);
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  { The two shapes the RTL's `Create`/`Free` tail turned out to be, both
    dcc32 37.0-probed and both stated by the probe rather than by the spec:

    - `T: class` guarantees TObject's members (`V.Free`, `V.ClassName` compile);
      `T: record` and a lone `T: constructor` do NOT — the same `V.Free` is
      `E2003` under either, so only the `class` keyword answers a type here;
    - a DYNAMIC array type has a pseudo-constructor (`TBytes.Create($20, $20)`,
      also with no arguments at all). A STATIC array and a VARIABLE qualifier
      are both `E2671`, which is why the negative cases are asserted too — and
      `TBytes` (a real declaration in CFSys now — PasTree.Sema.Builtins no
      longer seeds it) is exercised beside a locally-declared array, to prove
      the pseudo-constructor walk does not care which kind of DeclNode a
      dynamic array type has.

    The negatives are silence, so each is paired with a live report in the same
    unit: without one, a rule that suppressed everything would pass. }
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_ctorfree');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  // TObject in a fixture unit, for the reason UnitIfaceBase gives: this suite
  // analyses a temp directory whose only search path is itself, and the hop
  // goes through ResolveRealDecl, which searches USED units — never this one.
  TFile.WriteAllText(TPath.Combine(LDir, 'CFSys.pas'),
    'unit CFSys;'#10'interface'#10 +
    'type'#10 +
    '  TObject = class'#10 +
    '    procedure Free;'#10 +
    '  end;'#10 +
    // TBytes: real (PasTree.Sema.Builtins no longer seeds it) -- see the
    // header comment on why this fixture exercises it beside TMyArr.
    '  TBytes = array of Byte;'#10 +
    'implementation'#10 +
    'procedure TObject.Free;'#10 +
    'begin'#10 +
    'end;'#10 +
    'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'CFUse.pas'),
    'unit CFUse;'#10'interface'#10'uses CFSys;'#10 +
    'type'#10 +
    '  TMyArr = array of Byte;'#10 +
    '  TStat = array[0..1] of Byte;'#10 +
    '  TClassOnly<T: class> = class'#10 +
    '    procedure Use(const V: T);'#10 +
    '  end;'#10 +
    '  TRecOnly<T: record> = class'#10 +
    '    procedure Use(const V: T);'#10 +
    '  end;'#10 +
    'procedure P;'#10 +
    'implementation'#10 +
    'procedure TClassOnly<T>.Use(const V: T);'#10 +
    'begin'#10 +
    '  V.Free;'#10 +                     // TObject through `class`
    'end;'#10 +
    'procedure TRecOnly<T>.Use(const V: T);'#10 +
    'begin'#10 +
    '  V.Free;'#10 +                     // dcc: E2003 — and so do we
    'end;'#10 +
    'procedure P;'#10 +
    'var'#10 +
    '  LA: TMyArr;'#10 +
    '  LB: TBytes;'#10 +
    '  LS: TStat;'#10 +
    'begin'#10 +
    '  LA := TMyArr.Create(1, 2);'#10 +  // a declared dynamic array
    '  LB := TBytes.Create(1);'#10 +     // the SEEDED one
    '  LA := TMyArr.Create();'#10 +      // no arguments
    '  LS := TStat.Create(1, 2);'#10 +   // dcc: E2671 — we report the member
    '  LA := LA.Create(1);'#10 +         // a VARIABLE qualifier, likewise
    'end;'#10 +
    'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.ReportUnresolvedMembers := True;
    GProj.AnalyzeDirectory(LDir);
    var LCF := ModelByName('cfuse');
    Ok('ctorfree: CFUse loaded', Assigned(LCF));
    // Three left: the record-constrained Free and the two illegal Creates.
    Ok('ctorfree: `class` answers TObject and the other kinds do not',
      DiagCount(LCF, 'E2003') = 3);
    Ok('ctorfree: the surviving report is the record-constrained Free',
      DiagHasText(LCF, 'E2003', 'Free'));
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  { A constrained parameter used inside a method BODY. 16 §16.4.1 puts the
    constraints on the declaration and dcc forbids repeating them on the
    implementation header — `procedure TListBase<T>.Add;` — so the body's own
    `<T>` carries none, and that is where nearly every use of a constrained
    parameter lives (the whole `TAcceptValueListBase<T: TAcceptValueItem,
    constructor>` family in System.Net.Mime was this one shape).

    The constraint group is asserted too: a `constructor` constraint beside the
    type one must not hide the type. }
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_bodycon');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'BCItem.pas'),
    'unit BCItem;'#10'interface'#10 +
    'type'#10 +
    '  TItem = class'#10 +
    '    FWeight: Integer;'#10 +
    '    procedure Parse;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure TItem.Parse;'#10 +
    'begin'#10 +
    'end;'#10 +
    'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'BCList.pas'),
    'unit BCList;'#10'interface'#10'uses BCItem;'#10 +
    'type'#10 +
    '  TList<T: TItem, constructor> = class'#10 +
    '    procedure Use(const A: T);'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure TList<T>.Use(const A: T);'#10 +   // no constraints here, ever
    'begin'#10 +
    '  A.FWeight := 1;'#10 +
    '  A.Parse;'#10 +
    'end;'#10 +
    'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.ReportUnresolvedMembers := True;
    GProj.AnalyzeDirectory(LDir);
    var LBC := ModelByName('bclist');
    Ok('bodycon: BCList loaded', Assigned(LBC));
    Ok('bodycon: a body''s parameter reaches the DECLARATION''s constraint',
      DiagCount(LBC, 'E2003') = 0);
    Ok('bodycon: field and method both bind to the constraint type',
      CrossRefTo(LBC, 'FWeight', 'FWeight') and CrossRefTo(LBC, 'Parse', 'Parse'));
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  { The four shapes FMX's member tail turned out to be, all in one fixture
    because all four are about a name whose meaning the QUALIFIER decides:

    - a NESTED type as a type ARGUMENT (`TMsg<TModel.TInfo>`). Nothing binds
      that last segment cross-unit this early, and losing one argument loses
      the whole instantiation FRAME — with it every member of a field typed by
      the parameter. 82 of the FMX package's 89 reports were
      `Message.Value.<anything>` through exactly this.
    - a NESTED type as a member QUALIFIER (`TModel.TItems.Create(1, 2)`, where
      `TItems = TArray<Integer>`). A dotted name binds on its last segment, so
      the "is this a type?" test read nothing and the dynamic-array
      pseudo-constructor did not apply.
    - the RE-EXPORT idiom, `X = X` inside a class: the right side means the
      OUTER X, since a declaration cannot alias itself. dcc-probed. Bound to
      itself, the alias is a type whose definition is itself, and its members
      are therefore nothing.
    - a member NAME that collides with a compiler SEED (`Model.Text`, where
      `Text` is the predefined FILE type). A seed is never anyone's member, so
      a binding that says otherwise is to be corrected rather than trusted. }
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_qualified');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'QHost.pas'),
    'unit QHost;'#10'interface'#10 +
    'type'#10 +
    // TArray: real (PasTree.Sema.Builtins no longer seeds it) -- this suite
    // analyses a bare temp directory, so it needs declaring here.
    '  TArray<T> = array of T;'#10 +
    '  TMode = (None, AllLocal);'#10 +
    '  TModel = class'#10 +
    '  public type'#10 +
    '    TInfo = record'#10 +
    '      Index: Integer;'#10 +
    '    end;'#10 +
    '    TItems = TArray<Integer>;'#10 +
    '    TMode = TMode;'#10 +          // the re-export idiom
    '  public'#10 +
    '    Text: string;'#10 +           // collides with the seeded FILE type
    '  end;'#10 +
    '  TMsg<T> = record'#10 +
    '    Value: T;'#10 +
    '  end;'#10 +
    // The suite analyses a bare temp directory, so System.SysUtils is not
    // there and TStringHelper with it: the string helper the last assertion
    // needs has to be declared here, or `IsEmpty` would have nowhere to
    // resolve for a reason that has nothing to do with the rule.
    '  TStrHelp = record helper for string'#10 +
    '    function IsEmpty: Boolean;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TStrHelp.IsEmpty: Boolean;'#10 +
    'begin Result := Self = ''''; end;'#10 +
    'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'QUse.pas'),
    'unit QUse;'#10'interface'#10'uses QHost;'#10 +
    'procedure P(var M: TMsg<TModel.TInfo>; const AModel: TModel);'#10 +
    'implementation'#10 +
    'procedure P(var M: TMsg<TModel.TInfo>; const AModel: TModel);'#10 +
    'var'#10 +
    '  LItems: TModel.TItems;'#10 +
    '  LMode: TModel.TMode;'#10 +
    'begin'#10 +
    '  M.Value.Index := 1;'#10 +               // through the instantiation frame
    '  LItems := TModel.TItems.Create(1, 2);'#10 +  // dyn-array pseudo-ctor
    '  LMode := TModel.TMode.AllLocal;'#10 +   // the re-exported enum's value
    '  if AModel.Text.IsEmpty then'#10 +       // the seed-named member's helper
    '    Exit;'#10 +
    '  if Length(LItems) = 0 then Exit;'#10 +
    'end;'#10 +
    'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.ReportUnresolvedMembers := True;
    GProj.AnalyzeDirectory(LDir);
    var LQ := ModelByName('quse');
    Ok('qualified: QUse loaded', Assigned(LQ));
    Ok('qualified: all four qualifier shapes resolve',
      DiagCount(LQ, 'E2003') = 0);
    Ok('qualified: the frame reaches the nested type''s own member',
      CrossRefTo(LQ, 'Index', 'Index'));
    Ok('qualified: the re-exported alias yields the OUTER enum''s value',
      CrossRefTo(LQ, 'AllLocal', 'AllLocal'));
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  { A PARAMETERLESS function reference is CALLED when its name is written, so
    `.Member` after it belongs to the RESULT: `ValueFunc.GetValue` where
    `ValueFunc: TFunc<IValue>` means `ValueFunc().GetValue`
    (System.Bindings.Outputs, and the whole VCL package's member tail).

    The generic is the point rather than decoration — `TFunc<TResult> =
    reference to function: TResult` declares its result as a type PARAMETER, so
    only the instantiation makes it IValue, and a hop that forgot the frame
    would land on the open TResult and find nothing.

    Both negatives are asserted beside it, since they are what keeps the hop
    from inventing members: a proc type that takes PARAMETERS cannot be called
    by writing its name, and a `procedure` type has no result at all. }
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_procres');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'PRHost.pas'),
    'unit PRHost;'#10'interface'#10 +
    'type'#10 +
    '  IValue = interface'#10 +
    '    function GetValue: Integer;'#10 +
    '  end;'#10 +
    '  TFunc<TResult> = reference to function: TResult;'#10 +
    '  TTakesArg = reference to function(A: Integer): IValue;'#10 +
    '  TPlainProc = procedure of object;'#10 +
    'implementation'#10'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'PRUse.pas'),
    'unit PRUse;'#10'interface'#10'uses PRHost;'#10 +
    'procedure P(const AFunc: TFunc<IValue>; const AArg: TTakesArg;'#10 +
    '  const AProc: TPlainProc);'#10 +
    'implementation'#10 +
    'procedure P(const AFunc: TFunc<IValue>; const AArg: TTakesArg;'#10 +
    '  const AProc: TPlainProc);'#10 +
    'var'#10 +
    '  LI: Integer;'#10 +
    'begin'#10 +
    '  LI := AFunc.GetValue;'#10 +      // the implicit call, then IValue's member
    '  LI := AArg.GetValue;'#10 +       // takes a parameter: not callable so
    '  LI := AProc.GetValue;'#10 +      // no result at all
    '  if LI = 0 then Exit;'#10 +
    'end;'#10 +
    'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.ReportUnresolvedMembers := True;
    GProj.AnalyzeDirectory(LDir);
    var LPR := ModelByName('pruse');
    Ok('procres: a parameterless function reference yields its RESULT''s members',
      CrossRefTo(LPR, 'GetValue', 'GetValue'));
    Ok('procres: ...and the two shapes that cannot be called still report',
      DiagCount(LPR, 'E2003') = 2);
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  { Builtin ALIAS identity, and the distinct type that must not be caught by it.
    dcc32 37.0-probed: a `record helper for Cardinal` applies to values declared
    `Cardinal`, `LongWord` and `UInt32` (System.pas: `UInt32 = Cardinal`) alike,
    and is `E2671` on an `Integer` — identity, not compatibility. But
    `TEditMask = type string` (System.MaskUtils) declares a DISTINCT type, so
    ITS helper is not a string helper: registering it as one hid TStringHelper
    in FMX.MaskEdit and cost 17 false reports in the measurement that caught it.

    The negative is the whole point here, so it is asserted as a live binding
    rather than as silence. }
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_alias');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'ALHelp.pas'),
    'unit ALHelp;'#10'interface'#10 +
    'type'#10 +
    '  TMyStr = type string;'#10 +          // DISTINCT: not string
    '  TCardHelp = record helper for Cardinal'#10 +
    '    function Twice: Cardinal;'#10 +
    '  end;'#10 +
    '  TStrHelp = record helper for string'#10 +
    '    function Doubled: string;'#10 +
    '  end;'#10 +
    '  TMyStrHelp = record helper for TMyStr'#10 +
    '    function Mine: string;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TCardHelp.Twice: Cardinal;'#10'begin Result := Self; end;'#10 +
    'function TStrHelp.Doubled: string;'#10'begin Result := Self; end;'#10 +
    'function TMyStrHelp.Mine: string;'#10'begin Result := ''''; end;'#10 +
    'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'ALUse.pas'),
    'unit ALUse;'#10'interface'#10'uses ALHelp;'#10 +
    'procedure P;'#10 +
    'implementation'#10 +
    'procedure P;'#10 +
    'var'#10 +
    '  LW: LongWord;'#10 +
    '  LS: string;'#10 +
    'begin'#10 +
    '  LW := LW.Twice;'#10 +            // Cardinal helper on a LongWord value
    '  LS := LS.Doubled;'#10 +          // the string helper must still apply
    'end;'#10 +
    'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.ReportUnresolvedMembers := True;
    GProj.AnalyzeDirectory(LDir);
    var LAL := ModelByName('aluse');
    Ok('alias: a builtin helper answers for every name of the same type',
      DiagCount(LAL, 'E2003') = 0);
    Ok('alias: ...and the `type string` helper did NOT claim string',
      CrossRefTo(LAL, 'Doubled', 'Doubled'));
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  { 16.2.1: a generic METHOD's constraints live on its own declaration, and the
    body repeats a bare `<T>` — the same rule as a generic TYPE's, one level in.
    System.Rtti's `GetNamedObject<T: TRttiNamedObject>` is the shape; its body
    calls `Obj.HasName`, the last two member reports the RTL package had.

    The qualified implementation name is a FLAT run of idents, each able to
    carry its own parameter list, so the owner of a list is the ident right
    BEFORE it — the first segment would answer with the class's name. }
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_genmethod');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'GMHost.pas'),
    'unit GMHost;'#10'interface'#10 +
    'type'#10 +
    '  TNamed = class'#10 +
    '    function HasName(const A: string): Boolean;'#10 +
    '  end;'#10 +
    '  TFinder = class'#10 +
    '    function Pick<T: TNamed>(const A: string): T;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TNamed.HasName(const A: string): Boolean;'#10 +
    'begin Result := A = ''''; end;'#10 +
    'function TFinder.Pick<T>(const A: string): T;'#10 +
    'var'#10 +
    '  Obj: T;'#10 +
    'begin'#10 +
    '  Obj := nil;'#10 +
    '  if Obj.HasName(A) then'#10 +
    '    Exit(Obj);'#10 +
    '  Result := nil;'#10 +
    'end;'#10 +
    'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.ReportUnresolvedMembers := True;
    GProj.AnalyzeDirectory(LDir);
    Ok('genmethod: a generic METHOD''s body reaches its own constraint',
      DiagCount(ModelByName('gmhost'), 'E2003') = 0);
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  { A helper on a BUILTIN-typed value whose type came from ANOTHER model. Every
    model seeds its own `string` symbol, so `S.Trim` on a local (this model's
    seed) and `Give(S).Trim` on a third unit's function result (that unit's
    seed) are different keys into the helper index — and only the first was
    registered. Three units because two cannot tell the two keys apart: the
    helper and the function have to live in DIFFERENT units, neither of them the
    referring one. The local is asserted beside it so a fix that canonicalized
    everything to nothing would still fail. }
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_bihelp');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'BHHelp.pas'),
    'unit BHHelp;'#10'interface'#10 +
    'type'#10 +
    '  TStrHelp = record helper for string'#10 +
    '    function Trimmed: string;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TStrHelp.Trimmed: string;'#10 +
    'begin'#10 +
    '  Result := Self;'#10 +
    'end;'#10 +
    'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'BHMaker.pas'),
    'unit BHMaker;'#10'interface'#10 +
    'function Give(const A: string): string;'#10 +
    'implementation'#10 +
    'function Give(const A: string): string;'#10 +
    'begin'#10 +
    '  Result := A;'#10 +
    'end;'#10 +
    'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'BHUse.pas'),
    'unit BHUse;'#10'interface'#10'uses BHHelp, BHMaker;'#10 +
    'procedure P;'#10 +
    'implementation'#10 +
    'procedure P;'#10 +
    'var LS: string;'#10 +
    'begin'#10 +
    '  LS := LS.Trimmed;'#10 +          // this model's own seed
    '  LS := Give(LS).Trimmed;'#10 +    // BHMaker's seed
    'end;'#10 +
    'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.ReportUnresolvedMembers := True;
    GProj.AnalyzeDirectory(LDir);
    var LBH := ModelByName('bhuse');
    Ok('bihelp: BHUse loaded', Assigned(LBH));
    Ok('7.4.1: a string intrinsic-helper method answers for a builtin ' +
      'type seeded in ANOTHER model', DiagCount(LBH, 'E2003') = 0);
    Ok('7.4.1: both call sites bind to the helper member',
      CrossRefCountInUnit(LBH, 'Trimmed', 'Trimmed', 'bhhelp') = 2);
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  { A member reached through a GENERIC ANCESTOR and typed by that ancestor's own
    parameter — `class property Statics: S` on `TGenericImport<S>`, which is the
    WinRT shape (`TWinRTGenericImportS<S: IInspectable>` in System.Win.WinRT,
    used by every `Statics.CreateInstance` in the Winapi.* units).

    Bare `Statics` is found by the inherited pass, which closes its type over the
    instantiation frame; the next dot has to READ that answer instead of the open
    `S`. Run with the member check ON, since a member miss is otherwise silent —
    the binding assertion is the real subject and the diagnostic count is what
    makes a regression loud. Cross-unit on purpose: that is the failing shape,
    and it is the ancestor's frame rather than this unit's that matters. }
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_genanc');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'GABase.pas'),
    'unit GABase;'#10'interface'#10 +
    'type'#10 +
    '  IThing = interface'#10 +
    '    procedure Go;'#10 +
    '  end;'#10 +
    '  TImportBase = class'#10 +
    '  end;'#10 +
    '  TGenericImport<S: IThing> = class(TImportBase)'#10 +
    '    class function GetStatics: S; static;'#10 +
    '    class property Statics: S read GetStatics;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'class function TGenericImport<S>.GetStatics: S;'#10 +
    'begin'#10 +
    '  Result := nil;'#10 +
    'end;'#10 +
    'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'GAUse.pas'),
    'unit GAUse;'#10'interface'#10'uses GABase;'#10 +
    'type'#10 +
    '  IController = interface(IThing)'#10 +
    '    function GetDefault: Integer;'#10 +
    '  end;'#10 +
    '  TController = class(TGenericImport<IController>)'#10 +
    '    class function Make: Integer;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'class function TController.Make: Integer;'#10 +
    'begin'#10 +
    '  Result := Statics.GetDefault;'#10 +
    'end;'#10 +
    'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.ReportUnresolvedMembers := True;
    GProj.AnalyzeDirectory(LDir);
    var LGA := ModelByName('gause');
    Ok('genanc: GAUse loaded', Assigned(LGA));
    Ok('genanc: a member of the ancestor''s parameter-typed property resolves',
      DiagCount(LGA, 'E2003') = 0);
    Ok('genanc: the property itself comes from the generic ancestor',
      CrossRefTo(LGA, 'Statics', 'Statics'));
    // The member is declared in THIS unit (IController is), so the binding the
    // instantiation argument earns is a LOCAL one — which is exactly the point:
    // the open `S` could never have led here.
    Ok('genanc: and its member binds through the instantiation argument',
      LocalRefCount(LGA, 'GetDefault') = 1);
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  { ReportVisibility — the enforcement half of 11.2.1, also opt-in. Every rule
    below is dcc32 37.0-probed, and the SILENT ones carry the weight: `private`
    is visible to the whole declaring UNIT (the friend rule), so enforcing it
    per-type would reject correct code everywhere. }
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_vis');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'VisHost.pas'),
    'unit VisHost;'#10'interface'#10 +
    'type'#10 +
    '  TThing = class'#10 +
    '  private'#10 +
    '    FPriv: Integer;'#10 +
    '  strict private'#10 +
    '    FStrict: Integer;'#10 +
    '  public'#10 +
    '    FPub: Integer;'#10 +
    '    procedure Own;'#10 +
    '  end;'#10 +
    '  TFriend = class'#10 +
    '    procedure Touch(A: TThing);'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure TThing.Own;'#10 +
    'begin'#10 +
    '  Self.FStrict := 1;'#10 +      // its own strict private: legal
    'end;'#10 +
    'procedure TFriend.Touch(A: TThing);'#10 +
    'begin'#10 +
    '  A.FPriv := 1;'#10 +           // same unit: the friend rule, legal
    '  A.FPub := 2;'#10 +
    '  A.FStrict := 3;'#10 +         // strict: an error even here
    'end;'#10 +
    'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'VisUser.pas'),
    'unit VisUser;'#10'interface'#10'uses VisHost;'#10 +
    'type'#10 +
    '  TOutside = class'#10 +
    '    procedure Touch(A: TThing);'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure TOutside.Touch(A: TThing);'#10 +
    'begin'#10 +
    '  A.FPriv := 1;'#10 +           // another unit: an error
    '  A.FStrict := 2;'#10 +         // likewise
    '  A.FPub := 3;'#10 +
    'end;'#10 +
    'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.AnalyzeDirectory(LDir);
    Ok('visibility: OFF by default, so nothing is refused',
      (DiagCount(ModelByName('vishost'), 'E2361') = 0) and
      (DiagCount(ModelByName('visuser'), 'E2361') = 0));
  finally
    GProj.Free;
  end;
  // The overload shape that made this check unusable: a PRIVATE member sharing
  // its name with the PUBLIC one people call. `Exception` does exactly this — a
  // private `class constructor Create` above the public `constructor
  // Create(const Msg: string)` — and binding used to answer with the chain head,
  // so every `Create('x')` was refused. The call's selected target is what must
  // be judged.
  TFile.WriteAllText(TPath.Combine(LDir, 'VisOver.pas'),
    'unit VisOver;'#10'interface'#10 +
    'type'#10 +
    '  TThing2 = class'#10 +
    '  private'#10 +
    '    class constructor Create;'#10 +
    '  public'#10 +
    '    constructor Create(AValue: Integer); overload;'#10 +
    '    procedure Go;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'class constructor TThing2.Create;'#10 +
    'begin'#10 +
    'end;'#10 +
    'constructor TThing2.Create(AValue: Integer);'#10 +
    'begin'#10 +
    'end;'#10 +
    'procedure TThing2.Go;'#10 +
    'begin'#10 +
    'end;'#10 +
    'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'VisOverUse.pas'),
    'unit VisOverUse;'#10'interface'#10'uses VisOver;'#10 +
    'procedure P;'#10 +
    'implementation'#10 +
    'procedure P;'#10 +
    'begin'#10 +
    '  TThing2.Create(7).Go;'#10 +   // the PUBLIC overload, by argument count
    'end;'#10 +
    'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.ReportVisibility := True;
    GProj.AnalyzeDirectory(LDir);
    Ok('visibility: judged on the SELECTED overload, not the chain head',
      DiagCount(ModelByName('visoveruse'), 'E2361') = 0);
    // Same unit: only the STRICT one is refused — the friend rule keeps
    // `A.FPriv` legal, and a type's own strict member stays reachable.
    Ok('visibility: strict private is refused even in the declaring unit',
      DiagCount(ModelByName('vishost'), 'E2361') = 1);
    Ok('visibility: ...and names the member the way dcc does',
      DiagHasText(ModelByName('vishost'), 'E2361', 'TThing.FStrict'));
    // Another unit: both private forms are refused, the public one is not.
    Ok('visibility: across units private and strict private both go',
      DiagCount(ModelByName('visuser'), 'E2361') = 2);
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  { The three rules the `-visibility` tail turned out to need, all dcc32
    37.0-probed and all of them BINDING rules rather than visibility ones —
    which is what the flag has said about every one of its floods so far:

    - `strict private` reaches a NESTED type, and the relation is asymmetric.
      A nested class reading the OUTER class's strict private field compiles;
      the outer class reading a NESTED class's is dcc's own `E2361`.
      (`TJSONCollectionBuilder.TBaseCollection` reads the outer `FJSONWriter`.)
    - a `class constructor` is never what a name means — it runs once,
      automatically, and cannot be called (15 §15.1.5). `TRegistry` declares a
      private one fourteen lines above the public parameterless `Create`.
    - when NOTHING in a type's own chain fits the arguments, the call means an
      INHERITED routine: `TButton.Create(Self)` is TComponent's.

    Every assertion here is a count on a unit that also contains a live report,
    so a rule that simply stopped reporting could not pass. }
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_vistail');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'VTHost.pas'),
    'unit VTHost;'#10'interface'#10 +
    'type'#10 +
    '  TOuter = class'#10 +
    '  strict private'#10 +
    '    FVal: Integer;'#10 +
    '  public type'#10 +
    '    TInner = class'#10 +
    '    strict private'#10 +
    '      FIn: Integer;'#10 +
    '    public'#10 +
    '      procedure Poke(const A: TOuter);'#10 +
    '    end;'#10 +
    '  public'#10 +
    '    procedure Reach(const A: TInner);'#10 +
    '  end;'#10 +
    '  TReg = class'#10 +
    '  private'#10 +
    '    class constructor Create;'#10 +      // never callable (15.1.5)
    '  public'#10 +
    '    constructor Create; overload;'#10 +
    '    constructor Create(A: Integer); overload;'#10 +
    '  end;'#10 +
    '  TBase = class'#10 +
    '    constructor Create(A: Integer);'#10 +
    '  end;'#10 +
    '  TDesc = class(TBase)'#10 +
    '  private'#10 +
    '    class constructor Create;'#10 +      // hides nothing: not callable
    '  end;'#10 +
    'implementation'#10 +
    'procedure TOuter.TInner.Poke(const A: TOuter);'#10 +
    'begin'#10 +
    '  A.FVal := 1;'#10 +                     // nested -> outer strict: legal
    'end;'#10 +
    'procedure TOuter.Reach(const A: TInner);'#10 +
    'begin'#10 +
    '  A.FIn := 1;'#10 +                      // outer -> nested strict: E2361
    'end;'#10 +
    'class constructor TReg.Create;'#10'begin end;'#10 +
    'constructor TReg.Create;'#10'begin end;'#10 +
    'constructor TReg.Create(A: Integer);'#10'begin end;'#10 +
    'constructor TBase.Create(A: Integer);'#10'begin end;'#10 +
    'class constructor TDesc.Create;'#10'begin end;'#10 +
    'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'VTUse.pas'),
    'unit VTUse;'#10'interface'#10'uses VTHost;'#10 +
    'procedure P;'#10 +
    'implementation'#10 +
    'procedure P;'#10 +
    'var'#10 +
    '  LR: TReg;'#10 +
    '  LD: TDesc;'#10 +
    'begin'#10 +
    '  LR := TReg.Create;'#10 +               // the public parameterless one
    '  LD := TDesc.Create(7);'#10 +           // the INHERITED TBase.Create
    'end;'#10 +
    'end.'#10);
  { The four the LAST twelve reports turned out to be, read one site at a time.
    Same lesson as the round before: all four are binding, none is visibility. }
  TFile.WriteAllText(TPath.Combine(LDir, 'VTMore.pas'),
    'unit VTMore;'#10'interface'#10 +
    'type'#10 +
    '  TMon = class'#10 +
    '  private'#10 +
    '    function Take(ATimeout: Cardinal): Boolean; overload;'#10 +
    '  public'#10 +
    '    class procedure Take(const AObj: TObject); overload;'#10 +
    '  end;'#10 +
    '  TSelf = class'#10 +
    '  strict private type'#10 +
    '    TGlow = class'#10 +
    '    end;'#10 +
    '  private'#10 +
    '    FGlow: TSelf.TGlow;'#10 +      // own strict private nested type
    '  end;'#10 +
    '  TOnlyClassCtor = class(TObject)'#10 +
    '  strict private'#10 +
    '    class constructor Create;'#10 +  // its ONLY own Create
    '  end;'#10 +
    '  TSyncer = class'#10 +
    '  private'#10 +
    '    class procedure Go(ARec: Pointer; AQ: Boolean = False); overload;'#10 +
    '  public'#10 +
    '    class procedure Go(const AObj: TObject; AProc: TProc); overload;'#10 +
    '  end;'#10 +
    '  TProc = procedure of object;'#10 +
    'implementation'#10 +
    'function TMon.Take(ATimeout: Cardinal): Boolean;'#10'begin Result := False; end;'#10 +
    'class procedure TMon.Take(const AObj: TObject);'#10'begin end;'#10 +
    'class constructor TOnlyClassCtor.Create;'#10'begin end;'#10 +
    'class procedure TSyncer.Go(ARec: Pointer; AQ: Boolean);'#10'begin end;'#10 +
    'class procedure TSyncer.Go(const AObj: TObject; AProc: TProc);'#10'begin end;'#10 +
    'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'VTMoreUse.pas'),
    'unit VTMoreUse;'#10'interface'#10'uses VTMore;'#10 +
    'type'#10 +
    '  TDriver = class'#10 +
    '    FKlass: class of TOnlyClassCtor;'#10 +
    '    procedure Run;'#10 +
    '    procedure Step;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure TDriver.Step;'#10'begin end;'#10 +
    'procedure TDriver.Run;'#10 +
    'var'#10 +
    '  LO: TObject;'#10 +
    'begin'#10 +
    '  LO := nil;'#10 +
    '  VTMore.TMon.Take(LO);'#10 +      // a UNIT-qualified type qualifier
    '  LO := FKlass.Create;'#10 +       // class ref, own Create not callable
    '  TSyncer.Go(nil, Step);'#10 +     // a PROCEDURE designator, not a literal
    'end;'#10 +
    'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.ReportVisibility := True;
    GProj.AnalyzeDirectory(LDir);
    Ok('vistail: a UNIT-qualified type still rejects an instance method',
      DiagCount(ModelByName('vtmoreuse'), 'E2361') = 0);
    Ok('vistail: a class''s OWN strict private nested type is reachable',
      DiagCount(ModelByName('vtmore'), 'E2361') = 0);
  finally
    GProj.Free;
  end;

  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.ReportVisibility := True;
    GProj.AnalyzeDirectory(LDir);
    Ok('vistail: strict private reaches a NESTED type, and only inward',
      DiagCount(ModelByName('vthost'), 'E2361') = 1);
    Ok('vistail: ...and the one refused is the outer reading the nested one',
      DiagHasText(ModelByName('vthost'), 'E2361', 'FIn'));
    Ok('vistail: a class constructor is never the meaning of a name',
      DiagCount(ModelByName('vtuse'), 'E2361') = 0);
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  { An ANONYMOUS METHOD literal cannot bind to a non-procedural parameter, so it
    rejects that candidate outright. `TThread.Synchronize(nil, procedure ... end)`
    fits the PRIVATE `(ASyncRec: PSynchronizeRecord; QueueEvent: Boolean = False)`
    on arity and `nil` scores the same against either first parameter — 41 of
    bigflat's 111 false E2361 came from that one pair. }
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_anonpick');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'APHost.pas'),
    'unit APHost;'#10'interface'#10 +
    'type'#10 +
    '  TProcRef = reference to procedure;'#10 +
    '  TSync = class'#10 +
    '  private'#10 +
    '    class procedure Run(ARec: Pointer; AQueue: Boolean = False); overload;'#10 +
    '  public'#10 +
    '    class procedure Run(const AObj: TObject; AProc: TProcRef); overload;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'class procedure TSync.Run(ARec: Pointer; AQueue: Boolean);'#10'begin end;'#10 +
    'class procedure TSync.Run(const AObj: TObject; AProc: TProcRef);'#10'begin end;'#10 +
    'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'APUse.pas'),
    'unit APUse;'#10'interface'#10'uses APHost;'#10 +
    'procedure P;'#10 +
    'implementation'#10 +
    'procedure P;'#10 +
    'begin'#10 +
    '  TSync.Run(nil, procedure'#10 +
    '    begin'#10 +
    '    end);'#10 +
    'end;'#10 +
    'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.ReportVisibility := True;
    GProj.AnalyzeDirectory(LDir);
    Ok('anonpick: an anonymous method rejects a non-procedural parameter',
      DiagCount(ModelByName('apuse'), 'E2361') = 0);
    Ok('anonpick: ...and the call binds to the PUBLIC overload',
      CrossRefTo(ModelByName('apuse'), 'Run', 'Run'));
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  { 16.4.1: a value typed by an unbound type PARAMETER has the members its
    CONSTRAINT guarantees. System.Win.WinRT's `class var FFactory: F` with
    `F: IInspectable` is the shape — every `FFactory._AddRef` there was a false
    E2003 until the walk hopped to the constraint. }
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_constraint');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'ConHost.pas'),
    'unit ConHost;'#10'interface'#10 +
    'type'#10 +
    '  IThing = interface'#10 +
    '    procedure Go;'#10 +
    '  end;'#10 +
    'implementation'#10'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'ConUse.pas'),
    'unit ConUse;'#10'interface'#10'uses ConHost;'#10 +
    'type'#10 +
    '  TBox<T: IThing> = class'#10 +
    '    class var FIt: T;'#10 +
    '    class procedure Run;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'class procedure TBox<T>.Run;'#10 +
    'begin'#10 +
    '  FIt.Go;'#10 +          // the constraint's member
    '  FIt.Nope;'#10 +        // not on the constraint either
    'end;'#10 +
    'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.ReportUnresolvedMembers := True;
    GProj.AnalyzeDirectory(LDir);
    Ok('constraint: a parameter-typed value reaches its constraint''s members',
      DiagCount(ModelByName('conuse'), 'E2003') = 1);
    Ok('constraint: ...and only those', DiagHasText(ModelByName('conuse'),
      'E2003', 'Nope'));
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  // ---- test-coverage plan step 3 batch 2: 1.2.4 the implicit SysInit unit
  // ---- own directory, so it stays isolated from every OTHER unit named
  // System/SysInit above (EnsureSysInitUnit is a per-project singleton, same
  // as EnsureSystemUnit already is for UNIT_SYS).
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_sysinit');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'SysInit.pas'), UNIT_SYSINIT);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitSysInitUse.pas'),
    UNIT_SYSINIT_USE);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.AnalyzeDirectory(LDir);
    Ok('1.2.4: no E2003 on a bare SysInit-only global',
      DiagCount(ModelByName('unitsysinituse'), 'E2003') = 0);
    Ok('1.2.4: HInstance resolved via the implicit SysInit unit',
      CrossRefTo(ModelByName('unitsysinituse'), 'HInstance', 'HInstance'));
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  // ---- test-coverage plan step 3 batch 6: 14.5.1 an interface reference
  // held POLYMORPHICALLY -- an interface-typed variable assigned a class
  // instance, with a member called through the INTERFACE reference rather
  // than the concrete class. Nothing had ever assigned a class to an
  // interface-typed var before this (every prior interface fixture only
  // ever declared the shape, never used one as a value). Needs the PROJECT
  // pipeline, not bare Analyze: a variable's member-scope hookup runs in
  // the cross/inherited passes, not Phase 1 (SemaSmoke tried this first and
  // came back with 7 unresolved refs -- moved here once that was clear). ----
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_iface_poly');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  // TObject: real (PasTree.Sema.Builtins no longer seeds it) -- named
  // System.pas so the bare heritage below reaches it via the IMPLICIT unit.
  TFile.WriteAllText(TPath.Combine(LDir, 'System.pas'),
    'unit System;'#10'interface'#10 +
    'type'#10 +
    '  TObject = class'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitIfacePoly.pas'),
    'unit UnitIfacePoly;'#10'interface'#10 +
    'type'#10 +
    '  IFoo = interface'#10'    function Ping: Integer;'#10'  end;'#10 +
    '  TImpl = class(TObject, IFoo)'#10 +
    '    function Ping: Integer;'#10'  end;'#10 +
    'implementation'#10 +
    'function TImpl.Ping: Integer; begin Result := 1; end;'#10 +
    'procedure P;'#10'var F: IFoo;'#10 +
    'begin'#10'  F := TImpl.Create;'#10'  F.Ping;'#10'end;'#10 +
    'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.AnalyzeDirectory(LDir);
    Ok('14.5.1: no E2003 assigning a class through its interface reference',
      DiagCount(ModelByName('unitifacepoly'), 'E2003') = 0);
    Ok('14.5.1: F.Ping resolves through the interface reference''s own member',
      LocalRefCount(ModelByName('unitifacepoly'), 'Ping') >= 1);
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  // ---- test-coverage plan, RTTI-seeding batch 2: 19.3.1's own ancestry
  // rule -- "an ordinary class descending from TCustomAttribute" was
  // previously only tested for its PARSE/suffix-fallback shape (does
  // `[Table]` find `TableAttribute`); the ancestry constraint itself had
  // NO check anywhere (confirmed by grep: `TCustomAttribute` appeared
  // nowhere outside comments before this). dcc32 37.0 probed first, never
  // guessed: `[TObject] TFoo = class end;` and a from-scratch
  // `TNotAnAttr = class end; [TNotAnAttr] ...` both give
  // `E2010 Incompatible types: '<name>' and 'TCustomAttribute'` -- exactly
  // SE2010_IncompatibleTypes's existing shape (2.6.1 already uses it for
  // assignment-compatibility), just fired from CheckAttributes at a
  // declaration site instead of from the type-checker at an assignment.
  // Needs the PROJECT harness even for same-unit cases: CheckAttributes
  // uses XDescendsFrom, a cross-model primitive, and ResolveCustomAttributeX
  // resolves TCustomAttribute the same way `tobject` resolves elsewhere in
  // this file -- through a real System unit on the search path, so this
  // fixture (unlike 14.5.1's just above) DOES need its own System.pas stub;
  // no stub means ResolveCustomAttributeX finds nothing and the whole check
  // says nothing, by design (see CheckAttributes' own comment). ----
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_attr_anc');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'System.pas'),
    'unit System;'#10'interface'#10 +
    'type'#10 +
    '  TObject = class end;'#10 +
    '  TCustomAttribute = class(TObject) end;'#10 +
    'implementation'#10'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitAttrAnc.pas'),
    'unit UnitAttrAnc;'#10'interface'#10 +
    'type'#10 +
    // A real attribute class -- must NOT be flagged.
    '  TGoodAttr = class(TCustomAttribute) end;'#10 +
    // An ordinary class with no such ancestor -- must BE flagged, the exact
    // AttrProbe2.dpr shape probed against dcc directly.
    '  TNotAnAttr = class end;'#10 +
    // 19.3.1's own pre-existing suffix-fallback case, now with an ancestry
    // consequence: `[Table]` resolves to `TableAttribute` (no bare `Table`
    // exists here to compete), and THAT class does not descend either --
    // the check must fire on the RESOLVED name, not the name as written.
    '  TableAttribute = class end;'#10 +
    // 19.3.3's trap, mirroring a real component suite: an ordinary class
    // whose NAME is a compiler-recognized attribute. Ordinary resolution
    // finds it, so without the magic-attribute exemption `[unsafe]` below
    // would report it as a non-TCustomAttribute.
    '  Unsafe = class end;'#10 +
    '  [TGoodAttr]'#10'  TFooGood = class end;'#10 +
    '  [TNotAnAttr]'#10'  TFooBad = class end;'#10 +
    '  [Table]'#10'  TFooTable = class end;'#10 +
    '  TFooMagic = class'#10'    [unsafe] FRef: TObject;'#10'  end;'#10 +
    'implementation'#10'end.'#10);
  // Cross-unit: the attribute class and its use site are in DIFFERENT
  // units, proving XDescendsFrom's cross-model walk, not just a same-unit
  // heritage read.
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitAttrLib.pas'),
    'unit UnitAttrLib;'#10'interface'#10 +
    'type'#10'  TLibAttr = class(TCustomAttribute) end;'#10 +
    'implementation'#10'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitAttrUse.pas'),
    'unit UnitAttrUse;'#10'interface'#10 +
    'uses UnitAttrLib;'#10 +
    'type'#10'  [TLibAttr]'#10'  TFooCross = class end;'#10 +
    'implementation'#10'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.AnalyzeDirectory(LDir);
    var LAnc := ModelByName('unitattranc');
    Ok('19.3.1: a real TCustomAttribute descendant is NOT flagged',
      not DiagHasText(LAnc, 'E2010', 'TGoodAttr'));
    Ok('19.3.1: a class with no such ancestor IS flagged, dcc''s own message',
      DiagHasText(LAnc, 'E2010',
        'Incompatible types: ''TNotAnAttr'' and ''TCustomAttribute'''));
    Ok('19.3.1: the check fires on the RESOLVED name after the suffix '
      + 'fallback, not the name as written',
      DiagHasText(LAnc, 'E2010',
        'Incompatible types: ''TableAttribute'' and ''TCustomAttribute'''));
    var LUse := ModelByName('unitattruse');
    Ok('19.3.1: cross-unit -- a descendant declared in ANOTHER unit is not '
      + 'flagged either',
      Assigned(LUse) and (DiagCount(LUse, 'E2010') = 0));
    // 19.3.3: a COMPILER-RECOGNIZED attribute is exempt from the ancestry
    // check, and the fixture makes that non-vacuous the way the real world
    // did -- a class literally named `Unsafe` that is NOT a TCustomAttribute
    // descendant is in scope, so ordinary resolution finds it and the check
    // would fire. Cost 3 false E2010 on a real project (a component suite
    // ships `Unsafe = class // for internal use`), because exact-name-wins
    // means 19.3.1's `+Attribute` fallback never reaches System.pas's real
    // UnsafeAttribute.
    Ok('19.3.3: [unsafe] is exempt even when a non-attribute class named '
      + 'Unsafe is in scope -- dcc matches magic attributes by name, not by '
      + 'lookup', not DiagHasText(LAnc, 'E2010', 'Unsafe'));
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  // ---- test-coverage plan, ownership-tracking batch: 20.3.1 "is this type
  // managed" -- a real type-system query with zero prior modeling (grep for
  // "Managed"/"IsManagedType" across source/*.pas before this batch found
  // only the seeded INTRINSIC NAME, never evaluated, and one unrelated
  // "unmanaged" comment about ownership of a dictionary, not a language
  // type at all). Kept as a pure PUBLIC query (GProj.IsManagedTypeX), not a
  // diagnostic -- the spec itself frames managedness as something a
  // type-checker COMPUTES, not something dcc warns about: probed dcc32
  // 37.0 with GetMem/FreeMem of a managed-field record (20.7.1's own
  // suggested check) and it gives no diagnostic at all, so that is not a
  // real check to add. ----
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_managed');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitMg.pas'),
    'unit UnitMg;'#10'interface'#10 +
    'type'#10 +
    // Long strings: managed. ShortString: the one NOT managed (20.3.1
    // explicitly calls out "long strings"; ShortString is the Turbo-era
    // fixed-size exception the spec's own wording excludes).
    '  TLongStr = UnicodeString;'#10 +
    '  TShortStr = ShortString;'#10 +
    // Arrays: dynamic is ALWAYS managed; static is managed only through its
    // element (an Integer array isn't, a string array is).
    '  TDynArr = array of Integer;'#10 +
    '  TStaticArr = array[0..9] of Integer;'#10 +
    '  TStaticStrArr = array[0..2] of UnicodeString;'#10 +
    // Interface, Variant: always managed.
    '  IFoo = interface end;'#10 +
    '  TVar = Variant;'#10 +
    // Procedural types: only `reference to` is managed -- `of object` and a
    // plain procedural pointer are not.
    '  TRefProc = reference to procedure;'#10 +
    '  TObjProc = procedure of object;'#10 +
    '  TPlainProc = procedure;'#10 +
    // Records: managed via a lifecycle operator even with NO managed
    // fields, via a managed FIELD even with no operator, or neither.
    '  TPlainRec = record X: Integer; end;'#10 +
    '  TFieldRec = record S: UnicodeString; end;'#10 +
    '  TOpRec = record'#10 +
    '    class operator Initialize(out Dest: TOpRec);'#10 +
    '    class operator Finalize(var Dest: TOpRec);'#10 +
    '  end;'#10 +
    // A NESTED case: a static array of a managed record, and a record whose
    // only managed field is itself a static array of a managed type --
    // proves the recursion actually chains, not just one level.
    '  TArrOfFieldRec = array[0..1] of TFieldRec;'#10 +
    '  TWrapRec = record A: TStaticStrArr; end;'#10 +
    'implementation'#10 +
    'class operator TOpRec.Initialize(out Dest: TOpRec); begin end;'#10 +
    'class operator TOpRec.Finalize(var Dest: TOpRec); begin end;'#10 +
    'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.AnalyzeDirectory(LDir);

    Ok('20.3.1: a long string is managed',
      GProj.IsManagedTypeX(TypeXOf('unitmg', 'tlongstr')));
    Ok('20.3.1: ShortString is NOT managed',
      not GProj.IsManagedTypeX(TypeXOf('unitmg', 'tshortstr')));
    Ok('20.3.1: a dynamic array is managed regardless of element',
      GProj.IsManagedTypeX(TypeXOf('unitmg', 'tdynarr')));
    Ok('20.3.1: a static array of a plain type is NOT managed',
      not GProj.IsManagedTypeX(TypeXOf('unitmg', 'tstaticarr')));
    Ok('20.3.1: a static array IS managed through a managed element',
      GProj.IsManagedTypeX(TypeXOf('unitmg', 'tstaticstrarr')));
    Ok('20.3.1: an interface type is managed',
      GProj.IsManagedTypeX(TypeXOf('unitmg', 'ifoo')));
    Ok('20.3.1: Variant is managed',
      GProj.IsManagedTypeX(TypeXOf('unitmg', 'tvar')));
    Ok('20.3.1: `reference to procedure` is managed',
      GProj.IsManagedTypeX(TypeXOf('unitmg', 'trefproc')));
    Ok('20.3.1: `procedure of object` is NOT managed',
      not GProj.IsManagedTypeX(TypeXOf('unitmg', 'tobjproc')));
    Ok('20.3.1: a plain procedural type is NOT managed',
      not GProj.IsManagedTypeX(TypeXOf('unitmg', 'tplainproc')));
    Ok('20.3.1: a record with no managed field and no lifecycle op is NOT '
      + 'managed', not GProj.IsManagedTypeX(TypeXOf('unitmg', 'tplainrec')));
    Ok('20.3.1: a record with a managed FIELD is managed',
      GProj.IsManagedTypeX(TypeXOf('unitmg', 'tfieldrec')));
    Ok('20.3.1: a record with a lifecycle OPERATOR is managed even with no '
      + 'managed field', GProj.IsManagedTypeX(TypeXOf('unitmg', 'toprec')));
    Ok('20.3.1: recursion chains through a static array of a managed record',
      GProj.IsManagedTypeX(TypeXOf('unitmg', 'tarroffieldrec')));
    Ok('20.3.1: recursion chains through a record wrapping a managed array',
      GProj.IsManagedTypeX(TypeXOf('unitmg', 'twraprec')));
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  // ---- 9.4.2 (13.0), the half SemaSmoke's own case cannot reach: the
  // EXPLICIT `Self.FX` spelling inside a PARAMETERLESS operator. Needs the
  // project pipeline, and for a reason already written down (batch 6): a
  // qualifier's member scope is populated by the cross/inherited passes,
  // never by Phase 1 -- bare Analyze leaves `Self.FX`'s FX unresolved even
  // for an ordinary class method, so asserting it there would pin a
  // limitation instead of the rule.
  //
  // `Self` itself is asserted only through E2003's SILENCE, never through
  // RefMap: nothing declares it (11.3.3), so it deliberately has no symbol
  // at all and is name-exempted from E2003 -- its TYPE comes from
  // StructSymOfNode. So "does Self work" can only be observed HERE, through
  // whether the member hanging off it resolves. ----
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_implicitself');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitSelfOp.pas'),
    'unit UnitSelfOp;'#10'interface'#10 +
    'type'#10 +
    '  TG = record'#10 +
    '    FX: Integer;'#10 +
    '    class operator Initialize;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'class operator TG.Initialize;'#10 +
    'begin'#10 +
    '  FX := 0;'#10 +          // implicit Self, the bare spelling
    '  Self.FX := 1;'#10 +     // the EXPLICIT one -- the point of this case
    'end;'#10 +
    'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitSelfCmp.pas'),
    'unit UnitSelfCmp;'#10'interface'#10 +
    'type'#10 +
    '  TH = record'#10'    FY: Integer;'#10'    procedure Bar;'#10'  end;'#10 +
    '  TCls = class'#10'    FZ: Integer;'#10'    procedure Baz;'#10'  end;'#10 +
    'implementation'#10 +
    'procedure TH.Bar;'#10'var V: TH;'#10 +
    'begin'#10'  V.FY := 1;'#10'  Self.FY := 2;'#10'end;'#10 +
    'procedure TCls.Baz;'#10'var C: TCls;'#10 +
    'begin'#10'  C.FZ := 1;'#10'  Self.FZ := 2;'#10'end;'#10 +
    'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.AnalyzeDirectory(LDir);
    var LSelfOp := ModelByName('unitselfop');
    Ok('9.4.2: no E2003 for Self in a parameterless operator body -- it has '
      + 'no symbol by design, so silence is the assertion',
      DiagCount(LSelfOp, 'E2003') = 0);
    Ok('9.4.2: FX binds through the implicit Self in BOTH spellings -- bare '
      + 'and Self.FX', LocalRefCount(LSelfOp, 'FX') = 2);

    // ---- 11.3.3, the general rule the 9.4.2 case above sits on and the
    // reason it can assert 2 rather than 1: `Self.Member` now BINDS.
    // Found while probing 9.4.2 -- `Self` has no symbol (nothing declares
    // it), so CrossType's qualifier-type lookup dead-ended and the member
    // hanging off it was never bound, while the bare spelling right beside
    // it bound fine. It was never a false E2003 (the member-report branch
    // is gated on a KNOWN qualifier type, which is exactly what was
    // missing), just a silently absent binding -- so the cost was
    // navigation and every other RefMap consumer, on every `Self.X` in
    // every method. Both control spellings (`V.FY` through an ordinary
    // record variable, `C.FZ` through a class one) already bound before
    // the fix and are here so the case cannot pass vacuously. ----
    var LCmp := ModelByName('unitselfcmp');
    Ok('11.3.3: in a RECORD method, both V.FY and Self.FY bind',
      LocalRefCount(LCmp, 'FY') = 2);
    Ok('11.3.3: in a CLASS method, both C.FZ and Self.FZ bind',
      LocalRefCount(LCmp, 'FZ') = 2);
    Ok('11.3.3: and Self itself still raises no E2003 -- it has no symbol '
      + 'by design', DiagCount(LCmp, 'E2003') = 0);
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  // ---- 18.5.1 inner-exception chaining, and 18.5.2 the RaisingException
  // hook. The spec calls both "not new syntax" -- 18.5.1 is RTL members
  // (`InnerException`/`BaseException`/`ToString`) reached by ordinary member
  // access on an Exception-typed expression, 18.5.2 an ordinary virtual
  // override -- so what an analyzer can actually assert is that the whole
  // chain RESOLVES, which is exactly what nothing had ever pointed at.
  //
  // The load-bearing assertion is `Message` x3: it is reached once directly
  // on the handler variable and twice THROUGH a link of the chain
  // (`E.InnerException.Message`), so it only counts 3 if the intermediate
  // property's own Exception type was carried through the member walk. One
  // or two would mean the chain typed out halfway -- which is why the count
  // is pinned rather than a bare "does Message resolve".
  //
  // Verified against dcc32 37.0 as a REAL program first (real System.SysUtils,
  // not this stub): it compiles AND running it prints 'wrapped' then 'inner',
  // confirming both that the shapes below are legal and the spec's own note
  // that `ToString` concatenates the whole chain rather than one Message.
  // The stub only has to declare enough for resolution; the semantics are
  // runtime and out of a static analyzer's reach either way.
  //
  // 18.6.1 (a failing `Create` still runs `Destroy`) is deliberately NOT
  // tested: by the spec's own words "not new syntax -- no parser impact;
  // this is a runtime/codegen guarantee", so a test would assert nothing
  // real. Same call as 19.4.1/19.4.2/20.5.1. ----
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_excchain');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'System.pas'),
    'unit System;'#10'interface'#10 +
    'type'#10 +
    '  TObject = class end;'#10 +
    '  PExceptionRecord = Pointer;'#10 +
    '  Exception = class(TObject)'#10 +
    '  private'#10'    FMessage: string;'#10 +
    '  public'#10 +
    '    constructor Create(const Msg: string);'#10 +
    '    function ToString: string;'#10 +
    '    class procedure RaiseOuterException(E: Exception);'#10 +
    '    procedure RaisingException(P: PExceptionRecord); virtual;'#10 +
    '    property Message: string read FMessage;'#10 +
    '    property InnerException: Exception read FMessage;'#10 +
    '    property BaseException: Exception read FMessage;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'constructor Exception.Create(const Msg: string); begin end;'#10 +
    'function Exception.ToString: string; begin Result := ''''; end;'#10 +
    'class procedure Exception.RaiseOuterException(E: Exception);'#10 +
    'begin end;'#10 +
    'procedure Exception.RaisingException(P: PExceptionRecord);'#10 +
    'begin end;'#10 +
    'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitChain.pas'),
    'unit UnitChain;'#10'interface'#10 +
    'type'#10 +
    // 18.5.2: the RaisingException hook, an ordinary virtual override.
    '  ECustom = class(Exception)'#10 +
    '  protected'#10 +
    '    procedure RaisingException(P: PExceptionRecord); override;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'procedure ECustom.RaisingException(P: PExceptionRecord);'#10 +
    'begin'#10 +
    '  inherited RaisingException(P);'#10 +
    'end;'#10 +
    'procedure Consume;'#10'var S: string;'#10 +
    'begin'#10 +
    '  try'#10 +
    '    Consume;'#10 +
    '  except'#10 +
    // 18.5.1's own raising API: a CLASS method reached on the type itself.
    '    Exception.RaiseOuterException(ECustom.Create(''wrapped''));'#10 +
    '  end;'#10 +
    '  try'#10 +
    '    Consume;'#10 +
    '  except'#10 +
    '    on E: Exception do'#10 +
    '    begin'#10 +
    '      S := E.Message;'#10 +
    '      S := E.InnerException.Message;'#10 +
    '      S := E.BaseException.Message;'#10 +
    '      S := E.ToString;'#10 +
    '    end;'#10 +
    '  end;'#10 +
    'end;'#10'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.AnalyzeDirectory(LDir);
    var LCh := ModelByName('unitchain');
    Ok('18.5.1: no E2003 anywhere in an inner-exception chain fixture',
      DiagCount(LCh, 'E2003') = 0);
    Ok('18.5.1: InnerException resolves on an Exception-typed handler variable',
      CrossRefTo(LCh, 'InnerException', 'InnerException'));
    Ok('18.5.1: BaseException resolves too -- the spec''s own distinction '
      + 'from InnerException, and a separate member',
      CrossRefTo(LCh, 'BaseException', 'BaseException'));
    Ok('18.5.1: ToString resolves as a member, not the intrinsic',
      CrossRefTo(LCh, 'ToString', 'ToString'));
    Ok('18.5.1: Message resolves through EVERY link -- directly on the '
      + 'handler AND through both chain properties',
      CrossRefCountInUnit(LCh, 'Message', 'Message', 'system') = 3);
    Ok('18.5.1: RaiseOuterException resolves as a class method on the TYPE',
      CrossRefTo(LCh, 'RaiseOuterException', 'RaiseOuterException'));
    Ok('18.5.2: an `inherited RaisingException(P)` in the override binds to '
      + 'the ancestor''s virtual, cross-unit',
      CrossRefTo(LCh, 'RaisingException', 'RaisingException'));
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  // ---- 1.3.2, the $IF symbol oracle (RunDeclaredPass widened beyond
  // Declared): const values, SizeOf of enums (with positional {$Z}/
  // MINENUMSIZE state), SizeOf of a same-size-fields record, Length of a
  // bounded array — the four shapes measured on the RTL (System.VarUtils'
  // Generic*, System.Classes' TValueType, System.Rtti's TMethod, System.pas'
  // RegisteredTypeInfoTable). Each guard below is TRUE under the oracle but
  // guessed False on the first pass, so the declaration it guards EXISTS
  // only if the second pass really re-decided the unit — the assertion is
  // the symbol's existence, which cannot pass vacuously.
  //
  // The STRING-const guard is the deliberate negative: tier-1 answers
  // numbers and booleans only, so that one stays guessed-False and its type
  // must NOT exist — pinning that the oracle refuses rather than guesses.
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_iforacle');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitOracleLib.pas'),
    'unit UnitOracleLib;'#10'interface'#10 +
    'type'#10'  TDuo = record P, Q: Pointer; end;'#10 +
    'implementation'#10'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitOracle.pas'),
    'unit UnitOracle;'#10'interface'#10 +
    'uses UnitOracleLib;'#10 +
    'const'#10 +
    '  KBase = True;'#10 +
    '  KAlias = KBase;'#10 +          // a const CHAIN, like GenericVariants
    '  KStr = ''nope'';'#10 +
    'type'#10 +
    '  TSmallEnum = (seA, seB, seC);'#10 +
    '{$MINENUMSIZE 4}'#10 +
    '  TBigEnum = (beA, beB);'#10 +   // same unit, forced to 4 by the state
    '{$MINENUMSIZE 1}'#10 +
    '  TPair = record A, B: Pointer; end;'#10 +
    // A generic actual that MENTIONS an open parameter inside a compound is
    // what the layout walk still refuses; records, arrays, strings, sets,
    // variants, file types, inline enums, class-var sections, plain generic
    // instantiations and old-style objects are all computed for real now --
    // see the layout fixture.
    '  TGOra<T> = record V: T; end;'#10 +
    '  TOpenOra<T> = record V: TGOra<TGOra<T>>; end;'#10 +
    '  TMixedOra = TOpenOra<Integer>;'#10 +
    'var'#10 +
    '  GTable: array[0..2] of Integer;'#10 +
    '{$IF KAlias}'#10 +
    'type TTookConst = class end;'#10 +
    '{$ENDIF}'#10 +
    '{$IF SizeOf(TSmallEnum) = 1}'#10 +
    'type TTookEnum = class end;'#10 +
    '{$ENDIF}'#10 +
    '{$IF SizeOf(TBigEnum) = 4}'#10 +
    'type TTookEnumZ = class end;'#10 +
    '{$ENDIF}'#10 +
    '{$IF SizeOf(TPair) = 8}'#10 +    // 2 x Pointer = 8 on Win32
    'type TTookRec = class end;'#10 +
    '{$ENDIF}'#10 +
    '{$IF SizeOf(TDuo) = 8}'#10 +     // the CROSS-UNIT route (TMethod shape)
    'type TTookXUnit = class end;'#10 +
    '{$ENDIF}'#10 +
    '{$IF Length(GTable) = 3}'#10 +
    'type TTookLen = class end;'#10 +
    '{$ENDIF}'#10 +
    // Strings ARE answered now, and this is the shape that pins it. dcc
    // orders string constants for real and does it CASE-SENSITIVELY (probed:
    // `$IF 'ABC' = 'abc'` takes the ELSE branch), which is what the
    // version-guard idiom in the wild depends on — Indy's
    // `$IF gsIdVersion >= '10.5.5'`. Both guards below are False under the
    // first-pass guess and True only if the oracle really supplied the
    // string, so the types cannot appear vacuously. The case guard is the
    // one that would go red if the old SameText comparison came back.
    '{$IF KStr >= ''10.5.5''}'#10 +
    'type TTookStr = class end;'#10 +
    '{$ENDIF}'#10 +
    '{$IF KStr <> ''NOPE''}'#10 +
    'type TTookStrCase = class end;'#10 +
    '{$ENDIF}'#10 +
    // The residual the flag test below needs: a layout shape the walk refuses
    // to guess, so this guard is still open after the second pass.
    '{$IF SizeOf(TMixedOra) > 8}'#10 +
    'type TTookMixed = class end;'#10 +
    '{$ENDIF}'#10 +
    'implementation'#10'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.AnalyzeDirectory(LDir);
    var LOr := ModelByName('unitoracle');
    Ok('1.3.2 oracle: a const CHAIN answers and the guard flips True',
      SymCountOf(LOr, 'ttookconst', skType) = 1);
    Ok('1.3.2 oracle: SizeOf of an implicit enum answers 1',
      SymCountOf(LOr, 'ttookenum', skType) = 1);
    Ok('1.3.2 oracle: ...and respects the POSITIONAL {$MINENUMSIZE} state',
      SymCountOf(LOr, 'ttookenumz', skType) = 1);
    Ok('1.3.2 oracle: SizeOf of a same-size-fields record answers',
      SymCountOf(LOr, 'ttookrec', skType) = 1);
    Ok('1.3.2 oracle: SizeOf reaches a record in a USED unit too',
      SymCountOf(LOr, 'ttookxunit', skType) = 1);
    Ok('1.3.2 oracle: Length of a bounded array answers hi-lo+1',
      SymCountOf(LOr, 'ttooklen', skType) = 1);
    Ok('1.3.2 oracle: a STRING const answers and ORDERS, like dcc',
      SymCountOf(LOr, 'ttookstr', skType) = 1);
    Ok('1.3.2 oracle: ...and compares CASE-SENSITIVELY, like dcc',
      SymCountOf(LOr, 'ttookstrcase', skType) = 1);
    // ReportGuessedIfs is OFF by default: the TMixedOra residual above must
    // NOT have produced a diagnostic -- the analysis is byte-identical.
    Ok('1.3.2: ReportGuessedIfs off -- no PPIF diagnostics by default',
      DiagCount(LOr, 'PPIF') = 0);
  finally
    GProj.Free;
  end;
  // Same fixture, flag ON: the one residual guess (the TMixedOra guard) surfaces
  // as a PPIF diagnostic whose message carries the expression text -- the
  // exotica detector for foreign projects. The oracle-answered guards must
  // NOT appear: their units were re-decided and the second pass's flags are
  // what survives.
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.ReportGuessedIfs := True;
    GProj.AnalyzeDirectory(LDir);
    var LOrOn := ModelByName('unitoracle');
    Ok('1.3.2: ReportGuessedIfs on -- exactly the ONE residual guess reports',
      DiagCount(LOrOn, 'PPIF') = 1);
    Ok('1.3.2: ...and the message carries the expression text',
      DiagHasText(LOrOn, 'PPIF', 'TMixedOra'));
    Ok('1.3.2: oracle-answered guards do NOT report -- the flag shows '
      + 'guesses, not questions', not DiagHasText(LOrOn, 'PPIF', 'KAlias'));
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  // ---- ReportGuessedIfs' FILTER, the part that decides whether the flag is
  // a finding at all. A guess whose questions the full oracle can now answer
  // is CONFIRMED, not open, and must stay silent -- `$IF Declared(X)` where X
  // is declared nowhere is ordinary platform-conditional code (SysInit's
  // TlsStart; 31 such sites on the RTL, every one of them normal). What must
  // still report is anything genuinely undecidable, and the shapes below
  // are the reachability proof: without them the filter could be silencing
  // everything and look identical on a clean corpus. ----
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_ifexotic');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitExotic.pas'),
    'unit UnitExotic;'#10'interface'#10 +
    'type'#10 +
    // A generic actual over an OPEN parameter: the shape the walk refuses.
    '  TGEx<T> = record V: T; end;'#10 +
    '  TOpenEx<T> = record V: TGEx<TGEx<T>>; end;'#10 +
    '  TMixed = TOpenEx<Integer>;'#10 +
    'const'#10 +
    '  KStr = ''text'';'#10 +
    'implementation'#10 +
    // (a) a platform-style guard on a name declared NOWHERE: confirmed
    //     correct by the oracle, so it must NOT report.
    '{$IF Declared(NeverAnywhere)}'#10'procedure PA; begin end;'#10 +
    '{$ENDIF}'#10 +
    // (b) SizeOf of a layout tier 1 refuses.
    '{$IF SizeOf(TMixed) > 8}'#10'procedure PB; begin end;'#10'{$ENDIF}'#10 +
    // (c) a function CondEval has no case for at all -- the callee is named
    //     so the report can say what it choked on.
    '{$IF Ord(KStr[1]) > 64}'#10'procedure PC; begin end;'#10'{$ENDIF}'#10 +
    // (d) an expression that does not parse: PPBAD, the source's own bug.
    '{$IF 3 +}'#10'procedure PE; begin end;'#10'{$ENDIF}'#10 +
    'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.ReportGuessedIfs := True;
    GProj.AnalyzeDirectory(LDir);
    var LEx := ModelByName('unitexotic');
    Ok('1.3.2 filter: a CONFIRMED guess stays silent -- Declared(X) for an X '
      + 'declared nowhere is normal platform code, not a finding',
      not DiagHasText(LEx, 'PPIF', 'NeverAnywhere'));
    Ok('1.3.2 filter: SizeOf of a mixed-size record reports, naming it',
      DiagHasText(LEx, 'PPIF', 'SizeOf(TMixed)'));
    Ok('1.3.2 filter: an unrecognized FUNCTION reports, naming the callee -- '
      + 'it records no question, so a naive "nothing open" test would have '
      + 'silenced it', DiagHasText(LEx, 'PPIF', 'Ord()'));
    Ok('1.3.2 filter: a malformed conditional is PPBAD, not PPIF',
      DiagHasText(LEx, 'PPBAD', '3 +') and (DiagCount(LEx, 'PPBAD') = 1));
    Ok('1.3.2 filter: exactly the two undecidable guards report, no more',
      DiagCount(LEx, 'PPIF') = 2);
    // Severity: ours-vs-theirs, so a host does not call our own limitation
    // an error in the user's code.
    Ok('1.3.2: PPIF labels as Warning, PPBAD as Error',
      (DiagSeverityLabel('PPIF') = 'Warning') and
      (DiagSeverityLabel('PPBAD') = 'Error') and
      (DiagSeverityLabel('E2003') = 'Error'));
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  // ---- RECORD LAYOUT. Every number below was produced by compiling a .dpr
  // full of these shapes for WIN32 and printing SizeOf at run time -- this
  // fixture is that output transcribed, not a model checked against itself.
  // Each guard declares a marker type, so a refusal (or a wrong size) shows up
  // as a missing symbol rather than a silent pass. ----
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_iflayout');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitLayout.pas'),
    'unit UnitLayout;'#10'interface'#10 +
    'type'#10 +
    '  TInner8 = record X: Int64; end;'#10 +
    '  TMeth = record Code, Data: Pointer; end;'#10 +
    '  TR01 = record A: Byte; B: Int64; end;'#10 +          // 16: padded to 8
    '  TR03 = record A: Integer; B: Byte; end;'#10 +        // 8: TRAILING pad
    '  TR05 = record A: Word; B: Byte; C: Word; end;'#10 +  // 6
    '  TR06 = record A: Pointer; B: Byte; end;'#10 +        // 8 on Win32
    '  TR07 = packed record A: Byte; B: Int64; end;'#10 +   // 9: no padding
    '  TR08 = record A: Byte; N: TInner8; end;'#10 +        // 16: nested align
    '  TR12 = record A: Byte; B: Extended; end;'#10 +       // 24: size 10/al 8
    '  TR13 = record A: Char; B: AnsiChar; end;'#10 +       // 4
    '  TR16 = record A: Byte; M: TMeth; end;'#10 +          // 12
    '  TR19 = record A, B: Byte; C: Integer; end;'#10 +     // 8: shared decl
    '  TR20 = record A: Currency; B: Byte; end;'#10 +       // 16
    '{$A1}'#10 +
    '  TA1 = record A: Byte; B: Int64; end;'#10 +           // 9
    '{$A2}'#10 +
    '  TA2 = record A: Byte; B: Int64; end;'#10 +           // 10
    '{$A4}'#10 +
    '  TA4 = record A: Byte; B: Int64; end;'#10 +           // 12
    '{$A16}'#10 +
    '  TA16 = record A: Byte; B: Int64; end;'#10 +          // 16: caps at 8
    '{$A8}'#10 +
    '  TNest1 = record A: Byte; N: TA1; end;'#10 +          // 10: TA1 aligns 1
    // Reference-counted and pointer-like FIELDS. Every one is one machine
    // pointer, pointer-aligned, so after a Byte they all land on 8 (Win32) --
    // and SizeOf of a CLASS type is the reference, not the instance.
    '  IMy = interface end;'#10 +
    '  TCls = class Fa, Fb, Fc: Integer; end;'#10 +
    '  TDyn = array of Integer;'#10 +
    '  TS01 = record A: Byte; F: string; end;'#10 +          // 8
    '  TS02 = record A: Byte; F: ShortString; end;'#10 +     // 257: align 1!
    '  TS03 = record A: Byte; F: string[10]; end;'#10 +      // 12
    '  TS04 = record A: Byte; F: Variant; end;'#10 +         // 24: align 8
    '  TS05 = record A: Byte; F: IMy; end;'#10 +             // 8
    '  TS06 = record A: Byte; F: TCls; end;'#10 +            // 8
    '  TS07 = record A: Byte; F: TDyn; end;'#10 +            // 8
    // A method pointer aligns as a SCALAR of its own size, not as a pointer:
    // 8 bytes aligned to 8 on Win32, where a hand-written two-pointer record
    // (TMeth above, TR16) aligns to 4. The two together pin the difference.
    '  TProcOO = procedure(A: Integer) of object;'#10 +
    '  TS08 = record A: Byte; F: TProcOO; end;'#10 +         // 16, not 12
    // Static arrays, standalone and as fields. The last two pin that the
    // array's alignment is its ELEMENT's, not its size.
    '  TE5 = (q0, q1, q2, q3, q4);'#10 +
    '  TSub = 5..9;'#10 +
    '  TRec3 = record A, B, C: Byte; end;'#10 +
    '  TB01 = array[0..2] of Integer;'#10 +                  // 12
    '  TB02 = array[Byte] of Integer;'#10 +                  // 1024
    '  TB03 = array[TE5] of Integer;'#10 +                   // 20
    '  TB04 = array[TSub] of Integer;'#10 +                  // 20
    '  TB05 = array[0..1, 0..2] of Integer;'#10 +            // 24
    '  TB06 = array[0..1] of array[0..2] of Integer;'#10 +   // 24
    '  TB07 = array[''a''..''e''] of Byte;'#10 +             // 5
    '  TB08 = array[0..2] of TRec3;'#10 +                    // 9
    '  TC01 = record A: Byte; F: array[0..2] of Integer; end;'#10 +  // 16
    '  TC02 = record A: Byte; F: array[0..2] of Byte; end;'#10 +     // 4
    '  TC03 = record A: Byte; F: array[0..0] of Int64; end;'#10 +    // 16
    '  TC04 = record A: Byte; F: array[0..2] of TRec3; end;'#10 +    // 10
    // SETS. The storage is the byte SPAN from the base type's Lo to its Hi,
    // rounded up to a power of two while it still fits in a machine word and
    // exact above that -- so on Win32 (4-byte word) span 3 becomes 4 while
    // span 5 stays 5. Always byte-aligned, which the field cases pin.
    '  TE8 = (z0,z1,z2,z3,z4,z5,z6,z7);'#10 +
    '  TE9 = (y0,y1,y2,y3,y4,y5,y6,y7,y8);'#10 +
    '  TG01 = set of 0..7;'#10 +          // span 1 -> 1
    '  TG02 = set of 0..8;'#10 +          // span 2 -> 2
    '  TG03 = set of 0..16;'#10 +         // span 3 -> 4, rounded
    '  TG04 = set of 0..39;'#10 +         // span 5 -> 5, exact (Win32)
    '  TG05 = set of Byte;'#10 +          // 32
    '  TG06 = set of 8..15;'#10 +         // an OFFSET base: span 1 -> 1
    '  TG07 = set of 200..255;'#10 +      // span 7 -> 7 (Win32)
    '  TG08 = set of TE9;'#10 +           // 9 members -> span 2
    '  TH01 = record A: Byte; F: TG03; end;'#10 +   // 5: the set aligns to 1
    '  THO2 = record A: Byte; F: TG05; end;'#10 +   // 33
    // VARIANT parts. A named tag is stored and aligned but does NOT raise the
    // record`s own alignment; every branch starts at the same offset, aligned
    // to the largest alignment among the fields at THAT level only.
    '  TV01 = record A: Byte; case Integer of 0: (X: Int64); 1: (Y: Byte); end;'#10 +
    '  TV02 = record case Integer of 0: (A: Integer); 1: (B: array[0..7] of Byte); end;'#10 +
    '  TV03 = packed record A: Byte; case Integer of 0: (X: Int64); end;'#10 +
    '  TV04 = record A: Byte; case T: Word of 0: (X: Byte); end;'#10 +
    '  TV05 = record A: Byte; case T: Int64 of 0: (X: Byte); end;'#10 +
    '  TV06 = record A: Byte; case Integer of 0: (X: Byte; case Integer of 0: (Q: Int64)); end;'#10 +
    '  TV07 = record A: Byte; case Integer of 0: (P: Byte; Q: Int64); end;'#10 +
    '  TV08 = record A: Byte; case Integer of 0: (X: array[0..2] of Byte); 1: (Y: Word); end;'#10 +
    '  TV09 = record A: Byte; F: TV02; end;'#10 +
    // FILE types. Both `file` and `file of T` are System`s TFileRec whatever
    // the element -- so the size is looked up, not hard-coded. The replica
    // below stands in for it here (a closed corpus has no System.pas), and
    // the field case pins the rule that matters: TFileRec is PACKED, so its
    // own alignment is 1, but a file VARIABLE is pointer-aligned anyway.
    '  TFileRec = packed record H: NativeUInt; M: Word; Fl: Word;'#10 +
    '    case Byte of 0: (R: Cardinal); 1: (B: array[0..15] of Byte); end;'#10 +
    '  TKFile = file of Byte;'#10 +                        // 24, like TFileRec
    '  TKFld = record A: Byte; F: file of Byte; end;'#10 + // 28, aligned to 4
    // Inline anonymous ENUM fields, and CLASS VAR sections -- which run on,
    // so `A` below is per-type storage too and the record is 0 bytes.
    '  TE01 = record A: Byte; F: (r0, r1); end;'#10 +              // 2
    '  TE02 = record A: Byte; F: (v0 = 5, v1 = 9); end;'#10 +      // 2
    '  TE03 = record A: Byte; F: (p0 = 200, p1 = 300); end;'#10 +  // 4
    '  TW01 = record class var Q: Integer; end;'#10 +              // 0
    '  TW02 = record class var Q: Integer; A: Byte; end;'#10 +     // 0, runs on
    '  TW03 = record class var Q: Int64; var A: Byte; end;'#10 +   // 1
    '  TW04 = record A: Byte; class var Q: Int64; var B: Byte; end;'#10 + // 2
    // GENERIC instantiations: the body is laid out with the parameters bound
    // to the actuals, so a parameter in any position -- a field, an array
    // element, a nested instantiation -- resolves.
    '  TGA<T> = record V: T; end;'#10 +
    '  TGB<T, U> = record V: T; W: U; end;'#10 +           // ONE group, 2 names
    '  TGC<T> = record V: array[0..2] of T; end;'#10 +
    '  TGD<T> = record V: TGA<T>; end;'#10 +               // nested, open arg
    '  TN01 = TGA<Integer>;'#10 +                          // 4
    '  TN02 = TGB<Byte, Int64>;'#10 +                      // 16
    '  TN03 = TGC<Integer>;'#10 +                          // 12
    '  TN04 = TGD<Int64>;'#10 +                            // 8
    '  TN05 = record X: Byte; F: TGA<Int64>; end;'#10 +    // 16
    // Old-style OBJECT types: fields lay out like a record from where the
    // ancestor ended, and a VMT pointer is appended -- pointer-aligned, but
    // without raising the type`s own alignment -- only where a virtual member
    // is INTRODUCED.
    '  TO01 = object A: Integer; end;'#10 +                // 4
    '  TO02 = object A: Byte; B: Int64; end;'#10 +         // 16
    '  TO03 = object(TO01) B: Integer; end;'#10 +          // 8
    '  TO04 = packed object A: Byte; B: Int64; end;'#10 +  // 9
    '  TO05 = object end;'#10 +                            // 0
    '  TO06 = record X: Byte; F: TO02; end;'#10 +          // 24
    // Still NOT modelled, and the guard is written so that a wrong answer of
    // any kind declares the type. An actual that IS an enclosing parameter is
    // carried through (TGD above); one that merely MENTIONS one inside a
    // compound is refused rather than half-substituted.
    '  TOpenG<T> = record V: TGA<TGA<T>>; end;'#10 +
    '  TArrF = TOpenG<Integer>;'#10 +
    '{$IF SizeOf(TR01) = 16}type M01 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TR03) = 8}type M03 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TR05) = 6}type M05 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TR06) = 8}type M06 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TR07) = 9}type M07 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TR08) = 16}type M08 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TR12) = 24}type M12 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TR13) = 4}type M13 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TR16) = 12}type M16 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TR19) = 8}type M19 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TR20) = 16}type M20 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TA1) = 9}type MA1 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TA2) = 10}type MA2 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TA4) = 12}type MA4 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TA16) = 16}type MA16 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TNest1) = 10}type MNest = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TS01) = 8}type MS01 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TS02) = 257}type MS02 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TS03) = 12}type MS03 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TS04) = 24}type MS04 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TS05) = 8}type MS05 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TS06) = 8}type MS06 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TS07) = 8}type MS07 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TS08) = 16}type MS08 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TSub) = 1}type MSub = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TB01) = 12}type MB01 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TB02) = 1024}type MB02 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TB03) = 20}type MB03 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TB04) = 20}type MB04 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TB05) = 24}type MB05 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TB06) = 24}type MB06 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TB07) = 5}type MB07 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TB08) = 9}type MB08 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TC01) = 16}type MC01 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TC02) = 4}type MC02 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TC03) = 16}type MC03 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TC04) = 10}type MC04 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TG01) = 1}type MG01 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TG02) = 2}type MG02 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TG03) = 4}type MG03 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TG04) = 5}type MG04 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TG05) = 32}type MG05 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TG06) = 1}type MG06 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TG07) = 7}type MG07 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TG08) = 2}type MG08 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TH01) = 5}type MH01 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(THO2) = 33}type MH02 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TV01) = 16}type MV01 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TV02) = 8}type MV02 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TV03) = 9}type MV03 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TV04) = 5}type MV04 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TV05) = 17}type MV05 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TV06) = 16}type MV06 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TV07) = 24}type MV07 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TV08) = 6}type MV08 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TV09) = 12}type MV09 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TKFile) = 24}type MKF = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TKFld) = 28}type MKFld = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TE01) = 2}type ME01 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TE02) = 2}type ME02 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TE03) = 4}type ME03 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TW01) = 0}type MC01x = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TW02) = 0}type MC02x = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TW03) = 1}type MC03x = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TW04) = 2}type MC04x = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TN01) = 4}type MN01 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TN02) = 16}type MN02 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TN03) = 12}type MN03 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TN04) = 8}type MN04 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TN05) = 16}type MN05 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TO01) = 4}type MO01 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TO02) = 16}type MO02 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TO03) = 8}type MO03 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TO04) = 9}type MO04 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TO05) = 0}type MO05 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TO06) = 24}type MO06 = class end;{$IFEND}'#10 +
    '{$IF SizeOf(TArrF) <> 0}type MArr = class end;{$IFEND}'#10 +
    'implementation'#10'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.ReportGuessedIfs := True;
    GProj.AnalyzeDirectory(LDir);
    var LLay := ModelByName('unitlayout');
    var LMissing := '';
    for var LM in ['m01', 'm03', 'm05', 'm06', 'm07', 'm08', 'm12', 'm13',
                   'm16', 'm19', 'm20', 'ma1', 'ma2', 'ma4', 'ma16', 'mnest'] do
      if SymCountOf(LLay, LM, skType) <> 1 then
        LMissing := LMissing + ' ' + LM;
    Ok('1.3.2 layout: all 16 dcc-measured record sizes reproduce (missing:' +
      LMissing + ')', LMissing = '');
    LMissing := '';
    for var LM in ['ms01', 'ms02', 'ms03', 'ms04', 'ms05', 'ms06', 'ms07',
                   'ms08', 'msub'] do
      if SymCountOf(LLay, LM, skType) <> 1 then
        LMissing := LMissing + ' ' + LM;
    Ok('1.3.2 layout: string/ShortString/string[N]/Variant/interface/class/' +
      'dynarray/method-pointer fields and a subrange type all size and ALIGN ' +
      'as measured (missing:' + LMissing + ')', LMissing = '');
    LMissing := '';
    for var LM in ['mb01', 'mb02', 'mb03', 'mb04', 'mb05', 'mb06', 'mb07',
                   'mb08', 'mc01', 'mc02', 'mc03', 'mc04'] do
      if SymCountOf(LLay, LM, skType) <> 1 then
        LMissing := LMissing + ' ' + LM;
    Ok('1.3.2 layout: static arrays -- subrange, Byte/enum/subrange-type and ' +
      'char-literal indices, both multi-dim spellings, record elements, and ' +
      'as fields (missing:' + LMissing + ')', LMissing = '');
    LMissing := '';
    for var LM in ['mg01', 'mg02', 'mg03', 'mg04', 'mg05', 'mg06', 'mg07',
                   'mg08', 'mh01', 'mh02'] do
      if SymCountOf(LLay, LM, skType) <> 1 then
        LMissing := LMissing + ' ' + LM;
    Ok('1.3.2 layout: SET sizes -- byte span, rounded to a power of two only ' +
      'while it fits a machine word, offset bases, and byte alignment ' +
      '(missing:' + LMissing + ')', LMissing = '');
    LMissing := '';
    for var LM in ['mv01', 'mv02', 'mv03', 'mv04', 'mv05', 'mv06', 'mv07',
                   'mv08', 'mv09'] do
      if SymCountOf(LLay, LM, skType) <> 1 then
        LMissing := LMissing + ' ' + LM;
    Ok('1.3.2 layout: VARIANT parts -- branch start, max-branch extent, a ' +
      'stored tag that does not raise the alignment, nesting and packing ' +
      '(missing:' + LMissing + ')', LMissing = '');
    Ok('1.3.2 layout: a FILE type is its TFileRec, and a file FIELD is '
      + 'pointer-aligned even though that record is packed',
      (SymCountOf(LLay, 'mkf', skType) = 1) and
      (SymCountOf(LLay, 'mkfld', skType) = 1));
    LMissing := '';
    for var LM in ['me01', 'me02', 'me03', 'mc01x', 'mc02x', 'mc03x',
                   'mc04x'] do
      if SymCountOf(LLay, LM, skType) <> 1 then
        LMissing := LMissing + ' ' + LM;
    Ok('1.3.2 layout: inline anonymous ENUMS (explicit values sized by the ' +
      'largest) and CLASS VAR sections, which run on and contribute neither ' +
      'size nor alignment (missing:' + LMissing + ')', LMissing = '');
    LMissing := '';
    for var LM in ['mn01', 'mn02', 'mn03', 'mn04', 'mn05'] do
      if SymCountOf(LLay, LM, skType) <> 1 then
        LMissing := LMissing + ' ' + LM;
    Ok('1.3.2 layout: GENERIC instantiations -- a parameter as a field, as an ' +
      'array element, across a two-name group, and passed on to a nested ' +
      'instantiation (missing:' + LMissing + ')', LMissing = '');
    LMissing := '';
    for var LM in ['mo01', 'mo02', 'mo03', 'mo04', 'mo05', 'mo06'] do
      if SymCountOf(LLay, LM, skType) <> 1 then
        LMissing := LMissing + ' ' + LM;
    Ok('1.3.2 layout: old-style OBJECT types -- ancestor storage, packing, ' +
      'an empty one, and as a field (missing:' + LMissing + ')',
      LMissing = '');
    Ok('1.3.2 layout: a compound actual over an OPEN parameter still refuses',
      (SymCountOf(LLay, 'marr', skType) = 0) and
      DiagHasText(LLay, 'PPIF', 'SizeOf(TArrF)'));
    Ok('1.3.2 layout: that refusal is the ONLY residual -- everything else in '
      + 'this fixture sized for real', DiagCount(LLay, 'PPIF') = 1);
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  // ---- dcc's ABORT RULES for a name that resolves NOWHERE (1.3.2 in the
  // spec). Every guard below is a direct transcription of a probe: the .dpr
  // was compiled with both branches printing a marker and RUN, on dcc64 36.0
  // and 37.0 alike. The verdict is NOT "False because we could not tell" --
  // dcc has a determined answer and these pin that we copy it. Each guard is
  // asserted by the EXISTENCE of the type it guards, so none can pass
  // vacuously, and the whole fixture must stay silent under ReportGuessedIfs:
  // a copied verdict is parity, not a finding. ----
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_ifabort');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitAbort.pas'),
    'unit UnitAbort;'#10'interface'#10 +
    // --- TRUE: the name sits in a numeric position, so dcc abandons the
    //     whole expression with True and everything wrapped around it is
    //     ignored.
    '{$IF NOWHERE > 1}'#10'type TAbortRel = class end;'#10'{$ENDIF}'#10 +
    '{$IF not (NOWHERE > 1)}'#10'type TAbortNot = class end;'#10'{$ENDIF}'#10 +
    '{$IF (NOWHERE > 1) and False}'#10 +
    'type TAbortAnd = class end;'#10'{$ENDIF}'#10 +
    '{$IF NOWHERE + 1 = 1}'#10'type TAbortAdd = class end;'#10'{$ENDIF}'#10 +
    '{$IF 1 shl NOWHERE = 2}'#10'type TAbortShl = class end;'#10'{$ENDIF}'#10 +
    // --- FALSE: a boolean position, a string comparison, or a dotted name.
    '{$IF NOWHERE}'#10'type TBareNo = class end;'#10'{$ENDIF}'#10 +
    '{$IF not NOWHERE}'#10'type TNotNo = class end;'#10'{$ENDIF}'#10 +
    '{$IF NOWHERE >= ''1.0''}'#10'type TStrNo = class end;'#10'{$ENDIF}'#10 +
    '{$IF NOWHERE.Member > 1}'#10'type TDotNo = class end;'#10'{$ENDIF}'#10 +
    // --- FALSE by SHORT-CIRCUIT: dcc goes left to right and never reaches
    //     the name, so the abort never happens. This is the guard that would
    //     break if the abort were applied bottom-up instead of in order.
    '{$IF Defined(NOPEDEF) and (NOWHERE > 1)}'#10 +
    'type TShortNo = class end;'#10'{$ENDIF}'#10 +
    'implementation'#10'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.ReportGuessedIfs := True;
    GProj.AnalyzeDirectory(LDir);
    var LAb := ModelByName('unitabort');
    Ok('1.3.2 abort: a nowhere-name in a RELATIONAL position takes the TRUE '
      + 'branch, like dcc', SymCountOf(LAb, 'tabortrel', skType) = 1);
    Ok('1.3.2 abort: ...and an enclosing `not` does not flip it',
      SymCountOf(LAb, 'tabortnot', skType) = 1);
    Ok('1.3.2 abort: ...nor does an `and False` after it',
      SymCountOf(LAb, 'tabortand', skType) = 1);
    Ok('1.3.2 abort: ARITHMETIC aborts to True too',
      (SymCountOf(LAb, 'tabortadd', skType) = 1) and
      (SymCountOf(LAb, 'tabortshl', skType) = 1));
    Ok('1.3.2 abort: a BARE boolean position stays False',
      (SymCountOf(LAb, 'tbareno', skType) = 0) and
      (SymCountOf(LAb, 'tnotno', skType) = 0));
    Ok('1.3.2 abort: a STRING comparison stays False',
      SymCountOf(LAb, 'tstrno', skType) = 0);
    Ok('1.3.2 abort: a DOTTED name stays False, never aborts',
      SymCountOf(LAb, 'tdotno', skType) = 0);
    Ok('1.3.2 abort: SHORT-CIRCUIT wins -- dcc never reaches the name, so no '
      + 'abort happens', SymCountOf(LAb, 'tshortno', skType) = 0);
    // A copied dcc verdict is parity, not a finding: eight of the nine guards
    // above go silent. The DOTTED one is the deliberate exception. dcc's own
    // answer there is either False (unknown prefix) or a hard E2003 (known
    // unit, missing member), so we could copy False -- but only if our
    // qualified-name resolution is right, and when it is wrong the cost is a
    // silently mis-taken branch instead of a visible question. Reporting is
    // the safer half of that trade, so the dot stays a finding on purpose.
    Ok('1.3.2 abort: copied verdicts are silent -- only the dotted name, kept '
      + 'as an honest unknown, still reports',
      (DiagCount(LAb, 'PPIF') = 1) and
      DiagHasText(LAb, 'PPIF', 'NOWHERE.Member'));
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  // ---- A `with` whose target is an INLINE VAR with an INFERRED type. The
  // symbol exists but carries no type node, so asking it yields nothing and
  // the with-scope never opened: every bare name in the body then reported as
  // undeclared. A plain `L.Count` stays SILENT in the same situation (an
  // unknown base type cannot be said to lack a member), which is what made
  // this look like a member-binding bug (Alcinoe.JSONDoc, 24 reports off one
  // `var LNodeList := InternalGetChildNodes;`). ----
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_inlinevar');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitInline.pas'),
    'unit UnitInline;'#10'interface'#10 +
    'type'#10 +
    '  TNodeList = class'#10 +
    '  public'#10 +
    '    FCount: Integer;'#10 +
    '    function Count: Integer;'#10 +
    '  end;'#10 +
    '  TOwner = class'#10 +
    '  public'#10 +
    '    function GetList: TNodeList;'#10 +
    '    procedure PInferred;'#10 +
    '    procedure PWritten;'#10 +
    '    procedure PCast;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'function TNodeList.Count: Integer; begin Result := FCount; end;'#10 +
    'function TOwner.GetList: TNodeList; begin Result := nil; end;'#10 +
    // The regression: no written type, so the type comes from the initializer.
    'procedure TOwner.PInferred;'#10'begin'#10 +
    '  var L := GetList;'#10 +
    '  with L do if Count > 0 then ;'#10'end;'#10 +
    // The same shape with the type spelled out -- worked before, must stay.
    'procedure TOwner.PWritten;'#10'begin'#10 +
    '  var L: TNodeList := GetList;'#10 +
    '  with L do if Count > 0 then ;'#10'end;'#10 +
    // An inferred var initialised by a CAST rather than a call: the
    // initializer goes through the same walk, so this comes along.
    'procedure TOwner.PCast;'#10'begin'#10 +
    '  var L := TNodeList(GetList);'#10 +
    '  with L do if Count > 0 then ;'#10'end;'#10 +
    'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.AnalyzeDirectory(LDir);
    var LIv := ModelByName('unitinline');
    Ok('with-target: an inline var with an INFERRED type opens its scope',
      DiagCount(LIv, 'E2003') = 0);
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  // ---- A source file that fails STRICT decoding. Delphi's TEncoding.UTF8
  // raises on a malformed sequence, and real sources carry them: one
  // Windows-1252 apostrophe sits in a `///` comment in Alcinoe's
  // Dynamic.Objects.pas and dcc compiles it without a murmur. The old
  // fallback re-decoded the whole buffer as ANSI FROM OFFSET ZERO, so the
  // BOM became text, the file no longer began with `unit`, and the model came
  // out EMPTY -- ~1700 false E2003 across every unit that imported it. ----
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_badbyte');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  begin
    var LSrc :=
      'unit UnitBad;'#10'interface'#10 +
      '/// the image@s EXIF orientation'#10 +
      'type TKept = class end;'#10 +
      'implementation'#10'end.'#10;
    var LBytes := TEncoding.UTF8.GetBytes(LSrc);
    // UTF-8 BOM in front, and the '@' turned into a lone $92 -- invalid UTF-8.
    for var LI := 0 to High(LBytes) do
      if LBytes[LI] = Ord('@') then
        LBytes[LI] := $92;
    TFile.WriteAllBytes(TPath.Combine(LDir, 'UnitBad.pas'),
      TBytes.Create($EF, $BB, $BF) + LBytes);
  end;
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.AnalyzeDirectory(LDir);
    var LBad := ModelByName('unitbad');
    Ok('encoding: a malformed UTF-8 byte does not destroy the unit -- the '
      + 'declaration after it is still there',
      SymCountOf(LBad, 'tkept', skType) = 1);
    // ...and it SAYS SO. Recovering quietly is what turned one bad byte into
    // ~1700 downstream reports with nothing in the log pointing back.
    Ok('encoding: the recovery is reported as PPENC, naming the encoding',
      (DiagCount(LBad, 'PPENC') = 1) and DiagHasText(LBad, 'PPENC', 'UTF-8'));
    Ok('encoding: PPENC labels as Warning (ours, recovered) while an internal '
      + 'pass failure labels as Error',
      (DiagSeverityLabel('PPENC') = 'Warning') and
      (DiagSeverityLabel('PPINT') = 'Error'));
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  // ---- The decode rule for a file with NO PREAMBLE (decided 2026-08-20; see
  // the DecodeBytes header). UTF-8 if the bytes are valid UTF-8, ANSI only if
  // they are not. This used to default to ANSI unconditionally, "because that
  // is what dcc does", and the cost was invisible: a 3-byte UTF-8 character
  // arrived as 3 characters, so every COLUMN on a line with non-ASCII text
  // before the identifier was off by the byte inflation. Navigation landed
  // beside the name, or inside the preceding string literal, and nothing
  // reported it. Asserted on the decoded string rather than through the
  // analysis, because the string IS the rule - a column assertion downstream
  // would pass or fail for several different reasons. ----
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_decode_rule');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  try
    // Every string here is spelled with explicit CHARACTER CODES and every
    // byte with explicit BYTE VALUES, deliberately: this file has no BOM
    // either, so a literal `Привет` in this source would be read by dcc under
    // the very rule under test, and the test would then assert against
    // whatever the compiler happened to decode. Codes make it independent of
    // that. #$041F.. is 'Privet' in Cyrillic - 6 characters, 12 UTF-8 bytes,
    // which is the gap between the two rules.
    const cCyr = #$041F#$0440#$0438#$0432#$0435#$0442;
    var LText := 'begin Writeln(''' + cCyr + '''); end.'#10;
    var LNoBom := TPath.Combine(LDir, 'nobom.pas');
    TFile.WriteAllBytes(LNoBom, TEncoding.UTF8.GetBytes(LText));
    Ok('decode: a preamble-less file whose bytes are valid UTF-8 decodes as '
      + 'UTF-8, so a column after non-ASCII text is where the editor sees it',
      TPasSourceManager.LoadFileTolerant(LNoBom) = LText);

    // Same text, same absence of a BOM, but genuinely Windows-1251 bytes -
    // $C0 followed by $F0 is not a legal UTF-8 sequence, so this file is NOT
    // valid UTF-8. The old rule read every file this way; the new one still
    // reads THIS one this way, which is the whole point of the fallback.
    var LAnsi := TPath.Combine(LDir, 'ansi.pas');
    var LAnsiBytes := TEncoding.ASCII.GetBytes('begin Writeln(''')
      + TBytes.Create($CF, $F0, $E8, $E2, $E5, $F2)
      + TEncoding.ASCII.GetBytes('''); end.'#10);
    TFile.WriteAllBytes(LAnsi, LAnsiBytes);
    Ok('decode: a preamble-less file that is NOT valid UTF-8 still decodes '
      + 'as ANSI, so a 1251 source is not turned into U+FFFD',
      TPasSourceManager.LoadFileTolerant(LAnsi) =
        TEncoding.ANSI.GetString(LAnsiBytes));

    // A declared encoding still wins, and the preamble is still not content -
    // the bug that once cost ~1700 false E2003 (see the case above).
    var LBom := TPath.Combine(LDir, 'bom.pas');
    TFile.WriteAllBytes(LBom,
      TBytes.Create($EF, $BB, $BF) + TEncoding.UTF8.GetBytes(LText));
    Ok('decode: a UTF-8 BOM is honored and does not become text',
      TPasSourceManager.LoadFileTolerant(LBom) = LText);

    // Pure ASCII is valid UTF-8 and decodes identically under either rule,
    // which is why this change is a superset rather than a new policy for the
    // overwhelming majority of sources.
    var LAscii := TPath.Combine(LDir, 'ascii.pas');
    TFile.WriteAllBytes(LAscii, TEncoding.ASCII.GetBytes('unit A; end.'#10));
    Ok('decode: an ASCII file is unaffected by the rule change',
      TPasSourceManager.LoadFileTolerant(LAscii) = 'unit A; end.'#10);

  finally
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  // ---- ...and the ANSI reading must happen SILENTLY. PPENC means "the
  // recovered text may not be what the author wrote"; a preamble-less file
  // landing on ANSI is the RULE rather than a recovery, and loses nothing, so
  // it must not report. Reporting it anyway was the first attempt at the rule
  // above, and it put 10 warnings on a 197-unit closure for files that had been
  // read perfectly - nine SynEdit units and the RTL's System.DateUtils, every
  // one of them tripping over a Latin-1 letter in a copyright header. A
  // diagnostics list that names correct readings as problems stops being
  // read. ----
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_ansi_quiet');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  begin
    // 'Ma<EB>l' - Latin-1, no BOM, and $EB followed by 'l' is not legal UTF-8:
    // byte for byte the shape of the SynEdit copyright headers.
    var LBytes := TEncoding.ASCII.GetBytes(
        'unit UnitAnsi;'#10'interface'#10'// (c) Ma')
      + TBytes.Create($EB)
      + TEncoding.ASCII.GetBytes(
        'l'#10'type TAlso = class end;'#10'implementation'#10'end.'#10);
    TFile.WriteAllBytes(TPath.Combine(LDir, 'UnitAnsi.pas'), LBytes);
  end;
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.AnalyzeDirectory(LDir);
    var LQuiet := ModelByName('unitansi');
    Ok('encoding: an ANSI file with no BOM parses, declarations intact',
      SymCountOf(LQuiet, 'talso', skType) = 1);
    Ok('encoding: and reports NO PPENC - reading it as ANSI is the rule, not '
      + 'a recovery, and nothing was lost',
      DiagCount(LQuiet, 'PPENC') = 0);
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  // ---- ReleaseTransientMaps (MEMORY-AUDIT 6.4-4, stage 1): a host opt-in
  // that frees the post-analysis dead weight of every unit it is NOT editing.
  // The kept ("open editor") model keeps everything; the released one keeps
  // its navigation state (RefMap/ExtRefMap/Symbols) and drops only the maps
  // nothing reads for a closed unit; any later Analyze* must refuse LOUDLY
  // (the freed arrays are indexed unguarded by the cross passes, and with
  // range checks off the silent alternative is a wrong analysis). ----
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_release');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitRA.pas'),
    'unit UnitRA;'#10'interface'#10 +
    'type TR = record V: Integer; end;'#10 +
    'function FA: Integer;'#10 +
    'implementation'#10 +
    'function FA: Integer; begin Result := 1 + 2; end;'#10'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitRB.pas'),
    'unit UnitRB;'#10'interface'#10'uses UnitRA;'#10 +
    'var GR: TR;'#10'implementation'#10 +
    'procedure PB;'#10'begin'#10'  GR.V := FA;'#10'end;'#10'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.AnalyzeDirectory(LDir);
    var LKeepMid := MidByName('unitrb');
    var LRelMid := MidByName('unitra');
    Ok('release: both models carry ExprType before the call',
      (Length(GProj.Model(LKeepMid).ExprType) > 0) and
      (Length(GProj.Model(LRelMid).ExprType) > 0));
    GProj.ReleaseTransientMaps([GProj.ModelFile(LKeepMid)]);
    Ok('release: the kept (open-editor) model keeps its maps',
      Length(GProj.Model(LKeepMid).ExprType) > 0);
    Ok('release: a released model drops ExprType/ExprTypeX/WithUnopened',
      (GProj.Model(LRelMid).ExprType = nil) and
      (GProj.Model(LRelMid).ExprTypeX.Count = 0) and
      (GProj.Model(LRelMid).WithUnopened = nil));
    Ok('release: navigation state survives - RefMap, ExtRefMap and symbols',
      (Length(GProj.Model(LRelMid).RefMap) > 0) and
      (GProj.Model(LRelMid).SymCount > 0));
    var LRaised := False;
    try
      GProj.AnalyzeDirectory(LDir);
    except
      on EInvalidOperation do
        LRaised := True;
    end;
    Ok('release: a later Analyze* refuses loudly (EInvalidOperation), never '
      + 'indexes the freed maps', LRaised);
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  // ---- Text demotion + on-demand rehydration (MEMORY-AUDIT 6.4-4 stage 2).
  // Demote frees the whole token layer of a closed unit; navigation into it
  // then transparently rehydrates (re-preprocess, identity-checked); a file
  // that CHANGED after demotion refuses to rehydrate - no positions rather
  // than wrong ones. ----
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_demote');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitDA.pas'),
    'unit UnitDA;'#10'interface'#10 +
    'type TD = class'#10'  procedure M;'#10'end;'#10 +
    'implementation'#10 +
    'procedure TD.M; begin end;'#10'end.'#10);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitDB.pas'),
    'unit UnitDB;'#10'interface'#10'uses UnitDA;'#10 +
    'var GD: TD;'#10'implementation'#10 +
    'procedure PD;'#10'begin'#10'  GD.M;'#10'end;'#10'end.'#10);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.AnalyzeDirectory(LDir);
    var LDaMid := MidByName('unitda');
    var LDbMid := MidByName('unitdb');
    var LDa := GProj.Model(LDaMid);
    // The symbol indices we assert against, found BEFORE any demotion.
    var LTdSym := NIL_SYM;
    var LMSym := NIL_SYM;
    for var LS := 0 to LDa.SymCount - 1 do
      if (LDa.Symbols[LS].NameLower = 'td') and
         (LDa.Symbols[LS].Kind = skType) then
        LTdSym := LS
      else if (LDa.Symbols[LS].NameLower = 'm') and
              (LDa.Symbols[LS].Kind = skRoutine) and (LMSym = NIL_SYM) then
        LMSym := LS;
    Ok('demote: fixture symbols found', (LTdSym <> NIL_SYM) and
      (LMSym <> NIL_SYM));
    Ok('demote: head word is readable before (procedure)',
      LDa.RoutineHead(LMSym) = rhProcedure);
    GProj.DemoteClosedUnits([GProj.ModelFile(LDbMid)]);
    Ok('demote: the closed unit lost its text layer',
      LDa.Demoted and (LDa.Tree.Source.Visible = nil) and
      (LDa.Tree.Source.Files[0].Tokens = nil) and
      (LDa.Tree.Source.Files[0].Source = ''));
    Ok('demote: the kept unit did not',
      not GProj.Model(LDbMid).Demoted);
    Ok('demote: the routine head survives from the snapshot',
      LDa.RoutineHead(LMSym) = rhProcedure);
    // Navigation still answers (the hits live in the KEPT unit's ExtRefMap;
    // a demoted unit that holds a hit rehydrates lazily inside the scan).
    var LNav := TPasNavigator.Create(GProj);
    var LHitsBefore := 0;
    try
      var LHits := LNav.FindReferences(LDaMid, LTdSym);
      LHitsBefore := Length(LHits);
      Ok('demote: Find References still answers, with positions and snippets',
        (LHitsBefore > 0) and (LHits[0].Line > 0) and (LHits[0].Snippet <> ''));
    finally
      LNav.Free;
    end;
    // Explicit rehydration restores the full text layer, identity-checked.
    Ok('demote: EnsureHydrated restores the text layer',
      GProj.EnsureHydrated(LDaMid) and not LDa.Demoted and
      (Length(LDa.Tree.Source.Visible) > 0) and
      (LDa.Tree.Source.Files[0].LineText(1) <> ''));
    // Stale file: demote again, then CHANGE the file - rehydration must
    // refuse, and the askers degrade to nothing instead of lying.
    GProj.DemoteClosedUnits([GProj.ModelFile(LDbMid)]);
    Ok('demote: a second demotion works', LDa.Demoted);
    TFile.WriteAllText(TPath.Combine(LDir, 'UnitDA.pas'),
      'unit UnitDA;'#10'interface'#10 +
    'type TD = class'#10'  procedure MRenamedLonger;'#10'end;'#10 +
      'implementation'#10 +
      'procedure TD.MRenamedLonger; begin end;'#10'end.'#10);
    Ok('demote: a CHANGED file refuses to rehydrate',
      not GProj.EnsureHydrated(LDaMid) and LDa.Demoted);
    LNav := TPasNavigator.Create(GProj);
    try
      var LHits := LNav.FindReferences(LDaMid, LTdSym);
      var LOnlyKept := True;
      for var LH := 0 to High(LHits) do
        if not SameText(TPath.GetFileName(LHits[LH].FilePath), 'UnitDB.pas')
        then
          LOnlyKept := False;
      Ok('demote: hits then come ONLY from still-hydrated units - the stale '
        + 'unit contributes none rather than wrong ones',
        (Length(LHits) <= LHitsBefore) and LOnlyKept);
    finally
      LNav.Free;
    end;
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  if GCounter.Finish('SemaProjectSmoke') then
    ExitCode := 1;
end.
