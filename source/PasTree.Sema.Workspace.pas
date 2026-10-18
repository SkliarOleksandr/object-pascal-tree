unit PasTree.Sema.Workspace;

{ LIGHT MODE, full answers without the host's help (docs/library-light-mode.md,
  "The workspace"). A TPasWorkspace owns a TPasSemaProject and its
  TPasNavigator, and every query a light unit's body can change runs through
  it: the query's demand (TPasNavigator.Demand*, PasTree.Sema.Lint.DemandLint),
  TPasSemaProject.EnsureFull until the demand is empty, a rebuild when
  EnsureFull asks for one, an escalation to a full analysis when it is
  cheaper - and then the query, on the navigator over the models it changed.
  The answer is the full analysis's; Status.NotSearched is 0 unless the
  caller cancelled or asked for a partial answer.

  A host does not call Demand* or EnsureFull itself: one implementation, the
  one the light oracle (tools/PasTreeLightSmoke) tests, and a new query cannot
  forget its demand. In a full analysis every demand is empty and a
  workspace query is the navigator's own call.

  Identities. A query may replace models (a promotion) or the whole project
  (a rebuild, an escalation): model ids and symbol indexes taken before it
  are not valid after it. A workspace query therefore takes what survives -
  a symbol by TPasSymbolKey (file, name, declaration site), a file or a
  position by path - and its answer is in terms of the CURRENT Project and
  Nav, valid until the next workspace query that changes them (Generation
  moves then; Status.Changed says so).

  Threading. A workspace query runs on the caller's thread and may change
  the project, so the caller must own the project exclusively for its
  duration: no TPasAsyncSession running over it or with it as parse donor.
  The workspace enforces the part it can see - Release / Adopt hand the
  project to a session and back, Lend / EndLend mark it a session's donor -
  and refuses a query that would have to change a project it does not own
  (EPasWorkspaceBusy). }

interface

uses
  System.SysUtils,
  System.Diagnostics,
  System.Generics.Collections,
  PasTree.Types,
  PasTree.Ast,
  PasTree.Sema.Model,
  PasTree.Sema.Project,
  PasTree.Sema.Nav,
  PasTree.Sema.Lint;

type
  EPasWorkspaceBusy = class(Exception);

const
  // A workspace query's refusal when its symbol is not in the analysis.
  NOT_ANALYZED = 'the symbol is not in the analysis';

type
  { What an escalation does (decision D8 of the light-mode plan: run it, with
    progress). esRun - rebuild without light paths when EnsureFull says that
    is cheaper; esAsk - ask OnAskEscalate first, a refusal is esNever;
    esNever - never rebuild for it: the demand is met unit by unit however
    large (EnsureFull with no escalation bound). }
  TPasEscalation = (esRun, esAsk, esNever);

  TPasQueryStage = (qsPromote, qsRebuild, qsEscalate);

  TPasQueryProgress = record
    Stage: TPasQueryStage;
    Round: Integer;           // qsPromote: the EnsureFull round, from 1
    Units: Integer;           // qsPromote: the units of this round's demand
    Staged: TPasStagedProgress;   // qsRebuild / qsEscalate: the analysis
    Text: string;             // one line for a status bar
  end;

  { The options of every workspace query (TPasWorkspace.Options). The zero
    value is the full analysis's answer: Default(TPasQueryOptions) completes,
    escalates when that is cheaper, reports nothing and cannot be cancelled. }
  TPasQueryOptions = record
    { True: today's fast answer - no promotion, whatever light bodies hold
      is left out and Status.NotSearched counts it. False (the default):
      the full analysis's answer. }
    Partial: Boolean;
    Escalation: TPasEscalation;
    { Polled between EnsureFull rounds and by a rebuild's analysis (on its
      worker threads too: thread-safe and cheap, as AnalyzeStaged's
      ACancelled). True: the query answers with what is analyzed so far,
      Status.Cancelled set and NotSearched counting the rest. }
    Cancelled: TFunc<Boolean>;
    OnProgress: TProc<TPasQueryProgress>;
    { esAsk: the escalation's reason (EnsureFull's note); True runs it. }
    OnAskEscalate: TFunc<string, Boolean>;
  end;

  { What the last workspace query did. }
  TPasQueryStatus = record
    { The units whose bodies the answer needed and did not have: 0 unless
      Partial, Cancelled, or a unit EnsureFull refused (Refused). }
    NotSearched: Integer;
    Cancelled: Boolean;
    Escalated: Boolean;       // this query rebuilt the project full
    Rebuilt: Boolean;         // ... or rebuilt it light (eoNeedsRebuild)
    Changed: Boolean;         // Project / Nav replaced or their models changed
    Rounds, Promoted, Loaded, Preprocessed: Integer;
    Refused: TArray<string>;  // EnsureFull's 'file: reason'
    Ms: Int64;                // the demand's cost, the query excluded
    Note: string;
  end;

  { A declaration by what survives a promotion and a rebuild: the declaring
    model's file, the name, and where the name is written (an include file,
    maybe). A builtin (no declaration) has no key: Valid is False. }
  TPasSymbolKey = record
    MainFile: string;
    DeclFile: string;
    Name: string;
    Line, Col: Integer;
    function Valid: Boolean;
    class function Make(AProject: TPasSemaProject;
      AMid, ASym: Integer): TPasSymbolKey; static;
    { The symbol in AProject; False when its unit is not loaded there or no
      symbol of that name is declared at that site. }
    function Resolve(AProject: TPasSemaProject; out AMid, ASym: Integer): Boolean;
  end;

  { A new project configured as the host configures its analysis (search
    paths, defines, namespaces, aliases, switches, buffers, LightPaths) and
    NOT analyzed: the workspace's rebuilds. The workspace clears LightPaths
    on an escalation, adopts the current project as parse donor and analyzes
    it over the current project's roots (TPasSemaProject.AnalyzedRoots). }
  TPasProjectFactory = reference to function: TPasSemaProject;

  TPasPositionQuery<T> = reference to function(ANav: TPasNavigator;
    AMid: Integer): T;

  TPasSymDemandOf = reference to function(ANav: TPasNavigator;
    AMid, ASym: Integer): TPasDemand;

  TPasWorkspace = class
  private
    FProject: TPasSemaProject;
    FNav: TPasNavigator;
    FFactory: TPasProjectFactory;
    FLibraryPaths: TArray<string>;
    FGeneration: Integer;
    FNavModelGen: Integer;     // FProject.ModelGeneration when FNav was made
    FEscalated: Boolean;
    FReleased: Boolean;
    FLent: Integer;
    FOptions: TPasQueryOptions;
    FStatus: TPasQueryStatus;
    procedure SetLibraryPaths(const AValue: TArray<string>);
    procedure NewNav;
    procedure Swap(ANew: TPasSemaProject);
    procedure CheckOwned;
    procedure Progress(AStage: TPasQueryStage; ARound, AUnits: Integer;
      const AStaged: TPasStagedProgress; const AText: string);
    function IsCancelled: Boolean;
    function Rebuild(AEscalate: Boolean): Boolean;
    function AllowEscalation(const ANote: string): Boolean;
    { Demand -> EnsureFull -> again, a rebuild or an escalation on the way;
      FStatus filled. }
    procedure Prepare(const ADemand: TPasDemandFunc);
    procedure Finish;
    function SymDemand(const AKey: TPasSymbolKey;
      const AOf: TPasSymDemandOf): TPasDemandFunc;
    function FileDemand(const AFile: string): TPasDemandFunc;
    function PositionDemand(const AFile: string;
      ALine, ACol: Integer): TPasDemandFunc;
    class function ExtRefsOf(AProject: TPasSemaProject;
      const AKeys: TArray<TPasSymbolKey>): TArray<TPasExtRef>; static;
    function Sym(const AKey: TPasSymbolKey; out AMid, ASym: Integer): Boolean;
    function MidsOf(const AFiles: TArray<string>): TArray<Integer>;
    function MidOf(const AFile: string): Integer;
  public
    { Takes ownership of AProject - analyzed, finished. AFactory: the
      rebuilds (nil: none - a demand that needs one is left NotSearched,
      and an escalation is met unit by unit instead). }
    constructor Create(AProject: TPasSemaProject;
      const AFactory: TPasProjectFactory);
    destructor Destroy; override;

    { ---- ownership ---- }
    { A new analysis of the host's own (an edit, a reconfiguration): frees
      the old project and navigator, takes AProject. Ends a Release. }
    procedure Adopt(AProject: TPasSemaProject);
    { Hands the project out - to a module session (TPasAsyncSession.
      CreateForModule / CreateForPromotion take ownership) - the navigator
      freed; every query refuses (EPasWorkspaceBusy) until Adopt. }
    function Release: TPasSemaProject;
    { The project is a running session's parse donor until EndLend: the
      queries still answer, but one whose demand is not empty refuses
      (EPasWorkspaceBusy) unless Options.Partial - it would have to change
      the donor under the session. Nests. }
    function Lend: TPasSemaProject;
    procedure EndLend;

    property Project: TPasSemaProject read FProject;
    property Nav: TPasNavigator read FNav;
    property Factory: TPasProjectFactory read FFactory write FFactory;
    { Kept across every navigator the workspace creates. }
    property LibraryPaths: TArray<string> read FLibraryPaths write SetLibraryPaths;
    { Moves whenever Project or Nav is replaced (a promotion changes the
      models, a rebuild the project): ids a host cached from an older
      generation are stale. }
    property Generation: Integer read FGeneration;
    { An escalation happened: the project is full and stays full (decision
      D9) - the factory's later projects get no LightPaths either, and a host
      configuring its own next analysis leaves them off. }
    property Escalated: Boolean read FEscalated;
    property Options: TPasQueryOptions read FOptions write FOptions;
    property Status: TPasQueryStatus read FStatus;

    { ---- the references family ---- }
    function FindReferences(const AKey: TPasSymbolKey;
      AImplHeaders: Boolean = False; AFormFiles: Boolean = False;
      const AOnlyFile: string = ''): TArray<TPasRefHit>;
    function FindAssignments(const AKey: TPasSymbolKey): TArray<TPasRefHit>;
    function CollectReferencesOfAll(const AKeys: TArray<TPasSymbolKey>;
      AAssignOnly: Boolean = False;
      const AOnlyFile: string = ''): TArray<TPasRefHit>;
    function FindCreations(const AKey: TPasSymbolKey): TArray<TPasRefHit>;
    function FindDestructions(const AKey: TPasSymbolKey): TArray<TPasRefHit>;
    { ---- the hierarchy family ---- }
    function FindDescendants(const AKey: TPasSymbolKey): TArray<TPasDescendantHit>;
    function FindOverrides(const AKey: TPasSymbolKey): TArray<TPasOverrideHit>;
    function FindImplementations(const AKey: TPasSymbolKey): TArray<TPasImplHit>;
    function FindInterfaceImplementors(const AKey: TPasSymbolKey): TArray<TPasImplHit>;
    function RenameFamily(const AKey: TPasSymbolKey;
      out AMembers: TArray<TPasRenameFamilyMember>; out AError: string): Boolean;
    { ---- names ---- }
    function FindBuiltinReferences(const AName: string;
      const AOnlyFile: string = ''): TArray<TPasRefHit>;
    function FindDefines: TArray<TPasDefineSite>;
    function FindDefineReferences(const AName: string): TArray<TPasDefineHit>;
    { ---- renames ---- }
    function PlanRename(const AKey: TPasSymbolKey; const ANewName: string;
      out AEdits: TArray<TPasRenameEdit>;
      out ACarried: TArray<TPasCarriedRename>;
      out AFamily: TArray<TPasRenameFamilyMember>;
      out AError: string): Boolean;
    { ---- one file, one position ---- }
    { The routine's implementation node, in Nav's model AMid of its unit. }
    function RoutineImplNode(const AKey: TPasSymbolKey; out AMid: Integer): Integer;
    function SemanticTokens(const AFile: string): TArray<TPasSemanticToken>;
    { Any question about one file - its outline, its tokens, its bodies -
      once the file is fully analyzed (DemandFile; DemandFilePath for a file
      only a full closure has). AQuery gets the file's model id in Nav; it
      is not called (Default(T)) when the file is not in the closure. }
    function InFile<T>(const AFile: string;
      const AQuery: TPasPositionQuery<T>): T;
    { Any position question - IdentAt, SymbolAt, GotoDeclaration,
      GotoImplementation, DefinesAt, OptionsAt, the *At family - once the
      position's demand (DemandPosition) is met; as InFile otherwise. }
    function At<T>(const AFile: string; ALine, ACol: Integer;
      const AQuery: TPasPositionQuery<T>): T;
    { ---- the uses lint (PasTree.Sema.Lint) ---- }
    function FindUnusedUses(const AFiles: TArray<string>;
      AOptions: TPasLintOptions = []): TArray<TPasUnusedUse>;
    function FindUnreferencedUnits(const AFiles: TArray<string>;
      AOptions: TPasLintOptions = []): TArray<TPasUnreferencedUnit>;
  end;

implementation

uses
  System.Math,
  System.StrUtils;

const
  // A demand that keeps moving: each round loads units the closure had not
  // loaded, so it ends; the bound is a guard (PasEnsureDemand's).
  MAX_ROUNDS = 32;

{ TPasSymbolKey }

function TPasSymbolKey.Valid: Boolean;
begin
  Result := (MainFile <> '') and (Name <> '');
end;

class function TPasSymbolKey.Make(AProject: TPasSemaProject; AMid,
  ASym: Integer): TPasSymbolKey;
var
  LM: TPasSemaModel;
begin
  Result := Default(TPasSymbolKey);
  if (AProject = nil) or (AMid < 0) or (AMid >= AProject.ModelCount) then
    Exit;
  LM := AProject.Model(AMid);
  if (ASym < 0) or (ASym >= LM.SymCount) or
     (LM.Symbols[ASym].DeclNode = NIL_NODE) then
    Exit;
  if not AProject.NodeSite(AMid, LM.Symbols[ASym].DeclNode, Result.DeclFile,
       Result.Line, Result.Col) then
  begin
    Result := Default(TPasSymbolKey);
    Exit;
  end;
  Result.MainFile := AProject.ModelFile(AMid);
  Result.Name := LM.Symbols[ASym].Name;
end;

function TPasSymbolKey.Resolve(AProject: TPasSemaProject; out AMid,
  ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
  LFile: string;
  LLine, LCol: Integer;
begin
  Result := False;
  ASym := -1;
  AMid := -1;
  if not Valid or (AProject = nil) then
    Exit;
  AMid := AProject.ModelIdOf(MainFile);
  if AMid < 0 then
    Exit;
  LM := AProject.Model(AMid);
  for var LS := 0 to LM.SymCount - 1 do
    if SameText(LM.Symbols[LS].Name, Name) and
       (LM.Symbols[LS].DeclNode <> NIL_NODE) and
       AProject.NodeSite(AMid, LM.Symbols[LS].DeclNode, LFile, LLine, LCol) and
       (LLine = Line) and (LCol = Col) and SameText(LFile, DeclFile) then
    begin
      ASym := LS;
      Exit(True);
    end;
end;

{ TPasWorkspace }

constructor TPasWorkspace.Create(AProject: TPasSemaProject;
  const AFactory: TPasProjectFactory);
begin
  inherited Create;
  if AProject = nil then
    raise EArgumentNilException.Create('TPasWorkspace: no project');
  FProject := AProject;
  FFactory := AFactory;
  NewNav;
end;

destructor TPasWorkspace.Destroy;
begin
  FNav.Free;
  if not FReleased then
    FProject.Free;
  inherited;
end;

procedure TPasWorkspace.NewNav;
begin
  FreeAndNil(FNav);
  FNav := TPasNavigator.Create(FProject);
  FNav.LibraryPaths := FLibraryPaths;
  FNavModelGen := FProject.ModelGeneration;
  Inc(FGeneration);
end;

procedure TPasWorkspace.SetLibraryPaths(const AValue: TArray<string>);
begin
  FLibraryPaths := AValue;
  if FNav <> nil then
    FNav.LibraryPaths := AValue;
end;

procedure TPasWorkspace.Swap(ANew: TPasSemaProject);
var
  LOld: TPasSemaProject;
begin
  LOld := FProject;
  FreeAndNil(FNav);
  FProject := ANew;
  if LOld <> ANew then
    LOld.Free;
  NewNav;
  FStatus.Changed := True;
end;

procedure TPasWorkspace.Adopt(AProject: TPasSemaProject);
begin
  if AProject = nil then
    raise EArgumentNilException.Create('TPasWorkspace.Adopt: no project');
  if FLent > 0 then
    raise EPasWorkspaceBusy.Create('TPasWorkspace.Adopt: the project is ' +
      'lent to an analysis session as its parse donor (EndLend first)');
  if FReleased then
  begin
    FReleased := False;
    FProject := AProject;
    NewNav;
  end
  else
    Swap(AProject);
end;

function TPasWorkspace.Release: TPasSemaProject;
begin
  CheckOwned;
  if FLent > 0 then
    raise EPasWorkspaceBusy.Create('TPasWorkspace.Release: the project is ' +
      'lent to an analysis session as its parse donor (EndLend first)');
  FreeAndNil(FNav);
  Result := FProject;
  FReleased := True;
  Inc(FGeneration);
end;

function TPasWorkspace.Lend: TPasSemaProject;
begin
  CheckOwned;
  Inc(FLent);
  Result := FProject;
end;

procedure TPasWorkspace.EndLend;
begin
  if FLent > 0 then
    Dec(FLent);
end;

procedure TPasWorkspace.CheckOwned;
begin
  if FReleased then
    raise EPasWorkspaceBusy.Create('TPasWorkspace: the project is handed ' +
      'to an analysis session (Release); a query waits for Adopt');
end;

function TPasWorkspace.IsCancelled: Boolean;
begin
  Result := Assigned(FOptions.Cancelled) and FOptions.Cancelled();
end;

procedure TPasWorkspace.Progress(AStage: TPasQueryStage; ARound,
  AUnits: Integer; const AStaged: TPasStagedProgress; const AText: string);
var
  LP: TPasQueryProgress;
begin
  if not Assigned(FOptions.OnProgress) then
    Exit;
  LP.Stage := AStage;
  LP.Round := ARound;
  LP.Units := AUnits;
  LP.Staged := AStaged;
  LP.Text := AText;
  FOptions.OnProgress(LP);
end;

function TPasWorkspace.AllowEscalation(const ANote: string): Boolean;
begin
  case FOptions.Escalation of
    esRun:
      Result := True;
    esAsk:
      Result := Assigned(FOptions.OnAskEscalate) and
        FOptions.OnAskEscalate(ANote);
  else
    Result := False;
  end;
end;

function TPasWorkspace.Rebuild(AEscalate: Boolean): Boolean;
var
  LNew: TPasSemaProject;
  LStage: TPasQueryStage;
  LRoots: TArray<string>;
begin
  Result := False;
  if not Assigned(FFactory) then
  begin
    FStatus.Note := FStatus.Note + 'no project factory: no rebuild;';
    Exit;
  end;
  if AEscalate then
    LStage := qsEscalate
  else
    LStage := qsRebuild;
  LRoots := FProject.AnalyzedRoots;
  LNew := FFactory();
  try
    if AEscalate or FEscalated then
      LNew.LightPaths := nil;
    LNew.EscalationPercent := FProject.EscalationPercent;
    // The donor carries the promoted set: a rebuild EnsureFull asked for
    // loads those units full (TPasSemaProject.PromotedFiles).
    LNew.AdoptParseDonor(FProject);
    Progress(LStage, 0, 0, Default(TPasStagedProgress),
      IfThen(AEscalate, 'analyzing the library in full',
        'analyzing again with the promoted units'));
    LNew.AnalyzeStaged(LRoots, [], FOptions.Cancelled,
      procedure(AP: TPasStagedProgress)
      begin
        Progress(LStage, 0, 0, AP, Format('%s: %d of %d units', [AP.Phase,
          AP.FullDone, AP.Total]));
      end);
    if IsCancelled or not LNew.RunComplete then
    begin
      FStatus.Cancelled := FStatus.Cancelled or IsCancelled;
      FStatus.Note := FStatus.Note + 'rebuild incomplete;';
      LNew.Free;
      Exit;
    end;
  except
    LNew.Free;
    raise;
  end;
  Swap(LNew);
  if AEscalate then
  begin
    FEscalated := True;
    FStatus.Escalated := True;
  end
  else
    FStatus.Rebuilt := True;
  Result := True;
end;

procedure TPasWorkspace.Prepare(const ADemand: TPasDemandFunc);
var
  LDemand: TPasDemand;
  LRes: TPasEnsureResult;
  LSW: TStopwatch;
  LPct: Integer;
  LNoEscalation: Boolean;
begin
  CheckOwned;
  FStatus := Default(TPasQueryStatus);
  LSW := TStopwatch.StartNew;
  try
    if FOptions.Partial then
    begin
      FStatus.NotSearched := ADemand(FNav).NotSearched;
      Exit;
    end;
    LNoEscalation := (FOptions.Escalation = esNever) or not Assigned(FFactory);
    while True do
    begin
      LDemand := ADemand(FNav);
      if LDemand.IsEmpty then
        Break;
      if IsCancelled then
      begin
        FStatus.Cancelled := True;
        FStatus.NotSearched := LDemand.NotSearched;
        Break;
      end;
      if FLent > 0 then
        raise EPasWorkspaceBusy.CreateFmt('TPasWorkspace: this answer needs ' +
          '%d library unit(s) analyzed in full, and the project is an ' +
          'analysis session''s parse donor - ask again when the session ' +
          'is over, or ask for a partial answer (Options.Partial)',
          [Max(LDemand.NotSearched, Length(LDemand.Full))]);
      if FStatus.Rounds >= MAX_ROUNDS then
      begin
        FStatus.Note := FStatus.Note + Format('rounds>%d;', [MAX_ROUNDS]);
        FStatus.NotSearched := LDemand.NotSearched;
        Break;
      end;
      Inc(FStatus.Rounds);
      Progress(qsPromote, FStatus.Rounds, Length(LDemand.Full) +
        Length(LDemand.LoadOnly) + Length(LDemand.Preprocess),
        Default(TPasStagedProgress), Format('library bodies: %d unit(s)',
        [Length(LDemand.Full) + Length(LDemand.Preprocess)]));
      LPct := FProject.EscalationPercent;
      if LNoEscalation then
        FProject.EscalationPercent := 0;
      try
        LRes := FProject.EnsureFull(LDemand);
      finally
        FProject.EscalationPercent := LPct;
      end;
      Inc(FStatus.Promoted, LRes.Promoted);
      Inc(FStatus.Loaded, LRes.Loaded);
      Inc(FStatus.Preprocessed, LRes.Preprocessed);
      FStatus.Refused := FStatus.Refused + LRes.Refused;
      if LRes.Note <> '' then
        FStatus.Note := FStatus.Note + LRes.Note + ';';
      // Models replaced: the navigator would refuse to serve.
      if FProject.ModelGeneration <> FNavModelGen then
      begin
        NewNav;
        FStatus.Changed := True;
      end;
      case LRes.Outcome of
        eoNeedsRebuild:
          begin
            if not Rebuild(False) then
            begin
              FStatus.NotSearched := LDemand.NotSearched;
              Break;
            end;
            Continue;
          end;
        eoEscalate:
          begin
            if AllowEscalation(LRes.Note) then
            begin
              if not Rebuild(True) then
              begin
                FStatus.NotSearched := LDemand.NotSearched;
                Break;
              end;
            end
            else
              // Declined: this query meets its demand unit by unit.
              LNoEscalation := True;
            Continue;
          end;
      end;
      // Nothing moved: the refused units stay refused.
      if (LRes.Promoted = 0) and (LRes.Loaded = 0) and
         (LRes.Preprocessed = 0) then
      begin
        FStatus.NotSearched := LDemand.NotSearched;
        Break;
      end;
    end;
  finally
    FStatus.Ms := LSW.ElapsedMilliseconds;
    if FNav <> nil then
      FNav.NotSearched := 0;
  end;
end;

procedure TPasWorkspace.Finish;
begin
  FStatus.NotSearched := Max(FStatus.NotSearched, FNav.NotSearched);
end;

function TPasWorkspace.Sym(const AKey: TPasSymbolKey; out AMid,
  ASym: Integer): Boolean;
begin
  Result := AKey.Resolve(FProject, AMid, ASym);
end;

function TPasWorkspace.SymDemand(const AKey: TPasSymbolKey;
  const AOf: TPasSymDemandOf): TPasDemandFunc;
var
  LKey: TPasSymbolKey;
begin
  LKey := AKey;
  Result :=
    function(ANav: TPasNavigator): TPasDemand
    var
      LM, LS: Integer;
    begin
      if not LKey.Valid then
        Exit(Default(TPasDemand));
      // Not in this closure (yet): its unit first, when a full closure has
      // it (DemandFilePath).
      if not LKey.Resolve(ANav.Project, LM, LS) then
        Exit(ANav.DemandFilePath(LKey.MainFile));
      Result := AOf(ANav, LM, LS);
    end;
end;

function TPasWorkspace.MidOf(const AFile: string): Integer;
begin
  if AFile = '' then
    Result := -1
  else
    Result := FProject.ModelIdOf(AFile);
end;

function TPasWorkspace.MidsOf(const AFiles: TArray<string>): TArray<Integer>;
var
  LMid: Integer;
begin
  Result := nil;
  for var LF in AFiles do
  begin
    LMid := FProject.ModelIdOf(LF);
    if LMid >= 0 then
      Result := Result + [LMid];
  end;
end;

{ ---- the references family ---- }

function TPasWorkspace.FindReferences(const AKey: TPasSymbolKey;
  AImplHeaders, AFormFiles: Boolean; const AOnlyFile: string): TArray<TPasRefHit>;
var
  LM, LS, LOnly: Integer;
begin
  Prepare(SymDemand(AKey,
    function(ANav: TPasNavigator; AM, ASy: Integer): TPasDemand
    begin
      Result := ANav.DemandReferences(AM, ASy);
    end));
  Result := nil;
  LOnly := MidOf(AOnlyFile);
  if Sym(AKey, LM, LS) and ((AOnlyFile = '') or (LOnly >= 0)) then
    Result := FNav.FindReferences(LM, LS, AImplHeaders, AFormFiles, LOnly);
  Finish;
end;

function TPasWorkspace.FindAssignments(const AKey: TPasSymbolKey): TArray<TPasRefHit>;
var
  LM, LS: Integer;
begin
  Prepare(SymDemand(AKey,
    function(ANav: TPasNavigator; AM, ASy: Integer): TPasDemand
    begin
      Result := ANav.DemandReferences(AM, ASy);
    end));
  Result := nil;
  if Sym(AKey, LM, LS) then
    Result := FNav.FindAssignments(LM, LS);
  Finish;
end;

function TPasWorkspace.CollectReferencesOfAll(const AKeys: TArray<TPasSymbolKey>;
  AAssignOnly: Boolean; const AOnlyFile: string): TArray<TPasRefHit>;
var
  LKeys: TArray<TPasSymbolKey>;
  LRefs: TArray<TPasExtRef>;
  LHits: TList<TPasRefHit>;
  LOnly: Integer;
begin
  LKeys := AKeys;
  Prepare(
    function(ANav: TPasNavigator): TPasDemand
    var
      LM, LS: Integer;
    begin
      Result := ANav.DemandReferencesOfAll(ExtRefsOf(ANav.Project, LKeys));
      for var LK in LKeys do
        if LK.Valid and not LK.Resolve(ANav.Project, LM, LS) then
          Result := PasMergeDemand(Result, ANav.DemandFilePath(LK.MainFile));
    end);
  Result := nil;
  LOnly := MidOf(AOnlyFile);
  LRefs := ExtRefsOf(FProject, AKeys);
  if (LRefs <> nil) and ((AOnlyFile = '') or (LOnly >= 0)) then
  begin
    LHits := TList<TPasRefHit>.Create;
    try
      FNav.CollectReferencesOfAll(LRefs, LHits, AAssignOnly, LOnly);
      Result := LHits.ToArray;
    finally
      LHits.Free;
    end;
  end;
  Finish;
end;

class function TPasWorkspace.ExtRefsOf(AProject: TPasSemaProject;
  const AKeys: TArray<TPasSymbolKey>): TArray<TPasExtRef>;
var
  LR: TPasExtRef;
begin
  Result := nil;
  for var LK in AKeys do
    if LK.Resolve(AProject, LR.UnitId, LR.Sym) then
      Result := Result + [LR];
end;

function TPasWorkspace.FindCreations(const AKey: TPasSymbolKey): TArray<TPasRefHit>;
var
  LM, LS: Integer;
begin
  Prepare(SymDemand(AKey,
    function(ANav: TPasNavigator; AM, ASy: Integer): TPasDemand
    begin
      Result := ANav.DemandCreations(AM, ASy);
    end));
  Result := nil;
  if Sym(AKey, LM, LS) then
    Result := FNav.FindCreations(LM, LS);
  Finish;
end;

function TPasWorkspace.FindDestructions(const AKey: TPasSymbolKey): TArray<TPasRefHit>;
var
  LM, LS: Integer;
begin
  Prepare(SymDemand(AKey,
    function(ANav: TPasNavigator; AM, ASy: Integer): TPasDemand
    begin
      Result := ANav.DemandDestructions(AM, ASy);
    end));
  Result := nil;
  if Sym(AKey, LM, LS) then
    Result := FNav.FindDestructions(LM, LS);
  Finish;
end;

{ ---- the hierarchy family ---- }

function TPasWorkspace.FindDescendants(const AKey: TPasSymbolKey): TArray<TPasDescendantHit>;
var
  LM, LS: Integer;
begin
  Prepare(SymDemand(AKey,
    function(ANav: TPasNavigator; AM, ASy: Integer): TPasDemand
    begin
      Result := ANav.DemandDescendants(AM, ASy);
    end));
  Result := nil;
  if Sym(AKey, LM, LS) then
    Result := FNav.FindDescendants(LM, LS);
  Finish;
end;

function TPasWorkspace.FindOverrides(const AKey: TPasSymbolKey): TArray<TPasOverrideHit>;
var
  LM, LS: Integer;
begin
  Prepare(SymDemand(AKey,
    function(ANav: TPasNavigator; AM, ASy: Integer): TPasDemand
    begin
      Result := ANav.DemandOverrides(AM, ASy);
    end));
  Result := nil;
  if Sym(AKey, LM, LS) then
    Result := FNav.FindOverrides(LM, LS);
  Finish;
end;

function TPasWorkspace.FindImplementations(const AKey: TPasSymbolKey): TArray<TPasImplHit>;
var
  LM, LS: Integer;
begin
  Prepare(SymDemand(AKey,
    function(ANav: TPasNavigator; AM, ASy: Integer): TPasDemand
    begin
      Result := ANav.DemandImplementations(AM, ASy);
    end));
  Result := nil;
  if Sym(AKey, LM, LS) then
    Result := FNav.FindImplementations(LM, LS);
  Finish;
end;

function TPasWorkspace.FindInterfaceImplementors(const AKey: TPasSymbolKey): TArray<TPasImplHit>;
var
  LM, LS: Integer;
begin
  Prepare(SymDemand(AKey,
    function(ANav: TPasNavigator; AM, ASy: Integer): TPasDemand
    begin
      Result := ANav.DemandInterfaceImplementors(AM, ASy);
    end));
  Result := nil;
  if Sym(AKey, LM, LS) then
    Result := FNav.FindInterfaceImplementors(LM, LS);
  Finish;
end;

function TPasWorkspace.RenameFamily(const AKey: TPasSymbolKey;
  out AMembers: TArray<TPasRenameFamilyMember>; out AError: string): Boolean;
var
  LM, LS: Integer;
begin
  Prepare(SymDemand(AKey,
    function(ANav: TPasNavigator; AM, ASy: Integer): TPasDemand
    begin
      Result := ANav.DemandRenameFamily(AM, ASy);
    end));
  AMembers := nil;
  AError := '';
  if Sym(AKey, LM, LS) then
    Result := FNav.RenameFamily(LM, LS, AMembers, AError)
  else
  begin
    AError := NOT_ANALYZED;
    Result := False;
  end;
  Finish;
end;

{ ---- names ---- }

function TPasWorkspace.FindBuiltinReferences(const AName,
  AOnlyFile: string): TArray<TPasRefHit>;
var
  LName: string;
  LOnly: Integer;
begin
  LName := AName;
  Prepare(
    function(ANav: TPasNavigator): TPasDemand
    begin
      Result := ANav.DemandBuiltin(LName);
    end);
  Result := nil;
  LOnly := MidOf(AOnlyFile);
  if (AOnlyFile = '') or (LOnly >= 0) then
    Result := FNav.FindBuiltinReferences(AName, LOnly);
  Finish;
end;

function TPasWorkspace.FindDefines: TArray<TPasDefineSite>;
begin
  Prepare(
    function(ANav: TPasNavigator): TPasDemand
    begin
      Result := ANav.DemandDefines;
    end);
  Result := FNav.FindDefines;
  Finish;
end;

function TPasWorkspace.FindDefineReferences(const AName: string): TArray<TPasDefineHit>;
var
  LName: string;
begin
  LName := AName;
  Prepare(
    function(ANav: TPasNavigator): TPasDemand
    begin
      Result := ANav.DemandDefineReferences(LName);
    end);
  Result := FNav.FindDefineReferences(AName);
  Finish;
end;

{ ---- renames ---- }

function TPasWorkspace.PlanRename(const AKey: TPasSymbolKey;
  const ANewName: string; out AEdits: TArray<TPasRenameEdit>;
  out ACarried: TArray<TPasCarriedRename>;
  out AFamily: TArray<TPasRenameFamilyMember>; out AError: string): Boolean;
var
  LM, LS: Integer;
begin
  Prepare(SymDemand(AKey,
    function(ANav: TPasNavigator; AM, ASy: Integer): TPasDemand
    begin
      Result := ANav.DemandRename(AM, ASy);
    end));
  AEdits := nil;
  ACarried := nil;
  AFamily := nil;
  AError := '';
  if Sym(AKey, LM, LS) then
    Result := FNav.PlanRename(LM, LS, ANewName, AEdits, ACarried, AFamily,
      AError)
  else
  begin
    AError := NOT_ANALYZED;
    Result := False;
  end;
  Finish;
end;

{ ---- one file, one position ---- }

function TPasWorkspace.RoutineImplNode(const AKey: TPasSymbolKey;
  out AMid: Integer): Integer;
var
  LS: Integer;
begin
  Prepare(SymDemand(AKey,
    function(ANav: TPasNavigator; AM, ASy: Integer): TPasDemand
    begin
      Result := ANav.DemandFile(AM);
    end));
  Result := NIL_NODE;
  if Sym(AKey, AMid, LS) then
    Result := FNav.RoutineImplNode(AMid, LS);
  Finish;
end;

function TPasWorkspace.SemanticTokens(const AFile: string): TArray<TPasSemanticToken>;
begin
  Result := InFile<TArray<TPasSemanticToken>>(AFile,
    function(ANav: TPasNavigator; AMid: Integer): TArray<TPasSemanticToken>
    begin
      Result := ANav.SemanticTokens(AMid);
    end);
end;

function TPasWorkspace.FileDemand(const AFile: string): TPasDemandFunc;
var
  LFile: string;
begin
  LFile := AFile;
  Result :=
    function(ANav: TPasNavigator): TPasDemand
    var
      LM: Integer;
    begin
      LM := ANav.ModelIdOf(LFile);
      if LM < 0 then
        Result := ANav.DemandFilePath(LFile)
      else
        Result := ANav.DemandFile(LM);
    end;
end;

function TPasWorkspace.PositionDemand(const AFile: string; ALine,
  ACol: Integer): TPasDemandFunc;
var
  LFile: string;
  LLine, LCol: Integer;
begin
  LFile := AFile;
  LLine := ALine;
  LCol := ACol;
  Result :=
    function(ANav: TPasNavigator): TPasDemand
    var
      LM: Integer;
    begin
      LM := ANav.ModelIdOf(LFile);
      if LM < 0 then
        Result := ANav.DemandFilePath(LFile)
      else
        Result := ANav.DemandPosition(LM, LLine, LCol);
    end;
end;

function TPasWorkspace.InFile<T>(const AFile: string;
  const AQuery: TPasPositionQuery<T>): T;
var
  LMid: Integer;
begin
  Prepare(FileDemand(AFile));
  Result := Default(T);
  LMid := FNav.ModelIdOf(AFile);
  if LMid >= 0 then
    Result := AQuery(FNav, LMid);
  Finish;
end;

function TPasWorkspace.At<T>(const AFile: string; ALine, ACol: Integer;
  const AQuery: TPasPositionQuery<T>): T;
var
  LMid: Integer;
begin
  Prepare(PositionDemand(AFile, ALine, ACol));
  Result := Default(T);
  LMid := FNav.ModelIdOf(AFile);
  if LMid >= 0 then
    Result := AQuery(FNav, LMid);
  Finish;
end;

{ ---- the uses lint ---- }

function TPasWorkspace.FindUnusedUses(const AFiles: TArray<string>;
  AOptions: TPasLintOptions): TArray<TPasUnusedUse>;
var
  LFiles: TArray<string>;
  LOpts: TPasLintOptions;
begin
  LFiles := AFiles;
  LOpts := AOptions;
  Prepare(
    function(ANav: TPasNavigator): TPasDemand
    begin
      Result := DemandLint(ANav, MidsOf(LFiles), LOpts);
    end);
  Result := PasTree.Sema.Lint.FindUnusedUses(FNav, MidsOf(AFiles), AOptions);
  Finish;
end;

function TPasWorkspace.FindUnreferencedUnits(const AFiles: TArray<string>;
  AOptions: TPasLintOptions): TArray<TPasUnreferencedUnit>;
var
  LFiles: TArray<string>;
  LOpts: TPasLintOptions;
begin
  LFiles := AFiles;
  LOpts := AOptions;
  Prepare(
    function(ANav: TPasNavigator): TPasDemand
    begin
      Result := DemandLint(ANav, MidsOf(LFiles), LOpts);
    end);
  Result := PasTree.Sema.Lint.FindUnreferencedUnits(FNav, MidsOf(AFiles),
    AOptions);
  Finish;
end;

end.
