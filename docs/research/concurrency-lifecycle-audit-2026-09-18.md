# Concurrency and lifecycle audit — 2026-09-18

This audit follows the accepted architecture and the repository testing rubric. Four parallel
reviews covered task ownership, actor reentrancy, stream termination, and object/resource ownership.
The fixes preserve Swift 6 strict concurrency, the dependency DAG, and existing CLI/configuration.
No unsafe sendability annotation, global actor, dependency upgrade, or scheduling sleep was added.

## Confirmed defects and fixes

### 1. Cancellation did not stop the remaining tool batch

**Invariant:** once a turn observes cancellation, it must not admit another tool call.

**Sequence:** a provider returns two tool proposals; the first dispatcher call suspends; `/stop`
or shutdown cancels the lane; the dispatcher returns its cancellation/error observation; the loop
continues to dispatch the second proposal before reaching the next provider-round cancellation check.
A tool dispatcher may start independently owned work, so inheriting a cancelled task is insufficient.

**Code:** `AgentRuntime.runTurn`, the `response.toolCalls` loop in
[`AgentRuntime.swift`](../../Sources/ClawAgent/Runtime/AgentRuntime/AgentRuntime.swift).

**Consequence:** a cancelled turn can still initiate another tool operation or side effect.

**Minimal fix:** check cancellation before each proposed call and use the existing process-interruption
outcome. Already-recorded provider usage and the completed tool's audit remain recorded.

**Evidence:** `AgentRuntimeCancellationTests.cancellationDuringAToolStopsTheRemainingBatch` gates the
first dispatcher, cancels the turn externally, and observes only the first proposal dispatched.
It failed against the original loop and passes with the checkpoint.

### 2. Outbox retry work survived its service

**Invariant:** returning from the outbox service ends its retry wakeups.

**Sequence:** Telegram returns 429 with `retry_after`; `hold` starts an unregistered task sleeping
until retry; shutdown ends the notification loop; `run` returns; the sleeper retains the signal and
clock and later pokes the stopped service.

**Code:** `OutboxDispatcher.run`, `hold`, and `FloodControlHolds` in
[`OutboxDispatcher.swift`](../../Sources/ClawGateway/Services/OutboxDispatcher.swift).

**Consequence:** background work and retained dependencies survive the owning service.

**Minimal fix:** the existing hold state owns wakeup handles; service exit cancels and joins them;
a cancelled sleep does not poke the signal. Completed handles unregister from their owner.

**Evidence:** `OutboxDispatcherTests.shutdownCancelsAndJoinsFloodControlRetry` waits for the sleeper's
entry signal, cancels and joins the service, and observes sleeper completion and a pending delivery.
The test targets the original unowned timer; source review verifies the explicit join as well.

### 3. MCP disconnect did not own an in-flight connection

**Invariant:** disconnect finishes opening/handshake cleanup before returning; waiters cannot publish
an obsolete client afterward; subsequent calls can open a fresh session after teardown.

**Sequence:** a tool starts the shared opening task; its outer deadline or caller cancellation ends
the tool call; shutdown disconnects while no client has been published; the original teardown sees
`client == nil` and returns; the opening continues and a waiting caller publishes the late client.
The SDK handshake itself also owns work across suspension, so cancellation must cover it explicitly.

**Code:** `MCPServerSession.connected`, `open`, and `teardown` in
[`MCPServerSession.swift`](../../Sources/ClawMCP/Transport/MCPServerSession.swift).

**Consequence:** an MCP session can become live after shutdown has proceeded to close its HTTP client.

**Minimal fix:** one shared closing task cancels and joins opening; only the opening task publishes
its result and clears its handle; new callers wait for closing. Handshake cleanup also drains the SDK
operation. Retry teardown uses the same owner as explicit disconnect.

**Evidence:** `MCPServerSessionLifecycleTests` gates opening and the SDK handshake; cancelled opening
must fail and a subsequent call must use a fresh connection. These tests protect different suspension
boundaries, rather than assuming an actor serializes the entire method.

### 4. MCP HTTP requests could outlive disconnect

**Invariant:** the transport closes admission, ends admitted exchanges, and then returns the final
remote session with DELETE before its HTTP dependency closes.

**Sequence:** the SDK starts a POST in its own task; a tool deadline resolves the request continuation
while the POST still awaits headers or body bytes; disconnect finishes the receive stream but does
not cancel/join the POST; a late response installs a session ID or continues consuming body data
after teardown. A session created by late headers misses the earlier DELETE entirely.

**Code:** `MCPStreamableHTTPTransport.send`, `disconnect`, and response-head capture in
[`MCPStreamableHTTPTransport.swift`](../../Sources/ClawMCP/Transport/MCPStreamableHTTPTransport.swift).

**Consequence:** HTTP work survives shutdown and late-created remote session resources are not returned.

**Minimal fix:** register each send before suspension; propagate cancellation; share one teardown
that cancels and joins all admitted sends before deleting the captured session. Capture late headers
before checking cancellation, so their session ID remains available for cleanup. Disconnect also
consumes an idle single-use transport, preventing a delayed SDK connect from reopening it.

**Evidence:** `MCPTransportLifecycleTests.disconnectJoinsExchange` separately gates the response head
and body. The scripted HTTP boundary checks DELETE occurs after body termination and carries the
late session ID. Existing reconnect-refusal coverage includes disconnect before connection.

### 5. The approval construction cycle retained the runtime graph

**Invariant:** releasing the inactive or drained daemon releases its approval graph and dependencies.

**Sequence:** composition adopts a waiter into `DeferredApprovalParker`; the waiter contains
`TurnRunner`; the runner contains that same parker; dropping the root leaves the three-way strong
cycle intact, even when no approval was ever requested.

**Code:** `DeferredApprovalParker` in
[`ApprovalCoordinator.swift`](../../Sources/ClawGateway/Approval/ApprovalCoordinator.swift),
[`ApprovalWaiter.swift`](../../Sources/ClawGateway/Approval/ApprovalWaiter.swift), and
[`DaemonBuilder+Approvals.swift`](../../Sources/clawd/Composition/DaemonBuilder/DaemonBuilder+Approvals.swift).

**Consequence:** the stores, provider stack and transports reachable through that graph remain retained.

**Minimal fix:** make the immutable waiter a final class and keep a mutex-protected weak back-reference
from the deferred parker. The daemon's persistent boot/reconciliation closure remains the strong
owner for its complete lifetime; a parked call takes a temporary strong reference.

**Evidence:** `ApprovalLifecycleCompositionTests` builds the real daemon graph, verifies it retains
its transport while alive, releases the root, and verifies the weak transport reference becomes nil.

### 6. The native runner returned before cancellation cleanup and reaping

**Invariant:** the low-level subprocess runner's cancellation/timeout result is returned after its
native operation has ended, including teardown and reaping.

**Sequence:** a command spawns; cancellation or the program deadline wins `DeadlineRace`; that helper
cancels but deliberately does not join its loser; the runner returns a typed result while
`Subprocess.run` still performs process-group termination and reaps the child.

**Code:** `SwiftSubprocessRunner.run` and `spawnAndCapture` in
[`SwiftSubprocessRunner.swift`](../../Sources/ClawSubprocess/Runner/SwiftSubprocessRunner.swift).

**Consequence:** a caller observing completion can still find the direct child alive or unreaped.

**Minimal fix:** explicitly own the native operation, race its result, then cancel and join it before
returning. Refuse an already-cancelled invocation and check cancellation immediately before spawn.
The outer container watchdog retains its deliberate ability to abandon a genuinely wedged adapter;
this change does not claim that every outer `execute_code` cancellation now waits for that adapter.

**Evidence:** the existing `callerCancellationTearsDownTheCreatedProcessGroup` now checks the direct
child is already reaped immediately upon return, before its existing descendant-liveness poll.
`alreadyCancelledCallerDoesNotLaunchAProcess` observes the actual spawn callback, relying on the
separately protected joined-return boundary; it does not claim to catch an old abandoned operation
that could start after the assertion.

## Test-intent map and redundancy review

| Risk | Production seam | Nearest existing test | Distinct mutant | Primary regression |
| --- | --- | --- | --- | --- |
| Remaining tools run after cancellation | Agent tool loop | `midBatchToolCallCapDispatchesPrefixThenStops` tests a budget cap | Remove per-call cancellation checkpoint | `cancellationDuringAToolStopsTheRemainingBatch` |
| Retry sleeper outlives service | Outbox service exit | `floodControlSchedulesADrainOnceTheRetryWindowPasses` tests natural expiry | Restore discarded retry task | `shutdownCancelsAndJoinsFloodControlRetry` |
| Opening installs client after disconnect | MCP session opening/closing | `callAfterRestart` starts teardown after connection | Ignore opening at disconnect | `disconnectDuringOpening` |
| Late SDK handshake survives cleanup | SDK connect suspension | Opening-factory test stops before SDK connect | Omit cancellation forwarding to the owned SDK handshake | `disconnectDuringHandshake` |
| Late head creates unreleased session | MCP transport admission/head | `disconnectDeletesSession` completes send first | Omit ownership before response head | `disconnectJoinsExchange(.opening)` |
| Body producer survives deletion | MCP transport body termination | `disconnectDeletesSession` has no active body | Delete without cancelling/joining active send | `disconnectJoinsExchange(.body)` |
| Idle transport reopens after cleanup | MCP transport idle state | Existing `reconnectRefused` disconnects only connected transport | Return early on idle disconnect | `reconnectRefused` idle argument |
| Root release retains approval graph | Real daemon composition | Approval flow acceptance keeps root alive | Restore strong parker back-reference | `releasingTheDaemonReleasesTheApprovalGraphsTransport` |
| Pre-cancelled invocation launches a child | Subprocess entry/spawn | Existing cancellation test waits until spawn | Remove pre-launch cancellation checks while retaining join | `alreadyCancelledCallerDoesNotLaunchAProcess` |
| Cancelled native result precedes reap | Subprocess return boundary | Same test previously checked eventual descendant death only | Return before native operation joins | Existing cancellation test strengthened |

The map belongs in this audit/PR, not production comments. Cross-cutting test value and redundancy
receive an independent review. Tests reuse existing gates, scripted unmanaged boundaries and real
composition/stores. Watchdog deadlines only bound missing-signal failures; elapsed time does not prove
that work is correctly waiting. No duplicated DM/group variants or implementation-shape assertions
were added.

## Coverage and unchanged behavior

| Area | Traced paths and outcome |
| --- | --- |
| `ClawAgent` | FIFO admission/chaining, run cancellation, provider deadline loser draining, typing/drafts, stream terminal accounting, tool loop. Tool-batch defect fixed. |
| `ClawGateway` | Poller/router serialization, confirmation/approval lifecycle, scheduler, learning drain/CAS, Coder admission/recovery/shutdown, outbox, root shutdown ordering. Outbox and approval ownership fixed. |
| `ClawCore`, `ClawHTTP`, `ClawLLM` | Bounded channels, producer/consumer cancellation, full-buffer wakeup, terminal caching/join, both provider adapters and nested HTTP lifecycle. No further confirmed defect. |
| `ClawMCP` | SDK continuations, request deadlines, shared opening, reconnect, transport head/body/disconnect, boot catalog shutdown. Opening and exchange ownership fixed. |
| `ClawAuth`, `ClawSecrets` | Refresh flight IDs, cancelled waiters, generation rejection, persistence-before-publication, credential shutdown, secret file descriptors and error exits. No further confirmed defect. |
| `ClawSubprocess`, `ClawCoder`, `ClawExec` | Spawn/exit/timeout/cancel, process group and pipe lifetime, mandatory receipts, recovery, container queue/watchdog/cleanup and scratch descriptors. Low-level runner join fixed; Coder already owns its joined operation. |
| `clawd`, `ClawTelegram` | Composition references, boot failures, service ordering, CLI HTTP lifetime, teardown and transport boundaries. No additional defect beyond the approval graph. |
| `ClawData`, `ClawWorkspace`, `ClawTools` | GRDB serialized transactions and CAS, value-type filesystem/config readers, resolver off-pool continuation, policy/dispatch/atomic file operations. Intentional bounded tool abandonment retained. |
| `ClawAppleSpeech`, `ClawTestSupport` | Speech framework resource boundary, test continuation/gate helpers and shared doubles. Framework uncertainty listed below. |

The public README, Getting Started, Install, Customization and deployment guide were read in full.
No command, option, environment variable, default, secret location, installation or release step
changes; no public guide edits are needed. Normative lifecycle details are updated in
[`ARCHITECTURE.md`](../ARCHITECTURE.md).

## Hypotheses deliberately left unchanged

- A delayed, already-delivered error from an old MCP client might invalidate a newer client. The SDK
  cancels pending continuations on disconnect, so simply delaying two HTTP errors does not reproduce
  the required ordering. No claim of a reproduced stale-client defect is made.
- Apple Speech may require explicit `cancelAndFinishNow` after cancellation of result iteration.
  The necessary framework lifetime behavior was not established; changing it without evidence could
  introduce competing finalization.
- `InstanceLock` has a mutable released flag under existing unchecked sendability, but production
  direct releases use a single defer owner and credential leases serialize `releaseOnce`. No reachable
  concurrent-release scenario was found; no annotation or lock policy was changed.
- A weighted channel can admit a light sender while a heavier sender waits. Current HTTP/LLM paths
  use one producer per channel, so no current production ordering violation was demonstrated.

Actor suspension alone, an unstructured task with explicit ownership, a strong capture with a finite
lifetime, and the documented outer watchdog abandonment were not treated as defects.

## Validation

Eight selected regression tests were rerun with the original production implementations restored
(the test/support changes remained). All eight failed in the expected areas, reporting 16 issues:
remaining tool dispatch, live retry sleeper, retained graph, unreaped child, idle reconnect, unfinished
SDK handshake, late connection reuse, and HTTP body/session teardown. The fixed implementations
were then restored before the final checks. The already-cancelled-launch test was excluded from this
whole-original-code experiment because its precise mutant assumes the joined-return fix.

Final checks, in required order, on Apple Swift 6.3.3 / arm64 macOS:

- `scripts/lint.sh --fix`: three formatting-only corrections reviewed, `lint: ok`.
- `scripts/lint.sh`: `lint: ok`; advisory warnings occur only in unchanged files.
- `swift build`: `Build complete! (21.39s)`.
- `swift test`: 3437 tests in 443 suites passed in 14.831 seconds of test execution.
- `git diff --check` and all local links in this report passed.

The independent test-value/redundancy review found no blocking issue. Linux validation belongs to
the PR CI run.
This audit uses deterministic scripted/local process tests; it does not claim live Telegram/MCP,
paid inference, Apple Speech cancellation profiling, or production daemon deployment validation.
