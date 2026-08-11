{ uHttp - HTTPS POST over WinHTTP, with incremental delivery of the body.

  The Anthropic messages endpoint is streamed as server-sent events, so the
  reader hands each chunk to a callback as soon as it arrives instead of
  buffering the whole response.  WinHTTP is bound late (LoadLibrary) so the
  binary keeps running on machines where it is absent - it simply reports the
  failure instead of refusing to start. }
unit uHttp;

{$mode objfpc}{$H+}

interface

uses Windows;

const
  { The most Link header this unit will carry.  GitHub's four-rel Link for a
    paginated list - next, prev, first, last - runs to under about 300 bytes
    even with a long owner and repository name, so 4 KB is an order of
    magnitude of headroom and still a bound a hostile server cannot spend a
    megabyte against.

    A header that does not fit is DROPPED WHOLE, never cut.  That rule is the
    reason the cap can be this small: a truncated Link parses to a URL that is
    nearly right, and a URL that is nearly right is the worst thing an
    untrusted URL can be - it would be a host or a path one character from the
    one the caller checked for. Nothing is better than almost something here. }
  HttpMaxLinkBytes = 4096;

  { Content-Type is a token, a slash, a token and at most a parameter or two.
    Anything past this is not a media type somebody meant, and the same
    drop-whole rule applies for the same reason: half a media type is a media
    type one character from the one the caller tested for. }
  HttpMaxTypeBytes = 256;

type
  { Called for every chunk of body bytes.  Return False to abort the transfer. }
  TChunkProc = function(const Data: string; Ctx: Pointer): Boolean;

  THttpResult = record
    Ok: Boolean;
    Status: Integer;
    Body: string;      { collected when OnChunk is nil }
    Error: string;
    { From the Retry-After response header, in milliseconds; 0 when absent.
      A 429 that names its own wait beats any guess the client makes. }
    RetryAfterMs: Integer;
    { The Link response header, verbatim and unparsed, or '' when absent or
      over HttpMaxLinkBytes.  This unit now reads exactly two headers beyond
      the status - Retry-After and this one - and it reads this one as bytes
      and forms no opinion about them.

      rel= is the caller's dialect, and deliberately so: parsing rel="next"
      here would mean this unit returning a ready-made URL, and a transport
      that hands back a URL has to have a policy about which URLs may be
      requested - which host, which path, which scheme.  That policy belongs
      to whoever knows what it is talking to, and the bottom of the ladder
      knows about no host in particular.  So the bytes go up and the trust
      decision stays up there with them. }
    Link: string;
    { Content-Type, lower-cased and cut at the first ';' so a charset
      parameter does not have to be handled by every caller; '' when absent or
      over HttpMaxTypeBytes.

      A third header, and it earns its place on the same test the other two
      pass: it is a TRANSPORT fact rather than an application one.  Whether a
      body is one JSON document or a stream of server-sent events is a
      question about the bytes, not about what they mean, and the alternative
      is every caller sniffing the first non-space character - which is a
      guess that reads an opening brace at the front of an SSE comment as
      JSON.  (Spelling that character out rather than showing it, because a
      brace inside a brace comment opens a second comment level in FPC and
      eats the terminator - which is exactly how this paragraph first reached
      the compiler.)  This unit still forms no opinion about the value: MCP's
      own two content types are named nowhere in here, and the caller compares
      the string. }
    ContentType: string;
  end;

{ POSTs Body to Url.  Headers is a CRLF-separated block ('' for none).
  When OnChunk is non-nil the body is streamed to it and Result.Body stays
  empty unless the status indicates an error, in which case the body is kept
  so the caller can report it. }
function HttpPost(const Url, Headers, Body: string;
  OnChunk: TChunkProc; Ctx: Pointer): THttpResult;

{ GETs Url and collects the whole body, capped at MaxBytes (0 for no cap).
  Same transport, no streaming callback: the one caller is the fetch tool,
  which wants the document, not the arrival. }
function HttpGet(const Url, Headers: string; MaxBytes: Integer): THttpResult;

function HttpAvailable: Boolean;

type
  { Stands in for the network.  See HttpTransport. }
  TPostProc = function(const Url, Headers, Body: string;
    OnChunk: TChunkProc; Ctx: Pointer): THttpResult;
  TGetProc = function(const Url, Headers: string;
    MaxBytes: Integer): THttpResult;

var
  { When set, requests go here instead of to WinHTTP.  This exists so the
    agent loop can be driven end to end against scripted responses; nothing
    in the shipped program assigns it. }
  HttpTransport: TPostProc = nil;
  { The same seam for GET, used by the fetch tool's tests. }
  HttpGetTransport: TGetProc = nil;

  { Resolve/connect/send/receive timeouts, in milliseconds, for the duration
    of one call.  0 means the behaviour this unit has always had: WinHTTP's
    own defaults with the receive timeout widened to 300s, because a streamed
    answer idles between tokens and 30s truncates long replies.

    Only the telemetry flush sets this, and it restores it in a finally.  A
    collector must never be able to delay a turn, and equally must never be
    able to leave a two-second receive timeout behind on the model's own
    stream - which would surface as a truncated answer and look like a model
    fault rather than a telemetry one. }
  HttpTimeoutMs: Integer = 0;

{ Splits a URL into its parts and says whether the transport must be secure.
  https:// anywhere; http:// ONLY when the host is exactly '127.0.0.1' or
  'localhost'.  That exception exists for one caller - metrics to a collector
  on the same machine, where there is no network to be in the clear on - and
  it is an exact host test rather than a prefix one, because
  '127.0.0.1.evil.com' reading as loopback is the whole difference between a
  narrow exception and a hole.  A bracketed IPv6 literal is refused: the colon
  scan below cannot parse one and guessing would be worse.

  Exposed so it can be tested directly.  SplitUrl below is the unchanged
  https-only contract every other caller in this program still uses. }
function SplitUrlEx(const Url: string; out Host, Path: string;
  out Port: Word; out Secure: Boolean): Boolean;

implementation

uses SysUtils;

const
  WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY = 4;
  WINHTTP_FLAG_SECURE                 = $00800000;
  WINHTTP_QUERY_STATUS_CODE           = 19;
  WINHTTP_QUERY_RETRY_AFTER           = 35;
  { Query a header by name: the name goes in pwszName, the value comes back in
    lpBuffer. }
  WINHTTP_QUERY_CUSTOM                = 65;
  WINHTTP_QUERY_FLAG_NUMBER           = $20000000;
  INTERNET_DEFAULT_HTTPS_PORT         = 443;
  INTERNET_DEFAULT_HTTP_PORT          = 80;
  WINHTTP_OPTION_RECEIVE_TIMEOUT      = 6;

type
  TWinHttpOpen = function(pszAgentW: PWideChar; dwAccessType: DWORD;
    pszProxyW, pszProxyBypassW: PWideChar; dwFlags: DWORD): Pointer; stdcall;
  TWinHttpConnect = function(hSession: Pointer; pswzServerName: PWideChar;
    nServerPort: Word; dwReserved: DWORD): Pointer; stdcall;
  TWinHttpOpenRequest = function(hConnect: Pointer;
    pwszVerb, pwszObjectName, pwszVersion, pwszReferrer: PWideChar;
    ppwszAcceptTypes: Pointer; dwFlags: DWORD): Pointer; stdcall;
  TWinHttpSendRequest = function(hRequest: Pointer; pwszHeaders: PWideChar;
    dwHeadersLength: DWORD; lpOptional: Pointer;
    dwOptionalLength, dwTotalLength: DWORD; dwContext: PtrUInt): BOOL; stdcall;
  TWinHttpReceiveResponse = function(hRequest: Pointer; lpReserved: Pointer): BOOL; stdcall;
  TWinHttpQueryHeaders = function(hRequest: Pointer; dwInfoLevel: DWORD;
    pwszName: PWideChar; lpBuffer: Pointer; var lpdwBufferLength: DWORD;
    lpdwIndex: Pointer): BOOL; stdcall;
  TWinHttpReadData = function(hRequest: Pointer; lpBuffer: Pointer;
    dwNumberOfBytesToRead: DWORD; var lpdwNumberOfBytesRead: DWORD): BOOL; stdcall;
  TWinHttpCloseHandle = function(hInternet: Pointer): BOOL; stdcall;
  TWinHttpSetOption = function(hInternet: Pointer; dwOption: DWORD;
    lpBuffer: Pointer; dwBufferLength: DWORD): BOOL; stdcall;
  TWinHttpCrackUrl = function(pwszUrl: PWideChar; dwUrlLength, dwFlags: DWORD;
    lpUrlComponents: Pointer): BOOL; stdcall;
  TWinHttpSetTimeouts = function(hInternet: Pointer;
    nResolveTimeout, nConnectTimeout, nSendTimeout,
    nReceiveTimeout: Integer): BOOL; stdcall;

var
  Lib: HMODULE = 0;
  wOpen: TWinHttpOpen;
  wConnect: TWinHttpConnect;
  wOpenRequest: TWinHttpOpenRequest;
  wSendRequest: TWinHttpSendRequest;
  wReceiveResponse: TWinHttpReceiveResponse;
  wQueryHeaders: TWinHttpQueryHeaders;
  wReadData: TWinHttpReadData;
  wCloseHandle: TWinHttpCloseHandle;
  wSetOption: TWinHttpSetOption;
  { Resolved optionally, exactly as wSetOption is: its absence must never be
    what makes LoadWinHttp fail, because the program works without it. }
  wSetTimeouts: TWinHttpSetTimeouts;

function LoadWinHttp: Boolean;
begin
  if Lib <> 0 then Exit(True);
  Lib := LoadLibraryW('winhttp.dll');
  if Lib = 0 then Exit(False);
  Pointer(wOpen) := GetProcAddress(Lib, 'WinHttpOpen');
  Pointer(wConnect) := GetProcAddress(Lib, 'WinHttpConnect');
  Pointer(wOpenRequest) := GetProcAddress(Lib, 'WinHttpOpenRequest');
  Pointer(wSendRequest) := GetProcAddress(Lib, 'WinHttpSendRequest');
  Pointer(wReceiveResponse) := GetProcAddress(Lib, 'WinHttpReceiveResponse');
  Pointer(wQueryHeaders) := GetProcAddress(Lib, 'WinHttpQueryHeaders');
  Pointer(wReadData) := GetProcAddress(Lib, 'WinHttpReadData');
  Pointer(wCloseHandle) := GetProcAddress(Lib, 'WinHttpCloseHandle');
  Pointer(wSetOption) := GetProcAddress(Lib, 'WinHttpSetOption');
  Pointer(wSetTimeouts) := GetProcAddress(Lib, 'WinHttpSetTimeouts');
  Result := Assigned(wOpen) and Assigned(wConnect) and Assigned(wOpenRequest) and
            Assigned(wSendRequest) and Assigned(wReceiveResponse) and
            Assigned(wQueryHeaders) and Assigned(wReadData) and
            Assigned(wCloseHandle);
end;

function HttpAvailable: Boolean;
begin
  Result := LoadWinHttp;
end;

function SplitUrlEx(const Url: string; out Host, Path: string;
  out Port: Word; out Secure: Boolean): Boolean;
var
  Rest: string;
  Slash, Colon: Integer;
begin
  Result := False;
  Secure := False;
  if Copy(Url, 1, 8) = 'https://' then
  begin
    Secure := True;
    Rest := Copy(Url, 9, MaxInt);
  end
  else if Copy(Url, 1, 7) = 'http://' then
    Rest := Copy(Url, 8, MaxInt)
  else
    Exit;
  Slash := Pos('/', Rest);
  if Slash = 0 then
  begin
    Host := Rest;
    Path := '/';
  end
  else
  begin
    Host := Copy(Rest, 1, Slash - 1);
    Path := Copy(Rest, Slash, MaxInt);
  end;
  { A bracketed IPv6 host would be shredded by the colon scan below. }
  if (Host <> '') and (Host[1] = '[') then Exit;
  if Secure then
    Port := INTERNET_DEFAULT_HTTPS_PORT
  else
    Port := INTERNET_DEFAULT_HTTP_PORT;
  Colon := Pos(':', Host);
  if Colon > 0 then
  begin
    Port := Word(StrToIntDef(Copy(Host, Colon + 1, MaxInt), Port));
    Host := Copy(Host, 1, Colon - 1);
  end;
  if Host = '' then Exit;
  { Plaintext leaves this function only for a loopback literal. }
  if (not Secure) and (Host <> '127.0.0.1') and
     (LowerCase(Host) <> 'localhost') then Exit;
  Result := True;
end;

{ The unchanged contract: https only, Result False for anything else.  Every
  caller but the telemetry flush comes through here, so the loopback exception
  above cannot reach the Anthropic request path even by accident. }
function SplitUrl(const Url: string; out Host, Path: string;
  out Port: Word): Boolean;
var
  Secure: Boolean;
begin
  Result := SplitUrlEx(Url, Host, Path, Port, Secure) and Secure;
end;

function LastErrText: string;
begin
  Result := Format('WinHTTP error %d', [GetLastError]);
end;

{ One request over WinHTTP, shared by POST (streamed) and GET (collected).
  Verb decides which; a GET sends no body and ignores OnChunk. }
function HttpExec(const Verb, Url, Headers, Body: string;
  OnChunk: TChunkProc; Ctx: Pointer; MaxBytes: Integer): THttpResult;
var
  Host, Path: string;
  Port: Word;
  Sess, Conn, Req: Pointer;
  HdrW, HostW, PathW, VerbW, RetryW, LinkW, TypeW, NameW: WideString;
  Status, Len: DWORD;
  Buf: array[0..8191] of Byte;
  Got: DWORD;
  Chunk: string;
  Aborted, IsError, Secure: Boolean;
  Timeout: DWORD;
  ReqFlags: DWORD;
  RetrySecs: Integer;
begin
  Result.Ok := False;
  Result.Status := 0;
  Result.Body := '';
  Result.Error := '';
  Result.RetryAfterMs := 0;
  Result.Link := '';
  Result.ContentType := '';

  if not LoadWinHttp then
  begin
    Result.Error := 'winhttp.dll is not available';
    Exit;
  end;
  if not SplitUrlEx(Url, Host, Path, Port, Secure) then
  begin
    Result.Error := 'only https:// URLs are supported (http:// is accepted ' +
      'for a collector on 127.0.0.1 or localhost, where there is no network ' +
      'to be in the clear on): ' + Url;
    Exit;
  end;

  Sess := wOpen('pasclaude/0.1', WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, nil, nil, 0);
  if Sess = nil then
  begin
    Result.Error := LastErrText;
    Exit;
  end;
  try
    { Streamed answers can idle between tokens; the 30s default is too tight.
      A caller that set HttpTimeoutMs is saying the opposite - it would rather
      give up than wait - and gets all four timeouts at that value instead. }
    if (HttpTimeoutMs > 0) and Assigned(wSetTimeouts) then
      wSetTimeouts(Sess, HttpTimeoutMs, HttpTimeoutMs, HttpTimeoutMs,
        HttpTimeoutMs)
    else if Assigned(wSetOption) then
    begin
      Timeout := 300000;
      wSetOption(Sess, WINHTTP_OPTION_RECEIVE_TIMEOUT, @Timeout, SizeOf(Timeout));
    end;

    HostW := UTF8Decode(Host);
    Conn := wConnect(Sess, PWideChar(HostW), Port, 0);
    if Conn = nil then
    begin
      Result.Error := LastErrText;
      Exit;
    end;
    try
      PathW := UTF8Decode(Path);
      VerbW := UTF8Decode(Verb);
      { The flag comes from the parsed scheme and from nothing else: https://
        is the only scheme SplitUrlEx marks secure, so an Anthropic request
        cannot lose TLS through this branch. }
      if Secure then ReqFlags := WINHTTP_FLAG_SECURE else ReqFlags := 0;
      Req := wOpenRequest(Conn, PWideChar(VerbW), PWideChar(PathW), nil, nil, nil,
        ReqFlags);
      if Req = nil then
      begin
        Result.Error := LastErrText;
        Exit;
      end;
      try
        HdrW := UTF8Decode(Headers);
        if not wSendRequest(Req, PWideChar(HdrW), DWORD(Length(HdrW)),
          Pointer(Body), DWORD(Length(Body)), DWORD(Length(Body)), 0) then
        begin
          Result.Error := LastErrText;
          Exit;
        end;
        if not wReceiveResponse(Req, nil) then
        begin
          Result.Error := LastErrText;
          Exit;
        end;

        Status := 0;
        Len := SizeOf(Status);
        if wQueryHeaders(Req, WINHTTP_QUERY_STATUS_CODE or WINHTTP_QUERY_FLAG_NUMBER,
          nil, @Status, Len, nil) then
          Result.Status := Integer(Status);

        { Retry-After arrives as text - it may be a date, which is ignored;
          the delta-seconds form is what rate limits actually send. }
        SetLength(RetryW, 32);
        Len := Length(RetryW) * SizeOf(WideChar);
        if wQueryHeaders(Req, WINHTTP_QUERY_RETRY_AFTER, nil,
          PWideChar(RetryW), Len, nil) then
        begin
          SetLength(RetryW, Len div SizeOf(WideChar));
          RetrySecs := StrToIntDef(Trim(UTF8Encode(RetryW)), 0);
          { Clamped: a server asking for an hour is answered by giving up,
            not by an unkillable hour-long sleep. }
          if RetrySecs > 60 then RetrySecs := 60;
          if RetrySecs > 0 then
            Result.RetryAfterMs := RetrySecs * 1000;
        end;

        { Link, by name.  WINHTTP_QUERY_CUSTOM was chosen over
          WINHTTP_QUERY_RAW_HEADERS_CRLF because the raw query hands back the
          entire response header block - Set-Cookie and everything else a
          server felt like sending - which would then need a header-block
          parser HERE, in the unit that is supposed to know least, to get one
          value back out, and would force a cap large enough to hold a whole
          header block rather than one header.  That is the opposite of
          bounding.  Asking for one header by name is one call and one value.

          No index pointer is passed, so this is the FIRST Link header if a
          server sent several; GitHub sends one.  An oversized header makes
          the call fail rather than fill the buffer, which leaves Link empty -
          that is the cap doing its job, and it is why there is no retry on
          ERROR_INSUFFICIENT_BUFFER: growing the buffer would be undoing the
          bound we just set. }
        NameW := 'Link';
        { HttpMaxLinkBytes WideChars plus one, and the arithmetic is the point:
          the cap is stated in BYTES of UTF-8 and this buffer is measured in
          UTF-16 units, so sizing it at `div SizeOf(WideChar)` would have
          enforced half the documented cap - and the +1 is the terminating NUL,
          which WinHttpQueryHeaders needs room for inside lpdwBufferLength or
          it fails the whole call.  No UTF-8 encoding of a string is shorter
          than its UTF-16 unit count, so anything that survives the byte check
          below fits here, and anything that does not fit here was over the cap
          in bytes as well.  The buffer is 8 KB of stack-free WideString for
          the length of one call; the bound the constant names is the one
          actually enforced, on the bytes the caller sees. }
        SetLength(LinkW, HttpMaxLinkBytes + 1);
        Len := DWORD(Length(LinkW) * SizeOf(WideChar));
        if wQueryHeaders(Req, WINHTTP_QUERY_CUSTOM, PWideChar(NameW),
          PWideChar(LinkW), Len, nil) then
        begin
          SetLength(LinkW, Len div SizeOf(WideChar));
          Result.Link := UTF8Encode(LinkW);
          { UTF-8 can be longer in bytes than the widechar count that fitted,
            so the cap is re-checked on the bytes the caller will actually
            see, and again the answer to too long is nothing rather than a
            prefix. }
          if Length(Result.Link) > HttpMaxLinkBytes then Result.Link := '';
        end;

        { Content-Type, by the same call and the same rules.  Lower-cased and
          cut at the ';' here rather than in the caller, because every caller
          would otherwise write the same two lines and one of them would
          eventually forget the charset parameter - `text/event-stream;
          charset=utf-8` is a stream, and a caller comparing the whole string
          for equality would decide it was not. }
        NameW := 'Content-Type';
        SetLength(TypeW, HttpMaxTypeBytes + 1);
        Len := DWORD(Length(TypeW) * SizeOf(WideChar));
        if wQueryHeaders(Req, WINHTTP_QUERY_CUSTOM, PWideChar(NameW),
          PWideChar(TypeW), Len, nil) then
        begin
          SetLength(TypeW, Len div SizeOf(WideChar));
          Result.ContentType := LowerCase(Trim(UTF8Encode(TypeW)));
          if Length(Result.ContentType) > HttpMaxTypeBytes then
            Result.ContentType := ''
          else if Pos(';', Result.ContentType) > 0 then
            Result.ContentType :=
              Trim(Copy(Result.ContentType, 1, Pos(';', Result.ContentType) - 1));
        end;

        { On a non-2xx the body is an error document, not a stream, so it is
          collected whole for the caller to show. }
        IsError := (Result.Status < 200) or (Result.Status > 299);
        Aborted := False;
        repeat
          Got := 0;
          if not wReadData(Req, @Buf[0], SizeOf(Buf), Got) then
          begin
            Result.Error := LastErrText;
            Exit;
          end;
          if Got = 0 then Break;
          SetString(Chunk, PAnsiChar(@Buf[0]), Got);
          if IsError or not Assigned(OnChunk) then
          begin
            Result.Body := Result.Body + Chunk;
            { A caller with a cap wants the front of the document, not an
              unbounded slurp of one; the transfer stops once it is spent. }
            if (MaxBytes > 0) and (Length(Result.Body) >= MaxBytes) then
            begin
              SetLength(Result.Body, MaxBytes);
              Break;
            end;
          end
          else if not OnChunk(Chunk, Ctx) then
          begin
            Aborted := True;
            Break;
          end;
        until False;

        Result.Ok := not IsError;
        if IsError and (Result.Error = '') then
          Result.Error := Format('HTTP %d', [Result.Status]);
        if Aborted then
          Result.Error := 'aborted';
      finally
        wCloseHandle(Req);
      end;
    finally
      wCloseHandle(Conn);
    end;
  finally
    wCloseHandle(Sess);
  end;
end;

function HttpPost(const Url, Headers, Body: string;
  OnChunk: TChunkProc; Ctx: Pointer): THttpResult;
begin
  { A substituted transport takes the whole call, so the code above it runs
    unchanged. }
  if Assigned(HttpTransport) then
    Exit(HttpTransport(Url, Headers, Body, OnChunk, Ctx));
  Result := HttpExec('POST', Url, Headers, Body, OnChunk, Ctx, 0);
end;

function HttpGet(const Url, Headers: string; MaxBytes: Integer): THttpResult;
begin
  if Assigned(HttpGetTransport) then
    Exit(HttpGetTransport(Url, Headers, MaxBytes));
  Result := HttpExec('GET', Url, Headers, '', nil, nil, MaxBytes);
end;

finalization
  if Lib <> 0 then
    FreeLibrary(Lib);
end.
