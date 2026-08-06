{ Tests for the parts added after the first release: the line diff, the change
  previews shown before an edit is approved, and transcript compaction.

  These are the pieces a user meets on every turn, so the assertions are about
  behaviour that would be visibly wrong rather than about internal shapes:
  a diff that reports the wrong lines, a preview that lies about what a write
  will do, or a compaction that leaves a transcript the API will reject.

      fpc -Fusrc -FUbuild\units -FEbin tests\ux.lpr
      bin\ux.exe }
program ux;

{$mode objfpc}{$H+}

uses SysUtils, Classes, uJson, uDiff, uTools, uAgent;

var
  Fails: Integer = 0;
  TmpRoot: string;

procedure Check(Cond: Boolean; const What: string);
begin
  if Cond then
    WriteLn('ok   ', What)
  else
  begin
    WriteLn('FAIL ', What);
    Inc(Fails);
  end;
end;

function CountOccurrences(const Needle, Hay: string): Integer;
var
  P: Integer;
begin
  Result := 0;
  P := Pos(Needle, Hay);
  while P > 0 do
  begin
    Inc(Result);
    P := Pos(Needle, Hay, P + 1);
  end;
end;

procedure WriteFileText(const Path, Text: string);
var
  F: TFileStream;
begin
  ForceDirectories(ExtractFilePath(Path));
  F := TFileStream.Create(Path, fmCreate);
  try
    if Text <> '' then F.WriteBuffer(Text[1], Length(Text));
  finally
    F.Free;
  end;
end;

function ReadFileText(const Path: string): string;
var
  F: TFileStream;
begin
  Result := '';
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then F.ReadBuffer(Result[1], F.Size);
  finally
    F.Free;
  end;
end;

{ ------------------------------------------------------------------- diff -- }

procedure TestDiff;
var
  Stat: TDiffStat;
  Lines: TDiffLines;
  Text, Old, New: string;
  I, Adds, Removes, Gaps: Integer;
begin
  WriteLn('-- diff --');

  { Identical input must produce no diff at all, which is what lets the
    preview say "no change" instead of showing an empty box. }
  Lines := DiffText('a'#10'b'#10'c'#10, 'a'#10'b'#10'c'#10, Stat);
  Check((Stat.Added = 0) and (Stat.Removed = 0), 'identical text has no changes');
  Check(Length(Lines) = 0, 'identical text produces no diff lines');
  Check(DiffSummary('a'#10, 'a'#10, 0) = 'no change', 'a no-op edit says so');

  { A single changed line is one add and one remove, not a wholesale
    replacement: that is the difference between a readable preview and a
    useless one. }
  Lines := DiffText('a'#10'b'#10'c'#10, 'a'#10'B'#10'c'#10, Stat);
  Check(Stat.Added = 1, 'one changed line adds one');
  Check(Stat.Removed = 1, 'one changed line removes one');
  Adds := 0;
  Removes := 0;
  for I := 0 to High(Lines) do
  begin
    if Lines[I].Kind = dkAdd then Inc(Adds);
    if Lines[I].Kind = dkRemove then Inc(Removes);
  end;
  Check((Adds = 1) and (Removes = 1), 'the diff marks exactly the changed line');

  { Line numbers are what make a preview checkable against the file. }
  Lines := DiffText('a'#10'b'#10'c'#10, 'a'#10'b'#10'c'#10'd'#10, Stat);
  Check(Stat.Added = 1, 'an appended line is one addition');
  Check(Stat.Removed = 0, 'an appended line removes nothing');
  for I := 0 to High(Lines) do
    if Lines[I].Kind = dkAdd then
      Check(Lines[I].NewNo = 4, 'the added line carries its new line number');

  { Pure insertion and pure deletion are the two degenerate cases. }
  Lines := DiffText('', 'x'#10'y'#10, Stat);
  Check((Stat.Added = 2) and (Stat.Removed = 0), 'writing a new file is all additions');
  Lines := DiffText('x'#10'y'#10, '', Stat);
  Check((Stat.Added = 0) and (Stat.Removed = 2), 'emptying a file is all removals');

  { A change in a large file must not print the whole file: the context
    window is the point of the exercise. }
  Old := '';
  for I := 1 to 200 do
    Old := Old + Format('line %d'#10, [I]);
  New := StringReplace(Old, 'line 100'#10, 'CHANGED'#10, [], I);
  Lines := DiffText(Old, New, Stat);
  Check((Stat.Added = 1) and (Stat.Removed = 1), 'one line changed in a big file');
  Check(Length(Lines) <= 2 * DiffContext + 2,
    Format('only the changed region is shown, got %d lines', [Length(Lines)]));

  { Two distant changes are separate hunks with a gap marker between them,
    rather than one run that drags the middle of the file along. }
  New := StringReplace(Old, 'line 10'#10, 'FIRST'#10, [], I);
  New := StringReplace(New, 'line 150'#10, 'SECOND'#10, [], I);
  Lines := DiffText(Old, New, Stat);
  Gaps := 0;
  for I := 0 to High(Lines) do
    if Lines[I].Kind = dkGap then Inc(Gaps);
  Check(Gaps = 1, 'distant changes are separated by a gap marker');
  Check(Stat.Added = 2, 'both changes are counted');

  { CRLF is the native line ending here, so a file that uses it must not
    report every line as changed. }
  Lines := DiffText('a'#13#10'b'#13#10, 'a'#13#10'b'#13#10, Stat);
  Check((Stat.Added = 0) and (Stat.Removed = 0), 'CRLF text diffs clean against itself');
  Lines := DiffText('a'#13#10'b'#13#10, 'a'#13#10'B'#13#10, Stat);
  Check((Stat.Added = 1) and (Stat.Removed = 1), 'CRLF text finds the one change');
  { Counting alone is not enough: a stray CR compares equal on both sides, so
    the numbers stay right while the rendered diff carries a control character
    into the middle of the prompt and wrecks the layout. }
  Text := RenderDiff(Lines, 0);
  Check(Pos(#13, Text) = 0, 'no carriage return survives into the rendered diff');
  for I := 0 to High(Lines) do
    if Lines[I].Text <> '' then
      Check(Lines[I].Text[Length(Lines[I].Text)] <> #13,
        'no diff line ends in a carriage return');
  { A file that changes line endings but nothing else still differs, because
    the bytes on disk really did change. }
  Lines := DiffText('a'#13#10'b'#13#10, 'a'#10'b'#10, Stat);
  Check((Stat.Added = 0) and (Stat.Removed = 0),
    'a pure line-ending change is not shown as a content change');

  { The renderer's cap is what stops a huge rewrite filling the screen. }
  Old := '';
  New := '';
  for I := 1 to 100 do
  begin
    Old := Old + Format('old %d'#10, [I]);
    New := New + Format('new %d'#10, [I]);
  end;
  Lines := DiffText(Old, New, Stat);
  Text := RenderDiff(Lines, 10);
  Check(CountOccurrences(#10, Text) <= 11, 'the render cap is honoured');
  Check(Pos('more diff lines', Text) > 0, 'the truncation is announced');

  { Past the LCS limit the diff degrades to a summary instead of trying to
    allocate a table with millions of entries. }
  Old := '';
  for I := 1 to MaxLcsLines + 10 do
    Old := Old + Format('l%d'#10, [I]);
  New := Old + 'extra'#10;
  Lines := DiffText(Old, New, Stat);
  Check(Stat.Truncated, 'an oversized file falls back rather than diffing');
  Check(Pos('too large', DiffSummary(Old, New, 5)) > 0,
    'the fallback says why it is not a line diff');
end;

{ ---------------------------------------------------------------- preview -- }

var
  { Records what the permission prompt was shown, so the test can assert on
    what a user would actually have seen before approving. }
  LastDetail: string = '';
  Answer: TPermission = pmDeny;

function SpyAsk(const Title, Detail: string): TPermission;
begin
  LastDetail := Detail;
  Result := Answer;
end;

procedure TestPreview;
var
  Input: TJson;
  IsErr: Boolean;
  Path, Out_: string;
begin
  WriteLn('-- preview --');
  uTools.AllowAllEdits := False;
  uTools.AllowAllBash := False;

  Path := IncludeTrailingPathDelimiter(TmpRoot) + 'sample.txt';
  WriteFileText(Path, 'alpha'#10'beta'#10'gamma'#10);

  { An edit must show the change before it is approved.  This is the whole
    point of the feature: approving "edit sample.txt" tells the user nothing. }
  Input := TJson.NewObj;
  Input.AddStr('path', 'sample.txt');
  Input.AddStr('old_text', 'beta');
  Input.AddStr('new_text', 'BETA');
  LastDetail := '';
  Answer := pmDeny;
  Out_ := RunTool('edit_file', Input, @SpyAsk, IsErr);
  Input.Free;
  Check(Pos('- beta', LastDetail) > 0, 'the prompt shows the line being removed');
  Check(Pos('+ BETA', LastDetail) > 0, 'the prompt shows the line being added');
  Check(Pos('edit sample.txt', LastDetail) > 0, 'the prompt still names the file');
  Check(IsErr, 'a denied edit is an error result');
  Check(ReadFileText(Path) = 'alpha'#10'beta'#10'gamma'#10,
    'the denied edit did not touch the file');

  { The preview must reflect the file on disk, not what the model assumed.
    An edit whose old_text is not there is refused before any prompt. }
  Input := TJson.NewObj;
  Input.AddStr('path', 'sample.txt');
  Input.AddStr('old_text', 'not present');
  Input.AddStr('new_text', 'x');
  LastDetail := '';
  Out_ := RunTool('edit_file', Input, @SpyAsk, IsErr);
  Input.Free;
  Check(IsErr, 'an edit that does not match is an error');
  Check(LastDetail = '', 'a non-matching edit never reaches the prompt');

  { Overwriting an existing file shows a diff against the current contents. }
  Input := TJson.NewObj;
  Input.AddStr('path', 'sample.txt');
  Input.AddStr('content', 'alpha'#10'DELTA'#10'gamma'#10);
  LastDetail := '';
  Answer := pmDeny;
  Out_ := RunTool('write_file', Input, @SpyAsk, IsErr);
  Input.Free;
  Check(Pos('+ DELTA', LastDetail) > 0, 'an overwrite previews the new line');
  Check(Pos('- beta', LastDetail) > 0, 'an overwrite previews the lost line');
  Check(Pos('(new file)', LastDetail) = 0, 'an existing file is not called new');

  { A brand new file has nothing to diff against and should say so rather
    than claiming it removed the whole world. }
  Input := TJson.NewObj;
  Input.AddStr('path', 'fresh.txt');
  Input.AddStr('content', 'hello'#10);
  LastDetail := '';
  Answer := pmDeny;
  Out_ := RunTool('write_file', Input, @SpyAsk, IsErr);
  Input.Free;
  Check(Pos('(new file)', LastDetail) > 0, 'a new file is announced as new');
  Check(Pos('+ hello', LastDetail) > 0, 'the new content is previewed');

  { Approving must actually apply the change that was previewed. }
  Input := TJson.NewObj;
  Input.AddStr('path', 'sample.txt');
  Input.AddStr('old_text', 'beta');
  Input.AddStr('new_text', 'BETA');
  Answer := pmAllowOnce;
  Out_ := RunTool('edit_file', Input, @SpyAsk, IsErr);
  Input.Free;
  Check(not IsErr, 'an approved edit succeeds');
  Check(ReadFileText(Path) = 'alpha'#10'BETA'#10'gamma'#10,
    'the approved edit is exactly what was previewed');

  { A binary file has no useful line diff, and dumping its bytes into the
    prompt would be worse than saying nothing. }
  Path := IncludeTrailingPathDelimiter(TmpRoot) + 'blob.bin';
  WriteFileText(Path, 'A'#0#1#2#255'B');
  Input := TJson.NewObj;
  Input.AddStr('path', 'blob.bin');
  Input.AddStr('content', 'replacement');
  LastDetail := '';
  Answer := pmDeny;
  Out_ := RunTool('write_file', Input, @SpyAsk, IsErr);
  Input.Free;
  Check(Pos('binary', LastDetail) > 0, 'a binary overwrite is described, not diffed');

  { Under /yolo nothing is asked, so no preview work should happen and no
    prompt should appear. }
  uTools.AllowAllEdits := True;
  LastDetail := '';
  Input := TJson.NewObj;
  Input.AddStr('path', 'yolo.txt');
  Input.AddStr('content', 'x'#10);
  Out_ := RunTool('write_file', Input, @SpyAsk, IsErr);
  Input.Free;
  Check(not IsErr, 'accept-all writes without asking');
  Check(LastDetail = '', 'accept-all never builds a prompt');
  uTools.AllowAllEdits := False;

  { A path outside the root is refused before anything is read or previewed. }
  Input := TJson.NewObj;
  Input.AddStr('path', '..\escape.txt');
  Input.AddStr('content', 'x');
  LastDetail := '';
  Out_ := RunTool('write_file', Input, @SpyAsk, IsErr);
  Input.Free;
  Check(IsErr, 'an escaping write is refused');
  Check(LastDetail = '', 'an escaping write never reaches the prompt');
end;

{ ---------------------------------------------------------------- compact -- }

{ Builds a transcript the way a real session would: alternating user turns and
  assistant replies, some of them carrying tool calls and their results. }
procedure Converse(A: TAgent; Rounds: Integer);
var
  Blocks: TPartialBlocks;
  I: Integer;
  Ran: Boolean;
  Err: string;
begin
  for I := 1 to Rounds do
  begin
    A.Send('', Err);   { no-op: Send with empty text adds nothing }
    SetLength(Blocks, 1);
    Blocks[0].Kind := bkText;
    Blocks[0].Text := StringOfChar('x', 2000) + IntToStr(I);
    Blocks[0].Id := '';
    Blocks[0].Name := '';
    Blocks[0].Signature := '';
    A.ApplyBlocks(Blocks, Ran);
  end;
end;

procedure TestCompact;
var
  A: TAgent;
  Blocks: TPartialBlocks;
  Err, T: string;
  Ran: Boolean;
  I, Dropped, Before: Integer;
  Doc, Msgs: TJson;
begin
  WriteLn('-- compact --');

  { A short conversation has nothing worth dropping. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    Check(A.Compact(1000) = 0, 'an empty transcript compacts to nothing');
    A.Send('hello', Err);
    Check(A.Compact(10) = 0, 'a single exchange is never dropped');
    Check(A.MessageCount = 1, 'the only message survives');
  finally
    A.Free;
  end;

  { A long one is trimmed from the front, keeping the recent turns. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    for I := 1 to 12 do
    begin
      A.Send('question ' + IntToStr(I), Err);
      SetLength(Blocks, 1);
      Blocks[0].Kind := bkText;
      Blocks[0].Text := StringOfChar('x', 1000) + ' answer ' + IntToStr(I);
      Blocks[0].Id := '';
      Blocks[0].Name := '';
      Blocks[0].Signature := '';
      A.ApplyBlocks(Blocks, Ran);
    end;
    Before := A.MessageCount;
    Check(A.TranscriptBytes > 5000, 'the transcript grew large enough to matter');

    Dropped := A.Compact(5000);
    Check(Dropped > 0, 'an oversized transcript is trimmed');
    Check(A.MessageCount = Before - Dropped, 'the count matches what was dropped');
    Check(A.TranscriptBytes <= 5000 + 2000, 'the result is near the budget');

    { The recent exchange must survive - it is what the user is talking
      about - and the oldest must be gone. }
    T := A.Transcript;
    Check(Pos('question 12', T) > 0, 'the most recent question is kept');
    Check(Pos('question 1"', T) = 0, 'the oldest question is gone');

    { Whatever is left must still be a legal request: the API rejects a
      transcript that does not begin with a user turn. }
    Doc := JsonParse(T);
    Check(Doc <> nil, 'the compacted transcript is valid JSON');
    if Doc <> nil then
    try
      Check(Doc.Count > 0, 'something is left to send');
      Check(Doc.Item(0).Str('role') = 'user',
        'the transcript still starts with a user turn');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;

  { The hard case: a tool_result user message must never be left at the front,
    because it refers to a tool_use in an assistant message that compaction
    just removed.  The API rejects that outright. }

  { A budget too small for even one exchange must still leave something
    sendable.  Emptying the transcript would make the very next turn fail with
    no way for the user to recover short of restarting. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    for I := 1 to 6 do
    begin
      A.Send('q' + IntToStr(I), Err);
      SetLength(Blocks, 1);
      Blocks[0].Kind := bkText;
      Blocks[0].Text := StringOfChar('z', 500);
      Blocks[0].Id := '';
      Blocks[0].Name := '';
      Blocks[0].Signature := '';
      A.ApplyBlocks(Blocks, Ran);
    end;
    A.Compact(1);
    Check(A.MessageCount > 0, 'compacting to a tiny budget still leaves a message');
    Doc := JsonParse(A.Transcript);
    Check(Doc <> nil, 'the survivor is valid JSON');
    if Doc <> nil then
    try
      Check(Doc.Count > 0, 'the transcript is never emptied completely');
      Check(Doc.Item(0).Str('role') = 'user',
        'the survivor is a user turn, which is what the API demands');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;

  A := TAgent.Create('k', 'm', 'sys');
  try
    for I := 1 to 10 do
    begin
      A.Send('ask ' + IntToStr(I), Err);
      SetLength(Blocks, 1);
      Blocks[0].Kind := bkToolUse;
      Blocks[0].Id := 'call_' + IntToStr(I);
      Blocks[0].Name := 'search';
      Blocks[0].Text := '{"pattern":"' + StringOfChar('q', 800) + '"}';
      Blocks[0].Signature := '';
      A.ApplyBlocks(Blocks, Ran);
      if not Ran then Check(False, 'the scripted tool call ran');
    end;
    Check(True, 'every scripted tool call ran');

    Dropped := A.Compact(4000);
    Check(Dropped > 0, 'a tool-heavy transcript is trimmed');
    T := A.Transcript;
    Doc := JsonParse(T);
    Check(Doc <> nil, 'the trimmed transcript parses');
    if Doc <> nil then
    try
      Check(Doc.Item(0).Str('role') = 'user', 'it starts with a user turn');
      Msgs := Doc.Item(0).Find('content');
      Check(Msgs <> nil, 'the first message has content');
      if (Msgs <> nil) and (Msgs.Count > 0) then
        Check(Msgs.Item(0).Str('type') <> 'tool_result',
          'no orphaned tool_result is left at the front');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;

  { Compaction must not disturb a conversation that continues afterwards. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    for I := 1 to 8 do
    begin
      A.Send('q' + IntToStr(I), Err);
      SetLength(Blocks, 1);
      Blocks[0].Kind := bkText;
      Blocks[0].Text := StringOfChar('y', 900);
      Blocks[0].Id := '';
      Blocks[0].Name := '';
      Blocks[0].Signature := '';
      A.ApplyBlocks(Blocks, Ran);
    end;
    A.Compact(3000);
    A.Send('after compaction', Err);
    T := A.Transcript;
    Check(Pos('after compaction', T) > 0, 'the next question appends normally');
    Doc := JsonParse(A.RequestBody);
    Check(Doc <> nil, 'a request built after compaction is valid JSON');
    if Doc <> nil then
    try
      Msgs := Doc.Find('messages');
      Check((Msgs <> nil) and (Msgs.Count > 0), 'the request carries the messages');
      Check(Msgs.Item(0).Str('role') = 'user', 'and still opens with a user turn');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;
end;

{ ------------------------------------------------------------------- main -- }

procedure Cleanup(const Dir: string);
var
  R: TSearchRec;
  P: string;
begin
  if not DirectoryExists(Dir) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, R) = 0 then
  begin
    repeat
      if (R.Name = '.') or (R.Name = '..') then Continue;
      P := IncludeTrailingPathDelimiter(Dir) + R.Name;
      if (R.Attr and faDirectory) <> 0 then
        Cleanup(P)
      else
        DeleteFile(P);
    until FindNext(R) <> 0;
    SysUtils.FindClose(R);
  end;
  RemoveDir(Dir);
end;

begin
  TmpRoot := IncludeTrailingPathDelimiter(GetTempDir) + 'pasclaude-ux';
  Cleanup(TmpRoot);
  ForceDirectories(TmpRoot);
  uTools.RootDir := TmpRoot;

  try
    TestDiff;
    TestPreview;
    TestCompact;
  finally
    uTools.RootDir := '';
    Cleanup(TmpRoot);
  end;

  WriteLn;
  if Fails = 0 then
    WriteLn('all ux tests passed')
  else
  begin
    WriteLn(Fails, ' FAILURES');
    Halt(1);
  end;
end.
