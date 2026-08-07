{ Drives TAgent.Send end to end against scripted responses, which is the only
  way to exercise the multi-round tool loop without an API key: the model asks
  for a tool, the tool runs, the result is fed back, and the model answers.

  The transport is substituted, so everything above it - request building,
  streaming, block assembly, tool dispatch, transcript growth, the round limit
  - is the shipped code.

      fpc -Fusrc -FUbuild\units -obin\loop.exe tests\loop.lpr
      bin\loop.exe }
program loop;

{$mode objfpc}{$H+}

uses SysUtils, Classes, uJson, uHttp, uHooks, uTools, uAgent, uSdk;

var
  Fails: Integer = 0;

  { The scripted exchange. }
  Replies: array of string;   { response body per request, in order }
  Requests: array of string;  { what the agent actually sent }
  ReqHeaders: array of string; { headers per request, in order }
  CallCount: Integer = 0;
  FailAfter: Integer = -1;    { when >= 0, the transport errors from this call }
  FailUntil: Integer = 0;     { ... up to and including this call number }
  FailStatus: Integer = 529;
  FailBody: string = '';
  { When nonzero, failed responses carry this Retry-After (already in ms). }
  FakeRetryAfterMs: Integer = 0;

  Prose: string = '';
  Notices: string = '';
  ToolLog: string = '';
  ToolBegins: string = '';
  ToolArgs: string = '';
  { Set by the cancellation tests; the transport counts chunks it emitted. }
  CancelAfterChunks: Integer = -1;
  ChunksSeen: Integer = 0;

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

procedure CapText(const S: string);
begin
  Prose := Prose + S;
end;

procedure CapNotice(const S: string);
begin
  Notices := Notices + S + ';';
end;

procedure CapTool(const Name, Detail: string);
begin
  ToolLog := ToolLog + Detail + ';';
end;

procedure CapResult(const Name, Output: string);
begin
end;

procedure CapToolBegin(const Name, Id: string);
begin
  ToolBegins := ToolBegins + Name + ';';
end;

procedure CapToolArg(const S: string);
begin
  ToolArgs := ToolArgs + S;
end;

{ The stand-in transport: records the request, replays the next scripted
  response, and hands it to the caller in small chunks so the streaming path
  is used rather than bypassed. }
function FakePost(const Url, Headers, Body: string;
  OnChunk: TChunkProc; Ctx: Pointer): THttpResult;
var
  Reply: string;
  I, N: Integer;
begin
  Result.Ok := False;
  Result.Status := 0;
  Result.Body := '';
  Result.Error := '';
  Result.RetryAfterMs := 0;

  SetLength(Requests, Length(Requests) + 1);
  Requests[High(Requests)] := Body;
  SetLength(ReqHeaders, Length(ReqHeaders) + 1);
  ReqHeaders[High(ReqHeaders)] := Headers;
  Inc(CallCount);

  if (FailAfter >= 0) and (CallCount > FailAfter) and (CallCount <= FailUntil) then
  begin
    Result.Status := FailStatus;
    Result.RetryAfterMs := FakeRetryAfterMs;
    if FailBody <> '' then
      Result.Body := FailBody
    else
      Result.Body := '{"type":"error","error":{"type":"overloaded_error",' +
                     '"message":"Overloaded"}}';
    Result.Error := Format('HTTP %d', [FailStatus]);
    Exit;
  end;

  if CallCount > Length(Replies) then
  begin
    { Running past the script means the loop did not stop when it should. }
    Result.Status := 500;
    Result.Body := '{"error":{"type":"test_error","message":"script exhausted"}}';
    Result.Error := 'HTTP 500';
    Exit;
  end;

  Reply := Replies[CallCount - 1];
  N := 9;
  I := 1;
  while I <= Length(Reply) do
  begin
    Inc(ChunksSeen);
    if Assigned(OnChunk) then
      if not OnChunk(Copy(Reply, I, N), Ctx) then Break;
    Inc(I, N);
  end;
  Result.Ok := True;
  Result.Status := 200;
end;

function Ev(const Payload: string): string;
begin
  Result := 'event: x'#10'data: ' + Payload + #10#10;
end;

{ A reply that calls one tool. }
function ToolReply(const Id, Name, InputJson: string): string;
begin
  Result :=
    Ev('{"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":1}}}') +
    Ev('{"type":"content_block_start","index":0,"content_block":' +
       '{"type":"tool_use","id":' + JsonQuote(Id) + ',"name":' + JsonQuote(Name) + '}}') +
    Ev('{"type":"content_block_delta","index":0,"delta":' +
       '{"type":"input_json_delta","partial_json":' + JsonQuote(InputJson) + '}}') +
    Ev('{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}');
end;

{ A reply that just speaks and ends the turn. }
function TextReply(const Text: string): string;
begin
  Result :=
    Ev('{"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":1}}}') +
    Ev('{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}') +
    Ev('{"type":"content_block_delta","index":0,"delta":' +
       '{"type":"text_delta","text":' + JsonQuote(Text) + '}}') +
    Ev('{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":30}}');
end;

{ A reply that streams Text as several deltas, so a cancellation can land in
  the middle of it. }
function LongTextReply(const Piece: string; Count: Integer): string;
var
  I: Integer;
begin
  Result :=
    Ev('{"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":1}}}') +
    Ev('{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}');
  for I := 1 to Count do
    Result := Result +
      Ev('{"type":"content_block_delta","index":0,"delta":' +
         '{"type":"text_delta","text":' + JsonQuote(Piece) + '}}');
  Result := Result +
    Ev('{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":30}}');
end;

procedure ResetScript;
begin
  Replies := nil;
  Requests := nil;
  ReqHeaders := nil;
  CallCount := 0;
  FailAfter := -1;
  FailUntil := 0;
  FailStatus := 529;
  FailBody := '';
  FakeRetryAfterMs := 0;
  ChunksSeen := 0;
  Prose := '';
  Notices := '';
  ToolLog := '';
  ToolBegins := '';
  ToolArgs := '';
end;

{ The skills scan reads %USERPROFILE% from inside uTools, and this suite
  counts declared tools: a developer with a skill in their own home directory
  would make every one of those counts one too high. }
function SetEnvironmentVariable(Name, Value: PChar): LongBool; stdcall;
  external 'kernel32' name 'SetEnvironmentVariableA';

function SessionDir: string;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir) + 'pasclaude-loop';
  ForceDirectories(Result);
end;

procedure WriteSessionFile(const Name, Content: string);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Text := Content;
    L.SaveToFile(IncludeTrailingPathDelimiter(SessionDir) + Name);
  finally
    L.Free;
  end;
end;

function MakeAgent: TAgent;
begin
  Result := TAgent.Create('k', 'm', 'sys');
  Result.OnText := @CapText;
  Result.OnNotice := @CapNotice;
  Result.OnToolStart := @CapTool;
  Result.OnToolResult := @CapResult;
end;

{ The headline case: read a file, then answer using what it said. }
procedure TestTwoRoundLoop;
var
  A: TAgent;
  Err: string;
  Ok: Boolean;
  Doc, Msgs, C: TJson;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  uTools.AllowAllEdits := True;
  uTools.AllowAllBash := True;
  WriteSessionFile('note.txt', 'the answer is 42');

  SetLength(Replies, 2);
  Replies[0] := ToolReply('toolu_1', 'read_file', '{"path":"note.txt"}');
  Replies[1] := TextReply('The note says the answer is 42.');

  A := MakeAgent;
  try
    Ok := A.Send('what does note.txt say?', Err);
    Check(Ok, 'a two-round turn completes: ' + Err);
    Check(CallCount = 2, 'the agent made a second request after the tool ran');
    Check(Pos('read note.txt', ToolLog) > 0, 'the tool was dispatched');
    Check(Prose = 'The note says the answer is 42.',
      'the final answer was streamed to the caller');

    { The second request must carry the first round's result, or the model
      would be answering blind. }
    Doc := JsonParse(Requests[1]);
    try
      Msgs := Doc.Find('messages');
      Check(Msgs.Count = 3, 'the second request carries user, assistant, result');
      Check(Msgs.Item(0).Str('role') = 'user', 'the original question is first');
      Check(Msgs.Item(1).Str('role') = 'assistant', 'the tool call is second');
      C := Msgs.Item(2).Find('content').Item(0);
      Check(C.Str('type') = 'tool_result', 'the tool result is third');
      Check(Pos('the answer is 42', C.Str('content')) > 0,
        'the file contents reached the second request');
      Check(C.Str('tool_use_id') = 'toolu_1', 'the result is tied to the call');
    finally
      Doc.Free;
    end;

    Check(A.TokensIn = 20, 'input tokens accumulate across rounds');
    Check(A.TokensOut = 50, 'output tokens accumulate across rounds');
    Check(A.TurnCount = 1, 'the whole exchange counts as one turn');
  finally
    A.Free;
  end;
end;

{ Several tools in sequence, which is what a real task looks like. }
procedure TestThreeRoundLoop;
var
  A: TAgent;
  Err, Written: string;
  L: TStringList;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  uTools.AllowAllEdits := True;
  WriteSessionFile('src.txt', 'alpha');

  SetLength(Replies, 3);
  Replies[0] := ToolReply('t1', 'read_file', '{"path":"src.txt"}');
  Replies[1] := ToolReply('t2', 'write_file',
    '{"path":"out.txt","content":"alpha and omega"}');
  Replies[2] := TextReply('Done.');

  A := MakeAgent;
  try
    A.Send('copy it with a suffix', Err);
    Check(CallCount = 3, 'three rounds run to completion');
    Check(Prose = 'Done.', 'the closing message is delivered');

    { The write must have actually happened, not just been reported. }
    Written := IncludeTrailingPathDelimiter(SessionDir) + 'out.txt';
    Check(FileExists(Written), 'the second tool really wrote the file');
    if FileExists(Written) then
    begin
      L := TStringList.Create;
      try
        L.LoadFromFile(Written);
        Check(Pos('alpha and omega', L.Text) > 0, 'the file has the right contents');
      finally
        L.Free;
      end;
    end;
  finally
    A.Free;
  end;
end;

{ A model that never stops calling tools must be cut off rather than loop
  forever, and the user must be told. }
procedure TestRoundLimit;
var
  A: TAgent;
  Err: string;
  Ok: Boolean;
  I: Integer;
  Path: string;
  Doc, Msgs, Last: TJson;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  SetLength(Replies, MaxToolRounds + 5);
  for I := 0 to High(Replies) do
    Replies[I] := ToolReply('t' + IntToStr(I), 'list_dir', '{"path":"."}');

  A := MakeAgent;
  try
    Ok := A.Send('go forever', Err);
    Check(Ok, 'hitting the round limit is not an error');
    Check(CallCount = MaxToolRounds,
      Format('the loop stops after %d rounds, not more', [MaxToolRounds]));
    Check(Pos('tool rounds', Notices) > 0, 'the user is told the loop was cut off');

    { The loop stops immediately after RunTools appended a tool_result that was
      never sent, so the transcript now ends on a user message carrying tool
      results.  Asking anything afterwards would put a second user turn right
      behind it, and autosave writes that state to disk either way. }
    Path := IncludeTrailingPathDelimiter(SessionDir) + 'roundlimit.json';
    Check(A.SaveSession(Path, Err), 'the cut-off turn saves: ' + Err);

    { Unwinding the unsent results leaves the user's original question with
      nothing answering it, which is the same state a failed turn produces and
      is handled the same way: it is dropped rather than saved, so the next
      question does not stack behind it. }
    Check(not A.TrimUnansweredQuestion,
      'Send already trimmed the unanswered question at the round limit');
    Doc := JsonParse(A.Transcript);
    try
      Check((Doc.Count = 0) or
            (Doc.Item(Doc.Count - 1).Str('role') <> 'user'),
        'so the transcript no longer ends on a question');
    finally
      Doc.Free;
    end;

    { The next question must not simply pile up behind the unsent results. }
    ResetScript;
    SetLength(Replies, 1);
    Replies[0] := TextReply('answering the follow-up');
    Ok := A.Send('what happened?', Err);
    Check(Ok, 'a question after the round limit still works: ' + Err);

    Doc := JsonParse(Requests[0]);
    try
      Msgs := Doc.Find('messages');
      Err := '';
      for I := 0 to Msgs.Count - 1 do
        Err := Err + Msgs.Item(I).Str('role') + '/' +
          Msgs.Item(I).Find('content').Item(0).Str('type') + ' ';
      { With the cut-off turn unwound, the follow-up is a clean request: it
        must not contain two user turns in a row anywhere, nor a tool_use with
        nothing answering it. }
      Ok := True;
      for I := 1 to Msgs.Count - 1 do
      begin
        Last := Msgs.Item(I - 1);
        if (Last.Str('role') = 'user') and
           (Msgs.Item(I).Str('role') = 'user') then Ok := False;
        if Last.Find('content').Item(0).Str('type') = 'tool_use' then
          if Msgs.Item(I).Find('content').Item(0).Str('type') <> 'tool_result' then
            Ok := False;
      end;
      Check(Ok, 'the follow-up request has no consecutive user turns and no ' +
        'unanswered tool call: ' + Err);
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;

  { And what was written to disk has to be loadable, since autosave already
    wrote it. }
  A := MakeAgent;
  try
    Check(A.LoadSession(Path, Err),
      'a session saved at the round limit reloads: ' + Err);
  finally
    A.Free;
  end;
end;

{ A failure mid-loop must abort the turn and report, not carry on. }
procedure TestMidLoopFailure;
var
  A: TAgent;
  Err: string;
  Ok: Boolean;
  Path: string;
  Doc, Msgs: TJson;
  Shape: string;
  I: Integer;
  Good: Boolean;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  SetLength(Replies, 3);
  Replies[0] := ToolReply('t1', 'list_dir', '{"path":"."}');
  Replies[1] := TextReply('never reached');
  FailAfter := 1;      { the second request fails }
  FailUntil := 99;

  A := MakeAgent;
  try
    Ok := A.Send('do a thing', Err);
    Check(not Ok, 'a mid-loop transport failure fails the turn');
    Check(Pos('529', Err) > 0, 'the status is reported: ' + Err);
    Check(Pos('overloaded_error', Err) > 0, 'the API error type is reported');
    { The second request is retried before the turn gives up, so the count is
      the first success plus every attempt at the second. }
    Check(CallCount = 1 + MaxRetries + 1,
      Format('the loop retried then stopped, expected %d calls, got %d',
        [1 + MaxRetries + 1, CallCount]));

    { The turn aborted right after RunTools appended a tool_result that was
      never sent - the same state the round limit produced.  autosave runs
      after a failed turn too, so whatever is left has to be storable and
      resumable rather than a transcript the API would refuse. }
    Path := IncludeTrailingPathDelimiter(SessionDir) + 'midfail.json';
    Check(A.SaveSession(Path, Err), 'the aborted turn saves: ' + Err);

    { The turn aborted after a tool_result was appended but before it was ever
      sent, so the transcript ends on a user turn.  Asking again would put a
      second user turn straight behind it - the same defect the round limit
      had, reached by the failure path. }
    ResetScript;
    FailAfter := -1;
    FailUntil := 0;
    SetLength(Replies, 1);
    Replies[0] := TextReply('answering after the failure');
    Ok := A.Send('try again', Err);
    Check(Ok, 'a question after a mid-loop failure works: ' + Err);

    Doc := JsonParse(Requests[0]);
    try
      Msgs := Doc.Find('messages');
      Shape := '';
      for I := 0 to Msgs.Count - 1 do
        Shape := Shape + Msgs.Item(I).Str('role') + '/' +
          Msgs.Item(I).Find('content').Item(0).Str('type') + ' ';
      Good := True;
      for I := 1 to Msgs.Count - 1 do
        if (Msgs.Item(I - 1).Str('role') = 'user') and
           (Msgs.Item(I).Str('role') = 'user') then Good := False;
      Check(Good, 'no two user turns in a row after a failed turn: ' + Shape);
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;

  A := MakeAgent;
  try
    Check(A.LoadSession(Path, Err),
      'a session saved after a mid-loop failure reloads: ' + Err);
  finally
    A.Free;
  end;
end;

{ A denied tool must still complete the turn: the model gets the refusal as a
  result and can respond to it. }
procedure TestDeniedToolContinues;
var
  A: TAgent;
  Err: string;
  Doc, C: TJson;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  uTools.AllowAllEdits := False;
  uTools.AllowAllBash := False;

  SetLength(Replies, 2);
  Replies[0] := ToolReply('t1', 'write_file', '{"path":"nope.txt","content":"x"}');
  Replies[1] := TextReply('Understood, I will not write it.');

  A := MakeAgent;
  try
    A.Send('write a file', Err);
    Check(CallCount = 2, 'the turn continues after a denial');
    Check(Prose = 'Understood, I will not write it.',
      'the model responds to the refusal');
    Check(not FileExists(IncludeTrailingPathDelimiter(SessionDir) + 'nope.txt'),
      'the denied write never happened');

    Doc := JsonParse(Requests[1]);
    try
      C := Doc.Find('messages').Item(2).Find('content').Item(0);
      Check(C.Bool('is_error'), 'the denial is marked as an error result');
      Check(Pos('denied', C.Str('content')) > 0, 'the refusal reaches the model');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;
  uTools.AllowAllEdits := True;
end;

{ A deny rule refuses inside RunTool rather than at the gate, which is a new
  early exit on the path uAgent's one-tool_result-per-tool_use invariant
  depends on.  The transcript has to be exactly what a permission denial
  produces, or the next request is one the API rejects. }
procedure TestDenyProducesToolResult;
var
  A: TAgent;
  Err: string;
  Doc, Msg, C: TJson;
  Found: Integer;
  I: Integer;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  uTools.ClearDenyRules;
  { The most permissive state there is, so the refusal can only be the rule. }
  uTools.AllowAllEdits := True;
  uTools.AddDenyRule('path:secret.txt', 'test');

  SetLength(Replies, 2);
  Replies[0] := ToolReply('t1', 'write_file',
    '{"path":"secret.txt","content":"x"}');
  Replies[1] := TextReply('Understood, that path is off limits.');

  A := MakeAgent;
  try
    A.Send('write the secret', Err);
    Check(CallCount = 2, 'the turn continues after a deny rule refuses');
    Check(not FileExists(IncludeTrailingPathDelimiter(SessionDir) +
      'secret.txt'), 'and nothing was written');
    Check(IsValidUtf8(Requests[1]), 'the follow-up body is valid UTF-8');

    Doc := JsonParse(Requests[1]);
    try
      Msg := Doc.Find('messages').Item(2).Find('content');
      Found := 0;
      for I := 0 to Msg.Count - 1 do
        if Msg.Item(I).Str('tool_use_id') = 't1' then Inc(Found);
      Check(Found = 1, Format('exactly one tool_result for the tool_use (%d)',
        [Found]));
      C := Msg.Item(0);
      Check(C.Bool('is_error'), 'marked as an error result');
      Check(Pos('refused by deny rule', C.Str('content')) > 0,
        'naming the refusal: ' + C.Str('content'));
      Check(Pos('path:secret.txt', C.Str('content')) > 0,
        'and the rule itself, so a rule is not mistaken for a bug');
    finally
      Doc.Free;
    end;
    Check(Prose = 'Understood, that path is off limits.',
      'and the conversation reaches a normal reply');

    { The one line the whole session-note design turns on. }
    Doc := JsonParse(Requests[0]);
    try
      Check(Doc.Find('system').Count = 2,
        'a session with rules in force carries a second system block');
      Check(Doc.Find('system').Item(1).Find('cache_control') = nil,
        'and it is deliberately not part of the cached prefix');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;
  uTools.ClearDenyRules;

  { And with everything at its default the body is what it always was. }
  ResetScript;
  SetLength(Replies, 1);
  Replies[0] := TextReply('hello');
  A := MakeAgent;
  try
    A.Send('hi', Err);
    Doc := JsonParse(Requests[0]);
    try
      Check(Doc.Find('system').Count = 1,
        'with no rules there is no second block at all');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;
end;

{ Print mode has no human, so it must never be the most permissive mode.  The
  ordering that guarantees it is that the host calls LoadDenyRules before the
  print-mode halt and LoadPermissions after; this pins the half of it that
  lives in this unit. }
procedure TestPrintModeInheritsNoGrants;
var
  Base, Appr, Global: string;
  A: TJson;
  Out_: string;
  IsErr: Boolean;
  Saved: string;
begin
  uTools.ClearDenyRules;
  uTools.ClearBashPrefixes;
  uTools.ClearTrust;
  uTools.AllowAllEdits := False;
  uTools.AllowAllBash := False;
  uTools.RootDir := SessionDir;

  Saved := SysUtils.GetEnvironmentVariable('LOCALAPPDATA');
  Base := ExcludeTrailingPathDelimiter(SessionDir) + '-appdata';
  ForceDirectories(Base);
  try
    SetEnvironmentVariable('LOCALAPPDATA', PChar(Base));
    Appr := uTools.ApprovalsPath;
    Global := uTools.GlobalDenyPath;
    ForceDirectories(ExtractFileDir(Appr));
    ForceDirectories(ExtractFileDir(Global));
    with TStringList.Create do
    try
      Text := '{"allow_bash":true,"bash_programs":["git"],' +
        '"trusted":{"hooks.json":"deadbeefdeadbeef"},"deny":["tool:fetch"]}';
      SaveToFile(Appr);
      Text := '{"deny":["tool:search"]}';
      SaveToFile(Global);
    finally
      Free;
    end;

    { Exactly the call print mode makes, and nothing else. }
    uTools.LoadDenyRules(Appr, Global);
    Check(uTools.DenyRuleCount = 2, 'both files'' deny rules arrive');
    Check(not uTools.AllowAllBash, 'and allow_bash beside them does not');
    Check(not uTools.AllowAllEdits, 'nor allow_edits');
    Check(not uTools.BashPrefixAllowed('git status'),
      'nor a persisted bash program');
    Check(uTools.TrustedFingerprint('hooks.json') = '',
      'nor a trusted fingerprint');

    { With Ask nil - print mode's other half - a denied tool says why, and an
      ordinary read still works. }
    A := TJson.NewObj;
    A.AddStr('url', 'https://example.com/');
    Out_ := uTools.RunTool('fetch', A, nil, IsErr);
    A.Free;
    Check(IsErr and (Pos('refused by deny rule', Out_) > 0),
      'a denied tool is refused under -p: ' + Out_);
    A := TJson.NewObj;
    A.AddStr('pattern', 'nothing-in-particular');
    Out_ := uTools.RunTool('search', A, nil, IsErr);
    A.Free;
    Check(IsErr and (Pos('refused by deny rule', Out_) > 0),
      'including a tool that is otherwise ungated');
    WriteSessionFile('plain.txt', 'ordinary');
    A := TJson.NewObj;
    A.AddStr('path', 'plain.txt');
    Out_ := uTools.RunTool('read_file', A, nil, IsErr);
    A.Free;
    Check(not IsErr, 'while an ungated, undenied tool still runs');
  finally
    SetEnvironmentVariable('LOCALAPPDATA', PChar(Saved));
    uTools.ClearDenyRules;
  end;
end;

{ Conversation state has to persist across separate turns. }
procedure TestConversationPersists;
var
  A: TAgent;
  Err: string;
  Doc: TJson;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  SetLength(Replies, 2);
  Replies[0] := TextReply('First answer.');
  Replies[1] := TextReply('Second answer.');

  A := MakeAgent;
  try
    A.Send('first question', Err);
    A.Send('second question', Err);
    Check(A.TurnCount = 2, 'two turns are counted');

    Doc := JsonParse(Requests[1]);
    try
      Check(Doc.Find('messages').Count = 3,
        'the second turn carries the first exchange');
      Check(Doc.Find('messages').Item(0).Find('content').Item(0).Str('text') =
        'first question', 'the earlier question is still present');
    finally
      Doc.Free;
    end;

    { /clear must actually drop it. }
    A.Reset;
    ResetScript;
    SetLength(Replies, 1);
    Replies[0] := TextReply('Fresh.');
    A.Send('new question', Err);
    Doc := JsonParse(Requests[0]);
    try
      Check(Doc.Find('messages').Count = 1, 'a reset clears the transcript');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;
end;

{ A model that produces two tool calls in one message must have both run and
  both answered in a single result message. }
{ Everything about persistence is tested offline against the loader's own
  rules, which risks proving only that the loader agrees with itself.  This
  drives a resumed conversation through the real Send path instead: the
  transcript is saved, reloaded into a fresh agent, and that agent then runs a
  full request-tool-respond cycle.  What matters is the request body it builds
  from restored history, since that is the thing the API would accept or
  reject. }
procedure TestResumedSessionRunsThroughTheLoop;
var
  A: TAgent;
  Err, Path: string;
  Doc, Msgs: TJson;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  uTools.AllowAllEdits := True;
  WriteSessionFile('resumed.txt', 'contents of the resumed file');
  Path := IncludeTrailingPathDelimiter(SessionDir) + 'saved-session.json';

  { A conversation that got as far as running a tool, then stopped. }
  SetLength(Replies, 2);
  Replies[0] := ToolReply('call_r1', 'read_file', '{"path":"resumed.txt"}');
  Replies[1] := TextReply('I read it.');
  A := MakeAgent;
  try
    A.Send('read that file', Err);
    Check(A.SaveSession(Path, Err), 'the finished exchange saves');
  finally
    A.Free;
  end;

  { A brand new agent, as if the program had been restarted. }
  ResetScript;
  SetLength(Replies, 2);
  Replies[0] := ToolReply('call_r2', 'read_file', '{"path":"resumed.txt"}');
  Replies[1] := TextReply('Read it again.');
  A := MakeAgent;
  try
    Check(A.LoadSession(Path, Err), 'it resumes into a fresh agent: ' + Err);
    Check(A.Send('now read it again', Err),
      'a resumed conversation completes a full turn: ' + Err);
    Check(Pos('Read it again.', Prose) > 0, 'the answer is delivered');
    Check(Pos('read resumed.txt', ToolLog) > 0, 'the tool ran in the resumed turn');

    { The first request of the resumed turn is the one built entirely from
      restored history plus the new question.  Its shape is what the API
      would have judged. }
    Doc := JsonParse(Requests[0]);
    try
      Msgs := Doc.Find('messages');
      { question, tool_use, tool_result, answer, new question }
      Check(Msgs.Count = 5, Format('restored history is sent back, got %d',
        [Msgs.Count]));
      Check(Msgs.Item(0).Str('role') = 'user', 'it opens with a user turn');
      Check(Msgs.Item(0).Find('content').Item(0).Str('text') = 'read that file',
        'the original question survived the round trip');
      Check(Msgs.Item(1).Find('content').Item(0).Str('type') = 'tool_use',
        'the tool call survived');
      Check(Msgs.Item(1).Find('content').Item(0).Str('id') = 'call_r1',
        'with its id, which is what ties it to the result');
      Check(Msgs.Item(2).Find('content').Item(0).Str('tool_use_id') = 'call_r1',
        'and the result still answers that exact call');
      { The restored tool input must be an object, not the raw JSON string it
        was accumulated from - a string here is silently accepted by the
        loader but is not what the API expects. }
      Check(Msgs.Item(1).Find('content').Item(0).Find('input').Kind = jkObj,
        'the restored tool input is a JSON object, not a string');
      Check(Msgs.Item(4).Find('content').Item(0).Str('text') = 'now read it again',
        'the new question is appended last');
    finally
      Doc.Free;
    end;

    { And the whole thing must still be saveable and loadable afterwards, so a
      resumed session can be resumed again. }
    Check(A.SaveSession(Path, Err), 'the continued conversation saves again');
  finally
    A.Free;
  end;

  A := MakeAgent;
  try
    Check(A.LoadSession(Path, Err), 'and resumes a second time: ' + Err);
    Check(A.MessageCount = 8, Format('carrying both exchanges, got %d',
      [A.MessageCount]));
  finally
    A.Free;
  end;
end;

procedure TestParallelToolCalls;
var
  A: TAgent;
  Err: string;
  Doc, Content: TJson;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  uTools.AllowAllEdits := True;
  WriteSessionFile('one.txt', 'first file');
  WriteSessionFile('two.txt', 'second file');

  SetLength(Replies, 2);
  Replies[0] :=
    Ev('{"type":"content_block_start","index":0,"content_block":' +
       '{"type":"tool_use","id":"a1","name":"read_file"}}') +
    Ev('{"type":"content_block_delta","index":0,"delta":' +
       '{"type":"input_json_delta","partial_json":"{\"path\":\"one.txt\"}"}}') +
    Ev('{"type":"content_block_start","index":1,"content_block":' +
       '{"type":"tool_use","id":"a2","name":"read_file"}}') +
    Ev('{"type":"content_block_delta","index":1,"delta":' +
       '{"type":"input_json_delta","partial_json":"{\"path\":\"two.txt\"}"}}') +
    Ev('{"type":"message_delta","delta":{"stop_reason":"tool_use"}}');
  Replies[1] := TextReply('Read both.');

  A := MakeAgent;
  try
    A.Send('read both files', Err);
    Check(CallCount = 2, 'parallel tool calls resolve in one round');
    Doc := JsonParse(Requests[1]);
    try
      Content := Doc.Find('messages').Item(2).Find('content');
      Check(Content.Count = 2, 'both calls are answered in one result message');
      Check(Content.Item(0).Str('tool_use_id') = 'a1', 'the first id matches');
      Check(Content.Item(1).Str('tool_use_id') = 'a2', 'the second id matches');
      Check(Pos('first file', Content.Item(0).Str('content')) > 0,
        'the first tool really ran');
      Check(Pos('second file', Content.Item(1).Str('content')) > 0,
        'the second tool really ran');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;
end;

{ Cancellation: the user presses Esc while a reply streams. }
function WantsCancel: Boolean;
begin
  Result := (CancelAfterChunks >= 0) and (ChunksSeen >= CancelAfterChunks);
end;

procedure TestCancelMidStream;
var
  A: TAgent;
  Err: string;
  Ok: Boolean;
  Doc, Msgs: TJson;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  SetLength(Replies, 2);
  { 40 separate deltas, so the cancel can land between them. }
  Replies[0] := LongTextReply('chunk ', 40);
  Replies[1] := TextReply('second turn works');

  A := MakeAgent;
  try
    A.ShouldCancel := @WantsCancel;
    ChunksSeen := 0;
    { The opening events take roughly 23 chunks at 9 bytes each, and each
      delta about 12 more, so this lands a few deltas into the text. }
    CancelAfterChunks := 60;

    Ok := A.Send('say a lot', Err);
    Check(Ok, 'a cancelled turn is not an error');
    Check(Pos('cancelled', Notices) > 0, 'the user is told it was cancelled');
    Check(Length(Prose) < 40 * 6, 'the reply stopped early');
    Check(Length(Prose) > 0, 'what arrived before the stop was shown');

    { The partial reply has to stay in the transcript, or the next turn would
      look like the model never answered. }
    Doc := JsonParse(A.Transcript);
    try
      Msgs := Doc;
      Check(Msgs.Count = 2, 'the partial reply is kept in the transcript');
      Check(Msgs.Item(1).Str('role') = 'assistant', 'it is recorded as the assistant');
    finally
      Doc.Free;
    end;

    { And the conversation must still work afterwards. }
    CancelAfterChunks := -1;
    Prose := '';
    Ok := A.Send('carry on', Err);
    Check(Ok and (Prose = 'second turn works'),
      'the conversation continues after a cancellation');
  finally
    A.Free;
  end;
  CancelAfterChunks := -1;
end;

{ Cancelling while the model is mid-tool-call leaves an unanswered tool_use,
  which the API rejects.  Those blocks must be stripped. }
{ Cancelling before the model has said anything leaves the question in the
  transcript with nothing answering it - the same shape a failed turn produces,
  reached by a different route.  A cancel is not an error, so the caller's
  failure path does not run, which is exactly why this needs its own check:
  the conversation is then saved after every turn, cancelled or not. }
procedure TestCancelBeforeAnyContent;
var
  A: TAgent;
  Err, Path: string;
  Ok: Boolean;
  Doc: TJson;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  Path := IncludeTrailingPathDelimiter(SessionDir) + 'cancelled-session.json';
  SetLength(Replies, 1);
  Replies[0] := LongTextReply('chunk ', 40);

  A := MakeAgent;
  try
    A.ShouldCancel := @WantsCancel;
    ChunksSeen := 0;
    { Cancel almost immediately, before any text delta has been decoded. }
    CancelAfterChunks := 1;

    Ok := A.Send('a question nobody answers', Err);
    Check(Ok, 'an early cancellation is still not an error');
    Check(Prose = '', 'nothing was streamed before the stop');

    { This is the assertion that matters.  Whatever is left has to be a
      conversation that can be saved, resumed and continued. }
    Check(A.SaveSession(Path, Err), 'the cancelled turn saves: ' + Err);
    Doc := JsonParse(A.Transcript);
    try
      if Doc.Count > 0 then
        Check(Doc.Item(Doc.Count - 1).Str('role') <> 'user',
          'a cancelled turn does not leave the transcript ending on a question')
      else
        Check(True, 'the cancelled turn left nothing behind, which is fine');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;

  { And it must reload, because autosave already wrote it. }
  A := MakeAgent;
  try
    Check(A.LoadSession(Path, Err),
      'a session saved after a cancelled turn reloads: ' + Err);
  finally
    A.Free;
  end;
end;

procedure TestCancelDuringToolCallCleansTranscript;
var
  A: TAgent;
  Err: string;
  Doc, Msgs, Content: TJson;
  I, J: Integer;
  SawToolUse: Boolean;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  SetLength(Replies, 2);
  { The tool call completes, then a long tail of text keeps the stream open
    so the cancel arrives with a finished tool_use already in hand - which is
    the state that would otherwise poison the next request. }
  Replies[0] := ToolReply('t9', 'read_file', '{"path":"note.txt"}') +
    StringOfChar(' ', 0);
  for I := 1 to 40 do
    Replies[0] := Replies[0] +
      Ev('{"type":"content_block_delta","index":1,"delta":' +
         '{"type":"text_delta","text":"tail "}}');
  Replies[1] := TextReply('after cancel');

  A := MakeAgent;
  try
    A.ShouldCancel := @WantsCancel;
    ChunksSeen := 0;
    { Past the tool_use block, into the trailing text. }
    CancelAfterChunks := 60;

    A.Send('read something', Err);
    Check(ToolLog = '', 'a cancelled tool call is never executed');

    Doc := JsonParse(A.Transcript);
    try
      SawToolUse := False;
      Msgs := Doc;
      for I := 0 to Msgs.Count - 1 do
      begin
        Content := Msgs.Item(I).Find('content');
        if Content = nil then Continue;
        for J := 0 to Content.Count - 1 do
          if Content.Item(J).Str('type') = 'tool_use' then SawToolUse := True;
      end;
      Check(not SawToolUse,
        'no unanswered tool_use is left in the transcript');
    finally
      Doc.Free;
    end;

    { Proof it stayed usable: the next turn must go through. }
    CancelAfterChunks := -1;
    Prose := '';
    A.Send('never mind', Err);
    Check(Prose = 'after cancel', 'the next turn succeeds after the cleanup');
  finally
    A.Free;
  end;
  CancelAfterChunks := -1;
end;

{ Transient failures must be retried, permanent ones must not. }
procedure TestRetryOnOverload;
var
  A: TAgent;
  Err: string;
  Ok: Boolean;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  { The transport fails the first two calls, then the script answers. }
  SetLength(Replies, 3);
  Replies[0] := TextReply('unused');
  Replies[1] := TextReply('unused');
  Replies[2] := TextReply('recovered');
  FailAfter := 0;
  FailUntil := 2;

  A := MakeAgent;
  try
    Ok := A.Send('hello', Err);
    Check(Ok, 'a turn survives transient failures: ' + Err);
    Check(CallCount = 3, 'the request was retried twice');
    Check(Prose = 'recovered', 'the eventual reply is delivered');
    Check(Pos('retrying', Notices) > 0, 'the user is told a retry is happening');
  finally
    A.Free;
  end;
end;

procedure TestNoRetryOnPermanentError;
var
  A: TAgent;
  Err: string;
  Ok: Boolean;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  SetLength(Replies, 1);
  Replies[0] := TextReply('unused');
  FailAfter := 0;
  FailUntil := 99;
  FailStatus := 400;
  FailBody := '{"error":{"type":"invalid_request_error","message":"bad"}}';

  A := MakeAgent;
  try
    Ok := A.Send('hello', Err);
    Check(not Ok, 'a permanent error fails the turn');
    Check(CallCount = 1, 'a 400 is not retried');
    Check(Pos('invalid_request_error', Err) > 0, 'the reason is reported');
  finally
    A.Free;
  end;
end;

procedure TestRetriesGiveUp;
var
  A: TAgent;
  Err: string;
  Ok: Boolean;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  SetLength(Replies, 1);
  Replies[0] := TextReply('unused');
  FailAfter := 0;
  FailUntil := 99;

  A := MakeAgent;
  try
    Ok := A.Send('hello', Err);
    Check(not Ok, 'persistent failure eventually fails the turn');
    Check(CallCount = MaxRetries + 1,
      Format('it tried %d times then stopped, got %d',
        [MaxRetries + 1, CallCount]));
  finally
    A.Free;
  end;
end;

{ A 429 that names its own wait should be waited out as told, not guessed
  at.  The notice line reports the wait actually used, which is how the
  choice is observable without measuring wall-clock time. }
procedure TestRetryHonorsRetryAfter;
var
  A: TAgent;
  Err: string;
  Ok: Boolean;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  SetLength(Replies, 2);
  Replies[0] := TextReply('unused');
  Replies[1] := TextReply('recovered');
  FailAfter := 0;
  FailUntil := 1;
  FailStatus := 429;
  FakeRetryAfterMs := 7;

  A := MakeAgent;
  try
    Ok := A.Send('hello', Err);
    Check(Ok, 'the turn recovers after the named wait: ' + Err);
    Check(Pos('retrying in 7ms', Notices) > 0,
      'the server''s Retry-After was used instead of the default backoff, got: '
      + Notices);
  finally
    A.Free;
  end;
end;

{ Without a Retry-After the default widening backoff still applies. }
procedure TestRetryDefaultBackoffWithoutHeader;
var
  A: TAgent;
  Err: string;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  SetLength(Replies, 2);
  Replies[0] := TextReply('unused');
  Replies[1] := TextReply('recovered');
  FailAfter := 0;
  FailUntil := 1;

  A := MakeAgent;
  try
    A.Send('hello', Err);
    Check(Pos(Format('retrying in %dms', [uAgent.RetryBaseMs]), Notices) > 0,
      'no header means the default backoff, got: ' + Notices);
  finally
    A.Free;
  end;
end;

{ Summary compaction: the transcript becomes one exchange carrying the
  model's summary, and a later turn works from it. }
procedure TestCompactWithSummary;
var
  A: TAgent;
  Err: string;
  Ok: Boolean;
  Doc, Msgs: TJson;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  SetLength(Replies, 3);
  Replies[0] := TextReply('First answer.');
  Replies[1] := TextReply('We discussed the answer 42 and edited note.txt.');
  Replies[2] := TextReply('Continuing from the summary.');

  A := MakeAgent;
  try
    A.Send('what is the answer?', Err);
    Check(A.MessageCount = 2, 'two messages before compaction');

    Ok := A.CompactWithSummary(Err);
    Check(Ok, 'summary compaction succeeds: ' + Err);
    Check(A.MessageCount = 2, 'the compacted transcript is one exchange');
    Check(Pos('42 and edited note.txt', A.Transcript) > 0,
      'the summary text is in the new transcript');
    Check(Pos('what is the answer?', A.Transcript) = 0,
      'the original turns are gone');

    { The transcript must still be legal: a follow-up turn sends fine and
      opens with the summary user message. }
    Ok := A.Send('go on', Err);
    Check(Ok, 'a turn after summary compaction works: ' + Err);
    Doc := JsonParse(Requests[High(Requests)]);
    try
      Msgs := Doc.Find('messages');
      Check(Msgs.Item(0).Str('role') = 'user',
        'the compacted transcript opens with a user message');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;
end;

{ A summary request that fails must leave the conversation exactly as it
  was - this is the mutation a suite is most likely to miss, because every
  assertion about the failure itself still passes. }
procedure TestCompactWithSummaryFailureRestores;
var
  A: TAgent;
  Err, Before: string;
  Ok: Boolean;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  SetLength(Replies, 1);
  Replies[0] := TextReply('First answer.');

  A := MakeAgent;
  try
    A.Send('question one', Err);
    Before := A.Transcript;

    FailAfter := 1;
    FailUntil := 99;
    FailStatus := 400;
    FailBody := '{"error":{"type":"invalid_request_error","message":"nope"}}';
    Ok := A.CompactWithSummary(Err);
    Check(not Ok, 'a failed summary request reports failure');
    Check(A.Transcript = Before,
      'the conversation survives a failed summary byte for byte');
  finally
    A.Free;
  end;
end;

{ An empty summary - the model answered with nothing usable - is a refusal,
  not a replacement. }
procedure TestCompactWithSummaryEmptyRestores;
var
  A: TAgent;
  Err, Before: string;
  Ok: Boolean;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  SetLength(Replies, 2);
  Replies[0] := TextReply('First answer.');
  Replies[1] := TextReply('   ');

  A := MakeAgent;
  try
    A.Send('question one', Err);
    Before := A.Transcript;
    Ok := A.CompactWithSummary(Err);
    Check(not Ok, 'an empty summary is refused');
    Check(A.Transcript = Before, 'and the conversation is untouched');
  finally
    A.Free;
  end;
end;

{ The streaming display hooks: the tool name fires when its block opens,
  and the argument JSON streams through in fragments. }
procedure TestToolUseStreamingHooks;
var
  A: TAgent;
  Err: string;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  uTools.AllowAllEdits := True;
  WriteSessionFile('note.txt', 'the answer is 42');
  SetLength(Replies, 2);
  Replies[0] := ToolReply('t1', 'read_file', '{"path":"note.txt"}');
  Replies[1] := TextReply('Done.');

  A := MakeAgent;
  A.OnToolUseBegin := @CapToolBegin;
  A.OnToolArg := @CapToolArg;
  try
    A.Send('read it', Err);
    Check(ToolBegins = 'read_file;',
      'the tool name was announced when its block opened, got: ' + ToolBegins);
    Check(ToolArgs = '{"path":"note.txt"}',
      'the argument JSON streamed through the hook, got: ' + ToolArgs);
  finally
    A.Free;
  end;
end;

{ ContextTokens is the API's own count of the last prompt, which is what
  the token-aware compaction trigger reads. }
procedure TestContextTokens;
var
  A: TAgent;
  Err: string;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  SetLength(Replies, 1);
  Replies[0] := TextReply('hi');

  A := MakeAgent;
  try
    Check(A.ContextTokens = 0, 'context tokens start at zero');
    A.Send('hello', Err);
    Check(A.ContextTokens = 10,
      Format('context tokens reflect the last prompt, got %d',
        [A.ContextTokens]));
  finally
    A.Free;
  end;
end;

{ The thinking budget's effect on the request: a thinking block with the
  budget, and max_tokens raised so the reply is not starved by the think. }
procedure TestThinkingBudgetInRequest;
var
  A: TAgent;
  Doc, Th: TJson;
  BaseMax, RaisedMax: Integer;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  A := MakeAgent;
  try
    A.AppendUserText('q');

    Doc := JsonParse(A.RequestBody);
    try
      Check(Doc.Find('thinking') = nil, 'no thinking block by default');
      BaseMax := Round(Doc.Num('max_tokens'));
    finally
      Doc.Free;
    end;

    A.ThinkingBudget := 2048;
    Doc := JsonParse(A.RequestBody);
    try
      Th := Doc.Find('thinking');
      Check(Th <> nil, 'the thinking block is present when a budget is set');
      Check((Th <> nil) and (Th.Str('type') = 'enabled'), 'typed enabled');
      Check((Th <> nil) and (Round(Th.Num('budget_tokens')) = 2048),
        'with the budget');
      RaisedMax := Round(Doc.Num('max_tokens'));
      Check(RaisedMax = BaseMax + 2048,
        Format('max_tokens grows by the budget: %d -> %d', [BaseMax, RaisedMax]));
    finally
      Doc.Free;
    end;

    A.ThinkingBudget := 0;
    Doc := JsonParse(A.RequestBody);
    try
      Check(Doc.Find('thinking') = nil, 'turning it off removes the block');
      Check(Round(Doc.Num('max_tokens')) = BaseMax, 'and max_tokens falls back');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;
end;

{ A subscription OAuth token changes how a request authenticates and what
  its system prompt opens with; everything else must stay identical. }
procedure TestOauthRequestShape;
var
  A: TAgent;
  Err: string;
  Doc, Sys: TJson;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  SetLength(Replies, 1);
  Replies[0] := TextReply('hi');

  A := TAgent.Create('sk-ant-oat01-fake-token', 'm', 'sys prompt');
  A.OnText := @CapText;
  try
    A.Send('hello', Err);
    Check(Pos('authorization: Bearer sk-ant-oat01-fake-token',
      ReqHeaders[0]) > 0, 'an OAuth token rides the Bearer header');
    Check(Pos('x-api-key', ReqHeaders[0]) = 0,
      'and not the x-api-key header');
    Check(Pos('anthropic-beta: oauth', ReqHeaders[0]) > 0,
      'with the oauth beta flag');

    Doc := JsonParse(Requests[0]);
    try
      Sys := Doc.Find('system');
      Check((Sys <> nil) and (Sys.Count = 2),
        'the system prompt has two blocks under OAuth');
      Check((Sys <> nil) and (Sys.Count = 2) and
        (Pos('Claude Code', Sys.Item(0).Str('text')) > 0),
        'the first is the identity line the API requires');
      Check((Sys <> nil) and (Sys.Count = 2) and
        (Sys.Item(1).Str('text') = 'sys prompt'),
        'ours follows unchanged');
      Check((Sys <> nil) and (Sys.Count = 2) and
        (Sys.Item(1).Find('cache_control') <> nil),
        'and still carries the cache breakpoint');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;

  { An ordinary key is untouched by any of this. }
  ResetScript;
  SetLength(Replies, 1);
  Replies[0] := TextReply('hi');
  A := MakeAgent;
  try
    A.Send('hello', Err);
    Check(Pos('x-api-key: k', ReqHeaders[0]) > 0,
      'an API key still rides x-api-key');
    Check(Pos('authorization', ReqHeaders[0]) = 0,
      'with no Bearer header');
    Doc := JsonParse(Requests[0]);
    try
      Sys := Doc.Find('system');
      Check((Sys <> nil) and (Sys.Count = 1),
        'and a single system block, as before');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;
end;

{ Web search is a server-side tool: pasclaude declares it and the API runs it.
  Declaring it is therefore the whole of the user's consent, so it must be
  absent from the body unless the session asked for it. }
procedure TestWebSearchDeclaration;
var
  A: TAgent;
  Doc, Tools: TJson;
  I, Local, Web: Integer;
begin
  ResetScript;
  A := MakeAgent;
  try
    A.AppendUserText('hello');

    Doc := JsonParse(A.RequestBody);
    try
      Tools := Doc.Find('tools');
      Local := 0;
      Web := 0;
      for I := 0 to Tools.Count - 1 do
        if Tools.Item(I).Str('name') = 'web_search' then Inc(Web);
      { Source-contributed tools are excluded by name, so configuring an MCP
        server can never move a number that lives in this file. }
      Local := uTools.CountBuiltinTools(Tools) - Web;
      Check(Web = 0, 'web search is not declared by default');
      Check(Local = uTools.BuiltinToolCount,
        Format('the local tools are all declared (%d)', [Local]));
      { The count above holds only because this suite's root has no skills
        directory, and a count that is right by luck is a count that breaks
        somewhere unrelated.  Anchored by name, the reason is visible. }
      Check(Pos('"skill"', Doc.ToJson) = 0,
        'and no skill tool is declared in a project that has no skills');
    finally
      Doc.Free;
    end;

    A.WebSearch := True;
    Doc := JsonParse(A.RequestBody);
    try
      Tools := Doc.Find('tools');
      Local := 0;
      Web := 0;
      for I := 0 to Tools.Count - 1 do
        if Tools.Item(I).Str('name') = 'web_search' then
        begin
          Inc(Web);
          Check(Tools.Item(I).Str('type') = uTools.WebSearchToolType,
            'the declaration carries the dated type string');
          Check(Tools.Item(I).Find('input_schema') = nil,
            'a server-side tool declares no input schema');
        end;
      Local := uTools.CountBuiltinTools(Tools) - Web;
      Check(Web = 1, 'web search is declared exactly once when it is on');
      Check(Local = uTools.BuiltinToolCount,
        'the local tools are still all declared');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;
end;

{ A turn that stops with pause_turn is not finished: the server-side tool loop
  hit its own iteration cap and the documented resume is to send again with the
  assistant turn appended.  Treating it as an ending truncates the answer. }
procedure TestPauseTurnResumes;
var
  A: TAgent;
  Err: string;
  Doc: TJson;
  I: Integer;
  TwoUsers: Boolean;
begin
  ResetScript;
  SetLength(Replies, 2);
  Replies[0] :=
    Ev('{"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":1}}}') +
    Ev('{"type":"content_block_start","index":0,"content_block":' +
       '{"type":"server_tool_use","id":"srv1","name":"web_search"}}') +
    Ev('{"type":"content_block_delta","index":0,"delta":' +
       '{"type":"input_json_delta","partial_json":"{\"query\":\"x\"}"}}') +
    Ev('{"type":"content_block_start","index":1,"content_block":' +
       '{"type":"web_search_tool_result","tool_use_id":"srv1","content":[]}}') +
    Ev('{"type":"message_delta","delta":{"stop_reason":"pause_turn"},"usage":{"output_tokens":9}}');
  Replies[1] := TextReply('here is what I found');

  A := MakeAgent;
  try
    A.WebSearch := True;
    Check(A.Send('look it up', Err), 'a paused turn completes: ' + Err);
    Check(CallCount = 2, Format('the paused turn is resumed with a second request (%d)',
      [CallCount]));
    Check(Prose = 'here is what I found', 'the resumed turn produces the reply');

    Doc := JsonParse(A.Transcript);
    try
      TwoUsers := False;
      for I := 1 to Doc.Count - 1 do
        if (Doc.Item(I).Str('role') = 'user') and
           (Doc.Item(I - 1).Str('role') = 'user') then TwoUsers := True;
      Check(not TwoUsers, 'the resumed transcript alternates legally');
      Check(Doc.Item(Doc.Count - 1).Str('role') = 'assistant',
        'the turn ends on the assistant');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;
end;

{ Whether this key and this model will accept the web search declaration is
  something only the server knows.  A rejection must cost one request, not the
  session: the tool is dropped and the same round is sent again. }
procedure TestWebSearchRejectionSelfHeals;
var
  A: TAgent;
  Err: string;
  Doc, Tools: TJson;
  I: Integer;
  SawWeb: Boolean;
begin
  ResetScript;
  SetLength(Replies, 2);
  Replies[0] := TextReply('unused');
  Replies[1] := TextReply('answered anyway');
  { Call one is refused by name; call two goes through. }
  FailAfter := 0;
  FailUntil := 1;
  FailStatus := 400;
  FailBody := '{"type":"error","error":{"type":"invalid_request_error",' +
              '"message":"tools.11: unexpected tool type web_search"}}';

  A := MakeAgent;
  try
    A.WebSearch := True;
    Check(A.Send('search please', Err), 'the turn survives a rejected declaration: ' + Err);
    Check(CallCount = 2, Format('exactly one request was wasted (%d)', [CallCount]));
    Check(not A.WebSearch, 'web search is off after the rejection');
    Check(Pos('web search', Notices) > 0, 'a notice names web search: ' + Notices);
    Check(Prose = 'answered anyway', 'the retried round produces the reply');

    Doc := JsonParse(Requests[1]);
    try
      Tools := Doc.Find('tools');
      SawWeb := False;
      for I := 0 to Tools.Count - 1 do
        if Tools.Item(I).Str('name') = 'web_search' then SawWeb := True;
      Check(not SawWeb, 'the retried body no longer carries the tool');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;
  ResetScript;
end;

{ A server-side call and its result are two blocks of one assistant message,
  so a cancel can land between them.  The API rejects a server_tool_use with
  no result just as firmly as an unanswered tool_use - but a completed pair
  must survive, or the search is lost from the conversation. }
procedure TestCancelDropsDanglingServerToolUse;

  function TranscriptHas(A: TAgent; const BlockType: string): Boolean;
  var
    Doc, Content: TJson;
    I, J: Integer;
  begin
    Result := False;
    Doc := JsonParse(A.Transcript);
    try
      for I := 0 to Doc.Count - 1 do
      begin
        Content := Doc.Item(I).Find('content');
        if Content = nil then Continue;
        for J := 0 to Content.Count - 1 do
          if Content.Item(J).Str('type') = BlockType then Result := True;
      end;
    finally
      Doc.Free;
    end;
  end;

var
  A: TAgent;
  Err, Head, Tail: string;
  I: Integer;
begin
  Head :=
    Ev('{"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":1}}}') +
    Ev('{"type":"content_block_start","index":0,"content_block":' +
       '{"type":"server_tool_use","id":"srv1","name":"web_search"}}') +
    Ev('{"type":"content_block_delta","index":0,"delta":' +
       '{"type":"input_json_delta","partial_json":"{\"query\":\"x\"}"}}');
  Tail := '';
  for I := 1 to 40 do
    Tail := Tail + Ev('{"type":"content_block_delta","index":2,"delta":' +
                      '{"type":"text_delta","text":"tail "}}');

  { The cancel lands after the call block but before any result. }
  ResetScript;
  SetLength(Replies, 1);
  Replies[0] := Head +
    Ev('{"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}') +
    Tail;
  A := MakeAgent;
  try
    A.WebSearch := True;
    A.ShouldCancel := @WantsCancel;
    ChunksSeen := 0;
    CancelAfterChunks := 60;
    A.Send('look it up', Err);
    Check(not TranscriptHas(A, 'server_tool_use'),
      'a server call with no result is dropped from the transcript');
  finally
    A.Free;
  end;
  CancelAfterChunks := -1;

  { The same cancel with the result already in hand must keep both. }
  ResetScript;
  SetLength(Replies, 1);
  Replies[0] := Head +
    Ev('{"type":"content_block_start","index":1,"content_block":' +
       '{"type":"web_search_tool_result","tool_use_id":"srv1","content":[]}}') +
    Ev('{"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}') +
    Tail;
  A := MakeAgent;
  try
    A.WebSearch := True;
    A.ShouldCancel := @WantsCancel;
    ChunksSeen := 0;
    CancelAfterChunks := 90;
    A.Send('look it up', Err);
    Check(TranscriptHas(A, 'server_tool_use'),
      'an answered server call survives the cancel');
    Check(TranscriptHas(A, 'web_search_tool_result'),
      'and its result survives with it');
  finally
    A.Free;
  end;
  CancelAfterChunks := -1;
end;

{ ------------------------------------------------------------- subagents -- }

{ A reply with usage numbers the caller chooses, so a subagent's spending can
  be told apart from its parent's. }
function UsageTextReply(const Text: string;
  InTok, OutTok, CacheRead: Integer): string;
begin
  Result :=
    Ev(Format('{"type":"message_start","message":{"usage":{"input_tokens":%d,' +
      '"output_tokens":1,"cache_read_input_tokens":%d}}}', [InTok, CacheRead])) +
    Ev('{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}') +
    Ev('{"type":"content_block_delta","index":0,"delta":' +
       '{"type":"text_delta","text":' + JsonQuote(Text) + '}}') +
    Ev(Format('{"type":"message_delta","delta":{"stop_reason":"end_turn"},' +
      '"usage":{"output_tokens":%d}}', [OutTok]));
end;

function AgentsDirPath: string;
begin
  Result := IncludeTrailingPathDelimiter(SessionDir) + '.pasclaude' +
    PathDelim + 'agents' + PathDelim;
  ForceDirectories(Result);
end;

{ The whole shape of the feature in one exchange: the model asks for a task,
  a second agent with its own transcript answers it, and only that answer
  comes back. }
procedure TestSubagent;
var
  A: TAgent;
  Err, Sys: string;
  Ok: Boolean;
  Doc, Tools, Msgs, C: TJson;
  I, Local: Integer;
  SawRead, SawList, SawSearch, SawTask: Boolean;
begin
  ResetScript;
  uTools.RootDir := SessionDir;

  SetLength(Replies, 3);
  Replies[0] := ToolReply('t1', 'task', '{"prompt":"count the units"}');
  Replies[1] := TextReply('there are six units');
  Replies[2] := TextReply('done');

  A := MakeAgent;
  try
    Ok := A.Send('how many units are there?', Err);
    Check(Ok, 'a turn with a subagent completes: ' + Err);
    Check(CallCount = 3,
      Format('three requests: parent, subagent, parent (%d)', [CallCount]));
    Check(Pos('task: count the units', ToolLog) > 0,
      'the task shows in the transcript by its prompt: ' + ToolLog);

    { What the subagent was actually sent. }
    Doc := JsonParse(Requests[1]);
    try
      Tools := Doc.Find('tools');
      Local := 0;
      SawRead := False; SawList := False; SawSearch := False; SawTask := False;
      for I := 0 to Tools.Count - 1 do
      begin
        Inc(Local);
        if Tools.Item(I).Str('name') = 'read_file' then SawRead := True;
        if Tools.Item(I).Str('name') = 'list_dir' then SawList := True;
        if Tools.Item(I).Str('name') = 'search' then SawSearch := True;
        if Tools.Item(I).Str('name') = 'task' then SawTask := True;
      end;
      Check(Local = 3,
        Format('the subagent is offered exactly three tools (%d)', [Local]));
      Check(SawRead and SawList and SawSearch,
        'and they are read_file, list_dir and search');
      Check(not SawTask, 'and task is not among them, so it cannot nest');

      Sys := Doc.Find('system').Item(0).Str('text');
      Check(Pos('read-only', Sys) > 0,
        'the subagent is told what it is: ' + Copy(Sys, 1, 60));
      Check(Pos('sys', Sys) = 0,
        'and it does not inherit the parent''s system prompt');

      Msgs := Doc.Find('messages');
      Check(Msgs.Count = 1, 'the subagent starts from an empty conversation');
      Check(Pos('count the units',
        Msgs.Item(0).Find('content').Item(0).Str('text')) > 0,
        'and is given the prompt it was called with');
    finally
      Doc.Free;
    end;

    { And what came back. }
    Doc := JsonParse(Requests[2]);
    try
      Msgs := Doc.Find('messages');
      C := Msgs.Item(Msgs.Count - 1).Find('content').Item(0);
      Check(C.Str('type') = 'tool_result', 'the parent got a tool result');
      Check(C.Str('content') = 'there are six units',
        'carrying the subagent''s final answer and nothing else: ' +
        C.Str('content'));
      Check(C.Find('is_error') = nil, 'and not marked as a failure');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;
end;

{ Agent definitions mirror custom slash commands: a directory of markdown
  files, the whole file being the briefing. }
procedure TestSubagentAgentType;
var
  A: TAgent;
  Err, Sys: string;
  Doc, Msgs, C: TJson;
  L: TStringList;
begin
  ResetScript;
  uTools.RootDir := SessionDir;

  L := TStringList.Create;
  try
    L.Text := 'You are a research subagent. Always cite file paths.';
    L.SaveToFile(AgentsDirPath + 'research.md');
  finally
    L.Free;
  end;

  SetLength(Replies, 3);
  Replies[0] := ToolReply('t1', 'task',
    '{"prompt":"find the parser","agent_type":"research"}');
  Replies[1] := TextReply('uJson.pas holds it');
  Replies[2] := TextReply('done');

  A := MakeAgent;
  try
    A.Send('where is the parser?', Err);
    Doc := JsonParse(Requests[1]);
    try
      Sys := Doc.Find('system').Item(0).Str('text');
      Check(Pos('Always cite file paths', Sys) > 0,
        'the named definition reaches the subagent''s system prompt');
      Check(Pos('read-only', Sys) > 0,
        'appended to the standing briefing rather than replacing it');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;

  { An unknown type must fail before any subagent request is made. }
  ResetScript;
  SetLength(Replies, 2);
  Replies[0] := ToolReply('t1', 'task',
    '{"prompt":"find the parser","agent_type":"nosuch"}');
  Replies[1] := TextReply('sorry');

  A := MakeAgent;
  try
    A.Send('where is the parser?', Err);
    Check(CallCount = 2,
      Format('a bad agent type costs no subagent request (%d)', [CallCount]));
    Doc := JsonParse(Requests[1]);
    try
      Msgs := Doc.Find('messages');
      C := Msgs.Item(Msgs.Count - 1).Find('content').Item(0);
      Check((C.Str('type') = 'tool_result') and
            (C.Find('is_error') <> nil) and C.Find('is_error').AsBoolean,
        'the model is told the call failed');
      Check(Pos('unknown agent type', C.Str('content')) > 0,
        'by name: ' + C.Str('content'));
      Check(Pos('research', C.Str('content')) > 0,
        'listing the definitions that do exist');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;
  DeleteFile(AgentsDirPath + 'research.md');
end;

{ A counter that omits the subagent is a counter that lies in exactly the
  direction the user would mind, and only the invoice would say so. }
procedure TestSubagentCost;
var
  A: TAgent;
  Err: string;
begin
  ResetScript;
  uTools.RootDir := SessionDir;

  { Parent: 10 in / 20 out.  Subagent: 111 in / 222 out / 33 cached.
    Parent again: 10 in / 30 out. }
  SetLength(Replies, 3);
  Replies[0] := ToolReply('t1', 'task', '{"prompt":"look"}');
  Replies[1] := UsageTextReply('the answer', 111, 222, 33);
  Replies[2] := TextReply('relaying it');

  A := MakeAgent;
  try
    A.Send('ask a helper', Err);
    Check(A.TokensIn = 10 + 111 + 10,
      Format('the subagent''s input tokens reach /cost (%d)', [A.TokensIn]));
    Check(A.TokensOut = 20 + 222 + 30,
      Format('and its output tokens (%d)', [A.TokensOut]));
    Check(A.CacheReadTokens = 33,
      Format('and its cache reads (%d)', [A.CacheReadTokens]));
  finally
    A.Free;
  end;
end;

{ Esc during a subagent must stop both agents.  The host's cancel flag is
  consume-on-read, so this stand-in is too: without the latch the subagent
  eats the abort and the parent carries on as though nothing happened. }
var
  OneShotArmed: Boolean = False;
  OneShotFired: Boolean = False;
  OneShotBase: Integer = 0;

function OneShotCancel: Boolean;
begin
  Result := False;
  if not OneShotArmed or OneShotFired then Exit;
  { Only once the subagent request is the one in flight: the parent request
    that asked for the task streams plenty of chunks of its own. }
  if CallCount < 2 then Exit;
  if OneShotBase = 0 then OneShotBase := ChunksSeen;
  if ChunksSeen < OneShotBase + 20 then Exit;
  OneShotFired := True;
  Result := True;
end;

procedure TestSubagentCancel;
var
  A: TAgent;
  Err: string;
  Ok: Boolean;
  Doc, M, Content: TJson;
  I, J: Integer;
  Dangling: Boolean;
begin
  ResetScript;
  uTools.RootDir := SessionDir;

  SetLength(Replies, 3);
  Replies[0] := ToolReply('t1', 'task', '{"prompt":"a long look"}');
  Replies[1] := LongTextReply('chunk ', 40);
  Replies[2] := TextReply('should never be reached');

  A := MakeAgent;
  try
    A.ShouldCancel := @OneShotCancel;
    ChunksSeen := 0;
    OneShotArmed := True;
    OneShotFired := False;
    OneShotBase := 0;

    Ok := A.Send('go and look', Err);
    Check(Ok, 'a cancelled subagent is not an error for the caller');
    Check(Pos('cancelled', Notices) > 0,
      'the user is told the turn was cancelled: ' + Notices);
    Check(CallCount = 2,
      Format('the parent did not send again after the abort (%d)', [CallCount]));

    Doc := JsonParse(A.Transcript);
    try
      Check((Doc.Count = 0) or
            (Doc.Item(Doc.Count - 1).Str('role') <> 'user'),
        'the transcript does not end on an unanswered user turn');
      Dangling := False;
      for I := 0 to Doc.Count - 1 do
      begin
        M := Doc.Item(I);
        if M.Str('role') <> 'assistant' then Continue;
        Content := M.Find('content');
        if Content = nil then Continue;
        for J := 0 to Content.Count - 1 do
          if Content.Item(J).Str('type') = 'tool_use' then
            if (I + 1 >= Doc.Count) or
               (Doc.Item(I + 1).Str('role') <> 'user') then
              Dangling := True;
      end;
      Check(not Dangling, 'and no tool call is left without a result');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
    OneShotArmed := False;
  end;
end;

{ A subagent gets a lower round ceiling than its parent: it is doing one job
  and nobody is watching it spend. }
procedure TestSubagentRoundCap;
var
  A: TAgent;
  Err: string;
  I: Integer;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  WriteSessionFile('note.txt', 'the answer is 42');

  SetLength(Replies, 14);
  Replies[0] := ToolReply('t1', 'task', '{"prompt":"read forever"}');
  for I := 1 to 12 do
    Replies[I] := ToolReply('s' + IntToStr(I), 'read_file', '{"path":"note.txt"}');
  Replies[13] := TextReply('the helper gave up');

  A := MakeAgent;
  try
    A.Send('delegate something endless', Err);
    Check(Pos('subagent: stopped after 12 tool rounds', Notices) > 0,
      'the subagent stops at its own ceiling: ' + Notices);
    Check(CallCount = 14,
      Format('one parent call, twelve subagent rounds, one parent call (%d)',
        [CallCount]));
  finally
    A.Free;
  end;

  { And the parent's own ceiling is untouched by the subagent's. }
  ResetScript;
  SetLength(Replies, 24);
  for I := 0 to 23 do
    Replies[I] := ToolReply('p' + IntToStr(I), 'read_file', '{"path":"note.txt"}');

  A := MakeAgent;
  try
    A.Send('read it over and over', Err);
    Check(Pos('stopped after 24 tool rounds', Notices) > 0,
      'while a runaway parent still gets 24: ' + Notices);
  finally
    A.Free;
  end;
end;

{ A whole turn against a real MCP server: the declaration reaches the request
  body through ToolsSchema, the model asks for the tool by its namespaced
  name, the dispatcher routes it back down the registry to uMcp, and the
  answer comes back as a tool_result.  The point of doing it end to end is
  the invariant uAgent.RunTools depends on - every tool_use gets a
  tool_result, including the ones that are refused. }
procedure TestMcpTurn;
var
  A: TAgent;
  Doc, Tools, Msgs, C: TJson;
  Exe, Err, Body, Hash: string;
  I, DeclAt, Local: Integer;
  NoArgs: array of string;
  SavedMcp, SavedEdits, Ok: Boolean;
begin
  Exe := ExtractFilePath(ParamStr(0)) + 'srvmock.exe';
  Check(FileExists(Exe), 'the stand-in MCP server binary was built');
  if not FileExists(Exe) then Exit;

  SavedMcp := uTools.AllowAllMcp;
  SavedEdits := uTools.AllowAllEdits;
  uTools.RootDir := SessionDir;
  uTools.ClearMcpServers;
  uTools.ClearTrust;
  WriteSessionFile('.mcp.json',
    '{"mcpServers":{"mock":{"command":' + JsonQuote(Exe) + '}}}');

  { Approve without a prompt by recording the fingerprint the loader will
    compute.  That the test can compute the same hash is itself the assertion
    that the recorded approval is bound to the command line and not to the
    server's name. }
  SetLength(NoArgs, 0);
  Hash := uTools.McpCommandHash(Exe, NoArgs, NoArgs);
  uTools.RecordTrust('mcp:mock', Hash);

  { A previous run's discovery cache would make the first connect a cache hit
    and silently skip the half of this being tested. }
  SysUtils.DeleteFile(IncludeTrailingPathDelimiter(SessionDir) + StateDirName +
    PathDelim + 'mcp-cache.json');

  Check(uTools.LoadMcpConfig(uTools.McpConfigPath, Err),
    'the project config loads: ' + Err);
  uTools.McpApproveAll(nil, nil);
  Check(uTools.McpServerStatus('mock') <> mcDenied,
    'a recorded fingerprint answers the question without a prompt');
  uTools.McpConnectApproved(nil);
  Check(uTools.McpServerStatus('mock') = mcConnected,
    'and the first run connects and discovers');
  Check(uTools.McpServerToolCount('mock') = 2,
    Format('with both of its tools ingested (%d)',
      [uTools.McpServerToolCount('mock')]));

  { The steady state: the tool list comes off disk, nothing is spawned at the
    prompt, and the first real call below pays for the start-up.  A server
    that takes ten seconds to boot must not cost that at every launch. }
  uTools.ClearMcpServers;
  uTools.LoadMcpConfig(uTools.McpConfigPath, Err);
  uTools.McpApproveAll(nil, nil);
  uTools.McpConnectApproved(nil);
  Check(uTools.McpServerStatus('mock') = mcCached,
    'the next run declares from the cache instead of connecting');
  Check(uTools.McpServerToolCount('mock') = 2,
    'with the same tools');

  try
    { (a) the declaration is in the body, after every built-in. }
    ResetScript;
    A := MakeAgent;
    try
      A.AppendUserText('hello');
      Doc := JsonParse(A.RequestBody);
      try
        Tools := Doc.Find('tools');
        DeclAt := -1;
        for I := 0 to Tools.Count - 1 do
          if Tools.Item(I).Str('name') = 'mcp__mock__echo' then DeclAt := I;
        Local := uTools.CountBuiltinTools(Tools);
        Check(DeclAt >= Local,
          Format('the MCP declaration follows the built-ins (%d of %d)',
            [DeclAt, Tools.Count]));
        Check((DeclAt >= 0) and
              (Tools.Item(DeclAt).Find('input_schema') <> nil) and
              (Tools.Item(DeclAt).Find('input_schema').Str('type') = 'object'),
          'and carries a usable input schema');
        Check(Local = uTools.BuiltinToolCount,
          'and the built-in count is unchanged by it');
      finally
        Doc.Free;
      end;
    finally
      A.Free;
    end;

    { (b) the call round trips through the registry to the server. }
    uTools.AllowAllMcp := True;
    ResetScript;
    SetLength(Replies, 2);
    Replies[0] := ToolReply('tu_1', 'mcp__mock__echo', '{"text":"hi"}');
    Replies[1] := TextReply('done');
    A := MakeAgent;
    try
      Check(A.Send('call it', Err), 'the turn completes: ' + Err);
      Check(Length(Requests) = 2, 'in two requests');
      Doc := JsonParse(Requests[1]);
      try
        Msgs := Doc.Find('messages');
        C := Msgs.Item(Msgs.Count - 1).Find('content');
        Check((C <> nil) and (C.Count = 1) and
              (C.Item(0).Str('type') = 'tool_result') and
              (C.Item(0).Str('tool_use_id') = 'tu_1'),
          'the answer comes back as exactly one matching tool_result');
        Check(Pos('pong', C.Item(0).Str('content')) > 0,
          'carrying what the server said: ' + C.Item(0).Str('content'));
      finally
        Doc.Free;
      end;
    finally
      A.Free;
    end;

    { (c) a denial is still a tool_result.  Anything else is a transcript the
      API rejects, which is a far worse failure than a refused tool. }
    uTools.AllowAllMcp := False;
    uTools.AllowAllEdits := True;   { the catch-all must not cover this }
    uTools.ClearTrust;
    ResetScript;
    SetLength(Replies, 2);
    Replies[0] := ToolReply('tu_2', 'mcp__mock__echo', '{"text":"hi"}');
    Replies[1] := TextReply('fine');
    A := MakeAgent;
    try
      Check(A.Send('call it', Err), 'a denied turn still completes: ' + Err);
      Doc := JsonParse(Requests[1]);
      try
        Msgs := Doc.Find('messages');
        C := Msgs.Item(Msgs.Count - 1).Find('content');
        Check((C <> nil) and (C.Count = 1) and
              (C.Item(0).Str('type') = 'tool_result') and
              (C.Item(0).Str('tool_use_id') = 'tu_2'),
          'the denial is reported as a tool_result, not as a missing block');
        Check(C.Item(0).Bool('is_error'), 'marked as an error');
        Check(Pos('denied', C.Item(0).Str('content')) > 0,
          'and saying so: ' + C.Item(0).Str('content'));
      finally
        Doc.Free;
      end;
    finally
      A.Free;
    end;

    { (d) neither the declaration nor the call is available to a subagent -
      and neither is a skill, which is why one is planted first: without it
      the three-tool assertion below would be true for the wrong reason. }
    ForceDirectories(IncludeTrailingPathDelimiter(SessionDir) + StateDirName +
      PathDelim + 'skills' + PathDelim + 'deploy');
    WriteSessionFile(StateDirName + PathDelim + 'skills' + PathDelim +
      'deploy' + PathDelim + 'SKILL.md',
      '---'#10'description: how this project ships.'#10'---'#10'the body'#10);
    uTools.RefreshSkills;
    Check(uTools.EnterSubagent, 'claim the subagent slot');
    try
      Tools := uTools.ToolsSchema;
      try
        Body := Tools.ToJson;
        Check(Pos('mcp__', Body) = 0, 'a subagent is told about no MCP tool');
        { The skill declaration sits below the same Exit, so a project with
          skills still offers a subagent exactly three tools.  Moving it above
          that cut would hand a subagent a reader that reaches files SafePath
          refuses. }
        Check(Tools.Count = 3,
          Format('and still exactly three tools (%d)', [Tools.Count]));
        Check(Pos('"skill"', Body) = 0, 'and never the skill tool');
      finally
        Tools.Free;
      end;
      Doc := TJson.NewObj;
      try
        Body := uTools.RunTool('mcp__mock__echo', Doc, nil, Ok);
        Check(Ok and (Pos('not available to a subagent', Body) > 0),
          'and the call is refused at the boundary: ' + Body);
      finally
        Doc.Free;
      end;
    finally
      uTools.LeaveSubagent;
    end;
  finally
    { Before anything else touches this directory: a live child holding the
      stderr spool is both an unfreed handle and a file that cannot be
      deleted. }
    uTools.ClearMcpServers;
    uTools.ClearTrust;
    { The planted skill would otherwise be a thirteenth declaration in every
      later assertion about the size of the tool list. }
    SysUtils.DeleteFile(IncludeTrailingPathDelimiter(SessionDir) +
      StateDirName + PathDelim + 'skills' + PathDelim + 'deploy' + PathDelim +
      'SKILL.md');
    uTools.ClearSkills;
    uTools.AllowAllMcp := SavedMcp;
    uTools.AllowAllEdits := SavedEdits;
  end;
end;

{ ------------------------------------------------------------------ hooks -- }

procedure WriteHooksFile(const Body: string);
begin
  ForceDirectories(IncludeTrailingPathDelimiter(SessionDir) + StateDirName);
  WriteSessionFile(StateDirName + PathDelim + uHooks.HooksFileName, Body);
end;

{ A blocked tool call still has to produce a tool_result, or the next request
  carries a tool_use nobody answered and the API rejects the whole turn.  This
  is the assertion the feature's safety rests on, and it is only visible from
  above the tool layer. }
procedure TestHookBlocksToolCall;
var
  A: TAgent;
  Err, Notes, Target: string;
  Ok: Boolean;
  Doc, Msgs, Content, C: TJson;
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  uTools.AllowAllEdits := True;
  Target := IncludeTrailingPathDelimiter(SessionDir) + 'hooked-loop.txt';
  SysUtils.DeleteFile(Target);

  WriteHooksFile('{"hooks":{"PreToolUse":[{"matcher":"^write_file$",' +
    '"command":"echo the hook said no & exit /b 2"}]}}');
  uHooks.LoadHooks(True, Notes);
  Check(uHooks.HooksEnabled, 'the blocking hook loaded: ' + Trim(Notes));

  SetLength(Replies, 2);
  Replies[0] := ToolReply('toolu_h1', 'write_file',
    '{"path":"hooked-loop.txt","content":"x"}');
  Replies[1] := TextReply('Understood.');

  A := MakeAgent;
  try
    Ok := A.Send('write the file', Err);
    Check(Ok, 'the turn completes despite the block: ' + Err);
    Check(CallCount = 2, Format('and takes exactly two requests (%d)',
      [CallCount]));
    Check(not FileExists(Target), 'the tool never ran');

    Doc := JsonParse(Requests[1]);
    try
      Msgs := Doc.Find('messages');
      Content := Msgs.Item(Msgs.Count - 1).Find('content');
      Check(Msgs.Item(Msgs.Count - 1).Str('role') = 'user',
        'the block comes back as a user turn');
      Check(Content.Count = 1, 'with exactly one content block');
      C := Content.Item(0);
      Check(C.Str('type') = 'tool_result',
        'and that block is a tool_result: ' + C.Str('type'));
      Check(C.Str('tool_use_id') = 'toolu_h1',
        'tied to the call that was blocked: ' + C.Str('tool_use_id'));
      Check(C.Bool('is_error'), 'marked as an error, the way a denial is');
      Check(Pos('the hook said no', C.Str('content')) > 0,
        'carrying the hook''s reason: ' + C.Str('content'));
    finally
      Doc.Free;
    end;
  finally
    A.Free;
    uHooks.ClearHooks;
    SysUtils.DeleteFile(Target);
  end;
end;

{ The Stop hook drives one more turn, and only one.  The REPL owns the loop,
  so its shape is replicated here rather than reached into - what is being
  pinned is the contract the REPL implements: at most one continuation per
  user turn, the hook's text becomes the next prompt, and StopActive tells the
  hook it is on its second look. }
procedure TestStopHookContinuation;
var
  A: TAgent;
  Err, Notes, Line: string;
  HookOut: THookOutcome;
  Call: THookCall;
  StopActive, Again, TurnOk: Boolean;
  Doc, Msgs: TJson;
begin
  ResetScript;
  uTools.RootDir := SessionDir;

  { Exit 2 every time it is asked, so the cap is the only thing that can stop
    the loop.  If StopActive went missing this would never return. }
  WriteHooksFile('{"hooks":{"Stop":[{"command":' +
    '"echo run the tests & exit /b 2"}]}}');
  uHooks.LoadHooks(True, Notes);
  Check(uHooks.HooksEnabled, 'the Stop hook loaded: ' + Trim(Notes));

  SetLength(Replies, 3);
  Replies[0] := TextReply('Done.');
  Replies[1] := TextReply('Tests pass.');
  Replies[2] := TextReply('This third reply must never be requested.');

  A := MakeAgent;
  try
    Line := 'do the thing';
    StopActive := False;
    repeat
      Again := False;
      TurnOk := A.Send(Line, Err);
      if TurnOk and uHooks.HooksEnabled and not StopActive then
      begin
        Call := uHooks.HookCall(heStop);
        Call.StopActive := StopActive;
        HookOut := uHooks.FireHooks(Call);
        if HookOut.Blocked and (Trim(HookOut.Text) <> '') then
        begin
          StopActive := True;
          Line := HookOut.Text;
          Again := True;
        end;
      end;
    until not Again;

    Check(CallCount = 2,
      Format('a Stop block drives exactly one more turn (%d requests)',
        [CallCount]));
    Doc := JsonParse(Requests[1]);
    try
      Msgs := Doc.Find('messages');
      Check(Pos('run the tests',
        Msgs.Item(Msgs.Count - 1).Find('content').Item(0).Str('text')) > 0,
        'and the hook''s own words became the next prompt');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
    uHooks.ClearHooks;
  end;
end;


{ ------------------------------------------------------------ SDK protocol -- }

{ The protocol is driven entirely in process: uSdk writes through SdkSink and
  reads through SdkSource, so a suite can be the driver on the other end of
  the pipe without there being a pipe.  Both are restored to nil in a finally
  by every test that installs them - they are globals, and one left behind
  would silently swallow the output of every later test. }
var
  SdkLines: array of string;
  DriverLines: array of string;
  DriverAt: Integer = 0;

procedure CollectLine(const S: string);
begin
  SetLength(SdkLines, Length(SdkLines) + 1);
  SdkLines[High(SdkLines)] := S;
end;

function DriverLine(out S: string): Boolean;
begin
  S := '';
  Result := DriverAt <= High(DriverLines);
  if not Result then Exit;
  S := DriverLines[DriverAt];
  Inc(DriverAt);
end;

procedure Drive(const S: string);
begin
  SetLength(DriverLines, Length(DriverLines) + 1);
  DriverLines[High(DriverLines)] := S;
end;

procedure ResetSdk;
begin
  SdkLines := nil;
  DriverLines := nil;
  DriverAt := 0;
end;

{ The message types in the order they were emitted, as one string.  Ordering
  bugs - a result before its tool, an init inside the loop - are far easier to
  read as a sequence than as a set of index comparisons. }
function SdkTypes: string;
var
  I: Integer;
  D: TJson;
begin
  Result := '';
  for I := 0 to High(SdkLines) do
  begin
    D := JsonParse(SdkLines[I]);
    if D = nil then
    begin
      Result := Result + '?;';
      Continue;
    end;
    try
      Result := Result + D.Str('type') + ';';
    finally
      D.Free;
    end;
  end;
end;

function SdkCountOf(const AType: string): Integer;
var
  I: Integer;
  D: TJson;
begin
  Result := 0;
  for I := 0 to High(SdkLines) do
  begin
    D := JsonParse(SdkLines[I]);
    if D = nil then Continue;
    try
      if D.Str('type') = AType then Inc(Result);
    finally
      D.Free;
    end;
  end;
end;

{ The N-th line of a type, as raw text; '' when there is no such line. }
function SdkNthOf(const AType: string; N: Integer): string;
var
  I, Seen: Integer;
  D: TJson;
  Hit: Boolean;
begin
  Result := '';
  Seen := 0;
  for I := 0 to High(SdkLines) do
  begin
    D := JsonParse(SdkLines[I]);
    if D = nil then Continue;
    try
      Hit := D.Str('type') = AType;
    finally
      D.Free;
    end;
    if not Hit then Continue;
    if Seen = N then Exit(SdkLines[I]);
    Inc(Seen);
  end;
end;

function EveryLineIsOneJsonObject: Boolean;
var
  I: Integer;
  D: TJson;
begin
  Result := True;
  for I := 0 to High(SdkLines) do
  begin
    if Pos(#10, SdkLines[I]) > 0 then Exit(False);
    D := JsonParse(SdkLines[I]);
    if (D = nil) or (D.Kind <> jkObj) then Result := False;
    D.Free;
    if not Result then Exit;
  end;
end;

function SdkOptions(F: TSdkFormat; Stream: Boolean): TSdkOptions;
begin
  Result.Format := F;
  Result.StreamInput := Stream;
  Result.SessionId := 'sess-test';
  if Stream then Result.PermissionMode := 'ask'
  else Result.PermissionMode := 'deny';
end;

{ One turn with a tool in it, seen entirely through the wire. }
procedure TestSdkStreamProtocol;
var
  A: TAgent;
  Err, TU, TR, Deltas, Types: string;
  Code, I: Integer;
  Doc: TJson;
begin
  ResetScript;
  ResetSdk;
  uTools.RootDir := SessionDir;
  uTools.AllowAllEdits := True;
  WriteSessionFile('x.txt', 'hello from x');

  SetLength(Replies, 2);
  Replies[0] := ToolReply('t1', 'read_file', '{"path":"x.txt"}');
  Replies[1] := TextReply('done');

  uSdk.SdkSink := @CollectLine;
  A := MakeAgent;
  try
    Code := uSdk.SdkRun(A, SdkOptions(sfStreamJson, False), 'read x', Err);
    Check(Code = 0, 'a clean stream-json run exits 0');
    Check(EveryLineIsOneJsonObject,
      'every emitted line is exactly one JSON object with no embedded newline');

    Types := SdkTypes;
    Check(Copy(Types, 1, 12) = 'system;user;',
      'the run opens with system/init then the user echo: ' + Types);
    Check(Pos('tool_use;', Types) > 0, 'the tool call is announced');
    Check((Pos('tool_use;', Types) > 0) and
          (Pos('tool_use;', Types) < Pos('tool_result;', Types)),
      'and the call is announced before its result');
    Check(SdkCountOf('result') = 1, 'exactly one result line');
    Check(Copy(Types, Length(Types) - Length('result;') + 1, MaxInt) = 'result;',
      'and it is the last thing emitted: ' + Types);

    Doc := JsonParse(SdkNthOf('system', 0));
    try
      Check(Doc.Str('subtype') = 'init', 'the system line is the init line');
    finally
      Doc.Free;
    end;

    TU := SdkNthOf('tool_use', 0);
    Doc := JsonParse(TU);
    try
      Check(Doc.Str('id') = 't1', 'the tool_use carries the block id');
      Check((Doc.Find('input') <> nil) and (Doc.Find('input').Kind = jkObj),
        'and its input is a parsed object, not a quoted string');
      Check(Doc.Find('input').Str('path') = 'x.txt',
        'whose path is what the model asked for');
    finally
      Doc.Free;
    end;

    TR := SdkNthOf('tool_result', 0);
    Doc := JsonParse(TR);
    try
      Check(Doc.Str('tool_use_id') = 't1',
        'the tool_result pairs back to the same id');
      Check((Doc.Find('is_error') <> nil) and
            (Doc.Find('is_error').Kind = jkBool),
        'and is_error is a boolean, always present');
    finally
      Doc.Free;
    end;

    Deltas := '';
    for I := 0 to SdkCountOf('assistant_delta') - 1 do
    begin
      Doc := JsonParse(SdkNthOf('assistant_delta', I));
      try
        if Doc.Find('delta').Str('type') = 'text' then
          Deltas := Deltas + Doc.Find('delta').Str('text');
      finally
        Doc.Free;
      end;
    end;
    Check(Deltas = 'done',
      'the text deltas concatenate to the reply: "' + Deltas + '"');

    Doc := JsonParse(SdkNthOf('result', 0));
    try
      Check(Doc.Str('subtype') = 'success', 'the result says success');
      Check(Doc.Str('result') = A.LastAssistantText,
        'and carries the final assistant text');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
    uSdk.SdkSink := nil;
    uSdk.SdkSource := nil;
  end;
end;

{ A turn reports what that turn spent, not what the session has spent. }
procedure TestSdkPerTurnUsage;
var
  A: TAgent;
  Err: string;
  Doc: TJson;
begin
  ResetScript;
  ResetSdk;
  uTools.RootDir := SessionDir;

  SetLength(Replies, 2);
  Replies[0] := TextReply('one');
  Replies[1] := TextReply('two');
  Drive('{"type":"user","message":{"role":"user","content":"first"}}');
  Drive('{"type":"user","message":{"role":"user","content":"second"}}');

  uSdk.SdkSink := @CollectLine;
  uSdk.SdkSource := @DriverLine;
  A := MakeAgent;
  try
    uSdk.SdkRun(A, SdkOptions(sfStreamJson, True), '', Err);
    Check(SdkCountOf('result') = 2, 'two turns produce two result lines');

    Doc := JsonParse(SdkNthOf('result', 0));
    try
      Check(Doc.Find('usage').Num('input_tokens') = 10,
        'turn one reports its own input tokens');
      Check(Doc.Find('total_usage').Num('input_tokens') = 10,
        'and the running total is the same after one turn');
      Check(Doc.Num('num_turns') = 1, 'num_turns is 1');
      Check(Doc.Num('duration_ms') >= 0, 'duration_ms is present and sane');
      Check(Doc.Find('total_cost_usd') = nil,
        'no total_cost_usd is invented: there is no price table to build one from');
    finally
      Doc.Free;
    end;

    Doc := JsonParse(SdkNthOf('result', 1));
    try
      Check(Doc.Find('usage').Num('input_tokens') = 10,
        'turn two reports turn two alone, not the running sum');
      Check(Doc.Find('total_usage').Num('input_tokens') = 20,
        'while total_usage carries both turns');
      Check(Doc.Num('num_turns') = 2, 'num_turns has advanced');
      Check(Doc.Find('total_cost_usd') = nil,
        'and still no total_cost_usd on the second result');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
    uSdk.SdkSink := nil;
    uSdk.SdkSource := nil;
  end;
end;

{ Several turns over one stdin stream, in both content shapes a driver may
  have to hand. }
procedure TestSdkStreamInputMultiTurn;
var
  A: TAgent;
  Err: string;
  Code: Integer;
begin
  ResetScript;
  ResetSdk;
  uTools.RootDir := SessionDir;

  SetLength(Replies, 2);
  Replies[0] := TextReply('alpha');
  Replies[1] := TextReply('beta');
  Drive('{"type":"user","message":{"role":"user","content":"first question"}}');
  Drive('{"type":"user","message":{"role":"user","content":' +
        '[{"type":"text","text":"second question"}]}}');

  uSdk.SdkSink := @CollectLine;
  uSdk.SdkSource := @DriverLine;
  A := MakeAgent;
  try
    Code := uSdk.SdkRun(A, SdkOptions(sfStreamJson, True), '', Err);
    Check(Code = 0, 'a two-message driver session exits 0');
    Check(SdkCountOf('system') = 1,
      'the init line is emitted once for the whole run, not once per message');
    Check(SdkCountOf('user') = 2, 'both driver messages were echoed');
    Check(SdkCountOf('result') = 2,
      'and each one got its own result, including the block-array form');
    Check(CallCount = 2, 'two requests went out');
    Check((Pos('first question', Requests[1]) > 0) and
          (Pos('second question', Requests[1]) > 0),
      'the second request carries both turns, so the transcript survived');
  finally
    A.Free;
    uSdk.SdkSink := nil;
    uSdk.SdkSource := nil;
  end;
end;

{ One write_file turn answered by the given permission response.  Returns the
  tool_result's is_error; SawResult says whether one was emitted at all. }
function RunOnePermission(const Response: string; SendResponse: Boolean;
  out SawResult: Boolean; out ReqLine: string): Boolean;
var
  A: TAgent;
  Err: string;
  Doc: TJson;
begin
  Result := False;
  SawResult := False;
  ReqLine := '';
  ResetScript;
  ResetSdk;
  SetLength(Replies, 2);
  Replies[0] := ToolReply('w1', 'write_file',
    '{"path":"perm.txt","content":"second version\nwith two lines\n"}');
  Replies[1] := TextReply('ok');
  if SendResponse then Drive(Response);

  uSdk.SdkSink := @CollectLine;
  uSdk.SdkSource := @DriverLine;
  A := MakeAgent;
  try
    uSdk.SdkRun(A, SdkOptions(sfStreamJson, True), 'write it', Err);
    ReqLine := SdkNthOf('permission_request', 0);
    SawResult := SdkCountOf('tool_result') = 1;
    Doc := JsonParse(SdkNthOf('tool_result', 0));
    if Doc <> nil then
    try
      Result := Doc.Bool('is_error');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
    uSdk.SdkSink := nil;
    uSdk.SdkSource := nil;
  end;
end;

{ The driver as permission authority.  Every ambiguity has to deny, and every
  denial still has to produce a tool_result or the transcript is illegal. }
procedure TestSdkPermissionDelegation;
var
  SavedEdits, IsErr, Saw: Boolean;
  Req: string;
  Doc: TJson;
begin
  SavedEdits := uTools.AllowAllEdits;
  uTools.AllowAllEdits := False;
  uTools.RootDir := SessionDir;
  WriteSessionFile('perm.txt', 'first version');
  try
    IsErr := RunOnePermission('{"type":"permission_response","id":"perm_1",' +
      '"behavior":"allow"}', True, Saw, Req);
    Check(Saw, 'an allowed write still emits its tool_result');
    Check(not IsErr, 'and the result is not an error');
    Check(Req <> '', 'a permission_request was emitted');
    Doc := JsonParse(Req);
    try
      Check(Doc.Str('id') <> '', 'carrying a non-empty id');
      Check(Doc.Str('tool_name') = 'write_file', 'and the tool name');
      Check(Pos(#10, Req) = 0,
        'and the multi-line diff preview is escaped, so it stays one line');
      Check(Pos(#10, Doc.Str('detail')) > 0,
        'while the detail decodes back to the several lines a user would read');
    finally
      Doc.Free;
    end;

    { The write above went through, so put the file back for the refusals. }
    WriteSessionFile('perm.txt', 'first version');
    IsErr := RunOnePermission('{"type":"permission_response","id":"perm_1",' +
      '"behavior":"deny"}', True, Saw, Req);
    Check(Saw and IsErr, 'a refusal still produces a tool_result, marked error');

    IsErr := RunOnePermission('{"type":"permission_response","id":"nope",' +
      '"behavior":"allow"}', True, Saw, Req);
    Check(Saw and IsErr, 'an answer to a different id denies');

    IsErr := RunOnePermission('{"type":"permission_response","id":"perm_1",' +
      '"behavior":"maybe"}', True, Saw, Req);
    Check(Saw and IsErr, 'an unrecognised behavior denies');

    IsErr := RunOnePermission('{"type":"notice","text":"hi"}', True, Saw, Req);
    Check(Saw and IsErr, 'a message that is not a permission_response denies');

    IsErr := RunOnePermission('', False, Saw, Req);
    Check(Saw and IsErr, 'and end of stream denies');
  finally
    uTools.AllowAllEdits := SavedEdits;
  end;
end;

{ --output-format json: one line for the whole run, and nothing else. }
procedure TestSdkJsonSingleLine;
var
  A: TAgent;
  Err: string;
  Code: Integer;
  Doc: TJson;
begin
  ResetScript;
  ResetSdk;
  uTools.RootDir := SessionDir;
  SetLength(Replies, 1);
  Replies[0] := TextReply('the whole answer');

  uSdk.SdkSink := @CollectLine;
  A := MakeAgent;
  try
    Code := uSdk.SdkRun(A, SdkOptions(sfJson, False), 'ask', Err);
    Check(Code = 0, 'a clean json run exits 0');
    Check(Length(SdkLines) = 1,
      Format('json mode emits exactly one line (%d): %s',
        [Length(SdkLines), SdkTypes]));
    Check(SdkCountOf('assistant_delta') = 0,
      'no deltas: json mode installs no text hooks at all');
    Check(SdkCountOf('system') = 0, 'and no init line');
    Doc := JsonParse(SdkNthOf('result', 0));
    try
      Check(Doc.Str('subtype') = 'success', 'the one line is a success result');
      Check(Doc.Str('result') = 'the whole answer',
        'carrying the reply text');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
    uSdk.SdkSink := nil;
  end;

  { And a run the transport refuses outright. }
  ResetScript;
  ResetSdk;
  SetLength(Replies, 1);
  Replies[0] := TextReply('never sent');
  FailAfter := 0;
  FailUntil := 99;
  FailStatus := 400;
  FailBody := '{"type":"error","error":{"type":"invalid_request_error",' +
              '"message":"nope"}}';

  uSdk.SdkSink := @CollectLine;
  A := MakeAgent;
  try
    Code := uSdk.SdkRun(A, SdkOptions(sfJson, False), 'ask', Err);
    Check(Code = 1, 'a failed run exits 1, so a caller can tell');
    Check(Length(SdkLines) = 1, 'and still emits exactly one line');
    Doc := JsonParse(SdkNthOf('result', 0));
    try
      Check(Doc.Str('subtype') = 'error', 'reporting subtype error');
      Check(Doc.Bool('is_error'), 'with is_error true');
      Check(Trim(Doc.Str('error')) <> '', 'and a non-empty error field');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
    uSdk.SdkSink := nil;
  end;
end;

{ What a driver on the other end of a pipe can actually send.  The loop must
  survive every one of these and must never mistake one for a prompt. }
procedure TestSdkDriverInputHostile;
var
  A: TAgent;
  Err, Big: string;
  Code: Integer;
begin
  ResetScript;
  ResetSdk;
  uTools.RootDir := SessionDir;
  SetLength(Replies, 2);
  Replies[0] := TextReply('answered the big one');
  Replies[1] := TextReply('answered the good one');

  Big := StringOfChar('q', 300000);
  Drive('');
  Drive('   ');
  Drive('[1,2,3]');
  Drive('{}');
  Drive('{"type":"banana"}');
  Drive('{oops');
  Drive('{"type":"user","message":{"role":"user","content":' +
        JsonQuote(Big) + '}}');
  Drive('{"type":"user","message":{"role":"user","content":"finally"}}');

  uSdk.SdkSink := @CollectLine;
  uSdk.SdkSource := @DriverLine;
  A := MakeAgent;
  try
    Code := uSdk.SdkRun(A, SdkOptions(sfStreamJson, True), '', Err);
    Check(Code = 0, 'a stream of hostile lines does not fail the run');
    Check(SdkCountOf('error') = 6,
      Format('each of the six bad lines produced one error line (%d)',
        [SdkCountOf('error')]));
    { The point of the count: a malformed line that got treated as prompt text
      would show up here as a third request. }
    Check(CallCount = 2,
      Format('and only the two real user messages became requests (%d)',
        [CallCount]));
    Check(SdkCountOf('result') = 2, 'so there are two results');
    Check(Pos(Copy(Big, 1, 200), Requests[0]) > 0,
      'the 300 KB message went through whole');
    Check(Pos('finally', Requests[1]) > 0,
      'and the good message after the bad ones was still processed');
  finally
    A.Free;
    uSdk.SdkSink := nil;
    uSdk.SdkSource := nil;
  end;
end;

begin
  { Every request in this suite goes to the stand-in rather than the network. }
  SetEnvironmentVariable('USERPROFILE',
    PChar(IncludeTrailingPathDelimiter(SessionDir) + 'nohome'));
  uHttp.HttpTransport := @FakePost;
  { The backoff is real time; the tests only care that it happens. }
  uAgent.RetryBaseMs := 1;

  TestTwoRoundLoop;
  TestThreeRoundLoop;
  TestRoundLimit;
  TestMidLoopFailure;
  TestDeniedToolContinues;
  TestDenyProducesToolResult;
  TestPrintModeInheritsNoGrants;
  TestConversationPersists;
  TestParallelToolCalls;
  TestResumedSessionRunsThroughTheLoop;
  TestCancelMidStream;
  TestCancelDuringToolCallCleansTranscript;
  TestCancelBeforeAnyContent;
  TestRetryOnOverload;
  TestNoRetryOnPermanentError;
  TestRetriesGiveUp;
  TestRetryHonorsRetryAfter;
  TestRetryDefaultBackoffWithoutHeader;
  TestCompactWithSummary;
  TestCompactWithSummaryFailureRestores;
  TestCompactWithSummaryEmptyRestores;
  TestToolUseStreamingHooks;
  TestContextTokens;
  TestThinkingBudgetInRequest;
  TestOauthRequestShape;
  TestWebSearchDeclaration;
  TestPauseTurnResumes;
  TestWebSearchRejectionSelfHeals;
  TestCancelDropsDanglingServerToolUse;
  TestSubagent;
  TestSubagentAgentType;
  TestSubagentCost;
  TestSubagentCancel;
  TestSubagentRoundCap;
  TestMcpTurn;
  TestHookBlocksToolCall;
  TestStopHookContinuation;
  TestSdkStreamProtocol;
  TestSdkPerTurnUsage;
  TestSdkStreamInputMultiTurn;
  TestSdkPermissionDelegation;
  TestSdkJsonSingleLine;
  TestSdkDriverInputHostile;

  WriteLn;
  if Fails = 0 then
    WriteLn('all loop tests passed')
  else
    WriteLn(Fails, ' test(s) failed');
  ExitCode := Ord(Fails <> 0);
end.
