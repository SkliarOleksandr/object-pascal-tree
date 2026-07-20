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
    FLock: TCriticalSection;        // guards FProgress
    FProgress: TPasStagedProgress;
    FStarted: Boolean;
    procedure RunBody;
  public
    { Creates the session and its (empty) project. Call SetBuffer for any
      unsaved editor content, then Start. ARoots are the closure roots (a
      project main source, or the files of a directory); APriority names files
      to analyze first (the open editor module + its direct uses). }
    constructor Create(APlatform: TPasPlatform;
      const ASearchPaths, AExtraDefines, ARoots, APriority: TArray<string>);
    { Cancels the worker, waits for it to drain, then frees the project if it
      was never taken. Safe to call at any time. }
    destructor Destroy; override;
    { Editor-host buffer override — forwarded to the project. Call BEFORE
      Start (the worker reads buffers as it parses). }
    procedure SetBuffer(const APath, AText: string);
    { Configuration forwarded to the project. Call BEFORE Start. }
    procedure SetNamespaces(const ANamespaces: TArray<string>);
    procedure AddUnitAlias(const AAlias, AReal: string);
    procedure Start;
    { Request cooperative cancellation; the worker stops at the next module/
      wave boundary. Does not block. }
    procedure Cancel;
    { Blocks until the worker finishes (or was cancelled and drained). }
    procedure WaitFor;
    function IsDone: Boolean;
    { A thread-safe snapshot of the latest progress. }
    function Progress: TPasStagedProgress;
    { After IsDone, transfers project ownership to the caller (the session no
      longer frees it); returns nil if not finished yet or already taken. }
    function TakeProject: TPasSemaProject;
    { The model id of ARoots[0] in the built project (valid once done). }
    function MainResultId: Integer;
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

procedure TPasAsyncSession.SetBuffer(const APath, AText: string);
begin
  FProject.SetBuffer(APath, AText);
end;

procedure TPasAsyncSession.SetNamespaces(const ANamespaces: TArray<string>);
begin
  FProject.SetNamespaces(ANamespaces);
end;

procedure TPasAsyncSession.AddUnitAlias(const AAlias, AReal: string);
begin
  FProject.AddUnitAlias(AAlias, AReal);
end;

procedure TPasAsyncSession.RunBody;
begin
  try
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

function TPasAsyncSession.MainResultId: Integer;
begin
  Result := FMainResultId;
end;

end.
