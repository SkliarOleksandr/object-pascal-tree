program PasTreeXform;

{
  The source side of the compile-compare harness (tools\fidelity.ps1 is the
  driver): dcc judges the tree through the .dcu. A transformation that keeps
  the meaning FOR OUR TREE compiles to a byte-identical .dcu exactly when our
  tree agrees with dcc's, so nothing here needs an expectation file.

  Reads one unit with the inputs its compile gets (platform defines, -D
  defines, include paths) and writes a transformed copy of it AND of every
  include the preprocessor read into an output directory, plus sites.txt:
  what was changed where, and in which routine - the name the .dcu dump
  locates a difference by.

  Modes:
    t0  every file unchanged - the identity the harness must get right first
    ts  selftest: in each routine ONE deliberately WRONG regrouping of an
        operator chain the tree read left-associatively - `a - b + c` becomes
        `a - (b + c)`, `a div b * c` becomes `a div (b * c)`. Every unit with a
        site must compile to a different .dcu: a comparator that cannot see
        this cannot see anything.

  Usage:
    PasTreeXform <unit.pas> -mode:t0|ts -out:<dir> [-p:<platform>]
                 [-D:X;Y]... [-I:<dir>[;<dir>]]...

  Output, all of it under <dir>:
  - the files, mirrored under the common directory of the unit, its includes
    and the -I directories, so a relative `$I` include resolves as it did;
  - sites.txt, tab-separated: id, kind, operators, span
    `file(line,col)-(line,col)`, routine, the edit;
  - on stdout `main <path>` (the transformed unit), one `file <from> <to>`
    per file written, one `idir <from> <to>` per -I directory (the compile
    of the copy searches <to>), `sites <n>`; <from> and <to> tab-separated.

  What a compile reads besides the text is kept too:
  - the source MTIME, copied as the exact FILETIME - dcc stores it in the
    .dcu, so a fresh timestamp alone makes a copy compile differently;
  - the ENCODING: an edit is spliced into the original BYTES at the byte
    offset of its token (the prefix re-counted in the file's own encoding),
    so no untouched byte is ever re-encoded. A file whose bytes do not
    round-trip through its decoding (a lenient U+FFFD recovery) is refused.

  A file included more than once takes no edit (one text serves several
  preprocessing states); a site that would need one is dropped and counted.
}

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Dcu in '..\source\PasTree.Dcu.pas',
  PasTree.Dcu.Source in '..\source\PasTree.Dcu.Source.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.Version in '..\source\PasTree.Version.pas';

type
  TXformMode = (xmT0, xmTS);

const
  cModeNames: array[TXformMode] of string = ('t0', 'ts');

type
  // One text insertion into one file. Order breaks ties at the same offset:
  // a closing paren must land before an opening one there (`c)(d`), which is
  // what T1 will need when many parens meet; TS never puts two at one spot.
  TEdit = record
    FileId: Integer;
    Offset: Integer;     // UTF-16 offset in the file's decoded text
    Order: Integer;
    Text: string;
  end;

  TSite = record
    Kind: string;
    Ops: string;
    Span: string;
    Routine: string;
    Edit: string;
  end;

var
  GPre: TPasPreprocessed;
  GTree: TPasTree;
  GEdits: TList<TEdit>;
  GSites: TList<TSite>;
  GIncludedTwice: TArray<Boolean>;   // per FileId: its path occurs twice
  GDropped: Integer;                 // sites refused for an include used twice
  GUnitName: string;

function VisOffset(AVis: Integer; out AFileId: Integer): Integer;
var
  LTok: TPasVisibleToken;
begin
  LTok := GPre.Visible[AVis];
  AFileId := LTok.FileId;
  Result := GPre.Files[LTok.FileId].Tokens[LTok.TokenIndex].Start;
end;

function VisEnd(AVis: Integer; out AFileId: Integer): Integer;
var
  LTok: TPasVisibleToken;
begin
  LTok := GPre.Visible[AVis];
  AFileId := LTok.FileId;
  Result := GPre.Files[LTok.FileId].Tokens[LTok.TokenIndex].EndPos;
end;

// `File.pas(12,5)` for a file offset - 1-based, the dcc message form.
function PosText(AFileId, AOffset: Integer): string;
var
  LLine, LCol: Integer;
begin
  GPre.Files[AFileId].OffsetToLineCol(AOffset, LLine, LCol);
  Result := Format('%s(%d,%d)', [TPath.GetFileName(GPre.FileNames[AFileId]),
    LLine, LCol]);
end;

function SpanText(AFirstVis, ALastVis: Integer): string;
var
  LFile, LEndFile, LLine, LCol: Integer;
  LStart, LEnd: Integer;
begin
  LStart := VisOffset(AFirstVis, LFile);
  LEnd := VisEnd(ALastVis, LEndFile);
  Result := PosText(LFile, LStart);
  // The LAST character's position, inclusive, like an editor selection.
  GPre.Files[LEndFile].OffsetToLineCol(LEnd - 1, LLine, LCol);
  Result := Result + Format('-(%d,%d)', [LLine, LCol]);
end;

function Child(ANode, AIndex: Integer): Integer;
begin
  Result := GTree.Nodes[ANode].FirstChild;
  while (Result <> NIL_NODE) and (AIndex > 0) do
  begin
    Result := GTree.Nodes[Result].NextSibling;
    Dec(AIndex);
  end;
end;

function OpText(ANode: Integer): string;
begin
  Result := LowerCase(GPre.VisibleText(GTree.Nodes[ANode].Aux));
end;

{ A routine's name as the .dcu spells it: the leading name idents of the
  header, dotted (`TFoo.Bar`, `TOuter.TInner.Bar`), generic parameter lists
  left out - the driver compares names without them. A name part after the
  first follows a dot: the result type of a routine with no parameter list,
  `function TFoo.Get: TBar`, is the next ident child too. }
function RoutineName(ARoutine: Integer): string;
var
  LChild, LVis: Integer;
begin
  Result := '';
  LChild := GTree.Nodes[ARoutine].FirstChild;
  while LChild <> NIL_NODE do
  begin
    case GTree.Nodes[LChild].Kind of
      nkIdent:
        begin
          LVis := GTree.Nodes[LChild].FirstToken;
          if Result <> '' then
          begin
            if (LVis < 1) or (GPre.VisibleToken(LVis - 1).Kind <> tkDot) then
              Break;
            Result := Result + '.';
          end;
          // `&Type` names a routine `Type`: the ampersand is no part of it.
          Result := Result + GTree.NodeText(LChild).TrimLeft(['&']);
        end;
      nkGenericParams, nkTypeArgs:
        ;
    else
      Break;
    end;
    LChild := GTree.Nodes[LChild].NextSibling;
  end;
end;

{ The unit's name as written in its header, `PasTree.Ast` - the name of the
  routine a .dcu gives the initialization section's code. }
function HeaderName: string;
var
  LVis: Integer;
begin
  // ident { . ident } - a hint directive after it (`unit U platform;`) is
  // not part of the name.
  Result := '';
  LVis := GTree.Nodes[0].FirstToken + 1;
  while LVis <= High(GPre.Visible) do
  begin
    if GPre.VisibleToken(LVis).Kind <> tkIdentifier then
      Break;
    Result := Result + GPre.VisibleText(LVis).TrimLeft(['&']);
    if (LVis + 1 > High(GPre.Visible)) or
       (GPre.VisibleToken(LVis + 1).Kind <> tkDot) then
      Break;
    Result := Result + '.';
    Inc(LVis, 2);
  end;
end;

procedure AddEdit(AVis: Integer; AAfter: Boolean; AOrder: Integer;
  const AText: string);
var
  LEdit: TEdit;
begin
  if AAfter then
    LEdit.Offset := VisEnd(AVis, LEdit.FileId)
  else
    LEdit.Offset := VisOffset(AVis, LEdit.FileId);
  LEdit.Order := AOrder;
  LEdit.Text := AText;
  GEdits.Add(LEdit);
end;

{ TS: the site class of binary op P, 0 when it is not a candidate. P reads
  (A op1 B) op2 R; the wrong grouping is A op1 (B op2 R). Only pairs where
  that is a DIFFERENT computation for every operand type the original allows,
  and still type-checks: op1 is the non-associative one. `(a + b) - c` ->
  `a + (b - c)` is the same integer, and `and`/`or` chains short-circuit to
  the same jumps, so both could compile identically and prove nothing. }
function SiteClass(AP: Integer): Integer;
var
  LL: Integer;
  LOp1, LOp2: string;
begin
  Result := 0;
  LL := Child(AP, 0);
  if (LL = NIL_NODE) or (GTree.Nodes[LL].Kind <> nkBinaryOp) or
     (Child(AP, 1) = NIL_NODE) or (Child(LL, 1) = NIL_NODE) then
    Exit;
  LOp1 := OpText(LL);
  LOp2 := OpText(AP);
  if (LOp1 = '-') and ((LOp2 = '+') or (LOp2 = '-')) then
    Result := 1
  else if (((LOp1 = 'div') or (LOp1 = 'mod')) and
           ((LOp2 = '*') or (LOp2 = 'div') or (LOp2 = 'mod'))) or
          ((LOp1 = '/') and ((LOp2 = '*') or (LOp2 = '/'))) or
          ((LOp1 = '*') and ((LOp2 = 'div') or (LOp2 = 'mod'))) then
    Result := 2
  else if ((LOp1 = 'shl') or (LOp1 = 'shr')) and
          ((LOp2 = 'shl') or (LOp2 = 'shr')) then
    Result := 3;
end;

{ The candidate operator chains of one routine's statements, source order.
  Not descended: an anonymous method (compiled as a routine of its own, under
  a compiler-made name), case labels (a regrouped label can collide with
  another one and stop the compile), asm. }
procedure CollectCandidates(ANode: Integer; ACandidates: TList<Integer>);
var
  LChild: Integer;
begin
  case GTree.Nodes[ANode].Kind of
    nkAnonMethod, nkRoutine, nkCaseLabels, nkAsmStmt:
      Exit;
    nkBinaryOp:
      if SiteClass(ANode) > 0 then
        ACandidates.Add(ANode);
  end;
  LChild := GTree.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    CollectCandidates(LChild, ACandidates);
    LChild := GTree.Nodes[LChild].NextSibling;
  end;
end;

procedure PickSite(ABlock: Integer; const ARoutine: string);
var
  LCandidates: TList<Integer>;
  LBest, LClass, LCand, LP, LB, LR: Integer;
  LFirst, LLast, LFileA, LFileB: Integer;
  LSite: TSite;
begin
  LCandidates := TList<Integer>.Create;
  try
    CollectCandidates(ABlock, LCandidates);
    // The best class first, the first in source order within it.
    LP := NIL_NODE;
    LBest := MaxInt;
    for LCand in LCandidates do
    begin
      LClass := SiteClass(LCand);
      if LClass < LBest then
      begin
        LBest := LClass;
        LP := LCand;
      end;
    end;
    if LP = NIL_NODE then
      Exit;
    LB := Child(Child(LP, 0), 1);
    LR := Child(LP, 1);
    LFirst := GTree.NodeLeftmostVis(LB);
    LLast := GTree.Nodes[LR].LastToken;
    VisOffset(LFirst, LFileA);
    VisOffset(LLast, LFileB);
    if (LFileA <> LFileB) or GIncludedTwice[LFileA] then
    begin
      Inc(GDropped);
      Exit;
    end;
    AddEdit(LFirst, False, 1, '(');
    AddEdit(LLast, True, 0, ')');
    LSite.Kind := GTree.KindName(GTree.Nodes[LP].Kind);
    LSite.Ops := OpText(Child(LP, 0)) + '/' + OpText(LP);
    LSite.Span := SpanText(GTree.NodeLeftmostVis(LP), GTree.Nodes[LP].LastToken);
    LSite.Routine := ARoutine;
    LSite.Edit := Format('( at %s, ) after %s', [
      SpanText(LFirst, LFirst), SpanText(LLast, LLast)]);
    GSites.Add(LSite);
  finally
    LCandidates.Free;
  end;
end;

{ Every routine with a body, nested ones named `Outer.Inner` (the name the
  .dcu dump gives an embedded routine under its parent), plus the
  initialization and finalization sections under the names dcc gives their
  code. }
procedure VisitRoutines(ANode: Integer; const AOuter: string);
var
  LChild, LBodyChild: Integer;
  LName: string;
begin
  case GTree.Nodes[ANode].Kind of
    nkAnonMethod:
      Exit;
    nkRoutine:
      begin
        LName := RoutineName(ANode);
        if AOuter <> '' then
          LName := AOuter + '.' + LName;
        LChild := GTree.Nodes[ANode].FirstChild;
        while LChild <> NIL_NODE do
        begin
          if GTree.Nodes[LChild].Kind = nkRoutineBody then
          begin
            LBodyChild := GTree.Nodes[LChild].FirstChild;
            while LBodyChild <> NIL_NODE do
            begin
              case GTree.Nodes[LBodyChild].Kind of
                nkRoutine:
                  VisitRoutines(LBodyChild, LName);
                nkBlock:
                  PickSite(LBodyChild, LName);
              end;
              LBodyChild := GTree.Nodes[LBodyChild].NextSibling;
            end;
          end;
          LChild := GTree.Nodes[LChild].NextSibling;
        end;
        Exit;
      end;
    nkInitSec:
      begin
        PickSite(ANode, GUnitName);
        Exit;
      end;
    nkFinalSec:
      begin
        PickSite(ANode, 'Finalization');
        Exit;
      end;
  end;
  LChild := GTree.Nodes[ANode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    VisitRoutines(LChild, AOuter);
    LChild := GTree.Nodes[LChild].NextSibling;
  end;
end;

{ The encoding the source manager decoded AFileName's bytes with - the same
  decision as TPasSourceManager.DecodeBytes. False for its lenient UTF-8
  recovery, whose U+FFFD substitutions have no byte-exact inverse. }
function FileEncoding(const ABytes: TBytes; out AEnc: TEncoding;
  out APreamble: Integer): Boolean;
begin
  AEnc := nil;
  APreamble := TEncoding.GetBufferEncoding(ABytes, AEnc, TEncoding.UTF8);
  Result := True;
  if (AEnc.CodePage = CP_UTF8) and
     not TPasSourceManager.IsValidUtf8(ABytes, APreamble) then
  begin
    if APreamble > 0 then
      Exit(False);
    AEnc := TEncoding.ANSI;
  end;
end;

procedure CopyFileTime(const AFrom, ATo: string);
var
  LFrom, LTo: THandle;
  LCreate, LAccess, LWrite: TFileTime;
begin
  LFrom := CreateFile(PChar(AFrom), GENERIC_READ, FILE_SHARE_READ or
    FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
  if LFrom = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  try
    if not GetFileTime(LFrom, @LCreate, @LAccess, @LWrite) then
      RaiseLastOSError;
  finally
    CloseHandle(LFrom);
  end;
  LTo := CreateFile(PChar(ATo), FILE_WRITE_ATTRIBUTES, 0, nil, OPEN_EXISTING,
    0, 0);
  if LTo = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  try
    if not SetFileTime(LTo, @LCreate, @LAccess, @LWrite) then
      RaiseLastOSError;
  finally
    CloseHandle(LTo);
  end;
end;

{ Writes file AFileId's bytes with its edits spliced in at byte offsets. }
procedure WriteFile(AFileId: Integer; const AOutPath: string);
var
  LBytes, LOut: TBytes;
  LEnc: TEncoding;
  LPreamble, LTextPos, LBytePos, LCount, LIdx: Integer;
  LText: string;
  LEdits: TList<TEdit>;
  LEdit: TEdit;
  LStream: TBytesStream;
  LIns: TBytes;
begin
  LBytes := TFile.ReadAllBytes(GPre.FileNames[AFileId]);
  if not FileEncoding(LBytes, LEnc, LPreamble) then
    raise Exception.CreateFmt('%s: not valid UTF-8 despite its BOM - no ' +
      'byte-exact edit is possible', [GPre.FileNames[AFileId]]);
  LText := LEnc.GetString(LBytes, LPreamble, Length(LBytes) - LPreamble);
  // The offsets are the lexer's: they index the text IT read.
  if LText <> GPre.Files[AFileId].Source then
    raise Exception.CreateFmt('%s: decodes differently from the text the ' +
      'lexer read', [GPre.FileNames[AFileId]]);
  if LEnc.GetByteCount(LText, 0, Length(LText), 0) <>
     Length(LBytes) - LPreamble then
    raise Exception.CreateFmt('%s: the %s decoding does not round-trip',
      [GPre.FileNames[AFileId], LEnc.EncodingName]);
  LEdits := TList<TEdit>.Create;
  LStream := TBytesStream.Create;
  try
    for LEdit in GEdits do
      if LEdit.FileId = AFileId then
        LEdits.Add(LEdit);
    LEdits.Sort(TComparer<TEdit>.Construct(
      function(const A, B: TEdit): Integer
      begin
        Result := A.Offset - B.Offset;
        if Result = 0 then
          Result := A.Order - B.Order;
      end));
    if LPreamble > 0 then
      LStream.WriteBuffer(LBytes[0], LPreamble);
    LTextPos := 0;
    LBytePos := LPreamble;
    for LIdx := 0 to LEdits.Count - 1 do
    begin
      LEdit := LEdits[LIdx];
      LCount := LEnc.GetByteCount(LText, LTextPos, LEdit.Offset - LTextPos, 0);
      if LCount > 0 then
        LStream.WriteBuffer(LBytes[LBytePos], LCount);
      Inc(LBytePos, LCount);
      LTextPos := LEdit.Offset;
      LIns := LEnc.GetBytes(LEdit.Text);
      if Length(LIns) > 0 then
        LStream.WriteBuffer(LIns[0], Length(LIns));
    end;
    if LBytePos < Length(LBytes) then
      LStream.WriteBuffer(LBytes[LBytePos], Length(LBytes) - LBytePos);
    LOut := Copy(LStream.Bytes, 0, LStream.Size);
  finally
    LStream.Free;
    LEdits.Free;
  end;
  TDirectory.CreateDirectory(TPath.GetDirectoryName(AOutPath));
  TFile.WriteAllBytes(AOutPath, LOut);
  CopyFileTime(GPre.FileNames[AFileId], AOutPath);
end;

function NoSlash(const APath: string): string;
begin
  Result := ExcludeTrailingPathDelimiter(TPath.GetFullPath(APath));
end;

// The deepest directory containing both - '' when they share no root.
function CommonDir(const A, B: string): string;
var
  LA, LB: TArray<string>;
  LIdx: Integer;
begin
  LA := A.Split([PathDelim]);
  LB := B.Split([PathDelim]);
  Result := '';
  LIdx := 0;
  while (LIdx < Length(LA)) and (LIdx < Length(LB)) and
        SameText(LA[LIdx], LB[LIdx]) do
  begin
    if LIdx = 0 then
      Result := LA[0]
    else
      Result := Result + PathDelim + LA[LIdx];
    Inc(LIdx);
  end;
end;

// APath's place under AOut, mirrored from ARoot (a directory APath is under).
function Mirror(const APath, ARoot, AOut: string): string;
begin
  if not SameText(Copy(APath, 1, Length(ARoot) + 1), ARoot + PathDelim) and
     not SameText(APath, ARoot) then
    raise Exception.CreateFmt('%s is not under %s', [APath, ARoot]);
  Result := AOut + Copy(APath, Length(ARoot) + 1, MaxInt);
end;

var
  GArg, GFile, GOut, GRoot, GPath, GLine: string;
  GMode: TXformMode;
  GPlatform: TPasPlatform;
  GInfo: TPasPlatformInfo;
  GIncDirs, GDefNames: TList<string>;
  GSM: TPasSourceManager;
  GDefines: TPasDefines;
  GPP: TPasPreprocessor;
  GDiags: TArray<TPasParseDiag>;
  GIdx, GJdx, GNonInfo, GOffset: Integer;
  GSite: TSite;
  GName: string;
  GWritten: TDictionary<string, Boolean>;
  GSitesText, GFileLines: TStringList;

begin
  try
    GMode := xmT0;
    GPlatform := pfWin64;
    GFile := '';
    GOut := '';
    GIncDirs := TList<string>.Create;
    GDefNames := TList<string>.Create;
    for GIdx := 1 to ParamCount do
    begin
      GArg := ParamStr(GIdx);
      if GArg.StartsWith('-mode:', True) then
      begin
        GArg := LowerCase(Copy(GArg, 7, MaxInt));
        if GArg = 't0' then GMode := xmT0
        else if GArg = 'ts' then GMode := xmTS
        else raise Exception.Create('unknown mode: ' + GArg);
      end
      else if GArg.StartsWith('-out:', True) then
        GOut := NoSlash(Copy(GArg, 6, MaxInt))
      else if GArg.StartsWith('-p:', True) then
      begin
        if not TryParsePlatformName(Copy(GArg, 4, MaxInt), GPlatform) then
          raise Exception.Create('unknown platform: ' + Copy(GArg, 4, MaxInt));
      end
      else if GArg.StartsWith('-D:', True) then
      begin
        for GName in Copy(GArg, 4, MaxInt).Split([';']) do
          if Trim(GName) <> '' then
            GDefNames.Add(Trim(GName));
      end
      else if GArg.StartsWith('-I:', True) then
      begin
        for GName in Copy(GArg, 4, MaxInt).Split([';']) do
          if Trim(GName) <> '' then
            GIncDirs.Add(NoSlash(Trim(GName)));
      end
      else if GArg.StartsWith('-') then
        raise Exception.Create('unknown option: ' + GArg)
      else
        GFile := TPath.GetFullPath(GArg);
    end;
    if (GFile = '') or (GOut = '') then
    begin
      Writeln(ErrOutput, 'Usage: PasTreeXform <unit.pas> -mode:t0|ts -out:<dir> ' +
        '[-p:<platform>] [-D:X;Y]... [-I:<dir>[;<dir>]]...');
      ExitCode := 1;
      Exit;
    end;

    GInfo := PlatformInfo(GPlatform);
    GSM := TPasSourceManager.Create(GIncDirs.ToArray);
    GDefines := CreatePlatformDefines(GPlatform);
    for GName in GDefNames do
      GDefines.Define(GName);
    GPP := TPasPreprocessor.Create(GSM, GDefines, DEFAULT_COMPILER_VERSION,
      GInfo.PointerBytes, GInfo.ExtendedBytes);
    GEdits := TList<TEdit>.Create;
    GSites := TList<TSite>.Create;
    GWritten := TDictionary<string, Boolean>.Create;
    GSitesText := TStringList.Create;
    GFileLines := TStringList.Create;
    try
      GPre := GPP.Process(GFile);
      // A preprocessor diagnostic is worth seeing: an include not found here
      // is a file the copy will lack. $IF-needs-semantics is informational.
      GNonInfo := 0;
      for GIdx := 0 to High(GPre.Diagnostics) do
        if GPre.Diagnostics[GIdx].Code <> ppIfNeedsSemantics then
        begin
          Inc(GNonInfo);
          Writeln(ErrOutput, 'PP ', PosText(GPre.Diagnostics[GIdx].FileId,
            GPre.Diagnostics[GIdx].Start), ': ',
            PP_DIAG_MESSAGES[GPre.Diagnostics[GIdx].Code], ' ',
            GPre.Diagnostics[GIdx].Detail);
        end;

      SetLength(GIncludedTwice, Length(GPre.FileNames));
      for GIdx := 0 to High(GPre.FileNames) do
        for GJdx := 0 to High(GPre.FileNames) do
          if (GIdx <> GJdx) and
             SameText(GPre.FileNames[GIdx], GPre.FileNames[GJdx]) then
            GIncludedTwice[GIdx] := True;

      GDiags := nil;
      if GMode = xmTS then
      begin
        GTree := TPasParser.ParseFile(GPre, GDiags);
        for GIdx := 0 to High(GDiags) do
          if GDiags[GIdx].VisIndex <= High(GPre.Visible) then
          begin
            GOffset := VisOffset(GDiags[GIdx].VisIndex, GJdx);
            Writeln(ErrOutput, 'PARSE ', PosText(GJdx, GOffset), ': ',
              GDiags[GIdx].Msg);
          end
          else
            Writeln(ErrOutput, 'PARSE <eof>: ', GDiags[GIdx].Msg);
        GUnitName := HeaderName;
        VisitRoutines(0, '');
      end;

      // The mirror root: every file read and every -I directory under it.
      GRoot := NoSlash(TPath.GetDirectoryName(GFile));
      for GIdx := 1 to High(GPre.FileNames) do
        GRoot := CommonDir(GRoot, NoSlash(TPath.GetDirectoryName(
          GPre.FileNames[GIdx])));
      for GPath in GIncDirs do
        GRoot := CommonDir(GRoot, GPath);
      if GRoot = '' then
        raise Exception.Create('the unit, its includes and the -I ' +
          'directories share no root directory');

      for GIdx := 0 to High(GPre.FileNames) do
      begin
        GPath := Mirror(NoSlash(GPre.FileNames[GIdx]), GRoot, GOut);
        if GWritten.ContainsKey(LowerCase(GPath)) then
          Continue;
        GWritten.Add(LowerCase(GPath), True);
        WriteFile(GIdx, GPath);
        GFileLines.Add('file ' + NoSlash(GPre.FileNames[GIdx]) + #9 + GPath);
      end;

      GSitesText.Add(Format('# PasTreeXform %s  mode=%s  platform=%s  ' +
        'files=%d  parse-diagnostics=%d  pp-diagnostics=%d  ' +
        'dropped-sites=%d', [PasTreeVersion, cModeNames[GMode],
        PlatformName(GPlatform), Length(GPre.FileNames), Length(GDiags),
        GNonInfo, GDropped]));
      GSitesText.Add('# ' + GFile);
      GSitesText.Add('# id' + #9 + 'kind' + #9 + 'ops' + #9 + 'span' + #9 +
        'routine' + #9 + 'edit');
      for GIdx := 0 to GSites.Count - 1 do
      begin
        GSite := GSites[GIdx];
        GSitesText.Add(Format('%d'#9'%s'#9'%s'#9'%s'#9'%s'#9'%s', [GIdx + 1,
          GSite.Kind, GSite.Ops, GSite.Span, GSite.Routine, GSite.Edit]));
      end;
      TDirectory.CreateDirectory(GOut);
      GSitesText.WriteBOM := False;
      GSitesText.LineBreak := #13#10;
      GSitesText.SaveToFile(TPath.Combine(GOut, 'sites.txt'), TEncoding.UTF8);

      Writeln('main ', Mirror(NoSlash(GFile), GRoot, GOut));
      for GLine in GFileLines do
        Writeln(GLine);
      for GPath in GIncDirs do
        Writeln('idir ', GPath, #9, Mirror(GPath, GRoot, GOut));
      GLine := IntToStr(GSites.Count);
      if GDropped > 0 then
        GLine := GLine + ' dropped ' + IntToStr(GDropped);
      Writeln('sites ', GLine);
    finally
      GFileLines.Free;
      GSitesText.Free;
      GWritten.Free;
      GSites.Free;
      GEdits.Free;
      GPP.Free;
      GDefines.Free;
      GSM.Free;
      GIncDirs.Free;
      GDefNames.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
