import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawData

@Suite struct CoderJobStoreTests {
  @Test func admissionDeduplicatesBeforeCapacity() throws {
    // given
    let fixture = try CoderStoreFixture()
    let first = try fixture.admit(id: UUID(), limit: 1)
    // when
    let replay = try fixture.admit(id: UUID(), limit: 1)
    // then
    guard case .admitted(let original) = first, case .existing(let same) = replay else {
      Issue.record("Approved replay must return the already admitted job")
      return
    }
    #expect(same.id == original.id)
    #expect(same.origin == fixture.origin)
    #expect(same.prepared == fixture.prepared)
    #expect(same.createdAt == fixture.now)
    #expect(try fixture.store.reservedJobs().map(\.id) == [original.id])
  }
}

// MARK: - Reservation Admission

extension CoderJobStoreTests {
  @Test func onlyOneAdmissionWinsLastSlot() async throws {
    // given
    let first = try CoderStoreFixture()
    let second = try CoderStoreFixture(queue: first.queue, updateID: 2)
    let gate = AsyncGate()
    // when
    let outcomes = try await withThrowingTaskGroup(of: CoderAdmission.self) { group in
      for fixture in [first, second] {
        group.addTask {
          await gate.wait()
          return try fixture.admit(id: UUID(), limit: 1)
        }
      }
      gate.open()
      var results: [CoderAdmission] = []
      for try await result in group {
        results.append(result)
      }
      return results
    }
    // then
    #expect(
      outcomes.filter {
        if case .admitted = $0 {
          return true
        }
        return false
      }.count == 1
    )
    #expect(
      outcomes.filter {
        $0 == .busy
      }.count == 1
    )
    #expect(try first.store.reservedJobs().count == 1)
  }

  @Test func inPlaceReservationsExcludeRelatedWorkspaces() throws {
    // given
    let first = try CoderStoreFixture(
      prepared: CoderStoreFixture.localRequest(checkout: "/repo/main", common: "/repo/git")
    )
    _ = try first.admittedID()
    let sameCheckout = try CoderStoreFixture(
      queue: first.queue,
      updateID: 2,
      prepared: CoderStoreFixture.localRequest(checkout: "/repo/main", common: "/other/git")
    )
    let linked = try CoderStoreFixture(
      queue: first.queue,
      updateID: 3,
      prepared: CoderStoreFixture.localRequest(checkout: "/repo/linked", common: "/repo/git")
    )
    let separate = try CoderStoreFixture(
      queue: first.queue,
      updateID: 4,
      prepared: CoderStoreFixture.localRequest(
        checkout: "/repo/main",
        common: "/repo/git",
        workspace: .separate
      )
    )
    // when
    let checkoutOutcome = try sameCheckout.admit(id: UUID(), limit: 4)
    let linkedOutcome = try linked.admit(id: UUID(), limit: 4)
    let separateOutcome = try separate.admit(id: UUID(), limit: 4)
    // then
    #expect(checkoutOutcome == .workspaceBusy)
    #expect(linkedOutcome == .workspaceBusy)
    guard case .admitted = separateOutcome else {
      Issue.record("Separate checkout must not lock its source")
      return
    }
  }

  @Test func unresolvedOwnershipBlocksNewAdmissions() throws {
    // given
    let fixture = try CoderStoreFixture()
    let id = try fixture.admittedID()
    #expect(try fixture.store.markRunning(id: id, now: fixture.now))
    let receipt = CoderStoreFixture.receipt()
    try fixture.store.recordProcess(id: id, event: .willLaunch(receipt), now: fixture.now)
    try fixture.store.recordProcess(
      id: id,
      event: .unresolved(launchID: receipt.launchID),
      now: fixture.now
    )
    _ = try fixture.complete(id: id, state: .interrupted, release: false)
    let next = try CoderStoreFixture(queue: fixture.queue, updateID: 2)
    // when
    let outcome = try next.admit(id: UUID(), limit: 4)
    let replay = try fixture.admit(id: UUID(), limit: 1)
    // then
    #expect(outcome == .recoveryRequired)
    guard case .existing(let original) = replay else {
      Issue.record("Replay must still find the unresolved job")
      return
    }
    #expect(original.id == id)
  }
}
