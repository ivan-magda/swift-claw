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
      let firstKey = OutboxDedupKey.make(subjectDigest: review.subjectDigest, ordinal: 0)
      let exists =
        try Bool.fetchOne(
          db,
          sql: "SELECT EXISTS(SELECT 1 FROM outbound_deliveries WHERE dedup_key = ?)",
          arguments: [firstKey]
        ) ?? false
      if exists {
        guard try Self.committedReviewIsComplete(db, review: review) else {
          throw StoreError.unexpected("candidate review replay is incomplete")
        }
        return false
      }
      try Self.validateReview(db, review: review, now: now)
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
  static func committedReviewIsComplete(
    _ db: Database,
    review: CandidateReviewNotice
  ) throws -> Bool {
    guard
      review.subjectDigest
        == CandidateReviewIdentity.digest(
          candidateDigest: review.candidateDigest
        ),
      let artifact = try readCandidateArtifact(db, digest: review.candidateDigest),
      let job = try admissionJob(db, jobId: artifact.manifest.jobId),
      try committedChunksAreComplete(
        db,
        subjectDigest: review.subjectDigest,
        ownerChatId: job.ownerChatId
      ),
      try committedTargetsAreComplete(
        db,
        artifact: artifact,
        ownerChatId: job.ownerChatId
      )
    else {
      return false
    }
    return true
  }

  static func committedChunksAreComplete(
    _ db: Database,
    subjectDigest: String,
    ownerChatId: Int64
  ) throws -> Bool {
    let prefix = OutboxDedupKey.make(subjectDigest: subjectDigest, ordinal: 0).dropLast()
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT run_id, step_index, chat_id, dedup_key, payload, payload_hash, reply_markup,
          delivery_source
        FROM outbound_deliveries WHERE dedup_key GLOB ? ORDER BY step_index
        """,
      arguments: ["\(prefix)*"]
    )
    guard rows.isEmpty == false else {
      return false
    }
    for (ordinal, row) in rows.enumerated() {
      let payload: String = row["payload"]
      guard
        (row["run_id"] as Int64?) == nil,
        row["step_index"] as Int == ordinal,
        row["chat_id"] as Int64 == ownerChatId,
        row["dedup_key"] as String
          == OutboxDedupKey.make(subjectDigest: subjectDigest, ordinal: ordinal),
        payload.isEmpty == false,
        row["payload_hash"] as String == ContentHash.fnv1a(payload),
        row["delivery_source"] as String == DeliverySource.learning.rawValue
      else {
        return false
      }
    }
    return rows.dropLast().allSatisfy { row in
      (row["reply_markup"] as String?) == nil
    } && (rows.last?["reply_markup"] as String?) != nil
  }

  static func committedTargetsAreComplete(
    _ db: Database,
    artifact: CandidateArtifact,
    ownerChatId: Int64
  ) throws -> Bool {
    let candidateTargets = try storedTargets(
      db,
      artifact: artifact,
      subjectKind: .candidate,
      subjectDigest: artifact.digest.rawValue
    )
    guard
      candidateTargets.count == 1,
      let candidateTarget = candidateTargets.first,
      candidateTarget.ownerUserId == ownerChatId,
      candidateTarget.chatId == ownerChatId,
      candidateTarget.allowedActions == [.candidateReject, .candidateEdit]
        || candidateTarget.allowedActions
          == [.candidateApprove, .candidateReject, .candidateEdit]
    else {
      return false
    }
    for evaluation in artifact.manifest.evaluations {
      let matches = try storedTargets(
        db,
        artifact: artifact,
        subjectKind: .evaluation,
        subjectDigest: evaluation.digest.rawValue
      ).filter { target in
        target.allowedActions == [.evaluationConfirm, .evaluationDispute]
          && target.ownerUserId == ownerChatId
          && target.chatId == ownerChatId
          && target.expiresAt == candidateTarget.expiresAt
      }
      guard matches.isEmpty == false else {
        return false
      }
    }
    return true
  }

  static func storedTargets(
    _ db: Database,
    artifact: CandidateArtifact,
    subjectKind: FeedbackSubjectKind,
    subjectDigest: String
  ) throws -> [FeedbackTarget] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT * FROM feedback_targets
        WHERE job_id = ? AND learning_epoch = ? AND subject_kind = ? AND subject_digest = ?
        """,
      arguments: [
        artifact.manifest.jobId,
        artifact.manifest.epoch.value,
        subjectKind.rawValue,
        subjectDigest,
      ]
    ).map(decodeTarget)
  }

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
      review.chunks.allSatisfy({ chunk in chunk.chatId == job.ownerChatId }),
      chunksHaveValidShape(review.chunks, subjectDigest: review.subjectDigest)
    else {
      throw StoreError.unexpected("candidate review carrier is inconsistent")
    }
  }

  static func chunksHaveValidShape(
    _ chunks: [LearningNoticeChunk],
    subjectDigest: String
  ) -> Bool {
    chunks.enumerated().allSatisfy { ordinal, chunk in
      chunk.ordinal == ordinal
        && chunk.subjectDigest == subjectDigest
        && chunk.payload.isEmpty == false
        && chunk.payloadHash == ContentHash.fnv1a(chunk.payload)
    }
      && chunks.dropLast().allSatisfy { chunk in
        chunk.replyMarkup == nil
      } && chunks.last?.replyMarkup != nil
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
