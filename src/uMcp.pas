{ uMcp - a stdio MCP client: one child process, two anonymous pipes, and
  JSON-RPC 2.0 framed one message per line.

  The whole difficulty of this unit is that a synchronous ReadFile on an empty
  pipe blocks until somebody writes, and a Model Context Protocol server that
  hangs, crashes on a bad request, or simply takes its time is a third-party
  program we do not control.  The background-bash header already records the
  other half of that hazard - an unread anonymous pipe fills up and deadlocks
  the child - and answers it with a spool file, which works there because
  nobody is waiting for the output.  Here somebody always is: a tool call
  cannot return until the server answers.  So the answer has to be the other
  one.

  Every wire wait in this unit goes through McpAwait, whose loop is
  peek -> (bytes? read : alive? sleep : dead) -> deadline.  There is no path
  that calls ReadFile without a preceding non-zero PeekNamedPipe, and no path
  that waits without a deadline.  That makes "a hung server can never hang
  pasclaude" a postcondition of one function rather than a discipline spread
  across four call sites, and it is the reason the deadline is checked in the
  same loop that does the reading instead of around it.

  Writing needs the same treatment and for a while did not get it.  A request
  is small and stdin's buffer sounded big, so a byte ceiling was allowed to
  stand in for a deadline - but CreatePipe's default buffer is about 4 KB,
  which one model-supplied argument clears, and a server that stops draining
  its stdin then blocks us inside WriteFile where no deadline, no Esc and no
  tool_result can reach.  So the write end is opened PIPE_NOWAIT and
  ConnSendRaw runs the same loop shape as McpAwait.  A ceiling is not a
  deadline; only a deadline is.

  Polling on the caller's thread, rather than a reader thread or overlapped
  I/O, is a deliberate choice.  This program has exactly one thread and no
  thread safety anywhere: every piece of mutable state above here is an
  unguarded module global, and the subagent design explicitly reasons from
  "the tools a subagent may call touch no module state".  A reader thread
  would invalidate that argument for the whole program in order to save a
  Sleep(5).  Overlapped I/O would buy the same observable behaviour for an
  OVERLAPPED lifetime, a CancelIo path and GetOverlappedResult triage - more
  machinery for a loop that has to poll a deadline either way.

  What this unit knows: pipes, processes, job objects, JSON-RPC.  What it
  deliberately does not know: RootDir, the path guard, permissions, TAskProc,
  .mcp.json, the console.  All of that is policy and lives above, which is
  what keeps this testable against a scripted wire with no child process at
  all - see McpWire. }
unit uMcp;

{$mode objfpc}{$H+}

interface

uses Windows, uJson;

const
  { The widest-deployed handshake revision.  tools/list and tools/call have
    the same shape across every handshake-era revision, so we send this and
    accept whatever the server answers with rather than demanding a match -
    a client that refuses to talk to a server offering a different version is
    the "nothing ever starts" failure, and there is nothing to gain from it. }
  McpProtocolVersion = '2025-06-18';

  McpHandshakeMs = 10000;
  McpListMs      = 10000;
  McpCallMs      = 60000;

  { A request bigger than this is refused locally, without touching the pipe.
    Not a hang guard - ConnSendRaw's deadline is that - just a cap on how
    much of a hung server's buffer one request may be waiting on, and a limit
    on what a runaway argument object can ask the wire to carry. }
  McpMaxRequestBytes = 262144;

  { A line longer than this kills the connection.  A server streaming an
    unterminated line is indistinguishable from one that has hung, and the
    difference between the two is not worth an unbounded buffer. }
  McpMaxLineBytes = 1048576;

  { The assembled text of one tool result.  Capped with Utf8Cut, never
    Copy: the bytes go on to the model. }
  McpMaxResultBytes = 65536;

  McpReadChunk    = 32768;
  McpMaxListPages = 5;

  McpClientName    = 'pasclaude';
  McpClientVersion = '0.1';

type
  { msIdle is a configured server that has not been spawned; msRunning is one
    that answered the handshake; msDead is one that exited, was killed, or
    missed a deadline.  There is no msStarting: a spawn that does not reach a
    completed handshake is closed on the spot, because a half-initialised
    server is a server whose next answer cannot be trusted to belong to the
    question we asked. }
  TMcpState = (msIdle, msRunning, msDead);

  { The substitution seam, in the spirit of uHttp.HttpTransport.  When Open is
    assigned, McpSpawn hands the connection to these four instead of creating
    a process, so the framing, the handshake, pagination, the deadline and
    every hostile-input path can be driven against scripted bytes with no
    child at all.  Nothing in the shipped program assigns them; McpWireInstalled
    exists so a test can say so out loud.

    Poll must never block: it hands back whatever the server has already
    written and reports whether more could still arrive.  Returning False
    means the transport is gone for good, which is what a broken pipe means
    on the real path. }
  TMcpOpenProc = function(const Cmd, WorkDir, ErrLog: string;
    out Wire: Integer; out Err: string): Boolean;
  TMcpSendProc = function(Wire: Integer; const Data: string): Boolean;
  TMcpPollProc = function(Wire: Integer; out Data: string;
    out Alive: Boolean): Boolean;
  TMcpCloseProc = procedure(Wire: Integer; out ExitCode: Integer);

  TMcpWire = record
    Open: TMcpOpenProc;
    Send: TMcpSendProc;
    Poll: TMcpPollProc;
    Close: TMcpCloseProc;
  end;

var
  { All four nil in the shipped program.  See TMcpWire. }
  McpWire: TMcpWire;

  { Optional, filled from uAgent the way uTools.SubagentRunner is.  nil means
    deadline-only: the guarantee is the deadline, this only lets Ctrl+C cut a
    sixty-second call short. }
  McpShouldCancel: function: Boolean = nil;

  { How long a request may take to get into the server's stdin before the
    connection is declared wedged.  Separate from the answer deadlines above
    because it measures a different failure - a server that is not reading -
    and a server too busy to drain 256 KB in ten seconds is not going to
    answer either.

    A variable rather than a constant so a test can wind it down: the only
    way to reach this path is a real child process that genuinely never reads
    its stdin, and the alternative to a seam is ten seconds of wall clock in
    every suite run.  Nothing in the shipped program assigns it. }
  McpSendMs: Integer = 10000;

{ True when a stand-in wire is installed.  A test asserts this is False before
  it installs one, so a wire left behind by an earlier test cannot silently
  become the transport for a later one. }
function McpWireInstalled: Boolean;

{ ---- Streamable HTTP, the second transport -------------------------------

  Everything above this line stays exactly as it was.  That is the design and
  not a happy accident: the JSON-RPC framing, the id matching, pagination, the
  deadlines, the line cap and every hostile-input path in this unit operate on
  "bytes in, bytes out" through ConnSendRaw and ConnPoll, so a second transport
  is a third branch in each of those two functions and nothing else.  A version
  of this that gave HTTP its own handshake and its own list loop would have
  been two clients to keep in step, and the second one would have been the one
  without the hostile-input tests.

  WHAT IS IMPLEMENTED: stateless Streamable HTTP.  One POST per JSON-RPC
  message; the response is either one application/json document or a
  text/event-stream whose data: payloads are the messages.  Both are turned
  into the same newline-framed bytes the pipe path produces, by McpHttpFrame
  below, and handed to the reader that already exists.

  WHAT IS REFUSED, BY NAME: a server that requires a session.  The spec lets a
  server hand back an Mcp-Session-Id on initialize and demand it on every later
  request, and this client does not carry one - so such a server answers the
  first real request with 400 or 404, and that is reported as what it most
  likely is rather than as a bare status code.  Refused rather than
  half-supported for the reason nbformat v3 is: a session id we accepted but
  did not resend would produce a client that works for one call and then fails
  in a way nobody can read.

  ALSO NOT IMPLEMENTED, deliberately: the GET listening stream (a server
  pushing notifications to us needs a reader that is not on the caller's
  thread, which is the thread argument this whole unit rests on), resumption
  via Last-Event-Id, and the deprecated HTTP+SSE two-endpoint transport. }

{ Turns one HTTP response body into the newline-framed message bytes the rest
  of this unit reads.  Pure, and exported for that reason: it is where a
  hostile server's body meets our framing, so it is driven directly.

  application/json - the body is one message.  It is re-emitted COMPACT rather
  than passed through, because a server is entitled to pretty-print and a
  newline inside a pretty-printed object would frame one message as several -
  which is the same class of bug as ToJsonPretty on the send side, and is
  guarded here for the same reason.

  text/event-stream - each event's data: payload is one message.  Multiple
  data: lines in one event are joined with a newline before parsing, per the
  SSE grammar, and then compacted like any other message.  event:, id: and
  retry: fields are read and discarded; a comment line is ignored.

  Anything else, including a missing Content-Type, is treated as JSON: a
  server that sends the right bytes with the wrong label is more likely than
  one that means something else entirely, and a body that then fails to parse
  is reported by the framing layer with the text in it. }
function McpHttpFrame(const Body, ContentType: string): string;

{ Opens an HTTP connection to Url and returns its index, or -1 with Err set.
  Nothing is sent here: the first bytes on the wire are the handshake's, so a
  URL that is unreachable fails at McpHandshake with the transport's own error
  rather than at open time with a different one.

  ExtraHeaders is a CRLF-separated block added to the two this unit sets
  (Content-Type and Accept), '' for none.  It is passed through verbatim: the
  caller composed it from a file only the user can write, and a transport that
  edited headers would be forming an opinion about a document it did not
  read. }
function McpOpenHttp(const Name, Url, ExtraHeaders: string;
  out Err: string): Integer;

{ Starts a server and returns its connection index, or -1 with Err set.  Cmd
  is a complete command line and is passed to CreateProcess as written: no
  shell is interposed, because a shell would change the quoting the caller
  already decided on, swallow the exit code, and sit between us and the pipes
  so that closing stdin no longer reaches the server.  A caller that needs a
  .cmd shim has to say cmd /c itself.

  EnvPairs are NAME=VALUE overrides on top of the inherited environment; an
  empty array inherits unchanged.  ErrLogPath receives the server's stderr,
  which the spec permits it to write freely - it goes to a file rather than
  the console because a chatty server would otherwise scribble across a
  streaming reply. }
function McpSpawn(const Name, Cmd, WorkDir, ErrLogPath: string;
  const EnvPairs: array of string; out Err: string): Integer;

{ initialize, then notifications/initialized.  Any protocolVersion the server
  returns is accepted and reported; only a missing or non-object result is
  fatal. }
function McpHandshake(C: Integer; out ServerName, ServerVersion,
  ProtoVersion, Err: string): Boolean;

{ tools/list, following nextCursor for at most McpMaxListPages pages.  The
  caller owns ToolsArr and every element in it.  Validation of what is in
  those elements is the caller's business, not the transport's. }
function McpListTools(C: Integer; out ToolsArr: TJson; out Err: string): Boolean;

{ tools/call.  Args is copied, not adopted.  Returns False only when no answer
  arrived at all (deadline, death, refused request); a server that answered
  with a JSON-RPC error or with result.isError returns True with IsErr set,
  because that is an answer and the model should see it. }
function McpCallTool(C: Integer; const ToolName: string; Args: TJson;
  TimeoutMs: Integer; out ResultText: string; out IsErr: Boolean;
  out Err: string): Boolean;

function McpAlive(C: Integer): Boolean;
function McpState(C: Integer): TMcpState;
function McpExitCode(C: Integer): Integer;

{ True once the server has sent notifications/tools/list_changed.  Recorded
  and reported, never acted on: the tools array renders before the system
  prompt in the cached request prefix, so changing it mid-session throws away
  the whole prompt cache on every turn it happens. }
function McpToolsChanged(C: Integer): Boolean;

procedure McpClose(C: Integer);
procedure McpShutdownAll;

{ Live connections, for tests and for the teardown ordering rule: a suite must
  bring this to zero before deleting a temporary directory, because a live
  child holding the stderr spool makes the delete fail. }
function McpConnectionCount: Integer;

implementation

uses SysUtils, uSandbox, uHttp;

{ The job-object record and its four kernel32 imports used to be declared here
  verbatim, a third copy of the same thirty lines, because the ladder forbids
  this unit from importing uTools.  uSandbox is a leaf below all three, so
  there is now one declaration - the only direction that duplication could
  ever have been collapsed in. }
const
  McpKillWaitMs = 2000;

type
  TMcpConn = record
    Name, Cmd, ErrLog: string;
    hIn, hOut, Proc, Job: THandle;
    OnWire: Boolean;      { the stand-in wire owns this connection }
    Wire: Integer;
    { The HTTP transport.  Http excludes OnWire and the pipe handles: the three
      are alternatives, and every branch that asks tests OnWire first, then
      Http, then falls through to the pipes that have always been here - so a
      connection that is neither of the first two behaves exactly as it did
      before this existed. }
    Http: Boolean;
    Url: string;
    Hdrs: string;         { extra request headers, CRLF-separated }
    { What the last POST answered, waiting for ConnPoll to hand it over.  HTTP
      is request/response and the reader above is a stream, so the response is
      buffered here for exactly as long as it takes the reader to ask - which
      is immediately, because McpAwait polls in a loop. }
    Pending: string;
    { Set when a request came back 400 or 404 after the handshake had already
      succeeded, which is what a session-requiring server looks like from here.
      Kept as a field rather than reported once because every later call on
      this connection has the same problem and should say so. }
    NeedsSession: Boolean;
    Buf: string;
    NextId: Integer;
    State: TMcpState;
    ExitCode: Integer;
    Tree: Boolean;
    ToolsChanged: Boolean;
    Live: Boolean;        { the slot holds an open connection }
  end;

var
  { Slots are never reused.  A closed connection keeps its index and answers
    msDead forever, so a caller that held an index across a restart is told
    the truth instead of being handed somebody else's server. }
  Conns: array of TMcpConn;

function McpWireInstalled: Boolean;
begin
  Result := Assigned(McpWire.Open);
end;

function Valid(C: Integer): Boolean;
begin
  Result := (C >= 0) and (C <= High(Conns));
end;

function McpConnectionCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(Conns) do
    if Conns[I].Live then Inc(Result);
end;

function McpState(C: Integer): TMcpState;
begin
  if not Valid(C) then Exit(msDead);
  Result := Conns[C].State;
end;

function McpExitCode(C: Integer): Integer;
begin
  if not Valid(C) then Exit(-1);
  Result := Conns[C].ExitCode;
end;

function McpToolsChanged(C: Integer): Boolean;
begin
  Result := Valid(C) and Conns[C].ToolsChanged;
end;

{ ------------------------------------------------------------------ wire }

{ Non-blocking by construction: PeekNamedPipe reports what is ready without
  consuming it, and ReadFile is only ever asked for bytes Peek already
  promised.  Peek failing is how a closed child announces itself - the write
  end is gone, so ERROR_BROKEN_PIPE is EOF and no separate liveness dance is
  needed for it. }
function PipePoll(var Cn: TMcpConn; out Data: string): Boolean;
var
  Avail, Got: DWORD;
  Buf: array[0..McpReadChunk - 1] of Byte;
begin
  Data := '';
  Avail := 0;
  if not PeekNamedPipe(Cn.hOut, nil, 0, nil, @Avail, nil) then Exit(False);
  if Avail = 0 then Exit(True);
  if Avail > McpReadChunk then Avail := McpReadChunk;
  Got := 0;
  if not ReadFile(Cn.hOut, Buf, Avail, Got, nil) then Exit(False);
  if Got = 0 then Exit(False);
  SetLength(Data, Got);
  Move(Buf[0], Data[1], Got);
  Result := True;
end;

function ProcAlive(H: THandle): Boolean;
begin
  Result := (H <> 0) and (WaitForSingleObject(H, 0) = WAIT_TIMEOUT);
end;

{ One message, compacted, with its framing newline; '' for anything that is
  not a JSON object or array.  A body that will not parse is passed through
  verbatim so the line reader above reports it with the server's own bytes in
  the message - dropping it here would turn "the server sent nonsense" into
  "the server sent nothing", which is the harder failure to diagnose. }
function FrameOne(const Text: string): string;
var
  J: TJson;
  S: string;
begin
  S := Trim(Text);
  if S = '' then Exit('');
  J := JsonParse(S);
  if J = nil then Exit(S + #10);
  try
    Result := J.ToJson + #10;
  finally
    J.Free;
  end;
end;

function McpHttpFrame(const Body, ContentType: string): string;
var
  I, N: Integer;
  Line, Data: string;
  Lines: TStringArray;

  procedure Flush;
  begin
    if Data <> '' then Result := Result + FrameOne(Data);
    Data := '';
  end;

begin
  Result := '';
  if Trim(Body) = '' then Exit;
  if ContentType <> 'text/event-stream' then Exit(FrameOne(Body));

  { SSE.  Split on LF and strip a trailing CR, which covers both line endings
    without a second pass; the grammar is field ':' optional-space value, an
    empty line ends the event, and a line opening with ':' is a comment. }
  Lines := nil;
  SetLength(Lines, 0);
  N := 0;
  Line := '';
  for I := 1 to Length(Body) do
    if Body[I] = #10 then
    begin
      SetLength(Lines, N + 1);
      Lines[N] := Line;
      Inc(N);
      Line := '';
    end
    else if Body[I] <> #13 then
      Line := Line + Body[I];
  if Line <> '' then
  begin
    SetLength(Lines, N + 1);
    Lines[N] := Line;
  end;

  Data := '';
  for I := 0 to High(Lines) do
  begin
    Line := Lines[I];
    if Line = '' then
    begin
      Flush;
      Continue;
    end;
    if Line[1] = ':' then Continue;                 { comment }
    if Copy(Line, 1, 5) = 'data:' then
    begin
      Line := Copy(Line, 6, MaxInt);
      if (Line <> '') and (Line[1] = ' ') then Delete(Line, 1, 1);
      { Joined with a newline per the grammar, then compacted by FrameOne, so
        a payload a server chose to split across data: lines arrives as the one
        message it is rather than as several broken ones. }
      if Data = '' then Data := Line else Data := Data + #10 + Line;
    end;
    { event:, id: and retry: are read and dropped: this client has no use for
      an event name, does not resume, and has its own deadlines. }
  end;
  { A stream that ended without its terminating blank line still delivered a
    message, and a server closing the connection cleanly is the ordinary way
    a single-response stream ends. }
  Flush;
end;

function ConnPoll(C: Integer; out Data: string; out Alive: Boolean): Boolean;
begin
  Data := '';
  Alive := False;
  if not Valid(C) then Exit(False);
  if Conns[C].OnWire then
    Result := McpWire.Poll(Conns[C].Wire, Data, Alive)
  else if Conns[C].Http then
  begin
    { Whatever the last POST answered, once.  Alive is the connection's own
      state and not a process handle: there is no child here, so "alive" means
      the transport has not been declared finished - which POST failure and the
      session refusal are the only two ways to do. }
    Data := Conns[C].Pending;
    Conns[C].Pending := '';
    Alive := Conns[C].State <> msDead;
    Result := Alive or (Data <> '');
  end
  else
  begin
    Result := PipePoll(Conns[C], Data);
    Alive := ProcAlive(Conns[C].Proc);
  end;
end;

{ One POST carrying one JSON-RPC message, with the answer parked in Pending
  for the poll that is about to ask for it.

  DEADLINES ARE THE TRANSPORT'S HERE, not this loop's, and that is the one
  place the HTTP path genuinely differs from the pipe path rather than merely
  looking different.  WinHTTP owns the resolve, connect, send and receive
  timeouts, so there is no equivalent of ConnSendRaw's write loop and nothing
  to poll a cancel flag against mid-request: a POST is atomic from here.  What
  that costs is stated rather than hidden - Ctrl+C cannot cut a request that is
  already on the wire, where the pipe path checks McpShouldCancel every five
  milliseconds - and what stops it being a hang is that HttpTimeoutMs is set
  for the duration of the call and restored in a finally, exactly as the
  telemetry flush does it.

  A notification has no id and its answer is 202 with an empty body; that
  produces no frame, which is correct, because nothing upstream is waiting for
  one.

  400 and 404 AFTER a completed handshake are the session refusal.  Before the
  handshake they are an ordinary transport failure and read as one: a server
  that 404s the initialize was never an MCP endpoint, and telling somebody
  their URL needs a session when the URL is simply wrong would be the more
  confusing of the two lies. }
function HttpSendRaw(C: Integer; const Data: string): Boolean;
var
  R: uHttp.THttpResult;
  Saved: Integer;
  Hdrs: string;
begin
  if Trim(Data) = '' then Exit(True);
  { Accept names both, because a server chooses which to answer with and this
    client reads either.  The caller's own headers go last so a user who wants
    an Authorization line gets one, and so that nothing they wrote can be
    silently overridden by a default appended after it. }
  Hdrs := 'Content-Type: application/json'#13#10 +
          'Accept: application/json, text/event-stream';
  if Conns[C].Hdrs <> '' then Hdrs := Hdrs + #13#10 + Conns[C].Hdrs;

  Saved := uHttp.HttpTimeoutMs;
  uHttp.HttpTimeoutMs := McpCallMs;
  try
    R := uHttp.HttpPost(Conns[C].Url, Hdrs, Trim(Data), nil, nil);
  finally
    uHttp.HttpTimeoutMs := Saved;
  end;

  if not R.Ok then
  begin
    Conns[C].State := msDead;
    Exit(False);
  end;
  if (R.Status = 400) or (R.Status = 404) then
    if Conns[C].State = msRunning then
    begin
      Conns[C].NeedsSession := True;
      Conns[C].State := msDead;
      Exit(False);
    end;
  if (R.Status < 200) or (R.Status > 299) then
  begin
    Conns[C].State := msDead;
    Exit(False);
  end;
  Conns[C].Pending := Conns[C].Pending + McpHttpFrame(R.Body, R.ContentType);
  Result := True;
end;

{ The write half of the same guarantee McpAwait gives the read half, and it
  has to be here rather than in a byte ceiling above it: the pipe's buffer is
  the system default, about 4 KB, so "keep a request under a few buffer fills"
  never bounded anything - one model-supplied argument of a few kilobytes is
  already past it.  A server that stops draining its stdin would block us
  inside WriteFile with no deadline, no Esc and no tool_result, which is the
  exact hang this unit exists to make impossible.

  The write handle is put in PIPE_NOWAIT at spawn, so WriteFile takes what
  fits and returns immediately; the loop below supplies the deadline, the
  liveness check and the cancel poll, in the same order and with the same
  Sleep(5) as McpAwait.  A short write is progress, a zero write is a full
  buffer, and neither is an error until the deadline says so. }
function ConnSendRaw(C: Integer; const Data: string; DeadlineMs: Integer): Boolean;
var
  Wrote: DWORD;
  Sent, Chunk: Integer;
  Deadline: QWord;
begin
  if not Valid(C) then Exit(False);
  if Conns[C].OnWire then Exit(McpWire.Send(Conns[C].Wire, Data));
  if Conns[C].Http then Exit(HttpSendRaw(C, Data));
  if Data = '' then Exit(True);
  Sent := 0;
  Deadline := GetTickCount64 + QWord(DeadlineMs);
  repeat
    Wrote := 0;
    Chunk := Length(Data) - Sent;
    if not WriteFile(Conns[C].hIn, Data[Sent + 1], Chunk, Wrote, nil) then
      Exit(False);
    Inc(Sent, Integer(Wrote));
    if Sent >= Length(Data) then Exit(True);
    { Nothing moved.  A dead child never drains again, so do not spend the
      whole deadline discovering it. }
    if not ProcAlive(Conns[C].Proc) then Exit(False);
    if Assigned(McpShouldCancel) and McpShouldCancel() then Exit(False);
    Sleep(5);
  until GetTickCount64 > Deadline;
  Result := False;
end;

{ One message per line, and the line may not contain an embedded newline -
  that is the framing, verbatim from the spec.  ToJson is the compact writer
  and escapes control characters, so a newline inside a string value can never
  break a message in half; ToJsonPretty would, which is why this must not be
  "tidied up" into the readable form. }
function ConnSendMsg(C: Integer; Msg: TJson; DeadlineMs: Integer;
  out Err: string): Boolean;
var
  S: string;
begin
  Err := '';
  S := Msg.ToJson;
  if Length(S) + 1 > McpMaxRequestBytes then
  begin
    Err := Format('request is too large (%d bytes; the limit is %d)',
      [Length(S), McpMaxRequestBytes]);
    Exit(False);
  end;
  Result := ConnSendRaw(C, S + #10, DeadlineMs);
  { One message for both endings on purpose: from here a server that closed
    its stdin and one that stopped reading it are the same fact - the request
    did not land - and the connection is finished either way.

    The HTTP transport has a third ending that is worth naming, because it is
    the one a user can act on: a server that answered the handshake and then
    refused the next request is almost always one demanding the session id this
    client does not carry.  "Almost always" is doing real work in that sentence
    and the message says so rather than asserting it - the same status can mean
    the endpoint moved - but a refusal that names the likely cause is worth
    more than a bare 400 to somebody deciding whether their URL is wrong or
    their server is simply out of scope for this build. }
  if not Result then
    if Valid(C) and Conns[C].NeedsSession then
      Err := 'the server refused the request after the handshake, which is ' +
        'what a server requiring an Mcp-Session-Id looks like; this build ' +
        'speaks stateless streamable http only'
    else if Valid(C) and Conns[C].Http then
      Err := 'the request did not reach the server'
    else
      Err := 'the server stopped reading its input';
end;

function NewRequest(C: Integer; const Method: string; Params: TJson;
  out Id: Integer): TJson;
begin
  Inc(Conns[C].NextId);
  Id := Conns[C].NextId;
  Result := TJson.NewObj;
  Result.AddStr('jsonrpc', '2.0');
  Result.AddNum('id', Id);
  Result.AddStr('method', Method);
  if Params <> nil then Result.Add('params', Params);
end;

{ --------------------------------------------------------------- spawn }

function BuildEnvBlock(const EnvPairs: array of string): string;
var
  I, J, Eq: Integer;
  Name, Cur: string;
  Taken: Boolean;
begin
  Result := '';
  if Length(EnvPairs) = 0 then Exit;
  for I := 1 to GetEnvironmentVariableCount do
  begin
    Cur := GetEnvironmentString(I);
    Eq := Pos('=', Cur);
    if Eq <= 1 then Continue;         { the drive-letter entries Windows hides }
    Name := Copy(Cur, 1, Eq - 1);
    Taken := False;
    for J := 0 to High(EnvPairs) do
    begin
      Eq := Pos('=', EnvPairs[J]);
      if (Eq > 1) and SameText(Copy(EnvPairs[J], 1, Eq - 1), Name) then
        Taken := True;
    end;
    if not Taken then Result := Result + Cur + #0;
  end;
  for J := 0 to High(EnvPairs) do
    if Pos('=', EnvPairs[J]) > 1 then Result := Result + EnvPairs[J] + #0;
  Result := Result + #0;
end;

function McpOpenHttp(const Name, Url, ExtraHeaders: string;
  out Err: string): Integer;
var
  Cn: TMcpConn;
  Host, Path: string;
  Port: Word;
  Secure: Boolean;
begin
  Err := '';
  Result := -1;
  if Trim(Url) = '' then
  begin
    Err := 'no url';
    Exit;
  end;
  { SplitUrlEx and not a scheme test of our own, so this transport inherits
    exactly the rule the rest of the program already enforces: https anywhere,
    http only when the host is EXACTLY 127.0.0.1 or localhost.  Checked here
    rather than left to the first POST, because a refusal at open time names
    the URL in a message somebody can act on, where a failure at handshake time
    reads as a server that would not talk to us. }
  if not uHttp.SplitUrlEx(Url, Host, Path, Port, Secure) then
  begin
    Err := 'not a usable URL (https, or http only on localhost): ' + Url;
    Exit;
  end;
  if not uHttp.HttpAvailable then
  begin
    Err := 'winhttp.dll is not available, so no http server can be reached';
    Exit;
  end;
  FillChar(Cn, SizeOf(Cn), 0);
  Cn.Name := Name;
  { Cmd carries the URL because every display path above - /mcp, /doctor, the
    cache key, the notices - reads Cmd to say what a server IS.  Giving the URL
    a second field there as well would mean each of those growing a branch, and
    the one thing they all want is a string that identifies the server. }
  Cn.Cmd := Url;
  Cn.Url := Url;
  Cn.Hdrs := ExtraHeaders;
  Cn.Http := True;
  Cn.ExitCode := -1;
  { msIdle and not msRunning: nothing has been sent, so nothing has agreed to
    talk to us yet, and the handshake is what promotes it.  HttpSendRaw reads
    that difference to tell an ordinary 404 from a session refusal. }
  Cn.State := msIdle;
  Cn.Live := True;
  SetLength(Conns, Length(Conns) + 1);
  Conns[High(Conns)] := Cn;
  Result := High(Conns);
end;

function McpSpawn(const Name, Cmd, WorkDir, ErrLogPath: string;
  const EnvPairs: array of string; out Err: string): Integer;
var
  Cn: TMcpConn;
  SA: SECURITY_ATTRIBUTES;
  SI: STARTUPINFOA;
  PI: PROCESS_INFORMATION;
  hInR, hInW, hOutR, hOutW, hErr, hJob: THandle;
  Mode: DWORD;
  CmdLine, EnvBlock, Dir: string;
  InJob: Boolean;
begin
  Err := '';
  Result := -1;
  FillChar(Cn, SizeOf(Cn), 0);
  Cn.Name := Name;
  Cn.Cmd := Cmd;
  Cn.ErrLog := ErrLogPath;
  Cn.ExitCode := -1;
  Cn.State := msRunning;
  Cn.Live := True;
  if Trim(Cmd) = '' then
  begin
    Err := 'no command to run';
    Exit;
  end;

  if Assigned(McpWire.Open) then
  begin
    { The stand-in wire.  Everything below this point is process creation,
      and everything above McpSpawn is protocol - so this is the exact line
      the seam has to sit on for the protocol to be testable without one. }
    if not McpWire.Open(Cmd, WorkDir, ErrLogPath, Cn.Wire, Err) then Exit;
    Cn.OnWire := True;
    SetLength(Conns, Length(Conns) + 1);
    Conns[High(Conns)] := Cn;
    Result := High(Conns);
    Exit;
  end;

  FillChar(SA, SizeOf(SA), 0);
  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True;
  hInR := 0; hInW := 0; hOutR := 0; hOutW := 0;
  if not CreatePipe(hInR, hInW, @SA, 0) then
  begin
    Err := 'could not create a pipe: ' + SysErrorMessage(GetLastError);
    Exit;
  end;
  if not CreatePipe(hOutR, hOutW, @SA, 0) then
  begin
    CloseHandle(hInR); CloseHandle(hInW);
    Err := 'could not create a pipe: ' + SysErrorMessage(GetLastError);
    Exit;
  end;
  { Mandatory, not hygiene: without it the child inherits a duplicate of our
    own end of each pipe, and the read end therefore never sees EOF when the
    child exits - the exact deadlock this unit exists to avoid, arriving by
    the back door. }
  SetHandleInformation(hInW, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(hOutR, HANDLE_FLAG_INHERIT, 0);
  { Our end of the child's stdin, non-blocking, so ConnSendRaw's deadline is
    reachable at all.  Only this handle: the child keeps the blocking read end
    it expects, and our read end is already governed by PeekNamedPipe.  Not
    fatal if it fails - an old pipe implementation that refuses the mode leaves
    a blocking write, which is what shipped before and is still better than
    refusing to start the server. }
  Mode := PIPE_NOWAIT;
  SetNamedPipeHandleState(hInW, @Mode, nil, nil);

  if ErrLogPath <> '' then
    hErr := CreateFile(PChar(ErrLogPath), GENERIC_WRITE,
      FILE_SHARE_READ or FILE_SHARE_WRITE, @SA, CREATE_ALWAYS,
      FILE_ATTRIBUTE_NORMAL, 0)
  else
    hErr := CreateFile('NUL', GENERIC_WRITE,
      FILE_SHARE_READ or FILE_SHARE_WRITE, @SA, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL, 0);

  hJob := SandboxNewJob;

  { Unmodified, with no cmd.exe wrapper, unlike bash and hooks: what .mcp.json
    holds is a complete command line passed to CreateProcess as written.
    SandboxSpawn takes a finished line and never composes one, which is the
    property that lets this and the wrapped callers share it. }
  CmdLine := Cmd;
  { The server's own env pairs first, then the sandbox's temp redirection over
    the top - the scratch is the only directory a low child can write, so it
    has to win over anything the config set. }
  EnvBlock := SandboxApplyEnv(BuildEnvBlock(EnvPairs));
  Dir := WorkDir;

  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESTDHANDLES;
  SI.hStdInput := hInR;
  SI.hStdOutput := hOutW;
  SI.hStdError := hErr;
  FillChar(PI, SizeOf(PI), 0);

  if not SandboxSpawn(CmdLine, Dir, EnvBlock, 0, SI, PI, hJob, InJob) then
  begin
    Err := 'could not start: ' + SysErrorMessage(GetLastError);
    { Said here rather than left to the caller: at low integrity a server that
      wants to unpack itself into %APPDATA% fails before it has spoken a word
      of protocol, and without this the level looks like a broken config. }
    if uSandbox.SandboxLevel = slLow then
      Err := Err + ' [sandbox: low]';
    CloseHandle(hInR); CloseHandle(hInW);
    CloseHandle(hOutR); CloseHandle(hOutW);
    if hErr <> INVALID_HANDLE_VALUE then CloseHandle(hErr);
    if hJob <> 0 then CloseHandle(hJob);
    Exit;
  end;

  { The child holds its own copies; a handle kept here is a handle leaked -
    and the two we must drop are also the two that would keep the pipes from
    ever reporting EOF. }
  CloseHandle(hInR);
  CloseHandle(hOutW);
  if hErr <> INVALID_HANDLE_VALUE then CloseHandle(hErr);
  CloseHandle(PI.hThread);

  Cn.hIn := hInW;
  Cn.hOut := hOutR;
  Cn.Proc := PI.hProcess;
  Cn.Job := hJob;
  { Created suspended, assigned, then resumed, so the grandchild race this
    used to document is closed. }
  Cn.Tree := InJob;

  SetLength(Conns, Length(Conns) + 1);
  Conns[High(Conns)] := Cn;
  Result := High(Conns);
end;

{ --------------------------------------------------------------- close }

procedure McpClose(C: Integer);
var
  Code: DWORD;
  Ex: Integer;
begin
  if not Valid(C) then Exit;
  if not Conns[C].Live then Exit;
  Conns[C].Live := False;
  Conns[C].State := msDead;
  Conns[C].Buf := '';

  if Conns[C].OnWire then
  begin
    Ex := -1;
    if Assigned(McpWire.Close) then McpWire.Close(Conns[C].Wire, Ex);
    Conns[C].ExitCode := Ex;
    Exit;
  end;

  { Closing stdin is the polite shutdown the stdio transport specifies: a
    well-behaved server sees EOF and exits.  The wait is short because the
    ones that do not are exactly the ones we are here to survive, and the
    job object turns "kill the server" into "kill everything it started". }
  if Conns[C].hIn <> 0 then CloseHandle(Conns[C].hIn);
  Conns[C].hIn := 0;
  if Conns[C].Proc <> 0 then
  begin
    if WaitForSingleObject(Conns[C].Proc, McpKillWaitMs) <> WAIT_OBJECT_0 then
      if Conns[C].Job <> 0 then SandboxTerminateJob(Conns[C].Job, 1)
      else TerminateProcess(Conns[C].Proc, 1);
    Code := DWORD(-1);
    if GetExitCodeProcess(Conns[C].Proc, Code) and (Code <> STILL_ACTIVE) then
      Conns[C].ExitCode := Integer(Code);
    CloseHandle(Conns[C].Proc);
    Conns[C].Proc := 0;
  end;
  if Conns[C].hOut <> 0 then CloseHandle(Conns[C].hOut);
  Conns[C].hOut := 0;
  if Conns[C].Job <> 0 then CloseHandle(Conns[C].Job);
  Conns[C].Job := 0;
end;

procedure McpShutdownAll;
var
  I: Integer;
begin
  for I := 0 to High(Conns) do McpClose(I);
  SetLength(Conns, 0);
end;

function McpAlive(C: Integer): Boolean;
var
  Data: string;
  A: Boolean;
begin
  if not Valid(C) then Exit(False);
  if not Conns[C].Live then Exit(False);
  if Conns[C].State = msDead then Exit(False);
  if not ConnPoll(C, Data, A) then
  begin
    Conns[C].State := msDead;
    Exit(False);
  end;
  Conns[C].Buf := Conns[C].Buf + Data;
  Result := A;
  if not A then Conns[C].State := msDead;
end;

{ ----------------------------------------------------------- the wait }

function TakeLine(var Buf: string; out Line: string): Boolean;
var
  P: Integer;
begin
  Line := '';
  P := Pos(#10, Buf);
  if P = 0 then Exit(False);
  Line := Copy(Buf, 1, P - 1);
  Delete(Buf, 1, P);
  { A server that ends its lines with CRLF is out of spec but harmless, and
    refusing to parse it would be a diagnosis nobody could make from the
    outside. }
  if (Line <> '') and (Line[Length(Line)] = #13) then
    SetLength(Line, Length(Line) - 1);
  Result := True;
end;

procedure ReplyMethodNotFound(C: Integer; Id: TJson);
var
  M, E: TJson;
  Ignored: string;
begin
  M := TJson.NewObj;
  try
    M.AddStr('jsonrpc', '2.0');
    if Id.Kind = jkStr then M.AddStr('id', Id.AsString)
    else M.AddNum('id', Id.AsNumber);
    E := TJson.NewObj;
    E.AddNum('code', -32601);
    E.AddStr('message', 'pasclaude implements no client methods');
    M.Add('error', E);
    ConnSendMsg(C, M, McpSendMs, Ignored);
  finally
    M.Free;
  end;
end;

{ Every wire wait in this unit.  Returns the response object carrying Id -
  the caller owns it - or nil with Err set.

  Anything else on the wire is discarded rather than treated as an error.
  The spec says a server MUST NOT write non-protocol text to stdout, but a
  client that dies on a stray line is worse than one that ignores it: the
  server is a third-party program and the alternative to tolerating its noise
  is losing the whole session to it. }
function McpAwait(C, Id, DeadlineMs: Integer; out Err: string): TJson;
var
  Deadline: QWord;
  Line, Data: string;
  M, IdJ: TJson;
  Alive: Boolean;
begin
  Err := '';
  Result := nil;
  if not Valid(C) or not Conns[C].Live then
  begin
    Err := 'the server is not connected';
    Exit;
  end;
  Deadline := GetTickCount64 + QWord(DeadlineMs);
  repeat
    while TakeLine(Conns[C].Buf, Line) do
    begin
      if Trim(Line) = '' then Continue;
      M := JsonParse(Line);
      if M = nil then Continue;
      if M.Kind <> jkObj then
      begin
        M.Free;
        Continue;
      end;
      if M.Find('method') <> nil then
      begin
        IdJ := M.Find('id');
        if IdJ <> nil then
          { A request from the server.  We advertise no client capabilities,
            so a conformant server never sends one - but an answer costs one
            line and the alternative leaves it waiting for us forever. }
          ReplyMethodNotFound(C, IdJ)
        else if M.Str('method') = 'notifications/tools/list_changed' then
          Conns[C].ToolsChanged := True;
        M.Free;
        Continue;
      end;
      IdJ := M.Find('id');
      if (IdJ <> nil) and (Round(IdJ.AsNumber) = Id) then Exit(M);
      { A response to a request we already gave up on. }
      M.Free;
    end;

    if Length(Conns[C].Buf) > McpMaxLineBytes then
    begin
      Err := 'the server sent an unterminated line longer than the limit';
      McpClose(C);
      Exit(nil);
    end;

    if not ConnPoll(C, Data, Alive) then
    begin
      Conns[C].State := msDead;
      Err := 'the server stopped';
      McpClose(C);
      Exit(nil);
    end;
    if Data <> '' then
    begin
      Conns[C].Buf := Conns[C].Buf + Data;
      Continue;
    end;
    if not Alive then
    begin
      Conns[C].State := msDead;
      Err := 'the server stopped';
      McpClose(C);
      Exit(nil);
    end;
    if Assigned(McpShouldCancel) and McpShouldCancel() then
    begin
      Err := 'cancelled';
      Exit(nil);
    end;
    Sleep(5);
  until GetTickCount64 > Deadline;

  { Killed, not merely abandoned.  A server that ignored one request has no
    credibility for the next, and a process left running would still own the
    stderr spool and still be there at the next poll pretending to be idle. }
  Err := Format('the server did not answer within %d ms', [DeadlineMs]);
  Conns[C].State := msDead;
  McpClose(C);
end;

{ ------------------------------------------------------------ protocol }

function McpHandshake(C: Integer; out ServerName, ServerVersion,
  ProtoVersion, Err: string): Boolean;
var
  Req, Params, Caps, Info, Resp, R, Note: TJson;
  Id: Integer;
begin
  ServerName := '';
  ServerVersion := '';
  ProtoVersion := '';
  Err := '';
  Result := False;
  if not Valid(C) or not Conns[C].Live then
  begin
    Err := 'the server is not connected';
    Exit;
  end;

  Params := TJson.NewObj;
  Params.AddStr('protocolVersion', McpProtocolVersion);
  { We advertise nothing.  A conformant server therefore never asks us to
    sample, to list roots, or to elicit - none of which this client can do,
    and all of which would arrive as a request we would have to refuse in the
    middle of somebody's tool call. }
  Caps := TJson.NewObj;
  Params.Add('capabilities', Caps);
  Info := TJson.NewObj;
  Info.AddStr('name', McpClientName);
  Info.AddStr('version', McpClientVersion);
  Params.Add('clientInfo', Info);

  Req := NewRequest(C, 'initialize', Params, Id);
  try
    if not ConnSendMsg(C, Req, McpSendMs, Err) then Exit;
  finally
    Req.Free;
  end;

  Resp := McpAwait(C, Id, McpHandshakeMs, Err);
  if Resp = nil then Exit;
  try
    R := Resp.Find('error');
    if R <> nil then
    begin
      Err := Format('the server refused initialize (%d): %s',
        [Round(R.Num('code')), R.Str('message')]);
      Exit;
    end;
    R := Resp.Find('result');
    if (R = nil) or (R.Kind <> jkObj) then
    begin
      Err := 'the server answered initialize with no result object';
      Exit;
    end;
    ProtoVersion := R.Str('protocolVersion');
    Note := R.Find('serverInfo');
    if (Note <> nil) and (Note.Kind = jkObj) then
    begin
      ServerName := Note.Str('name');
      ServerVersion := Note.Str('version');
    end;
  finally
    Resp.Free;
  end;

  { Nothing may be sent before this, and the server is entitled to refuse
    everything until it arrives. }
  Req := TJson.NewObj;
  try
    Req.AddStr('jsonrpc', '2.0');
    Req.AddStr('method', 'notifications/initialized');
    if not ConnSendMsg(C, Req, McpSendMs, Err) then Exit;
  finally
    Req.Free;
  end;
  Conns[C].State := msRunning;
  Result := True;
end;

function McpListTools(C: Integer; out ToolsArr: TJson; out Err: string): Boolean;
var
  Req, Params, Resp, R, Arr: TJson;
  Id, Page, K: Integer;
  Cursor: string;
begin
  Err := '';
  ToolsArr := TJson.NewArr;
  Result := False;
  Cursor := '';
  try
    for Page := 1 to McpMaxListPages do
    begin
      if Cursor = '' then Params := nil
      else
      begin
        Params := TJson.NewObj;
        Params.AddStr('cursor', Cursor);
      end;
      Req := NewRequest(C, 'tools/list', Params, Id);
      try
        if not ConnSendMsg(C, Req, McpSendMs, Err) then Exit;
      finally
        Req.Free;
      end;

      Resp := McpAwait(C, Id, McpListMs, Err);
      if Resp = nil then Exit;
      try
        R := Resp.Find('error');
        if R <> nil then
        begin
          Err := Format('tools/list failed (%d): %s',
            [Round(R.Num('code')), R.Str('message')]);
          Exit;
        end;
        R := Resp.Find('result');
        if (R = nil) or (R.Kind <> jkObj) then
        begin
          Err := 'tools/list answered with no result object';
          Exit;
        end;
        Arr := R.Find('tools');
        { Take detaches by leaving a null placeholder behind, so Count never
          falls: a "while Count > 0 do Take(0)" loop here spins forever and
          allocates while it does it.  Index over the fixed length instead. }
        if (Arr <> nil) and (Arr.Kind = jkArr) then
          for K := 0 to Arr.Count - 1 do ToolsArr.Push(Arr.Take(K));
        Cursor := R.Str('nextCursor');
      finally
        Resp.Free;
      end;
      if Cursor = '' then Break;
    end;
    Result := True;
  finally
    if not Result then
    begin
      ToolsArr.Free;
      ToolsArr := nil;
    end;
  end;
end;

{ Content blocks that are not text become one line saying what was dropped.
  Base64 image data in the transcript would cost thousands of tokens to say
  nothing the model can act on, and a placeholder is at least honest about
  what happened. }
function DescribeBlock(B: TJson): string;
var
  Kind, Mime, Data: string;
begin
  Kind := B.Str('type');
  Mime := B.Str('mimeType');
  Data := B.Str('data');
  if Kind = 'resource_link' then
    Exit(Format('[resource %s]', [B.Str('uri')]));
  if Kind = 'resource' then
    Exit(Format('[embedded resource %s]', [B.Str('uri')]));
  if Mime = '' then Mime := 'unknown type';
  Result := Format('[%s %s, %d bytes]', [Kind, Mime, Length(Data)]);
end;

function AssembleResult(R: TJson; out IsErr: Boolean): string;
var
  Content, B, S: TJson;
  I: Integer;
  Parts: string;
begin
  IsErr := R.Bool('isError');
  Parts := '';
  Content := R.Find('content');
  if (Content <> nil) and (Content.Kind = jkArr) then
    for I := 0 to Content.Count - 1 do
    begin
      B := Content.Item(I);
      if B.Kind <> jkObj then Continue;
      if B.Str('type') = 'text' then
      begin
        if Parts <> '' then Parts := Parts + #10;
        Parts := Parts + B.Str('text');
      end
      else
      begin
        if Parts <> '' then Parts := Parts + #10;
        Parts := Parts + DescribeBlock(B);
      end;
    end;
  if Parts = '' then
  begin
    { Only when content is absent or empty.  A server that sends both means
      the text to be the answer, and structuredContent to be the machine
      form of the same thing - printing both would say everything twice. }
    S := R.Find('structuredContent');
    if S <> nil then Parts := S.ToJson;
  end;
  if Length(Parts) > McpMaxResultBytes then
    Parts := Utf8Cut(Parts, McpMaxResultBytes) +
      #10 + Format('[the server sent more than %d bytes; the rest is cut]',
        [McpMaxResultBytes]);
  Result := Parts;
end;

function McpCallTool(C: Integer; const ToolName: string; Args: TJson;
  TimeoutMs: Integer; out ResultText: string; out IsErr: Boolean;
  out Err: string): Boolean;
var
  Req, Params, Resp, R: TJson;
  Id: Integer;
begin
  ResultText := '';
  IsErr := False;
  Err := '';
  Result := False;

  Params := TJson.NewObj;
  Params.AddStr('name', ToolName);
  { Copied, not adopted: the caller built Args for its own reasons and gets
    to keep it, and a request that shared a subtree with the caller's document
    would be a double-free waiting for the first error path. }
  if Args <> nil then
    Params.Add('arguments', JsonParse(Args.ToJson))
  else
    Params.Add('arguments', TJson.NewObj);

  Req := NewRequest(C, 'tools/call', Params, Id);
  try
    if not ConnSendMsg(C, Req, McpSendMs, Err) then Exit;
  finally
    Req.Free;
  end;

  Resp := McpAwait(C, Id, TimeoutMs, Err);
  if Resp = nil then Exit;
  try
    R := Resp.Find('error');
    if R <> nil then
    begin
      { A protocol-level error is still an answer.  The model gets to see it
        as a failed tool result rather than as a transport failure, because
        "you called it wrong" is something it can act on. }
      IsErr := True;
      ResultText := Format('mcp error %d: %s',
        [Round(R.Num('code')), R.Str('message')]);
      Exit(True);
    end;
    R := Resp.Find('result');
    if (R = nil) or (R.Kind <> jkObj) then
    begin
      Err := 'the server answered the call with no result object';
      Exit;
    end;
    ResultText := AssembleResult(R, IsErr);
    Result := True;
  finally
    Resp.Free;
  end;
end;

finalization
  { A backstop for the paths that skip the host's own shutdown, exactly as
    uTools does for background jobs.  Without it a server survives us. }
  McpShutdownAll;
end.
