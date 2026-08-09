{ uDiag - what is true, what is wrong, and a file a maintainer can read.

  Three commands live here and they are one thing seen three ways: /status is
  the report with no judgement, /doctor is the judgement, /bug is both of them
  written to disk.  They share TStatusReport and TDiagReport for a reason that
  hand-written bug templates always get wrong: a report assembled separately
  from the status view drifts from it, and the drift is discovered by a
  maintainer reading a bug report that contradicts what the user saw.

  It is a unit rather than three procedures in pasclaude.lpr because a
  diagnostic that lives in the .lpr cannot be tested.  No suite can link the
  program, so every check, every level and every remedy would be verified by
  running the executable and reading it with human eyes - which is exactly the
  code path a user reaches when everything else has already gone wrong.  Here
  the builders are ordinary functions over in-memory state, the renderers are
  pure functions of their records, and the host's whole job is three lines:
  fill DiagFacts, record a note where it already prints a yellow one, and
  print what comes back.

  The note ledger rather than re-reading configuration is the load-bearing
  choice, and it is about safety, not speed.  Re-reading is how a diagnostic
  becomes destructive: uTools.LoadMcpConfig calls ClearMcpServers as its first
  statement, so re-invoking it tears down every live server connection even
  when .mcp.json has since vanished; uTools.RefreshSkills throws the cache
  away; uHooks.LoadHooks would re-ask a trust question the user already
  answered.  Replaying what startup observed is cheaper AND more honest: it
  reports the configuration this session is actually running on, not the one
  on disk now, and those two differ precisely when the user is confused enough
  to be typing /doctor.

  Nothing here prints, and nothing here uses uTerm - the ladder forbids it at
  this level, which is also what makes the renderers testable.  Nothing here
  raises past a builder either: each check runs inside its own try/except and
  a check that fails becomes a warning saying so, because a health check that
  crashes on the machine whose disk is the problem has answered nothing. }
unit uDiag;

{$mode objfpc}{$H+}
{ Nested procedure variables, for one reason: every check in DiagBuildDoctor
  is a nested procedure closing over the builder's Result, and they are run
  through one Guard that turns an exception into a warning naming the check.
  Thirteen hand-written try/except blocks would be the alternative, and the
  fourteenth would be the one somebody forgot. }
{$modeswitch nestedprocvars}

interface

uses SysUtils, Windows, DateUtils, uJson, uHttp, uHooks, uSandbox, uIde,
  uTools, uAgent;

type
  { ok / warning / problem / skipped.  dlSkipped is NOT a failure: it means
    the check was not run, or the fact it needs was never probed.  The exit
    code and DiagWorstLevel both treat it as ok, which is why the ordinal
    order cannot be used as a severity ranking - see DiagLevelRank. }
  TDiagLevel = (dlOk, dlWarn, dlProblem, dlSkipped);

  { What a check costs to run.  Printed beside the check, because a health
    check that quietly spends money or spawns a program is the thing this
    codebase refuses everywhere else. }
  TDiagCost = (dcNone, dcDisk, dcNetwork);

  TDiagCheck = record
    { Stable lowercase_underscore key.  This is simultaneously the JSON key a
      driver depends on and the name a remedy can refer to, so it is part of
      the contract and must not be renamed for cosmetic reasons. }
    Id: string;
    Title: string;
    Detail: string;
    { Every non-ok, non-skipped check must carry one.  A check that says
      "problem" without saying what to do is a riddle, and the builder
      asserts it rather than trusting the author to remember. }
    Remedy: string;
    Level: TDiagLevel;
    Cost: TDiagCost;
  end;
  TDiagReport = array of TDiagCheck;

  TStatusItem = record
    Id: string;
    Caption: string;
    Value: string;
    { Sub-lines.  When IsList is set the JSON value is an ARRAY of these -
      empty array included - rather than the Value string.  A field rather
      than "array when Extra is non-empty", because a driver that has to ask
      whether added_roots came back as a string or a list this time has no
      contract at all. }
    Extra: TStringArray;
    IsList: Boolean;
  end;
  TStatusReport = array of TStatusItem;

  { Everything the host knows and this unit cannot: the console, the
    credential, the keybinding file, whether this run is scripted.  One
    record var rather than a dozen callbacks - the uHttp.HttpTransport
    pattern in record form: the shipped program fills it in one block at
    startup, a suite assigns it directly and needs no console at all.

    A zeroed field reports dlSkipped "not probed" and NEVER a green tick.
    That distinction is the whole value of the record: a status view that
    invents a healthy answer for something nobody measured is worse than one
    that admits it did not look.

    The credential itself is deliberately absent.  Only the source word, the
    two booleans and the expiry are here, so /bug cannot leak a token even if
    every redactor failed - the value is not in the data structure. }
  TDiagFacts = record
    Version: string;
    AuthSource: string;        { 'env', 'claude_code', 'stored', ... }
    AuthDetail: string;        { the human phrase, never the token }
    ModelSource: string;       { where the model name came from }
    ModelRouting: string;      { subagent/compaction routing, when non-default }
    AuthPresent: Boolean;
    AuthIsOauth: Boolean;
    HasConsole: Boolean;
    VtActive: Boolean;
    StdinIsConsole: Boolean;
    VimOn: Boolean;
    Scripted: Boolean;         { -p, or any non-text output format }
    SettingsSupported: Boolean;
    AuthExpiresAtMs: Int64;
    ConsoleOutCp, ConsoleInCp: Cardinal;
    KeysPath, HistoryPath, SessionFilePath, PermissionsPath: string;
    SettingsSummary: TStringArray;   { uSettings.SettingsReport rows }
    SettingsRefused: TStringArray;   { uSettings.SettingsRefusals }
    TelemetrySummary: string;        { one line, or '' when off }
    { '' = nobody probed, 'on' / 'off' = what ide.enabled resolved to.  A
      string rather than a Boolean precisely so the zeroed record can say
      "not probed": a Boolean would have to be False, and False here reads
      as "the user turned it off", which is a fact nobody established.
      Detection itself is only consulted when this is non-empty, so a report
      built from a zeroed record never claims to have found an editor. }
    IdeSetting: string;
    { The ide.command path, when one is set.  A path, beside KeysPath and
      PermissionsPath - and like them, never a credential of any kind. }
    IdeCommand: string;
  end;

  TBugOptions = record
    IncludeTranscript: Boolean;
    RealPaths: Boolean;
    AsJson: Boolean;
  end;

const
  { Per field, applied with uJson.Utf8Cut.  Hook commands, MCP server names
    and style names are project-authored: a hostile hooks.json must not be
    able to make the report unreadable or push the JSON payload over what a
    driver will accept. }
  DiagFieldBytes = 512;
  { Above this many files in the reports directory, /doctor mentions it.
    Nothing is ever deleted automatically - a program that silently removes
    the user's evidence is worse than one that accumulates files. }
  DiagReportsNoisyAt = 20;
  DiagProbeName = '.diag-probe';

var
  { Filled by pasclaude.lpr in one block, after everything it describes has
    been decided.  Zeroed here so a suite that assigns three fields gets
    dlSkipped for the rest rather than a fabricated green. }
  DiagFacts: TDiagFacts;
  { Test seam: where /bug writes.  '' means the real answer (LOCALAPPDATA,
    then USERPROFILE, then nowhere at all).  Never a path inside a root -
    see DiagReportsDir. }
  DiagReportsDirOverride: string = '';

{ ------------------------------------------------------------- the ledger -- }

{ Recorded at every site that already prints a one-shot yellow configuration
  warning at startup.  /doctor replays these instead of re-reading the files,
  which is what keeps it from calling LoadMcpConfig. }
procedure DiagNote(const Source: string; Level: TDiagLevel;
  const Detail, Remedy: string);
function  DiagNotes: TDiagReport;
procedure ClearDiagNotes;                                    { test seam }
procedure ClearDiagFacts;                                    { test seam }

{ --------------------------------------------------------------- builders -- }

function DiagBuildStatus(A: TAgent): TStatusReport;
function DiagBuildDoctor(A: TAgent; Online: Boolean): TDiagReport;
{ The worst level present, with dlSkipped ranked as ok.  Drives the exit
  code, so ranking a not-run check above a passing one would make
  "pasclaude --doctor || setup" fire on a check nobody asked for. }
function DiagWorstLevel(const R: TDiagReport): TDiagLevel;
function DiagLevelRank(L: TDiagLevel): Integer;

{ -------------------------------------------- renderers: no console, no IO -- }

function DiagStatusText(const R: TStatusReport): TStringArray;
function DiagDoctorText(const R: TDiagReport): TStringArray;
function DiagStatusJsonObj(const R: TStatusReport): TJson;   { caller frees }
function DiagDoctorJsonObj(const R: TDiagReport): TJson;     { caller frees }
function DiagStatusJson(const R: TStatusReport): string;
function DiagDoctorJson(const R: TDiagReport): string;
function DiagLevelName(L: TDiagLevel): string;      { ok|warning|problem|skipped }
function DiagCostName(C: TDiagCost): string;        { none|disk|network }

{ ---------------------------------------------------------- pure helpers --- }

{ Exported because the failures they prevent are silent ones: an unredacted
  token in a file the user then pastes into an issue, or a path that leaks a
  client's project name. }
function DiagRedactSecrets(const S: string): string;
function DiagRedactPaths(const S: string; const Roots: TStringArray;
  const Home, Local: string): string;
function DiagTokenExpiry(ExpiresAtMs, NowMs: Int64;
  out Detail: string): TDiagLevel;
function DiagOsVersion: string;
function DiagBuildInfo: string;
function DiagProbeWritable(const Dir: string; out Err: string): Boolean;
function DiagNowUnixMs: Int64;
{ Everything a renderer emits goes through here: control characters removed,
  then Utf8Cut to DiagFieldBytes. }
function DiagClean(const S: string): string;

{ -------------------------------------------------------------------- bug -- }

function DiagReportsDir: string;
function DiagBugText(A: TAgent; const Opts: TBugOptions;
  const Status: TStatusReport; const Doctor: TDiagReport): string;
function DiagBugJson(A: TAgent; const Opts: TBugOptions;
  const Status: TStatusReport; const Doctor: TDiagReport): string;
{ Writes the report.  Path is where it went; False with Err set and NOTHING
  written anywhere when there is no home directory to write to.  True with
  Err set and TranscriptPath empty is the transcript-only failure: the report
  is there, the conversation file is not, and the sentence says why.  There
  is no path on which TranscriptPath names a file that was not redacted. }
function DiagWriteBug(A: TAgent; const Opts: TBugOptions;
  out Path, TranscriptPath, Err: string): Boolean;

implementation

{ ---------------------------------------------------------------- ledger --- }

var
  Ledger: TDiagReport;

procedure DiagNote(const Source: string; Level: TDiagLevel;
  const Detail, Remedy: string);
var
  N: Integer;
begin
  { Bounded, because a startup that produced a thousand notes has a problem
    the thousand-and-first note will not explain. }
  if Length(Ledger) >= 200 then Exit;
  N := Length(Ledger);
  SetLength(Ledger, N + 1);
  Ledger[N].Id := Source;
  Ledger[N].Title := Source;
  Ledger[N].Detail := Detail;
  Ledger[N].Remedy := Remedy;
  Ledger[N].Level := Level;
  Ledger[N].Cost := dcNone;
end;

function DiagNotes: TDiagReport;
var
  I: Integer;
begin
  SetLength(Result, Length(Ledger));
  for I := 0 to High(Ledger) do Result[I] := Ledger[I];
end;

procedure ClearDiagNotes;
begin
  Ledger := nil;
end;

procedure ClearDiagFacts;
begin
  { Default() rather than FillChar: the record holds strings and dynamic
    arrays, and zeroing those bytes by hand would leak every one of them.
    A partial reset would be worse than none, because the fields that
    survived would report as measured. }
  DiagFacts := Default(TDiagFacts);
end;

{ ---------------------------------------------------------------- helpers -- }

function DiagLevelName(L: TDiagLevel): string;
begin
  case L of
    dlOk: Result := 'ok';
    dlWarn: Result := 'warning';
    dlProblem: Result := 'problem';
  else
    Result := 'skipped';
  end;
end;

function DiagCostName(C: TDiagCost): string;
begin
  case C of
    dcDisk: Result := 'disk';
    dcNetwork: Result := 'network';
  else
    Result := 'none';
  end;
end;

function DiagLevelRank(L: TDiagLevel): Integer;
begin
  { dlSkipped sits with dlOk deliberately.  The enum's declaration order is
    for readability; severity is this function and nothing else. }
  case L of
    dlWarn: Result := 1;
    dlProblem: Result := 2;
  else
    Result := 0;
  end;
end;

function DiagWorstLevel(const R: TDiagReport): TDiagLevel;
var
  I: Integer;
begin
  Result := dlOk;
  for I := 0 to High(R) do
    if DiagLevelRank(R[I].Level) > DiagLevelRank(Result) then
      Result := R[I].Level;
end;

function DiagClean(const S: string): string;
var
  I, N: Integer;
  T: string;
begin
  { Control characters are removed rather than escaped.  A hook command
    carrying ESC[2J would otherwise clear the user's terminal from inside a
    diagnostic, and a NUL would truncate the JSON string for half the
    parsers that read it. }
  SetLength(T, Length(S));
  N := 0;
  for I := 1 to Length(S) do
    if S[I] >= ' ' then
    begin
      Inc(N);
      T[N] := S[I];
    end;
  SetLength(T, N);
  Result := Utf8Cut(T, DiagFieldBytes);
  { Utf8Cut passes non-UTF-8 bytes through unchanged by contract, which is
    right for tool output and wrong here: this string is about to become a
    JSON value in a protocol line.  A file that was not UTF-8 to begin with
    is reported as such rather than smuggled onto the wire. }
  if not IsValidUtf8(Result) then Result := '(not valid UTF-8)';
end;

function DiagNowUnixMs: Int64;
begin
  { The same arithmetic uAuth uses for the same purpose.  Two copies of a
    time conversion that must agree is how an expiry check ends up an hour
    out in one time zone, so this one is deliberately the same shape. }
  Result := Round((LocalTimeToUniversal(Now) - EncodeDate(1970, 1, 1)) *
    MSecsPerDay);
end;

{ ------------------------------------------------------------- redaction -- }

function IsTokenChar(C: Char): Boolean;
begin
  Result := ((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or
            ((C >= '0') and (C <= '9')) or (C = '-') or (C = '_');
end;

function IsNameChar(C: Char): Boolean;
begin
  Result := ((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or
            ((C >= '0') and (C <= '9')) or (C = '_');
end;

function MatchAt(const S: string; At: Integer; const Lit: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if At + Length(Lit) - 1 > Length(S) then Exit;
  for I := 1 to Length(Lit) do
    if UpCase(S[At + I - 1]) <> UpCase(Lit[I]) then Exit;
  Result := True;
end;

{ How many token characters run from At. }
function TokenRun(const S: string; At: Integer): Integer;
begin
  Result := 0;
  while (At + Result <= Length(S)) and IsTokenChar(S[At + Result]) do
    Inc(Result);
end;

function SensitiveName(const N: string): Boolean;
var
  U: string;
begin
  U := UpperCase(N);
  Result := (Pos('KEY', U) > 0) or (Pos('TOKEN', U) > 0) or
            (Pos('SECRET', U) > 0) or (Pos('PASSWORD', U) > 0) or
            (Pos('CREDENTIAL', U) > 0);
end;

{ True when a recognised secret literal starts at At.  Used by the NAME=
  rule so that "ANTHROPIC_API_KEY=sk-ant-..." still renders as sk-ant-***
  rather than a bare ***: the shape of a leaked key is the single most
  useful thing in a bug report, and the bytes after it are the only part
  that must not survive. }
function SecretLiteralAt(const S: string; At: Integer): Boolean;
begin
  Result := MatchAt(S, At, 'sk-ant-') or
            (MatchAt(S, At, 'sk-') and (TokenRun(S, At + 3) >= 16));
end;

function DiagRedactSecrets(const S: string): string;
var
  I, J, N, NameStart: Integer;
  Name: string;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    { The two literal key shapes.  Anchored nowhere: a token embedded in the
      middle of a log line is exactly how one reaches a bug report, so a
      line-start anchor here would be the defect rather than the check. }
    if MatchAt(S, I, 'sk-ant-') then
    begin
      N := TokenRun(S, I + 7);
      Result := Result + 'sk-ant-***';
      Inc(I, 7 + N);
      Continue;
    end;
    if MatchAt(S, I, 'sk-') and (TokenRun(S, I + 3) >= 16) then
    begin
      N := TokenRun(S, I + 3);
      Result := Result + 'sk-***';
      Inc(I, 3 + N);
      Continue;
    end;
    { Bearer <anything not whitespace>.  The value may contain dots and
      slashes - a JWT does - so the run is "not whitespace", not "token
      characters". }
    if MatchAt(S, I, 'bearer ') and
       ((I = 1) or not IsNameChar(S[I - 1])) then
    begin
      J := I + 7;
      while (J <= Length(S)) and (S[J] = ' ') do Inc(J);
      N := 0;
      while (J + N <= Length(S)) and (S[J + N] > ' ') do Inc(N);
      if N > 0 then
      begin
        Result := Result + Copy(S, I, 7) + '***';
        I := J + N;
        Continue;
      end;
    end;
    { NAME=value, where the name says the value is a secret.  Applied only
      when the value is not already one of the shapes above, so the shape
      survives and the bytes do not. }
    if S[I] = '=' then
    begin
      NameStart := I;
      while (NameStart > 1) and IsNameChar(S[NameStart - 1]) do Dec(NameStart);
      Name := Copy(S, NameStart, I - NameStart);
      if (Name <> '') and SensitiveName(Name) and
         not SecretLiteralAt(S, I + 1) then
      begin
        N := 0;
        while (I + 1 + N <= Length(S)) and (S[I + 1 + N] > ' ') and
              (S[I + 1 + N] <> '"') do Inc(N);
        if N > 0 then
        begin
          Result := Result + '=***';
          Inc(I, 1 + N);
          Continue;
        end;
      end;
    end;
    Result := Result + S[I];
    Inc(I);
  end;
end;

{ Case-insensitive replace of every occurrence of Needle. }
function ReplaceCI(const S, Needle, Sub: string): string;
var
  I: Integer;
begin
  if (Needle = '') or (Length(Needle) > Length(S)) then Exit(S);
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if MatchAt(S, I, Needle) then
    begin
      Result := Result + Sub;
      Inc(I, Length(Needle));
    end
    else
    begin
      Result := Result + S[I];
      Inc(I);
    end;
  end;
end;

function DiagRedactPaths(const S: string; const Roots: TStringArray;
  const Home, Local: string): string;
var
  Needles, Subs: TStringArray;
  I, J: Integer;
  TS: string;

  procedure Add(const N, Sub: string);
  begin
    if Trim(N) = '' then Exit;
    SetLength(Needles, Length(Needles) + 1);
    SetLength(Subs, Length(Subs) + 1);
    Needles[High(Needles)] := ExcludeTrailingPathDelimiter(N);
    Subs[High(Subs)] := Sub;
  end;

begin
  Needles := nil;
  Subs := nil;
  for I := 0 to High(Roots) do Add(Roots[I], '<root' + IntToStr(I) + '>');
  Add(Local, '%LOCALAPPDATA%');
  Add(Home, '%USERPROFILE%');
  { Longest first, and that ordering is the whole correctness argument.
    LOCALAPPDATA lives UNDER the home directory and a nested --add-dir root
    lives under the primary one, so replacing in the order they were given
    would substitute the outer path first and leave the remaining segment -
    the very part that names the project - in the report. }
  for I := 0 to High(Needles) - 1 do
    for J := 0 to High(Needles) - 1 - I do
      if Length(Needles[J]) < Length(Needles[J + 1]) then
      begin
        TS := Needles[J]; Needles[J] := Needles[J + 1]; Needles[J + 1] := TS;
        TS := Subs[J];    Subs[J]    := Subs[J + 1];    Subs[J + 1]    := TS;
      end;
  Result := S;
  { Case-insensitively, because Windows paths arrive from the shell, from
    GetCurrentDir and from an environment variable in three different cases
    and a case-sensitive compare leaks whichever one did not match. }
  for I := 0 to High(Needles) do
    Result := ReplaceCI(Result, Needles[I], Subs[I]);
end;

function DiagTokenExpiry(ExpiresAtMs, NowMs: Int64;
  out Detail: string): TDiagLevel;
var
  Left: Int64;
begin
  if ExpiresAtMs <= 0 then
  begin
    { Not a warning.  A source that does not publish an expiry has not
      failed a check; claiming otherwise would put a permanent yellow line
      in front of every user of a plain API key. }
    Detail := 'unknown: this credential source does not say when it expires';
    Exit(dlSkipped);
  end;
  Left := ExpiresAtMs - NowMs;
  if Left <= 0 then
  begin
    Detail := Format('expired %d minutes ago', [(-Left) div 60000]);
    Exit(dlProblem);
  end;
  if Left < 30 * 60 * 1000 then
  begin
    Detail := Format('expires in %d minutes', [Left div 60000]);
    Exit(dlWarn);
  end;
  Detail := Format('valid for another %d minutes', [Left div 60000]);
  Result := dlOk;
end;

{ ------------------------------------------------------------ environment -- }

type
  { RTL_OSVERSIONINFOW.  Declared directly rather than through a package,
    and RtlGetVersion rather than GetVersionEx because the latter lies to a
    program with no manifest: it reports 6.2 on Windows 10 and 11 forever,
    which in a bug report is worse than no answer at all. }
  TRtlOsVersionInfoW = record
    dwOSVersionInfoSize: DWORD;
    dwMajorVersion: DWORD;
    dwMinorVersion: DWORD;
    dwBuildNumber: DWORD;
    dwPlatformId: DWORD;
    szCSDVersion: array[0..127] of WideChar;
  end;
  TRtlGetVersion = function(var Info: TRtlOsVersionInfoW): LongInt; stdcall;

function DiagOsVersion: string;
var
  Lib: HMODULE;
  Fn: TRtlGetVersion;
  Info: TRtlOsVersionInfoW;
begin
  Result := 'windows (version unknown)';
  Lib := GetModuleHandle('ntdll.dll');
  if Lib = 0 then Lib := LoadLibrary('ntdll.dll');
  if Lib = 0 then Exit;
  Fn := TRtlGetVersion(GetProcAddress(Lib, 'RtlGetVersion'));
  if Fn = nil then Exit;
  FillChar(Info, SizeOf(Info), 0);
  Info.dwOSVersionInfoSize := SizeOf(Info);
  if Fn(Info) <> 0 then Exit;
  Result := Format('windows %d.%d build %d',
    [Info.dwMajorVersion, Info.dwMinorVersion, Info.dwBuildNumber]);
end;

function DiagBuildInfo: string;
begin
  Result := 'fpc ' + {$I %FPCVERSION%} + ' ' + {$I %FPCTARGETCPU%} +
    '-' + {$I %FPCTARGETOS%};
end;

function DiagProbeWritable(const Dir: string; out Err: string): Boolean;
var
  Path: string;
  H: THandle;
  Written: DWORD;
  B: Byte;
begin
  Err := '';
  Result := False;
  if Trim(Dir) = '' then
  begin
    Err := 'no directory to test';
    Exit;
  end;
  Path := IncludeTrailingPathDelimiter(Dir) + DiagProbeName;
  try
    if not DirectoryExists(Dir) then
      if not ForceDirectories(Dir) then
      begin
        Err := 'the directory does not exist and could not be created';
        Exit;
      end;
    H := CreateFile(PChar(Path), GENERIC_WRITE, 0, nil, CREATE_ALWAYS,
      FILE_ATTRIBUTE_TEMPORARY, 0);
    if H = INVALID_HANDLE_VALUE then
    begin
      Err := SysErrorMessage(GetLastError);
      Exit;
    end;
    try
      B := 0;
      Result := WriteFile(H, B, 1, Written, nil) and (Written = 1);
      if not Result then Err := SysErrorMessage(GetLastError);
    finally
      CloseHandle(H);
      { In a finally so a failure to write still removes the file.  A probe
        that leaves its own litter behind has made the directory it was
        checking slightly worse. }
      if not SysUtils.DeleteFile(Path) then
        Err := 'the probe file could not be removed: ' + Path;
    end;
  except
    on E: Exception do
    begin
      { Never out of the probe.  The machine whose disk is the problem is
        precisely the one running /doctor. }
      Result := False;
      Err := E.Message;
    end;
  end;
end;

{ Resolves the first word of a command line on PATH.  A heuristic, and
  deliberately reported as one: a shell builtin, a PATHEXT this does not
  enumerate, or quoting parsed differently would all produce a false alarm,
  which is why every caller reports dlWarn and never dlProblem. }
function ProgramResolves(const Cmd: string): Boolean;
var
  Prog, Dir, Ext: string;
  I: Integer;
  Paths, Exts: TStringArray;

  function Split(const S: string; Sep: Char): TStringArray;
  var
    P, Q: Integer;
  begin
    Result := nil;
    P := 1;
    while P <= Length(S) do
    begin
      Q := P;
      while (Q <= Length(S)) and (S[Q] <> Sep) do Inc(Q);
      if Q > P then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Copy(S, P, Q - P);
      end;
      P := Q + 1;
    end;
  end;

begin
  Result := False;
  Prog := Trim(Cmd);
  if Prog = '' then Exit;
  if Prog[1] = '"' then
  begin
    Delete(Prog, 1, 1);
    I := Pos('"', Prog);
    if I > 0 then Prog := Copy(Prog, 1, I - 1);
  end
  else
  begin
    I := Pos(' ', Prog);
    if I > 0 then Prog := Copy(Prog, 1, I - 1);
  end;
  if Prog = '' then Exit;
  Exts := Split(SysUtils.GetEnvironmentVariable('PATHEXT'), ';');
  if Length(Exts) = 0 then
  begin
    SetLength(Exts, 4);
    Exts[0] := '.COM'; Exts[1] := '.EXE'; Exts[2] := '.BAT'; Exts[3] := '.CMD';
  end;
  if (Pos('\', Prog) > 0) or (Pos('/', Prog) > 0) or (Pos(':', Prog) > 0) then
  begin
    if FileExists(Prog) then Exit(True);
    for I := 0 to High(Exts) do
      if FileExists(Prog + Exts[I]) then Exit(True);
    Exit;
  end;
  Paths := Split(SysUtils.GetEnvironmentVariable('PATH'), ';');
  for I := 0 to High(Paths) do
  begin
    Dir := IncludeTrailingPathDelimiter(Trim(Paths[I]));
    if FileExists(Dir + Prog) then Exit(True);
    for Ext in Exts do
      if FileExists(Dir + Prog + Ext) then Exit(True);
  end;
end;

{ --------------------------------------------------------------- builders -- }

function Field(const S: string; N: Integer): string;
var
  I, Start, Cur: Integer;
begin
  { N is zero-based over tab-separated fields, the shape McpServerList and
    SettingsReport both already produce. }
  Result := '';
  Cur := 0;
  Start := 1;
  for I := 1 to Length(S) + 1 do
    if (I > Length(S)) or (S[I] = #9) then
    begin
      if Cur = N then
      begin
        Result := Copy(S, Start, I - Start);
        Exit;
      end;
      Inc(Cur);
      Start := I + 1;
    end;
end;

type
  { One check, closing over the builder's Result.  Nested, so Guard can run
    it inside a try/except that names it. }
  TDiagCheckProc = procedure is nested;

{ The one derivation of the IDE row, shared by /status and /doctor so the two
  cannot drift into disagreeing about which editor is in front of the user.

  Detection is only run when DiagFacts.IdeSetting has been filled in.  That
  is not caution about the cost - reading five environment variables is
  free - it is the record's own contract: a zeroed TDiagFacts must not
  produce a fact.  Gating on the host-supplied field is what keeps a report
  built by a suite, or by any caller that never filled the record, honest
  about having looked. }
function DiagIdeState(out Host: TIdeHost; out Cli: string): string;
begin
  Host := Default(TIdeHost);
  Cli := '';
  if DiagFacts.IdeSetting = '' then Exit('not probed');
  if DiagFacts.IdeSetting = 'off' then Exit('off (ide.enabled is false)');
  Host := uIde.IdeDetect;
  if Host.Family = ifNone then Exit('not detected');
  Cli := uIde.IdeResolveCli(Host, DiagFacts.IdeCommand);
  Result := Host.Name;
  if Host.Version <> '' then Result := Result + ' ' + Host.Version;
  if Host.Product <> '' then Result := Result + ' (' + Host.Product + ')';
  if Cli <> '' then
    Result := Result + ', ' + ExtractFileName(Cli)
  else
    Result := Result + ', launcher not known';
end;

function DiagBuildStatus(A: TAgent): TStatusReport;
var
  N: Integer;

  procedure Item(const Id, Caption, Value: string);
  begin
    SetLength(Result, N + 1);
    Result[N].Id := Id;
    Result[N].Caption := Caption;
    Result[N].Value := DiagClean(Value);
    Result[N].Extra := nil;
    Result[N].IsList := False;
    Inc(N);
  end;

  procedure ListItem(const Id, Caption: string);
  begin
    Item(Id, Caption, '');
    Result[N - 1].IsList := True;
  end;

  procedure Sub(const S: string);
  begin
    SetLength(Result[N - 1].Extra, Length(Result[N - 1].Extra) + 1);
    Result[N - 1].Extra[High(Result[N - 1].Extra)] := DiagClean(S);
  end;

var
  I: Integer;
  Rows: TStringArray;
  S: string;
  Skills: TSkillInfoArray;
  Plugins: TPluginInfoArray;
  EnabledCount: Integer;
  IdeHost: TIdeHost;
  IdeCli: string;
begin
  Result := nil;
  N := 0;
  Item('version', 'version', DiagFacts.Version);
  if A <> nil then
  begin
    Item('model', 'model', A.Model);
    { The name that will actually go on the wire, which differs from the one
      above whenever an alias or a profile is in force.  Reported separately
      rather than instead: a user who typed "opusplan" should see the word
      they typed AND what it resolves to right now. }
    if A.EffectiveModel(mrMain) <> A.Model then
      Item('model_resolved', 'model resolves to', A.EffectiveModel(mrMain));
  end
  else
    Item('model', 'model', '(no agent)');
  if DiagFacts.ModelSource <> '' then
    { "at startup", because /model typed since is not visible from here and
      a caption reading "model from" would be a claim this cannot support. }
    Item('model_source', 'model at startup from', DiagFacts.ModelSource);
  if DiagFacts.ModelRouting <> '' then
    Item('model_routing', 'routing', DiagFacts.ModelRouting);
  if DiagFacts.AuthSource = '' then
    Item('auth', 'credential', 'not probed')
  else if DiagFacts.AuthDetail <> '' then
    Item('auth', 'credential', DiagFacts.AuthSource + ' (' +
      DiagFacts.AuthDetail + ')')
  else
    Item('auth', 'credential', DiagFacts.AuthSource);
  { Borrowed, never reimplemented.  The mode word belongs to uTools and a
    second copy here would drift the first time /mode grows one. }
  Item('permission_mode', 'permission mode',
    uTools.PermModeName(uTools.CurrentPermMode));
  S := uTools.PermGrantSummary;
  if S <> '' then Item('permission_grants', 'standing grants', S);
  Item('deny_rules', 'deny rules', IntToStr(uTools.DenyRuleCount));
  Item('root', 'session root', uTools.RootDir);
  ListItem('added_roots', 'added directories');
  for I := 1 to uTools.RootCount - 1 do Sub(uTools.RootAt(I));
  Item('sandbox', 'sandbox', uSandbox.SandboxLevelName(uSandbox.SandboxLevel));
  Item('output_style', 'output style', uTools.OutputStyleName);
  if uTools.OutputStyleSource <> '' then
    Item('output_style_source', 'style from', uTools.OutputStyleSource);
  Item('vim', 'vim mode', BoolToStr(DiagFacts.VimOn, 'on', 'off'));
  { Always emitted, including outside an editor.  A row that appeared only
    when an IDE was found would make every /bug report from a plain console
    structurally different from every other one, and a maintainer reading
    the difference could not tell "no editor" from "an older pasclaude". }
  Item('ide', 'IDE host', DiagIdeState(IdeHost, IdeCli));
  { Conditional, because "where the launcher came from" is only a question
    when the user answered it.  The value names the FILE, never the path:
    the path itself is one Item below in the doctor detail, and repeating it
    here would put a program path in the shortest report twice. }
  if DiagFacts.IdeCommand <> '' then
    Item('ide_command_source', 'IDE launcher from', 'user settings.json');
  if not uHooks.HooksConfigured then
    Item('hooks', 'hooks', 'none configured')
  else if not uHooks.HooksEnabled then
    Item('hooks', 'hooks', 'configured but not enabled')
  else
  begin
    ListItem('hooks', 'hooks');
    Result[N - 1].Value := 'enabled';
    for I := Ord(hePreTool) to Ord(heSessionStart) do
      if uHooks.HookCount(THookEvent(I)) > 0 then
        Sub(uHooks.HookEventName(THookEvent(I)) + ': ' +
          IntToStr(uHooks.HookCount(THookEvent(I))));
  end;
  ListItem('mcp', 'MCP servers');
  Rows := uTools.McpServerList;
  Result[N - 1].Value := IntToStr(Length(Rows));
  for I := 0 to High(Rows) do
    Sub(Field(Rows[I], 0) + ' - ' + Field(Rows[I], 1) + ', ' +
      Field(Rows[I], 2) + ' tools');
  Skills := uTools.SkillCatalogue;
  Item('skills', 'skills', IntToStr(Length(Skills)));
  Plugins := uTools.InstalledPlugins;
  EnabledCount := 0;
  for I := 0 to High(Plugins) do
    if Plugins[I].Enabled then Inc(EnabledCount);
  Item('plugins', 'plugins', Format('%d installed, %d enabled',
    [Length(Plugins), EnabledCount]));
  if A <> nil then
  begin
    Item('turns', 'turns', IntToStr(A.TurnCount));
    Item('tokens_in', 'input tokens', IntToStr(A.TokensIn));
    Item('tokens_out', 'output tokens', IntToStr(A.TokensOut));
    Item('cache_read', 'cache read tokens', IntToStr(A.CacheReadTokens));
    Item('cache_write', 'cache written tokens', IntToStr(A.CacheWriteTokens));
    Item('context', 'context tokens', IntToStr(A.ContextTokens));
    Item('messages', 'messages', IntToStr(A.MessageCount));
  end;
  Item('changed_files', 'files changed this session',
    IntToStr(Length(uTools.ChangedFiles)));
  Item('jobs', 'background jobs', IntToStr(uTools.BackgroundJobCount));
  Item('session_file', 'session file', DiagFacts.SessionFilePath);
  Item('keys_file', 'keybindings file', DiagFacts.KeysPath);
  Item('permissions_file', 'approvals file', DiagFacts.PermissionsPath);
  if DiagFacts.TelemetrySummary <> '' then
    Item('telemetry', 'telemetry', DiagFacts.TelemetrySummary)
  else
    Item('telemetry', 'telemetry', 'off');
  if Length(DiagFacts.SettingsSummary) > 0 then
  begin
    ListItem('settings', 'settings');
    Result[N - 1].Value := IntToStr(Length(DiagFacts.SettingsSummary));
    for I := 0 to High(DiagFacts.SettingsSummary) do
      Sub(Field(DiagFacts.SettingsSummary[I], 0) + ' = ' +
        Field(DiagFacts.SettingsSummary[I], 1) + ' (' +
        Field(DiagFacts.SettingsSummary[I], 2) + ')');
  end
  else
    Item('settings', 'settings', 'all defaults');
  { The footer, and it is the honest one: three caches mean this report
    describes the SESSION, which after a mid-session edit is not what is on
    disk.  That is correct and surprising, and until now /help documented it
    per feature rather than in one place. }
  ListItem('caches', 'read once, refreshed by');
  Sub('skills: /skills');
  Sub('output style: /output-style <name>');
  Sub('MCP servers: /mcp refresh');
  Sub('settings.json: /config reload');
end;

function DiagBuildDoctor(A: TAgent; Online: Boolean): TDiagReport;
var
  N: Integer;

  procedure Emit(const Id, Title, Detail, Remedy: string;
    Level: TDiagLevel; Cost: TDiagCost);
  begin
    SetLength(Result, N + 1);
    Result[N].Id := Id;
    Result[N].Title := Title;
    Result[N].Detail := DiagClean(Detail);
    Result[N].Remedy := DiagClean(Remedy);
    Result[N].Level := Level;
    Result[N].Cost := Cost;
    { The invariant, asserted rather than remembered.  A warning or a
      problem with nothing to do about it is the riddle a health check
      exists to avoid, and it is far better caught here than by a user. }
    if (DiagLevelRank(Level) > 0) and (Trim(Result[N].Remedy) = '') then
      Result[N].Remedy := '(no remedy recorded - this is a defect in ' +
        'pasclaude, please report it with /bug)';
    Inc(N);
  end;

  { Every check runs inside this, so one that raises becomes a warning
    naming itself rather than taking the whole report down. }
  procedure Guard(const Id, Title: string; Body: TDiagCheckProc);
  begin
    try
      Body();
    except
      on E: Exception do
        Emit(Id, Title, 'the check itself failed: ' + E.Message,
          'report this with /bug', dlWarn, dcNone);
    end;
  end;

  procedure CheckWinHttp;
  begin
    if uHttp.HttpAvailable then
      Emit('winhttp', 'network library',
        'winhttp.dll loaded; this says the DLL and its entry points ' +
        'resolve, not that a proxy will let a request out', '',
        dlOk, dcNone)
    else
      Emit('winhttp', 'network library',
        'winhttp.dll could not be loaded, so no request can be made',
        'check that %SystemRoot%\system32\winhttp.dll exists and that ' +
        'nothing is blocking it', dlProblem, dcNone);
  end;

  procedure CheckCredential;
  begin
    if DiagFacts.AuthSource = '' then
      Emit('credential', 'credential', 'not probed', '', dlSkipped, dcNone)
    else if not DiagFacts.AuthPresent then
      Emit('credential', 'credential',
        'no usable credential was found in any of the six sources',
        'set ANTHROPIC_API_KEY=sk-ant-..., sign in to Claude Code once, ' +
        'or type /login', dlProblem, dcNone)
    else
      Emit('credential', 'credential',
        DiagFacts.AuthSource + ' (' + DiagFacts.AuthDetail + ')' +
        BoolToStr(DiagFacts.AuthIsOauth, ', an OAuth token', ', an API key'),
        '', dlOk, dcNone);
  end;

  procedure CheckExpiry;
  var
    Detail: string;
    L: TDiagLevel;
  begin
    if (DiagFacts.AuthSource = '') or not DiagFacts.AuthPresent then
    begin
      Emit('credential_expiry', 'credential expiry', 'no credential to check',
        '', dlSkipped, dcNone);
      Exit;
    end;
    L := DiagTokenExpiry(DiagFacts.AuthExpiresAtMs, DiagNowUnixMs, Detail);
    if L = dlProblem then
      { The mid-session 401 this whole check exists for.  Nothing refreshes a
        token on its own, and a rejected credential is not retryable, so the
        session dies at the next turn with an API error that does not say
        which of six sources was refused. }
      Emit('credential_expiry', 'credential expiry', Detail,
        'renew it in the program that owns it (' + DiagFacts.AuthSource +
        '), then /login to pick the refreshed one up', dlProblem, dcNone)
    else if L = dlWarn then
      Emit('credential_expiry', 'credential expiry', Detail,
        'renew it in ' + DiagFacts.AuthSource + ' before it goes',
        dlWarn, dcNone)
    else
      Emit('credential_expiry', 'credential expiry', Detail, '', L, dcNone);
  end;

  { dlWarn is the worst this can ever be, and that is a deliberate ceiling:
    pasclaude is completely functional with no editor anywhere on the
    machine, and a red line for a missing convenience would train a reader
    to skim past red lines that matter. }
  procedure CheckIde;
  var
    Host: TIdeHost;
    Cli, State: string;
  begin
    State := DiagIdeState(Host, Cli);
    if DiagFacts.IdeSetting = '' then
    begin
      Emit('ide_editor_cli', 'editor command line',
        'not probed', '', dlSkipped, dcDisk);
      Exit;
    end;
    if DiagFacts.IdeSetting = 'off' then
    begin
      Emit('ide_editor_cli', 'editor command line',
        'ide.enabled is false in your settings.json, so /ide is switched off',
        '', dlSkipped, dcDisk);
      Exit;
    end;
    if Host.Family = ifNone then
    begin
      Emit('ide_editor_cli', 'editor command line',
        'this terminal is not inside an editor pasclaude recognises, so ' +
        '/ide has nothing to open', '', dlSkipped, dcDisk);
      Exit;
    end;
    if Cli <> '' then
    begin
      Emit('ide_editor_cli', 'editor command line',
        State + ' at ' + Cli, '', dlOk, dcDisk);
      Exit;
    end;
    if Host.Family = ifJetBrains then
      { Not a defect and not fixable by looking harder: no variable a
        JetBrains terminal sets names the launcher, and idea64 / pycharm64 /
        rider64 cannot be told apart from the outside. }
      Emit('ide_editor_cli', 'editor command line',
        State + '; nothing a JetBrains terminal sets names the launcher, so ' +
        'it cannot be found by looking',
        'set "ide.command" in your own settings.json to the full path of ' +
        'the IDE launcher (for example C:\...\bin\idea64.exe); a project ' +
        'file may not set it', dlWarn, dcDisk)
    else
      Emit('ide_editor_cli', 'editor command line',
        State + '; no code.cmd, code-insiders.cmd or equivalent was found ' +
        'beside ' + Host.ExePath,
        'run "Shell Command: Install ''code'' command in PATH" from the ' +
        'editor''s command palette, or set "ide.command" in your own ' +
        'settings.json to the shim''s full path', dlWarn, dcDisk);
  end;

  procedure CheckStateDir;
  var
    Err, Dir: string;
  begin
    Dir := SysUtils.GetEnvironmentVariable('LOCALAPPDATA');
    if Dir = '' then Dir := SysUtils.GetEnvironmentVariable('USERPROFILE');
    if Dir = '' then
    begin
      Emit('state_dir_writable', 'state directory',
        'neither %LOCALAPPDATA% nor %USERPROFILE% is set, so approvals, ' +
        'deny rules and bug reports have nowhere to live',
        'set %USERPROFILE%; pasclaude never falls back into the project ' +
        'directory for state it writes', dlProblem, dcNone);
      Exit;
    end;
    Dir := IncludeTrailingPathDelimiter(Dir) + 'pasclaude';
    if DiagProbeWritable(Dir, Err) then
      Emit('state_dir_writable', 'state directory',
        Dir + ' is writable', '', dlOk, dcDisk)
    else
      Emit('state_dir_writable', 'state directory',
        Dir + ': ' + Err,
        'standing approvals and deny rules cannot be saved; check the ' +
        'permissions on that directory', dlProblem, dcDisk);
  end;

  procedure CheckProjectStateDir;
  var
    Err, Dir: string;
  begin
    if uTools.RootDir = '' then
    begin
      Emit('project_state_dir_writable', 'project state directory',
        'no session root', '', dlSkipped, dcNone);
      Exit;
    end;
    Dir := IncludeTrailingPathDelimiter(uTools.RootDir) + uTools.StateDirName;
    if DiagProbeWritable(Dir, Err) then
      Emit('project_state_dir_writable', 'project state directory',
        Dir + ' is writable', '', dlOk, dcDisk)
    else
      Emit('project_state_dir_writable', 'project state directory',
        Dir + ': ' + Err,
        'the conversation, the prompt history and plugin enablement cannot ' +
        'be saved here; the session still runs, it just forgets',
        dlWarn, dcDisk);
  end;

  procedure CheckConfigFiles;
  var
    Notes: TDiagReport;
    I: Integer;
    Detail: string;
    Worst: TDiagLevel;
  begin
    { The ledger, replayed.  Nothing is re-read: LoadMcpConfig would tear
      down live connections, RefreshSkills would drop the cache, and
      LoadHooks would re-ask a trust question already answered. }
    Notes := DiagNotes;
    if Length(Notes) = 0 then
    begin
      Emit('config_files', 'configuration files',
        'nothing complained at startup.  Note this replays what startup ' +
        'saw; a file edited since is not re-read, and a settings key this ' +
        'build does not understand is dropped by the next approvals save',
        '', dlOk, dcNone);
      Exit;
    end;
    Worst := dlOk;
    Detail := '';
    for I := 0 to High(Notes) do
    begin
      if DiagLevelRank(Notes[I].Level) > DiagLevelRank(Worst) then
        Worst := Notes[I].Level;
      if Detail <> '' then Detail := Detail + '; ';
      Detail := Detail + Notes[I].Id + ': ' + Notes[I].Detail;
    end;
    Emit('config_files', 'configuration files', Detail,
      'each source above names the file; /config, /deny, /hooks and /mcp ' +
      'show what is in force', Worst, dcNone);
  end;

  procedure CheckMcp;
  var
    Rows: TStringArray;
    I, Bad, Unresolved: Integer;
    Detail: string;
  begin
    Rows := uTools.McpServerList;
    if Length(Rows) = 0 then
    begin
      Emit('mcp_servers', 'MCP servers', 'none configured', '',
        dlOk, dcNone);
      Exit;
    end;
    Bad := 0;
    Unresolved := 0;
    Detail := '';
    for I := 0 to High(Rows) do
    begin
      if Detail <> '' then Detail := Detail + '; ';
      Detail := Detail + Field(Rows[I], 0) + ': ' + Field(Rows[I], 1);
      if (Field(Rows[I], 1) = 'dead') or
         (Field(Rows[I], 1) = 'failed to start') then Inc(Bad);
      { PATH resolution only.  Nothing is spawned: approving a spawn is a
        permission answer, and a health check must never be a way to get
        one. }
      if not ProgramResolves(Field(Rows[I], 4)) then
      begin
        Inc(Unresolved);
        Detail := Detail + ' (program not found on PATH)';
      end;
    end;
    if Bad > 0 then
      Emit('mcp_servers', 'MCP servers', Detail,
        '/mcp restart <name> tries again; the server''s own stderr is in ' +
        'the /mcp panel', dlProblem, dcDisk)
    else if Unresolved > 0 then
      Emit('mcp_servers', 'MCP servers', Detail,
        'this check reads PATH and does not run anything, so a shell ' +
        'builtin or an unusual PATHEXT can produce a false alarm; check ' +
        'the command in .mcp.json', dlWarn, dcDisk)
    else
      Emit('mcp_servers', 'MCP servers', Detail, '', dlOk, dcDisk);
  end;

  procedure CheckHookCommands;
  var
    I, Bad: Integer;
    Detail, Cmd: string;
  begin
    if not uHooks.HooksConfigured then
    begin
      Emit('hook_commands', 'hook commands', 'no hooks.json in this project',
        '', dlOk, dcNone);
      Exit;
    end;
    if not uHooks.HooksEnabled then
    begin
      Emit('hook_commands', 'hook commands',
        'hooks.json is present but not enabled for this session',
        '/hooks shows what it asks for; a trust answer is per file content',
        dlWarn, dcNone);
      Exit;
    end;
    Bad := 0;
    Detail := '';
    for I := 0 to uHooks.HookEntryCount - 1 do
    begin
      Cmd := uHooks.HookCommandAt(I);
      if ProgramResolves(Cmd) then Continue;
      Inc(Bad);
      if Detail <> '' then Detail := Detail + '; ';
      Detail := Detail + Cmd;
    end;
    if Bad = 0 then
      Emit('hook_commands', 'hook commands',
        Format('%d hook(s), every program resolves on PATH',
          [uHooks.HookEntryCount]), '', dlOk, dcDisk)
    else
      { dlWarn and never dlProblem, because the resolution is a heuristic:
        a builtin, a PATHEXT this does not enumerate, or quoting parsed
        differently would each look like a missing program. }
      Emit('hook_commands', 'hook commands',
        Format('%d of %d could not be resolved: %s',
          [Bad, uHooks.HookEntryCount, Detail]),
        'this check reads PATH only and does not run anything; if the ' +
        'command is a shell builtin it is fine, otherwise fix it in ' +
        uHooks.HooksFilePath, dlWarn, dcDisk);
  end;

  procedure CheckConsole;
  begin
    if DiagFacts.ConsoleOutCp = 0 then
    begin
      Emit('console', 'console', 'not probed', '', dlSkipped, dcNone);
      Exit;
    end;
    if (DiagFacts.ConsoleOutCp <> 65001) or (DiagFacts.ConsoleInCp <> 65001) then
      Emit('console', 'console',
        Format('codepage out %d, in %d; UTF-8 is 65001',
          [DiagFacts.ConsoleOutCp, DiagFacts.ConsoleInCp]),
        'non-ASCII text will render wrongly; TermInit sets both and ' +
        'something has changed them since', dlWarn, dcNone)
    else if not DiagFacts.VtActive then
      Emit('console', 'console',
        'UTF-8 both ways, but virtual terminal processing is off',
        'colour and cursor control are unavailable; a very old console ' +
        'host or a redirected stdout will do this', dlWarn, dcNone)
    else
      Emit('console', 'console', 'UTF-8 both ways, VT active', '',
        dlOk, dcNone);
  end;

  procedure CheckSessionFile;
  var
    F: file of Byte;
    Sz: Int64;
  begin
    if DiagFacts.SessionFilePath = '' then
    begin
      Emit('session_file', 'session file', 'not probed', '', dlSkipped, dcNone);
      Exit;
    end;
    if not FileExists(DiagFacts.SessionFilePath) then
    begin
      Emit('session_file', 'session file',
        'none saved yet at ' + DiagFacts.SessionFilePath, '', dlOk, dcDisk);
      Exit;
    end;
    { Size only.  Parsing it would mean reading the whole transcript into
      memory to answer a question nobody asked, and the loader already
      refuses a corrupt one at /resume with its own message. }
    AssignFile(F, DiagFacts.SessionFilePath);
    Reset(F);
    try
      Sz := FileSize(F);
    finally
      CloseFile(F);
    end;
    Emit('session_file', 'session file',
      Format('%s, %d bytes', [DiagFacts.SessionFilePath, Sz]),
      '', dlOk, dcDisk);
  end;

  procedure CheckSettingsScope;
  var
    I: Integer;
    Detail: string;
  begin
    if not DiagFacts.SettingsSupported then
    begin
      Emit('settings_scope', 'settings scope', 'not probed', '',
        dlSkipped, dcNone);
      Exit;
    end;
    if Length(DiagFacts.SettingsRefused) = 0 then
    begin
      Emit('settings_scope', 'settings scope',
        'no settings key was refused for its scope', '', dlOk, dcNone);
      Exit;
    end;
    Detail := '';
    for I := 0 to High(DiagFacts.SettingsRefused) do
    begin
      if Detail <> '' then Detail := Detail + '; ';
      Detail := Detail + DiagFacts.SettingsRefused[I];
    end;
    Emit('settings_scope', 'settings scope', Detail,
      'a project file may set display and economy keys only; move the key ' +
      'to %USERPROFILE%\.pasclaude\settings.json (/config)',
      dlWarn, dcNone);
  end;

  procedure CheckReportsDir;
  var
    R: TSearchRec;
    Count: Integer;
    Total: Int64;
    Dir: string;
  begin
    Dir := DiagReportsDir;
    if (Dir = '') or not DirectoryExists(Dir) then
    begin
      Emit('disk_reports', 'bug reports on disk', 'none written', '',
        dlOk, dcDisk);
      Exit;
    end;
    Count := 0;
    Total := 0;
    if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, R) = 0 then
      try
        repeat
          if (R.Attr and faDirectory) <> 0 then Continue;
          Inc(Count);
          Total := Total + R.Size;
        until FindNext(R) <> 0;
      finally
        { Qualified: the Windows unit exports a FindClose taking a handle,
          and it is listed after SysUtils in this unit's uses clause. }
        SysUtils.FindClose(R);
      end;
    if Count > DiagReportsNoisyAt then
      { Reported, never pruned.  Deleting the user's evidence on their
        behalf is worse than accumulating files they can see. }
      Emit('disk_reports', 'bug reports on disk',
        Format('%d files, %d KB in %s', [Count, Total div 1024, Dir]),
        'nothing here is ever deleted automatically; remove what you have ' +
        'already sent', dlWarn, dcDisk)
    else
      Emit('disk_reports', 'bug reports on disk',
        Format('%d files in %s', [Count, Dir]), '', dlOk, dcDisk);
  end;

  procedure CheckModelAccess;
  var
    Err: string;
    List: TModelList;
    Want: string;
  begin
    if not Online then
    begin
      { The default, and deliberately so.  Web search is off by default and
        fetch has its own approval class for the same reason: an outbound
        request is a channel, and a command called "doctor" must not open
        one merely by being typed. }
      Emit('model_access', 'model access',
        'not checked; /doctor --online asks the API which models this ' +
        'credential can use (one GET, no tokens billed)', '',
        dlSkipped, dcNone);
      Exit;
    end;
    if A = nil then
    begin
      Emit('model_access', 'model access', 'no agent to ask with', '',
        dlSkipped, dcNetwork);
      Exit;
    end;
    List := A.ListModels(Err);
    if Err <> '' then
    begin
      Emit('model_access', 'model access', Err,
        'the credential was refused or the endpoint was unreachable; ' +
        '/login lists the sources', dlProblem, dcNetwork);
      Exit;
    end;
    Want := A.EffectiveModel(mrMain);
    if uAgent.ModelListMatches(Want, List) then
      Emit('model_access', 'model access',
        Format('%d models listed, and %s is one of them',
          [Length(List), Want]), '', dlOk, dcNetwork)
    else
      Emit('model_access', 'model access',
        Format('%d models listed, and %s is not among them',
          [Length(List), Want]),
        '/model lists what this credential can use; a very new model may ' +
        'work anyway, the list is what the key was told about',
        dlWarn, dcNetwork);
  end;

begin
  Result := nil;
  N := 0;
  Guard('winhttp', 'network library', @CheckWinHttp);
  Guard('credential', 'credential', @CheckCredential);
  Guard('credential_expiry', 'credential expiry', @CheckExpiry);
  Guard('state_dir_writable', 'state directory', @CheckStateDir);
  Guard('project_state_dir_writable', 'project state directory',
    @CheckProjectStateDir);
  Guard('config_files', 'configuration files', @CheckConfigFiles);
  Guard('settings_scope', 'settings scope', @CheckSettingsScope);
  Guard('mcp_servers', 'MCP servers', @CheckMcp);
  Guard('hook_commands', 'hook commands', @CheckHookCommands);
  Guard('console', 'console', @CheckConsole);
  Guard('ide_editor_cli', 'editor command line', @CheckIde);
  Guard('session_file', 'session file', @CheckSessionFile);
  Guard('disk_reports', 'bug reports on disk', @CheckReportsDir);
  Guard('model_access', 'model access', @CheckModelAccess);
end;

{ -------------------------------------------------------------- renderers -- }

procedure PushLine(var A: TStringArray; const S: string);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)] := S;
end;

function DiagStatusText(const R: TStatusReport): TStringArray;
var
  I, J: Integer;
  Line: string;
begin
  Result := nil;
  for I := 0 to High(R) do
  begin
    Line := Format('  %-24s %s', [R[I].Caption + ':', R[I].Value]);
    PushLine(Result, DiagClean(TrimRight(Line)));
    for J := 0 to High(R[I].Extra) do
      PushLine(Result, DiagClean('      ' + R[I].Extra[J]));
  end;
end;

function DiagDoctorText(const R: TDiagReport): TStringArray;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to High(R) do
  begin
    PushLine(Result, DiagClean(Format('  [%-7s] %-26s %s',
      [DiagLevelName(R[I].Level), R[I].Title, R[I].Detail])));
    if Trim(R[I].Remedy) <> '' then
      PushLine(Result, DiagClean('              -> ' + R[I].Remedy));
    if R[I].Cost <> dcNone then
      PushLine(Result, DiagClean('              (cost: ' +
        DiagCostName(R[I].Cost) + ')'));
  end;
end;

function DiagStatusJsonObj(const R: TStatusReport): TJson;
var
  I, J: Integer;
  Arr: TJson;
begin
  Result := TJson.NewObj;
  Result.AddStr('type', 'status');
  for I := 0 to High(R) do
    if R[I].IsList then
    begin
      Arr := TJson.NewArr;
      for J := 0 to High(R[I].Extra) do
        Arr.Push(TJson.NewStr(R[I].Extra[J]));
      Result.Add(R[I].Id, Arr);
    end
    else
      Result.AddStr(R[I].Id, R[I].Value);
end;

function DiagDoctorJsonObj(const R: TDiagReport): TJson;
var
  I, NOk, NWarn, NProb, NSkip: Integer;
  Arr, C, Counts: TJson;
begin
  Result := TJson.NewObj;
  Result.AddStr('type', 'doctor');
  Result.AddBool('ok', DiagWorstLevel(R) <> dlProblem);
  NOk := 0; NWarn := 0; NProb := 0; NSkip := 0;
  Arr := TJson.NewArr;
  for I := 0 to High(R) do
  begin
    case R[I].Level of
      dlOk: Inc(NOk);
      dlWarn: Inc(NWarn);
      dlProblem: Inc(NProb);
    else
      Inc(NSkip);
    end;
    C := TJson.NewObj;
    C.AddStr('id', R[I].Id);
    C.AddStr('title', R[I].Title);
    C.AddStr('level', DiagLevelName(R[I].Level));
    C.AddStr('detail', R[I].Detail);
    C.AddStr('remedy', R[I].Remedy);
    C.AddStr('cost', DiagCostName(R[I].Cost));
    Arr.Push(C);
  end;
  Counts := TJson.NewObj;
  Counts.AddNum('ok', NOk);
  Counts.AddNum('warning', NWarn);
  Counts.AddNum('problem', NProb);
  Counts.AddNum('skipped', NSkip);
  Result.Add('counts', Counts);
  Result.Add('checks', Arr);
end;

function DiagStatusJson(const R: TStatusReport): string;
var
  J: TJson;
begin
  J := DiagStatusJsonObj(R);
  try
    Result := J.ToJson;
  finally
    J.Free;
  end;
end;

function DiagDoctorJson(const R: TDiagReport): string;
var
  J: TJson;
begin
  J := DiagDoctorJsonObj(R);
  try
    Result := J.ToJson;
  finally
    J.Free;
  end;
end;

{ -------------------------------------------------------------------- bug -- }

function DiagReportsDir: string;
var
  Home: string;
begin
  if DiagReportsDirOverride <> '' then Exit(DiagReportsDirOverride);
  { Out of tree for the ApprovalsPath reason and one more: LOCALAPPDATA is
    outside every root, so uTools.SafePath means the model's own read_file
    cannot read the report back.  With neither home, '' - and DiagWriteBug
    then refuses.  There is deliberately no fallback into the project: a bug
    report committed by accident is the worst outcome available here. }
  Home := SysUtils.GetEnvironmentVariable('LOCALAPPDATA');
  if Home <> '' then
    Exit(IncludeTrailingPathDelimiter(Home) + 'pasclaude\reports');
  Home := SysUtils.GetEnvironmentVariable('USERPROFILE');
  if Home <> '' then
    Exit(IncludeTrailingPathDelimiter(Home) + '.pasclaude\reports');
  Result := '';
end;

{ Every root, the primary one FIRST.  uTools.WorkingDirs answers with the
  --add-dir extras alone, which is right for its own callers and wrong here:
  the session root is the path that names the project and the client, and in
  the ordinary run with no --add-dir it is the ONLY path there is.  Handing
  WorkingDirs to the redactor produced a report whose banner said paths were
  redacted while every line of it carried the project directory. }
function AllRoots: TStringArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, uTools.RootCount);
  for I := 0 to uTools.RootCount - 1 do Result[I] := uTools.RootAt(I);
end;

function RedactAll(const S: string; const Opts: TBugOptions): string;
begin
  { Secrets always, unconditionally, with no flag that turns it off.  Paths
    unless the user opted in, because a path names the project, the client
    and often the person. }
  Result := DiagRedactSecrets(S);
  if not Opts.RealPaths then
    Result := DiagRedactPaths(Result, AllRoots,
      SysUtils.GetEnvironmentVariable('USERPROFILE'),
      SysUtils.GetEnvironmentVariable('LOCALAPPDATA'));
end;

function BugManifest(const Opts: TBugOptions): string;
begin
  Result :=
    '## Included'#10#10 +
    '- pasclaude version, FPC version and target, Windows build'#10 +
    '- console codepages and virtual terminal state'#10 +
    '- the whole /status report'#10 +
    '- the whole /doctor report'#10 +
    '- the startup note ledger'#10 +
    '- counters: turns, tokens, messages, changed files, jobs'#10#10 +
    '## Excluded'#10#10 +
    '- your prompts and the model''s replies'#10 +
    '- tool inputs and tool output'#10 +
    '- the contents of any file'#10 +
    '- environment variable values'#10 +
    '- the credential, in any form.  This is structural: the token is ' +
    'never placed in the diagnostic record at all, only the source word, ' +
    'whether it is an OAuth token, and when it expires.'#10#10;
  if Opts.RealPaths then
    Result := Result + '> Paths are NOT redacted: --paths was given.'#10#10
  else
    Result := Result +
      '> Paths are redacted to %USERPROFILE%, %LOCALAPPDATA% and <root0>..' +
      #10'> This is best effort by substring match.  Read the file before ' +
      'sharing it.'#10#10;
  if Opts.IncludeTranscript then
    Result := Result +
      '> A transcript was written to the sibling file named at the end of ' +
      'this report.'#10'> It is your conversation.  Secrets are redacted; ' +
      'nothing else is.'#10#10;
end;

function DiagBugText(A: TAgent; const Opts: TBugOptions;
  const Status: TStatusReport; const Doctor: TDiagReport): string;
var
  Lines: TStringArray;
  I: Integer;
  Notes: TDiagReport;
  Body: string;
begin
  Body := '# pasclaude bug report'#10#10 +
    'Generated ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + ' (local)'#10#10 +
    BugManifest(Opts) +
    '## Environment'#10#10 +
    '- pasclaude ' + DiagFacts.Version + #10 +
    '- ' + DiagBuildInfo + #10 +
    '- ' + DiagOsVersion + #10 +
    Format('- console codepage out %d, in %d, VT %s, stdin %s'#10,
      [DiagFacts.ConsoleOutCp, DiagFacts.ConsoleInCp,
       BoolToStr(DiagFacts.VtActive, 'on', 'off'),
       BoolToStr(DiagFacts.StdinIsConsole, 'a console', 'redirected')]) +
    '- scripted run: ' + BoolToStr(DiagFacts.Scripted, 'yes', 'no') + #10#10 +
    '## Status'#10#10'```'#10;
  Lines := DiagStatusText(Status);
  for I := 0 to High(Lines) do Body := Body + Lines[I] + #10;
  Body := Body + '```'#10#10'## Doctor'#10#10'```'#10;
  Lines := DiagDoctorText(Doctor);
  for I := 0 to High(Lines) do Body := Body + Lines[I] + #10;
  Body := Body + '```'#10#10'## Startup notes'#10#10;
  Notes := DiagNotes;
  if Length(Notes) = 0 then
    Body := Body + 'None.'#10
  else
    for I := 0 to High(Notes) do
      Body := Body + '- [' + DiagLevelName(Notes[I].Level) + '] ' +
        Notes[I].Id + ': ' + Notes[I].Detail + #10;
  Body := Body + #10'## Counters'#10#10;
  if A <> nil then
    Body := Body + Format(
      '- turns %d, input %d, output %d, cache read %d, cache written %d'#10 +
      '- messages %d, transcript %d bytes, context %d tokens'#10,
      [A.TurnCount, A.TokensIn, A.TokensOut, A.CacheReadTokens,
       A.CacheWriteTokens, A.MessageCount, A.TranscriptBytes,
       A.ContextTokens])
  else
    Body := Body + '- no agent'#10;
  Body := Body + Format('- files changed %d, background jobs %d, ' +
    'snapshots %d'#10, [Length(uTools.ChangedFiles),
    uTools.BackgroundJobCount, uTools.SnapshotCount]);
  Result := RedactAll(Body, Opts);
end;

function DiagBugJson(A: TAgent; const Opts: TBugOptions;
  const Status: TStatusReport; const Doctor: TDiagReport): string;
var
  Root, Env, Notes: TJson;
  L: TDiagReport;
  I: Integer;
  C: TJson;
begin
  Root := TJson.NewObj;
  try
    Root.AddStr('type', 'bug_report');
    Root.AddStr('generated', FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now));
    Env := TJson.NewObj;
    Env.AddStr('version', DiagFacts.Version);
    Env.AddStr('build', DiagBuildInfo);
    Env.AddStr('os', DiagOsVersion);
    Env.AddNum('console_out_cp', DiagFacts.ConsoleOutCp);
    Env.AddNum('console_in_cp', DiagFacts.ConsoleInCp);
    Env.AddBool('vt', DiagFacts.VtActive);
    Env.AddBool('scripted', DiagFacts.Scripted);
    Root.Add('environment', Env);
    Root.Add('status', DiagStatusJsonObj(Status));
    Root.Add('doctor', DiagDoctorJsonObj(Doctor));
    Notes := TJson.NewArr;
    L := DiagNotes;
    for I := 0 to High(L) do
    begin
      C := TJson.NewObj;
      C.AddStr('source', L[I].Id);
      C.AddStr('level', DiagLevelName(L[I].Level));
      C.AddStr('detail', L[I].Detail);
      Notes.Push(C);
    end;
    Root.Add('notes', Notes);
    Result := RedactAll(Root.ToJsonPretty, Opts);
  finally
    Root.Free;
  end;
end;

function WriteAllText(const Path, Text: string; out Err: string): Boolean;
var
  H: THandle;
  Written: DWORD;
begin
  Err := '';
  Result := False;
  H := CreateFile(PChar(Path), GENERIC_WRITE, 0, nil, CREATE_ALWAYS,
    FILE_ATTRIBUTE_NORMAL, 0);
  if H = INVALID_HANDLE_VALUE then
  begin
    Err := SysErrorMessage(GetLastError);
    Exit;
  end;
  try
    if Text = '' then Exit(True);
    Result := WriteFile(H, Text[1], Length(Text), Written, nil) and
      (Integer(Written) = Length(Text));
    if not Result then Err := SysErrorMessage(GetLastError);
  finally
    CloseHandle(H);
  end;
end;

function ReadAllText(const Path: string; out Text: string): Boolean;
var
  H: THandle;
  Sz, Got: DWORD;
begin
  Text := '';
  Result := False;
  H := CreateFile(PChar(Path), GENERIC_READ, FILE_SHARE_READ, nil,
    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if H = INVALID_HANDLE_VALUE then Exit;
  try
    Sz := GetFileSize(H, nil);
    if Sz = DWORD(-1) then Exit;
    SetLength(Text, Sz);
    if Sz = 0 then Exit(True);
    Result := ReadFile(H, Text[1], Sz, Got, nil) and (Got = Sz);
    if not Result then Text := '';
  finally
    CloseHandle(H);
  end;
end;

function DiagWriteBug(A: TAgent; const Opts: TBugOptions;
  out Path, TranscriptPath, Err: string): Boolean;
var
  Dir, Stamp, Base, Text, Body: string;
  Status: TStatusReport;
  Doctor: TDiagReport;
  SaveErr, TransErr: string;
begin
  Path := '';
  TranscriptPath := '';
  Err := '';
  Result := False;
  Dir := DiagReportsDir;
  if Dir = '' then
  begin
    { Refused, and nothing is written anywhere.  Falling back into the
      project tree would put the user's diagnostics under version control
      by accident, which is the one outcome worse than having none. }
    Err := 'no %LOCALAPPDATA% and no %USERPROFILE%: there is nowhere ' +
      'outside the project to write a report, and pasclaude will not ' +
      'write one inside it';
    Exit;
  end;
  if not ForceDirectories(Dir) then
  begin
    Err := 'could not create ' + Dir;
    Exit;
  end;
  Stamp := FormatDateTime('yyyymmdd-hhnnss', Now);
  Base := IncludeTrailingPathDelimiter(Dir) + 'bug-' + Stamp;
  Status := DiagBuildStatus(A);
  Doctor := DiagBuildDoctor(A, False);
  { The transcript first, so its name can be stated inside the report the
    user is about to read. }
  TransErr := '';
  if Opts.IncludeTranscript and (A <> nil) then
  begin
    TranscriptPath := Base + '-transcript.json';
    if A.SaveSession(TranscriptPath, SaveErr) then
    begin
      { Secrets only.  Redaction cannot redact meaning, and the console says
        so in yellow: a transcript is the conversation.

        Read-back or rewrite can fail - a virus scanner or a backup agent
        holding the file it has just seen appear is the ordinary case - and
        what is on disk at that moment is the UNREDACTED session.  It is
        deleted and the name withdrawn, because the caller announces this
        file to the user with the sentence "secrets are redacted", and a file
        that contradicts that sentence is worse than no file: the user has
        been told in yellow that a key they pasted into the conversation is
        not in it. }
      if ReadAllText(TranscriptPath, Text) then
      begin
        if not WriteAllText(TranscriptPath, DiagRedactSecrets(Text),
             SaveErr) then
          TransErr := 'the transcript could not be redacted (' + SaveErr +
            ') and was deleted; nothing unredacted was left behind';
      end
      else
        TransErr := 'the transcript could not be read back to redact it ' +
          'and was deleted; nothing unredacted was left behind';
      if TransErr <> '' then
      begin
        SysUtils.DeleteFile(TranscriptPath);
        TranscriptPath := '';
      end;
    end
    else
    begin
      TranscriptPath := '';
      TransErr := 'the transcript could not be written: ' + SaveErr;
    end;
  end;
  if Opts.AsJson then
  begin
    Path := Base + '.json';
    Body := DiagBugJson(A, Opts, Status, Doctor);
  end
  else
  begin
    Path := Base + '.md';
    Body := DiagBugText(A, Opts, Status, Doctor);
    if TranscriptPath <> '' then
      Body := Body + #10'## Transcript'#10#10 +
        RedactAll(TranscriptPath, Opts) + #10;
  end;
  Result := WriteAllText(Path, Body, Err);
  if not Result then Path := '';
  { WriteAllText clears Err as its first statement, so a transcript failure
    reported before this call would vanish exactly when the report itself
    succeeded - success with no transcript and no explanation.  The report's
    own error wins when there is one; otherwise the transcript's is carried
    out even though Result is True, and the caller prints it. }
  if Result and (TransErr <> '') then Err := TransErr;
end;

initialization
  ClearDiagFacts;
end.
