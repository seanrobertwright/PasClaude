{ Smoke tests for the parts that do not need a network: JSON round-trips and
  each tool, including the path guard.  Run from the repo root:
      fpc -Fusrc -FUbuild\units -FEbin tests\smoke.lpr && bin\smoke.exe }
program smoke;

{$mode objfpc}{$H+}

uses SysUtils, Classes, uJson, uHttp, uMcp, uHooks, uTools, uAgent, uRegex;

var
  Fails: Integer = 0;

procedure Check(Cond: Boolean; const What: string);
begin
  if Cond then
    WriteLn('ok   ', What)
  else
  begin
    WriteLn('FAIL ', What);
    Inc(Fails);
  end;
end;

procedure TestJson;
var
  J, K: TJson;
  Err, Nb, Want: string;
begin
  J := JsonParse('{"a":1,"b":[true,null,"x\ny"],"c":{"d":-2.5e1}}', Err);
  Check(J <> nil, 'parses a nested document');
  if J = nil then Exit;
  try
    Check(J.Num('a') = 1, 'reads a number');
    K := J.Find('b');
    Check((K <> nil) and (K.Count = 3), 'reads an array');
    Check(K.Item(2).AsString = 'x'#10'y', 'decodes \n');
    Check(J.Find('c').Num('d') = -25, 'reads exponent notation');
  finally
    J.Free;
  end;

  { Serialising must not depend on the locale's decimal separator. }
  J := TJson.NewObj;
  try
    J.AddNum('n', 1.5);
    J.AddStr('s', 'quote " and \ back');
    Check(Pos('1.5', J.ToJson) > 0, 'writes a decimal point, not a comma');
    K := JsonParse(J.ToJson, Err);
    Check((K <> nil) and (K.Str('s') = 'quote " and \ back'), 'escapes round-trip');
    K.Free;
  finally
    J.Free;
  end;

  Check(JsonParse('{"a":', Err) = nil, 'rejects truncated input');
  Check(JsonParse('[1,2', Err) = nil, 'rejects an unclosed array');

  J := JsonParse('"\ud83d\ude00"', Err);
  Check((J <> nil) and (Length(J.AsString) = 4), 'joins a surrogate pair into UTF-8');
  J.Free;

  { SetAt replaces a value where it stands.  Implementing it as Drop-then-Add
    would move the key to the end, which is why the position is asserted as
    well as the value; the discarded child must also be freed, and -gh is what
    checks that. }
  J := JsonParse('{"a":1,"b":2,"c":3}', Err);
  try
    J.SetAt(J.IndexOf('b'), TJson.NewStr('z'));
    Check(J.Str('b') = 'z', 'SetAt replaces a value');
    Check(J.Key(1) = 'b', 'SetAt leaves the key where it was');
    Check(J.ToJson = '{"a":1,"b":"z","c":3}', 'and the field order with it');
  finally
    J.Free;
  end;

  J := JsonParse('["a","b","c"]', Err);
  try
    J.InsertAt(1, TJson.NewStr('x'));
    Check((J.Count = 4) and (J.Item(0).AsString = 'a') and
          (J.Item(1).AsString = 'x') and (J.Item(2).AsString = 'b'),
      'InsertAt shifts the element it inserts before');
    J.InsertAt(99, TJson.NewStr('tail'));
    Check(J.Item(J.Count - 1).AsString = 'tail', 'an index past the end appends');
    J.InsertAt(0, TJson.NewStr('head'));
    Check(J.Item(0).AsString = 'head', 'and index 0 prepends');
  finally
    J.Free;
  end;

  { The exact bytes matter, not merely the shape: this is what Python's
    json.dumps(indent=1, sort_keys=True, separators=(',', ': ')) emits, which
    is what nbformat writes.  Any drift - two-space indent, ':' without the
    space, empty containers expanded - turns every future notebook write into
    a whole-file git diff, and only a character-for-character assertion sees
    it happen. }
  Nb := '{"cells":[{"cell_type":"code","execution_count":null,"id":"a1",' +
        '"metadata":{},"outputs":[],"source":["print(1)\n"]}],' +
        '"metadata":{},"nbformat":4,"nbformat_minor":5}';
  Want :=
    '{'#10 +
    ' "cells": ['#10 +
    '  {'#10 +
    '   "cell_type": "code",'#10 +
    '   "execution_count": null,'#10 +
    '   "id": "a1",'#10 +
    '   "metadata": {},'#10 +
    '   "outputs": [],'#10 +
    '   "source": ['#10 +
    '    "print(1)\n"'#10 +
    '   ]'#10 +
    '  }'#10 +
    ' ],'#10 +
    ' "metadata": {},'#10 +
    ' "nbformat": 4,'#10 +
    ' "nbformat_minor": 5'#10 +
    '}';
  J := JsonParse(Nb, Err);
  try
    Check(J.ToJsonPretty(True) = Want,
      'ToJsonPretty matches nbformat''s layout byte for byte');
    { Legible is not enough: the output has to still be JSON carrying the same
      values, or a pretty writer that eats a separator ships unnoticed. }
    K := JsonParse(J.ToJsonPretty(True), Err);
    Check((K <> nil) and (K.ToJson = J.ToJson), 'the pretty form reparses equal');
    K.Free;
  finally
    J.Free;
  end;
end;

function Run(const Name: string; Input: TJson; out IsErr: Boolean): string;
begin
  Result := uTools.RunTool(Name, Input, nil, IsErr);
  Input.Free;
end;

{ ------------------------------------------------------------ regex engine -- }

{ uRegex is public API precisely so its behaviour can be pinned without a
  file, a console or a network anywhere in the picture. }

procedure ReCheck(const Pat, Subj: string; Want: Boolean;
  CaseSensitive: Boolean = False);
var
  R: TRegex;
  E: string;
  Verdict: string;
begin
  if not TRegex.Compile(Pat, CaseSensitive, R, E) then
  begin
    Check(False, Format('/%s/ compiles (got "%s")', [Pat, E]));
    Exit;
  end;
  try
    if Want then Verdict := 'matches' else Verdict := 'rejects';
    Check((R.Match(Subj) = rrMatch) = Want,
      Format('/%s/ %s "%s"', [Pat, Verdict, Subj]));
  finally
    R.Free;
  end;
end;

procedure ReBad(const Pat, What: string);
var
  R: TRegex;
  E: string;
  Ok: Boolean;
begin
  Ok := not TRegex.Compile(Pat, False, R, E);
  if not Ok then R.Free;
  { R must be nil on failure: a half-built object handed back would be both a
    wrong answer and, under -gh, a leak. }
  Check(Ok and (E <> '') and (R = nil), What + ' is refused: ' + E);
end;

procedure TestRegexEngine;
var
  R: TRegex;
  E, Long: string;
  I: Integer;
begin
  { Literals, any-byte, classes and the shorthands. }
  ReCheck('abc', 'xxabcyy', True);
  ReCheck('abc', 'ab', False);
  ReCheck('a.c', 'abc', True);
  ReCheck('[a-z]+', 'ABC', True);
  ReCheck('[a-z]+', 'ABC', False, True);
  ReCheck('[^0-9]', '123', False);
  ReCheck('[^0-9]', '12a3', True);
  ReCheck('\d\d', 'a12b', True);
  ReCheck('\d\d', 'a1b2', False);
  ReCheck('\D', '123', False);
  ReCheck('\w+', '   ', False);
  ReCheck('\W', 'abc_1', False);
  ReCheck('\s', 'a b', True);
  ReCheck('\S', '   ', False);

  { Anchors and word boundaries. }
  ReCheck('^abc', 'abc', True);
  ReCheck('^abc', 'xabc', False);
  ReCheck('abc$', 'xabc', True);
  ReCheck('abc$', 'abcx', False);
  ReCheck('\bfoo\b', 'a foo b', True);
  ReCheck('\bfoo\b', 'afoo b', False);
  ReCheck('\Boo', 'foo', True);

  { Alternation and groups. }
  ReCheck('cat|dog', 'hotdog', True);
  ReCheck('cat|dog', 'bird', False);
  ReCheck('a|b|c', 'zzc', True);
  ReCheck('(?:ab)+', 'abab', True);
  ReCheck('(ab)c', 'abc', True);

  { Case folding is compile-time, so it must apply to bare letters and to
    class ranges alike, and must switch off when asked. }
  ReCheck('AbC', 'xabcx', True);
  ReCheck('AbC', 'xabcx', False, True);

  { Counted repeats: the tail-duplication code, and the likeliest place for
    an off-by-one that nothing else here would catch. }
  ReCheck('^a{2,4}$', 'a', False);
  ReCheck('^a{2,4}$', 'aa', True);
  ReCheck('^a{2,4}$', 'aaaa', True);
  ReCheck('^a{2,4}$', 'aaaaa', False);
  ReCheck('^a{2,}$', 'aaaaa', True);
  ReCheck('^a{2,}$', 'a', False);
  ReCheck('^(ab){2}$', 'abab', True);
  ReCheck('^(ab){2}$', 'aba', False);
  ReCheck('^(a|bb){2,3}$', 'bbabb', True);
  ReCheck('^(a|bb){2,3}$', 'bbabbb', False);
  ReCheck('^x{0,3}y$', 'y', True);
  ReCheck('^x{0,3}y$', 'xxxy', True);
  ReCheck('^x{0,3}y$', 'xxxxy', False);

  { Bad patterns are reported, not raised and not silently reinterpreted. }
  ReBad('[a-', 'an unterminated class');
  ReBad('(a', 'an unterminated group');
  ReBad('a)', 'a stray close paren');
  ReBad('a{3,1}', 'a reversed repeat range');
  ReBad('a{999}', 'a repeat count over the cap');
  ReBad('\q', 'an unknown escape');
  ReBad('a\', 'a trailing backslash');
  ReBad('a|', 'an empty branch');
  ReBad('(\w{100}){100}', 'a pattern that would compile too large');
  Long := '';
  for I := 1 to 5000 do Long := Long + 'a';
  ReBad(Long, 'a 5000-byte pattern');

  { The budget is the one guard that keeps a hostile pattern from running
    unbounded inside a tool call nothing can interrupt.  Exhausting it must
    report rrBudget - "unknown" - and never rrNoMatch. }
  if TRegex.Compile('z+q', False, R, E) then
  try
    R.Budget := 40;
    Check(R.Match(StringOfChar('z', 200)) = rrBudget,
      'a spent budget reports exhaustion rather than a clean miss');
    R.Budget := DefaultRegexBudget;
    Check(R.Match(StringOfChar('z', 200)) = rrNoMatch,
      'and the same call with the real budget gives a definite answer');
    Check(R.ProgramSize > 0, 'the compiled program has instructions');
  finally
    R.Free;
  end
  else
    Check(False, 'the budget pattern compiles: ' + E);
end;

procedure TestTools;
var
  Dir, Out_, Nb, Before: string;
  IsErr: Boolean;
  I: Integer;
  J, Sch, Tool, Req: TJson;
  L: TStringList;
begin
  Dir := IncludeTrailingPathDelimiter(GetTempDir) + 'pasclaude-test';
  ForceDirectories(Dir);
  uTools.RootDir := Dir;
  uTools.AllowAllEdits := True;      { the prompt is not available in a test }

  J := TJson.NewObj;
  J.AddStr('path', 'a\b.txt');
  J.AddStr('content', 'one'#10'two'#10'three'#10);
  Out_ := Run('write_file', J, IsErr);
  Check(not IsErr, 'write_file creates nested directories: ' + Out_);

  J := TJson.NewObj;
  J.AddStr('path', 'a\b.txt');
  Out_ := Run('read_file', J, IsErr);
  Check((not IsErr) and (Pos('    1  one', Out_) > 0), 'read_file numbers lines');

  J := TJson.NewObj;
  J.AddStr('path', 'a\b.txt');
  J.AddStr('old_text', 'two');
  J.AddStr('new_text', 'TWO');
  Out_ := Run('edit_file', J, IsErr);
  Check(not IsErr, 'edit_file replaces a unique snippet');

  { "one" appears in "one" only once, so use a string that repeats. }
  J := TJson.NewObj;
  J.AddStr('path', 'a\b.txt');
  J.AddStr('content', 'dup'#10'dup'#10);
  Run('write_file', J, IsErr);
  J := TJson.NewObj;
  J.AddStr('path', 'a\b.txt');
  J.AddStr('old_text', 'dup');
  J.AddStr('new_text', 'x');
  Out_ := Run('edit_file', J, IsErr);
  Check(IsErr and (Pos('more than once', Out_) > 0),
    'edit_file refuses an ambiguous match');

  J := TJson.NewObj;
  J.AddStr('path', '..\..\Windows\win.ini');
  Out_ := Run('read_file', J, IsErr);
  Check(IsErr and (Pos('escapes', Out_) > 0), 'path guard blocks ..\ escapes');

  J := TJson.NewObj;
  J.AddStr('path', 'C:\Windows\win.ini');
  Out_ := Run('read_file', J, IsErr);
  Check(IsErr, 'path guard blocks an absolute path');

  J := TJson.NewObj;
  J.AddStr('path', '.');
  J.AddBool('recursive', True);
  Out_ := Run('list_dir', J, IsErr);
  Check((not IsErr) and (Pos('b.txt', Out_) > 0), 'list_dir finds nested files');

  J := TJson.NewObj;
  J.AddStr('pattern', 'dup');
  Out_ := Run('search', J, IsErr);
  Check(Pos('b.txt', Out_) > 0, 'search finds a match with its line number');

  J := TJson.NewObj;
  J.AddStr('pattern', 'nothing-matches-this-xyzzy');
  Out_ := Run('search', J, IsErr);
  Check(Pos('no matches', Out_) > 0, 'search reports an empty result');

  { Regex is opt-in.  Without the flag a metacharacter is just a character -
    which is the whole backward-compatibility argument, since "D.P" is the
    shape of half the identifiers a code search goes looking for. }
  J := TJson.NewObj;
  J.AddStr('pattern', 'd.p');
  Out_ := Run('search', J, IsErr);
  Check(Pos('b.txt', Out_) = 0, 'a metacharacter stays literal without regex');

  J := TJson.NewObj;
  J.AddStr('pattern', 'd.p');
  J.AddBool('regex', True);
  Out_ := Run('search', J, IsErr);
  Check((not IsErr) and (Pos('b.txt', Out_) > 0),
    'and is a pattern with it: ' + Out_);

  J := TJson.NewObj;
  J.AddStr('pattern', '^zzz\d+$');
  J.AddBool('regex', True);
  Out_ := Run('search', J, IsErr);
  Check((not IsErr) and (Pos('no matches', Out_) > 0),
    'a regex that matches nothing says so');

  { A bad pattern is a clean tool error, not a crash and not a search for the
    literal text. }
  J := TJson.NewObj;
  J.AddStr('pattern', '[a-');
  J.AddBool('regex', True);
  Out_ := Run('search', J, IsErr);
  Check(IsErr and (Pos('invalid regex', Out_) > 0),
    'an invalid pattern is a tool error: ' + Out_);

  J := TJson.NewObj;
  J.AddStr('pattern', 'DUP');
  J.AddBool('case_sensitive', True);
  Out_ := Run('search', J, IsErr);
  Check(Pos('b.txt', Out_) = 0, 'case_sensitive excludes a different case');

  J := TJson.NewObj;
  J.AddStr('pattern', 'DUP');
  Out_ := Run('search', J, IsErr);
  Check(Pos('b.txt', Out_) > 0, 'and the default still folds case');

  uTools.AllowAllBash := True;
  J := TJson.NewObj;
  J.AddStr('command', 'echo hello-from-shell');
  Out_ := Run('bash', J, IsErr);
  Check((not IsErr) and (Pos('hello-from-shell', Out_) > 0), 'bash captures output');

  J := TJson.NewObj;
  J.AddStr('command', 'exit /b 3');
  Out_ := Run('bash', J, IsErr);
  Check(IsErr and (Pos('exit code 3', Out_) > 0), 'bash reports a failing exit code');

  { Denial must be the default when no prompt is available. }
  uTools.AllowAllEdits := False;
  J := TJson.NewObj;
  J.AddStr('path', 'denied.txt');
  J.AddStr('content', 'x');
  Out_ := Run('write_file', J, IsErr);
  Check(IsErr and (Pos('denied', Out_) > 0), 'writes are denied without approval');

  { Same story for a notebook: the gate is the one edit_file uses, so a nil
    Ask must refuse and the file must be exactly as it was.  An arm that
    writes first and asks afterwards passes every other assertion here. }
  Nb := IncludeTrailingPathDelimiter(Dir) + 'n.ipynb';
  Before := '{"cells":[{"cell_type":"code","execution_count":null,' +
            '"metadata":{},"outputs":[],"source":["x=1\n"]}],' +
            '"metadata":{},"nbformat":4,"nbformat_minor":4}';
  L := TStringList.Create;
  try
    L.Text := Before;
    L.SaveToFile(Nb);
  finally
    L.Free;
  end;
  Before := '';
  L := TStringList.Create;
  try
    L.LoadFromFile(Nb);
    Before := L.Text;
  finally
    L.Free;
  end;

  J := TJson.NewObj;
  J.AddStr('path', 'n.ipynb');
  J.AddNum('cell', 0);
  J.AddStr('edit_mode', 'replace');
  J.AddStr('source', 'x=2');
  Out_ := Run('notebook_edit', J, IsErr);
  Check(IsErr and (Pos('denied', Out_) > 0),
    'notebook edits are denied without approval: ' + Out_);
  L := TStringList.Create;
  try
    L.LoadFromFile(Nb);
    Check(L.Text = Before, 'and the notebook is untouched after a denial');
  finally
    L.Free;
  end;
  uTools.AllowAllEdits := True;

  J := TJson.NewObj;
  J.AddStr('path', 'x');
  Out_ := Run('no_such_tool', J, IsErr);
  Check(IsErr, 'an unknown tool is an error');

  { The caller owns the schema, so it is freed here rather than leaked. }
  Sch := ToolsSchema;
  try
    Check(CountBuiltinTools(Sch) = BuiltinToolCount,
      'the schema exposes every built-in tool');
    { A tool that exists in RunTool but not in the schema is one the model
      never learns about, and no other test would notice. }
    Tool := nil;
    for I := 0 to Sch.Count - 1 do
      if Sch.Item(I).Str('name') = 'notebook_edit' then Tool := Sch.Item(I);
    Check(Tool <> nil, 'notebook_edit is declared to the model');
    if Tool <> nil then
    begin
      Req := Tool.Find('input_schema').Find('required');
      Check((Req.Count = 3) and (Req.Item(0).AsString = 'path') and
            (Req.Item(1).AsString = 'cell') and
            (Req.Item(2).AsString = 'edit_mode'),
        'notebook_edit requires path, cell and edit_mode');
      Check(Tool.Find('input_schema').Find('properties').Find('cell')
              .Str('type') = 'integer',
        'and declares cell as an integer, not a string');
    end;
  finally
    Sch.Free;
  end;

  { Web search is declared, never executed: the API runs it on its own
    servers.  A RunTool branch for it would mean this client tried to do the
    search itself, which the unknown-tool answer below rules out. }
  Tool := WebSearchToolDef;
  try
    Check(Tool.Kind = jkObj, 'the web search declaration is an object');
    Check(Tool.Str('type') = WebSearchToolType,
      'it carries the dated type string: ' + Tool.Str('type'));
    Check(Tool.Str('name') = 'web_search', 'and the tool name');
    Check(Tool.Num('max_uses') > 0, 'and a cap on searches per turn');
    Check(Tool.Find('input_schema') = nil,
      'a server-side tool declares no input schema');
  finally
    Tool.Free;
  end;

  Sch := ToolsSchema;
  try
    Check(CountBuiltinTools(Sch) = BuiltinToolCount,
      'the local schema is unchanged by web search');
  finally
    Sch.Free;
  end;

  J := TJson.NewObj;
  Out_ := Run('web_search', J, IsErr);
  Check(IsErr and (Out_ = 'unknown tool: web_search'),
    'web_search is never executed locally: ' + Out_);
end;

{ The fetch tool, against a stand-in transport: no network in this suite. }
var
  FakeGetUrl: string;
  FakeGetResult: THttpResult;

function FakeGet(const Url, Headers: string; MaxBytes: Integer): THttpResult;
begin
  FakeGetUrl := Url;
  Result := FakeGetResult;
end;

procedure TestFetch;
var
  J: TJson;
  Out_: string;
  IsErr: Boolean;
begin
  uHttp.HttpGetTransport := @FakeGet;
  try
    { Denied by default: fetch reaches the outside world, so it asks. }
    uTools.AllowAllFetch := False;
    J := TJson.NewObj;
    J.AddStr('url', 'https://example.com/doc');
    Out_ := Run('fetch', J, IsErr);
    Check(IsErr and (Pos('denied', Out_) > 0),
      'fetch is denied without approval');

    uTools.AllowAllFetch := True;

    { Not https, refused before any prompt or request. }
    J := TJson.NewObj;
    J.AddStr('url', 'http://example.com/doc');
    Out_ := Run('fetch', J, IsErr);
    Check(IsErr and (Pos('https', Out_) > 0), 'fetch refuses plain http');

    { The happy path returns the body. }
    FakeGetResult.Ok := True;
    FakeGetResult.Status := 200;
    FakeGetResult.Body := 'hello from the web';
    FakeGetResult.Error := '';
    FakeGetResult.RetryAfterMs := 0;
    J := TJson.NewObj;
    J.AddStr('url', 'https://example.com/doc');
    Out_ := Run('fetch', J, IsErr);
    Check((not IsErr) and (Out_ = 'hello from the web'),
      'fetch returns the body: ' + Out_);
    Check(FakeGetUrl = 'https://example.com/doc',
      'the requested URL reached the transport');

    { A failure carries the error and any body the server sent. }
    FakeGetResult.Ok := False;
    FakeGetResult.Status := 404;
    FakeGetResult.Body := 'not here';
    FakeGetResult.Error := 'HTTP 404';
    J := TJson.NewObj;
    J.AddStr('url', 'https://example.com/missing');
    Out_ := Run('fetch', J, IsErr);
    Check(IsErr and (Pos('HTTP 404', Out_) > 0) and (Pos('not here', Out_) > 0),
      'a failed fetch reports status and body');

    { A body that is not valid UTF-8 is scrubbed, never sent raw: one bad
      byte in a tool result poisons the whole request. }
    FakeGetResult.Ok := True;
    FakeGetResult.Status := 200;
    FakeGetResult.Body := 'caf' + #$E9 + ' latin-1';
    FakeGetResult.Error := '';
    J := TJson.NewObj;
    J.AddStr('url', 'https://example.com/latin1');
    Out_ := Run('fetch', J, IsErr);
    Check((not IsErr) and IsValidUtf8(Out_),
      'a non-UTF-8 body is converted to valid UTF-8');
  finally
    uHttp.HttpGetTransport := nil;
    uTools.AllowAllFetch := False;
  end;
end;

{ The bash prefix rules.  "Always" for a command approves its program; a
  chained command has no prefix and is asked about every time. }
procedure TestBashPrefixes;
var
  J: TJson;
  Out_: string;
  IsErr: Boolean;
begin
  ClearBashPrefixes;
  uTools.AllowAllBash := False;

  Check(BashPrefix('git status') = 'git', 'the prefix is the program name');
  Check(BashPrefix('  git   log --oneline') = 'git', 'leading space is trimmed');
  Check(BashPrefix('GIT LOG') = 'git', 'the prefix is case-folded');
  Check(BashPrefix('C:\Tools\git.exe log') = 'git',
    'a full path reduces to the program');
  Check(BashPrefix('"C:\Program Files\Git\git.exe"') = 'git',
    'quotes are stripped');
  Check(BashPrefix('git status && del /q *') = '',
    'a chained command has no prefix');
  Check(BashPrefix('type x | find "y"') = '', 'a pipe poisons the prefix');
  Check(BashPrefix('echo %PATH%') = '', 'an env expansion poisons the prefix');
  Check(BashPrefix('build > out.txt') = '', 'a redirect poisons the prefix');
  Check(BashPrefix('') = '', 'an empty command has no prefix');

  Check(not BashPrefixAllowed('git status'), 'nothing is approved to start');
  AllowBashPrefix('git status');
  Check(BashPrefixAllowed('git log'), 'approving git status approves git log');
  Check(BashPrefixAllowed('GIT PUSH'), 'case does not matter');
  Check(not BashPrefixAllowed('del /q x'), 'del was never approved');
  Check(not BashPrefixAllowed('git status && del /q *'),
    'a chained command never rides an approved prefix');

  { Through the real tool: an approved prefix runs without a prompt (Ask is
    nil here, so any prompt would deny). }
  AllowBashPrefix('echo hi');
  J := TJson.NewObj;
  J.AddStr('command', 'echo prefix-approved');
  Out_ := Run('bash', J, IsErr);
  Check((not IsErr) and (Pos('prefix-approved', Out_) > 0),
    'an approved prefix runs without asking');

  J := TJson.NewObj;
  J.AddStr('command', 'dir');
  Out_ := Run('bash', J, IsErr);
  Check(IsErr and (Pos('denied', Out_) > 0),
    'an unapproved program still asks (and a nil ask denies)');

  J := TJson.NewObj;
  J.AddStr('command', 'echo x && echo y');
  Out_ := Run('bash', J, IsErr);
  Check(IsErr and (Pos('denied', Out_) > 0),
    'a chained command is asked about even when its first program is approved');

  ClearBashPrefixes;
  Check(not BashPrefixAllowed('git log'), 'clearing forgets the approvals');
end;

{ Background bash.  The id-sensitive assertions go through the public job
  API, because a job id is the one thing a tool result cannot be relied on to
  spell for you; the gate assertions go through RunTool, because the gate is
  the thing that must not be bypassable from there. }
procedure TestBackgroundJobs;
var
  J: TJson;
  Out_, Id, Err, Spool: string;
  IsErr, Found: Boolean;
begin
  uTools.ClearJobs;
  uTools.AllowAllBash := True;

  { Through the tool, which is the only path the model has. }
  J := TJson.NewObj;
  J.AddStr('command', 'echo hello');
  J.AddBool('run_in_background', True);
  Out_ := Run('bash', J, IsErr);
  Check(not IsErr, 'a background bash call succeeds');
  Check(Pos('bg1', Out_) > 0, 'and returns the job id it started');
  Check(uTools.BackgroundJobCount = 1, 'and the job is held');
  Check(Pos('[exit code', Out_) = 0,
    'and it returned immediately rather than running in the foreground');
  uTools.ClearJobs;

  { Directly, so the exit code and the offset can be asserted on. }
  Check(StartBackgroundJob('echo hello', Id, Err), 'a job starts: ' + Err);
  Check(Id = 'bg1', 'ids are predictable after a clear');
  Check(WaitBackgroundJob(Id, 5000), 'and a quick job finishes');
  Out_ := PollBackgroundJob(Id, Found);
  Check(Found, 'polling finds it');
  Check(Pos('hello', Out_) > 0, 'and hands over what it printed');
  Check(Pos('exited 0', Out_) > 0, 'and reports the exit code once it is done');

  { The offset is the whole contract: output is handed over once. }
  Out_ := PollBackgroundJob(Id, Found);
  Check(Pos('hello', Out_) = 0, 'a second poll does not repeat the output');
  Check(Pos('(no new output)', Out_) > 0, 'and says so plainly');

  { An id that names nothing must say so, not answer with silence: a model
    reading silence as "it produced nothing" waits for a job that is not
    there. }
  PollBackgroundJob('bg999', Found);
  Check(not Found, 'an unknown id is not found');
  J := TJson.NewObj;
  J.AddStr('job_id', 'bg999');
  Out_ := Run('bash_output', J, IsErr);
  Check(IsErr and (Pos('no such job', Out_) > 0),
    'and the tool reports it as an error');

  { A genuinely long job, so the kill has something to kill. }
  uTools.ClearJobs;
  Check(StartBackgroundJob('ping -n 30 127.0.0.1', Id, Err),
    'a long job starts: ' + Err);
  Check(not WaitBackgroundJob(Id, 300), 'and is still running a moment later');
  Check(KillBackgroundJob(Id), 'killing it reports success');
  Check(WaitBackgroundJob(Id, 5000), 'and it really stops');

  { The gate, from the model's side.  This is the assertion that catches a
    fork placed above PermitBash, which would make backgrounding a way to
    run unapproved shell commands. }
  uTools.ClearJobs;
  uTools.AllowAllBash := False;
  ClearBashPrefixes;
  J := TJson.NewObj;
  J.AddStr('command', 'ping -n 1 127.0.0.1');
  J.AddBool('run_in_background', True);
  Out_ := Run('bash', J, IsErr);
  Check(IsErr and (Pos('denied', Out_) > 0),
    'a background command faces the bash gate');
  Check(uTools.BackgroundJobCount = 0, 'and a denied command starts nothing');

  { The same per-program approval covers both: backgrounding is a question
    about who waits, not about what runs. }
  AllowBashPrefix('ping -n 1 127.0.0.1');
  J := TJson.NewObj;
  J.AddStr('command', 'ping -n 1 127.0.0.1');
  J.AddBool('run_in_background', True);
  Out_ := Run('bash', J, IsErr);
  Check(not IsErr, 'a foreground prefix grant covers the background run');
  Check(uTools.BackgroundJobCount = 1, 'and the job is really started');

  { ClearJobs has to stop the child and take the spool with it, not just
    forget the array. }
  Spool := '';
  if StartBackgroundJob('ping -n 30 127.0.0.1', Id, Err) then
    Spool := IncludeTrailingPathDelimiter(uTools.RootDir) + '.pasclaude' +
      PathDelim + 'jobs' + PathDelim + Id + '.out';
  Check((Spool <> '') and FileExists(Spool), 'a job has a spool file on disk');
  uTools.ClearJobs;
  Check(uTools.BackgroundJobCount = 0, 'clearing forgets every job');
  Check(not FileExists(Spool), 'and deletes its spool');

  ClearBashPrefixes;
  uTools.AllowAllBash := False;
  uTools.ClearJobs;
end;

{ The changed-files log behind /diff. }
procedure TestChangedFiles;
var
  J: TJson;
  IsErr: Boolean;
  C: TStringArray;
begin
  ClearChangedFiles;
  uTools.AllowAllEdits := True;

  Check(Length(uTools.ChangedFiles) = 0, 'the list starts empty');

  J := TJson.NewObj;
  J.AddStr('path', 'diffed.txt');
  J.AddStr('content', 'one');
  Run('write_file', J, IsErr);

  J := TJson.NewObj;
  J.AddStr('path', 'diffed.txt');
  J.AddStr('old_text', 'one');
  J.AddStr('new_text', 'two');
  Run('edit_file', J, IsErr);

  C := uTools.ChangedFiles;
  Check(Length(C) = 1, 'a write and an edit of one file count once');
  Check((Length(C) = 1) and (C[0] = 'diffed.txt'), 'by its relative path');

  { A read is not a change. }
  J := TJson.NewObj;
  J.AddStr('path', 'diffed.txt');
  Run('read_file', J, IsErr);
  Check(Length(uTools.ChangedFiles) = 1, 'reading adds nothing');

  { A denied write is not a change either. }
  uTools.AllowAllEdits := False;
  J := TJson.NewObj;
  J.AddStr('path', 'never.txt');
  J.AddStr('content', 'x');
  Run('write_file', J, IsErr);
  Check(Length(uTools.ChangedFiles) = 1, 'a denied write is not recorded');
  uTools.AllowAllEdits := True;

  ClearChangedFiles;
  Check(Length(uTools.ChangedFiles) = 0, 'clearing empties the list');
end;

{ The model list, against the same stand-in transport as fetch.  The parse
  and the auth-header choice are the testable parts; the live endpoint was
  verified by hand. }
var
  FakeGetHeaders: string;

function FakeGetM(const Url, Headers: string; MaxBytes: Integer): THttpResult;
begin
  FakeGetUrl := Url;
  FakeGetHeaders := Headers;
  Result := FakeGetResult;
end;

procedure TestListModels;
var
  A: TAgent;
  Models: TModelList;
  Err: string;
begin
  uHttp.HttpGetTransport := @FakeGetM;
  try
    FakeGetResult.Ok := True;
    FakeGetResult.Status := 200;
    FakeGetResult.Error := '';
    FakeGetResult.RetryAfterMs := 0;
    FakeGetResult.Body :=
      '{"data":[{"id":"claude-a","display_name":"Claude A"},' +
      '{"id":"claude-b"},{"display_name":"no id, skipped"}]}';

    A := TAgent.Create('sk-ant-api-key', 'm', 'sys');
    try
      Models := A.ListModels(Err);
      Check(Length(Models) = 2, 'entries without an id are skipped');
      Check((Length(Models) = 2) and (Models[0].Id = 'claude-a') and
        (Models[0].DisplayName = 'Claude A'), 'id and display name are read');
      Check((Length(Models) = 2) and (Models[1].DisplayName = 'claude-b'),
        'a missing display name falls back to the id');
      Check(Pos('/v1/models', FakeGetUrl) > 0, 'the models endpoint is asked');
      Check(Pos('x-api-key: sk-ant-api-key', FakeGetHeaders) > 0,
        'an API key authenticates the list request');
    finally
      A.Free;
    end;

    A := TAgent.Create('sk-ant-oat01-tok', 'm', 'sys');
    try
      Models := A.ListModels(Err);
      Check(Pos('authorization: Bearer sk-ant-oat01-tok', FakeGetHeaders) > 0,
        'an OAuth token authenticates as a Bearer');
    finally
      A.Free;
    end;

    FakeGetResult.Ok := False;
    FakeGetResult.Status := 401;
    FakeGetResult.Error := 'HTTP 401';
    FakeGetResult.Body := '{"error":{"message":"bad key"}}';
    A := TAgent.Create('k', 'm', 'sys');
    try
      Models := A.ListModels(Err);
      Check((Length(Models) = 0) and (Pos('HTTP 401', Err) > 0),
        'a failed list reports the status');
    finally
      A.Free;
    end;

    FakeGetResult.Ok := True;
    FakeGetResult.Status := 200;
    FakeGetResult.Error := '';
    FakeGetResult.Body := 'not json';
    A := TAgent.Create('k', 'm', 'sys');
    try
      Models := A.ListModels(Err);
      Check((Length(Models) = 0) and (Err <> ''),
        'a garbled answer is an error, not a crash');
    finally
      A.Free;
    end;
  finally
    uHttp.HttpGetTransport := nil;
  end;
end;

{ The todo tool: display state, no gate, whole-list replacement. }
procedure TestTodos;
var
  J, Arr, T: TJson;
  Out_: string;
  IsErr: Boolean;
  Todos: TStringArray;
begin
  ClearTodos;
  Check(Length(CurrentTodos) = 0, 'the todo list starts empty');

  J := TJson.NewObj;
  Arr := TJson.NewArr;
  T := TJson.NewObj;
  T.AddStr('content', 'first step');
  T.AddStr('status', 'completed');
  Arr.Push(T);
  T := TJson.NewObj;
  T.AddStr('content', 'second step');
  T.AddStr('status', 'in_progress');
  Arr.Push(T);
  T := TJson.NewObj;
  T.AddStr('content', 'third step');
  T.AddStr('status', 'pending');
  Arr.Push(T);
  J.Add('todos', Arr);
  { Ask is nil here, which proves no permission gate blocks the tool. }
  Out_ := Run('todo_write', J, IsErr);
  Check(not IsErr, 'todo_write needs no approval: ' + Out_);

  Todos := CurrentTodos;
  Check(Length(Todos) = 3, 'three items are held');
  Check((Length(Todos) = 3) and (Todos[0] = '[x] first step'),
    'completed renders as [x]');
  Check((Length(Todos) = 3) and (Todos[1] = '[~] second step'),
    'in_progress renders as [~]');
  Check((Length(Todos) = 3) and (Todos[2] = '[ ] third step'),
    'pending renders as [ ]');

  { The next call replaces, not appends. }
  J := TJson.NewObj;
  Arr := TJson.NewArr;
  T := TJson.NewObj;
  T.AddStr('content', 'only step');
  T.AddStr('status', 'pending');
  Arr.Push(T);
  J.Add('todos', Arr);
  Run('todo_write', J, IsErr);
  Check(Length(CurrentTodos) = 1, 'a new list replaces the old one');

  J := TJson.NewObj;
  J.AddStr('todos', 'not an array');
  Out_ := Run('todo_write', J, IsErr);
  Check(IsErr, 'a non-array is refused');
  Check(Length(CurrentTodos) = 1, 'and the list is untouched');

  ClearTodos;
end;

{ Standing approvals surviving a "restart" (a save, a wipe, a load). }
{ The read-only claim, pinned twice over.  Once in the schema, which is what
  the model is told, and once in RunTool, which is what is actually true - and
  the second is the one that matters, because the model can name a tool it was
  never offered and the permission gate is no backstop when a standing "always"
  short-circuits it. }
procedure TestSubagentGate;
var
  Dir, Out_, Body: string;
  IsErr: Boolean;
  J, Sch: TJson;
  Saved: TSubagentProc;
begin
  Dir := IncludeTrailingPathDelimiter(GetTempDir) + 'pasclaude-test';
  ForceDirectories(Dir);
  uTools.RootDir := Dir;

  Check(SubagentDepth = 0, 'no subagent is running to start with');

  Sch := ToolsSchema;
  try
    Check(CountBuiltinTools(Sch) = BuiltinToolCount,
      'the full schema is every built-in tool');
  finally
    Sch.Free;
  end;

  Check(EnterSubagent, 'the one subagent slot can be claimed');
  try
    Check(SubagentDepth = 1, 'and the depth says so');
    Check(not EnterSubagent, 'a second subagent is refused');

    Sch := ToolsSchema;
    try
      Body := Sch.ToJson;
      Check(Sch.Count = 3, Format('a subagent is offered three tools (%d)',
        [Sch.Count]));
      Check(Pos('"read_file"', Body) > 0, 'read_file among them');
      Check(Pos('"list_dir"', Body) > 0, 'list_dir among them');
      Check(Pos('"search"', Body) > 0, 'search among them');
      Check(Pos('"write_file"', Body) = 0, 'write_file is not offered');
      Check(Pos('"bash"', Body) = 0, 'bash is not offered');
      Check(Pos('"task"', Body) = 0, 'and task is not offered, so it cannot nest');
    finally
      Sch.Free;
    end;

    { The hole a schema alone would leave: AllowAllEdits is on, Ask is nil,
      and Permit would wave this straight through. }
    uTools.AllowAllEdits := True;
    DeleteFile(IncludeTrailingPathDelimiter(Dir) + 'sub-escape.txt');
    J := TJson.NewObj;
    J.AddStr('path', 'sub-escape.txt');
    J.AddStr('content', 'the subagent should never have written this');
    Out_ := Run('write_file', J, IsErr);
    Check(IsErr and (Pos('not available to a subagent', Out_) > 0),
      'a subagent naming write_file is refused: ' + Out_);
    Check(not FileExists(IncludeTrailingPathDelimiter(Dir) + 'sub-escape.txt'),
      'and nothing reached the disk');

    J := TJson.NewObj;
    J.AddStr('prompt', 'go deeper');
    Out_ := Run('task', J, IsErr);
    Check(IsErr and (Pos('not available to a subagent', Out_) > 0),
      'and task itself is refused inside a subagent: ' + Out_);

    { read_file still works, or the toolset would be empty in practice. }
    J := TJson.NewObj;
    J.AddStr('path', 'a\b.txt');
    Out_ := Run('read_file', J, IsErr);
    Check(not IsErr, 'while read_file still answers: ' + Out_);
  finally
    LeaveSubagent;
  end;
  Check(SubagentDepth = 0, 'the depth is back to zero after the call');

  J := TJson.NewObj;
  J.AddStr('prompt', '   ');
  Out_ := Run('task', J, IsErr);
  Check(IsErr and (Pos('prompt is required', Out_) > 0),
    'a blank prompt is refused: ' + Out_);

  { A build with no runner installed must report that, not dereference nil. }
  Saved := uTools.SubagentRunner;
  uTools.SubagentRunner := nil;
  try
    J := TJson.NewObj;
    J.AddStr('prompt', 'find the main unit');
    Out_ := Run('task', J, IsErr);
    Check(IsErr and (Pos('subagents are not available', Out_) > 0),
      'with no runner the tool reports it rather than crashing: ' + Out_);
    Sch := ToolsSchema;
    try
      Check(Pos('"task"', Sch.ToJson) = 0,
        'and task is not advertised at all');
    finally
      Sch.Free;
    end;
  finally
    uTools.SubagentRunner := Saved;
  end;

  Check(SubagentDepth = 0, 'and the depth survived every failure path');
  uTools.AllowAllEdits := False;
end;

{ --------------------------------------------------------------- MCP ---
  The stand-in wire, in the spirit of loop.lpr's FakePost: the protocol runs
  against a script instead of a process, so framing, pagination, the deadline
  and every hostile byte sequence are testable with no child at all.  One
  reply is consumed per request that carries an id - a notification consumes
  none - and %ID% is substituted so a response answers the question that was
  actually asked rather than a number the script guessed.

  WireChunk is nine bytes for the same reason FakePost's is: every frame
  therefore arrives split across several reads, so the reassembly path is the
  only path the tests ever exercise. }
var
  Replies: array of string;
  ReplyN: Integer = 0;
  WireIn: string = '';
  WireOut: string = '';
  WireChunk: Integer = 9;
  WireAlive: Boolean = True;
  WireBroken: Boolean = False;
  WireSeq: Integer = 0;
  WireClosed: Integer = 0;

procedure ScriptReset;
begin
  SetLength(Replies, 0);
  ReplyN := 0;
  WireIn := '';
  WireOut := '';
  WireChunk := 9;
  WireAlive := True;
  WireBroken := False;
  WireClosed := 0;
end;

procedure Script(const S: string);
begin
  SetLength(Replies, Length(Replies) + 1);
  Replies[High(Replies)] := S;
end;

function WireOpen(const Cmd, WorkDir, ErrLog: string; out Wire: Integer;
  out Err: string): Boolean;
begin
  Err := '';
  Inc(WireSeq);
  Wire := WireSeq;
  Result := True;
end;

function WireSend(Wire: Integer; const Data: string): Boolean;
var
  Doc: TJson;
  R: string;
  Id: Integer;
begin
  WireIn := WireIn + Data;
  Result := True;
  Doc := JsonParse(Trim(Data));
  if Doc = nil then Exit;
  Id := -1;
  try
    if Doc.Find('id') <> nil then Id := Round(Doc.Num('id'));
  finally
    Doc.Free;
  end;
  if Id < 0 then Exit;
  if ReplyN > High(Replies) then Exit;      { script exhausted: silence }
  R := StringReplace(Replies[ReplyN], '%ID%', IntToStr(Id), [rfReplaceAll]);
  Inc(ReplyN);
  if R <> '' then WireOut := WireOut + R + #10;
end;

function WirePoll(Wire: Integer; out Data: string; out Alive: Boolean): Boolean;
begin
  Data := '';
  Alive := WireAlive;
  if WireBroken then Exit(False);
  if WireOut <> '' then
  begin
    Data := Copy(WireOut, 1, WireChunk);
    Delete(WireOut, 1, Length(Data));
  end;
  Result := True;
end;

procedure WireClose(Wire: Integer; out ExitCode: Integer);
begin
  ExitCode := 7;
  Inc(WireClosed);
end;

procedure InstallWire;
begin
  McpWire.Open := @WireOpen;
  McpWire.Send := @WireSend;
  McpWire.Poll := @WirePoll;
  McpWire.Close := @WireClose;
end;

procedure RemoveWire;
begin
  McpWire.Open := nil;
  McpWire.Send := nil;
  McpWire.Poll := nil;
  McpWire.Close := nil;
end;

function CountLf(const S: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to Length(S) do if S[I] = #10 then Inc(Result);
end;

const
  InitOk = '{"jsonrpc":"2.0","id":%ID%,"result":{"protocolVersion":' +
    '"2025-06-18","capabilities":{},"serverInfo":{"name":"srv",' +
    '"version":"1.0"}}}';
  ListTwo = '{"jsonrpc":"2.0","id":%ID%,"result":{"tools":[' +
    '{"name":"echo","description":"d","inputSchema":{"type":"object"}},' +
    '{"name":"ping","description":"d","inputSchema":{"type":"object"}}]}}';

{ Opens a scripted connection that has already shaken hands.  Returns -1 when
  the handshake itself failed, which every caller treats as fatal. }
function Shook(out C: Integer): Boolean;
var
  Err, N, V, P: string;
begin
  C := McpSpawn('mock', 'mock-command', '', '', [], Err);
  Result := (C >= 0) and McpHandshake(C, N, V, P, Err);
end;

{ ---------------------------------------------------- the tool registry -- }

{ A stand-in source: two declarations and a handler that reports what it was
  called with.  Everything about the registry that matters is visible from
  outside - where the declarations land in the array, which names reach the
  handler, and what happens when a handler misbehaves. }
function OneStub(const Name: string): TJson;
var
  S: TJson;
begin
  S := TJson.NewObj;
  S.AddStr('type', 'object');
  Result := TJson.NewObj;
  Result.AddStr('name', Name);
  Result.AddStr('description', 'a stand-in');
  Result.Add('input_schema', S);
end;

function StubDeclare: TJson;
begin
  Result := TJson.NewArr;
  Result.Push(OneStub('stub__one'));
  Result.Push(OneStub('stub__two'));
end;

function StubRun(const Name: string; Input: TJson; Ask: TAskProc;
  out IsError: Boolean): string;
begin
  IsError := False;
  if Name = 'stub__boom' then
    raise Exception.Create('the handler exploded');
  Result := 'stub ran ' + Name;
end;

function EmptyDeclare: TJson;
begin
  Result := TJson.NewArr;
end;

procedure TestToolRegistry;
var
  Sch: TJson;
  Err, Out_: string;
  IsErr, Ok: Boolean;
  I, StubAt: Integer;
begin
  ClearToolSources;
  Check(ToolSourceCount = 0, 'the registry starts empty once cleared');

  Check(not RegisterToolSource('', @StubDeclare, @StubRun, Err),
    'an empty prefix is refused');
  Ok := RegisterToolSource('read_', @StubDeclare, @StubRun, Err);
  Check((not Ok) and (Err <> ''),
    'a prefix that could shadow read_file is refused: ' + Err);
  Check(not RegisterToolSource('Stub__', @StubDeclare, @StubRun, Err),
    'an upper-case prefix is refused');
  Check(not RegisterToolSource('stub__', nil, @StubRun, Err),
    'a source with no declare procedure is refused');

  Ok := RegisterToolSource('stub__', @StubDeclare, @StubRun, Err);
  Check(Ok and (Err = ''), 'a well-formed prefix registers');
  Check(ToolSourceCount = 1, 'and the count says so');
  Check(ToolSourcePrefix(0) = 'stub__', 'and the prefix round-trips');
  Check(not RegisterToolSource('stub__', @StubDeclare, @StubRun, Err),
    'the same prefix twice is refused');
  Check(not RegisterToolSource('stub__x__', @StubDeclare, @StubRun, Err),
    'and so is one that overlaps it, so dispatch cannot depend on order');

  Sch := ToolsSchema;
  try
    Check(CountBuiltinTools(Sch) = BuiltinToolCount,
      'the built-in count is untouched by a source');
    Check(Sch.Count = BuiltinToolCount + 2,
      Format('and the source added two declarations (%d)', [Sch.Count]));
    StubAt := -1;
    for I := 0 to Sch.Count - 1 do
      if (Sch.Item(I).Str('name') = 'stub__one') and (StubAt < 0) then
        StubAt := I;
    { Order matters: the source loop sits below the read-only cut, so a source
      declaration can only ever appear after every built-in. }
    Check(StubAt = BuiltinToolCount,
      Format('source declarations come after the built-ins (at %d)', [StubAt]));
    Check(Sch.Item(Sch.Count - 1).Str('name') = 'stub__two',
      'in the order the source produced them');
  finally
    Sch.Free;
  end;

  Out_ := Run('stub__one', TJson.NewObj, IsErr);
  Check((not IsErr) and (Out_ = 'stub ran stub__one'),
    'a prefixed name reaches the source: ' + Out_);
  Out_ := Run('stub__never_declared', TJson.NewObj, IsErr);
  Check(Out_ = 'stub ran stub__never_declared',
    'dispatch is by prefix, not by what was declared');

  { The one line that matters most: uAgent does not catch, so an exception
    escaping a handler would skip the tool_result entirely. }
  Out_ := Run('stub__boom', TJson.NewObj, IsErr);
  Check(IsErr and (Pos('the handler exploded', Out_) > 0),
    'a handler that raises becomes an error result, not an escape: ' + Out_);

  Out_ := Run('other__thing', TJson.NewObj, IsErr);
  Check(IsErr and (Out_ = 'unknown tool: other__thing'),
    'a name no source claims is still unknown: ' + Out_);

  { A subagent is never told about a source's tools, and never gets to call
    one: the schema cut is an Exit, and IsSubagentTool holds the boundary. }
  Check(EnterSubagent, 'claim the subagent slot');
  try
    Sch := ToolsSchema;
    try
      Check(Sch.Count = 3, 'a subagent still sees only the three read tools');
      Check(Pos('stub__', Sch.ToJson) = 0,
        'and is told about no source tool at all');
    finally
      Sch.Free;
    end;
    Out_ := Run('stub__one', TJson.NewObj, IsErr);
    Check(IsErr and (Pos('not available to a subagent', Out_) > 0),
      'and a source call is refused before any source is consulted: ' + Out_);
  finally
    LeaveSubagent;
  end;

  { A source that declares nothing must not disturb the array. }
  ClearToolSources;
  Ok := RegisterToolSource('none__', @EmptyDeclare, @StubRun, Err);
  Check(Ok, 'an empty declarer registers');
  Sch := ToolsSchema;
  try
    Check(Sch.Count = BuiltinToolCount,
      'and contributes nothing to the schema');
  finally
    Sch.Free;
  end;

  ClearToolSources;
  Out_ := Run('mcp__nope__x', TJson.NewObj, IsErr);
  Check(IsErr and (Out_ = 'unknown tool: mcp__nope__x'),
    'with no source registered even an mcp name is unknown: ' + Out_);
  { Put MCP back: everything after this expects the shipped registration. }
  RegisterMcpToolSource;
  Check(ToolSourceCount = 1, 'and the MCP source is back');
end;

{ --------------------------------------------------- MCP approval storage -- }

procedure TestMcpApprovals;
var
  H1, H2, H3, H4, P: string;
  A1, A2: array of string;
begin
  SetLength(A1, 2);
  A1[0] := '-y';
  A1[1] := 'server-github';
  SetLength(A2, 0);

  H1 := McpCommandHash('npx', A1, A2);
  Check(Length(H1) = 8, 'a command hash is eight hex digits: ' + H1);
  A1[1] := 'server-gitlab';
  H2 := McpCommandHash('npx', A1, A2);
  Check(H1 <> H2, 'changing an argument changes the hash');
  H3 := McpCommandHash('npm', A1, A2);
  Check(H2 <> H3, 'changing the command changes the hash');

  SetLength(A2, 2);
  A2[0] := 'TOKEN';
  A2[1] := 'HOST';
  H3 := McpCommandHash('npx', A1, A2);
  Check(H3 <> H2, 'adding an environment key changes the hash');
  A2[0] := 'HOST';
  A2[1] := 'TOKEN';
  H4 := McpCommandHash('npx', A1, A2);
  Check(H3 = H4, 'but the order two variables were written in does not');

  { Expansion happens before hashing, so what the fingerprint covers is the
    command line that will actually run. }
  Check(McpExpandVars('${PASCLAUDE_NOT_SET_ANYWHERE:-fallback}') = 'fallback',
    'an unset variable takes its default');
  Check(McpExpandVars('${PASCLAUDE_NOT_SET_ANYWHERE}') = '',
    'and an unset variable with no default is empty');
  Check(McpExpandVars('a${PASCLAUDE_NOT_SET_ANYWHERE:-b}c') = 'abc',
    'expansion happens in the middle of a string too');

  { The trust store round-trips through the permissions file, and only ever
    widens, exactly as the three boolean classes do. }
  P := IncludeTrailingPathDelimiter(GetTempDir) + 'pasclaude-mcp-perms.json';
  DeleteFile(P);
  ClearTrust;
  RecordTrust('mcp:github', H1);
  RecordTrust('mcp-call:github', H1);
  SavePermissions(P);
  ClearTrust;
  Check(TrustedFingerprint('mcp:github') = '', 'the wipe took the approvals');
  LoadPermissions(P);
  Check(TrustedFingerprint('mcp:github') = H1,
    'the spawn approval survived the restart');
  Check(TrustedFingerprint('mcp-call:github') = H1, 'and the per-call one');
  Check(TrustedFingerprint('mcp:other') = '',
    'and nothing was approved that was not written');

  ClearTrust;
  SavePermissions(P);            { the file now records nothing }
  RecordTrust('mcp:github', H1); { and this session grants something }
  LoadPermissions(P);
  Check(TrustedFingerprint('mcp:github') = H1,
    'loading an empty file never revokes a live grant');

  { The fingerprint is the point: a changed command line is a new question. }
  Check(TrustedFingerprint('mcp:github') <> H2,
    'and a different command line does not match the recorded one');

  DeleteFile(P);
  ClearTrust;
end;

{ ------------------------------------------------------ the fourth class -- }

procedure TestMcpPermissionClass;
var
  SavedEdits, SavedMcp: Boolean;
begin
  SavedEdits := uTools.AllowAllEdits;
  SavedMcp := uTools.AllowAllMcp;
  try
    { The hole this guards: the edits class is the catch-all, so a class that
      forgets to exclude itself from it inherits every /yolo edit approval. }
    uTools.AllowAllEdits := True;
    uTools.AllowAllMcp := False;
    ClearTrust;
    Check(not Permit('mcp__foo__x', 'detail', nil),
      'an MCP call is not covered by a standing approval for edits');
    Check(Permit('write_file', 'detail', nil),
      'while a write still is');

    uTools.AllowAllMcp := True;
    Check(Permit('mcp__foo__x', 'detail', nil),
      'and its own class approval does cover it');

    uTools.AllowAllMcp := False;
    uTools.AllowAllEdits := False;
    Check(not Permit('mcp__foo__x', 'detail', nil),
      'a nil Ask denies, as it does for every other class');
  finally
    uTools.AllowAllEdits := SavedEdits;
    uTools.AllowAllMcp := SavedMcp;
  end;
end;

procedure TestMcpScripted;
var
  C: Integer;
  Err, SName, SVer, SProto, Text, Big: string;
  Arr, Args: TJson;
  IsErr, Ok: Boolean;
  Started: QWord;
begin
  Check(not McpWireInstalled,
    'the shipped program installs no stand-in MCP wire');
  InstallWire;
  try
    { --- the handshake --- }
    ScriptReset;
    Script(InitOk);
    C := McpSpawn('mock', 'mock-command', '', '', [], Err);
    Check(C >= 0, 'a scripted server opens');
    Ok := McpHandshake(C, SName, SVer, SProto, Err);
    Check(Ok, 'the handshake completes: ' + Err);
    Check(SName = 'srv', 'and reports the server name');
    Check(SProto = '2025-06-18', 'and the negotiated protocol version');
    Check(Pos('"method":"initialize"', WireIn) > 0, 'initialize was sent');
    Check(Pos('"method":"notifications/initialized"', WireIn) > 0,
      'and so was notifications/initialized - a strict server answers ' +
      'nothing until it arrives');
    Check(CountLf(WireIn) = 2,
      'two messages, two newlines: the framing is one line per message');
    Check(McpState(C) = msRunning, 'and the connection is running');
    McpShutdownAll;
    Check(McpConnectionCount = 0, 'shutdown closes every connection');
    Check(WireClosed = 1, 'and the wire was told');

    { A server is entitled to answer with a version other than ours.  A
      client that demanded a match would be the "nothing ever starts"
      failure. }
    ScriptReset;
    Script('{"jsonrpc":"2.0","id":%ID%,"result":{"protocolVersion":' +
      '"2025-11-25","serverInfo":{"name":"older","version":"9"}}}');
    C := McpSpawn('mock', 'mock-command', '', '', [], Err);
    Check(McpHandshake(C, SName, SVer, SProto, Err),
      'a different protocol version is accepted, not refused');
    Check(SProto = '2025-11-25', 'and reported as what it is');
    McpShutdownAll;

    { A result that is not an object is the one fatal handshake answer. }
    ScriptReset;
    Script('{"jsonrpc":"2.0","id":%ID%,"result":"yes"}');
    C := McpSpawn('mock', 'mock-command', '', '', [], Err);
    Check(not McpHandshake(C, SName, SVer, SProto, Err),
      'a non-object result fails the handshake');
    McpShutdownAll;

    { --- tools/list becomes tool records --- }
    ScriptReset;
    Script(InitOk);
    Script(ListTwo);
    Check(Shook(C), 'a listing server shakes hands');
    Ok := McpListTools(C, Arr, Err);
    Check(Ok, 'tools/list succeeds: ' + Err);
    if Arr <> nil then
    try
      Check(Arr.Count = 2, 'and yields both declarations');
      Check(Arr.Item(0).Str('name') = 'echo', 'in the order the server gave');
    finally
      Arr.Free;
    end;
    McpShutdownAll;

    { --- pagination --- }
    ScriptReset;
    Script(InitOk);
    Script('{"jsonrpc":"2.0","id":%ID%,"result":{"tools":[{"name":"a"}],' +
      '"nextCursor":"c2"}}');
    Script('{"jsonrpc":"2.0","id":%ID%,"result":{"tools":[{"name":"b"}],' +
      '"nextCursor":"c3"}}');
    Script('{"jsonrpc":"2.0","id":%ID%,"result":{"tools":[{"name":"c"}]}}');
    Check(Shook(C), 'a paginating server shakes hands');
    Check(McpListTools(C, Arr, Err), 'and every page is followed');
    if Arr <> nil then
    try
      Check(Arr.Count = 3, 'so all three tools arrive');
    finally
      Arr.Free;
    end;
    Check(Pos('"cursor":"c2"', WireIn) > 0, 'and the cursor was echoed back');
    McpShutdownAll;

    { --- a call round trip, including the escaping the framing depends on --- }
    ScriptReset;
    Script(InitOk);
    Script('{"jsonrpc":"2.0","id":%ID%,"result":{"content":[' +
      '{"type":"text","text":"pong"},{"type":"image",' +
      '"mimeType":"image/png","data":"AAAA"}]}}');
    Check(Shook(C), 'a calling server shakes hands');
    Args := TJson.NewObj;
    Args.AddStr('text', 'two' + #10 + 'lines');
    try
      Ok := McpCallTool(C, 'echo', Args, 2000, Text, IsErr, Err);
      Check(Ok, 'tools/call round-trips: ' + Err);
    finally
      Args.Free;
    end;
    Check(not IsErr, 'and reports no error');
    Check(Pos('pong', Text) > 0, 'and carries the text block');
    Check(Pos('[image image/png', Text) > 0,
      'and a non-text block becomes a placeholder, not base64');
    Check(Pos('\n', WireIn) > 0,
      'a newline inside a value is escaped on the wire');
    Check(CountLf(WireIn) = 3,
      'so three messages are still three lines - the compact writer is what ' +
      'makes one-message-per-line true');
    McpShutdownAll;

    { --- both error channels --- }
    ScriptReset;
    Script(InitOk);
    Script('{"jsonrpc":"2.0","id":%ID%,"error":{"code":-32602,' +
      '"message":"unknown tool"}}');
    Script('{"jsonrpc":"2.0","id":%ID%,"result":{"content":[' +
      '{"type":"text","text":"it refused"}],"isError":true}}');
    Check(Shook(C), 'an erroring server shakes hands');
    Check(McpCallTool(C, 'nope', nil, 2000, Text, IsErr, Err),
      'a JSON-RPC error is an answer, not a transport failure');
    Check(IsErr and (Pos('mcp error -32602', Text) > 0),
      'and reaches the model as a failed result: ' + Text);
    Check(McpCallTool(C, 'boom', nil, 2000, Text, IsErr, Err),
      'and so is result.isError');
    Check(IsErr and (Pos('it refused', Text) > 0),
      'with the server text intact');
    McpShutdownAll;

    { --- junk on stdout, and an unsolicited request --- }
    ScriptReset;
    Script(InitOk);
    Script('this is not JSON' + #10 + '{"broken":' + #10 +
      '{"jsonrpc":"2.0","id":900,"method":"roots/list"}' + #10 +
      '{"jsonrpc":"2.0","id":4242,"result":{"tools":[]}}' + #10 +
      '{"jsonrpc":"2.0","id":%ID%,"result":{"content":[' +
      '{"type":"text","text":"survived"}]}}');
    Check(Shook(C), 'a noisy server shakes hands');
    Ok := McpCallTool(C, 'echo', nil, 2000, Text, IsErr, Err);
    Check(Ok, 'junk lines are discarded, not fatal: ' + Err);
    Check(Text = 'survived', 'and the real answer is still found');
    Check(Pos('-32601', WireIn) > 0,
      'a request from the server gets an answer so it is not left waiting');
    McpShutdownAll;

    { --- a server that never answers --- }
    ScriptReset;
    Script(InitOk);
    Check(Shook(C), 'a silent server shakes hands');
    Started := GetTickCount64;
    Check(not McpCallTool(C, 'echo', nil, 200, Text, IsErr, Err),
      'a call that is never answered fails');
    Check(GetTickCount64 - Started < 3000, 'and fails on the deadline');
    Check(Pos('did not answer', Err) > 0, 'saying so: ' + Err);
    Check(McpState(C) = msDead,
      'a server that ignored one request is not trusted with the next');
    Check(WireClosed = 1, 'and it was killed, not merely abandoned');
    Check(not McpCallTool(C, 'echo', nil, 200, Text, IsErr, Err),
      'and a later call on a dead connection fails cleanly');
    McpShutdownAll;

    { --- a server that dies mid-call --- }
    ScriptReset;
    Script(InitOk);
    Check(Shook(C), 'a doomed server shakes hands');
    WireAlive := False;
    Check(not McpCallTool(C, 'echo', nil, 5000, Text, IsErr, Err),
      'a server that exits mid-call fails the call');
    Check(McpState(C) = msDead, 'and is marked dead');
    Check(Pos('stopped', Err) > 0, 'naming what happened: ' + Err);
    McpShutdownAll;

    { A broken pipe says the same thing by a different route. }
    ScriptReset;
    Script(InitOk);
    Check(Shook(C), 'a third server shakes hands');
    WireBroken := True;
    Check(not McpCallTool(C, 'echo', nil, 5000, Text, IsErr, Err),
      'a broken pipe is EOF, not a hang');
    McpShutdownAll;

    { --- a result too large to pass on whole --- }
    ScriptReset;
    Script(InitOk);
    Script('{"jsonrpc":"2.0","id":%ID%,"result":{"content":[' +
      '{"type":"text","text":"' + StringOfChar('x', 200000) + '"}]}}');
    Check(Shook(C), 'a verbose server shakes hands');
    WireChunk := 65536;
    Ok := McpCallTool(C, 'echo', nil, 5000, Text, IsErr, Err);
    Check(Ok, 'a huge result still returns: ' + Err);
    Check(Length(Text) < McpMaxResultBytes + 200,
      Format('and is capped (%d bytes)', [Length(Text)]));
    Check(Pos('the rest is cut', Text) > 0, 'and says it was cut');
    McpShutdownAll;

    { --- a request we refuse to send --- }
    ScriptReset;
    Script(InitOk);
    Check(Shook(C), 'a fourth server shakes hands');
    Big := StringOfChar('y', McpMaxRequestBytes + 1000);
    Args := TJson.NewObj;
    Args.AddStr('text', Big);
    try
      Check(not McpCallTool(C, 'echo', Args, 500, Text, IsErr, Err),
        'an oversized request is refused locally');
    finally
      Args.Free;
    end;
    Check(Pos('too large', Err) > 0,
      'without ever touching the pipe: ' + Err);
    Check(McpState(C) = msRunning,
      'and the connection survives, because nothing was written');
    McpShutdownAll;

    { --- a line that never ends --- }
    ScriptReset;
    Script(InitOk);
    Check(Shook(C), 'a fifth server shakes hands');
    WireChunk := 65536;
    WireOut := StringOfChar('z', McpMaxLineBytes + 4096);
    Check(not McpCallTool(C, 'echo', nil, 20000, Text, IsErr, Err),
      'an unterminated line is bounded, not buffered forever');
    Check(Pos('unterminated', Err) > 0, 'saying so: ' + Err);
    Check(McpState(C) = msDead, 'and the connection is dropped');
    McpShutdownAll;
  finally
    McpShutdownAll;
    RemoveWire;
    ScriptReset;
  end;
  Check(not McpWireInstalled, 'and the wire is put back');
end;

{ The half a scripted wire cannot reach: real pipes, real inheritance, a real
  EOF and a real exit code. }
procedure TestMcpServerProcess;
var
  C: Integer;
  Exe, ErrLog, Err, SName, SVer, SProto, Text: string;
  Arr: TJson;
  IsErr, Ok: Boolean;
begin
  Exe := ExtractFilePath(ParamStr(0)) + 'srvmock.exe';
  Check(FileExists(Exe), 'the stand-in server binary was built: ' + Exe);
  if not FileExists(Exe) then Exit;
  ErrLog := IncludeTrailingPathDelimiter(GetTempDir) + 'pasclaude-mcp.err';

  C := McpSpawn('mock', '"' + Exe + '"', '', ErrLog, [], Err);
  if C < 0 then Check(False, 'a real server starts: ' + Err)
  else Check(True, 'a real server starts');
  if C < 0 then Exit;
  try
    Ok := McpHandshake(C, SName, SVer, SProto, Err);
    Check(Ok, 'and completes the handshake over real pipes: ' + Err);
    Check((SName = 'srv') and (SProto = '2025-06-18'),
      'reporting its name and version');
    Ok := McpListTools(C, Arr, Err);
    Check(Ok, 'tools/list over a pipe: ' + Err);
    if Arr <> nil then
    try
      Check(Arr.Count = 2, 'yields both tools');
    finally
      Arr.Free;
    end;
    Ok := McpCallTool(C, 'ping', nil, 10000, Text, IsErr, Err);
    Check(Ok, 'tools/call over a pipe: ' + Err);
    Check((not IsErr) and (Pos('pong', Text) > 0), 'and answers pong');
    Check(McpAlive(C), 'and the child is still there');
  finally
    McpClose(C);
  end;
  Check(McpConnectionCount = 0, 'closing brings the connection count to zero');
  Check(McpState(C) = msDead,
    'and a stale index answers dead rather than somebody else''s server');
  SysUtils.DeleteFile(ErrLog);
end;

{ ------------------------------------------------------------------ hooks -- }

var
  { A scripted TAskProc for the permission-interaction test: it counts and
    always refuses, so "the write happened" and "Ask was never called" are two
    independent assertions rather than one. }
  AskCalls: Integer = 0;

function AlwaysDeny(const Title, Detail: string): TPermission;
begin
  Inc(AskCalls);
  Result := pmDeny;
end;

function HookRoot: string;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir) + 'pasclaude-hooks';
end;

procedure WriteHooksFile(const Body: string);
var
  L: TStringList;
begin
  ForceDirectories(HookRoot + PathDelim + '.pasclaude');
  L := TStringList.Create;
  try
    L.Text := Body;
    L.SaveToFile(uHooks.HooksFilePath);
  finally
    L.Free;
  end;
end;

{ The primitive on its own, which is where the transport decisions are either
  true or not.  Everything above it is policy; this is the part that either
  deadlocks or does not. }
procedure TestRunChild;
var
  Out_, Payload, Big: string;
  Code: Integer;
  Timed: Boolean;
  Started: QWord;
  R: TSearchRec;
  Strays: Integer;
begin
  ForceDirectories(HookRoot);
  uTools.RootDir := HookRoot;

  Payload := '{"hook_event_name":"PreToolUse","tool_name":"write_file"}';
  Code := uHooks.RunChild('findstr /R .', Payload, '', 5000,
    uHooks.MaxHookOutBytes, Out_, Timed);
  Check((Code = 0) and not Timed, 'a hook that reads stdin exits 0');
  Check(Pos('hook_event_name', Out_) > 0,
    'and the payload really arrived on its stdin: ' + Copy(Out_, 1, 40));

  Code := uHooks.RunChild('echo blocked 1>&2 & exit /b 2', '', '', 5000,
    uHooks.MaxHookOutBytes, Out_, Timed);
  Check(Code = 2, 'exit 2 propagates through cmd.exe intact');
  Check(Pos('blocked', Out_) > 0, 'and stderr is merged into the spool');

  Started := GetTickCount64;
  Code := uHooks.RunChild('ping -n 30 127.0.0.1 >nul', '', '', 1500,
    uHooks.MaxHookOutBytes, Out_, Timed);
  Check(Timed, 'a hook past its deadline is killed');
  Check(GetTickCount64 - Started < 6000,
    'and the deadline is honoured, not merely noticed');

  { The deadlock case.  With a pipe for stdin this blocks forever at the
    buffer size, because there is no second thread to drain it. }
  Big := StringOfChar('x', 200 * 1024);
  Started := GetTickCount64;
  Code := uHooks.RunChild('echo ignored', Big, '', 5000,
    uHooks.MaxHookOutBytes, Out_, Timed);
  Check((Code = 0) and not Timed,
    'a child that never reads 200 KB of stdin still completes');
  Check(GetTickCount64 - Started < 5000, 'and does not stall waiting for it');

  Code := uHooks.RunChild('for /L %i in (1,1,20000) do @echo a line of output',
    '', '', 30000, uHooks.MaxHookOutBytes, Out_, Timed);
  Check(Length(Out_) = uHooks.MaxHookOutBytes,
    Format('a torrent of output is cut at the cap (%d)', [Length(Out_)]));
  Check(IsValidUtf8(Out_), 'and the cut leaves valid UTF-8');

  { The measured fact the whole exit-code rule rests on. }
  Code := uHooks.RunChild('no_such_program_xyz', '', '', 5000,
    uHooks.MaxHookOutBytes, Out_, Timed);
  Check((Code <> 0) and (Code <> 2),
    Format('a nonexistent program exits nonzero but not 2 (%d)', [Code]));

  Strays := 0;
  if FindFirst(HookRoot + PathDelim + '.pasclaude' + PathDelim + 'tmp' +
       PathDelim + 'hook-*.*', faAnyFile, R) = 0 then
  begin
    repeat
      Inc(Strays);
    until FindNext(R) <> 0;
    SysUtils.FindClose(R);
  end;
  Check(Strays = 0, 'and every call cleaned up both of its temporary files');
end;

procedure TestHookConfig;
var
  Notes, F1, F2: string;
  L: TStringList;
  I: Integer;
begin
  uTools.RootDir := HookRoot;

  WriteHooksFile('{"hooks":{' +
    '"PreToolUse":[{"matcher":"^(write_file|edit_file)$","command":"echo pre"}],' +
    '"Stop":[{"command":"echo stop","timeout_ms":2000}]}}');
  uHooks.LoadHooks(True, Notes);
  Check(uHooks.HooksEnabled, 'a valid file loads');
  Check(uHooks.HookCount(hePreTool) = 1, 'one PreToolUse hook');
  Check(uHooks.HookCount(heStop) = 1, 'one Stop hook');
  Check(uHooks.HookCount(hePostTool) = 0, 'and nothing for the others');
  Check(Trim(Notes) = '', 'and nothing to complain about: ' + Notes);

  { Trust is the gate, and it gates the parse itself. }
  uHooks.LoadHooks(False, Notes);
  Check(not uHooks.HooksEnabled, 'an untrusted file loads nothing at all');
  Check(uHooks.HookCount(hePreTool) = 0, 'not even one entry');

  F1 := uHooks.HookFingerprint;
  F2 := uHooks.HookFingerprint;
  Check((F1 <> '') and (F1 = F2), 'the fingerprint is stable: ' + F1);
  L := TStringList.Create;
  try
    L.LoadFromFile(uHooks.HooksFilePath);
    L.Add('');
    L.SaveToFile(uHooks.HooksFilePath);
  finally
    L.Free;
  end;
  Check(uHooks.HookFingerprint <> F1, 'and changes when the bytes change');

  { An event pasclaude does not fire is named, not swallowed: a config pasted
    in from elsewhere says which half of itself will do nothing. }
  WriteHooksFile('{"hooks":{"SessionEnd":[{"command":"echo bye"}]}}');
  uHooks.LoadHooks(True, Notes);
  Check(uHooks.HookCount(heStop) = 0, 'SessionEnd registers nothing');
  Check(Pos('SessionEnd', Notes) > 0,
    'and the note names it: ' + Trim(Notes));

  WriteHooksFile('{"hooks":{"PreToolUse":[{"matcher":"^x$"}]}}');
  uHooks.LoadHooks(True, Notes);
  Check(uHooks.HookCount(hePreTool) = 0, 'an entry with no command is skipped');
  Check(Pos('command', Notes) > 0, 'and noted: ' + Trim(Notes));

  WriteHooksFile('{"hooks":{"PreToolUse":[{"matcher":"(","command":"echo x"}]}}');
  uHooks.LoadHooks(True, Notes);
  Check(uHooks.HookCount(hePreTool) = 0,
    'a matcher that will not compile disables its hook');
  Check(Pos('will not compile', Notes) > 0,
    'at load time, not mid-tool-call: ' + Trim(Notes));

  { Claude Code's nested shape is reported rather than half-supported. }
  WriteHooksFile('{"hooks":{"PreToolUse":[{"matcher":"^x$","hooks":' +
    '[{"type":"command","command":"echo x"}]}]}}');
  uHooks.LoadHooks(True, Notes);
  Check(uHooks.HookCount(hePreTool) = 0, 'the nested shape registers nothing');
  Check(Pos('flat', Notes) > 0, 'and says what pasclaude wants: ' + Trim(Notes));

  F1 := '{"hooks":{"PreToolUse":[';
  for I := 1 to 12 do
  begin
    if I > 1 then F1 := F1 + ',';
    F1 := F1 + '{"command":"echo ' + IntToStr(I) + '"}';
  end;
  WriteHooksFile(F1 + ']}}');
  uHooks.LoadHooks(True, Notes);
  Check(uHooks.HookCount(hePreTool) = uHooks.MaxHooksPerEvent,
    Format('twelve entries for one event load %d', [uHooks.HookCount(hePreTool)]));
  Check(Pos('only the first', Notes) > 0, 'and the cap is visible: ' + Trim(Notes));

  uHooks.ClearHooks;
  Check(not uHooks.HooksEnabled, 'ClearHooks turns the feature off');
  Check(uHooks.HookCount(hePreTool) = 0, 'and empties the table');
end;

{ End to end through RunTool, which is the only path that proves the wrapper
  fires around the ladder rather than beside it. }
procedure TestHookDispatch;
var
  Notes, Out_, Target: string;
  J: TJson;
  IsErr: Boolean;
  Saved: Boolean;
begin
  uTools.RootDir := HookRoot;
  Saved := uTools.AllowAllEdits;
  uTools.AllowAllEdits := True;
  Target := HookRoot + PathDelim + 'hooked.txt';
  DeleteFile(Target);
  try
    WriteHooksFile('{"hooks":{"PreToolUse":[{"matcher":"^write_file$",' +
      '"command":"echo not on my watch & exit /b 2"}]}}');
    uHooks.LoadHooks(True, Notes);

    J := TJson.NewObj;
    J.AddStr('path', 'hooked.txt');
    J.AddStr('content', 'x');
    Out_ := Run('write_file', J, IsErr);
    Check(IsErr, 'a PreToolUse block is an error result');
    Check(Pos('not on my watch', Out_) > 0,
      'carrying the hook''s own words: ' + Out_);
    Check(not FileExists(Target),
      'and the tool never ran, so the file does not exist');

    { The matcher is real: the same hook must not fire for another tool. }
    WriteHooksFile('{"hooks":{"PreToolUse":[{"matcher":"^bash$",' +
      '"command":"echo not on my watch & exit /b 2"}]}}');
    uHooks.LoadHooks(True, Notes);
    J := TJson.NewObj;
    J.AddStr('path', 'hooked.txt');
    J.AddStr('content', 'canary');
    Out_ := Run('write_file', J, IsErr);
    Check(not IsErr, 'a hook whose matcher misses does not fire: ' + Out_);
    Check(FileExists(Target), 'and the write happened');

    { PostToolUse appends rather than replaces, so the model still gets the
      tool's answer along with the objection. }
    WriteHooksFile('{"hooks":{"PostToolUse":[{"command":"echo reviewed"}]}}');
    uHooks.LoadHooks(True, Notes);
    J := TJson.NewObj;
    J.AddStr('path', 'hooked.txt');
    Out_ := Run('read_file', J, IsErr);
    Check(not IsErr, 'a PostToolUse hook exiting 0 is not an error');
    Check(Pos('reviewed', Out_) > 0, 'its text is appended: ' + Out_);
    Check(Pos('canary', Out_) > 0, 'and the tool result is still there');

    WriteHooksFile('{"hooks":{"PostToolUse":[{"command":"echo rejected & ' +
      'exit /b 2"}]}}');
    uHooks.LoadHooks(True, Notes);
    J := TJson.NewObj;
    J.AddStr('path', 'hooked.txt');
    Out_ := Run('read_file', J, IsErr);
    Check(IsErr, 'a PostToolUse block marks the result as an error');
    Check((Pos('rejected', Out_) > 0) and (Pos('canary', Out_) > 0),
      'without throwing away what the tool actually returned');

    { Hooks fire around a registered source''s tools too, by name and with no
      coordination between the two features - the wrapper is outside the
      ladder, and the dispatcher lives inside its terminal else. }
    ClearToolSources;
    Check(RegisterToolSource('stub__', @StubDeclare, @StubRun, Notes),
      'a source registers for the hook-reach test');
    WriteHooksFile('{"hooks":{"PreToolUse":[{"matcher":"^stub__",' +
      '"command":"echo no sources here & exit /b 2"}]}}');
    uHooks.LoadHooks(True, Notes);
    Out_ := Run('stub__one', TJson.NewObj, IsErr);
    Check(IsErr and (Pos('no sources here', Out_) > 0),
      'a PreToolUse hook blocks an MCP-shaped tool as well: ' + Out_);
    ClearToolSources;
    RegisterMcpToolSource;

    uHooks.ClearHooks;
  finally
    uTools.AllowAllEdits := Saved;
    DeleteFile(Target);
  end;
end;

{ The single most important test here: where the hook allow sits relative to
  the nil-Ask check. }
procedure TestHookPermission;
var
  Notes, Out_, Target: string;
  J: TJson;
  IsErr: Boolean;
  SavedEdits: Boolean;
begin
  uTools.RootDir := HookRoot;
  SavedEdits := uTools.AllowAllEdits;
  uTools.AllowAllEdits := False;
  Target := HookRoot + PathDelim + 'allowed.txt';
  try
    WriteHooksFile('{"hooks":{"PreToolUse":[{"matcher":"^write_file$",' +
      '"command":"echo {\"decision\":\"allow\"}"}]}}');
    uHooks.LoadHooks(True, Notes);
    Check(uHooks.HooksEnabled, 'the allow hook loaded: ' + Trim(Notes));

    { Nil Ask is print mode and a subagent both.  A hook must not be able to
      widen either, and the property comes from the line's position rather
      than from a rule anybody has to remember. }
    DeleteFile(Target);
    J := TJson.NewObj;
    J.AddStr('path', 'allowed.txt');
    J.AddStr('content', 'x');
    Out_ := uTools.RunTool('write_file', J, nil, IsErr);
    J.Free;
    Check(IsErr, 'with no way to ask, a hook allow still denies: ' + Out_);
    Check(not FileExists(Target), 'and nothing was written');

    { With somebody to ask, the allow answers for them - and the somebody is
      never consulted, which is what makes it an allow rather than a default. }
    AskCalls := 0;
    DeleteFile(Target);
    J := TJson.NewObj;
    J.AddStr('path', 'allowed.txt');
    J.AddStr('content', 'x');
    Out_ := uTools.RunTool('write_file', J, @AlwaysDeny, IsErr);
    J.Free;
    Check(not IsErr, 'a hook allow satisfies the gate: ' + Out_);
    Check(FileExists(Target), 'and the write happened');
    Check(AskCalls = 0, Format('without asking the user at all (%d calls)',
      [AskCalls]));

    Check(not uTools.TakeHookAllow,
      'and the allow does not outlive its tool call');
  finally
    uHooks.ClearHooks;
    uTools.AllowAllEdits := SavedEdits;
    DeleteFile(Target);
  end;
end;

procedure TestPermissionPersistence;
var
  P: string;
begin
  P := IncludeTrailingPathDelimiter(GetTempDir) + 'pasclaude-perms.json';
  DeleteFile(P);

  ClearBashPrefixes;
  uTools.AllowAllEdits := False;
  uTools.AllowAllBash := False;
  uTools.AllowAllFetch := False;

  uTools.AllowAllEdits := True;
  AllowBashPrefix('git status');
  AllowBashPrefix('build');
  SavePermissions(P);

  { The wipe stands in for a process exit. }
  ClearBashPrefixes;
  uTools.AllowAllEdits := False;
  Check(not BashPrefixAllowed('git log'), 'the wipe took the approvals');

  LoadPermissions(P);
  Check(uTools.AllowAllEdits, 'the edit-class always came back');
  Check(not uTools.AllowAllBash, 'bash-all was never granted and stays off');
  Check(not uTools.AllowAllFetch, 'fetch stays off too');
  Check(BashPrefixAllowed('git log'), 'the git approval survived the restart');
  Check(BashPrefixAllowed('build debug'), 'and the build approval');
  Check(not BashPrefixAllowed('del x'), 'del was never approved and still is not');

  { A file that grants nothing narrows nothing: approvals only widen.  The
    file must genuinely not grant, so it is written while everything is
    off, and only then is the live grant made. }
  ClearBashPrefixes;
  uTools.AllowAllEdits := False;
  SavePermissions(P);   { the file now says allow_edits: false }
  uTools.AllowAllEdits := True;
  LoadPermissions(P);
  Check(uTools.AllowAllEdits, 'loading never revokes a live grant');

  { Garbage is ignored, not fatal. }
  ClearBashPrefixes;
  uTools.AllowAllEdits := False;
  with TStringList.Create do
  try
    Text := 'not json at all';
    SaveToFile(P);
  finally
    Free;
  end;
  LoadPermissions(P);
  Check(not uTools.AllowAllEdits, 'a garbled file approves nothing');

  DeleteFile(P);
  ClearBashPrefixes;
  uTools.AllowAllEdits := False;
end;

var
  Schema: TJson;
begin
  TestJson;
  TestRegexEngine;
  TestTools;
  TestFetch;
  TestBashPrefixes;
  TestBackgroundJobs;
  TestChangedFiles;
  TestListModels;
  TestTodos;
  TestSubagentGate;
  TestPermissionPersistence;
  TestToolRegistry;
  TestMcpApprovals;
  TestMcpPermissionClass;
  TestMcpScripted;
  TestMcpServerProcess;
  TestRunChild;
  TestHookConfig;
  TestHookDispatch;
  TestHookPermission;
  Schema := ToolsSchema;
  try
    Check(Pos('"input_schema"', Schema.ToJson) > 0, 'the schema serialises');
    Check(Pos('"integer"', Schema.ToJson) > 0,
      'and carries the new depth properties');
    Check(Pos('"case_sensitive"', Schema.ToJson) > 0,
      'and the search flags');
    { A tool implemented in RunTool but missing from the schema is one the
      model can never call, and nothing else would notice. }
    Check(Pos('"bash_output"', Schema.ToJson) > 0,
      'and bash_output is declared to the model');
    Check(Pos('"kill_bash"', Schema.ToJson) > 0, 'and kill_bash');
    Check(Pos('"run_in_background"', Schema.ToJson) > 0,
      'and bash advertises run_in_background');
  finally
    Schema.Free;
  end;
  WriteLn;
  if Fails = 0 then
    WriteLn('all tests passed')
  else
    WriteLn(Fails, ' test(s) failed');
  { ExitCode rather than Halt: Halt skips the cleanup of temporaries, which
    shows up as a phantom leak under -gh. }
  ExitCode := Ord(Fails <> 0);
end.
