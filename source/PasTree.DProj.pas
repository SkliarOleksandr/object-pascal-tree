unit PasTree.DProj;

{
  PasTree - .dproj (MSBuild project file) reader.

  Encapsulates enough of the MSBuild property/condition model that a real
  Embarcadero-generated .dproj evaluates correctly for a chosen
  (Platform, Config): the compiled source-file list (DCCReference), the unit
  search path, conditional defines, unit aliases, the set of build
  configurations and target platforms, and the resolved main source.

  Scope: a purpose-built reader for this one XML shape, not a general XML
  library. It hand-parses elements/attributes/text, plus comments and CDATA
  (both appear in real files - see the CDATA branch in ParseElement for what
  ignoring them silently costs); namespaced tags are still assumed absent.
  It evaluates each PropertyGroup/element
  `Condition` attribute with a tiny boolean-expression evaluator (parentheses,
  and/or, '$(Name)'==/!='literal') - exactly the grammar Embarcadero's
  generator emits. Walking the file top-to-bottom and letting each matching
  group's `Name;$(Name)` pattern chain onto an accumulator dictionary
  reproduces real MSBuild property inheritance (Base -> Base_<Platform> ->
  Cfg_N -> Cfg_N_<Platform>) without needing a full build-system evaluator.
}

interface

uses
  PasTree.Platforms;

type
  TPasUnitAlias = record
    Alias: string;
    UnitName: string;
  end;

  TPasDProj = class
  private
    FDir: string;
    FProjectName: string;
    FMainSource: string;
    FPlatform: TPasPlatform;
    FConfig: string;
    FConfigurations: TArray<string>;
    FPlatforms: TArray<TPasPlatform>;
    FFiles: TArray<string>;
    FSearchPaths: TArray<string>;
    FDefines: TArray<string>;
    FNamespaces: TArray<string>;
    FUnitAliases: TArray<TPasUnitAlias>;
    function ResolvePath(const ARelOrAbs: string): string;
  public
    { Loads and evaluates APath for the given platform/config; either left
      empty defaults to the project's own fallback (its
      '$(Platform)'=='' / '$(Config)'=='' declarations). Returns False if the
      file is missing, malformed, or has no <Project> root / MainSource. }
    function Load(const APath: string; const APlatformOverride: string = '';
      const AConfigOverride: string = ''): Boolean;

    property Dir: string read FDir;
    property ProjectName: string read FProjectName;
    property MainSource: string read FMainSource;
    property Platform: TPasPlatform read FPlatform;
    property Config: string read FConfig;
    { Build configuration names found (e.g. 'Base', 'Debug', 'Release'). }
    property Configurations: TArray<string> read FConfigurations;
    { Target platforms enabled in the project (BorlandProject/Platforms). }
    property Platforms: TArray<TPasPlatform> read FPlatforms;
    { Absolute paths of every compiled unit: MainSource + DCCReference items,
      de-duplicated, in file order. }
    property Files: TArray<string> read FFiles;
    { Absolute directories from DCC_UnitSearchPath, for the evaluated config. }
    property SearchPaths: TArray<string> read FSearchPaths;
    { DCC_Define entries for the evaluated config. }
    property Defines: TArray<string> read FDefines;
    { DCC_Namespace entries (unit-scope namespaces, dcc -NS), in order. }
    property Namespaces: TArray<string> read FNamespaces;
    { DCC_UnitAlias entries (Alias -> real unit name). }
    property UnitAliases: TArray<TPasUnitAlias> read FUnitAliases;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.Generics.Collections;

{ ==== minimal XML node tree - private, scoped to the .dproj shape ==== }

type
  TXNode = class
  private
    FAttrs: TDictionary<string, string>;
    FChildren: TObjectList<TXNode>;
  public
    Tag: string;
    Text: string;
    constructor Create(const ATag: string);
    destructor Destroy; override;
    function Attr(const AName: string; const ADefault: string = ''): string;
    procedure SetAttr(const AName, AValue: string);
    function FirstChild(const ATag: string): TXNode;
    property Children: TObjectList<TXNode> read FChildren;
  end;

constructor TXNode.Create(const ATag: string);
begin
  inherited Create;
  Tag := ATag;
  FAttrs := TDictionary<string, string>.Create;
  FChildren := TObjectList<TXNode>.Create(True);
end;

destructor TXNode.Destroy;
begin
  FChildren.Free;
  FAttrs.Free;
  inherited;
end;

function TXNode.Attr(const AName, ADefault: string): string;
begin
  if not FAttrs.TryGetValue(LowerCase(AName), Result) then
    Result := ADefault;
end;

procedure TXNode.SetAttr(const AName, AValue: string);
begin
  FAttrs.AddOrSetValue(LowerCase(AName), AValue);
end;

function TXNode.FirstChild(const ATag: string): TXNode;
var
  LChild: TXNode;
begin
  Result := nil;
  for LChild in FChildren do
    if SameText(LChild.Tag, ATag) then
      Exit(LChild);
end;

{ ==== tiny hand-rolled XML scanner (elements/attrs/text only) ==== }

function DecodeXmlEntities(const S: string): string;
begin
  Result := S;
  if Pos('&', Result) = 0 then
    Exit;
  Result := StringReplace(Result, '&lt;', '<', [rfReplaceAll]);
  Result := StringReplace(Result, '&gt;', '>', [rfReplaceAll]);
  Result := StringReplace(Result, '&quot;', '"', [rfReplaceAll]);
  Result := StringReplace(Result, '&apos;', '''', [rfReplaceAll]);
  Result := StringReplace(Result, '&amp;', '&', [rfReplaceAll]); // last: avoid double-decode
end;

type
  TDProjXmlReader = class
  private
    FText: string;
    FPos, FLen: Integer;
    function Cur: Char; inline;
    procedure SkipWs;
    function ReadName: string;
    function ReadQuoted: string;
  public
    constructor Create(const AText: string);
    function ParseDocument: TXNode;
    function ParseElement: TXNode;
  end;

constructor TDProjXmlReader.Create(const AText: string);
begin
  inherited Create;
  FText := AText;
  FPos := 1;
  FLen := Length(AText);
end;

function TDProjXmlReader.Cur: Char;
begin
  if FPos <= FLen then
    Result := FText[FPos]
  else
    Result := #0;
end;

procedure TDProjXmlReader.SkipWs;
begin
  while (FPos <= FLen) and CharInSet(Cur, [' ', #9, #10, #13]) do
    Inc(FPos);
end;

function TDProjXmlReader.ReadName: string;
var
  LStart: Integer;
begin
  LStart := FPos;
  while (FPos <= FLen) and
        CharInSet(FText[FPos], ['A'..'Z', 'a'..'z', '0'..'9', '_', '.', ':', '-']) do
    Inc(FPos);
  Result := Copy(FText, LStart, FPos - LStart);
end;

function TDProjXmlReader.ReadQuoted: string;
var
  LQuote: Char;
  LStart: Integer;
begin
  LQuote := Cur; // ' or "
  Inc(FPos);
  LStart := FPos;
  while (FPos <= FLen) and (Cur <> LQuote) do
    Inc(FPos);
  Result := DecodeXmlEntities(Copy(FText, LStart, FPos - LStart));
  if Cur = LQuote then
    Inc(FPos);
end;

function TDProjXmlReader.ParseDocument: TXNode;
begin
  SkipWs;
  // Optional leading <?xml ... ?> declaration.
  if (Cur = '<') and (FPos + 1 <= FLen) and (FText[FPos + 1] = '?') then
  begin
    Inc(FPos, 2);
    while (FPos <= FLen) and
          not ((Cur = '?') and (FPos + 1 <= FLen) and (FText[FPos + 1] = '>')) do
      Inc(FPos);
    Inc(FPos, 2);
    SkipWs;
  end;
  // Comments before the root element are well-formed XML. Embarcadero never
  // writes one, but a hand-edited .dproj can, and mis-parsing the document
  // silently dropped Load back to the lightweight scan.
  while (Cur = '<') and (FPos + 3 <= FLen) and (FText[FPos + 1] = '!') and
        (FText[FPos + 2] = '-') and (FText[FPos + 3] = '-') do
  begin
    Inc(FPos, 4);
    while (FPos + 2 <= FLen) and
          not ((FText[FPos] = '-') and (FText[FPos + 1] = '-') and
               (FText[FPos + 2] = '>')) do
      Inc(FPos);
    Inc(FPos, 3);
    SkipWs;
  end;
  if Cur <> '<' then
    Exit(nil);
  Result := ParseElement;
end;

// FPos must be at the element's opening '<'.
function TDProjXmlReader.ParseElement: TXNode;
var
  LAttrName, LText: string;
  LSelfClosed: Boolean;
  LStart: Integer;
begin
  Inc(FPos); // '<'
  Result := TXNode.Create(ReadName);
  try
    repeat
      SkipWs;
      if CharInSet(Cur, ['/', '>', #0]) then
        Break;
      LAttrName := ReadName;
      if LAttrName = '' then
        Break; // malformed guard
      SkipWs;
      if Cur = '=' then
      begin
        Inc(FPos);
        SkipWs;
        if CharInSet(Cur, ['''', '"']) then
          Result.SetAttr(LAttrName, ReadQuoted);
      end;
    until False;
    SkipWs;
    LSelfClosed := Cur = '/';
    if LSelfClosed then
      Inc(FPos);
    if Cur = '>' then
      Inc(FPos);
    if LSelfClosed then
      Exit;

    LText := '';
    repeat
      if FPos > FLen then
        Break; // malformed guard
      if Cur = '<' then
      begin
        if (FPos + 1 <= FLen) and (FText[FPos + 1] = '/') then
        begin
          Inc(FPos, 2);
          ReadName; // closing tag name - trust structure, don't verify
          SkipWs;
          if Cur = '>' then
            Inc(FPos);
          Break;
        end
        else if (FPos + 3 <= FLen) and (Copy(FText, FPos, 4) = '<!--') then
        begin
          Inc(FPos, 4);
          while (FPos <= FLen) and (Copy(FText, FPos, 3) <> '-->') do
            Inc(FPos);
          Inc(FPos, 3);
        end
        else if (FPos + 8 <= FLen) and (Copy(FText, FPos, 9) = '<![CDATA[') then
        begin
          // Real .dproj files DO carry CDATA - Embarcadero emits
          // <PreBuildEvent><![CDATA[...]]></PreBuildEvent> for any project
          // with build events. The body is literal TEXT and routinely holds
          // '>' and '"', so falling through to ParseElement (as this used to)
          // consumed up to the first '>' INSIDE the payload and desynchronized
          // the rest of the document. Measured on a real 2500-unit project:
          // the PropertyGroup holding it lost its remaining children - no
          // DCC_UnitSearchPath, hence zero search paths - and every later
          // ItemGroup vanished, hence an empty DCCReference file list. Both
          // failures are silent: Load still returns True.
          // NB the payload joins LText and is entity-decoded with it below.
          // Harmless here (only DCC_* properties are ever read, never build
          // events) but wrong in general, so do not start trusting it.
          Inc(FPos, 9);
          LStart := FPos;
          while (FPos <= FLen) and (Copy(FText, FPos, 3) <> ']]>') do
            Inc(FPos);
          LText := LText + Copy(FText, LStart, FPos - LStart);
          Inc(FPos, 3);
        end
        else
          Result.Children.Add(ParseElement);
      end
      else
      begin
        LStart := FPos;
        while (FPos <= FLen) and (Cur <> '<') do
          Inc(FPos);
        LText := LText + Copy(FText, LStart, FPos - LStart);
      end;
    until False;
    Result.Text := Trim(DecodeXmlEntities(LText));
  except
    Result.Free;
    raise;
  end;
end;

{ ==== MSBuild-lite: macro expansion + condition evaluator ==== }

function ExpandMacros(const S: string; AVars: TDictionary<string, string>): string;
var
  LPos, LNameStart, LClose: Integer;
  LName, LValue: string;
  LSB: TStringBuilder;
begin
  if Pos('$(', S) = 0 then
    Exit(S);
  LSB := TStringBuilder.Create;
  try
    LPos := 1;
    while LPos <= Length(S) do
    begin
      if (S[LPos] = '$') and (LPos < Length(S)) and (S[LPos + 1] = '(') then
      begin
        LNameStart := LPos + 2;
        LClose := LNameStart;
        while (LClose <= Length(S)) and (S[LClose] <> ')') do
          Inc(LClose);
        LName := Copy(S, LNameStart, LClose - LNameStart);
        if not AVars.TryGetValue(LName, LValue) then
          LValue := ''; // MSBuild semantics: an undefined property is empty
        LSB.Append(LValue);
        LPos := LClose + 1;
      end
      else
      begin
        LSB.Append(S[LPos]);
        Inc(LPos);
      end;
    end;
    Result := LSB.ToString;
  finally
    LSB.Free;
  end;
end;

type
  ECondUnsupported = class(Exception);

  TCondTokenKind = (ctEnd, ctLParen, ctRParen, ctAnd, ctOr, ctEq, ctNeq, ctStr);
  TCondToken = record
    Kind: TCondTokenKind;
    Value: string; // ctStr: raw (unexpanded) inner text
  end;

function TokenizeCondition(const ACond: string): TArray<TCondToken>;
var
  LList: TList<TCondToken>;
  LPos, LLen, LStart: Integer;
  LTok: TCondToken;
  LWord: string;
begin
  LList := TList<TCondToken>.Create;
  try
    LPos := 1;
    LLen := Length(ACond);
    while LPos <= LLen do
    begin
      if CharInSet(ACond[LPos], [' ', #9]) then
      begin
        Inc(LPos);
        Continue;
      end;
      case ACond[LPos] of
        '(':
          begin
            LTok.Kind := ctLParen; LTok.Value := '';
            LList.Add(LTok);
            Inc(LPos);
          end;
        ')':
          begin
            LTok.Kind := ctRParen; LTok.Value := '';
            LList.Add(LTok);
            Inc(LPos);
          end;
        '''':
          begin
            Inc(LPos);
            LStart := LPos;
            while (LPos <= LLen) and (ACond[LPos] <> '''') do
              Inc(LPos);
            LTok.Kind := ctStr;
            LTok.Value := Copy(ACond, LStart, LPos - LStart);
            LList.Add(LTok);
            if LPos <= LLen then
              Inc(LPos);
          end;
        '=':
          begin
            if (LPos < LLen) and (ACond[LPos + 1] = '=') then
            begin
              LTok.Kind := ctEq; LTok.Value := '';
              LList.Add(LTok);
              Inc(LPos, 2);
            end
            else
              Inc(LPos); // stray '=' - ignore
          end;
        '!':
          begin
            if (LPos < LLen) and (ACond[LPos + 1] = '=') then
            begin
              LTok.Kind := ctNeq; LTok.Value := '';
              LList.Add(LTok);
              Inc(LPos, 2);
            end
            else
              Inc(LPos);
          end;
      else
        begin
          LStart := LPos;
          while (LPos <= LLen) and CharInSet(ACond[LPos], ['A'..'Z', 'a'..'z']) do
            Inc(LPos);
          LWord := Copy(ACond, LStart, LPos - LStart);
          if LWord = '' then
            Inc(LPos) // unrecognized character - skip defensively
          else if SameText(LWord, 'and') then
          begin
            LTok.Kind := ctAnd; LTok.Value := '';
            LList.Add(LTok);
          end
          else if SameText(LWord, 'or') then
          begin
            LTok.Kind := ctOr; LTok.Value := '';
            LList.Add(LTok);
          end
          else
            raise ECondUnsupported.Create('unsupported condition token: ' + LWord);
        end;
      end;
    end;
    LTok.Kind := ctEnd; LTok.Value := '';
    LList.Add(LTok);
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

// Recursive-descent over the token array: Or -> And -> Atom -> Comparison.
// Grammar matches exactly what Embarcadero's generated Condition attributes
// use: parens, and/or, '$(Name)' compared with =='literal' / !='literal'.
type
  TCondEvaluator = class
  private
    FTokens: TArray<TCondToken>;
    FPos: Integer;
    FVars: TDictionary<string, string>;
    function Cur: TCondToken;
    procedure NextTok;
    function ParseOperand: string;
    function ParseComparison: Boolean;
    function ParseAtom: Boolean;
    function ParseAndExpr: Boolean;
    function ParseOrExpr: Boolean;
  public
    constructor Create(const ATokens: TArray<TCondToken>;
      AVars: TDictionary<string, string>);
    function Evaluate: Boolean;
  end;

constructor TCondEvaluator.Create(const ATokens: TArray<TCondToken>;
  AVars: TDictionary<string, string>);
begin
  inherited Create;
  FTokens := ATokens;
  FPos := 0;
  FVars := AVars;
end;

function TCondEvaluator.Cur: TCondToken;
begin
  Result := FTokens[FPos];
end;

procedure TCondEvaluator.NextTok;
begin
  if FPos < High(FTokens) then
    Inc(FPos);
end;

function TCondEvaluator.ParseOperand: string;
begin
  if Cur.Kind <> ctStr then
    raise ECondUnsupported.Create('expected a quoted operand');
  Result := ExpandMacros(Cur.Value, FVars);
  NextTok;
end;

function TCondEvaluator.ParseComparison: Boolean;
var
  LLeft, LRight: string;
  LIsEq: Boolean;
begin
  LLeft := ParseOperand;
  if Cur.Kind = ctEq then
    LIsEq := True
  else if Cur.Kind = ctNeq then
    LIsEq := False
  else
    raise ECondUnsupported.Create('expected == or !=');
  NextTok;
  LRight := ParseOperand;
  if LIsEq then
    Result := SameText(LLeft, LRight)
  else
    Result := not SameText(LLeft, LRight);
end;

function TCondEvaluator.ParseAtom: Boolean;
begin
  if Cur.Kind = ctLParen then
  begin
    NextTok;
    Result := ParseOrExpr;
    if Cur.Kind <> ctRParen then
      raise ECondUnsupported.Create('expected )');
    NextTok;
  end
  else
    Result := ParseComparison;
end;

function TCondEvaluator.ParseAndExpr: Boolean;
begin
  Result := ParseAtom;
  while Cur.Kind = ctAnd do
  begin
    NextTok;
    Result := ParseAtom and Result;
  end;
end;

function TCondEvaluator.ParseOrExpr: Boolean;
begin
  Result := ParseAndExpr;
  while Cur.Kind = ctOr do
  begin
    NextTok;
    Result := ParseAndExpr or Result;
  end;
end;

function TCondEvaluator.Evaluate: Boolean;
begin
  Result := ParseOrExpr;
end;

// An empty condition is always true; a condition we can't parse fails OPEN
// (defaults to true) rather than silently dropping data the caller asked for.
function EvalCondition(const ACond: string; AVars: TDictionary<string, string>): Boolean;
var
  LEval: TCondEvaluator;
begin
  if Trim(ACond) = '' then
    Exit(True);
  try
    LEval := TCondEvaluator.Create(TokenizeCondition(ACond), AVars);
    try
      Result := LEval.Evaluate;
    finally
      LEval.Free;
    end;
  except
    on Exception do
      Result := True;
  end;
end;

{ TPasDProj }

function TPasDProj.ResolvePath(const ARelOrAbs: string): string;
begin
  Result := ARelOrAbs;
  if Result = '' then
    Exit;
  if not TPath.IsPathRooted(Result) then
    Result := TPath.Combine(FDir, Result);
  try
    Result := TPath.GetFullPath(Result);
  except
    // a stray unresolved macro or malformed segment - keep the combined form
  end;
end;

function TPasDProj.Load(const APath: string; const APlatformOverride: string;
  const AConfigOverride: string): Boolean;
var
  LText: string;
  LReader: TDProjXmlReader;
  LRoot, LGroup, LChild, LItem, LBP, LPlats, LP: TXNode;
  LVars: TDictionary<string, string>;
  LRawFiles, LConfigs: TList<string>;
  LPlatformsFound: TList<TPasPlatform>;
  LName, LVal: string;
  LPlat: TPasPlatform;

  procedure SeedEnv(const AName: string);
  var
    LEnv: string;
  begin
    LEnv := GetEnvironmentVariable(AName);
    if LEnv <> '' then
      LVars.AddOrSetValue(AName, LEnv);
  end;

begin
  Result := False;
  FDir := ''; FProjectName := ''; FMainSource := ''; FConfig := '';
  FPlatform := pfWin32;
  FConfigurations := nil; FPlatforms := nil; FFiles := nil;
  FSearchPaths := nil; FDefines := nil; FNamespaces := nil;
  FUnitAliases := nil;

  if not TFile.Exists(APath) then
    Exit;
  FDir := TPath.GetDirectoryName(TPath.GetFullPath(APath));
  FProjectName := TPath.GetFileNameWithoutExtension(APath);

  try
    LText := TFile.ReadAllText(APath);
  except
    Exit(False);
  end;

  LReader := TDProjXmlReader.Create(LText);
  try
    LRoot := LReader.ParseDocument;
  except
    LReader.Free;
    Exit(False);
  end;
  LReader.Free;

  if not Assigned(LRoot) or not SameText(LRoot.Tag, 'Project') then
  begin
    LRoot.Free;
    Exit(False);
  end;

  try
    LVars := TDictionary<string, string>.Create;
    LRawFiles := TList<string>.Create;
    LConfigs := TList<string>.Create;
    LPlatformsFound := TList<TPasPlatform>.Create;
    try
      SeedEnv('BDS'); SeedEnv('BDSLIB'); SeedEnv('BDSINCLUDE');
      SeedEnv('BDSCOMMONDIR'); SeedEnv('BDSBIN'); SeedEnv('BDSPROJECTSDIR');
      SeedEnv('BDSAPPDATABASEDIR'); SeedEnv('PRODUCTVERSION');
      if APlatformOverride <> '' then
        LVars.AddOrSetValue('Platform', APlatformOverride);
      if AConfigOverride <> '' then
        LVars.AddOrSetValue('Config', AConfigOverride);

      // Single forward pass mirrors real MSBuild evaluation: each matching
      // PropertyGroup's `Name;$(Name)` pattern chains onto whatever the prior
      // matching groups already accumulated in LVars.
      for LGroup in LRoot.Children do
      begin
        if SameText(LGroup.Tag, 'PropertyGroup') then
        begin
          if EvalCondition(LGroup.Attr('Condition'), LVars) then
            for LChild in LGroup.Children do
              if EvalCondition(LChild.Attr('Condition'), LVars) then
                LVars.AddOrSetValue(LChild.Tag, ExpandMacros(LChild.Text, LVars));
        end
        else if SameText(LGroup.Tag, 'ItemGroup') then
        begin
          if EvalCondition(LGroup.Attr('Condition'), LVars) then
            for LItem in LGroup.Children do
            begin
              if not EvalCondition(LItem.Attr('Condition'), LVars) then
                Continue;
              if SameText(LItem.Tag, 'DCCReference') then
                LRawFiles.Add(ExpandMacros(LItem.Attr('Include'), LVars))
              else if SameText(LItem.Tag, 'BuildConfiguration') then
              begin
                LName := LItem.Attr('Include');
                if (LName <> '') and not LConfigs.Contains(LName) then
                  LConfigs.Add(LName);
              end;
              // DelphiCompile/DCCResource/etc: not needed (MainSource comes
              // from the <MainSource> property itself).
            end;
        end
        else if SameText(LGroup.Tag, 'ProjectExtensions') then
        begin
          LBP := LGroup.FirstChild('BorlandProject');
          if Assigned(LBP) then
          begin
            LPlats := LBP.FirstChild('Platforms');
            if Assigned(LPlats) then
              for LP in LPlats.Children do
                if SameText(LP.Tag, 'Platform') and SameText(Trim(LP.Text), 'True') then
                  if TryParsePlatformName(LP.Attr('value'), LPlat) then
                    if not LPlatformsFound.Contains(LPlat) then
                      LPlatformsFound.Add(LPlat);
          end;
        end;
        // <Import>: build-system plumbing, not needed here.
      end;

      // ---- materialize results from the accumulated vars ----
      if not (LVars.TryGetValue('Platform', LVal) and
              TryParsePlatformName(LVal, FPlatform)) then
        FPlatform := pfWin32;
      LVars.TryGetValue('Config', FConfig);

      if LVars.TryGetValue('MainSource', LVal) and (LVal <> '') then
        FMainSource := ResolvePath(LVal);

      // Search paths FIRST: the file list below needs them (see there).
      if LVars.TryGetValue('DCC_UnitSearchPath', LVal) then
      begin
        var LSP := TList<string>.Create;
        try
          for LName in LVal.Split([';']) do
            if Trim(LName) <> '' then
            begin
              var LResolved := ResolvePath(Trim(LName));
              if not LSP.Contains(LResolved) then
                LSP.Add(LResolved);
            end;
          FSearchPaths := LSP.ToArray;
        finally
          LSP.Free;
        end;
      end;

      { A DCCReference is not always relative to the project directory. A
        package whose sources live one level up lists them by BARE NAME -
        `<DCCReference Include="Alcinoe.Cipher.pas"/>` with
        `DCC_UnitSearchPath=..\` - and the IDE finds them on the search path.
        Combining with the project dir alone yielded a list of paths that do
        not exist, so the host's file tree showed only the two entries that
        happened to sit beside the .dproj, and every unit in the package was
        classified as a LIBRARY unit rather than one of the project's own. }
      var LAllFiles := TList<string>.Create;
      try
        if FMainSource <> '' then
          LAllFiles.Add(FMainSource);
        for LName in LRawFiles do
        begin
          LVal := ResolvePath(LName);
          if (LVal <> '') and not TFile.Exists(LVal) and
             not TPath.IsPathRooted(LName) then
            for var LDir in FSearchPaths do
            begin
              var LTry := TPath.Combine(LDir, LName);
              if TFile.Exists(LTry) then
              begin
                LVal := LTry;
                Break;
              end;
            end;
          if (LVal <> '') and not LAllFiles.Contains(LVal) then
            LAllFiles.Add(LVal);
        end;
        FFiles := LAllFiles.ToArray;
      finally
        LAllFiles.Free;
      end;

      if LVars.TryGetValue('DCC_Define', LVal) then
      begin
        var LDefs := TList<string>.Create;
        try
          for LName in LVal.Split([';']) do
          begin
            var LDef := Trim(LName);
            if (LDef <> '') and (Pos('$(', LDef) = 0) and not LDefs.Contains(LDef) then
              LDefs.Add(LDef);
          end;
          FDefines := LDefs.ToArray;
        finally
          LDefs.Free;
        end;
      end;

      if LVars.TryGetValue('DCC_Namespace', LVal) then
      begin
        var LNS := TList<string>.Create;
        try
          for LName in LVal.Split([';']) do
          begin
            var LOne := Trim(LName);
            // Any UNEXPANDED macro is skipped. (The '$(DCC_Namespace)'
            // self-reference this once described cannot actually reach here:
            // ExpandMacros already substitutes '' for an undefined property
            // at store time. The guard is kept as a cheap invariant.)
            if (LOne <> '') and (Pos('$(', LOne) = 0) and
               not LNS.Contains(LOne) then
              LNS.Add(LOne);
          end;
          FNamespaces := LNS.ToArray;
        finally
          LNS.Free;
        end;
      end;

      if LVars.TryGetValue('DCC_UnitAlias', LVal) then
      begin
        var LAliases := TList<TPasUnitAlias>.Create;
        try
          for LName in LVal.Split([';']) do
          begin
            var LEq := Pos('=', LName);
            if LEq > 1 then
            begin
              var LA: TPasUnitAlias;
              LA.Alias := Trim(Copy(LName, 1, LEq - 1));
              LA.UnitName := Trim(Copy(LName, LEq + 1, MaxInt));
              if (LA.Alias <> '') and (LA.UnitName <> '') then
                LAliases.Add(LA);
            end;
          end;
          FUnitAliases := LAliases.ToArray;
        finally
          LAliases.Free;
        end;
      end;

      FConfigurations := LConfigs.ToArray;
      FPlatforms := LPlatformsFound.ToArray;
      Result := FMainSource <> '';
    finally
      LPlatformsFound.Free;
      LConfigs.Free;
      LRawFiles.Free;
      LVars.Free;
    end;
  finally
    LRoot.Free;
  end;
end;

end.
