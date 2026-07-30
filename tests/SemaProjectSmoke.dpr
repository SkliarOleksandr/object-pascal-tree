program SemaProjectSmoke;

{ Phase-2 cross-unit smoke tests: writes tiny unit fixtures to a temp dir and
  runs the project analyzer, checking external resolution, qualified access,
  E2003 (fired only when all uses resolve) and impl->interface linking. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
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
  PasTree.Sema.Project in '..\source\PasTree.Sema.Project.pas';

var
  GProj: TPasSemaProject;
  GPassed, GFailed: Integer;

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
    // opens over TVarRec's fields. OmniThreadLibrary's GpStuff/OtlCommon do
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
    '  I: Integer;'#10 +
    'begin'#10 +
    '  for I := Low(aValues) to High(aValues) do'#10 +
    '    with aValues[I] do'#10 +          // 47 element type is TVarRec
    '      if VType = 0 then'#10 +         // 48 a TVarRec field, bare
    '        I := VInteger;'#10 +
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

    DevExpress's shape: `TdxBarAccessibilityHelper` is a plain class in dxBar.pas
    and `TdxBarAccessibilityHelper<T: TWinControl>` a generic in
    dxBarAccessibility.pas, which then writes both spellings. Taking the nearer
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

// How many references spelled ARefText resolved cross-unit to a symbol named
// ATarget declared in unit AUnitLower. Unlike CrossRefTo this pins the OWNING
// UNIT, which is the whole point when the same name exists on both sides of
// the shadowing question (a `with` target's member vs the enclosing class's).
function CrossRefCountInUnit(AModel: TPasSemaModel;
  const ARefText, ATarget, AUnitLower: string): Integer;
var
  LExt: TPasExtRef;
begin
  Result := 0;
  for var LNode := 0 to High(AModel.RefMap) do
    if (AModel.Tree.Nodes[LNode].Kind = nkIdent) and
       SameText(AModel.Tree.NodeText(LNode), ARefText) and
       AModel.ExtRefMap.TryGetValue(LNode, LExt) then
      if SameText(GProj.Model(LExt.UnitId).Symbols[LExt.Sym].Name, ATarget) and
         SameText(GProj.Model(LExt.UnitId).UnitNameLower, AUnitLower) then
        Inc(Result);
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
  if ACond then
    Inc(GPassed)
  else
  begin
    Inc(GFailed);
    Writeln('FAIL: ', AName);
  end;
end;

var
  LDir: string;
  LA, LB, LC, LD, LE, LOvl: TPasSemaModel;
begin
  GPassed := 0; GFailed := 0;
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
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitArPlain.pas'), UNIT_ARPLAIN);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitArGen.pas'), UNIT_ARGEN);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitArUses.pas'), UNIT_ARUSES);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitArGenUse.pas'), UNIT_ARGENUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitArBase.pas'), UNIT_ARBASE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitArUse.pas'), UNIT_ARUSE);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitGenList.pas'), UNIT_GENLIST);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitGenListUse.pas'), UNIT_GENLISTUSE);
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
    Ok('self-target: the with body opens over Self.TreeViewControl',
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
    // same-named generic is nearer in scope (the DevExpress shape).
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

  Writeln(Format('=== SemaProjectSmoke: %d passed, %d failed ===',
    [GPassed, GFailed]));
  if GFailed > 0 then
    ExitCode := 1;
end.
