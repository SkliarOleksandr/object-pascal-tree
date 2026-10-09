program ParserSmoke;

{
  PasTree parser golden tests. The cases themselves live as DATA in
  PasTree.Tests.Parser (STMT_CASES, DECL_CASES, BuildCustomCases) --
  test-coverage plan step 2+5. This host just wires a preprocessor and runs
  them through PasTree.TestKit, the same shared runner every suite that
  migrates onto this mechanism will use.

  Every STMT/DECL row's tree also goes through the tree checker
  (PasTree.Ast.Check): the invariants I1-I4 and I6, I5 (the own-token table)
  and I8 when the row parses clean, and I7 - a second parse must build the
  same arena, and for a DECL row the interface-only parse must be a prefix of
  the full one. A clean row is also printed from its tree (PasTree.Printer):
  T3, the print against the row's tokens, and T3r, the print parsed back in
  two layouts. A violation fails the row, whatever its dump says. The custom
  cases that parse a tree of their own (BuildCustomCases: whole units,
  programs, packages, every platform's define set) get the same verdict
  through GCustomTreeVerdict. BuildOwnTokenCases holds the table itself to
  account: it parses, and I5 fails on trees built by hand to break it.
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.StrUtils,
  System.Classes,
  System.IOUtils,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Dcu in '..\source\PasTree.Dcu.pas',
  PasTree.Dcu.Source in '..\source\PasTree.Dcu.Source.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Ast.Json in '..\source\PasTree.Ast.Json.pas',
  PasTree.Ast.Check in '..\source\PasTree.Ast.Check.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.Printer in '..\source\PasTree.Printer.pas',
  PasTree.TestKit in 'PasTree.TestKit.pas',
  PasTree.Tests.Parser in 'PasTree.Tests.Parser.pas',
  PasTree.Tests.Roundtrip in 'PasTree.Tests.Roundtrip.pas',
  PasTree.Tests.Preprocessor in 'PasTree.Tests.Preprocessor.pas';

var
  // The preprocessor the rows are parsed with - T3r parses a print back with
  // it.
  GVerdictPP: TPasPreprocessor;

// T3 and T3r (PasTree.Printer) over a clean row: the structural print matches
// the row's tokens (a filed loss read in place) and parses back in both
// layouts to the same tree. '' when both hold.
function PrintVerdict(const ATree: TPasTree; AStatements: Boolean): string;
var
  LT3: TPasT3Result;
  LIdx: Integer;
  LMsg: string;
begin
  Result := '';
  if not CompareT3(ATree, 0, LT3) then
    for LIdx := 0 to High(LT3.Sites) do
      if LT3.Sites[LIdx].Finding = '' then
        Result := Result + '    ' +
          VisSiteText(ATree.Source, LT3.Sites[LIdx].Vis) + ': T3: ' +
          LT3.Sites[LIdx].Msg + sLineBreak;
  if not CheckT3r(ATree,
    function(const AText: string; out ABack: TPasTree; out ADiags,
      ADiagVis: Integer; out AFirstDiag: string): Boolean
    var
      LPre: TPasPreprocessed;
      LDiags: TArray<TPasParseDiag>;
    begin
      LPre := GVerdictPP.ProcessText('print.pas', AText);
      if AStatements then
        ABack := TPasParser.ParseStatements(LPre, LDiags)
      else
        ABack := TPasParser.ParseFile(LPre, LDiags);
      ADiags := Length(LDiags);
      ADiagVis := -1;
      AFirstDiag := '';
      if ADiags > 0 then
      begin
        ADiagVis := LDiags[0].VisIndex;
        AFirstDiag := LDiags[0].Msg;
      end;
      Result := True;
    end, LMsg) then
    Result := Result + '    T3r: ' + LMsg + sLineBreak;
end;

function TreeVerdict(const APre: TPasPreprocessed; const ATree: TPasTree;
  AStatements, AValid: Boolean): string;
var
  LReport: TPasCheckReport;
  LDiags: TArray<TPasParseDiag>;
  LLines: TArray<string>;
  LIdx: Integer;
begin
  LReport.Init;
  CheckTree(ATree, AValid, LReport);
  if AStatements then
    CompareTrees(ATree, TPasParser.ParseStatements(APre, LDiags), LReport)
  else
  begin
    CompareTrees(ATree, TPasParser.ParseFile(APre, LDiags), LReport);
    CheckInterfacePrefix(TPasParser.ParseFile(APre, LDiags, True), ATree,
      LReport);
  end;
  Result := '';
  LLines := CheckReportText(ATree, LReport).Split([sLineBreak],
    TStringSplitOptions.ExcludeEmpty);
  for LIdx := 0 to High(LLines) do
    Result := Result + '    ' + LLines[LIdx] + sLineBreak;
  if AValid then
    Result := Result + PrintVerdict(ATree, AStatements);
end;

type
  TNodeSpec = record
    Kind: TPasNodeKind;
    First, Last, Parent: Integer;
  end;

function N(AKind: TPasNodeKind; AFirst, ALast, AParent: Integer): TNodeSpec;
begin
  Result.Kind := AKind;
  Result.First := AFirst;
  Result.Last := ALast;
  Result.Parent := AParent;
end;

// A tree over ASource's visible tokens: each node in order, Parent an index
// into the nodes before it.
function HandTree(APP: TPasPreprocessor; const ASource: string;
  const ANodes: array of TNodeSpec): TPasTree;
var
  LB: TPasTreeBuilder;
  LSpec: TNodeSpec;
begin
  LB.Init;
  for LSpec in ANodes do
    LB.SetLast(LB.AddNode(LSpec.Kind, LSpec.Parent, LSpec.First), LSpec.Last);
  Result := LB.Build(APP.ProcessText('test.pas', ASource));
end;

// Passes when checking ATree as valid code reports exactly AOwn I5.own
// violations, AUnlisted of them for tokens no rule covers, and nothing else.
function JudgeOwn(const ATree: TPasTree; AOwn, AUnlisted: Integer;
  const AWhat: string): TPasCheckResult;
var
  LReport: TPasCheckReport;
begin
  LReport.Init;
  CheckTree(ATree, True, LReport);
  Result.Passed := (LReport.Counts[ccOwn] = AOwn) and
    (LReport.OwnUnlisted = AUnlisted) and (LReport.Total = AOwn);
  Result.Message := '';
  if not Result.Passed then
    Result.Message := Format('  %s: expected %d I5.own (%d unlisted) and ' +
      'nothing else, got %d I5.own (%d unlisted) of %d:', [AWhat, AOwn,
      AUnlisted, LReport.Counts[ccOwn], LReport.OwnUnlisted,
      LReport.Total]) + sLineBreak + CheckReportText(ATree, LReport);
end;

function OwnCase(const AName: string;
  const ARun: TFunc<TPasCheckResult>): TPasCustomCase;
begin
  Result.Section := 'I5';
  Result.Name := AName;
  Result.Run := ARun;
end;

// Passes when ADecl, parsed as a unit's interface, is valid, checks clean,
// and the own-token rules of AFinding classify exactly ATally tokens - the
// first of them the token ASite, when given.
function LossCase(APP: TPasPreprocessor; const ADecl, AFinding: string;
  ATally: Integer; const ASite: string): TPasCheckResult;
var
  LPre: TPasPreprocessed;
  LDiags: TArray<TPasParseDiag>;
  LTree: TPasTree;
  LReport: TPasCheckReport;
  LRule, LTally, LFirst: Integer;
begin
  // A whole program (F17's finding lives in the head), else a declaration.
  if ADecl.StartsWith('program ') then
    LPre := APP.ProcessText('test.pas', ADecl)
  else
    LPre := APP.ProcessText('test.pas', DeclCaseText(ADecl));
  LTree := TPasParser.ParseFile(LPre, LDiags);
  LReport.Init;
  CheckTree(LTree, Length(LDiags) = 0, LReport);
  LTally := 0;
  LFirst := MaxInt;
  for LRule := 0 to OwnRuleCount - 1 do
    if (OwnRule(LRule).Finding = AFinding) and
       (LReport.OwnCounts[LRule] > 0) then
    begin
      Inc(LTally, LReport.OwnCounts[LRule]);
      if LReport.OwnSites[LRule] < LFirst then
        LFirst := LReport.OwnSites[LRule];
    end;
  Result.Passed := (Length(LDiags) = 0) and (LReport.Total = 0) and
    (LTally = ATally) and ((ASite = '') or
     ((LFirst <> MaxInt) and SameText(LPre.VisibleText(LFirst), ASite)));
  Result.Message := '';
  if not Result.Passed then
    Result.Message := Format('  %s: %d diagnostics, %d violations, %s tally ' +
      '%d (%d expected, first on %s)', [ADecl, Length(LDiags), LReport.Total,
      AFinding, LTally, ATally, ASite]) + sLineBreak +
      CheckReportText(LTree, LReport);
end;

{ I5 must be able to fail, and the table must hold: the table parses; trees
  built by hand, over real tokens, break it on purpose - a token no rule
  covers, a once-token owned twice - and the checker says so; a fixed
  finding counts no loss. }
function BuildOwnTokenCases(APP: TPasPreprocessor): TPasCustomCases;
begin
  Result := [
    OwnCase('the own-token table parses',
      function: TPasCheckResult
      begin
        Result.Passed := OwnRuleTableErrors = '';
        Result.Message := OwnRuleTableErrors;
      end),
    // `if C then X` read with a hand-built tree: tokens if C then X <eof>.
    OwnCase('a hand tree the table accepts',
      function: TPasCheckResult
      begin
        Result := JudgeOwn(HandTree(APP, 'if C then X', [N(nkBlock, 0, 4, -1),
          N(nkIfStmt, 0, 3, 0), N(nkIdent, 1, 1, 1), N(nkExprStmt, 3, 3, 1),
          N(nkIdent, 3, 3, 3)]), 0, 0, 'IfStmt over if C then X');
      end),
    // The same tokens under a WhileStmt: `if` and `then` have no rule there
    // (2 unlisted), and `while` and `do`, once each, are missing (2 more).
    OwnCase('a token no rule covers is a violation',
      function: TPasCheckResult
      begin
        Result := JudgeOwn(HandTree(APP, 'if C then X', [N(nkBlock, 0, 4, -1),
          N(nkWhileStmt, 0, 3, 0), N(nkIdent, 1, 1, 1),
          N(nkExprStmt, 3, 3, 1), N(nkIdent, 3, 3, 3)]), 4, 2,
          'WhileStmt over if C then X');
      end),
    // `if C then then X`: one IfStmt owning both `then`.
    OwnCase('a once-token owned twice is a violation',
      function: TPasCheckResult
      begin
        Result := JudgeOwn(HandTree(APP, 'if C then then X', [
          N(nkBlock, 0, 5, -1), N(nkIfStmt, 0, 4, 0), N(nkIdent, 1, 1, 1),
          N(nkExprStmt, 4, 4, 1), N(nkIdent, 4, 4, 3)]), 1, 0,
          'IfStmt owning two then');
      end),
    // F17, the last filed loss, is no loss any more: the `program`
    // parameters are an nkProgramParams - every token covered, none counted.
    // No loss row is left for a counted case (this one counted F17's 3
    // tokens until the fix, a parameter's `const` before F18).
    OwnCase('F17: program parameters are nodes',
      function: TPasCheckResult
      begin
        Result := LossCase(APP,
          'program P(Input, Output); begin end.', 'F17', 0, '');
      end),
    // F1, F2 and F10 are no loss any more: the directives are nkDirective
    // children, the `;` before a procedural type's run is its own token,
    // and the initializer after the run is the declaration's - every token
    // covered, none counted.
    OwnCase('F2: a procedural type''s directives are nodes',
      function: TPasCheckResult
      begin
        Result := LossCase(APP, 'type TFn = procedure; stdcall; ' +
          'TG = function(A: Integer): Integer cdecl varargs; ' +
          'TH = procedure stdcall of object;', 'F2', 0, '');
      end),
    OwnCase('F1: the initializer after the directives is adopted',
      function: TPasCheckResult
      begin
        Result := LossCase(APP, 'var P: procedure; cdecl = nil; ' +
          'Q: array[0..1] of procedure; stdcall;', 'F1', 0, '');
      end),
    OwnCase('F10: directives before a header''s ; are nodes',
      function: TPasCheckResult
      begin
        Result := LossCase(APP, 'function F: Boolean stdcall; ' +
          'function G(A: PAnsiChar): Integer cdecl varargs; external ''m'';',
          'F10', 0, '');
      end),
    // F19 is no loss any more: the names carry nfName, so the separators of
    // `P, T: C` and `P: T = C` are derived and no rule counts them.
    OwnCase('F19: where the names end is derived',
      function: TPasCheckResult
      begin
        Result := LossCase(APP, 'var P, T: C; Q: Integer = 5;', 'F19', 0, '');
      end)
  ];
end;

type
  TTreeMutation = reference to procedure(var ATree: TPasTree);

// The first node of AKind whose first token reads AText.
function NodeOf(const ATree: TPasTree; AKind: TPasNodeKind;
  const AText: string): Integer;
var
  LIdx: Integer;
begin
  for LIdx := 0 to High(ATree.Nodes) do
    if (ATree.Nodes[LIdx].Kind = AKind) and
       SameText(ATree.NodeText(LIdx), AText) then
      Exit(LIdx);
  Result := NIL_NODE;
end;

{ I6's name check must be able to fail. ASource parses clean - as statements
  when AStatements, else as a file - and checks clean; AMutate then breaks
  the tree the way a parser defect would (a name left unmarked, a type
  marked, the initializer mark lost), and the checker must report I6.flags
  and nothing else (AClass: I6.aux for an Aux mark), the first message
  saying ASays. }
function NameCase(APP: TPasPreprocessor; const ASource: string;
  AStatements: Boolean; const AMutate: TTreeMutation;
  const ASays: string; AClass: TPasCheckClass = ccFlags): TPasCheckResult;
var
  LPre: TPasPreprocessed;
  LDiags: TArray<TPasParseDiag>;
  LTree: TPasTree;
  LReport, LBroken: TPasCheckReport;
begin
  LPre := APP.ProcessText('test.pas', ASource);
  if AStatements then
    LTree := TPasParser.ParseStatements(LPre, LDiags)
  else
    LTree := TPasParser.ParseFile(LPre, LDiags);
  LReport.Init;
  CheckTree(LTree, Length(LDiags) = 0, LReport);
  AMutate(LTree);
  LBroken.Init;
  CheckTree(LTree, True, LBroken);
  Result.Passed := (Length(LDiags) = 0) and (LReport.Total = 0) and
    (LBroken.Total > 0) and (LBroken.Counts[AClass] = LBroken.Total) and
    (Pos(ASays, LBroken.Violations[0].Msg) > 0);
  Result.Message := '';
  if not Result.Passed then
    Result.Message := Format('  %s: %d diagnostics, %d violations before ' +
      'the change, %d after (%d %s); the first should say "%s":',
      [ASource, Length(LDiags), LReport.Total, LBroken.Total,
       LBroken.Counts[AClass], CheckClassName(AClass), ASays]) + sLineBreak +
      CheckReportText(LTree, LBroken);
end;

function NameFlagCase(const AName: string;
  const ARun: TFunc<TPasCheckResult>): TPasCustomCase;
begin
  Result.Section := 'I6';
  Result.Name := AName;
  Result.Run := ARun;
end;

{ The names a declaration marks (nfName) against its separators: every
  consumer read the separators before the flag existed, so the check that the
  two agree is what makes the flag trustworthy - and it must be able to say
  so when they do not. }
function BuildNameFlagCases(APP: TPasPreprocessor): TPasCustomCases;
begin
  Result := [
    // `P, T: C`: T left unmarked reads as P's type.
    NameFlagCase('a name left unmarked is a violation',
      function: TPasCheckResult
      begin
        Result := NameCase(APP, DeclCaseText('var P, T: C;'), False,
          procedure(var ATree: TPasTree)
          var
            LNode: Integer;
          begin
            LNode := NodeOf(ATree, nkIdent, 'T');
            ATree.Nodes[LNode].Flags := ATree.Nodes[LNode].Flags - [nfName];
          end, 'a name is not marked');
      end),
    // `P: T = C`: the type marked reads as a second name.
    NameFlagCase('a type marked as a name is a violation',
      function: TPasCheckResult
      begin
        Result := NameCase(APP, DeclCaseText('var P: T = C;'), False,
          procedure(var ATree: TPasTree)
          var
            LNode: Integer;
          begin
            LNode := NodeOf(ATree, nkIdent, 'T');
            ATree.Nodes[LNode].Flags := ATree.Nodes[LNode].Flags + [nfName];
          end, 'between two names');
      end),
    // `function A.B;`: B unmarked reads as A's result type, `function A: B;`.
    NameFlagCase('a routine segment left unmarked is a violation',
      function: TPasCheckResult
      begin
        Result := NameCase(APP, 'unit Test;'#13#10'interface'#13#10 +
          'implementation'#13#10'function A.B;'#13#10'begin'#13#10 +
          'end;'#13#10'end.'#13#10, False,
          procedure(var ATree: TPasTree)
          var
            LNode: Integer;
          begin
            LNode := NodeOf(ATree, nkIdent, 'B');
            ATree.Nodes[LNode].Flags := ATree.Nodes[LNode].Flags - [nfName];
          end, 'a name is not marked');
      end),
    // `var X := K`: without Aux 1, K reads as the type, `var X: K`.
    NameFlagCase('an inline initializer without its mark is a violation',
      function: TPasCheckResult
      begin
        Result := NameCase(APP, 'var X := K;', True,
          procedure(var ATree: TPasTree)
          begin
            ATree.Nodes[NodeOf(ATree, nkInlineVar, 'var')].Aux := NIL_NODE;
          end, 'where `:` is due');
      end),
    NameFlagCase('nfName off an identifier is a violation',
      function: TPasCheckResult
      begin
        Result := NameCase(APP, DeclCaseText('var P: T;'), False,
          procedure(var ATree: TPasTree)
          var
            LNode: Integer;
          begin
            LNode := NodeOf(ATree, nkVarSec, 'var');
            ATree.Nodes[LNode].Flags := ATree.Nodes[LNode].Flags + [nfName];
          end, 'carries nfName');
      end),
    // F29: the `;` of `procedure; stdcall` is derived from the directive's
    // Aux 1 - lost, the print writes `procedure stdcall`, one type but not
    // one .dcu; set on a directive written in, it writes a `;` there.
    NameFlagCase('a directive after the type''s ; without Aux 1 is a violation',
      function: TPasCheckResult
      begin
        Result := NameCase(APP, DeclCaseText('type T = procedure; stdcall;'),
          False,
          procedure(var ATree: TPasTree)
          begin
            ATree.Nodes[NodeOf(ATree, nkDirective, 'stdcall')].Aux := NIL_NODE;
          end, 'without Aux 1', ccAux);
      end),
    NameFlagCase('Aux 1 on a directive written into the type is a violation',
      function: TPasCheckResult
      begin
        Result := NameCase(APP, DeclCaseText('type T = procedure stdcall;'),
          False,
          procedure(var ATree: TPasTree)
          begin
            ATree.Nodes[NodeOf(ATree, nkDirective, 'stdcall')].Aux := 1;
          end, 'follows no', ccAux);
      end),
    NameFlagCase('Aux 1 on a routine''s directive is a violation',
      function: TPasCheckResult
      begin
        Result := NameCase(APP, 'unit Test;'#13#10'interface'#13#10 +
          'procedure P; stdcall;'#13#10'implementation'#13#10 +
          'procedure P;'#13#10'begin'#13#10'end;'#13#10'end.'#13#10, False,
          procedure(var ATree: TPasTree)
          begin
            ATree.Nodes[NodeOf(ATree, nkDirective, 'stdcall')].Aux := 1;
          end, 'outside a procedural type', ccAux);
      end)
  ];
end;

function DepthCase(const AName: string;
  const ARun: TFunc<TPasCheckResult>): TPasCustomCase;
begin
  Result.Section := 'B1-02';
  Result.Name := AName;
  Result.Run := ARun;
end;

// Parses ASource (a whole file) and checks the tree, catching what either
// raises: on generated nesting the result is diagnostics, never a stack
// overflow (EnterGuard's promise, audit B1-02).
function ParsesWithoutRaising(APP: TPasPreprocessor;
  const ASource: string): TPasCheckResult;
var
  LPre: TPasPreprocessed;
  LDiags: TArray<TPasParseDiag>;
  LTree: TPasTree;
  LReport: TPasCheckReport;
begin
  Result.Passed := False;
  Result.Message := '';
  try
    LPre := APP.ProcessText('deep.pas', ASource);
    LTree := TPasParser.ParseFile(LPre, LDiags);
    LReport.Init;
    CheckTree(LTree, False, LReport);
    Result.Passed := True;
  except
    on E: Exception do
      Result.Message := '  raised ' + E.ClassName + ': ' + E.Message;
  end;
end;

{ Generated nesting the parser's recursion guard did not cover: a type
  argument per `<` in a type position, and a routine per nesting level. And
  outside the parser, the $IF evaluator's operator chain, one recursion per
  operand. }
function BuildDepthCases(APP: TPasPreprocessor): TPasCustomCases;
begin
  Result := [
    DepthCase('100,000 nested type arguments parse without raising',
      function: TPasCheckResult
      begin
        Result := ParsesWithoutRaising(APP, 'unit Deep;'#10'interface'#10 +
          'type X = ' + DupeString('A<', 100000) + 'B' +
          DupeString('>', 100000) + ';'#10'implementation'#10'end.'#10);
      end),
    DepthCase('20,000 nested routines parse without raising',
      function: TPasCheckResult
      var
        LSrc: TStringBuilder;
        LIdx: Integer;
      begin
        LSrc := TStringBuilder.Create;
        try
          LSrc.Append('unit Deep;'#10'interface'#10'implementation'#10);
          for LIdx := 1 to 20000 do
            LSrc.Append('procedure P').Append(LIdx).Append(';'#10);
          for LIdx := 1 to 20000 do
            LSrc.Append('begin end;'#10);
          LSrc.Append('end.'#10);
          Result := ParsesWithoutRaising(APP, LSrc.ToString);
        finally
          LSrc.Free;
        end;
      end),
    DepthCase('a 5,000-operand $IF chain evaluates exactly',
      function: TPasCheckResult
      var
        LPre: TPasPreprocessed;
        LIdx: Integer;
        LTook: Boolean;
      begin
        Result.Passed := False;
        Result.Message := '';
        try
          // dcc takes the branch: the sum is exactly 5000.
          LPre := APP.ProcessText('chain.pas', '{$IF 1' +
            DupeString(' + 1', 4999) + ' = 5000} Took {$IFEND}'#10);
          LTook := False;
          for LIdx := 0 to High(LPre.Visible) do
            if SameText(LPre.VisibleText(LIdx), 'Took') then
              LTook := True;
          Result.Passed := LTook;
          if not LTook then
            Result.Message := '  the branch was not taken';
        except
          on E: Exception do
            Result.Message := '  raised ' + E.ClassName + ': ' + E.Message;
        end;
      end)
  ];
end;

// Occurrences of ASub in AText (non-overlapping).
function CountOf(const AText, ASub: string): Integer;
var
  LAt: Integer;
begin
  Result := 0;
  LAt := Pos(ASub, AText);
  while LAt > 0 do
  begin
    Inc(Result);
    LAt := PosEx(ASub, AText, LAt + Length(ASub));
  end;
end;

function ChainCase(const ASection, AName: string;
  const ARun: TFunc<TPasCheckResult>): TPasCustomCase;
begin
  Result.Section := ASection;
  Result.Name := AName;
  Result.Run := ARun;
end;

{ Depth that is not the source's nesting: an operator chain is a left spine of
  nkBinaryOp as long as the chain (audit A1-01, B1-37), an `else if` chain a
  right spine of ifs (A1-07). Both are flat code that generators write by the
  thousand; dcc64 37.0 compiles either. }
function BuildChainCases(APP: TPasPreprocessor): TPasCustomCases;
begin
  Result := [
    ChainCase('A1-07', 'a 1,000-arm else-if chain parses clean, arm in arm',
      function: TPasCheckResult
      var
        LSrc: TStringBuilder;
        LPre: TPasPreprocessed;
        LDiags: TArray<TPasParseDiag>;
        LTree: TPasTree;
        LIdx, LIfs, LLast, LDepth, LNode: Integer;
      begin
        Result.Passed := False;
        Result.Message := '';
        LSrc := TStringBuilder.Create;
        try
          LSrc.Append('unit Arms;'#10'interface'#10'implementation'#10 +
            'function F(I: Integer): Integer;'#10'begin'#10 +
            '  if I = 0 then Result := 0'#10);
          for LIdx := 1 to 999 do
            LSrc.Append('  else if I = ').Append(LIdx)
              .Append(' then Result := ').Append(LIdx).Append(#10);
          LSrc.Append('  else Result := -1;'#10'end;'#10'end.'#10);
          try
            LPre := APP.ProcessText('arms.pas', LSrc.ToString);
            LTree := TPasParser.ParseFile(LPre, LDiags);
          except
            on E: Exception do
            begin
              Result.Message := '  raised ' + E.ClassName + ': ' + E.Message;
              Exit;
            end;
          end;
        finally
          LSrc.Free;
        end;
        // Every arm is an nkIfStmt, each the last child of the one before:
        // the innermost has the other 999 above it.
        LIfs := 0;
        LLast := NIL_NODE;
        for LIdx := 0 to High(LTree.Nodes) do
          if LTree.Nodes[LIdx].Kind = nkIfStmt then
          begin
            Inc(LIfs);
            LLast := LIdx;
          end;
        LDepth := 0;
        if LLast <> NIL_NODE then
        begin
          LNode := LTree.Nodes[LLast].Parent;
          while LNode <> NIL_NODE do
          begin
            if LTree.Nodes[LNode].Kind = nkIfStmt then
              Inc(LDepth);
            LNode := LTree.Nodes[LNode].Parent;
          end;
        end;
        Result.Passed := (Length(LDiags) = 0) and (LIfs = 1000) and
          (LDepth = 999);
        if not Result.Passed then
        begin
          Result.Message := Format('  %d diagnostics, %d ifs, the last %d deep',
            [Length(LDiags), LIfs, LDepth]);
          if Length(LDiags) > 0 then
            Result.Message := Result.Message + #10'  first: ' +
              LDiags[0].Msg;
        end;
      end),
    ChainCase('A1-01', 'a 50,000-term operator chain prints, dumps and ' +
      'serializes',
      function: TPasCheckResult
      const
        TERMS = 50000;
      var
        LPre: TPasPreprocessed;
        LDiags: TArray<TPasParseDiag>;
        LTree: TPasTree;
        LT3: TPasT3Result;
        LDump, LJson: string;
      begin
        Result.Passed := False;
        Result.Message := '';
        try
          LPre := APP.ProcessText('chain.pas', 'unit Chain;'#10'interface'#10 +
            'const S = ''a''' + DupeString(#10'  + ''b''', TERMS - 1) + ';'#10 +
            'implementation'#10'end.'#10);
          LTree := TPasParser.ParseFile(LPre, LDiags);
          // T3: every token of the chain printed back where it stood.
          if not CompareT3(LTree, 0, LT3) or (LT3.Matched <> LT3.Printed) then
          begin
            Result.Message := Format('  T3: %d printed, %d matched, %d defects',
              [LT3.Printed, LT3.Matched, LT3.Defects]);
            Exit;
          end;
          LDump := LTree.Dump(0);
          LJson := AstToJson(LTree);
          // One string leaf per term in each.
          Result.Passed := (Length(LDiags) = 0) and
            (CountOf(LDump, 'StrLit''') = TERMS) and
            (CountOf(LJson, '"kind":"StrLit"') = TERMS);
          if not Result.Passed then
            Result.Message := Format(
              '  %d diagnostics, %d leaves in the dump, %d in the JSON',
              [Length(LDiags), CountOf(LDump, 'StrLit'''),
               CountOf(LJson, '"kind":"StrLit"')]);
        except
          on E: Exception do
            Result.Message := '  raised ' + E.ClassName + ': ' + E.Message;
        end;
      end)
  ];
end;

var
  GSM: TPasSourceManager;
  GDefines: TPasDefines;
  GPP: TPasPreprocessor;
  GPassed, GFailed: Integer;
begin
  GSM := TPasSourceManager.Create([]);
  GDefines := TPasDefines.Create(['MSWINDOWS', 'WIN64']);
  GPP := TPasPreprocessor.Create(GSM, GDefines);
  GVerdictPP := GPP;
  GCustomTreeVerdict := TreeVerdict;
  try
    RunSuite('ParserSmoke', GPP, STMT_CASES, DECL_CASES,
      BuildCustomCases(GPP, GSM) + BuildRoundtripCases +
      BuildPreprocessorCases(GPP) + BuildOwnTokenCases(GPP) +
      BuildNameFlagCases(GPP) + BuildDepthCases(GPP) + BuildChainCases(GPP),
      GPassed,
      GFailed, TreeVerdict);
    if GFailed > 0 then
      ExitCode := 1;
  finally
    GPP.Free;
    GDefines.Free;
    GSM.Free;
  end;
end.
