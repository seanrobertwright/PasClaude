{ Replays recorded server-sent-event bytes through the agent's decoder, so the
  streaming path and the tool loop are exercised without a network or a key.
  The transport is not covered; everything downstream of it is.

      fpc -Fusrc -FUbuild\units -obin\stream.exe tests\stream.lpr
      bin\stream.exe }
program stream;

{$mode objfpc}{$H+}

uses SysUtils, Classes, uJson, uTools, uAgent;

type
  TChunks = array of string;

var
  Fails: Integer = 0;
  Prose: string = '';
  Reasoning: string = '';
  ToolCalls: string = '';

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

procedure CapThinking(const S: string);
begin
  Reasoning := Reasoning + S;
end;

procedure CapTool(const Name, Detail: string);
begin
  ToolCalls := ToolCalls + Name + '|' + Detail + ';';
end;

procedure CapResult(const Name, Output: string);
begin
end;

{ An event as the API frames it: an "event:" line the decoder ignores, then
  the "data:" line that carries the payload. }
function Ev(const Payload: string): string;
begin
  Result := 'event: x'#10'data: ' + Payload + #10#10;
end;

{ A reply that thinks, speaks, and calls a tool - the three block kinds in
  one message. }
function ToolStream: string;
begin
  Result :=
    Ev('{"type":"message_start","message":{"usage":{"input_tokens":120,"output_tokens":1}}}') +
    Ev('{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}') +
    Ev('{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"I should look."}}') +
    Ev('{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig123"}}') +
    Ev('{"type":"content_block_stop","index":0}') +
    Ev('{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}') +
    Ev('{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Reading "}}') +
    Ev('{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"the file.\n"}}') +
    Ev('{"type":"content_block_stop","index":1}') +
    Ev('{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_01","name":"read_file"}}') +
    Ev('{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"pa"}}') +
    Ev('{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"th\":\"note.txt\"}"}}') +
    Ev('{"type":"content_block_stop","index":2}') +
    Ev('{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":57}}') +
    Ev('{"type":"message_stop"}');
end;

{ Splits S into fixed-size pieces, which lands boundaries in the middle of
  lines and of JSON escapes - the case a naive line reader gets wrong. }
function Shred(const S: string; Size: Integer): TChunks;
var
  I, N: Integer;
begin
  Result := nil;
  N := (Length(S) + Size - 1) div Size;
  SetLength(Result, N);
  for I := 0 to N - 1 do
    Result[I] := Copy(S, I * Size + 1, Size);
end;

{ The cache counters come back inside message_start usage, alongside the
  ordinary token counts.  A server that omits them - or one that includes
  them - must both decode. }
procedure TestCacheUsage;
var
  A: TAgent;
  Stop, Err: string;
begin
  A := TAgent.Create('k', 'my-model', 'sys');
  try
    A.DecodeStream([
      Ev('{"type":"message_start","message":{"usage":{"input_tokens":9,' +
         '"output_tokens":1,"cache_creation_input_tokens":2048,' +
         '"cache_read_input_tokens":4096}}}'),
      Ev('{"type":"message_delta","delta":{"stop_reason":"end_turn"},' +
         '"usage":{"output_tokens":5}}')], Stop, Err);
    Check(A.CacheWriteTokens = 2048, 'cache writes are decoded from usage');
    Check(A.CacheReadTokens = 4096, 'cache reads are decoded from usage');
    Check(A.TokensIn = 9, 'plain input tokens are unchanged by the cache fields');

    { A second reply accumulates rather than overwrites. }
    A.DecodeStream([
      Ev('{"type":"message_start","message":{"usage":{"input_tokens":3,' +
         '"output_tokens":1,"cache_read_input_tokens":6000}}}')], Stop, Err);
    Check(A.CacheReadTokens = 4096 + 6000, 'cache reads accumulate across replies');
    Check(A.CacheWriteTokens = 2048, 'absent cache fields read as zero, not garbage');
  finally
    A.Free;
  end;

  { The old wire shape, with no cache fields at all, must still decode - that
    is what every reply looked like before the markers were added. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    A.DecodeStream([
      Ev('{"type":"message_start","message":{"usage":{"input_tokens":7,' +
         '"output_tokens":1}}}')], Stop, Err);
    Check((A.CacheWriteTokens = 0) and (A.CacheReadTokens = 0),
      'a reply without cache fields leaves the counters at zero');
  finally
    A.Free;
  end;
end;

procedure TestDecode;
var
  A: TAgent;
  Blocks: TPartialBlocks;
  Stop, Err: string;
  Parts: TChunks;
  Input: TJson;
begin
  A := TAgent.Create('test-key', 'test-model', 'sys');
  try
    A.OnText := @CapText;
    A.OnThinking := @CapThinking;

    { Delivered seven bytes at a time: every line and several escapes are
      split across chunk boundaries. }
    Parts := Shred(ToolStream, 7);
    Blocks := A.DecodeStream(Parts, Stop, Err);

    Check(Err = '', 'a well-formed stream reports no error');
    Check(Stop = 'tool_use', 'the stop reason is decoded');
    Check(Length(Blocks) = 3, 'three content blocks are assembled');
    Check(Prose = 'Reading the file.'#10, 'text deltas are streamed in order');
    Check(Reasoning = 'I should look.', 'thinking deltas are streamed');
    Check(A.TokensIn = 120, 'input tokens are recorded');
    Check(A.TokensOut = 57, 'the final output-token count wins');

    if Length(Blocks) = 3 then
    begin
      Check(Blocks[0].Kind = bkThinking, 'block 0 is thinking');
      Check(Blocks[0].Signature = 'sig123', 'the thinking signature is kept');
      Check(Blocks[1].Kind = bkText, 'block 1 is text');
      Check(Blocks[2].Kind = bkToolUse, 'block 2 is a tool call');
      Check(Blocks[2].Name = 'read_file', 'the tool name survives');
      { The argument JSON only becomes valid once the last fragment lands. }
      Input := JsonParse(Blocks[2].Text);
      Check((Input <> nil) and (Input.Str('path') = 'note.txt'),
        'split input_json_delta fragments reassemble into valid JSON');
      Input.Free;
    end;
  finally
    A.Free;
  end;
end;

procedure TestErrorEvent;
var
  A: TAgent;
  Stop, Err: string;
begin
  A := TAgent.Create('k', 'm', '');
  try
    A.DecodeStream(
      [Ev('{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}')],
      Stop, Err);
    Check(Pos('overloaded_error', Err) > 0, 'a mid-stream error event surfaces');
    Check(Pos('Overloaded', Err) > 0, 'the error message is included');
  finally
    A.Free;
  end;
end;

procedure TestJunkTolerated;
var
  A: TAgent;
  Blocks: TPartialBlocks;
  Stop, Err: string;
begin
  A := TAgent.Create('k', 'm', '');
  try
    { Keep-alive blanks, comment lines, an unknown event type and a malformed
      payload must all be skipped rather than aborting the stream. }
    Blocks := A.DecodeStream([
      #10': keep-alive'#10#10,
      Ev('{"type":"some_future_event","whatever":1}'),
      'data: {not json at all'#10#10,
      Ev('{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"survived"}}'),
      Ev('{"type":"message_delta","delta":{"stop_reason":"end_turn"}}')],
      Stop, Err);
    Check(Err = '', 'junk lines do not raise an error');
    Check((Length(Blocks) = 1) and (Blocks[0].Text = 'survived'),
      'decoding continues past unknown and malformed events');
    Check(Stop = 'end_turn', 'later events are still processed');
  finally
    A.Free;
  end;
end;

{ The whole point of the program: a tool call is executed and its result is
  appended to the transcript in the shape the API expects. }
procedure TestToolLoop;
var
  A: TAgent;
  Blocks: TPartialBlocks;
  Stop, Err, Dir, T: string;
  Ran: Boolean;
  Doc, Msg, Content, Blk: TJson;
begin
  Dir := IncludeTrailingPathDelimiter(GetTempDir) + 'pasclaude-stream';
  ForceDirectories(Dir);
  uTools.RootDir := Dir;
  uTools.AllowAllEdits := True;
  uTools.AllowAllBash := True;
  with TStringList.Create do
  try
    Text := 'hello from the file';
    SaveToFile(IncludeTrailingPathDelimiter(Dir) + 'note.txt');
  finally
    Free;
  end;

  A := TAgent.Create('k', 'm', 'sys');
  try
    A.OnToolStart := @CapTool;
    A.OnToolResult := @CapResult;
    Blocks := A.DecodeStream(Shred(ToolStream, 13), Stop, Err);
    A.ApplyBlocks(Blocks, Ran);

    Check(Ran, 'the tool loop reports that a tool ran');
    Check(Pos('read_file|read note.txt', ToolCalls) > 0,
      'the tool call is announced with its arguments');

    T := A.Transcript;
    Doc := JsonParse(T);
    try
      Check((Doc <> nil) and (Doc.Count = 2),
        'the transcript gains an assistant and a user message');
      if (Doc <> nil) and (Doc.Count = 2) then
      begin
        Msg := Doc.Item(0);
        Check(Msg.Str('role') = 'assistant', 'the first message is the assistant');
        Content := Msg.Find('content');
        Check((Content <> nil) and (Content.Count = 3),
          'all three blocks are echoed back');
        Blk := Content.Item(0);
        Check(Blk.Str('signature') = 'sig123',
          'the thinking signature is echoed verbatim');
        Blk := Content.Item(2);
        Check(Blk.Str('type') = 'tool_use', 'the tool_use block is preserved');
        Check(Blk.Find('input').Str('path') = 'note.txt',
          'the tool input is sent back as parsed JSON, not a string');

        Msg := Doc.Item(1);
        Check(Msg.Str('role') = 'user', 'the tool result goes back as a user turn');
        Content := Msg.Find('content');
        Blk := Content.Item(0);
        Check(Blk.Str('type') = 'tool_result', 'the result block is tool_result');
        Check(Blk.Str('tool_use_id') = 'toolu_01',
          'the result is tied to the call by id');
        Check(Pos('hello from the file', Blk.Str('content')) > 0,
          'the tool actually ran and its output is attached');
      end;
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;
end;

{ A denied tool must still produce a result block, otherwise the API rejects
  the next request for an unanswered tool_use. }
procedure TestDeniedToolStillAnswers;
var
  A: TAgent;
  Blocks: TPartialBlocks;
  Stop, Err: string;
  Ran: Boolean;
  Doc, Blk: TJson;
begin
  uTools.AllowAllEdits := False;
  uTools.AllowAllBash := False;
  A := TAgent.Create('k', 'm', '');
  try
    Blocks := A.DecodeStream([
      Ev('{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_09","name":"write_file"}}'),
      Ev('{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"x.txt\",\"content\":\"y\"}"}}')],
      Stop, Err);
    A.ApplyBlocks(Blocks, Ran);
    Doc := JsonParse(A.Transcript);
    try
      Blk := Doc.Item(1).Find('content').Item(0);
      Check(Blk.Str('tool_use_id') = 'toolu_09',
        'a denied call still gets a matching result');
      Check(Blk.Bool('is_error'), 'the denial is flagged as an error');
      Check(not FileExists(IncludeTrailingPathDelimiter(uTools.RootDir) + 'x.txt'),
        'the denied write did not touch the disk');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;
end;

{ A reply with no tool call ends the turn. }
procedure TestPlainReplyEndsTurn;
var
  A: TAgent;
  Blocks: TPartialBlocks;
  Stop, Err: string;
  Ran: Boolean;
begin
  A := TAgent.Create('k', 'm', '');
  try
    Blocks := A.DecodeStream([
      Ev('{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}'),
      Ev('{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Done."}}'),
      Ev('{"type":"message_delta","delta":{"stop_reason":"end_turn"}}')],
      Stop, Err);
    A.ApplyBlocks(Blocks, Ran);
    Check(not Ran, 'a reply with no tool call ends the turn');
  finally
    A.Free;
  end;
end;

{ The request body has to satisfy the API's schema, and a malformed one is
  only reported after authentication - which a test cannot reach. So the shape
  is checked directly here. }
procedure TestRequestBody;
var
  A: TAgent;
  Blocks: TPartialBlocks;
  Stop, Err: string;
  Ran: Boolean;
  Doc, Tools, T0, Msgs, C, Sys: TJson;
  I: Integer;
  SawRead: Boolean;
begin
  uTools.RootDir := IncludeTrailingPathDelimiter(GetTempDir) + 'pasclaude-stream';
  uTools.AllowAllEdits := True;
  A := TAgent.Create('k', 'my-model', 'be helpful');
  try
    { Build a transcript with every message shape in it, then inspect the
      body that would be posted. }
    Blocks := A.DecodeStream(Shred(ToolStream, 11), Stop, Err);
    A.ApplyBlocks(Blocks, Ran);

    Doc := JsonParse(A.RequestBody);
    try
      Check(Doc <> nil, 'the request body is valid JSON');
      if Doc = nil then Exit;
      Check(Doc.Str('model') = 'my-model', 'the model is set');
      { The system prompt travels as a block array so it can carry the cache
        marker; the text itself must be unchanged. }
      Sys := Doc.Find('system');
      Check((Sys <> nil) and (Sys.Count = 1) and
            (Sys.Item(0).Str('text') = 'be helpful'), 'the system prompt is set');
      Check((Sys <> nil) and (Sys.Count = 1) and
            (Sys.Item(0).Find('cache_control') <> nil) and
            (Sys.Item(0).Find('cache_control').Str('type') = 'ephemeral'),
        'the system prompt carries a cache breakpoint');
      Check(Doc.Num('max_tokens') > 0, 'max_tokens is present and positive');
      Check(Doc.Find('stream').AsBoolean, 'streaming is requested');

      Tools := Doc.Find('tools');
      Check((Tools <> nil) and (Tools.Count = 9), 'all nine tools are declared');
      SawRead := False;
      for I := 0 to Tools.Count - 1 do
      begin
        T0 := Tools.Item(I);
        if T0.Str('name') = 'read_file' then
        begin
          SawRead := True;
          Check(T0.Str('description') <> '', 'a tool carries a description');
          C := T0.Find('input_schema');
          Check((C <> nil) and (C.Str('type') = 'object'),
            'the input schema is an object schema');
          Check(C.Find('properties').Find('path') <> nil,
            'the declared property is present');
          Check(C.Find('required').Count = 1, 'the required list is populated');
        end;
      end;
      Check(SawRead, 'read_file is among the declared tools');

      { The second breakpoint sits on the last block of the last message, so
        each turn reuses the whole conversation prefix.  It must be on the
        posted copy only - FMessages stays clean, which the transcript check
        below (built before this body) relies on. }
      Msgs := Doc.Find('messages');
      Check(Msgs.Count > 0, 'the body carries messages');
      C := Msgs.Item(Msgs.Count - 1).Find('content');
      Check((C <> nil) and (C.Count > 0) and
            (C.Item(C.Count - 1).Find('cache_control') <> nil),
        'the last content block carries the conversation cache breakpoint');
      Check(Pos('cache_control', A.Transcript) = 0,
        'the stored transcript itself stays free of cache markers');

      Msgs := Doc.Find('messages');
      Check((Msgs <> nil) and (Msgs.Count = 2), 'the transcript is included');
      Check(Msgs.Item(0).Str('role') = 'assistant', 'roles survive the copy');
      Check(Msgs.Item(1).Find('content').Item(0).Str('type') = 'tool_result',
        'tool results survive the copy');
    finally
      Doc.Free;
    end;

    { The transcript must not be consumed by building a body, or the second
      request of a tool round would go out empty. }
    Check(Pos('tool_result', A.RequestBody) > 0,
      'building the body twice keeps the transcript intact');
  finally
    A.Free;
  end;
end;

{ Text with characters that must survive JSON escaping and UTF-8 round-trips. }
procedure TestAwkwardTextRoundTrips;
var
  A: TAgent;
  Blocks: TPartialBlocks;
  Stop, Err: string;
  Doc, Msgs: TJson;
  Ran: Boolean;
begin
  A := TAgent.Create('k', 'm', '');
  try
    { Pascal string literals have no escapes, so what is written here is the
      literal JSON: \" is one quote and \\ is one backslash after decoding. }
    Blocks := A.DecodeStream([
      Ev('{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}'),
      Ev('{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"quote \" backslash \\ tab \t"}}'),
      Ev('{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" newline \n caf\u00e9 \ud83d\ude00"}}')],
      Stop, Err);
    A.ApplyBlocks(Blocks, Ran);
    Doc := JsonParse(A.RequestBody);
    try
      Check(Doc <> nil, 'awkward text still produces valid JSON');
      if Doc = nil then Exit;
      Msgs := Doc.Find('messages');
      Check(Pos('quote " backslash \ tab', Msgs.Item(0).Find('content').Item(0).Str('text')) > 0,
        'quotes and backslashes round-trip through the body');
      Check(Pos('caf', Msgs.Item(0).Find('content').Item(0).Str('text')) > 0,
        'non-ASCII round-trips through the body');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;
end;

begin
  TestDecode;
  TestCacheUsage;
  TestErrorEvent;
  TestJunkTolerated;
  TestToolLoop;
  TestDeniedToolStillAnswers;
  TestPlainReplyEndsTurn;
  TestRequestBody;
  TestAwkwardTextRoundTrips;
  WriteLn;
  if Fails = 0 then
    WriteLn('all stream tests passed')
  else
    WriteLn(Fails, ' test(s) failed');
  { ExitCode rather than Halt: Halt skips the cleanup of temporaries, which
    shows up as a phantom leak under -gh. }
  ExitCode := Ord(Fails <> 0);
end.
