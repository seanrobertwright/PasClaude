# pasclaude

A terminal coding agent for Windows, written in Free Pascal. It talks to the
Anthropic messages API, streams the reply as it arrives, and lets the model
read, search, edit and run things in your project - asking before anything is
changed.

No dependencies beyond the FPC RTL: HTTPS is WinHTTP bound at runtime, JSON is
a small DOM in `uJson`, and the console is driven through the Win32 API.

```
pasclaude 0.1
  E:\Projects\pascal\pasclaude
  claude-sonnet-4-5
  /help for commands, /exit to quit

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
bin\pasclaude.exe [directory] [--resume]
```

Without a key, a Claude subscription works instead: if Claude Code has been
signed in on the machine, its OAuth token
(`%USERPROFILE%\.claude\.credentials.json`) is picked up automatically and
the banner says `(subscription)`. The token is read, never written -
refreshing it is Claude Code's job, and this program does not touch another
program's state. An explicit `ANTHROPIC_API_KEY` always wins, because
setting a variable is a deliberate act and borrowing a token is not. Under
OAuth the request authenticates with a Bearer header and its beta flag, and
the system prompt opens with Claude Code's identity line, which the API
requires verbatim; ours follows unchanged, cache breakpoint included.

The directory argument (default: the current one) becomes the *session root*.
Every path the model asks for is resolved against it and refused if it would
escape, so the agent cannot wander into `C:\Windows` because it misread a
relative path.

If the project contains `AGENTS.md`, `CLAUDE.md` or `.pasclaude.md`, the
contents are appended to the system prompt as binding instructions.

## Commands

| Command | Effect |
| --- | --- |
| `/help` | list the commands |
| `/clear` | forget the conversation, here and on disk |
| `/compact` | drop the oldest turns, keep the recent ones |
| `/compact full` | replace the transcript with a model-written summary |
| `/diff` | list the files this session has changed |
| `/think [n]` | extended thinking: on, off, or a token budget |
| `/resume` | reload the saved conversation |
| `/save` | write the conversation now |
| `/cwd` | show the session root |
| `/model [name]` | pick a model from a live list, or set one by name |
| `/yolo` | approve every tool for the rest of the session |
| `/cost` | turns and tokens used |
| `/exit` | quit (Ctrl+C also works) |

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
the line.

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

`Tab` completes: slash commands at the start of the line, file and directory
names anywhere else, resolved against the session root. Several matches extend
to their common prefix; directories complete with a trailing `\` so another Tab
descends. Pasting a multi-line block keeps its line breaks as one prompt
instead of firing a request per line, and `Ctrl+Enter` inserts a break by hand.

`@path` in a prompt attaches that file to it: the model starts with the
contents instead of spending a tool round reading them. Mentions face the same
path guard as tool calls - no escaping the root, no reaching the session state
- and a binary or oversized file is reported rather than attached. Tab
completes paths after the `@` too.

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
is already on disk. `--resume` picks it up at startup, `/resume` does it later,
and `/save` forces a write.

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

Starting in a directory that already holds a session, without `--resume`, moves
that session to `session.prev.json` before anything can overwrite it. Two
windows open on one project is not exotic, and the second one used to destroy
the first's conversation on its very first save.

## Tools

| Tool | Approval | Notes |
| --- | --- | --- |
| `read_file` | no | line-numbered, capped at 400 KB, hex dump if not text |
| `list_dir` | no | skips `.git`, `node_modules`, `.pasclaude` and `.gitignore`d entries, max depth 4 |
| `search` | no | case-insensitive content search, `*` globs, respects `.gitignore`, capped at 200 hits |
| `write_file` | yes | creates intermediate directories |
| `edit_file` | yes | one hunk or several at once; all must match or none apply |
| `bash` | yes | `cmd.exe /C`, output merged, 120 s timeout |
| `fetch` | yes | HTTPS GET, capped at 200 KB, own "always" class |

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

`fetch` reaches the outside world, so it asks - and its "always" answer is
its own class, separate from the edit tools, because approving edits forever
should not quietly approve network access too. Only `https://` URLs are
accepted, the response is cut at 200 KB during the transfer rather than
after it, and a body that is not valid UTF-8 is scrubbed rather than
hex-dumped: a page in another encoding is still mostly readable text,
unlike a binary file.

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

## Tests

```
test             :: the five offline suites
test net         :: also the suite that talks to real servers
```

Six suites, all built with `-gh` so an unfreed block fails the run - JSON
ownership here is manual, so a leak is a defect rather than noise.

* `tests\smoke.lpr` - the JSON parser (escapes, surrogate pairs, malformed
  input, locale-proof number formatting) and every tool, including the path
  guard and the deny-by-default permission path.
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

## Design notes

| Unit | Responsibility |
| --- | --- |
| `uJson` | JSON DOM: parse, build, serialise |
| `uHttp` | WinHTTP POST with the body delivered in chunks |
| `uTerm` | UTF-8 console output, colour, line editor |
| `uDiff` | line diff used to preview a change before it is approved |
| `uTools` | the tool implementations, path guard, permission gate |
| `uAgent` | request building, SSE decoding, the tool loop |
| `pasclaude.lpr` | REPL, slash commands, rendering |

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
* **`Send` owns the transcript's shape.** Three different exits - a transport
  failure, a cancellation, and the round limit - can each leave tool results
  the model never saw, or a question nothing answered. Putting the cleanup in
  the caller only fixed the one path the caller could see; it lives inside
  `Send` so every exit passes through it.

## License

MIT.
