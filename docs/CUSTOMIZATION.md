# Customizing Your Agent

Two surfaces shape how your agent behaves: Markdown files in the workspace (persona,
rules, profile) and environment variables (wiring, budgets, features). This guide covers
both. [`.env.example`](../.env.example) stays the complete variable reference.

## Workspace files

The workspace lives at `<state root>/workspace/` (default `~/.swift-claw/workspace/`).
Create any of these files and the daemon loads them on the next turn; a missing file is
skipped.

| File | What it shapes | Trust tier |
|---|---|---|
| `SOUL.md` | Personality and tone. The place to say "answer tersely", "be playful", "reply in Russian". | System prompt |
| `AGENTS.md` | Behavior rules: how to act, what to prioritize, standing instructions. | System prompt |
| `TOOLS.md` | Guidance on when and how to use tools. | System prompt |
| `USER.md` | Your profile: who you are, context the agent should know. | Untrusted, labeled |
| `MEMORY.md` | Long-lived memory the agent maintains. | Untrusted, labeled |
| `HEARTBEAT.md` | A checklist the proactive heartbeat reads, never ordinary turns. | Heartbeat runs only |

The trust tier decides how much authority the text carries:

- **`SOUL.md`, `AGENTS.md`, and `TOOLS.md` join the system prompt.** They are yours to
  write and the model treats them as trusted instruction. Editing one changes the policy
  fingerprint, which is why a `file_write` to any of them is flagged as privileged and why
  pending approvals do not survive the change. Nothing you put in them can loosen the
  security policy, which lives in code rather than in the prompt.
- **`USER.md` and `MEMORY.md` enter inside an untrusted, labeled wrapper**, below the
  system prompt, so text that arrived there through poisoned memory cannot claim system
  authority. Both count as private data for the exfiltration gate described below.

Dated daily logs (`memory/YYYY-MM-DD.md`) are written and read on request; the context
builder does not inject them automatically the way it does the files above.

Durable facts also live in the database: confirm something in chat ("remember that ...")
and it persists in SQLite with full-text recall across restarts. `/memory` shows what is
stored.

## When the agent asks permission

Two separate mechanisms decide this, and it is worth knowing which one is speaking.

**By tool.** File writes and code execution always suspend the run and wait for you,
whatever else happened in the session.

**By exfiltration risk.** Fetching an arbitrary URL waits for you once the session has
done *both* of these: ingested untrusted content (a web page, tool output, stored memory)
and read a private-data file (`USER.md`, `MEMORY.md`). One leg alone does not trigger it,
so the first `web_fetch` of a clean session runs unprompted. Traffic to pinned endpoints,
your LLM provider and the search backend, never parks for approval; those are protected
by endpoint pinning plus an argument scan that blocks private-file content and
secret-shaped tokens.

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
| `CLAW_PER_DAY_USD` | Daily kill-switch across everything |
| `CLAW_PROACTIVE_PER_DAY_USD` | Nested daily cap for scheduled + heartbeat runs (default 2.00) |
| `CLAW_MAX_TURNS` / `CLAW_MAX_TOOL_CALLS` | Bounds on the agentic loop per run |

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

## Code execution sandbox (macOS 26 arm64)

Off by default. `CLAW_EXEC_ENABLED=true` lets the agent run code in a fresh disposable
VM per request, behind an exact-action approval. Resource limits
(`CLAW_EXEC_MEMORY_MIB`, `CLAW_EXEC_CPUS`, `CLAW_EXEC_TIMEOUT`), the digest-pinned
workload image, and the network opt-in (`CLAW_EXEC_ALLOW_EGRESS`) are documented in
[`.env.example`](../.env.example) and [LOCAL_DEV.md](LOCAL_DEV.md).

## Everything else

- `CLAW_ALLOWLIST`: who may talk to the bot (comma-separated numeric Telegram IDs).
- `CLAW_APPROVAL_EXPIRY`: seconds before a pending approval auto-denies (default 3600).
- `CLAW_SEARCH_API_KEY`: Exa key; unset means the `web_search` tool is absent.
- `CLAW_WEBFETCH_EXEMPT_CIDRS`: SSRF-blocklist exemptions for fake-IP VPN pools.
- `CLAW_LOG_LEVEL`: `trace`, `debug`, `info` (default), `notice`, `warning`, `error`, `critical`.
- `CLAW_STATE_ROOT`: where all of it lives (default `~/.swift-claw`).
