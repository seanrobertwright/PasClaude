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
  end;

{ POSTs Body to Url.  Headers is a CRLF-separated block ('' for none).
  When OnChunk is non-nil the body is streamed to it and Result.Body stays
  empty unless the status indicates an error, in which case the body is kept
  so the caller can report it. }
function HttpPost(const Url, Headers, Body: string;
  OnChunk: TChunkProc; Ctx: Pointer): THttpResult;

function HttpAvailable: Boolean;

implementation

uses SysUtils;

const
  WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY = 4;
  WINHTTP_FLAG_SECURE                 = $00800000;
  WINHTTP_QUERY_STATUS_CODE           = 19;
  WINHTTP_QUERY_FLAG_NUMBER           = $20000000;
  INTERNET_DEFAULT_HTTPS_PORT         = 443;
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
  Result := Assigned(wOpen) and Assigned(wConnect) and Assigned(wOpenRequest) and
            Assigned(wSendRequest) and Assigned(wReceiveResponse) and
            Assigned(wQueryHeaders) and Assigned(wReadData) and
            Assigned(wCloseHandle);
end;

function HttpAvailable: Boolean;
begin
  Result := LoadWinHttp;
end;

{ Splits https://host/path into its parts.  Only https is supported, which is
  all this program talks. }
function SplitUrl(const Url: string; out Host, Path: string;
  out Port: Word): Boolean;
var
  Rest: string;
  Slash, Colon: Integer;
begin
  Result := False;
  if Copy(Url, 1, 8) <> 'https://' then Exit;
  Rest := Copy(Url, 9, MaxInt);
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
  Port := INTERNET_DEFAULT_HTTPS_PORT;
  Colon := Pos(':', Host);
  if Colon > 0 then
  begin
    Port := Word(StrToIntDef(Copy(Host, Colon + 1, MaxInt), 443));
    Host := Copy(Host, 1, Colon - 1);
  end;
  Result := Host <> '';
end;

function LastErrText: string;
begin
  Result := Format('WinHTTP error %d', [GetLastError]);
end;

function HttpPost(const Url, Headers, Body: string;
  OnChunk: TChunkProc; Ctx: Pointer): THttpResult;
var
  Host, Path: string;
  Port: Word;
  Sess, Conn, Req: Pointer;
  HdrW, HostW, PathW: WideString;
  Status, Len: DWORD;
  Buf: array[0..8191] of Byte;
  Got: DWORD;
  Chunk: string;
  Aborted, IsError: Boolean;
  Timeout: DWORD;
begin
  Result.Ok := False;
  Result.Status := 0;
  Result.Body := '';
  Result.Error := '';

  if not LoadWinHttp then
  begin
    Result.Error := 'winhttp.dll is not available';
    Exit;
  end;
  if not SplitUrl(Url, Host, Path, Port) then
  begin
    Result.Error := 'only https:// URLs are supported: ' + Url;
    Exit;
  end;

  Sess := wOpen('pasclaude/0.1', WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, nil, nil, 0);
  if Sess = nil then
  begin
    Result.Error := LastErrText;
    Exit;
  end;
  try
    { Streamed answers can idle between tokens; the 30s default is too tight. }
    if Assigned(wSetOption) then
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
      Req := wOpenRequest(Conn, 'POST', PWideChar(PathW), nil, nil, nil,
        WINHTTP_FLAG_SECURE);
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
            Result.Body := Result.Body + Chunk
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

finalization
  if Lib <> 0 then
    FreeLibrary(Lib);
end.
