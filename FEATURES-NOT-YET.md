# Claude Code features not yet in pasclaude

pasclaude already covers a lot of the core experience: streaming chat with
markdown rendering, thirteen tools (read_file, write_file, edit_file,
notebook_edit, list_dir, search, bash, bash_output, kill_bash, fetch,
todo_write, skill, task) behind a diff-previewing permission gate,
per-program bash approval, an opt-in server-side web_search, regex search
and notebook-aware read/edit, background shell jobs, read-only subagents,
CLAUDE.md / AGENTS.md / .pasclaude.md project instructions, `@path` file
mentions, tab completion, persistent history, session save/resume with
validation, automatic context trimming plus token-triggered summarizing
compaction, prompt caching with cost counters, retry with Retry-After,
extended thinking, `.gitignore`-aware listing/search, git status in the
system prompt, and reuse of Claude Code's or Jcode's OAuth credentials.

It now also covers the extensibility surface: MCP servers over stdio behind a
per-command-line spawn prompt, lifecycle hooks at five points in a turn behind
a fingerprint prompt, skills and plugins discovered from disk, a dynamic tool
registry any future source can plug into, and an SDK — `-p` with
`--output-format json|stream-json` and `--input-format stream-json` — plus a
console-free embedding facade in `src/uSdk.pas`. Standing approvals moved out
of the project to `%LOCALAPPDATA%\pasclaude\approvals\`, so a repository can no
longer ship the file that answers its own permission questions.

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
  had accumulated
  approvals in an in-repo `.pasclaude\permissions.json` is simply re-asked,
  with no notice explaining why.*
- [x] ~~**Permission modes** — no plan mode, no accept-edits mode, no
  `--dangerously-skip-permissions` flag (`/yolo` is per-session only).~~
  *Built: four modes, shown as one word — `ask`, `plan`, `accept-edits`,
  `bypass` — behind two pieces of state rather than one ladder, because plan
  has to beat bypass. Plan mode is a boundary enforced in `RunTool` beside the
  subagent read-only list, above the `PreToolUse` fire and far above the gate,
  so bypass, a class allow-all, a stored bash prefix, a hook's `allow` and a
  nil `Ask` are all structurally unable to lift it; what it permits is an
  allowlist (`read_file`, `list_dir`, `search`, `todo_write`, `skill`, `task`,
  `bash_output`, `fetch`), so a third-party MCP verb or a tool added next year
  is refused without anyone deciding to refuse it. The model learns the mode
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
  would still hand over by its absolute name. An added root grants file access and nothing else: its
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
  permission requests. Still missing: no mid-turn interrupt over the wire, no
  `total_cost_usd` on the result line, and no `--resume` in SDK mode. See the
  Agent SDK entry above.*
- [ ] **Image input** — cannot paste or attach screenshots/images.
- [ ] **Vim mode / keybindings** — line editing is fixed (arrows, Home/End,
  Ctrl+A/E/U); no `/vim`, no configurable keybindings.
- [ ] **Output styles** — no `/output-style`.

## Integrations

- [ ] **IDE integrations** — no VS Code or JetBrains extension awareness
  (diff-in-editor, selection as context).
- [ ] **GitHub Actions / `@claude` mentions** — no CI integration.
- [ ] **/review, /pr-comments, /install-github-app** — no built-in PR
  workflow commands (git itself works through bash, and `/diff` summarizes
  changes).

## Configuration and diagnostics

- [ ] **settings.json** — no hierarchical user/project/local config, no
  `/config`.
- [ ] **/doctor, /status, /bug** — no health check, status view, or
  feedback command.
- [ ] **/login, /logout** — cannot authenticate on its own; it reuses the
  token Claude Code or Jcode wrote (read-only, never refreshed) or
  `ANTHROPIC_API_KEY`.
- [ ] **Model aliases / routing** — `/model` lists and sets models, but
  there are no aliases like `opusplan` or per-task model routing.
- [ ] **Telemetry** — no OpenTelemetry/usage metrics export.

## Completed since this list was compiled

- **Todo tracking** — the `todo_write` tool maintains a task list rendered
  live in the terminal: `[x]` green, `[~]` yellow, `[ ]` grey.
- **Custom slash commands** — `/name args` reads
  `.pasclaude\commands\name.md` as the prompt with `$ARGUMENTS`
  substituted; built-ins cannot be shadowed.
- **Persistent permission rules** — "always" approvals (tool classes and
  bash programs) survive restarts in `.pasclaude\permissions.json`;
  widen-only, hand-editable, skipped by `/yolo` sessions and print mode.
  (Deny rules remain missing.)
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

*Compiled from `README.md` and the `src/` units at
`E:\Projects\pascal\pasclaude`, compared against the public Claude Code
feature set.*
