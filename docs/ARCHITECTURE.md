# swift-claw — Architecture

| | |
|---|---|
| **Status** | Normative technical spec (v1 scope approved) |
| **Date** | 2026-06-15 |
| **Owner** | Ivan Magda |
| **Related** | [`PRD.md`](./PRD.md) · [`TESTING.md`](./TESTING.md) · research: [impl-grounding](./research/swift-claw-impl-grounding-2026-06-15.md), [best-practices](./research/swift-claw-best-practices-2026-06-15.md) |

> Clean-room, original implementation. References OpenClaw/Hermes/teleclaw concepts only; copies no code.

> **Authority.** This document is the NORMATIVE technical spec. The load-bearing contracts below — §5 concurrency lane, §6.1 inbound sequence, §6.4 outbound outbox, §7 Store API + FSM tables, §9 context assembly — are authoritative and binding on the implementation. Where the `research/` sketches and this spec disagree, **this spec wins**. The PRD references this document for the technical contracts (notably §9 context assembly).

---

## 1. Guiding principles

1. **One reused agent loop behind thin surfaces.** A single agent runtime; Telegram is the only surface in v1, but it sits behind a normalized message envelope so other surfaces could be added.
2. **Local-first long-running daemon as control plane.** One supervised process owns connectivity, state, policy, and scheduling.
3. **The harness acts, the model proposes.** Deterministic code validates/authorizes/executes/records every side effect.
4. **Enforce policy in code.** Risk levels, allow/deny, approvals, rate limits, budgets, quiet hours are checked by the runtime, not the prompt.
5. **Untrusted inbound.** Messages, web pages, tool output, attachments — and durable memory — are *data*. A strict instruction hierarchy is applied in code; untrusted data is wrapped/labeled and can never claim system authority.
6. **Secure-by-default, fail-closed.** Dangerous tools off; consequential actions approval-gated; numeric-ID default-deny; access checks and rate limiters deny/throttle on internal error rather than failing open.
7. **Stop and ask, never go silent.** Every failure mode (provider outage, budget exhaustion, storage full, unsupported input) produces a plain-language user-facing message, never silence or a raw error/stack.
8. **Boring & legible.** Small, well-bounded modules; a layered dependency DAG; a pure domain core; heavy use of Swift value types + actors.
9. **Portable, pragmatically.** macOS-primary; Linux-clean is a soft guideline through the early increments, hardened by a **macOS + Linux GRDB/FTS5 build+test CI gate live on every PR** (`ci.yml`, §17). Portable protocol seams are kept throughout.

## 2. System context

```
                 ┌─────────────────────────────────────────────┐
   Telegram  ───►│  swift-claw daemon (clawd)                   │───► LLM endpoint
   (Bot API,     │                                              │     (OpenAI-compatible:
    long-poll)◄──│  ServiceGroup supervises:                    │◄───  OpenAI/OpenRouter/
                 │   • TelegramPollerService (intake)           │      Groq/Ollama/LiteLLM…)
                 │   • SchedulerService (ticker)        [Inc4]   │
                 │   • (future services)                        │
                 │                                              │
                 │  owns: routing · access control · sessions · │
                 │  agent runtime · memory · outbox · tools/    │
                 │  approvals · scheduler · audit · shutdown    │
                 └───────┬───────────────────────┬─────────────┘
                         │                        │
              ┌──────────▼─────────┐   ┌──────────▼───────────────┐
              │ SQLite (GRDB, WAL) │   │ ~/.swift-claw/workspace  │
              │ sessions/messages/ │   │ SOUL/AGENTS/USER/TOOLS/  │
              │ runs/usage/audit/  │   │ MEMORY.md, memory/*.md   │
              │ outbox/memory/...  │   │ skills/<name>/SKILL.md    │
              └────────────────────┘   └──────────────────────────┘
                         │
              ┌──────────▼───────────────┐
              │ ExecutionBackend (sandbox)│  [Inc5b]
              │ apple/container (macOS)   │
              │ microVM/Podman (Linux)    │
              └───────────────────────────┘
```

The Telegram client is a deliberate **thin clean-room implementation** over AsyncHTTPClient. The research's *primary* recommendation was `nerzh/swift-telegram-bot`; the thin client was its **runner-up**. We choose it deliberately for clean-room provenance, zero bus-factor on an external maintainer, and full control over transport, escaping, and the long-poll/offset durability contract. The committed surface is ~8–10 endpoints (see §18), not "~5."

State root: `~/.swift-claw/` (DB, secrets, logs) + `~/.swift-claw/workspace/` (identity/memory/skills). Profile override via `~/.swift-claw-<profile>/`.

## 3. Component architecture (modules)

SwiftPM package `swift-claw`. Module prefix `Claw`; daemon binary `clawd`. The dependency graph is a **layered DAG**, not a star: stores are reached through **protocols declared in `ClawCore`**, so `ClawAgent` and `ClawGateway` depend only on `ClawCore` for persistence (concrete `ClawData` is injected at the composition root in `clawd`).

```
clawd
  └─ ClawGateway ─────────────┐
        ├─ ClawAgent ─────────┤
        ├─ ClawTelegram ──────┤
        ├─ ClawLLM ───────────┼──► ClawCore  (protocols + value types; depends on nothing)
        ├─ ClawTools ─────────┤
        ├─ ClawWorkspace ─────┤
        └─ ClawData (concrete store impls; conforms to ClawCore store protocols)
              (injected only at the clawd composition root)
```

| Target | Kind | Responsibility | Key types |
|---|---|---|---|
| `ClawCore` | lib | Pure domain: value types, config model, **error taxonomy** (§19), **store protocols**, tool/provider/transport/sandbox protocols, the shared **HTTP seam** (`HTTPExecuting`/`HTTPResult`, request + response headers — F16), and the 32 768-char `ReplySplitter`. No I/O. | `IncomingMessage`, `SessionKey`, `Principal`, `AppConfig`, `RunState`, `ApprovalState`, `RiskLevel`, `RunBudget`, `HTTPResult`, `ReplySplitter`, error taxonomy types; protocols: `LLMProvider`, `ChannelIntake`, `MessageDelivery`, `TelegramTransport` (composite), `HTTPExecuting`, `SecretStore`, `ExecutionBackend`, `Tool`, `SearchProviding`, `MessageStore`, `SessionStore`, `RunStore`, `AllowlistStore`, `UpdateCursorStore`, `OutboxStore`, `UsageStore`, `AuditLog`, `MemoryStore`, `ApprovalStore` |
| `ClawData` | lib | GRDB persistence: schema, `DatabaseMigrator`, store implementations. WAL. **Thin `Sendable` wrappers over `any DatabaseWriter`** (not actors guarding the pool); relies on GRDB serialization. | `Database`, concrete `…Store` types conforming to the `ClawCore` protocols |
| `ClawTelegram` | lib | Thin Bot API client over AsyncHTTPClient; long-poll loop; envelope normalization; **`sendRichMessage` (markdown) + plain `sendMessage` fallback**; `sendChatAction`. (Escaping/splitter live in `ClawCore`.) | `TelegramClient`, `TelegramLongPoller`, `MessageEnvelope`, `InputRichMessage` |
| `ClawLLM` | lib | OpenAI-compatible Chat Completions client + OpenAI-shaped message model; usage/cost; retries; **SSE streaming (v1)**. | `OpenAICompatibleProvider`, `ChatMessage`, `ChatRequest`, `ChatResponse`, `ToolCall`, `Usage`, `CostTable`, `SSEParser` |
| `ClawWorkspace` | lib | Identity/memory files (`SOUL/AGENTS/USER/TOOLS/MEMORY.md`, `memory/*.md`, `skills/*`), Yams frontmatter, caps + untrusted-tier injection. | `WorkspaceStore`, `WorkspaceFile`, `MemoryDoc`, `FrontmatterParser` |
| `ClawTools` | lib | Tool registry + read-only tools (v1); policy gate + approval orchestration arrive in the P-tools phase (Inc 5a). | `ToolRegistry`, `ToolContext`; `WebSearchTool`, `WebFetchTool`, `FileReadTool` (v1); `PolicyGate`, `ApprovalCoordinator` [Inc5a] |
| `ClawAgent` | lib | Agent runtime: context assembly, the run loop, budgets, cancellation, the per-session lane. | `AgentRuntime`, `ContextBuilder`, `RunBudget`, `SessionActor` |
| `ClawGateway` | lib | Wiring: `ServiceGroup`, Services, routing, access control, session resolution, outbox dispatch, shutdown. | `Gateway`, `TelegramPollerService`, `SchedulerService` [Inc4], `Router`, `AccessControl`, `RateLimiter`, `OutboxDispatcher` |
| `clawd` | exe | Thin entry: load config + secrets → acquire startup lock → build ServiceGroup → run. | `main` |
| `*Tests` | test | One suite per lib; `MockTransport`, `MockProvider`, in-memory DB. (Real `ClawTools` mocks introduced when read-only tools land in Inc 3.) | — |

Each unit answers: *what does it do, how is it used, what does it depend on.* `ClawCore` depends on nothing, so the domain, protocols, and error taxonomy are trivially unit-testable.

`SearchProviding` is a `ClawCore` protocol; the default backend is Exa (`https://api.exa.ai/search`, a pinned trusted endpoint and documented trust dependency like `base_url`, including Exa's right to use query input/output to provide/improve its services). `Secrets.searchApiKey` keys it; unconfigured means the tool is absent and doctor reports info, not an error.

## 4. Process & runtime model

- Built on **`swift-service-lifecycle` `ServiceGroup`** (SSWG) over SwiftNIO. The daemon is a **process supervisor**, not a web framework — no listen socket by default (long-polling is outbound), which is the better secure-by-default posture.
- Each long-running concern is a `Service`: `TelegramPollerService` (Inc 0), `OutboxDispatcher` (Inc 1), `SchedulerService` (Inc 4). `ServiceGroup` provides ordered startup and **ordered graceful shutdown** on SIGTERM/SIGINT.
- **Startup cross-process lock.** At boot, `clawd` acquires an advisory `flock` on the state root. A second `clawd` against the same state root **refuses to boot** (distinct non-retryable exit) rather than fighting over `getUpdates`. The recovery runbook records which PID holds the lock.
- **Distinct startup exit codes.** Config-validation failure and secret-load failure are **distinct non-retryable exit codes**, so a deterministic startup failure (missing/`0600`-wrong age key, bad config) backs off under the supervisor instead of hot-looping. `clawd doctor --check-config` validates config/secrets **without starting the daemon**, and any config/secret error is the first thing it prints.
- **Shutdown choreography:** stop intake → let the in-flight turn finish (bounded) → drain the outbox → flush memory/state → checkpoint DB (bounded; PASSIVE fallback if a CLI read txn is open) → close → exit.
- **Supervision with throttling:** launchd (`KeepAlive`, `RunAtLoad`, `ThrottleInterval`) on macOS; systemd (`Restart=on-failure`, `RestartSec`, `StartLimitIntervalSec`+`StartLimitBurst`, `TimeoutStopSec`) on Linux. Throttling is documented in the units so a deterministic failure backs off.
- **Logging:** `swift-log` to stdout/stderr; journald/newsyslog handle rotation.

## 5. Concurrency model

### 5.1 Per-session lane (normative)

> **Correctness note (must-read).** Swift actors do **NOT** serialize across `await` — an actor reentrantly admits other calls while a turn is suspended on an LLM/network `await`. **"An actor serializes turns" is FALSE as written.** Ordered-enqueue-to-first-suspension (e.g. `ActorQueue`) orders work only up to the first suspension point and is **insufficient** for the run lane.

The lane mechanism is explicit:

- A `SessionActor` (one per `SessionKey`) holds `var currentTurn: Task<Void, Never>?`.
- Each new turn **chains** after the prior, so a turn runs to completion (across all its own suspension points) before the next begins:

  ```swift
  func enqueue(_ work: @Sendable @escaping () async -> Void) {
      let prev = currentTurn
      currentTurn = Task {
          _ = await prev?.value      // wait out the previous turn fully
          await work()               // run this turn to completion
      }
  }
  ```

- **Default = strict FIFO queue per session.** A plain inbound message **QUEUES** behind the current turn. Cross-session work runs concurrently; within a session, strictly ordered and non-interleaved. User-facing contract: two quick messages produce two in-order, non-interleaved replies.
- **Only `/stop` and `/new` SUPERSEDE.** `/stop` cancels the current turn cooperatively (`RunState → CANCELLED`). `/new` resets the session window, detaints it, and cancels the current turn (`RunState → SUPERSEDED`). A plain message never supersedes. `/new` resolves any pending durable approval as `superseded` (audited, §11) and still clears the session's pending command confirmation entry. `/new` also clears `sessions.has_private_data` in the same detaint transaction (Inc 5a, §12).
- **Cancellation semantics.** Cancellation threads through the run loop and (Inc 2+) streaming + tool execution via structured concurrency (`withThrowingTaskGroup`, cancellation handlers). On cancel: stop further LLM/tool work; any already-sent Telegram chunks remain (they are committed side effects, recorded in the outbox); no orphan `AWAITING_APPROVAL` row is left (the reconciliation sweep / FSM resolves it — §7).

### 5.2 Dependencies and state

- **`swift-async-queue` is dropped from the locked deps.** The plain actor + stored `currentTurn` Task handle above replaces it (single-owner DM bot → effectively one hot `SessionKey`; cross-session contention is near-empty in v1). It remains a noted escape hatch (§18) to revisit only if measured multi-session ordering/cancellation bugs appear.
- **Swift 6 strict concurrency.** Domain types are `Sendable` value types; mutable state lives in actors. Stores are thin `Sendable` wrappers over `any DatabaseWriter` relying on GRDB's internal serialization — **not** actors guarding the pool. Idempotency uses a single `db.write { }` transaction (§7), not a session-actor DB guard.
- **Backpressure & budgets.** Hard per-run caps (turns/tool-calls/tokens/wall-clock) **and a USD cost ceiling + rolling daily cap** (§5.3 / RunBudget), checked in code before each provider call. On exhaustion the run stops and the owner is told which cap was hit (§19 degradation UX).

### 5.3 RunBudget defaults

Concrete, config-overridable defaults for a single-owner daily-driver. These are the pinned numbers the PRD (FR-R3, NFR-Cost) refers to.

| Field | Meaning | Default |
|---|---|---|
| `maxTurns` | LLM round-trips per run | 12 |
| `maxToolCalls` | tool calls per run | 20 |
| `maxInputTokens` | context-assembly cap | 100000 |
| `reservedOutput` / `max_tokens` | mandatory, non-null (doctor rejects null) | 4096 |
| `wallClockDeadline` | per run | 180 s |
| `perRunUSD` | cost ceiling per run | $0.50 |
| `perDayUSD` | rolling daily spend cap (kill-switch + owner DM on trip) | $10.00 |
| `retryBudget` | attempts per request (~10% retry ratio) | 3 |
| `perToolOutputCap` | per-tool output (counted toward next-turn input) | 25000 tokens |
| `referenceUSDPerToken` | pinned cost reference for the offline token breaker | $0.000015 |
| `dayTokenCeiling` | derived hard offline failsafe = `perDayUSD ÷ referenceUSDPerToken` | ≈ 666 667 |

All overridable in config. The **hard offline failsafe is `dayTokenCeiling`** (a per-day token breaker checked before each call, so it trips even when no price is known); the USD caps ($0.50/run, $10/day) are the user-facing limits, enforced best-effort when a price is known. A **run in Inc 1 is exactly one LLM round-trip** — `maxTurns`/`maxToolCalls` exist but stay inert until tools land in Inc 3. `perToolOutputCap` is 25 000 tokens, enforced as its grapheme-domain equivalent 80 000 graphemes via the pinned estimator inverse (Inc 3b).

## 6. Data flow

### 6.1 Inbound message lifecycle — NORMATIVE numbered sequence (Inc 0/1)

The single most safety-critical invariant in the system. **The offset cursor advances LAST, only after the inbound write commits.** Never span the dedup check across an `await`.

```
TelegramPollerService loop:
  (1) getUpdates(offset = lastUpdateId + 1, long-poll timeout, allowed_updates)
       └─ 409 Conflict → DISTINCT typed error (not generic 5xx); surface loudly
          in doctor as "another poller active"; do NOT treat as retryable spin.
  for each update in the batch:
    (2) claimUpdate(update_id):
          INSERT OR IGNORE into processed_updates  ── in a SYNCHRONOUS actor
          critical section (NO await) ── returns inserted: Bool.
          If already seen → SKIP this update. (Reentrancy makes a "have I seen
          this?" check across an await unsafe; the claim is synchronous.)
    (3) normalize → IncomingMessage / callback / unsupported-type.
        AccessControl: numeric userId ∈ allowlist?   [default-DENY; fail CLOSED;
          BEFORE any LLM / tool / expensive work]
            └─ no → minimal "private bot" reply (unknown-sender path, §15); STOP.
    (3a) RateLimiter (per-user + global token bucket; honor retry_after;
         fail CLOSED on store/lock error).
    (3b) Non-text intake: unsupported type → friendly "I can't read X yet";
         media caption text IS processed; edited message → flagged isEdited
         and processed as a NEW turn (Inc 1); true /retry answer-replacement
         is deferred to Inc 2 (FR-G6).
    (4) ONE db.write transaction:
          • persist inbound message (sessions/messages, FK-linked to runs later)
          • record side effects / dedup rows belonging to this update
          • COMMIT
    (5) advance + persist lastUpdateId  ── ONLY after step (4) commits.
        The NEXT getUpdates(offset = lastUpdateId+1) acks the update to Telegram.
  then hand to the SessionActor lane:
       AgentRuntime.runTurn (queued per §5):
         a. ContextBuilder.assemble(...)        [§9 budgeted; truncation markers]
         b. TelegramClient.sendChatAction(typing)   [re-issued ~4s if blocking]
         c. (budget check) LLMProvider.complete / stream(messages)
         d. (Inc 5a) tool calls → PolicyGate → run safe / request approval
         e. persist assistant message (db.write)   [COMMIT before send — §6.4]
         f. enqueue outbound chunks (outbox) → OutboxDispatcher sends (§6.4)
         g. recordUsage + appendAudit (db.write)
```

> **Inc 1 fusion (claim + persist in one write).** Steps (2) and (4) are a single synchronous `db.write` — `claimAndPersistInbound` performs the `INSERT OR IGNORE` dedup claim *and* the inbound-message persist in one transaction (the §7.4/§7.5 idempotency invariant), not two separate commits; the cursor (5) still advances last.
>
> **Why the order matters.** If the offset were persisted *first* (the old diagram), a crash before step 4 commits would resume from the advanced cursor and Telegram would never redeliver — silently dropping messages. Advancing last makes "no missed/dup updates" actually true: a crash before step 4 simply re-fetches and the synchronous `claimUpdate` dedups any duplicate.
>
> **Poison-update policy.** If normalization of one update throws, advance the offset *past* it (never wedge the poller on one bad update), log it, and increment a `dropped_updates` counter surfaced in doctor.

### 6.2 Tool & approval flow (Inc 5a/5b)

```
model proposes tool_call
  └─ PolicyGate.evaluate(tool, args)          [risk tier (§10) + allow/deny + sandbox req]
       • read-only/safe → execute (no tap) → observation        [v1 tools live here]
       • ask        → ApprovalCoordinator.request:
                        persist PENDING (approvals) incl. ownerUserId, canonical-args
                          hash, policy_version, random callback nonce, fully-resolved target
                        send inline buttons
                        ├─ approve  (callback path — §6.5) → re-validate args-hash +
                        │            policy_version → execute ORIGINALLY-RECORDED args
                        ├─ reject   → cancel safely
                        └─ expire (approval-expiry ticker, default 1h) → DENY (terminal)
       • dangerous  → refuse unless explicitly enabled in config
       • LETHAL-TRIFECTA GATE (§12): if session.tainted && privileged/egress action,
         FORCE the approval path in code regardless of the tool's own tier.
  └─ AuditLog.append(actor, tool, args-redacted, decision, result-size, ts, run_id, session_id)
```

### 6.3 Scheduler flow (Inc 4)

```
SchedulerService ticks every 60s
  └─ due jobs computed by comparing last_fired_at / next-occurrence to WALL CLOCK
     (not by counting ticks) → robust across sleep/wake clock gaps
       └─ catch-up cap: collapse N missed occurrences into ≤1 delivery (max-age skip)
       └─ confirm-before-arm: a NEW LLM-parsed schedule requires owner confirmation
       └─ run as a reduced-privilege agent turn (no auto-approval; default-DENY — in
          Inc 4, pre-approval-FSM, any would-park approval outcome is an IMMEDIATE
          audited DENY with no pending state; when Inc 5a's FSM lands the same branch
          becomes park-with-timeout → EXPIRED → DENY; may not ingest untrusted web
          content while holding high-sensitivity memory; own daily spend budget)
       └─ deliver result to owner's Telegram DM (via outbox)
       └─ AuditLog: create/execute/cancel/failure
  └─ overlap guard: ONE authoritative atomic DB CLAIM (PENDING→RUNNING), not flock.
  └─ doctor exposes last_tick_at / due_count / last_misfire.
```

### 6.4 Outbound delivery — transactional outbox (NORMATIVE, Inc 1)

Exactly-once across the network is **impossible**. We implement an honest **at-least-once outbox** with idempotent completion.

```
table outbound_deliveries(
  run_id, step_index, chat_id,
  dedup_key UNIQUE  = run_id + ':' + step_index,   -- deterministic, NOT UUID/wall-clock
  payload_hash, telegram_message_id NULL,
  status [PENDING | SENT | FAILED], created_ts, sent_ts )

OutboxDispatcher:
  (1) For each ReplySplitter chunk, INSERT OR IGNORE one row with its own step_index
      (each chunk = its own step_index, so a partial multipart send recovers).
  (2) Send via sendMessage (or editMessageText for streaming coalesce).
  (3) On HTTP 200 → UPDATE status=SENT, telegram_message_id=<id>, sent_ts.
  (4) On crash/replay: rows still PENDING are re-sent; INSERT OR IGNORE +
      deterministic dedup_key prevent duplicate rows; a true network double-send
      is the irreducible at-least-once tail.
```

**Two honestly-distinct idempotency mechanisms** (do not conflate them):

- **(a) DB-internal dedup** via `INSERT OR IGNORE` inside one `db.write` txn — true for inbound `update_id`, `provider_usage`, `audit_events`.
- **(b) External side effects** via the transactional outbox — intent committed → effect performed **at-least-once** → completion recorded idempotently.

**Ordering invariant:** the inbound message + the run row **COMMIT before** the outbound reply is sent. So a disk-full/crash stops the turn before an unrecoverable side effect.

### 6.5 Callback (approval) path (Inc 5a)

`callback_query` updates arrive through the **same untrusted `getUpdates` stream** as messages but bypass §6.1 message ordering (they are callbacks). They MUST:

- run the **same numeric-ID default-deny** access check first; **and**
- be honored only if `callback.from.id == approval.ownerUserId` (persisted on the PENDING row);
- carry a `callback_id` that is a **≥128-bit single-use RANDOM nonce bound to the session** — NOT a sequential/PK/counter value;
- get the same audit + rate-limit treatment as messages;
- re-validate the stored canonical-args hash **and** `policy_version` at execution (an approval granted under an old policy cannot execute under a changed one);
- on expiry → DENY, enforced by the approval-expiry ticker (default 1h window, configurable via `approval_expiry`) (`PENDING → EXPIRED → DENY`).

## 7. Persistence & data model

**GRDB.swift v7** (Swift-6 concurrency-native), **WAL**, `DatabaseMigrator` for explicit versioned migrations, FTS5 for recall. One `DatabaseWriter` behind thin `Sendable` store wrappers.

Connection invariants (every connection): `PRAGMA foreign_keys = ON`; `busy_timeout = 5s`; `eraseDatabaseOnSchemaChange = false` (explicit). CLI tools open **read-only short txns** and must not hold a long read that blocks the shutdown checkpoint (bounded with a PASSIVE fallback). Periodic WAL checkpoint policy + a WAL-size signal in doctor.

### 7.1 Tables (introduced per increment)

| Table | Inc | Purpose | Key FKs |
|---|---|---|---|
| `allowlist` | 0 | numeric user IDs permitted (the security boundary) | — |
| `processed_updates` | 0 | claimed Telegram `update_id`s (dedup; synchronous claim) | — |
| `update_cursor` | 0 | last *confirmed* `lastUpdateId` (advanced last, §6.1) | — |
| `sessions` | 1 | session key, created/updated, rolling-summary ref, `tainted` | — |
| `messages` | 1 | role, content (un-redacted by design), session, ts, token counts; provenance marker (trusted/untrusted); **FTS5 external-content index added Inc 3a (not Inc 1)**; **`tool_calls` TEXT (JSON `[ToolCall]`, assistant proposals) and `tool_call_id` TEXT (set iff `role='tool'`), migration `v5`; `role` gains `tool`; tool rows persist with `provenance='untrusted'`** | `messages.run_id → runs.id`, `messages.session_id → sessions.id` |
| `runs` | 1 | RunState FSM, budgets used, `updated_ts` lease; **Inc 4: `origin` `'interactive' \| 'scheduled' \| 'heartbeat'` (default `'interactive'` — drives reduced privilege, the proactive budget, and doctor metrics) + nullable `job_id`** | `runs.session_id → sessions.id`, `runs.job_id → scheduled_jobs.id` |
| `provider_usage` | 1 | model, tokens (incl. cached/uncached where reported), computed USD | `run_id → runs.id`, `session_id → sessions.id` |
| `outbound_deliveries` | 1 | transactional outbox (§6.4) | `run_id → runs.id` |
| `audit_events` | 1 | **ordinary append-only** audit (actor, action, tool, args-redacted, result-size, decision, ts) | carries `run_id`, `session_id` |
| `memory_items` | 3 | type, content, source/provenance, ts, importance, sensitivity (durable facts; `confidence` deferred, `visibility`→`sensitivity` — Inc 3a) | `session_id → sessions.id` (nullable) |
| `scheduled_jobs` | 4 | `owner_chat_id` (set in code at arm time), `label`, `prompt` (owner-authored, trusted, frozen at confirm), `recurrence` (`{"schema_version":1,"rule":<RecurrenceRule JSON>}`; NULL ⇔ one-shot), `timezone` (IANA), materialized `next_occurrence` (advanced only inside the claim; NULL once terminal; partial index `(status, next_occurrence)`), `last_fired_at`, status FSM `ACTIVE\|PAUSED\|COMPLETED\|CANCELLED`, `session_id` (the job's dedicated session `sched:job:<id>`, NULL until first fire), `created_ts`/`updated_ts` | `session_id → sessions.id` |
| `scheduler_state` | 4 | single row (`id = 1` CHECK): `last_tick_at`, `last_misfire_at`, `last_misfire_skipped_count`, `last_heartbeat_at`, `heartbeat_count_day` (day string in `CLAW_TIMEZONE` — the cap boundary aligns with quiet hours, not UTC), `heartbeat_count`; `due_count` is computed by query, never stored | — |
| `approvals` | 5a | PENDING/APPROVED/REJECTED/EXPIRED (EXPIRED resolves to a DENY outcome at execution), tool + canonical args, **canonical-args hash, policy_version, ownerUserId, random callback nonce**, expiry | `approvals.run_id → runs.id` |

`runs.state = AWAITING_APPROVAL` references `approvals.id` as the **one** canonical source of truth for "blocked on approval" (no ambiguous dual flags).

The `approvals` row (Inc 5a) additionally carries `session_id`, `observation_message_id`, `tool_call_id`, `reason` (`ask_tier | exfil_trifecta`), `prompt_message_id`, and `resolved_ts`, and enforces a **UNIQUE partial index `WHERE state = 'PENDING'`** — at most one live approval per run. `outbound_deliveries` gains nullable `approval_id` + `reply_markup` (additive, so pre-upgrade PENDING rows stay valid; the envelope is not smuggled into `payload`): the button prompt travels through the transactional outbox, and when `approval_id` is set `markSent` writes the resulting `telegram_message_id` onto the linked approval's `prompt_message_id` **in the same transaction**.

Synthetic session keys (Inc 4): `sched:job:<id>` (one dedicated session per scheduled job, created lazily at first fire) and `sched:heartbeat`. `sessions` carries no chat id — a job run's delivery/notice target is `scheduled_jobs.owner_chat_id`; the heartbeat's is the config-resolved owner DM. `SessionKey.chatId(from:)` returns nil for both by design, so boot reconciliation resolves crashed-run owner notices for job runs via `scheduled_jobs.owner_chat_id` and for heartbeat runs via the config-derived target passed in at boot (§6.3, spec §5.2/§12).

### 7.2 Audit (Inc 1) — ordinary append-only, NOT tamper-evident

The audit table is an **ordinary append-only** record — genuinely useful for "why did it do that." **Hash-chaining / tamper-evidence / an `audit verify` tool are dropped from v1.** In-DB hash-chaining is *not* tamper-evident against the real threat (a same-host/compromised daemon can recompute and re-seal the chain), so v1 does not claim it. If integrity is added later (post-v1), it MUST use an **external anchor** (sign chain checkpoints with a key outside the daemon's writable scope and/or emit the head hash to an append-only off-daemon sink) and the audit row MUST be written in the **same transaction as the side effect**. Do not claim "tamper-evident" without an external anchor.

### 7.3 FTS5 + data lifecycle

- **External-content FTS5 over `messages`** (avoids duplicating sensitive text; keeps the owner-delete path a single source of truth). The vtable + sync triggers live in migrations — **built in Inc 3a via GRDB's FTS5 builder (`synchronize(withTable:)`, `content_rowid='id'`, `unicode61 remove_diacritics 2`), not Inc 1**.
- Content is stored **un-redacted by design**; at-rest file encryption (sops+age state root, §15) is the compensating control.
- The owner **data-deletion path also deletes/rebuilds FTS rows**, so deleted content is not recoverable via the index. A `messages` redesign requires an FTS rebuild migration.
- **Export + delete** covers conversation history (not just memory items); a retention/compaction policy bounds the message archive (see PRD FR for export/delete).

### 7.4 Idempotency (summary)

Dedup key + side effect committed in one `db.write` transaction; deterministic keys (not wall-time/UUID); the inbound dedup `claimUpdate` is done **synchronously** inside the owning actor critical section. External side effects go through the **outbox** (§6.4), not a "DB+network in one transaction" claim (impossible). **Vector search** (`sqlite-vec`) is deferred and isolated behind a protocol (§7.6); v1 recall is FTS5/BM25.

### 7.5 Store API (Inc 1) — load-bearing signatures

The seam between `ClawData` and the rest. Protocols live in `ClawCore`; `ClawData` implements them.

```swift
// dedup — synchronous claim, no await spanning the check
func claimUpdate(_ updateId: Int64) throws -> Bool        // INSERT OR IGNORE → inserted?

// inbound + assistant persistence share ONE write txn with their dedup/side-effects
func persistInbound(_ msg: IncomingMessage) throws         // db.write { dedup row + message }
func persistAssistant(_ reply: AssistantTurn) throws       // db.write { message + run update }

// outbox
func claimOutbound(runId: Int64, stepIndex: Int, chatId: Int64,
                   payloadHash: String) throws -> Bool      // INSERT OR IGNORE
func markSent(runId: Int64, stepIndex: Int, telegramMessageId: Int64) throws

// usage + audit (each INSERT OR IGNORE in its own/shared write txn)
func recordUsage(_ usage: ProviderUsage) throws
func appendAudit(_ event: AuditEvent) throws

// access (fail closed on store/lock error)
func allowlistContains(_ userId: Int64) throws -> Bool

// confirmed cursor — advanced LAST (§6.1 step 5)
func advanceCursor(to lastUpdateId: Int64) throws
```

All write methods execute inside a single `db.write { }` closure so the dedup key and the side effect share one transaction.

### 7.6 sqlite-vec — deferral honesty

`sqlite-vec` is **not** "add later via a protocol and a migration." It **requires a custom SQLite amalgamation** (`SQLITE_ENABLE_FTS5` **+** sqlite-vec, statically linked, **initialized before the connection opens**) and a **separate Linux-CI re-validation** (GRDB does not test it upstream; the vec binding ships its own connection). A stock `DatabaseMigrator` **cannot** create a `vec0` table. It stays strictly behind a protocol and deferred; risk = High (§18).

## 8. LLM provider abstraction

- **Contract:** OpenAI Chat Completions (the single wire format). `base_url` + `model` + `api_key` from config → swap providers without code changes (incl. local Ollama/LM Studio or a LiteLLM proxy). `base_url` is **pinned/allowlisted** and documented as a trust dependency (it is an outbound exfil sink — §12).
- **Internal model is OpenAI-shaped** (`role`/`content`/`tool_calls`), doubling as the wire format — minimal translation. Image input (`image_url` content parts; cheap on OpenAI-compatible providers) is on the **near-term roadmap**, not v1.
- **`LLMProvider` protocol** keeps a seam for a native adapter later (e.g. Anthropic Messages for prompt caching / extended thinking).
- **Client:** thin, over AsyncHTTPClient. **SSE streaming is v1**: a small SSE parser → throttled `editMessageText` (coalesce, min-interval ~1–2s, first chunk ASAP). If streaming is unavailable, fall back to blocking + re-issue `sendChatAction` every ~4s for the turn duration. The metric is **perceived latency (time-to-first-token)**, not just first-reply latency. (URLSession can't stream SSE on Linux → AsyncHTTPClient is the portable choice.) A stream whose response head carries a retryable-class status before any SSE bytes is a clean rejection (`ProviderError.rejected`) and falls back to the blocking path once; mid-stream failures still degrade with no re-issue.
- **Reliability:** retry only retryable errors (timeouts/429/5xx) with capped exponential backoff + full jitter + a retry budget (~3/req); honor `retry_after`. **Single-provider in v1** — automatic multi-provider/credential fallback is deferred (the `LLMProvider` protocol leaves room; an owner can retry or switch config). **Never silently fall back to a pricier tier.** Retries count against both budgets (§5.3).
- **Cost (best-effort, layered — no hand-maintained table):** resolve per-call USD as **provider-returned cost → vendored MIT price file → conservative heuristic** (`totalTokens × referenceUSDPerToken`), attributed in `provider_usage` (every row records `cost_usd` + `cost_source` + `is_estimated`); this feeds the USD breaker (§5.3). **Never a silent $0** — a heuristic computing to 0 with tokens > 0 is floored at $0.000001, while a *confirmed* provider $0 is recorded as $0. An unknown model falls through to the heuristic, and doctor surfaces the price-source mix. Per-call USD dashboards are deferred; the USD breaker + the offline token ceiling are v1.

## 9. Memory & context architecture — SINGLE NORMATIVE SOURCE

> §9 is the **single normative source** for context assembly. The PRD references this section; any divergent ordered list elsewhere is superseded by this one.

### 9.1 Workspace files

`~/.swift-claw/workspace/`: `SOUL.md` (persona/tone/boundaries), `AGENTS.md` (operating rules), `USER.md` (owner profile/timezone), `TOOLS.md` (tool notes), `MEMORY.md` (curated long-term), `memory/YYYY-MM-DD.md` (daily logs), `HEARTBEAT.md` (proactive tasks), `skills/<name>/SKILL.md` (agentskills.io standard; Yams for frontmatter). **Missing files never crash** — each loads to `(text, wasTruncated)`.

### 9.2 Canonical ordered list + budget formula

One canonical ordered assembly. Each section carries a **priority** and a **truncatable** flag.

| # | Section | Tier | Priority | Truncatable |
|---|---|---|---|---|
| 1 | System / security policy | system (trusted) | highest | no (degrade-not-drop) |
| 2 | Identity files (SOUL/AGENTS) | system (trusted) | high | no |
| 3 | Developer config / tool policy (TOOLS) | system (trusted) | high | no |
| 4 | Current date/time | system (trusted) | high | no |
| 5 | Owner profile (USER.md) | **untrusted/labeled wrapper** | med-high | no — hard cap 1375; overflow → omit + owner error (not silent truncation) |
| 6a | Durable memory file (MEMORY.md) | **untrusted/labeled wrapper** | med | no — hard cap 2200; overflow → omit + owner error |
| 6b | Durable memory items (`memory_items`) | **untrusted/labeled wrapper** | med | yes (budget cap; recency + importance — relevance deferred, Inc 3a) |
| 7 | Session history / rolling summary | mixed; **provenance preserved** | med | yes |
| 8 | Retrieved (FTS5 recall) + tool observations | **untrusted/labeled wrapper** | low | yes |
| 9 | Skills | untrusted/labeled | low | yes |

**Budget:** `inputCap = modelMax − reservedOutput`. Fill **greedily by priority**. A truncatable section is **cut to its cap** with a literal marker string (e.g. `…[truncated]`). A non-truncatable section **degrades but is never dropped**.

### 9.3 Memory tier, caps, and trust

- **Untrusted tier.** `MEMORY.md`/`USER.md` are injected inside the **SAME untrusted/labeled wrapper** as other data — **never the system tier** — so poisoned memory cannot claim system authority.
- **Caps (grapheme `String.count`):** `MEMORY.md` = **2200**, `USER.md` = **1375**. **On overflow → ERROR, never silent truncation.** For these **hand-curated** files, "force consolidation" means the runtime **omits the over-cap file for the turn and delivers an owner-facing consolidation notice** — it never auto-rewrites the file (Inc 3a). **This is the v1 contract** (it resolves the former §21 open question; it is not also listed as open).
- **Flush-before-compact:** durable facts are written to disk *before* any history summarization.
- **Compaction preserves provenance:** never fold an UNTRUSTED `tool_result` into the trusted rolling summary; retain an `untrusted` marker (§12).
- **High-sensitivity memory is NOT auto-injected** into a turn that already ingested untrusted content (§12).
- **Confirm-on-write** shows the **EXACT verbatim text** post-Unicode-normalization, with invisible/zero-width/bidi chars **made visible/stripped**. The pattern scan is **defense-in-depth only** (not an acceptance gate — it must not block the owner's own notes).
- `/memory review` + `/memory delete` (confirm-gated) with provenance.
- **Recall:** FTS5/BM25 over the message archive; durable facts (`memory_items`) by recency + importance, subject to the budget above. **Item-lane *relevance* is deferred** until item-FTS / `sqlite-vec` lands (Inc 3a); message recall uses BM25. Row-8 recall searches `user`/`assistant` roles only — tool rows stay FTS-indexed (and delete with their message) but are excluded from BM25 recall.

### 9.4 Counting unit

Grapheme counting (`String.count`) is used uniformly for all caps and budgets.

## 10. Tool system & policy

### 10.1 Read-only tier (v1)

v1 ships **read-only tools only**: `web_search`, `web_fetch`, workspace **file READ**. They are read-only + idempotent + low-blast-radius → **`safe` tier (no tap)**. Per-tool output cap **~25k tokens** (enforced as its grapheme-domain equivalent 80 000 graphemes via the pinned estimator inverse), counted toward the **next turn's input budget** (it is re-sent until compaction). `web_fetch` enforces an **SSRF blocklist** (a tested invariant): after DNS resolution and following any redirects, the destination must be a **public** address — requests to private/RFC-1918, loopback (`127.0.0.0/8`, `::1`), link-local (`169.254.0.0/16`, incl. the `169.254.169.254` cloud-metadata endpoint), and other reserved ranges are **refused** — and it is also subject to the outbound **exfil gate** (§12).

### 10.2 Default risk-tier table

| Class | Examples | Default tier | Approval |
|---|---|---|---|
| Read-only / idempotent / low blast | `web_search`, `web_fetch`, file READ | `safe` | none (but exfil gate applies) |
| Writes | file write, memory write | `ask` | per-action approval (Inc 5a) |
| Shell / exec | `execute_code` | `dangerous` | approval + sandbox (Inc 5b) |
| Egress-from-sandbox | opted-in network in an exec run | `dangerous` | approval; run is `canExfiltrate=true` |

(Inc 5a) **Registry** of < 20 narrow, typed tools (not a generic shell), each with input/output schemas, declared `RiskLevel`, timeout, sandbox requirement, audit behavior. The **`PolicyGate`** evaluates every proposed call before dispatch, independent of the model, and re-validates the approved action against the originally-approved canonical action + `policy_version` at execution. File tools are workspace-scoped: every path is resolved to its **canonical real path** (`realpath`, after `..` and symlink resolution) and **asserted to lie within the workspace root** — a tested invariant covering both the link and its final target — with size-capped output and secret redaction. Tool annotations are non-authoritative UX hints; the code gate is authoritative. (Batch approval + a time-boxed auto-approve toggle are deferred to the P-tools phase.)

## 11. Approval system (Inc 5a)

A **state machine** persisted in `approvals` so it survives restart. See §7.1 columns and the **ApprovalState FSM table** in §19.1. Requesting an approval **suspends the run to a durable checkpoint** (`runs.state = AWAITING_APPROVAL`, persisted) — a restart resumes the exact pending action rather than re-running the turn. Key contracts:

- **Bound to the exact action** (tool + fully-resolved target + canonical args); executes the **recorded** args (never a fresh model turn); a past approval is **never** cached into a future auto-run.
- **Durable checkpoint = persist-the-partial-exchange**, not a serialized wire checkpoint: the assistant proposal + every completed observation + a **placeholder observation row updated in place** (the v5 `messages` columns) pin rowid adjacency at suspend; the approved action runs the recorded args; the run then continues as an ordinary assembly round-trip whose context bound is the filled observation's message id, with **carried-over turn/tool-call/token/USD counters** and a **fresh per-segment wall-clock** (suspension time never counts against any budget).
- **Callback auth** (§6.5): same default-deny check; `callback.from.id == approval.ownerUserId`; ≥128-bit single-use random nonce; re-validate args-hash + `policy_version`. Args-hash + `policy_version` validation happens **inside the callback resolution CAS** as the §19.1 approve guard (a mismatch commits `PENDING → REJECTED`, `decision = stale_policy`, and never reaches `APPROVED`); the at-execution recheck survives only as the boot crash-window belt (§6.5), whose granted-then-denied audit pair is documented — a mismatch there fails the **run** while the row stays `APPROVED`.
- **`policy_version`** (Inc 5a) is the first 16 hex chars of a **length-prefixed SHA-256** over the policy-relevant inputs at run start: **system-tier prompt materials** (the system/security prompt text + the loaded contents of `SOUL.md`/`AGENTS.md`/`TOOLS.md`, a missing/unreadable file hashing as empty), the **tool registry surface** (sorted tool names, each with its canonical parameter JSON, declared `RiskLevel`, and `ToolEgressClass`), and the **pinned egress + policy config** (`llm.base_url`, search-endpoint presence, canonical workspace root). **Secret values are never hashed.** It is computed in two parts — a static sub-hash over the tool/config inputs at the composition root, folded into `ContextBuilder`'s prompt-material hash — persisted to `runs.policy_version` at pick-up and copied onto every approval; a **strict-inequality** mismatch at resolution denies with `stale_policy`.
- **Expiry → DENY** (terminal). Expiry is a **liveness / bounded-state control, not an attacker defense** — the single owner is the only approver, so the timer blocks no third party; its job is to guarantee a parked approval **self-resolves** instead of pinning a run (and its session lane) forever, with DENY as the fail-closed default direction. Default window **1h**, configurable via `approval_expiry`; enforced by a periodic expiry ticker and the boot reconciliation sweep (§19.1).
- **Escaping a pending approval:** a plain message **queues** behind it (strict FIFO — it never supersedes, §5.1); to abandon the parked action before expiry the owner uses `/stop` (cancel) or `/new` (reset + detaint), both of which resolve `AWAITING_APPROVAL` (§19.1). Otherwise silence rides out to `EXPIRED → DENY`.
- **Queue-behind survives restart:** boot reconciliation **re-parks a waiter on the lane** of every unexpired `AWAITING_APPROVAL` run, preserving the FIFO queue-behind contract across restart and giving **exactly one execution locus** — the callback handler, expiry ticker, and `/stop`//`new` command paths only CAS the row and signal the coordinator; the waiter task performs the resume/deny (observation update, run transition, owner notice, button disarm).
- **`ownerUserId` resolution:** the run's **delivery chat id** — the DM chat id for interactive runs, `scheduled_jobs.owner_chat_id` for job runs, the config-resolved owner DM for heartbeat runs — under the Telegram private-chat-id ≡ user-id identity; group chats are out of scope for v1 (single-owner DM bot).
- **Approval prompt contract:** show the **fully-resolved canonical target** (absolute path after symlink/`..` resolution; full URL incl. query/body, **never model-truncated**), a **TAINT banner** when the originating turn ingested untrusted content, and human-meaningful **blast radius** (create vs overwrite; egress yes/no). Redaction hides **secrets**, not the destination fields the owner needs to judge risk. Workspace-contained **privileged files** (`SOUL.md`/`AGENTS.md`/`USER.md`/`MEMORY.md`) are **writable via `file_write` behind an explicit ⚠ privileged-file banner** in the prompt (owner decision, 2026-07-09) — flagged, not refused in code, because they feed the system prompt / private-data tier.

## 12. Security & trust model

**Defense in independent layers — none of which is "the model behaved."** Security rests on four layers that each hold even if the model is fully subverted by prompt injection: (1) the **numeric-ID default-deny boundary** — untrusted senders never reach the model; (2) **untrusted-data labeling + the in-code instruction hierarchy** — inbound/tool/retrieved content and durable memory are wrapped as data and cannot claim authority; (3) the **in-code policy gate + risk tiers** — every side effect is authorized by deterministic code at the dispatch site, never by the prompt; (4) the **enforced lethal-trifecta gate + approvals + blast-radius caps + the VM sandbox** — consequential actions are gated and contained. A successful injection therefore yields, at most, what an *unprivileged* turn could already do.

- **Boundary:** numeric Telegram user ID, default-deny, enforced before any LLM/tool/expensive work; fail-closed on internal error. No username path anywhere (identity-rebinding CVE class).
- **Instruction hierarchy (in code):** system/security policy > developer config > identity files (SOUL/AGENTS/TOOLS) > user task > tool observations > retrieved/inbound content > durable memory (MEMORY.md/USER.md — untrusted tier). Durable memory never sits at the system tier.
- **Approval audit vocabulary (Inc 5a):** three actions — `approval_requested`, `approval_granted`, `approval_denied` — with the `decision` column carrying `rejected | expired | cancelled | superseded | stale_policy`; each row is appended **in the same transaction** as the state transition it records. A callback that fails **auth** (non-allowlisted or non-owner sender, unknown nonce) is **not** an approval decision — it audits as an access event (`message_in` / `forbidden`), leaving the approval row untouched.
- **Lethal trifecta = ENFORCED GATE, not a flag.** Taint is a **sticky, persisted session property**: `session.tainted = true` once ANY untrusted content is ingested — meaning **external/tool/retrieved content** (web/file/tool output, Inc 3b+). **Durable memory (MEMORY/USER/`memory_items`) is untrusted-*labeled* data that sets `hasPrivateDataAccess` but does NOT itself taint the session** (Inc 3a). When `tainted` **and** a privileged/egress action is proposed → the runtime **FORCES the approval path** (or requires `/new`), **in code**, independent of the tool's own risk tier. Compaction/rolling-summary **preserves the untrusted provenance marker**. Taint persists on every commit path of a run that ingested untrusted content, including degraded and failed turns; a `/new`-superseded run does not re-taint the fresh window.
- **Exfiltration.** `canExfiltrate` covers **every** outbound network sink — the **LLM provider endpoint** AND `http_fetch` — not just "a different chat." Once `hasIngestedUntrusted && hasPrivateDataAccess`: a subsequent `http_fetch` **requires approval** showing the full resolved URL (incl. query/body); fetch args containing substrings of `MEMORY.md`/`USER.md` or secret-shaped tokens are **blocked by `redact()` before dispatch**; `base_url` is pinned/allowlisted (documented trust dependency); high-sensitivity memory is **not auto-injected** into a turn that already ingested untrusted content. There is **no** "reply to owner DM ⇒ exfil-free" exemption. **"Gated by approval" is the durable approval fabric** (Inc 5a, §11): the would-egress action suspends the run onto a durable `approvals` row bound to the exact recorded action (tool + canonical args/target; for `web_fetch`, the canonical URL), resolved only by an authenticated inline-button callback under the nonce/CAS contract. A restart **re-parks** the pending approval (boot reconciliation, §6.5) — the buttons still resolve; a plain "yes" text is **inert** for tool approvals; silence rides out to `EXPIRED → DENY`. The exfiltration trifecta's private-data leg is evaluated per turn (context assembly plus in-run reads); private content that entered persisted history via an earlier run's tool observation is not counted by later turns, so if the memory file is over-cap (omitted from assembly) and the turn performs no private read, a remembered private substring can egress without approval — accepted for v1, the session-persisted private-data flag belongs to Inc 5a's durable approval work. Inc 5a lands it: `sessions.has_private_data` is **set on every commit path** where the per-turn private-data leg was true (including degraded and failed turns), **read** into the trifecta gate's private-data leg (`session.has_private_data ∪ assemblyPrivateData ∪ runPrivateData`), **cleared** by `/new` alongside detaint, and **re-arms** on the next private ingestion. **Outbound sinks are classified:** pinned trusted egress (the LLM `base_url` and the search endpoint — owner-configured and pinned, their providers see model-authored content under their ToS) is protected by the arg guard and config pinning, not approval; arbitrary-destination egress (`web_fetch`) additionally requires the trifecta approval. The owner explicitly accepts the search provider seeing model-authored queries.
- **`/new`** = fresh conversation window AND **detaint** ("clears anything the bot read from web/files this session"). **Durable memory PERSISTS by design**; forgetting facts is a separate confirm-gated `/memory delete`.
- **Prompt injection:** assume no reliable model-level fix; mitigate by least-privilege + approvals + blast-radius caps + the taint gate, not a classifier. Delimit/spotlight untrusted content; strip invisible/zero-width/bidi chars; tool output can never change system instructions.
- **Secrets:** never in replies or logs. **Exact-value redaction** of the loaded secret values (bot token, api keys, age-decrypted material) is the **PRIMARY** mechanism at both the log boundary and the outbound-reply boundary (the values are already in memory — cheap, deterministic); pattern-based scanning is **secondary** defense-in-depth. The gateway owns the destination chat id; outbound controls strip auto-fetching image/link elements.

## 13. Execution / sandbox architecture (Inc 5b)

- **`ExecutionBackend` protocol** (`Sendable`), driven via `swiftlang/swift-subprocess`:
  - **macOS:** `ContainerBackend` shells out to the `apple/container` CLI — **VM-per-container** via Virtualization.framework (a container escape needs a *hypervisor* escape).
  - **Linux:** `PodmanMicroVMBackend` (Podman/runc-in-microVM or gVisor `runsc`) behind the same protocol. (Backend choice is a genuinely open question — §21.)
- **Isolation unit (explicit):** **one untrusted execution = one disposable, never-reused VM** with scratch staged and destroyed per run. The **warm pool amortizes only the boot of a fresh instance** — it never reuses an instance across jobs.
- **Secure-by-default exec:** no host bind-mounts (stage inputs into a scratch dir), egress denied unless opted in, `--cap-drop ALL`, rootless, resource caps (≈1GB/4CPU), `--init` reaper, deterministic timeouts (stop-signal then SIGKILL), `closeAllUnknownFileDescriptors` on Linux.
- **Staging is a gated data-crossing, not free:** apply the same canonicalize + workspace-scope + secret-shaped-content checks to the staging path as to FS tools (anti confused-deputy). When egress is opted in, treat the run as `canExfiltrate=true` and require approval if the session is tainted.
- Prefer **shelling to the CLI** over embedding the pre-1.0 `containerization` library (looser coupling, separate process tree). Backend state lives in an `actor`.
- **`sandbox-exec`/Seatbelt** only as defense-in-depth around the launcher — never the sole boundary.

## 14. Scheduler architecture (Inc 4)

- **`Calendar.RecurrenceRule`** (in-toolchain, DST/TZ-correct, `Sendable`/`Codable`) + a ~150-line custom 60s ticker.
- Jobs persisted in `scheduled_jobs`; **fire-once-per-occurrence**; **one authoritative overlap guard = atomic DB CLAIM (PENDING→RUNNING)**, not flock. Due-time computed against **wall clock** (clock-gap-robust), with a catch-up cap (§6.3). (Reconciliation, Inc 4: the research corpus suggests actor-lock *plus* flock as overlap guards — rejected; the atomic claim is the ONE guard, and the §4 startup flock already covers the second-process case.)
- Scheduled runs are **reduced-privilege** agent runs (confirm-before-arm, no auto-approval, default-DENY — in Inc 4 (pre-approval-FSM) an immediate audited DENY with no pending state; with Inc 5a's FSM the same branch becomes park-with-timeout → EXPIRED → DENY — own daily budget); delivery routed to the owner's DM via the outbox; audit on create/execute/cancel/fail. NL → schedule via an LLM parse step that requires owner confirmation; the parse obeys turn spend discipline — day-cap preflight before the call, a run-less `provider_usage` row after (`run_id NULL`), and a 30 s deadline so the poller is never blinded. Attack-case to test: a self-scheduling injection cannot create a recurring fetch-and-follow C2 loop.
- `getUpdates` recovery is pinned: socket read timeout = long-poll timeout + 10 s; backoff-reconnect on timeout/network error. Scheduler-side gap recovery is lateness-based (§6.3's catch-up table) — no wake detection. Doctor exposes `last_tick_at`.

## 15. Configuration & secrets

- **Config:** a typed `AppConfig` (validated at load); env/`.env` for development; an invalid config is **rejected and preserved** — the offending file is moved aside as `config.toml.rejected.<timestamp>` and the last-known-good config is kept, never silently overwritten or partially applied; **`doctor --check-config` validates without starting the daemon**; config-validation and secret-load failures are **distinct non-retryable exit codes**. `max_tokens` MUST be a bounded non-null value — **doctor rejects a config with null `max_tokens`** (§5.3). **`approval_expiry`** (Inc 5a) is a bounded duration with a validated **floor 60s, ceiling 86400s (24h), default 3600s (1h)** — how long a pending approval waits before `EXPIRED → DENY` (§11/§19.1); a violation is a distinct non-retryable `ConfigError` (exit code `configInvalid`).
- **Onboarding / first-run:** the owner ID enters the default-deny allowlist via the **config file in v1**. An UNKNOWN sender's `/start` may echo **THAT sender's own numeric ID** (so they can self-allowlist) but **never reveals allowlist contents** and **never itself grants access**. A doctor check confirms **"at least one owner is allowlisted."** Pairing (later) = a high-entropy single-use expiring rate-limited audited secret provisioned out-of-band; pairing writes go through the same audited, idempotent allowlist path.
- **Secrets:** a `SecretStore` protocol. **Not the macOS Keychain** (a launchd daemon can't use the Data-Protection keychain; the System keychain is root-only/deprecation-flagged). Implementation: **sops + age** at rest, decrypted to memory at startup; `swift-crypto` AES-GCM for any in-process needs. The age identity lives outside the repo, `0600`. Dev fallback: `0600` `.env` / env vars (clearly warned).

## 16. Observability

- **Structured logs** (`swift-log`) — metadata only by default (model, tokens, finish reason, tool, latency, status); prompt/completion content capture is opt-in. Exact-value secret redaction at the boundary (§12).
- **`status` / `doctor` are clawd CLI subcommands AND Telegram commands** (`/status`, `/cost`) — **distinct** from the NG4 REST non-goal. `doctor --check-config` validates without starting the daemon. There is a **machine-readable JSON-to-stdout** form pollable by launchd/systemd watchdog.

### 16.1 Health table (doctor / status)

| Subsystem | Fields |
|---|---|
| poller | `connected`, `last_update_at`, `last_offset`, `last_409_at`, `last_429_at`, `dropped_updates` |
| LLM | `last_success_at`, `consecutive_failures`, `last_error_class`, `retry_budget` |
| DB | `writable`, `WAL_size`, `last_checkpoint_at`, `free_disk` |
| scheduler | `last_tick_at`, `due_count`, `last_misfire` |
| runs | `in_flight`, `oldest_run_age`, `last_FAILED` |
| spend | `today_usd`, `remaining_budget` (per-run + per-day) |
| config/secret | validation result — **printed first** if it errored |

- **Audit:** ordinary append-only (§7.2) — useful for "why did it do that." No tamper-evidence claim in v1.
- **Cost:** per-call USD from a local pricing table, attributed per run; unknown model price → loud doctor warning, never silent $0.

## 17. Deployment & portability

- **Build:** SwiftPM (**platform floor macOS 15** — `Calendar.RecurrenceRule` requires it, Inc 4/§14); two release binaries: a **macOS-native `arm64` binary** and a **Linux `x86_64` binary built natively in the `swift:6.3-noble` container** with `--static-swift-stdlib` (the Swift runtime is bundled; the system `libsqlite3` is the sole external runtime dependency). A musl **Static Linux SDK** → fully-static/distroless image is deferred: GRDB v7 declares SQLite as a `.systemLibrary` and the musl SDK ships none, so a musl cross-compile can't link (see §18 Deployment escape hatch).
- **Portability is enforced continuously:** a **GRDB + FTS5 build+test gate runs on both macOS and Linux on every PR** (`ci.yml`) — the portability gate is live, not deferred. Portable protocol seams + AsyncHTTPClient/OpenAI-compat choices are kept throughout; pragmatic macOS-native code is permitted behind a protocol and covered by the Linux CI gate.
- **Supervise:** launchd plist (macOS) / systemd unit (Linux), with throttling (§4). Logs to stdout/stderr.
- **CI:** the macOS + Linux **GRDB + FTS5 build+test gate** (`ci.yml`) runs on every PR and blocks merge; releases (`release.yml`) publish as **GitHub Releases with SHA256 checksums + build-provenance attestations**, not a container image.

## 18. Technology decisions

| Decision | Choice | Rationale | Alternative / escape hatch | Risk |
|---|---|---|---|---|
| Daemon framework | `swift-service-lifecycle` ServiceGroup / NIO | structured supervised lifecycle; no listen socket | Hummingbird 2 (if REST later) | Low |
| Telegram client | **thin clean-room client** over AsyncHTTPClient (research **runner-up**; primary was `nerzh/swift-telegram-bot`) | deliberate clean-room provenance, zero bus-factor, full transport + offset-durability control; ~8–10 endpoints (getUpdates, sendMessage, **sendRichMessage**, editMessageText, sendChatAction, answerCallbackQuery, getMe, setMyCommands, getFile) | `nerzh/swift-telegram-bot` | Low–Med |
| Persistence | GRDB.swift v7 (WAL, FTS5, migrations); **pin GRDB** via committed `Package.resolved` + Dependabot + the CI gate (the `from:` range is the floor, `Package.resolved` is the pin); links the system `libsqlite3` (vendoring a SQLite amalgamation is deferred — it arrives only with sqlite-vec, §7.6); macOS + Linux CI job exercises GRDB+FTS5 | Swift-6 concurrency-native, boring, full-featured | SQLite.swift / raw C | Low |
| Vectors | deferred, behind protocol; **requires custom SQLite amalgamation + Linux re-validation** (§7.6) | `sqlite-vec` is alpha; stock migrator can't make a `vec0` table | FTS5/BM25 for v1 | High |
| LLM provider | **OpenAI-compatible** contract + `LLMProvider` protocol; single-provider v1 | swap providers/models via config; pinned/allowlisted `base_url` | native Anthropic adapter later | Med |
| Web search backend | Exa (`https://api.exa.ai/search`) behind `SearchProviding` [Inc 3b] | pinned trusted endpoint, documented trust dependency like `base_url` (Exa may use query input/output to provide/improve its services) | unconfigured `Secrets.searchApiKey` ⇒ tool absent, doctor reports info not error | Low |
| HTTP/SSE | AsyncHTTPClient + small SSE parser (**streaming in v1**) | URLSession can't stream SSE on Linux | — | Low |
| Sandbox | `apple/container` (macOS) + microVM/Podman (Linux) behind `ExecutionBackend` [Inc 5b] | hardware-virt boundary for untrusted code | colima (weaker, older-macOS) | Med |
| Secrets | `SecretStore` over sops+age + swift-crypto | daemon can't use macOS Keychain; portable | 0600 env file (dev) | Low |
| Scheduling | `Calendar.RecurrenceRule` + custom ticker/store [Inc 4]; **raises the platform floor to macOS 15** | in-toolchain, DST-correct; Codable round-trip + DST suite pinned as toolchain-drift tripwires | SwifCron (vendored) | Low |
| Concurrency | std-lib actors + stored `currentTurn` Task handle (await-to-order, cancel-to-supersede) | per-session lanes without an external queue lib | `dfed/swift-async-queue` (escape hatch only) | Low |
| Config files | YAML for SKILL.md frontmatter via Yams | maintained YAML parser | — | Low |
| Deployment | native-container Linux `x86_64` binary (`swift:6.3-noble`, `--static-swift-stdlib`) + macOS-native `arm64` binary; GitHub Releases with SHA256 checksums + provenance attestations; launchd + systemd | Swift runtime bundled; only `libsqlite3` needed at runtime; publishes without a container registry | musl Static Linux SDK → distroless/scratch (blocked today: GRDB links system SQLite, musl SDK ships none) / swift-sdk-generator (glibc) | Low |

## 19. Cross-cutting concerns

- **Error taxonomy.** A top-level error taxonomy lives in `ClawCore`: `ProviderError`, `TelegramError` (incl. the **distinct 409 conflict** type), `PolicyDenied`, `BudgetExhausted`, `StoreError`, `ConfigError`. Each is tagged **retryable | terminal | user-visible**. The retry classifier and the "failures-as-observations" rule both consume this taxonomy.
- **Error handling:** tool/run failures captured as observations, not crashes; the loop stays alive; typed errors at boundaries.
- **Retries/backoff:** one layer, retryable-only classifier, capped exponential + full jitter, retry budget (~3/req), honor `retry_after`. Retries count against budgets (§5.3).
- **Idempotency:** synchronous `claimUpdate` dedup for inbound; deterministic outbox keys for outbound; at-least-once delivery (§6.4).
- **Cancellation:** cooperative throughout; `/stop` (→ CANCELLED) and `/new` (→ SUPERSEDED) via the SessionActor; a plain message queues.
- **Degradation UX (user-visible contract):** on provider failure/timeout after retries → "I couldn't reach the model, try again" (no secrets/stack); on budget exhaustion → "I stopped because <cap> was hit"; the typing indicator is cleared. On `SQLITE_FULL`/disk-full → refuse new turns + reply "storage full" once + do **not** crash-loop; doctor free-disk preflight. 409 → loud doctor surfacing + startup lock prevents a second poller.

### 19.1 Run / approval FSM (NORMATIVE)

`RunState = PENDING / RUNNING / AWAITING_APPROVAL / DONE / FAILED / CANCELLED / SUPERSEDED`.

**FSM invariants:** synchronous reduce; **no default arm** (every state×event is explicit); side effects after commit; expiry → DENY is a first-class terminal.

**RunState transition table:**

| State | Event | Next |
|---|---|---|
| (none) | inbound claimed + persisted | PENDING |
| PENDING | lane picks up turn | RUNNING |
| PENDING | `/stop` / `/new` | CANCELLED / SUPERSEDED |
| RUNNING | turn completes + reply enqueued | DONE |
| RUNNING | retryable failure exhausted / terminal error | FAILED |
| RUNNING | `/stop` | CANCELLED |
| RUNNING | `/new` | SUPERSEDED |
| RUNNING | tool needs approval | AWAITING_APPROVAL |
| AWAITING_APPROVAL | approval APPROVED | RUNNING |
| AWAITING_APPROVAL | REJECTED / EXPIRED→DENY | FAILED |
| AWAITING_APPROVAL | `/stop` / `/new` | CANCELLED / SUPERSEDED |
| **RUNNING (at boot)** | reconciliation sweep | FAILED (or re-enqueue if idempotent via outbox) |
| **AWAITING_APPROVAL (expired, at boot)** | reconciliation sweep | DENY → FAILED |

**ApprovalState transition table:**

| State | Event | Next |
|---|---|---|
| (none) | request created (PENDING row, nonce, ownerUserId) | PENDING |
| PENDING | valid callback (auth + nonce + args-hash + policy_version OK) | APPROVED |
| PENDING | reject callback | REJECTED |
| PENDING | expiry ticker / boot sweep finds age > `approval_expiry` (default 1h) | EXPIRED → DENY (terminal) |
| PENDING | run CANCELLED/SUPERSEDED | REJECTED (audit `decision = cancelled \| superseded`; no orphan) |

A cancelled/superseded run resolves its PENDING approval to **`REJECTED`** — the state stays within §7.1's four values and the audit `decision` column records why (`cancelled` for `/stop`, `superseded` for `/new`). Never add a fifth ApprovalState.

**Boot reconciliation sweep:** any `RUNNING` at boot → `FAILED` (or re-enqueue if idempotent via the outbox); any expired `AWAITING_APPROVAL` → DENY; an `updated_ts` **lease** on `RUNNING` rows distinguishes stuck from in-flight; the expiry ticker (default 1h window, `approval_expiry`) enforces approval expiry `PENDING → EXPIRED → DENY`.

## 20. Roadmap (technical increments)

Re-cut for the approved v1 scope. **Inc 0–3 = the v1 daily-driver milestone**: conversational + durable memory + read-only tools + streaming. Each increment lands a working, supervised slice, and each **"Done when" is an automated acceptance test** (per-requirement verified-by-test), not a manual check.

| Inc | Title | Done when |
|---|---|---|
| **0** | Supervised default-deny Telegram daemon (echo) | Bot echoes an allowlisted DM; un-allowlisted DM refused (default-deny); **startup flock** blocks a second clawd; **409 handled** as a typed loud error; onboarding self-ID echo works; non-text gets "I can't read X yet"; doctor skeleton runs; survives SIGTERM + restart. |
| **1** | LLM turn (blocking) + persistence | Allowlisted DM gets a real OpenAI-compatible answer, persisted (sessions/messages/runs/usage/audit + **outbox** + **`claimUpdate` ordering**), multi-turn, surviving restart; **`sendRichMessage` (markdown) + plain `sendMessage` fallback** (no formatting errors); **degradation UX**; **USD budget** breaker; context caps. |
| **2** | Streaming + per-session lane | **SSE → `sendRichMessageDraft` (streaming rich drafts, finalized via `sendRichMessage`)**; per-session **Task-chaining** lane; a second message queues in order; `/stop` cancels; `/new` resets+detaints; `SecretStore` (no plaintext on disk). |
| **3** | Memory & workspace + read-only tools | Workspace files injected at the **untrusted tier** (budgeted, caps, flush-before-compact); durable facts on confirm; `memory_items` + **FTS5 recall** across restarts; `/memory`; `web_search`/`web_fetch` + file READ at **`safe`** tier with the **exfil gate**. |
| **4** | Scheduler & proactive | "Every weekday 07:00 Europe/Berlin…" fires once per occurrence across restarts/DST; **confirm-before-arm**; reduced-privilege runs; clock-gap catch-up cap; delivery via outbox; opt-in heartbeat with quiet hours. *(Scope reconciliation: the external research roadmap bundles memory/workspace into its "Increment 4" — this repo shipped those in Inc 3a; this increment is scheduler/proactive only.)* |
| **5a** | Approval fabric + write tools | *Prep first: add `approval-requested/granted/denied` audit cases + a per-run prompt/workspace fingerprint for `policy_version` to bind to.* Then a consequential **write** tool (`file_write`/`memory_write`, `ask` tier) requires explicit approval via the **durable FSM** (**callback auth + ≥128-bit nonce + suspend-to-`AWAITING_APPROVAL` + boot reconciliation + expiry ticker**); a **forged or third-party callback cannot approve**; the **enforced lethal-trifecta gate** (upgraded from Inc 3b's ephemeral grant to the durable FSM) forces approval on a tainted privileged/egress action. **No virtualization.** |
| **5b** | Sandbox + code execution | Built on 5a's approval fabric: untrusted code (`execute_code`, `dangerous` tier) runs in a **per-exec disposable VM** (no host FS/network by default) behind approval; the staging path is gated like the file tools; an opted-in-egress run is `canExfiltrate=true`. **Prereqs:** resolve the Linux backend (§21) + pin the base image + add a sandbox check to doctor. |
| **6** | Linux portability & deployment | Same source → running, supervised binary on a fresh Linux box (systemd); the **macOS + Linux GRDB+FTS5 build+test CI gate already landed early** (`ci.yml`, §17), so the remainder here is the **musl Static Linux SDK → distroless packaging, which stays deferred/optional** (§17/§18 escape hatch). |

*(Later/optional: image input to a vision model; native Anthropic adapter w/ prompt caching; Hummingbird `/v1/chat/completions` REST; MCP via official SDK + Linux SSE transport; voice transcription; multi-provider fallback; per-call USD dashboards.)*

## 21. Open architectural questions

Genuinely-open (decided ones have moved into the body above):

- **Linux sandbox backend:** Podman+microVM vs gVisor `runsc` (decide before Inc 5b).
- MCP transport on Linux: custom AHC SSE transport vs Stdio-only.
- Rolling summary vs aggressive compaction + just-in-time retrieval (treat rolling summary as one strategy; keep out-of-window references).

*Resolved and moved into the spec:* supersede-vs-queue (= strict FIFO queue, only `/stop`/`/new` supersede — §5.1); error-on-overflow (= v1 contract — §9.3); memory char-counting (= grapheme `String.count` — §9.4); memory injection tier (= untrusted/labeled, never system — §9.3); confirm-on-write (= the default, with verbatim normalized preview — §9.3); HTML-vs-MarkdownV2 parse mode (= moot — the Inc 1 primary path is rich **markdown** via `InputRichMessage`, with plain `sendMessage` as the fallback — §6.4).

## 22. References

- [`PRD.md`](./PRD.md)
- Research: [Swift implementation grounding](./research/swift-claw-impl-grounding-2026-06-15.md) · [best practices & Swift how-to](./research/swift-claw-best-practices-2026-06-15.md) · [OpenClaw & Hermes study](./research/persistent-agents-openclaw-hermes.md)
- Product brief: [`teleclaw-prompt.md`](./teleclaw-prompt.md)
