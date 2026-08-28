import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import Logging
import Synchronization
import Testing

@testable import ClawGateway

private actor BlockingTurnRunner: TurnDispatching {
  private(set) var callCount = 0
  private var started: CheckedContinuation<Void, Never>?
  private var release: CheckedContinuation<Void, Never>?

  func run(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    triggerMessageId: Int64
  ) async throws {
    callCount += 1
    started?.resume()
    started = nil
    await withCheckedContinuation { continuation in
      release = continuation
    }
  }

  func waitUntilStarted() async {
    guard callCount == 0 else {
      return
    }
    await withCheckedContinuation { continuation in
      started = continuation
    }
  }

  func finish() {
    release?.resume()
    release = nil
  }
}

@Suite struct TelegramPollerServiceTests {
  private struct Stack {
    let poller: TelegramPollerService
    let transport: RecordingTransport
    let cursor: UpdateCursorStoreGRDB
    let dispatcher: FakeTurnRunner
  }

  private func makeStack(
    batches: [[RawUpdate]],
    allowed: [Int64],
    throwOnGetUpdates: TelegramError? = nil,
    sendError: TelegramError? = nil,
    logger: Logger = TestLog.silent,
    clock: any Clock<Duration> = ContinuousClock()
  ) throws -> Stack {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)

    let allowlist = AllowlistStoreGRDB(writer: queue)
    try allowlist.seedAllowlist(userIds: allowed)

    let transport = RecordingTransport(
      batches: batches,
      throwAfterExhaustion: throwOnGetUpdates,
      sendError: sendError
    )
    let dispatcher = FakeTurnRunner()
    let router = MessageRouter(
      processed: ProcessedUpdateStoreGRDB(writer: queue),
      sessionMessages: SessionMessageStoreGRDB(writer: queue),
      commands: CommandStoreGRDB(writer: queue),
      memory: MemoryStoreGRDB(writer: queue),
      memoryCommands: MemoryCommandStoreGRDB(writer: queue),
      pendingConfirmations: PendingConfirmationRegistry(),
      botUsername: "claw_bot",
      accessControl: AccessControl(allowlist: allowlist),
      delivery: transport,
      turnRunner: dispatcher,
      imageCache: ImageCache(),
      lanes: SessionLaneRegistry(),
      schedule: makeIdleScheduleSurface(writer: queue),
      coordinator: ApprovalCoordinator(),
      doctor: StubDoctorReporter(),
      logger: TestLog.silent
    )
    let cursor = UpdateCursorStoreGRDB(writer: queue)

    let poller = TelegramPollerService(
      intake: transport,
      router: router,
      cursor: cursor,
      pollTimeout: 0,
      logger: logger,
      clock: clock
    )

    return Stack(poller: poller, transport: transport, cursor: cursor, dispatcher: dispatcher)
  }

  @Test func processesABatchAndAdvancesCursor() async throws {
    // given
    let stack = try makeStack(
      batches: [[textUpdate(id: 100, from: 42, text: "hi")]],
      allowed: [42]
    )

    // when — the batch (turn dispatch + synchronous advance) completes before the next poll begins
    let task = Task { try await stack.poller.run() }
    await stack.transport.waitForPolls(atLeast: 2)
    task.cancel()
    try await task.value

    // then
    #expect(await stack.dispatcher.calls.count == 1)  // the turn was dispatched
    #expect(try stack.cursor.loadCursor() == 100)  // advanced LAST
  }

  @Test func cancellationStopsTheLoop() async throws {
    // given
    let stack = try makeStack(batches: [], allowed: [42])

    // when
    let task = Task { try await stack.poller.run() }
    await stack.transport.waitForPolls(atLeast: 1)
    task.cancel()

    // then
    try await task.value  // returns promptly, no throw
  }

  @Test func requestsCallbackQueryUpdates() async throws {
    // given — an idle poller (no batches) so it only long-polls
    let stack = try makeStack(batches: [], allowed: [42])

    // when
    let task = Task { try await stack.poller.run() }
    await stack.transport.waitForPolls(atLeast: 1)
    task.cancel()
    try await task.value

    // then — callback_query rides the same allowed_updates as messages/edits (spec §6.1)
    #expect(
      await stack.transport.lastAllowedUpdates == ["message", "edited_message", "callback_query"]
    )
  }

  @Test func cursorAdvancesAfterEnqueueWithoutWaitingForTurnCompletion() async throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let allowlist = AllowlistStoreGRDB(writer: queue)
    try allowlist.seedAllowlist(userIds: [42])
    let transport = RecordingTransport(batches: [[textUpdate(id: 100, from: 42, text: "hi")]])
    let runner = BlockingTurnRunner()
    let router = MessageRouter(
      processed: ProcessedUpdateStoreGRDB(writer: queue),
      sessionMessages: SessionMessageStoreGRDB(writer: queue),
      commands: CommandStoreGRDB(writer: queue),
      memory: MemoryStoreGRDB(writer: queue),
      memoryCommands: MemoryCommandStoreGRDB(writer: queue),
      pendingConfirmations: PendingConfirmationRegistry(),
      botUsername: "claw_bot",
      accessControl: AccessControl(allowlist: allowlist),
      delivery: transport,
      turnRunner: runner,
      imageCache: ImageCache(),
      lanes: SessionLaneRegistry(),
      schedule: makeIdleScheduleSurface(writer: queue),
      coordinator: ApprovalCoordinator(),
      doctor: StubDoctorReporter(),
      logger: TestLog.silent
    )
    let cursor = UpdateCursorStoreGRDB(writer: queue)
    let poller = TelegramPollerService(
      intake: transport,
      router: router,
      cursor: cursor,
      pollTimeout: 0,
      logger: TestLog.silent
    )

    // when
    let task = Task { try await poller.run() }
    await runner.waitUntilStarted()
    await transport.waitForPolls(atLeast: 2)

    // then
    #expect(try cursor.loadCursor() == 100)
    await runner.finish()
    task.cancel()
    try await task.value
  }

  @Test func poisonUpdateAdvancesCursorPastIt() async throws {
    // given — an update with no actionable content normalizes to nil → no reply, cursor advances
    let empty = RawUpdate(updateId: 200, message: nil, editedMessage: nil)
    let stack = try makeStack(batches: [[empty]], allowed: [42])

    // when — a second poll only happens after the batch (incl. the synchronous advance) is done
    let task = Task { try await stack.poller.run() }
    await stack.transport.waitForPolls(atLeast: 2)
    task.cancel()
    try await task.value

    // then
    #expect(try stack.cursor.loadCursor() == 200)
  }

  @Test func transientSendFailureDoesNotAdvanceCursor() async throws {
    // given — a transient send failure must not advance the offset, else the update is acked
    // to Telegram and the reply is silently lost. An unauthorized sender takes the canned-reply
    // path, whose direct send is what fails here (the turn path has no direct send to fail).
    let stack = try makeStack(
      batches: [[textUpdate(id: 100, from: 7, text: "hi")]],
      allowed: [42],
      sendError: .transport("network down")
    )

    // when
    let task = Task { try await stack.poller.run() }
    await stack.transport.waitForAttempts(atLeast: 1)  // the send was attempted…
    task.cancel()
    try await task.value

    // then
    #expect(try stack.cursor.loadCursor() == nil)  // …but the offset did NOT advance
  }

  @Test(.timeLimit(.minutes(1)))
  func conflict409LogsCriticalBacksOffTenSecondsAndRepolls() async throws {
    // given — getUpdates repeatedly throws 409 and the injected clock holds each backoff
    let recovery = PollerRecoveryControl(expectedFirstDelay: .seconds(10))
    defer { recovery.releaseAll() }
    let logs = RecordingLogCapture()
    let stack = try makeStack(
      batches: [],
      allowed: [42],
      throwOnGetUpdates: .conflict409(description: "terminated by other getUpdates"),
      logger: logs.logger(),
      clock: recovery.clock
    )

    // when — observe the first backoff, release it, then hold the second one after the retry
    let task = Task { try await stack.poller.run() }
    await recovery.firstBackoffStarted.wait()
    recovery.allowRetry()
    await recovery.secondBackoffStarted.wait()
    task.cancel()

    // then — the fault is loud, the requested delay is exact, and one release permits one re-poll
    try await task.value
    #expect(recovery.requestedDelays == [.seconds(10), .seconds(10)])
    #expect(await stack.transport.pollCount == 2)
    let critical = try #require(logs.entries.first { entry in entry.level == .critical })
    #expect(critical.message.contains("409 Conflict"))
    #expect(critical.message.contains("terminated by other getUpdates"))
  }

  @Test(.timeLimit(.minutes(1)))
  func readTimeoutLogsErrorBacksOffThreeSecondsAndRepolls() async throws {
    // given — a socket read timeout surfaces as TelegramError.transport on every poll
    let recovery = PollerRecoveryControl(expectedFirstDelay: .seconds(3))
    defer { recovery.releaseAll() }
    let logs = RecordingLogCapture()
    let stack = try makeStack(
      batches: [],
      allowed: [42],
      throwOnGetUpdates: .transport("getUpdates: read timed out"),
      logger: logs.logger(),
      clock: recovery.clock
    )

    // when — observe the first backoff, release it, then hold the second one after the retry
    let task = Task { try await stack.poller.run() }
    await recovery.firstBackoffStarted.wait()
    recovery.allowRetry()
    await recovery.secondBackoffStarted.wait()
    task.cancel()

    // then — recovery reports the transport fault, requests its delay, and keeps polling
    try await task.value
    #expect(recovery.requestedDelays == [.seconds(3), .seconds(3)])
    #expect(await stack.transport.pollCount == 2)
    let error = try #require(logs.entries.first { entry in entry.level == .error })
    #expect(error.message.contains("telegram error"))
    #expect(error.message.contains("getUpdates: read timed out"))
  }
}

private final class PollerRecoveryControl: Sendable {
  let firstBackoffStarted = AsyncGate()
  let secondBackoffStarted = AsyncGate()

  private let retryAllowed = AsyncGate()
  private let subsequentBackoffHeld = AsyncGate()
  private let delays = Mutex<[Duration]>([])
  private let expectedFirstDelay: Duration

  init(expectedFirstDelay: Duration) {
    self.expectedFirstDelay = expectedFirstDelay
  }

  var clock: ScriptedClock {
    ScriptedClock { [self] delay in
      let sleepCount = delays.withLock { recorded in
        recorded.append(delay)
        return recorded.count
      }
      if sleepCount == 1 {
        #expect(delay == expectedFirstDelay)
        firstBackoffStarted.open()
        await retryAllowed.wait()
      } else {
        secondBackoffStarted.open()
        await subsequentBackoffHeld.wait()
      }
    }
  }

  var requestedDelays: [Duration] {
    delays.withLock { recorded in
      recorded
    }
  }

  func allowRetry() {
    retryAllowed.open()
  }

  func releaseAll() {
    retryAllowed.open()
    subsequentBackoffHeld.open()
  }
}
