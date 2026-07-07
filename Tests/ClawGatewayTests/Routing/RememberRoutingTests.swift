import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawGateway

@Suite struct RememberRoutingTests {
  @Test func rememberParksAPendingWriteAndSendsTheConfirmPrompt() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/remember project: ship 3a")
    )

    // then
    #expect(outcome == .processed)
    let sent = await harness.transport.sent
    #expect(sent.count == 1)
    let prompt = try #require(sent.first)
    #expect(prompt.text.contains("Remember as project:"))
    #expect(prompt.text.contains("ship 3a"))
    #expect(try harness.memoryItemCount() == 0)
    let sessionId = try harness.ownerSessionId()
    let entry = await harness.pendingConfirmations.pending(sessionId: sessionId)
    guard case .command(.rememberWrite(let request)) = try #require(entry) else {
      Issue.record("expected a parked remember entry, got \(String(describing: entry))")
      return
    }
    #expect(request.item.text == "ship 3a")
    #expect(request.item.kind == .project)
    #expect(request.item.source == .owner)
    #expect(request.item.sessionId == sessionId)
  }

  @Test func rememberWithoutKindPrefixDefaultsToUser() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()

    // when
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/remember buy milk")
    )

    // then
    let sessionId = try harness.ownerSessionId()
    let entry = await harness.pendingConfirmations.pending(sessionId: sessionId)
    guard case .command(.rememberWrite(let request)) = try #require(entry) else {
      Issue.record("expected a parked remember entry, got \(String(describing: entry))")
      return
    }
    #expect(request.item.kind == .user)
    #expect(request.item.text == "buy milk")
  }

  @Test func duplicateRememberPromptsOnlyOnceAndDoesNotTouchTheSession() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()
    let update = textUpdate(id: 1, from: 42, text: "/remember buy milk")

    // when
    _ = await harness.router.handle(rawUpdate: update)
    let firstUpdatedTs = try sessionUpdatedTs(harness)
    let secondOutcome = await harness.router.handle(rawUpdate: update)

    // then
    #expect(secondOutcome == .skipped)
    #expect(await harness.transport.sent.count == 1)
    #expect(try sessionUpdatedTs(harness) == firstUpdatedTs)
  }

  @Test func rememberWithoutTextSendsUsage() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/remember")
    )

    // then
    #expect(outcome == .processed)
    let sent = await harness.transport.sent
    #expect(sent.map(\.text) == [MemoryReplies.rememberUsage])
    let sessionId = try harness.ownerSessionId()
    #expect(await harness.pendingConfirmations.pending(sessionId: sessionId) == nil)
  }

  @Test func rememberStrippedToEmptyIsRejected() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/remember \u{200B}\u{200C}")
    )

    // then
    #expect(outcome == .processed)
    let sent = await harness.transport.sent
    #expect(sent.map(\.text) == [MemoryReplies.nothingToSave])
    let sessionId = try harness.ownerSessionId()
    #expect(await harness.pendingConfirmations.pending(sessionId: sessionId) == nil)
    #expect(try harness.memoryItemCount() == 0)
  }

  @Test func rememberFromStrangerGetsPrivateBotReply() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()

    // when
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 7, text: "/remember steal this")
    )

    // then
    let sent = await harness.transport.sent
    #expect(sent.map(\.text) == [MessageRouter.privateBotText])
    #expect(try harness.memoryItemCount() == 0)
  }

  @Test func newRememberReplacesTheEarlierPendingOne() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()

    // when
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/remember first fact")
    )
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 2, from: 42, text: "/remember second fact")
    )

    // then
    let sessionId = try harness.ownerSessionId()
    let entry = await harness.pendingConfirmations.pending(sessionId: sessionId)
    guard case .command(.rememberWrite(let request)) = try #require(entry) else {
      Issue.record("expected a parked remember entry, got \(String(describing: entry))")
      return
    }
    #expect(request.item.text == "second fact")
  }

  private func sessionUpdatedTs(_ harness: MemoryRoutingHarness) throws -> Date? {
    try harness.queue.read { db in
      try Date.fetchOne(
        db,
        sql: "SELECT updated_ts FROM sessions WHERE session_key = ?",
        arguments: [SessionKey.telegramDM(chatId: 42)]
      )
    }
  }
}
