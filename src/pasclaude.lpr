{ pasclaude - a terminal coding agent in the spirit of Claude Code.

  Reads a prompt, streams the model's reply, lets it call tools against the
  working directory, and asks before anything is changed.

  Usage:  pasclaude [directory]
  The API key comes from ANTHROPIC_API_KEY, the model from ANTHROPIC_MODEL. }
program pasclaude;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, DateUtils, uTerm, uJson, uHttp, uTools, uAgent;

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
  { What the banner says about how the session authenticates; '' for a
    plain API key, which is the unremarkable case. }
  BannerAuth: string = '';
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
begin
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
  SlashCommands: array[0..11] of string = (
    '/help', '/clear', '/compact', '/diff', '/think', '/resume', '/save',
    '/cwd', '/model', '/yolo', '/cost', '/exit');

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

{ One quiet git call at startup.  Knowing the branch and whether the tree is
  dirty saves the model its most common first tool call, and mentioning git at
  all tells it commits are welcome.  A directory that is not a repository
  contributes nothing rather than an error. }
function GitContext: string;
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
begin
  Result := '';
  Head := uTools.RunShellQuiet('git rev-parse --abbrev-ref HEAD', Code);
  if Code <> 0 then Exit;
  Head := OneLine(Head);
  if Head = '' then Exit;

  Stat := uTools.RunShellQuiet('git status --porcelain', Code);
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

function SystemPrompt: string;
var
  GitInfo: string;
begin
  GitInfo := GitContext;
  Result :=
    'You are pasclaude, a terminal coding assistant working inside a user''s ' +
    'project directory on Windows.' + #10#10 +
    'Session root: ' + uTools.RootDir + #10#10 +
    GitInfo +
    'Guidelines:' + #10 +
    '- Investigate before you act: read the relevant files rather than ' +
    'guessing at their contents.' + #10 +
    '- Prefer edit_file over write_file when changing an existing file.' + #10 +
    '- Shell commands run through cmd.exe, so use Windows syntax.' + #10 +
    '- After changing code, build or test it if there is an obvious way to ' +
    'do so, and fix what you broke.' + #10 +
    '- Keep replies short. The user is reading a terminal, not a report. ' +
    'Explain what you did, not what you are about to do.' + #10 +
    '- Write, edit and shell commands need the user''s approval, so batch ' +
    'related changes rather than asking many times for trivia.';
end;

{ Project instructions, if the repository ships any.  This is how a project
  tells the agent about its own conventions. }
function ProjectContext: string;
var
  Names: array[0..2] of string = ('AGENTS.md', 'CLAUDE.md', '.pasclaude.md');
  I: Integer;
  Path: string;
  L: TStringList;
begin
  Result := '';
  for I := 0 to High(Names) do
  begin
    Path := IncludeTrailingPathDelimiter(uTools.RootDir) + Names[I];
    if not FileExists(Path) then Continue;
    L := TStringList.Create;
    try
      try
        L.LoadFromFile(Path);
        Result := Result + #10#10 + '--- ' + Names[I] + ' ---' + #10 + L.Text;
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

{ ------------------------------------------------------------------ shell -- }

procedure ShowHelp;
begin
  EmitCLn(clBright, 'Commands');
  EmitCLn(clGrey,   '  /help          this list');
  EmitCLn(clGrey,   '  /clear         forget the conversation, here and on disk');
  EmitCLn(clGrey,   '  /compact       drop the oldest turns, keep the recent ones');
  EmitCLn(clGrey,   '  /compact full  replace the transcript with a model-written summary');
  EmitCLn(clGrey,   '  /diff          list the files this session has changed');
  EmitCLn(clGrey,   '  /think [n]     extended thinking: on, off, or a token budget');
  EmitCLn(clGrey,   '  /resume        reload the saved conversation');
  EmitCLn(clGrey,   '  /save          write the conversation now');
  EmitCLn(clGrey,   '  /cwd           show the session root');
  EmitCLn(clGrey,   '  /model [name]  show or change the model');
  EmitCLn(clGrey,   '  /yolo          approve every tool for this session');
  EmitCLn(clGrey,   '  /cost          tokens used so far');
  EmitCLn(clGrey,   '  /exit          quit (Ctrl+C also works)');
  EmitLn;
  EmitCLn(clGrey,   '  Esc during a reply stops it.');
end;

{ Where the prompt history lives, beside the session. }
function HistoryPath: string;
begin
  Result := IncludeTrailingPathDelimiter(uTools.RootDir) + SessionDir +
    PathDelim + 'history.txt';
end;

{ A Claude subscription can stand in for an API key: Claude Code stores its
  OAuth token in ~\.claude\.credentials.json, and the messages API accepts
  it as a Bearer.  Read-only - refreshing the token is Claude Code's job,
  and this program must never write into another program's state.  Returns
  '' when there is no usable token, with Why saying what was found. }
function SubscriptionToken(out Why: string): string;
var
  Path, Text: string;
  F: TFileStream;
  Root, OAuth: TJson;
  ExpiresMs, NowMs: Int64;
begin
  Result := '';
  Why := '';
  Path := IncludeTrailingPathDelimiter(GetEnvironmentVariable('USERPROFILE')) +
    '.claude' + PathDelim + '.credentials.json';
  if not FileExists(Path) then
  begin
    Why := 'no Claude Code credentials found';
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
      Why := 'credentials unreadable: ' + E.Message;
      Exit;
    end;
  end;
  Root := JsonParse(Text);
  if Root = nil then
  begin
    Why := 'credentials are not valid JSON';
    Exit;
  end;
  try
    OAuth := Root.Find('claudeAiOauth');
    if OAuth = nil then
    begin
      Why := 'no OAuth entry in the credentials';
      Exit;
    end;
    { An expired token would fail every request with a 401; saying so up
      front beats a session that mysteriously cannot talk.  Refreshing it is
      one "claude" run away. }
    ExpiresMs := Round(OAuth.Num('expiresAt', 0));
    NowMs := Round((LocalTimeToUniversal(Now) - EncodeDate(1970, 1, 1)) * MSecsPerDay);
    if (ExpiresMs > 0) and (NowMs > ExpiresMs) then
    begin
      Why := 'the subscription token has expired; run claude once to refresh it';
      Exit;
    end;
    Result := OAuth.Str('accessToken');
    if Result = '' then
      Why := 'the credentials carry no access token';
  finally
    Root.Free;
  end;
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

procedure ShowBanner;
begin
  EmitCLn(clCyan, Format('pasclaude %s', [Version]));
  EmitCLn(clGrey, '  ' + uTools.RootDir);
  if BannerAuth <> '' then
    EmitCLn(clGrey, '  ' + Agent.Model + ' (' + BannerAuth + ')')
  else
    EmitCLn(clGrey, '  ' + Agent.Model);
  EmitCLn(clGrey, '  /help for commands, /exit to quit');
  EmitCLn(clGrey, '  Esc stops a reply in progress');
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
  else if Cmd = '/save' then
  begin
    if Agent.SaveSession(SessionPath(uTools.RootDir), Err) then
      EmitCLn(clGrey, Format('  saved %d messages', [Agent.MessageCount]))
    else
      EmitCLn(clRed, '  could not save: ' + Err);
  end
  else if Cmd = '/resume' then
  begin
    if Agent.LoadSession(SessionPath(uTools.RootDir), Err) then
      EmitCLn(clGrey, Format('  resumed %d messages (%d turns)',
        [Agent.MessageCount, Agent.TurnCount]))
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
      EmitCLn(clGrey, '  ' + Agent.Model);
  end
  else if Cmd = '/yolo' then
  begin
    uTools.AllowAllEdits := True;
    uTools.AllowAllBash := True;
    EmitCLn(clYellow, '  every tool is now approved for this session');
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
    EmitCLn(clRed, '  unknown command: ' + Cmd);
end;

{ ------------------------------------------------------------------- main -- }

var
  ApiKey, ModelName, Line, Err, Dir, SaveErr, Arg, ResumeErr: string;
  MentionNotes: string;
  Handled: Boolean;
  Dropped: Integer;
  Resume: Boolean = False;
  Resumed: Boolean = False;
  SaveWarned: Boolean = False;
  UsingSubscription: Boolean = False;
  ArgI: Integer;

begin
  TermInit;
  try
    Dir := '';
    for ArgI := 1 to ParamCount do
    begin
      Arg := ParamStr(ArgI);
      if (Arg = '--resume') or (Arg = '-r') then
        Resume := True
      else if (Arg = '--help') or (Arg = '-h') or (Arg = '/?') then
      begin
        EmitCLn(clBright, 'pasclaude [directory] [--resume]');
        EmitCLn(clGrey, '  --resume  continue the conversation saved in that directory');
        { Halt skips the finally block, so the console has to be put back
          here or the caller's codepage stays switched to UTF-8. }
        TermDone;
        Halt(0);
      end
      else if Copy(Arg, 1, 1) = '-' then
      begin
        EmitCLn(clRed, 'unknown option: ' + Arg);
        TermDone;
        Halt(2);
      end
      else
        Dir := Arg;
    end;
    if Dir <> '' then
    begin
      if not DirectoryExists(Dir) then
      begin
        EmitCLn(clRed, 'no such directory: ' + Dir);
        TermDone;
        Halt(2);
      end;
      SetCurrentDir(Dir);
    end;
    uTools.RootDir := GetCurrentDir;
    uTools.LoadIgnoreRules;

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
        EmitCLn(clRed, 'ANTHROPIC_API_KEY is not set, and no subscription token was usable');
        EmitCLn(clGrey, '  (' + SaveErr + ')');
        EmitCLn(clGrey, '  set ANTHROPIC_API_KEY=sk-ant-..., or sign in to Claude Code once');
        TermDone;
        Halt(2);
      end;
    end;
    if not HttpAvailable then
    begin
      EmitCLn(clRed, 'winhttp.dll could not be loaded; no network available.');
      TermDone;
      Halt(2);
    end;

    ModelName := GetEnvironmentVariable('ANTHROPIC_MODEL');
    if UsingSubscription then BannerAuth := 'subscription';
    Agent := TAgent.Create(ApiKey, ModelName, SystemPrompt + ProjectContext);
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
      uTerm.CompleteProvider := @Complete;

      { Resuming happens before the banner, because a saved session can carry
        its own model and the banner should report the one actually in use. }
      ResumeErr := '';
      if Resume then
        Resumed := Agent.LoadSession(SessionPath(uTools.RootDir), ResumeErr);

      { Up-arrow reaching last week's build command is the whole point of
        history; in-memory only, it died with the window. }
      HistoryLoad(HistoryPath);

      ShowBanner;

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
        if not ReadLineEdit('> ', Line) then Break;
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
              EmitCLn(clGrey, Format('  (compacted: dropped %d older messages)',
                [Dropped]));
          end;
        end
        else if Agent.TranscriptBytes > CompactKeepBytes then
        begin
          Dropped := Agent.Compact(CompactKeepBytes);
          if Dropped > 0 then
            EmitCLn(clGrey, Format('  (compacted: dropped %d older messages)',
              [Dropped]));
        end;
        if not Agent.Send(Line, Err) then
        begin
          NeedNewLine;
          EmitCLn(clRed, '  ' + Err);
        end;
        { The last line of the reply usually has no trailing newline and is
          still held by the renderer. }
        MdFinish;
        AtLineStart := True;
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
        NeedNewLine;
        EmitLn;
      until False;
    finally
      Agent.Free;
    end;
  finally
    TermDone;
  end;
end.
