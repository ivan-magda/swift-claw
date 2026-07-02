import ClawCore
import Foundation
import Testing

@testable import ClawGateway

@Suite struct PendingConfirmationRegistryTests {
  @Test func parkedEntryIsReadableUntilCleared() async throws {
    // given
    let registry = PendingConfirmationRegistry()
    let entry = try PendingConfirmation.rememberWrite(memoryWriteRequest(sessionId: 42))

    // when
    await registry.park(entry, sessionId: 42)
    let parked = await registry.pending(sessionId: 42)
    await registry.clear(sessionId: 42)
    let cleared = await registry.pending(sessionId: 42)

    // then
    #expect(parked == entry)
    #expect(cleared == nil)
  }

  @Test func reparkingReplacesPreviousEntryForSameSession() async throws {
    // given
    let registry = PendingConfirmationRegistry()
    let first = try PendingConfirmation.rememberWrite(memoryWriteRequest(sessionId: 42))
    let second = PendingConfirmation.deleteItem(id: 7)

    // when
    await registry.park(first, sessionId: 42)
    await registry.park(second, sessionId: 42)

    // then
    #expect(await registry.pending(sessionId: 42) == second)
  }

  @Test func sessionsAreIsolated() async throws {
    // given
    let registry = PendingConfirmationRegistry()
    let first = try PendingConfirmation.rememberWrite(memoryWriteRequest(sessionId: 42))
    let second = PendingConfirmation.deleteItem(id: 7)

    // when
    await registry.park(first, sessionId: 42)
    await registry.park(second, sessionId: 43)

    // then
    #expect(await registry.pending(sessionId: 42) == first)
    #expect(await registry.pending(sessionId: 43) == second)
  }

  private func memoryWriteRequest(sessionId: Int64) throws -> MemoryWriteRequest {
    try MemoryWriteBuilder.build(
      rawText: "owner prefers concise replies",
      kind: .user,
      sessionId: sessionId
    )
  }
}

@Suite struct ConfirmationReplyTests {
  @Test(
    "confirm keywords parse",
    arguments: [
      "yes",
      "y",
      " YES ",
      "\ny\t",
    ]
  )
  func confirmKeywordsParse(input: String) {
    // given

    // when
    let reply = ConfirmationReply.parse(input)

    // then
    #expect(reply == .confirm)
  }

  @Test(
    "cancel keywords parse",
    arguments: [
      "no",
      "n",
      "cancel",
      " NO ",
      "\nCancel\t",
    ]
  )
  func cancelKeywordsParse(input: String) {
    // given

    // when
    let reply = ConfirmationReply.parse(input)

    // then
    #expect(reply == .cancel)
  }

  @Test(
    "other inputs parse",
    arguments: [
      "",
      "yeah",
      "nope",
      "yes please",
      "cancel this memory",
    ]
  )
  func otherInputsParse(input: String) {
    // given

    // when
    let reply = ConfirmationReply.parse(input)

    // then
    #expect(reply == .other)
  }
}
