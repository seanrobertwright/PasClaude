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

{ ------------------------------------------------------------ permissions -- }

function AskPermission(const Title, Detail: string): TPermission;
var
  Line: string;
begin
  NeedNewLine;
  EmitCLn(clYellow, '  permission needed: ' + Title);
  EmitCLn(clBright, '    ' + Detail);
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
  EmitCLn(clGrey,   '  /cwd           show the session root');
  EmitCLn(clGrey,   '  /model [name]  show or change the model');
  EmitCLn(clGrey,   '  /yolo          approve every tool for this session');
  EmitCLn(clGrey,   '  /cost          tokens used so far');
  EmitCLn(clGrey,   '  /exit          quit (Ctrl+C also works)');
end;

procedure ShowBanner;
begin
  EmitCLn(clCyan, Format('pasclaude %s', [Version]));
  EmitCLn(clGrey, '  ' + uTools.RootDir);
  EmitCLn(clGrey, '  ' + Agent.Model);
  EmitCLn(clGrey, '  /help for commands, /exit to quit');
  EmitLn;
end;

{ Returns False when the command asked to quit. }
function HandleCommand(const Line: string; out Handled: Boolean): Boolean;
var
  Cmd, Arg: string;
  Sp: Integer;
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
  else if Cmd = '/cwd' then
    EmitCLn(clGrey, '  ' + uTools.RootDir)
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
  ApiKey, ModelName, Line, Err, Dir: string;
  Handled: Boolean;

begin
  TermInit;
  try
    Dir := '';
    if ParamCount >= 1 then Dir := ParamStr(1);
    if Dir <> '' then
    begin
      if not DirectoryExists(Dir) then
      begin
        EmitCLn(clRed, 'no such directory: ' + Dir);
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
      Halt(2);
    end;
    if not HttpAvailable then
    begin
      EmitCLn(clRed, 'winhttp.dll could not be loaded; no network available.');
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

      ShowBanner;

      repeat
        if not ReadLineEdit('> ', Line) then Break;
        Line := Trim(Line);
        if Line = '' then Continue;

        if not HandleCommand(Line, Handled) then Break;
        if Handled then Continue;

        AtLineStart := True;
        if not Agent.Send(Line, Err) then
        begin
          NeedNewLine;
          EmitCLn(clRed, '  ' + Err);
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
