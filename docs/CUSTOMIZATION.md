# Customizing Your Agent

You shape your agent in two places: Markdown files in the workspace (persona, rules,
profile) and environment variables (wiring, budgets, features).
[`.env.example`](../.env.example) stays the complete variable reference.

## Workspace files

The workspace lives at `<state root>/workspace/` (default `~/.swift-claw/workspace/`).
Create any of these files and the daemon loads them on the next turn; it skips the ones
you leave out.

| File | What it shapes | Trust tier |
|---|---|---|
| `SOUL.md` | Personality and tone. The place to say "answer tersely", "be playful", "reply in Russian". | System prompt |
| `AGENTS.md` | Behavior rules: how to act, what to prioritize, standing instructions. | System prompt |
| `TOOLS.md` | Guidance on when and how to use tools. | System prompt |
| `USER.md` | Your profile: who you are, context the agent should know. | Untrusted, labeled |
| `MEMORY.md` | Long-lived memory the agent maintains. | Untrusted, labeled |
| `HEARTBEAT.md` | A checklist the proactive heartbeat reads, never ordinary turns. | Heartbeat runs only |
| `skills/<name>/SKILL.md` | A procedure the agent loads when the task calls for it. See [Skills](#skills). | Untrusted, labeled |

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

When a skill does not make it into context, the reply says so above the answer — and keeps
saying it until you fix the file, since the scan runs fresh on every turn:

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

## When the agent asks permission

clawd shows an approval card for two reasons.

**The tool's own risk tier.** File writes, memory writes, and code execution park the run
every time, whatever else the session did.

**Exfiltration risk.** clawd holds a fetch to an arbitrary URL for your approval once the
session has done *both* of these:

- **Ingested untrusted content.** A web page, a file read, tool output, a voice transcript,
  or a photo. Durable memory and a skill you loaded do not count: both are labeled
  untrusted, and neither taints the session on its own.
- **Touched private data.** Assembling `USER.md`, `MEMORY.md`, or stored memory items into
  the context is enough; no tool has to read them. Once you have filled in `USER.md`, this
  leg is armed on essentially every turn, and it sticks for the session.

One leg alone does not trigger the gate, so the first `web_fetch` of a clean session runs
unprompted. `/new` clears both legs.

Your LLM provider and the search backend are pinned destinations, so they never park for
approval: no injected instruction can aim clawd at an attacker's URL instead. clawd also
scans outbound *tool* arguments for secret-shaped values, and, under the trifecta, for
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

## Spending limits

All optional; unset means the built-in defaults.

| Variable | Controls |
|---|---|
| `CLAW_PER_RUN_USD` | Cap per single run |
| `CLAW_PER_DAY_USD` | Daily spend kill-switch |
| `CLAW_PROACTIVE_PER_DAY_USD` | Nested daily cap for scheduled + heartbeat runs (default 2.00) |
| `CLAW_MAX_TURNS` / `CLAW_MAX_TOOL_CALLS` | Bounds on the agentic loop per run |

**On the ChatGPT subscription route these dollar caps do not gate.** A plan-included call
has no metered cost to compare against, so `CLAW_PER_RUN_USD` and
`CLAW_PROACTIVE_PER_DAY_USD` are inert there, and clawd records the usage at zero USD.
`CLAW_PER_DAY_USD` still binds indirectly, because the daily token ceiling derives from it;
set `CLAW_DAY_TOKEN_CEILING` to control that directly. Token, turn, tool-call, and
wall-clock bounds apply the same on both routes.

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

## Everything else

- `CLAW_ALLOWLIST`: numeric Telegram IDs, comma-separated, seeded into the allowlist at
  every daemon start. **Seeding only adds.** The `allowlist` table in `claw.sqlite` is what
  the daemon enforces, so removing an ID here does not revoke it. To revoke
  access, stop the daemon, drop the ID from `CLAW_ALLOWLIST`, and delete the row from the
  database in your state root (the `sqlite3` CLI is its own package on Linux:
  `sudo apt-get install -y sqlite3`):
  `sqlite3 "${CLAW_STATE_ROOT:-$HOME/.swift-claw}/claw.sqlite" "DELETE FROM allowlist WHERE user_id = <id>;"`
- `CLAW_APPROVAL_EXPIRY`: seconds before a pending approval auto-denies (default 3600).
- `CLAW_SEARCH_API_KEY`: Exa key; unset means the `web_search` tool is absent. Adding it
  after you have sealed does nothing on its own: once `secrets.enc` exists the daemon reads
  secrets only from there. See [Adding a secret later](#adding-a-secret-later).
- `CLAW_WEBFETCH_EXEMPT_CIDRS`: SSRF-blocklist exemptions for fake-IP VPN pools.
- `CLAW_LOG_LEVEL`: `trace`, `debug`, `info` (default), `notice`, `warning`, `error`, `critical`.
- `CLAW_STATE_ROOT`: where all of it lives (default `~/.swift-claw`).

## Adding a secret later

Sealing writes one envelope holding every runtime secret, and from then on the daemon
ignores secrets in the environment. Turning on `web_search` months later, or rotating a
key, therefore means resealing the whole set rather than adding a line to `clawd.env`.

Stop the daemon first; sealing takes the same state-root lock. Put **all** the secrets you
want back in the environment, not just the new one, since the reseal replaces the envelope:

```bash
export CLAW_TELEGRAM_BOT_TOKEN=...   # the values the first seal blanked from clawd.env
export CLAW_LLM_API_KEY=...
export CLAW_SEARCH_API_KEY=...       # the one you are adding
clawd secrets seal
```

Then clear them from your shell (or close it), and start the daemon again. `clawd doctor`
confirms the result: the `web_search` row turns from absent to configured.
