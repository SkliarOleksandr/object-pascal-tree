program ParserSmoke;

{
  PasTree parser golden tests. Each case is named by the spec feature it
  covers (object-pascal-spec numbering), runs the full pipeline
  text -> lex -> preprocess -> parse(statements) -> dump, and asserts the
  exact S-expression dump.
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas';

var
  GSM: TPasSourceManager;
  GDefines: TPasDefines;
  GPP: TPasPreprocessor;
  GPassed, GFailed: Integer;

procedure Check(const AName, ASource, AExpected: string;
  AExpectDiags: Integer = 0);
var
  LPre: TPasPreprocessed;
  LDiags: TArray<TPasParseDiag>;
  LTree: TPasTree;
  LActual: string;
  LIdx: Integer;
begin
  LPre := GPP.ProcessText('test.pas', ASource);
  LTree := TPasParser.ParseStatements(LPre, LDiags);
  LActual := LTree.Dump(0);
  if (LActual = AExpected) and (Length(LDiags) = AExpectDiags) then
  begin
    Inc(GPassed);
    Exit;
  end;
  Inc(GFailed);
  Writeln('FAIL ', AName);
  Writeln('  source:   ', ASource);
  Writeln('  expected: ', AExpected);
  Writeln('  actual:   ', LActual);
  if Length(LDiags) <> AExpectDiags then
  begin
    Writeln('  diags (expected ', AExpectDiags, '):');
    for LIdx := 0 to High(LDiags) do
      Writeln('    @', LDiags[LIdx].VisIndex, ': ', LDiags[LIdx].Msg);
  end;
end;

begin
  GSM := TPasSourceManager.Create([]);
  GDefines := TPasDefines.Create(['MSWINDOWS', 'WIN64']);
  GPP := TPasPreprocessor.Create(GSM, GDefines);
  GPassed := 0;
  GFailed := 0;
  try
    // ---- 5.1.1 assignment ----
    Check('5.1.1 assign', 'X := 42;',
      'Block(Assign(Ident''X'' IntLit''42''))');
    Check('5.1.1 member assign', 'Edit1.Text := S;',
      'Block(Assign(Member(Ident''Edit1'' Ident''Text'') Ident''S''))');
    Check('5.1.1 deref assign', 'P^.Value := 1;',
      'Block(Assign(Member(Deref(Ident''P'') Ident''Value'') IntLit''1''))');

    // ---- 5.1.2 call statement ----
    Check('5.1.2 call', 'DoWork(Input, 10);',
      'Block(ExprStmt(Call(Ident''DoWork'' Ident''Input'' IntLit''10'')))');
    Check('5.1.2 bare call', 'Application.Run;',
      'Block(ExprStmt(Member(Ident''Application'' Ident''Run'')))');

    // ---- 4.x expressions & precedence ----
    Check('4.2 precedence', 'X := A + B * C;',
      'Block(Assign(Ident''X'' BinaryOp''+''(Ident''A'' ' +
      'BinaryOp''*''(Ident''B'' Ident''C''))))');
    Check('4.3 bool vs rel', 'B := (A > 0) and (C > 0);',
      'Block(Assign(Ident''B'' BinaryOp''and''(Paren(BinaryOp''>''(' +
      'Ident''A'' IntLit''0'')) Paren(BinaryOp''>''(Ident''C'' ' +
      'IntLit''0'')))))');
    Check('4.8 address-of', 'P := @X;',
      'Block(Assign(Ident''P'' UnaryOp''@''(Ident''X'')))');
    Check('4.8 double address-of', 'P := @@Hook;',
      'Block(Assign(Ident''P'' UnaryOp''@''(UnaryOp''@''(Ident''Hook''))))');
    Check('4.9 is/as', 'if Obj is TButton then B := Obj as TButton;',
      'Block(IfStmt(BinaryOp''is''(Ident''Obj'' Ident''TButton'') ' +
      'Assign(Ident''B'' BinaryOp''as''(Ident''Obj'' Ident''TButton''))))');
    Check('4.9.1 is not', 'if Obj is not TButton then Exit;',
      'Block(IfStmt(BinaryOp''is''!(Ident''Obj'' Ident''TButton'') ' +
      'ExprStmt(Ident''Exit'')))');
    Check('4.9.1 not in', 'if C not in S then Exit;',
      'Block(IfStmt(BinaryOp''in''!(Ident''C'' Ident''S'') ' +
      'ExprStmt(Ident''Exit'')))');
    Check('4.10 cast-or-call', 'B := Byte(I);',
      'Block(Assign(Ident''B'' Call(Ident''Byte'' Ident''I'')))');
    Check('4.10 string cast', 'S := string(P);',
      'Block(Assign(Ident''S'' Call(Ident''string'' Ident''P'')))');
    Check('4.11.2 formatted args', 'Str(Val:0, S);',
      'Block(ExprStmt(Call(Ident''Str'' FormattedArg(Ident''Val'' ' +
      'IntLit''0'') Ident''S'')))');
    Check('B.6.1 string concat', 'S := ''Hi''#13#10;',
      'Block(Assign(Ident''S'' StrLit''''Hi''''))');
    Check('B.6.2 caret char', 'C := ^M;',
      'Block(Assign(Ident''C'' CaretChar''^''))');
    Check('B.9 set ctor', 'if C in [''a''..''z'', ''0''] then;',
      'Block(IfStmt(BinaryOp''in''(Ident''C'' SetCtor(Range(' +
      'StrLit''''a'''' StrLit''''z'''') StrLit''''0'''')) ' +
      'EmptyStmt))');

    // ---- 16.3 generic args in expressions ----
    Check('16.3 generic call', 'L := TList<Integer>.Create;',
      'Block(Assign(Ident''L'' Member(TypeArgs(Ident''TList'' ' +
      'Ident''Integer'') Ident''Create'')))');
    Check('16.3 less-than stays', 'B := A < C;',
      'Block(Assign(Ident''B'' BinaryOp''<''(Ident''A'' Ident''C'')))');

    // ---- 5.3.1 if / dangling else ----
    Check('5.3.1 dangling else',
      'if A then if B then X := 1 else X := 2;',
      'Block(IfStmt(Ident''A'' IfStmt(Ident''B'' Assign(Ident''X'' ' +
      'IntLit''1'') Assign(Ident''X'' IntLit''2''))))');

    // ---- 5.3.2 case ----
    Check('5.3.2 case',
      'case K of 1, 2: X := 1; 3..5: X := 2 else X := 3; end;',
      'Block(CaseStmt(Ident''K'' CaseSel(CaseLabels(IntLit''1'' ' +
      'IntLit''2'') Assign(Ident''X'' IntLit''1'')) CaseSel(CaseLabels(' +
      'Range(IntLit''3'' IntLit''5'')) Assign(Ident''X'' IntLit''2'')) ' +
      'Block(Assign(Ident''X'' IntLit''3''))))');

    // ---- 5.4.1 inline if ----
    Check('5.4.1 inline if', 'Max := if A > B then A else B;',
      'Block(Assign(Ident''Max'' InlineIf(BinaryOp''>''(Ident''A'' ' +
      'Ident''B'') Ident''A'' Ident''B'')))');

    // ---- 5.5 loops ----
    Check('5.5.1 for-to', 'for I := 1 to 10 do Sum := Sum + I;',
      'Block(ForStmt(Ident''I'' IntLit''1'' IntLit''10'' Assign(' +
      'Ident''Sum'' BinaryOp''+''(Ident''Sum'' Ident''I''))))');
    Check('5.5.1 inline counter', 'for var J := 1 to 2 do;',
      'Block(ForStmt(InlineVar(Ident''J'') IntLit''1'' IntLit''2'' ' +
      'EmptyStmt))');
    Check('5.5.2 for-in', 'for Item in MyList do Process(Item);',
      'Block(ForInStmt(Ident''Item'' Ident''MyList'' ExprStmt(Call(' +
      'Ident''Process'' Ident''Item''))))');
    Check('5.5.3 while', 'while not Done do Step;',
      'Block(WhileStmt(UnaryOp''not''(Ident''Done'') ExprStmt(' +
      'Ident''Step'')))');
    Check('5.5.4 repeat', 'repeat Step until Done;',
      'Block(RepeatStmt(Block(ExprStmt(Ident''Step'')) Ident''Done''))');

    // ---- 5.7 with ----
    Check('5.7 with', 'with A, B do X := 1;',
      'Block(WithStmt(Ident''A'' Ident''B'' Assign(Ident''X'' ' +
      'IntLit''1'')))');

    // ---- 3.1.3 inline vars ----
    Check('3.1.3 inline var', 'var Name := Edit1.Text;',
      'Block(InlineVar(Ident''Name'' Member(Ident''Edit1'' ' +
      'Ident''Text'')))');
    Check('3.1.3 typed inline var', 'var I: Integer := 0;',
      'Block(InlineVar(Ident''I'' Ident''Integer'' IntLit''0''))');

    // ---- 18.x exceptions ----
    Check('18.2.1 try-finally', 'try Use finally Obj.Free end;',
      'Block(TryStmt(Block(ExprStmt(Ident''Use'')) FinallyPart(Block(' +
      'ExprStmt(Member(Ident''Obj'' Ident''Free''))))))');
    Check('18.1.2 on-do',
      'try P except on E: EFoo do Log(E); else raise; end;',
      'Block(TryStmt(Block(ExprStmt(Ident''P'')) ExceptPart(ExceptOn(' +
      'Ident''E'' Ident''EFoo'' ExprStmt(Call(Ident''Log'' Ident''E''))) ' +
      'Block(RaiseStmt))))');
    Check('18.3.1 raise at', 'raise E at Addr;',
      'Block(RaiseStmt(Ident''E'' Ident''Addr''))');

    // ---- 12.1.2 inherited ----
    Check('12.1.2 inherited bare', 'inherited;',
      'Block(ExprStmt(Inherited))');
    Check('12.1.2 inherited named', 'inherited Create(X);',
      'Block(ExprStmt(Inherited(Call(Ident''Create'' Ident''X''))))');

    // ---- 1.3.2 conditional compilation in statements ----
    Check('1.3.2 ifdef', '{$IFDEF MSWINDOWS}A := 1;{$ELSE}A := 2;{$ENDIF}',
      'Block(Assign(Ident''A'' IntLit''1''))');

    Writeln;
    Writeln(Format('=== ParserSmoke: %d passed, %d failed ===',
      [GPassed, GFailed]));
    if GFailed > 0 then
      ExitCode := 1;
  finally
    GPP.Free;
    GDefines.Free;
    GSM.Free;
  end;
end.
