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
  SlashCommands: array[0..15] of string = (
    '/help', '/clear', '/compact', '/diff', '/memory', '/init', '/rewind',
    '/sessions', '/think',
    '/resume', '/save', '/cwd', '/model', '/yolo', '/cost', '/exit');

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
    '- Jupyter notebooks (.ipynb) read back as numbered cells; change them ' +
    'with notebook_edit, not edit_file.' + #10 +
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
function ExpandImports(const Text: string): string;
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
        if (Sub <> '') and uTools.IsValidUtf8(Sub) then
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
function UserContext: string;
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
function ProjectContext: string;
var
  Names: array[0..2] of string = ('AGENTS.md', 'CLAUDE.md', '.pasclaude.md');
  I: Integer;
  Path: string;
  L: TStringList;
begin
  Result := UserContext;
  for I := 0 to High(Names) do
  begin
    Path := IncludeTrailingPathDelimiter(uTools.RootDir) + Names[I];
    if not FileExists(Path) then Continue;
    L := TStringList.Create;
    try
      try
        L.LoadFromFile(Path);
        Result := Result + #10#10 + '--- ' + Names[I] + ' ---' + #10 +
          ExpandImports(L.Text);
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
  EmitCLn(clGrey,   '  /memory        show the project memory (CLAUDE.md)');
  EmitCLn(clGrey,   '  /init          have the model write a CLAUDE.md for this project');
  EmitCLn(clGrey,   '  /rewind        undo turns: conversation and edited files');
  EmitCLn(clGrey,   '  /think [n]     extended thinking: on, off, or a token budget');
  EmitCLn(clGrey,   '  /resume        reload the saved conversation');
  EmitCLn(clGrey,   '  /save          write the conversation now');
  EmitCLn(clGrey,   '  /cwd           show the session root');
  EmitCLn(clGrey,   '  /model [name]  pick a model from a list, or set one by name');
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

{ Standing approvals, beside the session and the history. }
function PermissionsPath: string;
begin
  Result := IncludeTrailingPathDelimiter(uTools.RootDir) + SessionDir +
    PathDelim + 'permissions.json';
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
  else if Cmd = '/yolo' then
  begin
    uTools.AllowAllEdits := True;
    uTools.AllowAllBash := True;
    uTools.AllowAllFetch := True;
    YoloSession := True;
    { Deliberately not persisted: /yolo is "I trust this session", and a
      standing file that quietly means "and every future one" is a wider
      grant than the word implied.  The per-answer approvals do persist,
      because each named the thing it covered. }
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
    { Not one of ours.  Left unhandled so the caller can try the custom
      commands in .pasclaude\commands before declaring it unknown. }
    Handled := False;
end;

{ ------------------------------------------------------------------- main -- }

{ A user-defined command: /name args reads .pasclaude\commands\name.md and
  returns its contents as the prompt, with every $ARGUMENTS replaced by the
  rest of the line.  The file is the prompt, nothing more - no frontmatter,
  no scripting - because a prompt in a file already covers the real use:
  the same request typed often, made one word. }
function ExpandCustomCommand(const Line: string; out Ok: Boolean): string;
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

  Path := IncludeTrailingPathDelimiter(uTools.RootDir) + SessionDir +
    PathDelim + 'commands' + PathDelim + Name + '.md';
  if not FileExists(Path) then Exit;

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
  PrintPrompt: string = '';
  PrintMode: Boolean = False;
  Piped: string;

begin
  TermInit;
  try
    Dir := '';
    for ArgI := 1 to ParamCount do
    begin
      Arg := ParamStr(ArgI);
      { -p consumed the next argument as its prompt on the pass before. }
      if (ArgI > 1) and ((ParamStr(ArgI - 1) = '-p') or
         (ParamStr(ArgI - 1) = '--print')) then Continue;
      if (Arg = '--resume') or (Arg = '-r') then
        Resume := True
      else if (Arg = '-p') or (Arg = '--print') then
      begin
        PrintMode := True;
        if ArgI < ParamCount then PrintPrompt := ParamStr(ArgI + 1);
      end
      else if (Arg = '--help') or (Arg = '-h') or (Arg = '/?') then
      begin
        EmitCLn(clBright, 'pasclaude [directory] [--resume] [-p "prompt"]');
        EmitCLn(clGrey, '  --resume  continue the conversation saved in that directory');
        EmitCLn(clGrey, '  -p        answer one prompt and exit (reads stdin when piped)');
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
          EmitCLn(clRed, 'print mode needs a prompt: -p "question" or piped stdin');
          TermDone;
          Halt(2);
        end;
        if Piped <> '' then
          PrintPrompt := PrintPrompt + #10#10 +
            'Input follows.'#10'---'#10 + Piped;

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
          Line := ExpandCustomCommand(Line, Handled);
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
        { The moment before the turn runs is what /rewind returns to. }
        RecordCheckpoint(Line);
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
    TermDone;
  end;
end.
