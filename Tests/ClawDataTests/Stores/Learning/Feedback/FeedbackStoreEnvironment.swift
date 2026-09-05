import ClawCore
import Foundation
import GRDB

@testable import ClawData

enum FeedbackFailureCase: CaseIterable {
  case owner
  case chat
  case expiry
  case action
  case epoch

  var outcome: FeedbackOutcome {
    switch self {
    case .owner: .ownerMismatch
    case .chat: .chatMismatch
    case .expiry: .expired
    case .action: .actionMismatch
    case .epoch: .staleEpoch
    }
  }

  var decision: String {
    switch self {
    case .owner: "owner_mismatch"
    case .chat: "chat_mismatch"
    case .expiry: "expired"
    case .action: "action_mismatch"
    case .epoch: "stale_epoch"
    }
  }
}

struct FeedbackStoreEnvironment {
  struct DeliveryRow {
    let deliveryKey: String
    let runId: Int64?
    let source: String
    let payload: String
    let replyMarkup: String?
    let createdAt: Date
  }

  struct AuditRow {
    let actor: AuditActor
    let action: String
    let tool: String
    let args: String
    let resultSize: Int
    let decision: String
    let ts: Date
  }

  struct EventRow {
    let id: Int64
    let signal: OwnerSignal
    let revision: FeedbackRevision
    let supersedes: Int64?
    let subjectDigest: String
    let payload: String?
    let occurredAt: Date
  }

  let base: BoundRunEnvironment
  let state: JobLearningState

  var queue: any DatabaseWriter { base.queue }
  var learning: ScheduledLearningStoreGRDB { base.learning }
  var jobId: Int64 { base.jobId }
  var now: Date { base.now }

  static func make() throws -> FeedbackStoreEnvironment {
    let base = try BoundRunEnvironment.make()
    let state = try base.learning.armJob(jobId: base.jobId, now: base.now)
    return FeedbackStoreEnvironment(base: base, state: state)
  }

  func target(
    nonce: String,
    signal: OwnerSignal,
    subject: String,
    kind: FeedbackSubjectKind = .run,
    expiresAt: Date? = nil
  ) -> NewFeedbackTarget {
    NewFeedbackTarget(
      nonce: nonce,
      jobId: jobId,
      epoch: state.epoch,
      subjectKind: kind,
      subjectDigest: subject,
      allowedActions: [signal],
      ownerUserId: 42,
      chatId: 42,
      expiresAt: expiresAt ?? now.addingTimeInterval(3_600)
    )
  }

  func chunk(subject: String, ordinal: Int, markup: String?) -> LearningNoticeChunk {
    let payload = "chunk-\(ordinal)"
    return LearningNoticeChunk(
      subjectDigest: subject,
      ordinal: ordinal,
      chatId: 42,
      payload: payload,
      payloadHash: ContentHash.fnv1a(payload),
      replyMarkup: markup
    )
  }

  func tap(
    target: NewFeedbackTarget,
    signal: OwnerSignal,
    updateId: Int64 = 1
  ) -> FeedbackTap {
    FeedbackTap(
      nonce: target.nonce,
      signal: signal,
      ownerUserId: target.ownerUserId,
      chatId: target.chatId,
      transportUpdateId: updateId
    )
  }

  func invalidTap(target: NewFeedbackTarget, failure: FeedbackFailureCase) -> FeedbackTap {
    FeedbackTap(
      nonce: target.nonce,
      signal: failure == .action ? .resultNotUseful : .resultUseful,
      ownerUserId: failure == .owner ? 43 : target.ownerUserId,
      chatId: failure == .chat ? 43 : target.chatId,
      transportUpdateId: 1
    )
  }

  func createTargets(
    _ targets: [NewFeedbackTarget],
    chunks: [LearningNoticeChunk]
  ) throws(StoreError) {
    try learning.createTargets(targets, chunks: chunks, now: now)
  }

  func consume(
    _ tap: FeedbackTap,
    now: Date? = nil
  ) throws(StoreError) -> FeedbackOutcome {
    try learning.consumeAndAppendEvent(tap, now: now ?? self.now)
  }

  func challengePrompt(_ target: NewFeedbackTarget) -> [LearningNoticeChunk] {
    let payload = "Reply with the correction."
    return [
      LearningNoticeChunk(
        subjectDigest: FeedbackChallengeDeliveryIdentity.digest(targetNonce: target.nonce),
        ordinal: 0,
        chatId: target.chatId,
        payload: payload,
        payloadHash: ContentHash.fnv1a(payload)
      )
    ]
  }

  func openChallenge(
    _ target: NewFeedbackTarget,
    updateId: Int64 = 1
  ) throws(StoreError) -> FeedbackOutcome {
    try learning.consumeAndOpenChallenge(
      tap(target: target, signal: target.allowedActions[0], updateId: updateId),
      prompt: challengePrompt(target),
      now: now
    )
  }

  func challenge(_ id: Int64) throws -> FeedbackChallenge? {
    try queue.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: "SELECT * FROM feedback_challenges WHERE challenge_id = ?",
          arguments: [id]
        )
      else {
        return nil
      }
      guard
        let kind = FeedbackSubjectKind(rawValue: row["subject_kind"]),
        let expiresAt = EpochSecondCodec.date(fromEpoch: row["expires_at"])
      else {
        throw StoreError.unexpected("challenge fixture row is unreadable")
      }
      let consumedEpoch: Int64? = row["consumed_at"]
      return FeedbackChallenge(
        id: row["challenge_id"],
        ownerUserId: row["owner_user_id"],
        chatId: row["chat_id"],
        jobId: row["job_id"],
        epoch: LearningEpoch(row["learning_epoch"]),
        subjectKind: kind,
        subjectDigest: row["subject_digest"],
        supersededBy: row["superseded_by"],
        consumedAt: consumedEpoch.flatMap(EpochSecondCodec.date(fromEpoch:)),
        expiresAt: expiresAt
      )
    }
  }

  func feedbackEvents(
    jobId: Int64,
    epoch: LearningEpoch,
    subjectKind: FeedbackSubjectKind,
    subjectDigest: String
  ) throws -> [EventRow] {
    try readFeedbackEvents(
      whereClause: "job_id = ? AND learning_epoch = ? AND subject_kind = ? AND subject_digest = ?",
      arguments: [jobId, epoch.value, subjectKind.rawValue, subjectDigest]
    )
  }

  func allFeedbackEvents() throws -> [EventRow] {
    try readFeedbackEvents(whereClause: "1 = 1", arguments: [])
  }

  func setEpoch(_ epoch: Int64) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE job_learning_state SET learning_epoch = ? WHERE job_id = ?",
        arguments: [epoch, jobId]
      )
    }
  }

  func forceFeedbackAuditFailure() throws {
    try queue.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER fail_feedback_audit BEFORE INSERT ON audit_events
          WHEN NEW.action = '\(AuditAction.learningFeedback.rawValue)'
          BEGIN SELECT RAISE(ABORT, 'forced feedback audit failure'); END
          """
      )
    }
  }

  func feedbackRevision() throws -> Int64 {
    try queue.read { db in
      try Int64.fetchOne(
        db,
        sql: "SELECT feedback_revision FROM job_learning_state WHERE job_id = ?",
        arguments: [jobId]
      ) ?? -1
    }
  }

  func targetCount() throws -> Int {
    try rowCount(table: "feedback_targets")
  }

  func eventCount() throws -> Int {
    try rowCount(table: "feedback_events")
  }

  func rowCount(table: String) throws -> Int {
    try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
    }
  }

  func deliveryRows() throws -> [DeliveryRow] {
    try queue.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT dedup_key, run_id, delivery_source, payload, reply_markup, created_ts
          FROM outbound_deliveries
          ORDER BY step_index
          """
      ).map { row in
        let createdAt: Date = row["created_ts"]
        return DeliveryRow(
          deliveryKey: row["dedup_key"],
          runId: row["run_id"],
          source: row["delivery_source"],
          payload: row["payload"],
          replyMarkup: row["reply_markup"],
          createdAt: createdAt
        )
      }
    }
  }

  func feedbackAudits() throws -> [AuditRow] {
    try queue.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT ts, actor, action, tool, args_redacted, result_size, decision FROM audit_events
          WHERE action = ? ORDER BY id
          """,
        arguments: [AuditAction.learningFeedback.rawValue]
      ).map { row in
        let ts: Date = row["ts"]
        guard let actor = AuditActor(rawValue: row["actor"]) else {
          throw StoreError.unexpected("feedback audit fixture actor is unreadable")
        }
        return AuditRow(
          actor: actor,
          action: row["action"],
          tool: row["tool"],
          args: row["args_redacted"],
          resultSize: row["result_size"],
          decision: row["decision"],
          ts: ts
        )
      }
    }
  }

  func insertTwoLiveChallengesDirectly() throws(StoreError) {
    try learning.database.writeMapping { db in
      for subject in ["41", "42"] {
        try db.execute(
          sql: """
            INSERT INTO feedback_challenges(owner_user_id, chat_id, job_id, learning_epoch,
              subject_kind, subject_digest, expires_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            42, 42, jobId, state.epoch.value, FeedbackSubjectKind.run.rawValue, subject,
            EpochSecondCodec.epoch(now.addingTimeInterval(3_600)),
          ]
        )
      }
    }
  }

  func insertChallengeDirectly(kind: FeedbackSubjectKind) throws {
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO feedback_challenges(owner_user_id, chat_id, job_id, learning_epoch,
            subject_kind, subject_digest, expires_at)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          42, 42, jobId, state.epoch.value, kind.rawValue, "unsupported",
          EpochSecondCodec.epoch(now.addingTimeInterval(3_600)),
        ]
      )
    }
  }

  func setTargetSubjectKind(nonce: String, kind: FeedbackSubjectKind) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE feedback_targets SET subject_kind = ? WHERE nonce = ?",
        arguments: [kind.rawValue, nonce]
      )
    }
  }
}

// MARK: - Feedback Event Rows

private extension FeedbackStoreEnvironment {
  func readFeedbackEvents(
    whereClause: String,
    arguments: StatementArguments
  ) throws -> [EventRow] {
    try queue.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT event_id, signal, feedback_revision, supersedes, subject_digest, payload,
            occurred_at
          FROM feedback_events
          WHERE \(whereClause)
          ORDER BY feedback_revision, event_id
          """,
        arguments: arguments
      ).map { row in
        guard
          let signal = OwnerSignal(rawValue: row["signal"]),
          let occurredAt = EpochSecondCodec.date(fromEpoch: row["occurred_at"])
        else {
          throw StoreError.unexpected("feedback event fixture row is unreadable")
        }
        return EventRow(
          id: row["event_id"],
          signal: signal,
          revision: FeedbackRevision(row["feedback_revision"]),
          supersedes: row["supersedes"],
          subjectDigest: row["subject_digest"],
          payload: row["payload"],
          occurredAt: occurredAt
        )
      }
    }
  }
}
