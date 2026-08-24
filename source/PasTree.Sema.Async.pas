unit PasTree.Sema.Async;

{
  Background driver for the staged analyzer. A TPasAsyncSession owns a fresh
  TPasSemaProject and runs TPasSemaProject.AnalyzeStaged on a worker thread,
  so the UI thread never blocks on analysis.

  DOUBLE-BUFFERING ownership model: the worker thread is the SOLE owner of its
  project while building — nothing else touches it — so there are no shared-
  mutable-access races to reason about. When the build finishes, the host polls
  IsDone (e.g. from a form timer), then, ON ITS OWN THREAD, calls TakeProject
  to assume ownership and swaps it in for the previous one. The previous
  project (and its navigator) is freed by the host after the swap, when the UI
  thread is provably not inside it.

  Progress is reported into a lock-guarded snapshot the host reads any time
  (Progress); cancellation is a cooperative Interlocked flag AnalyzeStaged
  polls between modules/waves. Cancel + WaitFor (drain) is what the host does
  on project switch / shutdown before starting the next session.

  Not covered here (deliberately deferred): exposing the project WHILE it is
  still building, so the open module is usable before the whole closure
  finishes. That needs concurrency-safe access to a growing slot array; the
  double-buffered swap-when-ready model above is correct and non-blocking
  without it. AnalyzeStaged still front-loads the open module (APriority), so
  it is ready first WITHIN the build.
}

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  PasTree.Platforms,
  PasTree.Sema.Project;

type
  TPasAsyncSession = class
  private type
    TWorker = class(TThread)
    private
      FOwner: TPasAsyncSession;
    protected
      procedure Execute; override;
    end;
  private
    FProject: TPasSemaProject;      // owned until TakeProject hands it off
    FWorker: TWorker;
    FRoots, FPriority: TArray<string>;
    FCancelFlag: Integer;           // Interlocked 0/1
    FDoneFlag: Integer;             // Interlocked 0/1
    FMainResultId: Integer;
    FLock: TCriticalSection;        // guards FProgress and FError
    FProgress: TPasStagedProgress;
    FError: string;                 // worker exception, if any ('' = none)
    FStarted: Boolean;
    // Single-module mode (CreateForModule): the worker calls
    // AnalyzeModuleOnly for FModulePath instead of a staged build.
    FModuleMode: Boolean;
    FModulePath: string;
    FModuleAccepted: Boolean;       // written before FDoneFlag, read after
    procedure RunBody;
  public
    { Creates the session and its (empty) project. Call SetBuffer for any
      unsaved editor content, then Start. ARoots are the closure roots (a
      project main source, or the files of a directory); APriority names files
      to analyze first (the open editor module + its direct uses). }
    constructor Create(APlatform: TPasPlatform;
      const ASearchPaths, AExtraDefines, ARoots, APriority: TArray<string>);
    { SINGLE-MODULE mode (incremental plan, stage B), the keystroke path: takes
      OWNERSHIP of AProject — the host's last-good, fully analyzed project —
      and, on Start, re-analyzes APath in place via
      TPasSemaProject.AnalyzeModuleOnly. Set the edited buffer with SetBuffer
      before Start, exactly like a full session.

      After IsDone, ModuleAccepted says whether the fast path ran. Either way
      the project comes back through TakeProject UNCHANGED-or-updated and
      still consistent: on a refusal (interface change, and every other case
      AnalyzeModuleOnly lists) the host takes it back untouched and starts an
      ordinary session over it, passing it as the parse donor. No progress is
      reported — the whole point is that there are no stages to report. }
    constructor CreateForModule(AProject: TPasSemaProject;
      const APath: string);
    { Cancels the worker, waits for it to drain, then frees the project if it
      was never taken. Safe to call at any time. }
    destructor Destroy; override;
    { Editor-host buffer override — forwarded to the project. Call BEFORE
      Start (the worker reads buffers as it parses). AVersion is the host's
      version stamp for the document; after TakeProject the host reads it
      back via the project's BufferVersion and compares against the version
      it holds NOW — unequal means this result was computed from older text
      and its positions may be stale. }
    procedure SetBuffer(const APath, AText: string; AVersion: Integer = 0);
    { Configuration forwarded to the project. Call BEFORE Start. }
    procedure SetNamespaces(const ANamespaces: TArray<string>);
    procedure AddUnitAlias(const AAlias, AReal: string);
    { Parse reuse — forwarded to TPasSemaProject.AdoptParseDonor (see there
      for the config gate and what a hit reuses). Call BEFORE Start, after
      the other configuration calls (the gate compares namespaces/aliases):
      the session's worker owns the project once the thread exists, the same
      "set BEFORE Start" contract as SetBuffer. ADonor — the host's
      still-alive last-good project — must outlive this session's build; the
      host's existing free-after-TakeProject-swap order already guarantees
      that. False = configuration mismatch, donor refused (log it; the run
      proceeds donor-less). }
    function SetParseDonor(ADonor: TPasSemaProject): Boolean;
    { Forwarded to the inner project: True runs the analysis stages
      sequentially (the inner parallelism still runs on THIS worker thread
      either way). Set BEFORE Start. }
    procedure SetSingleThreadedInner(AValue: Boolean);
    { Forwarded to the inner project: report a member after a dot that no lookup
      resolved. OFF is the error-TOLERANT mode an editor wants; ON is what a
      compiler front end needs. Set BEFORE Start — it changes what the analysis
      produces, not how the result is displayed. }
    procedure SetReportUnresolvedMembers(AValue: Boolean);
    { Same contract for ReportGuessedIfs — the residual-$IF exotica detector
      (PPIF/PPBAD diagnostics); see TPasSemaProject.ReportGuessedIfs. }
    procedure SetReportGuessedIfs(AValue: Boolean);
    procedure Start;
    { Request cooperative cancellation; the worker stops at the next module/
      wave boundary. Does not block. }
    procedure Cancel;
    { Blocks until the worker finishes (or was cancelled and drained). }
    procedure WaitFor;
    function IsDone: Boolean;
    { A thread-safe snapshot of the latest progress. }
    function Progress: TPasStagedProgress;
    { Non-empty if the worker died on an exception — the host should log it
      (a silently swallowed background failure looks like a hang). The built
      project may be partial but is internally consistent (same guarantee as
      a cancellation). }
    function LastError: string;
    { After IsDone, transfers project ownership to the caller (the session no
      longer frees it); returns nil if not finished yet or already taken. }
    function TakeProject: TPasSemaProject;
    { The model id of ARoots[0] in the built project (valid once done). }
    function MainResultId: Integer;
    { CreateForModule sessions only: did the single-module fast path run?
      Valid once IsDone. False = refused, the project is untouched and the
      host must rebuild (see CreateForModule). Always False for a normal
      session. }
    function ModuleAccepted: Boolean;
  end;

implementation

{ TPasAsyncSession.TWorker }

procedure TPasAsyncSession.TWorker.Execute;
begin
  FOwner.RunBody;
end;

{ TPasAsyncSession }

constructor TPasAsyncSession.Create(APlatform: TPasPlatform;
  const ASearchPaths, AExtraDefines, ARoots, APriority: TArray<string>);
begin
  inherited Create;
  FProject := TPasSemaProject.Create(APlatform, ASearchPaths, AExtraDefines);
  FRoots := ARoots;
  FPriority := APriority;
  FCancelFlag := 0;
  FDoneFlag := 0;
  FMainResultId := -1;
  FLock := TCriticalSection.Create;
  FProgress := Default(TPasStagedProgress);
  FStarted := False;
end;

constructor TPasAsyncSession.CreateForModule(AProject: TPasSemaProject;
  const APath: string);
begin
  inherited Create;
  FProject := AProject;   // ownership transferred; TakeProject hands it back
  FRoots := nil;
  FPriority := nil;
  FCancelFlag := 0;
  FDoneFlag := 0;
  FMainResultId := -1;
  FLock := TCriticalSection.Create;
  FProgress := Default(TPasStagedProgress);
  FStarted := False;
  FModuleMode := True;
  FModulePath := APath;
  FModuleAccepted := False;
end;

destructor TPasAsyncSession.Destroy;
begin
  Cancel;
  if FWorker <> nil then
  begin
    FWorker.WaitFor;
    FWorker.Free;
  end;
  FProject.Free;   // nil if TakeProject already handed it off
  FLock.Free;
  inherited;
end;

procedure TPasAsyncSession.SetBuffer(const APath, AText: string;
  AVersion: Integer);
begin
  FProject.SetBuffer(APath, AText, AVersion);
end;

procedure TPasAsyncSession.SetNamespaces(const ANamespaces: TArray<string>);
begin
  FProject.SetNamespaces(ANamespaces);
end;

procedure TPasAsyncSession.AddUnitAlias(const AAlias, AReal: string);
begin
  FProject.AddUnitAlias(AAlias, AReal);
end;

function TPasAsyncSession.SetParseDonor(ADonor: TPasSemaProject): Boolean;
begin
  Result := FProject.AdoptParseDonor(ADonor);
end;

procedure TPasAsyncSession.SetSingleThreadedInner(AValue: Boolean);
begin
  FProject.SingleThreaded := AValue;
end;

procedure TPasAsyncSession.SetReportUnresolvedMembers(AValue: Boolean);
begin
  FProject.ReportUnresolvedMembers := AValue;
end;

procedure TPasAsyncSession.SetReportGuessedIfs(AValue: Boolean);
begin
  FProject.ReportGuessedIfs := AValue;
end;

procedure TPasAsyncSession.RunBody;
begin
  try
    try
      if FModuleMode then
      begin
        // Cancellation is not offered here: the call is milliseconds, and a
        // half-applied module swap has no meaning (it is one commit point).
        FModuleAccepted := FProject.AnalyzeModuleOnly(FModulePath);
        if FModuleAccepted then
          FMainResultId := FProject.ModelIdOf(FModulePath);
        Exit;
      end;
      FMainResultId := FProject.AnalyzeStaged(FRoots, FPriority,
        function: Boolean
        begin
          Result := TInterlocked.CompareExchange(FCancelFlag, 0, 0) <> 0;
        end,
        procedure(AProgress: TPasStagedProgress)
        begin
          FLock.Enter;
          try
            FProgress := AProgress;
          finally
            FLock.Leave;
          end;
        end);
    except
      // Never let the worker die silently: capture for the host to log.
      // The project stays partial-but-consistent (published slots only).
      on E: Exception do
      begin
        FLock.Enter;
        try
          FError := E.ClassName + ': ' + E.Message;
        finally
          FLock.Leave;
        end;
      end;
    end;
  finally
    TInterlocked.Exchange(FDoneFlag, 1);
  end;
end;

procedure TPasAsyncSession.Start;
begin
  if FStarted then
    Exit;
  FStarted := True;
  FWorker := TWorker.Create(True);   // suspended
  FWorker.FOwner := Self;
  FWorker.FreeOnTerminate := False;  // we WaitFor + Free it ourselves
  FWorker.Start;
end;

procedure TPasAsyncSession.Cancel;
begin
  TInterlocked.Exchange(FCancelFlag, 1);
end;

procedure TPasAsyncSession.WaitFor;
begin
  if FWorker <> nil then
    FWorker.WaitFor;
end;

function TPasAsyncSession.IsDone: Boolean;
begin
  Result := TInterlocked.CompareExchange(FDoneFlag, 0, 0) <> 0;
end;

function TPasAsyncSession.Progress: TPasStagedProgress;
begin
  FLock.Enter;
  try
    Result := FProgress;
  finally
    FLock.Leave;
  end;
end;

function TPasAsyncSession.LastError: string;
begin
  FLock.Enter;
  try
    Result := FError;
  finally
    FLock.Leave;
  end;
end;

function TPasAsyncSession.TakeProject: TPasSemaProject;
begin
  if IsDone then
  begin
    Result := FProject;
    FProject := nil;   // ownership transferred; Destroy no longer frees it
  end
  else
    Result := nil;
end;

function TPasAsyncSession.ModuleAccepted: Boolean;
begin
  Result := FModuleAccepted;
end;

function TPasAsyncSession.MainResultId: Integer;
begin
  Result := FMainResultId;
end;

end.
