import ClawCore
import Foundation
import GRDB

// MARK: - Feedback Challenges

extension ScheduledLearningStoreGRDB {
  public func consumeAndOpenChallenge(
    _ tap: FeedbackTap,
    prompt: [LearningNoticeChunk],
    now: Date
  ) throws(StoreError) -> FeedbackOutcome {
    try database.writeMapping { db in
      guard tap.signal.opensFeedbackChallenge else {
        let target = try Self.readTarget(db, nonce: tap.nonce)
        let outcome = FeedbackOutcome.actionMismatch
        try Self.auditFeedback(db, tap: tap, target: target, outcome: outcome, now: now)
        return outcome
      }

      guard let target = try Self.consumeTarget(db, tap: tap, now: now) else {
        let found = try Self.readTarget(db, nonce: tap.nonce)
        let outcome = try Self.failedOutcome(db, tap: tap, target: found, now: now)
        try Self.auditFeedback(db, tap: tap, target: found, outcome: outcome, now: now)
        return outcome
      }

      let insertion = NewFeedbackChallenge(target: target)
      guard prompt.isEmpty == false else {
        throw StoreError.unexpected("feedback challenge prompt has no chunks")
      }
      guard
        prompt.allSatisfy({ chunk in
          chunk.subjectDigest == insertion.promptDigest && chunk.chatId == insertion.chatId
        })
      else {
        throw StoreError.unexpected("feedback challenge prompt identity does not match its target")
      }

      let priorId = try Self.temporarilyConsumeLiveChallenge(db, challenge: insertion, now: now)
      let challenge = try Self.insertChallenge(db, insertion)
      try Self.finishChallengeSupersession(db, priorId: priorId, replacementId: challenge.id)

      for chunk in prompt {
        guard try OutboxStoreGRDB.insertNotice(db, chunk: chunk, now: now) else {
          throw StoreError.unexpected("feedback challenge prompt delivery already exists")
        }
      }

      let outcome = FeedbackOutcome.challengeOpened(challenge)
      try Self.auditFeedback(db, tap: tap, target: target, outcome: outcome, now: now)
      return outcome
    }
  }

  public func consumeChallenge(
    id: Int64,
    payload: String,
    now: Date
  ) throws(StoreError) -> FeedbackOutcome {
    try database.writeMapping { db in
      guard let challenge = try Self.consumeLiveChallenge(db, id: id, now: now) else {
        let found = try Self.readChallenge(db, id: id)
        let outcome = try Self.failedChallengeOutcome(db, challenge: found, now: now)
        try Self.auditChallenge(
          db,
          challenge: found,
          outcome: outcome,
          payloadByteCount: payload.utf8.count,
          now: now
        )
        return outcome
      }

      guard let revision = try Self.advanceFeedbackRevision(db, challenge: challenge) else {
        throw StoreError.unexpected("feedback revision CAS lost after challenge consumption")
      }
      let event = try Self.insertEvent(
        db,
        challenge: challenge,
        payload: payload,
        revision: revision,
        now: now
      )
      try Self.recomputeFeedbackSubject(
        db,
        jobId: challenge.jobId,
        epoch: challenge.epoch,
        subjectKind: challenge.subjectKind,
        subjectDigest: challenge.subjectDigest,
        now: now
      )
      let outcome = FeedbackOutcome.recorded(event)
      try Self.auditChallenge(
        db,
        challenge: challenge,
        outcome: outcome,
        payloadByteCount: payload.utf8.count,
        now: now
      )
      return outcome
    }
  }

  public func liveChallenge(
    ownerUserId: Int64,
    chatId: Int64
  ) throws(StoreError) -> FeedbackChallenge? {
    try database.readMapping { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT * FROM feedback_challenges
            WHERE owner_user_id = ? AND chat_id = ?
              AND superseded_by IS NULL AND consumed_at IS NULL
            """,
          arguments: [ownerUserId, chatId]
        )
      else {
        return nil
      }
      return try Self.decodeChallenge(row)
    }
  }
}
