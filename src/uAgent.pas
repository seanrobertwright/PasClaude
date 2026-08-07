{ uAgent - the conversation loop against the Anthropic messages API.

  One turn is: send the whole transcript, stream the reply, and if the model
  asked for tools, run them, append the results as a user message, and send
  again.  That repeats until the model stops asking for tools, which is what
  makes this agentic rather than a chat box.

  The stream is server-sent events.  Content blocks arrive as start/delta/stop
  triplets keyed by index, so the decoder keeps a flat array of partial blocks
  and only builds JSON once the message is complete - JSON values here are
  immutable once written, and growing a string in place is cheaper anyway.
  Event types that are not needed are ignored on purpose, so a new one from
  the server cannot break the client. }
unit uAgent;

{$mode objfpc}{$H+}

interface

uses uJson, uTools;

type
  { Rendering hooks, so this unit stays free of console code. }
  TTextProc = procedure(const S: string);
  TToolProc = procedure(const Name, Detail: string);
  { Polled while a response streams; True abandons the request. }
  TCancelProc = function: Boolean;

  TModelInfo = record
    Id: string;           { what the API wants in "model" }
    DisplayName: string;  { what a human calls it }
  end;
  TModelList = array of TModelInfo;

  { bkServerToolUse is a tool the API runs for us: same shape as bkToolUse,
    but no RunTool ever sees it.  bkResult is a verbatim passthrough of a
    block this client does not interpret and must nevertheless echo back on
    the next request - its Text holds the block's own JSON, captured whole
    from content_block_start.  Making bkResult the fallback for any
    unrecognised type is what keeps a future server-side block from being
    silently flattened into empty prose. }
  TBlockKind = (bkText, bkThinking, bkToolUse, bkServerToolUse, bkResult);

  TPartialBlock = record
    Kind: TBlockKind;
    Text: string;        { prose, reasoning, accumulated tool JSON, or raw block JSON }
    Id: string;
    Name: string;
    Signature: string;   { thinking blocks must be echoed back verbatim }
  end;
  TPartialBlocks = array of TPartialBlock;

  TAgent = class
  private
    FApiKey: string;
    FModel: string;
    FSystem: string;
    FMessages: TJson;              { the "messages" array, owned here }
    FMaxTokens: Integer;
    FTotalIn, FTotalOut: Int64;
    FCacheWrite, FCacheRead: Int64;
    FTurns: Integer;
    { From the last failed response's Retry-After header, for the retry loop.
      Zero when the server named no wait. }
    FRetryAfterMs: Integer;
    { Prompt tokens of the most recent request, as the API counted them:
      plain input plus both cache columns.  This is the real size of the
      context, where TranscriptBytes is only a proxy for it. }
    FLastPromptTokens: Int64;
    FThinkingBudget: Integer;
    { Off unless the user turned it on this session.  When off the tool is
      not declared at all, so the model cannot reach the network and the
      declaration costs nothing. }
    FWebSearch: Boolean;
    { The tool-round ceiling for this agent.  A field rather than the constant
      because a subagent gets a lower one. }
    FMaxRounds: Integer;

    { The cancel test every poll site uses.  ShouldCancel is consume-on-read
      in the host (CtrlCPressed clears the flag as it answers), so a subagent
      polling it would swallow the user's abort and leave the parent running.
      ForceCancel is the latch that makes the abort survive that. }
    function WantsCancel: Boolean;
    { Folds a finished subagent's token counts into this agent's, so /cost
      reports what the turn actually cost rather than what the parent alone
      spent. }
    procedure AbsorbUsage(Sub: TAgent);

    function BuildBody: string;
    { Turns web search off after the server refused the declaration, so the
      turn can be retried without it.  True when it did, meaning the caller
      should try the same round again.  A tool the server will not accept
      must cost one request, not every request for the rest of the run. }
    function DisableWebSearchAfterRejection(const Err: string): Boolean;
    { One request/response exchange.  Returns the blocks the model produced. }
    function SendOnce(out Blocks: TPartialBlocks; out StopReason: string;
      out Err: string; out Cancelled: Boolean): Boolean;
    { Appends an assistant message rebuilt from Blocks. }
    procedure RecordAssistant(const Blocks: TPartialBlocks);
    { Runs every tool_use block and appends the tool_result user message.
      Returns False when no tool was requested. }
    function RunTools(const Blocks: TPartialBlocks): Boolean;
    { SendOnce with retries for transient failures. }
    function SendWithRetry(out Blocks: TPartialBlocks;
      out StopReason, Err: string; out Cancelled: Boolean): Boolean;
    { A wait that the user can break out of.  False when cancelled. }
    function SleepCancellable(Ms: Integer): Boolean;
    { Strips tool_use blocks that will never get a result. }
    procedure DropUnansweredToolCalls;
    { Puts the transcript back into a state the next question can legally
      follow after a cancellation. }
    procedure UnwindCancelledTail;
  public
    OnText: TTextProc;             { streamed assistant prose }
    OnThinking: TTextProc;         { streamed reasoning, when the model emits it }
    OnToolStart: TToolProc;
    OnToolResult: TToolProc;
    OnNotice: TTextProc;           { status and error lines }
    { Fires when a tool_use block opens in the stream, before its arguments
      have finished arriving - the earliest moment the user can be told what
      the model is doing.  Detail carries the tool's id. }
    OnToolUseBegin: TToolProc;
    { Streamed fragments of the tool's argument JSON, as they arrive. }
    OnToolArg: TTextProc;
    Ask: TAskProc;
    { Polled between chunks so the user can abandon a long reply. }
    ShouldCancel: TCancelProc;

    constructor Create(const ApiKey, AModel, SystemPrompt: string);
    destructor Destroy; override;

    { Runs a full turn including any tool round-trips.  False with Err set
      when the exchange could not be completed. }
    function Send(const UserText: string; out Err: string): Boolean;

    procedure Reset;
    { Drops the oldest exchanges, keeping roughly the last KeepBytes worth of
      transcript.  Returns the number of messages removed. }
    function Compact(KeepBytes: Integer): Integer;
    { Asks the model to summarize the conversation, then replaces the whole
      transcript with that summary.  The old transcript is restored intact on
      any failure, so a refusal or a dropped connection costs nothing.  The
      summary streams through OnText like any reply. }
    function CompactWithSummary(out Err: string): Boolean;
    { Bytes the transcript currently occupies as JSON. }
    function TranscriptBytes: Integer;
    function MessageCount: Integer;
    { Prompt tokens of the most recent request - the context's true size.
      Zero until a request has been made. }
    function ContextTokens: Int64;
    { Drops a trailing user message that never got an answer.  Returns True if
      one was removed. }
    function TrimUnansweredQuestion: Boolean;
    { Drops every message past Count, for /rewind.  The caller recorded the
      count before the turn it wants to return to. }
    procedure TruncateMessages(Count: Integer);
    { Unwinds a turn that stopped with tool results the model never saw, back
      to a state the next question can legally follow. }
    procedure UnwindUnsentTail;

    { Writes the conversation to Path so a later run can pick it up.  False
      with Err set when it could not be stored. }
    function SaveSession(const Path: string; out Err: string): Boolean;
    { Replaces the conversation with the one in Path.  A file that is missing,
      corrupt, or not a legal transcript is refused rather than loaded, since a
      bad transcript makes every later request fail. }
    function LoadSession(const Path: string; out Err: string): Boolean;

    function TokensIn: Int64;
    function TokensOut: Int64;
    function CacheWriteTokens: Int64;
    function CacheReadTokens: Int64;
    function TurnCount: Integer;
    property Model: string read FModel write FModel;
    { Asks the API which models this key can use.  Empty with Err set when
      the endpoint could not be reached or the answer was not understood. }
    function ListModels(out Err: string): TModelList;
    { Extended thinking budget in tokens; 0 disables it.  When set the
      request carries a thinking block allowance and max_tokens grows to
      leave room for the visible reply on top of the reasoning. }
    property ThinkingBudget: Integer read FThinkingBudget write FThinkingBudget;
    { Whether the server-side web search tool is declared to the API.  Off by
      default: the search runs on Anthropic's side, so there is no per-call
      hook to ask permission at, which makes this switch the whole of the
      user's consent to reaching the outside world. }
    property WebSearch: Boolean read FWebSearch write FWebSearch;
    { The tool-round ceiling for this agent.  MaxToolRounds by default; a
      subagent gets less, because it is doing one self-contained job and
      nobody is watching it spend. }
    property MaxRounds: Integer read FMaxRounds write FMaxRounds;
    { The text of the last assistant message - what a subagent hands back to
      its caller as the whole result.  '' when there is none. }
    function LastAssistantText: string;

    { Test seam.  Feeds raw response bytes through the same decoder the live
      stream uses, so the SSE handling can be exercised without a network.
      Chunks are concatenated as received, which is how a split mid-line or
      mid-escape gets covered. }
    function DecodeStream(const Chunks: array of string;
      out StopReason, Err: string): TPartialBlocks;
    { Test seam: the transcript as it would be sent. }
    function Transcript: string;
    { Test seam: append a user turn without sending, so a suite can build a
      conversation without a transport. }
    procedure AppendUserText(const S: string);
    { Test seam: the exact request body that would go on the wire. }
    function RequestBody: string;
    { Test seam: run the recorded blocks through the assistant/tool path. }
    procedure ApplyBlocks(const Blocks: TPartialBlocks; out RanTools: Boolean);
  end;

const
  DefaultModel  = 'claude-sonnet-4-5';
  ApiUrl        = 'https://api.anthropic.com/v1/messages';
  ApiVersion    = '2023-06-01';
  { A subscription OAuth token (Claude Code's) rather than an API key.  It
    authenticates with a Bearer header and a beta flag, and the API requires
    the first system block to be Claude Code's identity line, verbatim. }
  OauthKeyPrefix = 'sk-ant-oat';
  OauthBeta      = 'oauth-2025-04-20';
  OauthIdentity  = 'You are Claude Code, Anthropic''s official CLI for Claude.';
  MaxToolRounds = 24;
  { Transient failures are retried this many times before giving up. }
  MaxRetries    = 3;
  { Bumped when the saved-session shape changes incompatibly. }
  SessionVersion = 1;
  { A mentioned file larger than this is refused rather than attached; the
    model can read it in slices through the tool instead. }
  MaxMentionBytes = 100 * 1024;
  { Where a session lives, relative to the session root. }
  SessionDir  = '.pasclaude';
  SessionFile = 'session.json';

{ The default save location under Root. }
function SessionPath(const Root: string): string;

{ Expands @path mentions in a prompt.  Each mention of a readable text file
  under the session root becomes an attachment appended after the prose, so
  the model gets the file without spending a tool round reading it.  Returns
  the expanded text; Notes lists what was attached or why something was not. }
function ExpandMentions(const Text: string; out Notes: string): string;

{ Copies an existing session aside so a run that is not resuming it cannot
  destroy it on the first save.  True when there was nothing to do, or the
  copy succeeded. }
function BackupSession(const Path: string; out Err: string): Boolean;

var
  { Base backoff in milliseconds; doubles per attempt.  Only the tests lower
    it, so a suite does not spend seconds asleep. }
  RetryBaseMs: Integer = 1000;

implementation

uses SysUtils, Classes, uHttp, uMcp;

var
  { The agent whose tool call is currently running, so a nested agent spawned
    from inside that call can find its parent - its key, its model, and the
    counters its spending has to land in. }
  ActiveAgent: TAgent = nil;
  { Whose hooks a subagent's progress lines are forwarded to.  Held apart
    from ActiveAgent so the forwarding does not have to reach back through a
    parent pointer on every line. }
  SubHost: TAgent = nil;
  { Set when a subagent's own turn reported itself cancelled. }
  SubWasCancelled: Boolean = False;
  { The cancellation latch.  The host's ShouldCancel consumes its flag as it
    answers, so without this a subagent would read the user's Esc, stop, and
    the parent would carry on as though nothing had happened. }
  ForceCancel: Boolean = False;

function SessionPath(const Root: string): string;
begin
  Result := IncludeTrailingPathDelimiter(Root) + SessionDir +
    PathDelim + SessionFile;
end;

{ ---------------------------------------------------------------- mentions -- }

{ True for the characters that can appear in a mentioned path.  The set stops
  at whitespace and at punctuation that ends a sentence, so "see @a\b.pas,"
  attaches a\b.pas rather than a\b.pas-comma. }
function IsPathChar(C: Char): Boolean;
begin
  Result := C in ['A'..'Z', 'a'..'z', '0'..'9', '\', '/', '.', '_', '-', ':'];
end;

function ExpandMentions(const Text: string; out Notes: string): string;
var
  I, Start: Integer;
  Path, Full, FileText, Attach: string;
  F: TFileStream;
  N: Int64;
begin
  Result := Text;
  Notes := '';
  Attach := '';
  I := 1;
  while I <= Length(Text) do
  begin
    { An @ introduces a mention only at a word boundary: "user@host" is an
      address, not two mentions. }
    if (Text[I] = '@') and ((I = 1) or (Text[I - 1] in [' ', #9, #10, '('])) then
    begin
      Start := I + 1;
      I := Start;
      while (I <= Length(Text)) and IsPathChar(Text[I]) do
        Inc(I);
      { Trailing sentence punctuation belongs to the prose. }
      while (I > Start) and (Text[I - 1] in ['.', ',', ':']) do
        Dec(I);
      Path := Copy(Text, Start, I - Start);
      if Path = '' then Continue;

      { The same guard the tools use: a mention must not escape the session
        root or reach into pasclaude's own state, and @..\..\secrets is
        exactly as hostile typed as it is tool-called. }
      if not uTools.ResolveInRoot(Path, Full, FileText) then
      begin
        Notes := Notes + Format('@%s: %s'#10, [Path, FileText]);
        Continue;
      end;
      if not FileExists(Full) then
      begin
        Notes := Notes + Format('@%s: no such file'#10, [Path]);
        Continue;
      end;
      try
        F := TFileStream.Create(Full, fmOpenRead or fmShareDenyNone);
        try
          N := F.Size;
          if N > MaxMentionBytes then
          begin
            Notes := Notes + Format('@%s: %d bytes, too large to attach'#10,
              [Path, N]);
            Continue;
          end;
          SetLength(FileText, N);
          if N > 0 then F.ReadBuffer(FileText[1], N);
        finally
          F.Free;
        end;
      except
        on E: Exception do
        begin
          Notes := Notes + Format('@%s: %s'#10, [Path, E.Message]);
          Continue;
        end;
      end;
      { A binary file would poison the request body; the model can still ask
        for a hex dump through the tool if it really wants one. }
      if not uTools.IsValidUtf8(FileText) then
      begin
        Notes := Notes + Format('@%s: not text, not attached'#10, [Path]);
        Continue;
      end;
      Attach := Attach + Format(#10#10'--- %s ---'#10'%s', [Path, FileText]);
      Notes := Notes + Format('@%s: attached (%d bytes)'#10,
        [Path, Length(FileText)]);
    end
    else
      Inc(I);
  end;
  if Attach <> '' then
    Result := Text + #10 +
      #10'The files mentioned above are attached below.' + Attach;
end;

{ The previous session is kept under a fixed name rather than a timestamped
  one: a directory quietly filling with old conversations is its own problem,
  and one level of undo is what this is for. }
function BackupSession(const Path: string; out Err: string): Boolean;
var
  Prev: string;
begin
  Err := '';
  Result := True;
  if not FileExists(Path) then Exit;
  Prev := ChangeFileExt(Path, '') + '.prev.json';
  try
    if FileExists(Prev) and not DeleteFile(Prev) then
    begin
      Err := 'cannot replace ' + Prev;
      Exit(False);
    end;
    if not RenameFile(Path, Prev) then
    begin
      Err := 'cannot move ' + Path;
      Exit(False);
    end;
  except
    on E: Exception do
    begin
      Err := E.Message;
      Result := False;
    end;
  end;
end;

{ ------------------------------------------------------------ stream state -- }

type
  PStream = ^TStreamState;
  TStreamState = record
    Buf: string;                 { bytes not yet split into complete lines }
    Blocks: TPartialBlocks;
    Agent: TAgent;
    StopReason: string;
    InTok, OutTok: Int64;
    CacheWrite, CacheRead: Int64;
    ErrText: string;
    Cancel: Boolean;
  end;

procedure EnsureSlot(St: PStream; Idx: Integer);
var
  Old, I: Integer;
begin
  if Idx < 0 then Exit;
  Old := Length(St^.Blocks);
  if Idx < Old then Exit;
  SetLength(St^.Blocks, Idx + 1);
  for I := Old to Idx do
  begin
    St^.Blocks[I].Kind := bkText;
    St^.Blocks[I].Text := '';
    St^.Blocks[I].Id := '';
    St^.Blocks[I].Name := '';
    St^.Blocks[I].Signature := '';
  end;
end;

procedure ApplyEvent(St: PStream; Ev: TJson);
var
  T, K: string;
  Idx: Integer;
  CB, Delta, Msg, Usage, ErrObj, Content: TJson;
  Frag: string;
begin
  T := Ev.Str('type');

  if T = 'message_start' then
  begin
    Msg := Ev.Find('message');
    if Msg <> nil then
    begin
      Usage := Msg.Find('usage');
      if Usage <> nil then
      begin
        St^.InTok := Round(Usage.Num('input_tokens'));
        St^.OutTok := Round(Usage.Num('output_tokens'));
        { Cached tokens are billed differently and are the whole point of the
          cache_control markers, so they are tracked separately: a working
          cache shows up here as reads growing and plain input staying small. }
        St^.CacheWrite := Round(Usage.Num('cache_creation_input_tokens'));
        St^.CacheRead := Round(Usage.Num('cache_read_input_tokens'));
      end;
    end;
  end

  else if T = 'content_block_start' then
  begin
    Idx := Round(Ev.Num('index'));
    EnsureSlot(St, Idx);
    CB := Ev.Find('content_block');
    if CB = nil then Exit;
    K := CB.Str('type');
    if K = 'tool_use' then
    begin
      St^.Blocks[Idx].Kind := bkToolUse;
      St^.Blocks[Idx].Id := CB.Str('id');
      St^.Blocks[Idx].Name := CB.Str('name');
      St^.Blocks[Idx].Text := '';
      if Assigned(St^.Agent.OnToolUseBegin) then
        St^.Agent.OnToolUseBegin(St^.Blocks[Idx].Name, St^.Blocks[Idx].Id);
    end
    else if K = 'server_tool_use' then
    begin
      { The API runs this one itself.  It is recorded exactly like a local
        tool call because the transcript has to carry it back verbatim, but
        RunTools skips it - there is nothing here to execute. }
      St^.Blocks[Idx].Kind := bkServerToolUse;
      St^.Blocks[Idx].Id := CB.Str('id');
      St^.Blocks[Idx].Name := CB.Str('name');
      St^.Blocks[Idx].Text := '';
      if Assigned(St^.Agent.OnToolUseBegin) then
        St^.Agent.OnToolUseBegin(St^.Blocks[Idx].Name, St^.Blocks[Idx].Id);
    end
    else if K = 'thinking' then
    begin
      St^.Blocks[Idx].Kind := bkThinking;
      St^.Blocks[Idx].Text := CB.Str('thinking');
    end
    else if K = 'text' then
    begin
      St^.Blocks[Idx].Kind := bkText;
      St^.Blocks[Idx].Text := CB.Str('text');
    end
    else
    begin
      { Anything else - a search result, a redacted thinking block, whatever
        ships next - is captured whole and replayed unchanged.  Coercing it
        to text, as this branch used to, dropped it from the transcript
        entirely and broke the echo the API requires. }
      St^.Blocks[Idx].Kind := bkResult;
      St^.Blocks[Idx].Text := CB.ToJson;
      if K = 'web_search_tool_result' then
      begin
        { A network fetch that leaves no trace in the transcript would be the
          one tool where silence is least acceptable, so the result is
          summarised for the host the same way a local tool's would be. }
        Frag := '';
        Content := CB.Find('content');
        if (Content <> nil) and (Content.Kind = jkArr) then
          Frag := Format('%d results', [Content.Count])
        else if Content <> nil then
          Frag := 'error: ' + Content.Str('error_code')
        else
          Frag := 'no results';
        if Assigned(St^.Agent.OnToolResult) then
          St^.Agent.OnToolResult('web_search', Frag);
      end;
    end;
  end

  else if T = 'content_block_delta' then
  begin
    Idx := Round(Ev.Num('index'));
    EnsureSlot(St, Idx);
    { A delta for a raw-captured block means the capture from
      content_block_start was only the opening of it, so replaying that
      capture would echo a half-formed block.  Blanking the slot drops the
      block instead, which is the safer of the two wrong answers. }
    if St^.Blocks[Idx].Kind = bkResult then
    begin
      St^.Blocks[Idx].Kind := bkText;
      St^.Blocks[Idx].Text := '';
      Exit;
    end;
    Delta := Ev.Find('delta');
    if Delta = nil then Exit;
    K := Delta.Str('type');
    if K = 'text_delta' then
    begin
      Frag := Delta.Str('text');
      St^.Blocks[Idx].Text := St^.Blocks[Idx].Text + Frag;
      if Assigned(St^.Agent.OnText) then St^.Agent.OnText(Frag);
    end
    else if K = 'thinking_delta' then
    begin
      Frag := Delta.Str('thinking');
      St^.Blocks[Idx].Text := St^.Blocks[Idx].Text + Frag;
      if Assigned(St^.Agent.OnThinking) then St^.Agent.OnThinking(Frag);
    end
    else if K = 'signature_delta' then
      St^.Blocks[Idx].Signature := St^.Blocks[Idx].Signature + Delta.Str('signature')
    else if K = 'input_json_delta' then
    begin
      { Tool arguments stream as raw JSON text and are parsed once complete. }
      Frag := Delta.Str('partial_json');
      St^.Blocks[Idx].Text := St^.Blocks[Idx].Text + Frag;
      if Assigned(St^.Agent.OnToolArg) then St^.Agent.OnToolArg(Frag);
    end;
  end

  else if T = 'message_delta' then
  begin
    Delta := Ev.Find('delta');
    if Delta <> nil then
      St^.StopReason := Delta.Str('stop_reason', St^.StopReason);
    Usage := Ev.Find('usage');
    if Usage <> nil then
      St^.OutTok := Round(Usage.Num('output_tokens', St^.OutTok));
  end

  else if T = 'error' then
  begin
    ErrObj := Ev.Find('error');
    if ErrObj <> nil then
      St^.ErrText := ErrObj.Str('type') + ': ' + ErrObj.Str('message')
    else
      St^.ErrText := 'stream error';
  end;
end;

{ Consumes whole lines from the buffer.  Only "data:" lines matter; the
  matching "event:" line repeats the type that is already inside the JSON. }
procedure ConsumeLines(St: PStream);
var
  NL: Integer;
  Line, Payload: string;
  Ev: TJson;
begin
  repeat
    NL := Pos(#10, St^.Buf);
    if NL = 0 then Exit;
    Line := Copy(St^.Buf, 1, NL - 1);
    Delete(St^.Buf, 1, NL);
    if (Line <> '') and (Line[Length(Line)] = #13) then
      SetLength(Line, Length(Line) - 1);
    if Copy(Line, 1, 5) <> 'data:' then Continue;
    Payload := Trim(Copy(Line, 6, MaxInt));
    if (Payload = '') or (Payload = '[DONE]') then Continue;
    Ev := JsonParse(Payload);
    if Ev = nil then Continue;
    try
      ApplyEvent(St, Ev);
    finally
      Ev.Free;
    end;
  until False;
end;

function StreamChunk(const Data: string; Ctx: Pointer): Boolean;
var
  St: PStream;
begin
  St := PStream(Ctx);
  St^.Buf := St^.Buf + Data;
  ConsumeLines(St);
  { Checked per chunk rather than per event: it is the cheapest place that
    still reacts within a few hundred bytes of the user pressing Esc. }
  if St^.Agent.WantsCancel then
    St^.Cancel := True;
  Result := not St^.Cancel;
end;

{ ------------------------------------------------------------------ agent -- }

constructor TAgent.Create(const ApiKey, AModel, SystemPrompt: string);
begin
  inherited Create;
  FApiKey := ApiKey;
  FModel := AModel;
  if FModel = '' then FModel := DefaultModel;
  FSystem := SystemPrompt;
  FMessages := TJson.NewArr;
  FMaxTokens := 8192;
  FMaxRounds := MaxToolRounds;
  { Stated rather than left to the zero value, because "off" is a decision
    here and not an accident of initialisation. }
  FWebSearch := False;
end;

function TAgent.WantsCancel: Boolean;
begin
  Result := ForceCancel or (Assigned(ShouldCancel) and ShouldCancel());
end;

procedure TAgent.AbsorbUsage(Sub: TAgent);
begin
  if Sub = nil then Exit;
  Inc(FTotalIn, Sub.FTotalIn);
  Inc(FTotalOut, Sub.FTotalOut);
  Inc(FCacheWrite, Sub.FCacheWrite);
  Inc(FCacheRead, Sub.FCacheRead);
end;

function TAgent.LastAssistantText: string;
var
  I, J: Integer;
  M, Content, B: TJson;
begin
  Result := '';
  for I := FMessages.Count - 1 downto 0 do
  begin
    M := FMessages.Item(I);
    if (M = nil) or (M.Str('role') <> 'assistant') then Continue;
    Content := M.Find('content');
    if Content = nil then Exit;
    for J := 0 to Content.Count - 1 do
    begin
      B := Content.Item(J);
      if (B <> nil) and (B.Str('type') = 'text') then
        Result := Result + B.Str('text');
    end;
    Exit;
  end;
end;

destructor TAgent.Destroy;
begin
  FMessages.Free;
  inherited Destroy;
end;

procedure TAgent.Reset;
begin
  FMessages.Free;
  FMessages := TJson.NewArr;
  FTurns := 0;
end;

function TAgent.TokensIn: Int64;
begin
  Result := FTotalIn;
end;

function TAgent.TranscriptBytes: Integer;
begin
  Result := Length(FMessages.ToJson);
end;

function TAgent.MessageCount: Integer;
begin
  Result := FMessages.Count;
end;

procedure TAgent.TruncateMessages(Count: Integer);
begin
  if Count < 0 then Count := 0;
  while FMessages.Count > Count do
    FMessages.Drop(FMessages.Count - 1);
end;

function TAgent.ContextTokens: Int64;
begin
  Result := FLastPromptTokens;
end;

{ The models endpoint answers GET /v1/models with {"data":[{id, display_name,
  ...}]}.  The same authentication rules as the messages endpoint apply, so
  the header choice mirrors SendOnce's. }
function TAgent.ListModels(out Err: string): TModelList;
var
  Headers: string;
  Res: THttpResult;
  Doc, Data, M: TJson;
  I, N: Integer;
begin
  Result := nil;
  Err := '';

  if Copy(FApiKey, 1, Length(OauthKeyPrefix)) = OauthKeyPrefix then
    Headers :=
      'authorization: Bearer ' + FApiKey + #13#10 +
      'anthropic-beta: ' + OauthBeta + #13#10 +
      'anthropic-version: ' + ApiVersion
  else
    Headers :=
      'x-api-key: ' + FApiKey + #13#10 +
      'anthropic-version: ' + ApiVersion;

  Res := HttpGet('https://api.anthropic.com/v1/models?limit=50', Headers, 0);
  if not Res.Ok then
  begin
    Err := Res.Error;
    if Res.Body <> '' then Err := Err + ' - ' + Copy(Res.Body, 1, 300);
    Exit;
  end;

  Doc := JsonParse(Res.Body);
  if Doc = nil then
  begin
    Err := 'the model list was not valid JSON';
    Exit;
  end;
  try
    Data := Doc.Find('data');
    if (Data = nil) or (Data.Kind <> jkArr) then
    begin
      Err := 'the model list has no data array';
      Exit;
    end;
    N := 0;
    SetLength(Result, Data.Count);
    for I := 0 to Data.Count - 1 do
    begin
      M := Data.Item(I);
      if M.Str('id') = '' then Continue;
      Result[N].Id := M.Str('id');
      Result[N].DisplayName := M.Str('display_name', M.Str('id'));
      Inc(N);
    end;
    SetLength(Result, N);
    if N = 0 then Err := 'the API returned no models';
  finally
    Doc.Free;
  end;
end;

{ A turn that failed - no key, no network, a rejected request - leaves the
  user's question in the transcript with nothing answering it.  Saving that
  and resuming it produces two user messages in a row, which is a shape the
  conversation should never have been left in whether or not the API tolerates
  it.  The question is dropped instead: it was never answered, and the user
  still has it on screen to ask again. }
function IsToolResultMessage(M: TJson): Boolean; forward;

function TAgent.TrimUnansweredQuestion: Boolean;
var
  Last: TJson;
begin
  Result := False;
  if FMessages.Count = 0 then Exit;
  Last := FMessages.Item(FMessages.Count - 1);
  if Last.Str('role') <> 'user' then Exit;
  { A trailing tool_result message is a different animal: it answers the
    assistant turn before it, and dropping it would orphan that tool call. }
  if IsToolResultMessage(Last) then Exit;
  FMessages.Drop(FMessages.Count - 1);
  Result := True;
end;

{ True when this message is a user turn carrying tool results rather than
  something the user typed.  Such a message is only legal directly after the
  assistant message whose tool_use ids it answers, so a compaction may never
  leave one at the front of the transcript. }
function IsToolResultMessage(M: TJson): Boolean;
var
  Content: TJson;
  I: Integer;
begin
  Result := False;
  if (M = nil) or (M.Str('role') <> 'user') then Exit;
  Content := M.Find('content');
  if (Content = nil) or (Content.Count = 0) then Exit;
  for I := 0 to Content.Count - 1 do
    if Content.Item(I).Str('type') = 'tool_result' then Exit(True);
end;

{ Keeps the tail of the conversation and throws the head away.  Old turns are
  where the bulk of a long session's tokens sit - mostly file contents that
  have since been edited - while the recent exchanges are what the model
  actually needs.

  The cut point is then walked forward until it lands on a real user message,
  because starting a transcript with an assistant turn or with orphaned tool
  results is rejected by the API. }
function TAgent.Compact(KeepBytes: Integer): Integer;
var
  I, Total, Cut: Integer;
  Sizes: array of Integer;
  Running: Integer;
begin
  Result := 0;
  if FMessages.Count <= 2 then Exit;

  SetLength(Sizes, FMessages.Count);
  Total := 0;
  for I := 0 to FMessages.Count - 1 do
  begin
    Sizes[I] := Length(FMessages.Item(I).ToJson);
    Inc(Total, Sizes[I]);
  end;
  if Total <= KeepBytes then Exit;

  { Walk back from the end accumulating messages until the budget is spent;
    everything before that index goes. }
  Running := 0;
  Cut := 0;
  for I := FMessages.Count - 1 downto 0 do
  begin
    Inc(Running, Sizes[I]);
    if Running > KeepBytes then
    begin
      Cut := I + 1;
      Break;
    end;
  end;

  while (Cut < FMessages.Count) and
        ((FMessages.Item(Cut).Str('role') <> 'user') or
         IsToolResultMessage(FMessages.Item(Cut))) do
    Inc(Cut);

  { Never compact away everything: a transcript with no messages cannot be
    sent, and the last exchange is the one the user is still talking about. }
  if Cut >= FMessages.Count then Exit;

  for I := 1 to Cut do
    FMessages.Drop(0);
  Result := Cut;
end;

function TAgent.TokensOut: Int64;
begin
  Result := FTotalOut;
end;

{ Replaces the transcript with a model-written summary of it.  Dropping old
  turns loses what they established; asking the model to carry the substance
  forward in prose keeps it, at the cost of one request.

  The request is an ordinary exchange - transcript plus one instruction - so
  it streams and retries like any other.  The transcript is only replaced
  after a non-empty summary has fully arrived; every failure path restores
  the conversation exactly as it was, because a compaction that destroys the
  conversation on a dropped connection is worse than no compaction. }
function TAgent.CompactWithSummary(out Err: string): Boolean;
var
  Backup, StopReason, Summary: string;
  Blocks: TPartialBlocks;
  Cancelled: Boolean;
  Restored, Msg, Arr, B: TJson;
  I: Integer;

  procedure Restore;
  begin
    Restored := JsonParse(Backup);
    if Restored = nil then Exit;   { cannot happen: Backup came from ToJson }
    FMessages.Free;
    FMessages := Restored;
  end;

begin
  Err := '';
  Result := False;
  if FMessages.Count = 0 then
  begin
    Err := 'nothing to summarize';
    Exit;
  end;

  Backup := FMessages.ToJson;
  AppendUserText(
    'Summarize this conversation so far for your own future reference. ' +
    'Write plain prose, no tool calls. Preserve: what the user asked for, ' +
    'what was done and how, exact file paths and names involved, decisions ' +
    'made and their reasons, and anything still unfinished. Omit pleasantries ' +
    'and dead ends.');

  if not SendWithRetry(Blocks, StopReason, Err, Cancelled) then
  begin
    Restore;
    Exit;
  end;
  if Cancelled then
  begin
    Restore;
    Err := 'cancelled';
    Exit;
  end;

  Summary := '';
  for I := 0 to High(Blocks) do
    if Blocks[I].Kind = bkText then
      Summary := Summary + Blocks[I].Text;
  if Trim(Summary) = '' then
  begin
    Restore;
    Err := 'the model returned no summary';
    Exit;
  end;

  { The new transcript is one legal exchange: the summary as a user message
    (a transcript must open with one) and a short assistant acknowledgement,
    so the next question follows an assistant turn as the API requires. }
  FMessages.Free;
  FMessages := TJson.NewArr;
  AppendUserText('Summary of the conversation so far, carried over after ' +
    'compaction:'#10#10 + Summary);
  Arr := TJson.NewArr;
  B := TJson.NewObj;
  B.AddStr('type', 'text');
  B.AddStr('text', 'Understood. I have the context and will continue from it.');
  Arr.Push(B);
  Msg := TJson.NewObj;
  Msg.AddStr('role', 'assistant');
  Msg.Add('content', Arr);
  FMessages.Push(Msg);
  Result := True;
end;

function TAgent.CacheWriteTokens: Int64;
begin
  Result := FCacheWrite;
end;

function TAgent.CacheReadTokens: Int64;
begin
  Result := FCacheRead;
end;

function TAgent.TurnCount: Integer;
begin
  Result := FTurns;
end;

function TAgent.BuildBody: string;
var
  Root, Msgs, M, C: TJson;
  I: Integer;
  SysBlock, SysArr, Content, LastBlock, CC, Tools: TJson;
begin
  Root := TJson.NewObj;
  try
    Root.AddStr('model', FModel);
    { Thinking spends from the same max_tokens pot as the reply, so the
      ceiling rises with the budget or a long think would starve the
      answer that follows it. }
    if FThinkingBudget > 0 then
      Root.AddNum('max_tokens', FMaxTokens + FThinkingBudget)
    else
      Root.AddNum('max_tokens', FMaxTokens);
    Root.AddBool('stream', True);
    if FThinkingBudget > 0 then
    begin
      CC := TJson.NewObj;
      CC.AddStr('type', 'enabled');
      CC.AddNum('budget_tokens', FThinkingBudget);
      Root.Add('thinking', CC);
    end;
    { The system prompt travels as a content block so it can carry a
      cache_control marker.  The cache covers the request prefix up to the
      marker - tools come before system in that prefix - so this one
      breakpoint makes the API reuse both instead of re-reading a few
      thousand tokens of identical text on every turn. }
    if FSystem <> '' then
    begin
      SysArr := TJson.NewArr;
      { Under an OAuth token the API insists the system prompt open with
        Claude Code's own identity line, exactly.  It goes in as its own
        block ahead of ours, which continues unchanged. }
      if Copy(FApiKey, 1, Length(OauthKeyPrefix)) = OauthKeyPrefix then
      begin
        SysBlock := TJson.NewObj;
        SysBlock.AddStr('type', 'text');
        SysBlock.AddStr('text', OauthIdentity);
        SysArr.Push(SysBlock);
      end;
      SysBlock := TJson.NewObj;
      SysBlock.AddStr('type', 'text');
      SysBlock.AddStr('text', FSystem);
      CC := TJson.NewObj;
      CC.AddStr('type', 'ephemeral');
      SysBlock.Add('cache_control', CC);
      SysArr.Push(SysBlock);
      Root.Add('system', SysArr);
    end;
    { Web search is declared only when the user asked for it.  Absent, the
      model has no way to reach the network and the session pays no tokens
      for a tool it may not use; ownership is unchanged, the array still
      goes to Root. }
    Tools := ToolsSchema;
    if FWebSearch then Tools.Push(WebSearchToolDef);
    Root.Add('tools', Tools);

    { The transcript is copied rather than handed over, because FMessages
      must survive this request for the next turn. }
    Msgs := TJson.NewArr;
    for I := 0 to FMessages.Count - 1 do
    begin
      M := FMessages.Item(I);
      C := JsonParse(M.ToJson);
      if C <> nil then Msgs.Push(C);
    end;
    { A second marker on the final content block caches the conversation so
      far.  Each turn then only pays full price for what was added since the
      last one - the cache grows with the transcript instead of being
      invalidated by it.  It goes on the copy, never on FMessages, so the
      stored transcript stays free of transport concerns. }
    if Msgs.Count > 0 then
    begin
      Content := Msgs.Item(Msgs.Count - 1).Find('content');
      if (Content <> nil) and (Content.Count > 0) then
      begin
        LastBlock := Content.Item(Content.Count - 1);
        if (LastBlock <> nil) and (LastBlock.Kind = jkObj) and
           (LastBlock.Str('type') <> 'thinking') and
           (LastBlock.Find('cache_control') = nil) then
        begin
          CC := TJson.NewObj;
          CC.AddStr('type', 'ephemeral');
          LastBlock.Add('cache_control', CC);
        end;
      end;
    end;
    Root.Add('messages', Msgs);
    Result := Root.ToJson;
  finally
    Root.Free;
  end;
end;

{ Whether an API key or a subscription token may declare web search, and
  whether this dated type string is still the current one, are both things
  only a live server can answer.  Rather than guess, the failure is caught:
  a rejection that names the tool turns it off and the round is retried, so
  the worst case is one wasted request and a notice instead of a session
  where every turn fails.  The match is on the message the API sends back,
  which SendOnce has already appended to Err. }
function TAgent.DisableWebSearchAfterRejection(const Err: string): Boolean;
var
  Low: string;
begin
  Result := False;
  if not FWebSearch then Exit;
  Low := LowerCase(Err);
  if Pos('web_search', Low) = 0 then Exit;
  if (Pos('400', Low) = 0) and (Pos('invalid_request', Low) = 0) then Exit;
  FWebSearch := False;
  if Assigned(OnNotice) then
    OnNotice('web search rejected by the API - disabled for this session');
  Result := True;
end;

function TAgent.SendOnce(out Blocks: TPartialBlocks; out StopReason: string;
  out Err: string; out Cancelled: Boolean): Boolean;
var
  St: TStreamState;
  Headers, Body: string;
  Res: THttpResult;
  ErrJson, ErrObj: TJson;
begin
  Blocks := nil;
  StopReason := '';
  Err := '';
  Cancelled := False;

  St.Buf := '';
  St.Blocks := nil;
  St.Agent := Self;
  St.StopReason := '';
  St.InTok := 0;
  St.OutTok := 0;
  St.CacheWrite := 0;
  St.CacheRead := 0;
  St.ErrText := '';
  St.Cancel := False;

  { A subscription OAuth token authenticates as a Bearer with its beta flag;
    an API key rides the x-api-key header.  Same endpoint either way. }
  if Copy(FApiKey, 1, Length(OauthKeyPrefix)) = OauthKeyPrefix then
    Headers :=
      'authorization: Bearer ' + FApiKey + #13#10 +
      'anthropic-beta: ' + OauthBeta + #13#10 +
      'anthropic-version: ' + ApiVersion + #13#10 +
      'content-type: application/json' + #13#10 +
      'accept: text/event-stream'
  else
    Headers :=
      'x-api-key: ' + FApiKey + #13#10 +
      'anthropic-version: ' + ApiVersion + #13#10 +
      'content-type: application/json' + #13#10 +
      'accept: text/event-stream';

  Body := BuildBody;
  Res := HttpPost(ApiUrl, Headers, Body, @StreamChunk, @St);
  { Clamped on this side too: a substituted transport may leave the field
    uninitialized, and a nonsense wait must not become a nonsense sleep. }
  FRetryAfterMs := Res.RetryAfterMs;
  if (FRetryAfterMs < 0) or (FRetryAfterMs > 60000) then FRetryAfterMs := 0;

  { A user-cancelled transfer is not a failure: whatever was decoded before
    the abort is kept, so the partial reply stays in the transcript and the
    conversation remains coherent. }
  if St.Cancel then
  begin
    Cancelled := True;
    Inc(FTotalIn, St.InTok);
    Inc(FCacheWrite, St.CacheWrite);
    Inc(FCacheRead, St.CacheRead);
    Inc(FTotalOut, St.OutTok);
    FLastPromptTokens := St.InTok + St.CacheWrite + St.CacheRead;
    Blocks := St.Blocks;
    StopReason := 'cancelled';
    Exit(True);
  end;

  if not Res.Ok then
  begin
    Err := Res.Error;
    { The API reports failures as a JSON document; surface its message rather
      than a bare status code, which is rarely enough to act on. }
    if Res.Body <> '' then
    begin
      ErrJson := JsonParse(Res.Body);
      if ErrJson <> nil then
      try
        ErrObj := ErrJson.Find('error');
        if ErrObj <> nil then
          Err := Err + ' - ' + ErrObj.Str('type') + ': ' + ErrObj.Str('message')
        else
          Err := Err + ' - ' + Copy(Res.Body, 1, 500);
      finally
        ErrJson.Free;
      end
      else
        Err := Err + ' - ' + Copy(Res.Body, 1, 500);
    end;
    Exit(False);
  end;

  if St.ErrText <> '' then
  begin
    Err := St.ErrText;
    Exit(False);
  end;

  Inc(FTotalIn, St.InTok);
  Inc(FCacheWrite, St.CacheWrite);
  Inc(FCacheRead, St.CacheRead);
  Inc(FTotalOut, St.OutTok);
  FLastPromptTokens := St.InTok + St.CacheWrite + St.CacheRead;
  Blocks := St.Blocks;
  StopReason := St.StopReason;
  Result := True;
end;

procedure TAgent.RecordAssistant(const Blocks: TPartialBlocks);
var
  Msg, Arr, B, Input: TJson;
  I: Integer;
begin
  if Length(Blocks) = 0 then Exit;
  Arr := TJson.NewArr;
  for I := 0 to High(Blocks) do
  begin
    case Blocks[I].Kind of
      bkText:
        begin
          if Trim(Blocks[I].Text) = '' then Continue;
          B := TJson.NewObj;
          B.AddStr('type', 'text');
          B.AddStr('text', Blocks[I].Text);
        end;
      bkThinking:
        begin
          B := TJson.NewObj;
          B.AddStr('type', 'thinking');
          B.AddStr('thinking', Blocks[I].Text);
          B.AddStr('signature', Blocks[I].Signature);
        end;
      bkToolUse:
        begin
          B := TJson.NewObj;
          B.AddStr('type', 'tool_use');
          B.AddStr('id', Blocks[I].Id);
          B.AddStr('name', Blocks[I].Name);
          { An empty argument list streams as no deltas at all. }
          if Trim(Blocks[I].Text) = '' then
            Input := TJson.NewObj
          else
          begin
            Input := JsonParse(Blocks[I].Text);
            if Input = nil then Input := TJson.NewObj;
          end;
          B.Add('input', Input);
        end;
      bkServerToolUse:
        begin
          { Identical to a local tool call but for the type, which the API
            uses to pair the call with the result block it produced. }
          B := TJson.NewObj;
          B.AddStr('type', 'server_tool_use');
          B.AddStr('id', Blocks[I].Id);
          B.AddStr('name', Blocks[I].Name);
          if Trim(Blocks[I].Text) = '' then
            Input := TJson.NewObj
          else
          begin
            Input := JsonParse(Blocks[I].Text);
            if Input = nil then Input := TJson.NewObj;
          end;
          B.Add('input', Input);
        end;
      bkResult:
        begin
          { Echoed byte-for-byte: this client never understood the block, so
            reconstructing it is the one thing guaranteed to be wrong. }
          B := JsonParse(Blocks[I].Text);
          if B = nil then Continue;
        end;
    else
      Continue;
    end;
    Arr.Push(B);
  end;

  if Arr.Count = 0 then
  begin
    Arr.Free;
    Exit;
  end;
  Msg := TJson.NewObj;
  Msg.AddStr('role', 'assistant');
  Msg.Add('content', Arr);
  FMessages.Push(Msg);
end;

function TAgent.RunTools(const Blocks: TPartialBlocks): Boolean;
var
  I: Integer;
  Input, Results, R, Msg: TJson;
  Output, Detail: string;
  IsErr: Boolean;
  Prev: TAgent;
begin
  Result := False;
  Results := TJson.NewArr;
  try
    for I := 0 to High(Blocks) do
    begin
      if Blocks[I].Kind <> bkToolUse then Continue;
      Result := True;

      if Trim(Blocks[I].Text) = '' then
        Input := TJson.NewObj
      else
      begin
        Input := JsonParse(Blocks[I].Text);
        if Input = nil then Input := TJson.NewObj;
      end;
      try
        Detail := DescribeTool(Blocks[I].Name, Input);
        if Assigned(OnToolStart) then OnToolStart(Blocks[I].Name, Detail);
        { Only the call itself is wrapped: this is the window in which a task
          tool may reach back for its parent, and saving the previous value
          rather than nil'ing it keeps the nesting honest even though the
          depth cap allows only one level. }
        Prev := ActiveAgent;
        ActiveAgent := Self;
        try
          Output := uTools.RunTool(Blocks[I].Name, Input, Ask, IsErr);
        finally
          ActiveAgent := Prev;
        end;
        if Assigned(OnToolResult) then
          OnToolResult(Blocks[I].Name, Output);

        R := TJson.NewObj;
        R.AddStr('type', 'tool_result');
        R.AddStr('tool_use_id', Blocks[I].Id);
        R.AddStr('content', Output);
        if IsErr then R.AddBool('is_error', True);
        Results.Push(R);
      finally
        Input.Free;
      end;
    end;

    if not Result then
    begin
      Results.Free;
      Exit;
    end;
    Msg := TJson.NewObj;
    Msg.AddStr('role', 'user');
    Msg.Add('content', Results);
    FMessages.Push(Msg);
    Results := nil;
  except
    Results.Free;
    raise;
  end;
end;

{ ------------------------------------------------------------ test seams -- }

function TAgent.DecodeStream(const Chunks: array of string;
  out StopReason, Err: string): TPartialBlocks;
var
  St: TStreamState;
  I: Integer;
begin
  St.Buf := '';
  St.Blocks := nil;
  St.Agent := Self;
  St.StopReason := '';
  St.InTok := 0;
  St.OutTok := 0;
  St.CacheWrite := 0;
  St.CacheRead := 0;
  St.ErrText := '';
  St.Cancel := False;
  for I := Low(Chunks) to High(Chunks) do
    StreamChunk(Chunks[I], @St);
  Inc(FTotalIn, St.InTok);
  Inc(FTotalOut, St.OutTok);
  Inc(FCacheWrite, St.CacheWrite);
  Inc(FCacheRead, St.CacheRead);
  StopReason := St.StopReason;
  Err := St.ErrText;
  Result := St.Blocks;
end;

function TAgent.Transcript: string;
begin
  Result := FMessages.ToJson;
end;

function TAgent.RequestBody: string;
begin
  Result := BuildBody;
end;

procedure TAgent.ApplyBlocks(const Blocks: TPartialBlocks; out RanTools: Boolean);
begin
  RecordAssistant(Blocks);
  RanTools := RunTools(Blocks);
end;

{ ------------------------------------------------------------- persistence -- }

{ A saved session is the transcript plus enough context to tell whether
  resuming it makes sense.  The API key is deliberately not stored: it belongs
  in the environment, and writing it into a file inside the user's project is
  how secrets end up committed. }
function TAgent.SaveSession(const Path: string; out Err: string): Boolean;
var
  Root, Msgs, M: TJson;
  F: TFileStream;
  Dir, Text, Tmp: string;
  I: Integer;
begin
  Err := '';
  Result := False;
  Root := TJson.NewObj;
  try
    Root.AddNum('version', SessionVersion);
    Root.AddStr('model', FModel);
    Root.AddNum('turns', FTurns);
    Root.AddNum('tokens_in', FTotalIn);
    Root.AddNum('tokens_out', FTotalOut);
    Root.AddStr('saved_at', FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));

    Msgs := TJson.NewArr;
    for I := 0 to FMessages.Count - 1 do
    begin
      M := JsonParse(FMessages.Item(I).ToJson);
      if M <> nil then Msgs.Push(M);
    end;
    Root.Add('messages', Msgs);
    Text := Root.ToJson;
  finally
    Root.Free;
  end;

  Dir := ExtractFilePath(Path);
  if (Dir <> '') and not DirectoryExists(Dir) then
    if not ForceDirectories(Dir) then
    begin
      Err := 'cannot create ' + Dir;
      Exit;
    end;
  { Written to a temporary file and renamed over the old one.  fmCreate
    truncates immediately, so writing in place would mean a crash or a full
    disk mid-write destroys the previous good session as well as the new one -
    and this runs after every single turn, so "mid-write" is not a rare
    moment.  A rename is atomic enough that the file on disk is always one
    complete session or the other. }
  Tmp := Path + '.tmp';
  try
    F := TFileStream.Create(Tmp, fmCreate);
    try
      if Text <> '' then F.WriteBuffer(Text[1], Length(Text));
    finally
      F.Free;
    end;
  except
    on E: Exception do
    begin
      Err := E.Message;
      DeleteFile(Tmp);
      Exit;
    end;
  end;

  { DeleteFile then RenameFile, because Windows will not rename onto an
    existing name.  The window between them is the one failure this cannot
    close, so the temporary file is left in place as evidence if it happens. }
  if FileExists(Path) and not DeleteFile(Path) then
  begin
    Err := 'cannot replace ' + Path;
    Exit;
  end;
  if not RenameFile(Tmp, Path) then
  begin
    Err := 'cannot rename ' + Tmp;
    Exit;
  end;
  Result := True;
end;

{ A transcript is only legal if it opens with a user message and every
  tool_use is answered by a tool_result in the message that follows.  A file
  that fails either test is rejected whole: loading it would poison every
  request from then on, and a refusal the user can see beats a session that
  mysteriously cannot talk to the API. }
function ValidTranscript(Msgs: TJson; out Err: string): Boolean;
var
  I, J, K: Integer;
  M, Content, Block, NextContent: TJson;
  Role, BType: string;
  Answered: Boolean;
begin
  Err := '';
  Result := False;
  if (Msgs = nil) or (Msgs.Kind <> jkArr) then
  begin
    Err := 'no messages array';
    Exit;
  end;
  if Msgs.Count = 0 then Exit(True);   { an empty session is simply a new one }

  if Msgs.Item(0).Str('role') <> 'user' then
  begin
    Err := 'transcript does not start with a user message';
    Exit;
  end;

  for I := 0 to Msgs.Count - 1 do
  begin
    M := Msgs.Item(I);
    Role := M.Str('role');
    if (Role <> 'user') and (Role <> 'assistant') then
    begin
      Err := Format('message %d has role "%s"', [I, Role]);
      Exit;
    end;
    Content := M.Find('content');
    if (Content = nil) or (Content.Kind <> jkArr) or (Content.Count = 0) then
    begin
      Err := Format('message %d has no content blocks', [I]);
      Exit;
    end;

    for J := 0 to Content.Count - 1 do
    begin
      Block := Content.Item(J);
      if (Block = nil) or (Block.Kind <> jkObj) then
      begin
        Err := Format('message %d block %d is not an object', [I, J]);
        Exit;
      end;
      BType := Block.Str('type');
      if BType = '' then
      begin
        Err := Format('message %d block %d has no type', [I, J]);
        Exit;
      end;
      { The one structural rule the API enforces that a saved file can
        plausibly violate: an unanswered tool call. }
      if BType = 'tool_use' then
      begin
        Answered := False;
        if I + 1 < Msgs.Count then
        begin
          NextContent := Msgs.Item(I + 1).Find('content');
          if (NextContent <> nil) and (NextContent.Kind = jkArr) then
            for K := 0 to NextContent.Count - 1 do
              if (NextContent.Item(K).Str('type') = 'tool_result') and
                 (NextContent.Item(K).Str('tool_use_id') = Block.Str('id')) then
                Answered := True;
        end;
        if not Answered then
        begin
          Err := Format('message %d has an unanswered tool call', [I]);
          Exit;
        end;
      end;
    end;
  end;
  Result := True;
end;

function TAgent.LoadSession(const Path: string; out Err: string): Boolean;
var
  F: TFileStream;
  Text: string;
  Root, Msgs, Copy_: TJson;
  I: Integer;
begin
  Err := '';
  Result := False;
  if not FileExists(Path) then
  begin
    Err := 'no saved session at ' + Path;
    Exit;
  end;
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Text, F.Size);
      if F.Size > 0 then F.ReadBuffer(Text[1], F.Size);
    finally
      F.Free;
    end;
  except
    on E: Exception do
    begin
      Err := E.Message;
      Exit;
    end;
  end;

  Root := JsonParse(Text);
  if Root = nil then
  begin
    Err := 'the saved session is not valid JSON';
    Exit;
  end;
  try
    if Root.Kind <> jkObj then
    begin
      Err := 'the saved session is not an object';
      Exit;
    end;
    { A file from a future version may use a shape this build cannot honour,
      so it is refused rather than half-understood. }
    if Round(Root.Num('version', 0)) > SessionVersion then
    begin
      Err := Format('the saved session is version %d; this build understands %d',
        [Round(Root.Num('version', 0)), SessionVersion]);
      Exit;
    end;
    Msgs := Root.Find('messages');
    if not ValidTranscript(Msgs, Err) then
    begin
      if Err = '' then Err := 'the saved session is not a usable transcript';
      Exit;
    end;

    { Only now is the live conversation replaced, so a rejected file leaves
      the current session untouched. }
    FMessages.Free;
    FMessages := TJson.NewArr;
    for I := 0 to Msgs.Count - 1 do
    begin
      Copy_ := JsonParse(Msgs.Item(I).ToJson);
      if Copy_ <> nil then FMessages.Push(Copy_);
    end;
    FTurns := Round(Root.Num('turns', 0));
    FTotalIn := Round(Root.Num('tokens_in', 0));
    FTotalOut := Round(Root.Num('tokens_out', 0));
    { The model is restored only when the caller did not pick one, so an
      explicit ANTHROPIC_MODEL still wins over whatever was saved. }
    if Root.Str('model') <> '' then FModel := Root.Str('model');
    Result := True;
  finally
    Root.Free;
  end;
end;

{ True for the failures that are worth trying again: the server was busy or
  the connection dropped.  A 4xx other than 429 means the request itself is
  wrong, so retrying it would just fail identically. }
function Transient(const Err: string): Boolean;
begin
  Result := (Pos('429', Err) > 0) or (Pos('529', Err) > 0) or
            (Pos('overloaded', Err) > 0) or (Pos('rate_limit', Err) > 0) or
            (Pos('HTTP 500', Err) > 0) or (Pos('HTTP 502', Err) > 0) or
            (Pos('HTTP 503', Err) > 0) or (Pos('HTTP 504', Err) > 0);
end;

{ Sends one request, retrying transient failures with a widening delay. }
function TAgent.SendWithRetry(out Blocks: TPartialBlocks;
  out StopReason, Err: string; out Cancelled: Boolean): Boolean;
var
  Attempt, Wait: Integer;
begin
  for Attempt := 0 to MaxRetries do
  begin
    Result := SendOnce(Blocks, StopReason, Err, Cancelled);
    if Result or Cancelled then Exit;
    if not Transient(Err) then Exit;
    if Attempt = MaxRetries then Exit;

    { 1s, 2s, 4s by default.  Long enough to clear a burst, short enough that
      the user does not think the program has hung.  When the server named
      its own wait in Retry-After, that wins: guessing shorter re-hits the
      limit, guessing longer wastes the user's time. }
    Wait := RetryBaseMs shl Attempt;
    if FRetryAfterMs > 0 then Wait := FRetryAfterMs;
    if Assigned(OnNotice) then
      OnNotice(Format('%s - retrying in %dms (%d of %d)',
        [Err, Wait, Attempt + 1, MaxRetries]));
    if not SleepCancellable(Wait) then
    begin
      Cancelled := True;
      Exit(True);
    end;
  end;
end;

{ Waits, but breaks early when the user cancels.  Returns False if cancelled. }
function TAgent.SleepCancellable(Ms: Integer): Boolean;
var
  Waited, Step: Integer;
begin
  Step := 50;
  if Ms < Step then Step := Ms;
  if Step <= 0 then Exit(not WantsCancel);
  Waited := 0;
  while Waited < Ms do
  begin
    if WantsCancel then Exit(False);
    Sleep(Step);
    Inc(Waited, Step);
  end;
  Result := True;
end;

procedure TAgent.AppendUserText(const S: string);
var
  Msg, Arr, B: TJson;
begin
  if Trim(S) = '' then Exit;
  B := TJson.NewObj;
  B.AddStr('type', 'text');
  B.AddStr('text', S);
  Arr := TJson.NewArr;
  Arr.Push(B);
  Msg := TJson.NewObj;
  Msg.AddStr('role', 'user');
  Msg.Add('content', Arr);
  FMessages.Push(Msg);
end;

function TAgent.Send(const UserText: string; out Err: string): Boolean;
var
  Blocks: TPartialBlocks;
  StopReason: string;
  Round: Integer;
  Cancelled: Boolean;
begin
  Err := '';
  { Only a top-level turn may clear the latch.  A subagent's own Send runs
    with ActiveAgent set, and clearing it here would erase the very abort the
    subagent was started to propagate. }
  if ActiveAgent = nil then ForceCancel := False;
  AppendUserText(UserText);

  Inc(FTurns);
  for Round := 1 to FMaxRounds do
  begin
    if not SendWithRetry(Blocks, StopReason, Err, Cancelled) then
    begin
      { A refusal of the web search declaration is recoverable: the tool is
        dropped and the identical round goes out again.  This costs one of
        the tool rounds, which is the right bound - a server that keeps
        refusing cannot spin here forever. }
      if DisableWebSearchAfterRejection(Err) then
      begin
        Err := '';
        Continue;
      end;
      { The turn dies here, possibly with tool results already appended that
        the model never saw.  Leaving them would make the next question a
        second user turn in a row, so the tail is unwound before giving up. }
      UnwindUnsentTail;
      Exit(False);
    end;
    RecordAssistant(Blocks);
    if Cancelled then
    begin
      { Any tool the model asked for before the abort is deliberately not
        run: the user said stop.  The partial reply is kept so the next turn
        still reads sensibly, and the unanswered tool_use blocks are dropped
        from the transcript so the API does not reject the next request. }
      DropUnansweredToolCalls;
      UnwindCancelledTail;
      if Assigned(OnNotice) then OnNotice('cancelled');
      Exit(True);
    end;
    { A long server-side tool run stops the turn early with pause_turn rather
      than finishing it.  The documented resume is simply to send again with
      the assistant turn already appended, which RecordAssistant has just
      done - so the next round is the resume.  Without this the turn would
      end here looking complete but cut off mid-thought.  MaxToolRounds
      bounds how many times a turn may pause. }
    if StopReason = 'pause_turn' then Continue;
    if not RunTools(Blocks) then
      Exit(True);
    { The abort can also come from inside the tool call that just finished: a
      subagent that was cancelled propagates the user's Esc through
      ForceCancel, and a tool that ran for a minute gives the user plenty of
      time to press it.  Noticing here rather than letting the next request go
      out to be aborted mid-stream saves a round trip and, more to the point,
      keeps the transcript from gaining a turn nobody asked for.  ForceCancel
      is tested first inside WantsCancel, so a latched abort does not consume
      the host's own consume-on-read flag. }
    if WantsCancel then
    begin
      UnwindCancelledTail;
      if Assigned(OnNotice) then OnNotice('cancelled');
      Exit(True);
    end;
    { A tool ran, so the model gets another go with the results in hand. }
  end;

  if Assigned(OnNotice) then
    OnNotice(Format('stopped after %d tool rounds', [FMaxRounds]));
  { The loop exits directly after RunTools appended a tool_result message that
    was never sent, so the transcript ends on a user turn.  The next question
    would then sit behind it as a second user turn in a row, and the work those
    tools did would never be seen by the model at all.  Dropping that message
    puts the conversation back to the last assistant turn, which is a state the
    next question can legally follow. }
  UnwindUnsentTail;
  Result := True;
end;

{ A turn can stop with tool results already appended that the model never saw:
  the round limit cuts the loop, and a transport failure aborts it.  Either way
  the transcript ends on a user turn, so the next question would sit behind it
  as a second one - and the work those tools did is never seen at all.

  Unwinding the results also strips the tool_use blocks they answered, which
  can empty that assistant message and expose more results underneath, so this
  repeats.  It stops while the user's original question is still there, or the
  turn would erase itself entirely; that question is then trimmed too, being
  the same unanswered state a failed turn leaves. }
{ Two shapes of cancelled turn need two different repairs.  Cancel a reply
  mid-stream and the transcript ends on the user's question with nothing
  answering it, which TrimUnansweredQuestion removes.  Cancel from inside a
  tool call and RunTools has already pushed its results, so the transcript
  ends on a tool_result user message the model will never see - and
  TrimUnansweredQuestion rightly refuses to drop a tool_result, so the next
  question would sit behind it as a second user turn in a row and the API
  would reject it.  That case needs the full unwind.

  It cannot simply unwind in both cases: with a trailing assistant message the
  unwind's while loop never runs and a dangling tool_use would survive. }
procedure TAgent.UnwindCancelledTail;
begin
  if (FMessages.Count > 0) and
     (FMessages.Item(FMessages.Count - 1).Str('role') = 'user') then
    UnwindUnsentTail
  else
    TrimUnansweredQuestion;
end;

procedure TAgent.UnwindUnsentTail;
begin
  while (FMessages.Count > 1) and
        (FMessages.Item(FMessages.Count - 1).Str('role') = 'user') do
  begin
    FMessages.Drop(FMessages.Count - 1);
    DropUnansweredToolCalls;
  end;
  TrimUnansweredQuestion;
end;

{ The API rejects a request whose last assistant message contains a tool_use
  with no matching tool_result.  After a cancellation that is exactly the
  state, so those blocks are stripped; if nothing else remains, the message
  goes too.

  A server-side call is the same hazard with a different shape: its result
  arrives as a later block of the same message rather than in a following
  user turn, so a cancel landing between the two leaves a dangling
  server_tool_use the API refuses just as firmly.  Those are dropped only
  when their result never arrived - a completed pair must survive intact. }
function HasResultFor(Content: TJson; const Id: string): Boolean;
var
  I: Integer;
  B: TJson;
  T: string;
begin
  Result := False;
  if (Content = nil) or (Id = '') then Exit;
  for I := 0 to Content.Count - 1 do
  begin
    B := Content.Item(I);
    if B = nil then Continue;
    T := B.Str('type');
    { Every server tool names its result block <tool>_tool_result, so the
      suffix matches web search and whatever ships beside it later. }
    if (Length(T) > Length('_tool_result')) and
       (Copy(T, Length(T) - Length('_tool_result') + 1, MaxInt) = '_tool_result') and
       (B.Str('tool_use_id') = Id) then
      Exit(True);
  end;
end;

procedure TAgent.DropUnansweredToolCalls;
var
  Last, Content, Keep: TJson;
  I: Integer;
begin
  if FMessages.Count = 0 then Exit;
  Last := FMessages.Item(FMessages.Count - 1);
  if Last.Str('role') <> 'assistant' then Exit;
  Content := Last.Find('content');
  if Content = nil then Exit;

  Keep := TJson.NewArr;
  for I := 0 to Content.Count - 1 do
    if (Content.Item(I).Str('type') <> 'tool_use') and
       not ((Content.Item(I).Str('type') = 'server_tool_use') and
            not HasResultFor(Content, Content.Item(I).Str('id'))) then
      Keep.Push(JsonParse(Content.Item(I).ToJson));

  if Keep.Count = Content.Count then
  begin
    Keep.Free;
    Exit;
  end;

  { Rebuilding the message is simpler than editing it in place, and TJson has
    no removal operation by design. }
  FMessages.Drop(FMessages.Count - 1);
  if Keep.Count > 0 then
  begin
    Last := TJson.NewObj;
    Last.AddStr('role', 'assistant');
    Last.Add('content', Keep);
    FMessages.Push(Last);
  end
  else
    Keep.Free;
end;

{ --------------------------------------------------------------- subagent -- }

{ A subagent's own streaming stays off the terminal: two agents writing prose
  to one console interleaved is unreadable, and the user did not ask the
  second one anything.  What is forwarded is one line per tool it runs, so the
  wait is visibly alive and the user can see what is being read on their
  behalf. }
procedure SubToolStart(const Name, Detail: string);
begin
  if Assigned(SubHost) and Assigned(SubHost.OnToolStart) then
    SubHost.OnToolStart(Name, '-> ' + Detail);
end;

procedure SubNotice(const S: string);
begin
  { Latched rather than forwarded and forgotten: this is the only report that
    the nested turn was aborted, and the parent has to act on it. }
  if S = 'cancelled' then SubWasCancelled := True;
  if Assigned(SubHost) and Assigned(SubHost.OnNotice) then
    SubHost.OnNotice('subagent: ' + S);
end;

function RunSubagent(const Prompt, SystemExtra: string;
  out Reply, Err: string): Boolean;
var
  Parent, Sub: TAgent;
  SysText: string;
  SavedHost: TAgent;
  SavedCancelled: Boolean;
begin
  Result := False;
  Reply := '';
  Err := '';
  Parent := ActiveAgent;
  if Parent = nil then
  begin
    Err := 'no parent agent';
    Exit;
  end;
  { The parent's system prompt is deliberately NOT inherited: it carries the
    project memory and the guidance about getting writes approved, none of
    which applies to a helper that cannot write and has no user to ask. }
  SysText :=
    'You are a read-only subagent working inside a coding session rooted at ' +
    uTools.RootDir + '.' + #10 +
    'You have exactly three tools: read_file, list_dir and search. You ' +
    'cannot change files, run commands, fetch URLs, or start a subagent of ' +
    'your own.' + #10 +
    'Investigate what you were asked and then answer it in full. Your final ' +
    'message is the whole of what your caller receives - they see none of ' +
    'your intermediate steps - so it must stand on its own, cite the paths ' +
    'and line numbers you found, and say plainly when you could not find ' +
    'something.';
  if Trim(SystemExtra) <> '' then
    SysText := SysText + #10#10 + SystemExtra;

  Sub := TAgent.Create(Parent.FApiKey, Parent.FModel, SysText);
  try
    Sub.MaxRounds := uTools.SubagentMaxRounds;
    { Nil by construction rather than by omission: nothing a subagent can call
      asks permission, and a prompt raised on behalf of a hidden conversation
      would be unanswerable anyway. }
    Sub.Ask := nil;
    Sub.ShouldCancel := Parent.ShouldCancel;
    Sub.OnToolStart := @SubToolStart;
    Sub.OnNotice := @SubNotice;
    { Thinking is left off: a helper that reasons at budget doubles the bill
      of every delegated question, invisibly. }

    SavedHost := SubHost;
    SavedCancelled := SubWasCancelled;
    SubHost := Parent;
    SubWasCancelled := False;
    try
      Result := Sub.Send(Prompt, Err);
      { Counted whether or not the turn succeeded - a failed subagent still
        spent tokens, and a /cost that quietly omits them is a counter that
        lies in exactly the direction the user would mind. }
      Parent.AbsorbUsage(Sub);
      if Result then Reply := Sub.LastAssistantText;
      if SubWasCancelled then
      begin
        { The user's abort has to reach the parent's loop, and the parent may
          be several polls away from its next chance to notice. }
        ForceCancel := True;
        Err := 'cancelled';
        Result := False;
      end;
    finally
      SubHost := SavedHost;
      SubWasCancelled := SavedCancelled;
    end;
  finally
    Sub.Free;
  end;
end;

{ Whether the user has asked for the current turn to stop, asked from outside
  any agent.  ActiveAgent is set around every tool call, so during an MCP wait
  it is exactly the agent whose call is being waited on. }
function CancelDuringTool: Boolean;
begin
  Result := ForceCancel or (Assigned(ActiveAgent) and ActiveAgent.WantsCancel);
end;

initialization
  { The ladder crossing: uTools declares the hole because it is the unit that
    needs a way to run one, and the unit that knows what an agent is fills it.
    The same shape uHttp uses for the network transport. }
  uTools.SubagentRunner := @RunSubagent;
  { The same shape again, one rung further down.  Polish, not safety: uMcp's
    deadline is what guarantees a hung server cannot hang pasclaude, and this
    only lets Escape cut a sixty-second call short rather than waiting it
    out. }
  uMcp.McpShouldCancel := @CancelDuringTool;

end.
