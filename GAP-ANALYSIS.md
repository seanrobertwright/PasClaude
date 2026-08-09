# The distance to Claude Code, measured

`FEATURES-NOT-YET.md` answers "what has not been built yet" and every box in it
is ticked. This document answers a different question somebody asks next, and
it is not the same question: **what would it take to be an exact clone of the
Claude Code CLI?**

The short answer is that exact is not a target this program can reach, and that
saying so plainly is worth more than a checklist implying otherwise. Roughly
half the remaining distance is work this repository has already **refused in
writing**, with the argument attached, in the unit that implements the thing
being refused. Closing that half does not finish the project; it reverses it.
The other half splits into three structural facts that gate almost everything
else, and a genuinely closeable residual list that is shorter than it looks.

So the distance is sorted here into four kinds, and the kind matters more than
the count:

| kind | what it means | can it be closed |
| --- | --- | --- |
| **Structural** | a property of the language, the platform or the process model | not without a second project |
| **Refused** | built to a boundary, with the boundary written down | only by un-deciding it |
| **Residual** | nobody has done it, and nothing stops anyone | yes |
| **Surface** | a command, a flag or a key, additive at the top of the ladder | yes, cheaply |

## Standard of evidence

Everything asserted about **pasclaude** in this document was read out of this
tree and is cited by file and line. Everything asserted about **Claude Code**
comes from knowledge of that program rather than from a running install
compared side by side, and the CLI ships fast. Treat the Claude Code column as
a snapshot taken in August 2026 and re-check it before spending a week on
anything here. Where a claim would be expensive to act on and cheap to verify,
verify it.

That distinction is the reason this file exists at the top level rather than
inside `FEATURES-NOT-YET.md`, where every entry is checkable against the code
that implements it. This one is not, and mixing the two standards in one
document would quietly lower the stricter one.

---

## 1. Structural: three facts that gate the rest

### 1.1 This is a Windows program, and not by accident

Claude Code runs on macOS, Linux and WSL. Nothing here does, and the reason is
the same thing that makes the bottom of the ladder testable: `uSandbox` imports
`Windows` and `SysUtils` and nothing else, which is precisely what lets a spawn
shared by `uHooks`, `uMcp` and `uTools` exist below all three - and precisely
what makes it unportable.

What a port touches, by unit:

* `uHttp` - WinHTTP bound at runtime, one POST streamed to a callback. Becomes
  libcurl or a hand-rolled TLS client, and the "no dependencies beyond the FPC
  RTL" claim in the README's second paragraph does not survive either choice.
* `uTerm` - `ReadConsoleInputW`, `SetConsoleTextAttribute`, `WriteConsoleW`,
  the VT-processing probe, and the 250 ms `WaitForSingleObject` the idle tick
  is built on. Becomes termios and `select`, and the key-dispatch boundary that
  `tests\ux.lpr` drives through `EditApply` has to keep meaning the same thing.
* `uSandbox` - job objects, `KILL_ON_JOB_CLOSE`, low-integrity tokens, breakaway
  refusal. Becomes seatbelt on macOS and bubblewrap or cgroups on Linux, which
  are not the same shape and do not have the same guarantees, so `/sandbox`'s
  three levels would mean three different things per platform.
* `uImage` - `CF_DIB` off the Windows clipboard, and the stored-deflate PNG
  encoder that exists because paszlib is a package rather than RTL.
* `uTools` - `cmd.exe`, `%LOCALAPPDATA%`, `%USERPROFILE%`, 8.3 short names,
  junction canonicalisation in the path guard, `PathDelim` assumptions.

Five of twenty-one units, plus the path conventions that the deny rules and the
root guard both depend on being canonical. The honest estimate is a second
project of comparable size to this one, not a porting layer.

### 1.2 There are no threads, and five separate gaps are that one fact

This is stated as a constraint in at least four places in the tree and it is
load-bearing every time:

* **No mid-turn interrupt over the wire.** `{"type":"interrupt"}` is refused by
  name in the SDK, because reading stdin while blocked on the network needs a
  thread. Ctrl+C still stops a turn, which covers the human and not the driver.
* **MCP first-connect is sequential.** N servers each taking their 10 s
  deadline is a 10N-second first start, recorded in `FEATURES-NOT-YET.md` with
  "with no threads there is no way to overlap them" as the whole explanation.
* **One subagent at a time.** `task` is read-only, one level deep, twelve tool
  rounds. Parallel fan-out, agent teams and agent-to-agent messaging are all
  downstream of this and not of anything about subagents.
* **No background agents.** Distinct from background *bash*, which exists.
* **One session per process**, because `uTools`' state is module-global; the
  SDK's own answer is that a subprocess is the isolation boundary.

Adding threads would be the single highest-leverage change available and also
the most dangerous one on this list: the permission gate is a callback, the
tool state is module-global, and `-gh` on six suites is currently a meaningful
leak check precisely because allocation is single-threaded and deterministic.

### 1.3 There is no distribution story

Claude Code installs from npm or a native installer, updates itself, and has
`/release-notes`, `/upgrade` and `/migrate-installer` as commands about its own
lifecycle. pasclaude is `build.cmd` producing two exes, and `test.cmd`
producing six suites and two fixtures. Nothing here is wrong; it is simply a category of behaviour that does
not exist, and three commands cannot be cloned without first inventing the
thing they report on.

---

## 2. Refused: would have to be un-decided

These are not gaps in the sense the word usually carries. Each was built to a
boundary and the boundary was written down at the site that enforces it. They
are listed so that nobody re-derives the argument, and so that anybody who
disagrees knows exactly which sentence to argue with.

### 2.1 Anything that lets a repository grant itself authority

`src/uSettings.pas` carries a 46-entry key table: 16 honoured, **30 refused by
name**. The refusals are not silence - each names the file that really owns the
thing - and they cover most of what a Claude Code `settings.json` would carry:

| refused key | where the thing actually lives |
| --- | --- |
| `permissions`, `allow_edits`, `allow_bash`, `allow_fetch`, `bash_programs` | the approvals file under `%LOCALAPPDATA%\pasclaude`; answer the prompt with `a` |
| `deny` | `%LOCALAPPDATA%\pasclaude\deny.json` and the approvals file only |
| `permission_mode`, `sandbox` | `--permission-mode` / `/mode`, `--sandbox` / `/sandbox` |
| `add_dir`, `additionalDirectories` | `--add-dir` or `/add-dir`, never a file |
| `append_system_prompt` | the command line only - refused at **every** tier, the user's own file included |
| `apiKey`, `apiKeyHelper`, `auth`, `credential`, `login` | `ANTHROPIC_API_KEY` or a subscription; no key names one and none runs a program to fetch one |
| `mcpServers` | `.mcp.json`, where you can read it, each spawn approved by name |
| `hooks` | `.pasclaude\hooks.json`, which is fingerprinted; `settings.json` is not |
| `vim`, `bindings` | `%USERPROFILE%\.pasclaude\keys.json`; a git clone cannot choose what your keyboard does |
| `env` | nothing here sets environment variables for you |

**A settings-based allow/ask rule list is therefore not a residual.** It is the
exact thing the scope table exists to prevent, and `permissions` is refused by
that name with that reason. Claude Code's four-tier model - including a
system-managed policy tier above the user - is a different security posture,
not a missing feature: it presumes an administrator who outranks the user, and
this program presumes the person at the keyboard is the highest authority
there is.

### 2.2 The IDE extension, and the three things it would buy

`uIde` detects the editor and `/ide` opens files and real diff tabs. What is
refused, with the reasons already recorded: **no extension** (TypeScript, npm
and `vsce` is a second toolchain in a repository whose only non-Pascal files
are `.gitignore`, `LICENSE` and `logo.png`, and neither build script could
compile it or notice it rotting); **no selection as context** (nothing VS Code
injects into a terminal names a file, a line or a selection - the one IPC
handle is the git extension's askpass socket); **no diff in the approval
prompt** (`--wait` blocks the spawning thread so the y/a/n prompt could not be
answered, and without it a declined edit leaves a tab that looks applied).

Of the three, only the first is a decision that money and a second toolchain
could reverse. The second is a statement about what the channel carries.

### 2.3 The rest of the refusals, briefly

* **`exit_plan_mode`** - a tool that lets the model leave plan mode is a tool
  that lets it grant itself write access. Leaving is always a keystroke.
* **`total_cost_usd`** - no price table, because a hardcoded one becomes a lie
  the first time a model is repriced. The single intentional divergence from
  the SDK's documented shape.
* **The plugin marketplace and downloader** - the entire safety argument for
  plugins is that the user can read the directory before it does anything, and
  fetching archives with no signature story destroys that argument exactly when
  it is needed.
* **`/install-github-app`** - not applicable; there is no pasclaude GitHub App.
* **Write-capable CI** - the ceiling on `--ci report` is reading the repository
  and posting one comment, held there by four separate mechanisms.
* **`--resume` as a picker** - it keeps the meaning it has always had, because
  a new flag does not get to change what an existing one loads. `/sessions` is
  the picker.
* **Capture groups, backreferences and lookaround in `search`** - `uRegex` is
  an NFA because nothing in `uTools` can interrupt a compute loop, so cost is
  bounded by construction rather than watched.
* **nbformat 3 upgrade** - measured rather than assumed: nbformat's own
  converter draws new cell ids from a random word corpus, so the same v3 file
  converted twice gives two different v4 files, and a conversion that is not
  reproducible cannot be the no-op an edit has to be.

---

## 3. Residual: genuinely unbuilt, and closeable

Ordered by value per unit of work. These are the four that would actually move
the program.

### 3.1 MCP transports beyond stdio — the largest functional gap

Today: stdio only. A `url` entry or a non-stdio `type` is listed as unsupported
and contributes nothing. No HTTP, Streamable HTTP, SSE or WebSocket, and no
OAuth for remote servers - which is how a large and growing share of MCP
servers ship. Also absent: prompts, resources, sampling, roots and elicitation;
`--mcp-config`; auto-restart; per-tool rather than per-server approval.

Why it is the best-value item: `uMcp` already owns the JSON-RPC framing, the
name sanitising, the schema validation, the 32 KB declaration budget and a
deadline on every wait. A second transport goes behind the same interface, and
`uHttp` exists. The hard part is not the protocol, it is that a remote server
changes the trust question - the current spawn prompt shows an expanded command
line, and a URL has no command line to show, so the approval prompt needs a new
sentence and the "always" fingerprint needs a new input.

### 3.2 `-p` reads neither `mcp.json`

A scripted run has no MCP tools at all, which makes print mode strictly less
capable than the REPL in a way nothing about the design requires. The user-scope
file is already trusted without a prompt, so the argument that stops the
project's file from loading unattended does not apply to it. This is the
cheapest real capability on the list.

### 3.3 The hook events that are unfired, reconsidered

`SessionEnd`, `SubagentStop`, `PreCompact` and `Notification` are each recorded
as deliberate omissions, and three of the four arguments still hold. The one
worth reopening is **`SubagentStop`**: the stated reason is that a subagent is
read-only and invisible so "block" has no legal meaning inside one - which is
an argument about *blocking*, not about *notifying*. A fire that cannot block
is still useful and does not need the meaning that was refused.

`Notification` cannot be fired because there is no notification channel; that
is a missing feature, not a missing hook.

### 3.4 `WebFetch` semantics

`fetch` is an HTTPS GET capped at 200 KB with its own "always" class. Claude
Code's `WebFetch` converts HTML to markdown, runs a model prompt over the
content and caches the result. The difference matters on any page where the
useful 2 KB is buried in 190 KB of markup - the current tool spends the context
budget on the markup. Closing this needs an HTML-to-text pass, which is a real
piece of work and belongs in a unit of its own below `uTools`.

---

## 4. Surface: the cheap long tail

Additive at the top of the ladder, where `pasclaude.lpr` and `uDiag` already
own rendering. None of it is architecturally interesting and all of it is
visible to a user on day one.

**Commands with no equivalent:** `/context` (a token breakdown of what is
filling the window), `/usage`, `/export`, `/agents` (manage the definitions in
`.pasclaude\agents\`), `/permissions`, `/statusline`, `/terminal-setup`,
`/privacy-settings`, `/security-review`, `/feedback`. Of these, `/context` and
`/agents` are the two that pay for themselves - the first because compaction is
automatic and currently unexplained, the second because agent definitions are
already a directory of files with nothing that lists them.

**Custom command frontmatter.** Commands here are "the file is the prompt,
nothing more - no frontmatter, no scripting". Claude Code's carry
`allowed-tools`, `argument-hint`, `model` and `disable-model-invocation`. Note
that `allowed-tools` in a *project* file is the scope table's problem, not a
surface change, so only two of the four are actually cheap.

**A configurable status line.** Claude Code's `statusLine` key runs a user
command whose output becomes the line. Here the status line is compiled in and
tested at every width from 12 to 140 columns in `tests\ux.lpr`.

**CLI flags absent:** `--model`, `--settings`, `--agents`, `--verbose`,
`--fork-session`, `--include-partial-messages`, `--replay-user-messages`. The
model comes from `ANTHROPIC_MODEL`, `/model` or the user-scope settings key
instead, which is a deliberate narrowing for the reason in §2.1 and not an
oversight - but a *command-line* `--model` is argv, not a file, so it would be
consistent with the table rather than against it.

**Terminal surface:** no inline image rendering, no mouse, no queued messages,
no transcript search.

**Backends:** no Bedrock and no Vertex.

---

## 5. One finding this analysis turned up

The scope table's own charter is that *"every key somebody might paste out of
Claude Code's `settings.json` is in the same table as a refusal naming the file
that really owns it"* - and the table's comment at the head of the `scRefused`
block says the same in its own words: a key nothing knows about is a key that
fails silently.

**`statusLine` is not in the table.** It is a real Claude Code settings key, it
is neither honoured nor refused here, and a user who pastes it gets whatever
the unknown-key path does rather than a sentence telling them the status line
is compiled in. The same is true of `outputStyle` as spelled by Claude Code -
the honoured key here is `output_style`, and the camel-case spelling is not
listed beside it the way `additionalDirectories` is listed beside `add_dir`.

Two entries, both `scRefused`, both one line of table plus a `Note`. That is
the smallest actionable item in this document and the only one that is a defect
against a standard the repository has already set for itself rather than a
difference from another program.

---

## 6. What to actually do

If the goal is an exact clone: don't. The three structural facts in §1 each
cost more than everything in §3 and §4 combined, and §2 is not work.

If the goal is the closest useful thing, in order:

1. **`statusLine` and `outputStyle` into the refusal table** (§5) - an hour,
   and it is the repository's own rule.
2. **`-p` reads the user-scope `mcp.json`** (§3.2) - the cheapest real
   capability, and the trust argument is already made.
3. **`/context`** (§4) - automatic compaction is currently the most opaque
   thing the program does to a user.
4. **MCP over HTTP/SSE** (§3.1) - the one item that changes what the program
   can be pointed at, and the only one on this list that deserves a round of
   its own.

Nothing in §1 unless the project's charter changes. If it ever does, threads
before platforms: five listed gaps collapse into one piece of work, whereas a
port buys reach and closes nothing.
