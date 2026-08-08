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
  HdrW, HostW, PathW, VerbW, RetryW: WideString;
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
