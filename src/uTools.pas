{ uTools - the tools the model is allowed to call, and the permission gate.

  Every tool that changes the machine (write, edit, bash) asks the user first,
  unless the session has been put in accept-all mode.  Reads are free.  Paths
  are resolved against the session root and refused when they escape it, so a
  confused model cannot walk into C:\Windows by accident. }
unit uTools;

{$mode objfpc}{$H+}

interface

uses SysUtils, uJson, uDiff;

type
  { Answer to a permission prompt. }
  TPermission = (pmAsk, pmAllowOnce, pmAllowAlways, pmDeny);

  { Supplied by the host so this unit does not depend on the console. }
  TAskProc = function(const Title, Detail: string): TPermission;

  { Runs a nested agent to completion and returns its final reply.  Declared
    here and supplied by uAgent because the unit ladder runs the other way:
    the tools may not know what a conversation is, so the conversation loop
    hands this unit a way in - the same seam uHttp uses for the network. }
  TSubagentProc = function(const Prompt, SystemExtra: string;
    out Reply, Err: string): Boolean;

  { ---- the dynamic tool registry ----
    A tool source contributes declarations and executes the calls that land on
    them.  Declare returns a freshly built array which the caller owns
    entirely, elements included; Run has exactly the ladder's own contract -
    the result text, IsError set on every failure path, and no exception.
    That last clause is enforced here rather than trusted, because uAgent's
    tool loop does not catch: an exception escaping a handler would skip the
    tool_result the API requires and leave a transcript that cannot be sent. }
  TToolDeclareProc = function: TJson;
  TToolRunProc = function(const Name: string; Input: TJson; Ask: TAskProc;
    out IsError: Boolean): string;

  { What a configured MCP server is doing.  Every one of these is rendered by
    /mcp, including the ones that contribute nothing: a server silently
    dropped reads as a broken program, and the whole point of asking the user
    to approve a program is that they can see what happened to it. }
  TMcpStatus = (mcPending, mcDenied, mcUnsupported, mcCached, mcConnected,
                mcDead, mcFailed);

  { The host's one-line progress channel, so this unit can say "connecting
    foo" during a startup that takes seconds without knowing what a console
    is.  Nil is silence, not an error. }
  TMcpNoticeProc = procedure(const Text: string);

var
  { Session root; every path argument is resolved relative to it. }
  RootDir: string = '';
  { Set once the user picks "always" for a tool class. }
  AllowAllEdits: Boolean = False;
  AllowAllBash: Boolean = False;
  AllowAllFetch: Boolean = False;
  { The fourth approval class, and the only one that is never persisted: it is
    set by /yolo alone.  A per-server "always" is recorded against the exact
    command line instead, which is the same reasoning that makes an "always"
    for bash approve a program rather than a command line. }
  AllowAllMcp: Boolean = False;
  { Filled in by uAgent's initialization.  Nil means this build cannot run a
    subagent at all: the task tool is then not advertised and, if the model
    names it anyway, it reports a plain error.  Deny-by-default applied to a
    capability rather than to a file. }
  SubagentRunner: TSubagentProc = nil;

const
  { pasclaude's own state directory, kept out of listings and searches.  The
    name lives here rather than in uAgent because this unit is the one that has
    to skip it, and two copies of the literal would drift. }
  StateDirName = '.pasclaude';

  { The server-side web search tool's type string.  Anthropic versions these
    by date; older models take the basic 'web_search_20250305' instead.
    Rather than sniffing the model id - the mistake README already records -
    a rejection by the server disables the feature for the session and the
    turn is retried, so a wrong string here costs one request, not a run. }
  WebSearchToolType = 'web_search_20260209';

  { One level, and no further.  A subagent that can spawn subagents turns a
    confused model into an unbounded bill, and the second level buys nothing
    a single well-briefed helper cannot do. }
  MaxSubagentDepth  = 1;
  { A subagent's tool-round ceiling, well under the parent's: it is doing one
    self-contained job, and nobody is watching it spend.  Read by uAgent,
    which is why it lives here beside the depth cap rather than there. }
  SubagentMaxRounds = 12;

  { How many tool sources may be registered.  Small on purpose: the list is
    scanned per tool call and per schema build, and eight is already more
    extension points than this program has features. }
  MaxToolSources = 8;

  { The tools compiled into this program, counted so no test file has to
    carry the number.  Every one of them is declared when a subagent runner
    is installed; without one, task is absent and the count is one lower. }
  BuiltinToolCount = 12;

  { The one namespace MCP tools live in.  No built-in name contains a double
    underscore and none ever may - that is what makes it impossible for a
    server to shadow read_file, without a check against a list of built-ins
    that would need updating every time a thirteenth tool lands. }
  McpNamePrefix = 'mcp__';

  { The API's own ceiling on a tool name: ^[a-zA-Z0-9_-]{1,64}$.  Load-bearing
    for namespacing, because mcp__ + server + __ + tool overruns it easily. }
  McpMaxToolNameLen = 64;

  { One tool's whole declaration.  Rejected, never truncated: a cut schema is
    a lie the model will act on, and it would act on it every turn. }
  McpMaxSchemaBytes = 8192;
  { How deeply a schema may nest before we stop believing in it. }
  McpMaxSchemaDepth = 16;
  { Per server, so one enthusiastic server cannot crowd out the rest. }
  McpMaxTools = 64;
  { The budget for MCP declarations across ALL servers, not per server: this
    text lands in the cached request prefix ahead of the system prompt, so a
    per-server cap would be unbounded in aggregate exactly where it matters. }
  McpMaxDeclBytes = 32768;
  { A description is the one field with no structural limit of its own. }
  McpMaxDescBytes = 4096;
  { .mcp.json is a small hand-written file.  A megabyte of it is not a
    configuration, it is something else wearing the name. }
  McpMaxConfigBytes = 1024 * 1024;

{ The tool list, as the API expects it under "tools". }
function ToolsSchema: TJson;

{ How many of Arr's declarations are built-in - that is, are not contributed
  by a registered tool source.  The suites assert against BuiltinToolCount
  through this, so configuring an MCP server can never move a number that
  lives in a test file. }
function CountBuiltinTools(Arr: TJson): Integer;

{ Registers a source under Prefix, which must match ^[a-z][a-z0-9_]*__$ .
  False with Err set when the shape is wrong, when the prefix duplicates or
  overlaps an existing one - so at most one source can ever match a name and
  dispatch does not depend on registration order - or when the table is full.
  Called from a higher unit's initialization or from host startup, the way
  SubagentRunner is filled. }
function RegisterToolSource(const Prefix: string; Declare: TToolDeclareProc;
  Run: TToolRunProc; out Err: string): Boolean;
{ Test seam: forget every source.  A suite that calls this and wants MCP tools
  afterwards has to call RegisterMcpToolSource again. }
procedure ClearToolSources;
function ToolSourceCount: Integer;
function ToolSourcePrefix(I: Integer): string;
{ Puts the MCP source back after ClearToolSources; also what initialization
  calls, so there is one definition of what MCP registers as. }
procedure RegisterMcpToolSource;

{ The web search declaration.  Declaration only: the API executes this tool
  on its own servers, so there is no RunTool branch, no DescribeTool arm and
  no permission gate for it - the consent is the declaration itself, which
  the host makes conditional.  Caller takes ownership. }
function WebSearchToolDef: TJson;

{ Runs Name with Input.  Returns the text result; IsError says whether the
  model should treat it as a failure.  Ask may be nil, which denies anything
  needing permission. }
function RunTool(const Name: string; Input: TJson; Ask: TAskProc;
  out IsError: Boolean): string;

{ The class gate itself: asks the user about Name unless a standing approval
  for its class already covers it.  Exposed because the classes are the part
  of this program most worth pinning from outside - the failure it guards
  against is a new class silently inheriting the edits catch-all, and that is
  invisible to every test that goes through a tool. }
function Permit(const Name, Detail: string; Ask: TAskProc): Boolean;

{ A one-line description used in the transcript and in permission prompts. }
function DescribeTool(const Name: string; Input: TJson): string;

{ The diff a write or edit would produce, ready to show in a permission
  prompt.  Empty for tools that change nothing on disk. }
function ChangePreview(const Name: string; Input: TJson): string;

{ Converts console output from the OEM codepage to UTF-8.  Exposed so the
  encoding behaviour can be tested directly. }
function OemToUtf8(const S: string): string;

{ True when S is well-formed UTF-8.  Exposed because every string that leaves
  this unit ends up in a JSON request body, where invalid UTF-8 is fatal. }
function IsValidUtf8(const S: string): Boolean;

{ Resolves P under the session root with the same rules every tool applies:
  no escaping the root, no reaching into pasclaude's own state.  Exposed so
  @file mentions face the same guard as tool calls. }
function ResolveInRoot(const P: string; out Full: string; out Err: string): Boolean;

{ Loads the root .gitignore, if any.  Called once at startup and after /clear
  of the cache would make no sense - the file rarely changes mid-session. }
procedure LoadIgnoreRules;

{ True when a path relative to the root matches an ignore rule.  Exposed for
  the tests; the walkers consult it internally. }
function IsIgnored(const RelPath: string; IsDir: Boolean): Boolean;

{ Runs a command in the session root and returns its combined output, for the
  host's own use (git context at startup).  Same machinery as the bash tool,
  without the permission gate - the host is not the model. }
function RunShellQuiet(const Cmd: string; out ExitCode: Integer): string;

{ The leading program name of a shell command - the part an "always" answer
  reasonably covers.  Exposed for the tests. }
function BashPrefix(const Cmd: string): string;
{ True when Cmd's prefix was approved with "always" earlier this session. }
function BashPrefixAllowed(const Cmd: string): Boolean;
{ Records Cmd's prefix as approved.  Exposed for the tests. }
procedure AllowBashPrefix(const Cmd: string);
{ Test seam: forget every approved prefix. }
procedure ClearBashPrefixes;

{ Files the write and edit tools actually touched this session, relative to
  the root, oldest first, without duplicates.  Approvals happen one edit at
  a time; this is the aggregated answer to "what changed?". }
function ChangedFiles: TStringArray;
{ Records a touched file.  RunTool calls it on success; exposed for tests. }
procedure NoteChangedFile(const RelPath: string);
{ Test seam and /clear: forget the list. }
procedure ClearChangedFiles;

{ The task list the model maintains through the todo_write tool, rendered
  by the host after each update.  One string per item, prefixed with its
  state: '[ ] ', '[~] ' (in progress), '[x] '. }
function CurrentTodos: TStringArray;
{ Test seam and /clear. }
procedure ClearTodos;

{ ---- subagents ----
  A subagent runs inside a tool call, where the user is being asked nothing
  and is not even looking at a prompt.  So it is read-only: read_file,
  list_dir, search, and nothing else.  Threading the Ask callback down would
  put a permission dialog on screen for a conversation the user cannot see -
  and worse, it would be pointless, because Permit short-circuits on
  AllowAllEdits and PermitBash on a persisted "always", so under /yolo a
  writable subagent would write with no prompt at all.  Deny-by-default would
  be honoured in letter and defeated in spirit. }

{ Claims the one available subagent slot.  False at the cap, which is the
  guard against a fork bomb; the caller must Leave in a finally. }
function EnterSubagent: Boolean;
procedure LeaveSubagent;
{ Test seam: 0 when no subagent is running. }
function SubagentDepth: Integer;

{ The read-only allowlist.  RunTool consults this, not just ToolsSchema:
  the schema is advice to the model, and this is the boundary. }
function IsSubagentTool(const Name: string): Boolean;

{ The agent types defined under the state directory, one .md file each,
  named for the choices offered in the schema and in the unknown-type error. }
function SubagentTypes: TStringArray;

{ The extra system prompt for a named agent type; '' means the general
  purpose subagent, which is not an error.  False with Err set when the name
  is malformed or unknown. }
function LoadAgentDefinition(const AgentType: string;
  out Text, Err: string): Boolean;

{ ---- background jobs, the detached half of bash ----
  A background command's output goes to a spool file under the state
  directory rather than a pipe.  An unread anonymous pipe fills and then
  blocks the child forever, and by definition nothing is draining a
  background command - that deadlock is not a risk here, it is the default
  outcome.  A file cannot fill, so the child runs to completion whether or
  not anybody ever polls it.

  Each job also owns a Win32 job object with kill-on-close, so the whole
  process tree dies with pasclaude even when pasclaude dies badly. }

{ Starts Cmd detached and returns its job id.  False, with Err set, when the
  table is full, the command is blank, or Windows refused to start it. }
function StartBackgroundJob(const Cmd: string; out Id: string; out Err: string): Boolean;

{ The output produced since the last poll, with a status line.  Found is
  False when no such job exists, which the caller reports as an error: a
  model that reads silence as "it produced nothing" waits forever. }
function PollBackgroundJob(const Id: string; out Found: Boolean): string;

{ Stops the job and everything it started.  False when the id is unknown.
  The handles stay open so the final output can still be polled. }
function KillBackgroundJob(const Id: string): Boolean;

{ One line per job, for the model's bash_output with no id and for /jobs.
  A process started on the user's behalf has to be visible to the user
  without having to ask the model about it. }
function BackgroundJobList: string;

{ Test seam: how many jobs are held. }
function BackgroundJobCount: Integer;

{ Test seam: waits for a job to finish, bounded, so a suite can assert on a
  finished job without sprinkling Sleep calls and hoping. }
function WaitBackgroundJob(const Id: string; TimeoutMs: Integer): Boolean;

{ Stops every job, closes its handles and deletes its spool.  Wired to
  /clear, to exit, and to this unit's finalization. }
procedure ClearJobs;

{ ---- file snapshots, the disk half of /rewind ----
  Before a write or edit changes a file, its prior state is captured against
  the current turn number.  Rewinding to turn N restores every touched file
  to the oldest snapshot at or after N - the state it had when N began. }

{ Marks the turn now starting; snapshots taken from here belong to it. }
procedure BeginTurn(TurnNo: Integer);
{ Restores every file touched at or after TurnNo and forgets those
  snapshots.  Notes lists what was restored or why something could not be.
  Returns the number of files put back. }
function RestoreFilesSince(TurnNo: Integer; out Notes: string): Integer;
{ Test seam and /clear. }
procedure ClearSnapshots;
{ Test seam: how many snapshots are held. }
function SnapshotCount: Integer;

{ Loads standing approvals from Path: the tool-class "always" answers and
  the approved bash programs, so an "a" gives once survives restarts.  A
  missing or unreadable file simply approves nothing. }
procedure LoadPermissions(const Path: string);
{ Writes the standing approvals to Path.  Failures are swallowed: the
  session works identically, approvals just will not persist. }
procedure SavePermissions(const Path: string);

{ ---- the trust store ----
  One object in permissions.json, key = what was approved, value = a
  fingerprint of exactly what it was approved as.  A boolean would say "this
  project's config is trusted" forever; a fingerprint says "these bytes are",
  and the moment they change the question is asked again.  Same idea as an
  "always" for bash recording the program rather than the command line.
  Keys in use: 'mcp:<server>' for permission to run the program at all, and
  'mcp-call:<server>' for a standing yes to its tool calls. }
function TrustedFingerprint(const Key: string): string;   { '' when absent }
procedure RecordTrust(const Key, Fingerprint: string);
procedure ClearTrust;                                     { test seam }

{ ---- MCP servers ----
  A project's .mcp.json names programs to run.  That is the one genuinely new
  risk in this feature: cloning a repository and starting pasclaude in it
  would otherwise execute code its author chose.  So the file is read, the
  expanded command lines are shown, and nothing is spawned until the user has
  said yes to each one - once per exact command line, not once per name,
  because the name is a label the same file controls. }

{ <root>\.mcp.json.  The one config this program reads through the ordinary
  path guard rather than around it: it genuinely is a project file, it is
  meant to be committed and shared, and the tools can see and edit it.  That
  is accepted rather than worked around - the gate is the spawn prompt, not
  the file being hidden, and config is read once at startup so a mid-session
  rewrite changes nothing until the next launch, where the changed command
  line has no matching fingerprint and is asked about by name. }
function McpConfigPath: string;

{ Replaces the server table with what Path declares.  False when there is
  nothing usable; Err is set only for a real problem, so a missing file is a
  quiet False.  ${VAR} and ${VAR:-default} are expanded before the command
  line is hashed, so what the fingerprint covers is what will actually run. }
function LoadMcpConfig(const Path: string; out Err: string): Boolean;

{ The spawn gate.  Asks once per server whose fingerprint is not already
  recorded; a nil Ask denies everything and spawns nothing, which is what
  makes print mode structurally unable to be the thing that first runs a
  repository's code. }
procedure McpApproveAll(Ask: TAskProc; Notice: TMcpNoticeProc);

{ Connects the approved servers that have no cached tool list and returns how
  many came up.  Sequential and bounded per server; a cached server is not
  spawned at all and connects on its first actual call. }
function McpConnectApproved(Notice: TMcpNoticeProc): Integer;

{ The registered source's two halves. }
function McpDeclare: TJson;
function McpRun(const Name: string; Input: TJson; Ask: TAskProc;
  out IsError: Boolean): string;

{ One line per configured server for /mcp, tab-separated:
  name, status, tools, skipped, command, note.  Same shape as
  BackgroundJobList, and for the same reason: a program started on the user's
  behalf has to be visible without asking the model about it. }
function McpServerList: TStringArray;
function McpServerCount: Integer;                  { test seam }
function McpServerStatus(const Name: string): TMcpStatus;
function McpServerToolCount(const Name: string): Integer;
function McpStatusWord(S: TMcpStatus): string;

{ Drops one server's connection so its next call reconnects.  False when the
  name is unknown - a restart that silently succeeds on a typo is worse than
  one that fails. }
function McpRestart(const Name: string; out Err: string): Boolean;
{ Reconnects everything approved and rewrites the discovery cache.  The tool
  list the model was told about is NOT changed: the tools array renders ahead
  of the system prompt under one cache breakpoint, so a mid-session change
  throws the whole prompt cache away every turn it happens. }
function McpRefresh(out Err: string): Boolean;
{ Test seam: closes every connection and forgets every server.  A suite must
  call this before deleting its temporary directory, for the same reason it
  must call ClearJobs first - a live child holding the stderr spool makes the
  delete fail. }
procedure ClearMcpServers;

{ ---- name composition and validation, public so the tests can drive them -- }

{ mcp__<server>__<tool>, sanitized and length-checked.  '' when it cannot be
  made to fit, which skips the tool: a name we invented cannot be referenced
  by the user in an approval and reads to the model as a broken machine. }
function McpComposeName(const Server, Tool: string): string;
function McpSanitizeSegment(const S: string): string;
{ True when Decl can be forwarded to the API.  DeclText is the validated
  declaration, ready to re-parse; Why says what was wrong when it cannot. }
function McpValidateTool(Decl: TJson; const Server: string;
  out ComposedName, OrigName, DeclText, Why: string): Boolean;
function McpExpandVars(const S: string): string;

{ ---- approvals ---- }

{ 8 hex digits over the expanded command line, its arguments and the sorted
  names of its environment overrides.  Sorted keys, because the order two
  variables appear in a JSON object says nothing about what will run; the
  arguments are not sorted, because their order is exactly what runs. }
function McpCommandHash(const Cmd: string;
  const Args, EnvKeys: array of string): string;
{ True when this MCP tool's server has a standing per-call approval whose
  fingerprint still matches its current command line. }
function McpCallApproved(const ToolName: string): Boolean;
{ Records one, keyed to the live command line. }
procedure AllowMcpServer(const ToolName: string);

implementation

uses Classes, Process, Windows, uHttp, uRegex, uNotebook, uMcp;

const
  MaxReadBytes = 400 * 1024;   { keeps a stray huge file out of the context }
  { The ceiling on the depth argument of list_dir and search.  The complaint
    the argument answers is a *fixed* cap, not the existence of one: with no
    ceiling at all a single list_dir on a node_modules-shaped tree would do
    unbounded work only for Clip to throw most of the answer away. }
  MaxWalkDepth = 12;
  { A notebook is read whole or not at all.  The 400 KB cap would cut it
    mid-JSON, which is the one truncation that costs everything: a partial
    document does not parse, so the model gets a corrupt file rather than a
    short one.  Eight megabytes is affordable precisely because the outputs
    are summarised away - what reaches the model is the cells, not the
    base64 that makes the file big. }
  MaxNotebookBytes = 8 * 1024 * 1024;
  MaxOutBytes  = 30 * 1024;    { cap on any single tool result }
  { A fetched page larger than this is cut; the model gets the front, which
    is where documents put what they are about. }
  MaxFetchBytes = 200 * 1024;
  { Diff lines shown in a permission prompt.  Enough to judge a normal edit,
    short enough that a big one does not scroll the question off screen. }
  PreviewLines = 40;

{ ------------------------------------------------------------ path safety -- }

function NormalizeRoot: string;
begin
  if RootDir = '' then
    RootDir := GetCurrentDir;
  Result := ExcludeTrailingPathDelimiter(ExpandFileName(RootDir));
end;

{ Resolves P under the session root.  Fails when the result would sit outside
  the root, which is the only place this program is allowed to touch. }
function SafePath(const P: string; out Full: string; out Err: string): Boolean;
var
  Root, Cand: string;
begin
  Err := '';
  Root := NormalizeRoot;
  if P = '' then
  begin
    Err := 'path is required';
    Exit(False);
  end;
  if (Length(P) >= 2) and (P[2] = ':') then
    Cand := ExpandFileName(P)
  else if (Length(P) >= 1) and (P[1] in ['\', '/']) then
    Cand := ExpandFileName(Root + P)
  else
    Cand := ExpandFileName(IncludeTrailingPathDelimiter(Root) + P);
  Cand := ExcludeTrailingPathDelimiter(Cand);

  if (CompareText(Cand, Root) <> 0) and
     (CompareText(Copy(Cand, 1, Length(Root) + 1), Root + PathDelim) <> 0) then
  begin
    Err := Format('path escapes the session root (%s): %s', [Root, P]);
    Exit(False);
  end;

  { pasclaude's own state is off limits.  The session file is the conversation
    itself: letting the model read it wastes the context on a copy of what it
    already has, and letting it write there would let a tool call rewrite the
    history of the very turn that is running. }
  if (CompareText(Copy(Cand, Length(Root) + 2, Length(StateDirName)),
                  StateDirName) = 0) and
     ((Length(Cand) = Length(Root) + 1 + Length(StateDirName)) or
      (Cand[Length(Root) + 2 + Length(StateDirName)] = PathDelim)) then
  begin
    Err := StateDirName + ' holds pasclaude''s own session state and is not accessible';
    Exit(False);
  end;

  Full := Cand;
  Result := True;
end;

function ResolveInRoot(const P: string; out Full: string; out Err: string): Boolean;
begin
  Result := SafePath(P, Full, Err);
end;

{ -------------------------------------------------------------- .gitignore -- }

{ A deliberately partial reading of the format: comments, blank lines,
  dir-only rules (trailing /), anchored rules (leading /), and * within a
  segment.  Negation (!) is honoured for whole rules.  The full spec has
  corner cases (** spans, character classes) that build tools need and a
  listing filter does not; anything unmatched is simply shown, which errs on
  the side of the model seeing more rather than less. }
type
  TIgnoreRule = record
    Pattern: string;      { lowercased, / separators }
    DirOnly: Boolean;
    Anchored: Boolean;
    Negated: Boolean;
  end;

var
  IgnoreRules: array of TIgnoreRule;

procedure LoadIgnoreRules;
var
  L: TStringList;
  I, N: Integer;
  S: string;
  R: TIgnoreRule;
begin
  SetLength(IgnoreRules, 0);
  if not FileExists(IncludeTrailingPathDelimiter(NormalizeRoot) + '.gitignore') then
    Exit;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(IncludeTrailingPathDelimiter(NormalizeRoot) + '.gitignore');
    except
      Exit;   { an unreadable .gitignore just means nothing is filtered }
    end;
    N := 0;
    for I := 0 to L.Count - 1 do
    begin
      S := Trim(L[I]);
      if (S = '') or (S[1] = '#') then Continue;
      R.Negated := S[1] = '!';
      if R.Negated then Delete(S, 1, 1);
      R.DirOnly := (S <> '') and (S[Length(S)] = '/');
      if R.DirOnly then SetLength(S, Length(S) - 1);
      R.Anchored := (S <> '') and (S[1] = '/');
      if R.Anchored then Delete(S, 1, 1);
      if S = '' then Continue;
      R.Pattern := LowerCase(StringReplace(S, '\', '/', [rfReplaceAll]));
      SetLength(IgnoreRules, N + 1);
      IgnoreRules[N] := R;
      Inc(N);
    end;
  finally
    L.Free;
  end;
end;

{ Matches Pattern against one path segment or segment run, with * spanning
  anything except a separator. }
function SegMatch(const Pattern, S: string): Boolean;
var
  P, T: Integer;
  StarP, StarT: Integer;
begin
  P := 1;
  T := 1;
  StarP := 0;
  StarT := 0;
  while T <= Length(S) do
  begin
    if (P <= Length(Pattern)) and
       ((Pattern[P] = S[T]) or (Pattern[P] = '?')) then
    begin
      Inc(P);
      Inc(T);
    end
    else if (P <= Length(Pattern)) and (Pattern[P] = '*') then
    begin
      StarP := P;
      StarT := T;
      Inc(P);
    end
    else if StarP > 0 then
    begin
      { Backtrack: the star swallows one more character, but never a
        separator - that is what keeps *.txt from matching a\b.txt. }
      if S[StarT] = '/' then Exit(False);
      Inc(StarT);
      P := StarP + 1;
      T := StarT;
    end
    else
      Exit(False);
  end;
  while (P <= Length(Pattern)) and (Pattern[P] = '*') do
    Inc(P);
  Result := P > Length(Pattern);
end;

function IsIgnored(const RelPath: string; IsDir: Boolean): Boolean;
var
  I, J: Integer;
  Path, Seg: string;
  Rule: TIgnoreRule;
  Segs: array of string;
  NSeg: Integer;
  Hit: Boolean;
begin
  Result := False;
  if Length(IgnoreRules) = 0 then Exit;
  Path := LowerCase(StringReplace(RelPath, '\', '/', [rfReplaceAll]));

  { Split once; a rule may match the whole path or any single segment. }
  NSeg := 0;
  SetLength(Segs, 0);
  Seg := '';
  for I := 1 to Length(Path) do
    if Path[I] = '/' then
    begin
      SetLength(Segs, NSeg + 1);
      Segs[NSeg] := Seg;
      Inc(NSeg);
      Seg := '';
    end
    else
      Seg := Seg + Path[I];
  SetLength(Segs, NSeg + 1);
  Segs[NSeg] := Seg;
  Inc(NSeg);

  { Last matching rule wins, as in git. }
  for I := 0 to High(IgnoreRules) do
  begin
    Rule := IgnoreRules[I];
    { A dir-only rule can still hit a file underneath the directory: the
      match is applied to every ancestor segment as well as the leaf. }
    Hit := False;
    if Rule.Anchored then
      Hit := SegMatch(Rule.Pattern, Path) or
             ((Pos('/', Rule.Pattern) = 0) and (NSeg > 0) and
              SegMatch(Rule.Pattern, Segs[0]) and
              ((NSeg > 1) or IsDir or not Rule.DirOnly))
    else if Pos('/', Rule.Pattern) > 0 then
      Hit := SegMatch(Rule.Pattern, Path)
    else
      for J := 0 to NSeg - 1 do
        if SegMatch(Rule.Pattern, Segs[J]) then
        begin
          { A dir-only rule matched on the leaf requires the leaf to be a
            directory; matched on an ancestor it always applies. }
          if Rule.DirOnly and (J = NSeg - 1) and not IsDir then Continue;
          Hit := True;
          Break;
        end;
    if Hit then
      Result := not Rule.Negated;
  end;
end;

function Clip(const S: string): string;
begin
  if Length(S) <= MaxOutBytes then
    Result := S
  else
    { The cap is the last thing every tool result passes through, so it is
      also the last chance to split a character in one - and this result is
      on its way into a JSON request body that a single half-character makes
      unacceptable. }
    Result := Utf8Cut(S, MaxOutBytes) +
      Format(#10'... [truncated, %d bytes total]', [Length(S)]);
end;

function Rel(const Full: string): string;
var
  Root: string;
begin
  Root := IncludeTrailingPathDelimiter(NormalizeRoot);
  if CompareText(Copy(Full, 1, Length(Root)), Root) = 0 then
    Result := Copy(Full, Length(Root) + 1, MaxInt)
  else
    Result := Full;
end;

{ ------------------------------------------------------------------ files -- }

{ True when S is well-formed UTF-8.  Tool results are sent as JSON strings, and
  a request carrying invalid UTF-8 is rejected whole - so one binary file would
  otherwise destroy the turn rather than just the tool call. }
function IsValidUtf8(const S: string): Boolean;
var
  I, Len, Need: Integer;
  B: Byte;
begin
  I := 1;
  Len := Length(S);
  while I <= Len do
  begin
    B := Byte(S[I]);
    if B < $80 then
      Need := 0
    else if (B and $E0) = $C0 then
    begin
      Need := 1;
      if B < $C2 then Exit(False);        { overlong two-byte form }
    end
    else if (B and $F0) = $E0 then
      Need := 2
    else if (B and $F8) = $F0 then
    begin
      Need := 3;
      if B > $F4 then Exit(False);        { beyond U+10FFFF }
    end
    else
      Exit(False);                        { stray continuation or 0xFE/0xFF }

    if I + Need > Len then Exit(False);
    while Need > 0 do
    begin
      Inc(I);
      if (Byte(S[I]) and $C0) <> $80 then Exit(False);
      Dec(Need);
    end;
    Inc(I);
  end;
  Result := True;
end;

{ Renders bytes that are not text as a hex dump, so the model still gets
  something useful and the request stays valid. }
function HexDump(const S: string; MaxBytes: Integer): string;
var
  I, Stop: Integer;
  Line, Ascii: string;
  B: Byte;
begin
  Result := '';
  Stop := Length(S);
  if Stop > MaxBytes then Stop := MaxBytes;
  I := 1;
  while I <= Stop do
  begin
    Line := Format('%8.8x  ', [I - 1]);
    Ascii := '';
    while (I <= Stop) and (((I - 1) mod 16) <> 15) do
    begin
      B := Byte(S[I]);
      Line := Line + IntToHex(B, 2) + ' ';
      if (B >= 32) and (B < 127) then Ascii := Ascii + Chr(B) else Ascii := Ascii + '.';
      Inc(I);
    end;
    if I <= Stop then
    begin
      B := Byte(S[I]);
      Line := Line + IntToHex(B, 2) + ' ';
      if (B >= 32) and (B < 127) then Ascii := Ascii + Chr(B) else Ascii := Ascii + '.';
      Inc(I);
    end;
    Result := Result + Line + ' |' + Ascii + '|'#10;
  end;
  if Length(S) > MaxBytes then
    Result := Result + Format('... [%d bytes total]'#10, [Length(S)]);
end;

function OemToUtf8(const S: string): string;
var
  W: WideString;
  U: UTF8String;
  N, I: Integer;
  CP: UINT;
begin
  Result := '';
  if S = '' then Exit;
  { FPC's CP_OEMCP is the RTL's own marker value (1), not a Windows codepage
    identifier, so passing it to MultiByteToWideChar converts nothing. }
  CP := GetConsoleOutputCP;
  if CP = 0 then CP := GetOEMCP;
  N := MultiByteToWideChar(CP, 0, PAnsiChar(S), Length(S), nil, 0);
  if N > 0 then
  begin
    SetLength(W, N);
    if MultiByteToWideChar(CP, 0, PAnsiChar(S), Length(S), PWideChar(W), N) = N then
    begin
      U := UTF8Encode(W);
      { The bytes are copied one at a time.  Assigning a UTF8String straight to
        a string makes FPC convert it back to the ANSI codepage, silently
        undoing the work. }
      SetLength(Result, Length(U));
      for I := 1 to Length(U) do
        Result[I] := Char(U[I]);
      if IsValidUtf8(Result) then Exit;
    end;
  end;
  { Conversion failed, so the bytes are scrubbed to ASCII rather than left
    invalid: a mangled character is a far smaller problem than a request the
    API refuses outright. }
  Result := '';
  for I := 1 to Length(S) do
    if Byte(S[I]) < $80 then
      Result := Result + S[I]
    else
      Result := Result + '?';
end;

{ The reading half of every file tool.  Limit is a parameter rather than a
  constant because a notebook has to arrive whole to parse at all, while an
  ordinary source file only has to arrive in a useful quantity. }
function LoadFileLimited(const Full: string; Limit: Int64;
  out Text: string; out Err: string): Boolean;
var
  F: TFileStream;
  N: Int64;
begin
  Text := '';
  Err := '';
  try
    F := TFileStream.Create(Full, fmOpenRead or fmShareDenyNone);
  except
    on E: Exception do
    begin
      Err := E.Message;
      Exit(False);
    end;
  end;
  try
    N := F.Size;
    if N > Limit then N := Limit;
    SetLength(Text, N);
    if N > 0 then F.ReadBuffer(Text[1], N);
    if F.Size > Limit then
      Err := Format('(file is %d bytes; first %d shown)', [F.Size, Limit]);
    Result := True;
  finally
    F.Free;
  end;
end;

function LoadFileText(const Full: string; out Text: string; out Err: string): Boolean;
begin
  Result := LoadFileLimited(Full, MaxReadBytes, Text, Err);
end;

function SaveFileText(const Full, Text: string; out Err: string): Boolean;
var
  F: TFileStream;
  Dir: string;
begin
  Err := '';
  Dir := ExtractFilePath(Full);
  if (Dir <> '') and not DirectoryExists(Dir) then
    if not ForceDirectories(Dir) then
    begin
      Err := 'cannot create ' + Dir;
      Exit(False);
    end;
  try
    F := TFileStream.Create(Full, fmCreate);
    try
      if Text <> '' then F.WriteBuffer(Text[1], Length(Text));
    finally
      F.Free;
    end;
    Result := True;
  except
    on E: Exception do
    begin
      Err := E.Message;
      Result := False;
    end;
  end;
end;

{ Numbers each line the way a code reader expects, so the model can refer to
  line numbers when it proposes an edit. }
function WithLineNumbers(const Text: string): string;
var
  L: TStringList;
  I: Integer;
begin
  L := TStringList.Create;
  try
    L.Text := Text;
    Result := '';
    for I := 0 to L.Count - 1 do
      Result := Result + Format('%5d  %s'#10, [I + 1, L[I]]);
  finally
    L.Free;
  end;
end;

{ ------------------------------------------------------------- directories -- }

{ MaxDepth 0 is the old non-recursive listing and 4 the old recursive one:
  both are now expressed as a depth rather than as a Boolean plus a constant,
  which is what lets the caller ask for more. }
function ListDir(const Full: string; MaxDepth: Integer): string;
var
  RootPrefix: string;

  procedure Walk(const Dir, Prefix: string; Depth: Integer);
  var
    R: TSearchRec;
    Dirs, Files: TStringList;
    I: Integer;
    RelName: string;
  begin
    if Depth > MaxDepth then Exit;
    Dirs := TStringList.Create;
    Files := TStringList.Create;
    try
      if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, R) = 0 then
      begin
        repeat
          if (R.Name = '.') or (R.Name = '..') then Continue;
          RelName := Copy(IncludeTrailingPathDelimiter(Dir) + R.Name,
            Length(RootPrefix) + 1, MaxInt);
          { .git and build output would flood the listing with noise. }
          if (R.Attr and faDirectory) <> 0 then
          begin
            if (R.Name = '.git') or (R.Name = 'node_modules') or
               (CompareText(R.Name, StateDirName) = 0) then Continue;
            if IsIgnored(RelName, True) then Continue;
            Dirs.Add(R.Name);
          end
          else
          begin
            if IsIgnored(RelName, False) then Continue;
            Files.Add(Format('%s (%d bytes)', [R.Name, R.Size]));
          end;
        until FindNext(R) <> 0;
        SysUtils.FindClose(R);
      end;
      Dirs.Sort;
      Files.Sort;
      for I := 0 to Dirs.Count - 1 do
      begin
        Result := Result + Prefix + Dirs[I] + '\'#10;
        if Depth < MaxDepth then
          Walk(IncludeTrailingPathDelimiter(Dir) + Dirs[I], Prefix + '  ', Depth + 1);
      end;
      for I := 0 to Files.Count - 1 do
        Result := Result + Prefix + Files[I] + #10;
    finally
      Dirs.Free;
      Files.Free;
    end;
  end;

begin
  Result := Rel(Full) + '\'#10;
  RootPrefix := IncludeTrailingPathDelimiter(NormalizeRoot);
  Walk(Full, '  ', 0);
end;

{ ------------------------------------------------------------------ search -- }

{ Two engines behind one walker.  UseRegex is opt-in rather than sniffed from
  the pattern text, because real code searches are full of metacharacters used
  literally - "Result :=", "array[0]", "foo.bar" - and a "looks like a regex"
  heuristic would silently reinterpret them with no error anyone could see.
  Err is non-empty only when the pattern would not compile; the caller turns
  that into a tool error. }
function GrepTree(const Root, Pattern, Glob: string;
  UseRegex, CaseSensitive: Boolean; MaxDepth: Integer;
  out Err: string): string;
var
  Hits: Integer;
  RootPrefix, Needle: string;
  Rx: TRegex;
  Truncated: Boolean;

  { The match decision for one line.  A budget exhaustion is not a miss: it
    means the answer is unknown, so it stops the walk and is reported. }
  function LineHit(const L: string): Boolean;
  begin
    if UseRegex then
    begin
      case Rx.Match(L) of
        rrMatch: Result := True;
        rrBudget:
          begin
            Truncated := True;
            Result := False;
          end;
      else
        Result := False;
      end;
    end
    else if CaseSensitive then
      Result := Pos(Needle, L) > 0
    else
      Result := Pos(Needle, LowerCase(L)) > 0;
  end;

  function Matches(const Name: string): Boolean;
  begin
    if (Glob = '') or (Glob = '*') then Exit(True);
    { A glob containing * is exactly that and nothing else - otherwise
      nope*.txt would still match every .txt through the extension fallback,
      and a "did not match" filter that matches is worse than none.  The
      historical looser forms - a bare extension like ".pas", a substring -
      are kept only for starless patterns, because the model was told about
      them and models repeat what worked. }
    if Pos('*', Glob) > 0 then
      Exit(SegMatch(LowerCase(Glob), LowerCase(Name)));
    Result :=
      (LowerCase(ExtractFileExt(Name)) = LowerCase(ExtractFileExt(Glob))) or
      (Pos(LowerCase(Glob), LowerCase(Name)) > 0);
  end;

  procedure Walk(const Dir: string; Depth: Integer);
  var
    R: TSearchRec;
    { Named apart from the enclosing function's out parameter: Err there is
      the compile error, and shadowing it here would be a trap. }
    LText, LErr, Line: string;
    L: TStringList;
    I: Integer;
    RelName: string;
  begin
    if (Depth > MaxDepth) or (Hits >= 200) or Truncated then Exit;
    if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, R) = 0 then
    begin
      repeat
        if (R.Name = '.') or (R.Name = '..') then Continue;
        RelName := Copy(IncludeTrailingPathDelimiter(Dir) + R.Name,
          Length(RootPrefix) + 1, MaxInt);
        if (R.Attr and faDirectory) <> 0 then
        begin
          { The session file holds the whole conversation, so a search that
            matched it would feed the transcript back into the model - growing
            the context every turn with a copy of itself. }
          if (R.Name = '.git') or (R.Name = 'node_modules') or
             (CompareText(R.Name, StateDirName) = 0) then Continue;
          if IsIgnored(RelName, True) then Continue;
          Walk(IncludeTrailingPathDelimiter(Dir) + R.Name, Depth + 1);
        end
        else if Matches(R.Name) and (R.Size < MaxReadBytes) then
        begin
          if IsIgnored(RelName, False) then Continue;
          if not LoadFileText(IncludeTrailingPathDelimiter(Dir) + R.Name, LText, LErr) then
            Continue;
          { A hit goes straight into a JSON request body, where one bad byte
            makes the API reject the whole turn.  read_file has hex-dumped
            binary for exactly this reason since the beginning; search never
            checked, so a binary file whose name happened to pass the glob
            could take down the conversation. }
          if not IsValidUtf8(LText) then Continue;
          { The whole-file prefilter is what makes a substring search over a
            big tree cheap.  A regex has no cheap literal to prefilter on, so
            that path pays per line - bounded by the step budget instead. }
          if not UseRegex then
          begin
            if CaseSensitive then
            begin
              if Pos(Needle, LText) = 0 then Continue;
            end
            else if Pos(Needle, LowerCase(LText)) = 0 then Continue;
          end;
          L := TStringList.Create;
          try
            L.Text := LText;
            for I := 0 to L.Count - 1 do
            begin
              Line := L[I];
              if LineHit(Line) then
              begin
                Result := Result + Format('%s:%d: %s'#10,
                  [Rel(IncludeTrailingPathDelimiter(Dir) + R.Name), I + 1, Trim(Line)]);
                Inc(Hits);
                if Hits >= 200 then Break;
              end;
              if Truncated then Break;
            end;
          finally
            L.Free;
          end;
        end;
      until (FindNext(R) <> 0) or (Hits >= 200) or Truncated;
      SysUtils.FindClose(R);
    end;
  end;

begin
  Result := '';
  Err := '';
  Hits := 0;
  Truncated := False;
  Rx := nil;
  if CaseSensitive then Needle := Pattern else Needle := LowerCase(Pattern);
  if UseRegex and not TRegex.Compile(Pattern, CaseSensitive, Rx, Err) then
    Exit('');
  try
    { One budget for the whole call rather than one per line, so a hostile
      pattern cannot spend its allowance again on every file in the tree. }
    if Rx <> nil then Rx.Budget := DefaultRegexBudget;
    RootPrefix := IncludeTrailingPathDelimiter(NormalizeRoot);
    Walk(Root, 0);
  finally
    Rx.Free;
  end;
  { Partial hits are still worth having, so this is a note rather than an
    error - but the model has to be told the answer is incomplete. }
  if Truncated then
    Result := Result + '[search stopped: pattern too expensive]'#10;
  if Trim(Result) = '' then
    Result := 'no matches';
end;

{ -------------------------------------------------------------------- bash -- }

{ Runs Cmd through cmd.exe and returns its combined output.  A hard timeout
  keeps a hung command from freezing the session. }
function RunShell(const Cmd, WorkDir: string; out ExitCode: Integer): string;
var
  P: TProcess;
  Buf: array[0..4095] of Byte;
  N: LongInt;
  Deadline: QWord;
  S: string;
begin
  Result := '';
  ExitCode := -1;
  P := TProcess.Create(nil);
  try
    P.Executable := SysUtils.GetEnvironmentVariable('ComSpec');
    if P.Executable = '' then P.Executable := 'cmd.exe';
    P.Parameters.Add('/C');
    P.Parameters.Add(Cmd);
    P.CurrentDirectory := WorkDir;
    P.Options := [poUsePipes, poStderrToOutPut, poNoConsole];
    try
      P.Execute;
    except
      on E: Exception do
      begin
        Result := 'failed to start: ' + E.Message;
        Exit;
      end;
    end;
    Deadline := GetTickCount64 + 120000;
    repeat
      while P.Output.NumBytesAvailable > 0 do
      begin
        N := P.Output.Read(Buf[0], SizeOf(Buf));
        if N <= 0 then Break;
        SetString(S, PAnsiChar(@Buf[0]), N);
        Result := Result + S;
      end;
      if not P.Running then Break;
      if GetTickCount64 > Deadline then
      begin
        P.Terminate(1);
        Result := Result + #10'[timed out after 120s]';
        Break;
      end;
      Sleep(20);
    until False;
    { Drain whatever landed in the pipe after the process exited. }
    while P.Output.NumBytesAvailable > 0 do
    begin
      N := P.Output.Read(Buf[0], SizeOf(Buf));
      if N <= 0 then Break;
      SetString(S, PAnsiChar(@Buf[0]), N);
      Result := Result + S;
    end;
    ExitCode := P.ExitStatus;
  finally
    P.Free;
  end;
end;

function RunShellQuiet(const Cmd: string; out ExitCode: Integer): string;
begin
  Result := RunShell(Cmd, NormalizeRoot, ExitCode);
  if not IsValidUtf8(Result) then
    Result := OemToUtf8(Result);
end;

{ -------------------------------------------------------- background bash -- }

{ A second, entirely separate launch path.  RunShell above is left alone on
  purpose: its drain loop is correct only while somebody is blocking on it,
  and the whole point here is that nobody is.  The two share the permission
  gate and the OEM conversion rule, and nothing else. }

const
  { Eight live jobs is far more than a session ever wants and still a number
    a user can read off /jobs.  The cap exists so a model in a loop cannot
    fill the machine with detached shells. }
  MaxJobs = 8;
  { Bytes handed back per poll.  Deliberately under MaxOutBytes so the status
    line fits.  A chunk of solid high bytes can grow when it is converted out
    of the OEM codepage, so the ceiling is not exact - but it is a ceiling,
    and no byte is ever dropped, which is the property that matters: the
    offset advances by what was returned, so what is not returned now comes
    back next time rather than vanishing. }
  MaxPollBytes = 24 * 1024;
  { A runaway job writing to disk forever is the failure mode a spool file
    has that a pipe does not.  Sixteen megabytes is generous for anything
    worth reading and small enough to notice. }
  MaxSpoolBytes = 16 * 1024 * 1024;
  JobKillWaitMs = 2000;
  JobsDirName = 'jobs';

{ FPC 3.2.2's Windows unit does not declare the job-object API at all, so the
  four entry points and the two records it needs are declared here.  These are
  the documented kernel32 exports, nothing exotic; TJobExtendedLimits is 144
  bytes on x64, which SetInformationJobObject validates on every call and a
  probe confirmed before this was written. }
const
  JobObjectExtendedLimitInformation = 9;
  JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = $2000;

type
  TJobBasicLimits = record
    PerProcessUserTimeLimit: Int64;
    PerJobUserTimeLimit: Int64;
    LimitFlags: DWORD;
    MinimumWorkingSetSize: SIZE_T;
    MaximumWorkingSetSize: SIZE_T;
    ActiveProcessLimit: DWORD;
    Affinity: ULONG_PTR;
    PriorityClass: DWORD;
    SchedulingClass: DWORD;
  end;

  TJobIoCounters = record
    ReadOperationCount, WriteOperationCount, OtherOperationCount: QWord;
    ReadTransferCount, WriteTransferCount, OtherTransferCount: QWord;
  end;

  TJobExtendedLimits = record
    BasicLimitInformation: TJobBasicLimits;
    IoInfo: TJobIoCounters;
    ProcessMemoryLimit: SIZE_T;
    JobMemoryLimit: SIZE_T;
    PeakProcessMemoryUsed: SIZE_T;
    PeakJobMemoryUsed: SIZE_T;
  end;

function CreateJobObjectA(Attr: Pointer; Name: PAnsiChar): THandle; stdcall;
  external 'kernel32' name 'CreateJobObjectA';
function SetInformationJobObject(J: THandle; Cls: Integer; Info: Pointer;
  Len: DWORD): BOOL; stdcall; external 'kernel32' name 'SetInformationJobObject';
function AssignProcessToJobObject(J, P: THandle): BOOL; stdcall;
  external 'kernel32' name 'AssignProcessToJobObject';
function TerminateJobObject(J: THandle; Code: UINT): BOOL; stdcall;
  external 'kernel32' name 'TerminateJobObject';

type
  TBackgroundJob = record
    Id, Cmd, Spool, Note: string;
    Proc, Job: THandle;
    Offset: Int64;
    Started: QWord;
    Done, Reaped, Tree, Killed: Boolean;
    ExitCode: Integer;
  end;

var
  Jobs: array of TBackgroundJob;
  JobSeq: Integer = 0;

{ The spool directory.  This deliberately bypasses SafePath: the state
  directory is exactly where that guard refuses to let the model go, and
  that refusal is the property keeping the model from reading a half-written
  spool behind its own back or forging one for a job it never started. }
function JobsDir: string;
begin
  Result := IncludeTrailingPathDelimiter(NormalizeRoot) + StateDirName +
    PathDelim + JobsDirName + PathDelim;
  ForceDirectories(Result);
end;

{ The only route from an id to a path, which is what keeps a hostile id from
  naming a file: an id that is not in the table is simply not a job. }
function FindJob(const Id: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  if Id = '' then Exit;
  for I := 0 to High(Jobs) do
    if Jobs[I].Id = Id then Exit(I);
end;

function SpoolSize(const P: string): Int64;
var
  F: TFileStream;
begin
  Result := 0;
  try
    F := TFileStream.Create(P, fmOpenRead or fmShareDenyNone);
    try
      Result := F.Size;
    finally
      F.Free;
    end;
  except
    Result := 0;
  end;
end;

{ True while the process still runs.  The exit code is latched on the first
  poll that sees it gone, because a handle stays signalled forever but the
  code is only worth reading once. }
function JobAlive(var J: TBackgroundJob): Boolean;
var
  C: DWORD;
begin
  Result := WaitForSingleObject(J.Proc, 0) <> WAIT_OBJECT_0;
  if Result then Exit;
  if not J.Done then
  begin
    C := 0;
    if GetExitCodeProcess(J.Proc, C) then J.ExitCode := Integer(C);
    J.Done := True;
  end;
end;

{ Every handle this unit opened is closed here and every byte it wrote to
  disk is removed here.  The -gh run and the user's process list are the two
  things this has to leave clean, and they fail in opposite directions:
  forgetting CloseHandle leaks quietly, forgetting the kill leaves a process
  the user cannot name. }
procedure FreeJob(var J: TBackgroundJob);
begin
  if J.Proc <> 0 then
  begin
    if WaitForSingleObject(J.Proc, 0) <> WAIT_OBJECT_0 then
    begin
      if J.Job <> 0 then
        TerminateJobObject(J.Job, 1)
      else
        TerminateProcess(J.Proc, 1);
      WaitForSingleObject(J.Proc, JobKillWaitMs);
    end;
    CloseHandle(J.Proc);
    J.Proc := 0;
  end;
  if J.Job <> 0 then
  begin
    CloseHandle(J.Job);
    J.Job := 0;
  end;
  if J.Spool <> '' then
    SysUtils.DeleteFile(J.Spool);   { a spool nobody can poll is just litter }
  J.Id := '';
  J.Cmd := '';
  J.Spool := '';
  J.Note := '';
end;

{ Refreshes exit state, and stops anything that has written more than the
  spool cap.  Purge additionally drops jobs whose output has been read to the
  end after exiting - only StartBackgroundJob asks for that, because a poll
  that quietly forgot the job it just reported on would leave the model
  holding an id that had stopped existing between two sentences. }
procedure SweepJobs(Purge: Boolean);
var
  I, N: Integer;
begin
  for I := 0 to High(Jobs) do
  begin
    if JobAlive(Jobs[I]) and (SpoolSize(Jobs[I].Spool) > MaxSpoolBytes) then
    begin
      if Jobs[I].Job <> 0 then
        TerminateJobObject(Jobs[I].Job, 1)
      else
        TerminateProcess(Jobs[I].Proc, 1);
      WaitForSingleObject(Jobs[I].Proc, JobKillWaitMs);
      Jobs[I].Killed := True;
      Jobs[I].Note := Format('[%s produced more than %d MB and was stopped]',
        [Jobs[I].Id, MaxSpoolBytes div (1024 * 1024)]);
      JobAlive(Jobs[I]);
    end;
  end;
  if not Purge then Exit;
  N := 0;
  for I := 0 to High(Jobs) do
    if Jobs[I].Reaped then
      FreeJob(Jobs[I])
    else
    begin
      if N <> I then Jobs[N] := Jobs[I];
      Inc(N);
    end;
  SetLength(Jobs, N);
end;

function StartBackgroundJob(const Cmd: string; out Id: string; out Err: string): Boolean;
var
  Info: TJobExtendedLimits;
  SA: SECURITY_ATTRIBUTES;
  SI: STARTUPINFOA;
  PI: PROCESS_INFORMATION;
  hJob, hSpool, hNul: THandle;
  CmdLine, Spool, ComSpec: string;
  J: TBackgroundJob;
begin
  Result := False;
  Id := '';
  Err := '';
  SweepJobs(True);
  if Trim(Cmd) = '' then
  begin
    Err := 'command is required';
    Exit;
  end;
  if Length(Jobs) >= MaxJobs then
  begin
    Err := Format('too many background jobs (%d running); read one with ' +
      'bash_output or stop one with kill_bash', [Length(Jobs)]);
    Exit;
  end;

  Inc(JobSeq);
  Spool := JobsDir + 'bg' + IntToStr(JobSeq) + '.out';

  hJob := CreateJobObjectA(nil, nil);
  if hJob <> 0 then
  begin
    FillChar(Info, SizeOf(Info), 0);
    Info.BasicLimitInformation.LimitFlags := JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if not SetInformationJobObject(hJob, JobObjectExtendedLimitInformation,
             @Info, SizeOf(Info)) then
    begin
      CloseHandle(hJob);
      hJob := 0;
    end;
  end;

  { The child inherits a handle onto the spool and onto NUL.  NUL for stdin
    matters as much as the spool does: a command that reads stdin gets an
    instant EOF instead of waiting forever for a keyboard nobody is at. }
  FillChar(SA, SizeOf(SA), 0);
  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True;
  hSpool := CreateFile(PChar(Spool), GENERIC_WRITE,
    FILE_SHARE_READ or FILE_SHARE_WRITE, @SA, CREATE_ALWAYS,
    FILE_ATTRIBUTE_NORMAL, 0);
  if hSpool = INVALID_HANDLE_VALUE then
  begin
    if hJob <> 0 then CloseHandle(hJob);
    Err := 'could not open the output file: ' + SysErrorMessage(GetLastError);
    Exit;
  end;
  hNul := CreateFile('NUL', GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE,
    @SA, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);

  ComSpec := SysUtils.GetEnvironmentVariable('ComSpec');
  if ComSpec = '' then ComSpec := 'cmd.exe';
  { Raw CreateProcess rather than TProcess, which cannot be told to hand a
    file handle to its child.  The alternatives that keep TProcess both
    change what the command MEANS - wrapping it in "( ... ) > spool 2>&1"
    breaks on a bare ')', a generated .cmd file changes %% expansion - and a
    background command that behaves differently from the same command in the
    foreground is a trap nobody could explain afterwards.  The line reaching
    cmd.exe here is character-identical to RunShell's. }
  CmdLine := '"' + ComSpec + '" /C ' + Cmd;
  { CreateProcessA may write into lpCommandLine, so it must not be sharing a
    string with anybody. }
  UniqueString(CmdLine);
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESTDHANDLES;
  SI.hStdInput := hNul;
  SI.hStdOutput := hSpool;
  SI.hStdError := hSpool;
  FillChar(PI, SizeOf(PI), 0);

  if not CreateProcess(nil, PChar(CmdLine), nil, nil, True, CREATE_NO_WINDOW,
           nil, PChar(NormalizeRoot), SI, PI) then
  begin
    Err := 'could not start: ' + SysErrorMessage(GetLastError);
    CloseHandle(hSpool);
    if hNul <> INVALID_HANDLE_VALUE then CloseHandle(hNul);
    if hJob <> 0 then CloseHandle(hJob);
    SysUtils.DeleteFile(Spool);
    Exit;
  end;

  { The child holds its own copies; a handle kept here is a handle leaked. }
  CloseHandle(hSpool);
  if hNul <> INVALID_HANDLE_VALUE then CloseHandle(hNul);
  CloseHandle(PI.hThread);

  FillChar(J, SizeOf(J), 0);
  J.Id := 'bg' + IntToStr(JobSeq);
  J.Cmd := Cmd;
  J.Spool := Spool;
  J.Proc := PI.hProcess;
  J.Job := hJob;
  J.Started := GetTickCount64;
  J.ExitCode := -1;
  { Assignment is after the spawn, so a grandchild started in the microseconds
    before it escapes the job.  cmd.exe has to parse its command line first,
    so the window is tiny - but it is real, and a stray that escapes survives
    kill_bash.  When assignment fails outright the kill reaches cmd.exe only,
    which the status line says out loud rather than pretending otherwise. }
  J.Tree := (hJob <> 0) and AssignProcessToJobObject(hJob, PI.hProcess);
  if (hJob <> 0) and not J.Tree then
    J.Note := Format('[%s could not be put in a job object; stopping it may ' +
      'leave programs it started running]', [J.Id]);

  SetLength(Jobs, Length(Jobs) + 1);
  Jobs[High(Jobs)] := J;
  Id := J.Id;
  Result := True;
end;

{ The shared reader behind poll and kill.  While the process is still running
  the chunk is trimmed back to the last newline, so a poll never hands over
  half a line - and with it never splits a multi-byte character across two
  polls, which would leave both halves invalid with no way to rejoin them.
  Once it has exited whatever remains is final and is taken whole.

  The offset advances by exactly what is returned, before the OEM conversion
  changes the length.  That is the invariant the model depends on: no byte
  twice, no byte skipped. }
function ReadJobChunk(var J: TBackgroundJob; Alive: Boolean;
  out More: Boolean): string;
var
  F: TFileStream;
  Buf: array of Byte;
  N: LongInt;
  P: Integer;
begin
  Result := '';
  More := False;
  if J.Spool = '' then Exit;
  try
    F := TFileStream.Create(J.Spool, fmOpenRead or fmShareDenyNone);
    try
      if J.Offset >= F.Size then Exit;
      F.Position := J.Offset;
      SetLength(Buf, MaxPollBytes);
      N := F.Read(Buf[0], MaxPollBytes);
      if N <= 0 then Exit;
      More := N >= MaxPollBytes;
      SetString(Result, PAnsiChar(@Buf[0]), N);
    finally
      F.Free;
    end;
  except
    { A spool that cannot be opened is not worth an error: the status line
      still tells the caller whether the job is alive. }
    Result := '';
    More := False;
    Exit;
  end;
  if Alive then
  begin
    P := LastDelimiter(#10, Result);
    if P > 0 then
      SetLength(Result, P)
    { No newline in the whole buffer.  Holding it back is right while there
      is room for the line to finish, but once the read came back full the
      line is longer than a poll and waiting for its end means waiting
      forever: the offset would never advance and every later poll would
      return this same nothing.  A minified asset or a single-line build
      report does exactly that, so a full buffer is handed over cut at the
      last complete character instead - which is the only part of the
      line-boundary rule that was ever about correctness. }
    else if More then
      Result := Utf8Cut(Result, Length(Result))
    else
      Exit('');               { no complete line yet; keep it for next time }
  end;
  Inc(J.Offset, Length(Result));
  if not IsValidUtf8(Result) then
    Result := OemToUtf8(Result);
end;

function PollBackgroundJob(const Id: string; out Found: Boolean): string;
var
  I: Integer;
  Alive, More: Boolean;
  Chunk: string;
  Age: QWord;
begin
  Result := '';
  Found := False;
  SweepJobs(False);
  I := FindJob(Id);
  if I < 0 then Exit;
  Found := True;
  { Check the exit state before reading, the same discipline RunShell's
    post-exit drain follows: anything written between the read and the check
    is not lost, it is simply the next poll's. }
  Alive := JobAlive(Jobs[I]);
  Chunk := ReadJobChunk(Jobs[I], Alive, More);
  Age := (GetTickCount64 - Jobs[I].Started) div 1000;
  if Jobs[I].Killed then
    Result := Format('[%s killed]', [Jobs[I].Id])
  else if Alive then
    Result := Format('[%s running, %ds]', [Jobs[I].Id, Age])
  else
    Result := Format('[%s exited %d after %ds]',
      [Jobs[I].Id, Jobs[I].ExitCode, Age]);
  if Chunk <> '' then
    Result := Result + #10 + Chunk
  else
    Result := Result + #10 + '(no new output)';
  if More then
    Result := Result + #10'[... more output pending; call bash_output again]';
  if Jobs[I].Note <> '' then
    Result := Result + #10 + Jobs[I].Note;
  { Finished and fully read: the next launch may forget it. }
  if (not Alive) and (not More) and (Jobs[I].Offset >= SpoolSize(Jobs[I].Spool)) then
    Jobs[I].Reaped := True;
end;

function KillBackgroundJob(const Id: string): Boolean;
var
  I: Integer;
  C: DWORD;
begin
  I := FindJob(Id);
  Result := I >= 0;
  if not Result then Exit;
  if WaitForSingleObject(Jobs[I].Proc, 0) <> WAIT_OBJECT_0 then
  begin
    if Jobs[I].Job <> 0 then
      TerminateJobObject(Jobs[I].Job, 1)
    else
      TerminateProcess(Jobs[I].Proc, 1);
    WaitForSingleObject(Jobs[I].Proc, JobKillWaitMs);
  end;
  Jobs[I].Killed := True;
  Jobs[I].Done := True;
  Jobs[I].ExitCode := -1;
  C := 0;
  if GetExitCodeProcess(Jobs[I].Proc, C) and (C <> STILL_ACTIVE) then
    Jobs[I].ExitCode := Integer(C);
  { The handles stay open: the tail of the output is usually the interesting
    part, and the entry goes away at the next launch or at /clear. }
end;

function BackgroundJobList: string;
var
  I: Integer;
  State, C: string;
  Pending: Int64;
begin
  Result := '';
  SweepJobs(False);
  for I := 0 to High(Jobs) do
  begin
    if Jobs[I].Killed then
      State := 'killed'
    else if JobAlive(Jobs[I]) then
      State := 'running'
    else
      State := Format('exited %d', [Jobs[I].ExitCode]);
    Pending := SpoolSize(Jobs[I].Spool) - Jobs[I].Offset;
    if Pending < 0 then Pending := 0;
    C := Jobs[I].Cmd;
    { The command came out of the model's JSON, so it can be UTF-8, and this
      listing goes back to the model as the answer to a bash_output with no
      job id - a byte cut through a character here invalidates the whole
      request body, not just the column it widened. }
    if Length(C) > 60 then C := Utf8Cut(C, 57) + '...';
    Result := Result + Format('%s  %s  %ds  %d bytes unread  %s'#10,
      [Jobs[I].Id, State, (GetTickCount64 - Jobs[I].Started) div 1000,
       Pending, C]);
  end;
  if Result = '' then Result := 'no background jobs';
end;

function BackgroundJobCount: Integer;
begin
  Result := Length(Jobs);
end;

function WaitBackgroundJob(const Id: string; TimeoutMs: Integer): Boolean;
var
  I: Integer;
  Deadline: QWord;
begin
  I := FindJob(Id);
  if I < 0 then Exit(False);
  Deadline := GetTickCount64 + QWord(TimeoutMs);
  repeat
    if not JobAlive(Jobs[I]) then Exit(True);
    if GetTickCount64 >= Deadline then Exit(False);
    WaitForSingleObject(Jobs[I].Proc, 50);
  until False;
end;

procedure ClearJobs;
var
  I: Integer;
begin
  for I := 0 to High(Jobs) do
    FreeJob(Jobs[I]);
  SetLength(Jobs, 0);
  { Ids restart, because nothing that could still name an old one survives a
    clear: the transcript holding them has been thrown away too. }
  JobSeq := 0;
end;

{ ---------------------------------------------------------- bash prefixes -- }

var
  BashPrefixes: array of string;

{ The first token, lowercased, stripped of a path and an .exe suffix - so
  "git status" and "C:\Program Files\Git\git.exe log" share the prefix
  "git".  An "always" answer covers the program, not the arguments: the
  user who approved "git status" forever meant git, not status.

  Compound commands are deliberately not split: "git status && del *" has
  the prefix "git" only as its first program, and cmd.exe runs the rest
  regardless, so the whole line must carry the strictest reading.  The &,
  |, ; separators therefore poison the prefix - such a command never
  matches a stored prefix and is always asked about. }
function BashPrefix(const Cmd: string): string;
var
  S: string;
  I: Integer;
begin
  Result := '';
  S := Trim(Cmd);
  if S = '' then Exit;
  { A chained command is asked about every time; see above. }
  for I := 1 to Length(S) do
    if S[I] in ['&', '|', ';', '<', '>', '%', '^'] then Exit;
  { A quoted program name runs to the closing quote, spaces included;
    otherwise the first space ends it. }
  if S[1] = '"' then
  begin
    I := Pos('"', S, 2);
    if I = 0 then Exit;   { an unclosed quote is not worth guessing about }
    S := Copy(S, 2, I - 2);
  end
  else
  begin
    I := Pos(' ', S);
    if I > 0 then S := Copy(S, 1, I - 1);
  end;
  S := ExtractFileName(S);
  if LowerCase(ExtractFileExt(S)) = '.exe' then
    S := ChangeFileExt(S, '');
  Result := LowerCase(S);
end;

function BashPrefixAllowed(const Cmd: string): Boolean;
var
  P: string;
  I: Integer;
begin
  Result := False;
  P := BashPrefix(Cmd);
  if P = '' then Exit;
  for I := 0 to High(BashPrefixes) do
    if BashPrefixes[I] = P then Exit(True);
end;

procedure AllowBashPrefix(const Cmd: string);
var
  P: string;
begin
  P := BashPrefix(Cmd);
  if P = '' then Exit;
  if BashPrefixAllowed(Cmd) then Exit;
  SetLength(BashPrefixes, Length(BashPrefixes) + 1);
  BashPrefixes[High(BashPrefixes)] := P;
end;

procedure ClearBashPrefixes;
begin
  SetLength(BashPrefixes, 0);
end;

{ ------------------------------------------------------- the tool registry -- }

type
  TToolSource = record
    Prefix: string;
    Declare: TToolDeclareProc;
    Run: TToolRunProc;
  end;

var
  ToolSources: array of TToolSource;

{ ^[a-z][a-z0-9_]*__$ .  The trailing double underscore is the whole point:
  it is a structural invariant rather than a check against the list of
  built-in names, so it does not have to be revisited when a thirteenth
  built-in lands, and no source can ever shadow one. }
function ValidSourcePrefix(const P: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Length(P) < 3 then Exit;
  if Copy(P, Length(P) - 1, 2) <> '__' then Exit;
  if not (P[1] in ['a'..'z']) then Exit;
  for I := 1 to Length(P) do
    if not (P[I] in ['a'..'z', '0'..'9', '_']) then Exit;
  Result := True;
end;

function RegisterToolSource(const Prefix: string; Declare: TToolDeclareProc;
  Run: TToolRunProc; out Err: string): Boolean;
var
  I: Integer;
begin
  Err := '';
  Result := False;
  if not ValidSourcePrefix(Prefix) then
  begin
    Err := 'a tool source prefix must match ^[a-z][a-z0-9_]*__$ : ' + Prefix;
    Exit;
  end;
  if (Declare = nil) or (Run = nil) then
  begin
    Err := 'a tool source needs both a declare and a run procedure';
    Exit;
  end;
  if Length(ToolSources) >= MaxToolSources then
  begin
    Err := 'no room for another tool source';
    Exit;
  end;
  { Overlap either way, not just equality: if one prefix could be the start of
    another, two sources could match one name and dispatch would depend on
    registration order.  Refusing the overlap is what makes the scan below
    order-independent. }
  for I := 0 to High(ToolSources) do
    if (Copy(Prefix, 1, Length(ToolSources[I].Prefix)) = ToolSources[I].Prefix) or
       (Copy(ToolSources[I].Prefix, 1, Length(Prefix)) = Prefix) then
    begin
      Err := 'tool source prefix overlaps ' + ToolSources[I].Prefix + ': ' + Prefix;
      Exit;
    end;
  SetLength(ToolSources, Length(ToolSources) + 1);
  ToolSources[High(ToolSources)].Prefix := Prefix;
  ToolSources[High(ToolSources)].Declare := Declare;
  ToolSources[High(ToolSources)].Run := Run;
  Result := True;
end;

procedure ClearToolSources;
begin
  SetLength(ToolSources, 0);
end;

function ToolSourceCount: Integer;
begin
  Result := Length(ToolSources);
end;

function ToolSourcePrefix(I: Integer): string;
begin
  if (I < 0) or (I > High(ToolSources)) then Exit('');
  Result := ToolSources[I].Prefix;
end;

{ Finds the one source that owns Name and runs it.  The try/except is the
  single most important line in the registry: uAgent's tool loop does not
  catch, so an exception escaping a third-party handler would skip the
  tool_result and leave a transcript the API refuses. }
function DispatchToolSource(const Name: string; Input: TJson; Ask: TAskProc;
  out IsError: Boolean; out Output: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  IsError := False;
  Output := '';
  for I := 0 to High(ToolSources) do
    if Copy(Name, 1, Length(ToolSources[I].Prefix)) = ToolSources[I].Prefix then
    begin
      Result := True;
      try
        Output := ToolSources[I].Run(Name, Input, Ask, IsError);
      except
        on E: Exception do
        begin
          IsError := True;
          Output := 'tool source failed: ' + E.Message;
        end;
      end;
      Exit;
    end;
end;

function CountBuiltinTools(Arr: TJson): Integer;
var
  I, J: Integer;
  N: string;
  FromSource: Boolean;
begin
  Result := 0;
  if (Arr = nil) or (Arr.Kind <> jkArr) then Exit;
  for I := 0 to Arr.Count - 1 do
  begin
    N := Arr.Item(I).Str('name');
    FromSource := False;
    for J := 0 to High(ToolSources) do
      if Copy(N, 1, Length(ToolSources[J].Prefix)) = ToolSources[J].Prefix then
        FromSource := True;
    if not FromSource then Inc(Result);
  end;
end;

{ --------------------------------------------------------- the trust store -- }

type
  TTrustEntry = record
    Key, Fingerprint: string;
  end;

var
  Trusted: array of TTrustEntry;

function TrustedFingerprint(const Key: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Trusted) do
    if Trusted[I].Key = Key then Exit(Trusted[I].Fingerprint);
end;

procedure RecordTrust(const Key, Fingerprint: string);
var
  I: Integer;
begin
  if (Key = '') or (Fingerprint = '') then Exit;
  for I := 0 to High(Trusted) do
    if Trusted[I].Key = Key then
    begin
      Trusted[I].Fingerprint := Fingerprint;
      Exit;
    end;
  SetLength(Trusted, Length(Trusted) + 1);
  Trusted[High(Trusted)].Key := Key;
  Trusted[High(Trusted)].Fingerprint := Fingerprint;
end;

procedure ClearTrust;
begin
  SetLength(Trusted, 0);
end;

{ ---------------------------------------------------------- changed files -- }

var
  ChangedList: array of string;

function ChangedFiles: TStringArray;
var
  I: Integer;
begin
  SetLength(Result, Length(ChangedList));
  for I := 0 to High(ChangedList) do
    Result[I] := ChangedList[I];
end;

procedure NoteChangedFile(const RelPath: string);
var
  I: Integer;
begin
  if RelPath = '' then Exit;
  for I := 0 to High(ChangedList) do
    if CompareText(ChangedList[I], RelPath) = 0 then Exit;
  SetLength(ChangedList, Length(ChangedList) + 1);
  ChangedList[High(ChangedList)] := RelPath;
end;

procedure ClearChangedFiles;
begin
  SetLength(ChangedList, 0);
end;

{ ------------------------------------------------------------------ todos -- }

var
  TodoList: array of string;

function CurrentTodos: TStringArray;
var
  I: Integer;
begin
  SetLength(Result, Length(TodoList));
  for I := 0 to High(TodoList) do
    Result[I] := TodoList[I];
end;

procedure ClearTodos;
begin
  SetLength(TodoList, 0);
end;

{ -------------------------------------------------------------- subagents -- }

const
  AgentsDirName = 'agents';

var
  { Not a Boolean, because Enter/Leave must nest correctly even though the
    cap only ever permits one level; a counter cannot get out of step with
    itself the way a flag and a cap can. }
  SubDepth: Integer = 0;

function EnterSubagent: Boolean;
begin
  Result := SubDepth < MaxSubagentDepth;
  if Result then Inc(SubDepth);
end;

procedure LeaveSubagent;
begin
  if SubDepth > 0 then Dec(SubDepth);
end;

function SubagentDepth: Integer;
begin
  Result := SubDepth;
end;

{ The whole of what a subagent may do.  Three names, in one place, so a
  reviewer can verify the read-only claim by reading this line rather than by
  trusting six save-and-restore pairs elsewhere: nothing on this list touches
  the todo list, the changed-file list, the bash prefix table or the rewind
  snapshots, which is why none of that module state needs scoping. }
function IsSubagentTool(const Name: string): Boolean;
begin
  Result := (Name = 'read_file') or (Name = 'list_dir') or (Name = 'search');
end;

function AgentsDir: string;
begin
  Result := IncludeTrailingPathDelimiter(NormalizeRoot) + StateDirName +
    PathDelim + AgentsDirName + PathDelim;
end;

function SubagentTypes: TStringArray;
var
  R: TSearchRec;
  L: TStringList;
  I: Integer;
begin
  SetLength(Result, 0);
  L := TStringList.Create;
  try
    if FindFirst(AgentsDir + '*.md', faAnyFile, R) = 0 then
    begin
      repeat
        if (R.Attr and faDirectory) <> 0 then Continue;
        L.Add(ChangeFileExt(R.Name, ''));
      until FindNext(R) <> 0;
      SysUtils.FindClose(R);
    end;
    L.Sort;
    SetLength(Result, L.Count);
    for I := 0 to L.Count - 1 do
      Result[I] := L[I];
  finally
    L.Free;
  end;
end;

{ The one place in this unit that opens a file without SafePath, and it has
  to stay that way deliberately: SafePath refuses everything under the state
  directory by design, and the agent definitions live there.  The guard
  instead is that only the bare name comes from the model and it is filtered
  for the path-bearing characters exactly as the custom-command loader
  filters command names, so the directory part is constructed and can never
  be walked out of. }
function LoadAgentDefinition(const AgentType: string;
  out Text, Err: string): Boolean;
var
  Name, Path, List: string;
  I: Integer;
  Types: TStringArray;
  L: TStringList;
begin
  Text := '';
  Err := '';
  Name := Trim(AgentType);
  { No type named is the general-purpose subagent, not a mistake. }
  if Name = '' then Exit(True);

  for I := 1 to Length(Name) do
    if (Name[I] in ['\', '/', ':', '.']) or (Name[I] < ' ') then
    begin
      Err := 'bad agent type: ' + AgentType;
      Exit(False);
    end;

  Path := AgentsDir + Name + '.md';
  if not FileExists(Path) then
  begin
    Types := SubagentTypes;
    List := '';
    for I := 0 to High(Types) do
    begin
      if List <> '' then List := List + ', ';
      List := List + Types[I];
    end;
    if List = '' then
      Err := 'unknown agent type: ' + Name + ' (none are defined; put one in ' +
        StateDirName + PathDelim + AgentsDirName + PathDelim + '<name>.md)'
    else
      Err := 'unknown agent type: ' + Name + ' (available: ' + List + ')';
    Exit(False);
  end;

  L := TStringList.Create;
  try
    try
      L.LoadFromFile(Path);
      Text := L.Text;
    except
      on E: Exception do
      begin
        Err := 'cannot read agent type ' + Name + ': ' + E.Message;
        Exit(False);
      end;
    end;
  finally
    L.Free;
  end;
  { This text becomes a system prompt on a nested request, so one bad byte
    costs the whole subagent call - and it would surface only as a mysterious
    tool failure, with nothing pointing at the file. }
  if not IsValidUtf8(Text) then Text := OemToUtf8(Text);
  Text := Clip(Text);
  Result := True;
end;

{ -------------------------------------------------------------- snapshots -- }

type
  TSnapshot = record
    Turn: Integer;
    Full: string;        { absolute path }
    Existed: Boolean;    { False: the file was created, restore = delete }
    Text: string;        { prior contents when Existed }
  end;

var
  Snapshots: array of TSnapshot;
  CurrentTurn: Integer = 0;

procedure BeginTurn(TurnNo: Integer);
begin
  CurrentTurn := TurnNo;
end;

procedure ClearSnapshots;
begin
  SetLength(Snapshots, 0);
end;

function SnapshotCount: Integer;
begin
  Result := Length(Snapshots);
end;

{ Captures Full's state before its first change this turn.  Later changes in
  the same turn keep the first snapshot: rewinding lands at the turn start,
  not midway through it.  Snapshot bytes live in memory; a 400 KB cap keeps
  a huge generated file from bloating the process, at the cost of that file
  not being rewindable - noted at restore time. }
procedure SnapshotFile(const Full: string);
var
  I: Integer;
  S: TSnapshot;
  F: TFileStream;
begin
  { One snapshot per file per turn.  Earlier turns keep theirs: a file
    touched in turn 2 and again in turn 5 must be restorable to either. }
  for I := 0 to High(Snapshots) do
    if (Snapshots[I].Turn = CurrentTurn) and
       (CompareText(Snapshots[I].Full, Full) = 0) then Exit;

  S.Turn := CurrentTurn;
  S.Full := Full;
  S.Existed := FileExists(Full);
  S.Text := '';
  if S.Existed then
  begin
    try
      F := TFileStream.Create(Full, fmOpenRead or fmShareDenyNone);
      try
        if F.Size > MaxReadBytes then Exit;   { too big to hold; not rewindable }
        SetLength(S.Text, F.Size);
        if F.Size > 0 then F.ReadBuffer(S.Text[1], F.Size);
      finally
        F.Free;
      end;
    except
      Exit;   { unreadable now means unrestorable later; skip }
    end;
  end;
  SetLength(Snapshots, Length(Snapshots) + 1);
  Snapshots[High(Snapshots)] := S;
end;

function RestoreFilesSince(TurnNo: Integer; out Notes: string): Integer;
var
  I, Kept: Integer;
  Err: string;
begin
  Result := 0;
  Notes := '';
  { Newest first, so when a file has snapshots in several turns at or after
    TurnNo, the oldest one writes last and wins - the state the file had
    when TurnNo began. }
  for I := High(Snapshots) downto 0 do
  begin
    if Snapshots[I].Turn < TurnNo then Continue;
    if Snapshots[I].Existed then
    begin
      if SaveFileText(Snapshots[I].Full, Snapshots[I].Text, Err) then
      begin
        Inc(Result);
        Notes := Notes + 'restored ' + Rel(Snapshots[I].Full) + #10;
      end
      else
        Notes := Notes + 'could not restore ' + Rel(Snapshots[I].Full) +
          ': ' + Err + #10;
    end
    else
    begin
      if not FileExists(Snapshots[I].Full) or
         SysUtils.DeleteFile(Snapshots[I].Full) then
      begin
        Inc(Result);
        Notes := Notes + 'removed ' + Rel(Snapshots[I].Full) +
          ' (created that turn)'#10;
      end
      else
        Notes := Notes + 'could not remove ' + Rel(Snapshots[I].Full) + #10;
    end;
  end;

  { Forget what was restored; earlier turns keep their snapshots so a
    second, deeper rewind still works. }
  Kept := 0;
  for I := 0 to High(Snapshots) do
    if Snapshots[I].Turn < TurnNo then
    begin
      Snapshots[Kept] := Snapshots[I];
      Inc(Kept);
    end;
  SetLength(Snapshots, Kept);
end;

{ ------------------------------------------------- permission persistence -- }

{ The file is JSON: {"allow_edits":bool,"allow_bash":bool,"allow_fetch":bool,
  "bash_programs":["git","build",...],"trusted":{"mcp:github":"3f9a1c04"}}.
  Deliberately not the transcript format and deliberately tiny - it is
  user-editable state, and someone deleting a line from it must be able to
  predict what that does.  Deleting a "trusted" entry means being asked about
  that program again, which is the most useful thing a line in a permissions
  file can mean.

  AllowAllMcp is deliberately absent: it is set only by /yolo, and /yolo is
  never saved at all. }
procedure LoadPermissions(const Path: string);
var
  F: TFileStream;
  Text: string;
  Root, Progs: TJson;
  I: Integer;
begin
  if not FileExists(Path) then Exit;
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Text, F.Size);
      if F.Size > 0 then F.ReadBuffer(Text[1], F.Size);
    finally
      F.Free;
    end;
  except
    Exit;
  end;
  Root := JsonParse(Text);
  if Root = nil then Exit;
  try
    { Approvals only widen from the file, never narrow: a session that
      already granted something keeps it regardless of what is on disk. }
    if Root.Bool('allow_edits') then AllowAllEdits := True;
    if Root.Bool('allow_bash') then AllowAllBash := True;
    if Root.Bool('allow_fetch') then AllowAllFetch := True;
    Progs := Root.Find('bash_programs');
    if (Progs <> nil) and (Progs.Kind = jkArr) then
      for I := 0 to Progs.Count - 1 do
        AllowBashPrefix(Progs.Item(I).AsString);
    { Same only-widen rule: a fingerprint on disk can add a standing yes but
      an absent one cannot take back a yes given this session. }
    Progs := Root.Find('trusted');
    if (Progs <> nil) and (Progs.Kind = jkObj) then
      for I := 0 to Progs.Count - 1 do
        RecordTrust(Progs.Key(I), Progs.Item(I).AsString);
  finally
    Root.Free;
  end;
end;

procedure SavePermissions(const Path: string);
var
  Root, Progs: TJson;
  Text: string;
  F: TFileStream;
  I: Integer;
begin
  Root := TJson.NewObj;
  try
    Root.AddBool('allow_edits', AllowAllEdits);
    Root.AddBool('allow_bash', AllowAllBash);
    Root.AddBool('allow_fetch', AllowAllFetch);
    Progs := TJson.NewArr;
    for I := 0 to High(BashPrefixes) do
      Progs.Push(TJson.NewStr(BashPrefixes[I]));
    Root.Add('bash_programs', Progs);
    Progs := TJson.NewObj;
    for I := 0 to High(Trusted) do
      Progs.AddStr(Trusted[I].Key, Trusted[I].Fingerprint);
    Root.Add('trusted', Progs);
    Text := Root.ToJson;
  finally
    Root.Free;
  end;
  try
    F := TFileStream.Create(Path, fmCreate);
    try
      if Text <> '' then F.WriteBuffer(Text[1], Length(Text));
    finally
      F.Free;
    end;
  except
    { Nothing: persistence is a convenience. }
  end;
end;

{ ------------------------------------------------------------------ schema -- }

function StrProp(const Desc: string): TJson;
begin
  Result := TJson.NewObj;
  Result.AddStr('type', 'string');
  Result.AddStr('description', Desc);
end;

function BoolProp(const Desc: string): TJson;
begin
  Result := TJson.NewObj;
  Result.AddStr('type', 'boolean');
  Result.AddStr('description', Desc);
end;

function MakeTool(const Name, Desc: string; Props: TJson;
  const Required: array of string): TJson;
var
  Schema, Req: TJson;
  I: Integer;
begin
  Schema := TJson.NewObj;
  Schema.AddStr('type', 'object');
  Schema.Add('properties', Props);
  Req := TJson.NewArr;
  for I := Low(Required) to High(Required) do
    Req.Push(TJson.NewStr(Required[I]));
  Schema.Add('required', Req);

  Result := TJson.NewObj;
  Result.AddStr('name', Name);
  Result.AddStr('description', Desc);
  Result.Add('input_schema', Schema);
end;

{ Named types are listed in the description rather than as an enum, because a
  wrong name is already a clean tool error naming the alternatives, and an
  enum would have to be rebuilt every time the user drops a file in. }
function SubagentTypeDescription: string;
var
  T: TStringArray;
  I: Integer;
begin
  Result := 'Optional named agent type to brief the subagent with.';
  T := SubagentTypes;
  if Length(T) = 0 then Exit;
  Result := Result + ' Available:';
  for I := 0 to High(T) do
  begin
    if I > 0 then Result := Result + ',';
    Result := Result + ' ' + T[I];
  end;
  Result := Result + '.';
end;

function ToolsSchema: TJson;
var
  P, Decl: TJson;
  I, J: Integer;
begin
  Result := TJson.NewArr;

  P := TJson.NewObj;
  P.Add('path', StrProp('File path, relative to the session root.'));
  Result.Push(MakeTool('read_file',
    'Read a text file. Output is line-numbered so you can cite line numbers. ' +
    'A .ipynb file comes back instead as numbered notebook cells, with each ' +
    'output summarised by type and size rather than dumped.',
    P, ['path']));

  P := TJson.NewObj;
  P.Add('path', StrProp('Directory, relative to the session root. Default ".".'));
  P.Add('recursive', BoolProp('Descend into subdirectories (depth 4 unless ' +
    'depth is given).'));
  { Hand-built, like the edits and todos arrays: there is no IntProp helper,
    and one more of those for two call sites earns less than it costs. }
  P.Add('depth', TJson.NewObj);
  with P.Find('depth') do
  begin
    AddStr('type', 'integer');
    AddStr('description', 'How many levels to descend, 1-12. Overrides ' +
      'recursive. Default 4 when recursive, 0 otherwise.');
  end;
  Result.Push(MakeTool('list_dir', 'List a directory.', P, []));

  P := TJson.NewObj;
  P.Add('pattern', StrProp('Text to find. A case-insensitive substring ' +
    'unless regex is true.'));
  P.Add('glob', StrProp('Optional filename filter, e.g. ".pas" or "test".'));
  P.Add('regex', BoolProp('Treat pattern as a regular expression: . * + ? ' +
    'repeat counts, [a-z], \d \w \s \b ^ $ | and (groups). ASCII byte ' +
    'semantics; no backreferences or lookaround.'));
  P.Add('case_sensitive', BoolProp('Match case exactly. Default false.'));
  P.Add('depth', TJson.NewObj);
  with P.Find('depth') do
  begin
    AddStr('type', 'integer');
    AddStr('description', 'How many directory levels to search, 1-12. ' +
      'Default 8.');
  end;
  Result.Push(MakeTool('search',
    'Search file contents under the session root. Returns path:line: text. ' +
    'Set regex for pattern syntax.',
    P, ['pattern']));

  { The cut is made here rather than by filtering afterwards so a subagent is
    never told about a tool it would be refused: an offered tool that always
    fails wastes a round and reads to the model as a broken machine.  The
    three above are the whole read-only set, which is why they were moved to
    the top - three paragraphs relocated beats eight indented. }
  if SubDepth > 0 then Exit;

  P := TJson.NewObj;
  P.Add('path', StrProp('File path, relative to the session root.'));
  P.Add('content', StrProp('Full new contents of the file.'));
  Result.Push(MakeTool('write_file',
    'Create a file or replace its entire contents. Requires user approval.',
    P, ['path', 'content']));

  P := TJson.NewObj;
  P.Add('path', StrProp('File path, relative to the session root.'));
  P.Add('old_text', StrProp('Exact text to replace. Must occur exactly once.'));
  P.Add('new_text', StrProp('Replacement text.'));
  P.Add('edits', TJson.NewObj);
  with P.Find('edits') do
  begin
    AddStr('type', 'array');
    AddStr('description', 'Several replacements applied together: each item ' +
      'is {old_text, new_text}. Use this instead of separate calls when one ' +
      'change spans several places in the file. All must match, or none are ' +
      'applied.');
  end;
  Result.Push(MakeTool('edit_file',
    'Replace exact snippets in a file: one via old_text/new_text, or several ' +
    'at once via edits. Prefer this over write_file for changes to existing ' +
    'files. Requires user approval.',
    P, ['path']));

  P := TJson.NewObj;
  P.Add('command', StrProp('Command line, run through cmd.exe /C.'));
  P.Add('run_in_background', BoolProp('Start the command detached and return ' +
    'a job id immediately instead of waiting. Use it for servers, watchers ' +
    'and builds that outlive one tool call; poll with bash_output and stop ' +
    'with kill_bash. Foreground commands time out after 120 s, background ' +
    'ones do not.'));
  Result.Push(MakeTool('bash',
    'Run a shell command in the session root and return its output. ' +
    'Use it to build, run tests, or inspect the system. Set ' +
    'run_in_background for anything that should keep running after this ' +
    'call returns. Requires user approval.',
    P, ['command']));

  P := TJson.NewObj;
  P.Add('job_id', StrProp('The job id returned when the command was started. ' +
    'Omit it to list every background job.'));
  Result.Push(MakeTool('bash_output',
    'Read the output a background command has produced since your last ' +
    'read, plus whether it is still running and its exit code once it ' +
    'finishes.',
    P, []));

  P := TJson.NewObj;
  P.Add('job_id', StrProp('The job id to stop.'));
  Result.Push(MakeTool('kill_bash',
    'Stop a background command and everything it started, and return ' +
    'whatever output it had not yet handed over.',
    P, ['job_id']));

  P := TJson.NewObj;
  P.Add('url', StrProp('The https:// URL to fetch.'));
  Result.Push(MakeTool('fetch',
    'Fetch a URL over HTTPS and return the response body as text. ' +
    'Use it to read documentation, APIs, or reference pages. ' +
    'Requires user approval.',
    P, ['url']));

  P := TJson.NewObj;
  P.Add('todos', TJson.NewObj);
  with P.Find('todos') do
  begin
    AddStr('type', 'array');
    AddStr('description', 'The full task list, replacing the previous one. ' +
      'Each item: {"content": string, "status": "pending"|"in_progress"|' +
      '"completed"}. Keep at most one item in_progress.');
  end;
  Result.Push(MakeTool('todo_write',
    'Maintain a visible task list for multi-step work. Call it when ' +
    'starting a task with several steps, and again as each step starts and ' +
    'finishes, so the user can follow the plan. Send the whole list each ' +
    'time.',
    P, ['todos']));

  P := TJson.NewObj;
  P.Add('path', StrProp('Notebook path (.ipynb), relative to the session root.'));
  P.Add('cell', TJson.NewObj);
  with P.Find('cell') do
  begin
    AddStr('type', 'integer');
    AddStr('description', 'The 0-based cell number read_file showed. For ' +
      'insert, the index the new cell takes.');
  end;
  P.Add('edit_mode', StrProp('One of "replace", "insert" or "delete".'));
  P.Add('source', StrProp('The cell''s new source, as plain text. Required ' +
    'by replace and insert.'));
  P.Add('cell_type', StrProp('"code", "markdown" or "raw" for insert. ' +
    'Default "code".'));
  Result.Push(MakeTool('notebook_edit',
    'Replace, insert or delete one cell of a Jupyter notebook. Use this ' +
    'rather than edit_file for .ipynb files: edit_file works on the file''s ' +
    'JSON text, while this works on the cells read_file shows you. Outputs ' +
    'and execution counts of the cell survive a replace. Requires user ' +
    'approval, like any other file change.',
    P, ['path', 'cell', 'edit_mode']));

  { Only offered when a runner has been installed.  A build with no uAgent
    linked in - a test suite, say - would otherwise advertise a tool whose
    every call fails. }
  if Assigned(SubagentRunner) then
  begin
    P := TJson.NewObj;
    P.Add('prompt', StrProp('The whole job, self-contained: the subagent ' +
      'sees none of this conversation. Say what to investigate and what to ' +
      'report back.'));
    P.Add('agent_type', StrProp(SubagentTypeDescription));
    Result.Push(MakeTool('task',
      'Hand a self-contained investigation to a read-only subagent and get ' +
      'back its written answer. The subagent has its own conversation and ' +
      'can only read: read_file, list_dir and search. Use it when finding ' +
      'something would otherwise fill this conversation with intermediate ' +
      'reading - "which unit owns X", "where is Y configured". It cannot ' +
      'change anything, run commands, or start a subagent of its own.',
      P, ['prompt']));
  end;

  { Registered sources last, and below the read-only cut above rather than
    guarded by a check of their own: the cut is an Exit, so nothing written
    after it can ever run inside a subagent, whoever writes it.  A tool that
    came from outside this program is therefore invisible to a subagent by
    construction.

    Take rather than Item: Push adopts what it is given, so reading a child out
    and pushing it would leave two owners and -gh would find the second free.
    Take detaches by substituting a null in place, which is why this walks the
    indices once rather than repeatedly taking index 0 - the array does not
    shrink, and a "while Count > 0" would never end.  Freeing the wrapper
    disposes of the nulls left behind. }
  for I := 0 to High(ToolSources) do
  begin
    Decl := ToolSources[I].Declare();
    if Decl = nil then Continue;
    try
      if Decl.Kind = jkArr then
        for J := 0 to Decl.Count - 1 do
          Result.Push(Decl.Take(J));
    finally
      Decl.Free;
    end;
  end;
end;

{ Unlike everything in ToolsSchema this carries no input_schema: a server-side
  tool's arguments are the API's business, not ours.  max_uses caps how many
  searches one turn may run, which is the only spend control available for a
  tool the client never executes. }
function WebSearchToolDef: TJson;
begin
  Result := TJson.NewObj;
  Result.AddStr('type', WebSearchToolType);
  Result.AddStr('name', 'web_search');
  Result.AddNum('max_uses', 5);
end;

{ --------------------------------------------------------------- execution -- }

{ The effective walk depth for a tool call.  The value arrives as a Double, so
  it is range-checked before it is rounded: Round(1e300) raises, and a model
  can send anything.  A silly depth clamps rather than failing the call - a
  clamp is a more useful answer than a refused tool. }
function WalkDepth(Input: TJson; DefaultDepth: Integer): Integer;
var
  D: Double;
begin
  if (Input = nil) or (Input.Find('depth') = nil) then Exit(DefaultDepth);
  D := Input.Num('depth', DefaultDepth);
  if D >= MaxWalkDepth then Exit(MaxWalkDepth);
  { Written as a positive test so a NaN lands here rather than in Round. }
  if not (D > 1) then Exit(1);
  Result := Round(D);
end;

{ The cell argument of notebook_edit, as an Integer that cannot raise.  Models
  do send "2" for an integer field, so a string that parses is accepted; a
  value too large to round is clamped to something NotebookApply will refuse
  by name rather than crashing on the way in.  -1 means "not supplied", which
  is out of range for every mode and so reports itself. }
function CellIndex(Input: TJson): Integer;
var
  V: TJson;
  D: Double;
  N: Int64;
begin
  Result := -1;
  if Input = nil then Exit;
  V := Input.Find('cell');
  if V = nil then Exit;
  if V.Kind = jkStr then
  begin
    if TryStrToInt64(Trim(V.AsString), N) then
    begin
      if N > MaxInt then Exit(MaxInt);
      if N < -MaxInt then Exit(-MaxInt);
      Result := N;
    end;
    Exit;
  end;
  if V.Kind <> jkNum then Exit;
  D := V.AsNumber;
  if D >= MaxInt then Exit(MaxInt);
  { Written as a positive test so a NaN lands here, not in Round. }
  if not (D > -MaxInt) then Exit(-MaxInt);
  Result := Round(D);
end;

function DescribeTool(const Name: string; Input: TJson): string;
var
  S: string;
begin
  if Input = nil then Exit(Name);
  if Name = 'read_file' then
    Result := 'read ' + Input.Str('path')
  else if Name = 'write_file' then
    Result := Format('write %s (%d bytes)',
      [Input.Str('path'), Length(Input.Str('content'))])
  else if Name = 'edit_file' then
    Result := 'edit ' + Input.Str('path')
  else if Name = 'list_dir' then
  begin
    Result := 'list ' + Input.Str('path', '.');
    if Input.Find('depth') <> nil then
      Result := Result + Format(' (depth %d)', [WalkDepth(Input, 0)]);
  end
  { Which engine ran is worth a character in the transcript: /pat/ and "pat"
    mean different searches, and a user reading the log should not have to
    guess which one the model asked for. }
  else if Name = 'search' then
  begin
    if Input.Bool('regex') then
      Result := Format('search /%s/', [Input.Str('pattern')])
    else
      Result := Format('search "%s"', [Input.Str('pattern')]);
  end
  else if Name = 'bash' then
  begin
    S := Input.Str('command');
    if Length(S) > 120 then S := Copy(S, 1, 117) + '...';
    Result := '$ ' + S;
    { Said plainly in the prompt title, because "approve this command" and
      "approve this command and let it outlive the answer" are different
      questions and the user is only being asked once. }
    if Input.Bool('run_in_background') then
      Result := Result + '  [background]';
  end
  else if Name = 'bash_output' then
  begin
    if Input.Str('job_id') = '' then
      Result := 'list background jobs'
    else
      Result := 'read output of ' + Input.Str('job_id');
  end
  else if Name = 'kill_bash' then
    Result := 'stop ' + Input.Str('job_id')
  else if Name = 'fetch' then
    Result := 'fetch ' + Input.Str('url')
  { Both the mode and the cell number, because they are the whole of what the
    user is being asked to approve: "delete cell 3" and "replace cell 3" are
    very different answers to the same prompt title. }
  else if Name = 'notebook_edit' then
    Result := Format('%s cell %d of %s',
      [Input.Str('edit_mode', '?'), CellIndex(Input), Input.Str('path')])
  else if Name = 'todo_write' then
  begin
    if (Input.Find('todos') <> nil) then
      Result := Format('update todos (%d items)', [Input.Find('todos').Count])
    else
      Result := 'update todos';
  end
  { The prompt's first line is the whole of what the user can be told about a
    conversation they will never see, so it is what goes in the transcript. }
  else if Name = 'task' then
  begin
    S := Trim(Input.Str('prompt'));
    if Pos(#10, S) > 0 then S := Copy(S, 1, Pos(#10, S) - 1);
    if Length(S) > 60 then S := Copy(S, 1, 57) + '...';
    Result := 'task: ' + S;
    if Input.Str('agent_type') <> '' then
      Result := Result + ' [' + Input.Str('agent_type') + ']';
  end
  else
    Result := Name;
end;

{ Applies the edit(s) described by Input to Text in place.  One hunk comes as
  old_text/new_text, several as an edits array; the two can combine.  Every
  hunk is checked - present, unambiguous - before any is applied: an edit
  that half-lands leaves a file that neither the user nor the model expected
  to exist.  Later hunks match against the text as earlier ones changed it,
  in array order. }
function ApplyEdits(Input: TJson; var Text: string; const RelName: string;
  out Err: string): Boolean;
var
  Edits: TJson;
  I, At, Second, Count: Integer;
  Old, New, Work: string;

  function OneHunk(const O, N: string; Which: Integer): Boolean;
  begin
    Result := False;
    if O = '' then
    begin
      Err := Format('edit %d: old_text must not be empty', [Which]);
      Exit;
    end;
    At := Pos(O, Work);
    if At = 0 then
    begin
      Err := Format('edit %d: old_text was not found in %s', [Which, RelName]);
      Exit;
    end;
    Second := Pos(O, Work, At + 1);
    if Second > 0 then
    begin
      Err := Format('edit %d: old_text occurs more than once; include more context',
        [Which]);
      Exit;
    end;
    Work := Copy(Work, 1, At - 1) + N + Copy(Work, At + Length(O), MaxInt);
    Result := True;
  end;

begin
  Result := False;
  Err := '';
  Work := Text;
  Count := 0;

  { The single-hunk form, when present, runs first. }
  Old := Input.Str('old_text');
  New := Input.Str('new_text');
  if Old <> '' then
  begin
    if not OneHunk(Old, New, 1) then Exit;
    Inc(Count);
  end;

  Edits := Input.Find('edits');
  if (Edits <> nil) and (Edits.Kind = jkArr) then
    for I := 0 to Edits.Count - 1 do
    begin
      if not OneHunk(Edits.Item(I).Str('old_text'),
                     Edits.Item(I).Str('new_text'), Count + 1) then Exit;
      Inc(Count);
    end;

  if Count = 0 then
  begin
    Err := 'no edits given: supply old_text/new_text or an edits array';
    Exit;
  end;
  Text := Work;
  Result := True;
end;

function Permit(const Name, Detail: string; Ask: TAskProc): Boolean;
var
  IsBash, IsFetch, IsMcp: Boolean;
  A: TPermission;
begin
  IsBash := Name = 'bash';
  IsFetch := Name = 'fetch';
  IsMcp := Copy(Name, 1, Length(McpNamePrefix)) = McpNamePrefix;

  if IsBash and AllowAllBash then Exit(True);
  if IsFetch and AllowAllFetch then Exit(True);
  if IsMcp and AllowAllMcp then Exit(True);
  { The edits class is the catch-all, so every new class has to be excluded
    here as well as tested above.  A class that forgets this line silently
    inherits AllowAllEdits, which is the same /yolo hole the subagent comment
    in RunTool warns about: an approval the user gave for file edits would
    quietly cover running a third-party program's tools. }
  if (not IsBash) and (not IsFetch) and (not IsMcp) and AllowAllEdits then
    Exit(True);

  { A standing yes recorded against the server's actual command line. }
  if IsMcp and McpCallApproved(Name) then Exit(True);

  if Ask = nil then Exit(False);

  A := Ask(Name, Detail);
  case A of
    pmAllowOnce: Result := True;
    pmAllowAlways:
      begin
        if IsBash then AllowAllBash := True
        else if IsFetch then AllowAllFetch := True
        { Per server, not a blanket flag, and keyed to the command line - the
          same shape as AllowBashPrefix recording a program. }
        else if IsMcp then AllowMcpServer(Name)
        else AllowAllEdits := True;
        Result := True;
      end;
  else
    Result := False;
  end;
end;

{ The bash gate.  "Always" for a shell command approves its program, not
  every future command: the user who said always to "git status" meant git,
  and quietly extending that to "del /s" is how trust gets spent.  /yolo
  still approves everything through AllowAllBash. }
function PermitBash(const Cmd, Detail: string; Ask: TAskProc): Boolean;
var
  A: TPermission;
  P: string;
begin
  if AllowAllBash then Exit(True);
  if BashPrefixAllowed(Cmd) then Exit(True);
  if Ask = nil then Exit(False);

  P := BashPrefix(Cmd);
  A := Ask('bash', Detail);
  case A of
    pmAllowOnce: Result := True;
    pmAllowAlways:
      begin
        { A chained command has no prefix; "always" for one degrades to
          this-once, since there is nothing safe to remember it by -
          silently widening to all commands would spend trust the user
          never gave. }
        if P <> '' then AllowBashPrefix(Cmd);
        Result := True;
      end;
  else
    Result := False;
  end;
end;

{ Builds the diff a change would produce.  Reads the file as it stands now,
  so the preview reflects what is really on disk rather than what the model
  believed was there. }
function ChangePreview(const Name: string; Input: TJson): string;
var
  Full, Err, Text, Note, Updated, OldView, NewView, Canon: string;
begin
  Result := '';
  if Input = nil then Exit;

  if Name = 'write_file' then
  begin
    if not SafePath(Input.Str('path'), Full, Err) then Exit;
    if FileExists(Full) then
    begin
      if not LoadFileText(Full, Text, Note) then Exit;
      { A file that is not text has no meaningful line diff, and dumping its
        bytes into a prompt helps nobody. }
      if not IsValidUtf8(Text) then
        Exit(Format('replaces %d bytes of binary content', [Length(Text)]));
    end
    else
    begin
      Text := '';
      Result := '(new file)'#10;
    end;
    Result := Result + DiffSummary(Text, Input.Str('content'), PreviewLines);
  end

  else if Name = 'edit_file' then
  begin
    if not SafePath(Input.Str('path'), Full, Err) then Exit;
    if not FileExists(Full) then Exit;
    if not LoadFileText(Full, Text, Note) then Exit;
    if not IsValidUtf8(Text) then Exit;
    { The same application the execution path uses, so the preview is the
      change that will actually happen - including every hunk of a multi-edit.
      An edit that would be refused previews as nothing, and the refusal
      carries the reason. }
    Updated := Text;
    if not ApplyEdits(Input, Updated, Rel(Full), Err) then Exit;
    Result := DiffSummary(Text, Updated, PreviewLines);
  end

  else if Name = 'notebook_edit' then
  begin
    if not SafePath(Input.Str('path'), Full, Err) then Exit;
    if not FileExists(Full) then Exit;
    if not LoadFileLimited(Full, MaxNotebookBytes, Text, Note) then Exit;
    if not IsValidUtf8(Text) then Exit;
    { The same NotebookApply the execution path runs, so preview and result
      cannot diverge; an edit that would be refused previews as nothing, the
      way a refused edit_file does. }
    if not NotebookApply(Text, CellIndex(Input), Input.Str('edit_mode'),
                         Input.Str('source'), Input.Str('cell_type'),
                         Updated, Err) then Exit;
    { The diff is over the cell view, not the file bytes: the user approves
      the change in the same terms the model proposed it, and base64 output
      data cannot reach the prompt by that route. }
    if not NotebookView(Text, OldView, Err) then Exit;
    if not NotebookView(Updated, NewView, Err) then Exit;
    { What the cell diff cannot show is that the rest of the file is about to
      be rewritten in Jupyter's layout.  That is a real, one-time cost to
      someone's git history, so it is said out loud rather than discovered. }
    if NotebookCanonical(Text, Canon, Err) and (Canon <> Text) then
      Result := '(the file will be rewritten in Jupyter''s standard ' +
        'formatting)'#10;
    Result := Result + DiffSummary(OldView, NewView, PreviewLines);
  end;
end;

function PermitChange(const Name: string; Input: TJson; Ask: TAskProc): Boolean;
var
  Detail, Preview: string;
begin
  Detail := DescribeTool(Name, Input);
  { The diff is only built when someone is actually going to be asked, since
    reading and diffing the file is pure waste under /yolo. }
  if Assigned(Ask) and not (AllowAllEdits or ((Name = 'bash') and AllowAllBash)) then
  begin
    Preview := ChangePreview(Name, Input);
    if Preview <> '' then
      Detail := Detail + #10 + Preview;
  end;
  Result := Permit(Name, Detail, Ask);
end;

{ -------------------------------------------------------- MCP servers -- }

{ The policy half of MCP: which programs a project may run, what their tools
  are called here, what of their output we are willing to forward, and who
  said yes.  The wire itself is uMcp's, which knows none of this. }

type
  TMcpToolRec = record
    Name: string;   { the composed mcp__server__tool the model sees }
    Orig: string;   { what the server calls it, which is what we send back }
    Decl: string;   { the validated declaration, as text }
  end;

  TMcpServerRec = record
    Name, Command, Hash, WorkDir, Transport: string;
    Note, LastErr, ErrLog: string;
    EnvPairs: array of string;
    TimeoutMs: Integer;
    Status: TMcpStatus;
    Approved: Boolean;
    Conn: Integer;
    Skipped: Integer;
    Tools: array of TMcpToolRec;
  end;

var
  McpServers: array of TMcpServerRec;
  { Set by McpDeclare, not incremented by it: the declaration list is rebuilt
    on every request, so a counter would climb with the turn number rather
    than describe the configuration. }
  McpBudgetDropped: Integer = 0;

function McpConfigPath: string;
begin
  Result := IncludeTrailingPathDelimiter(NormalizeRoot) + '.mcp.json';
end;

{ Both of these are under the state directory and therefore both bypass
  SafePath, which refuses everything there by design.  The substitute guard is
  the one AgentsDir uses: the only part that comes from the file is a bare
  name filtered for the path-bearing characters, so the directory part is
  constructed and cannot be walked out of. }
function McpDir: string;
begin
  Result := IncludeTrailingPathDelimiter(NormalizeRoot) + StateDirName +
    PathDelim + 'mcp' + PathDelim;
end;

function McpCachePath: string;
begin
  Result := IncludeTrailingPathDelimiter(NormalizeRoot) + StateDirName +
    PathDelim + 'mcp-cache.json';
end;

function McpFind(const Name: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(McpServers) do
    if CompareText(McpServers[I].Name, Name) = 0 then Exit(I);
end;

function McpServerCount: Integer;
begin
  Result := Length(McpServers);
end;

function McpServerStatus(const Name: string): TMcpStatus;
var
  I: Integer;
begin
  I := McpFind(Name);
  if I < 0 then Exit(mcFailed);
  Result := McpServers[I].Status;
end;

function McpServerToolCount(const Name: string): Integer;
var
  I: Integer;
begin
  I := McpFind(Name);
  if I < 0 then Exit(0);
  Result := Length(McpServers[I].Tools);
end;

function McpStatusWord(S: TMcpStatus): string;
begin
  case S of
    mcPending:     Result := 'pending approval';
    mcDenied:      Result := 'denied';
    mcUnsupported: Result := 'unsupported transport (stdio only)';
    mcCached:      Result := 'cached, connects on first use';
    mcConnected:   Result := 'connected';
    mcDead:        Result := 'dead';
  else
    Result := 'failed to start';
  end;
end;

procedure ClearMcpServers;
var
  I: Integer;
begin
  for I := 0 to High(McpServers) do
    if McpServers[I].Conn >= 0 then uMcp.McpClose(McpServers[I].Conn);
  SetLength(McpServers, 0);
  McpBudgetDropped := 0;
end;

{ ---- variable expansion, name composition, validation ---- }

function McpExpandVars(const S: string): string;
var
  I, J, K: Integer;
  Body, VName, Def: string;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = '$') and (I < Length(S)) and (S[I + 1] = '{') then
    begin
      J := I + 2;
      while (J <= Length(S)) and (S[J] <> '}') do Inc(J);
      if J > Length(S) then
      begin
        { An expansion nobody closed is text.  Refusing the whole file over it
          would turn a typo in one server's arguments into "MCP is broken
          today". }
        Result := Result + Copy(S, I, MaxInt);
        Exit;
      end;
      Body := Copy(S, I + 2, J - I - 2);
      K := Pos(':-', Body);
      if K > 0 then
      begin
        VName := Copy(Body, 1, K - 1);
        Def := Copy(Body, K + 2, MaxInt);
      end
      else
      begin
        VName := Body;
        Def := '';
      end;
      { Qualified: the Windows unit's own GetEnvironmentVariable is the raw
        API and shadows SysUtils' string version in this scope. }
      VName := SysUtils.GetEnvironmentVariable(VName);
      if VName = '' then VName := Def;
      Result := Result + VName;
      I := J + 1;
    end
    else
    begin
      Result := Result + S[I];
      Inc(I);
    end;
  end;
end;

function McpSanitizeSegment(const S: string): string;
var
  I: Integer;
begin
  Result := Trim(S);
  for I := 1 to Length(Result) do
    if not (Result[I] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '-']) then
      Result[I] := '_';
end;

function McpComposeName(const Server, Tool: string): string;
var
  Sv, Tl: string;
  Room: Integer;
begin
  Result := '';
  Sv := McpSanitizeSegment(Server);
  Tl := McpSanitizeSegment(Tool);
  if (Sv = '') or (Tl = '') then Exit;
  { What is left for the server segment once the prefix, the separator and the
    tool's own name are paid for.  The server segment is the one that gives:
    the tool name is what the server advertised and what the user will read in
    an approval prompt, and shortening it would make the model call something
    by a name nobody chose. }
  Room := McpMaxToolNameLen - Length(McpNamePrefix) - 2 - Length(Tl);
  if Room < 1 then Exit;
  if Length(Sv) > Room then Sv := Copy(Sv, 1, Room);
  Result := McpNamePrefix + Sv + '__' + Tl;
end;

{ True when J nests deeper than N.  Asked as a bounded question rather than
  "how deep is it", so a schema built to be deep costs a walk of N and not a
  walk of itself. }
function DeeperThan(J: TJson; N: Integer): Boolean;
var
  I: Integer;
begin
  Result := False;
  if J = nil then Exit;
  if not (J.Kind in [jkArr, jkObj]) then Exit;
  if N <= 0 then Exit(True);
  for I := 0 to J.Count - 1 do
    if DeeperThan(J.Item(I), N - 1) then Exit(True);
end;

function McpValidateTool(Decl: TJson; const Server: string;
  out ComposedName, OrigName, DeclText, Why: string): Boolean;
var
  Schema, Out_, Copy_: TJson;
  Desc: string;
begin
  Result := False;
  ComposedName := '';
  OrigName := '';
  DeclText := '';
  Why := '';

  if (Decl = nil) or (Decl.Kind <> jkObj) then
  begin
    Why := 'not an object';
    Exit;
  end;
  OrigName := Trim(Decl.Str('name'));
  if OrigName = '' then
  begin
    Why := 'no name';
    Exit;
  end;
  ComposedName := McpComposeName(Server, OrigName);
  if ComposedName = '' then
  begin
    Why := 'name too long';
    Exit;
  end;

  Schema := Decl.Find('inputSchema');
  if (Schema = nil) or (Schema.Kind <> jkObj) then
  begin
    Why := 'inputSchema is not an object';
    Exit;
  end;
  { A missing type is filled in; a type that says something else is refused.
    "array" here would be forwarded verbatim into our request body and break
    every turn, not one call. }
  if (Schema.Find('type') <> nil) and (Schema.Str('type') <> 'object') then
  begin
    Why := 'inputSchema type is not object';
    Exit;
  end;
  if DeeperThan(Schema, McpMaxSchemaDepth) then
  begin
    Why := 'schema nests too deeply';
    Exit;
  end;

  Desc := Decl.Str('description');
  if not IsValidUtf8(Desc) then Desc := OemToUtf8(Desc);
  Desc := Utf8Cut(Desc, McpMaxDescBytes);

  { title, outputSchema and annotations are dropped rather than forwarded.
    The spec says a client must treat annotations as untrusted unless the
    server is, and "the user approved running this program" is not the same
    statement as "believe what it says about its own side effects". }
  Out_ := TJson.NewObj;
  try
    Out_.AddStr('name', ComposedName);
    Out_.AddStr('description', Desc);
    Copy_ := JsonParse(Schema.ToJson);
    if Copy_ = nil then
    begin
      Why := 'schema does not round-trip';
      Exit;
    end;
    if Copy_.Find('type') = nil then Copy_.AddStr('type', 'object');
    Out_.Add('input_schema', Copy_);
    DeclText := Out_.ToJson;
  finally
    Out_.Free;
  end;

  if not IsValidUtf8(DeclText) then
  begin
    DeclText := OemToUtf8(DeclText);
    if not IsValidUtf8(DeclText) then
    begin
      Why := 'not valid UTF-8';
      DeclText := '';
      Exit;
    end;
  end;
  { Rejected, not cut.  A truncated schema does not parse, and one that did
    would be a lie the model acts on every turn for the rest of the session. }
  if Length(DeclText) > McpMaxSchemaBytes then
  begin
    Why := 'schema too large';
    DeclText := '';
    Exit;
  end;
  Result := True;
end;

{ ---- approvals ---- }

function Fnv1a(const S: string; Seed: QWord): QWord;
var
  I: Integer;
begin
  Result := Seed;
  for I := 1 to Length(S) do
  begin
    Result := Result xor QWord(Byte(S[I]));
    Result := Result * QWord($100000001B3);
  end;
end;

function McpCommandHash(const Cmd: string;
  const Args, EnvKeys: array of string): string;
var
  H: QWord;
  L: TStringList;
  I: Integer;
begin
  H := Fnv1a(Cmd, QWord($CBF29CE484222325));
  H := Fnv1a(#0, H);
  for I := Low(Args) to High(Args) do
  begin
    H := Fnv1a(Args[I], H);
    H := Fnv1a(#0, H);
  end;
  H := Fnv1a(#0, H);
  { Sorted, because the order two variables happen to appear in a JSON object
    says nothing about what will run.  The arguments above are deliberately
    not sorted, because their order is exactly what will run. }
  L := TStringList.Create;
  try
    for I := Low(EnvKeys) to High(EnvKeys) do L.Add(EnvKeys[I]);
    L.Sort;
    for I := 0 to L.Count - 1 do
    begin
      H := Fnv1a(L[I], H);
      H := Fnv1a(#0, H);
    end;
  finally
    L.Free;
  end;
  Result := LowerCase(IntToHex(LongWord(H xor (H shr 32)), 8));
end;

{ The server a composed tool name belongs to, found by matching the name we
  built rather than by splitting on '__': a truncated server segment and a
  tool name containing underscores make splitting a guess, and the table has
  the answer. }
function McpServerOfTool(const ToolName: string): Integer;
var
  I, J: Integer;
begin
  Result := -1;
  for I := 0 to High(McpServers) do
    for J := 0 to High(McpServers[I].Tools) do
      if McpServers[I].Tools[J].Name = ToolName then Exit(I);
end;

function McpCallApproved(const ToolName: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  I := McpServerOfTool(ToolName);
  if I < 0 then Exit;
  Result := (McpServers[I].Hash <> '') and
    (TrustedFingerprint('mcp-call:' + McpServers[I].Name) = McpServers[I].Hash);
end;

procedure AllowMcpServer(const ToolName: string);
var
  I: Integer;
begin
  I := McpServerOfTool(ToolName);
  if I < 0 then Exit;
  RecordTrust('mcp-call:' + McpServers[I].Name, McpServers[I].Hash);
end;

{ ---- configuration ---- }

{ The same filter LoadAgentDefinition applies to an agent type, for the same
  reason: the name becomes part of a path (the stderr spool, the cache key),
  and it comes from a file the project author wrote. }
function ValidServerName(const N: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if (N = '') or (Length(N) > 64) then Exit;
  for I := 1 to Length(N) do
    if (N[I] in ['\', '/', ':', '.']) or (N[I] < ' ') then Exit;
  Result := True;
end;

function QuoteArg(const A: string): string;
begin
  if (A <> '') and (Pos(' ', A) = 0) and (Pos('"', A) = 0) then Exit(A);
  Result := '"' + StringReplace(A, '"', '\"', [rfReplaceAll]) + '"';
end;

procedure NoteReason(var S: string; const Reason: string);
begin
  if Reason = '' then Exit;
  if Pos(Reason, S) > 0 then Exit;
  if S <> '' then S := S + ', ';
  S := S + Reason;
end;

function LoadMcpConfig(const Path: string; out Err: string): Boolean;
var
  F: TFileStream;
  Text, Name, Cmd, PErr: string;
  Root, Servers, S, A, E: TJson;
  I, J: Integer;
  Args, EnvKeys: array of string;
  Rec: TMcpServerRec;
begin
  Err := '';
  Result := False;
  ClearMcpServers;
  if not FileExists(Path) then Exit;
  Text := '';
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      if F.Size > McpMaxConfigBytes then
      begin
        Err := Format('%s is %d bytes; that is not a configuration',
          [ExtractFileName(Path), F.Size]);
        Exit;
      end;
      SetLength(Text, F.Size);
      if F.Size > 0 then F.ReadBuffer(Text[1], F.Size);
    finally
      F.Free;
    end;
  except
    on Ex: Exception do
    begin
      Err := 'cannot read ' + ExtractFileName(Path) + ': ' + Ex.Message;
      Exit;
    end;
  end;

  Root := JsonParse(Text, PErr);
  if Root = nil then
  begin
    Err := ExtractFileName(Path) + ' is not valid JSON: ' + PErr;
    Exit;
  end;
  try
    Servers := Root.Find('mcpServers');
    if (Servers = nil) or (Servers.Kind <> jkObj) then
    begin
      Err := ExtractFileName(Path) + ' has no mcpServers object';
      Exit;
    end;
    for I := 0 to Servers.Count - 1 do
    begin
      Name := Servers.Key(I);
      S := Servers.Item(I);
      if not ValidServerName(Name) then
      begin
        NoteReason(Err, 'refused a server whose name is not a bare name');
        Continue;
      end;
      if McpFind(Name) >= 0 then
      begin
        NoteReason(Err, 'refused a duplicate server name');
        Continue;
      end;
      if (S = nil) or (S.Kind <> jkObj) then
      begin
        NoteReason(Err, 'refused a server entry that is not an object');
        Continue;
      end;

      Rec.Name := Name;
      Rec.Note := '';
      Rec.LastErr := '';
      Rec.Hash := '';
      Rec.WorkDir := NormalizeRoot;
      Rec.ErrLog := McpDir + Name + '.err';
      Rec.Status := mcPending;
      Rec.Approved := False;
      Rec.Conn := -1;
      Rec.Skipped := 0;
      SetLength(Rec.Tools, 0);
      SetLength(Rec.EnvPairs, 0);
      Rec.TimeoutMs := Round(S.Num('timeoutMs', uMcp.McpCallMs));
      if Rec.TimeoutMs < 1000 then Rec.TimeoutMs := 1000;
      if Rec.TimeoutMs > 600000 then Rec.TimeoutMs := 600000;

      Rec.Transport := LowerCase(Trim(S.Str('type')));
      if Rec.Transport = '' then Rec.Transport := 'stdio';
      { Listed, never silently dropped.  A user who wrote an http entry and
        saw nothing at all would conclude the feature is broken rather than
        that this build does not speak that transport. }
      if (S.Find('url') <> nil) or (Rec.Transport <> 'stdio') then
      begin
        Rec.Status := mcUnsupported;
        Rec.Command := Trim(S.Str('url'));
        if Rec.Command = '' then Rec.Command := Trim(S.Str('command'));
        Rec.Note := 'this build speaks stdio only';
        SetLength(McpServers, Length(McpServers) + 1);
        McpServers[High(McpServers)] := Rec;
        Continue;
      end;

      { Expansion happens before the hash, so the fingerprint covers what will
        actually run.  Hashing the template instead would let the environment,
        rather than the approved file, decide what the program is. }
      Cmd := Trim(McpExpandVars(S.Str('command')));
      if Cmd = '' then
      begin
        NoteReason(Err, 'refused a server with no command');
        Continue;
      end;

      SetLength(Args, 0);
      A := S.Find('args');
      if (A <> nil) and (A.Kind = jkArr) then
        for J := 0 to A.Count - 1 do
        begin
          SetLength(Args, Length(Args) + 1);
          Args[High(Args)] := McpExpandVars(A.Item(J).AsString);
        end;

      SetLength(EnvKeys, 0);
      E := S.Find('env');
      if (E <> nil) and (E.Kind = jkObj) then
        for J := 0 to E.Count - 1 do
        begin
          SetLength(EnvKeys, Length(EnvKeys) + 1);
          EnvKeys[High(EnvKeys)] := E.Key(J);
          SetLength(Rec.EnvPairs, Length(Rec.EnvPairs) + 1);
          Rec.EnvPairs[High(Rec.EnvPairs)] :=
            E.Key(J) + '=' + McpExpandVars(E.Item(J).AsString);
        end;

      Rec.Command := QuoteArg(Cmd);
      for J := 0 to High(Args) do
        Rec.Command := Rec.Command + ' ' + QuoteArg(Args[J]);
      Rec.Hash := McpCommandHash(Cmd, Args, EnvKeys);

      SetLength(McpServers, Length(McpServers) + 1);
      McpServers[High(McpServers)] := Rec;
    end;
  finally
    Root.Free;
  end;
  Result := Length(McpServers) > 0;
end;

{ ---- the discovery cache ---- }

procedure McpLoadCache;
var
  F: TFileStream;
  Text, Path: string;
  Root, Arr, It: TJson;
  I, J, K: Integer;
begin
  Path := McpCachePath;
  if not FileExists(Path) then Exit;
  Text := '';
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      if F.Size > McpMaxConfigBytes then Exit;
      SetLength(Text, F.Size);
      if F.Size > 0 then F.ReadBuffer(Text[1], F.Size);
    finally
      F.Free;
    end;
  except
    Exit;
  end;
  Root := JsonParse(Text);
  if Root = nil then Exit;
  try
    if Root.Kind <> jkObj then Exit;
    for I := 0 to High(McpServers) do
    begin
      if McpServers[I].Hash = '' then Continue;
      Arr := Root.Find(McpServers[I].Name + '@' + McpServers[I].Hash);
      if (Arr = nil) or (Arr.Kind <> jkArr) then Continue;
      SetLength(McpServers[I].Tools, 0);
      for J := 0 to Arr.Count - 1 do
      begin
        It := Arr.Item(J);
        if (It = nil) or (It.Kind <> jkObj) then Continue;
        if (It.Str('n') = '') or (It.Str('d') = '') then Continue;
        K := Length(McpServers[I].Tools);
        SetLength(McpServers[I].Tools, K + 1);
        McpServers[I].Tools[K].Name := It.Str('n');
        McpServers[I].Tools[K].Orig := It.Str('o');
        McpServers[I].Tools[K].Decl := It.Str('d');
      end;
    end;
  finally
    Root.Free;
  end;
end;

procedure McpSaveCache;
var
  Root, Arr, It: TJson;
  Text: string;
  F: TFileStream;
  I, J: Integer;
begin
  Root := TJson.NewObj;
  try
    for I := 0 to High(McpServers) do
    begin
      if (McpServers[I].Hash = '') or (Length(McpServers[I].Tools) = 0) then
        Continue;
      Arr := TJson.NewArr;
      for J := 0 to High(McpServers[I].Tools) do
      begin
        It := TJson.NewObj;
        It.AddStr('n', McpServers[I].Tools[J].Name);
        It.AddStr('o', McpServers[I].Tools[J].Orig);
        It.AddStr('d', McpServers[I].Tools[J].Decl);
        Arr.Push(It);
      end;
      Root.Add(McpServers[I].Name + '@' + McpServers[I].Hash, Arr);
    end;
    Text := Root.ToJson;
  finally
    Root.Free;
  end;
  try
    ForceDirectories(ExtractFileDir(McpCachePath));
    F := TFileStream.Create(McpCachePath, fmCreate);
    try
      if Text <> '' then F.WriteBuffer(Text[1], Length(Text));
    finally
      F.Free;
    end;
  except
    { A cache that cannot be written costs a connect at the next start. }
  end;
end;

{ ---- approval, connection, discovery ---- }

procedure McpApproveAll(Ask: TAskProc; Notice: TMcpNoticeProc);
var
  I, NeedAsk: Integer;
  Detail, Line: string;
begin
  NeedAsk := 0;
  for I := 0 to High(McpServers) do
  begin
    if McpServers[I].Status = mcUnsupported then Continue;
    if (McpServers[I].Hash <> '') and
       (TrustedFingerprint('mcp:' + McpServers[I].Name) = McpServers[I].Hash) then
    begin
      McpServers[I].Approved := True;
      Continue;
    end;
    Inc(NeedAsk);
  end;
  if NeedAsk = 0 then Exit;

  { Said once, in full, before the first prompt: the question "may this
    repository run a program on your machine" is answerable only by someone
    who has been shown every program it names. }
  if Assigned(Notice) then
  begin
    if NeedAsk = 1 then
      Notice(Format('this project ships %s and asks to run 1 program before ' +
        'you have read it:', [ExtractFileName(McpConfigPath)]))
    else
      Notice(Format('this project ships %s and asks to run %d programs ' +
        'before you have read them:', [ExtractFileName(McpConfigPath), NeedAsk]));
    for I := 0 to High(McpServers) do
      if (McpServers[I].Status <> mcUnsupported) and
         (not McpServers[I].Approved) then
      begin
        Line := '  ' + McpServers[I].Name;
        while Length(Line) < 12 do Line := Line + ' ';
        Notice(Line + McpServers[I].Command);
      end;
    Notice('');
  end;

  for I := 0 to High(McpServers) do
  begin
    if McpServers[I].Status = mcUnsupported then Continue;
    if McpServers[I].Approved then Continue;
    { Nobody to ask is no.  This is the whole of why print mode can never be
      the thing that first executes a repository's code: it arrives here with
      a nil Ask, exactly as every other deny-by-default path does. }
    if Ask = nil then
    begin
      McpServers[I].Status := mcDenied;
      McpServers[I].Note := 'nobody to ask';
      Continue;
    end;
    Detail := 'run  ' + McpServers[I].Command + #10 +
      'this program comes from the project directory, not from you.';
    case Ask('mcp server "' + McpServers[I].Name + '"', Detail) of
      pmAllowOnce:
        McpServers[I].Approved := True;
      pmAllowAlways:
        begin
          McpServers[I].Approved := True;
          RecordTrust('mcp:' + McpServers[I].Name, McpServers[I].Hash);
        end;
    else
      McpServers[I].Status := mcDenied;
      McpServers[I].Note := 'you said no';
    end;
  end;
end;

function McpEnsureConnected(I: Integer): Boolean;
var
  Err, SN, SV, SP: string;
  C: Integer;
begin
  Result := False;
  if (I < 0) or (I > High(McpServers)) then Exit;
  if not McpServers[I].Approved then
  begin
    McpServers[I].LastErr := 'not approved to run';
    Exit;
  end;
  if (McpServers[I].Conn >= 0) and
     (uMcp.McpState(McpServers[I].Conn) = msRunning) then Exit(True);
  if McpServers[I].Conn >= 0 then
  begin
    { A server that died is not restarted behind the user's back: the exit
      code is latched and reported, and /mcp restart is the way back.  What
      happens here is only the tidying up of a slot we already know is dead. }
    McpServers[I].Status := mcDead;
    uMcp.McpClose(McpServers[I].Conn);
    McpServers[I].Conn := -1;
    Exit;
  end;

  ForceDirectories(McpDir);
  C := uMcp.McpSpawn(McpServers[I].Name, McpServers[I].Command,
    McpServers[I].WorkDir, McpServers[I].ErrLog, McpServers[I].EnvPairs, Err);
  if C < 0 then
  begin
    McpServers[I].Status := mcFailed;
    McpServers[I].LastErr := Err;
    Exit;
  end;
  McpServers[I].Conn := C;
  if not uMcp.McpHandshake(C, SN, SV, SP, Err) then
  begin
    uMcp.McpClose(C);
    McpServers[I].Conn := -1;
    McpServers[I].Status := mcFailed;
    McpServers[I].LastErr := Err;
    Exit;
  end;
  McpServers[I].LastErr := '';
  Result := True;
end;

function McpDiscover(I: Integer): Boolean;
var
  Arr: TJson;
  Err, CName, OName, DText, Why: string;
  J, K, N: Integer;
  Dup: Boolean;
begin
  Result := False;
  if not uMcp.McpListTools(McpServers[I].Conn, Arr, Err) then
  begin
    McpServers[I].Status := mcFailed;
    McpServers[I].LastErr := Err;
    Exit;
  end;
  try
    SetLength(McpServers[I].Tools, 0);
    McpServers[I].Skipped := 0;
    McpServers[I].Note := '';
    for J := 0 to Arr.Count - 1 do
    begin
      if Length(McpServers[I].Tools) >= McpMaxTools then
      begin
        Inc(McpServers[I].Skipped);
        NoteReason(McpServers[I].Note, 'over the per-server tool cap');
        Continue;
      end;
      if not McpValidateTool(Arr.Item(J), McpServers[I].Name,
                             CName, OName, DText, Why) then
      begin
        Inc(McpServers[I].Skipped);
        NoteReason(McpServers[I].Note, Why);
        Continue;
      end;
      Dup := False;
      for K := 0 to High(McpServers[I].Tools) do
        if McpServers[I].Tools[K].Name = CName then Dup := True;
      if Dup then
      begin
        Inc(McpServers[I].Skipped);
        NoteReason(McpServers[I].Note, 'duplicate after truncation');
        Continue;
      end;
      N := Length(McpServers[I].Tools);
      SetLength(McpServers[I].Tools, N + 1);
      McpServers[I].Tools[N].Name := CName;
      McpServers[I].Tools[N].Orig := OName;
      McpServers[I].Tools[N].Decl := DText;
    end;
  finally
    Arr.Free;
  end;
  Result := True;
end;

function McpConnectApproved(Notice: TMcpNoticeProc): Integer;
var
  I: Integer;
begin
  Result := 0;
  McpLoadCache;
  for I := 0 to High(McpServers) do
  begin
    if not McpServers[I].Approved then Continue;
    if McpServers[I].Status = mcUnsupported then Continue;
    { A cached tool list is the steady state: nothing is spawned at the
      prompt, and the first real call pays for the start-up.  The divergence
      this buys - we can advertise a tool the server no longer has - surfaces
      as one clean tool error, which is a far smaller cost than adding the
      server's boot time to every launch. }
    if Length(McpServers[I].Tools) > 0 then
    begin
      McpServers[I].Status := mcCached;
      Continue;
    end;
    if Assigned(Notice) then
      Notice('mcp: connecting ' + McpServers[I].Name + '...');
    if McpEnsureConnected(I) and McpDiscover(I) then
    begin
      McpServers[I].Status := mcConnected;
      Inc(Result);
    end;
  end;
  McpSaveCache;
end;

{ ---- the registered source ---- }

function McpDeclare: TJson;
var
  I, J, Used, Dropped: Integer;
  D: TJson;
begin
  Result := TJson.NewArr;
  Used := 0;
  Dropped := 0;
  for I := 0 to High(McpServers) do
    for J := 0 to High(McpServers[I].Tools) do
    begin
      { The budget is global and consumed in server order.  Per server it
        would be unbounded in aggregate, and this text lands in the cached
        request prefix ahead of the system prompt, which is the one place
        where "a few servers each within their limit" is not a limit. }
      if Used + Length(McpServers[I].Tools[J].Decl) > McpMaxDeclBytes then
      begin
        Inc(Dropped);
        Continue;
      end;
      D := JsonParse(McpServers[I].Tools[J].Decl);
      if D = nil then Continue;
      Inc(Used, Length(McpServers[I].Tools[J].Decl));
      Result.Push(D);
    end;
  McpBudgetDropped := Dropped;
end;

function McpRun(const Name: string; Input: TJson; Ask: TAskProc;
  out IsError: Boolean): string;
var
  I, J, Si, Ti: Integer;
  Detail, Text, Err: string;
  IsErr: Boolean;
begin
  IsError := True;
  Si := -1;
  Ti := -1;
  for I := 0 to High(McpServers) do
    for J := 0 to High(McpServers[I].Tools) do
      if McpServers[I].Tools[J].Name = Name then
      begin
        Si := I;
        Ti := J;
      end;
  if Si < 0 then Exit('unknown MCP tool: ' + Name);

  { The second permission level.  The first was "may this repository run this
    program at all", answered before anything was spawned; this one is "may
    that program act now", and it exists so the user sees a runaway loop
    rather than as the security boundary - the boundary was the spawn. }
  Detail := Format('mcp server "%s", tool %s', [McpServers[Si].Name,
    McpServers[Si].Tools[Ti].Orig]) + #10 + 'run  ' + McpServers[Si].Command;
  if not Permit(Name, Detail, Ask) then
    Exit('permission denied: ' + Name);

  if not McpEnsureConnected(Si) then
    Exit(Format('mcp server "%s" is not running: %s (stderr: %s)',
      [McpServers[Si].Name, McpServers[Si].LastErr, McpServers[Si].ErrLog]));

  if not uMcp.McpCallTool(McpServers[Si].Conn, McpServers[Si].Tools[Ti].Orig,
       Input, McpServers[Si].TimeoutMs, Text, IsErr, Err) then
  begin
    McpServers[Si].Status := mcDead;
    McpServers[Si].LastErr := Err;
    Exit(Format('mcp server "%s" did not answer: %s (exit %d, stderr: %s)',
      [McpServers[Si].Name, Err, uMcp.McpExitCode(McpServers[Si].Conn),
       McpServers[Si].ErrLog]));
  end;

  { Everything here is bytes a third-party program chose.  uMcp caps them but
    deliberately does not repair them, because whether they are OEM console
    output or something else is a question only this layer can answer - and
    one byte that is not UTF-8 makes the API reject the whole request and
    lose the conversation, not just this result. }
  if not IsValidUtf8(Text) then Text := OemToUtf8(Text);
  if Trim(Text) = '' then Text := '(the tool returned nothing)';
  IsError := IsErr;
  Result := Clip(Text);
end;

procedure RegisterMcpToolSource;
var
  Err: string;
begin
  { The answer is deliberately ignored.  The only way this refuses is a second
    registration of mcp__, which is a programming error rather than anything a
    user, a config file or a server can cause - and a build that got it wrong
    fails the registry test, not a user's session. }
  RegisterToolSource(McpNamePrefix, @McpDeclare, @McpRun, Err);
end;

{ ---- the panel ---- }

function McpServerList: TStringArray;
var
  I: Integer;
  Note, Cmd: string;
begin
  SetLength(Result, Length(McpServers));
  for I := 0 to High(McpServers) do
  begin
    Note := McpServers[I].Note;
    if McpServers[I].LastErr <> '' then NoteReason(Note, McpServers[I].LastErr);
    if (McpServers[I].Status = mcDead) or (McpServers[I].Status = mcFailed) then
      NoteReason(Note, 'stderr: ' + McpServers[I].ErrLog);
    if uMcp.McpToolsChanged(McpServers[I].Conn) then
      NoteReason(Note, 'tools changed - /mcp refresh to pick up');
    { A command line is under the user's nose in a prompt, not in a table:
      one that wraps the terminal for forty lines makes the whole panel
      unreadable, and the full text is in .mcp.json either way. }
    Cmd := McpServers[I].Command;
    if Length(Cmd) > 100 then Cmd := Copy(Cmd, 1, 97) + '...';
    Result[I] := McpServers[I].Name + #9 + McpStatusWord(McpServers[I].Status) +
      #9 + IntToStr(Length(McpServers[I].Tools)) +
      #9 + IntToStr(McpServers[I].Skipped + McpBudgetDropped) +
      #9 + Cmd + #9 + Note;
  end;
end;

function McpRestart(const Name: string; out Err: string): Boolean;
var
  I: Integer;
begin
  Err := '';
  I := McpFind(Name);
  if I < 0 then
  begin
    Err := 'no such server: ' + Name;
    Exit(False);
  end;
  if McpServers[I].Conn >= 0 then
  begin
    uMcp.McpClose(McpServers[I].Conn);
    McpServers[I].Conn := -1;
  end;
  McpServers[I].LastErr := '';
  if Length(McpServers[I].Tools) > 0 then
    McpServers[I].Status := mcCached
  else
    McpServers[I].Status := mcPending;
  Result := True;
end;

function McpRefresh(out Err: string): Boolean;
var
  I: Integer;
begin
  Err := '';
  Result := False;
  for I := 0 to High(McpServers) do
  begin
    if not McpServers[I].Approved then Continue;
    if McpServers[I].Status = mcUnsupported then Continue;
    if McpServers[I].Conn >= 0 then
    begin
      uMcp.McpClose(McpServers[I].Conn);
      McpServers[I].Conn := -1;
    end;
    SetLength(McpServers[I].Tools, 0);
    if McpEnsureConnected(I) and McpDiscover(I) then
    begin
      McpServers[I].Status := mcConnected;
      Result := True;
    end
    else
      NoteReason(Err, McpServers[I].Name + ': ' + McpServers[I].LastErr);
  end;
  McpSaveCache;
end;

function RunTool(const Name: string; Input: TJson; Ask: TAskProc;
  out IsError: Boolean): string;
var
  Full, Err, Text, Cmd, Note, Updated: string;
  Code: Integer;
  Ok: Boolean;
begin
  IsError := False;
  if Input = nil then
  begin
    IsError := True;
    Exit('missing tool input');
  end;

  { This, not the schema, is where read-only is true.  The schema is advice
    to the model and nothing stops it naming a tool it was never offered; and
    the permission gate is no backstop here, because Permit short-circuits on
    AllowAllEdits and PermitBash on a persisted "always", so under /yolo a
    subagent's write would land with a nil Ask and no prompt at all. }
  if (SubDepth > 0) and not IsSubagentTool(Name) then
  begin
    IsError := True;
    Exit('not available to a subagent: ' + Name);
  end;

  if Name = 'read_file' then
  begin
    if not SafePath(Input.Str('path'), Full, Err) then
    begin
      IsError := True;
      Exit(Err);
    end;
    if not FileExists(Full) then
    begin
      IsError := True;
      Exit('no such file: ' + Rel(Full));
    end;
    { A notebook is decoded into cells before anything else, because the model
      reaches for read_file by reflex: a separate notebook_read tool would be
      discovered only after four megabytes of base64 had already landed in the
      context, and that is not a mistake anything can undo.  Anything that
      fails here - too big, not UTF-8, not a v4 notebook - falls through to the
      ordinary text path, so a damaged notebook is still visible and fixable. }
    if IsNotebookPath(Full) then
    begin
      if LoadFileLimited(Full, MaxNotebookBytes, Text, Note) and (Note = '') and
         IsValidUtf8(Text) and NotebookView(Text, Cmd, Err) then
        Exit(Clip(Cmd));
      Note := '(this .ipynb did not read as a notebook; showing the raw file)';
    end
    else
      Note := '';
    if not LoadFileText(Full, Text, Err) then
    begin
      IsError := True;
      Exit('cannot read: ' + Err);
    end;
    { Both notes can apply at once - a notebook too big to parse is also a
      file too big to show whole - so the truncation note joins rather than
      replaces the one explaining why the cells are missing. }
    if Err <> '' then
      if Note = '' then Note := Err else Note := Note + ' ' + Err;
    { A binary file is shown as hex rather than smuggled into the request as
      invalid UTF-8, which the API would refuse outright. }
    if not IsValidUtf8(Text) then
    begin
      Result := Rel(Full) + ' is not UTF-8 text; showing a hex dump.'#10#10 +
        HexDump(Text, 4096);
      Exit;
    end;
    Result := WithLineNumbers(Text);
    if Note <> '' then Result := Note + #10 + Result;
    Result := Clip(Result);
  end

  else if Name = 'write_file' then
  begin
    if not SafePath(Input.Str('path'), Full, Err) then
    begin
      IsError := True;
      Exit(Err);
    end;
    if not PermitChange(Name, Input, Ask) then
    begin
      IsError := True;
      Exit('the user denied this write');
    end;
    SnapshotFile(Full);
    if not SaveFileText(Full, Input.Str('content'), Err) then
    begin
      IsError := True;
      Exit('cannot write: ' + Err);
    end;
    NoteChangedFile(Rel(Full));
    Result := Format('wrote %s (%d bytes)',
      [Rel(Full), Length(Input.Str('content'))]);
  end

  else if Name = 'edit_file' then
  begin
    if not SafePath(Input.Str('path'), Full, Err) then
    begin
      IsError := True;
      Exit(Err);
    end;
    if not FileExists(Full) then
    begin
      IsError := True;
      Exit('no such file: ' + Rel(Full));
    end;
    if not LoadFileText(Full, Text, Note) then
    begin
      IsError := True;
      Exit('cannot read: ' + Note);
    end;
    { One hunk through old_text/new_text, several through edits.  Every hunk
      is validated against the file before any is applied, so a failure in
      the third leaves the first two unapplied rather than half-editing. }
    if not ApplyEdits(Input, Text, Rel(Full), Err) then
    begin
      IsError := True;
      Exit(Err);
    end;
    if not PermitChange(Name, Input, Ask) then
    begin
      IsError := True;
      Exit('the user denied this edit');
    end;
    SnapshotFile(Full);
    if not SaveFileText(Full, Text, Err) then
    begin
      IsError := True;
      Exit('cannot write: ' + Err);
    end;
    NoteChangedFile(Rel(Full));
    Result := 'edited ' + Rel(Full);
  end

  else if Name = 'list_dir' then
  begin
    if not SafePath(Input.Str('path', '.'), Full, Err) then
    begin
      IsError := True;
      Exit(Err);
    end;
    if not DirectoryExists(Full) then
    begin
      IsError := True;
      Exit('no such directory: ' + Rel(Full));
    end;
    { An explicit depth wins; otherwise recursive still means the old 4. }
    if Input.Bool('recursive') then Code := 4 else Code := 0;
    Result := Clip(ListDir(Full, WalkDepth(Input, Code)));
  end

  else if Name = 'search' then
  begin
    { No permission call: search reads and reports, so it stays ungated and
      nothing new joins the edits class. }
    Text := GrepTree(NormalizeRoot, Input.Str('pattern'), Input.Str('glob'),
      Input.Bool('regex'), Input.Bool('case_sensitive'),
      WalkDepth(Input, 8), Err);
    if Err <> '' then
    begin
      IsError := True;
      Exit('invalid regex: ' + Err);
    end;
    Result := Clip(Text);
  end

  else if Name = 'bash' then
  begin
    Cmd := Input.Str('command');
    if Trim(Cmd) = '' then
    begin
      IsError := True;
      Exit('command is required');
    end;
    if not PermitBash(Cmd, DescribeTool(Name, Input), Ask) then
    begin
      IsError := True;
      Exit('the user denied this command');
    end;
    { The fork is below the gate, and must stay there.  Backgrounding is a
      question about who waits, not about what runs: a detached "del /s"
      deletes exactly as much as an attached one, so it faces exactly the
      same approval and the same remembered per-program prefix. }
    if Input.Bool('run_in_background') then
    begin
      if not StartBackgroundJob(Cmd, Note, Err) then
      begin
        IsError := True;
        Exit(Err);
      end;
      Exit(Format('started background job %s: %s'#10 +
        'read its output with bash_output(job_id="%s"), stop it with kill_bash.',
        [Note, Cmd, Note]));
    end;
    Text := RunShell(Cmd, NormalizeRoot, Code);
    { Console programs emit OEM-codepage bytes, not UTF-8, so anything
      non-ASCII has to be converted or the request body becomes invalid. }
    if not IsValidUtf8(Text) then
      Text := OemToUtf8(Text);
    Result := Clip(Text);
    if Result = '' then Result := '(no output)';
    Result := Result + Format(#10'[exit code %d]', [Code]);
    IsError := Code <> 0;
  end

  else if Name = 'fetch' then
  begin
    Text := Input.Str('url');
    if Copy(Text, 1, 8) <> 'https://' then
    begin
      IsError := True;
      Exit('only https:// URLs can be fetched: ' + Text);
    end;
    if not Permit(Name, DescribeTool(Name, Input), Ask) then
    begin
      IsError := True;
      Exit('the user denied this fetch');
    end;
    with HttpGet(Text, 'accept: text/html, application/json, text/plain'#13#10 +
      'user-agent: pasclaude/0.1', MaxFetchBytes) do
    begin
      if not Ok then
      begin
        IsError := True;
        if Body <> '' then
          Exit(Error + #10 + Clip(Body))
        else
          Exit(Error);
      end;
      Text := Body;
    end;
    { The body is whatever the server sent; anything not valid UTF-8 is
      scrubbed rather than hex-dumped, because a page in another encoding is
      still mostly readable text, unlike a binary file. }
    if not IsValidUtf8(Text) then
      Text := OemToUtf8(Text);
    if Text = '' then Text := '(empty response)';
    Result := Clip(Text);
  end

  else if Name = 'todo_write' then
  begin
    { No permission gate: the list is display state, it touches nothing.
      The whole list replaces the previous one, which spares the model a
      diff protocol and the code a merge. }
    with Input do
    begin
      if (Find('todos') = nil) or (Find('todos').Kind <> jkArr) then
      begin
        IsError := True;
        Exit('todos must be an array');
      end;
      SetLength(TodoList, Find('todos').Count);
      for Code := 0 to Find('todos').Count - 1 do
      begin
        Text := Find('todos').Item(Code).Str('status');
        if Text = 'completed' then
          TodoList[Code] := '[x] '
        else if Text = 'in_progress' then
          TodoList[Code] := '[~] '
        else
          TodoList[Code] := '[ ] ';
        TodoList[Code] := TodoList[Code] +
          Find('todos').Item(Code).Str('content');
      end;
    end;
    Result := Format('todo list updated (%d items)', [Length(TodoList)]);
  end

  { A separate tool rather than an extension of edit_file, because edit_file's
    contract is substring replacement on the file's TEXT - and a notebook's
    text is JSON.  Overloading it would make old_text mean something different
    depending on the extension: the model, having read decoded cells, would
    send print(x) while the file holds "print(x)\n" inside a JSON array.
    Insert and delete of a cell have no expression in that schema at all.  A
    model that reaches for edit_file here gets "old_text was not found", which
    is a clean, self-correcting error. }
  else if Name = 'notebook_edit' then
  begin
    if not SafePath(Input.Str('path'), Full, Err) then
    begin
      IsError := True;
      Exit(Err);
    end;
    if not FileExists(Full) then
    begin
      IsError := True;
      Exit('no such file: ' + Rel(Full));
    end;
    if not IsNotebookPath(Full) then
    begin
      IsError := True;
      Exit('not a notebook: ' + Rel(Full) + ' - use edit_file for ordinary files');
    end;
    if not LoadFileLimited(Full, MaxNotebookBytes, Text, Note) then
    begin
      IsError := True;
      Exit('cannot read: ' + Note);
    end;
    { A truncated read must never be written back: the result would be a
      valid document that had silently lost everything past the cut. }
    if Note <> '' then
    begin
      IsError := True;
      Exit('notebook is too large to edit safely ' + Note);
    end;
    if not IsValidUtf8(Text) then
    begin
      IsError := True;
      Exit(Rel(Full) + ' is not UTF-8 text and cannot be parsed as a notebook');
    end;
    if (Input.Str('edit_mode') <> 'delete') and (Input.Find('source') = nil) then
    begin
      IsError := True;
      Exit('source is required for edit_mode ' + Input.Str('edit_mode', '(none)'));
    end;
    { Transformed before the user is asked, exactly as edit_file validates its
      hunks first: a bad cell index or an unknown mode should never reach a
      prompt. }
    if not NotebookApply(Text, CellIndex(Input), Input.Str('edit_mode'),
                         Input.Str('source'), Input.Str('cell_type'),
                         Updated, Err) then
    begin
      IsError := True;
      Exit(Err);
    end;
    if not PermitChange(Name, Input, Ask) then
    begin
      IsError := True;
      Exit('the user denied this notebook edit');
    end;
    SnapshotFile(Full);
    if not SaveFileText(Full, Updated, Err) then
    begin
      IsError := True;
      Exit('cannot write: ' + Err);
    end;
    NoteChangedFile(Rel(Full));
    Result := Format('%s cell %d of %s',
      [Input.Str('edit_mode'), CellIndex(Input), Rel(Full)]);
  end

  { Neither of these is gated, and the reason is the same for both: they can
    only observe or stop a process this session already got permission to
    start.  A gate on reading output would hide what the user approved from
    the model that has to react to it, and a gate on killing is a gate that
    can only ever do harm - the answer "no, you may not stop it" is never the
    one anybody wanted. }
  else if Name = 'bash_output' then
  begin
    Cmd := Trim(Input.Str('job_id'));
    if Cmd = '' then Exit(Clip(BackgroundJobList));
    Text := PollBackgroundJob(Cmd, Ok);
    if not Ok then
    begin
      IsError := True;
      Exit('no such job: ' + Cmd);
    end;
    Result := Text;
    { A finished job that failed reads as a failure, the same as foreground
      bash - the model should not have to parse the status line to notice. }
    Code := FindJob(Cmd);
    IsError := (Code >= 0) and Jobs[Code].Done and (Jobs[Code].ExitCode <> 0);
  end

  else if Name = 'kill_bash' then
  begin
    Cmd := Trim(Input.Str('job_id'));
    if Cmd = '' then
    begin
      IsError := True;
      Exit('job_id is required');
    end;
    if not KillBackgroundJob(Cmd) then
    begin
      IsError := True;
      Exit('no such job: ' + Cmd);
    end;
    { The final tail comes back in the same round trip: whatever the job
      printed just before it died is usually the reason it was killed. }
    Result := 'killed ' + Cmd + #10 + PollBackgroundJob(Cmd, Ok);
  end

  { Ungated, like the three tools it is allowed to call.  A subagent can do
    strictly less than read_file, list_dir and search, which nobody is asked
    about either; what it does spend is the user's money, and that is bounded
    by one level of nesting and a low round ceiling rather than by a prompt
    the model would learn to expect. }
  else if Name = 'task' then
  begin
    Text := Trim(Input.Str('prompt'));
    if Text = '' then
    begin
      IsError := True;
      Exit('prompt is required');
    end;
    if not Assigned(SubagentRunner) then
    begin
      IsError := True;
      Exit('subagents are not available in this build');
    end;
    if not LoadAgentDefinition(Input.Str('agent_type'), Note, Err) then
    begin
      IsError := True;
      Exit(Err);
    end;
    { The second of the two independent guards - the first being that task is
      absent from the schema a subagent is sent.  Balanced in a finally so an
      exception cannot leave the depth raised and the parent permanently
      unable to delegate. }
    if not EnterSubagent then
    begin
      IsError := True;
      Exit('a subagent cannot start another subagent');
    end;
    try
      if SubagentRunner(Text, Note, Cmd, Err) then
      begin
        if not IsValidUtf8(Cmd) then Cmd := OemToUtf8(Cmd);
        if Trim(Cmd) = '' then Cmd := '(the subagent returned nothing)';
        Result := Clip(Cmd);
      end
      else
      begin
        IsError := True;
        Result := 'subagent failed: ' + Err;
      end;
    finally
      LeaveSubagent;
    end;
  end

  { Not one of ours.  A registered source may own it - and note that the
    subagent boundary above has already run, so a name from a source is
    refused inside a subagent before any source is consulted, because nothing
    a source contributes is on IsSubagentTool's three-name list. }
  else if DispatchToolSource(Name, Input, Ask, IsError, Result) then
    { the source answered, in the ladder's own terms }

  else
  begin
    IsError := True;
    Result := 'unknown tool: ' + Name;
  end;
end;

initialization
  { The same ladder-crossing shape uAgent uses to fill SubagentRunner, except
    that both halves live in this unit, so there is nothing to wait for. }
  RegisterMcpToolSource;

finalization
  { A background job outliving the process that started it is the one failure
    mode worse than a leaked handle: the user is left with a program they did
    not launch by hand and cannot name.  The host calls this in its shutdown
    finally as well; this is the backstop for the paths that skip it.  The
    paths that skip even finalization - a hard kill - are covered by the job
    objects' kill-on-close, which Windows honours when it reclaims handles. }
  ClearJobs;

end.
