# pasclaude

A terminal coding agent for Windows, written in Free Pascal. It talks to the
Anthropic messages API, streams the reply as it arrives, and lets the model
read, search, edit and run things in your project - asking before anything is
changed.

No dependencies beyond the FPC RTL: HTTPS is WinHTTP bound at runtime, JSON is
a small DOM in `uJson`, and the console is driven through the Win32 API.

```
    /    /  \
   <    /    >     pasclaude v0.1
    \  /    /      a coding agent in Free Pascal

  claude-sonnet-4-5
  E:\Projects\pascal\pasclaude
  /help for commands, /exit to quit, Esc stops a reply

> what does uHttp do, and is the timeout long enough for streaming?
  * read src\uHttp.pas
    ...
uHttp is a thin WinHTTP wrapper: one POST, streamed to a callback...
```

## Build

```
build            :: release (optimised, stripped) -> bin\pasclaude.exe
build debug      :: with line-info for backtraces
build clean
```

Requires Free Pascal 3.2.x for `x86_64-win64`. The script finds `fpc.exe` on
`PATH`, or under `C:\lazarus\fpc\*` / `C:\FPC\*`.

## Run

```
set ANTHROPIC_API_KEY=sk-ant-...
set ANTHROPIC_MODEL=claude-sonnet-4-5          :: optional
bin\pasclaude.exe [directory] [--resume | --continue] [--web] [--add-dir <dir>]
                  [--permission-mode ask|plan|accept-edits]
                  [--dangerously-skip-permissions] [--sandbox off|limits|low]
                  [--output-style <name>] [--append-system-prompt <text>]
                  [--no-project-context]
                  [-p "prompt"] [--session-file <path>]
                  [--output-format text|json|stream-json] [--input-format text|stream-json]
                  [--status] [--doctor [--online]]
                  [--ci prepare|report --ci-in <path> --ci-out <path>
                   [--ci-pr <path>] [--ci-trigger <phrase>]
                   [--ci-allow collaborator|member|owner]]
```

Without a key, a Claude subscription works instead: if Claude Code has been
signed in on the machine, its OAuth token
(`%USERPROFILE%\.claude\.credentials.json`) is picked up automatically and
the banner says `(subscription)`. The token is read, never written -
refreshing it is Claude Code's job, and this program does not touch another
program's state. There are six sources in all and `/login` chooses among
them; see **Credentials** below for the order and the boundary. An explicit
`ANTHROPIC_API_KEY` always wins, because
setting a variable is a deliberate act and borrowing a token is not. Under
OAuth the request authenticates with a Bearer header and its beta flag, and
the system prompt opens with Claude Code's identity line, which the API
requires verbatim; ours follows unchanged, cache breakpoint included.

The directory argument (default: the current one) becomes the *session root*.
It cannot wander into `C:\Windows` because it misread a relative path: every
path a tool is handed is resolved against the session root and refused unless
the result lands inside it, or inside a directory you named yourself.

`--add-dir <dir>` adds a directory the file tools may also work in, repeatable
and also spelled `--add-dir=<dir>`; `/add-dir` does the same mid-session,
`/cwd` lists the set numbered and `/remove-dir <n|path>` takes one away. The
guard keeps one resolution base: a bare relative path always means the session
root, so adding a directory can only make an absolute path that used to be
refused succeed - it can never quietly re-point `src\main.pas` at another
tree. A file in an added directory is named by its full absolute path, which
is exactly how `list_dir` and `search` print it back, and the model is told so
by a system-prompt block emitted only when there is more than one root.

What an added directory does *not* get is the interesting half. It grants file
access and nothing else: its `.pasclaude\hooks.json` does not run, its skills,
commands and agents are not offered, its `.mcp.json` spawns nothing and its
`CLAUDE.md` is not read. Otherwise `--add-dir` would be a way to make any
directory execute what it ships, which is a much larger grant than the words
suggest. The session, the history, the approvals file, the rewind snapshots
and bash's working directory all stay bound to the session root; `.pasclaude`
is refused at the top of every root, added ones included, because a walker and
a guard that disagreed about that name would be the inconsistency.

Directories come from the command line or from a typed `/add-dir`, and from
nowhere else - no file names one, and nothing is persisted, so each session
starts at one root and you say it again. A write into an added directory still
raises the same approval prompt with the same rendered diff, and a deny rule
still refuses inside it. `--add-dir` widens reach, not permission. At most
eight extras: the root list is scanned by the hottest guard in the program.

It is honest about its one soft edge: `--add-dir C:\Users` is accepted and
grants a great deal. Only a bare drive letter or share root is refused, and
that is a typo guard rather than a boundary. The boundary is that only you can
type it, and that it lasts exactly one session.

If the project contains `AGENTS.md`, `CLAUDE.md` or `.pasclaude.md`, the
contents are appended to the system prompt as binding instructions. Not under
`--ci prepare` or `--ci report`, where the working directory is a checkout of
the pull request under review: those two runs load none of them and name the
files they skipped - see **Running unattended**. `--no-project-context` says
the same thing for *any* run, which is what you want when the directory is a
checkout somebody else wrote; it stops the three files and every `@import`
inside them, and nothing else. Your own
`%USERPROFILE%\.pasclaude\CLAUDE.md` loads either way, because the question
the flag asks is which *tree* wrote the prompt, and skills are untouched -
their descriptions ride in the `skill` tool's own description and were never
in the system prompt at all.

## Commands

| Command | Effect |
| --- | --- |
| `/help` | list the commands |
| `/clear` | forget the conversation, here and on disk |
| `/compact` | drop the oldest turns, keep the recent ones |
| `/compact full` | replace the transcript with a model-written summary |
| `/diff` | list the files this session has changed |
| `/ide` | the editor around this terminal; `/ide diff [<path>]`, `/ide open <path>[:line]` |
| `/review [--staged\|<ref>]` | have the model review a local diff; no network, no token |
| `/pr-comments [<n>] [--show]` | the comments on one GitHub pull request, printed then sent |
| `/hooks` | the commands that run automatically, yours and this project's; `/hooks off` stops both |
| `/jobs` | background commands still running |
| `/mcp` | MCP servers, yours and this project's: status, `/mcp restart <name>`, `/mcp refresh` |
| `/memory` | show the project memory (CLAUDE.md) |
| `/init` | have the model write a CLAUDE.md for this project |
| `/rewind` | undo turns: conversation and edited files |
| `/sessions` | list saved sessions and resume one |
| `/skills` | the skills this project offers; also rescans for new ones |
| `/plugins` | installed plugins; `/plugins enable\|disable <name>` |
| `/output-style [name]` | how replies are written; bare, it lists them |
| `/paste` | attach the clipboard image to your next message; `drop` cancels |
| `/vim [on\|off\|save]` | modal line editing; `save` keeps it for future sessions |
| `/keys` | the editing keys in force, and where to rebind them |
| `/think [n]` | extended thinking: on, off, or a token budget |
| `/web [on\|off]` | let the model search the web (off by default) |
| `/resume` | reload the saved conversation |
| `/save [name]` | write the conversation now; a name makes a keepable copy |
| `/cwd` | the session root and any added directories, numbered |
| `/add-dir <dir>` | also work in that directory (file access only) |
| `/remove-dir <n>` | stop working in it; the session root cannot go |
| `/model [name]` | pick a model from a live list, or set one by name |
| `/deny` | the rules nothing overrides; `/deny add <rule>`, `/deny remove <n>` |
| `/mode [name]` | `ask`, `plan` or `accept-edits`; bare, it shows the whole state |
| `/plan` | shorthand for `/mode plan` |
| `/yolo` | approve every tool for the rest of the session (bypass mode) |
| `/sandbox [level]` | `off`, `limits` or `low`: how confined child processes are |
| `/cost` | turns and tokens used |
| `/context` | what is filling the context window, by kind |
| `/config` | settings and the tier each came from; `get`, `set [--local]`, `unset`, `reload` |
| `/telemetry` | metrics state; `preview` shows the exact JSON, `send` flushes now |
| `/login [key]` | which credential answers; `key` stores one of pasclaude's own |
| `/logout` | remove that stored credential, and only that one |
| `/status` | what is true right now: model, credential, mode, roots, MCP, hooks, style, tokens |
| `/doctor [--online]` | what is wrong or might be, with a remedy each; offline unless `--online` |
| `/bug [--transcript] [--paths] [--json]` | write a redacted report to a file; nothing is uploaded |
| `/exit` | quit (Ctrl+C also works) |

A prompt starting with `# ` is a note for the project memory rather than a
question: `# prefer edit_file here` appends to CLAUDE.md (or AGENTS.md /
.pasclaude.md, whichever the project already has) under a Notes heading,
and the next session starts knowing it. `/memory` shows the file; `/init`
has the model explore the project and write a starter CLAUDE.md, through
the ordinary write approval.

Memory has a user level too: `%USERPROFILE%\.pasclaude\CLAUDE.md` follows
you across projects and loads before the project's own files, so a project
can override it - nearer wins. Inside any instruction file, a line that is
`@import <path>` (or a bare `@path` alone on its line) is replaced by that
file's contents, one level deep: enough for a shared conventions file,
no room for a cycle. The imported path faces the same session-root guard
as everything else; a refused path stays as literal text.

`/rewind` undoes turns. Before each of your prompts runs, the transcript
length is checkpointed, and before any `write_file`/`edit_file` touches a
file its prior state is snapshotted in memory (up to 400 KB per file).
Rewinding lists your turns, and picking one puts both the conversation and
the files back to the moment before it - including deleting files that
turn created. What cannot come back is named rather than glossed: shell
commands are not undone, and oversized files are not snapshotted.
Compaction, `/clear`, and resuming a session drop the checkpoints, because
their message positions no longer describe the transcript.

`/save <name>` keeps a named copy (`<name>.session.json`) the autosave
never overwrites, and `/sessions` lists everything saved in the directory -
the live session, the safety copy, and the named ones, with dates and
sizes - and resumes whichever you pick. `--continue` (`-c`) takes the most
recently written of exactly that set and asks nothing, naming the file it
took. One rule decides what counts as a saved conversation, in
`uAgent.IsSessionFile`, and both the picker and `--continue` go through it -
the approvals file lives in the same directory, and a "newest `.json`" rule
would load it as a transcript.

Two differences from Claude Code, said rather than glossed. There `--resume`
is the picker; here it keeps the meaning it has always had - this directory's
`session.json`, loaded silently - because a new flag does not get to change
what an existing one loads, and `/sessions` was already the picker. And
`--continue` is interactive only: under `-p` it is a startup error, with
`--session-file <path>` as the answer, because a script that continued
"whichever conversation was saved last" would continue a different one
depending on what you did in the REPL an hour ago. Giving both `--resume` and
`--continue` is a startup error too - they name different files, and either
precedence would be a guess.

Escape pressed twice on a prompt line that was already empty opens `/rewind`.
It is the only new meaning Escape has: the first press still clears the line,
a press on a line with text in it still just clears, and with `/vim` on
Escape leaves insert mode both times and never rewinds - a vim user's fingers
press it twice to be sure, and stealing that would cost more than the
shortcut is worth. It fires at the REPL prompt only, never in the permission
question or the `/model`, `/sessions` and `/rewind` pickers. `uTerm` sits
below `uTools` and cannot reach a slash command, so the word is pushed down
from `pasclaude.lpr` into `uTerm.EscEscCommand` - empty by default, so a
wiring mistake is a shortcut that does nothing - and submitted as though you
had typed it, through the one dispatcher every other command goes through.

A slash command nobody built in is looked up in `.pasclaude\commands\`:
`/shout loud words` reads `commands\shout.md` and sends its contents as the
prompt with every `$ARGUMENTS` replaced by `loud words`. The file is the
prompt, nothing more - no frontmatter, no scripting - because a prompt in a
file already covers the real use: the same request typed often, made one
word. Built-ins cannot be shadowed; the lookup runs only after they decline.

`pasclaude -p "question"` is print mode: one prompt in, one answer out,
exit code 0 on success. Piped stdin becomes context under the prompt
(`type build.log | pasclaude -p "why did this fail?"`), or is the prompt
itself when `-p` has no argument. No banner, and no session save unless
`--session-file <path>` asks for one by name - a script's throwaway question
should not disturb the directory's saved conversation, and guessing which file
it meant is exactly what `-p` declines to do, so `--resume` there is a startup
error without it. No permission prompts either: stdin may be a pipe, so asking
would hang.
Read-only tools work; a run that needed an edit approved says so in its
output instead of stalling. Deny rules do load, before the halt that stops
the approvals file being read, so a scripted run inherits every refusal and
no grant - strictly stricter than the interactive session that started with
the same flags, which is the rule. `--dangerously-skip-permissions` is the
one way past that, and it prints a warning to stderr when it is used.
It also loads no hooks, and spawns no MCP server the *project* declared: a
scripted run cannot be the thing that first executes a project's code. The
hooks half is a flag, `uHooks.HooksAllowed`, false unless the run is the REPL -
see **Hooks** for which four modes that took it away from and why a `finally`
position was not enough.

The MCP half used to be the same sentence and is now two. Your own
`%USERPROFILE%\.pasclaude\mcp.json` **is** read under `-p` and its servers do
start; the project's `.mcp.json` is not read at all. The distinction is the one
the spawn prompt already makes: that prompt exists so somebody can decide
whether to trust a program the *project* chose, and a scripted run has nobody
to answer it - but a program *you* chose is approved without any prompt in the
REPL today, and keeping it out of `-p` was the same grant withheld from the one
caller that could not object. `McpApproveAll` is handed a nil `Ask` there and
never reaches a question, because only project servers are counted into the
prompt loop.

What that buys depends on who is driving. A bare `-p` has a nil `Ask`, so it
declares your MCP tools and then refuses every call to them exactly as it
refuses every other gated tool, and says so in its output. The callers that
gain are the two that can answer: a `--input-format stream-json` driver
answering `permission_request` lines, and `--dangerously-skip-permissions`.
Connection notices are suppressed on this path, because under
`--output-format json` and `stream-json` stdout carries the protocol - a server
that fails to start is visible in its stderr spool and in the `/doctor` ledger
rather than on screen.

Pressing `Esc` while a reply is streaming stops it, and so does `Ctrl+C`:
outside the prompt the default Ctrl+C handler would kill the process
mid-turn, skipping every `finally` block - console restoration included - so
it is caught and treated as the cancel the user meant. Whatever arrived is
kept, any tool the model was about to call is not run, and the conversation
stays usable for the next question. `Ctrl+Break` keeps its default meaning:
a user reaching for it wants the process gone, not the reply stopped.

A bare `/model` fetches the models this key can actually use from
`GET /v1/models` and offers them as a numbered list, current one marked,
Enter to keep it. Typing an id from memory is guesswork about a namespace
that changes under you - the retired-default 404 was exactly that - so the
list comes from the API, which cannot be stale. `/model <name>` still sets
one directly, deliberately unvalidated: a model newer than the list, or one
behind a beta flag, should not be un-pickable.

Transient failures (429, 529, 5xx) are retried up to three times with a
widening delay, and the wait is interruptible. When the response carries a
`Retry-After` header the server's own wait is used instead of the guess -
guessing shorter re-hits the limit, guessing longer wastes the user's time.
The value is clamped to a minute; a server asking for an hour is answered by
giving up, not by an unkillable hour-long sleep.

At the prompt, the arrow keys move the caret and walk the command history,
`Home`/`End` (or `Ctrl+A`/`Ctrl+E`) jump to either end, and `Ctrl+U` clears
the line. `Ctrl+W`, `Ctrl+K`, `Alt+B`, `Alt+F` and `Ctrl+Z` are the readline
verbs it was missing; `/vim` turns on a modal editor and
`%USERPROFILE%\.pasclaude\keys.json` rebinds any of it. See *Editing the
prompt* below, which also records why nothing in that file can reach a
permission prompt.

History persists in `.pasclaude\history.txt`, so Up-arrow reaches last
week's build command in a fresh window. One command per line, multi-line
prompts stored with backslash escapes (`\n`, `\\`), capped at 200 entries,
written after every accepted line for the same reason the session is - the
run worth remembering is the one that ended in a closed window. A missing
or unreadable file is simply an empty history, never an error.

`/think` enables extended thinking. The request carries a
`thinking: {type: enabled, budget_tokens}` block, and `max_tokens` grows by
the budget so a long think does not starve the visible reply that follows
it. Budgets under the API's floor of 1024 are rounded up rather than
rejected; a bare `/think` uses 8192. The reasoning streams in grey as it
always has - the decoder handled thinking blocks and signatures from the
start, there was just no way to ask for them.

`/diff` answers "what changed?" in aggregate, since approvals happen one
edit at a time: the files this session's `write_file`/`edit_file` actually
touched (denied and failed calls are not recorded), followed by
`git diff --stat HEAD` when the directory is a repository - which also sees
hand edits the session list cannot.

pasclaude notices when it is running inside an editor's terminal, and only
then. VS Code sets `TERM_PROGRAM` and `VSCODE_INJECTION` in its integrated
terminal; JetBrains sets `TERMINAL_EMULATOR`. Both are tested for exact
equality, so a terminal that merely has `vscode` somewhere in its name is not
an editor. Outside one, `/ide` says so and does nothing, and every other
surface reads "not detected" rather than inventing a host.

`/ide diff` opens what this *session* changed: the file as it stood before
pasclaude first touched it, in a real diff tab, against the file as it is now.
That is not the diff you approved - it is the accumulated one, from the same
snapshots `/rewind` restores from, which is exactly the thing that is hard to
see at the end of a long session. `/ide open <path>:42` opens a file at a
line. Nothing goes the other way: the editor is never read from, no selection,
no cursor, and nothing an editor prints is captured. There is no extension,
there is no selection support, and there is no plan for either - a VS Code
integrated terminal exports nothing naming a file, a line, a column or a
selection, so there is no channel to read one over and none was invented.

The left-hand pane is a copy of your file, written under
`%LOCALAPPDATA%\pasclaude\ide` and never beside the file it came from, so
nothing appears inside the project you are working in. It does not linger: the
next launched `/ide diff` deletes the last one, so only ever one exists, a diff
you decline or that fails to start deletes the file it just wrote, and the end
of the session deletes whatever is still held. What survives all of that is a
session killed outright - `Ctrl+Break`, the window's X, Task Manager - which
runs no shutdown of any kind; that file is collected by a day-old sweep the
*next* time you run `/ide diff`, and by nothing else, so a session you never
run the command in again never runs the sweep. A file that was too large to
snapshot has no "before" side at all, and `/ide diff` says so and names the
400 KB limit rather than opening nothing.

The approval prompt was left alone on purpose. Opening the proposed change in
the editor sounds better than a diff in the terminal and is worse in practice:
`--wait` blocks until you close the tab, so the y/a/n prompt cannot be
answered, and without `--wait` the tab shows a change that has not happened
and stays open after you decline it. A rejected edit leaving a tab that looks
applied is a worse mistake than any amount of terminal diff.

Starting the editor is starting a program. It goes through the same spawn
every other child does, with the sandbox level forced off for the duration and
restored afterwards - a GUI shim under low integrity cannot reach your own
editor process. A slash command you typed never reaches the permission gate,
so rather than leave that silent, pasclaude prints the exact command line and
asks once per session. `a` there lasts the session and is never written to
disk: standing approvals are for tools, not for licences to run programs.

`Tab` completes: slash commands at the start of the line, file and directory
names anywhere else, resolved against the session root. Several matches extend
to their common prefix; directories complete with a trailing `\` so another Tab
descends. Pasting a multi-line block keeps its line breaks as one prompt
instead of firing a request per line, and `Ctrl+Enter` inserts a break by hand.

`@path` in a prompt attaches that file to it: the model starts with the
contents instead of spending a tool round reading them. Mentions face the same
path guard as tool calls - no escaping the root, no reaching the session state
- and an oversized file is reported rather than attached. A binary file is
still reported rather than attached, unless it is one of the four image types
the API takes, which is where *Images* below picks the story up. Tab completes
paths after the `@` too.

Replies render markdown as they stream: headings and **bold** brighten,
`inline code` and fenced blocks colour cyan, fence lines are swallowed. The
renderer holds back only the current incomplete line, so output appears line
by line. Unclosed marks print literally rather than swallowing text.

Requests carry two `cache_control` breakpoints: one on the system prompt
(whose span also covers the tools) and one on the last message, so each turn
reuses the cached conversation prefix instead of re-paying full price for it.
Cached reads are billed at a tenth of the normal input rate; `/cost` shows the
cache counters when they are nonzero, which is also how a working cache is
distinguished from a silently ignored marker.

A long session eventually outgrows the context window, and the failure mode is
the API rejecting the whole turn. Before each request the transcript is trimmed
back to roughly 100 KB by dropping the oldest exchanges; `/compact` does it on
demand. The cut is walked forward to a real user message, because a transcript
that opens with an assistant turn - or with tool results whose call has been
removed - is refused.

Bytes are a proxy for the thing that actually fills the window, so a second
trigger reads the measured truth: the prompt token count the API reported for
the last request (`/cost` shows it as `context:`). Past 150k tokens the
compaction is the summarizing kind - the measured trigger fires at a size
where the old turns are worth one request to keep - and falls back to the
plain trim if the summary request fails, because a session that cannot
summarize must still not outgrow the window.

`/context` is what to type before deciding which of those to do. The
statusline meter and `/cost` both answer *how full*; this answers *with what*,
which is the question somebody actually has when they are choosing between
`/compact`, `/clear` and evicting images. It prints two groups, and the split
is the cache breakpoint rather than a cosmetic one: the system prompt and the
tool declarations sit ahead of it and cost a tenth on a hit, while every byte
of the conversation is re-sent at full price every turn. The conversation is
broken into six fixed rows - your messages, replies, thinking, tool calls, tool
results, images - with a block count beside each, so `2 images, 8 KB` and
`40 images, 8 KB` read differently, as they should.

**One measured number, and everything else in bytes.** The API reports prompt
tokens for a request as a *whole* and never per block, so the token figure is
the one the server sent and the table beside it is byte shares. A tokens column
per row would mean inventing a bytes-per-token ratio and applying it to prose,
base64 and JSON keys alike - the same class of invention as the price table
this program refuses to ship, and wrong the same way. What is honest is the
session's own measured ratio, printed once at the foot as a single figure you
can apply yourself. The rows also sum to *less* than the transcript, and the
gap is named rather than absorbed: the role keys and array punctuation wrapping
every message are real bytes that no eviction can reach.

The classification is by block type first and role second, which matters for
exactly one row: a `tool_result` rides in a *user* message, so asking about the
role first would file every tool result under "your messages" - and that is the
row somebody would then try, and fail, to shrink by typing less. `ux` asserts
it.

`/compact full` is the expensive kind: it asks the model to summarize the
conversation - what was asked, what was done, exact paths, decisions and
their reasons, what is unfinished - and replaces the whole transcript with
that summary as one legal exchange. One request buys a transcript that keeps
the substance of the dropped turns instead of forgetting them. The old
transcript is only replaced after a non-empty summary has fully arrived;
a failed request, a cancellation, or an empty answer restores the
conversation byte for byte, because a compaction that destroys the
conversation on a dropped connection is worse than no compaction.

## Sessions

The conversation is written to `.pasclaude\session.json` after every turn, so
the session worth keeping - the one that ended in a crash or a closed window -
is already on disk. `--resume` picks it up at startup and `/resume` does the
same later; `--continue` takes the most recently written save instead -
whichever of the live file, the safety copy or a `/save` that is - and
`/save` forces a write.

The API key is never stored. It belongs in the environment, and writing it into
a file inside the user's project is how secrets end up committed.

A saved file is validated before it replaces anything: it must be an object of
a version this build understands, every message must have a known role and at
least one typed content block, the transcript must open with a user message,
and every `tool_use` must be answered by a `tool_result` carrying the matching
id. Anything else is refused with a reason, and the conversation already in
progress is left exactly as it was. That ordering is the point - a file the
user hand-edited should cost them nothing, and a transcript the API would
reject is worse than no transcript at all, because it fails on every later
request rather than at load time.

The write goes to a temporary file and is renamed over the old one. It runs
after every turn, so a crash or a full disk partway through a plain in-place
write would take the previous good session with it - `fmCreate` truncates
before it writes. The file on disk is now always one complete session or the
other.

A turn that fails - no key, no network, a rejected request - leaves the user's
question in the transcript with nothing answering it, and autosave runs after a
failed turn too. That question is dropped before saving, so a session never
ends on an unanswered user message. A trailing `tool_result` is deliberately
not treated the same way: it answers the assistant turn before it, and removing
it would orphan that tool call.

`/clear` clears the saved copy too. Otherwise it would mean "cleared until you
resume", and a conversation the user deliberately discarded would come back on
the next run.

`.pasclaude` is invisible to the tools. It sits inside the directory the model
is working in and holds the conversation, so `search` would otherwise match it
and hand the model a copy of its own transcript - which goes into the next
request, gets saved again, and grows every turn. `edit_file` could rewrite the
history of the turn currently running. It is skipped by `list_dir` and `search`
and refused by the path guard, including by a roundabout path. A file merely
named similarly, like `.pasclaude-notes.md`, is unaffected.

Starting in a directory that already holds a session, without `--resume`,
moves that session to `session.prev.json` before anything can overwrite it. Two
windows open on one project is not exotic, and the second one used to destroy
the first's conversation on its very first save.

`--resume` is the one exemption, and it is exempt because it loaded that exact
file: the copy would be a copy of what is about to be written back. `--continue`
is not exempt, though it briefly was. It takes whichever save is newest, which
may be a `/save` copy, and loads nothing at all when the newest one will not
parse - and in both of those the first turn writes over a `session.json`
nobody read. So the copy is taken whenever the file about to be overwritten is
not the file that was loaded, which is the question that actually matters
rather than which flag was typed.

## Tools

| Tool | Approval | Notes |
| --- | --- | --- |
| `read_file` | no | line-numbered, capped at 400 KB, hex dump if not text; a `.ipynb` comes back as numbered notebook cells instead |
| `list_dir` | no | skips `.git`, `node_modules`, `.pasclaude` and `.gitignore`d entries; depth 4 when recursive, or a `depth` argument up to 12 |
| `search` | no | case-insensitive substring or, with `regex`, a bounded regular expression; `*` globs, `case_sensitive` and `depth` arguments, an optional `path` narrowing it to one tree, respects each root's `.gitignore`, capped at 200 hits |
| `write_file` | yes | creates intermediate directories |
| `edit_file` | yes | one hunk or several at once; all must match or none apply |
| `notebook_edit` | yes | replace, insert or delete one cell of a Jupyter notebook; same diff preview and approval as `edit_file` |
| `bash` | yes | `cmd.exe /C` inside a job object, output merged, 120 s timeout; `run_in_background` returns a job id instead of waiting |
| `bash_output` | no | what a background job has printed since the last read, or the list of jobs |
| `kill_bash` | no | stops a background job and the whole process tree under it |
| `fetch` | yes | HTTPS GET, capped at 200 KB, own "always" class |
| `todo_write` | no | the visible task list; display state, touches nothing |
| `task` | no | hands a self-contained question to a read-only subagent |
| `skill` | no | reads a named `SKILL.md` out of the project; declared only when the project has skills |

`web_search` is declared to the API rather than implemented here: the search
runs on Anthropic's servers, `/web on` is what turns the declaration on, and
there is no local code for it to call. An MCP server's tools appear beside
these as `mcp__<server>__<tool>`, contributed at runtime rather than written
down here.

At each prompt you can answer `y` (once), `a` (always) or `n`. Read-only
tools never ask. For the edit tools and fetch, "always" covers the tool
class. For bash it covers the *program*: answering `a` to `git status`
approves future `git` commands, not `del /s` - quietly extending one
approval to every future command is how trust gets spent. The prefix is the
first token, lowercased, stripped of path and `.exe`, so `git` and
`C:\Tools\git.exe` match. A compound command (`&`, `|`, `;`, redirects,
`%var%`, `^`) has no prefix and is asked about every time, because cmd.exe
runs everything after the separator regardless of what the first program
was. "Always" for one degrades to this-once. `/yolo` still approves
everything.

"Always" answers persist in
`%LOCALAPPDATA%\pasclaude\approvals\<project>-<hash>.json` - the tool-class
grants, the approved bash programs and the trusted fingerprints - so a
restart does not re-ask what was already answered. It lives outside the
project on purpose: the file records what you let this project do, and a
repository that could ship its own copy would be answering its own
question - pre-approving its own hooks and its own MCP servers before you
saw a prompt. One file per project directory, keyed by its full path.
The file only ever widens what is approved, never
narrows a live grant, and it is deliberately tiny and hand-editable:
deleting a line must do the predictable thing. `/yolo` is the exception:
its blanket flags are "I trust this session", not "and every future one",
so a yolo session never writes the file. Print mode neither reads nor
writes it - a scripted run must not inherit interactive grants.

That file now carries three keys with three different polarities, which is
worth knowing before editing one. The grants (`allow_edits`, `allow_bash`,
`allow_fetch`, `bash_programs`, `trusted`) only widen: a true key can turn a
flag on and an absent one can never turn it off, which is what makes
`allow_edits: false` - written by `/mode ask` - a durable off switch rather
than a silence. `deny` only narrows, is read by a different function that runs
much earlier, and is written back verbatim, unparseable lines included,
because a hand-edited rule silently erased at exit is worse than one that
never worked. `sandbox` only raises: `"low"` loads, `"off"` is neither written
nor read, so nothing on disk can be the reason the sandbox is not running.
Working directories and the permission mode are stored nowhere at all.

The model also has a `todo_write` tool for multi-step work: it maintains a
task list that renders in the terminal as it changes - `[x]` done (green),
`[~]` in progress (yellow), `[ ]` pending - so a long task shows its plan
rather than a wall of tool calls. No approval needed; the list is display
state and touches nothing.

`fetch` reaches the outside world, so it asks - and its "always" answer is
its own class, separate from the edit tools, because approving edits forever
should not quietly approve network access too. Only `https://` URLs are
accepted, the response is cut at 200 KB during the transfer rather than
after it, and a body that is not valid UTF-8 is scrubbed rather than
hex-dumped: a page in another encoding is still mostly readable text,
unlike a binary file.

`search` takes a regular expression when asked for one, and the engine is
hand-written (`src\uRegex.pas`) rather than `uses RegExpr`. The reason is
worth recording, because the obvious choice is the wrong one. FPC does ship
TRegExpr and it compiles and links here - that was checked before anything
was written. It was rejected on one property: TRegExpr 0.987 is a
backtracker with no step limit, no deadline and no abort hook anywhere in
its source. Measured on this machine, `(a+)+$` against a run of `a`s took
109 ms at 20 characters, 1.7 s at 24 and 17.7 s at 27 - a clean doubling per
character. A tool call runs synchronously with nothing above it holding a
clock (the 120 s deadline belongs to the shell runner, not the tool layer),
so one pathological pattern against one ordinary line of code would freeze
the session with no way out short of killing the process. Nothing bolted on
from outside fixes that: an input-length cap cannot beat an exponent, a
watchdog thread cannot interrupt a compute loop, and screening patterns for
nested quantifiers is a heuristic that misses `(a|a)+` and `a?a?a?...`.

So `uRegex` is a Thompson NFA simulation instead. All live threads advance
over the line in lockstep, one byte at a time, with a per-position visited
set that collapses duplicate program counters; the cost is bounded by line
length times program size, and catastrophic backtracking is not screened
for - it cannot be expressed. It is small (about 900 lines) only because
`search` reports whole matched lines and never a slice of one, so it needs
no capture groups, no leftmost-longest rule and no greedy/lazy distinction.
On top sits a step budget spent once per search rather than per line; when
it runs out the tool reports the hits it found plus a note that the search
was stopped, because "incomplete" is a different answer from "no matches".
`bin\fuzz.exe` asserts that `(a+)+$` over 60 characters returns in under two
seconds - the assertion that encodes the whole decision.

Regex is opt-in through `regex: true` rather than detected from the pattern:
`Result :=`, `array[0]` and `foo.bar` are exactly what code searches look
like, and auto-switching would silently change what an existing prompt
means. The syntax is byte-oriented ASCII (`\w` and `\b` are `[A-Za-z0-9_]`,
bytes at or above $80 match only as literals, no backreferences, no
lookaround), which is safe because the output is always a whole line, so no
match can cut a UTF-8 sequence in half. Both tree walkers take a `depth`
argument now, 1 to 12, clamped rather than refused; their defaults are
unchanged.

pasclaude reads a `.ipynb` as cells, not as JSON. `read_file` on a notebook
prints `== cell 0 (code, execution_count 3) ==` headers followed by the
source verbatim and one summary line per output: `image/png (148.2 KB)`
rather than the 148 KB itself. That is the whole point - a single
`display_data` output is routinely megabytes of base64, and dumping it would
spend the context on data the model cannot use. text/plain reprs are shown
(truncated), streams and tracebacks are shown with ANSI escapes stripped,
and everything past 15 lines or 2000 characters per output, or 8 outputs per
cell, is counted rather than printed.

Editing goes through `notebook_edit(path, cell, edit_mode, source?,
cell_type?)`, not `edit_file`. Damage from the wrong read default is
unrecoverable - the base64 is already in the context - so reading had to
change; editing had to be a separate tool because `edit_file`'s contract is
substring replacement on file text, and a notebook's text is JSON. Overload
it and `old_text` means something different depending on the extension,
while insert and delete have no expression in its schema at all.
`notebook_edit` asks for approval exactly as `edit_file` does, and its diff
preview is a diff of the cell view - so what the user approves is what the
model proposed, in the same words, and base64 cannot reach the prompt.

The file is written back in Jupyter's own layout (one space of indent,
sorted keys, trailing newline), byte-identical to what nbformat produces:
round-trip fidelity here means "the user's git diff shows one changed line",
not "Jupyter still opens it". A notebook someone formatted differently is
reformatted once on the first edit, which the permission prompt announces.
Non-ASCII is written raw, which is what nbformat does too - its writer passes
`ensure_ascii=False` to `json.dumps`, against that function's own default -
so an accent, a CJK character or an emoji outside the BMP comes back as the
bytes it went in as and no line the user did not touch moves. This README
used to claim the opposite, that escaping was a deliberate deviation; it was
not a deviation and it was not deliberate, it was untested, and the fixture
that now checks it was written by nbformat itself. A file that arrived with
`\uXXXX` escapes in it, which some other writer produced, keeps them: the
parser remembers the literal a string arrived as whenever writing it back our
way would change it, and the writer hands that literal back, so the user's
diff is still the one line they asked about. Those two sentences are not in
tension - the first is about what this program writes when it is composing a
string, the second about what it reproduces when it is rewriting somebody
else's file - and the second reverses an earlier preference on purpose:
normalising towards Jupyter's spelling is still a change to a line nobody
touched. Three limits. Object keys are not covered, because the keys of an
object live in a parallel array that four operations shift and a raw-key
array shifted out of step would emit one field's name onto another, which is
a corrupted notebook rather than a spurious diff. It is the literal that
is reproduced, not the layout: indent, key order and the trailing newline are
still canonicalised, which is the reformatting the permission prompt
announces. And a string that arrived carrying a **raw** byte below `0x20` -
an unescaped tab or newline inside the quotes, which this parser accepts and
strict JSON does not - is written back escaped rather than as it arrived, so
that one string's other escapes are normalised with it. That is the one place
"keeps them" is knowingly not kept, and it is deliberate in the other
direction: handing the raw byte back would produce a file `nbformat` refuses
to read, which is worse than any diff. The fidelity is switched on by the notebook path alone - one
parser entry point, `uJson.JsonParseVerbatim`, whose only caller is
`uNotebook` - so a request body is still composed and emitted exactly the way
it always was. The line array is cut where Python's
`str.splitlines(True)` cuts it, which is on eleven things and not on `\n`
alone: a form feed page break in a Python source used to make one array
element here where Jupyter makes two. A source replace
keeps the cell's outputs and execution count - the user approved "change
this cell's code", not "throw away the plot it produced" - and the cell view
labels them, so a later read shows the model they are now stale.

Only nbformat 4 is supported. A v3 notebook is refused by name rather than
upgraded, and that stayed the answer after the upgrade was measured rather
than guessed at: nbformat's own converter flattens the worksheets, joins a
heading cell's lines into one, and draws every new cell id from a random word
corpus, so the same v3 file converted twice gives two different v4 files. A
conversion that is not reproducible cannot be the no-op an edit has to be,
and it rewrites every line of a document whose one guarantee is that an edit
touches the cell it names. The error names the tool that owns the conversion
instead of only saying no.

Shell commands can outlive the tool call that started them. `bash` takes
`run_in_background`; setting it returns a job id straight away instead of
waiting. `bash_output` reads whatever the job has produced since the last
read, along with whether it is still running and its exit code once it is
not; called with no job id it lists every job instead. `kill_bash` stops a
job and everything it started, and hands back the output it had not yet
given up. `/jobs` shows the same list to the user, because a process started
on their behalf by a model has to be visible without asking the model about
it. Foreground commands still time out after 120 seconds; background ones do
not.

Output goes to a spool file under `.pasclaude\jobs`, not a pipe. An
anonymous pipe that nobody drains fills and then blocks the writer forever,
and for a background command "nobody is draining it" is not a risk but the
definition, so the deadlock would be the normal case rather than the corner.
The alternatives were a reader thread per job - in a codebase with no
threading anywhere to model one on - or an overlapped I/O state machine. A
file cannot fill. The child's stdin is an inherited handle onto `NUL`, so a
command that reads stdin gets an instant EOF instead of waiting forever for
a keyboard nobody is at.

Each job also owns a Win32 job object with kill-on-close, so the whole
process tree dies with pasclaude, including the case where pasclaude dies
badly: Windows reclaims the handle even when no `finally` block runs. That
is the only mechanism on Windows that answers "must not be orphaned"
honestly - `TerminateProcess` on `cmd.exe` leaves the grandchildren, which
is precisely the shape of `npm run dev`, and `taskkill /T` does nothing at
all if pasclaude itself is killed. FPC 3.2.2 does not declare the job API,
so the prototypes are declared once, in `uSandbox`, which is also where the
job is created and the child assigned to it before it is allowed to run.

Polling reads the spool from a per-job byte offset that advances by exactly
what was returned: no byte twice, no byte skipped. While the job is running
the chunk is trimmed back to the last newline, so the model never sees half
a line - and never a multi-byte character split across two reads, which
would leave both halves invalid with no way to rejoin them. A single line
longer than the read cap is the exception, handed over cut at the last
complete character rather than held back forever. A poll is bounded by that
read cap rather than by `Clip`, because `Clip` would drop bytes the model
can never ask for again. OEM console output is converted to UTF-8 exactly as
it is for foreground bash.

A background command faces the same permission gate as a foreground one, and
the same remembered per-program approval covers both. Backgrounding is a
question about who waits, not about what runs: a detached `del /s` deletes
exactly as much as an attached one. The prompt says `[background]` so the
user can see they are approving a run that outlives the answer.
`bash_output` and `kill_bash` ask nothing - they can only observe or stop a
process this session already got permission to start, and refusing a kill is
a gate that can only ever do harm. Jobs stop at `/clear` (the transcript
holding their ids is being thrown away, and a job nobody can name is a
process the user cannot get rid of) and at exit. They deliberately survive
cancellation: Esc cancels the model's reply, not the user's build. At most
eight run at once, and a job that writes more than 16 MB is stopped and says
so.

Two limits are worth stating rather than hiding. The 16 MB cap is checked on
a throttled tick that runs at the top of every executed tool call, on every
chunk of a streaming reply, before every prompt is drawn, and now every
quarter second while the user sits at a prompt - the console read waits with
a timeout rather than blocking forever, and the permission question ticks on
the same clock, because that is where a user sits longest. Enforcement no
longer depends on the model choosing to start, poll or list a job, nor on
anybody touching the keyboard. Every quarter second *nobody types*, exactly:
a wake caused by a key goes straight to the read and runs nothing, because a
sweep that has to kill a job waits two seconds for each one to die, and that
belongs at an idle prompt and never between two characters of a line being
typed. A paste or a held key therefore suspends the sweep until the typing
pauses, which is a window bounded by the burst. It is still a bound and not a
guarantee:
nothing here is in the child's write path, so a child can write between two
ticks and the real promise is the cap plus a quarter-second of writing -
everywhere, with no exception for the prompt. And a job still running at exit
is stopped by design, so a user who wanted a truly detached server will find
it gone; that is the deliberate trade against orphaning, which the launch
message and `/jobs` make visible.

A tool call shows up the moment its block opens in the stream - the name
first, then the argument JSON echoed as it arrives (capped at 160
characters) - so a long argument stream, a big `write_file` say, reads as
progress rather than as a hang. The full description line follows once the
arguments are complete.

A `.gitignore` at the root filters listings and searches - build output is
noise the model pays tokens to look at. The reading of the format is
deliberately partial (dir rules, `*` within a segment, anchored rules, `!`
negation); anything unmatched is shown, which errs on the side of the model
seeing more. When the directory is a git repository, the system prompt names
the branch and whether the tree is dirty, saving the model its most common
first command.

A write or edit shows its diff before you answer, so the decision is about the
change rather than about the file name:

```
  permission needed: edit_file
    edit src\uAgent.pas
    1 added, 1 removed
      if not SendWithRetry(Blocks, StopReason, Err, Cancelled) then
    - Exit(False);
    + Exit(RecordFailure(Err));
      RecordAssistant(Blocks);
```

The diff is built from the file as it is on disk, not from what the model
believed was there, and it is only computed when someone is actually going to
be asked - under `/yolo` the work is skipped entirely. A binary file is
summarised instead of dumped, and an edit whose snippet is missing or
ambiguous is refused before any prompt appears.

## The permission predicate

"May this run?" is answered in four functions, and the order they run in is
the whole of the argument. It is written down here because a line inserted in
the wrong place still compiles, still passes most of the suite, and quietly
turns a boundary into a suggestion.

`RunTool` is the boundary layer. It runs before any gate is consulted:

```
R0   IsError := False
R1   clear the pending hook allow    (a hook's yes never crosses calls)
R2   refuse a nil input              (a rule cannot be matched against nothing)
R3   [DENY] a tool rule matching the name
R3b  [DENY] a bash rule matching any cmd.exe segment's program name
R4   plan mode: refuse anything not on the plan allowlist
R5   the subagent read-only list
R6   fire PreToolUse hooks; a block refuses here
R7   the per-tool arm: validate, resolve paths through SafePath, build the
     preview, call the gate
R8   fire PostToolUse hooks
```

Below that sit the three gates, and each opens with the same lines. `Permit`
(edits, fetch, MCP tools) is `[DENY]`, then `BypassMode`, then the class
allow-alls, then the edits catch-all, then a per-server standing yes, then the
nil-`Ask` refusal, then a hook's allow, then the question itself. `PermitBash`
is `[DENY]` twice - the tool name and the program name - then bypass, the bash
blanket, the stored prefix, nil `Ask`, a hook's allow, the question.
`SafePath` resolves the path, refuses anything outside every root, refuses the
state directory, and only then applies the path rules.

Five orderings carry the safety, and none of them is stylistic.

**Deny is first everywhere.** Above the class allow-alls, above the bash
prefix table, above the nil-`Ask` check, above a `PreToolUse` hook's `allow`,
and above `BypassMode` - so nothing overrides a rule: not `/yolo`, not an
"always" answered weeks ago, not a hook that answers allow. It is also above
the hook *fire*, because a hook is a program a repository ships and handing it
the arguments of a call the user forbade is a leak even when the hook cannot
allow it. The copies in `Permit` and `PermitBash` are belt and braces: a
reader sees deny-first without trusting the caller, and a fifth gate added
later cannot be talked into a yes. Any fifth gate opens with the same lines -
that is a copy-paste rule on purpose, not a memory test.

**Plan mode is a boundary, not a gate setting.** It lives in `RunTool`, in a
different function from `Permit`, beside the subagent read-only list. A check
inside the gate would have sat below the very short-circuits it needed to
beat; here, bypass, a class allow-all, a stored bash prefix, a hook's allow
and a nil `Ask` are all structurally unable to lift it, and none of them had
to be taught that plan mode exists.

**`TakeHookAllow` stays below the nil-`Ask` check.** Three properties fall out
of that position with no separate guard: print mode cannot be widened by a
hook, a subagent cannot, and the flag is reachable only where a human was
about to be asked anyway. The position is frozen; a feature that moves it is
a defect.

**`SafePath` is the only place a path argument becomes an absolute path.**
Every path-taking tool, the change preview, `@`-mentions and `@import` funnel
through it, so `..\` tricks, 8.3 names and junctions are unwound exactly once
and a tool added later cannot forget the rule. Deny is applied once, outside
the root loop, on the winning candidate: inside the loop it would be
order-dependent, and a rule whose effect depends on which directory was named
first is exactly the silently-failing rule deny exists to eliminate. The
escape comparison exists in one function, `WithinRoot`, and compares against
`Root + PathDelim` - which is what refuses `C:\proj-sibling\leak.txt` against
`C:\proj`. Nobody else writes a prefix compare.

**The sandbox is not an input to any of this.** No branch of any gate reads
`uSandbox.SandboxLevel`, and the level does not appear in an approval prompt's
detail line either. A confined command still reads every file you can read and
still reaches the network, so "it's sandboxed" buys no approval discount, and
a level shown at approval time would only invite "so yes".

What can move any of it is a short list, and the project directory is not on
it. No mode, working directory, deny rule or sandbox level is ever read from a
file inside a root, from a hook's output, from an MCP server, a skill, a
custom command, a plugin manifest or anything the model can emit. A mode comes
from a keystroke, from this process's command line, or from the `allow_edits`
key the user's own "always" wrote in `%LOCALAPPDATA%`. A working directory
comes from argv or a typed command. A deny rule comes from
`%LOCALAPPDATA%\pasclaude\deny.json` or from a hand-edited `"deny"` array in
the per-root approvals file. The sandbox level rises from argv, `/sandbox`, or
a key a previous session wrote, and falls only from argv or `/sandbox`. The
built-in slash dispatch runs above custom-command expansion, whose result is
prompt text and is never re-dispatched; that ordering is load-bearing.

Under `-p` every one of these is either identical or strictly stricter. Deny
rules load *before* the print-mode halt and standing approvals load after it,
so a scripted run inherits every refusal and no grant, and can neither add nor
remove a rule. `LoadDenyRules` reads only the `deny` array of each file, and
that is the whole reason: it is the one reader of the approvals file that runs
early, and if it ever grew to read a grant key, `-p` would start inheriting
approvals.

## Deny rules

One string per rule, `kind:pattern`, in a JSON array:

```
tool:bash        tool:fetch      tool:mcp__github__*
bash:rm          bash:del
path:.env        path:**/*.pem   path:/secrets/**
```

`tool:` and `bash:` are read at the top of `RunTool`, above the `PreToolUse`
hook fire; `path:` is read inside `SafePath`, where every path-taking tool,
`@`-mention and `@import` already funnels. A refusal names the rule and the
file it came from, so a rule is never mistaken for a bug. A pattern with no
separator in it is a name rule and matches the base name at any depth, so
`path:.env` catches `src\.env` without anybody thinking about where they are;
a pattern with one is anchored, and measured against whichever root contains
the file, so `path:secrets/**` means the same thing in an added working
directory as it does in the session root. Path rules also hide the file from
`list_dir` and `search` - the guard and the walkers agree, rather than the
walkers hiding something the guard would still hand over by absolute name.
An unparseable rule is kept with its reason, reported at startup and listed as
NOT IN FORCE, because a user who wrote `read:.env` believing it protected
something has to be told it does not.

Rules live in `%LOCALAPPDATA%\pasclaude\deny.json` (global, every project) and
in a `"deny"` array in the per-root approvals file (per project, hand-edited,
written back verbatim). Nothing in a repository is ever read for one - a deny
rule can only narrow, but strictness in one place buys looseness in another:
denying `search` pushes the model onto `bash`, where an "always" the user gave
weeks ago is waiting. `/deny` lists rules with their source file; `/deny add
<rule>` and `/deny remove <n>` write the global file. `remove` is the only
widening operation in the feature and exists only at the console - unreachable
from `-p`, from the SDK protocol, from a hook, from a server, from the model.

Three honest limits, printed by `/deny` as well as documented. `bash:` reads
the first token of each `cmd.exe` segment - it catches `git status && rm -rf
x`, where the approval prefix table gives up, but it cannot follow `%VAR%`
expansion, a `for` loop, a renamed copy, a `.cmd` wrapper or a caret inside
the name (`r^m`); `tool:bash` is the airtight form. `path:` covers pasclaude's
file tools and not the shell: `type .env` run through bash never touches
`SafePath`. Hardlinks evade `path:` - canonicalisation follows junctions, 8.3
names and case, but a second name for the same bytes is a different path to
every API Windows offers.

`fetch:<host>` is deliberately not offered. WinHTTP follows redirects and
`uHttp` sets no redirect policy, so a host rule would match the URL the model
typed and not the host that answered; `tool:fetch` is the honest version.
Blocking an MCP server's *spawn* is likewise not a deny rule: the spawn
decision happens before any tool name exists, so a rule can only block calls
(`tool:mcp__srv__*`) and stopping the program means editing `.mcp.json`.

## Permission modes

The gate now has a word for what it is doing, and the word is on the prompt.
`ask` is the default and means what it says. `accept-edits` stops the prompts
for file writes and nothing else - it is the flag a previous "always" answer
already set, finally visible and finally revocable. `bypass` approves
everything for this session and persists nothing. `plan` is the odd one out
and the most useful: the model may read, search, fetch and keep a todo list,
and every call that would change anything is refused before the permission
gate is consulted at all.

That last clause is the design, and its mechanics are in the predicate section
above. What plan mode allows is an allowlist of seven tool names in one line -
`read_file`, `list_dir`, `search`, `todo_write`, `skill`, `task`,
`bash_output` - which is how a tool somebody's MCP server contributes next
year is refused without anybody deciding to refuse it.

`fetch` was on that list once, on the argument that investigation is the point
of the mode. It came off. Every other name there reads something already on
this machine, which is what makes plan mode safe to enter without being asked
anything; `fetch` is the one channel by which what those tools read can leave.
A mode whose promise is "look, do not touch" cannot also POST the tree to a
URL, and a promise with one exception is not a promise anybody can rely on.
Investigation that genuinely needs the network is what leaving plan mode is
for.

The model is told the mode twice: once as a paragraph in the system prompt, so
it does not spend a turn finding out, and once in the refusal, because prompt
text is advice it can ignore mid-turn. The paragraph rides in a trailing
system block with no cache marker, so turning plan mode on costs a few dozen
tokens instead of re-reading the whole cached prefix - and with everything at
its default the request body is byte-identical to what it was before this
feature existed.

There is no tool the model can call to leave plan mode. A tool that lets the
model leave plan mode is a tool that lets the model grant itself write access.
Leaving is a keystroke - `/mode ask` or `/mode accept-edits` - and it approves
nothing retroactively: a plan is prose, and an approval that claims to cover
"the plan" while actually covering everything is a lie with a friendly label.
What real approval looks like is the diff `ChangePreview` already renders, one
edit at a time. `/mode ask` also revokes the bash, fetch and MCP class
blankets, which is broader than the name suggests and is printed; the named
per-program and per-server grants are left alone, because each of those named
the thing it covered.

`--dangerously-skip-permissions` is `/yolo` before the first prompt, including
under `-p`, and it is the largest single weakening in the program: a prompt
injection in a repository file reaches a fully unattended agent. It keeps its
long spelling on purpose - `--permission-mode bypass` is rejected by the
parser with a message naming the real flag, and `/mode bypass` says the same.
What still stands in its way: the session root, the deny rules, the subagent
read-only list, and the fact that `-p` halts before it can load a hook or
spawn an MCP server. Two combinations are startup errors rather than silent
precedence: `--permission-mode accept-edits` under `-p` with no stream-json
driver ("stop asking me" presupposes a me), and `--permission-mode plan`
together with `--dangerously-skip-permissions`, where either guess about which
the user meant is dangerous.

No mode is persisted or resumed - a session restarted with `--resume` comes
back in `ask` - and plan mode stops the model, not the machine: a
`SessionStart` or `UserPromptSubmit` hook is a command the user configured
themselves, and it still runs. `/mode` says so, and prints the four class
flags, the counts of the narrow grants a mode word does not cover, and whether
this session will persist anything at all. The prompt string carries the mode
on every keystroke (`plan> `, `accept-edits> `) with a `+` when a class grant
or a stored bash prefix makes the bare word an understatement; the `+` is a
pointer to `/mode`, not information, because no suffix can render every
combination and one that tried would be read as complete.

## Sandboxing

This is defence in depth and not an approval mechanism, and the two must not
be described in the same breath as if they were points on one scale. A mode
decides what you are asked; the sandbox decides what a child process can do
once you have said yes.

Every command pasclaude runs - the bash tool, a background job, a hook, an MCP
server - starts inside a job object. The tree is capped at 64 processes,
cannot break out of the job, cannot read the clipboard or change your desktop,
and dies when the session does. That is the default, it costs nothing, and a
command that behaves will never notice it. `/sandbox off` removes the limits
but not the job itself: kill-on-close is what makes `kill_bash`, a hook's
timeout and process exit reap a whole tree rather than terminating `cmd.exe`
and orphaning what it started, and that was never one of the restrictions
"off" was meant to switch off.

`--sandbox low` goes further and runs children at low integrity. They then
cannot write your user profile, the registry under HKCU, or any directory
nobody has labelled for them - which includes the project you are working in.
They get a scratch `%TEMP%` of their own instead, under `%LOCALAPPDATA%` and
keyed like the approvals file, out of the tree. That is a real cost, which is
why it is opt-in: a build that writes into its own tree will fail, `npx`-based
MCP servers and hooks that write `%APPDATA%` will fail, and the failure says
so on the same line as the exit code rather than leaving you to guess. When
there is no home directory to put the scratch in, `low` falls back to `limits`
and says so - never to `off`, because failing to find somewhere for a temp
directory is not a reason to stop confining children.

What low integrity does not do is worth saying plainly, because it is the part
people assume. It does not stop a command reading anything you can read, and
it does not stop it using the network - a probe on the machine this was
developed on ran `dir %USERPROFILE%`, read `.gitconfig` and completed an HTTPS
request under low integrity, all exiting 0. Scoping a process to a directory
needs a filesystem filter driver; denying it the network needs a firewall
rule. Neither is something an ordinary program can do to itself, so neither is
offered.

That measurement is why the sandbox changes nothing about what you are asked
to approve. A confined command can still read every credential on the machine
and send it anywhere, so "it's sandboxed" is not a reason to say yes to
something you would otherwise refuse. The level is shown in `/sandbox`, in the
banner when it is not the default, and on a failed command's exit line -
`[exit code 1; sandbox: low]`, tagged on the exit code rather than on any
message marker, because the markers that would let us guess more precisely are
English. A hint naming `icacls` and `/sandbox off` is added on top when the
failure looks sandbox-shaped. It is deliberately not in the approval prompt,
and deliberately not in the system prompt either: a model told it is sandboxed
routes around the sandbox.

Two designs were probed and rejected. Restricted tokens produce a child that
dies at 0xC0000142 without window-station ACL plumbing, and dropping
privileges alone buys nothing on an ordinary user token. AppContainer needs a
persistent per-profile identity and hand-written ACL grants for confinement
that is still mostly filesystem scoping we would have to build anyway. And one
asymmetry is documented rather than smoothed over: under `low`, an added
working directory is writable by `write_file` and not by sandboxed bash.
pasclaude never changes an ACL or an integrity label on anything outside its
own scratch; the failure message tells you the exact `icacls` command so you
can do it to your own tree deliberately.

Building this closed two older defects. The foreground shell had no job object
at all, so a timed-out command killed `cmd.exe` and orphaned its children; and
all three raw spawn sites assigned to the job *after* the spawn, leaving the
grandchild-escape race this README used to list as an accepted limit.
`SandboxSpawn` creates suspended, assigns, and only then resumes - a child
that has not run yet cannot have started anything outside the job.

## Web search

Anthropic's web search is a server-side tool: pasclaude declares it and the
API does the searching. There is no `RunTool` branch, nothing to execute
locally, and - the part that decides the design - no per-call hook to hang a
permission prompt on. Since the user can never be asked "may I search for
this?", the only honest place to put the consent is the declaration itself,
so the declaration is what the user controls. `/web on` turns it on for the
session, `/web off` turns it back off, and `--web` does the same for print
mode, where `Ask` is nil and nothing could be approved interactively anyway.
It is off by default: with it off the tool is absent from the request body
entirely, so the model has no way to reach the network and the session pays
no tokens for a declaration it may not use. It is deliberately not
persisted, for the same reason `/yolo` is not - a standing file meaning "and
every future session may reach the internet" is a wider grant than the word
implied. `fetch` is unchanged and is still the way to read a known URL.

The decoder repair is the interesting half. It assumed every content block
is text, thinking or `tool_use`; anything else fell into an else branch that
turned it into an empty text block, which `RecordAssistant` then dropped for
being blank. A server-side block would therefore have vanished from the
transcript - breaking the echo the API requires on the next request - while
the `input_json_delta` carrying its search query accumulated into that text
block and would have been sent back as assistant prose. Two new block kinds
fix it: `bkServerToolUse`, which is the local `tool_use` shape under a
different type string, and `bkResult`, a raw passthrough that captures the
block's own JSON whole from `content_block_start` and replays it verbatim. A
block this client never understood is one it cannot correctly rebuild, so it
is not rebuilt. Making `bkResult` the fallback for every unrecognised type
fixes `redacted_thinking` and whatever ships next for free.

Exactly one block type is now understood far enough to be shortened. A search
result set is echoed back on every request for the rest of the session and is
by a wide margin the largest thing in the transcript - a title and a url are a
few hundred bytes, and then there is an opaque blob of page content per result
that runs to several kilobytes - so a single verbose search taxes every turn
that follows it. A `web_search_tool_result` larger than 32 KB is therefore
clipped as it is captured: whole results are dropped off the end until it
fits, the last surviving result's title gains a note saying how many went, and
the status line on screen says so at the time. The first result is never
dropped, because an empty array would read as a search that found nothing.
Nothing inside a result that survives is regenerated, shortened or reordered,
so the sentence above about not rebuilding what this client does not
understand stays exactly true of every byte that is sent.

Whether a subscription OAuth token may declare this tool, and whether the
dated type string `web_search_20260209` is still current, are things only a
live server can answer - and a rejected declaration would 400 every turn for
the rest of the session. So a failure whose message names `web_search` turns
the tool off, prints a notice, and retries the same round without it. The
worst case is one wasted request. That converts an unverifiable assumption
into a bounded, testable degradation, which is also the only form of it a
suite with no network can cover. A long server-side run ends the turn with
`pause_turn` rather than `end_turn`, which `Send` treats as "keep going"
instead of as a finished answer.

Two costs come with it. Search results enter the transcript verbatim and are
echoed to the model on every later turn, which is a prompt-injection surface
this codebase did not previously have; default-off limits the exposure but
does not remove it. And results are not `Clip`ped - they are not `RunTool`
output - so a verbose result set inflates the transcript and every cached
turn after it.

## Subagents

The `task` tool hands a self-contained investigation to a nested agent with
its own conversation and returns its final message as the tool result:
`task(prompt, agent_type?)`, one at a time, synchronously, inside the
parent's tool call. The model uses it for the questions that would otherwise
fill the main transcript with intermediate reading - "which unit owns X",
"where is Y configured" - and works from the answer instead of from six file
dumps.

`uTools` sits below `uAgent`, so the tool that spawns an agent cannot know
what an agent is. That is resolved exactly as the network already is:
`uTools` declares `TSubagentProc` and `var SubagentRunner: TSubagentProc =
nil`, and `uAgent`'s `initialization` assigns it. A nil runner means the tool
is not advertised and, if named anyway, returns a plain error - deny by
default extended from files to a capability. It is the same shape as
`uHttp.HttpTransport`, so it introduces no new concept.

A subagent gets `read_file`, `list_dir` and `search`. Nothing else. It runs
inside a tool call, where the user is being asked nothing and is not even
looking at a prompt; threading `Ask` down would raise a permission dialog on
behalf of a conversation the user cannot see, whose question they never
wrote, with a detail line that is a plausible-looking write request and no
context. And it would be theatre, because `Permit` short-circuits on
`AllowAllEdits` and `PermitBash` on a persisted "always" - so under `/yolo`,
or after a single `a` pressed in some earlier session, a writable subagent
would write and shell with no prompt at all. Deny-by-default would be
honoured in letter and defeated in spirit, in exactly the sessions where the
user had already relaxed their guard. It is enforced twice: `ToolsSchema`
stops after those three tools when the depth is raised, and `RunTool`
refuses everything else at the top. The second is the real one, because the
schema is advice to the model and `RunTool` is the boundary - and it runs
before any `Permit` call, so a standing grant cannot reach past it.

Read-only is also what answers the shared-state question. `uTools` has six
module-level blobs two live agents would share, and the honest answer to
"which must be saved and restored around a subagent" is: none of them. The
todo list, the changed-file list, the bash prefix table and the rewind
snapshots are written only by tools a subagent cannot call, and `BeginTurn`
is host-only, so `/rewind` checkpoints stay keyed to the parent's turn
numbers. `RootDir` is legitimately shared - same session root, same guard.
That is a property a reviewer can verify by reading one three-name
allowlist, where the alternative was trusting six save-and-restore pairs,
one missed restore being a silently corrupted rewind.

Depth caps at one (`MaxSubagentDepth`), in a counter whose Enter/Leave is
balanced in a `finally` so an exception cannot leave the parent permanently
unable to delegate. Two guards, not one: `EnterSubagent` refuses at the cap,
and `task` is absent from the schema a subagent is sent. Rounds cap at
twelve (`SubagentMaxRounds`) rather than the parent's twenty-four - it is
doing one self-contained job and nobody is watching it spend.
`MaxToolRounds` became the default value of a new per-agent `MaxRounds`
property rather than a literal in the loop. The subagent's four token
counters are folded into the parent's whether or not its turn succeeded: a
failed subagent still spent tokens, and a `/cost` that quietly omits them
lies in the one direction the user would mind, discovered only on the
invoice.

Its `OnText`, `OnThinking`, `OnToolArg` and `OnToolUseBegin` stay nil - two
agents streaming prose to one terminal interleaved is unreadable, and the
user did not ask the second one anything. `OnToolStart` and `OnNotice`
forward to the parent's with `-> ` and `subagent: ` prefixes, so there is
one line per step and the wait is visibly alive. The answer arrives through
the ordinary tool-result summary; `pasclaude.lpr` needed no per-tool arm.

Cancellation turned up two real defects rather than polish. `CtrlCPressed`
consumes its flag as it answers, so a subagent polling `ShouldCancel` would
swallow the user's Esc and leave the parent running; a `ForceCancel` latch
in `uAgent`, tested first inside a new `WantsCancel` that replaced all three
poll sites, fixes it, and only a top-level turn clears it, so a subagent's
own `Send` cannot erase the abort it just caused. Second, a cancel landing
inside a tool call lets `RunTools` finish and push its results, so the
transcript ends on a `tool_result` user message the model will never answer
- and `TrimUnansweredQuestion` rightly refuses to drop a `tool_result`, so
the next question would be a second user turn in a row and the API would
reject it. `UnwindCancelledTail` picks the right repair: the full unwind when
the last message is a user turn, `TrimUnansweredQuestion` otherwise, since
with a trailing assistant message the unwind loop never runs and a dangling
`tool_use` would survive. `Send` also checks `WantsCancel` after `RunTools`,
so a latched abort does not send one more request just to abort it
mid-stream.

Named types live in `.pasclaude\agents\<name>.md`, the whole file being the
briefing, mirroring custom slash commands exactly rather than inventing a
second pattern. The parent's system prompt is deliberately not inherited: it
carries the project memory and the "writes need approval" guidance, neither
of which applies to a helper that cannot write and has no user to ask. The
name is filtered for `\ / : .` and control characters, the same rule
`ExpandCustomCommand` uses. That filter carries more weight here - agent
definitions live inside the state directory `SafePath` exists to refuse, so
this is the one place in `uTools` that opens a file without `SafePath`, the
path around the name is constructed, and the filter is the whole of the
guard. It must stay that way deliberately. The contents are UTF-8-validated
and clipped, because they become a system prompt on a nested request where
one bad byte loses the call and surfaces only as a mysterious tool failure.

There is no parallelism, and that is a decision rather than a gap. There is
no threading anywhere in this codebase; `TProcess`, the console hooks,
`HttpTransport` and every `uTools` blob are process-global, and the depth
counter is a plain `Integer`. Concurrency would be a rewrite of the
ownership model for a tool that already returns in seconds. Multiplicity is
free and already works: the model can emit several `task` blocks in one
assistant turn and `RunTools` runs them one after another, each Enter/Leave
balanced.

## Trust

Until this round, nothing in a project directory could make pasclaude run a
program. `CLAUDE.md` was prose, `.pasclaude\commands\` was prose, an agent
definition was prose; the only route to `CreateProcess` was the `bash` tool,
and that route ends at a prompt showing the command. Two of the four features
below change that - `.mcp.json` names programs to spawn, `hooks.json` names
commands to run at fixed points in a turn - so the line those files cross is
worth drawing explicitly rather than leaving a reader to infer it.

The organizing distinction is declarative versus executable. Declarative text
becomes prompt and nothing else: skill bodies, plugin commands, plugin agent
types, `CLAUDE.md`. That is trusted without a prompt, because it grants a
repository author no capability they did not already have through the
instruction files this program has always read unprompted and labelled
binding. A skill that says to run `del /s` produces a `bash` call that lands
on the same prompt it always would. Executable configuration - anything that
reaches `CreateProcess` - is asked about, every time the bytes change.

Both questions go through the same `[y] once [a] always [n] no` prompt the
bash gate uses, and both are shown in full before they are answered: every
hook command verbatim, every server's expanded command line. "Always" records
a fingerprint of exactly what was approved, not a name: the FNV-1a 64 of
`hooks.json`'s bytes, and for a server the hash of its command, its arguments
in order and its `NAME=VALUE` environment overrides sorted. Editing the hooks
file asks again. Repointing an approved server name at a different program
asks again, by name, showing the new program - because the name is a label
the same file controls, so approving the name would approve whatever it is
later made to mean. Environment values are hashed as well as names, since
`NODE_OPTIONS` chooses the program as surely as an argument does.

Those fingerprints live in the approvals file, which is why that file moved
out of the project this round. `%LOCALAPPDATA%\pasclaude\approvals\` is
keyed by the session root's full path; a repository that could ship its own
`permissions.json` would have been answering its own question, pre-approving
its own hooks and its own servers before a prompt appeared. When neither
`%LOCALAPPDATA%` nor `%USERPROFILE%` is set there is no store, and that means
approve-nothing and persist-nothing rather than a fall back into the project,
which would restore the hole.

Three things deliberately do *not* answer these questions. `/yolo` answers the
per-call gate and not the right to spawn: yolo has always meant "stop asking
me about these tools", it is answered before the repository's config is known
to exist, and extending it to launching third-party binaries a cloned
repository chose is a different sentence. That survived the move to bypass
mode for free - bypass is one line inside `Permit`, and neither the server
spawn prompt nor the hooks fingerprint prompt goes through `Permit`. Print
mode is structurally unable to
reach either prompt, and still is: it reads no project config at all, and
would arrive with a nil `Ask` and deny everything if it did - so a scripted run
can never be the thing that first executes a project's code. That is now a
statement about the *project's* files specifically. Print mode does read your
own `mcp.json` and start its servers, which reaches no prompt either, for the
opposite reason: those servers are approved without one in every mode, so there
was never a question for a nil `Ask` to fail to answer. And enabling a plugin
activates its commands, agents and skills and nothing else; a plugin manifest
naming a hook or a server is reported by `/plugins` and never acted on.

What this does not protect against, stated plainly:

* Habituation. A user who answers `a` by reflex is one keystroke from running
  a repository's commands. Showing every command verbatim and re-asking on
  every edit is a mitigation, not a fix, and it is the price of the feature
  existing at all.
* Prompt injection. A server can put instructions in a tool description and a
  skill can put them in its body, and both reach the model. Skill results are
  wrapped in a header naming the skill and its source and a trailer saying the
  text is project-supplied and not an instruction from the user; those lines
  are the only signal separating repository text from the user's own voice,
  and they are load-bearing rather than decorative. For MCP the gate is the
  user having approved the program.
* FNV-1a is a change detector, not a cryptographic digest. It is not
  preimage-resistant, and widening it to 64 bits doubles the work without
  changing that. FPC ships SHA-256 in fcl-hash rather than the RTL, which is
  outside this program's dependency rule. The residual attack needs someone
  who can already get a first server approved and then engineer a second
  config colliding with it.
* `.mcp.json` sits at the project root, so the tools can read *and write* it.
  That is accepted rather than worked around: convention puts it there, it is
  meant to be committed, and config is read once at startup, so a model that
  rewrites it changes nothing that session and the new command line has no
  matching fingerprint at the next launch. `hooks.json` lives under
  `.pasclaude` and is therefore unreachable by the tools. The asymmetry is
  deliberate - hooks have no convention pushing them to the root, so they take
  the stricter placement for free - and should not be "fixed" for symmetry.
  The user's own two files, `%USERPROFILE%\.pasclaude\hooks.json` and
  `%USERPROFILE%\.pasclaude\mcp.json`, sit outside every root, so no clone can
  ship one; and `.pasclaude` is refused at the top level of every root
  including added ones, so `--add-dir %USERPROFILE%` does not make them
  reachable either. That placement, not a prompt, is what makes it safe to
  trust them without asking.

## MCP servers

A project can name programs for pasclaude to run: an `.mcp.json` in the
session root, in the shape the rest of the ecosystem uses.

```json
{"mcpServers": {
  "github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"],
             "env": {"GITHUB_TOKEN": "${GH_TOKEN}"}}
}}
```

You can name your own in `%USERPROFILE%\.pasclaude\mcp.json`, same shape, and
those apply to every project you open. **That file, and only that file, may
also name a URL:**

```json
{"mcpServers": {
  "remote": {"url": "https://mcp.example.com/mcp",
             "headers": {"Authorization": "Bearer ${MY_TOKEN}"}}
}}
```

Stateless Streamable HTTP: one POST per JSON-RPC message, and the answer comes
back as one `application/json` document or as a `text/event-stream`, either of
which is framed into exactly the bytes the pipe path already produces. A
pretty-printed JSON body is compacted first, because a newline inside an object
would otherwise frame one message as several; an SSE payload split across
several `data:` lines is rejoined per the grammar before it is parsed. The URL
faces the same rule as every other URL here - https anywhere, plain http only
when the host is exactly `127.0.0.1` or `localhost` - and it is checked when
the server is opened rather than at first use, so a refusal names the URL
instead of reading as a server that would not talk to us.

**A project's `.mcp.json` may not name a URL, and this is the one place a
project entry is refused where a program would merely have prompted.** The
prompt cannot carry the question. For a program it shows a command line, and
"may this repository run this" is answerable by looking at it. For a URL the
grant is that every argument the model passes to that tool - file contents,
paths, whatever it read on your machine - is posted to a host the *repository*
chose, and no prompt showing a URL asks that in a form anybody can weigh. A
stdio server from a project can at least be read before it runs; a remote one
cannot be read at all. Not softened to a loopback exception either: `127.0.0.1`
in a cloned repository's file is a port on *your* machine that the repository
picked, and "it is only local" is exactly the sentence that makes that sound
safe.

What is refused on the transport itself, by name: a server that requires a
session. The spec lets one hand back an `Mcp-Session-Id` on initialize and
demand it afterwards; this client carries none, so such a server refuses the
first real request and the error says what that most likely means rather than
reporting a bare 400. Half-supporting it - accepting the id and not resending
it - would produce a client that works for one call and then fails in a way
nobody can read. There is also no GET listening stream (a server pushing
notifications needs a reader off the caller's thread, and one thread is what
this program's concurrency arguments rest on), no `Last-Event-Id` resumption,
no WebSocket, and no deprecated two-endpoint HTTP+SSE. And a POST is atomic
from here, so Ctrl+C cannot cut a request already on the wire the way it can on
the pipe path; the deadline is what bounds it.

That file is read *first*, and its
servers skip the per-command-line spawn prompt: the prompt exists because a
repository you cloned chose a program, and this file is you choosing one. It
does not skip the per-call permission - deciding to run a program of your own
is not approving every call the model makes to it, and `/yolo` is still what
answers that. If the project's `.mcp.json` names a server you already have, the
project's is refused and `/mcp` says so by name. That is the opposite of the
nearer-wins rule skills, styles, commands and agents use, on purpose: those
resolve inert text and this one resolves a program to spawn, so under
nearer-wins a repository could call its server `github`, displace yours, and
inherit the model's whole session habit of calling `mcp__github__*` - and the
fresh spawn prompt is no defence, because "may this run" is not the question
that went wrong. Your servers' discovery cache is written to
`%LOCALAPPDATA%\pasclaude\mcp-cache.json` rather than the project's, because
the project cache is a file the project can write and the cache is read back as
tool declarations for a server that is approved by construction.

Their stderr goes out of the project too, to
`%LOCALAPPDATA%\pasclaude\mcp\<name>-<session key>.err`. A server of yours
follows you between projects and so should what it says; before this it wrote
its diagnostics into whichever repository you happened to have open, one
disconnected file per project. Three things make the path unambiguous. Scope
picks the root, so a project `github` and a user `github` cannot name one file.
The name leads, so one listing of that directory shows every project's copy of
your server together. The session key trails, because the spool is opened
`CREATE_ALWAYS`: with one shared file the second *project* would truncate the
first mid-write and the two children would then write over each other at
independent offsets, which is worse than the placement bug it fixed. Project
and not session, despite the name: the key is a pure function of the directory
you opened, so two pasclaude windows on the *same* directory still share one
spool and still collide exactly as they did when the file lived in the project.
Nothing was lost there and nothing was fixed there either; adding a pid would
fix it and would cost the one thing the file is for, which is being findable by
somebody who went looking after the server died.
`%LOCALAPPDATA%` and not the `%USERPROFILE%` the `mcp.json` itself sits in -
that asymmetry is the layout rule below working exactly as intended, since
`mcp.json` is configuration you hand-write and a spool is state this program
writes, keyed by session. A PROJECT server's spool does not move: a program the
repository chose leaves its diagnostics in the repository, where
`.pasclaude\mcp\<name>.err` already is. And nothing creates a directory it is
not about to write, so a session running only your own servers no longer leaves
an empty `.pasclaude\mcp\` behind in somebody else's tree.

Their tools become ordinary tools, named `mcp__<server>__<tool>`. stdio
transport only; an entry carrying a `url`, or a `type` other than stdio, is
listed in `/mcp` as unsupported rather than silently dropped, because a user
who wrote it and saw nothing would conclude the feature is broken. `${VAR}`
and `${VAR:-default}` are expanded before the command line is hashed, so what
the fingerprint covers is what will actually run.

Startup cost is paid once. The first run after approval connects, discovers
and writes `.pasclaude\mcp-cache.json`; every later run declares from the
cache and spawns nothing until the first actual call. That buys a real
divergence - we can advertise a tool the server no longer has - and it is the
right trade, because the failure is one clean tool error that `/mcp refresh`
fixes, where the alternative adds every server's boot time to every prompt.
The tool list is frozen for the session even when a live server says it
changed: the tools array renders ahead of the system prompt under one
`cache_control` breakpoint, so swapping it mid-session throws the whole prompt
cache away on every turn afterwards. `/mcp` says `tools changed` and leaves it.

Everything a server says is treated as data. Tool names are sanitized to the
API's `[A-Za-z0-9_-]` and composed against its 64-character ceiling; when they
will not fit the server segment is truncated, and if even that is not enough
the tool is skipped. Skipping beats mangling - a name we invented cannot be
referenced by the user in an approval and reads to the model as a broken
machine. Schemas are checked for type, depth (16) and size (8 KB) and
*rejected* rather than truncated, because a cut schema does not parse and one
that did would be a lie the model acts on every turn. Descriptions are cut on
a UTF-8 boundary. `annotations`, `title` and `outputSchema` are dropped, per
the spec's own instruction that a client must not trust them: "the user
approved running this program" is not the same statement as "believe what it
says about its own side effects". Every skip is counted and shown in `/mcp`,
because a server contributing three of forty tools while looking correct is
worse than one that looks broken. The declarations share a 32 KB budget across
*all* servers, consumed in configuration order, because that text lands in the
cached prefix and a per-server cap is unbounded in aggregate.

`/mcp` lists every configured server with its scope, status, tool and skip
counts and expanded command line. It names the exact spool file on a server
that is dead or failed to start, which is when the path is the thing you want,
and once at the foot of the panel it names the directory your own servers write
to - a footer rather than a column because that answers the other question, the
one nothing was answering: where a *healthy* server's log went now that it is
not in the project. `/mcp restart <name>` drops a
connection so the next call reconnects; `/mcp refresh` reconnects everything
and rewrites the cache for the next run. Servers do not appear in `/jobs`, are
not killable by `kill_bash`, and survive `/clear`: a running server is a
capability this session has, not something the conversation said.

`src\uMcp.pas` is the transport and knows nothing about approval, naming or
dispatch. The decision worth recording is the one about blocking. A
synchronous read on an empty pipe waits until somebody writes, and an MCP
server is a third-party program that can hang, crash on a bad request, or take
its time. Background bash met the same hazard from the other side and answered
it with a spool file, which works there precisely because nobody is waiting;
here somebody always is, since a tool call cannot return until the server
answers. So every wire wait goes through one function, `McpAwait`, whose loop
is: drain the complete lines already buffered, check the buffer cap, ask the
pipe how many bytes are ready without consuming them, read only that many,
check the deadline. There is no path that reads without first peeking and none
that waits without a deadline, which makes "a hung server can never hang
pasclaude" one function's postcondition rather than a discipline spread over
four call sites. A deadline that expires kills the connection rather than
abandoning it: a server that ignored one request has no credibility for the
next, and one left running still owns its stderr file.

Polling on the caller's thread, rather than a reader thread or overlapped I/O,
is a correctness argument and not a style one. Every mutable thing above this
unit is an unguarded module global, and the subagent design reasons explicitly
from "the tools a subagent may call touch no module state"; a reader thread
would invalidate that argument for the whole program to save a five-millisecond
sleep. The write side has the same shape for the same reason - a `WriteFile`
to a server that has stopped draining its stdin is the one wait a read deadline
cannot cover, so the stdin handle is set `PIPE_NOWAIT` at spawn and the send
loop carries its own deadline and liveness check.

Three bounds keep a misbehaving server from doing damage. A request over
256 KB is refused locally without touching the pipe. A line over 1 MB with no
newline kills the connection, because a server streaming an unterminated line
is indistinguishable from one that has hung. A tool result is capped at 64 KB
with `uJson.Utf8Cut` and a note saying it was cut. Junk on stdout is discarded
rather than fatal - the spec forbids it, but a client that dies on a stray line
hands a broken server the power to end the session - and an unsolicited request
from the server gets a `-32601` reply so it is not left waiting. No shell is
interposed on the command line: a shell would change the quoting the caller
decided on, swallow the exit code, and sit between us and the pipes so that
closing stdin no longer reaches the server.

## Extending the tool list

The twelve built-in tools are still twelve straight-line literals. Anything
else that wants to contribute tools registers a *source*: a name prefix
matching `^[a-z][a-z0-9_]*__$` and two procedures, one that declares and one
that runs. MCP registers `mcp__`. The double underscore is the whole trick -
no built-in name contains one and none ever may, so a source cannot shadow
`read_file`, and the rule does not need revisiting when a thirteenth built-in
lands. Overlapping prefixes are refused at registration, so at most one source
matches a name and dispatch does not depend on the order things registered in.

Sources are declared last, below the cut that ends a subagent's tool list.
That cut is an `Exit`, so a subagent is never told about a source's tools no
matter who adds the next one - and `RunTool`'s read-only boundary refuses the
call anyway, since nothing a source contributes is on the three-name
allowlist. The dispatcher catches exceptions from a source's handler. That is
not defensive habit: the tool loop above does not catch, so an exception
escaping there would skip the `tool_result` the API requires and leave a
transcript that cannot be sent.

## Hooks

`.pasclaude\hooks.json` runs commands of your choosing at five points in a
turn: before a tool runs, after it runs, when you submit a prompt, when the
model finishes, and once when the session starts. A hook is a command line
and, for the two tool events, an optional regular expression matched against
the tool name.

```json
{"hooks":{
  "PreToolUse":[{"matcher":"^(write_file|edit_file)$",
                 "command":"python .pasclaude\\hooks\\fmt.py","timeout_ms":5000}],
  "Stop":[{"command":"build.cmd"}]}}
```

A hook is handed one UTF-8 JSON object on stdin - always `hook_event_name` and
`session_root`, plus `tool_name`/`tool_input`, `tool_result`/`is_error`,
`prompt` or `stop_hook_active` depending on the event. It answers with its exit
code: 0 proceeds, 2 blocks, and anything else means the hook *failed*, which is
never a block. On exit 0 a JSON object on stdout is honoured -
`{"decision":"allow"|"deny","reason":...,"context":...}` - and anything else is
treated as plain context appended to the result, the prompt or the system
prompt.

That "anything else is a failure" rule is the one worth explaining, because the
obvious rule is wrong. A nonexistent program exits 1 through cmd.exe; under
"any nonzero blocks", one mistyped hook command would silently deny every tool
call in the project with no way to find out why. A timeout is treated
identically, for the same reason.

What blocking means, per event: `PreToolUse` - the tool does not run and the
hook's text comes back as the tool's error result; `PostToolUse` - the tool
already ran, so its output is kept, the hook's objection appended and the whole
thing marked as an error; `UserPromptSubmit` - the turn is abandoned before
anything reaches the transcript; `Stop` - one more turn runs with the hook's
text as the prompt, exactly once per user turn; `SessionStart` - pasclaude
prints the reason and exits.

Stdin is a file, not a pipe. `uTools` already records why anonymous pipes were
rejected for detached children; a hook makes pasclaude the writer, and with one
thread there is nobody to drain. Measured: 200 KB to a child that never reads
it completes at once through a file handle and deadlocks at the buffer size
through a pipe. The deadlock is made impossible rather than unlikely. A
`tool_input` over 64 KB is replaced wholesale with `{"_omitted":"N bytes"}`
rather than truncated, because half a JSON value is not JSON and a hook that
cannot parse its own stdin is worse off than one told plainly.

A block returns the same `(text, is_error)` pair a permission denial already
returns, which is why the conversation loop needed no change at all: "blocking
leaves a legal transcript" is true by construction. A hook's `allow` decision
is read once and is checked *after* the nil-`Ask` test in `Permit`, so it can
turn a question into a yes and can never turn a refusal into one - print mode
and subagents both arrive there with a nil `Ask` and are unaffected. Matchers
are the same bounded NFA the `search` tool uses, so a pattern from an untrusted
file cannot hang the session; one that will not compile disables its hook with
a note at startup rather than a surprise mid-tool-call. Unknown event names are
named in the notes rather than ignored, so a Claude Code config pasted in tells
you which half of itself pasclaude will not fire - including that product's
nested `{"matcher":...,"hooks":[...]}` entry shape, which is detected and
reported rather than supported, because two accepted shapes is two parsers and
twice the surface to fuzz.

Hooks come from two files and the trust between them is deliberately
asymmetric. `%USERPROFILE%\.pasclaude\hooks.json` is yours: it is loaded
without a fingerprint and without a prompt, because prompting somebody about a
file only they can write is noise that teaches them to answer yes, and every
yes it trains is spent later on the project prompt that matters. The project's
`.pasclaude\hooks.json` keeps its prompt exactly as it was. Your file loads
first, so for every event your hooks fire before the project's - and since the
first block wins and stops the list, that order is the rule and not a detail: a
project file that fired first could pre-empt your own audit hook. A project
file can never remove, disable or shadow one of yours; there is no key that
removes a hook, and the eight-per-event ceiling counts what is already loaded,
so a project file listing nine `PreToolUse` entries crowds out its own
overflow. Running pasclaude in `%USERPROFILE%` makes the two paths one file: it
is loaded once, as yours, with nothing asked about it, and `/hooks` names it
once rather than listing it as loaded and then again as absent. Whether the two
are one file is decided against the spelling Windows resolves each directory
to, not against the text of the paths: comparing the typed strings meant a
junction, a `SUBST` drive or an 8.3 short name reaching your home directory by
a second name loaded that one file twice, fired every hook in it twice, and
asked you to trust a file of your own - reproduced with a junction before it
was fixed, not a worry about one.

`/hooks` shows both files, whether hooks are running, the project fingerprint
and one line per hook with its scope. `/hooks off` turns off *both* for the
session, which it says out loud - a switch that left some hooks running would
be a lie.

**Hooks are an interactive-only feature**, and that is a flag rather than an
accident of where a branch halts. `uHooks.HooksAllowed` ships false; the host
sets it true only when the run is neither `-p` nor one of `--status`,
`--doctor`, `--ci prepare` and `--ci report`. `LoadHooks` exits on it, so an
unattended run does not even parse the file, and `HooksEnabled` re-reads it,
so clearing it mid-run stops all six firing sites at once. The reason it had
to be a flag: the trust prompt sits above the `-p` halt but far above
`RunCi`, so both `--ci` verbs and both diagnostic modes were reaching
`TrustHooks` - where an empty line reads as allow and a non-console stdin
gives one. `--ci report` runs after `actions/checkout`, in a working
directory whose `.pasclaude\hooks.json` came from the pull request head. The
narrowing is real and is stated rather than hidden: `--doctor` no longer
loads or fires hooks, and reports `hooks.json is present but not enabled for
this session` instead. Note also that the CI deny floor cannot cover a hook
at all - `uHooks` sits below `uTools`, so no hook command is ever matched
against a rule - which is why the answer here is structural and not a rule.
The user-scope file changes none of this. `HooksAllowed` is checked *first and
alone* in `LoadHooks`, ahead of the project's trust answer, so it governs both
scopes: an unattended run parses neither file. A user-scope hook is not an
exemption from that byte, and making it one would turn the flag back into a
condition somebody has to remember.

## Skills and plugins

A skill is a directory under `.pasclaude\skills\` holding a `SKILL.md`: a small
frontmatter block naming it and describing when it applies, then a body of
instructions. Only the name and the description are ever advertised; the body
arrives when the model calls the `skill` tool by name. That is the whole idea -
a project can write down a dozen procedures and pay one line per procedure per
turn instead of a dozen documents. The catalogue is discovered from disk on
each refresh: this project's own skills, then each enabled plugin's
alphabetically, then the user's own in `%USERPROFILE%\.pasclaude\skills\`.
Nearer wins, the rule the instruction files already use.

The catalogue lives in the `skill` tool's own description rather than in the
system prompt. The system prompt is fixed when the agent is constructed and has
no setter, so a catalogue there could never change during a session; the tool
schema is rebuilt fresh on every request, and both sit inside the same single
`cache_control` breakpoint, so the token cost is byte-identical and a skill
dropped in after `/skills` is live on the next turn. That placement is now
load-bearing for a security argument as well as a caching one - it is why the
`--ci` gate on the instruction files does not have to cover skills, and a ux
check pins it. `/skills` prints the
catalogue and doubles as the rescan, because re-reading up to thirty-two files
per request would cost more than a stale list does.

The frontmatter reader takes a stated subset and refuses everything else with a
line number: a `---` fence, flat `key: value` lines, optionally quoted scalars
with no escape interpretation, `#` comments, blank lines. Block scalars,
sequences, indentation, flow collections, anchors and aliases are errors naming
the construct and the line. Unknown flat keys parse and are ignored, so a file
carrying `allowed-tools` or `license` still loads. This is small on purpose: a
half-implemented YAML parser mis-reads a description silently, and a
description read wrong is a skill that never triggers with nothing anywhere
saying why. A skill whose file fails to parse is listed by `/skills` with its
error rather than vanishing, for the same reason.

The `skill` tool is not gated. It reads a file the user put in their own
project, which is `read_file`'s trust class, and what comes back is text of the
same class as `CLAUDE.md`. It grants no capability. The header and trailer
described under Trust replace the gate that would have been theatre.

A plugin is a directory under `.pasclaude\plugins\` carrying a `plugin.json`
and any of `commands\`, `agents\`, `skills\`. It contributes into those three
namespaces through the same loaders an ordinary custom command or agent type
uses; it creates no parallel universe. A plugin dropped in is inert until
`/plugins enable <name>`. That consent is a typed name rather than a y/a/n
prompt deliberately: a launch-time prompt is answered by muscle memory before
anything has been read, while typing a plugin's name means the user went and
looked. Enablement lives in `.pasclaude\plugins.json`, which - unlike the
approvals file - is authoritative in *both* directions, because a disable that
did not survive a restart would be a consent bug the user could never diagnose.
Both files say so in comment. Collisions resolve nearest-first and the source
is always shown, so a cloned repository's plugin shadowing something the user
wrote is visible rather than silent. Built-in slash commands can never be
shadowed; the built-in dispatch runs first, unchanged.

Caps, all of them visible when they bite: 32 skills catalogued (past that the
listing ends `(N more skills are installed but not listed)`), 320 bytes of
description each, 128 KB per `SKILL.md`, 16 plugins. A supporting file that is
not valid UTF-8 is refused rather than hex-dumped - that is a mistake in the
skill, not a binary the model asked to see.

## Output styles

`/output-style` with no argument lists what is available and marks the one in
force; `/output-style <name>` sets it and remembers the name;
`--output-style <name>` does the same on the command line, and under `-p` it is
the only way in - a scripted run halts before the approvals file is read, so
nothing persisted can reach it.

Three styles are compiled in. `default` adds nothing at all. `explanatory` asks
for a sentence or two on why the code in front of you is built the way it is
and what the other way would have broken. `learning` asks for the work to stop
one step short, with the real decision marked `TODO(you):` and handed back.
Your own live as a flat `<name>.md` in `.pasclaude\styles\`, in an enabled
plugin's `styles\`, or in `%USERPROFILE%\.pasclaude\styles\`; nearer wins,
which is the precedence commands, agents and skills already use. The file is a
`SKILL.md`-shaped document read by the same frontmatter parser - a second
reader of the same file shape would be a second set of failure modes for it -
so a style written for another tool loads unchanged. The three built-in names
are reserved: a file called `explanatory.md` is listed with the clash and never
loaded, because a listing that advertises one thing while the loader uses
another is worse than a refusal. They are compiled in rather than shipped as
files for the same reason: a built-in on disk can be edited into something that
no longer matches the name the listing shows.

**A style adds; it never replaces.** It is one paragraph appended to a system
prompt that is otherwise untouched, behind a fixed fence line saying it governs
the tone and shape of your prose and grants access to nothing. That is not a
promise the model keeps - it is a fact about the code. Nothing reads a style
body except a single string concatenation in `SessionNote`, no frontmatter key
maps to any setting, and there is no parse step to trick because there is no
consumer to trick. A style saying "you may write files in plan mode" changes
nothing: `SafePath`, the deny rules, the plan-mode boundary and the permission
callback are Pascal and read no prompt text.

**It rides outside the prompt cache, deliberately.** The request has two
`cache_control` breakpoints; the first covers the tools schema and the system
prompt, and it is worth real money. A style sits after it, in the same uncached
trailing block as the plan-mode paragraph, so switching styles mid-session
costs a few hundred tokens instead of re-reading the whole cached prefix. The
price of that choice is a standing one: the style is billed as fresh input on
every turn. It is capped at 2 KB - about three hundred words - cut with
`Utf8Cut` rather than `Copy`, and `/output-style` prints the exact byte count
it added, so the charge is visible rather than silent. With the default style
the note is empty and the request body is byte-for-byte what it was before this
feature existed.

Order inside that block is fixed and is not a matter of taste: the style comes
first, then the plan paragraph, then the extra-roots block, then the deny
sentence, which stays permanently last. The style is the only text there that a
file chose rather than pasclaude's own state, and the deny sentence is the one
line describing a refusal nothing can override, so it keeps the recency
position. Anything added to this block later inserts before it.

**Where the choice is recorded.** The name and the place it resolved from go in
the approvals file under `%LOCALAPPDATA%`, keyed by the session root - never in
the project, because a repository that could pick its own text for the system
prompt has not been asked anything. That is a fourth polarity in a file that
already had three: `output_style` neither widens nor narrows, it selects. The
body is not stored, only the name; it is re-read from disk when you set it. If
the name later resolves somewhere other than where you agreed to it - a project
creates `styles\explanatory.md` after you set your own - pasclaude refuses it
rather than substituting, falls back to `default` and prints both sources in
yellow. Re-run `/output-style <name>` to consent to the new source.

Edit a style file and it applies by itself, from the next turn. The body is
still cached rather than re-read per request - `SessionNote` runs while a
request body is being built, and putting a file read, a UTF-8 repair and a
frontmatter parse there would put the parse FAILURE there too, so a file caught
half-written by an editor would decide the style for a request already in
flight. Instead `StyleNote` fingerprints the file it read - the size the
directory reports and FNV-1a 64 over its bytes - and re-parses only when that
fingerprint moved: on the ordinary turn nothing changed, the cached paragraph
goes out byte-identical, and the read that produced the fingerprint is one open
of a file capped at 64 KB. Over the bytes *inside that cap*, precisely: the
hash sees the same first 64 KB the parser does, so a body can never depend on a
byte the fingerprint missed, and a change past the cap that also moves the
length is caught by the size sitting beside the hash. Raising the read cap
without raising the hash cap would open a real blind spot, which is why the
source says so where the two meet. The read is on the request path and the parse is
not, which is the half of the caching that was ever load-bearing. A built-in
style has no file and never touches the disk at all.

The check used to compare the DOS timestamp `FindFirst` reports beside the
size, and two-second granularity made an edit that landed inside one tick and
left the file exactly the same length invisible. A real `FILETIME` through
`GetFileAttributesExW` was the obvious replacement and was rejected: NTFS
stores 100-nanosecond ticks but nothing writes 100-nanosecond values into
them - Windows stamps a write from the cached system time, whose tick is about
15 milliseconds, so two saves inside one tick share a last-write time to the
digit. That shrinks the blind window and makes what is left flaky rather than
documented. The bytes are the only thing that cannot be identical while the
content differs.

One residual, deliberate. A file that has become unreadable, unparseable or
deleted does NOT empty the style: what was working stays in force, and a yellow
line before the next prompt says which file and why, once, rather than once a
turn.

## Adding to the system prompt

`--append-system-prompt "<text>"` puts your own paragraph into the system
prompt for this run. It ADDS and can never replace: the guidelines, the session
root, this project's `CLAUDE.md` and everything they `@import` are all still
assembled above it, exactly as they were. It goes LAST, after the project's own
instructions, and that order is the argument for the flag - everything above it
was written by whoever last committed to the tree, and a standing instruction
typed at the keyboard should not lose the recency position to a file out of a
clone. The model is told where it came from: the paragraph is introduced as
`Additional instructions, given on this run's command line:`.

Give the flag more than once and the values accumulate in the order they were
given, a blank line apart - "append" read literally, because the alternative
silently discards text you typed. The total is capped at 4096 bytes and the run
STOPS past that rather than sending half of it: a standing rule the model
received part of is worse than one it never received. The banner names the byte
count, because text in the most trusted position of every request should not be
invisible.

There is deliberately no `settings.json` key and no approvals-file key for
this. A project file that could append to the system prompt is a project file
that can rewrite the agent's standing instructions from inside a clone - the
same risk `.mcp.json` and `hooks.json` are gated for, except that those two
announce themselves and can be trusted per tree, where a system-prompt line
would be invisible in every reply it shaped. Command line only means the person
who typed it was at the keyboard. Something long belongs in `CLAUDE.md`, where
`/memory` can show it back to you.

## Images

`@shot.png` in a prompt attaches the image; `/paste` takes one off the Windows
clipboard, and `/paste drop` cancels it before you send. Both print what you
are about to spend - dimensions, bytes, and the token cost - because an image
is expensive and, unlike prose, you cannot skim it back later in the
transcript. The figure is the API's own patch formula, `ceil(w/28) x
ceil(h/28)` after the model's downscale, so a 1080p screenshot reports 2691
tokens and a 4K one 4784.

The clipboard needed an encoder. Windows offers CF_DIB - raw pixels - and the
API takes png, jpeg, gif and webp but not BMP. FPC's paszlib is a package, not
the RTL, so it is off limits here; the way through is that a zlib stream may
legally be made of *stored* deflate blocks, which need only CRC-32 and
Adler-32. That was verified with a compiled probe before any of it was designed
around: Windows Imaging Component decoded the result and Python's zlib inflated
it with every chunk CRC validating. The price is that such a PNG is about the
size of its raw pixels, which is why `uImage` writes a palette when an image
has 256 colours or fewer - a terminal or dialog screenshot almost always does,
and that is the difference between a paste fitting in the 2 MB budget and not.
Past that it halves and retries, at most twice, then refuses and names the
size. A quarter-scale screenshot is still readable; a sixteenth is not, and an
honest refusal beats an image you cannot check.

Files you mention are never re-encoded - they are already compressed properly -
so they go up untouched under a 5 MB cap, and a JPEG cannot be resized without
a decoder anyway, which is what makes an oversize file a refusal rather than a
shrink. Eight images per message: the API allows more, but past twenty blocks
it imposes a stricter per-image dimension rule, and eight keeps a turn clear of
it. `uImage` is a leaf beside `uJson` - `SysUtils` only, no Win32, no console,
no JSON - so the awkward cases (a bottom-up DIB, a truncated header, a header
claiming 40000x40000) are testable without a clipboard.

A copied *file* goes through `ResolveInRoot`, which is `SafePath`, the same
resolver `@`-mentions, `read_file` and `@import` use. `/paste` of a file
outside the session root, inside `.pasclaude\`, or under a deny rule is refused
by the same message it would get as a tool argument; copying the *image* rather
than the file is unaffected, and `--add-dir` widens both alike.

### What a message holds now

A message content array can carry an `image` block, and one shape covers every
part of the program:

```json
{"type":"image","source":{"type":"base64","media_type":"image/png","data":"..."}}
```

Base64 sources only. A `url` source would have the API fetch a host nobody
here can vet, and the Files API needs a beta header and an upload round trip.
Images appear only in `user` messages, only where your own `@mention`,
`/paste`, or a stream-json driver's own message put them; a `tool_result` may
not carry one, and `RunTool` still returns a `string`. That is a prohibition
rather than a scoping choice - three units would have to move in lockstep, and
a tool result has no human in the loop to see what arrived.

`TBlockKind` gained nothing and the streaming decoder was not touched. The
model does not emit image blocks; if the API ever does, the existing `bkResult`
passthrough already captures it whole and replays it verbatim, which is the
correct behaviour and must not be "improved" into a typed kind.

Two local keys, `width` and `height`, live beside the block in `FMessages` so a
resumed session can print `[image 1920x1080 image/png]` without decoding a
megabyte of base64. They are stripped from the copy that goes on the wire,
beside the existing `cache_control` fixup, because the Messages API validates
content blocks strictly and rejects a key it does not know. The transcript
keeps our concerns and the transport keeps the API's.

`ValidTranscript` was not modified and `SessionVersion` is still 1: its only
type-sensitive rule is that a `tool_use` needs a matching `tool_result`, and an
image block satisfies everything else by being an object with a non-empty
`type`. So image sessions round-trip today, and nobody may add a block-type
allowlist - it would make already-saved sessions unloadable, which under `-p`
is a hard exit 2.

**What images cost you over time.** Base64 is re-sent in full on every turn, so
one screenshot puts the transcript permanently over the compaction threshold,
and `TranscriptBytes` counts it honestly because that is the real cost of the
next request. The byte trim cannot help by itself, because the image sits in
the tail it is trying to keep. So the trigger block first calls
`EvictImages(2)`: it walks the transcript oldest-first and replaces all but the
two newest image blocks with `[image removed to save context: 1920x1080
image/png]`. It substitutes rather than deletes - an emptied content array is
exactly what the session loader rejects, and a measure meant to save context
must not leave you with a session that will not load. Two survive because that
is the image you are discussing plus one for a before/after pair. Eviction
rewrites memory only; a file already saved keeps the bytes until it is
overwritten.

An image can also be consumed by a turn that never happened. `AppendUserText`
drains the pending queue into the message before the request goes out, and both
tail repairs - the failed-turn unwind and the unanswered-question trim - drop
that message. `RequeueImagesFrom` reads the base64 blocks back onto the queue
at both sites and says so in a notice; silence was the real damage, since you
had already been told the image goes with your next message.

**What an image can do that text cannot.** It can carry instructions painted
into its pixels that a person reading the transcript will never see - the
transcript shows only `[image 1920x1080 image/png]`. Nothing here detects that
and nothing can. What bounds it is the same instinct as the permission system:
an image gets in only by your own `@mention` or `/paste`, both root-guarded by
the check a tool call goes through, and it lands in a user block, so it carries
the authority of text you typed and no more. It cannot answer a permission
prompt: those are read from the real keyboard, and the model has no channel to
it. Note also that a saved session keeps the image on disk in plaintext under
`.pasclaude\`.

**Not done:** `read_file` on an image still returns its hex dump - a tool
result has no human in the loop, and `uNotebook` and `uMcp` already refuse to
sail base64 into context unexamined - tool results cannot carry images at all,
and only base64 sources are used. Print mode's plain `-p` never expands
`@mentions`, so an image cannot be attached that way; a `--input-format
stream-json` driver can send image blocks in its own `user` message, under the
same caps and the same four media types.

## The screen

Three pieces of chrome, all drawn by `uTerm` and all amber.

**The banner** is a rounded two-column frame. On the left is what this session
*is* - who it greets, the model and how it authenticates, the session root and
any added ones. On the right is what to type. The split is not decoration: the
left column is the half a user checks and the right is the half they learn once
and stop reading, so side by side means the half that goes stale never pushes
the half that stays useful off the screen.

What the frame deliberately does *not* hold is the warnings. A permission mode
that is not plain ask, a deny set in force, a sandbox below the default - those
go **underneath** it, unboxed. A box is exactly the shape an eye learns to skip,
and those are the three lines that must not be skipped. Under 64 columns the
frame is dropped for a single stacked column: two columns in forty columns is
two columns of ellipses.

**The prompt block** is a rule, the text, a rule, and the status lines under it.
The text word-wraps and the block grows downward, which means every repaint
paints rows *below* the caret and then walks back up to it - so the block exists
only where VT escapes do. A console that refuses VT gets the single-line editor
this program has always had, and so does every prompt that is not the REPL: the
permission question, the model picker, the session picker and the rewind picker
all read through `ReadLineEdit`, which never frames. A question wrapped in a
status bar is a question that gets skimmed.

Each repaint is assembled and written **once**. Six rows painted run by run is
thirty console calls per keystroke, which a user experiences as a prompt that
stutters while they type.

**The status line** says, in order: the model and where you are, the meters, what
was loaded, and the permission mode. Every field has a "say nothing" value, and
a field that says nothing takes no column - a session with no git, no MCP
servers and no memory file gets a shorter line, not a line of zeroes. The mode
is last because it is the line a narrow window must keep, and it is omitted
entirely for plain ask, on the same reasoning the prompt has always followed:
an indicator that is always on is not an indicator.

```
────────────────────────────────────────────────────────────────
❯ what shall we build
────────────────────────────────────────────────────────────────
[claude-opus-5] │ pasclaude git:(feat/config-diagnostics)
Context ███░░░░░░░░░ 12% (18.4k) │ Session 121.5k in 8.4k out
1 CLAUDE.md │ 3 MCPs │ 16 hooks
▸▸ bypass  (/mode to change)
```

The context meter fills towards the point *this program compacts at*, not the
model's context window: compaction is what you will actually experience, so it
is the number worth watching. A non-zero percentage always lights at least one
cell - a meter that reads empty at 1% is a meter that does not appear to work.

The branch comes out of `.git\HEAD`, not out of `git`. A subprocess per turn
would be affordable; the status is refreshed once per turn and never per
keystroke, but reading a file is the same answer for none of the cost, and it
handles the three shapes `.git` comes in (a directory, a worktree's pointer
file, and a detached HEAD, which is shown as the short commit).

**The palette.** Four amber tones - `clAmberLt`, `clAmber`, `clAmberDim`,
`clAmberDk` - go out as 24-bit escapes on a VT console. A sixteen-colour palette
has exactly one amber, so on a legacy console the two bright ends collapse onto
intense yellow and the two dark ones onto the dim pair that reads as structure
rather than text. The banner loses its shading and keeps its shape.

**How the rows are built.** A row is one string with zero-width colour marks in
it (`#1` plus a letter), not a run of coloured writes. That is what makes a row
*measurable*: `UiWidth` counts columns rather than bytes - `─` is three bytes and
one column, and a frame padded by `Length()` is a frame with a ragged edge -
`UiFit` truncates to a width while copying the marks through, and `UiPaint`
colours it. Dropping the marks on a cut would leak the last colour onto
everything painted after it, which is how one long path turns the rest of a
screen amber. `#1` is safe as the sentinel because nothing a user types or a
model returns contains it.

`uTerm` sits at the bottom of the unit ladder and cannot ask `uAgent` for a
token count or `uTools` for the permission mode, so the status facts are
**pushed** into it as a plain record before each read rather than pulled out of
it. That inversion is what keeps the console unit free of the program's state,
and it is why the composer is a pure function of a record that the suite drives
without a console: `StatusLines` at every width from 12 to 140, `UiBoxTop`,
`UiBoxRow` and `UiBoxBottom` asserted to be the same number of columns for both
glyph sets and for content far too long for its column, and `PromptRows`
asserted to lose no character and to leave the caret where the eye is.

## Editing the prompt

The line editor has always had arrows, Home/End and Ctrl+A/E/U. It now also has
the readline verbs it was missing - Ctrl+W deletes the word to the left, Ctrl+K
to the end of the line, Alt+B and Alt+F move by words, Ctrl+Z undoes - and both
halves of those are rebindable.

`/vim` turns on a modal editor. A line always starts in insert mode, so
forgetting the setting is on costs nothing; Esc (or Ctrl+[) enters normal mode
and the prompt says which one you are in, `[I]` or `[N]`, in front of whatever
the permission mode already puts there. In the framed block described under
**The screen** the permission mode has moved to the status line, so the tag is
all that stands in front of the mark - but it is still there, and in both its
states. Both tags are four columns wide, so the text does not shift sideways
when you press Esc. Normal mode has `h l w b e 0 ^ $` for
motion, `j` and `k` for history - a prompt is one line, so those are worth more
as history than as motion - `i a I A` to insert, `x D C S` and the `d` and `c`
compounds (`dw db de d0 d$ dd`, and the same with `c`) to edit, and `u` and
Ctrl+R for undo and redo. A whole insert session undoes in one step rather than
one character at a time.

What vim mode is not: no visual mode, no registers and no put, no counts, no
`.` repeat, no marks, no macros, no `:` commands, no search, no text objects,
no `r`/`R`/`s`, no `o`/`O`, no `gg`/`G`, no `%`. Most of those exist to move
around a buffer, and there is no buffer here. Two things do get worse when you
turn it on, and `/vim on` says so: Esc stops clearing the line (Ctrl+U still
does), and a paste that arrives while you are in normal mode is read as
commands. Esc-Esc for `/rewind` is off with vim on for the same reason - two
presses mean "definitely normal mode" to fingers older than this program.
`/vim save` keeps the setting; `/keys` prints the current table.

**Rebinding.** `%USERPROFILE%\.pasclaude\keys.json`:

```json
{"vim": true, "bindings": {"ctrl+w": "delete-word-left",
                           "alt+d": "delete-word-right",
                           "ctrl+k": "none"}}
```

An action is one of a closed list of editor verbs, `none` unbinds, and anything
the file gets wrong is printed at startup naming the entry - an unknown action
or an unparsable key is never silently dropped, and a refused entry leaves the
built-in binding standing. A missing or broken file is the built-in bindings
and a working session.

**Why that file is not in your project directory.** Everything else under
`.pasclaude\` describes the project and arrives with a `git clone`. Keybindings
decide what your keyboard does, and a repository that could ship them would be
choosing that for you before you had read a line. So keys.json is read from
`%USERPROFILE%` only, the same place the user-level `CLAUDE.md` lives - this is
configuration you write by hand, not state the program keeps, which is what
`%LOCALAPPDATA%` is for.

### The key-dispatch boundary

The approval question is read with the keyboard, so "configuration can reach
the line editor and nothing else" has to be a property of the code rather than
a convention. It is written down here because it is the invariant a maintainer
is most likely to break without noticing: every one of the changes that would
break it looks like tidying.

Three separate things stop a rebound key answering a permission prompt, and any
one of them would be enough.

**The shape.** `ReadLineCore(Prompt, P: TKeyProfile, Line)` is
implementation-only and takes the profile as a required parameter; there is no
module-var read inside it. Two interface wrappers supply one:
`ReadPromptLine` passes `PromptProfile`, and `ReadLineEdit` passes the constant
`KeysNone`. `ReadLineEdit` kept its exact old signature, so the default action
for any prompt added later - calling the function that already exists - is the
safe one. The permission prompt, `/model`, `/sessions` and `/rewind` all go
through it, and under `KeysNone` `Vim` is false, so normal mode cannot exist
there and `a` is always the character `a`.

**The grammar.** `KeyChordOf` cannot construct a chord for an unmodified
character. A bindable chord is `[ctrl+][alt+][shift+]base` where base is a
named non-character key, or a letter or digit that must carry ctrl or alt. `y`,
`a` and `n` have no spelling at all. `enter`, `tab`, `escape`, `ctrl+c`,
`ctrl+enter` and `alt+enter` do parse and are then refused by name as reserved.

**The action set.** Bindings map onto `TEditKey` and nothing else. No action
submits a line, cancels, answers a question, emits text or runs anything -
`KeyActionName(ekChar)` returns `''`, so the one verb that produces text cannot
even be named in the file. The worst a fully hostile keys.json achieves is
annoying editing, recoverable with Ctrl+U.

Matching is on virtual-key code plus modifier flags, never on the synthesised
control character, which dissolves the "Ctrl arrives two ways" problem: Ctrl+W
is VK $57 with `LEFT_CTRL_PRESSED` whatever `UnicodeChar` holds. The literal
control-character chain stays as a fixed fallback inside `ReadLineCore`,
outside the binding table.

The audit is one grep, and it is written in `uTerm`'s interface beside the
declarations:

```
grep -n "ReadPromptLine\|PromptProfile\|KeysNone" src/*.pas src/*.lpr
```

`ReadPromptLine` - one declaration, one body, one call, the REPL.
`PromptProfile` - one declaration, one body, one setter, and exactly one read
in a reader, `ReadPromptLine`'s argument expression. `KeysNone` - one
declaration, one body, one use in `ReadLineEdit`. A second `ReadPromptLine`
call site, or a read of `PromptProfile` inside `ReadLineCore`, is the defect.

None of this reaches the model. There is no change to the request body, to the
system prompt, or to either cache breakpoint: the body a conversation produces
is the same string with vim on or off, and a smoke test asserts it. Telling the
model you pressed `dw` would cost tokens on every turn to say something it
cannot act on.

## Driving pasclaude from another program

`-p` answers a single prompt, and two flags change what that answer looks like
on the wire. `--output-format json` prints one JSON object and nothing else:
the finished result of the turn. `--output-format stream-json` prints one JSON
object per line as the turn happens - the tools it called, the text as it
streamed, and finally the result. `--input-format stream-json` turns stdin into
the other half of the conversation, so a driver can ask a second question
without starting a second process, and can answer the permission questions the
user would otherwise have answered.

Both flags need `-p`, and `--input-format stream-json` needs
`--output-format stream-json`, because a driver that can speak has to be able
to listen. `-p` takes the next argument as its prompt only when that argument
does not begin with `-`, so the flags may go on either side of it.

The message types: `system` (subtype `init`, emitted once, carrying the session
id, cwd, any additional working directories, model, permission mode and the
full inventory of tools, agents, commands, MCP servers and skills), `user`
(the prompt echoed back),
`assistant_delta` (`delta.type` is `text` or `thinking`), `tool_use` (id, name,
and the input as a parsed object), `tool_result` (tool_use_id, name, content,
is_error), `notice`, `hook`, `permission_request`, `error`, and `result`.
Exactly one `result` per turn is the contract and the process never exits
without one, so a driver knows the run is over when it sees the result line and
then stdout closes.

`hook` is `{"type":"hook","event":"PreToolUse","tool_name":"write_file",
"detail":"...","blocked":true}` and is emitted once per fire that actually ran
a child - never for the empty fire that happens around every tool call when no
matcher matched, or a driver counting hooks would be counting tools. `blocked`
is the field it exists for: a hook that ran and let the call through and a hook
that refused it both end up in the same `tool_result`, one as content and one
as an error, so a driver that wanted to log refusals had to infer which from a
string. The detail is the hook's own output, repaired to UTF-8 and cut to
16 KB with `[hook detail truncated]` when the hooks of one event together
printed more than that; control bytes are escaped by the encoder, so a hook
that prints ten lines still occupies exactly one line of the protocol. Only
`stream-json` gets it - `json` is one object for the whole run, and the text
REPL already shows a hook's words in the tool result and its failures as
notices, so it gains nothing.

The honest caveat: **pasclaude's own `-p` never fires a hook**, because hooks
are interactive-only and every SDK format needs `-p`, `--status` or `--doctor`
(see *Hooks* below). The seam is armed under `stream-json` and there is
nothing in the shipped CLI to report through it; a program that embeds `uSdk`,
drives `SdkRun` in process and sets `uHooks.HooksAllowed` itself is the caller
that sees the event today.

The permission exchange is the part worth an example. pasclaude emits

```json
{"type":"permission_request","id":"perm_1","tool_name":"write_file",
 "title":"write_file","detail":"...diff..."}
```

and blocks on exactly one line of stdin. The driver replies

```json
{"type":"permission_response","id":"perm_1","behavior":"allow"}
```

where behavior is `allow`, `allow_always` or `deny`. Everything else denies: an
unknown verb, a mismatched id, a line that is not JSON, a message that is not a
`permission_response`, and end of stream. That is the same rule the console
prompt follows when its own read fails, and there is no default-allow branch
anywhere in the parser.

A driver is a permission answerer and nothing more. The protocol has no
message that sets a mode, adds a working directory, edits a deny rule or
changes the sandbox level; the working directories and the mode name appear in
the `init` event because a driver that cannot see them cannot explain a
refusal to whoever reads its log. Whether the channel is armed at all is a
separate decision from what is reported - `AskViaDriver`, set only in the two
modes where a question can arise, since plan refuses before the gate and
bypass answers itself. That used to be one string compared against `'ask'`,
which was a behaviour switch keyed on a display name and became a latent bug
the moment the vocabulary grew past two words.

A run *without* `--input-format stream-json` can read files, list directories
and search, and nothing else. Every write, edit and shell command is refused in
band, as an ordinary `tool_result` with `is_error` true naming the refusal -
print mode's existing deny-by-default rule, not a new one. An SDK run never
reads or writes the approvals file and never writes `session.json` or
`history.txt`, so a driver's throwaway question neither inherits a human's
standing approvals nor manufactures new ones. It never loads hooks - that is
the one byte `HooksAllowed`, which is set only on the interactive path, and it
is why the `hook` event above has nothing to carry under `-p` - and never
spawns an MCP server, for the same structural reason: it halts before that
startup work runs.

Exit codes: 0 success, 1 the turn failed, 2 a startup or usage error. A startup
failure in `json` or `stream-json` mode is emitted as a single
`{"type":"error","error":"..."}` line rather than a sentence, so a driver's
parser is never handed prose.

```python
p = subprocess.Popen([exe, "-p", "", "--output-format", "stream-json",
                      "--input-format", "stream-json"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
p.stdin.write(json.dumps({"type": "user",
                          "message": {"role": "user", "content": "hello"}}) + "\n")
p.stdin.flush()
for line in p.stdout:
    msg = json.loads(line)
    if msg["type"] == "result":
        break
```

### Scripted sessions

`-p` answers one question and exits, and by default it leaves no trace: the
directory's saved conversation is not read, not written and not backed up. A
throwaway question should not disturb a conversation somebody is in the middle
of, and that has been true since print mode existed.

A multi-turn agent built out of repeated subprocess calls needs the opposite,
so it asks for it by name:

```
pasclaude -p "start on the parser" --session-file work\agent.json
pasclaude -p "now the error cases" --session-file work\agent.json --resume
```

The file is the ordinary session file - same format, same version, same
validation - so one written by a script opens in the REPL with `/resume`, and a
conversation started at the keyboard can be continued by a script. There is no
second serialisation, because two serialisations of the same data are how two
serialisations drift apart.

The path is checked with the same guard the tools use: it lives in the session
root, or in a directory named with `--add-dir`. `--session-file` without `-p`
is a startup error - interactive sessions already have `/resume` and the
session picker, and a second way to name one file is a second thing to keep
consistent. `--resume` under `-p` without `--session-file` is a startup error
too, and that one is the point of the design: guessing the directory's session
file is exactly what `-p` has always declined to do. `--continue` under `-p` is
refused outright, with no `--session-file` escape, because it is the stronger
version of the same problem - `--resume` at least names one fixed file, where
`--continue` takes whichever transcript happens to have been written last.

On turn one there is no file yet, and that is not an error - the driver passes
the same arguments every time and the first call simply starts fresh, tested
with `FileExists` rather than by sniffing the loader's reason string. A file
that IS there and cannot be read stops the run with exit 2. That differs from
interactive `--resume`, which prints its reason and carries on, and the
difference is deliberate: a person reads the warning and decides, a script does
not. A run that quietly got a blank conversation would do work on absent
context and then save over the file it could not read.

The save happens before the `result` line, not after. That ordering is a
contract: when a driver reads `result`, the transcript is already on disk, so
it can spawn the next process immediately without polling for the file. If the
save fails it gets an `error` line and the process exits 1 - but the `result`
line still says the turn succeeded, with the answer in it, because the work was
done and only the writing down failed.

Every `system`/`init` line now carries `resumed`, `resumed_messages` and
`session_file`, present on every run whether or not anything was resumed. A
driver that has to branch on a missing key is a driver that gets it wrong on
the run where nothing happened, which is most of them. `TSdkOptions` is now
built only through `SdkDefaultOptions`, at every construction site including
the suites: FPC initialises only the managed fields of a local record, so a
Boolean added to that record inherits stack garbage, and `Resume` reading
garbage is a run that resumes a file nobody asked it to.

What comes back is the conversation and nothing else. Permission mode, added
roots, standing approvals, the sandbox level, MCP approvals, hook trust and the
output style are all re-established from the command line on every run, because
none of them is in the file - `LoadSession` writes the messages, the model and
the counters, and there is no path from a session file to any of pasclaude's
permission state at all. A resumed run can never come back more permissive than
a fresh one.

Two caveats worth knowing before building a loop on this. Nothing is compacted
on the scripted path: `CompactWithSummary` would spend an API request the
driver never asked for, and the byte trigger is the interactive host's policy
rather than part of the protocol, so a session that outgrows the context window
is answered with a new file. And two processes given the same `--session-file`
race - each write is atomic, so a reader never sees half a session, but the
loser's turn is lost with no warning.

The same code is reachable from Pascal. `src\uSdk.pas` is console-free and
`examples\embed.lpr` is about sixty lines using only SysUtils and uSdk - set
the root, construct, ask, free - and `build.cmd` builds it, so it cannot rot
into needing `uTerm`. One session per process, because `RootDir`, the AllowAll
flags, the job table, the bash prefixes, the snapshots and the ignore rules are
all module-global in `uTools`; a subprocess is the isolation boundary.
Constructing a session clears the working-directory set before setting the
root - they are a grant made to a session, not a property of the machine - and
loads the user's deny rules and nothing else out of the approvals store. That
is the one class of rule it is safe to hand an embedder unasked, because it is
the one class that cannot grant anything: `Ask` stays nil, so the session
inherits the user's refusals and none of their approvals.

That unit is also where the system prompt now lives. It was lifted out of
`pasclaude.lpr` verbatim, which is what makes it testable for the first time -
specifically that user memory loads *before* the project's own instruction
files, so nearer still wins. The facade ships with
`SdkProjectContextAllowed` false, and `examples\embed.lpr` sets it: letting
the tree you point a session at write part of the system prompt is a
deliberate act, like assigning `Ask`, and an embedder that clones a
stranger's repository into the working directory leaves the line out and gets
the guidelines only. `--no-project-context` is that same decision made from
the command line, for the caller who is running the shipped binary against a
tree rather than embedding the unit.

## Pull requests: /review and /pr-comments

```
/review                  :: git diff HEAD - the working tree
/review --staged         :: git diff --cached - the index
/review <ref>            :: git diff <ref>...HEAD - what this branch adds
/pr-comments [<n>]       :: one pull request's comments, printed then sent
/pr-comments <n> --show  :: printed, and nothing sent
```

`/review` is local. It runs `git`, sends the diff as an ordinary user message
and touches no network and no token at all, so any edit the model then
proposes shows its own diff and asks like every other. The stat is printed
first, so you see the size and the file list before a turn is spent on it.
`/review 123` is refused by name: fetching a pull request's diff would pull an
arbitrarily large, arbitrarily hostile change written by whoever opened it
into the context of an agent holding thirteen tools, for a result
`gh pr checkout 123` and then `/review main` already gives from code you chose
to check out.

A `<ref>` is user text entering a `cmd.exe` line that answers to nobody -
there is no permission gate, no deny check and no sandbox on a slash command
you typed - so it is charset-validated before anything is composed: letters,
digits, `. _ - /`, no leading `-`, no `..`, 128 bytes. The validator has its
own test, and it is one requirement with the resolver below rather than two
ideas: both, or neither ships.

`/pr-comments` fetches the inline review comments, the review bodies and the
conversation thread of one pull request in four GETs, or more when a list runs
to more than one page, renders them to the
console, and sends the model exactly the lines it printed. With no number it
infers the pull request from the current branch and asks for one when that is
not exactly one match. `--show` prints and sends nothing. Consent is per
invocation and per pull request: there is no `github` tool, so the model can
never fetch one itself, and there is no polling.

Read-only is a property of the client rather than of the caller. `uGitHub`
issues GET and nothing else - there is no POST, PUT, PATCH or DELETE anywhere
in the unit - so no comment, review, approval, merge, label or branch can be
produced by any amount of injected text, in any mode, by any answer to any
prompt. A read-only client cannot be talked into an action, which is a
stronger statement than any amount of prompt hygiene and is why the hygiene is
the second line rather than the first. The consequences are stated rather than
worked around: no replying, no resolving, no approving.

Pagination exists now. `uHttp` returns the `Link` response header - one header
by name, verbatim and unparsed, dropped whole rather than cut if it is over
4 KB, because a truncated URL is a URL that is nearly right and nearly right
is the worst thing an untrusted URL can be - and pasclaude follows
`rel="next"`. But a next URL is a URL a *server* chose, so it is followed only
when it is one pasclaude would have composed itself: `https`, the host exactly
`api.github.com` with no port and no credential in it, and the same path as
the page just read with only the query allowed to change. A `Link` that fails
any of that is refused, the list stops there, and the notice says so by
quoting the rule rather than guessing which half of it fired - eight different
things make that check say no and only one of them is another host, so a
notice that named the host every time would be wrong on the one line whose job
is to tell you something tried to move you. That check is not decoration:
a configurable API host is the one knob a credential must not have, and
without the check a `Link` header *is* that knob, operated from the wire with
no settings file involved and nothing for the scope table to refuse.

At most three pages of 100 and 300 items a list - the page cap bounds requests
carrying the token, the item cap bounds memory, and the two multiply to each
other on purpose so neither is a number that could never bite. A list stopped
by either cap is still reported rather than silently truncated, and the notice
now names *our* cap, which is a different sentence from the one it used to
have to write. The old sentence is still there for the one case that needs it:
a list whose last page came back exactly full with no `rel="next"` in it is
reported as *possibly* incomplete, because a `Link` that was dropped - over
the 4 KB cap, or through a header query that failed - looks from here exactly
like a list that ended, and handing you 100 of 250 comments with no sign
anything was missing is the failure this notice has always existed to prevent.
A short last page cannot be that case and says nothing at all. The honest
cost: a busy pull request spends up to ten GETs
where it spent four, and unauthenticated requests get sixty an hour, so six
runs can exhaust a limit fifteen used to.

Every program pasclaude runs by name - `git`, `gh` - is resolved on `PATH`
first. `cmd.exe` searches the current directory before `PATH`, so a repository
shipping a `git.cmd` used to have it run at startup; that was measured with a
probe rather than theorised. `ProgramCommand` walks `PATH` and `PATHEXT` and
never considers the current directory or a working root, and the three
pre-existing git call sites go through it too.

## The GitHub token, and text a stranger wrote

A GitHub token comes from `GH_TOKEN`, then `GITHUB_TOKEN`, then
`gh auth token`, and from nowhere else - not from a settings file at any tier,
not from a flag, not from a prompt, not from any file under a root. pasclaude
stores none: `gh` already owns GitHub credential storage, and a second DPAPI
blob would be a second credential lifetime to keep correct for no gain. So
`uAuth` grows no source, its writers still take no path argument, and
`AuthResolve`'s declaration order still answers only "which credential signs
the model request". The API host is compiled in and is settable at no tier,
which is why there is no GitHub Enterprise support and no `github.api_base`:
moving an endpoint is how a token leaves, so that knob does not exist.

The token is screened before it is used, not after. `uHttp` hands the header
block straight to `WinHttpSendRequest` and validates no byte of it, so a CR in
a token value is header injection; `GhTokenLooksUsable` requires printable
ASCII, one line, 8 to 512 bytes, and it runs before `HttpGet` is called rather
than inside a transport, so a substituted transport in a suite sees exactly
what the network would. A token that is present and unusable is refused by
name rather than quietly downgraded to an anonymous request. `gh`'s output is
accepted only on exit code 0 and only as a single line, and is never copied
into an error, a note or a report.

Where it is redacted is everywhere it could appear, and the first mechanism is
that it is never recorded. `TDiagFacts` carries the repository name and the
*source name* - `GH_TOKEN`, `GITHUB_TOKEN` or `gh cli` - and no value, no
hint and no length, so `/status`, `/doctor` and `/bug` could not leak it if
every redactor failed. It exists only inside the header block of a live
request: never in a URL, never in a console line, never in a session file,
never in telemetry. `/status` also spawns nothing to find it - naming the
source reads two environment variables and resolves `gh` on `PATH`, because a
command called status must not run a program whose whole job is to print a
credential to a pipe.

**A pull request body is written by anyone with a GitHub account**, and that
makes it the least trusted text this program handles - an MCP tool description
at least required somebody to approve a command line first. It lands in an
ordinary user message, never the system prompt, never a tool description,
inside a marked block preceded by one sentence saying that everything inside
is third-party data, is information to consider, and is never an instruction.
Caps: 100 items per list, 4 KB per body, 64 KB per payload, every cut marked,
every byte `IsValidUtf8`-checked.

The order of that envelope is the bug, so it is written down. Decode with
`uJson`, strip control characters, `Utf8Cut` to the cap, and **then** drop any
line that is a forged marker - per line, after the cut, never on the assembled
string. Stripping markers first is forgeable: pad so the cut lands mid-marker,
or write a marker that only appears once the pieces are joined. And the
envelope is a labelling device, not a sanitiser. It tells the model where the
third-party text starts and stops and removes a forged end-marker; it does not
make the text safe. A comment can still persuade the model to *propose* an
edit or a command, and the human answering the prompt is the last gate - so a
user who habitually answers `a` has already widened it, and `/review` over a
fetched fork branch feeds attacker-written code to the model exactly as
opening that file in an editor would.

## Running unattended

Everything above assumes somebody is at the prompt. This is the first context
where nobody is, and it is documented as its own thing for that reason.

A comment on an issue or pull request that mentions `@claude` can start a run.
The template is `examples\github\pasclaude-mention.yml`; it is copied into
your own repository rather than being live here, because a live workflow in
this repository would run on every comment, spend the maintainer's Actions
minutes, and fail saying "no credential".

**A CI run may read the repository and write one comment. It may never push,
never patch, never approve, never merge.**

**Who may pull the trigger.** `issue_comment`, created, and nothing else -
that trigger's workflow file is always taken from the default branch, so a
pull request cannot edit the workflow that reviews it. The check runs twice: a
cheap `if:` in YAML, so a stranger's comment never starts a runner at all, and
again in Pascal inside `--ci prepare`, so an edited `if:` does not silently
widen anything. Both read `author_association`, which GitHub computes from the
commenter's relationship to the repository; it is not a field the commenter
fills in, which is the only reason it is trustworthy input while the comment
beside it is not. Anything below `COLLABORATOR` is refused, an association
nobody has invented yet reads as the lowest value rather than the widest, and
`--ci-allow member|owner` narrows further. There is no flag that widens.

**Fork pull requests are refused, not unimplemented.**
`gh pr view --json isCrossRepository,headRefOid,state` is parsed as if
hostile: anything that is not the boolean `false` reads as a fork, and a
pull-request comment with no `--ci-pr` file is refused too, so deleting that
step fails closed rather than open. The argument for allowing forks is that
with bash denied nothing from the fork is executed, only read - but that rests
on the job having no build step, and one added `npm ci` line destroys it
silently.

**The token, key by key.** `contents: read` for the checkout, `issues: write`
to post the comment (the issue-comments endpoint serves pull requests too, and
this is the narrower of the two keys that satisfy it), `pull-requests: read`
for `gh pr view`. Naming any key sets every unnamed one to `none`, so with
exactly those three an injected instruction could read this repository, read
pull-request metadata and post comments here - and could not push to a branch,
create a branch or a tag, approve or submit a review, merge, edit a workflow,
publish a release, or reach another repository. It holds no token in any case:
`GH_TOKEN` is set on exactly the two fixed `gh` steps, and the step that runs
the model has `ANTHROPIC_API_KEY` and no GitHub credential.
`persist-credentials: false` keeps one out of `.git\config` where `read_file`
could find it.

**Why bypass mode is not the CI recipe.** `--dangerously-skip-permissions`
appears nowhere in the template and the ux suite fails if it ever does. Under
`-p` there is nobody to ask, so `Ask` is nil and a gated tool returns an
ordinary error result while the turn continues - plan mode over a deny floor
is not a degraded agent, it is one that reads and answers. The floor is
written out of tree, to `%LOCALAPPDATA%\pasclaude\deny.json`, so nothing in
the checkout can supply or edit it: `tool:bash`, `tool:bash_output`,
`tool:kill_bash`, `tool:fetch`, `tool:web_search`, `tool:write_file`,
`tool:edit_file`, `tool:notebook_edit`, `tool:task`, `path:**/.git/**`,
`path:**/.env*`, `path:**/*.pem`. Nothing overrides a deny rule - not a mode,
not a persisted "always", not a hook's allow, not a file in the tree - which
is exactly the property worth having where nobody is watching. `--ci prepare`
runs after the rules load and exits 2 naming every missing one. The one thing
that floor cannot cover is a hook, because `uHooks` sits below `uTools` and no
hook command is ever matched against a rule; hooks are therefore switched off
structurally instead, as **Hooks** above describes.

**The project's own instruction files are switched off the same way, and for
a reason the deny floor also cannot reach.** `uSdk.SdkProjectContextAllowed`
ships false; the host sets it true unless the mode is one of the two `--ci`
verbs *or* `--no-project-context` was given, and `SdkProjectContext` re-reads
it where the files are opened rather
than at the call site, so clearing that byte stops every caller at once -
including `TSdkSession`, which builds a prompt of its own. It matters for the
same reason hooks did: `--ci report` runs after `actions/checkout`, so
`AGENTS.md`, `CLAUDE.md`, `.pasclaude.md` and everything they `@import` came
from the pull request head and went into the system prompt, which is the most
trusted position in the request. A `path:` deny rule is matched against the
model's tool calls, and this loader is not one. Be exact about what that buys,
because the flattering reading is wrong: neither `--ci` verb runs a turn, so
what the flag stops there is the *read and the assembly* rather than a
delivery to a model, and a `--ci` run that skipped files says so in a line
that also says it asked no model anything - the answer in that build log came
from the `-p` step above it, which loads them unless it too passes
`--no-project-context`, and in the shipped template it does. The
user-level memory in `%USERPROFILE%\.pasclaude\CLAUDE.md` still loads: the
question the flag asks is which *tree* wrote the prompt, and the template
builds the agent from a clone in `RUNNER_TEMP` before checking the head out,
so nothing in a pull request can write that path.

The step that actually runs the model is an ordinary `-p` in the checked-out
head, and it passes `--no-project-context`. A flag on the command line rather
than a mode inferred from the prompt, and that distinction is the whole of it:
the prompt is the attacker-supplied text, so anything keyed on its contents is
a behaviour the attacker chooses, and the fail-open case would be a comment
crafted so the marker is not recognised. The flag clears the same byte, so
`SdkProjectContext` needs no second rule; the two terms meet in
`uSdk.SdkProjectContextDecide`, an `and` of two negatives, so neither can
widen the other and there is deliberately no argument that turns the loader
back on. `-p` *without* the flag loads a project's files exactly as the REPL
does, which is what **Scripted sessions** promises, and `ux` asserts both
directions over real files on disk. What is left of a branch's contribution to
that request is its skill catalogue, which is in the `skill` tool's own
description and not in the prompt.

**The two modes.** `--ci prepare --ci-in <event> --ci-out <prompt>
[--ci-pr <pr.json>]` decides whether to answer, writes the prompt file when it
will, writes a fixed refusal comment to `<prompt>.md` when it will not, and
appends `proceed`/`code`/`reason`/`number`/`head_sha` to `%GITHUB_OUTPUT%`.
`--ci report --ci-in <result.json> --ci-out <comment.md>` turns one line of
`--output-format json` into the comment and appends a run summary to
`%GITHUB_STEP_SUMMARY%`. Exit codes are the existing three: 0 for any decision
reached, 2 for a usage error, an unreadable or oversized input, an unwritable
output, or a deny floor that is not in force.

Comment text never passes through YAML expansion or a command line - pasclaude
opens `GITHUB_EVENT_PATH` itself, which is exactly how the classic Actions
injection is avoided - and nothing untrusted reaches `GITHUB_OUTPUT`,
`GITHUB_ENV` or a `run:` line. Every value written there is from a fixed
vocabulary or validated, and `head_sha` must be exactly 40 hex characters or
it is not emitted, because it chooses the commit `actions/checkout` writes
into the workspace.

**How the YAML is checked.** `build.cmd` and `test.cmd` cannot run YAML and
RTL-only forbids adding a parser, so `ux` reads the template as text - absent
is a failure, not a skip - and asserts every deny rule verbatim,
`persist-credentials: false`, the three permission keys and no fourth
`: write` line, fewer than 120 lines, and the absence of the `_target`
trigger, comment-body and title interpolation, and the bypass flag. It is a
grep, and it is honest about being one: everything semantically load-bearing
lives in `src/uCi.pas` where the suites can drive it.

**Cost.** `windows-latest`, Chocolatey's `freepascal`, and no release
pipeline, so the workflow clones and runs `build.cmd`: about four minutes
wall, eight billed on a private repository, free on a public one.

## Settings, and the scope table

```
%USERPROFILE%\.pasclaude\settings.json        user
<root>\.pasclaude\settings.json               project
<root>\.pasclaude\settings.local.json         local
```

Three files, one flat JSON object each, read once at startup. Nearer wins per
key: local, then project, then user, then the compiled default - the rule
`ScanSkillDir` already uses for skills, styles, commands and agents. Keys are
literal flat strings; `model.alias` is a key whose name contains a dot, not an
object to walk into, so this loader has no traversal of an unknown object at
all. The user file is in `%USERPROFILE%` rather than `%LOCALAPPDATA%` for the
reason `keys.json` is: `%LOCALAPPDATA%` is where the program keeps state *it*
writes, and this is hand-authored configuration a person has to be able to
find.

The charter is one sentence: **settings.json carries display and economy keys
only; authority stays where it is.** This is the fifth round in a row that
principle has been defended - approvals out of the repository, deny rules from
`%LOCALAPPDATA%` only, `keys.json` user-scope only, `--add-dir` from argv only -
and it now has a name and a table instead of an argument repeated per feature.

| key | who may set it | range | default |
| --- | --- | --- | --- |
| `output_style` | any tier | a style name | the built-in |
| `thinking_budget` | any tier | 0, or 1024..32768; project ..8192 | 0 |
| `tool_result_bytes` | any tier | 4096..131072; project ..65536 | 30720 |
| `auto_compact_tokens` | any tier | 20000..180000; project ..150000 | 150000 |
| `model` | **user file only** | a model id, alias or profile | `claude-sonnet-4-5` |
| `model.alias` | **user file only** | name -> id | four built-ins |
| `model.route.subagent`, `model.route.compaction` | **user file only** | a model name | `sonnet` |
| `telemetry.enabled`, `.endpoint`, `.headers`, `.interval_turns`, `.timeout_ms`, `.service_name` | **user file only** | | off |
| `ide.enabled` | **user file only** | let `/ide` open files and diffs in a detected editor | on |
| `ide.command` | **user file only** | absolute path to the editor's command-line program | none |

Sixteen keys, four of which a project may set. The three economy numbers are
**narrow-only** from a project or local file, measured against the value *you*
have in force - your own settings file if it names the key, the compiled
default if it does not. A project may lower `thinking_budget` and
`tool_result_bytes` and never raise either, and because the compiled thinking
budget is 0, a repository cannot turn extended thinking on at all.
`auto_compact_tokens` runs the other way: each compaction is an extra billed
request, so a project may push the point later and never earlier. The
comparison is against your position rather than against the key's own maximum,
which is the fix for the version that let a clone raise a compiled 0 to 8192
while the table's comment said it could not. A value past the ceiling is
refused, not clamped - a clamp teaches the repository that the key half-works
and teaches you nothing. A `thinking_budget` between 1 and 1023 is refused at
every tier, because the API's floor is 1024 and it rejects the request, so the
number would fail every turn in that checkout.

Both `ide` keys are user scope for the reason the whole table exists.
`ide.command` names a program a slash command starts, so a cloned repository
able to set it would be a cloned repository able to run anything on your
machine - the same shape of hole as a project-settable telemetry endpoint, and
it gets the same answer. It also has to be absolute, has to end in `.cmd`,
`.bat` or `.exe`, has to exist, and is only consulted once an editor has
already been detected. None of those four is sufficient on its own, and the
shape check is re-applied by `SettingsWrite`, so `/config set` cannot write
what startup would refuse. It is also the only way a JetBrains user gets a
launch, because nothing a JetBrains terminal exports names `idea64.exe`.

`model` is user scope because a project that picks the model does not merely
spend your money on its own say-so: it can name the weakest available id to
review its own code, and nothing in the output would say so. There is
deliberately no fingerprint-and-prompt path of the kind `hooks.json` has. Hook
trust is a one-time question about a bounded set of commands you can read in
full; model choice is unbounded and recurring.

**`settings.local.json` carries project authority, not user authority.**
`.gitignore` is a convention rather than a guard - a repository can simply
commit one - so treating the filename as a security property would hand a
clone back everything three rounds of work took away from it. Local is nearer
than project in *precedence* and identical to it in *authority*; the escape
hatch from a project value is `/config set --local`, not an inverted hierarchy.

**The one mechanism.** `TierAllowed(Def, Tier)` is a function in
`src/uSettings.pas` with exactly one call site: `SettingsStore`, which is the
only procedure in the unit that writes the value array. A value at a tier its
key does not permit is **never stored** - not stored and later overruled, and
there is no second `if` anywhere for a refactor to drop. Two greps are the
review: `SettingValues` must be written only inside `SettingsStore`, and
`TierAllowed` must have one caller. Every reader funnels through one
`SettingLookup`, so the reader side is trivially safe: it can only see what the
writer admitted. `uSettings` uses `uJson`, `SysUtils` and `Classes` and nothing
else, and `SettingsParseTier` takes **bytes**, never a path - the
`uTerm.KeysParse` rule - so the unit can never learn a configuration location
and every suite drives it with no filesystem.

Thirty-two more names are in the same table as refusals, honoured at no tier
including the user one: `permissions`, `allow_edits`, `allow_bash`,
`allow_fetch`, `bash_programs`, `trusted`, `deny`, `sandbox`,
`permission_mode`, `append_system_prompt`, `add_dir`, `additionalDirectories`,
`env`, `apiKey`, `apiKeyHelper`, `auth`, `credential`, `login`, `mcpServers`,
`plugins`, `vim`, `bindings`, `hooks`, bare `telemetry`, bare `ide`, `github`,
`report_dir`, `redact`, `doctor`, `bug`, `statusLine`, `outputStyle`.
They are there on purpose. The realistic failure is not an attack, it is
somebody pasting Claude Code's `settings.json` and believing it took effect, so
each one produces a sentence naming the file that really owns it - `vim` and
`bindings` point at `keys.json`, `hooks` at `.pasclaude\hooks.json`, `deny` at
`deny.json`, `permissions` at the approvals file under `%LOCALAPPDATA%`, bare
`ide` at the two dotted keys, and `github` at `GH_TOKEN`, `GITHUB_TOKEN` and
the `gh` CLI, since no file names the token and none names the host.
`append_system_prompt` points at the command-line flag of that name and is
refused at the user tier too, which is stricter than `output_style` beside it:
a style adds a paragraph about prose whose body has one reader, where this
would add arbitrary standing instructions to the most trusted position in every
request. `report_dir` and `redact` are pre-refused so that adding them later is
a review conflict rather than a one-line insertion. The last two are the two
shapes of silent failure this list exists to catch, and both were missing until
an audit went looking. `statusLine` names a *program* in Claude Code, so it is
`ide.command`'s hole without the slash command in front of it - a clone able to
set it would run something of its choosing every time the screen repainted -
and here the status line is compiled in and runs nothing at all. `outputStyle`
is the near miss on `output_style`, which any tier may set, and a near miss is
where silence costs most: the user can see the working key in somebody else's
file and has no way to tell why theirs does nothing. `SettingIndex` compares
names with `=` and nothing lowercases an incoming key, so the two spellings are
genuinely two entries and neither shadows the other. The counts above are
asserted in `ux` now rather than only written down - the sentence introducing
the honoured keys in `uSettings` had said "fourteen" since before the two `ide`
keys were added, which broke nothing and stopped being true.

A file with **any** problem in it contributes **nothing** - bad JSON, not an
object, an unknown key, a wrong type, an out-of-range integer, a key at a tier
it may not use - and every problem is named in yellow at startup beside the bad
deny rules. Partial application is how a typo silently changes half a
configuration. It never halts: a project file is attacker-controlled, and a
startup refusal would be denial of service via config. Those yellow lines are
suppressed under `--output-format json` and `stream-json`, where stdout carries
the protocol and nothing else, and every one of them is in the ledger `/doctor`
prints regardless. Control characters are stripped and every string is cut to
240 bytes on the way out: a key named `ESC[2J` in a cloned repository would
otherwise erase the security warnings printed above it, and a TAB inside a
value would shift the fields of the tab-separated `/config` row and let the
file choose the tier word `/status` blames.

The load sits immediately after the session root is known and **above** the
print-mode halt, so a `-p` run honours it. That is legal only because nothing
in the table can grant - not a permission, not a root, not a sandbox level, not
a mode, not a tool. The authority split is what buys the load position. If a
future key can grant, it does not belong in settings.json; if it somehow must,
the load splits and the granting half moves below the halt beside
`LoadPermissions`.

`/config` prints the three absolute paths, then key, effective value and tier,
with an `overruled:` line under anything shadowed. Absolute paths rather than
tier words because `SafePath` refuses everything under `.pasclaude` in every
root: the model's own `read_file` cannot look at a settings file even when you
ask it to, so `/config` is the whole debugging surface. `/config get <k>` shows
the chain, `/config set [--local] <k> <v>` writes the user file or
`settings.local.json`, `/config unset` removes and `/config reload` re-reads.
`/config set` never writes `<root>\.pasclaude\settings.json` - pasclaude
committing configuration into somebody's repository on their behalf is not a
convenience. The writer is read-modify-write over the parsed document, so every
other key survives including the refused ones, and an unparseable target file
refuses the write rather than being replaced; that is the direct answer to
`SavePermissions`, which rewrites wholesale and destroys any key its loader
does not understand.

Only three of the four keys re-apply on `/config reload`. The system prompt is
frozen at `TAgent.Create` for prompt-cache reasons, so a reloaded
`output_style` needs `/output-style` and a reloaded `model` needs `/model`.
`keys.json` and `plugins.json` were deliberately not folded in: one is
`%USERPROFILE%`-only by design, and the other is program-written in both
directions, where a hand-authored file would recreate `SavePermissions`'
silent-loss hazard in a new place.

## Model aliases and routing

`opus`, `sonnet` and `haiku` are short names for the current family ids, and
`opusplan` is a profile rather than an id: opus while plan mode is on, sonnet
the rest of the time. Every built-in target is **dateless** -
`claude-opus-4-5`, not a snapshot - because a dated id in a table this program
ships is the retired-default 404 that has already happened here once. The
server resolves a family name to whatever is current; a table of snapshots
would have to be re-shipped to stay true. The live list is still the authority:
a bare `/model` fetches `GET /v1/models`, numbers it exactly as before, then
prints the aliases below with continued numbering, marking in yellow any whose
target the key's own list does not mention. An alias name may not contain a
dash or begin with `claude`, so no real model id can ever be captured by one,
and any built-in target can be overridden from the user settings file without a
rebuild - which is what makes a stale table an annoyance rather than a
breakage.

Two roles run somewhere other than the model you picked: the read-only
subagent, which has three tools and nobody watching it spend, and the
compaction summary, which is mechanical work on text the model already wrote.
Both default to `sonnet`. On the shipped default model that is a **no-op** -
every request carries exactly the string it carried before routing existed - so
the feature costs nothing until you deliberately choose a stronger main model,
and when you do the banner says which models the routed roles are on. Your own
turns are never routed.

The profile is resolved per request rather than when you type `/model
opusplan`, so `/mode plan` and `/mode ask` switch the model mid-session with
nothing to keep in step, and `Agent.Model` keeps the literal word so `/resume`
restores the profile and not a snapshot of whichever half was live at save
time. The cost is real and worth stating: changing model mid-session
invalidates the cache breakpoint on the system block and re-bills the prefix.

When a turn fails with HTTP 404 and its id came from an alias, the API's own
`not_found_error` message gains a clause naming the alias, the id it produced
and `/model`. There is deliberately no startup preflight against `/v1/models`:
it would add a round trip to every start including `-p`, and it could only ever
answer "this key's list mentions it", which is not the same question for a
dateless name.

**Precedence, highest first:** `/model` typed this session, then the model a
resumed session restores, then `ANTHROPIC_MODEL`, then user-scope `model` in
settings.json, then the compiled default. `/cost` keeps its existing lines and
adds a `by model:` block only when more than one model was actually used -
tokens from different models are not comparable, and the block is the only
thing that says so. Still no prices, which is the same reason the SDK omits
`total_cost_usd`. The SDK's init line keeps `model` as the literal session
model, which may now be an alias or a profile, and gains `model_resolved`, what
the next main request would actually carry; the result line gains an additive
`models` array.

## Credentials

pasclaude authenticates with whatever this machine already has, in one order it
will tell you on request:

```
1  ANTHROPIC_API_KEY
2  ANTHROPIC_AUTH_TOKEN
3  a stored preference, if it names a source that is actually live
4  pasclaude's own store   %LOCALAPPDATA%\pasclaude\credential.json
5  Claude Code             %USERPROFILE%\.claude\.credentials.json
6  Jcode                   %USERPROFILE%\.jcode\auth.json
7  the ant CLI profile     %APPDATA%\Anthropic\credentials\<profile>.json
```

The two environment variables always win, because exporting a variable is a
deliberate act for one invocation and reading another program's token is not. A
preference can only *choose among* sources this machine already has; it can
never introduce one and never outranks the environment. If you never type
`/login`, this is exactly the behaviour of every earlier version with two more
places looked in.

**It cannot log you in, and that is the honest answer rather than a missing
feature.** The API documents three ways to authenticate: a static `sk-ant-api…`
key, Workload Identity Federation (an org-configured OIDC assertion exchanged
at a token endpoint - a CI mechanism needing a federation rule and a service
account, not a human at a terminal), and App Attest on Apple platforms. There
is no published authorization endpoint, no device-code grant, no PKCE flow and
no public client id available to a third-party program. `ant auth login` is
Anthropic's own CLI authenticating as itself and Claude Code's client identity
is Claude Code's, so a browser sign-in here could only be built by borrowing
one of those - this program claiming to be one it is not. pasclaude is a
credential *manager* and never a credential *issuer*, and that is written down
here so the next reader does not reopen it.

`/login` with no argument lists every source with its file and a hint of the
form `sk-ant-...4f2a` - never the value - marks the one in use, and takes a
number to record a preference. `/login key` reads a pasted key with **nothing
echoed at all**, not even asterisks, because the length of a key is worth
hiding too, and stores it at `%LOCALAPPDATA%\pasclaude\credential.json`
encrypted with Win32 DPAPI at current-user scope. If the encryption fails
nothing is written: there is no plaintext path and no flag that talks one into
existing. If the file later cannot be decrypted - a different Windows account,
different hardware - it is treated as absent and the note says which of those
it was rather than merely "log in again", and it is not deleted, because you
may simply be signed in as the wrong user.

**`/logout` removes that file and nothing else.** Claude Code's, Jcode's and
`ant`'s are read forever and written never: refreshing them is their owner's
job, and deleting one would break a program you did not ask us to touch. When
the credential in force came from one of those, `/logout` refuses, names the
file, and tells you to log out of that program instead. The guarantee is
structural rather than remembered - **no function in `uAuth` that opens a file
for writing takes a path parameter**, so it can name no file but its own.

No file in your project decides any of this. The store and the preference live
under `%LOCALAPPDATA%`, the three foreign sources under `%USERPROFILE%` and
`%APPDATA%`, `SafePath` refuses every path outside the session roots so the
model's own `read_file` and `bash` cannot reach a credential either, and
`apiKey`, `apiKeyHelper`, `auth`, `credential` and `login` are all refused
settings keys. A repository cannot ship one, cannot pick which one is used, and
cannot make `/login` run.

A GitHub token is a different question and is answered somewhere else
entirely. It comes from `GH_TOKEN`, then `GITHUB_TOKEN`, then `gh auth token`,
and from nowhere else; pasclaude stores none, `uAuth` gained no seventh source
and no second store, and the six sources above still answer only "which
credential signs the model request". See **The GitHub token, and text a
stranger wrote**.

A refused credential now produces a sentence rather than `HTTP 401 -
authentication_error`: which of the six sources it came from, which file,
whether it has expired since the session started, and what to do. A token the
owning program refreshed on disk mid-session is picked up automatically -
re-reading is not writing - once per request, only on 401, and only when the
new credential actually differs from the one just refused; 401 is still not a
retryable status. A credential expiring within fifteen minutes is announced at
startup instead of discovered mid-turn. `/login` and `/logout` are refused
under `-p` and in SDK modes, which have nobody to answer them; a stored
credential is still used there.

## What leaves the machine

Telemetry is off. It stays off until you write two keys into your own settings
file:

```
%USERPROFILE%\.pasclaude\settings.json
{"telemetry.enabled": true,
 "telemetry.endpoint": "http://localhost:4318"}
```

Both are needed; either alone sends nothing. A project file cannot set either,
because all six `telemetry.*` keys are user scope in the table above and a
project value is refused by name with the whole file discarded.
`OTEL_EXPORTER_OTLP_ENDPOINT` is not honoured either, and that is the less
obvious half: environment is inherited from whatever launched us, so honouring
the standard variable would have handed a repository the endpoint through a
wrapper script. There is no `--telemetry` flag. A project-configurable
telemetry URL is an exfiltration channel wearing a respectable name.

The wire format is OTLP/HTTP with the JSON encoding, POSTed to `/v1/metrics`
with `Content-Type: application/json`, lowerCamelCase keys, enums as integers,
64-bit values as decimal strings, DELTA temporality so a process that dies owes
nothing. Protobuf would mean hand-writing a wire encoder, which is the same
class of thing as the SHA-256 and paszlib refusals, so your collector has to
accept OTLP/JSON. The standard Collector does, on the same port as protobuf;
some vendor endpoints do not, and that shows up as an opaque 400 or 415 which
`/telemetry` reports by status.

Exactly this leaves the machine, and nothing else:

```
service.name, service.version          resource attributes
pasclaude.turns                        {turn}
pasclaude.tokens                       {token}    type, model
pasclaude.tool.calls                   {call}     tool, status
pasclaude.api.requests                 {request}  status
pasclaude.api.duration                 ms
```

`type` is one of input, output, cache_read, cache_write; `status` is ok/error
on a tool call and an HTTP code or `transport` on a request. That is the whole
list. Not sent: prompt text, reply text, thinking, tool arguments, tool output,
file names or paths, cwd or roots, project or repository name, host name, OS
user, command line, environment, error strings, deny rules, hook or skill or
MCP server names, changed-file counts, a session identifier, and no credential
in any form. `session.id` was cut rather than defaulted off - its only use is
letting a collector operator count distinct sessions, and a random id is
exactly the field that later grows into a stable one.

The two strings that could carry text are filtered rather than trusted. `tool`
must be in a compile-time list of built-in tool names or it becomes `mcp` -
naming no server - or `other`; `model` must look like `claude-[a-z0-9._-]*` or
it becomes `other`. Both filters exist because both strings arrive from files
that come with a clone: MCP tool names from `.mcp.json`, the model from
`session.json`. A comment asking people not to put a secret in a tool name
would not be enforcement. A test walks the live `ToolsSchema` and fails the
build if a fourteenth built-in tool is added without being added to the
allowlist, so the failure is a compile-time one rather than a dashboard quietly
reporting `other`.

`/telemetry` shows the state. `/telemetry preview` prints the exact JSON that
would go out, from the same function the sender calls, with any collector token
redacted to its length. `/telemetry send` flushes now and reports the status.

Sending is synchronous, because this program has no threads. The flush happens
at the end of a turn, after the answer is on screen and before the next prompt
is drawn, and only every `telemetry.interval_turns` turns (default ten). The
honest price is at worst `telemetry.timeout_ms` of quiet - 2 seconds by
default, capped at 5 - once per interval. A failed batch is discarded rather
than queued, so a collector that is down cannot grow a buffer, and after three
consecutive failures telemetry stops for the rest of the session with one
yellow note. A startup that never reached a turn sends nothing at all. Token
counts are a delta against a baseline that starts at zero, where a fresh agent
starts, and is moved by the host only when a session is *loaded* - so the first
turn of a session counts, which matters most where it is least visible: a `-p`
run has exactly one.

`http://` is accepted only for `127.0.0.1` and `localhost`, on an exact host
test, because a local collector is the one case where there is no network to be
in the clear on. `uHttp.SplitUrl` is unchanged - https only, as it always was -
and the loopback exception lives in a new `SplitUrlEx` with an `out Secure`, so
the edit cannot reach the contract the Anthropic request path already depends
on. `localhost` resolves through the hosts file, which needs administrator
rights to edit; that caveat is stated rather than pretended away.

## Status, doctor and bug reports

```
/status                              :: what is true right now
/doctor [--online]                   :: what is wrong, and what to do
/bug [--transcript] [--paths] [--json]  :: a report a maintainer can read
pasclaude --status                   :: the same report, then exit 0
pasclaude --doctor [--online]        :: exit 1 if anything is a problem
```

Three commands, one unit. `src/uDiag.pas` builds `TStatusReport` and
`TDiagReport` and renders each of them twice - once as console lines, once as
JSON - through functions that are *pure in the record and take nothing else*.
That is what stops the two renderings disagreeing, which is the classic way a
bug report drifts from the status view it claims to quote. It also makes the
whole feature testable: the builders read in-memory state, the host's only
jobs are to fill one facts record, record a note where it already prints a
yellow one, and print what comes back.

`/status` is the report with no judgement. It names the model and any routing,
the credential source, the permission mode and standing grants, the deny-rule
count, the session root and added directories, MCP servers, hooks, output
style, vim, sandbox level, skills and plugins, the token counters `/cost`
prints, the session file and the settings in force. Every one of those values
is *borrowed*: the mode word is `uTools.PermModeName(CurrentPermMode)` and the
sandbox word is `uSandbox.SandboxLevelName`, not a second copy that would
drift the first time `/mode` grew a word. It ends with the footer `/help`
never had: the three things read once at startup - skills, the output style,
the MCP config - plus `settings.json`, and the command that refreshes each.
`/status` reports the **session**, which after a mid-session edit is not what
is on disk, and that is exactly when somebody types it.

`/doctor` is the judgement. Fifteen checks with fixed ids, each carrying a
level, a cost and - whenever it is not ok - a remedy that the builder asserts
is non-empty, because a health check that says "problem" without saying what
to do is a riddle. What each costs:

| check | cost |
|---|---|
| `winhttp` `credential` `credential_expiry` `config_files` `settings_scope` `console` `github` | nothing; memory only |
| `state_dir_writable` `project_state_dir_writable` | one file created and deleted in a `finally` |
| `mcp_servers` `hook_commands` `session_file` `disk_reports` `ide_editor_cli` | reads PATH and file metadata; **nothing is spawned** |
| `model_access` | one `GET /v1/models`, and only with `--online` |

Nothing is spawned and nothing is sent unless you type `--online`. That is the
rule this codebase applies to web search and to `fetch`: an outbound request
is a channel, and a command must not open one because its name sounded
harmless. Resolving an MCP server's or a hook's program on `PATH` is a
heuristic - a shell builtin or an unusual `PATHEXT` can look like a missing
program - so those checks report `warning` and never `problem`, and say so.
`github` names the token's *source* and never runs `gh` to get one, which is
what lets it declare no cost at all; and `hook_commands` now reports that a
present `hooks.json` is not enabled for this session, because `--doctor` no
longer loads or fires hooks.

`/doctor` never re-reads a configuration file. Startup records a note wherever
it already prints a yellow warning - a bad deny rule, a settings refusal, a
hook or keys.json note, an MCP error, a style that no longer resolves, a
sandbox downgrade - and the check replays that ledger. Re-reading is how a
diagnostic becomes destructive: `LoadMcpConfig` calls `ClearMcpServers` as its
first statement, so "checking" `.mcp.json` would tear down every live server.

`/bug` writes a file and **uploads nothing**. There is no upload path in the
program, not a disabled one. The report goes to
`%LOCALAPPDATA%\pasclaude\reports\bug-<utc>.md`, falling back to
`%USERPROFILE%\.pasclaude\reports\`; with neither it refuses and writes
nothing at all - never into the project, where it would be committed by
accident. Out of tree also means `SafePath` refuses it, so the model's own
`read_file` cannot read the report back.

Included: a manifest of what is in and out, the pasclaude version, the FPC
version and target, the real Windows build (`RtlGetVersion` from `ntdll`, not
the 6.2 an unmanifested `GetVersionEx` reports forever), console codepages and
VT state, the whole `/status` report, the whole `/doctor` report, the note
ledger, and the counters. Excluded, and named as excluded in the file itself:
your prompts, the model's replies, tool inputs and outputs, file contents,
environment variable values, and the credential in any form. That last one is
structural rather than a promise - the token is never placed in the
diagnostic record at all, only the source word, whether it is an OAuth token
and when it expires, so `/bug` could not leak it even if every redactor
failed.

Secrets are redacted always, with no flag that turns it off: `sk-ant-…`,
long `sk-…`, anything after `Bearer`, and the value of any `NAME=` whose name
mentions KEY, TOKEN, SECRET, PASSWORD or CREDENTIAL. The *shape* survives -
`sk-ant-***` - because which kind of key it was is the one useful part.
Paths are redacted to `%USERPROFILE%`, `%LOCALAPPDATA%` and `<root0>`,
`<root1>`… unless you pass `--paths`, longest needle first so a nested
`--add-dir` root is replaced whole rather than left half-substituted, and
case-insensitively because Windows paths arrive in three different cases.
It is substring matching and the report says so: read the file before you
share it. `<root0>` is the session root - the path that names the project -
and the `--add-dir` extras follow it. `--transcript` writes your conversation to a
sibling file with a yellow warning that secrets are redacted and meaning is
not. That file is written, read back and rewritten redacted; if the read-back
or the rewrite fails - a scanner or a backup agent holding a file it has just
seen appear is the ordinary way - the transcript is **deleted** and the
failure printed, because the alternative is an unredacted conversation on disk
under a console message promising the opposite. Reports are
never deleted automatically - `/doctor` counts them past twenty and leaves
them alone, because a program that silently removes your evidence is worse
than one that accumulates files.

As flags, `--status` and `--doctor` run the whole of startup - including the
below-the-halt loads, because a status that cannot see the approvals file is a
lie - and then emit in place of the REPL. `--status` always exits 0;
`--doctor` exits 1 when any check is a problem and 0 otherwise (a warning and
a skipped check are not failures), so `pasclaude --doctor || setup` works in a
batch file. With `--output-format json` the payload is the object; with
`stream-json` it is one `{"type":"diagnostic","kind":"status"|"doctor",…}`
line, and the banner and startup notices are suppressed so stdout carries only
the protocol. That suppression is a property of the *output format* and not of
these two modes: any run that asks for `json` or `stream-json`, `-p` included,
gets the protocol and nothing else, because the loudest of those notices come
from a `settings.json` in the project tree and a cloned repository must not be
able to put a byte in front of a driver's parser. Nothing is lost - every
suppressed line is in the ledger `--doctor` prints. Both modes refuse to
combine with `-p`, a prompt, `--resume` or a driver - as do both `--ci` verbs,
which is why the exclusivity message now names three flags - and neither
approves or connects an MCP server: approving a spawn is a permission answer,
and a health check must not be a way to obtain one. They
are also the only two modes that continue past a missing credential or a
missing `winhttp.dll` and report it as one problem among fifteen instead of
exiting 2 - safe only because the branch ends in `Halt` and cannot reach a
turn or a tool.

## Tests

```
test             :: the five offline suites
test net         :: also the suite that talks to real servers
```

Six suites, all built with `-gh` so an unfreed block fails the run - JSON
ownership here is manual, so a leak is a defect rather than noise.

* `tests\smoke.lpr` - the JSON parser (escapes, surrogate pairs, malformed
  input, locale-proof number formatting, and the arrival-form memory the
  notebook path turns on - including the two assertions that the ordinary
  parser did not change for anyone who did not ask) and every tool, including
  the path guard and the deny-by-default permission path.
* `tests\stream.lpr` - recorded server-sent events replayed through the real
  decoder, delivered in 7- and 13-byte chunks so every line boundary and
  several JSON escapes are split across chunks. Covers text/thinking/tool
  blocks, reassembly of `input_json_delta` fragments, mid-stream error events,
  tolerance of unknown and malformed events, and the shape of the outgoing
  request body.
* `tests\loop.lpr` - the whole agent loop, driven through `TAgent.Send`
  against scripted responses with the transport substituted. A model asks for
  a tool, the tool really runs, its result is fed back, and the model answers:
  two- and three-round turns, parallel tool calls in one message, the round
  limit cutting off a runaway model, a mid-loop transport failure aborting the
  turn, a denied tool still letting the turn finish, conversation state
  persisting across turns and clearing on reset, cancellation mid-stream and
  mid-tool-call, and the retry policy (retried on 529, not on 400, giving up
  after `MaxRetries`).
  It also resumes a saved session into a fresh agent and runs a full turn from
  it, which is the only place restored history is checked against the code that
  builds requests rather than against the loader's own rules.
  A cancellation that lands before any content arrives is checked separately,
  because it reaches the same dangling-question state as a failed turn by a
  path where nothing reports an error.
* `tests\fuzz.lpr` - hostile inputs. Binary files and OEM-encoded shell output
  (the bytes that would otherwise make the API reject a whole turn), NUL bytes
  in JSON strings, path-guard escapes including a sibling directory sharing the
  root's name prefix, degenerate tool arguments, output caps, and a file whose
  contents impersonate the event protocol.
* `tests\ux.lpr` - the diff, the change previews, and compaction. The diff is
  checked on the cases that make a preview useful or useless: a one-line change
  reported as one add and one remove rather than a wholesale replacement, only
  the changed region of a 200-line file shown, two distant edits separated by a
  gap marker, CRLF files, the render cap, and the fallback past the LCS limit.
  The previews are driven through the real `RunTool` with a spy standing in for
  the user, asserting on what the prompt would have shown: the removed and
  added lines, a new file announced as new, a binary file summarised, and no
  prompt at all for an escaping path, a non-matching edit, or `/yolo`. It also
  asserts an approved edit applies exactly what was previewed. Compaction is
  checked for keeping the recent turns, dropping the old ones, never emptying
  the transcript, and never leaving an orphaned `tool_result` at the front.
  Persistence is checked by round-tripping a conversation, including a tool
  call with its result, and then by feeding the loader a series of files it did
  not write: missing, not JSON, not an object, no messages array, a future
  version, a
  transcript starting with the assistant, an unanswered tool call, a
  `tool_result` whose id does not match, an empty content array, an unknown
  role, and a block with no type. Each must be refused *and* leave the live
  conversation intact, which is asserted after all of them have been tried.
  Finally the line editor, whose decisions are separated from the console into
  `EditApply` so they can be driven directly: inserting mid-line, backspace
  versus delete, both caret boundaries, an empty line under every movement key,
  history recall including the half-typed line coming back, and a non-ASCII
  character counted and removed as one character rather than two bytes.

* `tests\net.lpr` - the transport, against real servers and needing no API
  key. TLS, a body that round-trips through an echo service, a response larger
  than one read buffer, aborting mid-transfer, rejection of non-https and
  unresolvable hosts, and the live Anthropic endpoint answering a generated
  request body with a structured `authentication_error`. It also feeds real
  wire bytes into the decoder, one byte at a time, to cover the seam between
  the two.

The suites were checked by mutation, not just by passing: reverting the
`input_json_delta` accumulator to an assignment fails 4 assertions, flipping
the permission default from deny to allow fails 1, disabling the chunk-callback
abort fails 2, capping the tool loop at one round fails 2, dropping the
transcript copy fails 1, treating every error as retryable fails 1, disabling
the cancelled-tool-call cleanup fails 1, and setting the wrong console codepage
fails 1.

Two of those mutations exposed tests that passed for the wrong reason. The
cancel-cleanup test fired before any tool block existed, so there was nothing
to clean up. The shell-encoding test only asserted the output was valid UTF-8,
which the ASCII-scrub fallback also satisfies - it now asserts the accented
character survives as `C3 A9`.

The newer code was checked the same way: making `ChangePreview` return nothing
fails 7 assertions, dropping the orphan check from the compaction cut point
fails 1, and removing the guard that stops compaction emptying the transcript
fails 2.

The session loader was checked the same way: accepting an unanswered tool call
fails 5 assertions, dropping the opening-role check fails 3, ignoring the
version guard fails 4, and - the one worth having - replacing the live
transcript *before* validating instead of after fails 2. That last mutation
leaves every "is it refused?" assertion passing, since the file is still
rejected; only the assertions about the conversation surviving a bad file
catch it.

Adding `--help` also exposed an older defect by accident. `Halt` skips the
`finally` block that restores the console, so any early exit left the caller's
terminal switched to UTF-8 - which then made the shell-encoding test in `fuzz`
fail, because under codepage 65001 `echo` emits the byte unchanged and there is
nothing for the conversion to do. Two bugs, one symptom: every early exit now
calls `TermDone` first, and the test pins the codepage itself rather than
inheriting whatever the shell happened to be on. It now passes identically
under 65001, 850 and 437, and still fails if the conversion result is
discarded.

Two defects in the session work were found by running the shipped binary rather
than the suites. Pointing it at the real endpoint with a bad key makes a turn
fail, and reading what autosave then wrote showed a transcript ending in the
user's unanswered question - resume it, ask again, and the conversation carries
two user turns in a row. Deliberately blocking the write afterwards showed the
second: an in-place `fmCreate` truncates before it writes, so a failure partway
through destroyed the previous good session as well. Both are fixed and
regression-tested, and removing the guard that spares a trailing `tool_result`
fails 3 assertions - the third being the loader refusing the file, which is the
corruption showing up where it would have hurt.

The line editor was checked the same way once its logic was separated from the
console: a backspace that deletes at the caret instead of before it fails 3
assertions, appending instead of inserting fails 1, giving `Delete` the caret
movement that belongs to backspace fails 1, and dropping the stash that holds
the half-typed line while history is browsed fails 2.

Completion got the same treatment: making `CompleteToken` fire when the shared
prefix adds nothing fails 1 assertion, and making it append instead of
replacing the token fails 6. The cache markers too: removing the system one
fails 1, the conversation one fails 1. Whether the live API honours the
markers is part of the standing no-key gap; the `/cost` counters exist so a
real session answers that at a glance.

The newest round: bypassing the path guard on @mentions fails 1 assertion
(the session file becoming mentionable), and a first draft of the glob change
failed its own test - `nope*.txt` still matched through the old extension
fallback, so a non-matching filter matched anyway; starred globs now match as
globs alone. One mutation survived and is worth recording: making each edit
hunk commit to the output as it applies is unobservable, because the caller
only reads the text after total success and discards it on any failure - the
atomicity the test pins lives at the call boundary, which is the boundary
that matters.

This round's additions were mutation-checked the same way. Making the retry
loop ignore `Retry-After` fails 1 assertion (the notice line reports the wait
actually used, which is how the choice is observable without measuring
wall-clock time). Breaking the restore path in `CompactWithSummary` fails 2 -
the byte-for-byte survival assertions, the same class of mutation as the
loader's validate-before-replace, and just as invisible to any "was it
refused?" test. Making `fetch` skip its permission gate fails 1, and zeroing
the prompt-token capture fails 1. The Ctrl+C handler is driven directly by
the test with synthetic events, since a suite cannot press the key.

The follow-on round: dropping the separator check from `BashPrefix` fails 6
assertions (chained commands riding an approved prefix is exactly the hole
the check closes), allowing any simple command through the bash gate fails
1, and saving history without its escapes fails 4 - a multi-line prompt
splits into several entries, which the round-trip assertions catch. The
first draft of the quote handling failed its own test: stripping quotes
before splitting on spaces broke `"C:\Program Files\Git\git.exe"` at the
space inside the path, so quoted names now run to the closing quote.

A third defect turned up the same way as the first two - by using the program
rather than reading it. `/clear` printed "conversation cleared" and left the
saved copy untouched, so `--resume` brought the whole thing back. For anything
cleared on purpose that is the wrong answer, so `/clear` now writes the cleared
state through to disk.

Two more came from asking where else the same mistake could hide. The trailing
unanswered question was fixed for a failed turn, but a cancelled turn reaches
the same state by another route - and a cancel is not an error, so the caller's
failure path never ran. Pressing Esc before the model had said anything left the
question dangling and saved it. The trim now happens inside `Send`, where every
cancellation path passes.

The last one was a question rather than a symptom: what do the tools see of
pasclaude's own state? Everything, as it turned out. `list_dir` showed
`.pasclaude`, `search` matched the transcript inside it, and `read_file` and
`edit_file` would open it. A search that returns the conversation feeds it back
into the next request, where it is saved and grows again. Disabling the path
guard fails 5 assertions, and removing the skip from `search` or from `list_dir`
fails 1 each.

Two more followed from the same habit. Hitting `MaxToolRounds` exits the loop
directly after `RunTools` appended a `tool_result` message that was never sent,
so the transcript ended on a user turn and the next question stacked behind it
as a second one - with the work those last tools did never reaching the model
at all. That tail is now unwound, repeatedly, because removing the results
strips the `tool_use` blocks they answered, which can empty the assistant
message and expose more results underneath. Disabling the unwind fails 2
assertions.

And running two instances in one directory showed the second destroying the
first's conversation on its first save. The banner had always warned that a
session existed, but warning happens before the damage and changes nothing.
The file is now moved aside first.

Asking the same question of the *failure* path found the eighth: a transport
error mid-loop aborts the turn at a point where tool results have been appended
and never sent, exactly as the round limit did. The unwind is now one method
used by both, and `Send` performs it on every exit that can reach that state -
failure, cancellation and the round limit - rather than relying on the caller.
Removing it from either call site fails assertions that name the shape
directly.

Not every hypothesis paid out, which is worth recording too. The saved session
looked like it might grow without bound, since compaction trims the transcript
in memory. It does not: compaction runs before the request and the save runs
after, so the file is written from the trimmed transcript. That is now asserted
rather than assumed - the file shrinks from 11288 to 2909 bytes across a
compaction, and resuming does not restore what was discarded.

Two more tests passing for the wrong reason turned up in that suite. Removing
the CR stripping from the line splitter changed nothing, because a stray `#13`
on both sides of a diff still compares equal: the counts stayed right while the
rendered diff would have carried a control character into the middle of the
prompt. It now asserts no carriage return reaches the output. The
empty-transcript guard was likewise uncovered until a case compacted to a
one-byte budget, which is the only way to reach it.

This round's five features were tested the same way, each in the suite that
can see it. `smoke` gained the regex engine driven directly - 47 match
assertions over literals, classes, anchors, `\b`, alternation, groups, case
folding and the counted repeats `^a{2,4}$`, `^(ab){2}$`, `^(a|bb){2,3}$`,
which are the highest-risk code in it - plus 10 malformed patterns that must
return an error rather than a match, two budget assertions, the job API
end to end (start, poll, poll again for nothing, kill, clear), and the
subagent gate: inside a raised depth the schema is exactly three tools and
`write_file` returns "not available to a subagent" *and* leaves no file on
disk. `ux` covers the walk depths (a ten-level tree found at `depth: 12`, a
`depth: 99` clamped to output byte-identical to `depth: 12`), the notebook
round trip against two fixtures nbformat itself wrote - one ASCII, one with
an accent, a CJK pair and two emoji outside the BMP that have to survive an
edit to a different cell byte for byte - and the
`/jobs` listing. `fuzz` covers the hostile half: `(a+)+$` over 60 characters
asserted to return in under two seconds, eight malformed patterns, a
truncated and a 1 MB-output notebook, nine job launches against a limit of
eight, an OEM-emitting job polled back as UTF-8, and agent-type names that
walk paths. `loop` covers the subagent's own request body (three tools,
`task` not among them, the parent's system prompt not inherited), its cost
folding, its round cap, cancellation across both agents, the `web_search`
declaration appearing only when asked for, `pause_turn` resuming, and a
rejected declaration disabling itself after one wasted request. `stream`
replays a `server_tool_use` block whose JSON is split mid-escape and asserts
the result block is echoed back byte for byte.

Mutation-checked in the usual form. For search: dropping both budget guards
in `uRegex` fails 1 assertion, dropping the UTF-8 check in the search walker
fails 2, emitting one repeat copy too many fails 2, defaulting `regex` to
true fails 1, and hard-coding either walker's depth back to its old constant
fails 1 each. Worth knowing before anyone simplifies one away: dropping only
*one* of the two budget guards fails nothing, because they mask each other.
For notebooks: dropping the space after `:` in `ToJsonPretty` fails 2,
removing the `PermitChange` call from the `notebook_edit` branch fails 2,
rendering output data by value instead of by size fails 4, and an off-by-one
in `InsertAt`'s shift loop fails 1 and leaks besides - 13 blocks in `smoke`,
52 in `ux` - because the overwritten child is never freed. For the arrival
form a notebook keeps: leaving `OpenDoc` on the ordinary `JsonParse` fails 4
in `ux`, and dropping the raw-control-byte clause from the capture test fails
1 in `smoke` - the assertion that a literal mixing a raw newline with an
escape is not reproduced, which is the only thing standing between us and
writing a notebook Python's `json` refuses to read. The gate itself was
checked the other way round too: making the ordinary `JsonParse` verbatim
fails 1 in `smoke`, 1 in `loop` and 6 in `fuzz` - request bodies and
round-trips, none of them notebooks, which is the evidence that the opt-in is
load-bearing and not decoration. One mutation deliberately survives and is
recorded so nobody hunts for the test that should have caught it: dropping the
`JsonQuote` comparison, so that every escaped literal is remembered rather
than only the ones a rewrite would change, fails nothing. It is a memory
optimisation and not a correctness one - a literal identical to what we would
write produces identical output either way - and it is commented as such in
`ParseString`. For background
bash: making `bash` ignore `run_in_background` fails 4, moving the
permission gate below the background fork fails 3, dropping the OEM
conversion from the spool reader fails 2,
leaving `ClearJobs` to forget the array without stopping the jobs fails 1,
and never advancing the poll offset fails 3. For web search: reverting the
`content_block_start` dispatch to the old `bkText` fallback fails 5,
removing the delta guard that blanks a truncated raw block fails 2, removing
`Send`'s `pause_turn` resume fails 2, removing the self-heal call fails 5,
and keeping `DropUnansweredToolCalls`' test as `type <> 'tool_use'` fails 1.
For subagents: disabling `RunTool`'s gate fails 3 - and the file the
subagent was refused actually lands on disk, which is the one that catches
the real hole - dropping `AbsorbUsage` fails 3, removing the `ForceCancel`
latch fails 1, leaving `Send`'s bound at the `MaxToolRounds` literal fails 2,
deleting `if SubDepth > 0 then Exit` from `ToolsSchema` fails 6, and
removing the agent-type character filter fails 6.

Reviewing that round found one bug in three places: a byte cap applied with
`Copy`, which cuts a multi-byte character in half. `uNotebook.Shorten` did it
to an output summary that goes straight to the model, `BackgroundJobList` did
it to the 57-character command column that `bash_output` returns, and `Clip`
- the 30 KB cap on every tool result - had always done it. The rule now lives
once, in `uJson.Utf8Cut`, because `uNotebook` sits below `uTools` and cannot
reach `IsValidUtf8`, so the bottom unit that already owns UTF-8
representation is the only legal common home. The same review found
`ReadJobChunk` returning nothing without advancing its offset when a running
job's chunk held no newline, so a job printing one line longer than the read
cap would repeat that nothing forever; a full buffer with no newline is now
handed over, cut at the last complete character. All four are regression-
tested and all four tests fail without the fix.

The extensibility round is tested the same way, in the suite that can see
each part. Two new seams carry most of it. `uMcp.McpWire` is a record of four
nil-by-default procedure pointers in the spirit of `uHttp.HttpTransport`; with
one installed, the framing, the handshake, pagination, both error channels,
junk, an unterminated line, an oversized request and the deadline all run
against scripted bytes with no child process at all, delivered in nine-byte
chunks so every frame arrives split across reads. Nothing shipped assigns it,
and a test says so out loud. The half a script cannot reach - real pipes, real
handle inheritance, real EOF, a real exit code, and a process that is genuinely
there and genuinely silent - runs against `bin\srvmock.exe`, a stand-in server
built by `test.cmd` whose misbehaviour is chosen by argument (`--hang`,
`--die`, `--junk`, `--crlf`, `--pages`, `--chatty`, `--big`, `--deaf`). It is
written against nothing but SysUtils and builds its JSON by hand, because a
fixture sharing our parser and our writer could not fail the ways a foreign
server fails; and it is built without `-gh`, because heaptrc's report on exit
would go down the same stdout the protocol is framed on. `uSdk.SdkSink` and
`SdkSource` are the other: the whole line protocol is driven with no process,
no pipe and no console.

`smoke` covers the primitives where the decisions are either true or not: the
child-process runner (stderr really merges, exit 2 survives cmd.exe, a
nonexistent program returns 1 and not 2, 200 KB of stdin to a child that never
reads it completes, nothing is left in `.pasclaude\tmp`); the hook loader; the
tool registry's six registration refusals and its dispatch; the MCP protocol
end to end through the scripted wire and once against a real `srvmock`; the
skill frontmatter reader and catalogue; plugin precedence through four
independent gates; and the SDK `init` line's inventory compared name-by-name
against a live walk of `ToolsSchema` rather than against a literal count, so a
feature adding a tool breaks nothing there. `fuzz` covers the hostile half:
hostile `.mcp.json` (traversing server names, a 5 MB config, `url` entries),
schema trust driven through `McpValidateTool` directly, real spawned children
with each misbehaviour flag, hostile `hooks.json`, hook behaviour under
megabytes of output and a blown deadline, skill names that walk paths with a
decoy planted at every traversal target, and the approvals store asserted to
live under `%LOCALAPPDATA%` and never inside the root - including that a
committed `.pasclaude\permissions.json` grants nothing through either loader.
`loop` covers the turn: a hook blocking a tool call and the transcript that
results, the Stop-hook continuation making exactly two requests, an MCP tool
appearing in the request body after the built-ins and round-tripping a call,
the same call denied still producing exactly one `tool_result`, and five SDK
tests over the protocol, per-turn usage, multi-turn driver input, permission
delegation and hostile driver lines. `ux` covers what a person meets: the
`/mcp` panel's six tab-separated columns, the hooks panel, and plugin state
round-tripping in *both* directions.

Mutation-checked in the usual form. For the transport: pretty-printing the
request instead of using the compact writer fails 11 assertions; abandoning a
timed-out connection instead of killing it fails 1; dropping the
peek-before-read guard fails no assertion at all - the suite simply never
returns, which is exactly the failure the design exists to prevent and is worth
recording as caught by a hang rather than by a red line. For the registry:
moving the source loop above the `SubDepth` cut in `ToolsSchema` fails 6,
dropping `(not IsMcp)` from the edits catch-all in `Permit` - the `/yolo` hole -
fails 3, and dropping the `try/except` from the dispatcher takes `smoke` down
with an unhandled exception, which is exactly what `RunTools` would do in
production. For hooks: moving `TakeHookAllow` above the nil-`Ask` check fails 2
(the single most important line in that feature, and it is pinned), dropping
the `PostToolUse` error marking fails 1, and removing the total entry cap fails
1. For skills: dropping the guard that stops a skill-free project advertising
the tool fails 9 in `smoke` and 4 in `loop`, `Copy` instead of `Utf8Cut` on the
description fails 1, treating EOF as the end of frontmatter fails 2, scanning
enabled plugins before the project fails 1, and copying the approvals file's
only-widen rule into the plugin state fails 3. For the SDK: replacing the
per-turn usage delta with the post-send snapshot fails 1, and making the
permission parser fall through to allow on an unrecognised verb and on EOF
fails 3.

Two bugs were found by the tests rather than by review. `TJson.Take(I)`
detaches by substituting a fresh null, so `Count` never falls and the obvious
move loop - `while Decl.Count > 0 do Push(Decl.Take(0))` - never terminates; it
allocated 5.3 GB before it was killed. Every append loop indexes over the fixed
length instead. And a mutation check exposed a fuzz assertion passing for the
wrong reason: it used `not McpAlive(C)`, which answers from the recorded state
and survived the mutant, and now asserts `McpConnectionCount = 0`, which only
falls when the connection was actually torn down.

The permissions round is tested the same way, and its tests are shaped by one
question: did the gate get *weaker*? Forty-five new procedures across `smoke`,
`fuzz`, `loop` and `ux`, plus `tests\sbxmock.lpr`, a fixture that reports from
*inside* a job object what only a child can observe - breakaway is refused with
ERROR_ACCESS_DENIED, and the process cap bites at 63 made plus
ERROR_NOT_ENOUGH_QUOTA, 63 because the fixture itself is the 64th. Like
`srvmock` it is built without `-gh`.

Four tests carry most of the weight, one per feature, and each of them stacks
every weakening the program offers and asserts the boundary still holds.
`TestDenyBeatsEverything` sets all four class blankets, a stored bash prefix
and an `Ask` that answers "always", and asserts `write_file`, `bash rm -rf x`
and `fetch` all refuse through `RunTool`, that `Permit` and `PermitBash` each
refuse directly, and that the `Ask` counter is still zero.
`TestPlanModeBeatsEverything` does the same with plan mode on top of bypass.
`TestDenyBeatsAddedRoot` adds the directory holding a `.pem`, turns on bypass
and `AllowAllEdits`, and asserts the rule still refuses. And
`TestSandboxDoesNotTouchTheGate` proves a counting `Ask` reaches the identical
decision the identical number of times at every sandbox level - the "sandboxed
commands need less approval" weakening this round must not make.
`TestDenyBeatsHookAllow` and `TestPlanModeBeatsHookAllow` run a real
`PreToolUse` hook that writes a marker file and echoes `{"decision":"allow"}`:
a positive control proves it fires for an ordinary call, then the boundary
refuses *and the marker is absent*, i.e. the forbidden call's arguments never
reached the repository's program.

The other half asks where a loosening could come *from*.
`TestDenyRulesNotFromProject`, `TestNoModeFromProject`, `TestNoRootFromProject`
and `TestSandboxLevelNotFromProject` each plant the relevant key in
`.pasclaude\permissions.json`, in a config file at the root, in `CLAUDE.md` and
in an environment variable, with `%LOCALAPPDATA%` pointed at a *sibling* of the
session root so a fixture that wrote inside the tree would test nothing - then
assert nothing changed, and that the real out-of-tree file does work, so the
loader is proven capable of the thing it is refusing.
`TestPrintModeInheritsNoGrants` pins the startup ordering: `LoadDenyRules`
alone brings the rules and not `AllowAllBash`, not the prefix table, not the
hooks fingerprint. `TestDenyRoundTrip` pins the hand-edited `"deny"` array
surviving a load and a save, unparseable line included.
`TestSdkSessionDoesNotInheritRoots` pins the embedder.

`ux` covers what a person meets - the mode indicator in all four modes and its
`+` suffix, the banner announcing a grant loaded from disk, `/add-dir`'s echo
of the resolved absolute path, `list_dir` on `.` byte-identical before and
after an add, a denied file invisible to `list_dir` *and* `search` *and*
`read_file`, the sandbox failure annotation, and a foreground timeout that
kills the grandchild rather than orphaning it. `loop` covers the wire: the
system array has two blocks with plan mode or a deny rule or an extra root in
play, the second carrying no `cache_control`, and exactly one block with
everything at its default.

Mutation-checked in the usual form. Dropping the `+ PathDelim` from
`WithinRoot` - the classic sibling-prefix bug - fails 42 assertions across
three suites, including the original path-guard assertion written years
earlier. Moving the plan check out of `RunTool` and into `Permit` fails 11, and
`bash` actually executes under the mutant because `PermitBash` is a different
function, which is the clearest available demonstration of why the check
belongs above the gate rather than inside one arm of it. Moving
`if BypassMode then Exit(True)` above the deny line in `Permit` fails 1 - only
one, because `RunTool` still catches the tool call, which is exactly why the
belt-and-braces assertion on `Permit` directly exists. Deleting the `[DENY]`
lines from `Permit` and `PermitBash` only fails exactly 2, and every `RunTool`
assertion still passes. Replacing `CanonicalPath` with `ExpandFileName` fails
2, and the junction assertions still pass - a junction leaves the base name
intact, so the 8.3 pair is what distinguishes "canonicalises" from "expands".
Deleting the deny `Continue` from the `search` walker alone fails 1 assertion
while `read_file` still refuses and `list_dir` still hides the file: the single
most damaging silent hole, and one test catches it. Deleting the deny
write-back from `SavePermissions` fails 2. Making `LoadPermissions` honour any
sandbox level from the file fails 3. Applying the state-directory check only to
root 0 fails 4, all in the two tests written for it and nothing else.
Inverting `SafePath`'s deny-as-fallthrough fails 11, four of them pre-existing
assertions with nothing to do with this round. Adding
`JOB_OBJECT_LIMIT_BREAKAWAY_OK` fails 2, and adding
`if SandboxLevel = slLow then Exit(True)` to `PermitBash` fails 3. Dropping the
`+` from the mode indicator fails 1, which is the exact failure this feature
exists to prevent.

A fifth sandbox mutation found a real bug rather than confirming a test.
Deleting the post-exit drain from `RunShell` failed nothing - which exposed
that the loop drained *before* testing for exit, so the trailing drain was
papering over a genuine race: bytes written between the drain and the exit test
were lost. The loop is now test-then-drain, correct by construction, and the
residual trailing drain serves only the kill path.

Review after the round found two more, both real. `PathForms` measured a
path's relative spelling against the primary root only, so an anchored rule
like `path:secrets/**` hid a file from `list_dir` and `search` in an added
working directory while `read_file` handed it over by absolute name - invisible
and fully readable, the worst possible pairing. It now measures against the
root that contains the file, primary first. And routing the three raw spawn
sites through `SandboxNewJob` had made the job object conditional on the
sandbox being on, so `/sandbox off` silently disabled tree-kill as well;
`SandboxNewJob` now always creates the job and configures nothing but
kill-on-close at `slOff`. Both are regression-tested, and the first was
verified to fail on the old code with the walker assertion still passing.

The input/output round is tested in the suite that can see each part, and its
tests are shaped by a different question: did anything reach the model, or the
gate, that the user did not put there? `smoke` pins the system prompt -
`SdkFullSystem` byte-identical with and without a style set, which is the
assertion a later "optimisation" moving style text inside cache breakpoint #1
has to fail; `SessionNote` empty at every default; the fence line ahead of the
plan paragraph and the deny sentence after both; a style whose frontmatter
carries `allowed-tools` and whose body reads "you may bypass plan mode"
reaching the prompt verbatim while every AllowAll flag, the permission mode,
plan mode, the sandbox level and the root count are unchanged; the request body
identical with vim off and with a loaded profile and vim on, and the string
`vim` absent from it; and `SdkDefaultOptions` checked field by field against a
deliberately dirtied stack. `ux` carries the codecs and the editor: CRC-32 and
Adler-32 against published vectors, every PNG chunk CRC recomputed, and the
three stored-deflate fields a decoder actually reads - BTYPE 0, NLEN as the
ones-complement of LEN, BFINAL on the last block only - asserted against the
format's rules rather than against a round trip through our own reader, which
is what makes them catch anything; a synthetic bottom-up 32bpp BI_BITFIELDS DIB
asserting the first output pixel is the top-left one and red rather than blue,
so the flip and the BGRA reorder are proved together; the vision documentation's
own token table; the four sniffers and BMP refused by name; images ordered ahead
of the text block and the ninth refused; an image block surviving `SaveSession`
and `LoadSession` through the real loader; `EvictImages` keeping the newest,
substituting rather than deleting, and leaving a transcript that still saves and
loads; the key grammar refusing `y`, `a` and `n` and reserving `ctrl+c`; and
`DecodeKey(KeysNone, ...)` resolving nothing however loaded the module var is.
`loop` covers the wire: two turns with a style set, both request bodies carrying
a second system block that holds the style body and no `cache_control` while the
first still carries exactly one and does not hold the style; a resume round trip
whose ordering assertion stats the session file at the instant the `result` line
is emitted; a corrupt transcript producing exactly `system;error;result`, exit
2, no turn run and the file on disk byte-identical; and a compaction with an
image queued, which had to move here from `ux` because the drain happens before
the request goes out. `fuzz` covers the hostile half: forty seeded random-byte
style files plus the usual truncations, each leaving `StyleNote` and
`SessionNote` valid UTF-8 and inside the cap; ~2400 truncations and bit
mutations of PNG, GIF, JPEG, WebP and DIB headers, where `DibToRgb` must either
refuse with a reason or return exactly `W*H*3` bytes inside `MaxImageDim` - the
guard against a clipboard header claiming 40000x40000; and nine session files,
one per `ValidTranscript` rule, each refused with the live conversation intact,
followed by the assertion that a `type:"image"` block is *accepted*, which is
what catches anyone adding a block-type allowlist to the load path.

Mutation-checked in the usual form. Reordering `SessionNote` to put the plan
paragraph before the style fails 1; replacing `Utf8Cut` with `Copy` at the style
cap fails 1 in `smoke` and 2 in `fuzz` on the euro-sign case; appending the
style to `SdkFullSystem` - moving it inside cache breakpoint #1 - fails 1, and
`loop` survives it, which is expected and by design, since `loop` builds its
agent with its own system string and never calls `SdkFullSystem`; dropping the
style from `SessionNote` entirely fails 6 across both turns of `loop`. Writing
NLEN as a copy of LEN fails 2, removing the DIB bottom-up flip fails 3, making
`EvictImages` keep the oldest fails 5, letting `CompactWithSummary` drain the
pending queue fails 2, and emitting the text block before the images fails 3.
Removing the plain-key refusal from `KeyChordOf` - the change that would let a
keys.json rebind `y`, `a` and `n` - fails 12; making `DecodeKey` read the module
var instead of its `P` parameter fails 2; making `WordEndFwd` land after the
word rather than on its last character fails 2; adding `ekChar` to `UndoWorthy`
failed only 1, which was a test too weak to be worth having, so it now asserts
the step count and fails 2. Turning `SdkResumeInto` into "a corrupt file is a
fresh start" fails 24 across three suites, and moving the session save from
before the `result` line to after it fails exactly 1 - the assertion written for
it and nothing else, which is what makes it a targeted test rather than an
incidental one.

Reviewing that round found four real defects, all in the half that touches the
outside world rather than in the arithmetic. `WordEndFwd` returned -1 on an
empty buffer through an early `Exit` that skipped its own clamps, and
`VimClamp` then indexed `W[0]` on a nil WideString; the empty-line answer is 0,
and `SegEnd` gained a defensive clamp so a negative caret from any future caller
cannot reach that index either. `/paste` of a copied *file* put the name from
the DROPFILES structure straight into a `TFileStream`, with no resolver at all -
it now goes through `ResolveInRoot`, the exported wrapper around the same
`SafePath` every `@`-mention uses. The local `width` and `height` keys were
being copied onto the request body by `BuildBody`'s deep copy, so
`StripLocalImageFields` now runs beside the `cache_control` fixup. And an image
was consumed by a turn that failed, because the queue is drained before the
request and both tail repairs then drop the message; `RequeueImagesFrom` puts
the blocks back and emits a notice, since silence was the real damage. Only the
`/paste` fix has no regression test, and it says so: `ClipboardImage` needs a
real clipboard and has no seam, and exporting the DROPFILES parse to get one
would be more surface than the fix.

The stored-deflate PNG and the DIB conversion were also verified out of suite,
against things a suite cannot reach. A probe emitted a 200x200 truecolour image
spanning two stored blocks; Windows Imaging Component decoded it at the right
size with the corner pixels matching the generated gradient, and Python's zlib
inflated all 120200 bytes with every chunk CRC validating. Then the real
clipboard: PowerShell's `SetImage` sets CF_BITMAP only, and the probe found
CF_DIB available anyway - confirming Windows synthesises it - with `biHeight`
positive, `biCompression` 3 and `GlobalSize` exactly 40 + 12 + pixels, which is
what pins the 12 mask bytes into the pixel offset. The encoded result decoded
through WIC with red top-left and blue top-right, so the flip and the reorder
are proved against a real clipboard rather than against a fixture we wrote.

**That decision is now reversed, and the reversal is the point.** This section
used to say the argument loop had no regression test and would not be getting
one: it was inline in `pasclaude.lpr`'s main block, interleaved with
`FailStart`, `Halt` and `SetCurrentDir`, no suite spawns the executable, and
extracting the whole loop into a seam was judged a larger refactor than a
one-line predicate warranted. The judgement was wrong, and the evidence that it
was wrong accumulated in three separate rounds of residuals - `--continue`'s
four refusals, whether `--no-project-context` was parsed at all, and which
`TDiagMode` values count as a `--ci` verb were each recorded as "main-block
code no suite can link" and each left there.

The loop is extracted. `uArgs.ArgsParse` takes an `array of string` and returns
a `TArgsOpts`; it writes no global, prints nothing, halts nothing and opens
nothing, and a refusal comes back in the record as a message, a hint and an
exit code. `smoke` drives it directly over argument arrays. What is pinned:
every flag and its value form, `--add-dir` repeating in both spellings, the
refusal messages **verbatim** - the words are the user interface, so the
strings are the assertion - the order-sensitive cases (`-p` not swallowing
a following flag, `--resume` refusing before `--continue` does, `plan` and
bypass contradicting whichever arrives first), and the property the host
depends on but could never show: that a refusal carries the output format
parsed *before* it and never one from past where it stopped, so
`--output-format json --bogus` still emits one JSON error line and
`--bogus --output-format json` still emits prose.

The count, because this paragraph got it wrong once and this is the section
whose whole job is to be right about coverage. `ArgsParse` has **43** refusal
sites. **41** can be produced by an argument list and all 41 are asserted word
for word. The remaining two - `--status, --doctor and --ci take no prompt` and
the same trio refusing `--input-format stream-json` - cannot be reached by any
command line, because `--print` is the only thing that fills the prompt and
`--input-format` without `-p` is refused higher up, so the `-p` refusals fire
first in both cases. They are kept as guards for a future flag, marked
unreachable at their sites, and stood in for by assertions on the *ordering*
that makes them unreachable. The earlier version of this paragraph said
"forty-two … verbatim"; fourteen refusals were in fact asserted nowhere, and
one entire flag, `--output-style`, was parsed by no test at all - its value,
its default and its refusal are all pinned now. A number nobody recomputes is
how a coverage claim goes stale, so the count now lives in `tests/smoke.lpr`
beside the assertions as well as here.

What is **not** pinned, and stays hand-verified against the built binary: the
help text, which is output rather than a decision and stayed in the host; and
the apply half - `DirectoryExists`, `SetCurrentDir`, `AddWorkingDir`,
`ResolveInRoot`, `SetOutputStyle` - which is where the disk starts and where a
pure function has to stop. The apply half is a column of plain assignments off
the record, deliberately, so it can be checked by eye. `--help`, `--bogus`,
`--output-format json --bogus`, `-p` with a json driver, `--status`, `--doctor`
and a `--ci prepare` over a fixture event were run against the binary after the
extraction and behave exactly as before.

`uHttp.HttpTransport` is the seam the loop suite uses. It is nil in the shipped
program, which is asserted by the network suite reaching the real API.

The live API has now been verified end to end through the subscription
token: a streaming 200, a real tool round trip (read a file, answer from
it), the cache counters reporting reads at a tenth rate, extended thinking
streaming its reasoning, and `/compact full` producing a genuine summary.
That run also caught a real defect the suites never could: the hardcoded
default model had been retired server-side (HTTP 404), which is exactly the
class of failure only live traffic reveals. The default is now a dated-less
alias (`claude-sonnet-4-5`) that tracks the current Sonnet.

That gap is wider than it used to look. `net` once claimed its 401 proved the
request body was well formed, on the theory that a bad shape is rejected as
`invalid_request_error` first. Checking that directly against the endpoint - an
empty `messages` array, a missing `max_tokens`, an assistant-first transcript -
returns `authentication_error` every time, because the key is examined before
the schema. So no keyless test can say anything about whether the API accepts a
transcript's *shape*; that is why the structural rules are enforced in
`LoadSession` and asserted offline rather than inferred from a live response.

The configuration round is spread across four suites on the same rule as
everything else - anything that asserts on a request body or drives a full turn
goes in `loop`, hostile documents go in `fuzz`, startup notes and whole reports
go in `ux`, and pure parsers and renderers go in `smoke`. `smoke` carries the
settings scope table, the DPAPI round trip (a blob that does not contain its
plaintext, a two-byte tail tamper refused, a value that was never a blob
refused), the six-source resolution order driven through a probe override, the
`ant` profile's five expiry encodings, the OTLP envelope a collector actually
validates - one `resourceMetrics`, exactly two resource attributes, every key
lowerCamelCase by recursive walk, every sum DELTA as the *number* 1, every
`asInt` a JSON string - the two telemetry filters, the endpoint rules with
`uAgent.ApiUrl` still parsing `Secure=True` on 443, and both diagnostic
redactors. `ux` carries the whole reports against driven state: `/status`
values asserted by *equality* against `uTools.PermModeName`,
`uTools.DenyRuleCount`, `uSandbox.SandboxLevelName` and `uTools.OutputStyleName`
rather than by string match, so a reimplementation in `uDiag` fails rather than
drifts; `/config`'s provenance rows; the writer preserving a hand-written
`permissions` block it is not allowed to honour; and a `/bug` end to end.
`fuzz` carries ten hostile settings documents, eleven hostile telemetry
configurations, a hostile credential file per malformed shape, 5000 tool calls
with 5000 distinct hostile names, and ESC/NUL/BEL/8 KB/truncated-UTF-8 strings
driven into every field a diagnostic renders. `loop` carries the parts only a
scripted transport can see: which model string each request actually carried,
the 401 refresh hook, `OnRequestDone`, and the assertion that building either
diagnostic report leaves the request count unchanged.

Four tests exist because they are the authority boundary rather than the
feature. `TestSettingsGrantsNothing` iterates `SettingDefs` and, for every
project-settable key, builds a synthetic project document setting only that key
and checks six authority variables are unmoved - so a new project-settable key
is covered the day somebody adds one.
`TestSettingsLocalHasProjectAuthority` pins that `settings.local.json` is
project class. `TestLogoutTouchesOnlyOurOwnCredential` writes real Claude
Code-, Jcode- and ant-shaped files, stores one of our own, clears it, and
asserts all three foreign files are byte-identical *and* were not even
rewritten with the same bytes (`FileAge` unchanged).
`TestDiagTakesNothingFromTheProject` refuses a project document naming `report_dir`, `redact`, `doctor` and `bug`,
and asserts the reports directory is outside every root by `uTools.WithinRoot`.

Mutation-checked in the usual form. Making `model` project-settable fails 10
assertions across `ux` and `smoke`; defeating the all-or-nothing gate so a file
with one bad value still stores the good ones fails 12; giving the local tier
user authority - the regression the design flagged as most likely - fails 5.
Dropping the `-` boundary from `ModelListMatches`, so `claude-opus-4` matches
`claude-opus-40`, fails 1; reverting the subagent to the parent's own model
fails 2; removing the `try/finally` that restores the role after a compaction
request fails 2, one of them the assertion that a *failed* compaction does not
strand the session on the compaction model. Widening `IsUnauthorized` from
`HTTP 401` to any 4xx fails 4; making `AuthClear` also delete Claude Code's
credential file - the single worst defect available in this feature - fails 4.
Emitting `aggregationTemporality` as the spec's enum *name* instead of the
integer fails 1, which is the failure a collector answers with an opaque 400
that nothing else would explain; dropping `TelemSafeModel`'s length and
`claude-` prefix tests fails 2; widening the loopback host test from exact
equality to a prefix match in both `SplitUrlEx` and `TelemValidEndpoint`, which
is the mutation that turns a narrow exception into a real vulnerability, fails
1. Removing the longest-first sort from `DiagRedactPaths` fails 2; replacing
`DiagLevelRank` with the raw enum ordinal in `DiagWorstLevel` - the mutant that
would make `--doctor` exit 1 for a check nobody ran - fails 1; anchoring the
`sk-ant-` pattern to position 1 fails 3.

Two of those exposed tests that passed for the wrong reason, and both are worth
recording. Making `AuthStore` skip `CryptProtectData` and store the key itself
- the exact silent fallback to unprotected storage the design forbids - was
**not** caught the first time, because base64 of a plaintext is not the
plaintext and the assertion was `Pos(Secret, Body) = 0`. It now asserts that
storing the same key twice produces a *different* file, because real ciphertext
is salted per call, and that the stored value is far longer than any encoding
of the key; the mutant then fails 1 deterministically. Anchoring the `sk-ant-`
pattern still did not put the planted token on disk, because the long-`sk-`
rule caught it as defence in depth - so the three failing assertions are the
ones about the key's *shape* surviving, which is the useful part of a redacted
report.

One mutation caught nothing and is reported rather than quietly dropped:
deleting the `if FAuthRefreshed then Exit` cap on the 401 refresh changes no
observable behaviour today, because 401 is not in `Transient()` and
`SendWithRetry` exits after the second `SendOnce` with or without it. The guard
is defence in depth against a future refactor that makes 401 retryable, and it
has no test because there is nothing yet to observe.

Two things in this round were verified against the built binary rather than a
suite, and say so. `/model opusplan` followed by `/mode plan` changing the live
model needs a real REPL. And `/bug --transcript`'s *failure* branch - where the
conversation file cannot be read back or cannot be rewritten redacted, and is
therefore deleted - needs a locked or unwritable file mid-call; forcing that
deterministically would need a filesystem seam in `uDiag` or a race against the
report's own timestamp, and a nondeterministic test is worse than none. What is
pinned instead is that the success path leaves the error string empty.

## Design notes

| Unit | Responsibility |
| --- | --- |
| `uJson` | JSON DOM: parse, build, serialise |
| `uImage` | image sniffing, visual-token cost, the stored-deflate PNG encoder |
| `uHttp` | WinHTTP POST with the body delivered in chunks |
| `uTerm` | UTF-8 console output, colour, line editor, key bindings |
| `uDiff` | line diff used to preview a change before it is approved |
| `uRegex` | NFA regex: compile a pattern, match a line, spend a budget |
| `uNotebook` | `.ipynb` cell view, cell edits, nbformat's exact layout |
| `uMcp` | MCP client: pipes or streamable HTTP, JSON-RPC, a deadline on every wait |
| `uHooks` | a child process with a deadline, the hook table, hook dispatch |
| `uSandbox` | the one spawn: job object, integrity level, scratch `%TEMP%` |
| `uSettings` | the key table, the scope question, the one writer |
| `uAuth` | which credential answers, and the file we alone may write |
| `uTelem` | OTLP counters, the two filters, the flush |
| `uTools` | the tool implementations, path guard, permission gate |
| `uAgent` | request building, SSE decoding, the tool loop |
| `uDiag` | status and doctor as records, both renderers, the redactors |
| `uSdk` | system prompt assembly, the NDJSON line protocol, the facade |
| `uArgs` | argv to a record: every flag, every refusal, no side effect |
| `pasclaude.lpr` | REPL, slash commands, rendering |

The ladder is strict: `uSandbox` -> `uJson` -> `uHttp` -> `uDiff`/`uRegex`/
`uNotebook`/`uMcp`/`uHooks`/`uSettings`/`uAuth`/`uTelem` -> `uTools` ->
`uAgent` -> `uDiag` -> `uSdk` -> `uArgs` -> `pasclaude.lpr`. `uHttp` moved out
of that group and below it when `uMcp` gained the HTTP transport: the two had
been peers, and one edge between them is what a second transport costs. It
creates no cycle - `uHttp` imports `Windows` and `SysUtils` and nothing of ours
- and it is worth stating rather than leaving to be inferred from a `uses`
clause, because the group is otherwise a set of units that genuinely cannot see
each other. `uArgs` is above
`uSdk` and `uCi` because one record has to name a `TSdkFormat` and a `TCiFloor`
at once, and those two units are peers that cannot see each other - so the
ladder did not merely permit the argument parser's home, it chose it. Being the
top unit below the program is the whole value: it is the last place a suite can
still link, which is exactly what the main block is not. Nothing in `src\` may
ever `uses uArgs` except `pasclaude.lpr`; a unit that tried would cycle and
fail to compile, which is the good outcome, and the unit's own header says so
in those words. Nothing at or below `uAgent`
knows the console exists. `uSettings`, `uAuth` and `uTelem` are leaves for the
same class of reason `uImage` is: each takes `uJson` and `SysUtils` and nothing
else of ours, so the scope table, the credential resolver and the payload
builder are all exercisable with no console, no network and - because
`SettingsParseTier` and `TelemParse` take bytes rather than paths - no
filesystem. `uDiag` sits above `uAgent` because it reads live counters, and
below `uSdk` so that `uSdk.SdkDiagnosticLine` adopts an already-built JSON
string the way `SdkToolUseLine` does and `uSdk` gains no dependency on it.
`uHooks` sits below `uTools` and so cannot call it, which is why the UTF-8
family - `IsValidUtf8` and `OemToUtf8` - moved down into `uJson` beside
`Utf8Cut`, with one-line forwards left in `uTools` so every existing reference
still compiles. `uSandbox` is at the bottom for the same class of reason: it
imports `Windows` and `SysUtils` and nothing else, because a spawn shared by
`uHooks`, `uMcp` and `uTools` is only expressible below all three - which is
exactly why the job-object declarations used to be copied verbatim into each
of them. Adding `uses uJson` there creates the cycle the ladder exists to
prevent. `uImage` is a leaf for the same class of reason from the other
direction: it imports `SysUtils` and nothing else, so every parser in it is
exercisable without a clipboard, a console or a DOM, and `uAgent` is the first
unit that knows both what an image is and what a message is. `uTerm` now uses
`uJson` in its *implementation* only, to parse `keys.json`; `KeysParse` takes
bytes rather than a path, so `uTerm` still reads nothing off disk but history.

Details worth knowing if you touch this code:

* **Colour goes out as ANSI escapes when the console accepts VT
  processing,** and through `SetConsoleTextAttribute` when it does not (an
  old conhost). `TermInit` asks for
  `ENABLE_VIRTUAL_TERMINAL_PROCESSING` and remembers the answer; on the VT
  path a coloured span is one write instead of three round trips. The mode
  is restored at exit because the flag is process-wide on shared consoles.

* **The tool loop is the whole point.** `TAgent.Send` posts the transcript,
  and if the reply contains `tool_use` blocks it runs them, appends the
  results as a user message, and posts again - up to `MaxToolRounds`. A turn
  ends only when the model stops asking for tools. `tests\loop.lpr` runs that
  cycle end to end against scripted responses.
* **Everything sent to the model must be valid UTF-8.** A tool result travels
  as a JSON string, and one invalid byte makes the API reject the entire
  request, losing the conversation rather than just the tool call. Binary files
  are shown as a hex dump, and shell output is converted from the console
  codepage. Note that FPC's `CP_OEMCP` is the RTL's own marker value, not a
  Windows codepage id, so `GetConsoleOutputCP` has to be asked instead - and
  UTF-8 bytes must be copied into a `string` one at a time, because assigning a
  `UTF8String` makes the compiler convert them straight back.
* **Cancellation keeps the transcript legal.** Esc aborts the stream, but the
  API rejects a request whose assistant message contains a `tool_use` with no
  matching `tool_result`. Those blocks are stripped on cancel, so the next
  question still works.
* **Content blocks are assembled outside the JSON DOM.** They stream as
  start/delta/stop triplets keyed by index, and `TJson` has no setters, so
  `uAgent` accumulates plain strings in an array and builds the message once.
  Tool arguments arrive as `input_json_delta` fragments that are only valid
  JSON once the last one lands.
* **Numbers are serialised with an invariant decimal point.** `FloatToStr`
  honours the locale, and on a machine set to a comma separator the request
  body would be malformed JSON.
* **`WriteConsoleW` fails on a redirected handle,** so `RawWrite` falls back
  to the plain stream. That is what makes `echo /help | pasclaude` work.
* **Permission defaults to deny.** `RunTool` takes a nil `Ask` in tests and in
  any non-interactive context, and a nil ask means no. Even a denial produces
  a `tool_result` carrying the refusal, both because the API demands one and
  because it lets the model react rather than retry blindly.
* **Thinking blocks carry a signature** that has to be echoed back verbatim
  on the next request, so it is captured from `signature_delta` and stored
  alongside the text.
* **Compaction has to leave a legal transcript.** Dropping the oldest messages
  is easy; the constraint is that a request must open with a user message, and
  a `tool_result` is only valid directly after the assistant message whose
  `tool_use` it answers. The cut point is therefore walked forward past any
  assistant turn and any tool-result message, and refuses to empty the
  transcript entirely - a session with nothing left to send cannot recover.
* **A diff is only worth building if someone will read it.** `PermitChange`
  skips the file read and the LCS entirely when the answer is already known,
  which is every tool call under `/yolo`. The diff is also taken against the
  file on disk rather than against whatever the model assumed, so an approval
  is a decision about the change that will actually be made.
* **The LCS table is quadratic**, which is fine for source files and ruinous
  past a few thousand lines, so `uDiff` falls back to reporting a whole-file
  replacement rather than allocating a table nobody benefits from.
* **A session is validated before it replaces anything.** The obvious order -
  load, then check - leaves a rejected file having already destroyed the
  conversation in progress. `LoadSession` parses into a scratch document,
  validates it, and only then swaps it in, so a refusal costs the user nothing.
  The mutation that reverses those two steps is the one a test suite is most
  likely to miss, because every assertion about the file being *refused* still
  passes.
* **`Halt` skips `finally`.** The console codepage is switched at startup and
  put back by `TermDone`, so every early exit has to call it explicitly or the
  user's terminal is left on UTF-8 after the program is gone.
* **A byte cap is not a character cap.** Every place that truncates text
  bound for the model - `Clip`, the notebook output summary, the job
  listing's command column - goes through `uJson.Utf8Cut`, which backs up to
  a character boundary. A plain `Copy` can leave a lead byte with no
  continuation, and one such byte makes the API reject the whole request.
* **The regex engine may not backtrack.** `uRegex` is an NFA simulation
  because a tool call has no clock above it: nothing in `uTools` can
  interrupt a compute loop, so a pattern's cost has to be bounded by
  construction rather than watched. Any change that introduces
  backreferences or lookaround reintroduces the exponent that the whole unit
  exists to avoid.
* **`uJson` values are mutable now, by convention only.** `SetAt` and
  `InsertAt` were added so `notebook_edit` can change one cell without
  cloning a document whose megabytes are exactly what it is trying to
  preserve. The DOM was already structurally mutable through `Take`/`Drop`;
  this is the missing third operation. Ownership rules are unchanged - the
  parent owns its children, and `SetAt` frees the value it replaces.
* **A background job's output goes to a file, never a pipe.** An undrained
  anonymous pipe blocks its writer forever, and for a detached command
  undrained is the definition rather than the risk. The per-job read offset
  must advance by exactly what was handed back: repeat it and the model sees
  the same output twice, skip it and those bytes are gone for good.
* **A subagent's toolset is enforced in `RunTool`, not in the schema.** The
  schema is advice to a model; `RunTool` is the boundary, and the check sits
  above every `Permit` call so a `/yolo` session or a persisted "always"
  cannot reach past it. The read-only rule is also what makes it safe for
  two agents to share `uTools`' module-level state, so widening it is not a
  local change.
* **`ForceCancel` is a latch, not a poll.** `CtrlCPressed` consumes its flag
  as it answers, so whichever agent asks first eats the user's Esc. Every
  cancellation check goes through `WantsCancel`, which tests the latch
  first, and only a top-level turn clears it.
* **A server-side content block is echoed verbatim.** `bkResult` stores the
  block's own JSON from `content_block_start` and replays it unchanged,
  because a block this client does not understand is one it cannot correctly
  rebuild - and it is the fallback for every unrecognised type, so the next
  one the API ships costs nothing.
* **`Send` owns the transcript's shape.** Three different exits - a transport
  failure, a cancellation, and the round limit - can each leave tool results
  the model never saw, or a question nothing answered. Putting the cleanup in
  the caller only fixed the one path the caller could see; it lives inside
  `Send` so every exit passes through it.
* **No built-in tool name may contain `__`.** That is what makes a registered
  source's prefix rule (`^[a-z][a-z0-9_]*__$`) a structural guarantee rather
  than a check against a list that grows: a source cannot shadow a built-in,
  and adding a thirteenth built-in does not require revisiting the rule.
* **The tools array must not change between turns except at an explicit user
  command.** `tools` renders before `system` under one `cache_control`
  breakpoint, so any change to the tool list invalidates the entire prompt
  cache - system prompt included - on every turn afterwards. MCP freezes its
  list for the session and reports a `list_changed` rather than applying it;
  the skill catalogue is cached and invalidated only by `RefreshSkills`, which
  the host calls at startup, `/clear`, `/skills` and after a plugin is enabled
  or disabled.
* **Registered sources are declared below the subagent cut, and the cut is an
  `Exit`.** That is why a subagent is never told about a source's tools no
  matter who adds the next append site, and why the "only one append site"
  rule was not needed. `RunTool`'s three-name allowlist refuses the call
  independently.
* **A tool source's handler is wrapped in `try/except`.** `uAgent.RunTools`
  does not catch, so an exception escaping a source would skip the
  `tool_result` the API requires and leave a transcript that cannot be sent.
  A source is third-party code; the dispatcher is the boundary.
* **The hook allow-flag is read once and sits below the nil-`Ask` check.** Its
  position in `Permit` is load-bearing, not stylistic: three properties fall
  out of it with no separate guard - print mode cannot be widened, a subagent
  cannot be widened, and the flag is reachable only where a human was about to
  be asked anyway. Anyone adding a fifth approval class adds it *above* those
  lines, with the other class tests, and must also exclude itself from the
  edits catch-all or it silently inherits `AllowAllEdits`.
* **No MCP wire wait exists outside `McpAwait`, and no write outside the send
  loop.** Both peek before they touch the pipe and both carry a deadline. A
  server is a third-party program; "it cannot hang us" has to be one
  function's postcondition rather than a discipline spread across call sites.
* **The approvals file lives outside the project.** It records what the user
  let *this project* do, so a project that could ship its own copy would be
  answering its own question. When no home directory is set there is no store,
  which means approve-nothing - never a fall back into the project. It now
  holds three polarities: the grants widen only, `deny` narrows only, and
  `sandbox` raises only. Each direction is the safe one for a stale file, and
  they must not be collapsed into one rule.
* **`.pasclaude\plugins.json` is authoritative in both directions**, unlike
  the approvals file, which only ever widens. A disable that did not survive a
  restart would be a consent bug nobody could diagnose. Both files carry a
  comment saying they have opposite semantics and why.
* **Deny is the first line of every gate, and `BypassMode` is the second.**
  `RunTool` refuses a denied call before the hook fire; `Permit` and
  `PermitBash` each repeat the check at the top, so a fifth gate added later
  cannot be talked into a yes and a reader sees deny-first without trusting
  the caller. `BypassMode` sits below those lines and in a different function
  from the `RunTool` checks, which is the cheapest available proof that no
  mode reaches around a rule. Anyone adding a gate copies both lines - that is
  a copy-paste rule on purpose, not a memory test.
* **Plan mode is a boundary, not a gate setting.** It is enforced in
  `RunTool`, beside the subagent read-only list and above the `PreToolUse`
  fire, so bypass, a class allow-all, a stored bash prefix, a hook's allow and
  a nil `Ask` are all structurally unable to lift it. Inside `Permit` it would
  have sat below the short-circuits it needed to beat. There is deliberately
  no `exit_plan_mode` tool: a tool that lets the model leave plan mode is a
  tool that lets the model grant itself write access.
* **There is exactly one path resolution base, however many roots there are.**
  A relative or rooted path always means the primary root, so `--add-dir` can
  only make a previously-refused absolute path succeed and can never re-point
  `src\main.pas` at another tree. The escape comparison lives only in
  `WithinRoot` and compares against `Root + PathDelim`; anyone who needs "is
  this inside that" calls it rather than writing a prefix compare. The deny
  check runs once, outside the root loop, on the winning candidate - inside it
  the answer would depend on which root was named first.
* **An added working directory contributes no code and no configuration.**
  `SkillsDirProject`, `HookRoot`, `AgentsDir`, `McpConfigPath`,
  `ResolveExtensionFile` and `SdkProjectContext` all read `NormalizeRoot` and
  each carries a comment saying why. Generalising any of them to scan every
  root turns `--add-dir` into a way to make an arbitrary directory execute
  what it ships, which is a far larger grant than the flag's words.
* **The sandbox is never consulted by a permission decision.** No gate reads
  `uSandbox.SandboxLevel`, and the level does not decorate an approval
  prompt's detail either. The reason is a measurement rather than a principle:
  a Low-integrity child still reads the whole user profile and still reaches
  the network, so a boundary that stops writes and stops nothing else cannot
  buy an approval discount.
* **`SessionNote` is one function, one trailing block, and empty by default.**
  The output style, plan mode, the extra roots and the deny sentence are
  appended in that fixed order as a second `system` content block carrying no
  `cache_control` marker of its own, after the marked one - so turning any of
  them on costs a few dozen tokens rather than the whole cached prefix. With
  the default style, one root, `ask` mode and no rules it returns `''`, no
  second block is emitted, and the request body is byte-identical to what it
  was before this round. The style is first because it is the only text here a
  file chose rather than pasclaude's own state; the deny sentence is
  permanently last because it is the one line describing an unbypassable
  refusal, and anything added later inserts before it rather than after. The
  deny *patterns* and the sandbox level are deliberately absent: naming `.env`
  advertises a target, and a model told it is sandboxed routes around the
  sandbox.
* **An output style is text with no consumer, and that is the enforcement.**
  Nothing reads a style body but one string concatenation in `SessionNote`, and
  no frontmatter key maps to any setting, so there is no parse step for a
  hostile file to aim at. The corollary is a rule rather than an observation:
  nobody may make a style key mean something. The name and the source it
  resolved from are both persisted, so a project file appearing later cannot
  inherit consent given to a user file of the same name.
* **`TAgent` still has no setter for its system prompt.** Its immutability is
  what makes cache breakpoint #1 worth having, and it is the seam every feature
  that wants to change the prompt mid-session will reach for. Anything session-
  mutable goes in `SessionNote`'s uncached block instead. Anyone adding one
  revisits that decision explicitly rather than inheriting it.
* **An image block is a plain object in `FMessages`, not a block kind.** The
  decoder was not taught about images because the model does not emit them;
  `bkResult`'s passthrough already handles a type this client does not
  understand. Images live only in `user` messages, never in a `tool_result` -
  `RunTool` returns a `string`, and lifting that is three units moving in
  lockstep for a result no human is looking at.
* **`width` and `height` are ours and must never reach the wire.** They exist
  so a resumed transcript can be described without decoding base64, and the
  Messages API rejects a content block carrying a key it does not know, so
  `StripLocalImageFields` removes them from `BuildBody`'s copy beside the
  `cache_control` fixup. Any local-only key added later goes in that one list.
* **`ValidTranscript` has no block-type allowlist and `SessionVersion` stays
  1.** An image block passes today because the rules are structural - an object
  with a non-empty `type`, and a `tool_use` answered by a `tool_result`. Adding
  a type whitelist would make already-saved image sessions unloadable, which
  under `--session-file` is a hard exit 2 for a script.
* **Eviction substitutes, it never deletes.** `EvictImages` replaces an image
  block with a text placeholder rather than removing it, because an emptied
  content array is exactly what the session loader refuses, and a measure that
  saves context by producing an unloadable session has made things worse. It
  runs before both compaction branches: base64 is re-sent in full every turn, so
  without it the byte trigger fires forever against a transcript it cannot trim.
* **A drained image queue has to be put back when the turn is dropped.**
  `AppendUserText` drains before the request, and both tail repairs delete that
  message, so `RequeueImagesFrom` runs at both sites and emits a notice. Silence
  was the defect: the user had been told the image goes with their next message.
* **A `TSdkOptions` is only ever built by `SdkDefaultOptions`.** FPC initialises
  only the managed fields of a local record, so a Boolean added to that record
  reads stack garbage at every hand-rolled construction site - and the field
  most likely to be added next is another one that means "resume" or "trust".
* **`ReadLineCore` takes its key profile as a parameter and reads no module
  var.** `ReadPromptLine` supplies `PromptProfile` and is called once, by the
  REPL; `ReadLineEdit` supplies the constant `KeysNone` and is what every other
  prompt in the program uses, permission included. That plus the chord grammar
  (no plain character is nameable) and the action set (`TEditKey` only, and
  `ekChar` has no name) is why a `keys.json` cannot answer a permission
  question. A non-editing action added to the name table breaks the third
  mechanism; such a chord belongs in `ReadLineCore`'s fixed key section and in
  `KeyChordReserved`, so no file can shadow it.
* **`Redraw`'s `PrevLen` is total painted width, not text length.** The vim
  indicator is painted by `EditLead` ahead of the prompt, so the erase loop has
  to clear a four-character lead that disappeared; the append fast path is
  `Inc(PrevLen)`. Anything else ever added to the painted line goes through
  `EditLead` and respects that meaning.
* **A user-scope config file is loaded because it is the USER's, never because
  it is inside a root.** `%USERPROFILE%\.pasclaude\hooks.json` and
  `mcp.json` are trusted without a prompt on exactly that argument - they live
  outside every root, so no clone ships one, and `.pasclaude` is refused at the
  top of every root including added ones. The added-root promise ("it grants
  file access and nothing else") is untouched by this: `--add-dir
  %USERPROFILE%` does not make either file executable configuration for that
  directory, it just makes the *other* files there readable. Anything that
  starts resolving these two by walking roots has inverted the argument.
* **Every new path under `.pasclaude` bypasses `SafePath` and must say so.**
  `SafePath` refuses that directory by design, so the substitute guard is the
  established one and no feature may invent a second: filter the bare name for
  `\ / : .` and control characters, then construct the directory part.
* **`SettingsStore` is the only writer of a setting, and `TierAllowed` is the
  only question it asks.** A second writer, or a second call site, is the
  entire bug this design exists to prevent - the reader side is safe only
  because it cannot see anything the writer refused. The tier walk starts at
  each key's *lowest permitted* tier, so a project value for a user-scope key
  is unreachable rather than merely unread; there is no filter for a later
  refactor to drop. New keys are added by growing `SettingDefs`, which is
  exactly why the `Scope` column has to be filled in at the same moment: the
  load position above the print-mode halt is legal only because nothing in
  that table can grant.
* **A project-class tier may only move a number toward the cheap side of the
  value the *user* has in force.** `Dflt` and `Cheap` are columns in the table
  rather than a comparison written at the call site, because the version that
  compared against the key's own maximum was not the rule at all: it let a
  clone raise a compiled `thinking_budget` of 0 to 8192 and more than double
  the tool-result cap. `ProjMax` is a cap on top of that invariant and is not
  the invariant. There is deliberately no clamp in `ApplySettings` - a second
  opinion on the same question drifts.
* **No function in `uAuth` that opens a file for writing takes a path
  parameter.** `AuthStore` and `AuthClear` compute `CredentialStorePath`
  internally, so they can name no file but pasclaude's own. Claude Code's,
  Jcode's and the `ant` CLI's credential files are read forever and written
  never, and that is enforced by the signatures rather than remembered by the
  bodies. If a store path cannot be computed out of tree, the answer is to
  store nothing, never to fall back into a root.
* **The token is never placed in the diagnostic record.** `DiagFacts` carries
  the source word, whether it is an OAuth token, whether one is present and
  when it expires - and nothing else - so `/bug` could not leak a credential
  even if every redactor failed. Redaction is defence in depth on top of that,
  not the mechanism.
* **Both diagnostic renderers are pure in their record and take nothing
  else.** `DiagStatusText`/`DiagDoctorText` and `DiagStatusJsonObj`/
  `DiagDoctorJsonObj` cannot reach `TAgent`, `uTools`, the filesystem or the
  console, which is what makes it impossible for the console view and the JSON
  view to disagree - the classic way a bug report drifts from the status it
  claims to quote. `/doctor` replays a note ledger rather than re-reading
  configuration for the same class of reason: `LoadMcpConfig` calls
  `ClearMcpServers` as its first statement, so "checking" `.mcp.json` would
  tear down every live server.
* **`SplitUrl` is unchanged and https-only; the loopback exception lives in
  `SplitUrlEx`.** Every request in the program goes through that parse, and a
  wrongly-derived flag would mean an Anthropic request attempted without
  `WINHTTP_FLAG_SECURE`. The safest form of the edit is one that cannot reach
  the existing contract at all, and a test asserts `uAgent.ApiUrl` still parses
  as secure on 443. `HttpTimeoutMs = 0` must keep the 300-second receive
  default, or a streamed turn starts timing out mid-answer.
* **Anything a settings file or a `.mcp.json` can name is filtered before it
  is sent or printed.** `TelemBucketTool` and `TelemSafeModel` collapse a tool
  or model name to a compile-time vocabulary because both arrive from files
  that come with a clone; `SettingClean` strips control characters and cuts to
  240 bytes because a key name of `ESC[2J` would erase the security warnings
  printed above it and a TAB would shift the fields of a tab-separated row.
  Neither is a comment asking people not to do it.
* **Startup notices go through `StartupNote` and are text-format only.** Under
  `--output-format json` or `stream-json`, stdout carries the protocol and
  nothing else - the loudest of those notices come from a `settings.json` in
  the project tree, and a cloned repository must not be able to put a byte in
  front of a driver's parser. Nothing is lost: every suppressed line is in the
  ledger `/doctor` prints.

## License

MIT.
