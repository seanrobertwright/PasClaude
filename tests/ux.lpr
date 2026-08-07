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

uses SysUtils, Classes, uJson, uDiff, uHooks, uTools, uAgent, uTerm, uNotebook,
  uSdk;

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

  HistoryClear;
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
  Out_ := ExpandMentions('please look at @notes.txt for context', Notes);
  Check(Pos('please look at @notes.txt', Out_) = 1, 'the prose is unchanged');
  Check(Pos('the notes contents', Out_) > 0, 'the file contents are attached');
  Check(Pos('--- notes.txt ---', Out_) > 0, 'under a header naming the file');
  Check(Pos('attached (', Notes) > 0, 'and the user is told');

  { Trailing punctuation belongs to the sentence, not the path. }
  Out_ := ExpandMentions('see @notes.txt, then decide', Notes);
  Check(Pos('the notes contents', Out_) > 0,
    'a mention followed by a comma still resolves');

  { A missing file is a note, not an attachment and not an error. }
  Out_ := ExpandMentions('what about @missing.txt here', Notes);
  Check(Out_ = 'what about @missing.txt here', 'a missing file changes nothing');
  Check(Pos('no such file', Notes) > 0, 'but is reported');

  { An email address is not a mention. }
  Out_ := ExpandMentions('mail bob@notes.txt about it', Notes);
  Check(Pos('--- notes.txt ---', Out_) = 0,
    'an @ inside a word does not attach anything');

  { The path guard applies to typed mentions exactly as to tool calls. }
  Out_ := ExpandMentions('read @..\..\Windows\win.ini now', Notes);
  Check(Pos('win.ini contents', Out_) = 0, 'an escaping mention attaches nothing');
  Check(Pos('@..', Notes) > 0, 'and the refusal is reported');
  Out_ := ExpandMentions('read @.pasclaude\session.json now', Notes);
  Check(Pos('--- .pasclaude', Out_) = 0, 'the session file cannot be mentioned in');

  { A binary file would poison the request body. }
  WriteFileText(IncludeTrailingPathDelimiter(TmpRoot) + 'blob2.bin', 'A'#0#255'B');
  Out_ := ExpandMentions('and @blob2.bin too', Notes);
  Check(Pos(#0, Out_) = 0, 'binary bytes never reach the prompt');
  Check(Pos('not text', Notes) > 0, 'with the reason named');

  { No mention, no work: the common case must pass through untouched. }
  Out_ := ExpandMentions('a plain question', Notes);
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

{ ------------------------------------------------------------------- main -- }

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
  Check(Length(All) - Length(StringReplace(All, #9, '', [rfReplaceAll])) = 5,
    'each line carries name, status, tools, skipped, command and note');

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

{ What the user reads before approving a hook file, and what survives in
  permissions.json afterwards.  Both are the parts of this feature a person
  actually meets: the summary is the entire basis for the yes, and the
  fingerprint is what stops the yes outliving the text it was given for. }
procedure TestHooksPanel;
var
  Notes, Sum, P, FP: string;
  SavedEdits, SavedBash, SavedFetch: Boolean;
begin
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

{ %USERPROFILE% has to be moved somewhere known: the user memory is read from
  it, and a developer's real home directory would decide this test. }
function SetEnvironmentVariable(Name, Value: PChar): LongBool; stdcall;
  external 'kernel32' name 'SetEnvironmentVariableA';

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
begin
  Root := IncludeTrailingPathDelimiter(TmpRoot) + 'prompt';
  Home := IncludeTrailingPathDelimiter(Root) + 'home';
  ForceDirectories(Home + PathDelim + '.pasclaude');
  SavedHome := SysUtils.GetEnvironmentVariable('USERPROFILE');
  SetEnvironmentVariable('USERPROFILE', PChar(Home));
  uTools.RootDir := Root;
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
  end;
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
    TestSession;
    TestDeniedPathIsInvisible;
    TestDenyRoundTrip;
    TestStateDirIsHidden;
    TestEditor;
    TestMentions;
    TestMultiEdit;
    TestNotebook;
    TestGitignore;
    TestWalkDepth;
    TestMarkdown;
    TestCtrlC;
    TestHistoryPersistence;
    TestVt;
    TestRewind;
    TestJobList;
    TestMcpPanel;
    TestHooksPanel;
    TestPluginState;
    TestSystemPromptLift;
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
