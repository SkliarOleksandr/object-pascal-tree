unit PasTree.Ast;

{
  PasTree — the homogeneous AST.

  Design (see README):
  - One node type. A node is a 32-byte record in a contiguous per-unit
    array; all references are integer indices (NIL_NODE = -1).
  - Nodes carry no text: FirstToken/LastToken index the preprocessor's
    VISIBLE stream, and the underlying token slices provide all names and
    values (full fidelity lives in the token layer).
  - Aux is a kind-specific payload: for nkBinaryOp/nkUnaryOp it is the
    visible index of the operator token; for others see the kind comments.
  - Kinds reference the spec (object-pascal-spec) feature numbers.
    TODO: generate this enum from the spec's AST blocks (tools/kindsgen).
}

interface

uses
  PasTree.Types,
  PasTree.Preprocessor;

const
  NIL_NODE = -1;

type
  TPasNodeKind = (
    nkError,          // parse error recovery node
    nkMissing,        // expected element that was absent

    // ---- expressions (spec ch.04, B.9) ----
    nkIdent,          // identifier reference (incl. keyword-as-type: string)
    nkIntLit, nkRealLit, nkStrLit, nkNilLit,
    nkCaretChar,      // ^M caret control-char literal (B.6.2)
    nkUnaryOp,        // Aux = operator visible-token index (not/@/+/-)
    nkBinaryOp,       // Aux = operator visible-token index; is not/not in
                      // are flagged via nfNegated on the node
    nkParen,          // ( expr ) — kept for fidelity
    nkCall,           // callee = child 0, args follow (4.10 cast-vs-call is
                      // resolved semantically)
    nkFormattedArg,   // Write/Str colon-arg: expr [:width [:prec]] (4.11.2)
    nkIndex,          // base = child 0, indices follow
    nkMember,         // base = child 0, name = child 1 (nkIdent)
    nkDeref,          // base = child 0 (postfix ^)
    nkTypeArgs,       // generic argument list on a designator segment (16.3)
    nkSetCtor,        // [ ... ] set/array constructor (B.9)
    nkRange,          // a..b (case labels, set elements)
    nkInlineIf,       // if c then a else b expression (5.4.1)
    nkInherited,      // inherited [name] (12.1.2)
    nkAnonMethod,     // anonymous method literal (17.2.1); minimal v1
    nkAnonParams,     // raw parameter tokens of an anon method (v1 opaque)

    // ---- statements (spec ch.05, ch.18) ----
    nkBlock,          // begin..end / statement list container
    nkEmptyStmt,
    nkAssign,         // 5.1.1: target = child 0, value = child 1
    nkExprStmt,       // 5.1.2: call/designator in statement position
    nkIfStmt,         // 5.3.1: cond, then, [else]
    nkCaseStmt,       // 5.3.2: selector, selectors..., [else block]
    nkCaseSel,        // labels (nkCaseLabels) + body
    nkCaseLabels,     // list of exprs/ranges
    nkForStmt,        // 5.5.1: [inline var] counter, from, to, body;
                      // Aux = 1 when downto
    nkForInStmt,      // 5.5.2: [inline var] element, collection, body
    nkWhileStmt,      // 5.5.3
    nkRepeatStmt,     // 5.5.4: body block, cond
    nkWithStmt,       // 5.7: targets..., body (last child)
    nkGotoStmt,       // 5.6.4
    nkLabeledStmt,    // label ident + statement
    nkTryStmt,        // 18.1/18.2: block + (nkExceptPart | nkFinallyPart)
    nkExceptPart,     // handlers (nkExceptOn...) or bare block; [else block]
    nkExceptOn,       // 18.1.2: [name], type, body
    nkFinallyPart,
    nkRaiseStmt,      // 18.3.1: [expr [at-expr]]
    nkAsmStmt,        // 6.10: opaque BASM token range
    nkInlineVar,      // 3.1.3: name, [type], [init]
    nkInlineConst,    // 3.1.3 const form

    // ---- compilation units (spec ch.01) ----
    nkUnit,           // 1.1.2: name, [uses], interface, implementation, ...
    nkProgram,        // 1.1.1
    nkLibrary,        // 1.1.3
    nkPackage,        // 1.1.3: requires/contains
    nkUsesClause,     // 1.2.1: items
    nkUsesItem,       //   name [+ 'in' path string]
    nkInterfaceSec,
    nkImplementationSec,
    nkInitSec, nkFinalSec,
    nkExportsClause,  // 1.1.3: items
    nkExportsItem,

    // ---- declaration sections (spec ch.02/03/06) ----
    nkTypeSec, nkConstSec, nkVarSec, nkLabelSec,
    nkTypeDecl,       // name [generic params] = [type-mark] TypeExpr;
                      // Aux = 1 for distinct alias (= type X, 2.5.1)
    nkConstDecl,      // name [: type] = init [hints]
    nkVarDecl,        // names... : type [absolute X | = init]; also fields
    nkAggregate,      // typed-const initializer ( ... ) (3.2.2)
    nkAggregateField, //   name: value element

    // ---- type expressions (spec ch.02/08/09/10/B.11) ----
    nkSubrange,       // lo..hi (2.2.5)
    nkEnumType,       // ( a, b = 1, ... ) (2.2.4)
    nkEnumValue,      //   name [= const]
    nkArrayType,      // array [dims] of T; Aux = 1 for array of const (8.x)
    nkSetType,        // set of T (2.4.1)
    nkFileType,       // file [of T] (10.2.1)
    nkPointerType,    // ^T (10.1.1)
    nkStringType,     // string[N] (7.1.3)
    nkClassOf,        // class of T (15.2.1)
    nkProcType,       // procedure/function type (6.6.1);
                      // Aux: 1 = of object, 2 = reference to
    nkClassType,      // 11.1.1; Aux: 1 = forward declaration
    nkRecordType,     // 9.x
    nkInterfaceType,  // 14.1.1; dispinterface flagged via Aux = 1
    nkObjectType,     // 11.5 legacy
    nkHelperType,     // 15.3: class/record helper for T; Aux 1 = record
    nkGuid,           // 14.1.1: ['{...}']

    // ---- members & routines (spec ch.06/11/13) ----
    nkVisibility,     // 11.2.1: Aux encodes level; strict via flag
    nkRoutine,        // procedure/function/constructor/destructor/operator;
                      // children: name, [generic params], [params], [result
                      // type], directives..., [body]
    nkParams, nkParam,
    nkDirective,      // routine directive (+ optional args as children)
    nkPropertyDecl,   // 13.1.1: name, [index params], [type], specifiers
    nkPropSpec,       // read/write/index/stored/default/implements + expr
    nkMethodResolution, // 14.2.2: IFace.Method = ImplName
    nkVariantPart,    // 9.1.3: [tag] type + branches
    nkVariantBranch,  //   labels : ( fields )
    nkGenericParams,  // 16.1: <T; U: constraints>
    nkGenericParam,
    nkConstraint,     // class/record/constructor/typeref
    nkAttrGroup,      // 19.3.2: [Attr(args), ...]
    nkAttribute,
    nkRoutineBody     // local decl sections + compound/asm block
  );

  TPasNodeFlag = (
    nfError,      // subtree contains a parse error
    nfNegated     // is not / not in (4.9.1)
  );
  TPasNodeFlags = set of TPasNodeFlag;

  TPasNode = record
    Kind: TPasNodeKind;
    Flags: TPasNodeFlags;
    FirstToken: Integer;   // visible-stream index of first token
    LastToken: Integer;    // visible-stream index of last token (inclusive)
    Parent: Integer;
    FirstChild: Integer;
    NextSibling: Integer;
    Aux: Integer;          // kind-specific (see kind comments)
  end;

  { A parsed compilation: the preprocessed token layer plus the node arena.
    Root node is index 0. Immutable once built. }
  TPasTree = record
  public
    Source: TPasPreprocessed;
    Nodes: TArray<TPasNode>;
    function KindName(AKind: TPasNodeKind): string;
    function NodeText(AIndex: Integer): string;    // first-token slice
    { Compact S-expression dump for golden tests:
      Kind or Kind'text' or Kind(children...). }
    function Dump(AIndex: Integer): string;
  end;

  { Arena builder used by the parser. }
  TPasTreeBuilder = record
  private
    FNodes: TArray<TPasNode>;
    FCount: Integer;
    FLastChild: TArray<Integer>;  // parallel: last child per node
    procedure Grow;
  public
    procedure Init;
    function AddNode(AKind: TPasNodeKind; AParent, AFirstToken: Integer):
      Integer;
    procedure SetLast(ANode, ALastToken: Integer);
    procedure SetAux(ANode, AAux: Integer);
    procedure SetKind(ANode: Integer; AKind: TPasNodeKind);
    procedure AddFlag(ANode: Integer; AFlag: TPasNodeFlag);
    { Re-parents ANode under ANewParent (used when a parsed expression
      becomes the first child of an enclosing node, e.g. assignment). }
    procedure Adopt(ANewParent, ANode: Integer);
    function Kind(ANode: Integer): TPasNodeKind;
    function Build(const ASource: TPasPreprocessed): TPasTree;
  end;

implementation

uses
  System.SysUtils,
  System.TypInfo;

{ TPasTree }

function TPasTree.KindName(AKind: TPasNodeKind): string;
begin
  Result := GetEnumName(TypeInfo(TPasNodeKind), Ord(AKind));
  Delete(Result, 1, 2); // strip 'nk'
end;

function TPasTree.NodeText(AIndex: Integer): string;
begin
  if (Nodes[AIndex].FirstToken >= 0) and
     (Nodes[AIndex].FirstToken <= High(Source.Visible)) then
    Result := Source.VisibleText(Nodes[AIndex].FirstToken)
  else
    Result := '';
end;

function TPasTree.Dump(AIndex: Integer): string;
var
  LChild: Integer;
  LChildren: string;
  LText: string;
begin
  Result := KindName(Nodes[AIndex].Kind);
  case Nodes[AIndex].Kind of
    nkIdent, nkIntLit, nkRealLit, nkStrLit, nkCaretChar:
      Result := Result + '''' + NodeText(AIndex) + '''';
    nkUnaryOp, nkBinaryOp:
      if (Nodes[AIndex].Aux >= 0) then
      begin
        LText := Source.VisibleText(Nodes[AIndex].Aux);
        Result := Result + '''' + LowerCase(LText) + '''';
        if nfNegated in Nodes[AIndex].Flags then
          Result := Result + '!';
      end;
  end;
  LChildren := '';
  LChild := Nodes[AIndex].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if LChildren <> '' then
      LChildren := LChildren + ' ';
    LChildren := LChildren + Dump(LChild);
    LChild := Nodes[LChild].NextSibling;
  end;
  if LChildren <> '' then
    Result := Result + '(' + LChildren + ')';
end;

{ TPasTreeBuilder }

procedure TPasTreeBuilder.Init;
begin
  FNodes := nil;
  FLastChild := nil;
  FCount := 0;
  SetLength(FNodes, 64);
  SetLength(FLastChild, 64);
end;

procedure TPasTreeBuilder.Grow;
begin
  if FCount = Length(FNodes) then
  begin
    SetLength(FNodes, Length(FNodes) * 2);
    SetLength(FLastChild, Length(FNodes));
  end;
end;

function TPasTreeBuilder.AddNode(AKind: TPasNodeKind; AParent,
  AFirstToken: Integer): Integer;
begin
  Grow;
  Result := FCount;
  Inc(FCount);
  FNodes[Result].Kind := AKind;
  FNodes[Result].Flags := [];
  FNodes[Result].FirstToken := AFirstToken;
  FNodes[Result].LastToken := AFirstToken;
  FNodes[Result].Parent := AParent;
  FNodes[Result].FirstChild := NIL_NODE;
  FNodes[Result].NextSibling := NIL_NODE;
  FNodes[Result].Aux := NIL_NODE;
  FLastChild[Result] := NIL_NODE;
  if AParent <> NIL_NODE then
  begin
    if FNodes[AParent].FirstChild = NIL_NODE then
      FNodes[AParent].FirstChild := Result
    else
      FNodes[FLastChild[AParent]].NextSibling := Result;
    FLastChild[AParent] := Result;
  end;
end;

procedure TPasTreeBuilder.SetLast(ANode, ALastToken: Integer);
begin
  FNodes[ANode].LastToken := ALastToken;
end;

procedure TPasTreeBuilder.SetAux(ANode, AAux: Integer);
begin
  FNodes[ANode].Aux := AAux;
end;

procedure TPasTreeBuilder.SetKind(ANode: Integer; AKind: TPasNodeKind);
begin
  FNodes[ANode].Kind := AKind;
end;

procedure TPasTreeBuilder.AddFlag(ANode: Integer; AFlag: TPasNodeFlag);
begin
  Include(FNodes[ANode].Flags, AFlag);
end;

procedure TPasTreeBuilder.Adopt(ANewParent, ANode: Integer);
var
  LPrev, LCur: Integer;
begin
  // Detach from the old parent's child list.
  if FNodes[ANode].Parent <> NIL_NODE then
  begin
    LPrev := NIL_NODE;
    LCur := FNodes[FNodes[ANode].Parent].FirstChild;
    while (LCur <> NIL_NODE) and (LCur <> ANode) do
    begin
      LPrev := LCur;
      LCur := FNodes[LCur].NextSibling;
    end;
    if LCur = ANode then
    begin
      if LPrev = NIL_NODE then
        FNodes[FNodes[ANode].Parent].FirstChild := FNodes[ANode].NextSibling
      else
        FNodes[LPrev].NextSibling := FNodes[ANode].NextSibling;
      if FLastChild[FNodes[ANode].Parent] = ANode then
        FLastChild[FNodes[ANode].Parent] := LPrev;
    end;
  end;
  FNodes[ANode].NextSibling := NIL_NODE;
  FNodes[ANode].Parent := ANewParent;
  if FNodes[ANewParent].FirstChild = NIL_NODE then
    FNodes[ANewParent].FirstChild := ANode
  else
    FNodes[FLastChild[ANewParent]].NextSibling := ANode;
  FLastChild[ANewParent] := ANode;
end;

function TPasTreeBuilder.Kind(ANode: Integer): TPasNodeKind;
begin
  Result := FNodes[ANode].Kind;
end;

function TPasTreeBuilder.Build(const ASource: TPasPreprocessed): TPasTree;
begin
  SetLength(FNodes, FCount);
  Result.Nodes := FNodes;
  Result.Source := ASource;
  FNodes := nil;
  FLastChild := nil;
  FCount := 0;
end;

end.
