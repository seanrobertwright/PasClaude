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

uses SysUtils, Classes, uJson, uHttp, uTools, uAgent;

var
  Fails: Integer = 0;

  { The scripted exchange. }
  Replies: array of string;   { response body per request, in order }
  Requests: array of string;  { what the agent actually sent }
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

begin
  { Every request in this suite goes to the stand-in rather than the network. }
  uHttp.HttpTransport := @FakePost;
  { The backoff is real time; the tests only care that it happens. }
  uAgent.RetryBaseMs := 1;

  TestTwoRoundLoop;
  TestThreeRoundLoop;
  TestRoundLimit;
  TestMidLoopFailure;
  TestDeniedToolContinues;
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

  WriteLn;
  if Fails = 0 then
    WriteLn('all loop tests passed')
  else
    WriteLn(Fails, ' test(s) failed');
  ExitCode := Ord(Fails <> 0);
end.
