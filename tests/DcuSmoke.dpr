program DcuSmoke;

{ Units with no source: the .dcu reader (PasTree.Dcu), the interface printer
  (PasTree.Dcu.Source) and the source manager's fallback to a compiled unit.

  The fixture is COMPILED HERE, by the dcc32 and dcc64 of the Studio
  build.bat's rsvars.bat put on the path (BDS in the environment): a checked-in
  binary would pin one compiler's output forever, while what this suite must
  hold is that the reader follows what the installed compiler writes. The
  fixture source is then kept OUT of the library directories, so the analyzer
  can only reach the unit through its .dcu.

  Checked: the tables read back (unit name, uses, a constant's value); the
  printed source carries each declaration shape once (enum, set, class with
  virtual/override/property/default, interface with GUID, generic, anonymous
  method type, helper, open array, default parameter, resourcestring, typed
  constant, class var, nested type, operator) and parses with no syntax
  diagnostic; a project importing the unit resolves every member with no
  E2003/F1027/E2034; a .pas beside a .dcu wins; navigation into the unit lands
  in the generated text; an unreadable .dcu (a version byte the reader does
  not know) is an F1027 that names the reason. }

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
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
  PasTree.Sema.Diagnostics in '..\source\PasTree.Sema.Diagnostics.pas',
  PasTree.Sema.Model in '..\source\PasTree.Sema.Model.pas',
  PasTree.Sema.Builtins in '..\source\PasTree.Sema.Builtins.pas',
  PasTree.Sema.Resolver in '..\source\PasTree.Sema.Resolver.pas',
  PasTree.Sema.Dump in '..\source\PasTree.Sema.Dump.pas',
  PasTree.Sema.Nav in '..\source\PasTree.Sema.Nav.pas',
  PasTree.Sema.Project in '..\source\PasTree.Sema.Project.pas',
  PasTree.TestKit in 'PasTree.TestKit.pas';

const
  FIXTURE: array[0..67] of string = (
    'unit DcuFix;',
    'interface',
    'uses System.SysUtils, System.Classes;',
    'const',
    '  KAnswer = 42;',
    '  KName = ''PasTree'';',
    '  KPi = 3.25;',
    '  KTyped: Integer = 5;',
    'resourcestring',
    '  SHello = ''Hello'';',
    'type',
    '  TColor3 = (cRed, cGreen, cBlue);',
    '  TColors = set of TColor3;',
    '  TGrid = array[0..3] of Integer;',
    '  TNotify = procedure(Sender: TObject) of object;',
    '  TCallback = reference to procedure(A: Integer);',
    '  TShape = class;',
    '  PShape = ^TShape;',
    '  IShape = interface(IInterface)',
    '    [''{5C4B7E62-1D3A-4F0B-9E2C-0A1B2C3D4E5F}'']',
    '    function GetName: string;',
    '  end;',
    '  TShape = class(TObject)',
    '  public type',
    '    TKind = (skRound, skSquare);',
    '  private',
    '    FTag: Integer;',
    '    function GetArea: Double;',
    '  protected',
    '    class var FCount: Integer;',
    '  public',
    '    const DefaultTag = 7;',
    '    procedure Draw; virtual;',
    '    class function Kind: TKind; virtual;',
    '    property Area: Double read GetArea;',
    '    property Tag: Integer read FTag write FTag default 7;',
    '  end;',
    '  TCircle = class(TShape)',
    '  public',
    '    constructor Create(ARadius: Double = 1.5);',
    '    procedure Draw; override;',
    '  end;',
    '  TBox<T> = class(TObject)',
    '  private',
    '    FItem: T;',
    '  public',
    '    function Get: T;',
    '    procedure Put(const AItem: T);',
    '  end;',
    '  TShapeHelper = class helper for TShape',
    '    procedure Ext;',
    '  end;',
    '  TVec = record',
    '    X, Y: Integer;',
    '    class operator Add(const A, B: TVec): TVec;',
    '  end;',
    'var',
    '  GCount: Integer;',
    'function Sum(const A: array of Integer): Integer;',
    'procedure Log(const S: string; Level: Integer = 3); overload;',
    'procedure Log(const S: string; const Args: array of const); overload;',
    'implementation',
    'function TShape.GetArea: Double; begin Result := 0; end;',
    'procedure TShape.Draw; begin end;',
    'class function TShape.Kind: TKind; begin Result := skRound; end;',
    'constructor TCircle.Create(ARadius: Double); begin inherited Create; end;',
    'procedure TCircle.Draw; begin inherited; end;',
    'function TBox<T>.Get: T; begin Result := FItem; end;');
  FIXTURE_TAIL: array[0..7] of string = (
    'procedure TBox<T>.Put(const AItem: T); begin FItem := AItem; end;',
    'procedure TShapeHelper.Ext; begin end;',
    'class operator TVec.Add(const A, B: TVec): TVec;',
    'begin Result.X := A.X + B.X; Result.Y := A.Y + B.Y; end;',
    'function Sum(const A: array of Integer): Integer; begin Result := Length(A); end;',
    'procedure Log(const S: string; Level: Integer); begin end;',
    'procedure Log(const S: string; const Args: array of const); begin end;',
    'end.');

  USER_UNIT: array[0..29] of string = (
    'unit DcuUser;',
    'interface',
    'uses DcuFix;',
    'type',
    '  TSq = class(TCircle)',
    '    procedure Draw; override;',
    '  end;',
    'procedure Run;',
    'implementation',
    'procedure TSq.Draw; begin inherited; end;',
    'procedure Run;',
    'var',
    '  S: TShape; B: TBox<Integer>; C: TColors; I: Integer; CB: TCallback;',
    '  V: TVec; K: TShape.TKind;',
    'begin',
    '  S := TCircle.Create;',
    '  S := TCircle.Create(2.0);',
    '  S.Draw;',
    '  I := S.Tag + KAnswer + Sum([1, 2]) + TShape.DefaultTag;',
    '  Log(''x'');',
    '  Log(''x'', 1);',
    '  C := [cRed, cBlue];',
    '  B := TBox<Integer>.Create;',
    '  B.Put(3);',
    '  I := B.Get;',
    '  S.Ext;',
    '  K := TShape.Kind;',
    '  V := V + V;',
    '  GCount := I + Length(KName) + Length(SHello) + KTyped;',
    'end;');

var
  GCounter: TPasSuiteCounter;
  GProj: TPasSemaProject;

procedure Ok(const AName: string; ACond: Boolean);
begin
  GCounter.Ok(AName, ACond);
end;

function Lines(const AArr: array of string): string;
var
  LIdx: Integer;
begin
  Result := '';
  for LIdx := 0 to High(AArr) do
    Result := Result + AArr[LIdx] + #13#10;
end;

// Runs a command line to completion and returns its exit code, -1 when it
// could not be started.
function RunProcess(const ACmdLine, ADir: string): Integer;
var
  LSI: TStartupInfo;
  LPI: TProcessInformation;
  LCmd: string;
  LCode: DWORD;
begin
  Result := -1;
  FillChar(LSI, SizeOf(LSI), 0);
  LSI.cb := SizeOf(LSI);
  LSI.dwFlags := STARTF_USESHOWWINDOW;
  LSI.wShowWindow := SW_HIDE;
  LCmd := ACmdLine;
  UniqueString(LCmd);
  if not CreateProcess(nil, PChar(LCmd), nil, nil, False, CREATE_NO_WINDOW,
    nil, PChar(ADir), LSI, LPI) then
    Exit;
  try
    WaitForSingleObject(LPI.hProcess, 120000);
    if GetExitCodeProcess(LPI.hProcess, LCode) then
      Result := Integer(LCode);
  finally
    CloseHandle(LPI.hThread);
    CloseHandle(LPI.hProcess);
  end;
end;

function StudioRoot: string;
begin
  Result := ExcludeTrailingPathDelimiter(GetEnvironmentVariable('BDS'));
  if Result = '' then
    Result := 'C:\Program Files (x86)\Embarcadero\Studio\37.0';
end;

// Compiles the fixture with the given compiler into ALibDir and removes the
// intermediate files, leaving DcuFix.dcu (and Both.dcu + Both.pas) there.
function CompileFixture(const ACompiler, ASrcDir, ALibDir, APlatform: string): Boolean;
var
  LCmd: string;
begin
  TDirectory.CreateDirectory(ALibDir);
  LCmd := Format('"%s\bin\%s" -B -Q -N0"%s" -E"%s" -U"%s\lib\%s\release" ' +
    '-NSSystem;Winapi "%s"', [StudioRoot, ACompiler, ALibDir, ALibDir, StudioRoot,
    APlatform, TPath.Combine(ASrcDir, 'DcuFix.pas')]);
  Result := RunProcess(LCmd, ASrcDir) = 0;
  if not Result then
    Writeln('  (fixture compile failed: ', LCmd, ')');
end;

function MidByName(const ANameLower: string): Integer;
begin
  Result := -1;
  for var LId := 0 to GProj.ModelCount - 1 do
    if GProj.Model(LId).UnitNameLower = ANameLower then
      Exit(LId);
end;

function DiagCount(AMid: Integer; const ACode: string): Integer;
begin
  Result := 0;
  if AMid < 0 then
    Exit(-1);
  for var LIdx := 0 to High(GProj.Model(AMid).Diags) do
    if GProj.Model(AMid).Diags[LIdx].Code = ACode then
      Inc(Result);
end;

function DiagText(AMid: Integer; const ACode: string): string;
begin
  Result := '';
  if AMid < 0 then
    Exit;
  for var LIdx := 0 to High(GProj.Model(AMid).Diags) do
    if GProj.Model(AMid).Diags[LIdx].Code = ACode then
      Exit(GProj.Model(AMid).Diags[LIdx].Msg);
end;

function ParseDiagCount(const ASource, AName: string): Integer;
var
  LSM: TPasSourceManager;
  LPP: TPasPreprocessor;
  LPre: TPasPreprocessed;
  LDiags: TArray<TPasParseDiag>;
begin
  LSM := TPasSourceManager.Create(nil);
  try
    LPP := TPasPreprocessor.Create(LSM, TPasDefines.Create);
    try
      LPre := LPP.ProcessText(AName, ASource);
      TPasParser.ParseFile(LPre, LDiags);
      Result := Length(LDiags);
    finally
      LPP.Free;
    end;
  finally
    LSM.Free;
  end;
end;

// The 1-based line of ASource whose text contains AText, 0 when none.
function LineWith(const ASource, AText: string): Integer;
var
  LList: TStringList;
  LIdx: Integer;
begin
  Result := 0;
  LList := TStringList.Create;
  try
    LList.Text := ASource;
    for LIdx := 0 to LList.Count - 1 do
      if LList[LIdx].Contains(AText) then
        Exit(LIdx + 1);
  finally
    LList.Free;
  end;
end;

procedure CheckReaderAndPrinter(const ADcuPath: string; APlatform: TPasDcuPlatform;
  const ATag: string);
var
  LUnit: TPasDcuUnit;
  LSrc: string;
  LDecl, LConst: TPasDcuDecl;
  LHasUses: Boolean;
  LUses: TPasDcuUses;
  LNotes: TArray<string>;
begin
  LUnit := LoadDcu(ADcuPath);
  try
    Ok(ATag + ': unit name read from the source-file record',
      SameText(LUnit.UnitName, 'DcuFix'));
    Ok(ATag + ': platform byte decoded', LUnit.Platform = APlatform);
    Ok(ATag + ': a supported version (Delphi 11 to 13)',
      DcuVersionSupported(LUnit.VersionByte) and
      (DcuVersionName(LUnit.VersionByte).StartsWith('Delphi 1')));
    LHasUses := False;
    for LUses in LUnit.UsesList do
      if SameText(LUses.Name, 'System.Classes') and (LUses.Section = usInterface) then
        LHasUses := True;
    Ok(ATag + ': the interface uses list names System.Classes', LHasUses);
    LConst := nil;
    for LDecl in LUnit.Decls do
      if (LDecl.Kind = dkConst) and (LDecl.Name = 'KAnswer') then
        LConst := LDecl;
    Ok(ATag + ': a constant is read with its value',
      (LConst <> nil) and (LConst.ValueInt = 42) and LConst.IsInterfaceVisible);
    Ok(ATag + ': every declaration that took a slot is in the address table',
      (LConst <> nil) and (LUnit.AddrAt(LConst.Slot) = LConst));
    Ok(ATag + ': no reader warnings', Length(LUnit.Warnings) = 0);

    LSrc := DcuInterfaceSource(LUnit, LNotes);
    Ok(ATag + ': nothing left unresolved by the printer', Length(LNotes) = 0);
    Ok(ATag + ': unit header', LSrc.Contains('unit DcuFix;'));
    Ok(ATag + ': interface uses without System', LSrc.Contains('System.SysUtils, System.Classes;')
      and not LSrc.Contains('  System, '));
    Ok(ATag + ': ordinal constant', LSrc.Contains('KAnswer = 42;'));
    Ok(ATag + ': string constant', LSrc.Contains('KName = ''PasTree'';'));
    Ok(ATag + ': float constant', LSrc.Contains('KPi = 3.25;'));
    Ok(ATag + ': typed constant as a typed variable',
      LSrc.Contains('KTyped: Integer; { typed constant'));
    Ok(ATag + ': resourcestring with an empty value',
      LSrc.Contains('SHello = ''''; {'));
    Ok(ATag + ': enumeration', LSrc.Contains('TColor3 = (cRed, cGreen, cBlue);'));
    Ok(ATag + ': set', LSrc.Contains('TColors = set of TColor3;'));
    Ok(ATag + ': static array', LSrc.Contains('TGrid = array[0..3] of Integer;'));
    Ok(ATag + ': method pointer type',
      LSrc.Contains('TNotify = procedure(Sender: TObject) of object;'));
    Ok(ATag + ': anonymous method type',
      LSrc.Contains('TCallback = reference to procedure(A: Integer);'));
    Ok(ATag + ': pointer type', LSrc.Contains('PShape = ^TShape;'));
    Ok(ATag + ': interface with GUID',
      LSrc.Contains('IShape = interface(IInterface)') and
      LSrc.Contains('[''{5C4B7E62-1D3A-4F0B-9E2C-0A1B2C3D4E5F}'']') and
      (LSrc.Contains('function GetName: string;') or LSrc.Contains('function GetName: UnicodeString;')));
    Ok(ATag + ': class head', LSrc.Contains('TShape = class(TObject)'));
    Ok(ATag + ': nested type', LSrc.Contains('TKind = (skRound, skSquare);'));
    Ok(ATag + ': class const', LSrc.Contains('DefaultTag = 7;'));
    Ok(ATag + ': class var', LSrc.Contains('class var FCount: Integer;'));
    Ok(ATag + ': virtual method', LSrc.Contains('procedure Draw; virtual;'));
    Ok(ATag + ': class function', LSrc.Contains('class function Kind: TShape.TKind; virtual;'));
    Ok(ATag + ': read-only property', LSrc.Contains('property Area: Double read GetArea;'));
    Ok(ATag + ': property with default',
      LSrc.Contains('property Tag: Integer read FTag write FTag default 7;'));
    Ok(ATag + ': visibility words', LSrc.Contains('    private') and
      LSrc.Contains('    protected') and LSrc.Contains('    public'));
    Ok(ATag + ': override', LSrc.Contains('procedure Draw; override;'));
    Ok(ATag + ': constructor with a float default',
      LSrc.Contains('constructor Create(ARadius: Double = 1.5);'));
    Ok(ATag + ': generic class head', LSrc.Contains('TBox<T> = class(TObject)'));
    Ok(ATag + ': generic members name the parameter',
      LSrc.Contains('FItem: T;') and LSrc.Contains('function Get: T;') and
      LSrc.Contains('procedure Put(const AItem: T);'));
    Ok(ATag + ': class helper', LSrc.Contains('TShapeHelper = class helper for TShape'));
    Ok(ATag + ': record with operator',
      LSrc.Contains('TVec = record') and
      LSrc.Contains('class operator Add(const A: TVec; const B: TVec): TVec;'));
    Ok(ATag + ': global variable', LSrc.Contains('GCount: Integer;'));
    Ok(ATag + ': open array parameter',
      LSrc.Contains('function Sum(const A: array of Integer): Integer;'));
    Ok(ATag + ': default parameter and overload',
      (LSrc.Contains('procedure Log(const S: string; Level: Integer = 3); overload;') or LSrc.Contains('procedure Log(const S: UnicodeString; Level: Integer = 3); overload;')));
    Ok(ATag + ': array of const',
      (LSrc.Contains('procedure Log(const S: string; const Args: array of const); overload;') or LSrc.Contains('procedure Log(const S: UnicodeString; const Args: array of const); overload;')));
    Ok(ATag + ': implementation part is empty',
      LSrc.Contains(#13#10'implementation'#13#10#13#10'end.'));
    Ok(ATag + ': the generated source parses without a syntax diagnostic',
      ParseDiagCount(LSrc, 'DcuFix.dcu') = 0);
  finally
    LUnit.Free;
  end;
end;

procedure CheckProject(const ALibDir, AProjDir: string; APlatform: TPasPlatform;
  const ATag: string);
var
  LNav: TPasNavigator;
  LMidFix, LMidUser: Integer;
  LTarget: TPasNavTarget;
  LIdent: TPasNavIdent;
  LText: string;
  LLine: Integer;
begin
  GProj := TPasSemaProject.Create(APlatform, [ALibDir,
    TPath.Combine(StudioRoot, 'source\rtl\sys'),
    TPath.Combine(StudioRoot, 'source\rtl\common'),
    TPath.Combine(StudioRoot, 'source\rtl\win')], []);
  try
    GProj.SetNamespaces(['System', 'Winapi']);
    GProj.AnalyzeProject(TPath.Combine(AProjDir, 'DcuApp.dpr'));
    LMidFix := MidByName('dcufix');
    LMidUser := MidByName('dcuuser');
    Ok(ATag + ': the compiled unit is in the closure', LMidFix >= 0);
    Ok(ATag + ': its model file is the .dcu',
      (LMidFix >= 0) and TPasSourceManager.IsDcuPath(GProj.ModelFile(LMidFix)));
    Ok(ATag + ': the importer has no F1027', DiagCount(LMidUser, 'F1027') = 0);
    Ok(ATag + ': the importer has no E2003', DiagCount(LMidUser, 'E2003') = 0);
    Ok(ATag + ': default parameters satisfy the arity check',
      (DiagCount(LMidUser, 'E2034') = 0) and (DiagCount(LMidUser, 'E2035') = 0));
    Ok(ATag + ': the generated unit itself is clean',
      (LMidFix >= 0) and (Length(GProj.Model(LMidFix).Diags) = 0));
    Ok(ATag + ': a .pas beside a .dcu wins',
      (MidByName('both') >= 0) and
      SameText(TPath.GetExtension(GProj.ModelFile(MidByName('both'))), '.pas'));
    Ok(ATag + ': an unreadable .dcu is an F1027 naming the reason',
      (DiagCount(MidByName('bogususer'), 'F1027') = 1) and
      DiagText(MidByName('bogususer'), 'F1027').Contains('could not be read') and
      DiagText(MidByName('bogususer'), 'F1027').Contains('version byte $1B'));
    // Navigation: `S.Draw` in Run lands on TShape.Draw's line of the
    // generated text.
    LNav := TPasNavigator.Create(GProj);
    try
      // Line 18 of USER_UNIT is `  S.Draw;` - the member name at column 5:
      // IdentAt + ResolveDecl is the demo's Ctrl+Click.
      if (LMidUser >= 0) and LNav.IdentAt(LMidUser, 18, 5, LIdent) and
         LNav.ResolveDecl(LMidUser, LIdent.Node, LTarget) then
      begin
        Ok(ATag + ': navigation lands in the .dcu',
          TPasSourceManager.IsDcuPath(LTarget.FilePath) and (LTarget.Line > 0));
        if not TPasSourceManager.IsDcuPath(LTarget.FilePath) then
          Writeln('  (target: ', LTarget.FilePath, ' line ', LTarget.Line, ' name ', LTarget.Name, ' unit ', LTarget.UnitId, ')');
        LText := TPasSourceManager.LoadFileTolerant(LTarget.FilePath);
        LLine := LineWith(LText, 'procedure Draw; virtual;');
        Ok(ATag + ': ...on the declaration line of the generated text',
          (LLine > 0) and (LLine = LTarget.Line));
      end
      else
      begin
        Ok(ATag + ': navigation resolves S.Draw', False);
        Writeln('  (GotoDeclaration failed; user model ', LMidUser, ')');
      end;
    finally
      LNav.Free;
    end;
  finally
    FreeAndNil(GProj);
  end;
end;

var
  GDir, GSrcDir, GLib32, GLib64, GProjDir: string;
  GBytes: TBytes;
  GVer, GPlat: Byte;
  GMsg: string;

begin
  GCounter.Init;
  GDir := TPath.Combine(TPath.GetTempPath, 'PasTreeDcuSmoke_' +
    IntToStr(GetCurrentProcessId));
  GSrcDir := TPath.Combine(GDir, 'src');
  GLib32 := TPath.Combine(GDir, 'lib32');
  GLib64 := TPath.Combine(GDir, 'lib64');
  GProjDir := TPath.Combine(GDir, 'proj');
  try
    TDirectory.CreateDirectory(GSrcDir);
    TDirectory.CreateDirectory(GProjDir);
    TFile.WriteAllText(TPath.Combine(GSrcDir, 'DcuFix.pas'),
      Lines(FIXTURE) + Lines(FIXTURE_TAIL));
    Ok('fixture compiles for Win32', CompileFixture('dcc32.exe', GSrcDir, GLib32, 'win32'));
    Ok('fixture compiles for Win64', CompileFixture('dcc64.exe', GSrcDir, GLib64, 'win64'));
    // Both.pas beside Both.dcu: a copy of the fixture under another name, in
    // the library directory itself.
    TFile.WriteAllText(TPath.Combine(GLib32, 'Both.pas'),
      (Lines(FIXTURE) + Lines(FIXTURE_TAIL)).Replace('unit DcuFix;', 'unit Both;'));
    TFile.WriteAllText(TPath.Combine(GLib64, 'Both.pas'),
      (Lines(FIXTURE) + Lines(FIXTURE_TAIL)).Replace('unit DcuFix;', 'unit Both;'));
    TFile.Copy(TPath.Combine(GLib32, 'DcuFix.dcu'), TPath.Combine(GLib32, 'Both.dcu'));
    TFile.Copy(TPath.Combine(GLib64, 'DcuFix.dcu'), TPath.Combine(GLib64, 'Both.dcu'));
    // A .dcu of a compiler this reader does not know: the modern magic with
    // version byte $1B (XE6) and a plausible size field.
    GBytes := TBytes.Create($4D, $03, $00, $1B, $10, $00, $00, $00,
      0, 0, 0, 0, 0, 0, 0, 0);
    TFile.WriteAllBytes(TPath.Combine(GLib32, 'Bogus.dcu'), GBytes);
    TFile.WriteAllBytes(TPath.Combine(GLib64, 'Bogus.dcu'), GBytes);

    // The header sniff and the refusal message, without a project.
    Ok('header sniff decodes the modern magic',
      DcuHeader(GBytes, GVer, GPlat) and (GVer = $1B) and (GPlat = $03));
    Ok('version support is Delphi 11 to 13 only',
      not DcuVersionSupported($1B) and DcuVersionSupported($23) and
      DcuVersionSupported($25) and not DcuVersionSupported($26));
    GMsg := '';
    try
      LoadDcu(TPath.Combine(GLib32, 'Bogus.dcu')).Free;
    except
      on E: EPasDcuError do
        GMsg := E.Message;
    end;
    Ok('an unsupported version is refused by name',
      GMsg.Contains('version byte $1B') and GMsg.Contains('not supported'));
    Ok('a file that is not a .dcu is refused',
      not DcuHeader(TBytes.Create(1, 2, 3, 4, 5, 6, 7, 8), GVer, GPlat));

    if TFile.Exists(TPath.Combine(GLib32, 'DcuFix.dcu')) then
      CheckReaderAndPrinter(TPath.Combine(GLib32, 'DcuFix.dcu'), dcuWin32, 'win32');
    if TFile.Exists(TPath.Combine(GLib64, 'DcuFix.dcu')) then
      CheckReaderAndPrinter(TPath.Combine(GLib64, 'DcuFix.dcu'), dcuWin64, 'win64');

    // The project: the fixture is reachable through its .dcu only.
    TFile.WriteAllText(TPath.Combine(GProjDir, 'DcuUser.pas'), Lines(USER_UNIT) + 'end.'#13#10);
    TFile.WriteAllText(TPath.Combine(GProjDir, 'BogusUser.pas'),
      'unit BogusUser;'#13#10'interface'#13#10'uses Bogus;'#13#10 +
      'implementation'#13#10'end.'#13#10);
    TFile.WriteAllText(TPath.Combine(GProjDir, 'DcuApp.dpr'),
      'program DcuApp;'#13#10'uses DcuUser, Both, BogusUser;'#13#10 +
      'begin'#13#10'  Run;'#13#10'end.'#13#10);
    if TFile.Exists(TPath.Combine(GLib32, 'DcuFix.dcu')) then
      CheckProject(GLib32, GProjDir, pfWin32, 'project/win32');
    if TFile.Exists(TPath.Combine(GLib64, 'DcuFix.dcu')) then
      CheckProject(GLib64, GProjDir, pfWin64, 'project/win64');
  finally
    if TDirectory.Exists(GDir) then
      TDirectory.Delete(GDir, True);
  end;

  if GCounter.Finish('DcuSmoke') then
    ExitCode := 1;
end.
