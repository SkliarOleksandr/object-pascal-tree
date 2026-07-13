unit DirectivesAsVariables;

{
  Ambiguity sample: weak keywords used as ordinary VARIABLE, PARAMETER and
  ROUTINE names, directly contrasted against the SAME words used in real
  directive/property-specifier position in TFoo. Lexically identical
  tkIdentifier tokens either way — only the parser's grammar position tells
  them apart. This is the exact shape of the bug the user found by hand:
  `var dynamic: Integer;` was rendering `dynamic` as a keyword before
  PasTreeDemo.Highlighter switched from a flat word-list check to AST-precise
  spans (see the unit's header comment).

  Expected coloring:
    - Bar/Baz's trailing `virtual`/`override`      -> Keyword (real directive)
    - X's `read`/`write`                            -> Keyword (real prop spec)
    - every other occurrence of dynamic/override/virtual/message/read/write/
      static below                                  -> Identifier
}

interface

type
  TFooBase = class
    procedure Baz; virtual;
  end;

  TFoo = class(TFooBase)
  private
    FX: Integer;
    function FGetX: Integer;
  public
    procedure Bar; virtual;
    procedure Baz; override;
    property X: Integer read FGetX write FX;
  end;

procedure static;
procedure UseParam(dynamic: Integer; const override: string);

var
  dynamic, override, virtual, message, read, write: Integer;

implementation

procedure static;
begin
end;

procedure TFooBase.Baz;
begin
end;

procedure UseParam(dynamic: Integer; const override: string);
begin
  dynamic := dynamic + Length(override);
end;

function TFoo.FGetX: Integer;
begin
  Result := FX;
end;

procedure TFoo.Bar;
begin
  dynamic := virtual;
end;

procedure TFoo.Baz;
begin
end;

end.
