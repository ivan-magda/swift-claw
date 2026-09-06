# Coder: delegating a repository task to a headless coding agent

**Date:** 2026-09-05
**Question:** what would it take for swift-claw to accept "take this repository and implement this
task in it", delegate the editing to an external headless coding agent, and produce a branch and a
Pull Request — as a general product capability, not a one-off.

**Sources studied**

- swift-claw at `0f317c29` (`origin/main`), plus the unmerged branches `host-bash-tool` and
  `feature/generic-production-learning-loop`.
- OpenClaw (TypeScript) at `5b03ce77f5148a8d2b44a35a1123e111ba640c62`. Note this checkout is from
  2026-03-06; findings describe that snapshot, not OpenClaw today.
- Hermes (Python) at `226e8de827a669e8ffa7035b27d70c19e44b1208` (2026-07-10). Single squashed
  commit, so no blame or revert history was available.
- OpenAI Codex CLI `0.153.4` and `pi` `0.79.4`, both driven live on this machine.
- `git 2.55.0`, `gh 2.98.0`, `container` 1.1.0, macOS 26.6.2 arm64.

**Method.** Five parallel readers over separate domains — swift-claw's seams, the Codex headless
contract, OpenClaw, Hermes, and the git/GitHub/process-hosting layer — then synthesis. The Codex
and git/hosting readers worked empirically: they ran the binaries and quote captured output rather
than documentation.

**Verification.** Load-bearing swift-claw claims were re-read against source before publication:
`RunBudget.default`, the tool-timeout table, `ApprovalReason`, the `executeWithTimeout` abandonment
contract, the `readonly` mount directive, the `ExfilArgGuard` shape table, the `swift-subprocess`
pin, and the `host-bash-tool` file list. Remaining swift-claw citations and all citations into
OpenClaw and Hermes are as reported by the readers.

Clean-room: mechanisms, contracts and invariants only. No code was transcribed from either
reference project.

---

## Summary

- **Do not adopt ACP as the backend seam.** Both reference projects have ACP infrastructure and
  neither uses it to drive a real coding agent. OpenClaw's ACP backend never opens an ACP
  connection — it spawns a `acpx` CLI per turn and reads NDJSON off stdout
  (`extensions/acpx/src/runtime.ts:265-367`). Hermes' `acp_registry/` is two files, `agent.json`
  and `icon.svg`, publishing Hermes into Zed's registry; there is no discovery or selection code at
  all. The one coding agent Hermes actually drives is Codex, over Codex's own JSON-RPC dialect,
  even though Codex speaks ACP. Define a `CoderBackend` seam in Swift terms and make Codex the
  first adapter.

- **Take OpenClaw's runtime seam shape, which is the part that earns its keep.** `ensureSession →
  opaque serialisable handle`, `runTurn → AsyncStream<Event>` over a small closed event union,
  `cancel`/`close`, optional `status`/`doctor`/`capabilities`, and a typed error enum
  (`src/acp/runtime/types.ts:113-135`, `errors.ts:1-9`). That shape fits `codex exec --json` as
  well as it fits an ACP adapter. The test for whether the seam has leaked: if `sandbox`,
  `approval`, or `config override` appears in the protocol, it is Codex-shaped and belongs in an
  opaque backend-owned settings value instead.

- **`codex exec --json`, not `codex app-server`, for the first backend.** One process per task
  gives one crash domain per task, which is the shape Coder wants, and `exec` is the stable
  documented surface while `app-server` is marked experimental. Hermes chose `app-server` because
  it bridges approvals mid-turn and injects its own MCP tools into the child
  (`agent/transports/hermes_tools_mcp_server.py:29-32`) — neither is a v1 requirement here.

- **A Coder run cannot be a synchronous tool call, and the existing justification for the tool
  seam's failure mode explicitly does not extend to it.** `RunBudget.default.wallClockDeadlineSeconds`
  is 180 (`Sources/ClawCore/LLM/RunBudget.swift:59`); `execute_code`'s default dispatcher
  timeout is 50 s (`ExecuteCodeTool.swift:73`). An overrunning tool is cancelled and
  **abandoned detached** — and `ToolPolicyGate.swift:547-555` justifies that specifically because
  `file_write` commits through a single `rename(2)` and `execute_code` sits behind a sandbox
  enforcing its own shorter timeout. A Coder run has neither property: abandoning it orphans a
  network-connected child process holding a git checkout.

- **Make the run a durable job that reports back as a new turn.** The tool call starts the run and
  returns a run id immediately; a `CoderRunnerService` in the `SchedulerService` mould supervises
  the child and persists state; completion arrives as a fresh turn on the session lane. This needs
  no new `RunState` and no change to the run FSM. Hermes states the same invariant as a hard rule:
  completions surface as a new turn when the agent is idle, never spliced between a tool result and
  an assistant message, because mutating past context breaks prompt caching
  (`tools/async_delegation.py:1-34`).

- **Process exit status is not task outcome, and two independent projects learned this the hard
  way.** Measured on Codex 0.153.4: a real edit and a deliberate no-op both exit 0 with an
  identical `turn.completed`; a model refusal also exits 0 with the refusal in the final message;
  and `SIGTERM` to the npm `codex` shim yields exit **0** instead of 143, because the shim re-emits
  the signal into its own still-installed handler (`bin/codex.js:255-295`). Hermes classifies a
  worker that exits 0 without an explicit terminal transition as a `clean_exit` protocol violation
  and trips its breaker at `failure_limit=1` rather than retrying (`kanban_db.py:6634-6648`,
  incident `2026-06-09 t_d9cbe312`). The rule: `success := saw turn.completed AND exit == 0`;
  `no-op := success AND git porcelain empty`.

- **Derive the changed file set from git, never from the agent's event stream.** Codex emits a
  `file_change` item only when the model routes through `apply_patch`. In a live run the model
  wrote the file with `/bin/zsh -lc 'printf hello > HELLO.md'` and emitted only a
  `command_execution` item, with no `file_change` at all.

- **The workspace `.git` directory is an executable surface, and this is the sharpest security
  finding in the study.** Verified four ways: an agent-written `.gitattributes` plus a repo-local
  `filter.*.clean` driver executed on a supervisor `git add`; `core.fsmonitor` executed on a plain
  `git status`; and an agent-planted `credential.helper` was invoked (`op=get`) by the supervisor's
  `git push` — the exact code path whose job is to hand over the GitHub token. `--no-verify` and
  `core.hooksPath=/dev/null` suppress hooks but were verified **not** to stop filter drivers. The
  only airtight mitigation is to never run git in a directory the agent wrote.

- **Delegation is a sandbox-downgrade primitive unless designed otherwise.** OpenClaw shipped this
  bug twice — once for ACP spawns (CHANGELOG:279, #32254, "preventing sandbox-boundary bypass via
  host-side ACP initialization") and once for subagents (CHANGELOG:607). Both fixes were to fail
  closed at the spawn API. Any Coder spawn needs an explicit isolation-inheritance rule whose
  default is refuse.

- **Neither reference project owns git or PR creation in code.** OpenClaw's entire branch-and-PR
  story is prose in `skills/coding-agent/SKILL.md` telling the model to run `git worktree` and
  `gh pr create`; grep finds no PR-creation call anywhere in `src/` or `extensions/`. Hermes opens
  PRs only from a human-driven dashboard flow (`hermes_cli/web_git.py:450-460`); its autonomous
  workers are forbidden to, and end with `kanban_block(reason="review-required: …")` instead.
  Neither project has any handling for "the agent produced no changes" or "the agent left the tree
  broken". That is the gap Coder should fill in typed Swift, not a design to copy.

- **`host-bash-tool` already builds the host process layer Coder needs, and Coder should depend on
  it rather than extract a third copy.** That unmerged branch adds `Sources/ClawProcess/` with
  `LocalCommandRunning`, `LocalCommand` (carrying the `workingDirectory` and
  `LocalCommandEnvironment` prefix-stripping that `ClawExec` lacks), `ProcessLiveness`, a shared
  `DangerousToolSupport`, and a `ToolDefinition.requiresInteractiveRun` flag whose gate arm refuses
  host tools in proactive and group runs. Verified present via `git ls-tree`.

- **Coder contradicts `docs/ARCHITECTURE.md` §13 at its foundation, and the conflict cannot be
  papered over.** §13 states the sole host mount is a scratch directory "mounted at `/work` with
  the explicit `readonly` option", and `ContainerInvocation.swift:114` hardcodes exactly that.
  Coder's entire purpose is a writable checkout. §6.2's dangerous-tier rule — "execute only inside
  its declared sandbox after approval" (`ARCHITECTURE.md:315`) — is the second direct conflict.

---

## 1. The shape both reference projects converged on

Strip away the differences and OpenClaw and Hermes describe the same pipeline: a durable task
record, a prepared workspace, a supervised child process speaking newline-delimited JSON, a stream
of progress events relayed to a chat surface, and a terminal verdict that the supervisor must not
take on trust.

They differ in what they own. Hermes owns the workspace: tasks carry
`workspace_kind ∈ {scratch, worktree, dir}` with `workspace_path` and `branch_name`, and the store
rejects a `branch_name` unless the kind is `worktree` (`kanban_db.py:2449-2450`) — an invariant
enforced in the database rather than by convention. OpenClaw owns nothing: `cwd` is a
caller-supplied string validated only as "must be absolute"
(`src/acp/control-plane/runtime-options.ts:89-97`), and the real guardrails live as prose in a
skill file ("NEVER start Codex in `~/.openclaw/`"). Two concurrent OpenClaw sessions pointed at the
same repository will stomp each other and nothing in the code prevents it.

Hermes is the better model here, and its own worker prompt draws the line the study kept
rediscovering: the agent edits, the supervisor decides
(`agent/prompt_builder.py:227-234`).

---

## 2. The ACP question, settled

ACP is a JSON-RPC-over-stdio protocol between an editor and an agent. Both reference projects
integrate it. Neither uses it for the job Coder does.

OpenClaw's `AcpRuntime` is its own interface; the only registered implementation shells out to a
third-party CLI multiplexer once per operation and reads NDJSON. If ACP-as-transport were carrying
weight, that plugin would hold a long-lived connection. It does not.

Hermes' ACP surface points the other way entirely: `acp_adapter/` is Hermes *serving* ACP so Zed
can drive it. Its one ACP client (`agent/copilot_acp_client.py`) degrades the protocol into an
OpenAI chat-completions shim — one short-lived session per request, the conversation flattened to a
single text prompt, tool calls recovered by regex-scraping `<tool_call>` blocks out of the response
text, and every permission request auto-denied.

ACP also models none of what Coder needs: no workspace preparation, no branch, no changeset as a
first-class result, no durable job that outlives the connection, no credential or isolation
semantics. And its permission model assumes a human at a keyboard. Headless, OpenClaw must answer
it with a static policy, and the shipped defaults (`approve-reads` + `fail`) mean a coding task
dies on its first file write with `AcpRuntimeError: Permission prompt unavailable in
non-interactive mode`. They documented that rather than fixing it.

**Conclusion.** Own the seam; keep its event vocabulary close to what both Codex and ACP emit, so
an ACP adapter is a later addition rather than a rewrite. Do not put ACP at the boundary.

---

## 3. The Codex contract

All of this was observed on `codex-cli 0.153.4` on this machine, against a throwaway repository
with an isolated `CODEX_HOME`.

**Invocation.**

```
<native codex binary> exec --json -C <workspace> -s workspace-write \
  -c approval_policy="never" -c sandbox_workspace_write.network_access=false \
  --ignore-user-config --ignore-rules -o <final-message-file> "<task>"  < /dev/null
```

Four things in that line are not obvious.

**stdin must be `/dev/null`.** Codex reads stdin even when the prompt is in argv. Measured: 12 s
wall clock with stdin held open 8 s, versus 4 s with `/dev/null`.

**Spawn the native Rust binary, not the npm shim.** The shim's signal handler re-emits SIGTERM into
itself, so a terminated run exits 0 instead of 143. Confirmed by reading the cause and by
experiment.

**`codex exec` has no `-a/--ask-for-approval` and no `--full-auto`** in this version; both are
rejected as unexpected arguments. Approval policy is reachable only through `-c`. Related: `--yolo`
is no longer a full bypass — it now routes approvals through an automatic reviewer that refused an
`rm -f` outright in testing.

**A `.codex/config.toml` inside the target repository is loaded and outranks user config.** A
deliberately broken one aborted a run. For Coder this is untrusted input capable of weakening the
sandbox, redirecting the model, or registering MCP servers, which makes `--ignore-user-config
--ignore-rules` a requirement rather than hygiene. Note the observed scope of
`--ignore-user-config` is broader than its help text claims, so pin it with a regression test since
it is being relied on as a security control.

**Event stream.** `--json` gives clean JSONL on stdout with diagnostics on stderr:
`thread.started{thread_id}` → `turn.started` → `item.started`/`item.completed{item}` →
`turn.completed{usage}` or `turn.failed{error}`. `thread_id` is the resume handle. `usage` carries
token counts and no cost field. The full item taxonomy can be generated from the binary itself via
`codex app-server generate-json-schema`, though the `exec` envelope is its own narrower wire format
not covered by those schemas — decode leniently.

**Orphans.** Verified: after SIGTERM to a run whose task was `sleep 300`, both codex processes were
gone and the `sleep` had been reparented to init. Codex does not tear down its tool-spawned
children. The supervisor must spawn into its own process group and signal the group.

**Authentication for a daemon.** State lives in `$CODEX_HOME/auth.json` at mode 0600, and ChatGPT
tokens self-refresh, so the daemon needs its own writable `CODEX_HOME`. No TTY is required —
verified working with nothing but a symlink to a valid `auth.json`. Preflight with `codex login
status`, because an expired token otherwise costs about 30 s of retries per task before surfacing a
confusing failure.

**Backend-agnostic versus Codex-specific.** Cross-checked against `pi`, which independently
converged on the same shape (one process, one task, JSONL on stdout, session id on the first line,
start/end bracket, tool start/end items, final message, resumable by id, ephemeral option). The
generic fields are: task text, working directory, model, agent-issued session id, resume/fork by
id, ephemeral flag, run start/finish/fail, tool start/finish, assistant text, final message, token
usage, exit status, supervisor timeout. Everything about sandbox modes, approval policy,
`CODEX_HOME`, TOML overrides, and the richer item taxonomy is Codex-specific and belongs behind an
opaque backend settings value.

---

## 4. Why the run cannot be a tool call

Four facts, each verified in source:

- `RunBudget.default.wallClockDeadlineSeconds` is 180 s, re-checked before every tool dispatch
  (`AgentRuntime.swift:477`).
- The default dispatcher timeout for `execute_code` is 50 s, not a fixed maximum.
- The session lane is strict FIFO (`SessionLaneRegistry.swift:66-103`), so a ten-minute call
  freezes the owner's chat for ten minutes.
- Graceful shutdown drains lanes in 30 s (`DaemonBuilder.swift:47`), and a drain timeout is a
  documented failure path.

The fifth fact is the decisive one. An overrunning tool is cancelled and abandoned detached, and
`ToolPolicyGate.swift:547-555` argues that is the right trade because `file_write` "commits through
a staged temp file and a single `rename(2)`/`link(2)`, so an abandoned write either lands whole or
leaves the previous file untouched", and `execute_code` "runs inside a sandbox that enforces its
own shorter timeout". A Coder run satisfies neither clause. Abandoning it leaves a network-connected
child process with write access to a git checkout and no owner.

**Recommended shape: a durable job with a new-turn callback.** The tool call validates, records a
`coder_runs` row, starts the run, and returns a run id within its ordinary timeout. A
`CoderRunnerService` — a `Service` in the `SchedulerService` mould, which already polls a store and
enqueues onto lanes — supervises the child, streams progress, and on completion enqueues a fresh
turn carrying the verdict. Boot reconciliation marks any row left `RUNNING` as failed, exactly as
runs and approvals already do.

The rejected alternative is parking the agent run in a new suspension state alongside
`AWAITING_APPROVAL`. It would work — that machinery already suspends a run across unbounded wall
clock and resumes it with carried-over counters and a fresh per-segment deadline — but `RunState`
has exactly one suspension case, bound one-to-one to an `approvals` row, and `RunFSM.reduce` has no
default arm. Adding a case is a compiler-forced audit of every transition plus normative amendments
to §19.1 and §7.1. For a first vertical slice that cost buys nothing the new-turn callback does not
already give.

---

## 5. Workspace, git, and the Pull Request

**Checkout: one daemon-owned bare mirror per repository, then a local-path `git clone` per task.**
Measured on a 46-commit, 29 MiB repository: the mirror clones in 0.31 s; a per-task clone from the
mirror path costs 0.14 s and **108 KiB** of incremental `.git`, because `git clone /path/to/mirror`
uses the local transport and hardlinks the object store. A `file://` URL disables that and costs
29 MiB.

`git worktree add` is marginally cheaper (0.13 s) and proved robust under 12-way concurrent `add`,
under `add`/`prune`/`fetch` races, and against `gc --prune=now` eating worktree-only commits. It
was rejected anyway, for two reasons. Its failure modes block *retries*: `rm -rf` of a worktree
directory leaves a registered stale entry, and re-adding at that path fails until a prune. More
importantly, a linked worktree's `.git` is a pointer file into a **shared** object store, ref
namespace and config — all of which the agent can write. A local-path clone shares only immutable
hardlinked pack files and has its own config, refs and HEAD. Cleanup is `rm -rf`, which cannot fail
in a way that blocks the next attempt.

Shallow clone is rejected outright. `--depth 1` saved 0.01 MiB on the test repository, because
depth removes history rather than the tip tree. Against that, pushing a shallow branch to a remote
lacking the base history fails with `! [remote rejected] … (shallow update not allowed)` — which is
the fork-based PR workflow exactly.

**The supervisor commits, always,** because that is where identity, trailers and the size/secret
gate are enforced, and enforcing them through a prompt is what the house rules forbid. Identity
goes through `GIT_AUTHOR_*`/`GIT_COMMITTER_*` environment variables rather than config, since the
workspace config is agent-writable and the global config is the owner's identity. If the agent
already committed, treat that as normal: record `BASE` immediately after the clone, then
`rev-list --count $BASE..HEAD` and `status --porcelain=v2` give four outcomes with obvious actions.
Do not amend or rebase the agent's commits.

**Detecting a broken tree needs more than `status`.** A stale `index.lock` is invisible to both
`status` and `diff` — both exit 0 — while `git add` then fails with exit 128. A supervisor that
reads "clean" from `status` alone will silently discard the agent's work. The probe set must
additionally check for `index.lock`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`,
`rebase-merge`/`rebase-apply`, `BISECT_LOG`, a detached HEAD, unmerged index entries, and committed
conflict markers. Note a conflicted rebase reports a detached HEAD, so neither check implies the
other. Do not attempt automated repair: `rm -rf` the workspace, fail the task with the specific
reason, and let the retry get a fresh clone.

**Size and secret guards need no new machinery.** `git diff --cached --numstat` is not enough — it
prints `-` for binary files, the exact case being guarded against — so take real byte counts from
`cat-file -s` on the staged oids. For secrets, `ExfilArgGuard.shapePatterns` already carries a
`github-token` rule (`ExfilArgGuard.swift:89`) alongside `openai-key`, `slack-token`,
`aws-access-key` and a high-entropy catch-all, and `SecretRedactor` covers exact values. Same
table, new call site: run both tiers over staged blob contents before committing.

**Open the PR with a hand-written REST client on the existing `HTTPExecuting` seam, not `gh`.** `gh`
works headless, but it shells out to git (`GH_DEBUG=1` shows `[git remote -v]`), so it adds two PATH
dependencies; its porcelain errors are English prose where the API returns typed JSON; and its test
double has to be a file on disk rather than a value in the type system. Three endpoints is less
code than the shell-out harness. `ARCHITECTURE.md:868` records the identical reasoning for the
Telegram client, and the only `Process()` outside the sandbox backend today is a `launchctl` probe
in doctor.

**Auth: a GitHub App installation token**, minted per task and narrowed to the one repository, is
the recommendation; a fine-grained PAT behind the same delivery mechanism is the acceptable v1
shortcut. The token reaches git through `GIT_ASKPASS` with `GIT_TERMINAL_PROMPT=0`, never through a
URL — verified that `git remote set-url origin http://user:TOKEN@host/…` writes the token verbatim
into a world-readable `.git/config`. `-c credential.helper=` is mandatory, not hygiene: without it
this machine's three global helpers produced `fatal: User cancelled dialog.` from Git Credential
Manager trying to open a GUI in a headless context.

---

## 6. Containment versus credentials

This is the tension the whole design turns on: the coding agent needs network egress to reach a
model API, and must not be able to touch anything outside its workspace or reach the daemon's own
secrets.

**OpenClaw did not solve it — it moved the agent out.** Sandbox containers default to no network,
do not inherit host environment, and filter anything resembling a credential
(`src/agents/sandbox/sanitize-env-vars.ts` blocklists `GH_TOKEN`, `GITHUB_TOKEN`, and a catch-all
`_?(API_KEY|TOKEN|PASSWORD|PRIVATE_KEY|SECRET)$`). A coding agent inside can reach neither a model
API nor a git remote, so ACP sessions run on the host and the code refuses to pretend otherwise.

**Hermes narrowed what "credentials" means.** `hermes_subprocess_env(inherit_credentials:)`
(`tools/environments/local.py:471`) is a two-tier strip: tier one is always denied even to a coding
child (GitHub auth, messaging bot tokens, relay secrets, infrastructure tokens); tier two is model
provider keys, admitted only with an explicit flag that is deliberately grep-able for audit, with
exactly two production call sites. Git push is not solved — `GITHUB_TOKEN` is tier-one stripped and
a skill re-reads it from disk inside the shell. Hermes says so out loud in `SECURITY.md:58-119`:
the only security boundary against an adversarial LLM is the operating system, and environment
scrubbing "reduces casual exfiltration; it is not containment."

Two scars are worth carrying. Skills declaring `required_environment_variables` tunnelled provider
keys past the strip (`GHSA-rhgp-j443-p4rf`); the fix intersects any declaration with a hard deny
list and fails closed if that list cannot be loaded. And stripping too much broke the user's own
tools: removing `CLAUDE_CODE_OAUTH_TOKEN` made agent-spawned `claude` CLIs fall through to the
shared credential store and, on failure, clear it — logging the owner out of their interactive
sessions (#55878).

**Recommendation: split the boundary.** Run the agent inside an apple/container VM with a writable
bind mount of the task workspace and network enabled; run every git and GitHub operation on the
host, in a fresh checkout the agent never wrote, with a token the agent never sees. The containment
then has nothing to leak even if the agent is fully subverted. Build the child environment from an
allowlist rather than a denylist — `ClawExec`'s three-key removal over `.inherit` is correct for
its case, where the child is the trusted `container` CLI, and wrong here. The concrete list to
scrub or override: `SSH_AUTH_SOCK`, every `GIT_*`, `GH_TOKEN`/`GITHUB_TOKEN`, cloud credential
variables, every `CLAW_*`, package-registry tokens, plus `HOME` and `TMPDIR` repointed inside the
workspace and a fixed minimal `PATH`.

`sandbox-exec` is worth adding around the launcher as a second layer — a working profile
demonstrably blocked `~/.ssh`, `~/.aws` and `~/.gitconfig` while leaving network intact — but never
as the boundary, which is what `ARCHITECTURE.md:786` already says. Two caveats from building one: a
`(deny default)` profile without `(import "bsd.sb")` aborts the process before `main` with no
diagnostic, and omitting `(allow process-fork)` breaks any agent that spawns compilers.

---

## 7. What "done" means

The failure taxonomy is where both reference projects bled, and it converges with the Codex
measurements into one rule set.

- **Success** requires a terminal event *and* a zero exit. Never exit code alone.
- **No-op** is success with an empty `git status --porcelain`. Codex cannot distinguish it and a
  model refusal looks identical from outside.
- **Protocol violation** — the child exited without a terminal event — is a distinct,
  **non-retrying** class. Hermes trips its breaker immediately here rather than looping, on the
  reasoning that a retry will do exactly the same thing.
- **Never trust the child's terminal event either.** OpenClaw ships a documented failure where "ACP
  session stalls indefinitely after completing work", with the remedy "kill stale processes
  manually". Their fix elsewhere is to synthesise the terminal event from exit code plus observed
  stream state, and to swallow duplicates.
- **Two timers, always:** a wall clock and a silence watchdog that resets on output, clamped
  strictly below the hard timeout. OpenClaw uses different budgets for a fresh run versus a resume,
  on the reasoning that a resumed session going quiet is more likely wedged. Hermes adds a
  *post-tool* quiet watchdog specifically, so a child that finishes a tool and then goes silent
  fails fast instead of burning the full deadline.
- **Distinguish ENOENT causes.** Missing binary and missing working directory produce the same
  error; conflating them yields an un-actionable message.
- **Rate limiting deserves its own class.** Hermes gave it a dedicated sentinel exit code
  (`EX_TEMPFAIL`) so a provider quota wall requeues without counting a failure, after quota windows
  were permanently blocking cards.

---

## 8. Reuse map

| Concern | Reuse | Build |
|---|---|---|
| Tool contract | `Tool`, `ToolDefinition`, `ToolPayload`, `JSONValue` | — |
| Registration | `ToolRegistry`, `GatedToolDispatcher`, `makeToolDispatcher` | conditional append behind a health probe |
| Approval | `prepareAction`/`PreparedToolAction`, the gate's dangerous arm, `ApprovalWaiter`, `ApprovedActionExecutor` | a fourth `ApprovalReason` case plus its prompt copy — the enum is closed and the prompt exhaustive, so it will not compile otherwise |
| Secret scanning | `ExfilArgGuard.shapePatterns`, `SecretRedactor` | a new call site over staged blobs |
| Process launch | `swift-subprocess` (pinned `exact: "1.0.0"`), `DeadlineRace`, `createSession` + process-group teardown | — |
| Host launcher | **`ClawProcess.LocalCommandRunning` from `host-bash-tool`** | the same seam, if that branch does not land |
| Scratch layout | `<stateRoot>/<feature>-scratch/<id>` at `0700`, `PrivateDirectory.ensure`, unconditional removal | Coder's own; `ScratchWorkspace` is `internal` and request-shaped |
| Store | `MappedDatabase`, `ClawDatabase.classifyError`, the `ScheduledJobStoreGRDB` shape including its fused compare-and-swap claim | `CoderRunStore` + GRDB impl + migration `v11` |
| Background service | the `SchedulerService` / `OutboxDispatcher` `Service` shape, `TurnEnqueuer` | `CoderRunnerService` |
| HTTP client | `HTTPExecuting`, `AsyncHTTPExecutor`, the `TelegramClient` hand-written pattern | a three-endpoint GitHub client |
| Config & secrets | `AppConfig.EnvKey`/`EnvDefaults`, `EnvSecretStore.EnvKey.sealed`, the envelope pattern | `CoderConfig`, one credential field |
| Doctor | `SandboxHealth` / health-row shape | Coder backend probe rows |

There is no Swift-side git or GitHub helper today. A case-insensitive search for `git` across
`Sources/` matches one build-stamp string.

---

## 9. Proposed shape for Issue 1

A minimal vertical slice, ordered so each step is independently useful.

1. **`CoderBackend` seam in `ClawCore`.** Input: task text, workspace path, optional model,
   timeout, optional resume handle. Output: an event stream over a small closed union plus a
   terminal outcome carrying final message, usage, and exit status. Backend-specific settings ride
   as an opaque value the composition root builds. Changed files are *not* a backend concern.
2. **`CodexBackend` in a sibling target**, spawning the native binary with the §3 argument list over
   `ClawProcess.LocalCommandRunning`, decoding JSONL leniently, synthesising the terminal event
   from exit status plus observed stream state.
3. **`coder_runs` store** in house style — protocol in `ClawCore` with `throws(StoreError)`, a GRDB
   struct holding one `MappedDatabase`, migration `v11`, a fused compare-and-swap claim so a run
   cannot double-start, and new closed-enum audit actions.
4. **Workspace preparation on the host:** mirror fetch, local-path clone, `BASE` capture, branch
   naming derived from the run id and never from model text.
5. **`CoderRunnerService`** supervising the child, relaying coalesced progress, enforcing both
   timers, tearing down the process group, and enqueueing the completion turn.
6. **Verdict and commit on the host**, in a checkout the agent never wrote, behind the size and
   secret gates.
7. **PR via the GitHub REST client**, with an existing-PR probe for retry idempotence.

Deliberately out of scope for the slice: participants, per-participant isolation, scoring, a second
backend, mid-run steering, and resumption of a partially completed run.

---

## 10. Spec amendments

`docs/ARCHITECTURE.md` is normative, and a task that changes a contract changes the spec in the
same commit. Coder touches:

- **§13 execution/sandbox** — the `readonly` sole-mount invariant, the 16-file/4 MiB staging model,
  the disposable-VM-per-execution unit, the 1 MiB output retention, and serialized concurrency.
  Either §13 grows a second execution profile or Coder must fit inside the existing one, which it
  cannot.
- **§6.2** — "execute only inside its declared sandbox after approval" (`ARCHITECTURE.md:315`).
- **§5.1 / §5.3** — the strict-FIFO lane contract and the 180 s run budget. Also worth noting that
  a Codex run spends on the owner's OpenAI account through a channel `BudgetGate` cannot see.
- **§7.1** — a `coder_runs` table row.
- **§10.2** — the tier table, and the sentence "a registry of < 20 narrow, typed tools (not a
  generic shell)".
- **§11** — the approval binds an *invocation*, but the *effect* is non-deterministic. The spec
  should say which one the owner is approving, and define Coder's blast-radius vocabulary.
- **§12 / §12.1** — a fourth outbound sink class that `ExfilArgGuard` cannot inspect, because the
  bytes never pass through swift-claw; and the group-mode arm that runs dangerous actions untapped
  on the reasoning that "the sandbox is the containment".
- **§15, §16.1, §20, §21** — config namespace and sealed-variable list, doctor rows, a roadmap row,
  and the containment question while it stays open.

---

## 11. Open questions

1. Does Coder run inside a container at all, or on the host behind `requiresInteractiveRun`? The
   study recommends the container, but that is the §13 amendment with the widest blast radius.
2. Does every Coder run require an owner approval? Every run is networked by definition, and §12
   currently makes a networked run unconditionally `canExfiltrate`. Answering "yes" is at least
   honest; answering "no" needs its own argument in the spec.
3. What image does the agent run in? The `execute_code` base is a pinned Chainguard Python image; a
   coding agent needs git, a toolchain and the Codex CLI. That is a new digest-pinned image with
   its own supply-chain verification.
4. Does the pinned `swift-subprocess` 1.0.0 contain PR #272 (AsyncIO cancelled on child exit)? A
   coding agent spawns grandchildren constantly, so it is more exposed to that hang than
   `execute_code` is. Verify by commit ancestry, not version number.
5. Does `host-bash-tool` land, and in what shape? Coder's execution path depends on it.
6. Where does the GitHub credential live — a single sealed value like `searchApiKey`, or the
   per-service envelope pattern with a URL fingerprint, if Coder ever serves more than one remote?
