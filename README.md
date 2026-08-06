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
  claude-sonnet-4-20250514
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
set ANTHROPIC_MODEL=claude-sonnet-4-20250514   :: optional
bin\pasclaude.exe [directory]
```

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
| `/clear` | forget the conversation so far |
| `/cwd` | show the session root |
| `/model [name]` | show or change the model |
| `/yolo` | approve every tool for the rest of the session |
| `/cost` | turns and tokens used |
| `/exit` | quit (Ctrl+C also works) |

Pressing `Esc` while a reply is streaming stops it. Whatever arrived is kept,
any tool the model was about to call is not run, and the conversation stays
usable for the next question.

Transient failures (429, 529, 5xx) are retried up to three times with a
widening delay, and the wait is interruptible.

## Tools

| Tool | Approval | Notes |
| --- | --- | --- |
| `read_file` | no | line-numbered, capped at 400 KB, hex dump if not text |
| `list_dir` | no | skips `.git` and `node_modules`, max depth 4 |
| `search` | no | case-insensitive content search, capped at 200 hits |
| `write_file` | yes | creates intermediate directories |
| `edit_file` | yes | exact-snippet replace; refuses an ambiguous match |
| `bash` | yes | `cmd.exe /C`, output merged, 120 s timeout |

At each prompt you can answer `y` (once), `a` (always, for that class of tool)
or `n`. Read-only tools never ask.

## Tests

```
test             :: the four offline suites
test net         :: also the suite that talks to real servers
```

Five suites, 199 assertions, all built with `-gh` so an unfreed block fails the
run - JSON ownership here is manual, so a leak is a defect rather than noise.

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
* `tests\fuzz.lpr` - hostile inputs. Binary files and OEM-encoded shell output
  (the bytes that would otherwise make the API reject a whole turn), NUL bytes
  in JSON strings, path-guard escapes including a sibling directory sharing the
  root's name prefix, degenerate tool arguments, output caps, and a file whose
  contents impersonate the event protocol.
* `tests\net.lpr` - the transport, against real servers and needing no API
  key. TLS, a body that round-trips through an echo service, a response larger
  than one read buffer, aborting mid-transfer, rejection of non-https and
  unresolvable hosts, and the live Anthropic endpoint answering a generated
  request body with `authentication_error` - which is proof the body was well
  formed, since a malformed one is rejected as `invalid_request_error` before
  the key is even examined. It also feeds real wire bytes into the decoder,
  one byte at a time, to cover the seam between the two.

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

`uHttp.HttpTransport` is the seam the loop suite uses. It is nil in the shipped
program, which is asserted by the network suite reaching the real API.

What remains unverified is a 200 response from the live API, which needs a key
this machine does not have. Both sides of it are covered: the transport carries
real traffic in `net`, and the full request-stream-tool-respond cycle runs in
`loop`.

## Design notes

| Unit | Responsibility |
| --- | --- |
| `uJson` | JSON DOM: parse, build, serialise |
| `uHttp` | WinHTTP POST with the body delivered in chunks |
| `uTerm` | UTF-8 console output, colour, line editor |
| `uTools` | the tool implementations, path guard, permission gate |
| `uAgent` | request building, SSE decoding, the tool loop |
| `pasclaude.lpr` | REPL, slash commands, rendering |

Details worth knowing if you touch this code:

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
