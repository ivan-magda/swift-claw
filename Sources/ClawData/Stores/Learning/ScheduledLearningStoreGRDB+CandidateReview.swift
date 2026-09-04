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
    do {
      guard
        review.subjectDigest
          == CandidateReviewIdentity.digest(
            candidateDigest: review.candidateDigest
          ),
        let artifact = try readCandidateArtifact(db, digest: review.candidateDigest),
        let job = try admissionJob(db, jobId: artifact.manifest.jobId),
        let state = try committedReviewState(db, artifact: artifact),
        reviewCarrierMatchesImmutableArtifact(
          review,
          artifact: artifact,
          state: state,
          ownerChatId: job.ownerChatId
        ),
        let markup = try committedChunksMarkup(
          db,
          review: review,
          ownerChatId: job.ownerChatId
        ),
        try committedTargetsAreComplete(
          db,
          artifact: artifact,
          state: state,
          ownerChatId: job.ownerChatId,
          markup: markup
        )
      else {
        return false
      }
      return true
    } catch is StoreError {
      return false
    }
  }

  static func committedReviewState(
    _ db: Database,
    artifact: CandidateArtifact
  ) throws -> CandidateReviewState? {
    if let trial = try trialRow(db, candidate: artifact.digest) {
      _ = try admissionReceipt(db, artifact: artifact, trial: trial)
      return .admitted
    }
    guard artifact.manifest.origin == .ownerEdit else {
      return nil
    }
    return .awaitingApproval
  }

  static func committedChunksMarkup(
    _ db: Database,
    review: CandidateReviewNotice,
    ownerChatId: Int64
  ) throws -> String? {
    let prefix = OutboxDedupKey.make(subjectDigest: review.subjectDigest, ordinal: 0).dropLast()
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT run_id, step_index, chat_id, dedup_key, payload, payload_hash, approval_id,
          reply_markup, message_thread_id, reply_to_message_id, delivery_source
        FROM outbound_deliveries WHERE dedup_key GLOB ? ORDER BY step_index
        """,
      arguments: ["\(prefix)*"]
    )
    guard rows.count == review.chunks.count, rows.isEmpty == false else {
      return nil
    }
    for (ordinal, row) in rows.enumerated() {
      let expected = review.chunks[ordinal]
      let payload: String = row["payload"]
      guard
        (row["run_id"] as Int64?) == nil,
        row["step_index"] as Int == ordinal,
        row["chat_id"] as Int64 == ownerChatId,
        row["dedup_key"] as String
          == OutboxDedupKey.make(subjectDigest: review.subjectDigest, ordinal: ordinal),
        expected.subjectDigest == review.subjectDigest,
        expected.ordinal == ordinal,
        expected.chatId == ownerChatId,
        payload == expected.payload,
        row["payload_hash"] as String == expected.payloadHash,
        payload.isEmpty == false,
        row["payload_hash"] as String == ContentHash.fnv1a(payload),
        (row["approval_id"] as Int64?) == nil,
        (row["message_thread_id"] as Int64?) == nil,
        (row["reply_to_message_id"] as Int64?) == nil,
        row["delivery_source"] as String == DeliverySource.learning.rawValue
      else {
        return nil
      }
    }
    guard
      rows.dropLast().allSatisfy({ row in
        (row["reply_markup"] as String?) == nil
      }), let markup = rows.last?["reply_markup"] as String?
    else {
      return nil
    }
    return markup
  }

  static func committedTargetsAreComplete(
    _ db: Database,
    artifact: CandidateArtifact,
    state: CandidateReviewState,
    ownerChatId: Int64,
    markup: String
  ) throws -> Bool {
    guard
      let rows = try? FeedbackKeyboard.parseMarkup(markup),
      rows.count == artifact.manifest.evaluations.count + 1
    else {
      return false
    }
    let candidateActions = candidateActions(for: state)
    var targetNonces: Set<String> = []
    var targets: [NewFeedbackTarget] = []
    var candidateExpiry: Date?
    for (index, buttons) in rows.enumerated() {
      guard
        let nonce = buttons.first?.nonce,
        buttons.allSatisfy({ $0.nonce == nonce }),
        targetNonces.insert(nonce).inserted,
        let target = try readTarget(db, nonce: nonce)
      else {
        return false
      }
      let expectedKind: FeedbackSubjectKind
      let expectedDigest: String
      let expectedActions: [OwnerSignal]
      if index == 0 {
        expectedKind = .candidate
        expectedDigest = artifact.digest.rawValue
        expectedActions = candidateActions
        candidateExpiry = target.expiresAt
      } else {
        expectedKind = .evaluation
        expectedDigest = artifact.manifest.evaluations[index - 1].digest.rawValue
        expectedActions = [.evaluationConfirm, .evaluationDispute]
      }
      guard
        buttons.map(\.action.signal) == expectedActions,
        target.jobId == artifact.manifest.jobId,
        target.epoch == artifact.manifest.epoch,
        target.subjectKind == expectedKind,
        target.subjectDigest == expectedDigest,
        target.allowedActions == expectedActions,
        target.ownerUserId == ownerChatId,
        target.chatId == ownerChatId,
        target.expiresAt == candidateExpiry
      else {
        return false
      }
      targets.append(newTarget(from: target))
    }
    guard
      FeedbackKeyboard.candidateReviewMarkup(
        targets: targets,
        evaluations: artifact.manifest.evaluations
      ) == markup
    else {
      return false
    }
    return true
  }

  static func newTarget(from target: FeedbackTarget) -> NewFeedbackTarget {
    NewFeedbackTarget(
      nonce: target.nonce,
      jobId: target.jobId,
      epoch: target.epoch,
      subjectKind: target.subjectKind,
      subjectDigest: target.subjectDigest,
      allowedActions: target.allowedActions,
      ownerUserId: target.ownerUserId,
      chatId: target.chatId,
      expiresAt: target.expiresAt
    )
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
      chunksHaveValidShape(review.chunks, subjectDigest: review.subjectDigest),
      FeedbackKeyboard.candidateReviewMarkup(
        targets: review.targets,
        evaluations: artifact.manifest.evaluations
      ) == review.chunks.last?.replyMarkup
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
    let candidateActions = candidateActions(for: state)
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

  static func candidateActions(for state: CandidateReviewState) -> [OwnerSignal] {
    switch state {
    case .admitted:
      [.candidateReject, .candidateEdit]
    case .awaitingApproval:
      [.candidateApprove, .candidateReject, .candidateEdit]
    }
  }

  static func reviewCarrierMatchesImmutableArtifact(
    _ review: CandidateReviewNotice,
    artifact: CandidateArtifact,
    state: CandidateReviewState,
    ownerChatId: Int64
  ) -> Bool {
    guard
      review.state == state,
      review.targets.count == artifact.manifest.evaluations.count + 1,
      review.targets.count <= 6,
      let expiry = review.targets.first?.expiresAt,
      review.targets.allSatisfy({ $0.nonce.isEmpty == false }),
      Set(review.targets.map(\.nonce)).count == review.targets.count,
      targetsMatch(
        review.targets,
        artifact: artifact,
        state: state,
        ownerChatId: ownerChatId,
        expiry: expiry
      ),
      review.chunks.allSatisfy({ $0.chatId == ownerChatId }),
      chunksHaveValidShape(review.chunks, subjectDigest: review.subjectDigest),
      FeedbackKeyboard.candidateReviewMarkup(
        targets: review.targets,
        evaluations: artifact.manifest.evaluations
      ) == review.chunks.last?.replyMarkup
    else {
      return false
    }
    return true
  }
}
