import ClawCore
import Foundation
import Testing

@testable import ClawData

@Suite struct RetentionTests {
  @Test func unreferencedPayloadsThenReceiptsAreCollectedWithoutRecovery() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let source = try env.evaluatedEvidence(issueCode: "material.missed")
    let feedback = try env.appendFeedback(
      subjectKind: .run,
      subjectDigest: String(source.evidence.runId),
      signal: .resultCorrection,
      payload: "Ignore counter-only changes."
    )

    // when
    let payloadSweep = try env.learning.sweepRetention(
      now: env.now.addingTimeInterval(31 * 86_400)
    )

    // then
    #expect(payloadSweep.deletedPayloads == 2)
    #expect(try env.learning.evidence(runId: source.evidence.runId)?.payload == nil)
    #expect(try env.learning.evaluation(runId: source.evidence.runId) != nil)
    #expect(feedback.eventId > 0)

    // when
    let compactSweep = try env.learning.sweepRetention(
      now: env.now.addingTimeInterval(91 * 86_400)
    )
    let again = try env.learning.sweepRetention(now: env.now.addingTimeInterval(92 * 86_400))

    // then
    #expect(compactSweep.deletedReceipts > 0)
    #expect(again.deletedReceipts == 0)
    #expect(try env.learning.evidence(runId: source.evidence.runId) == nil)
    #expect(try env.learning.workflowRuns(jobId: env.jobId, after: 0, limit: 64).isEmpty)
    #expect(try env.learning.unsealed(limit: 64).isEmpty)
  }

  @Test func liveTrialAndPromotionRetainSources() throws {
    // given
    let env = try BoundRunEnvironment.promotionEnvironment()
    let trial = try #require(try env.learning.openTrial(jobId: env.jobId))
    let candidate = try #require(try env.learning.candidateArtifact(digest: trial.candidateDigest))
    let first = try env.positiveTrialRun()
    _ = try env.positiveTrialRun()
    let old = env.now.addingTimeInterval(120 * 86_400)

    // when
    _ = try env.learning.sweepRetention(now: old)

    // then
    for source in candidate.manifest.evidence {
      #expect(try env.learning.evidence(runId: source.runId)?.payload != nil)
    }
    #expect(try env.learning.openTrial(jobId: env.jobId) != nil)

    // when
    let promotion = try env.promoteTrial()
    _ = try env.learning.sweepRetention(now: old)

    // then
    #expect(try env.learning.currentPromotion(jobId: env.jobId) == promotion)
    #expect(try env.learning.evidence(runId: first)?.payload != nil)
    #expect(try env.learning.lessonSet(jobId: env.jobId, digest: trial.baseDigest) != nil)
    #expect(try env.learning.candidateArtifact(digest: trial.candidateDigest) == candidate)
  }

  @Test func closedReplacementRemainsBlockedAfterCollection() throws {
    // given
    let env = try BoundRunEnvironment.promotionEnvironment()
    let trial = try #require(try env.learning.openTrial(jobId: env.jobId))
    let replacement = try #require(
      try env.learning.lessonSet(jobId: env.jobId, digest: trial.replacementDigest)
    )
    _ = try env.learning.applyTrialDecision(
      .fallback(reason: .insufficientSupport),
      trial: trial,
      feedbackRevision: FeedbackRevision(0),
      now: trial.assignmentDeadline
    )

    // when
    _ = try env.learning.sweepRetention(now: env.now.addingTimeInterval(150 * 86_400))
    let retry = try AdmissionStoreFixture(env: env).persistedCandidate(
      lessons: replacement.lessons
    )
    let outcome = try env.learning.admitCandidate(
      digest: retry.digest,
      redactor: SecretRedactor(secretValues: []),
      now: env.now
    )

    // then
    #expect(outcome == .rejected(.replacementAlreadyClosed))
  }

  @Test func rollbackBaseRetainsItsClosedReplacementBlocker() throws {
    // given
    let env = try BoundRunEnvironment.promotionEnvironment()
    let failed = try #require(try env.learning.openTrial(jobId: env.jobId))
    let replacement = try #require(
      try env.learning.lessonSet(jobId: env.jobId, digest: failed.replacementDigest)
    )
    _ = try env.learning.applyTrialDecision(
      .fallback(reason: .insufficientSupport),
      trial: failed,
      feedbackRevision: FeedbackRevision(0),
      now: failed.assignmentDeadline
    )
    let fixture = AdmissionStoreFixture(env: env)
    let other = try fixture.persistedCandidate(lessons: ["Consult the complete archive."])
    _ = try env.learning.admitCandidate(
      digest: other.digest,
      redactor: SecretRedactor(secretValues: []),
      now: env.now
    )
    _ = try env.positiveTrialRun()
    _ = try env.positiveTrialRun()
    let promotion = try env.promoteTrial()

    // when
    _ = try env.learning.sweepRetention(now: env.now.addingTimeInterval(150 * 86_400))
    let event = try env.promotionFeedback(promotion, signal: .promotionRollback)
    let rollback = try env.learning.rollback(
      .ownerFeedback(promotionId: promotion.decisionId, eventId: event.id),
      now: env.now
    )
    let retry = try fixture.persistedCandidate(lessons: replacement.lessons)
    let outcome = try env.learning.admitCandidate(
      digest: retry.digest,
      redactor: SecretRedactor(secretValues: []),
      now: env.now
    )

    // then
    #expect(rollback?.result == .rolledBack)
    #expect(outcome == .rejected(.replacementAlreadyClosed))
  }

  @Test func liveEditedCandidateRetainsItsPredecessorAndSourcePayloads() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let original = try AdmissionStoreFixture(env: env).persistedCandidate()
    let payload = #"{"lessons":["Ignore counter-only changes."]}"#
    let feedback = try env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: original.digest.rawValue,
      signal: .candidateEdit,
      payload: payload
    )
    let outcome = try env.learning.editCandidate(
      CandidateEdit(
        predecessorDigest: original.digest,
        feedbackEventId: feedback.eventId,
        payload: Data(payload.utf8)
      ),
      redactor: SecretRedactor(secretValues: []),
      now: env.now
    )
    guard case .awaitingApproval(let edited) = outcome else {
      Issue.record("expected an unadmitted owner edit")
      return
    }

    // when
    _ = try env.learning.sweepRetention(now: env.now.addingTimeInterval(120 * 86_400))

    // then
    #expect(try env.learning.candidateArtifact(digest: edited.digest) == edited)
    #expect(try env.learning.candidateArtifact(digest: original.digest) == original)
    for source in original.manifest.evidence {
      #expect(try env.learning.evidence(runId: source.runId)?.payload != nil)
    }
  }

  @Test func unfinishedOperationRetainsEvidence() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let evidence = try env.sealedEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: evidence))

    // when
    _ = try env.learning.sweepRetention(now: env.now.addingTimeInterval(120 * 86_400))
    let recorded = try env.learning.finishOperation(
      env.result(for: operation.id, evaluation: env.verdict(outcome: .noIssue, issueCodes: [])),
      now: env.now.addingTimeInterval(120 * 86_400)
    )

    // then
    #expect(recorded)
    #expect(try env.learning.evaluation(runId: evidence.runId) != nil)
  }
}
