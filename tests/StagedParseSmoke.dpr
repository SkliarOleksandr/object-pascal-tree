program StagedParseSmoke;

{
  Interface-only parsing (TPasParser.ParseFile ..., AInterfaceOnly := True) is
  stage 1 of the async parser's two-wave scheme. Its whole correctness rests
  on the PREFIX INVARIANT: the interface-only tree's nodes [0..N-1] are
  byte-identical to a FULL parse of the same source, with exactly two allowed
  divergences -
    - Nodes[0] (the unit root) LastToken: the interface-only root spans less;
    - the nkInterfaceSec node's NextSibling: NIL_NODE here, but the
      implementation section in a full parse.
  These tests reuse ONE TPasPreprocessed per case (both parses share stage-1
  lex+preprocess, exactly as the async pipeline does) and assert the invariant
  field-by-field, so any future parser change that would break the snapshot
  swap fails loudly here.
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.TestKit in 'PasTree.TestKit.pas';

var
  GSM: TPasSourceManager;
  GDefines: TPasDefines;
  GPP: TPasPreprocessor;
  GCounter: TPasSuiteCounter;

procedure Ok(const AName: string; ACond: Boolean);
begin
  GCounter.Ok(AName, ACond);
end;

// Index of the (single) nkInterfaceSec child of the root, or NIL_NODE.
function InterfaceSecOf(const ATree: TPasTree): Integer;
var
  LChild: Integer;
begin
  Result := NIL_NODE;
  if Length(ATree.Nodes) = 0 then
    Exit;
  LChild := ATree.Nodes[0].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if ATree.Nodes[LChild].Kind = nkInterfaceSec then
      Exit(LChild);
    LChild := ATree.Nodes[LChild].NextSibling;
  end;
end;

function NodesEqual(const A, B: TPasNode): Boolean;
begin
  Result := (A.Kind = B.Kind) and (A.Flags = B.Flags) and
    (A.FirstToken = B.FirstToken) and (A.LastToken = B.LastToken) and
    (A.Parent = B.Parent) and (A.FirstChild = B.FirstChild) and
    (A.NextSibling = B.NextSibling) and (A.Aux = B.Aux);
end;

// Assert AIntf is a strict prefix of AFull with EXACTLY the two documented
// divergences (root LastToken; interface-sec NextSibling) and nothing else.
procedure CheckPrefix(const ACase: string; const AIntf, AFull: TPasTree);
var
  LIntfSec, LI: Integer;
  LA, LB: TPasNode;
  LFieldsOk, LRootLastDiffered, LSecSiblingDiffered: Boolean;
begin
  Ok(ACase + ': intf has fewer nodes than full',
    Length(AIntf.Nodes) < Length(AFull.Nodes));
  if Length(AIntf.Nodes) >= Length(AFull.Nodes) then
    Exit;
  LIntfSec := InterfaceSecOf(AIntf);
  Ok(ACase + ': has an interface section', LIntfSec <> NIL_NODE);

  LFieldsOk := True;
  LRootLastDiffered := False;
  LSecSiblingDiffered := False;
  for LI := 0 to High(AIntf.Nodes) do
  begin
    LA := AIntf.Nodes[LI];
    LB := AFull.Nodes[LI];
    // Every field must match, EXCEPT the two sanctioned deltas - which we
    // require to actually be present (they prove the two parses really did
    // diverge where expected, not that they happened to be identical).
    if (LI = 0) and (LA.LastToken <> LB.LastToken) then
    begin
      LRootLastDiffered := True;
      // compare the root ignoring LastToken
      if not ((LA.Kind = LB.Kind) and (LA.Flags = LB.Flags) and
        (LA.FirstToken = LB.FirstToken) and (LA.Parent = LB.Parent) and
        (LA.FirstChild = LB.FirstChild) and (LA.NextSibling = LB.NextSibling)
        and (LA.Aux = LB.Aux)) then
      begin
        LFieldsOk := False;
        Writeln('  ', ACase, ': root node differs beyond LastToken');
      end;
    end
    else if (LI = LIntfSec) and (LA.NextSibling <> LB.NextSibling) then
    begin
      LSecSiblingDiffered := True;
      if not ((LA.NextSibling = NIL_NODE) and (LB.NextSibling <> NIL_NODE) and
        (AFull.Nodes[LB.NextSibling].Kind = nkImplementationSec)) then
      begin
        LFieldsOk := False;
        Writeln('  ', ACase, ': intf-sec sibling delta is not ',
          'NIL -> implementation section');
      end;
      // and every OTHER field of the interface-sec node must still match
      if not ((LA.Kind = LB.Kind) and (LA.Flags = LB.Flags) and
        (LA.FirstToken = LB.FirstToken) and (LA.LastToken = LB.LastToken) and
        (LA.Parent = LB.Parent) and (LA.FirstChild = LB.FirstChild) and
        (LA.Aux = LB.Aux)) then
      begin
        LFieldsOk := False;
        Writeln('  ', ACase, ': intf-sec node differs beyond NextSibling');
      end;
    end
    else if not NodesEqual(LA, LB) then
    begin
      LFieldsOk := False;
      Writeln(Format('  %s: node %d differs (kind %s)',
        [ACase, LI, AIntf.KindName(LA.Kind)]));
    end;
  end;

  Ok(ACase + ': all nodes match except the two sanctioned deltas', LFieldsOk);
  Ok(ACase + ': root LastToken really did differ', LRootLastDiffered);
  Ok(ACase + ': interface-sec NextSibling really did differ',
    LSecSiblingDiffered);
end;

// Full parse of AText through the shared preprocessor.
function ParseBoth(const AText: string; out AIntf, AFull: TPasTree): Boolean;
var
  LPre: TPasPreprocessed;
  LD1, LD2: TArray<TPasParseDiag>;
begin
  LPre := GPP.ProcessText('test.pas', AText);
  AIntf := TPasParser.ParseFile(LPre, LD1, {AInterfaceOnly} True);
  AFull := TPasParser.ParseFile(LPre, LD2, {AInterfaceOnly} False);
  Result := True;
end;

function TreesIdentical(const A, B: TPasTree): Boolean;
var
  LI: Integer;
begin
  Result := Length(A.Nodes) = Length(B.Nodes);
  if not Result then
    Exit;
  for LI := 0 to High(A.Nodes) do
    if not NodesEqual(A.Nodes[LI], B.Nodes[LI]) then
      Exit(False);
end;

const
  UNIT_BASIC =
    'unit Sample;'#10 +
    'interface'#10 +
    'uses System.SysUtils, System.Classes;'#10 +
    'type'#10 +
    '  TFoo = class'#10 +
    '    function Bar(A: Integer): string;'#10 +
    '    procedure Baz;'#10 +
    '  end;'#10 +
    'var GCount: Integer;'#10 +
    'procedure Global(X: Integer);'#10 +
    'implementation'#10 +
    'uses System.Math;'#10 +
    'function TFoo.Bar(A: Integer): string;'#10 +
    'begin'#10 +
    '  Result := IntToStr(A);'#10 +
    'end;'#10 +
    'procedure TFoo.Baz;'#10 +
    'begin'#10 +
    'end;'#10 +
    'procedure Global(X: Integer);'#10 +
    'begin'#10 +
    '  GCount := X;'#10 +
    'end;'#10 +
    'initialization'#10 +
    '  GCount := 0;'#10 +
    'finalization'#10 +
    'end.'#10;

  // $IFDEF opened in the interface and another closed in the implementation:
  // whole-file preprocessing (shared stage 1) resolves both regardless of the
  // interface/implementation cut, so the visible stream - and thus the prefix
  // - is unaffected. WIN64 is defined (see main), NEXTGEN is not.
  UNIT_IFDEF =
    'unit CondSample;'#10 +
    'interface'#10 +
    '{$IFDEF WIN64}'#10 +
    'const PtrKind = 64;'#10 +
    '{$ELSE}'#10 +
    'const PtrKind = 32;'#10 +
    '{$ENDIF}'#10 +
    'procedure P;'#10 +
    'implementation'#10 +
    '{$IFNDEF NEXTGEN}'#10 +
    'procedure P;'#10 +
    'begin'#10 +
    'end;'#10 +
    '{$ENDIF}'#10 +
    'end.'#10;

  // Empty implementation section (still adds nkImplementationSec + end.).
  UNIT_EMPTY_IMPL =
    'unit Bare;'#10 +
    'interface'#10 +
    'procedure P;'#10 +
    'implementation'#10 +
    'end.'#10;

  // A program has no interface section - AInterfaceOnly must be IGNORED.
  PROGRAM_SRC =
    'program App;'#10 +
    'uses System.SysUtils;'#10 +
    'var X: Integer;'#10 +
    'begin'#10 +
    '  X := 1;'#10 +
    'end.'#10;

  // A package likewise has no interface section.
  PACKAGE_SRC =
    'package MyPkg;'#10 +
    'requires rtl;'#10 +
    'contains Unit1 in ''Unit1.pas'';'#10 +
    'end.'#10;

var
  LIntf, LFull, LIntf2, LFull2: TPasTree;
  LPre: TPasPreprocessed;
  LD1, LD2: TArray<TPasParseDiag>;
begin
  GSM := TPasSourceManager.Create([]);
  GDefines := TPasDefines.Create(['MSWINDOWS', 'WIN64']);
  GPP := TPasPreprocessor.Create(GSM, GDefines);
  GCounter.Init;
  try
    // ---- Prefix invariant: unit variants ----
    ParseBoth(UNIT_BASIC, LIntf, LFull);
    CheckPrefix('basic unit', LIntf, LFull);

    ParseBoth(UNIT_IFDEF, LIntf, LFull);
    CheckPrefix('$IFDEF spanning sections', LIntf, LFull);

    ParseBoth(UNIT_EMPTY_IMPL, LIntf, LFull);
    CheckPrefix('empty implementation', LIntf, LFull);

    // ---- Determinism: full parse twice == identical (snapshot swap relies
    // on a reparse reproducing the exact same tree) ----
    LPre := GPP.ProcessText('test.pas', UNIT_BASIC);
    LFull := TPasParser.ParseFile(LPre, LD1, False);
    LPre := GPP.ProcessText('test.pas', UNIT_BASIC);
    LFull2 := TPasParser.ParseFile(LPre, LD2, False);
    Ok('full parse is deterministic', TreesIdentical(LFull, LFull2));

    // Interface-only parse twice == identical, too.
    LPre := GPP.ProcessText('test.pas', UNIT_BASIC);
    LIntf := TPasParser.ParseFile(LPre, LD1, True);
    LPre := GPP.ProcessText('test.pas', UNIT_BASIC);
    LIntf2 := TPasParser.ParseFile(LPre, LD2, True);
    Ok('interface-only parse is deterministic', TreesIdentical(LIntf, LIntf2));

    // ---- Flag IGNORED for program/package (no interface section) ----
    LPre := GPP.ProcessText('test.pas', PROGRAM_SRC);
    LIntf := TPasParser.ParseFile(LPre, LD1, True);
    LFull := TPasParser.ParseFile(LPre, LD2, False);
    Ok('program: AInterfaceOnly ignored (identical trees)',
      TreesIdentical(LIntf, LFull));

    LPre := GPP.ProcessText('test.pas', PACKAGE_SRC);
    LIntf := TPasParser.ParseFile(LPre, LD1, True);
    LFull := TPasParser.ParseFile(LPre, LD2, False);
    Ok('package: AInterfaceOnly ignored (identical trees)',
      TreesIdentical(LIntf, LFull));
  finally
    GPP.Free;
    GDefines.Free;
    GSM.Free;
  end;

  if GCounter.Finish('StagedParseSmoke') then
    ExitCode := 1;
end.
