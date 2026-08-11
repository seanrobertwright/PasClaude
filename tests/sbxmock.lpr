{ sbxmock - a stand-in child, built by test.cmd into bin\sbxmock.exe.

  It exists because two of the sandbox's claims cannot be observed from the
  process that set them up.  "A child in this job is refused breakaway" and
  "the process cap is enforced" are both statements about what CreateProcess
  returns to somebody already inside the job, and the only way to read that
  return value is to be there.  A test that checked the flag word instead
  would be asserting that we typed the constant we meant to type, which is not
  the same claim and would pass just as happily if the constant did nothing.

  One binary, selected by argument:
    breakaway <out>   spawn a child with CREATE_BREAKAWAY_FROM_JOB and write
                      'ok=<0|1> err=<n>' to <out>
    fanout <n> <out>  attempt n spawns and write 'made=<k> err=<n>' to <out>

  Written against Windows and SysUtils only, and built WITHOUT -gh for the
  same reason srvmock is: it writes a small file the test then parses, and a
  heaptrc report is not something the parser is expecting.  Its exit code is
  not summed into any suite result - it is a fixture, not a suite. }
program sbxmock;

{$mode objfpc}{$H+}

uses Windows, SysUtils;

const
  CREATE_BREAKAWAY_FROM_JOB = $01000000;

procedure Put(const Path, Text: string);
var
  F: THandle;
  N: DWORD;
begin
  F := CreateFile(PChar(Path), GENERIC_WRITE, FILE_SHARE_READ, nil,
    CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if F = INVALID_HANDLE_VALUE then Exit;
  if Text <> '' then WriteFile(F, Text[1], Length(Text), N, nil);
  CloseHandle(F);
end;

{ Spawns Cmd.  A stock program rather than this one, so a failure to spawn
  cannot be confused with a failure to find ourselves on disk. }
function Spawn(const Cmd: string; Flags: DWORD; out Err: DWORD): Boolean;
var
  SI: STARTUPINFOA;
  PI: PROCESS_INFORMATION;
  Line: string;
begin
  Line := Cmd;
  UniqueString(Line);
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  FillChar(PI, SizeOf(PI), 0);
  Err := 0;
  Result := CreateProcess(nil, PChar(Line), nil, nil, False,
    Flags or CREATE_NO_WINDOW, nil, nil, SI, PI);
  if Result then
  begin
    { Left running: the point of the fanout case is how many exist AT ONCE,
      and a child that has already exited no longer counts against the cap. }
    CloseHandle(PI.hThread);
    CloseHandle(PI.hProcess);
  end
  else
    Err := GetLastError;
end;

var
  Mode, OutPath: string;
  Err: DWORD;
  Ok: Boolean;
  Want, Made, I: Integer;
  LastErr: DWORD;
begin
  Mode := ParamStr(1);

  if Mode = 'breakaway' then
  begin
    OutPath := ParamStr(2);
    Ok := Spawn('"' + SysUtils.GetEnvironmentVariable('ComSpec') +
      '" /C exit 0', CREATE_BREAKAWAY_FROM_JOB, Err);
    Put(OutPath, Format('ok=%d err=%d', [Ord(Ok), Err]));
    Halt(0);
  end;

  if Mode = 'fanout' then
  begin
    Want := StrToIntDef(ParamStr(2), 0);
    OutPath := ParamStr(3);
    Made := 0;
    LastErr := 0;
    { The children have to still be RUNNING to count: ActiveProcessLimit caps
      how many exist at once, and a child that has already exited frees its
      slot.  ping is the stock program that idles for a predictable few
      seconds without needing a shell to interpret it - one process per spawn,
      so the arithmetic against the cap is the obvious one.  They are left to
      the job: closing its handle reaps whatever is still alive. }
    for I := 1 to Want do
      if Spawn('ping -n 6 127.0.0.1', 0, Err) then Inc(Made)
      else LastErr := Err;
    Put(OutPath, Format('made=%d err=%d', [Made, LastErr]));
    Halt(0);
  end;

  Halt(2);
end.
