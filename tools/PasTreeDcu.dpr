program PasTreeDcu;

{
  PasTree .dcu driver: reads compiled units with PasTree.Dcu and prints
  either the interface source PasTree.Dcu.Source generates for one, or a raw
  declaration dump, or sweeps a whole directory reporting every file the
  reader cannot follow. The regression gate for the reader is the sweep over
  `lib\<platform>\release` of every installed Studio (docs/dcu-reader.md).

  Usage:
    PasTreeDcu <file.dcu> [-src] [-dump] [-trace] [-parse]
    PasTreeDcu <directory> [-parse] [-v]

  -src    print the generated interface source (the default for one file)
  -dump   print the raw declaration tables instead
  -trace  print the `<offset> <tag>` record stream to stderr while reading
  -parse  run the generated source through the PasTree parser and report
          its syntax diagnostics (per file in a sweep)
  -v      in a sweep, list every file rather than only the failures
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Diagnostics,
  System.Generics.Collections,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.Dcu in '..\source\PasTree.Dcu.pas',
  PasTree.Dcu.Source in '..\source\PasTree.Dcu.Source.pas';

const
  cKindNames: array[TPasDcuDeclKind] of string = (
    'unitref', 'import', 'type', 'vmt', 'const', 'resstring', 'var',
    'threadvar', 'absvar', 'typedconst', 'strconst', 'label', 'export',
    'param', 'field', 'method', 'constructor', 'destructor', 'classvar',
    'property', 'dispproperty', 'routine', 'sysroutine', 'unitaddinfo',
    'specvar', 'paramdefault', 'copy', 'delayedimport', 'orec',
    'genericparams');
  cTypeKindNames: array[TPasDcuTypeKind] of string = (
    'pending', 'import', 'range', 'enum', 'float', 'pointer', 'text', 'file',
    'set', 'shortstring', 'string', 'array', 'variant', 'classref', 'record',
    'proctype', 'object', 'class', 'metaclass', 'interface', 'void',
    'dynarray', 'genericparam', 'genericinst');

procedure DumpDecl(AUnit: TPasDcuUnit; ADecl: TPasDcuDecl; const AIndent: string);
var
  LSub: TPasDcuDecl;
begin
  Write(AIndent, cKindNames[ADecl.Kind], ' ''', ADecl.Name, '''');
  if ADecl.Slot <> 0 then
    Write(' #', IntToHex(ADecl.Slot, 1));
  if ADecl.TypeIdx <> 0 then
    Write(' T#', IntToHex(ADecl.TypeIdx, 1));
  if ADecl.Flags <> 0 then
    Write(' F=', IntToHex(ADecl.Flags, 1));
  if (ADecl.LocFlags <> 0) or (ADecl.LocFlagsX <> 0) then
    Write(' LF=', IntToHex(ADecl.LocFlags, 1), '/', IntToHex(ADecl.LocFlagsX, 1));
  if ADecl.Kind in [dkField, dkParam, dkMethod, dkConstructor, dkDestructor,
    dkClassVar, dkProperty] then
    Write(' ofs=', ADecl.Offset);
  if ADecl.Kind = dkConst then
  begin
    Write(' kind=', ADecl.ValueKind);
    if Length(ADecl.ValueBytes) = 0 then
      Write(' val=', ADecl.ValueInt)
    else
      Write(' bytes=', Length(ADecl.ValueBytes));
  end;
  if ADecl.Kind = dkProperty then
    Write(' read=#', IntToHex(ADecl.ReadSlot, 1), ' write=#',
      IntToHex(ADecl.WriteSlot, 1), ' stored=#', IntToHex(ADecl.StoredSlot, 1));
  if ADecl.Kind in [dkRoutine, dkSysRoutine] then
  begin
    Write(' res=T#', IntToHex(ADecl.ResultTypeIdx, 1), ' class=#',
      IntToHex(ADecl.ClassSlot, 1), ' VProc=', IntToHex(ADecl.ProcFlags, 1),
      ' call=', Ord(ADecl.CallKind));
    if ADecl.IsUnnamed then
      Write(' unnamed');
  end;
  if ADecl.CaiFlags <> 0 then
    Write(' cai=', IntToHex(ADecl.CaiFlags, 1));
  if ADecl.HasDeprecated then
    Write(' deprecated ''', ADecl.DeprecatedMsg, '''');
  if Length(ADecl.GenericParamTypes) > 0 then
    Write(' generic(', Length(ADecl.GenericParamTypes), ')');
  if ADecl.DataSize >= 0 then
  begin
    Write(' data@', IntToHex(ADecl.DataOffset, 1), '[', ADecl.DataSize, ']=');
    for var LB := ADecl.DataOffset to ADecl.DataOffset + ADecl.DataSize - 1 do
      if LB < Length(AUnit.DataBlock) then
        Write(IntToHex(AUnit.DataBlock[LB], 2), ' ');
  end;
  Writeln;
  if ADecl.Args <> nil then
    for LSub in ADecl.Args do
      DumpDecl(AUnit, LSub, AIndent + '    arg ');
  if ADecl.GenericParams <> nil then
    for LSub in ADecl.GenericParams do
      DumpDecl(AUnit, LSub, AIndent + '    gen ');
  if ADecl.Items <> nil then
    for LSub in ADecl.Items do
      DumpDecl(AUnit, LSub, AIndent + '    item ');
  // Nested routines and local types: a nested routine's code is a data range
  // of its own, outside its parent's - without these rows a difference there
  // shows in the raw bytes and nowhere in the dump (tools\fidelity.ps1
  // locates differences by these lines).
  if ADecl.Embedded <> nil then
    for LSub in ADecl.Embedded do
      DumpDecl(AUnit, LSub, AIndent + '    emb ');
end;

procedure DumpUnit(AUnit: TPasDcuUnit);
var
  LUses: TPasDcuUses;
  LDecl: TPasDcuDecl;
  LType: TPasDcuType;
  LIdx: Integer;
begin
  Writeln('unit ', AUnit.UnitName, '  ', DcuVersionName(AUnit.VersionByte),
    '  platform ', Ord(AUnit.Platform), '  addrs ', AUnit.Addrs.Count,
    '  types ', AUnit.Types.Count, '  decls ', AUnit.Decls.Count);
  for LUses in AUnit.UsesList do
    Writeln('uses ', LUses.Name, ' section=', Ord(LUses.Section),
      ' imports=', LUses.Imports.Count);
  Writeln('--- types');
  for LIdx := 0 to AUnit.Types.Count - 1 do
  begin
    LType := AUnit.Types[LIdx];
    if LType = nil then
    begin
      Writeln('T#', IntToHex(LIdx + 1, 1), ' (empty)');
      Continue;
    end;
    Write('T#', IntToHex(LIdx + 1, 1), ' ', cTypeKindNames[LType.Kind], ' ''',
      LType.Name, ''' size=', LType.Size, ' decl=#', IntToHex(LType.DeclSlot, 1));
    case LType.Kind of
      tkImport: Write(' from=', LType.UnitIdx, ' ''', LType.ImportName, '''');
      tkRange, tkEnum: Write(' base=T#', IntToHex(LType.BaseIdx, 1), ' ',
        LType.Low, '..', LType.High, ' B=', LType.RangeFlag);
      tkPointer, tkDynArray, tkClassRef, tkSet, tkFile:
        Write(' base=T#', IntToHex(LType.BaseIdx, 1));
      tkArray, tkString, tkShortString:
        Write(' idx=T#', IntToHex(LType.IndexIdx, 1), ' elem=T#',
          IntToHex(LType.ElemIdx, 1), ' B1=', LType.ArrayFlag, ' cp=', LType.CodePage);
      tkFloat: Write(' fk=', LType.FloatKind);
      tkRecord: Write(' flags=', LType.RecFlags[0], '/', LType.RecFlags[1], '/',
        LType.RecFlags[2], '/', LType.RecFlags[3], ' extra=', LType.RecExtra[0],
        '/', LType.RecExtra[1], '/', LType.RecExtra[2]);
      tkClass, tkMetaClass: Write(' parent=T#', IntToHex(LType.ParentIdx, 1),
        ' flags=', IntToHex(LType.ClassFlags[0], 1), '/', IntToHex(LType.ClassFlags[1], 1),
        '/', IntToHex(LType.ClassFlags[2], 1), '/', IntToHex(LType.ClassFlags[3], 1),
        ' info=', LType.ClassInfo[3], '/', LType.ClassInfo[4], '/', LType.ClassInfo[5],
        ' intfs=', Length(LType.Interfaces));
      tkInterface: Write(' parent=T#', IntToHex(LType.ParentIdx, 1),
        ' B=', IntToHex(LType.IntfFlags, 1), ' BX=', IntToHex(LType.IntfFlagsX, 1),
        ' guid=', GUIDToString(LType.Guid));
      tkProcType: Write(' res=T#', IntToHex(LType.ResultTypeIdx, 1),
        ' flags=', IntToHex(LType.ProcFlags, 1), ' call=', Ord(LType.CallKind));
      tkObject: Write(' parent=T#', IntToHex(LType.ParentIdx, 1));
      tkGenericInst: Write(' of=T#', IntToHex(LType.BaseIdx, 1), ' args=',
        Length(LType.GenericArgs), ' full=T#', IntToHex(LType.InstFullIdx, 1));
      tkGenericParam: Write(' table=', Length(LType.ParamTable), ' extra=', LType.ParamExtra);
    end;
    if Length(LType.GenericParamTypes) > 0 then
      Write(' generic(', Length(LType.GenericParamTypes), ')');
    Writeln;
    if LType.Members <> nil then
      for LDecl in LType.Members do
        DumpDecl(AUnit, LDecl, '    ');
  end;
  Writeln('--- decls');
  for LDecl in AUnit.Decls do
    DumpDecl(AUnit, LDecl, '');
  Writeln('--- fixups (data block ', Length(AUnit.DataBlock), ' bytes)');
  for LIdx := 0 to High(AUnit.Fixups) do
    Writeln('  @', IntToHex(AUnit.Fixups[LIdx].Offset, 1), ' kind=',
      AUnit.Fixups[LIdx].Kind, ' slot=#', IntToHex(AUnit.Fixups[LIdx].Slot, 1));
  for LIdx := 0 to High(AUnit.Warnings) do
    Writeln('warning: ', AUnit.Warnings[LIdx]);
end;

function ParseDiagCount(const ASource, AName: string; AVerbose: Boolean): Integer;
var
  LSM: TPasSourceManager;
  LPP: TPasPreprocessor;
  LPre: TPasPreprocessed;
  LTree: TPasTree;
  LDiags: TArray<TPasParseDiag>;
  LIdx, LLine, LCol, LVis: Integer;
  LTok: TPasVisibleToken;
begin
  LSM := TPasSourceManager.Create(nil);
  try
    LPP := TPasPreprocessor.Create(LSM, TPasDefines.Create);
    try
      LPre := LPP.ProcessText(AName, ASource);
      LTree := TPasParser.ParseFile(LPre, LDiags);
      Result := Length(LDiags);
      if AVerbose then
        for LIdx := 0 to High(LDiags) do
        begin
          LVis := LDiags[LIdx].VisIndex;
          if LVis > High(LPre.Visible) then
            LVis := High(LPre.Visible);
          LTok := LPre.Visible[LVis];
          LPre.Files[LTok.FileId].OffsetToLineCol(
            LPre.Files[LTok.FileId].Tokens[LTok.TokenIndex].Start, LLine, LCol);
          Writeln(Format('  %s(%d,%d): %s', [AName, LLine, LCol,
            LDiags[LIdx].Msg]));
        end;
      if Length(LTree.Nodes) < 0 then
        Exit;   // never true: the tree is a record, freed with the frame
    finally
      LPP.Free;
    end;
  finally
    LSM.Free;
  end;
end;

var
  GArg, GTarget: string;
  GIdx: Integer;
  GDump, GTrace, GSrc, GParse, GVerbose: Boolean;
  GUnit: TPasDcuUnit;
  GFiles: TArray<string>;
  GFile, GSource, GMsg: string;
  GOk, GFail, GParseFail: Integer;
  GWatch: TStopwatch;
  GTraceProc: TPasDcuTraceProc;

begin
  try
    for GIdx := 1 to ParamCount do
    begin
      GArg := ParamStr(GIdx);
      if SameText(GArg, '-dump') then GDump := True
      else if SameText(GArg, '-trace') then GTrace := True
      else if SameText(GArg, '-src') then GSrc := True
      else if SameText(GArg, '-parse') then GParse := True
      else if SameText(GArg, '-v') then GVerbose := True
      else GTarget := GArg;
    end;
    if GTarget = '' then
    begin
      Writeln('usage: PasTreeDcu <file.dcu|directory> [-src] [-dump] [-trace] [-parse] [-v]');
      Halt(2);
    end;
    if GTrace then
      GTraceProc :=
        procedure(const ALine: string)
        begin
          Writeln(ErrOutput, ALine);
        end
    else
      GTraceProc := nil;

    if TDirectory.Exists(GTarget) then
    begin
      GFiles := TDirectory.GetFiles(GTarget, '*.dcu');
      TArray.Sort<string>(GFiles);
      GOk := 0;
      GFail := 0;
      GParseFail := 0;
      GWatch := TStopwatch.StartNew;
      for GFile in GFiles do
      begin
        try
          GUnit := LoadDcu(GFile, GTraceProc);
          try
            if GParse then
            begin
              GSource := DcuInterfaceSource(GUnit);
              GIdx := ParseDiagCount(GSource, TPath.GetFileName(GFile), GVerbose);
              if GIdx > 0 then
              begin
                Inc(GParseFail);
                Writeln('PARSE ', TPath.GetFileNameWithoutExtension(GFile),
                  ' :: ', GIdx, ' syntax diagnostic(s)');
              end
              else if GVerbose then
                Writeln('OK    ', TPath.GetFileNameWithoutExtension(GFile));
            end
            else if GVerbose then
              Writeln('OK    ', TPath.GetFileNameWithoutExtension(GFile));
            Inc(GOk);
          finally
            GUnit.Free;
          end;
        except
          on E: Exception do
          begin
            Inc(GFail);
            GMsg := E.Message;
            Writeln('FAIL  ', TPath.GetFileNameWithoutExtension(GFile), ' :: ', GMsg);
          end;
        end;
      end;
      Writeln(Format('TOTAL files=%d ok=%d fail=%d parsefail=%d (%d ms)',
        [Length(GFiles), GOk, GFail, GParseFail, GWatch.ElapsedMilliseconds]));
      if (GFail > 0) or (GParseFail > 0) then
        Halt(1);
      Exit;
    end;

    GUnit := LoadDcu(GTarget, GTraceProc);
    try
      if GDump then
        DumpUnit(GUnit)
      else
      begin
        GSource := DcuInterfaceSource(GUnit);
        if GParse then
        begin
          GIdx := ParseDiagCount(GSource, TPath.GetFileName(GTarget), True);
          Writeln(Format('%d syntax diagnostic(s)', [GIdx]));
          if GIdx > 0 then
            Halt(1);
        end
        else
          Write(GSource);
      end;
    finally
      GUnit.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
