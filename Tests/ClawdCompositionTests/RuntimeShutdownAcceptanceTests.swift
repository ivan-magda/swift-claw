import ClawAgent
import ClawCore
import ClawData
import ClawGateway
import ClawHTTP
import ClawLLM
import ClawTelegram
import ClawTestSupport
import Foundation
import GRDB
import Logging
import Testing

@testable import clawd

/// Shutdown acceptance through the production builder and command orchestration.
@Suite
struct RuntimeShutdownAcceptanceTests {
  private struct HeldLane: Sendable {
    let coordination: DaemonBuilder.TurnCoordination
    let hold: ScriptedStreamHold
    let join: TerminationBox
    let credentialSource: any LLMCredentialSource
  }

  private func startHeldLane(sessionID: Int64, runID: Int64) async throws -> HeldLane {
    let hold = ScriptedStreamHold()
    let http = ScriptedHTTPExecutor([
      .blockedStream(
        CompositionAcceptance.okHead,
        CompositionAcceptance.terminalRound(tokens: (5, 2)),
        hold
      ),
    ])
    let stack = try CompositionAcceptance.makeStack(
      http: http,
      store: CompositionAcceptance.freshCredentialStore()
    )
    let coordination = DaemonBuilder.TurnCoordination()
    let join = TerminationBox()

    let admission = await coordination.lanes.enqueue(sessionID: sessionID, runID: runID) {
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

  @Test
  func cleanDrainThroughTheBundleJoinsTheProducerThenRunsCleanupInOrder() async throws {
    // given
    let lane = try await startHeldLane(sessionID: 1, runID: 10)
    let booted = AsyncGate()
    let recorder = StepRecorder()
    let composed = try Self.makeComposed(
      lane: lane,
      clock: ContinuousClock(),
      boot: {
        booted.open()
      },
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
    let (writer, sessionID, runID) = try Self.makeRunningRun()
    let lane = try await startHeldLane(sessionID: sessionID, runID: runID)
    let booted = AsyncGate()
    let recorder = StepRecorder()
    let logs = RecordingLogCapture()
    let composed = try Self.makeComposed(
      lane: lane,
      clock: ScriptedClock { _ in },
      boot: {
        booted.open()
      },
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
    #expect(
      logs.entries.contains {
        $0.message.contains(String(runID))
      }
    )
    let state = try Self.runState(writer, runID: runID)
    #expect(state == RunState.running.rawValue)

    lane.hold.release.open()
    _ = await lane.coordination.lanes.drain(timeout: .seconds(5), clock: ContinuousClock())
  }

  @Test
  func coderBootWorkJoinsBeforeDependentCleanup() async throws {
    // given
    let fixture = try CoderCompositionFixture(holdCleanup: true)
    defer { fixture.cleanup() }
    let coordination = DaemonBuilder.TurnCoordination()
    let coder = await fixture.builder.prepareCoder(coordination: coordination)
    let service = try #require(coder.service)
    let bootEntered = AsyncGate()
    let releaseBoot = AsyncGate()
    let laneCancelled = AsyncGate()
    let releaseLane = AsyncGate()
    let laneJoined = AsyncGate()
    defer {
      releaseBoot.open()
      releaseLane.open()
    }
    let closed = AsyncGate()
    let bundle = fixture.builder.runtimeBundle(
      services: [],
      coordination: coordination,
      credentialSources: [],
      boot: {
        do {
          try await service.start()
          let prepared = try await service.prepare(CoderCompositionFixture.request)
          let context = try fixture.approvedContext(prepared)
          _ = await coordination.lanes.enqueue(sessionID: context.sessionID, runID: context.runID) {
            do {
              _ = try await service.submit(prepared, context: context)
            } catch {
              Issue.record(error)
            }
            await withTaskCancellationHandler(
              operation: {
                await releaseLane.waitIgnoringCancellation()
              },
              onCancel: {
                laneCancelled.open()
              }
            )
            laneJoined.open()
          }
          _ = await fixture.backend.started.waitUntilOpen()
        } catch {
          Issue.record(error)
        }
        bootEntered.open()
        await releaseBoot.waitIgnoringCancellation()
      },
      coder: service,
      gracefulShutdownSignals: []
    )
    let composed = RunComposition.Composed(
      bundle: bundle,
      clients: RuntimeHTTPClients { _ in
        RuntimeHTTPClient(executor: AsyncHTTPExecutor(client: .shared)) {
          #expect(laneJoined.isOpen)
          #expect(fixture.backend.allowCleanup.isOpen)
          #expect((try? fixture.builder.stores.coderJobs.reservedJobs().isEmpty) == true)
          closed.open()
        }
      }
    )

    // when
    let command = Task {
      try await RunCommand.serveThenShutDown(
        composed: composed,
        redactionValues: [],
        logger: Self.silent
      )
    }
    #expect(await bootEntered.waitUntilOpen())
    command.cancel()
    releaseBoot.open()
    let cancelled = await laneCancelled.waitUntilOpen()
    releaseLane.open()
    let cleanupEntered = await fixture.backend.invocations[0].cleanupEntered.waitUntilOpen()
    fixture.backend.allowCleanup.open()
    let result = await command.result
    fixture.backend.releaseAll()
    try? await service.shutdown()
    await coordination.lanes.stopAcceptingAndCancel()
    _ = await coordination.lanes.drain(timeout: .seconds(5), clock: ContinuousClock())
    try result.get()

    // then
    #expect(cancelled)
    #expect(cleanupEntered)
    #expect(closed.isOpen)
  }

  @Test
  func coderUnresolvedCleanupRefusesDependentTeardown() async throws {
    // given
    let fixture = try CoderCompositionFixture(unresolvedCleanup: true)
    defer { fixture.cleanup() }
    let coordination = DaemonBuilder.TurnCoordination()
    let coder = await fixture.builder.prepareCoder(coordination: coordination)
    let service = try #require(coder.service)
    try await service.start()
    let prepared = try await service.prepare(CoderCompositionFixture.request)
    _ = try await service.submit(prepared, context: fixture.approvedContext(prepared))
    #expect(await fixture.backend.started.waitUntilOpen())
    let code = ExitCodeBox()
    let bundle = fixture.builder.runtimeBundle(
      services: [],
      coordination: coordination,
      credentialSources: [],
      boot: {},
      coder: service,
      gracefulShutdownSignals: []
    )
    let composed = RunComposition.Composed(
      bundle: bundle,
      clients: RuntimeHTTPClients { _ in
        RuntimeHTTPClient(executor: AsyncHTTPExecutor(client: .shared)) {
          Issue.record("Unresolved Coder ownership closed a dependent client")
        }
      }
    )

    // when
    let finished = AsyncGate()
    let command = Task {
      defer { finished.open() }
      try await RunCommand.serveThenShutDown(
        composed: composed,
        redactionValues: [],
        logger: Self.silent,
        terminator: FatalProcessTerminator { value in
          code.set(value)
          throw FatalExitSentinel()
        }
      )
    }
    fixture.backend.allowCompletion.open()
    let failedFromService = await finished.waitUntilOpen()
    if !failedFromService {
      command.cancel()
    }
    await #expect(throws: FatalExitSentinel.self) {
      try await command.value
    }
    fixture.backend.releaseAll()
    try? await service.shutdown()

    // then
    #expect(failedFromService)
    #expect(code.value == 1)
    #expect(try fixture.builder.stores.coderJobs.reservedJobs().count == 1)
  }

  // MARK: - Helpers

  private static let silent = Logger(label: "test") { _ in
    SwiftLogNoOpLogHandler()
  }

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
        RecordingCredentialSource(base: lane.credentialSource, recorder: recorder),
      ],
      boot: boot,
      laneDrainClock: clock,
      gracefulShutdownSignals: []
    )
    return RunComposition.Composed(
      bundle: bundle,
      clients: RuntimeHTTPClients { role in
        RuntimeHTTPClient(executor: AsyncHTTPExecutor(client: .shared)) {
          await recorder.record(Self.event(for: role))
        }
      }
    )
  }

  private static func event(for role: RuntimeHTTPClientRole) -> String {
    switch role {
    case .telegram:
      return "telegram"
    case .llm:
      return "llm"
    case .tool:
      return "tool"
    }
  }

  private static func makeRunningRun() throws -> (
    writer: any DatabaseWriter,
    sessionID: Int64,
    runID: Int64
  ) {
    let queue = try TestDatabase.make()
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let runs = RunStoreGRDB(writer: queue)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let chatID: Int64 = 99
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateID: 1,
        sessionKey: SessionKey.telegramDM(chatID: chatID),
        chatID: chatID,
        userID: chatID,
        text: "hi",
        isEdited: false,
        ts: now
      )
    )
    let sessionID = try #require(claim.sessionID)
    let runID = try #require(claim.runID)
    _ = try runs.pickUp(runID: runID, policyVersion: nil, now: now)  // PENDING → RUNNING
    return (queue, sessionID, runID)
  }

  private static func runState(_ writer: any DatabaseWriter, runID: Int64) throws -> String? {
    try writer.read { db in
      try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runID])
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

  func reject(generation: LLMCredentialGeneration, disposition: LLMCredentialRejection) async {
    await base.reject(generation: generation, disposition: disposition)
  }

  func shutdown() async throws {
    await recorder.record("credential")
    try await base.shutdown()
  }
}
