import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawGateway

struct CoderServiceTests {
  @Test func startupBlocksSubmissionDuringInspection() async throws {
    // given
    let fixture = try CoderServiceFixture(limit: 4)
    defer { fixture.cleanup() }
    _ = try fixture.seedUnfinished(receipt: CoderServiceFixture.receipt(launched: true))
    await fixture.inspector.holdInspection()
    defer { fixture.inspector.proceed.open() }
    // when
    let startup = Task {
      try await fixture.service.start()
    }
    #expect(await fixture.inspector.entered.waitUntilOpen())
    let submission = await fixture.submitAnotherApprovedOrigin()
    // then
    if case .failure(.unavailable) = submission {
    } else {
      Issue.record("Submission proceeded before startup reconciliation finished")
    }
    fixture.inspector.proceed.open()
    fixture.backend.releaseAll()
    try await startup.value
    try await fixture.service.shutdown()
  }

  @Test func cancelBeforeLaunchKeepsServiceHealthy() async throws {
    // given
    let script = ScriptedCoderBackend.Invocation(
      result: CoderServiceFixture.result(state: .cancelled),
      holdLaunch: true
    )
    let fixture = try CoderServiceFixture(scripts: [script])
    defer { fixture.cleanup() }
    try await fixture.service.start()
    let job = try await fixture.submitFirst()
    await script.entered.wait()
    // when
    _ = try await fixture.service.cancel(id: job.id, context: fixture.ownerContext)
    script.allowLaunch.open()
    let shutdown = Task {
      try await fixture.service.shutdown()
    }
    let outcome = await shutdown.result
    // then
    if case .failure(let error) = outcome {
      Issue.record(error)
    }
    #expect(await fixture.service.failure == nil)
    #expect(try fixture.store.job(id: job.id)?.state == .cancelled)
    #expect(try fixture.store.job(id: job.id)?.slotReserved == false)
    #expect(try fixture.reports().count == 1)
  }

  @Test func cancelKeepsReservationUntilJoined() async throws {
    // given
    let script = ScriptedCoderBackend.Invocation(
      result: CoderServiceFixture.result(),
      holdCleanup: true
    )
    let fixture = try CoderServiceFixture(scripts: [script])
    defer { fixture.cleanup() }
    try await fixture.service.start()
    let first = try await fixture.submitFirst()
    await fixture.backend.started.wait()
    let cancelReturned = AsyncGate()
    // when
    let cancellation = Task {
      let value = try await fixture.service.cancel(id: first.id, context: fixture.ownerContext)
      cancelReturned.open()
      return value
    }
    let returnedPromptly = await cancelReturned.waitUntilOpen()
    // then
    #expect(returnedPromptly)
    let reservation = Result {
      try fixture.store.job(id: first.id)?.slotReserved
    }
    script.allowCleanup.open()
    let stopped = try await cancellation.value
    await fixture.jobFinished.wait()
    #expect(stopped.state == .stopping)
    #expect(try reservation.get() == true)
    #expect(try fixture.store.job(id: first.id)?.slotReserved == false)
    #expect(try fixture.store.job(id: first.id)?.state == .cancelled)
    try await fixture.service.shutdown()
  }

  @Test func twoJobsStartBeforeEitherFinishes() async throws {
    // given
    let scripts = (0..<2).map { _ in
      ScriptedCoderBackend.Invocation(result: CoderServiceFixture.result())
    }
    let fixture = try CoderServiceFixture(limit: 2, scripts: scripts)
    defer { fixture.cleanup() }
    try await fixture.service.start()
    // when
    let first = try await fixture.submitFirst()
    let second = try await fixture.submitAnotherApprovedOrigin().get()
    let firstStarted = await scripts[0].started.waitUntilOpen()
    let secondStarted = await scripts[1].started.waitUntilOpen()
    let started = await fixture.backend.startedJobIDs
    let third = await fixture.submitAnotherApprovedOrigin(index: 3)
    // then
    #expect(Set(started) == Set([first.id, second.id]))
    #expect(firstStarted && secondStarted)
    #expect(third == .failure(.busy))
    fixture.backend.releaseAll()
    try await fixture.service.shutdown()
  }

  @Test func duplicateSubmissionDoesNotRelaunch() async throws {
    // given
    let fixture = try CoderServiceFixture()
    defer { fixture.cleanup() }
    try await fixture.service.start()
    // when
    let first = try await fixture.submitFirst()
    await fixture.backend.started.wait()
    let duplicate = try await fixture.submitFirst()
    fixture.backend.releaseAll()
    await fixture.jobFinished.wait()
    // then
    #expect(duplicate.id == first.id)
    #expect(await fixture.backend.startedJobIDs == [first.id])
    #expect(try fixture.reports().count == 1)
    try await fixture.service.shutdown()
  }

  @Test(arguments: [false, true])
  func revalidationRejectsChangedApproval(policyChanged: Bool) async throws {
    // given
    let fixture = try CoderServiceFixture()
    defer { fixture.cleanup() }
    try await fixture.service.start()
    let prepared =
      policyChanged ? CoderServiceFixture.request(policy: "old-policy") : fixture.prepared
    let context = try CoderServiceFixture.context(
      queue: fixture.queue,
      prepared: prepared,
      index: 2
    )
    await fixture.preparer.configure(changedIdentity: !policyChanged)
    // when
    await #expect(throws: CoderError.staleApproval) {
      try await fixture.service.submit(prepared, context: context)
    }
    // then
    #expect(try fixture.store.reservedJobs().isEmpty)
    #expect(await fixture.backend.startedJobIDs.isEmpty)
    try await fixture.service.shutdown()
  }

  @Test func requesterScopeIsEnforced() async throws {
    // given
    let fixture = try CoderServiceFixture()
    defer { fixture.cleanup() }
    try await fixture.service.start()
    let job = try await fixture.submitFirst()
    let caller = try CoderServiceFixture.context(
      queue: fixture.queue,
      prepared: CoderServiceFixture.request(index: 2),
      index: 2,
      ownerID: 88
    )
    // when
    await #expect(throws: CoderError.forbidden) {
      try await fixture.service.status(id: job.id, context: caller)
    }
    await #expect(throws: CoderError.forbidden) {
      try await fixture.service.cancel(id: job.id, context: caller)
    }
    // then
    #expect(try fixture.store.job(id: job.id)?.state != .stopping)
    fixture.backend.releaseAll()
    try await fixture.service.shutdown()
  }

  @Test func shutdownClosesAdmissionAndJoins() async throws {
    // given
    let script = ScriptedCoderBackend.Invocation(
      result: CoderServiceFixture.result(),
      holdCleanup: true
    )
    let fixture = try CoderServiceFixture(limit: 2, scripts: [script])
    defer { fixture.cleanup() }
    try await fixture.service.start()
    let job = try await fixture.submitFirst()
    await script.started.wait()
    // when
    let shutdown = Task {
      try await fixture.service.shutdown()
      return try fixture.store.job(id: job.id)
    }
    #expect(await script.cleanupEntered.waitUntilOpen())
    let another = await fixture.submitAnotherApprovedOrigin()
    let state = Result {
      try fixture.store.job(id: job.id)
    }
    // then
    if case .failure(.unavailable) = another {
    } else {
      Issue.record("Admission remained open")
    }
    script.allowCleanup.open()
    let atReturn = try await shutdown.value
    #expect(atReturn?.state == .cancelled)
    #expect(atReturn?.slotReserved == false)
    #expect(try state.get()?.state == .stopping)
    #expect(try state.get()?.slotReserved == true)
    #expect(try fixture.store.job(id: job.id)?.slotReserved == false)
  }

  @Test func admissionCannotResumeAfterShutdown() async throws {
    // given
    let fixture = try CoderServiceFixture()
    defer { fixture.cleanup() }
    try await fixture.service.start()
    await fixture.preparer.configure(hold: true)
    let proceed = fixture.preparer.proceed
    defer { proceed.open() }
    // when
    let submission = Task {
      try await fixture.submitFirst()
    }
    await fixture.preparer.entered.wait()
    try await fixture.service.shutdown()
    proceed.open()
    // then
    await #expect(throws: CoderError.self) {
      try await submission.value
    }
    #expect(try fixture.store.reservedJobs().isEmpty)
    #expect(await fixture.backend.startedJobIDs.isEmpty)
  }

  @Test func groupJobControlRequiresOriginalRequesterAndTopic() async throws {
    // given
    let fixture = try CoderServiceFixture(groupChatID: -700, threadID: 19)
    try await fixture.withJoinedCleanup {
      try await fixture.service.start()
      let job = try await fixture.submitFirst()
      let otherScopes: [(Int64, Int64?, Int64?)] = [
        (88, -700, 19),
        (7, -700, 20),
        (7, nil, nil),
      ]

      // when
      for (offset, scope) in otherScopes.enumerated() {
        let caller = try CoderServiceFixture.context(
          queue: fixture.queue,
          prepared: fixture.prepared,
          index: Int64(offset + 2),
          ownerID: scope.0,
          groupChatID: scope.1,
          threadID: scope.2
        )
        await #expect(throws: CoderError.forbidden) {
          try await fixture.service.status(id: job.id, context: caller)
        }
        await #expect(throws: CoderError.forbidden) {
          try await fixture.service.cancel(id: job.id, context: caller)
        }
      }
      let requester = try CoderServiceFixture.context(
        queue: fixture.queue,
        prepared: fixture.prepared,
        index: 6,
        groupChatID: -700,
        threadID: 19
      )
      let visible = try await fixture.service.status(id: job.id, context: requester)
      let cancellation = try await fixture.service.cancel(id: job.id, context: requester)

      // then
      #expect(visible.id == job.id)
      #expect(cancellation.state == .stopping)
    }
  }
}
