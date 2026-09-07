import ClawCore
import Foundation
import Testing

@testable import ClawData

@Suite struct CoderJobProcessTests {
  @Test func launchEventsRequireCurrentLaunchAndRunningReservation() throws {
    // given
    let fixture = try CoderStoreFixture()
    let id = try fixture.admittedID()
    let first = CoderStoreFixture.receipt()
    #expect(throws: StoreError.self) {
      try fixture.store.recordProcess(id: id, event: .willLaunch(first), now: fixture.now)
    }
    #expect(try fixture.store.markRunning(id: id, now: fixture.now))
    try fixture.store.recordProcess(id: id, event: .didLaunch(first), now: fixture.now)
    #expect(try fixture.store.job(id: id)?.ownership == CoderProcessOwnership.none)
    try fixture.store.recordProcess(id: id, event: .willLaunch(first), now: fixture.now)
    try fixture.store.recordProcess(
      id: id,
      event: .stopped(launchID: first.launchID),
      now: fixture.now
    )
    let pending = CoderStoreFixture.receipt(phase: .codex)
    let launched = CoderStoreFixture.receipt(id: pending.launchID, phase: .codex, launched: true)
    try fixture.store.recordProcess(id: id, event: .willLaunch(pending), now: fixture.now)
    _ = try fixture.store.requestCancellation(id: id, now: fixture.now)
    // when
    try fixture.store.recordProcess(id: id, event: .didLaunch(first), now: fixture.now)
    let stillPending = try #require(try fixture.store.job(id: id))
    #expect(stillPending.processReceipt == pending)
    #expect(stillPending.ownership == .launching)
    try fixture.store.recordProcess(id: id, event: .didLaunch(launched), now: fixture.now)
    try fixture.store.recordProcess(
      id: id,
      event: .stopped(launchID: first.launchID),
      now: fixture.now
    )
    try fixture.store.recordProcess(
      id: id,
      event: .unresolved(launchID: first.launchID),
      now: fixture.now
    )
    try fixture.store.recordProcess(id: id, event: .didLaunch(first), now: fixture.now)
    // then
    #expect(try fixture.store.job(id: id)?.processReceipt == launched)
    #expect(try fixture.store.job(id: id)?.ownership == .owned)
    #expect(throws: StoreError.self) {
      try fixture.store.recordProcess(id: id, event: .willLaunch(first), now: fixture.now)
    }
    try fixture.store.recordProcess(
      id: id,
      event: .unresolved(launchID: pending.launchID),
      now: fixture.now
    )
    _ = try fixture.complete(id: id, expected: .stopping, state: .cancelled, release: false)
    #expect(throws: StoreError.self) {
      try fixture.store.releaseResolvedReservation(id: id, now: fixture.now)
    }
    try fixture.store.recordProcess(
      id: id,
      event: .stopped(launchID: pending.launchID),
      now: fixture.now
    )
    #expect(try fixture.store.job(id: id)?.slotReserved == true)
    #expect(throws: StoreError.self) {
      try fixture.store.recordProcess(id: id, event: .willLaunch(first), now: fixture.now)
    }
    try fixture.store.releaseResolvedReservation(id: id, now: fixture.now)
    #expect(try fixture.store.reservedJobs().isEmpty)
  }
}
