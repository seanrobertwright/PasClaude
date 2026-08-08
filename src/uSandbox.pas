{ uSandbox - what can be taken away from a child process without asking anyone.

  Every child this program starts - foreground bash, background bash, a hook,
  an MCP server - is created here, so that what is or is not confined is one
  decision in one place rather than four that drift apart.

  WHAT IS ACTUALLY REACHABLE.  Each of these was settled by compiling a probe
  and running it on an ordinary non-admin interactive account, not by reading
  documentation:

  * Job objects cost nothing and need no privilege.  SetInformationJobObject
    accepted the whole extended-limit set and all eight UI-restriction bits.
    A child inside a job that lacks BREAKAWAY_OK is refused CREATE_BREAKAWAY_-
    FROM_JOB with ERROR_ACCESS_DENIED, so today's flags already deny breakaway
    and no new flag is needed to keep it that way - only the discipline of not
    adding one.  This is the default level.

  * Low integrity is the only real confinement an unprivileged process can
    apply.  Lowering a token's label needs no privilege (only raising does),
    and a Low child cannot write %USERPROFILE%, cannot write HKCU, and cannot
    write any directory that has not been labelled for it - including the
    project tree.  It CAN read the entire user profile and it CAN use the
    network: a probe ran "dir %USERPROFILE%", "type .gitconfig" and an HTTPS
    request under Low and all three exited 0.  That measurement is the whole
    reason this unit is never consulted by a permission function.  A boundary
    that stops writes and stops nothing else cannot buy an approval discount,
    because the command it just approved can still read every credential on
    the machine and send it anywhere.

  * Restricted tokens are rejected.  CreateRestrictedToken(WRITE_RESTRICTED)
    built a token whose child died at 0xC0000142, STATUS_DLL_INIT_FAILED -
    the window-station and desktop ACL problem that costs Chromium hundreds of
    lines of SID plumbing.  DISABLE_MAX_PRIVILEGE spawned fine and bought
    nothing: the probe's child still wrote %TEMP%, because an ordinary user
    token has essentially no privileges to drop.

  * AppContainer is rejected.  It needs a persistent per-profile identity, it
    rewrites ACLs on every path that must stay reachable, and it puts the
    network behind capability SIDs that would have to be granted wholesale.
    What it adds over Low integrity is filesystem scoping we would have to
    hand-build anyway.

  * Two things are simply not on offer.  Scoping a child's filesystem to the
    session root needs a minifilter driver.  Denying it the network needs WFP
    or a firewall rule.  Both need a driver or an administrator, so neither is
    offered, and nothing here should be read as implying otherwise.

  The split into two levels follows from the costs.  Job limits are free, so
  they are on always; integrity is expensive - under it a command cannot write
  the tree it was asked to build - so it is opt-in.  Keeping them apart means
  the default is never the thing a user switches off for good after one
  mysterious build failure, which would leave them with less than an honest
  opt-in would have.

  The ladder: this unit is below uJson, uHooks, uMcp and uTools and imports
  Windows and SysUtils and nothing else.  That is not tidiness, it is the only
  legal place a spawn shared by uHooks, uMcp and uTools can live, since the
  ladder forbids the first two from importing the third - which is exactly why
  the job-object record used to be declared verbatim in all three.  Adding
  uJson here would create the cycle the ladder exists to prevent. }

unit uSandbox;

{$mode objfpc}{$H+}

interface

uses Windows, SysUtils;

type
  { slLimits is the default and costs nothing functionally.  slLow adds the
    integrity drop and is opt-in.  slOff is the escape hatch and restores
    exactly what shipped before this unit existed. }
  TSandboxLevel = (slOff, slLimits, slLow);

var
  { Set by the host from --sandbox or /sandbox, and by nothing else.  uTools
    never writes it and no permission function ever reads it. }
  SandboxLevel: TSandboxLevel = slLimits;

{ Parses 'off' | 'limits' | 'low' exactly - no trimming, no case folding, no
  prefixes.  A corrupt file or a fat-fingered flag must fail loudly rather
  than resolve to the least confined thing that nearly matches. }
function SandboxParseLevel(const S: string; out L: TSandboxLevel): Boolean;
function SandboxLevelName(L: TSandboxLevel): string;

{ Where the Low-labelled scratch would live for Key.  Key is a hash the host
  computes from the session root, so this unit never learns the root.  ''
  means there is no out-of-tree home directory to put it in - which is why
  slLow refuses rather than falling back into the project. }
function SandboxScratchPath(const Key: string): string;

{ Creates Dir and labels it Low so a Low child can write there.  False when
  Dir is '' or the directory or its label could not be made. }
function SandboxSetScratchRoot(const Dir: string): Boolean;

{ The directory handed to children as TEMP/TMP/TMPDIR under slLow.  '' until
  SandboxSetScratchRoot has succeeded. }
function SandboxTempDir: string;

{ True when slLow could actually be applied right now: there is a scratch to
  point TEMP at and the token can be built.  The host asks before accepting
  the level, so 'low' is never a word printed over a sandbox that is not
  running. }
function SandboxLowReady: Boolean;

{ Creates and configures a job for the current level.  0 on failure, which
  every caller treats as 'spawn anyway, unconfined' - degrading is the rule
  the background-job table already used, and refusing to run a command
  because a job object could not be made would be a worse trade.

  A job is made at every level, slOff included; slOff simply gets nothing but
  KILL_ON_JOB_CLOSE.  Reaping a child's tree is what the callers had before the
  sandbox existed and is not one of the restrictions 'off' switches off. }
function SandboxNewJob: THandle;

{ The primary token for the current level, or 0 meaning 'use the parent's'.
  Cached; closed by SandboxShutdown. }
function SandboxToken: THandle;

{ Base with TEMP/TMP/TMPDIR pointed at the scratch under slLow.  Base '' means
  the parent's environment, and the result is '' too at slOff and slLimits,
  because '' is what a caller passes as nil to CreateProcess. }
function SandboxApplyEnv(const Base: string): string;

{ SandboxApplyEnv(''), cached. }
function SandboxEnvBlock: string;

{ The one spawn.  Creates suspended, assigns to Job, and only then resumes -
  which is what closes the grandchild-escape race all three call sites used to
  document as accepted, since a child that has not run yet cannot have started
  anything outside the job.  Probe-verified with both a plain and a low token.

  CmdLine is a finished command line: this never composes one, because bash
  and hooks want cmd.exe wrapped round theirs and MCP servers must not have
  it.  Dir and Env are '' for 'inherit'. }
function SandboxSpawn(const CmdLine, Dir, Env: string; ExtraFlags: DWORD;
  const SI: STARTUPINFOA; var PI: PROCESS_INFORMATION;
  Job: THandle; out AssignedToJob: Boolean): Boolean;

{ Kills a job and everything in it.  Here so the three call sites that used to
  declare the import themselves no longer have to. }
function SandboxTerminateJob(J: THandle; Code: UINT): BOOL;

{ '; sandbox: low' for the exit line, or '' when the level is off or the
  command succeeded.  Unconditional on the level rather than on any guess
  about why the command failed: it is the only part of the annotation that
  survives a machine whose error messages are not in English. }
function SandboxTag(ExitCode: Integer): string;

{ One line of advice when something about the failure suggests the sandbox
  caused it, '' otherwise.  Output must already be UTF-8. }
function SandboxExplain(ExitCode: Integer; const Output: string): string;

{ What the level forbids and - just as important - what it does not.  Used by
  /sandbox and the --help text. }
function SandboxDescribe(L: TSandboxLevel): string;

{ Closes the cached token and drops the cached environment block.  Idempotent,
  and it must run on the Halt paths too, since Halt skips finally. }
procedure SandboxShutdown;

implementation

{ ------------------------------------------------------ the Win32 surface -- }

{ FPC 3.2.2's Windows unit declares none of this.  These are the documented
  kernel32 and advapi32 exports; TJobExtendedLimits is 144 bytes on x64, which
  SetInformationJobObject validates on every call and a probe confirmed. }
const
  JobObjectExtendedLimitInformation = 9;
  JobObjectBasicUIRestrictions      = 4;

  JOB_OBJECT_LIMIT_ACTIVE_PROCESS             = $8;
  JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION = $400;
  JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE          = $2000;

  JOB_OBJECT_UILIMIT_HANDLES          = $1;
  JOB_OBJECT_UILIMIT_READCLIPBOARD    = $2;
  JOB_OBJECT_UILIMIT_WRITECLIPBOARD   = $4;
  JOB_OBJECT_UILIMIT_SYSTEMPARAMETERS = $8;
  JOB_OBJECT_UILIMIT_DISPLAYSETTINGS  = $10;
  JOB_OBJECT_UILIMIT_GLOBALATOMS      = $20;
  JOB_OBJECT_UILIMIT_DESKTOP          = $40;
  JOB_OBJECT_UILIMIT_EXITWINDOWS      = $80;

  { Sixty-four processes is far past anything a real build needs at once and
    far short of a fork bomb.  It is the one quantitative limit taken: memory
    limits were rejected because an allocation failure deep inside a linker is
    undiagnosable from the outside, and CPU-time limits were rejected because
    PerJobUserTimeLimit counts CPU rather than wall clock and a legitimate
    build exceeds it - while the foreground already has a wall-clock deadline
    and the background already has a spool cap. }
  MaxChildProcesses = 64;

  TokenIntegrityLevel = 25;
  SE_GROUP_INTEGRITY  = $20;
  TokenPrimary        = 1;
  SecurityImpersonation = 2;
  TOKEN_ALL_ACCESS_P  = $F01FF;
  LowIntegritySid     = 'S-1-16-4096';

  LABEL_SECURITY_INFORMATION = $10;
  { Low mandatory label, inheritable, no-write-up.  NW only: a Low child must
    be able to write here, and anything stronger would also stop it. }
  LowLabelSddl = 'S:(ML;OICI;NW;;;LW)';

type
  TJobBasicLimits = record
    PerProcessUserTimeLimit: Int64;
    PerJobUserTimeLimit: Int64;
    LimitFlags: DWORD;
    MinimumWorkingSetSize: SIZE_T;
    MaximumWorkingSetSize: SIZE_T;
    ActiveProcessLimit: DWORD;
    Affinity: ULONG_PTR;
    PriorityClass: DWORD;
    SchedulingClass: DWORD;
  end;

  TJobIoCounters = record
    ReadOperationCount, WriteOperationCount, OtherOperationCount: QWord;
    ReadTransferCount, WriteTransferCount, OtherTransferCount: QWord;
  end;

  TJobExtendedLimits = record
    BasicLimitInformation: TJobBasicLimits;
    IoInfo: TJobIoCounters;
    ProcessMemoryLimit: SIZE_T;
    JobMemoryLimit: SIZE_T;
    PeakProcessMemoryUsed: SIZE_T;
    PeakJobMemoryUsed: SIZE_T;
  end;

  TJobUIRestrictions = record
    UIRestrictionsClass: DWORD;
  end;

  TSidAndAttributes = record
    Sid: Pointer;
    Attributes: DWORD;
  end;

  TTokenMandatoryLabel = record
    Value: TSidAndAttributes;
  end;

function CreateJobObjectA(Attr: Pointer; Name: PAnsiChar): THandle; stdcall;
  external 'kernel32' name 'CreateJobObjectA';
function SetInformationJobObject(J: THandle; Cls: Integer; Info: Pointer;
  Len: DWORD): BOOL; stdcall; external 'kernel32' name 'SetInformationJobObject';
function AssignProcessToJobObject(J, P: THandle): BOOL; stdcall;
  external 'kernel32' name 'AssignProcessToJobObject';
function TerminateJobObject(J: THandle; Code: UINT): BOOL; stdcall;
  external 'kernel32' name 'TerminateJobObject';

function ConvertStringSidToSidA(S: PAnsiChar; out Sid: Pointer): BOOL; stdcall;
  external 'advapi32' name 'ConvertStringSidToSidA';
function DuplicateTokenEx(Tok: THandle; Access: DWORD; SA: Pointer;
  Level, TokType: Integer; out NewTok: THandle): BOOL; stdcall;
  external 'advapi32' name 'DuplicateTokenEx';
function SetTokenInformation(Tok: THandle; Cls: Integer; Info: Pointer;
  Len: DWORD): BOOL; stdcall; external 'advapi32' name 'SetTokenInformation';
function CreateProcessAsUserA(Tok: THandle; App, Cmd: PAnsiChar;
  PA, TA: Pointer; Inherit: BOOL; Flags: DWORD; Env: Pointer; Dir: PAnsiChar;
  const SI: STARTUPINFOA; var PI: PROCESS_INFORMATION): BOOL; stdcall;
  external 'advapi32' name 'CreateProcessAsUserA';
function ConvertStringSecurityDescriptorToSecurityDescriptorA(S: PAnsiChar;
  Rev: DWORD; out SD: Pointer; Size: Pointer): BOOL; stdcall;
  external 'advapi32'
  name 'ConvertStringSecurityDescriptorToSecurityDescriptorA';
function SetFileSecurityA(F: PAnsiChar; Info: DWORD; SD: Pointer): BOOL;
  stdcall; external 'advapi32' name 'SetFileSecurityA';

{ TerminateJobObject is re-exported so uTools and uHooks can kill a tree
  without declaring the import a fourth time. }
function SandboxTerminateJob(J: THandle; Code: UINT): BOOL;
begin
  Result := TerminateJobObject(J, Code);
end;

{ ------------------------------------------------------------ the levels -- }

function SandboxParseLevel(const S: string; out L: TSandboxLevel): Boolean;
begin
  L := slLimits;
  Result := True;
  if S = 'off' then L := slOff
  else if S = 'limits' then L := slLimits
  else if S = 'low' then L := slLow
  else Result := False;
end;

function SandboxLevelName(L: TSandboxLevel): string;
begin
  case L of
    slOff: Result := 'off';
    slLow: Result := 'low';
  else
    Result := 'limits';
  end;
end;

function SandboxDescribe(L: TSandboxLevel): string;
begin
  case L of
    slOff:
      Result := 'child processes run with everything this program has.';
    slLow:
      Result :=
        'children run at low integrity inside a job object.  They cannot ' +
        'write your profile,'#10'  the registry under HKCU, or any ' +
        'directory not labelled for them - including this project.'#10 +
        '  They CAN still read every file you can read, and they CAN still ' +
        'reach the network.';
  else
    Result :=
      'children run inside a job object: at most ' +
      IntToStr(MaxChildProcesses) + ' processes, killed when the job ' +
      'closes,'#10'  no breakaway, no clipboard read, no desktop or ' +
      'display changes.  Nothing else is'#10'  taken away - this level is ' +
      'meant to be invisible to a command that behaves.';
  end;
end;

{ ----------------------------------------------------------- the scratch -- }

var
  ScratchDir: string = '';

function SandboxScratchPath(const Key: string): string;
var
  Home: string;
begin
  Result := '';
  { SysUtils. qualified deliberately: the Windows unit's raw API of the same
    name is in scope here and shadows it. }
  Home := Trim(SysUtils.GetEnvironmentVariable('LOCALAPPDATA'));
  if Home = '' then
    Home := Trim(SysUtils.GetEnvironmentVariable('USERPROFILE'));
  if Home = '' then Exit;
  { Out of the project tree for the same two reasons approvals are: a clone
    must not be able to ship it, and a directory labelled Low is writable by
    every other Low-integrity process on the machine - which is a thing to put
    under %LOCALAPPDATA%, not inside somebody's source. }
  Result := IncludeTrailingPathDelimiter(Home) + 'pasclaude' + PathDelim +
    'sandbox' + PathDelim + Key;
end;

function SandboxSetScratchRoot(const Dir: string): Boolean;
var
  SD: Pointer;
begin
  Result := False;
  ScratchDir := '';
  if Trim(Dir) = '' then Exit;
  if not ForceDirectories(Dir) then Exit;
  if not ConvertStringSecurityDescriptorToSecurityDescriptorA(
           LowLabelSddl, 1, SD, nil) then Exit;
  try
    if not SetFileSecurityA(PAnsiChar(ExcludeTrailingPathDelimiter(Dir)),
             LABEL_SECURITY_INFORMATION, SD) then Exit;
  finally
    LocalFree(HLOCAL(SD));
  end;
  ScratchDir := ExcludeTrailingPathDelimiter(Dir);
  Result := True;
end;

function SandboxTempDir: string;
begin
  Result := ScratchDir;
end;

{ -------------------------------------------------------------- the token -- }

var
  LowTok: THandle = 0;
  LowTokTried: Boolean = False;

{ Built once and kept.  Lowering a label needs no privilege, so this succeeds
  for an ordinary user; it is cached because building it per child would pay
  three syscalls for a token that never changes. }
function BuildLowToken: THandle;
var
  Self_, Dup: THandle;
  Sid: Pointer;
  Value: TTokenMandatoryLabel;
begin
  Result := 0;
  Self_ := 0;
  if not OpenProcessToken(GetCurrentProcess, TOKEN_ALL_ACCESS_P, @Self_) then
    Exit;
  if not DuplicateTokenEx(Self_, 0, nil, SecurityImpersonation, TokenPrimary,
           Dup) then
  begin
    CloseHandle(Self_);
    Exit;
  end;
  CloseHandle(Self_);
  if not ConvertStringSidToSidA(LowIntegritySid, Sid) then
  begin
    CloseHandle(Dup);
    Exit;
  end;
  Value.Value.Sid := Sid;
  Value.Value.Attributes := SE_GROUP_INTEGRITY;
  if not SetTokenInformation(Dup, TokenIntegrityLevel, @Value,
           SizeOf(Value)) then
  begin
    LocalFree(HLOCAL(Sid));
    CloseHandle(Dup);
    Exit;
  end;
  LocalFree(HLOCAL(Sid));
  Result := Dup;
end;

function SandboxToken: THandle;
begin
  Result := 0;
  if SandboxLevel <> slLow then Exit;
  if not LowTokTried then
  begin
    LowTokTried := True;
    LowTok := BuildLowToken;
  end;
  Result := LowTok;
end;

function SandboxLowReady: Boolean;
var
  Saved: TSandboxLevel;
begin
  { Asked before the level is accepted, so the level has to be forced for the
    duration of the question - otherwise 'is low ready' could only ever be
    answered once low was already on, which is too late to refuse it. }
  Saved := SandboxLevel;
  SandboxLevel := slLow;
  try
    Result := (ScratchDir <> '') and (SandboxToken <> 0);
  finally
    SandboxLevel := Saved;
  end;
end;

{ -------------------------------------------------------- the environment -- }

var
  EnvCache: string = '';
  EnvCacheFor: TSandboxLevel = slOff;
  EnvCacheValid: Boolean = False;

{ The separator is the first '=' at position 2 or later.  Position 2, not 1,
  because cmd.exe keeps its per-drive working directories in variables whose
  names begin with '=' ("=C:=C:\work"), and a split on the first '=' anywhere
  would turn those into an empty name and drop them - which loses a shell's
  idea of where it is on every drive but the current one. }
function EntryName(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 2 to Length(S) do
    if S[I] = '=' then Exit(Copy(S, 1, I - 1));
end;

function SandboxApplyEnv(const Base: string): string;
var
  I, Start: Integer;
  Cur, Name: string;
  Scratch: string;
begin
  Result := '';
  { Nothing to redirect below slLow, and '' tells the caller to pass nil and
    let the child inherit - which is both cheaper and exactly what shipped. }
  if SandboxLevel <> slLow then Exit(Base);
  Scratch := ScratchDir;
  if Scratch = '' then Exit(Base);

  if Base = '' then
  begin
    { The parent's environment, entry by entry.  GetEnvironmentString hands
      back the '='-prefixed entries too, which is why they have to be
      recognised rather than merely tolerated. }
    for I := 1 to GetEnvironmentVariableCount do
    begin
      Cur := GetEnvironmentString(I);
      if Cur = '' then Continue;
      Name := EntryName(Cur);
      if Name = '' then Continue;
      if SameText(Name, 'TEMP') or SameText(Name, 'TMP') or
         SameText(Name, 'TMPDIR') then Continue;
      Result := Result + Cur + #0;
    end;
  end
  else
  begin
    { A block somebody else built: NAME=VALUE#0 repeated, closed by a second
      #0.  Only the three names are touched; every other entry is copied
      through byte for byte, so a value containing '=' cannot be damaged
      because it is never taken apart. }
    Start := 1;
    for I := 1 to Length(Base) do
      if Base[I] = #0 then
      begin
        Cur := Copy(Base, Start, I - Start);
        Start := I + 1;
        if Cur = '' then Break;         { the terminator }
        Name := EntryName(Cur);
        if Name = '' then Continue;
        if SameText(Name, 'TEMP') or SameText(Name, 'TMP') or
           SameText(Name, 'TMPDIR') then Continue;
        Result := Result + Cur + #0;
      end;
  end;

  { The scratch is the only directory a Low child can write, so pointing the
    three temp variables at it is what keeps ordinary tools working: almost
    everything that fails under Low fails first on a temporary file. }
  Result := Result + 'TEMP=' + Scratch + #0;
  Result := Result + 'TMP=' + Scratch + #0;
  Result := Result + 'TMPDIR=' + Scratch + #0;
  { CreateProcess reads until it sees the empty entry.  Forgetting this second
    NUL makes it walk off the end of the string. }
  Result := Result + #0;
end;

function SandboxEnvBlock: string;
begin
  if EnvCacheValid and (EnvCacheFor = SandboxLevel) then Exit(EnvCache);
  EnvCache := SandboxApplyEnv('');
  EnvCacheFor := SandboxLevel;
  EnvCacheValid := True;
  Result := EnvCache;
end;

{ ---------------------------------------------------------------- the job -- }

function SandboxNewJob: THandle;
var
  Info: TJobExtendedLimits;
  UI: TJobUIRestrictions;
begin
  Result := CreateJobObjectA(nil, nil);
  if Result = 0 then Exit;

  { KILL_ON_JOB_CLOSE alone at slOff, and never nothing.  Every one of these
    call sites created a job unconditionally before the sandbox existed, purely
    so that closing the handle reaps the grandchildren: without it kill_bash
    terminates cmd.exe and leaves whatever it started holding the spool file
    open, a timed-out hook leaks its tree, and process exit reaps nothing.
    That is process lifetime, not confinement, so turning the sandbox off must
    not turn it off - "off" means no limits on what a child may do, not that a
    child outlives the tool call that made it. }
  if SandboxLevel = slOff then
  begin
    FillChar(Info, SizeOf(Info), 0);
    Info.BasicLimitInformation.LimitFlags := JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if not SetInformationJobObject(Result, JobObjectExtendedLimitInformation,
             @Info, SizeOf(Info)) then
    begin
      CloseHandle(Result);
      Result := 0;
    end;
    Exit;
  end;

  FillChar(Info, SizeOf(Info), 0);
  { KILL_ON_JOB_CLOSE is what makes closing the handle reap the whole tree.
    ACTIVE_PROCESS must be in the flag word as well as the field being set -
    a populated ActiveProcessLimit with the flag missing is enforced by
    nothing, which is the classic way this record is got wrong.
    BREAKAWAY_OK is deliberately absent and must stay absent: without it a
    child asking for CREATE_BREAKAWAY_FROM_JOB is refused outright, which a
    probe confirmed from inside the job rather than from the documentation. }
  Info.BasicLimitInformation.LimitFlags :=
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE or
    JOB_OBJECT_LIMIT_ACTIVE_PROCESS or
    JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
  Info.BasicLimitInformation.ActiveProcessLimit := MaxChildProcesses;
  if not SetInformationJobObject(Result, JobObjectExtendedLimitInformation,
           @Info, SizeOf(Info)) then
  begin
    { Degrade rather than refuse: a command the user approved should not fail
      because a job object could not be configured. }
    CloseHandle(Result);
    Result := 0;
    Exit;
  end;

  { Held back to slLimits because none of these is something a build does.
    WRITECLIPBOARD and HANDLES are not here: "| clip" is a thing people
    legitimately pipe to, and driving a window they already have open is a
    thing people legitimately script - so those two wait for slLow, where the
    user has said they want the tighter setting. }
  UI.UIRestrictionsClass :=
    JOB_OBJECT_UILIMIT_EXITWINDOWS or
    JOB_OBJECT_UILIMIT_READCLIPBOARD or
    JOB_OBJECT_UILIMIT_DESKTOP or
    JOB_OBJECT_UILIMIT_DISPLAYSETTINGS or
    JOB_OBJECT_UILIMIT_SYSTEMPARAMETERS or
    JOB_OBJECT_UILIMIT_GLOBALATOMS;
  if SandboxLevel = slLow then
    UI.UIRestrictionsClass := UI.UIRestrictionsClass or
      JOB_OBJECT_UILIMIT_HANDLES or JOB_OBJECT_UILIMIT_WRITECLIPBOARD;
  { A UI restriction that will not take is not worth losing the job over: the
    limits above are the ones that matter. }
  SetInformationJobObject(Result, JobObjectBasicUIRestrictions,
    @UI, SizeOf(UI));
end;

{ -------------------------------------------------------------- the spawn -- }

function SandboxSpawn(const CmdLine, Dir, Env: string; ExtraFlags: DWORD;
  const SI: STARTUPINFOA; var PI: PROCESS_INFORMATION;
  Job: THandle; out AssignedToJob: Boolean): Boolean;
var
  Line, EnvCopy, DirCopy: string;
  EnvPtr: Pointer;
  DirPtr: PAnsiChar;
  Flags: DWORD;
  Tok: THandle;
begin
  AssignedToJob := False;
  { CreateProcessA may write into lpCommandLine and into the environment
    block, so neither may be sharing a string with anybody. }
  Line := CmdLine;
  UniqueString(Line);
  EnvCopy := Env;
  UniqueString(EnvCopy);
  DirCopy := Dir;
  UniqueString(DirCopy);
  if EnvCopy = '' then EnvPtr := nil else EnvPtr := PAnsiChar(EnvCopy);
  if DirCopy = '' then DirPtr := nil else DirPtr := PAnsiChar(DirCopy);

  Flags := ExtraFlags or CREATE_NO_WINDOW or CREATE_SUSPENDED;
  Tok := SandboxToken;
  FillChar(PI, SizeOf(PI), 0);
  if Tok <> 0 then
    Result := CreateProcessAsUserA(Tok, nil, PAnsiChar(Line), nil, nil, True,
      Flags, EnvPtr, DirPtr, SI, PI)
  else
    Result := CreateProcess(nil, PChar(Line), nil, nil, True, Flags,
      EnvPtr, DirPtr, SI, PI);
  if not Result then Exit;

  { Assign before the first instruction runs.  The three old call sites each
    assigned after the spawn and each documented the resulting race - a
    grandchild started while cmd.exe parsed its command line escaped the job
    and survived the kill.  Suspending closes it, because there is no window
    in which the child is running and unassigned. }
  if Job <> 0 then
    AssignedToJob := AssignProcessToJobObject(Job, PI.hProcess);

  if ResumeThread(PI.hThread) = DWORD(-1) then
  begin
    { A child that was created but never resumed would sit there forever
      holding whatever handles it inherited, and no caller is prepared for
      that, so it is killed here rather than handed back. }
    TerminateProcess(PI.hProcess, 1);
    CloseHandle(PI.hThread);
    CloseHandle(PI.hProcess);
    FillChar(PI, SizeOf(PI), 0);
    AssignedToJob := False;
    Result := False;
  end;
end;

{ --------------------------------------------------- explaining a failure -- }

function SandboxTag(ExitCode: Integer): string;
begin
  Result := '';
  if SandboxLevel = slOff then Exit;
  if ExitCode = 0 then Exit;
  Result := '; sandbox: ' + SandboxLevelName(SandboxLevel);
end;

function SandboxExplain(ExitCode: Integer; const Output: string): string;
var
  Looks: Boolean;
begin
  Result := '';
  if SandboxLevel = slOff then Exit;
  if ExitCode = 0 then Exit;
  { The two exit codes are locale-independent: C0000142 is a process that
    could not initialise, 1816 is ERROR_NOT_ENOUGH_QUOTA, which is what the
    process cap reports.  The message markers are not - on a Windows that
    speaks anything but English none of them will ever fire.  That is exactly
    why the unconditional level tag on the exit line, not this hint, is what
    stops a user misdiagnosing the sandbox as a broken tool; this only adds
    the remedy when we can guess at one. }
  Looks := (ExitCode = Integer($C0000142)) or (ExitCode = 1816) or
    (Pos('Access is denied', Output) > 0) or
    (Pos('Not enough quota', Output) > 0) or
    (Pos('is denied', Output) > 0);
  if not Looks then Exit;

  if SandboxLevel = slLow then
    Result := 'the sandbox is at "low": this command could not write ' +
      'outside %TEMP%.  Nothing'#10'outside the sandbox scratch is ' +
      'writable, including this project.  To let it write a'#10 +
      'directory of your own, run: icacls <dir> /setintegritylevel ' +
      '(OI)(CI)L'#10'To turn the sandbox off for this session: /sandbox off'
  else
    Result := 'the sandbox is at "limits": children run in a job object ' +
      'capped at ' + IntToStr(MaxChildProcesses) + #10'processes, with no ' +
      'clipboard read and no desktop changes.  To turn it off for this'#10 +
      'session: /sandbox off';
end;

{ ----------------------------------------------------------------- teardown -- }

procedure SandboxShutdown;
begin
  if LowTok <> 0 then
  begin
    CloseHandle(LowTok);
    LowTok := 0;
  end;
  LowTokTried := False;
  EnvCache := '';
  EnvCacheValid := False;
  ScratchDir := '';
end;

end.
