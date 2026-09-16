import ClawCore
import ClawTestSupport
import Foundation
import GRDB

@testable import ClawData

extension BoundRunEnvironment {
  func runFeedbackTarget(runID: Int64, signal: OwnerSignal) -> NewFeedbackTarget {
    NewFeedbackTarget(
      nonce: "run-\(runID)-\(signal.rawValue)",
      jobID: jobID,
      epoch: LearningEpoch(1),
      subjectKind: .run,
      subjectDigest: String(runID),
      allowedActions: [signal],
      ownerUserID: 42,
      chatID: 777,
      expiresAt: now.addingTimeInterval(3_600)
    )
  }

  func evaluationFeedbackTarget(
    digest: EvaluationDigest,
    signal: OwnerSignal
  ) -> NewFeedbackTarget {
    feedbackTarget(
      nonce: "evaluation-\(signal.rawValue)",
      kind: .evaluation,
      digest: digest.rawValue,
      signal: signal
    )
  }

  func candidateFeedbackTarget(digest: CandidateDigest, signal: OwnerSignal) -> NewFeedbackTarget {
    feedbackTarget(
      nonce: "candidate-\(signal.rawValue)",
      kind: .candidate,
      digest: digest.rawValue,
      signal: signal
    )
  }

  func feedbackTap(_ target: NewFeedbackTarget, updateID: Int64) -> FeedbackTap {
    FeedbackTap(
      nonce: target.nonce,
      signal: target.allowedActions[0],
      ownerUserID: target.ownerUserID,
      chatID: target.chatID,
      transportUpdateID: updateID
    )
  }

  func challengePrompt(_ target: NewFeedbackTarget) -> [LearningNoticeChunk] {
    let payload = "Reply with the correction."
    return [
      LearningNoticeChunk(
        subjectDigest: FeedbackChallengeDeliveryIdentity.digest(targetNonce: target.nonce),
        ordinal: 0,
        chatID: target.chatID,
        payload: payload,
        payloadHash: ContentHash.fnv1a(payload)
      ),
    ]
  }

  func recordRunFeedback(runID: Int64, signal: OwnerSignal, updateID: Int64) throws {
    let target = runFeedbackTarget(runID: runID, signal: signal)
    try TestLearningFixtures(writer: queue).seedTargets([target])
    guard case .recorded = try learning.consumeAndAppendEvent(
      feedbackTap(target, updateID: updateID),
      now: now.addingTimeInterval(1)
    )
    else {
      throw StoreError.unexpected("fixture feedback was not recorded")
    }
  }

  func setCurrentFeedbackRevision(_ revision: Int64) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE job_learning_state SET feedback_revision = ? WHERE job_id = ?",
        arguments: [revision, jobID]
      )
    }
  }

  func feedbackEventCount() throws -> Int {
    try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feedback_events") ?? -1
    }
  }

  func learningAuditCount() throws -> Int {
    try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM audit_events WHERE action = ?",
        arguments: [AuditAction.learningFeedback.rawValue]
      ) ?? -1
    }
  }
}

// MARK: - Feedback Targets

private extension BoundRunEnvironment {
  func feedbackTarget(
    nonce: String,
    kind: FeedbackSubjectKind,
    digest: String,
    signal: OwnerSignal
  ) -> NewFeedbackTarget {
    NewFeedbackTarget(
      nonce: nonce,
      jobID: jobID,
      epoch: LearningEpoch(1),
      subjectKind: kind,
      subjectDigest: digest,
      allowedActions: [signal],
      ownerUserID: 42,
      chatID: 777,
      expiresAt: now.addingTimeInterval(3_600)
    )
  }
}
