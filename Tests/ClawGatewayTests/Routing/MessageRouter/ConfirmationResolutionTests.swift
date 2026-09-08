import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawGateway

@Suite struct ConfirmationResolutionTests {
  @Test func yesCommitsTheMemoryRowWithAuditAndAcks() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/remember project: ship 3a")
    )

    // when
    let outcome = await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 42, text: "yes"))

    // then
    #expect(outcome == .processed)
    #expect(try harness.memoryItemCount() == 1)
    #expect(try harness.auditActions().contains("memory_write"))
    let sent = await harness.transport.sent
    #expect(sent.last?.text.hasPrefix("Saved memory") == true)
    let sessionId = try harness.ownerSessionId()
    #expect(await harness.pendingConfirmations.pending(sessionId: sessionId) == nil)
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func redeliveredYesDoesNotDoubleWrite() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/remember project: ship 3a")
    )
    let yesUpdate = textUpdate(id: 2, from: 42, text: "yes")
    _ = await harness.router.handle(rawUpdate: yesUpdate)

    // when
    let secondOutcome = await harness.router.handle(rawUpdate: yesUpdate)

    // then
    #expect(secondOutcome == .skipped)
    #expect(try harness.memoryItemCount() == 1)
    #expect(try harness.auditActions().filter { $0 == "memory_write" }.count == 1)
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func noCancelsWithoutWriting() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/remember project: ship 3a")
    )

    // when
    let outcome = await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 42, text: "no"))

    // then
    #expect(outcome == .processed)
    #expect(try harness.memoryItemCount() == 0)
    let sent = await harness.transport.sent
    #expect(sent.last?.text == MemoryReplies.cancelled)
    let sessionId = try harness.ownerSessionId()
    #expect(await harness.pendingConfirmations.pending(sessionId: sessionId) == nil)
    #expect(try harness.messageCount(content: "no") == 0)
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func otherTextClearsPendingAndRunsANormalTurnUnclaimedAsACommand() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/remember project: ship 3a")
    )

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 2, from: 42, text: "what's the weather")
    )
    await harness.dispatcher.waitForCalls(atLeast: 1)

    // then
    #expect(outcome == .processed)
    #expect(await harness.dispatcher.calls.count == 1)
    #expect(try harness.messageCount(content: "what's the weather") == 1)
    #expect(try harness.memoryItemCount() == 0)
    let sessionId = try harness.ownerSessionId()
    #expect(await harness.pendingConfirmations.pending(sessionId: sessionId) == nil)
  }

  @Test func yesWithNoPendingEntryIsJustANormalTurn() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()

    // when
    let outcome = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 42, text: "yes"))
    await harness.dispatcher.waitForCalls(atLeast: 1)

    // then
    #expect(outcome == .processed)
    #expect(await harness.dispatcher.calls.count == 1)
  }

  @Test func confirmedDeleteEntryCommitsForgetWithAudit() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()
    let seeded = try harness.seedItem(text: "obsolete fact", kind: .user)
    let sessionId = try harness.ownerSessionId()
    await harness.pendingConfirmations.park(
      .deleteItem(id: seeded.id),
      sessionId: sessionId
    )

    // when
    let outcome = await harness.router.handle(rawUpdate: textUpdate(id: 9, from: 42, text: "yes"))

    // then
    #expect(outcome == .processed)
    #expect(try harness.memory.get(id: seeded.id) == nil)
    #expect(try harness.auditActions().contains("memory_delete"))
    let sent = await harness.transport.sent
    #expect(sent.last?.text == MemoryReplies.deleted(id: seeded.id))
    #expect(await harness.pendingConfirmations.pending(sessionId: sessionId) == nil)
  }

  @Test func nonDiskCommitFailureSurfacesAnOwnerErrorAndClearsThePending() async throws {
    // given
    struct FailingMemoryCommands: MemoryCommandStore {
      func applyRemember(
        updateId: Int64,
        item: NewMemoryItem,
        now: Date
      ) throws(StoreError) -> MemoryCommandResult {
        throw StoreError.unexpected("commit lost")
      }

      func applyForget(
        updateId: Int64,
        itemId: Int64,
        now: Date
      ) throws(StoreError) -> MemoryCommandResult {
        throw StoreError.unexpected("commit lost")
      }
    }

    let harness = try MemoryRoutingHarness.make(memoryCommands: FailingMemoryCommands())
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/remember project: ship 3a")
    )

    // when
    let yesUpdate = textUpdate(id: 2, from: 42, text: "yes")
    let outcome = await harness.router.handle(rawUpdate: yesUpdate)

    // then
    #expect(outcome == .processed)
    let sent = await harness.transport.sent
    #expect(sent.last?.text == MemoryReplies.saveFailed)
    #expect(try harness.memoryItemCount() == 0)
    let sessionId = try harness.ownerSessionId()
    #expect(await harness.pendingConfirmations.pending(sessionId: sessionId) == nil)
    #expect(await harness.dispatcher.calls.isEmpty)

    // when
    let secondOutcome = await harness.router.handle(rawUpdate: yesUpdate)

    // then
    #expect(secondOutcome == .skipped)
    #expect(try harness.messageCount(content: "yes") == 0)
  }

  @Test func diskFullCommitFailureKeepsThePendingEntryForRetryAfterCleanup() async throws {
    // given
    struct DiskFullMemoryCommands: MemoryCommandStore {
      func applyRemember(
        updateId: Int64,
        item: NewMemoryItem,
        now: Date
      ) throws(StoreError) -> MemoryCommandResult {
        throw StoreError.diskFull
      }

      func applyForget(
        updateId: Int64,
        itemId: Int64,
        now: Date
      ) throws(StoreError) -> MemoryCommandResult {
        throw StoreError.diskFull
      }
    }

    let harness = try MemoryRoutingHarness.make(memoryCommands: DiskFullMemoryCommands())
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/remember project: ship 3a")
    )

    // when
    let outcome = await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 42, text: "yes"))

    // then
    #expect(outcome == .storageFull)
    let sent = await harness.transport.sent
    #expect(sent.last?.text == Degradation.storageFull)
    let sessionId = try harness.ownerSessionId()
    #expect(await harness.pendingConfirmations.pending(sessionId: sessionId) != nil)
  }

  @Test func pendingLookupFailureFailsClosedInsteadOfLeakingAYesIntoATurn() async throws {
    // given
    let harness = try MemoryRoutingHarness.make(
      routerSessionMessages: {
        FakeSessionMessageStore(
          failures: [.findSession: .unexpected("lookup lost")],
          delegatingTo: $0
        )
      }
    )
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/remember project: ship 3a")
    )

    // when
    let outcome = await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 42, text: "yes"))

    // then
    #expect(outcome == .transientFailure)
    #expect(try harness.messageCount(content: "yes") == 0)
    #expect(try harness.memoryItemCount() == 0)
    let sessionId = try harness.ownerSessionId()
    #expect(await harness.pendingConfirmations.pending(sessionId: sessionId) != nil)
    #expect(await harness.dispatcher.calls.isEmpty)
  }
}
