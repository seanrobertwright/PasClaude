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
    FTurns: Integer;

    function BuildBody: string;
    { One request/response exchange.  Returns the blocks the model produced. }
    function SendOnce(out Blocks: TPartialBlocks; out StopReason: string;
      out Err: string): Boolean;
    { Appends an assistant message rebuilt from Blocks. }
    procedure RecordAssistant(const Blocks: TPartialBlocks);
    { Runs every tool_use block and appends the tool_result user message.
      Returns False when no tool was requested. }
    function RunTools(const Blocks: TPartialBlocks): Boolean;
  public
    OnText: TTextProc;             { streamed assistant prose }
    OnThinking: TTextProc;         { streamed reasoning, when the model emits it }
    OnToolStart: TToolProc;
    OnToolResult: TToolProc;
    OnNotice: TTextProc;           { status and error lines }
    Ask: TAskProc;

    constructor Create(const ApiKey, AModel, SystemPrompt: string);
    destructor Destroy; override;

    { Runs a full turn including any tool round-trips.  False with Err set
      when the exchange could not be completed. }
    function Send(const UserText: string; out Err: string): Boolean;

    procedure Reset;
    function TokensIn: Int64;
    function TokensOut: Int64;
    function TurnCount: Integer;
    property Model: string read FModel write FModel;
  end;

const
  DefaultModel  = 'claude-sonnet-4-20250514';
  ApiUrl        = 'https://api.anthropic.com/v1/messages';
  ApiVersion    = '2023-06-01';
  MaxToolRounds = 24;

implementation

uses SysUtils, uHttp;

{ ------------------------------------------------------------ stream state -- }

type
  PStream = ^TStreamState;
  TStreamState = record
    Buf: string;                 { bytes not yet split into complete lines }
    Blocks: TPartialBlocks;
    Agent: TAgent;
    StopReason: string;
    InTok, OutTok: Int64;
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

function TAgent.TokensOut: Int64;
begin
  Result := FTotalOut;
end;

function TAgent.TurnCount: Integer;
begin
  Result := FTurns;
end;

function TAgent.BuildBody: string;
var
  Root, Msgs, M, C: TJson;
  I: Integer;
begin
  Root := TJson.NewObj;
  try
    Root.AddStr('model', FModel);
    Root.AddNum('max_tokens', FMaxTokens);
    Root.AddBool('stream', True);
    if FSystem <> '' then
      Root.AddStr('system', FSystem);
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
    Root.Add('messages', Msgs);
    Result := Root.ToJson;
  finally
    Root.Free;
  end;
end;

function TAgent.SendOnce(out Blocks: TPartialBlocks; out StopReason: string;
  out Err: string): Boolean;
var
  St: TStreamState;
  Headers, Body: string;
  Res: THttpResult;
  ErrJson, ErrObj: TJson;
begin
  Blocks := nil;
  StopReason := '';
  Err := '';

  St.Buf := '';
  St.Blocks := nil;
  St.Agent := Self;
  St.StopReason := '';
  St.InTok := 0;
  St.OutTok := 0;
  St.ErrText := '';
  St.Cancel := False;

  Headers :=
    'x-api-key: ' + FApiKey + #13#10 +
    'anthropic-version: ' + ApiVersion + #13#10 +
    'content-type: application/json' + #13#10 +
    'accept: text/event-stream';

  Body := BuildBody;
  Res := HttpPost(ApiUrl, Headers, Body, @StreamChunk, @St);

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

function TAgent.Send(const UserText: string; out Err: string): Boolean;
var
  Msg, Arr, B: TJson;
  Blocks: TPartialBlocks;
  StopReason: string;
  Round: Integer;
begin
  Err := '';
  if Trim(UserText) <> '' then
  begin
    B := TJson.NewObj;
    B.AddStr('type', 'text');
    B.AddStr('text', UserText);
    Arr := TJson.NewArr;
    Arr.Push(B);
    Msg := TJson.NewObj;
    Msg.AddStr('role', 'user');
    Msg.Add('content', Arr);
    FMessages.Push(Msg);
  end;

  Inc(FTurns);
  for Round := 1 to MaxToolRounds do
  begin
    if not SendOnce(Blocks, StopReason, Err) then
      Exit(False);
    RecordAssistant(Blocks);
    if not RunTools(Blocks) then
      Exit(True);
    { A tool ran, so the model gets another go with the results in hand. }
  end;

  if Assigned(OnNotice) then
    OnNotice(Format('stopped after %d tool rounds', [MaxToolRounds]));
  Result := True;
end;

end.
