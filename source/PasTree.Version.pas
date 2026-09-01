unit PasTree.Version;

{
  PasTree's own version, and nothing else.

  A SEPARATE UNIT ON PURPOSE. Everything that wants to report which PasTree it
  is built against - the LSP server's serverInfo, a tool's --version, a log
  header - can use this without dragging in the parser, the resolver or the
  RTL beyond SysUtils. That matters most for the consumer that is furthest
  away: the RAD Studio plugin cannot link PasTree at all (32-bit designtime
  package, PasTree is Win64-only), so it can only ever learn this number by
  asking the server, and the server can only tell it if reporting the version
  is free of the analysis machinery.

  VERSIONED INDEPENDENTLY OF ITS CONSUMER. PasTree and pastree-lsp (the LSP
  server together with its clients, which share one number between them) each
  count their own commits. What ties them together is not a shared number but a
  stated minimum: the server declares the oldest PasTree it works with
  (cMinPasTreeVersion) and fails loudly at startup when that is not met, since
  PasTree is linked into its exe. See CompareVersions.

  ONE PATCH BUMP PER COMMIT, MINOR FOR A SUBSTANTIAL CHANGE - see the
  Versioning section of the README. The short version: the patch component
  makes this number identify a BUILD, because the question it exists to answer
  is "which build is running", asked from outside a deployed binary; the minor
  component still means what semver says it means.

  The numbers start low deliberately: nothing here promises a stable API yet,
  which is exactly what 0.x means.
}

interface

const
  /// <summary>
  /// PasTree's version. BUMP THE PATCH IN EVERY COMMIT, mechanically; bump the
  /// MINOR for a substantial change - see the README's Versioning section. The
  /// patch component is what makes this able to answer "which build is this";
  /// what a consumer can RELY on is expressed by its own cMin... constant.
  /// </summary>
  PasTreeVersion = '0.14.1';

/// <summary>
/// The last-write time of a binary, formatted, or '' if it cannot be read.
///
/// This is the build stamp, and it is deliberately taken from the FILE rather
/// than baked in at compile time. Delphi has no compile-date macro (the
/// {$I %DATE%} form is Free Pascal's, and this was written with it once
/// already), and a generated include file is a build step that can be skipped
/// - whereas the timestamp of the binary that is actually running cannot lie
/// about itself. It answers the question a semver cannot during development:
/// "is the exe the IDE is running the one I just built?" Pass ParamStr(0) for
/// the running exe, or a module's own filename for a DLL/BPL.
/// </summary>
function BinaryBuiltOn(const APath: string): string;

/// <summary>
/// Compares two dotted version strings numerically: -1, 0 or +1, the usual
/// way round (Result &lt; 0 means A is older than B).
///
/// Numerically, NOT as text, because the obvious string comparison is wrong in
/// the one case that matters: '0.10.0' sorts BEFORE '0.9.0' as text, so a
/// minimum-version check written that way starts rejecting the newer builds
/// the moment a component reaches its tenth minor release. Missing components
/// count as zero, so '1' = '1.0' = '1.0.0'. Any pre-release suffix
/// ('0.2.0-rc1') is compared by its numeric part only - enough for a
/// compatibility gate, and deliberately not a full semver implementation.
/// </summary>
function CompareVersions(const A, B: string): Integer;

implementation

uses
  System.SysUtils, System.Classes, System.IOUtils;

function BinaryBuiltOn(const APath: string): string;
begin
  Result := '';
  try
    if TFile.Exists(APath) then
      Result := FormatDateTime('yyyy-mm-dd hh:nn',
        TFile.GetLastWriteTime(APath));
  except
    Result := '';   // a build stamp is never worth an exception
  end;
end;

function CompareVersions(const A, B: string): Integer;

  function PartOf(const AParts: TArray<string>; AIndex: Integer): Integer;
  var
    LText: string;
    LPos: Integer;
  begin
    Result := 0;
    if AIndex > High(AParts) then
      Exit;
    LText := AParts[AIndex];
    // Cut a pre-release/build suffix off the last component ('0-rc1' -> '0').
    LPos := 1;
    while (LPos <= Length(LText)) and CharInSet(LText[LPos], ['0'..'9']) do
      Inc(LPos);
    LText := Copy(LText, 1, LPos - 1);
    if LText <> '' then
      Result := StrToIntDef(LText, 0);
  end;

var
  LA, LB: TArray<string>;
  LIdx, LMax, LLeft, LRight: Integer;
begin
  LA := A.Split(['.']);
  LB := B.Split(['.']);
  LMax := Length(LA);
  if Length(LB) > LMax then
    LMax := Length(LB);
  for LIdx := 0 to LMax - 1 do
  begin
    LLeft := PartOf(LA, LIdx);
    LRight := PartOf(LB, LIdx);
    if LLeft <> LRight then
      if LLeft < LRight then
        Exit(-1)
      else
        Exit(1);
  end;
  Result := 0;
end;

end.
