import ClawCore
import Foundation
import Testing

@testable import ClawGateway

@Suite
struct PendingConfirmationRegistryTests {
  @Test
  func parkedEntryIsReadableUntilCleared() async throws {
    // given
    let registry = PendingConfirmationRegistry()
    let entry = try CommandConfirmation.rememberWrite(memoryWriteRequest(sessionID: 42))

    // when
    await registry.park(entry, sessionID: 42)
    let parked = await registry.pending(sessionID: 42)
    await registry.clear(sessionID: 42)
    let cleared = await registry.pending(sessionID: 42)

    // then
    #expect(parked == entry)
    #expect(cleared == nil)
  }

  @Test
  func reparkingReplacesPreviousEntryForSameSession() async throws {
    // given
    let registry = PendingConfirmationRegistry()
    let first = try CommandConfirmation.rememberWrite(memoryWriteRequest(sessionID: 42))
    let second = CommandConfirmation.deleteItem(id: 7)

    // when
    await registry.park(first, sessionID: 42)
    await registry.park(second, sessionID: 42)

    // then
    #expect(await registry.pending(sessionID: 42) == second)
  }

  @Test
  func sessionsAreIsolated() async throws {
    // given
    let registry = PendingConfirmationRegistry()
    let first = try CommandConfirmation.rememberWrite(memoryWriteRequest(sessionID: 42))
    let second = CommandConfirmation.deleteItem(id: 7)

    // when
    await registry.park(first, sessionID: 42)
    await registry.park(second, sessionID: 43)

    // then
    #expect(await registry.pending(sessionID: 42) == first)
    #expect(await registry.pending(sessionID: 43) == second)
  }

  private func memoryWriteRequest(sessionID: Int64) throws -> MemoryWriteRequest {
    try MemoryWriteBuilder.build(
      rawText: "owner prefers concise replies",
      kind: .user,
      sessionID: sessionID
    )
  }
}

@Suite
struct ConfirmationReplyTests {
  @Test("confirm keywords parse", arguments: ["yes", "y", " YES ", "\ny\t"])
  func confirmKeywordsParse(input: String) {
    // given

    // when
    let reply = ConfirmationReply.parse(input)

    // then
    #expect(reply == .confirm)
  }

  @Test("cancel keywords parse", arguments: ["no", "n", "cancel", " NO ", "\nCancel\t"])
  func cancelKeywordsParse(input: String) {
    // given

    // when
    let reply = ConfirmationReply.parse(input)

    // then
    #expect(reply == .cancel)
  }

  @Test("other inputs parse", arguments: ["", "yeah", "nope", "yes please", "cancel this memory"])
  func otherInputsParse(input: String) {
    // given

    // when
    let reply = ConfirmationReply.parse(input)

    // then
    #expect(reply == .other)
  }
}
