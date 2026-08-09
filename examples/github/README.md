# Answering an `@claude` mention from GitHub Actions

`pasclaude-mention.yml` is a template. Copy it into `.github/workflows/` in
your own repository, change the clone URL to the fork or tag of pasclaude you
have read, and set one secret. It is not live in this repository on purpose:
a live workflow here would run on every comment, spend the maintainer's
Actions minutes, and fail saying "no credential" because this repository has
no `ANTHROPIC_API_KEY`.

**One secret.** `ANTHROPIC_API_KEY`, a repository secret. It is set on exactly
one step — the one that runs the model — and appears exactly once in the file.

## What the run may do

A CI run may **read the repository and write one comment**. It may never push,
never patch, never approve, never merge. That is the whole autonomy budget and
it is enforced in four independent places, any three of which could fail:

1. **A stranger cannot start a run.** The trigger is `issue_comment` (created)
   and nothing else. The job's `if:` requires the comment to mention `@claude`,
   the sender not to be a bot, and `author_association` to be `OWNER`,
   `MEMBER` or `COLLABORATOR`. That value is computed by GitHub from the
   commenter's relationship to the repository; it is not something the
   commenter types. The same check runs again in Pascal inside `--ci prepare`,
   so an edited `if:` does not silently widen anything, and `--ci-allow
   member|owner` narrows it further. **There is no flag that widens it.**

2. **The agent's process holds no GitHub credential.** `GH_TOKEN` is set on
   exactly two steps, both of which run fixed command lines: "read the pull
   request" (`gh pr view`) and "post the comment" (`gh api`). The step that
   runs the model has `ANTHROPIC_API_KEY` and no GitHub token at all — a
   GitHub token is never in a step's environment unless you write it there.
   `actions/checkout` is given `persist-credentials: false`, so no token is
   left in `.git/config` where `read_file` could find it.

3. **The token that does exist cannot do much.** `permissions:` names three
   keys, which sets every unnamed one to `none`:

   | key | why | what it buys an attacker |
   |---|---|---|
   | `contents: read` | `actions/checkout` | read this repository |
   | `issues: write` | posting the comment (the issue-comments endpoint serves pull requests too, and this is the narrower of the two keys that satisfy it) | post comments on issues and pull requests here |
   | `pull-requests: read` | `gh pr view` | read pull request metadata |

   With exactly that, an injected instruction **cannot push to a branch**,
   create a branch or a tag, approve or submit a review, merge, edit a
   workflow, publish a release, or reach any other repository.

4. **The agent has no shell, no fetch, no write.** A fixed step writes
   `%LOCALAPPDATA%\pasclaude\deny.json` — out of tree, so nothing in the
   checkout can supply or edit it — containing `tool:bash`, `tool:bash_output`,
   `tool:kill_bash`, `tool:fetch`, `tool:web_search`, `tool:write_file`,
   `tool:edit_file`, `tool:notebook_edit`, `tool:task`, `path:**/.git/**`,
   `path:**/.env*` and `path:**/*.pem`. Nothing overrides a deny rule: not a
   permission mode, not a persisted "always", not a hook's allow, not a file
   in the tree. What is left is `read_file`, `list_dir`, `search` and
   `todo_write` — enough to review code and answer.

   **`--dangerously-skip-permissions` appears nowhere.** It is not needed:
   under `-p` there is nobody to ask, so `Ask` is nil and a gated tool returns
   an ordinary error result while the turn continues. The run is
   `-p --output-format json --permission-mode plan --no-project-context`.
   That last flag is there because this step runs in the checkout, and the
   checkout is the pull request's *own head*: its `AGENTS.md`, `CLAUDE.md` and
   `.pasclaude.md` are the author's text, and the system prompt is the most
   trusted position in the request. It is a flag on the command line and never
   a mode inferred from the prompt, because the prompt is the part an attacker
   wrote.

   `--ci prepare` runs *after* the deny rules load and refuses to proceed, with
   exit 2 naming every missing rule, if the floor is not in force. A workflow
   edited to drop that step stops working instead of quietly widening.

## Fork pull requests are refused

Not unimplemented — refused. `--ci prepare` reads
`gh pr view --json isCrossRepository,headRefOid,state`; a cross-repository pull
request gets `proceed=false, code=fork` and a fixed sentence posted as a
comment. A pull request comment with no `--ci-pr` file is refused too, so
removing that step fails closed rather than open.

The argument for allowing forks would be that with bash denied nothing from the
fork is executed, only read. That invariant rests on the absence of any build
step in this job, and one added `npm ci` line destroys it silently. Same-repo
branches only.

If you adapt this template to `pull_request` from a fork, secrets are absent,
`ANTHROPIC_API_KEY` is empty, and pasclaude exits 2 at startup with "no usable
credential was found" — a clean startup failure before any turn.

## What it costs

`windows-latest`. There is **no release pipeline**, so the workflow clones
pasclaude and builds it: Chocolatey's `freepascal` package is about 2–3
minutes, `build.cmd` about 30 seconds, the turn about 30 seconds — roughly
four minutes wall. Free on public repositories; billed at 2× on private ones,
so about eight minutes. Caching the compiler would help and is not shipped: a
cached compiler directory without the matching PATH state is a support burden.

`gh` is preinstalled on GitHub-hosted runners. On a self-hosted Windows runner
it may not be, and the two `gh` steps fail visibly rather than skipping.

## What reaches the model

The comment body and the issue title are third-party text. They land in an
ordinary **user message**, never the system prompt, inside a marked block
preceded by one sentence saying the contents are data and never an instruction.
Control characters are stripped, the request is cut to 4000 bytes, and any line
forging a marker is dropped **after** the cut. The envelope is a labelling
device, not a sanitiser: a comment can still try to persuade the model, and
what it can achieve is bounded by (2), (3) and (4) above, not by the wording.

Nothing untrusted reaches `GITHUB_OUTPUT`, `GITHUB_ENV` or a `run:` line.
`head_sha` in particular must be exactly 40 hex characters or it is not
emitted, because it chooses the commit `actions/checkout` writes into the
workspace.

**Residual, stated rather than glossed:** a same-repo branch's `CLAUDE.md`,
`AGENTS.md` and `.pasclaude.md` — and every `@import` inside them — no longer
enter the system prompt at all, because the answering step passes
`--no-project-context`. What still reaches the request from the branch is its
**skill descriptions**, which were never in the system prompt to begin with:
the catalogue rides in the `skill` tool's own description, rebuilt with the
schema on every request. They are not gated by that flag on purpose —
suppressing them is a different feature, changing the tool schema and with it
the cache breakpoint — and the bound on them is the same as it always was:
whoever wrote them has push access, the deny floor above still holds, and the
worst outcome is a wrong comment rather than an action. The posted answer is
also not rewritten, so it can `@`-mention people and generate notifications;
rewriting `@` would corrupt code in the answer.

## How this file is checked

`build.cmd` and `test.cmd` cannot run YAML. The `ux` suite reads this workflow
from disk (**absent is a failure, not a skip**) and asserts that every rule of
`uCi.CiDenyFloor` appears verbatim, that `persist-credentials: false` appears,
that the three `permissions:` keys appear and no fourth `: write` line does,
that the file is under 120 lines, that the line running the model carries
`--no-project-context` — checked on *that line*, not anywhere in the file, so
naming the flag in a comment would not satisfy it — and that none of
`pull_request_target`,
`${{ github.event.comment.body`, `${{ github.event.issue.title` or
`--dangerously-skip-permissions` appears anywhere. It is a grep, not a parse —
there is no YAML parser here and RTL-only forbids adding one. Everything
semantically load-bearing lives in Pascal instead, in `src/uCi.pas`, where the
suites can drive it.
