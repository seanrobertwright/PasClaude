{ uArgs - the command line, as a decision instead of a side effect.

  Everything this unit does used to happen inside pasclaude.lpr's main block,
  and that one fact is why it exists.  No suite can link a program, so every
  decision made between `begin` and the first `Halt` was verified by running
  the executable and reading the console with human eyes.  Three separate
  rounds recorded the consequence as a residual and moved on: --continue's
  four refusals, whether --no-project-context was seen at all, and which
  TDiagMode values count as a --ci verb were all described in comments
  elsewhere as "main-block code no suite can link".  They were right, and the
  answer was never a better comment.  The answer is to move the DECISIONS out
  and leave the EFFECTS behind.

  So ArgsParse takes an array of string and returns a record.  It is not
  passed ParamStr or ParamCount and cannot reach them meaningfully - taking
  the arguments as data is the whole seam, and a version of this that read
  argv itself with an injectable hook would be a global to set and restore in
  a finally, for a function that has no reason to own any state at all.

  THE HARD RULE, and it is the unit's entire value: ArgsParse writes no
  global, prints nothing, halts nothing and opens nothing.  A refusal comes
  back IN the record - Ok is False and ErrMsg/ErrHint/ErrCode say what and why
  - and the host is what calls FailStart, which is what prints, shuts the
  sandbox down and halts.  The day a parse decision wants to touch the disk it
  does not go in here; it goes below the host's call, where the disk already
  starts (DirectoryExists, SetCurrentDir, AddWorkingDir, ResolveInRoot,
  SetOutputStyle - all of them still in the .lpr, all of them still verified
  by hand).

  WHY THIS IS THE TOP UNIT, above uSdk and uCi.  The record has to name a
  uSdk.TSdkFormat (--output-format) and a uCi.TCiFloor (--ci-allow) in the
  same record, and the refusals for both have to be phrased here or they stay
  in the main block, which is the code this unit exists to make testable.
  uSdk and uCi are peers: neither can see the other, and giving either one a
  dependency on the other would be a brand new edge at the top of the ladder -
  in uSdk's case one that also drags uDiag and uAgent into examples\embed.lpr,
  whose "SysUtils and uSdk and nothing else" claim build.cmd exists to
  protect.  So no existing unit can host this, and the ladder did not merely
  permit this design, it forced it.

  NOTHING IN src\ MAY EVER `uses uArgs` EXCEPT pasclaude.lpr.  Being the last
  unit a suite can still link is the point; a unit below reaching up for it
  would cycle and fail to compile, which is the good outcome, but the rule is
  written here so nobody has to discover it that way. }
unit uArgs;

{$mode objfpc}{$H+}

interface

uses SysUtils, uTools, uSandbox, uSdk, uCi;

type
  { --status and --doctor as top-level modes.  An enum set by exactly ONE
    thing - ArgsParse, below - and that is load-bearing: it is the single
    condition under which the missing-credential and missing-winhttp refusals
    in the host become recorded notes instead of a startup halt, and the
    branch it selects ends in Halt with no path past it to the REPL.  Nothing
    in a file, an environment variable or a settings key can reach it.

    It used to be declared in pasclaude.lpr beside the variable holding it,
    with a comment saying the same thing; the difference now is that the thing
    which sets it can be linked, so "set only in the argument loop" is an
    assertion a suite makes rather than a claim a reader takes on trust.

    The two --ci verbs join the enum rather than becoming a mode of their
    own, and that inheritance is the whole reason the host diff for CI is
    sixty lines: they get the refusals ("cannot be combined with -p, a
    prompt, --resume or a driver"), the one relaxation that lets a run
    continue past a missing credential - safe only because the branch ends in
    Halt - and the skipped MCP connect, approvals load and session backup,
    all of which a run with nobody at the console must not do. }
  TDiagMode = (dmNone, dmStatus, dmDoctor, dmCiPrepare, dmCiReport);

  { Everything argv decided, and nothing it did.  Each field is named for the
    host variable it is assigned into, so the apply half reads as a column of
    plain assignments and a reviewer can check it by eye - which matters,
    because the apply half is the part no suite can reach.

    Ok/ErrMsg/ErrHint/ErrCode are the refusal.  Every refusal in this program
    is exit code 2 today; the field exists anyway so that nothing downstream
    assumes it, and so a future exit code is a change in one place rather than
    a discovery in the host.

    PARTIAL STATE ON REFUSAL IS DELIBERATE AND LOAD-BEARING.  Parsing stops at
    the refusal, exactly where FailStart used to halt, so the fields set
    before it hold and the fields after it do not.  FailStart chooses red
    prose or one SdkErrorLine by reading the output format, so
    "--output-format json --bogus" must come back with OutFormat = sfJson and
    "--bogus --output-format json" must come back with sfText.  Both are what
    the program does today, and both are pinned in smoke. }
  TArgsOpts = record
    Ok: Boolean;
    ErrMsg: string;
    ErrHint: string;
    ErrCode: Integer;
    { --help/-h//? asked for the help text.  The text itself stays in the
      host: it is output, not a decision, and a hundred and thirty EmitCLn
      lines in here would be strings no assertion ever reads.  Parsing stops
      the instant it is seen, so "--help --bogus" still exits 0 and
      "--bogus --help" still exits 2. }
    Help: Boolean;
    Dir: string;
    PrintPrompt: string;
    StyleWanted: string;
    SessionFileArg: string;
    AppendSystem: string;
    Resume: Boolean;
    ContinueFlag: Boolean;
    WebFlag: Boolean;
    PrintMode: Boolean;
    ScriptedRun: Boolean;
    NoProjectContext: Boolean;
    ModeGiven: Boolean;
    PlanFlag: Boolean;
    BypassFlag: Boolean;
    SandboxGiven: Boolean;
    StreamInput: Boolean;
    DiagOnline: Boolean;
    ModeWanted: uTools.TPermMode;
    SandboxWanted: uSandbox.TSandboxLevel;
    OutFormat: uSdk.TSdkFormat;
    DiagMode: TDiagMode;
    AddDirs: TStringArray;
    CiInPath: string;
    CiPrPath: string;
    CiOutPath: string;
    CiTrigger: string;
    CiFloor: uCi.TCiFloor;
  end;

{ Every field explicitly, including the ones a zeroed record would already
  have right.  The record is returned by value into suites built with -gh:
  FPC initialises the managed fields of a function result and leaves the rest
  alone, so "it is False anyway" is true of a local today and not a promise
  the language makes about every call site tomorrow. }
function ArgsDefault: TArgsOpts;

{ argv in, decisions out.  Argv holds the arguments WITHOUT the program name -
  the host passes ParamStr(1)..ParamStr(ParamCount) - because a parser that
  had to remember to skip element zero would be a parser with an off-by-one
  waiting in it, and the tests would have to carry a dummy first element
  forever to reproduce the real thing. }
function ArgsParse(const Argv: array of string): TArgsOpts;

{ Whether a mode is one of the two GitHub Actions verbs.  One spelling of a
  question the host asked in five places as `DiagMode in [dmCiPrepare,
  dmCiReport]`, which is five chances to widen the set by one verb and no test
  anywhere that would notice.  uSdk.SdkProjectContextDecide's own comment
  named this as one of its two untestable inputs; it is a function with a
  truth table now, and this is the other half of closing that. }
function ArgsIsCiVerb(M: TDiagMode): Boolean;

implementation

function ArgsDefault: TArgsOpts;
begin
  Result.Ok := True;
  Result.ErrMsg := '';
  Result.ErrHint := '';
  Result.ErrCode := 0;
  Result.Help := False;
  Result.Dir := '';
  Result.PrintPrompt := '';
  Result.StyleWanted := '';
  Result.SessionFileArg := '';
  Result.AppendSystem := '';
  Result.Resume := False;
  Result.ContinueFlag := False;
  Result.WebFlag := False;
  Result.PrintMode := False;
  Result.ScriptedRun := False;
  Result.NoProjectContext := False;
  Result.ModeGiven := False;
  Result.PlanFlag := False;
  Result.BypassFlag := False;
  Result.SandboxGiven := False;
  Result.StreamInput := False;
  Result.DiagOnline := False;
  Result.ModeWanted := uTools.pmodeAsk;
  Result.SandboxWanted := uSandbox.slLimits;
  Result.OutFormat := uSdk.sfText;
  Result.DiagMode := dmNone;
  Result.AddDirs := nil;
  Result.CiInPath := '';
  Result.CiPrPath := '';
  Result.CiOutPath := '';
  Result.CiTrigger := uCi.CiDefaultTrigger;
  Result.CiFloor := uCi.cfCollaborator;
end;

function ArgsIsCiVerb(M: TDiagMode): Boolean;
begin
  Result := M in [dmCiPrepare, dmCiReport];
end;

function ArgsParse(const Argv: array of string): TArgsOpts;
var
  I: Integer;
  Arg, AddArg, Err, Joined, Why: string;
  SkipNext: Boolean;

  { The only way out of a refusal, and it is followed by Exit at every single
    site.  In the main block this was FailStart, which halted, so control
    could never continue past a refusal into the next flag; here nothing stops
    the loop but the Exit, and a missing one would let a later argument
    overwrite the message and let the run carry on where it used to die.
    smoke pins that discipline at three points - a refusal followed by --help,
    and the two --output-format orderings - rather than trusting the eye. }
  procedure Fail(const Msg, Hint: string; Code: Integer);
  begin
    Result.Ok := False;
    Result.ErrMsg := Msg;
    Result.ErrHint := Hint;
    Result.ErrCode := Code;
  end;

begin
  Result := ArgsDefault;
  AddArg := '';
  Err := '';
  Joined := '';
  Why := '';
  SkipNext := False;
  for I := 0 to High(Argv) do
  begin
    Arg := Argv[I];
    { The previous flag consumed this argument as its value.  A latch rather
      than a backwards look at Argv[I - 1], because there are now
      three flags that take a value and asking "was the one before me any of
      them" gets longer and wronger with each. }
    if SkipNext then
    begin
      SkipNext := False;
      Continue;
    end;
    if (Arg = '--resume') or (Arg = '-r') then
      Result.Resume := True
    { Claude Code's pair, and the same division of labour: --continue takes
      the most recent conversation and asks nothing, --resume is the one you
      reach for when you want to choose.  The shapes are not identical and
      pretending otherwise would be the lie: --resume here has always meant
      exactly this directory's session.json and still does, because changing
      what an existing flag loads is not a thing a new flag gets to do.  The
      choosing is /sessions, which was already the picker and is what --help
      points at. }
    else if (Arg = '--continue') or (Arg = '-c') then
      Result.ContinueFlag := True
    else if Arg = '--append-system-prompt' then
    begin
      if I >= High(Argv) then
      begin
        Fail('--append-system-prompt needs text', '', 2);
        Exit;
      end;
      { Refused at the door rather than truncated or ignored.  Every other
        way of getting this wrong - too long, empty - ends the run here with
        the reason, because the flag's whole job is to put words in the
        system prompt and a run that half-did that is a run whose replies
        cannot be explained.

        SdkAppendJoin rather than SdkAppendSystemPush, and that is the one
        place a pure parser had to change something outside itself: the push
        writes uSdk's module variable, which this function may not do.  The
        rule - the trim, the blank-line join, the cap measured on the TOTAL -
        is the same function in both, so the refusal a user sees for four
        thousand and one bytes is the same refusal in the same words, and it
        still arrives AT THE FLAG rather than after the whole line is read.
        That last part is why the values are not merely collected and pushed
        by the host: "--append-system-prompt <5KB> --bogus" reports the cap
        today, and deferring the join would have made it report the unknown
        option instead - a different refusal for the same command line. }
      if not uSdk.SdkAppendJoin(Result.AppendSystem, Argv[I + 1], Joined,
        Err) then
      begin
        Fail('--append-system-prompt: ' + Err,
          'it adds to the system prompt and can never replace it; put a ' +
          'long standing instruction in CLAUDE.md instead', 2);
        Exit;
      end;
      Result.AppendSystem := Joined;
      SkipNext := True;
    end
    else if Arg = '--web' then
      { Print mode leaves Ask nil, so nothing there can be approved
        interactively; without a flag a -p run could never search. }
      Result.WebFlag := True
    else if (Arg = '-p') or (Arg = '--print') then
    begin
      Result.PrintMode := True;
      Result.ScriptedRun := True;
      { A leading '-' means the next token is another flag, not this one's
        value.  Taking it unconditionally made every flag after -p unusable
        in the order --help showed: "-p --output-format json" sent
        '--output-format' to the model as the question and then died on
        'json' as a directory name, and "-p --web" quietly asked the model
        about the string '--web' with the web never enabled.  A prompt that
        genuinely starts with a dash is what -- style quoting is for, and is
        worth far less than flags that work in the documented order. }
      if (I < High(Argv)) and (Copy(Argv[I + 1], 1, 1) <> '-') then
      begin
        Result.PrintPrompt := Argv[I + 1];
        SkipNext := True;
      end;
    end
    else if Arg = '--permission-mode' then
    begin
      if I >= High(Argv) then
      begin
        Fail('--permission-mode needs a value: ask, plan or accept-edits',
          '', 2);
        Exit;
      end;
      if not uTools.PermModeParse(Argv[I + 1], Result.ModeWanted) then
      begin
        { Named explicitly, because a user who typed 'bypass' knows what
          they wanted and the only thing worth telling them is how it is
          spelled here.  It is not an alias: the long form is the whole
          defence against the mode arriving in a script by accident. }
        if LowerCase(Argv[I + 1]) = 'bypass' then
          Fail('bypass is spelled --dangerously-skip-permissions',
            'and it means it: nothing is asked about at all', 2)
        else
          Fail('unknown permission mode: ' + Argv[I + 1],
            'ask, plan or accept-edits', 2);
        Exit;
      end;
      Result.ModeGiven := True;
      Result.PlanFlag := Result.PlanFlag or
        (Result.ModeWanted = uTools.pmodePlan);
      SkipNext := True;
    end
    else if Arg = '--output-style' then
    begin
      if I >= High(Argv) then
      begin
        Fail('--output-style needs a name: default, explanatory, ' +
          'learning or one of your own', '', 2);
        Exit;
      end;
      Result.StyleWanted := Argv[I + 1];
      SkipNext := True;
    end
    else if Arg = '--sandbox' then
    begin
      if I >= High(Argv) then
      begin
        Fail('--sandbox needs a value: off, limits or low', '', 2);
        Exit;
      end;
      if not uSandbox.SandboxParseLevel(Argv[I + 1],
        Result.SandboxWanted) then
      begin
        Fail('unknown sandbox level: ' + Argv[I + 1], 'off, limits or low', 2);
        Exit;
      end;
      Result.SandboxGiven := True;
      SkipNext := True;
    end
    else if (Arg = '--add-dir') or (Copy(Arg, 1, 10) = '--add-dir=') then
    begin
      if Copy(Arg, 1, 10) = '--add-dir=' then
        AddArg := Copy(Arg, 11, MaxInt)
      else
      begin
        if I >= High(Argv) then
        begin
          Fail('--add-dir needs a directory', '', 2);
          Exit;
        end;
        AddArg := Argv[I + 1];
        SkipNext := True;
      end;
      SetLength(Result.AddDirs, Length(Result.AddDirs) + 1);
      Result.AddDirs[High(Result.AddDirs)] := AddArg;
    end
    { Beside --add-dir because they answer the same question from opposite
      ends: one says what this tree may REACH, this one says what this tree
      may SAY.  A plain boolean with no value and no = form - --add-dir has
      one because a path is what people paste, and there is nothing here to
      paste or to validate.  It is refused against no other flag either: it
      is meaningful in the REPL, under -p, and redundantly under a --ci
      verb, and this program refuses combinations that are dangerous or
      meaningless rather than ones that are merely unusual. }
    else if Arg = '--no-project-context' then
      Result.NoProjectContext := True
    else if Arg = '--status' then
      Result.DiagMode := dmStatus
    else if Arg = '--doctor' then
      Result.DiagMode := dmDoctor
    else if Arg = '--online' then
      Result.DiagOnline := True
    { The six GitHub Actions flags.  Every value is a path or a fixed word;
      none of them can carry comment text, because the workflow never
      interpolates a github.event expression into a command line at all -
      the
      event reaches this program as a FILE it opens itself. }
    else if Arg = '--ci' then
    begin
      if I >= High(Argv) then
      begin
        Fail('--ci needs a value: prepare or report', '', 2);
        Exit;
      end;
      if Argv[I + 1] = 'prepare' then
        Result.DiagMode := dmCiPrepare
      else if Argv[I + 1] = 'report' then
        Result.DiagMode := dmCiReport
      else
      begin
        Fail('unknown --ci verb: ' + Argv[I + 1], 'prepare or report', 2);
        Exit;
      end;
      SkipNext := True;
    end
    else if Arg = '--ci-in' then
    begin
      if I >= High(Argv) then
      begin
        Fail('--ci-in needs a path', '', 2);
        Exit;
      end;
      Result.CiInPath := Argv[I + 1];
      SkipNext := True;
    end
    else if Arg = '--ci-pr' then
    begin
      if I >= High(Argv) then
      begin
        Fail('--ci-pr needs a path', '', 2);
        Exit;
      end;
      Result.CiPrPath := Argv[I + 1];
      SkipNext := True;
    end
    else if Arg = '--ci-out' then
    begin
      if I >= High(Argv) then
      begin
        Fail('--ci-out needs a path', '', 2);
        Exit;
      end;
      Result.CiOutPath := Argv[I + 1];
      SkipNext := True;
    end
    else if Arg = '--ci-trigger' then
    begin
      if I >= High(Argv) then
      begin
        Fail('--ci-trigger needs a phrase', '', 2);
        Exit;
      end;
      Result.CiTrigger := Argv[I + 1];
      { Why rather than the --add-dir scratch string the main block reused for
        this out parameter.  Nothing depended on the reuse - AddArg is always
        written before it is read - and one variable that is sometimes a
        directory and sometimes an error message is the kind of thrift that
        survives until the day it does not. }
      if not uCi.CiTriggerValid(Result.CiTrigger, Why) then
      begin
        Fail('--ci-trigger: ' + Why, '', 2);
        Exit;
      end;
      SkipNext := True;
    end
    else if Arg = '--ci-allow' then
    begin
      if I >= High(Argv) then
      begin
        Fail('--ci-allow needs a value: collaborator, member or owner',
          '', 2);
        Exit;
      end;
      { It narrows and only narrows.  There is deliberately no flag that
        widens the association gate: a workflow that could be told to answer
        anybody is the failure this whole feature is designed against. }
      if not uCi.CiFloorParse(Argv[I + 1], Result.CiFloor) then
      begin
        Fail('unknown --ci-allow value: ' + Argv[I + 1],
          'collaborator (the default), member or owner', 2);
        Exit;
      end;
      SkipNext := True;
    end
    else if Arg = '--dangerously-skip-permissions' then
    begin
      Result.ModeWanted := uTools.pmodeBypass;
      Result.ModeGiven := True;
      Result.BypassFlag := True;
    end
    else if Arg = '--output-format' then
    begin
      if I >= High(Argv) then
      begin
        Fail('--output-format needs a value: text, json or stream-json',
          '', 2);
        Exit;
      end;
      if not uSdk.SdkParseFormat(Argv[I + 1], Result.OutFormat) then
      begin
        Fail('unknown output format: ' + Argv[I + 1],
          'text, json or stream-json', 2);
        Exit;
      end;
      { A protocol on stdout is a driver, not a person: the interactive
        credential commands refuse there for the same reason the permission
        prompt does. }
      if Result.OutFormat <> uSdk.sfText then Result.ScriptedRun := True;
      SkipNext := True;
    end
    else if Arg = '--session-file' then
    begin
      if I >= High(Argv) then
      begin
        Fail('--session-file needs a path', '', 2);
        Exit;
      end;
      Result.SessionFileArg := Argv[I + 1];
      SkipNext := True;
    end
    else if Arg = '--input-format' then
    begin
      if I >= High(Argv) then
      begin
        Fail('--input-format needs a value: text or stream-json', '', 2);
        Exit;
      end;
      if Argv[I + 1] = 'text' then
        Result.StreamInput := False
      else if Argv[I + 1] = 'stream-json' then
        Result.StreamInput := True
      else
      begin
        Fail('unknown input format: ' + Argv[I + 1], 'text or stream-json', 2);
        Exit;
      end;
      SkipNext := True;
    end
    else if (Arg = '--help') or (Arg = '-h') or (Arg = '/?') then
    begin
      { The text is the host's - see TArgsOpts.Help.  The Exit is what the
        Halt(0) used to be: nothing after --help on the line is looked at, so
        "--help --bogus" is still a help screen and exit 0. }
      Result.Help := True;
      Exit;
    end
    else if Copy(Arg, 1, 1) = '-' then
    begin
      Fail('unknown option: ' + Arg, '', 2);
      Exit;
    end
    else
      Result.Dir := Arg;
  end;
  { The formats only mean anything on the one-shot path.  Refusing rather
    than ignoring, because a driver that mistyped its invocation would
    otherwise sit waiting for a protocol nobody is speaking. }
  if not Result.PrintMode then
  begin
    { --status and --doctor are the exception, and a deliberate one: a
      driver that can ask "am I healthy" and parse the answer is worth
      more than one that scrapes prose, and these two modes answer without
      a turn ever happening. }
    if (Result.OutFormat <> uSdk.sfText) and (Result.DiagMode = dmNone) then
    begin
      Fail('--output-format needs -p, --status or --doctor', '', 2);
      Exit;
    end;
    if Result.StreamInput then
    begin
      Fail('--input-format needs -p', '', 2);
      Exit;
    end;
    { Interactive already has /resume and the session picker.  A second way
      to name the same file is a second thing to keep consistent with the
      first, so it is refused rather than quietly honoured. }
    if Result.SessionFileArg <> '' then
    begin
      Fail('--session-file needs -p',
        'interactive sessions use /resume and the session picker', 2);
      Exit;
    end;
  end;
  { The load-bearing refusal.  Defaulting to SessionPath(RootDir) here is
    exactly what -p has always declined to do: a scripted run must name the
    conversation it continues, and the directory's saved session is left
    alone unless somebody types its path. }
  if Result.Resume and Result.PrintMode and (Result.SessionFileArg = '') then
  begin
    Fail('--resume under -p needs --session-file <path>',
      'a scripted run must name the conversation it continues; the ' +
      'directory''s saved session is left alone', 2);
    Exit;
  end;
  { And --continue is refused under -p outright, with no --session-file
    escape, because it is a STRONGER version of the thing the refusal above
    exists for: --resume at least names one fixed file, where this one takes
    whichever transcript happens to have been written last.  A script that
    continued "the most recent conversation" would continue a different one
    depending on what the user did in the REPL an hour ago, which is not
    something a scripted run can be said to have chosen.  --session-file is
    the answer under -p, and it is what the message says. }
  if Result.ContinueFlag and Result.PrintMode then
  begin
    Fail('--continue is interactive; under -p name the transcript',
      'use --session-file <path>, optionally with --resume: a scripted run ' +
      'must not depend on which conversation was saved last', 2);
    Exit;
  end;
  { Contradictory rather than ordered, exactly as --permission-mode plan and
    --dangerously-skip-permissions are.  They load DIFFERENT files - one the
    directory's session.json, the other whichever save is newest - so either
    precedence would be a guess about which conversation the user meant, and
    the wrong guess silently continues the wrong one. }
  if Result.Resume and Result.ContinueFlag then
  begin
    Fail('--resume and --continue name different conversations',
      '--resume loads this directory''s saved session, --continue loads ' +
      'whichever was written last; pick one', 2);
    Exit;
  end;
  if Result.StreamInput and (Result.OutFormat <> uSdk.sfStreamJson) then
  begin
    Fail('--input-format stream-json needs --output-format stream-json',
      'a driver that sends messages has to be able to read the answers', 2);
    Exit;
  end;
  { A mode that cannot work under -p is a startup error rather than a quiet
    downgrade: a script that asked to stop being prompted and was silently
    given the prompting mode would fail later, in the middle of the work,
    with a refusal that looks like a bug. }
  if Result.PrintMode and not uTools.PermModeReachableUnderPrint(
    Result.ModeWanted, Result.PrintMode and Result.StreamInput) then
  begin
    Fail('--permission-mode ' + uTools.PermModeName(Result.ModeWanted) +
      ' needs somebody to accept: -p has nobody',
      'attach a driver with --input-format stream-json, or say' +
      ' --dangerously-skip-permissions and mean it', 2);
    Exit;
  end;
  { Contradictory rather than ordered.  Either precedence would be a guess
    about which flag the user meant, and both guesses are dangerous: one
    silently plans nothing, the other silently approves everything. }
  if Result.PlanFlag and Result.BypassFlag then
  begin
    Fail('--permission-mode plan and --dangerously-skip-permissions '
      + 'contradict each other', 'pick one', 2);
    Exit;
  end;
  { The refusals that keep the diagnostic relaxation honest.  --status and
    --doctor continue past a missing credential and past a missing
    winhttp.dll, because a doctor that exits saying "ANTHROPIC_API_KEY is
    not set" instead of listing that as one problem among thirteen is the
    riddle the whole feature exists to avoid.  That is only safe because
    the mode structurally cannot run a turn or a tool - so it must not be
    combinable with anything that can. }
  if Result.DiagMode <> dmNone then
  begin
    if Result.PrintMode then
    begin
      Fail('--status, --doctor and --ci cannot be combined with -p',
        'they are modes of their own: run them alone', 2);
      Exit;
    end;
    { UNREACHABLE TODAY, and kept anyway - one of exactly two refusals in this
      unit that no argument list can produce, and the only two smoke does not
      assert verbatim.  PrintPrompt is written in one place, the -p branch,
      which sets PrintMode on the line above it, so a non-empty prompt always
      trips the refusal directly above this one first.  What smoke pins
      instead is that ordering: '--doctor -p hi' comes back with the -p
      message, and if the two ever swapped that Check would fail.

      Deleted, rather than left standing, would be the tidier diff and the
      wrong call: this is the guard for a FUTURE flag that fills PrintPrompt
      without implying -p, and rediscovering that a diagnostic mode must
      refuse a prompt is a worse cost than four lines that cannot run.  It is
      named as unreachable here, and counted as unreachable in README, so
      nobody has to prove it twice. }
    if Trim(Result.PrintPrompt) <> '' then
    begin
      Fail('--status, --doctor and --ci take no prompt', '', 2);
      Exit;
    end;
    { Both flags, and for the one reason: whichever transcript is loaded,
      it changes the message count, the token counters and the model the
      report would print. }
    if Result.Resume or Result.ContinueFlag then
    begin
      Fail('--status, --doctor and --ci cannot be combined with ' +
        '--resume or --continue',
        'they report on a fresh session, and loading a transcript would ' +
        'change what they report', 2);
      Exit;
    end;
    { The second unreachable one, for the mirror-image reason, and it is worth
      following through because the shape is not obvious.  StreamInput without
      -p is refused far above by '--input-format needs -p'; StreamInput WITH
      -p never gets here, because the -p refusal a few lines up fires first.
      So both ways in are closed, and again the property smoke pins is the
      order: '--status --input-format stream-json' comes back with
      '--input-format needs -p', which is the assertion that would fail the
      day somebody hoists this block above the not-PrintMode one. }
    if Result.StreamInput then
    begin
      Fail('--status, --doctor and --ci cannot be combined with ' +
        '--input-format stream-json', '', 2);
      Exit;
    end;
  end;
  { The two CI verbs take their own flags and refuse the driver formats:
    what they write is a prompt file and a comment file, and their stdout
    is a build log a person reads.  A JSON protocol there would be a second
    contract to keep, for a caller that is a YAML step. }
  if ArgsIsCiVerb(Result.DiagMode) then
  begin
    if Result.OutFormat <> uSdk.sfText then
    begin
      Fail('--ci cannot be combined with --output-format',
        'it writes files named by --ci-out; stdout is the build log', 2);
      Exit;
    end;
    if Result.CiInPath = '' then
    begin
      Fail('--ci needs --ci-in <path>',
        'prepare reads the event payload (%GITHUB_EVENT_PATH%); report ' +
        'reads one line of --output-format json', 2);
      Exit;
    end;
    if Result.CiOutPath = '' then
    begin
      Fail('--ci needs --ci-out <path>',
        'prepare writes the prompt there; report writes the comment', 2);
      Exit;
    end;
    if (Result.DiagMode = dmCiReport) and (Result.CiPrPath <> '') then
    begin
      Fail('--ci-pr belongs to --ci prepare', '', 2);
      Exit;
    end;
  end
  else if (Result.CiInPath <> '') or (Result.CiOutPath <> '') or
          (Result.CiPrPath <> '') then
  begin
    Fail('the --ci-* flags need --ci prepare or --ci report', '', 2);
    Exit;
  end;
  if Result.DiagOnline and (Result.DiagMode <> dmDoctor) then
  begin
    Fail('--online needs --doctor',
      'it is the opt-in for the one check that makes a request', 2);
    Exit;
  end;
  { And that is the end of the decisions.  What the host does next -
    DirectoryExists on Dir, SetCurrentDir, AddWorkingDir for every AddDirs
    entry, ResolveInRoot on the session file, SetOutputStyle - is where the
    disk starts, and a pure function stops being pure there. }
end;

end.
