{ uSdk - driving pasclaude from another program.

  Two things live here, and they are the same thing seen from two sides.

  The first is a line protocol: one JSON object per line on stdout, one line
  of driver input per answer on stdin, so a script in any language can spawn
  pasclaude and watch a turn happen instead of scraping prose out of a
  terminal.  The second is the assembly and ordering ritual that a program
  embedding TAgent has to perform - the system prompt, the project's own
  instruction files, the root and the ignore rules - which until now was
  trapped inside pasclaude.lpr where nothing could reach it.

  The unit exists because a protocol that lives in the .lpr cannot be tested.
  No suite can link the program, so every field name, every escape and the
  one-object-per-line rule would be verified by running the executable and
  reading it with human eyes.  Here the encoders are ordinary functions and
  the driver reads and writes through two procedure-typed vars, so loop, fuzz
  and ux drive the whole protocol with no process, no pipe and no console.

  Nothing in here touches uTerm.  That is not tidiness: it is what makes the
  facade a proof rather than a demo, and examples\embed.lpr is built by
  build.cmd so it cannot quietly start needing a console again. }
unit uSdk;

{$mode objfpc}{$H+}

interface

uses SysUtils, uJson, uTools, uAgent;

type
  TSdkFormat = (sfText, sfJson, sfStreamJson);
  { One finished protocol line, without its terminator.  Nil writes to stdout. }
  TLineSink = procedure(const S: string);
  { One line of driver input; False at end of stream.  Nil reads stdin. }
  TLineSource = function(out S: string): Boolean;
  { Extra system-prompt text contributed by another feature.  Today that is
    hooks' SessionStart output and nothing else: skills put their catalogue in
    the skill tool's description and MCP puts its tools in the tools array,
    both of which are rebuilt per request, where the system prompt is fixed at
    TAgent.Create.  A general injection seam here would invite exactly the
    mid-session prefix invalidation the tool list is careful to avoid. }
  TSystemExtraProc = function: string;

  TSdkUsage = record
    InputTokens, OutputTokens, CacheWriteTokens, CacheReadTokens: Int64;
  end;

  TSdkOptions = record
    Format: TSdkFormat;
    StreamInput: Boolean;
    SessionId: string;
    { The mode NAME as reported to the driver in the init event, and nothing
      else.  It used to be a behaviour switch keyed on a display string, which
      became a latent bug the moment the vocabulary grew past two words: a
      mode the driver should see reported ('plan') would have silently
      disarmed the permission channel.  '' means "ask uTools what it is". }
    PermissionMode: string;
    { Whether a permission request should be put to the driver.  Separate from
      the name above so reporting a mode and answering a prompt are two
      decisions, taken by whoever knows each. }
    AskViaDriver: Boolean;
    { Where this run's transcript is saved and, with Resume, loaded from.
      Empty means persist nothing, which is what -p has always done and stays
      the default: a script's throwaway question must not touch the
      directory's saved conversation. }
    SessionFile: string;
    { Load SessionFile before the first turn.  A file that is not there yet is
      a fresh start; a file that is there and unreadable stops the run. }
    Resume: Boolean;
    { What the load actually did, filled in by SdkRun and reported on the init
      line so a driver can tell a continuation from a fresh start without
      guessing. }
    Resumed: Boolean;
    ResumedMessages: Integer;
  end;

var
  SdkSink: TLineSink = nil;
  SdkSource: TLineSource = nil;
  SdkSystemExtra: TSystemExtraProc = nil;

{ ---- system prompt assembly, lifted verbatim from pasclaude.lpr ---- }
function SdkGitContext: string;
function SdkExpandImports(const Text: string): string;
function SdkUserContext: string;
function SdkProjectContext: string;
function SdkSystemPrompt: string;
{ The single call site the host uses.  The extra text sits between the
  guidelines and the project's own instructions, because it is session
  context rather than a standing rule and the "treat them as binding" line
  must stay attached to the files it introduces. }
function SdkFullSystem: string;

{ ---- custom commands ---- }
function SdkCommandNames: TStringArray;
function SdkExpandCustomCommand(const Line: string; out Ok: Boolean): string;

{ ---- pure encoders: each returns one complete NDJSON line ---- }
{ AModel is the LITERAL session model, which may now be an alias or a
  profile name; AResolved is what the next main request would actually carry.
  Both, because a driver has to be able to report the user's choice and the
  string on the wire, and after a /mode those two differ. }
function SdkInitLine(const Opts: TSdkOptions;
  const AModel, AResolved: string): string;
function SdkUserLine(const Text: string): string;
function SdkDeltaLine(const Kind, Text: string): string;
function SdkToolUseLine(const Id, Name, InputJson: string): string;
function SdkToolResultLine(const Id, Name, Content: string; IsError: Boolean): string;
function SdkNoticeLine(const Text: string): string;
{ One diagnostic report as one protocol line: {"type":"diagnostic","kind":...}
  with the payload's own keys merged in beside them.  PayloadJson is PARSED
  and re-emitted rather than spliced, exactly as SdkToolUseLine handles a
  model's argument text: a payload carrying a newline would otherwise split
  one event into two lines and desynchronise every driver reading the stream.
  A payload that will not parse becomes an empty object with the kind intact,
  which a driver can survive; a broken line is not survivable.
  Deliberately a string parameter and not a uDiag type, so uSdk gains no
  dependency on the unit that produces it. }
function SdkDiagnosticLine(const Kind, PayloadJson: string): string;
function SdkHookLine(const Event, ToolName, Detail: string; Blocked: Boolean): string;
function SdkErrorLine(const Text: string): string;
function SdkPermissionRequestLine(const Id, ToolName, Title, Detail: string): string;
{ Models is additive: 'usage' and 'total_usage' keep exactly their present
  meaning, and the new 'models' array says which model spent what - which the
  two scalars stopped being able to say once a role could be routed. }
function SdkResultLine(const Subtype, ErrText, FinalText: string;
  DurationMs: Int64; Turns: Integer; const Usage, Total: TSdkUsage;
  const Models: TModelUsageList): string;

{ ---- plumbing ---- }
procedure SdkEmit(const Line: string);
function SdkReadLine(out S: string): Boolean;
function SdkNewSessionId: string;
function SdkParseFormat(const S: string; out F: TSdkFormat): Boolean;
{ The four public token counters as one value, so a turn's own cost is the
  difference of two snapshots.  Computing it here costs uAgent nothing. }
function SdkSnapshotUsage(A: TAgent): TSdkUsage;

{ A TSdkOptions with every field at its default.  A locally declared record
  only has its string fields initialised by the compiler - its Booleans and
  Integers keep whatever was on the stack - so a caller that sets the fields
  it knows about silently inherits garbage in the ones added after it was
  written.  A garbage Boolean deciding whether to load a session would be
  machine-dependent and not a compile error, so every construction goes
  through here. }
function SdkDefaultOptions: TSdkOptions;

{ Loads Path into A if there is anything to load.  An empty path and a file
  that is not there yet are both a fresh start, because the first call in a
  subprocess-per-turn loop has no file: Msgs comes back 0 and the run goes on.
  A file that IS there and cannot be read is a refusal, not a fresh start - a
  script that asked to continue a conversation and quietly got a blank one
  does work on absent context and then overwrites the evidence.  Err is
  LoadSession's own reason, unaltered. }
function SdkResumeInto(A: TAgent; const Path: string;
  out Msgs: Integer; out Err: string): Boolean;

{ Runs the whole SDK session and returns the process exit code.  0 is a clean
  run, 1 means some turn failed or a save did not happen, and 2 means the run
  never started: the named session file exists and could not be resumed. }
function SdkRun(A: TAgent; const Opts: TSdkOptions;
  const FirstPrompt: string; out Err: string): Integer;

{ Queues any image blocks in a driver's user message onto the agent, and says
  how many.  Public so a suite can drive it without stdin; called from the
  type:'user' arm before the turn runs, because UserTextOf keeps only text and
  a driver's image would otherwise be dropped without a word. }
function AttachUserImages(A: TAgent; M: TJson): Integer;

type
  { The Pascal embedding facade: the ordering ritual in one object.  One
    session per process, and that is not a simplification - RootDir, the
    AllowAll flags, the job table, the bash prefixes, the snapshots and the
    ignore rules are all module-global in uTools, so a second concurrent
    session would share them. }
  TSdkSession = class
  private
    FAgent: TAgent;
  public
    constructor Create(const Root, ApiKey, AModel: string);
    destructor Destroy; override;
    { One question, one answer.  Ask is nil, so every gated tool refuses and
      says so in its result - an embedder that wants otherwise assigns
      Agent.Ask itself and is thereby making a deliberate choice. }
    function Ask(const Prompt: string; out Reply, Err: string): Boolean;
    property Agent: TAgent read FAgent;
  end;

implementation

uses Classes;

{ ---------------------------------------------------------- system prompt -- }

{ One quiet git call at startup.  Knowing the branch and whether the tree is
  dirty saves the model its most common first tool call, and mentioning git at
  all tells it commits are welcome.  A directory that is not a repository
  contributes nothing rather than an error. }
function SdkGitContext: string;
var
  Code: Integer;
  Head, Stat: string;

  function OneLine(const S: string): string;
  var
    P: Integer;
  begin
    Result := Trim(S);
    P := Pos(#10, Result);
    if P > 0 then SetLength(Result, P - 1);
    Result := Trim(Result);
  end;

var
  I, Lines: Integer;
  Git: string;
begin
  Result := '';
  { Resolved on PATH rather than composed as a bare 'git'.  cmd.exe /C
    searches the CURRENT DIRECTORY first, so the bare form ran a git.cmd the
    cloned repository shipped - at startup, before the user typed anything.
    A git that does not resolve contributes nothing here, exactly as a
    directory that is not a repository already does. }
  Git := uTools.ProgramCommand('git', 'rev-parse --abbrev-ref HEAD');
  if Git = '' then Exit;
  Head := uTools.RunShellQuiet(Git, Code);
  if Code <> 0 then Exit;
  Head := OneLine(Head);
  if Head = '' then Exit;

  Git := uTools.ProgramCommand('git', 'status --porcelain');
  if Git = '' then Exit;
  Stat := uTools.RunShellQuiet(Git, Code);
  Lines := 0;
  if Code = 0 then
    for I := 1 to Length(Stat) do
      if Stat[I] = #10 then Inc(Lines);

  Result := 'This is a git repository on branch "' + Head + '"';
  if Lines = 0 then
    Result := Result + ' with a clean tree.'
  else
    Result := Result + Format(' with %d changed files (git status/diff for detail).',
      [Lines]);
  Result := Result + #10#10;
end;

function SdkSystemPrompt: string;
var
  GitInfo, Extra: string;
  I: Integer;
begin
  GitInfo := SdkGitContext;
  { Emitted only when the user added one, so an ordinary session's prompt -
    and the cache prefix built on it - is byte-identical to what it was
    before working directories became a set. }
  Extra := '';
  if uTools.RootCount > 1 then
  begin
    Extra := 'Additional working directories (same rules as the session ' +
      'root):' + #10;
    for I := 1 to uTools.RootCount - 1 do
      Extra := Extra + '  ' + uTools.RootAt(I) + #10;
    Extra := Extra + 'Tool paths are relative to the session root. A file ' +
      'in an additional directory must be given as its full absolute path.' +
      #10#10;
  end;
  Result :=
    'You are pasclaude, a terminal coding assistant working inside a user''s ' +
    'project directory on Windows.' + #10#10 +
    'Session root: ' + uTools.RootDir + #10#10 +
    Extra +
    GitInfo +
    'Guidelines:' + #10 +
    '- Investigate before you act: read the relevant files rather than ' +
    'guessing at their contents.' + #10 +
    '- Prefer edit_file over write_file when changing an existing file.' + #10 +
    '- Jupyter notebooks (.ipynb) read back as numbered cells; change them ' +
    'with notebook_edit, not edit_file.' + #10 +
    '- For a self-contained question that needs a lot of reading to answer - ' +
    'which unit owns something, where a setting is used - hand it to task ' +
    'and work from its answer, so this conversation is not filled with the ' +
    'intermediate files.' + #10 +
    '- Named skills may be available through the skill tool; check its list ' +
    'before improvising a procedure this project has already written down.' + #10 +
    '- Shell commands run through cmd.exe, so use Windows syntax.' + #10 +
    '- After changing code, build or test it if there is an obvious way to ' +
    'do so, and fix what you broke.' + #10 +
    '- Keep replies short. The user is reading a terminal, not a report. ' +
    'Explain what you did, not what you are about to do.' + #10 +
    '- Write, edit and shell commands need the user''s approval, so batch ' +
    'related changes rather than asking many times for trivia.';
end;

{ Expands @import lines in an instruction file: a line that is exactly
  "@import <path>" (or Claude Code's bare "@path" form alone on a line) is
  replaced by that file's contents.  One level only - an import cannot
  import - because a cycle must terminate and one level covers the real
  use: a shared conventions file included from CLAUDE.md.  The path faces
  the session-root guard; anything it refuses stays as literal text. }
function SdkExpandImports(const Text: string): string;
var
  L, F: TStringList;
  I: Integer;
  Line, Ref, Full, Err, Sub: string;
begin
  L := TStringList.Create;
  try
    L.Text := Text;
    Result := '';
    for I := 0 to L.Count - 1 do
    begin
      Line := Trim(L[I]);
      Ref := '';
      if Copy(Line, 1, 8) = '@import ' then
        Ref := Trim(Copy(Line, 9, MaxInt))
      else if (Length(Line) > 1) and (Line[1] = '@') and
              (Pos(' ', Line) = 0) then
        { The bare "@path" form, alone on its line. }
        Ref := Copy(Line, 2, MaxInt);

      if (Ref <> '') and uTools.ResolveInRoot(Ref, Full, Err) and
         FileExists(Full) then
      begin
        Sub := '';
        F := TStringList.Create;
        try
          try
            F.LoadFromFile(Full);
            Sub := F.Text;
          except
            Sub := '';
          end;
        finally
          F.Free;
        end;
        if (Sub <> '') and uJson.IsValidUtf8(Sub) then
        begin
          Result := Result + '--- imported: ' + Ref + ' ---'#10 + Sub + #10;
          Continue;
        end;
      end;
      Result := Result + L[I] + #10;
    end;
  finally
    L.Free;
  end;
end;

{ The user-level memory: %USERPROFILE%\.pasclaude\CLAUDE.md, instructions
  that follow the user across projects.  It loads before the project's own
  files so a project can override it - nearer wins, as in Claude Code. }
function SdkUserContext: string;
var
  Path: string;
  L: TStringList;
begin
  Result := '';
  Path := IncludeTrailingPathDelimiter(GetEnvironmentVariable('USERPROFILE')) +
    '.pasclaude' + PathDelim + 'CLAUDE.md';
  if not FileExists(Path) then Exit;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(Path);
      Result := #10#10 + '--- user memory (~\.pasclaude\CLAUDE.md) ---' + #10 +
        L.Text;
    except
      { Unreadable user memory is not worth failing the session over. }
    end;
  finally
    L.Free;
  end;
end;

{ Project instructions, if the repository ships any.  This is how a project
  tells the agent about its own conventions.  The user-level memory loads
  first so the project's own files can override it - nearer wins. }
function SdkProjectContext: string;
var
  Names: array[0..2] of string = ('AGENTS.md', 'CLAUDE.md', '.pasclaude.md');
  I: Integer;
  Path: string;
  L: TStringList;
begin
  Result := SdkUserContext;
  for I := 0 to High(Names) do
  begin
    Path := IncludeTrailingPathDelimiter(uTools.RootDir) + Names[I];
    if not FileExists(Path) then Continue;
    L := TStringList.Create;
    try
      try
        L.LoadFromFile(Path);
        Result := Result + #10#10 + '--- ' + Names[I] + ' ---' + #10 +
          SdkExpandImports(L.Text);
      except
        { An unreadable context file is not worth failing the session over. }
      end;
    finally
      L.Free;
    end;
  end;
  if Result <> '' then
    Result := #10#10 + 'Project instructions follow. Treat them as binding.' + Result;
end;

function SdkFullSystem: string;
begin
  Result := SdkSystemPrompt;
  if Assigned(SdkSystemExtra) then Result := Result + SdkSystemExtra();
  Result := Result + SdkProjectContext;
end;

{ --------------------------------------------------------- slash commands -- }

{ The names under .pasclaude\commands, for the init line's inventory.  Only
  the project's own directory is walked: an enabled plugin's commands answer
  to /name through uTools.ResolveCommandFile, but there is no enumerator for
  them, and inventing one here would put a second, differently-ordered list
  beside the one /plugins already prints. }
function SdkCommandNames: TStringArray;
var
  R: TSearchRec;
  L: TStringList;
  I: Integer;
  Dir: string;
begin
  Result := nil;
  Dir := IncludeTrailingPathDelimiter(uTools.RootDir) + uTools.StateDirName +
    PathDelim + uTools.CommandsDirName + PathDelim;
  L := TStringList.Create;
  try
    if FindFirst(Dir + '*.md', faAnyFile, R) = 0 then
    begin
      repeat
        if (R.Attr and faDirectory) <> 0 then Continue;
        L.Add(ChangeFileExt(R.Name, ''));
      until FindNext(R) <> 0;
      FindClose(R);
    end;
    L.Sort;
    SetLength(Result, L.Count);
    for I := 0 to L.Count - 1 do Result[I] := L[I];
  finally
    L.Free;
  end;
end;

{ A user-defined command: /name args reads .pasclaude\commands\name.md and
  returns its contents as the prompt, with every $ARGUMENTS replaced by the
  rest of the line.  The file is the prompt, nothing more - no frontmatter,
  no scripting - because a prompt in a file already covers the real use:
  the same request typed often, made one word. }
function SdkExpandCustomCommand(const Line: string; out Ok: Boolean): string;
var
  Name, Args, Path: string;
  Sp, I: Integer;
  L: TStringList;
begin
  Result := '';
  Ok := False;
  Sp := Pos(' ', Line);
  if Sp = 0 then
  begin
    Name := Copy(Line, 2, MaxInt);
    Args := '';
  end
  else
  begin
    Name := Copy(Line, 2, Sp - 2);
    Args := Trim(Copy(Line, Sp + 1, MaxInt));
  end;
  if Name = '' then Exit;
  { The name is a filename; anything that could redirect the lookup out of
    the commands directory is refused rather than resolved. }
  for I := 1 to Length(Name) do
    if Name[I] in ['\', '/', ':', '.'] then Exit;

  { Through the resolver, so an enabled plugin's commands answer to /name too.
    The filter above stays: it is one line, it is the same rule, and defence
    in depth costs nothing here. }
  Path := uTools.ResolveCommandFile(Name);
  if Path = '' then Exit;

  L := TStringList.Create;
  try
    try
      L.LoadFromFile(Path);
    except
      Exit;
    end;
    Result := StringReplace(L.Text, '$ARGUMENTS', Args, [rfReplaceAll]);
    Ok := Trim(Result) <> '';
  finally
    L.Free;
  end;
end;

{ ---------------------------------------------------------------- encoders -- }

{ Everything that reaches a protocol line has been somewhere this program does
  not control: a tool's stdout, a file's bytes, a server's reply.  One byte
  that is not UTF-8 makes the line unparseable for the driver, exactly as it
  makes a request unacceptable to the API - so the repair happens on the way
  in, once, on every field. }
function Safe(const S: string): string;
begin
  if uJson.IsValidUtf8(S) then Result := S else Result := uJson.OemToUtf8(S);
end;

{ Every encoder ends here: build an object, serialise it compactly, free it.
  ToJson is used and never ToJsonPretty - a pretty object spans lines, and a
  line is the frame. }
function Finish(Root: TJson): string;
begin
  try
    Result := Root.ToJson;
  finally
    Root.Free;
  end;
end;

function UsageJson(const U: TSdkUsage): TJson;
begin
  Result := TJson.NewObj;
  Result.AddNum('input_tokens', U.InputTokens);
  Result.AddNum('output_tokens', U.OutputTokens);
  Result.AddNum('cache_write_tokens', U.CacheWriteTokens);
  Result.AddNum('cache_read_tokens', U.CacheReadTokens);
end;

{ Splits one TAB-separated row of uTools.McpServerList. }
function TabField(const S: string; N: Integer): string;
var
  I, Start, Seen: Integer;
begin
  Result := '';
  Start := 1;
  Seen := 0;
  for I := 1 to Length(S) + 1 do
    if (I > Length(S)) or (S[I] = #9) then
    begin
      if Seen = N then
      begin
        Result := Copy(S, Start, I - Start);
        Exit;
      end;
      Inc(Seen);
      Start := I + 1;
    end;
end;

function SdkInitLine(const Opts: TSdkOptions;
  const AModel, AResolved: string): string;
var
  Root, Arr, Ent: TJson;
  Schema: TJson;
  I: Integer;
  Names: TStringArray;
  Rows: TStringArray;
  Skills: uTools.TSkillInfoArray;
begin
  Root := TJson.NewObj;
  try
    Root.AddStr('type', 'system');
    Root.AddStr('subtype', 'init');
    Root.AddStr('session_id', Opts.SessionId);
    Root.AddStr('cwd', Safe(uTools.RootDir));
    { Reported, never accepted: a driver can see which directories are in the
      set and has no message that adds one. }
    Arr := TJson.NewArr;
    for I := 1 to uTools.RootCount - 1 do
      Arr.Push(TJson.NewStr(Safe(uTools.RootAt(I))));
    Root.Add('working_dirs', Arr);
    Root.AddStr('model', Safe(AModel));
    Root.AddStr('model_resolved', Safe(AResolved));
    { A caller that says nothing gets the truth rather than a blank: a driver
      that cannot see the mode cannot explain a refusal to whoever is reading
      its log. }
    if Opts.PermissionMode <> '' then
      Root.AddStr('permission_mode', Opts.PermissionMode)
    else
      Root.AddStr('permission_mode',
        uTools.PermModeName(uTools.CurrentPermMode));

    { Walked out of the live schema rather than listed here, so a tool that
      MCP or skills contributed appears without this encoder knowing it
      exists.  ToolsSchema hands over ownership of the array. }
    Arr := TJson.NewArr;
    Schema := uTools.ToolsSchema;
    try
      for I := 0 to Schema.Count - 1 do
        Arr.Push(TJson.NewStr(Schema.Item(I).Str('name')));
    finally
      Schema.Free;
    end;
    Root.Add('tools', Arr);

    Arr := TJson.NewArr;
    Names := uTools.SubagentTypes;
    for I := 0 to High(Names) do Arr.Push(TJson.NewStr(Safe(Names[I])));
    Root.Add('agents', Arr);

    Arr := TJson.NewArr;
    Names := SdkCommandNames;
    for I := 0 to High(Names) do Arr.Push(TJson.NewStr(Safe(Names[I])));
    Root.Add('commands', Arr);

    { Always present, even empty.  A driver that must branch on a missing key
      is a driver that will get it wrong on the build where the feature is
      switched off. }
    Arr := TJson.NewArr;
    Rows := uTools.McpServerList;
    for I := 0 to High(Rows) do
    begin
      Ent := TJson.NewObj;
      Ent.AddStr('name', Safe(TabField(Rows[I], 0)));
      Ent.AddStr('status', Safe(TabField(Rows[I], 1)));
      Arr.Push(Ent);
    end;
    Root.Add('mcp_servers', Arr);

    Arr := TJson.NewArr;
    Skills := uTools.SkillCatalogue;
    for I := 0 to High(Skills) do
    begin
      Ent := TJson.NewObj;
      Ent.AddStr('name', Safe(Skills[I].Name));
      Ent.AddStr('description', Safe(Skills[I].Description));
      Arr.Push(Ent);
    end;
    Root.Add('skills', Arr);

    { All three unconditional, by the same rule as mcp_servers above: a driver
      that branches on a missing key gets it wrong on the run where nothing
      was resumed, which is most of them.  resumed is the outcome SdkRun
      found, not what the caller asked for, so a --resume against a file that
      was not there yet reports false rather than a hopeful true. }
    Root.AddBool('resumed', Opts.Resumed);
    Root.AddNum('resumed_messages', Opts.ResumedMessages);
    Root.AddStr('session_file', Safe(Opts.SessionFile));
  except
    Root.Free;
    raise;
  end;
  Result := Finish(Root);
end;

function SdkUserLine(const Text: string): string;
var
  Root, Msg: TJson;
begin
  Root := TJson.NewObj;
  Root.AddStr('type', 'user');
  Msg := TJson.NewObj;
  Msg.AddStr('role', 'user');
  Msg.AddStr('content', Safe(Text));
  Root.Add('message', Msg);
  Result := Finish(Root);
end;

function SdkDeltaLine(const Kind, Text: string): string;
var
  Root, D: TJson;
begin
  Root := TJson.NewObj;
  Root.AddStr('type', 'assistant_delta');
  D := TJson.NewObj;
  D.AddStr('type', Kind);
  D.AddStr('text', Safe(Text));
  Root.Add('delta', D);
  Result := Finish(Root);
end;

function SdkToolUseLine(const Id, Name, InputJson: string): string;
var
  Root, In_: TJson;
begin
  Root := TJson.NewObj;
  Root.AddStr('type', 'tool_use');
  Root.AddStr('id', Safe(Id));
  Root.AddStr('name', Safe(Name));
  { Parsed and re-emitted rather than spliced in as a fragment.  A model that
    streamed truncated argument JSON would otherwise corrupt the whole line
    and take the driver's parser down with it; an empty object is a lie the
    driver can survive, a broken line is not. }
  In_ := nil;
  if Trim(InputJson) <> '' then In_ := JsonParse(InputJson);
  if (In_ = nil) or (In_.Kind <> jkObj) then
  begin
    In_.Free;
    In_ := TJson.NewObj;
  end;
  Root.Add('input', In_);
  Result := Finish(Root);
end;

function SdkToolResultLine(const Id, Name, Content: string; IsError: Boolean): string;
var
  Root: TJson;
begin
  Root := TJson.NewObj;
  Root.AddStr('type', 'tool_result');
  Root.AddStr('tool_use_id', Safe(Id));
  Root.AddStr('name', Safe(Name));
  Root.AddStr('content', Safe(Content));
  Root.AddBool('is_error', IsError);
  Result := Finish(Root);
end;

function SdkNoticeLine(const Text: string): string;
var
  Root: TJson;
begin
  Root := TJson.NewObj;
  Root.AddStr('type', 'notice');
  Root.AddStr('text', Safe(Text));
  Result := Finish(Root);
end;

function SdkDiagnosticLine(const Kind, PayloadJson: string): string;
var
  Root, Payload: TJson;
  I: Integer;
begin
  Root := TJson.NewObj;
  Root.AddStr('type', 'diagnostic');
  Root.AddStr('kind', Safe(Kind));
  Payload := nil;
  if Trim(PayloadJson) <> '' then Payload := JsonParse(PayloadJson);
  if (Payload <> nil) and (Payload.Kind = jkObj) then
  try
    { Merged rather than nested under a 'payload' key, so a driver reads
      report.model and not report.payload.model.  The payload's own 'type'
      is skipped: this line's type is 'diagnostic', and letting a nested
      value overwrite it would produce an event no driver has a case for. }
    for I := 0 to Payload.Count - 1 do
      if (Payload.Key(I) <> 'type') and (Payload.Key(I) <> 'kind') then
        Root.Add(Payload.Key(I), Payload.Take(I));
  finally
    Payload.Free;
  end
  else
    Payload.Free;
  Result := Finish(Root);
end;

function SdkHookLine(const Event, ToolName, Detail: string; Blocked: Boolean): string;
var
  Root: TJson;
begin
  Root := TJson.NewObj;
  Root.AddStr('type', 'hook');
  Root.AddStr('event', Safe(Event));
  Root.AddStr('tool_name', Safe(ToolName));
  Root.AddStr('detail', Safe(Detail));
  Root.AddBool('blocked', Blocked);
  Result := Finish(Root);
end;

function SdkErrorLine(const Text: string): string;
var
  Root: TJson;
begin
  Root := TJson.NewObj;
  Root.AddStr('type', 'error');
  Root.AddStr('error', Safe(Text));
  Result := Finish(Root);
end;

function SdkPermissionRequestLine(const Id, ToolName, Title, Detail: string): string;
var
  Root: TJson;
begin
  Root := TJson.NewObj;
  Root.AddStr('type', 'permission_request');
  Root.AddStr('id', Safe(Id));
  Root.AddStr('tool_name', Safe(ToolName));
  Root.AddStr('title', Safe(Title));
  { The detail is the diff preview a console user would read, newlines and
    all.  JsonQuote turns those into \n, so a fifty-line diff still occupies
    exactly one line of the protocol. }
  Root.AddStr('detail', Safe(Detail));
  Result := Finish(Root);
end;

function SdkResultLine(const Subtype, ErrText, FinalText: string;
  DurationMs: Int64; Turns: Integer; const Usage, Total: TSdkUsage;
  const Models: TModelUsageList): string;
var
  Root, Arr, Ent: TJson;
  I: Integer;
begin
  Root := TJson.NewObj;
  Root.AddStr('type', 'result');
  Root.AddStr('subtype', Subtype);
  Root.AddBool('is_error', Subtype = 'error');
  Root.AddStr('error', Safe(ErrText));
  Root.AddStr('result', Safe(FinalText));
  Root.AddNum('duration_ms', DurationMs);
  Root.AddNum('num_turns', Turns);
  Root.Add('usage', UsageJson(Usage));
  Root.Add('total_usage', UsageJson(Total));
  { Always present, even empty and even with one row: a driver that has to
    branch on a missing key is a driver that will get it wrong on the run
    where nothing was routed. }
  Arr := TJson.NewArr;
  for I := 0 to High(Models) do
  begin
    Ent := TJson.NewObj;
    Ent.AddStr('model', Safe(Models[I].Model));
    Ent.AddNum('tokens_in', Models[I].TokensIn);
    Ent.AddNum('tokens_out', Models[I].TokensOut);
    Ent.AddNum('cache_read', Models[I].CacheRead);
    Ent.AddNum('cache_write', Models[I].CacheWrite);
    Arr.Push(Ent);
  end;
  Root.Add('models', Arr);
  { Deliberately no total_cost_usd.  This program has no price table - /cost
    reports tokens for the same reason - and a hardcoded one drifts into a
    lie the first time a model is repriced.  A driver that wants money
    multiplies the token counts by numbers it can see. }
  Result := Finish(Root);
end;

{ ---------------------------------------------------------------- plumbing -- }

procedure SdkEmit(const Line: string);
begin
  if Assigned(SdkSink) then
  begin
    SdkSink(Line);
    Exit;
  end;
  { A single Write of the line and its terminator.  FPC does not translate
    #10 to CRLF on a redirected handle, so this is byte-exact NDJSON, and the
    flush is what makes a driver reading line by line see the turn happen
    rather than receive it all at the end. }
  Write(System.Output, Line + #10);
  Flush(System.Output);
end;

function SdkReadLine(out S: string): Boolean;
begin
  S := '';
  if Assigned(SdkSource) then Exit(SdkSource(S));
  if EOF(System.Input) then Exit(False);
  ReadLn(System.Input, S);
  Result := True;
end;

function SdkNewSessionId: string;
var
  G: TGUID;
begin
  if CreateGUID(G) <> 0 then
  begin
    { A machine that cannot mint a GUID still gets a distinguishable id
      rather than an empty field. }
    Result := LowerCase(Format('%.8x-0000-0000-0000-%.12x',
      [Cardinal(GetTickCount64), Int64(GetTickCount64)]));
    Exit;
  end;
  Result := LowerCase(Copy(GUIDToString(G), 2, 36));
end;

function SdkParseFormat(const S: string; out F: TSdkFormat): Boolean;
begin
  Result := True;
  F := sfText;
  if S = 'text' then F := sfText
  else if S = 'json' then F := sfJson
  else if S = 'stream-json' then F := sfStreamJson
  else Result := False;
end;

function SdkSnapshotUsage(A: TAgent): TSdkUsage;
begin
  Result.InputTokens := A.TokensIn;
  Result.OutputTokens := A.TokensOut;
  Result.CacheWriteTokens := A.CacheWriteTokens;
  Result.CacheReadTokens := A.CacheReadTokens;
end;

{ ------------------------------------------------------------------ driver -- }

var
  { The run in progress.  Module state rather than a parameter because the
    agent's hooks are plain procedures, which is the same reason uTools keeps
    ActiveAgent - and it is honest about the one-session-per-process limit
    that uTools' own globals already impose. }
  RunOpts: TSdkOptions;
  PermSeq: Integer = 0;
  { Set by OneTurn when a save failed, read by SdkRun for the exit code.  It
    is not the turn's own result: the answer is in the result line either way,
    and telling a driver its work was lost when the text is right there would
    be a worse lie than the silence it replaces. }
  SaveFailed: Boolean = False;

function SdkDefaultOptions: TSdkOptions;
begin
  Result.Format := sfText;
  Result.StreamInput := False;
  Result.SessionId := '';
  Result.PermissionMode := '';
  Result.AskViaDriver := False;
  Result.SessionFile := '';
  Result.Resume := False;
  Result.Resumed := False;
  Result.ResumedMessages := 0;
end;

function SdkResumeInto(A: TAgent; const Path: string;
  out Msgs: Integer; out Err: string): Boolean;
begin
  Msgs := 0;
  Err := '';
  Result := True;
  if (A = nil) or (Path = '') then Exit;
  { Absence is not corruption.  The first iteration of a subprocess-per-turn
    loop has no file, and requiring the driver to omit --resume on turn one
    would be a special case in every script that uses this.  Asked with
    FileExists rather than by sniffing LoadSession's reason string, because a
    reason is prose and prose gets reworded. }
  if not FileExists(Path) then Exit;
  Result := A.LoadSession(Path, Err);
  if Result then Msgs := A.MessageCount;
end;

procedure HookText(const S: string);
begin
  SdkEmit(SdkDeltaLine('text', S));
end;

procedure HookThinking(const S: string);
begin
  SdkEmit(SdkDeltaLine('thinking', S));
end;

procedure HookNotice(const S: string);
begin
  SdkEmit(SdkNoticeLine(S));
end;

procedure HookToolInput(const Id, Name, InputJson: string);
begin
  SdkEmit(SdkToolUseLine(Id, Name, InputJson));
end;

procedure HookToolDone(const Id, Name, Output: string; IsError: Boolean);
begin
  SdkEmit(SdkToolResultLine(Id, Name, Output, IsError));
end;

{ The driver answers on the user's behalf.  Every ambiguity denies: an
  unknown verb, a mismatched id, a line that is not JSON, a message that is
  not a permission_response, and end of stream.  There is no default-allow
  branch in here at all, which is the same rule the console prompt follows
  when its own read fails. }
function AskThroughDriver(const Title, Detail: string): TPermission;
var
  Id, Line, Behavior: string;
  Doc: TJson;
begin
  Result := pmDeny;
  Inc(PermSeq);
  Id := Format('perm_%d', [PermSeq]);
  SdkEmit(SdkPermissionRequestLine(Id, Title, Title, Detail));
  if not SdkReadLine(Line) then Exit;
  Doc := JsonParse(Line);
  if Doc = nil then Exit;
  try
    if Doc.Kind <> jkObj then Exit;
    if Doc.Str('type') <> 'permission_response' then Exit;
    if Doc.Str('id') <> Id then Exit;
    Behavior := Doc.Str('behavior');
    if Behavior = 'allow' then Result := pmAllowOnce
    else if Behavior = 'allow_always' then Result := pmAllowAlways;
  finally
    Doc.Free;
  end;
end;

{ The text of a driver's user message.  Content may be a plain string or the
  API's array of blocks, because a driver that already speaks to Anthropic
  will hand over whichever shape it has to hand. }
function UserTextOf(Doc: TJson): string;
var
  Msg, C, B: TJson;
  I: Integer;
begin
  Result := '';
  Msg := Doc.Find('message');
  if (Msg <> nil) and (Msg.Kind = jkObj) then
    C := Msg.Find('content')
  else
    C := Doc.Find('content');
  if C = nil then Exit(Doc.Str('text'));
  if C.Kind = jkStr then Exit(C.AsString);
  if C.Kind <> jkArr then Exit;
  for I := 0 to C.Count - 1 do
  begin
    B := C.Item(I);
    if (B <> nil) and (B.Kind = jkObj) and (B.Str('type', 'text') = 'text') then
      Result := Result + B.Str('text');
  end;
end;

{ Honours image blocks in a driver's user message, which UserTextOf drops on
  the floor because it flattens content to a string.  Returns how many were
  queued.  The same four media types and the same caps as every other entry
  point - a driver is not more trusted than a keyboard, so the base64 charset
  and the decoded size are checked before anything reaches the transcript. }
function AttachUserImages(A: TAgent; M: TJson): Integer;
var
  Msg, C, B, Src: TJson;
  I: Integer;
  Media, Data, Err: string;
begin
  Result := 0;
  if (A = nil) or (M = nil) then Exit;
  Msg := M.Find('message');
  if (Msg <> nil) and (Msg.Kind = jkObj) then
    C := Msg.Find('content')
  else
    C := M.Find('content');
  if (C = nil) or (C.Kind <> jkArr) then Exit;
  for I := 0 to C.Count - 1 do
  begin
    B := C.Item(I);
    if (B = nil) or (B.Kind <> jkObj) or (B.Str('type') <> 'image') then
      Continue;
    Src := B.Find('source');
    if (Src = nil) or (Src.Kind <> jkObj) then Continue;
    { base64 only.  A url source would have the API fetch a host this program
      cannot vet, and a file_id needs a beta header and an upload round trip. }
    if Src.Str('type') <> 'base64' then Continue;
    Media := Src.Str('media_type');
    Data := Src.Str('data');
    if Data = '' then Continue;
    if A.AttachImage(Media, Data, Round(B.Num('width')), Round(B.Num('height')),
         Err) then
      Inc(Result)
    else
      SdkEmit(SdkErrorLine('image not attached: ' + Err));
  end;
end;

{ One turn: echo the prompt, run it, and emit exactly one result.  The
  per-turn cost is the difference of two snapshots, so turn fifty reports what
  turn fifty spent rather than the running total. }
function OneTurn(A: TAgent; const Prompt: string): Boolean;
var
  Before, After, Delta: TSdkUsage;
  T0: QWord;
  Err, Subtype, SaveErr: string;
begin
  Before := SdkSnapshotUsage(A);
  T0 := GetTickCount64;
  if RunOpts.Format = sfStreamJson then SdkEmit(SdkUserLine(Prompt));
  Err := '';
  Result := A.Send(Prompt, Err);
  After := SdkSnapshotUsage(A);
  Delta.InputTokens := After.InputTokens - Before.InputTokens;
  Delta.OutputTokens := After.OutputTokens - Before.OutputTokens;
  Delta.CacheWriteTokens := After.CacheWriteTokens - Before.CacheWriteTokens;
  Delta.CacheReadTokens := After.CacheReadTokens - Before.CacheReadTokens;
  if not Result then Subtype := 'error'
  else if A.TurnWasCancelled then Subtype := 'cancelled'
  else Subtype := 'success';

  { Before the result line, and that ordering is the contract: the result line
    is the driver's signal that the transcript is on disk, so a
    subprocess-per-turn agent may spawn the next process the moment it reads
    one.  Saved whatever the subtype, matching the REPL's unconditional save -
    Send has already trimmed an unanswered question and dropped unanswered
    tool calls, so even a failed turn leaves a legal transcript. }
  if RunOpts.SessionFile <> '' then
    if not A.SaveSession(RunOpts.SessionFile, SaveErr) then
    begin
      SdkEmit(SdkErrorLine('session not saved: ' + SaveErr));
      SaveFailed := True;
    end;

  SdkEmit(SdkResultLine(Subtype, Err, A.LastAssistantText,
    Int64(GetTickCount64 - T0), A.TurnCount, Delta, After, A.UsageByModel));
end;

function SdkRun(A: TAgent; const Opts: TSdkOptions;
  const FirstPrompt: string; out Err: string): Integer;
var
  Line, MsgType, Text: string;
  Doc: TJson;
  AnyFail: Boolean;
  Imgs, Msgs: Integer;
  Zero: TSdkUsage;
begin
  Err := '';
  RunOpts := Opts;
  PermSeq := 0;
  AnyFail := False;
  SaveFailed := False;

  { The console hooks are replaced wholesale, nils included: uTerm is never
    reached in this mode, and a leftover renderer writing prose between two
    JSON lines would break the frame for good. }
  A.OnText := nil;
  A.OnThinking := nil;
  A.OnToolStart := nil;
  A.OnToolUseBegin := nil;
  A.OnToolArg := nil;
  A.OnToolResult := nil;
  A.OnNotice := nil;
  A.OnToolInput := nil;
  A.OnToolDone := nil;
  if Opts.Format = sfStreamJson then
  begin
    A.OnText := @HookText;
    A.OnThinking := @HookThinking;
    A.OnNotice := @HookNotice;
    A.OnToolInput := @HookToolInput;
    A.OnToolDone := @HookToolDone;
  end;

  { Delegation is only offered when there is a driver on stdin to delegate
    to.  Everything else runs the print-mode rule unchanged: nobody to ask
    means every gated tool refuses, in band, with a normal tool_result. }
  if Opts.StreamInput and Opts.AskViaDriver then
    A.Ask := @AskThroughDriver
  else
    A.Ask := nil;

  { The load happens before the init line so that line describes the session
    that is actually starting rather than the one that was asked for. }
  RunOpts.Resumed := False;
  RunOpts.ResumedMessages := 0;
  if RunOpts.Resume then
    if not SdkResumeInto(A, RunOpts.SessionFile, Msgs, Err) then
    begin
      { Not "start fresh".  A script that asked to continue a conversation and
        silently got a blank one does work on absent context, and the next
        save would overwrite the file it could not read.  The frame is kept
        whole in each format: stream-json opens with system and ends with
        result, json emits exactly the one line it always emits. }
      FillChar(Zero, SizeOf(Zero), 0);
      if Opts.Format = sfStreamJson then
      begin
        SdkEmit(SdkInitLine(RunOpts, A.Model, A.EffectiveModel(mrMain)));
        SdkEmit(SdkErrorLine('cannot resume ' + RunOpts.SessionFile +
          ': ' + Err));
      end;
      SdkEmit(SdkResultLine('error', Err, '', 0, A.TurnCount, Zero,
        SdkSnapshotUsage(A), A.UsageByModel));
      Exit(2);
    end
    else
    begin
      RunOpts.Resumed := Msgs > 0;
      RunOpts.ResumedMessages := Msgs;
    end;

  { Once, for the whole run.  A driver reads this line to learn what this
    build can do before it sends anything. }
  if Opts.Format = sfStreamJson then
    SdkEmit(SdkInitLine(RunOpts, A.Model, A.EffectiveModel(mrMain)));

  if Trim(FirstPrompt) <> '' then
    if not OneTurn(A, FirstPrompt) then AnyFail := True;

  if Opts.StreamInput then
    while SdkReadLine(Line) do
    begin
      if Trim(Line) = '' then
      begin
        SdkEmit(SdkErrorLine('empty driver message'));
        Continue;
      end;
      Doc := JsonParse(Line);
      if Doc = nil then
      begin
        SdkEmit(SdkErrorLine('driver message is not JSON'));
        Continue;
      end;
      try
        if Doc.Kind <> jkObj then
        begin
          SdkEmit(SdkErrorLine('driver message is not an object'));
          Continue;
        end;
        MsgType := Doc.Str('type');
        if MsgType = '' then
          SdkEmit(SdkErrorLine('driver message has no type'))
        else if MsgType = 'user' then
        begin
          Text := UserTextOf(Doc);
          { Images are queued before the turn so AppendUserText carries them
            in the same message as the prose.  An image-only message is a
            legal turn, so the blank test has to account for one. }
          Imgs := AttachUserImages(A, Doc);
          if (Trim(Text) = '') and (Imgs = 0) then
            SdkEmit(SdkErrorLine('user message has no content'))
          else if not OneTurn(A, Text) then
            AnyFail := True;
        end
        else if MsgType = 'interrupt' then
          { Reading stdin while blocked on the network would need a thread,
            and this program has none.  Saying so is better than accepting
            the message and ignoring it. }
          SdkEmit(SdkErrorLine(
            'interrupt is not supported; cancel with Ctrl+C'))
        else
          SdkEmit(SdkErrorLine('unknown driver message type: ' + Safe(MsgType)));
      finally
        Doc.Free;
      end;
    end;

  if AnyFail or SaveFailed then Result := 1 else Result := 0;
end;

{ ------------------------------------------------------------------ facade -- }

constructor TSdkSession.Create(const Root, ApiKey, AModel: string);
begin
  inherited Create;
  { The ordering that pasclaude.lpr performs by hand, in the one order that
    works: the root first, because the ignore rules and every path guard read
    it, and the system prompt after, because it names the root. }
  { Before the root, so one session in a process cannot inherit another's
    working directories - they are a grant made to a session, not a property
    of the machine. }
  uTools.ClearWorkingDirs;
  uTools.RootDir := Root;
  { Deny rules, and nothing else out of the approvals store.  They are the one
    kind of rule it is safe to hand an embedder unasked, because they are the
    one kind that cannot grant anything: FAgent.Ask stays nil below, so this
    session inherits the user's refusals and none of their approvals. }
  uTools.LoadDenyRules(uTools.ApprovalsPath, uTools.GlobalDenyPath);
  uTools.LoadIgnoreRules;
  FAgent := TAgent.Create(ApiKey, AModel, SdkFullSystem);
  FAgent.Ask := nil;
end;

destructor TSdkSession.Destroy;
begin
  FAgent.Free;
  { A background job outlives the agent that started it: its child process is
    real and holds a handle on a spool file.  Nobody else is going to reap
    them in an embedder. }
  uTools.ClearJobs;
  inherited Destroy;
end;

function TSdkSession.Ask(const Prompt: string; out Reply, Err: string): Boolean;
begin
  Reply := '';
  Result := FAgent.Send(Prompt, Err);
  if Result then Reply := FAgent.LastAssistantText;
end;

end.
