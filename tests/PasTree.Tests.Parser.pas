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
  STMT_CASES: array[0..50] of TPasCaseRow = (
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
       'Assign(Ident''stored'' IntLit''14''))'; ExpectDiags: 0)
  );

  DECL_CASES: array[0..32] of TPasCaseRow = (
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
       'Attribute(Ident''weak'')) VarDecl(Ident''FFoo'' Ident''IFoo''))))';
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
     ExpectDiags: 0)
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
    Result.Section := '';
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

var
  LPlatform: TPasPlatform;
begin
  Result := [];
  for LPlatform := Low(TPasPlatform) to High(TPasPlatform) do
    Result := Result + [PlatformCase(LPlatform)];
  Result := Result + [IncludeContextCase];
  AddMultilineIndentCases(Result);
  Result := Result + [OutParamAuxCase, PackageHeadTokensCase];
end;


end.
