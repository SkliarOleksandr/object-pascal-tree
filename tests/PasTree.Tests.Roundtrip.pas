unit PasTree.Tests.Roundtrip;

{
  Test-coverage plan step 4 / README definition-of-done item 2: concatenated
  tokens + trivia == the original source, byte-for-byte -- even for malformed
  input, since a lexer that only stays lossless on well-formed source is not
  full-fidelity. RoundtripHolds (PasTree.TestKit) already proved this at SCALE
  over the flattened RTL+VCL+FMX corpora via tools/PasTreeLex's offset-based
  CheckCoverage (0 coverage failures on 110M+ chars, both corpora, 2026-08-09)
  -- this unit is the fast, in-repo counterpart: one case per B-chapter
  lexical feature (comment forms, directives, every literal shape, the
  malformed-input paths), plus one aggregate case that reuses every source
  string already sitting in PasTree.Tests.Parser for free.
}

interface

uses
  PasTree.TestKit,
  PasTree.Tests.Parser;

function BuildRoundtripCases: TPasCustomCases;

implementation

uses
  System.SysUtils;

function AllCaseSourcesCase: TPasCustomCase;
begin
  Result.Section := '';
  Result.Name := 'every ParserSmoke case source round-trips';
  Result.Run :=
    function: TPasCheckResult
    var
      LIdx, LAt: Integer;
      LFailed: string;
    begin
      LFailed := '';
      for LIdx := 0 to High(STMT_CASES) do
        if not RoundtripHolds(STMT_CASES[LIdx].Source, LAt) then
          LFailed := LFailed + '  stmt ' + STMT_CASES[LIdx].Section + ' ' +
            STMT_CASES[LIdx].Name + ' (offset ' + IntToStr(LAt) + ')' +
            sLineBreak;
      for LIdx := 0 to High(DECL_CASES) do
        if not RoundtripHolds(DECL_CASES[LIdx].Source, LAt) then
          LFailed := LFailed + '  decl ' + DECL_CASES[LIdx].Section + ' ' +
            DECL_CASES[LIdx].Name + ' (offset ' + IntToStr(LAt) + ')' +
            sLineBreak;
      Result.Passed := LFailed = '';
      Result.Message := LFailed;
    end;
end;

function BuildRoundtripCases: TPasCustomCases;
begin
  Result := [
    AllCaseSourcesCase,

    // ---- B.1 source text: the three line-break forms, mixed in one source
    // (CRLF, bare LF, bare CR all end a line per B.1) ----
    RoundtripCase('B.1', 'mixed line-break forms',
      'X := 1;'#13#10'Y := 2;'#10'Z := 3;'#13'W := 4;'),

    // ---- B.2.1 all three comment forms in one source, incl. cross-
    // delimiter nesting (`{ (* *) }` nests; same-delimiter does not) ----
    RoundtripCase('B.2.1', 'all three comment forms',
      '// line comment'#13#10 +
      '{ brace comment with (* nested paren *) inside }'#13#10 +
      '(* paren comment with { nested brace } inside *)'#13#10 +
      'X := 1; // trailing'),

    // ---- B.2.2 a compiler directive is lexically a comment whose first
    // char is $; the roundtrip only cares that it is still trivia text ----
    RoundtripCase('B.2.2', 'compiler directive',
      '{$IFDEF MSWINDOWS}X := 1;{$ELSE}X := 2;{$ENDIF}'),

    // ---- B.3 the & escape: one leading & escapes, a SECOND & is part of
    // the name (&&op_Equality names &op_Equality -- see PasTree.Lexer's Run) ----
    RoundtripCase('B.3', 'ampersand-escaped identifiers',
      'var'#13#10'  &Type: Integer;'#13#10'  &&op_Equality: Boolean;'),

    // ---- B.5.1 every integer literal form: decimal, hex, binary, and a
    // digit separator ----
    RoundtripCase('B.5.1', 'integer literal forms',
      'A := 42; B := $FF; C := %1010; D := 1_000_000;'),

    // ---- B.6.1 a string literal with a doubled-quote escape ----
    RoundtripCase('B.6.1', 'quoted string with an escaped quote',
      'S := ''it''''s here'';'),

    // ---- B.6.2 caret control chars and every #-numeric form ----
    RoundtripCase('B.6.2', 'caret and numeric control characters',
      'S := ^M#13#$0D#%1101;'),

    // ---- B.6.3 a multiline (triple-quoted) string literal, whole block as
    // one token ----
    RoundtripCase('B.6.3', 'multiline string literal',
      'const A =' + #13#10 + '    ''''''' + #13#10 +
      '    line one' + #13#10 + '    line two' + #13#10 +
      '    ''''''' + ';'),

    // ---- Malformed input: the lossless promise must hold even where the
    // lexer ALSO raises a diagnostic -- an unterminated string, comment,
    // directive and asm block, plus one outright invalid character ----
    RoundtripCase('B.6.1', 'unterminated string at EOF',
      'S := ''never closed'),
    RoundtripCase('B.2.1', 'unterminated brace comment at EOF',
      '{ never closed'),
    RoundtripCase('B.2.2', 'unterminated directive at EOF',
      '{$IFDEF never closed'),
    RoundtripCase('6.10', 'unterminated asm block at EOF',
      'asm MOV AX, BX'),
    RoundtripCase('B.1', 'an outright invalid character',
      'X := 1' + #0 + '; Y := 2;'),

    // ---- 6.10 an asm block with a labeled jump named END, tabs, and a
    // BASM string -- the shape the lexer's word-boundary check for the
    // closing `end` exists for (Vcl.Graphics.pas: `JS @@END` / `@@END:`) ----
    RoundtripCase('6.10', 'asm block with an END-named label and tabs',
      'asm'#13#10#9'JS @@END'#13#10#9'MOV AL, "x"'#13#10 +
      '@@END:'#13#10'end;')
  ];
end;

end.
