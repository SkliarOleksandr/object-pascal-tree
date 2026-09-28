unit PasTree.Sema.Dfm;

{
  PasTree semantics - FORM FILES bound to the symbols they name.

  PasTree.Dfm reads a .dfm/.fmx into identifier positions; this unit says
  which symbol each of them IS, so a reference search can list them and a
  rename can rewrite them. A form file binds by NAME at run time only, so a
  rename that skipped it compiles and then fails when the form is created: a
  handler the reader cannot find is EReadError (TReader.FindMethod ->
  PropValueError), a component whose field was renamed stays nil without a
  word (FieldAddress finds nothing) and fails at its first use.

  THE RULES ARE TReader'S (System.Classes), not a guess at them:

  - `object/inherited X: TC` - X is the published FIELD X of the LOOKUP ROOT's
    class (FieldAddress), searched through its ancestors; TC is that field's
    type (GetFieldClass looks the name up among the published fields'
    classes). The root object's class is the class of that name declared in
    the unit the form file belongs to.
  - The lookup root is the form - except inside `inline F: TFrame1`, where it
    is the frame (csInline -> FLookupRoot := the frame): the frame's children
    are fields of TFrame1.
  - `OnClick = M` - M is a published METHOD of the ROOT's class
    (Root.MethodAddress), inline frame or not: a handler set on a frame's
    button in the HOST form is a method of the host.
  - The Root is the INSTANCE being created, and a descendant's instance
    reads every ancestor's form file too (InitInheritedComponent): a line
    of an ancestor's form binds, for a descendant that redeclares M, the
    descendant's M (fsvAncestor). Such a line binds the ancestor's M for
    the ancestor's own forms at the same time, so a rename of either
    cannot rewrite it and is refused.
  - `FocusControl = X` - a component owned by the lookup root, i.e. its field.
  - `P = A.B.C` - A is a component of the lookup root, else the Name of
    another module's ROOT (a data module referenced from a form - the global
    fixups); B, C are fields of the class the previous segment has.
  - A bare identifier value is either a handler or a component, and nothing
    in the syntax says which - the property's type does, and property types
    are not resolved here yet (tier 2). So: a method of the root wins in a
    property named On*, a component of the lookup root elsewhere; a value
    that is neither (an enum value, `True`, `clBtnFace`) binds to nothing.

  PUBLISHED ONLY, as FieldAddress/MethodAddress find only those. A form class
  descends from TPersistent, which compiles with $M+, so its default section
  IS published: svDefault counts as published here.

  WHAT A COMPONENT'S RENAME CARRIES ALONG (CarriedBy) is what the form
  designer does when a component's Name changes, so that a rename made here
  and one made in the IDE's designer agree: the handlers NAMED AFTER the
  component on its own events (Button1Click on Button1's OnClick) are
  renamed with it, and a caption that reads its old name follows it
  (TControl.SetName's csSetCaption rule, TContainedAction's without clients,
  TCustomLabeledEdit's EditLabel). A handler rename that would be refused on
  its own is left out - a handler is bound by name wherever it is linked, so
  not renaming it never breaks anything.

  HOW A SITE IS REACHED (TPasFormSiteVia) is recorded for the same host: the
  designer propagates a rename to a form's own components, to its loaded
  descendants and across modules, but whether it follows into an inline
  frame's block was never measured.

  WHAT IS NOT BOUND YET, AND IS REFUSED RATHER THAN SKIPPED. Property NAMES
  (`Caption = ...`, `Font.Name`) and enum VALUES bind through a property's
  type, which this unit does not resolve yet. Find References simply lists
  nothing for them; a RENAME of a published property or of an enum value
  that a form file may spell is refused whole - a partial rename would be
  exactly the silent break this unit exists to prevent.
}

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  PasTree.Sema.Model,
  PasTree.Sema.Project,
  PasTree.Dfm;

type
  // What a form-file site IS, for a host that applies form edits through a
  // form designer rather than as text. fskNone is a Pascal source edit.
  TPasFormSiteKind = (
    fskNone,
    fskComponent,     // `object X: TC` - the component's name
    fskClass,         // `object X: TC` - the class
    fskHandler,       // `OnClick = X`
    fskComponentRef,  // `FocusControl = X`, `DataSource = DM.X`
    fskCaption);      // `Caption = 'X'` - a renamed component's caption that
                      // read its name, and follows it (CarriedBy); never a
                      // reference, only ever part of a rename

  { HOW a site reaches its symbol - which matters to a host that applies form
    edits through a live designer, because the designer propagates a rename
    differently along each path (measured in RAD Studio 13, 2026-09-27). }
  TPasFormSiteVia = (
    fsvOwn,     // the form's own lookup root: its components, its handlers
    fsvInline,  // inside an inline frame's block, or through a component
                // path (`Frame1.Edit1`)
    fsvModule,  // through another module's root Name (`DataModule1.Table1`)
    fsvAncestor); // an ANCESTOR's form file binding the handler by name: a
                // descendant's instance reads it too, and its MethodAddress
                // finds the descendant's own method of that name - a line
                // that also binds the ancestor's method for the ancestor's
                // own forms, so a rename can never rewrite it

  TPasFormSite = record
    FilePath: string;
    Line, Col: Integer;     // 1-based; Col in characters of the line
    Len: Integer;           // characters
    OldText: string;
    Snippet: string;        // the line as written, trailing blanks trimmed
    HiFrom, HiTo: Integer;  // 0-based offsets of the name in Snippet
    Offset, ByteLen: Integer; // the name's bytes in the file
    Kind: TPasFormSiteKind;
    Via: TPasFormSiteVia;
    // The component the site belongs to - the object whose header it is, or
    // whose property holds it - by Name; '' for the form (root) itself.
    ObjectName: string;
    ObjIndex: Integer;      // that object, in the form file's TPasDfmDoc
    // The property the site is the value of, as written (`OnClick`,
    // `FocusControl`, `Caption`); '' for an object header.
    PropName: string;
    IsBinary: Boolean;      // positions are the converted text's
    IsUtf8: Boolean;        // the file can hold a non-ASCII name
  end;

  { Where a symbol lives in the project's form files, for a host whose forms
    a live designer may hold: what it is there (fskComponent for a published
    field of a form class, fskHandler for a published method, fskClass for a
    form's own class, fskNone for anything else), the class that declares it
    (a class: itself), and the form file whose ROOT is that class - the one
    whose designer owns the symbol ('' when that class has none: a base class
    declared in code only). }
  TPasFormRole = record
    Kind: TPasFormSiteKind;
    OwnerClass: string;
    FormFile: string;
  end;

  // A handler a component's rename carries along (CarriedBy).
  TPasCarriedHandler = record
    TMid, TSym: Integer;
    NewName: string;
  end;

  // One object of a form file, bound (DescribeForm).
  TPasFormObject = record
    Obj: Integer;              // its index in the document's Objects
    Parent: Integer;           // the enclosing object's Obj; -1 for the root
    Kind: TPasDfmObjectKind;
    Name, ClassName: string;   // as written; Name '' for an unnamed object
    Line: Integer;             // of its header, 1-based
    ClassX: TSemaXType;        // the class it is (ObjClassOf); XNil when unknown
    // The published field its name fills - of the lookup root's class, the
    // nearest inline frame's inside one (FieldAddress). NIL_SYM for the root,
    // an unnamed object and a component no field is declared for.
    FieldMid, FieldSym: Integer;
  end;

  { An identifier VALUE of a form file that names a symbol - a handler
    (`OnClick = M`), a component (`FocusControl = X`, `DataSource = DM.X`) -
    or one that should and names nothing: an event property whose value no
    published method of the root has (the form fails to load), a component
    path whose head or segment no field answers. A value that is none of
    these (`Align = alClient`, `Visible = True`) is not one. }
  TPasFormBinding = record
    Obj: Integer;              // the object whose property it is
    PropName: string;          // `OnClick`, `FocusControl`, `Items.Action`
    Value: string;             // as written: `btnSaveClick`, `dmData.pmActions`
    Line: Integer;             // 1-based
    IsMethod: Boolean;         // a handler (or an event whose method is missing)
    // The symbol it binds; TSym = NIL_SYM when it binds nothing.
    TMid, TSym: Integer;
    Via: TPasFormSiteVia;
  end;

  // A form file as TReader would bind it (DescribeForm).
  TPasFormInfo = record
    FilePath: string;
    // '' when it was read whole; else why not, and what was read before.
    Error: string;
    IsBinary: Boolean;         // lines are of the converted text
    RootClass: TSemaXType;     // the class of the unit the file belongs to
    Objects: TArray<TPasFormObject>;     // in file order, the root first
    Bindings: TArray<TPasFormBinding>;   // in file order
  end;

  TPasFormBinder = class
  private type
    TFormEntry = class
      Mid: Integer;         // the unit the form file belongs to
      Path: string;
      Doc: IPasDfmDoc;      // nil until loaded; replaced when the file changes
      RootDone: Boolean;
      RootClass: TSemaXType;
      ObjDone: TArray<Boolean>;
      ObjClass: TArray<TSemaXType>;
    end;
    TSymShape = (ssNone, ssField, ssMethod, ssClass, ssProperty, ssEnumValue);
  private
    FProj: TPasSemaProject;
    FLibraryPaths: TArray<string>;
    FForms: TObjectList<TFormEntry>;
    FListed: Boolean;
    FRootNames: TDictionary<string, TArray<Integer>>;
    FRootNamesBuilt: Boolean;
    function IsLibrary(const APath: string): Boolean;
    procedure EnsureListed;
    procedure Refresh;
    function DocOf(AEntry: TFormEntry): TPasDfmDoc;
    procedure EnsureRootNames;
    function TypeInUnit(AMid: Integer; const ANameLower: string): TSemaXType;
    function RootClassOf(AEntry: TFormEntry): TSemaXType;
    function HeaderLookupRoot(ADoc: TPasDfmDoc; AObj: Integer): Integer;
    function InnerLookupRoot(ADoc: TPasDfmDoc; AObj: Integer): Integer;
    function ObjClassOf(AEntry: TFormEntry; AObj: Integer): TSemaXType;
    function FieldIn(AMid: Integer; const AClass: TSemaXType;
      const ANameLower: string; out AFMid, AFSym: Integer): Boolean;
    function MethodIn(AMid: Integer; const AClass: TSemaXType;
      const ANameLower: string; out AFMid, AFSym: Integer): Boolean;
    function FieldClass(AFMid, AFSym: Integer): TSemaXType;
    function SameType(const A, B: TSemaXType): Boolean;
    function ShapeOf(ATMid, ASym: Integer; out AOwner: TSemaXType): TSymShape;
    function IsEventProp(ADoc: TPasDfmDoc; AProp: Integer): Boolean;
    function ValueTarget(AEntry: TFormEntry; AIdent: Integer;
      out ATMid, ATSym: Integer; out AIsMethod: Boolean): Boolean; overload;
    function ValueTarget(AEntry: TFormEntry; AIdent: Integer;
      out ATMid, ATSym: Integer; out AIsMethod: Boolean;
      out AVia: TPasFormSiteVia): Boolean; overload;
    function HeaderVia(ADoc: TPasDfmDoc; AObj: Integer): TPasFormSiteVia;
    function SiteOf(AEntry: TFormEntry; AIdent: Integer;
      AKind: TPasFormSiteKind; AVia: TPasFormSiteVia): TPasFormSite;
    function EntryOf(const APath: string): TFormEntry;
  public
    { ALibraryPaths as TPasNavigator keeps them (full, lower case, trailing
      delimiter): a form file under one of them is never read - a library's
      own forms cannot name a project's symbols, and a rename could not
      write them anyway. }
    constructor Create(AProject: TPasSemaProject;
      const ALibraryPaths: TArray<string>);
    destructor Destroy; override;
    { Every place a form file of the project names (ATMid, ASym), sorted by
      file, line, column. Empty for a symbol no form file can name.

      ARename asks for the answer a RENAME needs, which is stricter: AError
      is set (and nothing returned) when a form file that may spell the
      name cannot be read or bound, or names it in a way this unit does not
      bind yet (a published property, an enum value - see the unit header).
      A reference search passes False and gets what could be bound. }
    function SitesOf(ATMid, ASym: Integer; ARename: Boolean;
      out AError: string): TArray<TPasFormSite>;
    { The form-file refusals of a rename to ANewName, '' when there are none:
      a binary form file among ASites (positions of converted text cannot be
      edited in place), a non-ASCII name for a file without a UTF-8 BOM, and
      a NAME COLLISION for a component or a handler - a member of that name
      already reachable from a form class that streams it, or a component of
      that name in its form file. A duplicate component name is a form that
      no longer loads, and a handler renamed onto an existing method rebinds
      silently; the compiler catches neither when the other name lives in a
      descendant. Meant to follow SitesOf, whose read of the files it reuses. }
    function RenameRefusal(ATMid, ASym: Integer; const ANewName: string;
      const ASites: TArray<TPasFormSite>): string;
    { What a COMPONENT's rename carries along - what the form designer does
      when a component's Name changes (measured in RAD Studio 13,
      2026-09-27; the rules are the IDE's and the RTL's, not a guess):

      - AHandlers: every handler NAMED AFTER it - on one of the component's
        own events, spelled its name + the event's name without "On"
        (Button1Click on Button1's OnClick, Edit1Change on OnChange; not
        Edit1Whatever on OnEnter, not SharedExit). Each such method once,
        with its new name: ANewName + the same suffix. The designer renames
        exactly those, header and implementation, and nothing else.
      - ACaptions: a `Caption` or `Text` of the component that reads EXACTLY
        its old name (TControl.SetName with csSetCaption, TTextControl in
        FMX), except an action's while a form file links it through an
        `Action` property (TContainedAction.SetName: not with clients), and
        a TLabeledEdit's `EditLabel.Caption` in any case (its own SetName,
        SameText). Sites of kind fskCaption, the text between the quotes.

      Only the component's own `object X` / `inherited X` blocks are looked
      in - ASites, as SitesOf returned them. Empty for anything that is not
      a component with sites. }
    procedure CarriedBy(ATMid, ASym: Integer; const ANewName: string;
      const ASites: TArray<TPasFormSite>;
      out AHandlers: TArray<TPasCarriedHandler>;
      out ACaptions: TArray<TPasFormSite>);
    { See TPasFormRole. }
    function RoleOf(ATMid, ASym: Integer): TPasFormRole;
    { One form file of the project, whole: every object with its class and
      the published field it fills, and every value that names a symbol,
      bound as SitesOf binds them - what the Object Inspector shows for the
      form, without its plain properties. An inherited form's objects are
      its own file's only (`inherited X` reopens the ancestor's X); the
      ancestor form is RoleOf(the ancestor class).FormFile. False, with
      AInfo.Error set, for a path that is no form file of the project. }
    function DescribeForm(const APath: string; out AInfo: TPasFormInfo): Boolean;
  end;

implementation

uses
  System.StrUtils,
  System.IOUtils,
  System.Generics.Defaults;

{ TPasFormBinder }

constructor TPasFormBinder.Create(AProject: TPasSemaProject;
  const ALibraryPaths: TArray<string>);
begin
  inherited Create;
  FProj := AProject;
  FLibraryPaths := ALibraryPaths;
  FForms := TObjectList<TFormEntry>.Create(True);
  FRootNames := TDictionary<string, TArray<Integer>>.Create;
end;

destructor TPasFormBinder.Destroy;
begin
  FRootNames.Free;
  FForms.Free;
  inherited;
end;

function TPasFormBinder.IsLibrary(const APath: string): Boolean;
var
  LFull, LDir: string;
begin
  Result := False;
  if Length(FLibraryPaths) = 0 then
    Exit;
  LFull := LowerCase(TPath.GetFullPath(APath));
  for LDir in FLibraryPaths do
    if LFull.StartsWith(LDir) then
      Exit(True);
end;

{ The project's form files: each analyzed unit's `.dfm` / `.fmx` sibling.
  Found by listing each unit DIRECTORY once rather than probing two names per
  unit - a large project has a few hundred directories and a few thousand
  units. }
procedure TPasFormBinder.EnsureListed;
var
  LDirs: TDictionary<string, TDictionary<string, string>>;
  LMid: Integer;
  LUnit, LDir, LKey, LFound, LFile: string;
  LNames: TDictionary<string, string>;
  LEntry: TFormEntry;
  LExt: string;
begin
  if FListed then
    Exit;
  FListed := True;
  LDirs := TObjectDictionary<string, TDictionary<string, string>>.Create(
    [doOwnsValues]);
  try
    for LMid := 0 to FProj.ModelCount - 1 do
    begin
      LUnit := FProj.ModelFile(LMid);
      if (LUnit = '') or IsLibrary(LUnit) then
        Continue;
      LDir := LowerCase(ExtractFileDir(LUnit));
      if not LDirs.TryGetValue(LDir, LNames) then
      begin
        LNames := TDictionary<string, string>.Create;
        LDirs.Add(LDir, LNames);
        try
          if TDirectory.Exists(ExtractFileDir(LUnit)) then
            for LFile in TDirectory.GetFiles(ExtractFileDir(LUnit)) do
            begin
              LExt := LowerCase(ExtractFileExt(LFile));
              if (LExt = '.dfm') or (LExt = '.fmx') then
                LNames.AddOrSetValue(LowerCase(ExtractFileName(LFile)), LFile);
            end;
        except
          // An unlistable directory has no form files we could read anyway.
        end;
      end;
      LKey := LowerCase(ChangeFileExt(ExtractFileName(LUnit), ''));
      if LNames.TryGetValue(LKey + '.dfm', LFound) or
         LNames.TryGetValue(LKey + '.fmx', LFound) then
      begin
        LEntry := TFormEntry.Create;
        LEntry.Mid := LMid;
        LEntry.Path := LFound;
        LEntry.RootClass := XNil;
        FForms.Add(LEntry);
      end;
    end;
  finally
    LDirs.Free;
  end;
end;

{ Every entry's doc as the file NOW reads - once per query, at its start. The
  cache revalidates by size and time, and a changed file resets everything
  resolved against the old one. The binder lives as long as the ANALYSIS
  does, and a form saved in a designer changes no Pascal source, so the docs
  cannot be loaded once and kept. }
procedure TPasFormBinder.Refresh;
var
  LEntry: TFormEntry;
  LDoc: IPasDfmDoc;
begin
  EnsureListed;
  for LEntry in FForms do
  begin
    LDoc := PasDfmLoad(LEntry.Path);
    if LDoc = nil then
      LDoc := PasDfmParse(LEntry.Path, nil);   // vanished: an empty, failed doc
    if (LEntry.Doc = nil) or (LEntry.Doc.Doc <> LDoc.Doc) then
    begin
      LEntry.Doc := LDoc;
      LEntry.RootDone := False;
      LEntry.RootClass := XNil;
      LEntry.ObjDone := nil;
      SetLength(LEntry.ObjDone, Length(LDoc.Doc.Objects));
      SetLength(LEntry.ObjClass, Length(LDoc.Doc.Objects));
      FRootNamesBuilt := False;
    end;
  end;
end;

// The entry's doc as of the last Refresh.
function TPasFormBinder.DocOf(AEntry: TFormEntry): TPasDfmDoc;
begin
  Result := AEntry.Doc.Doc;
end;

// Root Name (lower case) -> the forms whose root is called that: how
// `DM.Table1` in one form file finds the data module it means.
procedure TPasFormBinder.EnsureRootNames;
var
  LIdx: Integer;
  LName: string;
  LList: TArray<Integer>;
begin
  if FRootNamesBuilt then
    Exit;
  FRootNames.Clear;
  for LIdx := 0 to FForms.Count - 1 do
  begin
    LName := LowerCase(DocOf(FForms[LIdx]).RootName);
    if LName = '' then
      Continue;
    if not FRootNames.TryGetValue(LName, LList) then
      LList := nil;
    FRootNames.AddOrSetValue(LName, LList + [LIdx]);
  end;
  FRootNamesBuilt := True;
end;

// A TYPE named ANameLower declared in unit AMid itself - interface first,
// then implementation - else reachable from it (its uses, then System).
function TPasFormBinder.TypeInUnit(AMid: Integer;
  const ANameLower: string): TSemaXType;
var
  LM: TPasSemaModel;
  LSym, LScope, LRMid, LRSym: Integer;
begin
  Result := XNil;
  if ANameLower = '' then
    Exit;
  LM := FProj.Model(AMid);
  LSym := NIL_SYM;
  if LM.InterfaceScope <> NIL_SCOPE then
    LSym := LM.FindLocal(LM.InterfaceScope, ANameLower);
  if (LSym = NIL_SYM) or (LM.Symbols[LSym].Kind <> skType) then
  begin
    LSym := NIL_SYM;
    for LScope := 0 to LM.Scopes.Count - 1 do
      if LM.Scopes[LScope].Kind = sckImplementation then
      begin
        LSym := LM.FindLocal(LScope, ANameLower);
        Break;
      end;
  end;
  if (LSym <> NIL_SYM) and (LM.Symbols[LSym].Kind = skType) then
    Exit(FProj.CanonTypeX(XPlain(AMid, LSym)));
  if FProj.ResolveRealDecl(AMid, ANameLower, LRMid, LRSym) and
     (FProj.Model(LRMid).Symbols[LRSym].Kind = skType) then
    Result := FProj.CanonTypeX(XPlain(LRMid, LRSym));
end;

function TPasFormBinder.RootClassOf(AEntry: TFormEntry): TSemaXType;
var
  LDoc: TPasDfmDoc;
begin
  LDoc := DocOf(AEntry);
  if not AEntry.RootDone then
  begin
    AEntry.RootDone := True;
    AEntry.RootClass := XNil;
    if Length(LDoc.Objects) > 0 then
      AEntry.RootClass := TypeInUnit(AEntry.Mid,
        LowerCase(LDoc.RootClassName));
  end;
  Result := AEntry.RootClass;
end;

// The object whose class a component's NAME is looked up in: the nearest
// enclosing inline frame, else the root.
function TPasFormBinder.HeaderLookupRoot(ADoc: TPasDfmDoc;
  AObj: Integer): Integer;
begin
  Result := ADoc.Objects[AObj].Parent;
  while (Result > 0) and (ADoc.Objects[Result].Kind <> dokInline) do
    Result := ADoc.Objects[Result].Parent;
  if Result < 0 then
    Result := 0;
end;

// The lookup root in effect INSIDE the object's block - itself for an inline
// frame (its properties' component references are the frame's).
function TPasFormBinder.InnerLookupRoot(ADoc: TPasDfmDoc;
  AObj: Integer): Integer;
begin
  if AObj <= 0 then
    Exit(0);
  if ADoc.Objects[AObj].Kind = dokInline then
    Exit(AObj);
  Result := HeaderLookupRoot(ADoc, AObj);
end;

{ An object's class: the root's is the unit's class; any other's is the type
  of the field its name binds to, when that type is the class the header
  spells (GetFieldClass finds classes by NAME among the published fields'),
  else the class that name resolves to in the unit. }
function TPasFormBinder.ObjClassOf(AEntry: TFormEntry;
  AObj: Integer): TSemaXType;
var
  LDoc: TPasDfmDoc;
  LOwner, LFieldType: TSemaXType;
  LFMid, LFSym: Integer;
  LName, LClassName: string;
begin
  LDoc := DocOf(AEntry);
  if AObj = 0 then
    Exit(RootClassOf(AEntry));
  if (AObj < 0) or (AObj > High(LDoc.Objects)) then
    Exit(XNil);
  if AEntry.ObjDone[AObj] then
    Exit(AEntry.ObjClass[AObj]);
  AEntry.ObjDone[AObj] := True;
  AEntry.ObjClass[AObj] := XNil;
  LClassName := LDoc.ObjectClassName(AObj);
  LName := LowerCase(LDoc.ObjectName(AObj));
  LFieldType := XNil;
  LOwner := ObjClassOf(AEntry, HeaderLookupRoot(LDoc, AObj));
  if (LName <> '') and XValid(LOwner) and
     FieldIn(AEntry.Mid, LOwner, LName, LFMid, LFSym) then
    LFieldType := FieldClass(LFMid, LFSym);
  if XValid(LFieldType) and SameText(
     FProj.Model(LFieldType.UnitId).Symbols[LFieldType.Sym].Name, LClassName) then
    Result := LFieldType
  else
  begin
    Result := TypeInUnit(AEntry.Mid, LowerCase(LClassName));
    if not XValid(Result) then
      Result := LFieldType;
  end;
  AEntry.ObjClass[AObj] := Result;
end;

// A published FIELD named ANameLower reachable from AClass (its ancestors
// included) - what FieldAddress would find.
function TPasFormBinder.FieldIn(AMid: Integer; const AClass: TSemaXType;
  const ANameLower: string; out AFMid, AFSym: Integer): Boolean;
var
  LCtx: Integer;
  LSym: TSemaSymbol;
begin
  Result := XValid(AClass) and FProj.FindMemberX(AMid, AClass, ANameLower,
    AFMid, AFSym, LCtx) and (AFMid >= 0) and (AFSym <> NIL_SYM);
  if Result then
  begin
    LSym := FProj.Model(AFMid).Symbols[AFSym];
    Result := (LSym.Kind = skField) and
      (LSym.Visibility in [svDefault, svPublished]);
  end;
end;

// A published METHOD - what MethodAddress would find.
function TPasFormBinder.MethodIn(AMid: Integer; const AClass: TSemaXType;
  const ANameLower: string; out AFMid, AFSym: Integer): Boolean;
var
  LCtx: Integer;
  LSym: TSemaSymbol;
begin
  Result := XValid(AClass) and FProj.FindMemberX(AMid, AClass, ANameLower,
    AFMid, AFSym, LCtx) and (AFMid >= 0) and (AFSym <> NIL_SYM);
  if Result then
  begin
    LSym := FProj.Model(AFMid).Symbols[AFSym];
    Result := (LSym.Kind = skRoutine) and
      (LSym.Visibility in [svDefault, svPublished]);
  end;
end;

function TPasFormBinder.FieldClass(AFMid, AFSym: Integer): TSemaXType;
begin
  Result := FProj.CanonTypeX(FProj.DeclTypeX(AFMid, AFSym));
end;

function TPasFormBinder.SameType(const A, B: TSemaXType): Boolean;
begin
  Result := XValid(A) and XValid(B) and (A.UnitId = B.UnitId) and
    (A.Sym = B.Sym);
end;

{ What (ATMid, ASym) is, as far as form files are concerned, and the class
  it is a member of (AOwner) for a member. A member only counts when it is a
  CLASS member that is published - see the unit header. }
function TPasFormBinder.ShapeOf(ATMid, ASym: Integer;
  out AOwner: TSemaXType): TSymShape;
var
  LM: TPasSemaModel;
  LSym: TSemaSymbol;
  LOwner: Integer;
begin
  Result := ssNone;
  AOwner := XNil;
  if (ATMid < 0) or (ATMid >= FProj.ModelCount) or (ASym = NIL_SYM) then
    Exit;
  LM := FProj.Model(ATMid);
  if (ASym < 0) or (ASym >= LM.SymCount) then
    Exit;
  LSym := LM.Symbols[ASym];
  case LSym.Kind of
    skField, skRoutine, skProperty:
      begin
        if (LSym.Scope = NIL_SCOPE) or
           not (LSym.Visibility in [svDefault, svPublished]) then
          Exit;
        LOwner := LM.Scopes[LSym.Scope].StructSym;
        if LOwner = NIL_SYM then
          LOwner := LM.StructSymAtNode(LM.Scopes[LSym.Scope].OwnerNode);
        if (LOwner = NIL_SYM) or (LM.Symbols[LOwner].TypeCat <> tcClass) then
          Exit;
        AOwner := XPlain(ATMid, LOwner);
        case LSym.Kind of
          skField: Result := ssField;
          skRoutine: Result := ssMethod;
        else
          Result := ssProperty;
        end;
      end;
    skType:
      if LSym.TypeCat = tcClass then
        Result := ssClass;
    skEnumValue:
      Result := ssEnumValue;
  end;
end;

// Whether a value sits in an EVENT property - by the name the VCL, FMX and
// every component vendor give events. Only a tie-breaker (see ValueTarget).
function TPasFormBinder.IsEventProp(ADoc: TPasDfmDoc; AProp: Integer): Boolean;
var
  LLast: string;
begin
  Result := False;
  if (AProp < 0) or (AProp > High(ADoc.Props)) then
    Exit;
  LLast := ADoc.IdentText(ADoc.Props[AProp].FirstIdent +
    ADoc.Props[AProp].SegCount - 1);
  Result := (Length(LLast) > 2) and StartsText('On', LLast);
end;

function TPasFormBinder.ValueTarget(AEntry: TFormEntry; AIdent: Integer;
  out ATMid, ATSym: Integer; out AIsMethod: Boolean): Boolean;
var
  LVia: TPasFormSiteVia;
begin
  Result := ValueTarget(AEntry, AIdent, ATMid, ATSym, AIsMethod, LVia);
end;

// The path a component's own header is reached by: inside an inline frame's
// block its name is a field of the frame, not of the form.
function TPasFormBinder.HeaderVia(ADoc: TPasDfmDoc;
  AObj: Integer): TPasFormSiteVia;
begin
  if (AObj > 0) and (HeaderLookupRoot(ADoc, AObj) > 0) then
    Result := fsvInline
  else
    Result := fsvOwn;
end;

{ What the identifier-value segment AIdent binds to: a handler or a
  component (AIsMethod says which), and by which path (AVia). False when it
  binds to nothing this unit resolves - an enum value, a constant, a segment
  of a path whose head is unknown, the root Name of a module (not a
  symbol). }
function TPasFormBinder.ValueTarget(AEntry: TFormEntry; AIdent: Integer;
  out ATMid, ATSym: Integer; out AIsMethod: Boolean;
  out AVia: TPasFormSiteVia): Boolean;
var
  LDoc: TPasDfmDoc;
  LId: TPasDfmIdent;
  LFirst, LCand, LMMid, LMSym: Integer;
  LClass, LRoot: TSemaXType;
  LName: string;
  LRoots: TArray<Integer>;
  LHasMethod: Boolean;

  // Segments 1..LId.Seg of the path, from LClass on.
  function Walk(AFrom: TSemaXType): Boolean;
  var
    LS: Integer;
    LC: TSemaXType;
  begin
    Result := False;
    LC := AFrom;
    for LS := 1 to LId.Seg do
    begin
      if not FieldIn(AEntry.Mid, LC, LowerCase(LDoc.IdentText(LFirst + LS)),
        ATMid, ATSym) then
        Exit;
      if LS < LId.Seg then
        LC := FieldClass(ATMid, ATSym);
    end;
    Result := LId.Seg >= 1;
  end;

begin
  AIsMethod := False;
  ATMid := NIL_SYM;
  ATSym := NIL_SYM;
  LDoc := DocOf(AEntry);
  LId := LDoc.Idents[AIdent];
  LFirst := AIdent - LId.Seg;
  LClass := ObjClassOf(AEntry, InnerLookupRoot(LDoc, LId.Obj));
  LName := LowerCase(LDoc.IdentText(LFirst));
  // A value inside an inline frame's block is resolved against the frame.
  if InnerLookupRoot(LDoc, LId.Obj) > 0 then
    AVia := fsvInline
  else
    AVia := fsvOwn;
  if LId.SegCount = 1 then
  begin
    LRoot := RootClassOf(AEntry);
    LHasMethod := MethodIn(AEntry.Mid, LRoot, LName, LMMid, LMSym);
    if LHasMethod and IsEventProp(LDoc, LId.Prop) then
    begin
      ATMid := LMMid;
      ATSym := LMSym;
      AIsMethod := True;
      Exit(True);
    end;
    if FieldIn(AEntry.Mid, LClass, LName, ATMid, ATSym) then
      Exit(True);
    if LHasMethod then
    begin
      ATMid := LMMid;
      ATSym := LMSym;
      AIsMethod := True;
      Exit(True);
    end;
    Exit(False);
  end;
  // A path. Its head: a component of the lookup root...
  if FieldIn(AEntry.Mid, LClass, LName, ATMid, ATSym) then
  begin
    if LId.Seg = 0 then
      Exit(True);
    AVia := fsvInline;   // `Frame1.Edit1`: a field of the component's class
    Exit(Walk(FieldClass(ATMid, ATSym)));
  end;
  // ...else another module's root, by Name. Several forms may share one;
  // the first through which the path resolves wins.
  if LId.Seg = 0 then
    Exit(False);
  AVia := fsvModule;
  EnsureRootNames;
  if not FRootNames.TryGetValue(LName, LRoots) then
    Exit(False);
  for LCand in LRoots do
    if Walk(RootClassOf(FForms[LCand])) then
      Exit(True);
  Result := False;
end;

function TPasFormBinder.SiteOf(AEntry: TFormEntry; AIdent: Integer;
  AKind: TPasFormSiteKind; AVia: TPasFormSiteVia): TPasFormSite;
var
  LDoc: TPasDfmDoc;
  LId: TPasDfmIdent;
begin
  LDoc := DocOf(AEntry);
  LId := LDoc.Idents[AIdent];
  Result := Default(TPasFormSite);
  Result.FilePath := AEntry.Path;
  Result.Line := LDoc.LineOf(LId.Offset);
  Result.Col := LDoc.ColOf(LId.Offset);
  Result.OldText := LDoc.IdentText(AIdent);
  Result.Len := Length(Result.OldText);
  Result.Snippet := LDoc.LineText(Result.Line);
  Result.HiFrom := Result.Col - 1;
  Result.HiTo := Result.HiFrom + Result.Len;
  Result.Offset := LId.Offset;
  Result.ByteLen := LId.ByteLen;
  Result.Kind := AKind;
  Result.Via := AVia;
  Result.ObjectName := LDoc.ObjectName(LId.Obj);
  Result.ObjIndex := LId.Obj;
  if LId.Prop >= 0 then
    Result.PropName := LDoc.PropPath(LId.Prop);
  Result.IsBinary := LDoc.IsBinary;
  Result.IsUtf8 := LDoc.Encoding = dfeUtf8;
end;

function TPasFormBinder.EntryOf(const APath: string): TFormEntry;
var
  LEntry: TFormEntry;
begin
  for LEntry in FForms do
    if SameText(LEntry.Path, APath) then
      Exit(LEntry);
  Result := nil;
end;

function TPasFormBinder.SitesOf(ATMid, ASym: Integer; ARename: Boolean;
  out AError: string): TArray<TPasFormSite>;
var
  LShape: TSymShape;
  LOwner, LSelf, LClass: TSemaXType;
  LNameLower: string;
  LList: TList<TPasFormSite>;
  LEntry: TFormEntry;
  LDoc: TPasDfmDoc;
  LIdx, LTMid, LTSym: Integer;
  LId: TPasDfmIdent;
  LIsMethod: Boolean;
  LVia: TPasFormSiteVia;

  function Where: string;
  begin
    Result := Format('%s line %d', [TPath.GetFileName(LEntry.Path),
      LDoc.LineOf(LId.Offset)]);
  end;

begin
  Result := nil;
  AError := '';
  LShape := ShapeOf(ATMid, ASym, LOwner);
  if LShape = ssNone then
    Exit;
  LNameLower := AnsiLowerCase(FProj.Model(ATMid).Symbols[ASym].Name);
  LSelf := XNil;
  if LShape = ssClass then
    LSelf := FProj.CanonTypeX(XPlain(ATMid, ASym));
  Refresh;
  LList := TList<TPasFormSite>.Create;
  try
    for LEntry in FForms do
    begin
      LDoc := DocOf(LEntry);
      if LDoc.Error <> '' then
      begin
        if ARename and LDoc.MentionsText(LNameLower) then
        begin
          AError := Format('%s could not be read (%s) and may name "%s" - ' +
            'rename refused, nothing planned.', [TPath.GetFileName(LEntry.Path),
            LDoc.Error, FProj.Model(ATMid).Symbols[ASym].Name]);
          Exit;
        end;
        // A reference search still lists what was read before the error.
      end;
      for LIdx in LDoc.FindIdents(LNameLower) do
      begin
        LId := LDoc.Idents[LIdx];
        case LShape of
          ssField:
            case LId.Role of
              dirObjectName:
                if LId.Obj > 0 then
                begin
                  LClass := ObjClassOf(LEntry, HeaderLookupRoot(LDoc, LId.Obj));
                  if not XValid(LClass) then
                  begin
                    if ARename then
                    begin
                      AError := Format('%s: the class that owns the ' +
                        'component "%s" could not be resolved - rename ' +
                        'refused, nothing planned.', [Where, LDoc.IdentText(LIdx)]);
                      Exit;
                    end;
                  end
                  else if FieldIn(LEntry.Mid, LClass, LNameLower, LTMid,
                    LTSym) and (LTMid = ATMid) and (LTSym = ASym) then
                    LList.Add(SiteOf(LEntry, LIdx, fskComponent,
                      HeaderVia(LDoc, LId.Obj)));
                end;
              dirValue:
                if ValueTarget(LEntry, LIdx, LTMid, LTSym, LIsMethod, LVia) and
                   not LIsMethod and (LTMid = ATMid) and (LTSym = ASym) then
                  LList.Add(SiteOf(LEntry, LIdx, fskComponentRef, LVia));
            end;
          ssMethod:
            if (LId.Role = dirValue) and (LId.SegCount = 1) then
            begin
              if not XValid(RootClassOf(LEntry)) then
              begin
                if ARename then
                begin
                  AError := Format('%s: the form''s class "%s" is not ' +
                    'declared in its unit - rename refused, nothing planned.',
                    [Where, LDoc.RootClassName]);
                  Exit;
                end;
              end
              else if ValueTarget(LEntry, LIdx, LTMid, LTSym, LIsMethod,
                LVia) and LIsMethod and (LTMid = ATMid) and (LTSym = ASym) then
                LList.Add(SiteOf(LEntry, LIdx, fskHandler, LVia))
              // An ANCESTOR's form: an instance of the method's class reads
              // it too (InitInheritedComponent, one resource per class), and
              // the reader's Root is that instance - MethodAddress finds this
              // method by the name, not the ancestor's own.
              else if IsEventProp(LDoc, LId.Prop) and XValid(LOwner) and
                not SameType(FProj.CanonTypeX(LOwner), RootClassOf(LEntry)) and
                FProj.XDescendsFrom(LOwner, RootClassOf(LEntry)) and
                MethodIn(ATMid, LOwner, LNameLower, LTMid, LTSym) and
                (LTMid = ATMid) and (LTSym = ASym) then
              begin
                if ARename then
                begin
                  AError := Format('%s binds "%s" by name in an ancestor''s ' +
                    'form, for %s as well as for the ancestor''s own forms - ' +
                    'renaming it would leave that event running the ' +
                    'ancestor''s method; rename refused, nothing planned.',
                    [Where, LDoc.IdentText(LIdx),
                    FProj.Model(LOwner.UnitId).Symbols[LOwner.Sym].Name]);
                  Exit;
                end;
                LList.Add(SiteOf(LEntry, LIdx, fskHandler, fsvAncestor));
              end;
            end;
          ssClass:
            if LId.Role = dirClassName then
            begin
              LClass := ObjClassOf(LEntry, LId.Obj);
              // An inline object's class is the frame's, named in the host.
              if (LId.Obj > 0) and
                 ((LDoc.Objects[LId.Obj].Kind = dokInline) or
                  (HeaderLookupRoot(LDoc, LId.Obj) > 0)) then
                LVia := fsvInline
              else
                LVia := fsvOwn;
              if SameType(LClass, LSelf) then
                LList.Add(SiteOf(LEntry, LIdx, fskClass, LVia))
              else if ARename and not XValid(LClass) then
              begin
                AError := Format('%s: the class "%s" could not be resolved - ' +
                  'rename refused, nothing planned.', [Where,
                  LDoc.IdentText(LIdx)]);
                Exit;
              end;
            end;
          ssProperty:
            if ARename and (LId.Role = dirPropName) then
            begin
              // Excluded only when it is certainly some OTHER class's
              // property: a direct property of an object whose class is
              // known and is not the owner or a descendant of it.
              if (LId.Seg = 0) and not LId.InItem then
              begin
                LClass := ObjClassOf(LEntry, LId.Obj);
                if XValid(LClass) and not FProj.XDescendsFrom(LClass, LOwner) then
                  Continue;
              end;
              AError := Format('%s sets a property named "%s", and renaming ' +
                'a published property in form files is not supported yet - ' +
                'rename refused, nothing planned.', [Where,
                LDoc.IdentText(LIdx)]);
              Exit;
            end;
          ssEnumValue:
            if ARename and (LId.Role in [dirValue, dirSetItem]) then
            begin
              if (LId.Role = dirValue) and ValueTarget(LEntry, LIdx, LTMid,
                LTSym, LIsMethod) then
                Continue;   // a handler or a component of that spelling
              AError := Format('%s spells the value "%s", and renaming an ' +
                'enumeration value in form files is not supported yet - ' +
                'rename refused, nothing planned.', [Where,
                LDoc.IdentText(LIdx)]);
              Exit;
            end;
        end;
      end;
    end;
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
  TArray.Sort<TPasFormSite>(Result, TComparer<TPasFormSite>.Construct(
    function(const A, B: TPasFormSite): Integer
    begin
      Result := CompareText(A.FilePath, B.FilePath);
      if Result = 0 then
        Result := A.Line - B.Line;
      if Result = 0 then
        Result := A.Col - B.Col;
    end));
end;

function TPasFormBinder.RenameRefusal(ATMid, ASym: Integer;
  const ANewName: string; const ASites: TArray<TPasFormSite>): string;
var
  LSite: TPasFormSite;
  LShape: TSymShape;
  LOwner, LRoot: TSemaXType;
  LNewLower, LMember: string;
  LAscii: Boolean;
  LIdx, LObj, LMMid, LMSym, LCtx: Integer;
  LEntry: TFormEntry;
  LDoc: TPasDfmDoc;
begin
  Result := '';
  for LSite in ASites do
    if LSite.IsBinary then
      Exit(Format('%s is a binary form file - convert it to text (the ' +
        'form''s context menu, Text DFM), save it, and rename again. ' +
        'Nothing was renamed.', [TPath.GetFileName(LSite.FilePath)]));
  LAscii := True;
  for LIdx := 1 to Length(ANewName) do
    if Ord(ANewName[LIdx]) > 127 then
      LAscii := False;
  if not LAscii then
    for LSite in ASites do
      if not LSite.IsUtf8 then
        Exit(Format('%s is not a UTF-8 form file, so it cannot hold the ' +
          'name "%s" - rename refused, nothing planned.',
          [TPath.GetFileName(LSite.FilePath), ANewName]));
  LShape := ShapeOf(ATMid, ASym, LOwner);
  if not (LShape in [ssField, ssMethod]) or (Length(ASites) = 0) then
    Exit;
  LNewLower := AnsiLowerCase(ANewName);
  // Every form that streams the owner - its own and its descendants' - must
  // not already reach a member, or hold a component, of the new name. The
  // docs are the ones SitesOf just refreshed.
  if not FListed then
    Refresh;
  for LEntry in FForms do
  begin
    LDoc := DocOf(LEntry);
    LRoot := RootClassOf(LEntry);
    if not XValid(LRoot) or not FProj.XDescendsFrom(LRoot, LOwner) then
      Continue;
    if FProj.FindMemberX(LEntry.Mid, LRoot, LNewLower, LMMid, LMSym, LCtx) and
       (LMMid >= 0) and (LMSym <> NIL_SYM) and
       ((LMMid <> ATMid) or (LMSym <> ASym)) then
    begin
      LMember := FProj.Model(LMMid).Symbols[LMSym].Name;
      Exit(Format('%s already reaches a member named "%s" (declared in %s) ' +
        '- renaming onto it would rebind the form. Rename refused, nothing ' +
        'planned.', [LDoc.RootClassName, LMember,
        TPath.GetFileName(FProj.ModelFile(LMMid))]));
    end;
    for LObj := 1 to High(LDoc.Objects) do
      if (HeaderLookupRoot(LDoc, LObj) = 0) and
         SameText(LDoc.ObjectName(LObj), ANewName) then
        Exit(Format('%s already has a component named "%s" - rename ' +
          'refused, nothing planned.', [TPath.GetFileName(LEntry.Path),
          LDoc.ObjectName(LObj)]));
  end;
end;

procedure TPasFormBinder.CarriedBy(ATMid, ASym: Integer;
  const ANewName: string; const ASites: TArray<TPasFormSite>;
  out AHandlers: TArray<TPasCarriedHandler>;
  out ACaptions: TArray<TPasFormSite>);
var
  LShape: TSymShape;
  LOwner: TSemaXType;
  LOldName, LProp, LSuffix: string;
  LSite, LCaption: TPasFormSite;
  LEntry: TFormEntry;
  LDoc: TPasDfmDoc;
  LPi, LValue, LTMid, LTSym, LByteLen, LIdx: Integer;
  LIsMethod, LHasClient, LKnown, LFollows: Boolean;
  LHandler: TPasCarriedHandler;
begin
  AHandlers := nil;
  ACaptions := nil;
  LShape := ShapeOf(ATMid, ASym, LOwner);
  if (LShape <> ssField) or (Length(ASites) = 0) then
    Exit;
  LOldName := FProj.Model(ATMid).Symbols[ASym].Name;
  if not FListed then
    Refresh;
  // An action's clients, as far as form files say: whatever links it
  // through an `Action` property. Nothing but an action is linked that way.
  LHasClient := False;
  for LSite in ASites do
    if (LSite.Kind = fskComponentRef) and
       (SameText(LSite.PropName, 'Action') or
        EndsText('.Action', LSite.PropName)) then
      LHasClient := True;
  for LSite in ASites do
  begin
    if LSite.Kind <> fskComponent then
      Continue;
    LEntry := EntryOf(LSite.FilePath);
    if LEntry = nil then
      Continue;
    LDoc := DocOf(LEntry);
    for LPi := 0 to High(LDoc.Props) do
    begin
      if (LDoc.Props[LPi].Obj <> LSite.ObjIndex) or LDoc.Props[LPi].InItem then
        Continue;
      LProp := LDoc.PropPath(LPi);
      if (LDoc.Props[LPi].SegCount = 1) and IsEventProp(LDoc, LPi) then
      begin
        // The value, when it is one identifier: recorded right after the
        // property's own name segments.
        LValue := LDoc.Props[LPi].FirstIdent + LDoc.Props[LPi].SegCount;
        if (LValue > High(LDoc.Idents)) or
           (LDoc.Idents[LValue].Role <> dirValue) or
           (LDoc.Idents[LValue].Prop <> LPi) or
           (LDoc.Idents[LValue].SegCount <> 1) then
          Continue;
        LSuffix := Copy(LProp, 3, MaxInt);
        if not AnsiSameText(LDoc.IdentText(LValue), LOldName + LSuffix) or
           not ValueTarget(LEntry, LValue, LTMid, LTSym, LIsMethod) or
           not LIsMethod then
          Continue;
        LKnown := False;
        for LIdx := 0 to High(AHandlers) do
          if (AHandlers[LIdx].TMid = LTMid) and (AHandlers[LIdx].TSym = LTSym) then
            LKnown := True;
        if LKnown then
          Continue;
        LHandler.TMid := LTMid;
        LHandler.TSym := LTSym;
        LHandler.NewName := ANewName + LSuffix;
        AHandlers := AHandlers + [LHandler];
        Continue;
      end;
      if (LDoc.Props[LPi].SegCount = 1) and
         (SameText(LProp, 'Caption') or SameText(LProp, 'Text')) then
        LFollows := not LHasClient and
          LDoc.StringValueIs(LPi, LOldName, True, LByteLen)
      else if SameText(LProp, 'EditLabel.Caption') then
        LFollows := LDoc.StringValueIs(LPi, LOldName, False, LByteLen)
      else
        LFollows := False;
      if not LFollows then
        Continue;
      LCaption := LSite;
      LCaption.Kind := fskCaption;
      LCaption.Offset := LDoc.Props[LPi].StrOffset + 1;
      LCaption.ByteLen := LByteLen;
      LCaption.Line := LDoc.LineOf(LCaption.Offset);
      LCaption.Col := LDoc.ColOf(LCaption.Offset);
      LCaption.OldText := LDoc.DecodeBytes(LCaption.Offset, LByteLen);
      LCaption.Len := Length(LCaption.OldText);
      LCaption.Snippet := LDoc.LineText(LCaption.Line);
      LCaption.HiFrom := LCaption.Col - 1;
      LCaption.HiTo := LCaption.HiFrom + LCaption.Len;
      LCaption.PropName := LProp;
      ACaptions := ACaptions + [LCaption];
    end;
  end;
end;

function TPasFormBinder.RoleOf(ATMid, ASym: Integer): TPasFormRole;
var
  LOwner, LRoot: TSemaXType;
  LEntry: TFormEntry;
begin
  Result := Default(TPasFormRole);
  case ShapeOf(ATMid, ASym, LOwner) of
    ssField: Result.Kind := fskComponent;
    ssMethod: Result.Kind := fskHandler;
    ssClass:
      begin
        Result.Kind := fskClass;
        LOwner := XPlain(ATMid, ASym);
      end;
  else
    Exit;
  end;
  LOwner := FProj.CanonTypeX(LOwner);
  if not XValid(LOwner) then
    Exit;
  Result.OwnerClass := FProj.Model(LOwner.UnitId).Symbols[LOwner.Sym].Name;
  if not FListed then
    Refresh;
  for LEntry in FForms do
  begin
    LRoot := RootClassOf(LEntry);
    if SameType(LRoot, LOwner) then
    begin
      Result.FormFile := LEntry.Path;
      Break;
    end;
  end;
end;

function TPasFormBinder.DescribeForm(const APath: string;
  out AInfo: TPasFormInfo): Boolean;
var
  LEntry: TFormEntry;
  LDoc: TPasDfmDoc;
  LObjects: TList<TPasFormObject>;
  LBindings: TList<TPasFormBinding>;
  LO: TPasFormObject;
  LB: TPasFormBinding;
  LId: TPasDfmIdent;
  LOwner: TSemaXType;
  LTMid, LTSym, LFirst: Integer;
  LIsMethod: Boolean;
  LVia: TPasFormSiteVia;
begin
  AInfo := Default(TPasFormInfo);
  AInfo.FilePath := APath;
  AInfo.RootClass := XNil;
  Refresh;
  LEntry := EntryOf(APath);
  if LEntry = nil then
  begin
    AInfo.Error := 'not a form file of the project';
    Exit(False);
  end;
  LDoc := DocOf(LEntry);
  AInfo.FilePath := LEntry.Path;
  AInfo.Error := LDoc.Error;
  AInfo.IsBinary := LDoc.IsBinary;
  AInfo.RootClass := RootClassOf(LEntry);
  LObjects := TList<TPasFormObject>.Create;
  LBindings := TList<TPasFormBinding>.Create;
  try
    for var LObj := 0 to High(LDoc.Objects) do
    begin
      LO := Default(TPasFormObject);
      LO.Obj := LObj;
      LO.Parent := LDoc.Objects[LObj].Parent;
      LO.Kind := LDoc.Objects[LObj].Kind;
      LO.Name := LDoc.ObjectName(LObj);
      LO.ClassName := LDoc.ObjectClassName(LObj);
      if LDoc.Objects[LObj].ClassIdent >= 0 then
        LO.Line := LDoc.LineOf(
          LDoc.Idents[LDoc.Objects[LObj].ClassIdent].Offset);
      LO.ClassX := ObjClassOf(LEntry, LObj);
      LO.FieldMid := NIL_SYM;
      LO.FieldSym := NIL_SYM;
      if (LObj > 0) and (LO.Name <> '') then
      begin
        LOwner := ObjClassOf(LEntry, HeaderLookupRoot(LDoc, LObj));
        if FieldIn(LEntry.Mid, LOwner, LowerCase(LO.Name), LTMid, LTSym) then
        begin
          LO.FieldMid := LTMid;
          LO.FieldSym := LTSym;
        end;
      end;
      LObjects.Add(LO);
    end;
    // A value's LAST segment binds the whole path (ValueTarget walks it).
    for var LIdx := 0 to High(LDoc.Idents) do
    begin
      LId := LDoc.Idents[LIdx];
      if (LId.Role <> dirValue) or (LId.Seg <> LId.SegCount - 1) or
         (LId.Prop < 0) then
        Continue;
      LB := Default(TPasFormBinding);
      LB.Obj := LId.Obj;
      LB.PropName := LDoc.PropPath(LId.Prop);
      LFirst := LIdx - LId.Seg;
      LB.Value := LDoc.IdentText(LFirst);
      for var LS := LFirst + 1 to LIdx do
        LB.Value := LB.Value + '.' + LDoc.IdentText(LS);
      LB.Line := LDoc.LineOf(LDoc.Idents[LFirst].Offset);
      if ValueTarget(LEntry, LIdx, LTMid, LTSym, LIsMethod, LVia) then
      begin
        LB.IsMethod := LIsMethod;
        LB.TMid := LTMid;
        LB.TSym := LTSym;
        LB.Via := LVia;
      end
      else if not XValid(AInfo.RootClass) or not XValid(ObjClassOf(LEntry,
        InnerLookupRoot(LDoc, LId.Obj))) then
        Continue   // nothing to look the name up in: unknown, not missing
      else if (LId.SegCount = 1) and IsEventProp(LDoc, LId.Prop) then
      begin
        // An event naming no method the root has: EReadError when it loads.
        LB.IsMethod := True;
        LB.TMid := NIL_SYM;
        LB.TSym := NIL_SYM;
      end
      else if LId.SegCount > 1 then
      begin
        // `A.B` is a component path, never an enum value: one nothing answers
        // is a reference left dangling.
        LB.TMid := NIL_SYM;
        LB.TSym := NIL_SYM;
      end
      else
        Continue;   // `alClient`, `True`: a property's value, not a name
      LBindings.Add(LB);
    end;
    AInfo.Objects := LObjects.ToArray;
    AInfo.Bindings := LBindings.ToArray;
  finally
    LBindings.Free;
    LObjects.Free;
  end;
  Result := True;
end;

end.
