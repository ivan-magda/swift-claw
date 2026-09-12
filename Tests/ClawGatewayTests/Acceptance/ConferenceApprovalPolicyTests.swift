import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawGateway

@Suite struct ConferenceApprovalPolicyTests {
  @Test func rejectsApprovalAfterPolicyChange() async throws {
    // given
    let fixture = try ConferenceWorkflowFixture()
    let answer = "Restore accessibility labels."
    let prepared = try await fixture.service.prepareSubmission(answer: answer)
    let origin = try fixture.origin(answer: answer)
    let restarted = fixture.restarted(executionPolicyID: Self.changedPolicyID)

    // when / then
    await #expect(throws: ConferenceError.staleApproval) {
      try await restarted.submit(prepared, context: origin.executionContext)
    }
    #expect(
      try fixture.store.submission(
        participantUserID: origin.requesterUserID,
        caseID: prepared.caseSnapshot.id
      ) == nil
    )
  }

  @Test(arguments: [ConferenceWorkflowFixture.executionPolicyID, nil])
  func queuedApprovalCannotAcquireNewExecutionPolicy(approvedPolicyID: String?) async throws {
    // given
    let notice = AsyncGate()
    let fixture = try ConferenceWorkflowFixture()
    let prepared = PreparedConferenceSubmission(
      caseSnapshot: ConferenceWorkflowFixture.item,
      answer: "Preserve accessibility state in an actor.",
      executionPolicyID: approvedPolicyID
    )
    let origin = try ConferenceApprovedOriginFixture.make(
      queue: fixture.queue,
      prepared: prepared
    )
    let id = UUID()
    _ = try fixture.store.insertSubmission(
      id: id,
      prepared: prepared,
      origin: origin,
      now: Date()
    )
    let coder = ConferenceTestCoder(store: fixture.jobs, executionPolicyID: Self.changedPolicyID)
    let restarted = fixture.restarted(
      executionPolicyID: Self.changedPolicyID,
      coder: coder,
      notifyOutbox: { notice.open() }
    )

    // when
    let runner = Task { try await restarted.run() }
    let notified = await notice.waitUntilOpen()
    runner.cancel()
    _ = await runner.result

    // then
    try #require(notified)
    let submission = try #require(try fixture.store.submission(id: id))
    #expect(submission.state == .needsReview)
    #expect(submission.executionPolicyID == approvedPolicyID)
    #expect(submission.coderJobID == nil)
    #expect(await coder.admissions == 0)
  }

  private static let changedPolicyID = "changed-conference-execution-policy"
}
