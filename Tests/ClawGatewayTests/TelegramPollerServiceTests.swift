import ClawCore
import ClawData
import Foundation
import Logging
import Testing

@testable import ClawGateway

@Suite struct TelegramPollerServiceTests {
  private struct Stack {
    let poller: TelegramPollerService
    let transport: RecordingTransport
    let cursor: UpdateCursorStoreGRDB
  }

  private func makeStack(
    batches: [[RawUpdate]],
    allowed: [Int64],
    throwOnGetUpdates: TelegramError? = nil,
    sendError: TelegramError? = nil
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

    return Stack(poller: poller, transport: transport, cursor: cursor)
  }

  @Test func processesABatchAndAdvancesCursor() async throws {
    // given
    let stack = try makeStack(
      batches: [[textUpdate(id: 100, from: 42, text: "hi")]],
      allowed: [42]
    )

    // when — once the echo is sent and the loop stops, the synchronous advance has already run
    let task = Task { try await stack.poller.run() }
    await stack.transport.waitForSends(atLeast: 1)
    task.cancel()
    try await task.value

    // then
    let sent = await stack.transport.sent
    #expect(sent.first?.text == "You said: hi")
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
    // to Telegram and the owner's message is silently lost.
    let stack = try makeStack(
      batches: [[textUpdate(id: 100, from: 42, text: "hi")]],
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

  @Test func conflict409IsHandledLoudlyWithoutHotSpin() async throws {
    // given — getUpdates throws 409; react logs critical + backs off, the loop survives
    let stack = try makeStack(
      batches: [],
      allowed: [42],
      throwOnGetUpdates: .conflict409(description: "terminated by other getUpdates")
    )

    // when — wait until the 409 has been hit, then cancel mid-backoff
    let task = Task { try await stack.poller.run() }
    await stack.transport.waitForPolls(atLeast: 1)
    task.cancel()

    // then
    try await task.value  // returns cleanly, no throw/crash
  }
}
