# swift-claw — Increment 0 implementation grounding (deep research)

| | |
|---|---|
| **Status** | Research report (verified) — feeds the Increment 0 plan |
| **Date** | 2026-06-15 |
| **Owner** | Ivan Magda |
| **Scope** | Increment 0 stack only: ServiceGroup daemon, thin Telegram `getUpdates` client, GRDB v7 schema/migrations/WAL, cross-process `flock` startup lock + supervision, Swift Testing |
| **Method** | Deep-research workflow: 5 angles → 23 sources fetched → 100 claims → 25 verified via 3-vote adversarial verification (2/3 refutes kills) → 23 confirmed, 2 refuted |
| **Related** | [`ARCHITECTURE.md`](../ARCHITECTURE.md) §3–§7, §15–§18, §20 · [`PRD.md`](../PRD.md) · prior research: [impl-grounding](./swift-claw-impl-grounding-2026-06-15.md), [best-practices](./swift-claw-best-practices-2026-06-15.md) |

> All version-specific claims are pinned to **mid-June 2026**. GRDB and swift-service-lifecycle are actively released — **re-pin versions at implementation time** (`Package.resolved` is the source of truth).

---

## What this means for Increment 0 (the actionable distillation)

1. **Offset advances LAST, and is the only ack.** There is no ack RPC. Advancing `offset = lastUpdateId + 1` confirms *every* update with a lower id. So persist the cursor only after durable processing; the synchronous `claimUpdate` dedup is what actually prevents double-processing on a mid-window crash (the cursor is an optimization to avoid re-fetching). This is exactly the §6.1 ordering — the research confirms it against the primary source.
2. **Always re-send `allowed_updates`.** Omitting it reuses the previous server-side setting (it does **not** reset). Send `["message","edited_message"]` on every `getUpdates` call in Inc 0.
3. **ServiceGroup is the daemon spine, but don't assume start/stop ordering.** Use `Service.run()` + `ServiceGroup(services:gracefulShutdownSignals:[.sigterm,.sigint]:...)`. The long-poll loop must observe graceful shutdown so SIGTERM ends the poll cleanly. Do **not** rely on guaranteed array-order start / reverse-order stop (that claim was refuted 0-3).
4. **GRDB: stores over `any DatabaseWriter`; WAL in prod, in-memory `DatabaseQueue` in tests.** Configure `prepareDatabase` for `busy_timeout` + `foreign_keys`; `foreignKeysEnabled` defaults true. GRDB 7 rolls back in-flight writes on Task cancellation — good for SIGTERM.
5. **FTS5 is a Linux-portability landmine, but not needed in Inc 0.** macOS system SQLite has FTS5; Linux generally does not, and GRDB's documented custom-build is **not** SPM-compatible. Inc 0 creates no FTS5 tables (recall is Inc 3), so defer; the Inc 6 Linux CI gate must vendor an amalgamation with `SQLITE_ENABLE_FTS5`.
6. **`flock(LOCK_EX|LOCK_NB)` on a held-open FD is the single-instance guard.** Keep the FD open for the daemon's life; the kernel releases the lock on exit (graceful, signal, or crash), giving automatic stale-lock cleanup.

---

## Verified findings (confidence + vote + source)

### Angle 1 — Telegram `getUpdates` durability & errors

**F1. Acknowledgment is implicit via offset advancement.** *(high, 3-0 — [core.telegram.org/bots/api](https://core.telegram.org/bots/api))*
Primary source verbatim: *"Identifier of the first update to be returned. Must be greater by one than the highest among the identifiers of previously received updates. … An update is considered confirmed as soon as `getUpdates` is called with an `offset` higher than its `update_id`."* There is no separate ack RPC — advancing the offset **is** the ack. Persist the offset only after durable processing to avoid both duplicate delivery and dropped updates across restart.

**F2. `allowed_updates` persists if omitted; `[]` excludes reaction/member types.** *(high, 3-0 — [core.telegram.org/bots/api](https://core.telegram.org/bots/api))*
Verbatim: *"A JSON-serialized list of the update types you want your bot to receive. … Specify an empty list to receive all update types except `chat_member`, `message_reaction`, and `message_reaction_count` (default). If not specified, the previous setting will be used."* → **Re-send `allowed_updates` on every call** to keep the filter stable.

### Angle 2 — swift-service-lifecycle ServiceGroup (v2.11.0, 2026-03-31)

**F3. `Service` requires exactly one method.** *(high, 3-0 — [swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle), [Service.swift](https://github.com/swift-server/swift-service-lifecycle/blob/main/Sources/ServiceLifecycle/Service.swift))*
`public protocol Service: Sendable { func run() async throws }`. Conformers may be struct, class, or actor. This is the modern API that supersedes the deprecated 1.x `Lifecycle`. A long-poll intake service is a type whose `run()` loops until cancelled.

**F4. `ServiceGroup` init + signal wiring.** *(high, 3-0 — [ServiceGroup.swift](https://github.com/swift-server/swift-service-lifecycle/blob/main/Sources/ServiceLifecycle/ServiceGroup.swift))*
`public actor ServiceGroup: Sendable, Service`. Init: `init(services: [any Service], gracefulShutdownSignals: [UnixSignal] = [], cancellationSignals: [UnixSignal] = [], logger: Logger)` (not deprecated) or `init(configuration: ServiceGroupConfiguration)`. Spawns one child task per service (`try await service.run()`), driven by its own `run()`. `gracefulShutdownSignals: [.sigterm]` selects graceful signals; `cancellationSignals` is separate (immediate cancel). README example: `ServiceGroup(services: [s1, s2], gracefulShutdownSignals: [.sigterm], logger: logger)`.

**F5. Signal listeners trigger graceful shutdown — but ordering is NOT guaranteed.** *(high, 3-0)*
The group installs `UnixSignalsSequence` listeners for the configured signals and triggers graceful shutdown on each service. ⚠️ The claim that startup is strictly array-ordered and shutdown strictly reverse-ordered (each child awaited before the next) was **REFUTED (0-3)**. Do not rely on ordered start/stop semantics.

**F6. `TerminationBehavior` governs what happens when a service's `run()` returns/throws.** *(high, 3-0 — [ServiceGroupConfiguration.swift](https://github.com/swift-server/swift-service-lifecycle/blob/main/Sources/ServiceLifecycle/ServiceGroupConfiguration.swift))*
`successTerminationBehavior` / `failureTerminationBehavior`, each defaulting to `.cancelGroup` (others: `.gracefullyShutdownGroup`, `.ignore`). So if the long-poll service ever returns, the default brings down the whole group. `TerminationBehavior` is a struct with static-let factory values, consumed like enum cases.

**F7. Graceful-shutdown primitives for a cancellation-aware loop.** *(high, 3-0 — [GracefulShutdown.swift](https://github.com/swift-server/swift-service-lifecycle/blob/main/Sources/ServiceLifecycle/GracefulShutdown.swift))*
`gracefulShutdown() async throws`; `cancelWhenGracefulShutdown<T: Sendable>(_:) async rethrows -> T`; `withGracefulShutdownHandler(isolation:operation:onGracefulShutdown:)`; `withTaskCancellationOrGracefulShutdownHandler(isolation:operation:onCancelOrGracefulShutdown:)` (added v2.4.1). Older overloads lacking `isolation:` are deprecated. The intake loop should observe these so SIGTERM ends the long poll instead of blocking.

### Angle 3 — GRDB.swift v7 (7.11.0, 2026-06-01)

**F8. Version + toolchain floor.** *(high, 3-0 — [README](https://raw.githubusercontent.com/groue/GRDB.swift/master/README.md), [migration guide](https://github.com/groue/GRDB.swift/blob/master/Documentation/GRDB7MigrationGuide.md))*
GRDB 7.11.0 (2026-06-01; preceded by 7.10.0 2026-02-15, 7.9.0 2025-12-13). Requires **Swift 6.1+ / Xcode 16.3+**, SQLite 3.20.0+, iOS 13 / macOS 10.15 minimum.

**F9. Two connection types.** *(high, 3-0 — README)*
`DatabaseQueue` (simpler; supports **in-memory** — ideal for unit tests) and `DatabasePool` (concurrent; opens **WAL by default** unless read-only). README: *"If you are not sure, choose [DatabaseQueue]. You will always be able to switch to [DatabasePool] later."* WAL is unavailable for in-memory/temporary DBs.

**F10. `Configuration.prepareDatabase` is the connection-setup hook.** *(high, 3-0 — [Configuration.swift](https://github.com/groue/GRDB.swift/blob/master/GRDB/Core/Configuration.swift))*
`public mutating func prepareDatabase(_ setup: @escaping @Sendable (Database) throws -> Void)` — *"run whenever an SQLite connection is opened."* Daemon-critical settings: `foreignKeysEnabled` (default `true` → `PRAGMA foreign_keys = ON`), `busyMode` (default `.immediateError`; use `.timeout(TimeInterval)` → SQLite `busy_timeout`), `journalMode` (`.default` → WAL for `DatabasePool`). ⚠️ There is **no** property literally named `busy_timeout` (it's `busyMode`); the README body does not contain a literal `busy_timeout`/`foreignKeysEnabled` code block, but the `Configuration` API fully supports them (verified in source).

**F11. GRDB 7 respects Task cancellation.** *(high, 3-0 — migration guide)*
If the wrapping Task is cancelled, reads/writes throw `CancellationError`, pending transactions roll back, DB left unmodified (*"The only SQL statement that can execute in a cancelled database access is `ROLLBACK`."*). Differs from GRDB 6. Good for Inc 0: SIGTERM cancelling the intake Task cleanly rolls back any in-flight write. ⚠️ Known edge (issue #1715): a cancelled async write can occasionally leave the connection stuck read-only; opt out by wrapping the access in an unstructured `Task` to force commit.

**F12. FTS5 under SwiftPM.** *(high, 3-0 — [CustomSQLiteBuilds.md](https://github.com/groue/GRDB.swift/blob/master/Documentation/CustomSQLiteBuilds.md), README)*
GRDB supports FTS5 (`FTS5Pattern` with `matchingAnyTokenIn`/`matchingAllTokensIn`/`matchingPhrase`); macOS **system** SQLite ships FTS5, so a default SPM install gets FTS5 on macOS. The Xcode-based `GRDBCustom` custom-SQLite build is **NOT SPM-compatible** (breaks GRDBQuery/GRDBSnapshotTesting). For Linux, FTS5 must come from elsewhere: vendor a SQLite amalgamation with `SQLITE_ENABLE_FTS5`, or use an SPM SQLite distribution that enables FTS5. Do **not** conclude FTS5 is impossible under SPM. *(Not needed until Inc 3/6 — Inc 0 creates no FTS5 tables.)*

### Angle 4 — `flock` single-instance guard

**F13. `flock(fd, LOCK_EX|LOCK_NB)` is the canonical guard.** *(high, 3-0 — [flock(2)](https://man7.org/linux/man-pages/man2/flock.2.html))*
Verbatim: *"Only one process may hold an exclusive lock for a given file at a given time."*; LOCK_NB makes it non-blocking, failing with `EWOULDBLOCK` if already locked → the second instance detects the first and exits. `flock` is advisory-only and unreliable over NFS (fine — the state root is local). The lock-holding FD must stay open for the daemon's lifetime.

**F14. Release on close / on exit.** *(high, 3-0 — flock(2))*
Released by explicit `LOCK_UN`, or automatically when **all** FDs referring to the same open file description are closed. The kernel closes all FDs on process termination (graceful, signal, or crash) → lock auto-released on exit, giving stale-lock cleanup for free. ⚠️ macOS BSD `flock(2)` shares the same core semantics but sanity-check on the macOS-primary target.

---

## Refuted claims (do NOT rely on)

| Claim | Vote | Note |
|---|---|---|
| `getUpdates` and webhooks are mutually exclusive, and a set webhook is *the* root cause of 409 Conflict in a long-poll client. | 1-2 ✗ | 409 semantics remain only partially characterized; treat 409 as "another `getUpdates` consumer or other conflict," not solely "webhook is set." The single-instance `flock` + a typed 409 surfaced loudly in `doctor` is the mitigation regardless of root cause. |
| `ServiceGroup` guarantees strict array-order startup and strict reverse-order shutdown, awaiting each child before the next. | 0-3 ✗ | Do not assume ordered start/stop. Design Inc 0 services to be order-independent. |

---

## Caveats & open questions (gaps to fill from ARCHITECTURE / verify at implementation)

The verified set did **not** confirm several specifics requested in the brief. For Inc 0 these are filled from `ARCHITECTURE.md` (normative) and standard knowledge, and flagged in the plan for direct verification against the installed toolchain/API:

1. **Exact 409 / 429 JSON response shapes & backoff.** Expected shape (standard Bot API, unverified here): `{"ok":false,"error_code":429,"description":"Too Many Requests: retry after N","parameters":{"retry_after":N}}`; 409 mirrors with `error_code:409`. Plan parses `ok==false` → `error_code` → typed error and reads `parameters.retry_after`. **Verify against a live 429/409 at implementation.**
2. **Angle 5 — swift-testing produced NO surviving verified claims.** The framework is well-established (Swift Testing, bundled with the Swift 6.x toolchain; `@Test`/`@Suite`/`#expect`/`#require`/`arguments:`/`withKnownIssue`/`@Tag`/`confirmation`; `swift test --filter <Suite>/<test>`), but treat exact macro signatures as **unconfirmed pending the installed toolchain**. Sources seen but unverified: [swiftlang/swift-testing](https://github.com/swiftlang/swift-testing), [migrating-from-xctest](https://swiftpackageindex.com/swiftlang/swift-testing/6.1.0/documentation/testing/migratingfromxctest), [WWDC24 “Meet Swift Testing”](https://developer.apple.com/videos/play/wwdc2024/10195/).
3. **Supervisor throttling keys** (launchd `KeepAlive`/`ThrottleInterval`/`RunAtLoad`/`SuccessfulExit`; systemd `Restart=on-failure`/`RestartSec`/`StartLimitIntervalSec`/`StartLimitBurst`/`TimeoutStopSec`) and **distinct non-retryable exit codes** for config-vs-secret failures — no surviving verified claims; taken from `ARCHITECTURE.md` §4/§15 and the [launchd.plist(5)](https://keith.github.io/xcode-man-pages/launchd.plist.5.html) / [systemd.service(5)](https://www.freedesktop.org/software/systemd/man/systemd.service.html) man pages (fetched but not in the verified set).
4. **Long-poll timeout vs socket/read-timeout distinction**, and the **`edited_message`/`callback_query` shapes** — unverified here; the plan sets HTTP read timeout > long-poll timeout (well-known requirement) and models only `message`/`edited_message` in Inc 0 (`callback_query` arrives in Inc 5).
5. **Linux FTS5 vendoring approach** (hand-vendored amalgamation vs CSQLite vs SQLite-on-SPM vs swift-sqlcipher) — open for Inc 6.

## Stats

5 angles · 23 sources fetched · 100 claims extracted · 25 verified · 23 confirmed / 2 killed · 105 agent calls.
