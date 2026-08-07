{ pasclaude - a terminal coding agent in the spirit of Claude Code.

  Reads a prompt, streams the model's reply, lets it call tools against the
  working directory, and asks before anything is changed.

  Usage:  pasclaude [directory]
  The API key comes from ANTHROPIC_API_KEY, the model from ANTHROPIC_MODEL. }
program pasclaude;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, DateUtils, uTerm, uJson, uHttp, uMcp, uHooks, uTools,
  uAgent, uSdk;

const
  Version = '0.1';
  { A transcript larger than this is trimmed before the next turn.  Roughly
    100k characters, which is a fraction of the context window but well past
    the point where old file dumps are still earning their place. }
  CompactKeepBytes = 100 * 1024;
  { When the API reports the prompt at more than this many tokens, the
    transcript is trimmed even if its byte count looks fine.  Bytes are a
    proxy; this is the measured thing the context window actually fills
    with, and 150k leaves headroom under a 200k window for the reply. }
  CompactTokens = 150000;
  { The /think default: enough for real multi-step reasoning, small enough
    that a casual "on" does not silently multiply the bill. }
  DefaultThinkBudget = 8192;

var
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
  SlashCommands: array[0..25] of string = (
    '/help', '/clear', '/compact', '/deny', '/diff', '/hooks', '/jobs', '/mcp',
    '/memory', '/init', '/mode', '/plan', '/rewind', '/sessions', '/skills',
    '/plugins', '/think', '/web',
    '/resume', '/save', '/cwd', '/model', '/yolo', '/cost', '/exit', '/quit');

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

procedure ShowHelp;
begin
  EmitCLn(clBright, 'Commands');
  EmitCLn(clGrey,   '  /help          this list');
  EmitCLn(clGrey,   '  /clear         forget the conversation, here and on disk');
  EmitCLn(clGrey,   '  /compact       drop the oldest turns, keep the recent ones');
  EmitCLn(clGrey,   '  /compact full  replace the transcript with a model-written summary');
  EmitCLn(clGrey,   '  /diff          list the files this session has changed');
  EmitCLn(clGrey,   '  /hooks         hooks this project defines; /hooks off disables them');
  EmitCLn(clGrey,   '  /jobs          background commands still running');
  EmitCLn(clGrey,   '  /mcp           MCP servers: status, restart, refresh');
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
  EmitCLn(clGrey,   '  /cwd           show the session root');
  EmitCLn(clGrey,   '  /model [name]  pick a model from a list, or set one by name');
  EmitCLn(clGrey,   '  /deny          rules nothing can override; add <rule>, remove <n>');
  EmitCLn(clGrey,   '  /mode [name]   ask | plan | accept-edits; no argument shows the state');
  EmitCLn(clGrey,   '  /plan          shorthand for /mode plan: read and investigate only');
  EmitCLn(clGrey,   '  /yolo          approve every tool for this session (bypass)');
  EmitCLn(clGrey,   '  /cost          tokens used so far');
  EmitCLn(clGrey,   '  /exit          quit (Ctrl+C also works)');
  EmitLn;
  EmitCLn(clGrey,   '  Esc during a reply stops it.');
  EmitCLn(clGrey,   '  A file in .pasclaude\commands\ is a slash command; one in');
  EmitCLn(clGrey,   '  .pasclaude\agents\ is a subagent type the task tool can ask for;');
  EmitCLn(clGrey,   '  .pasclaude\skills\<name>\SKILL.md is a skill the model can read.');
  EmitCLn(clGrey,   '  A directory in .pasclaude\plugins\ can carry all three, once you');
  EmitCLn(clGrey,   '  enable it by name. A skill added mid-session appears after /skills.');
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
end;

{ Where the prompt history lives, beside the session. }
function HistoryPath: string;
begin
  Result := IncludeTrailingPathDelimiter(uTools.RootDir) + SessionDir +
    PathDelim + 'history.txt';
end;

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
  bash prefixes.  /yolo deliberately does not answer this question. }
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
    EmitCLn(clGrey, '  hooks are off for this session (/hooks shows them)');
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

{ A Claude subscription can stand in for an API key.  Two programs on this
  machine may hold its OAuth token: Claude Code (~\.claude\.credentials.json)
  and Jcode (~\.jcode\auth.json).  Whichever has a live token wins; both
  files are read-only here - refreshing is their owner's job, and this
  program must never write into another program's state.  Returns '' when
  no usable token exists anywhere, with Why saying what was found. }

function NowUnixMs: Int64;
begin
  Result := Round((LocalTimeToUniversal(Now) - EncodeDate(1970, 1, 1)) * MSecsPerDay);
end;

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

{ Claude Code's file: {"claudeAiOauth":{"accessToken","expiresAt",...}}. }
function TokenFromClaudeCode(out Why: string): string;
var
  Text: string;
  Root, OAuth: TJson;
  ExpiresMs: Int64;
begin
  Result := '';
  Why := 'no Claude Code credentials';
  if not ReadFileText(IncludeTrailingPathDelimiter(
    GetEnvironmentVariable('USERPROFILE')) + '.claude' + PathDelim +
    '.credentials.json', Text) then Exit;
  Root := JsonParse(Text);
  if Root = nil then
  begin
    Why := 'Claude Code credentials are not valid JSON';
    Exit;
  end;
  try
    OAuth := Root.Find('claudeAiOauth');
    if OAuth = nil then
    begin
      Why := 'no OAuth entry in the Claude Code credentials';
      Exit;
    end;
    ExpiresMs := Round(OAuth.Num('expiresAt', 0));
    if (ExpiresMs > 0) and (NowUnixMs > ExpiresMs) then
    begin
      Why := 'the Claude Code token has expired';
      Exit;
    end;
    Result := OAuth.Str('accessToken');
    if Result = '' then Why := 'the Claude Code credentials hold no token';
  finally
    Root.Free;
  end;
end;

{ Jcode's file: {"anthropic_accounts":[{"access","expires",...}]}. }
function TokenFromJcode(out Why: string): string;
var
  Text: string;
  Root, Accts, A: TJson;
  I: Integer;
  ExpiresMs: Int64;
begin
  Result := '';
  Why := 'no Jcode credentials';
  if not ReadFileText(IncludeTrailingPathDelimiter(
    GetEnvironmentVariable('USERPROFILE')) + '.jcode' + PathDelim +
    'auth.json', Text) then Exit;
  Root := JsonParse(Text);
  if Root = nil then
  begin
    Why := 'Jcode credentials are not valid JSON';
    Exit;
  end;
  try
    Accts := Root.Find('anthropic_accounts');
    if (Accts = nil) or (Accts.Kind <> jkArr) or (Accts.Count = 0) then
    begin
      Why := 'no accounts in the Jcode credentials';
      Exit;
    end;
    { The first account with a live token; expired ones are skipped rather
      than reported, since a later account may still work. }
    for I := 0 to Accts.Count - 1 do
    begin
      A := Accts.Item(I);
      if A.Str('access') = '' then Continue;
      ExpiresMs := Round(A.Num('expires', 0));
      if (ExpiresMs > 0) and (NowUnixMs > ExpiresMs) then Continue;
      Exit(A.Str('access'));
    end;
    Why := 'every Jcode token has expired';
  finally
    Root.Free;
  end;
end;

function SubscriptionToken(out Why: string): string;
var
  WhyCc, WhyJc: string;
begin
  Result := TokenFromClaudeCode(WhyCc);
  if Result <> '' then
  begin
    Why := '';
    Exit;
  end;
  Result := TokenFromJcode(WhyJc);
  if Result <> '' then
  begin
    Why := '';
    Exit;
  end;
  Why := WhyCc + '; ' + WhyJc;
end;


{ What this session changed.  git diff --stat is the richer answer when
  there is a repository - it also sees compiler output and hand edits - so
  the session's own list leads and the stat follows when available. }
procedure ShowDiff;
var
  Changed: TStringArray;
  I, Code: Integer;
  Stat: string;
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

  Stat := uTools.RunShellQuiet('git diff --stat HEAD', Code);
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
    uHooks.ClearHooks;
    EmitCLn(clGrey, '  hooks are off for this session');
    Exit;
  end;
  if not uHooks.HooksConfigured then
  begin
    EmitCLn(clGrey, '  no hooks (put them in ' + SessionDir + PathDelim +
      uHooks.HooksFileName + ')');
    Exit;
  end;
  EmitCLn(clGrey, '  ' + uHooks.HooksFilePath);
  if uHooks.HooksEnabled then
  begin
    EmitCLn(clGreen, '  enabled, fingerprint ' + uHooks.HookFingerprint);
    Sum := uHooks.HookSummary;
    if Sum <> '' then EmitC(clGrey, Sum);
  end
  else
    EmitCLn(clYellow, '  not running (not trusted this session, or /hooks off)');
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
    EmitCLn(clGrey, '  no MCP servers configured (.mcp.json in the session root)');
    Exit;
  end;
  for I := 0 to High(Rows) do
  begin
    Status := Field(Rows[I], 1);
    if Status = 'connected' then Col := clGreen
    else if (Status = 'dead') or (Status = 'denied') or
            (Status = 'failed to start') then Col := clRed
    else Col := clGrey;
    EmitC(clBright, '  ' + Field(Rows[I], 0) + '  ');
    EmitC(Col, Status);
    EmitCLn(clGrey, Format('  %s tools, %s skipped',
      [Field(Rows[I], 2), Field(Rows[I], 3)]));
    EmitCLn(clGrey, '      ' + Field(Rows[I], 4));
    if Field(Rows[I], 5) <> '' then
      EmitCLn(clGrey, '      ' + Field(Rows[I], 5));
  end;
end;

{ A bare /model lists what the key can actually use and takes a number.
  Typing a model id from memory is guesswork about a namespace that changes
  under you - the retired-default 404 was exactly that - so the list comes
  from the API, which cannot be stale. }
procedure PickModel;
var
  Models: TModelList;
  Err, Line: string;
  I, Pick: Integer;
  Mark: string;
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

  for I := 0 to High(Models) do
  begin
    if Models[I].Id = Agent.Model then Mark := ' (current)' else Mark := '';
    EmitC(clGrey, Format('  %2d  ', [I + 1]));
    EmitC(clBright, Models[I].DisplayName);
    EmitCLn(clGrey, '  ' + Models[I].Id + Mark);
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
  if (Pick < 1) or (Pick > Length(Models)) then
  begin
    EmitCLn(clRed, '  not a listed number: ' + Line);
    Exit;
  end;
  Agent.Model := Models[Pick - 1].Id;
  EmitCLn(clGrey, '  model set to ' + Agent.Model);
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
      { Sessions only: the permissions file also lives here. }
      if (R.Name = 'session.json') or (R.Name = 'session.prev.json') or
         (Pos('.session.json', R.Name) > 0) then
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
  EmitCLn(clYellow, '  shell commands are not undone, and files over 400 KB were not snapshotted');

  { The checkpoints past the target are gone with the turns they marked. }
  SetLength(CheckTurns, Pick - 1);
  SetLength(CheckCounts, Pick - 1);
  SetLength(CheckPrompts, Pick - 1);

  { The saved session must match, or a crash right now resurrects what was
    just rewound. }
  if not Agent.SaveSession(SessionPath(uTools.RootDir), Err) then
    EmitCLn(clYellow, '  (the rewound session could not be saved: ' + Err + ')');
end;

{ The logo: logo.png's </> mark as ASCII art, blue like the source image,
  with the wordmark beside it.  Three lines tall - enough to read as the
  mark, small enough that the banner is still a banner. }
procedure ShowBanner;
var
  Auth: string;
begin
  EmitLn;
  EmitC(clBlue,  '    /    ');  EmitC(clBright, '/');  EmitC(clBlue, '  \');
  EmitLn;
  EmitC(clBlue,  '   <    ');  EmitC(clBright, '/');  EmitC(clBlue, '    >');
  EmitC(clBright, '     pasclaude');  EmitC(clGrey, ' v' + Version);
  EmitLn;
  EmitC(clBlue,  '    \  ');  EmitC(clBright, '/');  EmitC(clBlue, '    /');
  EmitC(clGrey, '      a coding agent in Free Pascal');
  EmitLn;
  EmitLn;
  Auth := Agent.Model;
  if BannerAuth <> '' then Auth := Auth + ' (' + BannerAuth + ')';
  EmitCLn(clGrey, '  ' + Auth);
  EmitCLn(clGrey, '  ' + uTools.RootDir);
  { Only when there are any: a user in a stricter state than they believe is a
    smaller problem than one in a looser state, but a refusal nobody can
    explain is still a bug report. }
  { The mode, whenever it is not the plain one - including the case that has
    existed all along and was invisible, a previous session's "always" loading
    as accept-edits before anything has been typed. }
  if uTools.PermModeBanner <> '' then
    EmitCLn(clYellow, '  ' + uTools.PermModeBanner);
  if uTools.DenyRulesInForce then
    EmitCLn(clGrey, Format('  %d deny rules in force (/deny)',
      [uTools.DenyRuleCount]));
  EmitCLn(clGrey, '  /help for commands, /exit to quit, Esc stops a reply');
  EmitLn;
end;

{ Returns False when the command asked to quit. }
function HandleCommand(const Line: string; out Handled: Boolean): Boolean;
var
  Cmd, Arg: string;
  Sp: Integer;
  Dropped: Integer;
  Err: string;
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
    EmitCLn(clGrey, '  ' + uTools.RootDir)
  else if Cmd = '/diff' then
  begin
    { Approvals happen one edit at a time; this is the aggregated answer.
      When the directory is a git repository the real diff stat is the
      better source - it sees hand edits too - so it is preferred and the
      session's own list is the fallback. }
    ShowDiff;
  end
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
      EmitCLn(clGrey, Format('  resumed %d messages (%d turns)',
        [Agent.MessageCount, Agent.TurnCount]));
    end
    else
      EmitCLn(clRed, '  could not resume: ' + Err);
  end
  else if Cmd = '/model' then
  begin
    if Arg <> '' then
    begin
      Agent.Model := Arg;
      EmitCLn(clGrey, '  model set to ' + Arg);
    end
    else
      PickModel;
  end
  else if Cmd = '/skills' then
    ShowSkills
  else if Cmd = '/plugins' then
    ShowPlugins(Arg)
  else if Cmd = '/hooks' then
    ShowHooks(Arg)
  else if Cmd = '/mcp' then
    ShowMcp(Arg)
  else if Cmd = '/deny' then
    ShowDeny(Arg)
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
  end
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
  { Halt skips the finally block, so the console has to be put back here or
    the caller's codepage stays switched to UTF-8. }
  TermDone;
  Halt(Code);
end;

var
  ApiKey, ModelName, Line, Err, Dir, SaveErr, Arg, ResumeErr: string;
  MentionNotes: string;
  SkillNames: string;
  SkillList: uTools.TSkillInfoArray;
  NewPlugins: TStringArray;
  BadRules: TStringArray;
  Handled: Boolean;
  Dropped: Integer;
  Resume: Boolean = False;
  Resumed: Boolean = False;
  SaveWarned: Boolean = False;
  UsingSubscription: Boolean = False;
  ArgI: Integer;
  PrintPrompt: string = '';
  PrintMode: Boolean = False;
  WebFlag: Boolean = False;
  Piped: string;
  McpErr: string = '';
  HookNotes: string = '';
  HookOut: THookOutcome;
  HookCallRec: THookCall;
  SdkOpts: uSdk.TSdkOptions;
  SdkCode: Integer;
  SkipNext: Boolean = False;
  { The mode asked for on the command line, held rather than applied: it has
    to beat a grant loaded from the approvals file, and that file is read much
    later.  ModeGiven distinguishes "the user asked for ask" from "nobody
    said", which are different answers once allow_edits is on disk. }
  ModeWanted: uTools.TPermMode = uTools.pmodeAsk;
  ModeGiven: Boolean = False;
  { Recorded separately from ModeWanted, which only one of them can win, so
    the two can be seen to contradict each other whichever order they arrive
    in. }
  PlanFlag: Boolean = False;
  BypassFlag: Boolean = False;
  StopActive: Boolean = False;
  Again: Boolean = False;
  TurnOk: Boolean = False;

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

begin
  TermInit;
  try
    Dir := '';
    SkipNext := False;
    for ArgI := 1 to ParamCount do
    begin
      Arg := ParamStr(ArgI);
      { The previous flag consumed this argument as its value.  A latch rather
        than a backwards look at ParamStr(ArgI - 1), because there are now
        three flags that take a value and asking "was the one before me any of
        them" gets longer and wronger with each. }
      if SkipNext then
      begin
        SkipNext := False;
        Continue;
      end;
      if (Arg = '--resume') or (Arg = '-r') then
        Resume := True
      else if Arg = '--web' then
        { Print mode leaves Ask nil, so nothing there can be approved
          interactively; without a flag a -p run could never search. }
        WebFlag := True
      else if (Arg = '-p') or (Arg = '--print') then
      begin
        PrintMode := True;
        { A leading '-' means the next token is another flag, not this one's
          value.  Taking it unconditionally made every flag after -p unusable
          in the order --help showed: "-p --output-format json" sent
          '--output-format' to the model as the question and then died on
          'json' as a directory name, and "-p --web" quietly asked the model
          about the string '--web' with the web never enabled.  A prompt that
          genuinely starts with a dash is what -- style quoting is for, and is
          worth far less than flags that work in the documented order. }
        if (ArgI < ParamCount) and (Copy(ParamStr(ArgI + 1), 1, 1) <> '-') then
        begin
          PrintPrompt := ParamStr(ArgI + 1);
          SkipNext := True;
        end;
      end
      else if Arg = '--permission-mode' then
      begin
        if ArgI >= ParamCount then
          FailStart('--permission-mode needs a value: ask, plan or accept-edits',
            '', 2);
        if not uTools.PermModeParse(ParamStr(ArgI + 1), ModeWanted) then
        begin
          { Named explicitly, because a user who typed 'bypass' knows what
            they wanted and the only thing worth telling them is how it is
            spelled here.  It is not an alias: the long form is the whole
            defence against the mode arriving in a script by accident. }
          if LowerCase(ParamStr(ArgI + 1)) = 'bypass' then
            FailStart('bypass is spelled --dangerously-skip-permissions',
              'and it means it: nothing is asked about at all', 2)
          else
            FailStart('unknown permission mode: ' + ParamStr(ArgI + 1),
              'ask, plan or accept-edits', 2);
        end;
        ModeGiven := True;
        PlanFlag := PlanFlag or (ModeWanted = uTools.pmodePlan);
        SkipNext := True;
      end
      else if Arg = '--dangerously-skip-permissions' then
      begin
        ModeWanted := uTools.pmodeBypass;
        ModeGiven := True;
        BypassFlag := True;
      end
      else if Arg = '--output-format' then
      begin
        if ArgI >= ParamCount then
          FailStart('--output-format needs a value: text, json or stream-json',
            '', 2);
        if not uSdk.SdkParseFormat(ParamStr(ArgI + 1), OutFormat) then
          FailStart('unknown output format: ' + ParamStr(ArgI + 1),
            'text, json or stream-json', 2);
        SkipNext := True;
      end
      else if Arg = '--input-format' then
      begin
        if ArgI >= ParamCount then
          FailStart('--input-format needs a value: text or stream-json', '', 2);
        if ParamStr(ArgI + 1) = 'text' then
          StreamInput := False
        else if ParamStr(ArgI + 1) = 'stream-json' then
          StreamInput := True
        else
          FailStart('unknown input format: ' + ParamStr(ArgI + 1),
            'text or stream-json', 2);
        SkipNext := True;
      end
      else if (Arg = '--help') or (Arg = '-h') or (Arg = '/?') then
      begin
        EmitCLn(clBright, 'pasclaude [directory] [--resume] [--web] [-p "prompt"]');
        EmitCLn(clGrey, '  --resume  continue the conversation saved in that directory');
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
        EmitCLn(clGrey, '  --dangerously-skip-permissions');
        EmitCLn(clGrey, '            approve everything, asking nothing, for this run only.');
        EmitCLn(clGrey, '            Nothing is persisted.  Deny rules, the session root and');
        EmitCLn(clGrey, '            the subagent read-only list still apply; nothing else does.');
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
      end
      else if Copy(Arg, 1, 1) = '-' then
        FailStart('unknown option: ' + Arg, '', 2)
      else
        Dir := Arg;
    end;
    { The formats only mean anything on the one-shot path.  Refusing rather
      than ignoring, because a driver that mistyped its invocation would
      otherwise sit waiting for a protocol nobody is speaking. }
    if not PrintMode then
    begin
      if OutFormat <> uSdk.sfText then
        FailStart('--output-format needs -p', '', 2);
      if StreamInput then
        FailStart('--input-format needs -p', '', 2);
    end;
    if StreamInput and (OutFormat <> uSdk.sfStreamJson) then
      FailStart('--input-format stream-json needs --output-format stream-json',
        'a driver that sends messages has to be able to read the answers', 2);
    { A mode that cannot work under -p is a startup error rather than a quiet
      downgrade: a script that asked to stop being prompted and was silently
      given the prompting mode would fail later, in the middle of the work,
      with a refusal that looks like a bug. }
    if PrintMode and not uTools.PermModeReachableUnderPrint(ModeWanted,
      PrintMode and StreamInput) then
      FailStart('--permission-mode ' + uTools.PermModeName(ModeWanted) +
        ' needs somebody to accept: -p has nobody',
        'attach a driver with --input-format stream-json, or say' +
        ' --dangerously-skip-permissions and mean it', 2);
    { Contradictory rather than ordered.  Either precedence would be a guess
      about which flag the user meant, and both guesses are dangerous: one
      silently plans nothing, the other silently approves everything. }
    if PlanFlag and BypassFlag then
      FailStart('--permission-mode plan and --dangerously-skip-permissions '
        + 'contradict each other', 'pick one', 2);
    if Dir <> '' then
    begin
      if not DirectoryExists(Dir) then
        FailStart('no such directory: ' + Dir, '', 2);
      SetCurrentDir(Dir);
    end;
    uTools.RootDir := GetCurrentDir;
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
      EmitCLn(clYellow, '  deny rule not understood, NOT in force: ' +
        BadRules[ArgI] + ' (/deny)');
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
    if PrintMode and (uTools.CurrentPermMode = uTools.pmodeBypass) then
      { On stderr, so a driver reading stdout for JSON is undisturbed and a
        log of the run still records that nothing was asked. }
      WriteLn(StdErr, 'pasclaude: --dangerously-skip-permissions: every tool ' +
        'is approved without asking. Deny rules and the session root still ' +
        'apply; nothing else does.');

    ApiKey := GetEnvironmentVariable('ANTHROPIC_API_KEY');
    UsingSubscription := False;
    if Trim(ApiKey) = '' then
    begin
      { No key in the environment; a Claude subscription can stand in.
        The explicit key wins when both exist, because setting a variable
        is a deliberate act and reading another program's token is not. }
      ApiKey := SubscriptionToken(SaveErr);
      if Trim(ApiKey) <> '' then
        UsingSubscription := True
      else
      begin
        FailStart('ANTHROPIC_API_KEY is not set, and no subscription token was usable',
          '(' + SaveErr + ')'#10 +
          'set ANTHROPIC_API_KEY=sk-ant-..., or sign in to Claude Code once', 2);
      end;
    end;
    if not HttpAvailable then
    begin
      FailStart('winhttp.dll could not be loaded; no network available.', '', 2);
    end;

    ModelName := GetEnvironmentVariable('ANTHROPIC_MODEL');
    if UsingSubscription then BannerAuth := 'subscription';

    { Hooks, before the agent exists, because SessionStart's output can only
      reach the model through the string Create is handed - TAgent has no
      setter for its system prompt, deliberately, since changing it mid-session
      would throw away the prompt cache on every turn afterwards.

      Print mode is excluded outright rather than by a flag it could be talked
      out of: a scripted run has nobody to answer the trust question, and
      deny-by-default means a config that cannot be asked about does not run.
      There is no override in v1 - that is a decision to make with a user in
      the room, not a default. }
    HookSystemExtra := '';
    uSdk.SdkSystemExtra := @SdkExtra;
    if not PrintMode then
    begin
      uHooks.OnHookNotice := @HookNotice;
      if TrustHooks then
      begin
        uHooks.LoadHooks(True, HookNotes);
        if Trim(HookNotes) <> '' then
          EmitC(clYellow, '  ' + StringReplace(Trim(HookNotes), #10, #10'  ',
            [rfReplaceAll]) + #10);
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
    end;

    { One call, in uSdk, for the whole prompt: the identity and guidelines,
      then whatever a SessionStart hook contributed, then the project's own
      instruction files.  The hook text sits between them because it is
      session context rather than a standing rule, and the "treat them as
      binding" line has to stay attached to the files it introduces. }
    Agent := TAgent.Create(ApiKey, ModelName, uSdk.SdkFullSystem);
    try
      Agent.OnText := @OnText;
      Agent.OnThinking := @OnThinking;
      Agent.OnToolStart := @OnToolStart;
      Agent.OnToolUseBegin := @OnToolUseBegin;
      Agent.OnToolArg := @OnToolArg;
      Agent.OnToolResult := @OnToolResult;
      Agent.OnNotice := @OnNotice;
      Agent.Ask := @AskPermission;
      Agent.ShouldCancel := @UserWantsStop;
      if WebFlag then Agent.WebSearch := True;
      uTerm.CompleteProvider := @Complete;

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
          SdkOpts.Format := OutFormat;
          SdkOpts.StreamInput := True;
          SdkOpts.SessionId := uSdk.SdkNewSessionId;
          { The reported name and the answering channel, decided separately.
            A driver is a permission answerer and nothing more, so it is armed
            only in the two modes where a question can arise: plan refuses
            before the gate, and bypass answers itself. }
          SdkOpts.PermissionMode :=
            uTools.PermModeName(uTools.CurrentPermMode);
          SdkOpts.AskViaDriver :=
            uTools.CurrentPermMode in [uTools.pmodeAsk, uTools.pmodeAcceptEdits];
          SdkCode := uSdk.SdkRun(Agent, SdkOpts, PrintPrompt, Err);
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
          SdkOpts.Format := OutFormat;
          SdkOpts.StreamInput := False;
          SdkOpts.SessionId := uSdk.SdkNewSessionId;
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
          TermDone;
          Halt(SdkCode);
        end;

        MdReset;
        if Agent.Send(PrintPrompt, Err) then
        begin
          MdFinish;
          TermDone;
          Halt(0);
        end
        else
        begin
          MdFinish;
          NeedNewLine;
          EmitCLn(clRed, Err);
          TermDone;
          Halt(1);
        end;
      end;

      { Resuming happens before the banner, because a saved session can carry
        its own model and the banner should report the one actually in use. }
      ResumeErr := '';
      if Resume then
        Resumed := Agent.LoadSession(SessionPath(uTools.RootDir), ResumeErr);

      { Up-arrow reaching last week's build command is the whole point of
        history; in-memory only, it died with the window. }
      HistoryLoad(HistoryPath);
      { Standing approvals survive restarts.  Print mode skips this: a
        scripted run must not inherit interactive grants, nor write any. }
      LoadPermissions(PermissionsPath);
      { Second application: LoadPermissions widens, so without this a flag
        saying "ask me" would be quietly overruled by a grant the user made
        weeks ago and has since forgotten. }
      ApplyStartupMode;

      { After LoadPermissions, so an approval already given suppresses the
        prompt, and after the print-mode Halt above, which is what makes a
        scripted run structurally unable to be the thing that first executes a
        repository's code - print mode never reaches here at all, and would
        arrive with a nil Ask and deny everything if it did. }
      if uTools.LoadMcpConfig(uTools.McpConfigPath, McpErr) then
      begin
        uTools.McpApproveAll(@AskPermission, @McpNotice);
        uTools.McpConnectApproved(@McpNotice);
      end;
      if McpErr <> '' then EmitCLn(clYellow, '  ' + McpErr);

      ShowBanner;

      { The honest disclosure for the half of this feature that asks nothing:
        text out of the repository is now in the model's catalogue, and here
        is the command that shows what it says. }
      SkillList := uTools.SkillCatalogue;
      if Length(SkillList) > 0 then
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
      if Length(NewPlugins) > 0 then
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

      if Resume then
      begin
        if Resumed then
          EmitCLn(clGreen, Format('  resumed %d messages (%d turns)',
            [Agent.MessageCount, Agent.TurnCount]))
        else
          EmitCLn(clYellow, '  starting fresh: ' + ResumeErr);
        EmitLn;
      end
      else if FileExists(SessionPath(uTools.RootDir)) then
      begin
        { A session was left here and this run is not continuing it, so the
          first save would overwrite it.  It is copied aside first: the user
          who wanted it can still get it back, and the one who did not loses
          nothing but a file. }
        if BackupSession(SessionPath(uTools.RootDir), SaveErr) then
          EmitCLn(clGrey,
            '  a saved conversation exists here; /resume loads it' +
            ' (a copy is kept as session.prev.json)')
        else
          EmitCLn(clYellow, '  a saved conversation exists here but could not ' +
            'be copied aside: ' + SaveErr);
        EmitLn;
      end;

      repeat
        if not ReadLineEdit(ModePrompt, Line) then Break;
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
          Line := ExpandMentions(Line, MentionNotes);
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
          TurnOk := Agent.Send(Line, Err);
          if not TurnOk then
          begin
            NeedNewLine;
            EmitCLn(clRed, '  ' + Err);
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
        NeedNewLine;
        EmitLn;
      until False;
    finally
      Agent.Free;
    end;
  finally
    { Before TermDone, so anything a dying child prints on its way out lands
      while the console is still in a sane state.  uTools' finalization
      repeats this as the backstop for the paths that skip a finally. }
    uTools.ClearJobs;
    { Same reasoning one unit down: an MCP server outliving the program that
      launched it is a process the user did not start by hand and cannot name.
      uMcp's finalization repeats this for the paths that skip a finally. }
    uMcp.McpShutdownAll;
    TermDone;
  end;
end.
