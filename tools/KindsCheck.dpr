program KindsCheck;

// Cross-checks AST node kinds between the spec (object-pascal-spec) and
// PasTree.Ast.pas — the spec's per-feature "*AST:* NodeName" hints vs the
// implemented TPasNodeKind enum. Reports both directions.
//
// NOTE: this is deliberately a CHECK, not a generator — the enum predates
// full spec-name alignment; the report drives convergence.
//
// Vocabulary policy (see docs/DelphiAST-analysis.md and the spec):
//  - Pure synonyms are converged by renaming the spec's *AST:* hint to the
//    code's bare kind name (e.g. CallExpr -> Call). Those then match directly.
//  - Intentional many->one merges (several spec concepts fold into one kind +
//    Aux/flag) are declared in ALIASES below so they stop counting as drift.
//  - Structural helper kinds the spec never needs to name are in ALLOWLIST.
// A clean run therefore means: spec-only REAL GAP = 0 and code-only
// (unlisted) = 0. Anything left is a genuine action item, and the exit code
// is non-zero so this can gate CI later.
//
// Spec-name extraction: every backtick-quoted span on an *AST:* line
// contributes its LEADING identifier if it is Capitalized (node names are
// written `Name { ... }` or `Name`); this captures single-word kinds (Call,
// Block) and multi-name hints (`A`, `B`, `C`) alike.
//
// Usage: KindsCheck <spec-dir> <PasTree.Ast.pas path>

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Generics.Collections,
  System.RegularExpressions;

const
  // spec concept (lc) -> code bare kind (lc). Intentional many->one merges;
  // the spec keeps its descriptive name, the code stays homogeneous.
  ALIASES: array [0..22] of string = (
    'staticarraytype=arraytype',   // 8.x static/dynamic/open fold into one
    'dynamicarraytype=arraytype',
    'openarray=arraytype',
    'arrayliteral=setctor',        // [ ... ] shared set/array constructor
    'bracketconstructor=setctor',
    'methoddecl=routine',          // methods/operators are routines
    'operatordecl=routine',
    'typecastexpr=call',           // 4.10 cast-vs-call resolved semantically
    'nameofexpr=call',             // nameof(x) parses as a call
    'exitstmt=call',               // exit/break/continue are standard procs
    'isexpr=binaryop',             // is/as are binary operators (flag/Aux)
    'asexpr=binaryop',
    'generictypedecl=typedecl',    // generic params are children of TypeDecl
    'typealias=typedecl',          // Aux = 1 marks a distinct alias
    'typeref=typedecl',
    'anonmethodtype=proctype',     // reference to ... = proc type (Aux = 2)
    'proceduraltype=proctype',
    'fielddecl=vardecl',           // fields share the VarDecl node
    'typedconstdecl=constdecl',
    'resourcestringdecl=constdecl',// resourcestring -> nkConstDecl (parser 2459)
    'genericinstantiation=typeargs',
    'labeldecl=labelsec',
    'tryexceptstmt=trystmt'        // try/except & try/finally are one TryStmt
  );
  // TryFinallyStmt shares the alias below (kept separate for readability).
  ALIASES2: array [0..0] of string = (
    'tryfinallystmt=trystmt'
  );

  // Code bare kinds (lc) that are structural helpers / list wrappers the spec
  // legitimately does not give an *AST:* hint.
  ALLOWLIST: array [0..47] of string = (
    'error', 'missing', 'ident', 'reallit', 'nillit', 'caretchar', 'paren',
    'index', 'member', 'deref', 'range', 'anonparams', 'emptystmt', 'exprstmt',
    'casesel', 'caselabels', 'exceptpart', 'finallypart', 'inlineconst',
    'usesclause', 'usesitem', 'interfacesec', 'implementationsec', 'initsec',
    'finalsec', 'exportsclause', 'exportsitem', 'typesec', 'constsec', 'varsec',
    'aggregate', 'aggregatefield', 'enumvalue', 'stringtype', 'guid',
    'visibility', 'params', 'param', 'directive', 'propspec',
    'methodresolution', 'variantbranch', 'genericparams', 'genericparam',
    'constraint', 'attrgroup', 'attribute', 'routinebody'
  );

  // Backtick-leading idents that look like node names but are not.
  IGNORE_SPEC: array [0..0] of string = ('self');

var
  GSpecKinds, GCodeKinds: TDictionary<string, string>; // lc name -> original
  GAlias: TDictionary<string, string>;                 // lc spec -> lc code
  GAliasTargets: TDictionary<string, Boolean>;         // lc code covered by an alias
  GAllow, GIgnore: TDictionary<string, Boolean>;
  GFile, GText, GLine, GSpan, GName: string;
  GLineMatch, GSpanMatch, GLeadMatch: TMatch;
  GPair: string;
  GMatched, GAliased, GGap, GUnlisted: Integer;

procedure LoadPairs(const AArr: array of string);
var
  LItem: string;
  LEq: Integer;
begin
  for LItem in AArr do
  begin
    LEq := Pos('=', LItem);
    GAlias.AddOrSetValue(Copy(LItem, 1, LEq - 1), Copy(LItem, LEq + 1, MaxInt));
    GAliasTargets.AddOrSetValue(Copy(LItem, LEq + 1, MaxInt), True);
  end;
end;

begin
  if ParamCount < 2 then
  begin
    Writeln('Usage: KindsCheck <spec-dir> <PasTree.Ast.pas>');
    ExitCode := 2;
    Exit;
  end;
  GSpecKinds := TDictionary<string, string>.Create;
  GCodeKinds := TDictionary<string, string>.Create;
  GAlias := TDictionary<string, string>.Create;
  GAliasTargets := TDictionary<string, Boolean>.Create;
  GAllow := TDictionary<string, Boolean>.Create;
  GIgnore := TDictionary<string, Boolean>.Create;
  try
    LoadPairs(ALIASES);
    LoadPairs(ALIASES2);
    for GName in ALLOWLIST do
      GAllow.AddOrSetValue(GName, True);
    for GName in IGNORE_SPEC do
      GIgnore.AddOrSetValue(GName, True);

    // Spec side: leading Capitalized ident of each backtick span on an
    // *AST:* line.
    for GFile in TDirectory.GetFiles(ParamStr(1), '*.md') do
    begin
      GText := TFile.ReadAllText(GFile);
      for GLineMatch in TRegEx.Matches(GText, '(?m)^.*\*AST:\*.*$') do
      begin
        GLine := GLineMatch.Value;
        for GSpanMatch in TRegEx.Matches(GLine, '`([^`]+)`') do
        begin
          GSpan := GSpanMatch.Groups[1].Value;
          GLeadMatch := TRegEx.Match(GSpan, '^\s*([A-Za-z_][A-Za-z0-9_]*)');
          if not GLeadMatch.Success then
            Continue;
          GName := GLeadMatch.Groups[1].Value;
          if not CharInSet(GName[1], ['A'..'Z']) then
            Continue;
          if GIgnore.ContainsKey(LowerCase(GName)) then
            Continue;
          GSpecKinds.AddOrSetValue(LowerCase(GName), GName);
        end;
      end;
    end;

    // Code side: nkXxx enum members.
    GText := TFile.ReadAllText(ParamStr(2));
    for GLineMatch in TRegEx.Matches(GText, '\bnk([A-Z][A-Za-z0-9]*)') do
      GCodeKinds.AddOrSetValue(LowerCase(GLineMatch.Groups[1].Value),
        GLineMatch.Groups[1].Value);

    Writeln('Spec AST hints: ', GSpecKinds.Count,
      '   Code kinds: ', GCodeKinds.Count);
    Writeln;

    // Spec -> code classification.
    GMatched := 0; GAliased := 0; GGap := 0;
    Writeln('== matched-via-alias (intentional merges) ==');
    for GName in GSpecKinds.Keys do
    begin
      if GCodeKinds.ContainsKey(GName) then
        Inc(GMatched)
      else if GAlias.TryGetValue(GName, GPair) and GCodeKinds.ContainsKey(GPair) then
      begin
        Inc(GAliased);
        Writeln(Format('  %-22s -> nk%s', [GSpecKinds[GName], GCodeKinds[GPair]]));
      end;
    end;
    Writeln;
    Writeln('== spec-only REAL GAP (code node missing) ==');
    for GName in GSpecKinds.Keys do
      if not GCodeKinds.ContainsKey(GName) and
         not (GAlias.TryGetValue(GName, GPair) and GCodeKinds.ContainsKey(GPair)) then
      begin
        Inc(GGap);
        Writeln('  ', GSpecKinds[GName]);
      end;

    // Code -> spec classification.
    GUnlisted := 0;
    Writeln;
    Writeln('== code-only NOT in allow-list (needs a spec hint or allow-list) ==');
    for GName in GCodeKinds.Keys do
      if not GSpecKinds.ContainsKey(GName) and
         not GAliasTargets.ContainsKey(GName) and
         not GAllow.ContainsKey(GName) then
      begin
        Inc(GUnlisted);
        Writeln('  nk', GCodeKinds[GName]);
      end;

    Writeln;
    Writeln(Format('matched: %d   via-alias: %d   allow-listed helpers: %d',
      [GMatched, GAliased, GAllow.Count]));
    Writeln(Format('REAL GAP (spec-only): %d   code-only (unlisted): %d',
      [GGap, GUnlisted]));
    if (GGap > 0) or (GUnlisted > 0) then
      ExitCode := 1
    else
      ExitCode := 0;
  finally
    GIgnore.Free;
    GAllow.Free;
    GAliasTargets.Free;
    GAlias.Free;
    GCodeKinds.Free;
    GSpecKinds.Free;
  end;
end.
