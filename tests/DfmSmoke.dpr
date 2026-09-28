program DfmSmoke;

{ Form files (.dfm) bound to the symbols they name - PasTree.Dfm reads them,
  PasTree.Sema.Dfm binds them, TPasNavigator lists them (FindFormSites,
  FindReferences' AFormFiles) and renames them (PlanRename).

  The fixture is the shapes a real project is made of: a form with a
  handler, a component reference and a data module reached by its root
  Name; a DESCENDANT form (`inherited`) that reuses the ancestor's handler;
  an INLINE frame whose children belong to the frame class while their
  handlers belong to the host; a BINARY form file; a MALFORMED one. Every
  position below is counted from the fixture text, so a check that fails
  names a real line. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.Sema.Model in '..\source\PasTree.Sema.Model.pas',
  PasTree.Sema.Project in '..\source\PasTree.Sema.Project.pas',
  PasTree.Dfm in '..\source\PasTree.Dfm.pas',
  PasTree.Sema.Dfm in '..\source\PasTree.Sema.Dfm.pas',
  PasTree.Sema.Nav in '..\source\PasTree.Sema.Nav.pas',
  PasTree.TestKit in 'PasTree.TestKit.pas';

const
  CRLF = #13#10;

  UNIT_SYS =
    'unit System;'#10 +
    'interface'#10 +
    'type'#10 +
    '  TObject = class'#10 +
    '    constructor Create;'#10 +
    '  end;'#10 +
    'implementation'#10 +
    'constructor TObject.Create;'#10 +
    'begin'#10 +
    'end;'#10 +
    'end.'#10;

  // The smallest VCL that streams: TPersistent's published default section,
  // an event type, an enum-typed and a component-typed property.
  UNIT_VCL =
    'unit FixVcl;'#10 +                                          // 1
    'interface'#10 +                                             // 2
    'type'#10 +                                                  // 3
    '  TNotifyEvent = procedure(Sender: TObject) of object;'#10 + // 4
    '  TAlign = (alNone, alClient);'#10 +                        // 5  alClient col 21
    '  TPersistent = class'#10 +                                 // 6
    '  end;'#10 +                                                // 7
    '  TComponent = class(TPersistent)'#10 +                     // 8
    '  end;'#10 +                                                // 9
    '  TAction = class(TComponent)'#10 +                         // 10
    '  private'#10 +                                             // 11
    '    FOnExecute: TNotifyEvent;'#10 +                         // 12
    '  published'#10 +                                           // 13
    '    property OnExecute: TNotifyEvent read FOnExecute write FOnExecute;'#10 + // 14
    '  end;'#10 +                                                // 15
    '  TControl = class(TComponent)'#10 +                        // 16
    '  private'#10 +                                             // 17
    '    FAlign: TAlign;'#10 +                                   // 18
    '    FAction: TAction;'#10 +                                 // 19
    '    FCaption: string;'#10 +                                 // 20
    '    FOnClick: TNotifyEvent;'#10 +                           // 21
    '  published'#10 +                                           // 22
    '    property Align: TAlign read FAlign write FAlign;'#10 +  // 23
    '    property Action: TAction read FAction write FAction;'#10 + // 24
    '    property Caption: string read FCaption write FCaption;'#10 + // 25
    '    property OnClick: TNotifyEvent read FOnClick write FOnClick;'#10 + // 26
    '  end;'#10 +                                                // 27
    '  TWinControl = class(TControl)'#10 +                       // 28
    '  end;'#10 +                                                // 29
    '  TButton = class(TWinControl)'#10 +                        // 30
    '  end;'#10 +                                                // 31
    '  TEdit = class(TWinControl)'#10 +                          // 32
    '  private'#10 +                                             // 33
    '    FText: string;'#10 +                                    // 34
    '  published'#10 +                                           // 35
    '    property Text: string read FText write FText;'#10 +     // 36
    '  end;'#10 +                                                // 37
    '  TLabel = class(TControl)'#10 +                            // 38
    '  private'#10 +                                             // 39
    '    FFocusControl: TWinControl;'#10 +                       // 40
    '  published'#10 +                                           // 41
    '    property FocusControl: TWinControl read FFocusControl write FFocusControl;'#10 + // 42
    '  end;'#10 +                                                // 43
    '  TForm = class(TWinControl)'#10 +                          // 44
    '  end;'#10 +                                                // 45
    '  TFrame = class(TWinControl)'#10 +                         // 46
    '  end;'#10 +                                                // 47
    '  TDataModule = class(TComponent)'#10 +                     // 48
    '  end;'#10 +                                                // 49
    'implementation'#10 +                                        // 50
    'end.'#10;                                                   // 51

  UNIT_DATA =
    'unit FixData;'#10 +                                         // 1
    'interface'#10 +                                             // 2
    'uses FixVcl;'#10 +                                          // 3
    'type'#10 +                                                  // 4
    '  TFixData = class(TDataModule)'#10 +                       // 5
    '    Action1: TAction;'#10 +                                 // 6  Action1 col 5
    '    procedure Action1Execute(Sender: TObject);'#10 +        // 7  col 15
    '  published'#10 +                                           // 8
    '    Action2: TAction;'#10 +                                 // 9  Action2 col 5
    '    procedure Action2Execute(Sender: TObject);'#10 +        // 10 col 15
    '  end;'#10 +                                                // 11
    'var'#10 +                                                   // 12
    '  FixData: TFixData;'#10 +                                  // 13
    'implementation'#10 +                                        // 14
    '{$R *.dfm}'#10 +                                            // 15
    'procedure TFixData.Action1Execute(Sender: TObject);'#10 +   // 16
    'begin'#10 +                                                 // 17
    'end;'#10 +                                                  // 18
    'procedure TFixData.Action2Execute(Sender: TObject);'#10 +   // 19
    'begin'#10 +                                                 // 20
    'end;'#10 +                                                  // 21
    'end.'#10;                                                   // 22

  // Action1 has a client (FixBase's Button1.Action), Action2 has none - an
  // action's caption follows its name only without one.
  DFM_DATA =
    'object FixData: TFixData' + CRLF +                          // 1
    '  object Action1: TAction' + CRLF +                         // 2  Action1 col 10
    '    OnExecute = Action1Execute' + CRLF +                    // 3  col 17
    '    Caption = ''Action1''' + CRLF +                         // 4
    '  end' + CRLF +                                             // 5
    '  object Action2: TAction' + CRLF +                         // 6  Action2 col 10
    '    Caption = ''Action2''' + CRLF +                         // 7  text col 16
    '    OnExecute = Action2Execute' + CRLF +                    // 8  col 17
    '  end' + CRLF +                                             // 9
    'end' + CRLF;                                                // 10

  // What a component's rename carries along: its handlers named after it
  // (CapButtonClick, shared with OtherButton; CapEditClick) and a caption
  // or text that reads its name - and what it does not: the form's own
  // caption, a caption in another case, one that is not a plain literal, a
  // handler not named after it (SharedClick).
  UNIT_CAP =
    'unit FixCap;'#10 +                                          // 1
    'interface'#10 +                                             // 2
    'uses FixVcl;'#10 +                                          // 3
    'type'#10 +                                                  // 4
    '  TFixCapForm = class(TForm)'#10 +                          // 5
    '    CapButton: TButton;'#10 +                               // 6  col 5
    '    CapEdit: TEdit;'#10 +                                   // 7  col 5
    '    LowButton: TButton;'#10 +                               // 8  col 5
    '    SplitButton: TButton;'#10 +                             // 9  col 5
    '    PlusButton: TButton;'#10 +                              // 10 col 5
    '    OtherButton: TButton;'#10 +                             // 11 col 5
    '    procedure CapButtonClick(Sender: TObject);'#10 +        // 12 col 15
    '    procedure CapEditClick(Sender: TObject);'#10 +          // 13 col 15
    '    procedure SharedClick(Sender: TObject);'#10 +           // 14 col 15
    '  end;'#10 +                                                // 15
    'implementation'#10 +                                        // 16
    '{$R *.dfm}'#10 +                                            // 17
    'procedure TFixCapForm.CapButtonClick(Sender: TObject);'#10 + // 18 col 23
    'begin'#10 +                                                 // 19
    '  CapEditClick(Sender);'#10 +                               // 20 col 3
    'end;'#10 +                                                  // 21
    'procedure TFixCapForm.CapEditClick(Sender: TObject);'#10 +  // 22 col 23
    'begin'#10 +                                                 // 23
    '  CapButtonClick(nil);'#10 +                                // 24 col 3
    'end;'#10 +                                                  // 25
    'procedure TFixCapForm.SharedClick(Sender: TObject);'#10 +   // 26
    'begin'#10 +                                                 // 27
    'end;'#10 +                                                  // 28
    'end.'#10;                                                   // 29

  DFM_CAP =
    'object FixCapForm: TFixCapForm' + CRLF +                    // 1
    '  Caption = ''CapButton''' + CRLF +                         // 2  the form's own
    '  object CapButton: TButton' + CRLF +                       // 3  col 10
    '    Caption = ''CapButton''' + CRLF +                       // 4  text col 16
    '    OnClick = CapButtonClick' + CRLF +                      // 5  col 15
    '  end' + CRLF +                                             // 6
    '  object CapEdit: TEdit' + CRLF +                           // 7  col 10
    '    Text = ''CapEdit''' + CRLF +                            // 8  text col 13
    '    OnClick = CapEditClick' + CRLF +                        // 9  col 15
    '  end' + CRLF +                                             // 10
    '  object LowButton: TButton' + CRLF +                       // 11
    '    Caption = ''lowbutton''' + CRLF +                       // 12
    '    OnClick = SharedClick' + CRLF +                         // 13
    '  end' + CRLF +                                             // 14
    '  object SplitButton: TButton' + CRLF +                     // 15
    '    Caption = ''SplitButton''#13''x''' + CRLF +             // 16
    '  end' + CRLF +                                             // 17
    '  object PlusButton: TButton' + CRLF +                      // 18
    '    Caption = ''Plus'' +' + CRLF +                          // 19
    '      ''Button''' + CRLF +                                  // 20
    '  end' + CRLF +                                             // 21
    '  object OtherButton: TButton' + CRLF +                     // 22
    '    Caption = ''Other''' + CRLF +                           // 23
    '    OnClick = CapButtonClick' + CRLF +                      // 24 col 15
    '  end' + CRLF +                                             // 25
    'end' + CRLF;                                                // 26

  UNIT_FRAME =
    'unit FixFrame;'#10 +                                        // 1
    'interface'#10 +                                             // 2
    'uses FixVcl;'#10 +                                          // 3
    'type'#10 +                                                  // 4
    '  TFixFrame = class(TFrame)'#10 +                           // 5  TFixFrame col 3
    '    FrameEdit: TEdit;'#10 +                                 // 6  col 5
    '    FrameButton: TButton;'#10 +                             // 7  col 5
    '    procedure FrameButtonClick(Sender: TObject);'#10 +      // 8  col 15
    '  private'#10 +                                             // 9
    '    FTitle: string;'#10 +                                   // 10
    '  published'#10 +                                           // 11
    '    property Title: string read FTitle write FTitle;'#10 +  // 12  Title col 14
    '  end;'#10 +                                                // 13
    'implementation'#10 +                                        // 14
    '{$R *.dfm}'#10 +                                            // 15
    'procedure TFixFrame.FrameButtonClick(Sender: TObject);'#10 + // 16
    'begin'#10 +                                                 // 17
    '  FrameEdit.Text := ''x'';'#10 +                            // 18
    'end;'#10 +                                                  // 19
    'end.'#10;                                                   // 20

  DFM_FRAME =
    'object FixFrame: TFixFrame' + CRLF +                        // 1  TFixFrame col 18
    '  object FrameEdit: TEdit' + CRLF +                         // 2  FrameEdit col 10
    '  end' + CRLF +                                             // 3
    '  object FrameButton: TButton' + CRLF +                     // 4
    '    OnClick = FrameButtonClick' + CRLF +                    // 5  col 15
    '  end' + CRLF +                                             // 6
    'end' + CRLF;                                                // 7

  UNIT_BASE =
    'unit FixBase;'#10 +                                         // 1
    'interface'#10 +                                             // 2
    'uses FixVcl, FixFrame;'#10 +                                // 3
    'type'#10 +                                                  // 4
    '  TFixBaseForm = class(TForm)'#10 +                         // 5  TFixBaseForm col 3
    '    Label1: TLabel;'#10 +                                   // 6
    '    Button1: TButton;'#10 +                                 // 7  Button1 col 5
    '    Edit1: TEdit;'#10 +                                     // 8  Edit1 col 5
    '    Label2: TLabel;'#10 +                                   // 9
    '    Frame11: TFixFrame;'#10 +                               // 10 Frame11 col 5
    '    procedure Button1Click(Sender: TObject);'#10 +          // 11 col 15
    '    procedure Frame11FrameButtonClick(Sender: TObject);'#10 + // 12 col 15
    '  private'#10 +                                             // 13
    '    FCount: Integer;'#10 +                                  // 14 FCount col 5
    '  end;'#10 +                                                // 15
    'var'#10 +                                                   // 16
    '  FixBaseForm: TFixBaseForm;'#10 +                          // 17
    'implementation'#10 +                                        // 18
    'uses FixData;'#10 +                                         // 19
    '{$R *.dfm}'#10 +                                            // 20
    'procedure TFixBaseForm.Button1Click(Sender: TObject);'#10 + // 21 Button1Click col 24
    'begin'#10 +                                                 // 22
    '  Button1.Caption := ''Clicked'';'#10 +                     // 23 Button1 col 3
    '  Inc(FCount);'#10 +                                        // 24
    'end;'#10 +                                                  // 25
    'procedure TFixBaseForm.Frame11FrameButtonClick(Sender: TObject);'#10 + // 26
    'begin'#10 +                                                 // 27
    '  Button1Click(Sender);'#10 +                               // 28 col 3
    'end;'#10 +                                                  // 29
    'end.'#10;                                                   // 30

  DFM_BASE =
    'object FixBaseForm: TFixBaseForm' + CRLF +                  // 1  TFixBaseForm col 21
    '  Caption = ''Base''' + CRLF +                              // 2
    '  object Label1: TLabel' + CRLF +                           // 3
    '    FocusControl = Edit1' + CRLF +                          // 4  Edit1 col 20
    '  end' + CRLF +                                             // 5
    '  object Button1: TButton' + CRLF +                         // 6  Button1 col 10
    '    Action = FixData.Action1' + CRLF +                      // 7  Action1 col 22
    '    OnClick = Button1Click' + CRLF +                        // 8  col 15
    '  end' + CRLF +                                             // 9
    '  object Edit1: TEdit' + CRLF +                             // 10 Edit1 col 10
    '    Align = alClient' + CRLF +                              // 11 alClient col 13
    '  end' + CRLF +                                             // 12
    '  object Label2: TLabel' + CRLF +                           // 13
    '    FocusControl = Frame11.FrameEdit' + CRLF +              // 14 Frame11 col 20, FrameEdit col 28
    '  end' + CRLF +                                             // 15
    '  inline Frame11: TFixFrame' + CRLF +                       // 16 Frame11 col 10, TFixFrame col 19
    '    Title = ''Hi''' + CRLF +                                // 17 Title col 5
    '    inherited FrameEdit: TEdit' + CRLF +                    // 18 FrameEdit col 15
    '      Text = ''y''' + CRLF +                                // 19
    '    end' + CRLF +                                           // 20
    '    inherited FrameButton: TButton' + CRLF +                // 21
    '      OnClick = Frame11FrameButtonClick' + CRLF +           // 22 col 17
    '    end' + CRLF +                                           // 23
    '  end' + CRLF +                                             // 24
    'end' + CRLF;                                                // 25

  UNIT_CHILD =
    'unit FixChild;'#10 +                                        // 1
    'interface'#10 +                                             // 2
    'uses FixVcl, FixBase;'#10 +                                 // 3
    'type'#10 +                                                  // 4
    '  TFixChildForm = class(TFixBaseForm)'#10 +                 // 5
    '    Button2: TButton;'#10 +                                 // 6  Button2 col 5
    '  end;'#10 +                                                // 7
    'implementation'#10 +                                        // 8
    '{$R *.dfm}'#10 +                                            // 9
    'end.'#10;                                                   // 10

  // A descendant with no form file of its own that REDECLARES the handler its
  // ancestors' forms bind by name: an instance of it reads FixBase.dfm and
  // FixChild.dfm, and MethodAddress finds its own Button1Click.
  UNIT_GRAND =
    'unit FixGrand;'#10 +                                        // 1
    'interface'#10 +                                             // 2
    'uses FixVcl, FixChild;'#10 +                                // 3
    'type'#10 +                                                  // 4
    '  TFixGrandForm = class(TFixChildForm)'#10 +                // 5
    '    procedure Button1Click(Sender: TObject);'#10 +          // 6  col 15
    '  end;'#10 +                                                // 7
    'implementation'#10 +                                        // 8
    'procedure TFixGrandForm.Button1Click(Sender: TObject);'#10 + // 9
    'begin'#10 +                                                 // 10
    'end;'#10 +                                                  // 11
    'end.'#10;                                                   // 12

  // Button3 and Label3 have no field, and name what nothing answers: a
  // handler no class of the chain declares, a component path whose head is
  // no component and no module (DescribeForm lists both as unbound).
  DFM_CHILD =
    'inherited FixChildForm: TFixChildForm' + CRLF +             // 1
    '  inherited Button1: TButton' + CRLF +                      // 2  Button1 col 13
    '    Caption = ''Child''' + CRLF +                           // 3
    '  end' + CRLF +                                             // 4
    '  object Button2: TButton' + CRLF +                         // 5  Button2 col 10
    '    OnClick = Button1Click' + CRLF +                        // 6  col 15
    '  end' + CRLF +                                             // 7
    '  object Button3: TButton' + CRLF +                         // 8
    '    OnClick = MissingClick' + CRLF +                        // 9
    '  end' + CRLF +                                             // 10
    '  object Label3: TLabel' + CRLF +                           // 11
    '    FocusControl = Nowhere.Edit1' + CRLF +                  // 12
    '  end' + CRLF +                                             // 13
    'end' + CRLF;                                                // 14

  UNIT_BIN =
    'unit FixBin;'#10 +                                          // 1
    'interface'#10 +                                             // 2
    'uses FixVcl;'#10 +                                          // 3
    'type'#10 +                                                  // 4
    '  TFixBinForm = class(TForm)'#10 +                          // 5
    '    BinButton: TButton;'#10 +                               // 6
    '    procedure BinButtonClick(Sender: TObject);'#10 +        // 7  col 15
    '  end;'#10 +                                                // 8
    'implementation'#10 +                                        // 9
    '{$R *.dfm}'#10 +                                            // 10
    'procedure TFixBinForm.BinButtonClick(Sender: TObject);'#10 + // 11
    'begin'#10 +                                                 // 12
    'end;'#10 +                                                  // 13
    'end.'#10;                                                   // 14

  // Written through ObjectTextToResource: the binary form file an old
  // project still has.
  DFM_BIN_TEXT =
    'object FixBinForm: TFixBinForm' + CRLF +
    '  object BinButton: TButton' + CRLF +
    '    OnClick = BinButtonClick' + CRLF +
    '  end' + CRLF +
    'end' + CRLF;

  UNIT_BROKEN =
    'unit FixBroken;'#10 +                                       // 1
    'interface'#10 +                                             // 2
    'uses FixVcl;'#10 +                                          // 3
    'type'#10 +                                                  // 4
    '  TFixBrokenForm = class(TForm)'#10 +                       // 5
    '    BrokenButton: TButton;'#10 +                            // 6  col 5
    '  end;'#10 +                                                // 7
    'implementation'#10 +                                        // 8
    '{$R *.dfm}'#10 +                                            // 9
    'end.'#10;                                                   // 10

  // An unterminated string on line 3: TParser stops there.
  DFM_BROKEN =
    'object FixBrokenForm: TFixBrokenForm' + CRLF +              // 1
    '  object BrokenButton: TButton' + CRLF +                    // 2  col 10
    '    Caption = ''unterminated' + CRLF +                      // 3
    '  end' + CRLF +                                             // 4
    'end' + CRLF;                                                // 5

  // A frame embedded in a host, and the host's descendant and grandchild
  // reopening it as `inherited Pane1` - the frame's block all the same (the
  // component is csInline since the host's `inline` created it). Panel1 is
  // the control case: a plain `inherited` object, its children the form's.
  UNIT_PANE =
    'unit FixPane;'#10 +                                         // 1
    'interface'#10 +                                             // 2
    'uses FixVcl;'#10 +                                          // 3
    'type'#10 +                                                  // 4
    '  TFixPane = class(TFrame)'#10 +                            // 5
    '    PaneEdit: TEdit;'#10 +                                  // 6  col 5
    '  end;'#10 +                                                // 7
    'implementation'#10 +                                        // 8
    '{$R *.dfm}'#10 +                                            // 9
    'end.'#10;                                                   // 10

  DFM_PANE =
    'object FixPane: TFixPane' + CRLF +                          // 1
    '  object PaneEdit: TEdit' + CRLF +                          // 2  col 10
    '  end' + CRLF +                                             // 3
    'end' + CRLF;                                                // 4

  UNIT_HOST =
    'unit FixHost;'#10 +                                         // 1
    'interface'#10 +                                             // 2
    'uses FixVcl, FixPane;'#10 +                                 // 3
    'type'#10 +                                                  // 4
    '  TFixHostForm = class(TForm)'#10 +                         // 5
    '    Panel1: TWinControl;'#10 +                              // 6
    '    HostEdit: TEdit;'#10 +                                  // 7  col 5
    '    Pane1: TFixPane;'#10 +                                  // 8  col 5
    '    procedure HostPaneClick(Sender: TObject);'#10 +         // 9  col 15
    '  end;'#10 +                                                // 10
    'implementation'#10 +                                        // 11
    '{$R *.dfm}'#10 +                                            // 12
    'procedure TFixHostForm.HostPaneClick(Sender: TObject);'#10 + // 13
    'begin'#10 +                                                 // 14
    'end;'#10 +                                                  // 15
    'end.'#10;                                                   // 16

  DFM_HOST =
    'object FixHostForm: TFixHostForm' + CRLF +                  // 1
    '  object Panel1: TWinControl' + CRLF +                      // 2
    '    object HostEdit: TEdit' + CRLF +                        // 3  col 12
    '    end' + CRLF +                                           // 4
    '  end' + CRLF +                                             // 5
    '  inline Pane1: TFixPane' + CRLF +                          // 6  Pane1 col 10
    '  end' + CRLF +                                             // 7
    'end' + CRLF;                                                // 8

  UNIT_HOSTKID =
    'unit FixHostKid;'#10 +                                      // 1
    'interface'#10 +                                             // 2
    'uses FixVcl, FixHost;'#10 +                                 // 3
    'type'#10 +                                                  // 4
    '  TFixHostKidForm = class(TFixHostForm)'#10 +               // 5
    '  end;'#10 +                                                // 6
    'implementation'#10 +                                        // 7
    '{$R *.dfm}'#10 +                                            // 8
    'end.'#10;                                                   // 9

  DFM_HOSTKID =
    'inherited FixHostKidForm: TFixHostKidForm' + CRLF +         // 1
    '  inherited Panel1: TWinControl' + CRLF +                   // 2
    '    inherited HostEdit: TEdit' + CRLF +                     // 3  col 15
    '      Text = ''k''' + CRLF +                                // 4
    '    end' + CRLF +                                           // 5
    '  end' + CRLF +                                             // 6
    '  inherited Pane1: TFixPane' + CRLF +                       // 7  Pane1 col 13
    '    inherited PaneEdit: TEdit' + CRLF +                     // 8  col 15
    '      OnClick = HostPaneClick' + CRLF +                     // 9  col 17
    '    end' + CRLF +                                           // 10
    '  end' + CRLF +                                             // 11
    'end' + CRLF;                                                // 12

  UNIT_HOSTGRAND =
    'unit FixHostGrand;'#10 +                                    // 1
    'interface'#10 +                                             // 2
    'uses FixVcl, FixHostKid;'#10 +                              // 3
    'type'#10 +                                                  // 4
    '  TFixHostGrandForm = class(TFixHostKidForm)'#10 +          // 5
    '  end;'#10 +                                                // 6
    'implementation'#10 +                                        // 7
    '{$R *.dfm}'#10 +                                            // 8
    'end.'#10;                                                   // 9

  DFM_HOSTGRAND =
    'inherited FixHostGrandForm: TFixHostGrandForm' + CRLF +     // 1
    '  inherited Pane1: TFixPane' + CRLF +                       // 2
    '    inherited PaneEdit: TEdit' + CRLF +                     // 3  col 15
    '      Text = ''g''' + CRLF +                                // 4
    '    end' + CRLF +                                           // 5
    '  end' + CRLF +                                             // 6
    'end' + CRLF;                                                // 7

  // Component paths TReader resolves by NAME (probed, dcc32 37.0 - all three
  // bind at run time): a frame's component with no field, a path headed by
  // the frame's own name inside its block, a sibling frame's component from
  // inside another frame's block.
  UNIT_TRAY =
    'unit FixTray;'#10 +                                         // 1
    'interface'#10 +                                             // 2
    'uses FixVcl;'#10 +                                          // 3
    'type'#10 +                                                  // 4
    '  TFixTray = class(TFrame)'#10 +                            // 5
    '    TrayLabel: TLabel;'#10 +                                // 6
    '    TrayEdit: TEdit;'#10 +                                  // 7  col 5
    '  end;'#10 +                                                // 8
    'implementation'#10 +                                        // 9
    '{$R *.dfm}'#10 +                                            // 10
    'end.'#10;                                                   // 11

  DFM_TRAY =
    'object FixTray: TFixTray' + CRLF +                          // 1
    '  object TrayLabel: TLabel' + CRLF +                        // 2
    '  end' + CRLF +                                             // 3
    '  object TrayEdit: TEdit' + CRLF +                          // 4
    '  end' + CRLF +                                             // 5
    '  object TrayGhost: TEdit' + CRLF +                         // 6  no field
    '  end' + CRLF +                                             // 7
    'end' + CRLF;                                                // 8

  UNIT_DOCK =
    'unit FixDock;'#10 +                                         // 1
    'interface'#10 +                                             // 2
    'uses FixVcl, FixTray;'#10 +                                 // 3
    'type'#10 +                                                  // 4
    '  TFixDockForm = class(TForm)'#10 +                         // 5
    '    Label1: TLabel;'#10 +                                   // 6
    '    Tray1: TFixTray;'#10 +                                  // 7
    '    Tray2: TFixTray;'#10 +                                  // 8
    '    Label3: TLabel;'#10 +                                   // 9
    '  end;'#10 +                                                // 10
    'implementation'#10 +                                        // 11
    '{$R *.dfm}'#10 +                                            // 12
    'end.'#10;                                                   // 13

  DFM_DOCK =
    'object FixDockForm: TFixDockForm' + CRLF +                  // 1
    '  object Label1: TLabel' + CRLF +                           // 2
    '    FocusControl = Tray1.TrayGhost' + CRLF +                // 3
    '  end' + CRLF +                                             // 4
    '  inline Tray1: TFixTray' + CRLF +                          // 5
    '    inherited TrayLabel: TLabel' + CRLF +                   // 6
    '      FocusControl = Tray1.TrayEdit' + CRLF +               // 7  TrayEdit col 28
    '    end' + CRLF +                                           // 8
    '  end' + CRLF +                                             // 9
    '  inline Tray2: TFixTray' + CRLF +                          // 10
    '    inherited TrayLabel: TLabel' + CRLF +                   // 11
    '      FocusControl = Tray1.TrayEdit' + CRLF +               // 12 TrayEdit col 28
    '    end' + CRLF +                                           // 13
    '  end' + CRLF +                                             // 14
    '  object Label3: TLabel' + CRLF +                           // 15
    '    FocusControl = Tray1.Nowhere' + CRLF +                  // 16
    '  end' + CRLF +                                             // 17
    'end' + CRLF;                                                // 18

  // What a real form holds and a naive reader gets wrong: a Boolean named
  // like an event, an event cleared with nil, the items of one collection
  // binding one event each, and text after the root's `end` - which dcc's
  // conversion drops, so nothing there binds.
  UNIT_COLL =
    'unit FixColl;'#10 +                                         // 1
    'interface'#10 +                                             // 2
    'uses FixVcl;'#10 +                                          // 3
    'type'#10 +                                                  // 4
    '  TFixCollForm = class(TForm)'#10 +                         // 5
    '    Grid: TButton;'#10 +                                    // 6
    '    procedure PrintA(Sender: TObject);'#10 +                // 7  col 15
    '    procedure PrintB(Sender: TObject);'#10 +                // 8  col 15
    '  end;'#10 +                                                // 9
    'implementation'#10 +                                        // 10
    '{$R *.dfm}'#10 +                                            // 11
    'procedure TFixCollForm.PrintA(Sender: TObject); begin end;'#10 + // 12
    'procedure TFixCollForm.PrintB(Sender: TObject); begin end;'#10 + // 13
    'end.'#10;                                                   // 14

  DFM_COLL =
    'object FixCollForm: TFixCollForm' + CRLF +                  // 1
    '  OneOnRow = True' + CRLF +                                 // 2
    '  object Grid: TButton' + CRLF +                            // 3
    '    OnClick = nil' + CRLF +                                 // 4
    '    Items = <' + CRLF +                                     // 5
    '      item' + CRLF +                                        // 6
    '        OnPrint = PrintA' + CRLF +                          // 7  col 19
    '      end' + CRLF +                                         // 8
    '      item' + CRLF +                                        // 9
    '        OnPrint = PrintB' + CRLF +                          // 10 col 19
    '      end' + CRLF +                                         // 11
    '      item' + CRLF +                                        // 12
    '        Caption = ''x''' + CRLF +                           // 13
    '      end>' + CRLF +                                        // 14
    '  end' + CRLF +                                             // 15
    'end' + CRLF +                                               // 16
    '  object Stray: TButton' + CRLF +                           // 17
    '    OnClick = PrintA' + CRLF +                              // 18
    '  end' + CRLF +                                             // 19
    'end' + CRLF;                                                // 20

  // Written AFTER the binder listed the directory: the unit first, its form
  // file next, as an agent writes them.
  UNIT_LATE =
    'unit FixLate;'#10 +                                         // 1
    'interface'#10 +                                             // 2
    'uses FixVcl;'#10 +                                          // 3
    'type'#10 +                                                  // 4
    '  TFixLateForm = class(TForm)'#10 +                         // 5
    '    LateButton: TButton;'#10 +                              // 6
    '    procedure LateButtonClick(Sender: TObject);'#10 +       // 7  col 15
    '  end;'#10 +                                                // 8
    'implementation'#10 +                                        // 9
    '{$R *.dfm}'#10 +                                            // 10
    'procedure TFixLateForm.LateButtonClick(Sender: TObject);'#10 + // 11
    'begin'#10 +                                                 // 12
    'end;'#10 +                                                  // 13
    'end.'#10;                                                   // 14

  DFM_LATE =
    'object FixLateForm: TFixLateForm' + CRLF +                  // 1
    '  object LateButton: TButton' + CRLF +                      // 2
    '    OnClick = LateButtonClick' + CRLF +                     // 3  col 15
    '  end' + CRLF +                                             // 4
    'end' + CRLF;                                                // 5

var
  GCounter: TPasSuiteCounter;
  GProj: TPasSemaProject;
  GNav: TPasNavigator;
  GDir: string;

procedure Ok(const AName: string; ACond: Boolean);
begin
  GCounter.Ok(AName, ACond);
end;

function FilePath(const AName: string): string;
begin
  Result := TPath.Combine(GDir, AName);
end;

// The symbol at (ALine, ACol) of AFile, as Find References would search it.
function SymAt(const AFile: string; ALine, ACol: Integer;
  out ATMid, ASym: Integer): Boolean;
var
  LName: string;
  LMid: Integer;
begin
  LMid := GNav.ModelIdOf(FilePath(AFile));
  Result := (LMid >= 0) and GNav.SymbolAt(LMid, ALine, ACol, ATMid, ASym,
    LName);
end;

function Sites(const AFile: string; ALine, ACol: Integer): TArray<TPasFormSite>;
var
  LTMid, LSym: Integer;
begin
  Result := nil;
  if SymAt(AFile, ALine, ACol, LTMid, LSym) then
    Result := GNav.FindFormSites(LTMid, LSym);
end;

function HasSite(const ASites: TArray<TPasFormSite>; const AFile: string;
  ALine, ACol: Integer; AKind: TPasFormSiteKind;
  const AObject: string): Boolean;
var
  LSite: TPasFormSite;
begin
  for LSite in ASites do
    if SameText(TPath.GetFileName(LSite.FilePath), AFile) and
       (LSite.Line = ALine) and (LSite.Col = ACol) and (LSite.Kind = AKind) and
       SameText(LSite.ObjectName, AObject) then
      Exit(True);
  Result := False;
end;

function Plan(const AFile: string; ALine, ACol: Integer; const ANewName: string;
  out AEdits: TArray<TPasRenameEdit>; out AError: string): Boolean;
var
  LTMid, LSym: Integer;
begin
  AEdits := nil;
  AError := 'no symbol at the position';
  Result := SymAt(AFile, ALine, ACol, LTMid, LSym) and
    GNav.PlanRename(LTMid, LSym, ANewName, AEdits, AError);
end;

function FormEdits(const AEdits: TArray<TPasRenameEdit>): Integer;
var
  LEdit: TPasRenameEdit;
begin
  Result := 0;
  for LEdit in AEdits do
    if LEdit.FormKind <> fskNone then
      Inc(Result);
end;

function HasEdit(const AEdits: TArray<TPasRenameEdit>; const AFile: string;
  ALine, ACol: Integer; AKind: TPasFormSiteKind;
  const ASnippet: string): Boolean;
var
  LEdit: TPasRenameEdit;
begin
  for LEdit in AEdits do
    if SameText(TPath.GetFileName(LEdit.FilePath), AFile) and
       (LEdit.Line = ALine) and (LEdit.Col = ACol) and
       (LEdit.FormKind = AKind) and ((ASnippet = '') or
       (LEdit.Snippet = ASnippet)) then
      Exit(True);
  Result := False;
end;

// Any edit on that line of that file.
function HasEditOnLine(const AEdits: TArray<TPasRenameEdit>;
  const AFile: string; ALine: Integer): Boolean;
var
  LEdit: TPasRenameEdit;
begin
  for LEdit in AEdits do
    if SameText(TPath.GetFileName(LEdit.FilePath), AFile) and
       (LEdit.Line = ALine) then
      Exit(True);
  Result := False;
end;

// The edit at a position writes ANewText, and its line then reads ASnippet.
function EditWrites(const AEdits: TArray<TPasRenameEdit>; const AFile: string;
  ALine, ACol: Integer; const ANewText, ASnippet: string): Boolean;
var
  LEdit: TPasRenameEdit;
begin
  for LEdit in AEdits do
    if SameText(TPath.GetFileName(LEdit.FilePath), AFile) and
       (LEdit.Line = ALine) and (LEdit.Col = ACol) then
      Exit((LEdit.NewText = ANewText) and (LEdit.Snippet = ASnippet) and
        (Copy(LEdit.Snippet, LEdit.HiFrom + 1, LEdit.HiTo - LEdit.HiFrom) =
         ANewText));
  Result := False;
end;

function PlanCarried(const AFile: string; ALine, ACol: Integer;
  const ANewName: string; out AEdits: TArray<TPasRenameEdit>;
  out ACarried: TArray<TPasCarriedRename>; out AError: string): Boolean;
var
  LTMid, LSym: Integer;
begin
  AEdits := nil;
  ACarried := nil;
  AError := 'no symbol at the position';
  Result := SymAt(AFile, ALine, ACol, LTMid, LSym) and
    GNav.PlanRename(LTMid, LSym, ANewName, AEdits, ACarried, AError);
end;

function RoleAt(const AFile: string; ALine, ACol: Integer): TPasFormRole;
var
  LTMid, LSym: Integer;
begin
  Result := Default(TPasFormRole);
  if SymAt(AFile, ALine, ACol, LTMid, LSym) then
    Result := GNav.FormRoleOf(LTMid, LSym);
end;

function SiteVia(const ASites: TArray<TPasFormSite>; const AFile: string;
  ALine, ACol: Integer; AVia: TPasFormSiteVia): Boolean;
var
  LSite: TPasFormSite;
begin
  for LSite in ASites do
    if SameText(TPath.GetFileName(LSite.FilePath), AFile) and
       (LSite.Line = ALine) and (LSite.Col = ACol) then
      Exit(LSite.Via = AVia);
  Result := False;
end;

// The property APath set on the object named AObject, in ADoc; -1 if none.
function PropOf(ADoc: TPasDfmDoc; const AObject, APath: string): Integer;
var
  LIdx: Integer;
begin
  for LIdx := 0 to High(ADoc.Props) do
    if SameText(ADoc.ObjectName(ADoc.Props[LIdx].Obj), AObject) and
       SameText(ADoc.PropPath(LIdx), APath) then
      Exit(LIdx);
  Result := -1;
end;

procedure WriteBinaryForm(const APath, AText: string);
var
  LIn: TStringStream;
  LOut: TFileStream;
begin
  LIn := TStringStream.Create(AText, TEncoding.ASCII);
  try
    LOut := TFileStream.Create(APath, fmCreate);
    try
      ObjectTextToResource(LIn, LOut);
    finally
      LOut.Free;
    end;
  finally
    LIn.Free;
  end;
end;

procedure ReaderChecks;
var
  LDoc: IPasDfmDoc;
  LIdx: Integer;
begin
  LDoc := PasDfmLoad(FilePath('FixBase.dfm'));
  Ok('reader: FixBase.dfm read without error',
    (LDoc <> nil) and (LDoc.Doc.Error = '') and not LDoc.Doc.IsBinary);
  Ok('reader: root name and class',
    (LDoc.Doc.RootName = 'FixBaseForm') and
    (LDoc.Doc.RootClassName = 'TFixBaseForm'));
  Ok('reader: 8 objects (root, 2 labels, button, edit, frame + 2 in it)',
    Length(LDoc.Doc.Objects) = 8);
  LIdx := LDoc.Doc.FindIdents('frameedit')[0];
  Ok('reader: a dotted value is one identifier per segment',
    (Length(LDoc.Doc.FindIdents('frameedit')) = 2) and
    (LDoc.Doc.Idents[LIdx].Role = dirValue) and
    (LDoc.Doc.Idents[LIdx].Seg = 1) and (LDoc.Doc.Idents[LIdx].SegCount = 2) and
    (LDoc.Doc.LineOf(LDoc.Doc.Idents[LIdx].Offset) = 14) and
    (LDoc.Doc.ColOf(LDoc.Doc.Idents[LIdx].Offset) = 28));
  Ok('reader: the line text of a site',
    LDoc.Doc.LineText(14) = '    FocusControl = Frame11.FrameEdit');
  LDoc := PasDfmLoad(FilePath('FixBin.dfm'));
  Ok('reader: a binary form file is converted and read',
    (LDoc <> nil) and LDoc.Doc.IsBinary and (LDoc.Doc.Error = '') and
    (LDoc.Doc.RootClassName = 'TFixBinForm') and
    (Length(LDoc.Doc.FindIdents('binbuttonclick')) = 1));
  LDoc := PasDfmLoad(FilePath('FixBroken.dfm'));
  Ok('reader: a malformed file says why and keeps what came before',
    (LDoc <> nil) and (LDoc.Doc.Error <> '') and
    (Length(LDoc.Doc.FindIdents('brokenbutton')) = 1));
  Ok('reader: no form file is nil', PasDfmLoad(FilePath('None.dfm')) = nil);
  Ok('reader: the form file of a unit',
    SameText(PasDfmFileOfUnit(FilePath('FixBase.pas')), FilePath('FixBase.dfm')) and
    (PasDfmFileOfUnit(FilePath('FixVcl.pas')) = ''));
end;

procedure SiteChecks;
var
  LSites: TArray<TPasFormSite>;
  LTMid, LSym: Integer;
  LHits: TArray<TPasRefHit>;
  LFound: Boolean;
  LHit: TPasRefHit;
begin
  LSites := Sites('FixBase.pas', 7, 5);   // Button1
  Ok('field Button1: its object and the descendant''s inherited one',
    (Length(LSites) = 2) and
    HasSite(LSites, 'FixBase.dfm', 6, 10, fskComponent, 'Button1') and
    HasSite(LSites, 'FixChild.dfm', 2, 13, fskComponent, 'Button1'));
  LSites := Sites('FixBase.pas', 8, 5);   // Edit1
  Ok('field Edit1: its object and a FocusControl reference',
    (Length(LSites) = 2) and
    HasSite(LSites, 'FixBase.dfm', 10, 10, fskComponent, 'Edit1') and
    HasSite(LSites, 'FixBase.dfm', 4, 20, fskComponentRef, 'Label1'));
  LSites := Sites('FixBase.pas', 11, 15); // Button1Click
  Ok('handler Button1Click: in its form and in the descendant',
    (Length(LSites) = 2) and
    HasSite(LSites, 'FixBase.dfm', 8, 15, fskHandler, 'Button1') and
    HasSite(LSites, 'FixChild.dfm', 6, 15, fskHandler, 'Button2'));
  LSites := Sites('FixBase.pas', 21, 24); // Button1Click, implementation
  Ok('handler from its implementation header: the same two',
    Length(LSites) = 2);
  LSites := Sites('FixFrame.pas', 6, 5);  // FrameEdit
  Ok('frame field FrameEdit: frame''s own, the host''s inline child, ' +
    'the host''s Frame11.FrameEdit',
    (Length(LSites) = 3) and
    HasSite(LSites, 'FixFrame.dfm', 2, 10, fskComponent, 'FrameEdit') and
    HasSite(LSites, 'FixBase.dfm', 18, 15, fskComponent, 'FrameEdit') and
    HasSite(LSites, 'FixBase.dfm', 14, 28, fskComponentRef, 'Label2'));
  LSites := Sites('FixFrame.pas', 8, 15); // FrameButtonClick
  Ok('frame handler: the frame''s own form file only',
    (Length(LSites) = 1) and
    HasSite(LSites, 'FixFrame.dfm', 5, 15, fskHandler, 'FrameButton'));
  LSites := Sites('FixBase.pas', 12, 15); // Frame11FrameButtonClick
  Ok('host handler inside the inline frame: bound to the host (Root)',
    (Length(LSites) = 1) and
    HasSite(LSites, 'FixBase.dfm', 22, 17, fskHandler, 'FrameButton'));
  LSites := Sites('FixFrame.pas', 5, 3);  // TFixFrame
  Ok('frame class: its own root header and the host''s inline header',
    (Length(LSites) = 2) and
    HasSite(LSites, 'FixFrame.dfm', 1, 18, fskClass, 'FixFrame') and
    HasSite(LSites, 'FixBase.dfm', 16, 19, fskClass, 'Frame11'));
  LSites := Sites('FixBase.pas', 10, 5);  // Frame11
  Ok('inline frame field: its header and the head of Frame11.FrameEdit',
    (Length(LSites) = 2) and
    HasSite(LSites, 'FixBase.dfm', 16, 10, fskComponent, 'Frame11') and
    HasSite(LSites, 'FixBase.dfm', 14, 20, fskComponentRef, 'Label2'));
  LSites := Sites('FixData.pas', 6, 5);   // Action1
  Ok('data module field: its object and FixData.Action1 in the form',
    (Length(LSites) = 2) and
    HasSite(LSites, 'FixData.dfm', 2, 10, fskComponent, 'Action1') and
    HasSite(LSites, 'FixBase.dfm', 7, 22, fskComponentRef, 'Button1'));
  LSites := Sites('FixData.pas', 7, 15);  // Action1Execute
  Ok('data module handler',
    (Length(LSites) = 1) and
    HasSite(LSites, 'FixData.dfm', 3, 17, fskHandler, 'Action1'));
  LSites := Sites('FixBase.pas', 5, 3);   // TFixBaseForm
  Ok('form class: its own root header only (the descendant names its own)',
    (Length(LSites) = 1) and
    HasSite(LSites, 'FixBase.dfm', 1, 21, fskClass, 'FixBaseForm'));
  LSites := Sites('FixBase.pas', 14, 5);  // FCount (private)
  Ok('a private field: no form file site', Length(LSites) = 0);
  LSites := Sites('FixBin.pas', 7, 15);   // BinButtonClick
  Ok('a binary form file is still listed',
    (Length(LSites) = 1) and LSites[0].IsBinary and
    (LSites[0].Kind = fskHandler));
  LSites := Sites('FixBroken.pas', 6, 5); // BrokenButton
  Ok('a malformed form file lists what it read',
    (Length(LSites) = 1) and
    HasSite(LSites, 'FixBroken.dfm', 2, 10, fskComponent, 'BrokenButton'));

  Ok('FindReferences: form files only when asked',
    SymAt('FixBase.pas', 11, 15, LTMid, LSym));
  LHits := GNav.FindReferences(LTMid, LSym);
  LFound := False;
  for LHit in LHits do
    if SameText(ExtractFileExt(LHit.FilePath), '.dfm') then
      LFound := True;
  Ok('FindReferences: no .dfm row by default', not LFound);
  LHits := GNav.FindReferences(LTMid, LSym, False, True);
  LFound := False;
  for LHit in LHits do
    if SameText(TPath.GetFileName(LHit.FilePath), 'FixChild.dfm') and
       (LHit.Line = 6) and (LHit.Col = 15) and
       (LHit.Snippet = '    OnClick = Button1Click') and (LHit.HiFrom = 14) and
       (LHit.HiTo = 26) then
      LFound := True;
  Ok('FindReferences(AFormFiles): the descendant''s handler row, positioned',
    LFound and (Length(LHits) = 3));   // the call on line 28, two form rows
end;

procedure RenameChecks;
var
  LEdits: TArray<TPasRenameEdit>;
  LErr: string;
begin
  Ok('rename component Button1 -> btnOk: planned',
    Plan('FixBase.pas', 7, 5, 'btnOk', LEdits, LErr));
  // Its two headers, and Button1Click carried along as btnOkClick: decl,
  // implementation, the call, the form's link and the descendant's.
  Ok('rename component: the two form edits, previewed, and its handler''s',
    (FormEdits(LEdits) = 4) and (Length(LEdits) = 9) and
    HasEdit(LEdits, 'FixBase.dfm', 6, 10, fskComponent,
      '  object btnOk: TButton') and
    HasEdit(LEdits, 'FixChild.dfm', 2, 13, fskComponent,
      '  inherited btnOk: TButton') and
    HasEdit(LEdits, 'FixChild.dfm', 6, 15, fskHandler,
      '    OnClick = btnOkClick') and
    EditWrites(LEdits, 'FixBase.pas', 28, 3, 'btnOkClick',
      '  btnOkClick(Sender);'));
  Ok('rename handler Button1Click -> OkClick: planned',
    Plan('FixBase.pas', 11, 15, 'OkClick', LEdits, LErr));
  Ok('rename handler: decl, impl, call and both form links',
    (FormEdits(LEdits) = 2) and (Length(LEdits) = 5) and
    HasEdit(LEdits, 'FixChild.dfm', 6, 15, fskHandler,
      '    OnClick = OkClick'));
  Ok('rename frame field FrameEdit: three form edits',
    Plan('FixFrame.pas', 6, 5, 'NameEdit', LEdits, LErr) and
    (FormEdits(LEdits) = 3) and
    HasEdit(LEdits, 'FixBase.dfm', 14, 28, fskComponentRef,
      '    FocusControl = Frame11.NameEdit'));
  Ok('rename frame class: both headers',
    Plan('FixFrame.pas', 5, 3, 'TNameFrame', LEdits, LErr) and
    (FormEdits(LEdits) = 2) and
    HasEdit(LEdits, 'FixBase.dfm', 16, 19, fskClass,
      '  inline Frame11: TNameFrame'));
  // Action1Execute follows; the caption does not - the action has a client.
  Ok('rename data module component: the cross-module reference follows',
    Plan('FixData.pas', 6, 5, 'actSave', LEdits, LErr) and
    (FormEdits(LEdits) = 3) and
    HasEdit(LEdits, 'FixBase.dfm', 7, 22, fskComponentRef,
      '    Action = FixData.actSave') and
    HasEdit(LEdits, 'FixData.dfm', 3, 17, fskHandler,
      '    OnExecute = actSaveExecute') and
    not HasEditOnLine(LEdits, 'FixData.dfm', 4));

  Ok('refused: a published property a form file sets',
    not Plan('FixFrame.pas', 12, 14, 'Heading', LEdits, LErr) and
    (Pos('property', LErr) > 0) and (Length(LEdits) = 0));
  Ok('refused: an enum value a form file spells',
    not Plan('FixVcl.pas', 5, 21, 'alAll', LEdits, LErr) and
    (Pos('enumeration', LErr) > 0));
  Ok('refused: a binary form file',
    not Plan('FixBin.pas', 7, 15, 'BinClick', LEdits, LErr) and
    (Pos('binary', LErr) > 0));
  Ok('refused: a malformed form file that may name it',
    not Plan('FixBroken.pas', 6, 5, 'OkButton', LEdits, LErr) and
    (Pos('could not be read', LErr) > 0));
  Ok('refused: a component renamed onto an existing member',
    not Plan('FixBase.pas', 7, 5, 'Edit1', LEdits, LErr) and
    (Pos('Edit1', LErr) > 0));
  Ok('refused: a name only the DESCENDANT has',
    not Plan('FixBase.pas', 7, 5, 'Button2', LEdits, LErr) and
    (Pos('Button2', LErr) > 0));
  Ok('a symbol no form file names: no form edits',
    Plan('FixBase.pas', 14, 5, 'FClicks', LEdits, LErr) and
    (FormEdits(LEdits) = 0) and (Length(LEdits) = 2));
end;

{ What a component's rename carries along (TPasFormBinder.CarriedBy), where
  a site is reached from (Via), and what a symbol is to the form files
  (FormRoleOf). }
procedure CarryChecks;
var
  LEdits: TArray<TPasRenameEdit>;
  LCarried: TArray<TPasCarriedRename>;
  LErr: string;
  LRole: TPasFormRole;
  LSites: TArray<TPasFormSite>;
  LDoc: IPasDfmDoc;
  LLen: Integer;
begin
  LDoc := PasDfmLoad(FilePath('FixCap.dfm'));
  Ok('reader: a lone quoted caption is its text, case-sensitively',
    LDoc.Doc.StringValueIs(PropOf(LDoc.Doc, 'CapButton', 'Caption'),
      'CapButton', True, LLen) and (LLen = 9) and
    not LDoc.Doc.StringValueIs(PropOf(LDoc.Doc, 'CapButton', 'Caption'),
      'capbutton', True, LLen) and
    LDoc.Doc.StringValueIs(PropOf(LDoc.Doc, 'CapButton', 'Caption'),
      'capbutton', False, LLen));
  Ok('reader: a caption that goes on past the quote (#13) is not',
    not LDoc.Doc.StringValueIs(PropOf(LDoc.Doc, 'SplitButton', 'Caption'),
      'SplitButton', True, LLen));
  Ok('reader: a + concatenation has no single string position',
    (PropOf(LDoc.Doc, 'PlusButton', 'Caption') >= 0) and
    (LDoc.Doc.Props[PropOf(LDoc.Doc, 'PlusButton', 'Caption')].StrOffset = -1));

  Ok('carry: CapButton -> OkButton planned',
    PlanCarried('FixCap.pas', 6, 5, 'OkButton', LEdits, LCarried, LErr));
  Ok('carry: its handler, once, with its own new name and whose it is',
    (Length(LCarried) = 1) and (LCarried[0].OldName = 'CapButtonClick') and
    (LCarried[0].NewName = 'OkButtonClick') and
    (LCarried[0].Role.Kind = fskHandler) and
    (LCarried[0].Role.OwnerClass = 'TFixCapForm') and
    SameText(TPath.GetFileName(LCarried[0].Role.FormFile), 'FixCap.dfm'));
  Ok('carry: field + header, caption, and the handler''s decl, impl, call, ' +
    'two links',
    (Length(LEdits) = 8) and (FormEdits(LEdits) = 4));
  Ok('carry: the caption that read its name follows',
    HasEdit(LEdits, 'FixCap.dfm', 4, 16, fskCaption,
      '    Caption = ''OkButton''') and
    EditWrites(LEdits, 'FixCap.dfm', 4, 16, 'OkButton',
      '    Caption = ''OkButton'''));
  Ok('carry: the form''s own caption of the same text does not',
    not HasEditOnLine(LEdits, 'FixCap.dfm', 2));
  Ok('carry: both links to the handler, the shared one too',
    HasEdit(LEdits, 'FixCap.dfm', 5, 15, fskHandler,
      '    OnClick = OkButtonClick') and
    HasEdit(LEdits, 'FixCap.dfm', 24, 15, fskHandler,
      '    OnClick = OkButtonClick'));
  Ok('carry: the handler''s implementation header and its call',
    EditWrites(LEdits, 'FixCap.pas', 18, 23, 'OkButtonClick',
      'procedure TFixCapForm.OkButtonClick(Sender: TObject);') and
    EditWrites(LEdits, 'FixCap.pas', 24, 3, 'OkButtonClick',
      '  OkButtonClick(nil);') and
    EditWrites(LEdits, 'FixCap.pas', 6, 5, 'OkButton',
      '    OkButton: TButton;'));

  Ok('carry: CapEdit -> NameEdit: Text follows, CapEditClick is carried',
    PlanCarried('FixCap.pas', 7, 5, 'NameEdit', LEdits, LCarried, LErr) and
    HasEdit(LEdits, 'FixCap.dfm', 8, 13, fskCaption,
      '    Text = ''NameEdit''') and
    (Length(LCarried) = 1) and (LCarried[0].NewName = 'NameEditClick') and
    EditWrites(LEdits, 'FixCap.pas', 20, 3, 'NameEditClick',
      '  NameEditClick(Sender);'));
  Ok('carry: a caption in another case, a shared handler - neither',
    PlanCarried('FixCap.pas', 8, 5, 'LowBtn', LEdits, LCarried, LErr) and
    (Length(LEdits) = 2) and (Length(LCarried) = 0));
  Ok('carry: a caption that is not a plain literal - no',
    PlanCarried('FixCap.pas', 9, 5, 'SplitBtn', LEdits, LCarried, LErr) and
    (Length(LEdits) = 2));
  Ok('carry: a concatenated caption - no',
    PlanCarried('FixCap.pas', 10, 5, 'PlusBtn', LEdits, LCarried, LErr) and
    (Length(LEdits) = 2));
  // CapEditClick would become SharedClick, which exists: the handler keeps
  // its name, the component is still renamed.
  Ok('carry: a handler whose new name is taken keeps its name',
    PlanCarried('FixCap.pas', 7, 5, 'Shared', LEdits, LCarried, LErr) and
    (Length(LCarried) = 0) and (Length(LEdits) = 3) and
    HasEdit(LEdits, 'FixCap.dfm', 8, 13, fskCaption, '    Text = ''Shared''') and
    not HasEditOnLine(LEdits, 'FixCap.dfm', 9));
  Ok('carry: an action with no client - its caption follows',
    PlanCarried('FixData.pas', 9, 5, 'actOpen', LEdits, LCarried, LErr) and
    HasEdit(LEdits, 'FixData.dfm', 7, 16, fskCaption,
      '    Caption = ''actOpen''') and
    (Length(LCarried) = 1) and (LCarried[0].NewName = 'actOpenExecute'));

  LSites := Sites('FixFrame.pas', 6, 5);   // FrameEdit
  Ok('via: a frame''s component - own in its frame, inline in the host',
    SiteVia(LSites, 'FixFrame.dfm', 2, 10, fsvOwn) and
    SiteVia(LSites, 'FixBase.dfm', 18, 15, fsvInline) and
    SiteVia(LSites, 'FixBase.dfm', 14, 28, fsvInline));
  LSites := Sites('FixData.pas', 6, 5);    // Action1
  Ok('via: a data module''s component through its root Name',
    SiteVia(LSites, 'FixData.dfm', 2, 10, fsvOwn) and
    SiteVia(LSites, 'FixBase.dfm', 7, 22, fsvModule));
  LSites := Sites('FixBase.pas', 12, 15);  // Frame11FrameButtonClick
  Ok('via: a host handler linked inside the inline frame',
    SiteVia(LSites, 'FixBase.dfm', 22, 17, fsvInline));
  LSites := Sites('FixBase.pas', 11, 15);  // Button1Click
  Ok('via: a descendant''s link to the ancestor''s handler is its own',
    SiteVia(LSites, 'FixChild.dfm', 6, 15, fsvOwn));
  LSites := Sites('FixBase.pas', 8, 5);    // Edit1
  Ok('site: the property a reference is the value of',
    (Length(LSites) = 2) and
    ((LSites[0].PropName = 'FocusControl') or
     (LSites[1].PropName = 'FocusControl')));

  LRole := RoleAt('FixBase.pas', 7, 5);    // Button1
  Ok('role: a component, of its form',
    (LRole.Kind = fskComponent) and (LRole.OwnerClass = 'TFixBaseForm') and
    SameText(TPath.GetFileName(LRole.FormFile), 'FixBase.dfm'));
  LRole := RoleAt('FixBase.pas', 11, 15);  // Button1Click
  Ok('role: a handler, of its form',
    (LRole.Kind = fskHandler) and (LRole.OwnerClass = 'TFixBaseForm'));
  LRole := RoleAt('FixFrame.pas', 5, 3);   // TFixFrame
  Ok('role: a frame''s class, with its own form file',
    (LRole.Kind = fskClass) and (LRole.OwnerClass = 'TFixFrame') and
    SameText(TPath.GetFileName(LRole.FormFile), 'FixFrame.dfm'));
  LRole := RoleAt('FixBase.pas', 14, 5);   // FCount
  Ok('role: a private field is none', LRole.Kind = fskNone);
  LRole := RoleAt('FixChild.pas', 6, 5);   // Button2
  Ok('role: a descendant''s own component, of the descendant''s form',
    (LRole.Kind = fskComponent) and (LRole.OwnerClass = 'TFixChildForm') and
    SameText(TPath.GetFileName(LRole.FormFile), 'FixChild.dfm'));
end;

function FormObj(const AInfo: TPasFormInfo; const AName: string): Integer;
begin
  for var LIdx := 0 to High(AInfo.Objects) do
    if SameText(AInfo.Objects[LIdx].Name, AName) then
      Exit(LIdx);
  Result := -1;
end;

// The binding of AObject's property AProp, -1 for none.
function FormBinding(const AInfo: TPasFormInfo; const AObject,
  AProp: string): Integer;
begin
  for var LIdx := 0 to High(AInfo.Bindings) do
    if SameText(AInfo.Objects[AInfo.Bindings[LIdx].Obj].Name, AObject) and
       SameText(AInfo.Bindings[LIdx].PropName, AProp) then
      Exit(LIdx);
  Result := -1;
end;

// Whether (AMid, ASym) is the symbol at ALine, ACol of AFile.
function IsSymAt(AMid, ASym: Integer; const AFile: string;
  ALine, ACol: Integer): Boolean;
var
  LTMid, LSym: Integer;
begin
  Result := (ASym <> NIL_SYM) and SymAt(AFile, ALine, ACol, LTMid, LSym) and
    (LTMid = AMid) and (LSym = ASym);
end;

procedure AncestorChecks;
var
  LSites: TArray<TPasFormSite>;
  LEdits: TArray<TPasRenameEdit>;
  LError: string;
begin
  LSites := Sites('FixGrand.pas', 6, 15);   // TFixGrandForm.Button1Click
  Ok('a redeclared handler: bound by both ancestors'' forms, by name',
    (Length(LSites) = 2) and
    HasSite(LSites, 'FixBase.dfm', 8, 15, fskHandler, 'Button1') and
    HasSite(LSites, 'FixChild.dfm', 6, 15, fskHandler, 'Button2') and
    SiteVia(LSites, 'FixBase.dfm', 8, 15, fsvAncestor) and
    SiteVia(LSites, 'FixChild.dfm', 6, 15, fsvAncestor));
  LSites := Sites('FixBase.pas', 11, 15);   // TFixBaseForm.Button1Click
  Ok('the ancestor''s handler keeps its own forms'' lines',
    (Length(LSites) = 2) and SiteVia(LSites, 'FixBase.dfm', 8, 15, fsvOwn));
  Ok('a redeclared handler''s rename is refused', not Plan('FixGrand.pas', 6,
    15, 'GrandClick', LEdits, LError) and LError.Contains('ancestor'));
end;

{ `inherited Pane1` in a descendant host is the frame's block: its children
  are the frame's fields, as in the host's `inline Pane1` - two levels down
  too. Until 0.63.1 they bound to nothing and a rename left them behind. }
procedure InheritedInlineChecks;
var
  LSites: TArray<TPasFormSite>;
  LEdits: TArray<TPasRenameEdit>;
  LError: string;
  LInfo: TPasFormInfo;
  LIdx: Integer;
begin
  LSites := Sites('FixPane.pas', 6, 5);    // PaneEdit
  Ok('inherited inline: the frame''s field in both descendant hosts',
    (Length(LSites) = 3) and
    HasSite(LSites, 'FixPane.dfm', 2, 10, fskComponent, 'PaneEdit') and
    HasSite(LSites, 'FixHostKid.dfm', 8, 15, fskComponent, 'PaneEdit') and
    HasSite(LSites, 'FixHostGrand.dfm', 3, 15, fskComponent, 'PaneEdit'));
  Ok('inherited inline: reached inline, as in the host',
    SiteVia(LSites, 'FixHostKid.dfm', 8, 15, fsvInline) and
    SiteVia(LSites, 'FixHostGrand.dfm', 3, 15, fsvInline));
  LSites := Sites('FixHost.pas', 7, 5);    // HostEdit
  Ok('a plain inherited object''s child stays the form''s',
    (Length(LSites) = 2) and
    HasSite(LSites, 'FixHost.dfm', 3, 12, fskComponent, 'HostEdit') and
    HasSite(LSites, 'FixHostKid.dfm', 3, 15, fskComponent, 'HostEdit') and
    SiteVia(LSites, 'FixHostKid.dfm', 3, 15, fsvOwn));
  LSites := Sites('FixHost.pas', 9, 15);   // HostPaneClick
  Ok('a host handler linked inside the inherited inline block',
    (Length(LSites) = 1) and
    HasSite(LSites, 'FixHostKid.dfm', 9, 17, fskHandler, 'PaneEdit') and
    SiteVia(LSites, 'FixHostKid.dfm', 9, 17, fsvInline));
  Ok('inherited inline: a rename of the frame''s field reaches both',
    Plan('FixPane.pas', 6, 5, 'NameBox', LEdits, LError) and
    (FormEdits(LEdits) = 3) and
    HasEdit(LEdits, 'FixHostKid.dfm', 8, 15, fskComponent,
      '    inherited NameBox: TEdit') and
    HasEdit(LEdits, 'FixHostGrand.dfm', 3, 15, fskComponent,
      '    inherited NameBox: TEdit'));
  Ok('describe: an inherited inline block''s child fills the frame''s field',
    GNav.DescribeForm(FilePath('FixHostKid.dfm'), LInfo));
  LIdx := FormObj(LInfo, 'PaneEdit');
  Ok('describe: PaneEdit is TFixPane.PaneEdit', (LIdx > 0) and
    IsSymAt(LInfo.Objects[LIdx].FieldMid, LInfo.Objects[LIdx].FieldSym,
    'FixPane.pas', 6, 5));
end;

procedure DescribeChecks;
var
  LInfo: TPasFormInfo;
  LIdx: Integer;
begin
  Ok('describe: a base form reads whole', GNav.DescribeForm(
    FilePath('FixBase.dfm'), LInfo) and (LInfo.Error = '') and
    not LInfo.IsBinary and (Length(LInfo.Objects) = 8) and
    (LInfo.Objects[0].Parent = -1) and (LInfo.Objects[0].FieldSym = NIL_SYM));
  LIdx := FormObj(LInfo, 'Button1');
  Ok('describe: a component fills its field', (LIdx > 0) and
    (LInfo.Objects[LIdx].Line = 6) and (LInfo.Objects[LIdx].ClassName =
    'TButton') and IsSymAt(LInfo.Objects[LIdx].FieldMid,
    LInfo.Objects[LIdx].FieldSym, 'FixBase.pas', 7, 5));
  LIdx := FormObj(LInfo, 'FrameEdit');
  Ok('describe: an inline frame''s child fills the frame''s field',
    (LIdx > 0) and (LInfo.Objects[LIdx].Kind = dokInherited) and
    (LInfo.Objects[LInfo.Objects[LIdx].Parent].Name = 'Frame11') and
    (LInfo.Objects[LInfo.Objects[LIdx].Parent].Kind = dokInline) and
    IsSymAt(LInfo.Objects[LIdx].FieldMid, LInfo.Objects[LIdx].FieldSym,
    'FixFrame.pas', 6, 5));
  Ok('describe: five values name symbols, alClient is none',
    (Length(LInfo.Bindings) = 5) and (FormBinding(LInfo, 'Edit1', 'Align') < 0));
  LIdx := FormBinding(LInfo, 'Button1', 'OnClick');
  Ok('describe: a handler', (LIdx >= 0) and LInfo.Bindings[LIdx].IsMethod and
    (LInfo.Bindings[LIdx].Line = 8) and IsSymAt(LInfo.Bindings[LIdx].TMid,
    LInfo.Bindings[LIdx].TSym, 'FixBase.pas', 11, 15));
  LIdx := FormBinding(LInfo, 'Button1', 'Action');
  Ok('describe: a module''s component, by its root Name', (LIdx >= 0) and
    not LInfo.Bindings[LIdx].IsMethod and
    (LInfo.Bindings[LIdx].Value = 'FixData.Action1') and
    (LInfo.Bindings[LIdx].Via = fsvModule) and IsSymAt(
    LInfo.Bindings[LIdx].TMid, LInfo.Bindings[LIdx].TSym, 'FixData.pas', 6, 5));
  LIdx := FormBinding(LInfo, 'Label2', 'FocusControl');
  Ok('describe: a path into an inline frame', (LIdx >= 0) and
    IsSymAt(LInfo.Bindings[LIdx].TMid, LInfo.Bindings[LIdx].TSym,
    'FixFrame.pas', 6, 5));
  LIdx := FormBinding(LInfo, 'FrameButton', 'OnClick');
  Ok('describe: a handler set in an inline block is the host''s',
    (LIdx >= 0) and (LInfo.Bindings[LIdx].Via = fsvInline) and
    IsSymAt(LInfo.Bindings[LIdx].TMid, LInfo.Bindings[LIdx].TSym,
    'FixBase.pas', 12, 15));

  Ok('describe: an inherited form lists its own file''s objects',
    GNav.DescribeForm(FilePath('FixChild.dfm'), LInfo) and
    (Length(LInfo.Objects) = 5) and (FormObj(LInfo, 'Button1') > 0) and
    (LInfo.Objects[FormObj(LInfo, 'Button1')].Kind = dokInherited) and
    IsSymAt(LInfo.Objects[FormObj(LInfo, 'Button1')].FieldMid,
    LInfo.Objects[FormObj(LInfo, 'Button1')].FieldSym, 'FixBase.pas', 7, 5));
  LIdx := FormBinding(LInfo, 'Button2', 'OnClick');
  Ok('describe: the ancestor''s handler', (LIdx >= 0) and IsSymAt(
    LInfo.Bindings[LIdx].TMid, LInfo.Bindings[LIdx].TSym, 'FixBase.pas', 11,
    15));
  LIdx := FormBinding(LInfo, 'Button3', 'OnClick');
  Ok('describe: a handler no class declares is unbound', (LIdx >= 0) and
    LInfo.Bindings[LIdx].IsMethod and (LInfo.Bindings[LIdx].TSym = NIL_SYM) and
    (LInfo.Bindings[LIdx].Value = 'MissingClick'));
  LIdx := FormBinding(LInfo, 'Label3', 'FocusControl');
  Ok('describe: a path nothing answers is unbound', (LIdx >= 0) and
    not LInfo.Bindings[LIdx].IsMethod and
    (LInfo.Bindings[LIdx].TSym = NIL_SYM) and
    (LInfo.Bindings[LIdx].Value = 'Nowhere.Edit1'));
  Ok('describe: a component with no field', (FormObj(LInfo, 'Button3') > 0)
    and (LInfo.Objects[FormObj(LInfo, 'Button3')].FieldSym = NIL_SYM));

  Ok('describe: a binary form file says so', GNav.DescribeForm(
    FilePath('FixBin.dfm'), LInfo) and LInfo.IsBinary and
    (FormBinding(LInfo, 'BinButton', 'OnClick') >= 0));
  Ok('describe: a malformed one, with what was read', GNav.DescribeForm(
    FilePath('FixBroken.dfm'), LInfo) and (LInfo.Error <> '') and
    (FormObj(LInfo, 'BrokenButton') > 0));
  Ok('describe: no form file of the project', not GNav.DescribeForm(
    FilePath('NoSuch.dfm'), LInfo) and (LInfo.Error <> ''));
end;

{ A published property's form lines, for a reference search: TReader sets it
  by name, so a rename or a removal fails when the form loads. }
procedure PropChecks;
var
  LSites: TArray<TPasFormSite>;
begin
  LSites := Sites('FixFrame.pas', 12, 14);
  Ok('prop: a frame''s property set on its inline instance',
    (Length(LSites) = 1) and HasSite(LSites, 'FixBase.dfm', 17, 5,
    fskProperty, 'Frame11'));
  LSites := Sites('FixVcl.pas', 23, 14);
  Ok('prop: TControl.Align, set on an edit', (Length(LSites) = 1) and
    HasSite(LSites, 'FixBase.dfm', 11, 5, fskProperty, 'Edit1'));
  LSites := Sites('FixVcl.pas', 36, 14);
  Ok('prop: TEdit.Text inside an inline frame''s block', HasSite(LSites,
    'FixBase.dfm', 19, 7, fskProperty, 'FrameEdit'));
  LSites := Sites('FixVcl.pas', 25, 14);
  Ok('prop: TControl.Caption on the form''s root and a button',
    HasSite(LSites, 'FixBase.dfm', 2, 3, fskProperty, 'FixBaseForm') and
    HasSite(LSites, 'FixCap.dfm', 4, 5, fskProperty, 'CapButton'));
  Ok('prop: ...not an action''s Caption (TAction has none here), nor an '
    + 'item''s', not HasSite(LSites, 'FixData.dfm', 4, 5, fskProperty,
    'Action1') and not HasSite(LSites, 'FixColl.dfm', 13, 9, fskProperty,
    'Grid'));
end;

procedure DockChecks;
var
  LInfo: TPasFormInfo;

  // The binding written on line ALine, -1 for none.
  function AtLine(ALine: Integer): Integer;
  begin
    for var LI := 0 to High(LInfo.Bindings) do
      if LInfo.Bindings[LI].Line = ALine then
        Exit(LI);
    Result := -1;
  end;

var
  LIdx: Integer;
  LSites: TArray<TPasFormSite>;
begin
  Ok('dock: described', GNav.DescribeForm(FilePath('FixDock.dfm'), LInfo) and
    (LInfo.Error = '') and (Length(LInfo.Bindings) = 4));
  LIdx := AtLine(3);
  Ok('dock: a frame''s component with no field is reached by name', (LIdx >= 0)
    and (LInfo.Bindings[LIdx].TSym = NIL_SYM) and LInfo.Bindings[LIdx].NoField);
  LIdx := AtLine(7);
  Ok('dock: inside a frame''s block, a path headed by the frame''s own name',
    (LIdx >= 0) and IsSymAt(LInfo.Bindings[LIdx].TMid,
    LInfo.Bindings[LIdx].TSym, 'FixTray.pas', 7, 5));
  LIdx := AtLine(12);
  Ok('dock: inside a frame''s block, a sibling frame''s component',
    (LIdx >= 0) and IsSymAt(LInfo.Bindings[LIdx].TMid,
    LInfo.Bindings[LIdx].TSym, 'FixTray.pas', 7, 5));
  LIdx := AtLine(16);
  Ok('dock: a path nothing answers still dangles', (LIdx >= 0) and
    (LInfo.Bindings[LIdx].TSym = NIL_SYM) and not LInfo.Bindings[LIdx].NoField);
  LSites := Sites('FixTray.pas', 7, 5);
  Ok('dock: the field''s sites hold both frame-block lines',
    HasSite(LSites, 'FixDock.dfm', 7, 28, fskComponentRef, 'TrayLabel') and
    HasSite(LSites, 'FixDock.dfm', 12, 28, fskComponentRef, 'TrayLabel'));
end;

procedure CollChecks;
var
  LInfo: TPasFormInfo;
  LIdx: Integer;
  LDoc: IPasDfmDoc;
begin
  Ok('coll: described whole, the text after the root''s end said',
    GNav.DescribeForm(FilePath('FixColl.dfm'), LInfo) and (LInfo.Error = '')
    and (LInfo.TrailingLine = 17));
  Ok('coll: a Boolean named like an event is no event',
    FormBinding(LInfo, 'FixCollForm', 'OneOnRow') < 0);
  LIdx := FormBinding(LInfo, 'Grid', 'OnClick');
  Ok('coll: `OnClick = nil` is cleared, not a missing method', (LIdx >= 0)
    and LInfo.Bindings[LIdx].IsMethod and LInfo.Bindings[LIdx].Cleared and
    (LInfo.Bindings[LIdx].TSym = NIL_SYM));
  LIdx := FormBinding(LInfo, 'Grid', 'Items[0].OnPrint');
  Ok('coll: the first item''s event, by its index', (LIdx >= 0) and
    (LInfo.Bindings[LIdx].Line = 7) and IsSymAt(LInfo.Bindings[LIdx].TMid,
    LInfo.Bindings[LIdx].TSym, 'FixColl.pas', 7, 15));
  LIdx := FormBinding(LInfo, 'Grid', 'Items[1].OnPrint');
  Ok('coll: the second item''s event, a binding of its own', (LIdx >= 0) and
    (LInfo.Bindings[LIdx].Line = 10) and IsSymAt(LInfo.Bindings[LIdx].TMid,
    LInfo.Bindings[LIdx].TSym, 'FixColl.pas', 8, 15));
  Ok('coll: nothing after the root''s end is read',
    (FormObj(LInfo, 'Stray') < 0) and (Length(LInfo.Bindings) = 3));
  Ok('coll: PrintA''s site is the item''s line, not the stray one',
    HasSite(Sites('FixColl.pas', 7, 15), 'FixColl.dfm', 7, 19, fskHandler,
    'Grid') and (Length(Sites('FixColl.pas', 7, 15)) = 1));
  LDoc := PasDfmLoad(FilePath('FixColl.dfm'));
  Ok('coll: the stray text names PrintA as a word, not Print',
    LDoc.Doc.MentionsTrailing('printa') and
    not LDoc.Doc.MentionsTrailing('print'));
  LDoc := PasDfmLoad(FilePath('FixBase.dfm'));
  Ok('coll: a form with nothing after its root', (LDoc.Doc.TrailingLine = 0)
    and not LDoc.Doc.MentionsTrailing('button1'));
end;

{ A form file that appears after the binder listed its directory is read -
  the directory's write time moved - and one deleted and brought back, as a
  checkout does, is read again. }
procedure LateChecks;
var
  LInfo: TPasFormInfo;
  LIdx: Integer;
begin
  Ok('late: no form file yet', not GNav.DescribeForm(FilePath('FixLate.dfm'),
    LInfo));
  TFile.WriteAllText(FilePath('FixLate.dfm'), DFM_LATE, TEncoding.ASCII);
  Ok('late: a form file written after the listing is read',
    GNav.DescribeForm(FilePath('FixLate.dfm'), LInfo) and
    (LInfo.Error = ''));
  LIdx := FormBinding(LInfo, 'LateButton', 'OnClick');
  Ok('late: its handler bound', (LIdx >= 0) and IsSymAt(
    LInfo.Bindings[LIdx].TMid, LInfo.Bindings[LIdx].TSym, 'FixLate.pas', 7,
    15));
  Ok('late: the handler''s sites hold it', HasSite(Sites('FixLate.pas', 7, 15),
    'FixLate.dfm', 3, 15, fskHandler, 'LateButton'));
  TFile.Delete(FilePath('FixLate.dfm'));
  Ok('late: deleted, no site', Length(Sites('FixLate.pas', 7, 15)) = 0);
  TFile.WriteAllText(FilePath('FixLate.dfm'), DFM_LATE, TEncoding.ASCII);
  Ok('late: brought back, read again', HasSite(Sites('FixLate.pas', 7, 15),
    'FixLate.dfm', 3, 15, fskHandler, 'LateButton'));
end;

begin
  GCounter.Init;
  GDir := TPath.Combine(TPath.GetTempPath, 'pastree_dfm_smoke');
  if TDirectory.Exists(GDir) then
    TDirectory.Delete(GDir, True);
  TDirectory.CreateDirectory(GDir);
  TFile.WriteAllText(FilePath('System.pas'), UNIT_SYS);
  TFile.WriteAllText(FilePath('FixVcl.pas'), UNIT_VCL);
  TFile.WriteAllText(FilePath('FixData.pas'), UNIT_DATA);
  TFile.WriteAllText(FilePath('FixData.dfm'), DFM_DATA, TEncoding.ASCII);
  TFile.WriteAllText(FilePath('FixFrame.pas'), UNIT_FRAME);
  TFile.WriteAllText(FilePath('FixFrame.dfm'), DFM_FRAME, TEncoding.ASCII);
  TFile.WriteAllText(FilePath('FixBase.pas'), UNIT_BASE);
  TFile.WriteAllText(FilePath('FixBase.dfm'), DFM_BASE, TEncoding.ASCII);
  TFile.WriteAllText(FilePath('FixChild.pas'), UNIT_CHILD);
  TFile.WriteAllText(FilePath('FixGrand.pas'), UNIT_GRAND);
  TFile.WriteAllText(FilePath('FixChild.dfm'), DFM_CHILD, TEncoding.ASCII);
  TFile.WriteAllText(FilePath('FixBin.pas'), UNIT_BIN);
  WriteBinaryForm(FilePath('FixBin.dfm'), DFM_BIN_TEXT);
  TFile.WriteAllText(FilePath('FixBroken.pas'), UNIT_BROKEN);
  TFile.WriteAllText(FilePath('FixBroken.dfm'), DFM_BROKEN, TEncoding.ASCII);
  TFile.WriteAllText(FilePath('FixCap.pas'), UNIT_CAP);
  TFile.WriteAllText(FilePath('FixCap.dfm'), DFM_CAP, TEncoding.ASCII);
  TFile.WriteAllText(FilePath('FixPane.pas'), UNIT_PANE);
  TFile.WriteAllText(FilePath('FixPane.dfm'), DFM_PANE, TEncoding.ASCII);
  TFile.WriteAllText(FilePath('FixHost.pas'), UNIT_HOST);
  TFile.WriteAllText(FilePath('FixHost.dfm'), DFM_HOST, TEncoding.ASCII);
  TFile.WriteAllText(FilePath('FixHostKid.pas'), UNIT_HOSTKID);
  TFile.WriteAllText(FilePath('FixHostKid.dfm'), DFM_HOSTKID, TEncoding.ASCII);
  TFile.WriteAllText(FilePath('FixHostGrand.pas'), UNIT_HOSTGRAND);
  TFile.WriteAllText(FilePath('FixHostGrand.dfm'), DFM_HOSTGRAND,
    TEncoding.ASCII);
  TFile.WriteAllText(FilePath('FixLate.pas'), UNIT_LATE);
  TFile.WriteAllText(FilePath('FixTray.pas'), UNIT_TRAY);
  TFile.WriteAllText(FilePath('FixTray.dfm'), DFM_TRAY, TEncoding.ASCII);
  TFile.WriteAllText(FilePath('FixDock.pas'), UNIT_DOCK);
  TFile.WriteAllText(FilePath('FixDock.dfm'), DFM_DOCK, TEncoding.ASCII);
  TFile.WriteAllText(FilePath('FixColl.pas'), UNIT_COLL);
  TFile.WriteAllText(FilePath('FixColl.dfm'), DFM_COLL, TEncoding.ASCII);

  GProj := TPasSemaProject.Create(pfWin32, [GDir], []);
  try
    GProj.AnalyzeDirectory(GDir);
    GNav := TPasNavigator.Create(GProj);
    try
      ReaderChecks;
      SiteChecks;
      RenameChecks;
      CarryChecks;
      DescribeChecks;
      AncestorChecks;
      InheritedInlineChecks;
      CollChecks;
      DockChecks;
      PropChecks;
      LateChecks;
    finally
      GNav.Free;
    end;
  finally
    GProj.Free;
    PasDfmForget;
    if TDirectory.Exists(GDir) then
      TDirectory.Delete(GDir, True);
  end;

  if GCounter.Finish('DfmSmoke') then
    ExitCode := 1;
end.
