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

uses uJson, uTools, uImage;

type
  { An image waiting to go out with the next user message.  It is queued
    rather than pushed straight into the transcript because the user's prose
    and the image belong in one message - the API is explicit that an image
    works best placed before the text it is asked about, and a message per
    attachment would put them in the wrong order and the wrong turns. }
  TImageAttach = record
    Media: string;    { one of the four types the API accepts }
    Data: string;     { base64, no line breaks }
    W, H: Integer;    { 0 when the format was recognised but not measurable }
  end;
  TImageAttachArray = array of TImageAttach;

  { Rendering hooks, so this unit stays free of console code. }
  TTextProc = procedure(const S: string);
  TToolProc = procedure(const Name, Detail: string);
  { Polled while a response streams; True abandons the request. }
  TCancelProc = function: Boolean;
  { Asked for a credential after one was refused.  Returns '' when there is
    no better one - this unit never treats that as an error, only as "do not
    retry".  A plain function variable, not a method pointer, so the host can
    wire a top-level function the way it wires HttpTransport. }
  TAuthRefreshFn = function: string;
  { Fires in RunTools with the tool's id and its effective input JSON - what
    RunTool will actually be given, after this unit's own repair of an
    unparseable argument stream.  The console never needed the id, because a
    human reads the calls in order; a protocol does, because its consumer has
    to pair a result with the call that produced it. }
  TToolInputProc = procedure(const Id, Name, InputJson: string);
  { Fires after the tool returns, carrying the id and the error flag.  IsError
    is otherwise local to RunTools and reachable from no hook at all, so a
    consumer could not tell a refusal from an answer. }
  TToolDoneProc = procedure(const Id, Name, Output: string; IsError: Boolean);

  TModelInfo = record
    Id: string;           { what the API wants in "model" }
    DisplayName: string;  { what a human calls it }
  end;
  TModelList = array of TModelInfo;

  { What a request is for, which is the only thing that decides which model
    carries it.  mrMain is the user's own turn and is never routed anywhere:
    the model they picked is the model that answers them. }
  TModelRole = (mrMain, mrSubagent, mrCompact);
  { makProfile is an alias that is not an id at all - it names one model for
    one situation and another for the rest, and is resolved at request time
    rather than when it is set. }
  TModelAliasKind = (makNone, makModel, makProfile);
  TModelUsage = record
    Model: string;
    TokensIn, TokensOut, CacheRead, CacheWrite: Int64;
  end;
  TModelUsageList = array of TModelUsage;

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
    { Images the user attached that no message has carried yet.  Drained by
      AppendUserText, never by AppendUserTextOnly. }
    FPendingImages: TImageAttachArray;
    FMaxTokens: Integer;
    FTotalIn, FTotalOut: Int64;
    FCacheWrite, FCacheRead: Int64;
    { Per-model rows behind the scalar totals above.  The scalars stay the
      truth about this session's tokens; these say which model spent them,
      which the scalars stopped being able to say the moment a role could be
      routed somewhere else. }
    FModelUsage: TModelUsageList;
    { What this agent's next request is for.  A field rather than a parameter
      threaded through BuildBody, because BuildBody is reached from the retry
      loop, the compaction path and the test seam, and a parameter would have
      to be correct at all three. }
    FRole: TModelRole;
    { What the last request actually carried, and the name it was resolved
      from.  The pair exists for the 404: a bare not_found_error cannot say
      that an alias produced the id, and the first turn is the worst possible
      moment to be told nothing. }
    FLastRequestModel: string;
    FLastRequestSource: string;
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
    { Whether the turn that just finished was aborted.  Cleared at the top of
      every Send, so it always describes the most recent turn and never a
      stale one. }
    FTurnCancelled: Boolean;
    { Whether this request has already spent its one auth retry.  Reset per
      SendWithRetry call rather than per turn, which is the strictly tighter
      bound: two dead sources alternating cannot loop, because the second
      attempt is the last one this request gets. }
    FAuthRefreshed: Boolean;

    { The cancel test every poll site uses.  ShouldCancel is consume-on-read
      in the host (CtrlCPressed clears the flag as it answers), so a subagent
      polling it would swallow the user's abort and leave the parent running.
      ForceCancel is the latch that makes the abort survive that. }
    function WantsCancel: Boolean;
    { Folds a finished subagent's token counts into this agent's, so /cost
      reports what the turn actually cost rather than what the parent alone
      spent. }
    procedure AbsorbUsage(Sub: TAgent);
    { Adds one response's usage to the row for Model, creating it if this is
      the first request that model carried. }
    procedure BumpModelUsage(const AModel: string;
      InTok, OutTok, CW, CR: Int64);
    { The model a usage row should be filed under.  FLastRequestModel is empty
      only on the recorded-stream seam, which never went near a transport. }
    function UsageModelKey: string;
    { What the role's model was resolved FROM - the alias name when there is
      one, so a failure can name it. }
    function RoleSource(Role: TModelRole): string;

    { True when the credential in hand is a subscription OAuth token rather
      than an API key.  Extracted because the same Copy() test used to be
      written out at three call sites - the messages request, the models
      request and the system-block builder - and a fourth request path would
      have had to remember all three.  One function means it cannot drift. }
    function IsOauth: Boolean;
    { Consults OnAuthRefresh after a 401, at most once per request, and
      installs a genuinely different key.  True when it did, meaning the
      caller should try the same request again. }
    function TryAuthRefresh(const Err: string): Boolean;

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
    { AppendUserText's original semantics: one text block, and the pending
      image queue is left strictly alone.  Every append this unit makes on its
      own behalf goes through here, because an internal bookkeeping message -
      a summarise instruction, say - must not spend the image the user just
      pasted and meant for their next question. }
    procedure AppendUserTextOnly(const S: string);
    { Puts the image blocks of a user message that is about to be dropped back
      on the pending queue.  AppendUserText drains the queue into the message
      before the request goes out, so a message removed because the turn never
      reached the server takes the attachment with it - and the clipboard the
      user copied it from may be long gone. }
    procedure RequeueImagesFrom(M: TJson);
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
    { The id-carrying pair, for a consumer that has to match one to the other.
      Both nil-safe and both additive: nothing that existed before this pair
      changed shape, so every host that never assigns them behaves exactly as
      it did. }
    OnToolInput: TToolInputProc;
    OnToolDone: TToolDoneProc;
    Ask: TAskProc;
    { Polled between chunks so the user can abandon a long reply. }
    ShouldCancel: TCancelProc;
    { Consulted ONLY on an HTTP 401, and at most once per request.  Nil by
      default and never assigned by this unit - the uHttp.HttpTransport
      pattern.  The host wires it to a credential re-resolve, so a token the
      owning program refreshed on disk mid-session is picked up without a
      restart; re-reading another program's file is not writing it.

      401 is deliberately NOT added to Transient(): a rejected credential is
      not a busy server, and retrying the same key would fail identically.
      The retry happens only when the callback hands back a non-empty key
      that DIFFERS from the one that was just refused. }
    OnAuthRefresh: TAuthRefreshFn;

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
    { Queues an image for the next user message.  B64 is already base64; this
      unit never sees pixels.  False with Err set when the queue is full or
      the media type is not one the API takes - a refusal the user reads beats
      a request the API rejects whole. }
    function AttachImage(const Media, B64: string; W, H: Integer;
      out Err: string): Boolean;
    { How many images are waiting for the next message. }
    function PendingImages: Integer;
    { Throws the queue away, for a user who changed their mind. }
    procedure ClearPendingImages;
    { Replaces every image block except the newest KeepNewest with a short
      text placeholder, oldest first, and returns how many it replaced.  Base64
      is re-sent in full on every turn until it goes, so on a long session the
      stale images are the most expensive and least re-read thing in the
      transcript.  Substitution rather than deletion is deliberate: removing a
      block could empty a content array, which ValidTranscript rejects, so a
      measure meant to save context would produce a session that will not
      load. }
    function EvictImages(KeepNewest: Integer): Integer;

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
    { The one place a model string is produced.  Every request path goes
      through it, so there is exactly one answer to "what will this carry",
      and a profile is expanded here - at request time - rather than when it
      was set, which is what lets /mode change the model with no new state to
      keep consistent. }
    function EffectiveModel(Role: TModelRole): string;
    { What the last request actually carried; '' before the first one. }
    function LastRequestModel: string;
    { Per-model token rows, with any subagent's already folded in.  A copy:
      the caller must not be able to edit the counters. }
    function UsageByModel: TModelUsageList;
    { May now hold an alias or a profile name rather than an id.  Deliberately
      unexpanded: /resume round-trips the profile, not a snapshot of whichever
      half happened to be active when the session was saved. }
    property Model: string read FModel write FModel;
    { Write-only, and uAuth is its only legitimate source.  It exists so
      /login takes effect without a restart - before it, FApiKey was set once
      in Create and a user who logged in mid-session would have gone on
      401ing until they restarted.  Write-only because nothing outside the
      credential layer has any business READING the key back out of the
      agent, and a getter is exactly the accessor a future feature would
      reach for on its way to putting the secret somewhere it does not
      belong.  Anything that plumbs a project-derived string in here has
      defeated the whole of uAuth. }
    property ApiKey: string write FApiKey;
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
    { True when the last Send ended because the user aborted it.  Send returns
      True for a cancelled turn as well as a finished one - both leave a legal
      transcript, which is what its Boolean means - so until now the only way
      to tell them apart was to read the human-facing 'cancelled' notice. }
    function TurnWasCancelled: Boolean;

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
    model can read it in slices through the tool instead.  This is a budget
    for TEXT: an image is not prose, is not read in slices, and is bounded by
    MaxImageFileBytes instead. }
  MaxMentionBytes = 100 * 1024;
  { Images in one message.  The API allows far more, but above twenty blocks
    it imposes a stricter per-image dimension limit, and eight keeps a turn
    structurally clear of that rule while bounding it at roughly twenty
    thousand visual tokens. }
  MaxImagesPerMessage = 8;
  { A mentioned image file larger than this is refused rather than attached.
    Its bytes are never transcoded - a JPEG cannot be resized without a
    decoder - so an oversize file is a refusal, not a resize. }
  MaxImageFileBytes = 5 * 1024 * 1024;
  { Where a session lives, relative to the session root. }
  SessionDir  = '.pasclaude';
  SessionFile = 'session.json';

{ ------------------------------------------------------------- aliases -- }

{ Short names for models, and the two routes.  This is a table of strings
  asserting things about a namespace this program does not own, which is
  exactly the mistake that produced the retired-default 404 recorded in the
  README - so three properties keep it from being that mistake twice:

    * every built-in target is a DATELESS family alias, the same class of
      string DefaultModel already is, and the server resolves it to whatever
      snapshot is current;
    * GET /v1/models stays the only authority - a bare /model annotates this
      table against the live list rather than the other way round;
    * any entry is overridable from %USERPROFILE%\.pasclaude\settings.json,
      so a stale table is an annoyance rather than a rebuild.

  An alias name may not contain '-' and may not begin with 'claude'.  Every
  model id Anthropic has shipped has hyphens and begins with 'claude', so no
  legal id can be captured by an alias and the resolution order stays
  readable.  It is a rule about someone else's naming convention, which is
  why it is stated here rather than assumed. }

{ True when Name is in the table.  Kind says whether Target is an id
  (makModel) or the two halves of a profile joined ' / ' (makProfile). }
function ResolveModelAlias(const Name: string; out Target: string;
  out Kind: TModelAliasKind): Boolean;
function ModelAliasCount: Integer;
function ModelAliasName(I: Integer): string;
{ For a profile: 'opus / sonnet'. }
function ModelAliasTarget(I: Integer): string;
{ Adds or replaces an entry.  False with Err set when the name breaks the
  no-hyphen/no-'claude' rule or the target is not something that could be a
  model id - a target with a control byte or invalid UTF-8 would go straight
  into the "model" field of a request. }
function SetModelAlias(const Name, Target: string; out Err: string): Boolean;
procedure SetModelRoute(Role: TModelRole; const NameOrId: string);
function ModelRoute(Role: TModelRole): string;
{ Resolves aliases and profiles to a concrete id, with a hop limit so a
  table a user pointed at itself terminates instead of looping. }
function ExpandModelName(const Name: string): string;
{ ' - the model came from alias "opus" (-> claude-opus-4-5); /model lists
  what this key can actually use', or '' when Name was typed literally. }
function ModelSourceNote(const Name: string): string;
{ True when Target names, or is named by, one of the ids the live list
  returned - a dateless alias against a dated snapshot, in either direction.
  The boundary must be a '-' or 'claude-opus-4' would match
  'claude-opus-40'. }
function ModelListMatches(const Target: string; const List: TModelList): Boolean;

{ The default save location under Root. }
function SessionPath(const Root: string): string;

{ Expands @path mentions in a prompt.  Each mention of a readable text file
  under the session root becomes an attachment appended after the prose, so
  the model gets the file without spending a tool round reading it.  Returns
  the expanded text; Notes lists what was attached or why something was not.

  A mentioned image goes to A's pending queue instead of into the prose, and A
  is an explicit parameter rather than a module hook: a var hook exists so a
  unit need not learn about something below it, and uAgent already depends on
  uTools and uImage, so a hook here would buy nothing and hide the dependency.
  A nil agent refuses images with the same note a non-image binary gets. }
function ExpandMentions(const Text: string; A: TAgent;
  out Notes: string): string;

{ '[image 1920x1080 image/png]' for a block that cannot be shown - the
  placeholder style uMcp and uNotebook already use for content a terminal
  cannot render.  Base64 must never reach the console: it is megabytes of
  noise that says nothing a reader can act on. }
function DescribeImageBlock(B: TJson): string;

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

{ ------------------------------------------------------------- aliases -- }

type
  TModelAlias = record
    Name: string;
    Kind: TModelAliasKind;
    Target: string;              { makModel }
    PlanHalf, ExecHalf: string;  { makProfile }
  end;

var
  { Built in the initialization section from the compiled-in defaults, then
    mutable, because SetModelAlias is how the user's settings file overrides
    a target that retired without waiting for a new build. }
  Aliases: array of TModelAlias;
  { Empty means "this role is not routed anywhere": it falls back to the main
    model, which is the only fallback that cannot spend the user's quality
    budget without being asked.  Falling back to DefaultModel instead would
    route a user who opted into nothing onto sonnet. }
  Routes: array[TModelRole] of string;

{ The hop ceiling for alias resolution.  A user can define a -> b and b -> a
  in settings.json; the loop has to end at a value that can be sent rather
  than at a stack overflow. }
const
  MaxAliasHops = 8;

function AliasIndex(const Name: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  if Name = '' then Exit;
  for I := 0 to High(Aliases) do
    if Aliases[I].Name = Name then Exit(I);
end;

function ModelAliasCount: Integer;
begin
  Result := Length(Aliases);
end;

function ModelAliasName(I: Integer): string;
begin
  Result := '';
  if (I >= 0) and (I <= High(Aliases)) then Result := Aliases[I].Name;
end;

function ModelAliasTarget(I: Integer): string;
begin
  Result := '';
  if (I < 0) or (I > High(Aliases)) then Exit;
  if Aliases[I].Kind = makProfile then
    Result := Aliases[I].PlanHalf + ' / ' + Aliases[I].ExecHalf
  else
    Result := Aliases[I].Target;
end;

function ResolveModelAlias(const Name: string; out Target: string;
  out Kind: TModelAliasKind): Boolean;
var
  I: Integer;
begin
  Target := '';
  Kind := makNone;
  I := AliasIndex(Name);
  Result := I >= 0;
  if not Result then Exit;
  Kind := Aliases[I].Kind;
  Target := ModelAliasTarget(I);
end;

{ Model ids are printable ASCII with no spaces.  The check is on the bytes
  rather than on intent because whatever passes here is copied verbatim into
  the "model" field of a request: a NUL truncates the JSON, a control byte
  makes it unparseable, and an invalid UTF-8 sequence breaks the rule that
  everything sent to the model is valid UTF-8.  Restricting to ASCII settles
  all three at once and costs nothing - no id has ever needed more. }
function ModelTargetOk(const S: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if (S = '') or (Length(S) > 128) then Exit;
  for I := 1 to Length(S) do
    if (S[I] < #33) or (S[I] > #126) then Exit;
  Result := True;
end;

function SetModelAlias(const Name, Target: string; out Err: string): Boolean;
var
  I: Integer;
begin
  Err := '';
  Result := False;
  if Name = '' then
  begin
    Err := 'an alias needs a name';
    Exit;
  end;
  if Pos('-', Name) > 0 then
  begin
    Err := 'an alias name may not contain a dash: every model id has one, ' +
      'and an alias that looked like an id would shadow it';
    Exit;
  end;
  if CompareText(Copy(Name, 1, 6), 'claude') = 0 then
  begin
    Err := 'an alias name may not begin with "claude": that is the shape of ' +
      'a real model id';
    Exit;
  end;
  if not ModelTargetOk(Target) then
  begin
    Err := 'the target must be printable ASCII with no spaces, at most 128 ' +
      'characters - it goes straight into the request as the model';
    Exit;
  end;
  I := AliasIndex(Name);
  if I < 0 then
  begin
    I := Length(Aliases);
    SetLength(Aliases, I + 1);
  end;
  { An override always lands as a plain model entry.  A profile is a shape
    this program defines, not a string a settings file can name, so
    overriding 'opusplan' with an id turns it into an ordinary alias rather
    than half-rewriting a profile. }
  Aliases[I].Name := Name;
  Aliases[I].Kind := makModel;
  Aliases[I].Target := Target;
  Aliases[I].PlanHalf := '';
  Aliases[I].ExecHalf := '';
  Result := True;
end;

procedure SetModelRoute(Role: TModelRole; const NameOrId: string);
begin
  { mrMain is not a route.  The user's own turn carries the model the user
    chose, and a "route" for it would be a second, invisible way to set the
    session model. }
  if Role = mrMain then Exit;
  Routes[Role] := Trim(NameOrId);
end;

function ModelRoute(Role: TModelRole): string;
begin
  Result := Routes[Role];
end;

function ExpandModelName(const Name: string): string;
var
  Hops, I: Integer;
begin
  Result := Name;
  for Hops := 1 to MaxAliasHops do
  begin
    I := AliasIndex(Result);
    if I < 0 then Exit;
    if Aliases[I].Kind = makProfile then
    begin
      { Read per request, not remembered.  uTools.PlanMode is derived state
        the permission round already maintains, so a profile costs one
        boolean test and no callback: /mode plan changes the model on the
        next request with nothing to keep in step. }
      if uTools.PlanMode then Result := Aliases[I].PlanHalf
      else Result := Aliases[I].ExecHalf;
    end
    else
      Result := Aliases[I].Target;
  end;
  { Out of hops: the table points at itself.  Whatever we hold is a string
    the API can reject cleanly, which is a better end than a hang. }
end;

function ModelSourceNote(const Name: string): string;
var
  Target: string;
  Kind: TModelAliasKind;
begin
  Result := '';
  if not ResolveModelAlias(Name, Target, Kind) then Exit;
  Result := ' - the model came from alias "' + Name + '" (-> ' +
    ExpandModelName(Name) + '); /model lists what this key can actually use';
end;

function ModelListMatches(const Target: string; const List: TModelList): Boolean;
var
  I: Integer;
  Id: string;
begin
  Result := False;
  if Target = '' then Exit;
  for I := 0 to High(List) do
  begin
    Id := List[I].Id;
    if Id = Target then Exit(True);
    { The '-' is the whole of the check.  Without it 'claude-opus-4' matches
      'claude-opus-40', and the warning this feeds would never fire for the
      case it exists for. }
    if Copy(Id, 1, Length(Target) + 1) = Target + '-' then Exit(True);
    if Copy(Target, 1, Length(Id) + 1) = Id + '-' then Exit(True);
  end;
end;

{ ---------------------------------------------------------------- mentions -- }

{ True for the characters that can appear in a mentioned path.  The set stops
  at whitespace and at punctuation that ends a sentence, so "see @a\b.pas,"
  attaches a\b.pas rather than a\b.pas-comma. }
function IsPathChar(C: Char): Boolean;
begin
  Result := C in ['A'..'Z', 'a'..'z', '0'..'9', '\', '/', '.', '_', '-', ':'];
end;

{ '1920x1080 image/png', or as much of it as the block records.  Shared so the
  placeholder EvictImages leaves behind and the transcript description say the
  same thing about the same image. }
function ImageFacts(B: TJson): string;
var
  Src: TJson;
  Media: string;
  W, H: Integer;
begin
  Result := '';
  if (B = nil) or (B.Kind <> jkObj) then Exit;
  Src := B.Find('source');
  Media := '';
  if Src <> nil then Media := Src.Str('media_type');
  W := Round(B.Num('width'));
  H := Round(B.Num('height'));
  if (W > 0) and (H > 0) then Result := Format('%dx%d', [W, H]);
  if Media <> '' then
  begin
    if Result <> '' then Result := Result + ' ';
    Result := Result + Media;
  end;
end;

function DescribeImageBlock(B: TJson): string;
var
  Facts: string;
begin
  Facts := ImageFacts(B);
  if Facts = '' then Result := '[image]' else Result := '[image ' + Facts + ']';
end;

function ExpandMentions(const Text: string; A: TAgent;
  out Notes: string): string;
var
  I, Start: Integer;
  Path, Full, FileText, Attach: string;
  F: TFileStream;
  N: Int64;
  Media, AttachErr: string;
  IW, IH: Integer;
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
      Media := '';
      try
        F := TFileStream.Create(Full, fmOpenRead or fmShareDenyNone);
        try
          N := F.Size;
          { The header alone decides which budget applies, so a four-megabyte
            text file is refused without being read and a four-megabyte PNG is
            not refused for being over a limit that was only ever about
            prose. }
          SetLength(FileText, N);
          if N > 64 then SetLength(FileText, 64);
          if Length(FileText) > 0 then
            F.ReadBuffer(FileText[1], Length(FileText));
          if not uImage.SniffImage(FileText, Media, IW, IH) then Media := '';

          if Media <> '' then
          begin
            if N > MaxImageFileBytes then
            begin
              Notes := Notes + Format(
                '@%s: %d bytes, too large to attach (limit %d)'#10,
                [Path, N, MaxImageFileBytes]);
              Continue;
            end;
          end
          else if N > MaxMentionBytes then
          begin
            Notes := Notes + Format('@%s: %d bytes, too large to attach'#10,
              [Path, N]);
            Continue;
          end;

          F.Position := 0;
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

      { The old refusal of a binary file is where images branch off: the bytes
        are one of the four types the API takes, so they go up verbatim as an
        image block instead of being turned away.  A user's own file is never
        transcoded - it is already properly compressed, and re-encoding it
        would cost quality for nothing. }
      if Media <> '' then
      begin
        if A = nil then
        begin
          Notes := Notes + Format('@%s: images cannot be attached here'#10,
            [Path]);
          Continue;
        end;
        if (IW > uImage.MaxImageDim) or (IH > uImage.MaxImageDim) then
        begin
          Notes := Notes + Format('@%s: %dx%d is over the %d px limit'#10,
            [Path, IW, IH, uImage.MaxImageDim]);
          Continue;
        end;
        if not A.AttachImage(Media, uImage.Base64Encode(FileText), IW, IH,
             AttachErr) then
        begin
          Notes := Notes + Format('@%s: %s'#10, [Path, AttachErr]);
          Continue;
        end;
        { The token figure is the documented patch formula, not a guess: an
          image is expensive and cannot be skimmed later in the transcript, so
          the moment of attaching is the only honest place to say what it
          costs. }
        if (IW > 0) and (IH > 0) then
          Notes := Notes + Format(
            '@%s: image attached (%dx%d %s, %d bytes, ~%d tokens)'#10,
            [Path, IW, IH, Media, N, uImage.VisualTokens(IW, IH)])
        else
          Notes := Notes + Format(
            '@%s: image attached (%s, %d bytes, size unknown)'#10,
            [Path, Media, N]);
        Continue;
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
    here and not an accident of initialisation.  The same applies to the
    role: every agent answers a user until something says otherwise, and a
    subagent's role stays mrMain because it was handed a resolved id. }
  FWebSearch := False;
  FRole := mrMain;
end;

function TAgent.IsOauth: Boolean;
begin
  Result := Copy(FApiKey, 1, Length(OauthKeyPrefix)) = OauthKeyPrefix;
end;

function TAgent.WantsCancel: Boolean;
begin
  Result := ForceCancel or (Assigned(ShouldCancel) and ShouldCancel());
end;

procedure TAgent.BumpModelUsage(const AModel: string;
  InTok, OutTok, CW, CR: Int64);
var
  I, N: Integer;
begin
  if AModel = '' then Exit;
  for I := 0 to High(FModelUsage) do
    if FModelUsage[I].Model = AModel then
    begin
      Inc(FModelUsage[I].TokensIn, InTok);
      Inc(FModelUsage[I].TokensOut, OutTok);
      Inc(FModelUsage[I].CacheWrite, CW);
      Inc(FModelUsage[I].CacheRead, CR);
      Exit;
    end;
  N := Length(FModelUsage);
  SetLength(FModelUsage, N + 1);
  FModelUsage[N].Model := AModel;
  FModelUsage[N].TokensIn := InTok;
  FModelUsage[N].TokensOut := OutTok;
  FModelUsage[N].CacheWrite := CW;
  FModelUsage[N].CacheRead := CR;
end;

function TAgent.UsageModelKey: string;
begin
  Result := FLastRequestModel;
  if Result = '' then Result := EffectiveModel(FRole);
end;

function TAgent.UsageByModel: TModelUsageList;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(FModelUsage));
  for I := 0 to High(FModelUsage) do Result[I] := FModelUsage[I];
end;

function TAgent.LastRequestModel: string;
begin
  Result := FLastRequestModel;
end;

function TAgent.RoleSource(Role: TModelRole): string;
begin
  Result := FModel;
  if (Role <> mrMain) and (Routes[Role] <> '') then Result := Routes[Role];
end;

function TAgent.EffectiveModel(Role: TModelRole): string;
begin
  Result := ExpandModelName(RoleSource(Role));
  { Cannot happen with a model set at Create, but a caller that cleared the
    property must still produce something sendable rather than an empty
    "model" the API rejects with a message about the wrong thing. }
  if Result = '' then Result := DefaultModel;
end;

procedure TAgent.AbsorbUsage(Sub: TAgent);
var
  I: Integer;
begin
  if Sub = nil then Exit;
  Inc(FTotalIn, Sub.FTotalIn);
  Inc(FTotalOut, Sub.FTotalOut);
  Inc(FCacheWrite, Sub.FCacheWrite);
  Inc(FCacheRead, Sub.FCacheRead);
  { The rows have to come across too, or a routed subagent's tokens appear in
    the scalar totals and in no row at all, and the per-model block silently
    under-reports the thing it exists to report. }
  for I := 0 to High(Sub.FModelUsage) do
    BumpModelUsage(Sub.FModelUsage[I].Model,
      Sub.FModelUsage[I].TokensIn, Sub.FModelUsage[I].TokensOut,
      Sub.FModelUsage[I].CacheWrite, Sub.FModelUsage[I].CacheRead);
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

function TAgent.TurnWasCancelled: Boolean;
begin
  Result := FTurnCancelled;
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

  if IsOauth then
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
  { The question is being thrown away unanswered; anything the user attached
    to it was never sent either, so it goes back on the queue rather than
    vanishing with the message. }
  RequeueImagesFrom(Last);
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
  Cancelled, Sent: Boolean;
  SavedRole: TModelRole;
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
  { Only-text on purpose: this is pasclaude asking a question of its own, and
    draining the user's pending attachment into it would spend the image on a
    summary the user never sees. }
  AppendUserTextOnly(
    'Summarize this conversation so far for your own future reference. ' +
    'Write plain prose, no tool calls. Preserve: what the user asked for, ' +
    'what was done and how, exact file paths and names involved, decisions ' +
    'made and their reasons, and anything still unfinished. Omit pleasantries ' +
    'and dead ends.');

  { Summarising text the model already produced is mechanical work, so it is
    one of the two things routed off the main model.  The role is set around
    the request alone and restored in a finally: a compaction that failed or
    was cancelled must not strand the rest of the session on the compaction
    model, and every exit below this point is an early one. }
  SavedRole := FRole;
  FRole := mrCompact;
  try
    Sent := SendWithRetry(Blocks, StopReason, Err, Cancelled);
  finally
    FRole := SavedRole;
  end;
  if not Sent then
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
  AppendUserTextOnly('Summary of the conversation so far, carried over ' +
    'after compaction:'#10#10 + Summary);
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

{ width and height are ours, not the API's.  They live in FMessages so a
  resumed session can say '[image 1920x1080 image/png]' without decoding a
  megabyte of base64, and LoadSession reads them back - but the Messages API
  validates content blocks strictly and rejects a block carrying a key it does
  not know, so every one of them has to be gone from the copy that goes on the
  wire.  Stripped here, beside the cache_control fixup, for the same reason:
  the transcript stays free of transport concerns and the transport stays free
  of ours.  Local-only keys added later belong in this one list. }
procedure StripLocalImageFields(Msg: TJson);
var
  Content, B: TJson;
  I, K: Integer;
begin
  if Msg = nil then Exit;
  Content := Msg.Find('content');
  if (Content = nil) or (Content.Kind <> jkArr) then Exit;
  for I := 0 to Content.Count - 1 do
  begin
    B := Content.Item(I);
    if (B = nil) or (B.Kind <> jkObj) then Continue;
    if B.Str('type') <> 'image' then Continue;
    K := B.IndexOf('width');
    if K >= 0 then B.Drop(K);
    K := B.IndexOf('height');
    if K >= 0 then B.Drop(K);
  end;
end;

function TAgent.BuildBody: string;
var
  Root, Msgs, M, C: TJson;
  I: Integer;
  SysBlock, SysArr, Content, LastBlock, CC, Tools: TJson;
  Note: string;
begin
  Root := TJson.NewObj;
  try
    { The single production point for a model string.  Recorded as it is
      produced, together with the name it came from, because by the time a
      404 comes back the only thing that can explain it is what was sent. }
    FLastRequestModel := EffectiveModel(FRole);
    FLastRequestSource := RoleSource(FRole);
    Root.AddStr('model', FLastRequestModel);
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
      if IsOauth then
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
      { Whatever is true of this session rather than of the program: plan
        mode, deny rules, and later the extra roots.  Read from uTools here
        rather than set by the host, because a host that forgot to wire it
        would produce exactly the failure plan mode exists to prevent - a
        model told nothing, discovering the boundary by walking into it after
        doing half the work.  It goes
        AFTER the marked block and carries no marker of its own, so a session
        that turns one of these on does not invalidate the cached prefix -
        and with everything at its default uTools.SessionNote is '', no second
        block is emitted, and the body is byte-identical to before. }
      Note := uTools.SessionNote;
      if Note <> '' then
      begin
        SysBlock := TJson.NewObj;
        SysBlock.AddStr('type', 'text');
        SysBlock.AddStr('text', Note);
        SysArr.Push(SysBlock);
      end;
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
      if C <> nil then
      begin
        StripLocalImageFields(C);
        Msgs.Push(C);
      end;
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
  if IsOauth then
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
    BumpModelUsage(UsageModelKey, St.InTok, St.OutTok,
      St.CacheWrite, St.CacheRead);
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
    { A model the account cannot use is a 404 on the first turn, which is the
      worst possible moment to be told nothing.  When the id came from an
      alias, say so and name it: the alternative is an opaque
      not_found_error about a string the user never typed.  Nothing is
      printed here - uAgent has no console - the text is returned. }
    if (Res.Status = 404) or (Copy(Err, 1, 8) = 'HTTP 404') then
      Err := Err + ModelSourceNote(FLastRequestSource);
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
  BumpModelUsage(UsageModelKey, St.InTok, St.OutTok,
    St.CacheWrite, St.CacheRead);
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
        if Assigned(OnToolInput) then
          OnToolInput(Blocks[I].Id, Blocks[I].Name, Input.ToJson);
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
        if Assigned(OnToolDone) then
          OnToolDone(Blocks[I].Id, Blocks[I].Name, Output, IsErr);

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
  BumpModelUsage(UsageModelKey, St.InTok, St.OutTok,
    St.CacheWrite, St.CacheRead);
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
  how secrets end up committed.  Still true now that a credential can also
  come from uAuth's own store - MORE true, since the whole point of that
  store is that the secret lives out of tree under DPAPI, and a copy of it in
  <root>\.pasclaude\session.json would be one SafePath does not protect and
  git might.  There is a test pinning this; the field this comment describes
  is the one that must never be added. }
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
    { The saved model wins whenever it is not blank, including over an
      explicit ANTHROPIC_MODEL.  The comment here used to claim the opposite;
      the code has always done this, and telling the truth is the cheaper fix -
      distinguishing "the caller picked one" from "the caller took the
      default" needs a flag threaded through TAgent.Create, and changing the
      behaviour would change interactive /resume with it. }
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

{ True for an authentication failure and nothing else.  A 403 is a
  permission error and a 400 is a bad request; replaying either against a new
  credential would just fail again, and widening this test is the specific
  mistake that turns one clear refusal into a retry storm. }
function IsUnauthorized(const Err: string): Boolean;
begin
  { The status alone, deliberately.  Matching the API's error TYPE as well
    would look more generous and be wrong: the body is attacker-adjacent
    text that arrives with any status, so an error_type test would let a 403
    or a 400 carrying the word authentication_error trigger a replay. }
  Result := Pos('HTTP 401', Err) > 0;
end;

function TAgent.TryAuthRefresh(const Err: string): Boolean;
var
  NewKey: string;
begin
  Result := False;
  if FAuthRefreshed then Exit;
  if not IsUnauthorized(Err) then Exit;
  if not Assigned(OnAuthRefresh) then Exit;
  { Marked spent BEFORE the callback runs, so a callback that throws or that
    keeps handing back fresh-but-dead keys still cannot produce a third
    request. }
  FAuthRefreshed := True;
  NewKey := OnAuthRefresh();
  { A key identical to the one just refused would fail identically; an empty
    one means the host found nothing better. }
  if (NewKey = '') or (NewKey = FApiKey) then Exit;
  FApiKey := NewKey;
  if Assigned(OnNotice) then
    OnNotice('the credential was refused; retrying with a newly resolved one');
  Result := True;
end;

{ Sends one request, retrying transient failures with a widening delay. }
function TAgent.SendWithRetry(out Blocks: TPartialBlocks;
  out StopReason, Err: string; out Cancelled: Boolean): Boolean;
var
  Attempt, Wait: Integer;
begin
  FAuthRefreshed := False;
  for Attempt := 0 to MaxRetries do
  begin
    Result := SendOnce(Blocks, StopReason, Err, Cancelled);
    if Result or Cancelled then Exit;
    { Before the Transient test, because 401 is not transient and must not
      become so.  This is an immediate re-send with a different credential,
      not a backoff: there is nothing to wait for. }
    if TryAuthRefresh(Err) then
    begin
      Result := SendOnce(Blocks, StopReason, Err, Cancelled);
      if Result or Cancelled then Exit;
    end;
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

procedure TAgent.AppendUserTextOnly(const S: string);
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

function TAgent.AttachImage(const Media, B64: string; W, H: Integer;
  out Err: string): Boolean;
var
  N: Integer;
begin
  Err := '';
  Result := False;
  if (Media <> 'image/png') and (Media <> 'image/jpeg') and
     (Media <> 'image/gif') and (Media <> 'image/webp') then
  begin
    Err := Media + ' is not an image type the API accepts';
    Exit;
  end;
  if B64 = '' then
  begin
    Err := 'the image is empty';
    Exit;
  end;
  N := Length(FPendingImages);
  if N >= MaxImagesPerMessage then
  begin
    Err := Format('at most %d images per message; send these first',
      [MaxImagesPerMessage]);
    Exit;
  end;
  SetLength(FPendingImages, N + 1);
  FPendingImages[N].Media := Media;
  FPendingImages[N].Data := B64;
  FPendingImages[N].W := W;
  FPendingImages[N].H := H;
  Result := True;
end;

function TAgent.PendingImages: Integer;
begin
  Result := Length(FPendingImages);
end;

procedure TAgent.ClearPendingImages;
begin
  SetLength(FPendingImages, 0);
end;

{ The one builder of user messages, for prose and images alike.  A second one
  would eventually drift from this ordering, and the ordering is not
  arbitrary: the API documents that an image works best before the text that
  asks about it. }
procedure TAgent.AppendUserText(const S: string);
var
  Msg, Arr, B, Src: TJson;
  I: Integer;
begin
  { An image-only paste is a real message.  Testing the text alone here would
    make it vanish silently, which is the worst outcome available: the user
    paid for the image and it never left the machine. }
  if (Trim(S) = '') and (Length(FPendingImages) = 0) then Exit;

  Arr := TJson.NewArr;
  for I := 0 to High(FPendingImages) do
  begin
    Src := TJson.NewObj;
    Src.AddStr('type', 'base64');
    Src.AddStr('media_type', FPendingImages[I].Media);
    Src.AddStr('data', FPendingImages[I].Data);
    B := TJson.NewObj;
    B.AddStr('type', 'image');
    B.Add('source', Src);
    { Dimensions the API ignores and this program reads back: they are what
      lets a resumed transcript say '[image 1920x1080 image/png]' rather than
      '[image]', without decoding a megabyte of base64 to find out. }
    if (FPendingImages[I].W > 0) and (FPendingImages[I].H > 0) then
    begin
      B.AddNum('width', FPendingImages[I].W);
      B.AddNum('height', FPendingImages[I].H);
    end;
    Arr.Push(B);
  end;
  SetLength(FPendingImages, 0);

  if Trim(S) <> '' then
  begin
    B := TJson.NewObj;
    B.AddStr('type', 'text');
    B.AddStr('text', S);
    Arr.Push(B);
  end;

  Msg := TJson.NewObj;
  Msg.AddStr('role', 'user');
  Msg.Add('content', Arr);
  FMessages.Push(Msg);
end;

function TAgent.EvictImages(KeepNewest: Integer): Integer;
var
  I, J, Total, Seen: Integer;
  Content, B, Repl: TJson;
  Desc: string;

  function CountImages: Integer;
  var
    A, C: Integer;
    Ct: TJson;
  begin
    Result := 0;
    for A := 0 to FMessages.Count - 1 do
    begin
      Ct := FMessages.Item(A).Find('content');
      if (Ct = nil) or (Ct.Kind <> jkArr) then Continue;
      for C := 0 to Ct.Count - 1 do
        if Ct.Item(C).Str('type') = 'image' then Inc(Result);
    end;
  end;

begin
  Result := 0;
  if KeepNewest < 0 then KeepNewest := 0;
  Total := CountImages;
  if Total <= KeepNewest then Exit;

  { Oldest first: the image the user just pasted is the one still being
    discussed, and the stale ones at the front are what nobody will look at
    again. }
  Seen := 0;
  for I := 0 to FMessages.Count - 1 do
  begin
    Content := FMessages.Item(I).Find('content');
    if (Content = nil) or (Content.Kind <> jkArr) then Continue;
    for J := 0 to Content.Count - 1 do
    begin
      B := Content.Item(J);
      if (B = nil) or (B.Str('type') <> 'image') then Continue;
      Inc(Seen);
      if Seen > Total - KeepNewest then Exit;
      Desc := ImageFacts(B);
      if Desc = '' then Desc := 'unknown';
      Repl := TJson.NewObj;
      Repl.AddStr('type', 'text');
      Repl.AddStr('text', '[image removed to save context: ' + Desc + ']');
      Content.SetAt(J, Repl);
      Inc(Result);
    end;
  end;
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
  FTurnCancelled := False;
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
      FTurnCancelled := True;
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
      FTurnCancelled := True;
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

{ The queue is bounded, so an image that cannot fit is dropped rather than
  allowed to push the count past what AttachImage would ever have permitted -
  a silently over-long queue would fail the next request instead of this one.
  Order within the message is preserved, which is the order the user pasted
  them in. }
procedure TAgent.RequeueImagesFrom(M: TJson);
var
  Content, B, Src: TJson;
  I, N, Back: Integer;
begin
  if M = nil then Exit;
  if M.Str('role') <> 'user' then Exit;
  Content := M.Find('content');
  if (Content = nil) or (Content.Kind <> jkArr) then Exit;
  Back := 0;
  for I := 0 to Content.Count - 1 do
  begin
    B := Content.Item(I);
    if (B = nil) or (B.Kind <> jkObj) then Continue;
    if B.Str('type') <> 'image' then Continue;
    Src := B.Find('source');
    if (Src = nil) or (Src.Str('data') = '') then Continue;
    N := Length(FPendingImages);
    if N >= MaxImagesPerMessage then Break;
    SetLength(FPendingImages, N + 1);
    FPendingImages[N].Media := Src.Str('media_type');
    FPendingImages[N].Data := Src.Str('data');
    FPendingImages[N].W := Round(B.Num('width'));
    FPendingImages[N].H := Round(B.Num('height'));
    Inc(Back);
  end;
  { Silence here would be the real damage: the user was told the image goes
    with their next message, and without this they would send that message
    without it and never know. }
  if (Back > 0) and Assigned(OnNotice) then
    OnNotice(Format('%d attached image(s) were not sent; they go with your ' +
      'next message', [Back]));
end;

procedure TAgent.UnwindUnsentTail;
begin
  while (FMessages.Count > 1) and
        (FMessages.Item(FMessages.Count - 1).Str('role') = 'user') do
  begin
    RequeueImagesFrom(FMessages.Item(FMessages.Count - 1));
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

{ The same block the main system prompt carries, under the same condition:
  a subagent reads in every root the parent can, and a path it cannot name is
  a path it will waste a round guessing at.  '' when there is one root, so an
  ordinary subagent's prompt is unchanged. }
function SubRootsNote: string;
var
  I: Integer;
begin
  Result := '';
  if uTools.RootCount <= 1 then Exit;
  Result := 'Additional working directories you may also read:' + #10;
  for I := 1 to uTools.RootCount - 1 do
    Result := Result + '  ' + uTools.RootAt(I) + #10;
  Result := Result + 'Paths are relative to the session root; a file in an ' +
    'additional directory must be given as its full absolute path.' + #10;
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
    SubRootsNote +
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

  { Routed rather than inherited.  A read-only investigator with three tools
    and nobody watching it spend is the clearest case in the program for a
    cheaper model - RunSubagent already declines to give it a thinking budget
    for the same reason.  The child is handed a concrete id and its own role
    stays mrMain, so its resolution is a plain passthrough and it cannot
    route again. }
  Sub := TAgent.Create(Parent.FApiKey, Parent.EffectiveModel(mrSubagent),
    SysText);
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

procedure AddBuiltinAlias(const Name, Target: string);
var
  I: Integer;
begin
  I := Length(Aliases);
  SetLength(Aliases, I + 1);
  Aliases[I].Name := Name;
  Aliases[I].Kind := makModel;
  Aliases[I].Target := Target;
end;

procedure AddBuiltinProfile(const Name, PlanHalf, ExecHalf: string);
var
  I: Integer;
begin
  I := Length(Aliases);
  SetLength(Aliases, I + 1);
  Aliases[I].Name := Name;
  Aliases[I].Kind := makProfile;
  Aliases[I].PlanHalf := PlanHalf;
  Aliases[I].ExecHalf := ExecHalf;
end;

initialization
  { Dateless on purpose, every one of them.  A dated snapshot id is a promise
    about a date this program does not control, and one of those has already
    expired under this codebase - a live 404 on a hardcoded default, which is
    why DefaultModel is 'claude-sonnet-4-5' and not a snapshot.  The server
    resolves a family alias to whatever is current; a table of snapshots
    would have to be re-shipped to stay true. }
  AddBuiltinAlias('opus',   'claude-opus-4-5');
  AddBuiltinAlias('sonnet', 'claude-sonnet-4-5');
  AddBuiltinAlias('haiku',  'claude-haiku-4-5');
  { Not an id: a profile.  Plan mode refuses every changing tool, so under
    opusplan the expensive model only ever reads and the cheap one does the
    work - which is the whole argument for the alias existing. }
  AddBuiltinProfile('opusplan', 'opus', 'sonnet');
  { The shipped routes.  On the shipped default model these are a no-op -
    'sonnet' expands to exactly DefaultModel - so out of the box every
    request carries the same string it carried before routing existed.  The
    feature only bites once the user has deliberately chosen a stronger main
    model, which is the moment they asked for it. }
  Routes[mrSubagent] := 'sonnet';
  Routes[mrCompact]  := 'sonnet';

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
