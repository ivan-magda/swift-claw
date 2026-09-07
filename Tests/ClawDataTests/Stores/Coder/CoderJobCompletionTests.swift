import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct CoderJobCompletionTests {
  @Test func completionAndNoticeCommitTogether() throws {
    // given
    let fixture = try CoderStoreFixture()
    let id = try fixture.admittedID()
    #expect(try fixture.store.markRunning(id: id, now: fixture.now))
    let outbox = OutboxStoreGRDB(writer: fixture.queue)
    let prompt = try #require(try outbox.pendingOutbound().first)
    try fixture.queue.write { db in
      try db.execute(
        sql: """
          CREATE TEMP TRIGGER reject_coder_notice BEFORE INSERT ON outbound_deliveries
          BEGIN SELECT RAISE(ABORT, 'fixture completion failure'); END
          """
      )
    }
    // when
    #expect(throws: StoreError.self) {
      try fixture.complete(id: id)
    }
    // then
    #expect(try fixture.store.job(id: id)?.state == .running)
    #expect(try outbox.pendingOutbound().count == 1)
    try fixture.queue.write { db in
      try db.execute(sql: "DROP TRIGGER reject_coder_notice")
    }
    #expect(try fixture.complete(id: id) == .committed)
    #expect(try fixture.complete(id: id) == .alreadyTerminal)
    let rows = try outbox.pendingOutbound()
    let report = try #require(
      rows.first {
        $0.payload == "Coder report"
      }
    )
    #expect(rows.count == 2)
    #expect(report.stepIndex > prompt.stepIndex)
    #expect(report.chatId == fixture.origin.chatID)
    #expect(try fixture.store.job(id: id)?.result == CoderStoreFixture.result())
    #expect(try fixture.store.reservedJobs().isEmpty)
  }

  @Test func cancellationWinsCompletionCompareAndSwap() throws {
    // given
    let fixture = try CoderStoreFixture()
    let id = try fixture.admittedID()
    #expect(try fixture.store.markRunning(id: id, now: fixture.now))
    #expect(try !fixture.store.markRunning(id: id, now: fixture.now))
    let stopping = try #require(try fixture.store.requestCancellation(id: id, now: fixture.now))
    // when
    let outcome = try fixture.complete(id: id)
    // then
    #expect(stopping.state == .stopping)
    #expect(outcome == .stateChanged(stopping))
    #expect(try !fixture.store.markRunning(id: id, now: fixture.now))
    #expect(try OutboxStoreGRDB(writer: fixture.queue).pendingOutbound().count == 1)
    #expect(try fixture.complete(id: id, expected: .stopping, state: .cancelled) == .committed)
    #expect(try fixture.store.requestCancellation(id: id, now: fixture.now)?.state == .cancelled)
  }

  @Test func releaseRequiresTerminalAndResolvedOwnership() throws {
    // given
    let fixture = try CoderStoreFixture()
    let id = try fixture.admittedID()
    #expect(try fixture.store.markRunning(id: id, now: fixture.now))
    let receipt = CoderStoreFixture.receipt()
    try fixture.store.recordProcess(id: id, event: .willLaunch(receipt), now: fixture.now)
    // when
    #expect(throws: StoreError.self) {
      try fixture.complete(id: id)
    }
    try fixture.store.recordProcess(
      id: id,
      event: .stopped(launchID: receipt.launchID),
      now: fixture.now
    )
    #expect(throws: StoreError.self) {
      try fixture.store.releaseResolvedReservation(id: id, now: fixture.now)
    }
    // then
    #expect(try fixture.store.job(id: id)?.slotReserved == true)
    _ = try fixture.complete(id: id, release: false)
    try fixture.store.releaseResolvedReservation(id: id, now: fixture.now)
    try fixture.store.releaseResolvedReservation(id: id, now: fixture.now)
    #expect(try fixture.store.reservedJobs().isEmpty)
    #expect(try OutboxStoreGRDB(writer: fixture.queue).pendingOutbound().count == 2)
  }
}
