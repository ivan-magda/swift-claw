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
    let dispatcher: FakeTurnRunner
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
    let dispatcher = FakeTurnRunner()
    let router = MessageRouter(
      processed: ProcessedUpdateStoreGRDB(writer: queue),
      sessionMessages: SessionMessageStoreGRDB(writer: queue),
      accessControl: AccessControl(allowlist: allowlist),
      transport: transport,
      turnRunner: dispatcher,
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
