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

/// Shutdown acceptance: a real `SessionLaneRegistry` holding a lane **live inside a composed ChatGPT
/// provider's SSE and its nested HTTP exchange**, quiesced through the real drain and the real
/// `RuntimeShutdownCoordinator`. Proves the clean-drain ordering (admission → producer/exchange join →
/// credential → llm → telegram → tool) and the grace-timeout path: active run IDs surface, no
/// dependent resource closes, a recording fatal terminator fires (never the production `_exit`), and a
/// real `RUNNING` row is left for boot reconciliation.
@Suite struct RuntimeShutdownAcceptanceTests {
  /// A held lane whose work runs a composed provider stream to termination, so joining the lane joins
  /// the LLM producer and its nested HTTP exchange.
  private struct HeldLane: Sendable {
    let registry: SessionLaneRegistry
    let hold: AcceptanceStreamingHTTP.StreamHold
    let join: TerminationBox
    let stack: ProviderStack
  }

  private func startHeldLane(
    sessionId: Int64,
    runId: Int64
  ) async throws -> HeldLane {
    let hold = AcceptanceStreamingHTTP.StreamHold()
    let http = AcceptanceStreamingHTTP(streamScripts: [
      .init(
        head: CompositionAcceptance.okHead,
        chunks: CompositionAcceptance.terminalRound(tokens: (5, 2)),
        hold: hold
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

  @Test func cleanDrainJoinsTheProducerThenRunsCleanupInOrder() async throws {
    // given — a lane held live inside provider SSE
    let lane = try await startHeldLane(sessionId: 1, runId: 10)
    let recorder = StepRecorder()

    // when — release the SSE, close admission + cancel, and drain to quiescence
    lane.hold.release.open()
    lane.registry.closeAdmission()
    await lane.registry.stopAcceptingAndCancel()
    let drain = await lane.registry.drain(timeout: .seconds(5), clock: ContinuousClock())

    // then — the lane drained and its producer/exchange actually joined
    #expect(drain == .drained)
    #expect(await lane.join.isCompleted)

    // when — the coordinator runs the dependent cleanup after a clean drain
    let coordinator = RuntimeShutdownCoordinator(
      logger: Self.silent,
      redactor: SecretRedactor(secretValues: [])
    )
    let outcome = await coordinator.shutDown(
      daemonError: nil,
      laneDrain: drain,
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
  func graceTimeoutSkipsCleanupReportsRunIDsAndLeavesARunningRow() async throws {
    // given — a real RUNNING run row and a lane held live inside provider SSE that will not finish
    let (writer, sessionId, runId) = try Self.makeRunningRun()
    let lane = try await startHeldLane(sessionId: sessionId, runId: runId)
    let recorder = StepRecorder()

    // when — shutdown cancels the lane, but the join outlives cancellation and the grace window
    // expires immediately on the manual clock
    lane.registry.closeAdmission()
    await lane.registry.stopAcceptingAndCancel()
    let drain = await lane.registry.drain(timeout: .seconds(30), clock: ScriptedClock { _ in })

    // then — the still-active run is reported, not drained
    guard case .timedOut(let activeRunIDs) = drain else {
      Issue.record("expected timedOut, got \(drain)")
      lane.hold.release.open()
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
      laneDrain: drain,
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

private struct FatalExitSentinel: Error {}

private final class ExitCodeBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Int32?

  var value: Int32? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func set(_ code: Int32) {
    lock.lock()
    defer { lock.unlock() }
    stored = code
  }
}
