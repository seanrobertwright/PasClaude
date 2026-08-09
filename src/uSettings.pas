{ uSettings - the hierarchical settings file, and the one table that decides
  what a project directory is allowed to say.

  Three files, one shape:

      %USERPROFILE%\.pasclaude\settings.json       user
      <root>\.pasclaude\settings.json              project
      <root>\.pasclaude\settings.local.json        local

  Nearer wins, per key: local -> project -> user -> compiled default.  That is
  the rule ScanSkillDir already uses for skills, styles, commands and agents
  ("the first source to offer a name keeps it"), and a ninth configuration
  surface inventing an opposite one is how a program becomes impossible to
  reason about.  A user who wants out from under a project value writes the
  local file; the hierarchy is not inverted to give them that.

  The central question this unit answers is not "what format" but "what may a
  cloned repository decide".  Three rounds of work moved standing approvals out
  of the project tree, kept deny rules from ever being read from it, and put
  keybindings in %USERPROFILE% so that "a git clone cannot choose what your
  keyboard does".  A settings.json with a project tier is that entire hole
  reopened unless the answer to "may a project set this" is a property of a
  data structure rather than of a reviewer's memory.

  So: SettingDefs is the table, Scope is the column, TierAllowed is the
  question, and SettingsStore is the ONLY procedure that writes a value.  A
  value at a tier its def does not permit is never stored - not stored and then
  overridden, never stored.  There is no `if` anywhere else to forget.  The
  charter is one sentence: keys that change display and economy, plus
  user-scope-only keys that change model and outbound metrics; nothing that
  changes authority.

  Refused names are in the same table for a different reason.  The realistic
  failure is a user pasting Claude Code's settings.json and believing it took
  effect; silence there is worse than any wrong default, so every name they
  would plausibly paste is present and produces a sentence naming the file
  that really owns it.

  Keys are literal flat strings.  "model.alias" is a key whose name contains a
  dot, not an object to walk into: there is no nested traversal in this loader
  and no code path that descends an unknown object.

  uses uJson, SysUtils, Classes and nothing else.  It never learns a path -
  SettingsParseTier takes BYTES, exactly as uTerm.KeysParse does, so every
  suite can drive it with no filesystem and no unit below it can be tempted to
  reach up.  It never touches uTerm and never prints. }
unit uSettings;

{$mode objfpc}{$H+}

interface

uses SysUtils, uJson;

type
  { The tier ladder, lowest authority first.  stLocal sits beside stProject in
    AUTHORITY and merely ahead of it in PRECEDENCE.  That distinction is the
    single most important line in this unit: settings.local.json is gitignored
    by convention, and .gitignore is a convention rather than a guard - a
    repository can simply commit one.  Treating the local tier as user scope
    because of its filename would hand a clone back everything three rounds of
    work took away from it.  TestSettingsLocalHasProjectAuthority exists to
    make that "improvement" fail. }
  TSettingTier = (stDefault, stUser, stProject, stLocal, stRuntime);

  { scAny      - any tier may set it.  Display and economy only.
    scUserOnly - the user file only; a project-class value is refused by name.
    scRefused  - honoured at NO tier, including the user one.  Present solely
                 so a pasted Claude Code key produces a sentence. }
  TSettingScope = (scAny, scUserOnly, scRefused);

  TSettingKind = (skBool, skInt, skStr, skMap);

  { Shape checks that a Lo..Hi range cannot express.  Table-driven for the same
    reason the scope is: a validation written at the call site is a validation
    somebody adds a key without. }
  TSettingShape = (shNone, shEndpoint, shServiceName, shHeaderMap, shAliasMap,
    { 0 or at least 1024, nothing between.  The API's own floor is 1024 and it
      REJECTS a smaller budget, so a thinking_budget of 512 in a project file
      was every turn in that checkout failing with an HTTP 400 - a loader
      whose stated contract is that a hostile project file can never stop the
      program, stopping it.  0 stays legal because 0 means off. }
    shThinkBudget,
    { An absolute path to a program a slash command will START.  Drive letter
      or UNC prefix, extension in .cmd/.bat/.exe, printable ASCII 32..126 and
      no '"'.  Absolute is the load-bearing half: a relative path resolves
      against the process's current directory, which is the session root, so
      without it a checked-in ide.command could name a file in the repository
      even before the scope column was consulted. }
    shIdeCommand);

  { Which direction of a number costs the user money.  The narrow-only rule is
    stated against the value the USER has in force, and this column says which
    way "narrow" points; without it the rule cannot be written down, and what
    was written instead - a comparison against the def's own Hi - was not the
    rule at all. }
  TSettingCheap = (chNone, chLower, chHigher);

  TSettingDef = record
    Name: string;
    Kind: TSettingKind;
    Scope: TSettingScope;
    Lo, Hi: Integer;        { skInt range; ignored otherwise }
    { Absolute ceiling for a project-class tier; 0 means "same as Hi".  It is
      a cap and NOT the invariant: the invariant is Dflt/Cheap below, and a
      value that satisfies this one still has to satisfy that one. }
    ProjMax: Integer;
    { What this program does when NO file names the key - the compiled default,
      copied here because a project-class tier is measured against the user's
      position and the user's position is this number until they write it down.
      Comparing against Hi instead let a cloned repository turn extended
      thinking on from a compiled 0 and more than double the tool result cap,
      both of which the table's own comment said were impossible.  A test pins
      each of these to the constant it duplicates. }
    Dflt: Integer;
    Cheap: TSettingCheap;
    Shape: TSettingShape;
    { scRefused: the sentence the user reads, naming the file that owns it.
      Other scopes: a short description for /config. }
    Note: string;
  end;

const
  SettingsFileName      = 'settings.json';
  SettingsLocalFileName = 'settings.local.json';

  { A settings document larger than this is refused whole.  Every one of these
    files is hand-authored and the largest plausible one is a few kilobytes;
    the cap exists so a project file cannot turn startup into a parse of a
    multi-megabyte document before anything else has run. }
  MaxSettingsBytes = 256 * 1024;

  { Fourteen real keys, four of which a project may set, plus every name a
    user might paste out of Claude Code's settings.json.  Growing this table
    is the natural way to add a setting, which is exactly why the Scope column
    has to be filled in at the same moment: the load position (above the
    print-mode halt) is legal ONLY because nothing here can grant. }
  SettingCount = 44;
  SettingDefs: array[0..SettingCount - 1] of TSettingDef = (
    { ---- scAny: display and economy.  A project may set these. ---- }
    (Name: 'output_style'; Kind: skStr; Scope: scAny;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'name of an output style; the same trust class as CLAUDE.md'),
    { Dflt 0: TAgent.Create never assigns FThinkingBudget, so thinking is OFF
      until somebody asks for it.  chLower therefore means a project-class file
      can say nothing but 0 unless the USER turned thinking on first. }
    (Name: 'thinking_budget'; Kind: skInt; Scope: scAny;
     Lo: 0; Hi: 32768; ProjMax: 8192; Dflt: 0; Cheap: chLower;
     Shape: shThinkBudget;
     Note: 'extended thinking budget in tokens'),
    { Dflt 30720: uTools.MaxOutBytes, and TestSettingDefaultsMatchTheProgram
      fails the build if the two ever disagree. }
    (Name: 'tool_result_bytes'; Kind: skInt; Scope: scAny;
     Lo: 4096; Hi: 131072; ProjMax: 65536; Dflt: 30720; Cheap: chLower;
     Shape: shNone;
     Note: 'cap on any single tool result'),
    { The one key whose cheap direction is UP.  Compaction is not free: each
      firing is an extra billed request that summarises the transcript, so a
      project file setting 20000 makes nearly every turn in a long session pay
      for one.  A project may therefore push the compaction point later and
      never earlier, and ProjMax still caps how much later. }
    (Name: 'auto_compact_tokens'; Kind: skInt; Scope: scAny;
     Lo: 20000; Hi: 180000; ProjMax: 150000; Dflt: 150000; Cheap: chHigher;
     Shape: shNone;
     Note: 'prompt size at which the transcript is trimmed'),

    { ---- scUserOnly: the model.  A project setting this spends the user's
      money on the project's say-so, and worse, can silently downgrade the
      reviewer of its own code.  That is a sabotage vector, not a billing
      inconvenience, and there is deliberately no fingerprint-and-prompt path
      the way hooks.json has one: hook trust is a one-time question about a
      bounded set of commands the user can read, model choice is unbounded and
      recurring. ---- }
    (Name: 'model'; Kind: skStr; Scope: scUserOnly;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'preferred model; ANTHROPIC_MODEL and /model both beat it'),
    (Name: 'model.alias'; Kind: skMap; Scope: scUserOnly;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shAliasMap;
     Note: 'short names for models'),
    (Name: 'model.route.subagent'; Kind: skStr; Scope: scUserOnly;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'model the task tool uses'),
    (Name: 'model.route.compaction'; Kind: skStr; Scope: scUserOnly;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'model that writes the compaction summary'),

    { ---- scUserOnly: telemetry.  Outbound by definition, so the endpoint is
      the one field a project directory must never reach: a project-settable
      telemetry URL is an exfiltration channel wearing a respectable name.
      User scope only is what makes the load position above the print-mode
      halt safe for these too. ---- }
    (Name: 'telemetry.enabled'; Kind: skBool; Scope: scUserOnly;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'send metrics; off unless both this and the endpoint are set'),
    (Name: 'telemetry.endpoint'; Kind: skStr; Scope: scUserOnly;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shEndpoint;
     Note: 'OTLP/HTTP endpoint; https, or http for loopback only'),
    (Name: 'telemetry.headers'; Kind: skMap; Scope: scUserOnly;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shHeaderMap;
     Note: 'extra request headers for the endpoint'),
    (Name: 'telemetry.interval_turns'; Kind: skInt; Scope: scUserOnly;
     Lo: 1; Hi: 100; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'turns between flushes'),
    (Name: 'telemetry.timeout_ms'; Kind: skInt; Scope: scUserOnly;
     Lo: 250; Hi: 5000; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'how long a flush may block'),
    (Name: 'telemetry.service_name'; Kind: skStr; Scope: scUserOnly;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shServiceName;
     Note: 'service.name resource attribute'),

    { ---- scUserOnly: the editor.  ide.command NAMES A PROGRAM THAT A SLASH
      COMMAND STARTS, which makes it the highest-authority string in this
      table after the model: a repository that could set it would have a
      cloned checkout launching any executable on the machine the first time
      somebody typed /ide.  That is the same shape of hole as a project-
      settable telemetry endpoint and it gets the same answer.  ide.enabled
      is user scope for the smaller reason that it gates the command that
      reads the other one. ---- }
    { Dflt 1: uIde.IdeEnabledDefault is True, and
      TestSettingDefaultsMatchTheProgram fails the build if the two drift. }
    (Name: 'ide.enabled'; Kind: skBool; Scope: scUserOnly;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 1; Cheap: chNone; Shape: shNone;
     Note: 'let /ide open files and diffs in a detected editor'),
    (Name: 'ide.command'; Kind: skStr; Scope: scUserOnly;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shIdeCommand;
     Note: 'absolute path to the editor command-line program; only ' +
       'consulted once an editor has already been detected'),

    { ---- scRefused.  Every one of these is a key somebody will paste from
      Claude Code's settings.json.  Honoured at no tier; each says where the
      thing it names actually lives. ---- }
    (Name: 'permissions'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'permissions are answered by you, per tool, and recorded outside ' +
       'the project tree; no file in a repository can grant one'),
    (Name: 'allow_edits'; Kind: skBool; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'standing approvals live in the approvals file under ' +
       '%LOCALAPPDATA%\pasclaude; answer the prompt with "a"'),
    (Name: 'allow_bash'; Kind: skBool; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'standing approvals live in the approvals file under ' +
       '%LOCALAPPDATA%\pasclaude; answer the prompt with "a"'),
    (Name: 'allow_fetch'; Kind: skBool; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'standing approvals live in the approvals file under ' +
       '%LOCALAPPDATA%\pasclaude; answer the prompt with "a"'),
    (Name: 'bash_programs'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'approved bash programs are recorded when you answer "a", in the ' +
       'approvals file under %LOCALAPPDATA%\pasclaude'),
    (Name: 'trusted'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'trust fingerprints are recorded in the approvals file under ' +
       '%LOCALAPPDATA%\pasclaude when you answer a trust prompt'),
    (Name: 'deny'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'deny rules come from %LOCALAPPDATA%\pasclaude\deny.json and the ' +
       'approvals file only; /deny add <rule>'),
    (Name: 'sandbox'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'the sandbox level comes from --sandbox or /sandbox, never a file ' +
       'in a repository'),
    (Name: 'permission_mode'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'the permission mode comes from --permission-mode or /mode, never ' +
       'a file in a repository'),
    (Name: 'add_dir'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'reach comes from --add-dir or /add-dir, never a file'),
    (Name: 'additionalDirectories'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'reach comes from --add-dir or /add-dir, never a file'),
    (Name: 'env'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'pasclaude never sets environment variables for you; a file that ' +
       'could would be choosing what every child process sees'),
    (Name: 'apiKey'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'the credential comes from ANTHROPIC_API_KEY or a Claude ' +
       'subscription; no settings key names one'),
    (Name: 'apiKeyHelper'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'the credential comes from ANTHROPIC_API_KEY or a Claude ' +
       'subscription; no settings key runs a program to fetch one'),
    (Name: 'auth'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'the credential comes from ANTHROPIC_API_KEY or a Claude ' +
       'subscription; no settings key names one'),
    (Name: 'credential'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'the credential comes from ANTHROPIC_API_KEY or a Claude ' +
       'subscription; no settings key names one'),
    (Name: 'login'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'the credential comes from ANTHROPIC_API_KEY or a Claude ' +
       'subscription; no settings key names one'),
    (Name: 'mcpServers'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'MCP servers are declared in .mcp.json at the project root, where ' +
       'you can read them, and each spawn is approved by name'),
    (Name: 'plugins'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'plugin enablement lives in .pasclaude\plugins.json and is ' +
       'written by /plugins, in both directions'),
    (Name: 'vim'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'keybindings live in %USERPROFILE%\.pasclaude\keys.json only; a ' +
       'git clone cannot choose what your keyboard does'),
    (Name: 'bindings'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'keybindings live in %USERPROFILE%\.pasclaude\keys.json only; a ' +
       'git clone cannot choose what your keyboard does'),
    (Name: 'hooks'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'hooks live in .pasclaude\hooks.json, which is fingerprinted and ' +
       'trusted by hand; settings.json is not, so it may not carry them'),
    (Name: 'telemetry'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'the telemetry keys are dotted: telemetry.enabled, ' +
       'telemetry.endpoint and the rest, and all are user scope'),
    (Name: 'ide'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'the IDE keys are dotted: ide.enabled and ide.command, and both ' +
       'are user scope'),
    (Name: 'report_dir'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'a settable report path is somewhere for a diagnostic to be ' +
       'written that you did not choose; reports go under %LOCALAPPDATA%'),
    (Name: 'redact'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'redaction is not a switch a file may flip'),
    (Name: 'doctor'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'diagnostics are commands, not configuration'),
    (Name: 'bug'; Kind: skStr; Scope: scRefused;
     Lo: 0; Hi: 0; ProjMax: 0; Dflt: 0; Cheap: chNone; Shape: shNone;
     Note: 'diagnostics are commands, not configuration')
  );

function SettingIndex(const Name: string): Integer;      { -1 = unknown }
function SettingIsProjectClass(T: TSettingTier): Boolean;
function TierAllowed(const D: TSettingDef; T: TSettingTier): Boolean;
function TierName(T: TSettingTier): string;

{ Parse ONE tier from BYTES.  All or nothing: not valid JSON, not an object,
  an unknown key, a wrong type, an out-of-range int, a project-class value
  that moves a number away from where the USER has it in the direction that
  costs money, or a key at a tier it may not use, and the document
  contributes NOTHING.  Partial application is how a typo silently changes
  half a configuration.  False means nothing was stored and Problems is never
  empty; Label names the file in the problem text and is display only. }
function SettingsParseTier(Tier: TSettingTier; const Bytes, Where: string;
  out Problems: TStringArray): Boolean;

procedure SettingsClear;                                       { test seam }

{ Reads the three files and calls SettingsParseTier for each in tier order.
  Any path may be ''.  Absent is not a problem; unreadable is.  No console:
  the notes come back for the host to print in yellow beside BadDenyRules. }
procedure SettingsLoad(const UserPath, ProjectPath, LocalPath: string;
  out Notes: TStringArray);

{ Effective value after the local -> project -> user -> default walk, which
  STARTS at the def's lowest permitted tier - so for an scUserOnly key there
  is no code path that can even read a project value. }
function SettingStr(const Name: string): string;
function SettingInt(const Name: string): Integer;
function SettingBool(const Name: string): Boolean;
function SettingMap(const Name: string; out Keys, Values: TStringArray): Boolean;
function SettingIsSet(const Name: string): Boolean;
function SettingSource(const Name: string): TSettingTier;
{ '' when that tier did not set it; the value as written otherwise. }
function SettingTierValue(const Name: string; Tier: TSettingTier): string;

{ The host says when argv, an env var or a typed command has taken a key over,
  so /config reports the truth rather than the file. }
procedure SettingsSetRuntime(const Name, Value, SourceLabel: string);
function SettingRuntimeLabel(const Name: string): string;

{ True when a project-class tier supplied any of the economy keys.  The host
  says so at startup: a repository that quadrupled the cost of every tool
  result should not be discoverable only through /cost. }
function SettingsProjectEconomyNote: string;

{ Read-modify-write of ONE key in ONE file.  Every other key survives,
  including refused ones - the direct answer to SavePermissions' full rewrite,
  which destroys any key its loader does not understand.  Remove deletes.
  Refuses rather than clobbering when the file exists and does not parse. }
function SettingsWrite(const Path, Name, Value: string; Remove: Boolean;
  out Err: string): Boolean;

{ Rows for /config, tab-separated: name, effective value, tier word, shadowed
  summary.  Built here so the host only colours them.  Every field that came
  out of a file has had its control characters removed, the TAB among them:
  the separator is in the data's reach otherwise, and a value carrying one
  moves the tier word one field along. }
function SettingsReport: TStringArray;
{ Every refusal recorded during the last SettingsLoad, one sentence each. }
function SettingsRefusals: TStringArray;

implementation

uses Classes;

type
  TSettingSlot = record
    Present: Boolean;
    Value: string;             { as written, for /config and for skStr }
    IntVal: Integer;
    BoolVal: Boolean;
    MapKeys: TStringArray;     { skMap }
    MapVals: TStringArray;
  end;

var
  { The store.  Indexed [def, tier].  SettingsStore is the ONLY procedure that
    writes it, and that is the invariant worth auditing: a grep for
    SettingValues must show assignments in SettingsStore and in the reset
    beside it, and nowhere else.  A second writer is the bug this design
    exists to prevent.

    TierAllowed is the opposite case and the audit reads the other way round.
    It is asked three times - when a value is parsed, when it is stored, and
    when the effective tier is chosen - and every one of them REFUSES.  More
    call sites make a project value harder to smuggle in, not easier, so a
    reviewer counting them and deleting the "duplicates" would be removing
    the belt and the braces to tidy up the trousers.  What would be a defect
    is a path that stores or reads a value WITHOUT asking. }
  SettingValues: array[0..SettingCount - 1, TSettingTier] of TSettingSlot;
  RuntimeLabels: array[0..SettingCount - 1] of string;
  Refusals: TStringArray;
  EconomyNote: string = '';

function SettingIndex(const Name: string): Integer;
var
  I: Integer;
begin
  for I := 0 to SettingCount - 1 do
    if SettingDefs[I].Name = Name then Exit(I);
  Result := -1;
end;

function SettingIsProjectClass(T: TSettingTier): Boolean;
begin
  { stLocal is here, not with stUser.  See the comment on TSettingTier. }
  Result := (T = stProject) or (T = stLocal);
end;

{ The whole enforcement mechanism, and it has exactly one caller. }
function TierAllowed(const D: TSettingDef; T: TSettingTier): Boolean;
begin
  case D.Scope of
    scRefused: Result := False;
    scUserOnly: Result := (T = stUser) or (T = stRuntime);
  else
    Result := True;
  end;
end;

function TierName(T: TSettingTier): string;
begin
  case T of
    stUser: Result := 'user';
    stProject: Result := 'project';
    stLocal: Result := 'local';
    stRuntime: Result := 'runtime';
  else
    Result := 'default';
  end;
end;

{ Every string this unit hands out that came from a FILE goes through here
  first, and the reason is that one of those files is in the project tree.

  Two failures, both demonstrated: a key name of ESC[2J erased the yellow
  security block printed immediately above it and OSC 0 renamed the user's
  window, because uTerm writes a string through verbatim; and a TAB inside a
  value shifted every field of the tab-separated /config row after it, letting
  a project file dictate the tier word that /config, /status and /bug
  attribute its own value to.  Stripping control characters answers both at
  once, which is why it is one function and not two.

  Removed rather than escaped, exactly as uDiag.DiagClean does it - a report
  that says ^[ where the file said ESC is a report about a different file.
  The cap is on top: a 200KB one-line value is not a row, it is a way to push
  the rest of the screen out of the scrollback. }
function SettingClean(const S: string): string;
var
  I, N: Integer;
  T: string;
begin
  SetLength(T, Length(S));
  N := 0;
  for I := 1 to Length(S) do
    if S[I] >= ' ' then
    begin
      Inc(N);
      T[N] := S[I];
    end;
  SetLength(T, N);
  Result := Utf8Cut(T, 240);
end;

procedure NoteAdd(var A: TStringArray; const S: string);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)] := S;
end;

{ The only writer.  Everything else in this unit reads. }
procedure SettingsStore(Index: Integer; Tier: TSettingTier;
  const Raw: string; IntVal: Integer; BoolVal: Boolean;
  const MapKeys, MapVals: TStringArray);
begin
  if (Index < 0) or (Index >= SettingCount) then Exit;
  { Belt as well as braces: the parser has already asked, but a future caller
    that forgot would be storing a project value for a user-only key, which is
    the one failure this unit is built to make unreachable. }
  if not TierAllowed(SettingDefs[Index], Tier) then Exit;
  SettingValues[Index, Tier].Present := True;
  SettingValues[Index, Tier].Value := Raw;
  SettingValues[Index, Tier].IntVal := IntVal;
  SettingValues[Index, Tier].BoolVal := BoolVal;
  SettingValues[Index, Tier].MapKeys := MapKeys;
  SettingValues[Index, Tier].MapVals := MapVals;
end;

procedure SettingsClear;
var
  I: Integer;
  T: TSettingTier;
begin
  for I := 0 to SettingCount - 1 do
  begin
    for T := Low(TSettingTier) to High(TSettingTier) do
    begin
      SettingValues[I, T].Present := False;
      SettingValues[I, T].Value := '';
      SettingValues[I, T].IntVal := 0;
      SettingValues[I, T].BoolVal := False;
      SettingValues[I, T].MapKeys := nil;
      SettingValues[I, T].MapVals := nil;
    end;
    RuntimeLabels[I] := '';
  end;
  Refusals := nil;
  EconomyNote := '';
end;

{ ------------------------------------------------------------- validation -- }

{ https anywhere, http for loopback only.  An http endpoint on a real host
  would send metrics in clear over somebody else's network; loopback is the
  case a collector actually runs in, and the hosts-file caveat is documented
  rather than pretended away. }
function EndpointOk(const S: string; out Why: string): Boolean;
var
  Rest, Host: string;
  P: Integer;
begin
  Why := '';
  if Copy(S, 1, 8) = 'https://' then Exit(True);
  if Copy(S, 1, 7) <> 'http://' then
  begin
    Why := 'must begin with https://';
    Exit(False);
  end;
  Rest := Copy(S, 8, Length(S));
  P := Pos('/', Rest);
  if P > 0 then Rest := Copy(Rest, 1, P - 1);
  Host := Rest;
  P := Pos(':', Host);
  if P > 0 then Host := Copy(Host, 1, P - 1);
  Result := (LowerCase(Host) = 'localhost') or (Host = '127.0.0.1');
  if not Result then
    Why := 'http:// is accepted for 127.0.0.1 and localhost only';
end;

function ServiceNameOk(const S: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if (S = '') or (Length(S) > 64) then Exit;
  if not (S[1] in ['a'..'z', '0'..'9']) then Exit;
  for I := 2 to Length(S) do
    if not (S[I] in ['a'..'z', '0'..'9', '.', '_', '-']) then Exit;
  Result := True;
end;

{ The path of a program /ide will START.  Four independent requirements, none
  of which is sufficient alone:

  absolute - a drive letter or a \\ UNC prefix.  A relative path resolves
    against the current directory, which is the session root, so a relative
    ide.command would name a file in the repository.
  extension - .cmd, .bat or .exe.  Anything else is not a thing CreateProcess
    or cmd.exe will start, so accepting it would only defer the failure.
  printable ASCII 32..126 and no '"' - the same screen uIde applies before
    composing a command line, applied a second time here so a value that
    could never be launched is refused at the moment it is written rather
    than at the moment somebody types /ide.

  What this check does NOT do is decide whether the program is a reasonable
  one to run.  That is the Scope column's job, and it says user only. }
function IdeCommandOk(const S: string): Boolean;
var
  I: Integer;
  E: string;
begin
  Result := False;
  if (S = '') or (Length(S) > 512) then Exit;
  for I := 1 to Length(S) do
    if (S[I] < #32) or (S[I] > #126) or (S[I] = '"') then Exit;
  if not (((Length(S) > 2) and (S[1] in ['A'..'Z', 'a'..'z']) and
           (S[2] = ':') and (S[3] = '\')) or
          (Copy(S, 1, 2) = '\\')) then Exit;
  E := LowerCase(ExtractFileExt(S));
  if (E <> '.cmd') and (E <> '.bat') and (E <> '.exe') then Exit;
  Result := True;
end;

{ A header value carrying CR or LF splits the request; NUL truncates it.  Both
  are header injection, so the check is on the bytes rather than on intent. }
function HeaderTextOk(const S: string): Boolean;
var
  I: Integer;
begin
  Result := S <> '';
  for I := 1 to Length(S) do
    if (S[I] < #32) or (S[I] > #126) then Exit(False);
end;

{ An alias that contains a dash, or begins with "claude", would shadow a real
  model id and make the resolution order unreadable. }
function AliasNameOk(const S: string): Boolean;
begin
  Result := (S <> '') and (Pos('-', S) = 0) and
    (CompareText(Copy(S, 1, 6), 'claude') <> 0);
end;

{ ------------------------------------------------------------------ parse -- }

function SettingsParseTier(Tier: TSettingTier; const Bytes, Where: string;
  out Problems: TStringArray): Boolean;
var
  Root, V, Sub: TJson;
  Err, Name, Raw, Why: string;
  I, J, Idx, N, Ceiling, Base: Integer;
  D: TSettingDef;
  MK, MV: TStringArray;
  BoolVal: Boolean;

  { The single choke point for every complaint this parser makes.  Key names
    and values are interpolated into most of them and both come out of the
    file, so the cleaning happens once here rather than at thirty call sites
    where the thirty-first would forget. }
  procedure Bad(const Msg: string);
  begin
    NoteAdd(Problems, SettingClean(Where + ': ' + Msg));
  end;

begin
  Problems := nil;
  Result := False;
  if Length(Bytes) > MaxSettingsBytes then
  begin
    Bad(Format('%d bytes is larger than a settings file may be (%d)',
      [Length(Bytes), MaxSettingsBytes]));
    Exit;
  end;
  { Everything sent to the model must be valid UTF-8, and an output style name
    out of this file reaches the system prompt.  Refusing the document is the
    only honest answer: a scrubbed name would silently select a style nobody
    asked for. }
  if not IsValidUtf8(Bytes) then
  begin
    Bad('not valid UTF-8');
    Exit;
  end;
  Root := JsonParse(Bytes, Err);
  if Root = nil then
  begin
    Bad('not valid JSON: ' + Err);
    Exit;
  end;
  try
    if Root.Kind <> jkObj then
    begin
      Bad('the top level must be a JSON object');
      Exit;
    end;

    { First pass: every key is checked before any is stored.  All or nothing
      means the checking must finish before the storing starts, and it also
      means every problem in the file is reported rather than just the first -
      a loader that stops at the first error makes the user fix a typo, rerun,
      and find another. }
    for I := 0 to Root.Count - 1 do
    begin
      Name := Root.Key(I);
      Idx := SettingIndex(Name);
      if Idx < 0 then
      begin
        Bad('unknown key "' + Name + '"');
        Continue;
      end;
      D := SettingDefs[Idx];
      V := Root.Item(I);
      if D.Scope = scRefused then
      begin
        Bad('"' + Name + '" is not a settings key. ' + D.Note);
        NoteAdd(Refusals,
          SettingClean(Where + ': "' + Name + '" - ' + D.Note));
        Continue;
      end;
      if not TierAllowed(D, Tier) then
      begin
        { Named rather than swallowed, in the shape BadDenyRules uses: the
          user has to be told the value did not take, and where it would. }
        Bad('"' + Name + '" may only be set in the user settings file ' +
          '(%USERPROFILE%\.pasclaude\' + SettingsFileName + '), not by a ' +
          TierName(Tier) + ' file');
        NoteAdd(Refusals, SettingClean(Where + ': "' + Name + '" = ' +
          V.AsString) +
          ' - ' + D.Note + '; a ' + TierName(Tier) +
          ' file may not set it, copy it into %USERPROFILE%\.pasclaude\' +
          SettingsFileName);
        Continue;
      end;
      case D.Kind of
        skBool:
          if V.Kind <> jkBool then
            Bad('"' + Name + '" must be true or false');
        skInt:
          begin
            if V.Kind <> jkNum then
              Bad('"' + Name + '" must be a number')
            { Round() on a double outside Int64 raises, and an exception here
              would escape a loader whose whole contract is that a hostile
              project file can never stop the program - 1e308 in a cloned
              settings.json would have been startup denial of service.  The
              range test has to happen in floating point, before the
              conversion. }
            else if (V.AsNumber < -9.2e18) or (V.AsNumber > 9.2e18) then
              Bad(Format('"%s" must be between %d and %d',
                [Name, D.Lo, D.Hi]))
            else
            begin
              N := Round(V.AsNumber);
              if (N < D.Lo) or (N > D.Hi) then
                Bad(Format('"%s" must be between %d and %d, not %d',
                  [Name, D.Lo, D.Hi, N]))
              else if (D.Shape = shThinkBudget) and (N > 0) and (N < 1024) then
                { At every tier, not just the project one.  This is not a cost
                  rule; it is the API's floor, and a value under it makes every
                  request fail. }
                Bad(Format('"%s" = %d: the API rejects a thinking budget ' +
                  'under 1024; use 0 to turn thinking off', [Name, N]))
              else if SettingIsProjectClass(Tier) then
              begin
                Ceiling := D.ProjMax;
                if Ceiling = 0 then Ceiling := D.Hi;
                { The user's position: their own file if it names the key, the
                  compiled default if it does not.  stLocal is measured against
                  the same position as stProject and never against the project
                  value, because stLocal has project AUTHORITY - a repository
                  that can commit settings.json can commit settings.local.json
                  beside it, and letting one raise the baseline for the other
                  would give a clone two moves where the rule allows none. }
                Base := D.Dflt;
                if SettingValues[Idx, stUser].Present then
                  Base := SettingValues[Idx, stUser].IntVal;
                { Narrow only, and now actually narrow: a project may move the
                  number toward the cheap side of where the user has it and
                  never away from it.  Refused rather than clamped, so the
                  repository does not learn that the key half-works and the
                  user is told which file said what. }
                case D.Cheap of
                  chLower:
                    begin
                      if Base < Ceiling then Ceiling := Base;
                      if N > Ceiling then
                        Bad(Format('"%s" = %d: a %s file may not raise this ' +
                          'above %d (only the user settings file may)',
                          [Name, N, TierName(Tier), Ceiling]));
                    end;
                  chHigher:
                    begin
                      if N > Ceiling then
                        Bad(Format('"%s" = %d: a %s file may not raise this ' +
                          'above %d (only the user settings file may)',
                          [Name, N, TierName(Tier), Ceiling]))
                      else if N < Base then
                        Bad(Format('"%s" = %d: a %s file may not lower this ' +
                          'below %d (only the user settings file may)',
                          [Name, N, TierName(Tier), Base]));
                    end;
                else
                  if N > Ceiling then
                    Bad(Format('"%s" = %d: a %s file may not raise this ' +
                      'above %d (only the user settings file may)',
                      [Name, N, TierName(Tier), Ceiling]));
                end;
              end;
            end;
          end;
        skStr:
          if V.Kind <> jkStr then
            Bad('"' + Name + '" must be a string')
          else
          begin
            Raw := V.AsString;
            case D.Shape of
              shEndpoint:
                if not EndpointOk(Raw, Why) then
                  Bad('"' + Name + '": ' + Why);
              shServiceName:
                if not ServiceNameOk(Raw) then
                  Bad('"' + Name + '": lower-case letters, digits, dot, ' +
                    'underscore and dash, 64 characters at most');
              shIdeCommand:
                if not IdeCommandOk(Raw) then
                  Bad('"' + Name + '": an absolute path (drive letter or ' +
                    '\\\\server\\share) to a .cmd, .bat or .exe, printable ' +
                    'ASCII and no quote characters');
            end;
          end;
        skMap:
          if V.Kind <> jkObj then
            Bad('"' + Name + '" must be an object of string values')
          else
            for J := 0 to V.Count - 1 do
            begin
              Sub := V.Item(J);
              if Sub.Kind <> jkStr then
                Bad('"' + Name + '.' + V.Key(J) + '" must be a string')
              else
                case D.Shape of
                  shAliasMap:
                    if not AliasNameOk(V.Key(J)) then
                      Bad('"' + Name + '": "' + V.Key(J) + '" is not a usable ' +
                        'alias (no dashes, and not starting with "claude")');
                  shHeaderMap:
                    if not (HeaderTextOk(V.Key(J)) and HeaderTextOk(Sub.AsString)) then
                      Bad('"' + Name + '": "' + V.Key(J) + '" must be ' +
                        'printable ASCII with no control characters');
                end;
            end;
      end;
    end;

    if Length(Problems) > 0 then
    begin
      { The file-level sentence, so the user is never left to infer from a
        list of complaints that NONE of the good keys applied either. }
      Bad('this file contributed nothing; every key in it was ignored');
      Exit;
    end;

    { Second pass: store.  Nothing above assigned anything. }
    for I := 0 to Root.Count - 1 do
    begin
      Idx := SettingIndex(Root.Key(I));
      D := SettingDefs[Idx];
      V := Root.Item(I);
      MK := nil;
      MV := nil;
      N := 0;
      BoolVal := False;
      Raw := '';
      case D.Kind of
        skBool:
          begin
            BoolVal := V.AsBoolean;
            if BoolVal then Raw := 'true' else Raw := 'false';
          end;
        skInt:
          begin
            N := Round(V.AsNumber);
            Raw := IntToStr(N);
          end;
        skStr: Raw := V.AsString;
        skMap:
          begin
            SetLength(MK, V.Count);
            SetLength(MV, V.Count);
            for J := 0 to V.Count - 1 do
            begin
              MK[J] := V.Key(J);
              MV[J] := V.Item(J).AsString;
              if Raw <> '' then Raw := Raw + ', ';
              Raw := Raw + MK[J] + '=' + MV[J];
            end;
          end;
      end;
      SettingsStore(Idx, Tier, Raw, N, BoolVal, MK, MV);
      if SettingIsProjectClass(Tier) and
         ((D.Name = 'tool_result_bytes') or (D.Name = 'auto_compact_tokens') or
          (D.Name = 'thinking_budget')) then
      begin
        if EconomyNote <> '' then EconomyNote := EconomyNote + ', ';
        EconomyNote := EconomyNote + D.Name + ' = ' + SettingClean(Raw) +
          ' (' + TierName(Tier) + ')';
      end;
    end;
    Result := True;
  finally
    Root.Free;
  end;
end;

{ ------------------------------------------------------------------- load -- }

function ReadWhole(const Path: string; out Bytes: string;
  out Err: string): Boolean;
var
  F: TFileStream;
begin
  Bytes := '';
  Err := '';
  Result := False;
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Bytes, F.Size);
      if F.Size > 0 then F.ReadBuffer(Bytes[1], F.Size);
      Result := True;
    finally
      F.Free;
    end;
  except
    on E: Exception do Err := E.Message;
  end;
end;

procedure SettingsLoad(const UserPath, ProjectPath, LocalPath: string;
  out Notes: TStringArray);
var
  Paths: array[0..2] of string;
  Tiers: array[0..2] of TSettingTier;
  Problems: TStringArray;
  Bytes, Err: string;
  I, J: Integer;
begin
  Notes := nil;
  SettingsClear;
  Paths[0] := UserPath;   Tiers[0] := stUser;
  Paths[1] := ProjectPath; Tiers[1] := stProject;
  Paths[2] := LocalPath;  Tiers[2] := stLocal;
  for I := 0 to 2 do
  begin
    if Paths[I] = '' then Continue;
    { Absent is the normal case and is not a problem.  Unreadable is: a file
      the user wrote and this program could not open must not look the same
      as one that was never there. }
    if not FileExists(Paths[I]) then Continue;
    if not ReadWhole(Paths[I], Bytes, Err) then
    begin
      NoteAdd(Notes, Paths[I] + ': could not be read: ' + Err);
      Continue;
    end;
    if not SettingsParseTier(Tiers[I], Bytes, Paths[I], Problems) then
      for J := 0 to High(Problems) do
        NoteAdd(Notes, Problems[J]);
  end;
end;

{ ------------------------------------------------------------------- read -- }

{ The tier walk, and the reason an scUserOnly project value is unreachable
  rather than merely unread: the walk STARTS at the def's lowest permitted
  tier.  There is no moment at which a refused value is in hand and a filter
  is deciding what to do with it, so there is no filter a later refactor can
  drop. }
function SettingLookup(const Name: string; out Idx: Integer;
  out Tier: TSettingTier): Boolean;
var
  T: TSettingTier;
begin
  Result := False;
  Tier := stDefault;
  Idx := SettingIndex(Name);
  if Idx < 0 then Exit;
  if SettingDefs[Idx].Scope = scRefused then Exit;
  if RuntimeLabels[Idx] <> '' then
  begin
    Tier := stRuntime;
    Exit(SettingValues[Idx, stRuntime].Present);
  end;
  for T := High(TSettingTier) downto Low(TSettingTier) do
  begin
    if T = stRuntime then Continue;
    if T = stDefault then Break;
    if not TierAllowed(SettingDefs[Idx], T) then Continue;
    if SettingValues[Idx, T].Present then
    begin
      Tier := T;
      Exit(True);
    end;
  end;
end;

function SettingStr(const Name: string): string;
var
  I: Integer;
  T: TSettingTier;
begin
  Result := '';
  if SettingLookup(Name, I, T) then Result := SettingValues[I, T].Value;
end;

function SettingInt(const Name: string): Integer;
var
  I: Integer;
  T: TSettingTier;
begin
  Result := 0;
  if SettingLookup(Name, I, T) then Result := SettingValues[I, T].IntVal;
end;

function SettingBool(const Name: string): Boolean;
var
  I: Integer;
  T: TSettingTier;
begin
  Result := False;
  if SettingLookup(Name, I, T) then Result := SettingValues[I, T].BoolVal;
end;

function SettingMap(const Name: string; out Keys, Values: TStringArray): Boolean;
var
  I: Integer;
  T: TSettingTier;
begin
  Keys := nil;
  Values := nil;
  Result := SettingLookup(Name, I, T);
  if Result then
  begin
    Keys := SettingValues[I, T].MapKeys;
    Values := SettingValues[I, T].MapVals;
  end;
end;

function SettingIsSet(const Name: string): Boolean;
var
  I: Integer;
  T: TSettingTier;
begin
  Result := SettingLookup(Name, I, T);
end;

function SettingSource(const Name: string): TSettingTier;
var
  I: Integer;
  T: TSettingTier;
begin
  if SettingLookup(Name, I, T) then Result := T else Result := stDefault;
end;

function SettingTierValue(const Name: string; Tier: TSettingTier): string;
var
  I: Integer;
begin
  Result := '';
  I := SettingIndex(Name);
  if I < 0 then Exit;
  { Only what was actually stored, which is why a refused project value can
    never be surfaced back as data: it was never stored. }
  if SettingValues[I, Tier].Present then Result := SettingValues[I, Tier].Value;
end;

procedure SettingsSetRuntime(const Name, Value, SourceLabel: string);
var
  I, N: Integer;
  Empty: TStringArray;
begin
  I := SettingIndex(Name);
  if I < 0 then Exit;
  Empty := nil;
  N := StrToIntDef(Value, 0);
  SettingsStore(I, stRuntime, Value, N,
    (LowerCase(Value) = 'true') or (Value = '1'), Empty, Empty);
  RuntimeLabels[I] := SourceLabel;
end;

function SettingRuntimeLabel(const Name: string): string;
var
  I: Integer;
begin
  Result := '';
  I := SettingIndex(Name);
  if I >= 0 then Result := RuntimeLabels[I];
end;

function SettingsProjectEconomyNote: string;
begin
  Result := EconomyNote;
end;

function SettingsRefusals: TStringArray;
begin
  Result := Refusals;
end;

function SettingsReport: TStringArray;
var
  I: Integer;
  T, Src: TSettingTier;
  Shadow, Row, Eff: string;
begin
  Result := nil;
  for I := 0 to SettingCount - 1 do
  begin
    if SettingDefs[I].Scope = scRefused then Continue;
    if not SettingIsSet(SettingDefs[I].Name) then Continue;
    Src := SettingSource(SettingDefs[I].Name);
    { Cleaned, and the tab is the whole point.  The row is tab-separated and
      the value comes out of a file: an output_style of  explanatory<TAB>user
      in the PROJECT tree made /status print  output_style = explanatory
      (user)  - a project file choosing the tier word that /status attributes
      its own value to, in the one surface whose contract is "what is true
      right now".  SettingClean removes the separator along with the ESC. }
    Eff := SettingClean(SettingStr(SettingDefs[I].Name));
    Shadow := '';
    for T := High(TSettingTier) downto Low(TSettingTier) do
    begin
      if (T = Src) or (T = stDefault) then Continue;
      if not SettingValues[I, T].Present then Continue;
      if Shadow <> '' then Shadow := Shadow + ', ';
      Shadow := Shadow + TierName(T) + '=' +
        SettingClean(SettingValues[I, T].Value);
    end;
    Row := SettingDefs[I].Name + #9 + Eff + #9;
    if Src = stRuntime then
      Row := Row + RuntimeLabels[I]
    else
      Row := Row + TierName(Src);
    NoteAdd(Result, Row + #9 + Shadow);
  end;
end;

{ ------------------------------------------------------------------ write -- }

function SettingsWrite(const Path, Name, Value: string; Remove: Boolean;
  out Err: string): Boolean;
var
  Root, V: TJson;
  Bytes, Text, ParseErr: string;
  Idx, I, N: Integer;
  D: TSettingDef;
  F: TFileStream;
begin
  Result := False;
  Err := '';
  Idx := SettingIndex(Name);
  if Idx < 0 then
  begin
    Err := 'no such setting: ' + Name;
    Exit;
  end;
  D := SettingDefs[Idx];
  if D.Scope = scRefused then
  begin
    Err := Name + ' is not a settings key. ' + D.Note;
    Exit;
  end;
  if (D.Kind = skMap) and not Remove then
  begin
    { A map is edited in the file, not one key at a time from a command line;
      pretending otherwise would need a second syntax for the sub-key. }
    Err := Name + ' is a table of values; edit ' + Path + ' by hand';
    Exit;
  end;

  Root := nil;
  try
    if FileExists(Path) then
    begin
      if not ReadWhole(Path, Bytes, Err) then Exit;
      Root := JsonParse(Bytes, ParseErr);
      { Refused rather than replaced.  A writer that fell back to a fresh
        document would delete a user's hand-written file on a typo - the exact
        silent loss SavePermissions' full rewrite already produces once. }
      if Root = nil then
      begin
        Err := Path + ' is not valid JSON (' + ParseErr +
          '); fix it by hand rather than let this overwrite it';
        Exit;
      end;
      if Root.Kind <> jkObj then
      begin
        Err := Path + ' is not a JSON object; fix it by hand';
        Exit;
      end;
    end
    else
      Root := TJson.NewObj;

    if Remove then
    begin
      I := Root.IndexOf(Name);
      if I >= 0 then Root.Drop(I);
    end
    else
    begin
      case D.Kind of
        skBool:
          begin
            if (LowerCase(Value) <> 'true') and (LowerCase(Value) <> 'false') then
            begin
              Err := Name + ' takes true or false';
              Exit;
            end;
            V := TJson.NewBool(LowerCase(Value) = 'true');
          end;
        skInt:
          begin
            N := StrToIntDef(Value, D.Lo - 1);
            if (N < D.Lo) or (N > D.Hi) then
            begin
              Err := Format('%s must be between %d and %d', [Name, D.Lo, D.Hi]);
              Exit;
            end;
            V := TJson.NewNum(N);
          end;
      else
        begin
          { The same shape checks the loader applies, applied here too.  A
            /config set that wrote a value the next startup would refuse would
            void the whole file over one typed word. }
          case D.Shape of
            shEndpoint:
              if not EndpointOk(Value, ParseErr) then
              begin
                Err := Name + ': ' + ParseErr;
                Exit;
              end;
            shServiceName:
              if not ServiceNameOk(Value) then
              begin
                Err := Name + ': lower-case letters, digits, dot, underscore ' +
                  'and dash, 64 characters at most';
                Exit;
              end;
            shIdeCommand:
              if not IdeCommandOk(Value) then
              begin
                Err := Name + ': an absolute path (drive letter or ' +
                  '\\server\share) to a .cmd, .bat or .exe, printable ASCII ' +
                  'and no quote characters';
                Exit;
              end;
          end;
          V := TJson.NewStr(Value);
        end;
      end;
      I := Root.IndexOf(Name);
      { SetAt keeps the key where it was, so a rewritten file differs from the
        original only in the value that changed - every other key, INCLUDING
        the refused ones, survives byte for byte in its own position. }
      if I >= 0 then Root.SetAt(I, V) else Root.Add(Name, V);
    end;

    { Written as bytes rather than through a TStringList, so the file the user
      opens is exactly what the serialiser produced and no line ending is
      rewritten behind their back. }
    Text := Root.ToJsonPretty(False) + #10;
    try
      ForceDirectories(ExtractFilePath(Path));
      F := TFileStream.Create(Path, fmCreate);
      try
        F.WriteBuffer(Text[1], Length(Text));
      finally
        F.Free;
      end;
      Result := True;
    except
      on E: Exception do Err := E.Message;
    end;
  finally
    Root.Free;
  end;
end;

initialization
  SettingsClear;

end.
