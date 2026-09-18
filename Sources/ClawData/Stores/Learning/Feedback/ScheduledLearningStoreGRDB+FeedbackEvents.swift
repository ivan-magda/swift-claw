import ClawCore
import Foundation
import GRDB

// MARK: - Event Rows

extension ScheduledLearningStoreGRDB {
  struct FeedbackEventInsertion {
    let jobID: Int64
    let epoch: LearningEpoch
    let subjectKind: FeedbackSubjectKind
    let subjectDigest: String
    let signal: OwnerSignal
    let payload: String?
    let transportUpdateID: Int64?
  }

  static func advanceFeedbackRevision(
    _ db: Database,
    jobID: Int64,
    epoch: LearningEpoch
  ) throws -> FeedbackRevision? {
    let revision = try Int64.fetchOne(
      db,
      sql: """
        UPDATE job_learning_state SET feedback_revision = feedback_revision + 1
        WHERE job_id = ? AND learning_epoch = ?
        RETURNING feedback_revision
        """,
      arguments: [jobID, epoch.value]
    )
    return revision.map(FeedbackRevision.init)
  }

  static func insertEvent(
    _ db: Database,
    insertion: FeedbackEventInsertion,
    revision: FeedbackRevision,
    now: Date
  ) throws -> FeedbackEvent {
    let supersedes = try Int64.fetchOne(
      db,
      sql: """
        SELECT event_id FROM feedback_events
        WHERE job_id = ? AND learning_epoch = ? AND subject_kind = ? AND subject_digest = ?
        ORDER BY feedback_revision DESC, event_id DESC LIMIT 1
        """,
      arguments: [
        insertion.jobID,
        insertion.epoch.value,
        insertion.subjectKind.rawValue,
        insertion.subjectDigest,
      ]
    )
    try db.execute(
      sql: """
        INSERT INTO feedback_events(job_id, learning_epoch, subject_kind, subject_digest, signal,
          payload, actor, transport_update_id, feedback_revision, supersedes, occurred_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        insertion.jobID,
        insertion.epoch.value,
        insertion.subjectKind.rawValue,
        insertion.subjectDigest,
        insertion.signal.rawValue,
        insertion.payload,
        AuditActor.owner.rawValue,
        insertion.transportUpdateID,
        revision.value,
        supersedes,
        EpochSecondCodec.epoch(now),
      ]
    )
    return FeedbackEvent(
      id: db.lastInsertedRowID,
      runID: try runID(
        db,
        jobID: insertion.jobID,
        subjectKind: insertion.subjectKind,
        subjectDigest: insertion.subjectDigest
      ),
      signal: insertion.signal,
      payload: insertion.payload,
      revision: revision,
      supersedes: supersedes,
      occurredAt: now,
      actor: .owner,
      transportUpdateID: insertion.transportUpdateID
    )
  }
}

// MARK: - Subject Runs

extension ScheduledLearningStoreGRDB {
  static func runID(_ db: Database, target: FeedbackTarget) throws -> Int64? {
    try runID(
      db,
      jobID: target.jobID,
      subjectKind: target.subjectKind,
      subjectDigest: target.subjectDigest
    )
  }

  static func runID(
    _ db: Database,
    jobID: Int64,
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
        arguments: [jobID, subjectDigest]
      )
    case .candidate, .promotion:
      return nil
    }
  }
}
