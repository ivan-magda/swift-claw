import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct PromotionTests {
  @Test func completeCohortAndReplay() throws {
    // given
    let env = try BoundRunEnvironment.promotionEnvironment()
    let first = try env.positiveTrialRun()
    let second = try env.positiveTrialRun()
    try env.recordRunFeedback(runId: first, signal: .resultUseful, updateId: 799)
    let trial = try #require(try env.learning.openTrial(jobId: env.jobId))
    let revision = try env.currentLearningState().feedbackRevision

    // when
    let receipt = try #require(
      try env.learning.applyTrialDecision(
        .promote,
        trial: trial,
        feedbackRevision: revision,
        now: env.now
      )
    )
    let replay = try env.learning.applyTrialDecision(
      .promote,
      trial: trial,
      feedbackRevision: revision,
      now: env.now
    )

    // then
    #expect(receipt.result == .promoted)
    #expect(Set(receipt.cohort.map(\.runId)) == [first, second])
    #expect(
      receipt.cohort.allSatisfy { support in
        support.outcome == .positive
      }
    )
    let ownerSupport = receipt.cohort.first { support in
      support.runId == first
    }
    #expect(ownerSupport?.evaluationRequired == false)
    #expect(replay == receipt)
    #expect(try env.currentLearningState().stableDigest == trial.replacementDigest)
    #expect(try env.learning.openTrial(jobId: env.jobId) == nil)
  }
  @Test func waitsForEveryAssignedRun() throws {
    // given
    let env = try BoundRunEnvironment.promotionEnvironment()
    _ = try env.positiveTrialRun()
    let pending = try env.settledBoundRun()
    _ = try env.positiveTrialRun()
    let trial = try #require(try env.learning.openTrial(jobId: env.jobId))

    // when
    let result = try env.learning.applyTrialDecision(
      .promote,
      trial: trial,
      feedbackRevision: FeedbackRevision(0),
      now: env.now
    )

    // then
    #expect(result == nil)
    #expect(try env.currentLearningState().stableDigest == trial.baseDigest)
    #expect(try env.assignment(runId: pending)?.resolvedEvidence == nil)
  }

  @Test(arguments: StalePromotionPredicate.allCases)
  func staleReviewedPredicates(_ predicate: StalePromotionPredicate) throws {
    // given
    let env = try BoundRunEnvironment.promotionEnvironment()
    let run = try env.positiveTrialRun()
    _ = try env.positiveTrialRun()
    let trial = try #require(try env.learning.openTrial(jobId: env.jobId))
    let request = trial.reviewedMutation(predicate)
    switch predicate {
    case .feedback:
      try env.recordRunFeedback(runId: run, signal: .resultUseful, updateId: 800)
    case .epoch:
      _ = try env.learning.applyReset(updateId: 801, jobId: env.jobId, now: env.now)
    case .cancelled:
      _ = try env.jobs.cancel(id: env.jobId, now: env.now)
    case .baseRevision, .baseDigest, .candidate, .replacement, .generation, .algorithm:
      break
    }
    let before = try env.currentLearningState()

    // when
    let receipt = try #require(
      try env.learning.applyTrialDecision(
        .promote,
        trial: request,
        feedbackRevision: FeedbackRevision(0),
        now: env.now
      )
    )

    // then
    #expect(receipt.result == .stale)
    let after = try env.currentLearningState()
    #expect(after.stableDigest == before.stableDigest)
    #expect(after.stableRevision == before.stableRevision)
    #expect(after.epoch == before.epoch)
  }

  @Test func fallbackReceipt() throws {
    // given
    let env = try BoundRunEnvironment.promotionEnvironment()
    let run = try env.positiveTrialRun()
    let trial = try #require(try env.learning.openTrial(jobId: env.jobId))
    try env.recordRunFeedback(runId: run, signal: .resultNotUseful, updateId: 810)

    // when
    let receipt = try #require(
      try env.learning.applyTrialDecision(
        .fallback(reason: .negativeOutcome),
        trial: trial,
        feedbackRevision: try env.currentLearningState().feedbackRevision,
        now: env.now
      )
    )

    // then
    #expect(receipt.result == .fallback)
    #expect(receipt.cohort.first?.outcome == .negative)
    #expect(try env.currentLearningState().stableDigest == trial.baseDigest)
    #expect(try env.learning.openTrial(jobId: env.jobId) == nil)
    guard case .readable(let view) = try env.learning.learningView(jobId: env.jobId)[0],
      case .terminal(let shown) = view.lastDecision?.detail
    else {
      Issue.record("terminal receipt must remain readable")
      return
    }
    #expect(shown == receipt)
  }

  @Test(arguments: [false, true])
  func closedReplacementCannotRetry(rolledBack: Bool) throws {
    // given
    let env = try BoundRunEnvironment.promotionEnvironment()
    let trial = try #require(try env.learning.openTrial(jobId: env.jobId))
    if rolledBack {
      _ = try env.positiveTrialRun()
      _ = try env.positiveTrialRun()
      let promotion = try env.promoteTrial()
      _ = try env.learning.rollback(
        .safety(
          promotionId: promotion.decisionId,
          receiptDigest: SHA256Digest.hex("safety"),
          failure: .security
        ),
        now: env.now
      )
    } else {
      _ = try env.learning.applyTrialDecision(
        .fallback(reason: .insufficientSupport),
        trial: trial,
        feedbackRevision: FeedbackRevision(0),
        now: trial.assignmentDeadline
      )
    }
    let fixture = AdmissionStoreFixture(path: "", env: env)
    let replacement = try #require(
      try env.learning.lessonSet(jobId: env.jobId, digest: trial.replacementDigest)
    )
    let retry = try fixture.persistedCandidate(lessons: replacement.lessons)

    // when
    let outcome = try env.learning.admitCandidate(
      digest: retry.digest,
      redactor: SecretRedactor(secretValues: []),
      now: env.now
    )

    // then
    #expect(retry.digest != trial.candidateDigest)
    #expect(outcome == .rejected(.replacementAlreadyClosed))
    #expect(try env.learning.openTrial(jobId: env.jobId) == nil)
  }

  @Test func promotionIsAtomic() throws {
    // given
    let env = try BoundRunEnvironment.promotionEnvironment()
    _ = try env.positiveTrialRun()
    _ = try env.positiveTrialRun()
    let trial = try #require(try env.learning.openTrial(jobId: env.jobId))
    try env.queue.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER fail_promotion BEFORE UPDATE OF stable_lesson_set_digest
          ON job_learning_state BEGIN SELECT RAISE(ABORT, 'injected disk failure'); END
          """
      )
    }

    // when
    #expect(throws: StoreError.self) {
      try env.learning.applyTrialDecision(
        .promote,
        trial: trial,
        feedbackRevision: FeedbackRevision(0),
        now: env.now
      )
    }

    // then
    #expect(try env.currentLearningState().stableDigest == trial.baseDigest)
    #expect(try env.learning.openTrial(jobId: env.jobId) != nil)
    #expect(try env.terminalDecisionCount() == 0)
  }
}

extension BoundRunEnvironment {
  static func promotionEnvironment() throws -> Self {
    let env = try make()
    let fixture = AdmissionStoreFixture(path: "", env: env)
    let artifact = try fixture.persistedCandidate()
    guard
      case .admitted = try env.learning.admitCandidate(
        digest: artifact.digest,
        redactor: SecretRedactor(secretValues: []),
        now: env.now
      )
    else {
      throw StoreError.unexpected("promotion fixture admission failed")
    }
    return env
  }

  func positiveTrialRun() throws -> Int64 {
    let sealed = try sealedTrialEvidence()
    let operation = try startedOperation(evaluatorKey(for: sealed))
    _ = try learning.finishOperation(
      result(for: operation.id, evaluation: verdict(outcome: .noIssue, issueCodes: [])),
      now: now
    )
    return sealed.runId
  }
}

enum StalePromotionPredicate: CaseIterable {
  case baseRevision, baseDigest, candidate, replacement, feedback, epoch, generation, cancelled,
    algorithm
}

private extension LearningTrial {
  func reviewedMutation(_ predicate: StalePromotionPredicate) -> LearningTrial {
    let other = SHA256Digest.hex("other reviewed identity")
    return LearningTrial(
      identity: LearningTrialIdentity(
        trialId: trialId,
        jobId: jobId,
        epoch: epoch,
        generation: predicate == .generation ? generation + 1 : generation
      ),
      baseDigest: predicate == .baseDigest ? LessonSetDigest(rawValue: other) : baseDigest,
      baseRevision: predicate == .baseRevision
        ? StableRevision(baseRevision.value + 1) : baseRevision,
      candidateDigest: predicate == .candidate ? CandidateDigest(rawValue: other) : candidateDigest,
      replacementDigest: predicate == .replacement
        ? LessonSetDigest(rawValue: other) : replacementDigest,
      algorithm: predicate == .algorithm
        ? LearningAlgorithm(rawValue: "scheduled-learning/v2") : algorithm,
      admittedAt: admittedAt,
      cohortCutoff: cohortCutoff,
      maxAssignments: maxAssignments,
      consumedAssignments: consumedAssignments,
      assignmentDeadline: assignmentDeadline,
      decisionDeadline: decisionDeadline,
      state: state,
      hardVetoes: hardVetoes
    )
  }
}

extension BoundRunEnvironment {
  func terminalDecisionCount() throws -> Int {
    try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM learning_decisions WHERE kind = ?",
        arguments: [LearningDecisionKind.trial.rawValue]
      ) ?? 0
    }
  }

  func promoteTrial() throws -> DecisionReceipt {
    let trial = try #require(try learning.openTrial(jobId: jobId))
    return try #require(
      try learning.applyTrialDecision(
        .promote,
        trial: trial,
        feedbackRevision: try currentLearningState().feedbackRevision,
        now: now
      )
    )
  }
}
