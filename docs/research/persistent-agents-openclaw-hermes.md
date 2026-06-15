# Building Persistent, Multi-Channel Personal AI Agents: A Source-Grounded Architectural Study of OpenClaw and Hermes Agent

*Prepared for Ivan (agent-runtime engineer, author of `swift-claude-code`). Goal: understand the architecture deeply enough to rebuild in Swift/Kotlin or write a teaching series. Claims are pinned to source files where possible; where docs and code disagree, code wins and the gap is flagged. "Not present" means I could not find it in code/docs, not that it is impossible.*

> **Sourcing caveat up front.** Both repos are real and very active in mid-2026 (Hermes `NousResearch/hermes-agent`; OpenClaw `openclaw/openclaw`). I verified against GitHub source files, the two official docs sites (`hermes-agent.nousresearch.com/docs`, `docs.openclaw.ai`), DeepWiki, and GitHub issues. Several third-party "guide" sites carry **fabricated stats** (e.g. "250,829 GitHub stars, overtook React"; "CrowdStrike found 42,000 exposed instances"). I treat those as unreliable. For scale: as of June 14, 2026 the GitHub UI for `NousResearch/hermes-agent` shows roughly **193k stars / 33.7k forks** (a maintainer red-team issue, #40889, cites "184,750 stars | 31,711 forks | 245,728 LOC | 2,097 Python files" for v0.16.0). Star counts are approximate and not load-bearing for this analysis.

---

## TL;DR

- **Both systems converge on one invariant: a single reused agent loop (one class/function) behind many thin "surfaces" (CLI, messaging gateway, IDE/ACP, REST), with a local-first long-running gateway daemon, file-based identity/memory, an `agentskills.io`-standard SKILL.md skill system, subagent delegation, and sandboxed tool execution.** Hermes centers everything on the synchronous `AIAgent` class in `run_agent.py`; OpenClaw centers everything on a TypeScript Gateway WebSocket control plane that calls an embedded agent runner built on the "Pi" agent core.
- **They diverge most in what they optimize.** Hermes optimizes *cognition* — a closed learning loop (autonomous skill creation → self-improvement → cron Curator → optional DSPy/GEPA self-evolution), Programmatic Tool Calling via `execute_code`, OpenAI-compatible REST, ACP, trajectory export. OpenClaw optimizes *surface area and presence* — 25 channels, device "nodes" with pairing, Voice Wake/Talk Mode, an agent-driven A2UI Canvas, and a hardened multi-tenant gateway with per-channel DM policies.
- **For Ivan's rebuild:** his `swift-claude-code` already has the hard core (loop, file-based task DAG, sub-agents, compaction, background tasks, skill loader). The highest impact-to-complexity additions, in order, are: (1) a persistent file-based memory layer (`MEMORY.md`/`USER.md` + flush-before-compact), (2) a messaging gateway with one channel adapter + DM allowlist, (3) natural-language cron with delivery routing, (4) autonomous skill creation + a Curator, (5) a sandbox backend abstraction, then (6) ACP server and (7) trajectory export. Skill files are already portable across both systems via SKILL.md — steal that contract first.

---

## Key Findings

1. **One core, many surfaces is the load-bearing idea.** Hermes: "The agent core is `AIAgent` in `run_agent.py`. All other subsystems — gateway, CLI, ACP server, cron scheduler — use this single agent core." OpenClaw: the Gateway is "just the control plane"; a single embedded agent runtime executes the loop and every channel/companion app is a WebSocket client.
2. **Loops are ReAct and (mostly) synchronous.** Hermes' loop is explicitly synchronous/single-threaded with `ThreadPoolExecutor` only for parallel tool calls in one turn; default hard cap **90 iterations** (`agent.max_turns`), subagents get an independent **50** (`delegation.max_iterations`). OpenClaw serializes runs per session via a **lane queue** (session lane + optional global lane) and emits `lifecycle`/`assistant`/`tool` stream events.
3. **Identity/memory/skills are plain files, deliberately.** Hermes: `SOUL.md` (identity, slot #1 in prompt), `MEMORY.md` (~2,200 char cap), `USER.md` (~1,375 char cap), skills in `~/.hermes/skills/`. OpenClaw: `AGENTS.md`/`SOUL.md`/`TOOLS.md`/`USER.md`/`BOOTSTRAP.md` injected on first turn; skills in `~/.openclaw/workspace/skills/<skill>/SKILL.md`; JSONL transcripts at `~/.openclaw/agents/<agentId>/sessions/<sessionId>.jsonl`.
4. **The skill *file* is portable; the *loop around it* is not.** Both implement the `agentskills.io` open standard (SKILL.md = YAML frontmatter + markdown body, progressive disclosure: ~name/description at startup, full body on activation, references on demand). Hermes adds autonomous creation (after 5+ tool calls), self-patching, and the cron Curator. OpenClaw adds ClawHub registry + signed trust envelopes + a Skill Workshop proposal flow.
5. **Sandbox/trust boundary is treated as the #1 security surface in both.** Inbound DMs are untrusted input → tool families are gated. The OpenClaw README states verbatim: "Typical sandbox default: allow bash, process, read, write, edit, sessions_list, sessions_history, sessions_send, sessions_spawn; deny browser, canvas, nodes, cron, discord, gateway. Docker is the default sandbox backend; SSH and OpenShell backends are also available." Hermes runs commands in one of seven terminal backends and treats OS-level isolation as the primary trust boundary.
6. **The two systems are designed to interoperate.** Hermes ships `hermes claw migrate` (imports SOUL.md, MEMORY.md/USER.md, skills, allowlists, keys from `~/.openclaw`). The community `HermesClaw` bridge proves the shared contract: both speak the same WeChat iLink transport and both consume SKILL.md, so a proxy can fan one account out to both gateways.

---

## Part 1 — OpenClaw (TypeScript/Node, pnpm monorepo)

### 1. Agent core and main loop
OpenClaw's runtime lives under `src/agents/`. Per `docs.openclaw.ai/agent-runtime-architecture`: `src/agents/embedded-agent-runner/` holds the "built-in agent attempt loop, provider stream adapters, compaction, model selection, and session wiring"; `packages/agent-core/` is the "reusable agent core … messages, compaction helpers, prompt templates, and tool/session contracts"; `src/agents/runtime/` is "OpenClaw facade for `@openclaw/agent-core`." **Code-vs-docs gap (flag):** actual code references (GitHub issues, DeepWiki) use the on-disk path `src/agents/pi-embedded-runner/` — `run.ts` (the `while(true)` attempt loop: on contextOverflow → compact + continue, on authError → rotate key + continue), `run/attempt.ts` (`runEmbeddedAttempt`, a single model invocation), `run/stream-processor.ts` (`processAgentStream`, switching on `content`/`reasoning`/`tool_call_start` chunks), `run/tool-executor.ts`, `run/payloads.ts`. The embedded runtime is built on the upstream `@mariozechner/pi-coding-agent` SDK (`createAgentSession`, `SessionManager`). The 48-hour run abort timer is "enforced in `runEmbeddedAgent`" per docs. A separate `runCliAgent` path wraps provider CLIs (Claude Code, Codex CLI, Gemini CLI) as alternative runtimes. **Same core reused across surfaces** via the Gateway: the `agent` and `agent.wait` RPCs (and the `openclaw agent` CLI) are the entry points; everything else is a WebSocket client.

- *Ivan analog:* **HAS** — his single loop + ContextCompactor is the direct analog. OpenClaw's twist worth stealing: the explicit **lane queue** serializing per-session runs and a state-machine framing (queues → attempts → streaming → compaction → complete/fail) with steer/abort.

### 2. Gateway / control plane
The Gateway is a single always-on Node process (the `ws` library), default port **18789**, bind `loopback` by default; installed as a launchd (macOS) / systemd (Linux) user service via `openclaw onboard --install-daemon`. It is "the only process that holds messaging sessions," multiplexing WS + HTTP on one port. State lives under `~/.openclaw/` (or `~/.openclaw-<profile>/`). The RPC protocol is versioned. Per `docs/gateway/protocol.md`, verbatim: "PROTOCOL_VERSION lives in `packages/gateway-protocol/src/version.ts`. Clients send minProtocol + maxProtocol; the server rejects ranges that do not include its current protocol." **Code-vs-docs gap (flag):** a current-main issue shows the constant living at `src/gateway/protocol/version.ts` and bumped to `5` (`export const PROTOCOL_VERSION = 5 as const`), while docs still say v4 — the protocol is in flux v4→v5 in mid-2026. Session routing: a **SessionKey** like `slack:C12345:T67890` maps channel+account+thread to state; multi-agent routing binds inbound channels/accounts/peers to isolated agents (each with its own workspace + per-agent sessions). The device handshake uses a challenge nonce: the Gateway sends `connect.challenge` and the client must sign the payload (v2/v3) including the server nonce. Companion apps/nodes connect over the same WS.

- *Ivan analog:* **LACKS** — this is the single biggest missing block (messaging gateway + session routing + multi-tenancy). Highest-value new subsystem.

### 3. Channel adapters
Channels normalize heterogeneous platforms into one message/event envelope. The full supported set, verbatim from the README: "WhatsApp, Telegram, Slack, Discord, Google Chat, Signal, iMessage, IRC, Microsoft Teams, Matrix, Feishu, LINE, Mattermost, Nextcloud Talk, Nostr, Synology Chat, Tlon, Twitch, Zalo, Zalo Personal, WeChat, QQ, WebChat, macOS, iOS/Android." Each implements a ChannelPlugin interface; WhatsApp uses Baileys, Telegram grammY, Discord discord.js. **Smallest contract to add a channel:** implement the channel plugin (inbound normalize → envelope, outbound send), register it, and declare DM/group policy. **DM safety policies** are first-class and per-channel: `dmPolicy` = `pairing` (default; unknown sender gets a 6-digit code, max 3 pending/channel, 1-hour expiry, approve via `openclaw pairing approve <channel> <code>`) | `allowlist` | `open` (requires explicit `allowFrom: ["*"]`) | `disabled`. Group messages default to require-mention. `accessGroups` share trusted-sender sets across channels; approving a DM pairing code also bootstraps `commands.ownerAllowFrom` for the first owner. **Streaming vs edit fallback:** Telegram supports block streaming/edits; non-Telegram channels require explicit `*.blockStreaming: true`; tune via `blockStreamingBreak`/`blockStreamingChunk` (default 800–1200 chars)/`blockStreamingCoalesce`.

- *Ivan analog:* **LACKS** — channel adapter shape + DM pairing policy is a clean, copyable contract.

### 4. Workspace, sessions, memory
Workspace root `~/.openclaw/workspace`. On first turn, OpenClaw injects `AGENTS.md` (operating instructions + "memory"), `SOUL.md` (persona), `TOOLS.md` (user tool notes), `USER.md` (profile), `BOOTSTRAP.md` (one-time, deleted after). Sessions are JSONL transcripts at `~/.openclaw/agents/<agentId>/sessions/<sessionId>.jsonl` (stable, OpenClaw-chosen IDs), guarded by a process-aware file write-lock. **Memory is layered and pluggable:** builtin memory engine (SQLite, hybrid BM25 + vector via FTS5); a **QMD** engine (`memory.backend="qmd"`, a local-first BM25+vector+rerank sidecar, home `~/.openclaw/agents/<agentId>/qmd/`); a **Honcho** memory option; an **Active Memory** blocking sub-agent that runs *before* the main loop to inject relevant history/"beliefs"; and **Dreaming** — a three-phase (light/deep/REM) background consolidation cron that promotes durable facts into `MEMORY.md` and surfaces themes in `DREAMS.md`. **Compaction (`/compact`)** does a two-step: a silent **pre-compaction memory flush** (`runMemoryFlushIfNeeded`) so durable facts are written before history is summarized, then summarization preserving the unsummarized tail; hooks `before_compaction`/`after_compaction`.

- *Ivan analog:* **PARTIAL** — HAS compaction; **LACKS** persistent cross-session memory and the flush-before-compact discipline (high value, low complexity).

### 5. Skills system
A skill is a directory with `SKILL.md` (YAML frontmatter, single-line keys only per OpenClaw's parser; minimum `name` + `description`) plus optional `references/`/`scripts/`/`assets/`. Skills live in workspace `skills/` (default) or `~/.openclaw/skills` (`--global`). **ClawHub** is the public registry: `openclaw skills install/update/verify`, signed trust envelopes (`clawhub.skill.verify.v1`), `.clawhub/origin.json` pinning, VirusTotal/ClawScan/static-analysis scan state, MIT-0 licensing. A **Skill Workshop** offers a propose/inspect/apply lifecycle (`openclaw skills workshop list|inspect|apply`). Discovery follows the AgentSkills spec with progressive disclosure (metadata listed, body loaded on demand). **No autonomous Curator** in OpenClaw (that's Hermes); OpenClaw's hardening is supply-chain (verify/scan/pin) rather than lifecycle pruning.

- *Ivan analog:* **HAS** a skill loader; **LACKS** a registry + trust envelopes + autonomous creation.

### 6. Tool surface
Built-in tool families (from `docs.openclaw.ai/tools` group expansions): `group:runtime` (exec, bash, process), `group:fs` (read, write, edit, apply_patch), `group:sessions` (sessions_list, sessions_history, sessions_send, sessions_spawn, session_status), `group:memory` (memory_search, memory_get), `group:web` (web_search via Brave, web_fetch → HTML→markdown, 15-min cache), `group:ui` (browser, canvas), `group:automation` (cron, gateway), `group:messaging` (message), `group:nodes` (nodes), plus image/pdf. Tool definitions live in `src/agents/agent-tools*.ts` (factory `createOpenClawCodingTools`, Claude-style aliases) with individual implementations under `src/agents/tools/` (e.g. `browser-tool.ts`). Policy: `tools.allow`/`tools.deny` (deny wins, wildcards), `tools.profile` (e.g. `coding`, `messaging`), `tools.byProvider`. **MCP** is dual-role: OpenClaw is both an MCP client (consumes configured servers, exposed under the `bundle-mcp` plugin id; stdio + Streamable HTTP/SSE) and an MCP server (channel server, plugin-tools server, openclaw-tools server under `src/mcp/`). **No Programmatic-Tool-Calling/execute_code** equivalent (that is a Hermes invention) — though a "code mode" exposes MCP type signatures via a virtual API file surface.

- *Ivan analog:* **HAS** ~14 tools; **LACKS** MCP integration and execute_code-style pipelines.

### 7. Subagents and delegation
Multi-agent on one Gateway uses cross-session tools: `sessions_list`, `sessions_history <session>`, `sessions_send <session> <message>`, and `sessions_spawn` (params include `task, label, runtime, agentId, model, thinking, cwd, runTimeoutSeconds, sandbox, cleanup`). This enables "one CEO, many specialists" routing via AGENTS.md. There is also a `delegate-architecture` and "parallel specialist lanes" concept. Spawned/cron executions are tracked as background tasks.

- *Ivan analog:* **HAS** — his Task sub-agents are the analog; OpenClaw's `sessions_spawn` is a cleaner cross-session contract.

### 8. Sandboxes / terminal backends
Sandbox modes: `agents.defaults.sandbox.mode` = `non-main` (sandbox only non-main sessions) or `all`. **Backends: Docker (default), SSH, OpenShell.** Default sandbox tool policy (README, verbatim): allow `bash, process, read, write, edit, sessions_list, sessions_history, sessions_send, sessions_spawn`; deny `browser, canvas, nodes, cron, discord, gateway`. Scope `agent` (default) | `session` | `shared`; `workspaceAccess: "none"` by default keeps the real workspace off-limits. Main session is host-trusted by default (tools run directly on host). Elevated exec (`tools.elevated`, `/elevated on|off|ask|full`) bypasses sandbox via a configured escape path. Trust boundary is explicit: inbound DMs are untrusted → sandbox + deny dangerous tools for non-owner agents.

- *Ivan analog:* **LACKS** — sandbox backend abstraction is a discrete, valuable subsystem.

### 9. Scheduling and autonomy
Cron jobs run in the Gateway; isolated cron executions are tracked as background tasks with a cron-owned per-turn `timeoutSeconds`. A `HEARTBEAT.md` drives a cron-triggered "heartbeat" agentic loop (skipped on `empty-heartbeat-file`/`no-tasks-due`/quiet-hours). Delivery routes back to any connected channel. Diagnostics surface job run history (ok/skipped/error) and heartbeat skip reasons.

- *Ivan analog:* **PARTIAL** — HAS background tasks; **LACKS** cron + delivery routing.

### 10. Model abstraction
Providers registered via `api.registerProvider` handle model-specific normalization, streaming, failover. Config uses `provider/model` refs; `agents.defaults.model.primary` + `fallbacks`; `agents.defaults.models` is the catalog/allowlist for `/model`. Auth profile rotation + failover is first-class ("Model failover"). Providers include Anthropic, OpenAI, and many others; per-provider `timeoutSeconds` idle watchdog for slow local endpoints (Ollama).

- *Ivan analog:* **PARTIAL** — likely HAS a provider abstraction; auth-profile rotation/failover is the gap.

### 11. External API surface
The Gateway exposes HTTP endpoints (`/v1/*`, `/tools/invoke`, `/api/channels/*`, `/healthz`, `/readyz`) alongside WS RPC. `openclaw acp` lets OpenClaw **host** a coding harness session and route it through ACP; `openclaw mcp serve` exposes routed channel conversations over MCP. Webhooks/hooks and a rich RPC family (status, channels, models, chat, agent, sessions, nodes, approvals, exec.approval.*, tasks.*, artifacts.*) round it out. **No OpenAI-compatible `/v1/chat/completions` agent endpoint** documented as a first-class feature the way Hermes has it (OpenClaw's `/v1/*` exists, but its headline external contract is WS RPC + ACP-host + MCP-serve).

### 12. Voice and Canvas (OpenClaw-specific)
**Voice Wake + Talk Mode:** wake words on macOS/iOS, continuous voice on Android (ElevenLabs + system TTS fallback). Talk is surfaced via Gateway RPC: `talk.client.create` (webrtc or provider-websocket; Gateway owns config/credentials/tool policy), `talk.session.steer` (`mode` = status|steer|cancel|followup), `talk.session.close`, `talk.client.toolCall` (first supported tool `openclaw_agent_consult`). **Canvas + A2UI:** the `canvas` tool (`skills/canvas/SKILL.md`) actions are `present`, `hide`, `navigate`, `eval`, `snapshot`; the canvas host serves files from `plugins.entries.canvas.config.host.root` on the Gateway HTTP port at `/__openclaw__/canvas/<file>.html`. A2UI is **v0.8 JSONL** server→client messages (`beginRendering`, `surfaceUpdate`, `dataModelUpdate`, `deleteSurface`); `createSurface` (v0.9) is rejected. Node apps render URLs in a WebView; A2UI actions are forwarded back to the agent (`handleCanvasA2UIAction`). These surface to the agent as ordinary tools (`canvas`, `nodes canvas a2ui push`).

- *Ivan analog:* **LACKS** — OpenClaw-specific and lower priority for a teaching series unless targeting consumer UX.

### 13. Companion apps / nodes
Nodes are peripherals (not gateways): macOS menu-bar app (also runs in node mode), iOS/Android apps, Windows Hub. They connect to the Gateway WS with `role: node` and a device identity; the Gateway creates a pairing request approved via `openclaw devices approve <requestId>` / `openclaw nodes approve`. Nodes expose `canvas.*`, `camera.*`, `screen.record`, `location.get` via `node.invoke`; must be foregrounded for canvas/camera (else `NODE_BACKGROUND_UNAVAILABLE`). Discovery via mDNS/Bonjour (`_openclaw-gw._tcp`); device tokens rotate on re-pair; iOS push via a relay. Loopback gateways require an SSH tunnel for remote node hosts.

- *Ivan analog:* **LACKS.**

### 14. Research / training plumbing
**Not present** as a first-class feature. OpenClaw is not built around trajectory export / RL — that is Hermes territory. (OpenClaw has a personal-agent benchmark pack in docs, but no SFT/RL export pipeline.)

### 15. Operator UX
Chat slash commands (README): `/status`, `/new`, `/reset`, `/compact`, `/think <level>`, `/verbose on|off`, `/trace on|off`, `/usage off|tokens|full`, `/restart`, `/activation mention|always`. `openclaw doctor` diagnoses config/DM-policy risks and can `--fix` (chmod state/config, flip groupPolicy open→allowlist); `openclaw security audit [--deep|--fix]` runs 50+ checks across 12 categories. Config hot-reload (`hybrid`/`hot`/`restart`/`off`) with schema-gated writes (invalid external edits saved as `.rejected.*`).

- *Ivan analog:* **PARTIAL** — HAS some commands; doctor/security-audit is a nice operator-UX pattern to copy.

---

## Part 2 — Hermes Agent (Python, single `AIAgent` core)

### 1. Agent core and main loop
The core is the `AIAgent` class in `run_agent.py`. The loop is ReAct and synchronous: build system prompt → check compression → interruptible API call → execute tool calls → loop, terminating when the model returns plain text with no tool calls or the iteration budget is hit. Two entry points: `chat()` (returns final string) wraps `run_conversation()` (returns dict with messages/metadata/usage). `run_conversation()` is the loop (`run_agent.py:2758`). **Three API modes** all normalized to one internal OpenAI-style message format: `chat_completions`, `codex_responses`, `anthropic_messages`. API calls run in a background thread via `_interruptible_api_call()` so a new inbound message / `/stop` / signal can abandon the in-flight response cleanly. **Agent-level tools** (`todo`, `memory`, `session_search`, `delegate_task`) are intercepted before the registry and mutate agent state directly. **Iteration budget:** default **90** turns (`agent.max_turns`); subagents independent **50** (`delegation.max_iterations`); `execute_code` "refunds" iterations. **Same core reused** across CLI (`cli.py`/Ink TUI via `tui_gateway`), gateway (`gateway/run.py`), ACP (`acp_adapter/`), batch runner (`batch_runner.py`), API server. Note: the gateway constructs a **fresh `AIAgent` per inbound message**, rebuilding state from the session transcript (mitigated by frozen system-prompt caching) — a known perf wrinkle (issue #16155: memory providers re-init per turn, labeled `comp/agentCore`). The file was famously ~16,083 lines, refactored in v0.15.0 to 3,821 lines across 14 `agent/*` modules with thin forwarders preserved.

- *Ivan analog:* **HAS** — closest match to his design. Steal: turn boundaries as economic boundaries (reset retry/iteration accounting per turn); one internal message format with adapters per provider.

### 2. Gateway / control plane
`gateway/run.py` is a long-running process connecting to messaging platforms and routing messages to `AIAgent` instances, with per-platform session isolation sharing memory/skills. Installed as a user service (`hermes gateway install`) or system service (`--system`). Cron ticking lives in the gateway (every 60s). Session durability (v0.13.0): conversations auto-resume after gateway restarts via checkpoints + atomic persistence. The gateway also hosts the API server and the Ink TUI bridge (`tui_gateway/server.py`, stdio JSON-RPC, or WS via `tui_gateway/ws.py`).

- *Ivan analog:* **LACKS.**

### 3. Channel adapters
One gateway process speaks 20+ platforms (Telegram, Discord, Slack, WhatsApp, Signal, Email, SMS, DingTalk, Matrix, Mattermost, Feishu/Lark, WeCom, Weixin, QQBot, Yuanbao, BlueBubbles iMessage, IRC, Microsoft Teams, Google Chat, LINE, SimpleX Chat, ntfy, Home Assistant). **Streaming vs edit fallback:** real-time token streaming on Telegram, Discord, Slack, and CLI via `_interruptible_streaming_api_call()`; WhatsApp/Signal/Email/Home Assistant fall back to non-streaming automatically (no message-edit API). DM security via pairing + container isolation. Adding a platform is "expand reach at the edges" — new adapters land routinely per `AGENTS.md`.

- *Ivan analog:* **LACKS.**

### 4. Workspace, sessions, memory
State under `~/.hermes/`. **Built-in memory (always on):** `MEMORY.md` (agent's own notes, ~2,200 char cap) + `USER.md` (user model, ~1,375 char cap), injected every turn (~1,300 tokens); when full, the agent must consolidate before saving — "scarcity is the feature." Identity is `SOUL.md` (prompt slot #1). Sessions persist in SQLite (`hermes_state.py`) with **FTS5** full-text search across all past sessions (`session_search`; rebuilt to be no-LLM, ~4,500× faster and free in v0.15.0). **Pluggable memory providers (v0.7.0):** a provider ABC + plugin system, one external provider active at a time alongside built-in: **Honcho** (dialectic user modeling, AGPL), OpenViking, Mem0, Hindsight, Holographic (local HRR), RetainDB, ByteRover, Supermemory. Active provider injects context into the prompt, prefetches before each turn, syncs after each response. **Compression:** preflight at >50% context, gateway auto-compression at >85%; memory flushed to disk *first*, middle turns summarized, last N (`compression.protect_last_n`, default 20) preserved, tool-call/result pairs kept together, new session lineage ID minted. Context engine is pluggable (`agent/context_engine.py` ABC; default `agent/context_compressor.py`).

- *Ivan analog:* **PARTIAL** — HAS compaction; **LACKS** persistent memory + FTS5 recall + provider abstraction. The bounded-memory + flush-before-compress pattern is the single best low-complexity steal.

### 5. Skills system
Skills are SKILL.md dirs in `~/.hermes/skills/` (agentskills.io standard; progressive disclosure). **Autonomous creation:** the `skill_manage` tool (actions `create`, `patch` [preferred, token-efficient], `edit`, `delete`, `write_file`, `remove_file`) fires after a complex task (5+ tool calls) succeeds, after recovering from an error, or after a user correction. **Self-improvement during use:** skills are patched mid-run when found outdated/incomplete/wrong; an optional `write_approval` gate stages writes under `~/.hermes/pending/skills/` reviewed via `/skills pending|diff|approve|reject`. **The Curator (v0.12, expanded v0.13):** a background maintenance pass over **agent-created skills only** (never bundled/hub/pinned). Triggered by inactivity check (not a daemon): on CLI start and a gateway cron-ticker, if `interval_hours` (default 168 = 7 days) elapsed AND idle ≥ `min_idle_hours` (2h), it forks an `AIAgent` (aux model, `max_iterations=8`). **Deterministic transitions:** unused > `stale_after_days` (30) → stale; > `archive_after_days` (90) → moved to `~/.hermes/skills/.archive/`. **LLM review** uses only `skills_list`, `skill_view`, `skill_manage(patch)`, `terminal mv` to consolidate overlaps and patch drift. Invariants (tested): never touches bundled/hub skills, never auto-deletes, pinned skills immune, uses aux client so main prompt cache is untouched; tar.gz snapshot before each pass; `hermes curator status|run|--dry-run|backup|rollback|pin|unpin|restore|list-archived`. `prune_builtins: true` lets it archive unused bundled skills too. **Skill Hubs/taps:** ClawHub, skills.sh, browse.sh (200+ site automations), direct URL, GitHub "taps" (`hermes skills tap add owner/repo`); per the release notes, "NVIDIA/skills joins OpenAI, Anthropic, and HuggingFace as a default trusted tap in the Skills Hub — discoverable, browsable, searchable, and auto-updating." Source tree carries 166 tracked skills (87 bundled + 79 optional). **Known weaknesses (in-repo issues):** self-congratulation bias (#6051, learned helplessness from transient failures); no write-time correctness gate (#25833); skills grow monotonically without the Curator (#7816).

- *Ivan analog:* **HAS** a skill loader; **LACKS** autonomous creation + self-improvement + Curator (Hermes' signature inventions).

### 6. Tool surface
40+ tools across toolsets: `web`, `search`, `terminal`, `file`, `browser`, `vision`, `image_gen`, `moa`, `skills`, `tts`, `todo`, `memory`, `session_search`, `cronjob`, `code_execution`, `delegation`, `clarify`, `homeassistant`, `messaging`, `spotify`, `discord`, `discord_admin`, `debugging`, `safe`. Tools self-register at import time via `tools/registry.py` (each `tools/*.py` calls `registry.register()`); `model_tools.py` collects schemas and dispatches (`handle_function_call()`). **MCP:** stdio + HTTP, per-server tool filtering, OAuth 2.1 PKCE, a Nous-approved MCP catalog. **Programmatic Tool Calling (`execute_code`):** the agent writes a Python script that imports an auto-generated `hermes_tools.py` RPC stub; Hermes opens a Unix-domain-socket RPC listener; the script runs in a child process group; **only stdout returns to the LLM — intermediate tool results never enter context**, collapsing multi-step pipelines into one turn. Limits (`tools/code_execution_tool.py`): `DEFAULT_MAX_TOOL_CALLS=50`, stdout cap 50 KB, stderr 10 KB, credential scrubbing (env vars with KEY/TOKEN/SECRET/etc. stripped); `SANDBOX_ALLOWED_TOOLS` whitelist; Unix-only (Linux/macOS).

- *Ivan analog:* **PARTIAL** — HAS ~14 tools + a registry concept; **LACKS** MCP and execute_code (both worth stealing; execute_code is the higher-leverage idea).

### 7. Subagents and delegation
`delegate_task` spawns full `AIAgent` instances with isolated context, restricted toolsets, and their own terminal sessions — not threads. Limits (`tools/delegate_tool.py`): `MAX_DEPTH=2` (parent→child→grandchild rejected), `MAX_CONCURRENT_CHILDREN=3`, subagents denied `DELEGATE_BLOCKED_TOOLS` (`delegate_task`, `clarify`, `memory`, `send_message`, `execute_code`). Subagents get independent 50-iteration budgets (total tree work can exceed the parent cap — "delegation is outsourcing, not sharing one counter"). Subagents **share the parent's skill library**. Fire-and-forget or blocking; `_build_child_progress_callback` streams child tool calls to the parent. **The "zero-context-cost pipeline" trick** = `execute_code` (RPC keeps intermediate results out of context), not delegation per se.

- *Ivan analog:* **HAS** — direct analog to his Task sub-agents; copy the depth/concurrency caps and blocked-tool list.

### 8. Sandboxes / terminal backends
**Seven backends** (README): local, Docker, SSH, Singularity, Modal, Daytona, Vercel Sandbox (config switch, no code change). Docker behaves as a persistent sandbox VM across a session (`container_persistent`). Daytona/Modal offer serverless hibernation. Security policy (rewritten v0.14.0) treats **OS-level isolation as the primary trust boundary**, with a command-approval workflow flagging dangerous ops (`rm -rf`, `sudo`, `curl|sh`) for explicit approval (`tools/approval.py`), plus sudo brute-force block and tool-error sanitization. Skills can declare `required_environment_variables` to pass through specific secrets without weakening the default scrub.

- *Ivan analog:* **LACKS** — the backend ABC is a clean, copyable abstraction; start with local + Docker.

### 9. Scheduling and autonomy
A single `cronjob` tool (actions: create/list/pause/resume/run/remove/edit) created in **natural language** — an LLM parses plain English into a cron expression, stored in the gateway's SQLite scheduler (timezone-aware, persists across restarts, missed-run catch-up/skip). The gateway ticks every 60s (`~/.hermes/cron/.tick.lock` prevents overlap). Jobs are full sessions (all tools/skills/memory), can attach skills, chain via `context_from`, run in no-agent mode (raw stdout), and **deliver to any platform** — `deliver=all` fans out to every configured channel, resolved at fire time. Cron-run sessions cannot recursively create cron jobs. The **Autonomous Curator** (above) is the other scheduled-autonomy pillar.

- *Ivan analog:* **PARTIAL** — HAS background tasks; **LACKS** NL cron + delivery routing.

### 10. Model abstraction
Provider-agnostic: Nous Portal, OpenRouter (200+), OpenAI (chat + Codex Responses), Anthropic, Google/Gemini (incl. CLI OAuth), AWS Bedrock (Converse API), NVIDIA NIM, Vercel ai-gateway, Azure AI Foundry, LM Studio, GMI Cloud, local endpoints — switch with `hermes model`. Resolution: explicit `api_mode` → provider detection → base-URL heuristics → default `chat_completions`. **Credential pools** rotate multiple keys per provider (`least_used`, 401 refresh-and-rotate); **fallback providers** on 429/5xx/401-403 with credential refresh before failover; auxiliary tasks (vision/compression/web-extract) have independent fallback chains. Cross-session 1-hour prefix cache for Claude. `hermes proxy` (v0.14.0) exposes an OAuth-backed subscription (Claude Pro/ChatGPT Pro/SuperGrok) as a local OpenAI-compatible endpoint.

- *Ivan analog:* **PARTIAL** — credential pools + multi-mode normalization + auxiliary fallback chains are the gaps worth copying.

### 11. External API surface
**OpenAI-compatible API server** (`gateway/platforms/api_server.py`): `/v1/chat/completions` and `/v1/responses` + `/api/jobs` REST cron management; hardened with input limits, field whitelists, SQLite response persistence, CORS protection, Idempotency-Key (v0.5.0), real-time tool-progress streaming + session continuity via `X-Hermes-Session-Id` (v0.7.0). Any OpenAI-format frontend (Open WebUI, LobeChat, LibreChat, NextChat) connects with Hermes' full toolset. **ACP server** (`acp_adapter/`: `entry.py`, `server.py`, `session.py`, `events.py`, `permissions.py`, `tools.py`, `auth.py`; `hermes acp` / `hermes-acp`): wraps the synchronous `AIAgent` in an async JSON-RPC stdio server for VS Code/Zed/JetBrains; exposes a curated `hermes-acp` toolset (file tools, search, terminal — excludes messaging/cron); binds editor cwd to the task ID; routes dangerous commands back to the editor's approval UI; sessions persist to `~/.hermes/state.db` and appear in `session_search`; Zed registry launches via `uvx --from 'hermes-agent[acp]==<version>' hermes-acp`. A third protocol — the **TUI gateway JSON-RPC** — serves custom hosts.

- *Ivan analog:* **LACKS** — ACP is "implement once, embed in every IDE"; OpenAI-compatible REST is the lowest-friction external contract. Both high value.

### 12. Voice and canvas
Hermes has **TTS + STT** across messaging (TTS providers: Edge/ElevenLabs/OpenAI/MiniMax/Mistral Voxtral/Gemini/xAI/NeuTTS/KittenTTS/Piper; STT: local faster-whisper, Groq, OpenAI Whisper, Mistral, xAI) and voice-memo transcription, but **no Voice Wake / continuous Talk Mode and no A2UI Canvas** — those are OpenClaw-specific. (Hermes Desktop is an Electron GUI, not an agent-driven canvas.)

### 13. Companion apps / nodes
**Not present** as a device-pairing node system. Hermes Desktop (Electron) connects to a local or **remote** Hermes gateway over secure WebSocket with OAuth/username-password, multiple profiles, cross-profile `@session` links — but it is a thin GUI client, not a peripheral-node fabric like OpenClaw's.

### 14. Research and training plumbing
First-class. `save_trajectory()` (`agent/trajectory.py`, `run_agent.py` `_save_trajectory`/`_convert_to_trajectory_format` ~line 4258) writes **ShareGPT-format JSONL** (conversations + timestamp + model + completed flag); image-bearing tool results are replaced with text summaries to keep trajectories text-only. `batch_runner.py` runs the agent over many prompts in parallel with checkpointing for SFT data generation. A separate `trajectory_compressor.py` post-hoc summarizes long trajectories into a `_compressed/` dir to fit a target token budget. **Atropos** integration (`environments/`, `tools/rl_training_tool.py`) turns trajectories into RL rollouts (start→check_status→stop→get_results; WandB logging; 11 tool-call parsers). The separate **`hermes-agent-self-evolution`** repo uses **DSPy + GEPA** to read execution traces, generate candidate skill/prompt variants, gate them (tests pass 100%, skills <15 KB, caching preserved, no semantic drift), and open a PR against hermes-agent. Per the repo README it requires "no GPU training… ~$2-10 per optimization run." GEPA (the "Reflective Prompt Evolution Can Outperform Reinforcement Learning" work, Lakshya Agrawal et al., ICLR 2026 Oral) first shipped in Hermes v0.8.0 (April 8, 2026); published benchmarks claim it "outperforms GRPO… by 6% on average and up to 20%… while using 35× fewer rollouts" (independent secondary source — treat as the project's reported figures, not independently re-run).

- *Ivan analog:* **LACKS** — trajectory export (ShareGPT JSONL) is cheap to add and very valuable if a teaching series touches training/evals.

### 15. Operator UX
Shared slash commands across CLI + messaging: `/new`|`/reset`, `/model`, `/personality`, `/retry`|`/undo`, `/compress`, `/usage`, `/insights`, `/skills`, `/stop`, `/status`, `/sethome`, plus `/goal`/`/subgoal` (worker proposes, judge LLM grades until done), `/curator`, `/cron`. New commands need only an entry in the `CommandDef` aliases tuple (dispatch/help/Telegram menu/Slack mapping/autocomplete auto-update); gateway availability gated by `gateway_config_gate`. `hermes doctor` diagnoses issues; `hermes setup`/`hermes setup --portal` wizards.

- *Ivan analog:* **PARTIAL.**

---

## Part 3 — Adjacent projects (brief)

- **hermes-webui (`nesquena/hermes-webui`):** a Hermes WebUI showing SSE streaming, subagent delegation cards, and in-process agent embedding (importing `run_agent.AIAgent` directly rather than spawning a subprocess). Confirms the "embed the core in-process" pattern Hermes documents under Programmatic Integration. *(I could not fetch this repo's source directly; treat its specific internals as README-level claims, not code-verified.)*
- **hermes-agent-self-evolution (`NousResearch/...`):** DSPy + GEPA evolution loop over skills/prompts/tools; reads real session history or synthetic eval sets; constraint-gated; outputs PRs. This is the *offline* counterpart to the *online* Curator — same philosophy (improve the skill library), different mechanism (evolutionary prompt search vs. usage-telemetry pruning).
- **HermesClaw (`AaronWong1999/hermesclaw`):** community WeChat bridge. The convergence contract it reveals: both Hermes and OpenClaw (a) natively poll the **same WeChat iLink transport** (each tries to exclusively lock it → 403 conflict) and (b) consume the **same SKILL.md skill files**. HermesClaw becomes the sole iLink poller and runs two local proxies (`:19999` openclaw, `:19998` hermes) plus an ACP bridge for OpenCode, routing by `/hermes` `/openclaw` `/opencode` `/three`. The deeper lesson: **the shared "contract" between the two systems is (1) the messaging transport envelope and (2) the agentskills.io SKILL.md format** — which is exactly why `hermes claw migrate` can import OpenClaw's SOUL.md/MEMORY.md/USER.md/skills/allowlists wholesale.

---

## Part 4 — Cross-cutting synthesis

### 4.1 The reference architecture of a 2026 persistent personal AI agent (text block diagram)
```
                 ┌──────────────────────────────────────────────────────────┐
   Surfaces  →   │ CLI/TUI │ Messaging Gateway │ IDE (ACP) │ REST (/v1/...) │  ← thin adapters
                 └──────────────┬───────────────────────────────────────────┘
                                │  (normalized message envelope; session key)
                 ┌──────────────▼───────────────┐
   Control       │  GATEWAY / CONTROL PLANE      │  long-running daemon (launchd/systemd)
   plane     →   │  routing · session lanes ·    │  per-session serialization, multi-agent
                 │  pairing/auth · cron ticker   │  isolation, RPC to companion clients
                 └──────────────┬────────────────┘
                                │ (build AIAgent / embedded run per turn)
                 ┌──────────────▼────────────────┐
   Core      →   │  SINGLE AGENT LOOP (ReAct)     │  prompt assembly → model call →
                 │  one internal message format   │  tool dispatch → loop; interrupt;
                 │  iteration budget; compaction  │  budget cap; fallback/retry
                 └───┬───────────┬───────────┬────┘
                     │           │           │
        ┌────────────▼──┐ ┌──────▼─────┐ ┌───▼───────────────┐
 Context│ Identity+Memory│ │  Skills    │ │ Tools + Sandbox   │
 layer →│ SOUL/AGENTS.md │ │ SKILL.md   │ │ registry; MCP;    │
        │ MEMORY/USER.md │ │ (agent-    │ │ exec backends     │
        │ session DB+FTS │ │  skills.io)│ │ (local/Docker/SSH)│
        └────────────────┘ └────────────┘ └───────────────────┘
                     │           │              │
            flush-before-compact │       delegate_task → child AIAgent(s)
            cross-session recall │       cron → scheduled session → deliver to channel
                     └───────────┴──────────────┘
   Optional research tap: trajectory export (ShareGPT) → batch/RL (Atropos) / DSPy+GEPA self-evolution
```
**Invariant across both:** (1) one reused ReAct loop with a single internal message format and provider adapters; (2) a long-running local-first daemon as control plane; (3) file-based identity + bounded persistent memory + flush-before-compact; (4) SKILL.md progressive-disclosure skills; (5) tool registry + sandboxed exec + MCP; (6) subagent delegation with budget caps; (7) cron with channel delivery; (8) untrusted-inbound → gated tools as the security model.

### 4.2 Where they diverge (real design choices)
- **Skill curation:** Hermes = autonomous create + self-patch + usage-telemetry Curator (online) + DSPy/GEPA (offline). OpenClaw = human/registry-curated with supply-chain trust (verify/scan/pin), Skill Workshop proposals, **no autonomous pruning**.
- **Memory layering:** Hermes = bounded `MEMORY.md`/`USER.md` (hard char caps, scarcity-forces-curation) + SQLite/FTS5 + a single pluggable external provider. OpenClaw = markdown + SQLite hybrid (BM25+vector) + optional QMD sidecar + **Active Memory blocking sub-agent** + **Dreaming** (sleep-phase consolidation). OpenClaw's memory is more elaborate/automatic; Hermes' is more minimal/legible.
- **Sandbox abstraction:** Hermes = 7 backends incl. serverless (Modal/Daytona/Vercel) for "agent lives in the cloud, you talk from Telegram." OpenClaw = 3 backends (Docker/SSH/OpenShell) with finer per-tool-family allow/deny and per-channel trust tiers.
- **Voice/visual surface:** OpenClaw invests heavily (Voice Wake, Talk Mode, A2UI Canvas, device nodes); Hermes stays text/TTS/STT + Electron GUI.
- **External contract:** Hermes leads with OpenAI-compatible REST + ACP (developer/IDE reach); OpenClaw leads with WS RPC + MCP-serve + ACP-host (it *hosts* harnesses rather than *being* one in an IDE).
- **Philosophy:** Hermes = "the agent gets smarter" (cognition, research lineage, model-agnostic harness). OpenClaw = "the agent is everywhere you are" (breadth, presence, consumer polish). The fact that Hermes ships an OpenClaw importer signals it views OpenClaw's user base as a migration audience.

### 4.3 Inventions worth stealing (specific)
**From Hermes:**
1. **Autonomous skill creation + Curator loop** — event-trigger (5+ tool calls) → SKILL.md; deterministic stale/archive transitions (30/90d) + aux-model consolidation; never-touch-bundled, never-delete, pinnable, snapshot-before-run. Copy the *invariants* even if you simplify the mechanism.
2. **Programmatic Tool Calling (`execute_code`)** — generate an RPC stub, run agent-written code in a child process over a Unix socket, return only stdout. Collapses N-step pipelines into one turn and keeps intermediate results out of context. Highest-leverage single tool.
3. **Trajectory export → RL** — ShareGPT JSONL writer (4 fields), text-only normalization, separate post-hoc compressor; optional Atropos. Cheap to add, opens evals/fine-tuning.
4. **ACP server** — one stdio JSON-RPC adapter → every major IDE.
5. **OpenAI-compatible `/v1/chat/completions`** — instant compatibility with the entire OpenAI-format frontend ecosystem.
6. **Credential pools + auxiliary fallback chains** — rotate keys within a provider; independent fallback for vision/compression.

**From OpenClaw:**
1. **A2UI Canvas** — agent-driven visual workspace via versioned JSONL (`beginRendering`/`surfaceUpdate`/`dataModelUpdate`/`deleteSurface`) served on the gateway HTTP port, rendered in node WebViews.
2. **Nodes + device pairing** — peripherals connect to the gateway WS with `role: node` + device identity + challenge-nonce; approve via CLI; capabilities (`canvas.*`, `camera.*`, `screen.record`, `location.get`) via `node.invoke`.
3. **Per-channel DM pairing policy** — `pairing`/`allowlist`/`open`/`disabled` as a strict per-channel contract with pairing codes, owner bootstrap, access groups. The cleanest "untrusted inbound" gate in either project.
4. **SOUL.md / TOOLS.md / AGENTS.md split** — separate identity vs. environment-specific tool notes vs. operating instructions, each injected on first turn. Better than one monolithic system prompt.
5. **`openclaw doctor` / `security audit`** — operator diagnostics that actively flag risky DM policies and fix file perms.
6. **Lane queue** — per-session serialization with optional global lane to prevent tool/session races.

### 4.4 The minimum viable persistent agent (by impact-to-complexity)
1. **Bounded file memory + flush-before-compact** (highest ratio): two capped markdown files injected every turn; flush durable facts before any summarization. Turns a chatbot into something that remembers.
2. **One messaging channel adapter + DM allowlist/pairing** behind a daemon: makes it "persistent and reachable."
3. **NL cron + deliver-to-channel**: turns reactive into proactive; reuse the same loop in a scheduled session.
4. **Cross-session recall** (SQLite FTS5): cheap, no embeddings needed, big UX win.
5. **Autonomous skill creation (create + patch)**: even without a Curator, "save what worked" compounds.
6. **Sandbox backend (local + Docker)**: the trust boundary you need before exposing tools to inbound DMs.

Everything beyond this (ACP, REST, RL export, voice, nodes, Curator, provider pools) is high-value but not load-bearing for "MVP persistent agent."

### 4.5 Build-in-this-order recommendation (from a working swift-claude-code core)
1. **Persist memory + sessions.** Add `MEMORY.md`/`USER.md` (capped), a SQLite session store with FTS5, and a flush hook wired into your existing ContextCompactor (flush → then compact). *Reuses your loop; no new surface.* **Threshold to advance:** you can close the app, reopen, and the agent recalls a fact from a prior session.
2. **Stand up a gateway daemon + one channel.** Extract your loop behind a long-running process (launchd on macOS), add a normalized inbound/outbound envelope and a SessionKey router, implement **one** adapter (Telegram is easiest) with a DM allowlist/pairing gate. *Big lift; do it before anything else network-facing.* **Threshold:** a paired Telegram DM round-trips through your loop with tool use.
3. **NL cron + delivery routing.** Reuse your BackgroundManager; add an LLM-parsed schedule store and a "deliver to channel X" step. Cron sessions = normal sessions. **Threshold:** "every morning at 8, summarize X and send to Telegram" works unattended.
4. **Sandbox backend abstraction.** Define a backend protocol; implement `local` + `Docker`; gate tool families for non-main/inbound-triggered sessions (copy OpenClaw's allow/deny default). **Threshold:** an inbound DM cannot run `browser`/`gateway`/`cron` tools.
5. **Autonomous skill creation + a minimal Curator.** Your skill loader already reads SKILL.md; add a `skill_manage`-style tool (create/patch) triggered after successful multi-tool tasks, plus a deterministic stale/archive sweep over agent-created skills only (skip the LLM-review pass initially). **Threshold:** a repeated task needs fewer corrections the second week.
6. **`execute_code` (Programmatic Tool Calling).** Add an RPC stub + child-process runner returning only stdout. Big context savings; pairs well with your existing tool registry.
7. **External contracts: ACP, then OpenAI-compatible REST.** ACP for IDE embedding (one stdio JSON-RPC adapter over your loop), then `/v1/chat/completions` for frontend reach.
8. **Research tap (optional): ShareGPT trajectory export.** A ~30-line writer at turn end; add a compressor later.
9. **Voice/Canvas/nodes (optional, last).** Only if targeting consumer UX; A2UI + device pairing is a large surface.

### 4.6 Open problems / frontier the codebases hint at
- **Curator robustness:** Hermes' own issues document self-congratulation bias (#6051), no write-time correctness gate before a skill is persisted (#25833), and monotonic skill growth without lifecycle management (#7816). Auto-curation can also overwrite manual customizations with worse versions. Grading on usage telemetry is weak signal.
- **Skill portability across agents:** SKILL.md is portable, but creation/curation behavior is runtime-specific; advanced features (Claude context forking, Codex `openai.yaml`) don't port. The "same files, different loop" reality limits true portability.
- **Sandbox escape surface:** treating inbound DMs as untrusted is right, but `execute_code` (arbitrary Python over RPC), elevated-exec escape paths, MCP servers holding credentials, and prompt-injection-to-RCE (the documented CVE-2026-25253 class for OpenClaw's WS hijacking) keep the blast radius large. OS-level isolation is the only real boundary.
- **Memory provider standards:** Hermes has a provider ABC and 8 backends but only one active at a time and re-inits per turn (#16155); there is no cross-agent memory standard. OpenClaw's Honcho/QMD/Active Memory/Dreaming stack is powerful but bespoke.
- **agentskills.io maturity:** the standard is intentionally minimal (file layout + frontmatter + progressive disclosure) and leaves routing/lifecycle/trust to each runtime — so security scanning, signing (ClawHub envelopes), and curation are all non-standardized add-ons.
- **Per-message agent reconstruction:** Hermes building a fresh `AIAgent` per inbound message (rebuilding from transcript) is a scaling/latency wrinkle that hints at a future stateful-actor model.

---

## Recommendations (decision-ready)

- **Read in this order to internalize the architecture:** Hermes `run_agent.py` + `developer-guide/agent-loop.md` (the cleanest articulation of "one loop, many surfaces"); then OpenClaw `docs/concepts/agent-loop.md` + `agent-runtime-architecture` (the cleanest articulation of "gateway as control plane"). These two together *are* the reference architecture.
- **Build the cognition layer from Hermes and the presence layer from OpenClaw.** They are complementary, not competing, models. Your Swift/Kotlin rebuild should take Hermes' single-`AIAgent`-with-adapters discipline and bounded-memory pattern, and OpenClaw's gateway/lane-queue/DM-pairing/sandbox-default model.
- **Steal the SKILL.md contract verbatim first** (frontmatter `name`+`description`, progressive disclosure, `references/`/`scripts/`/`assets/`). It is the one piece already standardized and portable across both systems and Claude Code/Codex/Cursor — building to it future-proofs your skill loader and lets you import the existing ecosystem.
- **Treat inbound DMs as untrusted from day one.** Implement the DM-pairing gate and sandbox tool allow/deny *before* exposing any channel. The default-deny list (`browser, canvas, nodes, cron, discord, gateway`) is a good starting policy to copy directly.
- **For a teaching series:** structure it exactly as §4.5 — each step is a self-contained, demoable increment from a working coding-agent core, and each maps to a named subsystem in one or both real codebases so students can read the source.

## Caveats

- **Code-vs-docs gaps flagged inline.** OpenClaw's runner directory is `pi-embedded-runner` in live code references but `embedded-agent-runner` in docs; `PROTOCOL_VERSION` is v4 in docs (`packages/gateway-protocol/src/version.ts`) but v5 in a current-main issue (`src/gateway/protocol/version.ts`). Verify against the live `src/agents/` and `src/gateway/protocol/` trees before quoting paths in published material.
- **Some OpenClaw memory/voice internals (Active Memory, Dreaming, Talk RPC) are docs-derived**, not line-verified against source in this pass. `nesquena/hermes-webui` internals are README-level.
- **Version drift:** features are tagged to the releases where I found them (e.g. memory providers v0.7.0, Curator v0.12/v0.13, `hermes proxy` v0.14.0, the `run_agent.py` refactor v0.15.0, GEPA v0.8.0). Both projects move weekly; treat exact line numbers (`run_agent.py:2758`, `~:4258`) and constants as approximate anchors, not pins.
- **Benchmark and adoption numbers are the projects'/third parties' reported figures, not independently reproduced** (e.g. GEPA's "93% on MATH," "35× fewer rollouts," star counts). Star/usage stats on third-party guide sites are frequently fabricated and were excluded.
- **The CVE-2026-25253 reference** comes from secondary write-ups, not a verified NVD entry I fetched; cite it as "reported" until confirmed against the advisory.