unit PasTree.Sema.Project;

{
  PasTree semantics — Phase 2 project driver: resolves `uses` to real units,
  indexes their interface symbols, re-resolves each unit's external references
  against them, and emits E2003 for genuinely undeclared identifiers.

  Per-unit models (Phase 1) are kept as-is; a cross-unit resolution is recorded
  in the referring model's ExtRefMap as (unitId, symbolId). E2003 is emitted
  only when every `uses` unit of the referring unit resolved (AllUsesResolved),
  so an unindexable import never yields a false undeclared-identifier.
}

interface

uses
  System.Generics.Collections,
  PasTree.Preprocessor,
  PasTree.Platforms,
  PasTree.SourceManager,
  PasTree.Ast,
  PasTree.Sema.Model;

type
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
    function LoadFile(const APath: string): Integer;
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
  public
    constructor Create(APlatform: TPasPlatform;
      const ASearchPaths: TArray<string>; const AExtraDefines: TArray<string>);
    destructor Destroy; override;
    function ModelCount: Integer;
    function Model(AId: Integer): TPasSemaModel;
    function ModelFile(AId: Integer): string;
    // Analyze one unit + its direct uses; returns the main unit's model id.
    function AnalyzeFile(const AMainFile: string): Integer;
    // Analyze every .pas/.dpr under a directory (indexed first).
    procedure AnalyzeDirectory(const ARoot: string);
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
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
end;

destructor TPasSemaProject.Destroy;
begin
  FByPath.Free;
  FFiles.Free;
  FModels.Free;
  FPP.Free;
  FDefines.Free;
  FSM.Free;
  inherited;
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
    Exit;
  if not TFile.Exists(LFull) then
    Exit(-1);
  try
    LPre := FPP.Process(LFull);
    LTree := TPasParser.ParseFile(LPre, LDiags);
    LModel := TPasSemaResolver.Analyze(LTree);
  except
    on Exception do
      Exit(-1);   // tolerate a unit that fails to parse; treat as unresolvable
  end;
  Result := FModels.Add(LModel);
  FFiles.Add(LFull);
  FByPath.Add(LKey, Result);
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
begin
  Result := LoadFile(AMainFile);
  if Result < 0 then
    Exit;
  ResolveUses(Result);
  CrossResolve(Result);
  CheckCalls(Result);
end;

procedure TPasSemaProject.AnalyzeDirectory(const ARoot: string);
var
  LFile, LExt: string;
  LN, LIdx: Integer;
begin
  FSM.BuildUnitIndex(ARoot);
  for LFile in TDirectory.GetFiles(ARoot, '*.*',
    TSearchOption.soAllDirectories) do
  begin
    LExt := LowerCase(TPath.GetExtension(LFile));
    if (LExt = '.pas') or (LExt = '.dpr') then
      LoadFile(LFile);
  end;
  LN := FModels.Count;   // snapshot: only the directory's own units get E2003
  for LIdx := 0 to LN - 1 do
    ResolveUses(LIdx);
  for LIdx := 0 to LN - 1 do
    CrossResolve(LIdx);
  for LIdx := 0 to LN - 1 do
    CheckCalls(LIdx);
end;

end.
