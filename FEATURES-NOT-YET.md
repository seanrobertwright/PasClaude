# Claude Code features not yet in pasclaude

pasclaude already covers a lot of the core experience: streaming chat with
markdown rendering, seven tools (read_file, write_file, edit_file, list_dir,
search, bash, fetch) behind a diff-previewing permission gate, per-program
bash approval, CLAUDE.md / AGENTS.md / .pasclaude.md project instructions,
`@path` file mentions, tab completion, persistent history, session
save/resume with validation, automatic context trimming plus token-triggered
summarizing compaction, prompt caching with cost counters, retry with
Retry-After, extended thinking, `.gitignore`-aware listing/search, git status
in the system prompt, and reuse of Claude Code's OAuth credentials.

Since this list was first compiled, the following have been built: print
mode (`-p`, piped stdin), a `todo_write` task-list tool with terminal
rendering, persistent permission rules (`.pasclaude\permissions.json`),
custom slash commands (`.pasclaude\commands\*.md` with `$ARGUMENTS`),
project memory (`#` notes, `/memory`, `/init`), and Jcode's `auth.json` as
a second subscription-token source.

The following Claude Code features are missing.

## Agents and tools

- **Subagents / Task tool** — no way to spawn parallel or specialized agents
  (`.claude/agents`, the Task tool, agent teams).
- **Web search** — `fetch` does an HTTPS GET of a known URL; there is no
  WebSearch tool.
- **Background bash** — shell commands are synchronous with a 120 s timeout;
  no run-in-background, output polling, or kill.
- **Notebook editing** — no Jupyter (`.ipynb`) aware read/edit.
- **Regex search** — `search` does case-insensitive substrings and `*` globs,
  not the full regex Grep of Claude Code; `list_dir` is capped at depth 4.

## Extensibility

- **MCP (Model Context Protocol)** — no external MCP servers, `.mcp.json`,
  or `/mcp`.
- **Hooks** — no PreToolUse/PostToolUse or other lifecycle hooks.
- **Skills / plugins** — no plugin marketplace or skill packs.
- **Agent SDK** — no programmatic embedding.

## Permissions

- **Deny rules** — approvals persist (`.pasclaude\permissions.json`), but
  there is no deny list: nothing can be marked never-allowed.
- **Permission modes** — no plan mode, no accept-edits mode, no
  `--dangerously-skip-permissions` flag (`/yolo` is per-session only).
- **Sandboxed bash** — commands run directly through `cmd.exe /C`,
  unsandboxed (compound commands are re-prompted, but not isolated).
- **Additional working directories** — one session root, fixed at startup;
  no `--add-dir`.

## Sessions and memory

- **Checkpointing / rewind** — no Esc-Esc rewind, no `/rewind`, no restoring
  code + conversation to an earlier point.
- **Session picker** — one session per directory (the previous one is moved
  to `session.prev.json`, not offered); no list of past sessions, no naming,
  no `--continue` vs `--resume` distinction.
- **User-level memory** — `#`, `/memory` and `/init` exist, but only for the
  project file; no user-level `~/.claude/CLAUDE.md`, no `@import`.

## Input and output

- **Structured output** — `-p` print mode and piped stdin exist, but there
  is no `--output-format json` / `stream-json`.
- **Image input** — cannot paste or attach screenshots/images.
- **Vim mode / keybindings** — line editing is fixed (arrows, Home/End,
  Ctrl+A/E/U); no `/vim`, no configurable keybindings.
- **Output styles** — no `/output-style`.

## Integrations

- **IDE integrations** — no VS Code or JetBrains extension awareness
  (diff-in-editor, selection as context).
- **GitHub Actions / `@claude` mentions** — no CI integration.
- **/review, /pr-comments, /install-github-app** — no built-in PR workflow
  commands (git itself works through bash, and `/diff` summarizes changes).

## Configuration and diagnostics

- **settings.json** — no hierarchical user/project/local config, no
  `/config`.
- **/doctor, /status, /bug** — no health check, status view, or feedback
  command.
- **/login, /logout** — cannot authenticate on its own; it reuses the token
  Claude Code wrote (read-only, never refreshed) or `ANTHROPIC_API_KEY`.
- **Model aliases / routing** — `/model` lists and sets models, but there
  are no aliases like `opusplan` or per-task model routing.
- **Telemetry** — no OpenTelemetry/usage metrics export.

*Compiled from `README.md` and the `src/` units at
`E:\Projects\pascal\pasclaude`, compared against the public Claude Code
feature set.*
