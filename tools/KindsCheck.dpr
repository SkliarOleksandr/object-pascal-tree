program KindsCheck;

// Cross-checks AST node kinds between the spec (object-pascal-spec) and
// PasTree.Ast.pas — the spec's per-feature "*AST:* NodeName" hints vs the
// implemented TPasNodeKind enum. Reports both directions.
// NOTE: this is deliberately a CHECK, not a generator — the enum predates
// full spec-name alignment; the report drives convergence.
//
// Usage: KindsCheck <spec-dir> <PasTree.Ast.pas path>

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Generics.Collections,
  System.RegularExpressions;

var
  GSpecKinds, GCodeKinds: TDictionary<string, string>; // lc name -> original
  GFile, GText, GName: string;
  GMatch: TMatch;
  GMissing, GUnspecced: Integer;

begin
  if ParamCount < 2 then
  begin
    Writeln('Usage: KindsCheck <spec-dir> <PasTree.Ast.pas>');
    ExitCode := 2;
    Exit;
  end;
  GSpecKinds := TDictionary<string, string>.Create;
  GCodeKinds := TDictionary<string, string>.Create;
  try
    // Spec side: `*AST:* `NodeName` / *AST:* NodeName { ... } / lists.
    for GFile in TDirectory.GetFiles(ParamStr(1), '*.md') do
    begin
      GText := TFile.ReadAllText(GFile);
      // CamelCase with a second capital = a node name, not prose.
      for GMatch in TRegEx.Matches(GText,
        '\*AST:\*\s+`?([A-Z][a-z0-9]+(?:[A-Z][A-Za-z0-9]*)+)') do
      begin
        GName := GMatch.Groups[1].Value;
        GSpecKinds.AddOrSetValue(LowerCase(GName), GName);
      end;
    end;
    // Code side: nkXxx enum members.
    GText := TFile.ReadAllText(ParamStr(2));
    for GMatch in TRegEx.Matches(GText, '\bnk([A-Z][A-Za-z0-9]*)') do
      GCodeKinds.AddOrSetValue(LowerCase(GMatch.Groups[1].Value),
        GMatch.Groups[1].Value);

    Writeln('Spec AST hints: ', GSpecKinds.Count,
      '   Code kinds: ', GCodeKinds.Count);
    GMissing := 0;
    for GName in GSpecKinds.Keys do
      if not GCodeKinds.ContainsKey(GName) then
      begin
        Inc(GMissing);
        Writeln('  spec-only:  ', GSpecKinds[GName]);
      end;
    GUnspecced := 0;
    for GName in GCodeKinds.Keys do
      if not GSpecKinds.ContainsKey(GName) then
      begin
        Inc(GUnspecced);
        Writeln('  code-only:  nk', GCodeKinds[GName]);
      end;
    Writeln(Format('Missing in code: %d   Missing in spec: %d',
      [GMissing, GUnspecced]));
  finally
    GCodeKinds.Free;
    GSpecKinds.Free;
  end;
end.
