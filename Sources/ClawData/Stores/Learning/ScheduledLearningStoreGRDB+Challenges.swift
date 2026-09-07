import ClawCore
import Foundation
import GRDB

// MARK: - Challenge Rows

extension ScheduledLearningStoreGRDB {
  static func temporarilyConsumeLiveChallenge(
    _ db: Database,
    challenge: NewFeedbackChallenge,
    now: Date
  ) throws -> Int64? {
    try Int64.fetchOne(
      db,
      sql: """
        UPDATE feedback_challenges SET consumed_at = ?
        WHERE owner_user_id = ? AND chat_id = ?
          AND superseded_by IS NULL AND consumed_at IS NULL
        RETURNING challenge_id
        """,
      arguments: [EpochSecondCodec.epoch(now), challenge.ownerUserId, challenge.chatId]
    )
  }

  static func insertChallenge(
    _ db: Database,
    _ challenge: NewFeedbackChallenge
  ) throws -> FeedbackChallenge {
    guard challenge.subjectKind == .run || challenge.subjectKind == .candidate else {
      throw StoreError.unexpected("feedback challenge subject kind cannot carry free text")
    }
    try db.execute(
      sql: """
        INSERT INTO feedback_challenges(owner_user_id, chat_id, job_id, learning_epoch,
          subject_kind, subject_digest, superseded_by, consumed_at, expires_at)
        VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, ?)
        """,
      arguments: [
        challenge.ownerUserId,
        challenge.chatId,
        challenge.jobId,
        challenge.epoch.value,
        challenge.subjectKind.rawValue,
        challenge.subjectDigest,
        EpochSecondCodec.epoch(challenge.expiresAt),
      ]
    )
    return FeedbackChallenge(
      id: db.lastInsertedRowID,
      ownerUserId: challenge.ownerUserId,
      chatId: challenge.chatId,
      jobId: challenge.jobId,
      epoch: challenge.epoch,
      subjectKind: challenge.subjectKind,
      subjectDigest: challenge.subjectDigest,
      supersededBy: nil,
      consumedAt: nil,
      expiresAt: challenge.expiresAt
    )
  }

  static func finishChallengeSupersession(
    _ db: Database,
    priorId: Int64?,
    replacementId: Int64
  ) throws {
    guard let priorId else {
      return
    }
    try db.execute(
      sql: """
        UPDATE feedback_challenges SET superseded_by = ?, consumed_at = NULL
        WHERE challenge_id = ?
        """,
      arguments: [replacementId, priorId]
    )
  }

  static func readChallenge(_ db: Database, id: Int64) throws -> FeedbackChallenge? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: "SELECT * FROM feedback_challenges WHERE challenge_id = ?",
        arguments: [id]
      )
    else {
      return nil
    }
    return try decodeChallenge(row)
  }

  static func decodeChallenge(_ row: Row) throws -> FeedbackChallenge {
    guard
      let subjectKind = FeedbackSubjectKind(rawValue: row["subject_kind"]),
      subjectKind == .run || subjectKind == .candidate,
      let expiresAt = EpochSecondCodec.date(fromEpoch: row["expires_at"])
    else {
      throw StoreError.unexpected("feedback challenge row is unreadable")
    }
    let consumedEpoch: Int64? = row["consumed_at"]
    return FeedbackChallenge(
      id: row["challenge_id"],
      ownerUserId: row["owner_user_id"],
      chatId: row["chat_id"],
      jobId: row["job_id"],
      epoch: LearningEpoch(row["learning_epoch"]),
      subjectKind: subjectKind,
      subjectDigest: row["subject_digest"],
      supersededBy: row["superseded_by"],
      consumedAt: consumedEpoch.flatMap(EpochSecondCodec.date(fromEpoch:)),
      expiresAt: expiresAt
    )
  }
}

// MARK: - Challenge Consumption

extension ScheduledLearningStoreGRDB {
  static func consumeLiveChallenge(
    _ db: Database,
    id: Int64,
    now: Date
  ) throws -> FeedbackChallenge? {
    let row = try Row.fetchOne(
      db,
      sql: """
        UPDATE feedback_challenges SET consumed_at = ?
        WHERE challenge_id = ? AND consumed_at IS NULL AND superseded_by IS NULL
          AND expires_at > ?
          AND learning_epoch = (
            SELECT learning_epoch FROM job_learning_state
            WHERE job_id = feedback_challenges.job_id
          )
        RETURNING *
        """,
      arguments: [EpochSecondCodec.epoch(now), id, EpochSecondCodec.epoch(now)]
    )
    return try row.map(decodeChallenge)
  }

  static func failedChallengeOutcome(
    _ db: Database,
    challenge: FeedbackChallenge?,
    now: Date
  ) throws -> FeedbackOutcome {
    guard let challenge else {
      return .targetMissing
    }
    if challenge.consumedAt != nil || challenge.supersededBy != nil {
      return .alreadyConsumed
    }
    if challenge.expiresAt <= now {
      return .expired
    }
    guard
      let currentEpoch = try Int.fetchOne(
        db,
        sql: "SELECT learning_epoch FROM job_learning_state WHERE job_id = ?",
        arguments: [challenge.jobId]
      )
    else {
      return .staleEpoch
    }
    if currentEpoch != challenge.epoch.value {
      return .staleEpoch
    }
    throw StoreError.unexpected("feedback challenge CAS lost without a classified predicate")
  }

  static func advanceFeedbackRevision(
    _ db: Database,
    challenge: FeedbackChallenge
  ) throws -> FeedbackRevision? {
    let revision = try Int64.fetchOne(
      db,
      sql: """
        UPDATE job_learning_state SET feedback_revision = feedback_revision + 1
        WHERE job_id = ? AND learning_epoch = ?
        RETURNING feedback_revision
        """,
      arguments: [challenge.jobId, challenge.epoch.value]
    )
    return revision.map(FeedbackRevision.init)
  }
}

// MARK: - Challenge Events

extension ScheduledLearningStoreGRDB {
  static func insertEvent(
    _ db: Database,
    challenge: FeedbackChallenge,
    payload: String,
    revision: FeedbackRevision,
    now: Date
  ) throws -> FeedbackEvent {
    let signal = try challengeSignal(challenge.subjectKind)
    let supersedes = try Int64.fetchOne(
      db,
      sql: """
        SELECT event_id FROM feedback_events
        WHERE job_id = ? AND learning_epoch = ? AND subject_kind = ? AND subject_digest = ?
        ORDER BY feedback_revision DESC, event_id DESC LIMIT 1
        """,
      arguments: [
        challenge.jobId,
        challenge.epoch.value,
        challenge.subjectKind.rawValue,
        challenge.subjectDigest,
      ]
    )
    try db.execute(
      sql: """
        INSERT INTO feedback_events(job_id, learning_epoch, subject_kind, subject_digest, signal,
          payload, actor, transport_update_id, feedback_revision, supersedes, occurred_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?)
        """,
      arguments: [
        challenge.jobId,
        challenge.epoch.value,
        challenge.subjectKind.rawValue,
        challenge.subjectDigest,
        signal.rawValue,
        payload,
        AuditActor.owner.rawValue,
        revision.value,
        supersedes,
        EpochSecondCodec.epoch(now),
      ]
    )
    return FeedbackEvent(
      id: db.lastInsertedRowID,
      runId: try runId(
        db,
        jobId: challenge.jobId,
        subjectKind: challenge.subjectKind,
        subjectDigest: challenge.subjectDigest
      ),
      signal: signal,
      payload: payload,
      revision: revision,
      supersedes: supersedes,
      occurredAt: now,
      actor: .owner,
      transportUpdateId: nil
    )
  }

  static func challengeSignal(_ subjectKind: FeedbackSubjectKind) throws -> OwnerSignal {
    switch subjectKind {
    case .run:
      return .resultCorrection
    case .candidate:
      return .candidateEdit
    case .evaluation, .promotion:
      throw StoreError.unexpected("feedback challenge subject kind cannot carry free text")
    }
  }

  static func runId(_ db: Database, target: FeedbackTarget) throws -> Int64? {
    try runId(
      db,
      jobId: target.jobId,
      subjectKind: target.subjectKind,
      subjectDigest: target.subjectDigest
    )
  }

  static func runId(
    _ db: Database,
    jobId: Int64,
    subjectKind: FeedbackSubjectKind,
    subjectDigest: String
  ) throws -> Int64? {
    switch subjectKind {
    case .run:
      return Int64(subjectDigest)
    case .evaluation:
      return try Int64.fetchOne(
        db,
        sql: """
          SELECT run_id FROM learning_evaluations
          WHERE job_id = ? AND evaluation_digest = ?
          """,
        arguments: [jobId, subjectDigest]
      )
    case .candidate, .promotion:
      return nil
    }
  }
}

// MARK: - Challenge Audit

extension ScheduledLearningStoreGRDB {
  static func auditChallenge(
    _ db: Database,
    challenge: FeedbackChallenge?,
    outcome: FeedbackOutcome,
    payloadByteCount: Int,
    now: Date
  ) throws {
    let signal = try challenge.map { value in
      try challengeSignal(value.subjectKind)
    }
    try AuditLogGRDB.insertAudit(
      db,
      AuditEvent(
        actor: challenge == nil ? .system : .owner,
        action: .learningFeedback,
        tool: signal?.rawValue,
        argsRedacted: auditSubject(challenge),
        resultSize: payloadByteCount,
        decision: outcome.auditDecision,
        runId: try challenge.flatMap { value in
          try runId(
            db,
            jobId: value.jobId,
            subjectKind: value.subjectKind,
            subjectDigest: value.subjectDigest
          )
        },
        ts: now
      )
    )
  }

  static func auditSubject(_ challenge: FeedbackChallenge?) -> String {
    guard let challenge else {
      return ""
    }
    return
      "subject_kind=\(challenge.subjectKind.rawValue),subject_digest=\(challenge.subjectDigest)"
  }
}
