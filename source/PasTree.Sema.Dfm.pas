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
    are fields of TFrame1. A descendant host reopens F as `inherited F`, and
    that block is the frame's too - csInline is the component's, set by the
    ancestor's form that created it (IsInlineObj).
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
  descendants, across modules, and into its hosts' inline blocks (measured
  in RAD Studio 13, pastree-lsp local/DFM-PLAN.md, spike run 5).

  WHAT IS NOT BOUND YET, AND IS REFUSED RATHER THAN SKIPPED. A property NAME
  is found for a reference search (fskProperty) in the class TReader looks
  it up in - the object's for `Caption = ...`, the property type's for a
  sub-property (`Font.Name`), the item class of the collection for an item's
  property (PropHolder) - a bare redeclaration taken for the one it
  republishes. Enum VALUES bind through a property's type, which this unit
  does not resolve for values yet. A RENAME of a published property or of an
  enum value that a form file may spell is refused whole - a partial rename
  would be exactly the silent break this unit exists to prevent.
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
    fskCaption,       // `Caption = 'X'` - a renamed component's caption that
                      // read its name, and follows it (CarriedBy); never a
                      // reference, only ever part of a rename
    fskProperty);     // `Caption = ...` - a line setting the published property
                      // (reference searches only: a rename is still refused)

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
    // An fskProperty line that MAY set the property: the class it is read
    // in, or a link of its path, is a declared type without it, the class
    // read chosen at run time (PropHolder's ADeclared, AOpen) - so it may as
    // well set some other class's property of the name.
    Unsure: Boolean;
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
    PropName: string;          // `OnClick`, `FocusControl`, `Items[0].Action`
    Value: string;             // as written: `btnSaveClick`, `dmData.pmActions`
    Line: Integer;             // 1-based
    IsMethod: Boolean;         // a handler (or an event whose method is missing)
    // `OnClick = nil`: the event runs nothing - what the designer writes when
    // a descendant clears the handler its ancestor's form binds. TSym is
    // NIL_SYM, and it is not a missing method.
    Cleared: Boolean;
    // A component path that reaches a component by NAME - one the form files
    // create with no field declared for it: it binds at run time, and TSym
    // is NIL_SYM because there is no symbol to bind to.
    NoField: Boolean;
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
    // The first line after the root's `end`, 0 when nothing follows it: dcc
    // reads one object, so what is written from there is not bound.
    TrailingLine: Integer;
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
      // IsInlineObj, memoized: 0 not yet known, 1 no, 2 yes.
      ObjInline: TArray<Byte>;
    end;
    // A directory holding analyzed units, as EnsureListed last listed it.
    TFormDir = class
      Path: string;
      Stamp: Int64;               // its last write time then (DirStamp)
      Mids: TArray<Integer>;      // the analyzed units in it
    end;
    TSymShape = (ssNone, ssField, ssMethod, ssClass, ssProperty, ssEnumValue);
  private
    FProj: TPasSemaProject;
    FLibraryPaths: TArray<string>;
    FForms: TObjectList<TFormEntry>;
    FDirs: TObjectList<TFormDir>;
    FFormOfMid: TDictionary<Integer, TFormEntry>;
    FListed: Boolean;
    FRootNames: TDictionary<string, TArray<Integer>>;
    FRootNamesBuilt: Boolean;
    function IsLibrary(const APath: string): Boolean;
    procedure EnsureListed;
    procedure ListDir(ADir: TFormDir);
    procedure Refresh;
    function DocOf(AEntry: TFormEntry): TPasDfmDoc;
    procedure EnsureRootNames;
    function TypeInUnit(AMid: Integer; const ANameLower: string): TSemaXType;
    function RootClassOf(AEntry: TFormEntry): TSemaXType;
    function RootEntryOfClass(const AClass: TSemaXType): TFormEntry;
    function IsInlineObj(AEntry: TFormEntry; AObj: Integer): Boolean;
    function HeaderLookupRoot(AEntry: TFormEntry; AObj: Integer): Integer;
    function InnerLookupRoot(AEntry: TFormEntry; AObj: Integer): Integer;
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
    function HeaderVia(AEntry: TFormEntry; AObj: Integer): TPasFormSiteVia;
    function SiteOf(AEntry: TFormEntry; AIdent: Integer;
      AKind: TPasFormSiteKind; AVia: TPasFormSiteVia): TPasFormSite;
    function EntryOf(const APath: string): TFormEntry;
    function SameProperty(AMid1, ASym1, AMid2, ASym2: Integer): Boolean;
    function CreatedIn(const AClass: TSemaXType; const ANameLower: string;
      out AObjClass: TSemaXType): Boolean;
    function ReachedByName(AEntry: TFormEntry; AIdent: Integer): Boolean;
    function PropClassOf(AMid: Integer; const AClass: TSemaXType;
      const ANameLower: string; out AFound: Boolean): TSemaXType;
    function PropHolder(AEntry: TFormEntry; AProp, ASeg: Integer;
      out ADeclared, AOpen: Boolean): TSemaXType;
    function ItemClassOf(AEntry: TFormEntry; AColl: Integer;
      out AOpen: Boolean): TSemaXType;
    function ClassNamedBeside(AEntry: TFormEntry;
      AProp, ASeg: Integer): TSemaXType;
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
      out AError: string): TArray<TPasFormSite>; overload;
    { The same, for one method of a rename that takes several under one new
      name (PlanRename's family, ATogether): an ancestor's form line that
      binds a descendant's redeclaration and the ancestor's own method at
      once is no refusal when that ancestor method is in ATogether - the
      line is rewritten and binds both again - but a site of this one too. }
    function SitesOf(ATMid, ASym: Integer; ARename: Boolean;
      const ATogether: TArray<TPasExtRef>;
      out AError: string): TArray<TPasFormSite>; overload;
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
{$IFDEF MSWINDOWS}
  Winapi.Windows,
{$ENDIF}
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
  FDirs := TObjectList<TFormDir>.Create(True);
  FFormOfMid := TDictionary<Integer, TFormEntry>.Create;
  FRootNames := TDictionary<string, TArray<Integer>>.Create;
end;

destructor TPasFormBinder.Destroy;
begin
  FRootNames.Free;
  FFormOfMid.Free;
  FDirs.Free;
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

// A directory's last write time, 0 when it cannot be read: creating,
// deleting or renaming a file in it moves it, writing a file does not. One
// file system call - Refresh asks it of every unit directory on every query.
function DirStamp(const APath: string): Int64;
{$IFDEF MSWINDOWS}
var
  LData: TWin32FileAttributeData;
begin
  if GetFileAttributesEx(PChar(APath), GetFileExInfoStandard, @LData) then
    Result := (Int64(LData.ftLastWriteTime.dwHighDateTime) shl 32) or
      LData.ftLastWriteTime.dwLowDateTime
  else
    Result := 0;
end;
{$ELSE}
begin
  try
    Result := Trunc(TDirectory.GetLastWriteTimeUtc(APath) * 86400000.0);
  except
    Result := 0;
  end;
end;
{$ENDIF}

{ The project's form files: each analyzed unit's `.dfm` / `.fmx` sibling.
  Found by listing each unit DIRECTORY rather than probing two names per unit
  - a large project has a few hundred directories and a few thousand units.
  Each directory's write time is kept, and Refresh lists a directory again
  when it moved: a form file written after the listing - the unit first and
  its form next, as an agent writes them, or one brought back by a checkout -
  would otherwise not be a form file of the project for as long as the binder
  lives, and every handler it binds would read unbound. }
procedure TPasFormBinder.EnsureListed;
var
  LByPath: TDictionary<string, TFormDir>;
  LMid: Integer;
  LUnit, LKey: string;
  LDir: TFormDir;
begin
  if FListed then
    Exit;
  FListed := True;
  LByPath := TDictionary<string, TFormDir>.Create;
  try
    for LMid := 0 to FProj.ModelCount - 1 do
    begin
      LUnit := FProj.ModelFile(LMid);
      if (LUnit = '') or IsLibrary(LUnit) then
        Continue;
      LKey := LowerCase(ExtractFileDir(LUnit));
      if not LByPath.TryGetValue(LKey, LDir) then
      begin
        LDir := TFormDir.Create;
        LDir.Path := ExtractFileDir(LUnit);
        FDirs.Add(LDir);
        LByPath.Add(LKey, LDir);
      end;
      LDir.Mids := LDir.Mids + [LMid];
    end;
  finally
    LByPath.Free;
  end;
  for LDir in FDirs do
  begin
    LDir.Stamp := DirStamp(LDir.Path);
    ListDir(LDir);
  end;
end;

// Adds an entry for each unit of ADir that has a form file beside it now and
// none yet. An entry is never removed - a form file that vanishes reads as a
// failed document (Refresh), and one that comes back is read again.
procedure TPasFormBinder.ListDir(ADir: TFormDir);
var
  LNames: TDictionary<string, string>;
  LFile, LExt, LKey, LFound: string;
  LMid: Integer;
  LEntry: TFormEntry;
begin
  LNames := TDictionary<string, string>.Create;
  try
    try
      if TDirectory.Exists(ADir.Path) then
        for LFile in TDirectory.GetFiles(ADir.Path) do
        begin
          LExt := LowerCase(ExtractFileExt(LFile));
          if (LExt = '.dfm') or (LExt = '.fmx') then
            LNames.AddOrSetValue(LowerCase(ExtractFileName(LFile)), LFile);
        end;
    except
      // An unlistable directory has no form files we could read anyway.
    end;
    for LMid in ADir.Mids do
    begin
      if FFormOfMid.ContainsKey(LMid) then
        Continue;
      LKey := LowerCase(ChangeFileExt(ExtractFileName(FProj.ModelFile(LMid)),
        ''));
      if LNames.TryGetValue(LKey + '.dfm', LFound) or
         LNames.TryGetValue(LKey + '.fmx', LFound) then
      begin
        LEntry := TFormEntry.Create;
        LEntry.Mid := LMid;
        LEntry.Path := LFound;
        LEntry.RootClass := XNil;
        FForms.Add(LEntry);
        FFormOfMid.Add(LMid, LEntry);
      end;
    end;
  finally
    LNames.Free;
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
  LChanged: Boolean;
  LIdx: Integer;
  LDir: TFormDir;
  LStamp: Int64;
begin
  if FListed then
    for LDir in FDirs do
    begin
      LStamp := DirStamp(LDir.Path);
      if LStamp <> LDir.Stamp then
      begin
        LDir.Stamp := LStamp;
        ListDir(LDir);   // a new entry has no doc yet: the loop below reads it
      end;
    end;
  EnsureListed;
  LChanged := False;
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
      LEntry.ObjInline := nil;
      SetLength(LEntry.ObjInline, Length(LDoc.Doc.Objects));
      FRootNamesBuilt := False;
      LChanged := True;
    end;
  end;
  // What an object IS depends on other form files too - an `inherited F` is
  // an inline frame when its ancestor's form says so (IsInlineObj) - so one
  // changed file forgets every object's class and inline state.
  if LChanged then
    for LEntry in FForms do
      for LIdx := 0 to High(LEntry.ObjDone) do
      begin
        LEntry.ObjDone[LIdx] := False;
        LEntry.ObjInline[LIdx] := 0;
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

// The form entry whose ROOT is of class AClass, or nil - the form file that
// class streams itself from (InitInheritedComponent reads one per class).
function TPasFormBinder.RootEntryOfClass(const AClass: TSemaXType): TFormEntry;
var
  LEntry: TFormEntry;
begin
  Result := nil;
  if not XValid(AClass) then
    Exit;
  for LEntry in FForms do
    if SameType(RootClassOf(LEntry), AClass) then
      Exit(LEntry);
end;

{ WHETHER AObj'S BLOCK IS AN INLINE FRAME'S - the lookup root inside it is
  then the frame. TReader switches FLookupRoot on the COMPONENT's csInline
  (ReadComponent: `if csInline in Result.ComponentState then FLookupRoot :=
  Result`), and csInline is set by the stream that CREATED the component
  with ffInline. So `inline F` says it itself, and `inherited F` - a
  descendant reopening its ancestor's F - says nothing: F is inline when the
  ancestor's form file that created it wrote `inline F`. That form is found
  up the class chain of the class that owns F (the lookup root's): the
  form's own ancestors for a component of the form, the frame class itself
  (then its ancestors) for a component inside a frame - the first form file
  of the chain holding F as `object` or `inline` created it; `inherited`
  there sends the search one class further up.

  Until 0.63.1 only `inline` counted, and every component inside an
  `inherited Frame1` block of a descendant host was looked up in the host's
  class and bound to nothing - silently: a rename of the frame's component
  left `inherited FrameButton` in the descendant's form file, which then
  fails to load ("Ancestor for 'FrameButton' not found" when the form is
  created). Found by Alex on 2026-09-28, local/dfmspike's SpikeChild.dfm. }
function TPasFormBinder.IsInlineObj(AEntry: TFormEntry; AObj: Integer): Boolean;
var
  LDoc, LAncDoc: TPasDfmDoc;
  LOwnerObj, LIdx, LGuard: Integer;
  LClass: TSemaXType;
  LAnc: TFormEntry;
  LName: string;
  LFound, LAnswer: Boolean;
begin
  Result := False;
  LDoc := DocOf(AEntry);
  if (AObj <= 0) or (AObj > High(LDoc.Objects)) then
    Exit;
  case LDoc.Objects[AObj].Kind of
    dokInline:
      Exit(True);
    dokObject:
      Exit(False);
  end;
  if AEntry.ObjInline[AObj] <> 0 then
    Exit(AEntry.ObjInline[AObj] = 2);
  AEntry.ObjInline[AObj] := 1;   // "no" while it is worked out: no cycle
  LName := LDoc.ObjectName(AObj);
  LOwnerObj := HeaderLookupRoot(AEntry, AObj);
  LClass := ObjClassOf(AEntry, LOwnerObj);
  // A component of the form: created by an ANCESTOR's form file - this one
  // only reopens it. A component inside a frame: by the frame's own.
  if LOwnerObj = 0 then
    LClass := FProj.CanonTypeX(FProj.AncestorOfX(LClass));
  LAnswer := False;
  LGuard := 0;
  while XValid(LClass) and (LGuard < 64) do
  begin
    LAnc := RootEntryOfClass(LClass);
    if (LAnc <> nil) and (LAnc <> AEntry) then
    begin
      LAncDoc := DocOf(LAnc);
      LFound := False;
      for LIdx := 1 to High(LAncDoc.Objects) do
        if SameText(LAncDoc.ObjectName(LIdx), LName) and
           (HeaderLookupRoot(LAnc, LIdx) = 0) then
        begin
          LFound := LAncDoc.Objects[LIdx].Kind <> dokInherited;
          if LFound then
            LAnswer := LAncDoc.Objects[LIdx].Kind = dokInline;
          Break;
        end;
      if LFound then
        Break;
    end;
    LClass := FProj.CanonTypeX(FProj.AncestorOfX(LClass));
    Inc(LGuard);
  end;
  if LAnswer then
    AEntry.ObjInline[AObj] := 2;
  Result := LAnswer;
end;

// The object whose class a component's NAME is looked up in: the nearest
// enclosing inline frame (IsInlineObj), else the root.
function TPasFormBinder.HeaderLookupRoot(AEntry: TFormEntry;
  AObj: Integer): Integer;
var
  LDoc: TPasDfmDoc;
begin
  LDoc := DocOf(AEntry);
  // An index the doc does not hold answers the root, as the siblings do
  // (ObjClassOf, IsInlineObj): the reader keeps it consistent, this is the
  // second line.
  if (AObj <= 0) or (AObj > High(LDoc.Objects)) then
    Exit(0);
  Result := LDoc.Objects[AObj].Parent;
  while (Result > 0) and not IsInlineObj(AEntry, Result) do
    Result := LDoc.Objects[Result].Parent;
  if Result < 0 then
    Result := 0;
end;

// The lookup root in effect INSIDE the object's block - itself for an inline
// frame (its properties' component references are the frame's).
function TPasFormBinder.InnerLookupRoot(AEntry: TFormEntry;
  AObj: Integer): Integer;
begin
  if AObj <= 0 then
    Exit(0);
  if IsInlineObj(AEntry, AObj) then
    Exit(AObj);
  Result := HeaderLookupRoot(AEntry, AObj);
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
  LOwner := ObjClassOf(AEntry, HeaderLookupRoot(AEntry, AObj));
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
        // A property of any visibility: a descendant republishes a protected
        // one (`property Caption;`), and a form file sets it through that.
        if (LSym.Scope = NIL_SCOPE) or ((LSym.Kind <> skProperty) and
           not (LSym.Visibility in [svDefault, svPublished])) then
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
  // `On` and then an upper-case letter, as every event is named: a toolbar
  // component's Boolean `OneOnRow = True` was taken for an event whose
  // method is gone, "the form fails to load", on 49 lines of forms that load.
  Result := (Length(LLast) > 2) and StartsText('On', LLast) and
    CharInSet(LLast[3], ['A'..'Z', '_']);
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
function TPasFormBinder.HeaderVia(AEntry: TFormEntry;
  AObj: Integer): TPasFormSiteVia;
begin
  if (AObj > 0) and (HeaderLookupRoot(AEntry, AObj) > 0) then
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
  LClass := ObjClassOf(AEntry, InnerLookupRoot(AEntry, LId.Obj));
  LName := LowerCase(LDoc.IdentText(LFirst));
  // A value inside an inline frame's block is resolved against the frame.
  if InnerLookupRoot(AEntry, LId.Obj) > 0 then
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
  // ...else, inside an inline frame's block, a component of the FORM: what
  // the frame does not resolve, TReader resolves from the root - the frame
  // named by its own name (`Frame1.Edit1` inside Frame1's block), a sibling
  // frame's component (probed, dcc32 37.0: both bind at run time)...
  if (InnerLookupRoot(AEntry, LId.Obj) > 0) and FieldIn(AEntry.Mid,
     RootClassOf(AEntry), LName, ATMid, ATSym) then
  begin
    if LId.Seg = 0 then
      Exit(True);
    if Walk(FieldClass(ATMid, ATSym)) then
      Exit(True);
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

// Whether two property declarations are one property: each followed up its
// bare redeclarations (`property X;`) to the declaration that writes the type.
function TPasFormBinder.SameProperty(AMid1, ASym1, AMid2, ASym2: Integer): Boolean;

  procedure Up(var AMid, ASym: Integer);
  var
    LPMid, LPSym, LDepth: Integer;
  begin
    for LDepth := 1 to 32 do
    begin
      if not FProj.IsBarePropertyRedecl(AMid, ASym) or
         not FProj.PropertyRedeclPrev(AMid, ASym, LPMid, LPSym) then
        Exit;
      AMid := LPMid;
      ASym := LPSym;
    end;
  end;

begin
  Up(AMid1, ASym1);
  Up(AMid2, ASym2);
  Result := (AMid1 = AMid2) and (ASym1 = ASym2);
end;

{ Whether a form file of AClass's chain - its own, then its ancestors' -
  creates a component named ANameLower at its top (not inside an inline
  frame's block), and of which class. A component needs no field to exist:
  TReader creates it, and FindComponent finds it by Name. }
function TPasFormBinder.CreatedIn(const AClass: TSemaXType;
  const ANameLower: string; out AObjClass: TSemaXType): Boolean;
var
  LK: TSemaXType;
  LEntry: TFormEntry;
  LDoc: TPasDfmDoc;
  LIdx, LGuard: Integer;
begin
  AObjClass := XNil;
  LK := AClass;
  LGuard := 0;
  while XValid(LK) and (LGuard < 64) do
  begin
    LEntry := RootEntryOfClass(LK);
    if LEntry <> nil then
    begin
      LDoc := DocOf(LEntry);
      for LIdx := 1 to High(LDoc.Objects) do
        if SameText(LDoc.ObjectName(LIdx), ANameLower) and
           (HeaderLookupRoot(LEntry, LIdx) = 0) then
        begin
          AObjClass := ObjClassOf(LEntry, LIdx);
          Exit(True);
        end;
    end;
    LK := FProj.CanonTypeX(FProj.AncestorOfX(LK));
    Inc(LGuard);
  end;
  Result := False;
end;

{ Whether the component path ending at AIdent names a component that exists
  at run time though no field chain reaches it: a segment is a field, else a
  component the form files of the class so far create (CreatedIn) - what
  FindNestedComponent walks by Name. From the lookup root, and inside an
  inline frame's block from the form's root too (see ValueTarget). A frame's
  component the designer left without a field read as a dangling reference
  (probed, dcc32 37.0: it binds). }
function TPasFormBinder.ReachedByName(AEntry: TFormEntry;
  AIdent: Integer): Boolean;
var
  LDoc: TPasDfmDoc;
  LId: TPasDfmIdent;
  LFirst: Integer;

  function From(const AClass: TSemaXType): Boolean;
  var
    LC, LNext: TSemaXType;
    LS, LFMid, LFSym: Integer;
    LName: string;
  begin
    Result := False;
    LC := AClass;
    for LS := 0 to LId.Seg do
    begin
      if not XValid(LC) then
        Exit;
      LName := LowerCase(LDoc.IdentText(LFirst + LS));
      if FieldIn(AEntry.Mid, LC, LName, LFMid, LFSym) then
        LC := FieldClass(LFMid, LFSym)
      else if CreatedIn(LC, LName, LNext) then
        LC := LNext   // not CreatedIn(LC, ..., LC): the out clears the const
      else
        Exit;
    end;
    Result := True;
  end;

begin
  LDoc := DocOf(AEntry);
  LId := LDoc.Idents[AIdent];
  LFirst := AIdent - LId.Seg;
  Result := From(ObjClassOf(AEntry, InnerLookupRoot(AEntry, LId.Obj))) or
    ((InnerLookupRoot(AEntry, LId.Obj) > 0) and From(RootClassOf(AEntry)));
end;

// The declared type of AClass's property ANameLower (a bare redeclaration
// followed to the one that writes it) - `Font` -> TFont; XNil when AClass
// has no property of that name (AFound False) or it is not class-typed.
function TPasFormBinder.PropClassOf(AMid: Integer; const AClass: TSemaXType;
  const ANameLower: string; out AFound: Boolean): TSemaXType;
var
  LPMid, LPSym, LCtx: Integer;
begin
  Result := XNil;
  AFound := XValid(AClass) and FProj.FindMemberX(AMid, AClass, ANameLower,
    LPMid, LPSym, LCtx) and (LPMid >= 0) and (LPSym <> NIL_SYM) and
    (FProj.Model(LPMid).Symbols[LPSym].Kind = skProperty);
  if AFound then
    Result := FProj.CanonTypeX(FProj.SymDeclTypeX(LPMid, LPSym));
end;

{ The class TReader looks segment ASeg of property AProp up in: the object's
  class for a property set on the object itself, then through each segment
  before ASeg to the class-typed property's type (`Font.Name`: TFont), and
  for a property inside a collection item the item class its collection
  holds (ItemClassOf). XNil where a link does not resolve.

  ADeclared says the class is a DECLARED type (a property's, an item's)
  rather than the one the instance read has: that may be a descendant - a
  collection created with an item subclass, a property object whose class
  another property chooses - whose own properties the line sets too. A
  sibling line naming the class (`PropertiesClassName = 'TcxCurrencyEdit
  Properties'` beside `Properties.DisplayFormat`, the DevExpress editors'
  convention: its setter creates that class) settles it: that class, not
  declared. AOpen says a link before ASeg was a declared type WITHOUT a
  property of that segment's name: the class the rest of the path is read in
  is chosen at run time (TActionClientItem.CommandProperties is a
  TCommandProperties, its CommandStyle makes it a TTextProperties or a
  TMenuProperties, each with a Font), so the result is XNil and nothing is
  known. }
function TPasFormBinder.PropHolder(AEntry: TFormEntry; AProp, ASeg: Integer;
  out ADeclared, AOpen: Boolean): TSemaXType;
var
  LDoc: TPasDfmDoc;
  LSeg: Integer;
  LFound: Boolean;
  LNamed: TSemaXType;
begin
  Result := XNil;
  AOpen := False;
  ADeclared := False;
  LDoc := DocOf(AEntry);
  if (AProp < 0) or (AProp > High(LDoc.Props)) then
    Exit;
  ADeclared := LDoc.Props[AProp].Owner >= 0;
  if ADeclared then
    Result := ItemClassOf(AEntry, LDoc.Props[AProp].Owner, AOpen)
  else
    Result := ObjClassOf(AEntry, LDoc.Props[AProp].Obj);
  for LSeg := 0 to ASeg - 1 do
  begin
    if not XValid(Result) then
      Exit;
    // A miss in the object's own class is a form that fails to load, not an
    // open link.
    Result := PropClassOf(AEntry.Mid, Result,
      LowerCase(LDoc.IdentText(LDoc.Props[AProp].FirstIdent + LSeg)), LFound);
    if not LFound and ADeclared then
      AOpen := True;
    ADeclared := True;
    LNamed := ClassNamedBeside(AEntry, AProp, LSeg);
    if XValid(LNamed) and XValid(Result) and
       FProj.XDescendsFrom(LNamed, Result) then
    begin
      Result := LNamed;
      ADeclared := False;
    end;
  end;
end;

{ The class a sibling line names for segment ASeg of property AProp: on the
  same object (and collection item), the path up to ASeg with `ClassName`
  appended to its last segment, a string - `PropertiesClassName =
  'TcxCurrencyEditProperties'` for `Properties.DisplayFormat`. Looked up as
  the form's unit sees it (the designer adds the class's unit to its uses);
  XNil when there is no such line or the name does not resolve. }
function TPasFormBinder.ClassNamedBeside(AEntry: TFormEntry;
  AProp, ASeg: Integer): TSemaXType;
var
  LDoc: TPasDfmDoc;
  LP: TPasDfmProp;
  LQ, LDir, LS, LFrom, LTo: Integer;
  LMatch: Boolean;
  LLine, LName: string;
begin
  Result := XNil;
  LDoc := DocOf(AEntry);
  LP := LDoc.Props[AProp];
  LName := LowerCase(LDoc.IdentText(LP.FirstIdent + ASeg)) + 'classname';
  // An object's properties are read before its children, so its lines are
  // contiguous but for its collection items: walk out from AProp both ways
  // while the object is the same.
  for LDir := -1 to 1 do
  begin
    if LDir = 0 then
      Continue;
    LQ := AProp + LDir;
    while (LQ >= 0) and (LQ <= High(LDoc.Props)) and
          (LDoc.Props[LQ].Obj = LP.Obj) do
    begin
      if (LDoc.Props[LQ].Owner = LP.Owner) and (LDoc.Props[LQ].Item = LP.Item)
         and (LDoc.Props[LQ].SegCount = ASeg + 1) and
         (LDoc.Props[LQ].StrOffset >= 0) and SameText(LDoc.IdentText(
         LDoc.Props[LQ].FirstIdent + ASeg), LName) then
      begin
        LMatch := True;
        for LS := 0 to ASeg - 1 do
          if not SameText(LDoc.IdentText(LDoc.Props[LQ].FirstIdent + LS),
             LDoc.IdentText(LP.FirstIdent + LS)) then
            LMatch := False;
        if LMatch then
        begin
          // The value is one plain literal (StrOffset): the text between
          // its quotes on that line.
          LLine := LDoc.LineText(LDoc.LineOf(LDoc.Props[LQ].StrOffset));
          LFrom := LDoc.ColOf(LDoc.Props[LQ].StrOffset);
          if (LFrom < 1) or (LFrom > Length(LLine)) or
             (LLine[LFrom] <> '''') then
            Exit;
          LTo := LFrom + 1;
          while (LTo <= Length(LLine)) and (LLine[LTo] <> '''') do
            Inc(LTo);
          Exit(TypeInUnit(AEntry.Mid,
            LowerCase(Copy(LLine, LFrom + 1, LTo - LFrom - 1))));
        end;
      end;
      Inc(LQ, LDir);
    end;
  end;
end;

{ The item class of the collection property AColl's value (`Panels = <`):
  the type of its collection class's `default` array property, which a
  collection written for one item class declares with that class
  (TStatusPanels.Items: TStatusPanel, TActionClients.ActionClients:
  TActionClientItem), else of TCollection's `Items`, TCollectionItem - whose
  descendants' properties are then taken as PropHolder's ADeclared says.
  AOpen as PropHolder's, for the collection's own path. }
function TPasFormBinder.ItemClassOf(AEntry: TFormEntry; AColl: Integer;
  out AOpen: Boolean): TSemaXType;
var
  LDoc: TPasDfmDoc;
  LLast: Integer;
  LDeclared, LFound: Boolean;
  LHolder, LOwner: TSemaXType;
  LPMid, LPSym: Integer;
begin
  LDoc := DocOf(AEntry);
  LLast := LDoc.Props[AColl].SegCount - 1;
  LHolder := PropHolder(AEntry, AColl, LLast, LDeclared, AOpen);
  Result := PropClassOf(AEntry.Mid, LHolder,
    LowerCase(LDoc.IdentText(LDoc.Props[AColl].FirstIdent + LLast)), LFound);
  if not LFound and XValid(LHolder) and LDeclared then
    AOpen := True;
  if XValid(Result) and FProj.DefaultArrayPropX(Result, LPMid, LPSym,
     LOwner) then
    Result := FProj.CanonTypeX(FProj.SymDeclTypeX(LPMid, LPSym))
  else
    Result := PropClassOf(AEntry.Mid, Result, 'items', LFound);
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
begin
  Result := SitesOf(ATMid, ASym, ARename, nil, AError);
end;

function TPasFormBinder.SitesOf(ATMid, ASym: Integer; ARename: Boolean;
  const ATogether: TArray<TPasExtRef>;
  out AError: string): TArray<TPasFormSite>;
var
  LShape: TSymShape;
  LOwner, LSelf, LClass: TSemaXType;
  LNameLower: string;
  LList: TList<TPasFormSite>;
  LEntry: TFormEntry;
  LDoc: TPasDfmDoc;
  LIdx, LTMid, LTSym, LCtx: Integer;
  LId: TPasDfmIdent;
  LIsMethod: Boolean;
  LVia: TPasFormSiteVia;
  LDeclared, LOpen: Boolean;
  LSite: TPasFormSite;

  function Where: string;
  begin
    Result := Format('%s line %d', [TPath.GetFileName(LEntry.Path),
      LDoc.LineOf(LId.Offset)]);
  end;

  // Whether the method that line binds for its own form's class is renamed
  // with this one.
  function BoundRenamedWith: Boolean;
  var
    LBMid, LBSym: Integer;
    LBIsMethod: Boolean;
    LBVia: TPasFormSiteVia;
  begin
    Result := False;
    if not ValueTarget(LEntry, LIdx, LBMid, LBSym, LBIsMethod, LBVia) or
       not LBIsMethod then
      Exit;
    for var LR in ATogether do
      if (LR.UnitId = LBMid) and (LR.Sym = LBSym) then
        Exit(True);
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
                  LClass := ObjClassOf(LEntry, HeaderLookupRoot(LEntry, LId.Obj));
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
                      HeaderVia(LEntry, LId.Obj)));
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
                if ARename and not BoundRenamedWith then
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
                 (IsInlineObj(LEntry, LId.Obj) or
                  (HeaderLookupRoot(LEntry, LId.Obj) > 0)) then
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
            // A reference search: a line setting the property on an object
            // whose class HAS it - found from that class, a bare
            // redeclaration taken for the property it republishes, as
            // FindReferences takes it. TReader sets it by name: rename or
            // remove the property and the form fails to load, after a clean
            // compile. A sub-property (`Font.Name`) is looked up in the
            // class of the property before it, an item's property in the
            // item class of its collection (PropHolder). Where that class is
            // a declared type and has no property of the name at all, the
            // instance read may be a descendant's, and so may the class a
            // link before it is read in (AOpen): the line is kept as one
            // that MAY set it (Unsure) - left out, it is a silent miss; a
            // namesake elsewhere gets it too.
            if not ARename and (LId.Role = dirPropName) then
            begin
              LClass := PropHolder(LEntry, LId.Prop, LId.Seg, LDeclared,
                LOpen);
              LSite := SiteOf(LEntry, LIdx, fskProperty,
                HeaderVia(LEntry, LId.Obj));
              LSite.Unsure := True;
              if not XValid(LClass) then
              begin
                if LOpen and (FProj.Model(ATMid).Symbols[ASym].Visibility in
                   [svDefault, svPublished]) then
                  LList.Add(LSite);
                Continue;
              end;
              if FProj.FindMemberX(LEntry.Mid, LClass, LNameLower, LTMid,
                 LTSym, LCtx) and (LTMid >= 0) and (LTSym <> NIL_SYM) then
              begin
                if (FProj.Model(LTMid).Symbols[LTSym].Kind = skProperty) and
                   (FProj.Model(LTMid).Symbols[LTSym].Visibility in
                   [svDefault, svPublished]) and
                   SameProperty(LTMid, LTSym, ATMid, ASym) then
                  LList.Add(SiteOf(LEntry, LIdx, fskProperty,
                    HeaderVia(LEntry, LId.Obj)));
              end
              else if LDeclared and not SameType(LClass, LOwner) and
                FProj.XDescendsFrom(LOwner, LClass) and
                (FProj.Model(ATMid).Symbols[ASym].Visibility in [svDefault,
                svPublished]) then
                LList.Add(LSite);
            end
            // A rename: refused where a form file may set it - for a published
            // property, as before properties of any visibility were searched.
            else if ARename and (LId.Role = dirPropName) and
              (FProj.Model(ATMid).Symbols[ASym].Visibility in [svDefault,
              svPublished]) then
            begin
              // Excluded only when it is certainly some OTHER class's
              // property: the class the segment is looked up in is known
              // and is not the owner or a descendant of it - nor, for a
              // declared type, an ancestor, whose instance may be the
              // owner's (PropHolder).
              LClass := PropHolder(LEntry, LId.Prop, LId.Seg, LDeclared,
                LOpen);
              if XValid(LClass) and not FProj.XDescendsFrom(LClass, LOwner) and
                 not (LDeclared and FProj.XDescendsFrom(LOwner, LClass)) then
                Continue;
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
      if (HeaderLookupRoot(LEntry, LObj) = 0) and
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
  AInfo.TrailingLine := LDoc.TrailingLine;
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
        LOwner := ObjClassOf(LEntry, HeaderLookupRoot(LEntry, LObj));
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
      LB.PropName := LDoc.ItemPath(LId.Prop);
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
      else if (LId.SegCount = 1) and SameText(LB.Value, 'nil') and
        IsEventProp(LDoc, LId.Prop) then
      begin
        // Cleared: TReader sets the event to nil - nothing is missing.
        LB.IsMethod := True;
        LB.Cleared := True;
        LB.TMid := NIL_SYM;
        LB.TSym := NIL_SYM;
      end
      else if not XValid(AInfo.RootClass) or not XValid(ObjClassOf(LEntry,
        InnerLookupRoot(LEntry, LId.Obj))) then
        Continue   // nothing to look the name up in: unknown, not missing
      else if (LId.SegCount = 1) and (SameText(LB.Value, 'True') or
        SameText(LB.Value, 'False')) then
        Continue   // a Boolean's value, whatever the property is called
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
        LB.NoField := ReachedByName(LEntry, LIdx);
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
