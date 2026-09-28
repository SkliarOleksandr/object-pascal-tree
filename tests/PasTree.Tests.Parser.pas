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
  STMT_CASES: array[0..127] of TPasCaseRow = (
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
     Expected: 'Block(ExprStmt(Call(Member(Ident''Charts'' Ident''Add'') ' +
       'Member(Ident''A'' Ident''B'') Error)))'; ExpectDiags: 1),

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
    // 4.9: a TYPE NAME on the right of `is` ends that operand, and the test
    // goes on as the LEFT operand of the multiplicative and additive
    // operators - the one exception dcc makes to the table (dcc64 37.0,
    // probed 2026-09-26: every shape here compiled, or failed, as its tree
    // says; `O is TFoo and C = D` printed the value only this grouping
    // gives). Which names are types is not known to the parser, so a
    // name-shaped VALUE is taken for one: `O is R and C`, R a record whose
    // `and` yields a class reference, is `O is (R and C)` for dcc - the limit
    // docs/coverage.md lists.
    (Section: '4.9'; Name: 'is: a type name ends the right operand';
     Source: 'B := O is TFoo and C;';
     Expected: 'Block(Assign(Ident''B'' BinaryOp''and''(BinaryOp''is''(' +
       'Ident''O'' Ident''TFoo'') Ident''C'')))'; ExpectDiags: 0),
    (Section: '4.9'; Name: 'is: the test is a left operand, and binds before or';
     Source: 'B := O is TFoo or C and D;';
     Expected: 'Block(Assign(Ident''B'' BinaryOp''or''(BinaryOp''is''(' +
       'Ident''O'' Ident''TFoo'') BinaryOp''and''(Ident''C'' Ident''D''))))';
     ExpectDiags: 0),
    (Section: '4.9'; Name: 'is: the relational loop goes on after it';
     Source: 'B := O is TFoo and C = D;';
     Expected: 'Block(Assign(Ident''B'' BinaryOp''=''(BinaryOp''and''(' +
       'BinaryOp''is''(Ident''O'' Ident''TFoo'') Ident''C'') Ident''D'')))';
     ExpectDiags: 0),
    (Section: '4.9'; Name: 'is: the shape the RTL and VCL ship';
     Source: 'if O is TFoo and (X > 0) then Exit;';
     Expected: 'Block(IfStmt(BinaryOp''and''(BinaryOp''is''(Ident''O'' ' +
       'Ident''TFoo'') Paren(BinaryOp''>''(Ident''X'' IntLit''0''))) ' +
       'ExprStmt(Ident''Exit'')))'; ExpectDiags: 0),
    (Section: '4.9'; Name: 'is: a qualified generic type name';
     Source: 'B := O is TBox<Integer>.TInner and C;';
     Expected: 'Block(Assign(Ident''B'' BinaryOp''and''(BinaryOp''is''(' +
       'Ident''O'' Member(TypeArgs(Ident''TBox'' Ident''Integer'') ' +
       'Ident''TInner'')) Ident''C'')))'; ExpectDiags: 0),
    (Section: '4.9'; Name: 'is: a second is after the continuation';
     Source: 'B := O is TFoo and P is TBar;';
     Expected: 'Block(Assign(Ident''B'' BinaryOp''is''(BinaryOp''and''(' +
       'BinaryOp''is''(Ident''O'' Ident''TFoo'') Ident''P'') ' +
       'Ident''TBar'')))'; ExpectDiags: 0),
    (Section: '4.9'; Name: 'is: an inline-if condition';
     Source: 'B := if O is TFoo and C then X else Y;';
     Expected: 'Block(Assign(Ident''B'' InlineIf(BinaryOp''and''(' +
       'BinaryOp''is''(Ident''O'' Ident''TFoo'') Ident''C'') Ident''X'' ' +
       'Ident''Y'')))'; ExpectDiags: 0),
    // A parenthesis, a cast and an index are values: `O is (TFoo)` alone
    // compiles, `O is (TFoo) and C` is E2015 - the table's grouping.
    (Section: '4.9'; Name: 'is: a parenthesized operand follows the table';
     Source: 'B := O is (TFoo) and C;';
     Expected: 'Block(Assign(Ident''B'' BinaryOp''is''(Ident''O'' ' +
       'BinaryOp''and''(Paren(Ident''TFoo'') Ident''C''))))'; ExpectDiags: 0),
    (Section: '4.9'; Name: 'is: a cast follows the table';
     Source: 'B := O is TFooClass(CV) and C;';
     Expected: 'Block(Assign(Ident''B'' BinaryOp''is''(Ident''O'' ' +
       'BinaryOp''and''(Call(Ident''TFooClass'' Ident''CV'') ' +
       'Ident''C''))))'; ExpectDiags: 0),
    (Section: '4.9'; Name: 'is: an index follows the table';
     Source: 'B := O is A[0] and C;';
     Expected: 'Block(Assign(Ident''B'' BinaryOp''is''(Ident''O'' ' +
       'BinaryOp''and''(Index(Ident''A'' IntLit''0'') Ident''C''))))';
     ExpectDiags: 0),
    // The LEFT operand is untouched (`C and O is TFoo` is E2015), and `in`
    // has no such rule (`X in S and C` is E2015).
    (Section: '4.9'; Name: 'is: the left operand follows the table';
     Source: 'B := C and O is TFoo;';
     Expected: 'Block(Assign(Ident''B'' BinaryOp''is''(BinaryOp''and''(' +
       'Ident''C'' Ident''O'') Ident''TFoo'')))'; ExpectDiags: 0),
    (Section: '4.9.1'; Name: 'is not: a type name ends the right operand';
     Source: 'B := O is not TFoo and C;';
     Expected: 'Block(Assign(Ident''B'' BinaryOp''and''(BinaryOp''is''!(' +
       'Ident''O'' Ident''TFoo'') Ident''C'')))'; ExpectDiags: 0),
    (Section: '4.6'; Name: 'in: the right operand is a simple expression';
     Source: 'B := X in S and C;';
     Expected: 'Block(Assign(Ident''B'' BinaryOp''in''(Ident''X'' ' +
       'BinaryOp''and''(Ident''S'' Ident''C''))))'; ExpectDiags: 0),
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
    (Section: '5.1.2'; Name: 'truncated arg list carries an Error child';
     Source: 'F(1, &4M4);';
     Expected: 'Block(ExprStmt(Call(Ident''F'' IntLit''1'' IntLit''&4'' Error)))';
     ExpectDiags: 1),
    // A comma promises an argument (dcc: one E2029 per shape). The empty
    // slot is an Error child so CheckCalls does not count it, and the list
    // continues instead of cascading into `")" expected` / `";" expected`.
    // A TRAILING comma is not a parse error (6.2.5: `H(1, 2,)` compiles when
    // the last parameter has a default) - a Missing child, verdict in sema.
    (Section: '6.2.5'; Name: 'trailing comma in an arg list is not a parse error';
     Source: 'F(1,);';
     Expected: 'Block(ExprStmt(Call(Ident''F'' IntLit''1'' Missing)))';
     ExpectDiags: 0),
    (Section: '5.1.2'; Name: 'leading comma in an arg list';
     Source: 'F(,1);';
     Expected: 'Block(ExprStmt(Call(Ident''F'' Error IntLit''1'')))';
     ExpectDiags: 1),
    (Section: '5.1.2'; Name: 'empty middle slot in an arg list';
     Source: 'F(1,,2);';
     Expected: 'Block(ExprStmt(Call(Ident''F'' IntLit''1'' Error IntLit''2'')))';
     ExpectDiags: 1),
    // Garbage AFTER an argument: one `")" expected`, then a resync to the
    // list's own `)` so the statement loop does not add `";" expected` on
    // the same token (dcc reports one error). Nested brackets are balanced.
    (Section: '5.1.2'; Name: 'garbage after an argument resyncs to the paren';
     Source: 'F(1 2);';
     Expected: 'Block(ExprStmt(Call(Ident''F'' IntLit''1'' Error)))';
     ExpectDiags: 1),
    (Section: '5.1.2'; Name: 'arg-list resync balances nested brackets';
     Source: 'F(1 G(2, [3]), 4);';
     Expected: 'Block(ExprStmt(Call(Ident''F'' IntLit''1'' Error)))';
     ExpectDiags: 1),
    (Section: 'B.6.2'; Name: 'caret bracket'; Source: 'C := ^[;';
     Expected: 'Block(Assign(Ident''C'' CaretChar''^[''))'; ExpectDiags: 0),
    (Section: 'B.6.2'; Name: 'caret del'; Source: 'C := ^?;';
     Expected: 'Block(Assign(Ident''C'' CaretChar''^?''))'; ExpectDiags: 0),
    (Section: 'B.6.2'; Name: 'caret quote does not open a string';
     Source: 'C := ^'';';
     Expected: 'Block(Assign(Ident''C'' CaretChar''^''''))'; ExpectDiags: 0),
    (Section: 'B.6.2'; Name: 'caret chain folds'; Source: 'S := ^M^J^_^]^^;';
     Expected: 'Block(Assign(Ident''S'' StrLit''^''))'; ExpectDiags: 0),
    (Section: 'B.6.2'; Name: 'caret folds with quoted and #n';
     Source: 'S := ''ab''^M#10''cd''^[;';
     Expected: 'Block(Assign(Ident''S'' StrLit''''ab''''))'; ExpectDiags: 0),
    (Section: 'B.6.2'; Name: 'caret takes one char'; Source: 'C := ^Mx;';
     Expected: 'Block(Assign(Ident''C'' CaretChar''^''))'; ExpectDiags: 1),
    (Section: 'B.6.2'; Name: 'double deref is not ^^'; Source: 'X := P^^;';
     Expected: 'Block(Assign(Ident''X'' Deref(Deref(Ident''P''))))';
     ExpectDiags: 0),
    (Section: 'B.6.2'; Name: 'deref then index is not ^['; Source: 'X := P^[0];';
     Expected: 'Block(Assign(Ident''X'' Index(Deref(Ident''P'') IntLit''0'')))';
     ExpectDiags: 0),
    (Section: 'B.6.2'; Name: 'caret range in set'; Source: 'if C in [^A..^Z, ^[] then;';
     Expected: 'Block(IfStmt(BinaryOp''in''(Ident''C'' SetCtor(Range(' +
       'CaretChar''^'' CaretChar''^'') CaretChar''^['')) EmptyStmt))';
     ExpectDiags: 0),
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
    // A member access wrapped after its dot inside a statement: `B =` on its
    // own line is the member and a comparison, not a declaration head (the
    // line heuristic is off inside statement blocks).
    (Section: '5.3.1'; Name: 'wrapped member after the dot is not a decl head';
     Source: 'if T(A).'#10'B = C then X := 1;';
     Expected: 'Block(IfStmt(BinaryOp''=''(Member(Call(Ident''T'' Ident''A'') ' +
       'Ident''B'') Ident''C'') Assign(Ident''X'' IntLit''1'')))';
     ExpectDiags: 0),
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
    // The `;` after the last selector is what gives the else to the case: 
    // without it the else is the if's (dcc64 37.0 probed, as parsed here).
    // The printer writes one after every selector for that reason.
    (Section: '5.3.2'; Name: 'case else after an if, with the ;';
     Source: 'case K of 1: if A then X := 1; else X := 2 end;';
     Expected: 'Block(CaseStmt(Ident''K'' CaseSel(CaseLabels(IntLit''1'') ' +
       'IfStmt(Ident''A'' Assign(Ident''X'' IntLit''1''))) ' +
       'Block(Assign(Ident''X'' IntLit''2''))))'; ExpectDiags: 0),
    (Section: '5.3.2'; Name: 'the if''s else inside a case, without the ;';
     Source: 'case K of 1: if A then X := 1 else X := 2 end;';
     Expected: 'Block(CaseStmt(Ident''K'' CaseSel(CaseLabels(IntLit''1'') ' +
       'IfStmt(Ident''A'' Assign(Ident''X'' IntLit''1'') ' +
       'Assign(Ident''X'' IntLit''2'')))))'; ExpectDiags: 0),

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
     Expected: 'Block(ForStmt(InlineVar(Ident''J''#name) IntLit''1'' ' +
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
     Expected: 'Block(InlineVar#init(Ident''Name''#name ' +
       'Member(Ident''Edit1'' ' +
       'Ident''Text'')))'; ExpectDiags: 0),
    (Section: '3.1.3'; Name: 'typed inline var';
     Source: 'var I: Integer := 0;';
     Expected: 'Block(InlineVar#init(Ident''I''#name Ident''Integer'' ' +
       'IntLit''0''))';
     ExpectDiags: 0),
    // Recovery: an initializer not yet typed keeps the NEXT declaration -
    // with the ';' present (one error) and without it (a second error for
    // the ';', still nothing lost).
    (Section: '3.1.3'; Name: 'recovery: empty initializer keeps the next decl';
     Source: 'var A := ;'#10'var B := 5;';
     Expected: 'Block(InlineVar#init(Ident''A''#name Error) ' +
       'InlineVar#init(Ident''B''#name ' +
       'IntLit''5''))'; ExpectDiags: 1),
    (Section: '3.1.3'; Name: 'recovery: unfinished initializer keeps the next decl';
     Source: 'var A :='#10'var B := 5;';
     Expected: 'Block(InlineVar#init(Ident''A''#name Error) ' +
       'InlineVar#init(Ident''B''#name ' +
       'IntLit''5''))'; ExpectDiags: 2),

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
    // The same for the except part's else after a handler's if.
    (Section: '18.1.2'; Name: 'except else after a handler''s if';
     Source: 'try P except on E: EFoo do if A then B; else C end;';
     Expected: 'Block(TryStmt(Block(ExprStmt(Ident''P'')) ExceptPart(' +
       'ExceptOn(Ident''E'' Ident''EFoo'' IfStmt(Ident''A'' ' +
       'ExprStmt(Ident''B''))) Block(ExprStmt(Ident''C'')))))';
     ExpectDiags: 0),
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

    // ---- 5.6.5 Halt: same intrinsic-call shape as Break/Continue/Exit
    // above, in BOTH arities -- bare, and with the optional Integer exit
    // code. dcc32 37.0 probe-verified both forms compile before these rows
    // were written. Already a seeded intrinsic (PasTree.Sema.Builtins), so
    // the parse shape is the whole of what there is to pin. ----
    (Section: '5.6.5'; Name: 'Halt, bare';
     Source: 'if Fatal then Halt;';
     Expected: 'Block(IfStmt(Ident''Fatal'' ExprStmt(Ident''Halt'')))';
     ExpectDiags: 0),
    (Section: '5.6.5'; Name: 'Halt with an exit code';
     Source: 'Halt(3);';
     Expected: 'Block(ExprStmt(Call(Ident''Halt'' IntLit''3'')))';
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
     Expected: 'Block(Assign(Ident''G'' ' +
       'AnonMethod(Params(Param(Ident''A''#name ' +
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
       'Ident''B'') Ident''C'')) Ident''D'') Ident''E'')))'; ExpectDiags: 0),

    // ---- Code audit 2026-08-31, section 2.9: dcc64-valid shapes the parser
    // rejected or silently mis-shaped ----
    // 3.1.3: an inline var may be given a STRUCTURAL type, not just a type
    // reference. Both of these were a hard "type expected".
    (Section: '3.1.3'; Name: 'inline var with an array type';
     Source: 'var A: array[0..1] of Byte;';
     Expected: 'Block(InlineVar(Ident''A''#name ' +
       'ArrayType(Subrange(IntLit''0'' ' +
       'IntLit''1'') Ident''Byte'')))'; ExpectDiags: 0),
    (Section: '3.1.3'; Name: 'inline var with a set type';
     Source: 'var S: set of Byte;';
     Expected: 'Block(InlineVar(Ident''S''#name SetType(Ident''Byte'')))';
     ExpectDiags: 0),
    // 16.3: `>=` written without a space lexes as ONE token, and the
    // expression-side generic scan refused it - so this parsed as
    // `(V.AsType < Integer) >= 5` with no diagnostic at all.
    (Section: '16.3'; Name: 'fused >= closes a generic argument list';
     Source: 'B := V.AsType<Integer>=5;';
     Expected: 'Block(Assign(Ident''B'' BinaryOp''>=''(TypeArgs(Member(' +
       'Ident''V'' Ident''AsType'') Ident''Integer'') IntLit''5'')))';
     ExpectDiags: 0),
    // B.5.2: dcc takes an EMPTY fraction - `100.` is a real literal when the
    // dot is followed by nothing that could start another token (a report
    // builder in the client writes `100. - ARightPadding`). `100.e2` stays
    // member access on an integer, as dcc reads it.
    (Section: 'B.5.2'; Name: 'real literal with an empty fraction';
     Source: 'X := 100. - 3;';
     Expected: 'Block(Assign(Ident''X'' BinaryOp''-''(RealLit''100.'' ' +
       'IntLit''3'')))';
     ExpectDiags: 0),
    // B.2: every control character #0..#31 is whitespace for dcc - a stray
    // #$12 after a semicolon (a PDF-viewer library unit) and an embedded #1
    // compile silently. Lexed as tkUnknown they surfaced as "declaration
    // expected, found """ at an invisible character.
    (Section: 'B.2'; Name: 'control characters are whitespace';
     Source: 'X := 1;'#$12' Y :='#1'2;';
     Expected: 'Block(Assign(Ident''X'' IntLit''1'') Assign(Ident''Y'' ' +
       'IntLit''2''))';
     ExpectDiags: 0),

    // ---- F19 (the parser-fidelity plan): an inline var's identifiers alone
    // do not fix its shape - nfName marks the names, Aux 1 (#init) says the
    // last child is the initializer (3.1.3) ----
    (Section: '3.1.3'; Name: 'F19: a name and a type';
     Source: 'var X: K;';
     Expected: 'Block(InlineVar(Ident''X''#name Ident''K''))';
     ExpectDiags: 0),
    (Section: '3.1.3'; Name: 'F19: a name and an initializer';
     Source: 'var X := K;';
     Expected: 'Block(InlineVar#init(Ident''X''#name Ident''K''))';
     ExpectDiags: 0),
    (Section: '3.1.3'; Name: 'F19: two names and a type';
     Source: 'var X, Y: K;';
     Expected: 'Block(InlineVar(Ident''X''#name Ident''Y''#name ' +
       'Ident''K''))'; ExpectDiags: 0),
    (Section: '3.1.3'; Name: 'F19: a name, a type and an initializer';
     Source: 'var X: Y := K;';
     Expected: 'Block(InlineVar#init(Ident''X''#name Ident''Y'' ' +
       'Ident''K''))'; ExpectDiags: 0),
    (Section: '3.1.3'; Name: 'F19: a typed inline const';
     Source: 'const C: T = V;';
     Expected: 'Block(InlineConst#init(Ident''C''#name Ident''T'' ' +
       'Ident''V''))'; ExpectDiags: 0),
    // Invalid (dcc: E2029) and taken without a diagnostic, as the author
    // types it: the names still say what they are - read by position, Y
    // would be the initializer of `var X := Y`.
    (Section: '3.1.3'; Name: 'F19 recovery: names with neither type nor value';
     Source: 'var X, Y;';
     Expected: 'Block(InlineVar(Ident''X''#name Ident''Y''#name))';
     ExpectDiags: 0),

    // ---- F2, F11 (the parser-fidelity plan): a directive is a node. An
    // anonymous method's before its body; an inline var's or const's
    // procedural type takes a run after its `;` - a convention starts it,
    // whatever follows, as dcc64 37.0 reads it (6.6.1, 17.2.1) ----
    (Section: '17.2.1'; Name: 'F11: a convention before the body';
     Source: 'F := function(A: Integer): Integer stdcall begin Result := A ' +
       'end;';
     Expected: 'Block(Assign(Ident''F'' AnonMethod(Params(Param(Ident''A''#name ' +
       'Ident''Integer'')) Ident''Integer'' Directive''stdcall'' ' +
       'RoutineBody(Block(Assign(Ident''Result'' Ident''A''))))))';
     ExpectDiags: 0),
    (Section: '17.2.1'; Name: 'F11: a procedure with a convention';
     Source: 'P := procedure cdecl begin end;';
     Expected: 'Block(Assign(Ident''P'' AnonMethod(Directive''cdecl'' ' +
       'RoutineBody(Block))))';
     ExpectDiags: 0),
    (Section: '6.6.1'; Name: 'F2: an inline var''s run, then its initializer';
     Source: 'var P: procedure; stdcall := SP;';
     Expected: 'Block(InlineVar#init(Ident''P''#name ' +
       'ProcType(Directive''stdcall''#semi) Ident''SP''))';
     ExpectDiags: 0),
    (Section: '6.6.1'; Name: 'F2: an inline var''s run at the list''s end';
     Source: 'var P: procedure; stdcall';
     Expected: 'Block(InlineVar(Ident''P''#name ' +
       'ProcType(Directive''stdcall''#semi)))';
     ExpectDiags: 0),
    // A routine named pascal is not called: dcc takes the word as P's.
    (Section: '6.6.1'; Name: 'F2: a convention after the ; is the type''s';
     Source: 'var P: procedure; pascal; X;';
     Expected: 'Block(InlineVar(Ident''P''#name ProcType(Directive''pascal''#semi)) ' +
       'ExprStmt(Ident''X''))';
     ExpectDiags: 0),
    // varargs starts no run: the statement calls a routine named varargs.
    (Section: '6.6.1'; Name: 'F2: varargs after the ; is a statement';
     Source: 'var P: procedure; varargs;';
     Expected: 'Block(InlineVar(Ident''P''#name ProcType) ' +
       'ExprStmt(Ident''varargs''))';
     ExpectDiags: 0),
    (Section: '6.6.1'; Name: 'F2: an inline const''s run, then its value';
     Source: 'const C: procedure; cdecl = CP;';
     Expected: 'Block(InlineConst#init(Ident''C''#name ' +
       'ProcType(Directive''cdecl''#semi) Ident''CP''))';
     ExpectDiags: 0)
  );

  DECL_CASES: array[0..211] of TPasCaseRow = (
    // ---- 3.1 variables ----
    // 3.1.4: the `absolute` expression is an ALIAS, and it lands in the same
    // child slot an initializer would -- only the mark separates them.
    (Section: '3.1.4'; Name: 'absolute';
     Source: 'var A: Integer absolute B;';
     Expected: 'VarSec''var''(VarDecl#absolute(Ident''A''#name ' +
       'Ident''Integer'' ' +
       'Ident''B''))'; ExpectDiags: 0),
    (Section: '3.1.4'; Name: 'initializer is not absolute';
     Source: 'var A: Integer = 1;';
     Expected: 'VarSec''var''(VarDecl(Ident''A''#name Ident''Integer'' ' +
       'IntLit''1''))'; ExpectDiags: 0),
    // 3.1.5: same section shape as `var`; the head word is the whole
    // difference, so the dump has to carry it.
    (Section: '3.1.5'; Name: 'threadvar'; Source: 'threadvar T: Integer;';
     Expected: 'VarSec''threadvar''(VarDecl(Ident''T''#name Ident''Integer''))';
     ExpectDiags: 0),

    // ---- 3.2 constants ----
    // 3.2.3: a resourcestring section parses as a const section.
    (Section: '3.2.3'; Name: 'resourcestring';
     Source: 'resourcestring SHi = ''hi'';';
     Expected: 'ConstSec''resourcestring''(ConstDecl(Ident''SHi'' ' +
       'StrLit''''hi''''))'; ExpectDiags: 0),

    // ---- recovery inside declaration sections (see TPasParser.AtDeclHead):
    // a declaration cut short loses ITSELF, never the declarations after it.
    // Each case is one keystroke state of typing a new declaration above an
    // existing one; the diagnostic count is the one error the author is
    // still fixing. ----
    (Section: '2.5.1'; Name: 'recovery: type name alone keeps the next decl';
     Source: 'type A'#10'B = Integer;';
     Expected: 'TypeSec(TypeDecl(Ident''A'') TypeDecl(Ident''B'' ' +
       'Ident''Integer''))'; ExpectDiags: 1),
    (Section: '2.5.1'; Name: 'recovery: type name and = keep the next decl';
     Source: 'type A ='#10'B = Integer;';
     Expected: 'TypeSec(TypeDecl(Ident''A'') TypeDecl(Ident''B'' ' +
       'Ident''Integer''))'; ExpectDiags: 1),
    (Section: '2.5.1'; Name: 'recovery: a generic type still reads its args';
     Source: 'type A = TList<Integer>;';
     Expected: 'TypeSec(TypeDecl(Ident''A'' TypeArgs(Ident''TList'' ' +
       'Ident''Integer'')))'; ExpectDiags: 0),
    // B.11: the keyword types qualify like any other System name -
    // `Nullable<System.string>` in a DI library's converter table, and
    // `System.file` too (probed dcc64 35.0). The dotted segment after `.`
    // took only an identifier, so the whole call became three E2029s.
    (Section: 'B.11'; Name: 'a keyword type qualified by its unit';
     Source: 'type A = TArray<System.string>; B = System.file;';
     Expected: 'TypeSec(TypeDecl(Ident''A'' TypeArgs(Ident''TArray'' ' +
       'Member(Ident''System'' Ident''string''))) TypeDecl(Ident''B'' ' +
       'Member(Ident''System'' Ident''file'')))'; ExpectDiags: 0),
    (Section: '2.5.1'; Name: 'recovery: a missing ; resyncs at the next head';
     Source: 'type A = Integer B = Byte; C = Word;';
     Expected: 'TypeSec(TypeDecl(Ident''A'' Ident''Integer'') ' +
       'TypeDecl(Ident''B'' Ident''Byte'') TypeDecl(Ident''C'' Ident''Word''))';
     ExpectDiags: 1),
    (Section: '2.5.1'; Name: 'recovery: garbage after a decl is skipped to the next head';
     Source: 'type A = Integer x y z; B = Byte;';
     Expected: 'TypeSec(TypeDecl(Ident''A'' Ident''Integer'') ' +
       'TypeDecl(Ident''B'' Ident''Byte''))'; ExpectDiags: 1),
    (Section: '13.1.1'; Name: 'recovery: a bare property does not eat the class end';
     Source: 'type C = class property end; D = Integer;';
     Expected: 'TypeSec(TypeDecl(Ident''C'' ClassType(PropertyDecl)) ' +
       'TypeDecl(Ident''D'' Ident''Integer''))'; ExpectDiags: 3),
    (Section: '6.6.1'; Name: 'recovery: a named routine header is not a proc type';
     Source: 'type S ='#10'procedure P;';
     Expected: 'TypeSec(TypeDecl(Ident''S'' Error)) ' +
       'Routine''procedure''(Ident''P''#name)';
     ExpectDiags: 2),
    (Section: '6.6.1'; Name: 'recovery: a real procedural type still parses';
     Source: 'type S = procedure stdcall;';
     Expected: 'TypeSec(TypeDecl(Ident''S'' ProcType(Directive''stdcall'')))';
     ExpectDiags: 0),
    // F29: one type either way, but not one .dcu (dcc64 37.0 orders two
    // records of the type's entry apart when an EXTERNALSYM names it and
    // its result is an alias) - the directive after the `;` says which.
    (Section: '6.6.1'; Name: 'F29: a result type, the convention written in';
     Source: 'type T = function: BOOL stdcall;';
     Expected: 'TypeSec(TypeDecl(Ident''T'' ProcType(Ident''BOOL'' ' +
       'Directive''stdcall'')))';
     ExpectDiags: 0),
    (Section: '6.6.1'; Name: 'F29: a result type, the convention after the ;';
     Source: 'type T = function: BOOL; stdcall;';
     Expected: 'TypeSec(TypeDecl(Ident''T'' ProcType(Ident''BOOL'' ' +
       'Directive''stdcall''#semi)))';
     ExpectDiags: 0),
    (Section: '6.6.1'; Name: 'F29: of object, written in and after the ;';
     Source: 'var V: function: BOOL stdcall of object; cdecl;';
     Expected: 'VarSec''var''(VarDecl(Ident''V''#name ' +
       'ProcType#ofobject(Ident''BOOL'' Directive''stdcall'' ' +
       'Directive''cdecl''#semi)))';
     ExpectDiags: 0),
    (Section: '6.1'; Name: 'recovery: a bare routine keyword keeps the next decl';
     Source: 'type A = Byte;'#10'function'#10'B = Integer;';
     Expected: 'TypeSec(TypeDecl(Ident''A'' Ident''Byte'')) Routine''function'' ' +
       'TypeSec(TypeDecl(Ident''B'' Ident''Integer''))'; ExpectDiags: 2),
    (Section: '3.2.1'; Name: 'recovery: const name alone keeps the next decl';
     Source: 'const A'#10'B = 1;';
     Expected: 'ConstSec''const''(ConstDecl(Ident''A'') ConstDecl(Ident''B'' ' +
       'IntLit''1''))'; ExpectDiags: 1),
    (Section: '3.1.1'; Name: 'recovery: var name alone keeps the next decl';
     Source: 'var A'#10'B: Integer;';
     Expected: 'VarSec''var''(VarDecl(Ident''A''#name) ' +
       'VarDecl(Ident''B''#name ' +
       'Ident''Integer''))'; ExpectDiags: 1),

    // ---- valid code the line heuristic must not touch: each of these is
    // token-identical to a typing state above and was a false diagnostic in a
    // real project before its guard. ----
    (Section: '16.4'; Name: 'wrapped generic constraints are parameters';
     Source: 'type G<'#10'TInfo: TObject;'#10'TOptions: record> ='#10'class end;';
     Expected: 'TypeSec(TypeDecl(Ident''G'' GenericParams(GenericParam(' +
       'Ident''TInfo'' Constraint(Ident''TObject'')) GenericParam(' +
       'Ident''TOptions'' Constraint''record'')) ClassType))'; ExpectDiags: 0),
    (Section: '3.2.2'; Name: 'wrapped typed const type followed by its initializer';
     Source: 'const A: array[0..1] of'#10'TC = (nil, nil);';
     Expected: 'ConstSec''const''(ConstDecl(Ident''A'' ArrayType(Subrange(' +
       'IntLit''0'' IntLit''1'') Ident''TC'') Aggregate(NilLit NilLit)))';
     ExpectDiags: 0),

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
       'Ident''A''#name Ident''Integer'')))))'; ExpectDiags: 0),
    (Section: '6.6.1'; Name: 'method pointer';
     Source: 'type TEvent = procedure(Sender: TObject) of object;';
     Expected: 'TypeSec(TypeDecl(Ident''TEvent'' ProcType#ofobject(' +
       'Params(Param(Ident''Sender''#name ' +
       'Ident''TObject'')))))'; ExpectDiags: 0),
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
       'VarDecl(Ident''FX''#name Ident''Integer'') ' +
       'VarSec#class(VarDecl(Ident''Count''#name Ident''Integer'')) ' +
       'Routine''procedure''(Ident''Go''#name) ' +
       'Routine''function''#class(Ident''Make''#name Ident''TR'' ' +
       'Directive''static'') ' +
       'PropertyDecl(Ident''X'' Ident''Integer'' PropSpec''read''(' +
       'Ident''FX'') PropSpec''write''(Ident''FX'')))))'; ExpectDiags: 0),
    (Section: '9.2.2'; Name: 'record constructor';
     Source: 'type TR = record constructor Create(A: Integer); end;';
     Expected: 'TypeSec(TypeDecl(Ident''TR'' RecordType(' +
       'Routine''constructor''(Ident''Create''#name ' +
       'Params(Param(Ident''A''#name ' +
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
       'Visibility''private''#strict VarDecl(Ident''FA''#name ' +
       'Ident''Integer'') ' +
       'Visibility''protected'' VarDecl(Ident''FB''#name Ident''Integer'') ' +
       'Visibility''published'' VarDecl(Ident''FC''#name Ident''Integer''))))';
     ExpectDiags: 0),
    // 12.2.3 reintroduce, and 12.2.1 virtual/override -- directives are
    // nodes, and which directive it is is the head word.
    (Section: '12.2.3'; Name: 'reintroduce';
     Source: 'type'#13#10'  TC = class(TObject)'#13#10 +
       '    procedure P; virtual;'#13#10 +
       '    procedure Q; reintroduce; overload;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(Ident''TObject'' ' +
       'Routine''procedure''(Ident''P''#name Directive''virtual'') ' +
       'Routine''procedure''(Ident''Q''#name Directive''reintroduce'' ' +
       'Directive''overload''))))'; ExpectDiags: 0),

    // ---- 14.x interfaces ----
    (Section: '14.1.2'; Name: 'dispinterface';
     Source: 'type'#13#10'  ID = dispinterface'#13#10 +
       '    [''{11111111-2222-3333-4444-555555555555}'']'#13#10 +
       '    procedure P;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''ID'' InterfaceType#disp(Guid ' +
       'Routine''procedure''(Ident''P''#name))))'; ExpectDiags: 0),
    (Section: '14.1.1'; Name: 'interface is not a dispinterface';
     Source: 'type IFoo = interface procedure P; end;';
     Expected: 'TypeSec(TypeDecl(Ident''IFoo'' InterfaceType(' +
       'Routine''procedure''(Ident''P''#name))))'; ExpectDiags: 0),
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
       'Ident''IFoo'' MethodResolution(Ident''IFoo''#name Ident''P''#name ' +
       'Ident''MyP''))))'; ExpectDiags: 0),

    // ---- 15.3.1 helpers ----
    (Section: '15.3.1'; Name: 'class helper';
     Source: 'type TH = class helper for TObject procedure P; end;';
     Expected: 'TypeSec(TypeDecl(Ident''TH'' HelperType(Ident''TObject'' ' +
       'Routine''procedure''(Ident''P''#name))))'; ExpectDiags: 0),
    (Section: '15.3.1'; Name: 'record helper';
     Source: 'type TH = record helper for Integer procedure P; end;';
     Expected: 'TypeSec(TypeDecl(Ident''TH'' HelperType#record(' +
       'Ident''Integer'' Routine''procedure''(Ident''P''#name))))';
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

    // ---- 7.1.7 UCS4Char / UCS4String, same row shape as its six siblings
    // above. Deliberately NOT seeded into PasTree.Sema.Builtins: the spec is
    // explicit that both are REAL System.pas declarations (`UCS4Char =
    // Cardinal`, `UCS4String = array of UCS4Char`), and that seed list is
    // only for names with no declaration anywhere -- seeding a declared name
    // is exactly the mistake its own comment warns about at length. So they
    // resolve through the real System unit like any other imported type, and
    // there is nothing string-specific to model: `UCS4String` being a plain
    // dynamic array means 8.2's rules (and 20.3.1's managedness) already
    // cover it unchanged. dcc32 37.0 probe-verified: both resolve with no
    // uses clause, and `UnicodeStringToUCS4String('Hello')` really returns 6
    // elements with S[0] = 72, exactly as the spec documents. ----
    (Section: '7.1.7'; Name: 'UCS4Char and UCS4String';
     Source: 'type'#13#10'  TC4 = UCS4Char;'#13#10 +
       '  TS4 = UCS4String;';
     Expected: 'TypeSec(TypeDecl(Ident''TC4'' Ident''UCS4Char'') ' +
       'TypeDecl(Ident''TS4'' Ident''UCS4String''))'; ExpectDiags: 0),

    // ---- 6.2.7 untyped parameters: a name with no ':' type at all ----
    (Section: '6.2.7'; Name: 'untyped var parameter';
     Source: 'procedure P(var X);';
     Expected: 'Routine''procedure''(Ident''P''#name ' +
       'Params(Param(Ident''X''#name)))';
     ExpectDiags: 0),

    // ---- 6.7.1 external, never exercised at all (varargs alone was) ----
    (Section: '6.7.1'; Name: 'external plain';
     Source: 'procedure P; external ''user32.dll'';';
     Expected: 'Routine''procedure''(Ident''P''#name Directive''external''(' +
       'StrLit''''user32.dll''''))'; ExpectDiags: 0),
    (Section: '6.7.1'; Name: 'external name';
     Source: 'procedure P; external ''user32.dll'' name ''RealP'';';
     Expected: 'Routine''procedure''(Ident''P''#name Directive''external''(' +
       'StrLit''''user32.dll'''' StrLit''''RealP''''))'; ExpectDiags: 0),
    (Section: '6.7.1'; Name: 'external index';
     Source: 'function F: Integer; external ''k32.dll'' index 5;';
     Expected: 'Routine''function''(Ident''F''#name Ident''Integer'' ' +
       'Directive''external''(StrLit''''k32.dll'''' IntLit''5''))';
     ExpectDiags: 0),
    (Section: '6.7.1'; Name: 'external delayed';
     Source: 'procedure P; external ''x.dll'' delayed;';
     // `delayed` is consumed but adopts no child of its own -- only name/
     // index/dependency arguments become children (ParseRoutineDirectives).
     Expected: 'Routine''procedure''(Ident''P''#name Directive''external''(' +
       'StrLit''''x.dll''''))'; ExpectDiags: 0),

    // ---- 14.3.2 [weak]/[unsafe] on an interface-typed field: an attribute
    // group in member position -- pin the CURRENT shape, since the parser
    // adopts it onto the class, a SIBLING of the field, not onto the field
    // itself (ParseMemberList's tkLBracket branch) ----
    (Section: '14.3.2'; Name: 'weak attribute on an interface field';
     Source: 'type'#13#10'  TC = class'#13#10 +
       '    [weak] FFoo: IFoo;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(AttrGroup(' +
       'Attribute#weak(Ident''weak'')) VarDecl(Ident''FFoo''#name ' +
       'Ident''IFoo''))))';
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
       'Attribute#volatile(Ident''Volatile'')) VarDecl(Ident''F''#name ' +
       'Ident''Integer''))))';
     ExpectDiags: 0),
    (Section: '19.3.3'; Name: '[unsafe] as an ATTRIBUTE, not the directive '
      + 'word';
     Source: 'type TC = class [unsafe] F: TObject; end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(AttrGroup(' +
       'Attribute#unsafe(Ident''unsafe'')) VarDecl(Ident''F''#name ' +
       'Ident''TObject''))))';
     ExpectDiags: 0),
    (Section: '19.3.3'; Name: 'the Attribute suffix is recognized too';
     Source: 'type TC = class [WeakAttribute] F: IInterface; end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(AttrGroup(' +
       'Attribute#weak(Ident''WeakAttribute'')) VarDecl(Ident''F''#name ' +
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
     Expected: 'Routine''procedure''(Ident''P''#name Directive''forward'')';
     ExpectDiags: 0),

    // ---- 6.2.1-6.2.4 every parameter passing mode in one signature ----
    (Section: '6.2.1'; Name: 'value, var, const, out parameters';
     Source: 'procedure P(A: Integer; var B: Integer; const C: Integer; ' +
       'out D: Integer);';
     Expected: 'Routine''procedure''(Ident''P''#name ' +
       'Params(Param(Ident''A''#name ' +
       'Ident''Integer'') Param(Ident''B''#name Ident''Integer'') ' +
       'Param(Ident''C''#name Ident''Integer'') Param#out(Ident''D''#name ' +
       'Ident''Integer'')))'; ExpectDiags: 0),

    // ---- 6.2.5 default (optional) parameters ----
    (Section: '6.2.5'; Name: 'default parameter value';
     Source: 'procedure P(A: Integer = 5);';
     Expected: 'Routine''procedure''(Ident''P''#name ' +
       'Params(Param(Ident''A''#name ' +
       'Ident''Integer'' IntLit''5'')))'; ExpectDiags: 0),

    // ---- 6.2.6 open array and array-of-const parameters ----
    (Section: '6.2.6'; Name: 'open array and array of const parameters';
     Source: 'procedure P(const A: array of Integer; const B: array of const);';
     Expected: 'Routine''procedure''(Ident''P''#name ' +
       'Params(Param(Ident''A''#name ' +
       'ArrayType(Ident''Integer'')) Param(Ident''B''#name ' +
       'ArrayType#ofconst)))';
     ExpectDiags: 0),

    // ---- 6.3.1 / 6.4.1 / 6.5.1 / 6.8 routine directives never exercised on
    // a plain (non-external, non-message) routine before ----
    (Section: '6.3.1'; Name: 'overload directive';
     Source: 'procedure P(A: Integer); overload;';
     Expected: 'Routine''procedure''(Ident''P''#name ' +
       'Params(Param(Ident''A''#name ' +
       'Ident''Integer'')) Directive''overload'')'; ExpectDiags: 0),
    (Section: '6.4.1'; Name: 'inline directive';
     Source: 'procedure P; inline;';
     Expected: 'Routine''procedure''(Ident''P''#name Directive''inline'')';
     ExpectDiags: 0),
    (Section: '6.5.1'; Name: 'calling convention directives';
     Source: 'procedure P; stdcall;'#13#10'procedure Q; cdecl;';
     Expected: 'Routine''procedure''(Ident''P''#name Directive''stdcall'') ' +
       'Routine''procedure''(Ident''Q''#name Directive''cdecl'')';
     ExpectDiags: 0),
    (Section: '6.8'; Name: 'noreturn directive';
     Source: 'procedure P; noreturn;';
     Expected: 'Routine''procedure''(Ident''P''#name Directive''noreturn'')';
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
       'Ident''X''#name Ident''Byte''))))'; ExpectDiags: 0),

    // ---- 9.1.3 variant records (the `case` part) ----
    (Section: '9.1.3'; Name: 'variant record';
     Source: 'type'#13#10'  TR = record'#13#10 +
       '    case Integer of'#13#10 +
       '      0: (X: Integer);'#13#10 +
       '      1: (Y: Single);'#13#10 +
       '  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TR'' RecordType(VariantPart(' +
       'Ident''Integer'' VariantBranch(IntLit''0'' VarDecl(Ident''X''#name ' +
       'Ident''Integer'')) VariantBranch(IntLit''1'' VarDecl(Ident''Y''#name ' +
       'Ident''Single''))))))'; ExpectDiags: 0),
    // The tag may start the line after `case` (dcc64 37.0, probed 2026-09-28;
    // plan finding F28). A recovery rule took any `Ident :` starting that
    // line for the next field - `case` typed above `Reserve: array...` - and
    // made the valid shape a parse error. A branch label's `:` after an `of`,
    // before any `;` / `end`, is what tells the tag.
    (Section: '9.1.3'; Name: 'variant tag on the line after case';
     Source: 'type TR = record A: Integer; case'#13#10 +
       '  Tag: Byte of 0: (B: Integer); 1: (C: Word); end;';
     Expected: 'TypeSec(TypeDecl(Ident''TR'' RecordType(VarDecl(Ident''A''#name ' +
       'Ident''Integer'') VariantPart(Ident''Tag'' Ident''Byte'' ' +
       'VariantBranch(IntLit''0'' VarDecl(Ident''B''#name ' +
       'Ident''Integer'')) VariantBranch(IntLit''1'' ' +
       'VarDecl(Ident''C''#name Ident''Word''))))))'; ExpectDiags: 0),
    (Section: '9.1.3'; Name: 'variant tag, its colon on the next line';
     Source: 'type TR = record case'#13#10'  Tag'#13#10 +
       '  : Byte of 0: (B: Integer); end;';
     Expected: 'TypeSec(TypeDecl(Ident''TR'' RecordType(VariantPart(Ident''Tag'' ' +
       'Ident''Byte'' VariantBranch(IntLit''0'' VarDecl(Ident''B''#name ' +
       'Ident''Integer''))))))'; ExpectDiags: 0),
    (Section: '9.1.3'; Name: 'variant tag on the next line, an enum type';
     Source: 'type TR = record case'#13#10 +
       '  Kind: (kA, kB) of kA: (B: Integer); kB: (C: Double); end;';
     Expected: 'TypeSec(TypeDecl(Ident''TR'' ' +
       'RecordType(VariantPart(Ident''Kind'' ' +
       'EnumType(EnumValue(Ident''kA'') EnumValue(Ident''kB'')) ' +
       'VariantBranch(Ident''kA'' VarDecl(Ident''B''#name ' +
       'Ident''Integer'')) VariantBranch(Ident''kB'' ' +
       'VarDecl(Ident''C''#name Ident''Double''))))))'; ExpectDiags: 0),
    (Section: '9.1.3'; Name: 'variant tag on the next line, a set type';
     Source: 'type TR = record case'#13#10 +
       '  S: set of Byte of [1]: (C: Integer); end;';
     Expected: 'TypeSec(TypeDecl(Ident''TR'' RecordType(VariantPart(Ident''S'' ' +
       'SetType(Ident''Byte'') VariantBranch(SetCtor(IntLit''1'') ' +
       'VarDecl(Ident''C''#name Ident''Integer''))))))'; ExpectDiags: 0),
    (Section: '9.1.3'; Name: 'variant tag on the next line, a nested part';
     Source: 'type TR = record case Integer of'#13#10 +
       '  0: (A: Byte; case'#13#10'    Sub: Word of 0: (B: Integer));'#13#10 +
       '  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TR'' ' +
       'RecordType(VariantPart(Ident''Integer'' ' +
       'VariantBranch(IntLit''0'' VarDecl(Ident''A''#name Ident''Byte'') ' +
       'VariantPart(Ident''Sub'' Ident''Word'' VariantBranch(IntLit''0'' ' +
       'VarDecl(Ident''B''#name Ident''Integer''))))))))'; ExpectDiags: 0),
    // A qualified label's member on the next line is the label's - it is
    // followed by `: (` - not the next field's head.
    (Section: '9.1.3'; Name: 'variant label, member on the next line';
     Source: 'type TR = record case K: TK of TK.'#13#10 +
       '  kA: (B: Integer); TK.'#13#10'  kB: (C: Word); end;';
     Expected: 'TypeSec(TypeDecl(Ident''TR'' RecordType(VariantPart(Ident''K'' ' +
       'Ident''TK'' VariantBranch(Member(Ident''TK'' Ident''kA'') ' +
       'VarDecl(Ident''B''#name Ident''Integer'')) ' +
       'VariantBranch(Member(Ident''TK'' Ident''kB'') ' +
       'VarDecl(Ident''C''#name Ident''Word''))))))'; ExpectDiags: 0),
    // The recovery it was for stays: `case` typed above a field.
    (Section: '9.1.3'; Name: 'case typed above a field (recovery)';
     Source: 'type TR = record case'#13#10 +
       '  Reserve: array[0..3] of Byte;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TR'' RecordType(VariantPart ' +
       'VarDecl(Ident''Reserve''#name ArrayType(Subrange(IntLit''0'' ' +
       'IntLit''3'') Ident''Byte'')))))'; ExpectDiags: 1),
    (Section: '9.1.3'; Name: 'case typed above a procedural field (recovery)';
     Source: 'type TR = record case'#13#10 +
       '  F: function: Integer of object;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TR'' RecordType(VariantPart ' +
       'VarDecl(Ident''F''#name ProcType#ofobject(Ident''Integer'')))))'; ExpectDiags: 1),
    (Section: '9.1.3'; Name: 'variant label typed above a field (recovery)';
     Source: 'type TR = record case K: TK of TK.'#13#10 +
       '  Reserve: array[0..3] of Byte;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TR'' RecordType(VariantPart(Ident''K'' ' +
       'Ident''TK'' VariantBranch(Member(Ident''TK''))) ' +
       'VarDecl(Ident''Reserve''#name ArrayType(Subrange(IntLit''0'' ' +
       'IntLit''3'') Ident''Byte'')))))'; ExpectDiags: 2),

    // ---- 9.3.1 class operator declarations ----
    (Section: '9.3.1'; Name: 'class operator';
     Source: 'type TVec = record'#13#10 +
       '    class operator Add(A, B: TVec): TVec;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TVec'' RecordType(' +
       'Routine''operator''#class(Ident''Add''#name ' +
       'Params(Param(Ident''A''#name ' +
       'Ident''B''#name Ident''TVec'')) Ident''TVec''))))'; ExpectDiags: 0),

    // ---- 10.1.1 / 10.1.2 typed and untyped pointers ----
    (Section: '10.1.1'; Name: 'typed pointer';
     Source: 'type PInt = ^Integer;';
     Expected: 'TypeSec(TypeDecl(Ident''PInt'' PointerType(' +
       'Ident''Integer'')))'; ExpectDiags: 0),
    (Section: '10.1.2'; Name: 'untyped Pointer variable';
     Source: 'var P: Pointer;';
     Expected: 'VarSec''var''(VarDecl(Ident''P''#name Ident''Pointer''))';
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
       'Routine''constructor''(Ident''Create''#name ' +
       'Params(Param(Ident''A''#name ' +
       'Ident''Integer''))))))'; ExpectDiags: 0),
    (Section: '11.3.2'; Name: 'class destructor declaration';
     Source: 'type TC = class(TObject)'#13#10 +
       '    destructor Destroy; override;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(Ident''TObject'' ' +
       'Routine''destructor''(Ident''Destroy''#name Directive''override''))))';
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
       'Ident''X''#name Ident''Integer''))))'; ExpectDiags: 0),

    // ---- 12.2.1 / 12.2.2 / 12.2.4 / 12.2.5 method-binding directives ----
    (Section: '12.2.1'; Name: 'virtual and override';
     Source: 'type'#13#10'  TBase = class'#13#10 +
       '    procedure P; virtual;'#13#10'  end;'#13#10 +
       '  TSub = class(TBase)'#13#10 +
       '    procedure P; override;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TBase'' ClassType(' +
       'Routine''procedure''(Ident''P''#name Directive''virtual''))) ' +
       'TypeDecl(Ident''TSub'' ClassType(Ident''TBase'' ' +
       'Routine''procedure''(Ident''P''#name Directive''override''))))';
     ExpectDiags: 0),
    (Section: '12.2.2'; Name: 'dynamic directive';
     Source: 'type TC = class'#13#10'    procedure P; dynamic;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(' +
       'Routine''procedure''(Ident''P''#name Directive''dynamic''))))';
     ExpectDiags: 0),
    (Section: '12.2.4'; Name: 'abstract method';
     Source: 'type TC = class'#13#10 +
       '    procedure P; virtual; abstract;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(' +
       'Routine''procedure''(Ident''P''#name Directive''virtual'' ' +
       'Directive''abstract''))))'; ExpectDiags: 0),
    (Section: '12.2.5'; Name: 'sealed class and final method';
     Source: 'type TC = class sealed'#13#10 +
       '    procedure P; virtual; final;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(' +
       'Routine''procedure''(Ident''P''#name Directive''virtual'' ' +
       'Directive''final''))))'; ExpectDiags: 0),

    // ---- 12.3.1 message methods ----
    (Section: '12.3.1'; Name: 'message method';
     Source: 'type TC = class'#13#10 +
       '    procedure WMPaint(var Msg: TMessage); message WM_PAINT;'#13#10 +
       '  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(' +
       'Routine''procedure''(Ident''WMPaint''#name ' +
       'Params(Param(Ident''Msg''#name ' +
       'Ident''TMessage'')) Directive''message''(Ident''WM_PAINT'')))))';
     ExpectDiags: 0),

    // ---- 13.1.2 / 13.1.3 / 13.1.4 / 13.1.5 / 13.3.1 property shapes ----
    (Section: '13.1.2'; Name: 'array property';
     Source: 'type TC = class'#13#10 +
       '    property Items[Idx: Integer]: string read GetItem write SetItem;'#13#10 +
       '  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(PropertyDecl(' +
       'Ident''Items'' Params(Param(Ident''Idx''#name Ident''Integer'')) ' +
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
       'Ident''Items'' Params(Param(Ident''I''#name Ident''Integer'')) ' +
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
       'Routine''procedure''#class(Ident''P''#name Directive''static''))))';
     ExpectDiags: 0),
    (Section: '15.1.5'; Name: 'class constructor and destructor';
     Source: 'type TC = class'#13#10 +
       '    class constructor Create;'#13#10 +
       '    class destructor Destroy;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(' +
       'Routine''constructor''#class(Ident''Create''#name) ' +
       'Routine''destructor''#class(Ident''Destroy''#name))))'; ExpectDiags: 0),
    (Section: '15.2.1'; Name: 'class of type';
     Source: 'type TClassRef = class of TObject;';
     Expected: 'TypeSec(TypeDecl(Ident''TClassRef'' ClassOf(' +
       'Ident''TObject'')))'; ExpectDiags: 0),
    (Section: '15.2.2'; Name: 'type of a class and an interface';
     Source: 'type TC = type of TForm1; TI = type of IInterface;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassOf#typeof(' +
       'Ident''TForm1'')) TypeDecl(Ident''TI'' ClassOf#typeof(' +
       'Ident''IInterface'')))'; ExpectDiags: 0),
    (Section: '15.2.2'; Name: 'type of interface (no target)';
     Source: 'type TRef = type of interface; TId = type Integer;';
     Expected: 'TypeSec(TypeDecl(Ident''TRef'' ClassOf#typeof) ' +
       'TypeDecl#distinct(Ident''TId'' Ident''Integer''))'; ExpectDiags: 0),

    // ---- 16.1.1 / 16.4.1 generics never pinned at the DECLARATION level
    // (16.3 already covers a generic reference in an EXPRESSION) ----
    (Section: '16.1.1'; Name: 'generic class declaration';
     Source: 'type TBox<T> = class'#13#10'    FValue: T;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TBox'' GenericParams(' +
       'GenericParam(Ident''T'')) ClassType(VarDecl(Ident''FValue''#name ' +
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
    // dcc-verified: TWO generic parameters closed with NO space before the
    // `=` that follows (`T, TT >= class`) lex `>=` as ONE fused
    // greater-or-equal token - real source in the wild (a detours library's
    // `TGenericsCast < T, TT >= class(TObject)`). The parser must split it:
    // consume the '>' as the list's close, leave the '=' pending for the
    // type declaration's own `=`. Without the split this dropped the SECOND
    // parameter entirely and read as `TypeDecl(Ident TGenericsCast
    // GenericParams(GenericParam(Ident T)))` followed by a parse error where
    // `TT` and `>=` themselves became the (nonsensical) type expression.
    (Section: '16.3.1'; Name: 'fused ">=" splits at a generic list''s close';
     Source: 'type TGenericsCast<T, TT>= class(TObject) end;';
     Expected: 'TypeSec(TypeDecl(Ident''TGenericsCast'' GenericParams(' +
       'GenericParam(Ident''T'' Ident''TT'')) ' +
       'ClassType(Ident''TObject'')))'; ExpectDiags: 0),

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
     Expected: 'VarSec''var''(VarDecl(Ident''X''#name Ident''Integer''))';
     ExpectDiags: 0),
    (Section: '3.1.2'; Name: 'initialized global variable';
     Source: 'var X: Integer = 5;';
     Expected: 'VarSec''var''(VarDecl(Ident''X''#name Ident''Integer'' ' +
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
     Expected: 'Routine''procedure''(Ident''P''#name ' +
       'Params(Param(Ident''A''#name ' +
       'Ident''Integer'')))'; ExpectDiags: 0),
    (Section: '6.2.3'; Name: 'const [Ref] parameter';
     Source: 'procedure P(const [Ref] A: Integer);';
     Expected: 'Routine''procedure''(Ident''P''#name Params(Param(AttrGroup(' +
       'Attribute#ref(Ident''Ref'')) Ident''A''#name Ident''Integer'')))';
     ExpectDiags: 0),
    (Section: '6.2.4'; Name: 'a lone out parameter';
     Source: 'procedure P(out A: Integer);';
     Expected: 'Routine''procedure''(Ident''P''#name Params(Param#out(' +
       'Ident''A''#name Ident''Integer'')))'; ExpectDiags: 0),

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
       'Ident''X''#name Ident''Y''#name Ident''Integer''))))'; ExpectDiags: 0),

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
       'Routine''operator''#class(Ident''Initialize''#name Params(Param#out(' +
       'Ident''Dest''#name Ident''TR''))) Routine''operator''#class(' +
       'Ident''Finalize''#name Params(Param(Ident''Dest''#name ' +
       'Ident''TR''))) ' +
       'Routine''operator''#class(Ident''Assign''#name Params(Param(' +
       'Ident''Dest''#name Ident''TR'') Param(AttrGroup(Attribute#ref(' +
       'Ident''Ref'')) Ident''Src''#name Ident''TR''))))))'; ExpectDiags: 0),

    // ---- 9.4.2 (13.0) the PARAMETERLESS Initialize/Finalize: before 13.0
    // the explicit `(var X: T)` parameter was REQUIRED, from 13.0 it is
    // optional and Self is implied. The spec asks a parser for exactly one
    // thing here -- accept BOTH arities -- so this row is only half the
    // rule; 9.4.1's row right above is the other half (same two operators
    // WITH their parameters), and the pair is what pins it. dcc32 37.0
    // probe-verified to accept this form before the row was written; the
    // parser needed no change, a Routine simply has no Params child. ----
    (Section: '9.4.2'; Name: 'parameterless Initialize/Finalize (implicit Self)';
     Source: 'type TG = record'#13#10 +
       '    class operator Initialize;'#13#10 +
       '    class operator Finalize;'#13#10 +
       '  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TG'' RecordType(' +
       'Routine''operator''#class(Ident''Initialize''#name) ' +
       'Routine''operator''#class(Ident''Finalize''#name))))';
     ExpectDiags: 0),

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
       'Routine''procedure''#class(Ident''P''#name))))'; ExpectDiags: 0),
    (Section: '15.1.2'; Name: 'class var';
     Source: 'type TC = class'#13#10 +
       '    class var Count: Integer;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(VarSec#class(' +
       'VarDecl(Ident''Count''#name Ident''Integer'')))))'; ExpectDiags: 0),
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
       'Ident''X''#name Ident''Y''#name Ident''Integer''))) TypeDecl(' +
       'Ident''TPointHelper'' HelperType#record(Ident''TPoint'' ' +
       'Routine''procedure''(Ident''Offset''#name ' +
       'Params(Param(Ident''DX''#name ' +
       'Ident''DY''#name Ident''Integer''))))))'; ExpectDiags: 0),

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
       'Routine''procedure''(Ident''P''#name GenericParams(GenericParam(' +
       'Ident''T'')) Params(Param(Ident''A''#name Ident''T''))))))';
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
       'Attribute#weak(Ident''weak'')) VarDecl(Ident''FFoo''#name ' +
       'Ident''IFoo''))))';
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
     Expected: 'Routine''procedure''(Ident''P''#name) ' +
       'Routine''function''(Ident''F''#name Ident''Integer'')'; ExpectDiags: 0),

    // ---- 11.1.2 / 11.1.3 fields and methods, each standing alone with
    // nothing else in the class (every prior class case bundles them with
    // something richer -- visibility, directives, generics) ----
    (Section: '11.1.2'; Name: 'a class with only fields';
     Source: 'type TC = class'#13#10'    FX, FY: Integer;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(VarDecl(' +
       'Ident''FX''#name Ident''FY''#name ' +
       'Ident''Integer''))))'; ExpectDiags: 0),
    (Section: '11.1.3'; Name: 'a class with only a method';
     Source: 'type TC = class'#13#10'    procedure P;'#13#10'  end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(' +
       'Routine''procedure''(Ident''P''#name))))'; ExpectDiags: 0),

    // ==== test-coverage plan step 3 batch 7 ====================

    // ---- B.11 a type reference combining THREE forms at once -- dotted
    // (qualified), generic instantiation, and pointer-to -- each shown
    // separately in some other case (1.2.2, 16.3, 10.1.1), never together
    // the way a real reference to a unit's generic type usually reads ----
    (Section: 'B.11'; Name: 'a dotted, generic, pointer type reference';
     Source: 'type TP = ^Generics.Collections.TList<Integer>;';
     Expected: 'TypeSec(TypeDecl(Ident''TP'' PointerType(TypeArgs(' +
       'Member(Member(Ident''Generics'' Ident''Collections'') ' +
       'Ident''TList'') Ident''Integer''))))'; ExpectDiags: 0),

    // ---- Code audit 2026-08-31, section 2.9 ----
    // 14.1.1: a FORWARD interface is not a dispinterface. Both used to write
    // Aux = 1, so the two were indistinguishable in the tree.
    (Section: '14.1.1'; Name: 'a forward interface is marked forward, not disp';
     Source: 'type IFoo = interface;';
     Expected: 'TypeSec(TypeDecl(Ident''IFoo'' InterfaceType#forward))';
     ExpectDiags: 0),
    (Section: '14.1.1'; Name: 'and a dispinterface still reads as one';
     Source: 'type IFoo = dispinterface end;';
     Expected: 'TypeSec(TypeDecl(Ident''IFoo'' InterfaceType#disp))';
     ExpectDiags: 0),
    // 14.1.1: a GUID clause written as a NAMED CONSTANT is still the GUID
    // clause, not an attribute group.
    (Section: '14.1.1'; Name: 'a named-constant GUID clause';
     Source: 'type IFoo = interface [SID_IFoo] end;';
     Expected: 'TypeSec(TypeDecl(Ident''IFoo'' InterfaceType(' +
       'Guid(Ident''SID_IFoo''))))'; ExpectDiags: 0),
    // 2.2.5: an IDENT-headed subrange bound may carry arithmetic. Only
    // selector continuations were allowed after an identifier head, so both
    // of these - dcc64-valid - were hard parse errors.
    (Section: '2.2.5'; Name: 'ident-headed subrange bound with arithmetic';
     Source: 'type T = A+1..B;';
     Expected: 'TypeSec(TypeDecl(Ident''T'' Subrange(BinaryOp''+''(' +
       'Ident''A'' IntLit''1'') Ident''B'')))'; ExpectDiags: 0),
    (Section: '2.2.5'; Name: 'array index range with arithmetic bounds';
     Source: 'var A: array[B-1..B] of Integer;';
     Expected: 'VarSec''var''(VarDecl(Ident''A''#name ArrayType(Subrange(' +
       'BinaryOp''-''(Ident''B'' IntLit''1'') Ident''B'') ' +
       'Ident''Integer'')))'; ExpectDiags: 0),
    // 2.2.5: where the upper bound ends (dcc64 37.0, probed 2026-09-27; plan
    // finding F6). In the declared type of a var-section variable or a typed
    // constant a top-level `=` ends the upper bound of the subrange that
    // closes the type - the initializer follows. The bound used to take it:
    // `var V: 0..31 = 7;` was the type `0..(31 = 7)` with no initializer and
    // no diagnostic, and the typed constants were parse errors.
    (Section: '2.2.5'; Name: 'typed constant of a subrange type';
     Source: 'const A: 0..31 = 5;';
     Expected: 'ConstSec''const''(ConstDecl(Ident''A'' Subrange(' +
       'IntLit''0'' IntLit''31'') IntLit''5''))'; ExpectDiags: 0),
    (Section: '2.2.5'; Name: 'initialized variable of a subrange type';
     Source: 'var V: 0..31 = 7;';
     Expected: 'VarSec''var''(VarDecl(Ident''V''#name Subrange(' +
       'IntLit''0'' IntLit''31'') IntLit''7''))'; ExpectDiags: 0),
    (Section: '2.2.5'; Name: 'initialized variable, name-headed bounds';
     Source: 'var V: L..M = 7;';
     Expected: 'VarSec''var''(VarDecl(Ident''V''#name Subrange(' +
       'Ident''L'' Ident''M'') IntLit''7''))'; ExpectDiags: 0),
    (Section: '2.2.5'; Name: 'typed constant, set of a subrange';
     Source: 'const S: set of 0..31 = [1, 2];';
     Expected: 'ConstSec''const''(ConstDecl(Ident''S'' SetType(Subrange(' +
       'IntLit''0'' IntLit''31'')) SetCtor(IntLit''1'' IntLit''2'')))';
     ExpectDiags: 0),
    (Section: '2.2.5'; Name: 'typed constant, array of set of a subrange';
     Source: 'const B: array[Boolean] of set of 0..31 = ([1], [2]);';
     Expected: 'ConstSec''const''(ConstDecl(Ident''B'' ArrayType(' +
       'Ident''Boolean'' SetType(Subrange(IntLit''0'' IntLit''31''))) ' +
       'Aggregate(SetCtor(IntLit''1'') SetCtor(IntLit''2''))))';
     ExpectDiags: 0),
    // Only `=` ends it: `<` chains on, as the probe's value (True) showed.
    (Section: '2.2.5'; Name: 'typed constant, a relational upper bound';
     Source: 'const A: False..1 < 2 = True;';
     Expected: 'ConstSec''const''(ConstDecl(Ident''A'' Subrange(' +
       'Ident''False'' BinaryOp''<''(IntLit''1'' IntLit''2'')) ' +
       'Ident''True''))'; ExpectDiags: 0),
    // Everywhere else the bound is a whole expression, `=` included.
    (Section: '2.2.5'; Name: 'type declaration: the upper bound takes =';
     Source: 'type T = False..1 = 1;';
     Expected: 'TypeSec(TypeDecl(Ident''T'' Subrange(Ident''False'' ' +
       'BinaryOp''=''(IntLit''1'' IntLit''1''))))'; ExpectDiags: 0),
    (Section: '2.2.5'; Name: 'typed constant: the LOWER bound takes =';
     Source: 'const A: 1 = 1..True = True;';
     Expected: 'ConstSec''const''(ConstDecl(Ident''A'' Subrange(' +
       'BinaryOp''=''(IntLit''1'' IntLit''1'') Ident''True'') ' +
       'Ident''True''))'; ExpectDiags: 0),
    (Section: '2.2.5'; Name: 'typed constant: an index bound takes =';
     Source: 'const A: array[False..1 = 1] of Integer = (1, 2);';
     Expected: 'ConstSec''const''(ConstDecl(Ident''A'' ArrayType(Subrange(' +
       'Ident''False'' BinaryOp''=''(IntLit''1'' IntLit''1'')) ' +
       'Ident''Integer'') Aggregate(IntLit''1'' IntLit''2'')))';
     ExpectDiags: 0),
    (Section: '2.2.5'; Name: 'initialized variable: index takes =, element not';
     Source: 'var A: array[False..1 = 1] of 0..31 = (1, 2);';
     Expected: 'VarSec''var''(VarDecl(Ident''A''#name ArrayType(Subrange(' +
       'Ident''False'' BinaryOp''=''(IntLit''1'' IntLit''1'')) ' +
       'Subrange(IntLit''0'' IntLit''31'')) Aggregate(IntLit''1'' ' +
       'IntLit''2'')))'; ExpectDiags: 0),
    (Section: '2.2.5'; Name: 'record field: the upper bound takes =';
     Source: 'type TR = record F: False..1 = 1; end;';
     Expected: 'TypeSec(TypeDecl(Ident''TR'' ' +
       'RecordType(VarDecl(Ident''F''#name ' +
       'Subrange(Ident''False'' BinaryOp''=''(IntLit''1'' ' +
       'IntLit''1''))))))'; ExpectDiags: 0),
    (Section: '2.2.5'; Name: 'class var: the upper bound takes =';
     Source: 'type TC = class class var F: False..1 = 1; end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(VarSec#class(' +
       'VarDecl(Ident''F''#name Subrange(Ident''False'' BinaryOp''=''(' +
       'IntLit''1'' IntLit''1'')))))))'; ExpectDiags: 0),
    (Section: '2.2.5'; Name: 'var section in a class: the upper bound takes =';
     Source: 'type TC = class var F: False..1 = 1; end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(VarSec''f''(' +
       'VarDecl(Ident''F''#name Subrange(Ident''False'' BinaryOp''=''(' +
       'IntLit''1'' IntLit''1'')))))))'; ExpectDiags: 0),
    // Under `packed` the bound takes `=` again: no initializer here (dcc
    // compiles both), and `packed array[0..1] of 0..31 = (3, 4)` is E2029.
    (Section: '2.2.5'; Name: 'packed array element: the upper bound takes =';
     Source: 'var V: packed array[0..1] of False..1 = 1;';
     Expected: 'VarSec''var''(VarDecl(Ident''V''#name ArrayType(Subrange(' +
       'IntLit''0'' IntLit''1'') Subrange(Ident''False'' BinaryOp''=''(' +
       'IntLit''1'' IntLit''1'')))))'; ExpectDiags: 0),
    (Section: '2.2.5'; Name: 'packed set: the upper bound takes =';
     Source: 'var V: packed set of False..1 = 1;';
     Expected: 'VarSec''var''(VarDecl(Ident''V''#name SetType(Subrange(' +
       'Ident''False'' BinaryOp''=''(IntLit''1'' IntLit''1'')))))';
     ExpectDiags: 0),
    (Section: '2.2.5'; Name: 'class constant: = ends the upper bound';
     Source: 'type TC = class const C: 0..31 = 5; end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(ConstSec''const''(' +
       'ConstDecl(Ident''C'' Subrange(IntLit''0'' IntLit''31'') ' +
       'IntLit''5'')))))'; ExpectDiags: 0),
    // A stray reserved word in MEMBER position used to consume nothing, so
    // the member loop spun until the fuel watchdog abandoned the rest of the
    // FILE. One error, one token, and the declarations after it survive.
    (Section: '11.1'; Name: 'a stray reserved word in member position does '
       + 'not eat the rest of the file';
     Source: 'type TR = record string end; TGood = class end;';
     Expected: 'TypeSec(TypeDecl(Ident''TR'' RecordType) ' +
       'TypeDecl(Ident''TGood'' ClassType))'; ExpectDiags: 1),
    // A parenthesised const EXPRESSION whose first inner token is '(' is not
    // a one-element aggregate - the shape LooksLikeAggregate's own header
    // names as the one to reject.
    (Section: '4.2'; Name: 'a parenthesised const expression is not an '
       + 'aggregate';
     Source: 'const C = ((1.0/2) / 3);';
     Expected: 'ConstSec''const''(ConstDecl(Ident''C'' Paren(BinaryOp''/''(' +
       'Paren(BinaryOp''/''(RealLit''1.0'' IntLit''2'')) IntLit''3''))))';
     ExpectDiags: 0),
    // 3.2 + 6.6: a typed procedural CONSTANT with its calling convention
    // between the type and the initializer (an image library's plugin unit
    // writes `exec: procedure(); cdecl = nil;`); dcc accepts the shape.
    (Section: '3.2'; Name: 'typed proc const carries a calling convention '
       + 'before the initializer';
     Source: 'const exec: procedure(); cdecl = nil;';
     Expected: 'ConstSec''const''(ConstDecl(Ident''exec'' ProcType(Params ' +
       'Directive''cdecl''#semi) NilLit))';
     ExpectDiags: 0),

    // ---- F19 (the parser-fidelity plan): where a name list ends. Each pair
    // holds the same identifiers, and dcc64 compiles both - only nfName on
    // the names tells them apart (3.1.1, 6.2.5, 6.2.7) ----
    (Section: '3.1.1'; Name: 'F19: two names and a type';
     Source: 'var P, T: C;';
     Expected: 'VarSec''var''(VarDecl(Ident''P''#name Ident''T''#name ' +
       'Ident''C''))'; ExpectDiags: 0),
    (Section: '3.1.2'; Name: 'F19: one name, a type and an initializer';
     Source: 'var P: T = C;';
     Expected: 'VarSec''var''(VarDecl(Ident''P''#name Ident''T'' ' +
       'Ident''C''))'; ExpectDiags: 0),
    (Section: '6.2.7'; Name: 'F19: two untyped const parameters';
     Source: 'procedure Q(const A, B);';
     Expected: 'Routine''procedure''(Ident''Q''#name Params(Param(' +
       'Ident''A''#name Ident''B''#name)))'; ExpectDiags: 0),
    (Section: '6.2.3'; Name: 'F19: one typed const parameter';
     Source: 'procedure Q(const A: B);';
     Expected: 'Routine''procedure''(Ident''Q''#name Params(Param(' +
       'Ident''A''#name Ident''B'')))'; ExpectDiags: 0),
    (Section: '6.2.1'; Name: 'F19: two parameters and a type';
     Source: 'procedure Q(A, T: X);';
     Expected: 'Routine''procedure''(Ident''Q''#name Params(Param(' +
       'Ident''A''#name Ident''T''#name Ident''X'')))'; ExpectDiags: 0),
    (Section: '6.2.5'; Name: 'F19: one parameter, a type and a default';
     Source: 'procedure Q(A: T = X);';
     Expected: 'Routine''procedure''(Ident''Q''#name Params(Param(' +
       'Ident''A''#name Ident''T'' Ident''X'')))'; ExpectDiags: 0),
    // Attribute groups between the names stay unmarked.
    (Section: '6.2.3'; Name: 'F19: attributes between the names';
     Source: 'procedure Q(const [Ref] A, [Ref] B: TGUID);';
     Expected: 'Routine''procedure''(Ident''Q''#name Params(Param(' +
       'AttrGroup(Attribute#ref(Ident''Ref'')) Ident''A''#name ' +
       'AttrGroup(Attribute#ref(Ident''Ref'')) Ident''B''#name ' +
       'Ident''TGUID'')))'; ExpectDiags: 0),
    // A method resolution clause: the interface and its method are the name
    // segments, the implementing method is not.
    (Section: '14.2.2'; Name: 'F19: method resolution segments';
     Source: 'type TC = class(TInterfacedObject, IFoo) ' +
       'function IFoo.M = Impl; end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(' +
       'Ident''TInterfacedObject'' Ident''IFoo'' MethodResolution(' +
       'Ident''IFoo''#name Ident''M''#name Ident''Impl''))))';
     ExpectDiags: 0),
    // Cut short after the dot while typing: a missing segment keeps TFoo a
    // qualifier - without it the header reads as a routine NAMED TFoo.
    (Section: '6.1.1'; Name: 'F19 recovery: a name cut short after the dot';
     Source: 'procedure TFoo.;';
     Expected: 'Routine''procedure''(Ident''TFoo''#name Missing#name)';
     ExpectDiags: 1),

    // ---- F1, F2, F10 (the parser-fidelity plan): every directive is an
    // nkDirective child. A procedural type's are written into it (before and
    // after `of object`) or, where it closes a declaration's type, after a
    // `;` - one run, started by a convention, far or near; the initializer
    // after it is the declaration's. A routine's may precede its header's
    // `;`. Every source dcc64 37.0 compiles, but the recovery rows (6.5.1,
    // 6.6.1) ----
    (Section: '6.6.1'; Name: 'F2: a convention after the type''s ;';
     Source: 'type TFn = function(A: Integer): Integer; stdcall;';
     Expected: 'TypeSec(TypeDecl(Ident''TFn'' ' +
       'ProcType(Params(Param(Ident''A''#name Ident''Integer'')) ' +
       'Ident''Integer'' Directive''stdcall''#semi)))';
     ExpectDiags: 0),
    (Section: '6.6.1'; Name: 'F2: a run of two after the ;';
     Source: 'var V: function(A: Integer): Integer; cdecl varargs;';
     Expected: 'VarSec''var''(VarDecl(Ident''V''#name ' +
       'ProcType(Params(Param(Ident''A''#name Ident''Integer'')) ' +
       'Ident''Integer'' Directive''cdecl''#semi Directive''varargs'')))';
     ExpectDiags: 0),
    (Section: '6.6.1'; Name: 'F2: before and after of object';
     Source: 'type T = procedure stdcall of object stdcall;';
     Expected: 'TypeSec(TypeDecl(Ident''T'' ' +
       'ProcType#ofobject(Directive''stdcall'' Directive''stdcall'')))';
     ExpectDiags: 0),
    // The last convention wins for dcc (cdecl here); the tree keeps both.
    (Section: '6.6.1'; Name: 'F2: written in and after the ;';
     Source: 'type T = procedure of object stdcall; cdecl;';
     Expected: 'TypeSec(TypeDecl(Ident''T'' ' +
       'ProcType#ofobject(Directive''stdcall'' Directive''cdecl''#semi)))';
     ExpectDiags: 0),
    (Section: '6.6.1'; Name: 'F2: reference to, written in';
     Source: 'type T = reference to procedure stdcall;';
     Expected: 'TypeSec(TypeDecl(Ident''T'' ' +
       'ProcType#reference(Directive''stdcall'')))';
     ExpectDiags: 0),
    // dcc: E2029 - `reference to` takes no run after its `;`.
    (Section: '6.6.1'; Name: 'F2 recovery: no run after reference to''s ;';
     Source: 'type T = reference to procedure; stdcall;';
     Expected: 'TypeSec(TypeDecl(Ident''T'' ProcType#reference) ' +
       'TypeDecl(Ident''stdcall'' Error))';
     ExpectDiags: 3),
    (Section: '3.1.2'; Name: 'F1: the initializer after the run';
     Source: 'var P: procedure; cdecl = nil;';
     Expected: 'VarSec''var''(VarDecl(Ident''P''#name ' +
       'ProcType(Directive''cdecl''#semi) NilLit))';
     ExpectDiags: 0),
    (Section: '3.1.2'; Name: 'F1: a routine as the initializer, then a var';
     Source: 'var V: procedure; cdecl = CP; W: Integer = 5;';
     Expected: 'VarSec''var''(VarDecl(Ident''V''#name ' +
       'ProcType(Directive''cdecl''#semi) Ident''CP'') ' +
       'VarDecl(Ident''W''#name Ident''Integer'' IntLit''5''))';
     ExpectDiags: 0),
    (Section: '3.1.2'; Name: 'F1: a hint after the initializer';
     Source: 'var V: procedure; cdecl = nil platform;';
     Expected: 'VarSec''var''(VarDecl(Ident''V''#name ' +
       'ProcType(Directive''cdecl''#semi) NilLit Directive''platform''))';
     ExpectDiags: 0),
    // dcc warns W1001 of T: the hint is the declaration's, not the type's.
    (Section: '6.6.1'; Name: 'F2: a hint after the type is the declaration''s';
     Source: 'type T = procedure library;';
     Expected: 'TypeSec(TypeDecl(Ident''T'' ProcType Directive''library''))';
     ExpectDiags: 0),
    (Section: '8.1'; Name: 'F2: an array''s procedural element takes the run';
     Source: 'var A: array[0..1] of procedure; stdcall;';
     Expected: 'VarSec''var''(VarDecl(Ident''A''#name ' +
       'ArrayType(Subrange(IntLit''0'' IntLit''1'') ' +
       'ProcType(Directive''stdcall''#semi))))';
     ExpectDiags: 0),
    (Section: '8.1'; Name: 'F2: a typed constant array, the run, the value';
     Source: 'const A: array[0..0] of procedure; cdecl = (CP);';
     Expected: 'ConstSec''const''(ConstDecl(Ident''A'' ' +
       'ArrayType(Subrange(IntLit''0'' IntLit''0'') ' +
       'ProcType(Directive''cdecl''#semi)) Paren(Ident''CP'')))';
     ExpectDiags: 0),
    (Section: '8.1'; Name: 'F2: under packed too';
     Source: 'var A: packed array[0..1] of procedure; stdcall;';
     Expected: 'VarSec''var''(VarDecl(Ident''A''#name ' +
       'ArrayType(Subrange(IntLit''0'' IntLit''1'') ' +
       'ProcType(Directive''stdcall''#semi))))';
     ExpectDiags: 0),
    (Section: '9.1.1'; Name: 'F2: the last field''s run before the end';
     Source: 'type R = record F: procedure; stdcall end;';
     Expected: 'TypeSec(TypeDecl(Ident''R'' RecordType(VarDecl(Ident''F''#name ' +
       'ProcType(Directive''stdcall''#semi)))))';
     ExpectDiags: 0),
    (Section: '9.1.1'; Name: 'F2: a field''s run, then a field';
     Source: 'type R = record F: procedure; stdcall; G: Integer; end;';
     Expected: 'TypeSec(TypeDecl(Ident''R'' RecordType(VarDecl(Ident''F''#name ' +
       'ProcType(Directive''stdcall''#semi)) VarDecl(Ident''G''#name ' +
       'Ident''Integer''))))';
     ExpectDiags: 0),
    (Section: '9.1.3'; Name: 'F2: a variant field''s run before the )';
     Source: 'type R = record case Integer of 0: (F: procedure; stdcall); 1: ' +
       '(G: Pointer); end;';
     Expected: 'TypeSec(TypeDecl(Ident''R'' ' +
       'RecordType(VariantPart(Ident''Integer'' ' +
       'VariantBranch(IntLit''0'' VarDecl(Ident''F''#name ' +
       'ProcType(Directive''stdcall''#semi))) VariantBranch(IntLit''1'' ' +
       'VarDecl(Ident''G''#name Ident''Pointer''))))))';
     ExpectDiags: 0),
    (Section: '11.2'; Name: 'F2: a class field''s run, then a method';
     Source: 'type TC = class F: procedure; stdcall; procedure M; end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(VarDecl(Ident''F''#name ' +
       'ProcType(Directive''stdcall''#semi)) ' +
       'Routine''procedure''(Ident''M''#name))))';
     ExpectDiags: 0),
    (Section: '11.2'; Name: 'F2: a class var''s run before the end';
     Source: 'type TC = class class var F: procedure; stdcall end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ' +
       'ClassType(VarSec#class(VarDecl(Ident''F''#name ' +
       'ProcType(Directive''stdcall''#semi))))))';
     ExpectDiags: 0),
    // A struct body's var section ends at the `end` like a field list.
    (Section: '11.2'; Name: 'a class var before the end, no ;';
     Source: 'type TC = class class var F: Integer end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ' +
       'ClassType(VarSec#class(VarDecl(Ident''F''#name ' +
       'Ident''Integer'')))))';
     ExpectDiags: 0),
    (Section: '9.1.1'; Name: 'a record var section before the end, no ;';
     Source: 'type R = record var F: Integer end;';
     Expected: 'TypeSec(TypeDecl(Ident''R'' ' +
       'RecordType(VarSec''f''(VarDecl(Ident''F''#name ' +
       'Ident''Integer'')))))';
     ExpectDiags: 0),
    // Only a convention, far or near starts a run: varargs names a var.
    (Section: '6.6.1'; Name: 'F2: varargs after the ; is the next var';
     Source: 'var V: procedure; varargs: Integer;';
     Expected: 'VarSec''var''(VarDecl(Ident''V''#name ProcType) ' +
       'VarDecl(Ident''varargs''#name Ident''Integer''))';
     ExpectDiags: 0),
    // One run: a second convention after its `;` names the next var.
    (Section: '6.6.1'; Name: 'F2: one run, then a var named cdecl';
     Source: 'var V: procedure; stdcall; cdecl: Integer;';
     Expected: 'VarSec''var''(VarDecl(Ident''V''#name ' +
       'ProcType(Directive''stdcall''#semi)) VarDecl(Ident''cdecl''#name ' +
       'Ident''Integer''))';
     ExpectDiags: 0),
    (Section: '6.6.1'; Name: 'F2: one run, then a type named stdcall';
     Source: 'type T = procedure; cdecl; stdcall = Integer;';
     Expected: 'TypeSec(TypeDecl(Ident''T'' ProcType(Directive''cdecl''#semi)) ' +
       'TypeDecl(Ident''stdcall'' Ident''Integer''))';
     ExpectDiags: 0),
    (Section: '3.2'; Name: 'F2: a constant named cdecl after a typed one';
     Source: 'const C: procedure = nil; cdecl = 5;';
     Expected: 'ConstSec''const''(ConstDecl(Ident''C'' ProcType NilLit) ' +
       'ConstDecl(Ident''cdecl'' IntLit''5''))';
     ExpectDiags: 0),
    // B.4.2: a directive word naming the next declaration starts no run.
    (Section: 'B.4.2'; Name: 'F2: Unsafe after a procedural type is a type';
     Source: 'type T = procedure; Unsafe = class end;';
     Expected: 'TypeSec(TypeDecl(Ident''T'' ProcType) TypeDecl(Ident''Unsafe'' ' +
       'ClassType))';
     ExpectDiags: 0),
    (Section: '6.5.1'; Name: 'F10: a convention before the header''s ;';
     Source: 'function F: Boolean stdcall;';
     Expected: 'Routine''function''(Ident''F''#name Ident''Boolean'' ' +
       'Directive''stdcall'')';
     ExpectDiags: 0),
    (Section: '6.5.1'; Name: 'F10: a run of two before the header''s ;';
     Source: 'function printf(Fmt: PAnsiChar): Integer cdecl varargs; external ' +
       '''msvcrt.dll'';';
     Expected: 'Routine''function''(Ident''printf''#name ' +
       'Params(Param(Ident''Fmt''#name Ident''PAnsiChar'')) ' +
       'Ident''Integer'' Directive''cdecl'' Directive''varargs'' ' +
       'Directive''external''(StrLit''''msvcrt.dll''''))';
     ExpectDiags: 0),
    (Section: '6.5.1'; Name: 'F10: a method''s convention before its ;';
     Source: 'type TC = class procedure M stdcall; end;';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ' +
       'ClassType(Routine''procedure''(Ident''M''#name ' +
       'Directive''stdcall''))))';
     ExpectDiags: 0),
    (Section: '6.5.1'; Name: 'F10: before the ; and after it';
     Source: 'procedure P(A: Integer) stdcall; overload;';
     Expected: 'Routine''procedure''(Ident''P''#name ' +
       'Params(Param(Ident''A''#name Ident''Integer'')) ' +
       'Directive''stdcall'' Directive''overload'')';
     ExpectDiags: 0),
    // dcc: E2029 - no run after a type that is not procedural; it was once
    // taken silently.
    (Section: '6.6.1'; Name: 'F2 recovery: no run after an Integer''s ;';
     Source: 'type T = Integer; stdcall;';
     Expected: 'TypeSec(TypeDecl(Ident''T'' Ident''Integer'') ' +
       'TypeDecl(Ident''stdcall'' Error))';
     ExpectDiags: 3),
    // The printer's canonical forms (parser fidelity S9): each spelling below
    // is one tree with the printer's, which T3 maps and T3r parses back.
    (Section: '19.3.2'; Name: 'S9: two bracket groups are one group';
     Source: 'type [A][B(1)] T = Integer;';
     Expected: 'TypeSec(TypeDecl(AttrGroup(Attribute(Ident''A'') ' +
       'Attribute(Ident''B'' IntLit''1'')) Ident''T'' Ident''Integer''))';
     ExpectDiags: 0),
    (Section: '11.1.1'; Name: 'S9: a class that stops at its ancestors';
     Source: 'type TC = class(TObject); TD = class(TC, IInterface);';
     Expected: 'TypeSec(TypeDecl(Ident''TC'' ClassType(Ident''TObject'')) ' +
       'TypeDecl(Ident''TD'' ClassType(Ident''TC'' Ident''IInterface'')))';
     ExpectDiags: 0),
    (Section: '3.2.2'; Name: 'S9: a record constant''s last value and ;';
     Source: 'const C: TR = (X: 1; Y: (A: 2;););';
     Expected: 'ConstSec''const''(ConstDecl(Ident''C'' Ident''TR'' ' +
       'Aggregate(AggregateField(Ident''X'' IntLit''1'') ' +
       'AggregateField(Ident''Y'' Aggregate(AggregateField(Ident''A'' ' +
       'IntLit''2''))))))';
     ExpectDiags: 0),
    (Section: '9.1'; Name: 'S9: a record''s alignment and hint after end';
     Source: 'type TR = packed record X: Integer end align 16 platform;';
     Expected: 'TypeSec(TypeDecl(Ident''TR'' RecordType(VarDecl(' +
       'Ident''X''#name Ident''Integer'') IntLit''16'' Directive''platform'')))';
     ExpectDiags: 0),
    (Section: '1.1.3'; Name: 'S9: exports with index, name and resident';
     Source: 'procedure P; exports P index 3 name ''Q'' resident, P;';
     Expected: 'Routine''procedure''(Ident''P''#name) ExportsClause(' +
       'ExportsItem(Ident''P'' IntLit''3'' StrLit''''Q'''') ' +
       'ExportsItem(Ident''P''))';
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

var
  { The verdict ParserSmoke passes RunSuite for every golden row (the tree
    checker, T3, T3r), applied to the trees the custom cases above parse
    themselves as well; nil in every other host. }
  GCustomTreeVerdict: TPasTreeVerdict;

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
          ApplyVerdict(Result, SNIPPET, GCustomTreeVerdict, LPre, LTree,
            True, Length(LDiags) = 0);
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
        ApplyVerdict(Result, SRC, GCustomTreeVerdict, LPre, LTree, False,
          Length(LDiags) = 0);
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
        ApplyVerdict(Result, SRC, GCustomTreeVerdict, LPre, LTree, False,
          Length(LDiags) = 0);
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
        ApplyVerdict(Result, SRC, GCustomTreeVerdict, LPre, LTree, False,
          Length(LDiags) = 0);
      end;
  end;

  { 6.10 + 1.3: an `asm` in a DEAD conditional branch must not leave the
    lexer in BASM mode for the live Pascal branch that shares the routine's
    `end` - the two-body routine shape of a fast-code library (an $IF on
    WIN32 around an asm body, an $ELSE with the Pascal body, one shared end).
    The lexer runs before the branch is decided; NoteDirective closes the asm
    at the $ELSE of the same conditional depth. A conditional INSIDE an asm
    body (deeper $ELSE) must keep the mode - the second routine checks that. }
  function DeadAsmBranchCase: TPasCustomCase;
  begin
    Result.Section := '6.10';
    Result.Name := 'dead asm branch does not swallow the live Pascal branch';
    Result.Run :=
      function: TPasCheckResult
      const
        SRC =
          'unit U;'#13#10'interface'#13#10'implementation'#13#10 +
          'function F: Integer;'#13#10'{$IFDEF NOPE_ASM}'#13#10 +
          'asm'#13#10'  mov eax, 1'#13#10'{$ELSE}'#13#10'const'#13#10 +
          '  K = 1;'#13#10'begin'#13#10'  Result := K;'#13#10'{$ENDIF}'#13#10 +
          'end;'#13#10 +
          'function G: Integer;'#13#10'asm'#13#10'{$IFDEF NOPE_ASM}'#13#10 +
          '  mov eax, 1'#13#10'{$ELSE}'#13#10'  mov eax, 2'#13#10 +
          '{$ENDIF}'#13#10'end;'#13#10 +
          'end.'#13#10;
      var
        LPre: TPasPreprocessed;
        LDiags: TArray<TPasParseDiag>;
        LTree: TPasTree;
      begin
        LPre := GPP.ProcessText('u.pas', SRC);
        LTree := TPasParser.ParseFile(LPre, LDiags);
        Result := CheckDump(SRC, 'Unit(Ident''U'' InterfaceSec ' +
          'ImplementationSec(Routine''function''(Ident''F''#name ' +
          'Ident''Integer'' RoutineBody(' +
          'ConstSec''const''(ConstDecl(Ident''K'' IntLit''1'')) ' +
          'Block(Assign(Ident''Result'' Ident''K'')))) ' +
          'Routine''function''(Ident''G''#name Ident''Integer'' ' +
          'RoutineBody(AsmStmt))))',
          LTree.Dump(0), LDiags, 0);
        ApplyVerdict(Result, SRC, GCustomTreeVerdict, LPre, LTree, False,
          Length(LDiags) = 0);
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
        ApplyVerdict(Result, SRC, GCustomTreeVerdict, LPre, LTree, False,
          Length(LDiags) = 0);
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
        Result := CheckDump(SRC, 'Routine''procedure''(Ident''Outer''#name ' +
          'RoutineBody(Routine''procedure''(Ident''Inner''#name RoutineBody(' +
          'Block)) Block(ExprStmt(Ident''Inner''))))', LTree.Dump(LOuter),
          LDiags, 0);
        ApplyVerdict(Result, SRC, GCustomTreeVerdict, LPre, LTree, False,
          Length(LDiags) = 0);
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
        Result := CheckDump(SRC, 'Routine''procedure''(Ident''P''#name ' +
          'RoutineBody(LabelSec ConstSec''const''(ConstDecl(Ident''K'' ' +
          'IntLit''1'')) TypeSec(TypeDecl(Ident''TLocal'' ' +
          'Ident''Integer'')) VarSec''var''(VarDecl(Ident''X''#name ' +
          'Ident''TLocal'')) Block(LabeledStmt(Assign(Ident''X'' ' +
          'Ident''K'')))))', LTree.Dump(LRoutine), LDiags, 0);
        ApplyVerdict(Result, SRC, GCustomTreeVerdict, LPre, LTree, False,
          Length(LDiags) = 0);
      end;
  end;

  { F19: a routine header's name segments carry nfName, and only they. The
    implementation section is the one place where `function A.B;` - the
    method B of class A, parameters and result type omitted (6.1.2) - and
    `function A: B;` hold the same two identifiers, and where a generic
    type's segment carries its parameters; CheckDecl (interface section only)
    cannot reach them. }
  function RoutineNamesCase: TPasCustomCase;
  begin
    Result.Section := '6.1.1';
    Result.Name := 'F19: routine name segments, not the result type';
    Result.Run :=
      function: TPasCheckResult
      const
        SRC =
          'unit U;'#13#10'interface'#13#10'implementation'#13#10 +
          'function A.B;'#13#10'begin'#13#10'end;'#13#10 +
          'function A: B;'#13#10'begin'#13#10'end;'#13#10 +
          'procedure TG<T>.P(X: T);'#13#10'begin'#13#10'end;'#13#10 +
          'end.'#13#10;
      var
        LPre: TPasPreprocessed;
        LDiags: TArray<TPasParseDiag>;
        LTree: TPasTree;
      begin
        LPre := GPP.ProcessText('u.pas', SRC);
        LTree := TPasParser.ParseFile(LPre, LDiags);
        Result := CheckDump(SRC, 'Unit(Ident''U'' InterfaceSec ' +
          'ImplementationSec(' +
          'Routine''function''(Ident''A''#name Ident''B''#name ' +
          'RoutineBody(Block)) ' +
          'Routine''function''(Ident''A''#name Ident''B'' ' +
          'RoutineBody(Block)) ' +
          'Routine''procedure''(Ident''TG''#name GenericParams(' +
          'GenericParam(Ident''T'')) Ident''P''#name Params(Param(' +
          'Ident''X''#name Ident''T'')) RoutineBody(Block))))',
          LTree.Dump(0), LDiags, 0);
        ApplyVerdict(Result, SRC, GCustomTreeVerdict, LPre, LTree, False,
          Length(LDiags) = 0);
      end;
  end;

var
  LPlatform: TPasPlatform;
begin
  Result := [];
  Result := Result + [ProgramFileCase, UnitFileCase, DeadAsmBranchCase,
    NestedRoutineCase,
    FullBlockCase, RoutineNamesCase];
  for LPlatform := Low(TPasPlatform) to High(TPasPlatform) do
    Result := Result + [PlatformCase(LPlatform)];
  Result := Result + [IncludeContextCase];
  AddMultilineIndentCases(Result);
  Result := Result + [OutParamAuxCase, PackageHeadTokensCase];
end;


end.
