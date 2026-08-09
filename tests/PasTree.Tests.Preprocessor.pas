unit PasTree.Tests.Preprocessor;

{
  test-coverage plan step 3 batch 5: 1.3.1 (switch & parameter directives)
  and 1.3.4 ($PUSHOPT/$POPOPT) have no AST shape of their own -- a switch
  directive changes compiler OPTION STATE, and CheckDump has nothing to
  compare against for that. PasTree.TestKit's SwitchCase is the
  infrastructure this batch needed: it reads the option back off the
  preprocessor itself (TPasPreprocessor.SwitchState/ScopedEnumsFinal, added
  alongside these cases) instead of forcing the case into a dump comparison
  it doesn't fit.

  Two properties get tested per section, not one: that the OPTION reads
  right (SwitchCase, direct), and — for 1.3.1 only — that a downstream
  $IFOPT actually BRANCHES on it (a plain STMT_CASES row via ParseStatements,
  since that half already fits CheckDump). $PUSHOPT/$POPOPT is state-only
  (nothing branches on the SAVE/RESTORE itself), so 1.3.4 stays entirely in
  SwitchCase/custom-case territory.
}

interface

uses
  PasTree.Types, PasTree.Ast, PasTree.Parser, PasTree.Preprocessor,
  PasTree.TestKit;

function BuildPreprocessorCases(APP: TPasPreprocessor): TPasCustomCases;

implementation

uses
  System.SysUtils;

function BuildPreprocessorCases(APP: TPasPreprocessor): TPasCustomCases;

  { $IFOPT reading back what a plain switch directive just set -- the other
    half of 1.3.1: not just that SwitchState answers right (the rows below
    already cover that), but that conditional compilation actually ACTS on
    it, the same way 1.3.2's ifdef case proves for $DEFINE. }
  function IfOptBranchesOnSwitchCase: TPasCustomCase;
  begin
    Result.Section := '1.3.1';
    Result.Name := '$IFOPT branches on a switch directive';
    Result.Run :=
      function: TPasCheckResult
      const
        SRC = '{$R+}{$IFOPT R+}A := 1;{$ELSE}A := 2;{$ENDIF}';
      var
        LPre: TPasPreprocessed;
        LDiags: TArray<TPasParseDiag>;
        LTree: TPasTree;
      begin
        LPre := APP.ProcessText('test.pas', SRC);
        LTree := TPasParser.ParseStatements(LPre, LDiags);
        Result := CheckDump(SRC, 'Block(Assign(Ident''A'' IntLit''1''))',
          LTree.Dump(0), LDiags, 0);
      end;
  end;

  { $POPOPT with no matching $PUSHOPT is a real diagnostic (ppPopWithoutPush),
    not silently ignored -- the one 1.3.4 behavior that is neither a switch
    VALUE nor an AST shape, just a preprocessor diagnostic. }
  function PopWithoutPushCase: TPasCustomCase;
  begin
    Result.Section := '1.3.4';
    Result.Name := '$POPOPT without a matching $PUSHOPT is diagnosed';
    Result.Run :=
      function: TPasCheckResult
      const
        SRC = '{$POPOPT}';
      var
        LPre: TPasPreprocessed;
        LIdx: Integer;
        LFound: Boolean;
      begin
        LPre := APP.ProcessText('test.pas', SRC);
        LFound := False;
        for LIdx := 0 to High(LPre.Diagnostics) do
          if LPre.Diagnostics[LIdx].Code = ppPopWithoutPush then
            LFound := True;
        Result.Passed := LFound;
        if Result.Passed then
          Result.Message := ''
        else
          Result.Message := '  expected a ppPopWithoutPush diagnostic, got ' +
            IntToStr(Length(LPre.Diagnostics)) + ' diagnostic(s)' +
            sLineBreak;
      end;
  end;

begin
  Result := [
    // ---- 1.3.1: a switch directive sets/clears a single-letter option,
    // alone and combined with another switch on the same directive line
    // (`{$R+,O-}`, the shape ApplySwitches exists for) ----
    SwitchCase('1.3.1', 'a switch directive sets an option', '{$R+}', 'R',
      True, APP),
    SwitchCase('1.3.1', 'a switch directive clears an option',
      '{$R+}{$R-}', 'R', False, APP),
    SwitchCase('1.3.1', 'two switches on one directive line, first',
      '{$R+,O-}', 'R', True, APP),
    SwitchCase('1.3.1', 'two switches on one directive line, second',
      '{$R+,O-}', 'O', False, APP),
    IfOptBranchesOnSwitchCase,

    // ---- 1.3.4: $PUSHOPT/$POPOPT round-trips BOTH halves of TPasOptState
    // -- the single-letter switches and SCOPEDENUMS, tracked separately
    // because SCOPEDENUMS is a long-form-only option (see TPasOptState's
    // own comment) ----
    SwitchCase('1.3.4', '$PUSHOPT/$POPOPT round-trips a switch',
      '{$R+}{$PUSHOPT}{$R-}{$POPOPT}', 'R', True, APP),
    SwitchCase('1.3.4', '$PUSHOPT/$POPOPT round-trips SCOPEDENUMS too',
      '{$SCOPEDENUMS ON}{$PUSHOPT}{$SCOPEDENUMS OFF}{$POPOPT}', #0, True,
      APP),
    PopWithoutPushCase
  ];
end;

end.
