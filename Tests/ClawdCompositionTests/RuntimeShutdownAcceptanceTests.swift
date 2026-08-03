import ClawAgent
import ClawCore
import ClawData
import ClawGateway
import ClawLLM
import ClawTestSupport
import Foundation
import GRDB
import Logging
import Testing

@testable import clawd

/// Shutdown acceptance driven through the real `DaemonRuntimeBundle`: a lane held **live inside a
/// composed ChatGPT provider's SSE and its nested HTTP exchange**, carried by a bundle whose real
/// service graph (the production-ordered `LaneAdmissionShutdownService`) closes admission, joins the
/// producer, and records the drain result the bundle exposes — which is then handed to the real
/// `RuntimeShutdownCoordinator` exactly as `RunCommand` sequences it. Proves the clean-drain ordering
/// (bundle drain → credential → llm → telegram → tool) and the grace-timeout path: active run IDs
/// surface through the bundle, no dependent resource closes, a recording fatal terminator fires
/// (never the production `_exit`), and a real `RUNNING` row is left for boot reconciliation.
@Suite struct RuntimeShutdownAcceptanceTests {
  /// A held lane whose work runs a composed provider stream to termination, so joining the lane joins
  /// the LLM producer and its nested HTTP exchange.
  private struct HeldLane: Sendable {
    let registry: SessionLaneRegistry
    let hold: ScriptedStreamHold
    let join: TerminationBox
    let stack: ProviderStack
  }

  private func startHeldLane(
    sessionId: Int64,
    runId: Int64
  ) async throws -> HeldLane {
    let hold = ScriptedStreamHold()
    let http = ScriptedHTTPExecutor([
      .blockedStream(
        CompositionAcceptance.okHead,
        CompositionAcceptance.terminalRound(tokens: (5, 2)),
        hold
      )
    ])
    let stack = try CompositionAcceptance.makeStack(http: http, store: FreshCredentialStore())
    let registry = SessionLaneRegistry()
    let join = TerminationBox()

    let admission = await registry.enqueue(sessionID: sessionId, runID: runId) {
      let session = stack.provider.stream(
        request: ChatRequest(
          model: stack.wireModel,
          messages: [ChatMessage(role: .user, content: "hi")],
          maxOutputTokens: 256
        )
      )
      let termination = await session.awaitTermination()
      await join.set(termination)
    }
    #expect(admission == .accepted)

    // The lane is now live inside the provider's SSE producer and its nested HTTP exchange.
    await hold.started.wait()
    return HeldLane(registry: registry, hold: hold, join: join, stack: stack)
  }

  // MARK: - Clean drain

  @Test func cleanDrainThroughTheBundleJoinsTheProducerThenRunsCleanupInOrder() async throws {
    // given — a lane held live inside composed provider SSE, carried by a real runtime bundle
    let lane = try await startHeldLane(sessionId: 1, runId: 10)
    let booted = AsyncGate()
    let bundle = Self.makeBundle(lane: lane, clock: ContinuousClock(), boot: { booted.open() })
    let recorder = StepRecorder()

    // when — run the real service graph, release the SSE, then stop the graph. Its lane-admission
    // service closes admission, joins the producer, and records the drain result on the bundle.
    let daemonTask = Task { try await bundle.daemon.run() }
    await booted.wait()
    lane.hold.release.open()
    daemonTask.cancel()
    try await daemonTask.value

    // then — the producer/exchange actually joined and the bundle carries a clean drain
    #expect(await lane.join.isCompleted)
    let laneDrain = await bundle.laneShutdownOutcome.value() ?? .drained
    #expect(laneDrain == .drained)

    // when — the coordinator runs the dependent cleanup after the bundle's clean drain, exactly as
    // `RunCommand` sequences it
    let coordinator = RuntimeShutdownCoordinator(
      logger: Self.silent,
      redactor: SecretRedactor(secretValues: [])
    )
    let outcome = await coordinator.shutDown(
      daemonError: nil,
      laneDrain: laneDrain,
      dependent: Self.recordingCleanup(recorder)
    )

    // then — credential shutdown, then the three client closes, in the mandated order
    #expect(await recorder.events == ["credential", "llm", "telegram", "tool"])
    if case .clean = outcome {
    } else {
      Issue.record("expected clean outcome, got \(outcome)")
    }
  }

  // MARK: - Grace timeout

  @Test(.timeLimit(.minutes(1)))
  func graceTimeoutThroughTheBundleSkipsCleanupReportsRunIDsAndLeavesARunningRow() async throws {
    // given — a real RUNNING run row and a lane held live inside composed SSE that will not finish,
    // carried by a real runtime bundle whose drain deadline fires at once on a manual clock
    let (writer, sessionId, runId) = try Self.makeRunningRun()
    let lane = try await startHeldLane(sessionId: sessionId, runId: runId)
    let booted = AsyncGate()
    let bundle = Self.makeBundle(lane: lane, clock: ScriptedClock { _ in }, boot: { booted.open() })
    let recorder = StepRecorder()

    // when — run and then stop the service graph; the held producer outlives cancellation and the
    // grace window expires immediately, so the bundle records a timeout, not a drain
    let daemonTask = Task { try await bundle.daemon.run() }
    await booted.wait()
    daemonTask.cancel()
    try await daemonTask.value

    // then — the still-active run is reported through the bundle, not drained
    let laneDrain = await bundle.laneShutdownOutcome.value() ?? .drained
    guard case .timedOut(let activeRunIDs) = laneDrain else {
      Issue.record("expected timedOut, got \(laneDrain)")
      lane.hold.release.open()
      _ = await lane.registry.drain(timeout: .seconds(5), clock: ContinuousClock())
      return
    }
    #expect(activeRunIDs == [runId])

    // when — the coordinator refuses every dependent close on a fatal lane timeout
    let coordinator = RuntimeShutdownCoordinator(
      logger: Self.silent,
      redactor: SecretRedactor(secretValues: [])
    )
    let outcome = await coordinator.shutDown(
      daemonError: nil,
      laneDrain: laneDrain,
      dependent: Self.recordingCleanup(recorder)
    )

    // then — no credential or client cleanup ran, and the run IDs pass through untouched
    #expect(await recorder.events == [])
    guard case .fatalLaneTimeout(let fatalRunIDs) = outcome else {
      Issue.record("expected fatalLaneTimeout, got \(outcome)")
      lane.hold.release.open()
      return
    }
    #expect(fatalRunIDs == [runId])

    // when — the fatal path terminates through a recording terminator, never production `_exit`
    let recordedCode = ExitCodeBox()
    let terminator = FatalProcessTerminator { code in
      recordedCode.set(code)
      throw FatalExitSentinel()
    }
    #expect(throws: FatalExitSentinel.self) {
      try terminator.fatalLaneDrainTimeout(activeRunIDs: fatalRunIDs, logger: Self.silent)
    }
    #expect(recordedCode.value == 1)

    // then — the run is still RUNNING on disk for the boot reconciler to sweep
    let state = try Self.runState(writer, runId: runId)
    #expect(state == RunState.running.rawValue)

    // cleanup — release the held producer so no task is left parked past the test
    lane.hold.release.open()
    _ = await lane.registry.drain(timeout: .seconds(5), clock: ContinuousClock())
  }

  // MARK: - Helpers

  private static let silent = Logger(label: "test", factory: { _ in SwiftLogNoOpLogHandler() })

  /// A real `DaemonRuntimeBundle` over the held lane's registry and the composed credential source,
  /// built with the production service-ordering helper so its daemon carries the same lane-admission
  /// service the composition root wires. Cancelling `daemon.run()` stops the graph, driving that
  /// service through close-admission → cancel → drain → record on `laneShutdownOutcome` — the exact
  /// handoff `RunCommand` reads. `boot` fires once the graph is running, so a test can stop it after.
  private static func makeBundle(
    lane: HeldLane,
    clock: any Clock<Duration>,
    boot: @escaping @Sendable () async -> Void
  ) -> DaemonRuntimeBundle {
    let outcome = LaneShutdownOutcome()
    let laneAdmission = LaneAdmissionShutdownService(
      lanes: lane.registry,
      outcome: outcome,
      drainTimeout: .seconds(5),
      clock: clock,
      logger: silent
    )
    let daemon = Daemon(
      services: DaemonBuilder.servicesWithLaneAdmissionLast(base: [], laneAdmission: laneAdmission),
      boot: boot,
      logger: silent,
      gracefulShutdownSignals: [],
      gracefulShutdownSeconds: 30
    )
    return DaemonRuntimeBundle(
      daemon: daemon,
      lanes: lane.registry,
      credentialSource: lane.stack.credentialSource,
      laneShutdownOutcome: outcome
    )
  }

  private static func recordingCleanup(
    _ recorder: StepRecorder
  ) -> RuntimeShutdownCoordinator.DependentCleanup {
    RuntimeShutdownCoordinator.DependentCleanup(
      commitCredentials: { await recorder.record("credential") },
      closeLLMClient: { await recorder.record("llm") },
      closeTelegramClient: { await recorder.record("telegram") },
      closeToolClient: { await recorder.record("tool") }
    )
  }

  private static func makeRunningRun() throws -> (
    writer: any DatabaseWriter, sessionId: Int64, runId: Int64
  ) {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let runs = RunStoreGRDB(writer: queue)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let chatId: Int64 = 99
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: SessionKey.telegramDM(chatId: chatId),
        chatId: chatId,
        userId: chatId,
        text: "hi",
        isEdited: false,
        ts: now
      )
    )
    let sessionId = try #require(claim.sessionId)
    let runId = try #require(claim.runId)
    _ = try runs.pickUp(runId: runId, policyVersion: nil, now: now)  // PENDING → RUNNING
    return (queue, sessionId, runId)
  }

  private static func runState(_ writer: any DatabaseWriter, runId: Int64) throws -> String? {
    try writer.read { db in
      try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runId])
    }
  }
}

// MARK: - Doubles

private actor TerminationBox {
  private var termination: LLMStreamTermination?

  func set(_ value: LLMStreamTermination) {
    termination = value
  }

  var isCompleted: Bool {
    if case .completed = termination {
      return true
    }
    return false
  }
}

private actor StepRecorder {
  private(set) var events: [String] = []

  func record(_ name: String) {
    events.append(name)
  }
}
