unit PasTree.CondEval;

{
  PasTree — the `$IF` / `$ELSEIF` expression evaluator (spec 1.3.2, B.2.2).

  The GRAMMAR is not here: the expression text is parsed by the real
  TPasParser (ParseExpressionText), so the preprocessor's conditional
  expressions and the language's expressions can never drift apart — any
  construct the parser learns is automatically legal in `$IF`. This unit
  only EVALUATES the resulting tree, under a context of things the
  preprocessor knows (defines, compiler version, seeded type sizes, an
  optional Declared() oracle).

  A name only the semantic phase could resolve (a unit constant, an
  unanswered Declared(), SizeOf of a user type, Ord(x)) evaluates as a
  GUESS AT THE LEAF — False (0 for SizeOf) — and computation proceeds
  normally, exactly as the old string-walking evaluator did. The leaf-level
  guess is LOAD-BEARING, found the hard way (a Kleene draft of this unit
  propagated "unknown" to the top instead, and a corpus diff caught 6 RTL
  units taking different branches): the RTL's fallback idiom is

      $IF not Declared(socklen_t) ... declare it ... $ENDIF

  and only `not False = True` takes the fallback, which is what keeps the
  name resolvable either way. The second pass is calibrated to the same
  guess: RunDeclaredPass re-preprocesses exactly the units where a recorded
  name turns out DECLARED — the one case where the False guess was wrong.

  What the guess taints, however, is tracked: TPasCondValue.Guessed rides
  along, and an and/or whose verdict is settled by a CLEAN side alone drops
  the other side's taint (dcc32 37.0-probed: dcc short-circuits
  left-to-right, so `Defined(FPC) and (FPC_FULLVERSION < 30301)` — the
  RTL's own System.Skia.API shape — never evaluates the undeclared name;
  same verdict here, and no needs-semantics flag, because no second pass
  could change it).

  One dcc divergence, probed and deliberate: when dcc actually EVALUATES an
  identifier that is declared nowhere, it abandons the whole expression
  with a fixed verdict — True if the unknown sat in a relational or
  arithmetic position (`(UNDECL > 3) and Defined(NOPE)` takes the TRUE
  branch, the `and False` ignored; so do `not (UNDECL > 3)` and nested
  parens), False in a bare boolean position (`$IF UNDECL`,
  `$IF not UNDECL`). We compute with the False guess instead: for names
  that ARE declared somewhere the second pass supplies the real value and
  the quirk never matters, and code relying on the abort-True of a
  genuinely undeclared name would be fragile under dcc itself.
}

interface

uses
  PasTree.Types,
  PasTree.Ast,
  PasTree.Preprocessor;

type
  TPasCondKind = (cvBool, cvNum, cvStr);

  TPasCondValue = record
    Kind: TPasCondKind;
    Bool: Boolean;
    Num: Double;
    Str: string;
    // A guessed leaf contributed to THIS value. Cleared when an and/or was
    // settled by a clean side alone — the flag's consumer is the
    // needs-semantics diagnostic, i.e. "could a second pass change this
    // verdict", and a Kleene-decided verdict it could not.
    Guessed: Boolean;
  end;

  TPasCondContext = record
    // Inputs.
    Defines: TPasDefines;            // nil tolerated (tree-eval of const
                                     // initializers has no define set; a
                                     // Defined() there just guesses)
    OnDeclared: TPasDeclaredQuery;   // nil = nobody can answer Declared()
    OnSymbol: TPasCondSymbolQuery;   // nil = nobody can answer const/SizeOf/
                                     // Length questions (the first pass)
    CompilerVersion: Double;         // answers RTLVersion too (equal since XE2)
    PointerBytes: Integer;
    ExtendedBytes: Integer;
    // Outputs.
    UnknownDeclared: TArray<string>; // Declared() names nobody answered
    UnknownSymbols: TArray<TPasUnresolvedSymbol>; // ...and symbol questions
  end;

{ Evaluates the expression rooted at ANode. Never raises; anything it cannot
  prove evaluates as a False/0 guess with Guessed set. }
function EvalCondNode(const ATree: TPasTree; ANode: Integer;
  var ACtx: TPasCondContext): TPasCondValue;

{ Lex + parse (TPasParser.ParseExpressionText) + evaluate AExpr. ABadExpr is
  the old `Failed`: the text does not parse as an expression at all. The tree
  is still evaluated in that case — solely so UnknownDeclared gets recorded,
  matching the old evaluator's deliberate behavior ("a half-parsed expression
  that mentioned a name is still a case a second pass could learn from"). }
function EvalCondText(const AExpr: string; var ACtx: TPasCondContext;
  out ABadExpr: Boolean): TPasCondValue;

{ The branch verdict. }
function CondAsBool(const AValue: TPasCondValue): Boolean;
function CondAsNum(const AValue: TPasCondValue): Double;

{ SizeOf(X) for the SEEDED builtin types only, parameterized by target.
  Public because the projects symbol oracle sizes record FIELDS with it. }
function PasBuiltinSizeOf(const AName: string; APointerBytes,
  AExtendedBytes: Integer; out ASize: Double): Boolean;

implementation

uses
  System.SysUtils,
  PasTree.Parser;

function MkBool(AValue: Boolean): TPasCondValue;
begin
  Result := Default(TPasCondValue);
  Result.Kind := cvBool;
  Result.Bool := AValue;
end;

function MkNum(AValue: Double): TPasCondValue;
begin
  Result := Default(TPasCondValue);
  Result.Kind := cvNum;
  Result.Num := AValue;
end;

// The leaf guess: False for a boolean position, 0 where a number is wanted
// (the SizeOf case constructs its own). See the unit comment for why the
// guess sits at the LEAF and not at the top.
function MkGuess: TPasCondValue;
begin
  Result := MkBool(False);
  Result.Guessed := True;
end;

function CondAsBool(const AValue: TPasCondValue): Boolean;
begin
  case AValue.Kind of
    cvBool: Result := AValue.Bool;
    cvNum: Result := AValue.Num <> 0;
  else
    Result := AValue.Str <> '';
  end;
end;

function CondAsNum(const AValue: TPasCondValue): Double;
begin
  case AValue.Kind of
    cvNum: Result := AValue.Num;
    cvBool: Result := Ord(AValue.Bool);
  else
    Result := 0;
  end;
end;

// Token text -> number. Handles what the LEXER can hand us: decimal, real,
// $hex, %binary, digit separators. (The old string-walking evaluator only
// knew bare decimals — `$IF $10 > 15` was a bad expression; the real lexer
// tokenizes it, so it now evaluates.)
function CondNumOfText(const AText: string; out ANum: Double): Boolean;
var
  LClean: string;
  L64: Int64;
  LIdx: Integer;
begin
  ANum := 0;
  LClean := AText.Replace('_', '');
  if LClean = '' then
    Exit(False);
  case LClean[1] of
    '$':
      begin
        Result := TryStrToInt64(LClean, L64);
        if Result then
          ANum := L64;
      end;
    '%':
      begin
        if Length(LClean) < 2 then
          Exit(False);
        L64 := 0;
        for LIdx := 2 to Length(LClean) do
          case LClean[LIdx] of
            '0': L64 := L64 * 2;
            '1': L64 := L64 * 2 + 1;
          else
            Exit(False);
          end;
        ANum := L64;
        Result := True;
      end;
  else
    Result := TryStrToFloat(LClean, ANum, TFormatSettings.Invariant);
  end;
end;

// Token text -> string value: strip the outer quotes, un-double the inner
// ones. #-char forms come back as written (the old evaluator had no support
// for them either; nothing in a real `$IF` compares control characters).
function CondStrOfText(const AText: string): string;
var
  LIdx: Integer;
begin
  if (AText = '') or (AText[1] <> '''') then
    Exit(AText);
  Result := '';
  LIdx := 2;
  while LIdx <= Length(AText) do
  begin
    if AText[LIdx] = '''' then
    begin
      if (LIdx < Length(AText)) and (AText[LIdx + 1] = '''') then
      begin
        Result := Result + '''';
        Inc(LIdx, 2);
      end
      else
        Break;
    end
    else
    begin
      Result := Result + AText[LIdx];
      Inc(LIdx);
    end;
  end;
end;

// A Declared() argument is a DESIGNATOR, not a bare identifier — the RTL
// writes `Declared(System.Embedded)`. '' = a shape we cannot name (and the
// caller guesses).
function DottedNameOf(const ATree: TPasTree; ANode: Integer): string;
var
  LChild: Integer;
begin
  case ATree.Nodes[ANode].Kind of
    nkIdent:
      Result := ATree.NodeText(ANode);
    nkMember:
      begin
        Result := '';
        LChild := ATree.Nodes[ANode].FirstChild;
        while LChild <> NIL_NODE do
        begin
          if ATree.Nodes[LChild].Kind <> nkIdent then
            Exit('');
          if Result <> '' then
            Result := Result + '.';
          Result := Result + ATree.NodeText(LChild);
          LChild := ATree.Nodes[LChild].NextSibling;
        end;
      end;
  else
    Result := '';
  end;
end;

function PasBuiltinSizeOf(const AName: string; APointerBytes,
  AExtendedBytes: Integer; out ASize: Double): Boolean;
begin
  Result := True;
  if SameText(AName, 'Pointer') or SameText(AName, 'NativeInt') or
     SameText(AName, 'NativeUInt') then
    ASize := APointerBytes
  else if SameText(AName, 'Extended') then
    ASize := AExtendedBytes
  else if SameText(AName, 'Int64') or SameText(AName, 'UInt64') or
    SameText(AName, 'Double') or SameText(AName, 'Currency') then
    ASize := 8
  else if SameText(AName, 'Integer') or SameText(AName, 'Cardinal') or
    SameText(AName, 'LongInt') or SameText(AName, 'LongWord') or
    SameText(AName, 'Single') then
    ASize := 4
  else if SameText(AName, 'Char') or SameText(AName, 'WideChar') or
    SameText(AName, 'Word') or SameText(AName, 'SmallInt') then
    ASize := 2
  else if SameText(AName, 'AnsiChar') or SameText(AName, 'Byte') or
    SameText(AName, 'ShortInt') or SameText(AName, 'Boolean') then
    ASize := 1
  else
  begin
    ASize := 0;
    Result := False;
  end;
end;

function EvalCondNode(const ATree: TPasTree; ANode: Integer;
  var ACtx: TPasCondContext): TPasCondValue;

  // Records one unanswerable question. sqDeclared additionally feeds
  // UnknownDeclared, which RunDeclaredPass's candidate filter reads.
  procedure AddUnknown(AQuery: TPasSymbolQuery; const AName: string);
  var
    LSym: TPasUnresolvedSymbol;
  begin
    LSym.Query := AQuery;
    LSym.Name := AName;
    ACtx.UnknownSymbols := ACtx.UnknownSymbols + [LSym];
    if AQuery = sqDeclared then
      ACtx.UnknownDeclared := ACtx.UnknownDeclared + [AName];
  end;

  // A symbol question: ask the oracle when there is one, otherwise record
  // the question (kind + name) for the second pass and return the guess —
  // exactly the Declared() contract, widened.
  function AskSymbol(AQuery: TPasSymbolQuery; const AName: string;
    const AGuess: TPasCondValue): TPasCondValue;
  var
    LNum: Double;
  begin
    if Assigned(ACtx.OnSymbol) and ACtx.OnSymbol(AQuery, AName, LNum) then
      Exit(MkNum(LNum));
    AddUnknown(AQuery, AName);
    Result := AGuess;
    Result.Guessed := True;
  end;

  function EvalCall(ACallNode: Integer): TPasCondValue;
  var
    LCallee, LArg: Integer;
    LName, LArgName: string;
    LKnown: Boolean;
    LSize: Double;
  begin
    Result := MkGuess;
    LCallee := ATree.Nodes[ACallNode].FirstChild;
    if (LCallee = NIL_NODE) or (ATree.Nodes[LCallee].Kind <> nkIdent) then
      Exit;
    LName := ATree.NodeText(LCallee);
    LArg := ATree.Nodes[LCallee].NextSibling;
    if LArg = NIL_NODE then
      Exit;

    if SameText(LName, 'Defined') then
    begin
      if (ATree.Nodes[LArg].Kind = nkIdent) and Assigned(ACtx.Defines) then
        Result := MkBool(ACtx.Defines.IsDefined(ATree.NodeText(LArg)));
    end
    else if SameText(LName, 'Declared') then
    begin
      LArgName := DottedNameOf(ATree, LArg);
      if LArgName = '' then
        Exit;
      if Assigned(ACtx.OnDeclared) and ACtx.OnDeclared(LArgName, LKnown) then
        // Somebody with a symbol table answered — see TPasDeclaredQuery.
        // Not recorded, because it is not a guess.
        Result := MkBool(LKnown)
      else
        // Nobody can answer yet: the symbol table that knows is built from
        // the token stream this very decision produces. False is the guess —
        // the guarded text is by construction the text that does NOT compile
        // when the name IS declared, and `not Declared(X)` fallbacks then
        // come out True, keeping the name resolvable. The NAME is recorded
        // so a caller with a symbol table can come back and ask properly —
        // twice over: UnknownDeclared drives RunDeclaredPass's candidate
        // filter, UnknownSymbols rides on the diagnostic so a reporter can
        // tell an UNVERIFIED guess from one a full symbol table later
        // CONFIRMED (see TPasPPDiagnostic.Unanswered).
        AddUnknown(sqDeclared, LArgName);
    end
    else if SameText(LName, 'SizeOf') then
    begin
      if (ATree.Nodes[LArg].Kind = nkIdent) and
         PasBuiltinSizeOf(ATree.NodeText(LArg), ACtx.PointerBytes,
           ACtx.ExtendedBytes, LSize) then
        Result := MkNum(LSize)
      else
      begin
        // A user type's size: the oracle's question; guessed 0 (like the
        // old evaluator) when nobody answers.
        LArgName := DottedNameOf(ATree, LArg);
        if LArgName <> '' then
          Result := AskSymbol(sqSizeOfType, LArgName, MkNum(0))
        else
        begin
          Result := MkNum(0);
          Result.Guessed := True;
        end;
      end;
    end
    else if SameText(LName, 'Length') then
    begin
      // Length(X) of an array constant/variable — System.pas guards on
      // `Length(RegisteredTypeInfoTable)`. Guess 0 when unanswered.
      LArgName := DottedNameOf(ATree, LArg);
      if LArgName <> '' then
        Result := AskSymbol(sqLengthOf, LArgName, MkNum(0));
    end
    else
      // Anything else (Ord(x), a unit function, ...) stays a guess — but the
      // CALLEE is recorded so a reporter can say what it choked on. Without
      // this the guess carries no question at all, and a filter that trusts
      // "no open questions" would call it verified.
      AddUnknown(sqConstValue, LName + '()');
  end;

  function EvalRel(const AOp: string; const L, R: TPasCondValue):
    TPasCondValue;
  begin
    if (L.Kind = cvStr) and (R.Kind = cvStr) then
    begin
      // Case-insensitive on purpose — ported behavior; version strings in
      // the wild compare like define names.
      if AOp = '=' then
        Result := MkBool(SameText(L.Str, R.Str))
      else if AOp = '<>' then
        Result := MkBool(not SameText(L.Str, R.Str))
      else
        Result := MkBool(False);
    end
    else if AOp = '=' then
      Result := MkBool(CondAsNum(L) = CondAsNum(R))
    else if AOp = '<>' then
      Result := MkBool(CondAsNum(L) <> CondAsNum(R))
    else if AOp = '<' then
      Result := MkBool(CondAsNum(L) < CondAsNum(R))
    else if AOp = '>' then
      Result := MkBool(CondAsNum(L) > CondAsNum(R))
    else if AOp = '<=' then
      Result := MkBool(CondAsNum(L) <= CondAsNum(R))
    else
      Result := MkBool(CondAsNum(L) >= CondAsNum(R));
    Result.Guessed := L.Guessed or R.Guessed;
  end;

  function EvalBinary(ABinNode: Integer): TPasCondValue;
  var
    LLeftNode, LRightNode: Integer;
    LOp: string;
    L, R: TPasCondValue;
  begin
    Result := MkGuess;
    LLeftNode := ATree.Nodes[ABinNode].FirstChild;
    if LLeftNode = NIL_NODE then
      Exit;
    LRightNode := ATree.Nodes[LLeftNode].NextSibling;
    if LRightNode = NIL_NODE then
      Exit;
    if ATree.Nodes[ABinNode].Aux < 0 then
      Exit;
    LOp := LowerCase(ATree.Source.VisibleText(ATree.Nodes[ABinNode].Aux));

    L := EvalCondNode(ATree, LLeftNode, ACtx);
    R := EvalCondNode(ATree, LRightNode, ACtx);

    // and/or: a CLEAN side that settles the verdict alone drops the other
    // side's taint — the verdict cannot change no matter what the guessed
    // part turns out to be, so no second pass needs to look at it. This is
    // dcc's own left-to-right short-circuit, applied symmetrically (see the
    // unit comment for the probed divergence on undeclared names).
    if LOp = 'and' then
    begin
      if (not L.Guessed and not CondAsBool(L)) or
         (not R.Guessed and not CondAsBool(R)) then
        Exit(MkBool(False));
      Result := MkBool(CondAsBool(L) and CondAsBool(R));
      Result.Guessed := L.Guessed or R.Guessed;
      Exit;
    end;
    if LOp = 'or' then
    begin
      if (not L.Guessed and CondAsBool(L)) or
         (not R.Guessed and CondAsBool(R)) then
        Exit(MkBool(True));
      Result := MkBool(CondAsBool(L) or CondAsBool(R));
      Result.Guessed := L.Guessed or R.Guessed;
      Exit;
    end;
    if LOp = 'xor' then
    begin
      Result := MkBool(CondAsBool(L) xor CondAsBool(R));
      Result.Guessed := L.Guessed or R.Guessed;
      Exit;
    end;

    if (LOp = '=') or (LOp = '<>') or (LOp = '<') or (LOp = '>') or
       (LOp = '<=') or (LOp = '>=') then
      Exit(EvalRel(LOp, L, R));

    if LOp = '+' then
      Result := MkNum(CondAsNum(L) + CondAsNum(R))
    else if LOp = '-' then
      Result := MkNum(CondAsNum(L) - CondAsNum(R))
    else if LOp = '*' then
      Result := MkNum(CondAsNum(L) * CondAsNum(R))
    else if (LOp = '/') and (CondAsNum(R) <> 0) then
      Result := MkNum(CondAsNum(L) / CondAsNum(R))
    else if (LOp = 'div') and (Trunc(CondAsNum(R)) <> 0) then
      Result := MkNum(Trunc(CondAsNum(L)) div Trunc(CondAsNum(R)))
    else if (LOp = 'mod') and (Trunc(CondAsNum(R)) <> 0) then
      Result := MkNum(Trunc(CondAsNum(L)) mod Trunc(CondAsNum(R)))
    else
      // shl/shr/in/division by zero — nothing in a real $IF; a guess,
      // never a crash.
      Exit;
    Result.Guessed := L.Guessed or R.Guessed;
  end;

var
  LText: string;
  LNum: Double;
  LChild: Integer;
  LVal: TPasCondValue;
begin
  Result := MkGuess;
  if (ANode = NIL_NODE) or (ANode > High(ATree.Nodes)) then
    Exit;
  case ATree.Nodes[ANode].Kind of
    nkIntLit, nkRealLit:
      if CondNumOfText(ATree.NodeText(ANode), LNum) then
        Result := MkNum(LNum);
    nkStrLit:
      begin
        Result := Default(TPasCondValue);
        Result.Kind := cvStr;
        Result.Str := CondStrOfText(ATree.NodeText(ANode));
      end;
    nkIdent:
      begin
        LText := ATree.NodeText(ANode);
        if SameText(LText, 'True') then
          Result := MkBool(True)
        else if SameText(LText, 'False') then
          Result := MkBool(False)
        else if SameText(LText, 'CompilerVersion') or
                SameText(LText, 'RTLVersion') then
          Result := MkNum(ACtx.CompilerVersion)
        else
          // Any other bare name is a CONSTANT only semantics could resolve
          // (`$IF GenericVariants`, System.VarUtils) — the oracle's
          // question; guessed False when nobody answers (`$ELSEIF CPUX64`
          // in the RTL is a DEFINE used bare; dcc evaluates the undeclared
          // name by its quirk, we by the guess).
          Result := AskSymbol(sqConstValue, LText, MkBool(False));
      end;
    nkMember:
      begin
        // A dotted constant reference (`Unit.Const`) — same oracle question
        // with the dotted name; a shape we cannot name stays a guess.
        LText := DottedNameOf(ATree, ANode);
        if LText <> '' then
          Result := AskSymbol(sqConstValue, LText, MkBool(False));
      end;
    nkParen:
      begin
        LChild := ATree.Nodes[ANode].FirstChild;
        if LChild <> NIL_NODE then
          Result := EvalCondNode(ATree, LChild, ACtx);
      end;
    nkUnaryOp:
      begin
        LChild := ATree.Nodes[ANode].FirstChild;
        if (LChild = NIL_NODE) or (ATree.Nodes[ANode].Aux < 0) then
          Exit;
        LText := LowerCase(ATree.Source.VisibleText(ATree.Nodes[ANode].Aux));
        LVal := EvalCondNode(ATree, LChild, ACtx);
        if LText = 'not' then
          Result := MkBool(not CondAsBool(LVal))
        else if LText = '-' then
          Result := MkNum(-CondAsNum(LVal))
        else if LText = '+' then
          Result := LVal;
        Result.Guessed := LVal.Guessed;
      end;
    nkBinaryOp:
      Result := EvalBinary(ANode);
    nkCall:
      Result := EvalCall(ANode);
    // Everything else: a designator only semantics could resolve — a guess.
  end;
end;

function EvalCondText(const AExpr: string; var ACtx: TPasCondContext;
  out ABadExpr: Boolean): TPasCondValue;
var
  LTree: TPasTree;
  LRoot: Integer;
  LDiags: TArray<TPasParseDiag>;
begin
  LTree := TPasParser.ParseExpressionText(AExpr, LRoot, LDiags);
  ABadExpr := Length(LDiags) > 0;
  Result := EvalCondNode(LTree, LRoot, ACtx);
  if ABadExpr then
    Result := MkBool(False);
end;

end.
