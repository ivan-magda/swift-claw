import ClawCore
import Foundation
import GRDB

public struct ScheduledLearningStoreGRDB: ScheduledLearningStore {
  let database: MappedDatabase

  public init(writer: any DatabaseWriter) {
    database = MappedDatabase(writer: writer)
  }

  public func armJob(jobId: Int64, now: Date) throws(StoreError) -> JobLearningState {
    try database.writeMapping { db in
      try Self.armState(db, jobId: jobId, now: now)
    }
  }

  public func binding(runId: Int64) throws(StoreError) -> RunLearningBinding? {
    try database.readMapping { db in
      try Self.readBinding(db, runId: runId)
    }
  }

  public func openTrial(jobId: Int64) throws(StoreError) -> LearningTrial? {
    try database.readMapping { db in
      try Self.liveTrial(db, jobId: jobId)
    }
  }

  public func lessonSet(jobId: Int64, digest: LessonSetDigest) throws(StoreError) -> LessonSet? {
    try database.readMapping { db in
      try Self.readLessonSet(db, jobId: jobId, digest: digest)
    }
  }
}

// MARK: - In-Transaction Arming

extension ScheduledLearningStoreGRDB {
  static func readLessonSet(
    _ db: Database,
    jobId: Int64,
    digest: LessonSetDigest
  ) throws -> LessonSet? {
    let row = try Row.fetchOne(
      db,
      sql: "SELECT canonical_bytes FROM lesson_sets WHERE job_id = ? AND digest = ?",
      arguments: [jobId, digest.rawValue]
    )
    guard let row else {
      return nil
    }
    guard
      let bytes = SQLiteStoredValue.data(in: row, column: "canonical_bytes"),
      let set = LessonSet.decoded(jobId: jobId, canonicalBytes: bytes),
      set.digest == digest
    else {
      throw StoreError.unexpected("lesson set \(digest.rawValue) for job \(jobId) is unreadable")
    }
    return set
  }

  /// `armJob` without a transaction of its own, so the fire path can arm a job and bind its run
  /// in one write. Idempotent: a job that has already armed keeps the state it has.
  static func armState(_ db: Database, jobId: Int64, now: Date) throws -> JobLearningState {
    // The empty set goes in first: the state row names a digest, and a state that pointed at a
    // lesson set no row holds would let a job fire against a binding it cannot resolve.
    let empty = LessonSet.empty(jobId: jobId)
    try insertCanonicalEmptySet(db, empty, now: now)
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO job_learning_state(job_id, learning_epoch,
          stable_lesson_set_digest, stable_revision, open_trial_id, feedback_revision, armed_at)
        VALUES (?, 1, ?, 0, NULL, 0, ?)
        """,
      arguments: [jobId, empty.digest.rawValue, EpochSecondCodec.epoch(now)]
    )
    guard let state = try readState(db, jobId: jobId) else {
      throw StoreError.unexpected("job \(jobId) has no learning state after arming")
    }
    return state
  }

  static func readState(_ db: Database, jobId: Int64) throws -> JobLearningState? {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT learning_epoch, stable_lesson_set_digest, stable_revision, open_trial_id,
          feedback_revision
        FROM job_learning_state WHERE job_id = ?
        """,
      arguments: [jobId]
    )
    guard let row else {
      return nil
    }
    guard
      let epoch = SQLiteStoredValue.int64(in: row, column: "learning_epoch"),
      let stableDigest = SQLiteStoredValue.string(
        in: row,
        column: "stable_lesson_set_digest"
      ),
      let stableRevision = SQLiteStoredValue.int64(in: row, column: "stable_revision"),
      let openTrial = SQLiteStoredValue.nullableInt64(in: row, column: "open_trial_id"),
      let feedbackRevision = SQLiteStoredValue.int64(in: row, column: "feedback_revision")
    else {
      throw StoreError.unexpected("job \(jobId) has an unreadable learning state")
    }
    return JobLearningState(
      jobId: jobId,
      epoch: LearningEpoch(epoch),
      stableDigest: LessonSetDigest(rawValue: stableDigest),
      stableRevision: StableRevision(stableRevision),
      openTrialId: openTrial.value,
      feedbackRevision: FeedbackRevision(feedbackRevision)
    )
  }
}

// MARK: - Rows

private extension ScheduledLearningStoreGRDB {
  static func insertCanonicalEmptySet(_ db: Database, _ set: LessonSet, now: Date) throws {
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO lesson_sets(job_id, digest, schema_version, canonical_bytes,
          source, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        set.jobId,
        set.digest.rawValue,
        set.schemaVersion,
        set.canonicalBytes,
        LessonSetSource.canonicalEmpty.rawValue,
        EpochSecondCodec.epoch(now),
      ]
    )
  }
}
