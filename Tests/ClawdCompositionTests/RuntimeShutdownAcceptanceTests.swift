import ClawAgent
import ClawCore
import ClawData
import ClawGateway
import ClawLLM
import ClawTelegram
import ClawTestSupport
import Foundation
import GRDB
import Logging
import Testing

@testable import clawd

/// Shutdown acceptance through the production builder and command orchestration.
@Suite struct RuntimeShutdownAcceptanceTests {
  private struct HeldLane: Sendable {
    let coordination: DaemonBuilder.TurnCoordination
    let hold: ScriptedStreamHold
    let join: TerminationBox
    let credentialSource: any LLMCredentialSource
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
    let coordination = DaemonBuilder.TurnCoordination()
    let join = TerminationBox()

    let admission = await coordination.lanes.enqueue(sessionID: sessionId, runID: runId) {
      let session = stack.binding.provider.stream(
        request: ChatRequest(
          model: stack.binding.wireModel,
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
    return HeldLane(
      coordination: coordination,
      hold: hold,
      join: join,
      credentialSource: stack.credentialSource
    )
  }

  // MARK: - Clean drain

  @Test func cleanDrainThroughTheBundleJoinsTheProducerThenRunsCleanupInOrder() async throws {
    // given
    let lane = try await startHeldLane(sessionId: 1, runId: 10)
    let booted = AsyncGate()
    let recorder = StepRecorder()
    let composed = try Self.makeComposed(
      lane: lane,
      clock: ContinuousClock(),
      boot: { booted.open() },
      recorder: recorder
    )

    // when
    let commandTask = Task {
      try await RunCommand.serveThenShutDown(
        composed: composed,
        redactionValues: [],
        logger: Self.silent
      )
    }
    await booted.wait()
    lane.hold.release.open()
    commandTask.cancel()
    try await commandTask.value

    // then
    #expect(await lane.join.isCompleted)
    #expect(await recorder.events == ["credential", "llm", "telegram", "tool"])
  }

  // MARK: - Grace timeout

  @Test(.timeLimit(.minutes(1)))
  func graceTimeoutThroughTheBundleSkipsCleanupReportsRunIDsAndLeavesARunningRow() async throws {
    // given
    let (writer, sessionId, runId) = try Self.makeRunningRun()
    let lane = try await startHeldLane(sessionId: sessionId, runId: runId)
    let booted = AsyncGate()
    let recorder = StepRecorder()
    let logs = RecordingLogCapture()
    let composed = try Self.makeComposed(
      lane: lane,
      clock: ScriptedClock { _ in },
      boot: { booted.open() },
      recorder: recorder
    )
    let recordedCode = ExitCodeBox()
    let terminator = FatalProcessTerminator { code in
      recordedCode.set(code)
      throw FatalExitSentinel()
    }

    // when
    let commandTask = Task {
      try await RunCommand.serveThenShutDown(
        composed: composed,
        redactionValues: [],
        logger: logs.logger(),
        terminator: terminator
      )
    }
    await booted.wait()
    commandTask.cancel()
    await #expect(throws: FatalExitSentinel.self) {
      try await commandTask.value
    }

    // then
    #expect(await recorder.events == [])
    #expect(recordedCode.value == 1)
    #expect(logs.entries.contains { $0.message.contains(String(runId)) })
    let state = try Self.runState(writer, runId: runId)
    #expect(state == RunState.running.rawValue)

    lane.hold.release.open()
    _ = await lane.coordination.lanes.drain(
      timeout: .seconds(5),
      clock: ContinuousClock()
    )
  }

  // MARK: - Helpers

  private static let silent = Logger(label: "test", factory: { _ in SwiftLogNoOpLogHandler() })

  private static func makeComposed(
    lane: HeldLane,
    clock: any Clock<Duration>,
    boot: @escaping @Sendable () async -> Void,
    recorder: StepRecorder
  ) throws -> RunComposition.Composed {
    let http = ScriptedHTTPExecutor([])
    let builder = try CompositionAcceptance.makeBuilder(http: http)
    let bundle = builder.runtimeBundle(
      services: [],
      coordination: lane.coordination,
      credentialSources: [
        RecordingCredentialSource(base: lane.credentialSource, recorder: recorder)
      ],
      boot: boot,
      laneDrainClock: clock,
      gracefulShutdownSignals: []
    )
    return RunComposition.Composed(
      bundle: bundle,
      clients: RuntimeHTTPClients { role in
        RuntimeHTTPClient(
          executor: AsyncHTTPExecutor(client: .shared),
          close: { await recorder.record(Self.event(for: role)) }
        )
      }
    )
  }

  private static func event(for role: RuntimeHTTPClientRole) -> String {
    switch role {
    case .telegram: return "telegram"
    case .llm: return "llm"
    case .tool: return "tool"
    }
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

private struct RecordingCredentialSource: LLMCredentialSource {
  let base: any LLMCredentialSource
  let recorder: StepRecorder

  func authorization() async throws -> LLMRequestAuthorization {
    try await base.authorization()
  }

  func reject(
    generation: LLMCredentialGeneration,
    disposition: LLMCredentialRejection
  ) async {
    await base.reject(generation: generation, disposition: disposition)
  }

  func shutdown() async throws {
    await recorder.record("credential")
    try await base.shutdown()
  }
}
