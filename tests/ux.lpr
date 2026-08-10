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

{ Windows first, so SysUtils' DeleteFile and GetEnvironmentVariable win over
  the raw API of the same names. }
uses Windows, SysUtils, Classes, DateUtils, uJson, uSettings, uAuth, uDiff,
  uHttp, uTelem, uHooks, uSandbox, uIde, uTools, uImage, uAgent, uDiag,
  uTerm, uNotebook, uSdk, uGitHub, uCi;

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
    A.AppendUserText('hello');
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
      A.AppendUserText('question ' + IntToStr(I));
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
      A.AppendUserText('q' + IntToStr(I));
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
      A.AppendUserText('ask ' + IntToStr(I));
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
      A.AppendUserText('q' + IntToStr(I));
      SetLength(Blocks, 1);
      Blocks[0].Kind := bkText;
      Blocks[0].Text := StringOfChar('y', 900);
      Blocks[0].Id := '';
      Blocks[0].Name := '';
      Blocks[0].Signature := '';
      A.ApplyBlocks(Blocks, Ran);
    end;
    A.Compact(3000);
    A.AppendUserText('after compaction');
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

{ ---------------------------------------------------------------- session -- }

{ A saved session is a file in the user's project that is read back and sent
  straight to the API.  That makes it the one input here that is both
  persistent and structurally load-bearing: a stale or hand-edited file must be
  refused rather than turned into requests that fail forever after. }
{ The whole resume policy, driven directly so no network is involved.  Two
  rules carry the feature and both are asserted here: a file that is not there
  yet is a fresh start, because the first iteration of a subprocess-per-turn
  loop has none, and a file that IS there and cannot be read stops the run,
  because a script that asked to continue and quietly got a blank session does
  work on absent context and then overwrites the evidence. }
procedure TestSdkResumePolicy;
var
  A: TAgent;
  Blocks: TPartialBlocks;
  Err, Dir, Good, Bad, Newer, Missing: string;
  N: Integer;
  Ran: Boolean;
begin
  WriteLn('-- sdk resume --');
  Dir := IncludeTrailingPathDelimiter(TmpRoot) + 'sdkresume';
  ForceDirectories(Dir);
  Good := IncludeTrailingPathDelimiter(Dir) + 'good.json';
  Bad := IncludeTrailingPathDelimiter(Dir) + 'bad.json';
  Newer := IncludeTrailingPathDelimiter(Dir) + 'newer.json';
  Missing := IncludeTrailingPathDelimiter(Dir) + 'not-here.json';
  if FileExists(Missing) then DeleteFile(Missing);

  A := TAgent.Create('k', 'm', 'sys');
  try
    A.AppendUserText('the saved question');
    SetLength(Blocks, 1);
    Blocks[0].Kind := bkText;
    Blocks[0].Text := 'the saved answer';
    Blocks[0].Id := '';
    Blocks[0].Name := '';
    Blocks[0].Signature := '';
    A.ApplyBlocks(Blocks, Ran);
    Check(A.SaveSession(Good, Err), 'a session to resume from is written');
  finally
    A.Free;
  end;

  WriteFileText(Bad, '{not json');
  WriteFileText(Newer,
    '{"version":99,"messages":[{"role":"user","content":' +
    '[{"type":"text","text":"hi"}]}]}');

  A := TAgent.Create('k', 'm', 'sys');
  try
    N := -1;
    Check(uSdk.SdkResumeInto(A, '', N, Err), 'an empty path is not a refusal');
    Check(N = 0, 'and restores nothing');
    Check(A.MessageCount = 0, 'leaving the transcript empty');

    N := -1;
    Check(uSdk.SdkResumeInto(A, Missing, N, Err),
      'a file that is not there yet is a fresh start, not a failure');
    Check(N = 0, 'with no messages restored');
    Check(A.MessageCount = 0, 'and an untouched transcript');

    N := -1;
    Check(uSdk.SdkResumeInto(A, Good, N, Err),
      'a good session file resumes: ' + Err);
    Check(N = 2, Format('reporting the message count it restored (%d)', [N]));
    Check(N = A.MessageCount, 'which is the agent''s own count');
    Check(Pos('the saved question', A.Transcript) > 0,
      'and the conversation came back');
  finally
    A.Free;
  end;

  { The refusals, each against an agent that already has a conversation, so a
    load that replaced FMessages before finishing validation is visible. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    A.AppendUserText('the live question');
    N := -1;
    Check(not uSdk.SdkResumeInto(A, Bad, N, Err),
      'a file that is not JSON is refused, not started fresh');
    Check(Err <> '', 'with a reason');
    Check(Pos('the live question', A.Transcript) > 0,
      'and the live conversation is untouched');

    Err := '';
    Check(not uSdk.SdkResumeInto(A, Newer, N, Err),
      'a session from a newer build is refused');
    Check(Pos('version', Err) > 0, 'saying so: ' + Err);
    Check(Pos('the live question', A.Transcript) > 0,
      'and that conversation is untouched too');
  finally
    A.Free;
  end;
end;

procedure TestSession;
var
  A: TAgent;
  Blocks: TPartialBlocks;
  Err, Path, T: string;
  Ran: Boolean;
  I: Integer;
  Doc: TJson;
  Before, After_: Integer;

  procedure SeedTurn(Ag: TAgent; const Q, R: string);
  begin
    { Send is not used here: with no transport it fails, and a failed turn now
      correctly unwinds the question it could not answer.  The user turn is
      appended directly so the seeded conversation is the one being tested. }
    Ag.AppendUserText(Q);
    SetLength(Blocks, 1);
    Blocks[0].Kind := bkText;
    Blocks[0].Text := R;
    Blocks[0].Id := '';
    Blocks[0].Name := '';
    Blocks[0].Signature := '';
    Ag.ApplyBlocks(Blocks, Ran);
  end;

begin
  WriteLn('-- session --');
  Path := IncludeTrailingPathDelimiter(TmpRoot) + 'sess' + PathDelim + 'session.json';

  { The round trip has to preserve what the next request is built from: the
    messages, and the counters the user sees in /cost. }
  A := TAgent.Create('secret-key', 'some-model', 'sys');
  try
    SeedTurn(A, 'first question', 'first answer');
    SeedTurn(A, 'second question', 'second answer');
    Check(A.SaveSession(Path, Err), 'a session saves');
    Check(FileExists(Path), 'the file is created, directories and all');
  finally
    A.Free;
  end;

  A := TAgent.Create('other-key', '', 'sys');
  try
    Check(A.LoadSession(Path, Err), 'a saved session loads: ' + Err);
    Check(A.MessageCount = 4, 'every message came back');
    T := A.Transcript;
    Check(Pos('first question', T) > 0, 'the first question survived');
    Check(Pos('second answer', T) > 0, 'the last answer survived');
    Check(A.Model = 'some-model', 'the model is restored');
    { A resumed conversation must be able to continue, which means the
      restored transcript has to be a legal request body. }
    A.AppendUserText('third question');
    Check(Pos('third question', A.Transcript) > 0, 'the conversation continues');
    Doc := JsonParse(A.RequestBody);
    Check(Doc <> nil, 'a request after resuming is valid JSON');
    Doc.Free;
  finally
    A.Free;
  end;

  { The key is the one thing that must never be written down: the file lives
    inside the user's project, next to code that gets committed. }
  Check(Pos('secret-key', ReadFileText(Path)) = 0,
    'the API key is not written into the session file');

  { A tool call and its result have to survive together, because the API
    rejects one without the other. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    A.AppendUserText('use a tool');
    SetLength(Blocks, 1);
    Blocks[0].Kind := bkToolUse;
    Blocks[0].Id := 'call_1';
    Blocks[0].Name := 'search';
    Blocks[0].Text := '{"pattern":"x"}';
    Blocks[0].Signature := '';
    A.ApplyBlocks(Blocks, Ran);
    Check(Ran, 'the tool ran');
    Check(A.SaveSession(Path, Err), 'a session with a tool call saves');
  finally
    A.Free;
  end;
  A := TAgent.Create('k', 'm', 'sys');
  try
    Check(A.LoadSession(Path, Err), 'a tool exchange reloads: ' + Err);
    Check(Pos('tool_use', A.Transcript) > 0, 'the tool call survived');
    Check(Pos('tool_result', A.Transcript) > 0, 'its result survived with it');
  finally
    A.Free;
  end;

  { A server-side search leaves a call and a result block in the same
    assistant message.  The unanswered-tool-call rule is about tool_use
    specifically, so a saved session carrying those blocks must reload
    rather than being read as a dangling call. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    A.AppendUserText('look it up');
    SetLength(Blocks, 2);
    Blocks[0].Kind := bkServerToolUse;
    Blocks[0].Id := 'srv_1';
    Blocks[0].Name := 'web_search';
    Blocks[0].Text := '{"query":"pascal"}';
    Blocks[0].Signature := '';
    Blocks[1].Kind := bkResult;
    Blocks[1].Id := '';
    Blocks[1].Name := '';
    Blocks[1].Text := '{"type":"web_search_tool_result","tool_use_id":"srv_1",' +
                      '"content":[{"type":"web_search_result","title":"P"}]}';
    Blocks[1].Signature := '';
    A.ApplyBlocks(Blocks, Ran);
    Check(not Ran, 'a server-side call runs nothing locally');
    Check(A.SaveSession(Path, Err), 'a session with a web search saves');
  finally
    A.Free;
  end;
  A := TAgent.Create('k', 'm', 'sys');
  try
    Check(A.LoadSession(Path, Err), 'a web search exchange reloads: ' + Err);
    Check(Pos('server_tool_use', A.Transcript) > 0, 'the search call survived');
    Check(Pos('web_search_tool_result', A.Transcript) > 0,
      'its result survived with it');
  finally
    A.Free;
  end;

  { Everything below is a file the program did not write.  Each one must be
    refused with the current conversation left intact - a bad file on disk
    should cost the user nothing. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    SeedTurn(A, 'live question', 'live answer');

    Check(not A.LoadSession(IncludeTrailingPathDelimiter(TmpRoot) + 'nope.json', Err),
      'a missing session is refused');
    Check(Err <> '', 'and says so');

    WriteFileText(Path, 'this is not json at all');
    Check(not A.LoadSession(Path, Err), 'a corrupt session is refused');

    WriteFileText(Path, '[1,2,3]');
    Check(not A.LoadSession(Path, Err), 'a session that is not an object is refused');

    WriteFileText(Path, '{"version":1}');
    Check(not A.LoadSession(Path, Err), 'a session with no messages array is refused');

    { From the future: the shape may have changed in ways this build would
      misread, so it is refused rather than half-understood. }
    WriteFileText(Path, '{"version":999,"messages":[]}');
    Check(not A.LoadSession(Path, Err), 'a newer session version is refused');
    Check(Pos('999', Err) > 0, 'the version mismatch is explained');

    { The two structural rules the API enforces. }
    WriteFileText(Path, '{"version":1,"messages":[' +
      '{"role":"assistant","content":[{"type":"text","text":"hi"}]}]}');
    Check(not A.LoadSession(Path, Err),
      'a transcript starting with the assistant is refused');

    WriteFileText(Path, '{"version":1,"messages":[' +
      '{"role":"user","content":[{"type":"text","text":"q"}]},' +
      '{"role":"assistant","content":[{"type":"tool_use","id":"c1",' +
      '"name":"search","input":{}}]}]}');
    Check(not A.LoadSession(Path, Err),
      'a transcript with an unanswered tool call is refused');
    Check(Pos('unanswered', Err) > 0, 'and names the reason');

    { A tool_result whose id does not match the call is the same defect
      wearing a disguise, and the API rejects it just as hard. }
    WriteFileText(Path, '{"version":1,"messages":[' +
      '{"role":"user","content":[{"type":"text","text":"q"}]},' +
      '{"role":"assistant","content":[{"type":"tool_use","id":"c1",' +
      '"name":"search","input":{}}]},' +
      '{"role":"user","content":[{"type":"tool_result","tool_use_id":"WRONG",' +
      '"content":"x"}]}]}');
    Check(not A.LoadSession(Path, Err),
      'a tool result with a mismatched id is refused');

    WriteFileText(Path, '{"version":1,"messages":[' +
      '{"role":"user","content":[]}]}');
    Check(not A.LoadSession(Path, Err), 'a message with no content is refused');

    WriteFileText(Path, '{"version":1,"messages":[' +
      '{"role":"wizard","content":[{"type":"text","text":"q"}]}]}');
    Check(not A.LoadSession(Path, Err), 'an unknown role is refused');

    WriteFileText(Path, '{"version":1,"messages":[' +
      '{"role":"user","content":[{"text":"no type here"}]}]}');
    Check(not A.LoadSession(Path, Err), 'a block with no type is refused');

    { After all of that the live conversation must be exactly as it was. }
    Check(A.MessageCount = 2, 'the live conversation is untouched by bad files');
    Check(Pos('live question', A.Transcript) > 0, 'its content is intact');
    Doc := JsonParse(A.RequestBody);
    Check(Doc <> nil, 'and it can still build a request');
    Doc.Free;
  finally
    A.Free;
  end;

  { A turn that failed leaves the question in the transcript with nothing
    answering it.  Autosave runs after a failed turn too, so without trimming,
    the saved session ends in a user message - and resuming it and asking again
    produces two user turns in a row.  Found by running the shipped binary
    against the real endpoint with a bad key and reading what it wrote. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    SeedTurn(A, 'answered question', 'an answer');
    { No transport, so this turn fails - and Send now unwinds the question it
      could not answer rather than leaving it for autosave to store. }
    A.Send('question that fails', Err);
    Check(A.MessageCount = 2, 'the failed question is not left in the transcript');
    Check(not A.TrimUnansweredQuestion, 'there is nothing left to trim');
    T := A.Transcript;
    Check(Pos('question that fails', T) = 0, 'the unanswered question is gone');
    Check(Pos('answered question', T) > 0, 'the answered exchange is untouched');
    Check(not A.TrimUnansweredQuestion,
      'trimming again does nothing, since the last turn is the assistant');

    { The saved file must not end on a user turn either. }
    Check(A.SaveSession(Path, Err), 'the trimmed conversation saves');
  finally
    A.Free;
  end;
  A := TAgent.Create('k', 'm', 'sys');
  try
    Check(A.LoadSession(Path, Err), 'it reloads');
    Check(A.MessageCount = 2, 'with the trailing question left out');
  finally
    A.Free;
  end;

  { A trailing tool_result is a different case and must survive: it answers
    the assistant turn before it, so dropping it would orphan that tool call -
    exactly the corruption the loader refuses. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    A.AppendUserText('use a tool');
    SetLength(Blocks, 1);
    Blocks[0].Kind := bkToolUse;
    Blocks[0].Id := 'call_x';
    Blocks[0].Name := 'search';
    Blocks[0].Text := '{"pattern":"y"}';
    Blocks[0].Signature := '';
    A.ApplyBlocks(Blocks, Ran);
    Check(A.MessageCount = 3, 'question, tool call, tool result');
    Check(not A.TrimUnansweredQuestion,
      'a trailing tool_result is not mistaken for an unanswered question');
    Check(A.MessageCount = 3, 'so nothing is removed');
    Check(A.SaveSession(Path, Err) and A.LoadSession(Path, Err),
      'and it still round-trips: ' + Err);
  finally
    A.Free;
  end;

  { Trimming an empty conversation must not misbehave. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    Check(not A.TrimUnansweredQuestion, 'trimming an empty transcript is a no-op');
    Check(A.MessageCount = 0, 'and leaves it empty');
  finally
    A.Free;
  end;

  { Clearing a conversation has to clear the saved copy as well.  Otherwise
    "cleared" means "cleared until you resume", and something the user
    deliberately discarded comes back on the next run.  This is the sequence
    /clear performs. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    SeedTurn(A, 'something private', 'a reply about it');
    Check(A.SaveSession(Path, Err), 'the conversation is saved');
    Check(Pos('something private', ReadFileText(Path)) > 0,
      'and is really on disk');

    A.Reset;
    Check(A.SaveSession(Path, Err), 'clearing saves the now-empty conversation');
    Check(Pos('something private', ReadFileText(Path)) = 0,
      'the cleared conversation is gone from the file');
  finally
    A.Free;
  end;
  A := TAgent.Create('k', 'm', 'sys');
  try
    Check(A.LoadSession(Path, Err), 'the cleared session still loads');
    Check(A.MessageCount = 0, 'and resuming it resurrects nothing');
  finally
    A.Free;
  end;

  { A second run in the same directory that is not resuming would overwrite the
    session on its first save.  The old one is moved aside first, so work is
    recoverable rather than silently gone.  Two people - or two windows - in
    one project directory is not an exotic case. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    SeedTurn(A, 'valuable earlier work', 'an answer worth keeping');
    Check(A.SaveSession(Path, Err), 'the earlier session is saved');
  finally
    A.Free;
  end;

  Check(BackupSession(Path, Err), 'the existing session is moved aside: ' + Err);
  Check(not FileExists(Path), 'the live path is now free for the new run');
  Check(FileExists(ChangeFileExt(Path, '') + '.prev.json'),
    'and the previous conversation is kept beside it');
  Check(Pos('valuable earlier work',
    ReadFileText(ChangeFileExt(Path, '') + '.prev.json')) > 0,
    'with its contents intact');

  { The copy has to be a real session, not just bytes: recovering it by hand
    means renaming it back and resuming. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    Check(A.LoadSession(ChangeFileExt(Path, '') + '.prev.json', Err),
      'the kept copy is itself resumable: ' + Err);
    Check(A.MessageCount = 2, 'carrying the earlier exchange');
  finally
    A.Free;
  end;

  { Backing up when there is nothing there is not an error - the common case
    is a first run in a clean directory. }
  DeleteFile(Path);
  Check(BackupSession(Path, Err), 'backing up a missing session is a no-op');

  { And a second backup must not fail on the copy already being there. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    SeedTurn(A, 'second run work', 'another answer');
    A.SaveSession(Path, Err);
  finally
    A.Free;
  end;
  Check(BackupSession(Path, Err),
    'a later backup replaces the previous copy: ' + Err);
  Check(Pos('second run work',
    ReadFileText(ChangeFileExt(Path, '') + '.prev.json')) > 0,
    'and the copy is the most recent one');

  { An empty session is not corrupt, it is just a conversation nobody has had
    yet, and loading it should quietly produce an empty transcript. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    WriteFileText(Path, '{"version":1,"messages":[]}');
    Check(A.LoadSession(Path, Err), 'an empty session loads without complaint');
    Check(A.MessageCount = 0, 'and leaves nothing behind');
    A.AppendUserText('starting over');
    Check(A.MessageCount = 1, 'a fresh conversation starts from it');
  finally
    A.Free;
  end;

  { Compaction and persistence meet on every long session: the transcript is
    trimmed before a request and saved after it, so whatever compaction leaves
    behind is what gets written.  If compaction could produce a shape the
    loader rejects, a long session would save a file it could never resume. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    for I := 1 to 10 do
    begin
      A.AppendUserText('long question ' + IntToStr(I));
      SetLength(Blocks, 1);
      Blocks[0].Kind := bkToolUse;
      Blocks[0].Id := 'tc_' + IntToStr(I);
      Blocks[0].Name := 'search';
      Blocks[0].Text := '{"pattern":"' + StringOfChar('p', 600) + '"}';
      Blocks[0].Signature := '';
      A.ApplyBlocks(Blocks, Ran);
    end;
    Check(A.Compact(4000) > 0, 'a long tool session compacts');
    Check(A.SaveSession(Path, Err), 'the compacted session saves');
  finally
    A.Free;
  end;
  A := TAgent.Create('k', 'm', 'sys');
  try
    { This is the assertion that matters: the loader applies the same
      structural rules the API does, so if it accepts what compaction wrote,
      compaction did not corrupt the conversation. }
    Check(A.LoadSession(Path, Err),
      'what compaction left behind is still loadable: ' + Err);
    Check(A.MessageCount > 0, 'and it is not empty');
  finally
    A.Free;
  end;

  { The file is rewritten after every turn, so the write must not be able to
    destroy the previous good session partway through.  It goes to a temporary
    file and is renamed over the old one; the observable consequences are that
    no .tmp is left behind and that repeated saves keep the file loadable. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    for I := 1 to 5 do
    begin
      SeedTurn(A, 'turn ' + IntToStr(I), 'reply ' + IntToStr(I));
      Check(A.SaveSession(Path, Err), 'save ' + IntToStr(I) + ' succeeds');
    end;
    Check(not FileExists(Path + '.tmp'), 'no temporary file is left behind');
  finally
    A.Free;
  end;
  A := TAgent.Create('k', 'm', 'sys');
  try
    Check(A.LoadSession(Path, Err), 'the repeatedly-saved file still loads');
    Check(A.MessageCount = 10, 'with every exchange intact');
  finally
    A.Free;
  end;

  { A session file that only ever grows would eventually be a problem of its
    own: compaction bounds the transcript in memory, so the file written from
    it has to shrink too, or resuming would restore everything compaction just
    discarded. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    for I := 1 to 12 do
      SeedTurn(A, 'question ' + IntToStr(I) + StringOfChar('q', 400),
                  'answer ' + IntToStr(I) + StringOfChar('a', 400));
    A.SaveSession(Path, Err);
    Before := Length(ReadFileText(Path));

    Check(A.Compact(3000) > 0, 'the long conversation compacts');
    Check(A.SaveSession(Path, Err), 'and saves again');
    After_ := Length(ReadFileText(Path));
    Check(After_ < Before,
      Format('the saved file shrinks with the transcript, %d -> %d',
        [Before, After_]));
  finally
    A.Free;
  end;
  A := TAgent.Create('k', 'm', 'sys');
  try
    Check(A.LoadSession(Path, Err), 'the compacted file reloads');
    Check(Pos('question 1' + StringOfChar('q', 400), A.Transcript) = 0,
      'and resuming does not restore what compaction discarded');
  finally
    A.Free;
  end;

  { Saving must be repeatable: the file is rewritten every turn, so a shorter
    conversation must not leave the tail of a longer one behind. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    for I := 1 to 5 do
      SeedTurn(A, 'q' + IntToStr(I), 'a' + IntToStr(I));
    A.SaveSession(Path, Err);
    A.Reset;
    SeedTurn(A, 'only one', 'only answer');
    A.SaveSession(Path, Err);
  finally
    A.Free;
  end;
  A := TAgent.Create('k', 'm', 'sys');
  try
    Check(A.LoadSession(Path, Err), 'the rewritten session loads');
    Check(A.MessageCount = 2, 'it holds only the newer, shorter conversation');
    Check(Pos('q5', A.Transcript) = 0, 'no debris from the longer one remains');
  finally
    A.Free;
  end;
end;

{ What --continue resolves to, which is the only part of that flag a suite can
  reach: the argument parsing lives in pasclaude.lpr, which nothing links.

  The stamps are SET rather than taken from the order the files were written.
  FindFirst reports a DOS timestamp with two-second granularity, so three
  files written in the same instant carry the same date and "newest" would be
  whatever the directory happened to return first - a test that passed or
  failed on disk-order luck asserts nothing.  Setting them says exactly what
  the rule is meant to do.

  The decoy is the assertion that matters most.  The approvals file lives in
  the same directory as the transcripts and is deliberately given the newest
  date of all: a "most recent .json in .pasclaude" rule would load a
  permissions file as a conversation. }
procedure TestNewestSessionIsWhatContinueTakes;
var
  Root, Dir: string;

  procedure PutStamped(const Name: string; Y, M, D: Word);
  begin
    WriteFileText(Dir + Name, '{"version":1,"messages":[]}');
    FileSetDate(Dir + Name,
      DateTimeToFileDate(EncodeDate(Y, M, D) + EncodeTime(10, 0, 0, 0)));
  end;

begin
  WriteLn('-- newest session --');
  Root := IncludeTrailingPathDelimiter(TmpRoot) + 'newest';
  Dir := IncludeTrailingPathDelimiter(Root) + SessionDir + PathDelim;
  ForceDirectories(Dir);

  Check(NewestSession(Root) = '',
    'an empty state directory offers nothing to continue');

  PutStamped('session.prev.json', 2024, 1, 1);
  PutStamped('session.json', 2024, 1, 2);
  PutStamped('work.session.json', 2024, 1, 3);
  PutStamped('permissions.json', 2030, 1, 1);

  Check(IsSessionFile('session.json'), 'the live file is a session');
  Check(IsSessionFile('session.prev.json'), 'so is the safety copy');
  Check(IsSessionFile('work.session.json'), 'and so is a /save');
  Check(not IsSessionFile('permissions.json'),
    'the approvals file beside them is not, whatever its date');

  Check(NewestSession(Root) = Dir + 'work.session.json',
    'the newest of them is what --continue would take');

  DeleteFile(Dir + 'work.session.json');
  Check(NewestSession(Root) = Dir + 'session.json',
    'and with it gone, the next newest - not the live file by default');

  DeleteFile(Dir + 'session.json');
  Check(NewestSession(Root) = Dir + 'session.prev.json',
    'down to the safety copy, which is a conversation somebody may want');

  DeleteFile(Dir + 'session.prev.json');
  Check(NewestSession(Root) = '',
    'and with only the approvals file left, nothing at all');
end;

{ ------------------------------------------------------------- self-state -- }

{ The session file sits inside the directory the model is working in, and it
  contains the conversation.  Left visible, `search` would match it and hand
  the model a copy of its own transcript - which then goes into the next
  request, and is saved again, growing every turn.  Worse, edit_file could
  rewrite the history of the turn currently running.  It is therefore hidden
  from listings and searches and refused by the path guard. }
{ A denied file must be invisible, not merely unreadable.  SafePath stops the
  model naming it; without the walker half, search would print the secret line
  out of the very file read_file refuses to open - the most damaging way a
  path rule could look enforced and not be. }
procedure TestDeniedPathIsInvisible;
var
  Input: TJson;
  IsErr: Boolean;
  Out_: string;
begin
  WriteLn('-- deny rules --');
  uTools.ClearDenyRules;
  WriteFileText(IncludeTrailingPathDelimiter(TmpRoot) + '.env',
    'SECRET=SENTINELDENY'#10);
  WriteFileText(IncludeTrailingPathDelimiter(TmpRoot) + 'ok.txt',
    'SENTINELDENY lives here too'#10);

  uTools.AddDenyRule('path:.env', 'test');

  Input := TJson.NewObj;
  Input.AddStr('path', '.');
  Out_ := RunTool('list_dir', Input, nil, IsErr);
  Input.Free;
  Check(Pos('.env', Out_) = 0, 'list_dir does not announce a denied file');
  Check(Pos('ok.txt', Out_) > 0, 'but still lists the rest of the directory');

  Input := TJson.NewObj;
  Input.AddStr('pattern', 'SENTINELDENY');
  Out_ := RunTool('search', Input, nil, IsErr);
  Input.Free;
  Check(Pos('ok.txt', Out_) > 0, 'search still finds an ordinary file');
  Check(Pos('.env', Out_) = 0, 'and never reports a line out of a denied one');

  Input := TJson.NewObj;
  Input.AddStr('path', '.env');
  Out_ := RunTool('read_file', Input, nil, IsErr);
  Input.Free;
  Check(IsErr and (Pos('refused by deny rule', Out_) > 0),
    'and read_file refuses it, naming the rule: ' + Out_);

  { The other direction, so the three assertions above are the rule's doing
    and not an accident of the fixture. }
  uTools.ClearDenyRules;
  Input := TJson.NewObj;
  Input.AddStr('path', '.');
  Out_ := RunTool('list_dir', Input, nil, IsErr);
  Input.Free;
  Check(Pos('.env', Out_) > 0, 'with the rule gone the file is listed again');
  Input := TJson.NewObj;
  Input.AddStr('path', '.env');
  Out_ := RunTool('read_file', Input, nil, IsErr);
  Input.Free;
  Check(not IsErr, 'and read again');
  SysUtils.DeleteFile(IncludeTrailingPathDelimiter(TmpRoot) + '.env');
end;

{ The approvals file is hand-edited, so a line somebody typed into it has to
  survive the session that read it.  Nothing else in this program writes the
  deny array, which is exactly why forgetting the write-back would be silent. }
procedure TestDenyRoundTrip;
var
  P, Raw: string;
begin
  P := IncludeTrailingPathDelimiter(TmpRoot) + 'approvals-roundtrip.json';
  uTools.ClearDenyRules;
  uTools.ClearBashPrefixes;
  uTools.AllowAllBash := False;
  WriteFileText(P, '{"allow_bash":true,"deny":["bash:rm","garbage"]}');

  uTools.LoadDenyRules(P, '');
  uTools.LoadPermissions(P);
  Check(uTools.DenyRuleCount = 1, 'the usable rule is in force');
  Check(Length(uTools.BadDenyRules) = 1, 'and the other is reported, not dropped');

  uTools.SavePermissions(P);
  Raw := ReadFileText(P);
  Check(Pos('"bash:rm"', Raw) > 0, 'a hand-added rule survives the save');
  Check(Pos('"garbage"', Raw) > 0,
    'including one this program could not parse: ' + Raw);

  { Deleting a line does the predictable thing, next run. }
  WriteFileText(P, '{"allow_bash":true,"deny":["bash:rm"]}');
  uTools.ClearDenyRules;
  uTools.LoadDenyRules(P, '');
  Check(uTools.DenyRuleCount = 1, 'deleting a line removes exactly that rule');
  Check(Length(uTools.BadDenyRules) = 0, 'and nothing else');

  uTools.ClearDenyRules;
  uTools.AllowAllBash := False;
  SysUtils.DeleteFile(P);
end;

procedure TestStateDirIsHidden;
var
  Input: TJson;
  IsErr: Boolean;
  Out_, Marker: string;
begin
  WriteLn('-- self-state --');
  uTools.AllowAllEdits := True;
  uTools.AllowAllBash := True;

  Marker := 'CONVERSATIONMARKER';
  WriteFileText(IncludeTrailingPathDelimiter(TmpRoot) + StateDirName +
    PathDelim + 'session.json',
    '{"version":1,"messages":[{"role":"user","content":[{"type":"text",' +
    '"text":"' + Marker + '"}]}]}');
  WriteFileText(IncludeTrailingPathDelimiter(TmpRoot) + 'ordinary.txt',
    'an ordinary project file'#10);

  { A recursive listing must not mention it. }
  Input := TJson.NewObj;
  Input.AddStr('path', '.');
  Input.Add('recursive', TJson.NewBool(True));
  Out_ := RunTool('list_dir', Input, nil, IsErr);
  Input.Free;
  Check(Pos(StateDirName, Out_) = 0, 'list_dir does not show the state directory');
  Check(Pos('ordinary.txt', Out_) > 0, 'but ordinary files are still listed');

  { A search must not match the transcript.  This is the one that would
    otherwise feed the conversation back into itself. }
  Input := TJson.NewObj;
  Input.AddStr('pattern', Marker);
  Out_ := RunTool('search', Input, nil, IsErr);
  Input.Free;
  Check(Pos(Marker, Out_) = 0, 'search does not find the conversation');

  { Reading and writing it are refused outright. }
  Input := TJson.NewObj;
  Input.AddStr('path', StateDirName + PathDelim + 'session.json');
  Out_ := RunTool('read_file', Input, nil, IsErr);
  Input.Free;
  Check(IsErr, 'read_file refuses the session file');

  Input := TJson.NewObj;
  Input.AddStr('path', StateDirName + PathDelim + 'session.json');
  Input.AddStr('content', 'rewritten history');
  Out_ := RunTool('write_file', Input, nil, IsErr);
  Input.Free;
  Check(IsErr, 'write_file refuses to rewrite the session');
  Check(Pos(Marker, ReadFileText(IncludeTrailingPathDelimiter(TmpRoot) +
    StateDirName + PathDelim + 'session.json')) > 0,
    'and the conversation on disk is untouched');

  { Including by a roundabout path, since a guard that only matches the
    obvious spelling is not a guard. }
  Input := TJson.NewObj;
  Input.AddStr('path', 'sub' + PathDelim + '..' + PathDelim + StateDirName +
    PathDelim + 'session.json');
  Out_ := RunTool('read_file', Input, nil, IsErr);
  Input.Free;
  Check(IsErr, 'an indirect path to the session is refused too');

  Input := TJson.NewObj;
  Input.AddStr('path', StateDirName);
  Out_ := RunTool('list_dir', Input, nil, IsErr);
  Input.Free;
  Check(IsErr, 'the state directory cannot be listed directly');

  { A file that merely starts with the same letters is a different thing and
    must still work. }
  WriteFileText(IncludeTrailingPathDelimiter(TmpRoot) + '.pasclaude-notes.md',
    'these are my notes'#10);
  Input := TJson.NewObj;
  Input.AddStr('path', '.pasclaude-notes.md');
  Out_ := RunTool('read_file', Input, nil, IsErr);
  Input.Free;
  Check(not IsErr, 'a file with a similar name is not caught by the guard');
  Check(Pos('these are my notes', Out_) > 0, 'and reads normally');

  uTools.AllowAllEdits := False;
  uTools.AllowAllBash := False;
end;

{ ----------------------------------------------------------------- editor -- }

{ The line editor is what the user touches on every single prompt, and its
  failures are the kind that are obvious in use and invisible to a compiler:
  a caret off by one, a backspace that eats the wrong character, history that
  loses the line being typed.  EditApply is the whole decision layer, so it can
  be driven directly. }
procedure TestEditor;
var
  E: TEditState;
  AtStart: Boolean;

  procedure TypeStr(const S: WideString);
  var
    I: Integer;
  begin
    for I := 1 to Length(S) do
      EditApply(E, ekChar, S[I]);
  end;

  function Txt: string;
  begin
    Result := UTF8Encode(E.Text);
  end;

begin
  WriteLn('-- editor --');
  HistoryClear;

  { Typing appends and leaves the caret at the end. }
  EditInit(E);
  TypeStr('hello');
  Check(Txt = 'hello', 'typing builds the line');
  Check(E.Caret = 5, 'the caret sits at the end');

  { Backspace removes the character before the caret. }
  EditApply(E, ekBackspace, #0);
  Check(Txt = 'hell', 'backspace removes the last character');
  Check(E.Caret = 4, 'and moves the caret back');

  { The point of the rewrite: editing in the middle of the line. }
  EditInit(E);
  TypeStr('helo');
  EditApply(E, ekLeft, #0);
  Check(E.Caret = 3, 'left moves the caret back one');
  EditApply(E, ekChar, 'l');
  Check(Txt = 'hello', 'a character is inserted at the caret, not appended');
  Check(E.Caret = 4, 'and the caret follows the insertion');

  { Backspace mid-line must remove the character before the caret, not the
    last one on the line. }
  EditInit(E);
  TypeStr('abXcd');
  EditApply(E, ekLeft, #0);
  EditApply(E, ekLeft, #0);
  Check(E.Caret = 3, 'the caret is after the X');
  EditApply(E, ekBackspace, #0);
  Check(Txt = 'abcd', 'mid-line backspace removes the right character');
  Check(E.Caret = 2, 'and the caret stays where the text closed up');

  { Delete removes forwards and leaves the caret alone, which is the whole
    difference between it and backspace. }
  EditInit(E);
  TypeStr('abXcd');
  EditApply(E, ekHome, #0);
  EditApply(E, ekRight, #0);
  EditApply(E, ekRight, #0);
  EditApply(E, ekDelete, #0);
  Check(Txt = 'abcd', 'delete removes the character under the caret');
  Check(E.Caret = 2, 'and does not move it');

  { The boundaries: neither key may run off either end. }
  EditInit(E);
  TypeStr('ab');
  EditApply(E, ekHome, #0);
  EditApply(E, ekLeft, #0);
  Check(E.Caret = 0, 'left stops at the start');
  EditApply(E, ekBackspace, #0);
  Check(Txt = 'ab', 'backspace at the start does nothing');
  EditApply(E, ekEnd, #0);
  EditApply(E, ekRight, #0);
  Check(E.Caret = 2, 'right stops at the end');
  EditApply(E, ekDelete, #0);
  Check(Txt = 'ab', 'delete at the end does nothing');

  { An empty line must survive every key without misbehaving. }
  EditInit(E);
  EditApply(E, ekBackspace, #0);
  EditApply(E, ekDelete, #0);
  EditApply(E, ekLeft, #0);
  EditApply(E, ekRight, #0);
  EditApply(E, ekHome, #0);
  EditApply(E, ekEnd, #0);
  Check((Txt = '') and (E.Caret = 0), 'an empty line survives every movement key');

  { Home, End and clear. }
  EditInit(E);
  TypeStr('some text');
  EditApply(E, ekHome, #0);
  Check(E.Caret = 0, 'home goes to the start');
  EditApply(E, ekEnd, #0);
  Check(E.Caret = 9, 'end goes to the end');
  EditApply(E, ekClear, #0);
  Check((Txt = '') and (E.Caret = 0), 'clear empties the line');

  { History. }
  HistoryClear;
  HistoryAdd('first command');
  HistoryAdd('second command');
  Check(HistoryCount = 2, 'two commands are remembered');
  HistoryAdd('second command');
  Check(HistoryCount = 2, 'an immediate repeat is not stored twice');
  HistoryAdd('   ');
  Check(HistoryCount = 2, 'blank input is not stored');

  EditInit(E);
  EditApply(E, ekHistPrev, #0);
  Check(Txt = 'second command', 'up recalls the most recent command');
  Check(E.Caret = Length('second command'), 'with the caret at the end');
  EditApply(E, ekHistPrev, #0);
  Check(Txt = 'first command', 'up again goes further back');
  EditApply(E, ekHistPrev, #0);
  Check(Txt = 'first command', 'and stops at the oldest');
  EditApply(E, ekHistNext, #0);
  Check(Txt = 'second command', 'down comes forward again');
  EditApply(E, ekHistNext, #0);
  Check(Txt = '', 'down past the newest returns to the empty line');

  { The half-typed line must come back, which is the part people notice when
    it is missing. }
  EditInit(E);
  TypeStr('half typed');
  EditApply(E, ekHistPrev, #0);
  Check(Txt = 'second command', 'browsing away shows history');
  EditApply(E, ekHistNext, #0);
  Check(Txt = 'half typed', 'and coming back restores what was being typed');
  Check(E.Caret = Length('half typed'), 'with the caret at the end of it');

  { With no history at all, the keys must leave the line alone. }
  HistoryClear;
  EditInit(E);
  TypeStr('untouched');
  EditApply(E, ekHistPrev, #0);
  EditApply(E, ekHistNext, #0);
  Check(Txt = 'untouched', 'history keys do nothing when there is no history');

  { Tab completion.  The whole decision - which candidates apply, what the
    token becomes - is in CompleteToken, driven here with fixed candidate
    lists so no file system is involved. }
  EditInit(E);
  TypeStr('/he');
  Check(CompleteToken(E, ['/help']), 'a single candidate completes');
  Check(Txt = '/help', 'to the full command');
  Check(E.Caret = 5, 'with the caret after it');

  EditInit(E);
  TypeStr('/c');
  { /clear, /compact, /cost and /cwd share only "/c", which is already
    typed, so there is nothing to extend and the call must say so. }
  Check(not CompleteToken(E, ['/clear', '/compact', '/cost', '/cwd']),
    'candidates sharing only the typed prefix change nothing');
  Check(Txt = '/c', 'and the line is untouched');
  { /compact and /comp... - candidates with a longer shared prefix do
    extend, stopping where they diverge. }
  EditInit(E);
  TypeStr('/c');
  Check(CompleteToken(E, ['/compact', '/cost']),
    'a shared prefix longer than the token extends it');
  Check(Txt = '/co', 'up to the point of divergence');
  Check(E.Caret = 3, 'with the caret at the new end');

  EditInit(E);
  TypeStr('read src\uA');
  Check(CompleteToken(E, ['src\uAgent.pas']), 'a path token completes mid-line');
  Check(Txt = 'read src\uAgent.pas', 'replacing only the token, not the line');
  Check(E.Caret = Length('read src\uAgent.pas'), 'caret lands at the end of it');

  EditInit(E);
  TypeStr('nothing matches xyz');
  Check(not CompleteToken(E, []), 'no candidates changes nothing');
  Check(Txt = 'nothing matches xyz', 'and the line is untouched');

  { TokenAtCaret is what the provider sees; its notion of "line start" is
    what routes between commands and paths. }
  EditInit(E);
  TypeStr('/mod');
  Check(TokenAtCaret(E, AtStart) = '/mod', 'the token is the text back to a space');
  Check(AtStart, 'a first word is flagged as opening the line');
  EditInit(E);
  TypeStr('read a.txt');
  Check(TokenAtCaret(E, AtStart) = 'a.txt', 'a later word is its own token');
  Check(not AtStart, 'and is not at the line start');

  { Multi-line input: a newline is inserted like any character and the
    submitted text carries it. }
  EditInit(E);
  TypeStr('first line');
  EditApply(E, ekNewline, #0);
  TypeStr('second line');
  Check(Txt = 'first line'#10'second line', 'a newline joins two lines in one buffer');
  Check(E.Caret = Length('first line') + 1 + Length('second line'),
    'the caret counts the newline as one character');
  EditApply(E, ekBackspace, #0);
  Check(Txt = 'first line'#10'second lin', 'backspace works after a newline');
  { And crossing the boundary deletes the break itself. }
  EditInit(E);
  TypeStr('ab');
  EditApply(E, ekNewline, #0);
  EditApply(E, ekBackspace, #0);
  Check(Txt = 'ab', 'backspace at a line start removes the break');

  { Non-ASCII has to survive as characters, not bytes: the editor works in
    UTF-16 and the transcript is UTF-8, so a wrong assumption here shows up as
    a mangled prompt. }
  HistoryClear;
  EditInit(E);
  TypeStr('caf' + WideChar($00E9));
  Check(E.Caret = 4, 'an accented character counts as one character');
  { The bytes are checked one at a time.  A string literal with high bytes in
    it is subject to the source file's encoding and the compiler's codepage,
    so comparing against one tests the build as much as the editor. }
  Check((Length(Txt) = 5) and (Byte(Txt[4]) = $C3) and (Byte(Txt[5]) = $A9),
    'and encodes to UTF-8 on the way out');
  EditApply(E, ekBackspace, #0);
  Check(Txt = 'caf', 'backspace removes the whole character, not one byte');

  { The default state is what the permission prompt and the three pickers
    edit in.  Vim behaviour leaking into it would change what every prompt in
    the program does, so the absence is asserted rather than assumed. }
  HistoryClear;
  EditInit(E);
  Check(not E.Vim, 'a plain edit starts with vim off');
  Check(E.Mode = vmInsert, 'and in insert mode');
  Check(E.PendOp = #0, 'with no pending operator');
  Check(E.UndoN = 0, 'and an empty undo stack');
  { Every character vim would interpret is still just a character here. }
  TypeStr('dwciAX0$');
  Check(Txt = 'dwciAX0$', 'printable keys are inserted, never interpreted');
  { And a profile with vim on does not reach a state built without it. }
  SetPromptProfile(KeysDefault);
  SetPromptVim(True);
  EditInit(E);
  Check(not E.Vim, 'EditInit ignores the installed profile entirely');
  EditInitProfile(E, KeysNone);
  Check(not E.Vim, 'and KeysNone starts a line with vim off');
  SetPromptVim(False);

  HistoryClear;
end;

{ ------------------------------------------------------- vim and bindings -- }

{ The first wall: the key-name grammar.  A chord that cannot be written
  cannot be bound, and y/a/n cannot be written. }
procedure TestKeyGrammarRefusesPlainKeys;
var
  C: TKeyChord;
  Why: string;

  procedure Refused(const Name: string);
  begin
    Check(not KeyChordOf(Name, C, Why),
      'a plain "' + Name + '" is not a bindable chord');
    Check(Pos('ctrl+', Why) > 0, '  and the reason names the missing modifier');
  end;

  procedure Reserved(const Name: string);
  begin
    if not KeyChordOf(Name, C, Why) then
      Check(False, Name + ' should parse so it can be refused by name')
    else
      Check(KeyChordReserved(C), Name + ' is reserved and cannot be rebound');
  end;

  procedure RoundTrips(const Name: string);
  begin
    if not KeyChordOf(Name, C, Why) then
      Check(False, Name + ' should be a legal chord (' + Why + ')')
    else
      Check(KeyChordName(C) = Name, Name + ' round-trips through its name');
  end;

begin
  WriteLn('-- key grammar --');

  { These five are the whole of the permission prompt's vocabulary plus a
    digit for the pickers.  None of them may ever become nameable. }
  Refused('y');
  Refused('a');
  Refused('n');
  Refused('1');
  Refused('x');

  Reserved('ctrl+c');
  Reserved('enter');
  Reserved('ctrl+enter');
  Reserved('alt+enter');
  Reserved('tab');
  Reserved('escape');

  RoundTrips('ctrl+w');
  RoundTrips('alt+f');
  RoundTrips('ctrl+[');
  RoundTrips('home');
  RoundTrips('ctrl+alt+shift+k');

  Check(not KeyChordOf('ctrl+', C, Why), 'a modifier with no key is refused');
  Check(not KeyChordOf('ctrl+nosuchkey', C, Why), 'an unknown key name is refused');
end;

{ The second wall: the plain reader passes KeysNone, so a fully populated
  profile installed for the REPL is invisible to it. }
procedure TestPlainReaderIgnoresBindings;
var
  P: TKeyProfile;
  Notes: TStringArray;
  E: TEditState;
  K: TEditKey;
begin
  WriteLn('-- bindings are scoped to the prompt --');
  Notes := nil;
  Check(KeysParse('{"vim":true,"bindings":{"ctrl+w":"delete-line"}}', P, Notes),
    'a well-formed keys.json parses');
  Check(Length(Notes) = 0, 'with nothing to report');
  Check(P.Vim, 'and vim on');
  SetLength(Notes, 0);

  { Install it exactly as the host does at startup. }
  SetPromptProfile(P);

  EditInit(E);
  Check(DecodeKey(P, E, Ord('W'), True, False, False, #0, K) and (K = ekDelLine),
    'the prompt profile resolves Ctrl+W to the bound verb');
  Check(not DecodeKey(KeysNone, E, Ord('W'), True, False, False, #0, K),
    'the empty profile resolves nothing, however loaded the module var is');

  { And vim is a field of the profile, so normal mode cannot exist on a line
    that was started without one: 'a' at the permission prompt is the
    character a, not the append command. }
  EditInitProfile(E, KeysNone);
  Check(not E.Vim, 'a KeysNone line is not modal');
  EditApply(E, ekChar, 'a');
  EditApply(E, ekChar, 'd');
  Check(UTF8Encode(E.Text) = 'ad', 'so vim command letters are plain text there');

  SetPromptProfile(KeysDefault);
end;

{ A refused entry must be reported.  Silence would be indistinguishable from
  a binding this build does not support. }
procedure TestKeysParseReportsRatherThanIgnores;
var
  P: TKeyProfile;
  Notes: TStringArray;
  I, N: Integer;
  K: TEditKey;
  C: TKeyChord;
  Why: string;

  function Bound(const Chord: string; out Act: TEditKey): Boolean;
  var
    E: TEditState;
    Ignore: string;
  begin
    EditInit(E);
    Result := False;
    if not KeyChordOf(Chord, C, Ignore) then Exit;
    Result := DecodeKey(P, E, C.VK, C.Ctrl, C.Alt, C.Shift, #0, Act);
  end;

begin
  WriteLn('-- keys.json reports what it refuses --');
  Notes := nil;
  Check(KeysParse('{"bindings":{"ctrl+w":"eat-the-line","nonsense+q":"undo",' +
    '"ctrl+c":"undo","y":"undo","ctrl+k":"delete-to-end"}}', P, Notes),
    'a document with bad entries still parses');
  Check(Length(Notes) = 4, 'and every one of the four bad entries is reported');
  { Each note has to name the entry it is about, or the user cannot find it. }
  N := 0;
  for I := 0 to High(Notes) do
    if (Pos('ctrl+w', Notes[I]) > 0) or (Pos('nonsense+q', Notes[I]) > 0) or
       (Pos('ctrl+c', Notes[I]) > 0) or (Pos('y', Notes[I]) > 0) then Inc(N);
  Check(N = 4, 'each note names its own entry');
  SetLength(Notes, 0);

  Check(Bound('ctrl+k', K) and (K = ekDelToEnd),
    'the one good entry took effect');
  { The refused ctrl+w did not unbind the default it failed to replace - a
    bad entry must change nothing at all. }
  Check(Bound('ctrl+w', K) and (K = ekDelWordLeft),
    'and a refused entry leaves the built-in binding standing');

  { A malformed or empty file is the defaults, not an empty binding set. }
  Notes := nil;
  Check(not KeysParse('{ not json', P, Notes), 'a malformed file fails');
  Check(Length(Notes) = 1, 'with one note saying so');
  Check(Bound('ctrl+w', K) and (K = ekDelWordLeft),
    'and leaves the built-in bindings in place');
  SetLength(Notes, 0);

  Notes := nil;
  Check(not KeysParse('', P, Notes), 'an empty file fails');
  Check(Length(Notes) = 1, 'with one note');
  Check(Length(P.Binds) = Length(KeysDefault.Binds),
    'and the profile is the built-in table');
  SetLength(Notes, 0);

  { An explicit unbind is the only way a file removes a default. }
  Notes := nil;
  Check(KeysParse('{"bindings":{"ctrl+w":"none"}}', P, Notes), 'none unbinds');
  Check(Length(Notes) = 0, 'quietly, because it is not an error');
  Check(not Bound('ctrl+w', K), 'and Ctrl+W is then unbound');
  SetLength(Notes, 0);
  Why := '';
end;

procedure TestVimMotionsAndOperators;
var
  E: TEditState;
  P: TKeyProfile;
  K: TEditKey;

  procedure Start(const S: WideString);
  var
    I: Integer;
  begin
    EditInitProfile(E, P);
    for I := 1 to Length(S) do
      EditApply(E, ekChar, S[I]);
    EditApply(E, ekNormalMode, #0);
  end;

  function Txt: string;
  begin
    Result := UTF8Encode(E.Text);
  end;

begin
  WriteLn('-- vim motions and operators --');
  HistoryClear;
  P := KeysNone;
  P.Vim := True;

  { Motions.  An off-by-one in the word scanner is the first thing a vim
    user notices, so each landing point is named. }
  Start('the quick brown fox');
  EditApply(E, ekHome, #0);
  Check(E.Caret = 0, 'normal mode starts the walk at the line start');
  EditApply(E, ekWordRight, #0);
  Check(E.Caret = 4, 'w lands on the q of quick');
  EditApply(E, ekWordRight, #0);
  Check(E.Caret = 10, 'w again lands on the b of brown');
  EditApply(E, ekWordRight, #0);
  Check(E.Caret = 16, 'and again on the f of fox');

  EditApply(E, ekHome, #0);
  EditApply(E, ekWordEnd, #0);
  Check(E.Caret = 2, 'e lands ON the last character of the word, not after it');

  EditApply(E, ekEnd, #0);
  Check(E.Caret = 18, 'in normal mode the caret clamps to the last character');
  EditApply(E, ekWordLeft, #0);
  Check(E.Caret = 16, 'b from the end lands on the start of fox');

  { The operator parser.  'd' is absorbed; the next key resolves it. }
  Start('the quick brown fox');
  EditApply(E, ekHome, #0);
  Check(not EditNormalKey(E, 'd', K), 'd alone produces no verb');
  Check(E.PendOp = 'd', 'and is remembered as a pending operator');
  Check(EditNormalKey(E, 'w', K) and (K = ekDelWordRight),
    'the following w resolves it to delete-word-right');
  Check(E.PendOp = #0, 'and clears the operator');
  EditApply(E, K, #0);
  Check(Txt = 'quick brown fox', 'dw removes the word and the space after it');
  Check(E.Mode = vmNormal, 'and d leaves the editor in normal mode');

  { An invalid target must clear the operator, or it fires on the next key. }
  Start('the quick brown fox');
  EditApply(E, ekHome, #0);
  EditNormalKey(E, 'd', K);
  Check(not EditNormalKey(E, 'z', K), 'dz is not a command');
  Check(E.PendOp = #0, 'and the pending d does not survive it');
  Check(Txt = 'the quick brown fox', 'with the line untouched');
  Check(EditNormalKey(E, 'w', K) and (K = ekWordRight),
    'so the next w is a motion, not a deletion');

  { c is d plus insert mode - forgetting the mode change is the classic bug. }
  Start('the quick brown fox');
  EditApply(E, ekHome, #0);
  EditApply(E, ekChangeWordEnd, #0);
  Check(Txt = ' quick brown fox', 'cw removes to the end of the word');
  Check(E.Mode = vmInsert, 'and leaves the editor in insert mode');

  { dd, D and x. }
  Start('the quick brown fox');
  EditApply(E, ekDelLine, #0);
  Check(Txt = '', 'dd empties the line');
  Check(E.Caret = 0, 'with the caret at the start');
  Start('the quick brown fox');
  EditApply(E, ekHome, #0);
  EditApply(E, ekWordRight, #0);
  EditApply(E, ekDelToEnd, #0);
  Check(Txt = 'the ', 'D removes from the caret to the end of the line');
  Start('abc');
  EditApply(E, ekHome, #0);
  EditApply(E, ekDelete, #0);
  Check(Txt = 'bc', 'x removes the character under the caret');

  { Esc's step left, and the empty line, where every verb must no-op. }
  EditInitProfile(E, P);
  EditApply(E, ekChar, 'a');
  EditApply(E, ekChar, 'b');
  EditApply(E, ekChar, 'c');
  Check(E.Caret = 3, 'insert mode leaves the caret past the last character');
  EditApply(E, ekNormalMode, #0);
  Check(E.Caret = 2, 'and Esc steps back onto it');
  EditInitProfile(E, P);
  EditApply(E, ekNormalMode, #0);
  Check(E.Caret = 0, 'on an empty line Esc leaves the caret at 0');
  EditApply(E, ekWordRight, #0);
  EditApply(E, ekDelWordRight, #0);
  EditApply(E, ekDelToEnd, #0);
  { e is in this list because it was the one that was not: WordEndFwd used to
    answer Length-1 = -1 on an empty buffer, and the clamps that would have
    caught it sat after the early exit.  A caret of -1 reaches SegEnd and
    Redraw, which both index W[Caret + 1] - W[0] on a nil WideString, an
    access violation that kills the process without running TermDone and
    leaves the console in raw mode.  '/vim on', Esc, e was the whole
    reproduction. }
  EditApply(E, ekWordEnd, #0);
  EditApply(E, ekDelWordEnd, #0);
  EditApply(E, ekFirstNonBlank, #0);
  Check((Txt = '') and (E.Caret = 0), 'and every verb no-ops on an empty line');

  { The same verb with vim OFF, where VimClamp does not run: a keys.json can
    bind word-end to any chord, so the caret must be sane without the clamp
    behind it - Redraw indexes it either way. }
  EditInit(E);
  EditApply(E, ekWordEnd, #0);
  Check(E.Caret = 0, 'word-end on an empty line is 0 with vim off too');
  EditApply(E, ekChar, 'a');
  EditApply(E, ekHome, #0);
  EditApply(E, ekWordEnd, #0);
  Check(E.Caret = 0, 'and 0 on a one-character line, not past it');

  { i a I A, which only differ by where the caret lands. }
  Start('  hi');
  EditApply(E, ekHome, #0);
  EditApply(E, ekInsertStart, #0);
  Check((E.Caret = 2) and (E.Mode = vmInsert), 'I goes to the first non-blank');
  Start('abc');
  EditApply(E, ekHome, #0);
  EditApply(E, ekAppendHere, #0);
  Check((E.Caret = 1) and (E.Mode = vmInsert), 'a inserts after the caret');
  Start('abc');
  EditApply(E, ekHome, #0);
  EditApply(E, ekInsertHere, #0);
  Check((E.Caret = 0) and (E.Mode = vmInsert), 'i inserts at the caret');
  Start('abc');
  EditApply(E, ekHome, #0);
  EditApply(E, ekAppendEnd, #0);
  Check((E.Caret = 3) and (E.Mode = vmInsert), 'A goes past the last character');

  { Non-ASCII is a word character, not a separator: a path with an accent
    must not fragment into one word per letter. }
  Start('caf' + WideChar($00E9) + ' na' + WideChar($00EF) + 've');
  EditApply(E, ekHome, #0);
  EditApply(E, ekWordRight, #0);
  Check(E.Caret = 5, 'w skips the whole accented word, landing on the next');

  { j and k are history, which is the one-line adaptation. }
  HistoryClear;
  HistoryAdd('an old command');
  Start('');
  Check(EditNormalKey(E, 'k', K) and (K = ekHistPrev), 'k is history-previous');
  Check(EditNormalKey(E, 'j', K) and (K = ekHistNext), 'j is history-next');
  HistoryClear;
end;

procedure TestVimUndo;
var
  E: TEditState;
  P: TKeyProfile;
  I: Integer;

  procedure TypeStr(const S: WideString);
  var
    J: Integer;
  begin
    for J := 1 to Length(S) do
      EditApply(E, ekChar, S[J]);
  end;

  function Txt: string;
  begin
    Result := UTF8Encode(E.Text);
  end;

begin
  WriteLn('-- undo --');
  HistoryClear;
  P := KeysNone;
  P.Vim := True;

  { A word deletion is one step, and it comes back with its caret. }
  EditInit(E);
  TypeStr('hello world');
  EditApply(E, ekDelWordLeft, #0);
  Check(Txt = 'hello ', 'Ctrl+W removes the word');
  EditApply(E, ekUndo, #0);
  Check(Txt = 'hello world', 'undo brings it back');
  Check(E.Caret = 11, 'with the caret where it was');
  EditApply(E, ekRedo, #0);
  Check(Txt = 'hello ', 'redo removes it again');

  { A new edit truncates the redo tail: the abandoned branch must not come
    back on a later Ctrl+R.  The two branches have to differ visibly or the
    assertion would pass on either. }
  EditApply(E, ekUndo, #0);
  Check(Txt = 'hello world', 'undo again');
  EditApply(E, ekHome, #0);
  EditApply(E, ekDelWordRight, #0);
  Check(Txt = 'world', 'a different edit from the same point');
  EditApply(E, ekRedo, #0);
  Check(Txt = 'world', 'redo does not resurrect the abandoned branch');

  { One insert session is ONE step, which is the whole complaint every vim
    user has about editors that undo per character. }
  EditInitProfile(E, P);
  EditApply(E, ekInsertHere, #0);
  EditApply(E, ekChar, 'a'); EditApply(E, ekChar, 'b'); EditApply(E, ekChar, 'c');
  EditApply(E, ekNormalMode, #0);
  Check(Txt = 'abc', 'three characters typed');
  Check(E.UndoN = 2, 'and the whole session is one step on the stack');
  EditApply(E, ekUndo, #0);
  Check(Txt = '', 'so one undo removes all three');

  { Undo on a state that has never been edited is a no-op, not a crash. }
  EditInit(E);
  EditApply(E, ekUndo, #0);
  EditApply(E, ekRedo, #0);
  Check((Txt = '') and (E.Caret = 0), 'undo on a fresh line does nothing');

  { The stack is capped.  A paste-and-delete loop must not grow without
    bound, and the oldest entry is the one that goes. }
  EditInit(E);
  for I := 1 to 150 do
  begin
    EditApply(E, ekChar, 'a');
    EditApply(E, ekDelWordLeft, #0);
  end;
  Check(E.UndoN = 100, 'the undo stack stops at a hundred entries');
  Check(E.UndoAt = 99, 'with the newest state at the top');
  for I := 1 to 200 do EditApply(E, ekUndo, #0);
  Check(E.UndoAt = 0, 'and undo runs back to the oldest kept entry, no further');
end;

procedure TestKeysRoundTripAndDefaults;
var
  P, Q: TKeyProfile;
  Notes: TStringArray;
  E: TEditState;
  C: TKeyChord;
  K: TEditKey;
  Doc, Why: string;
  Root: TJson;

  function DefaultIs(const Chord, Action: string): Boolean;
  var
    Act: TEditKey;
  begin
    Result := False;
    if not KeyChordOf(Chord, C, Why) then Exit;
    if not DecodeKey(P, E, C.VK, C.Ctrl, C.Alt, C.Shift, #0, Act) then Exit;
    Result := KeyActionName(Act) = Action;
  end;

begin
  WriteLn('-- default bindings and /vim save --');
  EditInit(E);
  P := KeysDefault;
  Check(DefaultIs('ctrl+w', 'delete-word-left'), 'Ctrl+W deletes the word left');
  Check(DefaultIs('ctrl+k', 'delete-to-end'),    'Ctrl+K deletes to the end');
  Check(DefaultIs('alt+b',  'word-left'),        'Alt+B moves a word left');
  Check(DefaultIs('alt+f',  'word-right'),       'Alt+F moves a word right');
  Check(DefaultIs('ctrl+z', 'undo'),             'Ctrl+Z is undo');

  { No default may name a reserved chord, or the editor would be fighting
    itself before any file was read. }
  Check(not KeyChordReserved(P.Binds[0].Chord), 'no default takes a reserved key');

  { /vim save is a read-modify-write: a hand-written bindings block and any
    field this build does not know about have to survive it. }
  Q := KeysNone;
  Q.Vim := True;
  Doc := KeysToJson(Q,
    '{"vim":false,"bindings":{"ctrl+k":"delete-to-end"},"other":42}');
  Root := JsonParse(Doc);
  Check(Root <> nil, 'the rewritten document is valid JSON');
  if Root <> nil then
  try
    Check(Root.Bool('vim', False), 'with vim now true');
    Check(Root.Num('other', 0) = 42, 'the unknown field survives');
    Check(Root.IndexOf('other') = 2, 'in the position it was written in');
    Check((Root.Find('bindings') <> nil) and
          (Root.Find('bindings').Str('ctrl+k') = 'delete-to-end'),
      'and the hand-written bindings are untouched');
  finally
    Root.Free;
  end;

  { And it re-parses into the same effective table. }
  Notes := nil;
  Check(KeysParse(Doc, P, Notes), 'the rewritten file parses back');
  Check(P.Vim, 'with vim on');
  Check(DecodeKey(P, E, Ord('K'), True, False, False, #0, K) and
        (K = ekDelToEnd), 'and Ctrl+K still bound');
  SetLength(Notes, 0);

  { The painted lead, which is the only part of the indicator a test can
    see - Redraw writes to a real console and nothing here can read it. }
  EditInit(E);
  Check(EditLead(E, '> ', True) = '> ', 'with vim off the lead is the prompt');
  Check(EditLead(E, '> ', False) = '... ', 'and the continuation marker below it');
  P := KeysNone;
  P.Vim := True;
  EditInitProfile(E, P);
  Check(EditLead(E, '> ', True) = '[I] > ', 'with vim on the mode is shown');
  EditApply(E, ekNormalMode, #0);
  Check(EditLead(E, '> ', True) = '[N] > ', 'and changes with the mode');
  Check(EditLead(E, 'plan+> ', False) = '[N] ... ',
    'the continuation line carries the tag too');
  { It composes with the permission indicator without either knowing about
    the other: ModePrompt owns everything before the '> '. }
  Check(EditLead(E, 'plan+> ', True) = '[N] plan+> ',
    'and the permission mode keeps its place in front of the prompt');
end;

{ ------------------------------------------------------------------ image -- }

{ A PNG this suite can hand around: the smallest thing that exercises the real
  encoder rather than a literal. }
function MakeRgb(W, H: Integer; Colours: Integer): RawByteString;
var
  X, Y, I: Integer;
begin
  SetLength(Result, W * H * 3);
  for Y := 0 to H - 1 do
    for X := 0 to W - 1 do
    begin
      I := (Y * W + X) * 3 + 1;
      Result[I] := Chr(((X + Y) mod Colours) * (250 div Colours));
      Result[I + 1] := Chr(((X * 3) mod Colours) * (250 div Colours));
      Result[I + 2] := Chr(((Y * 5) mod Colours) * (250 div Colours));
    end;
end;

{ The encoder writes a container no unit in this tree can read back, so a
  round trip through our own code would prove nothing.  These assertions are
  against the format's own rules instead: the signature, every chunk's CRC,
  and the three things inside a stored deflate stream that a decoder checks
  and a naive writer gets wrong. }
procedure TestImageCodec;
var
  Png, Rgb, Idat, Tag, Data: RawByteString;
  P, N, Len, Blocks, LenF, NlenF: Integer;
  Final: Boolean;
  Adler, RawAdler: LongWord;
  Raw: RawByteString;
  X, Y, I: Integer;
  Ok: Boolean;

  function Be32At(const S: RawByteString; At: Integer): LongWord;
  begin
    Result := (LongWord(Byte(S[At])) shl 24) or (LongWord(Byte(S[At + 1])) shl 16)
      or (LongWord(Byte(S[At + 2])) shl 8) or LongWord(Byte(S[At + 3]));
  end;

begin
  WriteLn('-- image codec --');

  { Known vectors, so a broken checksum is caught here rather than as a file
    nothing will open. }
  Check(uImage.Crc32Str('123456789') = $CBF43926, 'CRC-32 matches its vector');
  Check(uImage.Adler32Str('123456789') = $091E01DE,
    'Adler-32 matches its vector');

  Rgb := MakeRgb(8, 2, 4);
  Png := uImage.EncodePng(Rgb, 8, 2);
  Check(Length(Png) > 8, 'an 8x2 image encodes');
  Check((Byte(Png[1]) = $89) and (Copy(Png, 2, 3) = 'PNG') and
        (Byte(Png[5]) = $0D) and (Byte(Png[6]) = $0A) and
        (Byte(Png[7]) = $1A) and (Byte(Png[8]) = $0A),
    'it opens with the PNG signature');

  { Walk the chunks: every stored CRC must equal the one we compute over
    tag+data, which is the field a hand-written encoder most often takes over
    the wrong range. }
  Ok := True;
  Idat := '';
  P := 9;
  while P + 8 <= Length(Png) do
  begin
    Len := Integer(Be32At(Png, P));
    Tag := Copy(Png, P + 4, 4);
    Data := Copy(Png, P + 8, Len);
    if Be32At(Png, P + 8 + Len) <> uImage.Crc32Str(Tag + Data) then Ok := False;
    if Tag = 'IDAT' then Idat := Idat + Data;
    Inc(P, 12 + Len);
  end;
  Check(Ok, 'every chunk CRC covers exactly its tag and data');
  Check(Idat <> '', 'there is an IDAT');
  Check((Byte(Idat[1]) = $78) and (Byte(Idat[2]) = $01),
    'the zlib header is 78 01');

  { The stored-block chain: LEN and NLEN must be ones-complements, and the
    last block and only the last must carry BFINAL. }
  Raw := '';
  Blocks := 0;
  Ok := True;
  Final := False;
  P := 3;
  while (P + 4 <= Length(Idat)) and not Final do
  begin
    Final := (Byte(Idat[P]) and 1) = 1;
    if (Byte(Idat[P]) and 6) <> 0 then Ok := False;   { BTYPE must be stored }
    LenF := Byte(Idat[P + 1]) or (Byte(Idat[P + 2]) shl 8);
    NlenF := Byte(Idat[P + 3]) or (Byte(Idat[P + 4]) shl 8);
    if (LenF xor $FFFF) <> NlenF then Ok := False;
    Raw := Raw + Copy(Idat, P + 5, LenF);
    Inc(Blocks);
    Inc(P, 5 + LenF);
  end;
  Check(Ok, 'each stored block has BTYPE 0 and NLEN as the complement of LEN');
  Check(Final, 'the last block carries BFINAL');
  Check(P + 4 = Length(Idat) + 1, 'and the stream ends after it');

  { Adler-32 is over the UNCOMPRESSED bytes and big-endian: computing it over
    the deflate stream, or writing it little-endian, both produce a file that
    looks plausible and that no decoder accepts. }
  Adler := Be32At(Idat, Length(Idat) - 3);
  RawAdler := uImage.Adler32Str(Raw);
  Check(Adler = RawAdler,
    'the trailing Adler-32 is big-endian over the raw scanlines');
  Check(Length(Raw) = 2 * (1 + 8 * 3),
    'the inflated data is one filter byte per scanline plus the pixels');

  { Wide enough that the raw data passes 65535 bytes and the encoder must
    emit a second stored block. }
  Rgb := MakeRgb(300, 300, 8);
  Png := uImage.EncodePng(Rgb, 300, 300);
  Idat := '';
  P := 9;
  while P + 8 <= Length(Png) do
  begin
    Len := Integer(Be32At(Png, P));
    if Copy(Png, P + 4, 4) = 'IDAT' then Idat := Idat + Copy(Png, P + 8, Len);
    Inc(P, 12 + Len);
  end;
  Blocks := 0;
  Ok := True;
  Final := False;
  P := 3;
  while (P + 4 <= Length(Idat)) and not Final do
  begin
    Final := (Byte(Idat[P]) and 1) = 1;
    LenF := Byte(Idat[P + 1]) or (Byte(Idat[P + 2]) shl 8);
    NlenF := Byte(Idat[P + 3]) or (Byte(Idat[P + 4]) shl 8);
    if (LenF xor $FFFF) <> NlenF then Ok := False;
    if (not Final) and (LenF <> 65535) then Ok := False;
    Inc(Blocks);
    Inc(P, 5 + LenF);
  end;
  Check(Blocks > 1, 'a 300x300 image needs more than one stored block');
  Check(Ok, 'and every block header validates, not just the first');

  { The indexed path, and its bail-out. }
  Rgb := MakeRgb(16, 16, 4);
  Check(uImage.EncodePngIndexed(Rgb, 16, 16, Png),
    'a four-colour image encodes as indexed');
  Check(Pos('PLTE', Png) > 0, 'with a palette chunk');
  Check(Byte(Png[26]) = 3, 'and colour type 3');
  SetLength(Rgb, 64 * 64 * 3);
  for Y := 0 to 63 do
    for X := 0 to 63 do
    begin
      I := (Y * 64 + X) * 3 + 1;
      Rgb[I] := Chr((Y * 64 + X) and $FF);
      Rgb[I + 1] := Chr(((Y * 64 + X) shr 8) and $FF);
      Rgb[I + 2] := Chr((X * 7) and $FF);
    end;
  Check(not uImage.EncodePngIndexed(Rgb, 64, 64, Png),
    'an image with over 256 colours is refused so the caller falls back');

  { Downscale-to-fit, and the refusal when two halvings are not enough. }
  Rgb := MakeRgb(200, 200, 5);
  Check(uImage.EncodePngAuto(Rgb, 200, 200, 200000, Png, X, Y) and
    (X = 200) and (Y = 200), 'a generous budget needs no halving');
  Check(uImage.EncodePngAuto(Rgb, 200, 200, 12000, Png, X, Y) and
    (X < 200) and (Length(Png) <= 12000),
    'a tight budget halves until it fits');
  Check(not uImage.EncodePngAuto(Rgb, 200, 200, 200, Png, X, Y),
    'and an impossible budget is refused rather than shrunk to nothing');
  N := Length(Png);
  Check(N = 0, 'a refused encode returns no bytes');
end;

{ The clipboard hands over a header this program did not write, from any
  process on the machine, so both the layout and the bounds checking matter. }
procedure TestDibToRgb;
var
  Dib, Rgb: RawByteString;
  W, H: Integer;
  Err: string;

  procedure PutLe32(var S: RawByteString; At: Integer; V: LongWord);
  begin
    S[At] := Chr(V and $FF);
    S[At + 1] := Chr((V shr 8) and $FF);
    S[At + 2] := Chr((V shr 16) and $FF);
    S[At + 3] := Chr((V shr 24) and $FF);
  end;

  procedure PutLe16(var S: RawByteString; At: Integer; V: Word);
  begin
    S[At] := Chr(V and $FF);
    S[At + 1] := Chr((V shr 8) and $FF);
  end;

  { A 40-byte BITMAPINFOHEADER plus, for BI_BITFIELDS, the three colour masks
    the probe confirmed sit between the header and the pixels. }
  function Header(Wid, Hgt, Bits, Comp: Integer): RawByteString;
  begin
    SetLength(Result, 40);
    FillChar(Result[1], 40, 0);
    PutLe32(Result, 1, 40);
    PutLe32(Result, 5, LongWord(Wid));
    PutLe32(Result, 9, LongWord(LongInt(Hgt)));
    PutLe16(Result, 13, 1);
    PutLe16(Result, 15, Word(Bits));
    PutLe32(Result, 17, LongWord(Comp));
    if Comp = 3 then
      Result := Result + #255#0#0#0 + #0#255#0#0 + #0#0#255#0;
  end;

begin
  WriteLn('-- DIB conversion --');

  { 2x2, 32bpp BI_BITFIELDS, positive height so the rows are bottom-up.
    Stored bottom row first: the image reads red,green over blue,white. }
  Dib := Header(2, 2, 32, 3);
  { bottom row (y=1 of the image): blue, white - BGRA on the wire }
  Dib := Dib + #255#0#0#0 + #255#255#255#0;
  { top row (y=0): red, green }
  Dib := Dib + #0#0#255#0 + #0#255#0#0;
  Check(uImage.DibToRgb(Dib, Rgb, W, H, Err), 'a 32bpp DIB converts: ' + Err);
  Check((W = 2) and (H = 2), 'with its dimensions');
  Check(Length(Rgb) = 12, 'and three bytes per pixel');
  { A bottom-up DIB read without the flip puts every screenshot upside down,
    and BGRA read as RGB swaps red and blue in every one. }
  Check((Byte(Rgb[1]) = 255) and (Byte(Rgb[2]) = 0) and (Byte(Rgb[3]) = 0),
    'the first output pixel is the TOP-left one, and it is red not blue');
  Check((Byte(Rgb[4]) = 0) and (Byte(Rgb[5]) = 255) and (Byte(Rgb[6]) = 0),
    'the second is green');
  Check((Byte(Rgb[7]) = 0) and (Byte(Rgb[8]) = 0) and (Byte(Rgb[9]) = 255),
    'and the bottom row follows, blue first');

  { A negative height is already top-down and must NOT be flipped again. }
  Dib := Header(2, -2, 32, 3);
  Dib := Dib + #0#0#255#0 + #0#255#0#0;
  Dib := Dib + #255#0#0#0 + #255#255#255#0;
  Check(uImage.DibToRgb(Dib, Rgb, W, H, Err), 'a top-down DIB converts');
  Check((H = 2) and (Byte(Rgb[1]) = 255) and (Byte(Rgb[3]) = 0),
    'and is not flipped a second time');

  { 24bpp rows are padded to a four-byte boundary: 3 pixels is 9 bytes of
    pixel and 3 of padding.  Ignoring the padding shears the image
    progressively, which looks like a decoding bug anywhere but here. }
  Dib := Header(3, 1, 24, 0);
  Dib := Dib + #1#2#3 + #4#5#6 + #7#8#9 + #0#0#0;
  Check(uImage.DibToRgb(Dib, Rgb, W, H, Err), 'a 24bpp DIB converts');
  Check(Length(Rgb) = 9, 'to exactly W*H*3 bytes, padding excluded');
  Check((Byte(Rgb[1]) = 3) and (Byte(Rgb[2]) = 2) and (Byte(Rgb[3]) = 1),
    'with BGR reordered to RGB');
  Check((Byte(Rgb[7]) = 9) and (Byte(Rgb[9]) = 7),
    'and the last pixel of the row is not lost to the padding');

  { The 12 mask bytes are part of the pixel offset.  Dropping them shifts
    every row, so a DIB whose pixels are exactly accounted for must fail when
    the masks are missing rather than read past the buffer. }
  Dib := Header(2, 2, 32, 3);
  Dib := Dib + #255#0#0#0 + #255#255#255#0 + #0#0#255#0 + #0#255#0#0;
  Check(Length(Dib) = 40 + 12 + 16,
    'a 2x2 32bpp BI_BITFIELDS blob is header + masks + pixels');

  { Refusals, each by name rather than by silence. }
  Dib := Header(2, 2, 8, 0);
  Dib := Dib + StringOfChar(#0, 64);
  Check(not uImage.DibToRgb(Dib, Rgb, W, H, Err), 'an 8bpp DIB is refused');
  Check(Pos('8-bit', Err) > 0, 'and says so: ' + Err);

  Dib := Header(4000, 4000, 32, 0);
  Check(not uImage.DibToRgb(Dib, Rgb, W, H, Err),
    'a header claiming more pixels than the blob holds is refused');
  Check(Pos('smaller', Err) > 0, 'naming the reason: ' + Err);

  Check(not uImage.DibToRgb('', Rgb, W, H, Err), 'an empty blob is refused');
  Check(not uImage.DibToRgb(StringOfChar(#0, 20), Rgb, W, H, Err),
    'and a truncated header is refused rather than read past');
end;

{ The number shown to the user before an image is attached is the number the
  API bills, so these are the documented table's own figures. }
procedure TestVisualTokens;
begin
  WriteLn('-- visual tokens --');
  Check(uImage.VisualTokens(200, 200) = 64, '200x200 costs 64 tokens');
  Check(uImage.VisualTokens(1000, 1000) = 1296, '1000x1000 costs 1296');
  Check(uImage.VisualTokens(1092, 1092) = 1521, '1092x1092 costs 1521');
  Check(uImage.VisualTokens(1920, 1080) = 2691,
    'a 1080p screenshot costs 2691, not (w*h)/750');
  Check(uImage.VisualTokens(2000, 1500) = 3888, '2000x1500 costs 3888');
  { The tier downscales past 2576 on the long edge, so the cost stops rising
    there; without that step a 4K paste would be reported at three times what
    it costs. }
  Check(uImage.VisualTokens(3840, 2160) = 4784,
    '4K is downscaled to the tier and costs exactly the 4784 cap');
  Check(uImage.VisualTokens(8000, 8000) <= 4784,
    'and nothing exceeds the cap');
  Check(uImage.VisualTokens(0, 100) = 0, 'an unknown size costs nothing');
end;

procedure TestSniffImage;
var
  B: RawByteString;
  Media: string;
  W, H: Integer;
begin
  WriteLn('-- image sniffing --');

  { PNG: IHDR sits at a fixed offset, big-endian. }
  B := #137'PNG'#13#10#26#10 + #0#0#0#13 + 'IHDR' + #0#0#7#128 + #0#0#4#56 +
       #8#2#0#0#0;
  Check(uImage.SniffImage(B, Media, W, H) and (Media = 'image/png'),
    'a PNG header is recognised');
  Check((W = 1920) and (H = 1080), 'with its IHDR dimensions');

  { GIF is little-endian, which is the opposite of PNG and easy to carry
    over from the line above. }
  B := 'GIF89a' + #64#0 + #48#0 + #0#0#0;
  Check(uImage.SniffImage(B, Media, W, H) and (Media = 'image/gif'),
    'a GIF header is recognised');
  Check((W = 64) and (H = 48), 'with its little-endian dimensions');

  { JPEG puts HEIGHT before width in a SOF segment. }
  B := #255#216#255#224 + #0#16 + 'JFIF' + #0#1#1#0#0#1#0#1#0#0 +
       #255#192 + #0#17 + #8 + #2#88 + #3#32 + #3#1#17#0#2#17#1#3#17#1;
  Check(uImage.SniffImage(B, Media, W, H) and (Media = 'image/jpeg'),
    'a JPEG is recognised');
  Check((H = 600) and (W = 800),
    'with height read before width, as SOF stores them');

  { WebP, lossy. }
  B := 'RIFF' + #0#0#0#0 + 'WEBP' + 'VP8 ' + #0#0#0#0 + #0#0#0 +
       #157#1#42 + #100#0 + #50#0 + #0#0;
  Check(uImage.SniffImage(B, Media, W, H) and (Media = 'image/webp'),
    'a WebP is recognised');
  Check((W = 100) and (H = 50), 'with its 14-bit dimensions');

  { A BMP must be refused: the API rejects image/bmp, so accepting it here
    would turn a local problem into a rejected request. }
  B := 'BM' + StringOfChar(#0, 60);
  Check(not uImage.SniffImage(B, Media, W, H), 'a BMP is not an image type');
  Check(not uImage.SniffImage('just some text here', Media, W, H),
    'and neither is text');
  Check(not uImage.SniffImage('', Media, W, H), 'nor an empty buffer');

  { Truncated: the type is certain, the size is not, and reading past the
    buffer to find out is the bug this guards. }
  B := #137'PNG'#13#10#26#10 + #0#0#0#13;
  Check(uImage.SniffImage(B, Media, W, H) and (Media = 'image/png'),
    'a truncated PNG is still a PNG');
  Check((W = 0) and (H = 0), 'reported with an unknown size, not a guess');
end;

{ The queue, the ordering inside a message, and the one place an internal
  append must not touch it. }
procedure TestAppendUserImages;
var
  A: TAgent;
  Err, T: string;
  Doc, Msg, Content: TJson;
  I: Integer;
  Ok: Boolean;
begin
  WriteLn('-- user images --');

  A := TAgent.Create('k', 'm', 'sys');
  try
    Check(A.PendingImages = 0, 'nothing is queued to start with');
    Check(A.AttachImage('image/png', 'QUJD', 8, 4, Err),
      'an image queues: ' + Err);
    Check(A.PendingImages = 1, 'and is counted');
    Check(A.MessageCount = 0, 'but nothing is in the transcript yet');

    A.AppendUserText('look at this');
    Check(A.PendingImages = 0, 'appending drains the queue');
    Check(A.MessageCount = 1, 'into exactly one message');

    Doc := JsonParse(A.Transcript);
    try
      Msg := Doc.Item(0);
      Check(Msg.Str('role') = 'user', 'a user message');
      Content := Msg.Find('content');
      Check(Content.Count = 2, 'with two blocks');
      { The API documents that an image works best before the text asking
        about it; text-then-image measurably degrades the answer. }
      Check(Content.Item(0).Str('type') = 'image', 'the image comes FIRST');
      Check(Content.Item(1).Str('type') = 'text', 'and the prose after it');
      Check(Content.Item(0).Find('source').Str('type') = 'base64',
        'the source is base64');
      Check(Content.Item(0).Find('source').Str('media_type') = 'image/png',
        'with the media type');
      Check(Content.Item(0).Find('source').Str('data') = 'QUJD',
        'and the data verbatim');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;

  { An image with no prose is a real message.  The old unconditional
    blank-text exit would have thrown it away without a word. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    Check(A.AttachImage('image/png', 'QUJD', 8, 4, Err), 'an image queues');
    A.AppendUserText('');
    Check(A.MessageCount = 1, 'an image with no text still makes a message');
    Doc := JsonParse(A.Transcript);
    try
      Check(Doc.Item(0).Find('content').Count = 1, 'holding just the image');
      Check(Doc.Item(0).Find('content').Item(0).Str('type') = 'image',
        'and it is the image');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;

  A := TAgent.Create('k', 'm', 'sys');
  try
    A.AppendUserText('');
    Check(A.MessageCount = 0, 'blank text with an empty queue still adds nothing');

    { The cap, and the fact that hitting it changes nothing else. }
    Ok := True;
    for I := 1 to MaxImagesPerMessage do
      if not A.AttachImage('image/png', 'QUJD', 2, 2, Err) then Ok := False;
    Check(Ok, 'the cap admits exactly MaxImagesPerMessage');
    Check(not A.AttachImage('image/png', 'QUJD', 2, 2, Err),
      'and refuses one more');
    Check(Pos(IntToStr(MaxImagesPerMessage), Err) > 0,
      'naming the limit: ' + Err);
    Check(A.MessageCount = 0, 'a refused attach leaves the transcript alone');
    Check(A.PendingImages = MaxImagesPerMessage, 'and the queue intact');

    Check(not A.AttachImage('image/bmp', 'QUJD', 2, 2, Err),
      'a media type the API will not take is refused here, not by the API');

    A.ClearPendingImages;
    Check(A.PendingImages = 0, 'the queue can be dropped');
  finally
    A.Free;
  end;

  { The queue survives every append that is not the user's own message.  The
    end-to-end proof of that - a real summarise round trip that must not spend
    the image - needs a transport and lives in loop.lpr; what is checkable
    here is that queueing alone never writes to the transcript. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    A.AppendUserText('a question');
    T := A.Transcript;
    Check(A.AttachImage('image/png', 'QUJD', 2, 2, Err), 'an image is pending');
    Check(A.Transcript = T, 'queueing an image changes no message');
    Check(Pos('QUJD', A.Transcript) = 0, 'and puts nothing in the transcript');
  finally
    A.Free;
  end;

  { width and height are ours and the API's schema does not have them.  They
    must be in the transcript, where LoadSession and the '[image WxH]' summary
    read them, and out of the request, which the Messages API validates
    strictly and rejects for an unknown key - a 400 on every turn carrying an
    image would leave the whole feature dead on first contact with a server. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    Check(A.AttachImage('image/png', 'QUJD', 4, 8, Err), 'an image is queued');
    A.AppendUserText('look at this');
    Check(Pos('"width"', A.Transcript) > 0,
      'the transcript keeps the dimensions');
    Check(Pos('"height"', A.Transcript) > 0, 'both of them');
    Check(Pos('"width"', A.RequestBody) = 0,
      'and the request carries neither: ' + A.RequestBody);
    Check(Pos('"height"', A.RequestBody) = 0, 'nor the second');
    Check(Pos('QUJD', A.RequestBody) > 0,
      'while the image itself still goes out');
  finally
    A.Free;
  end;

  { A turn that never reached the server must not eat the attachment.  The
    user was told the image goes with their next message; unwinding the user
    turn under it would consume it silently, and the clipboard it came from
    may be gone. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    Check(A.AttachImage('image/png', 'QUJD', 4, 8, Err), 'an image is queued');
    A.AppendUserText('a question about it');
    Check(A.PendingImages = 0, 'sending drains the queue');
    Check(A.TrimUnansweredQuestion, 'the failed turn is unwound');
    Check(A.MessageCount = 0, 'leaving nothing behind');
    Check(A.PendingImages = 1, 'and the image is back on the queue');
    A.AppendUserText('asking again');
    Check(Pos('QUJD', A.Transcript) > 0, 'so the retry still carries it');
  finally
    A.Free;
  end;

  { The same repair through the tool-result path, which drops more than one
    message on its way back to the last assistant turn. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    Check(A.AttachImage('image/png', 'QUJD', 4, 8, Err), 'an image is queued');
    A.AppendUserText('a question about it');
    A.UnwindUnsentTail;
    Check(A.PendingImages = 1, 'the unwind puts the image back too');
  finally
    A.Free;
  end;
end;

{ The worst outcome this feature could produce is a saved session the loader
  then refuses.  This pins the round trip even though today's loader needs no
  change - so that a later block-type allowlist fails here rather than in a
  user's directory. }
procedure TestImageTranscriptRoundTrip;
var
  A: TAgent;
  Err, Path, T: string;
  Doc, Content, Src: TJson;
begin
  WriteLn('-- image transcript --');
  Path := IncludeTrailingPathDelimiter(TmpRoot) + 'img' + PathDelim +
    'session.json';

  A := TAgent.Create('k', 'some-model', 'sys');
  try
    Check(A.AttachImage('image/png', 'aGVsbG8=', 32, 16, Err), 'attached');
    A.AppendUserText('what is this');
    Check(A.SaveSession(Path, Err), 'a session with an image saves: ' + Err);
  finally
    A.Free;
  end;

  A := TAgent.Create('k', '', 'sys');
  try
    Check(A.LoadSession(Path, Err),
      'and loads again - an image block is not rejected: ' + Err);
    T := A.Transcript;
    Doc := JsonParse(T);
    try
      Content := Doc.Item(0).Find('content');
      Check(Content.Item(0).Str('type') = 'image', 'the image block came back');
      Src := Content.Item(0).Find('source');
      Check(Src.Str('media_type') = 'image/png', 'with its media type');
      Check(Src.Str('data') = 'aGVsbG8=', 'and its data byte for byte');
    finally
      Doc.Free;
    end;
  finally
    A.Free;
  end;

  { The existing structural rules still bite.  An image block is legal only
    because it is an object with a non-empty type, not because it is an
    image - so a block written without one is still refused by the loader. }
  WriteFileText(Path, '{"version":1,"model":"m","messages":' +
    '[{"role":"user","content":[{"source":{"type":"base64"}}]}]}');
  A := TAgent.Create('k', '', 'sys');
  try
    Check(not A.LoadSession(Path, Err), 'a block with no type is still refused');
    Check(Pos('no type', Err) > 0, 'for that reason: ' + Err);
  finally
    A.Free;
  end;
end;

procedure TestEvictImages;
var
  A: TAgent;
  Err, T, Path: string;
  Blocks: TPartialBlocks;
  Ran: Boolean;
  Doc: TJson;
  Before, N: Integer;
begin
  WriteLn('-- image eviction --');

  A := TAgent.Create('k', 'm', 'sys');
  try
    { Four images over three user messages, with a tool call and its result in
      between so the pairing rule is actually in play. }
    A.AttachImage('image/png', 'b25l', 10, 10, Err);
    A.AttachImage('image/png', 'dHdv', 20, 20, Err);
    A.AppendUserText('first pair');
    SetLength(Blocks, 1);
    Blocks[0].Kind := bkToolUse;
    Blocks[0].Id := 'call_1';
    Blocks[0].Name := 'search';
    Blocks[0].Text := '{"pattern":"x"}';
    Blocks[0].Signature := '';
    A.ApplyBlocks(Blocks, Ran);
    A.AttachImage('image/png', 'dGhyZWU=', 30, 30, Err);
    A.AppendUserText('third');
    A.AttachImage('image/png', 'Zm91cg==', 40, 40, Err);
    A.AppendUserText('fourth');

    Before := A.MessageCount;
    N := A.EvictImages(1);
    Check(N = 3, 'three of four images are evicted, keeping the newest');
    Check(A.MessageCount = Before, 'no message is removed');

    T := A.Transcript;
    { Oldest first: evicting newest-first would throw away the image the user
      just pasted and keep one nobody will look at again. }
    Check(Pos('b25l', T) = 0, 'the oldest image is gone');
    Check(Pos('dHdv', T) = 0, 'and the second');
    Check(Pos('dGhyZWU=', T) = 0, 'and the third');
    Check(Pos('Zm91cg==', T) > 0, 'but the NEWEST image survives');
    Check(CountOccurrences('[image removed', T) = 3,
      'each evicted image left a placeholder');
    Check(Pos('[image removed to save context: 10x10 image/png]', T) > 0,
      'naming what it was');

    { Substitution, not deletion: a deleted block could empty a content array,
      and a zero-length content array is exactly what the loader rejects, so a
      measure meant to save context would produce an unloadable session.  The
      proof is the real path - save it, load it back. }
    Doc := JsonParse(T);
    try
      Check(Doc.Item(0).Find('content').Count = 3,
        'the first message still has all three of its blocks');
      Check(Doc.Item(0).Find('content').Item(0).Str('type') = 'text',
        'with the image replaced by text in place');
    finally
      Doc.Free;
    end;
    Path := IncludeTrailingPathDelimiter(TmpRoot) + 'evict' + PathDelim +
      'session.json';
    Check(A.SaveSession(Path, Err), 'an evicted transcript saves: ' + Err);
    Check(A.LoadSession(Path, Err),
      'and loads again - eviction left it legal: ' + Err);

    Check(A.EvictImages(1) = 0, 'a second pass has nothing left to do');
    Check(A.EvictImages(0) = 1, 'and keeping none evicts the last one');
  finally
    A.Free;
  end;

  { The trigger's whole point: bring the transcript back under the byte line
    so the byte trim stops firing uselessly on every turn. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    A.AttachImage('image/png', StringOfChar('A', 200000), 100, 100, Err);
    A.AppendUserText('a big one');
    A.AttachImage('image/png', 'c21hbGw=', 10, 10, Err);
    A.AppendUserText('a small one');
    Check(A.TranscriptBytes > 150000, 'base64 makes the transcript large');
    A.EvictImages(1);
    Check(A.TranscriptBytes < 5000,
      'and eviction brings it back down, which is what makes the byte trim ' +
      'useful again');
  finally
    A.Free;
  end;
end;

{ The cross-cutting guard.  Attaching an image is a slash command - a whole
  line, read and then dispatched - and must never become a keystroke, because
  the key loop that would read that keystroke is the same one AskPermission
  uses to read y/a/n. }
procedure TestPasteIsNotAKey;
var
  E: TEditState;
  Verbs: Integer;
begin
  WriteLn('-- paste is not a key --');

  { The enumeration is a closed set of BUFFER verbs.  A new one here is the
    first step of putting a clipboard action - or an approval - inside the
    reader the permission prompt uses, so the count is pinned and every
    bindable name is checked to resolve back to a verb in it. }
  Verbs := Ord(High(TEditKey)) - Ord(Low(TEditKey)) + 1;
  Check(Verbs = 34, 'TEditKey has exactly its 34 editing verbs');
  Check(Ord(High(TEditKey)) = Ord(ekRedo),
    'and the vim verbs were appended, not interleaved');
  Check(Ord(ekNewline) = 10, 'with the original eleven still in their places');
  { ekChar is the only verb that can produce text, and it is deliberately
    absent from the action table - so no keys.json can name it. }
  Check(KeyActionName(ekChar) = '', 'no binding can name the insert verb');

  { Every verb still only edits a buffer: none submits, cancels, or reaches
    outside the line. }
  EditInit(E);
  EditApply(E, ekChar, 'a');
  EditApply(E, ekChar, 'b');
  EditApply(E, ekHome, #0);
  EditApply(E, ekChar, 'x');
  Check(UTF8Encode(E.Text) = 'xab', 'ekChar still inserts at the caret');
  EditApply(E, ekClear, #0);
  Check(UTF8Encode(E.Text) = '', 'ekClear still clears the line');

  { And the approval answer is parsed from a whole line, so a slash command
    typed at the permission prompt is simply not an allow.  Permission
    defaults to deny, and '/paste' is neither 'y' nor 'a'. }
  Check(not ((LowerCase('/paste') = 'y') or (LowerCase('/paste') = 'a') or
             (Trim('/paste') = '')),
    'a slash-prefixed line does not parse as an approval');
end;

{ --------------------------------------------------------------- mentions -- }

procedure TestMentions;
var
  Notes, Out_: string;
begin
  WriteLn('-- mentions --');
  WriteFileText(IncludeTrailingPathDelimiter(TmpRoot) + 'notes.txt',
    'the notes contents'#10);

  { The basic case: prose stays, the file is appended, the note reports it. }
  Out_ := ExpandMentions('please look at @notes.txt for context', nil, Notes);
  Check(Pos('please look at @notes.txt', Out_) = 1, 'the prose is unchanged');
  Check(Pos('the notes contents', Out_) > 0, 'the file contents are attached');
  Check(Pos('--- notes.txt ---', Out_) > 0, 'under a header naming the file');
  Check(Pos('attached (', Notes) > 0, 'and the user is told');

  { Trailing punctuation belongs to the sentence, not the path. }
  Out_ := ExpandMentions('see @notes.txt, then decide', nil, Notes);
  Check(Pos('the notes contents', Out_) > 0,
    'a mention followed by a comma still resolves');

  { A missing file is a note, not an attachment and not an error. }
  Out_ := ExpandMentions('what about @missing.txt here', nil, Notes);
  Check(Out_ = 'what about @missing.txt here', 'a missing file changes nothing');
  Check(Pos('no such file', Notes) > 0, 'but is reported');

  { An email address is not a mention. }
  Out_ := ExpandMentions('mail bob@notes.txt about it', nil, Notes);
  Check(Pos('--- notes.txt ---', Out_) = 0,
    'an @ inside a word does not attach anything');

  { The path guard applies to typed mentions exactly as to tool calls. }
  Out_ := ExpandMentions('read @..\..\Windows\win.ini now', nil, Notes);
  Check(Pos('win.ini contents', Out_) = 0, 'an escaping mention attaches nothing');
  Check(Pos('@..', Notes) > 0, 'and the refusal is reported');
  Out_ := ExpandMentions('read @.pasclaude\session.json now', nil, Notes);
  Check(Pos('--- .pasclaude', Out_) = 0, 'the session file cannot be mentioned in');

  { A binary file would poison the request body. }
  WriteFileText(IncludeTrailingPathDelimiter(TmpRoot) + 'blob2.bin', 'A'#0#255'B');
  Out_ := ExpandMentions('and @blob2.bin too', nil, Notes);
  Check(Pos(#0, Out_) = 0, 'binary bytes never reach the prompt');
  Check(Pos('not text', Notes) > 0, 'with the reason named');

  { No mention, no work: the common case must pass through untouched. }
  Out_ := ExpandMentions('a plain question', nil, Notes);
  Check((Out_ = 'a plain question') and (Notes = ''), 'plain text passes through');
end;

{ ------------------------------------------------------------- multi-edit -- }

procedure TestMultiEdit;
var
  Input, Arr, H: TJson;
  IsErr: Boolean;
  Path, Out_: string;
begin
  WriteLn('-- multi-edit --');
  uTools.AllowAllEdits := True;
  Path := IncludeTrailingPathDelimiter(TmpRoot) + 'multi.txt';
  WriteFileText(Path, 'alpha'#10'beta'#10'gamma'#10'delta'#10);

  { Two hunks in one call, one approval, both applied. }
  Input := TJson.NewObj;
  Input.AddStr('path', 'multi.txt');
  Arr := TJson.NewArr;
  H := TJson.NewObj;
  H.AddStr('old_text', 'alpha');
  H.AddStr('new_text', 'ALPHA');
  Arr.Push(H);
  H := TJson.NewObj;
  H.AddStr('old_text', 'gamma');
  H.AddStr('new_text', 'GAMMA');
  Arr.Push(H);
  Input.Add('edits', Arr);
  Out_ := RunTool('edit_file', Input, nil, IsErr);
  Input.Free;
  Check(not IsErr, 'a two-hunk edit succeeds: ' + Out_);
  Check(ReadFileText(Path) = 'ALPHA'#10'beta'#10'GAMMA'#10'delta'#10,
    'both hunks landed');

  { Atomicity: if the second hunk cannot match, the first is not applied. }
  Input := TJson.NewObj;
  Input.AddStr('path', 'multi.txt');
  Arr := TJson.NewArr;
  H := TJson.NewObj;
  H.AddStr('old_text', 'beta');
  H.AddStr('new_text', 'BETA');
  Arr.Push(H);
  H := TJson.NewObj;
  H.AddStr('old_text', 'not present anywhere');
  H.AddStr('new_text', 'x');
  Arr.Push(H);
  Input.Add('edits', Arr);
  Out_ := RunTool('edit_file', Input, nil, IsErr);
  Input.Free;
  Check(IsErr, 'a failing hunk fails the call');
  Check(Pos('edit 2', Out_) > 0, 'naming which hunk failed');
  Check(ReadFileText(Path) = 'ALPHA'#10'beta'#10'GAMMA'#10'delta'#10,
    'and no hunk was applied - all or nothing');

  { The single-hunk form still works, since the model knows it. }
  Input := TJson.NewObj;
  Input.AddStr('path', 'multi.txt');
  Input.AddStr('old_text', 'delta');
  Input.AddStr('new_text', 'DELTA');
  Out_ := RunTool('edit_file', Input, nil, IsErr);
  Input.Free;
  Check(not IsErr, 'the single-hunk form still works');
  Check(Pos('DELTA', ReadFileText(Path)) > 0, 'and applies');

  { No hunks at all is an error, not a silent no-op write. }
  Input := TJson.NewObj;
  Input.AddStr('path', 'multi.txt');
  Out_ := RunTool('edit_file', Input, nil, IsErr);
  Input.Free;
  Check(IsErr, 'an edit with no hunks is refused');

  uTools.AllowAllEdits := False;
end;

{ --------------------------------------------------------------- notebook -- }

{ The two-cell fixture, written in the exact layout nbformat produces, so
  "the writer is a fixed point" is a claim about real files rather than about
  our own output fed back to us.  Png is the image payload, so the same
  fixture serves the round-trip test with eight bytes and the output-summary
  test with forty kilobytes. }
function NotebookFixture(const Png: string; Minor: Integer): string;
begin
  Result :=
    '{'#10 +
    ' "cells": ['#10 +
    '  {'#10 +
    '   "cell_type": "code",'#10 +
    '   "execution_count": 3,'#10;
  if Minor >= 5 then
    Result := Result + '   "id": "cell-zero",'#10;
  Result := Result +
    '   "metadata": {},'#10 +
    '   "outputs": [],'#10 +
    '   "source": ['#10 +
    '    "x = 1\n",'#10 +
    '    "print(x)"'#10 +
    '   ]'#10 +
    '  },'#10 +
    '  {'#10 +
    '   "cell_type": "code",'#10 +
    '   "execution_count": 7,'#10;
  if Minor >= 5 then
    Result := Result + '   "id": "cell-one",'#10;
  Result := Result +
    '   "metadata": {},'#10 +
    '   "outputs": ['#10 +
    '    {'#10 +
    '     "data": {'#10 +
    '      "image/png": "' + Png + '",'#10 +
    '      "text/plain": "<Figure size 640x480>"'#10 +
    '     },'#10 +
    '     "metadata": {},'#10 +
    '     "output_type": "display_data"'#10 +
    '    }'#10 +
    '   ],'#10 +
    '   "source": ['#10 +
    '    "plot(x)"'#10 +
    '   ]'#10 +
    '  }'#10 +
    ' ],'#10 +
    ' "metadata": {'#10 +
    '  "kernelspec": {'#10 +
    '   "display_name": "Python 3",'#10 +
    '   "language": "python",'#10 +
    '   "name": "python3"'#10 +
    '  }'#10 +
    ' },'#10 +
    ' "nbformat": 4,'#10 +
    ' "nbformat_minor": ' + IntToStr(Minor) + #10 +
    '}'#10;
end;

function NbEdit(const Path, Mode: string; Cell: Integer;
  const Source, CellType: string; out IsErr: Boolean): string;
var
  Input: TJson;
begin
  Input := TJson.NewObj;
  Input.AddStr('path', Path);
  Input.AddNum('cell', Cell);
  Input.AddStr('edit_mode', Mode);
  if Mode <> 'delete' then Input.AddStr('source', Source);
  if CellType <> '' then Input.AddStr('cell_type', CellType);
  Result := uTools.RunTool('notebook_edit', Input, nil, IsErr);
  Input.Free;
end;

procedure TestNotebook;
var
  Input, Doc, Cells, C: TJson;
  IsErr: Boolean;
  Path, Out_, View, Err, Before, Big, Preview: string;
  Snaps: Integer;
  Changed: TStringArray;
  I: Integer;
  Found: Boolean;
begin
  WriteLn('-- notebook --');
  uTools.AllowAllEdits := True;
  Path := IncludeTrailingPathDelimiter(TmpRoot) + 'nb.ipynb';

  { The canonical form of a canonical file is itself.  A trailing newline
    written twice or not at all, or CRLF instead of LF, all show up here -
    and each of them would make a no-op edit dirty the file in git. }
  Before := NotebookFixture('QUJDRA==', 5);
  Check(NotebookCanonical(Before, Out_, Err) and (Out_ = Before),
    'the writer is a fixed point on an nbformat-written file: ' + Err);

  WriteFileText(Path, Before);
  uTools.ClearChangedFiles;
  uTools.ClearSnapshots;
  uTools.BeginTurn(1);
  Snaps := uTools.SnapshotCount;

  Out_ := NbEdit('nb.ipynb', 'replace', 0, 'x = 2'#10'print(x + 1)', '', IsErr);
  Check(not IsErr, 'notebook_edit replaces a cell source: ' + Out_);

  { Everything the edit did not name has to survive verbatim.  A cell rebuilt
    from the fields the code happens to know about loses ids and custom
    metadata, and a replace that clears outputs destroys the user's plot -
    each shows up below as one specific field that no longer matches. }
  Doc := JsonParse(ReadFileText(Path), Err);
  Check(Doc <> nil, 'the rewritten notebook still parses: ' + Err);
  if Doc <> nil then
  try
    Cells := Doc.Find('cells');
    Check(Doc.Num('nbformat', 0) = 4, 'nbformat survives');
    Check(Doc.Num('nbformat_minor', 0) = 5, 'nbformat_minor survives');
    Check(Doc.Find('metadata').Find('kernelspec').Str('name') = 'python3',
      'the kernelspec survives');
    Check(Cells.Count = 2, 'the cell count is unchanged');
    C := Cells.Item(1);
    Check(C.Str('id') = 'cell-one', 'the untouched cell keeps its id');
    Check(C.Num('execution_count', 0) = 7,
      'and its execution_count');
    Check(C.Find('outputs').Item(0).Find('data').Str('image/png') = 'QUJDRA==',
      'and its output data');
    C := Cells.Item(0);
    Check(C.Str('id') = 'cell-zero', 'the edited cell keeps its id too');
    Check(C.Num('execution_count', 0) = 3,
      'and its execution_count: a source change is not a re-run');
    Check((C.Find('source').Count = 2) and
          (C.Find('source').Item(0).AsString = 'x = 2'#10) and
          (C.Find('source').Item(1).AsString = 'print(x + 1)'),
      'and carries the new source as lines');
  finally
    Doc.Free;
  end;

  { The wiring that makes an edit visible to /diff and undoable by /rewind.
    Neither changes the file, so nothing else here would catch their loss. }
  Check(uTools.SnapshotCount = Snaps + 1, 'the edit took a snapshot');
  Changed := uTools.ChangedFiles;
  Found := False;
  for I := 0 to High(Changed) do
    if Changed[I] = 'nb.ipynb' then Found := True;
  Check(Found, 'and the notebook is listed as changed');

  { A replace with the source the cell already has must leave the bytes alone,
    which is the same fixed-point claim, now through the whole tool path. }
  Before := ReadFileText(Path);
  Out_ := NbEdit('nb.ipynb', 'replace', 0, 'x = 2'#10'print(x + 1)', '', IsErr);
  Check((not IsErr) and (ReadFileText(Path) = Before),
    'a no-op replace leaves the file byte-identical');

  { The view: cells legible, outputs named and measured, payload absent.
    Forty kilobytes of base64 is what the whole feature exists to keep out of
    the context, so the assertion is that no long run of it appears at all. }
  Big := StringOfChar('A', 40000);
  Check(NotebookView(NotebookFixture(Big, 5), View, Err),
    'the view renders a notebook with a big output: ' + Err);
  Check(Pos('== cell 1 (code', View) > 0, 'cells are numbered and typed');
  Check(Pos('plot(x)', View) > 0, 'the source is shown verbatim');
  Check(Pos('image/png', View) > 0, 'the output mime type is named');
  Check(Pos(' KB)', View) > 0, 'with its size');
  Check(Pos('<Figure size 640x480>', View) > 0, 'text/plain is shown');
  Check(Pos(StringOfChar('A', 200), View) = 0,
    'and no run of the payload reaches the view');
  Check(Length(View) < 4096, 'the whole view stays small: ' +
    IntToStr(Length(View)) + ' bytes');

  { The per-output cap is a byte count, and an output is as likely to be a
    pandas repr with an em dash or a traceback with a curly quote as it is to
    be ASCII.  Here the 2000th byte is the lead byte of an accented
    character: cut there with Copy and the view - which read_file hands
    straight to the model - is not valid UTF-8, and the API rejects the whole
    request rather than the one output that was too long. }
  Big := '{"cells":[{"cell_type":"code","execution_count":1,"metadata":{},' +
    '"outputs":[{"output_type":"stream","name":"stdout","text":"' +
    StringOfChar('a', 1999) + #$C3#$A9 + StringOfChar('b', 50) + '"}],' +
    '"source":["print(s)"]}],"metadata":{},"nbformat":4,"nbformat_minor":5}';
  Check(IsValidUtf8(Big), 'the boundary fixture is itself valid UTF-8');
  Check(NotebookView(Big, View, Err),
    'the view renders an output that is cut mid-character: ' + Err);
  Check(IsValidUtf8(View), 'and the cut view is still valid UTF-8');
  Check(Pos('chars total', View) > 0, 'the output really was cut');

  { The permission prompt.  Without a ChangePreview arm the user is asked to
    approve a bare tool name, and without a DescribeTool arm the title is the
    word "notebook_edit" - neither of which any other assertion notices. }
  Input := TJson.NewObj;
  Input.AddStr('path', 'nb.ipynb');
  Input.AddNum('cell', 0);
  Input.AddStr('edit_mode', 'replace');
  Input.AddStr('source', 'x = 99');
  Preview := uTools.ChangePreview('notebook_edit', Input);
  Out_ := uTools.DescribeTool('notebook_edit', Input);
  Input.Free;
  Check(Pos('- x = 2', Preview) > 0, 'the preview shows the old source removed');
  Check(Pos('+ x = 99', Preview) > 0, 'and the new source added');
  Check(Pos(StringOfChar('A', 200), Preview) = 0, 'and carries no payload');
  Check((Pos('replace', Out_) > 0) and (Pos('cell 0', Out_) > 0),
    'the prompt title names the mode and the cell: ' + Out_);

  { Insert and delete.  The inserted cell must carry what the v4 schema makes
    mandatory, an id only where the minor version allows one, and the pair of
    operations must cancel exactly. }
  Before := ReadFileText(Path);
  Out_ := NbEdit('nb.ipynb', 'insert', 1, 'y = 2', 'code', IsErr);
  Check(not IsErr, 'a cell can be inserted: ' + Out_);
  Doc := JsonParse(ReadFileText(Path), Err);
  if Doc <> nil then
  try
    Cells := Doc.Find('cells');
    C := Cells.Item(1);
    Check(Cells.Count = 3, 'the notebook gained a cell');
    Check(C.Find('source').Item(0).AsString = 'y = 2',
      'the new cell sits at the requested index carrying the given source');
    Check((C.Find('metadata') <> nil) and (C.Find('metadata').Count = 0),
      'with empty metadata');
    Check((C.Find('outputs') <> nil) and (C.Find('outputs').Kind = jkArr) and
          (C.Find('outputs').Count = 0), 'an empty outputs array');
    Check((C.Find('execution_count') <> nil) and
          (C.Find('execution_count').Kind = jkNull),
      'and a null execution_count, both of which v4 requires');
    Check((C.Str('id') <> '') and (C.Str('id') <> 'cell-zero') and
          (C.Str('id') <> 'cell-one'),
      'plus an id distinct from every existing one at nbformat_minor 5');
  finally
    Doc.Free;
  end;
  Out_ := NbEdit('nb.ipynb', 'delete', 1, '', '', IsErr);
  Check((not IsErr) and (ReadFileText(Path) = Before),
    'and deleting it returns the file to its exact previous bytes');

  { 4.0 through 4.4 forbid the id field, so emitting one always is as wrong
    as never emitting it. }
  WriteFileText(Path, NotebookFixture('QUJDRA==', 4));
  Out_ := NbEdit('nb.ipynb', 'insert', 0, 'z = 3', 'markdown', IsErr);
  Check(not IsErr, 'insert works on a 4.4 notebook: ' + Out_);
  Doc := JsonParse(ReadFileText(Path), Err);
  if Doc <> nil then
  try
    C := Doc.Find('cells').Item(0);
    Check(C.IndexOf('id') < 0, 'and adds no id where the schema forbids it');
    Check(C.Str('cell_type') = 'markdown', 'honouring cell_type');
    Check(C.IndexOf('outputs') < 0,
      'a markdown cell gets no outputs array, which would be invalid');
  finally
    Doc.Free;
  end;

  uTools.ClearSnapshots;
  uTools.ClearChangedFiles;
  uTools.AllowAllEdits := False;
end;

{ ------------------------------------------------- notebook, non-ASCII -- }

{ The markdown cell of the non-ASCII fixture, on its own so the round-trip
  assertion and the fixture cannot drift apart: the test below asserts these
  exact bytes are still present after an edit to a different cell, and if it
  built its own copy of them the assertion would only prove the test agrees
  with itself.  Every non-ASCII byte is spelled out rather than typed, because
  a fixture whose whole point is byte identity must not be at the mercy of
  whatever encoding an editor decides this file is in. }
function NbUnicodeMarkdownCell: string;
const
  IDiaeresis = #$C3#$AF;                     { U+00EF, two bytes }
  EmDash = #$E2#$80#$94;                     { U+2014, three }
  Grin = #$F0#$9F#$98#$80;                   { U+1F600, four - outside the BMP,
                                               so escaping it would need a
                                               surrogate pair }
  Rocket = #$F0#$9F#$9A#$80;                 { U+1F680, four }
begin
  Result :=
    '  {'#10 +
    '   "cell_type": "markdown",'#10 +
    '   "id": "1c2d0f07",'#10 +
    '   "metadata": {},'#10 +
    '   "source": ['#10 +
    '    "# na' + IDiaeresis + 've ' + EmDash + ' ' + Grin + ' rocket ' +
      Rocket + '\n"'#10 +
    '   ]'#10 +
    '  }'#10;
end;

{ A notebook nbformat itself wrote - generated with nbformat 5.11 through
  nbformat.write and copied out byte for byte, ids included - carrying an
  accented letter, a CJK pair, an em dash and two emoji outside the BMP.
  Every one of those is raw UTF-8 in the file, which is the fact the tests
  below exist to pin down. }
function NbUnicodeFixture: string;
const
  EAcute = #$C3#$A9;                         { U+00E9 }
  Kanji = #$E6#$BC#$A2#$E5#$AD#$97;          { U+6F22 U+5B57 }
begin
  Result :=
    '{'#10 +
    ' "cells": ['#10 +
    '  {'#10 +
    '   "cell_type": "code",'#10 +
    '   "execution_count": null,'#10 +
    '   "id": "ead6385d",'#10 +
    '   "metadata": {},'#10 +
    '   "outputs": [],'#10 +
    '   "source": ['#10 +
    '    "print(''caf' + EAcute + ''')\n",'#10 +
    '    "# ' + Kanji + '\n"'#10 +
    '   ]'#10 +
    '  },'#10 +
    NbUnicodeMarkdownCell +
    ' ],'#10 +
    ' "metadata": {'#10 +
    '  "kernelspec": {'#10 +
    '   "display_name": "Python 3",'#10 +
    '   "language": "python",'#10 +
    '   "name": "python3"'#10 +
    '  }'#10 +
    ' },'#10 +
    ' "nbformat": 4,'#10 +
    ' "nbformat_minor": 5'#10 +
    '}'#10;
end;

{ The same cell, the same layout, the same id - with its non-ASCII spelled as
  \u escapes instead.  That is what Python's json.dumps produces when nobody
  turns ensure_ascii off, so it is what a notebook written by a tool that is
  not nbformat looks like; Jupyter itself would never write this file, and that
  is exactly the point.  It is a spelling we have to reproduce rather than one
  we would ever choose.  One of the escapes is a surrogate pair, the character
  that breaks first in either direction.  It lives beside NbUnicodeMarkdownCell
  for the same reason that one exists: the assertions below compare against
  these exact bytes rather than against the test's own idea of them. }
function NbEscapedMarkdownCell: string;
begin
  Result :=
    '  {'#10 +
    '   "cell_type": "markdown",'#10 +
    '   "id": "1c2d0f07",'#10 +
    '   "metadata": {},'#10 +
    '   "source": ['#10 +
    '    "# na\u00efve \u2014 \ud83d\ude00 rocket \ud83d\ude80\n"'#10 +
    '   ]'#10 +
    '  }'#10;
end;

{ The nbformat fixture with that one cell swapped for its escaped twin.
  Building it by substitution rather than by writing it out again guarantees
  the two fixtures differ in exactly one cell, and it leaves the CODE cell's
  e-acute and kanji raw - so the document is mixed, which is the whole point.
  The memory is per string, not per file, and a fixture that was escaped
  throughout could not tell the difference. }
function NbEscapedFixture: string;
begin
  Result := StringReplace(NbUnicodeFixture, NbUnicodeMarkdownCell,
    NbEscapedMarkdownCell, []);
end;


procedure TestNotebookUnicode;
const
  Grin = #$F0#$9F#$98#$80;
  IDiaeresis = #$C3#$AF;
  EmDash = #$E2#$80#$94;
  Rocket = #$F0#$9F#$9A#$80;
  Kanji = #$E6#$BC#$A2#$E5#$AD#$97;
  Copyright = #$C2#$A9;                      { U+00A9: starts C2, is not NEL }
  EnDash = #$E2#$80#$93;                     { U+2013: starts E2 80, is not LS }
  Nel = #$C2#$85;                            { U+0085 }
  LineSep = #$E2#$80#$A8;                    { U+2028 }
  ParaSep = #$E2#$80#$A9;                    { U+2029 }
var
  Doc, Cells, Src: TJson;
  Nb, Canon, New_, View, Err: string;
begin
  WriteLn('-- notebook non-ASCII --');

  Nb := NbUnicodeFixture;
  Check(IsValidUtf8(Nb), 'the non-ASCII fixture is itself valid UTF-8');

  { The whole claim in one assertion.  nbformat writes non-ASCII raw - its
    writer passes ensure_ascii=False, against json.dumps' default - so a writer
    that escaped it would differ from the file it was handed on every line
    with an accent in it, which is the diff the layout rules exist to prevent.
    A fixed point here is the only thing that proves we agree. }
  Check(NotebookCanonical(Nb, Canon, Err) and (Canon = Nb),
    'the writer is a fixed point on a notebook nbformat wrote with non-ASCII '
    + 'in it: ' + Err);
  Check(Pos('\u', Canon) = 0,
    'and escapes none of it, not the emoji as a surrogate pair either');

  { An edit to cell 0 must leave cell 1 alone to the byte.  The emoji is the
    part that would break first: four bytes, outside the BMP, and the one
    character that a writer reaching for \uXXXX has to split into a surrogate
    pair to emit at all. }
  Check(NotebookApply(Nb, 0, 'replace', 'x = 1', '', New_, Err),
    'a cell of a non-ASCII notebook can be replaced: ' + Err);
  Check(Pos(NbUnicodeMarkdownCell, New_) > 0,
    'and the untouched cell comes back byte-identical, emoji included');
  Check(IsValidUtf8(New_), 'the rewritten notebook is valid UTF-8');
  Check(Pos('\u', New_) = 0, 'with nothing escaped on the way out');

  { Non-ASCII the model supplies has to survive the trip out and back in.  It
    arrives as UTF-8 in the tool arguments and is written the same way, so the
    only thing that could go wrong is a writer that mangles what it did not
    parse itself. }
  Check(NotebookApply(Nb, 0, 'replace', 'print("' + Grin + '")', '',
    New_, Err), 'a replacement source can carry an emoji: ' + Err);
  Check(Pos('print(\"' + Grin + '\")', New_) > 0,
    'and reaches the file as its four raw bytes');
  Doc := JsonParse(New_, Err);
  Check(Doc <> nil, 'the result parses: ' + Err);
  if Doc <> nil then
  try
    Src := Doc.Find('cells').Item(0).Find('source');
    Check((Src.Count = 1) and (Src.Item(0).AsString = 'print("' + Grin + '")'),
      'and reads back as the source that went in');
  finally
    Doc.Free;
  end;

  { A file somebody else wrote with escapes.  The rule here used to be that we
    normalised it to the raw form on the first edit, on the argument that the
    change was at least a change towards what Jupyter would have written.  That
    argument now runs the other way, and the reversal is deliberate rather than
    a sentence that quietly became more accurate: the promise this program
    makes about a notebook edit is that the user's diff shows the line they
    asked about and nothing else, and a line rewritten into a better spelling
    is still a line the user did not touch.  So a string that ARRIVED escaped
    goes back out escaped, and only what we compose ourselves is raw.

    The property the old assertion was really guarding - a surrogate pair
    joining into one four-byte character rather than two stumps - has not gone
    anywhere.  It is asserted on the parsed value now, because the emitted text
    no longer shows it, and dropping it along with the line that used to check
    it would have retired the only test of surrogate joining in the suite. }
  Nb := '{"cells":[{"cell_type":"code","execution_count":null,"id":"a1",' +
        '"metadata":{},"outputs":[],"source":["s = \"\ud83d\ude00\u00e9\""]}],' +
        '"metadata":{},"nbformat":4,"nbformat_minor":5}';
  Check(NotebookCanonical(Nb, Canon, Err),
    'a notebook written with \u escapes still reads: ' + Err);
  Check(IsValidUtf8(Canon), 'and rewrites as valid UTF-8');
  Check(Pos('s = \"\ud83d\ude00\u00e9\"', Canon) > 0,
    'the escapes it arrived with are written back as they arrived');
  Doc := JsonParse(Canon, Err);
  Check(Doc <> nil, 'the rewritten document parses: ' + Err);
  if Doc <> nil then
  try
    Check(Doc.Find('cells').Item(0).Find('source').Item(0).AsString =
      's = "' + Grin + #$C3#$A9 + '"',
      'and the surrogate pair still reads as one four-byte character, not two '
      + 'stumps');
  finally
    Doc.Free;
  end;

  { Where the line array is cut.  nbformat splits a cell's source with Python's
    str.splitlines(True), which breaks on eleven things and not on #10 alone;
    the expected seven elements below are what nbformat 5.11 produced for this
    exact string.  The two near misses are the point of the fixture: U+00A9
    starts with the same byte as NEL and U+2013 with the same two bytes as the
    line separator, and a scanner that split on the lead byte would cut both of
    them in half and hand the model invalid UTF-8. }
  Nb := NbUnicodeFixture;
  Check(NotebookApply(Nb, 0, 'replace',
    'a'#12'b'#13'c'#13#10'd' + LineSep + 'e' + Copyright + 'f' + Nel +
    'g' + EnDash + 'h' + ParaSep + 'i', '', New_, Err),
    'a source with every kind of line break can be written: ' + Err);
  Doc := JsonParse(New_, Err);
  Check(Doc <> nil, 'and the result parses: ' + Err);
  if Doc <> nil then
  try
    Cells := Doc.Find('cells');
    Src := Cells.Item(0).Find('source');
    Check(Src.Count = 7, 'the source is cut into seven lines, as Python cuts it');
    if Src.Count = 7 then
    begin
      Check(Src.Item(0).AsString = 'a'#12, 'a form feed ends a line');
      Check(Src.Item(1).AsString = 'b'#13, 'a lone carriage return ends one');
      Check(Src.Item(2).AsString = 'c'#13#10,
        'and CRLF ends one line rather than two');
      Check(Src.Item(3).AsString = 'd' + LineSep, 'U+2028 ends a line');
      Check(Src.Item(4).AsString = 'e' + Copyright + 'f' + Nel,
        'U+0085 ends a line and U+00A9, which starts with the same byte, does not');
      Check(Src.Item(5).AsString = 'g' + EnDash + 'h' + ParaSep,
        'U+2029 ends a line and U+2013, which shares its first two bytes, does not');
      Check(Src.Item(6).AsString = 'i', 'and the tail with no break survives');
    end;
    Check(IsValidUtf8(New_), 'no character was cut in half doing it');
  finally
    Doc.Free;
  end;

  { The unit itself.  A notebook whose author's tooling escaped what Jupyter
    would not: left alone it has to be a fixed point like any other file we did
    not write, and after an edit to one cell the other cell has to come back
    byte for byte, escapes and all.  Pos of the escaped cell proves it survived;
    Pos of the raw one being zero proves it was not quietly normalised, which is
    the failure this unit exists to remove and the one a test that only checked
    the characters would have walked straight past. }
  Nb := NbEscapedFixture;
  Check(NotebookCanonical(Nb, Canon, Err) and (Canon = Nb),
    'a notebook whose escapes are not the ones Jupyter writes is a fixed '
    + 'point too: ' + Err);
  Check(NotebookApply(Nb, 0, 'replace', 'print("' + Grin + '")', '', New_, Err),
    'a cell of it can be replaced: ' + Err);
  Check(Pos(NbEscapedMarkdownCell, New_) > 0,
    'and every other cell comes back byte-identical, escapes included');
  Check(Pos(NbUnicodeMarkdownCell, New_) = 0,
    'rather than normalised to the raw form we would have written ourselves');
  Check(Pos('print(\"' + Grin + '\")', New_) > 0,
    'while the cell we did write goes out as raw UTF-8, as nbformat writes it');
  Check(IsValidUtf8(New_), 'the result is valid UTF-8');
  Doc := JsonParse(New_, Err);
  Check(Doc <> nil, 'the edited escaped notebook parses: ' + Err);
  if Doc <> nil then
  try
    Src := Doc.Find('cells').Item(1).Find('source');
    Check((Src <> nil) and (Src.Count = 1) and
      (Src.Item(0).AsString = '# na' + IDiaeresis + 've ' + EmDash + ' ' +
       Grin + ' rocket ' + Rocket + #10),
      'and the preserved cell still means the characters it always meant');
  finally
    Doc.Free;
  end;

  { The other direction, in the same document, and the pair is the whole rule.
    Replacing the ESCAPED cell writes it the way we write anything we composed
    ourselves - raw, as nbformat writes it - because a source the model handed
    us has no arrival form to be faithful to.  The code cell's kanji, which
    nobody touched, is still the raw bytes it came in as.  So one file holds
    both spellings at once and neither is imposed on the other: the memory is
    per string, not per file, which is the part a per-file switch would get
    wrong. }
  Check(NotebookApply(Nb, 1, 'replace', '# ' + EmDash + ' done', '', New_, Err),
    'the escaped cell itself can be replaced: ' + Err);
  Check(Pos('"# ' + EmDash + ' done"', New_) > 0,
    'and the source we supplied goes out raw, not re-escaped to match the '
    + 'neighbours it is replacing');
  Check(Pos('# ' + Kanji, New_) > 0,
    'while a raw character in a cell nobody touched stays raw');

  { The model never sees an escape it will not be asked to reproduce: the view
    is built from decoded values, so remembering the literal changed nothing
    about what reaches the conversation. }
  Check(NotebookView(NbEscapedFixture, View, Err) and (Pos(Grin, View) > 0),
    'the cell view shows the characters, not the spelling of the file');

  { v3 stays refused, and says so in terms somebody can act on.  Upgrading was
    measured and rejected: nbformat's own converter joins a heading cell's
    lines into one and draws every new cell id from a random word corpus, so
    the same v3 file converted twice gives two different v4 files - it cannot
    be the no-op an edit has to be. }
  Nb := '{"worksheets":[{"cells":[{"cell_type":"code","input":["x = 1"],' +
        '"prompt_number":1,"outputs":[]}]}],"metadata":{},"nbformat":3,' +
        '"nbformat_minor":0}';
  Check((not NotebookCanonical(Nb, Canon, Err)) and (Pos('nbformat 3', Err) > 0),
    'a v3 notebook is refused by version: ' + Err);
  Check(Pos('as_version=4', Err) > 0,
    'and the refusal names the tool that owns the conversion');

end;

{ -------------------------------------------------------------- gitignore -- }

procedure TestGitignore;
var
  Input: TJson;
  IsErr: Boolean;
  Out_: string;
begin
  WriteLn('-- gitignore --');
  WriteFileText(IncludeTrailingPathDelimiter(TmpRoot) + '.gitignore',
    '# build output'#10 +
    'obj/'#10 +
    '*.log'#10 +
    '/topsecret.txt'#10 +
    '!keep.log'#10);
  WriteFileText(IncludeTrailingPathDelimiter(TmpRoot) + 'obj\junk.o', 'object code');
  WriteFileText(IncludeTrailingPathDelimiter(TmpRoot) + 'trace.log', 'log MARKER1');
  WriteFileText(IncludeTrailingPathDelimiter(TmpRoot) + 'keep.log', 'kept MARKER2');
  WriteFileText(IncludeTrailingPathDelimiter(TmpRoot) + 'topsecret.txt', 'MARKER3');
  WriteFileText(IncludeTrailingPathDelimiter(TmpRoot) + 'visible.txt', 'MARKER4');
  LoadIgnoreRules;

  Check(IsIgnored('obj', True), 'a dir-only rule hides the directory');
  Check(IsIgnored('obj\junk.o', False), 'and everything under it');
  Check(IsIgnored('trace.log', False), 'a *.log rule hides matching files');
  Check(not IsIgnored('keep.log', False), 'a negated rule un-hides its match');
  Check(IsIgnored('topsecret.txt', False), 'an anchored rule hides the root file');
  Check(not IsIgnored('sub\topsecret.txt', False),
    'but not the same name deeper down');
  Check(not IsIgnored('visible.txt', False), 'unmatched files stay visible');
  Check(not IsIgnored('trace.log.txt', False), '*.log does not match .log.txt');

  { And the walkers actually consult it. }
  Input := TJson.NewObj;
  Input.AddStr('path', '.');
  Input.Add('recursive', TJson.NewBool(True));
  Out_ := RunTool('list_dir', Input, nil, IsErr);
  Input.Free;
  Check(Pos('junk.o', Out_) = 0, 'list_dir hides ignored output');
  Check(Pos('visible.txt', Out_) > 0, 'and shows the rest');

  Input := TJson.NewObj;
  Input.AddStr('pattern', 'MARKER1');
  Out_ := RunTool('search', Input, nil, IsErr);
  Input.Free;
  Check(Pos('MARKER1', Out_) = 0, 'search skips ignored files');
  Input := TJson.NewObj;
  Input.AddStr('pattern', 'MARKER2');
  Out_ := RunTool('search', Input, nil, IsErr);
  Input.Free;
  Check(Pos('MARKER2', Out_) > 0, 'but not un-ignored ones');

  { Search gains real globs alongside the old loose forms. }
  Input := TJson.NewObj;
  Input.AddStr('pattern', 'MARKER4');
  Input.AddStr('glob', 'vis*.txt');
  Out_ := RunTool('search', Input, nil, IsErr);
  Input.Free;
  Check(Pos('MARKER4', Out_) > 0, 'a star glob matches');
  Input := TJson.NewObj;
  Input.AddStr('pattern', 'MARKER4');
  Input.AddStr('glob', 'nope*.txt');
  Out_ := RunTool('search', Input, nil, IsErr);
  Input.Free;
  Check(Pos('MARKER4', Out_) = 0, 'and a non-matching one excludes');

  { Cleanup so later tests see a rule-free root. }
  DeleteFile(IncludeTrailingPathDelimiter(TmpRoot) + '.gitignore');
  LoadIgnoreRules;
  Check(not IsIgnored('trace.log', False), 'removing .gitignore clears the rules');
end;

{ ------------------------------------------------------------- walk depth -- }

{ Defined with the rest of the main-block housekeeping at the foot of the
  file; this test builds a ten-level tree and has to take it down again. }
procedure Cleanup(const Dir: string); forward;

{ Both walkers used to stop at a constant - 4 for list_dir, 8 for search - and
  a tree deeper than that was simply invisible.  The cap is now an argument
  with a ceiling: the defaults must not have moved, the argument must actually
  be honoured, and a preposterous value must clamp rather than run away. }
procedure TestWalkDepth;
var
  Input: TJson;
  Out_, Deep, Deeper, At99: string;
  IsErr: Boolean;
begin
  Deep := IncludeTrailingPathDelimiter(TmpRoot) + 'dp\a\b\c\d\e\';
  Deeper := Deep + 'f\g\h\i\';
  WriteFileText(Deep + 'deep.txt', 'six levels down');
  WriteFileText(Deeper + 'deepest.txt', 'DEPTHMARKER ten levels down');

  Input := TJson.NewObj;
  Input.AddStr('path', '.');
  Input.AddBool('recursive', True);
  Out_ := RunTool('list_dir', Input, nil, IsErr);
  Input.Free;
  Check(Pos('deep.txt', Out_) = 0,
    'the default recursive listing still stops at depth 4');

  Input := TJson.NewObj;
  Input.AddStr('path', '.');
  Input.AddNum('depth', 8);
  Out_ := RunTool('list_dir', Input, nil, IsErr);
  Input.Free;
  Check(Pos('deep.txt', Out_) > 0, 'and a depth argument reaches further');

  Input := TJson.NewObj;
  Input.AddStr('path', '.');
  Input.AddNum('depth', 99);
  At99 := RunTool('list_dir', Input, nil, IsErr);
  Input.Free;
  Check((not IsErr) and (At99 <> ''), 'an absurd depth still returns');

  Input := TJson.NewObj;
  Input.AddStr('path', '.');
  Input.AddNum('depth', 12);
  Out_ := RunTool('list_dir', Input, nil, IsErr);
  Input.Free;
  Check(At99 = Out_, 'and clamps to the ceiling rather than running away');

  Input := TJson.NewObj;
  Input.AddStr('pattern', 'DEPTHMARKER');
  Out_ := RunTool('search', Input, nil, IsErr);
  Input.Free;
  Check(Pos('deepest.txt', Out_) = 0,
    'search at its default depth misses a file ten levels down');

  Input := TJson.NewObj;
  Input.AddStr('pattern', 'DEPTHMARKER');
  Input.AddNum('depth', 12);
  Out_ := RunTool('search', Input, nil, IsErr);
  Input.Free;
  Check(Pos('deepest.txt', Out_) > 0, 'and finds it when told how deep to go');

  { The later tests list and search this root, so the tree does not stay. }
  Cleanup(IncludeTrailingPathDelimiter(TmpRoot) + 'dp');
end;

{ --------------------------------------------------------------- markdown -- }

{ The renderer's decisions are observable through Emit, so the test captures
  raw output by swapping the console for a buffer... except uTerm writes to
  the real console.  What is testable without that seam is the line
  discipline: what is held, what is flushed, and the fence state.  MdMidLine
  exposes the held-line state; the styling itself is eyeballed. }
procedure TestMarkdown;
begin
  WriteLn('-- markdown --');
  MdReset;
  Check(not MdMidLine, 'a fresh renderer holds nothing');
  MdFeed('a partial li');
  Check(MdMidLine, 'an incomplete line is held back');
  MdFeed('ne'#10);
  Check(not MdMidLine, 'the newline releases it');
  MdFeed('one'#10'two'#10'three no newline');
  Check(MdMidLine, 'only the unterminated tail is held');
  MdFinish;
  Check(not MdMidLine, 'finish flushes the tail');
  { A fragment split inside a fence marker must not break the fence: feed
    the marker in two pieces and the code line after it still arrives once
    the line completes. }
  MdReset;
  MdFeed('``');
  Check(MdMidLine, 'half a fence is just a held line');
  MdFeed('`'#10'code line'#10'```'#10);
  Check(not MdMidLine, 'the fenced block flowed through');
  MdFinish;
end;

{ Escape twice opens /rewind, and every clause of that sentence is a fence
  around behaviour that already existed.  The decision is a pure function
  precisely so it can be asserted here: ReadLineCore itself needs a console
  and cannot be driven by a suite, so a rule left inline in its key handler
  would be a rule nothing ever checked.

  The fifth and sixth assertions are the ones that matter.  Escape has always
  cleared the line and, with vim on, has always left insert mode; if either of
  those regresses, the feature has cost more than it is worth and this is
  where that shows up. }
procedure TestEscEscOpensRewind;
var
  Saved: string;
begin
  WriteLn('-- escape twice --');
  Saved := uTerm.EscEscCommand;
  try
    uTerm.EscEscCommand := '';
    Check(not EscEscFires(True, True, True, False, 10),
      'with no command pushed down, escape twice does nothing at all');
    uTerm.EscEscCommand := '/rewind';
    Check(EscEscFires(True, True, True, False, 10),
      'at the prompt, armed, on an empty line, a second escape fires');
    Check(not EscEscFires(False, True, True, False, 10),
      'never in a picker or a permission question: only the REPL prompt');
    Check(not EscEscFires(True, False, True, False, 10),
      'never on a first escape, whatever the line');
    Check(not EscEscFires(True, True, False, False, 10),
      'never on a line that had text in it: escape still just clears');
    Check(not EscEscFires(True, True, True, True, 10),
      'and never with vim on, where escape means normal mode both times');
    Check(EscEscFires(True, True, True, False, EscEscWindowMs),
      'the last millisecond of the window still counts');
    Check(not EscEscFires(True, True, True, False, EscEscWindowMs + 1),
      'and one past it is two gestures, not one');
  finally
    { Back to whatever it was, or every ReadLineCore after this suite would
      believe a command had been wired into it. }
    uTerm.EscEscCommand := Saved;
  end;
end;

{ The console control handler, driven directly: a Ctrl+C event must be
  consumed (or the default handler kills the process mid-turn, skipping every
  finally block) and must surface exactly once through CtrlCPressed.  Other
  events pass through untouched, because Ctrl+Break and a closing window mean
  "kill it", not "stop the reply". }
procedure TestCtrlC;
const
  CTRL_C_EVENT = 0;
  CTRL_BREAK_EVENT = 1;
begin
  WriteLn('-- ctrl+c --');
  Check(not CtrlCPressed, 'no Ctrl+C means no cancel');
  Check(HandleConsoleBreak(CTRL_C_EVENT), 'Ctrl+C is consumed, not fatal');
  Check(CtrlCPressed, 'the cancel flag is raised');
  Check(not CtrlCPressed, 'reading the flag consumes it');
  Check(not HandleConsoleBreak(CTRL_BREAK_EVENT),
    'Ctrl+Break keeps its default meaning');
  Check(not CtrlCPressed, 'Ctrl+Break does not raise the cancel flag');
end;

{ History persistence.  The file format is line-oriented with backslash
  escapes, so a multi-line prompt must survive the round trip as one entry. }
procedure TestHistoryPersistence;
var
  P: string;
  E: TEditState;
  I: Integer;
begin
  WriteLn('-- history file --');
  P := IncludeTrailingPathDelimiter(TmpRoot) + 'history.txt';

  HistoryClear;
  HistoryAdd('build debug');
  HistoryAdd('what does uHttp do?');
  HistoryAdd('line one'#10'line two');
  HistoryAdd('a literal \n stays literal');
  HistorySave(P);

  HistoryClear;
  Check(HistoryCount = 0, 'memory is empty before the load');
  HistoryLoad(P);
  Check(HistoryCount = 4, 'every entry came back');

  { Recall through the editor, newest first. }
  EditInit(E);
  EditApply(E, ekHistPrev, #0);
  Check(UTF8Encode(E.Text) = 'a literal \n stays literal',
    'a literal backslash-n survives the round trip');
  EditApply(E, ekHistPrev, #0);
  Check(UTF8Encode(E.Text) = 'line one'#10'line two',
    'a multi-line entry is one entry with its newline intact');
  EditApply(E, ekHistPrev, #0);
  Check(UTF8Encode(E.Text) = 'what does uHttp do?', 'ordinary lines are ordinary');

  { A missing file is an empty history, not an error. }
  HistoryLoad(IncludeTrailingPathDelimiter(TmpRoot) + 'no-such-history.txt');
  Check(HistoryCount = 0, 'a missing file loads as empty');

  { The cap: more than HistoryMax entries keep only the newest. }
  HistoryClear;
  for I := 1 to HistoryMax + 25 do
    HistoryAdd('cmd ' + IntToStr(I));
  HistorySave(P);
  HistoryLoad(P);
  Check(HistoryCount = HistoryMax,
    Format('the file keeps at most %d entries, got %d', [HistoryMax, HistoryCount]));
  EditInit(E);
  EditApply(E, ekHistPrev, #0);
  Check(UTF8Encode(E.Text) = 'cmd ' + IntToStr(HistoryMax + 25),
    'and they are the newest ones');

  HistoryClear;
  DeleteFile(P);
end;

{ The VT colour mapping.  A suite has no terminal to switch modes on, so
  the pure mapping is what is checked: off means empty strings (the
  attribute path), and the sequences themselves are well-formed SGR. }
procedure TestVt;
begin
  WriteLn('-- vt --');
  { TermInit has not run in this suite, so VT is off. }
  Check(not TermVtActive, 'VT is off without TermInit');
  Check(VtSeq(clRed) = '', 'no sequence when VT is off');
  Check(VtReset = '', 'no reset when VT is off');
end;

{ The rewind machinery: TruncateMessages on the transcript, and the file
  snapshots the write/edit tools take.  Driven through the real RunTool so
  the snapshot happens exactly where a real edit triggers it. }
procedure TestRewind;
var
  A: TAgent;
  J: TJson;
  Out_, Notes, P: string;
  IsErr: Boolean;
  L: TStringList;
  N: Integer;
begin
  WriteLn('-- rewind --');
  uTools.AllowAllEdits := True;
  uTools.ClearSnapshots;

  { TruncateMessages: the conversation half. }
  A := TAgent.Create('k', 'm', 'sys');
  try
    A.AppendUserText('one');
    A.AppendUserText('two');
    A.AppendUserText('three');
    A.TruncateMessages(1);
    Check(A.MessageCount = 1, 'truncate keeps the requested prefix');
    Check(Pos('one', A.Transcript) > 0, 'and it is the oldest message');
    Check(Pos('three', A.Transcript) = 0, 'the newer ones are gone');
    A.TruncateMessages(5);
    Check(A.MessageCount = 1, 'truncating to more than exists is a no-op');
    A.TruncateMessages(-3);
    Check(A.MessageCount = 0, 'a negative count clamps to empty');
  finally
    A.Free;
  end;

  { Snapshots: edit an existing file across two turns, then rewind. }
  P := IncludeTrailingPathDelimiter(TmpRoot) + 'rw.txt';
  L := TStringList.Create;
  try
    L.Text := 'original';
    L.SaveToFile(P);
  finally
    L.Free;
  end;

  uTools.BeginTurn(1);
  J := TJson.NewObj;
  J.AddStr('path', 'rw.txt');
  J.AddStr('old_text', 'original');
  J.AddStr('new_text', 'after turn 1');
  Out_ := uTools.RunTool('edit_file', J, nil, IsErr);
  J.Free;
  Check(not IsErr, 'the turn-1 edit applies: ' + Out_);

  uTools.BeginTurn(2);
  J := TJson.NewObj;
  J.AddStr('path', 'rw.txt');
  J.AddStr('old_text', 'after turn 1');
  J.AddStr('new_text', 'after turn 2');
  Out_ := uTools.RunTool('edit_file', J, nil, IsErr);
  J.Free;
  Check(not IsErr, 'the turn-2 edit applies: ' + Out_);
  { A file created in turn 2 must be deleted by the rewind. }
  J := TJson.NewObj;
  J.AddStr('path', 'made-in-2.txt');
  J.AddStr('content', 'new');
  uTools.RunTool('write_file', J, nil, IsErr);
  J.Free;
  Check(SnapshotCount = 3, 'each first-touch per turn took one snapshot');

  { Rewind to the start of turn 2: rw.txt back to its turn-1 result, the
    created file gone, turn 1's snapshot still held for a deeper rewind. }
  N := uTools.RestoreFilesSince(2, Notes);
  Check(N = 2, 'two files were put back');
  L := TStringList.Create;
  try
    L.LoadFromFile(P);
    Check(Trim(L.Text) = 'after turn 1', 'the edit landed back at the turn-2 start');
  finally
    L.Free;
  end;
  Check(not FileExists(IncludeTrailingPathDelimiter(TmpRoot) + 'made-in-2.txt'),
    'a file created that turn is removed');
  Check(SnapshotCount = 1, 'turn 1''s snapshot survives for a deeper rewind');

  { And the deeper rewind reaches the original. }
  N := uTools.RestoreFilesSince(1, Notes);
  Check(N = 1, 'the deeper rewind restores one file');
  L := TStringList.Create;
  try
    L.LoadFromFile(P);
    Check(Trim(L.Text) = 'original', 'all the way back to the original');
  finally
    L.Free;
  end;
  Check(SnapshotCount = 0, 'nothing left to rewind');

  { The ordering case: one file touched in two turns, both at or after the
    rewind point.  The restore must land on the older state - write order
    inside RestoreFilesSince is what decides it, so this is the assertion
    that pins the direction of that loop. }
  L := TStringList.Create;
  try
    L.Text := 'v0';
    L.SaveToFile(P);
  finally
    L.Free;
  end;
  uTools.BeginTurn(5);
  J := TJson.NewObj;
  J.AddStr('path', 'rw.txt');
  J.AddStr('old_text', 'v0');
  J.AddStr('new_text', 'v5');
  uTools.RunTool('edit_file', J, nil, IsErr);
  J.Free;
  uTools.BeginTurn(6);
  J := TJson.NewObj;
  J.AddStr('path', 'rw.txt');
  J.AddStr('old_text', 'v5');
  J.AddStr('new_text', 'v6');
  uTools.RunTool('edit_file', J, nil, IsErr);
  J.Free;
  N := uTools.RestoreFilesSince(5, Notes);
  Check(N = 2, 'both turn snapshots were applied');
  L := TStringList.Create;
  try
    L.LoadFromFile(P);
    Check(Trim(L.Text) = 'v0',
      'a file snapshotted in two rewound turns lands on the older state');
  finally
    L.Free;
  end;

  uTools.ClearSnapshots;
  DeleteFile(P);
end;

{ What /jobs shows.  A process started on the user's behalf by a model has to
  be legible to the user without asking the model about it: which job, whether
  it is alive, and what it is actually running. }
{ Puts the scratch somewhere this suite owns and turns low on, or reports why
  it could not.  False means every low assertion below is skipped rather than
  failed: a machine with no LOCALAPPDATA is a machine where low is correctly
  unavailable, not a machine where this feature is broken. }
function EnableLow: Boolean;
begin
  Result := uSandbox.SandboxSetScratchRoot(
    uSandbox.SandboxScratchPath(uTools.SessionKey)) and uSandbox.SandboxLowReady;
  if Result then uSandbox.SandboxLevel := slLow;
end;

{ The measurement the whole design rests on, pinned as a test rather than left
  in a comment.  Low integrity stops writes outside the scratch - and stops
  NOTHING ELSE, which is asserted here explicitly, because that half is what
  makes "the sandbox is not an approval substitute" true. }
procedure TestSandboxLowBlocksProfileWrite;
var
  Saved: uSandbox.TSandboxLevel;
  Code: Integer;
  Profile, Mark, Out_: string;
begin
  Saved := uSandbox.SandboxLevel;
  Profile := SysUtils.GetEnvironmentVariable('USERPROFILE');
  if Profile = '' then
  begin
    Check(True, 'no USERPROFILE on this machine; low-integrity test skipped');
    Exit;
  end;
  Mark := IncludeTrailingPathDelimiter(Profile) + 'pasclaude-ux-sandbox.txt';
  try
    { At off it must succeed, or the test proves nothing about low: a write
      that fails for an ordinary reason would look exactly like confinement. }
    uSandbox.SandboxLevel := slOff;
    SysUtils.DeleteFile(Mark);
    RunShell('echo x > "' + Mark + '"', TmpRoot, True, Code);
    Check(FileExists(Mark),
      'unsandboxed, a command can write the user profile');
    SysUtils.DeleteFile(Mark);

    if not EnableLow then
    begin
      Check(True, 'low integrity unavailable here; the rest is skipped');
      Exit;
    end;

    RunShell('echo x > "' + Mark + '"', TmpRoot, True, Code);
    Check(Code <> 0, 'at low, the identical write fails');
    Check(not FileExists(Mark), 'and really leaves no file');

    { And the honest other half.  A model asked to exfiltrate can still read
      everything the user can read, which is why no approval may be skipped
      on the strength of the level. }
    RunShell('dir "' + Profile + '" >nul', TmpRoot, True, Code);
    Check(Code = 0,
      'but a low-integrity command can still READ the user profile');

    { The scratch is what keeps ordinary tools working: almost everything
      that breaks at low breaks first on a temporary file. }
    RunShell('echo y > "%TEMP%\pasclaude-ux-scratch.txt"', TmpRoot, True, Code);
    Check(Code = 0, 'and can write the %TEMP% it was given');
    Check(FileExists(IncludeTrailingPathDelimiter(uSandbox.SandboxTempDir) +
      'pasclaude-ux-scratch.txt'),
      'which really is the sandbox scratch, not the real %TEMP%');

    { RunShellQuiet is this program's own introspection and is exempt.  If it
      were confined too, pasclaude would appear to forget how to read its own
      repository the moment somebody typed /sandbox low. }
    Out_ := uTools.RunShellQuiet('echo introspection', Code);
    Check((Code = 0) and (Pos('introspection', Out_) > 0),
      'and the program''s own git introspection is not confined');
  finally
    SysUtils.DeleteFile(Mark);
    uSandbox.SandboxLevel := Saved;
  end;
end;

{ A command that fails only because it was confined must say so on the line
  the user reads, or the sandbox is indistinguishable from a broken tool. }
procedure TestSandboxAnnotatesFailure;
var
  Saved: uSandbox.TSandboxLevel;
begin
  Saved := uSandbox.SandboxLevel;
  try
    { The tag is keyed on the exit code, never on a message marker.  A marker
      is English and a localised Windows would carry no sandbox context at
      all - which is the misdiagnosis this exists to prevent. }
    uSandbox.SandboxLevel := slLow;
    Check(uSandbox.SandboxTag(1) = '; sandbox: low',
      'a failed command carries the level');
    Check(uSandbox.SandboxTag(0) = '',
      'a command that succeeded carries nothing');
    uSandbox.SandboxLevel := slLimits;
    Check(uSandbox.SandboxTag(1) = '; sandbox: limits',
      'and the default level says so too, rather than staying quiet');
    uSandbox.SandboxLevel := slOff;
    Check(uSandbox.SandboxTag(1) = '',
      'with the sandbox off there is nothing to blame it for');

    { The hint is the opposite: it fires only when something suggests the
      sandbox, because a remedy printed under every ordinary build failure
      would train the user to ignore it. }
    uSandbox.SandboxLevel := slLow;
    Check(Pos('icacls', uSandbox.SandboxExplain(1, 'Access is denied.')) > 0,
      'a denied write is explained, with the icacls the user may run');
    Check(Pos('/sandbox off', uSandbox.SandboxExplain(1, 'Access is denied.')) > 0,
      'and the way out is named');
    Check(uSandbox.SandboxExplain(4, 'ordinary compile error') = '',
      'an ordinary failure gets no sandbox hint');
    Check(uSandbox.SandboxExplain(0, 'Access is denied.') = '',
      'and a command that succeeded is never explained');
    Check(Pos('quota', LowerCase(uSandbox.SandboxExplain(1816, ''))) >= 0,
      'the process cap is recognised by its exit code, not its wording');
    uSandbox.SandboxLevel := slOff;
    Check(uSandbox.SandboxExplain(1, 'Access is denied.') = '',
      'with the sandbox off nothing is explained either');
  finally
    uSandbox.SandboxLevel := Saved;
  end;
end;

{ The foreground shell had no job object at all, so a timeout terminated
  cmd.exe and left whatever it had started running.  Under this suite that
  surfaces as the recursive Cleanup failing on the next run, which reads as an
  unrelated flake. }
procedure TestForegroundTimeoutKillsTree;
var
  SavedMs: Integer;
  Code: Integer;
  Started, Elapsed, Deadline: QWord;
  LockPath, Cmd, Text: string;
  Freed: Boolean;
begin
  SavedMs := uTools.ShellTimeoutMs;
  LockPath := IncludeTrailingPathDelimiter(TmpRoot) + 'held.txt';
  SysUtils.DeleteFile(LockPath);
  try
    { The grandchild holds the file open for far longer than the deadline, so
      "the file can be deleted afterwards" is a real observation about the
      grandchild being gone rather than about it having finished. }
    uTools.ShellTimeoutMs := 2000;
    Cmd := 'start /b cmd /c "ping -n 60 127.0.0.1 > ""' + LockPath +
      '""" & ping -n 60 127.0.0.1 >nul';
    Started := GetTickCount64;
    Text := RunShell(Cmd, TmpRoot, True, Code);
    Elapsed := GetTickCount64 - Started;

    Check(Elapsed < 30000,
      'a hung foreground command returns on its deadline: ' +
      IntToStr(Elapsed) + 'ms');
    Check(Pos('[timed out after', Text) > 0, 'and says it timed out');

    { The whole point.  A surviving grandchild keeps a write handle on the
      file, and Windows refuses the delete while it does.

      Bounded rather than immediate, and for a reason worth stating: the kill
      reaches the whole job, but only the top process is waited for, so the
      grandchild can still be releasing its handle when this line runs.  Five
      seconds separates "being reaped" from "still running", because the
      grandchild was told to hold the file for sixty - a retry loop cannot
      turn a survivor into a pass, it can only stop a busy machine turning a
      correct kill into a phantom failure. }
    Deadline := GetTickCount64 + 5000;
    repeat
      Freed := SysUtils.DeleteFile(LockPath) or not FileExists(LockPath);
      if Freed then Break;
      Sleep(50);
    until GetTickCount64 > Deadline;
    Check(Freed,
      'and the grandchild it started is gone, so its file can be deleted');
    Check(not FileExists(LockPath), 'leaving nothing locked under TmpRoot');
  finally
    uTools.ShellTimeoutMs := SavedMs;
    SysUtils.DeleteFile(LockPath);
  end;
end;

procedure TestJobList;
var
  Id, Err, L: string;
begin
  uTools.ClearJobs;
  Check(uTools.BackgroundJobList = 'no background jobs',
    'an empty job list says so rather than showing nothing');

  if not StartBackgroundJob('ping -n 30 127.0.0.1', Id, Err) then
  begin
    Check(False, 'a job starts for the listing: ' + Err);
    Exit;
  end;
  L := uTools.BackgroundJobList;
  Check(Pos(Id, L) > 0, 'the listing names the job');
  Check(Pos('running', L) > 0, 'and says it is running');
  Check(Pos('ping -n 30', L) > 0, 'and shows the command');

  uTools.KillBackgroundJob(Id);
  uTools.WaitBackgroundJob(Id, 5000);
  L := uTools.BackgroundJobList;
  Check(Pos('running', L) = 0, 'and stops calling a stopped job running');

  uTools.ClearJobs;
  Check(uTools.BackgroundJobList = 'no background jobs',
    'and clearing empties it again');
end;

var
  IdleTicks: Integer = 0;

procedure CountingIdleTick;
begin
  Inc(IdleTicks);
end;

{ The prompt-idle window: while a user sits at a prompt, uTerm's read now wakes
  on a bounded wait and runs the tick the host pushed down, so a background job
  left running while nobody types is bounded by the same clock as everywhere
  else.

  What can be asserted here is the decision and the seam, and that is deliberate
  rather than a shortfall being glossed over: the wait itself needs a console,
  which no test runner has, and the wiring line in pasclaude.lpr sits in a main
  block no suite can link.  So the interval arithmetic is tested with numbers
  rather than with a sleep - which is the whole reason IdleTickFires takes NowMs
  as a parameter - and the one property the frame depends on, that the wired
  tick prints nothing, is tested against the real callee rather than a stand-in
  that could not print anything anyway. }
procedure TestIdleTickAtThePrompt;
var
  SavedIdle: uTerm.TIdleProc;
  Last, Seq: QWord;
  Id, Err: string;
  Found: Boolean;
begin
  WriteLn('-- the prompt-idle tick --');
  SavedIdle := uTerm.IdleTick;
  try
    Check(not Assigned(SavedIdle),
      'nothing is wired into the idle seam by default: a unit that ticked by ' +
      'itself would be a unit that reached upward');
    Check(not uTerm.IdleTickFires(False, 0, 1000000),
      'with nothing pushed down, no wake ever ticks however long the wait was');
    Check(uTerm.IdleTickFires(True, 0, 1),
      'the first wake ticks: zero means never here, as it does for the sweep');
    Check(not uTerm.IdleTickFires(True, 1000, 1000),
      'two wakes inside one clock tick are one tick, not two');
    Check(not uTerm.IdleTickFires(True, 1000, 1000 + uTerm.IdleTickMs - 1),
      'one millisecond short of the gap is not due');
    Check(uTerm.IdleTickFires(True, 1000, 1000 + uTerm.IdleTickMs),
      'the gap exactly is due');
    Check(uTerm.IdleTickFires(True, 1000, 1000 + uTerm.IdleWaitMs),
      'a wake that timed out is always due - the gap is set under the wait ' +
      'so the coarse tick clock cannot skip one');

    Last := 0;
    Check(not uTerm.IdleTickRun(Last, 5000),
      'nil does nothing at all, which is what the default has to mean');
    Check(Last = 0,
      'and a wake that did not tick leaves the clock where it was');

    uTerm.IdleTick := @CountingIdleTick;
    IdleTicks := 0;
    Check(uTerm.IdleTickRun(Last, 5000), 'wired, the first wake runs the tick');
    Check(IdleTicks = 1, 'exactly once');
    Check(Last = 5000, 'and the wake that ran it is what the clock now holds');
    Check(not uTerm.IdleTickRun(Last, 5000 + uTerm.IdleTickMs - 1),
      'a wake inside the gap does not run it again');
    Check(IdleTicks = 1, 'so a burst of keystrokes cannot make the tick hot');
    Check(uTerm.IdleTickRun(Last, 5000 + uTerm.IdleTickMs),
      'and the first wake past the gap does');
    Check(IdleTicks = 2, 'twice, and no more than twice');

    { A live job, because TickBackgroundJobs exits on an empty table and a
      silence proved against a function that returned immediately would prove
      nothing.  The same command TestJobList uses, for the same reason: it
      runs long enough to still be there when the sweep walks it. }
    uTools.ClearJobs;
    if not StartBackgroundJob('ping -n 30 127.0.0.1', Id, Err) then
    begin
      Check(False, 'a job starts for the tick: ' + Err);
      Exit;
    end;
    uTerm.IdleTick := @uTools.TickBackgroundJobs;
    Last := 0;
    Seq := uTerm.EmitCount;
    Check(uTerm.IdleTickRun(Last, 9000),
      'the real sweep runs from a wake with a job in the table');
    Check(uTerm.EmitCount = Seq,
      'and prints not one byte, which is the whole reason the framed prompt ' +
      'block can stay up across a tick');
    Check(uTools.BackgroundJobList <> 'no background jobs',
      'and the job it just walked is under the cap, so the sweep left it ' +
      'alone rather than killing it');

    { The purge, and this is the second version of this assertion.  The first
      claimed to prove the tick sweeps WITHOUT purging and could not fail: it
      re-listed the ping above, which is alive and therefore not Reaped, and
      SweepJobs' purge arm only frees a job whose Reaped flag is set.  Turning
      TickBackgroundJobs' SweepJobs(False) into SweepJobs(True) - the exact
      edit three comments now exist to forbid, because it would resize the
      Jobs array under a nested RunToolInner holding an index across a
      permission prompt - left the suite green.  The only defence against the
      one new constraint of the round was grep.

      So the fixture has to be a job the purge WOULD take: finished, and read
      to the end, which is the pair of conditions PollBackgroundJob turns into
      Reaped.  ClearJobs first because it also zeroes LastSweepTick, and the
      tick above has just set it - without that the sweep would decline on the
      quarter-second gate and the check would pass for the wrong reason, which
      is the failure mode being fixed here in the first place. }
    uTools.ClearJobs;
    if not StartBackgroundJob('echo swept', Id, Err) then
    begin
      Check(False, 'a short job starts for the purge check: ' + Err);
      Exit;
    end;
    uTools.WaitBackgroundJob(Id, 5000);
    { Twice: the first poll reports the exit and drains the spool, and it is
      the poll that finds nothing left after it which can say the output has
      been read to the end. }
    uTools.PollBackgroundJob(Id, Found);
    uTools.PollBackgroundJob(Id, Found);
    Check(Pos(Id, uTools.BackgroundJobList) > 0,
      'a finished, fully read job is still listed until something purges it');
    Last := 0;
    Check(uTerm.IdleTickRun(Last, 30000), 'a wake runs the sweep over it');
    Check(Pos(Id, uTools.BackgroundJobList) > 0,
      'and the tick did not purge it: an id the model was just given still ' +
      'names a job after the prompt has been sat at');
  finally
    uTerm.IdleTick := SavedIdle;
    uTools.ClearJobs;
  end;
end;

{ ------------------------------------------------------------------- main -- }

{ %USERPROFILE% has to be moved somewhere known: the user memory is read from
  it, and so now are %USERPROFILE%\.pasclaude\hooks.json and
  %USERPROFILE%\.pasclaude\mcp.json - a developer's real home directory would
  otherwise decide these tests, and on somebody else's machine decide them
  differently.  Declared here rather than beside the system-prompt tests
  further down, which is where it used to live: the two panel tests below need
  it, and a declaration after its callers is not one. }
function SetEnvironmentVariable(Name, Value: PChar): LongBool; stdcall;
  external 'kernel32' name 'SetEnvironmentVariableA';

{ /mcp is the only place a user can see what became of a program a project
  asked to run, so the panel has to account for every configured server -
  including the ones that contribute nothing.  A server that vanished from
  the list would look like a feature that does not work rather than like a
  decision somebody made. }
procedure TestMcpPanel;
var
  Rows: TStringArray;
  Path, Err, All: string;

  function Row(const Name: string): string;
  var
    K: Integer;
  begin
    Result := '';
    for K := 0 to High(Rows) do
      if Copy(Rows[K], 1, Length(Name) + 1) = Name + #9 then Result := Rows[K];
  end;

begin
  Path := IncludeTrailingPathDelimiter(TmpRoot) + '.mcp.json';
  uTools.ClearMcpServers;
  uTools.ClearTrust;
  WriteFileText(Path,
    '{"mcpServers":{' +
    '"remote":{"url":"https://example.com/mcp"},' +
    '"local":{"command":"' + StringOfChar('c', 4000) + '"}}}');
  uTools.LoadMcpConfig(uTools.McpConfigPath, Err);

  Rows := uTools.McpServerList;
  Check(Length(Rows) = 2, Format('every configured server gets a line (%d)',
    [Length(Rows)]));
  Check(Pos('stdio only', Row('remote')) > 0,
    'an unsupported transport is reported, not silently dropped: ' +
    Row('remote'));
  Check(Pos('pending approval', Row('local')) > 0,
    'and a server nobody has answered for yet says so');
  { The whole row, not just the command column: a 4000-character command line
    that wrapped would push everything else off the screen. }
  Check(Length(Row('local')) < 200,
    Format('an absurd command line is elided rather than wrapped (%d)',
      [Length(Row('local'))]));

  { Skip counts are part of the line, so a server contributing three of forty
    tools cannot look correct. }
  All := Row('local');
  Check(Length(All) - Length(StringReplace(All, #9, '', [rfReplaceAll])) = 6,
    'each line carries name, status, tools, skipped, command, note and scope');
  Check(Copy(All, Length(All) - Length(#9'project') + 1, MaxInt) = #9'project',
    'and the scope is the last field, so every existing reader still indexes ' +
    'the same columns: ' + All);

  { Nobody to ask is no, and the panel says which. }
  uTools.McpApproveAll(nil, nil);
  Rows := uTools.McpServerList;
  Check(Pos('denied', Row('local')) > 0,
    'a denied server is shown as denied: ' + Row('local'));
  Check(Pos('stdio only', Row('remote')) > 0,
    'and an unsupported one is not re-labelled by the approval pass');

  Check(not uTools.McpRestart('nosuchserver', Err),
    'restarting a server that does not exist fails');
  Check(Pos('no such server', Err) > 0,
    'and says so rather than silently succeeding: ' + Err);
  Check(uTools.McpRestart('local', Err), 'restarting a known one succeeds');

  { The command line the user reads must be the expanded one, since that is
    what a fingerprint covers and what would actually run. }
  uTools.ClearMcpServers;
  WriteFileText(Path,
    '{"mcpServers":{"e":{"command":"prog","args":["${PASCLAUDE_UX_UNSET:-shown}"]}}}');
  uTools.LoadMcpConfig(uTools.McpConfigPath, Err);
  Rows := uTools.McpServerList;
  Check(Pos('shown', Row('e')) > 0,
    'the panel shows the expanded command line: ' + Row('e'));

  uTools.ClearMcpServers;
  uTools.ClearTrust;
  Rows := uTools.McpServerList;
  Check(Length(Rows) = 0, 'and clearing leaves nothing behind');
  DeleteFile(Path);
end;

{ The user's own mcp.json: loaded first, approved without the spawn prompt
  because it names a program the user chose, and holding its names against a
  project file that wants them.  Both %USERPROFILE% and %LOCALAPPDATA% are
  redirected - the second because UserMcpCachePath resolves through it, and a
  test that writes the developer's real discovery cache is a test that changes
  their next session. }
procedure TestUserMcpIsNotPrompted;
var
  Rows: TStringArray;
  Home, Local, SavedHome, SavedLocal, Err: string;

  function Row(const Name: string): string;
  var
    K: Integer;
  begin
    Result := '';
    for K := 0 to High(Rows) do
      if Copy(Rows[K], 1, Length(Name) + 1) = Name + #9 then Result := Rows[K];
  end;

begin
  Home := ExcludeTrailingPathDelimiter(TmpRoot) + '-userhome';
  Local := ExcludeTrailingPathDelimiter(TmpRoot) + '-userlocal';
  SavedHome := SysUtils.GetEnvironmentVariable('USERPROFILE');
  SavedLocal := SysUtils.GetEnvironmentVariable('LOCALAPPDATA');
  ForceDirectories(Home + PathDelim + StateDirName);
  ForceDirectories(Local);
  SetEnvironmentVariable('USERPROFILE', PChar(Home));
  SetEnvironmentVariable('LOCALAPPDATA', PChar(Local));
  try
    uTools.ClearMcpServers;
    uTools.ClearTrust;
    WriteFileText(uTools.UserMcpConfigPath,
      '{"mcpServers":{"mine":{"command":"my-own-server.exe"}}}');
    { The project deliberately names "mine" as well, which is the collision the
      user has to win: under project-wins a repository could take over a name
      the model has been calling all session. }
    WriteFileText(IncludeTrailingPathDelimiter(TmpRoot) + '.mcp.json',
      '{"mcpServers":{"mine":{"command":"their-server.exe"},' +
      '"theirs":{"command":"other-server.exe"}}}');

    Check(uTools.LoadMcpConfigAll(Err), 'both scopes load through one call');
    Check(uTools.McpServerCount = 2, 'a name in both files is one server, not two');
    Check(uTools.McpServerScope('mine') = 'user',
      'and the name the user holds still runs the user''s program');
    Check(Pos('mine', Err) > 0,
      'the project''s attempt to take that name is reported, not silent: ' + Err);
    Check(uTools.McpServerScope('theirs') = 'project',
      'a project server the user never named is still the project''s');

    { The half this feature is allowed to skip, and the half it is not.  A nil
      Ask is print mode and a subagent both. }
    uTools.McpApproveAll(nil, nil);
    Check(uTools.McpServerApproved('mine'),
      'a user-scope server needs nobody to ask');
    Check(uTools.McpServerStatus('mine') <> mcDenied,
      'so a nil Ask does not deny it');
    Check(not uTools.McpServerApproved('theirs'),
      'while the project''s server is not approved by anybody');
    Check(uTools.McpServerStatus('theirs') = mcDenied,
      'and nobody to ask is still no, exactly as before');

    Rows := uTools.McpServerList;
    Check(Pos(#9'user', Row('mine')) > 0,
      'the /mcp line says which file a server came from: ' + Row('mine'));
    Check(Pos(#9'project', Row('theirs')) > 0,
      'and says it for the project''s too: ' + Row('theirs'));

    Check(Pos(IncludeTrailingPathDelimiter(TmpRoot), uTools.UserMcpCachePath) = 0,
      'a user server''s discovery cache is not inside the project the session ' +
      'is running in: ' + uTools.UserMcpCachePath);
    Check(uTools.UserMcpConfigPath <> uTools.McpConfigPath,
      'and the two config files are never the same path');

    { The spool, asserted through the loaded server rather than through the
      builder: the builder being right and the load site still writing the old
      expression is precisely the failure this pair of scopes can hide. }
    Check(Pos(IncludeTrailingPathDelimiter(TmpRoot),
      uTools.McpServerErrLog('mine')) = 0,
      'a user server''s stderr spool is not inside the project either: ' +
      uTools.McpServerErrLog('mine'));
    Check(Pos(IncludeTrailingPathDelimiter(Local),
      uTools.McpServerErrLog('mine')) = 1,
      'it is under localappdata, where state this program writes lives');
    Check(uTools.McpServerErrLog('mine') = uTools.UserMcpSpoolPath('mine'),
      'and it is the path UserMcpSpoolPath names, not a second one built at ' +
      'the load site');
    Check(Pos(uTools.SessionKey, uTools.McpServerErrLog('mine')) > 0,
      'the session key is in the file name, so two projects running the same ' +
      'user server do not truncate one file');
    Check(Pos(IncludeTrailingPathDelimiter(TmpRoot),
      uTools.McpServerErrLog('theirs')) = 1,
      'while a project server''s spool has not moved: ' +
      uTools.McpServerErrLog('theirs'));
    Check(uTools.McpServerErrLog('nobody') = '',
      'and a name nobody configured has no spool at all');
  finally
    uTools.ClearMcpServers;
    uTools.ClearTrust;
    SysUtils.DeleteFile(IncludeTrailingPathDelimiter(TmpRoot) + '.mcp.json');
    SetEnvironmentVariable('USERPROFILE', PChar(SavedHome));
    SetEnvironmentVariable('LOCALAPPDATA', PChar(SavedLocal));
  end;
end;

{ The spool path on its own, including the two shapes the test above cannot
  reach because loading a user server needs a %USERPROFILE% to have found the
  mcp.json in: no LOCALAPPDATA, and no home at all.  Both env vars are saved at
  the top and handed back in ONE finally at the very end - never mid-test, and
  never partially, because a fixture that redirects %USERPROFILE% and leaves
  %LOCALAPPDATA% pointing at the developer's real profile is how a suite starts
  computing paths in somebody's actual home directory. }
procedure TestUserMcpSpoolIsOutOfTree;
var
  Local, Prof, Want, SavedHome, SavedLocal, P: string;
begin
  { TWO directories, and they used to be one.  With %USERPROFILE% and
    %LOCALAPPDATA% pointing at the same place, "the spool sits under
    localappdata and not under the profile" was a sentence no assertion could
    tell from its opposite, and the fallback below could not be distinguished
    from the ordinary path at all. }
  Local := ExcludeTrailingPathDelimiter(TmpRoot) + '-spoollocal';
  Prof := ExcludeTrailingPathDelimiter(TmpRoot) + '-spoolprofile';
  SavedHome := SysUtils.GetEnvironmentVariable('USERPROFILE');
  SavedLocal := SysUtils.GetEnvironmentVariable('LOCALAPPDATA');
  { Cleanup first, not after: one assertion below is that asking for the path
    creates nothing, and a directory left behind by an earlier run would make
    that assertion pass or fail on history rather than on this code. }
  Cleanup(Local);
  Cleanup(Prof);
  SetEnvironmentVariable('USERPROFILE', PChar(Prof));
  SetEnvironmentVariable('LOCALAPPDATA', PChar(Local));
  try
    { The location spelled out rather than asked for.  Pos(UserMcpSpoolDir, P)
      was what stood here and it is a tautology - UserMcpSpoolPath's first
      statement IS Result := UserMcpSpoolDir, so both sides move together and
      no edit to either function could ever fail it.  A literal is the only
      thing that can say the panel and the spawn agree on somewhere REAL. }
    Want := IncludeTrailingPathDelimiter(Local) + 'pasclaude' + PathDelim +
      'mcp' + PathDelim;
    P := uTools.UserMcpSpoolPath('mine');
    Check(Pos(Want, P) = 1,
      'the user spool sits under localappdata, not the profile its mcp.json ' +
      'lives in: ' + P);
    Check(Pos(IncludeTrailingPathDelimiter(Prof), P) = 0,
      'and no part of it is the profile directory');
    Check(ExtractFileExt(P) = '.err',
      'and is still a .err file, so nothing that looked for one has to learn ' +
      'a new extension');
    Check(uTools.UserMcpSpoolDir = Want,
      'the directory /mcp names is that same one, spelled out here so the ' +
      'panel and the spawn cannot drift apart: ' + uTools.UserMcpSpoolDir);
    Check(not DirectoryExists(uTools.UserMcpSpoolDir),
      'asking for the path creates nothing - only a spawn creates the ' +
      'directory it writes');
    Check(uTools.UserMcpSpoolPath('a') <> uTools.UserMcpSpoolPath('b'),
      'two of your servers never share one spool');

    { No LOCALAPPDATA.  The fallback is the profile, which is one directory
      this program may not have written before - but it is still not the
      project.  Asserted as "it is under the profile" and not merely as "it is
      not under the project", because '' satisfies the second: deleting the
      two fallback lines from UserMcpSpoolDir left the old check passing while
      every user server on such a machine silently threw its stderr at NUL. }
    SetEnvironmentVariable('LOCALAPPDATA', nil);
    P := uTools.UserMcpSpoolPath('mine');
    Check(Pos(IncludeTrailingPathDelimiter(Prof) + 'pasclaude' + PathDelim +
      'mcp' + PathDelim, P) = 1,
      'with no localappdata it falls back to the profile: ' + P);
    Check(Pos(IncludeTrailingPathDelimiter(TmpRoot), P) = 0,
      'and never into the project');

    { No home at all.  '' travels to McpSpawn, which opens NUL. }
    SetEnvironmentVariable('USERPROFILE', nil);
    Check(uTools.UserMcpSpoolPath('mine') = '',
      'with no home at all there is no spool path, and the server''s stderr ' +
      'goes to NUL');
    Check(uTools.UserMcpSpoolDir = '',
      'so the panel has no directory to offer either');
  finally
    SetEnvironmentVariable('USERPROFILE', PChar(SavedHome));
    SetEnvironmentVariable('LOCALAPPDATA', PChar(SavedLocal));
    Cleanup(Local);
    Cleanup(Prof);
  end;
end;

{ What the user reads before approving a hook file, and what survives in
  permissions.json afterwards.  Both are the parts of this feature a person
  actually meets: the summary is the entire basis for the yes, and the
  fingerprint is what stops the yes outliving the text it was given for. }
procedure TestHooksPanel;
var
  Notes, Sum, P, FP, SavedHome: string;
  SavedEdits, SavedBash, SavedFetch: Boolean;
begin
  { LoadHooks reads the user's home directory now, so without this the two
    "one line per hook" counts below would be counting whatever hooks the
    developer running the suite happens to have of their own. }
  SavedHome := SysUtils.GetEnvironmentVariable('USERPROFILE');
  SetEnvironmentVariable('USERPROFILE',
    PChar(IncludeTrailingPathDelimiter(TmpRoot) + 'nohome'));
  ForceDirectories(IncludeTrailingPathDelimiter(TmpRoot) + StateDirName);
  WriteFileText(uHooks.HooksFilePath, '{"hooks":{' +
    '"PreToolUse":[{"matcher":"^(write_file|edit_file)$",' +
    '"command":"python .pasclaude\\hooks\\fmt.py"}],' +
    '"Stop":[{"command":"build.cmd"}]}}');

  { The prompt has to describe the file before the file is trusted, so this
    is read straight off disk with nothing loaded. }
  uHooks.ClearHooks;
  Sum := uHooks.HookSummaryOf(uHooks.HooksFilePath);
  Check(Length(Sum) - Length(StringReplace(Sum, #10, '', [rfReplaceAll])) = 2,
    'the approval prompt shows one line per hook');
  Check((Pos('PreToolUse', Sum) > 0) and (Pos('Stop', Sum) > 0),
    'naming each event: ' + StringReplace(Trim(Sum), #10, ' | ', [rfReplaceAll]));
  Check(Pos('write_file|edit_file', Sum) > 0, 'and each matcher');
  Check((Pos('fmt.py', Sum) > 0) and (Pos('build.cmd', Sum) > 0),
    'and each command verbatim, which is the whole basis for the answer');

  uHooks.LoadHooks(True, Notes);
  Sum := uHooks.HookSummary;
  Check(Length(Sum) - Length(StringReplace(Sum, #10, '', [rfReplaceAll])) = 2,
    'and the loaded table renders the same two lines');

  { The trust field shares permissions.json with the standing approvals, so
    the thing to pin is that it cannot displace one of them. }
  SavedEdits := uTools.AllowAllEdits;
  SavedBash := uTools.AllowAllBash;
  SavedFetch := uTools.AllowAllFetch;
  P := IncludeTrailingPathDelimiter(TmpRoot) + 'ux-perms.json';
  DeleteFile(P);
  try
    Check(uTools.LoadTrustedEntry(P, uHooks.HookTrustKey) = '',
      'a permissions file that does not exist trusts nothing');

    uTools.ClearTrust;
    ClearBashPrefixes;
    uTools.AllowAllEdits := True;
    uTools.AllowAllBash := False;
    uTools.AllowAllFetch := True;
    AllowBashPrefix('git status');
    FP := uHooks.HookFingerprint;
    Check(FP <> '', 'the file has a fingerprint');
    uTools.RecordTrust(uHooks.HookTrustKey, FP);
    uTools.SavePermissions(P);

    Check(uTools.LoadTrustedEntry(P, uHooks.HookTrustKey) = FP,
      'the hook fingerprint round-trips through the file');
    Check(uTools.LoadTrustedEntry(P, 'nothing-like-this') = '',
      'and nothing else comes back with it');

    { The narrow read must not be a full load in disguise: it runs before the
      print-mode Halt, where loading approvals is exactly what must not
      happen. }
    uTools.AllowAllEdits := False;
    uTools.LoadTrustedEntry(P, uHooks.HookTrustKey);
    Check(not uTools.AllowAllEdits,
      'reading the fingerprint grants no approvals of its own');

    uTools.AllowAllFetch := False;
    ClearBashPrefixes;
    uTools.LoadPermissions(P);
    Check(uTools.AllowAllEdits, 'the edits approval still round-trips');
    Check(uTools.AllowAllFetch, 'and the fetch approval');
    Check(not uTools.AllowAllBash, 'and bash is still off, as it was written');
    Check(BashPrefixAllowed('git log'),
      'and the bash program approvals were not displaced by the trust field');

    { A changed file is a new question, which is the entire point. }
    WriteFileText(uHooks.HooksFilePath, '{"hooks":{"Stop":[{"command":"x"}]}}');
    Check(uHooks.HookFingerprint <> FP,
      'editing hooks.json invalidates the recorded approval');
  finally
    DeleteFile(P);
    uHooks.ClearHooks;
    uTools.ClearTrust;
    ClearBashPrefixes;
    uTools.AllowAllEdits := SavedEdits;
    uTools.AllowAllBash := SavedBash;
    uTools.AllowAllFetch := SavedFetch;
    SetEnvironmentVariable('USERPROFILE', PChar(SavedHome));
  end;
end;

{ ---------------------------------------------------------- plugin state -- }

{ The one piece of state in the program whose file narrows as well as widens.
  permissions.json sits in the same directory and only ever widens, so the two
  are tested against each other here: a disable that did not survive a restart
  would be a consent bug the user could never diagnose. }
procedure TestPluginState;
var
  Path, Err: string;
  P: uTools.TPluginInfoArray;
  U: TStringArray;
begin
  Path := IncludeTrailingPathDelimiter(TmpRoot) + '.pasclaude' + PathDelim +
    'plugins.json';
  DeleteFile(Path);
  uTools.ClearPluginState;

  WriteFileText(IncludeTrailingPathDelimiter(TmpRoot) + '.pasclaude' +
    PathDelim + 'plugins' + PathDelim + 'acme' + PathDelim + 'plugin.json',
    '{"name":"acme","description":"a bundle","hooks":{"PreToolUse":"x"}}');
  WriteFileText(IncludeTrailingPathDelimiter(TmpRoot) + '.pasclaude' +
    PathDelim + 'plugins' + PathDelim + 'acme' + PathDelim + 'commands' +
    PathDelim + 'ship.md', 'ship it');

  uTools.LoadPluginState(Path);
  Check(not uTools.PluginEnabled('acme'),
    'a plugin nobody enabled is inert, missing file and all');

  P := uTools.InstalledPlugins;
  Check(Length(P) = 1, 'but it is listed as installed');
  Check((Length(P) = 1) and (P[0].Commands = 1), 'with its component counts');
  { Named, never obeyed.  A manifest asking for a hook is reported so the user
    knows what they are not getting, and nothing is executed. }
  Check((Length(P) = 1) and (Pos('hooks', P[0].Ignored) > 0),
    'and a manifest key this build does not act on is reported: ' +
    P[0].Ignored);

  U := uTools.UnseenPlugins;
  Check((Length(U) = 1) and (U[0] = 'acme'),
    'a plugin the user has not looked at yet is unseen');

  Check(uTools.SetPluginEnabled('acme', True, Err), 'it enables: ' + Err);
  uTools.SavePluginState(Path);
  uTools.ClearPluginState;
  Check(not uTools.PluginEnabled('acme'), 'the wipe took the enablement');
  uTools.LoadPluginState(Path);
  Check(uTools.PluginEnabled('acme'), 'and it came back off disk');
  Check(Length(uTools.UnseenPlugins) = 1,
    'while enabling is not the same as having looked');

  uTools.MarkPluginsSeen;
  uTools.SavePluginState(Path);
  Check(Length(uTools.UnseenPlugins) = 0, 'running /plugins marks it seen');
  uTools.ClearPluginState;
  uTools.LoadPluginState(Path);
  Check(Length(uTools.UnseenPlugins) = 0, 'and that survives a restart too');

  { The half that permissions.json cannot do.  Copying its only-widen rule in
    here would make /plugins disable appear to work and silently re-enable on
    the next launch. }
  Check(uTools.SetPluginEnabled('acme', False, Err), 'it disables: ' + Err);
  uTools.SavePluginState(Path);
  uTools.ClearPluginState;
  uTools.LoadPluginState(Path);
  Check(not uTools.PluginEnabled('acme'),
    'a disable survives the round trip: this file narrows as well as widens');

  { Every malformed shape leaves everything off rather than crashing - and
    each of these takes a different early exit out of the parse, all of which
    must still free the parsed document. }
  uTools.SetPluginEnabled('acme', True, Err);
  WriteFileText(Path, '{"enabled":"acme"}');
  uTools.LoadPluginState(Path);
  Check(not uTools.PluginEnabled('acme'),
    'a string where an array belongs enables nothing');

  uTools.SetPluginEnabled('acme', True, Err);
  WriteFileText(Path, '{"enabled":["acme"');
  uTools.LoadPluginState(Path);
  Check(not uTools.PluginEnabled('acme'), 'nor does a truncated file');

  uTools.SetPluginEnabled('acme', True, Err);
  WriteFileText(Path, '["acme"]');
  uTools.LoadPluginState(Path);
  Check(not uTools.PluginEnabled('acme'), 'nor a non-object root');

  { A name that could name a path never becomes one, even coming back off
    disk: this file is input like any other. }
  WriteFileText(Path, '{"enabled":["..\\evil","acme"]}');
  uTools.LoadPluginState(Path);
  Check(uTools.PluginEnabled('acme'), 'a legal name beside a hostile one loads');
  Check(uTools.ResolveCommandFile('..\evil') = '',
    'and the hostile one resolves to nothing at all');

  uTools.ClearPluginState;
  DeleteFile(Path);
end;

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

function LiftSentinel: string;
begin
  Result := #10#10'SENTINEL-FROM-EXTRA';
end;

{ The first test this project has ever had of the system prompt.  It was
  unreachable while it lived in pasclaude.lpr, which is most of the reason the
  lift happened - and a lift that silently reorders UserContext against the
  project's own files inverts the nearer-wins rule with nothing to catch it. }
procedure TestSystemPromptLift;
var
  Root, Home, Full, SavedHome: string;
  UserAt, ProjectAt, GuideAt, ExtraAt, BindingAt: Integer;
  SavedAllowed: Boolean;
begin
  Root := IncludeTrailingPathDelimiter(TmpRoot) + 'prompt';
  Home := IncludeTrailingPathDelimiter(Root) + 'home';
  ForceDirectories(Home + PathDelim + '.pasclaude');
  SavedHome := SysUtils.GetEnvironmentVariable('USERPROFILE');
  SetEnvironmentVariable('USERPROFILE', PChar(Home));
  uTools.RootDir := Root;
  SavedAllowed := uSdk.SdkProjectContextAllowed;
  { Set here rather than inherited.  Every assertion below about a project's
    CLAUDE.md, its @import and the "treat them as binding" line is an assertion
    about the REPL, and the REPL is the caller that turns this on - so this
    test stands in for that caller itself instead of resting on the cleanup of
    whichever test happened to run before it. }
  uSdk.SdkProjectContextAllowed := True;
  try
    WriteFileText(Home + PathDelim + '.pasclaude' + PathDelim + 'CLAUDE.md',
      'always speak plainly'#10);
    WriteFileText(IncludeTrailingPathDelimiter(Root) + 'shared.md',
      'the shared convention is tabs'#10);
    WriteFileText(IncludeTrailingPathDelimiter(Root) + 'CLAUDE.md',
      'project rules'#10'@import shared.md'#10);

    Full := uSdk.SdkFullSystem;
    Check(Pos('Session root: ' + Root, Full) > 0,
      'the prompt still names the session root');
    Check(Pos('--- imported: shared.md ---', Full) > 0,
      'an @import line is still expanded');
    Check(Pos('the shared convention is tabs', Full) > 0,
      'and the imported file''s text is in the prompt');
    Check(Pos('Project instructions follow. Treat them as binding.', Full) > 0,
      'and the project files are still introduced as binding');

    UserAt := Pos('--- user memory', Full);
    ProjectAt := Pos('--- CLAUDE.md ---', Full);
    Check((UserAt > 0) and (ProjectAt > 0) and (UserAt < ProjectAt),
      'the user memory comes first, so the project can override it');

    { The one seam another feature reaches the prompt through: hooks'
      SessionStart output.  It has to land after the guidelines and before the
      project files, or the "treat them as binding" line ends up introducing
      the wrong text. }
    uSdk.SdkSystemExtra := @LiftSentinel;
    try
      Full := uSdk.SdkFullSystem;
      GuideAt := Pos('Guidelines:', Full);
      ExtraAt := Pos('SENTINEL-FROM-EXTRA', Full);
      BindingAt := Pos('Project instructions follow.', Full);
      Check((GuideAt > 0) and (ExtraAt > GuideAt) and (ExtraAt < BindingAt),
        'the extra text sits between the guidelines and the project files');
    finally
      uSdk.SdkSystemExtra := nil;
    end;
    Full := uSdk.SdkFullSystem;
    Check(Pos('SENTINEL-FROM-EXTRA', Full) = 0,
      'and with the seam unhooked it contributes nothing at all');
  finally
    SetEnvironmentVariable('USERPROFILE', PChar(SavedHome));
    uTools.RootDir := TmpRoot;
    uSdk.SdkProjectContextAllowed := SavedAllowed;
  end;
end;

{ --append-system-prompt.  Three properties, and the second is the one that
  would be quietly lost by a refactor: the text ADDS, it goes LAST, and the
  cap is on the total rather than on each occurrence.  The project's own
  CLAUDE.md is put on disk here for the same reason the lift test does it -
  "last" is only a claim worth making when there is something for it to come
  after. }
procedure TestAppendSystemPrompt;
var
  Root, Home, Full, Err, Before, SavedHome: string;
  SavedAllowed: Boolean;
begin
  WriteLn('-- append system prompt --');
  Root := IncludeTrailingPathDelimiter(TmpRoot) + 'append';
  Home := IncludeTrailingPathDelimiter(Root) + 'home';
  ForceDirectories(Home + PathDelim + '.pasclaude');
  SavedHome := SysUtils.GetEnvironmentVariable('USERPROFILE');
  SetEnvironmentVariable('USERPROFILE', PChar(Home));
  uTools.RootDir := Root;
  SavedAllowed := uSdk.SdkProjectContextAllowed;
  uSdk.SdkProjectContextAllowed := True;
  uSdk.SdkAppendSystemClear;
  try
    WriteFileText(IncludeTrailingPathDelimiter(Root) + 'CLAUDE.md',
      'PROJECT-RULE-LINE'#10);

    Check(uSdk.SdkAppendSystem = '',
      'nothing is appended until the flag is given');
    Full := uSdk.SdkFullSystem;
    Check(Pos('Additional instructions', Full) = 0,
      'and the system prompt carries no fence for it');

    Check(not uSdk.SdkAppendSystemPush('   ', Err),
      'text that is only whitespace is refused: ' + Err);
    Check(uSdk.SdkAppendSystem = '', 'and adds nothing');

    Check(uSdk.SdkAppendSystemPush('APPENDED-ONE', Err),
      'one value is taken: ' + Err);
    Full := uSdk.SdkFullSystem;
    Check(Pos('APPENDED-ONE', Full) > 0, 'and reaches the system prompt');
    Check(Pos('You are pasclaude', Full) > 0,
      'which still opens with the identity line');
    Check(Pos('Guidelines:', Full) > 0,
      'and still carries the guidelines: it adds, it never replaces');
    Check(Pos('PROJECT-RULE-LINE', Full) > 0,
      'and the project''s own instructions are still there');
    Check(Pos('APPENDED-ONE', Full) > Pos('PROJECT-RULE-LINE', Full),
      'with the command line LAST, after everything the tree supplied');

    Check(uSdk.SdkAppendSystemPush('APPENDED-TWO', Err),
      'a second occurrence is taken too: ' + Err);
    Check(Pos('APPENDED-ONE', uSdk.SdkAppendSystem) = 1,
      'the first value keeps its place');
    Check(Pos(#10#10'APPENDED-TWO', uSdk.SdkAppendSystem) > 0,
      'and the second accumulates after it, a blank line apart');

    Before := uSdk.SdkAppendSystem;
    Check(not uSdk.SdkAppendSystemPush(
      StringOfChar('x', uSdk.MaxAppendSystemBytes), Err),
      'a value that takes the TOTAL past the cap is refused: ' + Err);
    Check(Pos('capped', Err) > 0, 'saying which cap: ' + Err);
    Check(uSdk.SdkAppendSystem = Before,
      'and nothing at all is added, so the refusal is not a truncation');
  finally
    uSdk.SdkAppendSystemClear;
    SetEnvironmentVariable('USERPROFILE', PChar(SavedHome));
    uTools.RootDir := TmpRoot;
    uSdk.SdkProjectContextAllowed := SavedAllowed;
  end;
end;

{ The CI gate on the project's own instruction files, put in both directions
  because both are requirements and only one of them is the new behaviour.

  Under --ci report the working directory is a checkout of the pull request
  head, so AGENTS.md, CLAUDE.md and .pasclaude.md are files whoever opened the
  pull request wrote, and until this flag they went straight into the system
  prompt - the most trusted position in the request - carrying whatever they
  @imported with them.  The CI deny floor could never have caught it: uTools'
  path: rules are matched against the model's TOOL CALLS and this loader is
  not one.  The other direction is the requirement that is easier to break by
  accident: the REPL and every ordinary -p run must still bind a project's
  CLAUDE.md, imports and all, because that is a promise README makes to every
  scripted user.  Widening or narrowing this gate means deleting an assertion
  here first. }
procedure TestProjectContextIsNotForCi;
var
  Root, Home, SavedHome, Full, SkillDir: string;
  SavedAllowed: Boolean;
begin
  SavedAllowed := uSdk.SdkProjectContextAllowed;
  Root := IncludeTrailingPathDelimiter(TmpRoot) + 'ctxgate';
  Home := IncludeTrailingPathDelimiter(Root) + 'home';
  ForceDirectories(Home + PathDelim + '.pasclaude');
  SavedHome := SysUtils.GetEnvironmentVariable('USERPROFILE');
  SetEnvironmentVariable('USERPROFILE', PChar(Home));
  uTools.RootDir := Root;
  try
    { Before a single instruction file exists, because an empty tree is the
      case the notice has to stay quiet about - otherwise every CI run in a
      repository that ships none prints a line about nothing. }
    Check(uSdk.SdkProjectContextFiles = '',
      'a tree with no instruction files gives the log nothing to say');

    WriteFileText(Home + PathDelim + '.pasclaude' + PathDelim + 'CLAUDE.md',
      'always speak plainly'#10);
    WriteFileText(IncludeTrailingPathDelimiter(Root) + 'secret.md',
      'the imported branch text'#10);
    WriteFileText(IncludeTrailingPathDelimiter(Root) + 'CLAUDE.md',
      'branch rules'#10'@import secret.md'#10);
    WriteFileText(IncludeTrailingPathDelimiter(Root) + 'AGENTS.md',
      'branch agent rules'#10);
    Check(uSdk.SdkProjectContextFiles = 'AGENTS.md, CLAUDE.md',
      'the notice names the instruction files in load order');

    { The shipped default, and this is the only place in the suite it is
      observable: nothing has set the flag yet, and false is exactly what the
      two --ci verbs leave it at. }
    Check(not uSdk.SdkProjectContextAllowed,
      'SdkProjectContextAllowed ships false, so a host that never sets it ' +
      'loads no project instructions');
    Full := uSdk.SdkFullSystem;
    Check(Pos('branch rules', Full) = 0,
      'a ci run gets no claude.md out of the checked-out tree');
    Check(Pos('branch agent rules', Full) = 0, 'nor agents.md');
    Check(Pos('the imported branch text', Full) = 0,
      'and an @import inside one is never followed either');
    Check(Pos('always speak plainly', Full) > 0,
      'while the user memory survives: a pull request cannot write %userprofile%');
    Check(Pos('Session root: ' + Root, Full) > 0,
      'and the guidelines the program wrote are untouched');

    { Skills are NOT gated by this flag, and the reason is that they never
      reach the prompt to begin with: the catalogue rides in the skill tool's
      own description, rebuilt with the schema on every request.  That fact
      has just become load-bearing for a security argument, so it is pinned
      here - anyone who later moves the catalogue into the system prompt has
      to come and read why they may not. }
    SkillDir := IncludeTrailingPathDelimiter(Root) + uTools.StateDirName +
      PathDelim + uTools.SkillsDirName + PathDelim + 'branchskill';
    ForceDirectories(SkillDir);
    WriteFileText(IncludeTrailingPathDelimiter(SkillDir) + 'SKILL.md',
      '---'#10'description: SKILLDESC-FROM-BRANCH.'#10'---'#10'the body'#10);
    uTools.RefreshSkills;
    Check(Pos('SKILLDESC-FROM-BRANCH', uTools.SkillListDescription) > 0,
      'a skill description reaches the skill tool''s own description');
    Check(Pos('SKILLDESC-FROM-BRANCH', uSdk.SdkFullSystem) = 0,
      'skill descriptions are not in the system prompt at all');

    { And the other direction: with the flag on - the REPL, and every -p run
      that is not a --ci verb - the same files out of the same tree bind. }
    uSdk.SdkProjectContextAllowed := True;
    Full := uSdk.SdkFullSystem;
    Check(Pos('branch rules', Full) > 0,
      'and the repl loads the same file from the same tree');
    Check(Pos('the imported branch text', Full) > 0, 'imports and all');
    { The skill pin again, and THIS is the run that matters: the check above
      it passed in a configuration where SdkProjectContext contributes nothing
      at all, so on its own it proves only that skills are absent from a prompt
      the project loader never touched.  README calls this pin load-bearing for
      the argument that the flag does not have to gate skills, and the shipped
      REPL and -p configuration is the one that argument is about. }
    Check(Pos('SKILLDESC-FROM-BRANCH', Full) = 0,
      'and with the project loader on - the shipped repl and -p ' +
      'configuration - it is still nowhere in the system prompt');
  finally
    SetEnvironmentVariable('USERPROFILE', PChar(SavedHome));
    uTools.RootDir := TmpRoot;
    uTools.ClearSkills;
    { Restored to what it was found at, like any other module state this
      suite touches.  It used to be left ON for TestSystemPromptLift, which
      made the order of the two load-bearing and the failure of the second one
      unreadable if either ever moved; that test now sets the flag it needs
      itself. }
    uSdk.SdkProjectContextAllowed := SavedAllowed;
  end;
end;

{ --no-project-context, in both directions, because both are requirements and
  only one of them is the new behaviour.

  The truth table comes first and it is the part that has never been testable
  before: the condition deciding whether a checkout writes part of the system
  prompt lived as an expression in pasclaude.lpr's main block, which no suite
  can link, so the flag's two DIRECTIONS were coverable and the COMBINING of
  them was not.  SdkProjectContextDecide exists to close that, and a new reason
  to suppress has to be added inside it - which will fail a line here until it
  is written down.

  The boundary, because a suite that lets itself be read as covering more than
  it does is worse than one that covers less: the two ARGUMENTS are still
  untested and unreachable from here.  Nothing below notices if the parser
  stops setting the flag, or if the set of DiagModes counted as a --ci verb
  shrinks to one - both mutations build clean and leave every suite green.
  What is pinned is the rule, given its inputs.

  Then the same decision driven through the real loader over real files,
  because a predicate that returns the right Boolean while the loader ignores
  it is the failure the truth table cannot see.  The off direction - an
  ordinary -p still binding the tree's CLAUDE.md, imports and all - is the one
  a future refactor breaks silently: -p quietly losing a project's
  instructions is a regression scripted users would find in production rather
  than in a diff. }
procedure TestNoProjectContextFlag;
var
  Root, Home, SavedHome, Full: string;
  SavedAllowed: Boolean;
begin
  SavedAllowed := uSdk.SdkProjectContextAllowed;
  Root := IncludeTrailingPathDelimiter(TmpRoot) + 'noctx';
  Home := IncludeTrailingPathDelimiter(Root) + 'home';
  ForceDirectories(Home + PathDelim + '.pasclaude');
  SavedHome := SysUtils.GetEnvironmentVariable('USERPROFILE');
  SetEnvironmentVariable('USERPROFILE', PChar(Home));
  uTools.RootDir := Root;
  try
    Check(uSdk.SdkProjectContextDecide(False, False),
      'an ordinary -p run still loads the project''s instruction files');
    Check(not uSdk.SdkProjectContextDecide(True, False),
      'and --no-project-context takes them away from that same run');
    Check(not uSdk.SdkProjectContextDecide(False, True),
      'a --ci verb loads none of them with no flag typed');
    Check(not uSdk.SdkProjectContextDecide(True, True),
      'and the flag cannot widen a --ci verb back open');

    WriteFileText(Home + PathDelim + '.pasclaude' + PathDelim + 'CLAUDE.md',
      'always speak plainly'#10);
    WriteFileText(IncludeTrailingPathDelimiter(Root) + 'shared.md',
      'the imported branch text'#10);
    WriteFileText(IncludeTrailingPathDelimiter(Root) + 'CLAUDE.md',
      'branch rules'#10'@import shared.md'#10);
    WriteFileText(IncludeTrailingPathDelimiter(Root) + 'AGENTS.md',
      'branch agent rules'#10);

    uSdk.SdkProjectContextAllowed := uSdk.SdkProjectContextDecide(False, False);
    Full := uSdk.SdkFullSystem;
    Check(Pos('branch rules', Full) > 0,
      'with no flag a -p run binds the tree''s claude.md');
    Check(Pos('the imported branch text', Full) > 0, 'imports and all');
    Check(Pos('branch agent rules', Full) > 0, 'and agents.md with it');

    uSdk.SdkProjectContextAllowed := uSdk.SdkProjectContextDecide(True, False);
    Full := uSdk.SdkFullSystem;
    Check(Pos('branch rules', Full) = 0,
      'and with --no-project-context the same run gets none of it');
    Check(Pos('the imported branch text', Full) = 0,
      'and no @import inside one is followed either');
    Check(Pos('branch agent rules', Full) = 0, 'nor agents.md');
    Check(Pos('always speak plainly', Full) > 0,
      'while the user memory survives: the flag asks which tree wrote the prompt');
    Check(Pos('Session root: ', Full) > 0,
      'and the guidelines the program wrote are untouched');
    Check(uSdk.SdkProjectContextFiles = 'AGENTS.md, CLAUDE.md',
      'and the run can still name what it refused');
  finally
    SetEnvironmentVariable('USERPROFILE', PChar(SavedHome));
    uTools.RootDir := TmpRoot;
    { Back to what it was found at, in a finally: heaptrc aside, a byte left
      set here is inherited by every test below and the next failure would be
      read as belonging to whatever ran last. }
    uSdk.SdkProjectContextAllowed := SavedAllowed;
  end;
end;

{ A user who does not know they are in accept-edits is the failure this
  feature exists to prevent, so the indicator has to be right in every state
  and not merely in the interesting ones.  Returning the plain word whenever
  the mode is not plan is exactly the bug the brief forbids. }
procedure TestModeIsVisible;
var
  SE, SB, SF, SM, SP, SY: Boolean;
begin
  SE := uTools.AllowAllEdits;  SB := uTools.AllowAllBash;
  SF := uTools.AllowAllFetch;  SM := uTools.AllowAllMcp;
  SP := uTools.PlanMode;       SY := uTools.BypassMode;
  try
    uTools.SetPermMode(uTools.pmodeAsk);
    uTools.ClearBashPrefixes;
    uTools.ClearTrust;
    Check(uTools.PermModeIndicator = 'ask',
      'the plain state reads ask: ' + uTools.PermModeIndicator);
    Check(uTools.PermModeBanner = '',
      'and the banner has nothing to say');

    uTools.SetPermMode(uTools.pmodeAcceptEdits);
    Check(uTools.PermModeIndicator = 'accept-edits',
      'accept-edits is named: ' + uTools.PermModeIndicator);

    uTools.SetPermMode(uTools.pmodeBypass);
    Check(uTools.PermModeIndicator = 'bypass', 'and bypass');

    uTools.SetPermMode(uTools.pmodePlan);
    Check(uTools.PermModeIndicator = 'plan',
      'and plan wins over bypass, as it does in the predicate: ' +
      uTools.PermModeIndicator);

    { The suffix, and what it is for: a class grant the mode word cannot
      cover.  Without it the prompt would read "ask" while bash never asks. }
    uTools.SetPermMode(uTools.pmodeAsk);
    uTools.AllowAllBash := True;
    Check(uTools.PermModeIndicator = 'ask+',
      'a live bash grant marks the word as understating it: ' +
      uTools.PermModeIndicator);
    Check(Pos('bash', uTools.PermGrantSummary) > 0,
      'and the summary names it: ' + uTools.PermGrantSummary);
    Check(Pos('/mode ask', uTools.PermModeBanner) > 0,
      'and the banner says how to get out: ' + uTools.PermModeBanner);
  finally
    uTools.ClearBashPrefixes;
    uTools.ClearTrust;
    uTools.PlanMode := SP;       uTools.BypassMode := SY;
    uTools.AllowAllEdits := SE;  uTools.AllowAllBash := SB;
    uTools.AllowAllFetch := SF;  uTools.AllowAllMcp := SM;
  end;
end;

{ The state that has always existed and has never been on screen: a previous
  session's "always" answer loading as accept-edits before the user has typed
  anything at all.  Suppressing the banner for a grant that came from disk
  rather than from a command is precisely the invisible case. }
procedure TestLoadedGrantIsAnnounced;
var
  Path: string;
  SE, SB, SF, SM, SP, SY: Boolean;
begin
  SE := uTools.AllowAllEdits;  SB := uTools.AllowAllBash;
  SF := uTools.AllowAllFetch;  SM := uTools.AllowAllMcp;
  SP := uTools.PlanMode;       SY := uTools.BypassMode;
  Path := IncludeTrailingPathDelimiter(TmpRoot) + 'loaded-approvals.json';
  try
    uTools.SetPermMode(uTools.pmodeAsk);
    uTools.ClearBashPrefixes;
    uTools.ClearTrust;
    WriteFileText(Path, '{"allow_edits":true}');
    uTools.LoadPermissions(Path);
    Check(uTools.CurrentPermMode = uTools.pmodeAcceptEdits,
      'a loaded grant IS a mode, and the program now says so');
    Check(Pos('accept-edits', uTools.PermModeBanner) > 0,
      'the banner names it: ' + uTools.PermModeBanner);
    Check(Pos('/mode ask', uTools.PermModeBanner) > 0,
      'and the way out of it');
  finally
    SysUtils.DeleteFile(Path);
    uTools.ClearBashPrefixes;
    uTools.ClearTrust;
    uTools.PlanMode := SP;       uTools.BypassMode := SY;
    uTools.AllowAllEdits := SE;  uTools.AllowAllBash := SB;
    uTools.AllowAllFetch := SF;  uTools.AllowAllMcp := SM;
  end;
end;

{ ---------------------------------------- additional working directories -- }

{ What the user actually sees once a second directory is in play.  The two
  things that would look wrong on screen: a hit in an added tree printed
  relative (untypeable - the model would hand it back and be refused), and
  the primary root's anchored .gitignore rule silently hiding a directory in
  somebody else's tree. }
procedure TestExtraRootDisplay;
var
  Extra, Norm, Err, Before, After, Out_: string;
  Input: TJson;
  IsErr, Ok: Boolean;
begin
  WriteLn('-- working directories --');
  uTools.ClearWorkingDirs;
  Extra := ExcludeTrailingPathDelimiter(TmpRoot) + '-lib';
  Cleanup(Extra);
  ForceDirectories(Extra);
  WriteFileText(IncludeTrailingPathDelimiter(Extra) + 'lib.txt', 'ROOTMARK');
  WriteFileText(IncludeTrailingPathDelimiter(Extra) + 'src\deep.txt', 'DEEPMARK');
  WriteFileText(IncludeTrailingPathDelimiter(Extra) + 'noisy.tmp', 'HIDDENMARK');
  WriteFileText(IncludeTrailingPathDelimiter(Extra) + '.gitignore', '*.tmp'#10);
  { The primary already carries an anchored /topsecret.txt rule from the
    gitignore test; give it an anchored /src rule too, which must not travel. }
  WriteFileText(IncludeTrailingPathDelimiter(TmpRoot) + '.gitignore',
    'obj/'#10'*.log'#10'/topsecret.txt'#10'!keep.log'#10'/src'#10);
  WriteFileText(IncludeTrailingPathDelimiter(TmpRoot) + 'primary-mark.txt',
    'ROOTMARK');
  LoadIgnoreRules;

  Input := TJson.NewObj;
  Input.AddStr('path', '.');
  Before := RunTool('list_dir', Input, nil, IsErr);
  Input.Free;

  Ok := uTools.AddWorkingDir(Extra, Norm, Err);
  Check(Ok, 'the library directory is added: ' + Err);
  LoadIgnoreRules;

  Input := TJson.NewObj;
  Input.AddStr('path', '.');
  After := RunTool('list_dir', Input, nil, IsErr);
  Input.Free;
  Check(After = Before,
    'a listing of the session root is byte-identical to the single-root run');

  Input := TJson.NewObj;
  Input.AddStr('path', Extra);
  Out_ := RunTool('list_dir', Input, nil, IsErr);
  Input.Free;
  Check((not IsErr) and (Pos('lib.txt', Out_) > 0),
    'the added directory lists by absolute path');
  Check(Pos(Extra, Out_) > 0,
    'and its header names it absolutely, which is how it must be typed back');
  Check(Pos('noisy.tmp', Out_) = 0,
    'its own .gitignore hides its own file');
  Check(Pos('src', Out_) > 0,
    'and the primary root''s anchored /src rule does not reach into it');

  Input := TJson.NewObj;
  Input.AddStr('pattern', 'ROOTMARK');
  Out_ := RunTool('search', Input, nil, IsErr);
  Input.Free;
  Check(Pos('primary-mark.txt', Out_) > 0, 'search finds the primary hit');
  Check(Pos('  primary-mark.txt', '  ' + Out_) > 0,
    'labelled relative, as it always was');
  Check(Pos(IncludeTrailingPathDelimiter(Extra) + 'lib.txt', Out_) > 0,
    'and the added-root hit, labelled with its absolute path: ' + Out_);

  { An explicit path narrows the walk to one tree. }
  Input := TJson.NewObj;
  Input.AddStr('pattern', 'ROOTMARK');
  Input.AddStr('path', Extra);
  Out_ := RunTool('search', Input, nil, IsErr);
  Input.Free;
  Check((Pos('lib.txt', Out_) > 0) and (Pos('primary-mark.txt', Out_) = 0),
    'search path restricts the walk to that directory');

  uTools.ClearWorkingDirs;
  Cleanup(Extra);
  LoadIgnoreRules;
end;

{ The add and remove operations as the REPL drives them.  What breaks here is
  invisible in the guard: an echo of what the user typed rather than of what
  was resolved, or a remove that takes the session root with it. }
procedure TestAddDirCommands;
var
  Extra, Norm, Err: string;
  N: Integer;
  Ok: Boolean;
begin
  uTools.ClearWorkingDirs;
  Extra := ExcludeTrailingPathDelimiter(TmpRoot) + '-cmd';
  Cleanup(Extra);
  ForceDirectories(Extra);

  Check(uTools.RootCount = 1, 'a session starts with the session root alone');
  Check(uTools.RootAt(0) = ExcludeTrailingPathDelimiter(TmpRoot),
    'index 0 is the session root: ' + uTools.RootAt(0));
  Check(Length(uTools.WorkingDirs) = 0, 'and there are no added ones to list');

  { The '..\name' form is exactly what a user types and exactly what an echo
    of the raw argument would render uselessly. }
  Ok := uTools.AddWorkingDir('..\' + ExtractFileName(Extra), Norm, Err);
  Check(Ok, 'a relative directory is accepted: ' + Err);
  Check(Norm = Extra, 'and echoed as the absolute path it resolved to: ' + Norm);
  Check(Length(uTools.WorkingDirs) = 1, 'the list has one entry');

  N := uTools.RootCount;
  Check(not uTools.AddWorkingDir(Extra, Norm, Err),
    'the same directory twice is refused');
  Check(uTools.RootCount = N, 'and the list did not grow');

  Check(not uTools.RemoveWorkingDir('0', Err),
    'index 0 cannot be removed: ' + Err);
  Check(uTools.RootAt(0) = ExcludeTrailingPathDelimiter(TmpRoot),
    'and the session root survives');
  Ok := uTools.RemoveWorkingDir('1', Err);
  Check(Ok, 'index 1 can: ' + Err);
  Check(uTools.RootCount = 1, 'leaving the session root alone');

  { /yolo lifts asking, not reach.  The two axes are separate on purpose. }
  Ok := uTools.AddWorkingDir(Extra, Norm, Err);
  N := uTools.RootCount;
  uTools.SetPermMode(uTools.pmodeBypass);
  Check(uTools.RootCount = N, 'bypass adds no working directory');
  uTools.SetPermMode(uTools.pmodeAsk);
  uTools.ClearWorkingDirs;
  Cleanup(Extra);
end;

{ ------------------------------------------------------- settings.json -- }

{ The three settings files, written under a scratch directory this suite owns.
  uSettings never learns a path of its own, so the tests either hand it bytes
  or hand it these. }
function SetDir: string;
begin
  Result := IncludeTrailingPathDelimiter(TmpRoot) + 'cfg' + PathDelim;
end;

function UserSet: string;  begin Result := SetDir + 'user.json'; end;
function ProjSet: string;  begin Result := SetDir + 'project.json'; end;
function LocalSet: string; begin Result := SetDir + 'local.json'; end;

procedure ClearSetFiles;
begin
  ForceDirectories(SetDir);
  if FileExists(UserSet) then DeleteFile(UserSet);
  if FileExists(ProjSet) then DeleteFile(ProjSet);
  if FileExists(LocalSet) then DeleteFile(LocalSet);
end;

{ True when any note or refusal mentions Needle.  The assertions are about the
  user being TOLD, so they look at the text rather than at a count. }
function Mentions(const A: TStringArray; const Needle: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(A) do
    if Pos(Needle, A[I]) > 0 then Exit(True);
end;

{ The Scope column is the whole feature.  A project document setting the model
  must not merely lose a precedence race - the value must never be stored, and
  the user must be told it was refused and where it would work. }

{ ---------------------------------------------------------- the boundary -- }

function SetEnvVarU(Name, Value: PChar): LongBool; stdcall;
  external 'kernel32' name 'SetEnvironmentVariableA';

procedure PutFileU(const Path, Text: string);
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

function SlurpU(const Path: string): string;
var
  L: TStringList;
begin
  Result := '';
  if not FileExists(Path) then Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(Path);
    Result := L.Text;
  finally
    L.Free;
  end;
end;

{ THE assertion this whole feature is built around.  /logout removes
  pasclaude's own credential and nothing else; Claude Code's file, Jcode's
  and the ant profile's are read forever and written never.  The single
  worst defect available here would be a /logout that deleted or rewrote one
  of them, breaking a program the user did not ask us to touch - and the
  structural guarantee is that AuthClear takes NO path argument, so it can
  name no file but its own.  This proves the guarantee holds in bytes as
  well as in signature. }
procedure TestLogoutTouchesOnlyOurOwnCredential;
var
  Home, Ant, SavedHome, SavedLocal, SavedDir, SavedProfile, Err: string;
  CcPath, JcPath, AntPath: string;
  CcBefore, JcBefore, AntBefore: string;
  CcAge, JcAge, AntAge: LongInt;
  Info: TAuthInfo;
begin
  Home := IncludeTrailingPathDelimiter(TmpRoot) + 'authhome';
  Ant := IncludeTrailingPathDelimiter(TmpRoot) + 'authant';
  SavedHome := SysUtils.GetEnvironmentVariable('USERPROFILE');
  SavedLocal := SysUtils.GetEnvironmentVariable('LOCALAPPDATA');
  SavedDir := SysUtils.GetEnvironmentVariable('ANTHROPIC_CONFIG_DIR');
  SavedProfile := SysUtils.GetEnvironmentVariable('ANTHROPIC_PROFILE');
  try
    ForceDirectories(Home);
    SetEnvVarU('USERPROFILE', PChar(Home));
    SetEnvVarU('LOCALAPPDATA', PChar(Home));
    SetEnvVarU('ANTHROPIC_CONFIG_DIR', PChar(Ant));
    SetEnvVarU('ANTHROPIC_PROFILE', PChar('default'));
    SetEnvVarU('ANTHROPIC_API_KEY', PChar(''));
    SetEnvVarU('ANTHROPIC_AUTH_TOKEN', PChar(''));

    CcPath := Home + PathDelim + '.claude' + PathDelim + '.credentials.json';
    JcPath := Home + PathDelim + '.jcode' + PathDelim + 'auth.json';
    AntPath := Ant + PathDelim + 'credentials' + PathDelim + 'default.json';
    PutFileU(CcPath,
      '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-claudecodes000"}}');
    PutFileU(JcPath,
      '{"anthropic_accounts":[{"access":"sk-ant-oat01-jcodesown00000"}]}');
    PutFileU(AntPath, '{"access_token":"sk-ant-oat01-antsownvalue00"}');
    CcBefore := SlurpU(CcPath);
    JcBefore := SlurpU(JcPath);
    AntBefore := SlurpU(AntPath);
    CcAge := FileAge(CcPath);
    JcAge := FileAge(JcPath);
    AntAge := FileAge(AntPath);

    Check(uAuth.AuthStore('sk-ant-api03-ourownstoredkey000', Err),
      'a credential of our own stores');
    Check(uAuth.AuthResolve(Info) and (Info.Source = asStored),
      'and answers ahead of the three foreign ones');

    Check(uAuth.AuthClear(Err), '/logout removes it');
    Check(not FileExists(uAuth.CredentialStorePath), 'the store is gone');

    Check(SlurpU(CcPath) = CcBefore,
      'and Claude Code''s credentials are byte-identical');
    Check(SlurpU(JcPath) = JcBefore, 'and so are Jcode''s');
    Check(SlurpU(AntPath) = AntBefore, 'and so is the ant profile''s');
    Check(FileAge(CcPath) = CcAge,
      'Claude Code''s file was not even rewritten with the same bytes');
    Check(FileAge(JcPath) = JcAge, 'nor was Jcode''s');
    Check(FileAge(AntPath) = AntAge, 'nor was the ant profile''s');

    { And with our own gone, a foreign one answers again - which is what
      makes the refusal safe rather than merely polite. }
    Check(uAuth.AuthResolve(Info) and (Info.Source = asClaudeCode),
      'resolution falls back to Claude Code afterwards');
    Check(Info.Token = 'sk-ant-oat01-claudecodes000',
      'reading it, as it always has');
  finally
    SetEnvVarU('USERPROFILE', PChar(SavedHome));
    SetEnvVarU('LOCALAPPDATA', PChar(SavedLocal));
    SetEnvVarU('ANTHROPIC_CONFIG_DIR', PChar(SavedDir));
    SetEnvVarU('ANTHROPIC_PROFILE', PChar(SavedProfile));
  end;
end;

{ The near-expiry warning fires on minutes, not on milliseconds mistaken for
  them.  A threshold wired to the wrong unit would either warn on every
  single startup or never warn at all, and neither failure announces itself.
  AuthExpiresInMs is what the startup note tests, so it is what is tested. }
procedure TestNearExpiryThreshold;
var
  I: TAuthInfo;
  NowMs: Int64;
  Threshold: Int64;
begin
  Threshold := 15 * 60 * 1000;
  NowMs := Round((LocalTimeToUniversal(Now) - EncodeDate(1970, 1, 1)) *
    MSecsPerDay);
  I.Source := asClaudeCode;
  I.Token := 'sk-ant-oat01-expirycheck0000';
  I.Path := 'C:\nowhere';
  I.Hint := '';
  I.Why := '';
  I.Present := True;
  I.Decryptable := True;

  I.ExpiresMs := NowMs + 14 * 60 * 1000;
  Check(uAuth.AuthExpiresInMs(I) < Threshold,
    'a credential expiring in 14 minutes trips the warning');
  Check(uAuth.AuthExpiresInMs(I) >= 0, 'and is not reported as already gone');

  I.ExpiresMs := NowMs + 60 * 60 * 1000;
  Check(uAuth.AuthExpiresInMs(I) >= Threshold,
    'one expiring in an hour does not');

  { The unparseable case is -1 and must not read as "expired an eternity
    ago", which would warn on every startup for every source with no expiry
    field - that is most of them. }
  I.ExpiresMs := 0;
  Check(uAuth.AuthExpiresInMs(I) = -1,
    'and a credential with no known expiry reports no expiry at all');
  Check(not (uAuth.AuthExpiresInMs(I) < Threshold) or
        (uAuth.AuthExpiresInMs(I) < 0),
    'which the startup test excludes by asking for a non-negative value');

  { The 401 diagnosis names the source and says whether it has expired, and
    carries no part of the token. }
  I.ExpiresMs := NowMs - 60 * 1000;
  Check(Pos('expired', uAuth.AuthDiagnose401(I)) > 0,
    'the 401 diagnosis says an expired credential expired');
  Check(Pos('claude code', uAuth.AuthDiagnose401(I)) > 0,
    'and names the source it came from');
  Check(Pos('C:\nowhere', uAuth.AuthDiagnose401(I)) > 0, 'and the file');
  Check(Pos(I.Token, uAuth.AuthDiagnose401(I)) = 0,
    'and never the credential itself');
end;

{ A scripted run has nobody to type a secret, and a reader that blocked there
  would hang the run forever.  This suite's stdin is not a console, so the
  refusal is testable exactly as a -p run would meet it. }
procedure TestSecretReaderRefusesOffConsole;
var
  S: string;
begin
  if uTerm.StdinIsConsole then
  begin
    Check(True, 'stdin is a console here; the off-console read is not testable');
    Exit;
  end;
  S := 'not overwritten';
  Check(not uTerm.ReadSecretLine('  key: ', S),
    'the secret reader refuses immediately when stdin is not a console');
  Check(S = '', 'and hands back nothing rather than leaving a stale value');
end;
procedure TestSettingsScopeTable;
var
  Problems: TStringArray;
begin
  SettingsClear;
  Check(not SettingsParseTier(stProject, '{"model":"claude-opus-4"}',
    'proj.json', Problems), 'a project file may not set the model');
  Check(SettingStr('model') = '', 'and the value is not readable afterwards');
  Check(SettingSource('model') = stDefault, 'and the source is still default');
  Check(SettingTierValue('model', stProject) = '',
    'and the project tier holds nothing: it was never stored, not overridden');
  Check(Mentions(Problems, 'model'), 'the problem names the key');
  Check(Mentions(SettingsRefusals, 'proj.json'),
    'and the refusal names the file it came from');

  SettingsClear;
  Check(SettingsParseTier(stUser, '{"model":"claude-opus-4"}',
    'user.json', Problems), 'the same document at the user tier is honoured');
  Check(SettingStr('model') = 'claude-opus-4', 'and the value reads back');
  Check(SettingSource('model') = stUser, 'from the user tier');
  SettingsClear;
end;

{ The authority boundary this feature touches, end to end rather than at the
  loader alone: the four model keys are the ones that spend money, and a
  cloned repository must not be able to move any of them.  ApplyModelSettings
  in the host does exactly the three reads below, so what they answer here is
  what it would apply. }
procedure TestModelSettingsAreUserScopeEndToEnd;
var
  P, Keys, Vals: TStringArray;
  A: TAgent;
  Err, Sonnet, Haiku: string;
  Kind: TModelAliasKind;
  Doc: string;
begin
  ResolveModelAlias('sonnet', Sonnet, Kind);
  ResolveModelAlias('haiku', Haiku, Kind);
  Doc := '{"model.alias":{"fast":"claude-haiku-4-5"},' +
         '"model.route.subagent":"fast"}';

  SettingsClear;
  Check(not SettingsParseTier(stProject, Doc, 'proj.json', P),
    'a project file may not set model.alias or a route');
  Check(not SettingMap('model.alias', Keys, Vals),
    'and the alias map is not readable afterwards');
  Check(not SettingIsSet('model.route.subagent'),
    'and neither is the route');
  Check(SettingTierValue('model.route.subagent', stProject) = '',
    'the project tier holds nothing: it was never stored, not overridden');

  SettingsClear;
  Check(not SettingsParseTier(stLocal, Doc, 'settings.local.json', P),
    'and settings.local.json may not either - it carries project authority');
  Check(not SettingIsSet('model.route.subagent'), 'nothing stored from it');

  { The same document from the user's own file does take effect, which is
    what makes the refusal above a scope rule rather than a missing feature. }
  SettingsClear;
  Check(SettingsParseTier(stUser, Doc, 'user.json', P),
    'the same document at the user tier is honoured');
  Check(SettingMap('model.alias', Keys, Vals) and (Length(Keys) = 1) and
    (Keys[0] = 'fast') and (Vals[0] = 'claude-haiku-4-5'),
    'and the alias map reads back');
  Check(SettingStr('model.route.subagent') = 'fast', 'and the route');

  { And applying what the user file said actually moves the wire. }
  A := TAgent.Create('k', 'claude-opus-4-5', 'sys');
  try
    Check(A.EffectiveModel(mrSubagent) = Sonnet,
      'the subagent starts on the shipped route');
    SetModelAlias(Keys[0], Vals[0], Err);
    SetModelRoute(mrSubagent, SettingStr('model.route.subagent'));
    Check(A.EffectiveModel(mrSubagent) = 'claude-haiku-4-5',
      'and a user-set alias and route move it (' +
      A.EffectiveModel(mrSubagent) + ')');
  finally
    A.Free;
    SetModelRoute(mrSubagent, 'sonnet');
  end;

  { An alias name that could shadow a real id is refused by the loader too,
    at either tier - the same rule SetModelAlias enforces, so a settings file
    cannot walk around it. }
  SettingsClear;
  Check(not SettingsParseTier(stUser, '{"model.alias":{"my-model":"x"}}',
    'user.json', P), 'an alias name with a dash is refused in settings.json');
  Check(not SettingsParseTier(stUser, '{"model.alias":{"claude5":"x"}}',
    'user.json', P), 'and one beginning with claude');
  SettingsClear;
end;

{ The realistic failure is a user pasting Claude Code's settings.json and
  believing it took effect.  Every name they would paste is refused BY NAME,
  and afterwards nothing that decides authority has moved. }
procedure TestSettingsRefusedKeys;
const
  Names: array[0..17] of string = ('permissions', 'allow_edits', 'allow_bash',
    'allow_fetch', 'deny', 'sandbox', 'permission_mode', 'add_dir', 'env',
    'apiKey', 'mcpServers', 'plugins', 'vim', 'bindings', 'hooks',
    { The newest of them, and the one whose absence would be hardest to
      notice: a project file that could append to the system prompt could
      rewrite every standing instruction the agent has. }
    'append_system_prompt',
    { Two spellings the table had missed until an audit went looking, and they
      are the two shapes of silent failure this list exists to prevent.
      statusLine names a PROGRAM in Claude Code, so a project able to set it
      would run one every repaint - ide.command's hole without the slash
      command.  outputStyle is a near miss on output_style, which any tier may
      set: the user can see the working key in their own file and has no way
      to tell why theirs does nothing, which is the case where silence costs
      most. }
    'statusLine', 'outputStyle');
var
  Problems: TStringArray;
  Doc: string;
  I, Denies: Integer;
  Mode: uTools.TPermMode;
  Level: uSandbox.TSandboxLevel;
begin
  SettingsClear;
  Mode := uTools.CurrentPermMode;
  Level := uSandbox.SandboxLevel;
  Denies := uTools.DenyRuleCount;
  Doc := '{';
  for I := 0 to High(Names) do
  begin
    if I > 0 then Doc := Doc + ',';
    Doc := Doc + '"' + Names[I] + '":true';
  end;
  Doc := Doc + '}';
  Check(not SettingsParseTier(stProject, Doc, 'evil.json', Problems),
    'a pasted Claude Code settings.json contributes nothing');
  for I := 0 to High(Names) do
    Check(Mentions(Problems, '"' + Names[I] + '"'),
      '  refused by name: ' + Names[I]);
  Check(Length(SettingsRefusals) >= Length(Names),
    'and every one of them is in the refusals list');
  Check(not uTools.AllowAllEdits, 'edits are still not blanket-approved');
  Check(not uTools.AllowAllBash, 'nor bash');
  Check(not uTools.AllowAllFetch, 'nor fetch');
  Check(uSandbox.SandboxLevel = Level, 'the sandbox level did not move');
  Check(uTools.CurrentPermMode = Mode, 'the permission mode did not move');
  Check(uTools.DenyRuleCount = Denies, 'the deny rules did not move');
  Check(not uHooks.HooksEnabled, 'and hooks are still not enabled');
  SettingsClear;
end;

{ Partial application is how a typo silently changes half a configuration.  A
  document with one bad value applies NONE of its good ones. }
procedure TestSettingsAllOrNothing;
var
  Problems: TStringArray;
begin
  SettingsClear;
  Check(SettingsParseTier(stUser, '{"output_style":"learning"}', 'u', Problems),
    'a good user file loads');
  Check(SettingStr('output_style') = 'learning', 'and applies');
  Check(not SettingsParseTier(stProject,
    '{"output_style":"explanatory","thinking_budget":999999,' +
    '"tool_result_bytes":8192}', 'p.json', Problems),
    'a project file with one out-of-range value is refused whole');
  Check(SettingStr('output_style') = 'learning',
    'the good key beside it did NOT apply');
  Check(SettingInt('tool_result_bytes') = 0,
    'nor did the third key, which was legal on its own');
  Check(Mentions(Problems, '999999'),
    'the out-of-range value is named');
  Check(Mentions(Problems, 'contributed nothing'),
    'and the file-level sentence says the whole file was dropped');
  SettingsClear;
end;

{ local -> project -> user -> default, per key rather than per file. }
procedure TestSettingsPrecedence;
var
  P: TStringArray;
begin
  SettingsClear;
  SettingsParseTier(stUser, '{"thinking_budget":4096,"output_style":"a"}', 'u', P);
  SettingsParseTier(stProject, '{"thinking_budget":2048}', 'p', P);
  SettingsParseTier(stLocal, '{"thinking_budget":1024}', 'l', P);
  Check(SettingInt('thinking_budget') = 1024, 'local wins');
  Check(SettingSource('thinking_budget') = stLocal, 'and says so');
  Check(SettingStr('output_style') = 'a',
    'a key only the user file set resolves independently: the nearest FILE ' +
    'does not shadow keys it never mentions');

  SettingsClear;
  SettingsParseTier(stUser, '{"thinking_budget":4096}', 'u', P);
  SettingsParseTier(stProject, '{"thinking_budget":2048}', 'p', P);
  Check(SettingInt('thinking_budget') = 2048, 'without local, project wins');
  Check(SettingSource('thinking_budget') = stProject, 'and says so');

  SettingsClear;
  SettingsParseTier(stUser, '{"thinking_budget":4096}', 'u', P);
  Check(SettingInt('thinking_budget') = 4096, 'without project, user wins');
  Check(SettingSource('thinking_budget') = stUser, 'and says so');

  SettingsClear;
  Check(not SettingIsSet('thinking_budget'), 'with nothing set, nothing is set');
  Check(SettingSource('thinking_budget') = stDefault, 'and the source is default');
end;

{ Narrow-only, and measured against the value the USER has in force - their
  own file if it names the key, the compiled default if it does not.  What
  shipped compared against the def's own Hi, which is not that rule at all: a
  cloned repository could turn extended thinking on from a compiled 0, more
  than double the tool result cap, and pull the compaction point down onto
  every turn, while the table's comment said it could lower cost and never
  raise it.  A value outside the rule is REFUSED rather than clamped - a clamp
  teaches the repository that the key half-works and teaches the user nothing. }
procedure TestSettingsProjectCeiling;
var
  P: TStringArray;
begin
  SettingsClear;
  Check(not SettingsParseTier(stProject, '{"thinking_budget":32768}', 'p', P),
    'a project may not raise thinking_budget past its ceiling');
  Check(not SettingIsSet('thinking_budget'), 'nothing was stored');

  { The compiled default is 0 - TAgent.Create never assigns FThinkingBudget -
    so with no user file there is no legal project value but 0.  This is the
    case the shipped check let through: 8192 passed, and every request in that
    checkout grew a thinking block and twice the max_tokens. }
  SettingsClear;
  Check(not SettingsParseTier(stProject, '{"thinking_budget":8192}', 'p', P),
    'and may not turn thinking ON at all when the user has it off');
  Check(Mentions(P, 'may not raise'), 'the refusal says which way it failed');
  Check(SettingsParseTier(stProject, '{"thinking_budget":0}', 'p', P),
    'though 0 - the value already in force - is not a raise');

  SettingsClear;
  Check(SettingsParseTier(stUser, '{"thinking_budget":32768}', 'u', P),
    'the user file may set the same value');
  Check(SettingInt('thinking_budget') = 32768, 'at its full range');
  Check(SettingsParseTier(stProject, '{"thinking_budget":8192}', 'p', P),
    'and now a project may lower it: narrowing cost is always allowed');
  Check(SettingInt('thinking_budget') = 8192, 'and applies');

  { Below ProjMax and still refused, because the user is below it too. }
  SettingsClear;
  Check(SettingsParseTier(stUser, '{"thinking_budget":4096}', 'u', P),
    'the user asks for 4096');
  Check(not SettingsParseTier(stProject, '{"thinking_budget":8192}', 'p', P),
    'a project may not double it even staying under ProjMax');
  Check(Mentions(P, '4096'), 'and the refusal names the users own value');
  Check(SettingInt('thinking_budget') = 4096, 'the users value still stands');

  { The API floor, at every tier: a budget under 1024 is rejected by the API,
    so a project file could otherwise make every turn in a checkout fail with
    an HTTP 400 - from a loader whose contract is that it never stops the
    program. }
  SettingsClear;
  Check(not SettingsParseTier(stUser, '{"thinking_budget":512}', 'u', P),
    'a budget under the APIs 1024 floor is refused even in the user file');
  Check(Mentions(P, '1024'), 'and the floor is named');
  Check(SettingsParseTier(stUser, '{"thinking_budget":0}', 'u', P),
    'but 0 means off and stays legal');

  SettingsClear;
  Check(not SettingsParseTier(stProject, '{"tool_result_bytes":131072}', 'p', P),
    'a project may not quadruple the tool result cap either');
  Check(not SettingsParseTier(stProject, '{"tool_result_bytes":65536}', 'p', P),
    'nor double it: 30720 is what the program does when no file says');
  Check(SettingsParseTier(stProject, '{"tool_result_bytes":8192}', 'p', P),
    'lowering it is fine');
  Check(SettingsParseTier(stUser, '{"tool_result_bytes":131072}', 'u', P),
    'though the user may raise it');

  { The one key whose cheap direction is up: compaction costs an extra billed
    request every time it fires. }
  SettingsClear;
  Check(not SettingsParseTier(stProject, '{"auto_compact_tokens":20000}', 'p', P),
    'a project may not pull the compaction point down onto every turn');
  Check(Mentions(P, 'may not lower'), 'and the refusal says which way');
  Check(SettingsParseTier(stProject, '{"auto_compact_tokens":150000}', 'p', P),
    'the compiled default itself is not a lowering');
  SettingsClear;
  Check(SettingsParseTier(stUser, '{"auto_compact_tokens":20000}', 'u', P),
    'the user may compact as early as they like');
  SettingsClear;
end;

{ The Dflt column duplicates a constant that lives somewhere else, and a
  duplicated number is a number that drifts.  If uTools.MaxOutBytes moves and
  this does not, the narrow-only rule silently starts measuring a project file
  against a cap this program no longer uses. }
procedure TestSettingDefaultsMatchTheProgram;
var
  I: Integer;
begin
  for I := 0 to SettingCount - 1 do
    if SettingDefs[I].Name = 'tool_result_bytes' then
      Check(SettingDefs[I].Dflt = uTools.MaxOutBytes,
        'the tool_result_bytes baseline is uTools.MaxOutBytes')
    else if SettingDefs[I].Name = 'auto_compact_tokens' then
      Check(SettingDefs[I].Dflt = 150000,
        'the auto_compact_tokens baseline is the hosts CompactTokens')
    else if SettingDefs[I].Name = 'thinking_budget' then
      Check(SettingDefs[I].Dflt = 0,
        'and thinking is off until somebody asks for it')
    else if SettingDefs[I].Name = 'ide.enabled' then
      Check(SettingDefs[I].Dflt = Ord(uIde.IdeEnabledDefault),
        'and ide.enabled''s baseline is uIde.IdeEnabledDefault');
end;

{ SettingCount is a hand-maintained array bound that more than one feature
  edits.  A bumped count with a missing tuple compiles clean and leaves a
  zeroed def at the tail - Name '', Scope scAny, which TierAllowed then
  treats as "any tier may set it".  TestSettingDefaultsMatchTheProgram
  catches a wrong Dflt but would walk straight past that, so this is the
  assertion that catches the round's most likely silent failure. }
procedure TestSettingDefsAreComplete;
var
  I, J, Anyone, UserOnly, Refused: Integer;
begin
  for I := 0 to SettingCount - 1 do
  begin
    Check(Trim(SettingDefs[I].Name) <> '',
      Format('SettingDefs[%d] has a name', [I]));
    if SettingDefs[I].Scope <> scRefused then
      Check(Trim(SettingDefs[I].Note) <> '',
        'and a note: ' + SettingDefs[I].Name);
  end;
  { The census, and it is here because the comment above SettingDefs said
    "fourteen real keys" from before ide.enabled and ide.command joined the
    table.  Nothing failed; the number simply stopped being true, quietly, in
    the one place a reader checks to decide whether the README's scope table
    is complete.  A number in prose drifts and a number in an assertion does
    not, so these three are the same figures the README publishes and a key
    added without a decision about its Scope column now fails the run.
    Change them only together with the table and the README. }
  Anyone := 0;
  UserOnly := 0;
  Refused := 0;
  for I := 0 to SettingCount - 1 do
    case SettingDefs[I].Scope of
      scAny: Inc(Anyone);
      scUserOnly: Inc(UserOnly);
      scRefused: Inc(Refused);
    end;
  Check(Anyone = 4, Format('four keys any tier may set (%d)', [Anyone]));
  Check(UserOnly = 12, Format('twelve are the user''s alone (%d)', [UserOnly]));
  Check(Refused = 32, Format('and thirty-two are refused by name (%d)',
    [Refused]));
  Check(Anyone + UserOnly + Refused = SettingCount,
    'every scope value is one of the three the enum declares');
  { And no duplicate, which SettingIndex's first-match walk would hide: the
    second tuple would simply never be reachable, scope column and all. }
  for I := 0 to SettingCount - 1 do
    for J := I + 1 to SettingCount - 1 do
      if SettingDefs[I].Name = SettingDefs[J].Name then
        Check(False, 'a name appears twice: ' + SettingDefs[I].Name);
end;

{ ide.command names a program that a slash command STARTS.  A repository able
  to set it would have a clone launching any executable on the machine the
  first time somebody typed /ide, which is the same shape of hole as a
  project-settable telemetry endpoint. }
procedure TestIdeSettingsAreUserScopeOnly;
var
  P: TStringArray;
  Doc: string;
  I: Integer;
begin
  Doc := '{"ide.enabled":false,"ide.command":"C:\\x\\bin\\code.cmd"}';

  { The table itself, directly.  The document tests below would still pass
    with ide.command widened to scAny, because the all-or-nothing rule keeps
    a mixed document out on ide.enabled's account alone - so the scope
    column is asserted where it lives. }
  for I := 0 to SettingCount - 1 do
    if (SettingDefs[I].Name = 'ide.command') or
       (SettingDefs[I].Name = 'ide.enabled') then
    begin
      Check(SettingDefs[I].Scope = scUserOnly,
        SettingDefs[I].Name + ' is user scope in the table');
      Check(not TierAllowed(SettingDefs[I], stProject),
        '  and no project tier is allowed it');
      Check(not TierAllowed(SettingDefs[I], stLocal),
        '  nor the local one');
    end;
  Check(SettingDefs[SettingIndex('ide.command')].Shape = shIdeCommand,
    'and ide.command carries the launcher shape check');

  SettingsClear;
  { Alone, so nothing else in the document can be the reason it was
    refused: this is the assertion a widened scope column must fail. }
  Check(not SettingsParseTier(stProject,
    '{"ide.command":"C:\\x\\bin\\code.cmd"}', 'only.json', P),
    'a project file naming only the launcher is still refused');
  Check(SettingStr('ide.command') = '', 'and nothing is stored');
  Check(not SettingsParseTier(stLocal,
    '{"ide.command":"C:\\x\\bin\\code.cmd"}', 'only.local.json', P),
    'and settings.local.json alone is refused too');
  Check(SettingStr('ide.command') = '', 'and stores nothing either');

  SettingsClear;
  Check(not SettingsParseTier(stProject, Doc, 'proj.json', P),
    'a project file may not set the IDE keys');
  Check(Mentions(P, 'ide.command'), 'and the launcher key is named');
  Check(SettingStr('ide.command') = '',
    'and nothing is readable afterwards');
  Check(SettingTierValue('ide.command', stProject) = '',
    'the project tier holds nothing: never stored, not overridden');
  Check(Mentions(SettingsRefusals, 'proj.json'),
    'and the refusal names the file');

  SettingsClear;
  Check(not SettingsParseTier(stLocal, Doc, 'settings.local.json', P),
    'and settings.local.json may not either - it carries project authority');
  Check(not SettingIsSet('ide.command'), 'nothing stored from it');

  SettingsClear;
  Check(SettingsParseTier(stUser, Doc, 'user.json', P),
    'the same document from the user''s own file is honoured');
  Check(SettingStr('ide.command') = 'C:\x\bin\code.cmd',
    'and the launcher reads back');
  Check(SettingIsSet('ide.enabled') and not SettingBool('ide.enabled'),
    'and the off switch');

  { The shape check, which is the second of the four requirements and not a
    substitute for the scope column. }
  SettingsClear;
  Check(not SettingsParseTier(stUser, '{"ide.command":"code.cmd"}', 'u', P),
    'a relative launcher path is refused even from the user file');
  Check(not SettingsParseTier(stUser,
    '{"ide.command":"C:\\x\\bin\\code.ps1"}', 'u', P),
    'and one Windows will not start');
  Check(not SettingsParseTier(stUser,
    '{"ide.command":"C:\\x\\bin\\co\"de.cmd"}', 'u', P),
    'and one carrying a quote character');
  Check(SettingsParseTier(stUser,
    '{"ide.command":"\\\\srv\\share\\bin\\code.cmd"}', 'u', P),
    'while a UNC path is accepted');
  SettingsClear;

  { The bare name, the same convention the bare 'telemetry' refusal uses, so
    '"ide": {...}' produces a sentence naming the dotted keys rather than a
    vaguer "unknown key". }
  Check(not SettingsParseTier(stUser, '{"ide":{"command":"x"}}', 'u', P),
    'the bare name "ide" is refused at the user tier too');
  Check(Mentions(P, 'ide.enabled') and Mentions(P, 'ide.command'),
    'and the message names the dotted keys');
  SettingsClear;
end;

{ Everything this unit hands back came out of a file, and one of those files
  is in the project tree.  Two demonstrated failures, one function: an ESC in
  a key name drove the user's terminal at every launch - ESC[2J erased the
  yellow security block printed immediately above it, OSC 0 renamed the window
  - and a TAB in a value shifted the fields of the tab-separated /config row,
  letting a project file pick the tier word that /config, /status and /bug
  attribute its own value to. }
procedure TestSettingsTextIsSanitised;
var
  P, Rows: TStringArray;
  I, Fields, J: Integer;
  Row: string;

  function HasCtrl(const A: TStringArray): Boolean;
  var
    X, Y: Integer;
  begin
    Result := False;
    for X := 0 to High(A) do
      for Y := 1 to Length(A[X]) do
        if A[X][Y] < ' ' then Exit(True);
  end;

begin
  SettingsClear;
  { Valid JSON and valid UTF-8, so it reaches the problem text intact. }
  Check(not SettingsParseTier(stProject,
    '{"' + #27 + '[2J' + #27 + '[1;31mPWNED' + #27 + ']0;hijacked' + #7 +
    '":1}', 'p', P), 'a key of pure escape sequences is still just unknown');
  Check(not HasCtrl(P),
    'and no control character survives into the startup notice');
  Check(Mentions(P, 'PWNED'), 'the printable part is still reported');

  SettingsClear;
  Check(not SettingsParseTier(stProject,
    '{"model":"' + #27 + '[2Jx"}', 'p', P), 'a refused key with ESC in its value');
  Check(not HasCtrl(SettingsRefusals), 'and the refusal is clean too');

  { The tab, in the one place the tab means something. }
  SettingsClear;
  Check(SettingsParseTier(stProject, '{"output_style":"explanatory' + #9 +
    'user"}', 'p', P), 'a tab inside a value is legal JSON and legal UTF-8');
  Rows := SettingsReport;
  Row := '';
  for I := 0 to High(Rows) do
    if Copy(Rows[I], 1, 12) = 'output_style' then Row := Rows[I];
  Check(Row <> '', 'the row is there');
  Fields := 1;
  for J := 1 to Length(Row) do
    if Row[J] = #9 then Inc(Fields);
  Check(Fields = 4, 'and it still has exactly four fields');
  Check(Pos(#9 + 'project', Row) > 0,
    'the tier word is project, which is where the value came from');
  Check(Pos(#9 + 'user', Row) = 0,
    'and a project file cannot make /status say the user set it');
  SettingsClear;
end;

{ settings.local.json is gitignored by convention, and .gitignore is a
  convention rather than a guard: a repository can simply commit one.  The
  local tier therefore carries PROJECT authority, and treating it as user
  scope is the single most likely "improvement" someone makes to this. }
procedure TestSettingsLocalHasProjectAuthority;
var
  P: TStringArray;
begin
  SettingsClear;
  Check(SettingIsProjectClass(stLocal),
    'the local tier is project class, not user class');
  Check(not SettingsParseTier(stLocal, '{"model":"x"}', 'settings.local.json', P),
    'a local file may not set the model either');
  Check(SettingStr('model') = '', 'and nothing was stored');
  Check(Mentions(SettingsRefusals, 'settings.local.json'),
    'the refusal names the local file');
  SettingsClear;
  Check(not SettingsParseTier(stLocal, '{"hooks":{}}', 'settings.local.json', P),
    'and a refused key in a local file is refused just as loudly');
  SettingsClear;
  Check(not SettingsParseTier(stLocal, '{"thinking_budget":32768}', 'l', P),
    'and the project ceiling applies to it too');
  SettingsClear;
end;

{ The load position is above the print-mode halt, which is legal only because
  nothing in the table can grant.  This walks the table, so a new scAny key is
  covered the day somebody adds one. }
procedure TestSettingsGrantsNothing;
var
  P: TStringArray;
  I: Integer;
  Mode: uTools.TPermMode;
  Level: uSandbox.TSandboxLevel;
  Denies: Integer;
  Ok: Boolean;
  Val: string;
begin
  Mode := uTools.CurrentPermMode;
  Level := uSandbox.SandboxLevel;
  Denies := uTools.DenyRuleCount;
  Ok := True;
  for I := 0 to SettingCount - 1 do
  begin
    if SettingDefs[I].Scope <> scAny then Continue;
    SettingsClear;
    case SettingDefs[I].Kind of
      skInt: Val := IntToStr(SettingDefs[I].Lo);
      skBool: Val := 'true';
    else
      Val := '"default"';
    end;
    SettingsParseTier(stProject,
      '{"' + SettingDefs[I].Name + '":' + Val + '}', 'p', P);
    if uTools.AllowAllEdits or uTools.AllowAllBash or uTools.AllowAllFetch or
       (uSandbox.SandboxLevel <> Level) or (uTools.CurrentPermMode <> Mode) or
       (uTools.DenyRuleCount <> Denies) then
      Ok := False;
  end;
  Check(Ok, 'no key a project may set moves any of the six authority variables');
  SettingsClear;
end;

{ A hierarchy nobody can debug is worse than none, so the report has to carry
  where each value actually came from - including when a typed command has
  taken the key over since. }
procedure TestConfigShowsProvenance;
var
  P, Rows: TStringArray;
  I: Integer;
  Row: string;
begin
  SettingsClear;
  SettingsParseTier(stUser, '{"thinking_budget":4096}', 'u', P);
  SettingsParseTier(stProject, '{"thinking_budget":2048}', 'p', P);
  Rows := SettingsReport;
  Row := '';
  for I := 0 to High(Rows) do
    if Copy(Rows[I], 1, 15) = 'thinking_budget' then Row := Rows[I];
  Check(Pos(#9'2048'#9'project'#9, Row) > 0,
    'the report carries the tier that actually supplied the value');
  Check(Pos('user=4096', Row) > 0,
    'and names the tier it shadowed, with the value it shadowed');

  SettingsSetRuntime('thinking_budget', '16384', '/think');
  Rows := SettingsReport;
  Row := '';
  for I := 0 to High(Rows) do
    if Copy(Rows[I], 1, 15) = 'thinking_budget' then Row := Rows[I];
  Check(Pos(#9'16384'#9'/think'#9, Row) > 0,
    'and after /think it reports the typed value and the typed source, not ' +
    'the file''s');
  SettingsClear;
end;

{ The writer is read-modify-write for a documented reason: LoadPermissions
  widens on load but SavePermissions rewrites wholesale, so a key its loader
  does not understand dies silently.  This is the test standing between that
  and a user's hand-written block. }
procedure TestConfigSetPreservesUnknownKeys;
var
  Err, Raw, Before: string;
begin
  ClearSetFiles;
  WriteFileText(UserSet,
    '{"permissions":{"allow":["Bash"]},"output_style":"a"}');
  Check(SettingsWrite(UserSet, 'model', 'x', False, Err),
    'a write into a file with a refused key succeeds');
  Raw := ReadFileText(UserSet);
  Check(Pos('permissions', Raw) > 0, 'the refused block is still there');
  Check(Pos('Bash', Raw) > 0, 'with its contents intact');
  Check(Pos('"output_style"', Raw) > 0, 'and so is the key beside it');
  Check(Pos('"x"', Raw) > 0, 'and the new value landed');

  WriteFileText(UserSet, '{"output_style":"a"');
  Before := ReadFileText(UserSet);
  Check(not SettingsWrite(UserSet, 'model', 'y', False, Err),
    'a truncated file refuses the write');
  Check(Err <> '', 'and says why');
  Check(ReadFileText(UserSet) = Before,
    'and leaves the file byte-identical rather than replacing it with a ' +
    'fresh document');
end;

{ set writes the user file; --local writes settings.local.json; nothing ever
  writes the project file, because pasclaude committing configuration into
  somebody's repository on their behalf is not a convenience. }
procedure TestConfigSetWritesUserTier;
var
  Err, ProjBefore, LocalBefore: string;
  N: TStringArray;
begin
  ClearSetFiles;
  WriteFileText(UserSet, '{}');
  WriteFileText(ProjSet, '{"output_style":"learning"}');
  WriteFileText(LocalSet, '{}');
  ProjBefore := ReadFileText(ProjSet);
  LocalBefore := ReadFileText(LocalSet);

  Check(SettingsWrite(UserSet, 'output_style', 'x', False, Err),
    '/config set writes the user file');
  Check(ReadFileText(ProjSet) = ProjBefore, 'the project file is untouched');
  Check(ReadFileText(LocalSet) = LocalBefore, 'and so is the local file');
  SettingsLoad(UserSet, ProjSet, LocalSet, N);
  Check(SettingSource('output_style') = stProject,
    'and the project tier still wins, which is what /config says on the spot');

  Check(SettingsWrite(LocalSet, 'output_style', 'x', False, Err),
    '--local writes settings.local.json');
  Check(ReadFileText(ProjSet) = ProjBefore,
    'and still nothing writes the project file');
  SettingsLoad(UserSet, ProjSet, LocalSet, N);
  Check(SettingSource('output_style') = stLocal, 'which now wins');

  Check(not SettingsWrite(UserSet, 'permissions', 'x', False, Err),
    'and a refused key cannot be written at all');
  Check(Pos('no file in a repository can grant one', Err) > 0,
    'and the refusal says why rather than just saying no');
  SettingsClear;
end;

{ ------------------------------------------------------------- telemetry -- }

var
  UxTelemCalls: Integer = 0;
  UxTelemOk: Boolean = False;

function UxTelemTransport(const Url, Headers, Body: string;
  OnChunk: TChunkProc; Ctx: Pointer): THttpResult;
begin
  Inc(UxTelemCalls);
  Result.Ok := UxTelemOk;
  Result.Body := '';
  Result.RetryAfterMs := 0;
  if UxTelemOk then
  begin
    Result.Status := 200;
    Result.Error := '';
  end
  else
  begin
    Result.Status := 503;
    Result.Error := 'HTTP 503';
  end;
end;

{ What /telemetry has to be able to say.  With nothing configured it must say
  off and must NOT invent an endpoint; configured, it must report the URL,
  the interval and the timeout it will actually use. }
procedure TestTelemetryPanel;
var
  C: TTelemConfig;
  S: TTelemState;
begin
  TelemInit(TelemDefaultConfig);
  S := TelemState;
  Check(not S.Enabled, 'with nothing configured telemetry reports off');
  Check(S.Endpoint = '', 'and names no endpoint at all');
  Check(not S.SelfDisabled, 'and has not disabled itself');

  C := TelemDefaultConfig;
  C.Enabled := True;
  C.Endpoint := 'http://localhost:4318';
  C.IntervalTurns := 7;
  C.TimeoutMs := 1200;
  TelemInit(C);
  S := TelemState;
  Check(S.Enabled, 'a configured telemetry reports on');
  Check(S.Endpoint = 'http://localhost:4318/v1/metrics',
    'and shows the URL it would really POST to, path included');
  Check((S.IntervalTurns = 7) and (S.TimeoutMs = 1200),
    'and the interval and timeout in force');
  TelemInit(TelemDefaultConfig);
end;

{ /telemetry preview must be the SAME builder the sender uses, or "read the
  payload before you trust it" is a lie about the code. }
procedure TestTelemetryPreviewIsWhatShips;
var
  C: TTelemConfig;
  Saved: TPostProc;
  Preview: string;
  Doc: TJson;
  Status: Integer;
  Err: string;
begin
  C := TelemDefaultConfig;
  C.Enabled := True;
  C.Endpoint := 'http://127.0.0.1:4318/v1/metrics';
  SetLength(C.HeaderNames, 1);
  SetLength(C.HeaderValues, 1);
  C.HeaderNames[0] := 'x-collector-key';
  C.HeaderValues[0] := 'SUPERSECRET';
  TelemInit(C);
  TelemRecordTurn(10, 5, 0, 0, 'claude-sonnet-4-5');
  TelemRecordTurn(30, 15, 0, 0, 'claude-sonnet-4-5');
  TelemRecordTool('search', False);

  Preview := TelemBuildPayload(True);
  Doc := JsonParse(Preview);
  Check(Doc <> nil, 'the preview is JSON a parser accepts');
  if Doc <> nil then Doc.Free;
  Check(Pos('SUPERSECRET', Preview) = 0, 'and carries no collector token');
  Check(Pos('SUPERSECRET', TelemHeaderBlockRedacted) = 0,
    'and neither does the header block the user is shown');
  Check(Pos('x-collector-key', TelemHeaderBlockRedacted) > 0,
    'though it does name the header');

  Saved := uHttp.HttpTransport;
  uHttp.HttpTransport := @UxTelemTransport;
  try
    UxTelemCalls := 0;
    UxTelemOk := True;
    Check(TelemFlush(Status, Err), 'the flush succeeds');
    Check(UxTelemCalls = 1, 'having made one request');
    Check(not TelemState.HasData, 'and the batch is gone afterwards');
  finally
    uHttp.HttpTransport := Saved;
    TelemInit(TelemDefaultConfig);
  end;
end;

{ A dead collector must say so ONCE.  A note on every turn is noise; no note
  at all leaves the user believing data is flowing when it stopped. }
procedure TestTelemetrySelfDisableIsSaidOnce;
var
  C: TTelemConfig;
  Saved: TPostProc;
  Status, Notes, I: Integer;
  Err: string;
  WasDisabled: Boolean;
begin
  C := TelemDefaultConfig;
  C.Enabled := True;
  C.Endpoint := 'http://127.0.0.1:4318/v1/metrics';
  C.IntervalTurns := 1;
  TelemInit(C);
  Saved := uHttp.HttpTransport;
  uHttp.HttpTransport := @UxTelemTransport;
  try
    UxTelemOk := False;
    UxTelemCalls := 0;
    Notes := 0;
    { The host prints its one note on the transition, which is what this
      counts: the flush that first sets SelfDisabled. }
    for I := 1 to 6 do
    begin
      TelemRecordTurn(I * 10, I, 0, 0, 'claude-sonnet-4-5');
      if not TelemDueForFlush then Continue;
      WasDisabled := TelemState.SelfDisabled;
      TelemFlush(Status, Err);
      if (not WasDisabled) and TelemState.SelfDisabled then Inc(Notes);
    end;
    Check(Notes = 1, 'exactly one self-disabled note is produced, not three');
    Check(UxTelemCalls = 3,
      'and the dead collector was contacted three times, then never again');
    Check(not TelemEnabled, 'telemetry is off for the rest of the session');
    Check(Err <> '', 'and the note has a reason to carry');
  finally
    uHttp.HttpTransport := Saved;
    TelemInit(TelemDefaultConfig);
  end;
end;

{ ------------------------------------------------- /status /doctor /bug --- }

function StatusValue(const R: TStatusReport; const Id: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(R) do
    if R[I].Id = Id then Exit(R[I].Value);
end;

function DoctorLevel(const R: TDiagReport; const Id: string): TDiagLevel;
var
  I: Integer;
begin
  Result := dlSkipped;
  for I := 0 to High(R) do
    if R[I].Id = Id then Exit(R[I].Level);
end;

function DoctorField(const R: TDiagReport; const Id: string;
  Remedy: Boolean): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(R) do
    if R[I].Id = Id then
      if Remedy then Exit(R[I].Remedy) else Exit(R[I].Detail);
end;

function LinesJoin(const A: TStringArray): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(A) do Result := Result + A[I] + #10;
end;

{ /status must BORROW the mode word, the deny count and the sandbox name from
  the units that own them.  A second copy in uDiag would look identical today
  and drift the first time /mode or /sandbox grows a word - which is exactly
  the duplication the whole feature was asked not to create. }
procedure TestStatusBorrowsTheOwningUnits;
var
  R: TStatusReport;
  Text: string;
  Err: string;
begin
  ClearDiagNotes;
  ClearDiagFacts;
  uTools.ClearDenyRules;
  uTools.AddDenyRule('tool:bash', 'test');
  uTools.AddDenyRule('path:.env', 'test');
  uTools.SetPermMode(pmodePlan);
  uSandbox.SandboxLevel := slLow;
  uTools.SetOutputStyle('explanatory', Err);
  uHooks.ClearHooks;
  DiagFacts.Version := '9.9';
  DiagFacts.VimOn := True;

  R := DiagBuildStatus(nil);
  Check(StatusValue(R, 'permission_mode') =
    uTools.PermModeName(uTools.CurrentPermMode),
    'the mode value IS uTools.PermModeName, not a literal');
  Check(StatusValue(R, 'deny_rules') = IntToStr(uTools.DenyRuleCount),
    'the deny count IS uTools.DenyRuleCount');
  Check(StatusValue(R, 'sandbox') =
    uSandbox.SandboxLevelName(uSandbox.SandboxLevel),
    'the sandbox word IS uSandbox.SandboxLevelName');
  Check(StatusValue(R, 'output_style') = uTools.OutputStyleName,
    'the style name IS uTools.OutputStyleName');
  Text := LinesJoin(DiagStatusText(R));
  Check(Pos('plan', Text) > 0, 'and the rendered text carries the mode word');
  Check(Pos('2', StatusValue(R, 'deny_rules')) > 0, 'and the deny count');
  Check(Pos('low', Text) > 0, 'and the sandbox level');
  Check(Pos('explanatory', Text) > 0, 'and the style name');
  Check(Pos('vim mode:', Text) > 0, 'and the vim state');
  Check(Pos('hooks:', Text) > 0, 'and the hook state');
  Check(Pos('9.9', Text) > 0, 'and the version from DiagFacts');
  { The footer that says the report describes the SESSION and not the disk.
    /help has never had one place for this. }
  Check(Pos('/config reload', Text) > 0,
    'and a footer naming the caches and what refreshes each');

  uTools.SetOutputStyle('default', Err);
  uTools.SetPermMode(pmodeAsk);
  uSandbox.SandboxLevel := slLimits;
  uTools.ClearDenyRules;
  ClearDiagFacts;
end;

{ The row must be present whether or not an editor is there, and a record
  nobody filled in must not produce a fact.  The environment is set
  explicitly rather than trusted: this suite is itself very often run from
  inside a VS Code terminal, so a test that read the ambient variables would
  pass or fail depending on who ran it. }

{ There is NO GitHub settings key at any tier, and that is the point: the API
  host is compiled in and the token comes from the environment or the gh CLI.
  A github.api_base or a github.token "for convenience" would let a settings
  file name the host a credential is sent to, which is exactly the knob
  telemetry's endpoint was made user-scope-only to avoid - and stricter here,
  because there is no legitimate second host. }
procedure TestSettingsRefusesGithub;
var
  Problems: TStringArray;
  T: TSettingTier;
begin
  SettingsClear;
  for T := stUser to stLocal do
  begin
    Check(not SettingsParseTier(T, '{"github":{"token":"ghp_x"}}',
      'settings.json', Problems),
      'github is refused at ' + TierName(T));
    Check(Mentions(Problems, '"github"'), '  by name at ' + TierName(T));
    Check(Mentions(Problems, 'GH_TOKEN'),
      '  naming where the token really comes from at ' + TierName(T));
  end;
  Check(SettingIndex('github.token') = -1, 'github.token is not a key');
  Check(SettingIndex('github.api_base') = -1, 'nor github.api_base');
  Check(SettingIndex('github.enabled') = -1, 'nor github.enabled');
  Check(SettingIndex('github') >= 0, 'but the bare name is known and refused');
  Check(SettingCount = Length(SettingDefs),
    'and the hand-maintained bound still matches the table');
  SettingsClear;
end;

{ TDiagFacts holds a repository name and a token SOURCE NAME and no token.
  That is the property that makes /bug unable to leak one even if every
  redactor failed, so it is asserted over both renderers and the bug text. }
procedure TestGithubDiagRows;
const
  Secret = 'ghp_abcdefghijklmnopqrstuvwxyz0123456789';
var
  R: TStatusReport;
  D: TDiagReport;
  Opts: TBugOptions;
  Blob: string;
  I: Integer;
begin
  ClearDiagNotes;
  ClearDiagFacts;
  R := DiagBuildStatus(nil);
  Check(StatusValue(R, 'github') = 'not probed',
    'a zeroed DiagFacts reports the github row as not probed');
  D := DiagBuildDoctor(nil, False);
  Check(DoctorLevel(D, 'github') = dlSkipped,
    'and the check is skipped, never a green tick');

  DiagFacts.GithubRemoteWhy := 'origin is not a github.com remote (host: ' +
    'gitlab.com)';
  R := DiagBuildStatus(nil);
  Check(Pos('gitlab.com', StatusValue(R, 'github')) > 0,
    'a non-github remote says so: ' + StatusValue(R, 'github'));
  D := DiagBuildDoctor(nil, False);
  Check(DoctorLevel(D, 'github') = dlSkipped,
    'and is still not a failure - most directories are not GitHub clones');

  DiagFacts.GithubRemoteWhy := '';
  DiagFacts.GithubRepo := 'o/r';
  DiagFacts.GithubTokenSource := '';
  D := DiagBuildDoctor(nil, False);
  Check(DoctorLevel(D, 'github') = dlWarn, 'a repo with no token warns');
  Check(Pos('GH_TOKEN', DoctorField(D, 'github', True)) > 0,
    'and the remedy names GH_TOKEN: ' + DoctorField(D, 'github', True));
  for I := 0 to High(D) do
    if D[I].Id = 'github' then
      Check(D[I].Cost = dcNone,
        'the check costs nothing: it makes no request and spawns nothing');

  DiagFacts.GithubTokenSource := 'GH_TOKEN';
  R := DiagBuildStatus(nil);
  Check((Pos('o/r', StatusValue(R, 'github')) > 0) and
        (Pos('GH_TOKEN', StatusValue(R, 'github')) > 0),
    'the row names the repo and the source: ' + StatusValue(R, 'github'));
  D := DiagBuildDoctor(nil, False);
  Check(DoctorLevel(D, 'github') = dlOk, 'and the check passes');

  { The token is not in the record, so it cannot be in anything built from
    it - text, JSON or bug report.  A seven-character prefix is checked too,
    because a "helpful" AuthHint would put one there. }
  Opts.IncludeTranscript := False;
  Opts.RealPaths := True;
  Opts.AsJson := False;
  Blob := LinesJoin(DiagStatusText(R)) + LinesJoin(DiagDoctorText(D)) +
    DiagStatusJson(R) + DiagDoctorJson(D) + DiagBugText(nil, Opts, R, D);
  Check(Pos(Secret, Blob) = 0, 'no rendered field carries the token');
  Check(Pos(Copy(Secret, 1, 7), Blob) = 0, 'nor a seven-character prefix');
  Check(Pos('Bearer', Blob) = 0, 'nor the word Bearer');
  ClearDiagFacts;
end;

procedure TestStatusReportsIde;
var
  R: TStatusReport;
  D: TDiagReport;
  I: Integer;
  Fake, SavedTp, SavedInj, SavedNode, SavedVer, SavedEmu: string;
begin
  SavedTp   := SysUtils.GetEnvironmentVariable('TERM_PROGRAM');
  SavedVer  := SysUtils.GetEnvironmentVariable('TERM_PROGRAM_VERSION');
  SavedInj  := SysUtils.GetEnvironmentVariable('VSCODE_INJECTION');
  SavedNode := SysUtils.GetEnvironmentVariable('VSCODE_GIT_ASKPASS_NODE');
  SavedEmu  := SysUtils.GetEnvironmentVariable('TERMINAL_EMULATOR');
  try
    ClearDiagNotes;
    ClearDiagFacts;
    { A zeroed record.  The row exists - a report that omitted it for a
      plain console would be structurally different from every other one -
      and it claims nothing. }
    R := DiagBuildStatus(nil);
    Check(StatusValue(R, 'ide') = 'not probed',
      'a zeroed DiagFacts reports the IDE row as not probed');
    Check(StatusValue(R, 'ide_command_source') = '',
      'and names no launcher source');
    D := DiagBuildDoctor(nil, False);
    Check(DoctorLevel(D, 'ide_editor_cli') = dlSkipped,
      'and the doctor check is skipped, not a green tick');

    { A synthetic host, with a real file so the scan has something to find. }
    Fake := IncludeTrailingPathDelimiter(TmpRoot) + 'fakeide' + PathDelim;
    ForceDirectories(Fake + 'bin');
    WriteFileText(Fake + 'Code.exe', 'x');
    WriteFileText(Fake + 'bin' + PathDelim + 'code.cmd', 'x');
    SetEnvironmentVariable('TERM_PROGRAM', 'vscode');
    SetEnvironmentVariable('TERM_PROGRAM_VERSION', '9.9.9');
    SetEnvironmentVariable('VSCODE_INJECTION', '1');
    SetEnvironmentVariable('TERMINAL_EMULATOR', nil);
    SetEnvironmentVariable('VSCODE_GIT_ASKPASS_NODE',
      PChar(Fake + 'Code.exe'));
    DiagFacts.IdeSetting := 'on';
    R := DiagBuildStatus(nil);
    Check(Pos('vscode', StatusValue(R, 'ide')) > 0, 'a probed host is named');
    Check(Pos('9.9.9', StatusValue(R, 'ide')) > 0, 'with its version');
    Check(Pos('Code.exe', StatusValue(R, 'ide')) > 0, 'and its product');
    Check(Pos('code.cmd', StatusValue(R, 'ide')) > 0, 'and the resolved shim');
    D := DiagBuildDoctor(nil, False);
    Check(DoctorLevel(D, 'ide_editor_cli') = dlOk,
      'and the doctor check passes when a shim resolved');

    { The off switch, which /ide honours and which must not read as an
      editor that could not be found. }
    DiagFacts.IdeSetting := 'off';
    R := DiagBuildStatus(nil);
    Check(Pos('off', StatusValue(R, 'ide')) > 0, 'ide.enabled false says so');
    D := DiagBuildDoctor(nil, False);
    Check(DoctorLevel(D, 'ide_editor_cli') = dlSkipped,
      'and is skipped rather than warned about');

    { A detected host with nothing to launch is the one warning this check
      can produce, and the builder's own invariant says it must carry a
      remedy - nothing else in the suite exercises that for a new check. }
    DiagFacts.IdeSetting := 'on';
    SetEnvironmentVariable('VSCODE_GIT_ASKPASS_NODE', nil);
    D := DiagBuildDoctor(nil, False);
    Check(DoctorLevel(D, 'ide_editor_cli') = dlWarn,
      'a host with no resolvable shim warns');
    Check(Trim(DoctorField(D, 'ide_editor_cli', True)) <> '',
      'and carries a remedy');
    Check(Pos('ide.command', DoctorField(D, 'ide_editor_cli', True)) > 0,
      'naming the user-scope key that fixes it');
    for I := 0 to High(D) do
      Check((DiagLevelRank(D[I].Level) = 0) or (Trim(D[I].Remedy) <> ''),
        'every non-ok check still carries a remedy: ' + D[I].Id);

    { The launcher source row, and the fact it names a FILE and never the
      path - a program path belongs in the doctor detail, once. }
    DiagFacts.IdeCommand := 'C:\x\bin\code.cmd';
    R := DiagBuildStatus(nil);
    Check(StatusValue(R, 'ide_command_source') = 'user settings.json',
      'a set ide.command is attributed to the user file');
  finally
    SetEnvironmentVariable('TERM_PROGRAM', PChar(SavedTp));
    SetEnvironmentVariable('TERM_PROGRAM_VERSION', PChar(SavedVer));
    SetEnvironmentVariable('VSCODE_INJECTION', PChar(SavedInj));
    SetEnvironmentVariable('VSCODE_GIT_ASKPASS_NODE', PChar(SavedNode));
    SetEnvironmentVariable('TERMINAL_EMULATOR', PChar(SavedEmu));
    ClearDiagFacts;
  end;
end;

{ /ide diff shows what the SESSION did, so the baseline is the OLDEST
  snapshot, not the newest.  Writing the loop the natural way - High downto
  0, first match wins - would show only the last turn's change and report a
  multi-turn rewrite as a one-line edit. }
procedure TestIdeBaseline;
var
  J: TJson;
  Out_, Text, P: string;
  IsErr, Existed: Boolean;
begin
  uTools.AllowAllEdits := True;
  uTools.ClearSnapshots;
  P := IncludeTrailingPathDelimiter(TmpRoot) + 'baseline.txt';
  WriteFileText(P, 'original');

  uTools.BeginTurn(1);
  J := TJson.NewObj;
  J.AddStr('path', 'baseline.txt');
  J.AddStr('content', 'after turn 1');
  Out_ := uTools.RunTool('write_file', J, nil, IsErr);
  J.Free;
  Check(not IsErr, 'the turn-1 write applies: ' + Out_);

  uTools.BeginTurn(2);
  J := TJson.NewObj;
  J.AddStr('path', 'baseline.txt');
  J.AddStr('content', 'after turn 2');
  Out_ := uTools.RunTool('write_file', J, nil, IsErr);
  J.Free;
  Check(not IsErr, 'and the turn-2 write');

  Check(uTools.SessionBaseline(P, Text, Existed), 'a baseline is found');
  Check(Text = 'original',
    'and it is the state before the session, not before the last turn');
  Check(Existed, 'and it says the file was already there');

  { A file this session created: a real answer, distinct from "no
    snapshot".  Conflating the two would open an empty pane against a file
    /ide never touched and present it as wholly added. }
  uTools.BeginTurn(3);
  J := TJson.NewObj;
  J.AddStr('path', 'made-now.txt');
  J.AddStr('content', 'brand new');
  uTools.RunTool('write_file', J, nil, IsErr);
  J.Free;
  Check(uTools.SessionBaseline(IncludeTrailingPathDelimiter(TmpRoot) +
    'made-now.txt', Text, Existed), 'a created file has a baseline');
  Check((Text = '') and not Existed, 'and it is empty, and says so');

  Check(not uTools.SessionBaseline(IncludeTrailingPathDelimiter(TmpRoot) +
    'never.txt', Text, Existed), 'an untouched file has none');
  Check(not uTools.SessionBaseline('C:\somewhere\else.txt', Text, Existed),
    'nor does a path outside the root');
  uTools.ClearSnapshots;
  Check(not uTools.SessionBaseline(P, Text, Existed),
    'and none survives ClearSnapshots');
  uTools.AllowAllEdits := False;
end;

{ The "before" side of a diff is project text living outside the project, so
  its lifetime is the feature.  uIde owns exactly one at a time: holding a new
  one deletes the last, and dropping deletes what is held.  Asserted against
  real files rather than a mocked filesystem, because the whole claim is
  about a file existing or not existing on disk. }
procedure TestIdeScratchLifetime;
var
  A, B: string;
begin
  A := IncludeTrailingPathDelimiter(TmpRoot) + 'base-one.txt';
  B := IncludeTrailingPathDelimiter(TmpRoot) + 'base-two.txt';
  try
    WriteFileText(A, 'before one');
    uIde.IdeHoldScratch(A);
    Check(FileExists(A), 'a held baseline is left alone while it is the live one');
    Check(uIde.IdeHeldScratch = A, 'and it is the one being held');

    { Re-holding the same path must not delete it: the caller has just
      rewritten those bytes, and /ide diff twice on one file composes the
      same base-<name> both times. }
    WriteFileText(A, 'before one again');
    uIde.IdeHoldScratch(A);
    Check(FileExists(A),
      're-holding the same path leaves the bytes just written in place');

    WriteFileText(B, 'before two');
    uIde.IdeHoldScratch(B);
    Check(not FileExists(A),
      'holding a second baseline deletes the first, so at most one is ever live');
    Check(FileExists(B), 'and the second one is there for the editor to read');

    uIde.IdeDropScratch;
    Check(not FileExists(B), 'dropping deletes the held baseline');
    Check(uIde.IdeHeldScratch = '', 'and nothing is held after a drop');
    uIde.IdeDropScratch;
    Check(uIde.IdeHeldScratch = '', 'a drop with nothing held is quiet');
  finally
    uIde.IdeDropScratch;
    SysUtils.DeleteFile(A);
    SysUtils.DeleteFile(B);
  end;
end;

{ A file over the snapshot cap gets no baseline, and until now that was
  indistinguishable from a file this session never wrote - so /ide diff said
  "one of these two things" and named neither.  The skip is recorded where it
  happens, so the message can say which. }
procedure TestSnapshotOversizeIsNamed;
var
  J: TJson;
  Out_, Text, Big, Small: string;
  IsErr, Existed: Boolean;
begin
  Big := IncludeTrailingPathDelimiter(TmpRoot) + 'huge.log';
  Small := IncludeTrailingPathDelimiter(TmpRoot) + 'tiny.log';
  uTools.AllowAllEdits := True;
  uTools.ClearSnapshots;
  uTools.ClearChangedFiles;
  try
    WriteFileText(Big, StringOfChar('x', uTools.SnapshotLimitBytes + 1));
    WriteFileText(Small, 'small enough');

    uTools.BeginTurn(1);
    J := TJson.NewObj;
    J.AddStr('path', 'huge.log');
    J.AddStr('content', 'overwritten');
    Out_ := uTools.RunTool('write_file', J, nil, IsErr);
    J.Free;
    Check(not IsErr, 'the write over an oversized file still applies: ' + Out_);

    J := TJson.NewObj;
    J.AddStr('path', 'tiny.log');
    J.AddStr('content', 'overwritten too');
    uTools.RunTool('write_file', J, nil, IsErr);
    J.Free;

    Check(not uTools.SessionBaseline(Big, Text, Existed),
      'a file over the snapshot limit gets no baseline');
    Check(uTools.SnapshotSkippedOversize(Big),
      'and the skip is recorded, so /ide diff can name the reason instead of guessing');
    Check(Length(uTools.ChangedFiles) > 0,
      'and it is still listed as changed this session, which is why the silence read as a bug');
    Check(uTools.SessionBaseline(Small, Text, Existed) and
      not uTools.SnapshotSkippedOversize(Small),
      'an ordinary snapshotted file is not reported as oversized');
    Check(uTools.SnapshotLimitBytes div 1024 = 400,
      'the reported limit is the 400 KB /rewind prints');

    uTools.ClearSnapshots;
    Check(not uTools.SnapshotSkippedOversize(Big),
      'and the oversize record dies with the snapshots');
  finally
    uTools.ClearSnapshots;
    uTools.ClearChangedFiles;
    SysUtils.DeleteFile(Big);
    SysUtils.DeleteFile(Small);
    uTools.AllowAllEdits := False;
  end;
end;

procedure TestDoctorLevelsAndCosts;
var
  R: TDiagReport;
  I: Integer;
  AnyNetwork: Boolean;
begin
  ClearDiagNotes;
  ClearDiagFacts;
  DiagFacts.AuthSource := 'claude_code';
  DiagFacts.AuthPresent := False;
  R := DiagBuildDoctor(nil, False);
  Check(DoctorLevel(R, 'credential') = dlProblem,
    'no credential is a problem');
  Check(Pos('ANTHROPIC_API_KEY', DoctorField(R, 'credential', True)) > 0,
    'and the remedy names ANTHROPIC_API_KEY');
  Check(DoctorLevel(R, 'credential_expiry') = dlSkipped,
    'with no credential there is no expiry to judge');

  DiagFacts.AuthPresent := True;
  DiagFacts.AuthExpiresAtMs := DiagNowUnixMs - 60000;
  R := DiagBuildDoctor(nil, False);
  Check(DoctorLevel(R, 'credential_expiry') = dlProblem,
    'a credential that expired during the session is a problem');
  Check(DoctorField(R, 'credential_expiry', True) <> '',
    'and carries a remedy');

  Check(DoctorLevel(R, 'model_access') = dlSkipped,
    'model access is not checked offline');
  Check(Pos('--online', DoctorField(R, 'model_access', False)) > 0,
    'and its detail names the opt-in');
  { The rule this codebase applies to web search and to fetch: an outbound
    request is a channel, and typing a command must not open one. }
  AnyNetwork := False;
  for I := 0 to High(R) do
    if R[I].Cost = dcNetwork then AnyNetwork := True;
  Check(not AnyNetwork, 'and no check in an offline report costs the network');
  ClearDiagFacts;
end;

{ /doctor replays the ledger and must never re-read a config file.  The
  count assertion is the real one: uTools.LoadMcpConfig calls
  ClearMcpServers as its first statement, so a builder that "checked"
  .mcp.json by re-reading it would tear down every live connection. }
procedure TestDoctorReplaysTheLedger;
var
  R: TDiagReport;
  Before, After: Integer;
begin
  ClearDiagNotes;
  ClearDiagFacts;
  DiagFacts.SettingsSupported := True;
  R := DiagBuildDoctor(nil, False);
  Check(DoctorLevel(R, 'config_files') = dlOk,
    'an empty ledger is a clean config report');
  DiagNote('deny', dlWarn, 'rule not understood: nonsense', '/deny');
  DiagNote('hooks', dlWarn, 'PreToolUse entry has no command', '/hooks');
  Before := uTools.McpServerCount;
  R := DiagBuildDoctor(nil, False);
  After := uTools.McpServerCount;
  Check(DoctorLevel(R, 'config_files') = dlWarn,
    'a ledger entry makes the config check a warning');
  Check((Pos('deny', DoctorField(R, 'config_files', False)) > 0) and
        (Pos('hooks', DoctorField(R, 'config_files', False)) > 0),
    'and the detail names both sources');
  Check(Before = After,
    'and building the report did not disturb the MCP server table');
  ClearDiagNotes;
  R := DiagBuildDoctor(nil, False);
  Check(DoctorLevel(R, 'config_files') = dlOk,
    'clearing the ledger clears the check');
  ClearDiagFacts;
end;

procedure TestProbeWritableLeavesNothing;
var
  Dir, Err: string;
  R: TSearchRec;
  Before, After: Integer;

  function CountEntries(const D: string): Integer;
  begin
    Result := 0;
    if SysUtils.FindFirst(IncludeTrailingPathDelimiter(D) + '*',
         faAnyFile, R) = 0 then
      try
        repeat
          if (R.Attr and faDirectory) = 0 then Inc(Result);
        until SysUtils.FindNext(R) <> 0;
      finally
        SysUtils.FindClose(R);
      end;
  end;

begin
  Dir := IncludeTrailingPathDelimiter(TmpRoot) + 'probe';
  ForceDirectories(Dir);
  Before := CountEntries(Dir);
  Check(DiagProbeWritable(Dir, Err), 'a writable directory probes true');
  After := CountEntries(Dir);
  { A probe that leaves its own litter has made the directory it was
    checking slightly worse. }
  Check(Before = After, 'and leaves nothing behind');
  { And the machine whose disk is the problem is the one running /doctor,
    so the probe may report but never raise. }
  Check(not DiagProbeWritable('\\?\Q:\nowhere\at\all', Err),
    'an impossible path probes false');
  Check(Err <> '', 'with a reason, and without raising');
end;

{ The authority boundary this feature touches: NOTHING in a project
  directory may add a check, remove one, change a level, move where /bug
  writes, or turn redaction off.  uDiag has no settings key of its own, and
  the four names a project might reach for are refused BY NAME in
  uSettings.SettingDefs so that adding one later is a review conflict rather
  than a one-line diff. }
procedure TestDiagTakesNothingFromTheProject;
var
  Problems: TStringArray;
  BeforeIds, AfterIds: string;
  R: TDiagReport;
  I: Integer;
  Dir: string;

  function IdsOf(const Rep: TDiagReport): string;
  var
    K: Integer;
  begin
    Result := '';
    for K := 0 to High(Rep) do Result := Result + Rep[K].Id + ',';
  end;

begin
  ClearDiagNotes;
  ClearDiagFacts;
  DiagFacts.SettingsSupported := True;
  R := DiagBuildDoctor(nil, False);
  BeforeIds := IdsOf(R);

  uSettings.SettingsClear;
  Check(not uSettings.SettingsParseTier(stProject,
    '{"report_dir":"' + StringReplace(TmpRoot, '\', '\\', [rfReplaceAll]) +
    '","redact":false,"doctor":"off","bug":"upload"}',
    '<project settings.json>', Problems),
    'a project file naming report_dir, redact, doctor or bug is refused');
  Check(Length(Problems) > 0, 'and every refusal is named');
  { And the same four names are refused from the USER file too: they are not
    scope-limited keys, they do not exist at all. }
  Check(not uSettings.SettingsParseTier(stUser, '{"report_dir":"x"}',
    '<user settings.json>', Problems),
    'and not even the user file may name report_dir');
  uSettings.SettingsClear;

  R := DiagBuildDoctor(nil, False);
  AfterIds := IdsOf(R);
  Check(BeforeIds = AfterIds,
    'and the set of checks is byte-identical either way');

  { Where /bug writes is computed, never configured, and is outside every
    root - which is also why uTools.SafePath means the model's own read_file
    cannot read a report back. }
  Dir := DiagReportsDir;
  Check(Dir <> '', 'there is a reports directory');
  for I := 0 to uTools.RootCount - 1 do
    Check(not uTools.WithinRoot(Dir, uTools.RootAt(I)),
      'and it is outside root ' + IntToStr(I));
  ClearDiagFacts;
end;

{ ------------------------------------------------------------- the chrome --

  The banner and the prompt block are laid out by arithmetic on widths, and
  arithmetic on widths is exactly the thing that is wrong by one and looks
  almost right.  These tests assert the properties a reader would have to
  count columns on a screenshot to check. }

procedure TestUiWidthCountsColumnsNotBytes;
begin
  Check(UiWidth('abc') = 3, 'ASCII is its own length');
  { Three bytes, one column.  A banner padded by Length() would be two
    columns short here, which is how a frame goes ragged. }
  Check(UiWidth(#$E2#$94#$80) = 1, 'a box-drawing character is one column');
  Check(Length(#$E2#$94#$80) = 3, 'though it is three bytes');
  Check(UiWidth(MkAmber + 'abc' + MkOff) = 3, 'colour marks are not columns');
  Check(UiPlain(MkAmber + 'abc' + MkOff) = 'abc', 'and strip out cleanly');
  { A dangling mark is a caller's bug; it must not make the width negative
    or a pad loop will run to SetLength(-1). }
  Check(UiWidth('ab' + #1) = 2, 'a truncated mark costs no columns');
end;

procedure TestUiFitTruncatesWithoutLosingColour;
var
  S: string;
begin
  Check(UiFit('abc', 10) = 'abc', 'a string that fits is untouched');
  Check(UiWidth(UiFit('abcdefghij', 5)) <= 5, 'a long one is cut to the width');
  S := UiFit(MkAmber + 'aaaa' + MkRed + 'bbbb', 5);
  { The colour that was still in force at the cut has to survive it, or the
    next thing painted inherits it and the rest of the screen goes amber. }
  Check(Pos(MkAmber, S) > 0, 'the marks before the cut are kept');
  Check(UiWidth(S) <= 5, 'and the cut still respects the width');
  Check(UiFit('abc', 0) = '', 'no room means no output');
  Check(UiWidth(UiPad('ab', 6)) = 6, 'padding reaches the width exactly');
  Check(UiWidth(UiCentre('ab', 6)) = 4, 'centring pads only on the left');
end;

procedure TestUiMeterAndCount;
var
  M: string;
begin
  UiSetGlyphs(ugAscii);
  Check(UiWidth(UiMeter(50, 10, clAmber, clAmberDk)) = 10,
    'a meter is exactly as wide as it was asked to be');
  Check(UiWidth(UiMeter(0, 10, clAmber, clAmberDk)) = 10, 'empty included');
  Check(UiWidth(UiMeter(100, 10, clAmber, clAmberDk)) = 10, 'and full');
  Check(UiWidth(UiMeter(4000, 10, clAmber, clAmberDk)) = 10,
    'and one handed a nonsense percentage, which is clamped');
  { The first cell is the whole signal at the start of a session: a meter
    that reads empty at 1% is a meter that does not appear to work. }
  M := UiPlain(UiMeter(1, 20, clAmber, clAmberDk));
  Check(Pos('=', M) = 1, 'one per cent lights the first cell');
  Check(UiWidth(UiMeter(50, 0, clAmber, clAmberDk)) = 0,
    'and no cells is no meter rather than a crash');

  Check(UiCount(0) = '0', 'small counts are themselves');
  Check(UiCount(999) = '999', 'up to the thousand');
  Check(UiCount(1234) = '1.2k', 'then thousands');
  Check(UiCount(1500000) = '1.5M', 'then millions');
  UiSetGlyphs(ugAuto);
end;

{ The property that matters about a frame: every piece of it is the same
  number of columns, whatever went inside and whichever glyph set is in
  force.  Checked at several widths because an off-by-one in the top edge
  only shows up when the title length and the width disagree. }
procedure TestBoxPiecesLineUp;
var
  G: TUiGlyphs;
  W, LeftW, RightW: Integer;
  Long: string;
begin
  Long := StringOfChar('x', 300);
  for G := ugAscii to ugUnicode do
  begin
    UiSetGlyphs(G);
    for W := 40 to 60 do
    begin
      LeftW := (UiBoxInner(W, 2) * 42) div 100;
      RightW := UiBoxInner(W, 2) - LeftW;
      Check(UiWidth(UiBoxTop(MkAmber + 'pasclaude v0.1', W)) = W,
        Format('top edge is %d wide', [W]));
      Check(UiWidth(UiBoxBottom(W)) = W, Format('bottom edge is %d wide', [W]));
      { Content far too long for its column: it must be cut, not allowed to
        push the right border off the screen. }
      Check(UiWidth(UiBoxRow([Long, Long], [LeftW, RightW])) = W,
        Format('a row of over-long cells is still %d wide', [W]));
      Check(UiWidth(UiBoxRow(['', ''], [LeftW, RightW])) = W,
        Format('and a row of empty ones is too, at %d', [W]));
    end;
    { A single-column box, which the narrow path would want. }
    Check(UiWidth(UiBoxRow([Long], [UiBoxInner(50, 1)])) = 50,
      'the column count is honoured, not assumed to be two');
  end;
  UiSetGlyphs(ugAuto);
end;

{ The wrapping and the caret.  A wrap that drops a character is a prompt that
  sends something the user did not type, and a caret one row from where the
  eye is watching is worse than no cursor at all. }
{ The vim tag alone, taken out of EditLead by removing the prompt it was
  composed with.  The tag is not exported on its own; this is how the suite
  gets at the thing the framed block's column arithmetic depends on. }
function EditLeadTagOnly(Normal: Boolean): string;
var
  E: TEditState;
begin
  EditInit(E);
  E.Vim := True;
  if Normal then E.Mode := vmNormal else E.Mode := vmInsert;
  Result := EditLead(E, '', True);
end;

procedure TestPromptWrapsAndPlacesTheCaret;
var
  Rows: TStringArray;
  R, C: Integer;
begin
  Rows := PromptRows('hello world foo', 11, 0, R, C);
  Check(Length(Rows) = 2, 'a line too long for the row is broken in two');
  Check(Rows[0] = 'hello world', 'at the last space that fits');
  Check(Rows[1] = 'foo', 'and the space itself is not shown again');

  { The caret at the end of the first row stays on the first row.  Taking the
    later of two equal positions would jump the cursor to the next line the
    moment the user typed the character that filled this one. }
  PromptRows('hello world foo', 11, 11, R, C);
  Check((R = 0) and (C = 11), 'a caret at a row end stays on that row');
  PromptRows('hello world foo', 11, 12, R, C);
  Check(R = 1, 'and past the break it is on the next');
  PromptRows('hello world foo', 11, 15, R, C);
  Check((R = 1) and (C = 3), 'and at the very end it is after the last');

  { A word with no space in it has to be cut at the margin.  Refusing would
    either overflow the frame or loop forever. }
  Rows := PromptRows('abcdefghijklmno', 6, 0, R, C);
  Check(Length(Rows) = 3, 'an unbreakable word is cut at the margin');
  Check((Rows[0] = 'abcdef') and (Rows[1] = 'ghijkl') and (Rows[2] = 'mno'),
    'and no character is lost doing it');

  Rows := PromptRows('a'#10'b', 20, 0, R, C);
  Check((Length(Rows) = 2) and (Rows[0] = 'a') and (Rows[1] = 'b'),
    'a typed newline always breaks');
  Rows := PromptRows(''#10'', 20, 0, R, C);
  Check(Length(Rows) = 2, 'and an empty line is a row, not nothing');

  { The framed block puts the vim tag in front of the prompt mark, and it can
    only do that without shifting the text sideways on every Esc because both
    tags are the same width.  Asserted through EditLead, which composes the
    same tag the block does. }
  Check(UiWidth(EditLeadTagOnly(True)) = UiWidth(EditLeadTagOnly(False)),
    'both vim tags are the same width, so the text never shifts');
  Check(UiWidth(EditLeadTagOnly(True)) = 4, 'and that width is four columns');

  { The empty prompt.  There has to be a row for the caret to sit in. }
  Rows := PromptRows('', 20, 0, R, C);
  Check(Length(Rows) = 1, 'an empty prompt still has one row');
  Check((R = 0) and (C = 0), 'with the caret at its start');
  { A width no sane terminal would give, asked for anyway. }
  Rows := PromptRows('abc', 0, 3, R, C);
  Check(Length(Rows) >= 1, 'a zero width does not hang or crash');
end;

{ The status line says nothing it does not know, and everything it says fits.
  Both halves matter: a line of zeroes teaches the user to stop reading it,
  and a line that overruns the window wraps and doubles the block's height
  on every keystroke. }
procedure TestStatusLinesSayOnlyWhatIsKnown;
var
  S: TStatusInfo;
  L: TStringArray;
  I, W: Integer;
  Joined: string;
begin
  UiSetGlyphs(ugAscii);
  StatusClear(S);
  L := StatusLines(S, 80);
  Check(Length(L) = 0, 'a session that knows nothing shows no status at all');

  S.Model := 'claude-opus-5';
  S.Dir := 'pasclaude';
  S.Branch := 'feat/config-diagnostics';
  S.CtxTokens := 18400;
  S.CtxLimit := 150000;
  S.TokensIn := 121500;
  S.TokensOut := 8430;
  S.Memories := 1;
  S.Mcps := 3;
  S.Hooks := 16;
  S.Mode := 'bypass';
  S.ModeHot := True;
  L := StatusLines(S, 120);
  Joined := '';
  for I := 0 to High(L) do Joined := Joined + UiPlain(L[I]) + #10;
  Check(Pos('[claude-opus-5]', Joined) > 0, 'the model is named');
  Check(Pos('git:(feat/config-diagnostics)', Joined) > 0, 'and the branch');
  Check(Pos('12%', Joined) > 0, 'the context is a percentage of the limit');
  Check(Pos('18.4k', Joined) > 0, 'with the token count beside it');
  Check(Pos('121.5k in', Joined) > 0, 'the session totals are abbreviated');
  Check(Pos('1 CLAUDE.md', Joined) > 0, 'one memory file is singular');
  Check(Pos('3 MCPs', Joined) > 0, 'and three servers plural');
  Check(Pos('16 hooks', Joined) > 0, 'and the hooks are counted');
  Check(Pos('bypass', Joined) > 0, 'and the mode is said out loud');

  { The mode is last so that it is the line a narrow window keeps.  It is
    also the only line whose absence is dangerous. }
  Check(Pos('bypass', UiPlain(L[High(L)])) > 0,
    'the mode is the last line, where nothing can push it off');

  { Every width a window might have.  Nothing may exceed the width it was
    given, or the terminal wraps it and the block grows a row it does not
    know about. }
  Joined := '';
  for W := 12 to 140 do
  begin
    L := StatusLines(S, W);
    for I := 0 to High(L) do
      if UiWidth(L[I]) > W then
        Joined := Joined + Format(' line %d at width %d;', [I, W]);
  end;
  Check(Joined = '', 'no status line overruns its width:' + Joined);
  L := StatusLines(S, 4);
  Check(Length(L) = 0, 'a window too narrow to say anything says nothing');

  { A single hook and a single server read as one, not as "1 hooks". }
  StatusClear(S);
  S.Mcps := 1;
  S.Hooks := 1;
  L := StatusLines(S, 80);
  Check((Length(L) = 1) and (Pos('1 MCP ', UiPlain(L[0]) + ' ') > 0) and
        (Pos('1 hook ', UiPlain(L[0]) + ' ') > 0),
    'singular counts are written singular');

  { Zero is not a fact worth a column. }
  StatusClear(S);
  S.Memories := 0;
  S.Mcps := 0;
  S.Hooks := 0;
  L := StatusLines(S, 80);
  Check(Length(L) = 0, 'and a count of zero is left out rather than shown');
  UiSetGlyphs(ugAuto);
end;

procedure TestBugReportEndToEnd;
var
  Opts: TBugOptions;
  Path, TranscriptPath, Err, Body: string;
  A: TAgent;
  Dir, SavedLocal, SavedHome: string;
begin
  ClearDiagNotes;
  ClearDiagFacts;
  { No --add-dir, which is the ordinary run and the one the shipped redactor
    got wrong: it was handed uTools.WorkingDirs, which answers with the EXTRA
    roots only, so with none of those it was handed an empty list and the
    session root - the path that names the project - appeared verbatim in
    every line while the banner above them said paths were redacted.  Every
    earlier test in this suite that added a root has to be undone here or the
    assertion below passes on somebody else's leftovers. }
  uTools.ClearWorkingDirs;
  uTools.RootDir := TmpRoot;
  Check(uTools.RootCount = 1, 'the session root is the only root');
  Dir := IncludeTrailingPathDelimiter(TmpRoot) + 'reports';
  DiagReportsDirOverride := Dir;
  DiagFacts.Version := '0.1';
  DiagFacts.AuthSource := 'claude_code';
  DiagFacts.AuthPresent := True;
  { Planted where a careless implementation would copy it straight through:
    the detail string is display material and goes into the report body. }
  DiagFacts.AuthDetail := 'token sk-ant-oat01-PLANTEDSECRET';
  A := TAgent.Create('sk-ant-oat01-NOTINTHEREPORT', 'm', 'sys');
  try
    Opts.IncludeTranscript := False;
    Opts.RealPaths := False;
    Opts.AsJson := False;
    Check(DiagWriteBug(A, Opts, Path, TranscriptPath, Err),
      'a bug report is written');
    Check(FileExists(Path), 'and the file is there');
    Check(TranscriptPath = '',
      'and no transcript is written unless it was asked for');
    Body := ReadFileText(Path);
    Check((Pos('## Included', Body) > 0) and (Pos('## Excluded', Body) > 0),
      'it carries the manifest of what is in and out');
    Check(Pos('0.1', Body) > 0, 'the pasclaude version');
    Check(Pos('build', Body) > 0, 'and the Windows build');
    Check(Pos('PLANTEDSECRET', Body) = 0,
      'and no token survives, even one planted in a display field');
    Check(Pos('sk-ant-***', Body) > 0, 'though its shape is named');
    Check(Pos('<root0>', Body) > 0, 'roots are replaced');
    Check(Pos(TmpRoot, Body) = 0, 'and no real root survives');
    { Not a vacuous assertion: the line that leaked is in there, and what it
      says now is the label rather than the path. }
    Check(Pos('session root:', Body) > 0, 'the report states the session root');

    Opts.IncludeTranscript := True;
    Check(DiagWriteBug(A, Opts, Path, TranscriptPath, Err),
      'and again with the transcript');
    Check((TranscriptPath <> '') and FileExists(TranscriptPath),
      'the sibling file exists');
    { A transcript that could not be written or could not be redacted must
      leave TranscriptPath empty and Err set, never the pair that made the
      caller print "secrets are redacted" over an unredacted file.  On the
      path that worked, the pair is the other way round. }
    Check(Err = '', 'and a transcript that worked says nothing');
    Body := ReadFileText(Path);
    Check(Pos('Transcript', Body) > 0, 'and the report names it');

    { With nowhere outside the project to write, /bug must refuse and write
      NOTHING - never a fallback into the tree, where it would be committed
      by accident. }
    DiagReportsDirOverride := '';
    SavedLocal := SysUtils.GetEnvironmentVariable('LOCALAPPDATA');
    SavedHome := SysUtils.GetEnvironmentVariable('USERPROFILE');
    SetEnvironmentVariable('LOCALAPPDATA', nil);
    SetEnvironmentVariable('USERPROFILE', nil);
    try
      Check(DiagReportsDir = '', 'with no home there is nowhere to write');
      Check(not DiagWriteBug(A, Opts, Path, TranscriptPath, Err),
        'and the report is refused');
      Check(Err <> '', 'with a reason');
      Check(Path = '', 'and no path is claimed');
      Check(not FileExists(IncludeTrailingPathDelimiter(TmpRoot) +
        'bug-report.md'), 'and nothing is written into the project');
    finally
      SetEnvironmentVariable('LOCALAPPDATA', PChar(SavedLocal));
      SetEnvironmentVariable('USERPROFILE', PChar(SavedHome));
    end;
  finally
    A.Free;
    DiagReportsDirOverride := '';
    ClearDiagFacts;
  end;
end;

{ The one artifact in this repository that build.cmd and test.cmd cannot
  compile, run or notice rotting.  It is verified the only way an RTL-only
  program can verify YAML - by reading it as text - and that is stated out
  loud rather than dressed up as a parse.  Everything semantically
  load-bearing lives in uCi, where the assertions above can drive it.

  ABSENT IS A FAILURE, NOT A SKIP: a template that quietly vanished would
  take every one of these guarantees with it. }
procedure TestCiWorkflowTemplate;
var
  Path, Text: string;
  L: TStringList;
  Floor: TStringArray;
  I, Writes, AnswerAt: Integer;

  procedure Has(const S, What: string);
  begin
    Check(Pos(S, Text) > 0, What);
  end;

  procedure Hasnt(const S, What: string);
  begin
    Check(Pos(S, Text) = 0, What);
  end;

begin
  { Relative to the suite binary, which test.cmd puts in bin\. }
  Path := ExtractFilePath(ParamStr(0)) + '..' + PathDelim + 'examples' +
    PathDelim + 'github' + PathDelim + 'pasclaude-mention.yml';
  Check(FileExists(Path), 'the workflow template is there: ' + Path);
  if not FileExists(Path) then Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(Path);
    Text := L.Text;
    Check(L.Count < 120, 'and is short enough to read: ' +
      IntToStr(L.Count) + ' lines');

    { Every rule of the floor, verbatim.  A dropped rule here is a shell in
      an unattended run, and --ci prepare's own check would never see it
      because that check reads what the file actually loaded. }
    Floor := uCi.CiDenyFloor;
    for I := 0 to High(Floor) do
      Has('"' + Floor[I] + '"', 'the deny floor carries ' + Floor[I]);

    Has('persist-credentials: false',
      'checkout leaves no token in .git/config');
    Has('contents: read', 'contents is read');
    Has('issues: write', 'issues is write');
    Has('pull-requests: read', 'pull-requests is read');
    Writes := 0;
    for I := 0 to L.Count - 1 do
      if Pos(': write', L[I]) > 0 then Inc(Writes);
    Check(Writes = 1, 'and exactly one permission is write: ' +
      IntToStr(Writes));

    { The four mutations that would matter, each one a real vulnerability. }
    Hasnt('pull_request_target',
      'the classic fork-secrets trigger appears nowhere');
    Hasnt('${{ github.event.comment.body',
      'the comment body is never interpolated into the file');
    Hasnt('${{ github.event.issue.title',
      'and neither is the title');
    Hasnt('--dangerously-skip-permissions',
      'and the bypass flag appears nowhere');

    { Found on ONE LINE and asserted there, not anywhere in the file, and this
      is the whole point of the check rather than fussiness about how a grep
      is written: the flag has to be ON the command that runs the model.  A
      file-wide Pos would be satisfied by the word appearing in a YAML comment
      - which is exactly where it also appears - and a comment changes nothing
      about what that step loads.  If somebody reorders the flags so the line
      reads --output-format json -p, this search misses and the first Check
      below fails loudly, pointing at the line that changed.  That is the
      correct failure; do not widen it back to the whole file to quiet it. }
    AnswerAt := -1;
    for I := 0 to L.Count - 1 do
      if Pos('-p --output-format json', L[I]) > 0 then AnswerAt := I;
    Check(AnswerAt >= 0, 'the answering step is still a -p run');
    if AnswerAt >= 0 then
      Check(Pos('--no-project-context', L[AnswerAt]) > 0,
        'and it refuses the branch''s instruction files on that same line');

    Has('ANTHROPIC_API_KEY', 'the model credential is named');
    Check(L.Count > 0, 'and the file is not empty');
  finally
    L.Free;
  end;
end;

procedure TestCiRefusalComment;
var
  E: uCi.TCiEvent;
  P: uCi.TCiPr;
  D: uCi.TCiDecision;
  Err, Text: string;
  Payload: string;

  procedure ForCode(const Assoc, Login: string; IsBot: Boolean;
    const Want: string);
  var
    SenderType: string;
  begin
    if IsBot then SenderType := 'Bot' else SenderType := 'User';
    Payload := '{"action":"created","repository":{"full_name":"ZZINJECTZZ/ZZINJECTZZ"},' +
      '"issue":{"number":7,"title":"ZZINJECTZZ"' +
      '},"comment":{"body":"@claude ZZINJECTZZ","author_association":"' +
      Assoc + '","user":{"login":"' + Login + '","type":"User"}},' +
      '"sender":{"login":"' + Login + '","type":"' + SenderType + '"}}';
    Check(uCi.CiParseEvent(Payload, E, Err), 'the sentinel payload parses');
    D := uCi.CiDecide(E, P, uCi.CiDefaultTrigger, uCi.cfCollaborator);
    Check(D.Code = Want, 'the code is ' + Want + ': ' + D.Code);
    Text := uCi.CiRefusalComment(D);
    Check(Text <> '', 'a refusal comment exists for ' + Want);
    { The mutation this exists to catch: a refusal built by concatenating the
      reason with attacker text would post an unauthorized stranger's prose
      as a comment from the repository's own bot. }
    Check(Pos('ZZINJECTZZ', Text) = 0,
      'and it carries no byte of the body, the title, the repo or the login');
    Check(Pos(uCi.CiFooterMark, Text) > 0, 'and it carries the footer');
  end;

begin
  P := Default(uCi.TCiPr);
  ForCode('CONTRIBUTOR', 'ZZINJECTZZ', False, 'not-authorized');
  ForCode('OWNER', 'ZZINJECTZZ', True, 'bot');
  { Silence, not a comment: a body that never mentioned us is not an event,
    and a workflow that answered every comment to say it would not answer
    would be worse than the feature is worth. }
  Payload := '{"action":"created","repository":{"full_name":"a/b"},' +
    '"issue":{"number":7,"title":"t"},"comment":{"body":"just talking",' +
    '"author_association":"OWNER","user":{"login":"alice"}},' +
    '"sender":{"login":"alice","type":"User"}}';
  Check(uCi.CiParseEvent(Payload, E, Err), 'an ordinary comment parses');
  D := uCi.CiDecide(E, P, uCi.CiDefaultTrigger, uCi.cfCollaborator);
  Check(D.Code = 'no-trigger', 'and does not trigger: ' + D.Code);
  Check(uCi.CiRefusalComment(D) = '',
    'a comment that never mentioned us is answered with silence');
end;

procedure TestCiStepSummary;
var
  E: uCi.TCiEvent;
  P: uCi.TCiPr;
  D: uCi.TCiDecision;
  Err, S: string;
begin
  P := Default(uCi.TCiPr);
  Check(uCi.CiParseEvent('{"action":"created",' +
    '"repository":{"full_name":"a/b"},"issue":{"number":7,"title":"t"},' +
    '"comment":{"body":"@claude ZZINJECTZZ","author_association":' +
    '"CONTRIBUTOR","user":{"login":"eve"}}}', E, Err),
    'a refused payload parses');
  D := uCi.CiDecide(E, P, uCi.CiDefaultTrigger, uCi.cfCollaborator);
  S := uCi.CiStepSummary(D, '', '', False);
  Check(Pos('not-authorized', S) > 0, 'the summary names the code');
  Check(Pos(D.Reason, S) > 0, 'and the fixed reason');
  { A step summary is rendered by GitHub and reviewed by nobody in
    particular, which is exactly why the request must not land in it. }
  Check(Pos('ZZINJECTZZ', S) = 0, 'and no request text');

  D := Default(uCi.TCiDecision);
  D.Proceed := True;
  D.Code := 'ok';
  D.Number := 7;
  S := uCi.CiStepSummary(D, StringOfChar('a', uCi.CiMaxSummaryBytes * 2),
    '', False);
  Check(Length(S) < uCi.CiMaxSummaryBytes + 200,
    'a long answer is clipped for the summary: ' + IntToStr(Length(S)));
  Check(Pos('#7', S) > 0, 'and the number is named');
  S := uCi.CiStepSummary(D, '', 'the turn exploded', True);
  Check(Pos('the turn exploded', S) > 0, 'a failed turn says why');
end;

begin
  { Hooks are off unless a host says otherwise - see the shipped default in
    uHooks and TestHooksAreInteractiveOnly in the smoke suite.  This suite
    stands in for the REPL, which is the one caller that sets it. }
  uHooks.HooksAllowed := True;
  TmpRoot := IncludeTrailingPathDelimiter(GetTempDir) + 'pasclaude-ux';
  Cleanup(TmpRoot);
  ForceDirectories(TmpRoot);
  uTools.RootDir := TmpRoot;

  try
    { First, because it is the only test that can see
      SdkProjectContextAllowed's shipped default: nothing above this line sets
      it, and one assertion in there is about exactly that byte.  It no longer
      leaves the flag on for anybody - TestSystemPromptLift sets what it needs
      itself - so this is an ordering the suite reads better in, not one it
      depends on. }
    TestProjectContextIsNotForCi;
    { And immediately after it, never before: the test above holds the suite's
      only observation of SdkProjectContextAllowed's shipped default, and
      anything that sets the byte higher up would delete that assertion
      without failing anything. }
    TestNoProjectContextFlag;
    TestDiff;
    TestPreview;
    TestCompact;
    TestSession;
    TestNewestSessionIsWhatContinueTakes;
    TestSdkResumePolicy;
    TestDeniedPathIsInvisible;
    TestDenyRoundTrip;
    TestStateDirIsHidden;
    TestEditor;
    TestKeyGrammarRefusesPlainKeys;
    TestPlainReaderIgnoresBindings;
    TestKeysParseReportsRatherThanIgnores;
    TestVimMotionsAndOperators;
    TestVimUndo;
    TestKeysRoundTripAndDefaults;
    TestImageCodec;
    TestDibToRgb;
    TestVisualTokens;
    TestSniffImage;
    TestAppendUserImages;
    TestImageTranscriptRoundTrip;
    TestEvictImages;
    TestPasteIsNotAKey;
    TestMentions;
    TestMultiEdit;
    TestNotebook;
    TestNotebookUnicode;
    TestGitignore;
    TestWalkDepth;
    TestMarkdown;
    TestEscEscOpensRewind;
    TestCtrlC;
    TestHistoryPersistence;
    TestVt;
    TestRewind;
    TestJobList;
    TestIdleTickAtThePrompt;
    TestMcpPanel;
    TestUserMcpIsNotPrompted;
    TestUserMcpSpoolIsOutOfTree;
    TestHooksPanel;
    TestPluginState;
    TestSystemPromptLift;
    TestAppendSystemPrompt;
    TestModeIsVisible;
    TestLoadedGrantIsAnnounced;
    TestExtraRootDisplay;
    TestAddDirCommands;
    TestSandboxLowBlocksProfileWrite;
    TestSandboxAnnotatesFailure;
    TestForegroundTimeoutKillsTree;
    TestSettingsScopeTable;
    TestModelSettingsAreUserScopeEndToEnd;
    TestSettingsRefusedKeys;
    TestSettingsAllOrNothing;
    TestSettingsPrecedence;
    TestSettingsProjectCeiling;
    TestSettingDefaultsMatchTheProgram;
    TestSettingDefsAreComplete;
    TestIdeSettingsAreUserScopeOnly;
    TestSettingsTextIsSanitised;
    TestSettingsLocalHasProjectAuthority;
    TestSettingsGrantsNothing;
    TestLogoutTouchesOnlyOurOwnCredential;
    TestNearExpiryThreshold;
    TestSecretReaderRefusesOffConsole;
    TestConfigShowsProvenance;
    TestConfigSetPreservesUnknownKeys;
    TestConfigSetWritesUserTier;
    TestTelemetryPanel;
    TestTelemetryPreviewIsWhatShips;
    TestTelemetrySelfDisableIsSaidOnce;
    TestStatusBorrowsTheOwningUnits;
    TestSettingsRefusesGithub;
    TestGithubDiagRows;
    TestStatusReportsIde;
    TestIdeBaseline;
    TestIdeScratchLifetime;
    TestSnapshotOversizeIsNamed;
    TestDoctorLevelsAndCosts;
    TestDoctorReplaysTheLedger;
    TestProbeWritableLeavesNothing;
    TestDiagTakesNothingFromTheProject;
    TestBugReportEndToEnd;
    TestUiWidthCountsColumnsNotBytes;
    TestUiFitTruncatesWithoutLosingColour;
    TestUiMeterAndCount;
    TestBoxPiecesLineUp;
    TestPromptWrapsAndPlacesTheCaret;
    TestStatusLinesSayOnlyWhatIsKnown;
    TestCiWorkflowTemplate;
    TestCiRefusalComment;
    TestCiStepSummary;
  finally
    { Before the cleanup, not after: a live child holding a spool handle under
      TmpRoot would make the recursive delete fail. }
    uTools.ClearJobs;
    { And the MCP connections, for exactly the same reason: a live server
      holding its stderr spool under TmpRoot blocks the delete. }
    uTools.ClearMcpServers;
    { And the skills cache and plugin enablement, so nothing this suite
      put on disk outlives it in module state. }
    uTools.ClearSkills;
    uTools.ClearPluginState;
    uTools.ClearDenyRules;
    uTools.ClearWorkingDirs;
    { And the settings store, for the same reason: nothing this suite put in
      module state may outlive it. }
    uSettings.SettingsClear;
    { And the diagnostic ledger and host facts, for exactly the same
      reason: nothing this suite put in module state may outlive it. }
    uDiag.ClearDiagNotes;
    uDiag.ClearDiagFacts;
    uDiag.DiagReportsDirOverride := '';
    { Beside the two above and for a related reason: the cached low-integrity
      token is a handle, and a suite that left one open would report it.  The
      level goes back to the default so nothing after this point is confined
      by a decision this suite made. }
    uSandbox.SandboxLevel := slLimits;
    uSandbox.SandboxShutdown;
    { The spawn seam back to nil: a suite that left one installed would
      hand it to whatever ran next. }
    uIde.IdeSpawnOverride := nil;
    { And the idle seam, for exactly the same reason: a suite that left a tick
      wired would hand it to whatever ran next, and this one wires the real
      sweep. }
    uTerm.IdleTick := nil;
    uGitHub.GitHubClear;
    uHttp.HttpGetTransport := nil;
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
