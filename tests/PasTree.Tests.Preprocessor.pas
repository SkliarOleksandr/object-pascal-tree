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

// 19.2.1 ({$RTTI}): renders TPasRttiState the way CheckDump expects a
// golden string -- mode plus each category's set, `-` when the category
// clause was never written at all (distinct from an empty `[]`, which this
// repo's fixtures never exercise but the record still distinguishes). Unit-
// scope, not nested inside BuildPreprocessorCases: a nested FUNCTION (as
// opposed to a captured variable) cannot be called from an anonymous method
// nested alongside it (E2555), only from ordinary nested procedures.
function DumpRttiState(const AState: TPasRttiState): string;
const
  VIS_NAMES: array[TPasRttiVisibility] of string =
    ('Private', 'Protected', 'Public', 'Published');
  MODE_NAMES: array[TPasRttiMode] of string = ('Inherit', 'Explicit');

  function DumpSet(AHas: Boolean; const ASet: TPasRttiVisibilitySet): string;
  var
    LV: TPasRttiVisibility;
    LNames: TArray<string>;
  begin
    if not AHas then
      Exit('-');
    LNames := [];
    for LV := Low(TPasRttiVisibility) to High(TPasRttiVisibility) do
      if LV in ASet then
        LNames := LNames + [VIS_NAMES[LV]];
    Result := '[' + string.Join(',', LNames) + ']';
  end;

begin
  Result := MODE_NAMES[AState.Mode] +
    ' Methods=' + DumpSet(AState.HasMethods, AState.Methods) +
    ' Fields=' + DumpSet(AState.HasFields, AState.Fields) +
    ' Properties=' + DumpSet(AState.HasProperties, AState.Properties);
end;

function BuildPreprocessorCases(APP: TPasPreprocessor): TPasCustomCases;

  // A {$RTTI ...} directive (plus, optionally, more source after it) read
  // back via TPasPreprocessor.RttiState and rendered through DumpRttiState
  // -- CheckDump gives this the same source/expected/actual failure format
  // as every dump-comparison case, even though there is no AST dump here.
  function RttiCase(const ASection, AName, ASource, AExpected: string):
    TPasCustomCase;
  begin
    Result.Section := ASection;
    Result.Name := AName;
    Result.Run :=
      function: TPasCheckResult
      begin
        APP.ProcessText('test.pas', ASource);
        Result := CheckDump(ASource, AExpected,
          DumpRttiState(APP.RttiState), [], 0);
      end;
  end;

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
    PopWithoutPushCase,

    // ---- 19.1.1 (classic TObject RTTI / `M`): the spec frames this as pure
    // directive-STATE, same shape as 1.3.1 -- and it turns out ApplySwitches
    // already tracks any letter A..Z generically (it never special-cased
    // which letters are "real" switches), so `M` was ALREADY answered
    // correctly by SwitchState with zero source change. Probed before
    // trusting that, same as every other batch: this is the confirmation. ----
    SwitchCase('19.1.1', '{$M+} sets the option', '{$M+}', 'M', True, APP),
    SwitchCase('19.1.1', '{$M-} after {$M+} clears it',
      '{$M+}{$M-}', 'M', False, APP),
    SwitchCase('19.1.1', 'M is off by default, unlike C/D/O/...',
      '', 'M', False, APP),

    // ---- 19.2.1 ({$RTTI mode METHODS(set) FIELDS(set) PROPERTIES(set)}):
    // unlike a plain switch this has real grammar (ApplyRtti, added for this
    // batch) -- mode word plus up to three category clauses, each an
    // explicit set or a range. RttiCase/DumpRttiState above render the
    // structured result the same way a dump comparison would. ----
    RttiCase('19.2.1', 'no {$RTTI} at all -- INHERIT, no category clauses',
      '', 'Inherit Methods=- Fields=- Properties=-'),
    RttiCase('19.2.1', 'EXPLICIT with one category',
      '{$RTTI EXPLICIT METHODS([vcPublic,vcPublished])}',
      'Explicit Methods=[Public,Published] Fields=- Properties=-'),
    RttiCase('19.2.1', 'EXPLICIT with all three categories -- the real-world '
      + 'RTL shape',
      '{$RTTI EXPLICIT METHODS([vcPublic,vcPublished]) ' +
      'FIELDS([vcPrivate,vcProtected,vcPublic,vcPublished]) ' +
      'PROPERTIES([vcPublic,vcPublished])}',
      'Explicit Methods=[Public,Published] ' +
      'Fields=[Private,Protected,Public,Published] ' +
      'Properties=[Public,Published]'),
    RttiCase('19.2.1', 'a visibility RANGE (vcPrivate..vcPublished) expands',
      '{$RTTI EXPLICIT FIELDS([vcPrivate..vcPublished])}',
      'Explicit Methods=- Fields=[Private,Protected,Public,Published] ' +
      'Properties=-'),
    RttiCase('19.2.1', 'INHERIT is still a real mode, not just "absent"',
      '{$RTTI INHERIT METHODS([vcPublic])}',
      'Inherit Methods=[Public] Fields=- Properties=-'),
    RttiCase('1.3.4', '$PUSHOPT/$POPOPT round-trips RTTI too',
      '{$RTTI EXPLICIT METHODS([vcPublic])}{$PUSHOPT}' +
      '{$RTTI INHERIT}{$POPOPT}',
      'Explicit Methods=[Public] Fields=- Properties=-')
  ];
end;

end.
