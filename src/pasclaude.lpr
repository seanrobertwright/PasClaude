{ pasclaude - a terminal coding agent in the spirit of Claude Code.

  Reads a prompt, streams the model's reply, lets it call tools against the
  working directory, and asks before anything is changed.

  Usage:  pasclaude [directory]
  The API key comes from ANTHROPIC_API_KEY, the model from ANTHROPIC_MODEL. }
program pasclaude;

{$mode objfpc}{$H+}

uses
  Windows, SysUtils, Classes, DateUtils, uTerm, uJson, uSettings, uAuth,
  uHttp, uTelem, uMcp, uHooks, uSandbox, uIde, uTools, uImage, uAgent, uDiag,
  uSdk, uGitHub, uCi, uArgs;

const
  Version = '0.1';
  { A transcript larger than this is trimmed before the next turn.  Roughly
    100k characters, which is a fraction of the context window but well past
    the point where old file dumps are still earning their place. }
  CompactKeepBytes = 100 * 1024;
  { A pasted image is encoded here rather than merely forwarded, and a stored
    deflate PNG is about the size of its raw pixels, so the budget has to be
    generous enough to be useful and small enough that it is not re-sent
    forever.  Beyond it the encoder halves the image, at most twice. }
  MaxPasteBytes = 2 * 1024 * 1024;
  { The model's own maximum long edge.  Sending more pixels than this cannot
    improve the answer: the API downscales to it before looking. }
  PasteMaxEdge = 2576;
  { The /think default: enough for real multi-step reasoning, small enough
    that a casual "on" does not silently multiply the bill. }
  DefaultThinkBudget = 8192;

var
  { When the API reports the prompt at more than this many tokens, the
    transcript is trimmed even if its byte count looks fine.  Bytes are a
    proxy; this is the measured thing the context window actually fills
    with, and 150k leaves headroom under a 200k window for the reply.
    A var rather than a const because settings.json may move it, within the
    clamped range uSettings enforces - a project may only ever compact
    SOONER, never later. }
  CompactTokens: Integer = 150000;
  Agent: TAgent;
  AtLineStart: Boolean = True;
  { One checkpoint per user turn: the transcript length before it ran and
    the question that started it.  /rewind picks one and puts both the
    conversation and the files back. }
  CheckTurns: array of Integer;      { turn number, for the file snapshots }
  CheckCounts: array of Integer;     { MessageCount before the turn }
  CheckPrompts: array of string;     { first line of the question, for the list }
  { What the banner says about how the session authenticates; '' for a
    plain API key, which is the unremarkable case. }
  BannerAuth: string = '';
  { The credential in force, as uAuth resolved it at startup or as /login
    re-resolved it since.  Its Token field is the one copy this file holds
    and it is never printed, never written and never put in a message - only
    Source, Path and Hint are display material.  It exists so a 401 can say
    which of six sources was refused instead of leaving the user to guess. }
  ActiveAuth: TAuthInfo;
  { Set by /logout when it removed the only credential there was.  Every
    request path has to honour it, or the same session produces three
    different confusing errors - a main turn, a subagent and /model would
    each 401 separately - where one local refusal is the honest answer. }
  NoCredential: Boolean = False;
  { True for -p and for every SDK output format: a run with no human at the
    keyboard.  Set beside PrintMode in the argv loop and declared up here
    rather than in the main block, because the two commands that must refuse
    in a scripted run are defined long before that block is. }
  ScriptedRun: Boolean = False;
  { True once /yolo ran.  The permissions save skips these sessions
    wholesale, because yolo's blanket flags and real per-answer approvals
    are the same variables, and only the latter deserve to persist. }
  YoloSession: Boolean = False;
  { Bytes of tool-argument JSON already echoed for the current tool call;
    the display caps what it shows, the model still gets everything. }
  ToolArgShown: Integer = 0;

{ ------------------------------------------------------------- rendering -- }

{ The stream arrives in fragments that may split a line anywhere, so the
  renderer tracks whether the cursor sits at column zero.  Anything the program
  prints itself (tool lines, notices) needs that to avoid gluing onto the tail
  of a half-written sentence. }
procedure NeedNewLine;
begin
  if not AtLineStart then
  begin
    EmitLn;
    AtLineStart := True;
  end;
end;

procedure NoteWritten(const S: string);
begin
  if S <> '' then
    AtLineStart := S[Length(S)] = #10;
end;

procedure OnText(const S: string);
begin
  { Prose renders through the streaming markdown pass: complete lines are
    styled as they close, the current line is held until it does.  Output
    therefore appears line by line - the price of knowing whether a line is a
    heading or code before printing it. }
  MdFeed(S);
  AtLineStart := not MdMidLine;
end;

procedure OnThinking(const S: string);
begin
  EmitC(clGrey, S);
  NoteWritten(S);
end;

procedure OnToolStart(const Name, Detail: string);
begin
  { A tool call can interrupt mid-line; whatever prose is held back has to
    land first or it would print after the tool line it preceded. }
  MdFinish;
  AtLineStart := True;
  NeedNewLine;
  EmitC(clMagenta, '  * ');
  EmitCLn(clBright, Detail);
end;

{ The moment a tool_use block opens in the stream - its arguments are still
  arriving.  The name goes up immediately so a long argument stream (a big
  write_file, say) reads as progress rather than as a hang. }
procedure OnToolUseBegin(const Name, Id: string);
begin
  MdFinish;
  AtLineStart := True;
  NeedNewLine;
  EmitC(clMagenta, '  ~ ');
  EmitC(clGrey, Name + ' ');
  ToolArgShown := 0;
  AtLineStart := False;
end;

{ Argument JSON, echoed as it streams.  Capped: the point is to show life
  and the gist of the call, not to dump a whole file onto one line.  JSON
  string fragments carry no raw newlines, so the line stays a line. }
procedure OnToolArg(const S: string);
const
  MaxShow = 160;
var
  Room: Integer;
begin
  if ToolArgShown >= MaxShow then Exit;
  Room := MaxShow - ToolArgShown;
  if Length(S) <= Room then
    EmitC(clGrey, S)
  else
    EmitC(clGrey, Copy(S, 1, Room) + '...');
  Inc(ToolArgShown, Length(S));
  AtLineStart := False;
end;

{ Tool output is summarised rather than dumped: the model gets the whole
  thing, the user only needs to see that it happened and roughly what came
  back. }
procedure OnToolResult(const Name, Output: string);
var
  L: TStringList;
  I, Show: Integer;
  Line: string;
  W: Integer;
  Todos: TStringArray;
begin
  { The todo list renders as the list itself, states coloured, not as a
    tool-output summary: the list is the display. }
  if Name = 'todo_write' then
  begin
    Todos := uTools.CurrentTodos;
    for I := 0 to High(Todos) do
    begin
      Line := Todos[I];
      if Copy(Line, 1, 3) = '[x]' then
        EmitCLn(clGreen, '    ' + Line)
      else if Copy(Line, 1, 3) = '[~]' then
        EmitCLn(clYellow, '    ' + Line)
      else
        EmitCLn(clGrey, '    ' + Line);
    end;
    AtLineStart := True;
    Exit;
  end;
  W := TermWidth - 8;
  if W < 20 then W := 20;
  L := TStringList.Create;
  try
    L.Text := Output;
    Show := L.Count;
    if Show > 4 then Show := 4;
    for I := 0 to Show - 1 do
    begin
      Line := L[I];
      if Length(Line) > W then Line := Copy(Line, 1, W - 3) + '...';
      EmitCLn(clGrey, '    ' + Line);
    end;
    if L.Count > Show then
      EmitCLn(clGrey, Format('    ... %d more lines', [L.Count - Show]));
  finally
    L.Free;
  end;
  AtLineStart := True;
end;

procedure OnNotice(const S: string);
begin
  NeedNewLine;
  EmitCLn(clYellow, '  ' + S);
end;

{ Esc during a reply abandons it, and so does Ctrl+C: outside the prompt the
  default Ctrl+C handler would kill the process mid-turn, skipping every
  finally block - console restoration included - so it is caught and treated
  as the cancel the user meant.  The key is drained here rather than left in
  the buffer, where it would otherwise clear the next prompt line. }
function UserWantsStop: Boolean;
begin
  Result := EscPressed or CtrlCPressed;
end;

{ ------------------------------------------------------------ permissions -- }

{ ------------------------------------------------------------- completion -- }

const
  { Forty-three entries.  The bound is hand-maintained and a wrong one
    produces NO compile error, only a command that silently stops
    tab-completing, so it is counted rather than trusted. }
  SlashCommands: array[0..42] of string = (
    '/help', '/clear', '/compact', '/config', '/deny', '/diff', '/hooks',
    '/ide', '/jobs', '/mcp', '/memory', '/init', '/mode', '/plan', '/rewind',
    '/review', '/pr-comments',
    '/sandbox', '/sessions', '/skills', '/plugins', '/think', '/web',
    '/add-dir', '/remove-dir', '/resume', '/save', '/cwd', '/model', '/yolo',
    '/cost', '/telemetry', '/output-style', '/paste', '/vim', '/keys',
    '/login', '/logout', '/status', '/doctor', '/bug', '/exit', '/quit');

{ Candidates for the token being completed: slash commands when the token
  opens the line with a slash, file and directory names under the session
  root otherwise.  Directories come back with a trailing separator so a
  second Tab descends into them. }
function Complete(const Token: string; AtLineStart: Boolean): TStringArray;
var
  N: Integer;

  procedure Add(const S: string);
  begin
    SetLength(Result, N + 1);
    Result[N] := S;
    Inc(N);
  end;

var
  I: Integer;
  Dir, NamePart, Base: string;
  R: TSearchRec;
  Sigil, Tok: string;
begin
  Result := nil;
  N := 0;

  if AtLineStart and (Copy(Token, 1, 1) = '/') then
  begin
    for I := 0 to High(SlashCommands) do
      if Copy(SlashCommands[I], 1, Length(Token)) = Token then
        Add(SlashCommands[I]);
    Exit;
  end;

  { An @ prefix is a file mention; the path completes exactly as a bare one
    would, with the sigil carried through so the token replacement keeps it. }
  Sigil := '';
  Tok := Token;
  if Copy(Tok, 1, 1) = '@' then
  begin
    Sigil := '@';
    Delete(Tok, 1, 1);
  end;

  { A path: everything up to the last separator names the directory, the
    rest is the prefix to match.  The session root is the base, matching how
    every tool resolves paths. }
  Dir := '';
  NamePart := Tok;
  for I := Length(Tok) downto 1 do
    if Tok[I] in ['\', '/'] then
    begin
      Dir := Copy(Tok, 1, I);
      NamePart := Copy(Tok, I + 1, MaxInt);
      Break;
    end;
  Base := IncludeTrailingPathDelimiter(uTools.RootDir) + Dir;
  if not DirectoryExists(ExcludeTrailingPathDelimiter(Base)) then Exit;

  if FindFirst(Base + '*', faAnyFile, R) = 0 then
  begin
    repeat
      if (R.Name = '.') or (R.Name = '..') then Continue;
      if (R.Name = '.git') or (R.Name = uTools.StateDirName) then Continue;
      if (NamePart <> '') and
         (CompareText(Copy(R.Name, 1, Length(NamePart)), NamePart) <> 0) then
        Continue;
      if (R.Attr and faDirectory) <> 0 then
        Add(Sigil + Dir + R.Name + '\')
      else
        Add(Sigil + Dir + R.Name);
    until FindNext(R) <> 0;
    SysUtils.FindClose(R);
  end;
end;

{ The detail of a permission prompt is the tool's one-line description, and
  for a write or edit the diff it would produce.  Additions and removals are
  coloured so the shape of a change is readable at a glance rather than
  needing to be parsed character by character. }
procedure ShowDetail(const Detail: string);
var
  L: TStringList;
  I: Integer;
  Line: string;
begin
  L := TStringList.Create;
  try
    L.Text := Detail;
    for I := 0 to L.Count - 1 do
    begin
      Line := L[I];
      if Copy(Line, 1, 2) = '+ ' then
        EmitCLn(clGreen, '    ' + Line)
      else if Copy(Line, 1, 2) = '- ' then
        EmitCLn(clRed, '    ' + Line)
      else if Copy(Line, 1, 2) = '@@' then
        EmitCLn(clCyan, '    ' + Line)
      else if I = 0 then
        EmitCLn(clBright, '    ' + Line)
      else
        EmitCLn(clGrey, '    ' + Line);
    end;
  finally
    L.Free;
  end;
end;

function AskPermission(const Title, Detail: string): TPermission;
var
  Line: string;
begin
  NeedNewLine;
  EmitCLn(clYellow, '  permission needed: ' + Title);
  ShowDetail(Detail);
  repeat
    EmitC(clYellow, '  [y] once  [a] always  [n] no > ');
    if not ReadLineEdit('', Line) then Exit(pmDeny);
    Line := LowerCase(Trim(Line));
    if (Line = 'y') or (Line = 'yes') or (Line = '') then Exit(pmAllowOnce);
    if (Line = 'a') or (Line = 'always') then Exit(pmAllowAlways);
    if (Line = 'n') or (Line = 'no') then Exit(pmDeny);
  until False;
end;

{ ---------------------------------------------------------- system prompt -- }

{ The prompt assembly used to live here, which meant no suite could reach it:
  nothing can link a program.  It now lives in uSdk, verbatim, and this is the
  only thing left behind - the string a hook's SessionStart produced, handed
  to uSdk through the one seam that exists for it. }
var
  HookSystemExtra: string = '';

function SdkExtra: string;
begin
  Result := HookSystemExtra;
end;

{ ------------------------------------------------------------------ shell -- }

{ ------------------------------------------------------- permission modes -- }

{ The prompt is the only place the mode is guaranteed to be seen, because it
  is redrawn on every keystroke and a banner scrolls away.  A user who does
  not know they are in accept-edits is the failure this whole feature exists
  to prevent, so the word goes where it cannot be missed.

  The '+' is a pointer to /mode, not information: no four-character suffix can
  render every combination of class grants, and one that tried would be read
  as complete.  It says "the word understates this". }
function ModePrompt: string;
begin
  Result := uTools.PermModeIndicator;
  { Plain ask with nothing standing keeps the prompt the program has always
    had: an indicator that is always on stops being an indicator. }
  if Result = 'ask' then Result := '> ' else Result := Result + '> ';
end;

function Choice(B: Boolean; const Yes, No: string): string;
begin
  if B then Result := Yes else Result := No;
end;

procedure ShowMode(const Arg: string);
var
  M: uTools.TPermMode;
  Grants: string;
begin
  if Arg <> '' then
  begin
    if LowerCase(Arg) = 'bypass' then
    begin
      EmitCLn(clYellow, '  bypass is spelled /yolo, and it means it');
      Exit;
    end;
    if not uTools.PermModeParse(Arg, M) then
    begin
      EmitCLn(clRed, '  unknown mode: ' + Arg);
      EmitCLn(clGrey, '  ask, plan or accept-edits (/yolo for bypass)');
      Exit;
    end;
    uTools.SetPermMode(M);
    if M = uTools.pmodePlan then
      EmitCLn(clCyan, '  plan mode: the model may read and investigate; ' +
        'nothing may change until you leave with /mode ask')
    else
      EmitCLn(clYellow, '  mode: ' + uTools.PermModeName(M));
    if M = uTools.pmodeAsk then
      EmitCLn(clGrey, '  every write, shell command and fetch will be asked ' +
        'about again');
    Exit;
  end;

  EmitCLn(clBright, 'Permission mode');
  EmitCLn(clGrey, '  mode:         ' +
    uTools.PermModeName(uTools.CurrentPermMode));
  if uTools.PlanMode then
    EmitCLn(clGrey, '  plan mode:    on - every changing tool is refused ' +
      'before the gate is reached')
  else
    EmitCLn(clGrey, '  plan mode:    off');
  EmitLn;
  EmitCLn(clGrey, '  file edits:   ' +
    Choice(uTools.AllowAllEdits, 'approved', 'asked about'));
  EmitCLn(clGrey, '  shell:        ' +
    Choice(uTools.AllowAllBash, 'approved', 'asked about'));
  EmitCLn(clGrey, '  fetch:        ' +
    Choice(uTools.AllowAllFetch, 'approved', 'asked about'));
  EmitCLn(clGrey, '  mcp tools:    ' +
    Choice(uTools.AllowAllMcp, 'approved', 'asked about'));
  Grants := uTools.PermGrantSummary;
  if Grants <> '' then
    EmitCLn(clGrey, '  standing:     ' + Grants);
  EmitLn;
  if YoloSession then
    EmitCLn(clGrey, '  nothing from this session will be saved to the ' +
      'approvals file')
  else
    EmitCLn(clGrey, '  approvals given this session are saved to ' +
      uTools.ApprovalsPath);
  EmitLn;
  { Said out loud because the promise would otherwise be oversold.  Plan mode
    is a boundary on the MODEL's tool calls; a SessionStart or UserPromptSubmit
    hook is a command the user configured themselves and runs regardless. }
  EmitCLn(clGrey, '  Plan mode stops the model, not the machine: your own');
  EmitCLn(clGrey, '  hooks still run.  Deny rules beat every mode, always.');
  EmitCLn(clGrey, '  /mode ask | plan | accept-edits   (/yolo for bypass)');
  { Named here because a mode and a sandbox level are the two things most
    easily confused for each other, and they are on different axes: a mode
    decides what you are ASKED, the sandbox decides what a child process CAN
    DO once you have said yes. }
  EmitCLn(clGrey, '  sandbox:      ' +
    uSandbox.SandboxLevelName(uSandbox.SandboxLevel) +
    ' (/sandbox) - what a child process may do, not what you are asked');
end;

{ --------------------------------------------------------- the sandbox -- }

{ The scratch directory a low-integrity child is given as its TEMP, keyed the
  way ApprovalsPath is keyed and put in the same place, out of the tree.  Two
  reasons, one of them specific to this feature: a clone must not be able to
  ship it, and a directory labelled low integrity is writable by every other
  low-integrity process on the machine - browser renderers included - which is
  a thing to keep under %LOCALAPPDATA% rather than inside somebody's source. }
function SandboxScratchDir: string;
begin
  Result := uSandbox.SandboxScratchPath(uTools.SessionKey);
end;

{ True when low is usable.  Called before the level is accepted from anywhere,
  so 'low' is never a word printed over a sandbox that is not running. }
function PrepareSandbox: Boolean;
begin
  Result := uSandbox.SandboxSetScratchRoot(SandboxScratchDir) and
    uSandbox.SandboxLowReady;
end;

procedure ShowSandbox(const Arg: string);
var
  L: uSandbox.TSandboxLevel;
begin
  if Trim(Arg) = '' then
  begin
    EmitCLn(clBright, '  sandbox: ' +
      uSandbox.SandboxLevelName(uSandbox.SandboxLevel));
    EmitCLn(clGrey, '  ' + uSandbox.SandboxDescribe(uSandbox.SandboxLevel));
    EmitLn;
    { Said every time, because the honest limit is the part a user would
      otherwise assume away.  A confined command can still read every file
      the user can read and still reach the network: scoping a child to a
      directory needs a filesystem filter driver and blocking its network
      needs a firewall rule, and neither is something an ordinary process
      can do to itself. }
    EmitCLn(clGrey, '  No level stops a command READING your files, and no ' +
      'level stops it using');
    EmitCLn(clGrey, '  the network.  The sandbox is defence in depth; it is ' +
      'not a reason to');
    EmitCLn(clGrey, '  approve a command you would otherwise refuse, and it ' +
      'changes nothing');
    EmitCLn(clGrey, '  about what you are asked.');
    if uSandbox.SandboxLevel = uSandbox.slLow then
    begin
      EmitLn;
      EmitCLn(clGrey, '  scratch: ' + uSandbox.SandboxTempDir);
      EmitCLn(clGrey, '  That directory is writable by any other ' +
        'low-integrity program on this');
      EmitCLn(clGrey, '  machine, so a command that writes a secret to ' +
        '%TEMP% puts it somewhere');
      EmitCLn(clGrey, '  more exposed than %TEMP% was.');
    end;
    EmitLn;
    EmitCLn(clGrey, '  /sandbox off | limits | low');
    Exit;
  end;
  if not uSandbox.SandboxParseLevel(Trim(Arg), L) then
  begin
    EmitCLn(clYellow, '  not a sandbox level: ' + Arg +
      '  (off, limits or low)');
    Exit;
  end;
  if (L = uSandbox.slLow) and not PrepareSandbox then
  begin
    EmitCLn(clYellow, '  low is unavailable: there is no writable scratch ' +
      'directory outside');
    EmitCLn(clYellow, '  the project to give children as %TEMP%.  Staying at ' +
      uSandbox.SandboxLevelName(uSandbox.SandboxLevel) + '.');
    Exit;
  end;
  uSandbox.SandboxLevel := L;
  EmitCLn(clGrey, '  sandbox: ' + uSandbox.SandboxLevelName(L));
  EmitCLn(clGrey, '  ' + uSandbox.SandboxDescribe(L));
  { The two axes are separate and saying so here is cheaper than a bug
    report: the sandbox takes capability away from a child process and has
    no opinion at all about what you will be asked to approve. }
  EmitCLn(clGrey, '  You will be asked about commands exactly as before.');
end;

{ Split from ShowMode only so /plan can reach the same code with no argument
  parsing of its own. }
procedure SetMode(const Cmd, Arg: string);
begin
  if (Cmd = '/plan') and (Arg = '') then
    ShowMode('plan')
  else
    ShowMode(Arg);
end;

{ ------------------------------------------------ working directories -- }

{ With no argument, the whole set, numbered as /remove-dir wants them; with
  one, the add.  The echo is uTools' normalised path rather than what was
  typed, because a fat-fingered ..\.. is only visible once it is expanded -
  and because what was granted is the resolved directory, not the text. }
procedure ShowWorkingDirs(const Arg: string);
var
  I: Integer;
  Norm, Err: string;
begin
  if Trim(Arg) = '' then
  begin
    EmitCLn(clGrey, Format('  %2d  %s  (session root)', [0, uTools.RootDir]));
    for I := 1 to uTools.RootCount - 1 do
      EmitCLn(clGrey, Format('  %2d  %s', [I, uTools.RootAt(I)]));
    if uTools.RootCount = 1 then
      EmitCLn(clGrey, '  /add-dir <directory> to work in another one too');
    Exit;
  end;
  if not uTools.AddWorkingDir(Trim(Arg), Norm, Err) then
  begin
    EmitCLn(clRed, '  ' + Err);
    Exit;
  end;
  EmitCLn(clGrey, '  added ' + Norm);
  if Err <> '' then
    EmitCLn(clYellow, '  ' + Err);
  { Said every time rather than once: a user who expected a relative path to
    start meaning the added tree would otherwise find out by a refusal. }
  EmitCLn(clGrey, '  name files there by absolute path; relative paths still ' +
    'mean the session root');
end;

procedure DropWorkingDir(const Arg: string);
var
  Err: string;
begin
  if Trim(Arg) = '' then
  begin
    EmitCLn(clGrey, '  /remove-dir <number|path> - /cwd lists them');
    Exit;
  end;
  if uTools.RemoveWorkingDir(Trim(Arg), Err) then
    { Honest about what it does not do: anything already read is in the
      transcript and stays there.  This narrows future reach only. }
    EmitCLn(clGrey, '  removed; files already read stay in the conversation')
  else
    EmitCLn(clRed, '  ' + Err);
end;

procedure ShowHelp;
begin
  EmitCLn(clBright, 'Commands');
  EmitCLn(clGrey,   '  /help          this list');
  EmitCLn(clGrey,   '  /clear         forget the conversation, here and on disk');
  EmitCLn(clGrey,   '  /compact       drop the oldest turns, keep the recent ones');
  EmitCLn(clGrey,   '  /compact full  replace the transcript with a model-written summary');
  EmitCLn(clGrey,   '  /diff          list the files this session has changed');
  EmitCLn(clGrey,   '  /review        have the model review a local diff:');
  EmitCLn(clGrey,   '                 no argument is the working tree, --staged');
  EmitCLn(clGrey,   '                 is the index, <ref> is what this branch');
  EmitCLn(clGrey,   '                 adds. No network and no token');
  EmitCLn(clGrey,   '  /pr-comments   review comments on a GitHub pull request:');
  EmitCLn(clGrey,   '                 <n>, or the PR for this branch. Printed');
  EmitCLn(clGrey,   '                 first, then sent to the model as data;');
  EmitCLn(clGrey,   '                 --show prints and sends nothing. Read only');
  EmitCLn(clGrey,   '  /hooks         hooks, yours and this project''s; /hooks off');
  EmitCLn(clGrey,   '                 disables both for the session');
  EmitCLn(clGrey,   '  /jobs          background commands still running');
  EmitCLn(clGrey,   '  /mcp           MCP servers, yours and this project''s:');
  EmitCLn(clGrey,   '                 status, restart, refresh');
  EmitCLn(clGrey,   '  /memory        show the project memory (CLAUDE.md)');
  EmitCLn(clGrey,   '  /init          have the model write a CLAUDE.md for this project');
  EmitCLn(clGrey,   '  /rewind        undo turns: conversation and edited files');
  EmitCLn(clGrey,   '  /sessions      saved conversations in this directory');
  EmitCLn(clGrey,   '  /skills        skills this project offers; also rescans for new ones');
  EmitCLn(clGrey,   '  /plugins       installed plugins; /plugins enable|disable <name>');
  EmitCLn(clGrey,   '  /think [n]     extended thinking: on, off, or a token budget');
  EmitCLn(clGrey,   '  /web [on|off]  let the model search the web (off by default)');
  EmitCLn(clGrey,   '  /resume        reload the saved conversation');
  EmitCLn(clGrey,   '  /save          write the conversation now');
  EmitCLn(clGrey,   '  /cwd           show the session root and any added directories');
  EmitCLn(clGrey,   '  /add-dir <dir> also work in that directory (absolute paths only)');
  EmitCLn(clGrey,   '  /remove-dir <n> stop working in it; the session root cannot go');
  EmitCLn(clGrey,   '  /model [name]  pick a model from a list, or set one by name');
  EmitCLn(clGrey,   '  /deny          rules nothing can override; add <rule>, remove <n>');
  EmitCLn(clGrey,   '  /mode [name]   ask | plan | accept-edits; no argument shows the state');
  EmitCLn(clGrey,   '  /plan          shorthand for /mode plan: read and investigate only');
  EmitCLn(clGrey,   '  /yolo          approve every tool for this session (bypass)');
  EmitCLn(clGrey,   '  /sandbox [lvl] off | limits | low: how confined child processes are');
  EmitCLn(clGrey,   '  /output-style [name]  how replies are written; no argument lists them');
  EmitCLn(clGrey,   '  /paste         attach the clipboard image to your next message');
  EmitCLn(clGrey,   '  /vim [on|off|save]  modal line editing; save keeps it');
  EmitCLn(clGrey,   '  /keys          the editing keys, and where to rebind them');
  EmitCLn(clGrey,   '  /ide           the editor around this terminal, if any;');
  EmitCLn(clGrey,   '                 diff [<path>] opens what this session changed,');
  EmitCLn(clGrey,   '                 open <path>[:line] opens a file. Nothing is sent');
  EmitCLn(clGrey,   '                 to the model and no selection is read back');
  EmitCLn(clGrey,   '  /config        settings and where each value came from;');
  EmitCLn(clGrey,   '                 get <k>, set [--local] <k> <v>, unset, reload');
  EmitCLn(clGrey,   '  /cost          tokens used so far');
  EmitCLn(clGrey,   '  /telemetry     usage metrics: off unless YOUR settings');
  EmitCLn(clGrey,   '                 file turns them on; preview shows the');
  EmitCLn(clGrey,   '                 exact JSON, send flushes now');
  EmitCLn(clGrey,   '  /login [key]   which credential answers; key stores one of');
  EmitCLn(clGrey,   '                 pasclaude''s own, encrypted, out of the project');
  EmitCLn(clGrey,   '  /logout        remove that stored credential (only that one:');
  EmitCLn(clGrey,   '                 Claude Code''s and Jcode''s are read, never written)');
  EmitCLn(clGrey,   '  /status        what is true right now: model, credential,');
  EmitCLn(clGrey,   '                 mode, roots, MCP, hooks, style, tokens');
  EmitCLn(clGrey,   '  /doctor        what is wrong or might be, with a remedy each.');
  EmitCLn(clGrey,   '                 Offline and makes no request; --online adds one');
  EmitCLn(clGrey,   '                 GET asking which models this credential can use');
  EmitCLn(clGrey,   '  /bug           write a redacted report to a file for a');
  EmitCLn(clGrey,   '                 maintainer. Nothing is uploaded, ever.');
  EmitCLn(clGrey,   '                 --transcript adds your conversation, --paths');
  EmitCLn(clGrey,   '                 keeps real paths, --json writes JSON');
  EmitCLn(clGrey,   '  /exit          quit (Ctrl+C also works)');
  EmitLn;
  EmitCLn(clGrey,   '  Esc during a reply stops it. Esc twice on a prompt line that was');
  EmitCLn(clGrey,   '  ALREADY empty opens /rewind (not with /vim on, where Esc is');
  EmitCLn(clGrey,   '  normal mode).');
  EmitCLn(clGrey,   '  A file in .pasclaude\commands\ is a slash command; one in');
  EmitCLn(clGrey,   '  .pasclaude\agents\ is a subagent type the task tool can ask for;');
  EmitCLn(clGrey,   '  .pasclaude\skills\<name>\SKILL.md is a skill the model can read;');
  EmitCLn(clGrey,   '  .pasclaude\styles\<name>.md is an output style.');
  EmitCLn(clGrey,   '  A directory in .pasclaude\plugins\ can carry all four, once you');
  EmitCLn(clGrey,   '  enable it by name. A skill added mid-session appears after /skills;');
  EmitCLn(clGrey,   '  an edited style file applies by itself, from the next turn.');
  EmitCLn(clGrey,   '  To drive pasclaude from another program: -p with');
  EmitCLn(clGrey,   '  --output-format json|stream-json (see pasclaude --help).');
end;

{ Hook failures, matcher budgets and load-time notes.  Yellow, because none of
  them stops the session and all of them mean something in a file is not doing
  what its author expected. }
procedure HookNotice(const Msg: string);
begin
  NeedNewLine;
  EmitCLn(clYellow, '  ' + Msg);
  { And into the ledger, because this is the funnel for both the hook notes
    and the keys.json ones and /doctor replays the ledger rather than
    re-reading either file - re-reading hooks.json would re-ask a trust
    question the user already answered. }
  uDiag.DiagNote('hooks', uDiag.dlWarn, Msg,
    '/hooks shows what hooks.json asks for; /keys shows the bindings');
end;

{ Where the prompt history lives, beside the session. }
function HistoryPath: string;
begin
  Result := IncludeTrailingPathDelimiter(uTools.RootDir) + SessionDir +
    PathDelim + 'history.txt';
end;

{ Where the keybindings live - and pointedly NOT under the session root.
  Everything in <root>\.pasclaude arrives with a git clone, and this file
  decides what keystrokes do; a repository that could ship one would be
  choosing how the user's keyboard behaves before they had read a line of it.
  %USERPROFILE% rather than %LOCALAPPDATA% because this is hand-authored
  configuration the user writes and has to be able to find, the same argument
  as the user-level CLAUDE.md (uSdk.SdkUserContext).  LOCALAPPDATA is where
  the program keeps state IT writes, keyed by session; bindings are neither. }
function KeysPath: string;
begin
  Result := IncludeTrailingPathDelimiter(
    GetEnvironmentVariable('USERPROFILE')) + SessionDir + PathDelim +
    'keys.json';
end;

{ The three settings files, and the scope argument for each written out the
  way KeysPath's is, because this is the surface where getting the scope wrong
  is most expensive.

  The user file sits in %USERPROFILE% for exactly KeysPath's reason:
  LOCALAPPDATA is where the program keeps state IT writes, keyed by session
  (approvals, deny.json, the sandbox scratch), and this is hand-authored
  configuration the user must be able to find and edit - the same argument as
  the user-level CLAUDE.md.

  The project and local files arrive with a clone, and that is why the key
  table exists: what they may say is a property of uSettings.SettingDefs, not
  of what happens to be written in them.  The local one is gitignored by
  convention only, so it carries project authority and not user authority -
  .gitignore does not stop a committed file. }
function SettingsUserPath: string;                          { user scope }
begin
  Result := IncludeTrailingPathDelimiter(
    GetEnvironmentVariable('USERPROFILE')) + SessionDir + PathDelim +
    uSettings.SettingsFileName;
end;

function SettingsProjectPath: string;                       { project scope }
begin
  Result := IncludeTrailingPathDelimiter(uTools.RootDir) + SessionDir +
    PathDelim + uSettings.SettingsFileName;
end;

function SettingsLocalPath: string;             { project scope, gitignored }
begin
  Result := IncludeTrailingPathDelimiter(uTools.RootDir) + SessionDir +
    PathDelim + uSettings.SettingsLocalFileName;
end;

{ The four keys settings.json may actually move, applied in one place so
  startup and /config reload cannot drift apart.  Deliberately NOT the style:
  that has three sources to rank and lives in the post-halt startup block with
  the other two.

  Agent may be nil - the startup call happens before TAgent.Create, because
  MaxOutBytes and CompactTokens have to be right before anything reads them
  and the agent does not exist yet.  The thinking budget is picked up on the
  second call, immediately after Create. }
procedure ApplySettings;
begin
  if uSettings.SettingIsSet('tool_result_bytes') then
    uTools.MaxOutBytes := uSettings.SettingInt('tool_result_bytes');
  if uSettings.SettingIsSet('auto_compact_tokens') then
    CompactTokens := uSettings.SettingInt('auto_compact_tokens');
  { Guarded on IsSet rather than assigned unconditionally: a settings file
    that never mentions thinking must not switch it off, and /think later in
    the session records itself as the runtime source so this reads back the
    typed value rather than the file's.

    No clamp here, and deliberately: the API's 1024 floor and the narrow-only
    rule are both enforced in uSettings' table, where a value that fails them
    is never stored at all.  A clamp in this procedure would be a second
    opinion about the same question, and the two would drift. }
  if (Agent <> nil) and uSettings.SettingIsSet('thinking_budget') then
    Agent.ThinkingBudget := uSettings.SettingInt('thinking_budget');
end;

{ The alias table and the two routes, from the USER settings file only.
  model, model.alias, model.route.subagent and model.route.compaction are
  scUserOnly in uSettings.SettingDefs, and TierAllowed means a project value
  for one of them is never stored - so this reads what a project tree cannot
  have written, and there is no scope test to get wrong here.

  A repository choosing the model was refused rather than prompted.  It
  spends the user's money recurrently with no ceiling, and it can quietly
  downgrade the reviewer of its own code - a repo that names the weakest id
  gets a worse audit of itself and nothing in the output says so.  A prompt
  is the wrong shape for that: the question is cheap to answer yes to and the
  cost recurs.  A project file that tries is already named in yellow by the
  settings loader, which voids the whole file, so nothing is added here.

  Refusals are notes, never fatal.  An unresolvable alias is not a startup
  error either: there is deliberately no preflight against /v1/models - it
  would add a round trip to every start including -p and could still only
  answer "this key's list mentions it".  A bad id surfaces as a 404 on the
  first turn with the alias named in the message. }
procedure ApplyModelSettings;
var
  Keys, Vals: TStringArray;
  I: Integer;
  Err: string;
begin
  if uSettings.SettingMap('model.alias', Keys, Vals) then
    for I := 0 to High(Keys) do
      if not SetModelAlias(Keys[I], Vals[I], Err) then
        EmitCLn(clYellow, '  settings: model.alias "' + Keys[I] + '": ' + Err);
  if uSettings.SettingIsSet('model.route.subagent') then
    SetModelRoute(mrSubagent, uSettings.SettingStr('model.route.subagent'));
  if uSettings.SettingIsSet('model.route.compaction') then
    SetModelRoute(mrCompact, uSettings.SettingStr('model.route.compaction'));
end;

var
  KeysFileFound: Boolean = False;

{ Standing approvals - and pointedly NOT beside the session and the history.
  Everything else under <root>\.pasclaude describes the project; this one
  records what the user let the project do, and a project that can supply its
  own answer to that has not been asked anything.  uTools.ApprovalsPath puts
  it under %LOCALAPPDATA%, keyed by the root path. }
function PermissionsPath: string;
begin
  Result := uTools.ApprovalsPath;
end;

{ Which plugins are enabled - a different question from what is approved, and
  deliberately a different file.  permissions.json only ever widens on load,
  which would make a disable that did not survive a restart; this one is read
  as written, in both directions. }
function PluginStatePath: string;
begin
  Result := IncludeTrailingPathDelimiter(uTools.RootDir) + SessionDir +
    PathDelim + uTools.PluginStateName;
end;

{ The first-contact question for .pasclaude\hooks.json.  Nothing on disk is
  trusted initially: the file is executable configuration a git clone can
  carry, and running it before the user has read it is remote code execution.
  Today the only path to arbitrary code is bash's per-program prompt, and this
  must not become a second path that skips it.

  The fingerprint is over the bytes, so editing the file re-asks - an "always"
  that survived the text changing under it would be an approval of something
  never read.  Same y/a/n vocabulary, same file, same narrow-always rule as the
  bash prefixes.  /yolo deliberately does not answer this question.

  It is asked about the PROJECT file and only ever that.  The user's own
  %USERPROFILE%\.pasclaude\hooks.json is loaded whatever this returns, is never
  fingerprinted and is never prompted for - prompting somebody about a file
  only they can write is noise that teaches them to answer yes, and every yes
  it trains is spent later on this prompt.  uHooks.HooksConfigured is False
  when the session root IS the home directory, so a file that is both is the
  user's and no question is asked about it here. }
function TrustHooks: Boolean;
var
  FP: string;
begin
  Result := False;
  if not uHooks.HooksConfigured then Exit;
  FP := uHooks.HookFingerprint;
  if (FP <> '') and (FP = uTools.LoadTrustedEntry(PermissionsPath,
                            uHooks.HookTrustKey)) then Exit(True);

  case AskPermission('hooks',
         'this project defines hooks: ' + SessionDir + PathDelim +
         uHooks.HooksFileName + #10 +
         'these commands run automatically, before you approve anything else'#10 +
         uHooks.HookSummaryOf(uHooks.HooksFilePath)) of
    pmAllowOnce: Result := True;
    pmAllowAlways:
      begin
        { Recorded in the same "trusted" object MCP uses, so one mechanism
          answers "which of this project's programs did I say yes to". }
        uTools.RecordTrust(uHooks.HookTrustKey, FP);
        Result := True;
      end;
  else
    { Named as this project's, because with a user file loaded the flat old
      sentence is no longer true: refusing the project's hooks leaves the
      user's own running, and a line that said otherwise would be a lie about
      what is about to execute. }
    EmitCLn(clGrey,
      '  this project''s hooks are off for this session (/hooks shows them)');
  end;
end;

{ The project memory file.  CLAUDE.md is preferred when it exists because
  that is where users of Claude Code already keep this; otherwise whichever
  instruction file the project has; otherwise CLAUDE.md gets created. }
function MemoryPath: string;
var
  Names: array[0..2] of string = ('CLAUDE.md', 'AGENTS.md', '.pasclaude.md');
  I: Integer;
begin
  for I := 0 to High(Names) do
  begin
    Result := IncludeTrailingPathDelimiter(uTools.RootDir) + Names[I];
    if FileExists(Result) then Exit;
  end;
  Result := IncludeTrailingPathDelimiter(uTools.RootDir) + 'CLAUDE.md';
end;

{ Appends one remembered line to the project memory.  The note lands under
  a Notes heading so hand-written instructions above it stay untouched.
  This is the # shortcut: fact in, file grows, next session knows it. }
procedure RememberNote(const Note: string);
var
  Path, Text: string;
  L: TStringList;
begin
  Path := MemoryPath;
  L := TStringList.Create;
  try
    if FileExists(Path) then
    try
      L.LoadFromFile(Path);
    except
      on E: Exception do
      begin
        EmitCLn(clRed, '  could not read ' + ExtractFileName(Path) + ': ' + E.Message);
        Exit;
      end;
    end;
    Text := L.Text;
    if Pos('## Notes', Text) = 0 then
    begin
      if (Text <> '') and (Copy(Text, Length(Text), 1) <> #10) then
        L.Add('');
      if Text = '' then
        L.Add('# Project notes')
      else
        L.Add('');
      L.Add('## Notes');
    end;
    L.Add('- ' + Note);
    try
      L.SaveToFile(Path);
      EmitCLn(clGrey, '  remembered in ' + ExtractFileName(Path));
      EmitCLn(clGrey, '  (takes effect next session; project instructions load at startup)');
      { And not even then, if this session was told to ignore the tree's own
        files.  Writing a note into a file nothing reads is the small waste
        this line exists to stop; it says nothing about the note being saved,
        which it was. }
      if not uSdk.SdkProjectContextAllowed then
        EmitCLn(clGrey, '  (this session was started with --no-project-context, ' +
          'so it is not loaded)');
    except
      on E: Exception do
        EmitCLn(clRed, '  could not write ' + ExtractFileName(Path) + ': ' + E.Message);
    end;
  finally
    L.Free;
  end;
end;

{ Shows the memory file, numbered, so /memory answers "what does this
  project tell the agent?" without opening an editor. }
procedure ShowMemory;
var
  Path: string;
  L: TStringList;
  I: Integer;
begin
  Path := MemoryPath;
  if not FileExists(Path) then
  begin
    EmitCLn(clGrey, '  no project memory yet (# a note, or /init, creates ' +
      ExtractFileName(Path) + ')');
    Exit;
  end;
  EmitCLn(clBright, '  ' + ExtractFileName(Path) + ':');
  { The file is printed either way - /memory answers "what does this project
    tell the agent?" and the honest answer under the flag is "this, and it was
    not told" - but a reader editing prose nothing will read deserves to know
    before they spend the effort. }
  if not uSdk.SdkProjectContextAllowed then
    EmitCLn(clGrey, '  (this session was started with --no-project-context, ' +
      'so it is not loaded)');
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(Path);
    except
      on E: Exception do
      begin
        EmitCLn(clRed, '  could not read it: ' + E.Message);
        Exit;
      end;
    end;
    for I := 0 to L.Count - 1 do
      EmitCLn(clGrey, Format('  %3d  %s', [I + 1, L[I]]));
  finally
    L.Free;
  end;
end;

{ Credentials live in uAuth now.  Lifting the readers out of this file is
  most of what /login is worth: while TokenFromClaudeCode and TokenFromJcode
  lived here they were unreachable from all five suites, so two parsers for
  two other programs' JSON - expiry handling included - had no coverage at
  all.  The Why strings they produced are preserved word for word in uAuth,
  because they are the one thing a user with no working credential ever
  reads. }

function ReadFileText(const Path: string; out Text: string): Boolean;
var
  F: TFileStream;
begin
  Result := False;
  Text := '';
  if not FileExists(Path) then Exit;
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Text, F.Size);
      if F.Size > 0 then F.ReadBuffer(Text[1], F.Size);
    finally
      F.Free;
    end;
    Result := True;
  except
    Result := False;
  end;
end;



{ Reads keys.json if it is there, reports every refused entry, and installs
  the result.  A missing file is the built-in defaults in silence; a broken
  one is the built-in defaults plus notes.  Neither can fail the session, and
  neither can widen anything: the worst a file achieves is different editing. }
procedure LoadKeys;
var
  Text: string;
  P: TKeyProfile;
  Notes: TStringArray;
  I: Integer;
begin
  Notes := nil;
  KeysFileFound := FileExists(KeysPath);
  if not KeysFileFound then
  begin
    SetPromptProfile(KeysDefault);
    Exit;
  end;
  if not ReadFileText(KeysPath, Text) then
  begin
    HookNotice('keys.json could not be read; using the built-in bindings');
    SetPromptProfile(KeysDefault);
    Exit;
  end;
  KeysParse(Text, P, Notes);
  for I := 0 to High(Notes) do
    HookNotice('keys.json: ' + Notes[I]);
  SetLength(Notes, 0);
  SetPromptProfile(P);
end;

{ Telemetry, from the six user-scope keys of the settings files and from
  nowhere else.  No argv flag sets an endpoint and OTEL_EXPORTER_OTLP_ENDPOINT
  is deliberately NOT honoured: environment is inherited from whatever
  launched us, so a wrapper script in a repository would otherwise hand a
  project the endpoint by the back door - and a project-settable telemetry URL
  is an exfiltration channel wearing a respectable name.

  TierAllowed in uSettings is the enforcement: telemetry.enabled,
  .endpoint, .headers, .interval_turns, .timeout_ms and .service_name are all
  scUserOnly, so a project or local file naming one is refused by name and the
  value is never stored where this could read it. }
procedure LoadTelemetry;
var
  C: TTelemConfig;
  Notes: TStringArray;
  I: Integer;
begin
  C := uTelem.TelemConfigFromSettings(Version);
  uTelem.TelemInit(C);
  { Read back out of the unit, not off the record handed in: TelemInit copies,
    and the refusals that matter most - a bad endpoint, an unsendable header -
    are the ones it adds itself. }
  Notes := uTelem.TelemNotes;
  for I := 0 to High(Notes) do
    HookNotice('telemetry: ' + Notes[I]);
end;

{ The two recording callbacks, wired to the agent after it is built.  Both are
  deliberately narrow.  TelemToolDone uses ONLY Name and IsErr and never
  touches Output, which is tool RESULT TEXT - the single largest thing in this
  program that must not leave the machine. }
procedure TelemToolDone(const Id, Name, Output: string; IsError: Boolean);
begin
  uTelem.TelemRecordTool(Name, IsError);
end;

procedure TelemRequestDone(StatusCode, ElapsedMs: Integer; const Model: string);
begin
  uTelem.TelemRecordRequest(StatusCode, ElapsedMs);
end;

{ A session load moves the agent's cumulative counters without a turn having
  happened, so the telemetry baseline moves with it or the whole of somebody
  else's session is reported as this one's first turn.  Every LoadSession and
  SdkResumeInto call site calls this; a fresh session needs no call, because
  TelemInit baselines at the zero a fresh TAgent starts from.  That is the
  point: baselining on the first RECORD instead threw the first turn of every
  session away, and a -p run has exactly one turn. }
procedure TelemRebaseline;
begin
  if Agent = nil then Exit;
  uTelem.TelemBaseline(Agent.TokensIn, Agent.TokensOut,
    Agent.CacheReadTokens, Agent.CacheWriteTokens);
end;

{ One flush.  Synchronous, because this program has no threads: the honest
  price is at worst telemetry.timeout_ms of dead air before the next prompt,
  at most once every telemetry.interval_turns turns.  The third consecutive
  failure says so once and goes quiet for the rest of the process. }
procedure FlushTelemetry;
var
  Status: Integer;
  Err: string;
  WasDisabled: Boolean;
begin
  if not uTelem.TelemEnabled then Exit;
  WasDisabled := uTelem.TelemState.SelfDisabled;
  if uTelem.TelemFlush(Status, Err) then Exit;
  if (not WasDisabled) and uTelem.TelemState.SelfDisabled then
    HookNotice('telemetry stopped after ' + IntToStr(uTelem.TelemMaxFailures) +
      ' failures (' + Err + '); nothing more will be sent this session');
end;

{ /vim save.  Read-modify-write so a hand-written bindings block survives;
  JSON has no comments, so nothing else can be lost. }
function SaveVimSetting(out Err: string): Boolean;
var
  Text, Out_: string;
  F: TFileStream;
begin
  Err := '';
  Text := '';
  ReadFileText(KeysPath, Text);
  Out_ := KeysToJson(PromptProfile, Text);
  if not ForceDirectories(ExtractFilePath(KeysPath)) then
  begin
    Err := 'cannot create ' + ExtractFilePath(KeysPath);
    Exit(False);
  end;
  try
    F := TFileStream.Create(KeysPath, fmCreate);
    try
      if Out_ <> '' then F.WriteBuffer(Out_[1], Length(Out_));
    finally
      F.Free;
    end;
  except
    on E: Exception do
    begin
      Err := E.Message;
      Exit(False);
    end;
  end;
  KeysFileFound := True;
  Result := True;
end;

{ What this session changed.  git diff --stat is the richer answer when
  there is a repository - it also sees compiler output and hand edits - so
  the session's own list leads and the stat follows when available. }
procedure ShowDiff;
var
  Changed: TStringArray;
  I, Code: Integer;
  Stat, GitCmd: string;
  L: TStringList;
begin
  Changed := uTools.ChangedFiles;
  if Length(Changed) = 0 then
    EmitCLn(clGrey, '  no files written or edited this session')
  else
  begin
    EmitCLn(clBright, Format('  %d file(s) changed by this session:',
      [Length(Changed)]));
    for I := 0 to High(Changed) do
      EmitCLn(clGrey, '    ' + Changed[I]);
  end;

  { Composed through ProgramCommand: a bare 'git' in a cmd.exe /C line runs
    the current directory's git.cmd first, and the current directory here is
    the session root - a cloned repository. }
  GitCmd := uTools.ProgramCommand('git', 'diff --stat HEAD');
  if GitCmd = '' then Exit;
  Stat := uTools.RunShellQuiet(GitCmd, Code);
  if (Code = 0) and (Trim(Stat) <> '') then
  begin
    EmitCLn(clBright, '  git diff --stat HEAD:');
    L := TStringList.Create;
    try
      L.Text := Stat;
      for I := 0 to L.Count - 1 do
        if Trim(L[I]) <> '' then
          EmitCLn(clGrey, '    ' + L[I]);
    finally
      L.Free;
    end;
  end;
end;

{ ------------------------------------------------------------------ /ide -- }

{ Session only, and deliberately never written to disk.  "a" here means "stop
  asking me this session", not "this program may start editors from now on":
  a persisted grant would be a standing licence to run a named program, and
  the approvals file is for tools the MODEL asks for, answered per project.
  A user who wants it permanent already has one - ide.command in their own
  settings.json - and that one they had to type out in full. }
var
  IdeGrantedThisSession: Boolean = False;

{ Out of the tree, always.  A baseline written beside the file it is a
  baseline OF would be a file this program created inside the project that
  the project's own tooling would then see, and it would sit inside the
  reach every deny rule and every approval is written against.  '' when
  there is nowhere out of tree to put it, and the command then refuses
  rather than falling back into the checkout - the same rule ApprovalsPath
  follows. }
function IdeScratchDir: string;
var
  Home: string;
begin
  Result := '';
  Home := Trim(SysUtils.GetEnvironmentVariable('LOCALAPPDATA'));
  if Home = '' then Home := Trim(SysUtils.GetEnvironmentVariable('USERPROFILE'));
  if Home = '' then Exit;
  Result := IncludeTrailingPathDelimiter(Home) + 'pasclaude' + PathDelim +
    'ide' + PathDelim;
end;

const
  IdeScratchMaxAgeDays = 1.0;

{ Files older than IdeScratchMaxAgeDays, on the way in - and that is now ALL
  this sweep does.  The ordinary lifetime of a "before" side belongs to
  uIde.IdeHoldScratch and uIde.IdeDropScratch: the next /ide diff deletes the
  last one, a refused or failed launch deletes it at once, and the session's
  end deletes it through uIde's finalization.  So the only file this ever
  meets is one orphaned by a stop that ran no finalization at all -
  Ctrl+Break, a console window closed with its X, Task Manager.

  BE PRECISE ABOUT WHAT THAT BUYS, because the obvious sentence is wrong.
  This has exactly one call site, a few lines below, inside the /ide diff
  path.  It is not a startup sweep and it must not be read as one: a user
  whose session was killed with a diff tab open, and who never types /ide
  diff again, is never swept at all and that file stays until something else
  deletes it.  Making it a startup sweep was considered and refused - the
  startup path is deliberately free of mutations under --status, --doctor and
  the two --ci verbs, and a command whose name promises diagnosis must not
  delete files merely by being run, which is the same rule BackupSession is
  already skipped for.  So the bound this sweep offers is "the next time you
  ask for a diff", and the day-old test is what keeps that from deleting
  something live.

  Sweeping at exit was the option that was rejected here, and the reasoning
  stands where it was aimed: several exit paths go through Halt, which skips
  finally, and one of them is the Ctrl+C path where the user is already
  waiting.  Halt does run unit finalization, which is why the lifetime moved
  there rather than into a finally - see the comment at the foot of uIde.

  A day, still, and NOT the hour that looks tighter now that this is only a
  backstop.  The sweep cannot tell one session's leftovers from another's:
  a second pasclaude in another terminal keeps its live baseline in this same
  directory, and an hour is well inside the time a diff tab stays open, so a
  short bound would start deleting a file another session's editor is still
  reading.  Nothing is gained by shortening it either - the file this sweep
  finds is one no exit path got to, and there is no bound at which that stops
  being true. }
procedure IdeSweepScratch(const Dir: string);
var
  R: TSearchRec;
begin
  if FindFirst(Dir + '*', faAnyFile, R) <> 0 then Exit;
  try
    repeat
      if (R.Attr and faDirectory) <> 0 then Continue;
      if FileDateToDateTime(R.Time) < Now - IdeScratchMaxAgeDays then
        SysUtils.DeleteFile(Dir + R.Name);
    until FindNext(R) <> 0;
  finally
    FindClose(R);
  end;
end;

{ Every byte outside [A-Za-z0-9._-] replaced, so a filename the MODEL chose
  cannot climb out of the scratch directory no matter what it contains.  The
  extension survives the substitution, which is what makes the editor colour
  the left-hand pane of the diff. }
function IdeScratchName(const Base: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(Base) do
    if Base[I] in ['A'..'Z', 'a'..'z', '0'..'9', '.', '_', '-'] then
      Result := Result + Base[I]
    else
      Result := Result + '_';
  if Result = '' then Result := 'baseline';
  Result := 'base-' + Copy(Result, 1, 64);
end;

{ The scratch file this call just wrote, when this call is not going to launch
  anything after all.  It is a plain delete and NOT uIde.IdeDropScratch, which
  is the whole reason it exists: IdeDropScratch deletes whatever is HELD, and
  what is held at this point is the previous /ide diff's baseline, whose tab
  may still be open on screen.  A user who answers "n" is refusing this diff,
  not asking for the last one to be taken away.

  The one path that must not delete: Tmp IS the held file, because the same
  file was diffed twice.  The bytes were just rewritten identical, the earlier
  tab is reading that path, and there is nothing to clean up - the hold
  already covers it. }
procedure IdeDiscardScratch(const Tmp: string);
begin
  if CompareText(Tmp, uIde.IdeHeldScratch) = 0 then Exit;
  SysUtils.DeleteFile(Tmp);
end;

{ The whole gate for this feature, and it is here rather than in uTools
  because there is nothing in uTools to reach: a user-typed slash command
  never enters RunTool, so Permit, PermitBash and the deny rules have
  nothing to say about it - the same standing RunShellQuiet has.  Rather
  than leave it silently ungated, the exact line that is about to run is
  printed and the existing prompt is used. }
function IdeConfirmAndLaunch(const Line: string): Boolean;
var
  Err: string;
begin
  Result := False;
  if not IdeGrantedThisSession then
    case AskPermission('start your editor',
      'pasclaude will run this command line:' + #10 + Line + #10 +
      'Nothing it prints is read back, and no editor state is sent to the ' +
      'model.') of
      pmDeny: begin
        EmitCLn(clGrey, '  not started');
        Exit;
      end;
      pmAllowAlways: IdeGrantedThisSession := True;
    end;
  if uIde.IdeLaunch(Line, Err) then
    Result := True
  else
    EmitCLn(clYellow, '  ' + Err);
end;

procedure DoIde(const Arg: string);
var
  Host: uIde.TIdeHost;
  Cli, Verb, Rest, Full, Err, Line, Base, Text, Dir, Tmp: string;
  Changed: TStringArray;
  LineNo, P, I: Integer;
  Existed: Boolean;
  F: TFileStream;
begin
  Host := uIde.IdeDetect;
  Cli := '';
  { Both conditions, not either.  Detection alone was the tempting gate and
    it takes the off switch away from the user; ide.enabled alone would let
    a settings value start programs in a plain console, where the kept job
    object stops being safe because no editor is running to signal. }
  if uSettings.SettingIsSet('ide.enabled') and
     not uSettings.SettingBool('ide.enabled') then
  begin
    EmitCLn(clGrey, '  ide.enabled is false in your settings.json');
    Exit;
  end;
  if Host.Family <> ifNone then
    Cli := uIde.IdeResolveCli(Host, uSettings.SettingStr('ide.command'));

  Verb := LowerCase(Trim(Arg));
  Rest := '';
  P := Pos(' ', Verb);
  if P > 0 then
  begin
    Rest := Trim(Copy(Trim(Arg), P + 1, MaxInt));
    Verb := Copy(Verb, 1, P - 1);
  end;

  if Verb = '' then
  begin
    if Host.Family = ifNone then
    begin
      EmitCLn(clGrey, '  no editor detected around this terminal');
      EmitCLn(clGrey, '    VS Code sets TERM_PROGRAM and VSCODE_INJECTION in ' +
        'its integrated terminal;');
      EmitCLn(clGrey, '    JetBrains sets TERMINAL_EMULATOR. Neither is set ' +
        'here, so /ide does nothing.');
      Exit;
    end;
    EmitCLn(clBright, '  editor: ' + Host.Name +
      BoolToStr(Host.Version <> '', ' ' + Host.Version, ''));
    if Host.Product <> '' then
      EmitCLn(clGrey, '    reported by ' + Host.Product);
    if Cli <> '' then
      EmitCLn(clGrey, '    command line: ' + Cli)
    else
      EmitCLn(clYellow, '    no command-line program found; set ' +
        '"ide.command" in your own settings.json');
    EmitCLn(clGrey, '    /ide diff [<path>]     what this session changed, ' +
      'in a diff tab');
    EmitCLn(clGrey, '    /ide open <path>[:n]   open a file, optionally at a ' +
      'line');
    EmitCLn(clGrey, '    the editor is never read FROM: no selection, no ' +
      'cursor, nothing sent to the model');
    Exit;
  end;

  if (Verb <> 'diff') and (Verb <> 'open') then
  begin
    EmitCLn(clGrey, '  /ide, /ide diff [<path>], /ide open <path>[:line]');
    Exit;
  end;
  if Host.Family = ifNone then
  begin
    EmitCLn(clGrey, '  no editor detected around this terminal; /ide alone ' +
      'explains what is looked for');
    Exit;
  end;
  if Cli = '' then
  begin
    EmitCLn(clYellow, '  no editor command-line program could be found; ' +
      '/doctor says what to do about it');
    Exit;
  end;

  if Verb = 'open' then
  begin
    LineNo := 0;
    { A trailing :<n> is a line number only when every character after the
      last colon is a digit, so a drive letter and a path that simply
      contains a colon are both left alone. }
    P := Length(Rest);
    while (P > 0) and (Rest[P] in ['0'..'9']) do Dec(P);
    if (P > 1) and (P < Length(Rest)) and (Rest[P] = ':') then
    begin
      LineNo := StrToIntDef(Copy(Rest, P + 1, MaxInt), 0);
      Rest := Copy(Rest, 1, P - 1);
    end;
    if not uTools.ResolveInRoot(Rest, Full, Err) then
    begin
      EmitCLn(clYellow, '  ' + Err);
      Exit;
    end;
    if not FileExists(Full) then
    begin
      EmitCLn(clYellow, '  no such file: ' + Rest);
      Exit;
    end;
    if not uIde.IdeOpenLine(Host, Cli, Full, LineNo, Line, Err) then
    begin
      EmitCLn(clYellow, '  ' + Err);
      Exit;
    end;
    if IdeConfirmAndLaunch(Line) then
      EmitCLn(clGrey, '  opened ' + Rest);
    Exit;
  end;

  { diff.  With no argument, the session's own ledger answers when it names
    exactly one file; more than one and the user picks, because guessing
    which of six edits they meant is worse than a list. }
  if Rest = '' then
  begin
    Changed := uTools.ChangedFiles;
    if Length(Changed) = 0 then
    begin
      EmitCLn(clGrey, '  no files written or edited this session');
      Exit;
    end;
    if Length(Changed) > 1 then
    begin
      EmitCLn(clBright, '  name one of these:');
      for I := 0 to High(Changed) do
        EmitCLn(clGrey, '    /ide diff ' + Changed[I]);
      Exit;
    end;
    Rest := Changed[0];
  end;
  if not uTools.ResolveInRoot(Rest, Full, Err) then
  begin
    EmitCLn(clYellow, '  ' + Err);
    Exit;
  end;
  if not uTools.SessionBaseline(Full, Text, Existed) then
  begin
    { Two different facts, and they used to be printed as one sentence with
      an "or" in the middle, which is the shape of a message that does not
      know.  uTools records the oversize skip where it happens, so the case
      that used to be a silent shrug now names itself and names the number -
      and the number comes from the constant /rewind quotes rather than from
      a second copy of "400 KB" typed into prose here. }
    if uTools.SnapshotSkippedOversize(Full) then
    begin
      EmitCLn(clYellow, '  no baseline for ' + Rest + ': it was over ' +
        IntToStr(uTools.SnapshotLimitBytes div 1024) +
        ' KB when this session first touched it,');
      EmitCLn(clYellow, '    so nothing was held to diff against - the same ' +
        'limit, and the same reason, that stops /rewind restoring it');
    end
    else
      EmitCLn(clGrey, '  no baseline for ' + Rest +
        ': this session has not written it');
    Exit;
  end;
  if not FileExists(Full) then
  begin
    EmitCLn(clYellow, '  ' + Rest + ' is not there now; /rewind restores it');
    Exit;
  end;

  Dir := IdeScratchDir;
  if Dir = '' then
  begin
    EmitCLn(clYellow, '  neither %LOCALAPPDATA% nor %USERPROFILE% is set, ' +
      'so there is nowhere outside');
    EmitCLn(clYellow, '    this project to write the "before" side, and it ' +
      'is not written inside one');
    Exit;
  end;
  if not ForceDirectories(Dir) then
  begin
    EmitCLn(clYellow, '  could not create ' + Dir);
    Exit;
  end;
  IdeSweepScratch(Dir);
  Base := IdeScratchName(ExtractFileName(Full));
  Tmp := Dir + Base;
  try
    F := TFileStream.Create(Tmp, fmCreate);
    try
      { Bytes verbatim: an editor is not a consumer of ours and repairing
        the encoding here would show the user a "before" side that is not
        what the file held. }
      if Length(Text) > 0 then F.WriteBuffer(Text[1], Length(Text));
    finally
      F.Free;
    end;
  except
    on E: Exception do
    begin
      { fmCreate truncated the file before WriteBuffer failed, so there is
        something on disk here even though nothing succeeded - and on this
        path nothing else in the program knows about it.  The hold below is
        never reached, and both the shutdown finally and uIde's finalization
        only ever delete what was HELD, so a partial copy of project text
        would sit in %LOCALAPPDATA% as exactly the orphan this lifetime was
        rewritten to stop existing.  It is deleted here, at the only point
        that still has the path.

        Through uIde when it happens to BE the held file - the same file
        diffed twice - because those bytes are gone whatever happens next and
        a held path pointing at a ruined file is worse than none. }
      if CompareText(Tmp, uIde.IdeHeldScratch) = 0 then
        uIde.IdeDropScratch
      else
        SysUtils.DeleteFile(Tmp);
      EmitCLn(clYellow, '  could not write the "before" side: ' + E.Message);
      Exit;
    end;
  end;

  if not uIde.IdeDiffLine(Host, Cli, Tmp, Full, Line, Err) then
  begin
    IdeDiscardScratch(Tmp);
    EmitCLn(clYellow, '  ' + Err);
    Exit;
  end;
  if IdeConfirmAndLaunch(Line) then
  begin
    { Handed over only once something has been launched, and the ordering is
      the correction: holding it before the prompt meant that answering "n"
      deleted the PREVIOUS baseline - IdeHoldScratch drops what it was
      holding - and killed the left-hand pane of a diff tab still open on
      screen, on the strength of a command the user had just refused.  The
      hold is here instead, so the file that dies is only ever replaced by
      one an editor has actually been pointed at.

      LATE ENOUGH: nothing deletes this one until either the NEXT launched
      /ide diff or the end of the session, and both of those are on the far
      side of the user typing something.  The editor reads the left-hand pane
      while IdeLaunch is still inside its wait - up to IdeLaunchWaitMs on the
      shim - and then has however long the human takes to read a diff and type
      again.  The one real race is a user who runs /ide diff and types /exit
      inside the same second, before the editor has opened the file; the shim
      returns when the running instance has been SIGNALLED, not when it has
      read anything, so that window is small but not zero, and the failure is
      a diff tab whose left pane says the file is gone.  That is a smaller
      harm, knowingly taken, than project text sitting in %LOCALAPPDATA%
      until tomorrow.

      EARLY ENOUGH: the file no longer outlives the session at all, and a long
      session accumulates nothing, because holding this one deletes the one
      before it. }
    uIde.IdeHoldScratch(Tmp);
    if Existed then
      EmitCLn(clGrey, '  ' + Rest +
        ': before this session on the left, now on the right')
    else
      EmitCLn(clGrey, '  ' + Rest +
        ': created this session, so the left pane is empty');
  end
  else
    IdeDiscardScratch(Tmp);
end;

{ Background commands were started on the user's behalf, by a model, without
  the user necessarily reading the line that launched them.  They must be
  visible without having to ask the model what it is running. }
procedure ShowJobs;
var
  L: TStringList;
  I: Integer;
begin
  L := TStringList.Create;
  try
    L.Text := uTools.BackgroundJobList;
    for I := 0 to L.Count - 1 do
      if Trim(L[I]) <> '' then
        EmitCLn(clGrey, '  ' + L[I]);
  finally
    L.Free;
  end;
end;

{ uTools' progress channel during startup.  Connecting several servers takes
  seconds and happens before the banner, so it has to say what it is waiting
  for; an empty line is a paragraph break, which is what the approval preamble
  wants before the first prompt. }
procedure McpNotice(const Text: string);
begin
  if Text = '' then EmitLn else EmitCLn(clGrey, '  ' + Text);
end;

{ Splits one tab-separated row of uTools.McpServerList. }
function Field(const S: string; N: Integer): string;
var
  L: TStringList;
begin
  Result := '';
  L := TStringList.Create;
  try
    L.Delimiter := #9;
    L.StrictDelimiter := True;
    L.DelimitedText := S;
    if (N >= 0) and (N < L.Count) then Result := L[N];
  finally
    L.Free;
  end;
end;

{ /hooks, /hooks off.  Reports the file, whether it is running, and what the
  user actually approved, because "hooks are configured" and "hooks are on"
  are different states and only this can tell them apart. }
{ /skills, which doubles as the rescan: the catalogue is cached, so a skill
  dropped in mid-session is invisible until something invalidates it, and the
  command a user reaches for to find out whether their skill is there is the
  natural place to do it.  A skill whose SKILL.md failed to parse is listed
  with its reason and line number rather than omitted - omitted is exactly the
  state in which nobody can find out why it never triggers. }
procedure ShowSkills;
var
  C: uTools.TSkillInfoArray;
  I: Integer;
  Src: string;
begin
  uTools.RefreshSkills;
  C := uTools.SkillCatalogue;
  if Length(C) = 0 then
  begin
    EmitCLn(clGrey, '  no skills (put one in ' + SessionDir + PathDelim +
      uTools.SkillsDirName + PathDelim + '<name>' + PathDelim + 'SKILL.md)');
    Exit;
  end;
  for I := 0 to High(C) do
  begin
    case C[I].Source of
      uTools.ssProject: Src := 'project';
      uTools.ssPlugin:  Src := 'plugin ' + C[I].Plugin;
    else
      Src := 'user';
    end;
    if C[I].Err <> '' then
    begin
      EmitCLn(clYellow, Format('  %-16s %-14s %s',
        [C[I].Name, Src, C[I].Err]));
      Continue;
    end;
    EmitCLn(clBright, Format('  %-16s %s', [C[I].Name, Src]));
    EmitCLn(clGrey,   '    ' + C[I].Description);
  end;
end;

{ Where a style came from, in the one wording the listing and the confirmation
  both use: two wordings for one fact is how a user ends up unable to tell
  whether the file they are looking at is the one in force. }
function StyleSourceLabel(const S: uTools.TStyleInfo): string;
begin
  if S.Builtin then Exit('built-in');
  case S.Source of
    uTools.ssProject: Result := 'project';
    uTools.ssPlugin:  Result := 'plugin ' + S.Plugin;
  else
    Result := 'user';
  end;
end;

{ /output-style, which like /skills doubles as the rescan.  Bare, it lists;
  named, it sets, reports the resolved path and the note's size, and persists
  the name.  The size is printed rather than kept quiet because the style
  rides OUTSIDE the prompt cache: it is charged as fresh input tokens on every
  single turn, and a number the user can see is the whole of the defence
  against that being a surprise on the bill. }
procedure ShowOutputStyle(const Arg: string);
var
  C: uTools.TStyleInfoArray;
  I: Integer;
  Name, Err, Mark: string;
begin
  Name := Trim(Arg);
  if Name = '' then
  begin
    uTools.RefreshStyles;
    C := uTools.StyleCatalogue;
    for I := 0 to High(C) do
    begin
      if C[I].Err <> '' then
      begin
        EmitCLn(clYellow, Format('  %-14s %-12s %s',
          [C[I].Name, StyleSourceLabel(C[I]), C[I].Err]));
        Continue;
      end;
      if CompareText(C[I].Name, uTools.OutputStyleName) = 0 then
        Mark := ' (current)'
      else
        Mark := '';
      EmitCLn(clBright, Format('  %-14s %s%s',
        [C[I].Name, StyleSourceLabel(C[I]), Mark]));
      if C[I].Description <> '' then
        EmitCLn(clGrey, '    ' + C[I].Description);
    end;
    EmitCLn(clGrey, '  a style adds to the system prompt; it never replaces it');
    Exit;
  end;

  if not uTools.SetOutputStyle(Name, Err) then
  begin
    EmitCLn(clRed, '  ' + Err);
    EmitCLn(clGrey, '  /output-style with no argument lists what is available');
    Exit;
  end;
  if uTools.OutputStylePath <> '' then
    EmitCLn(clGrey, '  ' + uTools.OutputStylePath)
  else
    EmitCLn(clGrey, '  built-in style ' + uTools.OutputStyleName);
  if uTools.StyleNote = '' then
    EmitCLn(clGrey, '  nothing is added to the system prompt')
  else
    EmitCLn(clGrey, Format('  %d bytes added to every request',
      [Length(uTools.StyleNote)]));
  if uTools.StyleNoteTruncated then
    EmitCLn(clYellow, Format('  the body was cut to %d bytes',
      [uTools.MaxStyleNoteBytes]));
  SavePermissions(PermissionsPath);
end;

{ /plugins, /plugins enable <name>, /plugins disable <name>.  Consent here is
  a typed name and not a y/a/n prompt on purpose: a launch-time prompt is
  answered by muscle memory before anything has been read, whereas typing the
  plugin's name means the user went and looked at it. }
procedure ShowPlugins(const Arg: string);
var
  P: uTools.TPluginInfoArray;
  I, Sp: Integer;
  Verb, Name, Err, State: string;
begin
  Sp := Pos(' ', Arg);
  if Sp = 0 then
  begin
    Verb := LowerCase(Trim(Arg));
    Name := '';
  end
  else
  begin
    Verb := LowerCase(Trim(Copy(Arg, 1, Sp - 1)));
    Name := Trim(Copy(Arg, Sp + 1, MaxInt));
  end;

  if (Verb = 'enable') or (Verb = 'disable') then
  begin
    if not uTools.SetPluginEnabled(Name, Verb = 'enable', Err) then
    begin
      EmitCLn(clYellow, '  ' + Err);
      Exit;
    end;
    uTools.SavePluginState(PluginStatePath);
    uTools.RefreshSkills;
    if Verb = 'enable' then
      EmitCLn(clGreen, '  ' + Name + ' enabled: its commands, agents and ' +
        'skills are live')
    else
      EmitCLn(clGrey, '  ' + Name + ' disabled');
    Exit;
  end;
  if Verb <> '' then
  begin
    EmitCLn(clYellow, '  /plugins, /plugins enable <name>, /plugins disable <name>');
    Exit;
  end;

  P := uTools.InstalledPlugins;
  if Length(P) = 0 then
  begin
    EmitCLn(clGrey, '  no plugins (a plugin is a directory in ' + SessionDir +
      PathDelim + uTools.PluginsDirName + ')');
    Exit;
  end;
  for I := 0 to High(P) do
  begin
    if P[I].Enabled then State := 'enabled' else State := 'disabled';
    if P[I].Enabled then
      EmitCLn(clGreen, Format('  %-16s %-9s %d commands, %d agents, %d skills',
        [P[I].Name, State, P[I].Commands, P[I].Agents, P[I].Skills]))
    else
      EmitCLn(clBright, Format('  %-16s %-9s %d commands, %d agents, %d skills',
        [P[I].Name, State, P[I].Commands, P[I].Agents, P[I].Skills]));
    if P[I].Description <> '' then
      EmitCLn(clGrey, '    ' + P[I].Description);
    if P[I].Err <> '' then
      EmitCLn(clYellow, '    ' + P[I].Err);
    { Named, never obeyed.  Enabling a plugin activates its commands, agents
      and skills and nothing else; a manifest asking for a hook or a server
      is reported so the user knows what they are not getting. }
    if P[I].Ignored <> '' then
      EmitCLn(clGrey, '    ignored: ' + P[I].Ignored +
        ' - this build does not run plugin hooks or servers');
  end;
  { Marked here rather than at startup: the notice exists to be read, and
    consuming it before the user had a chance makes it a flicker. }
  uTools.MarkPluginsSeen;
  uTools.SavePluginState(PluginStatePath);
end;

procedure ShowHooks(const Arg: string);
var
  Sum: string;
begin
  if LowerCase(Trim(Arg)) = 'off' then
  begin
    { BOTH scopes, and said so.  ClearHooks empties the one table, so this was
      already true; naming it is what stops the switch being a lie by omission
      now that some of the entries came from a file the user never approved
      and might not remember writing. }
    uHooks.ClearHooks;
    EmitCLn(clGrey, '  hooks are off for this session - both your own and ' +
      'this project''s');
    Exit;
  end;
  if not uHooks.AnyHooksConfigured then
  begin
    EmitCLn(clGrey, '  no hooks (put them in ' + SessionDir + PathDelim +
      uHooks.HooksFileName + ')');
    if uHooks.UserHooksFilePath <> '' then
      EmitCLn(clGrey, '  or in ' + uHooks.UserHooksFilePath +
        ', which every project you open reads');
    Exit;
  end;

  { Both files, both states, because a panel that showed one of them would
    leave the user unable to find the hook that just fired. }
  if uHooks.UserHooksConfigured then
    EmitCLn(clGrey, '  ' + uHooks.UserHooksFilePath +
      ' (yours; loaded without asking, fires first)')
  else if uHooks.UserHooksFilePath <> '' then
    EmitCLn(clGrey, '  ' + uHooks.UserHooksFilePath + ' (none)');
  if uHooks.HooksConfigured then
    EmitCLn(clGrey, '  ' + uHooks.HooksFilePath + ' (this project''s)')
  else if not uHooks.ProjectHooksAreTheUsers then
    EmitCLn(clGrey, '  ' + uHooks.HooksFilePath + ' (none)');
  { The suppression is the same one HooksConfigured and LoadHooks apply, and it
    has to be here too.  Running IN the home directory makes the two paths one
    file: the line above has just named it as the user's own, loaded and firing
    first, and HooksConfigured is False there BY CONSTRUCTION, so an unguarded
    else printed that identical path a second time as "(none)".  A panel that
    says a file is firing and then says there is no such file is the one thing
    a diagnostic must never do, and it is worse here than elsewhere because the
    reader is looking at this panel precisely to find out where the hook that
    just ran came from. }

  if uHooks.HooksEnabled then
  begin
    if uHooks.HooksConfigured then
      EmitCLn(clGreen, '  enabled, project fingerprint ' +
        uHooks.HookFingerprint)
    else
      EmitCLn(clGreen, '  enabled');
    Sum := uHooks.HookSummary;
    if Sum <> '' then EmitC(clGrey, Sum);
  end
  else
    EmitCLn(clYellow, '  not running (not trusted this session, or /hooks off)');
end;

{ /config, and it is the entire debugging surface for this feature: SafePath
  refuses every path under .pasclaude in every root, so the model's own tools
  cannot read a settings file even when asked to explain why a value did not
  take.  That is why this prints absolute paths and raw problem text rather
  than tier words alone.

  /config                 the three files, then key / value / where from
  /config get <k>         the full provenance chain for one key
  /config set [--local] <k> <v>
  /config unset [--local] <k>
  /config reload          re-read the files and re-apply what can be re-applied

  set and unset write the USER file by default, and settings.local.json with
  --local.  They never write <root>\.pasclaude\settings.json: pasclaude
  committing configuration into somebody's repository on their behalf is not a
  convenience. }
procedure ShowConfig(const Arg: string);
var
  Rows, Notes: TStringArray;
  Cmd, Rest, Name, Value, Path, Err, Field: string;
  I, Sp: Integer;
  Local, Removing: Boolean;
  T: uSettings.TSettingTier;
  Idx: Integer;

  { One row of the report: name, value, where from, what it shadows. }
  procedure EmitRow(const R: string);
  var
    P, Q: Integer;
    N, V, Src, Shadow: string;
  begin
    P := Pos(#9, R);
    N := Copy(R, 1, P - 1);
    Q := Pos(#9, R, P + 1);
    V := Copy(R, P + 1, Q - P - 1);
    P := Q;
    Q := Pos(#9, R, P + 1);
    Src := Copy(R, P + 1, Q - P - 1);
    Shadow := Copy(R, Q + 1, Length(R));
    EmitCLn(clGrey, Format('  %-22s %-24s %s', [N, V, Src]));
    if Shadow <> '' then
      EmitCLn(clGrey, '                         overruled: ' + Shadow);
  end;

  procedure ShowFile(const Label_, P: string);
  begin
    if FileExists(P) then
      EmitCLn(clGrey, '  ' + Label_ + '  ' + P)
    else
      EmitCLn(clGrey, '  ' + Label_ + '  ' + P + '  (absent)');
  end;

begin
  Rest := Trim(Arg);
  Sp := Pos(' ', Rest);
  if Sp > 0 then
  begin
    Cmd := LowerCase(Copy(Rest, 1, Sp - 1));
    Rest := Trim(Copy(Rest, Sp + 1, Length(Rest)));
  end
  else
  begin
    Cmd := LowerCase(Rest);
    Rest := '';
  end;

  if (Cmd = 'set') or (Cmd = 'unset') then
  begin
    Removing := Cmd = 'unset';
    Local := False;
    if LowerCase(Copy(Rest, 1, 7)) = '--local' then
    begin
      Local := True;
      Rest := Trim(Copy(Rest, 8, Length(Rest)));
    end;
    Sp := Pos(' ', Rest);
    if Sp > 0 then
    begin
      Name := Copy(Rest, 1, Sp - 1);
      Value := Trim(Copy(Rest, Sp + 1, Length(Rest)));
    end
    else
    begin
      Name := Rest;
      Value := '';
    end;
    if Name = '' then
    begin
      EmitCLn(clGrey, '  /config ' + Cmd + ' [--local] <key> [value]');
      Exit;
    end;
    if (not Removing) and (Value = '') then
    begin
      EmitCLn(clRed, '  /config set needs a value (/config unset removes one)');
      Exit;
    end;
    if Local then Path := SettingsLocalPath else Path := SettingsUserPath;
    if not uSettings.SettingsWrite(Path, Name, Value, Removing, Err) then
    begin
      EmitCLn(clRed, '  ' + Err);
      Exit;
    end;
    EmitCLn(clGrey, '  wrote ' + Path);
    { Re-read rather than patched in memory, so what is in force is exactly
      what a restart would produce - the same rule /deny follows. }
    uSettings.SettingsLoad(SettingsUserPath, SettingsProjectPath,
      SettingsLocalPath, Notes);
    ApplySettings;
    for I := 0 to High(Notes) do
      EmitCLn(clYellow, '  ' + Notes[I]);
    { Said on the spot: a user who set a value and saw nothing change would
      otherwise have to read the whole table to find out why. }
    if (not Removing) and (not Local) and
       uSettings.SettingIsProjectClass(uSettings.SettingSource(Name)) then
    begin
      EmitCLn(clYellow, '  ' + Name + ' is still ' +
        uSettings.SettingStr(Name) + ' from the ' +
        uSettings.TierName(uSettings.SettingSource(Name)) + ' file');
      EmitCLn(clGrey, '  /config set --local ' + Name + ' ' + Value +
        ' beats it for this checkout');
    end;
    Exit;
  end;

  if Cmd = 'reload' then
  begin
    uSettings.SettingsLoad(SettingsUserPath, SettingsProjectPath,
      SettingsLocalPath, Notes);
    ApplySettings;
    for I := 0 to High(Notes) do
      EmitCLn(clYellow, '  settings: ' + Notes[I]);
    EmitCLn(clGrey, '  re-read; tool_result_bytes, auto_compact_tokens and ' +
      'thinking_budget now apply');
    { Honest about the half it cannot honour.  TAgent has no setter for its
      system prompt, deliberately, because changing it mid-session throws the
      prompt cache away on every turn afterwards. }
    EmitCLn(clGrey, '  output_style needs /output-style <name>; model needs ' +
      '/model; both are frozen into this session');
    Exit;
  end;

  if Cmd = 'get' then
  begin
    if Rest = '' then
    begin
      EmitCLn(clGrey, '  /config get <key>');
      Exit;
    end;
    Idx := uSettings.SettingIndex(Rest);
    if Idx < 0 then
    begin
      EmitCLn(clRed, '  no such setting: ' + Rest);
      Exit;
    end;
    if uSettings.SettingDefs[Idx].Scope = uSettings.scRefused then
    begin
      EmitCLn(clYellow, '  ' + Rest + ' is not a settings key');
      EmitCLn(clGrey, '  ' + uSettings.SettingDefs[Idx].Note);
      Exit;
    end;
    EmitCLn(clBright, '  ' + Rest);
    EmitCLn(clGrey, '  ' + uSettings.SettingDefs[Idx].Note);
    if uSettings.SettingDefs[Idx].Scope = uSettings.scUserOnly then
      EmitCLn(clGrey, '  user settings file only; a project file may not set it');
    { The whole chain, nearest first, so the answer to "why is my value not
      taking effect" is visible rather than inferred. }
    for T := High(uSettings.TSettingTier) downto uSettings.stUser do
    begin
      Field := uSettings.SettingTierValue(Rest, T);
      if T = uSettings.stRuntime then
        Field := uSettings.SettingRuntimeLabel(Rest) + ' ' + Field;
      if Trim(Field) = '' then Continue;
      if T = uSettings.SettingSource(Rest) then
        EmitCLn(clGreen, Format('  %-8s %s   <- in force',
          [uSettings.TierName(T), Trim(Field)]))
      else
        EmitCLn(clGrey, Format('  %-8s %s', [uSettings.TierName(T), Trim(Field)]));
    end;
    if not uSettings.SettingIsSet(Rest) then
      EmitCLn(clGrey, '  not set anywhere; the built-in default applies');
    Exit;
  end;

  if Cmd <> '' then
  begin
    EmitCLn(clGrey, '  /config [get <k> | set [--local] <k> <v> | ' +
      'unset [--local] <k> | reload]');
    Exit;
  end;

  EmitCLn(clBright, 'Settings');
  ShowFile('user   ', SettingsUserPath);
  ShowFile('project', SettingsProjectPath);
  ShowFile('local  ', SettingsLocalPath);
  EmitCLn(clGrey, '  nearer wins: local, then project, then user, then the ' +
    'built-in default');
  EmitCLn(clGrey, '  the project and local files may set display and economy ' +
    'keys only');
  EmitLn;
  Rows := uSettings.SettingsReport;
  if Length(Rows) = 0 then
    EmitCLn(clGrey, '  nothing set; every value is the built-in default')
  else
  begin
    EmitCLn(clGrey, Format('  %-22s %-24s %s', ['key', 'value', 'from']));
    for I := 0 to High(Rows) do EmitRow(Rows[I]);
  end;
  Notes := uSettings.SettingsRefusals;
  if Length(Notes) > 0 then
  begin
    EmitLn;
    EmitCLn(clBright, 'Refused');
    for I := 0 to High(Notes) do
      EmitCLn(clYellow, '  ' + Notes[I]);
  end;
end;

{ /deny, /deny add <rule>, /deny remove <n>.  The listing names the file each
  rule came from, because the predictable thing to do with a rule you no
  longer want is to delete its line and the user has to know which file.

  "remove" is the single widening operation in the whole feature, and it lives
  here and nowhere else: a slash command is host-side text typed by a human at
  a console.  It is unreachable from -p, from the SDK protocol, from a hook,
  from an MCP server, from a subagent, and from anything the model can emit. }
procedure ShowDeny(const Arg: string);
var
  Rules: uTools.TDenyRuleArray;
  List: TStringArray;
  I, N: Integer;
  Cmd, Rest, Err: string;
  Sp: Integer;
begin
  Sp := Pos(' ', Arg);
  if Sp > 0 then
  begin
    Cmd := LowerCase(Copy(Arg, 1, Sp - 1));
    Rest := Trim(Copy(Arg, Sp + 1, MaxInt));
  end
  else
  begin
    Cmd := LowerCase(Trim(Arg));
    Rest := '';
  end;

  if (Cmd = 'add') and (Rest <> '') then
  begin
    List := uTools.GlobalDenyList;
    SetLength(List, Length(List) + 1);
    List[High(List)] := Rest;
    if not uTools.SaveGlobalDenyList(List, Err) then
    begin
      EmitCLn(clRed, '  could not write deny.json: ' + Err);
      Exit;
    end;
    { Reloaded rather than appended in memory, so what is in force is always
      exactly what the files say - the state a restart would produce. }
    uTools.ClearDenyRules;
    uTools.LoadDenyRules(PermissionsPath, uTools.GlobalDenyPath);
    EmitCLn(clGrey, '  added: ' + Rest);
  end
  else if (Cmd = 'remove') and (Rest <> '') then
  begin
    Rules := uTools.DenyRules;
    N := StrToIntDef(Rest, 0);
    if (N < 1) or (N > Length(Rules)) then
    begin
      EmitCLn(clRed, '  not a listed number: ' + Rest);
      Exit;
    end;
    if Rules[N - 1].Source <> uTools.GlobalDenyPath then
    begin
      EmitCLn(clYellow, '  that rule is in ' + Rules[N - 1].Source);
      EmitCLn(clGrey,   '  delete its line there; this command only writes deny.json');
      Exit;
    end;
    Rest := Rules[N - 1].Text;
    List := uTools.GlobalDenyList;
    N := -1;
    for I := 0 to High(List) do
      if List[I] = Rest then N := I;
    if N < 0 then
    begin
      EmitCLn(clRed, '  that rule is no longer in deny.json');
      Exit;
    end;
    for I := N to High(List) - 1 do List[I] := List[I + 1];
    SetLength(List, Length(List) - 1);
    if not uTools.SaveGlobalDenyList(List, Err) then
    begin
      EmitCLn(clRed, '  could not write deny.json: ' + Err);
      Exit;
    end;
    uTools.ClearDenyRules;
    uTools.LoadDenyRules(PermissionsPath, uTools.GlobalDenyPath);
    EmitCLn(clGrey, '  removed: ' + Rest);
  end;

  Rules := uTools.DenyRules;
  if Length(Rules) = 0 then
  begin
    EmitCLn(clGrey, '  no deny rules (/deny add tool:bash, /deny add path:.env)');
    EmitCLn(clGrey, '  they live in ' + uTools.GlobalDenyPath);
    Exit;
  end;
  for I := 0 to High(Rules) do
  begin
    if Rules[I].Err = '' then
      EmitCLn(clGrey, Format('  %2d  %-28s %s',
        [I + 1, Rules[I].Text, Rules[I].Source]))
    else
    begin
      EmitCLn(clYellow, Format('  %2d  %-28s NOT IN FORCE: %s',
        [I + 1, Rules[I].Text, Rules[I].Err]));
      EmitCLn(clGrey,   '      ' + Rules[I].Source);
    end;
  end;
  EmitLn;
  { The three limits, printed where the user is looking at the rules they
    believe protect them.  A rule misread as wider than it is is worse than
    no rule at all. }
  EmitCLn(clGrey, '  bash: rules filter the program name of each cmd.exe segment.');
  EmitCLn(clGrey, '  They cannot follow %VAR% expansion, a for loop, a renamed copy');
  EmitCLn(clGrey, '  or a .cmd wrapper - tool:bash is the airtight form.');
  EmitCLn(clGrey, '  path: rules cover pasclaude''s file tools, not the shell: a');
  EmitCLn(clGrey, '  command run through bash never passes them. Hardlinks evade them.');
end;

{ /mcp, /mcp restart <name>, /mcp refresh.  Every configured server is shown,
  including the ones contributing nothing: a server dropped in silence reads
  as a broken program, and the point of asking the user to approve a program
  is that they can then see what became of it. }
procedure ShowMcp(const Arg: string);
var
  Rows: TStringArray;
  I: Integer;
  Status, Err, Sub, Rest: string;
  Col: TColor;
  Sp: Integer;
  HasUser: Boolean;
begin
  Sp := Pos(' ', Arg);
  if Sp > 0 then
  begin
    Sub := LowerCase(Copy(Arg, 1, Sp - 1));
    Rest := Trim(Copy(Arg, Sp + 1, MaxInt));
  end
  else
  begin
    Sub := LowerCase(Arg);
    Rest := '';
  end;

  if Sub = 'restart' then
  begin
    if uTools.McpRestart(Rest, Err) then
      EmitCLn(clGrey, '  ' + Rest + ' will reconnect on its next call')
    else
      EmitCLn(clRed, '  ' + Err);
    Exit;
  end
  else if Sub = 'refresh' then
  begin
    EmitCLn(clGrey, '  reconnecting...');
    uTools.McpRefresh(Err);
    if Err <> '' then EmitCLn(clYellow, '  ' + Err);
    { The tool list the model was told about this session is deliberately not
      replaced: the tools array renders ahead of the system prompt under one
      cache breakpoint, so swapping it mid-session throws away the whole
      prompt cache on every turn afterwards. }
    EmitCLn(clGrey, '  the refreshed tool list applies to the next run');
  end;

  Rows := uTools.McpServerList;
  if Length(Rows) = 0 then
  begin
    EmitCLn(clGrey, '  no MCP servers configured (.mcp.json in the session ' +
      'root, or mcp.json in your own .pasclaude)');
    if uTools.UserMcpConfigPath <> '' then
      EmitCLn(clGrey, '  ' + uTools.UserMcpConfigPath);
    Exit;
  end;
  HasUser := False;
  for I := 0 to High(Rows) do
  begin
    Status := Field(Rows[I], 1);
    if Field(Rows[I], 6) = 'user' then HasUser := True;
    if Status = 'connected' then Col := clGreen
    else if (Status = 'dead') or (Status = 'denied') or
            (Status = 'failed to start') then Col := clRed
    else Col := clGrey;
    EmitC(clBright, '  ' + Field(Rows[I], 0) + '  ');
    { Which file named this program, beside the name and before the status: a
      user reading /mcp to decide whether to be alarmed is asking exactly that
      question, and a server they configured themselves needs no alarm. }
    EmitC(clGrey, Field(Rows[I], 6) + '  ');
    EmitC(Col, Status);
    EmitCLn(clGrey, Format('  %s tools, %s skipped',
      [Field(Rows[I], 2), Field(Rows[I], 3)]));
    EmitCLn(clGrey, '      ' + Field(Rows[I], 4));
    if Field(Rows[I], 5) <> '' then
      EmitCLn(clGrey, '      ' + Field(Rows[I], 5));
  end;
  { Your own servers' stderr no longer lands in this project, so /mcp has to
    say where it went - otherwise the improvement reads as the log having
    vanished.  A footer and not a column, and only when you actually have a
    server of your own: the per-row note already names the exact file the
    moment one dies, which is when the path matters, and the panel is three
    lines a server before anything is added to it.  This answers the other
    question, the one nothing was answering - where a HEALTHY server's log is. }
  if HasUser and (uTools.UserMcpSpoolDir <> '') then
    EmitCLn(clGrey, '  your servers'' stderr: ' + uTools.UserMcpSpoolDir);
end;

{ /model <name>.  An alias is resolved and said out loud; anything else is
  set verbatim and unvalidated, exactly as it always was, so a model newer
  than the list this key returns is still pickable.  The alias NAME is what
  is stored, never its target: a profile has to survive /resume as a profile,
  and freezing it here would leave the model and the mode disagreeing after
  the next /mode. }
procedure SetModelByName(const Name: string);
var
  Target: string;
  Kind: TModelAliasKind;
begin
  Agent.Model := Name;
  if not ResolveModelAlias(Name, Target, Kind) then
  begin
    EmitCLn(clGrey, '  model set to ' + Name);
    Exit;
  end;
  if Kind = makProfile then
  begin
    EmitCLn(clGrey, '  model set to ' + Name + '  (a profile: ' + Target + ')');
    EmitCLn(clGrey, '  the first half applies in plan mode, the second ' +
      'everywhere else (/mode)');
    EmitCLn(clGrey, '  right now: ' + Agent.EffectiveModel(mrMain));
  end
  else
    EmitCLn(clGrey, '  alias ' + Name + ' -> ' + Target);
end;

{ A bare /model lists what the key can actually use and takes a number.
  Typing a model id from memory is guesswork about a namespace that changes
  under you - the retired-default 404 was exactly that - so the list comes
  from the API, which cannot be stale. }
procedure PickModel;
var
  Models: TModelList;
  Err, Line: string;
  I, Pick, N: Integer;
  Mark, Target: string;
  Kind: TModelAliasKind;
begin
  EmitCLn(clGrey, '  fetching the model list...');
  Models := Agent.ListModels(Err);
  if Length(Models) = 0 then
  begin
    EmitCLn(clRed, '  could not list models: ' + Err);
    EmitCLn(clGrey, '  current model: ' + Agent.Model +
      '  (/model <name> still sets one directly)');
    Exit;
  end;

  { The live rows keep numbers 1..N verbatim.  Aliases are appended below
    with continued numbering, so nothing documented moves and a number still
    picks the thing it always picked. }
  for I := 0 to High(Models) do
  begin
    if Models[I].Id = Agent.Model then Mark := ' (current)' else Mark := '';
    EmitC(clGrey, Format('  %2d  ', [I + 1]));
    EmitC(clBright, Models[I].DisplayName);
    EmitCLn(clGrey, '  ' + Models[I].Id + Mark);
  end;

  N := Length(Models);
  if ModelAliasCount > 0 then
  begin
    EmitCLn(clGrey, '  aliases');
    for I := 0 to ModelAliasCount - 1 do
    begin
      if ModelAliasName(I) = Agent.Model then Mark := ' (current)'
      else Mark := '';
      EmitC(clGrey, Format('  %2d  ', [N + I + 1]));
      EmitC(clBright, ModelAliasName(I));
      EmitCLn(clGrey, '  ' + ModelAliasTarget(I) + Mark);
      { The live list is the authority and this table is only a hint over it,
        so the table is annotated against the list rather than trusted.  A
        profile is skipped: its halves are aliases, and each is checked on
        its own row. }
      ResolveModelAlias(ModelAliasName(I), Target, Kind);
      if (Kind = makModel) and not ModelListMatches(Target, Models) then
        EmitCLn(clYellow, '      not in the list this key returned');
    end;
  end;

  EmitC(clYellow, '  pick a number, or Enter to keep ' + Agent.Model + ' > ');
  if not ReadLineEdit('', Line) then Exit;
  Line := Trim(Line);
  if Line = '' then
  begin
    EmitCLn(clGrey, '  keeping ' + Agent.Model);
    Exit;
  end;
  Pick := StrToIntDef(Line, 0);
  if (Pick >= 1) and (Pick <= N) then
  begin
    Agent.Model := Models[Pick - 1].Id;
    EmitCLn(clGrey, '  model set to ' + Agent.Model);
    Exit;
  end;
  if (Pick > N) and (Pick <= N + ModelAliasCount) then
  begin
    SetModelByName(ModelAliasName(Pick - N - 1));
    Exit;
  end;
  EmitCLn(clRed, '  not a listed number: ' + Line);
end;

procedure RecordCheckpoint(const Prompt: string);
var
  N: Integer;
  Line: string;
  P: Integer;
begin
  N := Length(CheckTurns);
  SetLength(CheckTurns, N + 1);
  SetLength(CheckCounts, N + 1);
  SetLength(CheckPrompts, N + 1);
  CheckTurns[N] := Agent.TurnCount + 1;      { the turn about to run }
  CheckCounts[N] := Agent.MessageCount;
  Line := Prompt;
  P := Pos(#10, Line);
  if P > 0 then SetLength(Line, P - 1);
  if Length(Line) > 60 then Line := Copy(Line, 1, 57) + '...';
  CheckPrompts[N] := Line;
  uTools.BeginTurn(CheckTurns[N]);
end;

{ Checkpoint message counts are positions in the transcript, so anything
  that renumbers it - compaction, /clear, a resume - makes them lies.  The
  file snapshots go too: a rewind that restored files against a transcript
  that no longer matches would be half an undo, which is worse than none. }
procedure DropCheckpoints;
begin
  SetLength(CheckTurns, 0);
  SetLength(CheckCounts, 0);
  SetLength(CheckPrompts, 0);
  uTools.ClearSnapshots;
end;

{ Every saved conversation in .pasclaude: the live one, the safety copy,
  and any named saves (/save <name> writes <name>.session.json).  Each
  shows its date and size; a number resumes it.  Resuming a named session
  does not touch the live file until the next autosave, which is the same
  rule /resume has always had. }
procedure PickSession;
var
  R: TSearchRec;
  Dir, Line, Err: string;
  Names: array of string;
  Sizes: array of Int64;
  Stamps: array of TDateTime;
  N, I, Pick: Integer;

  procedure Add(const FileName: string; Size: Int64; Stamp: TDateTime);
  begin
    SetLength(Names, N + 1);
    SetLength(Sizes, N + 1);
    SetLength(Stamps, N + 1);
    Names[N] := FileName;
    Sizes[N] := Size;
    Stamps[N] := Stamp;
    Inc(N);
  end;

begin
  Dir := IncludeTrailingPathDelimiter(uTools.RootDir) + SessionDir + PathDelim;
  Names := nil;
  N := 0;
  if FindFirst(Dir + '*.json', faAnyFile, R) = 0 then
  begin
    repeat
      { Sessions only: the permissions file also lives here.  uAgent owns the
        rule now, because --continue asks the same question and the two must
        never disagree about what a transcript is. }
      if uAgent.IsSessionFile(R.Name) then
        Add(R.Name, R.Size, FileDateToDateTime(R.Time));
    until FindNext(R) <> 0;
    SysUtils.FindClose(R);
  end;
  if N = 0 then
  begin
    EmitCLn(clGrey, '  no saved sessions in ' + SessionDir);
    Exit;
  end;

  EmitCLn(clBright, '  saved sessions:');
  for I := 0 to N - 1 do
    EmitCLn(clGrey, Format('  %2d  %-32s %s  %d KB', [I + 1, Names[I],
      FormatDateTime('yyyy-mm-dd hh:nn', Stamps[I]),
      (Sizes[I] + 1023) div 1024]));
  EmitC(clYellow, '  pick a number to resume, or Enter to cancel > ');
  if not ReadLineEdit('', Line) then Exit;
  Line := Trim(Line);
  if Line = '' then
  begin
    EmitCLn(clGrey, '  cancelled');
    Exit;
  end;
  Pick := StrToIntDef(Line, 0);
  if (Pick < 1) or (Pick > N) then
  begin
    EmitCLn(clRed, '  not a listed number: ' + Line);
    Exit;
  end;
  if Agent.LoadSession(Dir + Names[Pick - 1], Err) then
  begin
    DropCheckpoints;
    TelemRebaseline;
    EmitCLn(clGrey, Format('  resumed %s: %d messages (%d turns)',
      [Names[Pick - 1], Agent.MessageCount, Agent.TurnCount]));
  end
  else
    EmitCLn(clRed, '  could not resume: ' + Err);
end;

{ /rewind: list the turns, pick one, and both the conversation and the
  files return to the moment before it ran.  The files come back from the
  snapshots the write and edit tools took; the conversation is truncated to
  its recorded length.  What cannot come back is deliberately named: shell
  commands are not undoable, and a file too large to snapshot stays as it
  is. }
procedure DoRewind;
var
  I, Pick, Restored: Integer;
  Line, Notes, Err: string;
begin
  if Length(CheckTurns) = 0 then
  begin
    EmitCLn(clGrey, '  nothing to rewind to yet');
    Exit;
  end;
  EmitCLn(clBright, '  rewind to the moment before:');
  for I := 0 to High(CheckTurns) do
    EmitCLn(clGrey, Format('  %2d  %s', [I + 1, CheckPrompts[I]]));
  EmitC(clYellow, '  pick a number, or Enter to cancel > ');
  if not ReadLineEdit('', Line) then Exit;
  Line := Trim(Line);
  if Line = '' then
  begin
    EmitCLn(clGrey, '  cancelled');
    Exit;
  end;
  Pick := StrToIntDef(Line, 0);
  if (Pick < 1) or (Pick > Length(CheckTurns)) then
  begin
    EmitCLn(clRed, '  not a listed number: ' + Line);
    Exit;
  end;

  Agent.TruncateMessages(CheckCounts[Pick - 1]);
  Restored := uTools.RestoreFilesSince(CheckTurns[Pick - 1], Notes);
  if Notes <> '' then
    EmitC(clGrey, '  ' + StringReplace(Trim(Notes), #10, #10'  ',
      [rfReplaceAll]) + #10);
  EmitCLn(clGrey, Format('  rewound: %d messages in the transcript, %d files restored',
    [Agent.MessageCount, Restored]));
  { The number comes from the constant, not from a typed '400 KB'.  /ide diff
    quotes the same cap when it explains a missing baseline, and two copies of
    a number in prose is exactly the pair that drifts apart the day the
    constant moves. }
  EmitCLn(clYellow, '  shell commands are not undone, and files over ' +
    IntToStr(uTools.SnapshotLimitBytes div 1024) +
    ' KB were not snapshotted');

  { The checkpoints past the target are gone with the turns they marked. }
  SetLength(CheckTurns, Pick - 1);
  SetLength(CheckCounts, Pick - 1);
  SetLength(CheckPrompts, Pick - 1);

  { The saved session must match, or a crash right now resurrects what was
    just rewound. }
  if not Agent.SaveSession(SessionPath(uTools.RootDir), Err) then
    EmitCLn(clYellow, '  (the rewound session could not be saved: ' + Err + ')');
end;

{ ------------------------------------------------------------- clipboard -- }

{ Windows hands over an image as CF_DIB - raw pixels - and the API takes png,
  jpeg, gif and webp but not BMP, so something has to encode.  uImage does the
  encoding; this function only acquires bytes, which is what keeps the DIB
  parsing testable without a clipboard.

  Three sources, best first: a copied FILE keeps its own bytes and its own
  compression; the registered "PNG" format, which browsers and capture tools
  commonly set, is already what we want; and CF_DIB is the fallback that
  always exists, because Windows synthesises it from CF_BITMAP whenever any
  image is on the clipboard. }
function ClipboardImage(out Bytes: RawByteString; out Media: string;
  out Note, Err: string): Boolean;
var
  Tries, N: Integer;
  H: THandle;
  P: Pointer;
  Dib, Rgb, Png: RawByteString;
  W, Ht, OW, OH, NW, NH: Integer;
  PngFmt: UINT;
  Drop: PByte;
  WideName: PWideChar;
  Name, Full: string;
  F: TFileStream;
  SW, SH: Integer;

  { The bytes of a clipboard handle, copied out under a lock. }
  function Grab(Fmt: UINT; out Data: RawByteString): Boolean;
  var
    Hh: THandle;
    Pp: Pointer;
    Sz: PtrUInt;
  begin
    Data := '';
    Result := False;
    if not IsClipboardFormatAvailable(Fmt) then Exit;
    Hh := GetClipboardData(Fmt);
    if Hh = 0 then Exit;
    Sz := GlobalSize(Hh);
    if (Sz = 0) or (Sz > 64 * 1024 * 1024) then Exit;
    Pp := GlobalLock(Hh);
    if Pp = nil then Exit;
    try
      SetLength(Data, Sz);
      Move(Pp^, Data[1], Sz);
    finally
      GlobalUnlock(Hh);
    end;
    Result := True;
  end;

begin
  Bytes := '';
  Media := '';
  Note := '';
  Err := '';
  Result := False;

  { Another process can hold the clipboard open for a moment; failing on the
    first try would make /paste flaky for no reason. }
  Tries := 0;
  while not OpenClipboard(0) do
  begin
    Inc(Tries);
    if Tries >= 8 then
    begin
      Err := 'the clipboard is in use by another program';
      Exit;
    end;
    Sleep(30);
  end;
  try
    { 1. A copied file: read its own bytes, which are already compressed
      properly and must not be re-encoded. }
    if IsClipboardFormatAvailable(CF_HDROP) then
    begin
      H := GetClipboardData(CF_HDROP);
      if H <> 0 then
      begin
        P := GlobalLock(H);
        if P <> nil then
          try
            { DROPFILES: a DWORD offset to the names, a POINT, and two BOOLs;
              the names follow as a double-null-terminated list. }
            Drop := PByte(P);
            if PBoolean(Drop + 16)^ then   { fWide }
            begin
              WideName := PWideChar(Drop + PDWORD(Drop)^);
              Name := UTF8Encode(WideString(WideName));
            end
            else
              Name := string(PAnsiChar(Drop + PDWORD(Drop)^));
          finally
            GlobalUnlock(H);
          end;
        { A copied file is a path argument like any other, and this is the one
          route by which a file's bytes reach the model without a tool call.
          ResolveInRoot is SafePath, which @-mentions, read_file and the SDK's
          @import all go through, so /paste goes through it too: the session
          root, the .pasclaude refusal and the deny rules mean the same thing
          however the path arrived.  Refusing here costs a user with a
          screenshot on the Desktop nothing - Ctrl+C on the IMAGE still works,
          and so does --add-dir. }
        if (Name <> '') and not uTools.ResolveInRoot(Name, Full, Err) then
        begin
          Exit;
        end;
        if (Full <> '') and FileExists(Full) then
        begin
          try
            F := TFileStream.Create(Full, fmOpenRead or fmShareDenyNone);
            try
              N := F.Size;
              if N > MaxImageFileBytes then
              begin
                Err := Format('%s is %d bytes, over the %d limit',
                  [ExtractFileName(Name), N, MaxImageFileBytes]);
                Exit;
              end;
              SetLength(Bytes, N);
              if N > 0 then F.ReadBuffer(Bytes[1], N);
            finally
              F.Free;
            end;
          except
            on E: Exception do
            begin
              Err := E.Message;
              Bytes := '';
              Exit;
            end;
          end;
          if uImage.SniffImage(Bytes, Media, SW, SH) then
          begin
            Note := ExtractFileName(Name);
            Exit(True);
          end;
          Bytes := '';
          Media := '';
          Err := ExtractFileName(Name) + ' is not an image the API accepts';
          Exit;
        end;
      end;
    end;

    { 2. An already-encoded PNG, when the source app offered one. }
    PngFmt := RegisterClipboardFormatW('PNG');
    if (PngFmt <> 0) and Grab(PngFmt, Bytes) then
      if uImage.SniffImage(Bytes, Media, SW, SH) and (Media = 'image/png') and
         (Length(Bytes) <= MaxImageFileBytes) then
        Exit(True)
      else
      begin
        Bytes := '';
        Media := '';
      end;

    { 3. Raw pixels.  This is the path that needs an encoder. }
    if not Grab(CF_DIB, Dib) then
    begin
      Err := 'there is no image on the clipboard';
      Exit;
    end;
  finally
    CloseClipboard;
  end;

  if not uImage.DibToRgb(Dib, Rgb, W, Ht, Err) then Exit;

  { The model's own maximum is 2576 on the long edge; beyond it the API
    downscales anyway, so uploading more pixels buys nothing and costs
    upload time and, with stored deflate, a great many bytes. }
  NW := W;
  NH := Ht;
  if (W > PasteMaxEdge) or (Ht > PasteMaxEdge) then
  begin
    if W >= Ht then
    begin
      NW := PasteMaxEdge;
      NH := (Ht * PasteMaxEdge) div W;
    end
    else
    begin
      NH := PasteMaxEdge;
      NW := (W * PasteMaxEdge) div Ht;
    end;
    if NW < 1 then NW := 1;
    if NH < 1 then NH := 1;
    Rgb := uImage.Downscale(Rgb, W, Ht, NW, NH);
    if Rgb = '' then
    begin
      Err := 'the clipboard image could not be resized';
      Exit;
    end;
  end;

  if not uImage.EncodePngAuto(Rgb, NW, NH, MaxPasteBytes, Png, OW, OH) then
  begin
    { Two halvings and it still does not fit.  A quarter-scale screenshot is
      readable and a sixteenth is not, so this is an honest refusal rather
      than an image the user cannot check. }
    Err := Format('the clipboard image is %dx%d and will not fit in %d KB ' +
      'even reduced; save it as a PNG or JPEG and use @path',
      [W, Ht, MaxPasteBytes div 1024]);
    Exit;
  end;
  Bytes := Png;
  Media := 'image/png';
  if (OW <> W) or (OH <> Ht) then
    Note := Format('%dx%d downscaled to %dx%d to fit', [W, Ht, OW, OH]);
  Result := True;
end;

{ /paste, and /paste drop to change your mind.  The terminal cannot show an
  image, so the note is the whole of the feedback: what it is, how big, and
  what it will cost.  Base64 never reaches the console. }
procedure DoPaste(const Arg: string);
var
  Bytes: RawByteString;
  Media, Note, Err: string;
  W, H, Tokens: Integer;
begin
  if SameText(Trim(Arg), 'drop') then
  begin
    if Agent.PendingImages = 0 then
      EmitCLn(clGrey, '  nothing attached')
    else
    begin
      EmitCLn(clGrey, Format('  dropped %d attached image(s)',
        [Agent.PendingImages]));
      Agent.ClearPendingImages;
    end;
    Exit;
  end;

  if not ClipboardImage(Bytes, Media, Note, Err) then
  begin
    EmitCLn(clYellow, '  ' + Err);
    Exit;
  end;
  if not uImage.SniffImage(Bytes, Media, W, H) then
  begin
    EmitCLn(clYellow, '  the clipboard image could not be identified');
    Exit;
  end;
  if (W > uImage.MaxImageDim) or (H > uImage.MaxImageDim) then
  begin
    EmitCLn(clYellow, Format('  %dx%d is over the %d px limit',
      [W, H, uImage.MaxImageDim]));
    Exit;
  end;
  if not Agent.AttachImage(Media, uImage.Base64Encode(Bytes), W, H, Err) then
  begin
    EmitCLn(clYellow, '  ' + Err);
    Exit;
  end;
  Tokens := uImage.VisualTokens(W, H);
  if (W > 0) and (H > 0) then
    EmitCLn(clGrey, Format(
      '  /paste: image attached (%dx%d %s, %d KB, ~%d tokens)',
      [W, H, Media, (Length(Bytes) + 1023) div 1024, Tokens]))
  else
    EmitCLn(clGrey, Format('  /paste: image attached (%s, %d KB)',
      [Media, (Length(Bytes) + 1023) div 1024]));
  if Note <> '' then
    EmitCLn(clGrey, '  /paste: ' + Note);
  EmitCLn(clGrey, '  it goes with your next message; /paste drop cancels it');
end;

{ The banner.

  Two columns in a rounded frame: who is answering and where on the left,
  what to type on the right.  The split is not decoration - the left column
  is the session's identity, which a user checks, and the right is the set of
  commands, which a user learns once and then stops reading.  Putting them
  side by side means the half that stops being useful never pushes the half
  that stays useful off the screen.

  What the frame does NOT hold is the warnings.  A permission mode, a deny
  set and a lowered sandbox are things the user must notice, and a box is
  exactly the shape the eye learns to skip; they go underneath, unboxed, in
  the colour that means "read this". }

{ The three rows of logo.png's </> mark. }
function LogoRow(N: Integer): string;
begin
  case N of
    0: Result := MkAmber + ' ▛▀▀▜ ' + MkAmberLt + ' ▟█▙ ' + MkAmber + ' ▞▀▞ ';
    1: Result := MkAmber + ' ▌  ▐ ' + MkAmberLt + ' █  █ ' + MkAmber + ' ▌  ▐ ';
    2: Result := MkAmber + ' ▙▄▄▟ ' + MkAmberLt + ' ▝██▛ ' + MkAmber + ' ▙▄▄▟ ';
  end;
end;

{ The name to greet, or '' when the machine will not say.  A greeting with a
  blank in it is worse than no greeting. }
function WelcomeName: string;
begin
  Result := Trim(GetEnvironmentVariable('USERNAME'));
  if Result = '' then Result := Trim(GetEnvironmentVariable('USER'));
end;

{ The model, with whatever qualification it needs to be read correctly. }
function BannerModel: string;
var
  AliasTarget: string;
  AliasKind: TModelAliasKind;
begin
  Result := Agent.Model;
  { A profile is not an id, so the banner has to say what it means or the
    user is reading a word where they expect a model.  An ordinary alias is
    left alone: it resolves to one thing and /model already said so. }
  if ResolveModelAlias(Agent.Model, AliasTarget, AliasKind) and
     (AliasKind = makProfile) then
    Result := Result + ' (' + AliasTarget + ' - first in plan mode)';
  if BannerAuth <> '' then Result := Result + ' (' + BannerAuth + ')';
end;

{ The routing note, '' when nothing was routed anywhere surprising.  Routing
  costs the user quality on work they cannot see - the parent only ever reads
  a subagent's final message - so a session that routes says so once, up
  front, rather than leaving it to be discovered in /cost. }
function BannerRoutes: string;
begin
  Result := '';
  if (ModelRoute(mrSubagent) <> 'sonnet') or
     (ModelRoute(mrCompact) <> 'sonnet') then
    Result := Format('routes: subagent %s, compaction %s',
      [Agent.EffectiveModel(mrSubagent), Agent.EffectiveModel(mrCompact)])
  else if Agent.EffectiveModel(mrSubagent) <> Agent.EffectiveModel(mrMain) then
    Result := 'subagents and compaction on ' + Agent.EffectiveModel(mrSubagent);
end;

{ The lines that go under the frame: everything a user would be unpleasantly
  surprised to discover later. }
procedure ShowBannerWarnings;
begin
  { The mode, whenever it is not the plain one - including the case that has
    existed all along and was invisible, a previous session's "always" loading
    as accept-edits before anything has been typed. }
  if uTools.PermModeBanner <> '' then
    UiPaintLn(MkYellow + '  ! ' + uTools.PermModeBanner);
  if uTools.DenyRulesInForce then
    UiPaintLn(MkGrey + Format('  %d deny rules in force (/deny)',
      [uTools.DenyRuleCount]));
  { Only when it is not the default, and in both directions: "off" is as much
    a thing a user should not be surprised by as "low" is. }
  if uSandbox.SandboxLevel <> uSandbox.slLimits then
    UiPaintLn(MkYellow + '  ! sandbox: ' +
      uSandbox.SandboxLevelName(uSandbox.SandboxLevel) + ' (/sandbox)');
end;

{ The one-column banner, for a window too narrow to split.  Same facts, same
  colours, no frame: a two-column layout in forty columns is two columns of
  ellipses. }
procedure ShowBannerNarrow;
var
  I: Integer;
  Who: string;
begin
  EmitLn;
  UiPaint('  ' + LogoRow(1) + '  ');
  UiPaintLn(MkAmberLt + 'pasclaude ' + MkAmberDim + 'v' + Version);
  Who := WelcomeName;
  if Who <> '' then UiPaintLn(MkBright + '  Welcome back, ' + Who + '!');
  UiPaintLn(MkGrey + '  ' + BannerModel);
  if BannerRoutes <> '' then UiPaintLn(MkGrey + '  ' + BannerRoutes);
  UiPaintLn(MkGrey + '  ' + uTools.RootDir);
  for I := 1 to uTools.RootCount - 1 do
    UiPaintLn(MkGrey + '  + ' + uTools.RootAt(I));
  ShowBannerWarnings;
  UiPaintLn(MkGrey + '  /help for commands, /exit to quit, Esc stops a reply');
  EmitLn;
end;

{ ------------------------------------------------------- the status block --

  What sits under the prompt.  Refreshed once per turn, never per keystroke:
  everything here is either free to read or read from a small file, but a
  status line that cost a syscall per character typed would be a status line
  that made the editor feel broken. }

{ The branch, read out of .git rather than out of git.  A subprocess per turn
  would be affordable and a subprocess per keystroke would not, and the file
  is the same answer for none of the cost.  '' when this is not a repository,
  which is a normal thing for a directory to be.

  Handles the three shapes .git comes in: a directory, a worktree's file
  pointing elsewhere, and a detached HEAD, which has no branch to name and
  is reported as the short commit instead. }
function GitBranch: string;
const
  RefPrefix = 'ref: refs/heads/';
var
  Dir, DotGit, Head: string;
  L: TStringList;
  Depth: Integer;
begin
  Result := '';
  Dir := IncludeTrailingPathDelimiter(uTools.RootDir);
  DotGit := '';
  { Up to the drive root, but bounded: a path long enough to loop here would
    be a symlink cycle, and a banner is not worth hanging the session for. }
  for Depth := 0 to 40 do
  begin
    if DirectoryExists(Dir + '.git') then
    begin
      DotGit := Dir + '.git';
      Break;
    end;
    if FileExists(Dir + '.git') then
    begin
      { A worktree or submodule: the file says "gitdir: <path>". }
      L := TStringList.Create;
      try
        try
          L.LoadFromFile(Dir + '.git');
          if (L.Count > 0) and (Copy(Trim(L[0]), 1, 8) = 'gitdir: ') then
            DotGit := Trim(Copy(Trim(L[0]), 9, MaxInt));
        except
        end;
      finally
        L.Free;
      end;
      Break;
    end;
    if ExtractFileDir(ExcludeTrailingPathDelimiter(Dir)) =
       ExcludeTrailingPathDelimiter(Dir) then Break;
    Dir := IncludeTrailingPathDelimiter(
      ExtractFileDir(ExcludeTrailingPathDelimiter(Dir)));
    if Dir = PathDelim then Break;
  end;
  if DotGit = '' then Exit;

  Head := IncludeTrailingPathDelimiter(DotGit) + 'HEAD';
  if not FileExists(Head) then Exit;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(Head);
      if L.Count = 0 then Exit;
      Head := Trim(L[0]);
      if Copy(Head, 1, Length(RefPrefix)) = RefPrefix then
        Result := Copy(Head, Length(RefPrefix) + 1, MaxInt)
      else if Length(Head) >= 7 then
        Result := Copy(Head, 1, 7);       { detached: the commit is the answer }
    except
      { An unreadable HEAD means no branch shown, not a failed prompt. }
    end;
  finally
    L.Free;
  end;
end;

{ How many memory files were actually loaded.  The same names SdkProjectContext
  reads, asked the same way, so the count cannot claim a file the model did
  not get.  Which is why the project loop is behind the same gate the loader
  is: under --no-project-context the three files are still on disk and still
  found by FileExists, and a status line saying "2 memories" about text no
  request ever carried is precisely the claim the sentence above forbids.
  The byte is re-read here rather than passed in, for the reason uSdk gives at
  SdkProjectContext's own open: clearing it has to turn the feature off in
  every reader at once, including whichever one is added next.
  The %USERPROFILE% line stays OUTSIDE the gate, matching SdkUserContext
  sitting above it in the loader - the gate asks which tree wrote the prompt,
  and the user's own memory is not in the tree. }
function MemoryFileCount: Integer;
const
  Names: array[0..2] of string = ('AGENTS.md', 'CLAUDE.md', '.pasclaude.md');
var
  I: Integer;
begin
  Result := 0;
  if FileExists(IncludeTrailingPathDelimiter(GetEnvironmentVariable('USERPROFILE')) +
     '.pasclaude' + PathDelim + 'CLAUDE.md') then Inc(Result);
  if uSdk.SdkProjectContextAllowed then
    for I := 0 to High(Names) do
      if FileExists(IncludeTrailingPathDelimiter(uTools.RootDir) + Names[I]) then
        Inc(Result);
end;

{ The tail of the --no-project-context notice, present only when there is a
  user memory for it to be true about.  A separate function and not an inline
  conditional because the notice is built inside the main block, where a local
  string would be a fourteenth reused variable, and because the rule it carries
  is the same one MemoryFileCount above states at length: a line that names a
  file the model did not get is worse than no line.  It asks the LOADER rather
  than the disk - SdkUserContext returns '' both for a missing file and for one
  it could not read, and in neither case did any request carry the text. }
function UserMemoryClause: string;
begin
  if uSdk.SdkUserContext <> '' then
    Result := '; your %USERPROFILE% memory still was'
  else
    Result := '';
end;

procedure RefreshStatus;
var
  S: TStatusInfo;
begin
  StatusClear(S);
  S.Model := Agent.EffectiveModel(mrMain);
  S.Dir := ExtractFileName(ExcludeTrailingPathDelimiter(uTools.RootDir));
  if S.Dir = '' then S.Dir := uTools.RootDir;
  S.Branch := GitBranch;
  { Measured against the point this program compacts at, not against the
    model's context window.  Compaction is what the user will actually
    experience, so it is the number the meter should be filling towards. }
  S.CtxTokens := Agent.ContextTokens;
  S.CtxLimit := CompactTokens;
  S.TokensIn := Agent.TokensIn + Agent.CacheReadTokens + Agent.CacheWriteTokens;
  S.TokensOut := Agent.TokensOut;
  S.Memories := MemoryFileCount;
  S.Mcps := uTools.McpServerCount;
  S.Hooks := uHooks.HookEntryCount;
  { The indicator rather than the name: the '+' that says "standing grants
    exist" belongs here more than anywhere, because this is the line that is
    on screen when the user decides what to type.

    Plain ask says nothing, which is the same rule ModePrompt has always
    followed - and the same reason.  'ask' on every line of every session is
    a word the eye stops seeing, and then the one session where it says
    something else is the one where it goes unread. }
  S.Mode := uTools.PermModeIndicator;
  if S.Mode = 'ask' then S.Mode := '';
  S.ModeHot := uTools.CurrentPermMode in [uTools.pmodeBypass,
                                          uTools.pmodeAcceptEdits];
  SetStatus(S);
end;

procedure ShowBanner;
var
  Width, LeftW, RightW, Rows, I: Integer;
  Left, Right: array of string;
  Who: string;

  procedure AddL(const S: string);
  begin
    SetLength(Left, Length(Left) + 1);
    Left[High(Left)] := S;
  end;

  procedure AddR(const S: string);
  begin
    SetLength(Right, Length(Right) + 1);
    Right[High(Right)] := S;
  end;

  function AtL(N: Integer): string;
  begin
    if N <= High(Left) then Result := Left[N] else Result := '';
  end;

  function AtR(N: Integer): string;
  begin
    if N <= High(Right) then Result := Right[N] else Result := '';
  end;

begin
  { Capped as well as fitted: a maximised terminal is 200 columns wide and a
    banner that used all of them would be a banner nobody can read across. }
  Width := TermWidth - 1;
  if Width > 92 then Width := 92;
  if Width < 64 then
  begin
    ShowBannerNarrow;
    Exit;
  end;
  { The left column carries centred text and the right carries a list, so
    the split is not even: a list reads badly when it wraps and centred text
    reads fine when it is tight. }
  LeftW := (UiBoxInner(Width, 2) * 42) div 100;
  RightW := UiBoxInner(Width, 2) - LeftW;

  Left := nil;
  Right := nil;

  Who := WelcomeName;
  AddL('');
  if Who <> '' then
    AddL(UiCentre(MkBright + 'Welcome back, ' + Who + '!', LeftW))
  else
    AddL(UiCentre(MkBright + 'Welcome to pasclaude', LeftW));
  AddL('');
  for I := 0 to 2 do AddL(UiCentre(LogoRow(I), LeftW));
  AddL('');
  AddL(UiCentre(MkGrey + BannerModel, LeftW));
  if BannerRoutes <> '' then AddL(UiCentre(MkGrey + BannerRoutes, LeftW));
  AddL(UiCentre(MkGrey + uTools.RootDir, LeftW));
  for I := 1 to uTools.RootCount - 1 do
    AddL(UiCentre(MkGrey + '+ ' + uTools.RootAt(I), LeftW));

  AddR(MkAmber + 'Tips for getting started');
  AddR(MkWhite + 'Run /init to write a CLAUDE.md for this project');
  AddR(MkWhite + 'Type @path to attach a file, # to remember a note');
  AddR(MkWhite + 'Esc stops a reply, Ctrl+Enter is a newline');
  AddR(MkAmberDim + UiRule(RightW));
  AddR(MkAmber + 'Getting around');
  AddR(MkWhite + '/help  ' + MkGrey + ' every command there is');
  AddR(MkWhite + '/mode  ' + MkGrey + ' what gets asked before it happens');
  AddR(MkWhite + '/cost  ' + MkGrey + ' what this session has spent');
  AddR(MkWhite + '/exit  ' + MkGrey + ' quit');

  EmitLn;
  UiPaintLn(UiBoxTop(MkAmberLt + 'pasclaude ' + MkAmberDim + 'v' + Version,
    Width));
  Rows := Length(Left);
  if Length(Right) > Rows then Rows := Length(Right);
  for I := 0 to Rows - 1 do
    UiPaintLn(UiBoxRow([AtL(I), AtR(I)], [LeftW, RightW]));
  UiPaintLn(UiBoxBottom(Width));
  EmitLn;
  ShowBannerWarnings;
  EmitLn;
end;

{ Returns False when the command asked to quit. }
{ /keys.  The effective table, which is the built-in defaults with whatever
  keys.json changed, plus where the file is and whether it was there.  Sorted
  by nothing in particular: the profile's own order is the order the user
  wrote, which is more useful than alphabetical. }
procedure ShowKeys;
var
  P: TKeyProfile;
  I: Integer;
begin
  P := PromptProfile;
  EmitCLn(clBright, 'Keys');
  EmitCLn(clGrey, '  ' + KeysPath +
    Choice(KeysFileFound, '', '  (not present; built-in bindings)'));
  EmitCLn(clGrey, '  vim mode ' + Choice(P.Vim, 'on', 'off'));
  EmitLn;
  for I := 0 to High(P.Binds) do
    EmitCLn(clGrey, Format('  %-12s %s',
      [KeyChordName(P.Binds[I].Chord), KeyActionName(P.Binds[I].Action)]));
  if Length(P.Binds) = 0 then
    EmitCLn(clGrey, '  no bindings');
  EmitLn;
  EmitCLn(clGrey, '  Bindings apply to this prompt only - not to the');
  EmitCLn(clGrey, '  permission question, and not to the /model, /sessions or');
  EmitCLn(clGrey, '  /rewind pickers.  Every chord must carry ctrl or alt, or');
  EmitCLn(clGrey, '  be a named key, so a plain letter cannot be rebound at');
  EmitCLn(clGrey, '  all; enter, tab, escape and ctrl+c are reserved.');
  EmitCLn(clGrey, '  Escape clears the line; pressed twice on a line that was');
  EmitCLn(clGrey, '  already empty it opens /rewind.  With vim on it leaves');
  EmitCLn(clGrey, '  insert mode and does nothing else, both times.');
  EmitCLn(clGrey, '  {"vim":true,"bindings":{"ctrl+w":"delete-word-left"}}');
end;

{ /telemetry.  Three things: the state, the payload, and a forced send.

  preview exists because "off by default" is only half the promise; the other
  half is that a user can READ what would leave the machine before trusting
  it.  It prints uTelem.TelemBuildPayload, which is the same function the
  sender calls - not a description of it - so the two cannot drift apart. }
procedure ShowTelemetry(const Arg: string);
var
  S: TTelemState;
  A, Status: string;
  Code: Integer;
  L: TStringList;
  I: Integer;
begin
  S := uTelem.TelemState;
  A := LowerCase(Trim(Arg));
  if (A <> '') and (A <> 'preview') and (A <> 'send') then
  begin
    EmitCLn(clGrey, '  /telemetry [preview|send]');
    Exit;
  end;

  if A = '' then
  begin
    EmitCLn(clBright, 'Telemetry');
    if S.Enabled then
    begin
      EmitCLn(clGrey, '  on, OTLP/HTTP with JSON encoding');
      EmitCLn(clGrey, '  ' + S.Endpoint);
      EmitCLn(clGrey, Format('  every %d turns, %d ms timeout (%d buffered)',
        [S.IntervalTurns, S.TimeoutMs, S.TurnsBuffered]));
      if S.LastStatus <> 0 then
        EmitCLn(clGrey, '  last send: HTTP ' + IntToStr(S.LastStatus));
      if S.LastError <> '' then
        EmitCLn(clYellow, '  last error: ' + S.LastError);
      if S.ConsecFailures > 0 then
        EmitCLn(clYellow, Format('  %d consecutive failures', [S.ConsecFailures]));
    end
    else if S.SelfDisabled then
      EmitCLn(clYellow, '  stopped for this session after repeated failures')
    else
      EmitCLn(clGrey, '  off');
    EmitLn;
    EmitCLn(clGrey, '  counters only: turns, tokens by kind and model, tool');
    EmitCLn(clGrey, '  calls by built-in name and ok/error, API requests by');
    EmitCLn(clGrey, '  HTTP status, and total request milliseconds.  No prompt');
    EmitCLn(clGrey, '  or reply text, no tool arguments or output, no paths,');
    EmitCLn(clGrey, '  no project or host name, no credential of any kind.');
    EmitCLn(clGrey, '  /telemetry preview shows the exact JSON.');
    EmitLn;
    EmitCLn(clGrey, '  Turned on only by telemetry.enabled and');
    EmitCLn(clGrey, '  telemetry.endpoint in %USERPROFILE%\.pasclaude\' +
      uSettings.SettingsFileName + ';');
    EmitCLn(clGrey, '  a project file may not set either (/config), and no');
    EmitCLn(clGrey, '  environment variable is consulted.');
    if S.Enabled then
    begin
      EmitLn;
      EmitCLn(clGrey, Format('  A flush is synchronous: at worst %d ms of ' +
        'quiet before', [S.TimeoutMs]));
      EmitCLn(clGrey, Format('  the next prompt, at most once every %d turns.',
        [S.IntervalTurns]));
    end;
    Exit;
  end;

  if A = 'preview' then
  begin
    EmitCLn(clBright, 'Would send to ' +
      Choice(S.Endpoint <> '', S.Endpoint, '(no endpoint)'));
    L := TStringList.Create;
    try
      L.Text := uTelem.TelemHeaderBlockRedacted;
      for I := 0 to L.Count - 1 do EmitCLn(clGrey, '  ' + L[I]);
      EmitLn;
      { Values are redacted to a length above: a collector token is a secret
        the user wrote down, and this is exactly the output that ends up in a
        screenshot. }
      L.Text := uTelem.TelemBuildPayload(True);
      for I := 0 to L.Count - 1 do EmitCLn(clGrey, L[I]);
    finally
      L.Free;
    end;
    if not S.HasData then
      EmitCLn(clGrey, '  (nothing recorded yet this interval)');
    Exit;
  end;

  if not uTelem.TelemEnabled then
  begin
    EmitCLn(clGrey, '  telemetry is off; nothing was sent');
    Exit;
  end;
  if uTelem.TelemFlush(Code, Status) then
    EmitCLn(clGrey, '  sent; HTTP ' + IntToStr(Code))
  else
    EmitCLn(clYellow, '  not sent: ' + Status);
end;

{ ------------------------------------------------------------ credential -- }

{ Re-resolves and installs whatever uAuth now says should answer.  Called
  after /login and /logout so a change takes effect on the next turn instead
  of the next run, and wired to Agent.OnAuthRefresh so a token another
  program refreshed on disk is picked up after a 401.  Re-reading another
  program's file is not writing it: the hard boundary is untouched. }
function ReResolveAuth: Boolean;
begin
  Result := uAuth.AuthResolve(ActiveAuth);
  NoCredential := not Result;
  if Result then
    Agent.ApiKey := ActiveAuth.Token
  else
    Agent.ApiKey := '';
end;

{ The 401 hook.  Returns '' when nothing better exists, which uAgent reads as
  "do not retry" rather than as an error. }
function AuthRefreshHook: string;
begin
  Result := '';
  if uAuth.AuthResolve(ActiveAuth) then
  begin
    Result := ActiveAuth.Token;
    NoCredential := False;
  end;
end;

{ One row per source, in the order they are consulted, so the listing itself
  explains why a pasted key is being ignored in favour of an exported
  variable.  Six sources is a lot of surface for one question, and a listing
  that does not make the order legible would have made auth harder to reason
  about rather than easier.

  It prints the hint and never the value.  A listing that showed the token to
  help the user identify it would be putting a secret on the screen, in the
  scrollback, and in any terminal recording of the session. }
procedure ShowLoginList;
var
  List: uAuth.TAuthInfoArray;
  I: Integer;
  Mark, Pref: string;
begin
  List := uAuth.AuthList;
  Pref := uAuth.AuthPrefer;
  EmitCLn(clBright, 'Credential sources, in the order they are consulted');
  for I := 0 to High(List) do
  begin
    if List[I].Source = ActiveAuth.Source then Mark := '*' else Mark := ' ';
    if List[I].Present then
      EmitCLn(clGrey, Format('  %s%d. %-16s %s', [Mark, I + 1,
        uAuth.AuthSourceName(List[I].Source), List[I].Hint]))
    else
      EmitCLn(clGrey, Format('   %d. %-16s -', [I + 1,
        uAuth.AuthSourceName(List[I].Source)]));
    if List[I].Path <> '' then
      EmitCLn(clGrey, '        ' + List[I].Path);
    if List[I].Why <> '' then
      EmitCLn(clYellow, '        ' + List[I].Why);
  end;
  EmitLn;
  if ActiveAuth.Source <> uAuth.asNone then
    EmitCLn(clGrey, '  * in use: ' + uAuth.AuthDescribe(ActiveAuth));
  if Pref <> '' then
    EmitCLn(clGrey, '  preferred: ' + Pref);
  EmitCLn(clGrey, '  The two environment variables always win - a preference');
  EmitCLn(clGrey, '  can only choose among sources this machine already has,');
  EmitCLn(clGrey, '  never introduce one.  A number sets the preference,');
  EmitCLn(clGrey, '  Enter keeps the current source, and /login key stores a');
  EmitCLn(clGrey, '  key of pasclaude''s own under %LOCALAPPDATA%.');
end;

{ Stores a pasted key.  Nothing is echoed while it is typed, nothing reaches
  the history, and nothing is written unless DPAPI protected it. }
procedure LoginWithKey;
var
  Key, Err: string;
begin
  EmitCLn(clGrey, '  Paste an API key.  Typing is NOT shown - not even as');
  EmitCLn(clGrey, '  asterisks, because the length of a key is worth hiding');
  EmitCLn(clGrey, '  too.  Esc cancels.');
  if not uTerm.ReadSecretLine('  key: ', Key) then
  begin
    EmitCLn(clGrey, '  cancelled; nothing was stored');
    Exit;
  end;
  Key := Trim(Key);
  if Key = '' then
  begin
    EmitCLn(clGrey, '  nothing entered; nothing was stored');
    Exit;
  end;
  { Shape only.  A key this program cannot recognise may still be one the API
    accepts, so an unfamiliar prefix is a warning and not a refusal - the
    control characters are, because those cannot travel in a header at all. }
  if Pos('sk-ant-', Key) <> 1 then
    EmitCLn(clYellow, '  that does not look like an Anthropic key ' +
      '(no sk-ant- prefix); storing it anyway');
  if uAuth.AuthStore(Key, Err) then
  begin
    EmitCLn(clGrey, '  stored, DPAPI-protected, in ' + uAuth.CredentialStorePath);
    EmitCLn(clGrey, '  hint ' + uAuth.AuthHint(Key) +
      ' - only this Windows user on this machine can decrypt it');
    if ReResolveAuth then
      EmitCLn(clGrey, '  now using ' + uAuth.AuthDescribe(ActiveAuth));
  end
  else
    EmitCLn(clRed, '  ' + Err);
  { The local copy goes as soon as it has been handed over.  It still exists
    in Agent.FApiKey and in the outbound header, which is unavoidable, but
    there is no reason for a second copy to sit in this procedure's frame. }
  Key := '';
end;

procedure DoLogin(const Arg: string);
var
  List: uAuth.TAuthInfoArray;
  Choice_, Err: string;
  N: Integer;
begin
  if ScriptedRun then
  begin
    EmitCLn(clYellow, '  /login is interactive; a scripted run has nobody ' +
      'to answer it. Set ANTHROPIC_API_KEY, or run pasclaude ' +
      'interactively once to store a credential.');
    Exit;
  end;
  if LowerCase(Arg) = 'key' then
  begin
    LoginWithKey;
    Exit;
  end;
  if Arg <> '' then
  begin
    EmitCLn(clRed, '  /login takes "key" or no argument');
    Exit;
  end;
  ShowLoginList;
  List := uAuth.AuthList;
  EmitLn;
  if not ReadLineEdit('  source (number, "key", or Enter to keep): ',
    Choice_) then Exit;
  Choice_ := Trim(Choice_);
  if Choice_ = '' then Exit;
  if LowerCase(Choice_) = 'key' then
  begin
    LoginWithKey;
    Exit;
  end;
  N := StrToIntDef(Choice_, 0);
  if (N < 1) or (N > Length(List)) then
  begin
    EmitCLn(clRed, '  not one of the numbers listed');
    Exit;
  end;
  if uAuth.AuthSetPrefer(uAuth.AuthSourceName(List[N - 1].Source), Err) then
  begin
    EmitCLn(clGrey, '  preference recorded: ' +
      uAuth.AuthSourceName(List[N - 1].Source));
    if not List[N - 1].Present then
      EmitCLn(clYellow, '  that source has nothing usable right now, so ' +
        'another one answers until it does')
    else if ReResolveAuth then
      EmitCLn(clGrey, '  now using ' + uAuth.AuthDescribe(ActiveAuth));
  end
  else
    EmitCLn(clRed, '  ' + Err);
end;

{ Removes pasclaude's OWN credential and nothing else.  When the credential
  in force came from Claude Code, Jcode or the ant profile this refuses and
  names the file: deleting or rewriting it would break a program the user did
  not ask us to touch, and "log out" of somebody else's session is not a
  sentence this program is entitled to say. }
procedure DoLogout;
var
  Err: string;
begin
  if ScriptedRun then
  begin
    EmitCLn(clYellow, '  /logout is interactive; a scripted run has nobody ' +
      'to answer it.');
    Exit;
  end;
  case ActiveAuth.Source of
    uAuth.asApiKeyEnv, uAuth.asAuthTokenEnv:
      begin
        EmitCLn(clYellow, '  the credential in use comes from the ' +
          uAuth.AuthDescribe(ActiveAuth) + ' environment variable.');
        EmitCLn(clGrey, '  Unset it in your shell; pasclaude does not ' +
          'change your environment.');
      end;
    uAuth.asClaudeCode, uAuth.asJcode, uAuth.asAntProfile:
      begin
        EmitCLn(clYellow, '  the credential in use belongs to another ' +
          'program:');
        EmitCLn(clGrey, '  ' + ActiveAuth.Path);
        EmitCLn(clGrey, '  pasclaude reads that file and never writes it, ' +
          'so /logout will not');
        EmitCLn(clGrey, '  touch it. Log out of that program instead.');
      end;
  end;
  { The store is removed whatever was in force: a stored credential the user
    wants gone should go even when an environment variable is currently
    shadowing it. }
  if uAuth.AuthClear(Err) then
  begin
    EmitCLn(clGrey, '  removed ' + uAuth.CredentialStorePath);
    if ReResolveAuth then
      EmitCLn(clGrey, '  now using ' + uAuth.AuthDescribe(ActiveAuth))
    else
      EmitCLn(clYellow, '  no credential remains; the next turn will be ' +
        'refused here rather than sent. /login stores one.');
  end
  else
    EmitCLn(clGrey, '  ' + Err);
end;

{ ------------------------------------------------------- status / doctor -- }

{ Everything uDiag cannot know: the console, the credential, the keybinding
  file, whether anybody is watching.  One block rather than a dozen
  callbacks, and called again at the top of each of the three commands so a
  report typed an hour into the session describes the session as it is now
  rather than as it started.

  The credential VALUE is deliberately absent.  Only the source word, the two
  booleans and the expiry cross this line, which is why /bug cannot leak a
  token even if every redactor in uDiag failed: the secret is not in the
  record the report is built from. }
procedure FillDiagFacts;
var
  Sub, Comp: string;
  GhRepo: uGitHub.TGhRepo;
begin
  uDiag.DiagFacts.Version := Version;
  if ActiveAuth.Source = uAuth.asNone then
    uDiag.DiagFacts.AuthSource := ''
  else
    uDiag.DiagFacts.AuthSource := uAuth.AuthSourceName(ActiveAuth.Source);
  uDiag.DiagFacts.AuthDetail := uAuth.AuthDescribe(ActiveAuth);
  uDiag.DiagFacts.AuthPresent := (not NoCredential) and
    (ActiveAuth.Token <> '');
  { The one line in the host that reads the key, and it reads a prefix and
    produces a Boolean.  uAgent.IsOauth is a private method of the agent, so
    the same test is spelled here against the same exported constant. }
  uDiag.DiagFacts.AuthIsOauth := Copy(ActiveAuth.Token, 1,
    Length(uAgent.OauthKeyPrefix)) = uAgent.OauthKeyPrefix;
  uDiag.DiagFacts.AuthExpiresAtMs := ActiveAuth.ExpiresMs;
  uDiag.DiagFacts.HasConsole := StdinIsConsole;
  uDiag.DiagFacts.StdinIsConsole := StdinIsConsole;
  uDiag.DiagFacts.VtActive := TermVtActive;
  uDiag.DiagFacts.ConsoleOutCp := GetConsoleOutputCP;
  uDiag.DiagFacts.ConsoleInCp := GetConsoleCP;
  uDiag.DiagFacts.VimOn := PromptProfile.Vim;
  uDiag.DiagFacts.Scripted := ScriptedRun;
  uDiag.DiagFacts.KeysPath := KeysPath;
  uDiag.DiagFacts.HistoryPath := HistoryPath;
  uDiag.DiagFacts.PermissionsPath := PermissionsPath;
  uDiag.DiagFacts.SessionFilePath := SessionPath(uTools.RootDir);
  uDiag.DiagFacts.SettingsSupported := True;
  { 'on'/'off' rather than a Boolean so that a caller which never ran this
    block leaves '' behind and uDiag reports "not probed" instead of
    inventing an answer.  The command path is the only place that decides
    whether an editor is really there; this says only what the setting is. }
  if uSettings.SettingIsSet('ide.enabled') and
     not uSettings.SettingBool('ide.enabled') then
    uDiag.DiagFacts.IdeSetting := 'off'
  else
    uDiag.DiagFacts.IdeSetting := 'on';
  uDiag.DiagFacts.IdeCommand := uSettings.SettingStr('ide.command');
  { Identity and the NAME of a token source - never a token, never a hint,
    never a length.  GhTokenSourceOffline spawns nothing: /status must not
    run a program whose whole job is to print a credential to a pipe, which
    is also what lets the doctor check declare dcNone. }
  if uGitHub.GhRepoFromGit(GhRepo) then
  begin
    uDiag.DiagFacts.GithubRepo := GhRepo.Owner + '/' + GhRepo.Name;
    uDiag.DiagFacts.GithubRemoteWhy := '';
    uDiag.DiagFacts.GithubTokenSource := uGitHub.GhTokenSourceOffline;
  end
  else
  begin
    uDiag.DiagFacts.GithubRepo := '';
    uDiag.DiagFacts.GithubTokenSource := '';
    uDiag.DiagFacts.GithubRemoteWhy := GhRepo.Why;
  end;
  { One report builder, not two: /config colours these same rows.  A second
    derivation here is how /status and /config end up disagreeing about
    which tier a value came from. }
  uDiag.DiagFacts.SettingsSummary := uSettings.SettingsReport;
  uDiag.DiagFacts.SettingsRefused := uSettings.SettingsRefusals;
  { Where the model name came from at STARTUP.  /model typed since is not
    visible here, which is why the caption says "at startup". }
  if Trim(GetEnvironmentVariable('ANTHROPIC_MODEL')) <> '' then
    uDiag.DiagFacts.ModelSource := 'ANTHROPIC_MODEL'
  else if uSettings.SettingIsSet('model') then
    uDiag.DiagFacts.ModelSource := 'settings.json (' +
      uSettings.TierName(uSettings.SettingSource('model')) + ')'
  else
    uDiag.DiagFacts.ModelSource := 'the built-in default';
  Sub := uAgent.ModelRoute(uAgent.mrSubagent);
  Comp := uAgent.ModelRoute(uAgent.mrCompact);
  uDiag.DiagFacts.ModelRouting := '';
  if (Sub <> '') or (Comp <> '') then
    uDiag.DiagFacts.ModelRouting := 'subagent ' + Sub + ', compaction ' + Comp;
  if uTelem.TelemEnabled then
    uDiag.DiagFacts.TelemetrySummary := 'on, sending to ' +
      uTelem.TelemState.Endpoint
  else if uTelem.TelemState.SelfDisabled then
    uDiag.DiagFacts.TelemetrySummary := 'stopped for this session after ' +
      'repeated failures (/telemetry)'
  else
    uDiag.DiagFacts.TelemetrySummary := '';
end;

procedure ShowStatus;
var
  Report: uDiag.TStatusReport;
  Lines: TStringArray;
  I: Integer;
begin
  FillDiagFacts;
  Report := uDiag.DiagBuildStatus(Agent);
  Lines := uDiag.DiagStatusText(Report);
  for I := 0 to High(Lines) do EmitCLn(clGrey, Lines[I]);
end;

procedure ShowDoctor(const Arg: string);
var
  Report, One: uDiag.TDiagReport;
  Lines: TStringArray;
  I, J, Problems, Warnings: Integer;
  Online: Boolean;
  C: TColor;
begin
  Online := (Arg = '--online') or (Arg = 'online');
  if (Arg <> '') and not Online then
  begin
    EmitCLn(clRed, '  /doctor takes no argument, or --online');
    Exit;
  end;
  FillDiagFacts;
  if Online then
    { Said before it happens, not after.  One GET is still a request, and
      this program does not make one because a command's name sounded
      harmless. }
    EmitCLn(clGrey, '  --online: asking the API which models this ' +
      'credential can use (one GET, no tokens billed)');
  Report := uDiag.DiagBuildDoctor(Agent, Online);
  Problems := 0;
  Warnings := 0;
  SetLength(One, 1);
  for I := 0 to High(Report) do
  begin
    case Report[I].Level of
      uDiag.dlProblem: begin C := clRed; Inc(Problems); end;
      uDiag.dlWarn: begin C := clYellow; Inc(Warnings); end;
    else
      C := clGrey;
    end;
    { Rendered one check at a time through the SAME pure renderer the JSON
      path and /bug use, so a colour decision here can never change what a
      line says. }
    One[0] := Report[I];
    Lines := uDiag.DiagDoctorText(One);
    for J := 0 to High(Lines) do EmitCLn(C, Lines[J]);
  end;
  EmitLn;
  if Problems > 0 then
    EmitCLn(clRed, Format('  %d problem(s), %d warning(s)',
      [Problems, Warnings]))
  else if Warnings > 0 then
    EmitCLn(clYellow, Format('  no problems, %d warning(s)', [Warnings]))
  else
    EmitCLn(clGreen, '  no problems found');
  if not Online then
    EmitCLn(clGrey, '  (/doctor --online also asks the API which models ' +
      'this credential can use)');
end;

procedure DoBug(const Arg: string);
var
  Opts: uDiag.TBugOptions;
  Path, TranscriptPath, Err, Tok, Rest: string;
  Sp: Integer;
begin
  Opts.IncludeTranscript := False;
  Opts.RealPaths := False;
  Opts.AsJson := False;
  Rest := Trim(Arg);
  while Rest <> '' do
  begin
    Sp := Pos(' ', Rest);
    if Sp = 0 then
    begin
      Tok := Rest;
      Rest := '';
    end
    else
    begin
      Tok := Copy(Rest, 1, Sp - 1);
      Rest := Trim(Copy(Rest, Sp + 1, MaxInt));
    end;
    if Tok = '--transcript' then Opts.IncludeTranscript := True
    else if Tok = '--paths' then Opts.RealPaths := True
    else if Tok = '--json' then Opts.AsJson := True
    else
    begin
      EmitCLn(clRed, '  unknown option: ' + Tok);
      EmitCLn(clGrey, '  /bug [--transcript] [--paths] [--json]');
      Exit;
    end;
  end;
  FillDiagFacts;
  if not uDiag.DiagWriteBug(Agent, Opts, Path, TranscriptPath, Err) then
  begin
    EmitCLn(clRed, '  no report was written: ' + Err);
    Exit;
  end;
  EmitCLn(clGreen, '  wrote ' + Path);
  { The report can succeed while the transcript does not.  Silence there
    would leave the user believing --transcript did what they asked. }
  if Err <> '' then EmitCLn(clYellow, '  ' + Err);
  if TranscriptPath <> '' then
  begin
    EmitCLn(clGrey, '  and ' + TranscriptPath);
    { Yellow, because --transcript is the one flag whose cost is not
      obvious from its name.  Secrets are redacted; meaning cannot be. }
    EmitCLn(clYellow, '  that second file is your conversation. Secrets ' +
      'are redacted, nothing else is.');
  end;
  EmitCLn(clGrey, '  Nothing was uploaded - there is no upload path in this');
  EmitCLn(clGrey, '  program, not a disabled one. Read the file before you');
  EmitCLn(clGrey, '  share it: it names your files, and path redaction is');
  EmitCLn(clGrey, '  best effort by substring match.');
  if not Opts.RealPaths then
    EmitCLn(clGrey, '  Paths are replaced with %USERPROFILE%, %LOCALAPPDATA% ' +
      'and <root0>..; --paths keeps the real ones.');
  EmitCLn(clGrey, '  Excluded: prompts, replies, tool input and output, file');
  EmitCLn(clGrey, '  contents, environment values, and the credential in any');
  EmitCLn(clGrey, '  form.');
end;

{ ---------------------------------------------------------------- /review -- }

{ A LOCAL review, and only a local one.  Reviewing a GitHub pull request
  through the API would mean pulling an arbitrarily large, arbitrarily
  hostile diff written by whoever opened it into the context of an agent that
  holds thirteen tools - for a result "gh pr checkout <n>" followed by
  "/review main" already gives, with code the user chose to check out.  A
  digit-only argument is therefore refused BY NAME and told what to type,
  rather than quietly doing something adjacent. }
procedure DoReview(const Arg: string);
var
  A, Args, StatArgs, Cmd, Stat, Diff, Err: string;
  I, Code: Integer;
  L: TStringList;
  AllDigits: Boolean;
begin
  A := Trim(Arg);
  AllDigits := A <> '';
  for I := 1 to Length(A) do
    if not (A[I] in ['0'..'9']) then AllDigits := False;
  if AllDigits then
  begin
    EmitCLn(clYellow, '  /review does not fetch a pull request.');
    EmitCLn(clGrey,   '  gh pr checkout ' + A + '   and then   /review main');
    EmitCLn(clGrey,   '  reviews the same change, from code you chose to');
    EmitCLn(clGrey,   '  check out and can read first.');
    Exit;
  end;

  if A = '' then
    Args := 'diff HEAD'
  else if (A = '--staged') or (A = '--cached') then
    Args := 'diff --cached'
  else
  begin
    { The ref is user text about to enter an UNGATED cmd.exe command line:
      no permission prompt, no deny check, no sandbox.  It is charset-checked
      BEFORE composition and composed nowhere else, because "/review main &
      whoami" is command injection into the one shell in this program that
      answers to nobody. }
    Args := uGitHub.GhReviewDiffArgs(A);
    if Args = '' then
    begin
      EmitCLn(clRed,  '  that is not a ref pasclaude will put on a command line');
      EmitCLn(clGrey, '  letters, digits and . _ - / only, up to 128 ' +
        'characters, and no ".."');
      Exit;
    end;
  end;
  StatArgs := 'diff --stat' + Copy(Args, 5, MaxInt);

  Cmd := uTools.ProgramCommand('git', StatArgs);
  if Cmd = '' then
  begin
    EmitCLn(clRed, '  git is not on PATH, so there is nothing to diff');
    Exit;
  end;
  Stat := uTools.RunShellQuiet(Cmd, Code);
  if Code <> 0 then
  begin
    EmitCLn(clRed, '  git could not produce that diff - is this a ' +
      'repository, and does that ref exist?');
    Exit;
  end;
  if Trim(Stat) = '' then
  begin
    EmitCLn(clGrey, '  nothing to review: that diff is empty');
    Exit;
  end;

  { The stat first, so the user sees the size and the file list BEFORE a
    turn is spent on it. }
  EmitCLn(clBright, '  git ' + StatArgs + ':');
  L := TStringList.Create;
  try
    L.Text := Stat;
    for I := 0 to L.Count - 1 do
      if Trim(L[I]) <> '' then EmitCLn(clGrey, '    ' + L[I]);
  finally
    L.Free;
  end;

  Diff := uTools.RunShellQuiet(uTools.ProgramCommand('git', Args), Code);
  if Length(Diff) > uGitHub.GhMaxTotalBytes then
    { Utf8Cut, never Copy: a cut inside a multi-byte sequence would put
      invalid UTF-8 into every later request in the session. }
    Diff := uJson.Utf8Cut(Diff, uGitHub.GhMaxTotalBytes) + #10 +
      '[... the diff was cut at ' + IntToStr(uGitHub.GhMaxTotalBytes) +
      ' bytes ...]';

  { An ordinary turn, exactly the /init shape: anything the model then wants
    to change shows its diff and asks like any other edit. }
  AtLineStart := True;
  MdReset;
  if not Agent.Send(
    'Review the following diff of this project (from "git ' + Args + '"). ' +
    'Point out correctness bugs, missing error handling, and anything that ' +
    'contradicts the conventions you can see in the code. Be specific about ' +
    'file and line. Do not rewrite anything unless I ask.'#10#10 +
    Diff, Err) then
  begin
    NeedNewLine;
    EmitCLn(clRed, '  ' + Err);
  end;
end;

{ ----------------------------------------------------------- /pr-comments -- }

{ Read-only, and consent is per invocation and per pull request: there is no
  github tool, so the model can never fetch one itself, and there is no
  polling.  The rendered lines go to the console FIRST and the model is sent
  exactly those lines - nothing reaches it that the user did not see. }
procedure DoPrComments(const Arg: string);
var
  Repo: uGitHub.TGhRepo;
  Auth: uGitHub.TGhAuth;
  Info: uGitHub.TGhPrInfo;
  Items: uGitHub.TGhCommentArray;
  E: uGitHub.TGhError;
  Lines: TStringArray;
  A, Tok, Branch, Cmd, Err: string;
  Num, I, Code, Sp: Integer;
  ShowOnly: Boolean;
begin
  A := Trim(Arg);
  ShowOnly := False;
  Num := 0;
  { Each command parses its own Arg; there is no shared option parser and
    HandleCommand split on the first space only. }
  while A <> '' do
  begin
    Sp := Pos(' ', A);
    if Sp = 0 then
    begin
      Tok := A;
      A := '';
    end
    else
    begin
      Tok := Copy(A, 1, Sp - 1);
      A := Trim(Copy(A, Sp + 1, MaxInt));
    end;
    if Tok = '--show' then
      ShowOnly := True
    else if StrToIntDef(Tok, -1) > 0 then
      Num := StrToIntDef(Tok, 0)
    else
    begin
      EmitCLn(clRed,  '  unknown argument: ' + Tok);
      EmitCLn(clGrey, '  /pr-comments [<number>] [--show]');
      Exit;
    end;
  end;

  if not uGitHub.GhRepoFromGit(Repo) then
  begin
    EmitCLn(clYellow, '  ' + Repo.Why);
    Exit;
  end;
  uGitHub.GhResolveToken(Auth);

  if Num = 0 then
  begin
    Cmd := uTools.ProgramCommand('git', 'rev-parse --abbrev-ref HEAD');
    if Cmd = '' then
    begin
      EmitCLn(clRed, '  git is not on PATH, so the branch is unknown; ' +
        'name the pull request number');
      Exit;
    end;
    Branch := Trim(uTools.RunShellQuiet(Cmd, Code));
    I := Pos(#10, Branch);
    if I > 0 then SetLength(Branch, I - 1);
    Branch := Trim(Branch);
    if not uGitHub.GhFindPrForBranch(Repo, Branch, Auth, Num, E) then
    begin
      EmitCLn(clRed, '  ' + uGitHub.GhErrorText(E, Repo, Auth.Present));
      Exit;
    end;
  end;

  if not uGitHub.GhFetchPrComments(Repo, Num, Auth, Info, Items, E) then
  begin
    EmitCLn(clRed, '  ' + uGitHub.GhErrorText(E, Repo, Auth.Present));
    Exit;
  end;

  Lines := uGitHub.GhRenderComments(Repo, Info, Items);
  for I := 0 to High(Lines) do
    EmitCLn(clGrey, '  ' + Lines[I]);
  if ShowOnly then
  begin
    EmitCLn(clGrey, '  --show: nothing was sent to the model');
    Exit;
  end;
  { Said out loud, every time.  The envelope tells the MODEL where the
    third-party text is; this tells the USER that it is going. }
  EmitCLn(clYellow, '  sending the lines above to the model as data. They ' +
    'were written by');
  EmitCLn(clYellow, '  whoever commented on that pull request, and every ' +
    'tool still asks.');
  AtLineStart := True;
  MdReset;
  if not Agent.Send(uGitHub.GhCommentsPrompt(Repo, Info, Items), Err) then
  begin
    NeedNewLine;
    EmitCLn(clRed, '  ' + Err);
  end;
end;

function HandleCommand(const Line: string; out Handled: Boolean): Boolean;
var
  Cmd, Arg: string;
  Sp: Integer;
  Dropped: Integer;
  Err: string;
  Rows: TModelUsageList;
  ArgI: Integer;
begin
  Result := True;
  Handled := False;
  if (Line = '') or (Line[1] <> '/') then Exit;
  Handled := True;

  Sp := Pos(' ', Line);
  if Sp = 0 then
  begin
    Cmd := LowerCase(Line);
    Arg := '';
  end
  else
  begin
    Cmd := LowerCase(Copy(Line, 1, Sp - 1));
    Arg := Trim(Copy(Line, Sp + 1, MaxInt));
  end;

  if (Cmd = '/exit') or (Cmd = '/quit') then
    Result := False
  else if Cmd = '/help' then
    ShowHelp
  else if Cmd = '/clear' then
  begin
    Agent.Reset;
    uTools.ClearChangedFiles;
    uTools.ClearTodos;
    { The transcript that held the job ids is being thrown away, so a job
      that survived it would be a process the user has no name for and no
      way to stop short of Task Manager. }
    uTools.ClearJobs;
    { A cleared conversation is about to be told what skills exist all over
      again, so it may as well be told the truth about the disk. }
    uTools.RefreshSkills;
    { MCP connections deliberately survive /clear, as the rewind snapshots and
      the approved bash programs do: a running server is a capability this
      session has, not something the conversation said. }
    { The saved copy has to go too.  Otherwise "cleared" means only "cleared
      until you resume", and a user who cleared something they did not want
      kept would find it again on the next run. }
    if Agent.SaveSession(SessionPath(uTools.RootDir), Err) then
      EmitCLn(clGrey, '  conversation cleared, here and on disk')
    else
      EmitCLn(clYellow, '  conversation cleared, but the saved copy remains: ' + Err);
  end
  else if Cmd = '/compact' then
  begin
    if Arg = 'full' then
    begin
      { The expensive kind: one request buys a transcript that keeps the
        substance of the dropped turns instead of forgetting them. }
      AtLineStart := True;
      MdReset;
      if Agent.CompactWithSummary(Err) then
      begin
        DropCheckpoints;
        MdFinish;
        AtLineStart := True;
        NeedNewLine;
        EmitCLn(clGrey, Format('  compacted to a summary (%d messages, %d bytes)',
          [Agent.MessageCount, Agent.TranscriptBytes]));
        if not Agent.SaveSession(SessionPath(uTools.RootDir), Err) then
          EmitCLn(clYellow, '  (but the session could not be saved: ' + Err + ')');
      end
      else
      begin
        MdFinish;
        AtLineStart := True;
        NeedNewLine;
        EmitCLn(clRed, '  could not summarize: ' + Err);
        EmitCLn(clGrey, '  the conversation is unchanged');
      end;
    end
    else
    begin
      Dropped := Agent.Compact(CompactKeepBytes);
      if Dropped > 0 then DropCheckpoints;
      if Dropped = 0 then
        EmitCLn(clGrey, Format('  nothing to compact (%d messages, %d bytes)',
          [Agent.MessageCount, Agent.TranscriptBytes]))
      else
        EmitCLn(clGrey, Format('  dropped %d older messages, %d left (%d bytes)',
          [Dropped, Agent.MessageCount, Agent.TranscriptBytes]));
    end;
  end
  else if Cmd = '/cwd' then
    ShowWorkingDirs('')
  else if Cmd = '/add-dir' then
    ShowWorkingDirs(Arg)
  else if Cmd = '/remove-dir' then
    DropWorkingDir(Arg)
  else if Cmd = '/diff' then
  begin
    { Approvals happen one edit at a time; this is the aggregated answer.
      When the directory is a git repository the real diff stat is the
      better source - it sees hand edits too - so it is preferred and the
      session's own list is the fallback. }
    ShowDiff;
  end
  else if Cmd = '/ide' then
    DoIde(Arg)
  else if Cmd = '/review' then
    DoReview(Arg)
  else if Cmd = '/pr-comments' then
    DoPrComments(Arg)
  else if Cmd = '/jobs' then
    ShowJobs
  else if Cmd = '/memory' then
    ShowMemory
  else if Cmd = '/rewind' then
    DoRewind
  else if Cmd = '/sessions' then
    PickSession
  else if Cmd = '/init' then
  begin
    if FileExists(MemoryPath) then
      EmitCLn(clYellow, '  ' + ExtractFileName(MemoryPath) +
        ' already exists; /memory shows it, # adds to it')
    else
    begin
      { The model writes it: it can read the project first, which is the
        whole point - a template would know nothing this directory did not
        already say.  An ordinary turn, so the write shows its diff and
        asks like any other. }
      AtLineStart := True;
      MdReset;
      if not Agent.Send(
        'Explore this project briefly (list_dir, key files) and then use ' +
        'write_file to create CLAUDE.md in the project root: a concise ' +
        'instruction file for AI coding agents working here. Include: what ' +
        'the project is, how to build and test it, the layout, and any ' +
        'conventions you can see in the code. Keep it under 60 lines. ' +
        'Do not invent rules the code does not show.', Err) then
      begin
        NeedNewLine;
        EmitCLn(clRed, '  ' + Err);
      end;
      MdFinish;
      AtLineStart := True;
    end;
  end
  else if Cmd = '/keys' then
    ShowKeys
  else if Cmd = '/vim' then
  begin
    if Arg = 'save' then
    begin
      if SaveVimSetting(Err) then
        EmitCLn(clGrey, '  vim ' + Choice(PromptProfile.Vim, 'on', 'off') +
          ' written to ' + KeysPath)
      else
        EmitCLn(clRed, '  ' + Err);
      Exit;
    end;
    if Arg = 'on' then SetPromptVim(True)
    else if Arg = 'off' then SetPromptVim(False)
    else if Arg = '' then SetPromptVim(not PromptProfile.Vim)
    else
    begin
      EmitCLn(clRed, '  /vim takes on, off, save, or no argument');
      Exit;
    end;
    if PromptProfile.Vim then
    begin
      EmitCLn(clGrey, '  vim mode on; [I] and [N] on the prompt say which mode');
      { The two things that stop working, said out loud.  Both are real
        losses, and finding them out by surprise is worse than either. }
      EmitCLn(clGrey, '  Esc now leaves insert mode instead of clearing the');
      EmitCLn(clGrey, '  line - Ctrl+U still clears it - and text pasted while');
      EmitCLn(clGrey, '  in normal mode is read as commands, not as text.');
      EmitCLn(clGrey, '  /vim save keeps it for future sessions; /keys lists');
      EmitCLn(clGrey, '  the bindings.');
    end
    else
      EmitCLn(clGrey, '  vim mode off');
  end
  else if Cmd = '/think' then
  begin
    if (Arg = '') or (Arg = 'on') then
      Agent.ThinkingBudget := DefaultThinkBudget
    else if Arg = 'off' then
      Agent.ThinkingBudget := 0
    else
    begin
      Agent.ThinkingBudget := StrToIntDef(Arg, -1);
      if Agent.ThinkingBudget < 0 then
      begin
        Agent.ThinkingBudget := 0;
        EmitCLn(clRed, '  /think takes on, off, or a token count');
        Exit;
      end;
      { The API floor is 1024; below it the request is rejected, and a
        rejected request is a worse answer than a rounded-up budget. }
      if (Agent.ThinkingBudget > 0) and (Agent.ThinkingBudget < 1024) then
        Agent.ThinkingBudget := 1024;
    end;
    { Recorded so /config reports what is actually in force rather than what
      the file says.  A hierarchy nobody can debug is worse than none, and the
      first thing a user checks after typing /think is /config. }
    uSettings.SettingsSetRuntime('thinking_budget',
      IntToStr(Agent.ThinkingBudget), '/think');
    if Agent.ThinkingBudget > 0 then
      EmitCLn(clGrey, Format('  extended thinking on, %d token budget',
        [Agent.ThinkingBudget]))
    else
      EmitCLn(clGrey, '  extended thinking off');
  end
  else if Cmd = '/web' then
  begin
    { The search runs on Anthropic's servers, so there is no tool call here to
      gate and no prompt to raise per query - this switch is the whole of the
      consent, which is why the notice spells out what it grants.  Not
      persisted, for the same reason /yolo is not: a standing file meaning
      "and every future session may reach the internet" is a wider grant than
      the word implied. }
    if (Arg = '') or (Arg = 'on') then
    begin
      Agent.WebSearch := True;
      EmitCLn(clYellow, '  web search on: the model can now reach the internet on its');
      EmitCLn(clYellow, '  own for the rest of this session. Individual searches are not');
      EmitCLn(clYellow, '  prompted for.');
    end
    else if Arg = 'off' then
    begin
      Agent.WebSearch := False;
      EmitCLn(clGrey, '  web search off');
    end
    else
      EmitCLn(clRed, '  /web takes on or off');
  end
  else if Cmd = '/save' then
  begin
    { /save <name> makes a named copy the autosave never overwrites, which
      is what turns one-session-per-directory into a collection: name the
      current state, keep going, and /sessions offers it later. }
    if Arg <> '' then
    begin
      for Sp := 1 to Length(Arg) do
        if Arg[Sp] in ['\', '/', ':', '.', '"', '*', '?', '<', '>', '|'] then
        begin
          EmitCLn(clRed, '  a session name cannot contain path characters');
          Exit;
        end;
      if Agent.SaveSession(IncludeTrailingPathDelimiter(uTools.RootDir) +
        SessionDir + PathDelim + Arg + '.session.json', Err) then
        EmitCLn(clGrey, Format('  saved %d messages as %s',
          [Agent.MessageCount, Arg]))
      else
        EmitCLn(clRed, '  could not save: ' + Err);
    end
    else if Agent.SaveSession(SessionPath(uTools.RootDir), Err) then
      EmitCLn(clGrey, Format('  saved %d messages', [Agent.MessageCount]))
    else
      EmitCLn(clRed, '  could not save: ' + Err);
  end
  else if Cmd = '/resume' then
  begin
    if Agent.LoadSession(SessionPath(uTools.RootDir), Err) then
    begin
      DropCheckpoints;
      TelemRebaseline;
      EmitCLn(clGrey, Format('  resumed %d messages (%d turns)',
        [Agent.MessageCount, Agent.TurnCount]));
    end
    else
      EmitCLn(clRed, '  could not resume: ' + Err);
  end
  else if Cmd = '/model' then
  begin
    if Arg <> '' then
      SetModelByName(Arg)
    else
      PickModel;
  end
  else if Cmd = '/paste' then
    DoPaste(Arg)
  else if Cmd = '/skills' then
    ShowSkills
  else if Cmd = '/output-style' then
    ShowOutputStyle(Arg)
  else if Cmd = '/plugins' then
    ShowPlugins(Arg)
  else if Cmd = '/hooks' then
    ShowHooks(Arg)
  else if Cmd = '/mcp' then
    ShowMcp(Arg)
  else if Cmd = '/login' then
    DoLogin(Arg)
  else if Cmd = '/logout' then
    DoLogout
  else if Cmd = '/status' then
    ShowStatus
  else if Cmd = '/doctor' then
    ShowDoctor(Arg)
  else if Cmd = '/bug' then
    DoBug(Arg)
  else if Cmd = '/config' then
    ShowConfig(Arg)
  else if Cmd = '/deny' then
    ShowDeny(Arg)
  else if Cmd = '/sandbox' then
    ShowSandbox(Arg)
  else if (Cmd = '/mode') or (Cmd = '/plan') then
    SetMode(Cmd, Arg)
  else if Cmd = '/yolo' then
  begin
    { One line where there were four flags.  /yolo deliberately does not grant
      a server permission to be spawned: that question was answered before
      this session knew what .mcp.json contained, and "stop asking me about
      these tools" is not the same sentence as "run whatever programs a cloned
      repository names".  For the same reason it does not trust hooks.json:
      that question is about running a repository's commands, not about the
      tools the model was declared.  Bypass reaches neither, because it is one
      line inside Permit and neither of those goes through Permit. }
    { And it adds no working directory either.  Reach and asking are separate
      axes on purpose: /yolo says "stop asking me about this session's tools",
      which is not a sentence about which directories exist. }
    uTools.SetPermMode(uTools.pmodeBypass);
    YoloSession := True;
    { Deliberately not persisted: /yolo is "I trust this session", and a
      standing file that quietly means "and every future one" is a wider
      grant than the word implied.  The per-answer approvals do persist,
      because each named the thing it covered.  Twice over now - bypass sets
      no persisted-shaped flag at all, so the save-suppression below is a
      second line of defence rather than the whole of it. }
    EmitCLn(clYellow, '  every tool is now approved for this session');
    { Said out loud, because "every" would otherwise be read as every.  A deny
      rule is checked above all four of the flags just set, and above the
      prompt they replace. }
    if uTools.DenyRulesInForce then
      EmitCLn(clYellow, '  deny rules still apply');
    { And so does the sandbox, deliberately untouched here.  /yolo is a
      statement about what the user will be ASKED; the sandbox is about what a
      child process CAN DO.  Turning one off because the other went off would
      be treating them as the same axis, which is the confusion this whole
      feature is careful not to make. }
    if uSandbox.SandboxLevel <> uSandbox.slOff then
      EmitCLn(clYellow, '  the sandbox still applies (' +
        uSandbox.SandboxLevelName(uSandbox.SandboxLevel) + '; /sandbox)');
  end
  else if Cmd = '/cost' then
  begin
    EmitCLn(clGrey, Format('  %d turns, %d input tokens, %d output tokens',
      [Agent.TurnCount, Agent.TokensIn, Agent.TokensOut]));
    if (Agent.CacheReadTokens > 0) or (Agent.CacheWriteTokens > 0) then
      EmitCLn(clGrey, Format('  cache: %d tokens read (90%% off), %d written',
        [Agent.CacheReadTokens, Agent.CacheWriteTokens]));
    if Agent.ContextTokens > 0 then
      EmitCLn(clGrey, Format('  context: %d tokens in the last request',
        [Agent.ContextTokens]));
    { Only above one model, so a session that never routed anywhere prints
      exactly what it printed before this existed.  When there IS more than
      one, the totals above have stopped being comparable - a thousand tokens
      of opus and a thousand of haiku are not the same money - and this block
      is the only thing that says so.  Still no prices: this program has no
      price table, for the same reason the SDK omits total_cost_usd. }
    Rows := Agent.UsageByModel;
    if Length(Rows) > 1 then
    begin
      EmitCLn(clGrey, '  by model:');
      for ArgI := 0 to High(Rows) do
        EmitCLn(clGrey, Format('    %s: %d in, %d out, %d cache read, %d written',
          [Rows[ArgI].Model, Rows[ArgI].TokensIn, Rows[ArgI].TokensOut,
           Rows[ArgI].CacheRead, Rows[ArgI].CacheWrite]));
    end;
  end
  else if Cmd = '/telemetry' then
    ShowTelemetry(Arg)
  else
    { Not one of ours.  Left unhandled so the caller can try the custom
      commands in .pasclaude\commands before declaring it unknown. }
    Handled := False;
end;

{ ------------------------------------------------------------------- main -- }

{ ExpandCustomCommand moved to uSdk with the prompt assembly; the REPL calls
  uSdk.SdkExpandCustomCommand below. }

{ How this run reports itself, decided in the argument loop and consulted by
  every startup failure below.  A driver that asked for JSON must never be
  handed a sentence: it has one parser, and prose on stdout is indistinguishable
  from a protocol line that went wrong. }
var
  OutFormat: uSdk.TSdkFormat = uSdk.sfText;
  StreamInput: Boolean = False;

var
  { uArgs.TDiagMode, and it used to be declared right here.  It moved out with
    the argument loop, because the claim its comment makes - "set by one thing,
    reachable from no file, no environment variable and no settings key" - was
    a claim about code no suite could link, and is now a claim about a pure
    function two suites do.  The enum's own comment travelled with it to
    uArgs; this is still the one variable in the program that holds the
    answer. }
  DiagMode: uArgs.TDiagMode = uArgs.dmNone;
  DiagOnline: Boolean = False;
  { The --ci-* flag values.  Every one of them is a PATH or a fixed word:
    no byte of comment text ever arrives on this program's command line,
    which is the classic GitHub Actions injection and is avoided by pasclaude
    reading GITHUB_EVENT_PATH itself rather than having YAML interpolate the
    body into a run: line. }
  CiInPath: string = '';
  CiPrPath: string = '';
  CiOutPath: string = '';
  CiTrigger: string = uCi.CiDefaultTrigger;
  CiFloor: uCi.TCiFloor = uCi.cfCollaborator;

{ The yellow startup block: deny rules that are not in force, settings
  problems, the project economy line, an --add-dir that came with a caveat.
  All of it is prose, and prose on stdout ahead of a JSON object breaks the
  driver parsing it - with --output-format json or stream-json this program's
  stdout carries the protocol and nothing else, which is what the manual
  promises for --status and --doctor and what a scripted -p needs to be worth
  using.  Nothing is lost by the guard: every one of these lines is also put
  in the diagnostic ledger, which is exactly what --doctor prints and what
  /bug includes.

  It is a guard on the OUTPUT FORMAT rather than on -p because the trigger is
  a settings.json in the project tree: a cloned repository must not be able to
  put a byte on a driver's stdout. }
procedure StartupNote(C: TColor; const S: string);
begin
  if OutFormat = uSdk.sfText then EmitCLn(C, S);
end;

{ Every early exit goes through here.  Hint is the human's extra context and
  is printed only in text mode - the machine gets the one line it can act on. }
procedure FailStart(const Msg, Hint: string; Code: Integer);
var
  L: TStringList;
  I: Integer;
begin
  if OutFormat = uSdk.sfText then
  begin
    EmitCLn(clRed, Msg);
    if Hint <> '' then
    begin
      L := TStringList.Create;
      try
        L.Text := Hint;
        for I := 0 to L.Count - 1 do EmitCLn(clGrey, '  ' + L[I]);
      finally
        L.Free;
      end;
    end;
  end
  else
    uSdk.SdkEmit(uSdk.SdkErrorLine(Msg));
  { Halt skips the finally block, so the console has to be put back here - and
    the sandbox's cached token closed here - or the caller's codepage stays
    switched to UTF-8 and a handle outlives the process that opened it. }
  uSandbox.SandboxShutdown;
  TermDone;
  Halt(Code);
end;

{ ------------------------------------------------------- GitHub Actions -- }

{ Writes Text to Path, creating or appending.  Deliberately small and
  deliberately here rather than in uCi: uCi is pure functions over bytes so
  that every decision it makes is a suite assertion, and the moment it opens
  a file half of it stops being testable without a temp tree. }
function CiPutFile(const Path, Text: string; Append: Boolean;
  out Err: string): Boolean;
var
  F: TFileStream;
begin
  Result := False;
  Err := '';
  try
    if Append and FileExists(Path) then
    begin
      F := TFileStream.Create(Path, fmOpenWrite or fmShareDenyWrite);
      F.Seek(0, soEnd);
    end
    else
      F := TFileStream.Create(Path, fmCreate);
    try
      if Text <> '' then F.WriteBuffer(Text[1], Length(Text));
    finally
      F.Free;
    end;
    Result := True;
  except
    on E: Exception do Err := E.Message;
  end;
end;

{ One name=value line into %GITHUB_OUTPUT%, and silence when the variable is
  not set (running the verb by hand outside a runner is a legitimate thing to
  do).  CiOutputLine returns '' for anything it will not vouch for and that
  line is then simply not written: a value carrying a newline would write a
  SECOND variable of the writer's choosing, and one of the variables here
  chooses the commit actions/checkout puts in the workspace. }
procedure CiEmitOutput(const Name, Value: string);
var
  Line, Path, Err: string;
begin
  Line := uCi.CiOutputLine(Name, Value);
  if Line = '' then Exit;
  Path := SysUtils.GetEnvironmentVariable('GITHUB_OUTPUT');
  if Path = '' then Exit;
  CiPutFile(Path, Line + #10, True, Err);
end;

procedure CiEmitSummary(const Text: string);
var
  Path, Err: string;
begin
  if Text = '' then Exit;
  Path := SysUtils.GetEnvironmentVariable('GITHUB_STEP_SUMMARY');
  if Path = '' then Exit;
  CiPutFile(Path, Text + #10, True, Err);
end;

{ The whole of the unattended path's host side.  It runs at the same point in
  startup as --status and --doctor, so the deny rules it asserts on are the
  ones actually in force for this process, and like them it ends in Halt on
  every path: there is no way from here to a REPL, a turn or a tool.

  Exit codes are the existing three and no more: 0 for any decision it
  reached (including "no, and here is why"), 2 for a usage error, an input it
  could not read or that was too large, an output it could not write, or a
  deny floor that is not in force. }
procedure RunCi;
var
  Bytes, Err, Text, Line: string;
  E: uCi.TCiEvent;
  P: uCi.TCiPr;
  D: uCi.TCiDecision;
  Missing, InForce: TStringArray;
  Rules: uTools.TDenyRuleArray;
  Answer, ErrText, Model: string;
  IsError: Boolean;
  DurationMs, I: Integer;
begin
  if not ReadFileText(CiInPath, Bytes) then
    FailStart('--ci-in: cannot read ' + CiInPath, '', 2);

  if DiagMode = dmCiReport then
  begin
    if not uCi.CiResultFromJson(Bytes, Answer, ErrText, Model, IsError,
      DurationMs, Err) then
      FailStart('--ci report: ' + Err,
        'the input is one line of --output-format json', 2);
    if not CiPutFile(CiOutPath, uCi.CiCommentBody(Answer, ErrText, Model,
      IsError, DurationMs), False, Err) then
      FailStart('--ci-out: cannot write ' + CiOutPath + ': ' + Err, '', 2);
    D := Default(uCi.TCiDecision);
    D.Proceed := True;
    D.Code := 'ok';
    CiEmitSummary(uCi.CiStepSummary(D, Answer, ErrText, IsError));
    EmitCLn(clGrey, '  ci: comment written to ' + CiOutPath);
    uTelem.TelemShutdown;
    uSandbox.SandboxShutdown;
    TermDone;
    Halt(0);
  end;

  { prepare. }
  if not uCi.CiParseEvent(Bytes, E, Err) then
    FailStart('--ci prepare: ' + Err,
      'the input is the file named by GITHUB_EVENT_PATH', 2);
  P := Default(uCi.TCiPr);
  if CiPrPath <> '' then
  begin
    if not ReadFileText(CiPrPath, Bytes) then
      FailStart('--ci-pr: cannot read ' + CiPrPath, '', 2);
    if not uCi.CiParsePr(Bytes, P, Err) then
      FailStart('--ci prepare: ' + Err,
        'the input is gh pr view --json isCrossRepository,headRefOid,state',
        2);
  end;

  { The assertion that keeps the strongest guarantee honest.  A workflow
    edited to drop the step that writes deny.json gets a run that stops here
    naming every missing rule, rather than one that quietly hands a shell to
    an agent answering a comment.  It is checked against the rules IN FORCE -
    a rule that failed to parse is not one - and it is checked here, after
    LoadDenyRules and before anything decides to proceed. }
  Rules := uTools.DenyRules;
  InForce := nil;
  for I := 0 to High(Rules) do
    if Rules[I].Err = '' then
    begin
      SetLength(InForce, Length(InForce) + 1);
      InForce[High(InForce)] := Rules[I].Text;
    end;
  Missing := uCi.CiDenyFloorMissing(InForce);
  if Length(Missing) > 0 then
  begin
    Text := '';
    for I := 0 to High(Missing) do
      Text := Text + '  ' + Missing[I] + #10;
    FailStart('--ci prepare: the CI deny floor is not in force',
      'these rules are missing and an unattended run will not start ' +
      'without them:'#10 + Text +
      'write them to the "deny" array of ' + uTools.GlobalDenyPath, 2);
  end;

  D := uCi.CiDecide(E, P, CiTrigger, CiFloor);

  if D.Proceed then
  begin
    if not CiPutFile(CiOutPath, D.Prompt, False, Err) then
      FailStart('--ci-out: cannot write ' + CiOutPath + ': ' + Err, '', 2);
  end
  else
  begin
    { The refusal comment goes to a sibling file rather than to --ci-out, so
      a workflow can never mistake "here is why not" for a prompt and feed it
      to the model.  An empty one means "say nothing at all", which is the
      right answer for a comment that never mentioned us. }
    Line := uCi.CiRefusalComment(D);
    if Line <> '' then CiPutFile(CiOutPath + '.md', Line, False, Err);
    CiEmitSummary(uCi.CiStepSummary(D, '', '', False));
  end;

  { Five values, every one from a fixed vocabulary or validated.  No byte of
    comment text reaches GITHUB_OUTPUT, GITHUB_ENV or a run: line, on any
    path. }
  if D.Proceed then
    CiEmitOutput('proceed', 'true')
  else
    CiEmitOutput('proceed', 'false');
  CiEmitOutput('code', D.Code);
  CiEmitOutput('reason', D.Reason);
  CiEmitOutput('number', IntToStr(D.Number));
  if D.HeadSha <> '' then CiEmitOutput('head_sha', D.HeadSha);
  if uCi.CiRefusalComment(D) <> '' then
    CiEmitOutput('refusal_file', 'yes');

  { One line for the log, built from the code and the fixed reason: the
    commenter's own words are not printed into a page anyone can read. }
  if D.Proceed then
    EmitCLn(clGrey, '  ci: proceeding (#' + IntToStr(D.Number) + ')')
  else
    EmitCLn(clGrey, '  ci: not proceeding (' + D.Code + ') - ' + D.Reason);
  uTelem.TelemShutdown;
  uSandbox.SandboxShutdown;
  TermDone;
  Halt(0);
end;

var
  ApiKey, ModelName, Line, Err, Dir, SaveErr, ResumeErr: string;
  { argv as data, and what uArgs made of it.  Argv holds ParamStr(1) upwards
    and nothing else: the parser is deliberately not given the program name,
    so no part of it can be off by one about which element is the first
    argument. }
  Argv: TStringArray;
  Cli: uArgs.TArgsOpts;
  MentionNotes: string;
  SkillNames: string;
  SkillList: uTools.TSkillInfoArray;
  NewPlugins: TStringArray;
  BadRules: TStringArray;
  SettingNotes: TStringArray;
  Handled: Boolean;
  Dropped: Integer;
  Resume: Boolean = False;
  Resumed: Boolean = False;
  { --continue: resume the most recent saved conversation without being asked
    which.  Held beside Resume rather than folded into it because the two name
    DIFFERENT files - Resume is always this directory's session.json, this one
    is whichever of the saved conversations was written last - and a run has to
    be able to say which of them it did. }
  ContinueFlag: Boolean = False;
  ResumeFile: string = '';
  AuthList: uAuth.TAuthInfoArray;
  ExpiryMs: Int64;
  SaveWarned: Boolean = False;
  ArgI: Integer;
  PrintPrompt: string = '';
  PrintMode: Boolean = False;
  WebFlag: Boolean = False;
  { --no-project-context, held rather than applied for the same reason
    ModeWanted is: the decision it feeds is made once, further down, after the
    session root is known and beside the hooks gate, and a flag that acted the
    moment it was parsed would be a second place the loader could be turned
    off.  False shipped, for the same reason uSdk.SdkProjectContextAllowed
    defaults false in the other direction - a flag nobody typed must leave -p
    behaving exactly as it always has. }
  NoProjectContext: Boolean = False;
  Piped: string;
  McpErr: string = '';
  HookNotes: string = '';
  { How many of the loaded entries came from the user's own file, counted at
    startup so the one line about them can be printed.  Nothing else reads it. }
  UserHooks: Integer = 0;
  { Not initialized, deliberately: an initialized global is a typed constant to
    the compiler and cannot be a for-loop counter. }
  HookIdx: Integer;
  HookOut: THookOutcome;
  HookCallRec: THookCall;
  SdkOpts: uSdk.TSdkOptions;
  SdkCode: Integer;
  { The transcript a -p run continues and saves to, as typed and then as
    resolved.  Empty means the flag was not given, which is what -p has always
    meant: nothing is written at all. }
  SessionFileArg: string = '';
  SessionFileFull: string = '';
  ResumeMsgs: Integer = 0;
  { The mode asked for on the command line, held rather than applied: it has
    to beat a grant loaded from the approvals file, and that file is read much
    later.  ModeGiven distinguishes "the user asked for ask" from "nobody
    said", which are different answers once allow_edits is on disk. }
  ModeWanted: uTools.TPermMode = uTools.pmodeAsk;
  ModeGiven: Boolean = False;
  { The two flags that used to be held here beside ModeWanted - recorded
    separately from it, which only one of them can win, so the two could be
    seen to contradict each other whichever order they arrived in - now live
    only in uArgs.TArgsOpts.  The contradiction is the ONLY thing that ever
    read them, and the contradiction is a refusal, which means it went out
    with the rest of the argument loop.  A host variable nothing reads is a
    variable somebody eventually writes a second meaning into, so they are
    gone rather than assigned and ignored. }
  { Held the same way and for a mirror-image reason: the approvals file may
    RAISE the sandbox level, so a --sandbox given on argv has to be applied
    both before that file is read (a -p run never gets past the halt) and
    again after it, or "--sandbox off" would be undone by a stale key. }
  SandboxWanted: uSandbox.TSandboxLevel = uSandbox.slLimits;
  SandboxGiven: Boolean = False;
  { Collected rather than applied as they are parsed: AddWorkingDir resolves
    relative to the session root, and the root is not set until after the
    optional [directory] argument has been seen. }
  AddDirs: TStringArray;
  AddArg: string = '';
  { Held rather than applied for the reason ModeWanted is: the approvals file
    may name a style too, and a name typed this time beats a name persisted
    weeks ago.  Under -p it is applied on the print branch instead, which
    never reads that file at all. }
  StyleWanted: string = '';
  StyleErr: string = '';
  StopActive: Boolean = False;
  Again: Boolean = False;
  TurnOk: Boolean = False;
  { The two reports and their rendered text, for the --status/--doctor
    branch below.  Built once, rendered once, never re-derived. }
  StatusReport: uDiag.TStatusReport;
  DoctorReport: uDiag.TDiagReport;
  DiagLines: TStringArray;

{ Applied twice, and idempotently, on purpose.  Once before the print-mode
  halt, because a -p run never reaches the second call and a flag it was given
  has to mean something; once after LoadPermissions, because that call only
  ever widens and would otherwise turn "--permission-mode ask" back into
  accept-edits using a grant from a previous session.  An explicit flag beats
  a loaded one - the user typed it this time. }
procedure ApplyStartupMode;
begin
  if not ModeGiven then Exit;
  uTools.SetPermMode(ModeWanted);
  if ModeWanted = uTools.pmodeBypass then
    { Sticky for the whole run: the shutdown save is skipped wholesale,
      because a session that approved everything cannot tell its blanket
      grants from the ones the user answered one at a time.  Bypass itself
      now sets no persisted flag, so this is the second line of defence
      rather than the only one. }
    YoloSession := True;
end;

{ Settles the sandbox level, and is called in the same two places and for the
  same reason as ApplyStartupMode.  A level of low that cannot actually be
  applied - no home directory to put the scratch in - falls back to limits and
  says so.  Never to off: the failure to find somewhere to put a temp
  directory is not a reason to stop confining children altogether. }
procedure ApplySandbox;
begin
  if SandboxGiven then uSandbox.SandboxLevel := SandboxWanted;
  if uSandbox.SandboxLevel <> uSandbox.slLow then Exit;
  if PrepareSandbox then Exit;
  uSandbox.SandboxLevel := uSandbox.slLimits;
  uDiag.DiagNote('sandbox', uDiag.dlWarn,
    'sandbox low is unavailable, using limits: no writable scratch ' +
    'directory outside the project to give children as %TEMP%',
    'set %LOCALAPPDATA% or %USERPROFILE%; /sandbox shows the level in force');
  if not PrintMode then
    EmitCLn(clYellow, '  sandbox low is unavailable: no writable scratch ' +
      'directory outside the project to give children as %TEMP%. Using ' +
      'limits.');
end;

begin
  TermInit;
  try
    { argv, collected into an array and handed to a function, instead of
      decided here.  Everything between this line and the apply block below
      used to be four hundred lines of if/else inside this main block, which
      no test suite can link - so every refusal it makes, including the four
      that --continue depends on, was verified by running the executable and
      reading the console.  Three rounds recorded that as a residual before
      anybody moved it.  uArgs.ArgsParse takes the arguments as data, writes
      no global, prints nothing, halts nothing and opens nothing, and smoke
      drives it over a hundred argument arrays.

      The program name is deliberately not passed: a parser that had to skip
      element zero would be a parser with an off-by-one waiting in it. }
    SetLength(Argv, ParamCount);
    for ArgI := 1 to ParamCount do Argv[ArgI - 1] := ParamStr(ArgI);
    Cli := uArgs.ArgsParse(Argv);
    { BEFORE the Ok test, and that order is load-bearing rather than tidy.
      FailStart chooses red prose or one SdkErrorLine by reading OutFormat, and
      the format used to be a global set half way down the loop - so a run that
      said "--output-format json --bogus" got a JSON error line and one that
      said "--bogus --output-format json" got prose, because the loop halted
      before it reached the format.  ArgsParse stops exactly where the loop
      halted and returns the state it had reached, so assigning the format
      first reproduces both, bit for bit.  Move this line below the test and
      every refusal after a format flag reverts to prose, silently, for a
      driver with one parser - and no suite would see it, because no suite
      spawns this executable. }
    OutFormat := Cli.OutFormat;
    if not Cli.Ok then FailStart(Cli.ErrMsg, Cli.ErrHint, Cli.ErrCode);
    if Cli.Help then
    begin
      { The text is output rather than a decision, so it stayed here.  A
        hundred and thirty lines of console prose in uArgs would be strings no
        assertion ever reads, in a unit whose whole value is that it has
        none. }
      EmitCLn(clBright, 'pasclaude [directory] [--resume] [--web] [--add-dir <dir>] [-p "prompt"]');
      EmitCLn(clGrey, '  --resume  continue the conversation saved in that directory');
      EmitCLn(clGrey, '            (-r; under -p it needs --session-file, below)');
      EmitCLn(clGrey, '  --continue');
      EmitCLn(clGrey, '            continue the most recently saved conversation in that');
      EmitCLn(clGrey, '            directory, whichever it is - the live one, the safety');
      EmitCLn(clGrey, '            copy, or a /save - and do not ask (-c). To CHOOSE one,');
      EmitCLn(clGrey, '            start without it and type /sessions. Interactive only:');
      EmitCLn(clGrey, '            under -p name the transcript with --session-file.');
      EmitCLn(clGrey, '  --web     let the model search the web (off by default)');
      EmitCLn(clGrey, '  -p        answer one prompt and exit (reads stdin when piped)');
      EmitCLn(clGrey, '            (-p never loads hooks: nobody is there to approve them)');
      EmitCLn(clGrey, '  --permission-mode ask|plan|accept-edits');
      EmitCLn(clGrey, '            ask (the default) prompts for every write, edit and command;');
      EmitCLn(clGrey, '            plan lets the model only read and investigate, and refuses');
      EmitCLn(clGrey, '            everything else until you leave it with /mode;');
      EmitCLn(clGrey, '            accept-edits stops asking about file writes (but not about');
      EmitCLn(clGrey, '            shell commands or fetch), and needs somebody to be there,');
      EmitCLn(clGrey, '            so under -p it needs --input-format stream-json.');
      EmitCLn(clGrey, '            Plan mode stops the MODEL, not the machine: your own');
      EmitCLn(clGrey, '            hooks still run.');
      EmitCLn(clGrey, '  --sandbox off|limits|low');
      EmitCLn(clGrey, '            how confined the child processes are - shell commands,');
      EmitCLn(clGrey, '            background jobs, hooks and MCP servers.  limits (the');
      EmitCLn(clGrey, '            default) puts each in a job object: at most 64 processes,');
      EmitCLn(clGrey, '            no breakaway, killed with the session.  low additionally');
      EmitCLn(clGrey, '            runs them at low integrity, which stops them writing your');
      EmitCLn(clGrey, '            profile, HKCU and this project, and gives them a scratch');
      EmitCLn(clGrey, '            %TEMP% of their own.  Neither level stops a command');
      EmitCLn(clGrey, '            READING your files and neither stops it using the network:');
      EmitCLn(clGrey, '            scoping a process to a directory needs a filesystem filter');
      EmitCLn(clGrey, '            driver and blocking its network needs a firewall rule.');
      EmitCLn(clGrey, '            The sandbox is defence in depth and does NOT change what');
      EmitCLn(clGrey, '            you are asked to approve.');
      EmitCLn(clGrey, '  --dangerously-skip-permissions');
      EmitCLn(clGrey, '            approve everything, asking nothing, for this run only.');
      EmitCLn(clGrey, '            Nothing is persisted.  Deny rules, the session root and');
      EmitCLn(clGrey, '            the subagent read-only list still apply; nothing else does.');
      EmitCLn(clGrey, '  --add-dir <dir>');
      EmitCLn(clGrey, '            also work in that directory, repeatable. Paths there must');
      EmitCLn(clGrey, '            be given absolute; a bare relative path always means the');
      EmitCLn(clGrey, '            session root. An added directory grants file access only:');
      EmitCLn(clGrey, '            its hooks, skills, commands, agents and .mcp.json are not');
      EmitCLn(clGrey, '            read. Nothing is persisted, so say it again next session.');
      EmitCLn(clGrey, '  --no-project-context');
      EmitCLn(clGrey, '            do not read this tree''s AGENTS.md, CLAUDE.md or');
      EmitCLn(clGrey, '            .pasclaude.md into the system prompt, and follow no @import');
      EmitCLn(clGrey, '            inside one.  For a checkout somebody else wrote: the Answer');
      EmitCLn(clGrey, '            step in examples\github\ passes it, because that step runs in');
      EmitCLn(clGrey, '            the pull request''s own head.  Without it, -p loads them');
      EmitCLn(clGrey, '            exactly as the REPL does and scripts rely on that.  Your own');
      EmitCLn(clGrey, '            %USERPROFILE%\.pasclaude\CLAUDE.md still loads - the question');
      EmitCLn(clGrey, '            the flag asks is which TREE wrote the prompt.  Skills are not');
      EmitCLn(clGrey, '            affected: their descriptions ride in the skill tool''s own');
      EmitCLn(clGrey, '            description and were never in the system prompt.');
      EmitCLn(clGrey, '  --output-style <name>');
      EmitCLn(clGrey, '            how replies are written: default, explanatory, learning,');
      EmitCLn(clGrey, '            or a .pasclaude\styles\<name>.md of your own (the user');
      EmitCLn(clGrey, '            copy under %USERPROFILE% counts too).  A style adds a');
      EmitCLn(clGrey, '            paragraph to the system prompt and never replaces one; it');
      EmitCLn(clGrey, '            grants nothing and cannot change what you are asked to');
      EmitCLn(clGrey, '            approve.  Interactively the name is remembered; under -p');
      EmitCLn(clGrey, '            nothing is remembered and this flag is the only way in.');
      EmitCLn(clGrey, '            Edit the file and it applies from the next turn; if the');
      EmitCLn(clGrey, '            edit cannot be read the old text stays and you are told.');
      EmitCLn(clGrey, '  --append-system-prompt <text>');
      EmitCLn(clGrey, '            add your own paragraph to the end of the system prompt for');
      EmitCLn(clGrey, '            this run.  It ADDS and never replaces: the guidelines and');
      EmitCLn(clGrey, '            this project''s CLAUDE.md are still there, above it.  Give');
      EmitCLn(clGrey, '            it more than once and the pieces accumulate in order,');
      EmitCLn(clGrey, '            separated by a blank line; 4096 bytes in total, and past');
      EmitCLn(clGrey, '            that the run stops rather than sending half of it.  There');
      EmitCLn(clGrey, '            is no settings.json key for this on purpose - a file in a');
      EmitCLn(clGrey, '            cloned project that could rewrite the system prompt is the');
      EmitCLn(clGrey, '            thing that must not exist.  Something long belongs in');
      EmitCLn(clGrey, '            CLAUDE.md, where /memory can show it to you.');
      EmitCLn(clGrey, '  --session-file <path>   (needs -p)');
      EmitCLn(clGrey, '            names the transcript a -p run saves to after every turn,');
      EmitCLn(clGrey, '            and with --resume the one it continues.  Without it -p');
      EmitCLn(clGrey, '            saves nothing at all, as it always has: a throwaway');
      EmitCLn(clGrey, '            question does not disturb the directory''s conversation.');
      EmitCLn(clGrey, '            The path must be inside the session root or an --add-dir');
      EmitCLn(clGrey, '            root.  A file that is not there yet is a fresh start; one');
      EmitCLn(clGrey, '            that is there and unreadable, or written by a newer build,');
      EmitCLn(clGrey, '            stops the run with exit 2 rather than starting blank -');
      EmitCLn(clGrey, '            interactive --resume warns and carries on instead, because');
      EmitCLn(clGrey, '            somebody is there to read the warning.  A resumed session');
      EmitCLn(clGrey, '            restores messages, model and counters and NOTHING else: no');
      EmitCLn(clGrey, '            mode, no approvals, no roots, so it can never come back');
      EmitCLn(clGrey, '            more permissive than a fresh one.  Nothing is compacted on');
      EmitCLn(clGrey, '            this path, so a session that outgrows the context window is');
      EmitCLn(clGrey, '            answered with a new file.  Two processes sharing one file');
      EmitCLn(clGrey, '            race: each write is atomic, but the loser''s turn is lost.');
      EmitCLn(clGrey, '  --status        print what is true right now and exit 0.');
      EmitCLn(clGrey, '  --doctor [--online]');
      EmitCLn(clGrey, '            check for problems and exit 1 if there are any, so');
      EmitCLn(clGrey, '            "pasclaude --doctor || setup" works in a script.');
      EmitCLn(clGrey, '            Offline and makes no request; --online adds one GET');
      EmitCLn(clGrey, '            asking which models the credential can use.  Both');
      EmitCLn(clGrey, '            modes run alone - never with -p, a prompt, --resume');
      EmitCLn(clGrey, '            or a driver - and neither can run a turn or a tool,');
      EmitCLn(clGrey, '            which is why they continue past a missing credential');
      EmitCLn(clGrey, '            and report it instead of refusing to start.  Both');
      EmitCLn(clGrey, '            take --output-format json|stream-json.');
      EmitCLn(clBright, '  GitHub Actions (see examples\github\)');
      EmitCLn(clGrey, '  --ci prepare|report');
      EmitCLn(clGrey, '            the unattended path, run from a workflow step and never');
      EmitCLn(clGrey, '            with -p, a prompt, --resume or a driver.  prepare reads');
      EmitCLn(clGrey, '            the event payload, decides whether to answer at all, and');
      EmitCLn(clGrey, '            writes the prompt; report turns one line of');
      EmitCLn(clGrey, '            --output-format json into the comment markdown.  prepare');
      EmitCLn(clGrey, '            refuses to run unless the CI deny floor is in force, so a');
      EmitCLn(clGrey, '            workflow edited to drop it fails closed.');
      EmitCLn(clGrey, '  --ci-in <path>     the event payload, or the result line');
      EmitCLn(clGrey, '  --ci-out <path>    the prompt file, or the comment markdown');
      EmitCLn(clGrey, '  --ci-pr <path>     gh pr view --json isCrossRepository,headRefOid,state');
      EmitCLn(clGrey, '  --ci-trigger <phrase>   default @claude');
      EmitCLn(clGrey, '  --ci-allow collaborator|member|owner');
      EmitCLn(clGrey, '            the lowest author association that may start a run.  It');
      EmitCLn(clGrey, '            narrows only: there is no flag that widens it.');
      EmitCLn(clGrey, '  --output-format text|json|stream-json   (needs -p)');
      EmitCLn(clGrey, '  --input-format  text|stream-json        (needs -p and stream-json out)');
      EmitCLn(clGrey, '            json/stream-json put one JSON object per line on stdout,');
      EmitCLn(clGrey, '            for driving pasclaude from another program.  Without');
      EmitCLn(clGrey, '            --input-format stream-json there is nobody to approve');
      EmitCLn(clGrey, '            anything, so every write, edit and shell command is refused.');
      EmitCLn(clGrey, '            -p takes the next argument as its prompt unless that starts');
      EmitCLn(clGrey, '            with "-", so the flags may go on either side of it.');
      { Halt skips the finally block, so the console has to be put back
        here or the caller's codepage stays switched to UTF-8. }
      TermDone;
      Halt(0);
    end;
    { The apply half: a column of plain assignments and nothing else.  Every
      one of these globals keeps the comment above its declaration explaining
      WHY it is held rather than acted on - the approvals file may widen a
      mode, the session root is not known yet, the style name may also be in
      a file - and every one of those reasons is still exactly right.  What
      changed is only that the value now arrives from a function a suite can
      call, instead of being written in place by a loop nobody could reach.

      This half is what is still hand-verified: it touches the disk from the
      next block down, so it is not, and cannot be, a pure function. }
    Dir := Cli.Dir;
    AddDirs := Cli.AddDirs;
    Resume := Cli.Resume;
    ContinueFlag := Cli.ContinueFlag;
    WebFlag := Cli.WebFlag;
    PrintMode := Cli.PrintMode;
    PrintPrompt := Cli.PrintPrompt;
    ScriptedRun := Cli.ScriptedRun;
    NoProjectContext := Cli.NoProjectContext;
    ModeWanted := Cli.ModeWanted;
    ModeGiven := Cli.ModeGiven;
    SandboxWanted := Cli.SandboxWanted;
    SandboxGiven := Cli.SandboxGiven;
    StyleWanted := Cli.StyleWanted;
    SessionFileArg := Cli.SessionFileArg;
    StreamInput := Cli.StreamInput;
    DiagMode := Cli.DiagMode;
    DiagOnline := Cli.DiagOnline;
    CiInPath := Cli.CiInPath;
    CiPrPath := Cli.CiPrPath;
    CiOutPath := Cli.CiOutPath;
    CiTrigger := Cli.CiTrigger;
    CiFloor := Cli.CiFloor;
    { The one field that is not an assignment, because uSdk owns the storage.
      The parser accumulated the --append-system-prompt values through
      uSdk.SdkAppendJoin - the same trim, the same blank-line join, the same
      cap measured on the total - so this push cannot fail: the text is
      already under the cap and AppendSystem_ is still empty.  It is checked
      anyway.  A push whose Boolean nobody looks at is precisely how a flag
      comes to be dropped in silence, and the whole point of this flag is that
      a run which half-applied it is a run whose replies cannot be
      explained. }
    if Cli.AppendSystem <> '' then
      if not uSdk.SdkAppendSystemPush(Cli.AppendSystem, Err) then
        FailStart('--append-system-prompt: ' + Err,
          'it adds to the system prompt and can never replace it; put a ' +
          'long standing instruction in CLAUDE.md instead', 2);
    if Dir <> '' then
    begin
      if not DirectoryExists(Dir) then
        FailStart('no such directory: ' + Dir, '', 2);
      SetCurrentDir(Dir);
    end;
    uTools.RootDir := GetCurrentDir;
    { Settings, immediately after the root is known and above everything that
      could consult one, so deny, plugins, mode, sandbox and style all see the
      same values a restart would produce.

      This is ABOVE the print-mode halt, and that is legal for exactly one
      reason: no key in uSettings.SettingDefs can grant anything.  Not a
      permission, not a root, not a sandbox level, not a permission mode, not
      a tool.  The authority split is what buys the load position.  The day a
      granting key is wanted, it does not go in this table; if it somehow
      must, this call does not move - a SECOND load goes down beside
      LoadPermissions, below the halt, where a scripted run cannot inherit it.

      Notes are printed with the deny rules below rather than here, so every
      configuration complaint at startup arrives in one yellow block. }
    uSettings.SettingsLoad(SettingsUserPath, SettingsProjectPath,
      SettingsLocalPath, SettingNotes);
    ApplySettings;
    { Above LoadIgnoreRules, because each root's own .gitignore is read there,
      and above the print-mode halt below, because argv is the human speaking:
      a -p run honours the flag.  What it grants there is read-only in
      practice - -p leaves Ask nil, so every gated tool in an added directory
      denies exactly as it denies in the session root.

      A failure exits rather than continuing with less reach than was asked
      for: a run that quietly starts without a directory it was told to use
      produces a wrong answer instead of an error. }
    for ArgI := 0 to High(AddDirs) do
      if not uTools.AddWorkingDir(AddDirs[ArgI], AddArg, SaveErr) then
        FailStart('--add-dir ' + AddDirs[ArgI] + ': ' + SaveErr, '', 2)
      else
      begin
        if not PrintMode then StartupNote(clGrey, '  + ' + AddArg);
        if SaveErr <> '' then StartupNote(clYellow, '  ' + SaveErr);
      end;
    { Resolved with the same guard the tools use, and only now, because
      --add-dir is what makes  --add-dir %TEMP% --session-file %TEMP%\s.json
      legal.  One notion of where pasclaude may write, not two. }
    if SessionFileArg <> '' then
      if not uTools.ResolveInRoot(SessionFileArg, SessionFileFull, SaveErr) then
        FailStart('--session-file must be inside the session root: ' + SaveErr,
          'use --add-dir to work in another directory', 2);
    uTools.LoadIgnoreRules;
    { Deny rules load here, before the print-mode halt below, where the
      standing approvals deliberately do not: a rule can only ever narrow, so
      a scripted run may inherit one without becoming more permissive than an
      interactive session started the same way.  LoadDenyRules reads only the
      "deny" array of each file - if it ever grew to read a grant key, -p
      would silently start inheriting approvals. }
    uTools.LoadDenyRules(PermissionsPath, uTools.GlobalDenyPath);
    { An unparseable rule is not in force, and the only thing standing between
      that and a user who believes they are protected is this line. }
    BadRules := uTools.BadDenyRules;
    for ArgI := 0 to High(BadRules) do
    begin
      StartupNote(clYellow, '  deny rule not understood, NOT in force: ' +
        BadRules[ArgI] + ' (/deny)');
      { And into the ledger beside the print, so /doctor can report it
        without re-reading deny.json.  Every one of these five sites prints
        exactly once at startup; the ledger is the only thing that lets a
        command typed an hour later still know it happened. }
      uDiag.DiagNote('deny', uDiag.dlWarn,
        'rule not understood, NOT in force: ' + BadRules[ArgI],
        '/deny lists what is in force; fix or remove the rule');
    end;
    { Settings problems, in the same block and the same colour and for the
      same reason: a file the user wrote is not doing what they think, and the
      only thing standing between that and a silent surprise is this loop.
      Never fatal - a project file is attacker-controlled, and halting on one
      would hand a clone a way to stop the program. }
    for ArgI := 0 to High(SettingNotes) do
    begin
      StartupNote(clYellow, '  settings: ' + SettingNotes[ArgI]);
      uDiag.DiagNote('settings', uDiag.dlWarn, SettingNotes[ArgI],
        '/config shows every key, its value and the tier it came from');
    end;
    { Said out loud rather than left to /cost: a repository that doubled the
      size of every tool result, or moved the compaction point, has changed
      what this session costs and the user did not type it. }
    if uSettings.SettingsProjectEconomyNote <> '' then
      StartupNote(clYellow, '  settings: this project sets ' +
        uSettings.SettingsProjectEconomyNote + ' (/config)');
    { Beside LoadIgnoreRules and therefore BEFORE the print-mode halt below,
      on purpose: a scripted run honours an enablement the user already made
      but, having no console, can never create one.  Skills need no enabling
      at all - they are text of the same trust class as CLAUDE.md, which is
      read here unprompted too - so this is only the plugin half. }
    uTools.LoadPluginState(PluginStatePath);
    uTools.RefreshSkills;

    { Beside the deny rules and for the mirror-image reason: a mode from argv
      is the human speaking about this run, and -p halts below without ever
      reaching the second application.  It is applied again after
      LoadPermissions so a loaded grant cannot undo it. }
    ApplyStartupMode;
    { Beside it, and above the print-mode halt for the same reason: a -p run
      is confined exactly as an interactive one is.  It cannot be made looser
      here either - the only thing --sandbox off restores is what shipped
      before this existed. }
    ApplySandbox;
    { And the style, above the halt for the third time with the same argument:
      a -p run never reads the approvals file, so this flag is the only way a
      scripted run can have a style at all.  A name that does not resolve is a
      startup error rather than a silent default - a script that asked for one
      voice and got another would be discovered by reading the output. }
    if StyleWanted <> '' then
      if not uTools.SetOutputStyle(StyleWanted, StyleErr) then
        FailStart('--output-style: ' + StyleErr,
          'default, explanatory, learning, or a file in ' + SessionDir +
          PathDelim + uTools.StylesDirName, 2);
    if PrintMode and (uTools.CurrentPermMode = uTools.pmodeBypass) then
      { On stderr, so a driver reading stdout for JSON is undisturbed and a
        log of the run still records that nothing was asked. }
      WriteLn(StdErr, 'pasclaude: --dangerously-skip-permissions: every tool ' +
        'is approved without asking. Deny rules and the session root still ' +
        'apply; nothing else does.');

    { Above the print-mode halt with the rest of settings, and legal there for
      the same one reason: a model key cannot grant anything.  It cannot widen
      a permission, add a root, lower the sandbox or admit a tool - all it can
      do is change which model answers, and only from the user's own file.
      Before the model name is read below, because that name may BE an alias. }
    ApplyModelSettings;

    { One call for all six sources, in uAuth's documented order: the two
      environment variables, then a stored preference if it names a source
      that is actually live, then pasclaude's own store, Claude Code, Jcode
      and the ant profile.  Same position in startup as the old two-source
      read - above the print-mode halt - because a credential is not a
      project-supplied capability: it is machine-scoped, out of tree, and the
      same class of thing as ANTHROPIC_API_KEY.  Moving it below the halt
      would silently strip a -p run of the credential the user configured. }
    if uAuth.AuthResolve(ActiveAuth) then
      ApiKey := ActiveAuth.Token
    else
    begin
      ApiKey := '';
      { Every source that was probed and why each one had nothing, rather
        than the old two-clause sentence.  With six places to look, "no
        subscription token was usable" would leave the user guessing which
        of them they were supposed to fix. }
      SaveErr := '';
      AuthList := uAuth.AuthList;
      for ArgI := 0 to High(AuthList) do
        if AuthList[ArgI].Why <> '' then
          SaveErr := SaveErr + uAuth.AuthSourceName(AuthList[ArgI].Source) +
            ': ' + AuthList[ArgI].Why + #10;
      { The one place a startup refusal is deliberately weakened, and the
        guard is DiagMode and nothing else - not a settings key, not an
        environment variable, not -p.  A diagnostic run continues with an
        empty key so that "no credential" can be one problem among thirteen
        rather than the exit code; it is safe only because the diag branch
        below ends in Halt and cannot reach the REPL, a turn or a tool.
        --doctor --online is the sole path that then makes a request, and
        it reports the API's own refusal, which is the honest answer. }
      if DiagMode <> dmNone then
        uDiag.DiagNote('credential', uDiag.dlProblem,
          'no usable credential was found in any of the six sources',
          'set ANTHROPIC_API_KEY=sk-ant-..., sign in to Claude Code once, ' +
          'or run pasclaude and type /login')
      else
        FailStart('no usable credential was found',
          SaveErr +
          'set ANTHROPIC_API_KEY=sk-ant-..., sign in to Claude Code once, ' +
          'or run pasclaude and type /login', 2);
    end;
    if not PrintMode then
    begin
      { Near-expiry, said before the first turn rather than discovered
        halfway through one.  Fifteen minutes because that is long enough to
        act on and short enough not to fire on every startup; a source with
        no parseable expiry says nothing at all, which is the honest answer
        when the field's type is another program's business. }
      ExpiryMs := uAuth.AuthExpiresInMs(ActiveAuth);
      if (ExpiryMs >= 0) and (ExpiryMs < 15 * 60 * 1000) then
        EmitCLn(clYellow, Format(
          '  the %s credential expires in %d minutes; renew it in that ' +
          'program before it does', [uAuth.AuthDescribe(ActiveAuth),
          ExpiryMs div 60000]));
    end;
    if not HttpAvailable then
    begin
      { Same relaxation, same single guard, same reason: a machine with no
        winhttp.dll is exactly the machine somebody would type --doctor on,
        and refusing to run there means the check that would name the
        problem never runs. }
      if DiagMode <> dmNone then
        uDiag.DiagNote('winhttp', uDiag.dlProblem,
          'winhttp.dll could not be loaded; no request can be made',
          'check that %SystemRoot%\system32\winhttp.dll exists')
      else
        FailStart('winhttp.dll could not be loaded; no network available.',
          '', 2);
    end;

    ModelName := GetEnvironmentVariable('ANTHROPIC_MODEL');
    { Below the environment variable, deliberately: a variable is set for this
      invocation and a settings file is a standing preference, so the more
      specific statement wins.  A saved session still beats both when /resume
      restores its own model (uAgent.LoadSession) - that is unchanged.  The
      key is user scope only, so nothing in the project tree reaches here: a
      repository that could pick the model would be spending the user's money
      on its own say-so, and could pick a weaker one to review its own code. }
    if Trim(ModelName) = '' then ModelName := uSettings.SettingStr('model');
    { Telemetry initialises here: it needs nothing from the credential and
      must never read one, but it has to exist before the first turn can
      happen in either mode.  ABOVE the print-mode halt, so a -p run's turns
      are counted - and that is legal for exactly one reason, which is that
      all six telemetry keys are scUserOnly.  If anyone ever gives telemetry a
      project tier, this call must move below the halt or a -p run gains an
      outbound channel from a repository. }
    LoadTelemetry;
    { The banner names the source when it is anything other than a plain
      exported API key.  'subscription' is preserved for the two OAuth
      sources because that is what the word means to the user and what the
      banner has always said. }
    case ActiveAuth.Source of
      uAuth.asApiKeyEnv: BannerAuth := '';
      uAuth.asClaudeCode, uAuth.asJcode: BannerAuth := 'subscription';
    else
      BannerAuth := uAuth.AuthDescribe(ActiveAuth);
    end;

    { Hooks, before the agent exists, because SessionStart's output can only
      reach the model through the string Create is handed - TAgent has no
      setter for its system prompt, deliberately, since changing it mid-session
      would throw away the prompt cache on every turn afterwards.

      EVERY unattended mode is excluded, not just print mode: a scripted run
      has nobody to answer the trust question, and deny-by-default means a
      config that cannot be asked about does not run.  There is no override in
      v1 - that is a decision to make with a user in the room, not a default.

      `if not PrintMode` used to be the whole of that, and it was wrong by
      four modes.  --status, --doctor and both --ci verbs are refused -p at
      the argument parser, so they are NOT print mode by construction and ran
      this block: --ci report in the mention workflow runs after checkout,
      with the current directory set to the pull request head, so the tree
      under review supplied .pasclaude\hooks.json and the trust prompt was
      answered by whatever the runner happened to attach to stdin - allow on
      an empty line, deny on EOF, and a hang on a pipe nobody closes.  The CI
      deny floor cannot cover it either: uHooks sits below uTools and no hook
      is ever checked against a rule.  uHooks.HooksAllowed carries the same
      decision into the unit, where it also gates the five other sites that
      fire or display hooks. }
    HookSystemExtra := '';
    uSdk.SdkSystemExtra := @SdkExtra;
    uHooks.HooksAllowed := (not PrintMode) and (DiagMode = dmNone);
    { The same shape as the line above it and a DIFFERENT condition, and the
      difference is the feature rather than an oversight.  Hooks lose every
      unattended mode because a hook executes a command with nobody to answer
      for it.  The project's instruction files lose only the two --ci verbs,
      because binding a project's CLAUDE.md under -p and in the REPL is a
      promise README makes to every scripted user, and prose that still has to
      talk a gated tool past its own prompt is not a command.

      --ci report is the verb that reaches a checkout: it runs after
      actions/checkout, with the current directory set to the pull request
      head, so AGENTS.md, CLAUDE.md and .pasclaude.md - and everything they
      @import - would be read out of the branch under review and assembled
      into this process's system prompt.  No deny rule could have caught it:
      uTools' path: rules are consulted for the model's tool calls and this
      loader is not one.  --ci prepare is gated for symmetry; it runs BEFORE
      the checkout in an empty workspace, so in the template it has no files
      to skip and the notice below never fires for it.

      WHAT THIS DOES NOT DO, said here rather than left to be discovered.
      Neither --ci verb sends anything to a model: RunCi ends in Halt on every
      path, and the prompt built a few lines below is thrown away under both.
      So the --ci half of this gate stops a branch's instructions being READ
      and assembled - it is not what keeps them out of the answer, because the
      answer is not produced here.  In the mention template it comes from the
      step before, an ordinary -p in the same checked-out head, and THAT is
      what the second term is for: --no-project-context, an explicit flag the
      workflow file passes on that step.  A flag and never a mode inferred
      from the prompt text, because the prompt is the one string in the run an
      attacker wrote, and any behaviour keyed on its contents is a behaviour
      the attacker chooses.

      The two terms are combined in uSdk.SdkProjectContextDecide rather than
      spelled out here, and the reason is that this is a program's main block:
      no suite can link it, so the condition that decides whether a checkout
      writes part of the system prompt was the one part of this feature with
      no test at all.  A third reason to suppress belongs inside that function
      too - not as another assignment somewhere below, because "one writer,
      go and read it" is the property that makes this auditable.

      The notice below used to be unconditional on stdout, and the argument
      for that was that --ci refuses --output-format at the argument parser,
      so its stdout is a build log by construction.  That argument does not
      survive the flag: the template's Answer step is
      -p --output-format json > result.json, where one grey line would land in
      front of --ci report's parser and break the posted comment.  So the flag
      branch goes to StdErr, exactly as the --dangerously-skip-permissions
      warning above does and for word-for-word the same reason.  It is named
      first when both hold, because the flag is the thing the operator typed.

      MemoryFileCount is NOT left alone any more, and the flag is why: under
      the two --ci verbs it was unreachable - RunCi halts before
      FillDiagFacts - but --no-project-context reaches the REPL status line,
      where a count of two memories the model never received would be exactly
      the claim that function's own comment promises it cannot make. }
    uSdk.SdkProjectContextAllowed := uSdk.SdkProjectContextDecide(
      NoProjectContext, uArgs.ArgsIsCiVerb(DiagMode));
    if (not uSdk.SdkProjectContextAllowed) and
       (uSdk.SdkProjectContextFiles <> '') then
    begin
      if NoProjectContext then
        { The second clause is CONDITIONAL, and the flag's own shipping
          environment is why.  It exists for CI, where a runner's home
          directory has no .pasclaude\CLAUDE.md in it at all - so the sentence
          "your %USERPROFILE% memory still was" read would be printed into
          every workflow log while SdkUserContext had in fact returned nothing.
          That is exactly the claim MemoryFileCount's own comment forbids: a
          line naming a file the model did not get.  Asked through
          SdkUserContext rather than through a FileExists of the same path
          spelled a second time here, so the notice cannot come to disagree
          with the loader about what counts as present - an unreadable file
          loads as nothing and is reported as nothing. }
        WriteLn(StdErr, 'pasclaude: --no-project-context: ' +
          uSdk.SdkProjectContextFiles + ' in this directory were not read ' +
          'into the system prompt' + UserMemoryClause)
      else
      begin
        EmitCLn(clGrey, '  ci: ' + uSdk.SdkProjectContextFiles +
          ' in this directory were not read by this --ci step');
        EmitCLn(clGrey, '    it asks no model anything; a -p step in the same ' +
          'checkout loads them unless it too passes --no-project-context');
      end;
    end;
    if uHooks.HooksAllowed then
    begin
      uHooks.OnHookNotice := @HookNotice;
      { LoadHooks is now called unconditionally, and that is the wiring change
        this round turns on.  The user's own hooks must load whether or not the
        project's were trusted, and TrustHooks already returns False without
        prompting when there is no project file - so the answer it gives is
        still exactly the answer about the project, passed straight through.
        HooksAllowed still wraps the whole block, so no unattended mode reaches
        either file. }
      uHooks.LoadHooks(TrustHooks, HookNotes);
      if Trim(HookNotes) <> '' then
        EmitC(clYellow, '  ' + StringReplace(Trim(HookNotes), #10, #10'  ',
          [rfReplaceAll]) + #10);
      { Said once, out loud, because it is the file nobody was asked about: a
        hook firing invisibly is the complaint this program's own
        FEATURES-NOT-YET already records, and the scope that skips the prompt
        is the one that most needs a line saying it is there. }
      UserHooks := 0;
      for HookIdx := 0 to uHooks.HookEntryCount - 1 do
        if uHooks.HookScopeAt(HookIdx) = 'user' then Inc(UserHooks);
      if UserHooks > 0 then
        EmitCLn(clGrey, Format('  %d hook(s) from %s (/hooks)',
          [UserHooks, uHooks.UserHooksFilePath]));
      if uHooks.HooksEnabled then
      begin
        HookOut := uHooks.FireHooks(uHooks.HookCall(heSessionStart));
        if HookOut.Blocked then
        begin
          { A SessionStart hook is the one place a block means "do not
            start": there is no turn to refuse and no transcript to keep
            legal, so the honest answer is to say why and stop. }
          NeedNewLine;
          EmitCLn(clRed, '  ' + Trim(HookOut.Text));
          TermDone;
          Halt(2);
        end;
        if Trim(HookOut.Text) <> '' then
          HookSystemExtra := #10#10'Session context follows.'#10 +
            HookOut.Text;
      end;
    end;

    { One call, in uSdk, for the whole prompt: the identity and guidelines,
      then whatever a SessionStart hook contributed, then the project's own
      instruction files.  The hook text sits between them because it is
      session context rather than a standing rule, and the "treat them as
      binding" line has to stay attached to the files it introduces. }
    Agent := TAgent.Create(ApiKey, ModelName, uSdk.SdkFullSystem);
    try
      { Second call, now that the agent exists: this is what picks up
        thinking_budget.  The other two keys were applied at the load point
        because they had to be right before anything could read them. }
      ApplySettings;
      { Consulted only on a 401 and only once per request.  It re-reads the
        sources - it never writes one - so a token Claude Code refreshed on
        disk while this session was running is picked up without a restart,
        instead of the session dying on a credential that was stale for
        thirty seconds. }
      Agent.OnAuthRefresh := @AuthRefreshHook;
      Agent.OnText := @OnText;
      Agent.OnThinking := @OnThinking;
      Agent.OnToolStart := @OnToolStart;
      Agent.OnToolUseBegin := @OnToolUseBegin;
      Agent.OnToolArg := @OnToolArg;
      Agent.OnToolResult := @OnToolResult;
      { The two telemetry seams.  OnRequestDone carries a status, a duration
        and the model and nothing else; OnToolDone hands over a name and an
        error flag, and TelemToolDone ignores the Output parameter entirely -
        that is tool result text. }
      Agent.OnRequestDone := @TelemRequestDone;
      Agent.OnToolDone := @TelemToolDone;
      Agent.OnNotice := @OnNotice;
      Agent.Ask := @AskPermission;
      Agent.ShouldCancel := @UserWantsStop;
      if WebFlag then Agent.WebSearch := True;
      uTerm.CompleteProvider := @Complete;
      { The third fact pushed down into the editor, and the one that closes the
        prompt-idle window: while the user sits at a prompt, uTerm's read now
        wakes every quarter second and calls this, so the background spool cap
        is enforced on the same clock at the prompt as it is everywhere else.
        Every quarter second NOBODY TYPES, precisely - a wake caused by a key
        goes straight to the read - and the bound that buys is stated at the
        tick call in the REPL loop below rather than twice here.
        uTerm is below uTools and has no idea what a background job is; all it
        gets is "there is periodic work", and the default is nil, which means
        do nothing and means the read is byte-for-byte the untimed one this
        program has always had.

        TickBackgroundJobs and emphatically not SweepJobs(True).  A purge from
        a tick could forget a finished job in the window between the model
        being told about it and the model reading it, and - since this can now
        fire from a permission prompt nested inside a running tool call - it
        could also resize the Jobs array under a caller holding an index into
        it.  uTools' own comment on TickBackgroundJobs argues both.

        Set ABOVE the `if PrintMode` below, with the other two push-downs, and
        here that placement is right rather than merely harmless.  The comment
        on EscEscCommand just below frets about being armed in every mode,
        correctly, because a shortcut means something.  A tick means the same
        thing in every mode there is, and the modes that cannot block on a
        console never enter the wait at all - ReadLineCore only waits when
        stdin IS a console, so a -p run off a pipe never reaches it. }
      uTerm.IdleTick := @uTools.TickBackgroundJobs;
      { Escape twice on an already-empty prompt line opens /rewind.  The word
        is pushed DOWN into the editor exactly like the completion provider
        above it: uTerm is below uTools and has no idea what a slash command
        is, so it submits this string as though the user had typed it and the
        REPL's one dispatcher does the rest.

        Set beside the other seam that only makes sense with a console, and
        NOT structurally confined to one: this assignment is ABOVE the
        `if PrintMode` below, so -p, --status, --doctor and both --ci verbs all
        execute it too.  What makes that inert is only that ReadPromptLine has
        exactly one call site and none of those modes reaches it - a property
        of the call graph, not of this line.  Anyone adding a second reader
        that blocks for input, or a scripted path that calls ReadPromptLine,
        inherits an armed shortcut and has to turn it off deliberately.  The
        earlier wording here claimed the -p branch "never reaches this line",
        which is the reverse of the truth and is the sentence a reviewer
        auditing the fail-closed story would have trusted.

        A NAME AND NOT A COMMAND OBJECT, which is the point: this string goes
        through HandleCommand like any other line, so /rewind's own "nothing
        to rewind to yet" and its picker are what a stray double-Escape gets,
        not a second undo path that had to be kept in step with the first. }
      uTerm.EscEscCommand := '/rewind';

      { Print mode: one prompt in, one answer out, exit code says how it
        went.  This is what makes  pasclaude -p "..."  usable from scripts
        and pipes.  No banner, no session save - a script's throwaway
        question should not disturb the directory's saved conversation -
        and no permission prompts: stdin may be a pipe, so asking would
        hang.  Ask stays nil, which is the deny-by-default path; read-only
        tools still work, and a print run that needs an edit approved says
        so in its output rather than stalling. }
      if PrintMode then
      begin
        Agent.Ask := nil;
        { The SDK path branches here, at exactly the point print mode already
          branches: before HistoryLoad, LoadPermissions, the banner and the
          session backup.  That is the cheapest possible proof the interactive
          REPL cannot regress - a REPL session can never enter it.

          With a driver on stdin there is nothing to slurp and nothing to
          require: stdin is the driver's channel, and the first user message
          arrives over it rather than on the command line. }
        if (OutFormat <> uSdk.sfText) and StreamInput then
        begin
          { From the zeroing constructor, never field-by-field on the bare
            local: FPC initialises only a record's managed fields, so every
            Boolean added to TSdkOptions after this line was written would
            otherwise start as whatever was on the stack. }
          SdkOpts := uSdk.SdkDefaultOptions;
          SdkOpts.Format := OutFormat;
          SdkOpts.StreamInput := True;
          SdkOpts.SessionId := uSdk.SdkNewSessionId;
          SdkOpts.SessionFile := SessionFileFull;
          SdkOpts.Resume := Resume;
          { The reported name and the answering channel, decided separately.
            A driver is a permission answerer and nothing more, so it is armed
            only in the two modes where a question can arise: plan refuses
            before the gate, and bypass answers itself. }
          SdkOpts.PermissionMode :=
            uTools.PermModeName(uTools.CurrentPermMode);
          SdkOpts.AskViaDriver :=
            uTools.CurrentPermMode in [uTools.pmodeAsk, uTools.pmodeAcceptEdits];
          SdkCode := uSdk.SdkRun(Agent, SdkOpts, PrintPrompt, Err);
          { Halt skips finally, so the one flush a scripted run gets has to be
            spelled out at every exit rather than left to the block below. }
          uTelem.TelemShutdown;
          TermDone;
          Halt(SdkCode);
        end;
        { A piped stdin becomes context under the prompt, which is how
          type build.log | pasclaude -p "why did this fail?"  works. }
        Piped := '';
        if not StdinIsConsole then
          while not EOF(Input) do
          begin
            ReadLn(Line);
            Piped := Piped + Line + #10;
          end;
        if Trim(PrintPrompt) = '' then
        begin
          { No -p argument: the piped text itself is the prompt. }
          PrintPrompt := Piped;
          Piped := '';
        end;
        if Trim(PrintPrompt) = '' then
        begin
          FailStart('print mode needs a prompt: -p "question" or piped stdin',
            '', 2);
        end;
        if Piped <> '' then
          PrintPrompt := PrintPrompt + #10#10 +
            'Input follows.'#10'---'#10 + Piped;

        if OutFormat <> uSdk.sfText then
        begin
          SdkOpts := uSdk.SdkDefaultOptions;
          SdkOpts.Format := OutFormat;
          SdkOpts.StreamInput := False;
          SdkOpts.SessionId := uSdk.SdkNewSessionId;
          SdkOpts.SessionFile := SessionFileFull;
          SdkOpts.Resume := Resume;
          { No driver, so nobody can be asked and SdkRun leaves Ask nil.  The
            reported name is still the truth about the session: a bypass run
            asks nobody because it needs nobody, which is a different fact
            from having nobody to ask. }
          SdkOpts.AskViaDriver := False;
          if uTools.CurrentPermMode = uTools.pmodeAsk then
            SdkOpts.PermissionMode := 'deny'
          else
            SdkOpts.PermissionMode :=
              uTools.PermModeName(uTools.CurrentPermMode);
          SdkCode := uSdk.SdkRun(Agent, SdkOpts, PrintPrompt, Err);
          { Halt skips finally, so the one flush a scripted run gets has to be
            spelled out at every exit rather than left to the block below. }
          uTelem.TelemShutdown;
          TermDone;
          Halt(SdkCode);
        end;

        { The same policy function the protocol paths use, reported in console
          idiom because this path has a console.  BackupSession is deliberately
          NOT called: the caller named the file, so the caller owns it. }
        if Resume then
          if not uSdk.SdkResumeInto(Agent, SessionFileFull, ResumeMsgs,
               ResumeErr) then
          begin
            NeedNewLine;
            EmitCLn(clRed, 'cannot resume ' + SessionFileFull + ': ' + ResumeErr);
            uTelem.TelemShutdown;
            TermDone;
            Halt(2);
          end
          else
            TelemRebaseline;

        MdReset;
        if Agent.Send(PrintPrompt, Err) then
        begin
          MdFinish;
          uTelem.TelemRecordTurn(Agent.TokensIn, Agent.TokensOut,
            Agent.CacheReadTokens, Agent.CacheWriteTokens,
            Agent.LastRequestModel);
          if SessionFileFull <> '' then
            if not Agent.SaveSession(SessionFileFull, SaveErr) then
            begin
              NeedNewLine;
              EmitCLn(clYellow, '  (session not saved: ' + SaveErr + ')');
              uTelem.TelemShutdown;
              TermDone;
              Halt(1);
            end;
          uTelem.TelemShutdown;
          TermDone;
          Halt(0);
        end
        else
        begin
          MdFinish;
          NeedNewLine;
          EmitCLn(clRed, Err);
          uTelem.TelemShutdown;
          TermDone;
          Halt(1);
        end;
      end;

      { Resuming happens before the banner, because a saved session can carry
        its own model and the banner should report the one actually in use. }
      ResumeErr := '';
      if Resume or ContinueFlag then
      begin
        { The one place the two flags differ, and they differ only in which
          path they hand to the same loader.  Nothing below here knows which
          flag was given except the notice, which names the file for
          --continue because the user did not choose it. }
        if ContinueFlag then ResumeFile := uAgent.NewestSession(uTools.RootDir)
        else ResumeFile := SessionPath(uTools.RootDir);
        if ResumeFile = '' then
          ResumeErr := 'no saved conversation in ' + SessionDir
        else
        begin
          Resumed := Agent.LoadSession(ResumeFile, ResumeErr);
          if Resumed then TelemRebaseline;
        end;
      end;

      { Up-arrow reaching last week's build command is the whole point of
        history; in-memory only, it died with the window. }
      HistoryLoad(HistoryPath);
      { Standing approvals survive restarts.  Print mode skips this: a
        scripted run must not inherit interactive grants, nor write any. }
      LoadPermissions(PermissionsPath);
      { The GitHub client is armed HERE and nowhere else - below the
        print-mode halt, on the interactive path, beside the one other piece
        of state a scripted run must never inherit.  Putting it up beside
        Agent.Ask := @AskPermission would arm it in every -p run, because
        that line is ABOVE the branch that nils Ask, and the whole
        unattended argument would collapse.  GitHubExecOverride stays nil:
        the unit calls uTools.RunShellQuiet itself. }
      if not uArgs.ArgsIsCiVerb(DiagMode) then
        uGitHub.GitHubAllowed := True;
      { Second application: LoadPermissions widens, so without this a flag
        saying "ask me" would be quietly overruled by a grant the user made
        weeks ago and has since forgotten. }
      ApplyStartupMode;
      { And again for the sandbox, because LoadPermissions may have RAISED the
        level to low from a key a previous session's /sandbox low wrote - so
        the scratch has to be prepared before the first child, and an explicit
        --sandbox off has to survive the file. }
      ApplySandbox;
      { And a third time for the style, same pattern: LoadPermissions may have
        applied a name persisted weeks ago, and a name typed on this command
        line is the user speaking about this run.  Validated above the halt
        already, so a failure here can only mean the file moved between the
        two calls; reported rather than fatal, because by now there is a
        session worth keeping. }
      if StyleWanted <> '' then
      begin
        if uTools.SetOutputStyle(StyleWanted, StyleErr) then
          uTools.ClearStyleStartupNote
        else
          EmitCLn(clYellow, '  --output-style: ' + StyleErr);
      end;
      { The persisted style did not apply - it no longer resolves, or it now
        resolves somewhere other than where the user agreed to it.  Yellow and
        named: falling back silently would leave the user reading replies in a
        voice they did not pick and no way to find out why. }
      if uTools.StyleStartupNote <> '' then
      begin
        EmitCLn(clYellow, '  ' + uTools.StyleStartupNote);
        uDiag.DiagNote('output_style', uDiag.dlWarn,
          uTools.StyleStartupNote,
          '/output-style lists the styles that resolve now');
      end;
      { And settings last of the three, which is the whole of its authority
        here: argv is the user speaking about this run, the approvals file is
        the user's persisted answer to /output-style, and settings.json only
        supplies a default when neither of those said anything.  A project may
        set it because a style is prose of the same trust class as CLAUDE.md,
        which a repository already supplies unprompted.  A name that does not
        resolve is a yellow note and never an error - by now there is a
        session worth keeping. }
      if (StyleWanted = '') and (uTools.StyleStartupNote = '') and
         (uTools.OutputStyleName = uTools.DefaultStyleName) and
         (Trim(uSettings.SettingStr('output_style')) <> '') then
      begin
        StyleErr := '';
        if not uTools.SetOutputStyle(Trim(uSettings.SettingStr('output_style')),
             StyleErr) then
          { Cleaned and format-guarded like the rest of the settings notices:
            the name is a string out of a file in the project tree, and this
            is the one place it reaches the console unquoted.  --status and
            --doctor run the whole of startup and reach here, so a JSON run
            would otherwise carry it too. }
          StartupNote(clYellow, '  settings: output_style ' +
            uDiag.DiagClean(uSettings.SettingStr('output_style')) + ': ' +
            uDiag.DiagClean(StyleErr))
        else if uSettings.SettingSource('output_style') <> uSettings.stUser then
          { Named, because the voice the replies are written in is now coming
            out of a file that arrived with the clone. }
          StartupNote(clGrey, '  output style ' +
            uDiag.DiagClean(uTools.OutputStyleName) +
            ' comes from this project''s settings (/config)');
      end;
      { And the residual risk stated out loud on every launch that hits it:
        the project could have created this file after the name was persisted,
        and project wins the precedence.  The source check above turns that
        into a refusal rather than a substitution, so reaching here means the
        user did consent to a project file - naming it is so they can see
        which one is speaking. }
      if (uTools.OutputStylePath <> '') and
         (uTools.OutputStyleSource <> 'user') then
        EmitCLn(clYellow, '  output style ' + uTools.OutputStyleName +
          ' comes from ' + uTools.OutputStylePath);

      { --append-system-prompt announces itself, in the same yellow the style
        notices use and for the same reason: text is being added to the most
        trusted position in every request of this run, and a session where the
        model is following an instruction nobody on screen can see is the
        failure this line exists to prevent.  The byte count and not the text:
        the text is on the command line the user just typed, they can scroll
        up, and four kilobytes of somebody's prose replayed into the banner
        would push the rest of it off the screen. }
      if uSdk.SdkAppendSystem <> '' then
        { StartupNote and not EmitCLn: --status and --doctor run the whole of
          startup and reach this line, and one sentence of prose on a stdout
          somebody is parsing as JSON is a broken protocol. }
        StartupNote(clYellow, Format('  --append-system-prompt: %d bytes ' +
          'added to the system prompt', [Length(uSdk.SdkAppendSystem)]));

      { After LoadPermissions, so an approval already given suppresses the
        prompt, and after the print-mode Halt above, which is what makes a
        scripted run structurally unable to be the thing that first executes a
        repository's code - print mode never reaches here at all, and would
        arrive with a nil Ask and deny everything if it did.  That is still
        true of BOTH files: LoadMcpConfigAll reads the user's mcp.json as well
        as the project's .mcp.json, and print mode reaches neither.

        LoadMcpConfigAll and not LoadMcpConfig, which is the project-only
        loader the suites drive.  The user's servers are loaded first and are
        approved without the spawn prompt, because they name programs the user
        themselves chose; the per-call permission gate is unchanged for them. }
      if uTools.LoadMcpConfigAll(McpErr) then
      begin
        { Parsed, but NOT approved and NOT connected under --status or
          --doctor.  Approving a spawn is a permission answer, and a health
          check must never be a way to obtain one; connecting would also
          mean a command called "doctor" started programs from a cloned
          repository.  The report still names every configured server and
          whether its program resolves on PATH, which is the whole of what
          it could honestly say anyway. }
        if DiagMode = dmNone then
        begin
          uTools.McpApproveAll(@AskPermission, @McpNotice);
          uTools.McpConnectApproved(@McpNotice);
        end;
      end;
      if McpErr <> '' then
      begin
        EmitCLn(clYellow, '  ' + McpErr);
        uDiag.DiagNote('mcp', uDiag.dlWarn, McpErr,
          '/mcp shows each server; the file is ' + uTools.McpConfigPath);
      end;

      { A driver asked for JSON on stdout, so nothing else may go there: one
        line of prose is indistinguishable from a protocol line that went
        wrong.  Only reachable from --status/--doctor, which are the only
        modes that get this far with a non-text format. }
      { And the same argument in a different key for --ci: its stdout is a
        build log, nobody is reading it for reassurance, and an amber logo
        between two YAML steps is noise.  It says one grey line instead. }
      if (OutFormat = uSdk.sfText) and
         not uArgs.ArgsIsCiVerb(DiagMode) then ShowBanner;

      { Keybindings, from %USERPROFILE% and nowhere else - below the banner
        because any note it prints is about a file the user wrote and belongs
        with the other startup remarks, not above the logo.  Pointedly not
        beside LoadPermissions: that file records what the project was
        allowed to do, this one grants nothing at all. }
      LoadKeys;

      { The honest disclosure for the half of this feature that asks nothing:
        text out of the repository is now in the model's catalogue, and here
        is the command that shows what it says. }
      SkillList := uTools.SkillCatalogue;
      if (OutFormat = uSdk.sfText) and (Length(SkillList) > 0) then
      begin
        SkillNames := '';
        for ArgI := 0 to High(SkillList) do
        begin
          if ArgI >= 6 then
          begin
            SkillNames := SkillNames + ', ...';
            Break;
          end;
          if SkillNames <> '' then SkillNames := SkillNames + ', ';
          SkillNames := SkillNames + SkillList[ArgI].Name;
        end;
        EmitCLn(clGrey, Format('  skills: %d available (%s) - /skills to read them',
          [Length(SkillList), SkillNames]));
      end;
      { Repeated every launch until /plugins is run, which is the point: a
        bundle somebody else wrote is sitting in this directory disabled, and
        the notice stops when the user has looked, not when they have
        enabled. }
      NewPlugins := uTools.UnseenPlugins;
      if (OutFormat = uSdk.sfText) and (Length(NewPlugins) > 0) then
      begin
        SkillNames := '';
        for ArgI := 0 to High(NewPlugins) do
        begin
          if SkillNames <> '' then SkillNames := SkillNames + ', ';
          SkillNames := SkillNames + NewPlugins[ArgI];
        end;
        EmitCLn(clGrey, Format('  plugins: %d new (%s) - disabled. read %s%s%s,' +
          ' then /plugins enable <name>',
          [Length(NewPlugins), SkillNames, SessionDir, PathDelim,
           uTools.PluginsDirName]));
      end;

      if Resume or ContinueFlag then
      begin
        if Resumed and ContinueFlag then
          { Named, because --continue chose the file and the user did not.  A
            "resumed 41 messages" with no file behind it is the notice a user
            has to take on faith, and the whole risk of the flag is that it
            picked the wrong conversation. }
          EmitCLn(clGreen, Format('  resumed %s: %d messages (%d turns)',
            [ExtractFileName(ResumeFile), Agent.MessageCount, Agent.TurnCount]))
        else if Resumed then
          EmitCLn(clGreen, Format('  resumed %d messages (%d turns)',
            [Agent.MessageCount, Agent.TurnCount]))
        else
          EmitCLn(clYellow, '  starting fresh: ' + ResumeErr);
        { --continue is NOT the exemption --resume is, and treating the two
          flags as one here destroyed conversations.  --resume loads
          session.json itself, so the file the first save overwrites is the
          file already in memory and a copy of it would be a copy of what is
          about to be written back - that skip is right.  --continue loads
          WHICHEVER SAVE IS NEWEST, which may be a /save copy, and loads
          nothing at all when the newest one will not parse.  In both of those
          the first turn writes over the session.json nobody read, and the
          branch below - the one that takes the copy - was never reached
          because it sits in the else of `Resume or ContinueFlag`.

          Reproduced before this was written: a directory holding a valid
          session.json and a newer unparseable save, run with --continue,
          printed "starting fresh" and left no session.prev.json anywhere; the
          same directory with no flag printed the notice and did create one.

          So the test is not which flag was typed but whether the file about to
          be overwritten is the file that was loaded.  Compared as text because
          both paths are built by the same two lines of uAgent from the same
          root, so they are the same string or they are different files. }
        if (DiagMode = dmNone) and
           (CompareText(ResumeFile, SessionPath(uTools.RootDir)) <> 0) and
           FileExists(SessionPath(uTools.RootDir)) then
        begin
          if BackupSession(SessionPath(uTools.RootDir), SaveErr) then
            EmitCLn(clGrey, '  the conversation already saved here was not the ' +
              'one loaded; a copy is kept as session.prev.json')
          else
            EmitCLn(clYellow, '  a different saved conversation is here and ' +
              'could not be copied aside: ' + SaveErr);
        end;
        EmitLn;
      end
      else if (DiagMode = dmNone) and
              FileExists(SessionPath(uTools.RootDir)) then
      begin
        { A session was left here and this run is not continuing it, so the
          first save would overwrite it.  It is copied aside first: the user
          who wanted it can still get it back, and the one who did not loses
          nothing but a file.

          Skipped under --status/--doctor, and that is not tidiness: this is
          the only mutation left in the startup path, and a command whose
          name promises diagnosis must not rewrite session.prev.json merely
          by being run. }
        if BackupSession(SessionPath(uTools.RootDir), SaveErr) then
          EmitCLn(clGrey,
            '  a saved conversation exists here; /resume loads it' +
            ' (a copy is kept as session.prev.json)')
        else
          EmitCLn(clYellow, '  a saved conversation exists here but could not ' +
            'be copied aside: ' + SaveErr);
        EmitLn;
      end;

      { --status / --doctor emit here and halt, in place of the REPL.  They
        deliberately run the WHOLE of startup first, including the
        below-the-halt loads (LoadPermissions, LoadKeys, the MCP parse),
        because a status that cannot see the approvals file or the configured
        servers is a lie.  That is affordable only because the mode cannot
        run a turn: Halt is the last statement on every path out of here. }
      { The two CI verbs halt from here too, and from the same position for
        the same reason: --ci prepare's whole job is to assert that the deny
        floor loaded above is really in force, and a check that ran before
        LoadDenyRules would be asserting nothing. }
      if uArgs.ArgsIsCiVerb(DiagMode) then RunCi;
      if DiagMode <> dmNone then
      begin
        FillDiagFacts;
        if DiagMode = dmStatus then
        begin
          StatusReport := uDiag.DiagBuildStatus(Agent);
          case OutFormat of
            uSdk.sfText:
              begin
                DiagLines := uDiag.DiagStatusText(StatusReport);
                for ArgI := 0 to High(DiagLines) do
                  EmitCLn(clGrey, DiagLines[ArgI]);
              end;
            uSdk.sfStreamJson:
              uSdk.SdkEmit(uSdk.SdkDiagnosticLine('status',
                uDiag.DiagStatusJson(StatusReport)));
          else
            uSdk.SdkEmit(uDiag.DiagStatusJson(StatusReport));
          end;
          SdkCode := 0;
        end
        else
        begin
          DoctorReport := uDiag.DiagBuildDoctor(Agent, DiagOnline);
          case OutFormat of
            uSdk.sfText:
              begin
                DiagLines := uDiag.DiagDoctorText(DoctorReport);
                for ArgI := 0 to High(DiagLines) do
                  EmitCLn(clGrey, DiagLines[ArgI]);
              end;
            uSdk.sfStreamJson:
              uSdk.SdkEmit(uSdk.SdkDiagnosticLine('doctor',
                uDiag.DiagDoctorJson(DoctorReport)));
          else
            uSdk.SdkEmit(uDiag.DiagDoctorJson(DoctorReport));
          end;
          { 1 for a problem, 0 for anything else, so
            "pasclaude --doctor || setup" works in a batch file.  A warning
            does not fail the run and neither does a skipped check: an exit
            code that fired on a check nobody asked to run would be
            unusable in exactly the script that wants it. }
          if uDiag.DiagWorstLevel(DoctorReport) = uDiag.dlProblem then
            SdkCode := 1
          else
            SdkCode := 0;
        end;
        { Halt skips finally, so the shutdown is spelled out here as it is
          at every other Halt in this file. }
        uTelem.TelemShutdown;
        uSandbox.SandboxShutdown;
        TermDone;
        Halt(SdkCode);
      end;

      repeat
        { The one call in the program that consults the binding table.  Every
          other prompt - the permission answer above all - reads through
          ReadLineEdit, which passes the empty profile.

          The status block is refreshed here, immediately before the read, so
          what it says is what was true when the user looked at it. }
        { The last moment before the read below, and it stays here for the
          reason it always had: it runs BEFORE RefreshStatus, so the job count
          the status block prints is the count after any kill rather than one
          that was true a moment ago.  This call is what makes the FIRST frame
          honest.

          What this comment used to add - that nothing ticks once the read
          begins, so a job left running through lunch is bounded by nothing -
          is no longer true.  The read now wakes every uTerm.IdleWaitMs and
          calls the same tick through uTerm.IdleTick, wired above, so the
          prompt is bounded by the same clock as a streaming reply.  On a wake
          the KEYBOARD caused it calls nothing: that loop breaks straight into
          the read, because a sweep that has to kill a job waits two seconds
          per job for it to die and no user should meet that between two
          characters of a line they are typing.  What the idle tick
          deliberately does NOT do is repaint the status block: a job killed
          during the wait leaves a stale count on screen until the next
          prompt, and redrawing it four times a second is exactly the flicker
          that would have been worse than the bug. }
        uTools.TickBackgroundJobs;
        { The style file behind the session changed and the new contents could
          not be used.  Drained HERE, before the status block is drawn and
          before the read blocks, because that is the last moment the user is
          looking at the screen rather than at their editor - and read-and-
          cleared, so a file left broken says this once instead of once a
          turn.  What was working is still in force; the line says so. }
        StyleErr := uTools.TakeStyleReloadNote;
        if StyleErr <> '' then EmitCLn(clYellow, '  ' + StyleErr);
        RefreshStatus;
        if not ReadPromptLine(ModePrompt, Line) then Break;
        Line := Trim(Line);
        if Line = '' then Continue;
        { Written now rather than at exit, for the same reason the session
          is: the run worth remembering is the one that ended in a crash or
          a closed window.  ForceDirectories because the first prompt can
          come before the first save creates .pasclaude. }
        ForceDirectories(ExtractFilePath(HistoryPath));
        HistorySave(HistoryPath);

        if not HandleCommand(Line, Handled) then Break;
        if Handled then Continue;

        { A leading # is a note for the project memory, Claude Code's
          shortcut: "# prefer edit_file" lands in CLAUDE.md, not in the
          conversation. }
        if (Length(Line) > 1) and (Line[1] = '#') and (Line[2] = ' ') then
        begin
          RememberNote(Trim(Copy(Line, 2, MaxInt)));
          Continue;
        end;

        { A slash word nobody built in may be a custom command: the contents
          of .pasclaude\commands\<name>.md become the prompt, with $ARGUMENTS
          substituted.  Checked after the built-ins so none can be shadowed. }
        if Line[1] = '/' then
        begin
          Line := uSdk.SdkExpandCustomCommand(Line, Handled);
          if not Handled then
          begin
            EmitCLn(clRed, '  unknown command (no .pasclaude\commands match either)');
            Continue;
          end;
        end;

        AtLineStart := True;
        MdReset;
        { @path mentions become attachments before the prompt is sent, so the
          model starts with the file instead of spending a round reading it. }
        if Pos('@', Line) > 0 then
        begin
          Line := ExpandMentions(Line, Agent, MentionNotes);
          if MentionNotes <> '' then
          begin
            EmitC(clGrey, '  ' + StringReplace(Trim(MentionNotes), #10,
              #10'  ', [rfReplaceAll]));
            EmitLn;
          end;
        end;
        { UserPromptSubmit fires here, after the mentions are expanded and
          before anything touches the transcript.  Blocking costs nothing to
          undo: Send has not run, so FMessages is untouched and the transcript
          is trivially still legal. }
        if uHooks.HooksEnabled then
        begin
          HookCallRec := uHooks.HookCall(heUserPrompt);
          HookCallRec.Prompt := Line;
          HookOut := uHooks.FireHooks(HookCallRec);
          if HookOut.Blocked then
          begin
            NeedNewLine;
            if Trim(HookOut.Text) = '' then
              EmitCLn(clYellow, '  blocked by a UserPromptSubmit hook')
            else
              EmitCLn(clYellow, '  ' + Trim(HookOut.Text));
            EmitLn;
            Continue;
          end;
          if Trim(HookOut.Text) <> '' then
            Line := Line + #10#10 + HookOut.Text;
        end;
        { A session that runs long enough will eventually exceed the context
          window, and the failure mode is the whole turn being rejected.
          Trimming first costs the oldest exchanges instead.  Two triggers:
          the byte count (a proxy, available before the first request) and
          the token count the API actually reported, which is the measured
          truth and catches token-dense transcripts the byte guess misses. }
        { Images go before either trim, and the ordering is load-bearing.
          Base64 is re-sent in full every turn, so one screenshot puts
          TranscriptBytes permanently over the byte threshold - and the byte
          trim cannot help, because the image sits in the tail it is trying to
          keep.  Left alone that branch would fire every single turn and drop
          nothing.  Evicting the stale images is what brings the transcript
          back under the line and makes the trim mean something again. }
        if Agent.TranscriptBytes > CompactKeepBytes then
        begin
          Dropped := Agent.EvictImages(2);
          if Dropped > 0 then
            EmitCLn(clGrey, Format(
              '  (dropped %d older image(s) to save context)', [Dropped]));
        end;
        if Agent.ContextTokens > CompactTokens then
        begin
          { The token trigger fires at a measured size, which is also the
            point where the old turns are worth a request to keep: the
            summary preserves their substance where the byte trim forgets
            it.  A failed summary falls back to the trim - a session that
            cannot summarize must still not outgrow the window. }
          EmitCLn(clGrey, '  (context is large; summarizing older turns)');
          AtLineStart := True;
          MdReset;
          if Agent.CompactWithSummary(Err) then
          begin
            DropCheckpoints;
            MdFinish;
            AtLineStart := True;
            NeedNewLine;
            EmitCLn(clGrey, Format('  (compacted to a summary, %d bytes)',
              [Agent.TranscriptBytes]));
          end
          else
          begin
            MdFinish;
            AtLineStart := True;
            NeedNewLine;
            EmitCLn(clYellow, '  (could not summarize: ' + Err + ')');
            Dropped := Agent.Compact(CompactKeepBytes);
            if Dropped > 0 then
            begin
              DropCheckpoints;
              EmitCLn(clGrey, Format('  (compacted: dropped %d older messages)',
                [Dropped]));
            end;
          end;
        end
        else if Agent.TranscriptBytes > CompactKeepBytes then
        begin
          Dropped := Agent.Compact(CompactKeepBytes);
          if Dropped > 0 then
          begin
            DropCheckpoints;
            EmitCLn(clGrey, Format('  (compacted: dropped %d older messages)',
              [Dropped]));
          end;
        end;
        { The Stop hook can say the turn is not finished, and its output then
          becomes the next prompt.  Exactly one continuation per user turn:
          StopActive caps it, and the same flag is in the hook's payload so a
          hook can tell it is on its second look and stop asking.  A turn that
          FAILED is never re-driven - a hook must not be able to turn a
          transport error into a loop. }
        StopActive := False;
        repeat
          Again := False;
          { The moment before the turn runs is what /rewind returns to. }
          RecordCheckpoint(Line);
          { Refused here rather than sent with an empty key.  /logout can
            leave a session with nothing to authenticate with, and one local
            sentence beats a 401 from the API - which would arrive again from
            the subagent and again from /model, three different confusing
            errors for one condition. }
          if NoCredential then
          begin
            NeedNewLine;
            EmitCLn(clRed, '  no credential: /login stores one, or set ' +
              'ANTHROPIC_API_KEY and restart');
            Break;
          end;
          TurnOk := Agent.Send(Line, Err);
          if not TurnOk then
          begin
            NeedNewLine;
            EmitCLn(clRed, '  ' + Err);
            { A bare 'HTTP 401 - authentication_error' is the thing this
              feature exists to replace: it says a credential was rejected
              without saying WHICH of six it was, where it came from, or
              whether it has since expired.  The token itself is never in
              this line - only the source, the file and the remedy. }
            if (Pos('HTTP 401', Err) > 0) or
               (Pos('authentication_error', Err) > 0) then
              EmitCLn(clYellow, '  ' + uAuth.AuthDiagnose401(ActiveAuth));
          end;
          { The last line of the reply usually has no trailing newline and is
            still held by the renderer. }
          MdFinish;
          AtLineStart := True;

          if TurnOk and uHooks.HooksEnabled and not StopActive then
          begin
            HookCallRec := uHooks.HookCall(heStop);
            HookCallRec.StopActive := StopActive;
            HookOut := uHooks.FireHooks(HookCallRec);
            if HookOut.Blocked and (Trim(HookOut.Text) <> '') then
            begin
              StopActive := True;
              Line := HookOut.Text;
              Again := True;
              NeedNewLine;
              EmitCLn(clGrey, '  (a Stop hook asked for one more turn)');
              MdReset;
            end;
          end;
        until not Again;
        { A plan is prose, so there is nothing an approval could be bound to
          and nothing is auto-approved on the way out - an approval that
          claims to cover "the plan" and actually covers everything is a lie
          with a friendly label.  What the user gets instead is the reminder
          that the two ways out are one command each. }
        if TurnOk and uTools.PlanMode then
        begin
          NeedNewLine;
          EmitCLn(clGrey, '  (plan mode: nothing was changed.  /mode ' +
            'accept-edits to do the work without prompts, or /mode ask to ' +
            'be asked about each step)');
        end;
        { Saved after every turn rather than at exit, because the session
          worth keeping is usually the one that ended in a crash or a closed
          window.  A failure to save is reported once and does not interrupt
          the conversation. }
        if not Agent.SaveSession(SessionPath(uTools.RootDir), SaveErr) then
          if not SaveWarned then
          begin
            SaveWarned := True;
            NeedNewLine;
            EmitCLn(clYellow, '  (session not being saved: ' + SaveErr + ')');
          end;
        { Approvals persist too, but never from a /yolo session: the blanket
          flags it sets are indistinguishable from real per-answer grants. }
        if not YoloSession then
          SavePermissions(PermissionsPath);
        { The flush point.  Here and nowhere else: the answer is already on
          screen and the next prompt has not been drawn, so the only thing a
          slow collector can delay is the user's next keystroke - and only
          once every telemetry.interval_turns turns.  Cumulative totals in,
          deltas kept inside uTelem. }
        uTelem.TelemRecordTurn(Agent.TokensIn, Agent.TokensOut,
          Agent.CacheReadTokens, Agent.CacheWriteTokens,
          Agent.LastRequestModel);
        if uTelem.TelemDueForFlush then FlushTelemetry;
        NeedNewLine;
        EmitLn;
      until False;
    finally
      Agent.Free;
    end;
  finally
    { The last flush, before the console is torn down so a note about a
      failure still has somewhere to go.  A startup refusal deliberately does
      NOT come through here: FailStart sends nothing, because a run that never
      reached a turn has nothing worth reporting and a collector should not
      learn that the program was started at all. }
    uTelem.TelemShutdown;
    { Before TermDone, so anything a dying child prints on its way out lands
      while the console is still in a sane state.  uTools' finalization
      repeats this as the backstop for the paths that skip a finally. }
    uTools.ClearJobs;
    { Same reasoning one unit down: an MCP server outliving the program that
      launched it is a process the user did not start by hand and cannot name.
      uMcp's finalization repeats this for the paths that skip a finally. }
    uMcp.McpShutdownAll;
    { And the same shape for the one file this program leaves outside the
      project: the "before" side of the last /ide diff holds project text, so
      it goes with the session that asked for it rather than waiting a day
      for a sweep.  uIde's finalization repeats this for the paths that skip
      a finally, which is most of the ones that matter here. }
    uIde.IdeDropScratch;
    { The cached low-integrity token is a process handle like any other, and
      the cached environment block is a string; neither should outlive the
      program.  After the two kills above, because a job object closing is
      what reaps the children and this does not. }
    uSandbox.SandboxShutdown;
    TermDone;
  end;
end.
