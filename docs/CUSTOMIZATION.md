# Customizing Your Agent

You shape your agent in two places: Markdown files in the workspace (persona, rules,
profile) and environment variables (wiring, budgets, features).
[`.env.example`](../.env.example) stays the complete variable reference.

## Workspace files

The workspace lives at `<state root>/workspace/` (default `~/.swift-claw/workspace/`).
Create any of these files and the daemon loads them on the next turn; it skips the ones
you leave out.

| File                     | What it shapes                                                                             | Trust tier          |
| ------------------------ | ------------------------------------------------------------------------------------------ | ------------------- |
| `SOUL.md`                | Personality and tone. The place to say "answer tersely", "be playful", "reply in Russian". | System prompt       |
| `AGENTS.md`              | Behavior rules: how to act, what to prioritize, standing instructions.                     | System prompt       |
| `TOOLS.md`               | Guidance on when and how to use tools.                                                     | System prompt       |
| `USER.md`                | Your profile: who you are, context the agent should know.                                  | Untrusted, labeled  |
| `MEMORY.md`              | Long-lived memory the agent maintains.                                                     | Untrusted, labeled  |
| `HEARTBEAT.md`           | A checklist the proactive heartbeat reads, never ordinary turns.                           | Heartbeat runs only |
| `skills/<name>/SKILL.md` | A procedure the agent loads when the task calls for it. See [Skills](#skills).             | Untrusted, labeled  |

The trust tier decides how much authority the text carries:

- **`SOUL.md`, `AGENTS.md`, and `TOOLS.md` join the system prompt.** You write them, and
  the model treats them as trusted instruction. They also feed the policy fingerprint, so
  editing one invalidates any approval still waiting on the old prompt. Nothing you put in
  them can loosen the security policy, which lives in code rather than in the prompt.
- **`USER.md` and `MEMORY.md` enter inside an untrusted, labeled wrapper**, below the
  system prompt, so text that reached them through poisoned memory cannot claim system
  authority. Both count as private data for the exfiltration gate below.

When the agent writes to a file that steers a later turn, the approval card carries a
privileged-file banner: any of the files above, plus `HEARTBEAT.md` and any `SKILL.md`.

The agent writes and reads dated daily logs (`memory/YYYY-MM-DD.md`) when a turn calls for
one; the context builder never injects them the way it injects the files above.

Durable facts also live in the database: confirm something in chat ("remember that ...")
and it persists in SQLite across restarts, recalled by importance and recency. Full-text
search covers conversation history, not these facts. `/memory` shows what is stored.

## Skills

A skill is a procedure you write once and the agent pulls up when a task calls for it —
the steps of your Friday review, or how you want a commit message worded. Each one gets
its own directory:

```
~/.swift-claw/workspace/skills/
└── weekly-review/
    └── SKILL.md
```

`SKILL.md` opens with a `---` fenced block carrying two required keys, then the procedure
itself:

```markdown
---
name: weekly-review
description: How to run the Friday review — which projects to check, in what order, and what to report.
---

Go through the open projects newest first. For each one, ...
```

Only the name and description stay in context, one line per skill. The body arrives on
demand: when a description covers what the agent is about to do, it asks for that skill by
name and follows what comes back. It is told to load at most one per task, and it never
types a path: the tool takes a name and resolves it against the directories the daemon
scanned, so a path cannot be typed at all.

What the scan requires:

- **`name`**: lowercase letters and digits, single hyphens between them, 1–64 characters
  (`weekly-review`), and it has to match the directory name exactly.
- **`description`**: the one line the agent matches against the task in front of it, so
  spend it on when to reach for the skill. Past 300 characters the index shows it
  truncated, and a description written across several lines is folded back into one.
- **One name per directory.** If two directories claim the same name, both are skipped:
  nothing can tell which one you meant.

You wrote the body, so the agent follows it as procedure. That is the whole licence: a
skill cannot hand out a tool, waive an approval, or loosen the security policy, all of
which live in code and in the system prompt rather than in the file. Loading one also
does not count as reading untrusted content, so your private memory stays available for
the rest of the session. Reading the same file with `file_read` would cost you that.

clawd touches nothing else in the directory for now: no `scripts/` runs, no `assets/` or
`references/` load.

Send `/skills` for the complete current scan. Its Accepted section lists every usable
name and description. Its Rejected section lists every scanner warning, including a
`skills/` directory that clawd could not read. The command starts no agent turn and
changes no skill state.

Ordinary turns use a smaller failure surface. A reply reports authoring errors,
workspace-boundary failures, and skills dropped from that turn's budget above the answer.
It logs a failure to read the whole `skills/` directory instead of repeating that warning
in every reply. The scan runs again on the next turn, so unresolved notices recur:

- `⚠ Skill weekly-review: manifest name weekly-summary must match the directory name; skipped.`
  — and sibling notices for a missing frontmatter block, a name that breaks the shape
  rules, or a duplicated name.
- `⚠ Skill research: its SKILL.md resolves outside the workspace, which I can't load from;
skipped.` A skill directory has to live under `skills/`, not be symlinked in from
  elsewhere — clawd reads nothing outside the workspace. Copy the folder in instead.
- `⚠ The skills directory resolves outside the workspace, which I can't load from; all
skills skipped.` The same rule applied to `skills/` itself: linking the whole directory
  to a folder elsewhere on disk turns every skill under it off. Move it in.
- `⚠ Skills index over budget; left out this turn: research, weekly-review.` The index has
  its own slice of the context budget. Skills are indexed in alphabetical order and the
  overflow is cut from the end, so shortening descriptions is what brings the tail back.

Full `clawd doctor` and Telegram `/status` summarize a fresh scan as
`context.skills accepted=N rejected=N fits_cap=true|false`. The row stays visible in
`/status` when healthy and fails if the scan has any warning or the complete canonical
index exceeds the absolute skills cap. A particular turn can still drop skills when
other context leaves less room; `fits_cap` does not predict that residual budget.

## When the agent asks permission

clawd shows an approval card for two reasons.

**The tool's own risk tier.** File writes, memory writes, code execution, and native Coder
submissions park the run every time, whatever else the session did.

**Exfiltration risk.** clawd holds an arbitrary-destination tool call, including `web_fetch`
and MCP calls, for your approval once the session has done _both_ of these:

- **Ingested untrusted content.** A web page, a file read, tool output, a voice transcript,
  or a photo. Durable memory and a skill you loaded do not count: both are labeled
  untrusted, and neither taints the session on its own.
- **Touched private data.** Assembling `USER.md`, `MEMORY.md`, or stored memory items into
  the context is enough; no tool has to read them. Once you have filled in `USER.md`, this
  leg is armed on essentially every turn, and it sticks for the session.

One leg alone does not trigger the gate, so the first `web_fetch` or safe MCP call of a clean
session runs unprompted. `/new` clears both legs.

Your LLM provider and the search backend are pinned destinations, so they never park for
approval: no injected instruction can aim clawd at an attacker's URL instead. clawd also
scans outbound _tool_ arguments for secret-shaped values, and, under the trifecta, for
substrings of your private files. The prompt sent to your LLM
carries `USER.md` and `MEMORY.md` verbatim by design, so treat your model provider as a
party you trust with that content.

## Model routing

`CLAW_LLM_MODEL` selects the provider route:

- **A plain model id** (`claude-sonnet-4-6`, `gpt-4o`, `openrouter/openai/gpt-5.4`) uses
  the OpenAI-compatible Chat Completions route against `CLAW_LLM_BASE_URL` with
  `CLAW_LLM_API_KEY`. This is the supported default and works with local servers too
  (leave the key blank for no-auth endpoints).
- **`openai-chatgpt/<model>`** uses the ChatGPT subscription route. `clawd auth login`
  handles the OAuth flow and prints the exact value to set; base URL and API key are
  unused there.

Related knobs: `CLAW_LLM_STREAMING` (rich streamed drafts, on by default),
`CLAW_LLM_MAX_TOKENS`, `CLAW_LLM_MAX_TOKENS_FIELD`, `CLAW_LLM_STRUCTURED_OUTPUT`.

### A second route to fall back to

Name a second model and clawd finishes the turn there when the first route cannot answer:
the plan quota ran out, the credential was refused or the account denied, or the endpoint
would not connect. Leave `CLAW_LLM_FALLBACK_MODEL` unset and none of this is in play.

| Variable                             | Controls                                                                                                    |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------- |
| `CLAW_LLM_FALLBACK_MODEL`            | The second route's model, chosen the same way `CLAW_LLM_MODEL` is. Unset means no fallback.                 |
| `CLAW_LLM_FALLBACK_BASE_URL`         | Its endpoint. Required when the model resolves to the OpenAI-compatible route, unused on `openai-chatgpt/`. |
| `CLAW_LLM_FALLBACK_API_KEY`          | Its key, sealed alongside `CLAW_LLM_API_KEY`.                                                               |
| `CLAW_LLM_FALLBACK_MAX_TOKENS_FIELD` | The fallback's own `CLAW_LLM_MAX_TOKENS_FIELD` (default `max_completion_tokens`).                           |
| `CLAW_LLM_PRIMARY_COOLDOWN_SECONDS`  | How long a walled-off primary is left alone before clawd tries it again (default 900).                      |

A ChatGPT subscription in front, a metered API key behind it:

```bash
CLAW_LLM_MODEL=openai-chatgpt/gpt-5.4
CLAW_LLM_FALLBACK_MODEL=claude-sonnet-4-6
CLAW_LLM_FALLBACK_BASE_URL=https://api.anthropic.com/v1
CLAW_LLM_FALLBACK_API_KEY=sk-ant-...
```

You hear about the transitions and nothing in between: one line under the reply when the
fallback takes over, naming both models, and one when the primary answers again. If both
routes fail, the reply names the primary's cause and adds that the backup was tried too.

A route that fails goes on a cooldown, so clawd stops probing an exhausted plan every
turn: 900 seconds by default, 60 for a failure that looked like a network problem,
doubling on each further failure up to an hour. Turns during that window start on the
fallback. The windows live in memory, so a restart costs one probe against the primary.

Before you turn it on:

- **The dollar caps start applying.** The fallback is billed per token, so the limits
  below bind from the call it takes over. They were inert while a flat-rate primary
  answered. Read [Spending limits](#spending-limits), including the one call that can go
  over.
- **A failure mid-answer does not switch.** Once the model may have started generating,
  re-sending the same work elsewhere could bill you twice, so clawd degrades the turn
  instead of moving it.
- **Both routes are checked at startup.** `CLAW_LLM_STRUCTURED_OUTPUT` set to a mode your
  fallback cannot serve fails config validation with exit 10, naming the route, rather
  than waiting to break the first time the fallback carries a turn.
- **An approval you granted can execute against the other provider.** You approve an
  action while your conversation is going to one provider; if the route switches before
  the run resumes, the action runs anyway and its output goes to the other one. clawd does
  not ask you again, because the fingerprint an approval binds to names your configured
  primary and a switch does not change it. Both providers in a fallback pair need the
  trust you would give either alone.

`clawd doctor --check-config` reports `llm.fallback_configured` as `yes (<model>)` or
`no`; it says nothing about whether the fallback's key works, which you find out when the
fallback first runs. To see which model is answering right now, send `/doctor` to your bot:
its `LLM & Runs` line names the active route, and adds the remaining cooldown while the
primary is walled off. The same rows exist in `clawd doctor` at the shell, where they read
`<your primary model> (configured primary)` and `unknown` — the cooldown windows belong to
the running daemon, and a separate process will not guess at them.

## Spending limits

All optional; unset means the built-in defaults.

| Variable                                 | Controls                                                       |
| ---------------------------------------- | -------------------------------------------------------------- |
| `CLAW_PER_RUN_USD`                       | Cap per single run                                             |
| `CLAW_PER_DAY_USD`                       | Daily spend kill-switch                                        |
| `CLAW_PROACTIVE_PER_DAY_USD`             | Nested daily cap for scheduled + heartbeat runs (default 2.00) |
| `CLAW_MAX_TURNS` / `CLAW_MAX_TOOL_CALLS` | Bounds on the agentic loop per run                             |

**On the ChatGPT subscription route these dollar caps do not gate.** A plan-included call
has no metered cost to compare against, so `CLAW_PER_RUN_USD` and
`CLAW_PROACTIVE_PER_DAY_USD` are inert there, and clawd records the usage at zero USD.
`CLAW_PER_DAY_USD` still binds indirectly, because the daily token ceiling derives from it;
set `CLAW_DAY_TOKEN_CEILING` to control that directly. Token, turn, tool-call, and
wall-clock bounds apply the same on both routes.

**With a [fallback route](#a-second-route-to-fall-back-to) configured, one call can go
over the dollar caps.** clawd checks the budget once per round-trip, before it calls the
model, against whichever route is active at that moment. The switch happens inside that
same round-trip, and the fallback's call on it is not checked again. Under a flat-rate
primary clawd skips the dollar checks outright, so that first metered call runs even when
the day's cap is already spent. Turns after it start on the fallback and are checked
normally, which puts the overshoot at roughly one call per cooldown window. The daily
token ceiling did gate that round-trip, since clawd checks it whether the active route is
metered or flat-rate; the dollar caps are the ones that let the call through.

## Proactive behavior

You create schedules in chat, and you confirm each one before it arms. The environment
sets the frame: `CLAW_TIMEZONE` (IANA zone for schedule defaults and day boundaries),
`CLAW_SCHED_MIN_INTERVAL_MINUTES`, `CLAW_SCHED_CATCHUP_MAX_AGE_MINUTES`.

The heartbeat is off by default. `CLAW_HEARTBEAT_ENABLED=true` turns it on (requires
exactly one allowlisted owner), then it works through `HEARTBEAT.md` up to
`CLAW_HEARTBEAT_MAX_PER_DAY` times a day, every `CLAW_HEARTBEAT_INTERVAL_MINUTES`
minutes, staying silent during `CLAW_HEARTBEAT_QUIET_HOURS` (default `22:00-09:00`).

## Voice messages (macOS 26)

On by default, on-device, off on other platforms. `CLAW_VOICE_LOCALES` takes a
comma-separated priority list (`ru-RU,en-US`); there is no audio language detection, so
every configured locale transcribes the note and the most confident transcript wins.
The first use of a locale downloads its speech model.

## Inbound images

On by default, every platform. A photo you send is downloaded and shown to the model with
its caption. This needs a vision-capable `CLAW_LLM_MODEL`; nothing checks that at startup,
so a text-only model fails the turn instead — and keeps failing every turn after it, until
`/new` clears the photo out of the conversation. `CLAW_IMAGE_INPUT=false` turns the feature off:
a bare photo then gets a canned refusal, while a captioned one still runs as a turn carrying
your caption. Bytes stay in memory, never on disk, and a restart loses them.

## Code execution sandbox (macOS 26 arm64)

Off by default. `CLAW_EXEC_ENABLED=true` lets the agent run code in a fresh disposable
VM per request, behind an exact-action approval. Resource limits
(`CLAW_EXEC_MEMORY_MIB`, `CLAW_EXEC_CPUS`, `CLAW_EXEC_TIMEOUT`), the digest-pinned
workload image, and the network opt-in (`CLAW_EXEC_ALLOW_EGRESS`) are documented in
[`.env.example`](../.env.example) and [LOCAL_DEV.md](LOCAL_DEV.md).

## Coder configuration

Set `CLAW_CODER_ENABLED=true` to expose `coder_submit`, `coder_status` and `coder_cancel` in owner
DMs and configured group topics. Submission always uses the durable Telegram approval path, then runs
in the background through your native Codex installation and its configured integrations.
`execute_code` keeps the VM sandbox described above.

In `coder_submit`, `task` describes the requested work and expected outcome with enough context for
Coder to work without the chat. `instructions` adds optional user requirements or preferences, such
as preserving a public API; requirements already in `task` need not be repeated. Both are task data,
without higher authority. A GitHub issue may supply the task. The approval card shows the provided
task after secret redaction, or the selected issue when no task text was supplied. Nonblank
`instructions` appear in full under **Additional requirements**, also after secret redaction;
absent or whitespace-only input hides that section.

| Variable                         | Default / accepted value                                                         |
| -------------------------------- | -------------------------------------------------------------------------------- |
| `CLAW_CODER_ENABLED`             | `false`; strict boolean (`true`/`false`, `yes`/`no`, `on`/`off`, `1`/`0`)        |
| `CLAW_CODER_MAX_CONCURRENT_JOBS` | `1`; any positive integer                                                        |
| `CLAW_CODER_JOB_TIMEOUT_SECONDS` | `1800`; integer seconds from 1 through 86400                                     |
| `CLAW_CODER_EXECUTABLE`          | `codex`; program name or absolute executable path, without command arguments     |
| `CLAW_CODER_PATH`                | Unset; optional colon-separated absolute directories used only by Coder children |
| `CLAW_CODER_PROFILE`             | Unset; optional existing Codex profile name                                      |
| `CLAW_CODER_CONFIG_HOME`         | Unset; optional absolute directory for the child's `CODEX_HOME`                  |

Omit optional settings to use defaults; explicit blank or invalid settings fail configuration even
with Coder disabled. Parsing does not check the executable, credentials or directory. These settings
apply after daemon restart. The backend child uses Codex-owned login/configuration, separately from
`clawd auth`; its working directory and profile are not isolation boundaries. Coder's concurrency
bound and timeout do not impose a hard dollar cap. Child-reported usage belongs to the Coder result,
not ordinary provider accounting; missing usage means accounting is unavailable.

The recommended setup is `clawd coder setup`, run from a terminal where Codex and its dependencies
already work. It keeps the invoking terminal's absolute PATH entries, removes duplicates without
changing their order, and proposes `CLAW_CODER_PATH` plus `CLAW_CODER_ENABLED=true`. Existing literal
env-file assignments take precedence over the terminal for local checks, so a configured executable,
profile or config home is preserved. Setup then overrides only the proposed Coder path and enabled
flag. Use `--dry-run` to inspect the checks and proposed settings without writing, or
`--env-file PATH` to select a file other than `$CLAW_ENV_FILE` / `~/.swift-claw/clawd.env`.

The console keeps the diagnostic checks and resolved Codex, optional `gh`, and optional `node` paths.
It summarizes `coder.path` as the number of captured directories and describes the settings it will
save without printing the full path assignment. `--dry-run` uses the same summary and explicitly says
that it did not change the configuration file.

Setup reads the env file as data; it never sources or executes it. It accepts one-line literal
`KEY=value` assignments, optionally prefixed by `export`, optionally quoted, with comments. Shell
expansion and multiline values are rejected before mutation. A successful write atomically replaces
the resolved file target at mode `0600`, preserving unrelated contents and the symlink at the path the
operator supplied. It changes no secret, dependency, credential, shell startup file or service state.

The backend resolves the selected executable once against its effective child `PATH`; an explicit
absolute path never falls back to another binary. `CLAW_CODER_PATH` overrides only Coder children;
when unset, the existing process-PATH then `/usr/bin:/bin` fallback remains. Explicit blank values,
relative directories and empty path segments fail config validation. The effective path participates
in the execution-policy identity, so a path change cannot reuse an approval for another toolchain.
The backend checks `--version` and `exec --help` before inference
and refuses installations missing the required automatic-review/schema flags. The validated recipe
uses `exec --approve-for-me` with `approval_policy="on-request"`; a refusal never triggers a broader
permission mode. See the [backend recipe](LOCAL_DEV.md#codex-backend-development).

The child receives basic OS/toolchain and locale settings plus `CODEX_HOME`, `GH_CONFIG_DIR`,
`GH_HOST`, `GH_TOKEN`, `GITHUB_TOKEN`, and `SSH_AUTH_SOCK` when selected. Telegram tokens, ordinary
LLM provider keys, and other `CLAW_*` values are excluded. The config-home override changes only
the child's `CODEX_HOME`. Existing Codex integrations can use their own credentials and remain
part of the trusted installation. swift-claw never imports that login state into `clawd auth`.
Interactive-shell access is not proof that launchd/systemd has the same authorization. Setup reports
resolved Codex, optional `gh` and optional `node` paths for its local checks. Restart the real service,
then inspect `/status`: the Coder headline includes the effective path's directory count and resolved
Codex and `gh` executables, plus `node` when resolved. This verifies the loaded service configuration, while
authentication remains a separate runtime fact. Rerun setup after nvm or other tool-path changes.

Local paths refer to the daemon machine. In-place accepts dirty work; a separate copy is ref-only,
with no uncommitted overlay. PRs require your configured repository rights; local PR preparation
refuses an origin whose fetch and push URLs name different repositories, including a preconfigured
fork push URL. Use an explicit GitHub source or an unambiguous origin. There is no automatic
apply-back or rollback, and no automatic dependency provisioning. N is configurable; full means busy,
without a queue. Completion uses existing outbox retries and needs no new LLM turn. Ask to inspect or
cancel a job by its UUID; `/stop` only stops the conversation turn. Child billing is separate from
conversational `/cost`, and Coder's limit/timeout cannot enforce a hard dollar cap.

To use Coder in a group, add its Telegram chat ID to `CLAW_GROUP_CHATS` and keep that deployment on a
separate nonpersonal state root, as described in [LOCAL_DEV.md](LOCAL_DEV.md#group-mode-telegram-forum-supergroup).
Make the bot a group administrator: Telegram guarantees `getChatMember` checks for other users only
for administrators. `coder_submit` is the one group tool that always parks an approval. Its Rich
Markdown card shows the complete source, workspace, start ref, deliverable, PR target/base,
existing-change scope, exact secret-redacted task and any **Additional requirements**. Any current
participant, including the requester, may approve or deny only from that original prompt; every tap
performs a fresh membership check and failure leaves the approval pending. The requester remains the
job identity, and only that person can use status or cancel from the same group topic. Existing group
auto-run/refusal behavior for all other tools is unchanged. Completion returns to the original topic
as a result card with state, summary, failure/publication/checks and changed files first, followed by
compact job, commit, actor and usage details.

Disabled Coder contributes no tools, admits no work and launches no probes. On restart it still
reconciles jobs admitted while enabled: unfinished jobs become interrupted with one completion notice,
and uncertain process ownership retains its reservation. Missing/incompatible Codex leaves the
assistant available with a failed Coder health row and no submit tool. An unprofiled local login-status
failure blocks submit; authenticate Codex under the daemon user and restart. `doctor --check-config`
performs no Codex probe and labels enabled runtime availability/authentication unverified. While Coder
is enabled, full doctor and startup run bounded local version/help/status checks without inference,
credential refresh, repository creation or publication. CLI compatibility and a present local login
do not prove runtime authorization.
Codex CLI cannot inspect a selected profile's authentication through `login status`: that health row
is explicitly unverified and fails doctor, while compatible operator-approved profile jobs remain
available. A profile can still fail authentication during execution; clawd does not refresh/import
credentials or retry with broader permissions. An owner who accepts that limitation can start `clawd run`
directly even when doctor withholds its healthy-start hint.

The running daemon reports live fatal service failures separately from the persisted reservation
count, unresolved ownership and last terminal failure. An external doctor labels live-only observations
unavailable and reads persisted reservations. These historical rows remain visible in full doctor and
daemon health with Coder disabled; `--check-config` does not read job history.
Unreadable storage is a failed row, never a healthy zero.
`coder.last_failure` is the most recently updated failed/timed-out/interrupted record, including
released jobs; recovery updates can reorder it. It is historical evidence, separate from current
CLI/auth availability. Child-reported checks/usage remain in each job's result.

Interrupted jobs are never automatically rerun. Unresolved process ownership retains its slot across
daemon restarts; see the [operator recovery path](LOCAL_DEV.md#coder-background-lifecycle-and-recovery).

## MCP servers

clawd can borrow tools from [MCP](https://modelcontextprotocol.io) servers you already use — an
issue tracker, a notes service, anything speaking Streamable HTTP. It is a client only: it consumes
tools and exposes none of its own.

List your servers in `~/.swift-claw/mcp.yaml` (or point `CLAW_MCP_CONFIG` at another path). No file
means no MCP tools and no change to anything else:

```yaml
servers:
  - name: linear
    url: https://mcp.linear.app/mcp
    # authHeader: Authorization      # default; the token goes out as "Bearer <token>"
    # connectTimeoutSeconds: 10      # default
    # requestTimeoutSeconds: 30      # default
    headers: # non-secret extras sent on every request; never a token
      X-Workspace: acme
    tools:
      include: [list_issues, create_issue] # server's own names; with include set, exclude is ignored
      risk:
        list_issues: safe # skip the approval tap for this one tool
  - name: notes
    url: http://127.0.0.1:8080/mcp
    enabled: false
    tools:
      exclude: [delete_note] # used only when include is absent
```

clawd refuses a `headers` entry named the same as `authHeader`. It also rejects malformed names and
values, case-insensitive duplicates, and fields that control MCP, request authority, or HTTP framing,
such as `Content-Type`, `Host`, `Content-Length`, and `Mcp-Session-Id`. Set `tools.include: []` when
you want a configured server to contribute no tools.

**No tokens in this file.** Store each one encrypted instead, with the daemon stopped — clawd reads
tokens once at startup:

```bash
clawd mcp set-token linear      # reads the token from stdin, never from the command line
```

Add the server to `mcp.yaml` first. The token is bound to that server's configured URL, so
`set-token` refuses a name the file does not declare (exit 10). `clear-token` takes a bare name, so
a token left behind by a server you have since deleted can still be removed.

The token is bound to that server's URL. Re-point the server at a different URL and clawd treats the
token as missing rather than handing your credential to a new host; run `set-token` again.
`clawd mcp clear-token <name>` removes one.

Two commands report on your servers, and they answer different questions:

```bash
clawd mcp list     # config and token state, contacts nothing
clawd mcp probe    # connects, initializes, counts the tools each server would contribute
```

`clawd doctor` runs both, and `/mcp` in Telegram reports what the running daemon actually loaded.
That command is status-only by design: adding a server, changing the catalog, and touching a token
are config-and-CLI jobs, so nothing the model reads can talk clawd into any of them.

Remote tools show up as `mcp__<server>__<tool>` alongside the built-ins, and clawd treats them as
the least-trusted tools it has:

- **Each tool asks for approval by default.** `risk: <tool>: safe` drops that default tap for a tool
  you name. The exfiltration gate above can still require approval, and config cannot push an MCP
  tool up to the sandbox tier.
- **Results come back as untrusted content**, so a remote call taints the session for the
  exfiltration gate above the same way a web page does.
- **Calling one counts as egress to an arbitrary destination**, and that is not configurable.

The catalog is fixed at startup. A server that is down, slow, or misbehaving is skipped with a
reason `clawd doctor` and `/mcp` will show, and clawd starts anyway with the rest. A mistake in
`mcp.yaml` is yours to fix rather than a server's, so it stops startup with exit 10 — a misspelled
key included. When the set of tools changes across a restart, clawd voids any approval still
waiting from before. Changing a server endpoint, its static request headers or auth-header name, or
the remote operation behind a normalized name also voids the approval. Approval cards show the
complete configured endpoint.

A skipped server is not a boot failure, but it _is_ a doctor failure: `clawd doctor` reports the
skip, exits 1, and withholds the start command it normally ends with. The daemon itself comes up
fine — start it directly if you know that server is down. A token bound to a URL the config no
longer uses fails `clawd doctor --check-config` the same way, with exit 10; `clawd mcp set-token
<name>` repairs it.

## Everything else

- `CLAW_ALLOWLIST`: numeric Telegram IDs, comma-separated, seeded into the allowlist at
  every daemon start. **Seeding only adds.** The `allowlist` table in `claw.sqlite` is what
  the daemon enforces, so removing an ID here does not revoke it. To revoke
  access, stop the daemon, drop the ID from `CLAW_ALLOWLIST`, and delete the row from the
  database in your state root (the `sqlite3` CLI is its own package on Linux:
  `sudo apt-get install -y sqlite3`):
  `sqlite3 "${CLAW_STATE_ROOT:-$HOME/.swift-claw}/claw.sqlite" "DELETE FROM allowlist WHERE user_id = <id>;"`
- `CLAW_GROUP_CHATS`: comma-separated Telegram group/supergroup chat IDs served as shared rooms.
  Keep this off for a personal state root. A group deployment trusts participant text in its topic
  history and has relaxed tool approval behavior except for Coder submission, so run it under a
  separate nonpersonal state root and review
  [LOCAL_DEV.md](LOCAL_DEV.md#group-mode-telegram-forum-supergroup) before enabling it.
- `CLAW_APPROVAL_EXPIRY`: seconds before a pending approval auto-denies (default 3600).
- `CLAW_SEARCH_API_KEY`: Exa key; unset means the `web_search` tool is absent. Adding it
  after you have sealed does nothing on its own: once `secrets.enc` exists the daemon reads
  secrets only from there. See [Adding a secret later](#adding-a-secret-later).
- `CLAW_WEBFETCH_EXEMPT_CIDRS`: SSRF-blocklist exemptions for fake-IP VPN pools.
- `CLAW_MCP_CONFIG`: path to the MCP server catalog. Unset, clawd looks for `mcp.yaml` in the state
  root and runs without MCP tools when it is absent. See [MCP servers](#mcp-servers).
- `CLAW_LOG_LEVEL`: `trace`, `debug`, `info` (default), `notice`, `warning`, `error`, `critical`.
- `CLAW_STATE_ROOT`: where all of it lives (default `~/.swift-claw`).

## Adding a secret later

Sealing writes one envelope holding every runtime secret, and from then on the daemon
ignores secrets in the environment. Turning on `web_search` months later, or rotating a
key, therefore means resealing the whole set rather than adding a line to `clawd.env`.

Stop the daemon first; sealing takes the same state-root lock. Put **all** the secrets you
want back in the environment, not just the new one, since the reseal replaces the envelope:

```bash
export CLAW_TELEGRAM_BOT_TOKEN=...     # the values the first seal blanked from clawd.env
export CLAW_LLM_API_KEY=...
export CLAW_LLM_FALLBACK_API_KEY=...   # only if you run a fallback route
export CLAW_SEARCH_API_KEY=...         # the one you are adding
clawd secrets seal
```

Then clear them from your shell (or close it), and start the daemon again. `clawd doctor`
confirms the result: the `web_search` row turns from absent to configured.
