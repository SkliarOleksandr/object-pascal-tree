unit PasTree.SourceManager;

{
  PasTree — source file loading and include resolution.

  Loading is tolerant: BOMs are honored; files without a BOM that fail
  strict decoding fall back to a raw ANSI decode (token boundaries are what
  matter to the lexer; only string/comment payloads could mis-decode).
}

interface

uses
  System.SysUtils,
  System.Generics.Collections;

type
  TPasSourceManager = class
  private
    FSearchPaths: TArray<string>;
    FIncludeIndex: TDictionary<string, string>;  // basename -> full path
  public
    constructor Create(const ASearchPaths: TArray<string>);
    destructor Destroy; override;
    function LoadText(const APath: string): string;
    { Indexes every *.inc under ARoot by basename as a last-resort include
      resolver (corpus runs without real project search paths). The first
      occurrence of an ambiguous name wins. }
    procedure BuildIncludeIndex(const ARoot: string);
    { Resolves an include argument (possibly quoted) against the directory
      of the including file, then the search paths, then the index. }
    function ResolveInclude(const AIncludingFile, AName: string;
      out AResolved: string): Boolean;
  end;

implementation

uses
  System.Classes,
  System.IOUtils;

{ TPasSourceManager }

constructor TPasSourceManager.Create(const ASearchPaths: TArray<string>);
begin
  inherited Create;
  FSearchPaths := ASearchPaths;
end;

destructor TPasSourceManager.Destroy;
begin
  FIncludeIndex.Free;
  inherited;
end;

procedure TPasSourceManager.BuildIncludeIndex(const ARoot: string);
var
  LFile, LKey: string;
begin
  FreeAndNil(FIncludeIndex);
  FIncludeIndex := TDictionary<string, string>.Create;
  for LFile in TDirectory.GetFiles(ARoot, '*.inc',
    TSearchOption.soAllDirectories) do
  begin
    LKey := LowerCase(TPath.GetFileName(LFile));
    if not FIncludeIndex.ContainsKey(LKey) then
      FIncludeIndex.Add(LKey, LFile);
  end;
end;

function TPasSourceManager.LoadText(const APath: string): string;
var
  LBytes: TBytes;
begin
  try
    Result := TFile.ReadAllText(APath);
  except
    on E: EEncodingError do
    begin
      LBytes := TFile.ReadAllBytes(APath);
      Result := TEncoding.ANSI.GetString(LBytes);
    end;
  end;
end;

function TPasSourceManager.ResolveInclude(const AIncludingFile, AName: string;
  out AResolved: string): Boolean;
var
  LName, LCandidate, LDir: string;
begin
  LName := Trim(AName);
  if (Length(LName) >= 2) and (LName[1] = '''') and
     (LName[Length(LName)] = '''') then
    LName := Copy(LName, 2, Length(LName) - 2);
  if LName = '' then
    Exit(False);

  // 1. Relative to the including file.
  LDir := TPath.GetDirectoryName(AIncludingFile);
  if LDir <> '' then
  begin
    LCandidate := TPath.Combine(LDir, LName);
    if TFile.Exists(LCandidate) then
    begin
      AResolved := TPath.GetFullPath(LCandidate);
      Exit(True);
    end;
  end;

  // 2. Search paths.
  for LDir in FSearchPaths do
  begin
    LCandidate := TPath.Combine(LDir, LName);
    if TFile.Exists(LCandidate) then
    begin
      AResolved := TPath.GetFullPath(LCandidate);
      Exit(True);
    end;
  end;

  // 3. Basename index (corpus fallback).
  if (FIncludeIndex <> nil) and
     FIncludeIndex.TryGetValue(LowerCase(TPath.GetFileName(LName)), LCandidate)
  then
  begin
    AResolved := LCandidate;
    Exit(True);
  end;

  Result := False;
end;

end.
