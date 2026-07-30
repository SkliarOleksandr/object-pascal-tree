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
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
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

procedure CheckAllPlatforms;
const
  SNIPPET =
    '{$IFDEF MSWINDOWS}W := 1;{$ENDIF}' +
    '{$IFDEF POSIX}P := 1;{$ENDIF}' +
    '{$IF SizeOf(Pointer) = 8}B := 64{$ELSE}B := 32{$ENDIF};';
var
  LPlatform: TPasPlatform;
  LInfo: TPasPlatformInfo;
  LDefines: TPasDefines;
  LPP: TPasPreprocessor;
  LPre: TPasPreprocessed;
  LDiags: TArray<TPasParseDiag>;
  LTree: TPasTree;
  LActual, LExpected: string;
begin
  for LPlatform := Low(TPasPlatform) to High(TPasPlatform) do
  begin
    LInfo := PlatformInfo(LPlatform);
    LDefines := CreatePlatformDefines(LPlatform);
    LPP := TPasPreprocessor.Create(GSM, LDefines, 37.0,
      LInfo.PointerBytes, LInfo.ExtendedBytes);
    try
      LPre := LPP.ProcessText('test.pas', SNIPPET);
      LTree := TPasParser.ParseStatements(LPre, LDiags);
      LActual := LTree.Dump(0);
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
      if (LActual = LExpected) and (Length(LDiags) = 0) then
        Inc(GPassed)
      else
      begin
        Inc(GFailed);
        Writeln('FAIL platform ', LInfo.Name);
        Writeln('  expected: ', LExpected);
        Writeln('  actual:   ', LActual);
      end;
    finally
      LPP.Free;
      LDefines.Free;
    end;
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
    // 4.10.1 OLE-automation NAMED ARGUMENTS. Without the nkNamedArg wrap the
    // argument list ended at the name and ':=' turned the whole call into an
    // assignment TARGET — two parse diags and a false E2003 on the name.
    Check('4.10.1 named argument',
      'Charts.Add(Source := R, Gap := 1);',
      'Block(ExprStmt(Call(Member(Ident''Charts'' Ident''Add'') ' +
      'NamedArg(Ident''Source'' Ident''R'') ' +
      'NamedArg(Ident''Gap'' IntLit''1''))))');
    // Only a bare identifier makes a named argument; anything else stays the
    // syntax error it always was (an assignment is not an expression).
    Check('4.10.1 named argument needs a bare name',
      'Charts.Add(A.B := R);',
      'Block(Assign(Call(Member(Ident''Charts'' Ident''Add'') ' +
      'Member(Ident''A'' Ident''B'')) Ident''R''))', 2);

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

    // ---- 5.6.4 goto / labels ----
    // An IDENTIFIER label is a reference to a `label`-section declaration, so
    // it gets its own Ident node the resolver can bind (without it the
    // labeled statement's name was the only node, and it resolved to nothing:
    // false E2003 on System.Generics.Defaults). A NUMERIC label declares no
    // name at all and stays a bare token in both positions.
    Check('5.6.4 goto ident label', 'goto Done;',
      'Block(GotoStmt(Ident''Done''))');
    Check('5.6.4 labeled stmt + goto', 'Again: Step; goto Again;',
      'Block(LabeledStmt(Ident''Again'' ExprStmt(Ident''Step'')) ' +
      'GotoStmt(Ident''Again''))');
    Check('5.6.4 numeric label declares no ident node', '1: goto 2;',
      'Block(LabeledStmt(GotoStmt))');

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

    // ---- platform presets: iterate ALL target platforms and verify the
    // define set + SizeOf(Pointer) drive branch selection correctly ----
    CheckAllPlatforms;

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
