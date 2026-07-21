program SemaNavSmoke;

{ Go-to-declaration smoke tests: fixture units in a temp dir, then IdentAt +
  ResolveDecl checks — same-unit locals, cross-unit types, cross-unit MEMBER
  access (Phase-3c discovered refs), a builtin name a used unit actually
  declares (the TBytes/SysUtils shape), the IMPLICIT System unit (TObject/
  TArray<T> — real declarations, never in any UsesList), the implicit Result,
  and pure builtins (no target). }

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
  PasTree.Sema.Project in '..\source\PasTree.Sema.Project.pas',
  PasTree.Sema.Nav in '..\source\PasTree.Sema.Nav.pas';

const
  // Line/col layout matters: the checks below address exact positions.
  UNIT_A =
    'unit NavA;'#10 +                          // 1
    'interface'#10 +                           // 2
    'type'#10 +                                // 3
    '  TThing = record'#10 +                   // 4  TThing at col 3
    '    Value: Integer;'#10 +                 // 5  Value at col 5
    '  end;'#10 +                              // 6
    'function MakeThing: TThing;'#10 +         // 7
    'implementation'#10 +                      // 8
    'function MakeThing: TThing;'#10 +         // 9
    'begin Result.Value := 1; end;'#10 +       // 10
    'end.'#10;                                 // 11

  // Declares TBytes — a name ALSO seeded as a compiler builtin. A reference to
  // it in NavB resolves locally to the builtin (no DeclNode); the used-unit
  // fallback must find THIS declaration. Mirrors TBytes / System.SysUtils.
  UNIT_C =
    'unit NavC;'#10 +                          // 1
    'interface'#10 +                           // 2
    'type'#10 +                                // 3
    '  TBytes = record'#10 +                   // 4  TBytes at col 3
    '    Len: Integer;'#10 +                   // 5
    '  end;'#10 +                              // 6
    'implementation'#10 +                      // 7
    'end.'#10;                                 // 8

  // A fixture for the IMPLICIT `System` unit — NEVER named in any `uses`
  // clause (that's the whole point: every unit uses it without saying so),
  // yet TObject/TArray<T> below are REAL declarations PasTree.Sema.Nav must
  // find via TPasSemaProject.EnsureSystemUnit. Mirrors real System.pas.
  // TObject.Free exercises the MEMBER fallback: the synthetic builtin
  // TObject symbol has no MemberScope, so FindMemberX must redirect to
  // THIS real class body to resolve `.Free` at all (see FindMemberX's
  // ResolveRealDecl call for the "builtin, nowhere to go" case).
  // SYS_MARK exercises a QUALIFIED EXPRESSION into the implicit unit
  // (`System.SYS_MARK`, not a `uses` item) — distinct from TObject/TArray
  // above, whose OWN NAME already resolves locally to a compiler-seeded
  // builtin; SYS_MARK isn't seeded at all, so it's a genuinely unresolved
  // local reference until CrossResolve's UnitNameOf fallback kicks in.
  UNIT_SYS =
    'unit System;'#10 +                        // 1
    'interface'#10 +                           // 2
    'const'#10 +                               // 3
    '  SYS_MARK = 777;'#10 +                   // 4  SYS_MARK col 3
    'type'#10 +                                // 5
    '  TArray<T> = array of T;'#10 +           // 6  TArray col 3
    '  TObject = class'#10 +                   // 7  TObject col 3
    '    constructor Create;'#10 +              // 8
    '    procedure Free;'#10 +                  // 9  Free col 15
    '  end;'#10 +                              // 10
    'implementation'#10 +                      // 11
    'constructor TObject.Create;'#10 +          // 12
    'begin'#10 +                               // 13
    'end;'#10 +                                // 14
    'procedure TObject.Free;'#10 +              // 15
    'begin'#10 +                               // 16
    'end;'#10 +                                // 17
    'end.'#10;                                 // 18

  // A DOTTED (namespaced) unit name, to exercise go-to-declaration on a
  // multi-segment `uses` reference (any segment clicked -> the SAME unit).
  UNIT_NS =
    'unit Namespace.NavD;'#10 +                // 1  Namespace col 6
    'interface'#10 +                           // 2
    'const NSD_MARK = 99;'#10 +                // 3
    'implementation'#10 +                      // 4
    'end.'#10;                                 // 5

  // Inherited-member / intrinsic / anon-param / except-var / nested-class
  // fixtures (the false-E2003 taxonomy found on the real demo project).
  UNIT_G =
    'unit NavG;'#10 +                          // 1
    'interface'#10 +                           // 2
    'type'#10 +                                // 3
    '  TIntProc = reference to procedure(AValue: Integer);'#10 + // 4
    '  TAncestor = class'#10 +                 // 5
    '    FStock: Integer;'#10 +                // 6   FStock col 5
    '    procedure Ping;'#10 +                 // 7   Ping col 15
    '  end;'#10 +                              // 8
    '  TOuterX = class'#10 +                   // 9
    '  type'#10 +                              // 10
    '    TInnerX = class'#10 +                 // 11
    '      FIn: Integer;'#10 +                 // 12  FIn col 7
    '      procedure Zap;'#10 +                // 13
    '    end;'#10 +                            // 14
    '  end;'#10 +                              // 15
    'implementation'#10 +                      // 16
    'procedure TAncestor.Ping;'#10 +           // 17
    'begin'#10 +                               // 18
    'end;'#10 +                                // 19
    'procedure TOuterX.TInnerX.Zap;'#10 +      // 20
    'begin'#10 +                               // 21
    '  FIn := 1;'#10 +                         // 22  FIn col 3
    'end;'#10 +                                // 23
    'end.'#10;                                 // 24
  UNIT_H =
    'unit NavH;'#10 +                          // 1
    'interface'#10 +                           // 2
    'uses NavG;'#10 +                          // 3
    'type'#10 +                                // 4
    '  TChild = class(TAncestor)'#10 +         // 5
    '    procedure Poke;'#10 +                 // 6
    '  end;'#10 +                              // 7
    'implementation'#10 +                      // 8
    'procedure TChild.Poke;'#10 +              // 9
    'var'#10 +                                 // 10
    '  L: Integer;'#10 +                       // 11
    '  F: TIntProc;'#10 +                      // 12
    'begin'#10 +                               // 13
    '  FStock := MaxInt;'#10 +                 // 14  FStock col 3, MaxInt col 13
    '  Ping;'#10 +                             // 15  Ping col 3
    '  F := procedure(AVal: Integer)'#10 +     // 16  AVal col 18
    '    begin'#10 +                           // 17
    '      L := AVal;'#10 +                    // 18  AVal col 12
    '    end;'#10 +                            // 19
    '  F(L);'#10 +                             // 20
    '  try'#10 +                               // 21
    '    L := 0;'#10 +                         // 22
    '  except'#10 +                            // 23
    '    on E: TObject do L := Ord(L);'#10 +   // 24  E col 8
    '  end;'#10 +                              // 25
    'end;'#10 +                                // 26
    'end.'#10;                                 // 27

  // Declaration <-> implementation toggle fixtures (Ctrl+Shift+Down/Up):
  // overloaded methods (arity disambiguation), a nested class's qualified
  // impl, a global forward decl, and a NESTED local proc's forward decl —
  // matched to its impl WITHIN the same enclosing routine only.
  UNIT_I =
    'unit NavI;'#10 +                              // 1
    'interface'#10 +                               // 2
    'type'#10 +                                    // 3
    '  TCalc = class'#10 +                          // 4
    '    function Add(A: Integer): Integer;'#10 +  // 5  1-param decl
    '    function Add(A, B: Integer): Integer; overload;'#10 + // 6  2-param
    '  type'#10 +                                   // 7
    '    TInner = class'#10 +                       // 8
    '      procedure Zap;'#10 +                     // 9  nested-class decl
    '    end;'#10 +                                 // 10
    '  end;'#10 +                                   // 11
    'procedure GProc(X: Integer); forward;'#10 +    // 12  global fwd decl
    'implementation'#10 +                           // 13
    'function TCalc.Add(A: Integer): Integer;'#10 + // 14
    'begin'#10 +                                    // 15
    '  Result := A;'#10 +                            // 16  <- 1-param target
    'end;'#10 +                                      // 17
    'function TCalc.Add(A, B: Integer): Integer;'#10 + // 18
    'begin'#10 +                                       // 19
    '  Result := A + B;'#10 +                          // 20  <- 2-param target
    'end;'#10 +                                        // 21
    'procedure TCalc.TInner.Zap;'#10 +                  // 22  nested-class impl
    'begin'#10 +                                        // 23  <- empty body:
    'end;'#10 +                                         // 24     target lands here
    'procedure GProc(X: Integer);'#10 +                 // 25
    'begin'#10 +                                        // 26
    '  X := X + 1;'#10 +                                // 27  <- fwd-decl target
    'end;'#10 +                                         // 28
    'procedure Outer;'#10 +                             // 29
    '  procedure Inner(Y: Integer); forward;'#10 +      // 30  nested fwd decl
    '  procedure Helper;'#10 +                          // 31  no decl of its own
    '  begin'#10 +                                      // 32
    '    Inner(1);'#10 +                                // 33
    '  end;'#10 +                                       // 34
    '  procedure Inner(Y: Integer);'#10 +               // 35
    '  begin'#10 +                                      // 36
    '    Helper;'#10 +                                  // 37  <- nested target
    '  end;'#10 +                                       // 38
    'begin'#10 +                                        // 39
    '  Helper;'#10 +                                    // 40
    'end;'#10 +                                         // 41
    'end.'#10;                                          // 42

  // Overloads sharing the SAME ARITY but different parameter TYPES — the
  // real bug report (System.SysUtils.AnsiCompareFileName's actual overload
  // set): count-only matching collided all three onto one bucket, and
  // which one "won" depended on the position index's span-size sort order,
  // not which one the user clicked. Also covers a body containing ONLY A
  // COMMENT (no statements at all, same as a truly empty body structurally
  // — PasTree drops comments before the AST) landing on the comment's own
  // line, not jumping past it to `end`.
  UNIT_J =
    'unit NavJ;'#10 +                                       // 1
    'interface'#10 +                                        // 2
    'function Cmp(const S1: PChar; L1: Integer; const S2: PChar;'#10 + // 3
    '  L2: Integer; CVC: Boolean = False): Integer; overload; forward;'#10 + // 4  5 params (PChar)
    'function Cmp(const S1: string; L1: Integer; const S2: string;'#10 + // 5
    '  L2: Integer; CVC: Boolean = False): Integer; overload; forward;'#10 + // 6  5 params (string) — SAME arity as above
    'function Cmp(const S1, S2: string; CVC: Boolean = False): Integer;'#10 + // 7  3 params
    '  overload; forward;'#10 +                             // 8
    'implementation'#10 +                                   // 9
    'function Cmp(const S1: PChar; L1: Integer; const S2: PChar;'#10 + // 10
    '  L2: Integer; CVC: Boolean): Integer;'#10 +           // 11
    'begin'#10 +                                             // 12
    '  Result := 1;'#10 +                                    // 13  <- PChar-overload target
    'end;'#10 +                                              // 14
    'function Cmp(const S1: string; L1: Integer; const S2: string;'#10 + // 15
    '  L2: Integer; CVC: Boolean): Integer;'#10 +           // 16
    'begin'#10 +                                             // 17
    '  Result := 2;'#10 +                                    // 18  <- string-overload target
    'end;'#10 +                                              // 19
    'function Cmp(const S1, S2: string; CVC: Boolean): Integer;'#10 + // 20
    'begin'#10 +                                             // 21
    '  // only a comment, no statement at all'#10 +          // 22  <- lands HERE, not on `end`
    'end;'#10 +                                              // 23
    'end.'#10;                                              // 24

  // Real bug report: go-to-impl/decl must NEVER cross from/to an INACTIVE
  // ($IFDEF'd-out) region — mirrors the actual System.SysUtils.CharInSet
  // shape (two overloads active under $IFNDEF NEXTGEN, two more inactive
  // under $ELSE, same routine NAME reused in both branches). pfWin32 never
  // defines NEXTGEN, so lines 4-5/12-19 are ACTIVE and 7-8/21-28 are the
  // dead $ELSE branch, which the parser never even builds AST nodes for.
  UNIT_K =
    'unit NavK;'#10 +                                  // 1
    'interface'#10 +                                   // 2
    '{$IFNDEF NEXTGEN}'#10 +                            // 3
    'function Zig(C: AnsiChar): Boolean; overload; forward;'#10 + // 4  ACTIVE
    'function Zig(C: WideChar): Boolean; overload; forward;'#10 + // 5  ACTIVE
    '{$ELSE}'#10 +                                      // 6
    'function Zig(C: Byte): Boolean; overload; forward;'#10 +    // 7  INACTIVE
    'function Zig(C: Char): Boolean; overload; forward;'#10 +    // 8  INACTIVE
    '{$ENDIF}'#10 +                                     // 9
    'implementation'#10 +                               // 10
    '{$IFNDEF NEXTGEN}'#10 +                            // 11
    'function Zig(C: AnsiChar): Boolean;'#10 +          // 12  ACTIVE
    'begin'#10 +                                        // 13
    '  Result := True;'#10 +                            // 14  <- AnsiChar target
    'end;'#10 +                                          // 15
    'function Zig(C: WideChar): Boolean;'#10 +          // 16  ACTIVE
    'begin'#10 +                                        // 17
    '  Result := True;'#10 +                            // 18  <- WideChar target
    'end;'#10 +                                          // 19
    '{$ELSE}'#10 +                                       // 20
    'function Zig(C: Byte): Boolean;'#10 +              // 21  INACTIVE
    'begin'#10 +                                        // 22
    '  Result := True;'#10 +                            // 23  dead code
    'end;'#10 +                                          // 24
    'function Zig(C: Char): Boolean;'#10 +              // 25  INACTIVE
    'begin'#10 +                                        // 26
    '  Result := True;'#10 +                            // 27  dead code
    'end;'#10 +                                          // 28
    '{$ENDIF}'#10 +                                      // 29
    'end.'#10;                                          // 30

  // Overload-PRECISE go-to-declaration: clicking the callee of a call must
  // land on the ARGUMENT-MATCHED overload's declaration (CallTargetX /
  // CallTarget), not on whichever overload heads the name-resolution chain.
  UNIT_OVL =
    'unit NavOvl;'#10 +                                          // 1
    'interface'#10 +                                             // 2
    'function Pick(A: Integer): Integer; overload;'#10 +         // 3  Pick col 10
    'function Pick(A: Double): Double; overload;'#10 +           // 4  Pick col 10
    'implementation'#10 +                                        // 5
    'function Pick(A: Integer): Integer; begin Result := A; end;'#10 + // 6
    'function Pick(A: Double): Double; begin Result := A; end;'#10 +   // 7
    'end.'#10;                                                   // 8
  UNIT_OVLUSE =
    'unit NavOvlUse;'#10 +                                       // 1
    'interface'#10 +                                             // 2
    'uses NavOvl;'#10 +                                          // 3
    'type'#10 +                                                  // 4
    '  TCup = class'#10 +                                        // 5
    '    function Fill(A: Integer): Integer; overload;'#10 +     // 6  Fill col 14
    '    function Fill(A: string): string; overload;'#10 +       // 7  Fill col 14
    '  end;'#10 +                                                // 8
    'implementation'#10 +                                        // 9
    'function TCup.Fill(A: Integer): Integer; begin Result := A; end;'#10 + // 10
    'function TCup.Fill(A: string): string; begin Result := A; end;'#10 +  // 11
    'procedure Use;'#10 +                                        // 12
    'var'#10 +                                                   // 13
    '  C: TCup;'#10 +                                            // 14  C col 3
    '  LI: Integer;'#10 +                                        // 15
    '  LD: Double;'#10 +                                         // 16
    '  LS: string;'#10 +                                         // 17
    'begin'#10 +                                                 // 18
    '  LI := Pick(11);'#10 +                                     // 19  Pick col 9
    '  LD := Pick(2.5);'#10 +                                    // 20  Pick col 9
    '  LI := C.Fill(7);'#10 +                                    // 21  Fill col 11
    '  LS := C.Fill(''x'');'#10 +                                // 22  Fill col 11
    'end;'#10 +                                                  // 23
    'end.'#10;                                                   // 24

  // AnalyzeProject fixtures: a main program whose closure pulls NavB (and
  // through it everything above) TRANSITIVELY; NavE is reachable only via a
  // unit-scope NAMESPACE (uses NavE + namespaces=['Wide'] -> Wide.NavE.pas);
  // OldNavF only via a unit ALIAS (OldNavF=NavF).
  UNIT_MAIN =
    'program NavMain;'#10 +                    // 1
    'uses NavB, NavE, OldNavF;'#10 +           // 2  NavE col 12, OldNavF col 18
    'begin'#10 +                               // 3
    'end.'#10;                                 // 4
  UNIT_E =
    'unit Wide.NavE;'#10 +                     // 1
    'interface'#10 +                           // 2
    'implementation'#10 +                      // 3
    'end.'#10;                                 // 4
  UNIT_F =
    'unit NavF;'#10 +                          // 1
    'interface'#10 +                           // 2
    'implementation'#10 +                      // 3
    'end.'#10;                                 // 4

  UNIT_B =
    'unit NavB;'#10 +                          // 1
    'interface'#10 +                           // 2
    'uses NavA, NavC, Namespace.NavD;'#10 +    // 3  (NOT System — implicit)
    'var GT: TThing;'#10 +                     // 4  GT col 5, TThing col 9
    'implementation'#10 +                      // 5
    'procedure P;'#10 +                        // 6
    'var'#10 +                                 // 7
    '  L: Integer;'#10 +                       // 8  Integer col 6
    '  B: TBytes;'#10 +                        // 9  TBytes col 6
    '  O: TObject;'#10 +                       // 10  TObject col 6
    '  A: TArray<Integer>;'#10 +               // 11  TArray col 6
    'begin'#10 +                               // 12
    '  L := GT.Value;'#10 +                    // 13  GT col 8, Value col 11
    '  O.Free;'#10 +                           // 14  Free col 5
    '  L := System.SYS_MARK;'#10 +             // 15  System col 8, SYS_MARK col 15
    '  L := Namespace.NavD.NSD_MARK;'#10 +     // 16  Namespace col 8, NavD col 18,
                                                //     NSD_MARK col 23
    'end;'#10 +                                // 17
    'function GetLen: Integer;'#10 +           // 18  GetLen col 10
    'begin'#10 +                               // 19
    '  Result := 0;'#10 +                      // 20  Result col 3
    'end;'#10 +                                // 21
    'end.'#10;                                 // 22

var
  GProj: TPasSemaProject;
  GNav: TPasNavigator;
  GPassed, GFailed: Integer;
  GMidB: Integer;

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

function DiagCount(AModel: TPasSemaModel; const ACode: string): Integer;
var
  LIdx: Integer;
begin
  Result := 0;
  for LIdx := 0 to High(AModel.Diags) do
    if AModel.Diags[LIdx].Code = ACode then
      Inc(Result);
end;

// IdentAt + ResolveDecl in one step.
procedure CheckNav(const ACase: string; ALine, ACol: Integer;
  const AWantIdent, AWantFile: string; AWantLine, AWantCol: Integer);
var
  LIdent: TPasNavIdent;
  LTarget: TPasNavTarget;
begin
  if not GNav.IdentAt(GMidB, ALine, ACol, {out} LIdent) then
  begin
    Ok(ACase + ': IdentAt', False);
    Exit;
  end;
  Ok(ACase + ': ident name', SameText(LIdent.Name, AWantIdent));
  if not GNav.ResolveDecl(GMidB, LIdent.Node, {out} LTarget) then
  begin
    Ok(ACase + ': ResolveDecl', False);
    Exit;
  end;
  Ok(ACase + ': target file',
    SameText(TPath.GetFileName(LTarget.FilePath), AWantFile));
  Ok(ACase + ': target pos',
    (LTarget.Line = AWantLine) and (LTarget.Col = AWantCol));
end;

// Declaration -> implementation: cursor at (ALine,ACol), expect the body's
// first-statement (or empty-body fallback) at (AWantLine,AWantCol). AWantCol
// < 0 skips the column check (some callers only care about the line).
procedure CheckImpl(const ACase: string; ALine, ACol, AWantLine: Integer;
  AWantCol: Integer = -1);
var
  LTarget: TPasNavTarget;
begin
  if not GNav.GotoImplementation(GMidB, ALine, ACol, {out} LTarget) then
  begin
    Ok(ACase + ': GotoImplementation', False);
    Exit;
  end;
  Ok(ACase + ': target line', LTarget.Line = AWantLine);
  if AWantCol >= 0 then
    Ok(ACase + ': target col (lands on the STATEMENT''S OWN START, not ' +
      'wherever the parser''s FPos happened to be after parsing it)',
      LTarget.Col = AWantCol);
end;

// Implementation -> declaration: cursor at (ALine,ACol), expect the
// declaration's own name at AWantLine.
procedure CheckDecl(const ACase: string; ALine, ACol, AWantLine: Integer);
var
  LTarget: TPasNavTarget;
begin
  if not GNav.GotoDeclaration(GMidB, ALine, ACol, {out} LTarget) then
  begin
    Ok(ACase + ': GotoDeclaration', False);
    Exit;
  end;
  Ok(ACase + ': target line', LTarget.Line = AWantLine);
end;

var
  LDir: string;
  LIdent: TPasNavIdent;
  LTarget: TPasNavTarget;
begin
  GPassed := 0; GFailed := 0;
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_sema_nav');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'NavA.pas'), UNIT_A);
  TFile.WriteAllText(TPath.Combine(LDir, 'NavC.pas'), UNIT_C);
  TFile.WriteAllText(TPath.Combine(LDir, 'System.pas'), UNIT_SYS);
  TFile.WriteAllText(TPath.Combine(LDir, 'Namespace.NavD.pas'), UNIT_NS);
  TFile.WriteAllText(TPath.Combine(LDir, 'NavB.pas'), UNIT_B);
  TFile.WriteAllText(TPath.Combine(LDir, 'NavG.pas'), UNIT_G);
  TFile.WriteAllText(TPath.Combine(LDir, 'NavH.pas'), UNIT_H);
  TFile.WriteAllText(TPath.Combine(LDir, 'NavI.pas'), UNIT_I);
  TFile.WriteAllText(TPath.Combine(LDir, 'NavJ.pas'), UNIT_J);
  TFile.WriteAllText(TPath.Combine(LDir, 'NavK.pas'), UNIT_K);
  TFile.WriteAllText(TPath.Combine(LDir, 'NavOvl.pas'), UNIT_OVL);
  TFile.WriteAllText(TPath.Combine(LDir, 'NavOvlUse.pas'), UNIT_OVLUSE);

  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.AnalyzeDirectory(LDir);
    GNav := TPasNavigator.Create(GProj);
    try
      GMidB := GNav.ModelIdOf(TPath.Combine(LDir, 'NavB.pas'));
      Ok('NavB model found', GMidB >= 0);
      Ok('unknown path -> -1', GNav.ModelIdOf('C:\no\such.pas') = -1);

      // Cross-unit type reference: TThing in `var GT: TThing;`.
      CheckNav('type ref', 4, 9, 'TThing', 'NavA.pas', 4, 3);
      // Middle of the token works too (col 12 is inside TThing).
      CheckNav('type ref mid-token', 4, 12, 'TThing', 'NavA.pas', 4, 3);
      // Same-unit var reference: GT in the body -> its decl on line 4.
      CheckNav('local var', 13, 8, 'GT', 'NavB.pas', 4, 5);
      // Cross-unit MEMBER (Phase-3c discovered): GT.Value -> NavA field.
      CheckNav('cross member', 13, 11, 'Value', 'NavA.pas', 5, 5);
      // Builtin name a used unit actually declares: TBytes -> NavC.
      CheckNav('builtin-in-uses', 9, 6, 'TBytes', 'NavC.pas', 4, 3);
      // Implicit System unit, no `uses System` anywhere: TObject/TArray<T>.
      CheckNav('implicit System: TObject', 10, 6, 'TObject', 'System.pas', 7, 3);
      CheckNav('implicit System: TArray', 11, 6, 'TArray', 'System.pas', 6, 3);
      // MEMBER access through a builtin: O.Free — the synthetic TObject
      // symbol has no MemberScope; FindMemberX must redirect to the real
      // TObject class body (System.pas) to resolve `.Free` at all.
      CheckNav('member through builtin: O.Free', 14, 5, 'Free', 'System.pas',
        9, 15);
      // QUALIFIED EXPRESSION into the implicit unit (`System.SYS_MARK`, not
      // a `uses` item, and SYS_MARK isn't a seeded builtin at all — this is
      // CrossResolve's UnitNameOf fallback, not ResolveDecl's builtin-decl
      // redirect). The qualifier `System` itself must NOT get a false E2003.
      CheckNav('qualified expr: System.SYS_MARK', 15, 15, 'SYS_MARK',
        'System.pas', 4, 3);
      // TWO-SEGMENT qualifier naming a used unit (mirrors System.SysUtils.
      // TBytes exactly): `Namespace.NavD` is never itself a skUnitRef symbol
      // (it's a sub-expression of a bigger nkMember), only NSD_MARK is the
      // real member.
      CheckNav('qualified expr: Namespace.NavD.NSD_MARK (leaf)', 16, 23,
        'NSD_MARK', 'Namespace.NavD.pas', 3, 7);
      // Clicking the QUALIFIER ITSELF (not the member) opens THAT unit, same
      // as a `uses` clause name — `System` in `System.SYS_MARK` is the whole
      // qualifier (single segment); `Namespace`/`NavD` in `Namespace.NavD.
      // NSD_MARK` are BOTH part of the SAME 2-segment qualifier and must
      // resolve to the SAME target regardless of which one was clicked.
      CheckNav('qualifier click: System', 15, 8, 'System', 'System.pas', 1, 6);
      CheckNav('qualifier click: Namespace', 16, 8, 'Namespace',
        'Namespace.NavD.pas', 1, 6);
      CheckNav('qualifier click: NavD (same 2-seg qualifier)', 16, 18, 'NavD',
        'Namespace.NavD.pas', 1, 6);
      // Hover span: `System` alone is a single-token qualifier; `Namespace`/
      // `NavD` share ONE 3-raw-token span (Namespace . NavD), excluding the
      // trailing .NSD_MARK member.
      Ok('qualifier span: System is single-token',
        GNav.IdentAt(GMidB, 15, 8, {out} LIdent) and
        (LIdent.RawToken = LIdent.RawTokenTo));
      Ok('qualifier span: Namespace spans Namespace.NavD only',
        GNav.IdentAt(GMidB, 16, 8, {out} LIdent) and
        (LIdent.RawTokenTo - LIdent.RawToken = 2));
      Ok('qualifier span: NavD spans the SAME Namespace.NavD',
        GNav.IdentAt(GMidB, 16, 18, {out} LIdent) and
        (LIdent.RawTokenTo - LIdent.RawToken = 2));
      // BUG REGRESSION: clicking the trailing MEMBER of a qualified
      // expression (SYS_MARK/NSD_MARK — already resolved via ExtRefMap, NOT
      // a qualifier segment) must highlight ONLY ITSELF, not get its span
      // stolen by QualifierUnitAt widening it to the qualifier prefix
      // instead (the exact bug reported: hovering `sLineBreak` in `System.
      // sLineBreak` colored only `System`).
      Ok('member span: SYS_MARK is single-token (not widened to System)',
        GNav.IdentAt(GMidB, 15, 15, {out} LIdent) and
        (LIdent.Name = 'SYS_MARK') and
        (LIdent.RawToken = LIdent.RawTokenTo) and
        (LIdent.ColFrom = 15));  // own column, NOT System's (col 8)
      Ok('member span: NSD_MARK is single-token (not widened to Namespace.NavD)',
        GNav.IdentAt(GMidB, 16, 23, {out} LIdent) and
        (LIdent.Name = 'NSD_MARK') and
        (LIdent.RawToken = LIdent.RawTokenTo));
      // Implicit Result -> its enclosing routine's declaration (GetLen).
      CheckNav('result -> routine', 20, 3, 'Result', 'NavB.pas', 18, 10);

      // `uses` clause: a plain unqualified unit name opens THAT unit's own
      // file, at its own declaration -- not the (useless) uses-item position
      // in NavB itself.
      CheckNav('uses: NavA', 3, 6, 'NavA', 'NavA.pas', 1, 6);
      // A DOTTED unit name: clicking EITHER segment must resolve to the SAME
      // unit (Namespace.NavD.pas), at ITS OWN (dotted) declaration -- and
      // TargetFromNode must land on "Namespace", not the '.' (nkMember's own
      // FirstToken), which is the bug this fixture specifically catches.
      CheckNav('uses: Namespace (qualifier segment)', 3, 18, 'Namespace',
        'Namespace.NavD.pas', 1, 6);
      CheckNav('uses: NavD (leaf segment)', 3, 28, 'NavD',
        'Namespace.NavD.pas', 1, 6);

      // Ctrl+hover highlight span: a plain name is just its own token: a
      // DOTTED name spans every segment + dot (Namespace.NavD, 3 raw tokens),
      // regardless of which segment was actually under the cursor.
      Ok('uses: NavA span is single-token',
        GNav.IdentAt(GMidB, 3, 6, {out} LIdent) and
        (LIdent.RawToken = LIdent.RawTokenTo));
      Ok('uses: Namespace click spans the WHOLE dotted name',
        GNav.IdentAt(GMidB, 3, 18, {out} LIdent) and
        (LIdent.RawTokenTo - LIdent.RawToken = 2));
      Ok('uses: NavD click spans the SAME whole dotted name',
        GNav.IdentAt(GMidB, 3, 28, {out} LIdent) and
        (LIdent.RawTokenTo - LIdent.RawToken = 2));

      // Compiler INTRINSIC with no source declaration anywhere (Integer):
      // targets the System unit's own header — RAD Studio IDE behavior
      // (real System.pas: "Predefined ... do not have actual declarations").
      Ok('builtin: IdentAt', GNav.IdentAt(GMidB, 8, 6, {out} LIdent));
      Ok('intrinsic -> System header',
        GNav.ResolveDecl(GMidB, LIdent.Node, {out} LTarget) and
        SameText(TPath.GetFileName(LTarget.FilePath), 'System.pas') and
        (LTarget.Line = 1) and (LTarget.Col = 6));

      // Non-identifier position (the ':' of ':=' on line 13 is at col 5).
      Ok('symbol pos -> no ident', not GNav.IdentAt(GMidB, 13, 5, {out} LIdent));

      // The qualifier segments of BOTH qualified expressions above (System;
      // Namespace, NavD) must NOT be false "undeclared identifier" E2003s —
      // that was the actual bug report (nav didn't work at all for these,
      // and the qualifier itself was flagged as undeclared).
      Ok('qualified expr qualifiers: no false E2003',
        DiagCount(GProj.Model(GMidB), 'E2003') = 0);

      // ---- The false-E2003 taxonomy from the real demo project ----
      // Inherited members from a CROSS-UNIT ancestor, unqualified in a
      // method body (the AddAttribute/fCaseSensitive shape) — resolve, are
      // not E2003, and NAVIGATE to the ancestor's declaration.
      GMidB := GNav.ModelIdOf(TPath.Combine(LDir, 'NavH.pas'));
      Ok('NavH model found', GMidB >= 0);
      CheckNav('inherited field: FStock', 14, 3, 'FStock', 'NavG.pas', 6, 5);
      CheckNav('inherited method: Ping', 15, 3, 'Ping', 'NavG.pas', 7, 15);
      // A compiler intrinsic INSIDE a method body (MaxInt is seeded, so it
      // resolves in Phase 1; nav falls back to the System unit's header).
      CheckNav('intrinsic in method: MaxInt', 14, 13, 'MaxInt',
        'System.pas', 1, 6);
      // Anonymous-method parameters are REAL declarations now (retired the
      // v1 opaque-token shape): the body reference resolves + navigates.
      CheckNav('anon-method param: AVal', 18, 12, 'AVal', 'NavH.pas', 16, 18);
      // `on E: TObject` declares E, scoped to its handler.
      CheckNav('except-on var: E', 24, 8, 'E', 'NavH.pas', 24, 8);
      Ok('NavH: no false E2003',
        DiagCount(GProj.Model(GMidB), 'E2003') = 0);
      // Nested-class method impl (TOuterX.TInnerX.Zap): the qualifier CHAIN
      // resolves, so the inner class's own field is visible in the body.
      GMidB := GNav.ModelIdOf(TPath.Combine(LDir, 'NavG.pas'));
      CheckNav('nested-class impl field: FIn', 22, 3, 'FIn',
        'NavG.pas', 12, 7);
      Ok('NavG: no false E2003',
        DiagCount(GProj.Model(GMidB), 'E2003') = 0);

      // ---- Declaration <-> implementation toggle (Ctrl+Shift+Down/Up) ----
      GMidB := GNav.ModelIdOf(TPath.Combine(LDir, 'NavI.pas'));
      Ok('NavI model found', GMidB >= 0);
      // Overloaded methods: arity picks the RIGHT implementation both ways.
      // Column pinned too: regression for a real bug — nkExprStmt/nkAssign
      // used to get FirstToken from FPos AFTER ParseExpression already
      // consumed the whole statement, so the target landed at the END of
      // the line (near the `;`) instead of the statement's own start.
      CheckImpl('decl->impl: Add(1 param)', 5, 15, 16, 3);
      CheckImpl('decl->impl: Add(2 params)', 6, 15, 20, 3);
      CheckDecl('impl->decl: Add(1 param) body', 16, 13, 5);
      CheckDecl('impl->decl: Add(2 params) body', 20, 13, 6);
      // Nested class (TCalc.TInner.Zap): qualifier chain must match the
      // declaration's OWN enclosing-type chain, both ways. Empty `begin
      // end` body -> the target lands on `end` itself (line 24, not 23).
      CheckImpl('decl->impl: nested-class Zap', 9, 17, 24);
      CheckDecl('impl->decl: nested-class Zap (on begin)', 23, 1, 9);
      // Global routine, forward-declared in the interface section.
      CheckImpl('decl->impl: GProc (global fwd)', 12, 11, 27, 3);
      CheckDecl('impl->decl: GProc body', 27, 3, 12);
      // Regression: a cursor sitting in the GAP right after `begin` (col 6 —
      // `begin` is 5 chars — before the next real token) used to fail
      // entirely: that raw position is lexed as trailing whitespace, which
      // never survives into the Visible stream, so VisAt found no mapping
      // at all. Must resolve exactly like clicking inside the body proper.
      CheckDecl('impl->decl: cursor in the gap right after begin', 15, 6, 5);
      // NESTED local procedure, forward-declared inside Outer's own local
      // declarations — container-scoped so it can never match some OTHER
      // outer routine's same-named nested proc.
      CheckImpl('decl->impl: Inner (nested fwd)', 30, 15, 37, 5);
      CheckDecl('impl->decl: Inner body', 37, 5, 30);
      // Negative: Helper has NO separate forward decl (defined directly) —
      // neither direction should find anything.
      Ok('Helper body: no declaration to jump to',
        not GNav.GotoDeclaration(GMidB, 33, 5, {out} LTarget));
      Ok('Helper header: not decl-only (has its own body)',
        not GNav.GotoImplementation(GMidB, 31, 15, {out} LTarget));
      // Negative: an unrelated position (the `type` keyword) is on neither.
      Ok('unrelated position: no implementation',
        not GNav.GotoImplementation(GMidB, 3, 2, {out} LTarget));
      Ok('unrelated position: no declaration',
        not GNav.GotoDeclaration(GMidB, 3, 2, {out} LTarget));

      // ---- Same-arity overloads (real bug report) + comment-only body ----
      GMidB := GNav.ModelIdOf(TPath.Combine(LDir, 'NavJ.pas'));
      Ok('NavJ model found', GMidB >= 0);
      // Both the PChar and the string overload have arity 5 — count-only
      // matching collided them; the signature must pick the RIGHT one.
      CheckImpl('decl->impl: Cmp(PChar,...) 5-arg overload', 3, 10, 13);
      CheckImpl('decl->impl: Cmp(string,...) 5-arg overload', 5, 10, 18);
      CheckDecl('impl->decl: Cmp(PChar,...) body', 13, 3, 3);
      CheckDecl('impl->decl: Cmp(string,...) body', 18, 3, 5);
      // The 3-param overload's body holds ONLY a comment — structurally
      // empty (comments never reach the AST), so this also exercises the
      // empty-body fallback; it must land on the COMMENT'S OWN line (22),
      // not jump past it to `end` (23).
      CheckImpl('decl->impl: Cmp(S1,S2,CVC) comment-only body', 7, 10, 22);
      CheckDecl('impl->decl: Cmp(S1,S2,CVC) from inside the comment line',
        22, 5, 7);
      Ok('NavJ: no false E2003', DiagCount(GProj.Model(GMidB), 'E2003') = 0);

      // ---- Inactive ($IFDEF'd-out) code must never cross-match ----
      // (real bug report: CharInSet's $IFNDEF NEXTGEN / $ELSE overload pair)
      GMidB := GNav.ModelIdOf(TPath.Combine(LDir, 'NavK.pas'));
      Ok('NavK model found', GMidB >= 0);
      // The ACTIVE branch works exactly like any other overload pair.
      CheckImpl('decl->impl: Zig(AnsiChar) ACTIVE', 4, 10, 14);
      CheckImpl('decl->impl: Zig(WideChar) ACTIVE', 5, 10, 18);
      CheckDecl('impl->decl: Zig(AnsiChar) body ACTIVE', 14, 3, 4);
      CheckDecl('impl->decl: Zig(WideChar) body ACTIVE', 18, 3, 5);
      // BUG: clicking a declaration INSIDE the dead $ELSE branch used to
      // walk backward past the whole inactive region and land on the
      // ACTIVE Zig(WideChar) implementation instead of refusing outright.
      Ok('decl->impl: Zig(Byte) INACTIVE -> no target',
        not GNav.GotoImplementation(GMidB, 7, 10, {out} LTarget));
      Ok('decl->impl: Zig(Char) INACTIVE -> no target',
        not GNav.GotoImplementation(GMidB, 8, 10, {out} LTarget));
      // Same bug, opposite direction: an implementation body inside the
      // dead $ELSE branch must not jump back to an ACTIVE declaration.
      Ok('impl->decl: Zig(Byte) body INACTIVE -> no target',
        not GNav.GotoDeclaration(GMidB, 23, 3, {out} LTarget));
      Ok('impl->decl: Zig(Char) body INACTIVE -> no target',
        not GNav.GotoDeclaration(GMidB, 27, 3, {out} LTarget));
      // The dead branch has NO AST representation at all (parser never sees
      // its tokens), so reusing the same routine NAME in both branches must
      // not trip a duplicate/false E2003 either.
      Ok('NavK: no false E2003', DiagCount(GProj.Model(GMidB), 'E2003') = 0);

      // ---- Overload-PRECISE go-to-declaration (CallTargetX/CallTarget) ----
      GMidB := GNav.ModelIdOf(TPath.Combine(LDir, 'NavOvlUse.pas'));
      Ok('NavOvlUse model found', GMidB >= 0);
      // Cross-unit global overloads: the ARGUMENT type picks the overload —
      // Pick(11) lands on the Integer declaration, Pick(2.5) on the Double
      // one (the old behavior landed both on the chain head, line 3).
      CheckNav('ovl-precise: Pick(11) -> Integer overload', 19, 9, 'Pick',
        'NavOvl.pas', 3, 10);
      CheckNav('ovl-precise: Pick(2.5) -> Double overload', 20, 9, 'Pick',
        'NavOvl.pas', 4, 10);
      // Method overloads: same-unit class, selected by the argument.
      CheckNav('ovl-precise: C.Fill(7) -> Integer method', 21, 11, 'Fill',
        'NavOvlUse.pas', 6, 14);
      CheckNav('ovl-precise: C.Fill(''x'') -> string method', 22, 11, 'Fill',
        'NavOvlUse.pas', 7, 14);
      // Negative: the callee's BASE (`C` in C.Fill) is not a callee name —
      // still navigates to the variable's own declaration.
      CheckNav('ovl-precise: base C keeps ordinary nav', 21, 9, 'C',
        'NavOvlUse.pas', 14, 3);
    finally
      GNav.Free;
    end;
  finally
    GProj.Free;
  end;

  // ---- AnalyzeProject: the TRANSITIVE closure from a main program. ----
  // NavMain uses only NavB/NavE/OldNavF; NavA, NavC, Namespace.NavD and the
  // implicit System unit must all load transitively, and the cross passes
  // must run for DEPENDENCY units too — clicking inside NavB behaves exactly
  // like the direct-analysis pass above (AnalyzeFile's documented gap).
  TFile.WriteAllText(TPath.Combine(LDir, 'NavMain.dpr'), UNIT_MAIN);
  TFile.WriteAllText(TPath.Combine(LDir, 'Wide.NavE.pas'), UNIT_E);
  TFile.WriteAllText(TPath.Combine(LDir, 'NavF.pas'), UNIT_F);
  GProj := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    GProj.SetNamespaces(['Wide']);
    GProj.AddUnitAlias('OldNavF', 'NavF');
    Ok('project: main model',
      GProj.AnalyzeProject(TPath.Combine(LDir, 'NavMain.dpr')) >= 0);
    GNav := TPasNavigator.Create(GProj);
    try
      // Transitive reach: NavA came in only through NavB's uses.
      Ok('project: transitive NavA loaded',
        GNav.ModelIdOf(TPath.Combine(LDir, 'NavA.pas')) >= 0);
      Ok('project: implicit System loaded',
        GNav.ModelIdOf(TPath.Combine(LDir, 'System.pas')) >= 0);
      // Namespace + alias resolution (uses NavE -> Wide.NavE.pas; uses
      // OldNavF -> NavF.pas).
      Ok('project: namespace unit loaded',
        GNav.ModelIdOf(TPath.Combine(LDir, 'Wide.NavE.pas')) >= 0);
      Ok('project: aliased unit loaded',
        GNav.ModelIdOf(TPath.Combine(LDir, 'NavF.pas')) >= 0);
      // Nav INSIDE the dependency NavB — the reported-bug shape (clicking
      // TSynCustomHighlighter inside a dependency unit did nothing).
      GMidB := GNav.ModelIdOf(TPath.Combine(LDir, 'NavB.pas'));
      Ok('project: NavB model found', GMidB >= 0);
      CheckNav('project dep: type ref', 4, 9, 'TThing', 'NavA.pas', 4, 3);
      CheckNav('project dep: cross member', 13, 11, 'Value', 'NavA.pas', 5, 5);
      CheckNav('project dep: implicit System', 10, 6, 'TObject',
        'System.pas', 7, 3);
      CheckNav('project dep: qualifier click', 15, 8, 'System',
        'System.pas', 1, 6);
      // `uses` clause nav in the MAIN file across namespace/alias.
      GMidB := GNav.ModelIdOf(TPath.Combine(LDir, 'NavMain.dpr'));
      CheckNav('project uses: NavE -> namespaced file', 2, 13, 'NavE',
        'Wide.NavE.pas', 1, 6);
      CheckNav('project uses: OldNavF -> aliased file', 2, 19, 'OldNavF',
        'NavF.pas', 1, 6);
    finally
      GNav.Free;
    end;
  finally
    GProj.Free;
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  end;

  Writeln(Format('=== SemaNavSmoke: %d passed, %d failed ===',
    [GPassed, GFailed]));
  if GFailed > 0 then
    ExitCode := 1;
end.
