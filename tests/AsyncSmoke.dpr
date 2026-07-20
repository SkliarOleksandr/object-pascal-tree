program AsyncSmoke;

{
  Staged (incremental) analysis — TPasSemaProject.AnalyzeStaged — is the engine
  the background async parser drives. These tests run it SYNCHRONOUSLY (no
  threads, so no flakiness) and assert:

  1. RESULT EQUIVALENCE: the staged two-wave+finalizer build produces the same
     final state (loaded units, per-unit diagnostics, cross-unit resolutions)
     as the batch AnalyzeProject over the same closure. Compared order-
     independently (by unit name + target name), since model ids depend on
     discovery order.
  2. The interface->full snapshot upgrade really happens (a unit is parsed
     interface-only, then upgraded to a full tree) and an implementation-only
     dependency, invisible in the interface wave, is discovered in wave 2.
  3. Cancellation between waves leaves a partial-but-consistent project (no
     crash / no leak) rather than a completed one.
  4. Progress counters advance and the total grows as the closure is found.
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
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
  PasTree.Sema.Diagnostics in '..\source\PasTree.Sema.Diagnostics.pas',
  PasTree.Sema.Model in '..\source\PasTree.Sema.Model.pas',
  PasTree.Sema.Builtins in '..\source\PasTree.Sema.Builtins.pas',
  PasTree.Sema.Resolver in '..\source\PasTree.Sema.Resolver.pas',
  PasTree.Sema.Dump in '..\source\PasTree.Sema.Dump.pas',
  PasTree.Sema.Project in '..\source\PasTree.Sema.Project.pas';

var
  GPassed, GFailed: Integer;

procedure Ok(const AName: string; ACond: Boolean);
begin
  if ACond then
    Inc(GPassed)
  else
  begin
    Inc(GFailed);
    Writeln('FAIL: ', AName);
  end;
end;

// Order-independent canonical summary of a project's final state: every unit
// (sorted by name), its diagnostic codes (sorted), and its cross-unit
// resolutions rendered by TARGET NAME (not id), sorted.
function CanonicalDump(AProj: TPasSemaProject): string;
var
  LUnitLines: TList<string>;
  LMid, LNode, LI: Integer;
  LM: TPasSemaModel;
  LDiags, LRefs: TList<string>;
  LExt: TPasExtRef;
  LSb: TStringBuilder;
begin
  LUnitLines := TList<string>.Create;
  LSb := TStringBuilder.Create;
  try
    for LMid := 0 to AProj.ModelCount - 1 do
    begin
      LM := AProj.Model(LMid);
      LDiags := TList<string>.Create;
      LRefs := TList<string>.Create;
      try
        for LI := 0 to High(LM.Diags) do
          LDiags.Add(LM.Diags[LI].Code);
        LDiags.Sort;
        for LNode := 0 to High(LM.Tree.Nodes) do
          if LM.ExtRefMap.TryGetValue(LNode, LExt) then
            LRefs.Add(Format('%s->%s.%s',
              [LM.Tree.NodeText(LNode),
               AProj.Model(LExt.UnitId).UnitNameLower,
               AProj.Model(LExt.UnitId).Symbols[LExt.Sym].NameLower]));
        LRefs.Sort;
        LUnitLines.Add(Format('UNIT %s | diags=[%s] | refs=[%s]',
          [LM.UnitNameLower, string.Join(',', LDiags.ToArray),
           string.Join(',', LRefs.ToArray)]));
      finally
        LDiags.Free;
        LRefs.Free;
      end;
    end;
    LUnitLines.Sort;
    for var S in LUnitLines do
      LSb.AppendLine(S);
    Result := LSb.ToString;
  finally
    LUnitLines.Free;
    LSb.Free;
  end;
end;

const
  MAIN_DPR =
    'program App;'#10 +
    'uses UnitA, UnitB;'#10 +
    'begin'#10 +
    'end.'#10;
  // UnitA: interface exposes TThing + KA; its IMPLEMENTATION uses UnitC — an
  // implementation-only dependency the interface wave cannot see (exercises
  // wave-2 discovery).
  UNIT_A =
    'unit UnitA;'#10 +
    'interface'#10 +
    'const KA = 7;'#10 +
    'type TThing = class'#10 +
    '  FV: Integer;'#10 +
    '  function Val: Integer;'#10 +
    'end;'#10 +
    'implementation'#10 +
    'uses UnitC;'#10 +
    'function TThing.Val: Integer;'#10 +
    'begin'#10 +
    '  Result := FV + CC_MARK;'#10 +
    'end;'#10 +
    'end.'#10;
  // UnitB: interface uses UnitA, references its exported names.
  UNIT_B =
    'unit UnitB;'#10 +
    'interface'#10 +
    'uses UnitA;'#10 +
    'var GT: TThing;'#10 +
    'const GK = KA;'#10 +
    'implementation'#10 +
    'end.'#10;
  UNIT_C =
    'unit UnitC;'#10 +
    'interface'#10 +
    'const CC_MARK = 100;'#10 +
    'implementation'#10 +
    'end.'#10;
  // Minimal implicit System (EnsureSystemUnit resolves "System" by name).
  UNIT_SYS =
    'unit System;'#10 +
    'interface'#10 +
    'type'#10 +
    '  TObject = class end;'#10 +
    '  Integer = _INT;'#10 +
    'implementation'#10 +
    'end.'#10;

function BatchProject(const ADir: string): TPasSemaProject;
begin
  Result := TPasSemaProject.Create(pfWin32, [ADir], []);
  Result.AnalyzeProject(TPath.Combine(ADir, 'App.dpr'));
end;

function StagedProject(const ADir: string;
  const APriority: TArray<string>;
  const ACancelled: TFunc<Boolean> = nil;
  const AOnProgress: TProc<TPasStagedProgress> = nil): TPasSemaProject;
begin
  Result := TPasSemaProject.Create(pfWin32, [ADir], []);
  Result.AnalyzeStaged([TPath.Combine(ADir, 'App.dpr')], APriority,
    ACancelled, AOnProgress);
end;

var
  LDir: string;
  LBatch, LStaged, LCancelled: TPasSemaProject;
  LMaxTotal, LMaxFull, LProgressCalls: Integer;
  LSawIntfPhase, LSawFullPhase, LSawDone: Boolean;
  LMid: Integer;
begin
  ReportMemoryLeaksOnShutdown := True;
  GPassed := 0;
  GFailed := 0;
  LDir := TPath.Combine(TPath.GetTempPath, 'pastree_async');
  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);
  TDirectory.CreateDirectory(LDir);
  TFile.WriteAllText(TPath.Combine(LDir, 'App.dpr'), MAIN_DPR);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitA.pas'), UNIT_A);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitB.pas'), UNIT_B);
  TFile.WriteAllText(TPath.Combine(LDir, 'UnitC.pas'), UNIT_C);
  TFile.WriteAllText(TPath.Combine(LDir, 'System.pas'), UNIT_SYS);

  // ---- 1. Result equivalence: staged == batch ----
  LBatch := BatchProject(LDir);
  LStaged := StagedProject(LDir, []);
  try
    Ok('staged loaded the same unit count as batch',
      LStaged.ModelCount = LBatch.ModelCount);
    Ok('staged final state == batch final state (order-independent)',
      CanonicalDump(LStaged) = CanonicalDump(LBatch));

    // Every unit is cross-ready after a full staged build.
    var LAllCross := True;
    for LMid := 0 to LStaged.ModelCount - 1 do
      if (LStaged.Model(LMid).UnitNameLower <> 'system') and
         (LStaged.ModuleStatus(LMid) <> msCrossReady) then
        LAllCross := False;
    Ok('staged: all non-System units reached msCrossReady', LAllCross);

    // Wave-2 discovery: UnitC is an implementation-only dependency of UnitA,
    // invisible to the interface wave — it must still be loaded.
    var LHasC := False;
    for LMid := 0 to LStaged.ModelCount - 1 do
      if LStaged.Model(LMid).UnitNameLower = 'unitc' then
        LHasC := True;
    Ok('staged: implementation-only dependency UnitC discovered in wave 2',
      LHasC);

    // The cross-unit const use (UnitA impl: CC_MARK from UnitC) resolved —
    // proves the full (not interface-only) trees drove the final analysis.
    var LCResolved := False;
    for LMid := 0 to LStaged.ModelCount - 1 do
      if LStaged.Model(LMid).UnitNameLower = 'unita' then
      begin
        var LM := LStaged.Model(LMid);
        var LExt: TPasExtRef;
        for var LNode := 0 to High(LM.Tree.Nodes) do
          if (LM.Tree.Nodes[LNode].Kind = nkIdent) and
             SameText(LM.Tree.NodeText(LNode), 'CC_MARK') and
             LM.ExtRefMap.TryGetValue(LNode, LExt) then
            LCResolved := True;
      end;
    Ok('staged: UnitA impl body resolves CC_MARK cross-unit into UnitC',
      LCResolved);
  finally
    LStaged.Free;
    LBatch.Free;
  end;

  // ---- 2. Progress: total grows, waves observed, ends 'done' ----
  LMaxTotal := 0;
  LMaxFull := 0;
  LProgressCalls := 0;
  LSawIntfPhase := False;
  LSawFullPhase := False;
  LSawDone := False;
  LStaged := StagedProject(LDir, [],
    nil,
    procedure(AP: TPasStagedProgress)
    begin
      Inc(LProgressCalls);
      if AP.Total > LMaxTotal then
        LMaxTotal := AP.Total;
      if AP.FullDone > LMaxFull then
        LMaxFull := AP.FullDone;
      if AP.Phase = 'intf' then
        LSawIntfPhase := True;
      if AP.Phase = 'full' then
        LSawFullPhase := True;
      if AP.Phase = 'done' then
        LSawDone := True;
    end);
  try
    Ok('progress: callback fired', LProgressCalls > 0);
    Ok('progress: saw the interface wave', LSawIntfPhase);
    Ok('progress: saw the full wave', LSawFullPhase);
    Ok('progress: ended with phase=done', LSawDone);
    Ok('progress: total grew to the full closure',
      LMaxTotal = LStaged.ModelCount);
    Ok('progress: full-done advanced', LMaxFull > 0);
  finally
    LStaged.Free;
  end;

  // ---- 3. Cancellation between waves -> partial but consistent ----
  // Cancel as soon as the full wave begins: some units are interface-ready,
  // nothing is cross-ready, no crash, no leak.
  LCancelled := TPasSemaProject.Create(pfWin32, [LDir], []);
  try
    var LSeenFull := False;
    LCancelled.AnalyzeStaged([TPath.Combine(LDir, 'App.dpr')], [],
      function: Boolean
      begin
        Result := LSeenFull;
      end,
      procedure(AP: TPasStagedProgress)
      begin
        if AP.Phase = 'full' then
          LSeenFull := True;
      end);
    // At least the interface wave completed; the cross finalizer did not run.
    var LAnyIntf := False;
    var LAnyCross := False;
    for LMid := 0 to LCancelled.ModelCount - 1 do
    begin
      if LCancelled.ModuleStatus(LMid) >= msIntfReady then
        LAnyIntf := True;
      if LCancelled.ModuleStatus(LMid) = msCrossReady then
        LAnyCross := True;
    end;
    Ok('cancel: some units reached interface-ready before cancel', LAnyIntf);
    Ok('cancel: cross finalizer did NOT run (nothing cross-ready)',
      not LAnyCross);
  finally
    LCancelled.Free;
  end;

  if TDirectory.Exists(LDir) then
    TDirectory.Delete(LDir, True);

  Writeln(Format('=== AsyncSmoke: %d passed, %d failed ===',
    [GPassed, GFailed]));
  if GFailed > 0 then
    ExitCode := 1;
end.
