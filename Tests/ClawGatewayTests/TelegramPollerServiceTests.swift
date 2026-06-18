import ClawCore
import ClawData
import Foundation
import Logging
import Testing

@testable import ClawGateway

@Suite struct TelegramPollerServiceTests {
  private func makeStack(
    batches: [[RawUpdate]],
    allowed: [Int64],
    throwOnGetUpdates: TelegramError? = nil,
    sendError: TelegramError? = nil
  ) throws -> (TelegramPollerService, RecordingTransport, UpdateCursorStoreGRDB) {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)

    let allowlist = AllowlistStoreGRDB(writer: queue)
    try allowlist.seedAllowlist(userIds: allowed)

    let transport = RecordingTransport(
      batches: batches,
      throwAfterExhaustion: throwOnGetUpdates,
      sendError: sendError
    )
    let router = MessageRouter(
      updateStore: ProcessedUpdateStoreGRDB(writer: queue),
      accessControl: AccessControl(allowlist: allowlist),
      transport: transport,
      logger: Logger(label: "test")
    )
    let cursor = UpdateCursorStoreGRDB(writer: queue)

    let poller = TelegramPollerService(
      transport: transport,
      router: router,
      cursor: cursor,
      pollTimeout: 0,
      logger: Logger(label: "test")
    )

    return (poller, transport, cursor)
  }

  /// Spins until `condition` holds or the deadline passes — the loop runs on another task,
  /// so the cursor/send side effects land asynchronously.
  private func waitUntil(
    _ condition: @Sendable () async -> Bool,
    timeout: Duration = .seconds(2)
  ) async throws {
    let start = ContinuousClock().now
    while await !condition() {
      if ContinuousClock().now - start > timeout {
        Issue.record("timed out waiting")
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  @Test func processesABatchAndAdvancesCursor() async throws {
    // given
    let (poller, transport, cursor) = try makeStack(
      batches: [[textUpdate(id: 100, from: 42, text: "hi")]],
      allowed: [42]
    )

    // when
    let task = Task { try await poller.run() }
    try await waitUntil { await transport.sentCount >= 1 }
    try await waitUntil { (try? cursor.loadCursor()) == 100 }
    task.cancel()
    try await task.value

    // then
    let sent = await transport.sent
    #expect(sent.first?.text == "You said: hi")
    #expect(try cursor.loadCursor() == 100)  // advanced LAST
  }

  @Test func cancellationStopsTheLoop() async throws {
    // given
    let (poller, _, _) = try makeStack(batches: [], allowed: [42])

    // when
    let task = Task { try await poller.run() }
    try await Task.sleep(for: .milliseconds(30))
    task.cancel()

    // then
    try await task.value  // returns promptly, no throw
  }

  @Test func poisonUpdateAdvancesCursorPastIt() async throws {
    // given — an update with no actionable content normalizes to nil → no reply, cursor advances
    let empty = RawUpdate(updateId: 200, message: nil, editedMessage: nil)
    let (poller, _, cursor) = try makeStack(batches: [[empty]], allowed: [42])

    // when
    let task = Task { try await poller.run() }
    try await waitUntil { (try? cursor.loadCursor()) == 200 }
    task.cancel()
    try await task.value

    // then
    #expect(try cursor.loadCursor() == 200)
  }

  @Test func transientSendFailureDoesNotAdvanceCursor() async throws {
    // given — a transient send failure must not advance the offset, else the update is acked
    // to Telegram and the owner's message is silently lost.
    let (poller, transport, cursor) = try makeStack(
      batches: [[textUpdate(id: 100, from: 42, text: "hi")]],
      allowed: [42],
      sendError: .transport("network down")
    )

    // when
    let task = Task { try await poller.run() }
    try await waitUntil { await transport.attempts >= 1 }  // the send was attempted…
    task.cancel()
    try await task.value

    // then
    #expect(try cursor.loadCursor() == nil)  // …but the offset did NOT advance
  }

  @Test func conflict409IsHandledLoudlyWithoutHotSpin() async throws {
    // given — getUpdates throws 409; react logs critical + backs off, the loop survives
    let (poller, _, _) = try makeStack(
      batches: [],
      allowed: [42],
      throwOnGetUpdates: .conflict409(description: "terminated by other getUpdates")
    )

    // when
    let task = Task { try await poller.run() }
    try await Task.sleep(for: .milliseconds(50))  // let it hit the 409 and enter back-off
    task.cancel()

    // then
    try await task.value  // returns cleanly, no throw/crash
  }
}
