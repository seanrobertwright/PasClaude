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
  FailAfter: Integer = -1;    { when >= 0, the transport errors at this call }

  Prose: string = '';
  Notices: string = '';
  ToolLog: string = '';

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

  SetLength(Requests, Length(Requests) + 1);
  Requests[High(Requests)] := Body;
  Inc(CallCount);

  if (FailAfter >= 0) and (CallCount > FailAfter) then
  begin
    Result.Status := 529;
    Result.Body := '{"type":"error","error":{"type":"overloaded_error",' +
                   '"message":"Overloaded"}}';
    Result.Error := 'HTTP 529';
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

procedure ResetScript;
begin
  Replies := nil;
  Requests := nil;
  CallCount := 0;
  FailAfter := -1;
  Prose := '';
  Notices := '';
  ToolLog := '';
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
begin
  ResetScript;
  uTools.RootDir := SessionDir;
  SetLength(Replies, 3);
  Replies[0] := ToolReply('t1', 'list_dir', '{"path":"."}');
  Replies[1] := TextReply('never reached');
  FailAfter := 1;      { the second request fails }

  A := MakeAgent;
  try
    Ok := A.Send('do a thing', Err);
    Check(not Ok, 'a mid-loop transport failure fails the turn');
    Check(Pos('529', Err) > 0, 'the status is reported: ' + Err);
    Check(Pos('overloaded_error', Err) > 0, 'the API error type is reported');
    Check(CallCount = 2, 'the loop stopped at the failure');
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

begin
  { Every request in this suite goes to the stand-in rather than the network. }
  uHttp.HttpTransport := @FakePost;

  TestTwoRoundLoop;
  TestThreeRoundLoop;
  TestRoundLimit;
  TestMidLoopFailure;
  TestDeniedToolContinues;
  TestConversationPersists;
  TestParallelToolCalls;

  WriteLn;
  if Fails = 0 then
    WriteLn('all loop tests passed')
  else
    WriteLn(Fails, ' test(s) failed');
  ExitCode := Ord(Fails <> 0);
end.
