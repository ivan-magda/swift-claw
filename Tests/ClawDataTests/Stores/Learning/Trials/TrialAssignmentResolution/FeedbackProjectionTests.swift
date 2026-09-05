import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

extension TrialAssignmentResolutionTests {
  @Test func relevantFeedbackRefreshesRevisionAndTimestampEvenWhenOutcomeStaysPositive() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: sealed))
    _ = try env.learning.finishOperation(env.result(for: operation.id), now: env.now)
    let before = try #require(try env.assignment(runId: sealed.runId))
    let digest = try #require(before.resolvedEvidence?.evaluationDigest)
    let target = env.evaluationFeedbackTarget(
      digest: digest,
      signal: .evaluationConfirm
    )
    try env.learning.createTargets([target], chunks: [], now: env.now)
    let feedbackAt = env.now.addingTimeInterval(7)

    // when
    let result = try env.learning.consumeAndAppendEvent(
      env.feedbackTap(target, updateId: 11),
      now: feedbackAt
    )

    // then — owner confirmation changes provenance, even though positive remains positive.
    guard case .recorded = result else {
      Issue.record("expected recorded confirmation")
      return
    }
    let after = try #require(try env.assignment(runId: sealed.runId))
    #expect(after.resolvedEvidence?.outcome == .positive)
    #expect(after.resolvedEvidence?.ownerConfirmed == true)
    #expect(after.resolvedEvidence?.effectiveFeedbackRevision == FeedbackRevision(1))
    #expect(before.resolvedAt == env.now)
    #expect(after.resolvedAt == feedbackAt)
  }

  @Test func unrelatedFeedbackDoesNotRewriteAResolvedAssignmentCache() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: sealed))
    _ = try env.learning.finishOperation(env.result(for: operation.id), now: env.now)
    let before = try env.assignmentCacheSnapshot(runId: sealed.runId)
    _ = try env.appendFeedback(
      subjectKind: .run,
      subjectDigest: "999999",
      signal: .resultUseful
    )

    // when
    let recomputed = try env.learning.recomputeAssignment(
      runId: sealed.runId,
      now: env.now.addingTimeInterval(20)
    )
    let after = try env.assignmentCacheSnapshot(runId: sealed.runId)

    // then — a job-wide revision alone is not a reason to rewrite unrelated provenance.
    guard case .unchanged(let assignment) = recomputed else {
      Issue.record("expected unchanged assignment")
      return
    }
    #expect(after == before)
    #expect(assignment.resolvedEvidence?.effectiveFeedbackRevision == FeedbackRevision(0))
    #expect(try env.currentLearningState().feedbackRevision == FeedbackRevision(1))
  }

  @Test func assignmentCacheCannotNameAFutureFeedbackRevision() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: sealed))
    _ = try env.learning.finishOperation(env.result(for: operation.id), now: env.now)
    try env.setAssignmentFeedbackRevision(runId: sealed.runId, revision: 99)
    let cacheBefore = try env.assignmentCacheSnapshot(runId: sealed.runId)

    // when / then — removing the cached-revision upper bound manufactures future provenance.
    #expect {
      _ = try env.learning.recomputeAssignment(runId: sealed.runId, now: env.now)
    } throws: { error in
      guard case StoreError.unexpected = error else {
        return false
      }
      return true
    }
    #expect(try env.assignmentCacheSnapshot(runId: sealed.runId) == cacheBefore)
  }

  @Test func assignmentProjectionCannotConsumeAFutureFeedbackEvent() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: sealed))
    _ = try env.learning.finishOperation(env.result(for: operation.id), now: env.now)
    try env.recordRunFeedback(
      runId: sealed.runId,
      signal: .resultNotUseful,
      updateId: 18
    )
    try env.setCurrentFeedbackRevision(0)
    try env.resetAssignmentCache(runId: sealed.runId, state: .primaryRunSettled)
    let cacheBefore = try env.assignmentCacheSnapshot(runId: sealed.runId)

    // when / then — removing the source-revision upper bound consumes a future event.
    #expect {
      _ = try env.learning.recomputeAssignment(runId: sealed.runId, now: env.now)
    } throws: { error in
      guard case StoreError.unexpected = error else {
        return false
      }
      return true
    }
    #expect(try env.assignmentCacheSnapshot(runId: sealed.runId) == cacheBefore)
  }

  @Test func terminallyIneligibleEvidenceIgnoresResultFeedbackAsQualityEvidence() throws {
    // given
    let env = try trialEnvironment()
    let evidence = try env.ineligibleSealedEvidence()

    // when
    try env.recordRunFeedback(
      runId: evidence.runId,
      signal: .resultUseful,
      updateId: 12
    )

    // then — feedback cannot convert a technical exclusion into positive support.
    let assignment = try #require(try env.assignment(runId: evidence.runId))
    #expect(assignment.resolvedEvidence?.outcome == .neutral)
    #expect(assignment.resolvedEvidence?.evaluationRequired == false)
  }

  @Test func disputeWithdrawsOnlyEvaluationDependentSupport() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: sealed))
    _ = try env.learning.finishOperation(
      env.result(
        for: operation.id,
        evaluation: env.verdict(outcome: .reusableIssue, issueCodes: ["wrong_fact"])
      ),
      now: env.now
    )
    let evaluated = try #require(try env.assignment(runId: sealed.runId))
    let digest = try #require(evaluated.resolvedEvidence?.evaluationDigest)
    let dispute = env.evaluationFeedbackTarget(digest: digest, signal: .evaluationDispute)
    let useful = env.runFeedbackTarget(runId: sealed.runId, signal: .resultUseful)
    try env.learning.createTargets([dispute, useful], chunks: [], now: env.now)

    // when — first remove evaluator support, then add independent run-result support.
    _ = try env.learning.consumeAndAppendEvent(
      env.feedbackTap(dispute, updateId: 13),
      now: env.now.addingTimeInterval(1)
    )
    let disputed = try #require(try env.assignment(runId: sealed.runId))
    _ = try env.learning.consumeAndAppendEvent(
      env.feedbackTap(useful, updateId: 14),
      now: env.now.addingTimeInterval(2)
    )

    // then
    #expect(disputed.resolvedEvidence?.outcome == .neutral)
    #expect(disputed.resolvedEvidence?.evaluationRequired == true)
    #expect(disputed.resolvedEvidence?.hardVetoes == [.ownerDependencyRejected])
    let independent = try #require(try env.assignment(runId: sealed.runId))
    #expect(independent.resolvedEvidence?.outcome == .positive)
    #expect(independent.resolvedEvidence?.evaluationRequired == false)
    #expect(independent.resolvedEvidence?.hardVetoes.isEmpty == true)
  }

  @Test func runCorrectionRecomputesInsideTheChallengeTransaction() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: sealed))
    _ = try env.learning.finishOperation(env.result(for: operation.id), now: env.now)
    let target = env.runFeedbackTarget(runId: sealed.runId, signal: .resultCorrection)
    try env.learning.createTargets([target], chunks: [], now: env.now)
    let opened = try env.learning.consumeAndOpenChallenge(
      env.feedbackTap(target, updateId: 16),
      prompt: env.challengePrompt(target),
      now: env.now
    )
    guard case .challengeOpened(let challenge) = opened else {
      Issue.record("expected correction challenge")
      return
    }
    let correctedAt = env.now.addingTimeInterval(1)

    // when
    _ = try env.learning.consumeChallenge(
      id: challenge.id,
      payload: "Use the corrected source.",
      now: correctedAt
    )

    // then — appending only the event leaves the cached positive assignment unchanged.
    let assignment = try #require(try env.assignment(runId: sealed.runId))
    #expect(assignment.resolvedEvidence?.outcome == .negative)
    #expect(assignment.resolvedEvidence?.correctionEventDigest != nil)
    #expect(assignment.resolvedEvidence?.effectiveFeedbackRevision == FeedbackRevision(1))
    #expect(assignment.resolvedAt == correctedAt)
  }

  @Test func sameEpochLateResultRefreshesCacheWithoutReopeningTerminalTrial() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: sealed))
    let trial = try #require(try env.learning.openTrial(jobId: env.jobId))
    let reject = env.candidateFeedbackTarget(
      digest: trial.candidateDigest,
      signal: .candidateReject
    )
    try env.learning.createTargets([reject], chunks: [], now: env.now)
    _ = try env.learning.consumeAndAppendEvent(
      env.feedbackTap(reject, updateId: 15),
      now: env.now.addingTimeInterval(1)
    )
    let terminalState = try env.currentLearningState()
    #expect(try env.trialState(trialId: trial.trialId) == .fellBack)

    // when
    let finishedAt = env.now.addingTimeInterval(2)
    _ = try env.learning.finishOperation(
      env.result(for: operation.id),
      now: finishedAt
    )

    // then — the current-epoch product may repair history but cannot apply Task 17 transitions.
    let refreshed = try env.rawResolvedAssignment(runId: sealed.runId)
    #expect(refreshed.state == .learningOutcomeResolved)
    #expect(refreshed.outcome == .positive)
    #expect(refreshed.evaluationDigest == refreshed.sourceEvaluationDigest)
    #expect(refreshed.evaluationDigest != nil)
    #expect(refreshed.feedbackRevision == terminalState.feedbackRevision)
    #expect(refreshed.resolvedAt == finishedAt)
    #expect(try env.trialState(trialId: trial.trialId) == .fellBack)
    #expect(try env.currentLearningState() == terminalState)
  }
}

private struct RawResolvedAssignment {
  let state: TrialAssignmentState
  let outcome: TrialOutcomeKind
  let evaluationDigest: EvaluationDigest?
  let sourceEvaluationDigest: EvaluationDigest?
  let feedbackRevision: FeedbackRevision
  let resolvedAt: Date
}

// MARK: - Assignment Reads

private extension BoundRunEnvironment {
  func rawResolvedAssignment(runId: Int64) throws -> RawResolvedAssignment {
    try queue.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT assignment.state, assignment.outcome, assignment.evaluation_digest,
              assignment.effective_feedback_revision, assignment.resolved_at,
              evaluation.evaluation_digest AS source_evaluation_digest
            FROM trial_assignments AS assignment
            LEFT JOIN learning_evaluations AS evaluation ON evaluation.run_id = assignment.run_id
            WHERE assignment.run_id = ?
            """,
          arguments: [runId]
        ),
        let stateRaw = SQLiteStoredValue.string(in: row, column: "state"),
        let state = TrialAssignmentState(rawValue: stateRaw),
        let outcomeRaw = SQLiteStoredValue.string(in: row, column: "outcome"),
        let outcome = TrialOutcomeKind(rawValue: outcomeRaw),
        let evaluationRaw = SQLiteStoredValue.nullableString(
          in: row,
          column: "evaluation_digest"
        ),
        let sourceRaw = SQLiteStoredValue.nullableString(
          in: row,
          column: "source_evaluation_digest"
        ),
        let feedbackRaw = SQLiteStoredValue.int64(
          in: row,
          column: "effective_feedback_revision"
        ),
        feedbackRaw >= 0,
        let resolvedRaw = SQLiteStoredValue.int64(in: row, column: "resolved_at"),
        let resolvedAt = EpochSecondCodec.date(fromEpoch: resolvedRaw)
      else {
        throw StoreError.unexpected("fixture assignment cache is not resolved")
      }
      return RawResolvedAssignment(
        state: state,
        outcome: outcome,
        evaluationDigest: evaluationRaw.value.map(EvaluationDigest.init(rawValue:)),
        sourceEvaluationDigest: sourceRaw.value.map(EvaluationDigest.init(rawValue:)),
        feedbackRevision: FeedbackRevision(feedbackRaw),
        resolvedAt: resolvedAt
      )
    }
  }
}
