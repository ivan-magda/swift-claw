# swift-claw — Architecture Review

| | |
|---|---|
| **Status** | Point-in-time architecture review (code at Increment 4, commit `ed37007`) |
| **Date** | 2026-07-06 |
| **Scope** | Whole-repo system-design review: module boundaries, channel abstraction, runtime design, persistence, extensibility, personal-agent practices, concurrency |
| **Method** | 42-agent review workflow (9 subsystem mappers, 8 dimension-focused risk finders, 10 stress-scenario evaluators, merge pass, adversarial verifier per finding); every finding re-verified against source, top claims additionally verified by hand |

**TL;DR:** The architecture is genuinely healthy — the layered DAG is real and compiler-enforced, the persistence and provider seams are exemplary, and the scheduler proved the runtime can absorb a second work-initiator cleanly. The risks that matter are concentrated in two places: a handful of security/robustness invariants that hold by convention rather than by structure (tool policy membership, store error mapping, provenance decoding, tool timeouts), and `MessageRouter`, which is the convergence point where Increment 5 will land. Fix those before Inc 5; resist the temptation to build multi-channel abstractions now.

Verdicts are marked CONFIRMED or PLAUSIBLE; two findings were downgraded during adversarial verification and are presented with those corrections.

---

## 1. Architecture map

The system is a SwiftPM package of ten targets forming a **layered DAG with a dependency-free kernel**. `ClawCore` (domain value types, error taxonomy, and *all* cross-module protocols) imports only Foundation. Every other library imports `ClawCore` plus its own vendor dependency: `ClawData` (GRDB), `ClawTelegram` (AsyncHTTPClient/NIO), `ClawLLM` (the OpenAI-compatible client), `ClawTools`, `ClawWorkspace` (Yams), `ClawSecrets` (swift-crypto). `ClawAgent` holds the turn loop; `ClawGateway` holds routing and the ServiceLifecycle services. Crucially, `ClawGateway` does **not** import `ClawTelegram`, `ClawLLM`, `ClawData`, or `ClawTools` — it reaches all of them through `ClawCore` protocols. The only module that sees concrete implementations is the executable `clawd`, whose `RunCommand.makeDaemon` (`Sources/clawd/Subcommands/RunCommand.swift:152`) is a textbook composition root.

**Telegram enters** at `TelegramPollerService`, which long-polls via the `TelegramTransport` protocol and hands each `RawUpdate` to `MessageRouter.handle`. The router normalizes (`IncomingMessage.normalize`), applies default-deny access control, parses slash commands, and either answers directly (canned replies, memory/schedule commands, confirmation resolution) or claims-and-persists the message in one fused transaction and enqueues a turn onto the per-session `SessionActor` lane (a stored-Task chain, `SessionActor.swift:9-18`, honoring the spec's "actors don't serialize across await" rule).

**The agent runtime starts** at `TurnRunner.run` (gateway side: durable `PENDING→RUNNING` pickup, context snapshot, day-total reads) which calls `AgentRuntime.runTurn` (agent side: a bounded multi-round-trip loop with per-round-trip budget preflight, gated tool dispatch through `ToolDispatching`, streaming or typing sub-runtimes) and **ends** back in `TurnRunner.commit`, which writes assistant message + run-state flip + usage + outbox chunks in one transaction, then pokes the `OutboxDispatcher` to deliver at-least-once.

**Persistence** is GRDB behind fourteen use-case-shaped store protocols declared in `ClawCore/Persistence`; implementations in `ClawData` route all SQLite failures through `ClawDatabase.classifyError` into domain-typed `StoreError`. **Tools** are registered by literal array construction in `RunCommand.makeToolDispatcher` and dispatched through `GatedToolDispatcher` → `ToolPolicyGate` → per-tool `execute`, with one audit row per dispatch. **The scheduler** (`SchedulerService`) is a second work-initiator that produces the *same* durable artifact as an inbound message (session + trigger message + PENDING run, stamped with `origin`) and reuses the same lane, `TurnRunner`, and outbox.

## 2. Strong parts of the current design

These should be preserved; several are better than what I'd expect from a mature team's codebase.

1. **The module DAG is real, not aspirational.** `import GRDB` appears only in `ClawData` (15 files); no vendor JSON type escapes `ClawTelegram`/`ClawLLM`; `ClawAgent` never imports `ClawTools` (the `ToolDispatching` protocol inverts that edge). The compile graph *is* the architecture diagram.
2. **The store seam is disciplined in both directions.** Protocols are use-case-shaped, not table-shaped: `applyStop`, `applyRemember`, `claimAndFire` each name a fused claim+effect+audit transaction, so atomicity requirements live in the *interface*. The `writeMapping`/`classifyError` discipline currently holds at 100% (zero raw `.write(`/`.read(` call sites), and migrations v1–v6 are strictly additive.
3. **The composition root is textbook.** All concrete wiring in one place; time (`now`/`sleep`/`jitter`), transport, stores, and the provider are injected seams, which is why the test suites can drive turn runtimes, the scheduler, and the budget windows deterministically.
4. **Security policy rides types, not prose.** The untrusted fence renders in exactly one place (`LabeledContext.render`); taint (`ingestedUntrusted`) flips visibly to the *next* tool call in the same run and persists on completed, degraded, and cancelled commits alike; `ToolDispatchContext.nonInteractive` has no default, so a forgotten construction site is a compile error, not a privilege grant.
5. **The agent loop is genuinely multi-round-trip** with crash-safe spend discipline: intermediate usage rows are written *before* the next provider call, and a usage-write failure halts further spending (`.accountingFailed`). The budget gate runs before every provider call, not once per turn.
6. **Recovery is implemented, not just specced.** Offset-advance-last holds exactly as §6.1 requires; outbox dedup keys match §6.4 byte-for-byte; boot reconciliation sweeps orphaned runs to FAILED with owner notices, resolving job/heartbeat delivery targets correctly. The scenario-10 evaluation found no correctness gaps at the weeks horizon.
7. **The scheduler was absorbed, not bolted on.** Scheduled and heartbeat work flow through the same lane/TurnRunner/commit/outbox pipeline as interactive messages, with divergence expressed as durable data (`runs.origin`) rather than parallel code paths. This is the existence proof that the runtime accepts new initiators.
8. **The Inc-5 approval fabric already exists end-to-end** (`ToolAction`/`OneTurnGrant`/`ToolApprovalRequest`, park-after-commit-arbitration, tool-agnostic router interception) and is exercised today by the live `web_fetch` exfil-approval flow — pre-wiring that earns its place rather than sitting dormant.
9. **Right-sized concurrency.** `SessionActor` is 36 lines doing exactly what §5 requires; every actor keeps isolated methods await-free; unstructured tasks appear only where structured concurrency can't work, each leak-proofed; long-uptime memory is bounded (coalescing outbox signal, hard byte caps on SSE accumulation).
10. **Degradation UX is a real contract.** `runTurn` throws only `StoreError.diskFull`; every other failure resolves in-band to a `TurnResult` through one choke point, so the owner always gets a plain-language reply.

## 3. Highest-priority architectural risks

### Risk 1: The tool timeout is advisory — a wedged tool blocks the owner's entire session lane

Severity: High · Confidence: High · **CONFIRMED** (verified first-hand)

Evidence:

* `ToolPolicyGate.swift:192-220` — `executeWithTimeout` races `tool.execute` against `Task.sleep` in a `withTaskGroup`; after `group.next()` picks the timeout winner and `cancelAll()`, `withTaskGroup` still awaits the losing child before returning.
* `SSRFGuard.swift:142-170` — `SystemAddressResolver.resolve` calls blocking `getaddrinfo` synchronously inside the async method, which never observes cancellation; its comment claims latency "is bounded by the tool timeout above," which the group-await semantics make false.
* `AgentRuntime.swift:275-311` — the wall-clock deadline is checked *before* each dispatch, but `await toolDispatcher.dispatch(...)` itself is unbounded.
* `StreamingTurnRuntime.swift:193-219` — `sendDraftBounded` documents this exact pitfall ("task groups always await their children") and deliberately goes unstructured to avoid it; the tool gate uses the pattern the draft code explicitly rejected.

Why it matters: The per-session lane is strict FIFO, and for a single-owner bot the DM session *is* the bot. A DNS blackhole on a hostile or flaky `web_fetch` target (resolver retries commonly run 30 s–2 min) makes the bot dark for the whole window while the code claims a 30 s timeout — and `/stop` cannot preempt it, because cancellation can't interrupt a blocking syscall and the group can't return until it completes.

Future change that becomes painful: Increment 5's write/shell tools plug into this exact seam. A shell tool doing a blocking process wait — the natural first implementation — would be completely unprotected: a hung command wedges the session lane indefinitely, silently, because the timeout observation *is* produced, just never returned.

Recommended fix: Make the timeout arm actually abandon the tool task — reuse the first-finisher-wins pattern `sendDraftBounded` already established (unstructured tasks + continuation) — and move the blocking `getaddrinfo` off the cooperative pool behind the existing `AddressResolving` seam. Fix the misleading comment regardless.

Tradeoffs: An abandoned tool task keeps running detached until its I/O returns, so tools must tolerate post-timeout side effects — true for today's read-only tools, and a property Inc 5's write tools need explicit thought about anyway.

### Risk 2: MessageRouter is a 1,176-line convergence point whose invariants are enforced by comments and ordering

Severity: High · Confidence: High · **CONFIRMED** (verified first-hand)

Evidence:

* `MessageRouter.swift:21-67` — one struct, 14 injected collaborators; the top switch fans into ~14 responsibilities (normalize, per-arm allowlist gating, `/stop`, `/new`, `/remember`, `/memory` ×4, the six-verb schedule family, confirmation resolution, turn dispatch).
* 23 copies of the same `catch StoreError.diskFull { … } catch { … }` block (grep-verified), with subtly varying generic-catch bodies.
* `MessageRouter.swift:741-756` vs `1098-1113` vs `SchedulerService.swift:215-236` — the lane-enqueue closure with its diskFull contract exists in three near-verbatim copies across two modules.
* `MessageRouter.swift:495-535, 678-698` — `nextFires`/`armNextOccurrence`/`resumeNextOccurrence` encode phase-continuity and skip-past-now occurrence semantics (scheduling *domain policy*, with 20-line load-bearing comments) inside the routing layer, away from `OccurrenceCalculator`.
* `PendingConfirmationRegistry` + `MessageRouter.swift:832-844, 923-924` — one `PendingConfirmation` enum mixes command confirmations with tool approvals; the tool-approval arm in `commitPending` is "unreachable by ordering," enforced by `preconditionFailure` (a daemon crash if the ordering assumption is ever violated).

Why it matters: The file is the convergence point for four unrelated axes of change — new commands, new confirmation kinds, new claim/dedup paths, new update shapes. Its invariants (one claim per update, confirmation-interception ordering, diskFull→storageFull backoff, occurrence anchoring) are enforced only by reading the whole switch and its comments, so each axis of growth raises the odds of silently violating another axis's invariant.

Future change that becomes painful: Increment 5 lands *exactly here*: `callback_query` is a new `RawUpdate` shape, a new router arm, and a durable approval-resolution path replacing the in-memory registry — woven through `resolvePendingConfirmation`/`commitPending`, the most invariant-dense region of the file.

Recommended fix: Split along seams that already exist before Inc 5: a `CommandHandlers` file (stop/new/remember/memory), a `ScheduleHandlers` file — moving the occurrence math into a small pure `OccurrencePolicy` type in `ClawCore/Domain/Scheduling` beside `OccurrenceCalculator`, also consumed by `SchedulerService` — and a `ConfirmationResolver`, splitting `PendingConfirmation` into two types (command confirmations vs tool approval) so each switch is exhaustive over only cases it can legally see. Extract one claim/error-mapping helper (with an outcome parameter, since the generic-catch bodies genuinely vary) to collapse the 23 copies.

Tradeoffs: More files and some parameter plumbing; today's file, while huge, is uniformly patterned and readable — the split trades that locality for compiler-checked boundaries just before the file's riskiest growth spurt.

### Risk 3: Tool policy classification is out-of-band, string-keyed, and fail-open

Severity: Medium (High if not fixed before Inc 5) · Confidence: High · **CONFIRMED** (verified first-hand)

Evidence:

* `ToolPolicyGate.swift:10` — `static let egressTools: Set<String> = ["web_fetch", "web_search"]` is the gate's *only* knowledge of which tools are egress sinks.
* `ToolPolicyGate.swift:26-31` — any tool not in that set returns `.allow`, skipping the blocking secret/exfil arg-guard tiers *and* the trifecta check entirely.
* `ToolPolicyGate.swift:56-92` — the approval branch is keyed to `call.name == "web_fetch"`, with URL extraction, canonicalization, and `ToolAction` construction inline in `evaluate()`.
* `WebFetchTool.swift:57-68` — the tool re-canonicalizes the same URL in `execute`; the gate-approved canonical form is never handed down, so gate and tool must agree byte-for-byte.
* `ToolContracts.swift:206-211` — the `Tool` protocol offers no way for a tool to declare its policy class.

Why it matters: Everywhere else, this codebase makes forgotten policy a *compile error* (`nonInteractive` has no default; `ApprovalReason` copy is exhaustive). Here, a forgotten set-entry is a *silent bypass* of the exfil arg-guard — the one failure class the architecture otherwise structurally excludes. The enforcement machinery is correctly centralized in the gate; only the classification input is fragile.

Future change that becomes painful: Inc 5's write/shell tools, or any future `send_email`/MCP-bridged tool: the advertised one-line registry append (`RunCommand.swift:344`) ships a tool whose arguments are never screened — no compile error, no warning, no audit anomaly.

Recommended fix: Declare the policy class on the tool contract with no default (e.g. `ToolDefinition.egressClass: none | fixedEndpoint | arbitraryDestination`, plus an optional `approvalAction(arguments:)` resolver), have the gate consume the declared class instead of the name set, and pass the gate-resolved canonical action into `execute`. Enforcement stays exclusively in the gate; tools declare class, never verdicts.

Tradeoffs: A slightly fatter `Tool` contract, and one round of churn in `ToolContracts` — best paid before Inc 5 opens the risk window rather than after.

### Risk 4: `/stop` cannot cancel a PENDING run, contradicting the FSM's own contract and the spec table

Severity: Medium · Confidence: High · **CONFIRMED** (verified first-hand)

Evidence:

* `RunFSM.swift:10-11, 28-29` — `(.pending, .cancel) → .cancelled` is a documented legal transition; `docs/ARCHITECTURE.md` FSM table row "PENDING + /stop → CANCELLED".
* `RunStoreGRDB.swift:339-350` — `fetchActiveRunId` selects `WHERE state = RUNNING` only, so `applyStop` can never reach the pending arm.
* `CommandStoreGRDB.swift:43-52` + `MessageRouter.swift:184-190` — `applyStop` cancels at most that single run; queued PENDING runs are untouched.

Why it matters: The lane is a FIFO queue, so multiple PENDING runs per session are *normal operation* (send two messages; the second is durably PENDING for minutes behind a slow first turn). `/stop` cancels the RUNNING one, acks "stopped," and the queued message fires anyway — spending budget and replying after the owner asked for silence. The FSM reducer, its doc comment, and the spec table all disagree with the store query.

Future change that becomes painful: Inc 5's AWAITING_APPROVAL joins the same FSM with its own `/stop` semantics; built on a query that only sees RUNNING, parked and queued runs will silently escape `/stop`, and the bug will be blamed on the new FSM.

Recommended fix: Have `applyStop` cancel every PENDING+RUNNING run for the session (the plural-id plumbing already exists in the `/new` path) and cancel each on the lane.

Tradeoffs: Changes `/stop` from "stop the current turn" to "stop everything queued" — if the singular reading is intended, the fix is instead to align the FSM table and doc; either way one of the two must move.

### Risk 5: Context-snapshot decode is fail-open for the trust vocabulary

Severity: Medium · Confidence: High · **CONFIRMED** (verified first-hand)

Evidence:

* `SessionMessageStoreGRDB.swift:168-170` — `Provenance(rawValue:) ?? .trusted` and `MessageRole(rawValue:) ?? .user`: an unrecognized persisted provenance silently becomes the *most permissive* tier.
* `MemoryStoreGRDB.swift:113-127` — the same layer's `decodeItem` throws `StoreError.unexpected` on unknown enums, with a comment explicitly stating a corrupted value "must not silently become the permissive tier and falsify the taint guard."
* `RunStoreGRDB.swift:25` — `RunOrigin(rawValue:) ?? .scheduled`, a third silent fallback (at least toward reduced privilege, but uncommented).
* `ContextBuilder.swift:428-449` — fencing currently keys off `role == .tool`, so the hole is latent, not live.

Why it matters: Provenance is the §12 trust tier persisted precisely so assembly can one day key fencing off it. The decode direction is fail-open for the one enum whose entire purpose is a security boundary — violating a rule the same layer has already articulated and adopted elsewhere.

Future change that becomes painful: The moment any consumer reads `StoredMessage.provenance` (e.g. moving fencing from role-based to provenance-based, or adding a quarantined tier), a rollback, hand-edited row, or partial migration silently renders unknown values as trusted, unfenced content — a prompt-injection fence that quietly stopped existing.

Recommended fix: Mirror `decodeItem` and throw on unknown role/provenance; or if history reads must degrade rather than fail, default to `.untrusted` (the conservative direction) and log. Comment the `RunOrigin` fallback as deliberate or make it throw too.

Tradeoffs: Throwing means one corrupt row can block a session's context load until repaired — a trade the memory store already accepts; over-fencing after corruption is strictly better than silent trust.

### Risk 6: The StoreError-at-the-seam rule is convention-only

Severity: Medium · Confidence: High · **CONFIRMED**

Evidence:

* All 14 store protocols declare untyped `throws` (`Stores.swift`); every store holds the full `any DatabaseWriter` (`RunStoreGRDB.swift:6`), so raw `writer.write { }` compiles identically to `writer.writeMapping { }`.
* Discipline is currently perfect (zero raw call sites, grep-verified) — but 23 `catch StoreError.diskFull` sites in the router and `AgentRuntime`'s "throws ONLY diskFull" contract all rest on it.

Why it matters: The daemon's entire disk-full degradation design (60 s poller backoff + a one-time owner notice) depends on a one-word convention. A leaked raw `DatabaseError` routes to `.transientFailure` — a 2-second retry loop against a full disk with the owner never told — silently bypassing the designed behavior. (The original finding's "hot re-poll loop" was overstated; the verifier corrected it to the 2 s backoff path, which is still the wrong behavior.)

Future change that becomes painful: Inc 5 adds new stores (approval FSM). A new store method written with `writer.write` out of habit compiles, passes all tests that don't simulate `SQLITE_FULL`, and fails the contract only in production.

Recommended fix: Make the seam structural: stores hold a thin internal wrapper exposing only `writeMapping`/`readMapping` instead of `any DatabaseWriter`, so the raw methods are unreachable from store code. (Swift 6 typed throws is the stronger alternative but has ergonomic edges with protocol defaults and async composition; the wrapper avoids those.)

Tradeoffs: One thin type and 14 mechanical store-init edits.

### Risk 7: Executed tool exchanges are dropped from durable history on every failure path

Severity: Medium · Confidence: High · **CONFIRMED**

Evidence:

* `TurnRunner.swift:260-263` — "Exchanges are lost by design on the failure path"; `DegradedTurn` (`Persistence.swift:287-310`) has no exchanges field, so the store seam *structurally cannot* persist them, while `AssistantTurn` does.
* `AgentRuntime.swift:313, 401-429` — per-dispatch audit rows *are* written immediately, so on a failed run the audit trail and session history permanently diverge; taint from the same dispatches also persists.

Why it matters: The contract encodes "tool work that didn't reach a completed reply is worthless" — true for read-only tools, false the moment tools mutate state. The next turn's model context cannot know what already ran.

Future change that becomes painful: An Inc 5 run that writes a file and then degrades (deadline, provider blip) leaves history with no trace of the mutation. The verifier correctly noted the "model re-executes the side effect" scenario is softened by Inc 5's approval-per-action design, but the owner-facing gap stands: "what did that failed run actually do" is unanswerable from context.

Recommended fix: Add exchanges to `DegradedTurn` (additive schema change; `TurnOutcome` already carries them to the commit seam), or persist exchanges incrementally mid-run the way intermediate usage rows already are.

Tradeoffs: Failed runs write more rows, and `HistoryHygiene`'s replay semantics for trailing incomplete exchanges need one deliberate decision.

### Risk 8: Mid-run wire growth is unchecked — the provider's context window is the de facto enforcement

Severity: Medium · Confidence: High · **CONFIRMED**

Evidence:

* `AgentRuntime.swift:134, 331-345` — `wire` grows every round trip with proposals plus fenced observations; nothing re-fits or truncates.
* `AgentRuntime.swift:162-186` — preflight computes `inputTokens` but checks only USD caps and the day-token ceiling; `budget.maxInputTokens` is consumed *only* at assembly time (`RunCommand.swift:196-199`, grep-confirmed sole consumer).
* Per-observation cap is 25 k tokens (80 k graphemes); `maxToolCalls` 20 — a run can legally add hundreds of thousands of tokens to the wire.

Why it matters: Input-size discipline lives in `ContextBuilder`/`BudgetFitter`, but the loop is the component that actually grows input. On a cheap model the USD preflight is vacuous, and overflowing the window draws an HTTP 400 classified *terminal* — the whole run degrades as "provider unavailable," losing exchanges (Risk 7) and presenting as an undiagnosable provider failure.

Recommended fix: One guard in the existing preflight — `inputTokens > budget.maxInputTokens → .budgetStopped(cap: "per-run input")` — leaving true mid-run compaction as a later option that now has a seam to hang off.

Tradeoffs: A hard stop abandons the run's tail like any budget stop; the grapheme estimator needs headroom against real tokenizers.

### Risk 9: The `/schedule` NL parse runs inline on the poller loop and is the one unmetered LLM call

Severity: Medium · Confidence: High · **CONFIRMED**

Evidence:

* `MessageRouter.swift:455` — `await schedule.parser.parse(...)` inline in `router.handle`; the poller awaits `handle` per update, so nothing else is processed until it returns.
* `OpenAICompatibleProvider` retry budget × 180 s request timeout → a provider brownout can freeze *all* update processing for up to ~9 minutes, including `/stop`.
* `ScheduleDraftParser.swift:48-67` — usage/cost discarded: no `provider_usage` row, no audit row, no `BudgetGate` preflight.

Why it matters: Every other long-running operation is pushed onto a lane to keep the poller live; every other provider call obeys "no spend without a durable row." This one call breaks both invariants. Notably, the in-code comment cites an Inc 4 *plan* document as justification, but the normative `ARCHITECTURE.md` (which per the repo's own authority rule wins) still says the token breaker is checked before *each* call and cost is always attributed — this is genuine spec drift, not a ratified exception.

Future change that becomes painful: Each future "just one quick LLM call" command (`/remember` NL parsing, memory-search rephrasing) copies the precedent, multiplying synchronous provider dependencies inside the router and widening the gap between recorded and actual spend.

Recommended fix: Bound the parse with the same deadline race the turn runtimes use (or enqueue the continuation onto the session lane and ack immediately); record a `ProviderUsage` row (nullable `run_id` or synthetic run) and consult the day cap before issuing the call.

Tradeoffs: A short deadline turns slow-but-successful parses into "try again"; nullable `run_id` slightly complicates the origin-JOIN daily accounting.

### Risk 10: The outbound half has no channel-neutral seam; Telegram's Int64 chat id is baked into durable rows

Severity: Medium · Confidence: High · **CONFIRMED** (verified first-hand)

Evidence:

* `TelegramTransport.swift:1-23` — the one outbound protocol bundles intake (`getUpdates`), delivery (`sendMessage`/`sendRichMessage`), UX (`sendChatAction`, drafts), and admin (`setMyCommands`) into a single Telegram-named contract.
* `OutgoingReply` (the type that *looks* like the neutral outbound envelope) has zero use sites — dead code; the real currency is direct `transport.sendMessage` calls plus `OutboxChunk` rows.
* `outbound_deliveries` stores `chat_id` and `telegram_message_id` with no channel column; `OutboxStore.markSent(telegramMessageId:)`; `TurnRunner.outboxChunks` pre-splits replies to Telegram's 32,768 cap *at commit time*, freezing channel-shaped chunks into durable rows.
* `HeartbeatSettings.swift:50` — the allowlist's Telegram *user* id is used verbatim as the heartbeat *delivery chat* id (correct only because DMs make them coincide; the verifier confirmed this specific derivation is a documented, fail-closed spec decision).

Why it matters: The inbound half has a genuine anti-corruption layer; the outbound half is a protocol veneer. This is honest for v1 (the spec says one surface behind a normalized envelope), but the asymmetry is worth naming because it, not the inbound path, is what makes a second channel awkward.

Future change that becomes painful: Any second channel (see Scenario 1) starts with refactoring three gateway consumers, the outbox schema, and the composition root before new-channel code compiles.

Recommended fix: Do only the cheap part now, at the natural moment (Inc 5 already forces a transport edit for `callback_query`): split `TelegramTransport` into a poller-facing intake protocol and a narrow delivery protocol (`sendMessage`+`sendRichMessage` — actual gateway usage is already only these, so the split is mechanical), and delete or adopt `OutgoingReply`. **Defer** the durable channel-neutral address work until a second channel is actually chosen.

Tradeoffs: One more protocol and slightly more wiring for a daemon that may never grow a second channel — which is exactly why the full address abstraction should wait.

### Risk 11: Streaming round trips (the default mode) get zero retry for retryable provider errors

Severity: Medium · Confidence: High · **PLAUSIBLE** (deliberate in part — corrected during verification)

Evidence:

* `OpenAICompatibleProvider.swift:111-115` — streaming non-2xx is classified and thrown once; contrast `complete()`, which retries up to `retryBudget` with backoff.
* `AgentRuntime.swift:473-486` — the fallback to the (internally retrying) blocking path triggers *only* on `.connectFailed`; `.retryable` degrades the entire run and debits an estimated usage row. `streamingEnabled` defaults to true.

Why it matters — with the correction: the verifier found this is *partly* a documented deliberate decision (the Inc 2 design pinned "no double-issue after the stream request was transmitted," because the provider may already be generating and billing; three tests pin it). So "retry ownership was forgotten" is wrong. What survives: a clean HTTP 429/5xx *rejection* — where the server demonstrably generated nothing — still kills a whole multi-round-trip run, and that case is not covered by the no-double-issue rationale.

Future change that becomes painful: Inc 5 multi-tool runs die at round-trip N on one 429, discarding executed tool work (compounded by Risk 7).

Recommended fix: Narrow, respecting the pinned decision: treat pre-stream HTTP-status rejections (429/5xx before any SSE bytes) as re-attemptable within the remaining wall-clock window, or fall back to the typing path the way `connectFailed` already does. Leave genuine mid-stream failures degrading as designed.

Tradeoffs: Distinguishing "rejected before generation" from "failed mid-generation" adds one classification case to the provider; the existing tests pinning no-double-issue must be preserved, not deleted.

### Risk 12: Conversation export/delete/retention is a stated v1 commitment with no code and no increment slot

Severity: Medium · Confidence: High · **CONFIRMED**

Evidence:

* `PRD.md:127, 230` — FR-S4 *(v1)* and SC4 acceptance: owner can export and delete conversation history, deletion rebuilds FTS rows, retention bounds the archive.
* `ARCHITECTURE.md` §20 — no increment (0–6, nor the Later list) carries this work.
* The only DELETEs in the codebase target `memory_items`; messages (including everything `web_fetch` ever ingested), audit, usage, and outbox rows grow without bound.

Why it matters: This is not a scheduled-but-unbuilt feature — it's a product commitment the build plan never slotted. For a *privacy-sensitive personal agent*, the un-exercised deletion path is the gap: the FTS "single delete source of truth" contract exists (a migration test covers the trigger mechanics) but no end-to-end owner-facing deletion has ever been proven.

Future change that becomes painful: Retrofitting "forget this conversation" against 12+ months of interlinked rows (messages, FTS, runs, deliveries, audit) after every consumer has been allowed to assume append-only.

Recommended fix: Slot a small increment: `clawd export`, a fused-transaction session-delete store method with FTS cleanup, and a config-driven retention sweep as one more `Service` — all reusing existing discipline.

Tradeoffs: Retention deletes history that audit rows reference (audit outliving its messages weakens later forensics — decide the precedence deliberately); an export file copies private content outside the state root.

### Risk 13: The audit trail can't answer "under which instructions" — and approval grants leave no audit row

Severity: Low · Confidence: Medium · **PLAUSIBLE** (downgraded during verification)

Evidence: `SystemPrompt.swift` is a hardcoded prompt whose comment says "replaced in Inc 3" yet still ships; workspace files are re-read per assembly with no fingerprint; `MessageRouter.swift:832-844` — the owner's "yes" arms a grant with no audit write; `AuditAction` has no approval-granted/denied case (and a dead `messageIn` case). The verifier's corrections: the owner's "yes" *is* durable as a session message; in a single-owner system the approver is definitionally the owner; and the durable approval record is an explicitly documented Inc 5 deferral. What survives is the forensics gap ("which SOUL/AGENTS content was in effect for this run") and the fact that Inc 5's `policy_version` re-validation has nothing yet to bind to.

Recommended fix (cheap, optional now): one `ContentHash.fnv1a` fingerprint over the policy prompt + loaded workspace files, recorded per run; an approval-resolved audit row in `resolvePendingConfirmation`; keep the workspace under git for content recovery. Skip anything heavier.

### Risk 14: In-run channel effects bypass origin-aware delivery policy

Severity: Low · Confidence: Medium · **CONFIRMED**

Evidence: quiet heartbeat runs visibly type (`AgentRuntime.swift:264`, unconditional) and stream draft frames of the *full* content (`StreamingTurnRuntime.swift:89, 187-192`) that the commit layer then suppresses (`TurnRunner.swift:199-218`); `origin` reaches the runtime but gates only budget. Fix: skip typing/drafts when `origin != .interactive` inside `roundTrip` — origin is already a parameter. Low because the blast radius today is cosmetic (a typing bubble during heartbeats), but it's the seed of "suppression semantics can never be reasoned about in one place."

## 4. Module boundary review

**Gateway / Telegram layer — clear, with one asymmetry.** Inbound is exemplary: `RawUpdate → IncomingMessage.normalize` is a real anti-corruption boundary, `HandleOutcome` compresses the entire cursor/dedup contract into four cases, and the poller knows nothing about commands. Outbound is a veneer (Risk 10): one Telegram-shaped protocol serves intake, delivery, UX, and admin, and `OutgoingReply` is dead. `MessageRouter` itself is the blurriest single artifact in the codebase (Risk 2) — not because responsibilities are wrong but because too many converge in one file, including scheduling domain math that belongs in `ClawCore`.

**Agent runtime — clear.** The `TurnRunner` (durable pickup, snapshot, fused commit) vs `AgentRuntime` (pure-ish loop, provider, tools) split is clean and the mid-run persistence softening (usage/audit) is documented and justified. Two leaks: channel progress UX (`chatId`, typing, draft cadence) threads through the loop keyed to Telegram's interaction model, and the loop lacks an input-size checkpoint (Risk 8).

**Domain modules — clear, with small tolerated leaks.** `ClawCore/Domain` is pure (Foundation-only, I/O-free, pure reducers/validators). Telegram fingerprints exist and are named honestly: `tg:dm:` in `SessionKey`, the 32,768 `ReplySplitter` cap, `Command.parse(botUsername:)`, `BotMenuCommand`. Fine for v1; the `SessionKey` namespace grammar is actually the *right* extensible design.

**SQL / persistence — clear; the strongest layer.** GRDB is airtight in `ClawData`; protocols are use-case-shaped fused transactions; migrations additive; FSM transitions delegate to the pure `RunFSM`. Two convention-vs-structure gaps: the `writeMapping` rule (Risk 6) and inconsistent enum-decode direction (Risk 5).

**Tools — clear structure, one fragile input.** Registry/gate/dispatcher separation is right, the gate is the single choke point, audit-per-dispatch is universal. The classification set and the per-tool approval branch (Risk 3) are the weak input to an otherwise strong mechanism.

**Memory / recall — clear.** `MemoryStore`/`Retriever` are narrow, domain-typed, backend-neutral; recall is injection-safe by construction; memory provenance decoding is fail-closed with the rationale written down. The seams assume synchronous local retrieval (see Scenario 5).

**LLM provider integration — clear; second-strongest layer.** Vendor wire shapes are private to `ClawLLM`; consumers hold `any LLMProvider` over neutral types; SSE fully abstracted. The internal message model is OpenAI-shaped *by documented decision*, and the scenario-2 analysis confirms that bet is cheap. One drift: the streaming retry asymmetry (Risk 11) and one string-typed wart (`finishReason == "length"` matching in the loop).

**Configuration / secrets — clear.** Typed validated `AppConfig`, distinct exit codes, fail-closed resolver, exact-value redaction installed before the first logger. Nothing to change.

**Logging / observability — clear.** Metadata-only developer logs with run/session correlation, a typed closed audit vocabulary, doctor with per-subsystem health. Gaps are enumerable and additive (Scenario 9): approval-resolution rows, `consumedGrant` surfacing, the dead `messageIn` case, free-string `decision` normalization.

## 5. Extensibility review

**New gateway — awkward.** The missing abstractions are concrete and enumerable: `processed_updates`/`update_cursor` have no channel dimension (a CLI channel minting update ids would collide); `TelegramTransport` bundles four roles; the outbox stores Telegram-shaped chunks and `telegram_message_id`; typing/draft sinks are constructed into `AgentRuntime`; the allowlist is Telegram-numeric. What's already present: the wire-agnostic envelope, the namespaced `SessionKey` grammar, per-channel router/runner stacks being *possible* by construction, and `HandleOutcome` being channel-neutral. Verdict: a weekend of refactoring before the first line of new-channel code, not a rewrite.

**New tool — clean** (one struct + one array line, automatic auditing and budget caps) **unless it needs policy**, in which case you must know to edit `egressTools` (Risk 3). A confirmation-gated tool is **clean** — Scenario 3 traced the whole park/prompt/resolve/grant loop as tool-agnostic; only the gate branch and one `ApprovalReason` case (compiler-forced copy) are added.

**New domain module — awkward but honest.** The scheduling precedent measured 98.7% additive (1,443 insertions, 18 deletions, 5 new files, 7 small compiler-guided edits to shared files). The open/closed story is: domain, store, replies are additive; `Command`, `PendingConfirmation`, `AuditAction`, `ClawStores`, the migrator are small forced edits; **MessageRouter absorbs the dominant edit** (+489 lines for scheduling). The router split (Risk 2) is what turns this "awkward" into "clean."

**New LLM provider — clean.** Scenario 2's full trace: a new `AnthropicMessagesProvider` module, finish-reason normalization, one composition-root discriminator, pricing rows. No changes to the loop, history model, or migrations. The optional payoffs (cache-token accounting, typed stop reasons) are additive.

**New memory backend — clean for ranking/local retrievers, awkward for embeddings.** `RecallCutoff`/`Retriever` are real seams with single construction sites. Missing for vector work: an async `Retriever` (today's is sync, so `ContextBuilder.assemble` and one `TurnRunner` call site go async), an `EmbeddingProviding` protocol, an indexer service, and — if literal sqlite-vec — the custom amalgamation the spec already flags High-risk (§7.6, honestly documented).

**New scheduled/background task — clean.** This is the architecture's proven muscle: `Daemon` takes `[any Service]`; prompt-shaped capabilities are pure data on `scheduled_jobs`; a new *initiator kind* is one fused store method + one `RunOrigin` case (with a hand-audit of the three non-exhaustive origin sites the compiler won't flag).

**New confirmation flow — clean pre-Inc5, planned churn at Inc 5.** One pathway exists and is generic; Scenario 8's caveat is real, though: the durable approval FSM converts `AgentRuntime.runTurn` from run-to-completion into suspend/resume (a new `TurnResult.suspended`, a fused suspend-commit, `RunStoreGRDB`'s raw-SQL active-state filters, and a `HistoryHygiene` exemption for the suspended exchange). That's the single largest planned change to the runtime — worth a design pass of its own before implementation.

## 6. Recommended target architecture

The current architecture *is* the right target — this is not a euphemism; the layering, the kernel-of-protocols pattern, and the composition root should not change. The target is the same diagram with five deltas, all of which sharpen existing seams rather than adding layers:

```
                clawd (composition root — the ONLY module seeing concrete types)
                  │
   ┌──────────────┼───────────────────────────────────────────┐
   │  ClawGateway: Services (poller, scheduler, outbox,       │
   │  future channels) · Router split into CommandHandlers /  │
   │  ScheduleHandlers / ConfirmationResolver · TurnRunner    │
   └──────┬───────────────┬───────────────────────────────────┘
          │               │
   ClawAgent (loop) ClawTelegram / ClawLLM / ClawTools / ClawData / ClawWorkspace
          │               │            (each: vendor code behind ClawCore protocols)
          └───────┬───────┘
                  ▼
   ClawCore — pure domain + ALL protocol seams:
     • ChannelIntake (getUpdates-shaped)  +  MessageDelivery (send-shaped)   [split]
     • LLMProvider · ToolDispatching · Tool (+ declared policy class)        [enriched]
     • 14 store protocols over a MappedDatabase-only writer                  [hardened]
     • OccurrencePolicy beside OccurrenceCalculator (schedule math)          [moved in]
     • RunFSM · budgets · error taxonomy · LabeledContext (unchanged)
```

Dependency direction stays exactly as today: everything points at `ClawCore`; `ClawCore` points at nothing; only `clawd` sees implementations. The deltas: **(1)** split the transport port into intake vs delivery so outbound consumers stop depending on a Telegram-named contract; **(2)** move tool policy classification onto the tool contract, keeping enforcement in the gate; **(3)** move occurrence-anchoring policy from the router into the scheduling domain; **(4)** make the store seam structurally incapable of leaking raw errors; **(5)** split the router by command family with a shared claim/error helper.

Explicitly *not* in the target for now: a channel-neutral delivery-address table, a runtime-level neutral event stream for multi-channel streaming, multi-provider fallback, and audit tamper-evidence — all of these are speculative until a concrete second consumer exists, and the spec already records sound reasoning for deferring most of them.

## 7. Concrete refactoring plan

**Stage 1 — small, high-value, do before Increment 5 starts.** All five are contained, none changes behavior the owner can see:

1. Tool policy class on `ToolDefinition` + gate consumes it + pass the canonical action into `execute` (Risk 3) — touches `ToolContracts.swift`, `ToolPolicyGate.swift`, the three tools, `RunCommand`.
2. Real timeout abandonment in `executeWithTimeout` (reuse the `sendDraftBounded` pattern) and move `getaddrinfo` off the cooperative pool (Risk 1) — `ToolPolicyGate.swift`, `SSRFGuard.swift`.
3. `applyStop` cancels PENDING+RUNNING (Risk 4) — `RunStoreGRDB.fetchActiveRunId` → plural, `CommandStoreGRDB`, router `/stop` handler.
4. Fail-closed provenance/role decode (Risk 5) — `SessionMessageStoreGRDB`, `RetrieverGRDB`, comment or fix the `RunOrigin` fallback.
5. `MappedDatabase` wrapper replacing `any DatabaseWriter` in stores (Risk 6) — mechanical, 14 inits.

Plus the one-line input-token preflight guard (Risk 8). Do **not** touch: the session lane, the outbox design, the FSM reducer, the provider.

**Stage 2 — medium cleanup, ideally interleaved with Inc 5 planning.**

1. Split `MessageRouter` (CommandHandlers / ScheduleHandlers / ConfirmationResolver), extract the claim/error-mapping helper, split `PendingConfirmation` into command-confirmation vs tool-approval types, and move `armNextOccurrence`/`resumeNextOccurrence`/`nextFires` into an `OccurrencePolicy` domain type also consumed by `SchedulerService` (Risk 2).
2. Split `TelegramTransport` into intake + delivery protocols; delete or adopt `OutgoingReply` (Risk 10).
3. Add exchanges to `DegradedTurn` with a decided `HistoryHygiene` replay rule (Risk 7).
4. Move the `/schedule` parse onto the lane (or deadline-bound it) and give it a usage row + day-cap check (Risk 9).
5. Narrow streaming retry: re-attempt pre-stream 429/5xx rejections only, preserving the pinned no-double-issue tests (Risk 11).

Do **not** start: any second-channel schema work.

**Stage 3 — optional, longer-term platform items.**

1. The export/delete/retention increment (Risk 12) — this one is "optional" only in sequencing; it's a committed v1 requirement and should get a slot.
2. Outbox dead-letter cap (attempts column + skip-after-N) — the one realistic weeks-scale delivery failure mode found by Scenario 10.
3. Per-run prompt/workspace fingerprint + approval-resolution audit rows (Risk 13), seeding Inc 5's `policy_version`.
4. Origin-gated progress UX (Risk 14).
5. Only when a second channel is actually chosen: channel column on dedup/outbox tables, delivery-address abstraction, and the neutral turn-progress sink from Scenario 6's plan.

## 8. Final recommendation

**Three most important things to fix** (all before or with Increment 5): (1) make tool policy *declared on the tool contract* instead of a fail-open string set — it converts the architecture's one silent-bypass seam into the compile-error discipline the rest of the codebase already practices; (2) make the tool timeout real and move blocking DNS off the cooperative pool — the single-owner bot's availability currently hangs on the goodwill of any hostile URL the model fetches; (3) split `MessageRouter` and relocate its scheduling math — not for aesthetics, but because Inc 5's callback approvals land in its most invariant-dense region and every invariant there is currently enforced by comments.

**Three things not to over-engineer:** (1) multi-channel infrastructure — do the cheap transport-protocol split and stop; no channel columns, no address abstraction, no neutral streaming event bus until a second channel is actually chosen, or you'll design the wrong abstraction against zero real consumers; (2) the provider layer — the OpenAI-shaped internal model is a documented, verified-cheap bet; don't build a provider-neutral message model or multi-provider fallback speculatively; (3) audit forensics — a per-run content fingerprint is enough; tamper-evident chains and prompt-version registries are enterprise theater for a single-owner daemon whose workspace can simply live in git.

**Overall verdict:** architecturally healthy — comfortably able to survive 12–24 months of serious personal use. The dependency structure, persistence discipline, security-as-types approach, and recovery story are all real and verified, not aspirational; the scheduler increment proved the core absorbs new capabilities the way the design intends. The risk register is dominated by convention-where-structure-belongs gaps and one oversized file, all fixable in days-not-weeks, and 5 of 10 stress scenarios pass clean with zero "poor" verdicts.

**What to analyze next:** the Increment 5 suspend/resume design — it's the largest planned change to the runtime (converting `runTurn` from run-to-completion to durable checkpoint/resume, new fused suspend-commit, `RunStoreGRDB` active-state filters, the `HistoryHygiene` exemption for suspended exchanges), and Scenario 8 identified the exact seams it will stress. A focused design review of that state machine *before* implementation — including how `/stop`, `/new`, boot reconciliation, and expiry interact with `AWAITING_APPROVAL` — would pay for itself.

---

## Appendix: stress-test scenario verdicts

| # | Scenario | Verdict |
|---|---|---|
| 1 | Second gateway (CLI/web) beside Telegram | awkward |
| 2 | Replace the LLM provider (native Anthropic adapter) | clean |
| 3 | New tool requiring user confirmation (pre-Inc5) | clean |
| 4 | Background scheduled task initiating agent work | clean |
| 5 | New memory backend / retrieval strategy | awkward |
| 6 | Streaming one turn to multiple UI channels | awkward |
| 7 | New domain module without touching the core runtime | awkward |
| 8 | Permission model for dangerous tools (Inc 5 approval FSM) | awkward |
| 9 | Structured audit logs for every tool call and decision | clean |
| 10 | Weeks-long uptime + clean crash recovery | clean |

No scenario rated "poor." The dominant cost in every "awkward" verdict is either `MessageRouter` (Scenarios 7, 8) or the outbound/streaming channel shape (Scenarios 1, 6); Scenario 5's cost is the synchronous `Retriever` seam plus the already-documented sqlite-vec toolchain risk.
