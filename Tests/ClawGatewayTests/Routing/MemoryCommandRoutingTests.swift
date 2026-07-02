import ClawCore
import Testing

@testable import ClawGateway

@Suite struct MemoryCommandRoutingTests {
  @Test func memoryReviewListsGroupedByKindWithProvenance() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()
    _ = try harness.seedItem(text: "ship 3a", kind: .project, day: 86_400)
    _ = try harness.seedItem(text: "prefers dark mode", kind: .user, day: 172_800)
    _ = try harness.seedItem(text: "cite sources", kind: .reference, day: 259_200)

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/memory")
    )

    // then
    #expect(outcome == .processed)
    let sent = await harness.transport.sent
    #expect(sent.count == 1)
    #expect(
      sent.first?.text
        == """
        user:
        2 · «prefers dark mode» · owner · 1970-01-03
        project:
        1 · «ship 3a» · owner · 1970-01-02
        reference:
        3 · «cite sources» · owner · 1970-01-04
        """
    )
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func emptyMemoryReviewUsesTheCannedEmptyReply() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/memory")
    )

    // then
    #expect(outcome == .processed)
    #expect(await harness.transport.sent.map(\.text) == [MemoryReplies.emptyReview(kind: nil)])
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func memoryFilterListsOnlyTheRequestedKind() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()
    _ = try harness.seedItem(text: "ship 3a", kind: .project, day: 86_400)
    _ = try harness.seedItem(text: "ship 3b", kind: .project, day: 172_800)
    _ = try harness.seedItem(text: "prefers dark mode", kind: .user, day: 259_200)

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/memory project")
    )

    // then
    #expect(outcome == .processed)
    let sent = await harness.transport.sent
    #expect(sent.count == 1)
    #expect(
      sent.first?.text
        == """
        project:
        2 · «ship 3b» · owner · 1970-01-03
        1 · «ship 3a» · owner · 1970-01-02
        """
    )
  }

  @Test func memoryShowPrintsTheFullItemReply() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()
    let item = try harness.seedItem(text: "ship 3a", kind: .project, day: 86_400)

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/memory show \(item.id)")
    )

    // then
    #expect(outcome == .processed)
    #expect(await harness.transport.sent.map(\.text) == [MemoryReplies.showItem(item)])
  }

  @Test func unknownMemoryShowIdRepliesNotFound() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/memory show 999")
    )

    // then
    #expect(outcome == .processed)
    #expect(await harness.transport.sent.map(\.text) == [MemoryReplies.notFound(id: 999)])
  }

  @Test func invalidMemoryArgumentsReplyWithUsage() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/memory nonsense")
    )

    // then
    #expect(outcome == .processed)
    #expect(await harness.transport.sent.map(\.text) == [MemoryReplies.memoryUsage])
  }

  @Test func memoryDeleteParksAConfirmationWithoutDeleting() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()
    let item = try harness.seedItem(text: "obsolete fact", kind: .user, day: 86_400)

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/memory delete \(item.id)")
    )

    // then
    #expect(outcome == .processed)
    #expect(try harness.memory.get(id: item.id) == item)
    #expect(
      await harness.transport.sent.map(\.text) == [MemoryReplies.deleteConfirmPrompt(item: item)]
    )
    let sessionId = try harness.ownerSessionId()
    #expect(
      await harness.pendingConfirmations.pending(sessionId: sessionId) == .deleteItem(id: item.id)
    )
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func deletingAnUnknownMemoryRepliesNotFoundAndParksNothing() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()
    let sessionId = try harness.ownerSessionId()

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/memory delete 999")
    )

    // then
    #expect(outcome == .processed)
    #expect(await harness.transport.sent.map(\.text) == [MemoryReplies.notFound(id: 999)])
    #expect(await harness.pendingConfirmations.pending(sessionId: sessionId) == nil)
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func strangerMemoryReviewGetsPrivateBotReplyWithoutLeakingMemory() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()
    _ = try harness.seedItem(text: "secret fact", kind: .user, day: 86_400)

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 7, text: "/memory")
    )

    // then
    #expect(outcome == .processed)
    #expect(await harness.transport.sent.map(\.text) == [MessageRouter.privateBotText])
    #expect(await harness.dispatcher.calls.isEmpty)
    #expect(try harness.memoryItemCount() == 1)
  }
}
