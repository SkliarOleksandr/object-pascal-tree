program PasTreeCompleteOracle;

{ The completion CORPUS SELF-ORACLE (local/COMPLETION-PLAN.md sec. 6): for every
  RESOLVED identifier reference in an analyzed corpus, completion invoked at
  that identifier must OFFER that name. The corpus is its own oracle - no
  goldens to write or maintain: RefMap/ExtRefMap say what the analysis proved
  each name means, and a list that would not have offered it is a context-
  classification or collection bug at that exact position.

  What a HIT means: the item LIST contains the reference's name (case-
  insensitive). Name-level, not symbol-identity-level, on purpose: the list
  deduplicates by name with shadowing precedence, so the surviving item may
  legitimately be a different symbol of the same name (an override, an
  overload head); identity-level checking is a ranking question, not a
  presence one.

  What is skipped, and why it is a skip rather than a miss:
  - the DECLARATION site itself (naming something new is not a completion
    position);
  - references whose token lives in an $I INCLUDE file (the caret machinery
    is main-file-only - the same GAP navigation row 14 documents);
  - skUnitRef targets (uses names complete as dotted UNIT names, a different
    match shape) and skLabel targets (labels complete after `goto` only -
    a documented stage-E gap).

  Usage: PasTreeCompleteOracle <dir|file.dpr|file.dproj> [-p:<platform>]
           [-max:<N>] [-list] [-overlay] [-at:<file>|<line>|<col>]
           [-studio:<dir>] [-L<dir>]

  -p:      platform (default Win32, matching the flat corpora; a .dproj
           carries its own and wins).
  -max:N   sample cap PER UNIT (default 200), stride-spread so the sample
           covers the whole file rather than its head. -max:0 = everything.
  -list    print every miss site (default: the first 25).
  -overlay the overlay oracle (T3) instead of the self-oracle: at every dot
           and every call's `(`, completion over a fresh overlay model of the
           file's unchanged text must list the member names, and signature
           help the targets, that the project's own model of the file gives.
           -max caps dots and calls per unit separately.
  -at:     one verbose request instead of the sweep - the drill-down mode.
  -studio: RAD Studio root for the RTL/VCL/FMX source trees (.dproj targets;
           $BDS when unset), same contract as PasTreeSemaProject's.
  -L<dir>  extra search path, repeatable (the registry-path lists for the
           real projects).

  A .dproj target is driven the way PasTreeSemaProject's -dproj mode drives
  one: platform, search paths, defines, namespaces and unit aliases read from
  the project file, AnalyzeStaged over its main source - so the oracle runs
  against the same closure the demo and the LSP server analyze. }

{$APPTYPE CONSOLE}
{$MAXSTACKSIZE $01000000}   // 16 MB per thread: README, "The stack every host should reserve"

uses
  System.SysUtils,
  System.Math,
  System.Diagnostics,
  System.IOUtils,
  System.Generics.Collections,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Dcu in '..\source\PasTree.Dcu.pas',
  PasTree.Dcu.Source in '..\source\PasTree.Dcu.Source.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.Project in '..\source\PasTree.Project.pas',
  PasTree.DProj in '..\source\PasTree.DProj.pas',
  PasTree.Sema.Diagnostics in '..\source\PasTree.Sema.Diagnostics.pas',
  PasTree.Sema.Model in '..\source\PasTree.Sema.Model.pas',
  PasTree.Sema.Builtins in '..\source\PasTree.Sema.Builtins.pas',
  PasTree.Sema.Resolver in '..\source\PasTree.Sema.Resolver.pas',
  PasTree.Sema.Project in '..\source\PasTree.Sema.Project.pas',
  PasTree.Sema.Complete in '..\source\PasTree.Sema.Complete.pas';

type
  TMissRow = record
    Site: string;      // file(line,col)
    Name: string;
    Context: TPasComplContext;
  end;

var
  GPlatform: TPasPlatform;
  GProj: TPasSemaProject;
  GPath: string;
  GExtraPaths: TArray<string>;
  GMaxPerUnit: Integer;
  GListAll: Boolean;
  GIdx: Integer;
  GArg: string;
  GSampled, GHits: Int64;
  GCtxSampled, GCtxHits: array[TPasComplContext] of Int64;
  GNoAnswer: Int64;              // CompleteAt returned False (refused caret)
  GMisses: TList<TMissRow>;
  GSW: TStopwatch;

const
  CTX_NAMES: array[TPasComplContext] of string = ('none', 'member', 'uses',
    'type', 'statement', 'expression', 'recfield', 'inherited', 'label',
    'propread', 'propwrite');

// The Studio SOURCE trees a .dproj needs on top of its own paths - copied
// from PasTreeSemaProject's -dproj mode (see the note there for why each
// subdirectory earns its place).
function StudioSearchPaths(const ARoot: string): TArray<string>;
const
  SUBS: array[0..8] of string = ('source\rtl\sys', 'source\rtl\common',
    'source\rtl\win', 'source\rtl\win\winrt', 'source\rtl\net',
    'source\databinding\engine', 'source\xml', 'source\vcl', 'source\fmx');
var
  LDir: string;
begin
  Result := nil;
  if ARoot = '' then
    Exit;
  for var LSub in SUBS do
  begin
    LDir := TPath.Combine(ARoot, LSub);
    if TDirectory.Exists(LDir) then
      Result := Result + [LDir];
  end;
end;

procedure OracleOneModel(AMid: Integer);
var
  LM: TPasSemaModel;
  LComp: TPasCompletion;
  LRefs: TArray<Integer>;
  LCount, LNode, LIdx, LSym, LVis, LRaw, LLine, LCol, LUp: Integer;
  LStride: Double;
  LExt: TPasExtRef;
  LTName: string;
  LCtx: TPasComplContext;
  LItems: TArray<TPasComplItem>;
  LHit: Boolean;
  LTS: TPasTokenStream;
  LMiss: TMissRow;
begin
  LM := GProj.Model(AMid);
  if (LM = nil) or (LM.Tree.Nodes = nil) then
    Exit;
  LTS := LM.Tree.Source.Files[0];

  // Pass 1: collect the oracle-eligible reference nodes.
  SetLength(LRefs, 256);
  LCount := 0;
  for LNode := 0 to High(LM.RefMap) do
  begin
    if LM.Tree.Nodes[LNode].Kind <> nkIdent then
      Continue;
    LSym := LM.RefMap[LNode];
    if LSym <> NIL_SYM then
    begin
      if LM.Symbols[LSym].DeclNode = LNode then
        Continue;   // the declaration site names something new
      if LM.Symbols[LSym].Kind in [skUnitRef, skLabel] then
        Continue;
      if LM.Symbols[LSym].Name = '' then
        Continue;
    end
    else if LM.ExtRefMap.TryGetValue(LNode, LExt) then
    begin
      if GProj.Model(LExt.UnitId).Symbols[LExt.Sym].Kind in
        [skUnitRef, skLabel] then
        Continue;
      if GProj.Model(LExt.UnitId).Symbols[LExt.Sym].Name = '' then
        Continue;
    end
    else
      Continue;   // unresolved - nothing proven to offer
    // Main file only: the caret machinery does not address $I includes.
    LVis := LM.Tree.Nodes[LNode].FirstToken;
    if (LVis < 0) or (LVis > High(LM.Tree.Source.Visible)) or
       (LM.Tree.Source.Visible[LVis].FileId <> 0) then
      Continue;
    // The MODULE HEADER's own dotted name is a naming position, not a
    // completion one (the engine refuses it by design) - a segment of it
    // can still RESOLVE (`FMX.Dialogs` of `unit FMX.Dialogs.Default`).
    LUp := LNode;
    while (LUp <> NIL_NODE) and
          (LM.Tree.Nodes[LUp].Kind in [nkIdent, nkMember]) do
      LUp := LM.Tree.Nodes[LUp].Parent;
    if (LUp <> NIL_NODE) and (LM.Tree.Nodes[LUp].Kind in
      [nkUnit, nkProgram, nkLibrary, nkPackage]) then
      Continue;
    if LCount = Length(LRefs) then
      SetLength(LRefs, LCount * 2);
    LRefs[LCount] := LNode;
    Inc(LCount);
  end;
  if LCount = 0 then
    Exit;

  // Pass 2: stride-sample and ask.
  LComp := TPasCompletion.Create(LM, GProj, AMid);
  try
    var LTake := LCount;
    if (GMaxPerUnit > 0) and (LTake > GMaxPerUnit) then
      LTake := GMaxPerUnit;
    LStride := LCount / LTake;   // >= 1; max index Trunc((LTake-1)*stride) < LCount
    for LIdx := 0 to LTake - 1 do
    begin
      LNode := LRefs[Min(Trunc(LIdx * LStride), LCount - 1)];

      LSym := LM.RefMap[LNode];
      if LSym <> NIL_SYM then
        LTName := LM.Symbols[LSym].Name
      else if LM.ExtRefMap.TryGetValue(LNode, LExt) then
        LTName := GProj.Model(LExt.UnitId).Symbols[LExt.Sym].Name
      else
        // Pass 1 guarantees one of the two maps answers; if that invariant
        // ever breaks, fail LOUDLY instead of scoring against Default() =
        // model 0 / symbol 0.
        raise Exception.CreateFmt('oracle pass-2 node %d lost its binding',
          [LNode]);

      LVis := LM.Tree.Nodes[LNode].FirstToken;
      LRaw := LM.Tree.Source.Visible[LVis].TokenIndex;
      LTS.OffsetToLineCol(LTS.Tokens[LRaw].Start, LLine, LCol);

      Inc(GSampled);
      // The dataflow through try/except is beyond W1036's sight - the
      // pre-init trades an unfixable warning for a pedantic H2077.
      LHit := False;
      // Caret one character INTO the identifier: a one-letter prefix, the
      // ordinary mid-typing shape.
      try
      if not LComp.CompleteAt(LLine, LCol + 1, LCtx, LItems) then
      begin
        Inc(GNoAnswer);
        LCtx := ccNone;
        LHit := False;
      end
      else
      begin
        LHit := False;
        for var LItIdx := 0 to High(LItems) do
          if SameText(LItems[LItIdx].Name, LTName) then
          begin
            LHit := True;
            Break;
          end;
      end;
      except
        on E: Exception do
        begin
          Writeln(ErrOutput, Format('EXCEPTION %s ''%s'' at %s(%d,%d): %s',
            [E.ClassName, LTName, GProj.ModelFile(AMid), LLine, LCol,
             E.Message]));
          LCtx := ccNone;
          LHit := False;
        end;
      end;
      Inc(GCtxSampled[LCtx]);
      if LHit then
      begin
        Inc(GHits);
        Inc(GCtxHits[LCtx]);
      end
      else
      begin
        LMiss.Site := Format('%s(%d,%d)', [GProj.ModelFile(AMid), LLine,
          LCol]);
        LMiss.Name := LTName;
        LMiss.Context := LCtx;
        GMisses.Add(LMiss);
      end;
    end;
  finally
    LComp.Free;
  end;
end;

// -at:<file>|<line>|<col> - one verbose request instead of the sweep: prints
// the caret classification, the context and every item, for drilling a miss.
procedure ProbeAt(const ASpec: string);
var
  LParts: TArray<string>;
  LMid, LLine, LCol, LIdx: Integer;
  LComp: TPasCompletion;
  LInfo: TPasCaretInfo;
  LCtx: TPasComplContext;
  LItems: TArray<TPasComplItem>;
begin
  LParts := ASpec.Split(['|']);
  if Length(LParts) <> 3 then
  begin
    Writeln('-at wants <file>|<line>|<col>');
    Exit;
  end;
  LMid := -1;
  for LIdx := 0 to GProj.ModelCount - 1 do
    if SameText(ExtractFileName(GProj.ModelFile(LIdx)),
      ExtractFileName(LParts[0])) then
    begin
      LMid := LIdx;
      Break;
    end;
  if LMid < 0 then
  begin
    Writeln('not analyzed: ', LParts[0]);
    Exit;
  end;
  LLine := StrToIntDef(LParts[1], 1);
  LCol := StrToIntDef(LParts[2], 1);
  LComp := TPasCompletion.Create(GProj.Model(LMid), GProj, LMid);
  try
    if not LComp.CompleteAt(LLine, LCol, LInfo, LCtx, LItems) then
    begin
      Writeln(Format('refused: caret kind %d', [Ord(LInfo.Kind)]));
      Exit;
    end;
    Writeln(Format('context %s, caret kind %d, prefix ''%s'', dotbase %d,'
      + ' node %d scope %d, %d withUnopened, %d items:',
      [CTX_NAMES[LCtx], Ord(LInfo.Kind), LInfo.Prefix, LInfo.DotBase,
       LInfo.Node, LInfo.Scope, Length(GProj.Model(LMid).WithUnopened),
       Length(LItems)]));
    // The scope chain with its joins - where a member SHOULD have come from.
    with GProj.Model(LMid) do
    begin
      var LSc := LInfo.Scope;
      var LHops := 0;
      while (LSc <> NIL_SCOPE) and (LHops < 12) do
      begin
        var LAdd := '';
        for var LA in Scopes[LSc].Additional do
          LAdd := LAdd + Format(' +%d(k%d,st%d)',
            [LA, Ord(Scopes[LA].Kind), Scopes[LA].StructSym]);
        Writeln(Format('  scope %d kind=%d struct=%d%s',
          [LSc, Ord(Scopes[LSc].Kind), Scopes[LSc].StructSym, LAdd]));
        LSc := Scopes[LSc].Parent;
        Inc(LHops);
      end;
    end;
    // Which unopened withs enclose the caret, and does the with pass's own
    // typer answer for their targets? (The injection's two preconditions.)
    with GProj.Model(LMid) do
      for LIdx := 0 to High(WithUnopened) do
      begin
        var LBody := Tree.Nodes[WithUnopened[LIdx]].FirstChild;
        while Tree.Nodes[LBody].NextSibling <> NIL_NODE do
          LBody := Tree.Nodes[LBody].NextSibling;
        var LIn := LInfo.Node;
        while (LIn <> NIL_NODE) and (LIn <> LBody) do
          LIn := Tree.Nodes[LIn].Parent;
        var LTgt := Tree.Nodes[WithUnopened[LIdx]].FirstChild;
        Writeln(Format('  with#%d node=%d bodyHasCaret=%s targetX=%s',
          [LIdx, WithUnopened[LIdx], BoolToStr(LIn = LBody, True),
           GProj.XTypeText(GProj.WithTargetTypeX(LMid, LTgt))]));
      end;
    for LIdx := 0 to High(LItems) do
      Writeln(Format('  %-30s kind=%d bucket=%d mid=%d sym=%d',
        [LItems[LIdx].Name, Ord(LItems[LIdx].Kind), Ord(LItems[LIdx].Bucket),
         LItems[LIdx].Mid, LItems[LIdx].Sym]));
  finally
    LComp.Free;
  end;
end;

// ---------------------------------------------------------------------------
// -overlay (T3): the overlay pipeline against the project model. A fresh
// overlay model of the file's UNCHANGED text - what the demo and the LSP
// server build per request - must answer what the project's own model of
// that file answers: at every dot the same member names, at every call's
// `(` the same call targets. The project side is the reference (it has the
// cross-unit typing); a row the overlay misses or adds is the overlay's
// second typer drifting from the project's rules (audit B47-B50).

type
  TOvlRow = record
    Site: string;      // file(line,col)
    What: string;      // 'dot' or 'call'
    Missing: string;   // reference names the overlay lacks (first few)
    Extra: string;     // overlay names the reference lacks (first few)
  end;

var
  GOverlay: Boolean;
  GOvlSite: string;              // -site:<file>|<line>|<col> (see there)
  GOvlSM: TPasSourceManager;
  GOvlDefines: TPasDefines;
  GOvlPP: TPasPreprocessor;
  GOvlRows: TList<TOvlRow>;
  GOvlDots, GOvlDotDiff, GOvlCalls, GOvlCallDiff: Int64;
  GOvlRefusedDots: Int64;        // the reference itself refused the caret

procedure EnsureOverlayPP(const ASearchPaths: TArray<string>;
  const AExtraDefines: TArray<string>);
begin
  if GOvlPP <> nil then
    Exit;
  GOvlSM := TPasSourceManager.Create(ASearchPaths);
  // The analysis's define set: the platform's, then the project's on top -
  // what TPasSemaProject builds and what the demo's completion pipeline
  // builds (EnsureComplPP).
  GOvlDefines := CreatePlatformDefines(GPlatform);
  for var LName in AExtraDefines do
    GOvlDefines.Define(LName);
  GOvlPP := TPasPreprocessor.Create(GOvlSM, GOvlDefines,
    DEFAULT_COMPILER_VERSION, PlatformInfo(GPlatform).PointerBytes,
    PlatformInfo(GPlatform).ExtendedBytes, PlatformInfo(GPlatform).LongBytes,
    PlatformInfo(GPlatform).ExtendedAlign);
end;

// The names of a list, lower-cased, sorted, unique.
function NameSet(const AItems: TArray<TPasComplItem>): TArray<string>;
var
  LList: TList<string>;
begin
  LList := TList<string>.Create;
  try
    for var LIt in AItems do
      LList.Add(LIt.Name.ToLower);
    LList.Sort;
    Result := nil;
    for var LIdx := 0 to LList.Count - 1 do
      if (LIdx = 0) or (LList[LIdx] <> LList[LIdx - 1]) then
        Result := Result + [LList[LIdx]];
  finally
    LList.Free;
  end;
end;

// The signatures of a call's targets: name, parameter text and result,
// sorted (a multiset - two overloads may print alike).
function TargetSet(const AInfo: TPasCallInfo): TArray<string>;
var
  LList: TList<string>;
begin
  LList := TList<string>.Create;
  try
    for var LT in AInfo.Targets do
      LList.Add((LT.Name + LT.ParamsText + ':' + LT.ResultText).ToLower);
    LList.Sort;
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

// Sorted-set difference; the first few of each side as display text.
procedure DiffSets(const ARef, AOvl: TArray<string>; out AMissing,
  AExtra: string; out ADiffers: Boolean);
const
  SHOW = 6;
var
  LI, LJ, LNMiss, LNExtra, LCmp: Integer;
begin
  AMissing := '';
  AExtra := '';
  LNMiss := 0;
  LNExtra := 0;
  LI := 0;
  LJ := 0;
  while (LI < Length(ARef)) or (LJ < Length(AOvl)) do
  begin
    if LI >= Length(ARef) then
      LCmp := 1
    else if LJ >= Length(AOvl) then
      LCmp := -1
    else
      LCmp := CompareStr(ARef[LI], AOvl[LJ]);
    if LCmp = 0 then
    begin
      Inc(LI);
      Inc(LJ);
    end
    else if LCmp < 0 then
    begin
      if LNMiss < SHOW then
        AMissing := AMissing + ' ' + ARef[LI];
      Inc(LNMiss);
      Inc(LI);
    end
    else
    begin
      if LNExtra < SHOW then
        AExtra := AExtra + ' ' + AOvl[LJ];
      Inc(LNExtra);
      Inc(LJ);
    end;
  end;
  ADiffers := (LNMiss > 0) or (LNExtra > 0);
  if LNMiss > SHOW then
    AMissing := AMissing + Format(' (+%d)', [LNMiss - SHOW]);
  if LNExtra > SHOW then
    AExtra := AExtra + Format(' (+%d)', [LNExtra - SHOW]);
end;

procedure OverlayOneModel(AMid: Integer);
var
  LM, LOvModel: TPasSemaModel;
  LTS: TPasTokenStream;
  LPre: TPasPreprocessed;
  LDiags: TArray<TPasParseDiag>;
  LOvTree: TPasTree;
  LRef, LOvl: TPasCompletion;
  LDots, LCalls: TArray<Integer>;   // visible index of each `.` / `(`
  LRow: TOvlRow;

  procedure Collect;
  var
    LNode, LVis, LUp, LTok: Integer;
  begin
    for LNode := 0 to High(LM.Tree.Nodes) do
      case LM.Tree.Nodes[LNode].Kind of
        nkMember:
          begin
            // FirstToken is the dot (see PasTree.Sema.Complete's header).
            LVis := LM.Tree.Nodes[LNode].FirstToken;
            if (LVis < 0) or (LVis > High(LM.Tree.Source.Visible)) or
               (LM.Tree.Source.Visible[LVis].FileId <> 0) then
              Continue;
            LTok := LM.Tree.Source.Visible[LVis].TokenIndex;
            if LTS.Tokens[LTok].Kind <> tkDot then
              Continue;
            // A dotted name in a module header or a uses clause is a
            // naming position, not a member access.
            LUp := LNode;
            while (LUp <> NIL_NODE) and
                  (LM.Tree.Nodes[LUp].Kind in [nkIdent, nkMember]) do
              LUp := LM.Tree.Nodes[LUp].Parent;
            if (LUp <> NIL_NODE) and (LM.Tree.Nodes[LUp].Kind in
              [nkUnit, nkProgram, nkLibrary, nkPackage, nkUsesItem]) then
              Continue;
            LDots := LDots + [LVis];
          end;
        nkCall:
          begin
            LUp := LM.Tree.Nodes[LNode].FirstChild;
            if LUp = NIL_NODE then
              Continue;
            LVis := LM.Tree.Nodes[LUp].LastToken + 1;
            if (LVis < 1) or (LVis > High(LM.Tree.Source.Visible)) or
               (LM.Tree.Source.Visible[LVis].FileId <> 0) then
              Continue;
            LTok := LM.Tree.Source.Visible[LVis].TokenIndex;
            if LTS.Tokens[LTok].Kind <> tkLParen then
              Continue;
            LCalls := LCalls + [LVis];
          end;
      end;
  end;

  // Stride-sample ASites down to the per-unit cap.
  function Sample(const ASites: TArray<Integer>): TArray<Integer>;
  var
    LTake: Integer;
    LStride: Double;
  begin
    LTake := Length(ASites);
    if (GMaxPerUnit > 0) and (LTake > GMaxPerUnit) then
      LTake := GMaxPerUnit;
    SetLength(Result, LTake);
    if LTake = 0 then
      Exit;
    LStride := Length(ASites) / LTake;
    for var LIdx := 0 to LTake - 1 do
      Result[LIdx] := ASites[Min(Trunc(LIdx * LStride), High(ASites))];
  end;

  procedure CaretAfter(AVis: Integer; out ALine, ACol: Integer);
  var
    LTok: Integer;
  begin
    LTok := LM.Tree.Source.Visible[AVis].TokenIndex;
    LTS.OffsetToLineCol(LTS.Tokens[LTok].Start, ALine, ACol);
    Inc(ACol);   // right after the one-character `.` / `(`
  end;

var
  LLine, LCol: Integer;
  LCtxR, LCtxO: TPasComplContext;
  LItR, LItO: TArray<TPasComplItem>;
  LCallR, LCallO: TPasCallInfo;
  LDiffers: Boolean;
begin
  LM := GProj.Model(AMid);
  if (LM = nil) or (LM.Tree.Nodes = nil) then
    Exit;
  LTS := LM.Tree.Source.Files[0];
  LDots := nil;
  LCalls := nil;
  Collect;
  if (LDots = nil) and (LCalls = nil) then
    Exit;
  LDots := Sample(LDots);
  LCalls := Sample(LCalls);

  LPre := GOvlPP.ProcessText(GProj.ModelFile(AMid), LTS.Source);
  LOvTree := TPasParser.ParseFile(LPre, LDiags);
  LOvModel := TPasSemaResolver.Analyze(LOvTree, False, GPlatform);
  LRef := nil;
  LOvl := nil;
  try
    LRef := TPasCompletion.Create(LM, GProj, AMid);
    LOvl := TPasCompletion.Create(LOvModel, GProj, AMid);
    for var LVis in LDots do
    begin
      CaretAfter(LVis, LLine, LCol);
      LRow.Site := Format('%s(%d,%d)', [GProj.ModelFile(AMid), LLine, LCol]);
      LRow.What := 'dot';
      LDiffers := False;
      try
        if not LRef.CompleteAt(LLine, LCol, LCtxR, LItR) then
        begin
          Inc(GOvlRefusedDots);
          Continue;
        end;
        Inc(GOvlDots);
        if not LOvl.CompleteAt(LLine, LCol, LCtxO, LItO) then
        begin
          LCtxO := ccNone;
          LItO := nil;
        end;
        DiffSets(NameSet(LItR), NameSet(LItO), LRow.Missing, LRow.Extra,
          LDiffers);
        if LCtxR <> LCtxO then
        begin
          LDiffers := True;
          LRow.Extra := LRow.Extra + Format(' [context %s vs %s]',
            [CTX_NAMES[LCtxR], CTX_NAMES[LCtxO]]);
        end;
      except
        on E: Exception do
        begin
          LDiffers := True;
          LRow.Missing := '';
          LRow.Extra := 'EXCEPTION ' + E.ClassName + ': ' + E.Message;
        end;
      end;
      if LDiffers then
      begin
        Inc(GOvlDotDiff);
        GOvlRows.Add(LRow);
      end;
    end;
    for var LVis in LCalls do
    begin
      CaretAfter(LVis, LLine, LCol);
      LRow.Site := Format('%s(%d,%d)', [GProj.ModelFile(AMid), LLine, LCol]);
      LRow.What := 'call';
      LDiffers := False;
      try
        if not LRef.CallAt(LLine, LCol, LCallR) or
           (LCallR.Targets = nil) then
          Continue;   // nothing proven to compare against
        Inc(GOvlCalls);
        if not LOvl.CallAt(LLine, LCol, LCallO) then
          LCallO.Targets := nil;
        // -site: the details of one call site as the sweep meets it - a
        // difference that depends on what earlier units left in the project
        // (hydration) does not show under -at, which analyzes one request.
        if (GOvlSite <> '') and SameText(GOvlSite, Format('%s|%d|%d',
           [ExtractFileName(GProj.ModelFile(AMid)), LLine, LCol])) then
          Writeln(ErrOutput, Format('SITE %s: reference bound %d/%d %d ' +
            'targets, overlay node %d bound %d/%d %d targets',
            [GOvlSite, LCallR.BoundMid, LCallR.BoundSym,
             Length(LCallR.Targets), LCallO.CallNode, LCallO.BoundMid,
             LCallO.BoundSym, Length(LCallO.Targets)]));
        if (GOvlSite <> '') and SameText(GOvlSite, Format('%s|%d|%d',
           [ExtractFileName(GProj.ModelFile(AMid)), LLine, LCol])) then
        begin
          for var LT in LCallR.Targets do
            Writeln(ErrOutput, Format('SITE   ref %d/%d %s%s:%s %s', [LT.Mid,
              LT.Sym, LT.Name, LT.ParamsText, LT.ResultText,
              GProj.ModelFile(Max(LT.Mid, 0))]));
          for var LT in LCallO.Targets do
            Writeln(ErrOutput, Format('SITE   ovl %d/%d %s%s:%s', [LT.Mid,
              LT.Sym, LT.Name, LT.ParamsText, LT.ResultText]));
        end;
        DiffSets(TargetSet(LCallR), TargetSet(LCallO), LRow.Missing,
          LRow.Extra, LDiffers);
      except
        on E: Exception do
        begin
          LDiffers := True;
          LRow.Missing := '';
          LRow.Extra := 'EXCEPTION ' + E.ClassName + ': ' + E.Message;
        end;
      end;
      if LDiffers then
      begin
        Inc(GOvlCallDiff);
        GOvlRows.Add(LRow);
      end;
    end;
  finally
    LOvl.Free;
    LRef.Free;
    LOvModel.Free;
  end;
end;

// -overlay -at:<file>|<line>|<col>: one request against both models - the
// items and the call targets each side gives, for drilling a difference.
procedure OverlayProbeAt(const ASpec: string);
var
  LParts: TArray<string>;
  LMid, LLine, LCol: Integer;
  LM, LOvModel: TPasSemaModel;
  LPre: TPasPreprocessed;
  LDiags: TArray<TPasParseDiag>;
  LComp: TPasCompletion;
  LCtx: TPasComplContext;
  LItems: TArray<TPasComplItem>;
  LCall: TPasCallInfo;
begin
  LParts := ASpec.Split(['|']);
  if Length(LParts) <> 3 then
  begin
    Writeln('-at wants <file>|<line>|<col>');
    Exit;
  end;
  LMid := -1;
  for var LIdx := 0 to GProj.ModelCount - 1 do
    if SameText(ExtractFileName(GProj.ModelFile(LIdx)),
      ExtractFileName(LParts[0])) then
    begin
      LMid := LIdx;
      Break;
    end;
  if LMid < 0 then
  begin
    Writeln('not analyzed: ', LParts[0]);
    Exit;
  end;
  LLine := StrToIntDef(LParts[1], 1);
  LCol := StrToIntDef(LParts[2], 1);
  LM := GProj.Model(LMid);
  LPre := GOvlPP.ProcessText(GProj.ModelFile(LMid),
    LM.Tree.Source.Files[0].Source);
  LOvModel := TPasSemaResolver.Analyze(TPasParser.ParseFile(LPre, LDiags),
    False, GPlatform);
  try
    for var LSide := 0 to 1 do
    begin
      if LSide = 0 then
      begin
        Writeln('project model:');
        LComp := TPasCompletion.Create(LM, GProj, LMid);
      end
      else
      begin
        Writeln('overlay model:');
        LComp := TPasCompletion.Create(LOvModel, GProj, LMid);
      end;
      try
        if LComp.CompleteAt(LLine, LCol, LCtx, LItems) then
        begin
          Write(Format('  %s, %d items:', [CTX_NAMES[LCtx], Length(LItems)]));
          for var LIdx := 0 to Min(High(LItems), 11) do
            Write(' ', LItems[LIdx].Name);
          Writeln;
        end
        else
          Writeln('  refused');
        if LComp.CallAt(LLine, LCol, LCall) then
        begin
          Writeln(Format('  call at %d:%d, node %d, bound %d/%d, %d targets',
            [LCall.OpenLine, LCall.OpenCol, LCall.CallNode, LCall.BoundMid,
             LCall.BoundSym, Length(LCall.Targets)]));
          for var LT in LCall.Targets do
            Writeln(Format('  call %s%s: %s', [LT.Name, LT.ParamsText,
              LT.ResultText]));
        end;
      finally
        LComp.Free;
      end;
    end;
  finally
    LOvModel.Free;
  end;
end;

procedure ReportOverlay;
var
  LShow: Integer;
begin
  Writeln(Format('overlay: %d dots (%d differ, %d refused by the reference),'
    + ' %d calls (%d differ) in %d ms', [GOvlDots, GOvlDotDiff,
    GOvlRefusedDots, GOvlCalls, GOvlCallDiff, GSW.ElapsedMilliseconds]));
  if GOvlRows.Count = 0 then
  begin
    Writeln('OVERLAY CLEAN');
    Exit;
  end;
  if GListAll then
    LShow := GOvlRows.Count
  else
    LShow := Min(25, GOvlRows.Count);
  Writeln(Format('first %d differences (- the overlay lacks, + it adds):',
    [LShow]));
  for var LIdx := 0 to LShow - 1 do
    Writeln(Format('  %s %s -%s +%s', [GOvlRows[LIdx].Site,
      GOvlRows[LIdx].What, GOvlRows[LIdx].Missing, GOvlRows[LIdx].Extra]));
end;

var
  LMid, LShow: Integer;
  LCtx: TPasComplContext;
  GAtSpec, GStudio: string;
  GDProj: TPasDProj;
begin
  // The one line every PasTree host must set - the parallel passes allocate
  // heavily, and the default MM SLEEPS on contention (measured 4.5x on a
  // real project; see the README's Multithreading section).
  System.NeverSleepOnMMThreadContention := True;
  GStudio := GetEnvironmentVariable('BDS');
  if ParamCount < 1 then
  begin
    Writeln('usage: PasTreeCompleteOracle <dir|file.dpr> [-p:<platform>]'
      + ' [-max:<N>] [-list] [-overlay] [-L<dir>]');
    ExitCode := 2;
    Exit;
  end;
  GPath := ParamStr(1);
  GPlatform := pfWin32;
  GMaxPerUnit := 200;
  GListAll := False;
  GOverlay := False;
  GExtraPaths := nil;
  for GIdx := 2 to ParamCount do
  begin
    GArg := ParamStr(GIdx);
    if GArg.StartsWith('-p:', True) then
    begin
      if not TryParsePlatformName(Copy(GArg, 4, MaxInt), GPlatform) then
      begin
        Writeln('unknown platform: ', GArg);
        ExitCode := 2;
        Exit;
      end;
    end
    else if GArg.StartsWith('-max:', True) then
      GMaxPerUnit := StrToIntDef(Copy(GArg, 6, MaxInt), 200)
    else if SameText(GArg, '-list') then
      GListAll := True
    else if SameText(GArg, '-overlay') then
      GOverlay := True
    else if GArg.StartsWith('-site:', True) then
      GOvlSite := Copy(GArg, 7, MaxInt)
    else if GArg.StartsWith('-at:', True) then
      GAtSpec := Copy(GArg, 5, MaxInt)
    else if GArg.StartsWith('-studio:', True) then
      GStudio := Copy(GArg, 9, MaxInt)
    else if GArg.StartsWith('-L', True) and (Length(GArg) > 2) then
      GExtraPaths := GExtraPaths + [Copy(GArg, 3, MaxInt)]
    else
    begin
      Writeln('unknown argument: ', GArg);
      ExitCode := 2;
      Exit;
    end;
  end;

  GMisses := TList<TMissRow>.Create;
  GDProj := nil;
  if SameText(ExtractFileExt(GPath), '.dproj') then
  begin
    GDProj := TPasDProj.Create;
    if not GDProj.Load(GPath, PlatformName(GPlatform)) then
    begin
      Writeln('could not load .dproj: ', GPath);
      ExitCode := 2;
      GDProj.Free;
      GMisses.Free;
      Exit;
    end;
    GPlatform := GDProj.Platform;
    GProj := TPasSemaProject.Create(GPlatform,
      [GDProj.Dir] + GDProj.SearchPaths + StudioSearchPaths(GStudio)
      + GExtraPaths, GDProj.Defines);
    if Length(GDProj.Namespaces) > 0 then
      GProj.SetNamespaces(GDProj.Namespaces)
    else
      GProj.SetNamespaces(PasDefaultNamespaces(GPlatform));
    for var LDef in PasDefaultUnitAliases(GPlatform) do
      GProj.AddUnitAlias(LDef.Alias, LDef.UnitName);
    for var LA in GDProj.UnitAliases do
      GProj.AddUnitAlias(LA.Alias, LA.UnitName);
  end
  else
  begin
    GProj := TPasSemaProject.Create(GPlatform, GExtraPaths, []);
    // A directory or bare-file run has no project to state its prefixes:
    // the IDE's defaults, as PasTreeSemaProject sets them - with none, a
    // `uses Classes` resolves nothing and every bridged name of it is lost.
    GProj.SetNamespaces(PasDefaultNamespaces(GPlatform));
    for var LDef in PasDefaultUnitAliases(GPlatform) do
      GProj.AddUnitAlias(LDef.Alias, LDef.UnitName);
  end;
  try
    GSW := TStopwatch.StartNew;
    if GDProj <> nil then
      GProj.AnalyzeStaged([GDProj.MainSource], [])
    else if TDirectory.Exists(GPath) then
      GProj.AnalyzeDirectory(GPath)
    else
      GProj.AnalyzeProject(GPath);
    Writeln(Format('analyzed %d units in %d ms (%s)',
      [GProj.ModelCount, GSW.ElapsedMilliseconds, PlatformName(GPlatform)]));

    if (GAtSpec <> '') and not GOverlay then
    begin
      ProbeAt(GAtSpec);
      Exit;
    end;

    GSW := TStopwatch.StartNew;
    if GOverlay then
    begin
      if GDProj <> nil then
        EnsureOverlayPP([GDProj.Dir] + GDProj.SearchPaths
          + StudioSearchPaths(GStudio) + GExtraPaths, GDProj.Defines)
      else if TDirectory.Exists(GPath) then
        EnsureOverlayPP([GPath] + GExtraPaths, [])
      else
        EnsureOverlayPP([ExtractFileDir(ExpandFileName(GPath))]
          + GExtraPaths, []);
      GOvlRows := TList<TOvlRow>.Create;
      try
        if GAtSpec <> '' then
          OverlayProbeAt(GAtSpec)
        else
        begin
          for LMid := 0 to GProj.ModelCount - 1 do
            OverlayOneModel(LMid);
          ReportOverlay;
        end;
      finally
        GOvlRows.Free;
        GOvlPP.Free;
        GOvlDefines.Free;
        GOvlSM.Free;
      end;
      Exit;
    end;
    for LMid := 0 to GProj.ModelCount - 1 do
      OracleOneModel(LMid);

    Writeln(Format('oracle: %d sampled, %d offered, %d missed'
      + ' (%d refused carets) in %d ms',
      [GSampled, GHits, GSampled - GHits, GNoAnswer,
       GSW.ElapsedMilliseconds]));
    for LCtx := Low(TPasComplContext) to High(TPasComplContext) do
      if GCtxSampled[LCtx] > 0 then
        Writeln(Format('  %-10s %8d sampled  %8d offered  %8d missed',
          [CTX_NAMES[LCtx], GCtxSampled[LCtx], GCtxHits[LCtx],
           GCtxSampled[LCtx] - GCtxHits[LCtx]]));
    if GMisses.Count > 0 then
    begin
      Writeln;
      if GListAll then
        LShow := GMisses.Count
      else
        LShow := Min(25, GMisses.Count);
      Writeln(Format('first %d misses:', [LShow]));
      for LMid := 0 to LShow - 1 do
        Writeln(Format('  %s ''%s'' [%s]', [GMisses[LMid].Site,
          GMisses[LMid].Name, CTX_NAMES[GMisses[LMid].Context]]));
    end;
    if GSampled = GHits then
      Writeln('ORACLE CLEAN');
  finally
    GProj.Free;
    GDProj.Free;
    GMisses.Free;
  end;
end.
