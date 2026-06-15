# swift-claw: Swift Implementation Grounding (2026)

_A persistent, always-on, Telegram-first personal AI assistant in pure Swift. Clean-room (no OpenClaw/prior code). Daily-driver on macOS (launchd) with Linux portability (systemd, Static Linux SDK). Swift 6 strict concurrency, secure-by-default, boring well-maintained libraries._

_Date: 2026-06-15. Library maturity verified against primary sources (GitHub API, raw `Package.swift`/source, official docs) as of mid-June 2026._

---

## 1. TL;DR — the recommended end-to-end Swift stack

- **Daemon core is a process supervisor, not a web framework.** Build the gateway on `swift-server/swift-service-lifecycle` `ServiceGroup` (SSWG, v2.11.0) over SwiftNIO; model the Telegram loop, store, and scheduler as `Service`s with ordered SIGTERM/SIGINT graceful shutdown. No open listen socket by default (long-polling), which is the better secure-by-default posture.
- **Telegram via `nerzh/swift-telegram-bot`** (module `SwiftTelegramBot`) for same-day Bot API coverage, `Sendable`/async client, and long-polling — but supply your own **AsyncHTTPClient-backed transport on Linux** instead of its default URLSession path. Own your MarkdownV2/HTML escaper and 4096-char (code-fence-safe) splitter regardless.
- **Persistence on `GRDB.swift` v7** (Swift-6 concurrency-native `DatabasePool`/`DatabaseQueue`, WAL, FTS5/BM25, migrations). Add **vector search via `sqlite-vec` compiled into a custom SQLite build** behind your own swappable protocol — `sqlite-vec` is the weak (alpha) link, so isolate it.
- **LLM clients are bespoke over AsyncHTTPClient + a tiny SSE parser.** No official Anthropic/OpenAI Swift SDK exists, and URLSession can't stream SSE on Linux / under the Static Linux SDK. Own the cross-provider `Message`/`ToolCall`/`StreamEvent` model and credential rotation/fallback. Use the **official MCP `swift-sdk`** for MCP only — but give it a Linux-capable SSE transport (its bundled `HTTPClientTransport` disables SSE on Linux).
- **Untrusted code runs in a VM-per-container boundary: `apple/container` via `swift-subprocess`** on the macOS daily-driver; a Podman/runc-in-microVM (or gVisor) backend on Linux, behind one `ExecutionBackend` protocol. Hardware virtualization, not shared-kernel namespaces.
- **Secrets via a thin `SecretStore` protocol over sops+age (at rest) + swift-crypto AES-GCM (in process)** — do **not** use the macOS Keychain as the daemon's primary store (a launchd daemon can't use the Data Protection keychain; the System keychain is root-only and deprecation-flagged).
- **Scheduling on Foundation `Calendar.RecurrenceRule`** (DST/timezone-correct, `Sendable`/`Codable`, in-toolchain) + a ~150-line custom 60s ticker, SQLite job store, and cross-process advisory lock.
- **Concurrency core is the standard library** (per-session actor + in-flight `Task` chaining/cancellation), plus **`dfed/swift-async-queue`** for ordered enqueue-from-nonisolated and batch cancellation (`/stop`). Workspace/memory is custom Swift + **Yams** for SKILL.md frontmatter. Optional REST surface = **Hummingbird 2**.
- **Ship one fully-static musl binary** via the **Swift Static Linux SDK** cross-compiled from the Mac; distroless `static`/`scratch` image; launchd + systemd supervision; logs to stdout/stderr (journald / newsyslog).

---

## 2. Recommended stack table

| Subsystem | Recommended | Runner-up | Maturity risk | One-line rationale |
|---|---|---|---|---|
| Gateway / daemon | swift-service-lifecycle `ServiceGroup` on SwiftNIO + swift-log | Hummingbird 2 (if inbound HTTP needed) | **Low** | Structured-concurrency supervisor with ordered graceful shutdown; no listen socket by default. |
| Telegram Bot API | `nerzh/swift-telegram-bot` (`import SwiftTelegramBot`) | Roll-your-own thin client over AsyncHTTPClient | **Med** | Same-day API coverage + `Sendable` async client; single maintainer, weak Linux URLSession default. |
| SQLite | GRDB.swift v7 (+ sqlite-vec as C extension) | SQLite.swift / raw C SQLite | **Low** (GRDB) / **High** (sqlite-vec) | GRDB is Swift-6 concurrency-native with WAL pool, FTS5/BM25, migrations; vectors are the immature part. |
| LLM clients | Thin in-house client over AsyncHTTPClient + SSE; official MCP `swift-sdk` for MCP | SwiftAnthropic + MacPaw/OpenAI under your own abstraction | **Med** | No official/cross-provider SDK; URLSession can't stream SSE on Linux; you own rotation/fallback anyway. |
| Sandboxing | `apple/container` (VM-per-container) via `swift-subprocess` | colima (shared-VM) + sandbox-exec defense-in-depth | **Med** | Hardware-virtualization boundary for untrusted code; macOS-26/Apple-Silicon-only, needs a separate Linux backend. |
| Secrets | `SecretStore` protocol over sops+age + swift-crypto AES-GCM | service-manager env vars / `LoadCredential` + 0600 file | **Low** | No portable Swift keyring; daemon can't use macOS Keychain well; boring primitives, identical on both OSes. |
| Scheduling | Foundation `Calendar.RecurrenceRule` + custom ticker/store | SwifCron (vendored) | **Low** | In-toolchain, DST/TZ-correct, `Sendable`/`Codable`; dedicated cron libs are small/stale. |
| Concurrency | std-lib structured concurrency + `dfed/swift-async-queue` | swift-async-algorithms `AsyncChannel` | **Low** | Per-session lanes via actor + Task chaining; one focused helper for ordered nonisolated enqueue + batch cancel. |
| Workspace / memory | Custom Swift module + Yams (SKILL.md frontmatter) | SwiftToolkit/frontmatter (reference only) | **Low** (Yams) | 90% file/string policy; Yams is the boring maintained YAML parser; swift-markdown can't do frontmatter. |
| Optional surfaces | Hummingbird 2 REST (`/v1/chat/completions`) + swift-subprocess (`execute_code`) | Vapor REST + SwiftWhisper/whisper.cpp + AVSpeechSynthesizer | **Med** | OpenAI-compat REST is highest-leverage; ACP is out-of-scope (no official Swift SDK). |
| Deployment | Static Linux SDK (musl) → distroless/scratch; launchd + systemd | swift-sdk-generator (glibc) + `swift:6.x-slim` | **Low** | First-party single static binary "runs on any Linux box"; escape hatch for glibc-only deps/WebSockets. |

---

## 3. Per-subsystem detail

### 3.1 Gateway / daemon framework

**Recommendation: `swift-service-lifecycle` `ServiceGroup` on SwiftNIO (with `swift-log`).** A headless Telegram gateway needs a structured-concurrency process supervisor — signal handling + ordered graceful shutdown — not HTTP routing/middleware. Model each long-running component (long-poll loop, state store, scheduler) as a `Service` (`func run() async throws`), compose them in a `ServiceGroup` with `gracefulShutdownSignals: [.sigterm, .sigint]`, and do cleanup after `try await gracefulShutdown()` returns (flush SQLite WAL, persist conversation state, cancel pending Bot API requests). SwiftNIO arrives transitively via AsyncHTTPClient for outbound Bot API calls — you never write ChannelHandlers. Minimal dependency surface, and with long-polling there is **no inbound listen socket**, which is the better baseline for a single-user daemon behind NAT.

**Runner-up: Hummingbird 2** — only if you decide to expose an inbound HTTP surface (Telegram webhook receiver, `/health`). It is the lightest real framework, rebuilt for Swift structured concurrency, and crucially uses the same `ServiceGroup` model (`runService()` defaults to `[.sigterm, .sigint]`, drains in-flight requests on shutdown), so adding it later is additive — the `Application` is just another `Service`. Prefer it over Vapor, whose dependency tree (Fluent, more middleware) is overkill here.

**Key tradeoffs.** The real decision is "process supervisor vs web framework," not "which framework." Long-polling needs no inbound port → `ServiceGroup` alone is ideal; a webhook needs HTTPS + cert + reverse proxy → the only reason to add Hummingbird. All three converge on the same graceful-shutdown mechanism, so the lighter base costs nothing. Raw SwiftNIO is rejected (only for custom wire protocols).

**Swift-6 / macOS+Linux notes.** Target Swift 6.1+. Do **not** install your own `signal(2)`/`sigaction` handlers — let `ServiceGroup` own signals (it uses an async signal source; a hand-rolled handler races the runtime and is not concurrency-safe). Shared mutable state (config, token store, memory) must be actor-isolated or `Sendable`; pass a `Sendable` `Logger`. Do not fork/daemonize — run foreground and let launchd (`RunAtLoad`/`KeepAlive`/`ThrottleInterval`) and systemd (`Type=simple`, `Restart=on-failure`, tuned `TimeoutStopSec`) supervise; both send SIGTERM on stop. Logging: depend on `apple/swift-log`; macOS bootstrap an OSLog backend (e.g. `chrisaljoudi/swift-log-oslog`), Linux keep the default `StreamLogHandler` (journald captures stdout). Bootstrap logging once before constructing services. Do all I/O async so cancellation/graceful-shutdown propagates.

**Verification corrections (apply these).**
- ⚠️ `swift-service-lifecycle` is SSWG **"Incubating," not "Graduated."** Only **SwiftNIO** holds SSWG "Graduated" status. (The maturity note correctly said only "SSWG package" for service-lifecycle, so the write-up is internally consistent — but do not describe service-lifecycle as graduated.)
- ⚠️ `givip/Telegrammer` is **effectively dead** (last release ~July 2019 / last source commit 2021-09-06; a misleadingly recent `pushed_at` does not reflect commits). Treat as abandoned, not merely "community-maintained."

---

### 3.2 Telegram Bot API

**Recommendation: `nerzh/swift-telegram-bot`, imported as `import SwiftTelegramBot`.** It is the only genuinely current Swift Telegram library (v10.1.0 on 2026-06-11, same day as Bot API 10.1), `swift-tools-version:6.0`, with a `Sendable` async client (`protocol TGClientPrtcl: Sendable`, all methods `async throws`). It ships the exact methods needed (`SendMessage`, `EditMessageText`, `SendChatAction`, `AnswerCallbackQuery`, `SendMessageDraft`), both `.longpolling()` and `.webhook(...)`, a handler/dispatcher layer (`CommandHandler`/`MessageHandler`/`RegexpHandler`/`CallbackQueryHandler`) for inline-keyboard approval flows, and is transport-agnostic. For a self-hosted daemon, pair **long-polling** (no inbound port/TLS) with a **custom AsyncHTTPClient-backed `TGClientPrtcl` on Linux** (the repo ships Hummingbird/Smoke/FlyingFox + AsyncHTTPClient examples).

**Runner-up: roll your own thin client over AsyncHTTPClient.** The Bot API is a trivial HTTPS/JSON RPC; long-poll is `getUpdates` with a timeout + offset cursor. You'd need only ~8–10 methods, fully-controlled Swift-6 types, native Linux+macOS via NIO (no swift-corelibs URLSession quirks), and zero solo-maintainer supply-chain risk — at the cost of writing Codable models and tracking API changes. A **hybrid** is best: the library plus your own AHC transport on Linux.

**Key tradeoffs.** Library = fastest to working, complete model coverage; custom = long-term control + dependency hygiene. Long-poll (no port/cert) vs webhook (lower latency, more plumbing): prefer long-poll for a personal daemon. Streaming: prefer `SendMessageDraft` (Bot API 9.3, GA in 9.5, 2026-03-01) where supported; fall back to throttled `editMessageText` (~1 edit/sec, shared ~20/min edit bucket). Parse mode: **prefer HTML** (escape only `& < >`) for LLM-generated text over MarkdownV2 (18 special chars with context-dependent rules) to avoid 400s. 4096-char limit: own a splitter that closes/reopens code fences.

**Swift-6 / macOS+Linux notes.** On Linux prefer the AHC transport (swift-corelibs URLSession is historically weaker). Isolate the `getUpdates` offset cursor and a per-chat rate-limit token bucket in an `actor`. On 429 read `parameters.retry_after` and `Task.sleep` before retry (typed error). Per-chat limiter: ≤1 msg/sec/chat, ≤20/min in groups, ~30/sec overall. Keep escaper and splitter pure `Sendable` functions. Some library internals use `@unchecked Sendable` (confirmed: `TGDefaultDispatcher`).

**Verification corrections (apply these).**
- ⚠️ **Import name was wrong.** It is `import SwiftTelegramBot` (the SPM product/module is `SwiftTelegramBot`), **not** `SwiftTelegramSdk`. File headers still say "SwiftTelegramSdk" but the module is `SwiftTelegramBot`.
- ⚠️ **There are not two near-identical repos.** `swift-telegram-sdk` was **renamed** to `nerzh/swift-telegram-bot` and 301-redirects; there is only one repo. The real footgun is the lingering "Sdk" naming inside file headers vs the "Bot" module name.
- ⚠️ The SDK's **v10.0.0 shipped 2026-05-11**, not 2026-05-08 (a 3-day lag behind Bot API 10.0). Same-day cadence holds for 10.1, not 10.0.
- ⚠️ `rapierorg/telegram-bot-swift` `Package.swift` is **`swift-tools-version:5.0`**, not 5.1 (and it remains stale: blocking synchronous `nextUpdateSync`, no async/await — not viable for Swift 6).
- Minor: source-file count is ~782 `.swift` files (not 740); `retry_after` is documented in the main Bot API reference, not the FAQ.

---

### 3.3 SQLite

**Recommendation: `GRDB.swift` v7 as the primary layer; `sqlite-vec` loaded as a C extension for vectors.** GRDB is the boring, batteries-included pick: built for Swift 6 strict concurrency (`Sendable` `DatabaseQueue`/`DatabasePool`, `try await writer.read{}` / `write{}`, an in-repo `SwiftConcurrency.md`, a `Swift6Migration` test target). `DatabasePool` gives WAL connection pooling (concurrent reads + one writer, WAL opened automatically); both share the `DatabaseWriter` protocol so you start with a `Queue` and upgrade to a `Pool` with no API churn. First-class FTS5 (BM25 ranking via SQLite's native `rank`/`bm25()`, surfaced as `.order(Column.rank)`), versioned migrations (`DatabaseMigrator`), value observation, type-safe records. For vectors, compile `sqlite-vec.c` into a custom SQLite build and call its init before opening (proven in GRDB discussion #1761) so BM25 + vector KNN + relational data share one file/connection.

**Runner-up: `SQLite.swift` v0.16.0** (10.1k stars, maintained, `Sendable` since 0.15.5, FTS5 via CSQLite, Linux compile fix in 0.16.0) — lighter, but no `DatabasePool`-style WAL pooling, weaker migrations, a less-developed Swift-6 story, and ~141 open issues. Or **raw C SQLite behind a small `Sendable` actor** for zero dependencies, at the cost of hand-rolling pooling/migrations/FTS5.

**Key tradeoffs.** GRDB's tested `DatabasePool`+WAL concurrency model is the single biggest win for a background-writer + foreground-reader daemon. FTS5/BM25 is solved natively in both GRDB and SQLite.swift. **Vector search is the real fork in the road** — no mature pure-Swift vector store exists. Encryption: GRDB supports SQLCipher but currently requires forking to edit `Package.swift`; consider full-disk/file encryption instead. Phasing: ship sessions/memory/scheduler on GRDB+FTS5 now; treat vectors as an isolated swappable module.

**Swift-6 / macOS+Linux notes.** Open exactly one `DatabasePool` (prod, WAL) or `DatabaseQueue` (tests/in-memory) per file for the process lifetime; both are `Sendable`. Enable `.enableUpcomingFeature("InferSendableFromCaptures")`. Prefer passing the `Sendable any DatabaseWriter` over wrapping it in a redundant actor (GRDB already serializes internally). Records crossing isolation boundaries must be `Sendable` value types. Use `DatabaseMigrator` once at startup. For vectors prefer the statically-linked `SQLITE_CORE` init pattern over runtime `load_extension`.

**Verification corrections (apply these).**
- ⚠️ **GRDB Linux is contributor-supported and NOT in upstream CI** — README verbatim: "Linux support is provided by contributors. It is not automatically tested, and not officially maintained." Pin the GRDB version, add your own Linux CI, and validate that your SQLite has FTS5 compiled in (vendor the amalgamation with `SQLITE_ENABLE_FTS5` + your `sqlite-vec` init so macOS and Linux behave identically).
- ⚠️ `sqlite-vec` is **pre-1.0 / alpha** (latest `v0.1.10-alpha.x`); the only dedicated Swift binding (`jkrukowski/SQLiteVec`, ~49 stars, 0.0.x) ships its own SQLite connection and does **not** integrate with GRDB. Keep all vector calls behind your own protocol so this alpha dependency is swappable. Open-issue counts in the maturity notes include PRs (e.g., GRDB "9" = 4 issues + 5 PRs); directionally GRDB is very clean, sqlite-vec carries the largest backlog.

---

### 3.4 LLM provider clients

**Recommendation: roll a thin in-house provider client over AsyncHTTPClient + a small SSE decoder; use the official MCP `swift-sdk` for MCP only.** The binding constraints — true Linux portability incl. the Static Linux SDK, Swift 6 strict concurrency, and a **cross-provider** abstraction with credential rotation/fallback that no Swift SDK provides — force this. URLSession's async streaming (`bytes(for:)`/`AsyncBytes`) is unavailable on swift-corelibs-foundation and unusable under the Static Linux SDK, so SSE token streaming (the core of an LLM client) cannot work cross-platform on URLSession. AsyncHTTPClient is the canonical, `Sendable`/Swift-6-ready NIO client and the de-facto Linux standard. An LLM REST client is small (Codable DTOs + a byte-stream `data:`/`event:` SSE parser); owning it puts the provider-agnostic layer (one `Message`/`ToolCall`/`StreamEvent` model, Anthropic↔OpenAI tool-schema normalization, credential pool with rotation + fallback on 401/429/5xx) where it belongs. For MCP, do **not** roll your own — use the official SDK, but give it a Linux-capable transport.

**Runner-up: `jamesrochabrun/SwiftAnthropic` + `MacPaw/OpenAI` under your own thin abstraction.** SwiftAnthropic is the standout for portability — it conditionally compiles AsyncHTTPClient + NIOFoundationCompat on `.linux` to dodge URLSession bugs, and supports streaming, tool use, prompt caching, vision/PDF, citations, token counting. MacPaw/OpenAI is the largest OpenAI Swift client (covers Responses + Chat Completions + MCP plumbing) **but is URLSession-based and declares only Apple platforms — not safe for the Linux half's streaming.** You'd still build the cross-provider normalization and rotation yourself.

**Key tradeoffs.** Build vs buy: a single-provider REST+SSE client is genuinely small, and the project's value-add (provider-agnostic model + schema normalization + credential rotation/fallback) is bespoke no matter what. Transport is decisive: any URLSession-based client (MacPaw, and the MCP SDK's HTTP transport) cannot stream tokens on Linux → AsyncHTTPClient is effectively mandatory. Borrow SwiftAnthropic/MacPaw DTOs as reference to reduce schema-tracking toil.

**Swift-6 / macOS+Linux notes.** Consume `HTTPClientResponse.body` as an `AsyncSequence<ByteBuffer>` into an incremental SSE parser (split on `\n\n`; OpenAI stops on `data: [DONE]`; Anthropic dispatches on `event:` types like `content_block_delta`/`message_delta`). Gate any macOS-only URLSession convenience with `#if canImport(FoundationNetworking)`; on Linux `import FoundationNetworking` for URL types. Make model types `Sendable`; manage the credential pool / per-provider backoff inside an `actor`; mark streaming callbacks `@Sendable`. Create one shared `HTTPClient` (`EventLoopGroupProvider.singleton`) for the daemon and `shutdown()` it on graceful termination. Credentials: macOS Keychain (or sops/age — see §3.5), Linux systemd credentials/env/0600 file. **MCP on Linux:** supply a custom AsyncHTTPClient + SSE transport, or restrict Linux MCP to `StdioTransport` (cross-platform).

**Verification corrections (apply these).**
- ⚠️ The MCP SDK's bundled `HTTPClientTransport` **explicitly disables SSE on Linux** (`#if !os(Linux) import EventSource`; logs "SSE responses aren't fully supported on Linux"). This is the central reason to re-transport it. Confirmed.
- Minor: `swiftlang/swift` #57548 redirects to the same `swift-corelibs-foundation` #5401 (SR-15226) — one report, not two independent sources (the still-open #3036 is the live corroborating issue). AsyncHTTPClient's "129 open issues" includes PRs (true issues-only ≈ 106) and it now requires Swift 6.1 (6.0 support dropped) — which strengthens, not weakens, the Swift-6 story. No claim refuted; central premise fully supported.

---

### 3.5 Secrets management

**Recommendation: a thin `SecretStore` protocol with two backends — (1) sops+age-encrypted file decrypted at startup, (2) a swift-crypto AES-GCM file backend — same code path on macOS and Linux. Do NOT use the macOS Keychain as the daemon's primary store.** No actively-maintained Swift library portably covers macOS + Linux secrets, so wrap boring primitives. The decisive constraint: a non-GUI launchd daemon **cannot use the Data Protection keychain** (Apple TN3137 / DTS engineer Quinn: it's user-context only); the file-based System keychain fallback requires root, is "on the road to deprecation," and is sandbox-fragile. Instead, store secrets in a sops+age-encrypted file (`/etc/swift-claw/secrets.env`, chmod 600), decrypt at process start, keep plaintext only in memory. sops (CNCF, v3.13.1) and age (FiloSottile, post-quantum) are extremely well maintained and identical across OSes. For an all-Swift in-process option, wrap `apple/swift-crypto` (v4.5.0, Swift 6 + Linux) AES-GCM/ChaChaPoly with an HKDF-derived key. The protocol lets you slot in a Keychain backend later for a GUI-helper case.

**Runner-up: env vars injected by the service manager** (launchd `EnvironmentVariables` / systemd `LoadCredential=` or `EnvironmentFile=`) backed by a 0600 file, no encryption at rest. Simplest, dependency-free, Swift-6/Linux-clean. Weaker: no at-rest protection and easier leakage (process env inheritance, `ps`, core dumps) — which is why sops+age is preferred for the at-rest copy and env/decrypt-on-start for runtime delivery. On macOS prefer reading a 0600 file the daemon opens itself over baking secrets into the plist (the plist would hold plaintext, and launchd doesn't always populate env for root daemons).

**Key tradeoffs.** Keychain portability is a dead end (only macOS/iOS wrappers, all unmaintained). sops+age gives encrypted, git-safe, rotatable secrets and one identical workflow — at the cost of a decrypt step at boot and an age identity that itself must be guarded (chmod 600, outside the repo). For a single-user daemon the master/age key lives on the same box anyway, so encryption-at-rest mainly protects backups/git/casual disk access — don't over-engineer toward HSM/KMS.

**Swift-6 / macOS+Linux notes.** Load all secrets once at startup into an immutable `struct Secrets: Sendable` (let-only) so it crosses actor/task boundaries freely. Wrap secrets in a `Redacted` type so they never interpolate into logs. `ProcessInfo.processInfo.environment` is value-typed — read at launch, not lazily. swift-crypto is Swift-6/`Sendable`-clean and identical on both OSes (`SymmetricKey`, `AES.GCM.seal/open`, `HKDF<SHA256>.deriveKey`); zero plaintext buffers after use. If you add a Keychain backend later, confine all `SecItem` calls behind `actor KeychainBackend` (Security C types aren't `Sendable`) gated by `#if os(macOS)`. Shell out to sops/age via `Process`; read decrypted output from a pipe into memory; verify the age identity file is `0o600` and fail fast otherwise.

**Verification corrections (apply these).**
- ⚠️ **REFUTED absolute claim:** "No Swift libsecret/Secret-Service bindings exist." `amethystsoft/KeyringAccess` is a pure-Swift Secret Service implementation on Linux (DBus-based, created 2026-05-03, ~16 stars). State it as "no **mature** Swift Secret-Service binding exists" — it is ~6 weeks old and unproven, so still unwise to depend on, but the absolute claim is false.
- ⚠️ **age version:** current latest is **v1.3.1 (2025-12-28)**, not v1.3.0 (v1.3.0 introduced ML-KEM-768 hybrid PQ recipients + `EncryptReader`). Post-quantum characterization is accurate; update the version number.
- Minor: swift-crypto v4.0.0 shipped **2025-10-06** (not 2025-09); the v4.5.0/2026-04-23 headline is correct. A 5.0.0-beta exists (2026-06-08) — pin to 4.x for stability. `kishikawakatsumi/KeychainAccess` confirmed dormant (v4.2.2, 2021; Swift 4.x–5.1; macOS/iOS only). `jamesog/AgeKit` confirmed WIP/immature.

---

### 3.6 Scheduling / NL cron

**Recommendation: Foundation `Calendar.RecurrenceRule` (swift-foundation, SF-0009) as the schedule model + a thin custom 60s ticker and SQLite job store.** The standout "library" ships in the toolchain: `RecurrenceRule` is `Equatable, Codable, Sendable`; `recurrences(of:in:)` returns `some Sequence<Date> & Sendable`; and because it computes through an embedded `Calendar` (with `TimeZone`), it is **correctly DST- and timezone-aware for free** — the hard part of scheduling. It's open-source swift-foundation, so the same code runs on macOS and Linux. This eliminates the biggest risk here: relying on a tiny, stale third-party cron parser for DST math. Model schedules as `Calendar.RecurrenceRule` (TZ carried by `rule.calendar.timeZone`, store IANA id), persist in SQLite, and roll a ~150-line ticker: a 60s repeating `Task` that computes due jobs, guards overlap with an in-process actor lock **plus** an OS advisory file lock (`flock`/`O_EXLOCK`), and records `last_fired_at` for restart-safe catch-up. Minimum granularity is minutely — matches a 60s ticker.

**Runner-up: `SwifCron`** — if cron strings (crontab.guru UX, LLM emits crontab syntax) are your canonical format. Pure Swift, zero deps, 5-/6-field, `next()`/`next(from:)`, builds on Linux. Downsides: maintenance-only (last commit 2023, tools 4.2, no `Sendable` annotations), no literal month/day names or `7`-for-Sunday, and DST correctness is on you. It's tiny (~5 files) so vendoring/forking is low-risk. `NIOCronScheduler` (same author) drags in SwiftNIO and is stale — not worth the coupling.

**Key tradeoffs.** RecurrenceRule (native, DST-correct, `Sendable`/`Codable`, no dep) vs cron strings (familiar, but DST math + third-party/hand-rolled parser on you). Platform floor: RecurrenceRule needs macOS 15+ on Apple platforms (fine for a 2026 daily-driver). Catch-up vs skip on restart: store `last_fired_at` + a misfire policy. Overlap: need both an in-process actor lock and a cross-process advisory lock. NL→schedule: constrain the LLM to emit typed JSON or a validated RRULE/cron string, parse deterministically, and echo the next 3 fire times for confirmation.

**Swift-6 / macOS+Linux notes.** `RecurrenceRule` and computed dates are `Sendable`. Model the scheduler as an `actor`; the ticker is `while !Task.isCancelled { try await Task.sleep(for: .seconds(60)); await scheduler.tick() }` — use `Task.sleep`, never `Thread.sleep`, and make it cancellable for clean shutdown. Cross-process lock via `flock(LOCK_EX|LOCK_NB)` (or `O_EXLOCK` on Darwin) under `$XDG_RUNTIME_DIR`/`~/.swift-claw`. Store IANA TZ id (not a fixed offset). Avoid `Timer`/`RunLoop` (semantics differ on Linux, don't fit structured concurrency). Keep the (slow, async) LLM call off the actor; hand back only the validated rule.

**Verification corrections (apply these).**
- ⚠️ **Declaration string was inaccurate.** Source is `public struct RecurrenceRule: Sendable, Equatable {` and **`Codable` is added via a separate extension**, not the main declaration. All three conformances (`Equatable`, `Codable`, `Sendable`) genuinely exist — so "it is Equatable/Codable/Sendable" holds — but don't quote the one-line declaration as `: Equatable, Codable, Sendable`.
- Minor: the proposal doesn't literally use the word "lazy" (the behavior is lazy/on-demand). `RRuleKit` declares **only Apple platforms** in `Package.swift` (no `.linux`) and pins macOS 15/iOS 18 — not a safe Linux dependency as published. Several "stale/avoid" star counts in the maturity notes are low vs reality (rymcol ~56, TheCodedSelf 33, safx 25, NIOCronScheduler 23) — but the dates/archival/issue facts hold. SwifCron's 2.0.0 does add 6-field seconds support.

---

### 3.7 Swift concurrency for an always-on multi-session server

**Recommendation: standard-library structured concurrency as the core (a per-session `actor` + an in-flight `Task` handle), plus `dfed/swift-async-queue` for ordered enqueue-from-nonisolated and batch cancellation.** This is a concurrency problem, not a framework choice. A plain `actor SessionRegistry` keyed by session id gives per-session state isolation for free. The **non-obvious, critical fact: actors do NOT serialize across `await` (actor reentrancy)** — a second inbound message can interleave between a suspension and resumption — so an actor alone does **not** give a per-session run lane. The boring fix: the actor holds `var currentRun: Task<Void, Never>?` and chains/cancels it. To serialize ("lane"): `let prev = currentRun; currentRun = Task { await prev?.value; await run() }`. For "inbound supersedes": `prev?.cancel()` first. `/stop` is `session.currentRun?.cancel()`. `dfed/swift-async-queue` closes the residual gap — sending **ordered** tasks into an actor from a **nonisolated** synchronous context (the Telegram callback) — and ships `FIFOQueue` (full serialization including across suspension points = a true lane), `ActorQueue` (cheaper, order until first suspension), `MainActor.queue`, and `CancellableQueue.cancelTasks()` (cancel executing + all pending at once = `/stop`). It builds under full Swift 6 mode (`.swiftLanguageMode(.v6)`), MIT, has explicit Linux CI (`ubuntu-24.04` / `swift:6.2`), 0 open issues, released 2026-06-09.

**Runner-up: `apple/swift-async-algorithms` `AsyncChannel`** as the lane + backpressure transport (one long-lived consumer task per session draining a channel; `send` suspends the producer = native backpressure). Apple-owned, lowest dependency risk — but it gives the transport, **not** the registry, the nonisolated-enqueue ordering guarantee, or batch cancellation, so you write more glue and manage one consumer task per session lifecycle.

**Key tradeoffs.** Build vs buy: the lane is ~50–100 lines; the library buys tested ordering/cancellation and avoids reentrancy footguns. `FIFOQueue` (strict per-session lane, one run at a time) vs `ActorQueue` (only ordered to first suspension — does NOT give "one run executing at a time" on its own); use `FIFOQueue` for the run lane, `ActorQueue`/`MainActor.queue` for a fast global control lane. **Cancellation is cooperative** — `cancelTasks()`/`cancel()` only set a flag; the run loop must `try Task.checkCancellation()` and blocking I/O (LLM streaming) must honor `withTaskCancellationHandler`. A single global lane serializes all sessions (bottleneck) — prefer per-session lanes; reserve a global lane for short global ops (config reload, rate-limit bucket).

**Swift-6 / macOS+Linux notes.** Everything passed into a run `Task` or sent over a channel must be `Sendable` (value-type commands/contexts; capture an immutable snapshot or the actor itself). `@globalActor` is a clean single global lane but serializes app-wide — use only for a small control surface. Backpressure: `AsyncChannel.send` suspends; `AsyncStream` with `.bufferingNewest(n)` drops — choose deliberately, and bound per-session queue depth. Both helpers have Linux CI on `swift:6.2`; `swift-async-queue` uses `FoundationEssentials` on Linux. Don't fake a lane with `DispatchQueue` serial queues or detached tasks under Swift 6.

**Verification corrections (apply these).**
- All six core claims **confirmed**. ⚠️ Note: `swift-async-queue`'s `Package.swift` `platforms[]` does **not** list Linux — this is normal SwiftPM behavior (Linux is implicit), and Linux support is proven via the dedicated CI job, not refuted.
- Minor: the maturity note's "swift-async-algorithms … plus FreeBSD/WASI" is **unverified** (README documents Linux only). A summarizer pass that claimed `FIFOQueue` "does NOT fully serialize across suspension points" was **wrong** — the README is authoritative ("begin _and end_ executing in the order … enqueued tasks execute atomically" = full serialization). `mattmassicotte/Queue` not recommended (still tools 5.9 / experimental StrictConcurrency flag, pre-1.0).

---

### 3.8 Workspace / memory file conventions

**Recommendation: a thin custom Swift workspace/memory module + Yams (`jpsim/Yams`) for SKILL.md YAML frontmatter.** This is 90% file/string conventions (policy, not parsing), so own the disk layout (`~/.swift-claw/workspace`) and the caps/injection-order/flush rules. The one external dependency worth taking is **Yams** for SKILL.md frontmatter: de-facto Swift YAML, actively maintained (v6.2.2, 2026-05-26), MIT, ships `Package@swift-6.0.swift`, and builds on Linux because it vendors LibYAML C bindings (no Foundation-only gaps). Apple's `swift-markdown` does **not** parse frontmatter (issue #73 open since 2022), so pair Yams (header) with swift-markdown (body, if you need an AST). The Agent Skills spec is the canonical, stable standard: `name` 1–64 chars `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$` (no `--`, must match parent dir), `description` 1–1024 chars, optional `license`/`compatibility`(≤500)/`metadata`/`allowed-tools`, 3-level progressive disclosure (metadata ~100 tokens at startup, full SKILL.md <5000 tokens / <500 lines on activation, resources on demand). Memory files follow Hermes/OpenClaw conventions.

**Runner-up: `SwiftToolkit/frontmatter`** (a Yams wrapper with `Frontmatter.decode()/encode()`) — but it's a single-author micro-package (~2 stars, ~3 commits, one `1.0.0` tag but no GitHub Releases, Linux undocumented). Treat as a reference; prefer depending on Yams directly and writing a ~30-line splitter (split on leading `---`, `YAMLDecoder` the header, keep the remainder as body).

**Key tradeoffs.** Memory/workspace caps + injection + flush have no suitable library — keep custom. Yams direct (fewer/healthier deps) over the unmaintained wrapper. Yams over hand-rolled YAML (arbitrary user YAML is a footgun). **Adopt Hermes-style tight caps with explicit error-on-overflow** (MEMORY 2200 / USER 1375) rather than OpenClaw's loose 20000/file + 150000-total **silent** truncation — silent truncation is a correctness hazard the OpenClaw docs themselves warn about. Frozen-snapshot injection improves prompt-prefix caching but means mid-session writes apply next session — surface live state only via tool responses.

**Swift-6 / macOS+Linux notes.** Layout under `~/.swift-claw/workspace` (`skills/<name>/SKILL.md` + `references/`/`scripts/`/`assets/`, `memory/MEMORY.md`, `memory/USER.md`, `memory/YYYY-MM-DD.md`, bootstrap `SOUL/AGENTS/IDENTITY/TOOLS/HEARTBEAT.md`). Resolve home with `FileManager.default.homeDirectoryForCurrentUser` (both OSes). Own all disk IO + cap enforcement in one `actor WorkspaceStore`; model files as immutable `Sendable` structs; caps as a test-injectable `Sendable` config. Count chars as `String.count` (graphemes); prefer throwing over truncating. Assemble the system prompt deterministically (recommend SOUL→AGENTS→IDENTITY→TOOLS→USER→MEMORY→HEARTBEAT→today+yesterday logs) into one frozen string per session. Validate `name`/`description` per spec. Flush-before-compact: one extra model turn exposing only the memory-write tool, persist via the actor (error on overflow), then summarize. Use a `LocalFileSystem` protocol for testability.

**Verification corrections (apply these).**
- ⚠️ Yams "full concurrency checking" is **overstated** — `Package@swift-6.0.swift` only sets `swift-tools-version:6.0` with no explicit `swiftLanguageMode(.v6)`/`StrictConcurrency` settings. The Swift 6 language mode (with complete concurrency checking) is the **default implied** by tools-version 6.0, so it's directionally true — but don't cite it as an explicit opt-in.
- Minor: `SwiftToolkit/frontmatter` "no releases" is precise only for GitHub Releases (a `1.0.0` git tag exists). Star/issue figures drift (Yams ~1251 stars / ~26 issues; agentskills ~20.5k / 34; Hermes ~188–190k, v0.16 ~2026-06-05). All six core spec/convention claims confirmed against primary sources.

---

### 3.9 Optional / future surfaces

**Recommendation: Hummingbird 2 for the OpenAI-compatible `/v1/chat/completions` surface; `swift-subprocess` for `execute_code`.** The REST endpoint is the highest-leverage, most portable surface, and Hummingbird is the clear fit (only Swift web framework architected for Swift 6 strict concurrency, Linux+macOS via SwiftNIO, small/composable, actively maintained). SSE streaming maps onto Hummingbird's async response body; back the route with your LLM actor. For `execute_code`, `swift-subprocess` (official swiftlang/Foundation) spawns a child, captures stdout-only via the collected-result API (`output: .string(limit:)`), streams stdout/stderr as async sequences, cross-platform (Darwin `posix_spawn`, Linux `fork+exec`/pidfd). The same Hummingbird/SwiftNIO server can bind a unix-domain socket for the RPC layer.

**Runner-up: Vapor for the REST endpoint** (proven by `gety-ai/apple-on-device-openai` and `Apple-Intelligence-API`, both exposing `/v1/chat/completions` with SSE) — heavier, older concurrency model, more deps. Voice STT: prefer vendoring upstream `ggml-org/whisper.cpp` (v1.8.6, 50.7k stars) via its C API for Linux portability over `SwiftWhisper` (maintenance-mode, Apple-focused). TTS: `AVSpeechSynthesizer` is excellent and free on macOS but Apple-only — Linux needs an external engine (Piper/Kokoro behind a localhost call).

**Key tradeoffs.** OpenAI-compat REST is far more useful here than ACP (which targets IDE↔coding-agent integration, has no official Swift SDK, and only tiny single-maintainer ports with weak/absent Linux support — treat ACP as out-of-scope). For `execute_code` the real work is sandboxing/limits (timeouts, env scrubbing, working-dir isolation, output caps), not the spawn. TTS is the asymmetric one — cross-platform TTS forces an external Linux engine. ShareGPT export is zero-tradeoff hand-rolled Codable (prefer JSONL for append-friendly trajectory logging).

**Swift-6 / macOS+Linux notes.** Model all four surfaces as actor-isolated, feature-gated services so the core Telegram path has no hard dependency on whisper/AVFoundation/a web server. Hummingbird handlers/router are `Sendable`-clean by construction; stream SSE via a `ResponseBody` yielding `data:` frames from an `AsyncSequence`. `swift-subprocess` needs Swift 6.2+ on main; enforce timeouts with a `Task` + cancellation (termination is cooperative). whisper.cpp is plain C — bridge via a SwiftPM `systemLibrary` over `whisper.h`, wrap the context in a dedicated actor, feed 16kHz mono Float PCM; CoreML/Metal is macOS-only (conditionally compiled). `AVSpeechSynthesizer` lives in AVFoundation — guard `#if canImport(AVFoundation)`/`#if os(macOS)`, keep a retained synthesizer + active run loop in a headless daemon; expose a `TTSProvider` protocol so Linux plugs an external engine.

**Verification corrections (apply these).**
- ⚠️ **whisper.cpp does NOT ship its own SwiftPM `Package.swift`** (404; bindings dir has go/java/javascript/ruby only). It ships an **Apple-only XCFramework artifact** referenced from a README `binaryTarget` example; the dedicated Swift package is the **separate** `whisper.spm` repo (~189 stars, last updated 2024). The substance holds (clean C API, Swift C-interop, Apple-only binary, Linux via source build) — just don't say whisper.cpp "ships an XCFramework via SPM" from itself.
- ⚠️ **ShareGPT schema:** the cited Hermes format does **not** use top-level `{id, length}` — it uses `conversations`/`timestamp`/`model`/`completed` (+ batch-variant extras). The `from`(system/human/gpt)/`value` core and "Codable, no library" conclusion are correct; `{id, length}` belongs to the broader ShareGPT dataset convention, not this source.
- Minor: Hummingbird 2.25.0 shipped **2026-05-29** (late May); `Package.swift` is `swift-tools-version:6.1` / badge `swift-6.1+` (not literally "6.0–6.3"); `StrictConcurrency=complete` is applied via CI/build flags. `swift-subprocess`: **all released versions require Swift 6.1**, only `main` needs 6.2+. ACP `aptove/swift-sdk` declares Apple platforms only (no Linux). No core claim refuted.

---

## 4. apple/container vs Docker — sandbox backend verdict

**Verdict: for executing UNTRUSTED inbound code, use a hardware-virtualization boundary (VM-per-container), not a shared-kernel namespace boundary. On the macOS daily-driver that means `apple/container`; on Linux, a Podman/runc-in-microVM (or gVisor `runsc`) backend behind the same abstraction. `colima`/Docker is the weaker, more-portable fallback.**

- **Why VM-per-container.** `apple/container` (pure Swift, Apache-2.0, v1.0.0 on 2026-06-09, 36.9k stars) runs each Linux container in its **own lightweight VM** via Virtualization.framework. A container escape therefore requires a **hypervisor** escape, not a Linux-kernel namespace/cgroup escape — the right threat model for untrusted code. `colima` (shared Lima VM kernel, 29.3k stars) is faster/lighter but a kernel exploit escapes to **all** co-located containers.
- ⚠️ **Hard limits to plan around.** `apple/container` is **Apple-Silicon-only AND macOS-26-only** (maintainers won't address issues not reproducible on macOS 26); some features (nested virtualization) need M3+. It has **no Linux runtime story**, so it cannot be the single cross-platform backend — it is the macOS production backend, with a separate Linux backend required. The embeddable `apple/containerization` library is **pre-1.0** (`.upToNextMinor` pinning, breaking-change risk if embedded). Per-VM boot adds latency vs a warm shared VM — amortize with a warm pool of short-lived ephemeral containers.
- ⚠️ **`sandbox-exec`/Seatbelt** is **deprecated but still functional in 2026, with NO published removal date and no sanctioned headless replacement** (App Sandbox targets GUI/App-Store apps). Use it only as defense-in-depth around the launcher (deny-by-default reads/network) — **never as the sole boundary** for untrusted code.
- ⚠️ **colima mounts `$HOME` writable by default** (a colima-specific override of Lima's conservative read-only default) — a credential-leak risk **stronger** than "mounts `$HOME`." Never mount `$HOME`; the dominant risk is **read** access to host secrets (SSH keys, tokens, `.env`).

**Secure-by-default execution model.**
- No host bind-mounts by default; clone/stage inputs into the VM, bind-mount only an explicit scratch dir.
- `--cap-drop ALL`, add back only what's needed; run rootless/unprivileged.
- Dedicated isolated network with **egress denied** unless a tool opts in (`apple/container` isolated networks or a filtering proxy).
- Default resource caps (1GB/4CPU) overridable; `--init` reaper; deterministic timeouts (`--stop-signal` then SIGKILL).

**Backend-abstraction sketch (drive via `swiftlang/swift-subprocess`, Swift 6.2, Sendable-correct).**
```swift
protocol ExecutionBackend: Sendable {
    func run(_ request: SandboxedExec) async throws -> ExecResult
}
struct SandboxedExec: Sendable { /* image, argv, env, scratchDir?, timeout, netPolicy */ }
struct ExecResult: Sendable { let stdout: String; let exitCode: Int32; let timedOut: Bool }

// macOS 26 + arm64: shells out to the `container` CLI via swift-subprocess
#if os(macOS)
struct ContainerBackend: ExecutionBackend { /* warm-pool + network handles inside an actor */ }
#endif
// Linux: Podman / runc-in-microVM (or gVisor runsc) behind the same protocol
#if os(Linux)
struct PodmanMicroVMBackend: ExecutionBackend { /* ... */ }
#endif
```
Prefer **shelling out to the `container` CLI** over embedding the pre-1.0 `containerization` library: looser coupling, more stable API, trivially swappable, and it keeps the untrusted workload in a separate process tree. Put backend state (warm-container pool, network handles) inside an `actor`; enforce timeouts/cancellation with `withThrowingTaskGroup`. On Linux use `.closeAllUnknownFileDescriptors` to avoid leaking host FDs into the sandbox.

---

## 5. Recommended build order (daily-driver MVP first)

Bias: daily-driver robustness over breadth. Each increment lands a working, supervised slice.

1. **Increment 0 — Supervised echo daemon (highest impact-to-complexity).** `swift-service-lifecycle` `ServiceGroup`; one `Service` that long-polls Telegram via `SwiftTelegramBot` (with your AsyncHTTPClient transport on Linux) and echoes messages; swift-log; launchd plist (macOS). _Done when:_ the bot replies to a Telegram message, survives `launchctl kickstart`/SIGTERM with clean graceful shutdown, and restarts on crash.
2. **Increment 1 — LLM turn + streaming + persistence.** Thin AsyncHTTPClient LLM client + SSE parser (one provider first); GRDB `DatabasePool` (WAL) for sessions/messages with `DatabaseMigrator`; your MarkdownV2/HTML escaper + 4096-char code-fence-safe splitter; streamed replies via throttled `editMessageText` (or `SendMessageDraft`). _Done when:_ a real model answer streams into Telegram, persists across daemon restart, and never throws a 400 on formatting.
3. **Increment 2 — Per-session lanes, `/stop`, and secrets.** Per-session `actor` + in-flight `Task` chaining (serialize / inbound-supersedes) and `dfed/swift-async-queue` for nonisolated enqueue + `cancelTasks()`; cooperative cancellation through the streaming loop; `SecretStore` over sops+age (decrypt-to-memory at startup). _Done when:_ a second message in the same chat queues behind the first, `/stop` interrupts an in-flight generation within a turn, and no secret is on disk in plaintext.
4. **Increment 3 — Sandboxed `execute_code`.** `ExecutionBackend` protocol; `ContainerBackend` (`apple/container` via `swift-subprocess`) on macOS, deny egress, no host mounts, timeouts, stdout-only capture. _Done when:_ untrusted code runs in a per-container VM, a hung process is killed on timeout, and it has no host filesystem/network access by default.
5. **Increment 4 — Scheduling + memory/workspace.** `Calendar.RecurrenceRule` jobs in SQLite with a 60s ticker, in-process actor lock + cross-process `flock`, catch-up/skip misfire policy; `~/.swift-claw/workspace` with `WorkspaceStore` actor, Hermes-style tight caps (error-on-overflow), frozen-snapshot injection, flush-before-compact; Yams for SKILL.md frontmatter. _Done when:_ a "every weekday 07:00 Europe/Berlin" job fires once per occurrence across restarts/DST, and durable facts persist to MEMORY.md before compaction without silent truncation.
6. **Increment 5 — Linux portability + deployment.** Static Linux SDK cross-compile from the Mac (musl, SDK version == toolchain); three-way `Glibc`/`Musl`/`Darwin` import shims; distroless `static` image with CA certs + tzdata; systemd unit (`Restart=on-failure`, `RestartSec`, `TimeoutStopSec`); Linux CI gating releases. _Done when:_ the same source produces a running, supervised binary on a fresh Linux box (Ubuntu/Fedora/Alpine) with HTTPS to Telegram + the LLM working.

_(Later/optional: Hummingbird `/v1/chat/completions` REST surface, MCP via the official SDK with a Linux SSE transport, voice, ShareGPT export.)_

---

## 6. Open risks & things to decide later

- **Telegram client bus factor.** `SwiftTelegramBot` is a single-maintainer project with `@unchecked Sendable` internals; the default URLSession transport is weak on Linux. Mitigation is committed (custom AHC transport) — but be ready to migrate to a fully roll-your-own client if maintenance lapses.
- **`sqlite-vec` is alpha.** Vector search is the immature part of the stack. Keep it strictly behind your own protocol; decide later whether to defer vectors entirely for v1 or commit to the custom-SQLite-build + C-shim (re-applied on GRDB upgrades).
- **macOS-26 / Apple-Silicon gate on `apple/container`.** Forces the daily-driver onto macOS 26 and is useless for Linux. Decide the Linux sandbox backend concretely (Podman+microVM vs gVisor `runsc`) before Increment 5, and whether `colima` (no macOS-26 requirement, weaker isolation) is an acceptable older-macOS fallback.
- **Static SDK pinned deps.** Bundled curl 8.7.1 lacks WebSocket support and ships pinned libs; the SDK version must exactly match the toolchain. If a dependency needs WebSockets/newer TLS/glibc-only C libs, fall back to `swift-sdk-generator` (glibc) + `--static-swift-stdlib`. Keep a Linux CI build to catch target-only cross-compile compiler bugs.
- **Secrets at-rest scope.** For a single-user box the age/master key lives locally anyway; decide how much encryption-at-rest actually buys you vs full-disk encryption, and where the age identity lives (must be `0o600`, outside the repo).
- **Parse mode policy.** Decide HTML-by-default vs MarkdownV2 for LLM output (HTML is far less 400-prone) and own the splitter regardless.
- **Memory cap semantics.** Lock in char-counting (grapheme `String.count` vs `unicodeScalars.count`) and confirm error-on-overflow (not silent truncation) end to end.
- **MCP transport on Linux.** Decide between supplying a custom AsyncHTTPClient SSE transport vs restricting Linux MCP to `StdioTransport`.
- **TTS cross-platform.** Decide whether TTS must work on Linux (forces Piper/Kokoro behind a localhost call) or macOS-only `AVSpeechSynthesizer` suffices.

---

## 7. Sources (deduped, grouped by subsystem)

**Gateway / daemon**
- https://github.com/swift-server/swift-service-lifecycle
- https://github.com/apple/swift-nio
- https://github.com/hummingbird-project/hummingbird
- https://github.com/apple/swift-log
- https://github.com/chrisaljoudi/swift-log-oslog

**Telegram Bot API**
- https://github.com/nerzh/swift-telegram-bot (formerly swift-telegram-sdk; `import SwiftTelegramBot`)
- https://core.telegram.org/bots/api
- https://core.telegram.org/bots/api-changelog
- https://github.com/swift-server/async-http-client

**SQLite**
- https://github.com/groue/GRDB.swift
- https://raw.githubusercontent.com/groue/GRDB.swift/master/GRDB/Documentation.docc/SwiftConcurrency.md
- https://github.com/groue/GRDB.swift/discussions/1761
- https://github.com/asg017/sqlite-vec
- https://github.com/stephencelis/SQLite.swift

**LLM clients**
- https://github.com/swift-server/async-http-client
- https://github.com/mattt/EventSource
- https://github.com/modelcontextprotocol/swift-sdk
- https://github.com/modelcontextprotocol/swift-sdk/blob/main/Sources/MCP/Base/Transports/HTTPClientTransport.swift
- https://github.com/jamesrochabrun/SwiftAnthropic
- https://github.com/MacPaw/OpenAI
- https://github.com/swiftlang/swift-corelibs-foundation/issues/5401
- https://github.com/swiftlang/swift-corelibs-foundation/issues/5092

**Sandboxing**
- https://github.com/apple/container
- https://github.com/apple/container/releases/tag/1.0.0
- https://github.com/apple/containerization
- https://github.com/apple/containerization/issues/737
- https://github.com/swiftlang/swift-subprocess
- https://github.com/abiosoft/colima

**Secrets**
- https://developer.apple.com/forums/thread/759976
- https://developer.apple.com/forums/thread/719219
- https://github.com/apple/swift-crypto
- https://github.com/getsops/sops
- https://github.com/FiloSottile/age

**Scheduling**
- https://github.com/swiftlang/swift-foundation/blob/main/Proposals/0009-calendar-recurrence-rule.md
- https://github.com/swiftlang/swift-foundation/blob/main/Sources/FoundationEssentials/Calendar/RecurrenceRule.swift
- https://developer.apple.com/documentation/foundation/calendar/recurrencerule
- https://github.com/MihaelIsaev/SwifCron

**Concurrency**
- https://github.com/dfed/swift-async-queue
- https://github.com/apple/swift-async-algorithms
- https://www.donnywals.com/actor-reentrancy-in-swift-explained/
- https://developer.apple.com/documentation/swift/withtaskcancellationhandler(operation:oncancel:isolation:)

**Workspace / memory**
- https://agentskills.io/specification
- https://github.com/jpsim/Yams
- https://github.com/swiftlang/swift-markdown/issues/73
- https://hermes-agent.nousresearch.com/docs/user-guide/features/memory
- https://www.stack-junkie.com/blog/openclaw-workspace-architecture

**Optional surfaces**
- https://github.com/hummingbird-project/hummingbird
- https://github.com/swiftlang/swift-subprocess
- https://github.com/ggml-org/whisper.cpp
- https://github.com/gety-ai/apple-on-device-openai

**Deployment**
- https://www.swift.org/documentation/articles/static-linux-getting-started.html
- https://github.com/swiftlang/swift-sdk-generator
- https://tuist.dev/blog/2026/02/16/linux
- https://willhbr.net/2025/10/13/the-6-2nd-stage-of-swift-on-linux/
- https://github.com/swift-server/swift-service-lifecycle
- https://keith.github.io/xcode-man-pages/launchd.plist.5.html
