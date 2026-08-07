{ Exercises the HTTPS transport against real servers, which is the one layer
  the replayed-event suite cannot reach.  It needs a working network, so it is
  kept out of the default run: use  test net.

      bin\net.exe

  No API key is required.  The Anthropic endpoint is reached only to confirm
  that TLS, the headers and the error path work end to end; the 401 it returns
  is the expected result. }
program net;

{$mode objfpc}{$H+}

uses SysUtils, uJson, uHttp, uAgent;

var
  Fails: Integer = 0;
  Chunks: Integer = 0;
  Received: string = '';

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

function Collect(const Data: string; Ctx: Pointer): Boolean;
begin
  Inc(Chunks);
  Received := Received + Data;
  Result := True;
end;

{ Aborts after the first chunk, which is how the user's Esc must behave. }
function StopEarly(const Data: string; Ctx: Pointer): Boolean;
begin
  Inc(Chunks);
  Received := Received + Data;
  Result := False;
end;

procedure TestAvailability;
begin
  Check(HttpAvailable, 'winhttp.dll loads and exports what is needed');
end;

procedure TestBadUrls;
var
  R: THttpResult;
begin
  R := HttpPost('http://example.com/x', '', '', nil, nil);
  Check((not R.Ok) and (Pos('https', R.Error) > 0), 'plain http is refused');

  R := HttpPost('nonsense', '', '', nil, nil);
  Check(not R.Ok, 'a malformed URL is refused');

  { A host that cannot resolve must come back as an error, not a hang. }
  R := HttpPost('https://this-host-does-not-exist-pasclaude.invalid/x', '', '{}', nil, nil);
  Check((not R.Ok) and (R.Error <> ''), 'an unresolvable host reports an error');
end;

{ A real request/response over TLS, echoed back so the body can be checked. }
procedure TestRealPost;
var
  R: THttpResult;
  Doc, Data: TJson;
  Sent: string;
begin
  Sent := '{"hello":"pasclaude","n":42}';
  Received := '';
  Chunks := 0;
  R := HttpPost('https://postman-echo.com/post',
    'content-type: application/json',
    Sent, @Collect, nil);

  Check(R.Ok, 'a real HTTPS POST succeeds: ' + R.Error);
  if not R.Ok then Exit;
  Check(R.Status = 200, 'the status code is read back');
  Check(Chunks > 0, 'the body arrives through the chunk callback');
  Check(Received <> '', 'the callback received bytes');

  { The echo service returns what it was sent, so a round-trip proves the
    body and headers actually went out intact. }
  Doc := JsonParse(Received);
  try
    Check(Doc <> nil, 'the response parses as JSON');
    if Doc = nil then Exit;
    Data := Doc.Find('json');
    Check((Data <> nil) and (Data.Str('hello') = 'pasclaude'),
      'the request body arrived at the server intact');
    Check((Data <> nil) and (Data.Num('n') = 42),
      'numbers survive the round trip');
    Data := Doc.Find('headers');
    Check((Data <> nil) and (Pos('json', Data.Str('content-type')) > 0),
      'request headers are sent');
  finally
    Doc.Free;
  end;
end;

{ Larger than one read buffer, so the multi-chunk path is exercised. }
procedure TestLargeResponse;
var
  R: THttpResult;
  Big: string;
  I: Integer;
begin
  Big := '';
  for I := 1 to 400 do
    Big := Big + '{"i":' + IntToStr(I) + ',"pad":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"},';
  SetLength(Big, Length(Big) - 1);
  Big := '{"items":[' + Big + ']}';

  Received := '';
  Chunks := 0;
  R := HttpPost('https://postman-echo.com/post',
    'content-type: application/json', Big, @Collect, nil);
  Check(R.Ok, 'a large body is accepted: ' + R.Error);
  if not R.Ok then Exit;
  Check(Length(Received) > 8192, 'the response exceeds one read buffer');
  Check(Pos('"i":400', Received) > 0, 'the whole body made the round trip');
end;

{ Returning False from the callback must end the transfer. }
procedure TestAbort;
var
  R: THttpResult;
  Big: string;
  I: Integer;
begin
  Big := '';
  for I := 1 to 400 do
    Big := Big + '{"i":' + IntToStr(I) + ',"pad":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"},';
  SetLength(Big, Length(Big) - 1);
  Big := '{"items":[' + Big + ']}';

  Received := '';
  Chunks := 0;
  R := HttpPost('https://postman-echo.com/post',
    'content-type: application/json', Big, @StopEarly, nil);
  Check(Chunks = 1, 'the transfer stops after the callback returns False');
  Check(R.Error = 'aborted', 'an aborted transfer is reported as such');
end;

{ The live API, without a key.  This proves TLS, the header block and the
  error path work against the endpoint the program actually uses. }
procedure TestAnthropicErrorPath;
var
  A: TAgent;
  Err: string;
  Ok: Boolean;
begin
  A := TAgent.Create('sk-ant-deliberately-invalid', DefaultModel, 'hi');
  try
    Ok := A.Send('hello', Err);
    Check(not Ok, 'an invalid key fails the turn rather than hanging');
    Check(Pos('401', Err) > 0, 'the HTTP status is reported: ' + Err);
    Check(Pos('authentication_error', Err) > 0,
      'the API error type is parsed out of the body');
    Check(Pos('x-api-key', Err) > 0, 'the API error message is surfaced');
  finally
    A.Free;
  end;
end;

{ A request that reaches the API and is rejected on its contents, not its
  key, would prove the body schema. Without a key the server refuses before
  it looks, so this only records that the request was well formed enough to
  be routed. }
procedure TestRequestReachesApi;
var
  R: THttpResult;
  A: TAgent;
  Doc, ErrObj: TJson;
begin
  A := TAgent.Create('sk-ant-invalid', DefaultModel, 'sys');
  try
    R := HttpPost(ApiUrl,
      'x-api-key: sk-ant-invalid'#13#10 +
      'anthropic-version: 2023-06-01'#13#10 +
      'content-type: application/json',
      A.RequestBody, nil, nil);
    Check(R.Status = 401, 'the API answers the generated request body');
    Doc := JsonParse(R.Body);
    try
      Check(Doc <> nil, 'the API error body is JSON');
      if Doc = nil then Exit;
      ErrObj := Doc.Find('error');
      Check(ErrObj <> nil, 'the error object is present');
      { This used to claim the body was proven well formed, on the theory that
        a malformed one is rejected as invalid_request_error first.  That is
        not how the endpoint behaves: an empty messages array, a missing
        max_tokens and an assistant-first transcript all answer
        authentication_error too, because the key is checked before the schema.
        So this asserts only what it can - the request was transported, reached
        the API, and came back as a structured error - and the request body's
        shape is covered offline in stream.lpr instead. }
      Check(ErrObj.Str('type') = 'authentication_error',
        'the API rejected the key, which is as far as a keyless test can get: ' +
        ErrObj.Str('type') + ' ' + ErrObj.Str('message'));
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;
end;

{ The transport and the decoder are only ever wired together inside SendOnce,
  which cannot run without a key.  This drives the same composition by hand:
  real bytes off the wire, delivered in whatever chunks the network chose,
  straight into the decoder.

  The echo service replies with JSON rather than events, so the decoder must
  produce nothing and, more importantly, must not fail - which is exactly how
  it has to behave if a proxy or an error page ever replaces the stream. }
procedure TestWireIntoDecoder;
var
  A: TAgent;
  R: THttpResult;
  Blocks: TPartialBlocks;
  Stop, Err: string;
  Parts: array of string;
  I: Integer;
  Sse: string;
begin
  { First: non-event bytes off a real connection must be shrugged off. }
  Received := '';
  Chunks := 0;
  R := HttpPost('https://postman-echo.com/post',
    'content-type: application/json', '{"not":"an event stream"}',
    @Collect, nil);
  Check(R.Ok, 'the echo request succeeded: ' + R.Error);

  A := TAgent.Create('k', 'm', '');
  try
    SetLength(Parts, 1);
    Parts[0] := Received;
    Blocks := A.DecodeStream(Parts, Stop, Err);
    Check(Length(Blocks) = 0, 'a non-event response yields no content blocks');
    Check(Err = '', 'a non-event response is not reported as a stream error');
  finally
    A.Free;
  end;

  { Second: genuine event text, but carried over the wire and split by the
    network rather than by the test.  The echo service hands the body back
    inside a JSON envelope, so it is recovered before decoding - the point is
    that the bytes made a real round trip. }
  Sse :=
    'event: x'#10'data: {"type":"content_block_start","index":0,' +
    '"content_block":{"type":"text","text":""}}'#10#10 +
    'event: x'#10'data: {"type":"content_block_delta","index":0,' +
    '"delta":{"type":"text_delta","text":"over the wire"}}'#10#10;

  Received := '';
  Chunks := 0;
  R := HttpPost('https://postman-echo.com/post',
    'content-type: application/json',
    '{"sse":' + JsonQuote(Sse) + '}', @Collect, nil);
  Check(R.Ok, 'the event payload was accepted: ' + R.Error);
  if not R.Ok then Exit;

  A := TAgent.Create('k', 'm', '');
  try
    { Recover the payload, then hand it to the decoder one byte at a time -
      the worst case the real stream could produce. }
    with JsonParse(Received) do
    try
      Sse := Find('json').Str('sse');
    finally
      Free;
    end;
    Check(Sse <> '', 'the event text survived the round trip');

    SetLength(Parts, Length(Sse));
    for I := 1 to Length(Sse) do
      Parts[I - 1] := Sse[I];
    Blocks := A.DecodeStream(Parts, Stop, Err);

    Check(Length(Blocks) = 1, 'wire bytes decode into a content block');
    Check((Length(Blocks) = 1) and (Blocks[0].Text = 'over the wire'),
      'the decoded text matches what was sent');
  finally
    A.Free;
  end;
end;

{ The GET path the fetch tool rides.  Same transport underneath, but the
  verb, the collected body and the byte cap are its own code. }
procedure TestRealGet;
var
  R: THttpResult;
begin
  R := HttpGet('https://postman-echo.com/get?probe=pasclaude', '', 0);
  Check(R.Ok, 'a real HTTPS GET succeeds: ' + R.Error);
  Check(Pos('"probe"', R.Body) > 0, 'the response body is collected');

  { The cap must cut the transfer, not just the returned string. }
  R := HttpGet('https://postman-echo.com/get?probe=pasclaude', '', 50);
  Check(R.Ok, 'a capped GET still succeeds: ' + R.Error);
  Check(Length(R.Body) = 50, Format('the cap is honoured, got %d bytes',
    [Length(R.Body)]));

  R := HttpGet('http://example.com/x', '', 0);
  Check(not R.Ok, 'plain http is refused for GET too');
end;

begin
  TestAvailability;
  TestBadUrls;
  TestRealPost;
  TestLargeResponse;
  TestAbort;
  TestRealGet;
  TestAnthropicErrorPath;
  TestRequestReachesApi;
  TestWireIntoDecoder;
  WriteLn;
  if Fails = 0 then
    WriteLn('all network tests passed')
  else
    WriteLn(Fails, ' test(s) failed');
  ExitCode := Ord(Fails <> 0);
end.
