{ uHooks - user commands that pasclaude runs at fixed points in a turn.

  Three things live here and nothing else: a child-process primitive with a
  deadline, the hook table loaded from .pasclaude\hooks.json, and the dispatch
  that turns a hook's exit code into a decision.  The unit sits below uTools so
  the tool layer can fire it, which is also why it may not know what a tool is:
  a hook call arrives as a THookCall record and leaves as a THookOutcome, and
  the meaning of "blocked" is decided by whoever fired it.

  Stdin is a FILE, not a pipe, and that is the whole safety argument for the
  transport.  uTools already records why anonymous pipes were rejected for
  detached children - an unread pipe fills and deadlocks the writer forever -
  and a hook makes the writer us.  Measured before this was written: a 200 KB
  payload handed to a child that never reads a byte of it completes at once
  through a file handle, where a pipe stalls at the buffer size with no drain
  loop possible, because the parent is the only thread there is.  Stdout and
  stderr both land on a second file, which is read back after the child exits.
  No writer thread, no PeekNamedPipe, no overlapped I/O, no loop that is
  "correct only while somebody is blocking on it".

  The other measured facts behind the contract: exit code 2 propagates through
  cmd.exe intact; stderr merges into the spool; a 30-second ping is killed at a
  1500 ms deadline; 840 KB of output comes back whole, so the cap is on the
  read and not on the write; and a nonexistent program exits 1 through cmd.exe,
  not 2.  That last one is why "any nonzero blocks" is not the rule: under it a
  mistyped hook command would silently deny every tool call in the project and
  the user would have no way to find out why. }
unit uHooks;

{$mode objfpc}{$H+}

interface

uses SysUtils, Classes, Windows, uJson, uRegex;

type
  { The five events this program has an honest place to fire.  SessionEnd,
    SubagentStop, PreCompact and Notification are deliberately absent - there
    is no firing point for them that is not a lie - and the loader names them
    when it sees them, so a config pasted in from elsewhere says out loud what
    pasclaude will not do with it rather than silently doing nothing. }
  THookEvent = (heNone, hePreTool, hePostTool, heUserPrompt, heStop,
                heSessionStart);

  { What the firing site knows.  ToolInput is borrowed and never freed here. }
  THookCall = record
    Event: THookEvent;
    ToolName: string;
    ToolInput: TJson;
    Prompt: string;
    ResultText: string;
    ResultIsError: Boolean;
    StopActive: Boolean;
  end;

  THookOutcome = record
    Blocked: Boolean;        { exit 2, or a decision of "deny" }
    Allowed: Boolean;        { a decision of "allow" - advisory only }
    Text: string;            { reason or context; UTF-8, capped }
    Ran, Failed: Integer;
  end;

  THookNotice = procedure(const Msg: string);

  { One FINISHED fire, in fields, for whoever is watching this session from
    outside.  Deliberately NOT merged into THookNotice, which it superficially
    resembles: a notice is one sentence about a hook that went wrong, written
    for a person, where this is the outcome of a fire that worked, and its
    consumer is a parser.  A driver told "hook exited 3 and was ignored" can
    print it; a driver told Blocked cannot mistake a refusal for a comment.

    Pushed down rather than reached for, because the ladder runs the other
    way: this unit sits below uTools and cannot see uSdk, which is where the
    line format lives.  Same shape as OnHookNotice and HookRootDir above it. }
  THookReport = procedure(const Event, ToolName, Detail: string;
    Blocked: Boolean);

  { Which of the two files an entry came from.  There are exactly two and
    there will not be a third: a hook is executable configuration, and every
    additional place one can arrive from is another place somebody has to be
    told about.  The order of the enumeration is the load order and the firing
    order, which is not a coincidence - see LoadHooks. }
  THookScope = (hsUser, hsProject);

const
  HookDefaultTimeoutMs = 10000;
  HookMinTimeoutMs     = 500;
  HookMaxTimeoutMs     = 60000;
  { What comes back from a hook.  It reaches the model at SessionStart and in
    a tool result, so it is a prompt-sized budget, not a log-sized one. }
  MaxHookOutBytes      = 16 * 1024;
  { What goes in.  A tool_input over this is replaced wholesale rather than
    truncated: half a JSON value is not JSON, and a hook that cannot parse its
    own stdin is worse off than one told plainly that the value was omitted. }
  MaxHookInBytes       = 64 * 1024;
  MaxHooksPerEvent     = 8;
  MaxHookEntries       = 32;
  { Per match, so one hostile matcher cannot spend the session.  uRegex is a
    Thompson NFA, so (a+)+$ is not expressible as a hang here - the budget is
    the second line of defence, not the first. }
  HookMatchBudget      = 100000;
  HooksFileName        = 'hooks.json';
  { One file name, two homes: <root>\.pasclaude\hooks.json and
    %USERPROFILE%\.pasclaude\hooks.json.  The directory name is a constant for
    the same reason HookTrustKey is - it is now spelled in two path builders
    instead of one, and two copies of a literal drift. }
  HookStateDirName     = '.pasclaude';
  HookTmpDirName       = 'tmp';
  { The key this feature's approval is recorded under in permissions.json's
    "trusted" object.  Named here because uTools writes it and the host reads
    it, and two copies of a literal drift. }
  HookTrustKey         = 'hooks.json';

var
  { False by default: no unattended run may execute this project's hooks.
    Same shape and same argument as uGitHub.GitHubAllowed - the host sets it
    True on the INTERACTIVE path only, so a wiring mistake fails closed.

    It exists because the guard it replaces was `if not PrintMode`, which was
    true of exactly one unattended mode and missed the other four.  --status,
    --doctor and both --ci verbs run the whole of startup and are refused -p
    at the argument parser, so they arrived at the hooks block as "not print
    mode" and would load and FIRE .pasclaude\hooks.json out of whatever tree
    the current directory happened to be.  In CI that tree is the checked-out
    pull request head, the trust question has nobody to answer it, and what
    happened next depended on how the runner attached stdin - allow, deny or
    block until the job timed out.  Hooks are also the one thing the CI deny
    floor cannot cover: this unit sits below uTools and cannot see a rule.

    A flag here rather than a wider condition at the one call site because
    FireHooks has three other firing sites and /hooks another two, and every
    one of them is now gated by the same byte. }
  HooksAllowed: Boolean = False;

  { One line to the user when a hook fails or a matcher gives up.  Nil is
    silence, not an error - the same shape uTools uses for MCP progress. }
  OnHookNotice: THookNotice = nil;

  { Who hears about a fire that ran something.  Nil is silence and is the
    default, which is what keeps the console out of this: the REPL never sets
    it, so a person sees exactly the output they saw before - the hook's words
    in the tool result and a notice when one misbehaves - and nothing new.
    uSdk.SdkInstallHookReporter is the only writer, and it points this at the
    protocol emitter for stream-json and clears it for every other format.

    It is a var and not a parameter for the same reason OnHookNotice is: the
    five sites that fire hooks are spread across uTools and the host, none of
    them knows what a driver is, and threading a callback through RunTool
    would have made the tool layer carry a fact about an output format. }
  OnHookFired: THookReport = nil;

  { The session root, supplied from above because the ladder runs the other
    way: this unit may not know that uTools exists, so uTools' initialization
    hands it a way to ask.  Nil falls back to the current directory, which is
    what the root is at startup anyway. }
  HookRootDir: function: string = nil;

{ True when THIS PROJECT's .pasclaude\hooks.json exists and is a file the
  project actually owns.  Distinct from HooksEnabled: a file the user refused
  is configured and not enabled, and /hooks says so.

  It stays the PROJECT question, deliberately, because it is what gates the
  trust prompt - the host asks about a project file and about nothing else.
  When the session root IS the home directory the two paths name one file, and
  that file is the USER's: ProjectHooksAreTheUsers makes this False there, so
  the host never asks a question whose answer it would then ignore.  Anything
  that only wants to know "are there hooks anywhere" wants AnyHooksConfigured;
  asking this one for that is how a display ends up denying what is running. }
function HooksConfigured: Boolean;
function HooksFilePath: string;

{ %USERPROFILE%\.pasclaude\hooks.json - the user's own hooks, which apply to
  every project they open.  '' when %USERPROFILE% is unset, which is not an
  error: it means there are none, and it is also how a test process gets a
  deterministic answer instead of the developer's real home directory. }
function UserHooksFilePath: string;
function UserHooksConfigured: Boolean;

{ True when the session root IS the home directory, so HooksFilePath and
  UserHooksFilePath are one file.  Consulted by HooksConfigured, LoadHooks and
  the /hooks panel, and it has to be all three or they disagree: loading it
  twice would double-fire every hook, letting the project branch claim it would
  prompt somebody about their own file, and a panel that only asked one of them
  would print the same path as loaded and as absent.  "The same directory" is
  decided against the resolved spelling, not the typed one - see the body. }
function ProjectHooksAreTheUsers: Boolean;

{ The question a DISPLAY asks: is there a hook file of either scope.  A
  diagnostic that reported "none configured" while a user hook was firing
  would be denying what is running, which is the one thing it must never do. }
function AnyHooksConfigured: Boolean;

{ 'user' | 'project'.  One spelling, so a panel, a /doctor line and a test all
  compare against the same two words. }
function HookScopeName(S: THookScope): string;

{ FNV-1a 64 over the PROJECT file's bytes, lowercase hex.  A change detector,
  not a defence against somebody who can already edit permissions.json: what it
  buys is that editing hooks.json re-asks, because an "always" that survived
  the text changing under it would be an approval of something never read.

  Project-only, and that is the whole shape of the asymmetry.  The user's file
  is never the subject of a question, so it has no fingerprint: a recorded
  trust for a question nobody asked would be a lie sitting in permissions.json
  claiming somebody consented to bytes they were never shown. }
function HookFingerprint: string;

{ One line per loaded hook: event, matcher and command. }
function HookSummary: string;

{ The loaded table, one entry at a time.  Read-only and display-only: they
  exist so /doctor can ask whether each hook's PROGRAM resolves on PATH
  without running any of them, and without splitting HookSummary's padded
  columns back apart - a command containing the arrow would have made that
  parse wrong exactly where the report needed to be right. }
function HookEntryCount: Integer;
function HookCommandAt(I: Integer): string;      { '' when out of range }
{ 'user' or 'project'; '' when out of range.  /doctor needs it because telling
  somebody to fix a command in this project's hooks.json when the command came
  from their home directory is advice that cannot work. }
function HookScopeAt(I: Integer): string;

{ The same rendering, straight off a file that has not been loaded.  It exists
  because the approval prompt has to show what the file says before the file is
  trusted, and trusting it in order to describe it would be the wrong order.
  It parses for display only: nothing is compiled, nothing is registered, and
  it renders per entry from the file - never from anything a hook or the
  transcript produced. }
function HookSummaryOf(const Path: string): string;

{ Reads and compiles the table from BOTH scopes.  Trusted is the answer to the
  question about the PROJECT file and has never meant anything else; the user's
  own file is loaded whatever it says.  HooksAllowed gates the whole call, both
  scopes, first and alone.  Notes carries one line per thing either file asked
  for that will not happen, and every line from the user's file names it. }
procedure LoadHooks(Trusted: Boolean; out Notes: string);
procedure ClearHooks;
function HooksEnabled: Boolean;
function HookCount(Ev: THookEvent): Integer;

{ A zeroed call for Ev.  A record with a stale ToolInput pointer in it is the
  kind of bug that only shows up under a hook nobody runs, so there is one
  place that builds them. }
function HookCall(Ev: THookEvent): THookCall;

{ Runs every hook registered for Call.Event, in file order, stopping at the
  first block.  Never raises: a hook is a foreign program and the tool layer
  above has no catch.  Reports the outcome through OnHookFired when anything
  actually ran, which is how a driver learns a hook happened without having to
  read it back out of the tool result it changed. }
function FireHooks(const Call: THookCall): THookOutcome;

{ The primitive.  Returns the child's exit code, or -1 when the spawn itself
  failed with the reason in Output.  StdinText is handed over as a file. }
function RunChild(const Cmd, StdinText, WorkDir: string;
  TimeoutMs, MaxOut: Integer; out Output: string;
  out TimedOut: Boolean): Integer;

{ The name a config file uses for Ev, and the reverse.  heNone means the name
  is not one this program fires. }
function HookEventName(Ev: THookEvent): string;
function HookEventFromName(const S: string): THookEvent;

implementation

uses uSandbox;

{ The job-object record and its four kernel32 imports used to be declared here
  verbatim, a deliberate second copy of uTools' because the ladder forbids
  this unit from importing uTools.  uSandbox is a leaf below all three, so the
  copy is now one shared declaration - which is what the ladder wanted all
  along, and the only direction the duplication could ever have been resolved
  in.  A hook is still a one-shot child with a deadline and still owns its own
  lifecycle; only the process creation is shared. }
const
  HookKillWaitMs = 2000;

type
  THookEntry = record
    Event: THookEvent;
    Matcher: string;
    Command: string;
    TimeoutMs: Integer;
    Scope: THookScope;   { which file it came from; display and /doctor only }
    Rx: TRegex;          { nil matches everything, by absence or by design }
  end;

var
  Hooks: array of THookEntry;
  HookSeq: Integer = 0;
  Loaded: Boolean = False;

procedure Notice(const Msg: string);
begin
  if Assigned(OnHookNotice) then OnHookNotice(Msg);
end;

function RootPath: string;
begin
  if Assigned(HookRootDir) then Result := HookRootDir()
  else Result := GetCurrentDir;
  if Result = '' then Result := GetCurrentDir;
  Result := ExcludeTrailingPathDelimiter(Result);
end;

function StateDir: string;
begin
  Result := IncludeTrailingPathDelimiter(RootPath) + HookStateDirName + PathDelim;
end;

function HooksFilePath: string;
begin
  Result := StateDir + HooksFileName;
end;

function UserHooksFilePath: string;
var
  Home: string;
begin
  Result := '';
  { SysUtils. qualified deliberately, the same note ApprovalsPath, GlobalDenyPath
    and SkillsDirUser each carry: the Windows unit's raw API of this name is in
    scope here and shadows it.  Reading the environment is not reaching upward
    through the ladder - uAuth and uTools read it at the same altitude, and the
    one fact this unit genuinely cannot know, the session root, still arrives
    the way it always did, through HookRootDir. }
  Home := Trim(SysUtils.GetEnvironmentVariable('USERPROFILE'));
  if Home = '' then Exit;
  Result := IncludeTrailingPathDelimiter(Home) + HookStateDirName + PathDelim +
    HooksFileName;
end;

function UserHooksConfigured: Boolean;
begin
  Result := (UserHooksFilePath <> '') and FileExists(UserHooksFilePath);
end;

{ FPC 3.2.2's Windows unit declares neither, and both are ordinary kernel32
  exports.  uTools carries the same pair for its deny rules, which is where the
  need was first measured; this unit is BELOW uTools and cannot call into it,
  so the two declarations sit in two files rather than one being imported
  upward.  Duplicating four lines of external declaration was judged the
  cheaper of the two evils - the alternative is a canonicaliser pushed down
  from pasclaude.lpr as a function variable, which is the HookRootDir shape and
  is reserved for facts this unit genuinely cannot compute.  A path is not one
  of those: it is Win32, and Win32 is already in this unit's uses clause. }
const
  FILE_FLAG_BACKUP_SEMANTICS_ = $02000000;

function GetFinalPathNameByHandleW(H: THandle; Buf: PWideChar;
  Cch, Flags: DWORD): DWORD; stdcall; external 'kernel32'
  name 'GetFinalPathNameByHandleW';
function GetLongPathNameW(Src, Buf: PWideChar; Cch: DWORD): DWORD; stdcall;
  external 'kernel32' name 'GetLongPathNameW';

{ The long, junction-free, filesystem-cased spelling of an EXISTING directory,
  or ExpandFileName's answer when Windows will not give one up.  Directories
  and not the two hooks.json paths themselves, deliberately: the file may not
  exist on either side while the directory containing it always does, and both
  paths append the identical .pasclaude\hooks.json tail, so the directories
  answer exactly the same question and answer it on names the API can resolve. }
function ResolvedDir(const D: string): string;
var
  W, Out_: UnicodeString;
  H: THandle;
  N: DWORD;
begin
  Result := ExcludeTrailingPathDelimiter(ExpandFileName(D));
  if Result = '' then Exit;
  W := UnicodeString(Result);
  SetLength(Out_, 1024);
  H := CreateFileW(PWideChar(W), 0, FILE_SHARE_READ or FILE_SHARE_WRITE or
    FILE_SHARE_DELETE, nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS_, 0);
  if H <> INVALID_HANDLE_VALUE then
  begin
    N := GetFinalPathNameByHandleW(H, PWideChar(Out_), Length(Out_), 0);
    CloseHandle(H);
    if (N > 0) and (N < DWORD(Length(Out_))) then
    begin
      SetLength(Out_, N);
      Result := string(Out_);
      { The API answers in \\?\ form, which nothing else in this program
        spells that way.  Normalised here so a caller comparing two of these
        never has one prefixed and the other not. }
      if Copy(Result, 1, 8) = '\\?\UNC\' then
        Result := '\\' + Copy(Result, 9, MaxInt)
      else if Copy(Result, 1, 4) = '\\?\' then
        Result := Copy(Result, 5, MaxInt);
      Exit(ExcludeTrailingPathDelimiter(Result));
    end;
    SetLength(Out_, 1024);
  end;
  { No handle - the directory is gone, or held in a way that refuses one.
    This expands an 8.3 name without opening anything, but it does not follow
    a junction; a wrong answer here is the OLD answer, which is the same
    failure the compare had before any of this was written. }
  N := GetLongPathNameW(PWideChar(W), PWideChar(Out_), Length(Out_));
  if (N > 0) and (N < DWORD(Length(Out_))) then
  begin
    SetLength(Out_, N);
    Result := ExcludeTrailingPathDelimiter(string(Out_));
  end;
end;

function ProjectHooksAreTheUsers: Boolean;
var
  Home: string;
begin
  { ExpandFileName ALONE was what stood here, and it was not enough.  It
    normalises a relative root and a trailing delimiter and nothing else: a
    junction, a SUBST drive or an 8.3 short name reaches the same directory by
    a second spelling, the compare says the two files are different, and the
    ONE physical hooks.json is then loaded twice - once as the user's with no
    prompt, once as the project's with one - so every hook in it fires twice
    and the user is asked to trust their own file.  Demonstrated with a
    junction beside a real home directory before this was changed, so it is a
    reproduction rather than a worry.

    Compared as DIRECTORIES because that is what Windows can canonicalise: the
    home directory and the session root both exist by the time anything asks,
    where either hooks.json may not.  The tail both paths append is identical,
    so the two questions are the same question.  Still case-insensitive on top,
    because C:\Users\x and C:\USERS\X are one directory even after the API has
    had its say and the fallback path may not have normalised the case. }
  Home := Trim(SysUtils.GetEnvironmentVariable('USERPROFILE'));
  if Home = '' then Exit(False);
  Result := CompareText(ResolvedDir(Home), ResolvedDir(RootPath)) = 0;
end;

{ The scratch directory for one hook call's two files.  Like every other path
  under the state directory this bypasses SafePath, because SafePath refuses
  everything there by design - and that refusal is exactly what keeps the model
  from reading a payload built about its own tool call. }
function TmpDir: string;
begin
  Result := StateDir + HookTmpDirName + PathDelim;
  ForceDirectories(Result);
end;

function HookEventName(Ev: THookEvent): string;
begin
  case Ev of
    hePreTool: Result := 'PreToolUse';
    hePostTool: Result := 'PostToolUse';
    heUserPrompt: Result := 'UserPromptSubmit';
    heStop: Result := 'Stop';
    heSessionStart: Result := 'SessionStart';
  else
    Result := '';
  end;
end;

function HookEventFromName(const S: string): THookEvent;
var
  E: THookEvent;
begin
  for E := hePreTool to heSessionStart do
    if SameText(S, HookEventName(E)) then Exit(E);
  Result := heNone;
end;

{ ------------------------------------------------------------ the child -- }

function RunChild(const Cmd, StdinText, WorkDir: string;
  TimeoutMs, MaxOut: Integer; out Output: string;
  out TimedOut: Boolean): Integer;
var
  SA: SECURITY_ATTRIBUTES;
  SI: STARTUPINFOA;
  PI: PROCESS_INFORMATION;
  hJob, hIn, hOut: THandle;
  CmdLine, ComSpec, InPath, OutPath, Dir: string;
  Wrote: DWORD;
  Code: DWORD;
  F: TFileStream;
  N: Int64;
  InJob: Boolean;
begin
  Result := -1;
  Output := '';
  TimedOut := False;
  if Trim(Cmd) = '' then
  begin
    Output := 'hook command is empty';
    Exit;
  end;
  if TimeoutMs < HookMinTimeoutMs then TimeoutMs := HookMinTimeoutMs;
  if TimeoutMs > HookMaxTimeoutMs then TimeoutMs := HookMaxTimeoutMs;

  Inc(HookSeq);
  InPath := TmpDir + 'hook-' + IntToStr(HookSeq) + '.in';
  OutPath := TmpDir + 'hook-' + IntToStr(HookSeq) + '.out';
  Dir := WorkDir;
  if Dir = '' then Dir := RootPath;

  try
    hJob := SandboxNewJob;

    FillChar(SA, SizeOf(SA), 0);
    SA.nLength := SizeOf(SA);
    SA.bInheritHandle := True;

    { The payload is written and closed before the child exists, then reopened
      read-only for it to inherit.  A file has no capacity, so handing over
      more than a pipe buffer's worth cannot block anybody, and a hook that
      never reads its stdin costs nothing. }
    hIn := CreateFile(PChar(InPath), GENERIC_WRITE, FILE_SHARE_READ, nil,
      CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if hIn = INVALID_HANDLE_VALUE then
    begin
      if hJob <> 0 then CloseHandle(hJob);
      Output := 'could not write the hook payload: ' +
        SysErrorMessage(GetLastError);
      Exit;
    end;
    if StdinText <> '' then
      WriteFile(hIn, StdinText[1], Length(StdinText), Wrote, nil);
    CloseHandle(hIn);

    hIn := CreateFile(PChar(InPath), GENERIC_READ,
      FILE_SHARE_READ or FILE_SHARE_WRITE, @SA, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL, 0);
    hOut := CreateFile(PChar(OutPath), GENERIC_WRITE,
      FILE_SHARE_READ or FILE_SHARE_WRITE, @SA, CREATE_ALWAYS,
      FILE_ATTRIBUTE_NORMAL, 0);
    if (hIn = INVALID_HANDLE_VALUE) or (hOut = INVALID_HANDLE_VALUE) then
    begin
      if hIn <> INVALID_HANDLE_VALUE then CloseHandle(hIn);
      if hOut <> INVALID_HANDLE_VALUE then CloseHandle(hOut);
      if hJob <> 0 then CloseHandle(hJob);
      Output := 'could not open the hook spool: ' +
        SysErrorMessage(GetLastError);
      Exit;
    end;

    ComSpec := SysUtils.GetEnvironmentVariable('ComSpec');
    if ComSpec = '' then ComSpec := 'cmd.exe';
    { Wrapped in cmd.exe, unlike an MCP server: a hook is a shell line out of
      a config file.  SandboxSpawn takes the finished line and never composes
      one, which is what lets both callers share it. }
    CmdLine := '"' + ComSpec + '" /C ' + Cmd;

    FillChar(SI, SizeOf(SI), 0);
    SI.cb := SizeOf(SI);
    SI.dwFlags := STARTF_USESTDHANDLES;
    SI.hStdInput := hIn;
    SI.hStdOutput := hOut;
    { Merged deliberately: a hook that explains its refusal on stderr has said
      the most useful thing it will say all session, and losing it would leave
      a blocked tool call with no reason attached. }
    SI.hStdError := hOut;
    FillChar(PI, SizeOf(PI), 0);

    if not SandboxSpawn(CmdLine, Dir, SandboxEnvBlock, 0, SI, PI, hJob,
             InJob) then
    begin
      Output := 'could not start the hook: ' + SysErrorMessage(GetLastError);
      if uSandbox.SandboxLevel = slLow then
        Output := Output + ' [sandbox: low]';
      CloseHandle(hIn);
      CloseHandle(hOut);
      if hJob <> 0 then CloseHandle(hJob);
      Exit;
    end;

    { The child holds its own copies; a handle kept here is a handle leaked -
      and worse, an open write handle on the spool makes the read below see a
      file the OS still considers busy. }
    CloseHandle(hIn);
    CloseHandle(hOut);
    CloseHandle(PI.hThread);

    { The child was created suspended, assigned, and only then resumed, so the
      grandchild race this used to document is closed: nothing it starts can
      have started before it was in the job. }

    if WaitForSingleObject(PI.hProcess, TimeoutMs) = WAIT_TIMEOUT then
    begin
      TimedOut := True;
      { The job, not the process: a hook that started a build has children,
        and killing only cmd.exe would leave them holding the spool. }
      if hJob <> 0 then SandboxTerminateJob(hJob, 1)
      else TerminateProcess(PI.hProcess, 1);
      WaitForSingleObject(PI.hProcess, HookKillWaitMs);
    end;

    Code := 0;
    if not GetExitCodeProcess(PI.hProcess, Code) then Code := DWORD(-1);
    Result := Integer(Code);
    CloseHandle(PI.hProcess);
    if hJob <> 0 then CloseHandle(hJob);

    { Read back what it said.  The cap is on the read, so a hook that printed
      a megabyte is not punished for it - the first MaxOut bytes are exactly
      what a person would look at anyway. }
    try
      F := TFileStream.Create(OutPath, fmOpenRead or fmShareDenyNone);
      try
        N := F.Size;
        if N > MaxOut then N := MaxOut;
        if N > 0 then
        begin
          SetLength(Output, N);
          F.ReadBuffer(Output[1], N);
        end;
      finally
        F.Free;
      end;
    except
      { A spool that cannot be read is a hook that said nothing, not a
        failure of the hook: the exit code is the decision. }
      Output := '';
    end;
    Output := Utf8Cut(Output, MaxOut);
  finally
    { A grandchild that escaped the assignment race can hold the spool open
      and make this fail; the stray is swept at the next LoadHooks rather than
      turned into an error nobody can act on. }
    SysUtils.DeleteFile(InPath);
    SysUtils.DeleteFile(OutPath);
  end;
end;

{ ------------------------------------------------------------ the table -- }

function HooksConfigured: Boolean;
begin
  { A file that is both the project's and the user's is the user's - the scope
    that asks nothing.  Reporting it as configured here would make the host
    prompt about a file only the person answering can write. }
  Result := FileExists(HooksFilePath) and not ProjectHooksAreTheUsers;
end;

function AnyHooksConfigured: Boolean;
begin
  Result := HooksConfigured or UserHooksConfigured;
end;

function HookScopeName(S: THookScope): string;
begin
  if S = hsUser then Result := 'user' else Result := 'project';
end;

function HooksEnabled: Boolean;
begin
  { HooksAllowed is re-read here rather than trusted to have been false at
    load time: it is what every firing site and every /hooks display consults,
    so clearing it mid-run turns the feature off everywhere at once. }
  Result := HooksAllowed and Loaded and (Length(Hooks) > 0);
end;

function HookCount(Ev: THookEvent): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(Hooks) do
    if Hooks[I].Event = Ev then Inc(Result);
end;

procedure ClearHooks;
var
  I: Integer;
begin
  for I := 0 to High(Hooks) do
    Hooks[I].Rx.Free;
  SetLength(Hooks, 0);
  Loaded := False;
end;

function ReadWholeFile(const Path: string; out Text: string): Boolean;
var
  F: TFileStream;
begin
  Text := '';
  Result := False;
  if not FileExists(Path) then Exit;
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      if F.Size > 0 then
      begin
        SetLength(Text, F.Size);
        F.ReadBuffer(Text[1], F.Size);
      end;
    finally
      F.Free;
    end;
    Result := True;
  except
    Result := False;
  end;
end;

function HookFingerprint: string;
var
  Text: string;
  H: QWord;
  I: Integer;
begin
  Result := '';
  if not ReadWholeFile(HooksFilePath, Text) then Exit;
  { FNV-1a 64.  Over the bytes, deliberately - a fingerprint of the path would
    never change and would approve every future edit in advance. }
  H := QWord($cbf29ce484222325);
  for I := 1 to Length(Text) do
  begin
    H := H xor QWord(Byte(Text[I]));
    H := H * QWord($100000001b3);
  end;
  Result := LowerCase(IntToHex(H, 16));
end;

{ Sweeps anything a previous run left behind in tmp\.  A hook killed at its
  deadline whose grandchild held the spool leaves a stray file; deleting it
  here rather than at the failure keeps the failure path simple and means the
  directory is tidy by the time anybody looks. }
procedure SweepTmp;
var
  R: TSearchRec;
  Dir: string;
begin
  Dir := TmpDir;
  if FindFirst(Dir + 'hook-*.*', faAnyFile, R) = 0 then
  begin
    repeat
      if (R.Attr and faDirectory) = 0 then
        SysUtils.DeleteFile(Dir + R.Name);
    until FindNext(R) <> 0;
    SysUtils.FindClose(R);
  end;
end;

procedure Note(var Notes: string; const S: string);
begin
  Notes := Notes + S + #10;
end;

{ timeout_ms arrives from a file, so every hostile double is reachable: NaN
  compares false against everything, 1e309 is +Inf and overflows a straight
  Round, and a negative would be a deadline already past.  Clamping on the
  double before it ever becomes an Integer is the only order that is safe. }
function ClampTimeout(D: Double; Present: Boolean): Integer;
begin
  if not Present then Exit(HookDefaultTimeoutMs);
  if not (D >= HookMinTimeoutMs) then Exit(HookMinTimeoutMs);   { NaN lands here }
  if D >= HookMaxTimeoutMs then Exit(HookMaxTimeoutMs);
  Result := Round(D);
end;

{ Where is '' for the project file and ' in <path>' for the user's.  Two files
  feeding one Notes string must each say which one they are, or a user reading
  a complaint about a matcher has no way to know which file to open - and the
  project's wording is unchanged byte for byte when Where is '', which is what
  keeps every existing assertion about these sentences honest. }
procedure LoadEntry(Ent: TJson; Ev: THookEvent; Scope: THookScope;
  const Where: string; var Notes: string);
var
  H: THookEntry;
  Cmd, Matcher, Err: string;
  T: TJson;
begin
  if Length(Hooks) >= MaxHookEntries then Exit;
  if (Ent = nil) or (Ent.Kind <> jkObj) then
  begin
    Note(Notes, HookEventName(Ev) + ': an entry is not an object; ignored' + Where);
    Exit;
  end;
  { Claude Code nests {"matcher":...,"hooks":[{"type":"command",...}]}.  It is
    detected and reported rather than supported: two accepted shapes would be
    two parsers and twice the surface to fuzz, and a user told exactly what to
    write is better served than one whose file half works. }
  T := Ent.Find('hooks');
  if (T <> nil) and (T.Kind = jkArr) then
  begin
    Note(Notes, HookEventName(Ev) + ': this entry uses the nested ' +
      '{"matcher":...,"hooks":[...]} shape; pasclaude wants a flat ' +
      '{"matcher":...,"command":...} entry' + Where);
    Exit;
  end;

  T := Ent.Find('command');
  if (T = nil) or (T.Kind <> jkStr) or (Trim(T.AsString) = '') then
  begin
    Note(Notes, HookEventName(Ev) + ': an entry has no "command" string; ' +
      'ignored' + Where);
    Exit;
  end;
  Cmd := Trim(T.AsString);
  if not uJson.IsValidUtf8(Cmd) then Cmd := uJson.OemToUtf8(Cmd);

  Matcher := '';
  T := Ent.Find('matcher');
  if (T <> nil) and (T.Kind = jkStr) then Matcher := Trim(T.AsString);
  if (Matcher <> '') and not (Ev in [hePreTool, hePostTool]) then
  begin
    Note(Notes, HookEventName(Ev) + ': "matcher" only applies to tool events; ' +
      'ignored for this one' + Where);
    Matcher := '';
  end;

  H.Rx := nil;
  if Matcher <> '' then
    { Compiled once, here.  A pattern that will not compile disables its entry
      with a note at startup rather than surprising somebody mid-tool-call,
      when there would be nothing on screen to connect it to a file. }
    if not TRegex.Compile(Matcher, False, H.Rx, Err) then
    begin
      Note(Notes, HookEventName(Ev) + ': matcher ' + Matcher +
        ' will not compile (' + Err + '); that hook is off' + Where);
      Exit;
    end;

  T := Ent.Find('timeout_ms');
  H.Event := Ev;
  H.Matcher := Matcher;
  H.Command := Cmd;
  H.Scope := Scope;
  H.TimeoutMs := ClampTimeout(Ent.Num('timeout_ms', 0),
    (T <> nil) and (T.Kind = jkNum));

  SetLength(Hooks, Length(Hooks) + 1);
  Hooks[High(Hooks)] := H;
end;

{ One file into the shared table.  Everything from the read to the parse used
  to be the body of LoadHooks and is unchanged apart from Where and Scope: the
  point of splitting it is that two scopes must be two calls to ONE parser,
  because a second parser would be a second set of failure modes for a file
  shape whose failure modes are the whole of what the fuzz suite pins. }
procedure LoadHookFile(const Path, Where: string; Scope: THookScope;
  var Notes: string);
var
  Text, Key: string;
  Root, Map, Arr: TJson;
  I, J, Taken, Seeded: Integer;
  Ev: THookEvent;
begin
  if Path = '' then Exit;
  if not ReadWholeFile(Path, Text) then Exit;

  Root := JsonParse(Text);
  if Root = nil then
  begin
    Note(Notes, HooksFileName + ' is not valid JSON; no hooks are loaded' + Where);
    Exit;
  end;
  try
    if Root.Kind <> jkObj then
    begin
      Note(Notes, HooksFileName + ' should be an object like ' +
        '{"hooks":{"PreToolUse":[...]}}; no hooks are loaded' + Where);
      Exit;
    end;
    { The outer "hooks" wrapper was originally kept against the day a
      settings.json landed, so this file could become the value of its "hooks"
      key with no reshaping.  That day came and the migration was declined:
      settings.json is not fingerprinted for trust the way this file is, and
      honouring "hooks" there would create a SECOND place executable
      configuration comes from - one that LoadHooks' deny-by-default gate at
      the top of this procedure could not see.  "hooks" is a refused key in
      uSettings.SettingDefs with a sentence pointing back here.  The wrapper
      stays because it makes the document self-describing, not because
      anything is going to adopt it. }
    Map := Root.Find('hooks');
    if (Map = nil) or (Map.Kind <> jkObj) then
    begin
      Note(Notes, HooksFileName + ' has no "hooks" object; no hooks are loaded' +
        Where);
      Exit;
    end;

    for I := 0 to Map.Count - 1 do
    begin
      Key := Map.Key(I);
      Ev := HookEventFromName(Key);
      if Ev = heNone then
      begin
        { Named, not swallowed.  A Claude Code config pasted in here tells the
          user exactly which of its events pasclaude will not fire, instead of
          appearing to work. }
        Note(Notes, Key + ': pasclaude does not fire this event (it fires ' +
          'PreToolUse, PostToolUse, UserPromptSubmit, Stop and SessionStart)' +
          Where);
        Continue;
      end;
      Arr := Map.Item(I);
      if (Arr = nil) or (Arr.Kind <> jkArr) then
      begin
        Note(Notes, Key + ': should be an array of entries; ignored' + Where);
        Continue;
      end;
      { Seeded with what is already loaded rather than zero, because the
        ceiling is a ceiling on the EVENT and not on the file: eight PreToolUse
        hooks is eight children before one tool call, whichever files they came
        from.  The user loads first, so the entries this crowds out are always
        the project's own overflow - a project file can never push a user hook
        past the cap and out of the table. }
      Taken := HookCount(Ev);
      Seeded := Taken;
      for J := 0 to Arr.Count - 1 do
      begin
        if Taken >= MaxHooksPerEvent then
        begin
          { Two sentences because one would be a puzzle.  "only the first 8 are
            used (8 were listed)" is what the single-file wording says when the
            other scope already took a slot, and a user reading that would go
            looking for a ninth entry that is not in the file they opened. }
          if Seeded = 0 then
            Note(Notes, Format('%s: only the first %d hooks are used (%d were ' +
              'listed)', [Key, MaxHooksPerEvent, Arr.Count]) + Where)
          else
            Note(Notes, Format('%s: only the first %d hooks are used for this ' +
              'event, and %d of them came from the other hooks.json (%d were ' +
              'listed here)',
              [Key, MaxHooksPerEvent, Seeded, Arr.Count]) + Where);
          Break;
        end;
        if Length(Hooks) >= MaxHookEntries then
        begin
          Note(Notes, Format('at most %d hooks in total; the rest of the file ' +
            'is ignored', [MaxHookEntries]) + Where);
          Break;
        end;
        LoadEntry(Arr.Item(J), Ev, Scope, Where, Notes);
        Inc(Taken);
      end;
    end;
  finally
    Root.Free;
  end;
end;

{ The two files, in the order that decides which hook gets to block first.

  HooksAllowed is the first gate and it is now the ONLY unattended gate, which
  is the load-bearing change here.  It used to sit inside `Trusted and
  HooksAllowed`, which was correct while there was one file; with two it would
  have let a user-scope hook run under -p and the --ci verbs the moment the
  project's answer stopped being the only answer.  That is exactly what commit
  43daa12 closed, and this does not spend it: neither scope is even READ when
  the flag is false.

  Trusted is now what it always meant and never quite said - the answer to the
  question about the PROJECT file.  The user's own file is not fingerprinted
  and is never prompted for.  Prompting somebody about a file only they can
  write is noise that teaches them to answer yes, and every yes it trains is
  spent later on the prompt that matters.  Two facts make that safe rather than
  merely convenient: the file lives under %USERPROFILE%, which is outside every
  root, so no clone can ship it; and SafePath refuses .pasclaude at the top
  level of EVERY root, added ones included, so the model's own path-taking
  tools cannot write it even under --add-dir %USERPROFILE%.  The honest
  residual, said out loud rather than left to be discovered: a bash program the
  user approved can still edit it, exactly as it can already edit the project's
  hooks.json, so the asymmetry is not made worse - it is made broader, because
  a hook installed there runs in every project.

  MERGE RULE.  Both tables coexist, appended, the user's first.  FireHooks
  walks the one array in index order and stops at the first block, so for every
  event the user's hooks fire before the project's.  That ordering is the rule
  and not a cosmetic detail: if the project fired first it could pre-empt the
  user's audit hook by blocking ahead of it.  A project file can never remove,
  disable or shadow a user hook - there is no key that removes one, and the
  per-event ceiling is seeded with what is already loaded.

  ROOT = HOME.  Running pasclaude in %USERPROFILE% makes the two paths one
  file.  It is loaded once, as the user's, with no prompt: HooksConfigured is
  False there, so TrustHooks returns False without asking, and the project
  branch is skipped here as well.  Both have to consult
  ProjectHooksAreTheUsers or the two disagree. }
procedure LoadHooks(Trusted: Boolean; out Notes: string);
begin
  ClearHooks;
  Notes := '';
  SweepTmp;
  if not HooksAllowed then Exit;
  LoadHookFile(UserHooksFilePath, ' in ' + UserHooksFilePath, hsUser, Notes);
  { Deny by default, and structurally: an untrusted project file is not parsed
    at all, so there is no path by which a matcher from it could even be
    compiled. }
  if Trusted and not ProjectHooksAreTheUsers then
    LoadHookFile(HooksFilePath, '', hsProject, Notes);
  Loaded := True;
end;

{ A leading scope column, because with two files a line that says only
  "PreToolUse * -> whatever" cannot be acted on: the user has to know which
  file to open before they can change anything.  One renderer for both readers,
  which is the reason HookSummaryOf exists as a second READER of the same
  shape rather than as a second parser with its own layout. }
function SummaryLine(const Scope, EvName, Matcher, Cmd: string): string;
var
  M: string;
begin
  M := Matcher;
  if M = '' then M := '*';
  Result := Format('  %-8s %-16s %-24s ->  %s'#10, [Scope, EvName, M, Cmd]);
end;

function HookSummary: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Hooks) do
    Result := Result + SummaryLine(HookScopeName(Hooks[I].Scope),
      HookEventName(Hooks[I].Event), Hooks[I].Matcher, Hooks[I].Command);
end;

function HookEntryCount: Integer;
begin
  Result := Length(Hooks);
end;

function HookCommandAt(I: Integer): string;
begin
  if (I < 0) or (I > High(Hooks)) then Exit('');
  Result := Hooks[I].Command;
end;

function HookScopeAt(I: Integer): string;
begin
  if (I < 0) or (I > High(Hooks)) then Exit('');
  Result := HookScopeName(Hooks[I].Scope);
end;

function HookSummaryOf(const Path: string): string;
var
  Text, Cmd, M: string;
  Root, Map, Arr, Ent, T: TJson;
  I, J, Shown: Integer;
begin
  Result := '';
  Shown := 0;
  if not ReadWholeFile(Path, Text) then Exit;
  Root := JsonParse(Text);
  if Root = nil then Exit;
  try
    if Root.Kind <> jkObj then Exit;
    Map := Root.Find('hooks');
    if (Map = nil) or (Map.Kind <> jkObj) then Exit;
    for I := 0 to Map.Count - 1 do
    begin
      Arr := Map.Item(I);
      if (Arr = nil) or (Arr.Kind <> jkArr) then Continue;
      for J := 0 to Arr.Count - 1 do
      begin
        if Shown >= MaxHookEntries then
        begin
          Result := Result + Format('  ... and more (only the first %d run)'#10,
            [MaxHookEntries]);
          Exit;
        end;
        Ent := Arr.Item(J);
        if (Ent = nil) or (Ent.Kind <> jkObj) then Continue;
        T := Ent.Find('command');
        if (T = nil) or (T.Kind <> jkStr) then Continue;
        Cmd := Trim(T.AsString);
        { The command is the whole point of the prompt, so it is repaired the
          same way a hook's output is: an unreadable byte here would be a
          program the user approved without being able to see its name. }
        if not uJson.IsValidUtf8(Cmd) then Cmd := uJson.OemToUtf8(Cmd);
        M := '';
        T := Ent.Find('matcher');
        if (T <> nil) and (T.Kind = jkStr) then M := Trim(T.AsString);
        if not uJson.IsValidUtf8(M) then M := uJson.OemToUtf8(M);
        { 'project' unconditionally, because this reader exists for exactly one
          caller: the trust prompt, which is only ever asked about the project
          file.  The user's file reaches no prompt at all. }
        Result := Result + SummaryLine(HookScopeName(hsProject), Map.Key(I),
          M, Cmd);
        Inc(Shown);
      end;
    end;
  finally
    Root.Free;
  end;
end;

{ ----------------------------------------------------------- the firing -- }

function HookCall(Ev: THookEvent): THookCall;
begin
  Result.Event := Ev;
  Result.ToolName := '';
  Result.ToolInput := nil;
  Result.Prompt := '';
  Result.ResultText := '';
  Result.ResultIsError := False;
  Result.StopActive := False;
end;

function Omitted(N: Integer): TJson;
begin
  Result := TJson.NewObj;
  { The byte count is in the value on purpose: a hook that cannot do its job
    because the payload was too big should be able to say so precisely. }
  Result.AddStr('_omitted', Format('%d bytes', [N]));
end;

function BuildPayload(const Call: THookCall; OmitBig: Boolean): string;
const
  OmitStrBytes = 8192;
var
  Root, Cp: TJson;
  InTxt: string;
begin
  Root := TJson.NewObj;
  try
    Root.AddStr('hook_event_name', HookEventName(Call.Event));
    Root.AddStr('session_root', RootPath);
    if Call.Event in [hePreTool, hePostTool] then
    begin
      Root.AddStr('tool_name', Call.ToolName);
      if Call.ToolInput = nil then
        Root.Add('tool_input', TJson.NewObj)
      else if OmitBig then
        Root.Add('tool_input', Omitted(Length(Call.ToolInput.ToJson)))
      else
      begin
        { A copy, because the caller still owns and will keep using its own. }
        InTxt := Call.ToolInput.ToJson;
        Cp := JsonParse(InTxt);
        if Cp = nil then Cp := TJson.NewObj;
        Root.Add('tool_input', Cp);
      end;
    end;
    if Call.Event = hePostTool then
    begin
      if OmitBig and (Length(Call.ResultText) > OmitStrBytes) then
        Root.AddStr('tool_result', Utf8Cut(Call.ResultText, OmitStrBytes))
      else
        Root.AddStr('tool_result', Call.ResultText);
      Root.AddBool('is_error', Call.ResultIsError);
    end;
    if Call.Event = heUserPrompt then
    begin
      if OmitBig and (Length(Call.Prompt) > OmitStrBytes) then
        Root.AddStr('prompt', Utf8Cut(Call.Prompt, OmitStrBytes))
      else
        Root.AddStr('prompt', Call.Prompt);
    end;
    if Call.Event = heStop then
      Root.AddBool('stop_hook_active', Call.StopActive);
    Result := Root.ToJson;
  finally
    Root.Free;
  end;
end;

function Payload(const Call: THookCall): string;
begin
  Result := BuildPayload(Call, False);
  { Over the cap, the big values are replaced wholesale rather than cut.  A
    truncated JSON value is not JSON, and a hook whose stdin will not parse
    has been handed a worse problem than the one the cap was solving. }
  if Length(Result) > MaxHookInBytes then
    Result := BuildPayload(Call, True);
end;

{ True when this hook applies to the call.  Only tool events have matchers, so
  everything else matches by construction. }
function Matches(var H: THookEntry; const Call: THookCall): Boolean;
begin
  if H.Rx = nil then Exit(True);
  if not (Call.Event in [hePreTool, hePostTool]) then Exit(True);
  H.Rx.Budget := HookMatchBudget;
  case H.Rx.Match(Call.ToolName) of
    rrMatch: Result := True;
    rrBudget:
      begin
        { The engine stopped early, so the answer is unknown - and an unknown
          is not a match.  Saying so out loud matters more than usual here: a
          hook silently not firing is indistinguishable from a hook that ran
          and approved. }
        Notice('a hook matcher ran out of budget against ' + Call.ToolName +
          '; treating it as no match');
        Result := False;
      end;
  else
    Result := False;
  end;
end;

procedure Absorb(var Res: THookOutcome; const Text: string);
begin
  if Trim(Text) = '' then Exit;
  if Res.Text <> '' then Res.Text := Res.Text + #10;
  Res.Text := Res.Text + Text;
end;

{ The fire itself.  FireHooks below is this plus the one report, and the split
  is the whole reason it exists: the loop leaves by three doors - a block from
  exit 2, a block from a "deny" decision, and the fall-through - so reporting
  inside it would be three copies of the same three lines, and the fourth exit
  somebody adds next year would be the one that forgot.  Rejected the
  alternative of a try..finally around the body, because a report has to see
  the finished Result and the finally would run on an exception too, where
  there is no outcome to describe. }
function FireAll(const Call: THookCall): THookOutcome;
var
  I, Code: Integer;
  Out_, Body, Decision: string;
  Cut: Boolean;
  TimedOut: Boolean;
  Doc: TJson;
begin
  Result.Blocked := False;
  Result.Allowed := False;
  Result.Text := '';
  Result.Ran := 0;
  Result.Failed := 0;
  if not HooksEnabled then Exit;
  if Call.Event = heNone then Exit;

  Body := '';
  for I := 0 to High(Hooks) do
  begin
    if Hooks[I].Event <> Call.Event then Continue;
    if not Matches(Hooks[I], Call) then Continue;
    if Body = '' then Body := Payload(Call);

    Code := RunChild(Hooks[I].Command, Body, RootPath, Hooks[I].TimeoutMs,
      MaxHookOutBytes, Out_, TimedOut);
    Inc(Result.Ran);

    { Everything below this line reaches the model, so it is repaired here
      once rather than at each of the three firing sites.  One bad byte from a
      hook would otherwise lose the whole conversation. }
    Cut := Length(Out_) >= MaxHookOutBytes;
    if not uJson.IsValidUtf8(Out_) then Out_ := uJson.OemToUtf8(Out_);
    Out_ := Trim(Out_);
    if Cut then Out_ := Out_ + #10'[hook output truncated]';

    if TimedOut then
    begin
      { A deadline is a failure, not a block, for exactly the reason a
        nonzero exit is: the user who typed a slow command did not thereby
        decide to deny every tool call in the project. }
      Inc(Result.Failed);
      Notice(Format('hook timed out after %d ms and was ignored: %s',
        [Hooks[I].TimeoutMs, Hooks[I].Command]));
      Continue;
    end;

    if Code = 2 then
    begin
      Result.Blocked := True;
      Absorb(Result, Out_);
      { First block wins; the rest of the list is not run.  Anything after a
        refusal would be acting on a decision already made. }
      Exit;
    end;

    if Code <> 0 then
    begin
      Inc(Result.Failed);
      Notice(Format('hook exited %d and was ignored: %s',
        [Code, Hooks[I].Command]));
      Continue;
    end;

    { Exit 0.  A JSON object is honoured; anything else is plain context, and
      never an error - a hook that prints a log line has not refused anything,
      and treating unparseable output as a block would make the first noisy
      hook in a project deny every tool call. }
    Doc := nil;
    if (Out_ <> '') and (Out_[1] = '{') then Doc := JsonParse(Out_);
    if (Doc <> nil) and (Doc.Kind = jkObj) then
    begin
      try
        Decision := LowerCase(Trim(Doc.Str('decision')));
        if Decision = 'deny' then
        begin
          Result.Blocked := True;
          Absorb(Result, Doc.Str('reason'));
          if Trim(Result.Text) = '' then Absorb(Result, Out_);
          Exit;
        end;
        if Decision = 'allow' then Result.Allowed := True;
        Absorb(Result, Doc.Str('context'));
      finally
        Doc.Free;
      end;
    end
    else
    begin
      Doc.Free;
      Absorb(Result, Out_);
    end;
  end;
end;

function FireHooks(const Call: THookCall): THookOutcome;
begin
  Result := FireAll(Call);
  if not Assigned(OnHookFired) then Exit;
  { Ran = 0 is not an event and must never become a line.  RunTool fires
    PreToolUse and PostToolUse around EVERY tool call whether or not a matcher
    matched, and whether or not there is a hooks.json at all - so reporting the
    empty fire would put two lines on a driver's stream per tool call to say
    that nothing happened, and a driver counting hook lines would in fact be
    counting tool calls.  The block that never ran a child is covered by this
    too: FireAll cannot block without running something.

    Blocked is passed through rather than recomputed from the text, because
    the two are not the same question - a hook that exits 0 and prints an
    objection has not refused anything, and a hook that exits 2 with no output
    at all has.  Detail is the outcome's own words, trimmed and nothing more;
    what an unparseable byte in them does to the line is decided by the
    encoder, which is the only place that knows what a line is. }
  if Result.Ran = 0 then Exit;
  OnHookFired(HookEventName(Call.Event), Call.ToolName, Trim(Result.Text),
    Result.Blocked);
end;

finalization
  { A compiled TRegex surviving the process is a leak -gh reports and a real
    one: the table is module state with no other owner. }
  ClearHooks;

end.
