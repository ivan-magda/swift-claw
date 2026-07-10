# Apple OSS engineering practices — a 15-repo synthesis

| | |
|---|---|
| **Status** | Research synthesis (durable) |
| **Date** | 2026-07-10 |
| **Owner** | Ivan Magda |
| **Related** | [`ARCHITECTURE.md`](../ARCHITECTURE.md) (normative spec) · forthcoming: `swift-claw-refactoring-proposals.md` (point-in-time proposals derived from this synthesis) |

> **What this is.** A durable reference on how Apple engineers organize Swift code, distilled from
> 15 Apple open-source repositories and backed by file-level citations. It describes the patterns;
> it does not prescribe swift-claw changes (those live in the separate proposals document).
>
> **The caveat that governs every takeaway:** 13 of the 15 repos are libraries or frameworks;
> swift-claw is an **application** with library-like targets. Library practice (API surface, module
> granularity, value types, typed errors, comment discipline) transfers to swift-claw's library-like
> targets. Application practice (composition, process layout, service lifecycle) comes from
> `container`, from example/executable code inside the library repos (NIO's server examples,
> containerization's `cctl`, argument-parser's `Examples/`), and from how those libraries expect an
> app to bootstrap them. Every section below applies the filter "library problem or application
> problem?" and says so where it matters.

---

## 1. Method & corpus

Each repository was shallow-cloned at its latest release tag (or `main` HEAD where noted), read by
one dedicated reviewer against a fixed question set (organization, architecture, responsibility
separation, data models & errors, comments & doc linkage, principles, testing/CI), and the resulting
notes were spot-checked against source before synthesis. Comment density was measured mechanically
over `Sources/` only, excluding tests and generated `.pb.swift` files. Citations below use
`repo path:line` at the studied revision (permalink bases in §12); load-bearing claims carry full
permalinks. A claim that could not be pinned to a file was dropped.

| Tier | Repo | Tag | SHA | What it is |
|---|---|---|---|---|
| 1 | container | 1.1.0 | `5973b9cc626a` | Swift CLI + long-lived launchd daemon(s) on macOS (closest clawd analog) |
| 1 | containerization | main-HEAD | `2f947e76143c` | The framework under `container`; multi-target library |
| 1 | swift-nio | 2.101.2 | `cd3e11520837` | Event-driven networking; NIOCore/NIOPosix/NIOEmbedded layering |
| 1 | swift-argument-parser | 1.8.2 | `6a52f3251125` | The CLI library clawd stands on |
| 1 | swift-log | 1.14.0 | `a878e7f8f46c` | `LogHandler` protocol + `LoggingSystem.bootstrap` |
| 2 | swift-http-types | 1.6.0 | `db774a277f60` | Small value-type wire API; COW |
| 2 | swift-async-algorithms | 1.1.5 | `3da39bbc4e68` | Async-sequence composition; stdlib `Clock` as injected time source |
| 2 | swift-collections | 1.6.0 | `a0cb0954ecb2` | Multi-module package layout at scale |
| 2 | swift-system | 1.7.4 | `b5544ba79a70` | Typed errors over an unsafe C layer (`Errno`) |
| 2 | swift-protobuf | 1.38.1 | `55d7a1cc5666` | Codegen/runtime split |
| 3 | swift-algorithms | 1.2.1 | `87e50f483c54` | API Design Guidelines + `Guides/` design docs |
| 3 | swift-atomics | 1.3.1 | `0442cb5a3f98` | Tiny sharp-edged API |
| 3 | swift-async-dns-resolver | 0.7.1 | `e145f21e97cc` | Small C-wrapping package; async bridging |
| 3 | swift-network-evolution | 0.1.0 | `6fb079faf120` | Apple greenfield networking stack (early) |
| 3 | coreai-models | main-HEAD | `f9e935769039` | Mixed Python/Swift; Swift runtime package only |

Full SHAs and permalink bases: §12.

---

## 2. Comment density & design-doc linkage

This is the sharpest finding of the study, so it leads. Two separate questions, two separate
answers: how *much* Apple comments, and how Apple *links* code to design documents.

### 2.1 Volume: swift-claw under-comments relative to Apple

Density = comment lines per 100 code lines; docshare = % of comment lines that are `///` doc
comments. Measured over `Sources/` only, excluding tests and generated code.

| Codebase | Density | Docshare | Kind |
|---|---|---|---|
| swift-log | 64.4 | 84% | library (tiny API) |
| swift-algorithms | 59.8 | 74% | library |
| swift-collections | 53.4 | 70% | library |
| swift-system | 42.3 | 75% | library |
| swift-http-types | 40.6 | 73% | library |
| swift-argument-parser | 38.2 | 72% | library |
| swift-nio | 35.5 | 69% | library |
| swift-protobuf | 35.2 | 54% | library (codegen) |
| swift-async-algorithms | 28.8 | 53% | library |
| swift-atomics | 25.9 | 80% | library |
| container | 25.8 | 26% | **application** |
| coreai-models | 25.4 | 63% | mixed |
| swift-async-dns-resolver | 22.6 | 54% | library |
| containerization | 21.8 | 36% | library/framework |
| swift-network-evolution | 10.6 | 20% | greenfield |
| **swift-claw** | **13.3** | **73%** | **application (this project)** |

swift-claw's 13.3 sits below every Apple *library* and below both applications (`container` 25.8,
`containerization` 21.8); only the greenfield `swift-network-evolution` (10.6) is lower. Per-target
the spread is wide: ClawCore 16.8 (docshare 91%), ClawWorkspace 24.0, ClawGateway 17.3, but ClawLLM
4.6 and ClawData 7.1. So whatever problem swift-claw's comments have, it is **not over-commenting by
volume** — by Apple's norms the codebase under-comments, especially in its implementation targets.

The anomaly is content: swift-claw's `Sources/` carries **423 inline `§N` references**, 113
`spec §`, plus process tags (`Inc N`, `F<n>`, `Task-N`, `rev.1`, "review H2", "NEW") threaded through
implementation comments, concentrated in `AgentRuntime.swift` (~29), `Stores.swift` (~27),
`RunCommand+Composition.swift` (~17), `ToolPolicyGate.swift` (17). Only ~10 use the resolvable
`ARCHITECTURE.md §N` form (e.g. `LoadedFile.swift:19`, `ToolContracts.swift:148`); a stranger cannot
resolve a bare `§5.5`. No Apple repo does anything like this.

### 2.2 The unanimous counter-practice: zero internal section numbers in code

All 15 repos agree, without exception: **code never threads internal design-doc section numbers
through comments.** The link runs the other direction — docs point at code (DocC symbol links,
evolution proposals, guides with `Source | Tests` headers) — and where code cites anything, it cites
only *stable external identifiers*: RFC numbers, spec URLs, C symbols, or a GitHub issue as bug
context. Rationale that must sit next to code is written into the symbol's own `///` doc,
self-contained.

| Repo | Internal `§`/section refs in Sources | What the code cites instead | Citation |
|---|---|---|---|
| swift-nio | 0 | External RFCs beside wire code: "encodes bytes as defined in RFC 9000 § 16" ([`ByteBuffer-quicBinaryEncodingStrategy.swift:16`](https://github.com/apple/swift-nio/blob/cd3e1152083706d77b223fb29110e590efcc70c0/Sources/NIOCore/ByteBuffer-quicBinaryEncodingStrategy.swift#L16)); per-protocol RFC numbers in `IPProtocol.swift:15-153`; only 4 `<doc:>` links in all of NIOCore | `Sources/NIOCore/Docs.docc/index.md:24-45` links symbols doc→code |
| swift-argument-parser | 0 | Three GitHub issue numbers as bug context (`#578`, `#327`, `#434`) | [`Parsing/CommandParser.swift:31`](https://github.com/apple/swift-argument-parser/blob/6a52f3251125d74daf04fcbd5e6f08a75d074382/Sources/ArgumentParser/Parsing/CommandParser.swift#L31); `Parsing/ArgumentSet.swift:443,448` |
| swift-http-types | 0 | RFC URLs on validation code (65 refs in `HTTPFieldName.swift` alone) | [`Sources/HTTPTypes/HTTPField.swift:91-93`](https://github.com/apple/swift-http-types/blob/db774a277f60063a32d854f2980299caf06da041/Sources/HTTPTypes/HTTPField.swift#L91) |
| containerization | ~11 (vs swift-claw's 423) | OCI spec URLs, including a *pinned permalink with a line anchor* (`…image-layout.md?plain=1#L175`) | `Descriptor.swift:17` (source-URL header); `LocalOCILayoutClient.swift:215` |
| container | 0 | Nothing — grep for `docs/`, `§`, `technical-overview` over `Sources/**.swift` returns zero; `docs/technical-overview.md` describes the code one-way, unpinned | `docs/technical-overview.md:43-47` |
| swift-log | 0 | Nothing inline; SLG-NNNN proposal docs link out to the issue and implementing PR | `Docs.docc/Proposals/SLG-0005-…md:11-19` |
| swift-collections | 0 | A DOI hyperlink to the min-max-heap paper; rationale otherwise inlined in `///` | `Sources/HeapModule/Heap.swift:26-34` |
| swift-system | 0 | The C man-page symbol it mirrors ("The corresponding C error is `EINTR`."); code→DocC symbol links | [`Sources/System/Errno.swift:72-79`](https://github.com/apple/swift-system/blob/b5544ba79a70a0cb3563e75bf26dc198d6b40ed3/Sources/System/Errno.swift#L72); `FileDescriptor.swift:109` |
| swift-protobuf | 0 | 27 links to the external wire spec (protobuf.dev); `INTERNALS.md` self-disclaims: "this is not a contract … probably already out of date" | `Documentation/INTERNALS.md:9-16` |
| swift-async-algorithms | 0 | Nothing; the DocC guide links `[Source](…) \| [Tests](…)` at the top | `Sources/AsyncAlgorithms/AsyncAlgorithms.docc/Guides/Debounce.md:5-8` |
| swift-algorithms | 0 | Nothing; each `Guides/*.md` design doc opens with Source + Tests links | `Guides/Chunked.md:3-4` |
| swift-atomics | 0 | Stable external names: "corresponds to `std::memory_order_relaxed` in C++"; SE-0282; a GitHub issue URL in a doc comment | `Sources/Atomics/Types/AtomicMemoryOrderings.swift:33-34`; `Protocols/AtomicReference.swift:65` |
| swift-async-dns-resolver | 0 | The upstream C header ("See `arpa/nameser.h`.") and reference-implementation URLs | `Sources/AsyncDNSResolver/c-ares/DNSResolver_c-ares.swift:96,188` |
| swift-network-evolution | 3 "Section N" in ~70k lines | Terse RFC pointers only at genuinely non-obvious wire points (see §2.4) | `Sources/SwiftNetwork/Utilities/UInt64+VLE.swift:32,52` |
| coreai-models | 0 | Outward links to *named* Markdown files ("See models/README.md#compiled-models") | `ModelBundle.swift:108`; `InstrumentsProfiler.swift:440` |

Three distinct mechanisms carry design rationale instead of section threading:

1. **The symbol's own `///` doc.** Where rationale must be adjacent to code, Apple writes it
   in-place, self-contained. `OrderedDictionary`'s Codable doc explains *why* it encodes as an
   unkeyed array ("`Codable`'s keyed containers do not guarantee that they preserve the ordering …
   JSON's 'object' construct is explicitly unordered",
   `Sources/OrderedCollections/OrderedDictionary/OrderedDictionary+Codable.swift:22-27`); `Heap`'s
   header explains why it refuses `Sequence` conformance (`Heap.swift:44-61`).
2. **Docs that point at code.** DocC articles reference symbols with double-backtick links
   (nio `Docs.docc/index.md:24-45`; argument-parser deep-links a specific overload,
   ``ParsableArguments/validate()-5r0ge``, in `Documentation.docc/Articles/Validation.md`);
   swift-algorithms' `Guides/` and async-algorithms' `Evolution/` proposals carry the rationale and
   cite the source files.
3. **Versioned proposal folders** for decision history: swift-log's `SLG-NNNN` process
   (`Docs.docc/Proposals/Proposals.md:1-40`), swift-system's `Proposals/0006-system-stat.md`,
   async-algorithms' `Evolution/0001…0018`. The record is prose that names code; the code never
   names the record's coordinates.

> The invariant, stated once: **the durable pointer lives in the doc, aimed at the stable
> file/type/symbol name; the code carries self-contained why/contract and cites only external canon.**
> Section numbers rot as the spec is edited; symbol names are refactoring-tracked. swift-claw's
> current direction (code → `§N` of a moving internal spec) is the inverse of all 15 repos.

### 2.3 What Apple comments carry

The high densities in §2.1 are not narration. Across the corpus, `///` doc comments carry the
**contract** (including what the signature cannot express) and `//` inline comments carry the
**non-obvious why**; restatement is effectively absent. Representative, attributed samples:

- Contract with a correctness caveat — swift-nio, `EventLoop.inEventLoop`:
  > "is allowed to produce false-negatives … It may _never_ produce false positives."
  (`Sources/NIOCore/EventLoop.swift:247-258`)
- Why behind a magic number — container, justifying `xpcRegistrationTimeout = .seconds(60)`:
  > "macOS can take 5 seconds (or considerably longer) to launch a service after it has been
  > registered." (`Sources/ContainerXPC/XPCClient.swift:22-27`)
- Operational why on an optimization — containerization, `Mount.clone(to:)`, explaining
  reflink-vs-naive copy: a plain copy
  > "would inflate a ~50 MB alpine rootfs into a fully-allocated 2 GiB clone and exhaust the
  > integration suite's writable layer in ~30 tests." (`Mount.swift:138-149`)
- One-line design why — swift-log, on the class-inside-struct box:
  > "// The storage implements CoW to become Sendable" (`Sources/Logging/Logger.swift:28`)
- Candid debt, not hidden — swift-nio, on the IO leak in its pure core:
  > "This file arguably shouldn't be here in NIOCore, but due to early design decisions we
  > accidentally exposed a few types that know about system calls into the core API (looking at
  > you, FileHandle)." ([`SystemCallHelpers.swift:20-21`](https://github.com/apple/swift-nio/blob/cd3e1152083706d77b223fb29110e590efcc70c0/Sources/NIOCore/SystemCallHelpers.swift#L20))

Notably, the *sentences* in swift-claw's flagged comments already meet this bar — sampled
`AgentRuntime.swift` comments do carry why/contract ("Per-round-trip preflight (§6.2): day totals at
run start + everything this run recorded.") — it is the leading/trailing `§` coordinates and the
temporal process tags (`// NEW (§6 — usage-write failure mid-run)`, `// §6 — review H2`) that no
Apple repo carries. swift-claw's own CLAUDE.md rule ("Comments: signal, not noise — explain
non-obvious why/contract") matches Apple practice; the drift is in the citation habit, not the
prose.

### 2.4 The greenfield floor

`swift-network-evolution` — a 70k-line QUIC/UDP/IP stack at 0.1.0, density 10.6 — shows the
*minimum* Apple considers acceptable and where the few inline citations go: **reserve an inline spec
citation for the places where a constant or a mandated-but-unused case would otherwise read as a
bug.** The whole stack has ~13 RFC mentions and 3 "Section N" occurrences: `// RFC 9000 Section 16`
above the varint codec (`Sources/SwiftNetwork/Utilities/UInt64+VLE.swift:32,52`), and
`case resetRead  // Not used, but part of RFC 9000.`
(`Sources/SwiftNetwork/QUIC/QUICStreamState.swift:102`). Everywhere else the code is expected to
read on its own. That is the floor; the library norm (§2.1 table) is far richer `///` contract
documentation on the public surface.

---

## 3. Composition & application wiring

This is application territory. The evidence comes from `container` (the closest clawd analog),
from argument-parser's own lifecycle design, and from how NIO and containerization expect an
executable to bootstrap them.

### 3.1 One centralized composition root per process — a plain function, not a framework

`container`'s daemon wires its entire object graph in one method:
[`APIServer.Start.run()`](https://github.com/apple/container/blob/5973b9cc626a3e7a499bb316a958237ebe14e2ed/Sources/APIServer/APIServer+Start.swift#L51)
(`Sources/APIServer/APIServer+Start.swift:51-175`). It builds an `[XPCRoute: RouteHandler]` table,
then calls a sequence of private `initialize*` helpers — `initializePluginLoader`,
`initializeContainersService`, `initializeNetworksService`, `initializeHealthCheckService`,
`initializeKernelService`, `initializeVolumeService`, … (`APIServer+Start.swift:61-97, 274-312`) —
each of which constructs a service actor, wraps it in its harness, and registers the harness's
methods into the shared route table. Cross-service dependencies are wired here too
(`await containersService.setNetworksService(networkService)`, `APIServer+Start.swift:80`). Each
helper daemon has its own *small* root of the same shape
(`Sources/Plugins/RuntimeLinux/RuntimeLinuxHelper+Start.swift:52-124`). The pattern:
**one long-lived graph → exactly one composition root, a plain function decomposed into named
`initialize*` helpers, attached to the process entry point.**

Two things `container` conspicuously does *not* do: no per-module assembly — `ContainersService`
and `ContainersHarness` live in the feature module, but nothing in that module instantiates them
together; the root reaches in and wires them (`APIServer+Start.swift:274-312`). And no DI framework
anywhere — composition is direct construction and parameter passing.

### 3.2 The CLI is not a composition root

`container`'s `@main ContainerCLI` is a 40-line passthrough (`Sources/CLI/ContainerCLI.swift:21-39`)
into a static ArgumentParser command tree (`Sources/ContainerCommands/Application.swift:45-100`).
Subcommands self-wire the cheap, stateless clients they need inline —
`let client = ContainerClient()`
([`ContainerCreate.swift:90`](https://github.com/apple/container/blob/5973b9cc626a3e7a499bb316a958237ebe14e2ed/Sources/ContainerCommands/Container/ContainerCreate.swift#L90)).
Wiring belongs to the process that owns the long-lived graph (the daemon), not to the command
surface.

argument-parser itself encodes the same separation: **the framework owns composition in `main()`**
— parse → validate → pick subcommand → `run()` → classify the error and exit
(`Sources/ArgumentParser/Parsable Types/ParsableCommand.swift:159`) — and **`run()` is a thin
leaf**; its default implementation is one line, `throw CleanExit.helpRequest(self)`
(`ParsableCommand.swift:47`). The library's own examples keep `run()` at 2–10 lines of business
logic (`Examples/math/Math.swift:62,175`). The idiom assumes a parse-execute-exit process; a
persistent daemon legitimately inverts it (its `run()` *is* the composition site) — but the
underlying discipline still holds: declaration, wiring, and work are three separated phases.

### 3.3 Constructor-inject a seam; choose the implementation in the executable

The libraries all expect the *application* to pick concrete implementations at its entry point:

- containerization: `LinuxContainer.init(… vmm: VirtualMachineManager …)` stores the manager by
  protocol (`LinuxContainer.swift:297,316`); the concrete backend (`VZ…` vs `CH…`) is constructed in
  the executable, `cctl`'s `RunCommand` (`cctl/RunCommand.swift:376,451-454`).
- swift-nio: the echo-server example imports `NIOCore` (abstractions) *and* `NIOPosix` (impls) at
  `main()`, injects `MultiThreadedEventLoopGroup` into `ServerBootstrap(group:)`, and registers
  handlers into the pipeline (`Sources/NIOTCPEchoServer/Server.swift:15-16,32,47-48`).
- swift-protobuf: conform a type to `CodeGenerator`, add `@main`, and the protocol-extension
  `main()` is the composition root (`Sources/SwiftProtobufPluginLibrary/CodeGenerator.swift:167`).

### 3.4 Transfer to swift-claw

swift-claw already matches the headline pattern: it has **one** centralized composition root — a
single graph built once at boot in `RunCommand.run()` (`Sources/clawd/Subcommands/RunCommand.swift:21-85`)
plus a 606-line `RunCommand+Composition.swift` holding `makeDaemon(deps:)` and 11 `make*` builders
(`RunCommand+Composition.swift:33-99`) — no per-module assemblies, no DI framework, which is exactly
what `container` chose. The pattern-level differences the Apple corpus highlights, stated
descriptively: `container` names its builders `initialize*` and keeps the root a plain decomposed
function on the daemon entry point, while its *other* commands never re-implement environment
setup — swift-claw's `DoctorCommand` independently re-loads config/secrets/stores
(`DoctorCommand.swift:31,43,102`) that `RunCommand`'s `*OrExit` helpers also load
(`RunCommand.swift:88-180`). Whether and how to restructure that is the proposals document's
business; the durable rule this corpus supports is: **one root per process; the command surface
stays thin; feature modules ship pieces, never assemblies; no DI framework.**

---

## 4. Module granularity & layering

### 4.1 What earns a target: a dependency, stability, or audience boundary — never a feature

- **swift-collections**: a module = one data-structure family + a stability tier + an independent
  import surface (`import HeapModule` pulls in no hash tables); shared plumbing is a `.hidden`
  non-exported target, `InternalCollectionsUtilities` (`Package.swift:227-231`); unstable modules
  are underscore-named (`_RopeModule`, `Package.swift:322-336`). The manifest even encodes the
  taxonomy as a `CustomTarget` DSL with `.exported`/`.hidden`/`.test`/`.testSupport` kinds
  (`Package.swift:137-167`).
- **containerization** states the rule in its own repo guide: "prefer adding code to the smallest
  applicable module … the leaf modules are intentionally light so they can be consumed standalone"
  (`CLAUDE.md:85`). `ContainerizationError` is a zero-dependency leaf so every target can throw it
  (`Package.swift:57-59`).
- **swift-http-types**: the split rule is literally "needs a heavy dependency": `HTTPTypes` has
  zero dependencies; `HTTPTypesFoundation` exists solely to depend on Foundation
  (`Package.swift:15-21`); NIO bridges are pushed to a different repo entirely.
- **swift-argument-parser**: `ArgumentParserToolInfo` is split out because its Codable wire model
  crosses a serialization/tooling boundary (`Package.swift:39`), consumed via `internal import` so
  it never leaks into the public API (`Sources/ArgumentParser/Completions/CompletionsGenerator.swift:12`).
- **container**: a target = one deployable role or one shareable contract — every service is a
  paired `Client` (wire contract, linked by the CLI) / `Server` (business + IO, linked by the
  daemon) target under `Sources/Services/<Name>/{Client,Server}` (`Package.swift:188-406`).
- The counterexample proving it's about boundaries, not size: **swift-network-evolution** keeps a
  70k-line transport stack in *one* target; new targets exist only for a different consumption
  shape (tools, benchmarks, a C shim) (`Package.swift:64-192`).

### 4.2 Protocols up in the abstract module, implementations down

swift-nio is the canonical arrangement: `NIOCore` holds the protocols (`Channel`, `ChannelHandler`,
`EventLoop`, `EventLoopGroup` — `Sources/NIOCore/Channel.swift:105`, `EventLoop.swift:246`) and
depends on no IO module (`Package.swift:64-80`); `NIOPosix` (sockets, selectors, syscalls) and
`NIOEmbedded` (deterministic test impls, `Sources/NIOEmbedded/Embedded.swift:119,431`) both point
*up* at `NIOCore` (`Package.swift:89-116`). The README states the intent: extension projects
"should only need to depend on NIOCore" (`README.md:28-29`). swift-log has the same shape in
miniature — the `LogHandler` seam in the API target, concrete handlers below it
(`Sources/Logging/LogHandler.swift:125`, `Handlers/`). `container` scales it to processes: the
`Client` target is the shared contract both CLI and Server depend on; the `InterfaceStrategy`
protocol lives in `Runtime/RuntimeClient`, its impls in `RuntimeLinux/Server`, the choice made at
the helper's entry point (`Sources/Services/Runtime/RuntimeClient/InterfaceStrategy.swift:33`;
`RuntimeLinuxHelper+Start.swift:67-71`).

swift-claw states the same rule (`ARCHITECTURE.md` §3: store protocols in ClawCore, concrete
`ClawData` injected at the root) and mostly follows it: ~15 store protocols live in
`Sources/ClawCore/Persistence/Stores.swift`, and ClawCore depends on nothing in-repo
(`Package.swift:20-138`). The one measured violation is the workspace seam: `WorkspaceReading` is
declared inside the implementation module (`Sources/ClawWorkspace/FileSystemWorkspace.swift:7`),
so `ClawAgent` and `ClawGateway` must import the concrete module to reach the abstraction
(`ClawAgent/Context/ContextBuilder.swift:2,22`;
`ClawGateway/Services/Heartbeat/SchedulerService.swift:23`) — the NIOCore-vs-NIOPosix arrangement
done backwards.

### 4.3 The `#if os()` nuance: portability splits are not capability splits

containerization keeps its `VirtualMachineManager`/`VirtualMachineInstance` seam *and both
implementations* in one target, separated by `#if os(macOS)` / `#if os(Linux)`
(`VirtualMachineManager.swift:18-20`; `CLAUDE.md:44-49`). This is not a counter-example to
protocols-up: the two backends are the *same capability on different OSes*, so the driver is
portability and compile-time selection. Where implementations differ by capability or vendor —
swift-claw's providers, stores, transports — the sibling-target split (NIO's arrangement) is the
one the corpus supports.

### 4.4 IO-free core: the rule, the honest leak, and the single-module alternatives

The rule (NIOCore): the abstract module does no IO, enforced by the SwiftPM target graph — NIOCore
*cannot* import NIOPosix. The leak: NIOCore carries a small set of syscall bindings for
`FileHandle`, with an inline apology rather than a pretense
(`Sources/NIOCore/SystemCallHelpers.swift:20-21`, quoted in §2.3) — even Apple's flagship pure core
has documented debt, treated as debt.

Where a separate target is too heavy, the corpus shows three single-module techniques for keeping a
dependency out of the seam:

- **`internal import` + a funnel namespace** — argument-parser routes all process/OS IO through one
  `enum Platform` (`Sources/ArgumentParser/Utilities/Platform.swift:33`) and quarantines Foundation
  behind `internal import` shims (`Utilities/Foundation.swift:12`).
- **`@_implementationOnly import`** — swift-system hides the C module from its public interface
  (`Sources/System/Internals/Exports.swift:22-31`) and proves it with a dedicated
  `MemberImportVisibility` build target (`Package.swift:141-146`).
- **`package` access** — containerization uses `package` ~65 times for the
  cross-target-within-package surface (`LocalOCILayoutClient.swift:24`), keeping it out of the
  public API without a separate module.

### 4.5 Inside a target: one primary type per file, satellites by concern

The file-level norm is consistent across the corpus: a primary type gets its own file, and
conformances/aspects peel off into `Type+Concern.swift` satellites. `OrderedDictionary` spans 18
files (`OrderedDictionary.swift` 1061 lines + `+Codable`/`+Hashable`/`+Sendable`/`+Invariants`/…
satellites of 15–40 lines each); nio fragments `ByteBuffer` by aspect (`ByteBuffer-core.swift` 1512,
`-aux`, `-int`, `-views`, …); swift-log carves `Logger+With.swift` and `Logger+Attributes.swift` off
its hub. Large files are acceptable when they hold *one* type or concern (`Errno.swift` 1573 lines ≈
100 documented constants; `ByteBuffer-core.swift`); tightly-coupled clusters may share a file
(nio `Channel.swift` holds the protocol plus its error enum). `// MARK:` is used sparingly and
within-file (53 in all of NIOCore; 11 in swift-system), not as a substitute for file splits.

swift-claw's shape (142 files, median 102 LOC, p90 331) matches the norm, with two measured
outliers against it: `Stores.swift` packs ~15 unrelated store protocols into one 486-line file where
Apple would give each domain family its own file, and `Sources/ClawGateway/Routing/` holds 19 files
spanning routing, approval, schedule, and turn-execution concerns in one folder where the corpus
convention is directory-per-subsystem (nio `AsyncChannel/`, async-algorithms `Debounce/`/`Merge/`,
network-evolution `QUIC/`/`Endpoint/`).

---

## 5. Responsibility separation

The corpus shows a clear generational sequence of mechanisms for "visible but not API", and a clear
default: **`internal` by default, promote to `public` only at a real audience boundary.**

| Mechanism | Who uses it | What it means |
|---|---|---|
| `_underscore` prefix | nio (`docs/public-api.md:11`: "If we prefix something with an underscore … we can't commit to an API for it"), atomics (`_AtomicsShims`: "the entire module may be removed in any new release", `README.md:112`), collections (any underscore anywhere in the qualified name voids the API promise, `README.md:230-236`), protobuf (`_protobuf_nameMap`, generated-code-only), async-algorithms (`_throttle` = not yet source-stable) | Public-but-not-API, enforced by prose contract + naming convention |
| `@_spi(Group)` | nio's newer NIOFS subsystem (247 uses, e.g. `@_spi(Testing)`, `Sources/NIOFS/FileSystem.swift:1739`); network-evolution as a *whole-API instability wall* (`@_spi(Essentials)` on 100+ sites, `@_spi(ProtocolProvider)` on 190+) | Named-audience SPI; the modern successor to the underscore for new subsystems |
| `package` | containerization (~65 uses), protobuf (~25, e.g. `SwiftProtobufError.message` is `package` while `code` is `public`, `Sources/SwiftProtobuf/SwiftProtobufError.swift:52,61`), container (~11) | First-class cross-target-within-package access; the newest repos prefer it over both conventions above |
| `@usableFromInline internal` | collections (`Deque._storage`, `Deque.swift:89-90`), nio (257 uses in NIOCore), system, atomics | Lets `@inlinable` public API touch internal storage; a performance-library tool |

Notably, several repos use **zero** `@_spi` (container, containerization, argument-parser,
http-types, atomics, collections' main modules) — the escape hatches are used reluctantly, and the
old underscore convention persists because downstream ecosystems depend on its prose contract.

**Application filter:** almost all of this is SemVer ceremony for external consumers. An
application with library-like targets needs only `internal` (default), `public` at genuine
target boundaries, and `package` where a symbol must cross targets without becoming part of the
conceptual API — the containerization/protobuf model, not nio's underscore-and-SPI machinery.

---

## 6. Data models & typed errors

### 6.1 Value types by default; hand-rolled COW only where a copy is measurably expensive

Every repo models domain data as `Sendable` value types (containerization: ~875 structs vs 57
classes; container: `struct … Sendable, Codable` resources, `ContainerConfiguration.swift:20-68`).
Classes are reserved for identity/lifetime owners. Hand-rolled COW appears only where copying is a
measured hot path, always as a private `_Storage` class behind a struct:

- swift-log `Logger.Storage` — "The storage implements CoW to become Sendable"
  (`Sources/Logging/Logger.swift:27-30,58-69`).
- swift-http-types `HTTPFields._Storage` — COW plus a lazily built name→index map so copies share
  the O(n) index (`Sources/HTTPTypes/HTTPFields.swift:26-28,261-264`).
- swift-nio `ByteBuffer._Storage` — `isKnownUniquelyReferenced` guards on every mutation
  (`Sources/NIOCore/ByteBuffer-core.swift:309-316,530`).
- swift-collections `Deque._Storage` over a `ManagedBuffer` — but `Heap` just wraps
  `ContiguousArray` and inherits Array's COW (`Sources/HeapModule/Heap.swift:64-65`): the custom
  buffer is paid for only where the access pattern (ring buffer) demands it.
- swift-protobuf spills message fields to a heap `_StorageClass` only when a documented cost model
  crosses a threshold or the message is recursive
  (`Sources/protoc-gen-swift/MessageStorageDecision.swift:67,230-233`).

swift-claw's domain values (`IncomingMessage`, `ChatMessage`, result structs with defaulted fields —
`Sources/ClawCore/Domain/Bot/IncomingMessage.swift`, `ClawCore/LLM/LLM.swift`) are small Sendable
structs; by the corpus rule they correctly need no custom COW.

### 6.2 Codable at wire seams re-validates untrusted input on decode

Where Codable crosses a trust boundary, Apple hand-writes the decoder to validate:

- swift-system `FilePath` — "Decoder is written explicitly to ensure that we validate invariants on
  untrusted input" ([`Sources/System/FilePath.swift:73-90`](https://github.com/apple/swift-system/blob/b5544ba79a70a0cb3563e75bf26dc198d6b40ed3/Sources/System/FilePath.swift#L73)).
- swift-http-types rejects pseudo-headers on decode with `DecodingError.dataCorruptedError` and
  re-checks `isValidValue` (`Sources/HTTPTypes/HTTPFields.swift:385-407`; `HTTPField.swift:230-263`).
- swift-collections throws `DecodingError.dataCorrupted` on duplicate keys / truncated pair streams
  (`OrderedDictionary+Codable.swift:71-83`).
- swift-argument-parser versions its wire model in the type name (`ToolInfoV0`) and validates a
  `serializationVersion` header *before* full decode
  (`Sources/ArgumentParserToolInfo/ToolInfo.swift:17,29`).

This is swift-claw's "untrusted inbound is data" rule (ARCHITECTURE §12) applied at the Codable
seam — the corpus confirms the discipline and the mechanism.

### 6.3 One classification seam per boundary; nothing above it sees the raw form

Every repo with an IO or trust boundary classifies raw failures into a typed domain error at
exactly one seam:

| Repo | Seam | Shape |
|---|---|---|
| swift-system | `valueOrErrno` — `-1 → .failure(Errno.current)`, plus EINTR retry, in one function ([`Sources/System/Util.swift:10-16`](https://github.com/apple/swift-system/blob/b5544ba79a70a0cb3563e75bf26dc198d6b40ed3/Sources/System/Util.swift#L10)) | `internal _foo() -> Result<T, Errno>` + thin throwing public wrapper |
| swift-nio | the `syscall(…)` wrapper in NIOPosix: on `-1`, `throw IOError(errnoCode:reason:)` (`Sources/NIOPosix/System.swift:306-333`) — NIOCore never classifies | Error type in the core module, classification in the IO module |
| swift-argument-parser | `MessageInfo.init(error:type:columns:)` — the single funnel any thrown error passes before reaching the user; the default case wraps foreign errors so `run()`'s errors still get a message and exit code (`Sources/ArgumentParser/Usage/MessageInfo.swift:17,75,181`) | Presentation-side funnel |
| swift-http-types | `HTTPParsedFields.ParsingError` enumerates every wire violation at the parse seam (`Sources/HTTPTypes/HTTPParsedFields.swift:26-52`) | Typed enum at the untrusted-input boundary |
| containerization | `ContainerizationError { code, message, cause: (any Error)? }` in its own zero-dep target; low layers throw `POSIXError.fromErrno()`, higher layers wrap with the underlying error chained in `cause` (`ContainerizationError.swift:23-41`; `POSIXError+Helpers.swift:31-37`) | Struct error with a cause chain |
| swift-async-dns-resolver | `Error.init(cAresCode:)` / `.init(dnssdCode:)` switch raw C codes into a domain `Code`, preserving the raw code in `source` — co-located with each backend (`Sources/AsyncDNSResolver/c-ares/Errors_c-ares.swift:20-36`) | Classifier lives next to the impl, not in the shared file |
| swift-protobuf | per-domain static factories build `SwiftProtobufError(code:message:location:)`, capturing `SourceLocation.here(function: #function, file: #fileID, line: #line)` via default args (`Sources/SwiftProtobuf/SwiftProtobufError.swift:161,186-215`) | Source-located, coded domain error |

**The cautionary wart** comes from `container`: its hand-rolled XPC wire error
`ContainerXPCError { code: String; message: String }` loses the original type identity, forcing the
server to sniff the *type-name string* to preserve volume errors —
`if errorTypeString.contains("VolumeError") || errorMessage.contains("Volume")`
([`Sources/ContainerXPC/XPCServer.swift:232-241`](https://github.com/apple/container/blob/5973b9cc626a3e7a499bb316a958237ebe14e2ed/Sources/ContainerXPC/XPCServer.swift#L232)).
Degrading a typed error to a stringly wire form at a seam costs the type system back; the corpus's
one negative example argues for keeping domain errors typed end-to-end.

Modern seam signatures carry the type: swift-system's newest code uses Swift 6 typed throws,
`public init(…) throws(Errno)` (`Sources/System/FileSystem/Stat.swift:104-111`).

swift-claw's `ClawDatabase.classifyError` → `StoreError` (`SQLITE_FULL → .diskFull`, routed through
`writeMapping`/`readMapping`; `Sources/ClawData/Database/ClawDatabase.swift:261`) is precisely this
discipline — the Errno/IOError seam with semantic bucketing. The corpus contrast worth recording:
Apple co-locates the *taxonomy* deliberately (containerization gives the error type its own
zero-dep target; dns-resolver keeps per-backend classifiers beside their backends), whereas
swift-claw's taxonomy is physically scattered (`StoreError` and `TelegramError` under
`Sources/ClawCore/Config/Errors.swift`; `ProviderError` inside `ClawCore/LLM/LLM.swift:130`).

### 6.4 Two error-type shapes, chosen by openness of the set

- **Open set → frozen struct over a raw value.** `Errno` is a `@frozen struct RawRepresentable`
  over `CInt` with `static var` "cases", because the errno space is open-ended — an enum would make
  unknown kernel codes unrepresentable (`Sources/System/Errno.swift:12-21,53-54`). dns-resolver and
  network-evolution use the same "struct `Code` wrapping a private enum" idiom for source-stable
  public error codes (`Errors.swift:18-77`; `NetworkError.swift:55-115`).
- **Closed, curated set → enum of domain buckets.** argument-parser's `ExitCode`/`ValidationError`,
  http-types' `ParsingError`, protobuf's legacy `BinaryDecodingError`. swift-claw's `StoreError` is
  this shape, appropriately — its buckets are domain semantics, not a passthrough.

---

## 7. Time, clocks & cross-cutting injection

### 7.1 The stdlib `Clock` is the injected time seam

swift-async-algorithms never reads wall-clock time and defines no bespoke `now:`/`sleep:` closure
seam: **every time-based operator takes a `Clock` as a generic parameter** and touches time only via
`clock.now` / `clock.sleep(until:tolerance:)`. `AsyncTimerSequence<C: Clock>` stores the clock and
computes purely with `C.Instant` arithmetic
([`Sources/AsyncAlgorithms/AsyncTimerSequence.swift:14-15,35-44`](https://github.com/apple/swift-async-algorithms/blob/3da39bbc4e687d4192af7c9cf4eab805745a0b9c/Sources/AsyncAlgorithms/AsyncTimerSequence.swift#L14)).
The real clock enters only through thin convenience overloads: `repeating(every:)` exists solely in
a `where C == SuspendingClock` extension (`AsyncTimerSequence.swift:77-85`); `debounce(for:)`
forwards `clock: .continuous` to the injectable overload
(`Sources/AsyncAlgorithms/Debounce/AsyncDebounceSequence.swift:27-33`). Tests substitute a
deterministic fake: `ManualClock: Clock` with nested `Instant: InstantProtocol` /
`Step: DurationProtocol`, where time moves only on `clock.advance()` and `sleep` parks a
continuation until the deadline is crossed
(`Tests/AsyncAlgorithmsTests/Support/ManualClock.swift:14,185-209,238-250`). ~250 lines of fake buys
zero real waiting. network-evolution corroborates with an injected `Scheduler` seam plus a
value-type `NetworkClock` for tests (`Sources/SwiftNetwork/Context/NetworkContext.swift:69-79`;
`Tests/SwiftNetworkTests/SwiftNetworkClockTests.swift:22-27`).

### 7.2 Bootstrap is for a different kind of dependency

swift-log's `LoggingSystem.bootstrap` is a process-global, install-once factory: a private static
cell seeded with a safe default (`StreamLogHandler.standardError`), replaceable exactly once,
enforced by a `precondition` ("logging system can only be initialized once per process",
`Sources/Logging/LoggingSystem.swift:29-58,164-168`). The cost of that global shows up immediately
under test: the library needs an internal `bootstrapInternal(validate: false)` back-door so the
suite can re-bootstrap (`LoggingSystem.swift:78-96`). And swift-log's own escape hatch for "a
different one *here*" is per-instance injection, `Logger.init(label:factory:)`
(`Sources/Logging/Logger.swift:1237-1274`), with a documented rule that libraries must accept a
`Logger`, never construct their own (`Docs.docc/BestPractices/003-AcceptingLoggers.md:1-12`).

**The discriminator:** a bootstrap fits a concern that is (a) ubiquitous across the whole process,
(b) effectively a singleton, and (c) has a safe zero-config default — logging is the poster child.
A clock is none of these under test: parallel tests want *different, isolated* clocks, which a
process-global cell fights (it would need the same `validate:false` back-door). So: **bootstrap for
logging; inject for time.**

swift-claw today injects `now: @Sendable () -> Date` at ~13 sites and
`sleep: @Sendable (Duration) async throws -> Void` at ~7, composed as `{ Date() }` /
`{ try await Task.sleep(for: $0) }` at the root (`RunCommand+Composition.swift:140-142`), with one
divergent seam (`OpenAICompatibleProvider.swift:11-12` takes seconds as `Double` plus a `jitter`
closure) and no use of the stdlib `Clock` anywhere. The injection *instinct* matches the corpus; the
*shape* Apple converged on is the stdlib `Clock` protocol rather than closure pairs. (Randomness is
a separate seam: swift-algorithms threads a seedable `RandomNumberGenerator` parameter,
`randomSample(count:using:)`, rather than a jitter closure.)

---

## 8. Concurrency under Swift 6

**Sendable value types are the default; actors and locks appear only where shared mutable state is
unavoidable.** containerization: ~875 structs, 13 actor declarations; swift-protobuf: zero actors —
its one shared registry sits behind a `DispatchQueue` so synchronous serialization paths can reach
it (`Sources/SwiftProtobuf/Google_Protobuf_Any+Registry.swift:25-29`); container uses `public actor`
for its ~30 genuinely stateful services (`ContainersService.swift:34`).

**The actor-reentrancy trap is corroborated in Apple's own words.** containerization holds
`LinuxContainer`'s state machine behind an `AsyncMutex` whose doc comment gives the reason:
it is "primarily used in spots where an actor makes sense, but we may need to ensure we don't fall
victim to **actor reentrancy** issues" (`AsyncMutex.swift:17-21`; used at
`LinuxContainer.swift:145`). That is a direct, independent confirmation of swift-claw's
ARCHITECTURE §5 rule — an actor does not serialize across `await`, so the per-session lane chains a
stored `Task` rather than relying on actor isolation. nio's equivalents: `EventLoop` bridges to
Swift Concurrency as a custom `SerialExecutor` (`Sources/NIOCore/EventLoop+SerialExecutor.swift:20-60`),
and `NIOLoopBound` is an `@unchecked Sendable` container whose safety is verified at runtime by
`preconditionInEventLoop()` (`Sources/NIOCore/NIOLoopBound.swift:27-60`). Across the corpus,
`@unchecked Sendable` always ships with a stated one-line reason (protobuf: "because we use a
backing class for storage", `SwiftProtobufError.swift:20`; argument-parser `Parsed.swift:26,32`).

**Construction cycles are broken by post-construction registration.** None of the studied repos has
swift-claw's exact mutual `TurnRunner ⇄ ApprovalWaiter` cycle, but the general Apple idiom for late
binding is build-then-register: nio pipelines register handlers after the channel exists
(`pipeline.syncOperations.addHandler(…)`, `Sources/NIOTCPEchoServer/Server.swift:47-48`), and
container's root builds services, then registers their harness methods into the shared route table
(`APIServer+Start.swift:61-97`). swift-claw's mechanism is the same shape: two narrow protocols in
each direction (`ApprovalParking`, `TurnDispatching`), a `DeferredApprovalParker` holding
`Mutex<(any ApprovalParking)?>` late-bound once via `adopt(_:)` at composition, plus a null-object
`InertApprovalParker` for phases without a waiter
(`Sources/ClawGateway/Routing/ApprovalCoordinator.swift:66,79,84,114`;
`RunCommand+Composition.swift:197`) — a contained instance of the corpus idiom, not a deviation
from it.

---

## 9. Principles in practice

### 9.1 Abstractions Apple refused (YAGNI, with receipts)

- No DI frameworks or runtime registries anywhere in 15 repos. argument-parser hand-lists
  subcommand metatypes and leaves a comment that auto-discovery is deliberately not built
  (`Examples/math/Math.swift:26`); coreai-models' `EngineFactory` is a plain struct with a static
  `switch`, "no protocol, no registry" (`EngineFactory.swift:32-73,102-120`).
- nio ships **one** `EventLoopGroup` implementation ("there is one EventLoopGroup implementation,
  and two EventLoop implementations", `README.md:151`) and keeps protocol implementations
  (TLS, HTTP/2) out of tree (`README.md:217-223`).
- async-algorithms refused to invent a time-source abstraction — the stdlib `Clock` is the seam
  (§7.1) — and keeps `_TinyArray` deliberately zero-or-one-element, vendored from
  swift-certificates rather than adding a dependency (`Sources/AsyncAlgorithms/Internal/_TinyArray.swift:1-27`).
- dns-resolver shipped a 10 ms polling loop with an honest
  `// TODO: implement this more nicely using NIO EventLoop?` rather than take an NIO dependency
  (`DNSResolver_c-ares.swift:196-263`; `Package.swift:26` — zero dependencies).
- collections gives `Heap` a plain `ContiguousArray` (free COW) and pays for a custom managed
  buffer only in `Deque`, whose ring layout Array cannot express (`Heap.swift:64-65`).
- protobuf keeps its heap-spill cost model deliberately crude, with an inline note that the numbers
  are placeholders "if desired" (`MessageStorageDecision.swift:19-21`).
- system refuses cross-platform abstraction outright: "It is not a design goal for System to
  eliminate the need for `#if os()`" (`README.md:5,9`) — and left `FileDescriptor: Sendable`
  *commented out* with a link to the open design discussion rather than ship a convenient-but-wrong
  conformance (`FileDescriptor.swift:641-644`).

### 9.2 Where they invested, and what earned it

The pattern behind every investment is *measured recurrence*: `ByteBuffer`'s COW machinery (the hot
path of every NIO app, `ByteBuffer-core.swift:309-316`); swift-log's `LogEvent` redesign, bought
with a full proposal plus deprecation shims because forwarding new fields would source-break the
entire handler ecosystem (`Docs.docc/Proposals/SLG-0005…`; `LogHandler.swift:237-302`);
async-algorithms' storage + pure-state-machine triad per concurrent operator, earned by "subtle
behaviors and many edge cases" in multi-input coordination (`Debounce/DebounceStateMachine.swift:13,130-133`);
dns-resolver's reply-parser protocol, earned by 10 record types × 2 backends collapsing into
one-line methods (`DNSResolver_c-ares.swift:39-91,297-334`); containerization's typed network
primitives (`CIDR`, `MACAddress`, `AddressAllocator` — domain types instead of strings,
`Sources/ContainerizationExtras/`), the same canonical-abstractions bar swift-claw holds; and
protobuf's `Visitor` traversal seam, which serves four encoders *and* hashing off one generated
method (`Sources/SwiftProtobuf/Visitor.swift:37`; `INTERNALS.md`, Serialization).

### 9.3 Naming, per the Swift API Design Guidelines

Two examples worth keeping as references: `ByteBuffer`'s symmetric quartet — mutating
`read<T>(length:)` / non-mutating `get<T>(at:)`, `write` / `set` — makes index behavior legible at
every call site (`Sources/NIOCore/ByteBuffer-core.swift:229-269`); and swift-system renames C
constants into phrases (`noSuchFileOrDirectory`) while keeping the C spelling as an
`@available(unavailable, renamed:)` alias so `EPERM` still teaches you the new name
(`Sources/System/Errno.swift:43-45,53-58`). Same spirit elsewhere: http-types' keyed subscripts
(`fields[.userAgent]`, `fields[values: .acceptLanguage]`, `HTTPFields.swift:181-231`); atomics'
deliberately unabbreviated `loadThenWrappingIncrement(by:ordering:)` (`README.md:207`).

---

## 10. Secondary observations (report-only)

**Testing.** Adoption splits cleanly by repo age: the newest repos are Swift Testing throughout
(container: 104 files `import Testing` vs 1 XCTest; containerization: 64 vs 0; swift-log,
coreai-models), while the established libraries remain XCTest (nio 149 files, argument-parser 57,
system, collections, protobuf, atomics, algorithms, async-algorithms, network-evolution).
Determinism is bought with **first-class test-support targets and fakes**, not sleeps: `NIOEmbedded`
(a shipped product whose `EmbeddedEventLoop` gives manual control of time and even fails loudly on a
leaked channel, `Sources/NIOEmbedded/Embedded.swift:489`), `ManualClock` (§7.1),
`_CollectionsTestSupport`'s `ConformanceCheckers`/`MinimalTypes`, `ArgumentParserTestHelpers` with
golden `Snapshots/`, `ContainerTestSupport`, and swift-system's built-in `MockingDriver` syscall
mocking behind `#if ENABLE_MOCKING` (`Sources/System/Internals/Mocking.swift:48-90`). swift-claw's
posture (Swift Testing, in-memory GRDB for managed deps, scripted doubles at protocol seams) is the
modern end of this spectrum.

**DocC & proposal habits.** Per-module `.docc` catalogs with curated `## Topics` pages are standard
(nio, log, collections, protobuf, algorithms, http-types); several repos run a lightweight
evolution-proposal process for design history (swift-log `SLG-NNNN`, swift-system `Proposals/`,
async-algorithms `Evolution/`, swift-algorithms `Guides/` with its Detailed Design / Complexity /
Naming template, `Guides/Chunked.md:78-140`). Long-form internals docs self-disclaim as
non-normative (protobuf `INTERNALS.md:9-16`).

**CI/release engineering.** Heavy reuse of shared `swiftlang/github-workflows` reusable workflows
(argument-parser, collections, http-types, async-algorithms, network-evolution); OS × Swift-version
matrices including nightlies, Windows, WASM, static Linux SDKs; strictness flags in CI
(`-require-explicit-sendable` in swift-log and http-types, `-warnings-as-errors`,
`MemberImportVisibility`); license-header soundness checks everywhere; actions pinned to major tags
as the norm (coreai-models is the outlier, pinning to commit SHAs with a `# v6` comment,
`.github/workflows/ci.yml:19`). network-evolution exercises *every package-trait combination* in CI
so trait wiring cannot rot (`.github/workflows/pull_request.yml`).

---

## 11. What transfers to swift-claw — summary

| Dimension | Transfers to swift-claw | Library-only / does not transfer |
|---|---|---|
| Composition root | One centralized root per process, a plain function decomposed into named builders; feature modules ship pieces, never assemblies; no DI framework (§3.1) | — |
| CLI wiring | Command surface stays thin; subcommands self-wire only cheap clients; shared environment loading not re-implemented per command (§3.2) | argument-parser's "run() is a leaf" literal form — a daemon's `run()` legitimately owns the graph |
| Module granularity | Target = dependency/stability/audience boundary; directory-per-subsystem inside a target (§4.1, §4.5) | collections' `CustomTarget` DSL, umbrella re-export modules, `COLLECTIONS_SINGLE_MODULE` builds |
| Protocol placement | Protocols up in the abstract module (ClawCore), impls down in siblings, composed in `clawd` — the NIO arrangement; the `WorkspaceReading` placement is the measured counterexample (§4.2) | containerization's `#if os()` single-target backends (portability driver, not capability/vendor) |
| IO-free core | Enforce via the target graph; where a split is too heavy, `internal import` / `@_implementationOnly` / `package` (§4.4) | nio's compile-time visibility proofs are optional rigor for a single-owner app |
| Access control | `internal` default, `public` at boundaries, `package` for cross-target-not-API (§5) | `_underscore`/`@_spi` SemVer fences, `@usableFromInline`/`@inlinable` gymnastics — external-consumer ceremony |
| Data models | Sendable value structs; defaulted fields for additive evolution; no custom COW until a copy is measured hot (§6.1) | Hand-rolled `_Storage` COW, `@frozen`/ABI machinery |
| Typed errors | One classification seam per boundary; keep type identity across seams (the `container` XPC wart is the warning); consider `throws(typed)` and a `cause` chain; co-locate the taxonomy deliberately (§6.3) | Errno's faithful open-set passthrough — swift-claw's curated semantic buckets are the right shape for a domain app |
| Codable | Hand-written decoders that re-validate untrusted input; versioned wire types (§6.2) | — |
| Time & cross-cutting | Inject time; the stdlib `Clock` is the converged seam shape, with real clocks only in convenience overloads and a `ManualClock` fake in tests; bootstrap only for ubiquitous singletons with safe defaults (logging) (§7) | The marble-diagram validation DSL — heavier than an app's scheduler needs |
| Concurrency | Sendable values + actors/locks where unavoidable; the reentrancy trap is real (containerization's `AsyncMutex` says so); post-construction registration for cycles (§8) | nio's `EventLoop`-as-`SerialExecutor` datapath, network-evolution's callback event loop |
| Comments | Volume up, not down (swift-claw under-comments every Apple library); `///` carries contract, `//` carries why; rationale self-contained at the symbol (§2.1, §2.3) | — |
| Doc linkage | Docs point at code (symbol/file names); code cites only stable external identifiers or nothing; reserve inline citations for would-read-as-a-bug spots (§2.2, §2.4) | — |
| Testing | Deterministic fakes and test-support targets over sleeps; Swift Testing is where Apple's newest repos are (§10) | Allocation-count suites, conformance harnesses, benchmark packages |
| Release engineering | Shared reusable workflows, matrixed CI, strictness flags, license soundness, actions pinned to major tags (§10) | SemVer public-API contracts, CMake/toolchain dual builds |

---

## 12. References

Permalink form: `<base><path>#L<line>`.

| Repo | Tag | Permalink base |
|---|---|---|
| container | 1.1.0 | `https://github.com/apple/container/blob/5973b9cc626a3e7a499bb316a958237ebe14e2ed/` |
| containerization | main-HEAD | `https://github.com/apple/containerization/blob/2f947e76143c79e94fa5403ac74ff8d9bd9f0319/` |
| swift-nio | 2.101.2 | `https://github.com/apple/swift-nio/blob/cd3e1152083706d77b223fb29110e590efcc70c0/` |
| swift-argument-parser | 1.8.2 | `https://github.com/apple/swift-argument-parser/blob/6a52f3251125d74daf04fcbd5e6f08a75d074382/` |
| swift-log | 1.14.0 | `https://github.com/apple/swift-log/blob/a878e7f8f46cfc0e1125e565b5c08e7d5272dc9a/` |
| swift-http-types | 1.6.0 | `https://github.com/apple/swift-http-types/blob/db774a277f60063a32d854f2980299caf06da041/` |
| swift-async-algorithms | 1.1.5 | `https://github.com/apple/swift-async-algorithms/blob/3da39bbc4e687d4192af7c9cf4eab805745a0b9c/` |
| swift-collections | 1.6.0 | `https://github.com/apple/swift-collections/blob/a0cb0954ecb21e4e31b0070e6ed5674e8556685a/` |
| swift-system | 1.7.4 | `https://github.com/apple/swift-system/blob/b5544ba79a70a0cb3563e75bf26dc198d6b40ed3/` |
| swift-protobuf | 1.38.1 | `https://github.com/apple/swift-protobuf/blob/55d7a1cc5666b85c13464aea1c4b4a90feccb4c8/` |
| swift-algorithms | 1.2.1 | `https://github.com/apple/swift-algorithms/blob/87e50f483c54e6efd60e885f7f5aa946cee68023/` |
| swift-atomics | 1.3.1 | `https://github.com/apple/swift-atomics/blob/0442cb5a3f98ab802acb777929fdb446bda11a34/` |
| swift-async-dns-resolver | 0.7.1 | `https://github.com/apple/swift-async-dns-resolver/blob/e145f21e97cc40ee744e1276b21426ed47ab9d88/` |
| swift-network-evolution | 0.1.0 | `https://github.com/apple/swift-network-evolution/blob/6fb079faf120fd6127b8d36db474b78449c2b293/` |
| coreai-models | main-HEAD | `https://github.com/apple/coreai-models/blob/f9e9357690392a200914320d0bf576788dd57245/` |

swift-claw facts in this document cite repository paths at the working tree of 2026-07-10
(e.g. `Sources/ClawCore/Persistence/Stores.swift`, `Sources/clawd/Subcommands/RunCommand+Composition.swift`),
verified against source during the study.
