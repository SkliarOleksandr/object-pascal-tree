program PasTreeDiffHarness;

{ The incremental-reanalysis DIFFERENTIAL HARNESS (stage B's first
  deliverable): runs an edit sequence through the FULL pipeline and through
  the INCREMENTAL path over the same closure, and compares RefMap, ExtRefMap
  and diagnostics across the ENTIRE closure after every step. The corpus
  suites only ever prove the full path; this is the evidence that the
  incremental path produces the same project, not a plausible-looking one.

  Usage:
    PasTreeDiffHarness <root.dpr> [-p:<platform>] [-L<dir>]...
                       [-samples:<N>] [-script:<file>] [-module]

  Two incremental MODES:
    default  - the stage-A donor CHAIN: rebuild k adopts rebuild k-1 as parse
               donor, exactly the LSP's intended usage.
    -module  - stage B: ONE project is kept alive across the whole sequence
               and each edit goes through AnalyzeModuleOnly (buffer overlay,
               single-module re-analysis in place). A REFUSAL falls back to a
               donor rebuild, exactly as a host must, and is reported as such.
               A body edit is expected to be ACCEPTED; an interface edit may
               be accepted too, since the redo covers the affected consumers
               (they return to Phase 1 and rebuild their own references), and
               is then counted, not judged - what decides correctness is the
               comparison against the full pipeline that every step runs.
               An unexpected fallback on a body edit is a WARNING (refusing is
               always safe) but is counted: a fast path that never fires is
               not a fast path.

  Edits are applied as BUFFER OVERLAYS (SetBuffer), never to the disk: both
  pipelines read byte-identical text through the one loader, so even an edit
  that lands badly in some exotic layout still differentiates the pipelines -
  the ground truth sees the same text. Steps are CUMULATIVE. Two synthetic
  edit kinds per sampled unit, per the plan:
    (a) body edit - a new procedure at the end of the implementation section
        (interface symbol sequence unchanged);
    (b) interface edit - a new routine declared at the end of the interface
        section, with its body appended.
  A -script file replaces the synthetic sampling: one edit per line,
  `body|intf|blank|comment|const|type <full-path>`, applied in order (the
  last four land at the end of the interface section).

  -selftest inverts the exercise to prove the COMPARATOR can see: the
  incremental side is deliberately fed the PRE-EDIT text of each step's
  edited file (the two pipelines then really analyze different projects), and
  every edit step is REQUIRED to mismatch - a step that compares equal fails
  the run, because a blind comparator makes every green run above worthless.

  Exit code 0 = every step compared equal (or, under -selftest, every edit
  step was caught); 1 otherwise. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Diagnostics,
  System.IOUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.Project in '..\source\PasTree.Project.pas',
  PasTree.CondEval in '..\source\PasTree.CondEval.pas',
  PasTree.Sema.Diagnostics in '..\source\PasTree.Sema.Diagnostics.pas',
  PasTree.Sema.Model in '..\source\PasTree.Sema.Model.pas',
  PasTree.Sema.Builtins in '..\source\PasTree.Sema.Builtins.pas',
  PasTree.Sema.Resolver in '..\source\PasTree.Sema.Resolver.pas',
  PasTree.Sema.Project in '..\source\PasTree.Sema.Project.pas';

type
  TEditKind = (ekBody, ekIntf, ekBlank, ekComment, ekConst, ekType);
  TEditStep = record
    Kind: TEditKind;
    Path: string;    // full path of the unit to edit
  end;

const
  MAX_REPORTED = 10;   // mismatch lines printed per step before eliding

var
  GPlatform: TPasPlatform;
  GRoot: string;
  GPaths: TArray<string>;
  GSamples: Integer;
  GScriptFile: string;
  GTexts: TDictionary<string, string>;    // path (lower) -> current text
  GVersion: Integer;                      // bumped per applied edit
  GFailedSteps: Integer;
  GSelfTest: Boolean;
  GSingleThread: Boolean;     // -st: both sides run the passes sequentially
  // -redolimit:N - ModuleRedoLimit for both sides (0 = leave the default).
  // Negative means NO ceiling: take any blast radius, which is how the
  // crossover against a full rebuild gets measured instead of guessed.
  GRedoLimit: Integer;
  GModuleMode: Boolean;       // -module: AnalyzeModuleOnly instead of the chain
  GAccepted: Integer;         // module mode: steps the guards accepted
  GFellBack: Integer;         // module mode: body edits that fell back anyway
  GAcceptedIntf: Integer;     // module mode: interface edits the redo covered
  // -selftest state for the CURRENT step: the edited file's pre-edit text,
  // fed to the incremental side only. '' = no divergence this step.
  GStaleKey, GStaleText: string;

{ ---- project construction (both sides identical except the donor) -------- }

function NewProject(AStale: Boolean): TPasSemaProject;
var
  LPair: TPair<string, string>;
begin
  Result := TPasSemaProject.Create(GPlatform, GPaths, []);
  Result.SingleThreaded := GSingleThread;
  if GRedoLimit <> 0 then
    Result.ModuleRedoLimit := GRedoLimit;
  Result.SetNamespaces(PasDefaultNamespaces(GPlatform));
  for var LDef in PasDefaultUnitAliases(GPlatform) do
    Result.AddUnitAlias(LDef.Alias, LDef.UnitName);
  for LPair in GTexts do
    if AStale and (LPair.Key = GStaleKey) then
      Result.SetBuffer(LPair.Key, GStaleText, GVersion)
    else
      Result.SetBuffer(LPair.Key, LPair.Value, GVersion);
end;

function AnalyzeOne(ADonor: TPasSemaProject; AStale: Boolean = False):
  TPasSemaProject;
begin
  Result := NewProject(AStale);
  if (ADonor <> nil) and not Result.AdoptParseDonor(ADonor) then
  begin
    Writeln(ErrOutput, 'FATAL: donor refused (config mismatch) - the harness ' +
      'builds both sides identically, so this is a defect');
    Halt(2);
  end;
  Result.AnalyzeStaged([GRoot], nil);
end;

{ ---- synthetic edits ------------------------------------------------------ }

// Line index of the first line whose trimmed text equals AWord (case-
// insensitive); -1 if none. Deliberately EXACT-line: a unit spelling the
// keyword with a trailing comment just gets skipped by the sampler.
function LineIndexOf(const ALines: TArray<string>; const AWord: string;
  AFromEnd: Boolean = False): Integer;
var
  LIdx: Integer;
begin
  if AFromEnd then
  begin
    for LIdx := High(ALines) downto 0 do
      if SameText(Trim(ALines[LIdx]), AWord) then
        Exit(LIdx);
  end
  else
    for LIdx := 0 to High(ALines) do
      if SameText(Trim(ALines[LIdx]), AWord) then
        Exit(LIdx);
  Result := -1;
end;

{ Applies one synthetic edit to AText; False when the unit's layout does not
  carry the markers the transform needs (the sampler then skips it).

  Insertion points: the interface DECLARATION goes right before the
  `implementation` line (the end of the interface section - always legal, no
  interference with a leading `uses`); the implementation CODE goes before
  `initialization` when the unit has one, else before the final `end.` (a
  declaration after `initialization` would not compile). NB even a transform
  that lands badly on some exotic layout stays a VALID differential step -
  both pipelines read the identical result. }
function ApplyEdit(const AText: string; AKind: TEditKind; ASeq: Integer;
  out ANewText: string): Boolean;
var
  LLines: TList<string>;
  LArr: TArray<string>;
  LImpl, LTail, LInit: Integer;
begin
  Result := False;
  ANewText := AText;
  LArr := AText.Split([#10]);
  for var LIdx := 0 to High(LArr) do
    LArr[LIdx] := LArr[LIdx].TrimRight([#13]);
  LImpl := LineIndexOf(LArr, 'implementation');
  LTail := LineIndexOf(LArr, 'end.', True);
  if (LImpl < 0) or (LTail < 0) or (LTail < LImpl) then
    Exit;
  LInit := LineIndexOf(LArr, 'initialization');
  if (LInit > LImpl) and (LInit < LTail) then
    LTail := LInit;   // declarations must precede the initialization section
  LLines := TList<string>.Create;
  try
    LLines.AddRange(LArr);
    // Insert bottom-most first so the earlier index stays valid.
    case AKind of
      ekBody:
        LLines.Insert(LTail, Format(
          'procedure __DiffBody%d; var __V: Integer; begin __V := %d; end;',
          [ASeq, ASeq]));
      ekIntf:
        begin
          LLines.Insert(LTail, Format(
            'procedure __DiffIntf%d; begin end;', [ASeq]));
          LLines.Insert(LImpl, Format('procedure __DiffIntf%d;', [ASeq]));
        end;
      // The "start typing in a big interface" shapes: nothing a consumer can
      // see (blank lines, a comment) and a fresh declaration nobody refers to.
      ekBlank:
        begin
          LLines.Insert(LImpl, '');
          LLines.Insert(LImpl, '');
        end;
      ekComment:
        LLines.Insert(LImpl, Format('// __DiffComment%d', [ASeq]));
      ekConst:
        LLines.Insert(LImpl, Format('const __DiffConst%d = %d;', [ASeq, ASeq]));
      ekType:
        LLines.Insert(LImpl, Format('type __DiffType%d = Integer;', [ASeq]));
    end;
    ANewText := string.Join(#13#10, LLines.ToArray);
    Result := True;
  finally
    LLines.Free;
  end;
end;

{ ---- comparison ----------------------------------------------------------- }

// path (lower) -> model id, for every loaded model of AProj.
function PathMap(AProj: TPasSemaProject): TDictionary<string, Integer>;
begin
  Result := TDictionary<string, Integer>.Create;
  for var LMid := 0 to AProj.ModelCount - 1 do
    Result.AddOrSetValue(LowerCase(AProj.ModelFile(LMid)), LMid);
end;

// A unit id inside AProj rendered generation-independently (its file path):
// model ids need not survive between two runs, paths do.
function UnitTag(AProj: TPasSemaProject; AUnitId: Integer): string;
begin
  if (AUnitId >= 0) and (AUnitId < AProj.ModelCount) then
    Result := LowerCase(AProj.ModelFile(AUnitId))
  else
    Result := '#' + IntToStr(AUnitId);
end;

function DiagLines(AModel: TPasSemaModel): TArray<string>;
begin
  SetLength(Result, Length(AModel.Diags));
  for var LIdx := 0 to High(AModel.Diags) do
    Result[LIdx] := Format('%s(%d,%d) %s', [AModel.Diags[LIdx].Code,
      AModel.Diags[LIdx].Line, AModel.Diags[LIdx].Col,
      AModel.Diags[LIdx].Msg]);
  // Content equality, not order: per-model diag order is deterministic today,
  // but nothing downstream depends on it and the harness must not either.
  TArray.Sort<string>(Result);
end;

function ExtLines(AProj: TPasSemaProject;
  AModel: TPasSemaModel): TArray<string>;
var
  LPair: TPair<Integer, TPasExtRef>;
  LCount: Integer;
begin
  SetLength(Result, AModel.ExtRefMap.Count);
  LCount := 0;
  for LPair in AModel.ExtRefMap do
  begin
    Result[LCount] := Format('%d>%s:%d', [LPair.Key,
      UnitTag(AProj, LPair.Value.UnitId), LPair.Value.Sym]);
    Inc(LCount);
  end;
  TArray.Sort<string>(Result);   // dictionary order is not deterministic
end;

var
  GReported: Integer;   // per step; reset in CompareStep
  GReportCap: Integer;  // MAX_REPORTED normally; 1 on a self-test step

procedure Mismatch(const AWhat: string);
begin
  Inc(GReported);
  if GReported <= GReportCap then
    Writeln(ErrOutput, '    ', AWhat)
  else if GReported = GReportCap + 1 then
    Writeln(ErrOutput, '    ... (further mismatches elided)');
end;

// First index where the sorted line sets differ, described; '' when equal.
function FirstDelta(const ATruth, ACand: TArray<string>): string;
var
  LIdx: Integer;
begin
  if Length(ATruth) <> Length(ACand) then
    Exit(Format('count %d vs %d', [Length(ATruth), Length(ACand)]));
  for LIdx := 0 to High(ATruth) do
    if ATruth[LIdx] <> ACand[LIdx] then
      Exit(Format('[%d] "%s" vs "%s"', [LIdx, ATruth[LIdx], ACand[LIdx]]));
  Result := '';
end;

function CompareStep(ATruth, ACand: TPasSemaProject): Boolean;
var
  LTruthMap, LCandMap: TDictionary<string, Integer>;
  LPair: TPair<string, Integer>;
  LMid: Integer;
  LTM, LCM: TPasSemaModel;
  LDelta: string;
begin
  GReported := 0;
  GReportCap := MAX_REPORTED;
  if GStaleKey <> '' then
    GReportCap := 1;   // the self-test EXPECTS a mismatch; one line is proof
  LTruthMap := PathMap(ATruth);
  LCandMap := PathMap(ACand);
  try
    for LPair in LTruthMap do
      if not LCandMap.ContainsKey(LPair.Key) then
        Mismatch('unit missing on the incremental side: ' + LPair.Key);
    for LPair in LCandMap do
      if not LTruthMap.ContainsKey(LPair.Key) then
        Mismatch('extra unit on the incremental side: ' + LPair.Key);

    for LPair in LTruthMap do
    begin
      if not LCandMap.TryGetValue(LPair.Key, LMid) then
        Continue;
      LTM := ATruth.Model(LPair.Value);
      LCM := ACand.Model(LMid);

      // RefMap: intra-unit bindings, node-indexed - a pure array compare
      // (symbol indices are intra-model and both sides parsed identical text).
      if Length(LTM.RefMap) <> Length(LCM.RefMap) then
        Mismatch(Format('%s: RefMap length %d vs %d',
          [LPair.Key, Length(LTM.RefMap), Length(LCM.RefMap)]))
      else
        for var LIdx := 0 to High(LTM.RefMap) do
          if LTM.RefMap[LIdx] <> LCM.RefMap[LIdx] then
          begin
            Mismatch(Format('%s: RefMap[%d] = %d vs %d',
              [LPair.Key, LIdx, LTM.RefMap[LIdx], LCM.RefMap[LIdx]]));
            Break;   // one line per unit; the first divergence names the node
          end;

      // ExtRefMap: cross-unit bindings - compared via file PATHS, because
      // model ids are a per-run accident of load order, not an identity.
      LDelta := FirstDelta(ExtLines(ATruth, LTM), ExtLines(ACand, LCM));
      if LDelta <> '' then
        Mismatch(Format('%s: ExtRefMap %s', [LPair.Key, LDelta]));

      // Diagnostics, full text + position.
      LDelta := FirstDelta(DiagLines(LTM), DiagLines(LCM));
      if LDelta <> '' then
        Mismatch(Format('%s: diags %s', [LPair.Key, LDelta]));
    end;
  finally
    LTruthMap.Free;
    LCandMap.Free;
  end;
  Result := GReported = 0;
  if not Result then
    Inc(GFailedSteps);
end;

{ ---- donor stats out of StageTimings -------------------------------------- }

function DonorStats(AProj: TPasSemaProject): string;
var
  LPos: Integer;
begin
  LPos := Pos('donorhits=', AProj.StageTimings);
  if LPos > 0 then
    Result := Copy(AProj.StageTimings, LPos, MaxInt)
  else
    Result := 'donorhits=?';
end;

{ ---- step sequence -------------------------------------------------------- }

function KindName(AKind: TEditKind): string;
begin
  case AKind of
    ekBody: Result := 'body';
    ekIntf: Result := 'intf';
    ekBlank: Result := 'blank';
    ekComment: Result := 'comment';
    ekConst: Result := 'const';
  else
    Result := 'type';
  end;
end;

// The synthetic sample: every loaded unit whose layout carries the markers,
// paths sorted, then an even stride down to GSamples - deterministic, no
// randomness (the harness must reproduce bit-for-bit across runs).
function SampleUnits(AProj: TPasSemaProject): TArray<string>;
var
  LAll: TList<string>;
  LText, LDummy: string;
  LStride, LIdx: Integer;
begin
  LAll := TList<string>.Create;
  try
    for var LMid := 0 to AProj.ModelCount - 1 do
    begin
      LText := TPasSourceManager.LoadFileTolerant(AProj.ModelFile(LMid));
      if ApplyEdit(LText, ekIntf, 0, LDummy) then
        LAll.Add(AProj.ModelFile(LMid));
    end;
    LAll.Sort;
    if LAll.Count <= GSamples then
      Exit(LAll.ToArray);
    Result := nil;
    LStride := LAll.Count div GSamples;
    LIdx := 0;
    while (LIdx < LAll.Count) and (Length(Result) < GSamples) do
    begin
      Result := Result + [LAll[LIdx]];
      Inc(LIdx, LStride);
    end;
  finally
    LAll.Free;
  end;
end;

function LoadScript(const AFile: string): TArray<TEditStep>;
var
  LLine, LKindWord, LPath: string;
  LStep: TEditStep;
  LSpace: Integer;
begin
  Result := nil;
  for LLine in TFile.ReadAllLines(AFile) do
  begin
    if Trim(LLine) = '' then
      Continue;
    LSpace := Pos(' ', LLine);
    if LSpace = 0 then
    begin
      Writeln(ErrOutput, 'bad script line: ', LLine);
      Halt(2);
    end;
    LKindWord := Copy(LLine, 1, LSpace - 1);
    LPath := TPath.GetFullPath(Trim(Copy(LLine, LSpace + 1, MaxInt)));
    if SameText(LKindWord, 'body') then
      LStep.Kind := ekBody
    else if SameText(LKindWord, 'intf') then
      LStep.Kind := ekIntf
    else if SameText(LKindWord, 'blank') then
      LStep.Kind := ekBlank
    else if SameText(LKindWord, 'comment') then
      LStep.Kind := ekComment
    else if SameText(LKindWord, 'const') then
      LStep.Kind := ekConst
    else if SameText(LKindWord, 'type') then
      LStep.Kind := ekType
    else
    begin
      Writeln(ErrOutput, 'bad script kind: ', LKindWord);
      Halt(2);
    end;
    LStep.Path := LPath;
    Result := Result + [LStep];
  end;
end;

{ ---- main ------------------------------------------------------------------ }

var
  GIdx: Integer;
  LSteps: TArray<TEditStep>;
  LStep: TEditStep;
  LCand, LNext, LTruth: TPasSemaProject;
  LKey, LText, LNew, LLabel: string;
  LSW: TStopwatch;
  LOk: Boolean;

begin
  GPlatform := pfWin64;
  GSamples := 5;
  GSelfTest := False;
  GSingleThread := False;
  GRedoLimit := 0;
  GModuleMode := False;
  GAccepted := 0;
  GFellBack := 0;
  GAcceptedIntf := 0;
  for GIdx := 1 to ParamCount do
    if ParamStr(GIdx).StartsWith('-p:', True) then
    begin
      if not TryParsePlatformName(Copy(ParamStr(GIdx), 4, MaxInt),
        GPlatform) then
      begin
        Writeln(ErrOutput, 'unknown platform: ', ParamStr(GIdx));
        Halt(2);
      end;
    end
    else if ParamStr(GIdx).StartsWith('-samples:', True) then
      GSamples := StrToIntDef(Copy(ParamStr(GIdx), 10, MaxInt), GSamples)
    else if ParamStr(GIdx).StartsWith('-script:', True) then
      GScriptFile := Copy(ParamStr(GIdx), 9, MaxInt)
    else if SameText(ParamStr(GIdx), '-selftest') then
      GSelfTest := True
    else if ParamStr(GIdx).StartsWith('-redolimit:', True) then
      GRedoLimit := StrToIntDef(Copy(ParamStr(GIdx), 12, MaxInt), 0)
    else if SameText(ParamStr(GIdx), '-st') then
      GSingleThread := True
    else if SameText(ParamStr(GIdx), '-module') then
      GModuleMode := True
    else if ParamStr(GIdx).StartsWith('-L', True) then
      GPaths := GPaths + [Copy(ParamStr(GIdx), 3, MaxInt)]
    else if GRoot = '' then
      GRoot := TPath.GetFullPath(ParamStr(GIdx));
  if (GRoot = '') or not TFile.Exists(GRoot) then
  begin
    Writeln(ErrOutput, 'usage: PasTreeDiffHarness <root.dpr> [-p:<platform>] '
      + '[-L<dir>]... [-samples:<N>] [-script:<file>] [-module] [-selftest]');
    Halt(2);
  end;
  GPaths := GPaths + [TPath.GetDirectoryName(GRoot)];
  GTexts := TDictionary<string, string>.Create;
  GVersion := 0;
  GFailedSteps := 0;

  // Initial build - the sampling source and the first donor in the chain.
  LSW := TStopwatch.StartNew;
  LCand := AnalyzeOne(nil);
  Writeln(ErrOutput, Format('initial: %d units in %d ms (%s)',
    [LCand.ModelCount, LSW.ElapsedMilliseconds,
     PlatformInfo(GPlatform).Name]));

  if GScriptFile <> '' then
    LSteps := LoadScript(GScriptFile)
  else
  begin
    LSteps := nil;
    for LKey in SampleUnits(LCand) do
    begin
      LStep.Path := LKey;
      LStep.Kind := ekBody;
      LSteps := LSteps + [LStep];
      LStep.Kind := ekIntf;
      LSteps := LSteps + [LStep];
    end;
  end;
  Writeln(ErrOutput, Format('steps: 1 no-edit + %d edits', [Length(LSteps)]));

  // Step 0 - no edit: a pure warm rebuild must reproduce the project exactly.
  for GIdx := 0 to Length(LSteps) do
  begin
    GStaleKey := '';
    GStaleText := '';
    if GIdx = 0 then
      LLabel := 'no-edit'
    else
    begin
      LStep := LSteps[GIdx - 1];
      LKey := LowerCase(LStep.Path);
      if not GTexts.TryGetValue(LKey, LText) then
        LText := TPasSourceManager.LoadFileTolerant(LStep.Path);
      if not ApplyEdit(LText, LStep.Kind, GIdx, LNew) then
      begin
        Writeln(ErrOutput, Format('step %d: SKIP (no markers) %s',
          [GIdx, LStep.Path]));
        Continue;
      end;
      Inc(GVersion);
      GTexts.AddOrSetValue(LKey, LNew);
      if GSelfTest then
      begin
        GStaleKey := LKey;
        GStaleText := LText;   // the incremental side sees PRE-edit text
      end;
      LLabel := Format('%s %s', [KindName(LStep.Kind),
        TPath.GetFileName(LStep.Path)]);
    end;

    LSW := TStopwatch.StartNew;
    var LHow := 'chain';
    if GModuleMode and (GIdx > 0) then
    begin
      // Stage B: the SAME project takes the edit as a buffer overlay and
      // re-analyzes the one module. Under -selftest the overlay is the
      // PRE-edit text, so the module the comparator sees is genuinely stale.
      if GStaleKey <> '' then
        LCand.SetBuffer(LStep.Path, GStaleText, GVersion)
      else
        LCand.SetBuffer(LStep.Path, GTexts[LKey], GVersion);
      if LCand.AnalyzeModuleOnly(LStep.Path) then
      begin
        // Carry the accepted run's own report too: it names the redo SIZE
        // (module=N) and whether the interface moved, which is the number to
        // pick ModuleRedoLimit from.
        LHow := 'module(' + LCand.StageTimings + ')';
        Inc(GAccepted);
      end
      else
      begin
        // Refused - a host must rebuild. The donor chain does that here.
        // AnalyzeModuleOnly names the reason in StageTimings; carry it into
        // the step line, because WHY a fast path did not fire is the report.
        LHow := 'fallback(' + LCand.StageTimings + ')';
        LNext := AnalyzeOne(LCand, GStaleKey <> '');
        LCand.Free;
        LCand := LNext;
      end;
    end
    else
    begin
      // The default incremental (donor-chain) side; under -selftest it
      // analyzes a DIFFERENT project on edit steps, which the comparator
      // must catch.
      LNext := AnalyzeOne(LCand, GStaleKey <> '');
      LCand.Free;                      // donor consumed; chain moves on
      LCand := LNext;
    end;
    var LCandMs := LSW.ElapsedMilliseconds;

    LSW := TStopwatch.StartNew;
    LTruth := AnalyzeOne(nil);         // ground truth: full fresh pipeline
    var LTruthMs := LSW.ElapsedMilliseconds;

    LOk := CompareStep(LTruth, LCand);
    LTruth.Free;
    // Module mode keeps ONE project across the sequence, so a -selftest step's
    // deliberately stale overlay would poison every later step. Heal it right
    // after the compare: the divergence has served its purpose.
    if GModuleMode and (GStaleKey <> '') then
    begin
      LCand.SetBuffer(LStep.Path, GTexts[LKey], GVersion);
      if not LCand.AnalyzeModuleOnly(LStep.Path) then
      begin
        LNext := AnalyzeOne(LCand);
        LCand.Free;
        LCand := LNext;
      end;
    end;
    var LVerdict: string;
    if GStaleKey <> '' then
    begin
      // Self-test inversion: an equal compare here means the comparator is
      // BLIND - count it as the failure; a mismatch is the pass.
      if LOk then
      begin
        LVerdict := 'SELFTEST FAILED (comparator saw nothing)';
        Inc(GFailedSteps);
      end
      else
      begin
        LVerdict := 'SELFTEST OK (divergence caught)';
        Dec(GFailedSteps);   // CompareStep counted the expected mismatch
      end;
    end
    else if LOk then
      LVerdict := 'OK'
    else
      LVerdict := 'MISMATCH';
    // Guard expectations (module mode, real edits only): a body edit must be
    // accepted, an interface edit must be refused. Only the second direction
    // is a failure - see the header.
    if GModuleMode and (GIdx > 0) and (GStaleKey = '') then
    begin
      // An accepted INTERFACE edit is no longer a failure: since the redo
      // covers the affected consumers (they go back to Phase 1 and rebuild
      // their own references), a shifted symbol index harms nobody. What
      // decides correctness is the comparison against the full pipeline,
      // which every step runs anyway - so this is counted, not judged.
      if (LStep.Kind in [ekIntf, ekConst, ekType]) and
         LHow.StartsWith('module') then
        Inc(GAcceptedIntf)
      else if (LStep.Kind in [ekBody, ekBlank, ekComment]) and
              not LHow.StartsWith('module') then
      begin
        LVerdict := LVerdict + ' (unexpected fallback)';
        Inc(GFellBack);
      end;
    end;
    Writeln(ErrOutput, Format('step %d (%s): %s  %s inc=%d ms full=%d ms  %s',
      [GIdx, LLabel, LVerdict, LHow, LCandMs, LTruthMs, DonorStats(LCand)]));
  end;
  LCand.Free;
  GTexts.Free;

  if GFailedSteps > 0 then
  begin
    if GSelfTest then
      Writeln(ErrOutput, Format(
        'SELF-TEST FAILURE: the comparator missed %d divergent step(s)',
        [GFailedSteps]))
    else
      Writeln(ErrOutput, Format('DIFFERENTIAL FAILURE: %d step(s) mismatched',
        [GFailedSteps]));
    ExitCode := 1;
  end
  else if GSelfTest then
    Writeln(ErrOutput, 'self-test passed: every divergence was caught')
  else
    Writeln(ErrOutput, 'all steps identical');
  if GModuleMode then
    Writeln(ErrOutput, Format(
      'module mode: %d step(s) taken by AnalyzeModuleOnly (%d of them ' +
      'interface edits), %d body edit(s) fell back',
      [GAccepted, GAcceptedIntf, GFellBack]));
end.
