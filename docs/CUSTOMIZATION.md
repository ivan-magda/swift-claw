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

The trust tier decides how much authority the text carries:

- **`SOUL.md`, `AGENTS.md`, and `TOOLS.md` join the system prompt.** You write them, and
  the model treats them as trusted instruction. They also feed the policy fingerprint, so
  editing one invalidates any approval still waiting on the old prompt. Nothing you put in
  them can loosen the security policy, which lives in code rather than in the prompt.
- **`USER.md` and `MEMORY.md` enter inside an untrusted, labeled wrapper**, below the
  system prompt, so text that reached them through poisoned memory cannot claim system
  authority. Both count as private data for the exfiltration gate below.

When the agent writes to `SOUL.md`, `AGENTS.md`, `USER.md`, or `MEMORY.md`, the approval
card carries a privileged-file banner. `TOOLS.md` does not get one.

The agent writes and reads dated daily logs (`memory/YYYY-MM-DD.md`) when a turn calls for
one; the context builder never injects them the way it injects the files above.

Durable facts also live in the database: confirm something in chat ("remember that ...")
and it persists in SQLite across restarts, recalled by importance and recency. Full-text
search covers conversation history, not these facts. `/memory` shows what is stored.

## When the agent asks permission

clawd shows an approval card for two reasons.

**The tool's own risk tier.** File writes, memory writes, and code execution park the run
every time, whatever else the session did.

**Exfiltration risk.** clawd holds an arbitrary-destination tool call, including `web_fetch`
and MCP calls, for your approval once the session has done *both* of these:

- **Ingested untrusted content.** A web page, a file read, tool output, a voice transcript,
  or a photo. Durable memory does not count: it is labeled untrusted but does not taint
  the session on its own.
- **Touched private data.** Assembling `USER.md`, `MEMORY.md`, or stored memory items into
  the context is enough; no tool has to read them. Once you have filled in `USER.md`, this
  leg is armed on essentially every turn, and it sticks for the session.

One leg alone does not trigger the gate, so the first `web_fetch` or safe MCP call of a clean
session runs unprompted. `/new` clears both legs.

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
    headers:                         # non-secret extras sent on every request; never a token
      X-Workspace: acme
    tools:
      include: [list_issues, create_issue]   # server's own names; with include set, exclude is ignored
      risk:
        list_issues: safe                    # skip the approval tap for this one tool
  - name: notes
    url: http://127.0.0.1:8080/mcp
    enabled: false
    tools:
      exclude: [delete_note]                 # used only when include is absent
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

A skipped server is not a boot failure, but it *is* a doctor failure: `clawd doctor` reports the
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
export CLAW_TELEGRAM_BOT_TOKEN=...   # the values the first seal blanked from clawd.env
export CLAW_LLM_API_KEY=...
export CLAW_SEARCH_API_KEY=...       # the one you are adding
clawd secrets seal
```

Then clear them from your shell (or close it), and start the daemon again. `clawd doctor`
confirms the result: the `web_search` row turns from absent to configured.
