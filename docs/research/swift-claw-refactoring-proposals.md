# swift-claw refactoring proposals — Apple OSS study triage

| | |
|---|---|
| **Status** | Refactoring proposals (point-in-time, for triage) |
| **Date** | 2026-07-10 |
| **Owner** | Ivan Magda |
| **Related** | [`apple-oss-engineering-practices.md`](apple-oss-engineering-practices.md) (the evidence base) · [`ARCHITECTURE.md`](../ARCHITECTURE.md) (normative spec) |

> **What this is.** Eight proposals derived from the 15-repo Apple OSS study, for the owner to
> accept or reject **by number**. Implementing an accepted item is a separate later task, one per
> item. This document is **not normative**: `ARCHITECTURE.md` remains the spec, and any proposal
> that would change it says so explicitly ("SPEC CHANGE"). Apple citations use `repo path:line` at
> the SHAs pinned in the synthesis (§12 there); swift-claw citations are repo paths at the working
> tree of 2026-07-10, verified during the study.

## Summary

| # | Title | Priority | One-line |
|---|---|---|---|
| 1 | Extract the environment loader and a `DaemonBuilder` from `RunCommand` | P1 | Keep the single composition root, but stop hanging it on the CLI command type and stop duplicating env bootstrap in `doctor` |
| 2 | Adopt the stdlib `Clock` for pacing seams | P2 | Replace the `sleep:` closures (and pacing `now:` reads) with an injected `any Clock<Duration>`; fix the `Double`-seconds divergence |
| 3 | Move `WorkspaceReading` into ClawCore | P1 | The one seam declared in an implementation module; forces `ClawAgent`/`ClawGateway` to import the concrete workspace |
| 4 | Split `Stores.swift` by domain and the `Routing/` folder by subsystem | P2 | One 486-line file of ~15 unrelated protocols; one 19-file folder of four subsystems |
| 5 | Consolidate the error taxonomy under `ClawCore/Errors/` and type the store seam | P2 | The §19 taxonomy is scattered across `Config/Errors.swift` and `LLM.swift`; `throws(StoreError)` makes the existing seam contract compiler-enforced |
| 6 | Strip process tags from comments; sharpen the comment rule | P2 | "NEW", "review H2", "Task 14", "rev.1", "Inc N" are change history, which git owns; the prose under them is fine |
| 7 | Flip the design-doc linkage: drop bare `§N` refs, add a code map to ARCHITECTURE.md | P1 | 423 inline `§N` refs invert the direction all 15 Apple repos use; docs should point at code, code should be self-contained |
| 8 | `DeferredApprovalParker` — keep as-is | P3 | The TurnRunner ⇄ ApprovalWaiter cycle is already broken the way Apple breaks cycles; recorded so the owner knows it was examined |

---

## Proposal 1 — Extract the environment loader and a `DaemonBuilder` from `RunCommand`

**Priority: P1**

**Problem.** All service-graph wiring lives on the `RunCommand` type: `run()`
(`Sources/clawd/Subcommands/RunCommand.swift:21-85`) plus a 606-line
`Sources/clawd/Subcommands/RunCommand+Composition.swift` holding `DaemonDependencies` (:20-29),
`makeDaemon(deps:)` (:33-99), the `TurnCoordination` (:120-126) and `ApprovalFabric` (:130-134)
fixtures, 11 `make*` builders, and the boot-sequence block — the entire graph as extensions of a
CLI command. Meanwhile `DoctorCommand` independently re-implements the environment preamble:
`AppConfig.load` (`Sources/clawd/Subcommands/DoctorCommand.swift:31`), secret resolution
(`DoctorCommand.swift:43,121`), `ClawDatabase.openStores` (`DoctorCommand.swift:102`) — the same
steps `RunCommand`'s private `*OrExit` helpers perform (`RunCommand.swift:88-180`). Two commands,
two copies of "load config, resolve secrets, open stores"; they will drift.

**Evidence.** `container`, the closest clawd analog, wires its daemon in exactly one place —
[`APIServer.Start.run()`](https://github.com/apple/container/blob/5973b9cc626a3e7a499bb316a958237ebe14e2ed/Sources/APIServer/APIServer+Start.swift#L51)
(`container Sources/APIServer/APIServer+Start.swift:51-175`), a plain function decomposed into
named `initialize*` helpers (:61-97, 274-312), attached to the daemon entry point, with no
per-module assemblies and no DI framework; its *other* subcommands never re-implement environment
setup — they self-wire only cheap stateless clients (`container
Sources/ContainerCommands/Container/ContainerCreate.swift:90`). argument-parser encodes the same
separation: the framework owns composition in `main()` and `run()` is a leaf
(`swift-argument-parser Sources/ArgumentParser/Parsable Types/ParsableCommand.swift:159,47`); a
persistent daemon legitimately inverts the leaf rule (its `run()` owns the graph), but declaration,
wiring, and work stay separated phases. See synthesis §3.1–§3.4.

**Proposed change.** Keep the single centralized composition root — no per-module assemblies, no
separate composition target, no DI framework. Two extractions, both inside the `clawd` target:

1. **A shared environment loader.** New `Sources/clawd/Bootstrap/EnvironmentLoader.swift`: an
   `enum EnvironmentLoader` of static throwing step functions (`loadConfig`, `loadSecrets`,
   `openStores`, `ensureWorkspaceDir`) plus a convenience `loadAll() throws -> DaemonEnvironment`
   (a struct bundling config, secrets, stores, workspace dir). `run` calls `loadAll` through thin
   `*OrExit` wrappers that keep their current exit-code mapping; `doctor` calls the step functions
   individually so it can keep reporting per-row diagnostics. One implementation of each step,
   two presentations.
2. **A `DaemonBuilder`.** Move everything now in `RunCommand+Composition.swift` onto a
   `struct DaemonBuilder` in `Sources/clawd/Composition/`, whose stored properties are what
   `DaemonDependencies` carries today and whose `build()` is `makeDaemon`. Organize the builders
   by subsystem as extension files: `DaemonBuilder+Agent.swift` (makeProvider, makeAgentStack,
   makeContextBuilder, makeAgent), `DaemonBuilder+Approvals.swift` (TurnCoordination,
   ApprovalFabric, makeApprovalFabric, makeTurnRunner), `DaemonBuilder+Schedule.swift`
   (makeScheduleSurface, makeScheduler), `DaemonBuilder+Intake.swift` (makeIntakeServices,
   makeToolDispatcher, policyStaticSubhash), `DaemonBuilder+Boot.swift` (bootSequence,
   registerMenuCommands, bootReconcile, bootReconcileApprovals). Keep the `make*` names — they are
   established here; `container`'s `initialize*` verbs also register into a route table, which
   these do not.

`RunCommand` keeps argument parsing and lifecycle: load environment, build HTTP/Telegram clients,
`DaemonBuilder(...).build()`, `daemon.run()`, shutdown.

**KISS / YAGNI / SOLID.** The command type currently has two responsibilities (CLI surface and
object-graph assembly); the split restores single responsibility without adding machinery. A DI
container, a registry, or protocolizing `DaemonBuilder` for mock injection would violate YAGNI —
the builder is exercised by every daemon boot and by the existing integration tests; none of the 15
Apple repos uses a DI framework (synthesis §9.1). Going further — per-module assemblies or a
dedicated composition *target* — would scatter the one place the graph is legible, which is
exactly what `container` avoids.

**Blast radius.** `Sources/clawd/` only: `RunCommand.swift`, `RunCommand+Composition.swift`
(dissolved into the new files), `DoctorCommand.swift`, possibly `Clawd.swift`. No library target
changes. ARCHITECTURE.md §3 already describes `clawd` as "Thin entry: load config + secrets →
acquire startup lock → build ServiceGroup → run" — this moves the code *toward* the spec. No spec
change.

**Priority rationale.** P1 — the composition file grows with every increment and the run/doctor
duplication is live drift; cheapest to fix before the next subsystem lands.

---

## Proposal 2 — Adopt the stdlib `Clock` for pacing seams

**Priority: P2**

**Problem.** Time is injected as ad-hoc closure pairs: `now: @Sendable () -> Date` at ~13 sites
(`Sources/ClawAgent/Context/ContextBuilder.swift:30`,
`Sources/ClawGateway/Routing/TurnRunner.swift:47`,
`Sources/ClawGateway/Services/ApprovalExpiryService.swift:23`,
`Sources/ClawGateway/Services/Heartbeat/SchedulerService.swift:25`, …) and
`sleep: @Sendable (Duration) async throws -> Void` at ~7 sites
(`Sources/ClawAgent/Runtime/StreamingTurnRuntime.swift:46`,
`Sources/ClawAgent/Runtime/AgentRuntime.swift:76`,
`Sources/ClawTools/Policy/ToolPolicyGate.swift:297`, …), composed as `{ Date() }` /
`{ try await Task.sleep(for: $0) }` at the root
(`Sources/clawd/Subcommands/RunCommand+Composition.swift:140-142`). One seam diverges:
`Sources/ClawLLM/Provider/OpenAICompatibleProvider.swift:11-12` takes `sleep` as seconds-as-`Double`
plus a lone `jitter: @Sendable (Double) -> Double` closure — the only `Double`-typed sleep and the
only jitter seam in the codebase. The stdlib `Clock` protocol is used nowhere.

**Evidence.** swift-async-algorithms defines no bespoke time seam: every time-based operator takes
a stdlib `Clock` and touches time only via `clock.now` / `clock.sleep`
([`AsyncTimerSequence.swift:14-15,35-44`](https://github.com/apple/swift-async-algorithms/blob/3da39bbc4e687d4192af7c9cf4eab805745a0b9c/Sources/AsyncAlgorithms/AsyncTimerSequence.swift#L14));
the real clock enters only through convenience overloads (`where C == SuspendingClock`,
:77-85), and tests inject a deterministic `ManualClock: Clock`
(`swift-async-algorithms Tests/AsyncAlgorithmsTests/Support/ManualClock.swift:14,185-209`) — zero
real waiting. swift-log shows why the clock must stay injected rather than bootstrapped: its
process-global `LoggingSystem.bootstrap` needs a `bootstrapInternal(validate: false)` back-door
just so its own test suite can re-bootstrap (`swift-log Sources/Logging/LoggingSystem.swift:29-58,
78-96`); parallel tests want different, isolated clocks. For randomness, swift-algorithms threads a
seedable `RandomNumberGenerator` parameter through its pure algorithms
(`randomSample(count:using:)`). See synthesis §7.

**Proposed change.** One rule: **`Clock` for pacing, the `Date` closure for wall-clock domain
timestamps.**

- Every `sleep:` closure seam becomes a stored `let clock: any Clock<Duration>`, sleeping via
  `clock.sleep(for:)`. Use the existential, not a generic parameter: async-algorithms goes generic
  for zero-cost library composition, but generifying `TurnRunner`, `AgentRuntime`, and every
  service over `<C: Clock>` would propagate type parameters through the whole graph for a daemon
  that sleeps in seconds — the existential is the KISS shape here. `ContinuousClock()` is supplied
  only at the composition root.
- Seams whose `now` exists purely for pacing arithmetic (elapsed-time, deadline math alongside a
  `sleep`) drop the `now:` closure and use `clock.now` instants.
- Seams whose `now()` mints wall-clock timestamps that are persisted or compared against persisted
  `Date`s (run rows, approval expiry, scheduler due-times) **keep** `now: @Sendable () -> Date`.
  The stdlib ships no wall clock — `ContinuousClock`/`SuspendingClock` instants are not `Date`s —
  and inventing a bespoke `WallClock` conformance is exactly the abstraction async-algorithms
  refused to build.
- Fix `OpenAICompatibleProvider` regardless of the rest: its backoff sleep is pure pacing, so it
  takes the clock seam and drops the `Double` seconds. For jitter, **keep a closure**, retyped
  `jitter: @Sendable (Duration) -> Duration`. A seedable `RandomNumberGenerator` seam is the wrong
  shape here: swift-algorithms threads its RNG as an `inout` parameter through pure functions,
  which a long-lived `Sendable` provider cannot do without wrapping mutable generator state in a
  lock — ceremony that buys nothing over a scripted closure in tests.
- Add a `ManualClock` (modeled on async-algorithms') to a shared test-support target so the
  Gateway/Agent/LLM suites stop scripting sleep closures individually — first-class test-support
  targets are the corpus norm (NIOEmbedded, `_CollectionsTestSupport`; synthesis §10).

**KISS / YAGNI / SOLID.** The stdlib protocol replaces two hand-rolled closure conventions with the
seam Apple converged on — dependency inversion with a vocabulary type. Over-applying it breaks
things in both directions: forcing the `Date`-minting sites onto a fake wall-clock conformance
would misrepresent domain timestamps as scheduling, and a process-global bootstrapped clock would
fight parallel test isolation (swift-log's own back-door is the warning — "bootstrap for logging,
inject for time").

**Blast radius.** ~20 constructor signatures across ClawAgent, ClawGateway, ClawTools, ClawLLM,
plus the composition sites in `RunCommand+Composition.swift` and the affected test doubles; one new
test-support target for `ManualClock`. ARCHITECTURE.md is silent on the time-injection shape — no
spec change. TESTING.md's determinism posture (no sleep-sync) is unaffected and served better.

**Priority rationale.** P2 — mechanical and worthwhile; the `Double`-vs-`Duration` divergence is
the only live wart, the rest is convergence on a standard seam.

---

## Proposal 3 — Move `WorkspaceReading` into ClawCore

**Priority: P1**

**Problem.** ARCHITECTURE.md §3 draws a layered DAG in which siblings depend only on ClawCore, and
states the rule for stores: protocols in `ClawCore`, concrete `ClawData` injected at the root. The
persistence seams comply (~15 store protocols in `Sources/ClawCore/Persistence/Stores.swift`), but
the workspace seam does not: `WorkspaceReading` is declared inside the implementation module
(`Sources/ClawWorkspace/FileSystemWorkspace.swift:7`, with `FileSystemWorkspace: WorkspaceReading`
at :26). Consequence: `ClawAgent/Context/ContextBuilder.swift:22` types a dependency as
`any WorkspaceReading` but must `import ClawWorkspace` (line 2) to see it, and
`ClawGateway/Services/Heartbeat/SchedulerService.swift:23` likewise — both targets carry a
`Package.swift` edge to the concrete module purely to reach an abstraction. This is the only such
violation found in the audit.

**Evidence.** This is the NIOCore-vs-NIOPosix arrangement done backwards. NIO keeps the protocols
in the abstract module (`swift-nio Sources/NIOCore/Channel.swift:105`, `EventLoop.swift:246`),
which depends on no IO module; `NIOPosix` and `NIOEmbedded` point *up* at it (`swift-nio
Package.swift:64-116`), and the README states the intent: extension projects "should only need to
depend on NIOCore" (`README.md:28-29`). swift-log has the same shape in miniature (`LogHandler` in
the API target, handlers below it). See synthesis §4.2.

**Proposed change.** Move `WorkspaceReading` plus the value types its signatures need
(`WorkspaceFile`, `LoadedFile` — currently `Sources/ClawWorkspace/LoadedFile.swift`) into
`Sources/ClawCore/Workspace/`. `ClawWorkspace` keeps only `FileSystemWorkspace` (and its
Yams-backed parsing), injected at the composition root. Drop the `ClawWorkspace` dependency edges
from `ClawAgent` and `ClawGateway` in `Package.swift` and delete the two imports — after which the
package graph *enforces* the rule the spec draws. Record the convention explicitly (one sentence in
§3 suffices): **seams in ClawCore, implementations in siblings, injected at `clawd`.** The store
seams already comply; this was the single violation.

**KISS / YAGNI / SOLID.** Straight dependency inversion, restoring the module boundary the spec
already claims. Over-applying it would mean either a separate `ClawWorkspaceCore` target (a target
is earned by a dependency/stability/audience boundary — ClawCore already *is* the abstract module;
synthesis §4.1) or dragging all of ClawWorkspace's parsing types into ClawCore, which would pull
Yams toward the pure core. Move only the seam and the value types it mentions. Keep the 10-target
split exactly as it is.

**Blast radius.** `Package.swift` (two dependency edges removed), two import lines, two or three
file moves into `Sources/ClawCore/Workspace/`. ARCHITECTURE.md §3: add `WorkspaceReading` to
ClawCore's protocol list in the module table — a clarification that brings the table in line with
the diagram the section already draws, not a contradiction. No SPEC CHANGE beyond that one-row
edit.

**Priority rationale.** P1 — small, mechanical, and it converts a stated architectural rule into a
compiler-checked one.

---

## Proposal 4 — Split `Stores.swift` by domain and the `Routing/` folder by subsystem

**Priority: P2**

**Problem.** Two structural outliers against an otherwise healthy file profile (142 files, median
102 LOC, p90 331). First, `Sources/ClawCore/Persistence/Stores.swift` packs ~15 unrelated store
protocols plus their result structs into one 486-line file (AllowlistStore, ProcessedUpdateStore,
CommandStore, MemoryStore, MemoryCommandStore, ScheduleCommandStore, Retriever, UpdateCursorStore,
SessionMessageStore, RunStore, ApprovalStore, UsageStore, OutboxStore, AuditLog,
ScheduledJobStore). Second, `Sources/ClawGateway/Routing/` is a 19-file folder mixing four
subsystems: message routing, the approval fabric, the schedule surface, and turn execution.

**Evidence.** The corpus norm is one primary type per file with `Type+Concern.swift` satellites
(`OrderedDictionary` spans 18 files; nio fragments `ByteBuffer` by aspect; swift-log carves
`Logger+With.swift` off its hub) and directory-per-subsystem inside a target (nio `AsyncChannel/`,
async-algorithms `Debounce/`/`Merge/`, network-evolution `QUIC/`/`Endpoint/`). Tightly-coupled
clusters may share a file — nio's `Channel.swift` holds the protocol plus its error enum. Large
files are fine when they hold *one* coherent type: `swift-system Sources/System/Errno.swift` is
1573 lines of ~100 documented constants. See synthesis §4.5.

**Proposed change.** Split `Stores.swift` into per-domain files under
`Sources/ClawCore/Persistence/`, each holding one store family plus the result structs that belong
to it (the nio protocol-plus-its-types cluster rule, not 15 micro-files):
`RunStore.swift`, `SessionMessageStore.swift`, `ApprovalStore.swift`, `ScheduledJobStore.swift`
(with `ScheduleCommandStore`), `MemoryStores.swift` (MemoryStore, MemoryCommandStore, Retriever),
`IntakeStores.swift` (AllowlistStore, ProcessedUpdateStore, UpdateCursorStore),
`CommandStore.swift`, `UsageStore.swift`, `OutboxStore.swift`, `AuditLog.swift`. Split
`Sources/ClawGateway/Routing/` into four subfolders:

- `Routing/` — AccessControl, CommandHandlers, HeartbeatAck, MessageRouter, ReplySender
- `Approval/` — ApprovalCallbackHandler, ApprovalCoordinator, ApprovalWaiter,
  ApprovedActionExecutor, ConfirmationResolver, PendingConfirmationRegistry
- `Schedule/` — ScheduleDraftParser, ScheduleHandlers, ScheduleSurface
- `Turn/` — BudgetBreaker, TurnDispatch, TurnEnqueuer, TurnRunner, TurnRunner+Payloads

Do **not** split the big single-type files (`TurnRunner.swift` 702 — already carrying a
`+Payloads` satellite — `AgentRuntime.swift` 688, `ScheduledJobStoreGRDB.swift` 682) for line count
alone; each holds one coherent type, which the corpus explicitly tolerates.

**KISS / YAGNI / SOLID.** Pure interface-segregation housekeeping: a reader opening "the approval
subsystem" should get a folder, not a grep. Over-applying it — one file per protocol regardless of
coupling, or promoting the subfolders into new SwiftPM targets — would trade one navigation problem
for fifteen tiny files and a heavier package graph (a target is earned by a boundary, not a
folder; synthesis §4.1).

**Blast radius.** File moves and splits only; no API, no behavior, no test changes (SwiftPM globs
sources per target). ARCHITECTURE.md does not dictate file layout — no spec change.

**Priority rationale.** P2 — worthwhile navigation and review-diff hygiene, no correctness stakes.

---

## Proposal 5 — Consolidate the error taxonomy under `ClawCore/Errors/` and type the store seam

**Priority: P2**

**Problem.** Spec §19 says "a top-level error taxonomy lives in `ClawCore`" — it does, but
physically scattered and partly mis-filed: `StoreError` and `TelegramError` (persistence and
transport errors) sit with `ConfigError` and `ClawExitCode` under
`Sources/ClawCore/Config/Errors.swift` — a `Config/` folder — while `ProviderError` sits inside
`Sources/ClawCore/LLM/LLM.swift:130`. `PolicyDenied` and `BudgetExhausted`, named in §19, are not
yet defined (future increments) and currently have no natural place to land.

**Evidence.** Apple co-locates the taxonomy deliberately: containerization gives
`ContainerizationError` its own zero-dependency target so every module can throw it
(`containerization Package.swift:57-59`), shaped as `{ code, message, cause: (any Error)? }`
(`ContainerizationError.swift:23-41`); swift-async-dns-resolver keeps per-backend classifiers
beside their backends. swift-system's newest code carries the type in the signature —
`public init(…) throws(Errno)` (`swift-system Sources/System/FileSystem/Stat.swift:104-111`). The
cautionary counterexample is `container`'s XPC boundary, where a stringly wire error forces the
server to sniff type-name strings
([`XPCServer.swift:232-241`](https://github.com/apple/container/blob/5973b9cc626a3e7a499bb316a958237ebe14e2ed/Sources/ContainerXPC/XPCServer.swift#L232))
— the argument for keeping errors typed end-to-end. See synthesis §6.3–§6.4.

**Proposed change.** Create `Sources/ClawCore/Errors/` with one file per family —
`StoreError.swift`, `TelegramError.swift`, `ProviderError.swift`, `ConfigError.swift`,
`ClawExitCode.swift` — and land `PolicyDenied`/`BudgetExhausted` there when their increments
arrive. (Chosen over `Domain/Errors/`: the taxonomy is cross-cutting per §19, not owned by one
domain area; a top-level group says so.) Additionally, adopt Swift 6 typed throws on the store
seam: the store protocols and `writeMapping`/`readMapping` become `throws(StoreError)`. The
project already holds this contract by convention — CLAUDE.md: "a raw `DatabaseError` must never
leak past a store," enforced today by `ClawDatabase.classifyError`
(`Sources/ClawData/Database/ClawDatabase.swift:261`) — typed throws makes the compiler hold it
instead. Keep `classifyError` exactly as it is; it is the Errno-style seam done right. Defer a
`cause` chain: containerization needs one because errors cross process boundaries; swift-claw's
buckets are consumed in-process by the retry classifier, and widening `StoreError` can wait for a
demonstrated debugging gap.

**KISS / YAGNI / SOLID.** Co-location plus a compiler-enforced boundary contract, nothing new
invented. Over-applying: a dedicated zero-dep error *target* (containerization's move) is external-
consumer packaging — ClawCore already is the zero-dep leaf; and spreading typed throws across every
service protocol would be premature — only the store seam has a single-classified-type guarantee
today, so only it earns the signature.

**Blast radius.** ClawCore file moves; `throws(StoreError)` touches the store protocol
declarations (currently `Stores.swift`; after Proposal 4, the per-domain files), the `ClawData`
implementations, and any `catch` sites that can narrow. §19 needs no edit — the proposal makes the
stated placement physical; at most one optional clarifying phrase ("under `ClawCore/Errors/`"). No
SPEC CHANGE.

**Priority rationale.** P2 — the relocation is trivial; typed throws is a moderate mechanical
sweep that converts a prose rule into a compile error.

---

## Proposal 6 — Strip process tags from comments; sharpen the comment rule

**Priority: P2**

**Problem.** By volume swift-claw *under*-comments: density 13.3 comment-lines/100 code-lines
versus 35–64 for every Apple library and 25.8/21.8 for the two applications, with thin spots at
`ClawLLM` 4.6 and `ClawData` 7.1. The defect is content, not volume: comments are laced with
temporal and process artifacts — 12 `Inc N`, 19 `F<n>`, 3 `Task-N`, 12 `rev.1`, plus "NEW",
"review H2", "D3"/"D6" — concentrated in `Sources/ClawAgent/Runtime/AgentRuntime.swift` (~29 such
lines), `Sources/ClawCore/Persistence/Stores.swift` (~27),
`Sources/clawd/Subcommands/RunCommand+Composition.swift` (~17),
`Sources/ClawTools/Policy/ToolPolicyGate.swift` (17). Sampled lines show the pattern:
`case accountingFailed  // NEW (§6 — usage-write failure mid-run)`, `// recorded must stop being
spent (§6 — review H2.)`. The sentences carry real why/contract; the tags are change history,
which git already owns. CLAUDE.md states the right rule ("signal, not noise") — the code drifts
from its own convention.

**Evidence.** No Apple repo threads process or review artifacts through comments. What their
comments carry (synthesis §2.3): `///` states the contract, including what the signature cannot
express — nio's `EventLoop.inEventLoop` "is allowed to produce false-negatives … It may _never_
produce false positives" (`swift-nio Sources/NIOCore/EventLoop.swift:247-258`); `//` states the
non-obvious why — container justifying a 60-second timeout with "macOS can take 5 seconds (or
considerably longer) to launch a service" (`container Sources/ContainerXPC/XPCClient.swift:22-27`),
containerization justifying reflink-clone with the concrete cost of the naive copy
(`Mount.swift:138-149`). Even candid debt is prose, not tags (`swift-nio
Sources/NIOCore/SystemCallHelpers.swift:20-21`).

**Proposed change.** One sweep (shared with Proposal 7, which handles the `§N` coordinates on the
same lines): delete the temporal/process tags — `NEW`, `review H2`, `Task N`, `rev.1`, `Inc N`,
`D3`/`D6`, `F<n>` — keeping the sentence each one decorates. Then sharpen the CLAUDE.md comment
bullet with the two-line criterion the corpus supports: **`///` earns its place by stating contract
the signature can't express; `//` earns its place by stating a non-obvious why; change history
belongs to git, never to comments.** Separately, when touching `ClawLLM` and `ClawData`, add `///`
contracts to their public seams opportunistically — those two targets are the measured
under-commented floor.

**KISS / YAGNI / SOLID.** The rule already exists; this enforces it and makes it concrete.
Over-applying would mean chasing Apple *library* densities (swift-log's 64 is a tiny-API library
documenting for external consumers) or adding comments to hit a number — `container`'s 25.8 is the
application norm, and restatement comments are worse than none.

**Blast radius.** Comment lines only; zero behavior. One CLAUDE.md bullet edited. No spec change.

**Priority rationale.** P2 on its own, but it executes as the same pass as Proposal 7 — accepting
7 makes this nearly free.

---

## Proposal 7 — Flip the design-doc linkage: drop bare `§N` refs, add a code map to ARCHITECTURE.md

**Priority: P1**

**Problem.** `Sources/` threads 423 inline `§N` references through implementation comments (113 of
them in the `spec §N` phrasing) (top files: `Sources/ClawAgent/Runtime/AgentRuntime.swift`,
`Sources/ClawCore/Persistence/Stores.swift`, `Sources/ClawTools/Policy/ToolPolicyGate.swift`,
`Sources/ClawGateway/Routing/TurnRunner.swift`). Only ~10 use a resolvable full form like
`ARCHITECTURE §N` (`Sources/ClawWorkspace/LoadedFile.swift:19`,
`Sources/ClawCore/Domain/Tools/ToolContracts.swift:148,214`,
`Sources/ClawTools/Tools/FileWriteTool.swift:12,130`); a stranger cannot resolve a bare `§5.5` at
all. Section numbers rot as the spec is edited, and the linkage direction is code→doc: the spec
never points back at the code that implements it.

**Evidence.** This is the unanimous finding of the study (synthesis §2.2): all 15 repos, zero
internal design-doc section numbers in code. Where code cites anything, it cites stable *external*
canon — RFC numbers beside wire code (`swift-nio
Sources/NIOCore/ByteBuffer-quicBinaryEncodingStrategy.swift:16`), OCI spec permalinks pinned to a
line (`containerization LocalOCILayoutClient.swift:215`), C man-page symbols (`swift-system
Sources/System/Errno.swift:72-79`), GitHub issues as bug context (`swift-argument-parser
Sources/ArgumentParser/Parsing/CommandParser.swift:31`). Rationale that must sit beside code is
written self-contained into the symbol's own `///`
(`swift-collections Sources/OrderedCollections/OrderedDictionary/OrderedDictionary+Codable.swift:22-27`).
The durable link runs docs→code: DocC symbol links, guides opening with `Source | Tests` pointers
(`swift-algorithms Guides/Chunked.md:3-4`), proposal folders naming files. The greenfield floor
(synthesis §2.4): `swift-network-evolution` keeps ~13 inline citations in 70k lines, reserved for
spots where a constant or a mandated-but-unused case would otherwise read as a bug
(`case resetRead  // Not used, but part of RFC 9000.`, `QUICStreamState.swift:102`).

**Proposed change.** Three moves, with a concrete DROP / KEEP / RELOCATE rule for the existing 423
`§N` citations:

- **DROP** (the large majority): any `§N`/`spec §N` whose surrounding sentence already states the
  why or contract — delete the coordinate, keep the sentence. Sampled `AgentRuntime.swift` shows
  most citations are this kind: the prose is self-sufficient once the coordinate is gone.
- **KEEP, rewritten to the full form** `// ARCHITECTURE.md §N`: only where the code would
  otherwise read as a bug or dead weight without the map — the network-evolution floor. Concretely:
  spec-mandated constants (the 32 768-char `ReplySplitter` limit), FSM arms mandated by §19.1 but
  not yet exercised, the no-default-arm reduce rule, spec-pinned defaults like the 1h
  `approval_expiry`. Expect a dozen or two survivors, not hundreds.
- **RELOCATE**: where a `§` ref currently stands in for rationale absent from the comment, write
  that rationale into the symbol's `///`, self-contained, and drop the coordinate (Apple's
  mechanism 1, synthesis §2.2).
- **Flip the durable direction**: add a short **code map** section to ARCHITECTURE.md — per major
  section, the implementing types by stable symbol name and target (e.g. §5 per-session lane →
  `SessionLaneRegistry`, `TurnEnqueuer` (ClawGateway); §11 approvals → `ApprovalCoordinator`,
  `ApprovalWaiter`, `ApprovedActionExecutor`; §19 store seam → `ClawDatabase.classifyError`
  (ClawData)). Symbol names are refactoring-tracked; line numbers and section coordinates are not.
  This is the docs→code direction every Apple repo uses.

**Rejected within this proposal:** adopting DocC catalogs. No `.docc` exists in the repo, the
targets have no external consumers, and `docs/ARCHITECTURE.md` already serves as the single
architecture narrative — curated DocC Topics pages are library-publication machinery this project
does not need (YAGNI).

**KISS / YAGNI / SOLID.** The change removes a bespoke, rotting cross-reference scheme and replaces
it with prose that stands alone plus one table that names symbols. Over-applying would mean zero
pointers anywhere — network-evolution deliberately keeps the handful that prevent
"looks-like-a-bug" misreads, and so should swift-claw; building lint tooling to police `§` refs
would also be over-engineering — one sweep plus a stated convention suffices.

**Blast radius.** Comment-only edits across the ~30 files carrying citations (top offenders listed
above); one CLAUDE.md line stating the citation convention. **SPEC CHANGE:** ARCHITECTURE.md gains
the code-map section — an additive doc edit that alters no normative rule, flagged because the
spec file itself changes.

**Priority rationale.** P1 — the owner's sharpest objection, the study's most unanimous finding,
and every spec edit made today deepens the rot of 423 live coordinates.

---

## Proposal 8 — `DeferredApprovalParker`: keep as-is

**Priority: P3**

**Problem (assessment, not a defect).** The one construction cycle in the graph —
`TurnRunner` needs a `parker: any ApprovalParking` while `ApprovalWaiter` needs a
`turns: any TurnDispatching`, which `TurnRunner` conforms to
(`Sources/ClawGateway/Routing/TurnRunner.swift:30`,
`Sources/ClawGateway/Routing/ApprovalWaiter.swift:18,30`) — is already broken cleanly: narrow
protocols in both directions, a `DeferredApprovalParker` holding
`Mutex<(any ApprovalParking)?>` (`Sources/ClawGateway/Routing/ApprovalCoordinator.swift:79`)
late-bound exactly once via `adopt(_:)` (:84) at composition
(`Sources/clawd/Subcommands/RunCommand+Composition.swift:197`), plus an `InertApprovalParker`
null-object (:114) for phases with no ask-tier tool registered.

**Evidence.** No studied repo has this exact mutual cycle, but the general Apple idiom for late
binding is build-then-register: nio pipelines add handlers after the channel exists (`swift-nio
Sources/NIOTCPEchoServer/Server.swift:47-48`), and `container`'s root builds services then
registers their harness methods into the shared route table (`container
Sources/APIServer/APIServer+Start.swift:61-97`). See synthesis §8.

**Proposed change.** None. The parker is a contained instance of the corpus idiom — a settable
holder bound once at the root, with a null-object for the unbound phase. Replacing it (closure
injection, merging the two types, an event bus) would trade a legible seam for hidden ordering or
a larger type. Recorded so the owner knows the cycle was examined and judged sound.

**KISS / YAGNI / SOLID.** The existing shape *is* the KISS answer; any generalized "late-binding
container" utility built from it would be YAGNI.

**Blast radius.** None.

**Priority rationale.** P3 — note only; no work item.

---

## Out of scope / considered and rejected

- **Per-module assemblies or factory types in feature targets.** `container` deliberately keeps
  feature modules as parts-suppliers and lets the root wire them (synthesis §3.1); scattering
  assembly would make the graph illegible. Proposal 1 keeps one root.
- **A separate composition target.** The `clawd` executable target already is the composition
  boundary; a new target would add a package edge and nothing else.
- **Splitting the 10 targets further** (e.g. `ClawGatewayApproval`, a workspace-core target). A
  target is earned by a dependency/stability/audience boundary, not a feature or a folder
  (synthesis §4.1); none of the candidates crosses one. Proposal 4's subfolders give the
  navigation win without package-graph cost.
- **`@_spi` / underscore-prefix / `@usableFromInline` ceremony.** SemVer machinery for external
  consumers of a published API surface (synthesis §5). swift-claw's targets have one consumer:
  `clawd`. `internal` by default and `public` at target boundaries covers it.
- **DocC catalogs and curated Topics pages.** Rejected inside Proposal 7 — no `.docc` exists,
  no external audience, and ARCHITECTURE.md plus the proposed code map carry the linkage.
- **Globalizing the clock via a `bootstrap`.** swift-log's install-once global needs a
  `validate:false` test back-door in its own suite (synthesis §7.2); parallel tests want isolated
  clocks. Proposal 2 keeps the clock injected.
- **Rewriting the `DeferredApprovalParker`.** Examined and kept — Proposal 8.
- **A seedable `RandomNumberGenerator` seam for jitter.** Rejected inside Proposal 2: threading a
  mutating RNG through a `Sendable` provider needs a lock for no test benefit over a scripted
  closure.
- **Custom COW storage for domain values.** The corpus reserves hand-rolled `_Storage` for
  measured hot copies (synthesis §6.1); swift-claw's small `Sendable` structs are correct as-is.
- **Splitting `TurnRunner.swift` / `AgentRuntime.swift` / `ScheduledJobStoreGRDB.swift` by line
  count.** Each holds one coherent type; the corpus tolerates far larger single-type files
  (`Errno.swift` 1573). Stated inside Proposal 4.
- **A `cause` chain on `StoreError` today.** Deferred inside Proposal 5 — motivated in
  containerization by cross-process error transport, which swift-claw does not do.
- **An evolution-proposal process (SLG-/`Evolution/`-style).** Decision history for a single-owner
  app lives in PRs and git history; a proposal folder is coordination machinery for a contributor
  ecosystem.
