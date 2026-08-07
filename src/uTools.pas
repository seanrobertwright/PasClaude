{ uTools - the tools the model is allowed to call, and the permission gate.

  Every tool that changes the machine (write, edit, bash) asks the user first,
  unless the session has been put in accept-all mode.  Reads are free.  Paths
  are resolved against the session root and refused when they escape it, so a
  confused model cannot walk into C:\Windows by accident. }
unit uTools;

{$mode objfpc}{$H+}

interface

uses SysUtils, uJson, uDiff;

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
  AllowAllFetch: Boolean = False;

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

{ Resolves P under the session root with the same rules every tool applies:
  no escaping the root, no reaching into pasclaude's own state.  Exposed so
  @file mentions face the same guard as tool calls. }
function ResolveInRoot(const P: string; out Full: string; out Err: string): Boolean;

{ Loads the root .gitignore, if any.  Called once at startup and after /clear
  of the cache would make no sense - the file rarely changes mid-session. }
procedure LoadIgnoreRules;

{ True when a path relative to the root matches an ignore rule.  Exposed for
  the tests; the walkers consult it internally. }
function IsIgnored(const RelPath: string; IsDir: Boolean): Boolean;

{ Runs a command in the session root and returns its combined output, for the
  host's own use (git context at startup).  Same machinery as the bash tool,
  without the permission gate - the host is not the model. }
function RunShellQuiet(const Cmd: string; out ExitCode: Integer): string;

{ The leading program name of a shell command - the part an "always" answer
  reasonably covers.  Exposed for the tests. }
function BashPrefix(const Cmd: string): string;
{ True when Cmd's prefix was approved with "always" earlier this session. }
function BashPrefixAllowed(const Cmd: string): Boolean;
{ Records Cmd's prefix as approved.  Exposed for the tests. }
procedure AllowBashPrefix(const Cmd: string);
{ Test seam: forget every approved prefix. }
procedure ClearBashPrefixes;

{ Files the write and edit tools actually touched this session, relative to
  the root, oldest first, without duplicates.  Approvals happen one edit at
  a time; this is the aggregated answer to "what changed?". }
function ChangedFiles: TStringArray;
{ Records a touched file.  RunTool calls it on success; exposed for tests. }
procedure NoteChangedFile(const RelPath: string);
{ Test seam and /clear: forget the list. }
procedure ClearChangedFiles;

{ The task list the model maintains through the todo_write tool, rendered
  by the host after each update.  One string per item, prefixed with its
  state: '[ ] ', '[~] ' (in progress), '[x] '. }
function CurrentTodos: TStringArray;
{ Test seam and /clear. }
procedure ClearTodos;

{ ---- file snapshots, the disk half of /rewind ----
  Before a write or edit changes a file, its prior state is captured against
  the current turn number.  Rewinding to turn N restores every touched file
  to the oldest snapshot at or after N - the state it had when N began. }

{ Marks the turn now starting; snapshots taken from here belong to it. }
procedure BeginTurn(TurnNo: Integer);
{ Restores every file touched at or after TurnNo and forgets those
  snapshots.  Notes lists what was restored or why something could not be.
  Returns the number of files put back. }
function RestoreFilesSince(TurnNo: Integer; out Notes: string): Integer;
{ Test seam and /clear. }
procedure ClearSnapshots;
{ Test seam: how many snapshots are held. }
function SnapshotCount: Integer;

{ Loads standing approvals from Path: the tool-class "always" answers and
  the approved bash programs, so an "a" gives once survives restarts.  A
  missing or unreadable file simply approves nothing. }
procedure LoadPermissions(const Path: string);
{ Writes the standing approvals to Path.  Failures are swallowed: the
  session works identically, approvals just will not persist. }
procedure SavePermissions(const Path: string);

implementation

uses Classes, Process, Windows, uHttp, uRegex, uNotebook;

const
  MaxReadBytes = 400 * 1024;   { keeps a stray huge file out of the context }
  { The ceiling on the depth argument of list_dir and search.  The complaint
    the argument answers is a *fixed* cap, not the existence of one: with no
    ceiling at all a single list_dir on a node_modules-shaped tree would do
    unbounded work only for Clip to throw most of the answer away. }
  MaxWalkDepth = 12;
  { A notebook is read whole or not at all.  The 400 KB cap would cut it
    mid-JSON, which is the one truncation that costs everything: a partial
    document does not parse, so the model gets a corrupt file rather than a
    short one.  Eight megabytes is affordable precisely because the outputs
    are summarised away - what reaches the model is the cells, not the
    base64 that makes the file big. }
  MaxNotebookBytes = 8 * 1024 * 1024;
  MaxOutBytes  = 30 * 1024;    { cap on any single tool result }
  { A fetched page larger than this is cut; the model gets the front, which
    is where documents put what they are about. }
  MaxFetchBytes = 200 * 1024;
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

function ResolveInRoot(const P: string; out Full: string; out Err: string): Boolean;
begin
  Result := SafePath(P, Full, Err);
end;

{ -------------------------------------------------------------- .gitignore -- }

{ A deliberately partial reading of the format: comments, blank lines,
  dir-only rules (trailing /), anchored rules (leading /), and * within a
  segment.  Negation (!) is honoured for whole rules.  The full spec has
  corner cases (** spans, character classes) that build tools need and a
  listing filter does not; anything unmatched is simply shown, which errs on
  the side of the model seeing more rather than less. }
type
  TIgnoreRule = record
    Pattern: string;      { lowercased, / separators }
    DirOnly: Boolean;
    Anchored: Boolean;
    Negated: Boolean;
  end;

var
  IgnoreRules: array of TIgnoreRule;

procedure LoadIgnoreRules;
var
  L: TStringList;
  I, N: Integer;
  S: string;
  R: TIgnoreRule;
begin
  SetLength(IgnoreRules, 0);
  if not FileExists(IncludeTrailingPathDelimiter(NormalizeRoot) + '.gitignore') then
    Exit;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(IncludeTrailingPathDelimiter(NormalizeRoot) + '.gitignore');
    except
      Exit;   { an unreadable .gitignore just means nothing is filtered }
    end;
    N := 0;
    for I := 0 to L.Count - 1 do
    begin
      S := Trim(L[I]);
      if (S = '') or (S[1] = '#') then Continue;
      R.Negated := S[1] = '!';
      if R.Negated then Delete(S, 1, 1);
      R.DirOnly := (S <> '') and (S[Length(S)] = '/');
      if R.DirOnly then SetLength(S, Length(S) - 1);
      R.Anchored := (S <> '') and (S[1] = '/');
      if R.Anchored then Delete(S, 1, 1);
      if S = '' then Continue;
      R.Pattern := LowerCase(StringReplace(S, '\', '/', [rfReplaceAll]));
      SetLength(IgnoreRules, N + 1);
      IgnoreRules[N] := R;
      Inc(N);
    end;
  finally
    L.Free;
  end;
end;

{ Matches Pattern against one path segment or segment run, with * spanning
  anything except a separator. }
function SegMatch(const Pattern, S: string): Boolean;
var
  P, T: Integer;
  StarP, StarT: Integer;
begin
  P := 1;
  T := 1;
  StarP := 0;
  StarT := 0;
  while T <= Length(S) do
  begin
    if (P <= Length(Pattern)) and
       ((Pattern[P] = S[T]) or (Pattern[P] = '?')) then
    begin
      Inc(P);
      Inc(T);
    end
    else if (P <= Length(Pattern)) and (Pattern[P] = '*') then
    begin
      StarP := P;
      StarT := T;
      Inc(P);
    end
    else if StarP > 0 then
    begin
      { Backtrack: the star swallows one more character, but never a
        separator - that is what keeps *.txt from matching a\b.txt. }
      if S[StarT] = '/' then Exit(False);
      Inc(StarT);
      P := StarP + 1;
      T := StarT;
    end
    else
      Exit(False);
  end;
  while (P <= Length(Pattern)) and (Pattern[P] = '*') do
    Inc(P);
  Result := P > Length(Pattern);
end;

function IsIgnored(const RelPath: string; IsDir: Boolean): Boolean;
var
  I, J: Integer;
  Path, Seg: string;
  Rule: TIgnoreRule;
  Segs: array of string;
  NSeg: Integer;
  Hit: Boolean;
begin
  Result := False;
  if Length(IgnoreRules) = 0 then Exit;
  Path := LowerCase(StringReplace(RelPath, '\', '/', [rfReplaceAll]));

  { Split once; a rule may match the whole path or any single segment. }
  NSeg := 0;
  SetLength(Segs, 0);
  Seg := '';
  for I := 1 to Length(Path) do
    if Path[I] = '/' then
    begin
      SetLength(Segs, NSeg + 1);
      Segs[NSeg] := Seg;
      Inc(NSeg);
      Seg := '';
    end
    else
      Seg := Seg + Path[I];
  SetLength(Segs, NSeg + 1);
  Segs[NSeg] := Seg;
  Inc(NSeg);

  { Last matching rule wins, as in git. }
  for I := 0 to High(IgnoreRules) do
  begin
    Rule := IgnoreRules[I];
    { A dir-only rule can still hit a file underneath the directory: the
      match is applied to every ancestor segment as well as the leaf. }
    Hit := False;
    if Rule.Anchored then
      Hit := SegMatch(Rule.Pattern, Path) or
             ((Pos('/', Rule.Pattern) = 0) and (NSeg > 0) and
              SegMatch(Rule.Pattern, Segs[0]) and
              ((NSeg > 1) or IsDir or not Rule.DirOnly))
    else if Pos('/', Rule.Pattern) > 0 then
      Hit := SegMatch(Rule.Pattern, Path)
    else
      for J := 0 to NSeg - 1 do
        if SegMatch(Rule.Pattern, Segs[J]) then
        begin
          { A dir-only rule matched on the leaf requires the leaf to be a
            directory; matched on an ancestor it always applies. }
          if Rule.DirOnly and (J = NSeg - 1) and not IsDir then Continue;
          Hit := True;
          Break;
        end;
    if Hit then
      Result := not Rule.Negated;
  end;
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

{ The reading half of every file tool.  Limit is a parameter rather than a
  constant because a notebook has to arrive whole to parse at all, while an
  ordinary source file only has to arrive in a useful quantity. }
function LoadFileLimited(const Full: string; Limit: Int64;
  out Text: string; out Err: string): Boolean;
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
    if N > Limit then N := Limit;
    SetLength(Text, N);
    if N > 0 then F.ReadBuffer(Text[1], N);
    if F.Size > Limit then
      Err := Format('(file is %d bytes; first %d shown)', [F.Size, Limit]);
    Result := True;
  finally
    F.Free;
  end;
end;

function LoadFileText(const Full: string; out Text: string; out Err: string): Boolean;
begin
  Result := LoadFileLimited(Full, MaxReadBytes, Text, Err);
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

{ MaxDepth 0 is the old non-recursive listing and 4 the old recursive one:
  both are now expressed as a depth rather than as a Boolean plus a constant,
  which is what lets the caller ask for more. }
function ListDir(const Full: string; MaxDepth: Integer): string;
var
  RootPrefix: string;

  procedure Walk(const Dir, Prefix: string; Depth: Integer);
  var
    R: TSearchRec;
    Dirs, Files: TStringList;
    I: Integer;
    RelName: string;
  begin
    if Depth > MaxDepth then Exit;
    Dirs := TStringList.Create;
    Files := TStringList.Create;
    try
      if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, R) = 0 then
      begin
        repeat
          if (R.Name = '.') or (R.Name = '..') then Continue;
          RelName := Copy(IncludeTrailingPathDelimiter(Dir) + R.Name,
            Length(RootPrefix) + 1, MaxInt);
          { .git and build output would flood the listing with noise. }
          if (R.Attr and faDirectory) <> 0 then
          begin
            if (R.Name = '.git') or (R.Name = 'node_modules') or
               (CompareText(R.Name, StateDirName) = 0) then Continue;
            if IsIgnored(RelName, True) then Continue;
            Dirs.Add(R.Name);
          end
          else
          begin
            if IsIgnored(RelName, False) then Continue;
            Files.Add(Format('%s (%d bytes)', [R.Name, R.Size]));
          end;
        until FindNext(R) <> 0;
        SysUtils.FindClose(R);
      end;
      Dirs.Sort;
      Files.Sort;
      for I := 0 to Dirs.Count - 1 do
      begin
        Result := Result + Prefix + Dirs[I] + '\'#10;
        if Depth < MaxDepth then
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
  RootPrefix := IncludeTrailingPathDelimiter(NormalizeRoot);
  Walk(Full, '  ', 0);
end;

{ ------------------------------------------------------------------ search -- }

{ Two engines behind one walker.  UseRegex is opt-in rather than sniffed from
  the pattern text, because real code searches are full of metacharacters used
  literally - "Result :=", "array[0]", "foo.bar" - and a "looks like a regex"
  heuristic would silently reinterpret them with no error anyone could see.
  Err is non-empty only when the pattern would not compile; the caller turns
  that into a tool error. }
function GrepTree(const Root, Pattern, Glob: string;
  UseRegex, CaseSensitive: Boolean; MaxDepth: Integer;
  out Err: string): string;
var
  Hits: Integer;
  RootPrefix, Needle: string;
  Rx: TRegex;
  Truncated: Boolean;

  { The match decision for one line.  A budget exhaustion is not a miss: it
    means the answer is unknown, so it stops the walk and is reported. }
  function LineHit(const L: string): Boolean;
  begin
    if UseRegex then
    begin
      case Rx.Match(L) of
        rrMatch: Result := True;
        rrBudget:
          begin
            Truncated := True;
            Result := False;
          end;
      else
        Result := False;
      end;
    end
    else if CaseSensitive then
      Result := Pos(Needle, L) > 0
    else
      Result := Pos(Needle, LowerCase(L)) > 0;
  end;

  function Matches(const Name: string): Boolean;
  begin
    if (Glob = '') or (Glob = '*') then Exit(True);
    { A glob containing * is exactly that and nothing else - otherwise
      nope*.txt would still match every .txt through the extension fallback,
      and a "did not match" filter that matches is worse than none.  The
      historical looser forms - a bare extension like ".pas", a substring -
      are kept only for starless patterns, because the model was told about
      them and models repeat what worked. }
    if Pos('*', Glob) > 0 then
      Exit(SegMatch(LowerCase(Glob), LowerCase(Name)));
    Result :=
      (LowerCase(ExtractFileExt(Name)) = LowerCase(ExtractFileExt(Glob))) or
      (Pos(LowerCase(Glob), LowerCase(Name)) > 0);
  end;

  procedure Walk(const Dir: string; Depth: Integer);
  var
    R: TSearchRec;
    { Named apart from the enclosing function's out parameter: Err there is
      the compile error, and shadowing it here would be a trap. }
    LText, LErr, Line: string;
    L: TStringList;
    I: Integer;
    RelName: string;
  begin
    if (Depth > MaxDepth) or (Hits >= 200) or Truncated then Exit;
    if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, R) = 0 then
    begin
      repeat
        if (R.Name = '.') or (R.Name = '..') then Continue;
        RelName := Copy(IncludeTrailingPathDelimiter(Dir) + R.Name,
          Length(RootPrefix) + 1, MaxInt);
        if (R.Attr and faDirectory) <> 0 then
        begin
          { The session file holds the whole conversation, so a search that
            matched it would feed the transcript back into the model - growing
            the context every turn with a copy of itself. }
          if (R.Name = '.git') or (R.Name = 'node_modules') or
             (CompareText(R.Name, StateDirName) = 0) then Continue;
          if IsIgnored(RelName, True) then Continue;
          Walk(IncludeTrailingPathDelimiter(Dir) + R.Name, Depth + 1);
        end
        else if Matches(R.Name) and (R.Size < MaxReadBytes) then
        begin
          if IsIgnored(RelName, False) then Continue;
          if not LoadFileText(IncludeTrailingPathDelimiter(Dir) + R.Name, LText, LErr) then
            Continue;
          { A hit goes straight into a JSON request body, where one bad byte
            makes the API reject the whole turn.  read_file has hex-dumped
            binary for exactly this reason since the beginning; search never
            checked, so a binary file whose name happened to pass the glob
            could take down the conversation. }
          if not IsValidUtf8(LText) then Continue;
          { The whole-file prefilter is what makes a substring search over a
            big tree cheap.  A regex has no cheap literal to prefilter on, so
            that path pays per line - bounded by the step budget instead. }
          if not UseRegex then
          begin
            if CaseSensitive then
            begin
              if Pos(Needle, LText) = 0 then Continue;
            end
            else if Pos(Needle, LowerCase(LText)) = 0 then Continue;
          end;
          L := TStringList.Create;
          try
            L.Text := LText;
            for I := 0 to L.Count - 1 do
            begin
              Line := L[I];
              if LineHit(Line) then
              begin
                Result := Result + Format('%s:%d: %s'#10,
                  [Rel(IncludeTrailingPathDelimiter(Dir) + R.Name), I + 1, Trim(Line)]);
                Inc(Hits);
                if Hits >= 200 then Break;
              end;
              if Truncated then Break;
            end;
          finally
            L.Free;
          end;
        end;
      until (FindNext(R) <> 0) or (Hits >= 200) or Truncated;
      SysUtils.FindClose(R);
    end;
  end;

begin
  Result := '';
  Err := '';
  Hits := 0;
  Truncated := False;
  Rx := nil;
  if CaseSensitive then Needle := Pattern else Needle := LowerCase(Pattern);
  if UseRegex and not TRegex.Compile(Pattern, CaseSensitive, Rx, Err) then
    Exit('');
  try
    { One budget for the whole call rather than one per line, so a hostile
      pattern cannot spend its allowance again on every file in the tree. }
    if Rx <> nil then Rx.Budget := DefaultRegexBudget;
    RootPrefix := IncludeTrailingPathDelimiter(NormalizeRoot);
    Walk(Root, 0);
  finally
    Rx.Free;
  end;
  { Partial hits are still worth having, so this is a note rather than an
    error - but the model has to be told the answer is incomplete. }
  if Truncated then
    Result := Result + '[search stopped: pattern too expensive]'#10;
  if Trim(Result) = '' then
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

function RunShellQuiet(const Cmd: string; out ExitCode: Integer): string;
begin
  Result := RunShell(Cmd, NormalizeRoot, ExitCode);
  if not IsValidUtf8(Result) then
    Result := OemToUtf8(Result);
end;

{ ---------------------------------------------------------- bash prefixes -- }

var
  BashPrefixes: array of string;

{ The first token, lowercased, stripped of a path and an .exe suffix - so
  "git status" and "C:\Program Files\Git\git.exe log" share the prefix
  "git".  An "always" answer covers the program, not the arguments: the
  user who approved "git status" forever meant git, not status.

  Compound commands are deliberately not split: "git status && del *" has
  the prefix "git" only as its first program, and cmd.exe runs the rest
  regardless, so the whole line must carry the strictest reading.  The &,
  |, ; separators therefore poison the prefix - such a command never
  matches a stored prefix and is always asked about. }
function BashPrefix(const Cmd: string): string;
var
  S: string;
  I: Integer;
begin
  Result := '';
  S := Trim(Cmd);
  if S = '' then Exit;
  { A chained command is asked about every time; see above. }
  for I := 1 to Length(S) do
    if S[I] in ['&', '|', ';', '<', '>', '%', '^'] then Exit;
  { A quoted program name runs to the closing quote, spaces included;
    otherwise the first space ends it. }
  if S[1] = '"' then
  begin
    I := Pos('"', S, 2);
    if I = 0 then Exit;   { an unclosed quote is not worth guessing about }
    S := Copy(S, 2, I - 2);
  end
  else
  begin
    I := Pos(' ', S);
    if I > 0 then S := Copy(S, 1, I - 1);
  end;
  S := ExtractFileName(S);
  if LowerCase(ExtractFileExt(S)) = '.exe' then
    S := ChangeFileExt(S, '');
  Result := LowerCase(S);
end;

function BashPrefixAllowed(const Cmd: string): Boolean;
var
  P: string;
  I: Integer;
begin
  Result := False;
  P := BashPrefix(Cmd);
  if P = '' then Exit;
  for I := 0 to High(BashPrefixes) do
    if BashPrefixes[I] = P then Exit(True);
end;

procedure AllowBashPrefix(const Cmd: string);
var
  P: string;
begin
  P := BashPrefix(Cmd);
  if P = '' then Exit;
  if BashPrefixAllowed(Cmd) then Exit;
  SetLength(BashPrefixes, Length(BashPrefixes) + 1);
  BashPrefixes[High(BashPrefixes)] := P;
end;

procedure ClearBashPrefixes;
begin
  SetLength(BashPrefixes, 0);
end;

{ ---------------------------------------------------------- changed files -- }

var
  ChangedList: array of string;

function ChangedFiles: TStringArray;
var
  I: Integer;
begin
  SetLength(Result, Length(ChangedList));
  for I := 0 to High(ChangedList) do
    Result[I] := ChangedList[I];
end;

procedure NoteChangedFile(const RelPath: string);
var
  I: Integer;
begin
  if RelPath = '' then Exit;
  for I := 0 to High(ChangedList) do
    if CompareText(ChangedList[I], RelPath) = 0 then Exit;
  SetLength(ChangedList, Length(ChangedList) + 1);
  ChangedList[High(ChangedList)] := RelPath;
end;

procedure ClearChangedFiles;
begin
  SetLength(ChangedList, 0);
end;

{ ------------------------------------------------------------------ todos -- }

var
  TodoList: array of string;

function CurrentTodos: TStringArray;
var
  I: Integer;
begin
  SetLength(Result, Length(TodoList));
  for I := 0 to High(TodoList) do
    Result[I] := TodoList[I];
end;

procedure ClearTodos;
begin
  SetLength(TodoList, 0);
end;

{ -------------------------------------------------------------- snapshots -- }

type
  TSnapshot = record
    Turn: Integer;
    Full: string;        { absolute path }
    Existed: Boolean;    { False: the file was created, restore = delete }
    Text: string;        { prior contents when Existed }
  end;

var
  Snapshots: array of TSnapshot;
  CurrentTurn: Integer = 0;

procedure BeginTurn(TurnNo: Integer);
begin
  CurrentTurn := TurnNo;
end;

procedure ClearSnapshots;
begin
  SetLength(Snapshots, 0);
end;

function SnapshotCount: Integer;
begin
  Result := Length(Snapshots);
end;

{ Captures Full's state before its first change this turn.  Later changes in
  the same turn keep the first snapshot: rewinding lands at the turn start,
  not midway through it.  Snapshot bytes live in memory; a 400 KB cap keeps
  a huge generated file from bloating the process, at the cost of that file
  not being rewindable - noted at restore time. }
procedure SnapshotFile(const Full: string);
var
  I: Integer;
  S: TSnapshot;
  F: TFileStream;
begin
  { One snapshot per file per turn.  Earlier turns keep theirs: a file
    touched in turn 2 and again in turn 5 must be restorable to either. }
  for I := 0 to High(Snapshots) do
    if (Snapshots[I].Turn = CurrentTurn) and
       (CompareText(Snapshots[I].Full, Full) = 0) then Exit;

  S.Turn := CurrentTurn;
  S.Full := Full;
  S.Existed := FileExists(Full);
  S.Text := '';
  if S.Existed then
  begin
    try
      F := TFileStream.Create(Full, fmOpenRead or fmShareDenyNone);
      try
        if F.Size > MaxReadBytes then Exit;   { too big to hold; not rewindable }
        SetLength(S.Text, F.Size);
        if F.Size > 0 then F.ReadBuffer(S.Text[1], F.Size);
      finally
        F.Free;
      end;
    except
      Exit;   { unreadable now means unrestorable later; skip }
    end;
  end;
  SetLength(Snapshots, Length(Snapshots) + 1);
  Snapshots[High(Snapshots)] := S;
end;

function RestoreFilesSince(TurnNo: Integer; out Notes: string): Integer;
var
  I, Kept: Integer;
  Err: string;
begin
  Result := 0;
  Notes := '';
  { Newest first, so when a file has snapshots in several turns at or after
    TurnNo, the oldest one writes last and wins - the state the file had
    when TurnNo began. }
  for I := High(Snapshots) downto 0 do
  begin
    if Snapshots[I].Turn < TurnNo then Continue;
    if Snapshots[I].Existed then
    begin
      if SaveFileText(Snapshots[I].Full, Snapshots[I].Text, Err) then
      begin
        Inc(Result);
        Notes := Notes + 'restored ' + Rel(Snapshots[I].Full) + #10;
      end
      else
        Notes := Notes + 'could not restore ' + Rel(Snapshots[I].Full) +
          ': ' + Err + #10;
    end
    else
    begin
      if not FileExists(Snapshots[I].Full) or
         SysUtils.DeleteFile(Snapshots[I].Full) then
      begin
        Inc(Result);
        Notes := Notes + 'removed ' + Rel(Snapshots[I].Full) +
          ' (created that turn)'#10;
      end
      else
        Notes := Notes + 'could not remove ' + Rel(Snapshots[I].Full) + #10;
    end;
  end;

  { Forget what was restored; earlier turns keep their snapshots so a
    second, deeper rewind still works. }
  Kept := 0;
  for I := 0 to High(Snapshots) do
    if Snapshots[I].Turn < TurnNo then
    begin
      Snapshots[Kept] := Snapshots[I];
      Inc(Kept);
    end;
  SetLength(Snapshots, Kept);
end;

{ ------------------------------------------------- permission persistence -- }

{ The file is JSON: {"allow_edits":bool,"allow_bash":bool,"allow_fetch":bool,
  "bash_programs":["git","build",...]}.  Deliberately not the transcript
  format and deliberately tiny - it is user-editable state, and someone
  deleting a line from it must be able to predict what that does. }
procedure LoadPermissions(const Path: string);
var
  F: TFileStream;
  Text: string;
  Root, Progs: TJson;
  I: Integer;
begin
  if not FileExists(Path) then Exit;
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Text, F.Size);
      if F.Size > 0 then F.ReadBuffer(Text[1], F.Size);
    finally
      F.Free;
    end;
  except
    Exit;
  end;
  Root := JsonParse(Text);
  if Root = nil then Exit;
  try
    { Approvals only widen from the file, never narrow: a session that
      already granted something keeps it regardless of what is on disk. }
    if Root.Bool('allow_edits') then AllowAllEdits := True;
    if Root.Bool('allow_bash') then AllowAllBash := True;
    if Root.Bool('allow_fetch') then AllowAllFetch := True;
    Progs := Root.Find('bash_programs');
    if (Progs <> nil) and (Progs.Kind = jkArr) then
      for I := 0 to Progs.Count - 1 do
        AllowBashPrefix(Progs.Item(I).AsString);
  finally
    Root.Free;
  end;
end;

procedure SavePermissions(const Path: string);
var
  Root, Progs: TJson;
  Text: string;
  F: TFileStream;
  I: Integer;
begin
  Root := TJson.NewObj;
  try
    Root.AddBool('allow_edits', AllowAllEdits);
    Root.AddBool('allow_bash', AllowAllBash);
    Root.AddBool('allow_fetch', AllowAllFetch);
    Progs := TJson.NewArr;
    for I := 0 to High(BashPrefixes) do
      Progs.Push(TJson.NewStr(BashPrefixes[I]));
    Root.Add('bash_programs', Progs);
    Text := Root.ToJson;
  finally
    Root.Free;
  end;
  try
    F := TFileStream.Create(Path, fmCreate);
    try
      if Text <> '' then F.WriteBuffer(Text[1], Length(Text));
    finally
      F.Free;
    end;
  except
    { Nothing: persistence is a convenience. }
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
    'Read a text file. Output is line-numbered so you can cite line numbers. ' +
    'A .ipynb file comes back instead as numbered notebook cells, with each ' +
    'output summarised by type and size rather than dumped.',
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
  P.Add('edits', TJson.NewObj);
  with P.Find('edits') do
  begin
    AddStr('type', 'array');
    AddStr('description', 'Several replacements applied together: each item ' +
      'is {old_text, new_text}. Use this instead of separate calls when one ' +
      'change spans several places in the file. All must match, or none are ' +
      'applied.');
  end;
  Result.Push(MakeTool('edit_file',
    'Replace exact snippets in a file: one via old_text/new_text, or several ' +
    'at once via edits. Prefer this over write_file for changes to existing ' +
    'files. Requires user approval.',
    P, ['path']));

  P := TJson.NewObj;
  P.Add('path', StrProp('Directory, relative to the session root. Default ".".'));
  P.Add('recursive', BoolProp('Descend into subdirectories (depth 4 unless ' +
    'depth is given).'));
  { Hand-built, like the edits and todos arrays: there is no IntProp helper,
    and one more of those for two call sites earns less than it costs. }
  P.Add('depth', TJson.NewObj);
  with P.Find('depth') do
  begin
    AddStr('type', 'integer');
    AddStr('description', 'How many levels to descend, 1-12. Overrides ' +
      'recursive. Default 4 when recursive, 0 otherwise.');
  end;
  Result.Push(MakeTool('list_dir', 'List a directory.', P, []));

  P := TJson.NewObj;
  P.Add('pattern', StrProp('Text to find. A case-insensitive substring ' +
    'unless regex is true.'));
  P.Add('glob', StrProp('Optional filename filter, e.g. ".pas" or "test".'));
  P.Add('regex', BoolProp('Treat pattern as a regular expression: . * + ? ' +
    'repeat counts, [a-z], \d \w \s \b ^ $ | and (groups). ASCII byte ' +
    'semantics; no backreferences or lookaround.'));
  P.Add('case_sensitive', BoolProp('Match case exactly. Default false.'));
  P.Add('depth', TJson.NewObj);
  with P.Find('depth') do
  begin
    AddStr('type', 'integer');
    AddStr('description', 'How many directory levels to search, 1-12. ' +
      'Default 8.');
  end;
  Result.Push(MakeTool('search',
    'Search file contents under the session root. Returns path:line: text. ' +
    'Set regex for pattern syntax.',
    P, ['pattern']));

  P := TJson.NewObj;
  P.Add('command', StrProp('Command line, run through cmd.exe /C.'));
  Result.Push(MakeTool('bash',
    'Run a shell command in the session root and return its output. ' +
    'Use it to build, run tests, or inspect the system. Requires user approval.',
    P, ['command']));

  P := TJson.NewObj;
  P.Add('url', StrProp('The https:// URL to fetch.'));
  Result.Push(MakeTool('fetch',
    'Fetch a URL over HTTPS and return the response body as text. ' +
    'Use it to read documentation, APIs, or reference pages. ' +
    'Requires user approval.',
    P, ['url']));

  P := TJson.NewObj;
  P.Add('todos', TJson.NewObj);
  with P.Find('todos') do
  begin
    AddStr('type', 'array');
    AddStr('description', 'The full task list, replacing the previous one. ' +
      'Each item: {"content": string, "status": "pending"|"in_progress"|' +
      '"completed"}. Keep at most one item in_progress.');
  end;
  Result.Push(MakeTool('todo_write',
    'Maintain a visible task list for multi-step work. Call it when ' +
    'starting a task with several steps, and again as each step starts and ' +
    'finishes, so the user can follow the plan. Send the whole list each ' +
    'time.',
    P, ['todos']));

  P := TJson.NewObj;
  P.Add('path', StrProp('Notebook path (.ipynb), relative to the session root.'));
  P.Add('cell', TJson.NewObj);
  with P.Find('cell') do
  begin
    AddStr('type', 'integer');
    AddStr('description', 'The 0-based cell number read_file showed. For ' +
      'insert, the index the new cell takes.');
  end;
  P.Add('edit_mode', StrProp('One of "replace", "insert" or "delete".'));
  P.Add('source', StrProp('The cell''s new source, as plain text. Required ' +
    'by replace and insert.'));
  P.Add('cell_type', StrProp('"code", "markdown" or "raw" for insert. ' +
    'Default "code".'));
  Result.Push(MakeTool('notebook_edit',
    'Replace, insert or delete one cell of a Jupyter notebook. Use this ' +
    'rather than edit_file for .ipynb files: edit_file works on the file''s ' +
    'JSON text, while this works on the cells read_file shows you. Outputs ' +
    'and execution counts of the cell survive a replace. Requires user ' +
    'approval, like any other file change.',
    P, ['path', 'cell', 'edit_mode']));
end;

{ --------------------------------------------------------------- execution -- }

{ The effective walk depth for a tool call.  The value arrives as a Double, so
  it is range-checked before it is rounded: Round(1e300) raises, and a model
  can send anything.  A silly depth clamps rather than failing the call - a
  clamp is a more useful answer than a refused tool. }
function WalkDepth(Input: TJson; DefaultDepth: Integer): Integer;
var
  D: Double;
begin
  if (Input = nil) or (Input.Find('depth') = nil) then Exit(DefaultDepth);
  D := Input.Num('depth', DefaultDepth);
  if D >= MaxWalkDepth then Exit(MaxWalkDepth);
  { Written as a positive test so a NaN lands here rather than in Round. }
  if not (D > 1) then Exit(1);
  Result := Round(D);
end;

{ The cell argument of notebook_edit, as an Integer that cannot raise.  Models
  do send "2" for an integer field, so a string that parses is accepted; a
  value too large to round is clamped to something NotebookApply will refuse
  by name rather than crashing on the way in.  -1 means "not supplied", which
  is out of range for every mode and so reports itself. }
function CellIndex(Input: TJson): Integer;
var
  V: TJson;
  D: Double;
  N: Int64;
begin
  Result := -1;
  if Input = nil then Exit;
  V := Input.Find('cell');
  if V = nil then Exit;
  if V.Kind = jkStr then
  begin
    if TryStrToInt64(Trim(V.AsString), N) then
    begin
      if N > MaxInt then Exit(MaxInt);
      if N < -MaxInt then Exit(-MaxInt);
      Result := N;
    end;
    Exit;
  end;
  if V.Kind <> jkNum then Exit;
  D := V.AsNumber;
  if D >= MaxInt then Exit(MaxInt);
  { Written as a positive test so a NaN lands here, not in Round. }
  if not (D > -MaxInt) then Exit(-MaxInt);
  Result := Round(D);
end;

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
  begin
    Result := 'list ' + Input.Str('path', '.');
    if Input.Find('depth') <> nil then
      Result := Result + Format(' (depth %d)', [WalkDepth(Input, 0)]);
  end
  { Which engine ran is worth a character in the transcript: /pat/ and "pat"
    mean different searches, and a user reading the log should not have to
    guess which one the model asked for. }
  else if Name = 'search' then
  begin
    if Input.Bool('regex') then
      Result := Format('search /%s/', [Input.Str('pattern')])
    else
      Result := Format('search "%s"', [Input.Str('pattern')]);
  end
  else if Name = 'bash' then
  begin
    S := Input.Str('command');
    if Length(S) > 120 then S := Copy(S, 1, 117) + '...';
    Result := '$ ' + S;
  end
  else if Name = 'fetch' then
    Result := 'fetch ' + Input.Str('url')
  { Both the mode and the cell number, because they are the whole of what the
    user is being asked to approve: "delete cell 3" and "replace cell 3" are
    very different answers to the same prompt title. }
  else if Name = 'notebook_edit' then
    Result := Format('%s cell %d of %s',
      [Input.Str('edit_mode', '?'), CellIndex(Input), Input.Str('path')])
  else if Name = 'todo_write' then
  begin
    if (Input.Find('todos') <> nil) then
      Result := Format('update todos (%d items)', [Input.Find('todos').Count])
    else
      Result := 'update todos';
  end
  else
    Result := Name;
end;

{ Applies the edit(s) described by Input to Text in place.  One hunk comes as
  old_text/new_text, several as an edits array; the two can combine.  Every
  hunk is checked - present, unambiguous - before any is applied: an edit
  that half-lands leaves a file that neither the user nor the model expected
  to exist.  Later hunks match against the text as earlier ones changed it,
  in array order. }
function ApplyEdits(Input: TJson; var Text: string; const RelName: string;
  out Err: string): Boolean;
var
  Edits: TJson;
  I, At, Second, Count: Integer;
  Old, New, Work: string;

  function OneHunk(const O, N: string; Which: Integer): Boolean;
  begin
    Result := False;
    if O = '' then
    begin
      Err := Format('edit %d: old_text must not be empty', [Which]);
      Exit;
    end;
    At := Pos(O, Work);
    if At = 0 then
    begin
      Err := Format('edit %d: old_text was not found in %s', [Which, RelName]);
      Exit;
    end;
    Second := Pos(O, Work, At + 1);
    if Second > 0 then
    begin
      Err := Format('edit %d: old_text occurs more than once; include more context',
        [Which]);
      Exit;
    end;
    Work := Copy(Work, 1, At - 1) + N + Copy(Work, At + Length(O), MaxInt);
    Result := True;
  end;

begin
  Result := False;
  Err := '';
  Work := Text;
  Count := 0;

  { The single-hunk form, when present, runs first. }
  Old := Input.Str('old_text');
  New := Input.Str('new_text');
  if Old <> '' then
  begin
    if not OneHunk(Old, New, 1) then Exit;
    Inc(Count);
  end;

  Edits := Input.Find('edits');
  if (Edits <> nil) and (Edits.Kind = jkArr) then
    for I := 0 to Edits.Count - 1 do
    begin
      if not OneHunk(Edits.Item(I).Str('old_text'),
                     Edits.Item(I).Str('new_text'), Count + 1) then Exit;
      Inc(Count);
    end;

  if Count = 0 then
  begin
    Err := 'no edits given: supply old_text/new_text or an edits array';
    Exit;
  end;
  Text := Work;
  Result := True;
end;

{ Asks the user, honouring any standing "always" answer for this tool class. }
function Permit(const Name, Detail: string; Ask: TAskProc): Boolean;
var
  IsBash, IsFetch: Boolean;
  A: TPermission;
begin
  IsBash := Name = 'bash';
  IsFetch := Name = 'fetch';
  if IsBash and AllowAllBash then Exit(True);
  if IsFetch and AllowAllFetch then Exit(True);
  if (not IsBash) and (not IsFetch) and AllowAllEdits then Exit(True);
  if Ask = nil then Exit(False);

  A := Ask(Name, Detail);
  case A of
    pmAllowOnce: Result := True;
    pmAllowAlways:
      begin
        if IsBash then AllowAllBash := True
        else if IsFetch then AllowAllFetch := True
        else AllowAllEdits := True;
        Result := True;
      end;
  else
    Result := False;
  end;
end;

{ The bash gate.  "Always" for a shell command approves its program, not
  every future command: the user who said always to "git status" meant git,
  and quietly extending that to "del /s" is how trust gets spent.  /yolo
  still approves everything through AllowAllBash. }
function PermitBash(const Cmd, Detail: string; Ask: TAskProc): Boolean;
var
  A: TPermission;
  P: string;
begin
  if AllowAllBash then Exit(True);
  if BashPrefixAllowed(Cmd) then Exit(True);
  if Ask = nil then Exit(False);

  P := BashPrefix(Cmd);
  A := Ask('bash', Detail);
  case A of
    pmAllowOnce: Result := True;
    pmAllowAlways:
      begin
        { A chained command has no prefix; "always" for one degrades to
          this-once, since there is nothing safe to remember it by -
          silently widening to all commands would spend trust the user
          never gave. }
        if P <> '' then AllowBashPrefix(Cmd);
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
  Full, Err, Text, Note, Updated, OldView, NewView, Canon: string;
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
    { The same application the execution path uses, so the preview is the
      change that will actually happen - including every hunk of a multi-edit.
      An edit that would be refused previews as nothing, and the refusal
      carries the reason. }
    Updated := Text;
    if not ApplyEdits(Input, Updated, Rel(Full), Err) then Exit;
    Result := DiffSummary(Text, Updated, PreviewLines);
  end

  else if Name = 'notebook_edit' then
  begin
    if not SafePath(Input.Str('path'), Full, Err) then Exit;
    if not FileExists(Full) then Exit;
    if not LoadFileLimited(Full, MaxNotebookBytes, Text, Note) then Exit;
    if not IsValidUtf8(Text) then Exit;
    { The same NotebookApply the execution path runs, so preview and result
      cannot diverge; an edit that would be refused previews as nothing, the
      way a refused edit_file does. }
    if not NotebookApply(Text, CellIndex(Input), Input.Str('edit_mode'),
                         Input.Str('source'), Input.Str('cell_type'),
                         Updated, Err) then Exit;
    { The diff is over the cell view, not the file bytes: the user approves
      the change in the same terms the model proposed it, and base64 output
      data cannot reach the prompt by that route. }
    if not NotebookView(Text, OldView, Err) then Exit;
    if not NotebookView(Updated, NewView, Err) then Exit;
    { What the cell diff cannot show is that the rest of the file is about to
      be rewritten in Jupyter's layout.  That is a real, one-time cost to
      someone's git history, so it is said out loud rather than discovered. }
    if NotebookCanonical(Text, Canon, Err) and (Canon <> Text) then
      Result := '(the file will be rewritten in Jupyter''s standard ' +
        'formatting)'#10;
    Result := Result + DiffSummary(OldView, NewView, PreviewLines);
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
  Full, Err, Text, Cmd, Note, Updated: string;
  Code: Integer;
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
    { A notebook is decoded into cells before anything else, because the model
      reaches for read_file by reflex: a separate notebook_read tool would be
      discovered only after four megabytes of base64 had already landed in the
      context, and that is not a mistake anything can undo.  Anything that
      fails here - too big, not UTF-8, not a v4 notebook - falls through to the
      ordinary text path, so a damaged notebook is still visible and fixable. }
    if IsNotebookPath(Full) then
    begin
      if LoadFileLimited(Full, MaxNotebookBytes, Text, Note) and (Note = '') and
         IsValidUtf8(Text) and NotebookView(Text, Cmd, Err) then
        Exit(Clip(Cmd));
      Note := '(this .ipynb did not read as a notebook; showing the raw file)';
    end
    else
      Note := '';
    if not LoadFileText(Full, Text, Err) then
    begin
      IsError := True;
      Exit('cannot read: ' + Err);
    end;
    { Both notes can apply at once - a notebook too big to parse is also a
      file too big to show whole - so the truncation note joins rather than
      replaces the one explaining why the cells are missing. }
    if Err <> '' then
      if Note = '' then Note := Err else Note := Note + ' ' + Err;
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
    SnapshotFile(Full);
    if not SaveFileText(Full, Input.Str('content'), Err) then
    begin
      IsError := True;
      Exit('cannot write: ' + Err);
    end;
    NoteChangedFile(Rel(Full));
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
    { One hunk through old_text/new_text, several through edits.  Every hunk
      is validated against the file before any is applied, so a failure in
      the third leaves the first two unapplied rather than half-editing. }
    if not ApplyEdits(Input, Text, Rel(Full), Err) then
    begin
      IsError := True;
      Exit(Err);
    end;
    if not PermitChange(Name, Input, Ask) then
    begin
      IsError := True;
      Exit('the user denied this edit');
    end;
    SnapshotFile(Full);
    if not SaveFileText(Full, Text, Err) then
    begin
      IsError := True;
      Exit('cannot write: ' + Err);
    end;
    NoteChangedFile(Rel(Full));
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
    { An explicit depth wins; otherwise recursive still means the old 4. }
    if Input.Bool('recursive') then Code := 4 else Code := 0;
    Result := Clip(ListDir(Full, WalkDepth(Input, Code)));
  end

  else if Name = 'search' then
  begin
    { No permission call: search reads and reports, so it stays ungated and
      nothing new joins the edits class. }
    Text := GrepTree(NormalizeRoot, Input.Str('pattern'), Input.Str('glob'),
      Input.Bool('regex'), Input.Bool('case_sensitive'),
      WalkDepth(Input, 8), Err);
    if Err <> '' then
    begin
      IsError := True;
      Exit('invalid regex: ' + Err);
    end;
    Result := Clip(Text);
  end

  else if Name = 'bash' then
  begin
    Cmd := Input.Str('command');
    if Trim(Cmd) = '' then
    begin
      IsError := True;
      Exit('command is required');
    end;
    if not PermitBash(Cmd, DescribeTool(Name, Input), Ask) then
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

  else if Name = 'fetch' then
  begin
    Text := Input.Str('url');
    if Copy(Text, 1, 8) <> 'https://' then
    begin
      IsError := True;
      Exit('only https:// URLs can be fetched: ' + Text);
    end;
    if not Permit(Name, DescribeTool(Name, Input), Ask) then
    begin
      IsError := True;
      Exit('the user denied this fetch');
    end;
    with HttpGet(Text, 'accept: text/html, application/json, text/plain'#13#10 +
      'user-agent: pasclaude/0.1', MaxFetchBytes) do
    begin
      if not Ok then
      begin
        IsError := True;
        if Body <> '' then
          Exit(Error + #10 + Clip(Body))
        else
          Exit(Error);
      end;
      Text := Body;
    end;
    { The body is whatever the server sent; anything not valid UTF-8 is
      scrubbed rather than hex-dumped, because a page in another encoding is
      still mostly readable text, unlike a binary file. }
    if not IsValidUtf8(Text) then
      Text := OemToUtf8(Text);
    if Text = '' then Text := '(empty response)';
    Result := Clip(Text);
  end

  else if Name = 'todo_write' then
  begin
    { No permission gate: the list is display state, it touches nothing.
      The whole list replaces the previous one, which spares the model a
      diff protocol and the code a merge. }
    with Input do
    begin
      if (Find('todos') = nil) or (Find('todos').Kind <> jkArr) then
      begin
        IsError := True;
        Exit('todos must be an array');
      end;
      SetLength(TodoList, Find('todos').Count);
      for Code := 0 to Find('todos').Count - 1 do
      begin
        Text := Find('todos').Item(Code).Str('status');
        if Text = 'completed' then
          TodoList[Code] := '[x] '
        else if Text = 'in_progress' then
          TodoList[Code] := '[~] '
        else
          TodoList[Code] := '[ ] ';
        TodoList[Code] := TodoList[Code] +
          Find('todos').Item(Code).Str('content');
      end;
    end;
    Result := Format('todo list updated (%d items)', [Length(TodoList)]);
  end

  { A separate tool rather than an extension of edit_file, because edit_file's
    contract is substring replacement on the file's TEXT - and a notebook's
    text is JSON.  Overloading it would make old_text mean something different
    depending on the extension: the model, having read decoded cells, would
    send print(x) while the file holds "print(x)\n" inside a JSON array.
    Insert and delete of a cell have no expression in that schema at all.  A
    model that reaches for edit_file here gets "old_text was not found", which
    is a clean, self-correcting error. }
  else if Name = 'notebook_edit' then
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
    if not IsNotebookPath(Full) then
    begin
      IsError := True;
      Exit('not a notebook: ' + Rel(Full) + ' - use edit_file for ordinary files');
    end;
    if not LoadFileLimited(Full, MaxNotebookBytes, Text, Note) then
    begin
      IsError := True;
      Exit('cannot read: ' + Note);
    end;
    { A truncated read must never be written back: the result would be a
      valid document that had silently lost everything past the cut. }
    if Note <> '' then
    begin
      IsError := True;
      Exit('notebook is too large to edit safely ' + Note);
    end;
    if not IsValidUtf8(Text) then
    begin
      IsError := True;
      Exit(Rel(Full) + ' is not UTF-8 text and cannot be parsed as a notebook');
    end;
    if (Input.Str('edit_mode') <> 'delete') and (Input.Find('source') = nil) then
    begin
      IsError := True;
      Exit('source is required for edit_mode ' + Input.Str('edit_mode', '(none)'));
    end;
    { Transformed before the user is asked, exactly as edit_file validates its
      hunks first: a bad cell index or an unknown mode should never reach a
      prompt. }
    if not NotebookApply(Text, CellIndex(Input), Input.Str('edit_mode'),
                         Input.Str('source'), Input.Str('cell_type'),
                         Updated, Err) then
    begin
      IsError := True;
      Exit(Err);
    end;
    if not PermitChange(Name, Input, Ask) then
    begin
      IsError := True;
      Exit('the user denied this notebook edit');
    end;
    SnapshotFile(Full);
    if not SaveFileText(Full, Updated, Err) then
    begin
      IsError := True;
      Exit('cannot write: ' + Err);
    end;
    NoteChangedFile(Rel(Full));
    Result := Format('%s cell %d of %s',
      [Input.Str('edit_mode'), CellIndex(Input), Rel(Full)]);
  end

  else
  begin
    IsError := True;
    Result := 'unknown tool: ' + Name;
  end;
end;

end.
