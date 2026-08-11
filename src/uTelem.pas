{ uTelem - opt-in usage metrics, exported as OTLP/HTTP with JSON encoding.

  THE FORMAT, ESTABLISHED RATHER THAN ASSUMED.  OTLP defines two encodings for
  its HTTP transport.  Binary protobuf is the common one and is refused here
  under the same rule that refused fcl-hash and paszlib: hand-writing a
  protobuf wire encoder is a dependency we would then own forever.  The JSON
  encoding is fully specified and the metrics path is a plain POST, which
  uHttp already does.  From https://opentelemetry.io/docs/specs/otlp/ :

    * the default metrics path is  /v1/metrics
    * "The client and the server MUST set 'Content-Type: application/json'"
    * "The keys of JSON objects are field names converted to lowerCamelCase.
      Original field names are not valid to use as keys" - so snake_case is
      not merely unusual here, it is invalid
    * "Values of enum fields MUST be encoded as integer values" - hence the
      literal 1 for DELTA, never 'AGGREGATION_TEMPORALITY_DELTA'
    * 64-bit integers are encoded as DECIMAL STRINGS
    * a 200 whose partialSuccess is populated MUST NOT be retried
    * the retryable statuses are 429, 502, 503 and 504

  JSON is OPTIONAL in the spec.  The Collector's standard otlp receiver
  accepts it on the same port as protobuf, multiplexed by Content-Type, so
  this is not an exotic path - but a vendor endpoint that speaks protobuf only
  will answer with an opaque 400 or 415, so /telemetry names the encoding and
  the last status rather than leaving the user to guess.

  DELTA temporality (=1) rather than CUMULATIVE, because a process that can be
  Ctrl+C'd at any moment must not owe a collector a running series.  Each flush
  reports what happened since the last one and then forgets it.

  WHAT THIS UNIT MAY NOT DO.  It never reads a file: its configuration arrives
  as a record, and the only parser it owns takes BYTES, which is uTerm's
  KeysParse rule (uTerm:1611) applied to the one surface where getting the
  scope wrong would be worst.  It never reads a credential, never sees a
  prompt, a completion, a tool argument, a tool result or a path, and the
  payload builder is the only thing that can put a string on the wire - which
  is why the two strings that do reach it, the tool name and the model name,
  go through allowlist filters rather than trust.  It never uses uTerm and
  never prints; the host reports for it. }
unit uTelem;

{$mode objfpc}{$H+}

interface

uses SysUtils, uJson;

type
  { The whole of the configuration, handed in by the host.  The six keys it
    comes from are scUserOnly in uSettings.SettingDefs - a project file that
    names one is refused by name and the value is never stored - so this
    record cannot be reached from anything in a project tree. }
  TTelemConfig = record
    Enabled: Boolean;
    Endpoint: string;
    ServiceName: string;
    ServiceVersion: string;      { the host's Version const; not duplicated }
    HeaderNames: TStringArray;
    HeaderValues: TStringArray;
    IntervalTurns: Integer;
    TimeoutMs: Integer;
    Notes: TStringArray;         { every reason something was refused }
  end;

  { What /telemetry shows.  A record rather than a formatted string so the
    host owns the words and this unit owns the facts. }
  TTelemState = record
    Enabled: Boolean;
    SelfDisabled: Boolean;
    Endpoint: string;            { the URL that would actually be POSTed to }
    ServiceName: string;
    IntervalTurns: Integer;
    TimeoutMs: Integer;
    TurnsBuffered: Integer;
    ConsecFailures: Integer;
    LastStatus: Integer;
    LastError: string;
    HasData: Boolean;
  end;

const
  { The path OTLP names for metrics, appended when the endpoint is a bare
    base URL.  A user who wrote a full path keeps it. }
  TelemMetricsPath = '/v1/metrics';

  { AggregationTemporality.DELTA.  An integer because the spec says enums are
    integers, and named here so the payload builder cannot drift. }
  TelemDelta = 1;

  { Three failures and telemetry goes quiet for the rest of the process.  A
    collector that is down must cost the user its timeout a bounded number of
    times, not once per interval forever. }
  TelemMaxFailures = 3;

  { Cardinality ceilings.  Tool names are bucketed to a compile-time list so
    that one is already bounded; the model string is not - LoadSession
    restores it from session.json in the PROJECT tree - so a hostile repo
    could otherwise grow the payload one row per turn. }
  TelemMaxModels = 16;

{ A configuration with every default in it: off, no endpoint, 'pasclaude',
  every ten turns, two seconds. }
function  TelemDefaultConfig: TTelemConfig;

{ Reads the six telemetry keys out of the LOADED settings store.  The host
  calls this after uSettings.SettingsLoad; it takes no path and no tier,
  because the tier question was answered in SettingDefs. }
function  TelemConfigFromSettings(const AServiceVersion: string): TTelemConfig;

{ The test seam: parse Bytes as a USER-tier settings document and return the
  telemetry configuration it asks for.  Bytes, never a path, so a suite can
  drive the whole feature with no filesystem.  It REPLACES the settings store
  (uSettings.SettingsClear first), which is why the shipped program does not
  call it - the host has already loaded three tiers by the time telemetry
  starts.  A caller is expected to SettingsClear afterwards. }
function  TelemParse(const Bytes: string): TTelemConfig;

{ https anywhere; http for 127.0.0.1 and localhost only.  Plaintext to a real
  host would put the payload and any collector token in the clear on somebody
  else's network, and loopback is the case a collector actually runs in. }
function  TelemValidEndpoint(const U: string; out Why: string): Boolean;

procedure TelemInit(const C: TTelemConfig);

{ Every reason something in the configuration did not take: the notes the
  parser produced plus any TelemInit added of its own.  Read back out of the
  unit rather than off the record handed in, because TelemInit copies - a
  caller that printed C.Notes would miss the refusals that matter most, which
  are the ones about the endpoint and the headers. }
function  TelemNotes: TStringArray;
function  TelemEnabled: Boolean;
function  TelemState: TTelemState;

{ Takes the agent's CUMULATIVE totals and keeps the deltas.  Cumulative in,
  delta out, because the caller has running totals and the wire wants
  differences - and because LoadSession can restore those totals DOWNWARD out
  of a project file, which is handled by clamping to zero and re-baselining
  rather than by putting a negative counter on the wire. }
procedure TelemRecordTurn(TokensIn, TokensOut, CacheRead, CacheWrite: Int64;
  const Model: string);
{ The baseline the deltas are measured from, moved by the HOST at the moment a
  session's counters change without a turn happening - immediately after
  LoadSession or SdkResumeInto and nowhere else.  A fresh session starts at
  zero and needs no call: that is why TelemInit sets the baseline rather than
  the first TelemRecordTurn: baselining lazily on the first record threw away
  the first turn of every session, and a -p run has exactly one turn, so
  scripted runs reported no tokens at all, forever. }
procedure TelemBaseline(TokensIn, TokensOut, CacheRead, CacheWrite: Int64);
procedure TelemRecordTool(const Name: string; IsError: Boolean);
procedure TelemRecordRequest(StatusCode, ElapsedMs: Integer);

function  TelemDueForFlush: Boolean;

{ The ONE builder.  /telemetry preview and the sender call this same function,
  so "read the payload before you trust it" is a fact about the code rather
  than a promise about a description of it. }
function  TelemBuildPayload(Pretty: Boolean): string;

function  TelemHeaderBlock: string;
function  TelemHeaderBlockRedacted: string;   { names and value lengths only }

{ One request, no retry inside it, batch discarded either way.  Sets and
  restores uHttp.HttpTimeoutMs around the call. }
function  TelemFlush(out Status: Integer; out Err: string): Boolean;

{ Final attempt at exit; safe when disabled or empty. }
procedure TelemShutdown;

{ Test seams for the two filters that stand between a project-controlled
  string and the wire. }
function  TelemBucketTool(const Name: string): string;
function  TelemSafeModel(const M: string): string;

implementation

uses Windows, uHttp, uSettings;

const
  { Every tool compiled into this program.  The bucket is an ALLOWLIST and not
    a denylist because MCP tool names come from .mcp.json and subagent types
    from .pasclaude\agents, both of which arrive with a clone: a repository
    that could name a tool after its own secret would have a channel.  A
    thirteenth built-in added later reports as 'other' until somebody adds it
    here, which fails safe - over-bucketing, never over-disclosure - and
    TestToolAllowlistCoversTheLiveSet catches the drift at build time. }
  BuiltinTools: array[0..12] of string = (
    'read_file', 'list_dir', 'search', 'write_file', 'edit_file',
    'bash', 'bash_output', 'kill_bash', 'fetch', 'todo_write',
    'notebook_edit', 'skill', 'task');

type
  TTokenRow = record
    Model: string;
    TokIn, TokOut, CacheRead, CacheWrite: Int64;
  end;
  TToolRow = record
    Tool: string;
    IsError: Boolean;
    Count: Int64;
  end;
  TReqRow = record
    Bucket: string;
    Count: Int64;
  end;

var
  Cfg: TTelemConfig;
  Active: Boolean = False;
  SelfDisabled: Boolean = False;
  ConsecFail: Integer = 0;
  LastStatus: Integer = 0;
  LastError: string = '';
  TurnsSince: Integer = 0;

  { The buffer.  All of it is discarded on a flush, successful or not. }
  Turns: Int64 = 0;
  DurationMs: Int64 = 0;
  TokenRows: array of TTokenRow;
  ToolRows: array of TToolRow;
  ReqRows: array of TReqRow;
  IntervalStartNs: Int64 = 0;

{ ------------------------------------------------------------------ time -- }

{ Unix nanoseconds.  FILETIME counts 100ns ticks from 1601; the constant is
  the gap to 1970 in those ticks. }
function NowUnixNanos: Int64;
var
  Ft: TFileTime;
  Q: Int64;
begin
  GetSystemTimeAsFileTime(Ft);
  Q := (Int64(Ft.dwHighDateTime) shl 32) or Int64(Ft.dwLowDateTime);
  Result := (Q - 116444736000000000) * 100;
end;

{ ----------------------------------------------------------- the filters -- }

function TelemBucketTool(const Name: string): string;
var
  I: Integer;
begin
  for I := 0 to High(BuiltinTools) do
    if Name = BuiltinTools[I] then Exit(Name);
  { The one namespace MCP tools live in (uTools.McpNamePrefix).  Named, not
    identified: knowing a call went to some MCP server is useful, knowing
    WHICH server is the project's business and not the collector's. }
  if Copy(Name, 1, 5) = 'mcp__' then Exit('mcp');
  Result := 'other';
end;

{ ^[a-z0-9][a-z0-9._-]{0,63}$ and a 'claude-' prefix, or the literal 'other'.
  uAgent.LoadSession overrides FModel from session.json, which lives in the
  project tree, so this string is project-influenced even though it looks like
  ours.  The filter is the enforcement; a comment asking people not to put
  secrets in a model name would not be. }
function TelemSafeModel(const M: string): string;
var
  I: Integer;
begin
  Result := 'other';
  if (M = '') or (Length(M) > 64) then Exit;
  if Copy(M, 1, 7) <> 'claude-' then Exit;
  if not (M[1] in ['a'..'z', '0'..'9']) then Exit;
  for I := 2 to Length(M) do
    if not (M[I] in ['a'..'z', '0'..'9', '.', '_', '-']) then Exit;
  Result := M;
end;

{ The service name is the one resource attribute the user chooses.  Same shape
  as a model id so a paste accident cannot become a label. }
function SafeService(const S: string): string;
var
  I: Integer;
begin
  Result := 'pasclaude';
  if (S = '') or (Length(S) > 64) then Exit;
  if not (S[1] in ['a'..'z', '0'..'9']) then Exit;
  for I := 2 to Length(S) do
    if not (S[I] in ['a'..'z', '0'..'9', '.', '_', '-']) then Exit;
  Result := S;
end;

{ A header value carrying CR or LF splits the request and NUL truncates it,
  which is request smuggling through a file the user edits by hand.  The check
  is on the bytes, not on intent. }
function HeaderTextOk(const S: string): Boolean;
var
  I: Integer;
begin
  Result := S <> '';
  for I := 1 to Length(S) do
    if (S[I] < #32) or (S[I] > #126) then Exit(False);
end;

function TelemValidEndpoint(const U: string; out Why: string): Boolean;
var
  Rest, Host: string;
  P: Integer;
begin
  Why := '';
  Result := False;
  if U = '' then
  begin
    Why := 'no endpoint';
    Exit;
  end;
  if Length(U) > 512 then
  begin
    Why := 'longer than 512 bytes';
    Exit;
  end;
  { CR, LF and NUL in a URL are request splitting one layer down. }
  if not HeaderTextOk(U) then
  begin
    Why := 'contains a control character or a non-ASCII byte';
    Exit;
  end;
  if Copy(U, 1, 8) = 'https://' then
    Rest := Copy(U, 9, MaxInt)
  else if Copy(U, 1, 7) = 'http://' then
    Rest := Copy(U, 8, MaxInt)
  else
  begin
    Why := 'must begin with https:// (or http:// for a loopback collector)';
    Exit;
  end;
  P := Pos('/', Rest);
  if P > 0 then Host := Copy(Rest, 1, P - 1) else Host := Rest;
  if Host = '' then
  begin
    Why := 'no host';
    Exit;
  end;
  { The colon scan below cannot parse a bracketed IPv6 literal, and guessing
    would be worse than refusing. }
  if Host[1] = '[' then
  begin
    Why := 'bracketed IPv6 addresses are not supported';
    Exit;
  end;
  P := Pos(':', Host);
  if P > 0 then Host := Copy(Host, 1, P - 1);
  if Copy(U, 1, 8) = 'https://' then Exit(True);
  { Exact hosts, never a prefix or a suffix test: '127.0.0.1.evil.com' must
    not read as loopback, and that is the whole of the difference between a
    narrow exception and a hole. }
  Result := (Host = '127.0.0.1') or (LowerCase(Host) = 'localhost');
  if not Result then
    Why := 'http:// is accepted for 127.0.0.1 and localhost only';
end;

{ The URL actually POSTed to.  A bare base URL gets OTLP's documented metrics
  path; a URL that already has one is left exactly as written. }
function TargetUrl: string;
var
  Rest: string;
  P: Integer;
begin
  Result := Cfg.Endpoint;
  if Copy(Result, 1, 8) = 'https://' then Rest := Copy(Result, 9, MaxInt)
  else Rest := Copy(Result, 8, MaxInt);
  P := Pos('/', Rest);
  if (P = 0) or (P = Length(Rest)) then
  begin
    if P = Length(Rest) then SetLength(Result, Length(Result) - 1);
    Result := Result + TelemMetricsPath;
  end;
end;

{ ------------------------------------------------------------ the config -- }

procedure NoteAdd(var A: TStringArray; const S: string);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)] := S;
end;

function TelemDefaultConfig: TTelemConfig;
begin
  Result.Enabled := False;
  Result.Endpoint := '';
  Result.ServiceName := 'pasclaude';
  Result.ServiceVersion := '0.1';
  Result.HeaderNames := nil;
  Result.HeaderValues := nil;
  Result.IntervalTurns := 10;
  Result.TimeoutMs := 2000;
  Result.Notes := nil;
end;

function TelemConfigFromSettings(const AServiceVersion: string): TTelemConfig;
var
  K, V: TStringArray;
  I: Integer;
begin
  Result := TelemDefaultConfig;
  if AServiceVersion <> '' then Result.ServiceVersion := AServiceVersion;
  Result.Enabled := uSettings.SettingBool('telemetry.enabled');
  Result.Endpoint := Trim(uSettings.SettingStr('telemetry.endpoint'));
  if uSettings.SettingIsSet('telemetry.service_name') then
    Result.ServiceName := uSettings.SettingStr('telemetry.service_name');
  if uSettings.SettingIsSet('telemetry.interval_turns') then
    Result.IntervalTurns := uSettings.SettingInt('telemetry.interval_turns');
  if uSettings.SettingIsSet('telemetry.timeout_ms') then
    Result.TimeoutMs := uSettings.SettingInt('telemetry.timeout_ms');
  if uSettings.SettingMap('telemetry.headers', K, V) then
    for I := 0 to High(K) do
    begin
      NoteAdd(Result.HeaderNames, K[I]);
      NoteAdd(Result.HeaderValues, V[I]);
    end;
end;

function TelemParse(const Bytes: string): TTelemConfig;
var
  Problems: TStringArray;
  I: Integer;
begin
  uSettings.SettingsClear;
  uSettings.SettingsParseTier(stUser, Bytes, 'settings.json', Problems);
  Result := TelemConfigFromSettings('0.1');
  for I := 0 to High(Problems) do
    NoteAdd(Result.Notes, Problems[I]);
end;

{ ------------------------------------------------------------ the buffer -- }

procedure ResetBuffer;
begin
  Turns := 0;
  DurationMs := 0;
  TokenRows := nil;
  ToolRows := nil;
  ReqRows := nil;
  TurnsSince := 0;
  IntervalStartNs := NowUnixNanos;
end;

function HasData: Boolean;
begin
  Result := (Turns > 0) or (Length(TokenRows) > 0) or
            (Length(ToolRows) > 0) or (Length(ReqRows) > 0);
end;

var
  { The baselines TelemRecordTurn differences against.  Not part of the buffer
    - a flush must not make the next turn look like the whole session.  Set at
    init to zero, which is where a fresh agent's counters start, and moved
    only by TelemBaseline. }
  BaseIn, BaseOut, BaseCR, BaseCW: Int64;

procedure TelemInit(const C: TTelemConfig);
var
  Why: string;
  I: Integer;
begin
  Cfg := C;
  Cfg.ServiceName := SafeService(Cfg.ServiceName);
  if Cfg.IntervalTurns < 1 then Cfg.IntervalTurns := 1;
  if Cfg.IntervalTurns > 100 then Cfg.IntervalTurns := 100;
  if Cfg.TimeoutMs < 250 then Cfg.TimeoutMs := 250;
  if Cfg.TimeoutMs > 5000 then Cfg.TimeoutMs := 5000;

  SelfDisabled := False;
  ConsecFail := 0;
  LastStatus := 0;
  LastError := '';
  BaseIn := 0; BaseOut := 0; BaseCR := 0; BaseCW := 0;
  ResetBuffer;

  { Both halves are required and either alone sends nothing: enabling without
    an endpoint is a user who meant to and did not finish, and an endpoint
    without enabling is a user who wrote one down. }
  Active := False;
  if not Cfg.Enabled then Exit;
  if not TelemValidEndpoint(Cfg.Endpoint, Why) then
  begin
    NoteAdd(Cfg.Notes, 'telemetry.endpoint ' + Why + '; telemetry is off');
    Exit;
  end;
  { A header the transport would refuse is dropped here rather than silently
    concatenated, and named so the user knows it did not take. }
  for I := 0 to High(Cfg.HeaderNames) do
    if (not HeaderTextOk(Cfg.HeaderNames[I])) or
       (not HeaderTextOk(Cfg.HeaderValues[I])) or
       (Pos(':', Cfg.HeaderNames[I]) > 0) or
       (CompareText(Cfg.HeaderNames[I], 'content-type') = 0) then
      NoteAdd(Cfg.Notes, 'telemetry.headers: "' + Cfg.HeaderNames[I] +
        '" is not a header this can send; ignored');
  Active := True;
end;

function TelemNotes: TStringArray;
begin
  Result := Cfg.Notes;
end;

function TelemEnabled: Boolean;
begin
  Result := Active;
end;

function TelemState: TTelemState;
begin
  Result.Enabled := Active;
  Result.SelfDisabled := SelfDisabled;
  if Active then Result.Endpoint := TargetUrl else Result.Endpoint := Cfg.Endpoint;
  Result.ServiceName := Cfg.ServiceName;
  Result.IntervalTurns := Cfg.IntervalTurns;
  Result.TimeoutMs := Cfg.TimeoutMs;
  Result.TurnsBuffered := TurnsSince;
  Result.ConsecFailures := ConsecFail;
  Result.LastStatus := LastStatus;
  Result.LastError := LastError;
  Result.HasData := HasData;
end;

procedure TelemRecordTurn(TokensIn, TokensOut, CacheRead, CacheWrite: Int64;
  const Model: string);
var
  DIn, DOut, DCR, DCW: Int64;
  M: string;
  I, N: Integer;
begin
  if not Active then Exit;
  DIn := TokensIn - BaseIn;
  DOut := TokensOut - BaseOut;
  DCR := CacheRead - BaseCR;
  DCW := CacheWrite - BaseCW;
  { A decrease is possible: LoadSession restores the counters from a file in
    the project tree.  Zero and re-baseline, because a negative asInt on a
    monotonic sum is a payload no collector should have to make sense of. }
  if DIn < 0 then DIn := 0;
  if DOut < 0 then DOut := 0;
  if DCR < 0 then DCR := 0;
  if DCW < 0 then DCW := 0;
  BaseIn := TokensIn; BaseOut := TokensOut;
  BaseCR := CacheRead; BaseCW := CacheWrite;

  Inc(Turns);
  Inc(TurnsSince);

  M := TelemSafeModel(Model);
  N := -1;
  for I := 0 to High(TokenRows) do
    if TokenRows[I].Model = M then begin N := I; Break; end;
  if N < 0 then
  begin
    { Bounded: past the ceiling everything folds into 'other' rather than
      growing a row per hostile model string. }
    if Length(TokenRows) >= TelemMaxModels then
    begin
      M := 'other';
      for I := 0 to High(TokenRows) do
        if TokenRows[I].Model = M then begin N := I; Break; end;
      if N < 0 then N := 0;
    end
    else
    begin
      N := Length(TokenRows);
      SetLength(TokenRows, N + 1);
      TokenRows[N].Model := M;
      TokenRows[N].TokIn := 0; TokenRows[N].TokOut := 0;
      TokenRows[N].CacheRead := 0; TokenRows[N].CacheWrite := 0;
    end;
  end;
  Inc(TokenRows[N].TokIn, DIn);
  Inc(TokenRows[N].TokOut, DOut);
  Inc(TokenRows[N].CacheRead, DCR);
  Inc(TokenRows[N].CacheWrite, DCW);
end;

procedure TelemBaseline(TokensIn, TokensOut, CacheRead, CacheWrite: Int64);
begin
  { Unconditional, and it runs whether or not telemetry is on: a session
    loaded while telemetry is off must not become the first turn's usage if
    telemetry is switched on later in the same process. }
  BaseIn := TokensIn; BaseOut := TokensOut;
  BaseCR := CacheRead; BaseCW := CacheWrite;
end;

procedure TelemRecordTool(const Name: string; IsError: Boolean);
var
  B: string;
  I, N: Integer;
begin
  if not Active then Exit;
  B := TelemBucketTool(Name);
  N := -1;
  for I := 0 to High(ToolRows) do
    if (ToolRows[I].Tool = B) and (ToolRows[I].IsError = IsError) then
    begin N := I; Break; end;
  if N < 0 then
  begin
    N := Length(ToolRows);
    SetLength(ToolRows, N + 1);
    ToolRows[N].Tool := B;
    ToolRows[N].IsError := IsError;
    ToolRows[N].Count := 0;
  end;
  Inc(ToolRows[N].Count);
end;

procedure TelemRecordRequest(StatusCode, ElapsedMs: Integer);
var
  B: string;
  I, N: Integer;
begin
  if not Active then Exit;
  { Numeric codes only, and 'transport' for a request that never got one.  An
    error STRING would be the first free-text field on the wire. }
  if (StatusCode >= 100) and (StatusCode <= 599) then
    B := IntToStr(StatusCode)
  else
    B := 'transport';
  N := -1;
  for I := 0 to High(ReqRows) do
    if ReqRows[I].Bucket = B then begin N := I; Break; end;
  if N < 0 then
  begin
    N := Length(ReqRows);
    SetLength(ReqRows, N + 1);
    ReqRows[N].Bucket := B;
    ReqRows[N].Count := 0;
  end;
  Inc(ReqRows[N].Count);
  if ElapsedMs > 0 then Inc(DurationMs, ElapsedMs);
end;

function TelemDueForFlush: Boolean;
begin
  Result := Active and HasData and (TurnsSince >= Cfg.IntervalTurns);
end;

{ ----------------------------------------------------------- the payload -- }

{ {"key":K,"value":{"stringValue":V}} - the AnyValue shape, spelled out once. }
function Attr(const K, V: string): TJson;
var
  Val: TJson;
begin
  Result := TJson.NewObj;
  Result.AddStr('key', K);
  Val := TJson.NewObj;
  Val.AddStr('stringValue', V);
  Result.Add('value', Val);
end;

{ A NumberDataPoint.  asInt is a STRING: the protobuf JSON mapping encodes
  64-bit integers as decimal strings, and a collector that sees a number here
  is within its rights to reject the batch. }
function Point(Attrs: TJson; Value: Int64; StartNs, NowNs: Int64): TJson;
begin
  Result := TJson.NewObj;
  if Attrs = nil then Attrs := TJson.NewArr;
  Result.Add('attributes', Attrs);
  Result.AddStr('startTimeUnixNano', IntToStr(StartNs));
  Result.AddStr('timeUnixNano', IntToStr(NowNs));
  Result.AddStr('asInt', IntToStr(Value));
end;

function Metric(const Name, Units, Desc: string; Points: TJson): TJson;
var
  Sum: TJson;
begin
  Result := TJson.NewObj;
  Result.AddStr('name', Name);
  Result.AddStr('description', Desc);
  Result.AddStr('unit', Units);
  Sum := TJson.NewObj;
  Sum.Add('dataPoints', Points);
  { The enum as an integer, per the spec.  AddNum writes an integral double
    as '1', so this is the literal the receiver expects. }
  Sum.AddNum('aggregationTemporality', TelemDelta);
  Sum.AddBool('isMonotonic', True);
  Result.Add('sum', Sum);
end;

function TelemBuildPayload(Pretty: Boolean): string;
var
  Root, ResMs, RM, Res, Attrs, ScopeMs, SM, Scope, Metrics, Pts, A: TJson;
  NowNs: Int64;
  I: Integer;

  procedure TokenMetric(const Kind: string; Which: Integer);
  var
    J: Integer;
    V: Int64;
    PA: TJson;
  begin
    for J := 0 to High(TokenRows) do
    begin
      case Which of
        0: V := TokenRows[J].TokIn;
        1: V := TokenRows[J].TokOut;
        2: V := TokenRows[J].CacheRead;
      else V := TokenRows[J].CacheWrite;
      end;
      if V <= 0 then Continue;
      PA := TJson.NewArr;
      PA.Push(Attr('type', Kind));
      PA.Push(Attr('model', TokenRows[J].Model));
      Pts.Push(Point(PA, V, IntervalStartNs, NowNs));
    end;
  end;

begin
  NowNs := NowUnixNanos;
  Root := TJson.NewObj;
  try
    ResMs := TJson.NewArr;
    Root.Add('resourceMetrics', ResMs);
    RM := TJson.NewObj;
    ResMs.Push(RM);

    { The whole of the resource.  Deliberately no host.name, no OS user, no
      process.command_line, no cwd and no root path: a path alone names the
      user and often their client. }
    Res := TJson.NewObj;
    Attrs := TJson.NewArr;
    Attrs.Push(Attr('service.name', Cfg.ServiceName));
    Attrs.Push(Attr('service.version', Cfg.ServiceVersion));
    Res.Add('attributes', Attrs);
    RM.Add('resource', Res);

    ScopeMs := TJson.NewArr;
    RM.Add('scopeMetrics', ScopeMs);
    SM := TJson.NewObj;
    ScopeMs.Push(SM);
    Scope := TJson.NewObj;
    Scope.AddStr('name', 'pasclaude');
    Scope.AddStr('version', Cfg.ServiceVersion);
    SM.Add('scope', Scope);
    Metrics := TJson.NewArr;
    SM.Add('metrics', Metrics);

    if Turns > 0 then
    begin
      Pts := TJson.NewArr;
      Pts.Push(Point(nil, Turns, IntervalStartNs, NowNs));
      Metrics.Push(Metric('pasclaude.turns', '{turn}',
        'user turns completed', Pts));
    end;

    Pts := TJson.NewArr;
    TokenMetric('input', 0);
    TokenMetric('output', 1);
    TokenMetric('cache_read', 2);
    TokenMetric('cache_write', 3);
    if Pts.Count > 0 then
      Metrics.Push(Metric('pasclaude.tokens', '{token}',
        'tokens billed, by kind and model', Pts))
    else
      Pts.Free;

    if Length(ToolRows) > 0 then
    begin
      Pts := TJson.NewArr;
      for I := 0 to High(ToolRows) do
      begin
        A := TJson.NewArr;
        A.Push(Attr('tool', ToolRows[I].Tool));
        if ToolRows[I].IsError then
          A.Push(Attr('status', 'error'))
        else
          A.Push(Attr('status', 'ok'));
        Pts.Push(Point(A, ToolRows[I].Count, IntervalStartNs, NowNs));
      end;
      Metrics.Push(Metric('pasclaude.tool.calls', '{call}',
        'tool calls, bucketed to built-in names', Pts));
    end;

    if Length(ReqRows) > 0 then
    begin
      Pts := TJson.NewArr;
      for I := 0 to High(ReqRows) do
      begin
        A := TJson.NewArr;
        A.Push(Attr('status', ReqRows[I].Bucket));
        Pts.Push(Point(A, ReqRows[I].Count, IntervalStartNs, NowNs));
      end;
      Metrics.Push(Metric('pasclaude.api.requests', '{request}',
        'API requests, by HTTP status', Pts));
      { Two Sums rather than a Histogram: bucket bounds would have to be
        chosen by hand and would be wrong for somebody.  Mean latency is
        duration divided by requests, which is what a dashboard wants first. }
      if DurationMs > 0 then
      begin
        Pts := TJson.NewArr;
        Pts.Push(Point(nil, DurationMs, IntervalStartNs, NowNs));
        Metrics.Push(Metric('pasclaude.api.duration', 'ms',
          'total time spent in API requests', Pts));
      end;
    end;

    if Pretty then
      Result := Root.ToJsonPretty
    else
      Result := Root.ToJson;
  finally
    Root.Free;
  end;
  { Belt as well as braces: everything sent anywhere by this program must be
    valid UTF-8, and the two strings that can reach here from a project file
    have already been filtered to ASCII by TelemSafeModel and TelemBucketTool. }
  if not IsValidUtf8(Result) then Result := '{"resourceMetrics":[]}';
end;

function HeaderUsable(I: Integer): Boolean;
begin
  Result := HeaderTextOk(Cfg.HeaderNames[I]) and
            HeaderTextOk(Cfg.HeaderValues[I]) and
            (Pos(':', Cfg.HeaderNames[I]) = 0) and
            (CompareText(Cfg.HeaderNames[I], 'content-type') <> 0);
end;

function TelemHeaderBlock: string;
var
  I: Integer;
begin
  { The spec's MUST.  Ours and not the user's: a configured Content-Type is
    dropped above rather than allowed to change the encoding out from under
    the builder. }
  Result := 'content-type: application/json';
  for I := 0 to High(Cfg.HeaderNames) do
    if HeaderUsable(I) then
      Result := Result + #13#10 + Cfg.HeaderNames[I] + ': ' + Cfg.HeaderValues[I];
end;

function TelemHeaderBlockRedacted: string;
var
  I: Integer;
begin
  { A collector token is a secret the user wrote down, and /telemetry preview
    is the kind of output that ends up in a screenshot.  The name and the
    length are enough to check the header is the one they meant. }
  Result := 'content-type: application/json';
  for I := 0 to High(Cfg.HeaderNames) do
    if HeaderUsable(I) then
      Result := Result + #13#10 + Cfg.HeaderNames[I] + ': <' +
        IntToStr(Length(Cfg.HeaderValues[I])) + ' bytes>';
end;

{ ------------------------------------------------------------- the flush -- }

{ A 200 whose partialSuccess names rejected points is a failure the spec
  forbids retrying.  Absent, or present with zeroes, is a success. }
function PartialSuccessRejected(const Body: string): Boolean;
var
  Doc, PS: TJson;
begin
  Result := False;
  if Trim(Body) = '' then Exit;
  Doc := JsonParse(Body);
  if Doc = nil then Exit;
  try
    PS := Doc.Find('partialSuccess');
    if PS = nil then Exit;
    Result := (PS.Num('rejectedDataPoints', 0) <> 0) or
              (PS.Str('errorMessage') <> '');
  finally
    Doc.Free;
  end;
end;

function TelemFlush(out Status: Integer; out Err: string): Boolean;
var
  Payload, Saved: string;
  Res: THttpResult;
  SavedTimeout: Integer;
begin
  Status := 0;
  Err := '';
  if not Active then
  begin
    if SelfDisabled then
      Err := 'telemetry disabled itself after ' + IntToStr(TelemMaxFailures) +
        ' failures'
    else
      Err := 'telemetry is off';
    Exit(False);
  end;
  if not HasData then
  begin
    TurnsSince := 0;
    Exit(True);
  end;
  Payload := TelemBuildPayload(False);
  Saved := TelemHeaderBlock;

  { The only place this program ever shortens the HTTP timeouts.  Restored in
    a finally without exception, because leaving it set would put a two-second
    receive timeout on the next streamed model turn - which would look like a
    truncated answer, not like a telemetry bug. }
  SavedTimeout := uHttp.HttpTimeoutMs;
  uHttp.HttpTimeoutMs := Cfg.TimeoutMs;
  try
    Res := uHttp.HttpPost(TargetUrl, Saved, Payload, nil, nil);
  finally
    uHttp.HttpTimeoutMs := SavedTimeout;
  end;

  Status := Res.Status;
  LastStatus := Res.Status;
  Result := Res.Ok and not PartialSuccessRejected(Res.Body);
  if not Result then
  begin
    if Res.Error <> '' then Err := Res.Error
    else if Res.Ok then Err := 'the collector rejected some data points'
    else Err := 'HTTP ' + IntToStr(Res.Status);
  end;
  LastError := Err;

  { Discarded either way.  No queue, no spool, no disk: a collector that is
    down must not grow a buffer, and a batch that is one interval old is not
    worth the memory it would take to keep. }
  ResetBuffer;

  if Result then
    ConsecFail := 0
  else
  begin
    Inc(ConsecFail);
    if ConsecFail >= TelemMaxFailures then
    begin
      SelfDisabled := True;
      Active := False;
    end;
  end;
end;

procedure TelemShutdown;
var
  S: Integer;
  E: string;
begin
  if Active and HasData then
    TelemFlush(S, E);
  Active := False;
end;

initialization
  Cfg := TelemDefaultConfig;
  IntervalStartNs := NowUnixNanos;
end.
