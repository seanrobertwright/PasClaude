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

  TBlockKind = (bkText, bkThinking, bkToolUse);

  TPartialBlock = record
    Kind: TBlockKind;
    Text: string;        { prose, reasoning, or accumulated tool JSON }
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

    function BuildBody: string;
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
  public
    OnText: TTextProc;             { streamed assistant prose }
    OnThinking: TTextProc;         { streamed reasoning, when the model emits it }
    OnToolStart: TToolProc;
    OnToolResult: TToolProc;
    OnNotice: TTextProc;           { status and error lines }
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
    { Bytes the transcript currently occupies as JSON. }
    function TranscriptBytes: Integer;
    function MessageCount: Integer;
    { Drops a trailing user message that never got an answer.  Returns True if
      one was removed. }
    function TrimUnansweredQuestion: Boolean;
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
  DefaultModel  = 'claude-sonnet-4-20250514';
  ApiUrl        = 'https://api.anthropic.com/v1/messages';
  ApiVersion    = '2023-06-01';
  MaxToolRounds = 24;
  { Transient failures are retried this many times before giving up. }
  MaxRetries    = 3;
  { Bumped when the saved-session shape changes incompatibly. }
  SessionVersion = 1;
  { Where a session lives, relative to the session root. }
  SessionDir  = '.pasclaude';
  SessionFile = 'session.json';

{ The default save location under Root. }
function SessionPath(const Root: string): string;

{ Copies an existing session aside so a run that is not resuming it cannot
  destroy it on the first save.  True when there was nothing to do, or the
  copy succeeded. }
function BackupSession(const Path: string; out Err: string): Boolean;

var
  { Base backoff in milliseconds; doubles per attempt.  Only the tests lower
    it, so a suite does not spend seconds asleep. }
  RetryBaseMs: Integer = 1000;

implementation

uses SysUtils, Classes, uHttp;

function SessionPath(const Root: string): string;
begin
  Result := IncludeTrailingPathDelimiter(Root) + SessionDir +
    PathDelim + SessionFile;
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
  CB, Delta, Msg, Usage, ErrObj: TJson;
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
    end
    else if K = 'thinking' then
    begin
      St^.Blocks[Idx].Kind := bkThinking;
      St^.Blocks[Idx].Text := CB.Str('thinking');
    end
    else
    begin
      St^.Blocks[Idx].Kind := bkText;
      St^.Blocks[Idx].Text := CB.Str('text');
    end;
  end

  else if T = 'content_block_delta' then
  begin
    Idx := Round(Ev.Num('index'));
    EnsureSlot(St, Idx);
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
      { Tool arguments stream as raw JSON text and are parsed once complete. }
      St^.Blocks[Idx].Text := St^.Blocks[Idx].Text + Delta.Str('partial_json');
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
  if Assigned(St^.Agent.ShouldCancel) and St^.Agent.ShouldCancel() then
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
  SysBlock, SysArr, Content, LastBlock, CC: TJson;
begin
  Root := TJson.NewObj;
  try
    Root.AddStr('model', FModel);
    Root.AddNum('max_tokens', FMaxTokens);
    Root.AddBool('stream', True);
    { The system prompt travels as a content block so it can carry a
      cache_control marker.  The cache covers the request prefix up to the
      marker - tools come before system in that prefix - so this one
      breakpoint makes the API reuse both instead of re-reading a few
      thousand tokens of identical text on every turn. }
    if FSystem <> '' then
    begin
      SysBlock := TJson.NewObj;
      SysBlock.AddStr('type', 'text');
      SysBlock.AddStr('text', FSystem);
      CC := TJson.NewObj;
      CC.AddStr('type', 'ephemeral');
      SysBlock.Add('cache_control', CC);
      SysArr := TJson.NewArr;
      SysArr.Push(SysBlock);
      Root.Add('system', SysArr);
    end;
    Root.Add('tools', ToolsSchema);

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

  Headers :=
    'x-api-key: ' + FApiKey + #13#10 +
    'anthropic-version: ' + ApiVersion + #13#10 +
    'content-type: application/json' + #13#10 +
    'accept: text/event-stream';

  Body := BuildBody;
  Res := HttpPost(ApiUrl, Headers, Body, @StreamChunk, @St);

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
        Output := uTools.RunTool(Blocks[I].Name, Input, Ask, IsErr);
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
      the user does not think the program has hung. }
    Wait := RetryBaseMs shl Attempt;
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
  if Step <= 0 then Exit(not (Assigned(ShouldCancel) and ShouldCancel()));
  Waited := 0;
  while Waited < Ms do
  begin
    if Assigned(ShouldCancel) and ShouldCancel() then Exit(False);
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
  AppendUserText(UserText);

  Inc(FTurns);
  for Round := 1 to MaxToolRounds do
  begin
    if not SendWithRetry(Blocks, StopReason, Err, Cancelled) then
    begin
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
      { If the abort landed before anything was recorded - or left only tool
        calls, which were just dropped - the transcript now ends on the user's
        question with nothing answering it.  That gets saved like any other
        turn, so it is trimmed here rather than in the caller: a cancel is not
        a failure, so the caller's error path never runs. }
      TrimUnansweredQuestion;
      if Assigned(OnNotice) then OnNotice('cancelled');
      Exit(True);
    end;
    if not RunTools(Blocks) then
      Exit(True);
    { A tool ran, so the model gets another go with the results in hand. }
  end;

  if Assigned(OnNotice) then
    OnNotice(Format('stopped after %d tool rounds', [MaxToolRounds]));
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
  goes too. }
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
    if Content.Item(I).Str('type') <> 'tool_use' then
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

end.
