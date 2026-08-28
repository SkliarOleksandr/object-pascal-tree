unit PasTree.Project;

{
  PasTree - project-level driver: parallel whole-tree parsing and .dproj
  platform detection.

  Parallel model (see README): parsing one file is a pure function of
  (text, defines, platform), so files are farmed out with one worker per
  core and NO locks on the hot path. Shared state is read-only: the source
  manager (include index built once up front) and the base define set
  (each preprocessor run works on its own clone). Results land in a
  pre-sized array by index - no contention, deterministic output.
}

interface

uses
  PasTree.Preprocessor,
  PasTree.Platforms,
  PasTree.Ast,
  PasTree.Parser,
  PasTree.SourceManager;

type
  TPasFileResult = record
    FileName: string;
    Tree: TPasTree;
    ParseDiags: TArray<TPasParseDiag>;
  end;

  TPasProject = class
  private
    FSourceManager: TPasSourceManager;
    FPlatform: TPasPlatform;
    FExtraDefines: TArray<string>;
  public
    constructor Create(APlatform: TPasPlatform;
      const ASearchPaths: TArray<string>;
      const AExtraDefines: TArray<string>);
    destructor Destroy; override;
    property SourceManager: TPasSourceManager read FSourceManager;
    { Parses every file in AFiles in parallel (one task per core). }
    function ParseFiles(const AFiles: TArray<string>): TArray<TPasFileResult>;
    { Collects .pas/.dpr/.dpk under ARoot and parses them in parallel. }
    function ParseDirectory(const ARoot: string): TArray<TPasFileResult>;
  end;

{ Reads the default <Platform> and <MainSource> from a .dproj (lightweight
  text scan; no XML dependency). Returns False if no platform was found. }
function TryReadDProj(const ADProjPath: string; out APlatform: TPasPlatform;
  out AMainSource: string): Boolean;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Threading;

{ TPasProject }

constructor TPasProject.Create(APlatform: TPasPlatform;
  const ASearchPaths: TArray<string>; const AExtraDefines: TArray<string>);
begin
  inherited Create;
  FPlatform := APlatform;
  FExtraDefines := AExtraDefines;
  FSourceManager := TPasSourceManager.Create(ASearchPaths);
end;

destructor TPasProject.Destroy;
begin
  FSourceManager.Free;
  inherited;
end;

function TPasProject.ParseFiles(
  const AFiles: TArray<string>): TArray<TPasFileResult>;
var
  LResults: TArray<TPasFileResult>;
  LInfo: TPasPlatformInfo;
  LBaseDefines: TPasDefines;
  LName: string;
begin
  SetLength(LResults, Length(AFiles));
  LInfo := PlatformInfo(FPlatform);
  // I/O first, CPU second - see TPasSourceManager.Prefetch (cold reads are
  // latency-bound; don't serialize them with parsing inside per-core workers).
  FSourceManager.Prefetch(AFiles);
  LBaseDefines := CreatePlatformDefines(FPlatform);
  try
    for LName in FExtraDefines do
      LBaseDefines.Define(LName);
    // Base defines and the source manager are read-only from here on;
    // every worker owns its preprocessor (which clones the defines per
    // file) and its parser state.
    TParallel.&For(0, High(AFiles),
      procedure(AIndex: Integer)
      var
        LPP: TPasPreprocessor;
        LPre: TPasPreprocessed;
      begin
        LPP := TPasPreprocessor.Create(FSourceManager, LBaseDefines, 37.0,
          LInfo.PointerBytes, LInfo.ExtendedBytes);
        try
          LPre := LPP.Process(AFiles[AIndex]);
          LResults[AIndex].FileName := AFiles[AIndex];
          LResults[AIndex].Tree :=
            TPasParser.ParseFile(LPre, LResults[AIndex].ParseDiags);
        finally
          LPP.Free;
        end;
      end);
  finally
    LBaseDefines.Free;
  end;
  Result := LResults;
end;

function TPasProject.ParseDirectory(
  const ARoot: string): TArray<TPasFileResult>;
var
  LAll, LFiles: TArray<string>;
  LFile, LExt: string;
  LCount: Integer;
begin
  FSourceManager.BuildIncludeIndex(ARoot);
  LAll := TDirectory.GetFiles(ARoot, '*.*', TSearchOption.soAllDirectories);
  SetLength(LFiles, Length(LAll));
  LCount := 0;
  for LFile in LAll do
  begin
    LExt := LowerCase(TPath.GetExtension(LFile));
    if (LExt = '.pas') or (LExt = '.dpr') or (LExt = '.dpk') then
    begin
      LFiles[LCount] := LFile;
      Inc(LCount);
    end;
  end;
  SetLength(LFiles, LCount);
  Result := ParseFiles(LFiles);
end;

function TryReadDProj(const ADProjPath: string; out APlatform: TPasPlatform;
  out AMainSource: string): Boolean;

  function TagContent(const AText, ATag: string): string;
  var
    LOpen, LFrom, LTo: Integer;
  begin
    // Matches <Tag ...>content</Tag>; first occurrence wins.
    Result := '';
    LOpen := Pos('<' + ATag, AText);
    if LOpen = 0 then
      Exit;
    LFrom := Pos('>', AText, LOpen);
    LTo := Pos('</' + ATag + '>', AText, LOpen);
    if (LFrom = 0) or (LTo = 0) or (LTo < LFrom) then
      Exit;
    Result := Trim(Copy(AText, LFrom + 1, LTo - LFrom - 1));
  end;

var
  LText, LValue: string;
begin
  APlatform := pfWin32;
  AMainSource := '';
  if not TFile.Exists(ADProjPath) then
    Exit(False);
  LText := TFile.ReadAllText(ADProjPath);
  AMainSource := TagContent(LText, 'MainSource');
  // Default platform: <Platform Condition="'$(Platform)'==''">Win64</Platform>
  LValue := TagContent(LText, 'Platform Condition');
  if LValue = '' then
    LValue := TagContent(LText, 'Platform');
  Result := (LValue <> '') and TryParsePlatformName(LValue, APlatform);
end;

end.
