import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

extension CoderServiceTests {
  @Test func completionRerendersAfterCancellationRace() async throws {
    // given
    let fixture = try CoderServiceFixture()
    defer { fixture.cleanup() }
    let service = fixture.restartedService { text in
      if text.contains(CoderJobState.succeeded.rawValue) {
        do {
          for job in try fixture.store.reservedJobs() {
            _ = try fixture.store.requestCancellation(id: job.id, now: Date())
          }
        } catch { Issue.record(error) }
      }
      return text
    }
    try await service.start()
    let job = try await service.submit(fixture.prepared, context: fixture.ownerContext)
    await fixture.backend.started.wait()
    // when
    fixture.backend.releaseAll()
    await fixture.jobFinished.wait()
    // then
    #expect(try fixture.store.job(id: job.id)?.state == .cancelled)
    let reports = try fixture.reports()
    #expect(reports.count == 1)
    let report = try #require(reports.first)
    #expect(report.payload.contains(CoderJobState.cancelled.rawValue))
    #expect(!report.payload.contains(CoderJobState.succeeded.rawValue))
    #expect(await fixture.backend.startedJobIDs == [job.id])
    try await service.shutdown()
  }

  @Test func selectedStopSurvivesCancellation() async throws {
    // given
    let script = ScriptedCoderBackend.Invocation(
      result: CoderServiceFixture.result(state: .timedOut),
      holdCleanup: true
    )
    let fixture = try CoderServiceFixture(scripts: [script])
    defer { fixture.cleanup() }
    try await fixture.service.start()
    let job = try await fixture.submitFirst()
    await script.started.wait()
    // when
    _ = try await fixture.service.cancel(id: job.id, context: fixture.ownerContext)
    script.allowCleanup.open()
    await fixture.jobFinished.wait()
    // then
    #expect(try fixture.store.job(id: job.id)?.state == .timedOut)
    #expect(try fixture.reports().first?.payload.contains(CoderJobState.timedOut.rawValue) == true)
    try await fixture.service.shutdown()
  }

  @Test(arguments: [false, true])
  func persistenceFailureIsUnhealthyAndReserved(receiptWrite: Bool) async throws {
    // given
    let fixture = try CoderServiceFixture()
    defer { fixture.cleanup() }
    try await fixture.service.start()
    try await fixture.queue.write { db in
      if receiptWrite {
        try db.execute(
          sql: """
            CREATE TRIGGER fail_coder_receipt BEFORE UPDATE OF process_ownership ON coder_jobs
            BEGIN SELECT RAISE(ABORT, 'receipt write failed'); END
            """
        )
      } else {
        try db.execute(
          sql: """
            CREATE TRIGGER fail_coder_notice BEFORE INSERT ON outbound_deliveries
            WHEN NEW.approval_id IS NULL BEGIN SELECT RAISE(ABORT, 'report write failed'); END
            """
        )
      }
    }
    let job = try await fixture.submitFirst()
    await fixture.backend.started.wait()
    let finished = AsyncGate()
    let running = Task {
      defer { finished.open() }
      try await fixture.service.run()
    }
    // when
    fixture.backend.releaseAll()
    let finishedWithoutCancellation = await finished.waitUntilOpen()
    if !finishedWithoutCancellation {
      running.cancel()
    }
    let outcome = await running.result
    // then
    #expect(finishedWithoutCancellation)
    guard case .failure(let error) = outcome,
      case .persistence = error as? CoderServiceFailure
    else {
      Issue.record("Service did not propagate terminal persistence failure")
      return
    }
    #expect(try fixture.store.job(id: job.id)?.slotReserved == true)
    #expect(try fixture.store.job(id: job.id)?.result == nil)
    #expect(try fixture.reports().isEmpty)
    #expect(!fixture.jobFinished.isOpen)
  }

  @Test(arguments: [false, true])
  func cleanupFailureUsesOwnership(unresolved: Bool) async throws {
    // given
    let script = ScriptedCoderBackend.Invocation(
      result: CoderServiceFixture.result(
        state: .failed,
        failure: CoderFailure(stage: .cleanup, message: "Cleanup failed")
      ),
      unresolvedCleanup: unresolved
    )
    let fixture = try CoderServiceFixture(scripts: [script])
    defer { fixture.cleanup() }
    try await fixture.service.start()
    let job = try await fixture.submitFirst()
    await script.started.wait()
    // when
    fixture.backend.releaseAll()
    await fixture.jobFinished.wait()
    // then
    #expect(try fixture.store.job(id: job.id)?.slotReserved == unresolved)
    #expect(try fixture.store.job(id: job.id)?.result?.failure?.stage == .cleanup)
    if unresolved {
      await #expect(throws: CoderServiceFailure.cleanup(jobID: job.id)) {
        try await fixture.service.shutdown()
      }
    } else {
      try await fixture.service.shutdown()
      #expect(await fixture.service.failure == nil)
    }
  }

  @Test func completionReportPreservesEvidenceAndRedacts() async throws {
    // given
    let secret = "fixture-secret-value"
    let result = CoderResult(
      state: .failed,
      summary: "Worker \(secret)",
      workspacePath: "/work/\(secret)",
      startingCommit: "abc",
      baselineObserved: false,
      changedFiles: nil,
      branch: "branch-\(secret)",
      commit: "def",
      publication: .unknown(reportedURL: secret),
      reportedChecks: ["check \(secret)"],
      reportedUsage: ["tokens": 42],
      commitAuthor: "author \(secret)",
      githubActor: "actor \(secret)",
      failure: CoderFailure(stage: .inspection, message: secret)
    )
    let redactor = SecretRedactor(secretValues: [secret])
    let fixture = try CoderServiceFixture(
      scripts: [.init(result: result)],
      redactor: redactor.redact
    )
    defer { fixture.cleanup() }
    try await fixture.service.start()
    let job = try await fixture.submitFirst()
    await fixture.backend.started.wait()
    // when
    fixture.backend.releaseAll()
    await fixture.jobFinished.wait()
    // then
    let report = try fixture.reports().map(\.payload).joined()
    #expect(!report.contains(secret))
    #expect(report.contains(SecretRedactor.replacement))
    #expect(report.contains(job.id.uuidString))
    #expect(report.contains("unknown"))
    #expect(report.contains("unavailable"))
    let startingEvidence = report.split(separator: "\n").first { line in
      line.contains("abc")
    }
    #expect(startingEvidence?.contains("worker-reported") == true)
    #expect(report.contains("42"))
    try await fixture.service.shutdown()
  }
}
