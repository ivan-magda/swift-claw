import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawGateway

struct CoderRecoveryTests {
  @Test func interruptionIsReportedOnceWithoutRerun() async throws {
    // given
    let fixture = try CoderServiceFixture()
    defer { fixture.cleanup() }
    let id = try fixture.seedUnfinished()
    // when
    try await fixture.service.start()
    try await fixture.service.shutdown()
    let next = fixture.restartedService()
    try await next.start()
    // then
    let job = try #require(try fixture.store.job(id: id))
    #expect(job.state == .interrupted)
    #expect(!job.slotReserved)
    #expect(job.result?.publication == .unknown(reportedURL: nil))
    #expect(try fixture.reports().count == 1)
    #expect(await fixture.backend.startedJobIDs.isEmpty)
    try await next.shutdown()
  }

  @Test func recoveryRetainsAmbiguousOwnershipAcrossRestarts() async throws {
    // given
    let fixture = try CoderServiceFixture(inspection: .liveOwned)
    defer { fixture.cleanup() }
    let id = try fixture.seedUnfinished(receipt: CoderServiceFixture.receipt(launched: true))
    // when
    try await fixture.service.start()
    try await fixture.service.shutdown()
    let next = fixture.restartedService()
    try await next.start()
    let another = CoderServiceFixture.request(index: 2)
    let context = try CoderServiceFixture.context(queue: fixture.queue, prepared: another, index: 2)
    let replay = try await next.submit(fixture.prepared, context: fixture.ownerContext)
    // then
    #expect(replay.id == id)
    await #expect(throws: CoderError.recoveryRequired) {
      try await next.submit(another, context: context)
    }
    #expect(try fixture.store.job(id: id)?.ownership == .unresolved)
    #expect(try fixture.store.job(id: id)?.slotReserved == true)
    #expect(try fixture.reports().count == 1)
    #expect(await fixture.backend.startedJobIDs.isEmpty)
    try await next.shutdown()
  }

  @Test func recoveryReleasesVerifiedStoppedOwnership() async throws {
    // given
    let fixture = try CoderServiceFixture(inspection: .unresolved)
    defer { fixture.cleanup() }
    let id = try fixture.seedUnfinished(receipt: CoderServiceFixture.receipt(launched: false))
    try await fixture.service.start()
    #expect(try fixture.store.job(id: id)?.slotReserved == true)
    try await fixture.service.shutdown()
    // when
    await fixture.inspector.set(.stopped)
    let next = fixture.restartedService()
    try await next.start()
    // then
    #expect(try fixture.store.job(id: id)?.ownership == .stopped)
    #expect(try fixture.store.job(id: id)?.slotReserved == false)
    #expect(try fixture.reports().count == 1)
    try await next.shutdown()
  }
}
