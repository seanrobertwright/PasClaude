{ pasclaude - a terminal coding agent in the spirit of Claude Code.

  Reads a prompt, streams the model's reply, lets it call tools against the
  working directory, and asks before anything is changed.

  Usage:  pasclaude [directory]
  The API key comes from ANTHROPIC_API_KEY, the model from ANTHROPIC_MODEL. }
program pasclaude;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, uTerm, uJson, uHttp, uTools, uAgent;

const
  Version = '0.1';
  { A transcript larger than this is trimmed before the next turn.  Roughly
    100k characters, which is a fraction of the context window but well past
    the point where old file dumps are still earning their place. }
  CompactKeepBytes = 100 * 1024;

var
  Agent: TAgent;
  AtLineStart: Boolean = True;

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
  Emit(S);
  NoteWritten(S);
end;

procedure OnThinking(const S: string);
begin
  EmitC(clGrey, S);
  NoteWritten(S);
end;

procedure OnToolStart(const Name, Detail: string);
begin
  NeedNewLine;
  EmitC(clMagenta, '  * ');
  EmitCLn(clBright, Detail);
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

{ Esc during a reply abandons it.  The key is drained here rather than left
  in the buffer, where it would otherwise clear the next prompt line. }
function UserWantsStop: Boolean;
begin
  Result := EscPressed;
end;

{ ------------------------------------------------------------ permissions -- }

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

function SystemPrompt: string;
begin
  Result :=
    'You are pasclaude, a terminal coding assistant working inside a user''s ' +
    'project directory on Windows.' + #10#10 +
    'Session root: ' + uTools.RootDir + #10#10 +
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
  EmitCLn(clGrey,   '  /clear         forget the conversation so far');
  EmitCLn(clGrey,   '  /compact       drop the oldest turns, keep the recent ones');
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

procedure ShowBanner;
begin
  EmitCLn(clCyan, Format('pasclaude %s', [Version]));
  EmitCLn(clGrey, '  ' + uTools.RootDir);
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
    EmitCLn(clGrey, '  conversation cleared');
  end
  else if Cmd = '/compact' then
  begin
    Dropped := Agent.Compact(CompactKeepBytes);
    if Dropped = 0 then
      EmitCLn(clGrey, Format('  nothing to compact (%d messages, %d bytes)',
        [Agent.MessageCount, Agent.TranscriptBytes]))
    else
      EmitCLn(clGrey, Format('  dropped %d older messages, %d left (%d bytes)',
        [Dropped, Agent.MessageCount, Agent.TranscriptBytes]));
  end
  else if Cmd = '/cwd' then
    EmitCLn(clGrey, '  ' + uTools.RootDir)
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
    EmitCLn(clGrey, Format('  %d turns, %d input tokens, %d output tokens',
      [Agent.TurnCount, Agent.TokensIn, Agent.TokensOut]))
  else
    EmitCLn(clRed, '  unknown command: ' + Cmd);
end;

{ ------------------------------------------------------------------- main -- }

var
  ApiKey, ModelName, Line, Err, Dir, SaveErr, Arg, ResumeErr: string;
  Handled: Boolean;
  Dropped: Integer;
  Resume: Boolean = False;
  Resumed: Boolean = False;
  SaveWarned: Boolean = False;
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

    ApiKey := GetEnvironmentVariable('ANTHROPIC_API_KEY');
    if Trim(ApiKey) = '' then
    begin
      EmitCLn(clRed, 'ANTHROPIC_API_KEY is not set.');
      EmitCLn(clGrey, '  set ANTHROPIC_API_KEY=sk-ant-...');
      TermDone;
      Halt(2);
    end;
    if not HttpAvailable then
    begin
      EmitCLn(clRed, 'winhttp.dll could not be loaded; no network available.');
      TermDone;
      Halt(2);
    end;

    ModelName := GetEnvironmentVariable('ANTHROPIC_MODEL');
    Agent := TAgent.Create(ApiKey, ModelName, SystemPrompt + ProjectContext);
    try
      Agent.OnText := @OnText;
      Agent.OnThinking := @OnThinking;
      Agent.OnToolStart := @OnToolStart;
      Agent.OnToolResult := @OnToolResult;
      Agent.OnNotice := @OnNotice;
      Agent.Ask := @AskPermission;
      Agent.ShouldCancel := @UserWantsStop;

      { Resuming happens before the banner, because a saved session can carry
        its own model and the banner should report the one actually in use. }
      ResumeErr := '';
      if Resume then
        Resumed := Agent.LoadSession(SessionPath(uTools.RootDir), ResumeErr);

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
        EmitCLn(clGrey, '  a saved conversation exists here; /resume loads it');
        EmitLn;
      end;

      repeat
        if not ReadLineEdit('> ', Line) then Break;
        Line := Trim(Line);
        if Line = '' then Continue;

        if not HandleCommand(Line, Handled) then Break;
        if Handled then Continue;

        AtLineStart := True;
        { A session that runs long enough will eventually exceed the context
          window, and the failure mode is the whole turn being rejected.
          Trimming first costs the oldest exchanges instead. }
        if Agent.TranscriptBytes > CompactKeepBytes then
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
