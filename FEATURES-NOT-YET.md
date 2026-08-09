# Claude Code features not yet in pasclaude

pasclaude already covers a lot of the core experience: streaming chat with
markdown rendering, thirteen tools (read_file, write_file, edit_file,
notebook_edit, list_dir, search, bash, bash_output, kill_bash, fetch,
todo_write, skill, task) behind a diff-previewing permission gate,
an opt-in server-side web_search, regex search
and notebook-aware read/edit, background shell jobs, read-only subagents,
CLAUDE.md / AGENTS.md / .pasclaude.md project instructions, `@path` file
mentions, tab completion, persistent history, session save/resume with
validation, automatic context trimming plus token-triggered summarizing
compaction, prompt caching with cost counters, retry with Retry-After,
extended thinking, `.gitignore`-aware listing/search, git status in the
system prompt, and reuse of Claude Code's or Jcode's OAuth credentials.

The input and output surface is now most of one too. A prompt can carry an
image — `@shot.png` or `/paste` off the Windows clipboard, priced in visual
tokens before you send it — and the transcript, the session file and
compaction all know what an image block is. `/output-style` chooses how
replies are written, from three built-ins or a `<name>.md` of your own, as a
paragraph ADDED to the system prompt and never one replacing it. `/vim` and
`%USERPROFILE%\.pasclaude\keys.json` make the line editor modal and
rebindable, walled off from every other prompt in the program. And `-p`
gained the one thing a multi-turn driver needed: `--session-file <path>`,
opt-in by name, so repeated subprocess calls continue one conversation while
a bare `-p` still touches nothing on disk.

It now also covers the extensibility surface: MCP servers over stdio behind a
per-command-line spawn prompt, lifecycle hooks at five points in a turn behind
a fingerprint prompt, skills and plugins discovered from disk, a dynamic tool
registry any future source can plug into, and an SDK — `-p` with
`--output-format json|stream-json` and `--input-format stream-json` — plus a
console-free embedding facade in `src/uSdk.pas`. Standing approvals moved out
of the project to `%LOCALAPPDATA%\pasclaude\approvals\`, so a repository can no
longer ship the file that answers its own permission questions.

The permission system is now most of one too. Deny rules — `tool:`, `bash:`
and `path:` globs, out of tree only — are checked above every allow-all, the
bash prefix table, the nil-`Ask` check and a `PreToolUse` hook's allow, so
nothing overrides one. Four modes named on the prompt (`ask`, `plan`,
`accept-edits`, `bypass`), reachable from `--permission-mode`,
`--dangerously-skip-permissions`, `/mode`, `/plan` and `/yolo`, with plan
enforced as a boundary in `RunTool` rather than as a gate setting.
`--add-dir` and `/add-dir` widen which directories the file tools may reach
without widening what is asked. And every child process — bash, background
jobs, hooks, MCP servers — is spawned into a job object by `src/uSandbox.pas`,
optionally at low integrity. Approvals remain per-program for bash and
per-server for MCP; nothing in a project directory can set a mode, add a
directory, remove a deny rule or lower the sandbox.

Configuration and diagnostics is now covered too, and it is the round where a
principle defended four times separately finally got written down as a table.
`settings.json` exists in three tiers — user, project and local — and one
column in `uSettings` says which tier may set each key, enforced by one
function with one call site: a value at a tier its key does not permit is
never stored rather than stored and overruled. A project may set four display
and economy keys and may only ever move a number in the direction that costs
you less; `model`, the two routing keys and the six telemetry keys are the
user's alone, and `settings.local.json` carries project authority despite its
name, because `.gitignore` is a convention rather than a guard. Every key
somebody might paste out of Claude Code's `settings.json` is in the same table
as a refusal naming the file that really owns it. On top of that: `/login` and
`/logout` manage credentials without ever issuing one, and never write another
program's credential file — enforced by the writers taking no path argument;
`/model` gained dateless aliases and two routed roles, both user-scope only;
opt-in OTLP metrics send five counters and no text at all; and `/status`,
`/doctor` and `/bug` report what is true, what is wrong and what a maintainer
needs, built once as a record and rendered twice so the two views cannot
disagree.

That leaves **Integrations** as the only section here with anything unchecked
in it: GitHub Actions. IDE integration is done as far as it honestly goes
from a console program — the editor around the terminal is detected and
`/ide` opens files and session diffs in it, while an extension and reading
the editor's selection are refused with their reasons. The PR workflow
commands are done too: `/review` reviews a local diff and needs no token at
all, `/pr-comments` reads one pull request's comments over a client that
issues GET and nothing else, and `/install-github-app` is recorded as not
applicable because there is no pasclaude GitHub App to install. Every other
section is complete.

Checked items have been built since this list was compiled; the strikethrough
text preserves what was missing at the time. Unchecked items remain open.

## Agents and tools

- [x] ~~**Subagents / Task tool** — no way to spawn parallel or specialized
  agents (`.claude/agents`, the Task tool, agent teams).~~
  *Built: the `task` tool runs one read-only subagent at a time with its own
  transcript and hands back its final message; named types live in
  `.pasclaude\agents\<name>.md`. One level deep, twelve tool rounds, no
  parallelism.*
- [x] ~~**Web search** — `fetch` does an HTTPS GET of a known URL; there is
  no WebSearch tool.~~
  *Built: the server-side `web_search` tool, declared to the API only when
  `/web on` or `--web` says so. The API runs the search; the decoder
  round-trips `server_tool_use` and `web_search_tool_result` blocks and
  resumes on `pause_turn`, and a declaration the server rejects disables
  itself after one wasted request. Off by default and never persisted.
  Still missing: no per-query prompt is possible (there is no local call to
  gate), and results are not clipped, so a verbose result set stays in the
  transcript and is echoed on every later turn.*
- [x] ~~**Todo tracking** — no TodoWrite/task-list tool for plan visibility
  on multi-step work.~~
  *Built: the `todo_write` tool maintains a task list rendered live in the
  terminal (`[x]` green, `[~]` yellow, `[ ]` grey).*
- [x] ~~**Background bash** — shell commands are synchronous with a 120 s
  timeout; no run-in-background, output polling, or kill.~~
  *Built: `run_in_background` on the bash tool, `bash_output` to poll,
  `kill_bash` to stop; output spooled to a file under `.pasclaude\jobs`
  rather than a pipe; a Win32 job object per job so the tree dies with
  pasclaude; the same per-program approval as foreground bash; `/jobs` to
  see what is running. At most eight at once, 16 MB of output each. Still
  missing: a job left running at exit is stopped by design, so there is no
  truly detached server; the 16 MB cap is only enforced when something
  sweeps the table, so an unpolled job can overrun it until the next tool
  call; and a grandchild spawned in the moment between `CreateProcess` and
  the job assignment escapes `kill_bash`.*
- [x] ~~**Notebook editing** — no Jupyter (`.ipynb`) aware read/edit.~~
  *Built: `read_file` renders a `.ipynb` as numbered cells with outputs
  summarised by mime type and size rather than dumped; `notebook_edit`
  replaces, inserts or deletes a cell through `edit_file`'s permission gate
  and diff preview. Writes back in nbformat's exact layout, so ids,
  execution counts and outputs survive a round trip untouched. Still
  missing: nbformat 4 only — a v3 notebook is refused rather than upgraded —
  and non-ASCII text is written as raw UTF-8 where nbformat escapes it, so
  such lines show as changed once on the first edit.*
- [x] ~~**Regex search** — `search` does case-insensitive substrings and `*`
  globs, not the full regex Grep of Claude Code; `list_dir` is capped at
  depth 4.~~
  *Built: `search` takes `regex`, `case_sensitive` and `depth`; `list_dir`
  takes `depth` (1-12, defaults unchanged). The engine is an NFA simulation
  in `uRegex`, not FPC's TRegExpr, so a pattern like `(a+)+` cannot hang the
  session. Still missing, and deliberately: no capture groups reported, no
  backreferences, no lookaround — `search` returns whole matching lines, not
  slices, which is what lets the engine stay bounded. Quantifiers count
  bytes rather than characters, so `.{3}` matches three bytes of a UTF-8
  sequence. And the regex path has no literal to prefilter on, so it drops
  the substring prefilter and is measurably slower over a large tree.*

## Extensibility

- [x] ~~**MCP (Model Context Protocol)** — no external MCP servers,
  `.mcp.json`, or `/mcp`.~~
  *Built: `.mcp.json` in the session root names stdio servers whose tools
  become ordinary tools called `mcp__<server>__<tool>`; `/mcp` lists them with
  status, tool and skip counts, expanded command line and stderr path, and
  takes `restart <name>` and `refresh`. Spawning is gated on a prompt showing
  every program before any of them runs, and "always" records a hash of the
  expanded command line, arguments and sorted `NAME=VALUE` environment, so
  repointing an approved name at a different program asks again. Discovery is
  cached in `.pasclaude\mcp-cache.json`, so only the first run after approval
  spawns anything. Everything a server says is validated as data: names
  sanitized and composed against the API's 64-character ceiling, schemas
  rejected rather than truncated past 8 KB or depth 16, descriptions cut on a
  UTF-8 boundary, `annotations`/`title`/`outputSchema` dropped, 32 KB of
  declarations across all servers.
  Still missing: stdio only — a `url` entry or a non-stdio `type` is listed as
  unsupported and contributes nothing; HTTP, Streamable HTTP, SSE and WebSocket
  are not implemented. Tools only — no prompts, resources, sampling, roots or
  elicitation, and the client advertises no capabilities so a conformant server
  never asks. Handshake-era protocol only: we send 2025-06-18 and accept what
  comes back, so a server speaking only the 2026-07-28 revision, which removed
  `initialize`, cannot be used and the only signal is its error text in `/mcp`.
  No auto-restart — a server that dies stays dead until `/mcp restart`, because
  a crash-looping server would otherwise spawn forever. First-run connection is
  sequential, so N servers each taking their 10 s deadline is a 10N-second
  first start; with no threads there is no way to overlap them. "Always" is per
  server, not per tool. The discovery cache can advertise a tool that no longer
  exists — a clean tool error, fixed by `/mcp refresh`. A user-scope
  `%USERPROFILE%\.pasclaude\mcp.json` is in the layout but is not read yet. And
  a server can still put prompt-injection text in a tool description that we
  faithfully forward; the gate is the user having approved the program.*
- [x] ~~**Hooks** — no PreToolUse/PostToolUse or other lifecycle hooks.~~
  *Built: `.pasclaude\hooks.json` runs commands at PreToolUse, PostToolUse,
  UserPromptSubmit, Stop and SessionStart, with an optional regex matcher on
  the tool name for the two tool events. One UTF-8 JSON object on stdin, the
  decision in the exit code (0 proceeds, 2 blocks, anything else is a failure
  and never a block), and an optional `{"decision":...}` object on stdout.
  Gated on a fingerprint of the file's bytes, so editing it asks again; `/yolo`
  does not answer that question and `-p` never loads hooks at all. `/hooks`
  shows the file and one line per hook; `/hooks off` stops them.
  Still missing: SessionEnd, SubagentStop, PreCompact and Notification are not
  fired, each a deliberate omission rather than a gap — there is no honest
  firing point for SessionEnd (Ctrl+C, a closed window and print mode's `Halt`
  all skip it), a subagent is read-only and invisible so "block" has no legal
  meaning inside one, a hook that can block compaction can kill the session it
  was meant to guard, and pasclaude has no notification channel. A hook cannot
  cancel a turn (`{"continue":false}` is not implemented) and cannot rewrite a
  tool's input — silently changing what the user approved in the diff preview
  is worse than blocking. Hook latency is invisible: eight hooks at the
  60-second ceiling is eight minutes on one tool call with nothing on screen,
  and the notice callback fires only on failure. A `tool_input` over 64 KB is
  replaced wholesale with `{"_omitted":"N bytes"}`, so a PreToolUse hook that
  formats large `write_file` payloads cannot do its job on them. There is no
  user-scope `%USERPROFILE%\.pasclaude\hooks.json` yet — the trust asymmetry
  (user-level trusted, project-level prompted) is designed but only the
  prompted half is built.*
- [x] ~~**Custom slash commands** — no `.claude/commands/*.md` user-defined
  commands.~~
  *Built: `/name args` reads `.pasclaude\commands\name.md` as the prompt
  with `$ARGUMENTS` substituted; built-ins cannot be shadowed.*
- [x] ~~**Skills / plugins** — no plugin marketplace or skill packs.~~
  *Built: a skill is `.pasclaude\skills\<name>\SKILL.md` — frontmatter naming
  it and describing when it applies, then a body the model gets only when it
  calls the ungated `skill` tool by name. The catalogue lives in that tool's
  own description rather than in the system prompt, so a skill dropped in after
  `/skills` is live on the next turn at byte-identical token cost. Project
  skills, then each enabled plugin's, then `%USERPROFILE%\.pasclaude\skills\`;
  nearer wins and the source is always shown. A plugin is a directory under
  `.pasclaude\plugins\` with a `plugin.json` and any of `commands\`, `agents\`,
  `skills\`, inert until `/plugins enable <name>`; `.pasclaude\plugins.json`
  records enablement in both directions.
  Deliberately out of scope, not merely unbuilt: there is no marketplace and no
  downloader. The entire safety argument for this feature is that the user can
  read the directory before it does anything, and fetching and unpacking
  archives with no signature story destroys that argument at exactly the moment
  it is needed. The scope is: copy or clone a directory into
  `.pasclaude\plugins\`.
  Also still missing: a skill added mid-session is invisible until `/skills`
  runs. The plugin startup notice repeats every launch until `/plugins` is run
  once. Skills copied from Claude Code that use a block scalar for their
  description are refused outright — intended, and the error names the line and
  the construct, but it will read as a bug. Subdirectories inside a skill are
  not addressable: `skill{file:...}` takes a bare filename from the skill's own
  directory and nothing else. Qualified `plugin:name` display names are not
  supported, because `:` is one of the characters every name filter in this
  program refuses. Caps: 32 skills catalogued, 320 bytes of description each,
  128 KB per SKILL.md, 16 plugins — all visible when they bite.*
- [x] ~~**Agent SDK** — no programmatic embedding.~~
  *Built: `-p` with `--output-format json|stream-json` prints one JSON object
  per line — `system` (subtype `init`, carrying the session id, cwd, model,
  permission mode and the full inventory of tools, agents, commands, MCP
  servers and skills), `user`, `assistant_delta`, `tool_use`, `tool_result`,
  `notice`, `hook`, `permission_request`, `error` and exactly one `result`.
  `--input-format stream-json` turns stdin into the other half: further user
  messages, and `permission_response` lines answering the questions a human
  would have answered, where everything that is not an explicit
  `allow`/`allow_always` denies. Exit codes 0/1/2, and a startup failure comes
  out as an `error` line rather than prose. `src/uSdk.pas` is console-free and
  `examples/embed.lpr` embeds the agent in about sixty lines using only
  SysUtils and uSdk; `build.cmd` builds it so it cannot rot.
  Still missing: no mid-turn interrupt over the wire — `{"type":"interrupt"}`
  is refused by name, because reading stdin while blocked on the network needs
  a thread and this codebase has none (Ctrl+C still stops a turn). No
  `total_cost_usd` on the result line: pasclaude has no price table, `/cost`
  reports tokens for the same reason, and a hardcoded one becomes a lie the
  first time a model is repriced — this is the single intentional divergence
  from Claude Code's SDK shape, and a driver that wants money multiplies the
  token counts by numbers it can see. No `--resume` in SDK mode and no session
  save at all. One session per process, because `uTools`' state is
  module-global; a subprocess is the isolation boundary. The raw API
  `stream_event` envelope is not mirrored — the stream is pasclaude's own
  normalised view of the SSE decoder, and re-synthesising raw events would be
  fiction. `SdkHookLine` exists and is tested but nothing emits it yet: hook
  activity reaches a driver as `notice` lines and as the resulting
  `tool_result`.*

## Permissions

- [x] ~~**Persistent permission rules** — "always" approvals (per tool
  class, per bash program) last one session; there is no `settings.json`
  allow/deny rule list that survives restarts.~~
  *Built: approvals persist in
  `%LOCALAPPDATA%\pasclaude\approvals\<project>-<hash>.json` (widen-only,
  hand-editable; `/yolo` sessions never write it, print mode never reads
  it), one file per session root and keyed by its full path. It holds the
  tool-class grants, the approved bash programs and the trusted fingerprints
  for `hooks.json` and each MCP server. It lives outside the project on
  purpose: a repository that could ship its own copy would be answering its
  own permission questions. Deny rules exist now: one string per rule,
  `tool:<glob>`, `bash:<program-glob>` or `path:<glob>`, in
  `%LOCALAPPDATA%\pasclaude\deny.json` (global, `/deny add|remove`) or in a
  `"deny"` array in the per-root approvals file (hand-edited, round-tripped
  verbatim). A rule is checked at the top of `RunTool` and inside `SafePath`,
  above every allow-all, the bash prefix table, the nil-`Ask` check and a
  `PreToolUse` hook's allow, so nothing — `/yolo`, an "always", a hook —
  overrides one; a refusal names the rule and the file it came from, and an
  unparseable rule is reported at startup rather than silently ignored. Path
  rules canonicalise (8.3 names, junctions, case, `..`) and also hide the file
  from `list_dir` and `search`. `-p` inherits deny rules and still inherits no
  approvals. Narrower than Claude Code in three ways, all deliberate:
  `bash:` filters the program name of each `cmd.exe` segment and cannot follow
  `%VAR%` expansion, a `for` loop, a renamed copy or a `.cmd` wrapper —
  `tool:bash` is the airtight form; `path:` covers pasclaude's file tools and
  not the shell, so `bash: type .env` is untouched by it, and a hardlink is a
  different path to every API Windows offers; and `fetch:<host>` was
  considered and refused, because WinHTTP follows redirects and a host rule
  would match the URL typed rather than the host that answered. No deny rule
  is ever read from the project tree. And the move is silent — a session that
  had accumulated approvals in an in-repo `.pasclaude\permissions.json` is
  simply re-asked, with no notice explaining why.*
- [x] ~~**Permission modes** — no plan mode, no accept-edits mode, no
  `--dangerously-skip-permissions` flag (`/yolo` is per-session only).~~
  *Built: four modes, shown as one word — `ask`, `plan`, `accept-edits`,
  `bypass` — behind two pieces of state rather than one ladder, because plan
  has to beat bypass. Plan mode is a boundary enforced in `RunTool` beside the
  subagent read-only list, above the `PreToolUse` fire and far above the gate,
  so bypass, a class allow-all, a stored bash prefix, a hook's `allow` and a
  nil `Ask` are all structurally unable to lift it; what it permits is an
  allowlist (`read_file`, `list_dir`, `search`, `todo_write`, `skill`, `task`,
  `bash_output`), so a third-party MCP verb or a tool added next year is
  refused without anyone deciding to refuse it. `fetch` is deliberately not on
  it: every other name reads this machine, and `fetch` is the one way what
  they read could leave it. The model learns the mode
  both ways: a paragraph in an uncached trailing system block, and a refusal
  naming the mode. Accept-edits IS the existing `AllowAllEdits` flag given a
  name, an indicator and — for the first time — an off switch, `/mode ask`,
  which survives a restart because the approvals file only ever widens from a
  true key. `--permission-mode ask|plan|accept-edits`,
  `--dangerously-skip-permissions`, `/mode`, `/plan` and `/yolo` are the only
  ways in; the prompt string carries the mode on every keystroke and the
  banner announces a grant loaded from disk, which had been invisible since
  approvals began persisting. Narrower than Claude Code in four ways: there is
  no `exit_plan_mode` tool at all, because a tool that lets the model leave
  plan mode is a tool that lets it grant itself write access, so leaving is
  always a keystroke and never auto-approves the plan's edits; plan mode stops
  the model, not the machine — a `SessionStart` or `UserPromptSubmit` hook is
  the user's own command and still runs; no mode is persisted or resumed, so a
  session resumed with `--resume` comes back in `ask`; and `/mode ask` revokes
  the bash, fetch and MCP class blankets as well as edits, which is broader
  than the name suggests and is printed, but leaves the named per-program and
  per-server grants alone.*
- [x] ~~**Sandboxed bash** — commands run directly through `cmd.exe /C`,
  unsandboxed (compound commands are re-prompted, but not isolated).~~
  *Built: every child this program starts — foreground bash, background bash,
  hook commands and MCP servers — is now created by one function in the new
  `uSandbox` unit, at one of two levels. `limits` is the default and costs
  nothing: a job object capping the tree at 64 processes, killing it when the
  session ends, refusing breakaway, and blocking clipboard reads and desktop
  changes. `low` is opt-in via `--sandbox low` or `/sandbox low` and adds a
  low-integrity token, so a command cannot write your profile, HKCU, or any
  directory not labelled for it — including the project — and gets a scratch
  `%TEMP%` of its own under `%LOCALAPPDATA%`. This also fixed two older gaps:
  the foreground shell had no job object at all (a timed-out command killed
  `cmd.exe` and orphaned its children), and all three raw spawn sites assigned
  to the job after the spawn, leaving a documented race that suspend-then-
  resume now closes. Still missing, and these are limits of Win32 rather than
  of the implementation: bash cannot be scoped to the session root, which
  needs a filesystem filter driver, and cannot be denied the network, which
  needs WFP or a firewall rule — so low integrity stops writes and registry
  persistence and stops nothing else. It does not stop a command reading every
  file you can read, and it does not stop it exfiltrating what it read, which
  is exactly why the sandbox changes nothing about what you are asked to
  approve. Restricted tokens and AppContainer were both probed and rejected:
  `CreateRestrictedToken(WRITE_RESTRICTED)` produces a child that dies at
  0xC0000142 without window-station ACL plumbing, and AppContainer needs a
  persistent profile identity for confinement we would still have to
  hand-build. Under `low`, `npx`-based MCP servers and hooks that write
  `%APPDATA%` will fail; `/sandbox off` restores the old behaviour — with one
  thing it deliberately does not switch off, because it was never a
  restriction: at every level, `off` included, a child still gets a job object
  carrying `KILL_ON_JOB_CLOSE`, so `kill_bash`, a hook's timeout and process
  exit reap the whole tree instead of terminating `cmd.exe` and orphaning what
  it started.*
- [x] ~~**Additional working directories** — one session root, fixed at
  startup; no `--add-dir`.~~
  *Built: `--add-dir <dir>` (repeatable, also `--add-dir=<dir>`) and `/add-dir`
  at the prompt add directories the file tools may work in; `/cwd` lists them
  numbered and `/remove-dir <n|path>` takes one away. The guard keeps ONE
  resolution base: a relative or rooted path still means the session root, so
  adding a directory can only make previously-refused absolute paths succeed
  and can never re-point `src\main.pas`. A file in an added directory is named
  by its full absolute path, which is also how `list_dir` and `search` print
  it, and the model is told so by a system-prompt block emitted only when
  there is more than one root. Each root gets its own `.gitignore`; the state
  directory is refused at the top of every root; deny rules still apply
  everywhere, and an anchored one (`path:secrets/**`) is measured against
  whichever root contains the file, so it means the same thing in an added
  directory as it does in the session root — the path guard and the `list_dir`
  and `search` walkers agree, rather than the walkers hiding a file the guard
  would still hand over by its absolute name. An added root grants file access
  and nothing else: its
  `.pasclaude\hooks.json`, skills, commands and agents, its `.mcp.json` and
  its `CLAUDE.md` are all deliberately unread, and the session, history,
  approvals, snapshots and bash's working directory stay bound to the session
  root. Roots come only from argv or a typed command — never from a file — and
  are never persisted, so every session re-states the grant. Still missing:
  Claude Code lets a relative path resolve in any working directory and
  persists the set; both are deliberate omissions here, the first because the
  ambiguity is a security bug and the second because the approvals file only
  widens on load. Bash is unaffected — its working directory is the session
  root and it was never path-guarded.*

## Sessions and memory

- [x] ~~**Checkpointing / rewind** — no Esc-Esc rewind, no `/rewind`, no
  restoring code + conversation to an earlier point.~~
  *Built: `/rewind` lists your turns and restores both the transcript and
  the files edited since the picked one, including deleting files created
  that turn. Shell commands are named as not-undoable; files over 400 KB
  are not snapshotted. (Esc-Esc as a shortcut remains missing.)*
- [x] ~~**Session picker** — one session per directory (the previous one is
  moved to `session.prev.json`, not offered); no list of past sessions, no
  naming.~~
  *Built: `/save <name>` keeps a named copy, `/sessions` lists everything
  saved (live, safety copy, named) with dates and sizes and resumes the
  pick. (`--continue` vs `--resume` as CLI flags remains missing.)*
- [x] ~~**Memory** — no `/memory`, no `#` shortcut to append to CLAUDE.md,
  no user-level `~/.claude/CLAUDE.md`, no `@import` in CLAUDE.md.~~
  *Built: `# note` appends to the project memory file, `/memory` shows it,
  `%USERPROFILE%\.pasclaude\CLAUDE.md` is user-level memory loaded before
  the project's (nearer wins), and `@import <path>` / bare `@path` lines in
  instruction files inline the referenced file, one level deep.*
- [x] ~~**/init** — cannot generate a CLAUDE.md for a new project.~~
  *Built: `/init` has the model explore the project and write a starter
  CLAUDE.md through the ordinary write approval.*

## Input and output

- [x] ~~**Non-interactive mode** — no `-p "prompt"` print mode, no piped
  stdin.~~
  *Built: `pasclaude -p "question"` answers once and exits with a status
  code; piped stdin becomes context, or the prompt itself when `-p` is
  bare. `--output-format json` prints one JSON object — the finished result —
  and `--output-format stream-json` prints one per line as the turn happens;
  `--input-format stream-json` lets a driver send further turns and answer
  permission requests. `--session-file <path>` names a transcript a `-p` run
  saves to after every turn — before the `result` line, so a driver may spawn
  the next process the moment it reads one — and with `--resume` continues; it
  is the whole opt-in, because without it `-p` still writes nothing at all and
  the directory's own conversation is never touched. The path goes through the
  same root guard the tools use, and the file is the ordinary session file, so
  one written by a script loads in the REPL and back. A file that is not there
  yet is a fresh start; one that is there and unreadable stops the run with
  exit 2 rather than doing work on absent context and then overwriting the
  evidence — interactive `--resume` warns and carries on instead, because
  somebody is there to read the warning. The init line reports `resumed`,
  `resumed_messages` and `session_file` on every run, present even when
  nothing was resumed. A resumed session restores messages, model and counters
  and nothing else: no mode, no approvals, no roots, so it can never come back
  more permissive than a fresh one. Still missing: no mid-turn interrupt over
  the wire and no `total_cost_usd` on the result line, both deliberate — the
  first needs a thread this program does not have, the second a price table
  that becomes a lie the first time a model is repriced. Nothing is compacted
  on this path either, so a scripted session that outgrows the context window
  is answered with a new file, and two processes sharing one file race with
  last writer winning. See the Agent SDK entry above.*
- [x] ~~**Image input** — cannot paste or attach screenshots/images.~~
  *Built: `@shot.png` in a prompt attaches the image instead of refusing it as
  a binary, and `/paste` takes one off the Windows clipboard (`/paste drop`
  cancels). Both report dimensions, byte size and the real token cost — the
  documented `ceil(w/28)*ceil(h/28)` patch formula, not a rule of thumb — so
  you see what a screenshot costs before you send it. png, jpeg, gif and webp;
  base64 only. Mentioned files go up untouched under a 5 MB cap; clipboard
  pixels are encoded here, since Windows offers CF_DIB and the API takes no
  BMP. That encoder writes a PNG over STORED deflate blocks because paszlib is
  a package, not the RTL — verified against Windows Imaging Component and
  Python zlib, not assumed. The price is that a stored PNG is about the size
  of its raw pixels: pasted images are capped at 2 MB and downscaled at most
  twice to fit, then refused with the size named rather than shrunk to
  something unreadable. Palette encoding rescues the common terminal or dialog
  screenshot; photographs are what hit the refusal. Images survive save/load
  and `--resume` unchanged, and compaction evicts all but the two newest
  first, since base64 is re-sent in full every turn. Still missing: no image
  from `read_file` (it keeps its hex dump — a tool result has no human in the
  loop, and `uNotebook` and `uMcp` already refuse to sail base64 into context
  unexamined), no images in tool results at all, no URL or Files API sources,
  8 per message, and plain `-p` never expands `@mentions` — though a
  `--input-format stream-json` driver can send image blocks in its own
  user message, so print mode is not closed to images, only the `@`
  shorthand is. **An image can carry text instructing the model that
  a person reading the transcript cannot see — the transcript shows only
  `[image 1920x1080 image/png]`. Nothing here detects that and nothing can.
  What bounds it: an image enters only by your own `@mention` or `/paste`, both
  root-guarded exactly as a tool call is — a FILE copied in Explorer goes
  through the same resolver as `@`, so a `/paste` of one outside the session
  root, or inside `.pasclaude\`, or under a deny rule, is refused by the same
  message (copying the *image* rather than the file is unaffected, and
  `--add-dir` widens both alike) — and it lands in a user block, so it carries
  the authority of text you typed and no more. A saved session also keeps the
  image on disk in plaintext under `.pasclaude\`.***
- [x] ~~**Vim mode / keybindings** — line editing is fixed (arrows, Home/End,
  Ctrl+A/E/U); no `/vim`, no configurable keybindings.~~
  *Built: two separate things. `/vim` turns on a modal editor — insert and
  normal modes, `[I]`/`[N]` on the prompt, motions `h l w b e 0 ^ $` with
  `j`/`k` as history, entries `i a I A`, edits `x D C S dd cc dw db de d0 d$
  cw cb ce c0 c$`, and undo `u` / redo Ctrl+R with one insert session as one
  step; `/vim save` keeps it. `/keys` lists the effective table.
  `%USERPROFILE%\.pasclaude\keys.json` rebinds — `{"vim":true,"bindings":
  {"ctrl+w":"delete-word-left"}}` — over built-in defaults Ctrl+W, Ctrl+K,
  Alt+B, Alt+F and Ctrl+Z, which are the readline verbs the line above
  complains are missing. Every refused entry is reported by name, never
  ignored. Still missing, deliberately: visual mode, registers/yank/put,
  counts (`3dw`), the `.` repeat, marks, macros, `:` commands, `/` search,
  text objects (`ciw`), `r`/`R`/`s`, `o`/`O`, `gg`/`G` and `%`. A prompt is
  one line — there is no buffer to write and no next line to open — and
  `j`/`k` are worth more as history than as motion. Turning vim on costs
  Esc-clears-the-line (Ctrl+U still clears), and text pasted while in normal
  mode is read as commands; `/vim on` says both out loud. **A binding cannot
  reach the permission prompt, and three separate things stop it: no chord
  can be named without ctrl or alt, so `y`, `a` and `n` are inexpressible; an
  action is an editor verb, so nothing bound can submit, answer or run
  anything; and the reader every other prompt uses passes an empty profile,
  with the binding table read in one expression a grep can audit. The file is
  under `%USERPROFILE%` and never the project directory, so a `git clone`
  cannot ship one. Nothing here enters the model's context: the request body
  is byte-identical with vim on or off.***
- [x] ~~**Output styles** — no `/output-style`.~~
  *Built: `/output-style` lists what is available and marks the current one,
  `/output-style <name>` sets it, and `--output-style <name>` works under
  `-p`, which is the only way in there. Three built-ins compiled in —
  `default`, `explanatory`, `learning` — plus a flat `<name>.md` in
  `.pasclaude\styles\`, an enabled plugin's `styles\`, or
  `%USERPROFILE%\.pasclaude\styles\`, nearer winning, parsed by the same
  frontmatter reader `SKILL.md` uses. A style ADDS a paragraph to the system
  prompt and can never replace one: nothing reads the body but a single
  concatenation in `SessionNote`, and no frontmatter key maps to a setting.
  The text rides in the uncached trailing system block beside the plan-mode
  paragraph, so switching costs a few hundred tokens rather than the whole
  cached prefix, and it is capped at 2 KB — `/output-style` prints the byte
  size it added. The chosen name and the source it resolved from persist
  under `%LOCALAPPDATA%`, never in the project; a name that now resolves
  somewhere else falls back to `default` with a yellow line. Still missing:
  no built-in `Explanatory`/`Learning` insert markers in the reply itself,
  no `--append-system-prompt`, and the body is read once at set time, so an
  edited style file applies only after re-running `/output-style <name>`.*

## Integrations

- [x] ~~**IDE integrations** — no VS Code or JetBrains extension awareness
  (diff-in-editor, selection as context).~~
  *Built: host detection and `/ide`, and two of the four things that phrase
  names turned out to have no honest implementation from a console program,
  so they are refused here rather than half-shipped. What exists: `uIde`
  identifies the editor around the terminal from the environment it already
  exports — `TERM_PROGRAM=vscode` with `VSCODE_INJECTION=1` for the VS Code
  family, `TERMINAL_EMULATOR=JetBrains-JediTerm` for JetBrains — compared
  for exact equality, never a prefix, for the same reason `SplitUrlEx`
  tests its loopback host exactly. `/ide` reports what was found, `/ide
  open <path>[:line]` opens a file, and `/ide diff [<path>]` opens a real
  diff tab of the file **as it was before this session first touched it**
  against the file as it stands, using the snapshots `/rewind` already
  keeps. The editor's command-line program is found by scanning `bin` and
  `resources\app\bin` beside the exe the environment names, skipping the
  updater's `new_*` copies and the `*-tunnel*` clients, because deriving
  the shim's name from the exe's works for VS Code stable and silently
  fails for Insiders and Cursor. Every path is screened for characters that
  cannot survive a command line before anything is composed, the launch
  goes through `uSandbox.SandboxSpawn` with the level forced to `off` for
  the duration and restored in a `finally`, and the exact command line is
  printed and approved once per session — a user-typed slash command never
  reaches the permission gate, so this is the only layer that could ask.
  `ide.enabled` and `ide.command` are user scope only: a repository naming
  a program that a slash command then starts is the same hole as a
  project-settable telemetry endpoint. Nothing here is reachable under `-p`
  or by the model, nothing an editor prints is captured, and no detection
  string reaches a request. Deliberately NOT built: **no extension** —
  TypeScript, npm and `vsce` is a second toolchain in a repository whose
  only non-Pascal files are `.gitignore`, `LICENSE` and `logo.png`,
  `build.cmd` and `test.cmd` could not compile it, run it or notice it
  rotting against a new API, and this codebase hand-wrote a PNG encoder
  over STORED deflate rather than take paszlib. **Selection as context is
  not applicable**: nothing VS Code injects into a terminal names a file, a
  line, a column or a selection — the one IPC handle is the git extension's
  askpass socket, whose protocol carries credential and commit-message
  prompts and no editor state — so there is no channel and none was
  invented; `@path` mentions and `/paste` are the nearest real things and
  both already exist. **No diff in the approval prompt**: `--wait` blocks
  the spawning thread until the tab closes, so the y/a/n prompt could not
  be answered, and without it a tab opens beside a prompt the user must
  answer in the terminal, shows a change that has not happened, and stays
  open after `n` — a declined edit would leave a tab that looks applied.
  `RenderDiff`, `ChangePreview`, `PermitChange`, `ShowDetail` and
  `AskPermission` are untouched. Still missing: JetBrains is detected from
  documentation rather than from a running IDE and is never launched into
  without an explicit `ide.command`, because nothing in that environment
  names the launcher; `/ide diff` has nothing to show for a file larger
  than the snapshot limit `/rewind` already documents; and the "before"
  side is written under `%LOCALAPPDATA%\pasclaude\ide` and swept only on
  the next launch, so a session that opens one diff and exits leaves one
  file holding project text for up to a day.*
- [ ] **GitHub Actions / `@claude` mentions** — no CI integration.
- [x] ~~**/review, /pr-comments, /install-github-app** — no built-in PR
  workflow commands (git itself works through bash, and `/diff` summarizes
  changes).~~
  *Built: two of the three commands, and the third is not applicable and no
  command ships for it. `/review` is **local and needs no network and no
  token**: `/review` reviews `git diff HEAD`, `/review --staged` reviews the
  index, and `/review <ref>` reviews `git diff <ref>...HEAD`, the merge-base
  form — "what this branch adds". It prints `git diff --stat` first so you
  see the size and the file list before a turn is spent, then sends the diff
  as an ordinary user message, so any edit the model proposes shows its own
  diff and asks like every other. `/review 123` is refused **by name**, and
  says to run `gh pr checkout 123` and then `/review main`: fetching a pull
  request's diff would pull an arbitrarily large, arbitrarily hostile change
  written by whoever opened it into the context of an agent holding thirteen
  tools, for a result one `gh` command already gives from code you chose to
  check out. A `<ref>` is user text entering an ungated `cmd.exe` line — no
  permission gate, no deny check, no sandbox — so it is charset-validated
  (letters, digits, `. _ - /`, no leading `-`, no `..`, 128 bytes) **before**
  anything is composed, and that validator has its own test. `/pr-comments`
  fetches the inline review comments, the review bodies and the conversation
  thread of one pull request in four GETs to `api.github.com`, renders them
  to the console, and **sends the model exactly the lines it printed** —
  `/pr-comments <n> --show` renders and sends nothing. With no number it
  infers the pull request from the current branch and asks for a number when
  that is not exactly one match. `uGitHub` issues **GET and nothing else**:
  there is no POST, PUT, PATCH or DELETE in the unit, so no comment, review,
  approval, merge or branch can be produced by any amount of injected text,
  in any mode, by any answer to any prompt — a read-only client cannot be
  talked into an action. The API host is a **compiled constant settable at no
  tier**, and `github` is a refused settings key naming where the token
  really comes from: `GH_TOKEN`, then `GITHUB_TOKEN`, then `gh auth token`,
  and nowhere else. Nothing is stored — `gh` already owns GitHub credential
  storage and a second DPAPI blob would be a second credential lifetime to
  keep correct for no gain — so `uAuth` grows no source and its writers still
  take no path argument. A token is screened for header bytes (printable
  ASCII, one line, 8..512) **before** `HttpGet` is called, because `uHttp`
  validates no header byte; `gh`'s output is accepted only on exit code 0 and
  only as a single line, and is never copied into an error, a note or a
  report. `TDiagFacts` gains the repository name and the token **source
  name** and no value, no hint and no length. Comment text is untrusted —
  anyone with a GitHub account can write it — so it lands in a user message,
  never the system prompt, inside a marked block preceded by one sentence
  saying it is data and never an instruction, with any line forging either
  marker dropped per line **after** truncation, capped at 100 items, 4 KB a
  body and 64 KB a payload, every cut marked, and every byte `IsValidUtf8`
  checked. Neither command exists under `-p`: `HandleCommand` runs only in
  the REPL, and `GitHubAllowed` is False until the interactive path sets it
  below the print-mode halt, so a future wiring mistake fails closed and a
  suite asserts the transport is never touched. A pre-existing hazard was
  fixed on the way: `cmd.exe /C` resolves the current directory before PATH,
  so `git rev-parse` at startup ran a `git.cmd` a cloned repository shipped —
  measured with a probe, not theorised. `uTools.ProgramCommand` walks PATH
  and PATHEXT, never the current directory and never a working root, and the
  three existing git calls now go through it. **`/install-github-app` is not
  applicable and no command ships.** It installs *Anthropic's* GitHub App so
  that `@claude` mentions are answered by Anthropic's infrastructure. There
  is no pasclaude GitHub App: one means an app id, a private key, a webhook
  receiver and a service somebody operates, none of which a single-file
  Windows binary with no dependencies beyond the FPC RTL can be. Pointing the
  command at Anthropic's app would be this program installing an integration
  it is not part of and cannot honour — the same finding `uAuth` already
  records about minting tokens with Claude Code's client identity: pasclaude
  is a credential manager and never a credential issuer, and by the same
  argument it is not an app publisher. A command that only printed an
  explanation would put a non-feature in the command table and in `/help`,
  which reads as half-built. Still missing: one page of 100 per list, because
  `uHttp` exposes no response headers and therefore no `Link` header — a full
  page is reported as possibly incomplete rather than silently truncated;
  **github.com only**, no GitHub Enterprise, because a configurable host is
  exactly the knob a credential should not have; **read-only**, so no reply,
  resolve, approve or merge; no pull-request diff review; and the residual
  the envelope does not fix — a comment can still persuade the model to
  *propose* an edit or a command, and the human answering the prompt is the
  last gate, so a user who habitually answers "a" has already widened it,
  while `/review` over a fetched fork branch feeds attacker-written code to
  the model exactly as opening that file in an editor would.*

## Configuration and diagnostics

- [x] ~~**settings.json** — no hierarchical user/project/local config, no
  `/config`.~~
  *Built: three files — `%USERPROFILE%\.pasclaude\settings.json`,
  `<root>\.pasclaude\settings.json` and
  `<root>\.pasclaude\settings.local.json`
  — resolved per key by the same "nearer wins" rule skills and styles already
  use: local, then project, then user, then the built-in default. The charter
  is one sentence: **settings.json carries display and economy keys only;
  authority stays where it is.** One table in `uSettings` gives every key a
  scope, and one function consulted from one place enforces it, so a value at
  a tier its key does not permit is never stored rather than stored and
  overruled. A project or local file may set four keys: `output_style`,
  `thinking_budget`, `tool_result_bytes` and `auto_compact_tokens` — and on
  the last three only in the direction that costs you less, measured against
  the value **you** have in force: your own settings file if it names the key,
  the compiled default if it does not. So a project may lower
  `thinking_budget` and `tool_result_bytes` and may never raise either, and
  since the compiled default for thinking is off, a repository cannot turn
  extended thinking on at all. `auto_compact_tokens` is the one that runs the
  other way — each compaction is an extra billed request, so a project may
  push the compaction point later and never earlier. A `thinking_budget`
  between 1 and 1023 is refused at every tier: the API's floor is 1024 and it
  rejects the request, so the number would otherwise fail every turn in a
  checkout. `model` and the model-routing and telemetry keys are
  user-scope only; a project value is refused by name. Every key somebody
  might paste out of Claude Code's `settings.json` — `permissions`,
  `allow_edits`, `deny`, `sandbox`, `permission_mode`, `env`, `apiKey`,
  `mcpServers`, `plugins`, `vim`, `bindings`, `hooks` and the rest — is in the
  same table as a refusal with a sentence naming the file that really owns it,
  because a user believing a pasted file took effect is worse than any wrong
  default. A file with any problem in it contributes **nothing** and every
  problem is named in yellow at startup, like a bad deny rule; it never halts,
  because a project file is attacker-controlled. Those yellow lines are
  suppressed under `--output-format json` and `stream-json`, where stdout
  carries the protocol and nothing else — a project file must not be able to
  put prose in front of a driver's JSON — and every one of them is in the
  diagnostic ledger that `/doctor` prints regardless. Control characters are
  stripped from every string this unit hands back: a key name of `ESC[2J` in a
  cloned repository would otherwise erase the security warnings printed above
  it, and a TAB inside a value would shift the fields of the tab-separated
  `/config` row and let the file choose the tier word `/status` blames.
  `/config` prints the three
  absolute paths and a table of key, value and tier with an "overruled:" line
  under anything shadowed; `/config get` shows the whole chain, `/config set
  [--local]` writes the user file or `settings.local.json` and never the
  project file, and `/config reload` re-reads. The writer is
  read-modify-write, so a hand-written block survives — including refused keys.
  **What is narrower than Claude Code's: `settings.local.json` carries
  PROJECT authority, not user authority, because `.gitignore` is a convention
  and a repository can simply commit one.** There is no `permissions` block,
  no `env`, no `hooks`, no `mcpServers`, no `apiKeyHelper` and no enterprise
  or managed-policy tier — those are the keys the whole design exists to
  refuse. Nothing writes `<root>\.pasclaude\settings.json` ever. A settings
  file is read once at startup, so a mid-session edit needs `/config reload`,
  and even then only the three economy keys re-apply: the system prompt is
  frozen at session start for prompt-cache reasons, so a reloaded
  `output_style` needs `/output-style` and a reloaded `model` needs `/model`.
  A `-p` run inherits the file but not its `output_style` — a scripted run
  still gets a style only from `--output-style`. `keys.json` and
  `plugins.json` were deliberately NOT folded in: one is `%USERPROFILE%`-only
  by design and the other is program-written in both directions.*
- [x] ~~**/doctor, /status, /bug** — no health check, status view, or
  feedback command.~~
  *Built: one unit, `src/uDiag.pas`, holds all three as data plus pure
  renderers, so a suite asserts on the content with no console. `/status`
  reports what is true now — model and routing, credential source, mode and
  standing grants, deny count, roots, MCP servers, hooks, style, vim,
  sandbox, tokens, session file, settings — and borrows every word from the
  unit that owns it rather than restating it. `/doctor` runs thirteen named
  checks, each with a level, a stated cost and a remedy that the builder
  asserts is non-empty; it replays a note ledger recorded where startup
  already printed its yellow warnings instead of re-reading configuration,
  because `LoadMcpConfig` tears down live connections at its first line.
  `/bug` writes a redacted markdown or JSON report to
  `%LOCALAPPDATA%\pasclaude\reports\` and **uploads nothing** — there is no
  upload path, not a disabled one — refusing outright rather than falling
  back into the project when there is no home. Path redaction covers the
  session root itself, not just the `--add-dir` extras, which is the whole
  point of it: the session root is the path that names the project. With
  `--transcript`, a conversation file that could not be read back or could not
  be rewritten redacted is **deleted** and the failure said out loud, because
  the alternative is a file on disk full of whatever you pasted into the
  conversation with the console telling you in yellow that it is redacted.
  `--status` and `--doctor` are
  also top-level flags that take `--output-format json|stream-json`, exit 1
  on a problem, and are the only two modes that continue past a missing
  credential — safe because they cannot run a turn.
  Narrower than Claude Code: there is no `/doctor` auto-repair, no
  installation or update check, no IDE or terminal-integration diagnosis, no
  MCP handshake probe (servers are resolved on PATH, never spawned, because
  approving a spawn is a permission answer), no `/bug` upload to an issue
  tracker and no `/feedback` at all. Path redaction is substring matching and
  says so; reports are never pruned, only counted.*
- [x] ~~**/login, /logout** — cannot authenticate on its own; it reuses the
  token Claude Code or Jcode wrote (read-only, never refreshed) or
  `ANTHROPIC_API_KEY`.~~
  *Built: pasclaude now manages credentials, and the honest qualification is
  that it still **cannot mint one**. Anthropic documents exactly three ways
  to authenticate — a static `sk-ant-api…` key, Workload Identity Federation
  (an org-configured OIDC assertion, a CI mechanism rather than a human at a
  terminal) and App Attest on Apple platforms. There is no published
  authorization endpoint, no device-code grant, no PKCE flow and no public
  client id a third-party program may use, so a "real" OAuth login could only
  be built by borrowing Claude Code's client identity — claiming to be a
  program we are not. That was refused, and it is named here so the next
  reader does not reopen the question. A new unit `uAuth` resolves six
  sources in one documented order: `ANTHROPIC_API_KEY`,
  `ANTHROPIC_AUTH_TOKEN`, a stored preference if it names a live source,
  pasclaude's own store, Claude Code, Jcode, and — new — the `ant` CLI
  profile at `%APPDATA%\Anthropic\credentials\<profile>.json`. The two
  environment variables always win; a preference can only **choose among**
  sources this machine already has and can never introduce one, so a user who
  never runs `/login` sees exactly today's behaviour. `/login` lists every
  source with its file and a hint of the form `sk-ant-...4f2a` and never the
  value; `/login key` reads a pasted key with **nothing echoed at all** — not
  even asterisks, because a mask publishes the length — and stores it
  DPAPI-protected at `%LOCALAPPDATA%\pasclaude\credential.json`. If
  `CryptProtectData` fails nothing is written: there is no plaintext path and
  no flag that talks one into existing, and a file that cannot be decrypted
  is treated as absent with a note saying it was protected by a different
  Windows account or on different hardware. `/logout` removes **only** that
  file — Claude Code's, Jcode's and `ant`'s are read forever and written
  never, enforced by the writers taking no path argument at all — and it says
  which foreign file it declined to touch. A 401 mid-turn now names the
  source, the file, whether it has since expired, and the remedy, instead of
  printing `HTTP 401 - authentication_error`; a credential the owning program
  refreshed on disk is picked up once per request through a nil-by-default
  hook, and 401 is still not a retryable status. A credential expiring within
  fifteen minutes is announced at startup.
  **What is narrower than Claude Code's:** there is no browser sign-in, no
  token refresh of any kind, and no account or subscription management —
  pasclaude cannot renew what it did not issue. `/login` and `/logout` are
  refused in `-p` and SDK runs, which have nobody to answer them, though a
  stored credential is still used there. Only one key is stored, not a set
  per organisation or workspace, and there is no `apiKeyHelper` hook: a
  project-supplied command that prints a credential is exactly the shape this
  design exists to refuse.*
- [x] ~~**Model aliases / routing** — `/model` lists and sets models, but
  there are no aliases like `opusplan` or per-task model routing.~~
  *Built: four built-in aliases — `opus`, `sonnet`, `haiku` and the compound
  `opusplan` — plus two routes, in one table in `uAgent` with one resolution
  point. Every built-in target is a **dateless** family id, the same class of
  string `DefaultModel` already is, because a dated snapshot in this table
  would be the retired-default 404 all over again; the live `GET /v1/models`
  stays the only authority and a bare `/model` now annotates each alias
  against it, marking in yellow any target the key's own list does not
  mention. An alias name may not contain a dash or begin with `claude`, so no
  real model id can ever be shadowed by one. `opusplan` is a profile rather
  than an id: it resolves to `opus` while plan mode is on and `sonnet`
  otherwise, **evaluated per request**, so `/mode plan` changes the model
  with no extra state — and `Agent.Model` keeps the literal word, so
  `/resume` round-trips the profile and not a snapshot of whichever half was
  live at save time. Two roles are routed — the read-only subagent and the
  compaction summary — and both default to `sonnet`, which on the shipped
  default model is a **no-op**: every request carries exactly the string it
  carried before. Routing only bites once a stronger main model was chosen
  deliberately, and the banner says so. The user's own turn is never routed.
  When a turn fails with HTTP 404 and its id came from an alias, the API's
  own message gains a clause naming the alias, its target and `/model` —
  there is deliberately no startup preflight, which would cost a round trip
  on every start including `-p` and still could not be authoritative for a
  dateless name. Aliases and routes come from the **user** settings file only
  (`model.alias`, `model.route.subagent`, `model.route.compaction`); a
  project or local file is refused by name, because a repository choosing the
  model spends the user's money recurrently and can quietly downgrade the
  reviewer of its own code. `/cost` keeps its existing lines and adds a
  `by model:` block only when more than one model was actually used, since
  totals across models are no longer comparable.
  **What is narrower than Claude Code's:** there are no per-agent-definition
  or per-command model overrides, no `--model` flag (the model comes from
  `/model`, `ANTHROPIC_MODEL` or user settings), no `[1m]` context variants
  or effort suffixes, and no fallback model on overload. Still no prices, so
  the per-model block reports tokens and never money. A profile has exactly
  one axis — plan mode — so there is no way to say "haiku for this tool loop"
  or to route by prompt length. The alias table remains a table of strings
  about a namespace this program does not own; a retired target is answered
  by overriding it in `settings.json` rather than by anything automatic.*
- [x] ~~**Telemetry** — no OpenTelemetry/usage metrics export.~~
  *Built: opt-in OTLP/HTTP metrics with the JSON encoding, off by default and
  turned on only by `telemetry.enabled` plus `telemetry.endpoint` in
  `%USERPROFILE%\.pasclaude\settings.json` — both keys are user scope in the
  settings table, so a cloned repository cannot enable telemetry, name an
  endpoint, add a header or change the interval, and `OTEL_EXPORTER_OTLP_*`
  is deliberately not honoured because environment is inherited from whatever
  launched us. JSON rather than protobuf because hand-writing a protobuf
  encoder is the dependency this program keeps refusing; the spec's rules are
  obeyed literally — `/v1/metrics`, `Content-Type: application/json`,
  lowerCamelCase keys, enums as integers, int64 as decimal strings, DELTA
  temporality so a process that dies owes nothing. Five counters go out and
  nothing else: turns, tokens by kind and model, tool calls by name and
  ok/error, API requests by HTTP status, and total request milliseconds.
  Tokens are a delta against a baseline that starts at zero — where a fresh
  agent starts — and is moved by the host only when a session is *loaded*, so
  the first turn of a session counts and a resumed session never reports
  somebody else's totals as its own. That matters most where it is least
  visible: a `-p` run has exactly one turn. The
  two strings that could carry text are filtered rather than trusted — a tool
  name must be in a compile-time list of built-ins or it becomes `mcp` or
  `other`, and a model name must match `claude-[a-z0-9._-]*` or it becomes
  `other` — because both reach here from files that arrive with a clone.
  `/telemetry preview` prints the exact payload from the same builder the
  sender uses, with any collector token redacted to a length. The flush is
  synchronous at the end of a turn, at most once every `interval_turns`, and
  three consecutive failures stop it for the session with one yellow note.
  `http://` is accepted for `127.0.0.1` and `localhost` only, on an exact
  host test, and `SplitUrl` itself is unchanged so the API path cannot lose
  TLS.
  **What is narrower than Claude Code's:** metrics only — no traces, no
  spans, no logs and no events, so there is nothing to correlate a slow turn
  against. No protobuf, so a vendor endpoint that speaks only protobuf cannot
  be used at all. No histograms: latency is a request count and a millisecond
  sum, which gives a mean and never a p95. No `session.id` and no host,
  user or account attribute, so a collector cannot tell two sessions apart —
  deliberate, but it does mean per-session dashboards are impossible. No
  queue and no spool: a failed batch is discarded rather than retried, so an
  offline period is simply missing. Nothing is sent from a `-p` run that
  never reached a turn, and startup refusals send nothing at all.*

## Completed since this list was compiled

- **Todo tracking** — the `todo_write` tool maintains a task list rendered
  live in the terminal: `[x]` green, `[~]` yellow, `[ ]` grey.
- **Custom slash commands** — `/name args` reads
  `.pasclaude\commands\name.md` as the prompt with `$ARGUMENTS`
  substituted; built-ins cannot be shadowed.
- **Persistent permission rules** — "always" approvals (tool classes and
  bash programs) survive restarts in `.pasclaude\permissions.json`;
  widen-only, hand-editable, skipped by `/yolo` sessions and print mode.
  (Later moved out of the repository; see below.)
- **Memory** — `# note` appends to the project memory file under a Notes
  heading; `/memory` shows it. (User-level `~/.claude/CLAUDE.md` and
  `@import` remain missing.)
- **User-level memory and @import** — `%USERPROFILE%\.pasclaude\CLAUDE.md`
  loads before the project files (nearer wins), and `@import <path>` lines
  in instruction files inline the referenced file, one level deep.
- **Checkpointing / rewind** — `/rewind` restores the conversation and the
  edited files to the moment before a picked turn.
- **Session picker** — `/save <name>` makes named copies and `/sessions`
  lists and resumes them.
- **/init** — the model explores the project and writes a starter
  CLAUDE.md through the ordinary write approval.
- **Non-interactive mode** — `pasclaude -p "question"` answers once and
  exits with a status code; piped stdin becomes context, or the prompt
  itself when `-p` is bare. (`--output-format json` remains missing.)
- **Jcode credentials** — `~\.jcode\auth.json` is a second subscription
  token source when Claude Code's credentials are empty.
- **Subagents** — `task(prompt, agent_type?)` runs a nested agent with its
  own conversation and returns its final message as the tool result. The
  subagent is read-only — `read_file`, `list_dir`, `search`, enforced in
  `RunTool` and not only in the schema — so it needs no permission prompt
  for a conversation the user cannot see, and it cannot touch the todo
  list, the changed-file list or the rewind snapshots. One level deep,
  twelve tool rounds, one at a time; its tokens are folded into `/cost`,
  and Esc aborts both agents. Named types are markdown files under
  `.pasclaude\agents\`, exactly as slash commands are under
  `.pasclaude\commands\`.
- **Regex search and walk depth** — `search` takes `regex`,
  `case_sensitive` and `depth`; `list_dir` takes `depth` (1-12, defaults
  unchanged). The engine is an NFA simulation in `uRegex`, not FPC's
  TRegExpr, so a pattern like `(a+)+` cannot hang the session. Whole
  matching lines only, ASCII byte semantics, no backreferences or
  lookaround.
- **Notebook editing** — `read_file` renders a `.ipynb` as numbered cells
  with each output summarised by mime type and size; `notebook_edit`
  replaces, inserts or deletes one cell through `edit_file`'s permission
  gate and diff preview, writing the file back in nbformat's exact layout.
  (nbformat 4 only.)
- **Background bash** — `run_in_background` on the bash tool, `bash_output`
  to poll, `kill_bash` to stop; output spooled to a file under
  `.pasclaude\jobs` rather than a pipe; a Win32 job object per job so the
  process tree dies with pasclaude; the same per-program approval as
  foreground bash; `/jobs` to see what is running. (Jobs are stopped at
  exit, so nothing is truly detached.)
- **Web search** — the server-side `web_search` tool, declared only when
  `/web on` or `--web` says so; the API runs the search, the decoder
  round-trips `server_tool_use` and `web_search_tool_result` blocks, and a
  rejected declaration disables itself after one wasted request. `fetch` is
  unchanged and still the way to read a known URL.
- **MCP servers** — `.mcp.json` names stdio servers whose tools become
  `mcp__<server>__<tool>`; `/mcp` shows status, tool and skip counts, the
  expanded command line and the stderr path, and takes `restart <name>` and
  `refresh`. Spawning is prompted per server and "always" is bound to a hash
  of the expanded command line, its arguments and its sorted `NAME=VALUE`
  environment, not to the server's name. Discovery is cached so only the
  first run after approval spawns anything, and the tool list is frozen for
  the session so the prompt cache survives. (stdio only; tools only;
  handshake-era protocol only; no auto-restart; "always" is per server, not
  per tool.)
- **A dynamic tool registry** — a source registers a prefix matching
  `^[a-z][a-z0-9_]*__$` plus a declare and a run procedure. No built-in name
  contains `__`, so a source cannot shadow one; overlapping prefixes are
  refused, so dispatch does not depend on registration order; sources declare
  below the subagent cut, so a subagent is never told about them; and the
  dispatcher catches, because the tool loop above it does not and an escaping
  exception would leave a `tool_use` with no `tool_result`.
- **Hooks** — commands at PreToolUse, PostToolUse, UserPromptSubmit, Stop and
  SessionStart, configured in `.pasclaude\hooks.json` and gated on a
  fingerprint of its bytes, so editing it re-asks. Exit 0 proceeds, 2 blocks,
  anything else is a failure and never a block. `/hooks`, `/hooks off`.
  (SessionEnd, SubagentStop, PreCompact and Notification are deliberately not
  fired; a hook cannot cancel a turn or rewrite a tool's input.)
- **Skills and plugins** — `.pasclaude\skills\<name>\SKILL.md` is advertised
  by name and description in the `skill` tool's description and read in full
  only when the model asks; plugins under `.pasclaude\plugins\` contribute
  commands, agents and skills once enabled by name in `/plugins`. Project,
  then enabled plugins, then `%USERPROFILE%`; nearer wins and the source is
  shown. (No marketplace and no downloader, deliberately.)
- **Agent SDK** — `-p` with `--output-format json|stream-json` emits one JSON
  object per line and `--input-format stream-json` reads driver turns and
  permission responses off stdin; `src/uSdk.pas` is console-free and
  `examples/embed.lpr` embeds the agent without a terminal. (No wire
  interrupt, no `total_cost_usd`, no `--resume`, one session per process.)
- **Approvals out of the repository** — standing grants moved from
  `.pasclaude\permissions.json` to
  `%LOCALAPPDATA%\pasclaude\approvals\<project>-<hash>.json`, so a cloned
  repository cannot ship the file that answers its own permission questions.
  Existing in-repo files are not migrated and are no longer read.
- **Deny rules** — one string per rule, `tool:<glob>`, `bash:<program-glob>`
  or `path:<glob>`, in `%LOCALAPPDATA%\pasclaude\deny.json` (global,
  `/deny add|remove`) or in a hand-edited `"deny"` array in the per-root
  approvals file, round-tripped verbatim. Checked at the top of `RunTool` and
  inside `SafePath`, above every allow-all, the bash prefix table, the
  nil-`Ask` check and a `PreToolUse` hook's allow, so `/yolo`, an "always" and
  a hook are all unable to override one; a refusal names the rule and its
  file. Path rules canonicalise and also hide the file from `list_dir` and
  `search`. `-p` inherits the rules and still inherits no approvals. Nothing
  in the project tree is ever read for one. (`bash:` filters a program name
  and is evadable — `tool:bash` is the airtight form; `path:` does not cover
  the shell; `fetch:<host>` is deliberately not offered.)
- **Permission modes** — `ask`, `plan`, `accept-edits` and `bypass`, shown as
  one word on the prompt and set only by `--permission-mode`,
  `--dangerously-skip-permissions`, `/mode`, `/plan` or `/yolo`. Plan mode is
  a boundary in `RunTool` beside the subagent read-only list, above the
  `PreToolUse` fire and far above the gate, permitting an eight-name
  allowlist; accept-edits is the existing `AllowAllEdits` flag given a name,
  an indicator and an off switch. (No `exit_plan_mode` tool, deliberately;
  no mode is persisted or resumed; plan mode stops the model, not the user's
  own hooks.)
- **Additional working directories** — `--add-dir <dir>` and `/add-dir` add
  directories the file tools may work in; `/cwd` lists them and
  `/remove-dir` takes one away. One resolution base, so a relative path
  always means the session root and an added directory can only make a
  refused absolute path succeed. An added root grants file access and nothing
  else — its hooks, skills, commands, agents, `.mcp.json` and `CLAUDE.md` are
  unread — and roots come only from argv or a typed command, never from a
  file, and are never persisted.
- **Sandboxed child processes** — every child pasclaude starts is created by
  `src/uSandbox.pas` inside a job object: 64 processes, no breakaway, no
  clipboard or desktop access, killed with the session. `--sandbox low` and
  `/sandbox low` add a low-integrity token and a scratch `%TEMP%` out of
  tree. This also gave the foreground shell a job object it never had and
  closed the grandchild-escape race at all three spawn sites. (Low integrity
  stops writes and registry persistence and nothing else — not reads, not the
  network — which is why it changes nothing about what you are asked to
  approve. `/sandbox off` keeps kill-on-close.)

- **Output styles** — `/output-style` lists what is available and marks the
  one in force, `/output-style <name>` sets it, `--output-style <name>` does
  it from the command line and is the only way in under `-p`. Three built-ins
  compiled in, plus a flat `<name>.md` in `.pasclaude\styles\`, an enabled
  plugin's `styles\` or `%USERPROFILE%\.pasclaude\styles\`, nearer winning,
  read by the same frontmatter parser `SKILL.md` uses. A style ADDS one
  paragraph to the system prompt and can never replace one: the body has
  exactly one reader, a string concatenation in `SessionNote`, and no
  frontmatter key maps to a setting. It rides in the uncached trailing block
  ahead of the plan paragraph and behind nothing, with the deny sentence
  permanently last, capped at 2 KB and cut on a character boundary. The name
  and the source it resolved from persist under `%LOCALAPPDATA%`, never in
  the project; a name that now resolves somewhere else falls back to
  `default` with a yellow line. (The body is read once at set time, so an
  edited file applies after re-running `/output-style <name>`.)
- **Image input** — `@shot.png` attaches an image instead of refusing it as a
  binary, and `/paste` takes one off the clipboard (`/paste drop` cancels).
  Both report dimensions, bytes and the real token cost from the documented
  patch formula. png, jpeg, gif and webp, base64 only, 8 per message;
  mentioned files go up untouched under 5 MB, clipboard pixels are encoded
  here over STORED deflate blocks because paszlib is a package and the API
  takes no BMP. Pasted images are capped at 2 MB and downscaled at most twice
  before an honest refusal. Images live only in user messages and never in a
  tool result; `width`/`height` are local keys stripped from the request
  body; `ValidTranscript` and `SessionVersion` were not touched, so they
  round-trip through save, load and `--resume`; and compaction evicts all but
  the two newest by substituting a placeholder rather than deleting a block.
  (An image can carry instructions a transcript reader cannot see. Nothing
  detects that; what bounds it is that only your own `@mention` or `/paste`
  can put one in, both through the same path guard a tool call goes through.)
- **Vim mode and keybindings** — `/vim` turns on a modal editor with `[I]`
  and `[N]` on the prompt, motions, the `d`/`c` compounds, and undo with a
  whole insert session as one step; `/vim save` keeps it and `/keys` lists
  the table. `%USERPROFILE%\.pasclaude\keys.json` rebinds over built-in
  Ctrl+W, Ctrl+K, Alt+B, Alt+F and Ctrl+Z, with every refused entry reported
  by name. No project scope, ever: a `git clone` cannot choose what your
  keyboard does. A binding cannot reach a permission prompt, and three
  independent things stop it — the chord grammar cannot spell `y`, `a` or
  `n`; an action is a buffer-editing verb and `ekChar` has no name at all;
  and every prompt but the REPL reads through `ReadLineEdit`, which passes
  the empty profile. Nothing here enters the model's context.
- **Session resume under `-p`** — `--session-file <path>` names the
  transcript a scripted run saves to after every turn, before the `result`
  line so a driver may spawn the next process the moment it reads one, and
  with `--resume` continues it. It is the whole opt-in: without it `-p`
  writes nothing and the directory's own conversation is untouched, and
  `--resume` under `-p` without it is a startup error rather than a guess.
  The path goes through the tools' own root guard and the file is the
  ordinary session file, so a script's transcript opens in the REPL and back.
  An absent file is a fresh start; an unreadable one stops the run with exit
  2 rather than doing work on absent context and then overwriting the
  evidence. The init line reports `resumed`, `resumed_messages` and
  `session_file` on every run. A resumed run restores messages, model and
  counters and nothing else, so it can never come back more permissive than a
  fresh one. (Nothing is compacted on this path, and two processes sharing
  one file race with last writer winning.)
- **settings.json and a scope table** — three tiers (user, project, local),
  fourteen keys, and one `TierAllowed` question asked from one place:
  `SettingsStore`, the only writer of a value. A project may set
  `output_style` and three economy numbers, and only in the direction that
  costs less than the value the user has in force; `model`, the routing keys
  and the telemetry keys are user scope, and a project value is never stored.
  Twenty-seven pasted-from-Claude-Code names are refused by name with a
  sentence saying where the thing really lives. Any problem voids the whole
  file, loudly and never fatally. `/config` shows every key, its value and its
  tier; `/config set [--local]` writes the user file or the local one and
  never the project file, read-modify-write so a hand-written block survives.
- **Model aliases and routing** — `opus`, `sonnet`, `haiku` and the
  `opusplan` profile, all dateless, plus two routed roles (the read-only
  subagent and the compaction summary) that default to `sonnet` and are
  therefore a no-op on the shipped model. The profile is resolved per request,
  so `/mode plan` changes the model with no extra state. A 404 whose id came
  from an alias says which alias. Aliases and routes come from the user
  settings file only. `/cost` gains a `by model:` block once more than one
  model was used.
- **/login and /logout** — six credential sources in one documented order,
  environment first; `/login` lists them with a hint and never the value and
  can record a preference among the ones this machine already has; `/login
  key` stores one of pasclaude's own, DPAPI-protected under `%LOCALAPPDATA%`,
  with no plaintext path if the encryption fails. `/logout` removes that file
  and refuses when the credential in force belongs to Claude Code, Jcode or
  the `ant` CLI — enforced by the writers taking no path argument at all. A
  401 names the source, the file and the remedy. There is still no login that
  logs in: no public grant is documented, and borrowing another program's
  client identity was refused.
- **Telemetry** — opt-in OTLP/HTTP metrics with the JSON encoding, off unless
  both `telemetry.enabled` and `telemetry.endpoint` are in the *user*
  settings file; `OTEL_EXPORTER_OTLP_*` is deliberately not honoured. Five
  counters and two filtered attribute strings leave the machine and nothing
  else — no text of any kind, no paths, no host or session id. `/telemetry
  preview` prints the exact payload from the sender's own builder. Synchronous
  end-of-turn flush, discard on failure, self-disabling after three.
- **/status, /doctor and /bug** — one unit holding all three as records with
  renderers pure in their record, so the console and JSON views cannot
  disagree. `/status` borrows every word from the unit that owns it;
  `/doctor` runs thirteen checks with a stated cost each, sends nothing
  without `--online`, and replays a startup note ledger rather than
  re-reading configuration; `/bug` writes a redacted report out of tree and
  uploads nothing. `--status` and `--doctor` are also flags, honour
  `--output-format`, exit 1 on a problem, and are the only modes that
  continue past a missing credential.

*Compiled from `README.md` and the `src/` units at
`E:\Projects\pascal\pasclaude`, compared against the public Claude Code
feature set.*
