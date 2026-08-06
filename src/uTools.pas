{ uTools - the tools the model is allowed to call, and the permission gate.

  Every tool that changes the machine (write, edit, bash) asks the user first,
  unless the session has been put in accept-all mode.  Reads are free.  Paths
  are resolved against the session root and refused when they escape it, so a
  confused model cannot walk into C:\Windows by accident. }
unit uTools;

{$mode objfpc}{$H+}

interface

uses uJson, uDiff;

type
  { Answer to a permission prompt. }
  TPermission = (pmAsk, pmAllowOnce, pmAllowAlways, pmDeny);

  { Supplied by the host so this unit does not depend on the console. }
  TAskProc = function(const Title, Detail: string): TPermission;

var
  { Session root; every path argument is resolved relative to it. }
  RootDir: string = '';
  { Set once the user picks "always" for a tool class. }
  AllowAllEdits: Boolean = False;
  AllowAllBash: Boolean = False;

const
  { pasclaude's own state directory, kept out of listings and searches.  The
    name lives here rather than in uAgent because this unit is the one that has
    to skip it, and two copies of the literal would drift. }
  StateDirName = '.pasclaude';

{ The tool list, as the API expects it under "tools". }
function ToolsSchema: TJson;

{ Runs Name with Input.  Returns the text result; IsError says whether the
  model should treat it as a failure.  Ask may be nil, which denies anything
  needing permission. }
function RunTool(const Name: string; Input: TJson; Ask: TAskProc;
  out IsError: Boolean): string;

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

implementation

uses SysUtils, Classes, Process, Windows;

const
  MaxReadBytes = 400 * 1024;   { keeps a stray huge file out of the context }
  MaxOutBytes  = 30 * 1024;    { cap on any single tool result }
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

function Clip(const S: string): string;
begin
  if Length(S) <= MaxOutBytes then
    Result := S
  else
    Result := Copy(S, 1, MaxOutBytes) +
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

function LoadFileText(const Full: string; out Text: string; out Err: string): Boolean;
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
    if N > MaxReadBytes then N := MaxReadBytes;
    SetLength(Text, N);
    if N > 0 then F.ReadBuffer(Text[1], N);
    if F.Size > MaxReadBytes then
      Err := Format('(file is %d bytes; first %d shown)', [F.Size, MaxReadBytes]);
    Result := True;
  finally
    F.Free;
  end;
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

function ListDir(const Full: string; Recurse: Boolean): string;

  procedure Walk(const Dir, Prefix: string; Depth: Integer);
  var
    R: TSearchRec;
    Dirs, Files: TStringList;
    I: Integer;
  begin
    if Depth > 4 then Exit;
    Dirs := TStringList.Create;
    Files := TStringList.Create;
    try
      if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, R) = 0 then
      begin
        repeat
          if (R.Name = '.') or (R.Name = '..') then Continue;
          { .git and build output would flood the listing with noise. }
          if (R.Attr and faDirectory) <> 0 then
          begin
            if (R.Name = '.git') or (R.Name = 'node_modules') or
               (CompareText(R.Name, StateDirName) = 0) then Continue;
            Dirs.Add(R.Name);
          end
          else
            Files.Add(Format('%s (%d bytes)', [R.Name, R.Size]));
        until FindNext(R) <> 0;
        SysUtils.FindClose(R);
      end;
      Dirs.Sort;
      Files.Sort;
      for I := 0 to Dirs.Count - 1 do
      begin
        Result := Result + Prefix + Dirs[I] + '\'#10;
        if Recurse then
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
  Walk(Full, '  ', 0);
end;

{ ------------------------------------------------------------------ search -- }

function GrepTree(const Root, Pattern, Glob: string): string;
var
  Hits: Integer;

  function Matches(const Name: string): Boolean;
  begin
    Result := (Glob = '') or (Glob = '*') or
      (LowerCase(ExtractFileExt(Name)) = LowerCase(ExtractFileExt(Glob))) or
      (Pos(LowerCase(Glob), LowerCase(Name)) > 0);
  end;

  procedure Walk(const Dir: string; Depth: Integer);
  var
    R: TSearchRec;
    Text, Line: string;
    L: TStringList;
    I: Integer;
    Err: string;
  begin
    if (Depth > 8) or (Hits >= 200) then Exit;
    if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, R) = 0 then
    begin
      repeat
        if (R.Name = '.') or (R.Name = '..') then Continue;
        if (R.Attr and faDirectory) <> 0 then
        begin
          { The session file holds the whole conversation, so a search that
            matched it would feed the transcript back into the model - growing
            the context every turn with a copy of itself. }
          if (R.Name = '.git') or (R.Name = 'node_modules') or
             (CompareText(R.Name, StateDirName) = 0) then Continue;
          Walk(IncludeTrailingPathDelimiter(Dir) + R.Name, Depth + 1);
        end
        else if Matches(R.Name) and (R.Size < MaxReadBytes) then
        begin
          if not LoadFileText(IncludeTrailingPathDelimiter(Dir) + R.Name, Text, Err) then
            Continue;
          if Pos(LowerCase(Pattern), LowerCase(Text)) = 0 then Continue;
          L := TStringList.Create;
          try
            L.Text := Text;
            for I := 0 to L.Count - 1 do
            begin
              Line := L[I];
              if Pos(LowerCase(Pattern), LowerCase(Line)) > 0 then
              begin
                Result := Result + Format('%s:%d: %s'#10,
                  [Rel(IncludeTrailingPathDelimiter(Dir) + R.Name), I + 1, Trim(Line)]);
                Inc(Hits);
                if Hits >= 200 then Break;
              end;
            end;
          finally
            L.Free;
          end;
        end;
      until (FindNext(R) <> 0) or (Hits >= 200);
      SysUtils.FindClose(R);
    end;
  end;

begin
  Result := '';
  Hits := 0;
  Walk(Root, 0);
  if Result = '' then
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

function ToolsSchema: TJson;
var
  P: TJson;
begin
  Result := TJson.NewArr;

  P := TJson.NewObj;
  P.Add('path', StrProp('File path, relative to the session root.'));
  Result.Push(MakeTool('read_file',
    'Read a text file. Output is line-numbered so you can cite line numbers.',
    P, ['path']));

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
  Result.Push(MakeTool('edit_file',
    'Replace one exact snippet in a file. Prefer this over write_file for ' +
    'changes to existing files. Requires user approval.',
    P, ['path', 'old_text', 'new_text']));

  P := TJson.NewObj;
  P.Add('path', StrProp('Directory, relative to the session root. Default ".".'));
  P.Add('recursive', BoolProp('Descend into subdirectories (max depth 4).'));
  Result.Push(MakeTool('list_dir', 'List a directory.', P, []));

  P := TJson.NewObj;
  P.Add('pattern', StrProp('Case-insensitive substring to search for.'));
  P.Add('glob', StrProp('Optional filename filter, e.g. ".pas" or "test".'));
  Result.Push(MakeTool('search',
    'Search file contents under the session root. Returns path:line: text.',
    P, ['pattern']));

  P := TJson.NewObj;
  P.Add('command', StrProp('Command line, run through cmd.exe /C.'));
  Result.Push(MakeTool('bash',
    'Run a shell command in the session root and return its output. ' +
    'Use it to build, run tests, or inspect the system. Requires user approval.',
    P, ['command']));
end;

{ --------------------------------------------------------------- execution -- }

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
    Result := 'list ' + Input.Str('path', '.')
  else if Name = 'search' then
    Result := Format('search "%s"', [Input.Str('pattern')])
  else if Name = 'bash' then
  begin
    S := Input.Str('command');
    if Length(S) > 120 then S := Copy(S, 1, 117) + '...';
    Result := '$ ' + S;
  end
  else
    Result := Name;
end;

{ Asks the user, honouring any standing "always" answer for this tool class. }
function Permit(const Name, Detail: string; Ask: TAskProc): Boolean;
var
  IsBash: Boolean;
  A: TPermission;
begin
  IsBash := Name = 'bash';
  if IsBash and AllowAllBash then Exit(True);
  if (not IsBash) and AllowAllEdits then Exit(True);
  if Ask = nil then Exit(False);

  A := Ask(Name, Detail);
  case A of
    pmAllowOnce: Result := True;
    pmAllowAlways:
      begin
        if IsBash then AllowAllBash := True else AllowAllEdits := True;
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
  Full, Err, Text, Note, Old, New, Updated: string;
  At, Second: Integer;
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
    Old := Input.Str('old_text');
    New := Input.Str('new_text');
    if Old = '' then Exit;
    At := Pos(Old, Text);
    if At = 0 then Exit;
    { An ambiguous match is refused later anyway; previewing the first hit
      would show an edit that is never going to happen. }
    Second := Pos(Old, Text, At + 1);
    if Second > 0 then Exit;
    Updated := Copy(Text, 1, At - 1) + New + Copy(Text, At + Length(Old), MaxInt);
    Result := DiffSummary(Text, Updated, PreviewLines);
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

function RunTool(const Name: string; Input: TJson; Ask: TAskProc;
  out IsError: Boolean): string;
var
  Full, Err, Text, Old, New, Cmd, Note: string;
  Code, At, Second: Integer;
begin
  IsError := False;
  if Input = nil then
  begin
    IsError := True;
    Exit('missing tool input');
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
    if not LoadFileText(Full, Text, Note) then
    begin
      IsError := True;
      Exit('cannot read: ' + Note);
    end;
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
    if not SaveFileText(Full, Input.Str('content'), Err) then
    begin
      IsError := True;
      Exit('cannot write: ' + Err);
    end;
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
    Old := Input.Str('old_text');
    New := Input.Str('new_text');
    if Old = '' then
    begin
      IsError := True;
      Exit('old_text must not be empty');
    end;
    At := Pos(Old, Text);
    if At = 0 then
    begin
      IsError := True;
      Exit('old_text was not found in ' + Rel(Full));
    end;
    { An ambiguous match would edit the wrong place, so it is refused rather
      than guessed at. }
    Second := Pos(Old, Text, At + 1);
    if Second > 0 then
    begin
      IsError := True;
      Exit('old_text occurs more than once; include more context');
    end;
    if not PermitChange(Name, Input, Ask) then
    begin
      IsError := True;
      Exit('the user denied this edit');
    end;
    Text := Copy(Text, 1, At - 1) + New + Copy(Text, At + Length(Old), MaxInt);
    if not SaveFileText(Full, Text, Err) then
    begin
      IsError := True;
      Exit('cannot write: ' + Err);
    end;
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
    Result := Clip(ListDir(Full, Input.Bool('recursive')));
  end

  else if Name = 'search' then
  begin
    Result := Clip(GrepTree(NormalizeRoot, Input.Str('pattern'), Input.Str('glob')));
  end

  else if Name = 'bash' then
  begin
    Cmd := Input.Str('command');
    if Trim(Cmd) = '' then
    begin
      IsError := True;
      Exit('command is required');
    end;
    if not Permit(Name, DescribeTool(Name, Input), Ask) then
    begin
      IsError := True;
      Exit('the user denied this command');
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

  else
  begin
    IsError := True;
    Result := 'unknown tool: ' + Name;
  end;
end;

end.
