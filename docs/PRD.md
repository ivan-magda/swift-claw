# swift-claw — Product Requirements Document (PRD)

| | |
|---|---|
| **Status** | Draft v2 (for review) |
| **Date** | 2026-06-15 |
| **Owner** | Ivan Magda |
| **Related** | [`ARCHITECTURE.md`](./ARCHITECTURE.md) · [`teleclaw-prompt.md`](./teleclaw-prompt.md) · research: [impl-grounding](./research/swift-claw-impl-grounding-2026-06-15.md), [best-practices](./research/swift-claw-best-practices-2026-06-15.md), [openclaw-hermes study](./research/persistent-agents-openclaw-hermes.md) |

> **Clean-room notice.** swift-claw is an original implementation in the same *product category* as OpenClaw / Hermes / the teleclaw-prompt brief. It does **not** copy or reproduce OpenClaw, Hermes, or the author's prior `swift-claude-code`. Those are references and inspiration only.

---

## 1. Summary

swift-claw is a **persistent, always-on, single-owner personal AI assistant**, controlled through **Telegram**, implemented in **pure Swift**. It runs as a long-lived local-first daemon on the owner's Mac (and any box with a Swift toolchain), holds durable per-conversation state, remembers facts across restarts, can read the web and the workspace, and — in later phases — can act through a small set of sandboxed tools behind explicit approvals and reach out proactively on a schedule. The design priority is **daily-driver robustness** and **secure-by-default** behavior over breadth or cleverness.

**v1 is a useful daily driver, not a demo.** The v1 slice (defined in §9) is conversational + durable memory + read-only tools (web search/fetch, workspace file read) + streaming replies — the smallest thing that earns daily use over the official ChatGPT/Claude apps. Write/shell tools, sandbox, approvals, and scheduling/proactive arrive in later phases.

## 2. Background & motivation

The author has already built a Claude Code–style coding agent (`swift-claude-code`): a single ReAct loop with tools, sub-agents, compaction, a task DAG, and a skill loader. swift-claw studies and builds a *different* class of system — the **persistent, multi-channel personal assistant** — keeping the proven "one reused agent loop behind thin surfaces" idea but adding the parts a coding agent lacks: a long-running gateway, durable cross-session memory, a messaging channel with an access boundary, a scheduler, and a sandboxed tool/approval layer.

Why Swift: a single static binary, strong concurrency model (Swift 6 strict concurrency / actors), good performance, and first-class macOS integration, while staying Linux-portable.

## 3. Goals & non-goals

### 3.1 Goals
- **G1.** A daily-driver assistant the owner actually uses every day from Telegram — earned at v1 (memory + read-only web/file + streaming), not deferred.
- **G2.** Always-on: survives restarts, crashes, and machine sleep/wake; supervised by launchd (macOS) / systemd (Linux) with restart throttling.
- **G3.** Secure-by-default: untrusted inbound is gated; dangerous capabilities are off or approval-gated; the security boundary is enforced in code, not in the prompt; access and rate-limit checks **fail closed**.
- **G4.** Persistent: conversations, memory, schedules, approvals, and audit all survive restarts.
- **G5.** Provider-portable: swap LLM provider/model via config behind **one `LLMProvider` contract** — an OpenAI-compatible endpoint the owner configures, or a ChatGPT subscription the owner logs into (FR-P5). Authentication is a separate concern from the wire format, so adding a provider adds an adapter, never a branch in the agent loop.
- **G6.** Local-first & private: data stays on the owner's machine; no third party beyond the chosen LLM endpoint and Telegram. The owner can export and delete their data.
- **G7.** Maintainable & legible: boring architecture, small well-bounded modules, well-tested; suitable to write a teaching series about.
- **G8.** Portable: macOS-primary, but the same source builds and runs on Linux.

### 3.2 Non-goals (v1)
- **NG1.** Multi-user / multi-tenant operation, groups, or supergroups. *(Single-owner only; the access model leaves room to add it later.)*
- **NG2.** Channels other than Telegram (no Slack/Discord/iMessage/WhatsApp). The channel layer stays abstractable, but only Telegram is implemented.
- **NG3.** Voice (STT/TTS) and an A2UI canvas or companion device "nodes." Inbound voice notes are **acknowledged but not transcribed** in v1 (see FR-G6).
- **NG4.** A web UI / REST API surface (OpenAI-compatible `/v1` server, ACP server) — possible later, not v1. (Note: `status`/`doctor` and Telegram `/status` are **not** this; they are a CLI subcommand and a chat command, see FR-O2.)
- **NG5.** Autonomous skill creation / a Curator / RL trajectory export.
- **NG6.** Webhook mode for Telegram (long-polling only in v1; webhook is a later option).
- **NG7.** Cloud/SaaS hosting, account systems, billing.
- **NG8.** Image/vision input. On the **near-term roadmap** (cheap on OpenAI-compatible providers via `image_url` content parts) but not in v1.
- **NG9.** Multi-provider / credential fallback and per-call USD attribution dashboards. v1 has one configured provider (with retry) and a USD spend **breaker**, not a dashboard.
- **NG10.** *(bounds FR-P5)* **Sharing or importing another tool's credentials** — notably Codex CLI's `~/.codex/auth.json` — shelling out to or supervising a Codex subprocess, multiple accounts, credential pools, live credential mutation while the daemon runs, and subscription providers other than ChatGPT. Also out: **a per-provider environment-variable namespace** (`CLAW_CHATGPT_*` and the like) and a configurable subscription endpoint or client identity. Subscription auth adds exactly **one** configuration selector — a provider-qualified model value — and structured configuration (`config.toml`) stays deferred; it is the mechanism a future provider's own settings will use.

## 4. Target user & operating context

- **Who:** the author (a single technical owner), self-hosting.
- **Where:** primary deployment is the owner's Mac (Apple Silicon, macOS 26); secondary is any Linux box with a Swift toolchain (VPS / home server).
- **How accessed:** a private Telegram bot, DMs only.
- **Trust:** the *owner* is trusted; everything arriving over the wire (messages, web pages, tool output, attachments) is **untrusted data**, never instructions.

## 5. Use cases (capabilities)

All capability areas are in scope over time; the v1 cut and later phasing are in §9. Capabilities tagged *(v1)* are part of the daily-driver milestone; others are deferred.

### 5.1 Conversational assistant *(v1)*
- *As the owner, I DM the bot a question and get a useful, in-context answer, with my recent conversation remembered.*
- Multi-turn context within a conversation; survives daemon restart.
- **Streaming replies:** the answer appears incrementally (first tokens fast), not as one delayed block.
- Two quick messages produce two **in-order, non-interleaved** replies (strict per-session ordering — a plain message queues; only `/stop` cancels the current turn and `/new` resets). See FR-R4.
- Long answers are split safely (no broken code fences) and fall back to plain text if formatting fails.
- On provider failure/outage or a hit budget cap, the owner gets a **plain-language message**, never silence or a raw error (see FR-R5).

### 5.2 Notes & long-term memory *(v1)*
- *"Remember that my timezone is Europe/Berlin"* → durable fact, recalled in future sessions.
- A curated long-term memory file plus a searchable archive of past conversations.
- The owner can **review** remembered facts (with provenance) and **delete** them.
- Durable facts are written **only on explicit confirmation** (configurable), shown verbatim before saving, and **flushed before compaction**.
- Cross-session recall via full-text search over the conversation archive.

### 5.3 Tools: read-only web & file *(v1)*
- *"Read my notes/project.md and draft a status update"* / *"fetch this URL and summarize."*
- Web search, web fetch, and workspace file **read** are the v1 tool surface. They are read-only, idempotent, low-blast-radius, and run automatically in the **`safe`** tier (no approval tap).
- Read-only tools are still subject to the **exfiltration gate** (see FR-T6): a fetch in a turn that already ingested untrusted content and touched private data requires approval.

### 5.4 Tools: write, shell & sandbox *(later phase)*
- Workspace-scoped file **write**; shell/code execution.
- Powerful, consequential tools run **inside a sandbox** and **behind explicit Telegram approvals**; nothing dangerous is enabled by default.
- The **enforced lethal-trifecta gate** (FR-T7) forces the approval path when a tainted session attempts a privileged or egress action.

### 5.5 Reminders, scheduling & proactive *(later phase)*
- *"Every weekday at 08:00 Europe/Berlin, summarize my unread items and message me."*
- Natural-language → schedule; restart-safe; fires once per occurrence (DST-correct); no duplicate delivery; **confirm-before-arm** for any new LLM-parsed schedule.
- Opt-in proactive check-ins / heartbeat with **quiet hours** and **frequency caps**; default OFF; reduced-privilege execution.
- Delivery routed back to the owner's Telegram DM.

### 5.6 Provider access & subscription login *(P-auth)*
- *As the owner, I authenticate swift-claw with my ChatGPT subscription and use an eligible model — without owning, paying for, or pasting an API key.*
- `clawd auth login` runs a device-code login in the terminal: it prints a URL and a short code to enter in the browser, waits, then discovers which models the subscription can **actually** use and prints the exact one-line setting to apply. The owner applies it — login never edits config, plists, or shell profiles on their behalf.
- `clawd auth status` says whether a credential exists and whether it is fresh, expiring, or expired, **without touching the network** and while the daemon runs. `clawd auth logout` removes it locally.
- **The configured OpenAI-compatible route is unchanged and stays the default.** One setting chooses between the two, and every existing model value keeps its current meaning — switching back is a one-line change.
- Subscription calls need no API key and incur no API billing. **Budgets still apply**: only the dollar caps go quiet, because a plan-included call has no dollar cost to cap.
- Failures are honest and actionable: *"authentication required — log in"* is a different message from *"your plan can't use this"* and *"you hit a quota, retry later"*, and **only the first one mentions logging in.**
- **This route is unofficial (R7)** — it is not a supported ChatGPT API, and the vendor can change or withdraw it without notice.

## 6. Functional requirements

Requirements tagged *(v1)* are part of the daily-driver milestone (§9); others land in their phase. Technical mechanism detail lives in [`ARCHITECTURE.md`](./ARCHITECTURE.md); this section states the product contract.

### 6.1 Gateway & lifecycle
- **FR-G1.** *(v1)* A single long-running daemon owns Telegram connectivity, config, access control, routing, sessions, run lifecycle, tools, memory, scheduler, provider calls, logging, and shutdown.
- **FR-G2.** *(v1)* Telegram updates are received via **long-polling** (`getUpdates`). **Durability invariant:** an update is claimed (deduplicated) and its inbound message + side effects persisted in one transaction **before** the confirmed offset advances, so no update is missed or double-processed across restarts. The normative sequence (claim → access-check → persist → advance offset) and the warning that the dedup check must never span an `await` live in [`ARCHITECTURE.md` §6.1].
- **FR-G3.** *(v1)* Updates are normalized into an internal `IncomingMessage`; replies go out as `OutgoingReply`. Duplicate `update_id`s are ignored (idempotent intake). A single malformed update never wedges intake (offset advances past it; counter exposed in `doctor`).
- **FR-G4.** *(v1)* Graceful shutdown on SIGTERM/SIGINT: stop intake → drain in-flight turn → flush → checkpoint + close DB → exit. Crash → supervised restart with throttling.
- **FR-G5.** *(v1)* **Single-instance guard.** At startup the daemon acquires a cross-process advisory lock on the state root; a second `clawd` refuses to boot rather than fighting over `getUpdates`. A Telegram **409 Conflict** (another poller active) is a distinct, loud error surfaced in `doctor`, not a generic retryable 5xx.
- **FR-G6.** *(v1)* **Non-text intake.** Every inbound update type is enumerated and handled deterministically — never a silent drop, never a crash:
  - Unsupported media (photo / voice / document / sticker) gets a friendly "I can't read X yet" reply.
  - **Caption text on media is captured and processed.**
  - Inbound **voice notes are acknowledged but not transcribed** in v1 (consistent with NG3).
  - An **edited user message** is treated as a `/retry` of that turn.
  - Image/vision input is on the near-term roadmap (NG8), not v1.

### 6.2 Access control & rate limiting
- **FR-A1.** *(v1)* **Default-deny.** No one can use the bot until their **numeric Telegram user ID** is allowlisted. Usernames are never used as a security boundary or resolved anywhere.
- **FR-A2.** *(v1)* Unknown senders never reach the LLM or any tool; they get a minimal "private bot" reply only. The reply itself never grants or reveals access and never lists allowlist contents (see FR-A5).
- **FR-A3.** *(v1)* Allowlist is configurable (config file + persisted) and survives restart. In v1 the owner ID enters the allowlist via the **config file**; a one-time **pairing flow** that writes a durable numeric ID is a later phase.
- **FR-A4.** *(v1)* Per-user and global **rate limits** (token-bucket); honor Telegram's `retry_after`. The rate limiter **fails closed** (throttle) on internal/store/lock error.
- **FR-A5.** *(v1)* **First-run / onboarding.** On a fresh install the owner must be able to discover their own numeric ID and self-allowlist:
  - An **unknown** sender's `/start` may echo **that sender's own numeric ID** (so they can paste it into the config) and nothing else — it never reveals who is on the allowlist and never grants access.
  - An **allowlisted** sender's `/start` shows the normal welcome/help.
  - `doctor` confirms **"at least one owner is allowlisted"** and fails the check otherwise.
  - **Pairing (later phase):** a high-entropy, single-use, expiring, rate-limited, audited secret provisioned out-of-band by the owner; pairing writes go through the same audited, idempotent allowlist path.
- **FR-A6.** *(later phase)* The approval-callback path runs the **same** default-deny numeric-ID check, and a pending privileged action can be approved **only** by the recorded owner of that action. Detail in FR-T5/§6.7.

### 6.3 Sessions & persistence
- **FR-S1.** *(v1)* Per-owner DM session keyed `telegram:dm:<userId>`; persisted in SQLite and survives restarts.
- **FR-S2.** *(v1)* Messages, runs, tool calls, memory items, scheduled jobs (their phase), provider usage, and audit events are stored in SQLite via explicit migrations, with a proper relational spine (foreign keys, `PRAGMA foreign_keys=ON`). Approvals are added in the tools phase.
- **FR-S3.** *(v1)* **Idempotency, split honestly into two mechanisms** (full detail in [`ARCHITECTURE.md` §7]):
  - **(a) DB-internal dedup:** inbound `update_id`, usage rows, and audit rows are deduplicated via `INSERT OR IGNORE` inside one write transaction.
  - **(b) External side effects (outbound replies):** delivered via a **transactional outbox** — intent committed → effect performed **at-least-once** → completion recorded. Each reply chunk is its own outbox step so a partial multipart send recovers.
  - The inbound message + run row **commit before** the outbound reply is sent (ordering invariant). Exactly-once across the network is impossible and is not claimed.
- **FR-S4.** *(v1)* **Data export & deletion.** The owner can export and delete **conversation history** (not just memory items). Deletion also removes/rebuilds the full-text-search rows so deleted content is not recoverable via the index. A retention/compaction policy bounds the message archive. (Conversation content is stored un-redacted by design; at-rest file encryption is the compensating control — see NFR-Privacy.)

### 6.4 Agent runtime
- **FR-R1.** *(v1)* The core loop: receive → authorize + rate-limit → resolve session → persist user message → build context → call provider → (later: dispatch tools / request approvals) → persist results → send reply → record usage + audit.
- **FR-R2.** *(v1)* Context is assembled within a deterministic size budget with explicit truncation markers. The **single normative source** for ordering, per-section priority, the truncatable flag, the budget formula (`inputCap = modelMax − reservedOutput`, greedy by priority, grapheme counting), and per-file caps is [`ARCHITECTURE.md` §9]; this FR defers to it.
- **FR-R3.** *(v1)* Runs support cancellation (`/stop`), timeouts, and retries with capped exponential backoff + full jitter at exactly one layer with a retry budget. Hard caps with **pinned numeric defaults** (set in [`ARCHITECTURE.md` §5]): max turns, max tool calls, max input tokens, reserved-output / `max_tokens`, wall-clock deadline. A **bounded, non-null `max_tokens` is mandatory** — `doctor` rejects a config with null `max_tokens`. (Multi-provider/credential fallback is **not** in v1, NG9.)
- **FR-R4.** *(v1)* **Per-session ordering.** Each session has a single processing lane: turns run in **strict FIFO** order. A plain message **queues** behind the current turn; only `/stop` (cancel current) and `/new` (reset + cancel) **supersede**. The owner sees two quick messages answered in order, never interleaved. (Mechanism — a `SessionActor` chaining each turn after the prior, and the fact that Swift actors do **not** serialize across `await` — is in [`ARCHITECTURE.md` §5].)
- **FR-R5.** *(v1)* **User-visible degradation contract.** This is the concrete form of "stop and ask":
  - On provider failure/timeout after retries, the owner gets a plain-language message ("I couldn't reach the model, please try again") with **no secrets or stack trace**.
  - On a hit budget cap, a specific message naming the cap ("I stopped because the per-day spend cap was hit").
  - The typing indicator is **cleared** in both cases.
- **FR-R6.** *(v1)* **Run state machine.** A run carries an explicit state (`PENDING / RUNNING / DONE / FAILED / CANCELLED / SUPERSEDED`; `AWAITING_APPROVAL` is added with the tools phase). A boot **reconciliation sweep** resolves orphaned states (any `RUNNING` at boot → `FAILED` or safe re-enqueue via the outbox). Transition tables and crash-recovery edges live in [`ARCHITECTURE.md` §19.1].

### 6.5 LLM provider
- **FR-P1.** *(v1)* One **`LLMProvider` contract** is the model-execution interface, with two wire routes behind it. **(a)** *(v1)* An **OpenAI-compatible Chat Completions** endpoint: provider/model/`base_url`/key are configurable, enabling swap between OpenAI, OpenRouter, Groq, local Ollama/LM Studio, an Anthropic OpenAI-compat endpoint, or a LiteLLM proxy — without code changes. `base_url` is **pinned/allowlisted** and documented as a trust dependency. **(b)** *(P-auth)* A **ChatGPT subscription** route (FR-P5). The route is selected by a single configuration value — a provider-qualified model reference — and **every unqualified model value keeps its current meaning and behavior**, including values containing `/`. Mechanism in [`ARCHITECTURE.md` §8].
- **FR-P2.** *(v1 seam)* Behind an `LLMProvider` protocol so a future *native* adapter (e.g. Anthropic Messages for prompt caching) can be added. **Authentication is a separate seam from the wire format**: a provider's credential lifecycle — a static key or an OAuth grant with refresh — is never a property of the agent loop, so the agent runtime, scheduler, and gateway never learn which provider they are talking to.
- **FR-P3.** *(v1 — not approved)* Records token usage and computes per-call cost from a local pricing table (feeds the USD budget, FR-R3/NFR-Cost). Per-call USD attribution **dashboards** are deferred (NG9). **A plan-included call records its tokens against a confirmed zero cost with an `included_plan` cost source** — an audited zero, distinguishable from an unpriced one (FR-P5).
- **FR-P4.** *(v1)* **Streaming.** Replies stream incrementally: an SSE parser maps chunks onto throttled Telegram `editMessageText` (coalesced, min-interval ~1–2 s, first chunk sent ASAP). If streaming is unavailable, fall back to blocking completion and re-issue `sendChatAction` every ~4 s for the turn's duration. The metric is **perceived latency (time-to-first-token)**, not just first-reply latency. Disabling streaming is a **presentation** choice — it turns off incremental Telegram drafts; it does not promise anything about a provider's wire transport.
- **FR-P5.** *(P-auth)* **ChatGPT subscription authentication.** The owner can authenticate with a ChatGPT subscription and run an eligible model **with no API key and no API billing**:
  - `clawd auth login` performs a **device-code** login, stores a refreshable credential **encrypted under the state root**, lists the models the subscription can actually use, and prints the exact configuration line — `CLAW_LLM_MODEL=openai-chatgpt/<model>` — for the owner to apply. It **never** edits `.env`, a launchd plist, a shell profile, or a future config file.
  - `clawd auth status` — read-only, network-free, and safe while the daemon runs — reports presence, expiry, and freshness. It never displays a token or an account identifier. `clawd auth logout` removes the local credential; it is **local deletion, not server-side revocation**, so an issued token may stay valid until the vendor expires it, and the owner is told so.
  - **Login and logout require the daemon to be stopped** — the running daemon is the only process allowed to refresh and save a credential — and they say exactly that rather than failing obscurely.
  - **Selection is one setting** (FR-P1): a provider-qualified model value picks the subscription route; every other value picks the configured route, unchanged. **No provider-specific environment variables are added** (NG10).
  - **Budgets still apply.** Token, turn, tool-call, and wall-clock ceilings all stay enforced; only the USD gates are skipped, because a plan-included call has no dollar cost to cap. **This is not an unlimited-budget mode.** Because this route cannot enforce an output cap on the wire, a token budget may overshoot by at most one in-flight call — see [`ARCHITECTURE.md` §8].
  - **Failures are distinct and actionable** (FR-R5): authentication required → *"stop clawd and run `clawd auth login`"*; entitlement/access denial and quota/throttle say what they are and **never** send the owner to log in again.
  - **The route is unofficial** (R7), and swift-claw never reads, imports, modifies, or shares another tool's credentials (NG10).

### 6.6 Memory *(v1)*
- **FR-M1.** Plain-text workspace identity/memory files (persona, operating rules, user profile, tool notes, curated memory) injected into context with size caps and truncation markers; missing files must not crash.
- **FR-M2.** Durable facts stored only on explicit ask/confirmation (configurable); each item has type, content, source/provenance, timestamps, importance, sensitivity, and supports deletion (`confidence` deferred until model-proposed/autonomous memory; `visibility` is named `sensitivity`, consistent with FR-M5's "high-sensitivity"; Inc 3a). Confirm-on-write shows the **exact verbatim text** post-Unicode-normalization, with invisible / zero-width / bidi characters made visible or stripped.
- **FR-M3.** Memory is flushed to disk **before** any compaction/summarization. **Bounded caps are a hard v1 contract:** MEMORY ≤ 2200 and USER ≤ 1375 graphemes (`String.count`); on overflow the runtime **errors and forces consolidation** rather than silently truncating. (This resolves the prior open question — it is the contract, not an open item.)
- **FR-M4.** Cross-session recall via SQLite **FTS5** search over the archive (external-content mode over `messages`, single delete source of truth — detail in [`ARCHITECTURE.md` §7]).
- **FR-M5.** Memory and tool output are **untrusted context**: MEMORY/USER files are injected inside the **same untrusted/labeled wrapper** as other data — **never the system tier** — so poisoned memory cannot claim system authority. They may never override system/security policy. Pattern scanning of memory writes is **defense-in-depth only**, not an acceptance gate. High-sensitivity memory is **not auto-injected** into a turn that has already ingested untrusted content.
- **FR-M6.** **`/memory review` + `/memory delete`** let the owner inspect remembered facts with provenance and forget them (confirm-gated). Durable memory **persists** across `/new` by design; forgetting is a separate, explicit path (see FR-O3).

### 6.7 Tools, policy & approvals
- **FR-T1.** *(v1 registry; full policy gate in the tools phase)* A fixed tool registry with explicit input/output schemas. Each tool declares a **risk tier**: `safe` | `ask` | `dangerous` | `disabled`, plus timeout, sandbox requirement, and audit behavior. A **per-tool output cap** (default ~25k tokens) is enforced and counts toward the next turn's input budget.
- **FR-T2.** **Default risk-tier table.** Read-only + idempotent + low-blast-radius ops — **`web_search`, `web_fetch`, workspace file READ** — default to **`safe`** (run automatically, no tap). Only writes, shell/exec, and egress-from-sandbox are `ask` / `dangerous`. `disabled` never runs. (Batch approval and a time-boxed auto-approve toggle are deferred to the tools phase.)
- **FR-T3.** Policy is enforced **in code** before dispatch — never delegated to the model. Tool output can never change system instructions.
- **FR-T4.** *(v1 for read; write in the tools phase)* File tools are workspace-scoped: every path is resolved to its **canonical real path** after `..`/symlink resolution and **asserted to lie within the workspace root** (a tested invariant covering both the link and its final target); outputs are size-capped; secrets are redacted in args/results; no arbitrary network or shell by default.
- **FR-T5.** *(tools phase)* **Approvals** are bound to the **exact** concrete action (tool + fully-resolved target + canonical-args hash + policy version), persisted as PENDING (restart-resumable) with the recorded **owner user ID**, expire to **DENY**, re-validate args **and** policy version at execution, execute the originally-recorded args, and are never cached into a future auto-run. The approval prompt shows the **fully-resolved** target (absolute path after symlink/`..` resolution; full URL incl. query/body, never model-truncated), a **taint banner** when the turn ingested untrusted content, and the **blast radius** (create vs overwrite, egress yes/no). Redaction hides secrets, **not** the destination fields the owner needs to judge risk. The callback `callback_id` is a ≥128-bit single-use random nonce bound to the session (never a sequential/PK/counter value); the callback handler runs the same default-deny check and honors the action only if `callback.from.id` equals the recorded owner ID.
- **FR-T6.** *(v1 for the read-only tools; full enforcement in the tools phase)* **Exfiltration gate.** `canExfiltrate` covers **every** outbound network sink — the LLM provider endpoint **and** `web_fetch` — not just "a different chat." Once a session has ingested untrusted content **and** touched private data, a subsequent `web_fetch` requires approval showing the full resolved URL; fetch args containing substrings of MEMORY/USER files or secret-shaped tokens are **blocked by redaction before dispatch**. There is no "reply to owner DM ⇒ exfil-free" exemption. v1's "gated by approval" is the ephemeral text approval: an in-memory single-slot pending entry whose `yes` arms a one-turn grant bound to the exact approved action (tool + canonical target; for `web_fetch`, the canonical URL); anything else — including restart — denies. The durable approval FSM, callback auth, and nonces remain Inc 5a. Outbound sinks are classified: pinned trusted egress (the LLM `base_url` and the search endpoint — owner-configured and pinned, their providers see model-authored content under their ToS) is protected by the arg guard and config pinning, not approval; arbitrary-destination egress (`web_fetch`) additionally requires the trifecta approval. The owner explicitly accepts the search provider seeing model-authored queries.
- **FR-T7.** *(tools phase)* **Enforced lethal-trifecta gate.** Taint is a **sticky, persisted session property** (`session.tainted = true` once any untrusted content is ingested). When a tainted session attempts a privileged or egress action, the approval path is **forced in code** (or `/new` is required), independent of the tool's own risk tier. Compaction/rolling-summary **preserves an untrusted-provenance marker** and never folds untrusted tool output into the trusted summary.
- **FR-T8.** *(v1)* **SSRF protection.** `web_fetch` refuses non-public destinations: after DNS resolution and following redirects, the target must be a public IP — private/RFC-1918, loopback, link-local (incl. the `169.254.169.254` cloud-metadata endpoint), and reserved ranges are blocked. A tested invariant.

### 6.8 Scheduler *(later phase)*
- **FR-C1.** Restart-safe scheduler stores jobs in SQLite (id, owner, due/recurrence, timezone, prompt/message, status, created/executed timestamps).
- **FR-C2.** A periodic ticker fires due jobs exactly once per occurrence (timezone/DST-correct) by comparing next-occurrence to wall-clock (not by counting ticks), with a misfire/catch-up policy that **collapses missed occurrences into at most one delivery** (clock-gap cap, to avoid a wake-time fire-storm), and **one authoritative** overlap guard (an atomic DB claim PENDING→RUNNING).
- **FR-C3.** Scheduled runs are normal agent runs (full context) at **reduced privilege** (no auto-approval; default-DENY on approval timeout; no untrusted-web ingestion while holding high-sensitivity memory) and deliver results to the owner's Telegram DM. A **new LLM-parsed schedule requires explicit owner confirmation before it arms.**
- **FR-C4.** Audit events for job create/execute/cancel/failure. Proactive runs have their own daily spend budget.

### 6.9 Execution / sandbox *(later phase)*
- **FR-X1.** Shell/code execution runs behind an `ExecutionBackend` protocol. Inc 5b supplies
  `apple/container` on macOS 26+ arm64: one untrusted execution = one disposable, never-reused
  hardware-virtualized VM. Linux gets a separately chosen backend in Inc 6; until a pinned
  Linux-host spike proves a microVM-conformant design, the Linux choice remains open.
- **FR-X2.** Secure-by-default exec exposes no live workspace, home, or ambient host bind mount.
  Approved inputs are copied into one daemon-owned, per-execution ephemeral scratch directory and
  that copy is the sole host mount, explicitly read-only. Egress is denied unless opted in;
  capabilities are dropped; resource caps and deterministic timeouts are explicit. Staging applies
  the same canonicalize + workspace-scope + secret-shaped-content checks as file tools and binds
  realpath/bytes by SHA-256; opted-in egress is `canExfiltrate=true`.

### 6.10 Operator UX
- **FR-O1.** *(commands land with their features)* Telegram command menu: at minimum `/start`, `/help`, `/status`, `/new`, `/stop`, `/cost` in v1; `/memory`, `/retry` in v1; `/model`, `/approve`, `/reject`, `/schedule`, `/cancel` as their features land.
- **FR-O2.** *(v1)* **`status` / `doctor` self-check.** Exposed both as a **`clawd` CLI subcommand** and a Telegram **`/status`** command (distinct from the NG4 REST surface). It reports a concrete **per-subsystem health table** with a machine-readable JSON-to-stdout form pollable by launchd/systemd, covering at minimum: poller (connected, last update, last offset, last 409/429), LLM (last success, consecutive failures, last error class, retry budget), **LLM auth (provider, credential mode, and freshness — validated without a network call, and never printing a token or account id)**, DB (writable, WAL size, last checkpoint, free disk), runs (in-flight, oldest run age, last FAILED), and spend (today's USD, remaining budget). `doctor --check-config` validates config **without** starting the daemon, and a config/secret error is the **first thing** it prints.
- **FR-O3.** *(v1)* **`/new` semantics.** `/new` starts a **fresh conversation window** and (with the tools phase) **detaints** the session — described to the owner as "clears anything the bot read from web/files this session." **Durable memory persists by design**; forgetting durable facts is the separate confirm-gated `/memory delete` path (FR-M6). `/new` also clears the session's pending confirmation entry (memory and exfil-approval kinds).

## 7. Non-functional requirements

- **NFR-Security.** Untrusted-inbound model; default-deny numeric-ID boundary; in-code policy enforcement; explicit instruction hierarchy (system/security policy > developer config > identity files (SOUL/AGENTS/TOOLS) > user task > tool observations > retrieved/inbound content > durable memory (MEMORY.md/USER.md — untrusted tier)); durable memory is injected in the untrusted/labeled wrapper and never the system tier (FR-M5); the "lethal trifecta" (private data + untrusted content + outbound comms) is an **enforced gate**, not a flag (FR-T7), covering **every outbound sink** (FR-T6); access and rate-limit checks **fail closed**; secrets never in replies/logs. **Fail-closed everywhere a security check can error internally.**
- **NFR-Privacy.** Local-first storage; data minimization; `0600/0700` file permissions; redaction at both the log boundary and the outbound-reply boundary (exact-value redaction of loaded secrets as the primary mechanism, pattern scanning as secondary); owner can export/delete (FR-S4); rely on OS full-disk encryption + an encrypted secret store + at-rest file encryption for the un-redacted message archive. Provider credentials live in their own encrypted envelope under the state root, and **tokens, account identifiers, device/authorization codes, and opaque provider replay payloads never appear in logs, replies, tool input, memory, or the search index** — a rotating credential is covered by the same exact-value redaction as a static one, across the rotation window.
- **NFR-Reliability.** Retries only on retryable errors with capped exponential backoff + full jitter at exactly one layer with a retry budget; **at-least-once** outbound delivery via the transactional outbox (FR-S3); crash-recoverable explicit run state machine with a boot reconciliation sweep; graceful shutdown; never silently loop (hard budgets stop and ask). Deterministic startup failures (bad config, missing secret, `409`, `SQLITE_FULL`) **back off rather than hot-loop**; disk-full refuses new turns and replies "storage full" once without crash-looping; `doctor` does a free-disk preflight.
- **NFR-Performance.** Responsive for an interactive DM assistant: typing indicator within ~1 s; **streaming time-to-first-token** is the felt-latency metric. Low idle footprint as an always-on daemon.
- **NFR-Portability.** Same source targets macOS and Linux. For early phases this is a **soft guideline** (keep portable protocol seams and AsyncHTTPClient/OpenAI-compat choices; pragmatic macOS-native code is permitted behind a protocol or flagged for audit), with **one hard gate** at the Linux portability/deployment phase: the CI Linux build must pass before release.
- **NFR-Operability.** Structured logs (swift-log) to stdout/stderr; an **ordinary append-only audit log** (actor, action, tool, redacted args, result size, decision, timestamp, run/session id) separate from app logs — useful for "why did it do that." (No hash-chaining / tamper-evidence claim in v1; if integrity is added later it requires an **external anchor** outside the daemon's writable scope.) Per-call token/cost capture; supervisor restart throttling documented in the launchd/systemd config; distinct non-retryable exit codes for config-validation and secret-load failures.
- **NFR-Maintainability/Testability.** Small, well-bounded modules with inward-only dependencies; pure domain core; mockable transport + provider; a top-level **error taxonomy** (`ProviderError / TelegramError / PolicyDenied / BudgetExhausted / StoreError / ConfigError`, each tagged retryable | terminal | user-visible); unit + integration tests (Swift Testing).
- **NFR-Cost.** A **USD spend breaker** is a v1 feature: a per-run cost ceiling **and** a rolling per-day cap, checked in code **before** each provider call (estimate input tokens + projected output); a hard kill-switch halts LLM calls and DMs the owner when the daily cap trips. Retries and any fallback count against both budgets; never silently fall back to a pricier tier. Token caps + the USD breaker are in v1; per-call USD attribution **dashboards** are deferred (NG9). Defaults for every budget (incl. `perRunUSD`, `perDayUSD`) are pinned in [`ARCHITECTURE.md` §5]. **On a plan-included route (FR-P5) the USD gates are inert by design** — there is no dollar cost to cap — while the token, turn, tool-call, and wall-clock ceilings and the daily token breaker stay fully enforced; usage still records with a confirmed zero and an `included_plan` source, so the audit trail stays complete and the two billing modes never share an identity.

## 8. Product principles (non-negotiables)

Distilled from the verified best-practices research:

1. **The harness acts, not the model.** The model only *proposes* a structured action; deterministic code validates, authorizes, executes, records, returns an observation.
2. **Enforce policy in code, not in the prompt.** Prompt text is defense-in-depth only.
3. **Default-deny, numeric-ID boundary; fail closed.** Reject unknown senders before any LLM/tool/expensive work; security checks deny on internal error.
4. **Untrusted inbound is data, never instructions.** Maintain a strict instruction hierarchy; the lethal-trifecta condition forces approval in code.
5. **Pause before the irreversible step.** Approvals bound to exact actions, expiring to deny, approvable only by the recorded owner.
6. **Hard budgets are product features.** Turns, tool-calls, tokens, wall-time, **USD**, retries — on exhaustion, stop and tell the owner (a concrete user-visible message, principle 10).
7. **Persist everything important; make side effects idempotent** (DB-internal dedup + transactional outbox; exactly-once across the network is impossible).
8. **Scarcity forces curation** (bounded memory) and **flush before compaction.**
9. **Boring over clever; ship a vertical slice end-to-end first** — but v1 must be a *useful* slice (memory + read-only web/file + streaming), not a robust echo.
10. **Anti-sycophancy & honest degradation:** no fabricated numeric confidence; state assumptions and ask on ambiguous irreversible actions; on failure the owner sees a plain-language message, never silence or a raw error.

## 9. Scope & phasing

**v1 = the daily-driver milestone.** It is *conversational + durable memory + read-only tools + streaming* — the smallest slice that earns daily use over the official ChatGPT/Claude apps. We still build it increment-by-increment (see the roadmap), but the success criteria below are claimed only for slices that can actually earn daily use.

**In v1:** conversational core; durable memory (remember-on-confirm + FTS5 recall); read-only tools (`web_search`, `web_fetch`, workspace file READ — all `safe` tier, no sandbox/approval); streaming replies; the USD spend breaker; onboarding/first-run; non-text intake handling; user-visible degradation; data export/delete; single-instance guard + 409 handling; `status`/`doctor`.

**Deferred to later phases:** write/shell/code tools + sandbox + approvals + the enforced lethal-trifecta gate; scheduling/proactive (its own phase); ChatGPT subscription authentication (its own phase); image/vision input (near-term roadmap); multi-provider/credential fallback; per-call USD attribution dashboards.

| Phase | Capability | Headline outcome |
|---|---|---|
| **v1 — Daily driver** | §5.1, §5.2, §5.3 | Supervised default-deny Telegram DM → real OpenAI-compatible **streaming** LLM answer; persisted; multi-turn; per-session FIFO lane + `/stop` + `/new`; durable memory on confirm + FTS5 recall; read-only `web_search`/`web_fetch`/file-read (`safe`, exfil-gated); USD breaker; onboarding; non-text handling; graceful degradation; export/delete; `doctor`; survives restart. |
| **P-tools** | §5.4 | Write/shell tools + in-code policy gate + Telegram approval flow (callback auth + nonce + FSM) + sandbox (`apple/container` in Inc 5b on macOS 26 arm64; Linux backend in Inc 6) + enforced lethal-trifecta gate. *Delivered in two increments — **5a** (approval fabric + write tools, no virtualization) then **5b** (sandbox + code execution); see [`ARCHITECTURE.md` §20].* |
| **P-schedule** | §5.5 | NL reminders; restart-safe DST-correct scheduler; confirm-before-arm; reduced-privilege proactive runs; opt-in heartbeat with quiet hours; delivery to DM. |
| **P-auth** | §5.6 | ChatGPT subscription login (`clawd auth login` / `status` / `logout`) + the ChatGPT Responses route behind the existing `LLMProvider` seam; one qualified model value selects it; no API key, no API billing, no new environment variables; the configured OpenAI-compatible route unchanged and still the default. *Independent of the v1→Linux build order — see [`ARCHITECTURE.md` §20].* |
| **P-portability** | — | Linux portability + deployment (static SDK, distroless/systemd, CI Linux gate). |
| **Roadmap (later)** | — | Image/vision input; native Anthropic adapter (prompt caching); pairing flow; sqlite-vec recall (behind a protocol). |

A detailed technical increment roadmap (Increment 0…6, each with a "done-when" threshold; v1 = Inc 0–3) lives in [`ARCHITECTURE.md` §Roadmap](./ARCHITECTURE.md).

## 10. Success criteria

Each criterion is backed by an **automated acceptance test** (per-requirement verified-by-test); a phase is "done" only when its tests pass.

- **SC1 (v1).** From a cold machine boot, an allowlisted Telegram DM gets a context-aware **streaming** LLM answer; an un-allowlisted DM never reaches the model. State survives `kill -TERM` + restart. No formatting-related Telegram 400s. Two quick messages produce two **in-order, non-interleaved** replies. **A provider outage produces a graceful user-facing message, not silence or a raw error.**
- **SC2 (v1).** Tell it a fact today; it recalls that fact in a new session next week after restarts; the owner can review it with provenance and delete it.
- **SC3 (v1).** "Read this URL / my notes file and summarize" works with no approval tap (read-only `safe` tier); a fetch in a tainted, private-data-touching turn is gated by approval, and fetch args carrying secret-shaped tokens are blocked before dispatch; a `web_fetch` to a private/loopback/link-local/metadata address is refused (SSRF). v1's "gated by approval" is the ephemeral text approval: an in-memory single-slot pending entry whose `yes` arms a one-turn grant bound to the exact approved action (tool + canonical target; for `web_fetch`, the canonical URL); anything else — including restart — denies. The durable approval FSM, callback auth, and nonces remain Inc 5a.
- **SC4 (v1).** The daily USD cap trips a hard kill-switch that halts LLM calls and DMs the owner; the owner can export and delete their conversation history (including FTS rows).
- **SC5 (ops, v1).** `status`/`doctor` answers "which subsystem is wedged and since when, and is it safely configured?" in one command (per-subsystem table + JSON), `doctor --check-config` validates without starting the daemon, and a second `clawd` refuses to boot. *(No tamper-evident-audit claim.)*
- **SC6 (P-tools).** A consequential tool (file write / shell) cannot run without an explicit owner approval bound to the exact resolved action; untrusted code cannot read host secrets or reach the network by default; a tainted session is forced down the approval path in code; a forged or third-party callback cannot approve a pending action.
- **SC7 (P-schedule).** "Every weekday 07:00 Europe/Berlin…" fires once per weekday across restarts and a DST change; a new schedule arms only after explicit confirmation.
- **SC8 (P-portability).** The same source produces a running, supervised binary on a fresh Linux box; the CI Linux build passes.
- **SC9 (P-auth).** With no API key configured, `clawd auth login` completes a device-code login and prints the exact `CLAW_LLM_MODEL=openai-chatgpt/<model>` line; applying it, an allowlisted DM gets a streaming answer over the subscription route, recorded with its token counts, a confirmed **zero USD**, and an `included_plan` cost source. **Every other model value still routes to the configured OpenAI-compatible endpoint with unchanged URL and key behavior.** `clawd auth status` reports freshness with no network call; concurrent turns share exactly one token refresh, and a stale request cannot invalidate a newer token. An expired credential tells the owner to stop the daemon and log in, while an entitlement or quota failure says what it is and **does not**. Token, turn, tool-call, and wall-clock caps still stop a run. **No test contacts OpenAI.**

## 11. Constraints & assumptions

- Pure Swift; Swift 6 strict concurrency; SwiftPM; **platform floor macOS 15** (`Calendar.RecurrenceRule` for the Inc 4 scheduler — Linux re-validation stays inside the Inc 6 gate).
- macOS 26 + Apple Silicon for `apple/container` (P-tools); Linux needs a separate sandbox backend.
- One owner; Telegram Bot API; long-polling.
- LLM access via an OpenAI-compatible endpoint the owner configures, with a pinned/allowlisted `base_url` — or, on the subscription route (FR-P5), a ChatGPT account the owner logs into, against a fixed endpoint that is a compile-time constant rather than configuration.
- Configuration is environment-based; structured configuration (`config.toml`) is deferred, and no per-provider environment namespace is introduced in its place (NG10).
- Single machine per deployment (no clustering); a single-instance startup lock enforces one daemon per state root.
- A bounded, non-null `max_tokens` and a configured USD spend cap are required at startup (`doctor` rejects otherwise).

## 12. Risks & open questions

- **R1.** Telegram thin-client correctness (offset ordering, 409 conflict, 429 flood-control) — mitigated by the FR-G2 durability invariant + single-instance guard + typed 409 + tests.
- **R2.** `apple/container` is macOS-26/Apple-Silicon-only. Inc 5b therefore ships the macOS
  backend only; Linux execution remains absent until Inc 6 resolves and proves its backend.
- **R3.** OpenAI-compat shims lag native features (Anthropic prompt caching, some tool-calling quirks) — acceptable; the `LLMProvider` protocol leaves an escape hatch, now exercised: the ChatGPT Responses adapter (FR-P5) is the seam's first non-Chat-Completions wire format.
- **R4.** `sqlite-vec` (vector search) requires a custom SQLite amalgamation + separate Linux re-validation — keep strictly behind a protocol and deferred; FTS5/BM25 is the v1 recall mechanism.
- **R5.** Prompt injection has no reliable model-level fix — rely on least-privilege, the enforced trifecta gate, and approvals, not a classifier; the memory-write scan is defense-in-depth only.
- **R6.** GRDB + FTS5 on Linux is contributor-supported (FTS5 may not be compiled into the platform SQLite) — mitigated by vendoring the SQLite amalgamation with FTS5 compiled in and a Linux CI job; risk is **Low (macOS) / Med (Linux until our own CI exists)**.
- **R7.** The ChatGPT subscription route (FR-P5) is **unofficial and provider-dependent**: it is derived from behavior observed in two reference implementations, **not** from a public, supported third-party ChatGPT inference API. The vendor can change or withdraw its endpoints, headers, device flow, or event shapes **without notice**, and the vendor's terms govern what a subscription may be used for. **Risk accepted deliberately, with the blast radius bounded by design:** the route is confined to its own credential and wire adapters, adds nothing to the path of an owner who does not select it, and the supported OpenAI-compatible route stays the default and is one model-value change away. swift-claw does not claim this route is stable or supported and must never document it as such.
- **OQ1.** HTML vs MarkdownV2 as the default Telegram parse mode (HTML is less 400-prone).
- **OQ2.** Linux sandbox backend (Inc 6): KVM-backed microVM versus an explicitly amended
  userspace-kernel profile, decided only after the pinned Linux-host spike.

*(Resolved and removed from open questions: memory write policy = confirm-on-write; context counting unit = graphemes; memory caps = 2200/1375; error-on-overflow is the v1 contract.)*

## 13. References

- Architecture: [`ARCHITECTURE.md`](./ARCHITECTURE.md)
- Product brief & principles: [`teleclaw-prompt.md`](./teleclaw-prompt.md)
- Research (verified): [Swift implementation grounding](./research/swift-claw-impl-grounding-2026-06-15.md), [best practices & Swift how-to](./research/swift-claw-best-practices-2026-06-15.md)
- Architecture study: [OpenClaw & Hermes](./research/persistent-agents-openclaw-hermes.md)
