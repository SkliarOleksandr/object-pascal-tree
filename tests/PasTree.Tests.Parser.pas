unit PasTree.Tests.Parser;

{
  Parser golden cases, as DATA (test-coverage plan step 2). STMT_CASES and
  DECL_CASES are plain const tables -- a suite's .dpr host no longer contains
  the cases themselves, just the pipeline wiring in PasTree.TestKit. Anything
  that is not a single (source, expected-dump) comparison -- a platform
  matrix, an include search-path fixture, a lexer-diagnostic-lines probe --
  is built by BuildCustomCases instead; see TPasCustomCase in PasTree.TestKit
  for why those stay closures rather than rows.

  A future demo view (test-coverage plan step 5) can `uses` this unit
  directly to enumerate STMT_CASES/DECL_CASES and group them by Section --
  Delphi's own unit system is the shared registry, and no separate
  registration mechanism has to run first.
}

interface

uses
  System.SysUtils, System.IOUtils,
  PasTree.Types,
  PasTree.Lexer,
  PasTree.SourceManager,
  PasTree.Preprocessor,
  PasTree.Platforms,
  PasTree.Ast,
  PasTree.Parser,
  PasTree.TestKit;

const
  STMT_CASES: array[0..73] of TPasCaseRow = (
    // ---- 5.1.1 assignment ----
    (Section: '5.1.1'; Name: 'assign'; Source: 'X := 42;';
     Expected: 'Block(Assign(Ident''X'' IntLit''42''))'; ExpectDiags: 0),
    (Section: '5.1.1'; Name: 'member assign'; Source: 'Edit1.Text := S;';
     Expected: 'Block(Assign(Member(Ident''Edit1'' Ident''Text'') ' +
       'Ident''S''))'; ExpectDiags: 0),
    (Section: '5.1.1'; Name: 'deref assign'; Source: 'P^.Value := 1;';
     Expected: 'Block(Assign(Member(Deref(Ident''P'') Ident''Value'') ' +
       'IntLit''1''))'; ExpectDiags: 0),

    // ---- 5.1.2 call statement ----
    (Section: '5.1.2'; Name: 'call'; Source: 'DoWork(Input, 10);';
     Expected: 'Block(ExprStmt(Call(Ident''DoWork'' Ident''Input'' ' +
       'IntLit''10'')))'; ExpectDiags: 0),
    (Section: '5.1.2'; Name: 'bare call'; Source: 'Application.Run;';
     Expected: 'Block(ExprStmt(Member(Ident''Application'' Ident''Run'')))';
     ExpectDiags: 0),
    // 4.11.3 OLE-automation NAMED ARGUMENTS. Without the nkNamedArg wrap the
    // argument list ended at the name and ':=' turned the whole call into an
    // assignment TARGET -- two parse diags and a false E2003 on the name.
    (Section: '4.11.3'; Name: 'named argument';
     Source: 'Charts.Add(Source := R, Gap := 1);';
     Expected: 'Block(ExprStmt(Call(Member(Ident''Charts'' Ident''Add'') ' +
       'NamedArg(Ident''Source'' Ident''R'') ' +
       'NamedArg(Ident''Gap'' IntLit''1''))))'; ExpectDiags: 0),
    // A Variant's INDEXED property takes them too (dcc-verified) -- the
    // bracket loop needed the same rule, and was still a false E2003 without
    // it.
    (Section: '4.11.3'; Name: 'named argument in an index';
     Source: 'V.Range[Source := 1] := 5;';
     Expected: 'Block(Assign(Index(Member(Ident''V'' Ident''Range'') ' +
       'NamedArg(Ident''Source'' IntLit''1'')) IntLit''5''))';
     ExpectDiags: 0),
    // Only a bare identifier makes a named argument; anything else stays the
    // syntax error it always was (an assignment is not an expression).
    (Section: '4.11.3'; Name: 'named argument needs a bare name';
     Source: 'Charts.Add(A.B := R);';
     Expected: 'Block(Assign(Call(Member(Ident''Charts'' Ident''Add'') ' +
       'Member(Ident''A'' Ident''B'')) Ident''R''))'; ExpectDiags: 2),

    // ---- 4.x expressions & precedence ----
    (Section: '4.2'; Name: 'precedence'; Source: 'X := A + B * C;';
     Expected: 'Block(Assign(Ident''X'' BinaryOp''+''(Ident''A'' ' +
       'BinaryOp''*''(Ident''B'' Ident''C''))))'; ExpectDiags: 0),
    (Section: '4.3'; Name: 'bool vs rel';
     Source: 'B := (A > 0) and (C > 0);';
     Expected: 'Block(Assign(Ident''B'' BinaryOp''and''(Paren(' +
       'BinaryOp''>''(Ident''A'' IntLit''0'')) Paren(BinaryOp''>''(' +
       'Ident''C'' IntLit''0'')))))'; ExpectDiags: 0),
    (Section: '4.8'; Name: 'address-of'; Source: 'P := @X;';
     Expected: 'Block(Assign(Ident''P'' UnaryOp''@''(Ident''X'')))';
     ExpectDiags: 0),
    (Section: '4.8'; Name: 'double address-of'; Source: 'P := @@Hook;';
     Expected: 'Block(Assign(Ident''P'' UnaryOp''@''(UnaryOp''@''(' +
       'Ident''Hook''))))'; ExpectDiags: 0),
    (Section: '4.9'; Name: 'is/as';
     Source: 'if Obj is TButton then B := Obj as TButton;';
     Expected: 'Block(IfStmt(BinaryOp''is''(Ident''Obj'' Ident''TButton'') ' +
       'Assign(Ident''B'' BinaryOp''as''(Ident''Obj'' Ident''TButton''))))';
     ExpectDiags: 0),
    (Section: '4.9.1'; Name: 'is not';
     Source: 'if Obj is not TButton then Exit;';
     Expected: 'Block(IfStmt(BinaryOp''is''!(Ident''Obj'' Ident''TButton'') ' +
       'ExprStmt(Ident''Exit'')))'; ExpectDiags: 0),
    (Section: '4.9.1'; Name: 'not in'; Source: 'if C not in S then Exit;';
     Expected: 'Block(IfStmt(BinaryOp''in''!(Ident''C'' Ident''S'') ' +
       'ExprStmt(Ident''Exit'')))'; ExpectDiags: 0),
    (Section: '4.10'; Name: 'cast-or-call'; Source: 'B := Byte(I);';
     Expected: 'Block(Assign(Ident''B'' Call(Ident''Byte'' Ident''I'')))';
     ExpectDiags: 0),
    (Section: '4.10'; Name: 'string cast'; Source: 'S := string(P);';
     Expected: 'Block(Assign(Ident''S'' Call(Ident''string'' Ident''P'')))';
     ExpectDiags: 0),
    (Section: '4.11.2'; Name: 'formatted args'; Source: 'Str(Val:0, S);';
     Expected: 'Block(ExprStmt(Call(Ident''Str'' FormattedArg(Ident''Val'' ' +
       'IntLit''0'') Ident''S'')))'; ExpectDiags: 0),
    (Section: 'B.6.1'; Name: 'string concat'; Source: 'S := ''Hi''#13#10;';
     Expected: 'Block(Assign(Ident''S'' StrLit''''Hi''''))'; ExpectDiags: 0),
    (Section: 'B.6.2'; Name: 'caret char'; Source: 'C := ^M;';
     Expected: 'Block(Assign(Ident''C'' CaretChar''^''))'; ExpectDiags: 0),
    (Section: 'B.9'; Name: 'set ctor';
     Source: 'if C in [''a''..''z'', ''0''] then;';
     Expected: 'Block(IfStmt(BinaryOp''in''(Ident''C'' SetCtor(Range(' +
       'StrLit''''a'''' StrLit''''z'''') StrLit''''0'''')) ' +
       'EmptyStmt))'; ExpectDiags: 0),

    // ---- 16.3 generic args in expressions ----
    (Section: '16.3'; Name: 'generic call';
     Source: 'L := TList<Integer>.Create;';
     Expected: 'Block(Assign(Ident''L'' Member(TypeArgs(Ident''TList'' ' +
       'Ident''Integer'') Ident''Create'')))'; ExpectDiags: 0),
    (Section: '16.3'; Name: 'less-than stays'; Source: 'B := A < C;';
     Expected: 'Block(Assign(Ident''B'' BinaryOp''<''(Ident''A'' ' +
       'Ident''C'')))'; ExpectDiags: 0),

    // ---- 5.3.1 if / dangling else ----
    (Section: '5.3.1'; Name: 'dangling else';
     Source: 'if A then if B then X := 1 else X := 2;';
     Expected: 'Block(IfStmt(Ident''A'' IfStmt(Ident''B'' Assign(' +
       'Ident''X'' IntLit''1'') Assign(Ident''X'' IntLit''2''))))';
     ExpectDiags: 0),

    // ---- 5.3.2 case ----
    (Section: '5.3.2'; Name: 'case';
     Source: 'case K of 1, 2: X := 1; 3..5: X := 2 else X := 3; end;';
     Expected: 'Block(CaseStmt(Ident''K'' CaseSel(CaseLabels(IntLit''1'' ' +
       'IntLit''2'') Assign(Ident''X'' IntLit''1'')) CaseSel(CaseLabels(' +
       'Range(IntLit''3'' IntLit''5'')) Assign(Ident''X'' IntLit''2'')) ' +
       'Block(Assign(Ident''X'' IntLit''3''))))'; ExpectDiags: 0),

    // ---- 5.4.1 inline if ----
    (Section: '5.4.1'; Name: 'inline if';
     Source: 'Max := if A > B then A else B;';
     Expected: 'Block(Assign(Ident''Max'' InlineIf(BinaryOp''>''(' +
       'Ident''A'' Ident''B'') Ident''A'' Ident''B'')))'; ExpectDiags: 0),

    // ---- 5.5 loops ----
    (Section: '5.5.1'; Name: 'for-to';
     Source: 'for I := 1 to 10 do Sum := Sum + I;';
     Expected: 'Block(ForStmt(Ident''I'' IntLit''1'' IntLit''10'' Assign(' +
       'Ident''Sum'' BinaryOp''+''(Ident''Sum'' Ident''I''))))';
     ExpectDiags: 0),
    (Section: '5.5.1'; Name: 'inline counter';
     Source: 'for var J := 1 to 2 do;';
     Expected: 'Block(ForStmt(InlineVar(Ident''J'') IntLit''1'' ' +
       'IntLit''2'' EmptyStmt))'; ExpectDiags: 0),
    (Section: '5.5.2'; Name: 'for-in';
     Source: 'for Item in MyList do Process(Item);';
     Expected: 'Block(ForInStmt(Ident''Item'' Ident''MyList'' ExprStmt(' +
       'Call(Ident''Process'' Ident''Item''))))'; ExpectDiags: 0),
    (Section: '5.5.3'; Name: 'while'; Source: 'while not Done do Step;';
     Expected: 'Block(WhileStmt(UnaryOp''not''(Ident''Done'') ExprStmt(' +
       'Ident''Step'')))'; ExpectDiags: 0),
    (Section: '5.5.4'; Name: 'repeat'; Source: 'repeat Step until Done;';
     Expected: 'Block(RepeatStmt(Block(ExprStmt(Ident''Step'')) ' +
       'Ident''Done''))'; ExpectDiags: 0),

    // ---- 5.6.4 goto / labels ----
    // An IDENTIFIER label is a reference to a `label`-section declaration, so
    // it gets its own Ident node the resolver can bind (without it the
    // labeled statement's name was the only node, and it resolved to
    // nothing: false E2003 on System.Generics.Defaults). A NUMERIC label
    // declares no name at all and stays a bare token in both positions.
    (Section: '5.6.4'; Name: 'goto ident label'; Source: 'goto Done;';
     Expected: 'Block(GotoStmt(Ident''Done''))'; ExpectDiags: 0),
    (Section: '5.6.4'; Name: 'labeled stmt + goto';
     Source: 'Again: Step; goto Again;';
     Expected: 'Block(LabeledStmt(Ident''Again'' ExprStmt(Ident''Step'')) ' +
       'GotoStmt(Ident''Again''))'; ExpectDiags: 0),
    (Section: '5.6.4'; Name: 'numeric label declares no ident node';
     Source: '1: goto 2;';
     Expected: 'Block(LabeledStmt(GotoStmt))'; ExpectDiags: 0),

    // ---- 5.7 with ----
    (Section: '5.7'; Name: 'with'; Source: 'with A, B do X := 1;';
     Expected: 'Block(WithStmt(Ident''A'' Ident''B'' Assign(Ident''X'' ' +
       'IntLit''1'')))'; ExpectDiags: 0),

    // ---- 3.1.3 inline vars ----
    (Section: '3.1.3'; Name: 'inline var'; Source: 'var Name := Edit1.Text;';
     Expected: 'Block(InlineVar(Ident''Name'' Member(Ident''Edit1'' ' +
       'Ident''Text'')))'; ExpectDiags: 0),
    (Section: '3.1.3'; Name: 'typed inline var';
     Source: 'var I: Integer := 0;';
     Expected: 'Block(InlineVar(Ident''I'' Ident''Integer'' IntLit''0''))';
     ExpectDiags: 0),

    // ---- 18.x exceptions ----
    (Section: '18.2.1'; Name: 'try-finally';
     Source: 'try Use finally Obj.Free end;';
     Expected: 'Block(TryStmt(Block(ExprStmt(Ident''Use'')) FinallyPart(' +
       'Block(ExprStmt(Member(Ident''Obj'' Ident''Free''))))))';
     ExpectDiags: 0),
    (Section: '18.1.2'; Name: 'on-do';
     Source: 'try P except on E: EFoo do Log(E); else raise; end;';
     Expected: 'Block(TryStmt(Block(ExprStmt(Ident''P'')) ExceptPart(' +
       'ExceptOn(Ident''E'' Ident''EFoo'' ExprStmt(Call(Ident''Log'' ' +
       'Ident''E''))) Block(RaiseStmt))))'; ExpectDiags: 0),
    (Section: '18.3.1'; Name: 'raise at'; Source: 'raise E at Addr;';
     Expected: 'Block(RaiseStmt(Ident''E'' Ident''Addr''))'; ExpectDiags: 0),

    // ---- 12.1.2 inherited ----
    (Section: '12.1.2'; Name: 'inherited bare'; Source: 'inherited;';
     Expected: 'Block(ExprStmt(Inherited))'; ExpectDiags: 0),
    (Section: '12.1.2'; Name: 'inherited named';
     Source: 'inherited Create(X);';
     Expected: 'Block(ExprStmt(Inherited(Call(Ident''Create'' ' +
       'Ident''X''))))'; ExpectDiags: 0),

    // ---- 1.3.2 conditional compilation in statements ----
    (Section: '1.3.2'; Name: 'ifdef';
     Source: '{$IFDEF MSWINDOWS}A := 1;{$ELSE}A := 2;{$ENDIF}';
     Expected: 'Block(Assign(Ident''A'' IntLit''1''))'; ExpectDiags: 0),

    // ---- B.5.2 real literals -- no fixture anywhere had one ----
    (Section: 'B.5.2'; Name: 'real literal forms';
     Source: 'X := 1.0e-3; Y := 1E+10; Z := 3.14;';
     Expected: 'Block(Assign(Ident''X'' RealLit''1.0e-3'') Assign(Ident''Y'' ' +
       'RealLit''1E+10'') Assign(Ident''Z'' RealLit''3.14''))';
     ExpectDiags: 0),

    // ---- 5.6.1 / 5.6.2 Break / Continue: plain identifiers, no dedicated
    // node -- nothing had ever exercised them as STATEMENTS (only inside
    // real loops in sema fixtures, never asserted on the parse shape) ----
    (Section: '5.6.1'; Name: 'break';
     Source: 'while True do Break;';
     Expected: 'Block(WhileStmt(Ident''True'' ExprStmt(Ident''Break'')))';
     ExpectDiags: 0),
    (Section: '5.6.2'; Name: 'continue';
     Source: 'while True do Continue;';
     Expected: 'Block(WhileStmt(Ident''True'' ExprStmt(Ident''Continue'')))';
     ExpectDiags: 0),

    // ---- 4.11.1 NameOf: ordinary call syntax, not a dedicated production ----
    (Section: '4.11.1'; Name: 'NameOf';
     Source: 'S := NameOf(X);';
     Expected: 'Block(Assign(Ident''S'' Call(Ident''NameOf'' Ident''X'')))';
     ExpectDiags: 0),

    // ---- 7.2.1 string element indexing: same Index node as an array ----
    (Section: '7.2.1'; Name: 'string element indexing';
     Source: 'C := S[1];';
     Expected: 'Block(Assign(Ident''C'' Index(Ident''S'' IntLit''1'')))';
     ExpectDiags: 0),

    // ---- 17.2.1 an anonymous method LITERAL used as a VALUE, not merely
    // named by a `reference to` TYPE (which 6.6.1 already covers) ----
    (Section: '17.2.1'; Name: 'anonymous procedure literal';
     Source: 'F := procedure begin DoIt; end;';
     Expected: 'Block(Assign(Ident''F'' AnonMethod(RoutineBody(Block(' +
       'ExprStmt(Ident''DoIt''))))))'; ExpectDiags: 0),
    (Section: '17.2.1'; Name: 'anonymous function literal with params';
     Source: 'G := function(A: Integer): Integer begin Result := A; end;';
     Expected: 'Block(Assign(Ident''G'' AnonMethod(Params(Param(Ident''A'' ' +
       'Ident''Integer'')) Ident''Integer'' RoutineBody(Block(Assign(' +
       'Ident''Result'' Ident''A''))))))'; ExpectDiags: 0),

    // ---- B.4.2 directive words are ordinary identifiers everywhere outside
    // their own grammar production -- the FULL list (PasTree.Types.
    // DIRECTIVE_WORDS) was untested; this samples across every family
    // (routine directives, property specifiers, hints, calling conventions)
    // since the "Unsafe = class" bug was exactly this shape missed once ----
    (Section: 'B.4.2'; Name: 'directive words as plain identifiers';
     Source: 'static := 1; unsafe := 2; message := 3; sealed := 4; ' +
       'strict := 5; read := 6; write := 7; index := 8; name := 9; ' +
       'at := 10; operator := 11; out := 12; default := 13; stored := 14;';
     Expected: 'Block(Assign(Ident''static'' IntLit''1'') ' +
       'Assign(Ident''unsafe'' IntLit''2'') ' +
       'Assign(Ident''message'' IntLit''3'') ' +
       'Assign(Ident''sealed'' IntLit''4'') ' +
       'Assign(Ident''strict'' IntLit''5'') ' +
       'Assign(Ident''read'' IntLit''6'') ' +
       'Assign(Ident''write'' IntLit''7'') ' +
       'Assign(Ident''index'' IntLit''8'') ' +
       'Assign(Ident''name'' IntLit''9'') ' +
       'Assign(Ident''at'' IntLit''10'') ' +
       'Assign(Ident''operator'' IntLit''11'') ' +
       'Assign(Ident''out'' IntLit''12'') ' +
       'Assign(Ident''default'' IntLit''13'') ' +
       'Assign(Ident''stored'' IntLit''14''))'; ExpectDiags: 0),

    // ---- 5.6.3 Exit / Exit(value): bare Exit already appears incidentally
    // elsewhere, but never Exit(value), and never as its own named case ----
    (Section: '5.6.3'; Name: 'bare Exit';
     Source: 'Exit;';
     Expected: 'Block(ExprStmt(Ident''Exit''))'; ExpectDiags: 0),
    (Section: '5.6.3'; Name: 'Exit with a value';
     Source: 'Exit(42);';
     Expected: 'Block(ExprStmt(Call(Ident''Exit'' IntLit''42'')))';
     ExpectDiags: 0),

    // ---- 8.2.2 dynamic array concatenation & literal (bracket) init --
    // the literal is the same SetCtor node a set constructor uses (B.9);
    // which one it MEANS is a typing question, not a parse-shape one ----
    (Section: '8.2.2'; Name: 'array literal init and concatenation';
     Source: 'A := [1, 2, 3]; B := A + C;';
     Expected: 'Block(Assign(Ident''A'' SetCtor(IntLit''1'' IntLit''2'' ' +
       'IntLit''3'')) Assign(Ident''B'' BinaryOp''+''(Ident''A'' ' +
       'Ident''C'')))'; ExpectDiags: 0),

    // ---- 8.2.3 the dynamic-array pseudo-constructor T.Create(...) --
    // ordinary call syntax; nothing marks it as a pseudo-constructor at
    // parse time, that is a sema/typing question ----
    (Section: '8.2.3'; Name: 'TBytes.Create pseudo-constructor';
     Source: 'B := TBytes.Create(1, 2, 3);';
     Expected: 'Block(Assign(Ident''B'' Call(Member(Ident''TBytes'' ' +
       'Ident''Create'') IntLit''1'' IntLit''2'' IntLit''3'')))';
     ExpectDiags: 0),

    // ---- B.7 relational punctuation tokens, each of which had only ever
    // appeared in isolation before -- `..` itself is already pinned at
    // 2.2.5 (subrange) and B.9 (set constructor); Delphi has no array-
    // SLICE syntax, so `K[L..M]` is not a shape to add here ----
    (Section: 'B.7'; Name: 'relational punctuation';
     Source: 'A := B <= C; D := E >= F; G := H <> I;';
     Expected: 'Block(Assign(Ident''A'' BinaryOp''<=''(Ident''B'' ' +
       'Ident''C'')) Assign(Ident''D'' BinaryOp''>=''(Ident''E'' ' +
       'Ident''F'')) Assign(Ident''G'' BinaryOp''<>''(Ident''H'' ' +
       'Ident''I'')))'; ExpectDiags: 0),

    // ==== test-coverage plan step 3 batch 4 ====================

    // ---- 1.2.3 qualified (multi-segment dotted) name resolution ----
    (Section: '1.2.3'; Name: 'multi-segment dotted name';
     Source: 'X := A.B.C;';
     Expected: 'Block(Assign(Ident''X'' Member(Member(Ident''A'' ' +
       'Ident''B'') Ident''C'')))'; ExpectDiags: 0),

    // ---- 1.3.5 a compiler-version conditional, same shape as 1.3.2's
    // ifdef but keyed to CompilerVersion instead of a define ----
    (Section: '1.3.5'; Name: 'compiler-version conditional';
     Source: '{$IF CompilerVersion >= 18}A := 1;{$ELSE}A := 2;{$ENDIF}';
     Expected: 'Block(Assign(Ident''A'' IntLit''1''))'; ExpectDiags: 0),

    // ---- 4.4 shl/shr: the only bitwise operators without their own
    // parse shape already -- and/or/xor/not already covered at 4.3, since
    // bitwise vs logical is a TYPING distinction, not a different node ----
    (Section: '4.4'; Name: 'shl and shr';
     Source: 'A := B shl 1; C := D shr 1;';
     Expected: 'Block(Assign(Ident''A'' BinaryOp''shl''(Ident''B'' ' +
       'IntLit''1'')) Assign(Ident''C'' BinaryOp''shr''(Ident''D'' ' +
       'IntLit''1'')))'; ExpectDiags: 0),

    // ---- 4.5 `=` as the equality operator -- tested everywhere as `:=`
    // but never as a bare relational `=` before ----
    (Section: '4.5'; Name: 'equality operator';
     Source: 'B := X = Y;';
     Expected: 'Block(Assign(Ident''B'' BinaryOp''=''(Ident''X'' ' +
       'Ident''Y'')))'; ExpectDiags: 0),

    // ---- 4.6 set difference and intersection (union already covered at
    // 8.2.2 by `+`; same BinaryOp shape, different operator token) ----
    (Section: '4.6'; Name: 'set difference and intersection';
     Source: 'S3 := S1 - S2; S4 := S1 * S2;';
     Expected: 'Block(Assign(Ident''S3'' BinaryOp''-''(Ident''S1'' ' +
       'Ident''S2'')) Assign(Ident''S4'' BinaryOp''*''(Ident''S1'' ' +
       'Ident''S2'')))'; ExpectDiags: 0),

    // ---- 5.2.1 an explicit begin..end block nested inside another
    // statement -- ParseStatements' own top level is already a Block, so
    // this is the first case where nesting one is the POINT ----
    (Section: '5.2.1'; Name: 'nested begin-end block';
     Source: 'if A then begin X := 1; Y := 2; end;';
     Expected: 'Block(IfStmt(Ident''A'' Block(Assign(Ident''X'' ' +
       'IntLit''1'') Assign(Ident''Y'' IntLit''2''))))'; ExpectDiags: 0),

    // ---- 10.1.3 / 20.7.1 manual allocation intrinsics: one shared shape,
    // two spec sections (ch.10's pointer chapter and ch.20's memory-
    // management chapter both name it) ----
    (Section: '10.1.3'; Name: 'manual allocation intrinsics';
     Source: 'New(P); GetMem(Q, 10); FreeMem(Q); Dispose(P);';
     Expected: 'Block(ExprStmt(Call(Ident''New'' Ident''P'')) ' +
       'ExprStmt(Call(Ident''GetMem'' Ident''Q'' IntLit''10'')) ' +
       'ExprStmt(Call(Ident''FreeMem'' Ident''Q'')) ' +
       'ExprStmt(Call(Ident''Dispose'' Ident''P'')))'; ExpectDiags: 0),
    (Section: '20.7.1'; Name: 'manual allocation intrinsics';
     Source: 'New(P); GetMem(Q, 10); FreeMem(Q); Dispose(P);';
     Expected: 'Block(ExprStmt(Call(Ident''New'' Ident''P'')) ' +
       'ExprStmt(Call(Ident''GetMem'' Ident''Q'' IntLit''10'')) ' +
       'ExprStmt(Call(Ident''FreeMem'' Ident''Q'')) ' +
       'ExprStmt(Call(Ident''Dispose'' Ident''P'')))'; ExpectDiags: 0),

    // ---- 11.3.3 the Self identifier: an ordinary reference, not a
    // dedicated node -- resolved by the SEMA layer, not the parser ----
    (Section: '11.3.3'; Name: 'Self identifier';
     Source: 'Self.DoIt;';
     Expected: 'Block(ExprStmt(Member(Ident''Self'' Ident''DoIt'')))';
     ExpectDiags: 0),

    // ---- 12.4.1 a hard cast to a CLASS type -- same Call shape 4.10
    // already pins for a builtin type (Byte(I)); different spec section ----
    (Section: '12.4.1'; Name: 'hard cast to a class type';
     Source: 'B := TButton(Sender);';
     Expected: 'Block(Assign(Ident''B'' Call(Ident''TButton'' ' +
       'Ident''Sender'')))'; ExpectDiags: 0),

    // ---- 18.1.1 a bare try-except with no on-do filter (18.1.2 already
    // covers the filtered form) ----
    (Section: '18.1.1'; Name: 'bare try-except';
     Source: 'try P except Q; end;';
     Expected: 'Block(TryStmt(Block(ExprStmt(Ident''P'')) ExceptPart(' +
       'Block(ExprStmt(Ident''Q'')))))'; ExpectDiags: 0),

    // ---- 18.4.1 raising the Exception base class directly ----
    (Section: '18.4.1'; Name: 'raise Exception.Create';
     Source: 'raise Exception.Create(''oops'');';
     Expected: 'Block(RaiseStmt(Call(Member(Ident''Exception'' ' +
       'Ident''Create'') StrLit''''oops'''')))'; ExpectDiags: 0),

    // ---- B.4.1 a genuinely RESERVED word (not a context-sensitive
    // directive, B.4.2's territory) escaped into identifier position ----
    (Section: 'B.4.1'; Name: 'escaped reserved word as an identifier';
     Source: '&Begin := 1;';
     Expected: 'Block(Assign(Ident''&Begin'' IntLit''1''))'; ExpectDiags: 0),

    // ---- 8.3.1 array-of-const at its CALL SITE -- a bracket literal
    // passed where the callee expects `array of const` (6.2.6 pins the
    // PARAMETER declaration; this is the argument, an ordinary SetCtor
    // like every other bracket literal -- what it MEANS is the callee's
    // parameter type, a typing question, not a parse-shape one) ----
    (Section: '8.3.1'; Name: 'array-of-const literal at a call site';
     Source: 'Writeln(Format(''%d %s'', [1, ''x'']));';
     Expected: 'Block(ExprStmt(Call(Ident''Writeln'' Call(Ident''Format'' ' +
       'StrLit''''%d %s'''' SetCtor(IntLit''1'' StrLit''''x'''')))))';
     ExpectDiags: 0),

    // ==== test-coverage plan step 3 batch 6 ====================

    // ---- 4.1 operator precedence, the full chain in one expression: unary
    // NOT binds tightest, then AND, then OR, then relational lowest -- 4.2's
    // batch-1 case only shows +/* against each other, one level ----
    (Section: '4.1'; Name: 'the full precedence chain in one expression';
     Source: 'B := not A and C or D = E;';
     Expected: 'Block(Assign(Ident''B'' BinaryOp''=''(BinaryOp''or''(' +
       'BinaryOp''and''(UnaryOp''not''(Ident''A'') Ident''C'') ' +
       'Ident''D'') Ident''E'')))'; ExpectDiags: 0),

    // ---- 4.7 the string `+` operator BETWEEN VARIABLES -- B.6.1's case
    // only shows adjacent STRING LITERALS, which the lexer merges into one
    // token before the parser ever sees an operator at all ----
    (Section: '4.7'; Name: 'string concatenation between variables';
     Source: 'S3 := S1 + S2;';
     Expected: 'Block(Assign(Ident''S3'' BinaryOp''+''(Ident''S1'' ' +
       'Ident''S2'')))'; ExpectDiags: 0),

    // ---- 10.1.2 the `nil` pointer LITERAL -- its own dedicated AST node
    // (nkNilLit, not an nkIdent -- a resolver-side probe this same batch
    // found the hard way), never pinned as its own case before, even
    // though `nil` appears incidentally all over the sema suites ----
    (Section: '10.1.2'; Name: 'the nil literal';
     Source: 'P := nil;';
     Expected: 'Block(Assign(Ident''P'' NilLit))'; ExpectDiags: 0),

    // ---- B.8 every designator FORM chained in one expression -- bare
    // name, member, index, dereference, call -- each shown separately
    // dozens of times, never all five links of the same chain together
    // the way B.8 itself enumerates them ----
    (Section: 'B.8'; Name: 'every designator form chained together';
     Source: 'A.B[C]^.D(E);';
     Expected: 'Block(ExprStmt(Call(Member(Deref(Index(Member(Ident''A'' ' +
       'Ident''B'') Ident''C'')) Ident''D'') Ident''E'')))'; ExpectDiags: 0)
  );

  DECL_CASES: array[0..112] of TPasCaseRow = (
    // ---- 3.1 variables ----
    // 3.1.4: the `absolute` expression is an ALIAS, and it lands in the same
    // child slot an initializer would -- only the mark separates them.
    (Section: '3.1.4'; Name: 'absolute';
     Source: 'var A: Integer absolute B;';
     Expected: 'VarSec''var''(VarDecl#absolute(Ident''A'' Ident''Integer'' ' +
       'Ident''B''))'; ExpectDiags: 0),
    (Section: '3.1.4'; Name: 'initializer is not absolute';
     Source: 'var A: Integer = 1;';
     Expected: 'VarSec''var''(VarDecl(Ident''A'' Ident''Integer'' ' +
       'IntLit''1''))'; ExpectDiags: 0),
    // 3.1.5: same section shape as `var`; the head word is the whole
    // difference, so the dump has to carry it.
    (Section: '3.1.5'; Name: 'threadvar'; Source: 'threadvar T: Integer;';
     Expected: 'VarSec''threadvar''(VarDecl(Ident''T'' Ident''Integer''))';
     ExpectDiags: 0),

    // ---- 3.2 constants ----
    // 3.2.3: a resourcestring section parses as a const section.
    (Section: '3.2.3'; Name: 'resourcestring';
     Source: 'resourcestring SHi = ''hi'';';
     Expected: 'ConstSec''resourcestring''(ConstDecl(Ident''SHi'' ' +
       'StrLit''''hi''''))'; ExpectDiags: 0),

    // ---- 2.5.1 distinct alias ----
    (Section: '2.5.1'; Name: 'plain alias'; Source: 'type TId = Integer;';
     Expected: 'TypeSec(TypeDecl(Ident''TId'' Ident''Integer''))';
     ExpectDiags: 0),
    (Section: '2.5.1'; Name: 'distinct alias';
     Source: 'type TId = type Integer;';
     Expected: 'TypeSec(TypeDecl#distinct(Ident''TId'' Ident''Integer''))';
     ExpectDiags: 0),

    // ---- 6.6.1 procedural types ----
    (Section: '6.6.1'; Name: 'procedure type';
     Source: 'type TProc = procedure(A: Integer);';
     Expected: 'TypeSec(TypeDecl(Ident''TProc'' ProcType(Params(Param(' +
       'Ident''A'' Ident''Integer'')))))'; ExpectDiags: 0),
    (Section: '6.6.1'; Name: 'method pointer';
     Source: 'type TEvent = procedure(Sender: TObject) of object;';
     Expected: 'TypeSec(TypeDecl(Ident''TEvent'' ProcType#ofobject(' +
       'Params(Param(Ident''Sender'' Ident''TObject'')))))'; ExpectDiags: 0),
    (Section: '6.6.1'; Name: 'reference to';
     Source: 'type TFn = reference to function: Integer;';
     Expected: 'TypeSec(TypeDecl(Ident''TFn'' ProcType#reference(' +
       'Ident''Integer'')))'; ExpectDiags: 0),

    // ---- 9.2 record members ----
    // 9.2.1 / 9.2.2: a record takes methods, properties and class members,
    // and a record CONSTRUCTOR is a constructor -- which the head word is
    // the only thing that says.
    (Section: '9.2.1'; Name: 'record members';
     Source: 'type'#13#10'  TR = record'#13#10 +
       '    FX: Integer;'#13#10 +
       '    class var Count: Integer;'#13#10 +
       '    procedure Go;'#13#10 +
       '    class function Make: TR; static;'#13#10 +
       '    property X: Integer read FX write FX;'#13#10 +
       '  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TR'' RecordType(' +
       'VarDecl(Ident''FX'' Ident''Integer'') ' +
       'VarSec#class(VarDecl(Ident''Count'' Ident''Integer'')) ' +
       'Routine''procedure''(Ident''Go'') ' +
       'Routine''function''#class(Ident''Make'' Ident''TR'' ' +
       'Directive''static'') ' +
       'PropertyDecl(Ident''X'' Ident''Integer'' PropSpec''read''(' +
       'Ident''FX'') PropSpec''write''(Ident''FX'')))))'; ExpectDiags: 0),
    (Section: '9.2.2'; Name: 'record constructor';
     Source: 'type TR = record constructor Create(A: Integer); end;';
     Expected: 'TypeSec(TypeDecl(Ident''TR'' RecordType(' +
       'Routine''constructor''(Ident''Create'' Params(Param(Ident''A'' ' +
       'Ident''Integer''))))))'; ExpectDiags: 0),

    // ---- 11.x classes ----
    (Section: '11.1.1'; Name: 'forward declaration';
     Source: 'type TC = class;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType#forward))';
     ExpectDiags: 0),
    // 11.2.1: which visibility a section introduces is its head word, and
    // `strict` makes it a different one again.
    (Section: '11.2.1'; Name: 'visibility sections';
     Source: 'type'#13#10'  TC = class'#13#10 +
       '  strict private'#13#10'    FA: Integer;'#13#10 +
       '  protected'#13#10'    FB: Integer;'#13#10 +
       '  published'#13#10'    FC: Integer;'#13#10 +
       '  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(' +
       'Visibility''private''#strict VarDecl(Ident''FA'' Ident''Integer'') ' +
       'Visibility''protected'' VarDecl(Ident''FB'' Ident''Integer'') ' +
       'Visibility''published'' VarDecl(Ident''FC'' Ident''Integer''))))';
     ExpectDiags: 0),
    // 12.2.3 reintroduce, and 12.2.1 virtual/override -- directives are
    // nodes, and which directive it is is the head word.
    (Section: '12.2.3'; Name: 'reintroduce';
     Source: 'type'#13#10'  TC = class(TObject)'#13#10 +
       '    procedure P; virtual;'#13#10 +
       '    procedure Q; reintroduce; overload;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(Ident''TObject'' ' +
       'Routine''procedure''(Ident''P'' Directive''virtual'') ' +
       'Routine''procedure''(Ident''Q'' Directive''reintroduce'' ' +
       'Directive''overload''))))'; ExpectDiags: 0),

    // ---- 14.x interfaces ----
    (Section: '14.1.2'; Name: 'dispinterface';
     Source: 'type'#13#10'  ID = dispinterface'#13#10 +
       '    [''{11111111-2222-3333-4444-555555555555}'']'#13#10 +
       '    procedure P;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''ID'' InterfaceType#disp(Guid ' +
       'Routine''procedure''(Ident''P''))))'; ExpectDiags: 0),
    (Section: '14.1.1'; Name: 'interface is not a dispinterface';
     Source: 'type IFoo = interface procedure P; end;';
     Expected: 'TypeSec(TypeDecl(Ident''IFoo'' InterfaceType(' +
       'Routine''procedure''(Ident''P''))))'; ExpectDiags: 0),
    // 14.4.1: `implements` is a property SPECIFIER, so the delegation
    // target sits where `read`/`write` targets do and only the head word
    // separates them.
    (Section: '14.4.1'; Name: 'implements';
     Source: 'type'#13#10'  TC = class(TObject, IFoo)'#13#10 +
       '    property Impl: IFoo read FImpl implements IFoo;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(Ident''TObject'' ' +
       'Ident''IFoo'' PropertyDecl(Ident''Impl'' Ident''IFoo'' ' +
       'PropSpec''read''(Ident''FImpl'') ' +
       'PropSpec''implements''(Ident''IFoo'')))))'; ExpectDiags: 0),
    // 14.2.2 method resolution clause.
    (Section: '14.2.2'; Name: 'method resolution';
     Source: 'type'#13#10'  TC = class(TObject, IFoo)'#13#10 +
       '    procedure IFoo.P = MyP;'#13#10'  end;';
     // The clause's three names are FLAT children -- interface, its method,
     // the implementing name -- not a Member designator.
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(Ident''TObject'' ' +
       'Ident''IFoo'' MethodResolution(Ident''IFoo'' Ident''P'' ' +
       'Ident''MyP''))))'; ExpectDiags: 0),

    // ---- 15.3.1 helpers ----
    (Section: '15.3.1'; Name: 'class helper';
     Source: 'type TH = class helper for TObject procedure P; end;';
     Expected: 'TypeSec(TypeDecl(Ident''TH'' HelperType(Ident''TObject'' ' +
       'Routine''procedure''(Ident''P''))))'; ExpectDiags: 0),
    (Section: '15.3.1'; Name: 'record helper';
     Source: 'type TH = record helper for Integer procedure P; end;';
     Expected: 'TypeSec(TypeDecl(Ident''TH'' HelperType#record(' +
       'Ident''Integer'' Routine''procedure''(Ident''P''))))';
     ExpectDiags: 0),

    // ---- 2.5.2 hint directives on a TYPE decl -- each hint is its own
    // nkDirective child of the TypeDecl (mirrors a routine's directives) ----
    (Section: '2.5.2'; Name: 'deprecated hint';
     Source: 'type TFoo = Integer deprecated;';
     Expected: 'TypeSec(TypeDecl(Ident''TFoo'' Ident''Integer'' ' +
       'Directive''deprecated''))'; ExpectDiags: 0),
    (Section: '2.5.2'; Name: 'deprecated hint with message';
     Source: 'type TFoo = Integer deprecated ''do not use'';';
     Expected: 'TypeSec(TypeDecl(Ident''TFoo'' Ident''Integer'' ' +
       'Directive''deprecated''(StrLit''''do not use'''')))'; ExpectDiags: 0),
    (Section: '2.5.2'; Name: 'platform hint';
     Source: 'type TFoo = Integer platform;';
     Expected: 'TypeSec(TypeDecl(Ident''TFoo'' Ident''Integer'' ' +
       'Directive''platform''))'; ExpectDiags: 0),

    // ---- 7.1.x string types: only AnsiString/WideString had ever appeared ----
    (Section: '7.1.1'; Name: 'UnicodeString';
     Source: 'type TS = UnicodeString;';
     Expected: 'TypeSec(TypeDecl(Ident''TS'' Ident''UnicodeString''))';
     ExpectDiags: 0),
    (Section: '7.1.3'; Name: 'short string with a capacity';
     Source: 'type TS = string[10];';
     Expected: 'TypeSec(TypeDecl(Ident''TS'' StringType(IntLit''10'')))';
     ExpectDiags: 0),
    (Section: '7.1.5'; Name: 'RawByteString and UTF8String';
     Source: 'type'#13#10'  TA = RawByteString;'#13#10 +
       '  TB = UTF8String;';
     Expected: 'TypeSec(TypeDecl(Ident''TA'' Ident''RawByteString'') ' +
       'TypeDecl(Ident''TB'' Ident''UTF8String''))'; ExpectDiags: 0),

    // ---- 6.2.7 untyped parameters: a name with no ':' type at all ----
    (Section: '6.2.7'; Name: 'untyped var parameter';
     Source: 'procedure P(var X);';
     Expected: 'Routine''procedure''(Ident''P'' Params(Param(Ident''X'')))';
     ExpectDiags: 0),

    // ---- 6.7.1 external, never exercised at all (varargs alone was) ----
    (Section: '6.7.1'; Name: 'external plain';
     Source: 'procedure P; external ''user32.dll'';';
     Expected: 'Routine''procedure''(Ident''P'' Directive''external''(' +
       'StrLit''''user32.dll''''))'; ExpectDiags: 0),
    (Section: '6.7.1'; Name: 'external name';
     Source: 'procedure P; external ''user32.dll'' name ''RealP'';';
     Expected: 'Routine''procedure''(Ident''P'' Directive''external''(' +
       'StrLit''''user32.dll'''' StrLit''''RealP''''))'; ExpectDiags: 0),
    (Section: '6.7.1'; Name: 'external index';
     Source: 'function F: Integer; external ''k32.dll'' index 5;';
     Expected: 'Routine''function''(Ident''F'' Ident''Integer'' ' +
       'Directive''external''(StrLit''''k32.dll'''' IntLit''5''))';
     ExpectDiags: 0),
    (Section: '6.7.1'; Name: 'external delayed';
     Source: 'procedure P; external ''x.dll'' delayed;';
     // `delayed` is consumed but adopts no child of its own -- only name/
     // index/dependency arguments become children (ParseRoutineDirectives).
     Expected: 'Routine''procedure''(Ident''P'' Directive''external''(' +
       'StrLit''''x.dll''''))'; ExpectDiags: 0),

    // ---- 14.3.2 [weak]/[unsafe] on an interface-typed field: an attribute
    // group in member position -- pin the CURRENT shape, since the parser
    // adopts it onto the class, a SIBLING of the field, not onto the field
    // itself (ParseMemberList's tkLBracket branch) ----
    (Section: '14.3.2'; Name: 'weak attribute on an interface field';
     Source: 'type'#13#10'  TC = class'#13#10 +
       '    [weak] FFoo: IFoo;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(AttrGroup(' +
       'Attribute#weak(Ident''weak'')) VarDecl(Ident''FFoo'' Ident''IFoo''))))';
     ExpectDiags: 0),

    // ---- 19.3.2 an attribute WITH ARGUMENTS -- attributes appear in NO
    // fixture at all per the audit, args included ----
    // The attribute must sit AFTER the `type` keyword, right before the
    // NAME it decorates -- one written before `type` itself lands as its
    // own sibling declaration in the enclosing section instead (probed).
    (Section: '19.3.2'; Name: 'attribute with arguments on a type';
     Source: 'type'#13#10'  [MyAttr(1, ''s'')] TFoo = class end;';
     Expected: 'TypeSec(TypeDecl(AttrGroup(Attribute(Ident''MyAttr'' ' +
       'IntLit''1'' StrLit''''s'''')) Ident''TFoo'' ClassType))';
     ExpectDiags: 0),

    // ---- 19.3.3 compiler-recognized ("magic") attributes -- matched by
    // NAME (PasAttrMagicAux), per the spec's own "lightweight parser"
    // allowance; real semantics are 6.2.3/14.3.2/20.6.1's concern, this is
    // only the RECOGNITION step. [Volatile] and [unsafe] had no fixture at
    // all before this ([Ref]/[weak] did, retagged above); the ordinary
    // `[MyAttr]` case right above is the discriminating half -- an
    // attribute the compiler does NOT recognize gets no `#` tag. ----
    (Section: '19.3.3'; Name: '[Volatile] on a field';
     Source: 'type TC = class [Volatile] F: Integer; end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(AttrGroup(' +
       'Attribute#volatile(Ident''Volatile'')) VarDecl(Ident''F'' ' +
       'Ident''Integer''))))';
     ExpectDiags: 0),
    (Section: '19.3.3'; Name: '[unsafe] as an ATTRIBUTE, not the directive '
      + 'word';
     Source: 'type TC = class [unsafe] F: TObject; end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(AttrGroup(' +
       'Attribute#unsafe(Ident''unsafe'')) VarDecl(Ident''F'' ' +
       'Ident''TObject''))))';
     ExpectDiags: 0),
    (Section: '19.3.3'; Name: 'the Attribute suffix is recognized too';
     Source: 'type TC = class [WeakAttribute] F: IInterface; end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(AttrGroup(' +
       'Attribute#weak(Ident''WeakAttribute'')) VarDecl(Ident''F'' ' +
       'Ident''IInterface''))))';
     ExpectDiags: 0),

    // ==== test-coverage plan step 3 batch 3 ====================

    // ---- 1.2.1 / 1.2.2 the uses clause, plain and dotted (namespaced) ----
    (Section: '1.2.1'; Name: 'uses clause';
     Source: 'uses SysUtils, Classes;';
     Expected: 'UsesClause(UsesItem(Ident''SysUtils'') ' +
       'UsesItem(Ident''Classes''))'; ExpectDiags: 0),
    (Section: '1.2.2'; Name: 'dotted unit name';
     Source: 'uses System.SysUtils;';
     Expected: 'UsesClause(UsesItem(Member(Ident''System'' ' +
       'Ident''SysUtils'')))'; ExpectDiags: 0),

    // ---- 2.2.4 enumerated types, plain and with explicit ordinal values ----
    (Section: '2.2.4'; Name: 'enum type';
     Source: 'type TColor = (Red, Green, Blue);';
     Expected: 'TypeSec(TypeDecl(Ident''TColor'' EnumType(' +
       'EnumValue(Ident''Red'') EnumValue(Ident''Green'') ' +
       'EnumValue(Ident''Blue''))))'; ExpectDiags: 0),
    (Section: '2.2.4'; Name: 'enum with explicit values';
     Source: 'type TE = (A, B = 5, C);';
     Expected: 'TypeSec(TypeDecl(Ident''TE'' EnumType(EnumValue(' +
       'Ident''A'') EnumValue(Ident''B'' IntLit''5'') ' +
       'EnumValue(Ident''C''))))'; ExpectDiags: 0),

    // ---- 2.2.5 subrange types ----
    (Section: '2.2.5'; Name: 'subrange type';
     Source: 'type TDigit = 0..9;';
     Expected: 'TypeSec(TypeDecl(Ident''TDigit'' Subrange(IntLit''0'' ' +
       'IntLit''9'')))'; ExpectDiags: 0),

    // ---- 2.4.1 set of ordinal ----
    (Section: '2.4.1'; Name: 'set of a builtin ordinal type';
     Source: 'type TFlags = set of Byte;';
     Expected: 'TypeSec(TypeDecl(Ident''TFlags'' SetType(Ident''Byte'')))';
     ExpectDiags: 0),

    // ---- 6.1.2 forward declarations ----
    (Section: '6.1.2'; Name: 'forward declaration';
     Source: 'procedure P; forward;';
     Expected: 'Routine''procedure''(Ident''P'' Directive''forward'')';
     ExpectDiags: 0),

    // ---- 6.2.1-6.2.4 every parameter passing mode in one signature ----
    (Section: '6.2.1'; Name: 'value, var, const, out parameters';
     Source: 'procedure P(A: Integer; var B: Integer; const C: Integer; ' +
       'out D: Integer);';
     Expected: 'Routine''procedure''(Ident''P'' Params(Param(Ident''A'' ' +
       'Ident''Integer'') Param(Ident''B'' Ident''Integer'') ' +
       'Param(Ident''C'' Ident''Integer'') Param#out(Ident''D'' ' +
       'Ident''Integer'')))'; ExpectDiags: 0),

    // ---- 6.2.5 default (optional) parameters ----
    (Section: '6.2.5'; Name: 'default parameter value';
     Source: 'procedure P(A: Integer = 5);';
     Expected: 'Routine''procedure''(Ident''P'' Params(Param(Ident''A'' ' +
       'Ident''Integer'' IntLit''5'')))'; ExpectDiags: 0),

    // ---- 6.2.6 open array and array-of-const parameters ----
    (Section: '6.2.6'; Name: 'open array and array of const parameters';
     Source: 'procedure P(const A: array of Integer; const B: array of const);';
     Expected: 'Routine''procedure''(Ident''P'' Params(Param(Ident''A'' ' +
       'ArrayType(Ident''Integer'')) Param(Ident''B'' ArrayType#ofconst)))';
     ExpectDiags: 0),

    // ---- 6.3.1 / 6.4.1 / 6.5.1 / 6.8 routine directives never exercised on
    // a plain (non-external, non-message) routine before ----
    (Section: '6.3.1'; Name: 'overload directive';
     Source: 'procedure P(A: Integer); overload;';
     Expected: 'Routine''procedure''(Ident''P'' Params(Param(Ident''A'' ' +
       'Ident''Integer'')) Directive''overload'')'; ExpectDiags: 0),
    (Section: '6.4.1'; Name: 'inline directive';
     Source: 'procedure P; inline;';
     Expected: 'Routine''procedure''(Ident''P'' Directive''inline'')';
     ExpectDiags: 0),
    (Section: '6.5.1'; Name: 'calling convention directives';
     Source: 'procedure P; stdcall;'#13#10'procedure Q; cdecl;';
     Expected: 'Routine''procedure''(Ident''P'' Directive''stdcall'') ' +
       'Routine''procedure''(Ident''Q'' Directive''cdecl'')';
     ExpectDiags: 0),
    (Section: '6.8'; Name: 'noreturn directive';
     Source: 'procedure P; noreturn;';
     Expected: 'Routine''procedure''(Ident''P'' Directive''noreturn'')';
     ExpectDiags: 0),

    // ---- 7.1.6 PChar and pointer-to-char types ----
    (Section: '7.1.6'; Name: 'PChar alias';
     Source: 'type TP = PChar;';
     Expected: 'TypeSec(TypeDecl(Ident''TP'' Ident''PChar''))';
     ExpectDiags: 0),

    // ---- 8.1.1 / 8.1.2 static arrays, single and multi-dimensional ----
    (Section: '8.1.1'; Name: 'single-dimension static array';
     Source: 'type TArr = array[0..9] of Integer;';
     Expected: 'TypeSec(TypeDecl(Ident''TArr'' ArrayType(Subrange(' +
       'IntLit''0'' IntLit''9'') Ident''Integer'')))'; ExpectDiags: 0),
    (Section: '8.1.2'; Name: 'multidimensional static array';
     Source: 'type TGrid = array[0..1, 0..1] of Integer;';
     Expected: 'TypeSec(TypeDecl(Ident''TGrid'' ArrayType(Subrange(' +
       'IntLit''0'' IntLit''1'') Subrange(IntLit''0'' IntLit''1'') ' +
       'Ident''Integer'')))'; ExpectDiags: 0),

    // ---- 8.2.1 dynamic array types ----
    (Section: '8.2.1'; Name: 'dynamic array type';
     Source: 'type TArr = array of Integer;';
     Expected: 'TypeSec(TypeDecl(Ident''TArr'' ArrayType(Ident''Integer'')))';
     ExpectDiags: 0),

    // ---- 9.1.2 packed records ----
    (Section: '9.1.2'; Name: 'packed record';
     Source: 'type TR = packed record X: Byte; end;';
     Expected: 'TypeSec(TypeDecl(Ident''TR'' RecordType(VarDecl(' +
       'Ident''X'' Ident''Byte''))))'; ExpectDiags: 0),

    // ---- 9.1.3 variant records (the `case` part) ----
    (Section: '9.1.3'; Name: 'variant record';
     Source: 'type'#13#10'  TR = record'#13#10 +
       '    case Integer of'#13#10 +
       '      0: (X: Integer);'#13#10 +
       '      1: (Y: Single);'#13#10 +
       '  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TR'' RecordType(VariantPart(' +
       'Ident''Integer'' VariantBranch(IntLit''0'' VarDecl(Ident''X'' ' +
       'Ident''Integer'')) VariantBranch(IntLit''1'' VarDecl(Ident''Y'' ' +
       'Ident''Single''))))))'; ExpectDiags: 0),

    // ---- 9.3.1 class operator declarations ----
    (Section: '9.3.1'; Name: 'class operator';
     Source: 'type TVec = record'#13#10 +
       '    class operator Add(A, B: TVec): TVec;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TVec'' RecordType(' +
       'Routine''operator''#class(Ident''Add'' Params(Param(Ident''A'' ' +
       'Ident''B'' Ident''TVec'')) Ident''TVec''))))'; ExpectDiags: 0),

    // ---- 10.1.1 / 10.1.2 typed and untyped pointers ----
    (Section: '10.1.1'; Name: 'typed pointer';
     Source: 'type PInt = ^Integer;';
     Expected: 'TypeSec(TypeDecl(Ident''PInt'' PointerType(' +
       'Ident''Integer'')))'; ExpectDiags: 0),
    (Section: '10.1.2'; Name: 'untyped Pointer variable';
     Source: 'var P: Pointer;';
     Expected: 'VarSec''var''(VarDecl(Ident''P'' Ident''Pointer''))';
     ExpectDiags: 0),

    // ---- 10.2.1 typed, text, and untyped files ----
    (Section: '10.2.1'; Name: 'typed, text and untyped file types';
     Source: 'type'#13#10'  TTypedFile = file of Integer;'#13#10 +
       '  TUntypedFile = file;'#13#10'  TTextFile = TextFile;';
     Expected: 'TypeSec(TypeDecl(Ident''TTypedFile'' FileType(' +
       'Ident''Integer'')) TypeDecl(Ident''TUntypedFile'' FileType) ' +
       'TypeDecl(Ident''TTextFile'' Ident''TextFile''))'; ExpectDiags: 0),

    // ---- 11.3.1 / 11.3.2 class constructors and destructors (9.2.2 already
    // pins a RECORD constructor; a class needs its own case since the
    // ancestor and `override` shape differ) ----
    (Section: '11.3.1'; Name: 'class constructor declaration';
     Source: 'type TC = class(TObject)'#13#10 +
       '    constructor Create(A: Integer);'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(Ident''TObject'' ' +
       'Routine''constructor''(Ident''Create'' Params(Param(Ident''A'' ' +
       'Ident''Integer''))))))'; ExpectDiags: 0),
    (Section: '11.3.2'; Name: 'class destructor declaration';
     Source: 'type TC = class(TObject)'#13#10 +
       '    destructor Destroy; override;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(Ident''TObject'' ' +
       'Routine''destructor''(Ident''Destroy'' Directive''override''))))';
     ExpectDiags: 0),

    // ---- 11.4.1 nested type and const declarations inside a class ----
    (Section: '11.4.1'; Name: 'nested type and const';
     Source: 'type'#13#10'  TOuter = class'#13#10 +
       '  type'#13#10'    TInner = record end;'#13#10 +
       '  const'#13#10'    KMax = 10;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TOuter'' ClassType(TypeSec(' +
       'TypeDecl(Ident''TInner'' RecordType)) ConstSec''const''(' +
       'ConstDecl(Ident''KMax'' IntLit''10'')))))'; ExpectDiags: 0),

    // ---- 11.5 legacy object types ----
    (Section: '11.5'; Name: 'legacy object type';
     Source: 'type TObj = object'#13#10'    X: Integer;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TObj'' ObjectType(VarDecl(' +
       'Ident''X'' Ident''Integer''))))'; ExpectDiags: 0),

    // ---- 12.2.1 / 12.2.2 / 12.2.4 / 12.2.5 method-binding directives ----
    (Section: '12.2.1'; Name: 'virtual and override';
     Source: 'type'#13#10'  TBase = class'#13#10 +
       '    procedure P; virtual;'#13#10'  end;'#13#10 +
       '  TSub = class(TBase)'#13#10 +
       '    procedure P; override;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TBase'' ClassType(' +
       'Routine''procedure''(Ident''P'' Directive''virtual''))) ' +
       'TypeDecl(Ident''TSub'' ClassType(Ident''TBase'' ' +
       'Routine''procedure''(Ident''P'' Directive''override''))))';
     ExpectDiags: 0),
    (Section: '12.2.2'; Name: 'dynamic directive';
     Source: 'type TC = class'#13#10'    procedure P; dynamic;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(' +
       'Routine''procedure''(Ident''P'' Directive''dynamic''))))';
     ExpectDiags: 0),
    (Section: '12.2.4'; Name: 'abstract method';
     Source: 'type TC = class'#13#10 +
       '    procedure P; virtual; abstract;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(' +
       'Routine''procedure''(Ident''P'' Directive''virtual'' ' +
       'Directive''abstract''))))'; ExpectDiags: 0),
    (Section: '12.2.5'; Name: 'sealed class and final method';
     Source: 'type TC = class sealed'#13#10 +
       '    procedure P; virtual; final;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(' +
       'Routine''procedure''(Ident''P'' Directive''virtual'' ' +
       'Directive''final''))))'; ExpectDiags: 0),

    // ---- 12.3.1 message methods ----
    (Section: '12.3.1'; Name: 'message method';
     Source: 'type TC = class'#13#10 +
       '    procedure WMPaint(var Msg: TMessage); message WM_PAINT;'#13#10 +
       '  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(' +
       'Routine''procedure''(Ident''WMPaint'' Params(Param(Ident''Msg'' ' +
       'Ident''TMessage'')) Directive''message''(Ident''WM_PAINT'')))))';
     ExpectDiags: 0),

    // ---- 13.1.2 / 13.1.3 / 13.1.4 / 13.1.5 / 13.3.1 property shapes ----
    (Section: '13.1.2'; Name: 'array property';
     Source: 'type TC = class'#13#10 +
       '    property Items[Idx: Integer]: string read GetItem write SetItem;'#13#10 +
       '  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(PropertyDecl(' +
       'Ident''Items'' Params(Param(Ident''Idx'' Ident''Integer'')) ' +
       'Ident''string'' PropSpec''read''(Ident''GetItem'') ' +
       'PropSpec''write''(Ident''SetItem'')))))'; ExpectDiags: 0),
    (Section: '13.1.3'; Name: 'indexed property (index directive)';
     Source: 'type TC = class'#13#10 +
       '    property Value: Integer index 1 read GetValue write SetValue;'#13#10 +
       '  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(PropertyDecl(' +
       'Ident''Value'' Ident''Integer'' PropSpec''index''(IntLit''1'') ' +
       'PropSpec''read''(Ident''GetValue'') PropSpec''write''(' +
       'Ident''SetValue'')))))'; ExpectDiags: 0),
    (Section: '13.1.4'; Name: 'default array property';
     Source: 'type TC = class'#13#10 +
       '    property Items[I: Integer]: string read GetItem; default;'#13#10 +
       '  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(PropertyDecl(' +
       'Ident''Items'' Params(Param(Ident''I'' Ident''Integer'')) ' +
       'Ident''string'' PropSpec''read''(Ident''GetItem'') ' +
       'PropSpec''default''))))'; ExpectDiags: 0),
    (Section: '13.1.5'; Name: 'default, nodefault and stored specifiers';
     Source: 'type TC = class'#13#10 +
       '    property X: Integer read FX write FX default 0;'#13#10 +
       '    property Y: Integer read FY write FY stored False;'#13#10 +
       '  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(PropertyDecl(' +
       'Ident''X'' Ident''Integer'' PropSpec''read''(Ident''FX'') ' +
       'PropSpec''write''(Ident''FX'') PropSpec''default''(IntLit''0'')) ' +
       'PropertyDecl(Ident''Y'' Ident''Integer'' PropSpec''read''(' +
       'Ident''FY'') PropSpec''write''(Ident''FY'') PropSpec''stored''(' +
       'Ident''False'')))))'; ExpectDiags: 0),
    (Section: '13.3.1'; Name: 'event (method-pointer) property';
     Source: 'type TC = class'#13#10 +
       '    property OnClick: TNotifyEvent read FOnClick write FOnClick;'#13#10 +
       '  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(PropertyDecl(' +
       'Ident''OnClick'' Ident''TNotifyEvent'' PropSpec''read''(' +
       'Ident''FOnClick'') PropSpec''write''(Ident''FOnClick'')))))';
     ExpectDiags: 0),

    // ---- 15.1.4 / 15.1.5 / 15.2.1 class mechanics not yet exercised ----
    (Section: '15.1.4'; Name: 'static class method';
     Source: 'type TC = class'#13#10 +
       '    class procedure P; static;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(' +
       'Routine''procedure''#class(Ident''P'' Directive''static''))))';
     ExpectDiags: 0),
    (Section: '15.1.5'; Name: 'class constructor and destructor';
     Source: 'type TC = class'#13#10 +
       '    class constructor Create;'#13#10 +
       '    class destructor Destroy;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(' +
       'Routine''constructor''#class(Ident''Create'') ' +
       'Routine''destructor''#class(Ident''Destroy''))))'; ExpectDiags: 0),
    (Section: '15.2.1'; Name: 'class of type';
     Source: 'type TClassRef = class of TObject;';
     Expected: 'TypeSec(TypeDecl(Ident''TClassRef'' ClassOf(' +
       'Ident''TObject'')))'; ExpectDiags: 0),

    // ---- 16.1.1 / 16.4.1 generics never pinned at the DECLARATION level
    // (16.3 already covers a generic reference in an EXPRESSION) ----
    (Section: '16.1.1'; Name: 'generic class declaration';
     Source: 'type TBox<T> = class'#13#10'    FValue: T;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TBox'' GenericParams(' +
       'GenericParam(Ident''T'')) ClassType(VarDecl(Ident''FValue'' ' +
       'Ident''T''))))'; ExpectDiags: 0),
    (Section: '16.4.1'; Name: 'generic type-parameter constraints';
     Source: 'type TBox<T: class, constructor> = class end;';
     Expected: 'TypeSec(TypeDecl(Ident''TBox'' GenericParams(' +
       'GenericParam(Ident''T'' Constraint''class'' ' +
       'Constraint''constructor'')) ClassType))'; ExpectDiags: 0),
    // ...and a SPECIFIC-type constraint keeps its child instead of a head
    // word (the constraint IS the type ref, not a fixed keyword).
    (Section: '16.4.1'; Name: 'a specific-type constraint keeps its child';
     Source: 'type TBox<T: IInterface> = class end;';
     Expected: 'TypeSec(TypeDecl(Ident''TBox'' GenericParams(' +
       'GenericParam(Ident''T'' Constraint(Ident''IInterface''))) ' +
       'ClassType))'; ExpectDiags: 0),

    // ==== test-coverage plan step 3 batch 4 ====================

    // ---- 2.2.1 / 2.2.2 / 2.2.3 / 2.3.1 the builtin type FAMILIES: only
    // ONE representative of each had ever appeared (Integer/Boolean/Char/
    // string), never the rest of the family ----
    (Section: '2.2.1'; Name: 'the integer type family';
     Source: 'type'#13#10'  T1 = ShortInt;'#13#10'  T2 = SmallInt;'#13#10 +
       '  T3 = Int64;'#13#10'  T4 = Cardinal;';
     Expected: 'TypeSec(TypeDecl(Ident''T1'' Ident''ShortInt'') ' +
       'TypeDecl(Ident''T2'' Ident''SmallInt'') TypeDecl(Ident''T3'' ' +
       'Ident''Int64'') TypeDecl(Ident''T4'' Ident''Cardinal''))';
     ExpectDiags: 0),
    (Section: '2.2.2'; Name: 'the boolean type family';
     Source: 'type T1 = ByteBool; T2 = LongBool;';
     Expected: 'TypeSec(TypeDecl(Ident''T1'' Ident''ByteBool'') ' +
       'TypeDecl(Ident''T2'' Ident''LongBool''))'; ExpectDiags: 0),
    (Section: '2.2.3'; Name: 'the character type family';
     Source: 'type T1 = AnsiChar; T2 = WideChar;';
     Expected: 'TypeSec(TypeDecl(Ident''T1'' Ident''AnsiChar'') ' +
       'TypeDecl(Ident''T2'' Ident''WideChar''))'; ExpectDiags: 0),
    (Section: '2.3.1'; Name: 'the predefined real type family';
     Source: 'type'#13#10'  T1 = Single;'#13#10'  T2 = Double;'#13#10 +
       '  T3 = Extended;'#13#10'  T4 = Currency;'#13#10'  T5 = Comp;';
     Expected: 'TypeSec(TypeDecl(Ident''T1'' Ident''Single'') ' +
       'TypeDecl(Ident''T2'' Ident''Double'') TypeDecl(Ident''T3'' ' +
       'Ident''Extended'') TypeDecl(Ident''T4'' Ident''Currency'') ' +
       'TypeDecl(Ident''T5'' Ident''Comp''))'; ExpectDiags: 0),

    // ---- 3.1.1 / 3.1.2 a plain (non-inline, non-absolute) var section,
    // uninitialized and initialized ----
    (Section: '3.1.1'; Name: 'plain var declaration';
     Source: 'var X: Integer;';
     Expected: 'VarSec''var''(VarDecl(Ident''X'' Ident''Integer''))';
     ExpectDiags: 0),
    (Section: '3.1.2'; Name: 'initialized global variable';
     Source: 'var X: Integer = 5;';
     Expected: 'VarSec''var''(VarDecl(Ident''X'' Ident''Integer'' ' +
       'IntLit''5''))'; ExpectDiags: 0),

    // ---- 3.2.1 / 3.2.2 a true (untyped) constant vs. a TYPED constant ----
    (Section: '3.2.1'; Name: 'true constant';
     Source: 'const K = 5;';
     Expected: 'ConstSec''const''(ConstDecl(Ident''K'' IntLit''5''))';
     ExpectDiags: 0),
    (Section: '3.2.2'; Name: 'typed constant';
     Source: 'const K: Integer = 5;';
     Expected: 'ConstSec''const''(ConstDecl(Ident''K'' Ident''Integer'' ' +
       'IntLit''5''))'; ExpectDiags: 0),

    // ---- 6.2.2 / 6.2.3 var and const parameters standing alone (6.2.1's
    // batch-3 case combines all four modes in one signature; these give
    // each of the two REFERENCE modes its own minimal, dedicated case).
    // 6.2.3 also covers `const [Ref]`, the attributed form the spec names
    // for this section specifically ----
    (Section: '6.2.2'; Name: 'a lone var parameter';
     Source: 'procedure P(var A: Integer);';
     Expected: 'Routine''procedure''(Ident''P'' Params(Param(Ident''A'' ' +
       'Ident''Integer'')))'; ExpectDiags: 0),
    (Section: '6.2.3'; Name: 'const [Ref] parameter';
     Source: 'procedure P(const [Ref] A: Integer);';
     Expected: 'Routine''procedure''(Ident''P'' Params(Param(AttrGroup(' +
       'Attribute#ref(Ident''Ref'')) Ident''A'' Ident''Integer'')))';
     ExpectDiags: 0),
    (Section: '6.2.4'; Name: 'a lone out parameter';
     Source: 'procedure P(out A: Integer);';
     Expected: 'Routine''procedure''(Ident''P'' Params(Param#out(' +
       'Ident''A'' Ident''Integer'')))'; ExpectDiags: 0),

    // ---- 7.1.2 / 7.1.4 AnsiString and WideString ----
    (Section: '7.1.2'; Name: 'AnsiString';
     Source: 'type TA = AnsiString;';
     Expected: 'TypeSec(TypeDecl(Ident''TA'' Ident''AnsiString''))';
     ExpectDiags: 0),
    (Section: '7.1.4'; Name: 'WideString';
     Source: 'type TW = WideString;';
     Expected: 'TypeSec(TypeDecl(Ident''TW'' Ident''WideString''))';
     ExpectDiags: 0),

    // ---- 9.1.1 a simple record, no methods/properties/class members
    // (9.2.1's batch-1 case already covers those richer member kinds) ----
    (Section: '9.1.1'; Name: 'simple record';
     Source: 'type TPoint = record X, Y: Integer; end;';
     Expected: 'TypeSec(TypeDecl(Ident''TPoint'' RecordType(VarDecl(' +
       'Ident''X'' Ident''Y'' Ident''Integer''))))'; ExpectDiags: 0),

    // ---- 9.4.1 the three record lifecycle operators the spec names --
    // same class-operator SHAPE 9.3.1 already pins (a different name),
    // but with their real signatures: `out`/`var`/`const [Ref]` params ----
    (Section: '9.4.1'; Name: 'Initialize, Finalize and Assign operators';
     Source: 'type TR = record'#13#10 +
       '    class operator Initialize(out Dest: TR);'#13#10 +
       '    class operator Finalize(var Dest: TR);'#13#10 +
       '    class operator Assign(var Dest: TR; const [Ref] Src: TR);'#13#10 +
       '  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TR'' RecordType(' +
       'Routine''operator''#class(Ident''Initialize'' Params(Param#out(' +
       'Ident''Dest'' Ident''TR''))) Routine''operator''#class(' +
       'Ident''Finalize'' Params(Param(Ident''Dest'' Ident''TR''))) ' +
       'Routine''operator''#class(Ident''Assign'' Params(Param(' +
       'Ident''Dest'' Ident''TR'') Param(AttrGroup(Attribute#ref(' +
       'Ident''Ref'')) Ident''Src'' Ident''TR''))))))'; ExpectDiags: 0),

    // ---- 12.1.1 single inheritance, standing alone ----
    (Section: '12.1.1'; Name: 'single inheritance';
     Source: 'type TSub = class(TBase) end;';
     Expected: 'TypeSec(TypeDecl(Ident''TSub'' ClassType(' +
       'Ident''TBase'')))'; ExpectDiags: 0),

    // ---- 13.1.1 the most basic property declaration (9.2.1's batch-1
    // case shows one too, but bundled with methods/class members) ----
    (Section: '13.1.1'; Name: 'basic property declaration';
     Source: 'type TC = class'#13#10 +
       '    property X: Integer read FX write FX;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(PropertyDecl(' +
       'Ident''X'' Ident''Integer'' PropSpec''read''(Ident''FX'') ' +
       'PropSpec''write''(Ident''FX'')))))'; ExpectDiags: 0),

    // ---- 13.2.1 a property under `published` visibility specifically --
    // 11.2.1's visibility case has a published FIELD, not a property ----
    (Section: '13.2.1'; Name: 'published property';
     Source: 'type TC = class'#13#10'  published'#13#10 +
       '    property X: Integer read FX write FX;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(' +
       'Visibility''published'' PropertyDecl(Ident''X'' Ident''Integer'' ' +
       'PropSpec''read''(Ident''FX'') PropSpec''write''(Ident''FX'')))))';
     ExpectDiags: 0),

    // ---- 14.2.1 a class implementing more than one interface ----
    (Section: '14.2.1'; Name: 'class implementing two interfaces';
     Source: 'type TC = class(TObject, IFoo, IBar) end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(Ident''TObject'' ' +
       'Ident''IFoo'' Ident''IBar'')))'; ExpectDiags: 0),

    // ---- 15.1.1 / 15.1.2 / 15.1.3 class-level members on a CLASS
    // specifically (9.2.1's batch-1 case shows the same shapes on a
    // RECORD, whose AST is identical -- these close the CLASS-tagged gap) ----
    (Section: '15.1.1'; Name: 'class method';
     Source: 'type TC = class'#13#10'    class procedure P;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(' +
       'Routine''procedure''#class(Ident''P''))))'; ExpectDiags: 0),
    (Section: '15.1.2'; Name: 'class var';
     Source: 'type TC = class'#13#10 +
       '    class var Count: Integer;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(VarSec#class(' +
       'VarDecl(Ident''Count'' Ident''Integer'')))))'; ExpectDiags: 0),
    (Section: '15.1.3'; Name: 'class property';
     Source: 'type TC = class'#13#10 +
       '    class property X: Integer read FX write FX;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(' +
       'PropertyDecl#class(Ident''X'' Ident''Integer'' PropSpec''read''(' +
       'Ident''FX'') PropSpec''write''(Ident''FX'')))))'; ExpectDiags: 0),

    // ---- 15.3.2 a record helper for a NON-INTRINSIC record type (15.3.1's
    // batch-1 case already covers a class helper and a helper for the
    // intrinsic Integer) ----
    (Section: '15.3.2'; Name: 'record helper for a non-intrinsic type';
     Source: 'type'#13#10'  TPoint = record X, Y: Integer; end;'#13#10 +
       '  TPointHelper = record helper for TPoint'#13#10 +
       '    procedure Offset(DX, DY: Integer);'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TPoint'' RecordType(VarDecl(' +
       'Ident''X'' Ident''Y'' Ident''Integer''))) TypeDecl(' +
       'Ident''TPointHelper'' HelperType#record(Ident''TPoint'' ' +
       'Routine''procedure''(Ident''Offset'' Params(Param(Ident''DX'' ' +
       'Ident''DY'' Ident''Integer''))))))'; ExpectDiags: 0),

    // ---- 16.1.2 overloading a generic NAME by arity: two declarations,
    // same name, different parameter-list length ----
    (Section: '16.1.2'; Name: 'generic overloaded by arity';
     Source: 'type'#13#10'  TBox<T> = class end;'#13#10 +
       '  TBox<T1, T2> = class end;';
     Expected: 'TypeSec(TypeDecl(Ident''TBox'' GenericParams(' +
       'GenericParam(Ident''T'')) ClassType) TypeDecl(Ident''TBox'' ' +
       'GenericParams(GenericParam(Ident''T1'' Ident''T2'')) ClassType))';
     ExpectDiags: 0),

    // ---- 16.2.1 a generic (parameterized) METHOD, whose own <T> is
    // distinct from any enclosing type's ----
    (Section: '16.2.1'; Name: 'generic method';
     Source: 'type TC = class'#13#10 +
       '    procedure P<T>(A: T);'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(' +
       'Routine''procedure''(Ident''P'' GenericParams(GenericParam(' +
       'Ident''T'')) Params(Param(Ident''A'' Ident''T''))))))';
     ExpectDiags: 0),

    // ---- 16.3.1 generic instantiation syntax at the TYPE level (16.3's
    // batch-1 case already covers one inside an EXPRESSION) ----
    (Section: '16.3.1'; Name: 'generic instantiation as a type alias';
     Source: 'type TIntList = TList<Integer>;';
     Expected: 'TypeSec(TypeDecl(Ident''TIntList'' TypeArgs(' +
       'Ident''TList'' Ident''Integer'')))'; ExpectDiags: 0),

    // ---- 17.1.1 the anonymous-method reference TYPE on its own (6.6.1's
    // batch-1 case shows the identical shape, tagged for procedural types
    // generally rather than this chapter's own topic) ----
    (Section: '17.1.1'; Name: 'anonymous-method reference type';
     Source: 'type TProc = reference to procedure;';
     Expected: 'TypeSec(TypeDecl(Ident''TProc'' ProcType#reference))';
     ExpectDiags: 0),

    // ---- 20.6.1 [weak]/[unsafe] tagged for ch.20's OWN section too
    // (14.3.2's batch-1 case already pins the identical attribute-group
    // shape from the interfaces chapter's point of view) ----
    (Section: '20.6.1'; Name: 'weak attribute, ch.20''s own tag';
     Source: 'type'#13#10'  TC = class'#13#10 +
       '    [weak] FFoo: IFoo;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(AttrGroup(' +
       'Attribute#weak(Ident''weak'')) VarDecl(Ident''FFoo'' Ident''IFoo''))))';
     ExpectDiags: 0),

    // ---- B.10 a constant expression: the parser accepts the SHAPE, folds
    // nothing -- evaluation is a sema/typing concern ----
    (Section: 'B.10'; Name: 'constant expression in a const decl';
     Source: 'const K = 1 + 2 * 3;';
     Expected: 'ConstSec''const''(ConstDecl(Ident''K'' BinaryOp''+''(' +
       'IntLit''1'' BinaryOp''*''(IntLit''2'' IntLit''3''))))';
     ExpectDiags: 0),

    // ==== test-coverage plan step 3 batch 6 ====================

    // ---- 6.1.1 a procedure and a function side by side -- the one
    // difference between them (a result type) had never been shown as
    // the DELIBERATE point of a case before, only as an incidental detail
    // of some richer one ----
    (Section: '6.1.1'; Name: 'a procedure and a function side by side';
     Source: 'procedure P;'#13#10'function F: Integer;';
     Expected: 'Routine''procedure''(Ident''P'') ' +
       'Routine''function''(Ident''F'' Ident''Integer'')'; ExpectDiags: 0),

    // ---- 11.1.2 / 11.1.3 fields and methods, each standing alone with
    // nothing else in the class (every prior class case bundles them with
    // something richer -- visibility, directives, generics) ----
    (Section: '11.1.2'; Name: 'a class with only fields';
     Source: 'type TC = class'#13#10'    FX, FY: Integer;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(VarDecl(' +
       'Ident''FX'' Ident''FY'' Ident''Integer''))))'; ExpectDiags: 0),
    (Section: '11.1.3'; Name: 'a class with only a method';
     Source: 'type TC = class'#13#10'    procedure P;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(' +
       'Routine''procedure''(Ident''P''))))'; ExpectDiags: 0),

    // ==== test-coverage plan step 3 batch 7 ====================

    // ---- B.11 a type reference combining THREE forms at once -- dotted
    // (qualified), generic instantiation, and pointer-to -- each shown
    // separately in some other case (1.2.2, 16.3, 10.1.1), never together
    // the way a real reference to a unit's generic type usually reads ----
    (Section: 'B.11'; Name: 'a dotted, generic, pointer type reference';
     Source: 'type TP = ^Generics.Collections.TList<Integer>;';
     Expected: 'TypeSec(TypeDecl(Ident''TP'' PointerType(TypeArgs(' +
       'Member(Member(Ident''Generics'' Ident''Collections'') ' +
       'Ident''TList'') Ident''Integer''))))'; ExpectDiags: 0)
  );

{ Builds every case that is not a plain dump comparison: the platform matrix
  (one per TPasPlatform, driven off GSM), the include-search-path fixture, the
  B.6.3 multiline-indent probes, the out-parameter Aux check, and the package
  head-token check. GPP/GSM are the suite's shared preprocessor/source
  manager, reused where a case does not need its own (most of these build
  their own, since they need different defines/platforms/search paths). }
function BuildCustomCases(GPP: TPasPreprocessor; GSM: TPasSourceManager):
  TPasCustomCases;

implementation

function BuildCustomCases(GPP: TPasPreprocessor; GSM: TPasSourceManager):
  TPasCustomCases;

  { One entry per TPasPlatform: the define set + SizeOf(Pointer) must drive
    branch selection correctly. }
  function PlatformCase(APlatform: TPasPlatform): TPasCustomCase;
  begin
    Result.Section := '';
    Result.Name := 'platform ' + PlatformInfo(APlatform).Name;
    Result.Run :=
      function: TPasCheckResult
      const
        SNIPPET =
          '{$IFDEF MSWINDOWS}W := 1;{$ENDIF}' +
          '{$IFDEF POSIX}P := 1;{$ENDIF}' +
          '{$IF SizeOf(Pointer) = 8}B := 64{$ELSE}B := 32{$ENDIF};';
      var
        LInfo: TPasPlatformInfo;
        LDefines: TPasDefines;
        LPP: TPasPreprocessor;
        LPre: TPasPreprocessed;
        LDiags: TArray<TPasParseDiag>;
        LTree: TPasTree;
        LExpected: string;
      begin
        LInfo := PlatformInfo(APlatform);
        LDefines := CreatePlatformDefines(APlatform);
        LPP := TPasPreprocessor.Create(GSM, LDefines, 37.0,
          LInfo.PointerBytes, LInfo.ExtendedBytes);
        try
          LPre := LPP.ProcessText('test.pas', SNIPPET);
          LTree := TPasParser.ParseStatements(LPre, LDiags);
          LExpected := 'Block(';
          if LInfo.IsWindows then
            LExpected := LExpected + 'Assign(Ident''W'' IntLit''1'') ';
          if LInfo.IsPosix then
            LExpected := LExpected + 'Assign(Ident''P'' IntLit''1'') ';
          if LInfo.PointerBytes = 8 then
            LExpected := LExpected + 'Assign(Ident''B'' IntLit''64'')'
          else
            LExpected := LExpected + 'Assign(Ident''B'' IntLit''32'')';
          LExpected := LExpected + ')';
          Result := CheckDump(SNIPPET, LExpected, LTree.Dump(0), LDiags, 0);
        finally
          LPP.Free;
          LDefines.Free;
        end;
      end;
  end;

  { An include that lives in ANOTHER directory and DEFINES a symbol,
    guarding a declaration. A utility library unit's shape exactly: it
    includes common.inc, which sits in source/include rather than beside the
    unit, and which (through jedi.inc) defines CPU32 -- the symbol guarding
    SizeInt = Integer.

    Both halves of the context matter, and the case pins both: with NO
    search path the include cannot resolve and the guarded region is
    reported SKIPPED -- which is what made the demo's highlighter grey out a
    line its own navigation had just jumped to. With the search path
    supplied, the region is live.

    The file NAME matters too: an include is resolved relative to the
    including file, so preprocessing real content under a placeholder name
    loses even an include sitting right beside it. }
  function IncludeContextCase: TPasCustomCase;
  begin
    Result.Section := '1.3.3';
    Result.Name := 'include context drives inactive regions';
    Result.Run :=
      function: TPasCheckResult
      var
        LDir, LSub, LUnitPath: string;
        LSkippedWith, LSkippedWithout: Boolean;

        function GuardSkipped(const APaths: TArray<string>;
          const AName: string): Boolean;
        var
          LSM: TPasSourceManager;
          LDefines: TPasDefines;
          LPP: TPasPreprocessor;
          LPre: TPasPreprocessed;
          LText: string;
          LAt: Integer;
        begin
          LSM := TPasSourceManager.Create(APaths);
          LDefines := CreatePlatformDefines(pfWin32);
          LPP := TPasPreprocessor.Create(LSM, LDefines);
          try
            LText := TFile.ReadAllText(LUnitPath);
            LPre := LPP.ProcessText(AName, LText);
            LAt := Pos('SizeInt = Integer', LText) - 1;   // 0-based offset
            Result := LPre.IsSkipped(0, LAt);
          finally
            LPP.Free;
            LDefines.Free;
            LSM.Free;
          end;
        end;

      begin
        LDir := TPath.Combine(TPath.GetTempPath, 'pastree_incctx');
        LSub := TPath.Combine(LDir, 'include');
        if TDirectory.Exists(LDir) then
          TDirectory.Delete(LDir, True);
        TDirectory.CreateDirectory(LSub);
        try
          TFile.WriteAllText(TPath.Combine(LSub, 'cfg.inc'),
            '{$DEFINE MYCPU32}'#10);
          LUnitPath := TPath.Combine(LDir, 'U.pas');
          TFile.WriteAllText(LUnitPath,
            'unit U;'#10 +
            '{$I cfg.inc}'#10 +      // NOT next to U.pas: needs search path
            'interface'#10 +
            'type'#10 +
            '{$IFDEF MYCPU32}'#10 +
            '  SizeInt = Integer;'#10 +
            '{$ENDIF}'#10 +
            'implementation'#10 +
            'end.'#10);

          LSkippedWithout := GuardSkipped([], 'buffer.pas');
          LSkippedWith := GuardSkipped([LSub], LUnitPath);

          Result.Passed := LSkippedWithout and not LSkippedWith;
          if Result.Passed then
            Result.Message := ''
          else
            Result.Message := '  expected: skipped without context, ' +
              'live with it' + sLineBreak +
              Format('  actual:   without=%s with=%s',
                [BoolToStr(LSkippedWithout, True),
                 BoolToStr(LSkippedWith, True)]) + sLineBreak;
        finally
          if TDirectory.Exists(LDir) then
            TDirectory.Delete(LDir, True);
        end;
      end;
  end;

  { Lexer-level check: the LINES on which ASource produces ACode, as a
    comma-separated list, so a case reads the way dcc's own output does. }
  function LexDiagLinesCase(const AName, ASource: string;
    ACode: TPasDiagCode; const AExpected: string): TPasCustomCase;
  begin
    Result.Section := 'B.6.3';
    Result.Name := AName;
    Result.Run :=
      function: TPasCheckResult
      var
        LStream: TPasTokenStream;
        LIdx, LLine, LCol: Integer;
        LActual: string;
      begin
        LStream := TPasLexer.Tokenize(ASource);
        LActual := '';
        for LIdx := 0 to High(LStream.Diagnostics) do
          if LStream.Diagnostics[LIdx].Code = ACode then
          begin
            LStream.OffsetToLineCol(LStream.Diagnostics[LIdx].Start, LLine,
              LCol);
            if LActual <> '' then
              LActual := LActual + ',';
            LActual := LActual + IntToStr(LLine);
          end;
        Result.Passed := LActual = AExpected;
        if Result.Passed then
          Result.Message := ''
        else
          Result.Message := '  expected lines: "' + AExpected + '"' +
            sLineBreak + '  actual lines:   "' + LActual + '"' + sLineBreak;
      end;
  end;

  { The eight B.6.3 multiline-string-indentation probes, every shape dcc32
    37.0 was checked against. The rule compares the closing run's indent
    CHARACTER BY CHARACTER against each content line: a mismatch is the
    error, running out of line is not. Line numbers are 1-based and the
    sources start with a `const` line, so content starts at line 3. }
  procedure AddMultilineIndentCases(var AList: TPasCustomCases);
  const
    // One apostrophe, so a quote RUN can be composed instead of spelled --
    // an eight-apostrophe literal is unreadable and was wrong the first
    // time.
    Q = '''';
    R3 = Q + Q + Q;      // '''
    R5 = R3 + Q + Q;     // '''''
    NL = #13#10;
  var
    LUnder, LOver, LTab, LBlank, LTabBlank, LTwo, LFlush, LFive: string;
  begin
    // Two spaces where the closer has four: the mismatch is at the 'u'.
    LUnder := 'const A =' + NL + '    ' + R3 + NL + '  under' + NL +
      '    ' + R3 + ';';
    // Deeper than the closer, then deeper still: legal.
    LOver := 'const A =' + NL + '    ' + R3 + NL + '    ok' + NL +
      '      more' + NL + '    ' + R3 + ';';
    // A tab where the closer has spaces -- the same WIDTH is not the rule.
    LTab := 'const A =' + NL + '    ' + R3 + NL + #9'tabbed' + NL +
      '    ' + R3 + ';';
    // Whitespace-only lines: empty, and shorter than the closer. Both legal.
    LBlank := 'const A =' + NL + '    ' + R3 + NL + NL + '  ' + NL +
      '    ok' + NL + '    ' + R3 + ';';
    // A tab-only line, though, mismatches on its first character.
    LTabBlank := 'const A =' + NL + '    ' + R3 + NL + #9 + NL +
      '    ok' + NL + '    ' + R3 + ';';
    // Two offenders: one report each, not one per literal.
    LTwo := 'const A =' + NL + '    ' + R3 + NL + '  one' + NL +
      '  two' + NL + '    ' + R3 + ';';
    // A closer at column 1 imposes nothing.
    LFlush := 'const A =' + NL + R3 + NL + 'anything' + NL + R3 + ';';
    // The same rule inside a longer odd run.
    LFive := 'const A =' + NL + '    ' + R5 + NL + '  bad' + NL +
      '    ' + R5 + ';';

    AList := AList + [
      LexDiagLinesCase('under-indented content line', LUnder,
        dcInconsistentIndentChars, '3'),
      LexDiagLinesCase('deeper than the closer is fine', LOver,
        dcInconsistentIndentChars, ''),
      LexDiagLinesCase('a tab where the closer has spaces', LTab,
        dcInconsistentIndentChars, '3'),
      LexDiagLinesCase('empty and short whitespace-only lines are fine',
        LBlank, dcInconsistentIndentChars, ''),
      LexDiagLinesCase('...but a tab-only line still mismatches', LTabBlank,
        dcInconsistentIndentChars, '3'),
      LexDiagLinesCase('one report per offending line', LTwo,
        dcInconsistentIndentChars, '3,4'),
      LexDiagLinesCase('a closer at column 1 imposes nothing', LFlush,
        dcInconsistentIndentChars, ''),
      LexDiagLinesCase('the rule holds for a five-quote run', LFive,
        dcInconsistentIndentChars, '3')];
  end;

  { A parameter's `out` is recorded on its nkParam as a visible-token index
    (nkParam.Aux), because `out` is a DIRECTIVE word: legal as an identifier
    elsewhere, so nothing but the parser can prove that this one is the
    modifier. The demo's highlighter reads exactly this to colour it, which
    is why the check asserts the token TEXT and not merely that Aux moved. }
  function OutParamAuxCase: TPasCustomCase;
  begin
    Result.Section := '6.2';
    Result.Name := 'out-parameter Aux';
    Result.Run :=
      function: TPasCheckResult
      const
        SRC =
          'unit u;'#13#10'interface'#13#10 +
          'procedure P1(out target);'#13#10 +
          'procedure P2(var a; const b: Integer; out c: string);'#13#10 +
          'procedure P3(plain: Integer);'#13#10 +
          // `out` as an ordinary identifier: it must NOT be recorded here.
          'procedure P4(out: Integer);'#13#10 +
          'implementation'#13#10'end.'#13#10;
      var
        LPre: TPasPreprocessed;
        LDiags: TArray<TPasParseDiag>;
        LTree: TPasTree;
        LIdx, LMarked, LWrongText: Integer;
      begin
        LPre := GPP.ProcessText('outparams.pas', SRC);
        LTree := TPasParser.ParseFile(LPre, LDiags);
        LMarked := 0;
        LWrongText := 0;
        for LIdx := 0 to High(LTree.Nodes) do
          if (LTree.Nodes[LIdx].Kind = nkParam) and
             (LTree.Nodes[LIdx].Aux >= 0) then
          begin
            Inc(LMarked);
            if not SameText(LPre.VisibleText(LTree.Nodes[LIdx].Aux), 'out')
            then
              Inc(LWrongText);
          end;
        // Two `out` parameters across P1 and P2; P3 has none and P4's `out`
        // is the parameter's NAME.
        Result.Passed := (LMarked = 2) and (LWrongText = 0) and
          (Length(LDiags) = 0);
        if Result.Passed then
          Result.Message := ''
        else
          Result.Message := Format(
            '  marked: %d (expected 2), wrong text: %d, parse diags: %d',
            [LMarked, LWrongText, Length(LDiags)]) + sLineBreak;
      end;
  end;

  { A package's three head words are DIRECTIVES (B.4.2), not reserved ones,
    so the lexer hands them over as identifiers and only the tree says they
    are keywords here. What a highlighter needs is their token INDEX: the
    nkPackage node's own first token for `package`, and each clause's first
    token for `requires`/`contains`. Asserted as the token TEXT at those
    indices, which is what makes a wrong index readable instead of merely
    unequal -- and `package` used to be recorded as token 0, right only
    while nothing precedes the word. }
  function PackageHeadTokensCase: TPasCustomCase;
  begin
    Result.Section := '1.1.3';
    Result.Name := 'package head tokens';
    Result.Run :=
      function: TPasCheckResult
      const
        SRC =
          '{ a comment ahead of the head word }'#13#10 +
          'package MyPack;'#13#10 +
          'requires rtl, vcl;'#13#10 +
          'contains UnitA in ''UnitA.pas'', UnitB;'#13#10 +
          'end.'#13#10;
      var
        LPre: TPasPreprocessed;
        LDiags: TArray<TPasParseDiag>;
        LTree: TPasTree;
        LIdx: Integer;
        LPkg, LReq, LCon: Boolean;
      begin
        LPre := GPP.ProcessText('mypack.dpk', SRC);
        LTree := TPasParser.ParseFile(LPre, LDiags);
        LPkg := False;
        LReq := False;
        LCon := False;
        for LIdx := 0 to High(LTree.Nodes) do
          case LTree.Nodes[LIdx].Kind of
            nkPackage:
              LPkg := SameText(LPre.VisibleText(LTree.Nodes[LIdx].FirstToken),
                'package');
            nkUsesClause:
              if SameText(LPre.VisibleText(LTree.Nodes[LIdx].FirstToken),
                   'requires') then
                LReq := LTree.Nodes[LIdx].Aux = 1  // Aux marks requires
              else if SameText(LPre.VisibleText(LTree.Nodes[LIdx].FirstToken),
                   'contains') then
                LCon := LTree.Nodes[LIdx].Aux <> 1;
          end;
        Result.Passed := LPkg and LReq and LCon and (Length(LDiags) = 0);
        if Result.Passed then
          Result.Message := ''
        else
          Result.Message := Format(
            '  package: %s, requires: %s, contains: %s, parse diags: %d',
            [BoolToStr(LPkg, True), BoolToStr(LReq, True),
             BoolToStr(LCon, True), Length(LDiags)]) + sLineBreak;
      end;
  end;

  { 1.1.1: the PROGRAM file's own top-level shape -- a `program` head, its
    uses clause, and the body block -- never dumped as a whole before
    (every other case wraps a fragment inside a unit's interface section). }
  function ProgramFileCase: TPasCustomCase;
  begin
    Result.Section := '1.1.1';
    Result.Name := 'program file shape';
    Result.Run :=
      function: TPasCheckResult
      const
        SRC =
          'program Sample;'#13#10 +
          'uses SysUtils;'#13#10 +
          'begin'#13#10'  X := 1;'#13#10'end.'#13#10;
      var
        LPre: TPasPreprocessed;
        LDiags: TArray<TPasParseDiag>;
        LTree: TPasTree;
      begin
        LPre := GPP.ProcessText('sample.dpr', SRC);
        LTree := TPasParser.ParseFile(LPre, LDiags);
        Result := CheckDump(SRC, 'Program(Ident''Sample'' UsesClause(' +
          'UsesItem(Ident''SysUtils'')) Block(Assign(Ident''X'' ' +
          'IntLit''1'')))', LTree.Dump(0), LDiags, 0);
      end;
  end;

  { 1.1.2: the UNIT file's own top-level shape -- name, interface and
    implementation sections both present as children of the root. }
  function UnitFileCase: TPasCustomCase;
  begin
    Result.Section := '1.1.2';
    Result.Name := 'unit file shape';
    Result.Run :=
      function: TPasCheckResult
      const
        SRC = 'unit U;'#13#10'interface'#13#10'implementation'#13#10'end.'#13#10;
      var
        LPre: TPasPreprocessed;
        LDiags: TArray<TPasParseDiag>;
        LTree: TPasTree;
      begin
        LPre := GPP.ProcessText('u.pas', SRC);
        LTree := TPasParser.ParseFile(LPre, LDiags);
        Result := CheckDump(SRC, 'Unit(Ident''U'' InterfaceSec ' +
          'ImplementationSec)', LTree.Dump(0), LDiags, 0);
      end;
  end;

  { 6.9: a routine nested inside another routine's body -- only reachable
    from an IMPLEMENTATION section's local declarations, so every other
    case (CheckDecl, wrapping content in the INTERFACE section) structurally
    cannot reach this shape at all. Dumps just the OUTER routine's own
    subtree, found by name, so the expected string stays about the nesting
    and says nothing about the surrounding unit. }
  function NestedRoutineCase: TPasCustomCase;
  begin
    Result.Section := '6.9';
    Result.Name := 'nested routine';
    Result.Run :=
      function: TPasCheckResult
      const
        SRC =
          'unit U;'#13#10'interface'#13#10'implementation'#13#10 +
          'procedure Outer;'#13#10 +
          '  procedure Inner;'#13#10 +
          '  begin'#13#10'  end;'#13#10 +
          'begin'#13#10'  Inner;'#13#10'end;'#13#10 +
          'end.'#13#10;
      var
        LPre: TPasPreprocessed;
        LDiags: TArray<TPasParseDiag>;
        LTree: TPasTree;
        LIdx, LOuter: Integer;
      begin
        LPre := GPP.ProcessText('u.pas', SRC);
        LTree := TPasParser.ParseFile(LPre, LDiags);
        // A routine's own FirstToken is the `procedure`/`function` keyword,
        // not its name -- the name is the FIRST CHILD (an nkIdent).
        LOuter := NIL_NODE;
        for LIdx := 0 to High(LTree.Nodes) do
          if (LTree.Nodes[LIdx].Kind = nkRoutine) and
             (LTree.Nodes[LIdx].FirstChild <> NIL_NODE) and
             SameText(LTree.NodeText(LTree.Nodes[LIdx].FirstChild),
               'Outer') then
          begin
            LOuter := LIdx;
            Break;
          end;
        if LOuter = NIL_NODE then
        begin
          Result.Passed := False;
          Result.Message := '  no routine named ''Outer'' found' + sLineBreak;
          Exit;
        end;
        Result := CheckDump(SRC, 'Routine''procedure''(Ident''Outer'' ' +
          'RoutineBody(Routine''procedure''(Ident''Inner'' RoutineBody(' +
          'Block)) Block(ExprStmt(Ident''Inner''))))', LTree.Dump(LOuter),
          LDiags, 0);
      end;
  end;

  { B.12: a block is its local declaration sections (label/const/type/var,
    in whatever order and however many) followed by the statement part --
    each section kind has appeared ALONE in some other case; this is the
    only one with every kind present together, the shape B.12 itself
    describes. Only reachable inside a routine BODY, so -- like 6.9 --
    CheckDecl (interface-section only) cannot reach it; dumps the found
    routine's own subtree, same technique NestedRoutineCase uses. }
  function FullBlockCase: TPasCustomCase;
  begin
    Result.Section := 'B.12';
    Result.Name := 'every local declaration section kind, together';
    Result.Run :=
      function: TPasCheckResult
      const
        SRC =
          'unit U;'#13#10'interface'#13#10'implementation'#13#10 +
          'procedure P;'#13#10 +
          'label'#13#10'  1;'#13#10 +
          'const'#13#10'  K = 1;'#13#10 +
          'type'#13#10'  TLocal = Integer;'#13#10 +
          'var'#13#10'  X: TLocal;'#13#10 +
          'begin'#13#10'  1: X := K;'#13#10'end;'#13#10 +
          'end.'#13#10;
      var
        LPre: TPasPreprocessed;
        LDiags: TArray<TPasParseDiag>;
        LTree: TPasTree;
        LIdx, LRoutine: Integer;
      begin
        LPre := GPP.ProcessText('u.pas', SRC);
        LTree := TPasParser.ParseFile(LPre, LDiags);
        LRoutine := NIL_NODE;
        for LIdx := 0 to High(LTree.Nodes) do
          if (LTree.Nodes[LIdx].Kind = nkRoutine) and
             (LTree.Nodes[LIdx].FirstChild <> NIL_NODE) and
             SameText(LTree.NodeText(LTree.Nodes[LIdx].FirstChild), 'P') then
          begin
            LRoutine := LIdx;
            Break;
          end;
        if LRoutine = NIL_NODE then
        begin
          Result.Passed := False;
          Result.Message := '  no routine named ''P'' found' + sLineBreak;
          Exit;
        end;
        Result := CheckDump(SRC, 'Routine''procedure''(Ident''P'' ' +
          'RoutineBody(LabelSec ConstSec''const''(ConstDecl(Ident''K'' ' +
          'IntLit''1'')) TypeSec(TypeDecl(Ident''TLocal'' ' +
          'Ident''Integer'')) VarSec''var''(VarDecl(Ident''X'' ' +
          'Ident''TLocal'')) Block(LabeledStmt(Assign(Ident''X'' ' +
          'Ident''K'')))))', LTree.Dump(LRoutine), LDiags, 0);
      end;
  end;

var
  LPlatform: TPasPlatform;
begin
  Result := [];
  Result := Result + [ProgramFileCase, UnitFileCase, NestedRoutineCase,
    FullBlockCase];
  for LPlatform := Low(TPasPlatform) to High(TPasPlatform) do
    Result := Result + [PlatformCase(LPlatform)];
  Result := Result + [IncludeContextCase];
  AddMultilineIndentCases(Result);
  Result := Result + [OutParamAuxCase, PackageHeadTokensCase];
end;


end.
