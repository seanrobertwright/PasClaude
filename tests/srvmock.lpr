{ srvmock - a stand-in MCP server, built by test.cmd into bin\srvmock.exe.

  This is the real-process half of the MCP transport tests: the scripted wire
  (uMcp.McpWire) covers the framing and every hostile byte sequence with no
  child at all, and this covers the half that only a real child can - pipes,
  inheritance, EOF, exit codes, stderr, and the deadline actually expiring on
  a process that is genuinely there and genuinely silent.

  It is deliberately written against nothing but SysUtils and builds its JSON
  by hand.  A fixture that shared our parser and our writer could not fail in
  the ways a foreign server fails, which is the only reason it exists.

  One binary covers every case, selected by argument:
    (none)     two tools; tools/call answers 'pong'
    --hang     answers initialize, then never answers anything again
    --deaf     answers initialize, then stops reading stdin for good.  Not
               the same failure as --hang: --hang drains every line before
               choosing not to answer, so the write side never fills up.
               This one wedges our WriteFile instead of our ReadFile, which
               is the half no deadline used to cover.
    --die      exits 3 immediately after answering initialize
    --junk     writes non-JSON lines before every response
    --pages    tools/list paginated over three nextCursor pages
    --big      tools/call answers with 300000 bytes of text
    --chatty   writes 100 KB to stderr before answering anything
    --crlf     ends every line with CRLF instead of LF
    --slow N   sleeps N ms before each response
  Its exit code is not summed into the suite result: it is a fixture, not a
  suite. }
program srvmock;

{$mode objfpc}{$H+}

uses SysUtils;

var
  Hang, Die, Deaf, Junk, Pages, Big, Chatty, Crlf: Boolean;
  SlowMs: Integer = 0;
  Page: Integer = 0;

procedure Emit(const S: string);
begin
  if Crlf then Write(Output, S, #13#10) else Write(Output, S, #10);
  Flush(Output);
end;

procedure Respond(const S: string);
begin
  if SlowMs > 0 then Sleep(SlowMs);
  if Junk then
  begin
    Emit('this is not JSON');
    Emit('{ not valid either');
  end;
  Emit(S);
end;

{ The request side is parsed by hand too - just enough to route. }
function FieldStr(const Line, Name: string): string;
var
  P, Q: Integer;
begin
  Result := '';
  P := Pos('"' + Name + '":"', Line);
  if P = 0 then Exit;
  Inc(P, Length(Name) + 4);
  Q := P;
  while (Q <= Length(Line)) and (Line[Q] <> '"') do Inc(Q);
  Result := Copy(Line, P, Q - P);
end;

function FieldNum(const Line, Name: string): string;
var
  P: Integer;
begin
  Result := '';
  P := Pos('"' + Name + '":', Line);
  if P = 0 then Exit;
  Inc(P, Length(Name) + 3);
  while (P <= Length(Line)) and (Line[P] in ['0'..'9', '-']) do
  begin
    Result := Result + Line[P];
    Inc(P);
  end;
end;

function ToolDecl(const Name, Desc: string): string;
begin
  Result := '{"name":"' + Name + '","description":"' + Desc +
    '","inputSchema":{"type":"object","properties":{"text":{"type":"string",' +
    '"description":"anything"}},"required":[]}}';
end;

procedure HandleList(const Id: string);
var
  Body: string;
begin
  if Pages then
  begin
    Inc(Page);
    case Page of
      1: Body := '{"tools":[' + ToolDecl('p1', 'page one') + '],' +
           '"nextCursor":"c2"}';
      2: Body := '{"tools":[' + ToolDecl('p2', 'page two') + '],' +
           '"nextCursor":"c3"}';
    else
      Body := '{"tools":[' + ToolDecl('p3', 'page three') + ']}';
    end;
  end
  else
    Body := '{"tools":[' + ToolDecl('echo', 'echoes its argument') + ',' +
      ToolDecl('ping', 'answers pong') + ']}';
  Respond('{"jsonrpc":"2.0","id":' + Id + ',"result":' + Body + '}');
end;

procedure HandleCall(const Id, Line: string);
var
  Tool, Text: string;
begin
  Tool := FieldStr(Line, 'name');
  if Tool = 'boom' then
  begin
    Respond('{"jsonrpc":"2.0","id":' + Id + ',"result":{"content":[' +
      '{"type":"text","text":"the tool refused"}],"isError":true}}');
    Exit;
  end;
  if Tool = 'nosuch' then
  begin
    Respond('{"jsonrpc":"2.0","id":' + Id + ',"error":{"code":-32602,' +
      '"message":"unknown tool"}}');
    Exit;
  end;
  if Big then
  begin
    Text := StringOfChar('x', 300000);
    Respond('{"jsonrpc":"2.0","id":' + Id + ',"result":{"content":[' +
      '{"type":"text","text":"' + Text + '"}]}}');
    Exit;
  end;
  Respond('{"jsonrpc":"2.0","id":' + Id + ',"result":{"content":[' +
    '{"type":"text","text":"pong"},{"type":"image","mimeType":"image/png",' +
    '"data":"AAAA"}]}}');
end;

var
  I: Integer;
  Line, Method, Id: string;
begin
  Hang := False; Die := False; Deaf := False; Junk := False; Pages := False;
  Big := False; Chatty := False; Crlf := False;
  I := 1;
  while I <= ParamCount do
  begin
    if ParamStr(I) = '--hang' then Hang := True
    else if ParamStr(I) = '--die' then Die := True
    else if ParamStr(I) = '--deaf' then Deaf := True
    else if ParamStr(I) = '--junk' then Junk := True
    else if ParamStr(I) = '--pages' then Pages := True
    else if ParamStr(I) = '--big' then Big := True
    else if ParamStr(I) = '--chatty' then Chatty := True
    else if ParamStr(I) = '--crlf' then Crlf := True
    else if (ParamStr(I) = '--slow') and (I < ParamCount) then
    begin
      Inc(I);
      SlowMs := StrToIntDef(ParamStr(I), 0);
    end;
    Inc(I);
  end;

  if Chatty then
  begin
    for I := 1 to 1024 do Write(ErrOutput, StringOfChar('e', 99), #10);
    Flush(ErrOutput);
  end;

  while not Eof(Input) do
  begin
    ReadLn(Input, Line);
    if Trim(Line) = '' then Continue;
    Method := FieldStr(Line, 'method');
    Id := FieldNum(Line, 'id');
    if Method = 'initialize' then
    begin
      Respond('{"jsonrpc":"2.0","id":' + Id + ',"result":{' +
        '"protocolVersion":"2025-06-18","capabilities":{"tools":{}},' +
        '"serverInfo":{"name":"srv","version":"1.0"}}}');
      if Die then Halt(3);
      { Still here, still holding both pipes, and never reading again.  The
        client's stdin buffer fills and its WriteFile has nowhere to go. }
      while Deaf do Sleep(1000);
    end
    else if Method = 'notifications/initialized' then
      { no reply, by the spec }
    else if Hang then
      { the point of --hang: it heard the request and says nothing }
    else if Method = 'tools/list' then
      HandleList(Id)
    else if Method = 'tools/call' then
      HandleCall(Id, Line)
    else if Id <> '' then
      Respond('{"jsonrpc":"2.0","id":' + Id + ',"error":{"code":-32601,' +
        '"message":"no such method"}}');
  end;
end.
