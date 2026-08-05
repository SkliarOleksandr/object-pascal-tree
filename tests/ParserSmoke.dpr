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
  System.IOUtils,
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

{ Lexer-level check: the LINES on which ASource produces ACode, as a
  comma-separated list, so a case reads the way dcc's own output does. Used for
  the multiline-string indentation rule (B.6.3), whose diagnostics never reach
  the parser. }
procedure CheckLexDiagLines(const AName, ASource: string;
  ACode: TPasDiagCode; const AExpected: string);
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
      LStream.OffsetToLineCol(LStream.Diagnostics[LIdx].Start, LLine, LCol);
      if LActual <> '' then
        LActual := LActual + ',';
      LActual := LActual + IntToStr(LLine);
    end;
  if LActual = AExpected then
    Inc(GPassed)
  else
  begin
    Inc(GFailed);
    Writeln('FAIL ', AName);
    Writeln('  expected lines: "', AExpected, '"');
    Writeln('  actual lines:   "', LActual, '"');
  end;
end;

{ B.6.3 indentation, every shape dcc32 37.0 was probed with. The rule compares
  the closing run's indent CHARACTER BY CHARACTER against each content line: a
  mismatch is the error, running out of line is not. Line numbers are 1-based
  and the sources start with a `const` line, so content starts at line 3. }
procedure CheckMultilineIndent;
const
  // One apostrophe, so a quote RUN can be composed instead of spelled — an
  // eight-apostrophe literal is unreadable and was wrong the first time.
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
  // A tab where the closer has spaces — the same WIDTH is not the rule.
  LTab := 'const A =' + NL + '    ' + R3 + NL + #9'tabbed' + NL +
    '    ' + R3 + ';';
  // Whitespace-only lines: empty, and shorter than the closer. Both legal.
  LBlank := 'const A =' + NL + '    ' + R3 + NL + NL + '  ' + NL +
    '    ok' + NL + '    ' + R3 + ';';
  // A tab-only line, though, mismatches on its first character.
  LTabBlank := 'const A =' + NL + '    ' + R3 + NL + #9 + NL + '    ok' + NL +
    '    ' + R3 + ';';
  // Two offenders: one report each, not one per literal.
  LTwo := 'const A =' + NL + '    ' + R3 + NL + '  one' + NL + '  two' + NL +
    '    ' + R3 + ';';
  // A closer at column 1 imposes nothing.
  LFlush := 'const A =' + NL + R3 + NL + 'anything' + NL + R3 + ';';
  // The same rule inside a longer odd run.
  LFive := 'const A =' + NL + '    ' + R5 + NL + '  bad' + NL +
    '    ' + R5 + ';';
  CheckLexDiagLines('B.6.3 under-indented content line', LUnder,
    dcInconsistentIndentChars, '3');
  CheckLexDiagLines('B.6.3 deeper than the closer is fine', LOver,
    dcInconsistentIndentChars, '');
  CheckLexDiagLines('B.6.3 a tab where the closer has spaces', LTab,
    dcInconsistentIndentChars, '3');
  CheckLexDiagLines('B.6.3 empty and short whitespace-only lines are fine',
    LBlank, dcInconsistentIndentChars, '');
  CheckLexDiagLines('B.6.3 ...but a tab-only line still mismatches',
    LTabBlank, dcInconsistentIndentChars, '3');
  CheckLexDiagLines('B.6.3 one report per offending line', LTwo,
    dcInconsistentIndentChars, '3,4');
  CheckLexDiagLines('B.6.3 a closer at column 1 imposes nothing', LFlush,
    dcInconsistentIndentChars, '');
  CheckLexDiagLines('B.6.3 the rule holds for a five-quote run', LFive,
    dcInconsistentIndentChars, '3');
end;

{ A parameter's `out` is recorded on its nkParam as a visible-token index
  (nkParam.Aux), because `out` is a DIRECTIVE word: legal as an identifier
  elsewhere, so nothing but the parser can prove that this one is the modifier.
  The demo's highlighter reads exactly this to colour it, which is why the check
  asserts the token TEXT and not merely that Aux moved. }
procedure CheckOutParamAux;
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
    if (LTree.Nodes[LIdx].Kind = nkParam) and (LTree.Nodes[LIdx].Aux >= 0) then
    begin
      Inc(LMarked);
      if not SameText(LPre.VisibleText(LTree.Nodes[LIdx].Aux), 'out') then
        Inc(LWrongText);
    end;
  // Two `out` parameters across P1 and P2; P3 has none and P4's `out` is the
  // parameter's NAME.
  if (LMarked = 2) and (LWrongText = 0) and (Length(LDiags) = 0) then
    Inc(GPassed)
  else
  begin
    Inc(GFailed);
    Writeln('FAIL 6.2 out-parameter Aux');
    Writeln('  marked: ', LMarked, ' (expected 2), wrong text: ', LWrongText,
      ', parse diags: ', Length(LDiags));
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

{ An include that lives in ANOTHER directory and DEFINES a symbol, guarding a
  declaration. JclBase.pas's shape exactly: it includes jcl.inc, which sits in
  source/include rather than beside the unit, and which (through jedi.inc)
  defines CPU32 -- the symbol guarding SizeInt = Integer.

  Both halves of the context matter, and the test pins both: with NO search path
  the include cannot resolve and the guarded region is reported SKIPPED — which
  is what made the demo's highlighter grey out a line its own navigation had
  just jumped to. With the search path supplied, the region is live.

  The file NAME matters too: an include is resolved relative to the including
  file, so preprocessing real content under a placeholder name loses even an
  include sitting right beside it. }
procedure CheckIncludeContext;
var
  LDir, LSub: string;
  LSM: TPasSourceManager;
  LDefines: TPasDefines;
  LPP: TPasPreprocessor;
  LPre: TPasPreprocessed;
  LUnitPath: string;
  LSkippedWith, LSkippedWithout: Boolean;

  // True when the GUARDED line ('SizeInt = Integer') fell in a skipped region.
  function GuardSkipped(const APaths: TArray<string>;
    const AName: string): Boolean;
  var
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
    TFile.WriteAllText(TPath.Combine(LSub, 'cfg.inc'), '{$DEFINE MYCPU32}'#10);
    LUnitPath := TPath.Combine(LDir, 'U.pas');
    TFile.WriteAllText(LUnitPath,
      'unit U;'#10 +
      '{$I cfg.inc}'#10 +          // NOT next to U.pas: needs the search path
      'interface'#10 +
      'type'#10 +
      '{$IFDEF MYCPU32}'#10 +
      '  SizeInt = Integer;'#10 +
      '{$ENDIF}'#10 +
      'implementation'#10 +
      'end.'#10);

    LSkippedWithout := GuardSkipped([], 'buffer.pas');
    LSkippedWith := GuardSkipped([LSub], LUnitPath);

    if LSkippedWithout and not LSkippedWith then
      Inc(GPassed)
    else
    begin
      Inc(GFailed);
      Writeln('FAIL include context drives inactive regions');
      Writeln('  expected: skipped without context, live with it');
      Writeln(Format('  actual:   without=%s with=%s',
        [BoolToStr(LSkippedWithout, True), BoolToStr(LSkippedWith, True)]));
    end;
  finally
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
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
    // A Variant's INDEXED property takes them too (dcc-verified) — the bracket
    // loop needed the same rule, and was still a false E2003 without it.
    Check('4.10.1 named argument in an index',
      'V.Range[Source := 1] := 5;',
      'Block(Assign(Index(Member(Ident''V'' Ident''Range'') ' +
      'NamedArg(Ident''Source'' IntLit''1'')) IntLit''5''))');
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
    CheckIncludeContext;
    CheckMultilineIndent;
    CheckOutParamAux;

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
