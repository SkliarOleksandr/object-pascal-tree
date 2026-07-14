unit PasTree.Sema.Project;

{
  PasTree semantics — Phase 2 project driver: resolves `uses` to real units,
  indexes their interface symbols, re-resolves each unit's external references
  against them, and emits E2003 for genuinely undeclared identifiers.

  Per-unit models (Phase 1) are kept as-is; a cross-unit resolution is recorded
  in the referring model's ExtRefMap as (unitId, symbolId). E2003 is emitted
  only when every `uses` unit of the referring unit resolved (AllUsesResolved),
  so an unindexable import never yields a false undeclared-identifier.

  Phase 3c adds cross-model TYPING on top: BindTypesX resolves declared types
  that live in another unit (and generic instantiations, deduped in the
  project-owned instance table), CrossType then types expressions the
  intra-unit typer could not — Var.Field across units, member access through
  ancestor chains and type aliases, constructor calls, and generic-parameter
  substitution (TList<Integer>.First -> Integer). This pass records types and
  member references only; it emits NO diagnostics (typing for navigation and
  dumps, never a new error source).
}

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  PasTree.Preprocessor,
  PasTree.Platforms,
  PasTree.SourceManager,
  PasTree.Ast,
  PasTree.Sema.Model;

type
  // One generic instantiation: a generic type symbol + positional actual
  // args. Args may themselves reference skGenericParam symbols (an "open"
  // instantiation inside another generic's body, e.g. TEnumerator<T> inside
  // TList<T>) — those close over the outer instance on substitution.
  TSemaInstance = record
    UnitId: Integer;            // model id of the generic type symbol
    Sym: Integer;               // the skType symbol of the generic
    Args: TArray<TSemaXType>;
  end;

  TPasSemaProject = class
  private
    FPlatform: TPasPlatform;
    FInfo: TPasPlatformInfo;
    FSM: TPasSourceManager;
    FDefines: TPasDefines;
    FPP: TPasPreprocessor;
    FModels: TObjectList<TPasSemaModel>;
    FFiles: TList<string>;                 // parallel to FModels (full path)
    FByPath: TDictionary<string, Integer>; // full path (lower) -> model id
    FSingleThreaded: Boolean;
    // Phase 3c: cross-model typing.
    FInstances: TList<TSemaInstance>;
    FInstKeys: TDictionary<string, Integer>;
    // Runs ABody for 0..AHi — one worker per core, or a plain loop when
    // SingleThreaded (baseline emulation / timing comparison / debugging).
    procedure ForEachIndex(AHi: Integer; const ABody: TProc<Integer>);
    function LoadFile(const APath: string): Integer;
    procedure LoadFilesParallel(const APaths: TArray<string>);
    procedure ResolveUses(AId: Integer);
    procedure CrossResolve(AId: Integer);
    function FindInUses(AId: Integer; const ANameLower: string;
      out AUnit, ASym: Integer): Boolean;
    function UsesUnitOf(AId, ASym: Integer): Integer;
    function LocalHead(AModel: TPasSemaModel; ANode: Integer): Integer;
    procedure EmitE2003(AModel: TPasSemaModel; ANode: Integer);
    procedure EmitAt(AModel: TPasSemaModel; ANode: Integer;
      const ACode, AMsg: string);
    function RoutineArity(AMid, ASym: Integer; out AReq, ATot: Integer;
      out AVariadic: Boolean): Boolean;
    procedure CheckCalls(AId: Integer);
    // Phase 3c: cross-model typing.
    function Instantiate(const ABase: TSemaXType;
      const AArgs: TArray<TSemaXType>): Integer;
    function TypeDefNodeOf(AMid, ASym: Integer): Integer;
    function GenericParamIdents(AMid, ASym: Integer): TArray<Integer>;
    function DeclTypeX(AMid, ASym: Integer): TSemaXType;
    function SubstX(const AX: TSemaXType; AInst, ADepth: Integer): TSemaXType;
    function ResolveTypeExpr(AId, ANode: Integer): TSemaXType;
    function FindMemberX(const ABase: TSemaXType; const ANameLower: string;
      out AMemMid, AMemSym: Integer; out ACtx: Integer): Boolean;
    function IsConstructorSym(AMid, ASym: Integer): Boolean;
    procedure BindTypesX(AId: Integer);
    procedure CrossType(AId: Integer);
  public
    constructor Create(APlatform: TPasPlatform;
      const ASearchPaths: TArray<string>; const AExtraDefines: TArray<string>);
    destructor Destroy; override;
    // True = run every stage on the calling thread (emulates the sequential
    // driver exactly; results are identical either way — the parallel stages
    // are pure per unit). Default False (one worker per core).
    property SingleThreaded: Boolean read FSingleThreaded write FSingleThreaded;
    { Editor-host buffer override: analysis reads AText for APath instead of
      the file on disk (for unsaved editor content). Call BEFORE AnalyzeFile/
      AnalyzeDirectory — LoadFile reads at analysis time. }
    procedure SetBuffer(const APath, AText: string);
    function ModelCount: Integer;
    function Model(AId: Integer): TPasSemaModel;
    function ModelFile(AId: Integer): string;
    function InstanceCount: Integer;
    function Instance(AInst: Integer): TSemaInstance;
    // 'TList<Integer>'-style rendering of a cross-model type (for dumps/tests).
    function XTypeText(const AX: TSemaXType): string;
    // Analyze one unit + its direct uses; returns the main unit's model id.
    function AnalyzeFile(const AMainFile: string): Integer;
    // Analyze every .pas/.dpr under a directory (indexed first).
    procedure AnalyzeDirectory(const ARoot: string);
  end;

implementation

uses
  System.IOUtils,
  System.Threading,
  PasTree.Parser,
  PasTree.Sema.Resolver,
  PasTree.Sema.Diagnostics;

constructor TPasSemaProject.Create(APlatform: TPasPlatform;
  const ASearchPaths: TArray<string>; const AExtraDefines: TArray<string>);
var
  LName: string;
begin
  inherited Create;
  FPlatform := APlatform;
  FInfo := PlatformInfo(APlatform);
  FSM := TPasSourceManager.Create(ASearchPaths);
  FDefines := CreatePlatformDefines(APlatform);
  for LName in AExtraDefines do
    FDefines.Define(LName);
  FPP := TPasPreprocessor.Create(FSM, FDefines, 37.0, FInfo.PointerBytes,
    FInfo.ExtendedBytes);
  FModels := TObjectList<TPasSemaModel>.Create(True);
  FFiles := TList<string>.Create;
  FByPath := TDictionary<string, Integer>.Create;
  FInstances := TList<TSemaInstance>.Create;
  FInstKeys := TDictionary<string, Integer>.Create;
end;

destructor TPasSemaProject.Destroy;
begin
  FInstKeys.Free;
  FInstances.Free;
  FByPath.Free;
  FFiles.Free;
  FModels.Free;
  FPP.Free;
  FDefines.Free;
  FSM.Free;
  inherited;
end;

procedure TPasSemaProject.ForEachIndex(AHi: Integer;
  const ABody: TProc<Integer>);
var
  LIdx: Integer;
begin
  if FSingleThreaded then
    for LIdx := 0 to AHi do
      ABody(LIdx)
  else
    TParallel.&For(0, AHi, ABody);
end;

procedure TPasSemaProject.SetBuffer(const APath, AText: string);
begin
  FSM.SetBuffer(APath, AText);
end;

function TPasSemaProject.ModelCount: Integer;
begin
  Result := FModels.Count;
end;

function TPasSemaProject.Model(AId: Integer): TPasSemaModel;
begin
  Result := FModels[AId];
end;

function TPasSemaProject.ModelFile(AId: Integer): string;
begin
  Result := FFiles[AId];
end;

function TPasSemaProject.LoadFile(const APath: string): Integer;
var
  LFull, LKey: string;
  LPre: TPasPreprocessed;
  LDiags: TArray<TPasParseDiag>;
  LTree: TPasTree;
  LModel: TPasSemaModel;
begin
  LFull := TPath.GetFullPath(APath);
  LKey := LowerCase(LFull);
  if FByPath.TryGetValue(LKey, Result) then
    Exit;   // includes the -1 negative-cache sentinel for known-bad files
  if not TFile.Exists(LFull) then
    Exit(-1);
  try
    LPre := FPP.Process(LFull);
    LTree := TPasParser.ParseFile(LPre, LDiags);
    LModel := TPasSemaResolver.Analyze(LTree);
  except
    on Exception do
    begin
      // Tolerate a unit that fails to parse; treat as unresolvable — and
      // remember that, so repeated `uses` of it don't re-parse every time.
      FByPath.Add(LKey, -1);
      Exit(-1);
    end;
  end;
  Result := FModels.Add(LModel);
  FFiles.Add(LFull);
  FByPath.Add(LKey, Result);
end;

// Parse + Phase-1-analyze a batch of files with one worker per core, then
// register the results IN INPUT ORDER (deterministic model ids). Pure per
// file: each worker owns its preprocessor (which clones the shared defines
// per run); the source manager and define set are read-only during the loop —
// the same no-locks model as TPasProject.ParseFiles.
procedure TPasSemaProject.LoadFilesParallel(const APaths: TArray<string>);
var
  LTodo: TArray<string>;
  LKeys: TArray<string>;
  LDone: TArray<TPasSemaModel>;
  LSeen: TDictionary<string, Boolean>;
  LIdx, LDummy: Integer;
  LFull, LKey: string;
begin
  // Normalize, drop already-loaded/known-bad paths and in-batch duplicates.
  LTodo := nil;
  LKeys := nil;
  LSeen := TDictionary<string, Boolean>.Create;
  try
    for LIdx := 0 to High(APaths) do
    begin
      LFull := TPath.GetFullPath(APaths[LIdx]);
      LKey := LowerCase(LFull);
      if FByPath.TryGetValue(LKey, LDummy) or LSeen.ContainsKey(LKey) then
        Continue;
      if not TFile.Exists(LFull) then
        Continue;
      LSeen.Add(LKey, True);
      LTodo := LTodo + [LFull];
      LKeys := LKeys + [LKey];
    end;
  finally
    LSeen.Free;
  end;
  if LTodo = nil then
    Exit;

  SetLength(LDone, Length(LTodo));
  ForEachIndex(High(LTodo),
    procedure(AIndex: Integer)
    var
      LPP: TPasPreprocessor;
      LPre: TPasPreprocessed;
      LDiags: TArray<TPasParseDiag>;
    begin
      LPP := TPasPreprocessor.Create(FSM, FDefines, 37.0, FInfo.PointerBytes,
        FInfo.ExtendedBytes);
      try
        try
          LPre := LPP.Process(LTodo[AIndex]);
          LDone[AIndex] :=
            TPasSemaResolver.Analyze(TPasParser.ParseFile(LPre, LDiags));
        except
          on Exception do
            LDone[AIndex] := nil;   // registered as known-bad below
        end;
      finally
        LPP.Free;
      end;
    end);

  for LIdx := 0 to High(LTodo) do
    if LDone[LIdx] <> nil then
    begin
      FByPath.Add(LKeys[LIdx], FModels.Add(LDone[LIdx]));
      FFiles.Add(LTodo[LIdx]);
    end
    else
      FByPath.Add(LKeys[LIdx], -1);
end;

procedure TPasSemaProject.ResolveUses(AId: Integer);
var
  LModel: TPasSemaModel;
  LPath: string;
  LUid, LIdx: Integer;
begin
  LModel := FModels[AId];
  LModel.AllUsesResolved := True;
  for LIdx := 0 to High(LModel.UsesList) do
  begin
    if FSM.ResolveUnit(LModel.UsesList[LIdx].NameFull,
      LModel.UsesList[LIdx].InPath, FFiles[AId], LPath) then
    begin
      LUid := LoadFile(LPath);
      LModel.UsesList[LIdx].UnitId := LUid;
      if LUid >= 0 then
      begin
        if LModel.UsesList[LIdx].Sym <> NIL_SYM then
          LModel.Symbols[LModel.UsesList[LIdx].Sym].Flags :=
            LModel.Symbols[LModel.UsesList[LIdx].Sym].Flags -
            [sfExternalUnresolved];
      end
      else
        LModel.AllUsesResolved := False;
    end
    else
      LModel.AllUsesResolved := False;
  end;
end;

function TPasSemaProject.UsesUnitOf(AId, ASym: Integer): Integer;
var
  LModel: TPasSemaModel;
  LIdx: Integer;
begin
  LModel := FModels[AId];
  for LIdx := 0 to High(LModel.UsesList) do
    if LModel.UsesList[LIdx].Sym = ASym then
      Exit(LModel.UsesList[LIdx].UnitId);
  Result := -1;
end;

function TPasSemaProject.FindInUses(AId: Integer; const ANameLower: string;
  out AUnit, ASym: Integer): Boolean;
var
  LModel, LUsed: TPasSemaModel;
  LIdx, LUid, LSym: Integer;
begin
  LModel := FModels[AId];
  for LIdx := High(LModel.UsesList) downto 0 do
  begin
    LUid := LModel.UsesList[LIdx].UnitId;
    if LUid < 0 then
      Continue;
    LUsed := FModels[LUid];
    if LUsed.InterfaceScope = NIL_SCOPE then
      Continue;
    // Resolve (not FindLocal) so interface-visible enum values and other
    // joined-scope names are importable too.
    LSym := LUsed.Resolve(LUsed.InterfaceScope, ANameLower);
    if LSym <> NIL_SYM then
    begin
      AUnit := LUid;
      ASym := LSym;
      Exit(True);
    end;
  end;
  Result := False;
end;

// The local symbol a designator head resolved to (reads RefMap only).
function TPasSemaProject.LocalHead(AModel: TPasSemaModel;
  ANode: Integer): Integer;
var
  LLast: Integer;
begin
  case AModel.Tree.Nodes[ANode].Kind of
    nkIdent:
      Result := AModel.RefMap[ANode];
    nkMember:
      begin
        LLast := AModel.Tree.Nodes[ANode].FirstChild;
        while (LLast <> NIL_NODE) and
              (AModel.Tree.Nodes[LLast].NextSibling <> NIL_NODE) do
          LLast := AModel.Tree.Nodes[LLast].NextSibling;
        if LLast <> NIL_NODE then
          Result := AModel.RefMap[LLast]
        else
          Result := NIL_SYM;
      end;
    nkTypeArgs:
      Result := LocalHead(AModel, AModel.Tree.Nodes[ANode].FirstChild);
  else
    Result := NIL_SYM;
  end;
end;

procedure TPasSemaProject.EmitE2003(AModel: TPasSemaModel; ANode: Integer);
var
  LVis: TPasVisibleToken;
  LFile, LLine, LCol, LTok: Integer;
  LName: string;
begin
  LFile := 0; LLine := 0; LCol := 0;
  LTok := AModel.Tree.Nodes[ANode].FirstToken;
  if (LTok >= 0) and (LTok <= High(AModel.Tree.Source.Visible)) then
  begin
    LVis := AModel.Tree.Source.Visible[LTok];
    LFile := LVis.FileId;
    AModel.Tree.Source.Files[LVis.FileId].OffsetToLineCol(
      AModel.Tree.Source.Files[LVis.FileId].Tokens[LVis.TokenIndex].Start,
      LLine, LCol);
  end;
  LName := AModel.Tree.NodeText(ANode);
  AModel.AddDiag(MakeDiag('E2003',
    Format(SE2003_UndeclaredIdentifier, [LName]), ANode, LFile, LLine, LCol));
end;

procedure TPasSemaProject.EmitAt(AModel: TPasSemaModel; ANode: Integer;
  const ACode, AMsg: string);
var
  LVis: TPasVisibleToken;
  LFile, LLine, LCol, LTok: Integer;
begin
  LFile := 0; LLine := 0; LCol := 0;
  LTok := AModel.Tree.Nodes[ANode].FirstToken;
  if (LTok >= 0) and (LTok <= High(AModel.Tree.Source.Visible)) then
  begin
    LVis := AModel.Tree.Source.Visible[LTok];
    LFile := LVis.FileId;
    AModel.Tree.Source.Files[LVis.FileId].OffsetToLineCol(
      AModel.Tree.Source.Files[LVis.FileId].Tokens[LVis.TokenIndex].Start,
      LLine, LCol);
  end;
  AModel.AddDiag(MakeDiag(ACode, AMsg, ANode, LFile, LLine, LCol));
end;

// Model-aware parameter arity of a routine symbol. Result=False if the routine
// has no parameter scope (a builtin) — caller then skips the whole call.
function TPasSemaProject.RoutineArity(AMid, ASym: Integer;
  out AReq, ATot: Integer; out AVariadic: Boolean): Boolean;
var
  LM: TPasSemaModel;
  LScope, LS, LChild: Integer;
  LSawDefault: Boolean;
begin
  LM := FModels[AMid];
  AReq := 0; ATot := 0; AVariadic := False;
  LScope := LM.Symbols[ASym].MemberScope;
  if LScope = NIL_SCOPE then
    Exit(False);
  LSawDefault := False;
  for LS in LM.Scopes[LScope].Symbols do
    if LM.Symbols[LS].Kind = skParam then
    begin
      Inc(ATot);
      if sfHasDefault in LM.Symbols[LS].Flags then
        LSawDefault := True;
      if not LSawDefault then
        Inc(AReq);
    end;
  LChild := LM.Tree.Nodes[LM.Scopes[LScope].OwnerNode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if (LM.Tree.Nodes[LChild].Kind = nkDirective) and
       SameText(LM.Tree.NodeText(LChild), 'varargs') then
      AVariadic := True;
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
  Result := True;
end;

// Cross-unit argument-count check: gathers a call's candidate routines from the
// local overload chain PLUS every resolved used unit's interface, then flags
// E2035/E2034 only if no candidate's arity admits the argument count. Runs only
// for units with resolved uses (complete candidate visibility).
procedure TPasSemaProject.CheckCalls(AId: Integer);
var
  LModel: TPasSemaModel;
  LNode, LCallee, LArg, LArgCount, LLocalHead, LUid, LS, LIdx: Integer;
  LMinReq, LMaxTot: Integer;
  LAnyFit, LAnyVariadic, LHaveAny, LSkip: Boolean;
  LName: string;

  procedure Consider(AMid, AHead: Integer);
  var
    LCand, LReq, LTot: Integer;
    LVariadic: Boolean;
  begin
    LCand := AHead;
    while LCand <> NIL_SYM do
    begin
      if FModels[AMid].Symbols[LCand].Kind <> skRoutine then
        Break;
      if not RoutineArity(AMid, LCand, LReq, LTot, LVariadic) then
      begin
        LSkip := True;   // a candidate with no param info (builtin) -> bail
        Exit;
      end;
      LHaveAny := True;
      if LVariadic then
        LAnyVariadic := True;
      if LReq < LMinReq then LMinReq := LReq;
      if LTot > LMaxTot then LMaxTot := LTot;
      if LVariadic or ((LArgCount >= LReq) and (LArgCount <= LTot)) then
        LAnyFit := True;
      LCand := FModels[AMid].Symbols[LCand].NextOverload;
    end;
  end;

begin
  LModel := FModels[AId];
  if (Length(LModel.UsesList) = 0) or not LModel.AllUsesResolved then
    Exit;

  for LNode := 0 to High(LModel.RefMap) do
  begin
    if LModel.Tree.Nodes[LNode].Kind <> nkCall then
      Continue;
    LCallee := LModel.Tree.Nodes[LNode].FirstChild;
    if (LCallee = NIL_NODE) or (LModel.Tree.Nodes[LCallee].Kind <> nkIdent) then
      Continue;   // member/qualified calls (methods) are out of scope
    LLocalHead := LModel.RefMap[LCallee];
    if (LLocalHead <> NIL_SYM) and
       (LModel.Symbols[LLocalHead].Kind in [skType, skBuiltinType]) then
      Continue;   // a type cast, not a call

    LArgCount := 0;
    LArg := LModel.Tree.Nodes[LCallee].NextSibling;
    while LArg <> NIL_NODE do
    begin
      Inc(LArgCount);
      LArg := LModel.Tree.Nodes[LArg].NextSibling;
    end;

    LMinReq := MaxInt; LMaxTot := -1;
    LAnyFit := False; LAnyVariadic := False; LHaveAny := False; LSkip := False;

    // Local global-routine overloads.
    if (LLocalHead <> NIL_SYM) and (LModel.Symbols[LLocalHead].Kind = skRoutine)
       and (LModel.Scopes[LModel.Symbols[LLocalHead].Scope].Kind in
            [sckUnit, sckImplementation]) then
      Consider(AId, LLocalHead);

    // Same-named routines from every resolved used unit.
    if not LSkip then
    begin
      LName := LowerCase(LModel.Tree.NodeText(LCallee));
      for LIdx := 0 to High(LModel.UsesList) do
      begin
        LUid := LModel.UsesList[LIdx].UnitId;
        if LUid < 0 then
          Continue;
        LS := FModels[LUid].Resolve(FModels[LUid].InterfaceScope, LName);
        if (LS <> NIL_SYM) and (FModels[LUid].Symbols[LS].Kind = skRoutine) then
          Consider(LUid, LS);
        if LSkip then
          Break;
      end;
    end;

    if LSkip or not LHaveAny or LAnyVariadic or LAnyFit or (LMaxTot < 0) then
      Continue;
    if LArgCount < LMinReq then
      EmitAt(LModel, LNode, 'E2035', SE2035_NotEnoughActualParams)
    else if LArgCount > LMaxTot then
      EmitAt(LModel, LNode, 'E2034', SE2034_TooManyActualParams);
  end;
end;

{ Phase 3c — cross-model typing }

function XNil: TSemaXType;
begin
  Result.UnitId := NIL_SYM;
  Result.Sym := NIL_SYM;
  Result.Inst := NIL_INST;
end;

function XValid(const AX: TSemaXType): Boolean;
begin
  Result := AX.Sym <> NIL_SYM;
end;

function XPlain(AMid, ASym: Integer): TSemaXType;
begin
  Result.UnitId := AMid;
  Result.Sym := ASym;
  Result.Inst := NIL_INST;
end;

// Dedup-registers one generic instantiation; returns its instance-table index.
function TPasSemaProject.Instantiate(const ABase: TSemaXType;
  const AArgs: TArray<TSemaXType>): Integer;
var
  LKey: string;
  LInst: TSemaInstance;
  LArg: TSemaXType;
begin
  LKey := Format('%d:%d', [ABase.UnitId, ABase.Sym]);
  for LArg in AArgs do
    LKey := LKey + Format('|%d:%d:%d', [LArg.UnitId, LArg.Sym, LArg.Inst]);
  if FInstKeys.TryGetValue(LKey, Result) then
    Exit;
  LInst.UnitId := ABase.UnitId;
  LInst.Sym := ABase.Sym;
  LInst.Args := AArgs;
  Result := FInstances.Add(LInst);
  FInstKeys.Add(LKey, Result);
end;

// The type-expression node defining a type symbol (nkTypeDecl's def child).
function TPasSemaProject.TypeDefNodeOf(AMid, ASym: Integer): Integer;
var
  LM: TPasSemaModel;
  LName, LParent: Integer;
begin
  Result := NIL_NODE;
  LM := FModels[AMid];
  if LM.Symbols[ASym].Kind <> skType then
    Exit;
  LName := LM.Symbols[ASym].DeclNode;
  if LName = NIL_NODE then
    Exit;
  LParent := LM.Tree.Nodes[LName].Parent;
  if (LParent = NIL_NODE) or (LM.Tree.Nodes[LParent].Kind <> nkTypeDecl) then
    Exit;
  Result := LM.Tree.Nodes[LName].NextSibling;
  while (Result <> NIL_NODE) and
        (LM.Tree.Nodes[Result].Kind = nkGenericParams) do
    Result := LM.Tree.Nodes[Result].NextSibling;
end;

// The name-ident nodes of a generic type's parameters, in declaration order —
// the positional frame instantiation args are matched against.
function TPasSemaProject.GenericParamIdents(AMid,
  ASym: Integer): TArray<Integer>;
var
  LM: TPasSemaModel;
  LName, LParent, LGen, LParam, LP: Integer;
begin
  Result := nil;
  LM := FModels[AMid];
  LName := LM.Symbols[ASym].DeclNode;
  if LName = NIL_NODE then
    Exit;
  LParent := LM.Tree.Nodes[LName].Parent;
  if (LParent = NIL_NODE) or (LM.Tree.Nodes[LParent].Kind <> nkTypeDecl) then
    Exit;
  LGen := LM.Tree.Nodes[LParent].FirstChild;
  while (LGen <> NIL_NODE) and (LM.Tree.Nodes[LGen].Kind <> nkGenericParams) do
    LGen := LM.Tree.Nodes[LGen].NextSibling;
  if LGen = NIL_NODE then
    Exit;
  LParam := LM.Tree.Nodes[LGen].FirstChild;
  while LParam <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LParam].Kind = nkGenericParam then
    begin
      // Leading idents are the names; a trailing nkConstraint ends them.
      LP := LM.Tree.Nodes[LParam].FirstChild;
      while (LP <> NIL_NODE) and (LM.Tree.Nodes[LP].Kind = nkIdent) do
      begin
        Result := Result + [LP];
        LP := LM.Tree.Nodes[LP].NextSibling;
      end;
    end;
    LParam := LM.Tree.Nodes[LParam].NextSibling;
  end;
end;

// The declared type of any symbol as a cross-model descriptor: the model's
// SymTypeX refinement when present, else its locally-bound TypeSym.
function TPasSemaProject.DeclTypeX(AMid, ASym: Integer): TSemaXType;
var
  LM: TPasSemaModel;
begin
  LM := FModels[AMid];
  if LM.SymTypeX.TryGetValue(ASym, Result) then
    Exit;
  if LM.Symbols[ASym].TypeSym <> NIL_SYM then
    Exit(XPlain(AMid, LM.Symbols[ASym].TypeSym));
  Result := XNil;
end;

// Closes AX over instantiation AInst: an open generic parameter of the
// instantiated type becomes its actual argument; an instantiation whose args
// mention open parameters is re-instantiated with them closed.
function TPasSemaProject.SubstX(const AX: TSemaXType;
  AInst, ADepth: Integer): TSemaXType;
var
  LInst: TSemaInstance;
  LIdents: TArray<Integer>;
  LIdx: Integer;
  LArgs: TArray<TSemaXType>;
begin
  Result := AX;
  if (AInst = NIL_INST) or (ADepth > 16) or not XValid(AX) then
    Exit;
  LInst := FInstances[AInst];
  if (AX.UnitId = LInst.UnitId) and
     (FModels[AX.UnitId].Symbols[AX.Sym].Kind = skGenericParam) then
  begin
    LIdents := GenericParamIdents(LInst.UnitId, LInst.Sym);
    for LIdx := 0 to High(LIdents) do
      if LIdents[LIdx] = FModels[AX.UnitId].Symbols[AX.Sym].DeclNode then
      begin
        if LIdx <= High(LInst.Args) then
          Exit(LInst.Args[LIdx]);
        Exit;
      end;
    Exit;   // someone else's parameter (an enclosing generic) — leave open
  end;
  if AX.Inst <> NIL_INST then
  begin
    LArgs := Copy(FInstances[AX.Inst].Args);
    for LIdx := 0 to High(LArgs) do
      LArgs[LIdx] := SubstX(LArgs[LIdx], AInst, ADepth + 1);
    Result.Inst := Instantiate(XPlain(AX.UnitId, AX.Sym), LArgs);
  end;
end;

// A type designator (nkIdent / nkMember / nkTypeArgs) as a cross-model type,
// reading the resolver's RefMap first, then the project's ExtRefMap. For
// nkTypeArgs the args are resolved too and the instantiation is registered;
// an unresolved arg degrades to the plain (open) generic.
function TPasSemaProject.ResolveTypeExpr(AId, ANode: Integer): TSemaXType;
var
  LM: TPasSemaModel;
  LName, LSym, LArgNode: Integer;
  LExt: TPasExtRef;
  LBase, LArg: TSemaXType;
  LArgs: TArray<TSemaXType>;
begin
  Result := XNil;
  if ANode = NIL_NODE then
    Exit;
  LM := FModels[AId];
  case LM.Tree.Nodes[ANode].Kind of
    nkIdent, nkMember:
      begin
        LName := ANode;
        if LM.Tree.Nodes[ANode].Kind = nkMember then
        begin
          LName := LM.Tree.Nodes[ANode].FirstChild;
          while (LName <> NIL_NODE) and
                (LM.Tree.Nodes[LName].NextSibling <> NIL_NODE) do
            LName := LM.Tree.Nodes[LName].NextSibling;
          if LName = NIL_NODE then
            Exit;
        end;
        LSym := LM.RefMap[LName];
        if (LSym <> NIL_SYM) and (LM.Symbols[LSym].Kind in
           [skType, skBuiltinType, skGenericParam]) then
          Exit(XPlain(AId, LSym));
        if LM.ExtRefMap.TryGetValue(LName, LExt) and
           (FModels[LExt.UnitId].Symbols[LExt.Sym].Kind in
            [skType, skBuiltinType, skGenericParam]) then
          Exit(XPlain(LExt.UnitId, LExt.Sym));
      end;
    nkTypeArgs:
      begin
        LBase := ResolveTypeExpr(AId, LM.Tree.Nodes[ANode].FirstChild);
        if not XValid(LBase) then
          Exit;
        LArgs := nil;
        LArgNode := LM.Tree.Nodes[LM.Tree.Nodes[ANode].FirstChild].NextSibling;
        while LArgNode <> NIL_NODE do
        begin
          LArg := ResolveTypeExpr(AId, LArgNode);
          if not XValid(LArg) then
            Exit(LBase);
          LArgs := LArgs + [LArg];
          LArgNode := LM.Tree.Nodes[LArgNode].NextSibling;
        end;
        Result := LBase;
        if (Length(LArgs) > 0) and
           (Length(GenericParamIdents(LBase.UnitId, LBase.Sym)) =
            Length(LArgs)) then
          Result.Inst := Instantiate(LBase, LArgs);
      end;
  end;
end;

// Member lookup by name on a type, following type aliases and the first
// heritage entry (ancestor class / base interface) across models, closing
// each hop over the current instantiation. ACtx returns the instantiation
// in whose frame the found member's declared type must be substituted.
function TPasSemaProject.FindMemberX(const ABase: TSemaXType;
  const ANameLower: string; out AMemMid, AMemSym: Integer;
  out ACtx: Integer): Boolean;
var
  LCur, LNext: TSemaXType;
  LM: TPasSemaModel;
  LScope, LDef, LChild, LDepth, LFound: Integer;
begin
  Result := False;
  AMemMid := NIL_SYM;
  AMemSym := NIL_SYM;
  ACtx := NIL_INST;
  LCur := ABase;
  for LDepth := 1 to 32 do
  begin
    if not XValid(LCur) then
      Exit;
    LM := FModels[LCur.UnitId];
    if not (LM.Symbols[LCur.Sym].Kind in [skType, skBuiltinType]) then
      Exit;
    LScope := LM.Symbols[LCur.Sym].MemberScope;
    if LScope <> NIL_SCOPE then
    begin
      LFound := LM.FindLocal(LScope, ANameLower);
      if LFound <> NIL_SYM then
      begin
        AMemMid := LCur.UnitId;
        AMemSym := LFound;
        ACtx := LCur.Inst;
        Exit(True);
      end;
    end;
    LDef := TypeDefNodeOf(LCur.UnitId, LCur.Sym);
    if LDef = NIL_NODE then
      Exit;   // a builtin (TObject...) or non-decl type — nowhere to go
    case LM.Tree.Nodes[LDef].Kind of
      nkIdent, nkMember, nkTypeArgs:
        LNext := ResolveTypeExpr(LCur.UnitId, LDef);   // type alias
      nkClassType, nkInterfaceType, nkRecordType, nkObjectType:
        begin
          // Leading nkIdent/nkMember/nkTypeArgs children are the heritage
          // list; the FIRST is the ancestor (a class's other entries are
          // implemented interfaces — their members must be implemented in
          // the class anyway, so they are not followed).
          LChild := LM.Tree.Nodes[LDef].FirstChild;
          while (LChild <> NIL_NODE) and not (LM.Tree.Nodes[LChild].Kind in
            [nkIdent, nkMember, nkTypeArgs]) do
            LChild := LM.Tree.Nodes[LChild].NextSibling;
          if LChild = NIL_NODE then
            Exit;
          LNext := ResolveTypeExpr(LCur.UnitId, LChild);
        end;
    else
      Exit;
    end;
    LNext := SubstX(LNext, LCur.Inst, 0);
    if XValid(LNext) and (LNext.UnitId = LCur.UnitId) and
       (LNext.Sym = LCur.Sym) and (LNext.Inst = LCur.Inst) then
      Exit;   // self-referential alias — bail
    LCur := LNext;
  end;
end;

// True when a routine symbol's declaration is `constructor ...` (the nkRoutine
// node's first visible token is the routine keyword itself).
function TPasSemaProject.IsConstructorSym(AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
  LName, LRoutine, LTok: Integer;
begin
  Result := False;
  LM := FModels[AMid];
  if LM.Symbols[ASym].Kind <> skRoutine then
    Exit;
  LName := LM.Symbols[ASym].DeclNode;
  if LName = NIL_NODE then
    Exit;
  LRoutine := LM.Tree.Nodes[LName].Parent;
  if (LRoutine = NIL_NODE) or (LM.Tree.Nodes[LRoutine].Kind <> nkRoutine) then
    Exit;
  LTok := LM.Tree.Nodes[LRoutine].FirstToken;
  if (LTok >= 0) and (LTok <= High(LM.Tree.Source.Visible)) then
    Result := SameText(LM.Tree.Source.VisibleText(LTok), 'constructor');
end;

// Declared-type pass: for every symbol whose type expression did not bind to
// a plain local type, resolve it cross-model / as an instantiation.
procedure TPasSemaProject.BindTypesX(AId: Integer);
var
  LM: TPasSemaModel;
  LSym: Integer;
  LX: TSemaXType;
begin
  LM := FModels[AId];
  for LSym := 0 to LM.SymCount - 1 do
    if LM.Symbols[LSym].TypeNode <> NIL_NODE then
    begin
      LX := ResolveTypeExpr(AId, LM.Symbols[LSym].TypeNode);
      if XValid(LX) and ((LM.Symbols[LSym].TypeSym = NIL_SYM) or
         (LX.Inst <> NIL_INST)) then
        LM.SymTypeX.AddOrSetValue(LSym, LX);
    end;
end;

// Expression pass: bottom-up over the whole tree, typing what the intra-unit
// typer could not — cross-model idents/members (with ancestor/alias walk),
// constructor calls, casts, generic-parameter substitution. Also records the
// member references it discovers (RefMap locally, ExtRefMap across models) —
// typing and navigation only, NO diagnostics.
procedure TPasSemaProject.CrossType(AId: Integer);
var
  LM: TPasSemaModel;
  LX: TArray<TSemaXType>;

  // A node's best-known type: this pass's result, else the intra-unit one.
  function GetX(N: Integer): TSemaXType;
  begin
    Result := LX[N];
    if not XValid(Result) and (LM.ExprType[N] <> NIL_SYM) then
      Result := XPlain(AId, LM.ExprType[N]);
  end;

  // The (mid, sym) a callee designator resolved to (after the member pass
  // below has enriched RefMap/ExtRefMap).
  function TargetSym(N: Integer; out AMid, ASym: Integer): Boolean;
  var
    LName: Integer;
    LExt: TPasExtRef;
  begin
    Result := False;
    AMid := AId;
    case LM.Tree.Nodes[N].Kind of
      nkIdent:
        LName := N;
      nkMember:
        begin
          LName := LM.Tree.Nodes[N].FirstChild;
          while (LName <> NIL_NODE) and
                (LM.Tree.Nodes[LName].NextSibling <> NIL_NODE) do
            LName := LM.Tree.Nodes[LName].NextSibling;
          if LName = NIL_NODE then
            Exit;
        end;
      nkTypeArgs:
        Exit(TargetSym(LM.Tree.Nodes[N].FirstChild, AMid, ASym));
    else
      Exit;
    end;
    ASym := LM.RefMap[LName];
    if ASym <> NIL_SYM then
      Exit(True);
    if LM.ExtRefMap.TryGetValue(LName, LExt) then
    begin
      AMid := LExt.UnitId;
      ASym := LExt.Sym;
      Exit(True);
    end;
  end;

  // True when at least one overload of the routine admits the call's
  // argument count (or a candidate is variadic / has no param info).
  function CallArityFits(ACall, AMid, AHead: Integer): Boolean;
  var
    LArg, LArgs, LCand, LReq, LTot: Integer;
    LVariadic: Boolean;
  begin
    LArgs := 0;
    LArg := LM.Tree.Nodes[LM.Tree.Nodes[ACall].FirstChild].NextSibling;
    while LArg <> NIL_NODE do
    begin
      Inc(LArgs);
      LArg := LM.Tree.Nodes[LArg].NextSibling;
    end;
    LCand := AHead;
    while LCand <> NIL_SYM do
    begin
      if FModels[AMid].Symbols[LCand].Kind <> skRoutine then
        Break;
      if not RoutineArity(AMid, LCand, LReq, LTot, LVariadic) then
        Exit(True);   // no param info (builtin) — cannot judge, allow
      if LVariadic or ((LArgs >= LReq) and (LArgs <= LTot)) then
        Exit(True);
      LCand := FModels[AMid].Symbols[LCand].NextOverload;
    end;
    Result := False;
  end;

  // The type a member access yields: the member's declared type (routines:
  // result type; constructors: the base type itself, so `TDerived.Create` —
  // parsed as a plain member when argless — types as TDerived), substituted
  // in the instantiation frame it was found in; a nested type member is the
  // type itself (designator).
  function MemberTypeX(AMid, ASym, AInstCtx: Integer;
    const ABaseX: TSemaXType): TSemaXType;
  begin
    case FModels[AMid].Symbols[ASym].Kind of
      skType, skBuiltinType:
        Result := XPlain(AMid, ASym);
      skRoutine:
        if IsConstructorSym(AMid, ASym) then
          Result := ABaseX
        else
          Result := SubstX(DeclTypeX(AMid, ASym), AInstCtx, 0);
      skVar, skConst, skField, skParam, skProperty, skEnumValue:
        Result := SubstX(DeclTypeX(AMid, ASym), AInstCtx, 0);
    else
      Result := XNil;
    end;
  end;

  procedure Walk(N: Integer);
  var
    LChild, LBase, LName, LSym, LMemMid, LMemSym, LCtx: Integer;
    LExt: TPasExtRef;
    LBX: TSemaXType;
  begin
    LChild := LM.Tree.Nodes[N].FirstChild;
    while LChild <> NIL_NODE do
    begin
      Walk(LChild);
      LChild := LM.Tree.Nodes[LChild].NextSibling;
    end;

    case LM.Tree.Nodes[N].Kind of
      nkIdent:
        begin
          LSym := LM.RefMap[N];
          if LSym <> NIL_SYM then
            case LM.Symbols[LSym].Kind of
              skVar, skConst, skField, skParam, skProperty, skRoutine:
                LX[N] := DeclTypeX(AId, LSym);
              skType, skBuiltinType, skGenericParam:
                LX[N] := XPlain(AId, LSym);
            end
          else if LM.ExtRefMap.TryGetValue(N, LExt) then
            case FModels[LExt.UnitId].Symbols[LExt.Sym].Kind of
              skVar, skConst, skField, skParam, skProperty, skRoutine:
                LX[N] := DeclTypeX(LExt.UnitId, LExt.Sym);
              skType, skBuiltinType:
                LX[N] := XPlain(LExt.UnitId, LExt.Sym);
            end;
        end;

      nkParen:
        if LM.Tree.Nodes[N].FirstChild <> NIL_NODE then
          LX[N] := GetX(LM.Tree.Nodes[N].FirstChild);

      nkTypeArgs:
        LX[N] := ResolveTypeExpr(AId, N);

      nkMember:
        begin
          LBase := LM.Tree.Nodes[N].FirstChild;
          if LBase = NIL_NODE then
            Exit;
          LName := LM.Tree.Nodes[LBase].NextSibling;
          if (LName = NIL_NODE) or
             (LM.Tree.Nodes[LName].Kind <> nkIdent) then
            Exit;
          LBX := GetX(LBase);
          LSym := LM.RefMap[LName];
          if LSym <> NIL_SYM then
            LX[N] := MemberTypeX(AId, LSym, LBX.Inst, LBX)
          else if LM.ExtRefMap.TryGetValue(LName, LExt) then
            LX[N] := MemberTypeX(LExt.UnitId, LExt.Sym, LBX.Inst, LBX)
          else if XValid(LBX) and FindMemberX(LBX,
            LowerCase(LM.Tree.NodeText(LName)), LMemMid, LMemSym, LCtx) then
          begin
            // Record the discovered member reference for navigation.
            if LMemMid = AId then
              LM.RefMap[LName] := LMemSym
            else
            begin
              LExt.UnitId := LMemMid;
              LExt.Sym := LMemSym;
              LM.ExtRefMap.AddOrSetValue(LName, LExt);
            end;
            LX[N] := MemberTypeX(LMemMid, LMemSym, LCtx, LBX);
          end;
        end;

      nkCall:
        begin
          LBase := LM.Tree.Nodes[N].FirstChild;   // the callee
          if (LBase <> NIL_NODE) and TargetSym(LBase, LMemMid, LMemSym) then
            case FModels[LMemMid].Symbols[LMemSym].Kind of
              skRoutine:
                if IsConstructorSym(LMemMid, LMemSym) and
                   (LM.Tree.Nodes[LBase].Kind = nkMember) then
                  // T.Create / TList<Integer>.Create -> the class type itself
                  LX[N] := GetX(LM.Tree.Nodes[LBase].FirstChild)
                else if CallArityFits(N, LMemMid, LMemSym) then
                  // The callee's X is already the substituted result type.
                  LX[N] := GetX(LBase);
                  // else: no local overload admits the arg count — the real
                  // callee is likely an unseen same-named overload; leave
                  // the call untyped rather than claim the wrong result.
              skType, skBuiltinType:
                LX[N] := GetX(LBase);   // a cast (incl. instantiated generic)
            end;
        end;

      nkInlineIf:
        begin
          LChild := LM.Tree.Nodes[N].FirstChild;   // cond, then, else
          if (LChild <> NIL_NODE) and
             (LM.Tree.Nodes[LChild].NextSibling <> NIL_NODE) then
            LX[N] := GetX(LM.Tree.Nodes[LChild].NextSibling);
        end;
    end;
  end;

var
  LNode: Integer;
begin
  LM := FModels[AId];
  SetLength(LX, Length(LM.Tree.Nodes));
  for LNode := 0 to High(LX) do
    LX[LNode] := XNil;
  if Length(LX) > 0 then
    Walk(0);
  // Persist only what ADDS to the intra-unit result: a type for a locally
  // untyped node, an instantiation, or a type living in another model.
  for LNode := 0 to High(LX) do
    if XValid(LX[LNode]) and ((LM.ExprType[LNode] = NIL_SYM) or
       (LX[LNode].Inst <> NIL_INST) or (LX[LNode].UnitId <> AId)) then
      LM.ExprTypeX.AddOrSetValue(LNode, LX[LNode]);
end;

function TPasSemaProject.InstanceCount: Integer;
begin
  Result := FInstances.Count;
end;

function TPasSemaProject.Instance(AInst: Integer): TSemaInstance;
begin
  Result := FInstances[AInst];
end;

function TPasSemaProject.XTypeText(const AX: TSemaXType): string;
var
  LIdx: Integer;
begin
  if not XValid(AX) then
    Exit('?');
  Result := FModels[AX.UnitId].Symbols[AX.Sym].Name;
  if AX.Inst <> NIL_INST then
  begin
    Result := Result + '<';
    for LIdx := 0 to High(FInstances[AX.Inst].Args) do
    begin
      if LIdx > 0 then
        Result := Result + ',';
      Result := Result + XTypeText(FInstances[AX.Inst].Args[LIdx]);
    end;
    Result := Result + '>';
  end;
end;

procedure TPasSemaProject.CrossResolve(AId: Integer);
var
  LModel: TPasSemaModel;
  LNode, LBase, LName, LHead, LUid, LSym: Integer;
  LExt: TPasExtRef;
  LNameLower: string;
begin
  LModel := FModels[AId];
  for LNode := 0 to High(LModel.RefMap) do
  begin
    case LModel.Tree.Nodes[LNode].Kind of
      nkMember:
        begin
          LBase := LModel.Tree.Nodes[LNode].FirstChild;
          if LBase = NIL_NODE then
            Continue;
          LName := LModel.Tree.Nodes[LBase].NextSibling;
          if (LName = NIL_NODE) or (LModel.RefMap[LName] <> NIL_SYM) or
             LModel.ExtRefMap.ContainsKey(LName) then
            Continue;
          LHead := LocalHead(LModel, LBase);
          if (LHead <> NIL_SYM) and
             (LModel.Symbols[LHead].Kind = skUnitRef) then
          begin
            LUid := UsesUnitOf(AId, LHead);
            if LUid >= 0 then
            begin
              LSym := FModels[LUid].Resolve(FModels[LUid].InterfaceScope,
                LowerCase(LModel.Tree.NodeText(LName)));
              if LSym <> NIL_SYM then
              begin
                LExt.UnitId := LUid; LExt.Sym := LSym;
                LModel.ExtRefMap.Add(LName, LExt);
              end;
            end;
          end;
        end;

      nkIdent:
        begin
          if (LModel.RefMap[LNode] <> NIL_SYM) or
             LModel.ExtRefMap.ContainsKey(LNode) then
            Continue;
          if (LNode > High(LModel.NodeScope)) or
             (LModel.NodeScope[LNode] = NIL_SCOPE) then
            Continue;   // not a reference in a real scope (e.g. uses name)
          // The member name of `A.B` is resolved via A's scope (nkMember case),
          // never as a plain identifier — it is not an undeclared-id candidate.
          LBase := LModel.Tree.Nodes[LNode].Parent;
          if (LBase <> NIL_NODE) and
             (LModel.Tree.Nodes[LBase].Kind = nkMember) and
             (LModel.Tree.Nodes[LBase].FirstChild <> LNode) then
            Continue;
          LNameLower := LowerCase(LModel.Tree.NodeText(LNode));
          if (LNameLower = 'result') or (LNameLower = 'self') then
            Continue;   // implicit routine/method names
          if FindInUses(AId, LNameLower, LUid, LSym) then
          begin
            LExt.UnitId := LUid; LExt.Sym := LSym;
            LModel.ExtRefMap.Add(LNode, LExt);
          end
          else if LModel.AllUsesResolved then
            EmitE2003(LModel, LNode);
        end;
    end;
  end;
end;

function TPasSemaProject.AnalyzeFile(const AMainFile: string): Integer;
var
  LIdx: Integer;
  LPaths: TArray<string>;
  LPath: string;
begin
  Result := LoadFile(AMainFile);
  if Result < 0 then
    Exit;
  // Pre-load the main unit's direct uses in parallel; ResolveUses below then
  // finds every one already cached (it stays the single source of truth for
  // UnitId assignment and the AllUsesResolved gate).
  LPaths := nil;
  for LIdx := 0 to High(FModels[Result].UsesList) do
    if FSM.ResolveUnit(FModels[Result].UsesList[LIdx].NameFull,
      FModels[Result].UsesList[LIdx].InPath, FFiles[Result], LPath) then
      LPaths := LPaths + [LPath];
  LoadFilesParallel(LPaths);
  ResolveUses(Result);
  CrossResolve(Result);
  CheckCalls(Result);
  // Declared types for EVERY loaded model first (the expression pass reads
  // used units' SymTypeX), then expressions for the requested unit only.
  for LIdx := 0 to FModels.Count - 1 do
    BindTypesX(LIdx);
  CrossType(Result);
end;

procedure TPasSemaProject.AnalyzeDirectory(const ARoot: string);
var
  LFile, LExt: string;
  LPaths: TArray<string>;
  LN, LIdx: Integer;
begin
  FSM.BuildUnitIndex(ARoot);
  LPaths := nil;
  for LFile in TDirectory.GetFiles(ARoot, '*.*',
    TSearchOption.soAllDirectories) do
  begin
    LExt := LowerCase(TPath.GetExtension(LFile));
    if (LExt = '.pas') or (LExt = '.dpr') then
      LPaths := LPaths + [LFile];
  end;
  LoadFilesParallel(LPaths);
  LN := FModels.Count;   // snapshot: only the directory's own units get E2003
  for LIdx := 0 to LN - 1 do
    ResolveUses(LIdx);
  // Cross passes per unit write ONLY their own model and read the others'
  // Phase-1 state (frozen once every unit is loaded) — safe to farm out.
  ForEachIndex(LN - 1,
    procedure(AIdx: Integer)
    begin
      CrossResolve(AIdx);
    end);
  ForEachIndex(LN - 1,
    procedure(AIdx: Integer)
    begin
      CheckCalls(AIdx);
    end);
  // Cross typing stays SEQUENTIAL by design: Instantiate mutates the shared
  // instance table, and CrossType both writes a model's RefMap/ExtRefMap and
  // reads other models' — parallelizing would need locks on the hot path for
  // ~5% of the total time (measured on the full RTL).
  for LIdx := 0 to FModels.Count - 1 do
    BindTypesX(LIdx);
  for LIdx := 0 to LN - 1 do
    CrossType(LIdx);
end;

end.
