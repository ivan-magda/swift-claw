import ClawCore
import ClawData
import Foundation
import GRDB
import Testing

@testable import ClawGateway

@Suite struct MemoryDeleteLifecycleTests {
  @Test func deleteLifecycleRemovesTheRowWithAuditAndAck() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()
    let item = try harness.seedItem(text: "obsolete fact", kind: .user, day: 86_400)

    // when
    let deleteOutcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/memory delete \(item.id)")
    )
    let yesOutcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 2, from: 42, text: "yes")
    )

    // then
    #expect(deleteOutcome == .processed)
    #expect(yesOutcome == .processed)
    #expect(try harness.memory.get(id: item.id) == nil)
    #expect(try harness.auditActions().contains("memory_delete"))

    let deleteSent = await harness.transport.sent
    #expect(deleteSent.last?.text == MemoryReplies.deleted(id: item.id))

    // when
    let reviewOutcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 3, from: 42, text: "/memory")
    )

    // then
    #expect(reviewOutcome == .processed)
    let reviewSent = await harness.transport.sent
    #expect(reviewSent.last?.text == MemoryReplies.emptyReview(kind: nil))
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func redeliveredDeleteYesIsSkippedWithoutASecondAudit() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()
    let item = try harness.seedItem(text: "obsolete fact", kind: .user, day: 86_400)
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/memory delete \(item.id)")
    )
    let yesUpdate = textUpdate(id: 2, from: 42, text: "yes")
    let firstOutcome = await harness.router.handle(rawUpdate: yesUpdate)

    // when
    let secondOutcome = await harness.router.handle(rawUpdate: yesUpdate)

    // then
    #expect(firstOutcome == .processed)
    #expect(secondOutcome == .skipped)
    #expect(try harness.memory.get(id: item.id) == nil)
    #expect(try harness.auditActions().filter { $0 == "memory_delete" }.count == 1)
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func deleteCancelledKeepsTheRow() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()
    let item = try harness.seedItem(text: "obsolete fact", kind: .user, day: 86_400)
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/memory delete \(item.id)")
    )

    // when
    let outcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 2, from: 42, text: "cancel")
    )

    // then
    #expect(outcome == .processed)
    #expect(try harness.memory.get(id: item.id) != nil)
    #expect(try harness.auditActions().contains("memory_delete") == false)
    let sent = await harness.transport.sent
    #expect(sent.last?.text == MemoryReplies.cancelled)
    #expect(await harness.dispatcher.calls.isEmpty)
  }

  @Test func deleteParkedAfterRememberReplacesItSoYesDeletesInsteadOfSaving() async throws {
    // given
    let harness = try MemoryRoutingHarness.make()
    let seeded = try harness.seedItem(text: "seeded fact", kind: .user, day: 86_400)
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 1, from: 42, text: "/remember new fact")
    )
    _ = await harness.router.handle(
      rawUpdate: textUpdate(id: 2, from: 42, text: "/memory delete \(seeded.id)")
    )

    // when
    let outcome = await harness.router.handle(rawUpdate: textUpdate(id: 3, from: 42, text: "yes"))

    // then
    #expect(outcome == .processed)
    #expect(try harness.memory.get(id: seeded.id) == nil)
    #expect(try harness.memoryItemCount() == 0)
    #expect(try harness.auditActions().contains("memory_delete"))
    #expect(try harness.auditActions().contains("memory_write") == false)
    let sent = await harness.transport.sent
    #expect(sent.last?.text == MemoryReplies.deleted(id: seeded.id))
    #expect(await harness.dispatcher.calls.isEmpty)
  }
}
