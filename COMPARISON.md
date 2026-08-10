# pasclaude vs Claude Code — Side-by-Side Feature Comparison

**Snapshot date:** 2026-08-09.
**pasclaude side:** branch `feat/integrations` at `67e0b71`, `v0.1` — compiled from
`src/` (22 units), `README.md`, and `FEATURES-NOT-YET.md`, with source-level evidence
cited per claim where it matters. The rows were drafted against the working tree
rather than against the commit below it, which is why several already describe the
round that landed in `67e0b71`: `uArgs`, the 250 ms prompt idle tick, verbatim
notebook escapes and the user-scope MCP spool move.
**Claude Code side:** the official documentation at `code.claude.com/docs` (fetched
live on the snapshot date). Claude Code versions referenced there reach into the
`v2.1.2xx` series. Claude Code ships roughly weekly and moves fast; anything written
about it decays. Treat this document as a point-in-time photograph, not a live diff.

## What each thing is

| | **pasclaude** | **Claude Code** |
| --- | --- | --- |
| Identity | A terminal coding agent in Free Pascal, deliberately dependency-free: WinHTTP bound at runtime, hand-written JSON DOM, Win32 console, hand-written PNG encoder, hand-written NFA regex engine. One `.exe`, built by `build.cmd`. | Anthropic's official agentic coding tool. TypeScript on a Node/Bun runtime, distributed via native installer (auto-updating), Homebrew, WinGet, and Linux package managers. |
| Platforms | Windows only (`x86_64-win64`, FPC 3.2.x), by construction: `cmd.exe`, WinHTTP, DPAPI, Win32 job objects. | Terminal on macOS/Linux/Windows (WSL2 recommended for sandboxing); plus a VS Code extension, JetBrains plugin, Desktop app (macOS/Windows), web (`claude.ai/code`), mobile apps, Slack, and a Chrome integration. |
| Model access | Anthropic Messages API only; endpoint is a compiled constant (`api.anthropic.com`), no base-URL override, no Bedrock/Vertex. | Anthropic API, Claude subscriptions, Amazon Bedrock, Google Cloud Agent Platform, Microsoft Foundry, and third-party provider gateways. |
| Concurrency model | Single-threaded by explicit design; every concurrency argument in the codebase depends on it. | Multi-process/multi-session: parallel subagents, background tasks, agent teams, cloud sessions. |
| Posture | A reimplementation that documents every refusal and every residual in prose; `FEATURES-NOT-YET.md` has no unchecked boxes left, only "Still missing" clauses. | A product surface that keeps absorbing new categories (routines, channels, design sync, voice). |

**Legend for the tables below**

- ✅ implemented, at or near parity
- 🟨 implemented, deliberately narrower or differently designed
- ❌ not implemented
- ⊘ deliberately refused, with the reason documented in the pasclaude sources

## How to read a ❌

The legend above separates *refused* from *not implemented*, and that separation is
the most useful thing in this document — but ❌ is still doing two very different
jobs, and a reader counting marks will misjudge the distance badly. Every ❌ below is
one of two kinds:

**Structural** — a property of the language, the platform or the process model, which
no amount of ordinary work closes. Three facts account for almost all of them:

1. **Windows only, by construction.** A port touches five of twenty-one units —
   `uHttp` (WinHTTP), `uTerm` (the Win32 console and the 250 ms wait the idle tick is
   built on), `uSandbox` (job objects, integrity levels), `uImage` (`CF_DIB`), and the
   path conventions in `uTools` that the deny rules and the root guard both require to
   be canonical. The reason `uSandbox` is unportable is exactly the reason it is
   testable: it imports `Windows` and `SysUtils` and nothing else.
2. **No threads.** Five separate ❌ rows are this one fact wearing different names —
   parallel subagents (§9), agent teams (§9), sequential MCP first-connect (§10), the
   wire `interrupt` refused by name (§16), and one session per process (§16).
3. **No distribution story.** Auto-update, `/upgrade` and `/release-notes` (§1, §6)
   cannot be cloned without first inventing the pipeline they report on.

**Residual** — nobody has done it and nothing structural stops anyone. This is the
much smaller set, and §23 ranks the four that would actually move the program.

⊘ is a third thing again, and it is not work. Closing that column does not finish the
project; it reverses it. The settings scope table (§14), the CI ceiling (§17), the
refusal of `exit_plan_mode` (§4) and of a plugin downloader (§13) are load-bearing for
the security posture, and each carries its argument at the site that enforces it.

---

## 1. Platform, distribution, surfaces

| Feature | Claude Code | pasclaude |
| --- | --- | --- |
| Terminal CLI | ✅ full-featured | ✅ the only surface |
| IDE extensions | ✅ VS Code + Cursor extension (inline diffs, @-mentions, plan review, history); JetBrains plugin (interactive diff, selection context) | 🟨 detects the editor around the terminal (`TERM_PROGRAM=vscode`+`VSCODE_INJECTION`, `TERMINAL_EMULATOR=JetBrains-JediTerm`, exact equality); `/ide open <path>[:line]` and `/ide diff` only. Extension ⊘ (second toolchain the repo refuses); reading editor selection ⊘ (no channel exists — nothing an integrated terminal exports names a file/line/selection). |
| Desktop app | ✅ macOS/Windows/ARM64 — visual diffs, side-by-side sessions, scheduled tasks, cloud sessions | ❌ |
| Web / mobile | ✅ claude.ai/code, iOS/Android, Teleport (`claude --teleport` pulls a web session into the terminal), Remote Control, Dispatch | ❌ |
| Chat integrations | ✅ Slack (`@Claude` → PRs), Channels (Telegram/Discord/iMessage/webhooks) | ❌ |
| Browser integration | ✅ Chrome ("claude-in-chrome", debugging live web apps) | ❌ |
| Auto-update | ✅ native installs update in background; stable + latest channels | ❌ ⊘ no release pipeline at all; the CI workflow clones and compiles |
| Routines / scheduled work | ✅ Routines (cloud cron, API/GitHub triggers), Desktop scheduled tasks, `/loop`, `/schedule` | ❌ |
| CLI subcommand family | ✅ `claude mcp …`, `claude plugin …`, `claude agents`, `claude attach/logs/stop/rm/respawn`, `claude daemon`, `claude auth login/logout/status`, `claude doctor`, `claude install/update`, `claude import codex|gemini`, `claude setup-token`, `claude project purge`, `claude ultrareview`, `claude gateway`, `claude remote-control` | 🟨 a single binary with flags only (`--status`, `--doctor`, `--ci prepare|report`); no subcommand tree |

---

## 2. Core agent loop

| Feature | Claude Code | pasclaude |
| --- | --- | --- |
| Streaming replies | ✅ | ✅ SSE decoder over content-block deltas (`uAgent`), markdown rendered as it arrives, line-buffered |
| Extended thinking | ✅ toggle in-session (`Alt+T`), `alwaysThinkingEnabled`, `MAX_THINKING_TOKENS` | ✅ `/think [n]` budget (default 8192, floor 1024 rounded up); thinking streams in grey; `max_tokens` grows by the budget |
| Effort levels | ✅ `/effort low…xhigh/max/ultracode`, `effortLevel` setting | ❌ |
| Fast mode / advisor | ✅ `/fast`, `/advisor` (second model consulted for guidance) | ❌ |
| Auto-compaction | ✅ `autoCompactEnabled`, `autoCompactWindow` (100k–1M tokens), `DISABLE_AUTO_COMPACT` | ✅ two triggers: byte-based trim (~100 KB, `/compact`) and token-based summarizing compaction (default 150k measured prompt tokens, `/compact full`); summary compaction is atomic — failed/cancelled/empty summary restores the transcript byte for byte |
| Manual compaction | ✅ `/compact [focus instructions]` | ✅ `/compact`, `/compact full` (model-written summary preserving paths, decisions, unfinished work) |
| Retry on overload | ✅ `fallbackModel` chain (up to 3), StopFailure hook event names rate_limit/overloaded/etc. | 🟨 3 retries with widening delay on 429/529/5xx, interruptible sleeps, honours `Retry-After` clamped to 60 s; no fallback model |
| Prompt caching | ✅ | ✅ two `cache_control` breakpoints (system+tools, last message); `/cost` shows cache counters |
| Interruption | ✅ Esc stops the turn, keeps work so far | ✅ Esc or Ctrl+C mid-stream; partial text kept, pending tool not run, transcript unwound to an API-legal shape; Ctrl+Break deliberately still kills the process |
| Context inspection | ✅ `/context` coloured grid with suggestions | 🟨 statusline context meter vs the compaction point; `/cost` shows measured `context:` tokens |
| Cost tracking | ✅ `/usage` with dollar costs, plan limits, rate limits | 🟨 `/cost` — turns, tokens by kind, per-model token rows, cache counters. **No money, deliberately**: pasclaude ships no price table, and a hardcoded one "becomes a lie the first time a model is repriced" |
| Model selection | ✅ `/model`, settings `model`, `availableModels` allowlist, `fallbackModel` | ✅ `/model` fetches the live list from `GET /v1/models` (the only authority — a dateless alias can't 404 like a dated snapshot); `/model <name>` unvalidated by design |
| Model aliases/routing | ✅ alias names (`sonnet`, `opus`, `haiku`, …), per-skill/per-agent model overrides | 🟨 four dateless aliases (`opus`, `sonnet`, `haiku`, `opusplan` — a profile resolved per request by plan mode) plus two routed roles (subagent, compaction summary); user-scope only; a repository may never choose the model that reviews it |
| Max agentic rounds | ✅ `--max-turns` | 🟨 fixed caps: 24 rounds main loop, 12 for subagents |
| Multi-turn tool loop | ✅ | ✅ `TAgent.Send` → `RunTools` → append results → repeat |

---

## 3. Built-in tools

pasclaude has 13 gated/ungated tools plus one server-side tool and MCP tools; Claude
Code's toolset is larger and still growing (the docs' background-subagent list alone
names `Read, Grep, Glob, Bash, PowerShell, Edit, Write, NotebookEdit, WebFetch,
WebSearch, TodoWrite, Skill, ToolSearch, EnterWorktree, ExitWorktree, Monitor,
TaskStop, SendMessage, Artifact`).

| Capability | Claude Code tool | pasclaude tool | Notes |
| --- | --- | --- | --- |
| Read files | `Read` | `read_file` | pasclaude: line-numbered, 400 KB cap, hex dump for binary, `.ipynb` rendered as numbered cells; image/PDF vision in tool results ❌ (deliberate — "a tool result has no human in the loop") |
| Write files | `Write` | `write_file` | both gated with diff preview |
| Edit files | `Edit` | `edit_file` | pasclaude supports an atomic `edits` array (multiple replacements, all-or-nothing) through one approval prompt |
| List/glob | `Glob` | `list_dir` (`recursive`, `depth` 1–12) | `.gitignore`-aware, skips `.git`/`node_modules`/`.pasclaude` |
| Search content | `Grep` (ripgrep) | `search` (`regex`, `case_sensitive`, `depth`, glob filter) | pasclaude's engine is a hand-written NFA simulation (`uRegex`) so `(a+)+` cannot hang the session; whole-line matches only, no backreferences/lookaround, byte-quantifiers |
| Shell | `Bash` (+ `PowerShell` on Windows) | `bash` (`cmd.exe /C`) | pasclaude: 120 s timeout, per-program approval, compound commands always re-prompt, `run_in_background` with `bash_output`/`kill_bash`, 8 jobs max, 16 MB output cap enforced on a 250 ms sweep. CC auto-runs a built-in read-only command set (ls, cat, grep, read-only git, …) without prompting |
| Background output/kill | `BashOutput` / `KillShell` | `bash_output` / `kill_bash` | ✅ parity of shape |
| Background tasks generally | ✅ background agents, `Monitor` tool, `TaskStop`, auto-backgrounding of long MCP calls | 🟨 background bash jobs only (`/jobs`); jobs are killed at exit by design — no detached servers |
| Fetch URL | `WebFetch` | `fetch` | pasclaude: HTTPS GET only, own approval class, 200 KB cut during transfer; host-based deny rules ⊘ because WinHTTP follows redirects |
| Web search | `WebSearch` (client tool) | `web_search` (server-side Anthropic tool) | pasclaude declares it only when `/web on` or `--web`; results clipped at 32 KB on result boundaries; off by default, never persisted |
| Notebooks | `NotebookEdit` | `notebook_edit` (+ `read_file` cell view) | pasclaude is byte-faithful to nbformat v4 (arrival-form escapes preserved, Python `splitlines` line cutting); v3 refused by name rather than non-reproducibly upgraded |
| Todo list | `TodoWrite` — **disabled by default since v2.1.142**, superseded by the `TaskCreate/Get/List/Update` system | `todo_write` | pasclaude renders live `[x]`/`[~]`/`[ ]` coloured |
| Subagents | `Agent` (formerly `Task`) | `task` | see §9 |
| Skills invocation | `Skill` | `skill` | both declare the catalogue in the tool description |
| Ask user questions | `AskUserQuestion` | ❌ | pasclaude asks through the ordinary permission prompt and REPL |
| Plan-mode tools | `EnterPlanMode` / `ExitPlanMode` | ❌ ⊘ see §4 | |
| LSP | `LSP` (jump-to-def, references, type errors) | ❌ | |
| Watchers/monitors | `Monitor` (command/WebSocket sources), `WaitForMcpServers`, `FileChanged` hooks | 🟨 background bash jobs only (`/jobs`) | |
| Worktrees | `EnterWorktree`/`ExitWorktree`, `--worktree`, `--tmux` | ❌ | |
| Scheduling | `RemoteTrigger` (`/schedule` Routines), `ScheduleWakeup` (`/loop`), `CronCreate/Delete/List` | ❌ | |
| Cross-session messaging / teams | `SendMessage`, `ListAgents`, `SendUserFile`, `PushNotification`, `TaskCreate/Get/List/Update` | ❌ | |
| Workflows / reviews | `Workflow` (multi-subagent), `ReportFindings` (structured review findings), `/ultrareview` | ❌ | |
| Artifacts / tool search / voice / browser | `Artifact`, `ToolSearch`, voice, Chrome tools | ❌ | |
| MCP resources | `ListMcpResourcesTool` / `ReadMcpResourceTool` | ❌ | |
| MCP tools | `mcp__<server>__<tool>` | `mcp__<server>__<tool>` | identical naming convention |
| Dynamic tool registry | n/a (built-in) | ✅ `^[a-z][a-z0-9_]*__$` prefix registration, overlap refusal, dispatcher exception catch — the seam MCP and any future source plug into | |

Tool-result budgeting: Claude Code caps MCP output at 25k tokens by default
(`MAX_MCP_OUTPUT_TOKENS`); pasclaude caps every tool result at 30 KB
(`tool_result_bytes`, project settings may only lower it).

---

## 4. Permissions and sandboxing

| Feature | Claude Code | pasclaude |
| --- | --- | --- |
| Permission modes | `default` (UI label "Manual"), `acceptEdits` (also auto-accepts mkdir/touch/mv/cp in workdir), `plan`, `auto` (background safety classifier), `dontAsk` (auto-deny unless pre-approved), `bypassPermissions`; cycled with Shift+Tab. Bypass keeps circuit breakers: `rm -rf /` and `~` still prompt, incl. via `$(...)`/backticks/process substitution | `ask`, `accept-edits`, `plan`, `bypass` via `--permission-mode`, `--dangerously-skip-permissions`, `/mode`, `/plan`, `/yolo`. No classifier, no auto mode |
| Plan mode | ✅ read-only research phase with an `ExitPlanMode` tool the model invokes | 🟨 plan enforced as a boundary in `RunTool` above the gate (allowlist of 7 read-only tools) so even bypass cannot lift it. `exit_plan_mode` tool ⊘ — "a tool that lets the model leave plan mode is a tool that lets it grant itself write access"; leaving is always a keystroke |
| Rule lists | `permissions.allow/ask/deny` in settings; rich syntax `Bash(npm run test *)`, `Read(./.env)`, `Edit(...)`, `WebFetch(domain:…)`, `mcp__server__tool`; rules merge across scopes | 🟨 deny-only: `tool:<glob>`, `bash:<program-glob>`, `path:<glob>` from `%LOCALAPPDATA%\pasclaude\deny.json` and the approvals file. Checked **above every allow-all, the bash prefix table, nil-Ask, and PreToolUse hook allows** — nothing overrides one. Allow lists exist only as persisted "always" grants — and a settings-based one is ⊘ rather than unbuilt: `permissions`, `allow_edits`, `allow_bash`, `allow_fetch` and `bash_programs` are each refused by name in `uSettings`, pointing at the approvals file that owns the thing. `bash:` filters are documented as evadable (`tool:bash` is the airtight form); `path:` doesn't cover shell access |
| Standing approvals | stored in `.claude/settings.local.json` ("don't ask again") | 🟨 `%LOCALAPPDATA%\pasclaude\approvals\<project>-<hash>.json` — **outside the repository on purpose**, widen-only, hand-editable; `/yolo` sessions never write it, `-p` never reads it. A repository cannot ship the file that answers its own permission questions |
| Enterprise policy | ✅ managed settings via MDM plist / Windows registry / `managed-settings.json(+.d)`, fail-closed security fields | ❌ ⊘ no managed tier; the settings scope table refuses the concept at the project level instead |
| Additional directories | ✅ `--add-dir`, `/add-dir` | ✅ same; additionally: an added root grants *file access only* (its hooks, MCP, skills, agents, CLAUDE.md are unread); relative paths keep one resolution base; never persisted; max 8 |
| Path containment | permission rules + sandbox | ✅ `SafePath` resolves every tool path against the session roots and refuses escapes; `.pasclaude` refused at the top of every root |
| Sandbox mechanics | ✅ macOS Seatbelt, Linux/WSL2 bubblewrap (+optional seccomp): filesystem write-allowlists, deny-read lists, protected paths, **credential protection with masking** (`sandbox.credentials`, JWT decode, TLS-termination required), and a network proxy with per-domain prompting/allowlists; **native Windows not supported** | 🟨 Win32 job objects on *every* child (64-process cap, kill-on-close, no breakaway, no clipboard/desktop) at the default `limits` level; `low` adds a low-integrity token with scratch `%TEMP%`. Honest limits, documented: no filesystem scoping to the root (needs a minifilter) and no network denial (needs WFP); restricted tokens and AppContainer were probe-tested and rejected |
| Sandbox escape hatch | `dangerouslyDisableSandbox` param, `allowUnsandboxedCommands`, `excludedCommands` | `--sandbox off` restores unconstrained spawning but keeps the kill-on-close job object |
| Auto-mode classifier | ✅ classifier reviews actions; `autoMode` settings, `disableAutoMode` | ❌ |
| Permission UI | `/permissions` interactive panel | `/deny add|remove`, `/mode`, the y/a/n prompt with rendered diff |

---

## 5. Context and memory

| Feature | Claude Code | pasclaude |
| --- | --- | --- |
| Project instruction file | `CLAUDE.md` (+ `CLAUDE.local.md`); **AGENTS.md is not read directly** — the documented pattern is an `@AGENTS.md` import | `AGENTS.md`, `CLAUDE.md`, `.pasclaude.md` — all three read natively, appended to the system prompt as binding instructions |
| Rules files | ✅ `~/.claude/rules/` and `.claude/rules/*.md`, recursive, with `paths:` frontmatter for path-scoped lazy loading (1000-pattern/4 MiB budget) | ❌ |
| Hierarchy | managed policy → user `~/.claude/CLAUDE.md` → project → local; walk up the tree; **subdirectory CLAUDE.md files load on demand** when Claude touches those dirs | 🟨 user `%USERPROFILE%\.pasclaude\CLAUDE.md` loads first, then the session-root files, nearer wins; no ancestor walk, no subdirectory discovery |
| Imports | `@path` inside CLAUDE.md, recursive to 4 hops, relative to the importing file | 🟨 `@import <path>` / bare `@path`, **one level deep** — "enough for a shared conventions file, no room for a cycle"; root-guarded |
| Auto memory | ✅ Claude writes its own memory (`MEMORY.md` index + topic files under `~/.claude/projects/<repo>/memory/`, first 200 lines/25 KB loaded) | ❌ |
| Manual memory shortcut | older versions had a `#` quick-add; the current memory docs describe no `#` shortcut (`/memory` manages the files) | ✅ `# note` appends to the project memory file under a Notes heading; `/memory` shows it |
| Generate memory | `/init` | ✅ `/init` writes a starter CLAUDE.md through the ordinary write approval |
| `@file` mentions in prompts | ✅ with autocomplete | ✅ root-guarded, 100 KB cap, image types attach as images; Tab completes paths after `@` |
| Git context | git status/branch in system prompt | ✅ `git rev-parse --abbrev-ref HEAD` + `git status --porcelain` (via PATH-resolved git — never the current directory, after measuring a `git.cmd` hijack) |
| System prompt additions | `--append-system-prompt` and `--system-prompt` (full replacement), plus file variants | 🟨 `--append-system-prompt` only, 4 KB cap, CLI-only; full replacement ⊘ and a project file that could append to the system prompt could rewrite standing instructions |
| Suppressing project context | trust model for untrusted folders | ✅ `--no-project-context`; both `--ci` verbs load none of the files and say so |

---

## 6. Slash commands

Claude Code ships a very large command surface (~60+ built-ins, plus bundled
skills/workflows and aliases); pasclaude ships ~40 built-ins plus custom commands.

**Core equivalents**

| pasclaude | Claude Code | Parity notes |
| --- | --- | --- |
| `/help` | `/help` | ✅ |
| `/clear` | `/clear [name]` | 🟨 CC can label the cleared conversation for later `/resume` |
| `/compact`, `/compact full` | `/compact [instructions]` | ✅ both; pasclaude distinguishes trim vs model-summary explicitly |
| `/model` | `/model` | 🟨 pasclaude lists from the live API; CC has plan/effort/default options |
| `/cost` | `/cost` → alias of `/usage` | 🟨 tokens only vs dollars + limits |
| `/status` | `/status` | ✅ |
| `/doctor` | `/doctor` (bundled skill, can fix issues) | 🟨 pasclaude: 13 named checks with remedies, offline unless `--online`, no auto-repair ⊘ |
| `/bug` | `/bug` (uploads with consent) | 🟨 pasclaude writes a redacted report locally; **no upload path exists at all** |
| `/login`, `/logout` | `/login`, `/logout` | 🟨 CC does real account sign-in/refresh; pasclaude only chooses among credential sources already on the machine and stores one DPAPI-protected key — it cannot mint a token (no public OAuth grant; borrowing Claude Code's client identity is ⊘) |
| `/mcp` | `/mcp` | ✅ both show status; CC adds OAuth, reconnect, enable/disable |
| `/memory` | `/memory` | 🟨 CC edits files + toggles auto memory |
| `/init` | `/init` | ✅ |
| `/add-dir` | `/add-dir` | ✅ |
| `/resume` | `/resume` | 🟨 semantics differ by design: CC's `--resume` is the picker; pasclaude's `--resume` silently loads this directory's `session.json` and `/sessions` is the picker ("a new flag does not get to change what an existing one loads") |
| `/rewind` (+ Esc-Esc) | `/rewind`, Esc-Esc | ✅ both rewind code+conversation from checkpoints; pasclaude names what cannot come back (shell side effects, >400 KB files) |
| `/diff` | `/diff` (interactive viewer, per-turn diffs) | 🟨 pasclaude prints session-changed files + `git diff --stat HEAD` |
| `/review` | `/review` → alias of `/code-review` skill | 🟨 pasclaude's is fully local, no token, reviews `git diff HEAD`/`--staged`/`<ref>`; refuses PR numbers by name. CC's reviews PRs incl. cloud |
| `/ide` | `/ide` | 🟨 see §18 |
| `/hooks` | `/hooks` | 🟨 pasclaude shows + `/hooks off`; CC views config |
| vim mode | `editorMode: vim` in settings (+ `vimInsertModeRemaps`) | 🟨 pasclaude `/vim [on|off|save]` + `/keys` + `keys.json` rebinding (user-scope only); no visual mode, registers, counts, text objects — "a prompt is one line" |
| `/output-style` | `/output-style` | 🟨 pasclaude styles ADD a paragraph and can never replace a system prompt; 2 KB cap |
| `/save`, `/sessions` | session management lives in `--resume`/`--continue` | 🟨 pasclaude's named copies + picker vs CC's transcript store |
| `/config` | `/config [key=value]` | 🟨 both; pasclaude prints the tier of every key and refuses 30 Claude-Code-shaped keys by name with a pointer to the file that really owns them |
| `/exit` | `/exit` (`/quit`) | ✅ |

**pasclaude-only commands**: `/pr-comments` (GET-only GitHub client), `/cwd`,
`/remove-dir`, `/jobs`, `/paste` (clipboard image), `/keys`, `/think`, `/web`,
`/telemetry preview|send`, `/deny`, `/mode`, `/plan`, `/yolo`, `/sandbox`,
`/skills` (rescan), `/plugins enable|disable`.

**Claude Code commands with no pasclaude equivalent** (selection): `/agents`,
`/branch`, `/fork`, `/background`, `/btw`, `/subtask`, `/tasks`, `/list-agents`,
`/context`, `/copy`, `/export`, `/goal`, `/effort`, `/fast`, `/advisor`,
`/autocompact`, `/autofix-pr`, `/security-review`, `/simplify`, `/permissions`,
`/install-github-app`, `/install-slack-app`, `/keybindings`, `/mobile`, `/desktop`,
`/teleport`, `/remote-control`, `/chrome`, `/color`, `/cd`, `/focus`, `/insights`,
`/import codex|gemini`, `/heapdump`, `/usage`, `/upgrade`, `/rename`, `/sandbox`,
`/tui`, `/team-onboarding`, bundled skills
(`/code-review`, `/batch`, `/loop`, `/debug`, `/verify`, `/run`, `/dataviz`,
`/design-sync`, `/claude-api`, `/fewer-permission-prompts`, `/deep-research`),
`/terminal-setup`, `/theme`, `/statusline`, `/voice`, `/privacy-settings`,
`/reload-plugins`, `/plugin`, `/schedule`.

**Custom commands**: both support markdown prompt files — Claude Code
`.claude/commands/*.md` (now unified with skills: rich frontmatter, `$ARGUMENTS`,
`$N`, named args, `${CLAUDE_PROJECT_DIR}`, dynamic `!`shell`` context injection);
pasclaude `.pasclaude\commands\<name>.md` with `$ARGUMENTS` substitution only —
"the file is the prompt, nothing more — no frontmatter, no scripting". Built-ins
cannot be shadowed in pasclaude.

---

## 7. Interactive editing and terminal UX

| Feature | Claude Code | pasclaude |
| --- | --- | --- |
| Renderers | classic + fullscreen renderer, mouse support in menus | Win32 console: amber framed banner + prompt block + statusline (VT when available, graceful single-line fallback) |
| Line editing | full readline set, `Ctrl+Y` yank history, `Ctrl+_` undo, external editor via `Ctrl+G` | arrows, Home/End, Ctrl+A/E/U, Ctrl+W/K, Alt+B/F, Ctrl+Z undo, Tab completion (commands at line start, paths elsewhere, common-prefix extension) |
| Multiline | `\`+Enter, Shift+Enter (per-terminal setup), paste mode | multi-line paste preserved as one prompt; Ctrl+Enter inserts a break |
| Input prefixes | `/` commands, `!` shell mode, `@` files, `:` emoji, `?` help | `/` commands, `@` files; no `!` shell mode |
| Image input | clipboard paste (Alt+V/Ctrl+V), drag-drop | 🟨 `@shot.png` + `/paste` from the Windows clipboard (hand-written PNG encoder over STORED deflate; 2 MB cap with two downscale attempts); both report the exact token cost from the patch formula before sending. No drag-drop, no images in tool results |
| Voice | ✅ hold-Space dictation | ❌ |
| History | persistent, reverse-search (`Ctrl+R`) | 🟨 `.pasclaude\history.txt`, 200 entries, Up-arrow walk; no reverse search |
| Transcript viewer | ✅ `Ctrl+O`, navigation keys, native scrollback export | ❌ (session file + `/bug --transcript` instead) |
| Themes | `/theme`, colour config | ⊘ fixed amber palette (13 colours, 16-colour console fallback) |
| Spinner | ✅ spinner + tips | ❌ none anywhere |
| Statusline | custom script protocol (`/statusline`, JSON in/out) | 🟨 built-in statusline only: model, branch, context/session meters, loaded counts, mode |
| Esc-Esc | rewind menu | ✅ submits `/rewind` on an already-empty prompt; never inside pickers or permission prompts; disabled under `/vim` where Esc means normal mode |
| Keybinding config | `/keybindings` | ✅ `%USERPROFILE%\.pasclaude\keys.json`; a binding structurally cannot reach a permission prompt (chord grammar can't spell `y`/`a`/`n`; actions are editor verbs; non-REPL prompts read through an empty profile) |

---

## 8. Sessions, checkpoints, rewind

| Feature | Claude Code | pasclaude |
| --- | --- | --- |
| Autosave | ✅ JSONL transcripts under `~/.claude/projects/…` | ✅ `.pasclaude\session.json` written after every turn ("the session worth keeping is the one that ended in a crash") |
| Load validation | schema of its own store | ✅ strict: version, known roles, typed blocks, transcript opens with a user message, every `tool_use` answered by a matching `tool_result`; refusal names the reason |
| Continue/resume | `--continue`, `--resume` (picker), session ids | `--resume` (this dir's session), `--continue` (newest of live/safety/named saves via one shared predicate), `--session-file <path>` for `-p`; `--continue` under `-p` is a startup error (a script must not resume "whichever conversation was last") |
| Session management CLIs | ✅ `claude attach/logs/stop/rm/respawn`, `claude daemon status/stop`, `claude project purge`, `--name` + `/rename`, `--fork-session`, `--from-pr` (picker filtered by PR), `--no-session-persistence` | 🟨 `/save <name>` named copies + `/sessions` picker; no background-session management, no branching |
| Checkpoints | automatic checkpoints; `/rewind` restores code and/or conversation | ✅ per-prompt transcript checkpoints + pre-edit file snapshots (≤400 KB/file); restores files including deleting ones the turn created; shell effects named as not undoable; dropped by compaction/`/clear`/resume |
| Export | `/export [file]` | ❌ (nearest: `/bug --transcript` redaction) |
| Session cleanup | `cleanupPeriodDays` (default 30) | safety copy `session.prev.json` only |
| Cross-device sessions | Teleport, Remote Control, `/desktop`, cloud | ❌ |

---

## 9. Subagents and parallelism

| Feature | Claude Code | pasclaude |
| --- | --- | --- |
| Spawn tool | `Agent` (renamed from `Task` in v2.1.63) | `task(prompt, agent_type?)` |
| Definition | `.claude/agents/*.md` + user dir + plugins + managed; frontmatter: `tools`, `disallowedTools`, `model`, `permissionMode`, `maxTurns`, `skills`, `mcpServers`, `hooks`, `memory`, `background`, `effort`, `isolation: worktree`, `color`, `initialPrompt` | 🟨 `.pasclaude\agents\<name>.md` (+ plugin/user scopes), body + light frontmatter; no per-agent MCP/hooks/memory |
| Built-in types | `Explore`, `Plan`, `general-purpose`, `claude`, `statusline-setup`, `claude-code-guide` | ❌ (project types only) |
| Parallelism | ✅ up to 20 concurrent (configurable), background-by-default since v2.1.198 | ❌ one at a time — no threads in the program |
| Nesting | depth 3 configurable | one level, 12 rounds |
| Write capability | ✅ general-purpose subagents edit code | 🟨 subagents are **read-only, enforced in `RunTool`** (read_file/list_dir/search only; they are never even *told* about write tools) and need no permission prompts for a conversation the user cannot see |
| Agent teams | ✅ teammates with task/cron tools, coordinator | ❌ |
| Forked subagents | ✅ `/subtask`, `context: fork` skills | ❌ |
| Resume completed agents | `SendMessage` | ❌ |
| Worktree isolation | `isolation: worktree` | ❌ |
| Run session as agent | `claude --agent <name>` | ❌ |
| Model routing for subagents | per-agent `model` field | ✅ `model.route.subagent` (default sonnet — a no-op on the shipped default) |

---

## 10. MCP (Model Context Protocol)

| Feature | Claude Code | pasclaude |
| --- | --- | --- |
| Transports | stdio, HTTP/streamable-HTTP, SSE, WebSocket | 🟨 **stdio only**; `url` entries listed as unsupported |
| Scopes | local / project (`.mcp.json`) / user / plugin / claude.ai connectors, precedence local→project→user→plugin→connectors | 🟨 user `%USERPROFILE%\.pasclaude\mcp.json` (trusted, loaded first) + project `.mcp.json`; a project entry may not take a user server's *name* — refused by name, not resolved |
| Project server trust | approval prompt; `claude mcp reset-project-choices` | ✅ spawn prompt showing the expanded command line; "always" binds to a **hash of command+args+sorted env** — repointing an approved name at a different program asks again |
| `claude mcp` CLI | add/add-json/remove/list/get/login/logout/serve/add-from-claude-desktop | 🟨 `/mcp` status, `/mcp restart <name>`, `/mcp refresh`; no CLI subcommands, no `serve` |
| OAuth | ✅ browser + headless, token refresh | ❌ |
| Env expansion | `${VAR:-default}` in command/args/env/url/headers | 🟨 literal values; the spawn prompt shows the expanded line |
| Headers / headersHelper | ✅ for remote transports | n/a (no remote transports) |
| Timeouts | MCP_TIMEOUT, per-server timeout, idle timeout, auto-background >2 min | 10 s handshake/list, 60 s calls |
| Output caps | 25k tokens default, `MAX_MCP_OUTPUT_TOKENS` | 64 KB per result, 32 KB of declarations across all servers, schemas rejected past 8 KB/depth 16 |
| Tool naming | `mcp__server__tool`, plugin-scoped variant | ✅ same convention, composed against the API's 64-char ceiling |
| Prompts/resources/sampling/elicitation | ✅ (prompts as slash commands; elicitation hooks) | ❌ tools only; the client advertises no capabilities |
| Tool search / deferred loading | ✅ `ENABLE_TOOL_SEARCH`, `alwaysLoad` | ❌ tool list frozen for the session (prompt-cache reasons); discovery cache in `mcp-cache.json` |
| In headless mode | ✅ | ❌ `-p` spawns no servers — "a scripted run cannot be the thing that first executes a project's code" |

---

## 11. Hooks

| Feature | Claude Code | pasclaude |
| --- | --- | --- |
| Events | **31**: SessionStart, Setup, UserPromptSubmit, UserPromptExpansion, PreToolUse, PermissionRequest, PermissionDenied, PostToolUse, PostToolUseFailure, PostToolBatch, Notification, MessageDisplay, SubagentStart/Stop, TaskCreated/Completed, Stop, StopFailure, TeammateIdle, InstructionsLoaded, ConfigChange, CwdChanged, DirectoryAdded, FileChanged, WorktreeCreate/Remove, PreCompact/PostCompact, Elicitation(+Result), SessionEnd | **5**: PreToolUse, PostToolUse, UserPromptSubmit, Stop, SessionStart. Absent by documented choice: SessionEnd (no honest firing point), SubagentStop (subagents are read-only; "block" has no legal meaning), PreCompact (a hook that can block compaction can kill the session it guards), Notification (no channel) |
| Handler types | command, HTTP, `mcp_tool`, `prompt` (model evaluates), `agent` | command only |
| Protocol | JSON on stdin; exit 0/2 semantics; rich JSON output (`continue`, `stopReason`, `systemMessage`, `hookSpecificOutput`, per-event decision tables) | ✅ same core: one UTF-8 JSON object on stdin, 0 proceeds / 2 blocks / else failure-not-block, optional `{"decision":…}` on stdout |
| Content rewriting | ✅ `updatedInput`, `updatedToolOutput` | ⊘ "silently changing what the user approved in the diff preview is worse than blocking" |
| Turn cancellation | ✅ `continue:false` | ⊘ not implemented (documented) |
| Matchers | regex/list matchers on tool names, plus per-event matcher vocabularies | regex matcher on tool name for the two tool events |
| Where defined | user/project/local/managed settings, plugins, skill & agent frontmatter; hot-reload; `disableAllHooks` | user `%USERPROFILE%\.pasclaude\hooks.json` (never prompted — prompting about a file only you can write trains yes-answers) + project `.pasclaude\hooks.json` **gated on a fingerprint of its bytes**; `/hooks off` all-or-nothing |
| Async hooks | ✅ `async`, `asyncRewake` | ❌ 60 s ceiling per hook |
| Scope of effect | everywhere | 🟨 **interactive-only**: `HooksAllowed` false under `-p`, `--status`, `--doctor`, both `--ci` verbs — "every one of those modes runs with nobody able to answer the trust question" |

---

## 12. Skills

| Feature | Claude Code | pasclaude |
| --- | --- | --- |
| Definition | `SKILL.md` + rich frontmatter (`allowed-tools`, `disallowed-tools`, `model`, `effort`, `context: fork`, `background`, `hooks`, `paths`, `shell`, `disable-model-invocation`, `user-invocable`, metadata) | 🟨 `SKILL.md` with name/description frontmatter; block-scalar descriptions refused (named on error) |
| Discovery | model-invoked via descriptions; `/skills` menu | ✅ catalogue rides in the `skill` tool's description (never the system prompt) so a skill added after `/skills` costs zero tokens until used |
| Scopes & precedence | project → user → plugin, nested dirs get qualified names | project → enabled plugins → user, nearer wins, source always shown |
| Dynamic context | `!`cmd`` shell injection, `${CLAUDE_SKILL_DIR}`, `${CLAUDE_PROJECT_DIR}` | ❌ |
| Argument placeholders | `$ARGUMENTS`, `$N`, named args, quoting rules | `$ARGUMENTS` in custom commands; skill body read whole |
| Bundled skills | ✅ `/code-review`, `/doctor`, `/batch`, `/loop`, `/debug`, `/verify`, `/run`, `/dataviz`, `/design-sync`, `/claude-api`, `/fewer-permission-prompts`, workflows (`/deep-research`) | ❌ none bundled |
| Caps | context window | 32 skills, 320-byte descriptions, 128 KB per SKILL.md |

---

## 13. Plugins

| Feature | Claude Code | pasclaude |
| --- | --- | --- |
| Components | skills, commands, agents, hooks, MCP servers, LSP servers, monitors, `bin/` (PATH), default settings | 🟨 commands, agents, skills, styles |
| Manifest | `.claude-plugin/plugin.json` | `plugin.json` |
| Distribution | **marketplaces**: `claude-plugins-official` (auto-registered), community (reviewed, SHA-pinned), private repos; `--plugin-dir`, `--plugin-url` | ⊘ **no marketplace, no downloader** — "the entire safety argument for this feature is that the user can read the directory before it does anything"; copy or clone into `.pasclaude\plugins\` |
| Enablement | `/plugin` manager, `/reload-plugins`, managed force enable/disable | `/plugins enable|disable <name>`, state in `.pasclaude\plugins.json` |
| Namespacing | `plugin:skill` | ⊘ `:` is refused by every name filter; sources shown instead |

---

## 14. Configuration

| Feature | Claude Code | pasclaude |
| --- | --- | --- |
| Tiers | managed policy > CLI args > `.claude/settings.local.json` > `.claude/settings.json` > `~/.claude/settings.json` | user > project > local, resolved **per key** by a scope table with one writer and one enforcement point |
| What a project may set | almost anything (trust step applies) | 🟨 exactly 4 display/economy keys — `output_style`, `thinking_budget`, `tool_result_bytes`, `auto_compact_tokens` — and the numeric three only in the direction that costs the *user* less; a repository cannot turn thinking on at all, and may only push compaction later |
| Paste-compatibility | n/a | 30 Claude-Code-shaped keys (`permissions`, `env`, `mcpServers`, `hooks`, `apiKey`, `sandbox`, …) are refused **by name with a sentence naming the file that really owns them** — 46 entries in the table, 16 honoured. Two known omissions in §22 |
| `env` key | ✅ injects environment | ⊘ refused — environment is inherited from whatever launched the program |
| Hot reload | settings watched; hooks/permissions/apiKeyHelper reload live | `/config reload`; the system prompt is frozen at session start for cache reasons (documented) |
| Backups of config | ✅ 5 timestamped backups | read-modify-write preserves hand-written blocks |
| Env variables | ~100 `CLAUDE_CODE_*` knobs | fixed small set: `ANTHROPIC_API_KEY/AUTH_TOKEN/MODEL`, `GH_TOKEN`/`GITHUB_TOKEN`, terminal detection vars |
| Config UI | `/config` tabbed interface, `key=value` direct set | `/config`, `/config get|set [--local]|unset|reload` with tier column and "overruled:" lines |

---

## 15. Authentication and providers

| Feature | Claude Code | pasclaude |
| --- | --- | --- |
| Sign-in | ✅ browser OAuth (subscription), API key, `claude setup-token`, org/enterprise management | 🟨 six sources in one documented order: `ANTHROPIC_API_KEY` → `ANTHROPIC_AUTH_TOKEN` → stored preference → pasclaude's own DPAPI-protected store (`%LOCALAPPDATA%\pasclaude\credential.json`, no plaintext path if `CryptProtectData` fails) → Claude Code's token file → Jcode → `ant` CLI profile. Foreign files are read, **never written** (writers take no path argument). `/login` can never mint a token ⊘ |
| Token refresh | ✅ | ❌ ("cannot renew what it did not issue"); a credential refreshed on disk by its owner is re-read once per request; 401 names source, file, expiry, remedy |
| `apiKeyHelper` | ✅ | ⊘ "a project-supplied command that prints a credential is exactly the shape this design exists to refuse" |
| Subscription reuse | n/a (is the issuer) | ✅ reuses Claude Code's OAuth token with the required beta header and identity line — read-only |
| Cloud providers | Bedrock, Vertex/Agent Platform, Foundry, WIF/OIDC | ❌ Anthropic API only |

---

## 16. Headless mode and SDK

| Feature | Claude Code | pasclaude |
| --- | --- | --- |
| One-shot | `claude -p "prompt"`, piped stdin (10 MB cap); `--bare` (skips all discovery — hooks/skills/plugins/MCP/auto-memory/CLAUDE.md), `--safe-mode`; SIGTERM aborts the turn, kills the bash tree, fires SessionEnd hooks, exits 143 | ✅ `pasclaude -p`, piped stdin as context or prompt; exit codes 0/1/2 |
| Output formats | `text`, `json`, `stream-json` (+ partial messages flag); `--json-schema` for validated structured output | ✅ same three; stream-json lines: `system(init)`, `user`, `assistant_delta`, `tool_use`, `tool_result`, `notice`, `hook`, `permission_request`, `error`, one `result` (usage + per-model, but **no `total_cost_usd`** ⊘ — CC's JSON result carries it); no structured-output schema |
| Input formats | `stream-json` multi-turn driver | ✅ `--input-format stream-json`: user messages (incl. images) + `permission_response` lines where anything not explicit allow denies; wire `interrupt` refused by name (needs a thread the program doesn't have) |
| Scripted session files | session ids / resume flags | ✅ `--session-file <path>` opt-in; a bare `-p` writes nothing — "a script's throwaway question should not disturb the directory's saved conversation" |
| Headless permission story | `--allowedTools`, `--permission-prompt-tool`, permission modes | deny rules load; approvals never load under `-p` (strictly stricter than interactive); `--dangerously-skip-permissions` is the one way past and prints a warning |
| Embedding SDK | ✅ Agent SDK for TypeScript + Python (sessions, hooks, `canUseTool`, custom tools, subagents) | 🟨 `src/uSdk.pas` — a console-free in-process facade (`TSdkSession.Create + Ask`), `examples/embed.lpr` embeds the agent in ~60 lines; `build.cmd` compiles it so the seam cannot rot. One session per process; a subprocess is the isolation boundary |
| Serve as MCP server | `claude mcp serve` | ❌ |

---

## 17. CI/CD and GitHub

| Feature | Claude Code | pasclaude |
| --- | --- | --- |
| Official action | `anthropics/claude-code-action` + Claude GitHub App | template workflow in `examples\github\` + two modes: `--ci prepare`, `--ci report` |
| `@claude` mentions | ✅ issues, PR comments, review comments; interactive + automation modes; can implement, push commits, create PRs, turn issues into PRs | 🟨 answers an `@claude`-style trigger phrase (`--ci-trigger`) with **a ceiling of reading the repository and posting one comment** — enforced in four independent places: `issue_comment(created)` only (workflow always from the default branch), authorization twice (YAML `if:` then `author_association` in Pascal, unknown association → lowest), fork PRs refused by name, and a minimal `permissions:` block (`contents: read`, `issues: write`, `pull-requests: read`, everything else none) |
| Write-capable CI | ✅ the product's headline feature | ⊘ "RCE-by-sentence": the model step has no GitHub token at all (`GH_TOKEN` scoped to two fixed `gh` steps, `persist-credentials: false`), and `--dangerously-skip-permissions` appears nowhere — a test greps the template and fails if it ever does |
| Untrusted text handling | actor/bot checks, `--max-turns` guidance | ✅ comment envelope: decodes `GITHUB_EVENT_PATH` itself (never YAML expansion), strips control chars, 4 KB cap, marker-forging lines dropped *after* the cut, lands in a user message marked as data |
| Deny floor | via settings | ✅ `--ci prepare` exits 2 naming every missing rule from the out-of-tree deny floor — a workflow edited to drop it stops working instead of quietly widening |
| PR workflow commands | `/code-review` skill, Claude Code Review product, `/install-github-app` | 🟨 `/review` (local diff, no network/token), `/pr-comments` (GET-only client — no POST/PUT/PATCH/DELETE in the unit, pagination links validated to same-host-same-path); `/install-github-app` ⊘ (no pasclaude app exists to install) |
| GitHub Enterprise | ✅ | ⊘ github.com only — "a configurable host is exactly the knob a credential should not have" |

---

## 18. IDE integration

| Feature | Claude Code | pasclaude |
| --- | --- | --- |
| VS Code | full extension: inline diffs, @-mentions of code, plan review UI, conversation history, selection/diagnostics context | 🟨 `/ide open <path>[:line]`, `/ide diff` — a real diff tab of the file as it stood **before this session first touched it** (rewind snapshots), scratch copy under `%LOCALAPPDATA%\pasclaude\ide` with one-file-at-a-time lifecycle and a day-old sweep |
| JetBrains | plugin with interactive diff + selection sharing | 🟨 detected from documentation; launched only with explicit `ide.command` |
| Diff in approval prompt | inline diff UI | ⊘ refused with reasoning: `--wait` blocks the y/a/n prompt; without it a declined edit leaves a tab that looks applied |
| Reading editor state | selection, cursor, diagnostics flow in | ⊘ "nothing VS Code injects into a terminal names a file, a line, a column or a selection… no channel and none was invented" |

---

## 19. Observability, diagnostics, telemetry

| Feature | Claude Code | pasclaude |
| --- | --- | --- |
| OpenTelemetry | ✅ metrics **and** events/logs via standard OTLP env config | 🟨 opt-in OTLP/HTTP **JSON metrics only** (`telemetry.enabled` + `telemetry.endpoint`, both user-scope; `OTEL_*` env deliberately ignored): 5 counters — turns, tokens by kind/model, tool calls by name+ok/error, API requests by status, request ms. **No text ever leaves**; tool/model names allowlist-filtered; `/telemetry preview` prints the exact payload; self-disables after 3 failures |
| Status | `/status` | ✅ `/status` — model, credential source, mode, grants, deny count, roots, MCP, hooks, style, vim, sandbox, tokens, session file, settings tiers |
| Health check | `/doctor` (bundled skill; can repair) | 🟨 `/doctor [--online]` — 13 checks, each with level/cost/remedy; replays a startup note ledger; offline by default; no repair |
| Bug reports | `/bug`/`/feedback` upload with consent | 🟨 `/bug [--transcript][--paths][--json]` — redacted markdown/JSON out of tree; path redaction covers the session root; a transcript that cannot be rewritten redacted is deleted rather than left claiming to be redacted; **no upload path exists** |
| Debug logs | ✅ `/debug` skill, debug log | ❌ (MCP stderr spools and job spools only) |
| Analytics | usage dashboards, `/insights` | ❌ |

---

## 20. Things pasclaude has that Claude Code doesn't (or does differently)

Most differences are Claude Code being larger; a few run the other way:

- **Deny rules nothing overrides** — checked above bypass, allow-alls, stored grants and
  hook allows. Claude Code's deny rules are authoritative too, but pasclaude's entire
  grant machinery is built so that no combination of features can outrank one.
- **Approvals stored out of the repository** — Claude Code keeps "don't ask again"
  grants in `.claude/settings.local.json`; pasclaude keeps them per-project under
  `%LOCALAPPDATA%` so a clone can never ship its own answers.
- **Fingerprinted trust for project hooks and MCP servers** — editing
  `.pasclaude\hooks.json` re-asks; "always" for an MCP server is a hash of the expanded
  command line + args + env, not the name.
- **A GET-only GitHub client** — no POST/PUT/PATCH/DELETE exists in `uGitHub`, so no
  injected text, in any mode, can produce a comment, review, merge or branch.
- **A hard CI ceiling enforced in code** — read + one comment, token absent from the
  model step, fork PRs refused by name, unknown actor association mapped to the lowest
  trust level, and a test suite that fails if the template changes shape.
- **Byte-faithful notebook editing** — arrival-form JSON escapes preserved per string,
  Python `splitlines` line-cutting, pinned against nbformat-written fixtures.
- **ReDoS-proof search** — a hand-written NFA simulation instead of a backtracking
  engine; `(a+)+` is asserted on wall-clock in the fuzz suite.
- **Strict session-file validation** — hand-edited or corrupted transcripts are refused
  with reasons instead of loaded.
- **Native AGENTS.md loading** — Claude Code reads `CLAUDE.md` (and `CLAUDE.local.md`);
  `AGENTS.md` only enters context via an explicit `@AGENTS.md` import. pasclaude reads
  `AGENTS.md`, `CLAUDE.md` and `.pasclaude.md` directly.
- **`# note` quick-add to project memory** — one keystroke appends to the memory file;
  the current Claude Code docs describe no equivalent shortcut.
- **Zero dependencies, one exe** — no Node, no npm, no package supply chain; HTTPS,
  JSON, PNG, regex and console all hand-rolled and testable offline.
- **Adversarial test investment** — ~27k lines across 6 suites + 2 fixtures:
  hostile JSON/notebooks/images/DIBs, path escapes, MCP wire attacks, CI payloads,
  heaptrc leak checking, and grep-audits of the shipped CI template.
- **`/pr-comments`, `/paste`, `/cwd`, `/remove-dir`, `/jobs`, `/keys`, `/web`,
  `/think`, `/telemetry preview`** — commands with no Claude Code counterpart.
- **Credential hygiene** — foreign credential files are read and never written,
  enforced by the writers' signatures taking no path argument; secrets are read with
  zero echo (not even asterisks — "a mask publishes the length").

---

## 21. The largest gaps in pasclaude, honestly named

1. **Everything beyond the terminal** — no desktop app, web, mobile, remote control,
   Slack/Chrome channels, routines or scheduled work.
2. **Parallelism** — one subagent at a time, read-only, one level deep; no agent
   teams, no background agents, no forked contexts, no worktree isolation.
3. **MCP breadth** — stdio and tools only; no HTTP/SSE/WebSocket, OAuth, prompts,
   resources, elicitation, tool search, or MCP under `-p`.
4. **Hooks breadth** — 5 of Claude Code's 30 events; command handlers only; no input
   rewriting or turn cancellation (both deliberate).
5. **Sandbox depth** — no filesystem scoping to the session root and no network
   denial on Windows; Claude Code's Seatbelt/bubblewrap sandbox does both (but not on
   native Windows, where pasclaude at least confines every child in a job object).
6. **Auto memory, auto mode, effort levels, fallback models** — the adaptive layer.
7. **Provider breadth** — Anthropic API only; no Bedrock/Vertex/Foundry, no
   base-URL override, no `apiKeyHelper`.
8. **Cost visibility** — tokens only, never dollars (deliberate, but still a gap for
   anyone whose workflow needs spend tracking).
9. **Ecosystem** — no marketplace, no bundled skills, no plugin downloader, no
   auto-update, no release pipeline.
10. **Cross-platform** — Windows-only by construction; Claude Code runs on
    macOS/Linux/Windows/WSL.

---

## 22. One gap in our own table

Everything above measures this program against another one. This entry does not: it
is a defect against a standard the repository set for itself, which makes it the only
item here that needs no comparison to justify acting on.

The `scRefused` block in `src/uSettings.pas` exists because, in its own words, a key
nothing knows about is a key that fails silently — so every key somebody might paste
out of Claude Code's `settings.json` should sit in the table as a refusal naming the
file that really owns it. Two do not:

* **`statusLine`** — a real Claude Code key (§7), neither honoured nor refused here.
  A user who pastes it gets whatever the unknown-key path does, rather than a sentence
  saying the status line is compiled in.
* **`outputStyle`** — the camel-case spelling of the honoured `output_style`. The
  table already carries `additionalDirectories` beside `add_dir` for exactly this
  reason; this pair is missing the same treatment.

Two entries, one line and a `Note` each. It is the smallest actionable item in this
document and the only one that is a bug rather than a difference.

## 23. What to actually do

If the goal is an exact clone: don't. The three structural facts under *How to read a
❌* each cost more than every residual in this document combined, and the ⊘ column is
not work at all.

If the goal is the closest useful thing, in order:

1. **`statusLine` and `outputStyle` into the refusal table** (§22) — an hour, and it
   is the repository's own rule rather than anybody else's feature.
2. **`-p` reads the user-scope `mcp.json`** (§10) — the cheapest real capability on
   the list. A scripted run currently has no MCP tools at all, which makes print mode
   strictly less capable than the REPL in a way nothing about the design requires, and
   the trust argument for the user's own file is already made and already relied on.
3. **`/context`** (§2, §6) — automatic compaction is the most opaque thing the program
   does to a user, and the statusline meter answers "how full" without answering "with
   what".
4. **MCP over HTTP/SSE** (§10) — the one item that changes what the program can be
   pointed at, and the only one here deserving a round of its own. `uMcp` already owns
   the framing, the validation, the caps and the deadlines; a second transport goes
   behind the same interface and `uHttp` exists. The hard part is not the protocol but
   the trust question: the spawn prompt shows an expanded command line, a URL has none,
   so both the prompt and the "always" fingerprint need a new input.

**`SubagentStop` is the one ⊘ worth reopening** (§11). The recorded reason is that a
subagent is read-only and invisible, so "block" has no legal meaning inside one — and
that is an argument about *blocking*, not about *notifying*. A fire that cannot block
is still useful and does not need the meaning that was refused.

Nothing structural unless the project's charter changes. If it ever does, threads
before platforms: threads collapse five listed gaps into one piece of work, whereas a
port buys reach and closes nothing.

---

## Sources

**pasclaude:** `README.md` (4,184 lines), `FEATURES-NOT-YET.md` (1,587 lines), and a
full source inventory of `src/` (pasclaude.lpr, uAgent, uArgs, uAuth, uCi, uDiag,
uDiff, uGitHub, uHooks, uHttp, uIde, uImage, uJson, uMcp, uNotebook, uRegex,
uSandbox, uSdk, uSettings, uTelem, uTerm, uTools), `tests/` (smoke, stream, loop,
fuzz, ux, net + srvmock/sbxmock fixtures), `examples/embed.lpr`,
`examples/github/`.

**Claude Code:** official documentation at `code.claude.com/docs` fetched 2026-08-09:
overview, cli-reference, commands, interactive-mode, slash-commands, tools-reference,
hooks, permissions, mcp, sub-agents, memory, settings, sandboxing, skills, plugins,
headless, github-actions. Pages fetched once and partially truncated where noted in
the text (checkpointing, vs-code, jetbrains, output-styles, statusline, env-vars,
context-window, agent-teams and the provider pages were covered only incidentally).
Claude Code changes continuously; re-verify before relying on any row of this document.

**Two grades of claim, deliberately not mixed.** Every statement about pasclaude is
read out of this tree and is checkable against the code that implements it. Every
statement about Claude Code comes from the documentation above, fetched once on the
snapshot date and not compared against a running install. That is why this file sits
at the top level and not inside `FEATURES-NOT-YET.md`, where the stricter standard
applies to every line; merging them would quietly lower it.

A second document, `GAP-ANALYSIS.md`, covered the same question from the other
direction and was folded in here rather than kept beside this one. What it
contributed: the structural/refused/residual split under *How to read a ❌*, the
correction that a settings-based allow list is refused rather than unbuilt (§4), the
count of the refusal table (§14 — it is thirty, not twenty-seven), §22 and §23.
