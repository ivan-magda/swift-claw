# swift-claw — Architecture Review

| | |
|---|---|
| **Status** | Point-in-time architecture review (code at commit `6f3fd98`, post `runtime-and-transport-hardening`) |
| **Date** | 2026-07-08 |
| **Scope** | Whole-repo system-design review: module boundaries, channel abstraction, runtime design, persistence, extensibility, personal-agent practices, concurrency — plus the areas the 2026-07-06 review under-covered: CI, deployment/backup/restore, dependency management, test architecture |
| **Method** | Single-reviewer deep pass building on [architecture-review-2026-07-06.md](./architecture-review-2026-07-06.md): every Stage 1/2 fix from that register re-verified against current source; two scoped read-only sweeps (import-graph/coupling audit; test-architecture + workspace/context mapping); the full suite executed during review (**804 tests in 133 suites, all passing**); every claim traced to current source |

**TL;DR:** The two top code risks from July 6 (fail-open tool classification, advisory timeouts) are genuinely fixed, along with the rest of that register's Stage 1 and Stage 2 — verified in source, not taken from the progress notes. Nothing of that severity remains in the code. What remains clusters in the **operational shell around the daemon** — CI runs no tests, there is no backup/restore, graceful shutdown behaves like a crash for in-flight turns, the owner's phone has no health surface — plus committed-but-unbuilt product surface (export/delete/retention) and a normative spec that has started to trail the implementation it governs. All of it is days-not-weeks work, and none of it requires touching the runtime.

> **Prior-review verification.** This review did not take [architecture-review-2026-07-06.md](./architecture-review-2026-07-06.md) on faith: each claimed fix was verified against current source (all eleven hold — §2 item 4). This review focuses on what is still standing, what the fixes introduced, and the previously under-covered areas.

---

## 1. Architecture map

### 1.1 The system as built

The package is a **layered DAG with a dependency-free kernel**, and the compiler enforces it. `Package.swift` declares ten targets: `ClawCore` (imports only Foundation — all domain value types, the error taxonomy, and *every* cross-module protocol), six leaf modules that each pair ClawCore with one vendor dependency (`ClawData`/GRDB, `ClawTelegram`/AsyncHTTPClient, `ClawLLM`, `ClawTools`, `ClawWorkspace`/Yams, `ClawSecrets`/swift-crypto), `ClawAgent` (the turn loop), `ClawGateway` (routing + services), and the executable `clawd`. Crucially, **ClawGateway does not link ClawTelegram, ClawLLM, ClawData, or ClawTools** — it reaches all of them through ClawCore protocols, and the only module that ever sees a concrete implementation is the composition root in `Sources/clawd/Subcommands/RunCommand.swift`. The import audit confirmed zero violations across all 117 source files.

**Where Telegram enters:** `TelegramPollerService` long-polls through the `ChannelIntake` protocol and hands each wire-agnostic `RawUpdate` (defined in `ClawCore/Domain/Bot/IncomingMessage.swift` — the Telegram JSON model never leaves `ClawTelegram`) to `MessageRouter`. The router (235 lines post-split) normalizes, applies default-deny access control, parses the command, and delegates to family handlers: `CommandHandlers`, `ScheduleHandlers`, `ConfirmationResolver`, or `TurnDispatch`. The offset cursor advances **last**, only after durable handling — exactly as spec §6.1 requires.

**Where the runtime starts and ends:** `TurnDispatch` claims-and-persists the inbound message in one fused transaction and enqueues onto a per-session lane (`SessionActor` — a 36-line stored-Task chain that correctly implements "actors don't serialize across await"). The lane calls `TurnRunner` (durable PENDING→RUNNING pickup, context snapshot, day-total reads), which calls `AgentRuntime.runTurn` — a bounded multi-round-trip loop with per-round-trip budget preflight (input tokens, per-run USD, day caps), streaming/typing sub-runtimes, and gated tool dispatch through the `ToolDispatching` protocol. It ends back in `TurnRunner.commit`: assistant message + run-state flip + usage + outbox chunks in one transaction, then a poke to `OutboxDispatcher` for at-least-once delivery.

**Where persistence is accessed:** exclusively through fourteen use-case-shaped store protocols in `ClawCore/Persistence/Stores.swift`, implemented in `ClawData` over a `MappedDatabase` wrapper that *structurally* prevents raw GRDB access — every SQLite failure routes through `ClawDatabase.classifyError` into domain-typed `StoreError`. Migrations v1–v7 in `ClawData/Database/ClawDatabase.swift`.

**Where tools are registered and executed:** literal array construction in `RunCommand.makeToolDispatcher` → `ToolRegistry` → `GatedToolDispatcher` → `ToolPolicyGate` (arg-guard tiers, trifecta check, approval keying on the declared `ToolEgressClass`) → per-tool `execute` under a first-finisher-wins timeout that abandons a wedged tool. One audit row per dispatch.

**The second work initiator:** `SchedulerService` ticks every 60 s, claims due jobs via a fused compare-and-advance in the store, and produces the *same* durable artifact as an inbound message (session + trigger message + PENDING run stamped with `origin`), reusing the same lane, TurnRunner, and outbox.

### 1.2 Coverage inventory

| Repository area | Contents | Covered? → maps to |
|---|---|---|
| `Sources/` — 10 targets, 117 files | kernel, data, agent, gateway, telegram, llm, tools, secrets, workspace, exe | Yes → focus areas 1–9 |
| `Tests/` — 9 targets, 133 suites, 804 tests | unit + integration + SC3/SC7 acceptance harnesses | Yes → §4 tests |
| `.github/workflows/` | one workflow: `lint.yml` (swift-format + SwiftLint only) | Yes → §4 CI, **Risk 1** |
| `deploy/` | launchd plist, systemd unit, `run-clawd.sh`, `README.md` | Yes → §4 deployment, **Risks 3, 6** |
| `scripts/` | `lint.sh`, `update-prices.sh` | Yes → CI/tooling |
| `docs/` | `ARCHITECTURE.md` (normative), `PRD.md`, `TESTING.md`, `LOCAL_DEV.md`, `research/`, `superpowers/` (plans/reviews/specs) | Yes → **Risk 6** (spec drift); process artifacts noted, not audited |
| Dependency management | `Package.swift` `from:` ranges + committed `Package.resolved`; 8 deps, all SSWG/Apple/GRDB-tier; no update automation; no release tags | Yes → §4 deployment/CI verdict |
| `docs/alt-solutions/`, `docs/teleclaw-prompt.md`, `.idea/`, `.superpowers/` | historical design alternatives, IDE state | **Excluded** — no bearing on the shipped architecture |

---

## 2. Strong parts of the current design

These are verified, not aspirational, and should be preserved.

1. **The module DAG is real and compiler-enforced.** `import GRDB` appears only in ClawData; the Telegram JSON model only in ClawTelegram; ClawAgent never imports ClawTools (the `ToolDispatching` protocol inverts that edge); environment access exists only in `clawd` and the config layer. The compile graph *is* the architecture diagram.

2. **The persistence seam is the strongest layer, in both directions.** Protocols are use-case-shaped fused transactions (`applyStop`, `applyRemember`, `claimAndFire` — atomicity lives in the *interface*); `MappedDatabase` makes the raw-error leak structurally impossible; migrations are versioned and additive (v7's table rebuild is the correct SQLite idiom for a column-nullability change); enum decodes fail closed.

3. **Security policy rides types, not prose — and the last review's one exception was fixed.** `ToolEgressClass` (`ClawCore/Domain/Tools/ToolContracts.swift`) has no default, so an unclassified tool cannot compile; the gate consumes the declaration and hands the resolved canonical target into `execute` (no re-derivation TOCTOU); `ToolDispatchContext.nonInteractive` has no default; a declared arbitrary-destination tool that resolves no target fails **closed** (`ToolPolicyGate.resolveAction`); the untrusted fence renders in exactly one place with a per-turn nonce.

4. **The July-6 register is genuinely closed, not marked closed.** Each fix verified in source: the tool timeout now abandons the loser via an `AsyncStream` first-finisher (`GatedToolDispatcher.executeWithTimeout`, `ToolPolicyGate.swift:244-277`); `/stop` cancels PENDING+RUNNING (`StopCommandResult.cancelledRunIds`); provenance/role decode throws; exchanges persist on degraded and budget-stopped commits (`DegradedTurn.exchanges`); the mid-run input-token preflight exists (`AgentRuntime.swift:168`); the `/schedule` parse is budget-gated, deadline-bounded, and debited via a run-less usage row (`ScheduleDraftParser` + migration v7); pre-stream 429/5xx rejections fall back to the retrying blocking path (`ProviderError.rejected`, `AgentRuntime.swift:501`); the transport is split into `ChannelIntake` + `MessageDelivery` and the dead `OutgoingReply` is deleted.

5. **The router split produced real boundaries.** `MessageRouter` is now a dispatcher over `CommandHandlers` / `ScheduleHandlers` / `ConfirmationResolver` / `TurnDispatch`, with a typed `throws(RoutingHalt)` unwinding path so the two-tier store-error contract is spelled once, and `PendingConfirmation` split so each resolver switch is exhaustive over only the cases it can legally see.

6. **Recovery and idempotency are implemented and tested.** Offset-advance-last, synchronous dedup claim, deterministic outbox keys, boot reconciliation sweeping orphans to FAILED with owner notices (including the config-derived heartbeat target), and the scheduler's single atomic CAS overlap guard. The SC3/SC7 acceptance harnesses drive the *real* router/runner/runtime/stores over scripted provider/HTTP/DNS — restart scenarios re-open the same database file.

7. **Spend discipline is crash-safe and layered.** Intermediate usage rows are written *before* the next provider call and a usage-write failure halts spending (`.accountingFailed`); estimated debits are floored, never a silent $0; the offline token ceiling backstops the USD caps; the proactive pool has its own cap and owner notification.

8. **The test suite matches its own normative doc.** `TESTING.md` prescribes real GRDB for managed dependencies, scripted doubles only at unmanaged seams, gate-based synchronization, and constants-not-literals — and the harnesses and doubles actually do this. 804 tests pass in ~1 s of test time.

9. **Right-sized concurrency.** One injected-clock/injected-sleep convention across the scheduler, runtimes, and parser; unstructured tasks appear only where task-group semantics would be wrong (tool timeout, draft sends), each with a documented reason and a hard bound; SSE accumulation is byte-capped.

---

## 3. Highest-priority architectural risks

Nothing of July-6 severity remains in the code. What remains clusters in the **operational shell around the daemon**, plus committed-but-unbuilt product surface. This section is the single home for every finding; later sections cite risk numbers.

### Risk 1: CI runs no build and no tests — the suite exists only on one machine

Severity: High · Confidence: High

Evidence:

* `.github/workflows/lint.yml` is the **only** workflow, and it runs swift-format and SwiftLint only.
* 804 tests in 133 suites pass locally (executed during this review), including the SC3/SC7 acceptance suites that encode the security invariants — none of this gates a merge.
* The architecture's own quality story leans on it: every increment's "Done when" is an automated acceptance test (ARCHITECTURE §20), and CLAUDE.md's "CI enforces it" is true only of lint.

Why it matters: This codebase's discipline is its tests — the fencing, exfil-gate, offset-ordering, and FSM invariants are all *proven* by suites that no automation runs. Development here is heavily agent-driven (the `docs/superpowers/` plan/review pipeline), which raises, not lowers, the value of a machine gate: an agent-authored PR that passes lint but breaks `applyStop` merges clean today.

Future change that would become painful: any of the next increments. Inc 5 (approvals FSM, write tools) is precisely the change where a silently broken acceptance suite is most expensive — and the Inc 6 "Linux CI gate" the spec plans is a *portability* gate, not a substitute for a test gate available today.

Recommended fix: one additional job — macOS runner, `swift build && swift test` — triggered on PRs and pushes to main. Add the Linux container build later as the Inc 6 gate the spec already plans.

Tradeoffs: macOS CI minutes cost real money and the suite's loopback-HTTP tests need the `.serialized` discipline they already have. That is the entire cost; there is no design cost.

### Risk 2: Export / delete / retention is a committed v1 feature with zero code and no increment slot

Severity: High (for a privacy-sensitive personal agent) · Confidence: High

Evidence:

* `PRD.md` FR-S4 *(v1)* (PRD.md:127), SC4 acceptance (PRD.md:230), NFR-Privacy, and the §5 v1 milestone table all commit to "owner can export and delete conversation history; deletion rebuilds FTS rows; retention bounds the archive."
* The only DELETE statements in the entire data layer target `memory_items` (grep-verified). `messages` (including everything `web_fetch` ever ingested), `audit_events`, `provider_usage`, `outbound_deliveries`, and `processed_updates` grow without bound; ARCHITECTURE §20 gives this work no increment (0–6 or Later).

Why it matters: This was Risk 12 in the July-6 review and is the only register item from it that remains fully open. It is not a missing feature so much as a missing *proof*: the FTS "single delete source of truth" contract exists in migration tests, but no end-to-end owner-facing deletion has ever exercised it. Every month of use raises the cost — more interlinked rows, more consumers allowed to assume append-only.

Future change that would become painful: retrofitting "forget this conversation" after 12+ months of runs/messages/deliveries/audit cross-references, or after Inc 5 adds approvals rows that reference runs.

Recommended fix: slot the small increment the previous review already outlined — `clawd export`, one fused-transaction session-delete store method with FTS cleanup, and a config-driven retention sweep as one more `Service`. Every discipline it needs (fused writes, additive migration, Service pattern) already exists.

Tradeoffs: audit-vs-history precedence must be decided (audit rows outliving their messages weakens forensics; deleting them weakens the audit) — one deliberate decision, documented in the spec.

### Risk 3: No backup or restore story for the state root

Severity: Medium · Confidence: High

Evidence:

* `LOCAL_DEV.md` says "`secret.key` — keep out of backups", presupposing backups that no document or command defines; `deploy/README.md` covers install and supervision only.
* The state root is the agent's entire accumulated value: `claw.sqlite` (memory items, message archive, scheduled jobs, audit) in WAL mode, plus `workspace/` (SOUL/AGENTS/USER/MEMORY.md), which is not under version control by default.
* A file copy of a live WAL database without its `-wal` sidecar can produce a stale or torn snapshot; nothing in the repo performs a checkpointed or `VACUUM INTO` copy.

Why it matters: for a personal agent, the database *is* the relationship. Everything else in the system is rebuildable from source; this one directory is not. The honest mitigations that exist by accident (APFS/Time Machine snapshots are crash-consistent, so a TM restore behaves like a crash image SQLite can recover) are undocumented luck, not a design.

Future change that would become painful: none — this is a loss-event risk, not a refactoring risk. The painful event is a dead disk or a botched migration during Inc 5, discovered without a restore path.

Recommended fix: a `clawd backup <dest>` subcommand (SQLite online-backup API or `VACUUM INTO`, plus a workspace copy, explicitly excluding `secret.key` per the existing guidance), a one-paragraph restore runbook in deploy/README, and a recommendation to keep `workspace/` in a private git repo.

Tradeoffs: essentially none; a scheduled-backup Service is optional later and should *not* be built until the manual path exists.

### Risk 4: Graceful shutdown abandons in-flight turns — the spec's shutdown choreography is not implemented

Severity: Medium · Confidence: High

Evidence:

* ARCHITECTURE §4 pins the contract: "stop intake → let the in-flight turn finish (bounded) → drain the outbox → … → exit."
* Turns run as unstructured tasks stored in `SessionActor`; `TurnEnqueuer.enqueue` is fire-and-forget; nothing joins them. `Daemon` awaits only the `ServiceGroup`; `SessionLaneRegistry` has no drain/quiesce API (grep-verified); `RunCommand.run` exits as soon as `daemon.run()` returns.
* On SIGTERM the poller and dispatcher cancel promptly (correct), then the process exits, killing any turn mid-flight; the run is left RUNNING and boot reconciliation sweeps it to FAILED with an owner "unfinished run" notice.

Why it matters: recovery is crash-*consistent* (fused commits mean no corruption, and this is tested), but every deliberate restart during an active turn — a deploy, an upgrade, a laptop shutdown — manufactures a failed run, a lost reply, and a degradation DM. For a daemon that restarts on every binary update, "graceful shutdown behaves exactly like a crash" is a real UX and spend cost, and it contradicts the normative spec.

Future change that would become painful: Inc 5's suspend/resume work. `AWAITING_APPROVAL` adds a durable mid-turn state; building it on a shutdown path that never waits for turns means designing resume semantics against an environment where "shutdown" and "crash" are indistinguishable — one more degree of freedom in the hardest planned change.

Recommended fix: give `SessionLaneRegistry` a bounded `quiesce(deadline:)` (await each lane's `lastEnqueuedTask` with a timeout), and run it in the shutdown path after intake stops — either as the last service's shutdown hook or in `Daemon.run` between group teardown and return, followed by one final outbox drain. Alternatively, if crash-consistent shutdown is the *intended* contract, amend §4 to say so and delete the promise.

Tradeoffs: shutdown can now take up to the turn deadline (bound it well below launchd/systemd's stop timeout, e.g. 20 s of the 30 s budget); a small new registry API; ordering care so quiesce runs after the poller stops.

### Risk 5: The owner's primary surface has no health or cost commands, despite a v1 commitment

Severity: Medium · Confidence: High

Evidence:

* PRD FR-O1 *(v1)* (PRD.md:175): menu includes `/status` and `/cost`; FR-O2 *(v1)* (PRD.md:176): status exposed "as a clawd CLI subcommand **and** a Telegram `/status` command." ARCHITECTURE §16 repeats it.
* `Command.parse` has no status/cost cases (grep-verified); the boot-time menu registration in `RunCommand` lists eleven commands, neither among them. Doctor exists only as a host CLI.
* Every underlying query already exists and is tested: `RunStore.runsHealth`, `UsageStore.todayTokensAndCost` + `costSourceMix`, `ScheduledJobStore.schedulerState`.

Why it matters: this is a phone-first agent; when it degrades (budget tripped, provider down, scheduler misfiring), the owner's only diagnostic path is to shell into the host. The audit/health machinery was built precisely to answer "why did it do that" — it is currently unreachable from the surface where the question arises.

Future change that would become painful: none structurally — this is committed product surface aging out of memory. The router split made it cheap; the longer it waits, the more it looks deliberately descoped without a recorded decision.

Recommended fix: a `/status` and `/cost` arm in `CommandHandlers` rendering the same rows doctor already assembles (reuse `DoctorReport`'s formatting seams). Purely additive.

Tradeoffs: none real; keep replies to the existing metadata-only discipline so no prompt content leaks into a health reply.

### Risk 6: The normative spec has drifted from deliberate implementation decisions

Severity: Medium · Confidence: High

Evidence (each checked against source):

* §15: "sops + age" — implemented instead as a homegrown AES-GCM envelope (`secrets.enc` + `secret.key`, `SecretStoreResolver` — fail-closed and well-tested, but not what the spec says).
* §15: "invalid config … moved aside as `config.toml.rejected.<timestamp>`" — no config file exists at all; config is env-only (`AppConfig`).
* §16: "`/status`, `/cost` … Telegram commands" — absent (Risk 5).
* §18: "pin GRDB; vendor SQLite amalgamation (FTS5 + sqlite-vec init compiled in)" — `Package.swift` uses `from:` ranges and stock GRDB SQLite; no amalgamation exists (fine until sqlite-vec, but the spec states it in the present tense).

Why it matters: this repo's own authority rule (CLAUDE.md: ARCHITECTURE.md "wins" over everything) is what makes drift expensive. The development model is spec-driven and agent-executed — the July-6 review already caught one bug-shaped consequence (the `/schedule` parse citing a plan doc against the spec). Every stale clause is an instruction a future agent will faithfully implement or "restore."

Future change that would become painful: Inc 5 planning, which will be written against §11–§13 assuming the §15/§16 baseline is real.

Recommended fix: a half-day reconciliation pass: update §15 (secrets as built, env-only config), §16 (commands as built or explicitly re-committed), §18 (GRDB pinning reality), and mark planned-vs-implemented explicitly where the spec describes the future in the present tense.

Tradeoffs: none — documentation only. The discipline cost is adopting "spec PR rides the implementation PR" going forward.

### Risk 7: The approval fabric's audit vocabulary has holes just before it becomes durable

Severity: Low · Confidence: High

Evidence: arming a grant leaves no audit row — `ConfirmationResolver.resolve`'s tool-approval branch clears the slot and dispatches the turn with the grant, writing nothing to `audit_events`; `AuditAction` has no approval-requested/granted/denied cases and still carries the dead `messageIn` case (declaration only, grep-verified); no per-run fingerprint of the policy prompt + workspace files exists, so Inc 5's planned `policy_version` re-validation has nothing to bind to. (The owner's "yes" *is* durable as a session message, which is why this is Low.)

Why it matters / future pain: Inc 5's durable approval FSM will need exactly these rows; adding them now means the ephemeral and durable systems share one vocabulary, and "which instructions was this run operating under" becomes answerable.

Recommended fix: two or three `AuditAction` cases + one `appendAudit` in the resolver and one at gate-park time; a `ContentHash.fnv1a` fingerprint over policy prompt + loaded workspace files recorded per run; delete or wire `messageIn`.

Tradeoffs: none.

### Risk 8: One permanently-failing outbox row stalls all later deliveries

Severity: Low · Confidence: High

Evidence: `OutboxDispatcher.drainOnce` deliberately stops at the first failed send to preserve ordering, and the code comment is honest (`OutboxDispatcher.swift:94-101`): "a row that permanently fails … stalls itself and every later row on every drain — no attempt cap in Inc 1; a dead-letter path is a later increment."

Why it matters: at the weeks-uptime horizon this is the one realistic way the bot goes silent while healthy — e.g. a payload Telegram rejects deterministically (both rich and plain paths) blocks everything behind it until manual DB surgery.

Recommended fix: an `attempts` column + skip-after-N (park as FAILED, surface in doctor + a one-time owner DM via a fresh row).

Tradeoffs: a skipped row breaks strict per-run ordering for the dead message only — the right trade for a single-owner DM.

### Risk 9: Progress UX ignores run origin — scheduled/heartbeat runs visibly type and stream drafts

Severity: Low · Confidence: High

Evidence: `AgentRuntime` sends typing unconditionally between round-trips (`AgentRuntime.swift:272`) and streams full-content draft frames regardless of `origin`; a heartbeat ack is suppressed only at commit (`TurnRunner` + `HeartbeatAck`), *after* its draft frames were already visible. `origin` currently gates only budget.

Why it matters: today cosmetic (a typing bubble and a flash of draft text during a quiet heartbeat); architecturally it is the seed of "delivery-suppression semantics live in two layers that can disagree."

Recommended fix: skip typing/draft sinks when `origin != .interactive` inside `roundTrip` — origin is already a parameter.

Tradeoffs: none.

---

## 4. Module boundary and extensibility review

**Gateway / Telegram layer.** Boundary: clear — inbound is a genuine anti-corruption layer (`RawUpdate → IncomingMessage.normalize`, poller ignorant of commands), and outbound consumers now depend on `MessageDelivery`, never the Telegram composite. Extensibility: new command family **clean** post-split (own handler file + compiler-forced `Command` case); new *gateway* **awkward** — dedup/cursor/outbox tables carry no channel dimension, the allowlist is Telegram-numeric, and `TurnDispatch` mints `tg:dm:` keys (deliberate v1 scoping; the namespaced `SessionKey` grammar is the right seam to grow from).

**Agent runtime.** Boundary: clear — TurnRunner (durable edges) vs AgentRuntime (loop) is a real division, and every failure resolves through one choke point. The one intentional blur: channel progress UX (`chatId`, typing, draft cadence) threads through the loop (Risk 9). Extensibility: a new initiator kind is **clean** (proven by heartbeat: one fused store method + one `RunOrigin` case); Inc 5's suspend/resume is the known big change and deserves its own design pass (Risk 4 interacts with it).

**Domain modules (ClawCore/Domain).** Boundary: clear — pure, Foundation-only, I/O-free; Telegram fingerprints (`tg:dm:`, `ReplySplitter` caps, `Command.parse(botUsername:)`) are named and tolerated. The `OccurrencePolicy`/`OccurrenceCalculator` move fixed the one real domain-logic leak. Extensibility: **clean**; new domain = new folder + store protocol + handler family (scheduling precedent: ~99% additive).

**SQL / persistence.** Boundary: clear; the strongest layer (§2 items 2, 4). Extensibility: new store **clean** — protocol + GRDB impl + additive migration + one `ClawStores` field; the seam is structurally protected now. Remaining debt is product-level, not structural: no delete/retention paths (Risk 2).

**Tools.** Boundary: clear — registry/gate/dispatcher separation with the gate as sole enforcement point; classification now rides the contract. Extensibility: new tool **clean** (one struct + one array line; egress class is compiler-forced; approval copy is compiler-forced via `ApprovalReason` exhaustiveness); a *write* tool is **awkward by plan** — it needs the Inc 5 risk-tier/approval FSM, and the timeout-abandonment contract explicitly flags that write tools must tolerate post-timeout side effects.

**Memory / recall.** Boundary: clear — `MemoryStore`/`Retriever` are narrow and domain-typed; recall is injection-safe by construction; fail-closed decode. Extensibility: swapping ranking/BM25 strategy **clean** (`RecallCutoff`, `MemoryRanker` are single-construction-site seams); an embedding backend **awkward** — `Retriever` is synchronous (so `ContextBuilder.assemble` and one TurnRunner call site go async), there's no `EmbeddingProviding` protocol or indexer service, and sqlite-vec carries the documented §7.6 toolchain risk.

**LLM provider integration.** Boundary: clear — vendor wire shapes private to ClawLLM; consumers hold `any LLMProvider` over neutral types; the retry/rejected/terminal taxonomy is coherent end-to-end. Extensibility: new provider **clean** — new module conforming to `LLMProvider`, one composition-root discriminator, pricing rows; the OpenAI-shaped internal model is a documented cheap bet (the `finishReason == "length"` string match in the loop is the one wart to normalize when a second provider lands).

**Configuration / secrets.** Boundary: clear — typed fail-closed `AppConfig` loaded once; env access confined to the root; exact-value redaction installed before the first logger; the secret resolver never silently falls back to plaintext. One honest note: `secret.key` sits beside `secrets.enc` in the state root, so the envelope defends against backup/log leakage, not same-host compromise — appropriate for this threat model, but ARCHITECTURE §15 describes a different mechanism (Risk 6). Extensibility: new config knob / new secret **clean**.

**Logging / observability.** Boundary: clear — developer logs (metadata-only, run/session-correlated) vs the typed durable audit trail vs doctor are three distinct instruments. Extensibility: new audit event **clean** (one enum case); the gaps are enumerable and additive (Risks 5, 7).

**Tests.** Boundary: clear — TESTING.md is a real normative rubric and the suite follows it (real GRDB, scripted unmanaged seams, acceptance harnesses wiring production objects). Extensibility: new-feature tests **clean** — harness/double infrastructure is reusable; the ~28 `Task.sleep` sites are mostly injected-sleep plumbing and one bounded `pollUntil` helper, an acceptable tail. The suite's one systemic weakness is that nothing runs it automatically (Risk 1).

**Deployment / operations / CI / dependency management.** Boundary: blurred — this is the least-designed area of the system. launchd/systemd units exist with correct throttling semantics, distinct exit codes, and an honest README, but: CI is lint-only (Risk 1), there is no backup/restore (Risk 3), the deploy README stops at plaintext-env secrets and never mentions `clawd secrets seal` (the better path LOCAL_DEV documents), launchd logs go to unrotated `/tmp` files, there are no release tags, and the systemd unit is unvalidated until Inc 6 (planned). Dependencies themselves are healthy: eight well-chosen SSWG/Apple/GRDB-tier packages, resolved versions committed; no update automation exists, which is tolerable *only* once CI can catch a bad update (Risk 1 again). Extensibility: adding an ops capability (backup service, retention sweep) is **clean** mechanically — `Daemon` takes `[any Service]` — the gap is that none of it exists yet.

**Workspace (surfaced by inventory).** Boundary: clear — pure synchronous file I/O, outcome-typed loads (`present/overCap/missing/unreadable`, never throws, never silently truncates), consumed via `WorkspaceReading` by ContextBuilder and SchedulerService. Extensibility: new identity file **clean** (one `WorkspaceFile` case + one context row).

---

## 5. Recommended target architecture

The July-6 review said the current architecture is the right target, and after two days of hardening that is even more true. This review does not propose a different one; the kernel-of-protocols DAG, the composition root, the fused-transaction store seam, the lane, and the outbox should not change. What the system actually needs next is not another layer in `Sources/` — it is the **operational shell** brought up to the standard of the code:

```
        ┌─ OPERATIONAL SHELL (the gap) ─────────────────────────────┐
        │  CI: lint + swift test (macOS now, Linux at Inc 6)        │
        │  clawd backup/restore · export/delete/retention Service   │
        │  /status · /cost owner surface   ·  spec kept in sync     │
        └───────────────────────────────────────────────────────────┘
                                │ wraps
   clawd (composition root — the ONLY module seeing concrete types)
        │
   ClawGateway: poller · scheduler · outbox · router families · TurnRunner
        │                                (+ bounded lane quiesce on shutdown)
   ClawAgent (loop, sub-runtimes)   ClawTelegram/ClawLLM/ClawData/
        │                           ClawTools/ClawWorkspace/ClawSecrets
        └────────────┬─────────────  (vendor code behind ClawCore protocols)
                     ▼
   ClawCore — pure domain + ALL seams (unchanged):
     ChannelIntake + MessageDelivery · LLMProvider · Tool (+ egress class)
     ToolDispatching · 14 store protocols over MappedDatabase-backed impls
     RunFSM · budgets · error taxonomy · LabeledContext · SessionKey grammar
```

Dependency direction stays exactly as today: everything points at ClawCore; ClawCore points at nothing; only clawd sees implementations. The in-code deltas are deliberately small: the lane-quiesce hook (Risk 4), the approval audit cases + run fingerprint (Risk 7), the outbox attempt cap (Risk 8), origin-gated progress (Risk 9), and the retention/delete store methods (Risk 2).

Explicitly **not** in the target now, unchanged from the previous review and reaffirmed: no channel columns or delivery-address abstraction until a second channel is actually chosen; no neutral streaming event bus (the multi-channel streaming scenario stays awkward on purpose); no provider-neutral message model or multi-provider fallback; no audit tamper-evidence. All of these would be designed against zero real consumers.

## 6. Concrete refactoring plan

**Stage 1 — the operational floor (days, all independent, do before Inc 5).** Add the CI test job (Risk 1) — the single highest leverage-to-effort item in the repo; everything later leans on it. Add `clawd backup` plus a restore runbook and put the workspace under git (Risk 3). Add the `/status` and `/cost` handler family reusing doctor's queries (Risk 5). Run the spec reconciliation pass so ARCHITECTURE.md §15/§16/§18 describe the system as built (Risk 6). None of these touch the runtime, the lane, the stores, or the provider — do not refactor any of those while doing this.

**Stage 2 — pre-Inc-5 hardening (small code changes, sequenced with Inc 5 planning).** Implement the bounded lane quiesce and wire it into shutdown, or explicitly amend the spec to crash-consistent shutdown (Risk 4) — decide this *before* designing suspend/resume, because it changes what "restart during AWAITING_APPROVAL" means. Add the approval-audit cases, the grant-armed audit row, and the per-run prompt/workspace fingerprint that `policy_version` will bind to (Risk 7). Add the outbox attempts column and skip-after-N (Risk 8), and the one-line origin gate on typing/drafts (Risk 9). Do not start second-channel schema work, and do not build the durable approval FSM inside this stage — it deserves the dedicated design review the previous report recommended.

**Stage 3 — committed product debt and long-term items.** The export/delete/retention increment (Risk 2) — "optional" only in sequencing; it is a v1 commitment and should get a numbered slot like any other increment. After that, in whatever order need dictates: the Linux CI/portability gate (Inc 6 as planned), release tagging once binaries deploy to more than one machine, and — only when a second channel or an embedding backend is actually chosen — the channel columns and the async `Retriever` seam respectively.

**Out of scope deliberately:** the session lane, the outbox design, the FSM reducer, the provider layer, the context assembly pipeline, and the module graph itself. All were re-verified healthy this pass; changing them now would be motion without progress.

## 7. What this review did not cover

* **Read shallowly or not at all:** the interior of `ClawWorkspace`, `ClawTelegram`'s wire layer, `SSEParser`, the SSRF/exfil guard implementations, `ContextBuilder`'s fitting math, and most individual GRDB store files — structure, the July-6 review's per-file verification, targeted greps, and the passing suite stood in for line-by-line reads. The "fixes verified" claims are based on reading the fixed code itself, but the previous review's adversarial verification of, e.g., SSRF bypass cases or FTS trigger correctness was not re-run.
* **Not executed:** the daemon against real Telegram or a real LLM endpoint; the systemd unit (no Linux host); `clawd doctor`/`secrets seal` end-to-end; any load, soak, or DB-growth measurement. The weeks-uptime verdict is code-reading plus the suite, not observation.
* **Not evaluated:** prompt *quality* (SystemPrompt content, fence effectiveness against a live model), actual recall relevance/BM25 quality, Telegram rate-limit behavior under bursts, and the `docs/superpowers/` process pipeline's contents.
* **Scenarios outside the ten:** multi-owner/pairing, MCP integration, image/voice input, migration *rollback* (migrations are forward-only; v7's rebuild has no down path), and hostile-host threat models (the secrets envelope explicitly does not defend against same-host compromise).
* **Claims taken from the prior review without independent re-verification:** the "98.7% additive" scheduling-increment measurement and the 42-agent review's scenario traces, which were consistent with what was read this pass.

## 8. Final recommendation

**Three most important things to fix:** (1) **give CI a build-and-test job** — the architecture's quality story is its 804 tests, and today no machine runs them on a merge; (2) **slot the export/delete/retention increment and a backup path** — the two remaining gaps that a privacy-sensitive personal agent actually owes its owner, and the only July-6 register item still fully open; (3) **decide the shutdown contract before Inc 5** — either implement the bounded lane quiesce the spec promises or amend the spec, because suspend/resume should not be designed on ambiguous restart semantics.

**Three things not to over-engineer:** (1) multi-channel infrastructure — the intake/delivery split is done and is the right stopping point; no channel columns, no address table, no streaming event bus until a second channel exists; (2) the provider and memory seams — `LLMProvider` and `Retriever` are proven-cheap to extend when a concrete second implementation arrives; building `EmbeddingProviding` or provider-neutral message models now is speculation; (3) audit forensics — a fingerprint and three enum cases suffice; tamper-evident chains remain theater for a single-owner daemon whose workspace can live in git.

**Overall verdict: architecturally healthy — and measurably healthier than two days ago.** The dependency structure is compiler-enforced, the persistence and security seams are structural rather than conventional, recovery is real, and the July-6 register was closed with fixes that match their descriptions. What now separates this codebase from "comfortably survives 12–24 months" is not module boundaries — it is the operational shell: nothing gates merges, nothing backs up the data, committed owner-facing surface (export/delete, `/status`) is unbuilt, and the normative spec has started to trail the implementation it governs. All of it is days-not-weeks work, and none of it requires touching the runtime.

**What to analyze next:** the same thing the previous review concluded, now with more urgency since everything ahead of it is cleared — the **Increment 5 suspend/resume design**: how `runTurn` converts from run-to-completion to durable checkpoint/resume, the fused suspend-commit, and specifically how `/stop`, `/new`, boot reconciliation, expiry, *and shutdown quiesce* interact with `AWAITING_APPROVAL`. A focused design review of that state machine before implementation is the highest-value next engagement.

---

## Appendix: stress-test scenario verdicts

| # | Scenario | Verdict |
|---|---|---|
| 1 | Second gateway (CLI/web) beside Telegram | awkward (unchanged; intake/delivery split helps, schema/allowlist/progress sinks remain Telegram-shaped) |
| 2 | Replace the LLM provider | clean |
| 3 | New tool requiring user confirmation | clean (ephemeral single-slot; restart denies by design until Inc 5) |
| 4 | Background scheduled task initiating agent work | clean (proven by scheduler + heartbeat) |
| 5 | New memory backend / retrieval strategy | clean for ranking/BM25 swaps; awkward for embeddings (sync `Retriever`, §7.6 toolchain risk) |
| 6 | Streaming one turn to multiple UI channels | awkward (deliberately deferred; no neutral progress sink) |
| 7 | New domain module without touching the core runtime | clean post-split (small compiler-forced edits: `Command`, menu, help, `ClawStores`, migration, `AuditAction`) |
| 8 | Permission model for dangerous tools | awkward by plan (egress classes exist; risk tiers + durable FSM are the known Inc 5 change) |
| 9 | Structured audit logs for every tool call and decision | clean (gaps enumerable: Risk 7) |
| 10 | Weeks-long uptime + clean crash recovery | clean, two caveats (Risk 4 restart-as-crash, Risk 8 dead-letter stall; unbounded tables → Risk 2) |

No scenario rates "poor." The dominant cost in every "awkward" verdict is a deliberate, documented deferral (second channel, embeddings, Inc 5 FSM), not an accident of coupling.
