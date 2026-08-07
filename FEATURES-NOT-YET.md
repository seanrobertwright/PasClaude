# Claude Code features not yet in pasclaude

pasclaude already covers a lot of the core experience: streaming chat with
markdown rendering, eight tools (read_file, write_file, edit_file, list_dir,
search, bash, fetch, todo_write) behind a diff-previewing permission gate,
per-program bash approval, CLAUDE.md / AGENTS.md / .pasclaude.md project
instructions, `@path` file mentions, tab completion, persistent history,
session save/resume with validation, automatic context trimming plus
token-triggered summarizing compaction, prompt caching with cost counters,
retry with Retry-After, extended thinking, `.gitignore`-aware
listing/search, git status in the system prompt, and reuse of Claude Code's
or Jcode's OAuth credentials.

Checked items have been built since this list was compiled; the strikethrough
text preserves what was missing at the time. Unchecked items remain open.

## Agents and tools

- [ ] **Subagents / Task tool** — no way to spawn parallel or specialized
  agents (`.claude/agents`, the Task tool, agent teams).
- [ ] **Web search** — `fetch` does an HTTPS GET of a known URL; there is no
  WebSearch tool.
- [x] ~~**Todo tracking** — no TodoWrite/task-list tool for plan visibility
  on multi-step work.~~
  *Built: the `todo_write` tool maintains a task list rendered live in the
  terminal (`[x]` green, `[~]` yellow, `[ ]` grey).*
- [ ] **Background bash** — shell commands are synchronous with a 120 s
  timeout; no run-in-background, output polling, or kill.
- [ ] **Notebook editing** — no Jupyter (`.ipynb`) aware read/edit.
- [ ] **Regex search** — `search` does case-insensitive substrings and `*`
  globs, not the full regex Grep of Claude Code; `list_dir` is capped at
  depth 4.

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

*Compiled from `README.md` and the `src/` units at
`E:\Projects\pascal\pasclaude`, compared against the public Claude Code
feature set.*
