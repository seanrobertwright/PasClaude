# Claude Code features not yet in pasclaude

pasclaude already covers a lot of the core experience: streaming chat with
markdown rendering, twelve tools (read_file, write_file, edit_file,
notebook_edit, list_dir, search, bash, bash_output, kill_bash, fetch,
todo_write, task) behind a diff-previewing permission gate, per-program bash
approval, an opt-in server-side web_search, regex search and notebook-aware
read/edit, background shell jobs, read-only subagents, CLAUDE.md /
AGENTS.md / .pasclaude.md project instructions, `@path` file mentions, tab
completion, persistent history, session save/resume with validation,
automatic context trimming plus token-triggered summarizing compaction,
prompt caching with cost counters, retry with Retry-After, extended
thinking, `.gitignore`-aware listing/search, git status in the system
prompt, and reuse of Claude Code's or Jcode's OAuth credentials.

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

- [ ] **MCP (Model Context Protocol)** — no external MCP servers,
  `.mcp.json`, or `/mcp`.
- [ ] **Hooks** — no PreToolUse/PostToolUse or other lifecycle hooks.
- [x] ~~**Custom slash commands** — no `.claude/commands/*.md` user-defined
  commands.~~
  *Built: `/name args` reads `.pasclaude\commands\name.md` as the prompt
  with `$ARGUMENTS` substituted; built-ins cannot be shadowed.*
- [ ] **Skills / plugins** — no plugin marketplace or skill packs.
- [ ] **Agent SDK** — no programmatic embedding.

## Permissions

- [x] ~~**Persistent permission rules** — "always" approvals (per tool
  class, per bash program) last one session; there is no `settings.json`
  allow/deny rule list that survives restarts.~~
  *Built: approvals persist in `.pasclaude\permissions.json` (widen-only,
  hand-editable; `/yolo` sessions never write it, print mode never reads
  it). Still missing: deny rules — nothing can be marked never-allowed.*
- [ ] **Permission modes** — no plan mode, no accept-edits mode, no
  `--dangerously-skip-permissions` flag (`/yolo` is per-session only).
- [ ] **Sandboxed bash** — commands run directly through `cmd.exe /C`,
  unsandboxed (compound commands are re-prompted, but not isolated).
- [ ] **Additional working directories** — one session root, fixed at
  startup; no `--add-dir`.

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
  bare. Still missing: `--output-format json` / `stream-json`.*
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

*Compiled from `README.md` and the `src/` units at
`E:\Projects\pascal\pasclaude`, compared against the public Claude Code
feature set.*
