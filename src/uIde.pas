{ uIde - what a Windows console program can honestly learn about the editor
  it is running inside, and the one thing it can honestly do about it.

  THE LADDER.  This unit uses SysUtils, Windows and uSandbox and nothing
  else.  It sits at the uSandbox tier, below uTools, so it cannot read a
  settings file, cannot touch a console and cannot reach the model: every
  configurable string it needs is PASSED IN.  That is what makes the whole
  unit drivable from a suite with no environment to mutate and no console to
  fake, and it is also the structural reason nothing this unit produces can
  reach a request body - uTools and uAgent do not import it.

  WHAT WAS ACTUALLY PROBED, on this machine, in a live VS Code integrated
  terminal, rather than taken from a list:

    TERM_PROGRAM=vscode
    TERM_PROGRAM_VERSION=1.128.1
    VSCODE_INJECTION=1
    VSCODE_GIT_ASKPASS_NODE=C:\Users\...\Microsoft VS Code\Code.exe
    VSCODE_GIT_ASKPASS_MAIN, GIT_ASKPASS, VSCODE_GIT_IPC_HANDLE

  ABSENT, and therefore not used: VSCODE_PID and VSCODE_CWD (those live in
  the IDE's own process, not in a terminal child), and - the point that
  decides a whole feature - ANYTHING naming a file, a line, a column or a
  selection.  The single IPC handle VS Code injects is the git extension's
  askpass socket; its protocol answers credential and commit-message prompts
  and carries no editor state.  So "the current selection as context" has no
  channel from the terminal side and none is invented here.

  JetBrains sets TERMINAL_EMULATOR=JetBrains-JediTerm.  That is taken from
  JetBrains' own terminal documentation and jediterm issue 253; NO JetBrains
  IDE was run to confirm it, and this comment says so rather than letting a
  reader assume both families were measured equally.  Nothing in a JetBrains
  environment names the launcher (idea64 / pycharm64 / rider64 all differ),
  which is exactly why a JetBrains host is detected and reported but never
  launched into unless the user names the program themselves.

  WHY THE CLI IS FOUND BY SCANNING A DIRECTORY rather than by deriving the
  shim name from the exe.  Deriving reads better and is wrong on real
  installations: VS Code stable is Code.exe -> bin\code.cmd, but Insiders is
  "Code - Insiders.exe" -> bin\code-insiders.cmd, and Cursor's shim lives in
  resources\app\bin\cursor.cmd, a different subtree entirely.  A stem rule
  silently launches the wrong editor or nothing at all.  The scan is also
  where two exclusions earn their place: this machine's real bin directory
  holds code.cmd, new_code.cmd, code-tunnel.exe and new_code-tunnel.exe -
  the updater staging copy and the remote-tunnel client sit right beside the
  shim, and either would be a wrong and surprising thing to start.

  WHAT THIS UNIT DELIBERATELY DOES NOT DO.  It never captures a child's
  output, so nothing an editor prints can enter the transcript.  It never
  waits for a tab to close: --wait blocks the caller until the user closes
  the editor, which is fine for a review action and would be a deadlock in
  front of a y/a/n prompt, and that is why the approval path was left
  untouched by this feature. }
unit uIde;

{$mode objfpc}{$H+}

interface

uses SysUtils, Windows, uSandbox;

type
  TIdeFamily = (ifNone, ifVsCode, ifJetBrains);

  TIdeHost = record
    Family:  TIdeFamily;
    Name:    string;   { 'vscode' | 'jetbrains' | '' }
    { The observed basename of the askpass exe, e.g. 'Code.exe' or
      'Cursor.exe'.  Reported as an observation and never as a claim about
      WHICH fork this is: Cursor, Insiders, Windsurf and Kiro all say
      TERM_PROGRAM=vscode, and guessing between them from a name would be a
      fact invented for a status row. }
    Product: string;
    Version: string;   { sanitised: printable ASCII 32..126, <= 32 chars }
    ExePath: string;   { VSCODE_GIT_ASKPASS_NODE, verbatim, when present }
  end;

  { The spawn seam, uHttp.HttpTransport in shape: a plain function pointer,
    nil in the shipped program.  A nested or method pointer will not compile
    against it.  Returning True means "consider it launched". }
  TIdeSpawnProc = function(const CmdLine: string): Boolean;

const
  { uSettings' 'ide.enabled' Dflt column must equal Ord of this, and
    ux.lpr's TestSettingDefaultsMatchTheProgram fails the build otherwise. }
  IdeEnabledDefault = True;
  IdeMaxVersionLen  = 32;
  { A path longer than this is not a path anybody typed or any tool made; it
    is somebody testing what happens at the end of a command line. }
  IdeMaxArgLen      = 1024;
  { How long the CLI shim gets to signal the editor before the job is closed
    on it.  A shim talking to a running instance returns in well under a
    second; ten is generous.  It is bounded rather than infinite because the
    caller is a REPL with a user waiting at it. }
  IdeLaunchWaitMs   = 10000;

var
  IdeSpawnOverride: TIdeSpawnProc = nil;

{ Pure, and that is the whole test seam: no environment mutation, no global,
  nothing to reset in a suite's finally block. }
function IdeIdentify(const TermProgram, TermProgramVersion,
  AskpassNode, TerminalEmulator, VsCodeInjection: string): TIdeHost;

{ Reads the five variables and calls IdeIdentify. }
function IdeDetect: TIdeHost;

function IdeFamilyName(F: TIdeFamily): string;

{ Configured wins when it is non-empty AND the file exists.  Otherwise scans
  <dir>\bin and <dir>\resources\app\bin beside Host.ExePath - never a path
  composed from the variable's own text - taking .cmd/.bat/.exe, skipping
  new_* and *-tunnel*, shortest name winning.  '' when nothing resolves, and
  '' always when no host was detected. }
function IdeResolveCli(const Host: TIdeHost; const Configured: string): string;

{ Refuses '', anything longer than IdeMaxArgLen, and any '"', '%' or byte
  below $20 or equal to $7F anywhere in the string. }
function IdeScreenArg(const S: string): Boolean;

{ Compose only - these do not spawn, so a suite can assert the exact bytes.
  False with Err set when there is no host, no CLI, or an argument is
  refused; Line is '' in every one of those cases. }
function IdeDiffLine(const Host: TIdeHost; const Cli, OldPath, NewPath: string;
  out Line, Err: string): Boolean;
function IdeOpenLine(const Host: TIdeHost; const Cli, Path: string;
  LineNo: Integer; out Line, Err: string): Boolean;

{ SandboxNewJob, then SandboxLevel saved / forced slOff / restored in a
  finally, then SandboxSpawn.  Never Halts, never writes to a console, never
  captures output. }
function IdeLaunch(const CmdLine: string; out Err: string): Boolean;

implementation

{ --------------------------------------------------------- sanitisation -- }

{ Printable ASCII only, capped.  This runs on TERM_PROGRAM_VERSION, which
  becomes a /status row and therefore lands in a /bug report the user pastes
  into an issue tracker: an escape sequence in it would repaint that output
  and an invalid UTF-8 byte would travel with it.  Cutting here, inside the
  identify function, is what means the raw bytes never exist above it. }
function CleanShort(const S: string; Max: Integer): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if (C >= #32) and (C <= #126) then
    begin
      Result := Result + C;
      if Length(Result) >= Max then Break;
    end;
  end;
end;

{ A basename, with the separators taken out as well.  ExtractFileName alone
  answers the ordinary case; the explicit strip is for a value that ends in
  a separator or carries one after a control byte was dropped. }
function CleanBaseName(const S: string): string;
var
  I: Integer;
  T: string;
begin
  T := CleanShort(ExtractFileName(S), 64);
  Result := '';
  for I := 1 to Length(T) do
    if not (T[I] in ['\', '/', ':']) then Result := Result + T[I];
end;

{ ------------------------------------------------------------ detection -- }

function IdeFamilyName(F: TIdeFamily): string;
begin
  case F of
    ifVsCode:    Result := 'vscode';
    ifJetBrains: Result := 'jetbrains';
  else
    Result := '';
  end;
end;

function IdeIdentify(const TermProgram, TermProgramVersion,
  AskpassNode, TerminalEmulator, VsCodeInjection: string): TIdeHost;
begin
  Result.Family  := ifNone;
  Result.Name    := '';
  Result.Product := '';
  Result.Version := '';
  Result.ExePath := '';

  { EXACT equality, never a prefix, a substring or a case fold.  This is the
    same rule and the same reason as uHttp.SplitUrlEx's exact-host loopback
    test: a prefix test makes '127.0.0.1.evil.com' read as loopback, and a
    substring test here makes any terminal calling itself 'xvscode-ish' a
    detected editor that this program will then offer to start programs for.

    VSCODE_INJECTION is required with it, and that is deliberate rather than
    belt-and-braces.  The marker is set by the shell integration VS Code
    injects into a terminal it is HOSTING; it is the closest thing the
    environment has to evidence that an editor window is alive right now.
    That evidence is the precondition IdeLaunch's kept job object rests on -
    see the comment there - so it is checked here rather than assumed. }
  if (TermProgram = 'vscode') and (VsCodeInjection = '1') then
  begin
    Result.Family  := ifVsCode;
    Result.Name    := 'vscode';
    Result.Version := CleanShort(TermProgramVersion, IdeMaxVersionLen);
    Result.ExePath := AskpassNode;
    Result.Product := CleanBaseName(AskpassNode);
    Exit;
  end;

  { Checked second, so a terminal that somehow carries both is reported as
    VS Code: VS Code's variables are the more specific evidence, and they
    are the ones that name a program this unit could actually resolve. }
  if TerminalEmulator = 'JetBrains-JediTerm' then
  begin
    Result.Family  := ifJetBrains;
    Result.Name    := 'jetbrains';
    Result.Version := CleanShort(TermProgramVersion, IdeMaxVersionLen);
  end;
end;

function IdeDetect: TIdeHost;
begin
  { SysUtils. qualified on every one of these: the Windows unit is in scope
    and exports a raw GetEnvironmentVariable of the same name that shadows
    this one and returns a DWORD.  Every call site in this program is
    qualified for that reason. }
  Result := IdeIdentify(
    SysUtils.GetEnvironmentVariable('TERM_PROGRAM'),
    SysUtils.GetEnvironmentVariable('TERM_PROGRAM_VERSION'),
    SysUtils.GetEnvironmentVariable('VSCODE_GIT_ASKPASS_NODE'),
    SysUtils.GetEnvironmentVariable('TERMINAL_EMULATOR'),
    SysUtils.GetEnvironmentVariable('VSCODE_INJECTION'));
end;

{ ------------------------------------------------------- resolving a CLI -- }

function LaunchableExt(const Name: string): Boolean;
var
  E: string;
begin
  E := LowerCase(ExtractFileExt(Name));
  Result := (E = '.cmd') or (E = '.bat') or (E = '.exe');
end;

{ new_* is the updater's staged copy and *-tunnel* is the remote-tunnel
  client; both sit in the same directory as the shim on a stock install and
  neither opens anything. }
function ExcludedName(const Name: string): Boolean;
var
  L: string;
begin
  L := LowerCase(Name);
  Result := (Copy(L, 1, 4) = 'new_') or (Pos('-tunnel', L) > 0);
end;

{ Shortest wins, and a tie is broken by the lower-cased name so the answer
  does not depend on the order FindFirst happened to yield. }
procedure ConsiderDir(const Dir: string; var Best: string);
var
  R: TSearchRec;
  Cand: string;
begin
  if Dir = '' then Exit;
  if FindFirst(Dir + '*', faAnyFile, R) <> 0 then Exit;
  try
    repeat
      if (R.Attr and faDirectory) <> 0 then Continue;
      if not LaunchableExt(R.Name) then Continue;
      if ExcludedName(R.Name) then Continue;
      Cand := Dir + R.Name;
      if (Best = '') or
         (Length(ExtractFileName(Cand)) < Length(ExtractFileName(Best))) or
         ((Length(ExtractFileName(Cand)) = Length(ExtractFileName(Best))) and
          (LowerCase(ExtractFileName(Cand)) < LowerCase(ExtractFileName(Best))))
      then
        Best := Cand;
    until FindNext(R) <> 0;
  finally
    { Qualified for the same reason GetEnvironmentVariable is above: Windows
      is used after SysUtils and exports a FindClose(HANDLE) that shadows the
      RTL's FindClose(var TSearchRec).  FindFirst and FindNext are safe - the
      API spells those FindFirstFile and FindNextFile - which is why this one
      is easy to miss. }
    SysUtils.FindClose(R);
  end;
end;

function IdeResolveCli(const Host: TIdeHost; const Configured: string): string;
var
  Dir, Best: string;
begin
  Result := '';
  { No host, no launch, and no scan either.  This precondition is not a
    convenience: IdeLaunch keeps its job object, which is only safe while the
    child is a shim signalling an editor that is ALREADY running.  Offering a
    launch outside a detected host would make the shim start the editor as a
    child of the job, and KILL_ON_JOB_CLOSE would then close the user's
    window when pasclaude exits. }
  if Host.Family = ifNone then Exit;

  { A user-set path wins, but only if it is really there.  A configured path
    that does not exist falls through to the scan rather than being handed
    back, so a stale settings value degrades to "the editor you are actually
    running" instead of to a spawn failure. }
  if (Configured <> '') and FileExists(Configured) then Exit(Configured);

  { JetBrains stops here, always.  Nothing in a JediTerm environment names
    idea64.exe, pycharm64.exe or rider64.exe, and a guess would be a program
    path invented by this program - so ide.command is the only way, and it
    is user scope only for exactly that reason. }
  if Host.Family <> ifVsCode then Exit;

  { The scan roots come from ExtractFilePath of a file that EXISTS, never
    from concatenating the variable's own text: that is what makes a
    traversal-shaped VSCODE_GIT_ASKPASS_NODE meaningless here rather than
    meaningful. }
  if Host.ExePath = '' then Exit;
  if not FileExists(Host.ExePath) then Exit;
  Dir := ExtractFilePath(Host.ExePath);
  if Dir = '' then Exit;

  Best := '';
  ConsiderDir(Dir + 'bin' + PathDelim, Best);
  ConsiderDir(Dir + 'resources' + PathDelim + 'app' + PathDelim +
    'bin' + PathDelim, Best);
  Result := Best;
end;

{ --------------------------------------------------- composing the lines -- }

function IdeScreenArg(const S: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if S = '' then Exit;
  if Length(S) > IdeMaxArgLen then Exit;
  for I := 1 to Length(S) do
    { A quote would close the one this program wrapped the argument in; a
      percent would be expanded by cmd.exe against the child's environment
      before the shim ever saw it; a control byte would break the line in
      ways that depend on which of the two spawn shapes was taken.

      " | < > ? * are also characters Windows does not permit in a path at
      all, so refusing them costs nothing a real file could have needed and
      removes the whole question of whether the quoting held.  & and ^ are
      NOT refused: both are legal in a Windows filename, and both are inert
      inside the quotes this unit puts round every argument - refusing them
      would break opening a file somebody legitimately named.  Bytes at or
      above $80 are left alone: a Unicode basename is an ordinary path. }
    if (S[I] in ['"', '%', '|', '<', '>', '?', '*']) or
       (S[I] < #32) or (S[I] = #127) then Exit;
  Result := True;
end;

function ComSpecPath: string;
begin
  Result := SysUtils.GetEnvironmentVariable('ComSpec');
  if Trim(Result) = '' then Result := 'cmd.exe';
end;

function Q(const S: string): string;
begin
  Result := '"' + S + '"';
end;

{ One composer for both verbs.  Args is everything after the program, already
  quoted; this decides only whether cmd.exe is in the picture.

  /S is not decoration.  Without it cmd.exe's rule for the string after /C
  depends on how many quote characters the whole line contains, which is the
  classic Windows footgun: a path with a space works until another quoted
  argument is added and then the line silently splits somewhere else.  /S
  makes it deterministic - strip the first and last quote, run the rest - so
  the shape below is stable no matter what the paths look like. }
function Compose(const Cli, Args: string; out Line, Err: string): Boolean;
var
  Shell: string;
begin
  Line := '';
  Err := '';
  if not IdeScreenArg(Cli) then
  begin
    Err := 'the editor command contains a character that cannot be put on a ' +
      'command line safely';
    Exit(False);
  end;
  if LowerCase(ExtractFileExt(Cli)) = '.exe' then
  begin
    { An .exe is started directly.  Wrapping it in cmd.exe would add a shell
      that parses the line a second time for no gain at all. }
    Line := Q(Cli) + ' ' + Args;
    Exit(True);
  end;
  Shell := ComSpecPath;
  if not IdeScreenArg(Shell) then
  begin
    Err := '%ComSpec% is not a path that can be quoted';
    Exit(False);
  end;
  Line := Q(Shell) + ' /S /C "' + Q(Cli) + ' ' + Args + '"';
  Result := True;
end;

{ Both entry points check every argument BEFORE anything is composed, so a
  refused path never exists as part of a command line even momentarily. }
function Preflight(const Host: TIdeHost; const Cli: string;
  out Err: string): Boolean;
begin
  Err := '';
  Result := False;
  if Host.Family = ifNone then
  begin
    Err := 'no editor was detected for this terminal';
    Exit;
  end;
  if Cli = '' then
  begin
    Err := 'no editor command-line program could be found';
    Exit;
  end;
  Result := True;
end;

function IdeDiffLine(const Host: TIdeHost; const Cli, OldPath, NewPath: string;
  out Line, Err: string): Boolean;
var
  Args: string;
begin
  Line := '';
  if not Preflight(Host, Cli, Err) then Exit(False);
  if not (IdeScreenArg(OldPath) and IdeScreenArg(NewPath)) then
  begin
    Err := 'that path contains a character that cannot be put on a command ' +
      'line safely';
    Exit(False);
  end;
  case Host.Family of
    ifVsCode:    Args := '--diff ' + Q(OldPath) + ' ' + Q(NewPath);
    ifJetBrains: Args := 'diff ' + Q(OldPath) + ' ' + Q(NewPath);
  else
    begin
      Err := 'that editor has no known diff command';
      Exit(False);
    end;
  end;
  Result := Compose(Cli, Args, Line, Err);
end;

function IdeOpenLine(const Host: TIdeHost; const Cli, Path: string;
  LineNo: Integer; out Line, Err: string): Boolean;
var
  Args: string;
begin
  Line := '';
  if not Preflight(Host, Cli, Err) then Exit(False);
  if not IdeScreenArg(Path) then
  begin
    Err := 'that path contains a character that cannot be put on a command ' +
      'line safely';
    Exit(False);
  end;
  case Host.Family of
    ifVsCode:
      if LineNo > 0 then
        Args := '-g ' + Q(Path + ':' + IntToStr(LineNo))
      else
        Args := '-g ' + Q(Path);
    ifJetBrains:
      if LineNo > 0 then
        Args := '--line ' + IntToStr(LineNo) + ' ' + Q(Path)
      else
        Args := Q(Path);
  else
    begin
      Err := 'that editor has no known open command';
      Exit(False);
    end;
  end;
  Result := Compose(Cli, Args, Line, Err);
end;

{ ------------------------------------------------------------- the spawn -- }

function IdeLaunch(const CmdLine: string; out Err: string): Boolean;
var
  Saved: TSandboxLevel;
  Job: THandle;
  SI: STARTUPINFOA;
  PI: PROCESS_INFORMATION;
  InJob: Boolean;
begin
  Err := '';
  Result := False;
  if Trim(CmdLine) = '' then
  begin
    Err := 'nothing to run';
    Exit;
  end;

  { The uTools.RunShell idiom, verbatim, and for a reason specific to a GUI
    program: under slLow the shim would get a low-integrity token and a
    redirected %TEMP%, so it could not talk to the user's own editor process
    and would fail in a way that reads as pasclaude being broken.  The
    restore is in a finally because leaving SandboxLevel at slOff would
    un-sandbox every bash call, background job, hook and MCP server for the
    rest of the session - a permission regression caused by a convenience
    command, with nothing in /status disagreeing. }
  Saved := uSandbox.SandboxLevel;
  if uSandbox.SandboxLevel <> slOff then uSandbox.SandboxLevel := slOff;
  try
    if IdeSpawnOverride <> nil then
    begin
      Result := IdeSpawnOverride(CmdLine);
      if not Result then Err := 'the editor could not be started';
      Exit;
    end;

    Job := uSandbox.SandboxNewJob;
    FillChar(SI, SizeOf(SI), 0);
    SI.cb := SizeOf(SI);
    { No pipes: the shim's output is never captured, so nothing an editor
      prints can reach the transcript or the console. }
    if not uSandbox.SandboxSpawn(CmdLine, '', '', 0, SI, PI, Job, InJob) then
    begin
      Err := 'could not start the editor (error ' +
        IntToStr(GetLastError) + ')';
      if Job <> 0 then CloseHandle(Job);
      Exit;
    end;
    { The job is KEPT for the child's whole life rather than closed straight
      away, and the wait is what makes that possible without a leaked handle.
      KILL_ON_JOB_CLOSE is harmless here ONLY because the child is a CLI shim
      that signals an editor instance which is already running and then
      exits - the window is a pre-existing process outside the job.  That is
      true only while /ide is offered exclusively inside a detected host,
      which IdeResolveCli enforces and which must not be relaxed. }
    WaitForSingleObject(PI.hProcess, IdeLaunchWaitMs);
    CloseHandle(PI.hThread);
    CloseHandle(PI.hProcess);
    if Job <> 0 then CloseHandle(Job);
    Result := True;
  finally
    uSandbox.SandboxLevel := Saved;
  end;
end;

end.
