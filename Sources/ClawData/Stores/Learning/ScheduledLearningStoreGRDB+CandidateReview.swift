import ClawCore
import Foundation
import GRDB

// MARK: - Review Commit

extension ScheduledLearningStoreGRDB {
  public func commitCandidateReview(
    _ review: CandidateReviewNotice,
    now: Date
  ) throws(StoreError) -> Bool {
    try database.writeMapping { db in
      try Self.validateReview(db, review: review, now: now)
      let firstKey = OutboxDedupKey.make(subjectDigest: review.subjectDigest, ordinal: 0)
      let exists =
        try Bool.fetchOne(
          db,
          sql: "SELECT EXISTS(SELECT 1 FROM outbound_deliveries WHERE dedup_key = ?)",
          arguments: [firstKey]
        ) ?? false
      guard exists == false else {
        return false
      }
      for chunk in review.chunks {
        guard try OutboxStoreGRDB.insertNotice(db, chunk: chunk, now: now) else {
          throw StoreError.unexpected("candidate review chunk identity already exists")
        }
      }
      for target in review.targets {
        try Self.insertTarget(db, target)
      }
      return true
    }
  }
}

// MARK: - Authoritative Review State

private extension ScheduledLearningStoreGRDB {
  static func validateReview(
    _ db: Database,
    review: CandidateReviewNotice,
    now: Date
  ) throws {
    guard
      let artifact = try readCandidateArtifact(db, digest: review.candidateDigest),
      let state = try readState(db, jobId: artifact.manifest.jobId),
      let job = try admissionJob(db, jobId: artifact.manifest.jobId),
      job.hasRecurrence,
      [.active, .paused].contains(job.status),
      artifact.manifest.jobId == state.jobId,
      artifact.manifest.epoch == state.epoch,
      artifact.manifest.baseDigest == state.stableDigest,
      artifact.manifest.baseRevision == state.stableRevision,
      artifact.manifest.feedbackRevision == state.feedbackRevision,
      try sourceBindingsAreCurrent(db, artifact: artifact, state: state),
      try hardVetoes(db, artifact: artifact).isEmpty,
      review.subjectDigest == CandidateReviewIdentity.digest(candidateDigest: artifact.digest),
      review.targets.count == artifact.manifest.evaluations.count + 1,
      review.targets.count <= 6,
      review.chunks.isEmpty == false,
      review.targets.allSatisfy({ target in target.nonce.isEmpty == false }),
      Set(review.targets.map(\.nonce)).count == review.targets.count,
      try reviewState(db, artifact: artifact) == review.state,
      targetsMatch(
        review.targets,
        artifact: artifact,
        state: review.state,
        ownerChatId: job.ownerChatId,
        expiry: now.addingTimeInterval(EvidenceWindow.maximumAge)
      ),
      review.chunks.enumerated().allSatisfy({ ordinal, chunk in
        chunk.ordinal == ordinal
          && chunk.subjectDigest == review.subjectDigest
          && chunk.chatId == job.ownerChatId
          && chunk.payload.isEmpty == false
          && chunk.payloadHash == ContentHash.fnv1a(chunk.payload)
      }),
      review.chunks.dropLast().allSatisfy({ chunk in chunk.replyMarkup == nil }),
      review.chunks.last?.replyMarkup != nil
    else {
      throw StoreError.unexpected("candidate review carrier is inconsistent")
    }
  }

  static func reviewState(
    _ db: Database,
    artifact: CandidateArtifact
  ) throws -> CandidateReviewState? {
    if let trial = try trialRow(db, candidate: artifact.digest) {
      guard trial.state == .open || trial.state == .draining else {
        return nil
      }
      _ = try admissionReceipt(db, artifact: artifact, trial: trial)
      return .admitted
    }
    guard
      artifact.manifest.origin == .ownerEdit,
      try hasSuccessor(db, predecessor: artifact.digest) == false,
      try liveTrial(db, jobId: artifact.manifest.jobId) == nil
    else {
      return nil
    }
    return .awaitingApproval
  }

  static func targetsMatch(
    _ targets: [NewFeedbackTarget],
    artifact: CandidateArtifact,
    state: CandidateReviewState,
    ownerChatId: Int64,
    expiry: Date
  ) -> Bool {
    let candidateActions: [OwnerSignal] =
      state == .admitted
      ? [.candidateReject, .candidateEdit]
      : [.candidateApprove, .candidateReject, .candidateEdit]
    let expectedSubjects =
      [
        (FeedbackSubjectKind.candidate, artifact.digest.rawValue, candidateActions)
      ]
      + artifact.manifest.evaluations.map { evaluation in
        (
          FeedbackSubjectKind.evaluation,
          evaluation.digest.rawValue,
          [OwnerSignal.evaluationConfirm, .evaluationDispute]
        )
      }
    return zip(targets, expectedSubjects).allSatisfy { target, expected in
      target.jobId == artifact.manifest.jobId
        && target.epoch == artifact.manifest.epoch
        && target.subjectKind == expected.0
        && target.subjectDigest == expected.1
        && target.allowedActions == expected.2
        && target.ownerUserId == ownerChatId
        && target.chatId == ownerChatId
        && target.expiresAt == expiry
    }
  }
}
